// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ASP.NET Core host wiring for the agent pipeline; see README service notes:
// https://yuruna.link/4286c679-0007
using Npgsql;
using TextToSqlUi.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();

// --- REGION: PostgreSQL data source
// No credential is committed; the read-only role's password is created for each
// deployment (see README). Connection string priority:
//   1. env TEXT2SQL_PG_CONN  (complete string; the pod's Secret supplies the password)
//   2. configuration ConnectionStrings:Postgres (user secrets, ConnectionStrings__Postgres)
//   3. env TEXT2SQL_PG_PASSWORD  (the role's password alone, for PostgreSQL on localhost)
// Startup fails when none is set.

var pgConn = PostgresConnectionString.Resolve(
    Environment.GetEnvironmentVariable(PostgresConnectionString.ConnectionVariable),
    builder.Configuration[PostgresConnectionString.ConfigurationKey],
    Environment.GetEnvironmentVariable(PostgresConnectionString.PasswordVariable));

var dsBuilder = new NpgsqlDataSourceBuilder(pgConn);
builder.Services.AddSingleton(dsBuilder.Build());

// --- REGION: Agent stack
builder.Services.AddSingleton<SchemaCatalog>();
builder.Services.AddSingleton<SqlValidator>();

// Client selection priority:
//   1. USE_LOCAL_MODEL set  -> OllamaLlmClient (local-first, on-device; keeps
//      the schema + question off any third-party API). OLLAMA_HOST / OLLAMA_MODEL
//      override the http://127.0.0.1:11434 + 'localcoder' defaults.
//   2. ANTHROPIC_API_KEY set -> ClaudeLlmClient (hosted).
//   3. otherwise             -> RuleBasedLlmClient (deterministic offline).
var useLocalModel = Environment.GetEnvironmentVariable("USE_LOCAL_MODEL");
var anthropicApiKey = Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY");
if (!string.IsNullOrEmpty(useLocalModel))
    builder.Services.AddSingleton<ILlmClient>(sp =>
        new OllamaLlmClient(
            sp.GetRequiredService<ILogger<OllamaLlmClient>>(),
            Environment.GetEnvironmentVariable("OLLAMA_HOST"),
            Environment.GetEnvironmentVariable("OLLAMA_MODEL")));
else if (!string.IsNullOrEmpty(anthropicApiKey))
    builder.Services.AddSingleton<ILlmClient>(sp =>
        new ClaudeLlmClient(
            anthropicApiKey,
            sp.GetRequiredService<ILogger<ClaudeLlmClient>>()));
else
    builder.Services.AddSingleton<ILlmClient, RuleBasedLlmClient>();

builder.Services.AddSingleton<AgentOrchestrator>();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseRequestLocalization(new RequestLocalizationOptions()
    .SetDefaultCulture("en-US")
    .AddSupportedCultures("en-US", "pt-BR", "zh-CN", "he-IL")
    .AddSupportedUICultures("en-US", "pt-BR", "zh-CN", "he-IL"));
app.UseStaticFiles();
app.UseRouting();
app.UseAuthorization();
app.MapRazorPages();

app.Run();
