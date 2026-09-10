"""Connects to Oracle and fetches SELECTs as DataFrames — used by
backend/app.py to read vw_site_hourly_features / vw_qoe_training_data."""
import oracledb
import pandas as pd

from src import config

# The CSV loaders (Spark's default JDBC writer especially) can create string
# columns as CLOB instead of VARCHAR2. Without this, oracledb returns those
# as opaque LOB objects (need .read(), unsortable/uncomparable) instead of
# plain str -- this makes every column fetch as a normal Python value.
oracledb.defaults.fetch_lobs = False


def build_db() -> oracledb.Connection:
    """Opens a connection to the Oracle DB configured via
    DB_USER/DB_PASSWORD/DB_DSN (src/config.py)."""
    return oracledb.connect(user=config.DB_USER, password=config.DB_PASSWORD, dsn=config.DB_DSN)


def fetch_df(conn: oracledb.Connection, sql: str) -> pd.DataFrame:
    """Run a SELECT against the connection from build_db() and return a DataFrame."""
    return pd.read_sql(sql, conn)
