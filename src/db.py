"""Databricks/Delta connection helper — replaces the old oracledb-based
db.py. Every other module still only calls db.fetch_df / db.execute /
db.executemany / db.merge / db.qualify, so this is the one file that had
to change to move the pipeline off Oracle onto Databricks; reverting means
swapping this file's internals back to oracledb, nothing else.

Oracle -> Databricks call-shape mapping:
    fetch_df(sql, params)        Oracle SELECT + pandas.read_sql  -> spark.sql(sql).toPandas()
    execute(sql, params)         Oracle DDL/DML (DELETE/UPDATE)   -> spark.sql(sql) (Delta supports
                                                                     DELETE FROM / UPDATE directly)
    executemany(table, rows)     Oracle cursor.executemany(INSERT) -> DataFrame.write.append()
    merge(table, rows, keys)     PL/SQL MERGE INTO (db/03_packages.sql) -> DeltaTable.merge()
    call_procedure(name, ...)    PL/SQL callproc()                -> direct Python call into
                                                                     src/etl.py / src/scoring.py
"""
from __future__ import annotations

import datetime

import pandas as pd

from . import config

_spark = None


def get_spark():
    """Returns the active SparkSession: the notebook-attached one when
    running as a Databricks notebook/job, otherwise a local session
    (with Delta enabled) for running this code outside Databricks."""
    global _spark
    if _spark is not None:
        return _spark

    try:
        from databricks.sdk.runtime import spark as _dbr_spark  # noqa: F401 (only exists on Databricks)
        _spark = _dbr_spark
    except ImportError:
        from delta import configure_spark_with_delta_pip
        from pyspark.sql import SparkSession

        builder = (
            SparkSession.builder.appName("telecom-qoe")
            .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
            .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
        )
        _spark = configure_spark_with_delta_pip(builder).getOrCreate()

    return _spark


def qualify(table: str) -> str:
    """catalog.schema.table, e.g. qualify('site') -> 'main.telecom_qoe.site'."""
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


def _bind(sql: str, params: dict | None) -> str:
    for key, value in (params or {}).items():
        sql = sql.replace(f":{key}", _sql_literal(value))
    return sql


def fetch_df(sql: str, params: dict | None = None) -> pd.DataFrame:
    """Run a SELECT and return a pandas DataFrame."""
    return get_spark().sql(_bind(sql, params)).toPandas()


def execute(sql: str, params: dict | None = None) -> None:
    """Run a DDL/DML statement (DELETE FROM / UPDATE) with no return
    value — Delta tables support these directly in Spark SQL."""
    get_spark().sql(_bind(sql, params))


def executemany(table: str, rows: list[dict]) -> None:
    """Appends `rows` to a Delta table. Takes the bare table name instead
    of an INSERT SQL string (Delta has no parameterized bulk-insert the
    way oracledb's cursor.executemany(sql, rows) did) — the one call-site
    shape change needed in src/predict_and_score.py."""
    if not rows:
        return
    df = get_spark().createDataFrame(pd.DataFrame(rows))
    df.write.format("delta").mode("append").saveAsTable(qualify(table))


def merge(table: str, rows: list[dict], key_cols: list[str]) -> None:
    """Upserts `rows` into a Delta table on `key_cols` — the Databricks
    equivalent of the PL/SQL MERGE statements in db/03_packages.sql
    (PKG_FEATURE_ENGINEERING.build_call_volume_hourly,
    PKG_QOE_SCORING.score_site_qoe_rule_based)."""
    from delta.tables import DeltaTable

    if not rows:
        return
    spark = get_spark()
    updates_df = spark.createDataFrame(pd.DataFrame(rows))
    target = DeltaTable.forName(spark, qualify(table))
    condition = " AND ".join(f"t.{c} = s.{c}" for c in key_cols)
    (
        target.alias("t")
        .merge(updates_df.alias("s"), condition)
        .whenMatchedUpdateAll()
        .whenNotMatchedInsertAll()
        .execute()
    )


def call_procedure(name: str, params: list | None = None) -> None:
    """Compatibility shim: PL/SQL stored-procedure calls (e.g.
    'pkg_triage.build_triage_queue') are now plain Python functions in
    src/etl.py. Kept only so a stale call site fails loudly instead of
    silently doing nothing."""
    raise NotImplementedError(
        f"'{name}' is now a Python function in src/etl.py — call it directly "
        "instead of db.call_procedure()."
    )
