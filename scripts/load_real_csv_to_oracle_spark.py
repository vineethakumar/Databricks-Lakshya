"""Same JDBC write pattern as create_and_load_oracle_repo_data.py, but
reads YOUR real CSVs instead of generating synthetic rows. Copy this to
the VM (same folder as create_and_load_oracle_repo_data.py / ojdbc8.jar),
put your two real CSV files next to it, and run it the same way.

Your CSVs must already have these column headers (rename first if not):
    site_hourly_features CSV: site_id, hour_ts, total_calls, dropped_calls,
        failed_calls, blocked_calls, success_rate, latency_ms, jitter_ms,
        packet_drop_rate, call_drop_rate, rrc_setup_success_rate,
        throughput_mbps, alarm_count, critical_alarm_count
    qoe_training_data CSV: site_id, latency_ms, jitter_ms, packet_drop_rate,
        call_drop_rate, rrc_setup_success_rate, throughput_mbps, segment,
        nps_score, csat_score

Same env vars as create_and_load_oracle_repo_data.py:
    export ORACLE_CONN_TYPE=tls        # "direct" or "tls"
    export ORACLE_HOST=...
    export ORACLE_PORT=1521
    export ORACLE_SERVICE=...
    export ORACLE_USER=...
    export ORACLE_PASSWORD=...

Usage:
    spark-submit --jars ojdbc8.jar --driver-class-path ojdbc8.jar \
        load_real_csv_to_oracle_spark.py \
        /path/to/site_hourly_features.csv /path/to/qoe_training_data.csv
"""
import os
import sys

from pyspark.sql import SparkSession
from pyspark.sql.functions import to_timestamp

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

if len(sys.argv) != 3:
    print(__doc__)
    raise SystemExit(1)

hourly_csv_path, qoe_csv_path = sys.argv[1], sys.argv[2]

spark = SparkSession.builder.appName("load-real-csv-to-oracle").getOrCreate()

raw_df = spark.read.csv(hourly_csv_path, header=True, inferSchema=True)
raw_df = raw_df.withColumn("hour_ts", to_timestamp("hour_ts"))

qoe_df = spark.read.csv(qoe_csv_path, header=True, inferSchema=True)

TABLES = [
    (raw_df, "site_hourly_features", "vw_site_hourly_features"),
    (qoe_df, "qoe_training_data", "vw_qoe_training_data"),
]

for df, table, _view in TABLES:
    print("Loading {} rows into {} ...".format(df.count(), table))
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
    for _df, table, view in TABLES:
        stmt.execute("CREATE OR REPLACE VIEW {} AS SELECT * FROM {}".format(view, table))
        print("created view {}".format(view))
    stmt.close()
finally:
    conn.close()

spark.stop()
