# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

#See https://aka.ms/containerfastmode to understand how Visual Studio uses this Dockerfile to build your images for faster debugging.

# REGISTRY is the registry prefix for the base images (must end in `/`).
# The yuruna flows pass the project's local distribution registry
# (localhost:5000/), seeded with these images beforehand (workload test
# scripts and the seed-base-images.ps1 pre-processor), so FROM resolves
# over loopback with no remote registry on the path. The default stays
# mcr.microsoft.com/ so a bare `docker build` on a machine without that
# registry still works direct.
ARG REGISTRY=mcr.microsoft.com/

FROM ${REGISTRY}dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 80
EXPOSE 443

FROM ${REGISTRY}dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["website.csproj", "."]
RUN dotnet restore "./website.csproj"
COPY . .
WORKDIR "/src/."
RUN dotnet tool install -g Microsoft.Web.LibraryManager.Cli
RUN ~/.dotnet/tools/libman restore
RUN dotnet build "website.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "website.csproj" -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
COPY --from=build /src/aspnetapp.pfx . 
ENTRYPOINT ["dotnet", "website.dll"]