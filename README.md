# yuruna-project

Project repository for [Yuruna](https://github.com/alissonsol/yuruna):
holds the user's resources, components, workloads, and test sequences,
kept separate from the framework so projects can be versioned and
shared independently.

## Layout

- [template/](template/) — folder structure for starting a new project
  (resources / components / workloads / config / test).
- [example/](example/) — end-to-end examples that exercise the
  framework against real clouds. See [Yuruna Examples ...](example/README.md).
  - [example/website/](example/website/) — .NET C# website container
    deployed to Kubernetes on localhost, Azure, or AWS.
  - [example/text-to-sql/](example/text-to-sql/) — **Early release.**
    Agentic read-only text-to-SQL on ASP.NET Core + PostgreSQL. Runs
    locally and deploys through the full Yuruna three-phase model
    (resources / components / workloads); Claude activates when
    `ANTHROPIC_API_KEY` is set.

## Read more

- Framework [architecture](https://github.com/alissonsol/yuruna/blob/main/docs/architecture.md)
- Connectivity & setup: [FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/faq.md)
- Contributing: [contributing.md](https://github.com/alissonsol/yuruna/blob/main/CONTRIBUTING.md)
- Security: [SECURITY.md](https://github.com/alissonsol/yuruna/blob/main/SECURITY.md)

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [yuruna-project](README.md) · [Yuruna](https://yuruna.com)
