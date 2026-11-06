#!/usr/bin/env python3
"""Flag SQL migration statements that break a rollback to the previous code.

A Deployment can be rolled back while the database keeps the new schema, so
the previous code must still work against it (expand/contract). This reads
the "up" direction of migration files and reports:

  block  - the previous code would break: DROP TABLE/VIEW/SCHEMA, DROP COLUMN,
           RENAME of a table/view/column/type/enum value, ALTER COLUMN ... TYPE,
           SET NOT NULL, ADD ... CHECK (... IS NOT NULL), ADD COLUMN ...
           NOT NULL / PRIMARY KEY without a non-null DEFAULT, DROP DEFAULT /
           IDENTITY on a column added NOT NULL earlier in the same migration,
           SET SCHEMA, DROP TYPE/DOMAIN ... CASCADE.
  warn   - usually safe, but worth a reviewer's look: DROP INDEX,
           DROP CONSTRAINT, RENAME of an index or constraint (the previous
           code's reads and writes still succeed; the risk is an
           `ON CONFLICT` that names it); DROP FUNCTION/PROCEDURE/SEQUENCE;
           other DROP DEFAULT / DROP IDENTITY (break the previous code's
           INSERTs if the column is NOT NULL, which this check cannot see).

Usage: sql_safety.py [--format plain|github] FILE...
Exit:  0 no blocking finding, 1 at least one, 2 usage/IO error.

Postgres dialect (all Signapse SQL services run Postgres). Comments, string
literals, quoted identifiers and dollar-quoted bodies are masked before
matching, except the body of a DO block (`DO $$ ... $$`, `DO LANGUAGE x $$`,
`DO '...'`), which runs at migration time and so is checked. Dynamic SQL
(`EXECUTE '...'`) is not inspected.
"""

import re
import sys

# An identifier after masking: bare word or quoted ("x" survives masking with
# its content replaced, so it still reads as one token), optionally qualified.
IDENT = r'(?:"[^"]*"|[A-Za-z_][A-Za-z0-9_$]*)(?:\.(?:"[^"]*"|[A-Za-z_][A-Za-z0-9_$]*))*'

