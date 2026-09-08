"""Creates (or updates) the two Databricks Jobs that replace Oracle's
DBMS_SCHEDULER jobs from the original db/04_triggers_scheduler.sql:

    job_refresh_call_volume : hourly at :05, was JOB_REFRESH_CALL_VOLUME
    job_rule_based_qoe      : hourly at :10, was JOB_RULE_BASED_QOE

This is the file-based, version-controlled alternative to clicking
"Schedule" by hand in the Databricks SQL Editor (see the manual steps
still documented in 04_triggers_scheduler.sql) — run this script whenever
you want the two jobs created fresh or updated to match the current
03_packages.sql.

Both jobs run a SQL File task against db/03_packages.sql. That file's
SECTION 1 (feature engineering) and SECTION 2 (QoE scoring, including the
churn check folded in right after the MERGE) do the actual work. Running
the *whole* file for each job is deliberate, not an oversight: it also
re-registers the SQL functions (rule_based_qoe, qoe_band, etc.) via
CREATE OR REPLACE FUNCTION every run, and the other sections' scripts are
harmless no-ops on their default (NULL site_id / current_timestamp())
variable values — same reasoning as the YAML version this replaces.

Setup:
    pip install databricks-sdk
    databricks configure --token          # or set DATABRICKS_HOST / DATABRICKS_TOKEN
    export DATABRICKS_SQL_WAREHOUSE_ID=<your-warehouse-id>

Usage:
    python db/create_scheduled_jobs.py

Note: this uses the Databricks SDK's Jobs API (w.jobs.*). Method/field
names shown here match the SDK as of this writing — if your installed
databricks-sdk version has renamed anything, adjust to match its docs.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from databricks.sdk import WorkspaceClient
from databricks.sdk.service import jobs
from databricks.sdk.service.workspace import ImportFormat

SQL_FILE = Path(__file__).parent / "03_packages.sql"
WAREHOUSE_ID = os.environ.get("DATABRICKS_SQL_WAREHOUSE_ID")

JOB_SPECS = [
    {
        "name": "job_refresh_call_volume",
        "task_key": "build_call_volume_hourly",
        "cron": "0 5 * * * ?",   # every hour at :05, same cadence as Oracle's JOB_REFRESH_CALL_VOLUME
        "comment": "Hourly rebuild of call_volume_hourly from raw CDR (LSTM input feed).",
    },
    {
        "name": "job_rule_based_qoe",
        "task_key": "score_site_qoe_rule_based_all_sites",
        "cron": "0 10 * * * ?",  # every hour at :10, same cadence as Oracle's JOB_RULE_BASED_QOE
        "comment": "Hourly rule-based QoE fallback score per site (churn check included).",
    },
]


def upload_sql_file(w: WorkspaceClient) -> str:
    """Pushes the local db/03_packages.sql into the caller's Databricks
    workspace so the SQL File tasks below have something to point at, and
    keeps the workspace copy in sync with this repo every time it runs."""
    me = w.current_user.me().user_name
    target_dir = f"/Workspace/Users/{me}/telecom_qoe_sql"
    workspace_path = f"{target_dir}/03_packages.sql"

    w.workspace.mkdirs(target_dir)
    w.workspace.upload(
        workspace_path,
        SQL_FILE.read_bytes(),
        format=ImportFormat.AUTO,
        overwrite=True,
    )
    print(f"Uploaded {SQL_FILE} -> {workspace_path}")
    return workspace_path


def create_or_update_job(w: WorkspaceClient, spec: dict, sql_path: str) -> None:
    task = jobs.Task(
        task_key=spec["task_key"],
        sql_task=jobs.SqlTask(
            warehouse_id=WAREHOUSE_ID,
            file=jobs.SqlTaskFile(path=sql_path),
        ),
    )
    schedule = jobs.CronSchedule(
        quartz_cron_expression=spec["cron"],
        timezone_id="UTC",
        pause_status=jobs.PauseStatus.UNPAUSED,
    )

    existing = next(iter(w.jobs.list(name=spec["name"])), None)

    if existing:
        w.jobs.reset(
            job_id=existing.job_id,
            new_settings=jobs.JobSettings(
                name=spec["name"],
                tasks=[task],
                schedule=schedule,
            ),
        )
        print(f"Updated existing job '{spec['name']}' (job_id={existing.job_id}), cron={spec['cron']}")
    else:
        created = w.jobs.create(name=spec["name"], tasks=[task], schedule=schedule)
        print(f"Created job '{spec['name']}' (job_id={created.job_id}), cron={spec['cron']}")


def main() -> None:
    if not WAREHOUSE_ID:
        sys.exit("Set DATABRICKS_SQL_WAREHOUSE_ID before running this script.")

    w = WorkspaceClient()
    sql_path = upload_sql_file(w)

    for spec in JOB_SPECS:
        create_or_update_job(w, spec, sql_path)


if __name__ == "__main__":
    main()
