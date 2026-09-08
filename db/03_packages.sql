-- ============================================================================
-- 03_packages.sql — core business logic (Databricks SQL / Delta Lake)
--   Feature engineering : raw CDR -> hourly aggregates (LSTM input)
--   QoE scoring         : rule-based QoE fallback + banding
--   Triage              : customer-impact-weighted triage queue + churn flag
--
-- Databricks SQL has no PL/SQL-style packages, procedures with OUT
-- parameters, or exception handlers. Every Oracle PROCEDURE/FUNCTION below
-- is converted to one of two things:
--   * a pure, deterministic calculation  -> a Databricks SQL scalar
--     function (CREATE OR REPLACE FUNCTION) — called exactly like the
--     original pkg_x.function_name(...) calls, just without the "pkg_x."
--     prefix
--   * a procedure with side effects (INSERT/UPDATE/MERGE/DELETE)  -> a
--     plain SQL script that reads session variables (DECLARE VARIABLE)
--     standing in for the Oracle IN parameters. To run one:
--       1. SET VARIABLE <name> = <value>;   -- for each parameter you need
--       2. run the script's statements top to bottom
--     Any parameter you don't SET keeps its DECLARE ... DEFAULT value,
--     same as an Oracle parameter with a default falling back when the
--     caller omits it.
--
-- Oracle's ROWNUM/BULK COLLECT/FOR-loop constructs are replaced by plain
-- set-based SQL (window functions, MERGE, a precomputed view + IN filter
-- instead of a correlated subquery inside UPDATE) — see CONVERSION_GUIDE.md
-- for the construct-by-construct mapping.
-- ============================================================================


-- ============================================================================
-- SECTION 1 — feature engineering (was PKG_FEATURE_ENGINEERING)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- build_call_volume_hourly
-- Aggregates raw CDR rows into CALL_VOLUME_HOURLY for the given window.
-- Idempotent: re-running for the same window overwrites via MERGE, so it
-- is safe to call from a Databricks Job on a rolling basis.
--
-- Was: pkg_feature_engineering.build_call_volume_hourly(p_start_ts, p_end_ts)
-- ---------------------------------------------------------------------------
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
-- To test a specific window instead of the trailing-2-hour default:
--   SET VARIABLE v_start_ts = TIMESTAMP'2026-01-01 00:00:00',
--               v_end_ts   = TIMESTAMP'2026-01-02 00:00:00';
-- then re-run the MERGE above.


-- ============================================================================
-- SECTION 2 — QoE scoring (was PKG_QOE_SCORING)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- rule_based_qoe
-- Weighted rule-based QoE score (0-100) from raw KPIs. Used as a
-- same-second fallback whenever the regression model's output is stale
-- or unavailable, and as a sanity baseline to diff the ML score against.
--
-- Was: pkg_qoe_scoring.rule_based_qoe(...) FUNCTION ... DETERMINISTIC
-- Each sub-score normalized to 0-100; worse KPI -> lower sub-score.
-- Weights reflect what most directly drives perceived call quality:
-- drop/failure behavior first, then latency/jitter, then throughput.
-- ---------------------------------------------------------------------------
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
      (GREATEST(0, 100 - (COALESCE(p_call_drop_rate, 0)   * 100 * 25))) * 0.30   -- call-drop, 4%   -> 0
    + (LEAST(100, COALESCE(p_rrc_setup_success_rate, 1) * 100))         * 0.20
    + (GREATEST(0, 100 - (COALESCE(p_latency_ms, 0) / 2)))              * 0.20   -- 200ms -> 0
    + (GREATEST(0, 100 - (COALESCE(p_packet_drop_rate, 0) * 100 * 20))) * 0.15   -- pkt-drop, 5% -> 0
    + (GREATEST(0, 100 - (COALESCE(p_jitter_ms, 0) * 5)))               * 0.10   -- 20ms  -> 0
    + (LEAST(100, COALESCE(p_throughput_mbps, 0) / 2))                 * 0.05   -- 200Mbps -> 100
, 3);

-- ---------------------------------------------------------------------------
-- qoe_band
-- Was: pkg_qoe_scoring.qoe_band(...) FUNCTION ... DETERMINISTIC
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- score_site_qoe_rule_based — SINGLE SITE (ad hoc / manual testing)
-- Scores the latest KPI reading for one site with rule_based_qoe() and
-- upserts into QOE_SCORE (model_version = 'RULE_BASED_V1'). Mirrors the
-- Oracle procedure's exact signature (p_site_id, p_as_of).
--
-- Oracle's "SELECT ... WHERE ROWNUM = 1" is replaced by ORDER BY + LIMIT 1.
-- Oracle's "EXCEPTION WHEN NO_DATA_FOUND THEN NULL" needs no equivalent
-- here: if no KPI row exists yet for the site, the source subquery is
-- empty and the MERGE simply does nothing — same net effect.
--
-- Was: pkg_qoe_scoring.score_site_qoe_rule_based(p_site_id, p_as_of)
-- ---------------------------------------------------------------------------
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

