<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4225b001-c90f-4210-ba9a-b5d1da7ee415
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'The isolated module-scope HTTP stub prevents these helper tests from touching a real registry.')]
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Sync-ExampleBuildModule.ps1') -Check
$module = Import-Module (Join-Path $PSScriptRoot 'Example.Build.psm1') -Force -PassThru

& $module {
    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:AlreadyServed = $false
    $script:LocalImage = 'mcr.microsoft.com/dotnet/sdk:10.0'
    $script:PushExit = 0
    $script:LASTEXITCODE = 0
    function Invoke-WebRequest {
        if (-not $script:AlreadyServed) { throw 'fixture cache miss' }
    }
    function docker {
        $script:Calls.Add(($args -join ' '))
        $script:LASTEXITCODE = 0
        if ($args[0] -eq 'image') { $script:LocalImage }
    }
    function Invoke-BoundedDocker {
        param([int]$TimeoutSeconds, [string[]]$DockerArgs)
        if ($TimeoutSeconds -ne 300) { throw 'Seed command lost its deadline' }
        $script:Calls.Add(($DockerArgs -join ' '))
        if ($DockerArgs[0] -eq 'push') { return $script:PushExit }
        return 0
    }
    $script:AlreadyServed = $true
    if ((Invoke-ExampleBaseImageSeed -BaseImage 'dotnet/sdk:10.0') -ne 0 -or $script:Calls.Count -ne 0) {
        throw 'A served manifest must skip Docker work'
    }
    $script:AlreadyServed = $false
    if ((Invoke-ExampleBaseImageSeed -BaseImage 'dotnet/sdk:10.0') -ne 0 -or
        -not ($script:Calls | Where-Object { $_ -like 'tag mcr.microsoft.com/dotnet/sdk:10.0 *' }) -or
        -not ($script:Calls | Where-Object { $_ -like 'push */dotnet/sdk:10.0' })) {
        throw 'A local base image must be tagged and pushed'
    }
    $script:PushExit = 17
    if ((Invoke-ExampleBaseImageSeed -BaseImage 'dotnet/sdk:10.0' -WarningAction SilentlyContinue) -ne 1) {
        throw 'Push failure must fail the seed step'
    }
    $script:PushExit = 0
    $script:LocalImage = ''
    $script:Calls.Clear()
    if ((Invoke-ExampleBaseImageSeed -BaseImage 'dotnet/sdk:10.0') -ne 0 -or
        -not ($script:Calls | Where-Object { $_ -like 'pull */dotnet/sdk:10.0' })) {
        throw 'A missing local image must be pulled before being pushed'
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-example-build-' + [guid]::NewGuid().ToString('N'))
try {
    $null = [IO.Directory]::CreateDirectory($fixture)
    $certificate = Join-Path $fixture 'fixture certificate.pfx'
    $destination = Join-Path $fixture 'context with spaces'
    $null = [IO.Directory]::CreateDirectory($destination)
    [IO.File]::WriteAllText($certificate, 'fixture certificate bytes')
    Copy-ExampleDevelopmentCertificate -Destination $destination -CertificatePath $certificate
    if ([IO.File]::ReadAllText((Join-Path $destination 'fixture certificate.pfx')) -cne 'fixture certificate bytes') {
        throw 'Certificate bytes changed'
    }
    $failed = $false
    try { Copy-ExampleDevelopmentCertificate -Destination $destination -CertificatePath (Join-Path $fixture 'missing.pfx') }
    catch { $failed = $_.Exception.Message -like '*Development certificate not found*' }
    if (-not $failed) { throw 'Missing certificate must stop the component phase' }

    # A copied build context must resolve its helper without the repository.
    $context = Join-Path $fixture 'exported context'
    $null = [IO.Directory]::CreateDirectory($context)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Example.Build.psm1') -Destination $context
    $exported = Import-Module (Join-Path $context 'Example.Build.psm1') -Force -PassThru
    & $exported { param($target, $source) Copy-ExampleDevelopmentCertificate -Destination $target -CertificatePath $source } $destination $certificate
    Remove-Module $exported
} finally {
    Remove-Module $module -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'yuruna-example-build-*' -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output 'Example build module: seed, certificate, and independent-context checks passed.'
