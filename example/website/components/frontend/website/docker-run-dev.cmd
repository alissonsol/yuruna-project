@REM LICENSEURI https://yuruna.link/license
@REM Copyright (c) 2019-2026 by Alisson Sol et al.
@REM The image holds no certificate: %USERPROFILE%\.aspnet\https is mounted read-only at run time.
@REM Set ASPNETCORE_Kestrel__Certificates__Default__Password to the password given when the
@REM certificate was exported (leave it unset for a file exported without one). It reaches the
@REM container by name, so it is never written in this file or echoed.
@REM When the variable is unset, the first line of aspnetapp.pfx.password beside the PFX (the
@REM file the guest provisioning scripts write) is used instead. SETLOCAL keeps that value out
@REM of the console that runs this file.
@setlocal
@if not defined ASPNETCORE_Kestrel__Certificates__Default__Password if exist "%USERPROFILE%\.aspnet\https\aspnetapp.pfx.password" set /p ASPNETCORE_Kestrel__Certificates__Default__Password=<"%USERPROFILE%\.aspnet\https\aspnetapp.pfx.password"
docker build --rm -f Dockerfile -t yrn42website-prefix/website:latest .
docker run --rm -it -p 8000:80 -p 8001:443 --name "yrn42website-prefix-example-website" -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 -e ASPNETCORE_Kestrel__Certificates__Default__Password -e ASPNETCORE_Kestrel__Certificates__Default__Path=/https/aspnetapp.pfx -v "%USERPROFILE%\.aspnet\https:/https:ro" yrn42website-prefix/website:latest
