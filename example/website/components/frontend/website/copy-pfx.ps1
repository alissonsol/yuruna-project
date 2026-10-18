<#PSScriptInfo
.VERSION 2026.10.18.1
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

# Validate the certificate without placing it in the build context.
# See https://yuruna.link/42f64340-0004
# --- REGION: Import build helpers
Import-Module (Join-Path $PSScriptRoot 'Example.Build.psm1') -Force
# --- REGION: Validate development certificate
Assert-ExampleDevelopmentCertificate
