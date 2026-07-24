<#PSScriptInfo
.VERSION 2026.07.24
.GUID 42a80288-ecfd-4370-856b-3b216c3b23ea
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

# Ensure the base images this component's Dockerfile FROMs reference are
# served by the project's local distribution registry (registryLocation,
# normally localhost:5000), so the build resolves FROM metadata over
# loopback instead of a remote registry. Idempotent: a manifest already
# served is a no-op. Acquisition order for a missing image: local docker
# store, the zot pull-through cache (derived from http_proxy), then
# mcr.microsoft.com direct.
# The list mirrors the Dockerfile's FROM lines.
$baseImages = @('dotnet/sdk:10.0', 'dotnet/aspnet:10.0')

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Warning "docker CLI not found; cannot seed base images."
    exit 1
}

# Run docker with an elapsed-time bound so a wedged registry surfaces as
# a failed seed step instead of hanging the component phase until the
# operator (or the session driving it) gives up. Returns the exit code,
# 124 on expiry (kills the whole process tree).
function Invoke-BoundedDocker {
    param(
        [Parameter(Mandatory)][int]$StallSeconds,
        [Parameter(Mandatory)][string[]]$DockerArgs
    )
    $outFile = $null
    $errFile = $null
    try {
        $outFile = (New-TemporaryFile).FullName
        $errFile = (New-TemporaryFile).FullName
        $process = Start-Process -FilePath 'docker' -ArgumentList $DockerArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $completed = $process.WaitForExit($StallSeconds * 1000)
        if (-not $completed) {
            try { $process.Kill($true) } catch { Write-Debug "kill: $($_.Exception.Message)" }
            $process.WaitForExit()
        }
        # Relay docker's output on the information stream: the success
        # stream must carry ONLY the exit code, because callers compare
        # the function's return value against 0 as a scalar.
        Get-Content -Path $outFile, $errFile -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Information $_ -InformationAction Continue }
        if (-not $completed) {
            Write-Warning "docker $($DockerArgs -join ' ') exceeded ${StallSeconds}s; treated as failed."
            return 124
        }
        return $process.ExitCode
    } finally {
        foreach ($tempFile in @($outFile, $errFile)) {
            if ($tempFile) { Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
}

$registry = [Environment]::GetEnvironmentVariable("$($env:registryName).registryLocation")
if ([string]::IsNullOrWhiteSpace($registry)) { $registry = 'localhost:5000' }
Write-Information "seed-base-images registry: ${registry}"

$acceptHeader = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

$cacheHost = ''
if ($env:http_proxy -match '^https?://([^:/]+)') { $cacheHost = $Matches[1] }

foreach ($ref in $baseImages) {
    $repo, $tag = $ref -split ':', 2

    $served = $false
    try {
        Invoke-WebRequest -Uri "http://${registry}/v2/${repo}/manifests/${tag}" -Method Head -Headers @{ Accept = $acceptHeader } -TimeoutSec 10 -ErrorAction Stop | Out-Null
        $served = $true
    } catch {
        Write-Debug "manifest probe for ${ref}: $($_.Exception.Message)"
    }
    if ($served) {
        Write-Information "Base image ${ref} already served by ${registry}"
        continue
    }

    $localRef = docker image ls --format '{{.Repository}}:{{.Tag}}' 2>$null |
        Where-Object { ($_ -eq $ref) -or ($_ -like "*/$ref") } |
        Select-Object -First 1

    if (-not $localRef) {
        $sources = @()
        if (-not [string]::IsNullOrWhiteSpace($cacheHost)) { $sources += "${cacheHost}:5000/" }
        $sources += 'mcr.microsoft.com/'
        foreach ($source in $sources) {
            Write-Information "Pulling ${source}${ref}"
            if ((Invoke-BoundedDocker -StallSeconds 300 -DockerArgs @('pull', "${source}${ref}")) -eq 0) {
                $localRef = "${source}${ref}"
                break
            }
        }
    }

    if (-not $localRef) {
        Write-Warning "Base image ${ref} is neither in the local docker store nor pullable; the build cannot resolve it locally."
        exit 1
    }

    docker tag $localRef "${registry}/${ref}"
    if ($LASTEXITCODE -ne 0) { exit 1 }
    if ((Invoke-BoundedDocker -StallSeconds 300 -DockerArgs @('push', "${registry}/${ref}")) -ne 0) {
        Write-Warning "Pushing ${ref} into ${registry} failed -- is the registry container up?"
        exit 1
    }
}
exit 0
