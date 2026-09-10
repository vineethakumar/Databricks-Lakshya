"""Quick standalone check: does data already exist in the Oracle DB?
Prints row counts + a few sample rows for the 3 tables
scripts/load_csv_to_oracle.py loads, and the 3 views over them. Tables/views
that don't exist yet are reported as MISSING instead of raising.

Usage:
    python -m scripts.check_oracle_data
"""
import sys
from pathlib import Path

import oracledb
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import config

TABLES = ["site_hourly_features", "qoe_training_data", "site_meta"]
VIEWS = ["vw_site_hourly_features", "vw_qoe_training_data", "vw_site_subscriber_value"]


def _exists(cursor, name: str, kind: str) -> bool:
    dict_view = "user_tables" if kind == "table" else "user_views"
    name_col = "table_name" if kind == "table" else "view_name"
    cursor.execute(f"SELECT COUNT(*) FROM {dict_view} WHERE {name_col} = :name", name=name.upper())
    return cursor.fetchone()[0] > 0


def _report(conn, name: str, kind: str) -> None:
    cursor = conn.cursor()
    if not _exists(cursor, name, kind):
        print(f"  {name:<26} MISSING ({kind} does not exist)")
        return

    cursor.execute(f"SELECT COUNT(*) FROM {name}")
    count = cursor.fetchone()[0]
    print(f"  {name:<26} {count} rows")
    if count > 0:
        sample = pd.read_sql(f"SELECT * FROM {name} FETCH FIRST 3 ROWS ONLY", conn)
        print(sample.to_string(index=False))
    print()


def main() -> None:
    print(f"Connecting to {config.DB_DSN} as {config.DB_USER} ...")
    conn = oracledb.connect(user=config.DB_USER, password=config.DB_PASSWORD, dsn=config.DB_DSN)
    try:
        print("\nTables:")
        for table in TABLES:
            _report(conn, table, "table")

        print("Views:")
        for view in VIEWS:
            _report(conn, view, "view")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
