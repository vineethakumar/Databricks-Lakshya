"""Thin Oracle equivalent of scripts/mock_db.py: connects to an Oracle DB
that has already been populated by scripts/load_csv_to_oracle.py and exposes
the same fetch_df(conn, sql) shape, so scripts/demo_from_oracle.py can fetch
its input with real SQL SELECTs against real Oracle tables/views instead of
the in-memory SQLite mock."""
import oracledb
import pandas as pd

from src import config


def build_db() -> oracledb.Connection:
    """Opens a connection to the Oracle DB configured via
    DB_USER/DB_PASSWORD/DB_DSN (src/config.py). Does not create or load any
    tables/views — run scripts/load_csv_to_oracle.py once beforehand."""
    return oracledb.connect(user=config.DB_USER, password=config.DB_PASSWORD, dsn=config.DB_DSN)


def fetch_df(conn: oracledb.Connection, sql: str) -> pd.DataFrame:
    """Run a SELECT against the connection from build_db() and return a
    DataFrame — the same fetch_df(conn, sql) shape as scripts/mock_db.py."""
    return pd.read_sql(sql, conn)