# Postgres words that can follow ADD inside ALTER TABLE without naming a
# column (a table constraint). After DROP only CONSTRAINT can, and that case is
# matched first. DROP DEFAULT / NOT NULL / IDENTITY follow ALTER COLUMN.
ADD_NOT_A_COLUMN = {"CONSTRAINT", "PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "EXCLUDE"}


def mask(sql):
    """Return sql with comments, strings and non-DO dollar bodies blanked.

    Length and newlines are preserved so offsets map back to line numbers.
    Quoted identifiers keep their quotes and word characters; anything else
    inside them becomes "_" so "drop column" cannot read as two keywords.
    """
    out = list(sql)
    n = len(sql)
    i = 0
    do_tags = []  # stack of open DO-block dollar tags whose body we scan

    def after_do(k):
        # `DO $$`, `DO LANGUAGE plpgsql $$` (name bare, "quoted" or 'string'),
        # `DO 'body'` all run at migration time.
        return re.search(r"\bDO(?:\s+LANGUAGE\s+(?:\w+|\"[^\"]*\"|'[^']*'))?\s*$", "".join(out[max(0, k - 60):k]), re.I)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = sql[i]
        nxt = sql[i + 1] if i + 1 < n else ""
        if c == "-" and nxt == "-":
            j = sql.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif c == "/" and nxt == "*":
            depth, j = 1, i + 2
            while j < n and depth:
                if sql.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif sql.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == "'":
            # E'...' allows backslash escapes; '' is an escaped quote in both.
            escapes = i > 0 and sql[i - 1] in "eE" and (i < 2 or not re.match(r"\w", sql[i - 2]))
            j = i + 1
            while j < n:
                if escapes and sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            if after_do(i):
                # Single-quoted DO body: check its statements in place. Same
                # length, so offsets still hold ('' inside reads as empty strings).
                out[i + 1:min(j, n)] = mask(sql[i + 1:min(j, n)])
            else:
                blank(i + 1, min(j, n))
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and not (sql[j] == '"' and sql[j + 1:j + 2] != '"'):
                j += 2 if sql[j] == '"' else 1  # "" is an escaped quote
            for k in range(i + 1, j):
                if not re.match(r"[A-Za-z0-9_$]", sql[k]):
                    out[k] = "_"
            i = j + 1
        elif c == "$":
            m = re.match(r"\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$", sql[i:])
            if not m or (i > 0 and re.match(r"[A-Za-z0-9_]", sql[i - 1])):
                i += 1
                continue
            tag = m.group(0)
            if do_tags and do_tags[-1] == tag:
                do_tags.pop()
                blank(i, i + len(tag))
                i += len(tag)
            elif after_do(i):
                do_tags.append(tag)
                blank(i, i + len(tag))
                i += len(tag)
            else:
                j = sql.find(tag, i + len(tag))
                j = n if j < 0 else j + len(tag)
                blank(i, j)
                i = j
        else:
            i += 1
    return "".join(out)


def up_section(sql):
    """For goose files, keep only the `-- +goose Up` section (others blanked)."""
    if not re.search(r"^\s*--\s*\+goose\s+Up\b", sql, re.M | re.I):
        return sql
    out, keep = [], False
    for line in sql.split("\n"):
        if re.match(r"\s*--\s*\+goose\s+Up\b", line, re.I):
            keep = True
        elif re.match(r"\s*--\s*\+goose\s+Down\b", line, re.I):
            keep = False
        # Blank, not drop, so offsets and line numbers match the file.
        out.append(line if keep else " " * len(line))
    return "\n".join(out)


def statements(masked):
    """Yield (offset, text) for each ;-separated statement."""
    start = 0
    for m in re.finditer(r";", masked):
        yield start, masked[start:m.start()]
        start = m.end()
    yield start, masked[start:]


def split_actions(body):
    """Split an ALTER TABLE action list on top-level commas.

    Returns [(offset_in_body, normalised_action)].
    """
    parts, depth, start = [], 0, 0
    for k, ch in enumerate(body + ","):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            chunk = body[start:k]
            if chunk.strip():
                lead = len(chunk) - len(chunk.lstrip())
                parts.append((start + lead, " ".join(chunk.split())))
            start = k + 1
    return parts


def check_exprs(action):
    """Yield the body of each balanced CHECK (...) in one action."""
    for m in re.finditer(r"\bCHECK\s*\(", action, re.I):
        depth = 1
        for k in range(m.end(), len(action)):
            depth += {"(": 1, ")": -1}.get(action[k], 0)
            if depth == 0:
                yield action[m.end():k]
                break


def bare(name):
    return name.replace('"', "")


def check_alter_table(table, actions, notnull):
    """Yield (severity, kind, detail, offset) for each action of one ALTER TABLE.

    notnull collects (table, column) added NOT NULL in this migration, so a
    later DROP DEFAULT on one is known to break the previous code's INSERTs.
    """
    for off, a in actions:
        u = a.upper()
        m = re.match(rf"RENAME\s+CONSTRAINT\s+({IDENT})\s+TO\s+({IDENT})", a, re.I)
        if m:
            yield ("warn", "RENAME CONSTRAINT", f"{table}: {m.group(1)} -> {m.group(2)}", off)
            continue
        m = re.match(rf"RENAME\s+TO\s+({IDENT})", a, re.I)
        if m:
            yield ("block", "RENAME TABLE", f"{table} -> {m.group(1)}", off)
            continue
        m = re.match(rf"RENAME\s+(?:COLUMN\s+)?({IDENT})\s+TO\s+({IDENT})", a, re.I)
        if m:
            yield ("block", "RENAME COLUMN", f"{table}.{m.group(1)} -> {m.group(2)}", off)
            continue
        m = re.match(rf"DROP\s+CONSTRAINT\s+(?:IF\s+EXISTS\s+)?({IDENT})", a, re.I)
        if m:
            yield ("warn", "DROP CONSTRAINT", f"{table}.{m.group(1)}", off)
            continue
        m = re.match(rf"DROP\s+(?:COLUMN\s+)?(?:IF\s+EXISTS\s+)?({IDENT})", a, re.I)
        if m:
            yield ("block", "DROP COLUMN", f"{table}.{m.group(1)}", off)
            continue
        m = re.match(rf"ALTER\s+(?:COLUMN\s+)?({IDENT})\s+(?:SET\s+DATA\s+)?TYPE\b", a, re.I)
        if m:
            yield ("block", "ALTER COLUMN TYPE", f"{table}.{m.group(1)}", off)
            continue
        m = re.match(rf"ALTER\s+(?:COLUMN\s+)?({IDENT})\s+SET\s+NOT\s+NULL\b", a, re.I)
        if m:
            yield ("block", "SET NOT NULL", f"{table}.{m.group(1)}", off)
            continue
        m = re.match(rf"ADD\s+(?:COLUMN\s+)?(?:IF\s+NOT\s+EXISTS\s+)?({IDENT})", a, re.I)
        # Ignore parenthesised parts, e.g. CHECK (x IS NOT NULL).
        top = u
        while re.search(r"\([^()]*\)", top):
            top = re.sub(r"\([^()]*\)", " ", top)
        if (m and m.group(1).upper() not in ADD_NOT_A_COLUMN
                and re.search(r"\b(NOT\s+NULL|PRIMARY\s+KEY)\b", top)
                and not re.search(r"\bDEFAULT\s+(?!NULL\b)|\b(GENERATED|(?:SMALL|BIG)?SERIAL)\b", top)):
            yield ("block", "ADD COLUMN NOT NULL", f"{table}.{m.group(1)} (no non-null DEFAULT)", off)
            continue
        if m and m.group(1).upper() not in ADD_NOT_A_COLUMN and re.search(r"\bNOT\s+NULL\b", top):
            notnull.add((table.lower(), bare(m.group(1)).lower()))
        m = re.match(rf"ALTER\s+(?:COLUMN\s+)?({IDENT})\s+DROP\s+(DEFAULT|IDENTITY)\b", a, re.I)
        if m:
            sev = "block" if (table.lower(), bare(m.group(1)).lower()) in notnull else "warn"
            yield (sev, f"DROP {m.group(2).upper()}", f"{table}.{m.group(1)}", off)
            continue
        if re.match(r"ADD\b", a, re.I) and any(re.search(r"\bIS\s+NOT\s+NULL\b", e, re.I) for e in check_exprs(a)):
            yield ("block", "CHECK NOT NULL", table, off)
            continue
        if re.match(r"SET\s+SCHEMA\b", a, re.I):
            yield ("block", "SET SCHEMA", table, off)


REASONS = {
    "DROP TABLE": "the previous code still reads and writes this table",
    "DROP VIEW": "the previous code may still query this view",
    "DROP SCHEMA": "the previous code may still use objects in this schema",
    "DROP COLUMN": "the previous code still selects or inserts this column",
    "RENAME TABLE": "the previous code still uses the old name",
    "RENAME COLUMN": "the previous code still uses the old column name",
    "RENAME TYPE": "the previous code still uses the old type name or enum value",
    "DROP TYPE ATTRIBUTE": "the previous code may still use this attribute",
    "ALTER COLUMN TYPE": "the previous code may not read or write the new type (and the table is rewritten under lock)",
    "SET NOT NULL": "the previous code may insert rows without this column",
    "ADD COLUMN NOT NULL": "the previous code's INSERTs do not set this column and fail without a non-null DEFAULT",
    "SET SCHEMA": "the previous code still uses the old schema-qualified name",
    "DROP TYPE CASCADE": "CASCADE also drops every column of this type, which the previous code still uses",
    "DROP ROUTINE": "the previous code may still call this function, procedure or sequence",
    "DROP INDEX": "safe for reads and writes, but breaks an ON CONFLICT that relies on it",
    "DROP CONSTRAINT": "safe for reads and writes, but breaks an ON CONFLICT ON CONSTRAINT that names it",
    "RENAME CONSTRAINT": "breaks an ON CONFLICT ON CONSTRAINT that names it",
    "RENAME INDEX": "breaks an ON CONFLICT ON CONSTRAINT that names it",
    "CHECK NOT NULL": "rejects the previous code's INSERTs that leave the column out, like SET NOT NULL (NOT VALID only skips existing rows)",
    "DROP DEFAULT": "the previous code's INSERTs that leave this column out fail if it is NOT NULL",
    "DROP IDENTITY": "the previous code's INSERTs that leave this column out fail if it is NOT NULL",
}


# Statement-level rules other than ALTER TABLE: (severity, kind, pattern, detail).
# Patterns search (not anchor) because statements inside a DO block arrive
# prefixed with BEGIN / IF ... THEN.
RULES = [
    ("block", "DROP VIEW", rf"\bDROP\s+(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+EXISTS\s+)?({IDENT})", "{0}"),
    ("block", "DROP SCHEMA", rf"\bDROP\s+SCHEMA\s+(?:IF\s+EXISTS\s+)?({IDENT})", "{0}"),
    ("warn", "DROP INDEX", rf"\bDROP\s+INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+EXISTS\s+)?({IDENT})", "{0}"),
    ("block", "RENAME COLUMN", rf"\bALTER\s+(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+EXISTS\s+)?({IDENT})\s+RENAME\s+(?:COLUMN\s+)?({IDENT})\s+TO\s+({IDENT})", "{0}.{1} -> {2} (view)"),
    ("block", "RENAME TABLE", rf"\bALTER\s+(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+EXISTS\s+)?({IDENT})\s+RENAME\s+TO\s+({IDENT})", "{0} -> {1} (view)"),
    ("warn", "RENAME INDEX", rf"\bALTER\s+INDEX\s+(?:IF\s+EXISTS\s+)?({IDENT})\s+RENAME\s+TO\s+({IDENT})", "{0} -> {1}"),
    ("block", "RENAME TYPE", rf"\bALTER\s+TYPE\s+({IDENT})\s+(RENAME\s+(?:TO|VALUE|ATTRIBUTE)\b[^;]*)", "{0}: {1}"),
    ("block", "DROP TYPE ATTRIBUTE", rf"\bALTER\s+TYPE\s+({IDENT})\s+DROP\s+ATTRIBUTE\s+(?:IF\s+EXISTS\s+)?({IDENT})", "{0}.{1}"),
    ("block", "SET SCHEMA", rf"\bALTER\s+(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+EXISTS\s+)?({IDENT})\s+SET\s+SCHEMA\s+({IDENT})", "{0} -> schema {1} (view)"),
    ("block", "DROP TYPE CASCADE", rf"\bDROP\s+(?:TYPE|DOMAIN)\s+(?:IF\s+EXISTS\s+)?({IDENT}(?:\s*,\s*{IDENT})*)\s+CASCADE\b", "{0}"),
    ("warn", "DROP ROUTINE", rf"\bDROP\s+(?:FUNCTION|PROCEDURE|SEQUENCE)\s+(?:IF\s+EXISTS\s+)?({IDENT})", "{0}"),
    ("block", "RENAME TABLE", rf"\bALTER\s+SCHEMA\s+({IDENT})\s+RENAME\s+TO\s+({IDENT})", "schema {0} -> {1}"),
]
CREATE_TABLE = rf"\bCREATE\s+(?:(?:GLOBAL|LOCAL)\s+)?(?:(?:TEMP|TEMPORARY|UNLOGGED)\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?({IDENT})"
ALTER_TABLE = rf"\bALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?({IDENT})\s*\*?\s+"
DROP_TABLE = rf"\bDROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?({IDENT}(?:\s*,\s*{IDENT})*)"


def analyse(sql):
    """Return [(severity, kind, detail, offset)] for one migration's text.

    Changes to a table created (plain CREATE TABLE, not IF NOT EXISTS) earlier
    in the same migration are ignored: the previous code cannot depend on it.
    """
    text = up_section(sql)
    masked = mask(text)
    findings = []
    created = set()
    notnull = set()
    for off, stmt in statements(masked):
        for m in re.finditer(CREATE_TABLE, stmt, re.I):
            # IF NOT EXISTS may be a no-op on a table the previous code uses.
            if not re.search(r"\bIF\s+NOT\s+EXISTS\b", m.group(0), re.I):
                created.add(bare(m.group(1)).lower())

        m = re.search(ALTER_TABLE, stmt, re.I)
        if m:
            table = bare(m.group(1))
            if table.lower() not in created:
                base = off + m.end()
                for sev, kind, detail, aoff in check_alter_table(table, split_actions(stmt[m.end():]), notnull):
                    findings.append((sev, kind, bare(detail), base + aoff))
            continue

        m = re.search(DROP_TABLE, stmt, re.I)
        if m:
            for t in re.split(r"\s*,\s*", m.group(1)):
                if bare(t).lower() not in created:
                    findings.append(("block", "DROP TABLE", bare(t), off + m.start()))
            continue

        for sev, kind, pattern, detail in RULES:
            m = re.search(pattern, stmt, re.I)
            if m:
                # Groups come from the unmasked text so enum values read properly.
                groups = (" ".join(text[off + a:off + b].split()) for a, b in (m.span(g) for g in range(1, len(m.groups()) + 1)))
                findings.append((sev, kind, bare(detail.format(*groups)), off + m.start()))
                break
    return findings


def main(argv):
    fmt = "plain"
    args = argv[1:]
    if args[:1] == ["--format"]:
        fmt, args = args[1], args[2:]
    if not args or fmt not in ("plain", "github"):
        print("usage: sql_safety.py [--format plain|github] FILE...", file=sys.stderr)
        return 2
    blocked = 0
    for path in args:
        try:
            with open(path, encoding="utf-8") as fh:
                sql = fh.read()
        except (OSError, UnicodeDecodeError) as e:
            print(f"{path}: {e}", file=sys.stderr)
            return 2
        for sev, kind, detail, off in analyse(sql):
            line = sql.count("\n", 0, off) + 1
            msg = f"{kind} {detail}: {REASONS[kind]}"
            if sev == "block":
                blocked += 1
            if fmt == "github":
                level = "error" if sev == "block" else "warning"
                title = "Destructive migration" if sev == "block" else "Migration needs a look"
                print(f"::{level} file={path},line={line},title={title}::{msg}")
            print(f"{path}:{line}: {'BLOCK' if sev == 'block' else 'warn'}: {msg}")
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
