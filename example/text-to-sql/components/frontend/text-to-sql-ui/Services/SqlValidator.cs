// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// SqlValidator — the "④ Validator (Guardrail)" stage of the agent pipeline.
// Five checks (single SELECT-only statement, no stacked statements, no
// comment payloads, enforced top-level LIMIT, EXPLAIN cost gate); the
// regex pre-check vs AST-parser trade-off: see the README service notes —
// https://yuruna.link/text-to-sql#service-notes
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

    // PII column identifiers the validator refuses outright. Kept aligned with
    // SchemaCatalog.IsPiiColumn: exact 'email' / 'phone', or any identifier ending in '_pii'.
    // The lookarounds isolate whole SQL identifiers so 'phone_number' / 'email_templates' do
    // not match (they are not the flagged PII columns).
    private static readonly Regex PiiColumnRx = new(
        @"(?<![A-Za-z0-9_])(email|phone|[A-Za-z0-9_]*_pii)(?![A-Za-z0-9_])",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

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

        // Deterministic PII guardrail. The LLM system prompt also forbids selecting PII, but a
        // prompt is advisory (prompt-injection / hallucination can violate it); the validator is
        // the real defense in depth, so refuse any reference to a PII column here rather than
        // trusting the model. Kept aligned with SchemaCatalog.IsPiiColumn.
        var piiMatch = PiiColumnRx.Match(noTrailing);
        if (piiMatch.Success)
            return StaticCheckResult.Fail($"Query references a PII column ('{piiMatch.Value}'); selecting PII is not permitted.");

        // Enforce the row cap on a TOP-LEVEL LIMIT only. A naive substring
        // check for " LIMIT " is satisfied by a LIMIT inside a subquery/CTE
        // while the OUTER result stays uncapped; a paren-depth
        // scan distinguishes the real top-level cap. When the query already has
        // a top-level LIMIT it is kept as-is (the EXPLAIN cost gate backstops an
        // over-large one); otherwise LIMIT N is appended at the TOP level so any
        // existing ORDER BY stays outermost -- wrapping the query in a derived
        // table would drop that ordering for the common "top N by X" shape.
        var withLimit = HasTopLevelLimit(noTrailing)
            ? noTrailing
            : noTrailing + $"\nLIMIT {_maxLimit}";

        return StaticCheckResult.Ok(withLimit);
    }

    // True iff a LIMIT clause exists at the TOP level (paren depth 0) -- one that
    // actually caps the final result, versus a LIMIT buried in a subquery/CTE
    // (which a naive substring check wrongly accepts while the outer result stays
    // uncapped). String literals are not stripped, which is acceptable for the
    // read-only SELECTs this validator gates (comment/PII/keyword checks ran first).
    private static bool HasTopLevelLimit(string sql)
    {
        var depth = 0;
        foreach (Match match in Regex.Matches(sql, @"\(|\)|\bLIMIT\b", RegexOptions.IgnoreCase))
        {
            switch (match.Value)
            {
                case "(": depth++; break;
                case ")": if (depth > 0) depth--; break;
                default:                       // a LIMIT keyword (any case)
                    if (depth == 0) return true;
                    break;
            }
        }
        return false;
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
