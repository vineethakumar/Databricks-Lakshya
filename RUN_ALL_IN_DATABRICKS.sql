-- ============================================================================
-- Call Failure & Customer Experience Prediction — Databricks SQL
-- ONE-FILE VERSION: paste this whole file into the Databricks SQL Editor
-- and click Run. It is db/01_schema.sql -> 02_views.sql -> 03_packages.sql
-- -> 05_seed_data.sql concatenated in their required run order (all 4
-- source files are unchanged; this file just saves you 4 copy/paste steps).
-- BEFORE RUNNING: edit the catalog/schem names on the nex two lines to
-- match your workspace (create the schem first if it doesn't exist yet:
-- CREATE SCHEMA IF NOT EXISTS <catalog>.<schema>;).
-- ============================================================================
   USE CATALOG telecom_qoe_catalog;
   USE SCHEMA  telecom_qoe;


-- ============================================================================
-- SECTION 1 / 4 — was db/01_schema.sql
-- Core dimension + fact tables (Databricks SQL / Delta Lake, Unity Catalog)
-- Converted from Oracle. See CONVERSION_GUIDE.md for the full mapping:
--   VARCHAR2(n)/CHAR(n) -> STRING | NUMBER(p) p<=9 -> INT | p>=10 -> BIGINT
--   NUMBER(p,s) -> DECIMAL(p,s) | SYSTIMESTAMP -> current_timestamp()
--   inline CHECK -> ALTER TABLE ADD CONSTRAINT right after CREATE TABLE
--   CREATE INDEX -> CLUSTER BY (liquid clustering)
-- ============================================================================

-- Make this script re-runnable: drop children before parents so Unity
-- Catalog's FK dependency tracking doesn't block dropping a referenced table.
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

-- DIMENSION: SITE (cell site / node inventory)
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

-- DIMENSION: SUBSCRIBER
CREATE TABLE subscriber (
    subscriber_id    BIGINT       GENERATED ALWAYS AS IDENTITY,
    msisdn           STRING       NOT NULL,
    segment          STRING       NOT NULL,
    plan_type        STRING,
    tenure_months    INT          DEFAULT 0,
    monthly_arpu     DECIMAL(10,2) DEFAULT 0,
    churn_flag       STRING       DEFAULT 'N',
    churn_flagged_ts TIMESTAMP,
    home_site_id     BIGINT       NOT NULL,
    created_ts       TIMESTAMP    DEFAULT current_timestamp() NOT NULL,
    CONSTRAINT pk_subscriber PRIMARY KEY (subscriber_id),
    CONSTRAINT fk_subscriber_site FOREIGN KEY (home_site_id) REFERENCES site(site_id)
)
CLUSTER BY (home_site_id)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE subscriber ADD CONSTRAINT ck_subscriber_segment CHECK (segment IN ('HIGH_VALUE','MEDIUM_VALUE','LOW_VALUE'));
ALTER TABLE subscriber ADD CONSTRAINT ck_subscriber_churn_flag CHECK (churn_flag IN ('Y','N'));

-- FACT: CDR (Call Detail Records)
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
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE cdr ADD CONSTRAINT ck_cdr_call_type CHECK (call_type IN ('VOICE','VIDEO','DATA_SESSION'));
ALTER TABLE cdr ADD CONSTRAINT ck_cdr_call_result CHECK (call_result IN ('SUCCESS','DROPPED','FAILED','BLOCKED'));

-- FACT: ALARM_LOG
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
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE alarm_log ADD CONSTRAINT ck_alarm_severity CHECK (severity IN ('CRITICAL','MAJOR','MINOR','WARNING'));

-- FACT: NETWORK_EVENT
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
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE network_event ADD CONSTRAINT ck_event_severity CHECK (event_severity IN ('INFO','WARNING','SEVERE'));

