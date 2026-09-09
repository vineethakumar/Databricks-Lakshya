-- ============================================================================
-- Use Case 1: Call Failure & Customer Experience Prediction
-- 01_schema.sql — core dimension + fact tables (Databricks SQL / Delta Lake,
-- Unity Catalog)
--
-- Run order: 01_schema.sql -> 02_views.sql -> 03_packages.sql -> 05_seed_data.sql
--
-- Converted from Oracle. See CONVERSION_GUIDE.md for the full type/construct
-- mapping table used across all 5 files. Quick recap of what changed here:
--   * VARCHAR2(n)/CHAR(n)      -> STRING          (Databricks does not enforce length)
--   * NUMBER(p)   p<=9         -> INT
--   * NUMBER(p)   p>=10        -> BIGINT
--   * NUMBER(p,s)              -> DECIMAL(p,s)
--   * GENERATED ALWAYS AS IDENTITY -> unchanged, Delta supports this natively
--   * SYSTIMESTAMP             -> current_timestamp()
--   * inline CHECK (...)       -> moved to ALTER TABLE ADD CONSTRAINT right
--                                 below each CREATE TABLE (Databricks does not
--                                 support inline CHECK in the column list)
--   * PRIMARY KEY / FOREIGN KEY -> kept inline; Unity Catalog constraints are
--                                 informational only (NOT ENFORCED) unless
--                                 noted otherwise
--   * UNIQUE constraint        -> Databricks has no UNIQUE constraint type;
--                                 noted in a comment where Oracle had one
--   * CREATE INDEX             -> replaced with CLUSTER BY (liquid clustering),
--                                 the closest Databricks equivalent
-- ============================================================================

-- Set these once per session before running the rest of the scripts:
-- USE CATALOG <your_catalog>;
-- USE SCHEMA  <your_schema>;

-- ---------------------------------------------------------------------------
-- Make this script re-runnable: drop any existing objects first. Children
-- are dropped before parents so Unity Catalog's FK dependency tracking
-- doesn't block dropping a referenced table.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS triage_queue;
DROP TABLE IF EXISTS qoe_score;
DROP TABLE IF EXISTS call_event_prediction;
DROP TABLE IF EXISTS call_volume_hourly;
DROP TABLE IF EXISTS customer_satisfaction;
DROP TABLE IF EXISTS ticket;
DROP TABLE IF EXISTS network_kpi;
DROP TABLE IF EXISTS network_event;
DROP TABLE IF EXISTS alarm_log;
DROP TABLE IF EXISTS cdr;
DROP TABLE IF EXISTS subscriber;
DROP TABLE IF EXISTS site;

-- ---------------------------------------------------------------------------
-- DIMENSION: SITE  (cell site / node inventory)
-- ---------------------------------------------------------------------------
CREATE TABLE site (
    site_id          BIGINT       GENERATED ALWAYS AS IDENTITY,
    site_name        STRING       NOT NULL,
    region           STRING       NOT NULL,
    latitude         DECIMAL(9,6),
    longitude        DECIMAL(9,6),
    site_type        STRING       DEFAULT 'MACRO',
    capacity_erlangs DECIMAL(10,2) NOT NULL,
    created_ts       TIMESTAMP    DEFAULT current_timestamp() NOT NULL,
    CONSTRAINT pk_site PRIMARY KEY (site_id)
)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE site ADD CONSTRAINT ck_site_type CHECK (site_type IN ('MACRO','SMALL_CELL','INDOOR'));

-- ---------------------------------------------------------------------------
-- DIMENSION: SUBSCRIBER
-- ---------------------------------------------------------------------------
CREATE TABLE subscriber (
    subscriber_id    BIGINT       GENERATED ALWAYS AS IDENTITY,
    msisdn           STRING       NOT NULL,
    segment          STRING       NOT NULL,
    plan_type        STRING,
    tenure_months    INT          DEFAULT 0,
    monthly_arpu     DECIMAL(10,2) DEFAULT 0,      -- used to weight customer impact
    churn_flag       STRING       DEFAULT 'N',
    churn_flagged_ts TIMESTAMP,
    home_site_id     BIGINT       NOT NULL,
    created_ts       TIMESTAMP    DEFAULT current_timestamp() NOT NULL,
    CONSTRAINT pk_subscriber PRIMARY KEY (subscriber_id),
    CONSTRAINT fk_subscriber_site FOREIGN KEY (home_site_id) REFERENCES site(site_id)
)
CLUSTER BY (home_site_id)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_subscriber_site

