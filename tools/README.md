# Project tools

`Sync-Sbom.py` maintains the repository, host, and guest software inventories.
See [SBOM maintenance](../docs/sbom/README.md) for the formats, comparison files,
and local pre-commit setup. It uses existing declarations and locks without
restoring dependencies.

`example-workload.sh` owns local registry preparation and bounded cache cleanup
for the Ubuntu website and text-to-SQL workloads. Both examples use Set-Component
as their sole build/push pipeline; the shared build/push helper remains available
for entrypoints that do not call Set-Component. Entrypoints source it
from the extracted project checkout, pass example/component names explicitly,
and keep deployment and readiness checks local. Preserve this file when serving
or copying project archives. Registry, pull, build, and push failures stop before
deployment, through `example_fail <class> <message>`: it prints one
`YURUNA_RESULT` line naming a canonical failure class, which the runner's ssh
verbs read in place of a generic script error, and exits 1. Each workload exports `YURUNA_EXAMPLE_SELF_SIGNED_CERT=1` before publishing, so the
deployment gives the pod a throwaway certificate: a run then needs neither the
guest's development certificate nor the password file beside it, and the image
carries none. The local registry publishes port 5000 on `127.0.0.1` only: the
deployment client and the node that pulls from it share the guest, and a port
open to the LAN would take pushes from any machine there. A registry container
an earlier run published on every address is created again.
`Test-ExampleBuild.ps1` verifies the synchronized PowerShell build modules, the
certificate Secret (generated password, no password in any output or argument, the
wrapper's exit codes, and redaction when kubectl echoes the submitted Secret), the rendered charts, and that no example ships key material
or a literal certificate password; `Invoke-BoundedDocker -TimeoutSeconds` names its
native execution and capture budget, with `-StallSeconds` retained as a compatibility alias.
The wrapper passes each Docker argument literally, captures both output streams
concurrently, and reserves time inside that budget for process-tree termination.
An incomplete output drain fails the operation instead of accepting a partial result.
The checks restore their fixture environment before returning to the calling shell.
Both seeding paths read the base images from the component's Dockerfile, its
`FROM ${REGISTRY}<image>` lines, and their upstream from its
`ARG REGISTRY=<upstream>/` default, so the Dockerfile is the only place the
base-image identity is written; a Dockerfile without them stops the seeding.
PowerShell base-image seeding and the Bash registry helper resolve the cache from
`http_proxy`, then `/etc/yuruna/host.env`, then a ten-second probe of
`yuruna-caching-proxy-service:5000`. Seeding discovers it once per run, only when
a base image is absent from both the registry and the local Docker store. A failed
cache pull retains the bounded MCR fallback. The build tests cover this precedence,
the direct-lab case, and cache-first pull ordering without a network connection.

`test_navigation.cjs` checks the rendered website at `WEBSITE_URL` (default
`http://127.0.0.1:5187`) at mobile width. Restore LibMan assets before building.
It resolves `playwright-core` through Node's normal module search and uses
Playwright's Chromium by default. `PLAYWRIGHT_MODULE` and `CHROME_PATH` select
an existing module and browser installation. Run `node tools/test_navigation.test.cjs`
for isolated dependency, override, and failure checks without starting a browser.
The check follows the toggle's `aria-controls` target and requires that panel to
be visibly expanded and collapsed along with its ARIA state.

The text-to-SQL schema retriever caches a name index for each successfully loaded
catalog and preserves FK expansion order. Run the service contract executable
with `--schema-index` for the synthetic catalog check. Agent runs use `Complete`
to record their final result and duration.

Run `python3 tools/test_example_consistency.py` to compare shared deployment
phases, build wrappers, local resource declarations, and Ubuntu release sequences.
The two localhost workload configurations must run the same deployment steps,
except the database Secret step only text-to-SQL declares, and share their
infrastructure variables. The ingress controller chart is installed from a
downloaded release file only after that file matches the SHA-256 its chart
repository's index publishes (`ingressChartVersion`, `ingressChartSha256`); the
chart pins its controller image by digest.
The guest-user fixture also checks sudo selection, literal home paths, and failed
account lookups without running a deployment. On Windows the source parity
checks run while the POSIX command fixture is skipped. Shared behavior belongs
in the same named regions; identity metadata and release-specific configuration
remain local. See [source consistency](https://yuruna.link/42e220c4-0009).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.30

Back to [yuruna-project](../README.md) - [Yuruna](https://yuruna.com)
