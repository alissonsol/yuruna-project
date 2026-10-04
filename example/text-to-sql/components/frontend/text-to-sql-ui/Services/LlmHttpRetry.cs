// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
using System.Diagnostics;
using System.Text;

namespace TextToSqlUi.Services;

// A model call that eventually succeeded, with what it cost to get the answer.
internal sealed record LlmHttpResult(string Body, string Dependency, string? Host, int Attempts, TimeSpan Elapsed)
{
    // A response that arrived but could not be used keeps the cost of obtaining it.
    internal LlmClientException ParseFailure(Exception inner) =>
        new(ServiceMessages.Get("ParseError", inner.Message),
            new LlmFailure(Dependency, Host, LlmFailureKind.Parse, Attempts, Elapsed, null, false), inner);
}

internal static class LlmHttpRetry
{
    // dependency is a logical service name chosen by the caller; it, and a host
    // derived from the URL without credentials or query, are what logs and errors
    // may name. A caller's own cancellation propagates as OperationCanceledException;
    // only the retry budget running out becomes an LlmClientException.
    internal static async Task<LlmHttpResult> PostAsync(HttpClient http, string url, string json,
        TimeSpan budget, bool retryRateLimit, CancellationToken ct,
        string dependency = "llm", ILogger? log = null)
    {
        var watch = Stopwatch.StartNew();
        var host = HostOf(url);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(budget);
        var token = deadline.Token;
        var attempt = 0;
        // What the loop has learned. The last error the service or the network reported is
        // kept when the budget then cuts off one more request: it is the more useful fact.
        LlmFailureKind? lastKind = null;
        int? lastStatus = null;
        Exception? lastError = null;

        LlmFailure Snapshot(LlmFailureKind kind, bool budgetExpired) =>
            new(dependency, host, kind, attempt, watch.Elapsed, lastStatus, budgetExpired);
        void Record(LlmFailureKind kind, Exception error, int? status = null)
        {
            lastKind = kind;
            lastStatus = status;
            lastError = error;
        }

        try
        {
            while (true)
            {
                token.ThrowIfCancellationRequested();
                attempt++;
                try
                {
                    using var content = new StringContent(json, Encoding.UTF8, "application/json");
                    using var response = await http.PostAsync(url, content, token);
                    var body = await response.Content.ReadAsStringAsync(token);
                    if (response.IsSuccessStatusCode) return new LlmHttpResult(body, dependency, host, attempt, watch.Elapsed);
                    var status = (int)response.StatusCode;
                    Record(status == 429 ? LlmFailureKind.RateLimit : LlmFailureKind.HttpStatus,
                        new HttpRequestException($"HTTP {status} ({response.ReasonPhrase}) from {dependency}", null, response.StatusCode),
                        status);
                    if (!(status >= 500 && status <= 599 || retryRateLimit && status == 429))
                        throw new LlmClientException(ServiceMessages.Get("ApiError", status, response.ReasonPhrase),
                            Snapshot(lastKind!.Value, false), lastError);
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                catch (HttpRequestException ex) { Record(LlmFailureKind.Transport, ex); }
                catch (IOException ex) { Record(LlmFailureKind.Transport, ex); }
                catch (OperationCanceledException ex) { Record(LlmFailureKind.Timeout, ex); } // Per-request timeout; total budget still applies.
                var delayMs = Math.Min(8000, 250 * (1 << Math.Min(attempt - 1, 5))) + Random.Shared.Next(250);
                log?.LogWarning(
                    "{Dependency} attempt {Attempt} failed ({LastError}: {Error}); retrying in {DelayMs} ms ({ElapsedMs} of {BudgetMs} ms used).",
                    dependency, attempt, Snapshot(lastKind!.Value, false).LastErrorText,
                    $"{lastError!.GetType().Name}: {lastError.Message}", delayMs, watch.ElapsedMilliseconds, (long)budget.TotalMilliseconds);
                await Task.Delay(delayMs, token);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (OperationCanceledException ex)
        {
            var failure = Snapshot(lastKind ?? LlmFailureKind.Cancelled, true);
            throw new LlmClientException(
                ServiceMessages.Get("RetryDeadline", failure.Attempts, (long)failure.Elapsed.TotalMilliseconds,
                    failure.LastErrorText, failure.Dependency),
                failure, lastError ?? ex);
        }
    }

    // Host and port only: a configured URL may carry credentials or a query, which must never reach a log or an error.
    internal static string? HostOf(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Host.Length > 0
            ? (uri.IsDefaultPort ? uri.Host : $"{uri.Host}:{uri.Port}")
            : null;
}
