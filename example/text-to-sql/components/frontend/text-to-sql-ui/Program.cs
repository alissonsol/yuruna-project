// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ASP.NET Core host wiring for the agent pipeline; see README service notes:
// https://yuruna.link/4286c679-0007
using Npgsql;
using TextToSqlUi.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();

// --- REGION: PostgreSQL data source
// Connection string priority:
//   1. env TEXT2SQL_PG_CONN  (preferred -- see README)
//   2. appsettings:ConnectionStrings:Postgres
//   3. localhost default

var pgConn =
    Environment.GetEnvironmentVariable("TEXT2SQL_PG_CONN")
    ?? builder.Configuration.GetConnectionString("Postgres")
    ?? "Host=localhost;Username=yuruna_agent_ro;Password=agent_demo_password;Database=yuruna_demo";

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

app.UseStaticFiles();
app.UseRouting();
app.UseAuthorization();
app.MapRazorPages();

app.Run();
