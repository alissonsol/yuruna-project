<#PSScriptInfo
.VERSION 2026.09.30
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

Import-Module (Join-Path $PSScriptRoot 'Example.Build.psm1') -Force
Copy-ExampleDevelopmentCertificate -Destination $PSScriptRoot
