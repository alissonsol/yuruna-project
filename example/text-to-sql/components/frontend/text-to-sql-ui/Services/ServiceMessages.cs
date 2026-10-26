// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42cf0e8f-b250-4457-88b7-6a89b5fe7d3c
using System.Globalization;
using System.Resources;

namespace TextToSqlUi.Services;

internal static class ServiceMessages
{
    private static readonly ResourceManager Resources = new("TextToSqlUi.Services.ServiceMessages", typeof(ServiceMessages).Assembly);
    internal static string Get(string key, params object?[] args) =>
        string.Format(CultureInfo.CurrentCulture, Resources.GetString(key, CultureInfo.CurrentUICulture)
            ?? throw new MissingManifestResourceException(key), args);
}
