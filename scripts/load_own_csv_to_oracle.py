"""Loads any CSV of yours into an Oracle table, then creates a view over
it with the given name -- so you can point your own data at the exact
views backend/app.py reads (vw_site_hourly_features / vw_qoe_training_data)
without needing the synthetic scripts/mock_data.py generator.

Your CSV's columns must already be named to match what's expected:
    vw_site_hourly_features: site_id, hour_ts, total_calls, dropped_calls,
        failed_calls, blocked_calls, success_rate, latency_ms, jitter_ms,
        packet_drop_rate, call_drop_rate, rrc_setup_success_rate,
        throughput_mbps, alarm_count, critical_alarm_count
    vw_qoe_training_data: site_id, latency_ms, jitter_ms, packet_drop_rate,
        call_drop_rate, rrc_setup_success_rate, throughput_mbps, segment,
        nps_score, csat_score
Rename columns in the CSV (or with pandas) first if they don't match.

Usage:
    python -m scripts.load_own_csv_to_oracle <csv_path> <table_name> <view_name> [date_col]

Example:
    python -m scripts.load_own_csv_to_oracle data/my_data/hourly.csv site_hourly_features vw_site_hourly_features hour_ts
    python -m scripts.load_own_csv_to_oracle data/my_data/qoe.csv qoe_training_data vw_qoe_training_data
"""
import sys
from pathlib import Path

import numpy as np
import oracledb
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import config


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
        cursor.execute(f"DROP TABLE {table}")
    columns = ", ".join(f'"{col}" {_oracle_type(df[col].dtype)}' for col in df.columns)
    cursor.execute(f"CREATE TABLE {table} ({columns})")


def _load_rows(cursor, table: str, df: pd.DataFrame) -> None:
    columns = list(df.columns)
    placeholders = ", ".join(f":{i + 1}" for i in range(len(columns)))
    insert_sql = f'INSERT INTO {table} ({", ".join(columns)}) VALUES ({placeholders})'
    rows = [tuple(row) for row in df.where(pd.notnull(df), None).itertuples(index=False, name=None)]
    cursor.executemany(insert_sql, rows)


def main() -> None:
    if len(sys.argv) < 4:
        print(__doc__)
        raise SystemExit(1)

    csv_path, table, view = sys.argv[1], sys.argv[2], sys.argv[3]
    date_col = sys.argv[4] if len(sys.argv) > 4 else None

    df = pd.read_csv(csv_path, parse_dates=[date_col] if date_col else None)
    print(f"Read {len(df)} rows, columns: {list(df.columns)}")

    conn = oracledb.connect(user=config.DB_USER, password=config.DB_PASSWORD, dsn=config.DB_DSN)
    try:
        cursor = conn.cursor()
        _create_table(cursor, table, df)
        _load_rows(cursor, table, df)
        print(f"  loaded {len(df)} rows into {table}")

        cursor.execute(f"CREATE OR REPLACE VIEW {view} AS SELECT * FROM {table}")
        print(f"  created view {view}")

        conn.commit()
    finally:
        conn.close()


if __name__ == "__main__":
    main()
