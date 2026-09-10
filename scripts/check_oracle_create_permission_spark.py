"""Standalone Spark JDBC check: can this Oracle user actually CREATE TABLE?
Privilege grants can look fine in the data dictionary but still fail at
creation time (e.g. no tablespace quota on an Autonomous DB), so this just
tries the real thing: CREATE a small scratch table, then DROP it again.

Uses Spark's underlying JVM to open a raw JDBC connection, since Spark's
normal read/write DataFrame API has no way to run arbitrary DDL.

Same env vars as check_oracle_data_spark.py:
    export ORACLE_CONN_TYPE=tls        # "direct" or "tls"
    export ORACLE_HOST=...
    export ORACLE_PORT=1521
    export ORACLE_SERVICE=...
    export ORACLE_USER=...
    export ORACLE_PASSWORD=...

Usage:
    spark-submit --jars ojdbc8.jar --driver-class-path ojdbc8.jar check_oracle_create_permission_spark.py
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

TEST_TABLE = "claude_permission_test"

spark = SparkSession.builder.appName("check-oracle-create-permission").getOrCreate()
jvm = spark._sc._jvm

conn = jvm.java.sql.DriverManager.getConnection(JDBC_URL, USERNAME, PASSWORD)
try:
    stmt = conn.createStatement()

    try:
        stmt.execute("DROP TABLE {}".format(TEST_TABLE))  # clean up a leftover from a previous run, if any
    except Exception:
        pass

    try:
        stmt.execute("CREATE TABLE {} (id NUMBER)".format(TEST_TABLE))
        print("CREATE TABLE permission: YES")
    except Exception as exc:
        print("CREATE TABLE permission: NO -- {}".format(exc))
        raise SystemExit(1)

    try:
        stmt.execute("DROP TABLE {}".format(TEST_TABLE))
        print("DROP TABLE permission: YES (cleaned up test table)")
    except Exception as exc:
        print("DROP TABLE permission: NO -- {} (test table {} was left behind, drop it manually)".format(exc, TEST_TABLE))

    stmt.close()
finally:
    conn.close()
    spark.stop()
