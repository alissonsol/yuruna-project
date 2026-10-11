// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ASP.NET Core host wiring for the agent pipeline; see README service notes:
// https://yuruna.link/4286c679-0007
using Npgsql;
using TextToSqlUi.Services;

// --- REGION: Initialize application
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();

// --- REGION: PostgreSQL data source
// Credentials and connection-source precedence: https://yuruna.link/4286c679-0004
var pgConn = PostgresConnectionString.Resolve(
    Environment.GetEnvironmentVariable(PostgresConnectionString.ConnectionVariable),
    builder.Configuration[PostgresConnectionString.ConfigurationKey],
    Environment.GetEnvironmentVariable(PostgresConnectionString.PasswordVariable));

var dsBuilder = new NpgsqlDataSourceBuilder(pgConn);
builder.Services.AddSingleton(dsBuilder.Build());

// --- REGION: Agent stack
builder.Services.AddSingleton<SchemaCatalog>();
builder.Services.AddSingleton<SqlValidator>();

// --- REGION: Select language model
// Local selection keeps the schema and question off third-party APIs.
// Provider precedence: https://yuruna.link/4286c679-0007
// OLLAMA_HOST / OLLAMA_MODEL override http://127.0.0.1:11434 / localcoder.
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

// --- REGION: Configure HTTP pipeline
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

// --- REGION: Run application
app.Run();
