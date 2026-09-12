<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42813fa1-cf84-4809-b9f3-c711fb218e2c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pssa-settings
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

@{
    # PSScriptAnalyzer settings for the yuruna-project repo.
    # Companion to yuruna/PSScriptAnalyzerSettings.psd1: the rule set
    # below is kept aligned with the framework's, but the surrounding
    # PSScriptInfo block (GUID, repo URL) is per-repo and must NOT be
    # copied across.
    #
    # Auto-discovered by `Invoke-ScriptAnalyzer -Path . -Recurse`.
    # Findings of every severity are reported; Information-severity
    # (low-priority) results are NOT filtered out.
    # PSUseBOMForUnicodeEncodedFile fires on a PowerShell file that contains
    # non-ASCII bytes and carries no BOM. Do NOT satisfy it by adding a BOM:
    # the pre-commit hook in the framework repo rejects a BOM in any file, so
    # the two rules would deadlock. Keep PowerShell sources ASCII-only, which
    # is what the framework's tools/Test-AsciiNoBom.ps1 enforces and what makes
    # this rule silent. When a file must be rewritten, use
    # `[System.Text.UTF8Encoding]::new($false)` -- the BOM-LESS overload.

    IncludeDefaultRules = $true

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
