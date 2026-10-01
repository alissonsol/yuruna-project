// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
using System.Text;

namespace TextToSqlUi.Services;

internal static class LlmHttpRetry
{
    internal static async Task<string> PostAsync(HttpClient http, string url, string json,
        TimeSpan budget, bool retryRateLimit, CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(budget);
        var token = deadline.Token;
        var attempt = 0;
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
                    if (response.IsSuccessStatusCode) return body;
                    var status = (int)response.StatusCode;
                    if (!(status >= 500 && status <= 599 || retryRateLimit && status == 429))
                        throw new LlmClientException(ServiceMessages.Get("ApiError", status, response.ReasonPhrase));
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                catch (HttpRequestException) { }
                catch (IOException) { }
                catch (OperationCanceledException) { } // Per-request timeout; total budget still applies.
                await Task.Delay(Math.Min(8000, 250 * (1 << Math.Min(attempt - 1, 5)))
                    + Random.Shared.Next(250), token);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (OperationCanceledException ex)
        {
            throw new LlmClientException(ServiceMessages.Get("RetryDeadline"), ex);
        }
    }
}
