// Copyright (c) 2019-2026 by Alisson Sol et al.
using System.Diagnostics;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace TextToSqlUi.Pages;

public class ErrorModel : PageModel
{
    public string? RequestId { get; private set; }
    public void OnGet() => RequestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier;
}
