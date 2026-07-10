// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// ---------------------------------------------------------------------------
// RuleBasedLlmClient — a deterministic stand-in for the "③ SQL Generator
// (LLM)" box. Lets the example run offline, with no API key. Pattern
// coverage and the plan-prose contract: see the README service notes —
// https://yuruna.link/text-to-sql#service-notes
// ---------------------------------------------------------------------------

using System.Text.RegularExpressions;

namespace TextToSqlUi.Services;

public sealed class RuleBasedLlmClient : ILlmClient
{
    private readonly ILogger<RuleBasedLlmClient> _log;
    public RuleBasedLlmClient(ILogger<RuleBasedLlmClient> log) => _log = log;

    public Task<LlmDecision> GenerateSqlAsync(string question, string schemaSlice, CancellationToken ct = default)
    {
        var q = question.ToLowerInvariant();

        // Always include the planner's "thinking" so the UI can show it —
        // this is what makes the pipeline look agentic, not just templated.
        string Plan(string s) => "Plan:\n" + s + "\n\nSchema slice (truncated): "
                                + (schemaSlice.Length > 220 ? schemaSlice[..220] + "…" : schemaSlice);

        // ── churn by tier × region ────────────────────────────────────────
        if (q.Contains("churn") && (q.Contains("tier") || q.Contains("plan"))
                                && (q.Contains("emea") || q.Contains("region")))
        {
            return Sql(@"
SELECT pt.tier_code,
       g.region,
       COUNT(ce.churn_event_id)::float
         / NULLIF(COUNT(DISTINCT s.subscription_id), 0) AS churn_rate
  FROM subscription s
  JOIN plan_tier pt ON pt.tier_id = s.tier_id
  JOIN customer  c  ON c.customer_id = s.customer_id
  JOIN geography g  ON g.geo_id = c.geo_id
  LEFT JOIN churn_event ce ON ce.subscription_id = s.subscription_id
 WHERE g.region = 'EMEA'
 GROUP BY pt.tier_code, g.region
 ORDER BY churn_rate DESC",
                Plan(@"
  1. Map ""plan tier"" → plan_tier.tier_code (FYI: renamed from plan_code in 2026-Q1).
  2. Map ""EMEA"" → geography.region.
  3. Need JOIN customer → geography for region; subscription → plan_tier for tier.
  4. Churn rate = churn_events / subscriptions, grouped."));
        }

        // ── churn by channel ──────────────────────────────────────────────
        if (q.Contains("churn") && (q.Contains("channel") || q.Contains("acquisition")))
        {
            return Sql(@"
SELECT ac.channel_name,
       COUNT(ce.churn_event_id)::float
         / NULLIF(COUNT(DISTINCT s.subscription_id), 0) AS churn_rate,
       COUNT(DISTINCT s.subscription_id) AS subscriptions
  FROM subscription s
  JOIN customer c  ON c.customer_id = s.customer_id
  JOIN acquisition_channel ac ON ac.channel_id = c.channel_id
  LEFT JOIN churn_event ce ON ce.subscription_id = s.subscription_id
 GROUP BY ac.channel_name
 ORDER BY churn_rate DESC",
                Plan(@"
  1. ""channel"" → acquisition_channel.channel_name.
  2. Join customer → acquisition_channel.
  3. Churn rate as before."));
        }

        // ── MRR / ARR by tier ─────────────────────────────────────────────
        if ((q.Contains("mrr") || q.Contains("arr") || q.Contains("revenue") || q.Contains("monthly"))
            && (q.Contains("tier") || q.Contains("plan")))
        {
            return Sql(@"
SELECT pt.tier_code,
       SUM(pt.monthly_usd * s.seat_count) AS mrr_usd,
       SUM(pt.monthly_usd * s.seat_count) * 12 AS arr_usd
  FROM subscription s
  JOIN plan_tier pt ON pt.tier_id = s.tier_id
 WHERE s.cancelled_at IS NULL
 GROUP BY pt.tier_code
 ORDER BY mrr_usd DESC",
                Plan(@"
  1. MRR = sum of plan_tier.monthly_usd × subscription.seat_count for active subs.
  2. Active = cancelled_at IS NULL.
  3. ARR = MRR × 12."));
        }

        // ── active subscriptions by region ────────────────────────────────
        if ((q.Contains("active") || q.Contains("current")) && q.Contains("subscription"))
        {
            return Sql(@"
SELECT g.region, COUNT(*) AS active_subscriptions
  FROM subscription s
  JOIN customer  c ON c.customer_id = s.customer_id
  JOIN geography g ON g.geo_id = c.geo_id
 WHERE s.cancelled_at IS NULL
 GROUP BY g.region
 ORDER BY active_subscriptions DESC",
                Plan(@"
  1. Active = cancelled_at IS NULL.
  2. Group by macro region."));
        }

        // ── top customers by invoice ──────────────────────────────────────
        if (q.Contains("top") && (q.Contains("customer") || q.Contains("client"))
                              && (q.Contains("invoice") || q.Contains("spend") || q.Contains("revenue")))
        {
            return Sql(@"
SELECT c.company_name,
       SUM(i.amount_usd) AS total_invoiced
  FROM invoice i
  JOIN subscription s ON s.subscription_id = i.subscription_id
  JOIN customer c     ON c.customer_id     = s.customer_id
 GROUP BY c.company_name
 ORDER BY total_invoiced DESC
 LIMIT 10",
                Plan(@"
  1. Sum invoice.amount_usd per customer.
  2. Note: customer.email is PII — we do NOT select it.
  3. Top N → ORDER BY ... LIMIT 10."));
        }

        // ── signups by month ──────────────────────────────────────────────
        if ((q.Contains("signup") || q.Contains("new") || q.Contains("acquired")) && q.Contains("month"))
        {
            return Sql(@"
SELECT date_trunc('month', signed_up_at)::date AS month,
       COUNT(*) AS new_customers
  FROM customer
 GROUP BY 1
 ORDER BY 1",
                Plan("New customers by month → date_trunc on customer.signed_up_at."));
        }

        // ── list-tables helper ────────────────────────────────────────────
        if (Regex.IsMatch(q, @"\b(list|show|what)\b.*\btables?\b"))
        {
            return Sql(@"
SELECT table_name
  FROM information_schema.tables
 WHERE table_schema = 'public'
 ORDER BY table_name",
                Plan("User asked for the table list → query information_schema.tables."));
        }

        // ── refusal: clearly out-of-domain or write-intent ────────────────
        if (Regex.IsMatch(q, @"\b(delete|drop|truncate|update|insert|grant|alter)\b"))
        {
            return Refuse("This system is read-only. Write/DDL operations are not permitted.");
        }

        // ── fallback "I don't know" path ──────────────────────────────────
        return Refuse(@"I don't have a confident SQL mapping for that question against the available schema.
Try one of: ""churn rate by plan tier in EMEA"", ""MRR by tier"",
""active subscriptions by region"", ""top customers by invoice"".");
    }

    private static Task<LlmDecision> Sql(string sql, string plan) =>
        Task.FromResult(new LlmDecision(false, sql.Trim(), null, plan));

    private static Task<LlmDecision> Refuse(string reason) =>
        Task.FromResult(new LlmDecision(true, null, reason, null));
}
