# Yuruna Text-to-SQL Example

> **Status: Early release.** Runs locally against PostgreSQL and
> deploys through the full Yuruna three-phase model (`Set-Resource` /
> `Set-Component` / `Set-Workload`); see the
> [Yuruna integration](#yuruna-integration) section below. Claude
> activates when `ANTHROPIC_API_KEY` is set.

A read-only agentic text-to-SQL application: ASP.NET Core (.NET 10) Razor
Pages on top of PostgreSQL, implementing a six-stage agent pipeline with
schema retrieval, static validation, and an EXPLAIN-based cost gate.

This example shows what an action-gated, observable agent looks like end
to end. The default `ILlmClient` is a deterministic rule-based stand-in
so the example runs offline against a local PostgreSQL; setting
`ANTHROPIC_API_KEY` activates the real Claude tool-use client
(`Services/ClaudeLlmClient.cs`) at runtime.

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
| ① Planner (LLM) | `Services/ClaudeLlmClient.cs` (Anthropic tool-use, active when `ANTHROPIC_API_KEY` is set) or `Services/RuleBasedLlmClient.cs` (deterministic stub, the offline default) |
| ② Schema Retriever | `Services/SchemaCatalog.cs` (FK-aware) |
| ③ SQL Generator | shared with ① in this example |
| ④ Validator / Guardrail | `Services/SqlValidator.cs` (static + EXPLAIN gate) |
| ⑤ Executor | `Services/AgentOrchestrator.cs` |
| ⑥ Observer | the timeline on `Pages/Index.cshtml` |

The **`ILlmClient`** interface (`Services/ILlmClient.cs`) is the seam
the real Claude / Anthropic tool-use loop plugs into without touching
the rest of the pipeline: `Services/ClaudeLlmClient.cs` is that
implementation, and `Program.cs` selects it at runtime whenever
`ANTHROPIC_API_KEY` is present.

## Yuruna integration

This example follows the same folder pattern as
[`example/website`](../website/README.md) — `components/frontend/<app>/` —
and deploys through the Yuruna three-phase model (`Set-Resource` /
`Set-Component` / `Set-Workload`). The pieces are in place:

- `config/localhost/{resources,components,workloads}.yml` drive the
  three phases.
- `components/frontend/text-to-sql-ui/Dockerfile` builds the container
  image during `Set-Component`.
- The helm chart under
  [`workloads/frontend/text-to-sql-ui/`](workloads/frontend/text-to-sql-ui/)
  deploys it to Kubernetes (pod + TLS ingress) during `Set-Workload`.
- The [`test/`](test/) workload exercises the whole cycle on a guest
  Kubernetes node.

The same `ILlmClient` selection applies in the deployed container:
set `ANTHROPIC_API_KEY` to run against Claude, leave it unset to run
the offline rule-based client.

### Development certificate

Generate the dev HTTPS certificate **before** the Docker / Yuruna
build. `Set-Component` runs `copy-pfx.ps1`, which copies
`$HOME/.aspnet/https/aspnetapp.pfx` into the build context, and the
`Dockerfile` then `COPY`s that pfx into the image. If the pfx does not
exist yet, `copy-pfx.ps1` fails loudly with the exact command to run.

```powershell
dotnet dev-certs https --check --trust              # check
mkdir $HOME/.aspnet/https
dotnet dev-certs https -ep $HOME/.aspnet/https/aspnetapp.pfx -p { password here }
dotnet dev-certs https --trust
```

If "A valid HTTPS certificate is already present" → `dotnet dev-certs https --clean` and retry.

## Files

```
example/text-to-sql/
├── README.md                        ← this file
├── db/
│   └── schema.sql                   ← Postgres schema + seed data
├── config/
│   └── localhost/                   ← resources · components · workloads (three-phase config)
├── workloads/
│   └── frontend/text-to-sql-ui/     ← helm chart (pod + TLS ingress)
├── test/                            ← guest-Kubernetes deployment test
└── components/
    └── frontend/
        └── text-to-sql-ui/
            ├── text-to-sql-ui.csproj
            ├── Program.cs
            ├── Dockerfile
            ├── copy-pfx.ps1          ← copies the dev cert into the build context
            ├── appsettings*.json
            ├── Properties/launchSettings.json
            ├── Pages/                ← Index · Schema · About · Error · Layout
            ├── Services/             ← ILlmClient · SchemaCatalog · SqlValidator
            │                            · AgentOrchestrator · RuleBasedLlmClient
            │                            · ClaudeLlmClient
            └── wwwroot/css/site.css
```

Back to [Yuruna](https://yuruna.com) or [Examples](../README.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.
