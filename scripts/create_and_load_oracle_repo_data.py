"""Standalone Spark JDBC script: generates this repo's mock dataset (same
shape/columns as data/mock/*.csv -- see scripts/mock_data.py) directly in
Python (stdlib random, no numpy/pandas needed on this machine) and writes it
straight to Oracle -- no CSV transfer required. Creates
site_hourly_features / qoe_training_data / site_meta tables, then the thin
views vw_site_hourly_features / vw_qoe_training_data /
vw_site_subscriber_value over them, same as check_oracle_data_spark.py
checks for.

Same env vars as check_oracle_data_spark.py:
    export ORACLE_CONN_TYPE=tls        # "direct" or "tls"
    export ORACLE_HOST=...
    export ORACLE_PORT=1521
    export ORACLE_SERVICE=...
    export ORACLE_USER=...
    export ORACLE_PASSWORD=...

Usage:
    spark-submit --jars ojdbc8.jar --driver-class-path ojdbc8.jar create_and_load_oracle_repo_data.py
"""
import os
import random
from datetime import datetime, timedelta

from pyspark.sql import SparkSession
from pyspark.sql.types import DoubleType, IntegerType, StringType, StructField, StructType, TimestampType

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

random.seed(7)

# (site_name, capacity_erlangs, high_value_count, subscriber_count, total_arpu, is_bad_site)
SITES = [
    ("SITE-A-DOWNTOWN", 800, 6, 30, 1800.0, False),
    ("SITE-B-SUBURB", 500, 3, 30, 1100.0, False),
    ("SITE-C-INDUSTRIAL", 400, 9, 30, 2200.0, True),
]
N_DAYS = 14
INCIDENT_START_DAY = 12
INCIDENT_DURATION_HOURS = 48
QOE_ROWS_PER_SEGMENT = 112


def make_site_hourly_rows(site_name, capacity, is_bad):
    start = datetime(2026, 8, 1)
    incident_start = start + timedelta(days=INCIDENT_START_DAY)
    incident_end = incident_start + timedelta(hours=INCIDENT_DURATION_HOURS)

    rows = []
    for h in range(N_DAYS * 24):
        hour = start + timedelta(hours=h)
        is_incident = is_bad and incident_start <= hour < incident_end
        busy = 1.5 if 8 <= hour.hour <= 22 else 0.4

        if is_incident:
            latency, jitter = 120 + random.uniform(0, 80), 15 + random.uniform(0, 10)
            pkt_drop, call_drop = 0.04 + random.uniform(0, 0.05), 0.12 + random.uniform(0, 0.15)
            rrc_success, throughput = max(0, 0.75 - random.uniform(0, 0.15)), 20 + random.uniform(0, 15)
            alarm_count, critical_alarm_count = 1, 1
        else:
            latency, jitter = 25 + random.uniform(0, 20), 2 + random.uniform(0, 3)
            pkt_drop, call_drop = 0.001 + random.uniform(0, 0.005), 0.005 + random.uniform(0, 0.01)
            rrc_success, throughput = min(1, 0.97 + random.uniform(0, 0.03)), 80 + random.uniform(0, 60)
            alarm_count, critical_alarm_count = 0, 0

        base_calls = 40 if capacity >= 500 else 20
        total_calls = max(1, round(base_calls * busy * random.uniform(0.7, 1.3)))
        dropped = round(total_calls * call_drop)
        failed = round(total_calls * pkt_drop * 2)
        blocked = round(total_calls * (1 - rrc_success) * 0.3)
        success_rate = max(0.0, 1 - (dropped + failed + blocked) / total_calls)

        rows.append((
            site_name, hour, total_calls, dropped, failed, blocked, success_rate,
            latency, jitter, pkt_drop, call_drop, rrc_success, throughput,
            alarm_count, critical_alarm_count, 0, capacity, "DEMO", "MACRO",
        ))
    return rows


