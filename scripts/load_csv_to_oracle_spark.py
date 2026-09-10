"""Standalone Spark JDBC loader: reads the 3 mock CSVs (already copied onto
this machine, e.g. via scp) and loads them into Oracle tables
site_hourly_features / qoe_training_data / site_meta, creating each table
from the CSV's inferred schema, then creates the same thin views
check_oracle_data_spark.py checks for: vw_site_hourly_features /
vw_qoe_training_data / vw_site_subscriber_value.

Expects the CSVs in the current directory (same dir as this script), named
exactly as in this repo's data/mock/: site_hourly_features.csv,
qoe_training_data.csv, site_meta.csv.

Same env vars as check_oracle_data_spark.py:
    export ORACLE_CONN_TYPE=tls        # "direct" or "tls"
    export ORACLE_HOST=...
    export ORACLE_PORT=1521
    export ORACLE_SERVICE=...
    export ORACLE_USER=...
    export ORACLE_PASSWORD=...

Usage:
    spark-submit --jars ojdbc8.jar --driver-class-path ojdbc8.jar load_csv_to_oracle_spark.py
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

# (csv filename, oracle table name, view name)
FILES = [
    ("site_hourly_features.csv", "site_hourly_features", "vw_site_hourly_features"),
    ("qoe_training_data.csv", "qoe_training_data", "vw_qoe_training_data"),
    ("site_meta.csv", "site_meta", "vw_site_subscriber_value"),
]

spark = SparkSession.builder.appName("load-csv-to-oracle").getOrCreate()

for csv_name, table, _view in FILES:
    df = spark.read.option("header", "true").option("inferSchema", "true").csv(csv_name)
    print("Loading {} ({} rows) into {} ...".format(csv_name, df.count(), table))
    (
        df.write.format("jdbc")
        .option("url", JDBC_URL)
        .option("driver", "oracle.jdbc.OracleDriver")
        .option("dbtable", table)
        .option("user", USERNAME)
        .option("password", PASSWORD)
        .mode("overwrite")
        .save()
    )
    print("  done")

jvm = spark._sc._jvm
conn = jvm.java.sql.DriverManager.getConnection(JDBC_URL, USERNAME, PASSWORD)
try:
    stmt = conn.createStatement()
    for _csv_name, table, view in FILES:
        stmt.execute("CREATE OR REPLACE VIEW {} AS SELECT * FROM {}".format(view, table))
        print("created view {}".format(view))
    stmt.close()
finally:
    conn.close()

spark.stop()
