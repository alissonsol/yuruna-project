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

// The last error a model call ended with. Parse means the service answered but
// the answer could not be used; Cancelled means the retry budget cut off a request
// before the service said anything. A caller's own cancellation is never a failure
// kind: it propagates as OperationCanceledException.
public enum LlmFailureKind { Timeout, Transport, HttpStatus, RateLimit, Cancelled, Parse }

// Why a model call failed, kept as data so a log line, the run timeline and
// telemetry report the same facts without parsing a message.
public sealed record LlmFailure(
    string Dependency,           // logical service name, for example "anthropic"
    string? Host,                // host[:port] only; a URL's credentials, path and query never get here
    LlmFailureKind LastErrorKind,
    int Attempts,                // requests started, including one the budget cut off
    TimeSpan Elapsed,
    int? LastStatusCode,         // HTTP status of the last response the service sent, if any
    bool BudgetExpired)          // the retry budget ran out; false when the call failed outright
{
    // A short token, not localized (like a status code), for messages and log lines.
    public string LastErrorText
    {
        get
        {
            var token = LastErrorKind switch
            {
                LlmFailureKind.Timeout => "timeout",
                LlmFailureKind.Transport => "transport",
                LlmFailureKind.HttpStatus => "http-status",
                LlmFailureKind.RateLimit => "rate-limit",
                LlmFailureKind.Cancelled => "cancelled",
                _ => "parse",
            };
            return LastStatusCode is { } status ? $"{token} {status}" : token;
        }
    }
}

// Thrown by ClaudeLlmClient for transport / HTTP / parse failures -- as opposed
// to a legitimate model refusal, which is returned as an LlmDecision. Lets the
// orchestrator render an error step + run error, and enables retry/monitoring,
// instead of mislabeling infrastructure trouble as the model declining.
// Failure is set when a model call was attempted; InnerException is the last
// error that call observed.
public sealed class LlmClientException : Exception
{
    public LlmClientException(string message) : base(message) { }
    public LlmClientException(string message, Exception inner) : base(message, inner) { }
    public LlmClientException(string message, LlmFailure failure, Exception? inner = null) : base(message, inner) => Failure = failure;

    public LlmFailure? Failure { get; }
}