ALTER TABLE subscriber ADD CONSTRAINT ck_subscriber_segment CHECK (segment IN ('HIGH_VALUE','MEDIUM_VALUE','LOW_VALUE'));
ALTER TABLE subscriber ADD CONSTRAINT ck_subscriber_churn_flag CHECK (churn_flag IN ('Y','N'));

-- ---------------------------------------------------------------------------
-- FACT: CDR (Call Detail Records)
-- ---------------------------------------------------------------------------
CREATE TABLE cdr (
    cdr_id                 BIGINT   GENERATED ALWAYS AS IDENTITY,
    call_id                STRING   NOT NULL,
    subscriber_id          BIGINT   NOT NULL,
    site_id                BIGINT   NOT NULL,
    call_start_ts          TIMESTAMP NOT NULL,
    call_end_ts            TIMESTAMP,
    duration_sec           INT      DEFAULT 0,
    call_type              STRING   DEFAULT 'VOICE',
    call_result            STRING   NOT NULL,
    termination_cause_code INT,
    CONSTRAINT pk_cdr PRIMARY KEY (cdr_id),
    CONSTRAINT fk_cdr_subscriber FOREIGN KEY (subscriber_id) REFERENCES subscriber(subscriber_id),
    CONSTRAINT fk_cdr_site       FOREIGN KEY (site_id)       REFERENCES site(site_id)
)
CLUSTER BY (site_id, call_start_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_cdr_site_ts, ix_cdr_sub, ix_cdr_result
                                     -- (liquid clustering allows up to 4 columns if you
                                     -- want subscriber_id / call_result added too)

ALTER TABLE cdr ADD CONSTRAINT ck_cdr_call_type CHECK (call_type IN ('VOICE','VIDEO','DATA_SESSION'));
ALTER TABLE cdr ADD CONSTRAINT ck_cdr_call_result CHECK (call_result IN ('SUCCESS','DROPPED','FAILED','BLOCKED'));

-- ---------------------------------------------------------------------------
-- FACT: ALARM_LOG
-- ---------------------------------------------------------------------------
CREATE TABLE alarm_log (
    alarm_id          BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id           BIGINT   NOT NULL,
    alarm_ts          TIMESTAMP NOT NULL,
    cleared_ts        TIMESTAMP,
    alarm_type        STRING   NOT NULL,
    severity          STRING   NOT NULL,
    alarm_description STRING,
    CONSTRAINT pk_alarm_log PRIMARY KEY (alarm_id),
    CONSTRAINT fk_alarm_site FOREIGN KEY (site_id) REFERENCES site(site_id)
)
CLUSTER BY (site_id, alarm_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_alarm_site_ts

ALTER TABLE alarm_log ADD CONSTRAINT ck_alarm_severity CHECK (severity IN ('CRITICAL','MAJOR','MINOR','WARNING'));

-- ---------------------------------------------------------------------------
-- FACT: NETWORK_EVENT (config changes, planned maintenance, fiber cuts, etc.)
-- ---------------------------------------------------------------------------
CREATE TABLE network_event (
    event_id          BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id           BIGINT   NOT NULL,
    event_ts          TIMESTAMP NOT NULL,
    event_type        STRING   NOT NULL,
    event_severity    STRING   DEFAULT 'INFO',
    event_description STRING,
    CONSTRAINT pk_network_event PRIMARY KEY (event_id),
    CONSTRAINT fk_event_site FOREIGN KEY (site_id) REFERENCES site(site_id)
)
CLUSTER BY (site_id, event_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_event_site_ts

ALTER TABLE network_event ADD CONSTRAINT ck_event_severity CHECK (event_severity IN ('INFO','WARNING','SEVERE'));

-- ---------------------------------------------------------------------------
-- FACT: NETWORK_KPI (hourly, per site)
-- ---------------------------------------------------------------------------
CREATE TABLE network_kpi (
    kpi_id                  BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id                 BIGINT   NOT NULL,
    kpi_ts                  TIMESTAMP NOT NULL,
    latency_ms              DECIMAL(8,2),
    jitter_ms               DECIMAL(8,2),
    packet_drop_rate        DECIMAL(6,4),   -- fraction 0-1
    call_drop_rate          DECIMAL(6,4),   -- fraction 0-1
    rrc_setup_success_rate  DECIMAL(6,4),   -- fraction 0-1
    throughput_mbps         DECIMAL(10,2),
    CONSTRAINT pk_network_kpi PRIMARY KEY (kpi_id),
    CONSTRAINT fk_kpi_site FOREIGN KEY (site_id) REFERENCES site(site_id)
    -- Oracle also had: CONSTRAINT uq_kpi_site_ts UNIQUE (site_id, kpi_ts)
    -- Databricks/Delta has no UNIQUE constraint type. Uniqueness of
    -- (site_id, kpi_ts) is enforced by the MERGE in 03_packages.sql instead
    -- of the database — see CONVERSION_GUIDE.md.
)
CLUSTER BY (site_id, kpi_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_kpi_ts (and covers site_id lookups too)

-- ---------------------------------------------------------------------------
-- FACT: TICKET (trouble tickets / resolution times)
-- ---------------------------------------------------------------------------
CREATE TABLE ticket (
    ticket_id            BIGINT   GENERATED ALWAYS AS IDENTITY,
    subscriber_id        BIGINT,
    site_id              BIGINT   NOT NULL,
    opened_ts            TIMESTAMP NOT NULL,
    closed_ts            TIMESTAMP,
    resolution_time_min  BIGINT,
    category             STRING,
    priority             STRING   DEFAULT 'P3',
    root_cause           STRING,
    CONSTRAINT pk_ticket PRIMARY KEY (ticket_id),
    CONSTRAINT fk_ticket_sub  FOREIGN KEY (subscriber_id) REFERENCES subscriber(subscriber_id),
    CONSTRAINT fk_ticket_site FOREIGN KEY (site_id)       REFERENCES site(site_id)
)
CLUSTER BY (site_id, opened_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_ticket_site_ts

ALTER TABLE ticket ADD CONSTRAINT ck_ticket_priority CHECK (priority IN ('P1','P2','P3','P4'));

-- ---------------------------------------------------------------------------
-- FACT: CUSTOMER_SATISFACTION (NPS / CSAT survey results)
-- ---------------------------------------------------------------------------
CREATE TABLE customer_satisfaction (
    survey_id      BIGINT   GENERATED ALWAYS AS IDENTITY,
    subscriber_id  BIGINT   NOT NULL,
    survey_ts      TIMESTAMP NOT NULL,
    nps_score      INT,
    csat_score     INT,
    channel        STRING   DEFAULT 'SMS',
    CONSTRAINT pk_customer_satisfaction PRIMARY KEY (survey_id),
    CONSTRAINT fk_csat_sub FOREIGN KEY (subscriber_id) REFERENCES subscriber(subscriber_id)
)
CLUSTER BY (subscriber_id, survey_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_csat_sub_ts

ALTER TABLE customer_satisfaction ADD CONSTRAINT ck_csat_nps CHECK (nps_score BETWEEN -100 AND 100);
ALTER TABLE customer_satisfaction ADD CONSTRAINT ck_csat_csat CHECK (csat_score BETWEEN 1 AND 5);

-- ---------------------------------------------------------------------------
-- DERIVED FACT: CALL_VOLUME_HOURLY — built by the feature-engineering script
-- from raw CDR. This is the primary LSTM training/inference input.
-- ---------------------------------------------------------------------------
CREATE TABLE call_volume_hourly (
    site_id        BIGINT   NOT NULL,
    hour_ts        TIMESTAMP NOT NULL,
    total_calls    BIGINT   DEFAULT 0,
    dropped_calls  BIGINT   DEFAULT 0,
    failed_calls   BIGINT   DEFAULT 0,
    blocked_calls  BIGINT   DEFAULT 0,
    success_rate   DECIMAL(6,4),
    refreshed_ts   TIMESTAMP DEFAULT current_timestamp(),
    CONSTRAINT pk_call_volume_hourly PRIMARY KEY (site_id, hour_ts),
    CONSTRAINT fk_cvh_site FOREIGN KEY (site_id) REFERENCES site(site_id)
)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

-- ---------------------------------------------------------------------------
-- MODEL OUTPUT: CALL_EVENT_PREDICTION — LSTM forecast written by the
-- Python training/inference pipeline (src/predict_and_score.py)
-- ---------------------------------------------------------------------------
CREATE TABLE call_event_prediction (
    prediction_id           BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id                 BIGINT   NOT NULL,
    prediction_ts           TIMESTAMP NOT NULL,   -- time the forecast target hour begins
    generated_ts            TIMESTAMP DEFAULT current_timestamp(),
    horizon_hours           INT      NOT NULL,   -- how far ahead this forecast looks
    predicted_call_volume   BIGINT,
    predicted_drop_rate     DECIMAL(6,4),
    predicted_failure_prob  DECIMAL(6,4),
    risk_level              STRING,
    model_version           STRING   NOT NULL,
    CONSTRAINT pk_call_event_prediction PRIMARY KEY (prediction_id),
    CONSTRAINT fk_cep_site FOREIGN KEY (site_id) REFERENCES site(site_id)
)
CLUSTER BY (site_id, prediction_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_cep_site_ts

ALTER TABLE call_event_prediction ADD CONSTRAINT ck_cep_risk_level CHECK (risk_level IN ('LOW','MODERATE','HIGH','CRITICAL'));

-- ---------------------------------------------------------------------------
-- MODEL OUTPUT: QOE_SCORE — regression output (KPIs -> QoE) plus the
-- rule-based fallback score (see rule_based_qoe function in 03_packages.sql)
-- ---------------------------------------------------------------------------
CREATE TABLE qoe_score (
    qoe_id                BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id               BIGINT   NOT NULL,
    score_ts              TIMESTAMP NOT NULL,
    predicted_qoe_score   DECIMAL(6,3) NOT NULL,   -- 0-100 scale
    qoe_band              STRING,
    model_version         STRING   NOT NULL,  -- e.g. 'REG_V1' or 'RULE_BASED_V1'
    created_ts            TIMESTAMP DEFAULT current_timestamp(),
    CONSTRAINT pk_qoe_score PRIMARY KEY (qoe_id),
    CONSTRAINT fk_qoe_site FOREIGN KEY (site_id) REFERENCES site(site_id)
    -- Oracle also had: CONSTRAINT uq_qoe_site_ts_model UNIQUE (site_id, score_ts, model_version)
    -- Same note as network_kpi above: enforced via MERGE, not a DB constraint.
)
CLUSTER BY (site_id, score_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_qoe_site_ts

ALTER TABLE qoe_score ADD CONSTRAINT ck_qoe_band CHECK (qoe_band IN ('EXCELLENT','GOOD','FAIR','POOR','CRITICAL'));

-- ---------------------------------------------------------------------------
-- BUSINESS OUTPUT: TRIAGE_QUEUE — final ranked worklist combining technical
-- severity with customer impact. Built by the build_triage_queue script in
-- 03_packages.sql.
-- ---------------------------------------------------------------------------
CREATE TABLE triage_queue (
    triage_id                        BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id                          BIGINT   NOT NULL,
    prediction_ts                    TIMESTAMP NOT NULL,
    technical_severity_score         DECIMAL(6,3),
    customer_impact_score            DECIMAL(6,3),
    composite_priority_score         DECIMAL(6,3),
    priority_rank                    INT,
    high_value_subscribers_affected  BIGINT,
    churn_risk_subscribers           BIGINT,
    recommended_action               STRING,
    status                           STRING   DEFAULT 'OPEN',
    created_ts                       TIMESTAMP DEFAULT current_timestamp(),
    CONSTRAINT pk_triage_queue PRIMARY KEY (triage_id),
    CONSTRAINT fk_triage_site FOREIGN KEY (site_id) REFERENCES site(site_id)
)
CLUSTER BY (prediction_ts, status)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported'); -- replaces ix_triage_pred_ts, ix_triage_status

ALTER TABLE triage_queue ADD CONSTRAINT ck_triage_status CHECK (status IN ('OPEN','ACKNOWLEDGED','RESOLVED'));

-- No COMMIT needed: Databricks SQL autocommits every DDL/DML statement.
