<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42b2bd9a-d168-4548-af37-7b5fbd3f8356
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
[CmdletBinding(SupportsShouldProcess)]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot 'Example.Build.psm1'
$expected = [IO.File]::ReadAllText($source)
foreach ($relative in @(
    'example/website/components/frontend/website/Example.Build.psm1',
    'example/text-to-sql/components/frontend/text-to-sql-ui/Example.Build.psm1'
)) {
    $destination = Join-Path $root $relative
    if ($Check) {
        if (-not (Test-Path -LiteralPath $destination) -or [IO.File]::ReadAllText($destination) -cne $expected) {
            throw "Bundled module differs from tools/Example.Build.psm1: $relative. Run tools/Sync-ExampleBuildModule.ps1."
        }
    } elseif ($PSCmdlet.ShouldProcess($destination, 'Synchronize the bundled example build module')) {
        [IO.File]::WriteAllText($destination, $expected, [Text.UTF8Encoding]::new($false))
    }
}
