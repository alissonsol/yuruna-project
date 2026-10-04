<a id="4225cd3d-0001"></a>

# Software bill of materials

The three inventories describe software declared by this repository: project
applications and their dependencies, host software, and guest software. The
shared formats and maintenance rules are documented at
[Yuruna SBOM maintenance](https://yuruna.link/427fb0be-0001).

| Scope | SPDX 2.2.1 JSON | CycloneDX 1.7 JSON | SWID 2015 XML |
|---|---|---|---|
| Repository | [repository.spdx.json](repository.spdx.json) | [repository.cdx.json](repository.cdx.json) | [repository.swidtag](repository.swidtag) |
| Hosts | [hosts.spdx.json](hosts.spdx.json) | [hosts.cdx.json](hosts.cdx.json) | [hosts.swidtag](hosts.swidtag) |
| Guests | [guests.spdx.json](guests.spdx.json) | [guests.cdx.json](guests.cdx.json) | [guests.swidtag](guests.swidtag) |

SPDX is the ISO/IEC 5962:2021 exchange format. CycloneDX follows ECMA-424,
second edition. SWID tags identify software using the 2015 XML vocabulary.
These are three representations of each source inventory.

<a id="4225cd3d-0002"></a>

## What the inventory establishes

The repository inventory reads the existing .NET project manifests, LibMan
browser-library declarations, and Dockerfile base images. Host and guest
inventories read the software declarations in setup and deployment scripts.
They describe what those scripts install or reference; they do not verify the
installed state of a running machine.

Collection runs locally without network access, package restoration, container
inspection, or new lockfile generation. This project has no tracked NuGet
restore locks, so its transitive NuGet packages remain unresolved. Restored
LibMan files and container operating-system packages are not present in the
source inventory. Floating image tags, version ranges, and expressions remain
constraints rather than asserted resolved versions. Evidence paths, line
numbers, checksums already recorded by source files, and completeness notes
explain each entry.

<a id="4225cd3d-0003"></a>

## Update and compare

Use Python 3.11 or newer and Git from this repository's root:

```sh
python tools/Sync-Sbom.py --update
python tools/Sync-Sbom.py --check
```

Use `python3` when that is the local Python command. An update writes changed
inventory files and copies each replaced file to the same path with `.previous`
appended. Initial generation has no previous file. Subsequent updates retain the
immediately preceding version for comparison; unchanged output is not rewritten.

```sh
git diff --no-index docs/sbom/repository.spdx.json.previous docs/sbom/repository.spdx.json
```

<a id="4225cd3d-0004"></a>

## Before a commit

The tracked pre-commit hook regenerates the inventories from staged source files
and stages changed outputs and their `.previous` copies. Its inputs therefore
describe the changes being committed. This maintenance runs locally and uses no
package download or dependency resolution service.

Enable the tracked hook in a local clone with:

```sh
git config core.hooksPath tools/githooks
```

The generator can perform the same operation explicitly:

```sh
python tools/Sync-Sbom.py --update --staged --stage
```

The project hook also keeps its existing translation maintenance. Hook activation
is local Git configuration and is not propagated by cloning the repository.

Back to [yuruna-project](../../README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.03
