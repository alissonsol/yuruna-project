// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42395d1b-4d22-46a1-9cb5-9e845ccbba53
using System.Diagnostics;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace TextToSqlUi.Pages;

public class ErrorModel : PageModel
{
    public string? RequestId { get; private set; }
    public void OnGet() => RequestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier;
}
