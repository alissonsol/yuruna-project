// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42bddc8d-21f0-46ca-972a-2859c24c59c5
// --- REGION: Initialize application
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();

// --- REGION: Configure HTTP pipeline
var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    // The default HSTS value is 30 days. You may want to change this for production scenarios, see https://aka.ms/aspnetcore-hsts.
    app.UseHsts();
}

app.UseHttpsRedirection();

app.UseRouting();

app.UseAuthorization();

app.MapStaticAssets();
app.MapRazorPages()
   .WithStaticAssets();

// --- REGION: Run application
app.Run();
