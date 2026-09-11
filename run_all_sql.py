# Reads RUN_ALL_IN_DATABRICKS.sql from the repo root (this Job's Git source)
# and executes it statement-by-statement against the workspace's default
# Spark session, so a push to that one file re-applies schema + seed data.
from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()

sql_file_path = "RUN_ALL_IN_DATABRICKS.sql"  # relative to repo root


def split_sql_statements(sql_text: str) -> list[str]:
    """Splits a multi-statement SQL script on unquoted, uncommented ';'
    characters.

    A naive text.split(';') breaks the moment a semicolon shows up
    ANYWHERE in the file -- and this file has two different cases of
    that: a '--' comment containing plain-English punctuation
    ('...source files are unchanged; this file just saves...'), and a
    single-quoted string literal used as a CASE result
    ('Dispatch field team immediately; notify...'). Stripping comments
    alone fixes the first case but not the second, so this scans
    character-by-character, tracking whether we're inside a
    single-quoted string (handling '' as an escaped quote) and inside a
    '--' line comment, and only splits on ';' when neither is true.
    """
    statements = []
    current = []
    in_string = False
    in_comment = False
    i = 0
    n = len(sql_text)
    while i < n:
        ch = sql_text[i]
        nxt = sql_text[i + 1] if i + 1 < n else ""

        if in_comment:
            if ch == "\n":
                in_comment = False
            i += 1
            continue

        if in_string:
            current.append(ch)
            if ch == "'":
                if nxt == "'":  # escaped '' inside a string -> literal quote, stay in string
                    current.append(nxt)
                    i += 2
                    continue
                in_string = False
            i += 1
            continue

        # not in string, not in comment
        if ch == "-" and nxt == "-":
            in_comment = True
            i += 2
            continue
        if ch == "'":
            in_string = True
            current.append(ch)
            i += 1
            continue
        if ch == ";":
            stmt = "".join(current).strip()
            if stmt:
                statements.append(stmt)
            current = []
            i += 1
            continue

        current.append(ch)
        i += 1

    tail = "".join(current).strip()
    if tail:
        statements.append(tail)
    return statements


with open(sql_file_path, "r") as f:
    sql_script = f.read()

statements = split_sql_statements(sql_script)
print(f"Found {len(statements)} statements to execute.")

for i, stmt in enumerate(statements, 1):
    try:
        spark.sql(stmt)
        print(f"✅ [{i}/{len(statements)}] Executed successfully")
    except Exception as e:
        print(f"❌ [{i}/{len(statements)}] FAILED: {stmt[:100]}...")
        print(f"   Error: {e}")
        raise  # stop immediately on first failure, don't silently continue

print("🎉 All statements executed successfully.")
