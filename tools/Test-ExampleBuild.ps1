<#PSScriptInfo
.VERSION 2026.10.04
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
$root = Split-Path -Parent $PSScriptRoot

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

# The ambient values would change what these tests prove; both are restored in the finally.
$ambient = @{}
foreach ($name in 'ASPNETCORE_Kestrel__Certificates__Default__Password', 'YURUNA_EXAMPLE_SELF_SIGNED_CERT', 'PATH', 'USERPROFILE', 'HOME') {
    $ambient[$name] = [Environment]::GetEnvironmentVariable($name)
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-example-build-' + [guid]::NewGuid().ToString('N'))
try {
    $null = [IO.Directory]::CreateDirectory($fixture)
    [Environment]::SetEnvironmentVariable('ASPNETCORE_Kestrel__Certificates__Default__Password', $null)
    [Environment]::SetEnvironmentVariable('YURUNA_EXAMPLE_SELF_SIGNED_CERT', $null)

    # Certificate Secret: behavior in the module, with kubectl replaced by a recorder.
    & $module {
        param($fixture)
        # The seed fixtures above shadow the automatic exit code with a module-scope variable;
        # the Secret function must read the real one.
        Remove-Variable -Name LASTEXITCODE -Scope Script -ErrorAction SilentlyContinue
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:Stdin = $null
        $script:KubectlExit = 0
        $variable = 'ASPNETCORE_Kestrel__Certificates__Default__Password'
        $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
        function kubectl {
            $script:Calls.Add(($args -join ' '))
            $captured = @($input)
            if ($captured.Count -gt 0) { $script:Stdin = ($captured -join "`n") }
            $global:LASTEXITCODE = $script:KubectlExit
            if ($script:KubectlExit -eq 0) { 'fixture ok' } else { 'Error from server (Forbidden): fixture denial' }
        }
        function Open-Pfx {
            param([byte[]]$Bytes, [string]$Unlock)
            $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
            if ($loader) { return $loader::LoadPkcs12($Bytes, $Unlock, $flags) }
            return [Security.Cryptography.X509Certificates.X509Certificate2]::new($Bytes, $Unlock, $flags)
        }
        # Runs the Secret function and returns its exit code, every other stream as one text, and the Secret it sent.
        function Invoke-Scenario {
            param([hashtable]$Arguments)
            $script:Calls.Clear()
            $script:Stdin = $null
            $all = @(Invoke-ExampleCertificateSecret @Arguments *>&1)
            $exitCodes = @($all | Where-Object { $_ -is [int] })
            $text = ($all | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n"
            $secret = if ($script:Stdin) { $script:Stdin | ConvertFrom-Json } else { $null }
            return [pscustomobject]@{ Exit = $exitCodes[-1]; Text = $text; Secret = $secret; Calls = ($script:Calls -join "`n") }
        }
        function Get-SecretPassword {
            param($Secret)
            return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Secret.data.password))
        }
        function Assert-NoLeak {
            param($Result, [string[]]$Forbidden, [string]$Scenario)
            foreach ($value in $Forbidden) {
                if ($Result.Text.Contains($value) -or $Result.Calls.Contains($value)) {
                    throw "$Scenario leaked a password into output or a kubectl argument"
                }
            }
        }

        # A throwaway certificate: the Secret holds a usable key under a generated password nothing else shows.
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; SelfSigned = $true }
        if ($run.Exit -ne 0) { throw "Self-signed Secret failed: $($run.Text)" }
        if ($run.Calls -ne "delete secret fixture-pod-cert --namespace fixture-ns --ignore-not-found=true`ncreate --namespace fixture-ns -f -") {
            throw "Unexpected kubectl calls: $($run.Calls)"
        }
        $secret = $run.Secret
        if ($secret.kind -ne 'Secret' -or $secret.type -ne 'Opaque' -or $secret.metadata.name -ne 'fixture-pod-cert' -or $secret.metadata.namespace -ne 'fixture-ns') {
            throw 'The Secret lost its identity'
        }
        if (((@($secret.data.PSObject.Properties.Name) | Sort-Object) -join ',') -ne 'aspnetapp.pfx,password') {
            throw 'The Secret must hold exactly aspnetapp.pfx and password'
        }
        $generated = Get-SecretPassword -Secret $secret
        if ($generated -notmatch '^[0-9a-f]{64}$') { throw 'The generated password is not 32 random bytes in hex' }
        $pfx = [Convert]::FromBase64String($secret.data.'aspnetapp.pfx')
        $opened = Open-Pfx -Bytes $pfx -Unlock $generated
        if (-not $opened.HasPrivateKey -or $opened.Subject -ne 'CN=localhost') { throw 'The Secret certificate has no usable key' }
        if ($opened.Extensions['2.5.29.17'].Format($false) -notlike '*localhost*') { throw 'The throwaway certificate lost its localhost name' }
        $opened.Dispose()
        $rejected = $false
        try { Open-Pfx -Bytes $pfx -Unlock 'password' | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'The Secret PFX must not open with the legacy literal password' }
        Assert-NoLeak -Result $run -Forbidden @($generated, $secret.data.'aspnetapp.pfx') -Scenario 'Self-signed Secret'

        # Each deployment gets its own password.
        $again = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; SelfSigned = $true }
        if ((Get-SecretPassword -Secret $again.Secret) -eq $generated) { throw 'Passwords must differ between deployments' }

        # The developer's certificate: the same certificate, re-protected under a new password.
        $sourcePassword = Get-ExampleRandomPassword
        $source = Get-ExampleSelfSignedCertificate
        $sourcePath = Join-Path $fixture 'developer certificate.pfx'
        [IO.File]::WriteAllBytes($sourcePath, $source.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $sourcePassword))
        [Environment]::SetEnvironmentVariable($variable, $sourcePassword)
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = $sourcePath }
        if ($run.Exit -ne 0) { throw "Developer certificate Secret failed: $($run.Text)" }
        $reprotected = Get-SecretPassword -Secret $run.Secret
        if ($reprotected -eq $sourcePassword) { throw 'The cluster Secret must not reuse the developer password' }
        $opened = Open-Pfx -Bytes ([Convert]::FromBase64String($run.Secret.data.'aspnetapp.pfx')) -Unlock $reprotected
        if ($opened.Thumbprint -ne $source.Thumbprint -or -not $opened.HasPrivateKey) { throw 'The developer certificate was not carried into the Secret' }
        $opened.Dispose()
        $rejected = $false
        try { Open-Pfx -Bytes ([Convert]::FromBase64String($run.Secret.data.'aspnetapp.pfx')) -Unlock $sourcePassword | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'The Secret PFX must not open with the developer password' }
        Assert-NoLeak -Result $run -Forbidden @($sourcePassword, $reprotected) -Scenario 'Developer certificate Secret'

        # A file exported without a password needs no variable.
        $plainPath = Join-Path $fixture 'passwordless.pfx'
        [IO.File]::WriteAllBytes($plainPath, $source.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx))
        [Environment]::SetEnvironmentVariable($variable, $null)
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = $plainPath }
        if ($run.Exit -ne 0) { throw "A passwordless certificate must work: $($run.Text)" }

        # A protected file whose password is not supplied stops before anything reaches the cluster.
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = $sourcePath }
        if ($run.Exit -ne 1 -or $run.Text -notlike "*$variable*" -or $run.Calls) { throw "A missing password must stop the deployment: $($run.Text)" }
        Assert-NoLeak -Result $run -Forbidden @($sourcePassword) -Scenario 'Missing password'
        [Environment]::SetEnvironmentVariable($variable, 'not-the-password')
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = $sourcePath }
        if ($run.Exit -ne 1 -or $run.Calls) { throw 'A wrong password must stop the deployment' }
        Assert-NoLeak -Result $run -Forbidden @($sourcePassword, 'not-the-password') -Scenario 'Wrong password'
        [Environment]::SetEnvironmentVariable($variable, $null)

        # The password file beside the PFX ('<pfx>.password') supplies the password when the variable is
        # unset, the way the guest provisioning scripts leave it. The variable wins whenever it is set, and
        # a file that is empty after its trailing line breaks are removed counts as absent.
        function Find-Openssl {
            $found = Get-Command openssl -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.Source }
            $candidates = @('C:\Program Files\Git\usr\bin\openssl.exe', '/usr/local/bin/openssl', '/opt/homebrew/bin/openssl', '/usr/bin/openssl')
            $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($git) { $candidates = @([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'usr/bin/openssl.exe'))) + $candidates }
            return ($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
        }
        # The Ubuntu provisioning script's two commands; the password reaches openssl through the environment.
        function Export-GuestStylePfx {
            param([string]$Openssl, [string]$Directory, [string]$Unlock)
            $key = Join-Path $Directory 'aspnetapp.key'
            $crt = Join-Path $Directory 'aspnetapp.crt'
            $pfx = Join-Path $Directory 'aspnetapp.pfx'
            & $Openssl req -x509 -newkey rsa:2048 -keyout $key -out $crt -days 2 -nodes -subj '/CN=localhost' 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'openssl could not create the guest-style certificate' }
            [Environment]::SetEnvironmentVariable('YURUNA_TEST_PFX_PASSWORD', $Unlock)
            try { & $Openssl pkcs12 -export -out $pfx -inkey $key -in $crt -passout env:YURUNA_TEST_PFX_PASSWORD }
            finally { [Environment]::SetEnvironmentVariable('YURUNA_TEST_PFX_PASSWORD', [NullString]::Value) }
            if ($LASTEXITCODE -ne 0) { throw 'openssl could not export the guest-style PFX' }
            Remove-Item -LiteralPath $key, $crt -Force
            return $pfx
        }
        # Opens through the component phase check and through the Secret step, and carries the certificate into the Secret.
        function Assert-PasswordAccepted {
            param([string]$Path, [string]$Thumbprint, [string[]]$Forbidden, [string]$Scenario)
            Assert-ExampleDevelopmentCertificate -CertificatePath $Path
            $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = $Path }
            if ($run.Exit -ne 0) { throw "$Scenario must open the certificate: $($run.Text)" }
            $generated = Get-SecretPassword -Secret $run.Secret
            $opened = Open-Pfx -Bytes ([Convert]::FromBase64String($run.Secret.data.'aspnetapp.pfx')) -Unlock $generated
            if ($opened.Thumbprint -ne $Thumbprint -or -not $opened.HasPrivateKey) { throw "$Scenario did not carry the certificate into the Secret" }
            $opened.Dispose()
            Assert-NoLeak -Result $run -Forbidden (@($generated) + $Forbidden) -Scenario $Scenario
        }
        # Stops both steps before anything reaches the cluster. The message names the variable and the file, and says
        # which of them supplied the password that failed ($Source is the sentence it must contain).
        function Assert-PasswordRefused {
            param([string]$Path, [string[]]$Forbidden, [string]$Scenario, [string]$Source)
            $sidecar = "$Path.password"
            $failure = ''
            try { Assert-ExampleDevelopmentCertificate -CertificatePath $Path } catch { $failure = $_.Exception.Message }
            if (-not $failure.Contains($variable) -or -not $failure.Contains($sidecar) -or -not $failure.Contains($Source)) { throw "$Scenario must stop the component phase, name both password sources, and report '$Source': $failure" }
            $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = $Path }
            if ($run.Exit -ne 1 -or $run.Calls -or -not $run.Text.Contains($variable) -or -not $run.Text.Contains($sidecar) -or -not $run.Text.Contains($Source)) {
                throw "$Scenario must stop before kubectl, name both password sources, and report '$Source': $($run.Text)"
            }
            Assert-NoLeak -Result $run -Forbidden $Forbidden -Scenario $Scenario
            foreach ($value in $Forbidden) { if ($failure.Contains($value)) { throw "$Scenario leaked a password into the failure message" } }
        }
        $guestDirectory = Join-Path $fixture 'guest style'
        $null = [IO.Directory]::CreateDirectory($guestDirectory)
        $guestPfx = Join-Path $guestDirectory 'aspnetapp.pfx'
        $guestSidecar = "$guestPfx.password"
        $guestPassword = Get-ExampleRandomPassword
        $wrongPassword = Get-ExampleRandomPassword
        $bothPasswords = @($guestPassword, $wrongPassword)
        $pfxContent = [Security.Cryptography.X509Certificates.X509ContentType]::Pfx
        # [NullString]::Value removes the variable; $null would leave it defined and empty.
        $unset = [NullString]::Value
        $noPassword = 'No password was supplied'
        [IO.File]::WriteAllBytes($guestPfx, $source.Export($pfxContent, $guestPassword))

        [IO.File]::WriteAllText($guestSidecar, "$wrongPassword`n")
        [Environment]::SetEnvironmentVariable($variable, $guestPassword)
        Assert-PasswordAccepted -Path $guestPfx -Thumbprint $source.Thumbprint -Forbidden $bothPasswords -Scenario 'The variable beside a wrong password file'
        [IO.File]::WriteAllText($guestSidecar, "$guestPassword`n")
        [Environment]::SetEnvironmentVariable($variable, $wrongPassword)
        Assert-PasswordRefused -Path $guestPfx -Forbidden $bothPasswords -Scenario 'A wrong variable beside a right password file' -Source "The password came from $variable."
        [Environment]::SetEnvironmentVariable($variable, $unset)

        foreach ($ending in @("`n", "`r`n", '', "`r`n`r`n")) {
            [IO.File]::WriteAllText($guestSidecar, "$guestPassword$ending")
            $label = $ending.Replace("`r", '\r').Replace("`n", '\n')
            Assert-PasswordAccepted -Path $guestPfx -Thumbprint $source.Thumbprint -Forbidden $bothPasswords -Scenario "A password file followed by '$label'"
        }
        [IO.File]::WriteAllText($guestSidecar, "$guestPassword`n")
        [Environment]::SetEnvironmentVariable($variable, '')
        Assert-PasswordAccepted -Path $guestPfx -Thumbprint $source.Thumbprint -Forbidden $bothPasswords -Scenario 'An empty variable beside a password file'
        [Environment]::SetEnvironmentVariable($variable, $unset)
        # Only trailing line breaks are removed: spaces belong to the password.
        $spacedPassword = "  $(Get-ExampleRandomPassword)  "
        $spacedPfx = Join-Path $guestDirectory 'spaced.pfx'
        [IO.File]::WriteAllBytes($spacedPfx, $source.Export($pfxContent, $spacedPassword))
        [IO.File]::WriteAllText("$spacedPfx.password", "$spacedPassword`r`n")
        Assert-PasswordAccepted -Path $spacedPfx -Thumbprint $source.Thumbprint -Forbidden @($spacedPassword) -Scenario 'A password with surrounding spaces'

        foreach ($content in @('', "`r`n")) {
            [IO.File]::WriteAllText($guestSidecar, $content)
            Assert-PasswordRefused -Path $guestPfx -Forbidden $bothPasswords -Scenario 'A protected PFX beside an empty password file' -Source $noPassword
        }
        $plainGuestPfx = Join-Path $guestDirectory 'plain.pfx'
        [IO.File]::WriteAllBytes($plainGuestPfx, $source.Export($pfxContent))
        [IO.File]::WriteAllText("$plainGuestPfx.password", "`n")
        Assert-PasswordAccepted -Path $plainGuestPfx -Thumbprint $source.Thumbprint -Forbidden $bothPasswords -Scenario 'A passwordless PFX beside an empty password file'

        Remove-Item -LiteralPath $guestSidecar -Force
        Assert-PasswordRefused -Path $guestPfx -Forbidden $bothPasswords -Scenario 'A protected PFX with neither the variable nor a password file' -Source $noPassword
        $fixedPfx = Join-Path $guestDirectory 'fixed.pfx'
        [IO.File]::WriteAllBytes($fixedPfx, $source.Export($pfxContent, 'password'))
        Assert-PasswordRefused -Path $fixedPfx -Forbidden $bothPasswords -Scenario 'A PFX exported under a fixed password, with no password file' -Source $noPassword

        # A PFX made the way the Ubuntu guest makes it: openssl, a random password, and the password file.
        $openssl = Find-Openssl
        $opensslDirectory = Join-Path $fixture 'openssl guest'
        $null = [IO.Directory]::CreateDirectory($opensslDirectory)
        $opensslPassword = Get-ExampleRandomPassword
        if ($openssl) {
            $opensslPfx = Export-GuestStylePfx -Openssl $openssl -Directory $opensslDirectory -Unlock $opensslPassword
        } else {
            Write-Warning 'openssl is not installed; the guest-style PFX was created with .NET instead.'
            $opensslPfx = Join-Path $opensslDirectory 'aspnetapp.pfx'
            [IO.File]::WriteAllBytes($opensslPfx, $source.Export($pfxContent, $opensslPassword))
        }
        [IO.File]::WriteAllText("$opensslPfx.password", "$opensslPassword`n")
        $opensslCertificate = Open-Pfx -Bytes ([IO.File]::ReadAllBytes($opensslPfx)) -Unlock $opensslPassword
        $opensslThumbprint = $opensslCertificate.Thumbprint
        $opensslCertificate.Dispose()
        Assert-PasswordAccepted -Path $opensslPfx -Thumbprint $opensslThumbprint -Forbidden @($opensslPassword) -Scenario 'A guest-style PFX with its password file'
        $rejected = $false
        try { Open-Pfx -Bytes ([IO.File]::ReadAllBytes($opensslPfx)) -Unlock 'password' | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'A guest-style PFX must not open with a fixed password' }
        Remove-Item -LiteralPath "$opensslPfx.password" -Force
        Assert-PasswordRefused -Path $opensslPfx -Forbidden @($opensslPassword) -Scenario 'A guest-style PFX without its password file' -Source $noPassword

        # A certificate without its private key cannot serve HTTPS: dotnet dev-certs writes exactly that
        # (a bare public certificate, not even a PFX) unless a password is given.
        $publicCertificate = if ($loader) { $loader::LoadCertificate($source.RawData) } else { [Security.Cryptography.X509Certificates.X509Certificate2]::new($source.RawData) }
        $publicOnlyPath = Join-Path $fixture 'public only.pfx'
        [IO.File]::WriteAllBytes($publicOnlyPath, $publicCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $sourcePassword))
        $barePath = Join-Path $fixture 'bare public certificate.pfx'
        [IO.File]::WriteAllBytes($barePath, $source.RawData)
        [Environment]::SetEnvironmentVariable($variable, $sourcePassword)
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = $publicOnlyPath }
        if ($run.Exit -ne 1 -or $run.Text -notlike '*no private key*' -or $run.Calls) { throw "A PFX without a private key must stop the deployment: $($run.Text)" }
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = $barePath }
        if ($run.Exit -ne 1 -or $run.Text -notlike '*dev-certs https exports it only with -p*' -or $run.Calls) { throw "A bare public certificate must stop with guidance: $($run.Text)" }
        $publicCertificate.Dispose()
        [Environment]::SetEnvironmentVariable($variable, $null)

        # A missing file names the command that creates it.
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = (Join-Path $fixture 'missing.pfx') }
        if ($run.Exit -ne 1 -or $run.Text -notlike '*dotnet dev-certs https*' -or $run.Calls) { throw "A missing certificate must stop with guidance: $($run.Text)" }

        # Automation without a developer certificate opts into the throwaway one by environment.
        [Environment]::SetEnvironmentVariable('YURUNA_EXAMPLE_SELF_SIGNED_CERT', '1')
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; CertificatePath = (Join-Path $fixture 'missing.pfx') }
        if ($run.Exit -ne 0 -or $run.Text -notlike '*self-signed*') { throw "YURUNA_EXAMPLE_SELF_SIGNED_CERT=1 must issue a throwaway certificate: $($run.Text)" }
        Assert-ExampleDevelopmentCertificate -CertificatePath (Join-Path $fixture 'missing.pfx')
        [Environment]::SetEnvironmentVariable('YURUNA_EXAMPLE_SELF_SIGNED_CERT', $null)

        # The early check fails loudly, and passes for a usable file.
        $failed = $false
        try { Assert-ExampleDevelopmentCertificate -CertificatePath (Join-Path $fixture 'missing.pfx') }
        catch { $failed = $_.Exception.Message -like '*Development certificate not found*' }
        if (-not $failed) { throw 'A missing certificate must stop the component phase' }
        $failed = $false
        try { Assert-ExampleDevelopmentCertificate -CertificatePath $sourcePath }
        catch { $failed = $_.Exception.Message -like "*$variable*" }
        if (-not $failed) { throw 'A protected certificate without its password must stop the component phase' }
        [Environment]::SetEnvironmentVariable($variable, $sourcePassword)
        Assert-ExampleDevelopmentCertificate -CertificatePath $sourcePath
        [Environment]::SetEnvironmentVariable($variable, $null)

        # A cluster refusal is reported through the exit code, without echoing anything secret.
        $script:KubectlExit = 1
        $run = Invoke-Scenario @{ Namespace = 'fixture-ns'; SecretName = 'fixture-pod-cert'; SelfSigned = $true }
        if ($run.Exit -ne 1 -or $run.Text -notlike '*fixture denial*') { throw "A kubectl failure must fail the step: $($run.Text)" }
        $script:KubectlExit = 0

        # Names are checked before they reach kubectl.
        $rejected = $false
        try { Invoke-ExampleCertificateSecret -Namespace 'Bad_Namespace' -SecretName 'fixture-pod-cert' -SelfSigned | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw 'An invalid namespace must be rejected' }
        $source.Dispose()
    } $fixture

    # Certificate Secret: the wrapper script, with a real native kubectl stand-in.
    $stubDirectory = Join-Path $fixture 'stub'
    $null = [IO.Directory]::CreateDirectory($stubDirectory)
    $stubLog = Join-Path $fixture 'kubectl.log'
    $stubStdin = Join-Path $fixture 'kubectl.stdin'
    if ($IsWindows) {
        [IO.File]::WriteAllText((Join-Path $stubDirectory 'kubectl.cmd'),
            "@echo off`r`necho %*>>`"%KUBECTL_LOG%`"`r`nif `"%1`"==`"create`" more > `"%KUBECTL_STDIN%`"`r`nexit /b %KUBECTL_EXIT%`r`n")
    } else {
        $stub = Join-Path $stubDirectory 'kubectl'
        [IO.File]::WriteAllText($stub, "#!/bin/sh`necho `"`$*`" >> `"`$KUBECTL_LOG`"`n[ `"`$1`" = create ] && cat > `"`$KUBECTL_STDIN`"`nexit `"`${KUBECTL_EXIT:-0}`"`n")
        & chmod +x $stub
    }
    [Environment]::SetEnvironmentVariable('PATH', $stubDirectory + [IO.Path]::PathSeparator + $ambient['PATH'])
    [Environment]::SetEnvironmentVariable('KUBECTL_LOG', $stubLog)
    [Environment]::SetEnvironmentVariable('KUBECTL_STDIN', $stubStdin)
    [Environment]::SetEnvironmentVariable('YURUNA_EXAMPLE_SELF_SIGNED_CERT', '1')
    $wrapperText = foreach ($component in 'example/website/components/frontend/website', 'example/text-to-sql/components/frontend/text-to-sql-ui') {
        [IO.File]::ReadAllText((Join-Path $root "$component/create-cert-secret.ps1")) -replace '(?m)^\.GUID .*$', '.GUID ID'
    }
    if ($wrapperText[0] -cne $wrapperText[1]) { throw 'The certificate Secret wrappers must stay identical across the examples' }
    foreach ($component in 'example/website/components/frontend/website', 'example/text-to-sql/components/frontend/text-to-sql-ui') {
        $wrapper = Join-Path $root "$component/create-cert-secret.ps1"
        [Environment]::SetEnvironmentVariable('KUBECTL_EXIT', '0')
        & pwsh -NoProfile -File $wrapper -Namespace fixture-ns -SecretName fixture-pod-cert 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$component wrapper failed with a working kubectl" }
        $bytes = [IO.File]::ReadAllBytes($stubStdin)
        if ($bytes[0] -ne [byte][char]'{') { throw "$component wrapper sent a byte-order mark or text before the Secret" }
        $sent = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        $sentPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sent.data.password))
        if ($sent.kind -ne 'Secret' -or $sentPassword -notmatch '^[0-9a-f]{64}$') { throw "$component wrapper sent an unexpected Secret" }
        if ((Get-Content -LiteralPath $stubLog -Raw).Contains($sentPassword)) { throw "$component wrapper put the password on a command line" }
        [IO.File]::Delete($stubLog)
        [Environment]::SetEnvironmentVariable('KUBECTL_EXIT', '1')
        & pwsh -NoProfile -File $wrapper -Namespace fixture-ns -SecretName fixture-pod-cert 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { throw "$component wrapper must report a kubectl failure as a non-zero exit code" }
        [IO.File]::Delete($stubLog)
    }
    [Environment]::SetEnvironmentVariable('PATH', $ambient['PATH'])
    [Environment]::SetEnvironmentVariable('YURUNA_EXAMPLE_SELF_SIGNED_CERT', $null)

    # The developer run scripts hand the password to Docker by name. With the variable unset they take it from the
    # password file beside the PFX, for that run only. A docker stand-in records its calls and the value its
    # environment held; the .cmd stand-in never returns to the batch file, so only its first call is seen.
    $passwordName = 'ASPNETCORE_Kestrel__Certificates__Default__Password'
    $devHome = Join-Path $fixture 'developer profile'
    $devHttps = Join-Path $devHome '.aspnet/https'
    $null = [IO.Directory]::CreateDirectory($devHttps)
    $devStub = Join-Path $fixture 'docker stub'
    $null = [IO.Directory]::CreateDirectory($devStub)
    $devEnvLog = Join-Path $fixture 'docker.env'
    $devCallLog = Join-Path $fixture 'docker.calls'
    if ($IsWindows) {
        [IO.File]::WriteAllText((Join-Path $devStub 'docker.cmd'),
            "@echo off`r`necho %1>>`"%DOCKER_CALL_LOG%`"`r`nset $passwordName>`"%DOCKER_ENV_LOG%`" 2>nul`r`nexit /b 0`r`n")
    } else {
        $dockerStub = Join-Path $devStub 'docker'
        $dockerText = @'
#!/bin/sh
echo "$1" >> "$DOCKER_CALL_LOG"
: > "$DOCKER_ENV_LOG"
if [ -n "${__NAME__+x}" ]; then printf '__NAME__=%s\n' "$__NAME__" > "$DOCKER_ENV_LOG"; fi
exit 0
'@
        [IO.File]::WriteAllText($dockerStub, $dockerText.Replace("`r`n", "`n").Replace('__NAME__', $passwordName))
        & chmod +x $dockerStub
    }
    function Invoke-DeveloperScript {
        param([string]$Path, $VariableValue)
        foreach ($log in $devEnvLog, $devCallLog) { if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force } }
        # Only [NullString]::Value removes a variable; $null would leave it defined and empty.
        $applied = if ($null -eq $VariableValue) { [NullString]::Value } else { [string]$VariableValue }
        [Environment]::SetEnvironmentVariable($passwordName, $applied)
        if ($Path.EndsWith('.cmd')) {
            $output = & cmd.exe /c $Path 2>&1 | Out-String
        } else {
            $output = & pwsh -NoProfile -Command "& '$Path'; 'variable-after-run: ' + (`$null -eq [Environment]::GetEnvironmentVariable('$passwordName'))" 2>&1 | Out-String
        }
        $exit = $LASTEXITCODE
        [Environment]::SetEnvironmentVariable($passwordName, [NullString]::Value)
        $calls = if (Test-Path -LiteralPath $devCallLog) { @(Get-Content -LiteralPath $devCallLog) } else { @() }
        $logged = if (Test-Path -LiteralPath $devEnvLog) { [IO.File]::ReadAllText($devEnvLog) -replace '[\r\n]+\z', '' } else { '' }
        $value = if ($logged.StartsWith("$passwordName=")) { $logged.Substring($passwordName.Length + 1) } else { $null }
        return [pscustomobject]@{ Exit = $exit; Output = $output; Calls = ($calls -join ','); Value = $value }
    }
    $devCertificate = & $module { Get-ExampleSelfSignedCertificate }
    $devPassword = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $otherPassword = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $devPfx = Join-Path $devHttps 'aspnetapp.pfx'
    $devSidecar = "$devPfx.password"
    $devPfxType = [Security.Cryptography.X509Certificates.X509ContentType]::Pfx
    $homeName = if ($IsWindows) { 'USERPROFILE' } else { 'HOME' }
    $websiteComponent = Join-Path $root 'example/website/components/frontend/website'
    $devPs1 = Join-Path $websiteComponent 'docker-run-dev.ps1'
    $devCmd = Join-Path $websiteComponent 'docker-run-dev.cmd'
    [Environment]::SetEnvironmentVariable($homeName, $devHome)
    [Environment]::SetEnvironmentVariable('PATH', $devStub + [IO.Path]::PathSeparator + $ambient['PATH'])
    [Environment]::SetEnvironmentVariable('DOCKER_ENV_LOG', $devEnvLog)
    [Environment]::SetEnvironmentVariable('DOCKER_CALL_LOG', $devCallLog)
    try {
        [IO.File]::WriteAllBytes($devPfx, $devCertificate.Export($devPfxType, $devPassword))
        [IO.File]::WriteAllText($devSidecar, "$devPassword`n")
        $run = Invoke-DeveloperScript -Path $devPs1 -VariableValue $null
        if ($run.Exit -ne 0 -or $run.Calls -ne 'build,run' -or $run.Value -cne $devPassword) { throw "docker-run-dev.ps1 must pass the password file's value to Docker by name (exit $($run.Exit), calls '$($run.Calls)'): $($run.Output)" }
        if ($run.Output.Contains($devPassword)) { throw 'docker-run-dev.ps1 echoed the password' }
        if ($run.Output -notmatch 'variable-after-run: True') { throw 'docker-run-dev.ps1 left the password in the environment of the shell that ran it' }
        $run = Invoke-DeveloperScript -Path $devPs1 -VariableValue ''
        if ($run.Exit -ne 0 -or $run.Value -cne $devPassword) { throw "docker-run-dev.ps1 must treat an empty variable as unset (exit $($run.Exit), calls '$($run.Calls)'): $($run.Output)" }

        [IO.File]::WriteAllText($devSidecar, "$otherPassword`n")
        $run = Invoke-DeveloperScript -Path $devPs1 -VariableValue $devPassword
        if ($run.Exit -ne 0 -or $run.Value -cne $devPassword) { throw "docker-run-dev.ps1 must prefer the variable to the password file (exit $($run.Exit), calls '$($run.Calls)'): $($run.Output)" }

        foreach ($content in @($null, '', "`r`n")) {
            if ($null -eq $content) { Remove-Item -LiteralPath $devSidecar -Force -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllText($devSidecar, $content) }
            $run = Invoke-DeveloperScript -Path $devPs1 -VariableValue $null
            if ($run.Exit -eq 0 -or $run.Calls -or $run.Output -notlike "*$passwordName*") { throw "docker-run-dev.ps1 must stop before building when no password opens the PFX (exit $($run.Exit), calls '$($run.Calls)'): $($run.Output)" }
        }

        [IO.File]::WriteAllBytes($devPfx, $devCertificate.Export($devPfxType))
        $run = Invoke-DeveloperScript -Path $devPs1 -VariableValue $null
        if ($run.Exit -ne 0 -or $run.Calls -ne 'build,run' -or $null -ne $run.Value) { throw "docker-run-dev.ps1 must not invent a password for a passwordless PFX (exit $($run.Exit), calls '$($run.Calls)'): $($run.Output)" }

        if ($IsWindows) {
            foreach ($case in @(
                @{ File = "$devPassword`n"; Variable = $null; Expect = $devPassword },
                @{ File = "$devPassword`r`n"; Variable = $null; Expect = $devPassword },
                @{ File = "$otherPassword`n"; Variable = $devPassword; Expect = $devPassword },
                @{ File = $null; Variable = $null; Expect = $null },
                @{ File = "`r`n"; Variable = $null; Expect = $null }
            )) {
                if ($null -eq $case.File) { Remove-Item -LiteralPath $devSidecar -Force -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllText($devSidecar, $case.File) }
                $run = Invoke-DeveloperScript -Path $devCmd -VariableValue $case.Variable
                if ($run.Exit -ne 0 -or $run.Calls -ne 'build' -or $run.Value -cne $case.Expect) { throw "docker-run-dev.cmd passed the wrong password to Docker (exit $($run.Exit), calls '$($run.Calls)'): $($run.Output)" }
                foreach ($secret in @($devPassword, $otherPassword)) { if ($run.Output.Contains($secret)) { throw 'docker-run-dev.cmd echoed a password' } }
            }
        } else {
            Write-Warning 'docker-run-dev.cmd is a Windows batch file; its password-file handling was not run on this platform.'
        }
    } finally {
        $devCertificate.Dispose()
        [Environment]::SetEnvironmentVariable($homeName, $(if ($null -eq $ambient[$homeName]) { [NullString]::Value } else { $ambient[$homeName] }))
        [Environment]::SetEnvironmentVariable('PATH', $ambient['PATH'])
        [Environment]::SetEnvironmentVariable($passwordName, [NullString]::Value)
    }

    # A copied build context must resolve its helper without the repository.
    $context = Join-Path $fixture 'exported context'
    $null = [IO.Directory]::CreateDirectory($context)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Example.Build.psm1') -Destination $context
    $exported = Import-Module (Join-Path $context 'Example.Build.psm1') -Force -PassThru
    $exportedFunctions = ($exported.ExportedFunctions.Keys | Sort-Object) -join ','
    if ($exportedFunctions -ne 'Assert-ExampleDevelopmentCertificate,Invoke-ExampleBaseImageSeed,Invoke-ExampleCertificateSecret') {
        throw "The bundled module exports $exportedFunctions"
    }
    $failed = $false
    try { Assert-ExampleDevelopmentCertificate -CertificatePath (Join-Path $fixture 'missing.pfx') }
    catch { $failed = $_.Exception.Message -like '*Development certificate not found*' }
    if (-not $failed) { throw 'A copied context must still stop on a missing certificate' }
    Remove-Module $exported

    # Nothing that ships may carry key material or a literal certificate password.
    # This script spells out the patterns it looks for, so it is the one file left out of the scan.
    $ignoredFolder = '[\\/](bin|obj|node_modules|\.yuruna|\.git)[\\/]'
    $scanned = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch $ignoredFolder -and $_.Name -ne 'Test-ExampleBuild.ps1' } |
        Where-Object { $_.Extension -in '.yml', '.yaml', '.cmd', '.ps1', '.psm1', '.md', '.sh', '.json', '.cs' -or $_.Name -in 'Dockerfile', '.dockerignore' })
    if ($scanned.Count -lt 50) { throw "The scan found only $($scanned.Count) files; the repository layout changed" }
    $literalAssignment = '(?i)Certificates__Default__Password["'']?\s*=\s*["''][^"''$%(\r\n{<]+["'']'
    $literalYaml = '(?is)name:\s*["'']?ASPNETCORE_Kestrel__Certificates__Default__Password["'']?\s*\r?\n\s*value:'
    foreach ($file in $scanned) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName)
        if ($text -match $literalAssignment -or $text -match $literalYaml) { throw "$relative carries a literal certificate password" }
        if ($file.Name -eq 'Dockerfile' -and $text -match '(?im)^\s*(COPY|ADD)\b[^\r\n]*\.(pfx|p12|pem|key)\b') { throw "$relative copies key material into an image" }
        if ($file.Name -eq 'Dockerfile' -and $text -match '(?im)^\s*(ENV|ARG)\b[^\r\n]*(password|pfx)') { throw "$relative bakes a password into an image" }
    }
    foreach ($dockerfile in @($scanned | Where-Object Name -EQ 'Dockerfile')) {
        $ignore = Join-Path $dockerfile.DirectoryName '.dockerignore'
        if (-not (Test-Path -LiteralPath $ignore) -or [IO.File]::ReadAllText($ignore) -notmatch '(?m)^\*\*/\*\.pfx\s*$') {
            throw "$([IO.Path]::GetRelativePath($root, $dockerfile.DirectoryName)) must exclude *.pfx from its build context"
        }
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $tracked = @(& git -C $root ls-files -- '*.pfx' '*.p12' '*.pem' '*.key')
        if ($tracked.Count -gt 0) { throw "Tracked key material: $($tracked -join ', ')" }
    }

    # The deployment order and the chart agree on the Secret.
    $deployments = @(
        @{ Config = 'example/website/config/localhost/workloads.yml'; Chart = 'frontend/website'; Variable = 'websitePodCertSecret'; Component = 'website' },
        @{ Config = 'example/website/config/azure/workloads.yml'; Chart = 'frontend/website'; Variable = 'websitePodCertSecret'; Component = 'website' },
        @{ Config = 'example/website/config/aws/workloads.yml'; Chart = 'frontend/website'; Variable = 'websitePodCertSecret'; Component = 'website' },
        @{ Config = 'example/text-to-sql/config/localhost/workloads.yml'; Chart = 'frontend/text-to-sql-ui'; Variable = 'appPodCertSecret'; Component = 'text-to-sql-ui' }
    )
    $yaml = Get-Module -ListAvailable powershell-yaml | Select-Object -First 1
    if ($yaml) {
        Import-Module powershell-yaml
        foreach ($deployment in $deployments) {
            $example = ($deployment.Config -split '/')[1]
            $workloads = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $root $deployment.Config) -Raw)
            if (-not $workloads.globalVariables.Contains($deployment.Variable)) { throw "$($deployment.Config) does not name the pod certificate Secret in $($deployment.Variable)" }
            $steps = @($workloads.workloads[0].deployments)
            $chartIndex = [array]::FindIndex($steps, [Predicate[object]] { param($step) $step.chart -eq $deployment.Chart })
            $secretIndex = [array]::FindIndex($steps, [Predicate[object]] { param($step) $step.shell -like '*create-cert-secret.ps1*' })
            if ($chartIndex -lt 0) { throw "$($deployment.Config) no longer installs $($deployment.Chart)" }
            if ($secretIndex -lt 0 -or $secretIndex -gt $chartIndex) { throw "$($deployment.Config) must create the certificate Secret before installing the chart" }
            if ($steps[$secretIndex].shell -notlike "*components/frontend/$($deployment.Component)/create-cert-secret.ps1*" -or
                $steps[$secretIndex].shell -notlike "*-SecretName `${env:$($deployment.Variable)}*" -or
                $steps[$secretIndex].shell -notlike '*-Namespace ${env:namespace}*') {
                throw "$($deployment.Config) runs the certificate Secret step with unexpected arguments"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $root "example/$example/components/frontend/$($deployment.Component)/create-cert-secret.ps1"))) {
                throw "$($deployment.Config) names a certificate Secret script that does not exist"
            }
        }
    } else {
        Write-Warning 'powershell-yaml is not installed; the workloads.yml ordering check was skipped.'
    }

    # The rendered workloads read the Secret and hold no password.
    if ($yaml -and (Get-Command helm -ErrorAction SilentlyContinue)) {
        $charts = @(
            @{ Path = 'example/website/workloads/frontend/website'; Name = 'website'; Variable = 'websitePodCertSecret'; Secret = 'website-pod-cert'
               Values = "namespace: fixture-ns`nregistryName: componentsRegistry`ncomponentsRegistry.registryLocation: localhost:5000`ncontainerPrefix: website`ningressClass: nginx`nwebsiteHost: localhost`nwebsiteTlsSecret: website-tls-secret`n" },
            @{ Path = 'example/text-to-sql/workloads/frontend/text-to-sql-ui'; Name = 'text-to-sql-ui'; Variable = 'appPodCertSecret'; Secret = 'text-to-sql-ui-pod-cert'
               Values = "namespace: fixture-ns`nregistryName: componentsRegistry`ncomponentsRegistry.registryLocation: localhost:5000`ncontainerPrefix: text-to-sql`ningressClass: nginx`nappHost: localhost`nappTlsSecret: text-to-sql-ui-tls-secret`nappDbSecret: text-to-sql-db`n" }
        )
        foreach ($chart in $charts) {
            $chartPath = Join-Path $root $chart.Path
            $valuesFile = Join-Path $fixture "$($chart.Name).values.yaml"
            [IO.File]::WriteAllText($valuesFile, "$($chart.Values)$($chart.Variable): $($chart.Secret)`n")
            $rendered = (& helm template fixture-release $chartPath --values $valuesFile 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw "helm template failed for $($chart.Name): $rendered" }
            if ($rendered -match 'value:\s*"password"') { throw "$($chart.Name) renders a literal password" }
            if ($rendered -notmatch 'defaultMode:\s*0440') { throw "$($chart.Name) must keep the private key readable by its owner and group only" }
            $documents = @(ConvertFrom-Yaml -Yaml $rendered -AllDocuments)
            $pod = ($documents | Where-Object { $_.kind -eq 'Deployment' }).spec.template.spec
            if ($pod.securityContext.fsGroup -ne 1654) { throw "$($chart.Name) must give the .NET image's non-root group access to the key" }
            $container = $pod.containers[0]
            $passwordVariable = $container.env | Where-Object name -EQ 'ASPNETCORE_Kestrel__Certificates__Default__Password'
            if ($passwordVariable.valueFrom.secretKeyRef.name -ne $chart.Secret -or $passwordVariable.valueFrom.secretKeyRef.key -ne 'password' -or
                $passwordVariable.Keys -contains 'value') {
                throw "$($chart.Name) must read the certificate password through secretKeyRef"
            }
            $pathVariable = $container.env | Where-Object name -EQ 'ASPNETCORE_Kestrel__Certificates__Default__Path'
            $mount = $container.volumeMounts | Where-Object mountPath -EQ '/https'
            $volume = $pod.volumes | Where-Object { $_.name -eq $mount.name }
            if ($pathVariable.value -ne '/https/aspnetapp.pfx' -or -not $mount.readOnly -or $volume.secret.secretName -ne $chart.Secret -or
                @($volume.secret.items).Count -ne 1 -or $volume.secret.items[0].key -ne 'aspnetapp.pfx' -or $volume.secret.items[0].path -ne 'aspnetapp.pfx') {
                throw "$($chart.Name) must mount only the certificate from the Secret at /https"
            }
            # The template refuses to render without the Secret name, so a missing value cannot deploy a pod that never starts.
            [IO.File]::WriteAllText($valuesFile, $chart.Values)
            $refused = (& helm template fixture-release $chartPath --values $valuesFile 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0 -or $refused -notlike "*$($chart.Variable)*") { throw "$($chart.Name) must require $($chart.Variable)" }
            & helm lint $chartPath --values $valuesFile --set "$($chart.Variable)=$($chart.Secret)" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "helm lint failed for $($chart.Name)" }
        }
    } else {
        Write-Warning 'helm or powershell-yaml is not installed; the rendered-chart checks were skipped.'
    }
} finally {
    # Only a null string removes a variable; $null would leave it defined and empty.
    foreach ($name in $ambient.Keys) { [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $ambient[$name]) { [NullString]::Value } else { $ambient[$name] })) }
    foreach ($name in 'KUBECTL_LOG', 'KUBECTL_STDIN', 'KUBECTL_EXIT', 'DOCKER_ENV_LOG', 'DOCKER_CALL_LOG', 'YURUNA_TEST_PFX_PASSWORD') { [Environment]::SetEnvironmentVariable($name, [NullString]::Value) }
    Remove-Module $module -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'yuruna-example-build-*' -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output 'Example build module: seed, certificate Secret, pod certificate wiring, and independent-context checks passed.'
