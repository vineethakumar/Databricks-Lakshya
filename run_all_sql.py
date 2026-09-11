# Notebook: run_all_sql
# Always runs the same file: RUN_ALL_IN_DATABRICKS.sql, from whichever
# Git ref the Job task is configured to check out.
from pyspark.sql import SparkSession
spark = SparkSession.builder.getOrCreate()

sql_file_path = "RUN_ALL_IN_DATABRICKS.sql"
# ...rest of the script stays the same

sql_file_path = "RUN_ALL_IN_DATABRICKS.sql"  # relative to repo root

with open(sql_file_path, "r") as f:
    sql_script = f.read()

statements = [s.strip() for s in sql_script.split(";") if s.strip()]
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
