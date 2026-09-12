# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

# --- REGION: https://yuruna.link/42e220c4-0009
# REGISTRY is the registry prefix for the base images (must end in `/`).
# The yuruna flows pass the project's local distribution registry
# (localhost:5000/), seeded beforehand by the workload test scripts and
# seed-base-images.ps1, so FROM resolves over loopback with no remote
# registry on the path. The default stays mcr.microsoft.com/ so a bare
# `docker build` outside those flows still works.
# --- REGION: Base image registry
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
RUN dotnet build "text-to-sql-ui.csproj" -c Release -o /app/build

# --- REGION: Publish application
FROM build AS publish
RUN dotnet publish "text-to-sql-ui.csproj" -c Release -o /app/publish

# --- REGION: Final image
FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
COPY --from=build /src/aspnetapp.pfx .
ENTRYPOINT ["dotnet", "text-to-sql-ui.dll"]
