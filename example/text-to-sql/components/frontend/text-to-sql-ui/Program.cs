// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// Agentic Text-to-SQL UI — minimal ASP.NET Core Razor Pages host wiring
// Razor Pages, the read-only Npgsql DataSource, and the agent services;
// offline rule-based LLM by default, ClaudeLlmClient when
// ANTHROPIC_API_KEY is set. See the README service notes —
// https://yuruna.link/text-to-sql#service-notes
// ---------------------------------------------------------------------------
using Npgsql;
using TextToSqlUi.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();

// ── Postgres data source ───────────────────────────────────────────────────
// Connection string priority:
//   1. env TEXT2SQL_PG_CONN  (preferred — see README)
//   2. appsettings:ConnectionStrings:Postgres
//   3. localhost default

var pgConn =
    Environment.GetEnvironmentVariable("TEXT2SQL_PG_CONN")
    ?? builder.Configuration.GetConnectionString("Postgres")
    ?? "Host=localhost;Username=yuruna_agent_ro;Password=agent_demo_password;Database=yuruna_demo";

var dsBuilder = new NpgsqlDataSourceBuilder(pgConn);
builder.Services.AddSingleton(dsBuilder.Build());

// ── Agent stack ────────────────────────────────────────────────────────────
builder.Services.AddSingleton<SchemaCatalog>();
builder.Services.AddSingleton<SqlValidator>();

// Use ClaudeLlmClient when ANTHROPIC_API_KEY is set; fall back to the
// deterministic rule-based client so the example runs offline without a key.
var anthropicApiKey = Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY");
if (!string.IsNullOrEmpty(anthropicApiKey))
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