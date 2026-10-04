<#PSScriptInfo
.VERSION 2026.09.30
.GUID 429aa0aa-bf8e-4bcf-9ec1-0f829370c031
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
Import-Module (Join-Path $PSScriptRoot 'Example.Build.psm1') -Force
exit (Invoke-ExampleCertificateSecret -Namespace $Namespace -SecretName $SecretName)
