<a id="42f64340-0001"></a>

# frontend/website

Frontend website for user authentication and human-computer interface.

<a id="42f64340-0002"></a>

## Client-side libraries (libman)

`wwwroot/lib/*` is gitignored; the client-side libraries declared in
`libman.json` are restored at build time. Docker handles this
automatically (`Dockerfile` installs
`Microsoft.Web.LibraryManager.Cli` and runs `libman restore` before
`dotnet build`). For a local `dotnet run` outside Docker, restore
once with:

```powershell
dotnet tool install -g Microsoft.Web.LibraryManager.Cli
libman restore
```

<a id="42f64340-0003"></a>

## Development certificate

The container image holds no certificate and no password. Kestrel reads the PFX
from a file the platform mounts and its password from an environment variable,
so neither this repository, an image layer, nor a manifest contains a key or a
password.

The example finds the password of your PFX in one of two places, in this order:

1. The `ASPNETCORE_Kestrel__Certificates__Default__Password` environment variable,
   when it is not empty.
2. The password file beside the PFX, `~/.aspnet/https/aspnetapp.pfx.password`, when
   the variable is unset: one line of plain text (a trailing newline is ignored). An
   empty file counts as absent.

With neither, the PFX is opened without a password, which works only for a file
exported without one. The variable wins whenever it is not empty, even when the file holds a
different password.

The Ubuntu and Windows guests need neither: their `k8s` provisioning scripts export
`aspnetapp.pfx` under a random password (32 bytes from the operating-system generator,
as 64 hexadecimal characters) and keep it in `aspnetapp.pfx.password`, created readable
by its owner only (mode `600` on Ubuntu, an ACL limited to the current user on Windows).
The password never appears on a command line or in the script output. No fixed
password remains anywhere: a PFX with no password file (for example, one exported under a
fixed password) must be replaced, so run the `k8s` workload again.

On your own machine, create the certificate once with a password you choose:

```powershell
dotnet dev-certs https --check --trust              # check
mkdir $HOME/.aspnet/https
$env:ASPNETCORE_Kestrel__Certificates__Default__Password = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
dotnet dev-certs https -ep $HOME/.aspnet/https/aspnetapp.pfx -p $env:ASPNETCORE_Kestrel__Certificates__Default__Password
dotnet dev-certs https --trust
```

If "A valid HTTPS certificate is already present" -> `dotnet dev-certs https --clean` and retry.

Then keep that password in the variable in every shell that builds, deploys, or runs the
example, or save it once in the password file and leave the variable unset:

```powershell
Set-Content -LiteralPath $HOME/.aspnet/https/aspnetapp.pfx.password -Value $env:ASPNETCORE_Kestrel__Certificates__Default__Password
```

`dotnet dev-certs` writes the private key only when `-p` is given; without it the
file is a bare public certificate that cannot serve HTTPS. A PFX from another tool
works too, including one with an empty password (leave the variable and password file empty or absent).

<a id="42f64340-0004"></a>

### Where the certificate goes

| Run | Certificate | Password |
| --- | --- | --- |
| `docker-run-dev.ps1`, `docker-run-dev.cmd` | `~/.aspnet/https` mounted read-only at `/https` | the variable above, passed to Docker by name; taken from `aspnetapp.pfx.password` when the variable is unset |
| Cluster, `Set-Workload.ps1` | Kubernetes Secret `website-pod-cert`, mounted at `/https` | random per deployment, read through `secretKeyRef` |
| Automation with no developer certificate (`YURUNA_EXAMPLE_SELF_SIGNED_CERT=1`) | the same Secret, holding a throwaway self-signed certificate | the same |

For a cluster, every `config/<cloud>/workloads.yml` runs
[create-cert-secret.ps1](create-cert-secret.ps1) immediately before it installs the
chart. The chart cannot install first: `helm upgrade --install --atomic` waits for
the pod, and the pod cannot start without its Secret. The script opens your PFX with
the password in the environment or, when that is unset, in the password file beside it
(or issues the throwaway certificate), generates a
password of 256 random bits, exports the certificate under that password, and sends
the Secret to `kubectl create`.

The design keeps the password out of everything that persists or is logged:

- It is generated inside the script, in memory. It is not a workloads variable (the
  deployment engine copies variables into `values.yaml`, the environment, and debug
  logs), not a command-line argument (the engine echoes a failed command, and a process
  list shows arguments), and not a file.
- The manifest reaches `kubectl` on standard input. `create` is used rather than
  `apply` so the data is not copied into a `last-applied-configuration` annotation.
- Each deployment deletes and re-creates its namespace, so the Secret and its password
  last exactly one deployment. Your own password is only used to open your file; the
  cluster never receives it.
- The pod mounts only `aspnetapp.pfx`, readable by its owner and group (mode `0440`), and
  receives the password as an environment variable. The image's single process runs as
  root and reads the file either way; `fsGroup: 1654`, the ID the .NET base images give
  their non-root user and group, lets that user read it too if the image ever drops root.
- `.dockerignore` excludes `*.pfx`, `*.p12`, `*.pem`, and `*.key`, so a stray key in the
  working tree cannot reach any build stage.