-- Trigger fold-in: Databricks has no DML triggers, so the churn re-check
-- that Oracle's trg_qoe_churn_check (04_triggers_scheduler.sql) fired
-- automatically on every INSERT INTO qoe_score is run explicitly here,
-- right after the MERGE above, for the one site just scored.
--
-- Written as a precomputed view + plain UPDATE ... WHERE site_id IN (...)
-- rather than a correlated subquery inside the UPDATE itself — same
-- result, but each piece can be run and inspected on its own
-- (SELECT * FROM _churn_check_single_site), and it avoids relying on
-- deeply correlated subquery support inside UPDATE.
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

-- ---------------------------------------------------------------------------
-- score_site_qoe_rule_based — ALL SITES (what the hourly job actually runs)
-- Same rule_based_qoe scoring + churn fold-in as above, but for every site
-- in one pass instead of looping — this is what replaces Oracle's
-- "FOR s IN (SELECT site_id FROM site) LOOP ... END LOOP" in
-- 04_triggers_scheduler.sql's JOB_RULE_BASED_QOE.
-- ---------------------------------------------------------------------------
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


-- ============================================================================
-- SECTION 3 — triage (was PKG_TRIAGE)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- customer_impact_score
-- Composite customer-impact score (0-100): blends the QoE gap with how
-- much high-value ARPU sits behind the site, so a mediocre-but-busy
-- consumer site doesn't drown out a small site full of enterprise lines.
--
-- Was: pkg_triage.customer_impact_score(...) FUNCTION ... DETERMINISTIC
-- Value weight in [1.0, 2.5]: up to +1.0 when every subscriber on the
-- site is high-value, plus up to +0.5 more when average ARPU per
-- subscriber is at/above a $200 reference point.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- technical_severity_score
-- Technical severity (0-100) from the LSTM's forward-looking failure
-- signals plus current alarm pressure.
--
-- Was: pkg_triage.technical_severity_score(...) FUNCTION ... DETERMINISTIC
-- ---------------------------------------------------------------------------
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
    + (LEAST(COALESCE(p_critical_alarm_count, 0), 10) * 2)   -- cap alarm contribution at 20 pts
), 3);

-- ---------------------------------------------------------------------------
-- flag_churn_risk — SINGLE SITE (standalone / ad hoc testing)
-- Sets SUBSCRIBER.churn_flag = 'Y' for high-value subscribers at a site
-- whose QoE has stayed below v_threshold for v_consecutive_hours or more.
-- One reading per score_ts (a regression-model row takes priority over a
-- rule-based fallback row for the same hour, so a site scored by both
-- models isn't double-counted).
--
-- Was: pkg_triage.flag_churn_risk(p_site_id, p_threshold, p_consecutive_hours)
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- build_triage_queue
-- Rebuilds the triage queue for one prediction timestamp: joins the
-- latest LSTM forecast + QoE score + subscriber value mix per site, ranks
-- by composite score, and flags churn risk for high-value subscribers
-- sitting behind a sustained QoE dip.
--
-- Oracle's closing "FOR r IN (SELECT DISTINCT site_id ...) LOOP
-- flag_churn_risk(r.site_id); END LOOP" is replaced by one set-based
-- UPDATE (same logic as flag_churn_risk above, correlated to each site
-- touched by this run instead of a single :site_id parameter).
--
-- Was: pkg_triage.build_triage_queue(p_prediction_ts)
-- ---------------------------------------------------------------------------
DECLARE OR REPLACE VARIABLE v_prediction_ts TIMESTAMP DEFAULT current_timestamp();
-- SET VARIABLE v_prediction_ts = TIMESTAMP'2026-01-10 09:00:00';

-- Clear any prior run for this exact prediction timestamp so re-running
-- (e.g. after a late-arriving forecast) doesn't duplicate.
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
        -- Composite deliberately weights customer impact slightly above raw
        -- technical severity: this is the "triage by customer impact, not
        -- just technical severity" behavior the use case asks for.
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
    -- Latest QoE score per site as of v_prediction_ts, precomputed with a
    -- window function instead of a scalar subquery correlated to p.site_id
    -- inside the JOIN condition — Databricks SQL doesn't support a
    -- correlated scalar subquery there (only in WHERE/SELECT/aggregations/
    -- UPDATE/MERGE/DELETE). Every row here already shares the same
    -- p.prediction_ts = v_prediction_ts (see the WHERE below), so "as of
    -- p.prediction_ts" and "as of v_prediction_ts" are the same thing.
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
        -- Alarms active as of the prediction timestamp: still open, or
        -- cleared after the fact (so a seeded/backfilled incident window
        -- with a known cleared_ts still counts as active while
        -- v_prediction_ts falls inside it).
        SELECT site_id, COUNT(*) AS critical_alarm_count
        FROM alarm_log
        WHERE severity = 'CRITICAL'
          AND alarm_ts <= v_prediction_ts
          AND (cleared_ts IS NULL OR cleared_ts > v_prediction_ts)
        GROUP BY site_id
    ) al ON al.site_id = p.site_id
    WHERE p.prediction_ts = v_prediction_ts
) ranked;

-- Replaces "FOR r IN (SELECT DISTINCT site_id FROM triage_queue ...) LOOP
-- flag_churn_risk(r.site_id); END LOOP": one set-based UPDATE covering
-- every site touched by this run, same threshold/window as flag_churn_risk,
-- narrowed to just the sites this run actually touched.
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

-- No COMMIT needed: Databricks SQL autocommits every DDL/DML statement.
