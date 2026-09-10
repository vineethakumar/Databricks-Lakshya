"""Standalone Spark JDBC check: does data already exist in the Oracle DB?
Same connection pattern as test_oracle_spark_connectivity.py, but instead of
just SELECT 1 FROM DUAL, it reports row counts (+ a few sample rows) for the
tables/views scripts/load_csv_to_oracle.py loads: site_hourly_features,
qoe_training_data, site_meta, and their vw_* views.

Reads connection details from env vars -- fill them in via `export` before
running, never hardcode credentials in this file:

    export ORACLE_CONN_TYPE=tls        # "direct" or "tls"
    export ORACLE_HOST=...
    export ORACLE_PORT=1521
    export ORACLE_SERVICE=...
    export ORACLE_USER=...
    export ORACLE_PASSWORD=...

Usage:
    spark-submit --jars ojdbc8.jar --driver-class-path ojdbc8.jar check_oracle_data_spark.py
"""
import os

from pyspark.sql import SparkSession

CONNECTION_TYPE = os.environ.get("ORACLE_CONN_TYPE", "direct")
HOST = os.environ["ORACLE_HOST"]
PORT = os.environ.get("ORACLE_PORT", "1521")
SERVICE = os.environ["ORACLE_SERVICE"]
USERNAME = os.environ["ORACLE_USER"]
PASSWORD = os.environ["ORACLE_PASSWORD"]

if CONNECTION_TYPE == "tls":
    JDBC_URL = "jdbc:oracle:thin:@tcps://{}:{}/{}?ssl_server_dn_match=yes".format(HOST, PORT, SERVICE)
else:
    JDBC_URL = "jdbc:oracle:thin:@//{}:{}/{}".format(HOST, PORT, SERVICE)

TABLES_AND_VIEWS = [
    "site_hourly_features", "qoe_training_data", "site_meta",
    "vw_site_hourly_features", "vw_qoe_training_data", "vw_site_subscriber_value",
]

spark = SparkSession.builder.appName("check-oracle-data").getOrCreate()


def read_table(name: str):
    return (
        spark.read.format("jdbc")
        .option("url", JDBC_URL)
        .option("driver", "oracle.jdbc.OracleDriver")
        .option("dbtable", name)
        .option("user", USERNAME)
        .option("password", PASSWORD)
        .load()
    )


for name in TABLES_AND_VIEWS:
    print("=" * 78)
    print(name)
    print("=" * 78)
    try:
        df = read_table(name)
        count = df.count()
        print("  {} rows".format(count))
        if count > 0:
            df.show(3, truncate=False)
    except Exception as exc:  # table/view may not exist yet
        print("  MISSING or unreadable: {}".format(exc))

spark.stop()
