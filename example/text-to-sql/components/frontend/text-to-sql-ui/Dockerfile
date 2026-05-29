#See https://aka.ms/containerfastmode to understand how Visual Studio uses this Dockerfile to build your images for faster debugging.

# REGISTRY swaps the upstream registry prefix for a local pull-through
# mirror in CI. Default is mcr.microsoft.com/ so a bare `docker build` on
# a developer laptop still works direct. The test workload overrides this
# with --build-arg REGISTRY=<cache>:5000/ so a transient MCR TLS handshake
# blip no longer fails the whole cycle.
ARG REGISTRY=mcr.microsoft.com/

FROM ${REGISTRY}dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 80
EXPOSE 443

FROM ${REGISTRY}dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["text-to-sql-ui.csproj", "."]
RUN dotnet restore "./text-to-sql-ui.csproj"
COPY . .
WORKDIR "/src/."
RUN dotnet build "text-to-sql-ui.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "text-to-sql-ui.csproj" -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
COPY --from=build /src/aspnetapp.pfx . 
ENTRYPOINT ["dotnet", "text-to-sql-ui.dll"]