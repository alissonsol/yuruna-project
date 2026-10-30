<#PSScriptInfo
.VERSION 2026.10.30
.GUID 428c708f-f1f1-4046-96d1-c612d18dbac8
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
# The Dockerfile beside this script names the images and their upstream.
exit (Invoke-ExampleBaseImageSeed -DockerfilePath (Join-Path $PSScriptRoot 'Dockerfile'))
