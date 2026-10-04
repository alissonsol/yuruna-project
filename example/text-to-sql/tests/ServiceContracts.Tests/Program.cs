// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
using System.Diagnostics;
using System.Net;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using TextToSqlUi.Services;

var assertions = 0;
void Check(bool value, string message) { assertions++; if (!value) throw new Exception(message); }
if (args.Contains("--schema-index"))
{
    await using var ds = NpgsqlDataSource.Create("Host=127.0.0.1;Port=1;Username=fixture;Database=fixture");
    var catalog = new SchemaCatalog(ds, NullLogger<SchemaCatalog>.Instance);
    var tables = Enumerable.Range(0, 2000).Select(i => new TableInfo("table" + i, "")).ToList();
    tables[0].FkOut.Add(("table1999", "id->table1999.id"));
    tables[0].FkOut.Add(("table1999", "other->table1999.id"));
    foreach (var table in tables) table.FreezeSearchBlob();
    typeof(SchemaCatalog).GetField("_cache", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(catalog, Task.FromResult<IReadOnlyList<TableInfo>>(tables));
    var first = await catalog.GetRelevantSchemaAsync("table0", 1);
    var second = await catalog.GetRelevantSchemaAsync("table0", 1);
    Check(first.Tables.Select(t => t.Name).SequenceEqual(new[] { "table0", "table1999" }), "FK expansion changed order or duplication");
    Check(first.FormattedPrompt == second.FormattedPrompt, "Cached lookup changed schema text");
    Console.WriteLine($"Schema index: {assertions} assertions passed on 2000 tables.");
    return;
}
foreach (var sql in new string?[] { null, "", "   " })
{
    foreach (var type in new[] { typeof(ClaudeLlmClient), typeof(OllamaLlmClient) })
    {
        var input = new { refused = false, sql, plan = "test", refusal_reason = "" };
        var payload = type == typeof(ClaudeLlmClient)
            ? JsonSerializer.Serialize(new { content = new[] { new { type = "tool_use", name = "generate_sql", input } } })
            : JsonSerializer.Serialize(new { message = new { content = JsonSerializer.Serialize(input) } });
        var method = type.GetMethod(type == typeof(ClaudeLlmClient) ? "ParseToolUseResponse" : "ParseChatResponse", BindingFlags.NonPublic | BindingFlags.Static)!;
        try { ((LlmDecision)method.Invoke(null, new object[] { payload })!).Validate(); Check(false, "Invalid SQL accepted"); }
        catch (LlmClientException) { assertions++; }
        catch (TargetInvocationException e) when (e.InnerException is LlmClientException) { assertions++; }
    }
}
Check(new LlmDecision(false, "SELECT 1", null, "test").Validate().Sql == "SELECT 1", "Valid decision");
Check(new LlmDecision(true, null, "Not supported", "test").Validate().Refused, "Valid refusal");
try { new LlmDecision(true, "SELECT 1", "No", "").Validate(); Check(false, "Contradictory refusal"); }
catch (LlmClientException) { assertions++; }
Check(SqlValidator.MaximumPlanRows("[{\"Plan\":{\"Plan Rows\":200,\"Plans\":[{\"Plan Rows\":5000000}]}}]") == 5000000, "Child estimate must not be hidden by LIMIT");
foreach (var bad in new[] { "[]", "{}", "[{\"Plan\":{}}]", "[{\"Plan\":{\"Plan Rows\":-1}}]" })
{
    try { SqlValidator.MaximumPlanRows(bad); Check(false, "Malformed plan accepted"); }
    catch (JsonException) { assertions++; }
}
foreach (var mode in new[] { "hung", "retry" })
{
    using var handler = new FixtureHandler(mode);
    using var http = new HttpClient(handler);
    var watch = Stopwatch.StartNew();
    LlmClientException? expired = null;
    try { await LlmHttpRetry.PostAsync(http, "http://fixture/", "{}", TimeSpan.FromMilliseconds(80), true, default, "fixture-llm"); Check(false, "Deadline ignored"); }
    catch (LlmClientException ex) { assertions++; expired = ex; }
    Check(watch.Elapsed < TimeSpan.FromSeconds(1), "Total retry budget exceeded");
    Check(handler.Calls == 1, "Request started after budget");
    Check(mode != "retry" || handler.Content!.Disposed, "Response body not disposed");
    // The failure keeps what the loop learned instead of reporting only a deadline.
    var expiry = expired!.Failure!;
    Check(expiry is { BudgetExpired: true, Dependency: "fixture-llm", Host: "fixture", Attempts: 1 }, "Budget expiry lost its identity");
    Check(expiry.Elapsed >= TimeSpan.FromMilliseconds(60), "Elapsed time not recorded");
    if (mode == "hung")
        Check(expiry.LastErrorKind == LlmFailureKind.Cancelled && expiry.LastStatusCode is null && expired.InnerException is OperationCanceledException,
            "A first attempt cut off by the budget must report cancelled");
    else
        Check(expiry.LastErrorKind == LlmFailureKind.HttpStatus && expiry.LastStatusCode == 503 &&
            expired.InnerException is HttpRequestException { StatusCode: HttpStatusCode.ServiceUnavailable },
            "The last HTTP status must survive the deadline");
    Check(expired.Message.Contains("fixture-llm") && expired.Message.Contains(expiry.LastErrorText), "The message must name the dependency and the last error");
}
// Errors that retrying cannot fix stop at once; each keeps its status, and a URL's credentials and query never reach the failure.
foreach (var (mode, retryRateLimit, kind, status, spendsBudget) in new[]
{
    ("bad-request", true, LlmFailureKind.HttpStatus, 400, false),
    ("rate-limit", false, LlmFailureKind.RateLimit, 429, false),
    ("rate-limit", true, LlmFailureKind.RateLimit, 429, true),
})
{
    using var handler = new FixtureHandler(mode);
    using var http = new HttpClient(handler);
    var watch = Stopwatch.StartNew();
    LlmClientException? raised = null;
    try
    {
        await LlmHttpRetry.PostAsync(http, "http://user:secret@fixture:8443/v1?key=querysecret", "{}",
            spendsBudget ? TimeSpan.FromMilliseconds(80) : TimeSpan.FromSeconds(5), retryRateLimit, default, "fixture-llm");
        Check(false, $"{mode} accepted");
    }
    catch (LlmClientException ex) { assertions++; raised = ex; }
    var failure = raised!.Failure!;
    Check(failure.LastErrorKind == kind && failure.LastStatusCode == status && failure.BudgetExpired == spendsBudget && failure.Host == "fixture:8443",
        $"{mode} lost its kind, status or host");
    Check(raised.InnerException is HttpRequestException { StatusCode: var seen } && (int?)seen == status, $"{mode} lost its inner exception");
    if (!spendsBudget)
    {
        Check(failure.Attempts == 1 && handler.Calls == 1 && watch.Elapsed < TimeSpan.FromSeconds(2), $"{mode} was retried");
        Check(raised.Message.Contains(status.ToString()), $"{mode} message lost the status");
    }
    var text = raised + failure.ToString();
    Check(!text.Contains("secret") && !text.Contains("querysecret"), $"{mode} leaked URL credentials");
}
using (var handler = new FixtureHandler("transport"))
using (var http = new HttpClient(handler))
{
    LlmClientException? raised = null;
    try { await LlmHttpRetry.PostAsync(http, "http://fixture/", "{}", TimeSpan.FromMilliseconds(80), true, default, "fixture-llm"); Check(false, "Transport failure accepted"); }
    catch (LlmClientException ex) { assertions++; raised = ex; }
    Check(raised!.Failure is { LastErrorKind: LlmFailureKind.Transport, LastStatusCode: null, BudgetExpired: true, Attempts: 1 } &&
        raised.InnerException is HttpRequestException { Message: "fixture connection refused" }, "A transport failure must survive the deadline with its exception");
}
using (var http = new HttpClient(new FixtureHandler("hung")) { Timeout = TimeSpan.FromMilliseconds(30) })
{
    var watch = Stopwatch.StartNew();
    LlmClientException? raised = null;
    try { await LlmHttpRetry.PostAsync(http, "http://fixture/", "{}", TimeSpan.FromMilliseconds(700), true, default, "fixture-llm"); Check(false, "Timeouts accepted"); }
    catch (LlmClientException ex) { assertions++; raised = ex; }
    Check(raised!.Failure is { LastErrorKind: LlmFailureKind.Timeout, BudgetExpired: true } failure && failure.Attempts >= 1 &&
        raised.InnerException is OperationCanceledException, "A per-request timeout must be reported as one, not as the budget");
    Check(watch.Elapsed < TimeSpan.FromSeconds(3), "Timeouts overran the budget");
}
// Intermediate failures are logged, not swallowed, and a call that recovers reports what recovery cost.
using (var handler = new FixtureHandler("flaky"))
using (var http = new HttpClient(handler))
{
    var log = new CapturingLogger();
    var recovered = await LlmHttpRetry.PostAsync(http, "http://fixture/", "{}", TimeSpan.FromSeconds(10), true, default, "fixture-llm", log);
    Check(recovered is { Attempts: 3, Dependency: "fixture-llm", Host: "fixture" } && recovered.Body.Contains("recovered") && recovered.Elapsed > TimeSpan.Zero, "A recovered call must report its attempts");
    var warnings = log.Entries.Where(e => e.Level == LogLevel.Warning).ToList();
    Check(warnings.Count == 2, "Each failed attempt must be logged");
    Check(warnings.Select(w => w.State["Attempt"]).SequenceEqual(new object?[] { 1, 2 }) &&
        warnings.All(w => (string?)w.State["Dependency"] == "fixture-llm" && ((string?)w.State["LastError"])!.StartsWith("http-status 503")),
        "Attempt log entries lost their dependency or last error");
}
using (var http = new HttpClient(new FixtureHandler("retry")))
using (var cancel = new CancellationTokenSource(100))
{
    try { await LlmHttpRetry.PostAsync(http, "http://fixture/", "{}", TimeSpan.FromSeconds(5), true, cancel.Token); Check(false, "Cancellation during backoff lost"); }
    catch (OperationCanceledException) when (cancel.IsCancellationRequested) { assertions++; }
}
using (var http = new HttpClient(new FixtureHandler("hung")))
using (var cancel = new CancellationTokenSource(20))
{
    try { await LlmHttpRetry.PostAsync(http, "http://fixture/", "{}", TimeSpan.FromSeconds(5), true, cancel.Token); Check(false, "Caller cancellation lost"); }
    catch (OperationCanceledException) when (cancel.IsCancellationRequested) { assertions++; }
}
var cfg = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Agent:ExplainRefuseRows"] = "1000" }).Build();
await using (var unavailable = NpgsqlDataSource.Create("Host=127.0.0.1;Port=1;Username=fixture;Database=fixture;Timeout=1"))
{
    var validator = new SqlValidator(unavailable, NullLogger<SqlValidator>.Instance, cfg);
    Check((await validator.ExplainAsync("SELECT 1")).ParseFailed, "Connection error must become a gate failure");
    try { await validator.ExplainAsync("SELECT 1", new CancellationToken(true)); Check(false, "Canceled database operation accepted"); }
    catch (OperationCanceledException) { assertions++; }
    var catalog = new SchemaCatalog(unavailable, NullLogger<SchemaCatalog>.Instance);
    var first = catalog.GetAllAsync(); try { await first; } catch (NpgsqlException) { }
    var second = catalog.GetAllAsync(); try { await second; } catch (NpgsqlException) { }
    Check(!ReferenceEquals(first, second), "Failed cache reused");
}
var cultureBefore = System.Globalization.CultureInfo.CurrentUICulture;
foreach (var tag in new[] { "en-US", "pt-BR", "zh-CN", "he-IL" })
{
    System.Globalization.CultureInfo.CurrentUICulture = System.Globalization.CultureInfo.GetCultureInfo(tag);
    foreach (var key in new[] { "InvalidDecision", "RetryDeadline", "PlanMissing", "PlanRowsInvalid", "ApiError", "ParseError" })
        Check(!string.IsNullOrWhiteSpace(ServiceMessages.Get(key, "503", "fixture", "timeout", "anthropic")), "Missing localized service message");
    if (tag != "en-US") Check(ServiceMessages.Get("InvalidDecision") != "Model response has an invalid SQL/refusal decision.", "Translation fell back to English");
    // Every locale reports the attempts, elapsed time, last error and dependency the retry loop learned.
    var deadline = ServiceMessages.Get("RetryDeadline", 3, 90012, "http-status 503", "anthropic");
    Check(new[] { "3", "90012", "http-status 503", "anthropic" }.All(deadline.Contains), $"{tag} deadline message lost a detail");
}
System.Globalization.CultureInfo.CurrentUICulture = cultureBefore;
foreach (var client in new IDisposable[] { new ClaudeLlmClient("fixture", NullLogger<ClaudeLlmClient>.Instance), new OllamaLlmClient(NullLogger<OllamaLlmClient>.Instance) })
{
    var http = (HttpClient)client.GetType().GetField("_http", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(client)!;
    client.Dispose();
    try { await http.GetAsync("http://127.0.0.1:1"); Check(false, "Owned client not disposed"); }
    catch (ObjectDisposedException) { assertions++; }
}
// A response that arrives but cannot be used reports what getting it cost, through the real clients.
foreach (var (client, dependency, host) in new (ILlmClient, string, string)[]
{
    (new ClaudeLlmClient("fixture-key", NullLogger<ClaudeLlmClient>.Instance), "anthropic", "api.anthropic.com"),
    (new OllamaLlmClient(NullLogger<OllamaLlmClient>.Instance, "http://user:secret@127.0.0.1:11434/?key=querysecret"), "ollama", "127.0.0.1:11434"),
})
{
    var field = client.GetType().GetField("_http", BindingFlags.NonPublic | BindingFlags.Instance)!;
    ((HttpClient)field.GetValue(client)!).Dispose();
    field.SetValue(client, new HttpClient(new FixtureHandler("garbage")));
    LlmClientException? raised = null;
    try { await client.GenerateSqlAsync("question", "schema"); Check(false, $"{dependency} accepted a garbage response"); }
    catch (LlmClientException ex) { assertions++; raised = ex; }
    Check(raised!.Failure is { LastErrorKind: LlmFailureKind.Parse, Attempts: 1, BudgetExpired: false, LastStatusCode: null } failure &&
        failure.Dependency == dependency && failure.Host == host && raised.InnerException is not null, $"{dependency} parse failure lost its detail");
    var text = raised.ToString();
    Check(!text.Contains("fixture-key") && !text.Contains("secret"), $"{dependency} leaked a credential");
    ((IDisposable)client).Dispose();
}
// The orchestrator logs a failed model call once with everything it learned, keeps it on the run,
// and leaves a caller's cancellation alone.
{
    await using var ds = NpgsqlDataSource.Create("Host=127.0.0.1;Port=1;Username=fixture;Database=fixture;Timeout=1");
    var table = new TableInfo("customer", "");
    table.FreezeSearchBlob();
    var catalog = new SchemaCatalog(ds, NullLogger<SchemaCatalog>.Instance);
    typeof(SchemaCatalog).GetField("_cache", BindingFlags.NonPublic | BindingFlags.Instance)!
        .SetValue(catalog, Task.FromResult<IReadOnlyList<TableInfo>>(new[] { table }));
    var validator = new SqlValidator(ds, NullLogger<SqlValidator>.Instance, cfg);
    var failure = new LlmFailure("fixture-llm", "fixture:8443", LlmFailureKind.HttpStatus, 3, TimeSpan.FromMilliseconds(90012), 503, true);
    var inner = new HttpRequestException("HTTP 503 (Service Unavailable) from fixture-llm", null, HttpStatusCode.ServiceUnavailable);
    var log = new CapturingLogger<AgentOrchestrator>();
    var run = await new AgentOrchestrator(catalog, validator, new FailingLlm(new LlmClientException("deadline", failure, inner)), ds, log, cfg)
        .RunAsync("how many customers");
    Check(!run.Succeeded && run.Error is not null && run.Failure == failure, "The run lost the structured failure");
    Check(run.Steps[^1] is { Stage: "SQL generation", Status: "fail", Note: "deadline" }, "The timeline lost the failed step");
    var entry = log.Entries.Single(e => e.Level == LogLevel.Error);
    Check(entry.Error is LlmClientException { InnerException: var seen } && ReferenceEquals(seen, inner), "The log lost the last inner exception");
    Check((string?)entry.State["Dependency"] == "fixture-llm" && (string?)entry.State["Host"] == "fixture:8443" && (string?)entry.State["LastError"] == "http-status 503" &&
        (int)entry.State["Attempts"]! == 3 && (long)entry.State["ElapsedMs"]! == 90012 && (bool)entry.State["BudgetExpired"]!, "The log lost a field of the failure");
    var untouched = log.Entries.Count;
    using var source = new CancellationTokenSource();
    try { await new AgentOrchestrator(catalog, validator, new CancelingLlm(source), ds, log, cfg).RunAsync("how many customers", source.Token); Check(false, "Cancellation reported as a failed run"); }
    catch (OperationCanceledException) { assertions++; }
    Check(log.Entries.Count == untouched, "Cancellation was logged as a failure");
}
// The connection string comes from the environment, then configuration, then the role's password alone;
// nothing in the repository supplies a credential.
{
    const string environmental = "Host=env.fixture;Username=u;Database=d";
    const string configured = "Host=cfg.fixture;Username=u;Database=d";
    Check(PostgresConnectionString.Resolve(environmental, configured, "pw") == environmental, "The environment connection string must win");
    Check(PostgresConnectionString.Resolve(null, configured, "pw") == configured, "Configuration must beat the password alone");
    foreach (var blank in new string?[] { null, "", "   " })
    {
        Check(PostgresConnectionString.Resolve(blank, configured, "pw") == configured, "A blank environment value must count as unset");
        Check(new NpgsqlConnectionStringBuilder(PostgresConnectionString.Resolve(blank, blank, "pw")).Host == "localhost", "A blank configuration value must count as unset");
    }
    // The password alone selects the read-only role on localhost and survives any character in it, so a
    // password cannot add or replace connection keywords.
    foreach (var password in new[] { "plain", "semi;colon", "equals=sign", "it's", "say \"hi\"", "two words", " padded ", "a;b=c'd \"e\" f",
        "x;Host=elsewhere;Username=postgres", "Password=other", "100%\\{}" })
    {
        var parsed = new NpgsqlConnectionStringBuilder(PostgresConnectionString.Resolve(null, null, password));
        Check(parsed.Password == password && parsed.Host == "localhost" && parsed.Username == "yuruna_agent_ro" && parsed.Database == "yuruna_demo",
            $"A {password.Length}-character password changed the connection it was given to");
        await using var accepted = new NpgsqlDataSourceBuilder(PostgresConnectionString.Resolve(null, null, password)).Build();
        assertions++;
    }
    // With no source the failure names every option and holds no password-shaped text.
    foreach (var blank in new string?[] { null, "", "   " })
    {
        try { PostgresConnectionString.Resolve(blank, blank, blank); Check(false, "A connection with no source was accepted"); }
        catch (InvalidOperationException ex)
        {
            assertions++;
            Check(new[] { "TEXT2SQL_PG_CONN", "ConnectionStrings:Postgres", "TEXT2SQL_PG_PASSWORD" }.All(ex.Message.Contains), "The failure must name all three options");
            Check(!Regex.IsMatch(ex.Message, "(?i)password=|PASSWORD '"), "The failure must not hold a password");
        }
    }

    // The well-known demo password is built from two halves so that this file does not hold it either.
    var demoPassword = "agent_demo_" + "password";
    static string SourceFolder([System.Runtime.CompilerServices.CallerFilePath] string path = "") => Path.GetDirectoryName(path)!;
    var example = Path.GetFullPath(Path.Combine(SourceFolder(), "..", ".."));
    var textFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".cs", ".json", ".yml", ".yaml", ".md", ".sh", ".sql", ".ps1", ".psm1", ".cshtml", ".resx", ".csproj", ".py" };
    var shipped = Directory.EnumerateFiles(example, "*", SearchOption.AllDirectories)
        .Where(file => !file.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any(part => part is "bin" or "obj"))
        .Where(file => textFiles.Contains(Path.GetExtension(file)) || Path.GetFileName(file) == "Dockerfile")
        .ToList();
    Check(shipped.Count > 20 && shipped.Any(file => Path.GetFileName(file) == "Program.cs" && file.Contains("text-to-sql-ui")),
        "The credential scan did not find the example; the layout changed");
    foreach (var file in shipped)
    {
        var text = File.ReadAllText(file);
        var name = Path.GetRelativePath(example, file);
        Check(!text.Contains(demoPassword, StringComparison.OrdinalIgnoreCase), $"{name} carries the well-known demo password");
        // Fixtures in the tests spell connection strings out; every other file must not.
        var isTest = name.StartsWith("tests" + Path.DirectorySeparatorChar, StringComparison.Ordinal);
        Check(isTest || !Regex.IsMatch(text, @"(?i)\bPassword=[A-Za-z0-9_.~+/-]{3,}"), $"{name} carries a literal connection-string password");
    }
}
var database = Environment.GetEnvironmentVariable("SERVICE_CONTRACT_DATABASE");
if (!string.IsNullOrEmpty(database))
{
    await using var ds = NpgsqlDataSource.Create(database);
    var validator = new SqlValidator(ds, NullLogger<SqlValidator>.Instance, cfg);
    Check((await validator.ExplainAsync("SELECT g FROM generate_series(1,50000) g LIMIT 200")) is { Allowed: false, ParseFailed: false }, "Live LIMIT hides expensive input");
    Check((await validator.ExplainAsync("SELECT 1" )).Allowed, "Cheap query refused");
    Check((await validator.ExplainAsync("SELECT * FROM missing_fixture_table")).ParseFailed, "SQL error escaped");
    Check((await validator.ExplainAsync("SELECT 1")).Allowed, "Failed transaction poisoned next request");
    var catalog = new SchemaCatalog(ds, NullLogger<SchemaCatalog>.Instance);
    var first = catalog.GetAllAsync(); var second = catalog.GetAllAsync();
    await Task.WhenAll(first, second);
    Check(ReferenceEquals(first, second) && ReferenceEquals(first, catalog.GetAllAsync()), "Concurrent/successful catalog not cached");
}
Console.WriteLine($"Service contracts: {assertions} assertions passed; live PostgreSQL: {!string.IsNullOrEmpty(database)}.");

sealed class TrackingContent : StringContent
{
    public bool Disposed { get; private set; }
    public TrackingContent() : base("{}") { }
    protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
}
sealed class FixtureHandler(string mode) : HttpMessageHandler
{
    public int Calls { get; private set; }
    public TrackingContent? Content { get; private set; }
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Calls++;
        if (mode == "hung") await Task.Delay(Timeout.Infinite, ct);
        if (mode == "transport") throw new HttpRequestException("fixture connection refused");
        if (mode == "garbage") return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("not json") };
        if (mode == "flaky" && Calls > 2) return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"note\":\"recovered\"}") };
        Content = new TrackingContent();
        var status = mode switch
        {
            "bad-request" => HttpStatusCode.BadRequest,
            "rate-limit" => HttpStatusCode.TooManyRequests,
            _ => HttpStatusCode.ServiceUnavailable,
        };
        return new HttpResponseMessage(status) { Content = Content };
    }
}
sealed class FailingLlm(Exception error) : ILlmClient
{
    public Task<LlmDecision> GenerateSqlAsync(string question, string schemaSlice, CancellationToken ct = default) =>
        Task.FromException<LlmDecision>(error);
}
// Cancels the caller's token while "calling the model", as a user abandoning the request would.
sealed class CancelingLlm(CancellationTokenSource source) : ILlmClient
{
    public Task<LlmDecision> GenerateSqlAsync(string question, string schemaSlice, CancellationToken ct = default)
    {
        source.Cancel();
        ct.ThrowIfCancellationRequested();
        throw new InvalidOperationException("The caller's token was not honored.");
    }
}
record LogEntry(LogLevel Level, string Message, Dictionary<string, object?> State, Exception? Error);
class CapturingLogger : ILogger
{
    public List<LogEntry> Entries { get; } = new();
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(LogLevel logLevel) => true;
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        var values = new Dictionary<string, object?>();
        if (state is IEnumerable<KeyValuePair<string, object?>> pairs) foreach (var pair in pairs) values[pair.Key] = pair.Value;
        Entries.Add(new LogEntry(logLevel, formatter(state, exception), values, exception));
    }
}
sealed class CapturingLogger<T> : CapturingLogger, ILogger<T> { }
