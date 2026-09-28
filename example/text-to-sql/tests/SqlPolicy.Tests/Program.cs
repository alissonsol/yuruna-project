// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

using System.Data;
using Microsoft.Extensions.Logging.Abstractions;
using TextToSqlUi.Services;

var assertions = 0;
void Check(bool condition, string description)
{
    assertions++;
    if (!condition) throw new InvalidOperationException(description);
}

var policy = new SqlQueryPolicy(200);
foreach (var sql in new[]
{
    "SELECT email FROM customer", "SELECT c.\"email\" FROM customer c",
    "SELECT phone FROM customer", "SELECT address_pii FROM customer",
    "SELECT * FROM customer", "SELECT c.* FROM customer c", "SELECT (c).* FROM customer c",
    "SELECT c FROM customer c", "SELECT customer FROM customer", "SELECT row_to_json(c) FROM customer c",
    "SELECT to_jsonb(\"c\") FROM customer AS \"c\"", "SELECT ROW(c) FROM customer c",
    "SELECT c AS payload FROM customer c", "SELECT c FROM subscription s, customer c",
    "SELECT row_to_json(c) FROM (SELECT customer_id FROM customer) c",
    "WITH rows AS (SELECT c FROM customer c) SELECT rows FROM rows",
    "WITH safe AS (SELECT customer_id FROM customer) SELECT row_to_json(safe) FROM safe",
    "SELECT t.payload FROM (SELECT to_jsonb(c) AS payload FROM customer c) t",
    "SELECT to_jsonb(ROW(c)) FROM customer c", "SELECT c.customer_id FROM customer c ORDER BY c",
    "SELECT 1; SELECT 2", "SELECT 1 -- LIMIT 1", "SELECT 1 /* comment */",
    "WITH changed AS (DELETE FROM customer RETURNING customer_id) SELECT customer_id FROM changed",
    "SELECT 1 INTO copied", "SELECT 'unterminated", "SELECT $$unterminated", "SELECT (1", ";"
}) Check(!policy.Check(sql).Allowed, "Must refuse: " + sql);

foreach (var sql in new[]
{
    "SELECT 'LIMIT', generate_series(1,500)", "SELECT 'LIMIT ( )' AS label",
    "SELECT 'it''s LIMIT 1' AS label", "SELECT E'escaped\\\' LIMIT 1' AS label",
    "SELECT $$LIMIT 1 ($$ AS label", "SELECT $tag$LIMIT 1 )$tag$ AS label",
    "SELECT 1 AS \"LIMIT\"", "SELECT 'email; -- /*' AS label",
    "SELECT ';'", "SELECT ROW(customer_id, company_name) FROM customer",
    "SELECT c.customer_id FROM customer c WHERE c.customer_id IN (SELECT customer_id FROM customer LIMIT 2)",
    "SELECT COUNT(*) FROM customer", "SELECT SUM(s.seat_count * p.monthly_usd) FROM subscription s JOIN plan_tier p ON p.tier_id=s.tier_id",
    "WITH c AS (SELECT customer_id FROM customer LIMIT 1) SELECT c.customer_id FROM c"
})
{
    var result = policy.Check(sql);
    Check(result.Allowed, "Must allow: " + sql + ": " + result.Reason);
    Check(result.SafeSql == sql + "\nLIMIT 200", "Must append real outer LIMIT: " + sql);
}

foreach (var (sql, expected) in new[]
{
    ("SELECT customer_id FROM customer ORDER BY customer_id DESC LIMIT 10", "SELECT customer_id FROM customer ORDER BY customer_id DESC LIMIT 10"),
    ("SELECT customer_id FROM customer ORDER BY customer_id DESC LIMIT 500", "SELECT customer_id FROM customer ORDER BY customer_id DESC LIMIT 200"),
    ("SELECT customer_id FROM customer ORDER BY customer_id LIMIT 0", "SELECT customer_id FROM customer ORDER BY customer_id LIMIT 0"),
    ("SELECT 1 LIMIT ALL OFFSET 5", "SELECT 1 LIMIT 200 OFFSET 5"),
    ("SELECT 1 LIMIT (SELECT 10) OFFSET 5", "SELECT 1 LIMIT LEAST(((SELECT 10)), 200) OFFSET 5"),
    ("SELECT 1 LIMIT NULL", "SELECT 1 LIMIT LEAST((NULL), 200)"),
    ("SELECT 1 FETCH FIRST 5 ROWS ONLY", "SELECT 1 FETCH FIRST 5 ROWS ONLY"),
    ("SELECT 'LIMIT' AS label;", "SELECT 'LIMIT' AS label\nLIMIT 200")
})
{
    var result = policy.Check(sql);
    Check(result.Allowed && result.SafeSql == expected, "Cap/order: " + sql + " => " + result.SafeSql);
}
Check(new SqlQueryPolicy(7).Check("SELECT 1").SafeSql == "SELECT 1\nLIMIT 7", "Configured SQL cap");
try { _ = new SqlQueryPolicy(0); Check(false, "Zero cap must fail"); } catch (ArgumentOutOfRangeException) { assertions++; }

var client = new RuleBasedLlmClient(NullLogger<RuleBasedLlmClient>.Instance);
foreach (var prompt in new[] { "churn rate by plan tier in EMEA", "churn by channel", "MRR by tier",
    "active subscriptions by region", "top 10 customers by invoice", "new signups by month", "list tables" })
{
    var decision = await client.GenerateSqlAsync(prompt, "fixture schema");
    Check(!decision.Refused && policy.Check(decision.Sql!).Allowed, "Built-in query must remain usable: " + prompt);
}

var table = new DataTable();
table.Columns.Add("id", typeof(int));
table.Columns.Add("nullable", typeof(string));
for (var i = 500; i >= 1; i--) table.Rows.Add(i, DBNull.Value);
foreach (var cap in new[] { 1, 7, 200, 600 })
{
    using var reader = table.CreateDataReader();
    var rows = await SqlResultReader.ReadRowsAsync(reader, cap);
    Check(rows.Count == Math.Min(500, cap), "Configured executor cap " + cap);
    Check(rows.Select(r => (int)r[0]!).SequenceEqual(Enumerable.Range(0, rows.Count).Select(i => 500 - i)), "Reader preserves database ordering");
    Check(rows.All(r => r[1] is null), "SQL null remains null");
    if (cap < 500) Check(reader.Read() && reader.GetInt32(0) == 500 - cap, "Reader must not consume an extra row");
}
using (var reader = table.Clone().CreateDataReader())
    Check((await SqlResultReader.ReadRowsAsync(reader, 200)).Count == 0, "Empty result");
using (var reader = table.CreateDataReader())
{
    var cancelled = new CancellationToken(true);
    try { await SqlResultReader.ReadRowsAsync(reader, 200, cancelled); Check(false, "Cancellation must propagate"); }
    catch (OperationCanceledException) { assertions++; }
}
Console.WriteLine($"SQL policy and result reader: {assertions} assertions passed.");
