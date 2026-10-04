<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42a7af8e-a2dc-48dd-8ac0-3c92a1d7e80a
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

# Checks create-db-secret.ps1 against a stand-in kubectl that records its arguments and the Secret
# it receives on standard input, then checks that the workloads configuration and the chart wire the
# Secret to the pod. No cluster, registry, or PostgreSQL is needed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$example = Split-Path -Parent $PSScriptRoot
$creator = Join-Path $example 'components/frontend/text-to-sql-ui/create-db-secret.ps1'
$setupStep = 'ubuntu.server.24.workload.k8s.text-to-sql.db.sh'
$checks = 0
# --- REGION: Assert-That
function Assert-That {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { throw $Message }
}

# Ambient values would change what these checks prove; every one is restored in the finally.
$variables = 'PATH', 'HOME', 'USERPROFILE', 'KUBECTL_LOG', 'KUBECTL_STDIN', 'KUBECTL_FAIL_ON'
$ambient = @{}
foreach ($name in $variables) { $ambient[$name] = [Environment]::GetEnvironmentVariable($name) }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-db-secret-' + [guid]::NewGuid().ToString('N'))
try {
    $null = [IO.Directory]::CreateDirectory($fixture)
    $stubDirectory = Join-Path $fixture 'stub'
    $null = [IO.Directory]::CreateDirectory($stubDirectory)
    $stubLog = Join-Path $fixture 'kubectl.log'
    $stubStdin = Join-Path $fixture 'kubectl.stdin'
    # The stand-in logs its arguments, keeps what it is sent on standard input, and fails the verb named in
    # KUBECTL_FAIL_ON. A failing create also prints the Secret, as a kubectl that echoes its input would.
    if ($IsWindows) {
        $lines = @(
            '@echo off',
            'echo %*>>"%KUBECTL_LOG%"',
            'if "%1"=="create" more > "%KUBECTL_STDIN%"',
            'if "%1"=="%KUBECTL_FAIL_ON%" (',
            '  echo Error from server ^(Forbidden^): fixture denial 1>&2',
            '  if "%1"=="create" type "%KUBECTL_STDIN%" 1>&2',
            '  exit /b 1',
            ')',
            'exit /b 0')
        [IO.File]::WriteAllText((Join-Path $stubDirectory 'kubectl.cmd'), (($lines -join "`r`n") + "`r`n"))
    } else {
        $stub = Join-Path $stubDirectory 'kubectl'
        $lines = @(
            '#!/bin/sh',
            'echo "$*" >> "$KUBECTL_LOG"',
            '[ "$1" = create ] && cat > "$KUBECTL_STDIN"',
            'if [ "$1" = "${KUBECTL_FAIL_ON:-none}" ]; then',
            '  echo "Error from server (Forbidden): fixture denial" >&2',
            '  [ "$1" = create ] && cat "$KUBECTL_STDIN" >&2',
            '  exit 1',
            'fi',
            'exit 0')
        [IO.File]::WriteAllText($stub, (($lines -join "`n") + "`n"))
        & chmod +x $stub
    }
    [Environment]::SetEnvironmentVariable('PATH', $stubDirectory + [IO.Path]::PathSeparator + $ambient['PATH'])
    [Environment]::SetEnvironmentVariable('KUBECTL_LOG', $stubLog)
    [Environment]::SetEnvironmentVariable('KUBECTL_STDIN', $stubStdin)

    # --- REGION: Get-RandomHex
    function Get-RandomHex {
        return [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    }
    # Runs the real script in a child process, as the deployment engine's shell step does, and returns its
    # exit code, every output stream as one text, the kubectl calls, and the Secret kubectl was sent.
    # --- REGION: Invoke-Creator
    function Invoke-Creator {
        param([string[]]$Arguments, [string]$FailOn = '')
        foreach ($file in $stubLog, $stubStdin) { if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) } }
        [Environment]::SetEnvironmentVariable('KUBECTL_FAIL_ON', $FailOn)
        $output = & pwsh -NoProfile -File $creator @Arguments -InformationAction Continue 2>&1
        $exit = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $stubLog) { (Get-Content -LiteralPath $stubLog) -join "`n" } else { '' }
        $bytes = if (Test-Path -LiteralPath $stubStdin) { [IO.File]::ReadAllBytes($stubStdin) } else { [byte[]]@() }
        $secret = if ($bytes.Count -gt 0) { [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ Exit = $exit; Text = (($output | ForEach-Object { "$_" }) -join "`n"); Calls = $calls; Secret = $secret; FirstByte = if ($bytes.Count) { $bytes[0] } else { 0 } }
    }
    # --- REGION: Get-SecretValue
    function Get-SecretValue {
        param($Secret)
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Secret.data.password))
    }
    # --- REGION: Write-Sidecar
    function Write-Sidecar {
        param([string]$Path, [string]$Content)
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        [IO.File]::WriteAllBytes($Path, [Text.UTF8Encoding]::new($false).GetBytes($Content))
    }
    # --- REGION: Assert-NoLeak
    function Assert-NoLeak {
        param($Run, [string[]]$Forbidden, [string]$Scenario)
        foreach ($value in $Forbidden) {
            Assert-That (-not ($Run.Text.Contains($value) -or $Run.Calls.Contains($value))) "$Scenario leaked the password or its encoding into output or a kubectl argument"
        }
    }

    $sidecar = Join-Path $fixture 'home/.text-to-sql/agent_ro.password'
    $common = @('-Namespace', 'fixture-ns', '-SecretName', 'fixture-db', '-SidecarFile', $sidecar)

    # The sidecar the database setup step writes: one line with a trailing newline.
    $password = Get-RandomHex
    Write-Sidecar -Path $sidecar -Content "$password`n"
    $run = Invoke-Creator -Arguments $common
    Assert-That ($run.Exit -eq 0) "The Secret step failed with a working kubectl: $($run.Text)"
    Assert-That ($run.Calls -ceq "delete secret fixture-db --namespace fixture-ns --ignore-not-found=true`ncreate --namespace fixture-ns -f -") "Unexpected kubectl calls: $($run.Calls)"
    Assert-That ($run.FirstByte -eq [byte][char]'{') 'The Secret must reach kubectl as bare JSON, with no byte-order mark or text before it'
    $secret = $run.Secret
    Assert-That ($secret.apiVersion -eq 'v1' -and $secret.kind -eq 'Secret' -and $secret.type -eq 'Opaque' -and $secret.metadata.name -eq 'fixture-db' -and $secret.metadata.namespace -eq 'fixture-ns') 'The Secret lost its identity'
    Assert-That ((@($secret.data.PSObject.Properties.Name) -join ',') -eq 'password') 'The Secret must hold exactly the key password'
    Assert-That ((Get-SecretValue -Secret $secret) -ceq $password) 'The Secret must carry the sidecar password unchanged'
    Assert-That ($run.Text -like "*Secret 'fixture-db' created in namespace 'fixture-ns'*") "The step must say what it created: $($run.Text)"
    Assert-NoLeak -Run $run -Forbidden @($password, $secret.data.password) -Scenario 'The Secret step'

    # Whatever surrounds the single line does not become part of the password.
    foreach ($shape in @(
            @{ Name = 'CRLF line ending'; Content = "$password`r`n" },
            @{ Name = 'no trailing newline'; Content = $password },
            @{ Name = 'surrounding blanks'; Content = "`n  $password  `n`n" },
            @{ Name = 'byte-order mark'; Content = [string][char]0xFEFF + "$password`n" })) {
        Write-Sidecar -Path $sidecar -Content $shape.Content
        $run = Invoke-Creator -Arguments $common
        Assert-That ($run.Exit -eq 0 -and (Get-SecretValue -Secret $run.Secret) -ceq $password) "A sidecar with $($shape.Name) must give the same Secret: $($run.Text)"
    }

    # Each deployment gets the password its database step just generated; the old Secret is replaced first.
    $replacement = Get-RandomHex
    Write-Sidecar -Path $sidecar -Content "$replacement`n"
    $run = Invoke-Creator -Arguments $common
    Assert-That ($run.Exit -eq 0 -and (Get-SecretValue -Secret $run.Secret) -ceq $replacement -and $run.Calls.StartsWith('delete secret')) 'A rerun must delete and recreate the Secret with the new password'

    # The default location is the owner's ~/.text-to-sql/agent_ro.password. Windows derives $HOME from USERPROFILE.
    $sandboxHome = Join-Path $fixture 'home'
    [Environment]::SetEnvironmentVariable('HOME', $sandboxHome)
    [Environment]::SetEnvironmentVariable('USERPROFILE', $sandboxHome)
    $run = Invoke-Creator -Arguments @('-Namespace', 'fixture-ns', '-SecretName', 'fixture-db')
    Assert-That ($run.Exit -eq 0 -and (Get-SecretValue -Secret $run.Secret) -ceq $replacement) "The default sidecar location is not ~/.text-to-sql/agent_ro.password: $($run.Text)"
    foreach ($name in 'HOME', 'USERPROFILE') { [Environment]::SetEnvironmentVariable($name, $ambient[$name]) }

    # The deployment engine runs the script in-process (& script), where the step's status is $LASTEXITCODE.
    # It must be 0 only when the Secret exists, whatever an earlier native command left behind.
    Write-Sidecar -Path $sidecar -Content "$password`n"
    $inProcess = "`$global:LASTEXITCODE = 7; & '$creator' -Namespace fixture-ns -SecretName fixture-db -SidecarFile '$sidecar' *> `$null; exit `$LASTEXITCODE"
    & pwsh -NoProfile -Command $inProcess
    Assert-That ($LASTEXITCODE -eq 0) 'An in-process run that created the Secret must leave $LASTEXITCODE at 0'
    $inProcess = $inProcess.Replace($sidecar, (Join-Path $fixture 'absent/agent_ro.password'))
    & pwsh -NoProfile -Command $inProcess
    Assert-That ($LASTEXITCODE -eq 1) 'An in-process run that could not read the sidecar must leave $LASTEXITCODE at 1'
    Assert-That ([IO.File]::ReadAllText($creator) -match '(?m)^exit 0\s*$') 'The success path must end with an explicit exit 0'

    # A sidecar that is missing, empty, or unusable stops the step before anything reaches the cluster, naming the file and the step.
    $missing = Join-Path $fixture 'absent/agent_ro.password'
    $run = Invoke-Creator -Arguments @('-Namespace', 'fixture-ns', '-SecretName', 'fixture-db', '-SidecarFile', $missing)
    Assert-That ($run.Exit -eq 1 -and -not $run.Calls) "A missing sidecar must fail without calling kubectl: $($run.Text)"
    Assert-That ($run.Text.Contains($missing) -and $run.Text.Contains($setupStep) -and $run.Text -like '*does not exist*') "The missing-sidecar message must name the file and the database step: $($run.Text)"
    foreach ($case in @(
            @{ Name = 'empty'; Content = ''; Expect = '*is empty*' },
            @{ Name = 'blank'; Content = "  `r`n`n"; Expect = '*is empty*' },
            @{ Name = 'two-line'; Content = "$password`nsecond`n"; Expect = '*exactly one line*' },
            @{ Name = 'semicolon'; Content = "abc;Host=elsewhere`n"; Expect = '*cannot be placed in a PostgreSQL connection string*' },
            @{ Name = 'equals'; Content = "abc=def`n"; Expect = '*cannot be placed in a PostgreSQL connection string*' },
            @{ Name = 'quote'; Content = "abc'def`n"; Expect = '*cannot be placed in a PostgreSQL connection string*' },
            @{ Name = 'space'; Content = "abc def`n"; Expect = '*cannot be placed in a PostgreSQL connection string*' })) {
        Write-Sidecar -Path $sidecar -Content $case.Content
        $run = Invoke-Creator -Arguments $common
        Assert-That ($run.Exit -eq 1 -and -not $run.Calls -and $run.Text -like $case.Expect -and $run.Text.Contains($sidecar) -and $run.Text.Contains($setupStep)) "A $($case.Name) sidecar must fail before kubectl, naming the file and the step: $($run.Text)"
        $secretText = $case.Content.Trim()
        Assert-That ($secretText -eq '' -or -not $run.Text.Contains($secretText.Split("`n")[0].Trim())) "A $($case.Name) sidecar was echoed in the failure"
    }
    $folder = Join-Path $fixture 'a-folder'
    $null = [IO.Directory]::CreateDirectory($folder)
    $run = Invoke-Creator -Arguments @('-Namespace', 'fixture-ns', '-SecretName', 'fixture-db', '-SidecarFile', $folder)
    Assert-That ($run.Exit -eq 1 -and -not $run.Calls) 'A folder in place of the sidecar must fail without calling kubectl'

    # A refusal from the cluster is reported through the exit code, and kubectl's own text never carries the password back out.
    Write-Sidecar -Path $sidecar -Content "$password`n"
    $run = Invoke-Creator -Arguments $common -FailOn 'delete'
    Assert-That ($run.Exit -eq 1 -and $run.Text -like '*could not delete*' -and $run.Text -like '*fixture denial*' -and $run.Calls -notlike '*create*') "A failed delete must fail the step before create: $($run.Text)"
    $run = Invoke-Creator -Arguments $common -FailOn 'create'
    Assert-That ($run.Exit -eq 1 -and $run.Text -like '*could not create*' -and $run.Text -like '*fixture denial*') "A failed create must fail the step: $($run.Text)"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($password))
    Assert-That ($run.Text -like '*<redacted>*') 'kubectl output that echoes the Secret must be redacted'
    Assert-NoLeak -Run $run -Forbidden @($password, $encoded) -Scenario 'A failed create'

    # Names are checked before they reach kubectl.
    foreach ($bad in @(@('-Namespace', 'Bad_Namespace', '-SecretName', 'fixture-db'), @('-Namespace', 'fixture-ns', '-SecretName', 'Bad Secret'))) {
        $run = Invoke-Creator -Arguments ($bad + @('-SidecarFile', $sidecar))
        Assert-That ($run.Exit -ne 0 -and -not $run.Calls) "An invalid name must be rejected before kubectl: $($bad -join ' ')"
    }

    # The script is plain ASCII with no byte-order mark, as every PowerShell source here must be.
    $bytes = [IO.File]::ReadAllBytes($creator)
    Assert-That (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) -and -not @($bytes | Where-Object { $_ -gt 127 }).Count) 'create-db-secret.ps1 must be ASCII without a byte-order mark'
    [Environment]::SetEnvironmentVariable('PATH', $ambient['PATH'])

    # The configuration runs the step before the chart, with the same arguments as the certificate step, and the chart reads the Secret.
    $yaml = Get-Module -ListAvailable powershell-yaml | Select-Object -First 1
    $template = [IO.File]::ReadAllText((Join-Path $example 'workloads/frontend/text-to-sql-ui/templates/01-text-to-sql-ui.yml'))
    $order = [regex]::Matches($template, '(?m)^\s+- name: (HOST_IP|TEXT2SQL_PG_PASSWORD|TEXT2SQL_PG_CONN)\s*$') | ForEach-Object { $_.Groups[1].Value }
    Assert-That (($order -join ',') -eq 'HOST_IP,TEXT2SQL_PG_PASSWORD,TEXT2SQL_PG_CONN') "Kubernetes expands `$(NAME) only from earlier variables, so the order must be HOST_IP, TEXT2SQL_PG_PASSWORD, TEXT2SQL_PG_CONN; found $($order -join ',')"
    Assert-That ($template -match 'Password=\$\(TEXT2SQL_PG_PASSWORD\);Database=yuruna_demo') 'The connection string must take the password from TEXT2SQL_PG_PASSWORD'
    Assert-That ($template -notmatch '(?i)Password=[A-Za-z0-9_.~+/-]') 'The chart must not hold a literal database password'
    if ($yaml) {
        Import-Module powershell-yaml
        $workloads = ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $example 'config/localhost/workloads.yml')))
        Assert-That ($workloads.globalVariables.appDbSecret -eq 'text-to-sql-db') 'workloads.yml must name the database Secret text-to-sql-db in appDbSecret'
        $steps = @($workloads.workloads[0].deployments)
        $chartIndex = [array]::FindIndex($steps, [Predicate[object]] { param($step) $step.chart -eq 'frontend/text-to-sql-ui' })
        $dbIndex = [array]::FindIndex($steps, [Predicate[object]] { param($step) $step.shell -like '*create-db-secret.ps1*' })
        $namespaceIndex = [array]::FindIndex($steps, [Predicate[object]] { param($step) $step.kubectl -like 'create namespace*' })
        Assert-That ($chartIndex -ge 0 -and $dbIndex -gt $namespaceIndex -and $namespaceIndex -ge 0 -and $dbIndex -lt $chartIndex) 'The database Secret must be created after the namespace and before the chart is installed'
        Assert-That ($steps[$dbIndex].shell -like '*components/frontend/text-to-sql-ui/create-db-secret.ps1*' -and
            $steps[$dbIndex].shell -like '*-SecretName ${env:appDbSecret}*' -and $steps[$dbIndex].shell -like '*-Namespace ${env:namespace}*') 'The database Secret step runs with unexpected arguments'
    } else {
        Write-Warning 'powershell-yaml is not installed; the workloads.yml ordering check was skipped.'
    }

    # The rendered chart reads the Secret through secretKeyRef and holds no password.
    if ($yaml -and (Get-Command helm -ErrorAction SilentlyContinue)) {
        $chartPath = Join-Path $example 'workloads/frontend/text-to-sql-ui'
        $values = "namespace: fixture-ns`nregistryName: componentsRegistry`ncomponentsRegistry.registryLocation: localhost:5000`ncontainerPrefix: text-to-sql`ningressClass: nginx`nappHost: localhost`nappTlsSecret: text-to-sql-ui-tls-secret`nappPodCertSecret: text-to-sql-ui-pod-cert`n"
        $valuesFile = Join-Path $fixture 'values.yaml'
        [IO.File]::WriteAllText($valuesFile, "${values}appDbSecret: fixture-db-secret`n")
        $rendered = (& helm template fixture-release $chartPath --values $valuesFile 2>&1) -join "`n"
        Assert-That ($LASTEXITCODE -eq 0) "helm template failed: $rendered"
        $pod = (@(ConvertFrom-Yaml -Yaml $rendered -AllDocuments) | Where-Object { $_.kind -eq 'Deployment' }).spec.template.spec
        $containerEnv = @($pod.containers[0].env)
        Assert-That ((($containerEnv | ForEach-Object { $_.name }) -join ',') -like 'HOST_IP,TEXT2SQL_PG_PASSWORD,TEXT2SQL_PG_CONN,*') 'The rendered environment must list HOST_IP, TEXT2SQL_PG_PASSWORD, then TEXT2SQL_PG_CONN'
        $passwordVariable = $containerEnv | Where-Object { $_.name -eq 'TEXT2SQL_PG_PASSWORD' }
        Assert-That ($passwordVariable.valueFrom.secretKeyRef.name -eq 'fixture-db-secret' -and $passwordVariable.valueFrom.secretKeyRef.key -eq 'password' -and $passwordVariable.Keys -notcontains 'value') 'TEXT2SQL_PG_PASSWORD must come from the database Secret through secretKeyRef'
        $connection = ($containerEnv | Where-Object { $_.name -eq 'TEXT2SQL_PG_CONN' }).value
        Assert-That ($connection -ceq 'Host=$(HOST_IP);Port=5432;Username=yuruna_agent_ro;Password=$(TEXT2SQL_PG_PASSWORD);Database=yuruna_demo') "Unexpected connection string: $connection"
        [IO.File]::WriteAllText($valuesFile, $values)
        $refused = (& helm template fixture-release $chartPath --values $valuesFile 2>&1) -join "`n"
        Assert-That ($LASTEXITCODE -ne 0 -and $refused -like '*appDbSecret*') "The chart must refuse to render without appDbSecret: $refused"
        [IO.File]::WriteAllText($valuesFile, "${values}appDbSecret: fixture-db-secret`n")
        & helm lint $chartPath --values $valuesFile 2>&1 | Out-Null
        Assert-That ($LASTEXITCODE -eq 0) 'helm lint failed'
    } else {
        Write-Warning 'helm or powershell-yaml is not installed; the rendered-chart checks were skipped.'
    }
} finally {
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $ambient[$name]) }
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'yuruna-db-secret-*' -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output "Database secret: $checks checks passed (sidecar reading, Secret contents, failure messages, secrecy, wiring)."
