<#PSScriptInfo
.VERSION 2026.10.22
.GUID 420a63bf-c586-48b0-899b-a8f6e6067042
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

# Run by the workloads configuration immediately before the chart is installed.
# The script form (rather than a module call in the configuration) lets a failure
# reach the deployment engine as an exit code.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$SecretName
)
# --- REGION: Import build helpers
Import-Module (Join-Path $PSScriptRoot 'Example.Build.psm1') -Force
# --- REGION: Create certificate Secret
exit (Invoke-ExampleCertificateSecret -Namespace $Namespace -SecretName $SecretName)
