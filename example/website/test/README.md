# Website test cycles

The website example ships full-install and warm-baseline top-level sequences
for both Ubuntu releases. The default `sequences` list in
`test/test.runner.yml` continues to exercise the full Ubuntu 26 installation
and Windows guest.

| Top-level sequence | Ubuntu | Behavior |
|---|---|---|
| `workload.guest.ubuntu.server.26.k8s.website` | 26 | Full installation; console workload |
| `workload.guest.ubuntu.server.24.k8s.website` | 24 | Full installation; console workload |
| `workload.guest.ubuntu.server.26.k8s.website.ssh` | 26 | Full installation; SSH workload |
| `workload.guest.ubuntu.server.24.k8s.website.ssh` | 24 | Full installation; SSH workload |
| `website.ubuntu26.warm` | 26 | Restore or build Kubernetes, then deploy and test |
| `website.ubuntu24.warm` | 24 | Restore or build Kubernetes, then deploy and test |

To run a lane continuously, list its sequence under `sequences:` in the
`test/test.runner.yml` of the project the host runs. A pool whose hosts need a
different list sets the Framework URL and Project URL on the pool-control
Pools page to the repository pair it runs; the Project URL selects the
repository that carries its own `test/test.runner.yml`. For a warm cycle, list
only `website.ubuntu26.warm` or `website.ubuntu24.warm`. Do not mix an
orchestration entry and direct guest entries in one cycle.

The warm lanes use orchestration to reach the snapshot-aware chain planner.
The first run installs Ubuntu and Kubernetes, verifies the node, and saves a
disk-only baseline. Later runs restore that baseline before deploying the
website. The VM and DHCP identity persist; each workload starts from the saved
disk state. Baseline account names are separate from full-install accounts so
their password records do not overwrite one another.

The producer and consumer share `snapshotPolicy`: expire after 24 hours and
rebuild when checkout revisions, declared source hashes or guest identity
change. The source list includes image-builder definitions, cloud-init seeds,
guest installers, start sequences and the baseline sequence. This records
version inputs, rather than claiming a digest of the ISO actually installed.
A manifest whose ownership cannot be verified stops the run; it never triggers
automatic deletion of an unrecognized VM.

Each restore waits for SSH, refreshes the user's Kubernetes client configuration
from the restored administrator configuration, and checks the node and
certificate expiration. Fresh account credentials and cluster certificates
are created by the cold rebuild, at least daily when this lane is in use.
The warm lane does not test the expired-password installation path. Keep the
full-install lanes in the lab's rotation; adding the warm lanes changes no
cadence and no active host configuration.

The GUI workloads use the shared `shellInputPrime` snippet after login. Its
disposable echo and fresh OCR match settle console input before submitting an
installation command. See [the console-delivery explanation](https://yuruna.link/42dc5bb9-0008)
and [the snapshot contract](https://yuruna.link/428e4df6).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.30

Back to [Website example](../README.md) - [yuruna-project](../../../README.md) - [Yuruna](https://yuruna.com)
