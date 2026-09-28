// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

using System.Data.Common;

namespace TextToSqlUi.Services;

public static class SqlResultReader
{
    public static async Task<List<object?[]>> ReadRowsAsync(DbDataReader reader, int maxRows, CancellationToken ct = default)
    {
        if (maxRows <= 0) throw new ArgumentOutOfRangeException(nameof(maxRows));
        var rows = new List<object?[]>();
        // Check the cap before advancing, so no extra row is consumed and the
        // database's ordering and any smaller SQL limit are preserved.
        while (rows.Count < maxRows && await reader.ReadAsync(ct))
        {
            var row = new object?[reader.FieldCount];
            for (var i = 0; i < reader.FieldCount; i++)
                row[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }
        return rows;
    }
}
