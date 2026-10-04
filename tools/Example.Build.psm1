<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42aa6d6d-83ef-4b17-b241-3a1d6bc163d8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

# Each example bundles this module beside its Dockerfile so copying only that
# build context retains the same base-image preparation and certificate Secret
# contract.

# --- REGION: Invoke-BoundedDocker
function Invoke-BoundedDocker {
    param(
        [Parameter(Mandatory)][Alias("StallSeconds")][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string[]]$DockerArgs
    )
    $outFile = $null
    $errFile = $null
    try {
        $outFile = (New-TemporaryFile).FullName
        $errFile = (New-TemporaryFile).FullName
        $process = Start-Process -FilePath 'docker' -ArgumentList $DockerArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
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
            Write-Warning "docker $($DockerArgs -join ' ') exceeded ${TimeoutSeconds}s; treated as failed."
            return 124
        }
        return $process.ExitCode
    } finally {
        foreach ($tempFile in @($outFile, $errFile)) {
            if ($tempFile) { Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
}

# --- REGION: Invoke-ExampleBaseImageSeed
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
                if ((Invoke-BoundedDocker -TimeoutSeconds 300 -DockerArgs @('pull', "${source}${ref}")) -eq 0) {
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
        if ((Invoke-BoundedDocker -TimeoutSeconds 300 -DockerArgs @('push', "${registry}/${ref}")) -ne 0) {
            Write-Warning "Pushing ${ref} into ${registry} failed -- is the registry container up?"
            return 1
        }
    }
    return 0
}

# See https://yuruna.link/42010605-0005
$script:SourcePasswordVariable = 'ASPNETCORE_Kestrel__Certificates__Default__Password'

# --- REGION: Test-ExampleSelfSignedRequested
function Test-ExampleSelfSignedRequested {
    <# .SYNOPSIS
        True when automation asked for a throwaway certificate instead of the developer's.
    #>
    [OutputType([bool])]
    param()
    return ([Environment]::GetEnvironmentVariable('YURUNA_EXAMPLE_SELF_SIGNED_CERT') -eq '1')
}

# --- REGION: Get-ExampleRandomPassword
function Get-ExampleRandomPassword {
    <# .SYNOPSIS
        Return a new random password: 32 bytes from the operating-system generator as 64 hex characters.
    #>
    [OutputType([string])]
    param()
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return (-join ($bytes | ForEach-Object { $_.ToString('x2', [Globalization.CultureInfo]::InvariantCulture) }))
}

# --- REGION: Get-ExampleSelfSignedCertificate
function Get-ExampleSelfSignedCertificate {
    <# .SYNOPSIS
        Create a throwaway self-signed server certificate for localhost, valid for 30 days.
    #>
    [OutputType([Security.Cryptography.X509Certificates.X509Certificate2])]
    param()
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=localhost', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $names = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $names.AddDnsName('localhost')
        $names.AddIpAddress([Net.IPAddress]::Loopback)
        $names.AddIpAddress([Net.IPAddress]::IPv6Loopback)
        $request.CertificateExtensions.Add($names.Build())
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]'DigitalSignature, KeyEncipherment', $true))
        # Kestrel refuses a certificate whose extended key usage omits server authentication.
        $usage = [Security.Cryptography.OidCollection]::new()
        $null = $usage.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usage, $true))
        $now = [DateTimeOffset]::UtcNow
        return $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(30))
    } finally {
        $rsa.Dispose()
    }
}

# --- REGION: Get-ExamplePfxPassword
function Get-ExamplePfxPassword {
    <# .SYNOPSIS
        Resolve the password of the developer's PFX: the environment variable when it is not empty,
        else the sidecar file beside the PFX, else none.
    .DESCRIPTION
        The sidecar is '<CertificatePath>.password'. Only trailing CR and LF characters are removed
        from its text, and a file that is empty after that counts as absent. Value is the password
        (or $null) and is never written to a stream; Description says, without the value, which
        source supplied it so a failure can report it.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$CertificatePath)
    $variable = $script:SourcePasswordVariable
    $sidecar = "$CertificatePath.password"
    $fromEnvironment = [Environment]::GetEnvironmentVariable($variable)
    if (-not [string]::IsNullOrEmpty($fromEnvironment)) {
        return [pscustomobject]@{ Value = $fromEnvironment; Description = "The password came from $variable." }
    }
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        try { $fromFile = [IO.File]::ReadAllText($sidecar) -replace '[\r\n]+\z', '' }
        catch { throw "Cannot read the password file '$sidecar': $($_.Exception.Message) Fix its permissions, or set $variable instead." }
        if ($fromFile.Length -gt 0) {
            return [pscustomobject]@{ Value = $fromFile; Description = "The password came from '$sidecar'." }
        }
    }
    return [pscustomobject]@{ Value = $null; Description = "No password was supplied: $variable is unset or empty and '$sidecar' is missing or empty." }
}

