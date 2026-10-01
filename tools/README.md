# Project tools

`example-workload.sh` owns the local registry preparation and image build/push
steps for the Ubuntu website and text-to-SQL workloads. Entrypoints source it
from the extracted project checkout, pass example/component names explicitly,
and keep deployment and readiness checks local. Preserve this file when serving
or copying project archives. Registry, pull, build, and push failures stop before
deployment. `Test-ExampleBuild.ps1` verifies the synchronized PowerShell build
modules; `Invoke-BoundedDocker -TimeoutSeconds` names its total time budget, with
`-StallSeconds` retained as a compatibility alias.

`test_navigation.cjs` checks the rendered website at `WEBSITE_URL` (default
`http://127.0.0.1:5187`) at mobile width. Restore LibMan assets before building.
`PLAYWRIGHT_MODULE` and `CHROME_PATH` select local browser tooling.

The text-to-SQL schema retriever caches a name index for each successfully loaded
catalog and preserves FK expansion order. Run the service contract executable
with `--schema-index` for the synthetic catalog check. Agent runs use `Complete`
to record their final result and duration.
