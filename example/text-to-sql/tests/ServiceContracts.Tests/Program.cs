// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
using System.Diagnostics;
using System.Net;
using System.Reflection;
using System.Text.Json;
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
    try { await LlmHttpRetry.PostAsync(http, "http://fixture/", "{}", TimeSpan.FromMilliseconds(80), true, default); Check(false, "Deadline ignored"); }
    catch (LlmClientException) { assertions++; }
    Check(watch.Elapsed < TimeSpan.FromSeconds(1), "Total retry budget exceeded");
    Check(handler.Calls == 1, "Request started after budget");
    Check(mode != "retry" || handler.Content!.Disposed, "Response body not disposed");
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
        Check(!string.IsNullOrWhiteSpace(ServiceMessages.Get(key, "503", "fixture")), "Missing localized service message");
    if (tag != "en-US") Check(ServiceMessages.Get("InvalidDecision") != "Model response has an invalid SQL/refusal decision.", "Translation fell back to English");
}
System.Globalization.CultureInfo.CurrentUICulture = cultureBefore;
foreach (var client in new IDisposable[] { new ClaudeLlmClient("fixture", NullLogger<ClaudeLlmClient>.Instance), new OllamaLlmClient(NullLogger<OllamaLlmClient>.Instance) })
{
    var http = (HttpClient)client.GetType().GetField("_http", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(client)!;
    client.Dispose();
    try { await http.GetAsync("http://127.0.0.1:1"); Check(false, "Owned client not disposed"); }
    catch (ObjectDisposedException) { assertions++; }
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
        Content = new TrackingContent();
        return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) { Content = Content };
    }
}
