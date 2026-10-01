// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Validator stage: static SQL checks + EXPLAIN cost gate; see README service
// notes: https://yuruna.link/4286c679-0007

using System.Text.Json;
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
        NpgsqlConnection? conn = null;
        NpgsqlTransaction? tx = null;
        try
        {
            conn = await _ds.OpenConnectionAsync(ct);
            tx = await conn.BeginTransactionAsync(ct);
            await using (var st = new NpgsqlCommand($"SET LOCAL statement_timeout = {_timeoutMs};", conn, tx))
                await st.ExecuteNonQueryAsync(ct);
            await using var cmd = new NpgsqlCommand("EXPLAIN (FORMAT JSON) " + sql, conn, tx);
            var raw = (string?)await cmd.ExecuteScalarAsync(ct) ?? "[]";
            var planRows = MaximumPlanRows(raw);
            await tx.RollbackAsync(ct);
            return planRows > _rowsRefuseThreshold
                ? ExplainResult.Refuse(planRows,
                    $"Estimated {planRows:N0} rows exceeds the {_rowsRefuseThreshold:N0} cost gate.")
                : ExplainResult.Allow(planRows);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception ex) when (ex is NpgsqlException or IOException or TimeoutException
            or JsonException or InvalidOperationException or FormatException or OverflowException)
        {
            return ExplainResult.ParseError(ex.Message);
        }
        finally
        {
            // Disposal rolls back an unfinished transaction. Cleanup must not replace
            // the original database failure or the caller's cancellation.
            if (tx is not null)
                try { await tx.DisposeAsync(); }
                catch (Exception ex) { _log.LogWarning(ex, "EXPLAIN transaction cleanup failed"); }
            if (conn is not null)
                try { await conn.DisposeAsync(); }
                catch (Exception ex) { _log.LogWarning(ex, "EXPLAIN connection cleanup failed"); }
        }
    }

    internal static long MaximumPlanRows(string raw)
    {
        using var document = JsonDocument.Parse(raw);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() != 1 ||
            !root[0].TryGetProperty("Plan", out var plan))
            throw new JsonException(ServiceMessages.Get("PlanMissing"));
        return Visit(plan);

        static long Visit(JsonElement node)
        {
            if (!node.TryGetProperty("Plan Rows", out var value) || !value.TryGetInt64(out var rows) || rows < 0)
                throw new JsonException(ServiceMessages.Get("PlanRowsInvalid"));
            if (node.TryGetProperty("Plans", out var children))
                foreach (var child in children.EnumerateArray()) rows = Math.Max(rows, Visit(child));
            return rows;
        }
    }
}

public sealed record ExplainResult(bool Allowed, long PlanRows, string? Reason, bool ParseFailed)
{
    public static ExplainResult Allow(long rows)            => new(true, rows, null, false);
    public static ExplainResult Refuse(long rows, string r) => new(false, rows, r, false);
    public static ExplainResult ParseError(string err)      => new(false, 0, err, true);
}
