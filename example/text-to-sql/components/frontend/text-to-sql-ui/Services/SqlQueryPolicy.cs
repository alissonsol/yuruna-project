// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

using System.Globalization;

namespace TextToSqlUi.Services;

// This is a conservative generated-query check, not a PostgreSQL parser or an
// authorization boundary. Column grants on the agent role protect the data even
// when a SQL expression represents a column indirectly.
public sealed class SqlQueryPolicy
{
    public int MaxRows { get; }

    public SqlQueryPolicy(int maxRows)
    {
        if (maxRows <= 0) throw new ArgumentOutOfRangeException(nameof(maxRows));
        MaxRows = maxRows;
    }

    public static bool IsPiiColumn(string name) =>
        name.Equals("email", StringComparison.OrdinalIgnoreCase)
        || name.Equals("phone", StringComparison.OrdinalIgnoreCase)
        || name.EndsWith("_pii", StringComparison.OrdinalIgnoreCase);

    public StaticCheckResult Check(string sql)
    {
        if (string.IsNullOrWhiteSpace(sql)) return StaticCheckResult.Fail("Empty SQL.");
        var text = sql.Trim();
        var tokens = Tokenize(text);
        if (tokens is null) return StaticCheckResult.Fail("Unterminated SQL token, unbalanced parentheses, or comments are not allowed.");
        if (tokens.Count > 0 && tokens[^1].Kind == TokenKind.Symbol && tokens[^1].Text == ";")
        {
            text = text[..tokens[^1].Start].TrimEnd();
            tokens.RemoveAt(tokens.Count - 1);
        }
        if (tokens.Count == 0) return StaticCheckResult.Fail("Empty SQL.");
        if (tokens.Any(t => t.Text == ";" && t.Kind == TokenKind.Symbol))
            return StaticCheckResult.Fail("Multiple statements are not allowed.");
        if (!tokens[0].IsWord("SELECT") && !tokens[0].IsWord("WITH"))
            return StaticCheckResult.Fail("Only SELECT / WITH are allowed (read-only agent).");

        foreach (var token in tokens)
        {
            if (token.Kind == TokenKind.Word && WriteKeywords.Contains(token.Text))
                return StaticCheckResult.Fail("Write statements are not permitted (read-only agent).");
            if (token.IsIdentifier && IsPiiColumn(token.Text))
                return StaticCheckResult.Fail($"Query references a PII column ('{token.Text}'); selecting PII is not permitted.");
        }

        for (var i = 0; i < tokens.Count; i++)
        {
            if (tokens[i].Text != "*" || tokens[i].Kind != TokenKind.Symbol) continue;
            var isCount = i >= 2 && tokens[i - 1].Text == "(" && tokens[i - 2].IsWord("COUNT")
                && i + 1 < tokens.Count && tokens[i + 1].Text == ")";
            if (isCount) continue;
            // Multiplication has an operand on both sides. A qualified star or
            // a star leading a projection/list is an expansion, not arithmetic.
            if (i == 0 || i + 1 == tokens.Count || !EndsOperand(tokens[i - 1]) || !StartsOperand(tokens[i + 1]))
                return StaticCheckResult.Fail("Wildcard projections are not permitted; select explicit non-PII columns.");
        }

        if (HasWholeRowReference(tokens))
            return StaticCheckResult.Fail("Whole-row references are not permitted; select explicit non-PII columns.");

        // Tokenization excludes literals and quoted identifiers from keyword
        // detection, including parentheses inside those tokens. Keep ORDER BY
        // at its authored level and retain a smaller existing limit.
        var limitIndex = tokens.FindIndex(t => t.Depth == 0 && t.IsWord("LIMIT"));
        if (limitIndex >= 0)
        {
            var start = limitIndex + 1;
            var end = start;
            while (end < tokens.Count && !(tokens[end].Depth == 0 &&
                   (tokens[end].IsWord("OFFSET") || tokens[end].IsWord("FOR")))) end++;
            if (start == end) return StaticCheckResult.Fail("LIMIT requires a row count.");
            var expressionStart = tokens[start].Start;
            var expressionEnd = end == tokens.Count ? text.Length : tokens[end].Start;
            var expression = text[expressionStart..expressionEnd].TrimEnd();
            var cap = MaxRows.ToString(CultureInfo.InvariantCulture);
            string bounded;
            if (end == start + 1 && tokens[start].IsWord("ALL")) bounded = cap;
            else if (end == start + 1 && tokens[start].Kind == TokenKind.Number &&
                     long.TryParse(expression, NumberStyles.None, CultureInfo.InvariantCulture, out var count))
                bounded = Math.Min(count, MaxRows).ToString(CultureInfo.InvariantCulture);
            else bounded = $"LEAST(({expression}), {cap})";
            return StaticCheckResult.Ok(text[..expressionStart] + bounded + (end < tokens.Count ? " " + text[expressionEnd..] : ""));
        }
        // FETCH has its own row-count grammar. Leave it intact; the executor's
        // independent cap also bounds FETCH WITH TIES and expression limits.
        if (tokens.Any(t => t.Depth == 0 && t.IsWord("FETCH"))) return StaticCheckResult.Ok(text);
        return StaticCheckResult.Ok(text + "\nLIMIT " + MaxRows.ToString(CultureInfo.InvariantCulture));
    }

