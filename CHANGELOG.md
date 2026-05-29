# Changelog

`yuruna-project` uses [Calendar Versioning](https://calver.org/):
`YYYY.MM.DD`. The framework lives at
[github.com/alissonsol/yuruna](https://github.com/alissonsol/yuruna);
this repo tracks user-facing project templates and end-to-end examples.

## 2026.05.29

First publicly tracked release.

- [template/](template/) — empty project scaffold (resources,
  components, workloads, config, test).
- [example/website/](example/website/) — .NET C# website container
  deployed to Kubernetes on localhost, Azure, and AWS, demonstrating
  resource + component + workload wiring and TLS via cert-manager.
- [example/text-to-sql/](example/text-to-sql/) — **Early release.**
  Agentic read-only text-to-SQL on ASP.NET Core + PostgreSQL. Runs
  locally; full three-phase Yuruna deployment is not yet wired up.
- **License**: [LICENSE.md](LICENSE.md) is now titled "Yuruna License"
  (based on the MIT License) and adds a plain-language "No Warranty /
  'As Is'" restatement plus an explicit "Administrator Risk Warning"
  section covering scripts that require elevated/root privileges.

Back to [yuruna-project](README.md) · [Yuruna](https://yuruna.com)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
