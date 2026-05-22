// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// SchemaCatalog — the "②  Schema Retriever" stage of the agent pipeline.
//
// Build-time: introspect information_schema + pg_constraint to materialize
//   - per-column metadata (name, type, nullable, sample values)
//   - per-table prose (from pg_description / COMMENT ON)
//   - the foreign-key graph as a sidecar { table -> [neighbour, fk-edge-label] }
//
// Query-time: get_relevant_schema(question, k)
//   - hybrid scoring: keyword (token overlap) + lightweight semantic-ish
//     similarity-by-substring on table/column docstrings.
//   - one-hop FK expansion so the LLM never has to invent JOIN partners.
//   - returns a compact string suitable for prompting (target: < 2 KB).
//
// In a production system the embedding side is a real vector index (pgvector,
// or a hosted store). Keeping it deterministic here means the example runs
// offline and is reproducible.
// ---------------------------------------------------------------------------

using System.Data;
using Npgsql;

namespace TextToSqlUi.Services;

public sealed class SchemaCatalog
{
    private readonly NpgsqlDataSource _ds;
    private readonly ILogger<SchemaCatalog> _log;
    private readonly Lazy<Task<IReadOnlyList<TableInfo>>> _cache;

    public SchemaCatalog(NpgsqlDataSource ds, ILogger<SchemaCatalog> log)
    {
        _ds = ds;
        _log = log;
        _cache = new Lazy<Task<IReadOnlyList<TableInfo>>>(LoadAsync);
    }

    public Task<IReadOnlyList<TableInfo>> GetAllAsync() => _cache.Value;

    // ── Public retriever ───────────────────────────────────────────────────
    // Returns the k most relevant tables (by hybrid score) plus their direct
    // FK neighbours. The string form is what the SQL generator sees.
    public async Task<RetrievalResult> GetRelevantSchemaAsync(string question, int k = 6)
    {
        var all = await _cache.Value;
        var qTokens = Tokenize(question);

        // Score by token-overlap against the table's "search blob"
        // (table name + column names + comment).
        var scored = all
            .Select(t => (t, score: ScoreTable(t, qTokens)))
            .OrderByDescending(x => x.score)
            .ToList();

        // Pull top-k, then one-hop FK expansion.
        var topK = scored.Take(k).Where(x => x.score > 0).Select(x => x.t).ToList();
        if (topK.Count == 0)
        {
            // Fallback: deterministic seed of the 4 most central tables so
            // an out-of-domain question still gets something to chew on.
            topK = all.Where(t => t.Name is "customer" or "subscription" or "plan_tier" or "churn_event")
                     .ToList();
        }

        var expanded = new Dictionary<string, TableInfo>(topK.ToDictionary(t => t.Name));
        foreach (var t in topK)
        {
            foreach (var (neighbour, _) in t.FkOut)
            {
                if (!expanded.ContainsKey(neighbour))
                {
                    var n = all.FirstOrDefault(x => x.Name == neighbour);
                    if (n is not null) expanded[neighbour] = n;
                }
            }
        }

        return new RetrievalResult(expanded.Values.ToList(), Format(expanded.Values));
    }

    private static int ScoreTable(TableInfo t, HashSet<string> qTokens)
    {
        int s = 0;
        foreach (var tok in qTokens)
        {
            if (t.SearchBlob.Contains(tok, StringComparison.OrdinalIgnoreCase)) s += 1;
            // exact name match weighs more
            if (t.Name.Equals(tok, StringComparison.OrdinalIgnoreCase)) s += 5;
            if (t.Columns.Any(c => c.Name.Equals(tok, StringComparison.OrdinalIgnoreCase))) s += 3;
        }
        return s;
    }

