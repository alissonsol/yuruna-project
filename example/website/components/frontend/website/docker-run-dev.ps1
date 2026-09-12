<#PSScriptInfo
.VERSION 2026.09.12
.GUID 420cfa6c-c9a1-4a18-bf13-87d3c8b7bd4a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# --- REGION: Prepare build
Push-Location -LiteralPath $PSScriptRoot -ErrorAction Stop
try {
    .\copy-pfx.ps1

    # --- REGION: Build application
    docker build --rm -f Dockerfile -t yrn42website-prefix/website:latest .
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed (exit code $LASTEXITCODE)." }

    # --- REGION: Run application
    docker run --rm -it -p 8000:80 -p 8001:443 --name "yrn42website-prefix-example-website" -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 -e ASPNETCORE_Kestrel__Certificates__Default__Password="password" -e ASPNETCORE_Kestrel__Certificates__Default__Path=/app/aspnetapp.pfx yrn42website-prefix/website:latest
    if ($LASTEXITCODE -ne 0) { throw "Docker run failed (exit code $LASTEXITCODE)." }
} finally {
    Pop-Location
}
