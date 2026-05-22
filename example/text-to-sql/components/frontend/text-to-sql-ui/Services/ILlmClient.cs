// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// ILlmClient — pluggable seam between the orchestrator and a real LLM.
//
// We define two implementations:
//   • RuleBasedLlmClient — deterministic, offline, no API key required.
//     Pattern-matches a handful of canonical questions against the seed
//     data and emits the corresponding SQL. Lets the example run
//     reproducibly without an LLM dependency.
//   • ClaudeLlmClient (sketch, file Services/ClaudeLlmClient.cs) — wired to
//     Anthropic's Messages API with tool-use loop. Activates when
//     ANTHROPIC_API_KEY is set. Left as a clean extension point on purpose.
//
// The seam shape: GenerateSqlAsync takes the question + the FK-expanded
// schema slice and returns either a SQL string OR a refusal with reason.
// ---------------------------------------------------------------------------

namespace TextToSqlUi.Services;

public interface ILlmClient
{
    Task<LlmDecision> GenerateSqlAsync(string question, string schemaSlice, CancellationToken ct = default);
}

public sealed record LlmDecision(
    bool Refused,
    string? Sql,
    string? RefusalReason,
    string? PlanText        // the "thinking" we want to show in the UI
);
