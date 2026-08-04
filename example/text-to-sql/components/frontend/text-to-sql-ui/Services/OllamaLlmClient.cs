// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// OllamaLlmClient — local-first ILlmClient implementation backed by an
// Ollama server (default http://127.0.0.1:11434) running a local coding
// model (e.g. qwen3-coder). Activated when USE_LOCAL_MODEL / OLLAMA_HOST is
// set; keeps proprietary schema + questions on-device (no third-party API).
// Mirrors ClaudeLlmClient's structured-output + refusal-vs-failure contract:
// a parsed refused=true is a normal LlmDecision; every other failure mode
// throws LlmClientException. Pipeline role and the LlmDecision contract: see
// the README service notes — https://yuruna.link/text-to-sql#service-notes
// ---------------------------------------------------------------------------

using System.Text;
using System.Text.Json;

namespace TextToSqlUi.Services;

public sealed class OllamaLlmClient : ILlmClient
{
    private readonly HttpClient _http;
    private readonly ILogger<OllamaLlmClient> _log;
    private readonly string _model;
    private readonly string _baseUrl;

    private const string DefaultBaseUrl = "http://127.0.0.1:11434";
    private const string DefaultModel = "localcoder";

    // Local generation is slower than a hosted API and the first call also pays
    // a model load. Give each request a generous per-call ceiling and bound the
    // transient-failure retry with a wider window than the Claude client.
    private static readonly TimeSpan HttpTimeout = TimeSpan.FromSeconds(180);
    private static readonly TimeSpan RetryWindow = TimeSpan.FromSeconds(240);

    // Same operating contract as the Claude system prompt: read-only, no PII,
    // LIMIT 200, refuse honestly. The JSON-shape instruction replaces Claude's
    // tool-use schema — Ollama's format:"json" mode guarantees valid JSON, and
    // the required keys are spelled out here so the parse below is total.
    private static readonly string SystemPrompt = @"
You are a read-only SQL agent for a SaaS subscription analytics database.

Your job:
1. Receive a natural language question and a schema slice.
2. Reason step by step about which tables and joins are needed.
3. Return a safe, read-only SELECT statement — or refuse if you cannot.

Hard rules:
- ONLY generate SELECT statements. Never INSERT, UPDATE, DELETE, DROP, TRUNCATE, ALTER, GRANT.
- NEVER select PII columns: customer.email, customer.phone, or any column ending in _pii.
- If the question is ambiguous or outside the schema, refuse honestly.
- If you are not confident, refuse. Do not hallucinate table or column names.
- Always add a LIMIT clause (max 200 rows) unless the query is an aggregate.

Respond with ONLY a single JSON object — no markdown fences, no prose before or
after — with EXACTLY these keys:
  ""plan"":           string, your step-by-step reasoning (shown in the UI timeline).
  ""sql"":            string, the raw SELECT SQL with no markdown fences. Empty string if refused.
  ""refused"":        boolean, true if the question cannot be safely answered.
  ""refusal_reason"": string, human-readable reason for refusal. Empty string if not refused.
".Trim();

    public OllamaLlmClient(ILogger<OllamaLlmClient> log, string? baseUrl = null, string? model = null)
    {
        _log = log;
        _baseUrl = (baseUrl ?? DefaultBaseUrl).TrimEnd('/');
        _model = model ?? DefaultModel;
        _http = new HttpClient { Timeout = HttpTimeout };
    }

