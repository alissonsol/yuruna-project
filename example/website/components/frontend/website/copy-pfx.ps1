<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42bb2c3d-4e5f-4067-b890-1c2d3e4f5168
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

Copy-Item -Path $env:pfxFile -Destination . -Force;

Pop-Location
