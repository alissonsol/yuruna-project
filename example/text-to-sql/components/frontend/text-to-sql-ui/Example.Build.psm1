<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42aa6d6d-83ef-4b17-b241-3a1d6bc163d8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

# Each example bundles this module beside its Dockerfile so copying only that
# build context retains the same certificate and base-image preparation contract.

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

function Invoke-ExampleBaseImageSeed {
    <# .SYNOPSIS
        Populate the configured local registry with the example's base images.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string[]]$BaseImage = @('dotnet/sdk:10.0', 'dotnet/aspnet:10.0'))
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warning 'docker CLI not found; cannot seed base images.'
        return 1
    }
    # --- REGION: Resolve registry
    $registry = [Environment]::GetEnvironmentVariable("$($env:registryName).registryLocation")
    if ([string]::IsNullOrWhiteSpace($registry)) { $registry = 'localhost:5000' }
    Write-Information "seed-base-images registry: ${registry}"

    $acceptHeader = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

    # --- REGION: Locate caching proxy
    $cacheHost = ''
    if ($env:http_proxy -match '^https?://([^:/]+)') { $cacheHost = $Matches[1] }

    # --- REGION: Seed base images
    foreach ($ref in $BaseImage) {
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
            return 1
        }

        docker tag $localRef "${registry}/${ref}"
        if ($LASTEXITCODE -ne 0) { return 1 }
        if ((Invoke-BoundedDocker -StallSeconds 300 -DockerArgs @('push', "${registry}/${ref}")) -ne 0) {
            Write-Warning "Pushing ${ref} into ${registry} failed -- is the registry container up?"
            return 1
        }
    }
    return 0
}

function Copy-ExampleDevelopmentCertificate {
    <# .SYNOPSIS
        Copy the existing development certificate into an example build context.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string]$CertificatePath = (Join-Path $HOME '.aspnet/https/aspnetapp.pfx')
    )
    Write-Information "pfxFile: $CertificatePath"
    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        throw "Development certificate not found at '$CertificatePath'. Generate it before building: dotnet dev-certs https -ep '$CertificatePath' -p { password here }"
    }
    if ($PSCmdlet.ShouldProcess($Destination, 'Copy the development certificate')) {
        Copy-Item -LiteralPath $CertificatePath -Destination $Destination -Force -ErrorAction Stop
    }
}

Export-ModuleMember -Function Invoke-ExampleBaseImageSeed, Copy-ExampleDevelopmentCertificate
