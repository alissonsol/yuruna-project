<#PSScriptInfo
.VERSION 2026.10.04
.GUID 428a1651-f4d0-45c5-9d0a-9adbc129e83c
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

# See https://yuruna.link/42010605-0005
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$Namespace,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$')][string]$SecretName,
    [string]$SidecarFile = (Join-Path $HOME '.text-to-sql/agent_ro.password')
)

$setupStep = 'ubuntu.server.24.workload.k8s.text-to-sql.db.sh'

# The only text here that does not come from this script is kubectl's own error output; keep
# the password, and the encoding it travels in, out of it.
# --- REGION: Hide-Secret
function Hide-Secret {
    param([string]$Text, [string[]]$Secret)
    foreach ($value in $Secret) {
        if ($value) { $Text = $Text.Replace($value, '<redacted>') }
    }
    return $Text
}

$hidden = @()
try {
    if (-not (Test-Path -LiteralPath $SidecarFile -PathType Leaf)) {
        throw "the database password file '$SidecarFile' does not exist. The database setup step ($setupStep) writes it before this workload step runs: run that step first, or write the read-only role's password on one line in that file."
    }
    $lines = @([IO.File]::ReadAllLines($SidecarFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) {
        throw "the database password file '$SidecarFile' is empty. The database setup step ($setupStep) writes the read-only role's password there: run it again before this workload step."
    }
    if ($lines.Count -gt 1) {
        throw "the database password file '$SidecarFile' must hold the password on exactly one line, but it holds $($lines.Count) lines. Run the database setup step ($setupStep) again to rewrite it."
    }
    $password = $lines[0]
    # The pod's connection string is the password substituted into Key=Value;Key=Value text,
    # so a value holding ; = quotes or whitespace would add or change connection keywords.
    if ($password -notmatch '^[A-Za-z0-9._~+/-]+$') {
        throw "the password in '$SidecarFile' contains characters that cannot be placed in a PostgreSQL connection string. Use only letters, digits and . _ ~ + / - (the database setup step ($setupStep) writes hexadecimal digits)."
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($password))
    $hidden = @($password, $encoded)
    $manifest = [ordered]@{
        apiVersion = 'v1'
        kind       = 'Secret'
        metadata   = [ordered]@{ name = $SecretName; namespace = $Namespace }
        type       = 'Opaque'
        data       = [ordered]@{ password = $encoded }
    } | ConvertTo-Json -Depth 4 -Compress

    # Delete first so a repeated run replaces the Secret; create, unlike apply, keeps the
    # data out of a last-applied-configuration annotation.
    $deleted = & kubectl delete secret $SecretName --namespace $Namespace --ignore-not-found=true 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl could not delete the previous Secret: $($deleted -join ' ')" }
    $created = $manifest | & kubectl create --namespace $Namespace -f - 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl could not create the Secret: $($created -join ' ')" }
    Write-Information "Secret '$SecretName' created in namespace '$Namespace' from $SidecarFile."
} catch {
    # Failures go to the error stream, which the deployment engine records at every log
    # level, and are reported by the exit code.
    Write-Error -ErrorAction Continue (Hide-Secret -Text "Cannot create Secret '$SecretName' in namespace '$Namespace': $($_.Exception.Message)" -Secret $hidden)
    exit 1
}
# An explicit status: after an in-process call the caller would otherwise read whatever
# kubectl left in $LASTEXITCODE.
exit 0
