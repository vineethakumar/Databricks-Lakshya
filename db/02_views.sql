-- ============================================================================
-- 02_views.sql — feature views consumed by the Python training/inference code
-- (Databricks SQL / Delta Lake)
--
-- Converted from Oracle. Changes from the Oracle version:
--   * TRUNC(ts, 'HH24')  -> date_trunc('HOUR', ts)
--   * NVL(...)           -> unchanged (Databricks SQL has a built-in nvl() too)
--   * INTERVAL '72' HOUR -> unchanged (Databricks SQL accepts the same ANSI
--                           interval literal syntax)
--   * CREATE OR REPLACE VIEW -> unchanged, identical syntax
-- ============================================================================

-- ---------------------------------------------------------------------------
-- VW_SITE_HOURLY_FEATURES
-- One row per site per hour: call-volume aggregates + KPI snapshot + alarm/
-- event counts in that hour. This is the LSTM's raw feature source
-- (src/data_loader.py -> load_site_hourly_features).
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- VW_QOE_TRAINING_DATA
-- Pairs each KPI reading with the average NPS/CSAT of each subscriber
-- segment at that site who took a survey in the following 72h, so the
-- regression model can learn KPI -> NPS/CSAT per segment. Grouped by
-- (site_id, kpi_ts, segment) rather than joined subscriber-by-subscriber:
-- a plain join would fan one KPI reading out into one row per matching
-- subscriber x survey, duplicating the same KPI values across many rows
-- and skewing training toward whichever site/hour happened to have the
-- most surveys land in its window. This is the QoE regression training
-- source (src/data_loader.py -> load_qoe_training_data).
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- VW_SITE_SUBSCRIBER_VALUE
-- Per-site rollup of subscriber value mix — used by the triage logic in
-- 03_packages.sql to weight customer impact by how many high-ARPU /
-- high-value subscribers a site actually serves, not just raw subscriber
-- counts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_site_subscriber_value AS
SELECT
    home_site_id                                                   AS site_id,
    COUNT(*)                                                        AS subscriber_count,
    SUM(CASE WHEN segment = 'HIGH_VALUE' THEN 1 ELSE 0 END)         AS high_value_count,
    SUM(monthly_arpu)                                                AS total_arpu,
    SUM(CASE WHEN churn_flag = 'Y' THEN 1 ELSE 0 END)               AS flagged_churn_count
FROM subscriber
GROUP BY home_site_id;

-- No COMMIT needed: Databricks SQL autocommits every DDL/DML statement.
