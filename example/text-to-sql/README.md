# Yuruna Text-to-SQL Example

> **Status: Early release.** Runs locally against PostgreSQL today.
> The full Yuruna three-phase deployment (`Set-Resource` /
> `Set-Component` / `Set-Workload`) is not yet wired up; see the
> [Yuruna integration](#yuruna-integration) section below.

A read-only agentic text-to-SQL application: ASP.NET Core (.NET 10) Razor
Pages on top of PostgreSQL, implementing a six-stage agent pipeline with
schema retrieval, static validation, and an EXPLAIN-based cost gate.

This example shows what an action-gated, observable agent looks like end
to end, without an LLM dependency: the default `ILlmClient` is a
deterministic rule-based stand-in so the example runs offline against a
local PostgreSQL.

| Path | What it is |
| ---- | ---------- |
| [db/schema.sql](db/schema.sql) | PostgreSQL schema + seed data (subscriptions / churn / invoices) |
| [components/frontend/text-to-sql-ui/](components/frontend/text-to-sql-ui/) | ASP.NET Core (.NET 10) Razor Pages app implementing the six-stage architecture |

## Quick start

### 1 · Prepare PostgreSQL

Any local PostgreSQL ≥ 14 works (Docker image, the Yuruna `guest.postgres`
component, or a native install). With a superuser, create the database
and load the schema:

```powershell
psql -h localhost -U postgres -c "CREATE DATABASE yuruna_demo;"
psql -h localhost -U postgres -d yuruna_demo -f db/schema.sql
```

`schema.sql` creates a `yuruna_agent_ro` role with `SELECT`-only grants —
that is the action-gating layer at the database level. The .NET app
connects as that role.

### 2 · Run the .NET app

```powershell
cd components/frontend/text-to-sql-ui
dotnet run
```

Then open <http://localhost:5080>.

Override the connection string if needed:

```powershell
$env:TEXT2SQL_PG_CONN = "Host=localhost;Username=yuruna_agent_ro;Password=agent_demo_password;Database=yuruna_demo"
dotnet run
```

## What the app demonstrates

The home page shows the agent pipeline as a live timeline. Every question
runs through six observable stages:

```
Question → Schema Retrieval → SQL Generation → Static Validation
                  → EXPLAIN Cost Gate → Execute → Observer (this timeline)
```

Try these prompts:

| Prompt | What it shows |
| ------ | ------------- |
| `churn rate by plan tier in EMEA` | regional aggregation + the `plan_code → tier_code` rename trap |
| `MRR by tier` | aggregation across `plan_tier` × `subscription` |
| `active subscriptions by region` | NULL-handling on `cancelled_at` |
| `top 10 customers by invoice` | PII column (`customers.email`) is **not** selected |
| `drop table customer` | the static validator refuses and the timeline shows it stopping at stage 3 |

The **`/Schema`** page renders what the schema retriever indexes — the
same catalog the agent uses, viewable as ground truth.

## Architecture map

| Stage | Implementation |
| ----- | -------------- |
| ① Planner (LLM) | `Services/RuleBasedLlmClient.cs` (deterministic stub) |
| ② Schema Retriever | `Services/SchemaCatalog.cs` (FK-aware) |
| ③ SQL Generator | shared with ① in this example |
| ④ Validator / Guardrail | `Services/SqlValidator.cs` (static + EXPLAIN gate) |
| ⑤ Executor | `Services/AgentOrchestrator.cs` |
| ⑥ Observer | the timeline on `Pages/Index.cshtml` |

The **`ILlmClient`** interface (`Services/ILlmClient.cs`) is the seam
where a real Claude / Anthropic tool-use loop drops in without touching
the rest of the pipeline.

## Yuruna integration

This example follows the same folder pattern as
[`example/website`](../website/README.md) — `components/frontend/<app>/` —
so it can be deployed through the Yuruna three-phase model
(`Set-Resource` / `Set-Component` / `Set-Workload`) once a Dockerfile and
the matching `config/` resources are added. The current example stops at
"runs locally against PostgreSQL" so that the agent architecture stays
the focus.

## Files

```
example/text-to-sql/
├── README.md                        ← this file
├── db/
│   └── schema.sql                   ← Postgres schema + seed data
└── components/
    └── frontend/
        └── text-to-sql-ui/
            ├── text-to-sql-ui.csproj
            ├── Program.cs
            ├── appsettings*.json
            ├── Properties/launchSettings.json
            ├── Pages/                ← Index · Schema · About · Error · Layout
            ├── Services/             ← ILlmClient · SchemaCatalog · SqlValidator
            │                            · AgentOrchestrator · RuleBasedLlmClient
            └── wwwroot/css/site.css
```

Back to [Yuruna](https://yuruna.com) or [Examples](../README.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.