    private static readonly HashSet<string> WriteKeywords = new(StringComparer.OrdinalIgnoreCase)
    {
        "INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "TRUNCATE", "GRANT", "REVOKE",
        "CREATE", "COPY", "CALL", "EXECUTE", "VACUUM", "REINDEX", "CLUSTER", "LOCK",
        "REFRESH", "SECURITY", "SET", "RESET", "BEGIN", "COMMIT", "ROLLBACK", "MERGE", "INTO"
    };

    private static bool EndsOperand(Token t) => t.Kind is TokenKind.Number or TokenKind.Literal or TokenKind.QuotedIdentifier
        || t.Text is ")" or "]" || t.Kind == TokenKind.Word && !ClauseWords.Contains(t.Text);
    private static bool StartsOperand(Token t) => t.Text == "(" || EndsOperand(t);

    private static readonly HashSet<string> ClauseWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "SELECT", "DISTINCT", "ALL", "FROM", "JOIN", "WHERE", "GROUP", "ORDER", "HAVING",
        "LIMIT", "OFFSET", "FETCH", "FOR", "UNION", "EXCEPT", "INTERSECT", "ON", "USING",
        "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS", "WINDOW", "AS", "WITH"
    };

    private static bool HasWholeRowReference(List<Token> tokens)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var declarations = new HashSet<int>();
        var fromDepths = new HashSet<int>();
        for (var i = 0; i < tokens.Count - 1; i++)
        {
            fromDepths.RemoveWhere(depth => depth > tokens[i].Depth);
            if (tokens[i].Kind == TokenKind.Word && FromEndWords.Contains(tokens[i].Text))
                fromDepths.Remove(tokens[i].Depth);
            var isFrom = tokens[i].IsWord("FROM");
            if (isFrom) fromDepths.Add(tokens[i].Depth);
            if (!isFrom && !tokens[i].IsWord("JOIN") &&
                !(tokens[i].Text == "," && fromDepths.Contains(tokens[i].Depth))) continue;
            var j = i + 1;
            if (tokens[j].IsWord("LATERAL") || tokens[j].IsWord("ONLY")) j++;
            if (j >= tokens.Count) continue;
            if (tokens[j].Text == "(")
            {
                var depth = tokens[j].Depth;
                while (++j < tokens.Count && !(tokens[j].Text == ")" && tokens[j].Depth == depth)) { }
                j++;
            }
            else
            {
                if (!tokens[j].IsIdentifier) continue;
                declarations.Add(j);
                while (j + 2 < tokens.Count && tokens[j + 1].Text == "." && tokens[j + 2].IsIdentifier)
                {
                    j += 2;
                    declarations.Add(j);
                }
                names.Add(tokens[j].Text);
                j++;
                if (j < tokens.Count && tokens[j].Text == "(") continue; // table-valued function
            }
            if (j < tokens.Count && tokens[j].IsWord("AS")) j++;
            if (j < tokens.Count && tokens[j].IsIdentifier && !ClauseWords.Contains(tokens[j].Text))
            {
                names.Add(tokens[j].Text);
                declarations.Add(j);
            }
        }
        for (var i = 0; i < tokens.Count; i++)
        {
            if (!tokens[i].IsIdentifier || !names.Contains(tokens[i].Text) || declarations.Contains(i)) continue;
            if (i + 1 < tokens.Count && (tokens[i + 1].Text == "." || tokens[i + 1].Text == "(")) continue;
            if (i > 0 && (tokens[i - 1].Text == "." || tokens[i - 1].IsWord("AS"))) continue;
            if (i > 0 && i + 1 < tokens.Count && tokens[i + 1].IsWord("AS") &&
                (tokens[i - 1].IsWord("WITH") || tokens[i - 1].IsWord("RECURSIVE") || tokens[i - 1].Text == ",")) continue;
            return true;
        }
        return false;
    }

    private static readonly HashSet<string> FromEndWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "SELECT", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH", "FOR",
        "UNION", "EXCEPT", "INTERSECT", "WINDOW", "RETURNING"
    };

    private enum TokenKind { Word, QuotedIdentifier, Literal, Number, Symbol }
    private sealed record Token(string Text, int Start, int Depth, TokenKind Kind)
    {
        public bool IsWord(string word) => Kind == TokenKind.Word && Text.Equals(word, StringComparison.OrdinalIgnoreCase);
        public bool IsIdentifier => Kind is TokenKind.Word or TokenKind.QuotedIdentifier;
    }

    private static List<Token>? Tokenize(string sql)
    {
        var tokens = new List<Token>();
        var depth = 0;
        for (var i = 0; i < sql.Length;)
        {
            if (char.IsWhiteSpace(sql[i])) { i++; continue; }
            var start = i;
            var c = sql[i];
            if (c == '\0' || i + 1 < sql.Length && (sql[i..(i + 2)] is "--" or "/*" or "*/")) return null;
            var escaped = (c is 'e' or 'E') && i + 1 < sql.Length && sql[i + 1] == '\'';
            if (escaped) { i++; c = '\''; }
            if (c is '\'' or '"')
            {
                var value = new System.Text.StringBuilder();
                i++;
                var closed = false;
                while (i < sql.Length)
                {
                    if (escaped && sql[i] == '\\') { i += 2; continue; }
                    if (sql[i] == c)
                    {
                        if (i + 1 < sql.Length && sql[i + 1] == c) { value.Append(c); i += 2; continue; }
                        i++; closed = true; break;
                    }
                    value.Append(sql[i++]);
                }
                if (!closed) return null;
                tokens.Add(new Token(value.ToString(), start, depth, c == '"' ? TokenKind.QuotedIdentifier : TokenKind.Literal));
                continue;
            }
            if (c == '$')
            {
                var tagEnd = i + 1;
                while (tagEnd < sql.Length && (char.IsLetterOrDigit(sql[tagEnd]) || sql[tagEnd] == '_')) tagEnd++;
                if (tagEnd < sql.Length && sql[tagEnd] == '$')
                {
                    var tag = sql[i..(tagEnd + 1)];
                    var end = sql.IndexOf(tag, tagEnd + 1, StringComparison.Ordinal);
                    if (end < 0) return null;
                    tokens.Add(new Token(sql[(tagEnd + 1)..end], i, depth, TokenKind.Literal));
                    i = end + tag.Length;
                    continue;
                }
            }
            if (char.IsLetter(c) || c == '_')
            {
                while (++i < sql.Length && (char.IsLetterOrDigit(sql[i]) || sql[i] is '_' or '$')) { }
                tokens.Add(new Token(sql[start..i], start, depth, TokenKind.Word));
                continue;
            }
            if (char.IsDigit(c))
            {
                while (++i < sql.Length && char.IsDigit(sql[i])) { }
                tokens.Add(new Token(sql[start..i], start, depth, TokenKind.Number));
                continue;
            }
            if (c == ')') { if (--depth < 0) return null; }
            tokens.Add(new Token(c.ToString(), i++, depth, TokenKind.Symbol));
            if (c == '(') depth++;
        }
        return depth == 0 ? tokens : null;
    }
}

public sealed record StaticCheckResult(bool Allowed, string? Reason, string? SafeSql)
{
    public static StaticCheckResult Ok(string safe) => new(true, null, safe);
    public static StaticCheckResult Fail(string why) => new(false, why, null);
}
