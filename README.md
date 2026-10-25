<a id="4255e584-0001"></a>

# yuruna-project

Project repository for [Yuruna](https://github.com/alissonsol/yuruna):
holds the user's resources, components, workloads, and test sequences,
kept separate from the framework so projects can be versioned and
shared independently.

<a id="4255e584-0002"></a>

## Layout

- [template/](template/) -- folder structure for starting a new project
  (resources / components / workloads / config).
- [example/](example/) -- end-to-end examples that exercise the
  framework against real clouds. See [Yuruna Examples ...](example/README.md).
  - [example/website/](example/website/) -- .NET C# website container
    deployed to Kubernetes on localhost, Azure, or AWS.
  - [example/text-to-sql/](example/text-to-sql/) -- **Early release.**
    Agentic read-only text-to-SQL on ASP.NET Core + PostgreSQL. Runs
    locally and deploys through the full Yuruna three-phase model;
    Claude activates when `ANTHROPIC_API_KEY` is set unless `USE_LOCAL_MODEL` selects Ollama.

<a id="4255e584-0003"></a>

## Read more

PowerShell analyzer settings use the framework's default rule set and report all
severities. Keep each repository's script metadata when synchronizing the rules.
PowerShell sources are ASCII without a byte-order mark: the analyzer's Unicode
BOM rule and the framework's BOM prohibition cannot both be satisfied by adding
a BOM. Write edited files with `[System.Text.UTF8Encoding]::new($false)`.

- Software declarations, inventory formats, and automatic maintenance: [Software bill of materials](docs/sbom/README.md).
- Languages and translated project fields: [Project display text](docs/globalization.md). Portuguese (Brazil): [translated documents](docs/pt-BR/index.md).
- Framework terminology: [Baseline, Configuration, Implementation, and Telemetry](https://yuruna.link/42fa6f45-0041). Project declarations describe Configuration; running behavior describes Implementation; collected results are Telemetry. Snapshot baselines keep their existing meaning.
- Framework [architecture](https://github.com/alissonsol/yuruna/blob/main/docs/architecture.md)
- Connectivity & setup: [Workarounds and FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/workarounds.md)
- Contributing: [CONTRIBUTING.md](https://github.com/alissonsol/yuruna/blob/main/CONTRIBUTING.md)
- Security: [SECURITY.md](https://github.com/alissonsol/yuruna/blob/main/SECURITY.md)

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.25

Back to [Yuruna](https://yuruna.com)
