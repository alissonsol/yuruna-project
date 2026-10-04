<#PSScriptInfo
.VERSION 2026.10.04
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
$passwordVariable = 'ASPNETCORE_Kestrel__Certificates__Default__Password'
$passwordFromFile = $false
Push-Location -LiteralPath $PSScriptRoot -ErrorAction Stop
try {
    .\copy-pfx.ps1

    # --- REGION: Build application
    docker build --rm -f Dockerfile -t yrn42website-prefix/website:latest .
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed (exit code $LASTEXITCODE)." }

    # --- REGION: Run application
    # The image holds no certificate: the developer's certificate folder is mounted read-only.
    # Passing the password variable by name (-e with no value) takes it from this process's
    # environment, so it is never written in this file or shown on a command line. When the
    # variable is unset, the password file beside the PFX (aspnetapp.pfx.password, which the
    # guest provisioning scripts write) supplies it, for this run only.
    $certificateFolder = [IO.Path]::GetFullPath((Join-Path $HOME '.aspnet/https'))
    $passwordFile = Join-Path $certificateFolder 'aspnetapp.pfx.password'
    if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($passwordVariable)) -and (Test-Path -LiteralPath $passwordFile -PathType Leaf)) {
        $filePassword = [IO.File]::ReadAllText($passwordFile) -replace '[\r\n]+\z', ''
        if ($filePassword.Length -gt 0) {
            [Environment]::SetEnvironmentVariable($passwordVariable, $filePassword)
            $passwordFromFile = $true
        }
    }
    docker run --rm -it -p 8000:80 -p 8001:443 --name "yrn42website-prefix-example-website" -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 -e ASPNETCORE_Kestrel__Certificates__Default__Password -e ASPNETCORE_Kestrel__Certificates__Default__Path=/https/aspnetapp.pfx -v "${certificateFolder}:/https:ro" yrn42website-prefix/website:latest
    if ($LASTEXITCODE -ne 0) { throw "Docker run failed (exit code $LASTEXITCODE)." }
} finally {
    # A script run from an interactive shell shares its environment; do not leave the password behind.
    # Only a null string removes the variable: $null reaches .NET as an empty value on this runtime.
    if ($passwordFromFile) { [Environment]::SetEnvironmentVariable($passwordVariable, [NullString]::Value) }
    Pop-Location
}
