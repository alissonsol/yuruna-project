<#PSScriptInfo
.VERSION 2026.06.30
.GUID 4235e9f4-2221-4d80-8930-3e3715979e46
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

Push-Location $PSScriptRoot

$env:basePath = $HOME
Write-Information "basePath: ${env:basePath}";

$env:pfxPath = ".aspnet/https/aspnetapp.pfx"
Write-Information "pfxPath: ${env:pfxPath}";

$env:pfxFile = Join-Path -Path ${env:basePath} -ChildPath ${env:pfxPath}
Write-Information "pfxFile: $env:pfxFile"

if (-Not (Test-Path -Path $env:pfxFile)) {
    Write-Error "Development certificate not found at '$env:pfxFile'. Generate it before building, e.g.: dotnet dev-certs https -ep $env:pfxFile -p { password here }"
    Pop-Location
    exit 1
}

Copy-Item -Path $env:pfxFile -Destination . -Force;

Pop-Location
