# Changelog

`yuruna-project` uses [Calendar Versioning](https://calver.org/):
`YYYY.MM.DD`. The framework lives at
[github.com/alissonsol/yuruna](https://github.com/alissonsol/yuruna);
this repo tracks user-facing project templates and end-to-end examples.

## 2026.09.30

- **Schema change**: `testSets` is removed from `test/test.runner.yml`; the
  pool-control Pools page assigns a Framework URL and Project URL together,
  and the project repository supplies its own sequence list.
- The text-to-SQL example adds column-level grants, bounded query and result
  handling through `SqlQueryPolicy` and `SqlResultReader`, and database recovery
  checks.
- Both examples use the shared `Example.Build.psm1` module. The AWS website
  workload uses NodePort ingress.
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

Last review: 2026.09.30

Back to [yuruna-project](README.md) - [Yuruna](https://yuruna.com)
