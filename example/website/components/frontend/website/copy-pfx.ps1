<#PSScriptInfo
.VERSION 2026.10.04
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

# Despite the name, nothing is copied: the certificate stays in the developer's
# profile and is read at deployment and run time, never placed in the build
# context. This step only fails early when the certificate cannot be used. The
# file name is part of the contract the framework's tests check.
Import-Module (Join-Path $PSScriptRoot 'Example.Build.psm1') -Force
Assert-ExampleDevelopmentCertificate
