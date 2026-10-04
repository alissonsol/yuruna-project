// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ILlmClient backed by the Anthropic Messages API; see README service notes:
// https://yuruna.link/4286c679-0007

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TextToSqlUi.Services;

public sealed class ClaudeLlmClient : ILlmClient, IDisposable
{
    private readonly HttpClient _http;
    private readonly ILogger<ClaudeLlmClient> _log;
    private readonly string _model;

    private const string AnthropicApiUrl = "https://api.anthropic.com/v1/messages";
    private const string Dependency = "anthropic";
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
3. Return a safe, read-only SELECT statement -- or refuse if you cannot.

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

    public void Dispose() => _http.Dispose();

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

        var result = await LlmHttpRetry.PostAsync(_http, AnthropicApiUrl, json, RetryWindow, true, ct, Dependency, _log);
        try
        {
            return ParseToolUseResponse(result.Body).Validate();
        }
        catch (Exception ex)
        {
            // The caller logs this once with the full failure; the exception keeps the parse error.
            throw result.ParseFailure(ex);
        }
    }

    private static LlmDecision ParseToolUseResponse(string responseJson)
    {
        using var doc = JsonDocument.Parse(responseJson);
        var root = doc.RootElement;

        foreach (var block in root.GetProperty("content").EnumerateArray())
        {
            if (block.GetProperty("type").GetString() != "tool_use" ||
                block.GetProperty("name").GetString() != "generate_sql") continue;

            var input = block.GetProperty("input");

            var refused = input.GetProperty("refused").GetBoolean();
            var sql = input.GetProperty("sql").GetString() ?? "";
            var plan = input.GetProperty("plan").GetString() ?? "";
            var refusalReason = input.GetProperty("refusal_reason").GetString() ?? "";

            return new LlmDecision(
                Refused: refused,
                Sql: sql,
                RefusalReason: refusalReason,
                PlanText: plan
            );
        }

        // No tool_use block: the model returned an unexpected shape. This is a
        // FAILURE (surfaced as an error by the caller), not a model refusal.
        throw new InvalidOperationException("Model response contained no tool_use block.");
    }
}
