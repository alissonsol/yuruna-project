# frontend/website

Frontend website for user authentication and human-computer interface.

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

## Development certificates

```powershell
dotnet dev-certs https --check --trust              # check
mkdir $HOME/.aspnet/https
dotnet dev-certs https -ep $HOME/.aspnet/https/aspnetapp.pfx -p { password here }
dotnet dev-certs https --trust
```

If "A valid HTTPS certificate is already present" → `dotnet dev-certs https --clean` and retry.

## Regenerating and modifying the website project

- Project created via [Tutorial: Get started with ASP.NET Core](https://learn.microsoft.com/en-us/aspnet/core/getting-started/?view=aspnetcore-10.0):
  - In `components/frontend`: `dotnet new webapp -o website`
  - Add `**/wwwroot/lib/*` to `.gitignore`.
- Containerize per [Running pre-built container images with HTTPS](https://learn.microsoft.com/en-us/aspnet/core/security/docker-https?view=aspnetcore-10.0):
  - If `Microsoft.VisualStudio.Azure.Containers.Tools.Targets` is missing: `dotnet add package Microsoft.VisualStudio.Azure.Containers.Tools.Targets --version 1.21.2`.
  - Right-click the project → `Add → Docker Support…` (needs [Visual Studio](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/docker/visual-studio-tools-for-docker?view=aspnetcore-10.0)).
- Test with `IIS Express`, then the `Docker` version:
  - "Volume sharing is not enabled" → Docker Desktop → Settings → Resources → File Sharing → add `C:\` → Apply & Restart.
  - The Linux build expects lowercase `dockerfile`; the VS debugger expects `Dockerfile`. Keep `Dockerfile` (uppercase) and use the debugger.

## Running the docker image locally

### Docker

- Start the Docker build via VS debugger — runs as `website:dev` named `website`. Stopping the debugger may leave it running; clean up.
- Or use `frontend/website/docker-run-dev.ps1`: builds `yrn42website-prefix/website:latest`, runs as `yrn42website-prefix-example-website`. Confirm the password matches the dev cert. Open `http://localhost:8000/`.
- Or build via `Set-Component.ps1 website localhost` then run interactively:
  ```
  docker run --rm -it -p 8000:80 -p 8001:443 --name "test-website" \
    -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 \
    -e ASPNETCORE_Kestrel__Certificates__Default__Password="password" \
    -e ASPNETCORE_Kestrel__Certificates__Default__Path=/app/aspnetapp.pfx \
    localhost:5000/website/website:latest
  ```

### Kubernetes (docker-desktop cluster)

```bash
# After Set-Component.ps1 website localhost
kubectl apply -f website-pod.yaml
kubectl apply -f website-service.yaml
kubectl port-forward services/website-service 8000:80 8001:443 -n default
# Open http://localhost:8000/
kubectl delete svc website-service
kubectl delete pod website-pod
```

Back to [Website example](../../../README.md) · [Yuruna](https://github.com/alissonsol/yuruna)

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.14

Back to [yuruna-project](../../../../../README.md) · [Yuruna](https://yuruna.com)