    private static readonly HashSet<string> StopWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "the","a","an","of","in","by","for","and","or","on","at","to","from","with",
        "how","what","when","where","which","who","is","are","was","were","be","been",
        "show","give","me","my","our","us","please","list","find","get","top","last",
        "this","that","these","those","each","every","per",
    };
    private static HashSet<string> Tokenize(string q)
    {
        return q
            .Split(new[] { ' ', ',', '.', '?', '!', '/', '(', ')', '-', '_', '\'', '"' },
                   StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim().ToLowerInvariant())
            .Where(s => s.Length >= 3 && !StopWords.Contains(s))
            .ToHashSet();
    }

    // ── Format for the prompt — compact YAML-ish so the model finds JOINs. ──
    private static string Format(IEnumerable<TableInfo> tables)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("# Relevant schema slice (FK-expanded)");
        foreach (var t in tables.OrderBy(t => t.Name))
        {
            sb.AppendLine($"- table: {t.Name}");
            if (!string.IsNullOrWhiteSpace(t.Comment))
                sb.AppendLine($"  doc: \"{t.Comment.Replace("\"", "'")}\"");
            sb.AppendLine("  columns:");
            foreach (var c in t.Columns)
            {
                var pii = c.IsPii ? " [PII]" : "";
                sb.AppendLine($"    - {c.Name}: {c.DataType}{pii}");
            }
            if (t.FkOut.Count > 0)
            {
                sb.AppendLine("  foreign_keys:");
                foreach (var (n, edge) in t.FkOut)
                    sb.AppendLine($"    - {edge} -> {n}");
            }
        }
        return sb.ToString();
    }

    // ── Build the catalog from information_schema + pg_constraint ──────────
    private async Task<IReadOnlyList<TableInfo>> LoadAsync()
    {
        var byName = new Dictionary<string, TableInfo>(StringComparer.OrdinalIgnoreCase);

        await using var conn = await _ds.OpenConnectionAsync();

        // Tables + comments
        const string sqlTables = @"
            SELECT c.relname,
                   COALESCE(obj_description(c.oid, 'pg_class'), '') AS comment
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = 'public'
             ORDER BY c.relname;";

        await using (var cmd = new NpgsqlCommand(sqlTables, conn))
        await using (var rdr = await cmd.ExecuteReaderAsync())
        {
            while (await rdr.ReadAsync())
            {
                var name = rdr.GetString(0);
                var cmt  = rdr.GetString(1);
                byName[name] = new TableInfo(name, cmt);
            }
        }

        // Columns
        const string sqlCols = @"
            SELECT table_name, column_name, data_type, is_nullable
              FROM information_schema.columns
             WHERE table_schema = 'public'
             ORDER BY table_name, ordinal_position;";

        await using (var cmd = new NpgsqlCommand(sqlCols, conn))
        await using (var rdr = await cmd.ExecuteReaderAsync())
        {
            while (await rdr.ReadAsync())
            {
                var tbl = rdr.GetString(0);
                if (!byName.TryGetValue(tbl, out var ti)) continue;
                var col = new ColumnInfo(
                    Name: rdr.GetString(1),
                    DataType: rdr.GetString(2),
                    Nullable: rdr.GetString(3) == "YES",
                    IsPii: rdr.GetString(1).Equals("email", StringComparison.OrdinalIgnoreCase)
                );
                ti.Columns.Add(col);
            }
        }

        // Foreign keys (table_name → referenced_table, edge_label = "fk(col→col)")
        const string sqlFks = @"
            SELECT tc.table_name,
                   kcu.column_name,
                   ccu.table_name  AS foreign_table,
                   ccu.column_name AS foreign_column
              FROM information_schema.table_constraints tc
              JOIN information_schema.key_column_usage     kcu
                ON tc.constraint_name = kcu.constraint_name
              JOIN information_schema.constraint_column_usage ccu
                ON ccu.constraint_name = tc.constraint_name
             WHERE tc.constraint_type = 'FOREIGN KEY'
               AND tc.table_schema    = 'public';";

        await using (var cmd = new NpgsqlCommand(sqlFks, conn))
        await using (var rdr = await cmd.ExecuteReaderAsync())
        {
            while (await rdr.ReadAsync())
            {
                var src = rdr.GetString(0);
                var srcCol = rdr.GetString(1);
                var tgt = rdr.GetString(2);
                var tgtCol = rdr.GetString(3);
                if (byName.TryGetValue(src, out var ti))
                    ti.FkOut.Add((tgt, $"{srcCol}→{tgt}.{tgtCol}"));
            }
        }

        // Pre-compute the search blob (lowercased) for fast scoring.
        foreach (var t in byName.Values) t.FreezeSearchBlob();

        _log.LogInformation("SchemaCatalog loaded {Count} tables.", byName.Count);
        return byName.Values.ToList();
    }
}

// ── Records ────────────────────────────────────────────────────────────────

public sealed class TableInfo
{
    public string Name { get; }
    public string Comment { get; }
    public List<ColumnInfo> Columns { get; } = new();
    public List<(string Neighbour, string Edge)> FkOut { get; } = new();
    public string SearchBlob { get; private set; } = "";

    public TableInfo(string name, string comment)
    {
        Name = name;
        Comment = comment;
    }

    internal void FreezeSearchBlob()
    {
        var cols = string.Join(' ', Columns.Select(c => c.Name));
        SearchBlob = $"{Name} {cols} {Comment}".ToLowerInvariant();
    }
}

public sealed record ColumnInfo(string Name, string DataType, bool Nullable, bool IsPii);

public sealed record RetrievalResult(IReadOnlyList<TableInfo> Tables, string FormattedPrompt);
