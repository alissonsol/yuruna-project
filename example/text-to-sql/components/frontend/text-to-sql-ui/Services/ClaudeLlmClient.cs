// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// ClaudeLlmClient — production ILlmClient implementation backed by the
// Anthropic Messages API with tool-use for structured output. Activated
// when ANTHROPIC_API_KEY is set; RuleBasedLlmClient is used otherwise.
// Pipeline role and the LlmDecision contract: see the README service
// notes — https://yuruna.link/text-to-sql#service-notes
// ---------------------------------------------------------------------------

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TextToSqlUi.Services;

public sealed class ClaudeLlmClient : ILlmClient
{
    private readonly HttpClient _http;
    private readonly ILogger<ClaudeLlmClient> _log;
    private readonly string _model;

    private const string AnthropicApiUrl = "https://api.anthropic.com/v1/messages";
    private const string AnthropicVersion = "2023-06-01";
    private const string DefaultModel = "claude-opus-4-8";

    // Per-request HTTP timeout + total retry window. The default HttpClient 100s
    // timeout would otherwise be the only bound, so a hung connection could
    // stall the whole run; these cap it and bound the transient-failure retry.
    private static readonly TimeSpan HttpTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan RetryWindow = TimeSpan.FromSeconds(90);

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

Return your response using the generate_sql tool.
In the plan field, show your step-by-step reasoning before arriving at the SQL.
".Trim();

    private static readonly object ToolDefinition = new
    {
        name = "generate_sql",
        description = "Return the SQL query and reasoning for the user's question, or a refusal.",
        input_schema = new
        {
            type = "object",
            properties = new
            {
                plan = new
                {
                    type = "string",
                    description = "Step-by-step reasoning shown in the agent timeline UI."
                },
                sql = new
                {
                    type = "string",
                    description = "Raw SELECT SQL, no markdown fences. Empty string if refused."
                },
                refused = new
                {
                    type = "boolean",
                    description = "True if the question cannot be safely answered."
                },
                refusal_reason = new
                {
                    type = "string",
                    description = "Human-readable reason for refusal. Empty string if not refused."
                }
            },
            required = new[] { "plan", "sql", "refused", "refusal_reason" }
        }
    };

    public ClaudeLlmClient(string apiKey, ILogger<ClaudeLlmClient> log, string? model = null)
    {
        _log = log;
        _model = model ?? DefaultModel;
        _http = new HttpClient { Timeout = HttpTimeout };
        _http.DefaultRequestHeaders.Add("x-api-key", apiKey);
        _http.DefaultRequestHeaders.Add("anthropic-version", AnthropicVersion);
        _http.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));
    }

    public async Task<LlmDecision> GenerateSqlAsync(
        string question, string schemaSlice, CancellationToken ct = default)
    {
        var userMessage = $"Question: {question}\n\nSchema:\n{schemaSlice}";

        var requestBody = new
        {
            model = _model,
            max_tokens = 2048,
            system = SystemPrompt,
            tools = new[] { ToolDefinition },
            tool_choice = new { type = "any" },
            messages = new[]
            {
                new { role = "user", content = userMessage }
            }
        };

        var json = JsonSerializer.Serialize(requestBody, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
        });

        // Deadline-bounded retry: transport failures, HTTP 429, and 5xx are
        // transient and retried with exponential backoff until RetryWindow
        // elapses. A model REFUSAL (a parsed tool_use with refused=true) is a
        // normal decision and returned; every other failure mode throws an
        // LlmClientException so the caller surfaces it as an error (and can
        // retry/monitor) rather than mislabeling infrastructure trouble as the
        // model declining.
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
                response = await _http.PostAsync(AnthropicApiUrl, content, ct);
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
                // Transport failure (socket/DNS), the per-request HttpClient
                // timeout (a TaskCanceledException NOT tied to the caller's ct),
                // or a body-read failure.
                if (DateTime.UtcNow < deadline)
                {
                    _log.LogWarning(ex, "Anthropic API request failed (attempt {Attempt}); retrying", attempt);
                    await BackoffAsync(attempt, ct);
                    continue;
                }
                throw new LlmClientException($"Anthropic API request failed after {attempt} attempt(s): {ex.Message}", ex);
            }

            var status = (int)response.StatusCode;

            if (response.IsSuccessStatusCode)
            {
                try
                {
                    return ParseToolUseResponse(responseJson);
                }
                catch (Exception ex)
                {
                    // A 2xx with an unparseable / tool_use-less body is a format
                    // failure, not a model refusal.
                    _log.LogError(ex, "Failed to parse Anthropic response: {Body}", responseJson);
                    throw new LlmClientException($"Failed to parse model response: {ex.Message}", ex);
                }
            }

            // Non-2xx. Retry 429 (rate limit) and 5xx (server) within the
            // deadline; fail other 4xx (bad request / auth) immediately -- a
            // retry cannot fix those.
            var retryable = status == 429 || (status >= 500 && status <= 599);
            if (retryable && DateTime.UtcNow < deadline)
            {
                _log.LogWarning("Anthropic API {Status}; retrying (attempt {Attempt}): {Body}", status, attempt, responseJson);
                await BackoffAsync(attempt, ct);
                continue;
            }
            _log.LogError("Anthropic API error {Status}: {Body}", status, responseJson);
            throw new LlmClientException($"Anthropic API error {status}: {response.ReasonPhrase}");
        }
    }

    // Exponential backoff with jitter, capped at 8s: ~250ms, 500ms, 1s, 2s, ...
    private static async Task BackoffAsync(int attempt, CancellationToken ct)
    {
        var baseMs = Math.Min(8000, 250 * (int)Math.Pow(2, Math.Min(attempt - 1, 6)));
        var delayMs = baseMs + Random.Shared.Next(0, 250);
        await Task.Delay(delayMs, ct);
    }

    private static LlmDecision ParseToolUseResponse(string responseJson)
    {
        using var doc = JsonDocument.Parse(responseJson);
        var root = doc.RootElement;

        // Find the tool_use block in content array
        foreach (var block in root.GetProperty("content").EnumerateArray())
        {
            if (block.GetProperty("type").GetString() != "tool_use") continue;

            var input = block.GetProperty("input");

            var refused = input.GetProperty("refused").GetBoolean();
            var sql = input.GetProperty("sql").GetString() ?? "";
            var plan = input.GetProperty("plan").GetString() ?? "";
            var refusalReason = input.GetProperty("refusal_reason").GetString() ?? "";

            return new LlmDecision(
                Refused: refused,
                Sql: refused ? null : (sql.Length > 0 ? sql : null),
                RefusalReason: refused ? refusalReason : null,
                PlanText: plan
            );
        }

        // No tool_use block: the model returned an unexpected shape. This is a
        // FAILURE (surfaced as an error by the caller), not a model refusal.
        throw new InvalidOperationException("Model response contained no tool_use block.");
    }
}

// Thrown by ClaudeLlmClient for transport / HTTP / parse failures -- as opposed
// to a legitimate model refusal, which is returned as an LlmDecision. Lets the
// orchestrator render an error step + run error, and enables retry/monitoring,
// instead of mislabeling infrastructure trouble as the model declining.
public sealed class LlmClientException : Exception
{
    public LlmClientException(string message) : base(message) { }
    public LlmClientException(string message, Exception inner) : base(message, inner) { }
}