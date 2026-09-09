-- ============================================================================
-- Use Case 1: Call Failure & Customer Experience Prediction
-- 01_schema.sql — core dimension + fact tables (Oracle PL/SQL)
--
-- Run order: 01_schema.sql -> 02_views.sql -> 03_packages.sql -> 05_seed_data.sql
-- (04_triggers_scheduler.sql removed — see db/CONVERSION_GUIDE.md)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- DIMENSION: SITE  (cell site / node inventory)
-- ---------------------------------------------------------------------------
CREATE TABLE site (
    site_id          NUMBER(10)      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_name        VARCHAR2(100)   NOT NULL,
    region           VARCHAR2(50)    NOT NULL,
    latitude         NUMBER(9,6),
    longitude        NUMBER(9,6),
    site_type        VARCHAR2(30)    DEFAULT 'MACRO' CHECK (site_type IN ('MACRO','SMALL_CELL','INDOOR')),
    capacity_erlangs NUMBER(10,2)    NOT NULL,
    created_ts       TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------------------
-- DIMENSION: SUBSCRIBER
-- ---------------------------------------------------------------------------
CREATE TABLE subscriber (
    subscriber_id    NUMBER(12)      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    msisdn           VARCHAR2(20)    NOT NULL,
    segment          VARCHAR2(20)    NOT NULL CHECK (segment IN ('HIGH_VALUE','MEDIUM_VALUE','LOW_VALUE')),
    plan_type        VARCHAR2(30),
    tenure_months    NUMBER(5)       DEFAULT 0,
    monthly_arpu     NUMBER(10,2)    DEFAULT 0,      -- used to weight customer impact
    churn_flag       CHAR(1)         DEFAULT 'N' CHECK (churn_flag IN ('Y','N')),
    churn_flagged_ts TIMESTAMP,
    home_site_id     NUMBER(10)      NOT NULL,
    created_ts       TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_subscriber_site FOREIGN KEY (home_site_id) REFERENCES site(site_id)
);

CREATE INDEX ix_subscriber_site ON subscriber(home_site_id);

-- ---------------------------------------------------------------------------
-- FACT: CDR (Call Detail Records)
-- ---------------------------------------------------------------------------
CREATE TABLE cdr (
    cdr_id                 NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    call_id                VARCHAR2(50) NOT NULL,
    subscriber_id          NUMBER(12)  NOT NULL,
    site_id                NUMBER(10)  NOT NULL,
    call_start_ts          TIMESTAMP   NOT NULL,
    call_end_ts            TIMESTAMP,
    duration_sec           NUMBER(10)  DEFAULT 0,
    call_type              VARCHAR2(20) DEFAULT 'VOICE' CHECK (call_type IN ('VOICE','VIDEO','DATA_SESSION')),
    call_result            VARCHAR2(20) NOT NULL CHECK (call_result IN ('SUCCESS','DROPPED','FAILED','BLOCKED')),
    termination_cause_code NUMBER(6),
    CONSTRAINT fk_cdr_subscriber FOREIGN KEY (subscriber_id) REFERENCES subscriber(subscriber_id),
    CONSTRAINT fk_cdr_site       FOREIGN KEY (site_id)       REFERENCES site(site_id)
);

CREATE INDEX ix_cdr_site_ts   ON cdr(site_id, call_start_ts);
CREATE INDEX ix_cdr_sub       ON cdr(subscriber_id);
CREATE INDEX ix_cdr_result    ON cdr(call_result);

-- ---------------------------------------------------------------------------
-- FACT: ALARM_LOG
-- ---------------------------------------------------------------------------
CREATE TABLE alarm_log (
    alarm_id          NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id           NUMBER(10)  NOT NULL,
    alarm_ts          TIMESTAMP   NOT NULL,
    cleared_ts        TIMESTAMP,
    alarm_type        VARCHAR2(50) NOT NULL,
    severity          VARCHAR2(20) NOT NULL CHECK (severity IN ('CRITICAL','MAJOR','MINOR','WARNING')),
    alarm_description VARCHAR2(500),
    CONSTRAINT fk_alarm_site FOREIGN KEY (site_id) REFERENCES site(site_id)
);

CREATE INDEX ix_alarm_site_ts ON alarm_log(site_id, alarm_ts);

-- ---------------------------------------------------------------------------
-- FACT: NETWORK_EVENT (config changes, planned maintenance, fiber cuts, etc.)
-- ---------------------------------------------------------------------------
CREATE TABLE network_event (
    event_id          NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id           NUMBER(10)  NOT NULL,
    event_ts          TIMESTAMP   NOT NULL,
    event_type        VARCHAR2(50) NOT NULL,
    event_severity    VARCHAR2(20) DEFAULT 'INFO' CHECK (event_severity IN ('INFO','WARNING','SEVERE')),
    event_description VARCHAR2(500),
    CONSTRAINT fk_event_site FOREIGN KEY (site_id) REFERENCES site(site_id)
);

CREATE INDEX ix_event_site_ts ON network_event(site_id, event_ts);

-- ---------------------------------------------------------------------------
-- FACT: NETWORK_KPI (hourly, per site)
-- ---------------------------------------------------------------------------
CREATE TABLE network_kpi (
    kpi_id                  NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id                 NUMBER(10)  NOT NULL,
    kpi_ts                  TIMESTAMP   NOT NULL,
    latency_ms              NUMBER(8,2),
    jitter_ms               NUMBER(8,2),
    packet_drop_rate        NUMBER(6,4),   -- fraction 0-1
    call_drop_rate          NUMBER(6,4),   -- fraction 0-1
    rrc_setup_success_rate  NUMBER(6,4),   -- fraction 0-1
    throughput_mbps         NUMBER(10,2),
    CONSTRAINT fk_kpi_site FOREIGN KEY (site_id) REFERENCES site(site_id),
    CONSTRAINT uq_kpi_site_ts UNIQUE (site_id, kpi_ts)
);

CREATE INDEX ix_kpi_ts ON network_kpi(kpi_ts);

-- ---------------------------------------------------------------------------
-- FACT: TICKET (trouble tickets / resolution times)
-- ---------------------------------------------------------------------------
CREATE TABLE ticket (
    ticket_id            NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscriber_id        NUMBER(12),
    site_id              NUMBER(10)  NOT NULL,
    opened_ts            TIMESTAMP   NOT NULL,
    closed_ts            TIMESTAMP,
    resolution_time_min  NUMBER(10),
    category             VARCHAR2(50),
    priority             VARCHAR2(20) DEFAULT 'P3' CHECK (priority IN ('P1','P2','P3','P4')),
    root_cause           VARCHAR2(200),
    CONSTRAINT fk_ticket_sub  FOREIGN KEY (subscriber_id) REFERENCES subscriber(subscriber_id),
    CONSTRAINT fk_ticket_site FOREIGN KEY (site_id)       REFERENCES site(site_id)
);

CREATE INDEX ix_ticket_site_ts ON ticket(site_id, opened_ts);

-- ---------------------------------------------------------------------------
-- FACT: CUSTOMER_SATISFACTION (NPS / CSAT survey results)
-- ---------------------------------------------------------------------------
CREATE TABLE customer_satisfaction (
    survey_id      NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscriber_id  NUMBER(12)  NOT NULL,
    survey_ts      TIMESTAMP   NOT NULL,
    nps_score      NUMBER(3)   CHECK (nps_score BETWEEN -100 AND 100),
    csat_score     NUMBER(3)   CHECK (csat_score BETWEEN 1 AND 5),
    channel        VARCHAR2(30) DEFAULT 'SMS',
    CONSTRAINT fk_csat_sub FOREIGN KEY (subscriber_id) REFERENCES subscriber(subscriber_id)
);

CREATE INDEX ix_csat_sub_ts ON customer_satisfaction(subscriber_id, survey_ts);

-- ---------------------------------------------------------------------------
-- DERIVED FACT: CALL_VOLUME_HOURLY — built by PKG_FEATURE_ENGINEERING
-- from raw CDR. This is the primary LSTM training/inference input.
-- ---------------------------------------------------------------------------
CREATE TABLE call_volume_hourly (
    site_id        NUMBER(10)  NOT NULL,
    hour_ts        TIMESTAMP   NOT NULL,
    total_calls    NUMBER(10)  DEFAULT 0,
    dropped_calls  NUMBER(10)  DEFAULT 0,
    failed_calls   NUMBER(10)  DEFAULT 0,
    blocked_calls  NUMBER(10)  DEFAULT 0,
    success_rate   NUMBER(6,4),
    refreshed_ts   TIMESTAMP   DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_call_volume_hourly PRIMARY KEY (site_id, hour_ts),
    CONSTRAINT fk_cvh_site FOREIGN KEY (site_id) REFERENCES site(site_id)
);

-- ---------------------------------------------------------------------------
-- MODEL OUTPUT: CALL_EVENT_PREDICTION — LSTM forecast written by the
-- Python training/inference pipeline (src/predict_and_score.py)
-- ---------------------------------------------------------------------------
CREATE TABLE call_event_prediction (
    prediction_id           NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id                 NUMBER(10)  NOT NULL,
    prediction_ts           TIMESTAMP   NOT NULL,   -- time the forecast target hour begins
    generated_ts            TIMESTAMP   DEFAULT SYSTIMESTAMP,
    horizon_hours           NUMBER(4)   NOT NULL,   -- how far ahead this forecast looks
    predicted_call_volume   NUMBER(10),
    predicted_drop_rate     NUMBER(6,4),
    predicted_failure_prob  NUMBER(6,4),
    risk_level              VARCHAR2(20) CHECK (risk_level IN ('LOW','MODERATE','HIGH','CRITICAL')),
    model_version           VARCHAR2(30) NOT NULL,
    CONSTRAINT fk_cep_site FOREIGN KEY (site_id) REFERENCES site(site_id)
);

CREATE INDEX ix_cep_site_ts ON call_event_prediction(site_id, prediction_ts);

-- ---------------------------------------------------------------------------
-- MODEL OUTPUT: QOE_SCORE — regression output (KPIs -> QoE) plus the
-- PL/SQL rule-based fallback score (PKG_QOE_SCORING.rule_based_qoe)
-- ---------------------------------------------------------------------------
CREATE TABLE qoe_score (
    qoe_id                NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id               NUMBER(10)  NOT NULL,
    score_ts              TIMESTAMP   NOT NULL,
    predicted_qoe_score   NUMBER(6,3) NOT NULL,   -- 0-100 scale
    qoe_band              VARCHAR2(20) CHECK (qoe_band IN ('EXCELLENT','GOOD','FAIR','POOR','CRITICAL')),
    model_version         VARCHAR2(30) NOT NULL,  -- e.g. 'REG_V1' or 'RULE_BASED_V1'
    created_ts            TIMESTAMP   DEFAULT SYSTIMESTAMP,
    CONSTRAINT fk_qoe_site FOREIGN KEY (site_id) REFERENCES site(site_id),
    CONSTRAINT uq_qoe_site_ts_model UNIQUE (site_id, score_ts, model_version)
);

CREATE INDEX ix_qoe_site_ts ON qoe_score(site_id, score_ts);

-- ---------------------------------------------------------------------------
-- BUSINESS OUTPUT: TRIAGE_QUEUE — final ranked worklist combining technical
-- severity with customer impact. Built by PKG_TRIAGE.build_triage_queue.
-- ---------------------------------------------------------------------------
CREATE TABLE triage_queue (
    triage_id                        NUMBER(19)  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id                          NUMBER(10)  NOT NULL,
    prediction_ts                    TIMESTAMP   NOT NULL,
    technical_severity_score         NUMBER(6,3),
    customer_impact_score            NUMBER(6,3),
    composite_priority_score         NUMBER(6,3),
    priority_rank                    NUMBER(6),
    high_value_subscribers_affected  NUMBER(10),
    churn_risk_subscribers           NUMBER(10),
    recommended_action               VARCHAR2(500),
    status                           VARCHAR2(20) DEFAULT 'OPEN' CHECK (status IN ('OPEN','ACKNOWLEDGED','RESOLVED')),
    created_ts                       TIMESTAMP   DEFAULT SYSTIMESTAMP,
    CONSTRAINT fk_triage_site FOREIGN KEY (site_id) REFERENCES site(site_id)
);

CREATE INDEX ix_triage_pred_ts ON triage_queue(prediction_ts);
CREATE INDEX ix_triage_status  ON triage_queue(status);

COMMIT;
