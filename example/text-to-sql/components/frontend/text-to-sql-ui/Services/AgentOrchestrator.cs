// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// AgentOrchestrator — the "①  Planner" + retry loop for the agent pipeline.
//
// Pipeline (with observability per stage):
//     question
//        ↓
//     [② schema retriever]   → schema slice
//        ↓
//     [③ SQL generator]      → SQL or refusal
//        ↓
//     [④ static validator]   → safe SQL or refusal
//        ↓
//     [④ EXPLAIN cost gate]  → allow or refuse
//        ↓
//     [⑤ executor]           → rows  (read replica, statement_timeout, LIMIT)
//        ↓
//     AgentRun (UI renders all of the above as a single timeline)
//
// Every stage emits a Step with elapsed-ms, status, and notes. The UI shows
// the timeline — that's the "Observer" layer in miniature, the kind of
// production awareness you'd want on a real agent.
// ---------------------------------------------------------------------------

using System.Data;
using System.Diagnostics;
using Npgsql;

namespace TextToSqlUi.Services;

public sealed class AgentOrchestrator
{
    private readonly SchemaCatalog _catalog;
    private readonly SqlValidator  _validator;
    private readonly ILlmClient    _llm;
    private readonly NpgsqlDataSource _ds;
    private readonly ILogger<AgentOrchestrator> _log;
    private readonly int _timeoutMs;
    private readonly bool _enableExplainGate;

    public AgentOrchestrator(
        SchemaCatalog catalog,
        SqlValidator validator,
        ILlmClient llm,
        NpgsqlDataSource ds,
        ILogger<AgentOrchestrator> log,
        IConfiguration cfg)
    {
        _catalog   = catalog;
        _validator = validator;
        _llm       = llm;
        _ds        = ds;
        _log       = log;
        _timeoutMs = cfg.GetValue("Agent:StatementTimeoutMs", 5000);
        // Defense-in-depth EXPLAIN cost gate is on by default; an operator can
        // opt out via config, in which case the pipeline records that the gate
        // was bypassed so the timeline still shows the decision.
        _enableExplainGate = cfg.GetValue("Agent:EnableExplainGate", true);
    }

