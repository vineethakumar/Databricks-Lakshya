"""API for the React UI (frontend/): reads training data from Databricks
(src/db.py), trains the models (src/models/*, src/features.py)
once at startup, serves predictions over HTTP, and stores every prediction
in a local SQLite database (src/predictions_store.py) for later lookup.

Usage:
    pip install -r requirements.txt
    # .env must have DATABRICKS_SERVER_HOSTNAME/DATABRICKS_HTTP_PATH/
    # DATABRICKS_TOKEN/DATABRICKS_CATALOG/DATABRICKS_SCHEMA pointing at a
    # Databricks workspace with vw_site_hourly_features / vw_qoe_training_data
    # views populated (see db/ for the schema + seed data)
    uvicorn backend.app:app --reload --port 8000
"""
import sys
from pathlib import Path

import pandas as pd
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import config, db, predictions_store
from src.features import build_latest_windows, build_windowed_dataset
from src.models.call_event_lstm import CallEventLSTM
from src.models.qoe_regression import QoERegressor

LOOKBACK_HOURS = config.LSTM_LOOKBACK_HOURS
HORIZON_HOURS = config.LSTM_HORIZON_HOURS

app = FastAPI(title="Call Failure & QoE Prediction API")
app.add_middleware(
    CORSMiddleware,
    # Vite's dev server picks the next free port (5173, 5174, ...) if the
    # default is already taken, and this may be viewed via localhost or a
    # remote host's IP (e.g. a VM's external IP), so match any http origin
    # rather than one hardcoded host/port.
    allow_origin_regex=r"http://[\w.\-]+:\d+",
    allow_methods=["*"],
    allow_headers=["*"],
)

_state: dict = {}


def load_data_from_databricks() -> tuple[pd.DataFrame, pd.DataFrame]:
    raw_df = db.fetch_df(f"SELECT * FROM {db.qualify('vw_site_hourly_features')}")
    raw_df["hour_ts"] = pd.to_datetime(raw_df["hour_ts"])
    raw_df = raw_df.sort_values(["site_id", "hour_ts"]).reset_index(drop=True)
    qoe_df = db.fetch_df(f"SELECT * FROM {db.qualify('vw_qoe_training_data')}")
    return raw_df, qoe_df


@app.on_event("startup")
def load_and_train() -> None:
    predictions_store.init_db()
    raw_df, qoe_df = load_data_from_databricks()
    dataset = build_windowed_dataset(raw_df, lookback_hours=LOOKBACK_HOURS, horizon_hours=HORIZON_HOURS)
    lstm = CallEventLSTM.train(dataset.X, dataset.y, dataset.scaler, lookback_hours=LOOKBACK_HOURS, epochs=15)
    qoe_model = QoERegressor.train(qoe_df)
    _state["raw_df"] = raw_df
    _state["lstm"] = lstm
    _state["qoe_model"] = qoe_model
    print(f"Trained on {len(raw_df)} site-hours across {raw_df['site_id'].nunique()} sites (from Databricks).")


class QoeRequest(BaseModel):
    latency_ms: float
    jitter_ms: float
    packet_drop_rate: float
    call_drop_rate: float
    rrc_setup_success_rate: float
    throughput_mbps: float
    segment: str


class QoeResponse(BaseModel):
    score: float
    band: str


@app.post("/api/predict/qoe", response_model=QoeResponse)
def predict_qoe(req: QoeRequest) -> QoeResponse:
    row = pd.DataFrame([req.model_dump()])
    score = float(_state["qoe_model"].predict(row)[0])
    result = QoeResponse(score=score, band=config.qoe_band(score))
    predictions_store.save_qoe_prediction(req.model_dump(), result.model_dump())
    return result


@app.get("/api/sites")
def list_sites() -> list[str]:
    return sorted(str(s) for s in _state["raw_df"]["site_id"].unique().tolist())


@app.get("/api/sites/{site_id}/history")
def site_history(site_id: str) -> list[dict]:
    site_hist = (
        _state["raw_df"][_state["raw_df"]["site_id"] == site_id]
        .sort_values("hour_ts")
        .tail(LOOKBACK_HOURS)
    )
    out = site_hist.copy()
    out["hour_ts"] = out["hour_ts"].astype(str)
    return out.to_dict(orient="records")


class ForecastRequest(BaseModel):
    site_id: str
    history: list[dict]  # LOOKBACK_HOURS rows, same shape as GET .../history returns


class ForecastResponse(BaseModel):
    predicted_call_volume: float
    predicted_drop_rate: float
    predicted_failure_prob: float
    risk_level: str


@app.post("/api/predict/forecast", response_model=ForecastResponse)
def predict_forecast(req: ForecastRequest) -> ForecastResponse:
    window_df = pd.DataFrame(req.history)
    window_df["hour_ts"] = pd.to_datetime(window_df["hour_ts"])
    window_df["site_id"] = req.site_id  # keep the grouping key stable even if a cell was edited

    latest = build_latest_windows(window_df, LOOKBACK_HOURS, _state["lstm"].scaler)
    call_volume, drop_rate, failure_prob = _state["lstm"].predict(latest.X)[0]

    result = ForecastResponse(
        predicted_call_volume=max(0.0, float(call_volume)),
        predicted_drop_rate=float(drop_rate),
        predicted_failure_prob=float(failure_prob),
        risk_level=config.risk_level(float(failure_prob)),
    )
    predictions_store.save_forecast_prediction(req.site_id, result.model_dump())
    return result


# Serves the built React UI (frontend/dist/, built via `npm run build`) from
# this same app/origin. Mounted last, after every /api/... route above, so
# static-file lookups never shadow the API — FastAPI matches routes in
# registration order and falls through to StaticFiles only when no earlier
# route matched. html=True serves index.html for unmatched paths too, so
# client-side routing (if the UI adds any) keeps working on refresh.
app.mount("/", StaticFiles(directory="frontend/dist", html=True), name="static")
