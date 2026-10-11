<#PSScriptInfo
.VERSION 2026.10.11
.GUID 4297a7c9-571b-4419-a5a5-398c374fe6eb
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

# --- REGION: Import build helpers
Import-Module (Join-Path $PSScriptRoot 'Example.Build.psm1') -Force
# --- REGION: Seed base images
exit (Invoke-ExampleBaseImageSeed)
