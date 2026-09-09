"""Standalone connectivity check for a real Databricks SQL Warehouse — run
this to confirm your credentials/network path actually work BEFORE trying
the full pipeline. Uses databricks-sql-connector directly (a lightweight
SQL client), not src/db.py's Spark session — src/db.py's local fallback
only ever spins up an offline Spark+Delta session when it's not running
inside an actual Databricks notebook/job, so it never touches your real
workspace and can't tell you whether a connection would even work.

Setup:
    pip install databricks-sql-connector   # already added to requirements.txt

    Set these in your .env (see .env.example) or the environment:
        DATABRICKS_SERVER_HOSTNAME   e.g. adb-1234567890123456.7.azuredatabricks.net
                                      or   dbc-abcd1234-5678.cloud.databricks.com
        DATABRICKS_HTTP_PATH         e.g. /sql/1.0/warehouses/abcdef1234567890
        DATABRICKS_TOKEN             a personal access token (or any bearer
                                      token accepted by your workspace)

    Find the first two under your SQL Warehouse's "Connection details" tab
    in the Databricks UI. Generate a token under
    User Settings -> Developer -> Access tokens.

Usage:
    python scripts/test_databricks_connection.py
"""
import os
import sys

from dotenv import load_dotenv

load_dotenv()

REQUIRED_VARS = ("DATABRICKS_SERVER_HOSTNAME", "DATABRICKS_HTTP_PATH", "DATABRICKS_TOKEN")


def main() -> None:
    missing = [name for name in REQUIRED_VARS if not os.getenv(name)]
    if missing:
        print(f"Missing environment variable(s): {', '.join(missing)}")
        print("Set them in .env (see .env.example) or your shell environment, then re-run.")
        sys.exit(1)

    try:
        from databricks import sql
    except ImportError:
        print("databricks-sql-connector is not installed. Run: pip install databricks-sql-connector")
        sys.exit(1)

    server_hostname = os.environ["DATABRICKS_SERVER_HOSTNAME"]
    http_path = os.environ["DATABRICKS_HTTP_PATH"]
    print(f"Connecting to {server_hostname}{http_path} ...")

    try:
        with sql.connect(
            server_hostname=server_hostname,
            http_path=http_path,
            access_token=os.environ["DATABRICKS_TOKEN"],
        ) as conn:
            with conn.cursor() as cursor:
                cursor.execute("SELECT 1 AS ok, current_catalog() AS catalog, current_schema() AS schema_")
                row = cursor.fetchone()
    except Exception as exc:
        print(f"Connection FAILED: {type(exc).__name__}: {exc}")
        sys.exit(1)

    print(f"Connection OK — result={row.ok}, current catalog={row.catalog}, current schema={row.schema_}")
    print("Warehouse is reachable and query execution works.")


if __name__ == "__main__":
    main()
