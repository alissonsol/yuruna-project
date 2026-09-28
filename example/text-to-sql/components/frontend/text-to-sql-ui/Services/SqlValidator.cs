// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Validator stage: static SQL checks + EXPLAIN cost gate; see README service
// notes: https://yuruna.link/4286c679-0007

using System.Text.RegularExpressions;
using Npgsql;

namespace TextToSqlUi.Services;

public sealed class SqlValidator
{
    private readonly NpgsqlDataSource _ds;
    private readonly ILogger<SqlValidator> _log;
    private readonly int _rowsRefuseThreshold;
    private readonly SqlQueryPolicy _policy;
    public int MaxRows => _policy.MaxRows;
    private readonly int _timeoutMs;

    public SqlValidator(NpgsqlDataSource ds, ILogger<SqlValidator> log, IConfiguration cfg)
    {
        _ds = ds;
        _log = log;
        _policy              = new SqlQueryPolicy(cfg.GetValue("Agent:MaxRowsReturned", 200));
        _timeoutMs           = cfg.GetValue("Agent:StatementTimeoutMs", 5000);
        _rowsRefuseThreshold = cfg.GetValue("Agent:ExplainRefuseRows", 1_000_000);
    }

    public StaticCheckResult StaticCheck(string sql) => _policy.Check(sql);

    // --- REGION: EXPLAIN cost gate
    public async Task<ExplainResult> ExplainAsync(string sql, CancellationToken ct = default)
    {
        await using var conn = await _ds.OpenConnectionAsync(ct);
        await using var tx   = await conn.BeginTransactionAsync(ct); // forced read-only by role + ROLLBACK below
        try
        {
            await using (var st = new NpgsqlCommand($"SET LOCAL statement_timeout = {_timeoutMs};", conn, tx))
                await st.ExecuteNonQueryAsync(ct);

            await using var cmd = new NpgsqlCommand("EXPLAIN (FORMAT JSON) " + sql, conn, tx);
            var raw = (string?)await cmd.ExecuteScalarAsync(ct) ?? "[]";

            // Top-level plan-rows is enough for the gate; we don't need the
            // whole plan tree here.
            long planRows = 0;
            var m = Regex.Match(raw, @"""Plan Rows""\s*:\s*(\d+)");
            if (m.Success) planRows = long.Parse(m.Groups[1].Value);

            await tx.RollbackAsync(ct);

            if (planRows > _rowsRefuseThreshold)
                return ExplainResult.Refuse(planRows,
                    $"Estimated {planRows:N0} rows exceeds the {_rowsRefuseThreshold:N0} cost gate.");

            return ExplainResult.Allow(planRows);
        }
        catch (NpgsqlException ex)
        {
            await tx.RollbackAsync(ct);
            return ExplainResult.ParseError(ex.Message);
        }
    }
}

public sealed record ExplainResult(bool Allowed, long PlanRows, string? Reason, bool ParseFailed)
{
    public static ExplainResult Allow(long rows)            => new(true, rows, null, false);
    public static ExplainResult Refuse(long rows, string r) => new(false, rows, r, false);
    public static ExplainResult ParseError(string err)      => new(false, 0, err, true);
}
