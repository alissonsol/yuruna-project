# Yuruna Examples

**NOTE**: Because some examples share the same ingress component and
namespace, deploying one can supersede another. To restore the
previously working example, redeploy its ingress rules. See the
Connectivity section of the
[Frequently Asked Questions](https://github.com/alissonsol/yuruna/blob/main/docs/faq.md).

## Basic end-to-end test

- [website](website/README.md): A simple .NET C# website container deployed to a Kubernetes cluster.

## Early-stage examples

- [text-to-sql](text-to-sql/README.md) — **Early release.** Agentic
  read-only text-to-SQL on ASP.NET Core + PostgreSQL. Runs locally
  against PostgreSQL today; full Yuruna three-phase deployment is not
  yet wired up.

## Template

- This is just the [folder structure](../template/) to create a new project.
  - Copy and paste folder structure to new folder.
  - Make needed changes and add component code (search for `TO-SET`).

Back to [Yuruna](https://yuruna.com)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
