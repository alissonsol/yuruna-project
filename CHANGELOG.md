# Changelog

`yuruna-project` uses [Calendar Versioning](https://calver.org/):
`YYYY.MM.DD`. The framework lives at
[github.com/alissonsol/yuruna](https://github.com/alissonsol/yuruna);
this repo tracks user-facing project templates and end-to-end examples.

## 2026.10.18.1

- **None.** No updates.

## 2026.10.14

- **Helm chart metadata.** Same-day CalVer patches use SemVer build metadata
  for the chart version while preserving the exact release in `appVersion`, so
  Helm can lint and install both example workloads.

## 2026.10.11

- **Behavior change.** the website and text-to-SQL images no longer
  carry the development certificate or its password. Each deployment
  generates a   Kubernetes Secret with a new password. Set
  `ASPNETCORE_Kestrel__Certificates__Default__Password` or keep it in
  `aspnetapp.pfx.password`, and remove earlier images.
- **Behavior change.** the text-to-SQL example no longer carries a
  database password. Setup generates a random one per run and publishes
  it as a Secret. Startup fails without a connection setting. Replace
  the old demo password.
- **Also in this release.** `testSets` is removed from
  `test/test.runner.yml`. The   text-to-SQL example gains column-level
  grants, bounded query handling, richer   LLM failure details, and
  recovery checks. Both examples share   `Example.Build.psm1`. Warm
  snapshots and SSH checks are hardened. Simplified   Chinese and Hebrew
  machine-translation drafts are added.

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

Last review: 2026.10.18.1

Back to [yuruna-project](README.md) - [Yuruna](https://yuruna.com)
