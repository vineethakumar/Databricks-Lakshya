"""Pulls training/inference data from the Delta feature views defined in
databricks/02_views.sql (ported from db/02_views.sql). Only change from
the Oracle version: table/view names are qualified via db.qualify() for
the catalog.schema namespace — the query shape and pandas post-processing
are identical."""
import pandas as pd

from . import db


def load_site_hourly_features(site_id: int | None = None) -> pd.DataFrame:
    """Feature source for the call-event LSTM: one row per site per hour.

    Maps to VW_SITE_HOURLY_FEATURES (databricks/02_views.sql), which joins
    call_volume_hourly + network_kpi + alarm/event counts.
    """
    sql = f"SELECT * FROM {db.qualify('vw_site_hourly_features')}"
    params = {}
    if site_id is not None:
        sql += " WHERE site_id = :site_id"
        params["site_id"] = site_id
    sql += " ORDER BY site_id, hour_ts"

    df = db.fetch_df(sql, params)
    df.columns = [c.lower() for c in df.columns]
    df["hour_ts"] = pd.to_datetime(df["hour_ts"])
    return df


def load_qoe_training_data() -> pd.DataFrame:
    """Feature source for the QoE regression model: KPI reading -> nearest
    NPS/CSAT survey. Maps to VW_QOE_TRAINING_DATA (databricks/02_views.sql).
    """
    df = db.fetch_df(f"SELECT * FROM {db.qualify('vw_qoe_training_data')} ORDER BY site_id, kpi_ts")
    df.columns = [c.lower() for c in df.columns]
    df["kpi_ts"] = pd.to_datetime(df["kpi_ts"])
    return df


def load_sites() -> pd.DataFrame:
    df = db.fetch_df(f"SELECT site_id, site_name, region, capacity_erlangs FROM {db.qualify('site')}")
    df.columns = [c.lower() for c in df.columns]
    return df
