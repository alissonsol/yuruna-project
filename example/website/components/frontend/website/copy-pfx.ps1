<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42ad409a-370e-45f4-980b-e629de1fa2b0
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

# --- REGION: Locate the development certificate
$pfxFile = Join-Path -Path $HOME -ChildPath '.aspnet/https/aspnetapp.pfx'
Write-Information "pfxFile: $pfxFile"

# --- REGION: Validate the development certificate
# See https://yuruna.link/42e220c4-0009
if (-not (Test-Path -LiteralPath $pfxFile -PathType Leaf)) {
    throw "Development certificate not found at '$pfxFile'. Generate it before building: dotnet dev-certs https -ep '$pfxFile' -p { password here }"
}

# --- REGION: Copy the development certificate
Copy-Item -LiteralPath $pfxFile -Destination $PSScriptRoot -Force -ErrorAction Stop
