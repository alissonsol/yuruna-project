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
)
{
    public LlmDecision Validate()
    {
        if (Refused ? string.IsNullOrWhiteSpace(RefusalReason) || !string.IsNullOrWhiteSpace(Sql)
                    : string.IsNullOrWhiteSpace(Sql) || !string.IsNullOrWhiteSpace(RefusalReason))
            throw new LlmClientException(ServiceMessages.Get("InvalidDecision"));
        return this;
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
