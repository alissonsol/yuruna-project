// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// ClaudeLlmClient — production ILlmClient implementation backed by the
// Anthropic Messages API with tool-use for structured output.
//
// Activated when ANTHROPIC_API_KEY is set in the environment.
// Falls back to RuleBasedLlmClient when the key is absent.
//
// Pipeline role: "③ SQL Generator (LLM)" in the AgentOrchestrator.
// Returns LlmDecision with:
//   • Sql        — raw SELECT statement (no markdown fences)
//   • PlanText   — Claude's chain-of-thought shown in the UI observer
//   • Refused    — true when Claude cannot map the question to safe SQL
//   • RefusalReason — human-readable reason shown in the timeline
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
    private const string DefaultModel = "claude-opus-4-5";

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
        _http = new HttpClient();
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
            max_tokens = 1024,
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

        HttpResponseMessage response;
        try
        {
            var content = new StringContent(json, Encoding.UTF8, "application/json");
            response = await _http.PostAsync(AnthropicApiUrl, content, ct);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Anthropic API request failed");
            return Refuse($"API request failed: {ex.Message}");
        }

        var responseJson = await response.Content.ReadAsStringAsync(ct);

        if (!response.IsSuccessStatusCode)
        {
            _log.LogError("Anthropic API error {Status}: {Body}", response.StatusCode, responseJson);
            return Refuse($"API error {(int)response.StatusCode}: {response.ReasonPhrase}");
        }

        try
        {
            return ParseToolUseResponse(responseJson);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to parse Anthropic response: {Body}", responseJson);
            return Refuse($"Failed to parse model response: {ex.Message}");
        }
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

        return Refuse("Model did not return a tool_use block.");
    }

    private static LlmDecision Refuse(string reason) =>
        new(true, null, reason, null);
}