@REM LICENSEURI https://yuruna.link/license
@REM Copyright (c) 2019-2026 by Alisson Sol et al.
@REM GUID: 4228a313-5733-4b6e-b2b7-b533f2abb707
@REM --- REGION: Prepare build
@echo off
setlocal
pushd "%~dp0"
if errorlevel 1 exit /b 1
if not defined ASPNETCORE_Kestrel__Certificates__Default__Password if exist "%USERPROFILE%\.aspnet\https\aspnetapp.pfx.password" set /p ASPNETCORE_Kestrel__Certificates__Default__Password=<"%USERPROFILE%\.aspnet\https\aspnetapp.pfx.password"
@REM --- REGION: Build application
call docker build --rm -f Dockerfile -t yrn42website-prefix/website:latest .
if not "%ERRORLEVEL%"=="0" goto :finish
@REM --- REGION: Run application
@REM Mount the certificate read-only and pass its password by variable name.
@REM See https://yuruna.link/42f64340-0004
call docker run --rm -it -p 8000:80 -p 8001:443 --name "yrn42website-prefix-example-website" -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 -e ASPNETCORE_Kestrel__Certificates__Default__Password -e ASPNETCORE_Kestrel__Certificates__Default__Path=/https/aspnetapp.pfx -v "%USERPROFILE%\.aspnet\https:/https:ro" yrn42website-prefix/website:latest
:finish
set "dockerExit=%ERRORLEVEL%"
popd
endlocal & exit /b %dockerExit%
