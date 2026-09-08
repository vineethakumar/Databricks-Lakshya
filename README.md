# Call Failure & Customer Experience Prediction

Predicts call volume, call failures, and service-impacting events before they
happen, and maps those predictions onto customer-perceived quality of
experience (QoE) — so network issues get triaged by real customer impact
instead of raw alarm noise.

## Architecture

```
CDR / alarms / events / KPIs / tickets / CSAT-NPS   (db/01_schema.sql)
              │
              ▼
   PL/SQL ETL: PKG_FEATURE_ENGINEERING               (db/03_packages.sql)
   builds CALL_VOLUME_HOURLY from raw CDR every hour  (db/04_triggers_scheduler.sql)
              │
              ▼
   Feature views: VW_SITE_HOURLY_FEATURES,            (db/02_views.sql)
                  VW_QOE_TRAINING_DATA
              │
     ┌────────┴─────────┐
     ▼                   ▼
 LSTM forecast      Regression QoE model
 (src/models/       (src/models/qoe_regression.py)
  call_event_lstm.py)      │
     │                     │
     ▼                     ▼
 CALL_EVENT_PREDICTION   QOE_SCORE          (src/predict_and_score.py writes both)
     └────────┬──────────┘
              ▼
   PKG_TRIAGE.build_triage_queue             (db/03_packages.sql)
   customer_impact_score (QoE gap × subscriber value)
   + technical_severity_score (predicted failures × alarms)
   = ranked TRIAGE_QUEUE, plus churn-risk flag on high-value
     subscribers behind a sustained QoE dip (TRG_QOE_CHURN_CHECK)
```

The database is not just storage here — `PKG_FEATURE_ENGINEERING`,
`PKG_QOE_SCORING`, and `PKG_TRIAGE` (all in `db/03_packages.sql`) hold real
business logic: the CDR → hourly-aggregate ETL, a rule-based QoE fallback
formula, and the customer-impact-weighted triage ranking + churn-risk
flagging. Python owns the two ML models; PL/SQL owns aggregation, scoring
fallback, and the triage/churn decision logic, and runs on its own schedule
via `DBMS_SCHEDULER` independent of whether the Python jobs have run yet.

## Data model (`db/01_schema.sql`)

| Table | Purpose |
|---|---|
| `site`, `subscriber` | dimensions: cell sites, subscribers (segment, ARPU, home site) |
| `cdr` | raw call detail records (result: SUCCESS/DROPPED/FAILED/BLOCKED) |
| `alarm_log`, `network_event` | alarms and network events per site |
| `network_kpi` | hourly latency/jitter/drop-rate/throughput per site |
| `ticket` | trouble tickets + resolution time |
| `customer_satisfaction` | NPS/CSAT survey results |
| `call_volume_hourly` | derived hourly CDR rollup (LSTM input, built by PL/SQL) |
| `call_event_prediction` | LSTM output: forecast call volume/drop-rate/failure-prob |
| `qoe_score` | regression (or rule-based fallback) QoE score, 0-100 |
| `triage_queue` | final ranked worklist: technical severity × customer impact |

## Models

- **Call-event LSTM** (`src/models/call_event_lstm.py`): 24h lookback →
  6h-ahead forecast of call volume, drop rate, and failure probability per
  site. Multi-head Keras model (one shared LSTM trunk, three output heads).
- **QoE regression** (`src/models/qoe_regression.py`): gradient-boosted
  regressor mapping KPIs + subscriber segment to a composite 0-100 QoE score,
  trained against real NPS/CSAT survey outcomes (`VW_QOE_TRAINING_DATA`).

## Running it

### Don't have Docker / Oracle available? Run the no-DB demo

```bash
pip install -r requirements.txt
python scripts/demo_local_no_db.py
```

`scripts/demo_local_no_db.py` generates a small synthetic dataset in memory
(same story as `db/05_seed_data.sql`: 3 sites, one hits a 2-day incident),
trains the *actual* `CallEventLSTM` and `QoERegressor` classes from
`src/models/` on it, runs inference, and re-ranks the sites using a
pure-Python mirror of `PKG_TRIAGE`'s scoring formulas. It proves the model
code and business logic are correct end to end, but it does **not** exercise
the real PL/SQL (`db/03_packages.sql` only runs inside Oracle) or the
Oracle read/write path in `src/db.py` / `src/predict_and_score.py` — for
that you need the real database, below.

#### Want to see (and edit) the mock data as CSV?

The generator behind the demo above (`scripts/mock_data.py`) can also be
dumped to CSV so you can open it in Excel/a text editor and see exactly what
feeds the KPI/QoE/triage logic, then re-run the pipeline against your edits:

```bash
python scripts/generate_mock_csv.py   # writes data/mock/*.csv
python scripts/demo_from_csv.py       # reads those CSVs, trains, predicts, ranks
```

This writes three input files under `data/mock/`:

