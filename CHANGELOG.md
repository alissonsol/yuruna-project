# Changelog

`yuruna-project` uses [Calendar Versioning](https://calver.org/):
`YYYY.MM.DD`. The framework lives at
[github.com/alissonsol/yuruna](https://github.com/alissonsol/yuruna);
this repo tracks user-facing project templates and end-to-end examples.

## 2026.10.04

- **Schema change**: `testSets` is removed from `test/test.runner.yml`; the
  pool-control Pools page assigns a Framework URL and Project URL together,
  and the project repository supplies its own sequence list.
- The text-to-SQL example adds column-level grants, bounded query and result
  handling through `SqlQueryPolicy` and `SqlResultReader`, and database recovery
  checks.
- Both examples use the shared `Example.Build.psm1` module. The AWS website
  workload uses NodePort ingress.
- **Behavior change**: the website and text-to-SQL images no longer carry the
  development certificate or its password, and the charts no longer hold a
  literal password. Each deployment creates a Kubernetes Secret
  (`create-cert-secret.ps1`) that holds the certificate under a newly generated
  password; the pod mounts the certificate and reads the password through
  `secretKeyRef`. Set `ASPNETCORE_Kestrel__Certificates__Default__Password` to the
  password used when exporting `$HOME/.aspnet/https/aspnetapp.pfx` before running
  `Set-Component`, `Set-Workload`, or `docker-run-dev`, or keep it on one line in
  `aspnetapp.pfx.password` beside the certificate: the examples read that file
  when the variable is unset or empty, `docker-run-dev.ps1` and
  `docker-run-dev.cmd` pass it on to Docker by name, and failure messages name
  both sources. Yuruna's guest `k8s` provisioning writes the file, so guest runs
  need no variable. Automation without a developer certificate sets
  `YURUNA_EXAMPLE_SELF_SIGNED_CERT=1`. Remove earlier
  images that contain `aspnetapp.pfx` from every registry, and regenerate the
  certificate (`dotnet dev-certs https --clean`) if such an image was ever pushed.
- **Behavior change**: the text-to-SQL example no longer carries a database
  password. `db/schema.sql` creates `yuruna_agent_ro` without one; the guest
  database setup script sets a new random password on every run and keeps it in
  the owner-only file `~/.text-to-sql/agent_ro.password`; `create-db-secret.ps1`
  publishes it as the Secret `text-to-sql-db`; and the pod reads it through
  `secretKeyRef` into `TEXT2SQL_PG_PASSWORD`. The application has no built-in
  connection string and `appsettings.json` has no `ConnectionStrings` entry, so
  startup fails unless `TEXT2SQL_PG_CONN`, `ConnectionStrings:Postgres`, or
  `TEXT2SQL_PG_PASSWORD` is set. A database created earlier keeps its old role
  password until the setup script runs again; treat the previous demo password
  as public and replace it. `tests/Test-DatabaseSecret.ps1` and
  `tests/db_script_contracts.py` check that the password differs on every run
  and stays out of argument lists, output, and `set -x` traces.
- The text-to-SQL model clients no longer reduce a failed call to a deadline:
  `LlmClientException.Failure` carries the dependency, last error kind and HTTP
  status, attempt count, and elapsed time, with the last exception as the inner
  exception. Each retried attempt is logged, and the orchestrator logs the final
  failure and keeps it on the run. Caller cancellation still propagates as
  `OperationCanceledException`.
- Project display text now has machine translation drafts for Simplified
  Chinese and Hebrew, pending professional review.

## 2026.07.31

- **Schema change**: Non-breaking addition of `testSets`, with `name`,
  `displayName`, and `description`.

## 2026.07.24

- **Schema change**: Breaking change to test sequences, plus project adjustments.

## 2026.07.14

- Minor fixes to enable the automated release.

## 2026.06.05

- [example/text-to-sql/](example/text-to-sql/) -- the full three-phase
  Yuruna deployment is now wired up. `config/localhost/{resources,
  components,workloads}.yml`, the helm chart under
  [`workloads/frontend/text-to-sql-ui/`](example/text-to-sql/workloads/frontend/text-to-sql-ui/),
  a `Dockerfile`, and the
  [`test/`](example/text-to-sql/test/) workload deploy the app to
  Kubernetes the same way the website example does.
- `Services/ClaudeLlmClient.cs` ships as the production `ILlmClient`:
  `Program.cs` activates it at runtime when `ANTHROPIC_API_KEY` is set
  and falls back to the deterministic rule-based client otherwise.

## 2026.05.15

First publicly tracked release.

- [template/](template/) -- empty project scaffold (resources,
  components, workloads, config, test).
- [example/website/](example/website/) -- .NET C# website container
  deployed to Kubernetes on localhost, Azure, and AWS, demonstrating
  resource + component + workload wiring and TLS via cert-manager.
- [example/text-to-sql/](example/text-to-sql/) -- **Early release.**
  Agentic read-only text-to-SQL on ASP.NET Core + PostgreSQL, running
  locally against PostgreSQL.
- **License**: [LICENSE.md](LICENSE.md) is now titled "Yuruna License"
  (based on the MIT License) and adds a plain-language "No Warranty /
  'As Is'" restatement plus an explicit "Administrator Risk Warning"
  section covering scripts that require elevated/root privileges.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.04

Back to [yuruna-project](README.md) - [Yuruna](https://yuruna.com)
