<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42c47ff4-1be9-488e-913e-cc133c03fda5
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