# --- REGION: Get-ExampleDevelopmentCertificate
function Get-ExampleDevelopmentCertificate {
    <# .SYNOPSIS
        Open the developer's PFX file with its password from the environment or from the sidecar file beside it.
    #>
    [OutputType([Security.Cryptography.X509Certificates.X509Certificate2])]
    param([Parameter(Mandatory)][string]$CertificatePath)
    $variable = $script:SourcePasswordVariable
    $sidecar = "$CertificatePath.password"
    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        throw "Development certificate not found at '$CertificatePath'. Generate it once: dotnet dev-certs https -ep '$CertificatePath' -p <password>, then set $variable to that password or write it to '$sidecar'. Automation that has no developer certificate sets YURUNA_EXAMPLE_SELF_SIGNED_CERT=1 for a throwaway one."
    }
    $resolved = Get-ExamplePfxPassword -CertificatePath $CertificatePath
    $password = $resolved.Value
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    $certificate = $null
    try {
        # X509CertificateLoader replaces the obsolete constructors on newer runtimes.
        $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
        $certificate = if ($loader) { $loader::LoadPkcs12FromFile($CertificatePath, $password, $flags) }
        else { [Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath, $password, $flags) }
    } catch {
        $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        # dotnet dev-certs writes only the public certificate, which is not a PFX, unless -p is given.
        throw "Cannot open '$CertificatePath': $reason The file must be a PFX that includes the private key (dotnet dev-certs https exports it only with -p), and the password it was exported with must be in $variable or, when that is unset, in '$sidecar'. $($resolved.Description)"
    }
    if (-not $certificate.HasPrivateKey) {
        $certificate.Dispose()
        throw "'$CertificatePath' holds no private key, so a pod could not serve HTTPS with it. Export it again with the private key: dotnet dev-certs https -ep '$CertificatePath' -p <password>, and keep that password in $variable or in '$sidecar'."
    }
    return $certificate
}

# --- REGION: Assert-ExampleDevelopmentCertificate
function Assert-ExampleDevelopmentCertificate {
    <# .SYNOPSIS
        Fail early when the certificate the example needs at run time is missing or cannot be opened.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([string]$CertificatePath = (Join-Path $HOME '.aspnet/https/aspnetapp.pfx'))
    if (Test-ExampleSelfSignedRequested) {
        Write-Information 'YURUNA_EXAMPLE_SELF_SIGNED_CERT=1: a throwaway certificate is issued at deployment; the developer certificate is not read.'
        return
    }
    Write-Information "pfxFile: $CertificatePath"
    $certificate = Get-ExampleDevelopmentCertificate -CertificatePath $CertificatePath
    $certificate.Dispose()
}

# --- REGION: Invoke-ExampleCertificateSecret
function Invoke-ExampleCertificateSecret {
    <# .SYNOPSIS
        Create the Kubernetes Secret that carries a pod's HTTPS certificate, protected by a new random password.
    .DESCRIPTION
        See https://yuruna.link/42010605-0005.
    .OUTPUTS
        0 when the Secret was created, 1 otherwise.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$Namespace,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$')][string]$SecretName,
        [string]$CertificatePath = (Join-Path $HOME '.aspnet/https/aspnetapp.pfx'),
        [switch]$SelfSigned
    )
    $certificate = $null
    try {
        if ($SelfSigned -or (Test-ExampleSelfSignedRequested)) {
            $certificate = Get-ExampleSelfSignedCertificate
            $origin = 'a throwaway self-signed certificate'
        } else {
            $certificate = Get-ExampleDevelopmentCertificate -CertificatePath $CertificatePath
            $origin = "the development certificate $($certificate.Thumbprint)"
        }
        $password = Get-ExampleRandomPassword
        $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password)
        $manifest = [ordered]@{
            apiVersion = 'v1'
            kind       = 'Secret'
            metadata   = [ordered]@{ name = $SecretName; namespace = $Namespace }
            type       = 'Opaque'
            data       = [ordered]@{
                'aspnetapp.pfx' = [Convert]::ToBase64String($pfx)
                'password'      = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($password))
            }
        } | ConvertTo-Json -Depth 4 -Compress

        # Delete first so a repeated run replaces the Secret; create, unlike apply, keeps the
        # data out of a last-applied-configuration annotation.
        $deleted = & kubectl delete secret $SecretName --namespace $Namespace --ignore-not-found=true 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error -ErrorAction Continue "Cannot replace Secret '$SecretName' in namespace '$Namespace': $($deleted -join ' ')"
            return 1
        }
        $created = $manifest | & kubectl create --namespace $Namespace -f - 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error -ErrorAction Continue "Cannot create Secret '$SecretName' in namespace '$Namespace': $($created -join ' ')"
            return 1
        }
        Write-Information "Secret '$SecretName' created in namespace '$Namespace' from $origin."
        return 0
    } catch {
        Write-Error -ErrorAction Continue "Cannot create Secret '$SecretName' in namespace '$Namespace': $($_.Exception.Message)"
        return 1
    } finally {
        if ($certificate) { $certificate.Dispose() }
    }
}

Export-ModuleMember -Function Invoke-ExampleBaseImageSeed, Assert-ExampleDevelopmentCertificate, Invoke-ExampleCertificateSecret
