@{
    # PSScriptAnalyzer settings for the yuruna-project repo.
    # Mirrors yuruna/PSScriptAnalyzerSettings.psd1 — keep in sync.
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