-- FACT: NETWORK_KPI (hourly, per site)
CREATE TABLE network_kpi (
    kpi_id                  BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id                 BIGINT   NOT NULL,
    kpi_ts                  TIMESTAMP NOT NULL,
    latency_ms              DECIMAL(8,2),
    jitter_ms               DECIMAL(8,2),
    packet_drop_rate        DECIMAL(6,4),
    call_drop_rate          DECIMAL(6,4),
    rrc_setup_success_rate  DECIMAL(6,4),
    throughput_mbps         DECIMAL(10,2),
    CONSTRAINT pk_network_kpi PRIMARY KEY (kpi_id),
    CONSTRAINT fk_kpi_site FOREIGN KEY (site_id) REFERENCES site(site_id)
    -- Oracle also had UNIQUE (site_id, kpi_ts); Delta has no UNIQUE
    -- constraint, so uniqueness is enforced by the MERGE in section 3 instead.
)
CLUSTER BY (site_id, kpi_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

-- FACT: TICKET (trouble tickets / resolution times)
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
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE ticket ADD CONSTRAINT ck_ticket_priority CHECK (priority IN ('P1','P2','P3','P4'));

-- FACT: CUSTOMER_SATISFACTION (NPS/CSAT survey results)
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
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE customer_satisfaction ADD CONSTRAINT ck_csat_nps CHECK (nps_score BETWEEN -100 AND 100);
ALTER TABLE customer_satisfaction ADD CONSTRAINT ck_csat_csat CHECK (csat_score BETWEEN 1 AND 5);

-- DERIVED FACT: CALL_VOLUME_HOURLY (built by section 3's feature-engineering script)
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

-- MODEL OUTPUT: CALL_EVENT_PREDICTION (LSTM forecast, written by src/predict_and_score.py)
CREATE TABLE call_event_prediction (
    prediction_id           BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id                 BIGINT   NOT NULL,
    prediction_ts           TIMESTAMP NOT NULL,
    generated_ts            TIMESTAMP DEFAULT current_timestamp(),
    horizon_hours           INT      NOT NULL,
    predicted_call_volume   BIGINT,
    predicted_drop_rate     DECIMAL(6,4),
    predicted_failure_prob  DECIMAL(6,4),
    risk_level              STRING,
    model_version           STRING   NOT NULL,
    CONSTRAINT pk_call_event_prediction PRIMARY KEY (prediction_id),
    CONSTRAINT fk_cep_site FOREIGN KEY (site_id) REFERENCES site(site_id)
)
CLUSTER BY (site_id, prediction_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE call_event_prediction ADD CONSTRAINT ck_cep_risk_level CHECK (risk_level IN ('LOW','MODERATE','HIGH','CRITICAL'));

-- MODEL OUTPUT: QOE_SCORE (regression output + rule-based fallback)
CREATE TABLE qoe_score (
    qoe_id                BIGINT   GENERATED ALWAYS AS IDENTITY,
    site_id               BIGINT   NOT NULL,
    score_ts              TIMESTAMP NOT NULL,
    predicted_qoe_score   DECIMAL(6,3) NOT NULL,
    qoe_band              STRING,
    model_version         STRING   NOT NULL,
    created_ts            TIMESTAMP DEFAULT current_timestamp(),
    CONSTRAINT pk_qoe_score PRIMARY KEY (qoe_id),
    CONSTRAINT fk_qoe_site FOREIGN KEY (site_id) REFERENCES site(site_id)
    -- Oracle also had UNIQUE (site_id, score_ts, model_version); same note as network_kpi above.
)
CLUSTER BY (site_id, score_ts)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE qoe_score ADD CONSTRAINT ck_qoe_band CHECK (qoe_band IN ('EXCELLENT','GOOD','FAIR','POOR','CRITICAL'));

-- BUSINESS OUTPUT: TRIAGE_QUEUE (final ranked worklist)
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
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');

ALTER TABLE triage_queue ADD CONSTRAINT ck_triage_status CHECK (status IN ('OPEN','ACKNOWLEDGED','RESOLVED'));


-- ============================================================================
-- SECTION 2 / 4 — was db/02_views.sql
-- Feature views consumed by the Python training/inference code
-- ============================================================================

CREATE OR REPLACE VIEW vw_site_hourly_features AS
SELECT
    cvh.site_id,
    cvh.hour_ts,
    cvh.total_calls,
    cvh.dropped_calls,
    cvh.failed_calls,
    cvh.blocked_calls,
    cvh.success_rate,
    k.latency_ms,
    k.jitter_ms,
    k.packet_drop_rate,
    k.call_drop_rate,
    k.rrc_setup_success_rate,
    k.throughput_mbps,
    NVL(a.alarm_count, 0)          AS alarm_count,
    NVL(a.critical_alarm_count, 0) AS critical_alarm_count,
    NVL(e.event_count, 0)          AS event_count,
    s.capacity_erlangs,
    s.region,
    s.site_type
FROM call_volume_hourly cvh
JOIN site s
  ON s.site_id = cvh.site_id
LEFT JOIN network_kpi k
  ON k.site_id = cvh.site_id AND k.kpi_ts = cvh.hour_ts
LEFT JOIN (
    SELECT site_id,
           date_trunc('HOUR', alarm_ts)                              AS hour_ts,
           COUNT(*)                                                  AS alarm_count,
           SUM(CASE WHEN severity = 'CRITICAL' THEN 1 ELSE 0 END)    AS critical_alarm_count
    FROM alarm_log
    GROUP BY site_id, date_trunc('HOUR', alarm_ts)
) a ON a.site_id = cvh.site_id AND a.hour_ts = cvh.hour_ts
LEFT JOIN (
    SELECT site_id, date_trunc('HOUR', event_ts) AS hour_ts, COUNT(*) AS event_count
    FROM network_event
    GROUP BY site_id, date_trunc('HOUR', event_ts)
) e ON e.site_id = cvh.site_id AND e.hour_ts = cvh.hour_ts;

CREATE OR REPLACE VIEW vw_qoe_training_data AS
SELECT
    k.site_id,
    k.kpi_ts,
    k.latency_ms,
    k.jitter_ms,
    k.packet_drop_rate,
    k.call_drop_rate,
    k.rrc_setup_success_rate,
    k.throughput_mbps,
    sub.segment,
    ROUND(AVG(cs.nps_score), 2)  AS nps_score,
    ROUND(AVG(cs.csat_score), 2) AS csat_score,
    COUNT(*)                     AS survey_count
FROM network_kpi k
JOIN subscriber sub
  ON sub.home_site_id = k.site_id
JOIN customer_satisfaction cs
  ON cs.subscriber_id = sub.subscriber_id
 AND cs.survey_ts BETWEEN k.kpi_ts AND k.kpi_ts + INTERVAL '72' HOUR
GROUP BY
    k.site_id, k.kpi_ts, k.latency_ms, k.jitter_ms, k.packet_drop_rate,
    k.call_drop_rate, k.rrc_setup_success_rate, k.throughput_mbps, sub.segment;

CREATE OR REPLACE VIEW vw_site_subscriber_value AS
SELECT
    home_site_id                                                   AS site_id,
    COUNT(*)                                                        AS subscriber_count,
    SUM(CASE WHEN segment = 'HIGH_VALUE' THEN 1 ELSE 0 END)         AS high_value_count,
    SUM(monthly_arpu)                                                AS total_arpu,
    SUM(CASE WHEN churn_flag = 'Y' THEN 1 ELSE 0 END)               AS flagged_churn_count
FROM subscriber
GROUP BY home_site_id;


-- ============================================================================
-- SECTION 3 / 4 — was db/03_packages.sql
-- Core business logic: feature engineering, QoE scoring, triage.
-- Oracle PL/SQL packages -> SQL scalar functions (pure/deterministic logic)
-- + plain scripts using session variables (side-effecting logic).
-- ============================================================================

-- build_call_volume_hourly (was pkg_feature_engineering.build_call_volume_hourly)
DECLARE OR REPLACE VARIABLE v_start_ts TIMESTAMP DEFAULT date_trunc('HOUR', current_timestamp()) - INTERVAL 2 HOURS;
DECLARE OR REPLACE VARIABLE v_end_ts   TIMESTAMP DEFAULT date_trunc('HOUR', current_timestamp()) + INTERVAL 1 HOURS;

MERGE INTO call_volume_hourly AS tgt
USING (
    SELECT
        site_id,
        date_trunc('HOUR', call_start_ts)                              AS hour_ts,
        COUNT(*)                                                       AS total_calls,
        SUM(CASE WHEN call_result = 'DROPPED' THEN 1 ELSE 0 END)       AS dropped_calls,
        SUM(CASE WHEN call_result = 'FAILED'  THEN 1 ELSE 0 END)       AS failed_calls,
        SUM(CASE WHEN call_result = 'BLOCKED' THEN 1 ELSE 0 END)       AS blocked_calls,
        ROUND(
            SUM(CASE WHEN call_result = 'SUCCESS' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 4
        ) AS success_rate
    FROM cdr
    WHERE call_start_ts >= v_start_ts
      AND call_start_ts <  v_end_ts
    GROUP BY site_id, date_trunc('HOUR', call_start_ts)
) AS src
ON tgt.site_id = src.site_id AND tgt.hour_ts = src.hour_ts
WHEN MATCHED THEN UPDATE SET
    tgt.total_calls   = src.total_calls,
    tgt.dropped_calls = src.dropped_calls,
    tgt.failed_calls  = src.failed_calls,
    tgt.blocked_calls = src.blocked_calls,
    tgt.success_rate  = src.success_rate,
    tgt.refreshed_ts  = current_timestamp()
WHEN NOT MATCHED THEN INSERT (
    site_id, hour_ts, total_calls, dropped_calls, failed_calls, blocked_calls, success_rate
) VALUES (
    src.site_id, src.hour_ts, src.total_calls, src.dropped_calls,
    src.failed_calls, src.blocked_calls, src.success_rate
);

-- rule_based_qoe / qoe_band (was pkg_qoe_scoring)
CREATE OR REPLACE FUNCTION rule_based_qoe(
    p_latency_ms            DOUBLE,
    p_jitter_ms              DOUBLE,
    p_packet_drop_rate       DOUBLE,
    p_call_drop_rate         DOUBLE,
    p_rrc_setup_success_rate DOUBLE,
    p_throughput_mbps        DOUBLE
)
RETURNS DECIMAL(6,3)
DETERMINISTIC
RETURN ROUND(
      (GREATEST(0, 100 - (COALESCE(p_call_drop_rate, 0)   * 100 * 25))) * 0.30
    + (LEAST(100, COALESCE(p_rrc_setup_success_rate, 1) * 100))         * 0.20
    + (GREATEST(0, 100 - (COALESCE(p_latency_ms, 0) / 2)))              * 0.20
    + (GREATEST(0, 100 - (COALESCE(p_packet_drop_rate, 0) * 100 * 20))) * 0.15
    + (GREATEST(0, 100 - (COALESCE(p_jitter_ms, 0) * 5)))               * 0.10
    + (LEAST(100, COALESCE(p_throughput_mbps, 0) / 2))                 * 0.05
, 3);

CREATE OR REPLACE FUNCTION qoe_band(p_score DOUBLE)
RETURNS STRING
DETERMINISTIC
RETURN CASE
    WHEN p_score >= 85 THEN 'EXCELLENT'
    WHEN p_score >= 70 THEN 'GOOD'
    WHEN p_score >= 50 THEN 'FAIR'
    WHEN p_score >= 30 THEN 'POOR'
    ELSE 'CRITICAL'
END;

-- score_site_qoe_rule_based — SINGLE SITE (ad hoc / manual testing)
DECLARE OR REPLACE VARIABLE v_site_id BIGINT DEFAULT NULL;   -- SET VARIABLE v_site_id = 1001;
DECLARE OR REPLACE VARIABLE v_as_of   TIMESTAMP DEFAULT current_timestamp();

MERGE INTO qoe_score AS tgt
USING (
    SELECT
        v_site_id AS site_id,
        kpi_ts     AS score_ts,
        rule_based_qoe(latency_ms, jitter_ms, packet_drop_rate, call_drop_rate,
                        rrc_setup_success_rate, throughput_mbps) AS score
    FROM network_kpi
    WHERE site_id = v_site_id AND kpi_ts <= v_as_of
    ORDER BY kpi_ts DESC
    LIMIT 1
) AS src
ON tgt.site_id = src.site_id AND tgt.score_ts = src.score_ts AND tgt.model_version = 'RULE_BASED_V1'
WHEN MATCHED THEN UPDATE SET
    tgt.predicted_qoe_score = src.score,
    tgt.qoe_band            = qoe_band(src.score)
WHEN NOT MATCHED THEN INSERT (site_id, score_ts, predicted_qoe_score, qoe_band, model_version)
    VALUES (src.site_id, src.score_ts, src.score, qoe_band(src.score), 'RULE_BASED_V1');

CREATE OR REPLACE TEMPORARY VIEW _churn_check_single_site AS
SELECT site_id
FROM (
    SELECT site_id, predicted_qoe_score,
           ROW_NUMBER() OVER (PARTITION BY site_id ORDER BY score_ts DESC) AS rn
    FROM (
        SELECT site_id, score_ts, predicted_qoe_score,
               ROW_NUMBER() OVER (
                   PARTITION BY site_id, score_ts
                   ORDER BY CASE model_version WHEN 'REG_V1' THEN 0 ELSE 1 END
               ) AS model_rank
        FROM qoe_score
        WHERE site_id = v_site_id
    ) dedup WHERE model_rank = 1
) recent
WHERE rn <= 3
GROUP BY site_id
HAVING COUNT(CASE WHEN predicted_qoe_score < 50 THEN 1 END) >= 3;

UPDATE subscriber
SET churn_flag = 'Y', churn_flagged_ts = current_timestamp()
WHERE home_site_id = v_site_id
  AND segment = 'HIGH_VALUE'
  AND churn_flag = 'N'
  AND home_site_id IN (SELECT site_id FROM _churn_check_single_site);

DROP VIEW IF EXISTS _churn_check_single_site;

-- score_site_qoe_rule_based — ALL SITES (what the hourly job actually runs)
DECLARE OR REPLACE VARIABLE v_all_sites_as_of TIMESTAMP DEFAULT current_timestamp();

MERGE INTO qoe_score AS tgt
USING (
    SELECT site_id, kpi_ts AS score_ts,
           rule_based_qoe(latency_ms, jitter_ms, packet_drop_rate, call_drop_rate,
                           rrc_setup_success_rate, throughput_mbps) AS score
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY site_id ORDER BY kpi_ts DESC) AS rn
        FROM network_kpi
        WHERE kpi_ts <= v_all_sites_as_of
    ) latest
    WHERE rn = 1
) AS src
ON tgt.site_id = src.site_id AND tgt.score_ts = src.score_ts AND tgt.model_version = 'RULE_BASED_V1'
WHEN MATCHED THEN UPDATE SET
    tgt.predicted_qoe_score = src.score,
    tgt.qoe_band            = qoe_band(src.score)
WHEN NOT MATCHED THEN INSERT (site_id, score_ts, predicted_qoe_score, qoe_band, model_version)
    VALUES (src.site_id, src.score_ts, src.score, qoe_band(src.score), 'RULE_BASED_V1');

CREATE OR REPLACE TEMPORARY VIEW _churn_check_all_sites AS
SELECT site_id
FROM (
    SELECT site_id, predicted_qoe_score,
           ROW_NUMBER() OVER (PARTITION BY site_id ORDER BY score_ts DESC) AS rn
    FROM (
        SELECT site_id, score_ts, predicted_qoe_score,
               ROW_NUMBER() OVER (
                   PARTITION BY site_id, score_ts
                   ORDER BY CASE model_version WHEN 'REG_V1' THEN 0 ELSE 1 END
               ) AS model_rank
        FROM qoe_score
    ) dedup WHERE model_rank = 1
) recent
WHERE rn <= 3
GROUP BY site_id
HAVING COUNT(CASE WHEN predicted_qoe_score < 50 THEN 1 END) >= 3;

UPDATE subscriber
SET churn_flag = 'Y', churn_flagged_ts = current_timestamp()
WHERE segment = 'HIGH_VALUE'
  AND churn_flag = 'N'
  AND home_site_id IN (SELECT site_id FROM _churn_check_all_sites);

DROP VIEW IF EXISTS _churn_check_all_sites;

-- customer_impact_score / technical_severity_score (was pkg_triage)
CREATE OR REPLACE FUNCTION customer_impact_score(
    p_qoe_score        DOUBLE,
    p_high_value_count DOUBLE,
    p_subscriber_count DOUBLE,
    p_total_arpu       DOUBLE
)
RETURNS DECIMAL(6,3)
DETERMINISTIC
RETURN ROUND(
    LEAST(100,
        GREATEST(0, 100 - COALESCE(p_qoe_score, 100))
        * (
            1
            + LEAST(1,   COALESCE(p_high_value_count, 0) / NULLIF(p_subscriber_count, 0))
            + LEAST(0.5, COALESCE(p_total_arpu, 0) / NULLIF(p_subscriber_count, 0) / 200)
          )
    )
, 3);

CREATE OR REPLACE FUNCTION technical_severity_score(
    p_predicted_drop_rate    DOUBLE,
    p_predicted_failure_prob DOUBLE,
    p_critical_alarm_count   DOUBLE
)
RETURNS DECIMAL(6,3)
DETERMINISTIC
RETURN ROUND(LEAST(100,
      (COALESCE(p_predicted_drop_rate, 0)    * 100 * 0.5)
    + (COALESCE(p_predicted_failure_prob, 0) * 100 * 0.3)
    + (LEAST(COALESCE(p_critical_alarm_count, 0), 10) * 2)
), 3);

-- flag_churn_risk — SINGLE SITE (standalone / ad hoc testing)
DECLARE OR REPLACE VARIABLE v_churn_site_id           BIGINT  DEFAULT NULL;  -- SET VARIABLE v_churn_site_id = 1001;
DECLARE OR REPLACE VARIABLE v_churn_threshold          DECIMAL(6,3) DEFAULT 50;
DECLARE OR REPLACE VARIABLE v_churn_consecutive_hours  INT     DEFAULT 3;

CREATE OR REPLACE TEMPORARY VIEW _churn_check_standalone AS
SELECT site_id
FROM (
    SELECT site_id, predicted_qoe_score,
           ROW_NUMBER() OVER (PARTITION BY site_id ORDER BY score_ts DESC) AS rn
    FROM (
        SELECT site_id, score_ts, predicted_qoe_score,
               ROW_NUMBER() OVER (
                   PARTITION BY site_id, score_ts
                   ORDER BY CASE model_version WHEN 'REG_V1' THEN 0 ELSE 1 END
               ) AS model_rank
        FROM qoe_score
        WHERE site_id = v_churn_site_id
    ) dedup WHERE model_rank = 1
) recent
WHERE rn <= v_churn_consecutive_hours
GROUP BY site_id
HAVING COUNT(CASE WHEN predicted_qoe_score < v_churn_threshold THEN 1 END) >= v_churn_consecutive_hours;

UPDATE subscriber
SET churn_flag = 'Y', churn_flagged_ts = current_timestamp()
WHERE home_site_id = v_churn_site_id
  AND segment = 'HIGH_VALUE'
  AND churn_flag = 'N'
  AND home_site_id IN (SELECT site_id FROM _churn_check_standalone);

DROP VIEW IF EXISTS _churn_check_standalone;

-- build_triage_queue (was pkg_triage.build_triage_queue)
DECLARE OR REPLACE VARIABLE v_prediction_ts TIMESTAMP DEFAULT current_timestamp();
-- SET VARIABLE v_prediction_ts = TIMESTAMP'2026-01-10 09:00:00';

DELETE FROM triage_queue WHERE prediction_ts = v_prediction_ts;

INSERT INTO triage_queue (
    site_id, prediction_ts, technical_severity_score, customer_impact_score,
    composite_priority_score, priority_rank, high_value_subscribers_affected,
    churn_risk_subscribers, recommended_action
)
SELECT
    ranked.site_id,
    v_prediction_ts,
    ranked.tech_score,
    ranked.impact_score,
    ranked.composite_score,
    RANK() OVER (ORDER BY COALESCE(ranked.composite_score, 0) DESC) AS priority_rank,
    ranked.high_value_count,
    ranked.flagged_churn_count,
    CASE
        WHEN ranked.composite_score >= 75 THEN 'Dispatch field team immediately; notify high-value accounts proactively.'
        WHEN ranked.composite_score >= 50 THEN 'Schedule capacity/maintenance intervention within 24h.'
        WHEN ranked.composite_score >= 25 THEN 'Monitor; add to next maintenance window.'
        ELSE 'No action required.'
    END AS recommended_action
FROM (
    SELECT
        p.site_id,
        technical_severity_score(
            p.predicted_drop_rate, p.predicted_failure_prob, COALESCE(al.critical_alarm_count, 0)
        ) AS tech_score,
        customer_impact_score(
            q.predicted_qoe_score, sv.high_value_count, sv.subscriber_count, sv.total_arpu
        ) AS impact_score,
        ROUND(
            customer_impact_score(
                q.predicted_qoe_score, sv.high_value_count, sv.subscriber_count, sv.total_arpu
            ) * 0.6
          + technical_severity_score(
                p.predicted_drop_rate, p.predicted_failure_prob, COALESCE(al.critical_alarm_count, 0)
            ) * 0.4
        , 3) AS composite_score,
        sv.high_value_count,
        sv.flagged_churn_count
    FROM call_event_prediction p
    JOIN (
        SELECT site_id, score_ts, predicted_qoe_score
        FROM (
            SELECT site_id, score_ts, predicted_qoe_score,
                   ROW_NUMBER() OVER (PARTITION BY site_id ORDER BY score_ts DESC) AS rn
            FROM qoe_score
            WHERE score_ts <= v_prediction_ts
        ) latest
        WHERE rn = 1
    ) q ON q.site_id = p.site_id
    LEFT JOIN vw_site_subscriber_value sv ON sv.site_id = p.site_id
    LEFT JOIN (
        SELECT site_id, COUNT(*) AS critical_alarm_count
        FROM alarm_log
        WHERE severity = 'CRITICAL'
          AND alarm_ts <= v_prediction_ts
          AND (cleared_ts IS NULL OR cleared_ts > v_prediction_ts)
        GROUP BY site_id
    ) al ON al.site_id = p.site_id
    WHERE p.prediction_ts = v_prediction_ts
) ranked;

CREATE OR REPLACE TEMPORARY VIEW _churn_check_triage_run AS
SELECT site_id
FROM (
    SELECT site_id, predicted_qoe_score,
           ROW_NUMBER() OVER (PARTITION BY site_id ORDER BY score_ts DESC) AS rn
    FROM (
        SELECT site_id, score_ts, predicted_qoe_score,
               ROW_NUMBER() OVER (
                   PARTITION BY site_id, score_ts
                   ORDER BY CASE model_version WHEN 'REG_V1' THEN 0 ELSE 1 END
               ) AS model_rank
        FROM qoe_score
        WHERE site_id IN (SELECT DISTINCT site_id FROM triage_queue WHERE prediction_ts = v_prediction_ts)
    ) dedup WHERE model_rank = 1
) recent
WHERE rn <= 3
GROUP BY site_id
HAVING COUNT(CASE WHEN predicted_qoe_score < 50 THEN 1 END) >= 3;

UPDATE subscriber
SET churn_flag = 'Y', churn_flagged_ts = current_timestamp()
WHERE segment = 'HIGH_VALUE'
  AND churn_flag = 'N'
  AND home_site_id IN (SELECT site_id FROM _churn_check_triage_run);

DROP VIEW IF EXISTS _churn_check_triage_run;


-- ============================================================================
-- SECTION 4 / 4 — was db/05_seed_data.sql
-- Synthetic demo dataset: 6 sites (2 hit a 3-day incident), ~400 subscribers,
-- 10 days of hourly KPIs + CDR, alarms/events/tickets, CSAT/NPS surveys.
-- NOTE: bounded demo scale (~150-250k CDR rows) — expect a few minutes to run.
-- ============================================================================

-- Re-runnable: clear children before parents, then reseed from a clean slate.
DELETE FROM triage_queue;
DELETE FROM qoe_score;
DELETE FROM call_event_prediction;
DELETE FROM call_volume_hourly;
DELETE FROM customer_satisfaction;
DELETE FROM ticket;
DELETE FROM network_kpi;
DELETE FROM network_event;
DELETE FROM alarm_log;
DELETE FROM cdr;
DELETE FROM subscriber;
DELETE FROM site;

-- Sites
INSERT INTO site (site_name, region, latitude, longitude, site_type, capacity_erlangs) VALUES
    ('SITE-A-DOWNTOWN',   'NORTH',   40.712776, -74.005974, 'MACRO',      800),
    ('SITE-B-SUBURB',     'SOUTH',   40.650002, -73.949997, 'MACRO',      500),
    ('SITE-C-INDUSTRIAL', 'EAST',    40.729816, -73.958596, 'MACRO',      400),
    ('SITE-D-CAMPUS',     'WEST',    40.678177, -73.944160, 'SMALL_CELL', 300),
    ('SITE-E-MALL',       'CENTRAL', 40.741895, -73.989308, 'INDOOR',     350),
    ('SITE-F-RURAL',      'NORTH',   40.803680, -73.964462, 'MACRO',      200);

-- Subscribers (~400), round-robined across sites, 20/40/40 segment split
INSERT INTO subscriber (msisdn, segment, plan_type, tenure_months, monthly_arpu, home_site_id)
SELECT
    concat('1555', lpad(cast(i AS STRING), 7, '0'))                         AS msisdn,
    CASE WHEN i % 10 IN (0, 1)          THEN 'HIGH_VALUE'
         WHEN i % 10 IN (2, 3, 4, 5)    THEN 'MEDIUM_VALUE'
         ELSE 'LOW_VALUE' END                                               AS segment,
    CASE WHEN i % 10 IN (0, 1) THEN 'UNLIMITED_PREMIUM' ELSE 'STANDARD' END AS plan_type,
    CAST(1 + rand() * 95 AS INT)                                            AS tenure_months,
    CASE WHEN i % 10 IN (0, 1)       THEN ROUND(80 + rand() * 70, 2)
         WHEN i % 10 IN (2, 3, 4, 5) THEN ROUND(30 + rand() * 50, 2)
         ELSE ROUND(10 + rand() * 20, 2) END                                AS monthly_arpu,
    sl.site_id                                                              AS home_site_id
FROM (SELECT explode(sequence(1, 400)) AS i) gen
JOIN (
    SELECT site_id, (ROW_NUMBER() OVER (ORDER BY site_id) - 1) AS rn, COUNT(*) OVER () AS site_count
    FROM site
) sl ON sl.rn = gen.i % sl.site_count;

-- Hourly KPIs, 10 days x 24 hours x 6 sites; incident window = days 7-9 on 2 sites
CREATE OR REPLACE TEMPORARY VIEW _site_hours AS
SELECT
    s.site_id,
    s.site_name,
    s.capacity_erlangs,
    hrs.hour_ts,
    (s.site_name IN ('SITE-C-INDUSTRIAL', 'SITE-E-MALL')
        AND hrs.hour_ts >= date_trunc('DAY', current_timestamp()) - INTERVAL 3 DAYS
        AND hrs.hour_ts <  date_trunc('DAY', current_timestamp())
    ) AS is_incident,
    CASE WHEN hour(hrs.hour_ts) BETWEEN 8 AND 22 THEN 1.5 ELSE 0.4 END AS busy_factor
FROM site s
CROSS JOIN (
    SELECT explode(sequence(
        date_trunc('DAY', current_timestamp()) - INTERVAL 10 DAYS,
        date_trunc('DAY', current_timestamp()) - INTERVAL 1 HOURS,
        INTERVAL 1 HOURS
    )) AS hour_ts
) hrs;

INSERT INTO network_kpi (site_id, kpi_ts, latency_ms, jitter_ms, packet_drop_rate, call_drop_rate, rrc_setup_success_rate, throughput_mbps)
SELECT
    site_id,
    hour_ts,
    CASE WHEN is_incident THEN ROUND(120 + rand() * 80, 2)   ELSE ROUND(25 + rand() * 20, 2)   END AS latency_ms,
    CASE WHEN is_incident THEN ROUND(15  + rand() * 10, 2)   ELSE ROUND(2  + rand() * 3, 2)    END AS jitter_ms,
    CASE WHEN is_incident THEN ROUND(0.04 + rand() * 0.05, 4) ELSE ROUND(0.001 + rand() * 0.005, 4) END AS packet_drop_rate,
    CASE WHEN is_incident THEN ROUND(0.12 + rand() * 0.15, 4) ELSE ROUND(0.005 + rand() * 0.01, 4)  END AS call_drop_rate,
    LEAST(CASE WHEN is_incident THEN ROUND(0.75 - rand() * 0.15, 4) ELSE ROUND(0.97 + rand() * 0.03, 4) END, 1) AS rrc_setup_success_rate,
    CASE WHEN is_incident THEN ROUND(20 + rand() * 15, 2)    ELSE ROUND(80 + rand() * 60, 2)   END AS throughput_mbps
FROM _site_hours;

-- CDR: one row per call, generated via LATERAL VIEW explode(sequence(...))
CREATE OR REPLACE TEMPORARY VIEW _site_subs AS
SELECT home_site_id AS site_id, collect_list(subscriber_id) AS sub_ids, COUNT(*) AS sub_count
FROM subscriber
GROUP BY home_site_id;

CREATE OR REPLACE TEMPORARY VIEW _cdr_plan AS
SELECT
    sh.site_id,
    sh.hour_ts,
    sh.is_incident,
    k.call_drop_rate,
    k.packet_drop_rate,
    k.rrc_setup_success_rate,
    GREATEST(1, ROUND(
        (CASE WHEN sh.capacity_erlangs >= 500 THEN 40 ELSE 20 END) * sh.busy_factor * (0.7 + rand() * 0.6)
    )) AS call_count
FROM _site_hours sh
JOIN network_kpi k ON k.site_id = sh.site_id AND k.kpi_ts = sh.hour_ts;

CREATE OR REPLACE TEMPORARY VIEW _cdr_rolls AS
SELECT
    p.site_id, p.hour_ts, p.call_drop_rate, p.packet_drop_rate, p.rrc_setup_success_rate,
    c.call_num,
    rand()                        AS roll,
    CAST(rand() * 3599 AS INT)    AS start_offset_sec
FROM _cdr_plan p
LATERAL VIEW explode(sequence(1, CAST(p.call_count AS INT))) c AS call_num;

CREATE OR REPLACE TEMPORARY VIEW _cdr_calls AS
SELECT
    site_id, hour_ts, call_num, start_offset_sec,
    CASE
        WHEN roll < call_drop_rate THEN 'DROPPED'
        WHEN roll < call_drop_rate + (packet_drop_rate * 2) THEN 'FAILED'
        WHEN roll < call_drop_rate + (packet_drop_rate * 2) + (1 - rrc_setup_success_rate) * 0.3 THEN 'BLOCKED'
        ELSE 'SUCCESS'
    END AS result,
    CASE
        WHEN roll < call_drop_rate THEN CAST(rand() * 115 + 5 AS INT)
        WHEN roll < call_drop_rate + (packet_drop_rate * 2) THEN 0
        WHEN roll < call_drop_rate + (packet_drop_rate * 2) + (1 - rrc_setup_success_rate) * 0.3 THEN 0
        ELSE CAST(rand() * 590 + 10 AS INT)
    END AS duration_sec
FROM _cdr_rolls;

INSERT INTO cdr (call_id, subscriber_id, site_id, call_start_ts, call_end_ts, duration_sec, call_type, call_result, termination_cause_code)
SELECT
    concat('CALL-', date_format(cc.hour_ts, 'yyyyMMddHH'), '-', cc.site_id, '-', cc.call_num) AS call_id,
    element_at(ss.sub_ids, CAST(FLOOR(rand() * ss.sub_count) AS INT) + 1)                      AS subscriber_id,
    cc.site_id,
    cc.hour_ts + (cc.start_offset_sec * INTERVAL 1 SECONDS)                                    AS call_start_ts,
    CASE WHEN cc.result IN ('SUCCESS', 'DROPPED')
         THEN cc.hour_ts + (cc.start_offset_sec * INTERVAL 1 SECONDS) + (cc.duration_sec * INTERVAL 1 SECONDS)
         ELSE NULL END                                                                         AS call_end_ts,
    cc.duration_sec,
    'VOICE'                                                                                    AS call_type,
    cc.result                                                                                  AS call_result,
    CASE cc.result WHEN 'SUCCESS' THEN NULL WHEN 'DROPPED' THEN 16 WHEN 'FAILED' THEN 34 ELSE 22 END AS termination_cause_code
FROM _cdr_calls cc
JOIN _site_subs ss ON ss.site_id = cc.site_id;

-- Alarms + network events tied to the incident window (bad sites only)
INSERT INTO alarm_log (site_id, alarm_ts, cleared_ts, alarm_type, severity, alarm_description)
SELECT
    site_id,
    date_trunc('DAY', current_timestamp()) - INTERVAL 3 DAYS AS alarm_ts,
    date_trunc('DAY', current_timestamp())                   AS cleared_ts,
    'CAPACITY_DEGRADATION',
    'CRITICAL',
    'Sustained elevated call-drop rate and RRC setup failures.'
FROM site WHERE site_name IN ('SITE-C-INDUSTRIAL', 'SITE-E-MALL');

INSERT INTO network_event (site_id, event_ts, event_type, event_severity, event_description)
SELECT
    site_id,
    date_trunc('DAY', current_timestamp()) - INTERVAL 3 DAYS,
    'FIBER_LINK_DEGRADATION',
    'SEVERE',
    'Backhaul link degradation detected upstream of site.'
FROM site WHERE site_name IN ('SITE-C-INDUSTRIAL', 'SITE-E-MALL');

-- Tickets from affected subscribers during the incident: 20 per bad site
CREATE OR REPLACE TEMPORARY VIEW _ticket_plan AS
SELECT
    bad.site_id,
    t.ticket_num,
    (date_trunc('DAY', current_timestamp()) - INTERVAL 3 DAYS) + (CAST(rand() * 259200 AS INT) * INTERVAL 1 SECONDS) AS opened_ts,
    CAST(rand() * 570 + 30 AS INT) AS resolution_min
FROM (SELECT site_id FROM site WHERE site_name IN ('SITE-C-INDUSTRIAL', 'SITE-E-MALL')) bad
LATERAL VIEW explode(sequence(1, 20)) t AS ticket_num;

INSERT INTO ticket (subscriber_id, site_id, opened_ts, closed_ts, resolution_time_min, category, priority, root_cause)
SELECT
    element_at(ss.sub_ids, CAST(FLOOR(rand() * ss.sub_count) AS INT) + 1) AS subscriber_id,
    p.site_id,
    p.opened_ts,
    p.opened_ts + (p.resolution_min * 60 * INTERVAL 1 SECONDS)            AS closed_ts,
    p.resolution_min,
    'DROPPED_CALLS',
    'P2',
    'Backhaul link degradation'
FROM _ticket_plan p
JOIN _site_subs ss ON ss.site_id = p.site_id;

-- CSAT/NPS surveys — one every ~7 days per subscriber; depressed post-incident
INSERT INTO customer_satisfaction (subscriber_id, survey_ts, nps_score, csat_score, channel)
SELECT
    sub.subscriber_id,
    survey_ts,
    CASE WHEN si.site_name IN ('SITE-C-INDUSTRIAL', 'SITE-E-MALL')
              AND survey_ts >= date_trunc('DAY', current_timestamp()) - INTERVAL 3 DAYS
         THEN CAST(rand() * 70 - 80 AS INT)
         ELSE CAST(rand() * 60 + 10 AS INT) END AS nps_score,
    LEAST(
        CASE WHEN si.site_name IN ('SITE-C-INDUSTRIAL', 'SITE-E-MALL')
                  AND survey_ts >= date_trunc('DAY', current_timestamp()) - INTERVAL 3 DAYS
             THEN CAST(rand() * 2 + 1 AS INT)
             ELSE CAST(rand() * 3 + 3 AS INT) END,
        5
    ) AS csat_score,
    'SMS' AS channel
FROM subscriber sub
JOIN site si ON si.site_id = sub.home_site_id
LATERAL VIEW explode(sequence(
    date_trunc('DAY', current_timestamp()) - INTERVAL 7 DAYS,
    date_trunc('DAY', current_timestamp()),
    INTERVAL 7 DAYS
)) sv AS survey_ts;

-- Backfill call_volume_hourly for the whole seeded window
DECLARE OR REPLACE VARIABLE v_seed_start_ts TIMESTAMP DEFAULT date_trunc('DAY', current_timestamp()) - INTERVAL 10 DAYS;
DECLARE OR REPLACE VARIABLE v_seed_end_ts   TIMESTAMP DEFAULT date_trunc('DAY', current_timestamp()) + INTERVAL 1 DAYS;

MERGE INTO call_volume_hourly AS tgt
USING (
    SELECT
        site_id,
        date_trunc('HOUR', call_start_ts) AS hour_ts,
        COUNT(*) AS total_calls,
        SUM(CASE WHEN call_result = 'DROPPED' THEN 1 ELSE 0 END) AS dropped_calls,
        SUM(CASE WHEN call_result = 'FAILED'  THEN 1 ELSE 0 END) AS failed_calls,
        SUM(CASE WHEN call_result = 'BLOCKED' THEN 1 ELSE 0 END) AS blocked_calls,
        ROUND(SUM(CASE WHEN call_result = 'SUCCESS' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 4) AS success_rate
    FROM cdr
    WHERE call_start_ts >= v_seed_start_ts AND call_start_ts < v_seed_end_ts
    GROUP BY site_id, date_trunc('HOUR', call_start_ts)
) AS src
ON tgt.site_id = src.site_id AND tgt.hour_ts = src.hour_ts
WHEN MATCHED THEN UPDATE SET
    tgt.total_calls = src.total_calls, tgt.dropped_calls = src.dropped_calls,
    tgt.failed_calls = src.failed_calls, tgt.blocked_calls = src.blocked_calls,
    tgt.success_rate = src.success_rate, tgt.refreshed_ts = current_timestamp()
WHEN NOT MATCHED THEN INSERT (site_id, hour_ts, total_calls, dropped_calls, failed_calls, blocked_calls, success_rate)
    VALUES (src.site_id, src.hour_ts, src.total_calls, src.dropped_calls, src.failed_calls, src.blocked_calls, src.success_rate);

DROP VIEW IF EXISTS _site_hours;
DROP VIEW IF EXISTS _site_subs;
DROP VIEW IF EXISTS _cdr_plan;
DROP VIEW IF EXISTS _cdr_rolls;
DROP VIEW IF EXISTS _cdr_calls;
DROP VIEW IF EXISTS _ticket_plan;


-- ============================================================================
-- DONE. Sanity checks:
-- ============================================================================
SELECT site_name, region, capacity_erlangs FROM site ORDER BY site_id;   -- expect 6 rows
SELECT COUNT(*) AS cdr_row_count FROM cdr;                               -- expect ~150k-250k
SELECT * FROM vw_site_hourly_features ORDER BY hour_ts DESC LIMIT 10;
