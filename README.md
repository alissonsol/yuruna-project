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
    Agentic read-only text-to-SQL on ASP.NET Core + PostgreSQL
    (runs locally; full Yuruna deployment pending).

## Read more

- Framework [architecture](https://github.com/alissonsol/yuruna/blob/main/docs/architecture.md)
- Connectivity & setup: [FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/faq.md)
- Contributing: [contributing.md](https://github.com/alissonsol/yuruna/blob/main/CONTRIBUTING.md)

Back to [Yuruna](https://github.com/alissonsol/yuruna)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
