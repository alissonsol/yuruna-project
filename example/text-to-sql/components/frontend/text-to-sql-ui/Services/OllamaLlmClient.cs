// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ILlmClient backed by a local Ollama server; see README service notes:
// https://yuruna.link/4286c679-0007

using System.Text;
using System.Text.Json;

namespace TextToSqlUi.Services;

public sealed class OllamaLlmClient : ILlmClient, IDisposable
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
    // tool-use schema -- Ollama's format:"json" mode guarantees valid JSON, and
    // the required keys are spelled out here so the parse below is total.
    private static readonly string SystemPrompt = @"
You are a read-only SQL agent for a SaaS subscription analytics database.

Your job:
1. Receive a natural language question and a schema slice.
2. Reason step by step about which tables and joins are needed.
3. Return a safe, read-only SELECT statement -- or refuse if you cannot.

Hard rules:
- ONLY generate SELECT statements. Never INSERT, UPDATE, DELETE, DROP, TRUNCATE, ALTER, GRANT.
- NEVER select PII columns: customer.email, customer.phone, or any column ending in _pii.
- If the question is ambiguous or outside the schema, refuse honestly.
- If you are not confident, refuse. Do not hallucinate table or column names.
- Always add a LIMIT clause (max 200 rows) unless the query is an aggregate.

Respond with ONLY a single JSON object -- no markdown fences, no prose before or
after -- with EXACTLY these keys:
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

    public void Dispose() => _http.Dispose();

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

        var responseJson = await LlmHttpRetry.PostAsync(_http, url, json, RetryWindow, false, ct);
        try
        {
            return ParseChatResponse(responseJson).Validate();
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to parse model response");
            throw new LlmClientException(ServiceMessages.Get("ParseError", ex.Message), ex);
        }
    }

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
            Sql: sql,
            RefusalReason: refusalReason,
            PlanText: plan
        );
    }
}
