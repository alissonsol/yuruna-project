# Yuruna Examples

**NOTE**: Because some examples share the same ingress component and
namespace, deploying one can supersede another. To restore the
previously working example, redeploy its ingress rules. See the
Connectivity section of the
[Workarounds and FAQ](https://github.com/alissonsol/yuruna/blob/main/docs/workarounds.md).

## Basic end-to-end test

- [website](website/README.md): A simple .NET C# website container deployed to a Kubernetes cluster.

## Early-stage examples

- [text-to-sql](text-to-sql/README.md) — **Early release.** Agentic
  read-only text-to-SQL on ASP.NET Core + PostgreSQL. Runs locally
  and deploys through the full Yuruna three-phase model
  (`Set-Resource` / `Set-Component` / `Set-Workload`); Claude
  activates when `ANTHROPIC_API_KEY` is set.

- [nested.host](nested.host/README.md) — Self-verification: the outer host
  builds a nested Ubuntu Server VM, installs the framework inside it, and runs
  one full cycle under nested virtualization. Not yet validated on a live lab.

## Template

- The [folder structure](../template/) for creating a new project: copy it
  to a new folder, then make needed changes and add component code
  (search for `TO-SET`).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.16

Back to [yuruna-project](../README.md) · [Yuruna](https://yuruna.com)
