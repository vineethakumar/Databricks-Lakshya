# Reads RUN_ALL_IN_DATABRICKS.sql from the repo root (this Job's Git source)
# and executes it statement-by-statement against the workspace's default
# Spark session, so a push to that one file re-applies schema + seed data.
from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()

sql_file_path = "RUN_ALL_IN_DATABRICKS.sql"  # relative to repo root


def strip_sql_comments(sql_text: str) -> str:
    """Removes '-- ...' line comments before splitting on ';'. Without
    this, a semicolon that appears inside a comment (e.g. this file's own
    header: '...source files are unchanged; this file just saves...')
    gets mistaken for a real statement separator, corrupting the split."""
    lines = []
    for line in sql_text.split("\n"):
        idx = line.find("--")
        if idx != -1:
            line = line[:idx]
        lines.append(line)
    return "\n".join(lines)


with open(sql_file_path, "r") as f:
    sql_script = f.read()

cleaned_script = strip_sql_comments(sql_script)
statements = [s.strip() for s in cleaned_script.split(";") if s.strip()]
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
