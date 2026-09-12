// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Pluggable seam between the orchestrator and an LLM implementation; see
// README service notes: https://yuruna.link/4286c679-0007

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
