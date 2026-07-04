<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42cc3d4e-5f60-4178-c901-2d3e4f506890
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

Push-Location $PSScriptRoot

.\copy-pfx.ps1

docker build --rm -f Dockerfile -t yrn42website-prefix/website:latest .
docker run --rm -it -p 8000:80 -p 8001:443 --name "yrn42website-prefix-example-website" -e ASPNETCORE_URLS="https://+;http://+" -e ASPNETCORE_HTTPS_PORT=8001 -e ASPNETCORE_Kestrel__Certificates__Default__Password="password" -e ASPNETCORE_Kestrel__Certificates__Default__Path=/app/aspnetapp.pfx yrn42website-prefix/website:latest

Pop-Location