Despite its name, `copy-pfx.ps1` copies nothing (the framework's tests check the file name);
it only fails early when the certificate cannot be used. Automation sets
`YURUNA_EXAMPLE_SELF_SIGNED_CERT=1` when no developer certificate exists or its password
is not known, as the Ubuntu guest workloads do; the throwaway certificate lives 30 days.

<a id="42f64340-0005"></a>

### Checking an image and a deployment

The image must hold no key and no password. After `Set-Component.ps1 website localhost`
(or the workload script), with `IMAGE=localhost:5000/website/website:latest`:

```bash
# No layer instruction names key material: expect no output.
docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE" | grep -i -E 'pfx|p12|\.pem|\.key'
# The application folder: expect no .pfx, .p12, .pem, or .key file.
docker run --rm --entrypoint ls "$IMAGE" -la /app
# Nothing key-shaped anywhere outside the CA bundle: expect no output.
docker run --rm --entrypoint sh "$IMAGE" -c "find / -xdev -type f \( -name '*.pfx' -o -name '*.p12' -o -name '*.key' -o -name '*.pem' \) -not -path '/etc/ssl/*' -not -path '/usr/share/ca-certificates/*' 2>/dev/null"
# No password variable is baked in: expect no ASPNETCORE_Kestrel entry.
docker image inspect --format '{{json .Config.Env}}' "$IMAGE"
```

HTTPS must still be served from the Secret (use `-n text-to-sql` for the other example):

```bash
kubectl wait --for=condition=available deployment/website -n website --timeout=240s
kubectl get secret website-pod-cert -n website -o jsonpath='{.data}'     # keys: aspnetapp.pfx, password
kubectl get deployment website -n website -o jsonpath='{.spec.template.spec.containers[0].env}'   # secretKeyRef, no literal value
kubectl exec -n website deploy/website -- ls -lL /https                  # only aspnetapp.pfx, mode -r--r-----
kubectl port-forward -n website svc/website 8443:443 &
curl -ksS -o /dev/null -w '%{http_code}\n' https://localhost:8443/       # 200
echo | openssl s_client -connect localhost:8443 2>/dev/null | openssl x509 -noout -subject -dates
curl -ksS -o /dev/null -w '%{http_code}\n' http://localhost/             # 200 through the ingress, as test-localhost.sh checks
```

The availability wait is the strongest check: the readiness probe is an HTTPS request to port 443,
so it passes only when Kestrel loaded the PFX with the Secret's password.

<a id="42f64340-0006"></a>

## Regenerating and modifying the website project

- Project created via [Tutorial: Get started with ASP.NET Core](https://learn.microsoft.com/en-us/aspnet/core/getting-started/?view=aspnetcore-10.0):
  - In `components/frontend`: `dotnet new webapp -o website`
  - Add `**/wwwroot/lib/*` to `.gitignore`.
- Containerize per [Running pre-built container images with HTTPS](https://learn.microsoft.com/en-us/aspnet/core/security/docker-https?view=aspnetcore-10.0):
  - If `Microsoft.VisualStudio.Azure.Containers.Tools.Targets` is missing: `dotnet add package Microsoft.VisualStudio.Azure.Containers.Tools.Targets --version 1.23.0`.
  - Right-click the project -> `Add -> Docker Support...` (needs [Visual Studio](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/docker/visual-studio-tools-for-docker?view=aspnetcore-10.0)).
- Test with `IIS Express`, then the `Docker` version:
  - "Volume sharing is not enabled" -> Docker Desktop -> Settings -> Resources -> File Sharing -> add `C:\` -> Apply & Restart.
  - Both the Linux build and the Visual Studio debugger use `Dockerfile`.

<a id="42f64340-0007"></a>

## Running the docker image locally

<a id="42f64340-0008"></a>

### Docker

- Start the Docker build via VS debugger -- runs as `website:dev` named `website`. Stopping the debugger may leave it running; clean up.
- Or use [docker-run-dev.ps1](docker-run-dev.ps1): builds `yrn42website-prefix/website:latest`, runs as `yrn42website-prefix-example-website`, and mounts `~/.aspnet/https` read-only. It stops before building when the certificate cannot be opened with the password in `ASPNETCORE_Kestrel__Certificates__Default__Password` or, when that is unset, in `~/.aspnet/https/aspnetapp.pfx.password`; either script reads that file into its own environment for the run when the variable is unset, so Docker still receives the password by name and nothing is echoed. [docker-run-dev.cmd](docker-run-dev.cmd) does the same without the early check. Open `http://localhost:8000/` or `https://localhost:8001/`.
- Or build via `Set-Component.ps1 website localhost` then run interactively (the password variable is passed by name, so its value is not typed here):
  ```
  docker run --rm -it -p 8000:80 -p 8001:443 --name "test-website" \
    -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 \
    -e ASPNETCORE_Kestrel__Certificates__Default__Password \
    -e ASPNETCORE_Kestrel__Certificates__Default__Path=/https/aspnetapp.pfx \
    -v "$HOME/.aspnet/https:/https:ro" \
    localhost:5000/website/website:latest
  ```

<a id="42f64340-0009"></a>

### Kubernetes (docker-desktop cluster)

```bash
# After Set-Component.ps1 website localhost
pwsh ./create-cert-secret.ps1 -Namespace default -SecretName website-pod-cert
kubectl apply -f website-pod.yaml
kubectl apply -f website-service.yaml
kubectl port-forward services/website-service 8000:80 8001:443 -n default
# Open http://localhost:8000/
kubectl delete svc website-service
kubectl delete pod website-pod
kubectl delete secret website-pod-cert
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.04

Back to [Website example](../../../README.md) - [yuruna-project](../../../../../README.md) - [Yuruna](https://yuruna.com)
