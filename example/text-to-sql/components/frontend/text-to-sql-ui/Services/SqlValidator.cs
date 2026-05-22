// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// SqlValidator — the "④ Validator (Guardrail)" stage of the agent pipeline.
//
// What it enforces:
//   1. Statement must be exactly ONE statement, and that statement must be
//      a SELECT (or WITH ... SELECT). Rejects DROP/DELETE/UPDATE/INSERT/
//      ALTER/GRANT/TRUNCATE/CREATE/COMMENT/COPY/CALL/EXECUTE/VACUUM/etc.
//   2. No semicolons in the middle (stacked statements).
//   3. No comments that could hide a payload (-- or /* */).
//   4. A LIMIT clause is enforced; if missing, we append one.
//   5. EXPLAIN-based cost gate: runs `EXPLAIN (FORMAT JSON)` and refuses
//      plans whose top-node "Plan Rows" exceeds a configurable threshold.
//
// In production swap the regex pre-check for an AST parser like libpg_query.
// In this example the regex layer is a deliberate, named trade-off — and
// the EXPLAIN gate is the real defense in depth.
// ---------------------------------------------------------------------------

using System.Text.RegularExpressions;
using Npgsql;

namespace TextToSqlUi.Services;

public sealed class SqlValidator
{
    private readonly NpgsqlDataSource _ds;
    private readonly ILogger<SqlValidator> _log;
    private readonly int _rowsRefuseThreshold;
    private readonly int _maxLimit;
    private readonly int _timeoutMs;

    public SqlValidator(NpgsqlDataSource ds, ILogger<SqlValidator> log, IConfiguration cfg)
    {
        _ds = ds;
        _log = log;
        _maxLimit            = cfg.GetValue("Agent:MaxRowsReturned", 200);
        _timeoutMs           = cfg.GetValue("Agent:StatementTimeoutMs", 5000);
        _rowsRefuseThreshold = cfg.GetValue("Agent:ExplainRefuseRows", 1_000_000);
    }

    // ── Static (offline) checks ───────────────────────────────────────────
    private static readonly Regex CommentRx = new(@"(--|/\*|\*/)", RegexOptions.Compiled);

    private static readonly string[] ForbiddenLeadingKeywords =
    {
        "INSERT","UPDATE","DELETE","DROP","ALTER","TRUNCATE","GRANT","REVOKE",
        "CREATE","COMMENT","COPY","CALL","EXECUTE","VACUUM","REINDEX","CLUSTER",
        "LOCK","REFRESH","SECURITY","SET","RESET","BEGIN","COMMIT","ROLLBACK",
    };

    public StaticCheckResult StaticCheck(string sql)
    {
        if (string.IsNullOrWhiteSpace(sql))
            return StaticCheckResult.Fail("Empty SQL.");

        var trimmed = sql.Trim();

        if (CommentRx.IsMatch(trimmed))
            return StaticCheckResult.Fail("Comments are not allowed in generated SQL.");

        // Strip trailing semicolons but reject embedded ones.
        var noTrailing = trimmed.TrimEnd(';', ' ', '\t', '\r', '\n');
        if (noTrailing.Contains(';'))
            return StaticCheckResult.Fail("Multiple statements are not allowed.");

        // First token check (case-insensitive). Allow SELECT and WITH ... .
        var firstToken = noTrailing.Split(
            new[] { ' ', '\t', '\r', '\n', '(' },
            2, StringSplitOptions.RemoveEmptyEntries)[0].ToUpperInvariant();

        if (ForbiddenLeadingKeywords.Contains(firstToken))
            return StaticCheckResult.Fail($"Statement type '{firstToken}' is not permitted (read-only agent).");

        if (firstToken != "SELECT" && firstToken != "WITH")
            return StaticCheckResult.Fail($"Only SELECT / WITH are allowed; got '{firstToken}'.");

        // For an extra cheap defense, also reject CTE-disguised writes
        // ("WITH ... INSERT/UPDATE/DELETE ... SELECT ..."). A real
        // libpg_query AST walk handles this cleanly; we use a substring
        // check that catches the common patterns.
        var upper = noTrailing.ToUpperInvariant();
        foreach (var bad in new[] { ") INSERT ", ") UPDATE ", ") DELETE ", ") MERGE " })
            if (upper.Contains(bad))
                return StaticCheckResult.Fail("CTE-disguised write statement detected.");

        // Inject a LIMIT if missing.
        var withLimit = upper.Contains(" LIMIT ")
            ? noTrailing
            : noTrailing + $"\nLIMIT {_maxLimit}";

        return StaticCheckResult.Ok(withLimit);
    }

    // ── Online cost gate: EXPLAIN (FORMAT JSON) ───────────────────────────
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
            // Look for the first occurrence of "Plan Rows":<number>.
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

public sealed record StaticCheckResult(bool Allowed, string? Reason, string? SafeSql)
{
    public static StaticCheckResult Ok(string safe) => new(true, null, safe);
    public static StaticCheckResult Fail(string why) => new(false, why, null);
}

public sealed record ExplainResult(bool Allowed, long PlanRows, string? Reason, bool ParseFailed)
{
    public static ExplainResult Allow(long rows)            => new(true, rows, null, false);
    public static ExplainResult Refuse(long rows, string r) => new(false, rows, r, false);
    public static ExplainResult ParseError(string err)      => new(false, 0, err, true);
}
