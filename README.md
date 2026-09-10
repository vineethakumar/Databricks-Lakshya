# Call Failure & Customer Experience Prediction

Predicts call volume, call failures, and service-impacting events, and maps
those predictions onto customer-perceived quality of experience (QoE).

## Architecture

```
Oracle DB (vw_site_hourly_features / vw_qoe_training_data views)
              │  scripts/oracle_db.py (python-oracledb)
              ▼
   backend/app.py (FastAPI)
     - trains CallEventLSTM + QoERegressor on startup (src/models/*)
     - POST /api/predict/qoe        -> QoE score + band
     - POST /api/predict/forecast   -> call volume / drop-rate / failure-prob forecast
     - GET  /api/sites, /api/sites/{id}/history
     - every prediction is written to predictions.db (SQLite, src/predictions_store.py)
              │  fetch()
              ▼
   frontend/ (React + Vite UI)
```

## Models

- **Call-event LSTM** (`src/models/call_event_lstm.py`): 24h lookback →
  6h-ahead forecast of call volume, drop rate, and failure probability per
  site. Multi-head Keras model (one shared LSTM trunk, three output heads).
- **QoE regression** (`src/models/qoe_regression.py`): gradient-boosted
  regressor mapping KPIs + subscriber segment to a composite 0-100 QoE score.

Both are trained from scratch, in memory, each time the backend starts —
there is no separate training step or saved model artifact.

## Running it

### 1. Configure the Oracle connection

```bash
cp .env.example .env
```

Set `DB_USER` / `DB_PASSWORD` / `DB_DSN` to point at an Oracle DB whose
`vw_site_hourly_features` and `vw_qoe_training_data` views are already
populated. `SQLITE_DB_PATH` controls where predictions get stored
(defaults to `predictions.db` in the project root).

### 2. Start the backend

```bash
python -m venv venv
venv\Scripts\activate              # Windows
pip install -r requirements.txt
uvicorn backend.app:app --reload --port 8000
```

On startup it connects to Oracle, pulls the two feature views, trains both
models, and initializes `predictions.db`.

### 3. Start the frontend

```bash
cd frontend
npm install
npm run dev
```

Open the printed local URL. The **QoE Score** tab calls
`POST /api/predict/qoe`; the **Call-Event Forecast** tab calls
`POST /api/predict/forecast`. Every call is also recorded into
`predictions.db` (`qoe_predictions` / `forecast_predictions` tables).

## Project layout

```
backend/app.py                 FastAPI app: Oracle fetch, train, predict, store
src/
  config.py                    env-based config (DB_*, SQLITE_DB_PATH, bands/thresholds)
  predictions_store.py         SQLite persistence for prediction results
  features.py                  sliding-window feature engineering for the LSTM
  models/
    call_event_lstm.py         LSTM forecast model
    qoe_regression.py          KPI -> QoE regression model
scripts/oracle_db.py           Oracle connection + SELECT -> DataFrame helper
frontend/                      React + Vite UI
```
