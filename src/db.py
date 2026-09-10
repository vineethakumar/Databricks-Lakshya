"""Databricks connection helper — replaces the old oracledb-based db.py.
Every other module still only calls db.fetch_df / db.execute /
db.executemany / db.merge / db.qualify, so this is the one file that had
to change to move the pipeline off Oracle onto Databricks; reverting means
swapping this file's internals back to oracledb, nothing else.

Connects via databricks-sql-connector (a lightweight SQL client) using
DATABRICKS_SERVER_HOSTNAME / DATABRICKS_HTTP_PATH / DATABRICKS_TOKEN from
src/config.py. This works both when running locally (outside Databricks)
and inside a Databricks notebook/job/App — it always talks to the real
workspace over the SQL Warehouse, so behavior is identical in both places.

Oracle -> Databricks call-shape mapping:
    fetch_df(sql, params)        Oracle SELECT + pandas.read_sql  -> cursor.execute + fetchall
    execute(sql, params)         Oracle DDL/DML (DELETE/UPDATE)   -> cursor.execute (Delta supports
                                                                     DELETE FROM / UPDATE directly)
    executemany(table, rows)     Oracle cursor.executemany(INSERT) -> multi-row INSERT INTO ... VALUES
    merge(table, rows, keys)     PL/SQL MERGE INTO (db/03_packages.sql) -> MERGE INTO ... USING VALUES
    call_procedure(name, ...)    PL/SQL callproc()                -> direct Python call into
                                                                     src/etl.py / src/scoring.py
"""
from __future__ import annotations

import datetime

import pandas as pd
from databricks import sql

from . import config

_connection = None


def get_connection():
    """Returns a lazily-created databricks-sql-connector connection, reused
    across calls for the lifetime of the process."""
    global _connection
    if _connection is not None:
        return _connection

    missing = [
        name
        for name, value in (
            ("DATABRICKS_SERVER_HOSTNAME", config.DATABRICKS_SERVER_HOSTNAME),
            ("DATABRICKS_HTTP_PATH", config.DATABRICKS_HTTP_PATH),
            ("DATABRICKS_TOKEN", config.DATABRICKS_TOKEN),
        )
        if not value
    ]
    if missing:
        raise RuntimeError(
            f"Missing Databricks connection setting(s): {', '.join(missing)}. "
            "Set them in .env (see .env.example) or the environment."
        )

    _connection = sql.connect(
        server_hostname=config.DATABRICKS_SERVER_HOSTNAME,
        http_path=config.DATABRICKS_HTTP_PATH,
        access_token=config.DATABRICKS_TOKEN,
    )
    return _connection


def qualify(table: str) -> str:
    """catalog.schema.table, e.g. qualify('site') -> 'telecom_qoe_catalog.telecom_qoe.site'."""
    return f"{config.DATABRICKS_CATALOG}.{config.DATABRICKS_SCHEMA}.{table}"


def _sql_literal(value) -> str:
    """Renders a Python value as a Spark SQL literal, for the same
    ':name' bind-style substitution the old Oracle call sites used.
    Internal pipeline values only (timestamps/numbers/strings computed by
    this codebase, never raw user input), so string substitution here is
    safe the same way the Oracle bind params were."""
    if value is None:
        return "NULL"
    if isinstance(value, (datetime.datetime, datetime.date, pd.Timestamp)):
        return f"TIMESTAMP'{pd.Timestamp(value):%Y-%m-%d %H:%M:%S}'"
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    return str(value)


def _bind(sql_text: str, params: dict | None) -> str:
    for key, value in (params or {}).items():
        sql_text = sql_text.replace(f":{key}", _sql_literal(value))
    return sql_text


def fetch_df(sql_text: str, params: dict | None = None) -> pd.DataFrame:
    """Run a SELECT and return a pandas DataFrame."""
    conn = get_connection()
    with conn.cursor() as cursor:
        cursor.execute(_bind(sql_text, params))
        rows = cursor.fetchall()
        columns = [col[0] for col in cursor.description]
    return pd.DataFrame(rows, columns=columns)


def execute(sql_text: str, params: dict | None = None) -> None:
    """Run a DDL/DML statement (DELETE FROM / UPDATE) with no return
    value — Delta tables support these directly."""
    conn = get_connection()
    with conn.cursor() as cursor:
        cursor.execute(_bind(sql_text, params))


def executemany(table: str, rows: list[dict]) -> None:
    """Appends `rows` to a Delta table via a multi-row INSERT."""
    if not rows:
        return
    cols = list(rows[0].keys())
    col_list = ", ".join(cols)
    values_list = ", ".join(
        "(" + ", ".join(_sql_literal(row.get(c)) for c in cols) + ")" for row in rows
    )
    execute(f"INSERT INTO {qualify(table)} ({col_list}) VALUES {values_list}")


def merge(table: str, rows: list[dict], key_cols: list[str]) -> None:
    """Upserts `rows` into a Delta table on `key_cols` — the Databricks
    equivalent of the PL/SQL MERGE statements in db/03_packages.sql
    (PKG_FEATURE_ENGINEERING.build_call_volume_hourly,
    PKG_QOE_SCORING.score_site_qoe_rule_based)."""
    if not rows:
        return
    cols = list(rows[0].keys())
    condition = " AND ".join(f"t.{c} = s.{c}" for c in key_cols)
    non_key_cols = [c for c in cols if c not in key_cols]
    update_set = ", ".join(f"t.{c} = s.{c}" for c in non_key_cols) or f"t.{key_cols[0]} = s.{key_cols[0]}"
    col_list = ", ".join(cols)
    values_list = ", ".join(
        "(" + ", ".join(_sql_literal(row.get(c)) for c in cols) + ")" for row in rows
    )
    merge_sql = f"""
        MERGE INTO {qualify(table)} AS t
        USING (SELECT * FROM (VALUES {values_list}) AS s({col_list})) AS s
        ON {condition}
        WHEN MATCHED THEN UPDATE SET {update_set}
        WHEN NOT MATCHED THEN INSERT ({col_list}) VALUES ({', '.join(f's.{c}' for c in cols)})
    """
    execute(merge_sql)


def call_procedure(name: str, params: list | None = None) -> None:
    """Compatibility shim: PL/SQL stored-procedure calls (e.g.
    'pkg_triage.build_triage_queue') are now plain Python functions in
    src/etl.py. Kept only so a stale call site fails loudly instead of
    silently doing nothing."""
    raise NotImplementedError(
        f"'{name}' is now a Python function in src/etl.py — call it directly "
        "instead of db.call_procedure()."
    )
