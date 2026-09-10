"""One-time/idempotent loader: reads data/mock/*.csv (generating them there
once if missing, via scripts.mock_data.load_or_generate) and loads them into
Oracle tables, then creates the same thin views scripts/mock_db.py creates
over SQLite (vw_site_hourly_features / vw_qoe_training_data /
vw_site_subscriber_value), so scripts/demo_from_oracle.py can query Oracle
with the exact same SQL scripts/demo_from_sql.py runs against SQLite.

Usage:
    python -m scripts.load_csv_to_oracle
"""
import sys
from pathlib import Path

import numpy as np
import oracledb
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.mock_data import load_or_generate
from src import config

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "mock"

# (table name, view name) pairs, in load order.
TABLES = [
    ("site_hourly_features", "vw_site_hourly_features"),
    ("qoe_training_data", "vw_qoe_training_data"),
    ("site_meta", "vw_site_subscriber_value"),
]


def _oracle_type(dtype: np.dtype) -> str:
    if pd.api.types.is_datetime64_any_dtype(dtype):
        return "TIMESTAMP"
    if pd.api.types.is_bool_dtype(dtype):
        return "NUMBER(1)"
    if pd.api.types.is_integer_dtype(dtype):
        return "NUMBER(38)"
    if pd.api.types.is_float_dtype(dtype):
        return "NUMBER"
    return "VARCHAR2(200)"


def _table_exists(cursor, table: str) -> bool:
    cursor.execute("SELECT COUNT(*) FROM user_tables WHERE table_name = :name", name=table.upper())
    return cursor.fetchone()[0] > 0


def _create_table(cursor, table: str, df: pd.DataFrame) -> None:
    if _table_exists(cursor, table):
        return
    columns = ", ".join(f'"{col}" {_oracle_type(df[col].dtype)}' for col in df.columns)
    cursor.execute(f"CREATE TABLE {table} ({columns})")


def _load_rows(cursor, table: str, df: pd.DataFrame) -> None:
    cursor.execute(f"TRUNCATE TABLE {table}")
    columns = list(df.columns)
    placeholders = ", ".join(f":{i + 1}" for i in range(len(columns)))
    insert_sql = f'INSERT INTO {table} ({", ".join(columns)}) VALUES ({placeholders})'
    rows = [tuple(row) for row in df.where(pd.notnull(df), None).itertuples(index=False, name=None)]
    cursor.executemany(insert_sql, rows)


def main() -> None:
    raw_df, qoe_df, site_meta_df = load_or_generate(DATA_DIR)
    frames = {"site_hourly_features": raw_df, "qoe_training_data": qoe_df, "site_meta": site_meta_df}

    conn = oracledb.connect(user=config.DB_USER, password=config.DB_PASSWORD, dsn=config.DB_DSN)
    try:
        cursor = conn.cursor()
        for table, _view in TABLES:
            df = frames[table]
            _create_table(cursor, table, df)
            _load_rows(cursor, table, df)
            print(f"  loaded {len(df)} rows into {table}")

        for table, view in TABLES:
            cursor.execute(f"CREATE OR REPLACE VIEW {view} AS SELECT * FROM {table}")
            print(f"  created view {view}")

        conn.commit()
    finally:
        conn.close()


if __name__ == "__main__":
    main()