    public async Task<LlmDecision> GenerateSqlAsync(
        string question, string schemaSlice, CancellationToken ct = default)
    {
        var userMessage = $"Question: {question}\n\nSchema:\n{schemaSlice}";

        // Ollama /api/chat with stream=false returns a single JSON envelope;
        // format="json" constrains message.content to a valid JSON document.
        var requestBody = new
        {
            model = _model,
            stream = false,
            format = "json",
            options = new { temperature = 0.0 },
            messages = new[]
            {
                new { role = "system", content = SystemPrompt },
                new { role = "user", content = userMessage }
            }
        };

        var json = JsonSerializer.Serialize(requestBody);
        var url = $"{_baseUrl}/api/chat";

        // Deadline-bounded retry, identical policy to ClaudeLlmClient: transport
        // failures and HTTP 5xx are transient and retried with exponential
        // backoff until RetryWindow elapses. A model REFUSAL (parsed
        // refused=true) is a normal decision and returned; every other failure
        // mode throws LlmClientException.
        var deadline = DateTime.UtcNow + RetryWindow;
        var attempt = 0;
        while (true)
        {
            attempt++;
            HttpResponseMessage response;
            string responseJson;
            try
            {
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                response = await _http.PostAsync(url, content, ct);
                // Read the body inside the SAME try so a mid-body connection drop
                // is retried/surfaced like any other transport failure instead of
                // escaping the loop un-wrapped (past the orchestrator's catch).
                responseJson = await response.Content.ReadAsStringAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw; // the caller cancelled -- propagate, never retry or relabel
            }
            catch (Exception ex)
            {
                // Transport failure (socket/DNS — e.g. Ollama not running), the
                // per-request HttpClient timeout (a TaskCanceledException NOT
                // tied to the caller's ct), or a body-read failure.
                if (DateTime.UtcNow < deadline)
                {
                    _log.LogWarning(ex, "Ollama API request failed (attempt {Attempt}); retrying", attempt);
                    await BackoffAsync(attempt, ct);
                    continue;
                }
                throw new LlmClientException($"Ollama API request failed after {attempt} attempt(s): {ex.Message}", ex);
            }

            var status = (int)response.StatusCode;

            if (response.IsSuccessStatusCode)
            {
                try
                {
                    return ParseChatResponse(responseJson);
                }
                catch (Exception ex)
                {
                    // A 2xx with an unparseable body / missing keys is a format
                    // failure, not a model refusal.
                    _log.LogError(ex, "Failed to parse Ollama response: {Body}", responseJson);
                    throw new LlmClientException($"Failed to parse model response: {ex.Message}", ex);
                }
            }

            // Non-2xx. Retry 5xx (server) within the deadline; fail other codes
            // immediately -- a retry cannot fix a bad request or a missing model.
            var retryable = status >= 500 && status <= 599;
            if (retryable && DateTime.UtcNow < deadline)
            {
                _log.LogWarning("Ollama API {Status}; retrying (attempt {Attempt}): {Body}", status, attempt, responseJson);
                await BackoffAsync(attempt, ct);
                continue;
            }
            _log.LogError("Ollama API error {Status}: {Body}", status, responseJson);
            throw new LlmClientException($"Ollama API error {status}: {response.ReasonPhrase}");
        }
    }

    // Exponential backoff with jitter, capped at 8s: ~250ms, 500ms, 1s, 2s, ...
    private static async Task BackoffAsync(int attempt, CancellationToken ct)
    {
        var baseMs = Math.Min(8000, 250 * (int)Math.Pow(2, Math.Min(attempt - 1, 6)));
        var delayMs = baseMs + Random.Shared.Next(0, 250);
        await Task.Delay(delayMs, ct);
    }

    // Ollama /api/chat (stream=false) envelope: { ..., "message": { "role":
    // "assistant", "content": "<json string>" }, "done": true }. With
    // format="json" the content is itself a JSON document carrying our four
    // required keys. Two-stage parse: envelope -> message.content -> decision.
    private static LlmDecision ParseChatResponse(string responseJson)
    {
        using var envelope = JsonDocument.Parse(responseJson);

        if (!envelope.RootElement.TryGetProperty("message", out var message) ||
            !message.TryGetProperty("content", out var contentElement))
        {
            throw new InvalidOperationException("Ollama response contained no message.content.");
        }

        var content = contentElement.GetString();
        if (string.IsNullOrWhiteSpace(content))
        {
            throw new InvalidOperationException("Ollama message.content was empty.");
        }

        using var inner = JsonDocument.Parse(content);
        var root = inner.RootElement;

        var refused = root.GetProperty("refused").GetBoolean();
        var sql = root.GetProperty("sql").GetString() ?? "";
        var plan = root.GetProperty("plan").GetString() ?? "";
        var refusalReason = root.GetProperty("refusal_reason").GetString() ?? "";

        return new LlmDecision(
            Refused: refused,
            Sql: refused ? null : (sql.Length > 0 ? sql : null),
            RefusalReason: refused ? refusalReason : null,
            PlanText: plan
        );
    }
}
