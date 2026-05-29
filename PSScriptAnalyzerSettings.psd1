<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42c9d8e7-f6a5-4b43-4321-a9c8d7e6f5a4
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
    # PSUseBOMForUnicodeEncodedFile gates on BOM-less PowerShell files;
    # PS7 Set-Content / Out-File default to BOM-less UTF-8, so rewrite
    # with `[System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($true))`.

    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
