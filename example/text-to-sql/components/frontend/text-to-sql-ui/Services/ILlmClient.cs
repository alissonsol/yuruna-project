// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// ILlmClient — pluggable seam between the orchestrator and a real LLM.
// GenerateSqlAsync takes the question + the FK-expanded schema slice and
// returns either a SQL string OR a refusal with reason. Implementations
// (rule-based offline default, Claude tool-use): see the README service
// notes — https://yuruna.link/text-to-sql#service-notes
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
