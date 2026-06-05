// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
using Microsoft.AspNetCore.Mvc.RazorPages;
using TextToSqlUi.Services;

namespace TextToSqlUi.Pages;

public class SchemaModel : PageModel
{
    private readonly SchemaCatalog _catalog;
    public SchemaModel(SchemaCatalog catalog) { _catalog = catalog; }

    public IReadOnlyList<TableInfo> Tables { get; private set; } = Array.Empty<TableInfo>();

    public async Task OnGetAsync() => Tables = await _catalog.GetAllAsync();
}