def make_qoe_rows(site_name, is_bad):
    rows = []
    for segment in ("HIGH_VALUE", "MEDIUM_VALUE", "LOW_VALUE"):
        for _ in range(QOE_ROWS_PER_SEGMENT):
            degraded = is_bad and random.uniform(0, 1) < 0.5
            if degraded:
                latency, jitter = 120 + random.uniform(0, 80), 15 + random.uniform(0, 10)
                pkt_drop, call_drop = 0.04 + random.uniform(0, 0.05), 0.12 + random.uniform(0, 0.15)
                rrc_success, throughput = max(0, 0.75 - random.uniform(0, 0.15)), 20 + random.uniform(0, 15)
                nps, csat = random.uniform(-80, -10), random.randint(1, 2)
            else:
                latency, jitter = 25 + random.uniform(0, 20), 2 + random.uniform(0, 3)
                pkt_drop, call_drop = 0.001 + random.uniform(0, 0.005), 0.005 + random.uniform(0, 0.01)
                rrc_success, throughput = min(1, 0.97 + random.uniform(0, 0.03)), 80 + random.uniform(0, 60)
                nps, csat = random.uniform(10, 70), random.randint(3, 5)

            rows.append((
                site_name, latency, jitter, pkt_drop, call_drop, rrc_success, throughput,
                segment, nps, min(csat, 5),
            ))
    return rows


spark = SparkSession.builder.appName("create-and-load-oracle-repo-data").getOrCreate()

RAW_SCHEMA = StructType([
    StructField("site_id", StringType()), StructField("hour_ts", TimestampType()),
    StructField("total_calls", IntegerType()), StructField("dropped_calls", IntegerType()),
    StructField("failed_calls", IntegerType()), StructField("blocked_calls", IntegerType()),
    StructField("success_rate", DoubleType()), StructField("latency_ms", DoubleType()),
    StructField("jitter_ms", DoubleType()), StructField("packet_drop_rate", DoubleType()),
    StructField("call_drop_rate", DoubleType()), StructField("rrc_setup_success_rate", DoubleType()),
    StructField("throughput_mbps", DoubleType()), StructField("alarm_count", IntegerType()),
    StructField("critical_alarm_count", IntegerType()), StructField("event_count", IntegerType()),
    StructField("capacity_erlangs", IntegerType()), StructField("region", StringType()),
    StructField("site_type", StringType()),
])

QOE_SCHEMA = StructType([
    StructField("site_id", StringType()), StructField("latency_ms", DoubleType()),
    StructField("jitter_ms", DoubleType()), StructField("packet_drop_rate", DoubleType()),
    StructField("call_drop_rate", DoubleType()), StructField("rrc_setup_success_rate", DoubleType()),
    StructField("throughput_mbps", DoubleType()), StructField("segment", StringType()),
    StructField("nps_score", DoubleType()), StructField("csat_score", IntegerType()),
])

META_SCHEMA = StructType([
    StructField("site_id", StringType()), StructField("capacity_erlangs", IntegerType()),
    StructField("high_value_count", IntegerType()), StructField("subscriber_count", IntegerType()),
    StructField("total_arpu", DoubleType()), StructField("is_bad_site", IntegerType()),
])

raw_rows, qoe_rows, meta_rows = [], [], []
for site_name, capacity, hv_count, sub_count, arpu, is_bad in SITES:
    raw_rows.extend(make_site_hourly_rows(site_name, capacity, is_bad))
    qoe_rows.extend(make_qoe_rows(site_name, is_bad))
    meta_rows.append((site_name, capacity, hv_count, sub_count, arpu, int(is_bad)))

TABLES = [
    (spark.createDataFrame(raw_rows, schema=RAW_SCHEMA), "site_hourly_features", "vw_site_hourly_features"),
    (spark.createDataFrame(qoe_rows, schema=QOE_SCHEMA), "qoe_training_data", "vw_qoe_training_data"),
    (spark.createDataFrame(meta_rows, schema=META_SCHEMA), "site_meta", "vw_site_subscriber_value"),
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
