# Yuruna Template Project

Folder scaffold for a new project. See
[architecture.md](https://github.com/alissonsol/yuruna/blob/main/docs/architecture.md) for
the three-phase model and CLI entry points, and the Connectivity
section of [Workarounds and FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/workarounds.md)
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
- **Workloads** — project workloads description. The shipped
  `config/localhost/workloads.yml` is a minimal scaffold (namespace +
  registry pull secret + a `TO-SET` placeholder). For a full localhost
  pipeline with TLS (mkcert), an nginx ingress, and a cert-manager
  issuer, copy and adapt
  [example/website](../example/website/config/localhost/workloads.yml).
- **Validation** — how to validate the system functionality.


---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.24

Back to [yuruna-project](../README.md) · [Yuruna](https://yuruna.com)
