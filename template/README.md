# Yuruna Template Project

Folder scaffold for a new project. See
[architecture.md](https://github.com/alissonsol/yuruna/blob/main/docs/architecture.md) for
the three-phase model and CLI entry points, and the Connectivity
section of [FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/faq.md)
before deploying.

## Deploy

Search for `TO-SET` in `config/<cloud>/*.yml` and fill required values,
then from the framework's `automation/` folder (in your local clone of
[yuruna](https://github.com/alissonsol/yuruna), not this project repo
— the deploy scripts ship with the framework):

```shell
Set-Resource.ps1  TO-SET localhost
Set-Component.ps1 TO-SET localhost
Set-Workload.ps1  TO-SET localhost
```

## Fill in

- **Resources** — project resources description and OpenTofu outputs.
- **Components** — project components description.
- **Workloads** — project workloads description.
- **Validation** — how to validate the system functionality.

Back to [Yuruna](https://yuruna.com).

---

Copyright (c) 2019-2026 by Alisson Sol et al.
