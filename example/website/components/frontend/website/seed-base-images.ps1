<#PSScriptInfo
.VERSION 2026.09.30
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

Import-Module (Join-Path $PSScriptRoot 'Example.Build.psm1') -Force
exit (Invoke-ExampleBaseImageSeed)
