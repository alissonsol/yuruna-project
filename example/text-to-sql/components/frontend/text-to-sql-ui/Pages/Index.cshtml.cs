// Copyright (c) 2019-2026 by Alisson Sol et al.
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using TextToSqlUi.Services;

namespace TextToSqlUi.Pages;

public class IndexModel : PageModel
{
    private readonly AgentOrchestrator _agent;
    private readonly ILogger<IndexModel> _log;

    public IndexModel(AgentOrchestrator agent, ILogger<IndexModel> log)
    {
        _agent = agent;
        _log = log;
    }

    [BindProperty] public string Question { get; set; } = "";
    public AgentRun? Run { get; private set; }

    public async Task OnGetAsync(string? q, CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(q))
        {
            Question = q;
            Run = await _agent.RunAsync(q, ct);
        }
    }

    public async Task<IActionResult> OnPostAsync(CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(Question))
            return Page();

        Run = await _agent.RunAsync(Question, ct);
        return Page();
    }
}
