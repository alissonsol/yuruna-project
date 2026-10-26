# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42fc5c98-ecbd-4691-9d61-eb9f54bdaa9b

# --- REGION: Base image registry
# Seeded project builds pass a local registry prefix; bare builds use MCR.
# See https://yuruna.link/42e220c4-0010
ARG REGISTRY=mcr.microsoft.com/

# --- REGION: Runtime image
FROM ${REGISTRY}dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 80
EXPOSE 443

# --- REGION: Build application
FROM ${REGISTRY}dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["website.csproj", "."]
RUN dotnet restore "./website.csproj"
COPY . .
WORKDIR "/src/."
RUN dotnet tool install -g Microsoft.Web.LibraryManager.Cli --version 3.0.114
RUN ~/.dotnet/tools/libman restore

# --- REGION: Publish application
FROM build AS publish
# Publish compiles the application; reuse the package graph restored above.
RUN dotnet publish "website.csproj" -c Release --no-restore -o /app/publish

# --- REGION: Final image
# The pod supplies its certificate and password at deployment.
# See https://yuruna.link/42f64340-0004
FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "website.dll"]
