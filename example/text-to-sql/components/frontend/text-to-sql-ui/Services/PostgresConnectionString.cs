// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
using Npgsql;

namespace TextToSqlUi.Services;

// Chooses the PostgreSQL connection string. The repository holds no credential:
// the read-only role gets a new password for each deployment, so a connection
// with no source for one fails at startup instead of falling back to a value
// that anyone who reads the repository already knows.
internal static class PostgresConnectionString
{
    internal const string ConnectionVariable = "TEXT2SQL_PG_CONN";
    internal const string PasswordVariable = "TEXT2SQL_PG_PASSWORD";
    internal const string ConfigurationKey = "ConnectionStrings:Postgres";

    // Priority: a complete connection string from the environment, then one from
    // configuration, then the role's password alone for a database on this machine.
    // An empty or blank value counts as unset, because a deployment that exports
    // an empty variable has not chosen a connection. A password that is not blank
    // is used exactly as given.
    internal static string Resolve(string? fromEnvironment, string? fromConfiguration, string? password)
    {
        if (!string.IsNullOrWhiteSpace(fromEnvironment)) return fromEnvironment;
        if (!string.IsNullOrWhiteSpace(fromConfiguration)) return fromConfiguration;
        if (!string.IsNullOrWhiteSpace(password))
        {
            // The builder quotes a password that holds ; = or quote characters. Text
            // concatenation would let such a password add or replace connection keywords.
            return new NpgsqlConnectionStringBuilder
            {
                Host = "localhost",
                Username = "yuruna_agent_ro",
                Password = password,
                Database = "yuruna_demo",
            }.ConnectionString;
        }
        throw new InvalidOperationException(
            $"No PostgreSQL connection is configured. Set {ConnectionVariable} to a complete connection string, " +
            $"or set {ConfigurationKey} (for example with the ConnectionStrings__Postgres environment variable or user secrets), " +
            $"or set {PasswordVariable} to the password of the yuruna_agent_ro role to connect to PostgreSQL on localhost.");
    }
}
