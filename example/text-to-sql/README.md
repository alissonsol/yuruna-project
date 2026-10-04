<a id="4286c679-0001"></a>

# Yuruna Text-to-SQL Example

> **Status: Early release.** Runs locally against PostgreSQL and
> deploys through the full Yuruna three-phase model (`Set-Resource` /
> `Set-Component` / `Set-Workload`); see
> [Yuruna integration](#yuruna-integration) below. Claude
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

<a id="4286c679-0002"></a>

## Quick start

<a id="4286c679-0003"></a>

<a id="1--prepare-postgresql"></a>

### 1 - Prepare PostgreSQL

Any local PostgreSQL >= 14 works (Docker image, a Yuruna guest
`<guest>.postgresql.sh` setup script, or a native install). With a superuser,
create the database and load the schema:

```powershell
psql -h localhost -U postgres -c "CREATE DATABASE yuruna_demo;"
psql -h localhost -U postgres -d yuruna_demo -f db/schema.sql
```

`schema.sql` creates a `yuruna_agent_ro` role with `SELECT` grants on explicit
safe columns. It removes blanket grants and their defaults, so `customer.email`,
wildcard reads containing that column, and whole-customer-row reads are denied
by PostgreSQL. Future columns receive no automatic access. The .NET app must
connect as this role, never as the database owner.

The role is created without a password, so no file in the repository holds a
credential. A login role with no password cannot authenticate over `scram-sha-256`
or `md5` (a `trust` rule in `pg_hba.conf` would still admit it, so keep one out of
reach of this role). Set a password before the app connects; the prompt keeps it
out of the shell history:

```powershell
psql -h localhost -U postgres -d yuruna_demo -c "\password yuruna_agent_ro"
```

On a Yuruna guest the database setup script does this for you: it generates a
random password on every run (see [Yuruna integration](#yuruna-integration)).

<a id="4286c679-0004"></a>

<a id="2--run-the-net-app"></a>

### 2 - Run the .NET app

```powershell
cd components/frontend/text-to-sql-ui
dotnet run
```

Then open <http://localhost:5080>.

The app holds no default password. It takes the connection from the first of
these that is set, and stops at startup with a message naming all three when
none is:

1. `TEXT2SQL_PG_CONN`: a complete connection string.
2. The `ConnectionStrings:Postgres` configuration key, for example from
   `dotnet user-secrets` or the `ConnectionStrings__Postgres` environment
   variable. `appsettings.json` deliberately carries no connection string, so
   that the next option stays reachable and no password can be committed there.
3. `TEXT2SQL_PG_PASSWORD`: the password of `yuruna_agent_ro` alone. The app then
   connects to `localhost` as that role, database `yuruna_demo`, and quotes the
   password, whatever characters it holds.

```powershell
$env:TEXT2SQL_PG_PASSWORD = Read-Host -MaskInput "yuruna_agent_ro password"
dotnet run
```

Or give the whole string, replacing the placeholder with the password you set:

```powershell
$env:TEXT2SQL_PG_CONN = "Host=localhost;Username=yuruna_agent_ro;Password=<password>;Database=yuruna_demo"
dotnet run
```

<a id="4286c679-0005"></a>

## What the app demonstrates

The home page shows the agent pipeline as a live timeline. Every question
runs through six observable stages:

```
Question -> Schema Retrieval -> SQL Generation -> Static Validation
                  -> EXPLAIN Cost Gate -> Execute -> Observer (this timeline)
```

Try these prompts:

| Prompt | What it shows |
| ------ | ------------- |
| `churn rate by plan tier in EMEA` | regional aggregation + the `plan_code -> tier_code` rename trap |
| `MRR by tier` | aggregation across `plan_tier` x `subscription` |
| `active subscriptions by region` | NULL-handling on `cancelled_at` |
| `top 10 customers by invoice` | PII column (`customer.email`) is **not** selected |
| `drop table customer` | the static validator refuses and the timeline shows it stopping at stage 3 |

The **`/Schema`** page renders what the schema retriever indexes -- the
same catalog the agent uses, viewable as ground truth.

<a id="4286c679-0006"></a>

## Architecture map

| Stage | Implementation |
| ----- | -------------- |
| (1) Planner (LLM) | `Services/ClaudeLlmClient.cs` (Anthropic tool-use, active when `ANTHROPIC_API_KEY` is set) or `Services/RuleBasedLlmClient.cs` (deterministic stub, the offline default) |
| (2) Schema Retriever | `Services/SchemaCatalog.cs` (FK-aware) |
| (3) SQL Generator | shared with (1) in this example |
| (4) Validator / Guardrail | `Services/SqlValidator.cs` (static + EXPLAIN gate) |
| (5) Executor | `Services/AgentOrchestrator.cs` |
| (6) Observer | the timeline on `Pages/Index.cshtml` |

<a id="4286c679-0007"></a>

### Service notes

Per-service design notes referenced from the file-top comments
(`https://yuruna.link/4286c679-0007`).

**`Program.cs`** -- minimal Razor Pages host. Three things are wired up:
Razor Pages for the chat UI, an Npgsql `DataSource` for the read-only
PostgreSQL connection, and the agent services
(SchemaCatalog -> SqlValidator -> AgentOrchestrator). The orchestrator
uses the deterministic rule-based "LLM" by default; when
`ANTHROPIC_API_KEY` is set the ClaudeLlmClient path is swapped in
through the same `ILlmClient` seam. `Services/PostgresConnectionString.cs`
chooses the connection string (see [Run the .NET app](#2--run-the-net-app)) and
fails startup rather than fall back to a built-in password.

**`Services/ILlmClient.cs`** -- the seam shape: `GenerateSqlAsync` takes
the question plus the FK-expanded schema slice and returns either a SQL
string or a refusal with a reason. Three implementations exist so the
example runs reproducibly with or without an LLM dependency:
`RuleBasedLlmClient` (deterministic, offline, no API key),
`ClaudeLlmClient` (Anthropic Messages API with tool-use), and
`OllamaLlmClient` (local Ollama server, activated by `USE_LOCAL_MODEL`).

**`Services/RuleBasedLlmClient.cs`** -- deterministic stand-in for the
"(3) SQL Generator (LLM)" box. Pattern coverage matches the seed data:
churn rate by plan tier / region / channel / quarter, MRR / ARR by
tier, active subscriptions / new signups, top customers by invoice
amount, and a no-answer path for out-of-domain prompts. Every match
returns a confidence score and the same prose a real LLM would produce
in a "plan" channel, so the UI shows realistic agent reasoning.

**`Services/SchemaCatalog.cs`** -- the "(2) Schema Retriever" stage.
Build-time: introspects `information_schema` + `pg_constraint` to
materialize per-column metadata (name, type, nullable, sample values),
per-table prose (from `COMMENT ON`), and the foreign-key graph as a
sidecar. Query-time: `get_relevant_schema(question, k)` uses hybrid
scoring (keyword overlap plus substring similarity on docstrings) with
one-hop FK expansion so the LLM never has to invent JOIN partners, and
returns a compact prompt slice (target < 2 KB). A production system
would use a real vector index (pgvector or a hosted store); keeping it
deterministic keeps the example offline and reproducible. Successful catalog loads
are shared and cached; a failed load is retried on the next request. Concurrent
callers share one load, and canceling one caller does not poison the shared cache.

**`Services/SqlValidator.cs`** -- the "(4) Validator (Guardrail)" stage.
Its dependency-free `SqlQueryPolicy` enforces: (1) exactly one statement,
and that statement a SELECT
(or `WITH ... SELECT`) -- DDL/DML verbs are rejected; (2) no mid-query
semicolons (stacked statements); (3) no comments that could hide a
payload; (4) explicit non-PII projections, rejecting wildcard/whole-row reads;
(5) a top-level LIMIT, appended when missing or capped when present, without
moving the authored ORDER BY. `SqlValidator` adds an EXPLAIN cost gate that
refuses a plan when any node's estimated row count exceeds the configured threshold.
It parses the JSON plan recursively, so an outer LIMIT cannot hide a large scan,
sort, or join input. This is a conservative cardinality gate, not an execution-time
or monetary cost estimate. Connection, transaction, and malformed-plan failures
produce a failed EXPLAIN timeline step; caller cancellation remains cancellation.
The policy tokenizes quoted SQL text but conservatively rejects some valid
expressions; it is not a complete PostgreSQL parser. The database role's
column permissions enforce data access independently of these static checks.

**`Services/ClaudeLlmClient.cs`** -- production `ILlmClient` backed by
the Anthropic Messages API with tool-use for structured output; the
"(3) SQL Generator (LLM)" role in the orchestrator. Returns an
`LlmDecision` with `Sql` (raw SELECT, no markdown fences), `PlanText`
(reasoning shown in the UI observer), `Refused`, and `RefusalReason`.

**`Services/OllamaLlmClient.cs`** -- local-first `ILlmClient` backed by
an Ollama server (default `http://127.0.0.1:11434`) running a local
coding model (e.g. `qwen3-coder`); activated by `USE_LOCAL_MODEL` /
`OLLAMA_HOST`, keeping the schema and questions on-device instead of
calling a third-party API. Mirrors `ClaudeLlmClient`'s structured-output
contract: a parsed `Refused=true` is a normal `LlmDecision`, and every
other failure mode throws `LlmClientException`. An accepted decision must contain
nonblank SQL; a refusal requires a reason and no SQL. The orchestrator validates
this contract even for alternate client implementations. Both HTTP clients share
a total retry deadline (Claude 90 seconds, Ollama 240 seconds), including body
reads and backoff, while retaining their respective transient-status policies.
Per-attempt messages are disposed, and singleton shutdown disposes the owned client.
A failed call is never reduced to a deadline: `LlmClientException.Failure` records
the dependency (`anthropic` or `ollama`) and its host, the last error kind (timeout,
transport, HTTP status, rate limit, canceled by the budget, or parse) with the last
HTTP status, the attempt count, the elapsed time, and whether the budget ran out,
and the last exception stays as `InnerException`. Each retried attempt is logged as
a warning; the orchestrator logs the final failure once and keeps it on the run as
`AgentRun.Failure`. A caller's own cancellation is never converted: it propagates as
`OperationCanceledException`. Host names exclude any credentials or query in a
configured URL.

New service diagnostics use standard .NET resources for English, Brazilian
Portuguese, Simplified Chinese, and Hebrew. Request localization selects culture
from the normal ASP.NET Core providers, including `Accept-Language`; unsupported
languages fall back to English. Translated resource comments record machine origin
and source hashes. Existing English UI prose remains unchanged.

From the `example/text-to-sql` directory, run
`dotnet run --project tests/ServiceContracts.Tests` for parser, deadline,
failure-detail, cancellation, disposal, localization, connection-string
resolution, and database-unavailability checks. The same program fails when any
file of the example carries a literal database password. Set
`SERVICE_CONTRACT_DATABASE` to a disposable PostgreSQL connection string to add
live EXPLAIN and shared-cache checks. No model API is called by these tests.

**`Services/AgentOrchestrator.cs`** -- the "(5) Executor" plus retry loop.
Runs the stages in order (schema retriever -> SQL generator -> static
validator -> EXPLAIN cost gate -> executor) and emits a `Step` per stage
with elapsed-ms, status, and notes; the UI renders one run as a single
timeline -- the "Observer" layer in miniature. `SqlResultReader` independently
caps returned rows at `Agent:MaxRowsReturned`, including FETCH WITH TIES and
expression limits, preserving database ordering and smaller query results.

<a id="4286c679-0008"></a>

## Yuruna integration

This example follows the same folder pattern as
[`example/website`](../website/README.md) -- `components/frontend/<app>/` --
and deploys through the Yuruna three-phase model. The pieces are in place:

- `config/localhost/{resources,components,workloads}.yml` drive the
  three phases.
- `components/frontend/text-to-sql-ui/Dockerfile` builds the container
  image during `Set-Component`.
- The Helm chart under
  [`workloads/frontend/text-to-sql-ui/`](workloads/frontend/text-to-sql-ui/)
  deploys it to Kubernetes (pod + TLS ingress) during `Set-Workload`, after
  `create-cert-secret.ps1` creates the pod's certificate Secret (see
  [Development certificate](#development-certificate)) and
  `create-db-secret.ps1` creates the Secret `text-to-sql-db` that holds the
  database password. The pod reads that password through `secretKeyRef` into
  `TEXT2SQL_PG_PASSWORD`, and the deployment builds `TEXT2SQL_PG_CONN` from it,
  pointing at `status.hostIP` (the node), so the pod reaches the host's
  PostgreSQL over the pod network.
- `test/ubuntu.server.24/ubuntu.server.24.workload.k8s.text-to-sql.db.sh`
  brings up the host database: it forces `ssl = off`, opens
  `listen_addresses`/`pg_hba` for the pod CIDR, creates `yuruna_demo`, and
  loads [`db/schema.sql`](db/schema.sql) (which also creates the read-only
  `yuruna_agent_ro` role the app connects as, without a password). Each run
  then generates a new random password (`openssl rand -hex 24`) for that role.
  The password reaches `psql` on standard input when it is set, and through
  `PGPASSWORD` for the one login probe, so it appears in no argument list,
  output line, or `set -x` trace. A copy is kept in
  `~/.text-to-sql/agent_ro.password` of the guest user (directory mode 700, file
  mode 600, one line). `create-db-secret.ps1` reads that file, or the file named
  by its `-SidecarFile` parameter, and stops with a message naming the file and
  this setup step when it is missing or empty. To deploy from another machine,
  write the role's password on one line in that file first, using only letters,
  digits, and `. _ ~ + / -`: Kubernetes substitutes it into the connection
  string, where other characters would add or change connection keywords.
- The [`test/`](test/) workload exercises the whole cycle on a guest
  Kubernetes node -- the `.baseline` sequence installs Kubernetes and
  checkpoints it; the `.test` sequence restores that checkpoint, sets up
  PostgreSQL, deploys, and asserts `HTTP 200`. Both run unattended.

The same `ILlmClient` selection applies in the deployed container:
set `ANTHROPIC_API_KEY` to run against Claude, leave it unset to run
the offline rule-based client.

<a id="4286c679-0009"></a>

### Development certificate

The image holds no certificate and no password. Generate the dev HTTPS
certificate **before** the Docker / Yuruna build. `Set-Component` runs
`copy-pfx.ps1`, which only checks that `$HOME/.aspnet/https/aspnetapp.pfx` opens
with the password in `ASPNETCORE_Kestrel__Certificates__Default__Password` and
fails loudly, with the exact command to run, when it does not. `Set-Workload`
then runs `create-cert-secret.ps1`, which re-exports that certificate under a
newly generated password into the Secret `text-to-sql-ui-pod-cert`; the chart
mounts the certificate at `/https` and reads the password through `secretKeyRef`.
Guest VMs store the development certificate's password in
`~/.aspnet/https/aspnetapp.pfx.password` (readable only by its owner), and the
example reads that file when `ASPNETCORE_Kestrel__Certificates__Default__Password`
is unset.

```powershell
dotnet dev-certs https --check --trust              # check
mkdir $HOME/.aspnet/https
$env:ASPNETCORE_Kestrel__Certificates__Default__Password = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
dotnet dev-certs https -ep $HOME/.aspnet/https/aspnetapp.pfx -p $env:ASPNETCORE_Kestrel__Certificates__Default__Password
dotnet dev-certs https --trust
```

If "A valid HTTPS certificate is already present" -> `dotnet dev-certs https --clean` and retry.

The design, the throwaway certificate that automation uses when no developer
certificate exists, and the commands that prove an image carries no key are in the
[website component README](../website/components/frontend/website/README.md#development-certificate).

The certificate and image-seeding wrappers load the bundled `Example.Build.psm1`
from their own build context. Its canonical source is
[`tools/Example.Build.psm1`](../../tools/Example.Build.psm1); run
`pwsh tools/Sync-ExampleBuildModule.ps1` from the repository root after editing it.
`-Check` verifies both bundles without writing. Each example can still be copied
and built independently.

**Local verification**

The dependency-free policy/result-reader test executable links the actual
production sources and runs with the .NET 8 SDK; the application remains on
.NET 10. From the repository root:

```powershell
dotnet run --project example/text-to-sql/tests/SqlPolicy.Tests
pwsh tools/Test-ExampleBuild.ps1
pwsh example/text-to-sql/tests/Test-DatabaseSecret.ps1
python example/text-to-sql/tests/db_script_contracts.py
```

The last two check the database password flow with stand-ins for `kubectl`,
`sudo`, and `psql`: the password must differ on every run and stay out of every
argument list, output stream, and `set -x` trace, reach `psql` only on standard
input (or in `PGPASSWORD` for the login probe), and be stored in an owner-only
file that the Secret script reads back.
They need `pwsh` and `python` (on Windows, Git for Windows' `usr\bin\bash.exe`),
and add the chart checks when `helm` and the `powershell-yaml` module are
installed. No cluster or PostgreSQL is needed.

After loading the schema in a disposable PostgreSQL database, verify the role's
permissions and readable schema as the database owner:

```powershell
psql -v ON_ERROR_STOP=1 -h localhost -U postgres -d yuruna_demo -f example/text-to-sql/db/test-agent-permissions.sql
```

The database fixture checks direct, wildcard, whole-row, JSON, and write
attempts, along with safe aggregation, column introspection, and foreign keys.
The guest database setup runs this check automatically after loading the schema.

<a id="4286c679-000a"></a>

## Files

```
example/text-to-sql/
+-- README.md                        <- this file
+-- db/
|   +-- schema.sql                   <- PostgreSQL schema + seed data
+-- config/
|   +-- localhost/                   <- resources - components - workloads (three-phase config)
+-- workloads/
|   +-- frontend/text-to-sql-ui/     <- helm chart (pod + TLS ingress)
+-- test/                            <- guest-Kubernetes deployment test
+-- tests/                           <- contract tests (C#, Python, PowerShell)
+-- components/
    +-- frontend/
        +-- text-to-sql-ui/
            +-- text-to-sql-ui.csproj
            +-- Program.cs
            +-- Dockerfile
            +-- .dockerignore         <- keeps *.pfx and other key files out of every build stage
            +-- copy-pfx.ps1          <- checks that the dev cert opens (nothing is copied)
            +-- create-cert-secret.ps1 <- creates the pod certificate Secret with a generated password
            +-- create-db-secret.ps1  <- creates the database password Secret from the file the DB setup step writes
            +-- seed-base-images.ps1  <- pushes the Dockerfile's base images to the local registry
            +-- appsettings*.json
            +-- Properties/launchSettings.json
            +-- Pages/                <- Index - Schema - About - Error - Layout
            +-- Services/             <- ILlmClient - SchemaCatalog - SqlValidator
            |                            - AgentOrchestrator - RuleBasedLlmClient
            |                            - ClaudeLlmClient - OllamaLlmClient
            +-- wwwroot/css/site.css
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.04

Back to [yuruna-project](../../README.md) - [Yuruna](https://yuruna.com)
