# Project tools

`Sync-Sbom.py` maintains the repository, host, and guest software inventories.
See [SBOM maintenance](../docs/sbom/README.md) for the formats, comparison files,
and local pre-commit setup. It uses existing declarations and locks without
restoring dependencies.

`example-workload.sh` owns the local registry preparation and image build/push
steps for the Ubuntu website and text-to-SQL workloads. Entrypoints source it
from the extracted project checkout, pass example/component names explicitly,
and keep deployment and readiness checks local. Preserve this file when serving
or copying project archives. Registry, pull, build, and push failures stop before
deployment. It also exports `YURUNA_EXAMPLE_SELF_SIGNED_CERT=1`, so the
deployment gives the pod a throwaway certificate: a run then needs neither the
guest's development certificate nor the password file beside it, and the image
carries none.
`Test-ExampleBuild.ps1` verifies the synchronized PowerShell build modules, the
certificate Secret (generated password, no password in any output or argument, the
wrapper's exit codes), the rendered charts, and that no example ships key material
or a literal certificate password; `Invoke-BoundedDocker -TimeoutSeconds` names its
total time budget, with `-StallSeconds` retained as a compatibility alias.

`test_navigation.cjs` checks the rendered website at `WEBSITE_URL` (default
`http://127.0.0.1:5187`) at mobile width. Restore LibMan assets before building.
`PLAYWRIGHT_MODULE` and `CHROME_PATH` select local browser tooling.

The text-to-SQL schema retriever caches a name index for each successfully loaded
catalog and preserves FK expansion order. Run the service contract executable
with `--schema-index` for the synthetic catalog check. Agent runs use `Complete`
to record their final result and duration.