| File | Shape | Mirrors |
|---|---|---|
| `site_hourly_features.csv` | one row per site per hour: call volume + KPIs (`latency_ms`, `jitter_ms`, `packet_drop_rate`, `call_drop_rate`, `rrc_setup_success_rate`, `throughput_mbps`) + alarm/event counts | `VW_SITE_HOURLY_FEATURES` (`db/02_views.sql`) — the LSTM's input |
| `qoe_training_data.csv` | KPI reading + subscriber segment -> NPS/CSAT | `VW_QOE_TRAINING_DATA` (`db/02_views.sql`) — the QoE regressor's input |
| `site_meta.csv` | per-site high-value subscriber count / total ARPU | `VW_SITE_SUBSCRIBER_VALUE` (`db/02_views.sql`) — used to weight `customer_impact_score` |

Edit any KPI column by hand (e.g. push `call_drop_rate`/`latency_ms` up for a
site) and re-run `demo_from_csv.py` to see how that change moves the QoE
score, `technical_severity_score`, `customer_impact_score`, and the final
triage rank — using the exact same `src/features.py` windowing and
`src/models/` code as the Oracle-backed pipeline, just fed from CSV instead
of `vw_site_hourly_features` / `vw_qoe_training_data`. It writes its own
output back out to `data/mock/triage_queue_output.csv`.

### 1. Start the database

```bash
cp .env.example .env          # adjust passwords if you want
docker compose up -d
```

This pulls `gvenzl/oracle-free` and automatically runs everything in `db/`
(schema → views → packages → triggers/scheduler → seed data) against the
`telecom_qoe` app schema on first startup. First boot takes a few minutes
(seed data generates ~150-250k synthetic CDR rows across a simulated 3-day
network incident on two sites, so both the LSTM and the QoE regression have
real signal to learn from).

Check readiness:

```bash
docker compose logs -f oracle-db      # wait for "DATABASE IS READY TO USE!"
```

### 2. Install Python dependencies

```bash
python -m venv .venv
.venv\Scripts\activate            # Windows
pip install -r requirements.txt
```

### 3. Train both models and run one inference + triage pass

```bash
python scripts/run_pipeline.py
```

This trains the LSTM and the QoE regressor, saves both under `artifacts/`,
runs inference for the latest hour per site, writes results into
`call_event_prediction` and `qoe_score`, and calls
`PKG_TRIAGE.build_triage_queue` to produce the ranked worklist — printing
the top 10 rows at the end.

### 4. Inspect the triage queue directly

```sql
SELECT site_id, priority_rank, composite_priority_score,
       technical_severity_score, customer_impact_score,
       high_value_subscribers_affected, recommended_action
FROM triage_queue
ORDER BY prediction_ts DESC, priority_rank;
```

### 5. Re-run on an ongoing basis

In production, `04_triggers_scheduler.sql`'s hourly jobs keep
`call_volume_hourly` and a rule-based QoE fallback fresh inside the
database on their own; schedule `scripts/run_pipeline.py` (or split its
three steps) via cron/Airflow/DBMS_SCHEDULER-triggered external job to keep
the ML-based forecasts and triage queue current, e.g. hourly.

## Tests

```bash
pytest
```

`tests/` covers the feature-windowing logic and the QoE composite label —
pure functions that don't need a live database.

## Project layout

```
db/
  01_schema.sql               tables
  02_views.sql                feature views for the ML pipeline
  03_packages.sql             PKG_FEATURE_ENGINEERING / PKG_QOE_SCORING / PKG_TRIAGE
  04_triggers_scheduler.sql   churn-check trigger + hourly DBMS_SCHEDULER jobs
  05_seed_data.sql            synthetic demo dataset (sites, subscribers, 10 days of history)
src/
  config.py                   env-based config, QoE band / risk-level thresholds
  db.py                       oracledb connection helper
  data_loader.py               pulls from the feature views
  features.py                  sliding-window feature engineering for the LSTM
  models/
    call_event_lstm.py         LSTM forecast model
    qoe_regression.py           KPI -> QoE regression model
  train_call_event_model.py     trains + saves the LSTM
  train_qoe_model.py            trains + saves the regressor
  predict_and_score.py          batch inference -> writes predictions -> rebuilds triage queue
tests/
scripts/
  run_pipeline.py              runs the three Oracle-backed steps above end to end
  mock_data.py                  synthetic data generator + pure-Python PKG_TRIAGE mirror
                                 (shared by the two no-DB scripts below)
  demo_local_no_db.py            no-DB demo: generates mock data in memory, trains,
                                 predicts, ranks
  generate_mock_csv.py           writes the mock data to data/mock/*.csv for inspection
  demo_from_csv.py                same pipeline as demo_local_no_db.py, reading its
                                 input from data/mock/*.csv instead of memory
data/mock/                     generated by generate_mock_csv.py (git-ignored input/output CSVs)
docker-compose.yml             Oracle Free container, auto-runs db/ on first start
```