    public async Task<AgentRun> RunAsync(string question, CancellationToken ct = default)
    {
        var run = new AgentRun(question);

        // ─── ② Schema retrieval ────────────────────────────────────────────
        var swSchema = Stopwatch.StartNew();
        RetrievalResult retrieval;
        try
        {
            retrieval = await _catalog.GetRelevantSchemaAsync(question, k: 6);
        }
        catch (Exception ex)
        {
            run.Steps.Add(Step.Fail("Schema retrieval", swSchema, ex.Message));
            run.Finalize(error: "Schema retrieval failed.");
            return run;
        }
        run.Steps.Add(Step.Ok("Schema retrieval", swSchema,
            $"Picked {retrieval.Tables.Count} tables (FK-expanded). " +
            $"Prompt slice ≈ {retrieval.FormattedPrompt.Length} chars."));
        run.SchemaSlice = retrieval.FormattedPrompt;

        // ─── ③ SQL generation ──────────────────────────────────────────────
        var swGen = Stopwatch.StartNew();
        LlmDecision decision;
        try
        {
            decision = await _llm.GenerateSqlAsync(question, retrieval.FormattedPrompt, ct);
        }
        catch (LlmClientException ex)
        {
            // A transport / HTTP / parse failure is an infrastructure ERROR, not
            // a model refusal -- render it as a failed step + run error so it is
            // distinguishable (and monitorable), and the client's own bounded
            // retry has already been exhausted.
            run.Steps.Add(Step.Fail("SQL generation", swGen, ex.Message));
            run.Finalize(error: "SQL generation failed (LLM/API error).");
            return run;
        }
        if (decision.Refused)
        {
            run.Steps.Add(Step.Refused("SQL generation", swGen, decision.RefusalReason ?? "unknown"));
            run.Finalize(refusal: decision.RefusalReason);
            return run;
        }
        run.PlanText = decision.PlanText;
        run.Steps.Add(Step.Ok("SQL generation", swGen, "Draft SQL produced."));
        var draftSql = decision.Sql!.Trim();

        // ─── ④ Static validation ───────────────────────────────────────────
        var swStatic = Stopwatch.StartNew();
        var st = _validator.StaticCheck(draftSql);
        if (!st.Allowed)
        {
            run.Steps.Add(Step.Refused("Static validation", swStatic, st.Reason ?? "rejected"));
            run.Finalize(refusal: st.Reason);
            return run;
        }
        var safeSql = st.SafeSql!;
        run.Steps.Add(Step.Ok("Static validation", swStatic,
            safeSql.Length > draftSql.Length ? "Allowed. (Auto-injected LIMIT.)" : "Allowed."));
        run.SafeSql = safeSql;

        // ─── ④ EXPLAIN cost gate ───────────────────────────────────────────
        var swExp = Stopwatch.StartNew();
        if (!_enableExplainGate)
        {
            _log.LogWarning("EXPLAIN cost gate bypassed by Agent:EnableExplainGate=false.");
            run.Steps.Add(Step.Ok("EXPLAIN", swExp,
                "Gate bypassed (Agent:EnableExplainGate=false)."));
        }
        else
        {
            var gate = await _validator.ExplainAsync(safeSql, ct);
            if (gate.ParseFailed)
            {
                run.Steps.Add(Step.Fail("EXPLAIN", swExp, gate.Reason ?? "parse failed"));
                run.Finalize(error: $"PostgreSQL rejected the SQL: {gate.Reason}");
                return run;
            }
            if (!gate.Allowed)
            {
                run.Steps.Add(Step.Refused("EXPLAIN", swExp, gate.Reason ?? "cost gate"));
                run.Finalize(refusal: gate.Reason);
                return run;
            }
            run.Steps.Add(Step.Ok("EXPLAIN", swExp, $"Plan rows ≈ {gate.PlanRows:N0}. Allowed."));
        }

        // ─── ⑤ Execute ─────────────────────────────────────────────────────
        var swExec = Stopwatch.StartNew();
        try
        {
            await using var conn = await _ds.OpenConnectionAsync(ct);
            await using var tx   = await conn.BeginTransactionAsync(ct);

            await using (var s = new NpgsqlCommand($"SET LOCAL statement_timeout = {_timeoutMs};", conn, tx))
                await s.ExecuteNonQueryAsync(ct);

            await using var cmd = new NpgsqlCommand(safeSql, conn, tx);
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var columns = new List<string>();
            for (int i = 0; i < rdr.FieldCount; i++) columns.Add(rdr.GetName(i));
            run.ResultColumns = columns;

            while (await rdr.ReadAsync(ct))
            {
                var row = new object?[rdr.FieldCount];
                for (int i = 0; i < rdr.FieldCount; i++)
                    row[i] = rdr.IsDBNull(i) ? null : rdr.GetValue(i);
                run.ResultRows.Add(row);
                if (run.ResultRows.Count >= 1000) break; // hard cap
            }

            await tx.RollbackAsync(ct);

            run.Steps.Add(Step.Ok("Execute", swExec,
                $"{run.ResultRows.Count} rows in {swExec.ElapsedMilliseconds} ms."));
            run.Finalize();
        }
        catch (PostgresException pex) when (pex.SqlState == "57014")  // statement_timeout
        {
            run.Steps.Add(Step.Refused("Execute", swExec, $"Statement timeout at {_timeoutMs} ms."));
            run.Finalize(refusal:
                "The generated query exceeded the statement timeout. " +
                "Mitigations: add a date filter, request a smaller LIMIT, or try a materialized view.");
        }
        catch (Exception execEx)
        {
            run.Steps.Add(Step.Fail("Execute", swExec, execEx.Message));
            run.Finalize(error: execEx.Message);
        }
        return run;
    }
}

// ── Run + Step records ─────────────────────────────────────────────────────

public sealed class AgentRun
{
    public string Question  { get; }
    public string? PlanText { get; internal set; }
    public string? SchemaSlice { get; internal set; }
    public string? SafeSql  { get; internal set; }
    public List<Step> Steps { get; } = new();
    public List<string> ResultColumns { get; internal set; } = new();
    public List<object?[]> ResultRows  { get; } = new();
    public bool   Succeeded { get; private set; }
    public string? RefusalReason { get; private set; }
    public string? Error    { get; private set; }
    public long TotalMs     { get; private set; }

    public AgentRun(string q) { Question = q; }

    internal void Finalize(string? refusal = null, string? error = null)
    {
        RefusalReason = refusal;
        Error = error;
        Succeeded = refusal is null && error is null;
        TotalMs = Steps.Sum(s => s.ElapsedMs);
    }
}

public sealed record Step(string Stage, string Status, long ElapsedMs, string Note)
{
    internal static Step Ok      (string stage, Stopwatch sw, string note) => new(stage, "ok",      sw.ElapsedMilliseconds, note);
    internal static Step Refused (string stage, Stopwatch sw, string note) => new(stage, "refused", sw.ElapsedMilliseconds, note);
    internal static Step Fail    (string stage, Stopwatch sw, string note) => new(stage, "fail",    sw.ElapsedMilliseconds, note);
}
