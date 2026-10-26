# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42b99b34-ae97-4394-afb0-f1eda3e127c2

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
COPY ["text-to-sql-ui.csproj", "."]
RUN dotnet restore "./text-to-sql-ui.csproj"
COPY . .
WORKDIR "/src/."

# --- REGION: Publish application
FROM build AS publish
# Publish compiles the application; reuse the package graph restored above.
RUN dotnet publish "text-to-sql-ui.csproj" -c Release --no-restore -o /app/publish

# --- REGION: Final image
# The pod supplies its certificate and password at deployment.
# See https://yuruna.link/42f64340-0004
FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "text-to-sql-ui.dll"]
