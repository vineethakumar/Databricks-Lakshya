-- ============================================================================
-- 03_packages.sql — PL/SQL business logic
--   PKG_FEATURE_ENGINEERING : raw CDR -> hourly aggregates (LSTM input)
--   PKG_QOE_SCORING         : rule-based QoE fallback + banding
--   PKG_TRIAGE              : customer-impact-weighted triage queue + churn flag
-- ============================================================================

CREATE OR REPLACE PACKAGE pkg_feature_engineering AS

    -- Aggregates raw CDR rows into CALL_VOLUME_HOURLY for the given window.
    -- Idempotent: re-running for the same window overwrites via MERGE, so it
    -- is safe to call from a scheduler job on a rolling basis.
    PROCEDURE build_call_volume_hourly(
        p_start_ts IN TIMESTAMP,
        p_end_ts   IN TIMESTAMP
    );

END pkg_feature_engineering;
/

CREATE OR REPLACE PACKAGE BODY pkg_feature_engineering AS

    PROCEDURE build_call_volume_hourly(
        p_start_ts IN TIMESTAMP,
        p_end_ts   IN TIMESTAMP
    ) IS
    BEGIN
        MERGE INTO call_volume_hourly tgt
        USING (
            SELECT
                site_id,
                TRUNC(call_start_ts, 'HH24')                                   AS hour_ts,
                COUNT(*)                                                       AS total_calls,
                SUM(CASE WHEN call_result = 'DROPPED' THEN 1 ELSE 0 END)       AS dropped_calls,
                SUM(CASE WHEN call_result = 'FAILED'  THEN 1 ELSE 0 END)       AS failed_calls,
                SUM(CASE WHEN call_result = 'BLOCKED' THEN 1 ELSE 0 END)       AS blocked_calls,
                ROUND(
                    SUM(CASE WHEN call_result = 'SUCCESS' THEN 1 ELSE 0 END)
                    / NULLIF(COUNT(*), 0), 4
                ) AS success_rate
            FROM cdr
            WHERE call_start_ts >= p_start_ts
              AND call_start_ts <  p_end_ts
            GROUP BY site_id, TRUNC(call_start_ts, 'HH24')
        ) src
        ON (tgt.site_id = src.site_id AND tgt.hour_ts = src.hour_ts)
        WHEN MATCHED THEN UPDATE SET
            tgt.total_calls   = src.total_calls,
            tgt.dropped_calls = src.dropped_calls,
            tgt.failed_calls  = src.failed_calls,
            tgt.blocked_calls = src.blocked_calls,
            tgt.success_rate  = src.success_rate,
            tgt.refreshed_ts  = SYSTIMESTAMP
        WHEN NOT MATCHED THEN INSERT (
            site_id, hour_ts, total_calls, dropped_calls, failed_calls, blocked_calls, success_rate
        ) VALUES (
            src.site_id, src.hour_ts, src.total_calls, src.dropped_calls,
            src.failed_calls, src.blocked_calls, src.success_rate
        );

        COMMIT;
    END build_call_volume_hourly;

END pkg_feature_engineering;
/


CREATE OR REPLACE PACKAGE pkg_qoe_scoring AS

    -- Weighted rule-based QoE score (0-100) from raw KPIs. Used as a
    -- same-second fallback whenever the regression model's output is stale
    -- or unavailable, and as a sanity baseline to diff the ML score against.
    FUNCTION rule_based_qoe(
        p_latency_ms             IN NUMBER,
        p_jitter_ms               IN NUMBER,
        p_packet_drop_rate        IN NUMBER,
        p_call_drop_rate          IN NUMBER,
        p_rrc_setup_success_rate  IN NUMBER,
        p_throughput_mbps         IN NUMBER
    ) RETURN NUMBER DETERMINISTIC;

    FUNCTION qoe_band(p_score IN NUMBER) RETURN VARCHAR2 DETERMINISTIC;

    -- Scores the latest KPI reading for a site with the rule-based formula
    -- and inserts into QOE_SCORE (model_version = 'RULE_BASED_V1').
    PROCEDURE score_site_qoe_rule_based(
        p_site_id IN NUMBER,
        p_as_of   IN TIMESTAMP DEFAULT SYSTIMESTAMP
    );

END pkg_qoe_scoring;
/

CREATE OR REPLACE PACKAGE BODY pkg_qoe_scoring AS

    FUNCTION rule_based_qoe(
        p_latency_ms             IN NUMBER,
        p_jitter_ms               IN NUMBER,
        p_packet_drop_rate        IN NUMBER,
        p_call_drop_rate          IN NUMBER,
        p_rrc_setup_success_rate  IN NUMBER,
        p_throughput_mbps         IN NUMBER
    ) RETURN NUMBER DETERMINISTIC IS
        v_latency_score     NUMBER;
        v_jitter_score      NUMBER;
        v_pkt_drop_score    NUMBER;
        v_call_drop_score   NUMBER;
        v_rrc_score         NUMBER;
        v_throughput_score  NUMBER;
        v_score             NUMBER;
    BEGIN
        -- Each sub-score normalized to 0-100; worse KPI -> lower sub-score.
        v_latency_score    := GREATEST(0, 100 - (NVL(p_latency_ms, 0) / 2));                    -- 200ms -> 0
        v_jitter_score     := GREATEST(0, 100 - (NVL(p_jitter_ms, 0) * 5));                      -- 20ms  -> 0
        v_pkt_drop_score   := GREATEST(0, 100 - (NVL(p_packet_drop_rate, 0) * 100 * 20));        -- 5%    -> 0
        v_call_drop_score  := GREATEST(0, 100 - (NVL(p_call_drop_rate, 0) * 100 * 25));          -- 4%    -> 0
        v_rrc_score        := LEAST(100, NVL(p_rrc_setup_success_rate, 1) * 100);
        v_throughput_score := LEAST(100, NVL(p_throughput_mbps, 0) / 2);                          -- 200Mbps -> 100

        -- Weights reflect what most directly drives perceived call quality:
        -- drop/failure behavior first, then latency/jitter, then throughput.
        v_score := (v_call_drop_score  * 0.30)
                 + (v_rrc_score        * 0.20)
                 + (v_latency_score    * 0.20)
                 + (v_pkt_drop_score   * 0.15)
                 + (v_jitter_score     * 0.10)
                 + (v_throughput_score * 0.05);

        RETURN ROUND(v_score, 3);
    END rule_based_qoe;

    FUNCTION qoe_band(p_score IN NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
    BEGIN
        RETURN CASE
            WHEN p_score >= 85 THEN 'EXCELLENT'
            WHEN p_score >= 70 THEN 'GOOD'
            WHEN p_score >= 50 THEN 'FAIR'
            WHEN p_score >= 30 THEN 'POOR'
            ELSE 'CRITICAL'
        END;
    END qoe_band;

    PROCEDURE score_site_qoe_rule_based(
        p_site_id IN NUMBER,
        p_as_of   IN TIMESTAMP DEFAULT SYSTIMESTAMP
    ) IS
        v_score NUMBER;
        v_kpi   network_kpi%ROWTYPE;
    BEGIN
        SELECT * INTO v_kpi
        FROM (
            SELECT * FROM network_kpi
            WHERE site_id = p_site_id AND kpi_ts <= p_as_of
            ORDER BY kpi_ts DESC
        )
        WHERE ROWNUM = 1;

        v_score := rule_based_qoe(
            v_kpi.latency_ms, v_kpi.jitter_ms, v_kpi.packet_drop_rate,
            v_kpi.call_drop_rate, v_kpi.rrc_setup_success_rate, v_kpi.throughput_mbps
        );

        -- MERGE, not INSERT: the hourly scheduler job re-runs this for every
        -- site every hour, and if no new KPI reading has landed since the
        -- last run this would otherwise re-insert the same (site_id,
        -- score_ts, model_version) and violate uq_qoe_site_ts_model.
        MERGE INTO qoe_score tgt
        USING (SELECT p_site_id AS site_id, v_kpi.kpi_ts AS score_ts FROM dual) src
        ON (tgt.site_id = src.site_id AND tgt.score_ts = src.score_ts AND tgt.model_version = 'RULE_BASED_V1')
        WHEN MATCHED THEN UPDATE SET
            tgt.predicted_qoe_score = v_score,
            tgt.qoe_band = qoe_band(v_score)
        WHEN NOT MATCHED THEN INSERT (site_id, score_ts, predicted_qoe_score, qoe_band, model_version)
            VALUES (p_site_id, v_kpi.kpi_ts, v_score, qoe_band(v_score), 'RULE_BASED_V1');

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL; -- no KPI reading yet for this site; nothing to score
    END score_site_qoe_rule_based;

END pkg_qoe_scoring;
/


CREATE OR REPLACE PACKAGE pkg_triage AS

    -- Composite customer-impact score (0-100): blends the QoE gap with how
    -- much high-value ARPU sits behind the site, so a mediocre-but-busy
    -- consumer site doesn't drown out a small site full of enterprise lines.
    FUNCTION customer_impact_score(
        p_qoe_score        IN NUMBER,
        p_high_value_count IN NUMBER,
        p_subscriber_count IN NUMBER,
        p_total_arpu       IN NUMBER
    ) RETURN NUMBER DETERMINISTIC;

    -- Technical severity (0-100) from the LSTM's forward-looking failure
    -- signals plus current alarm pressure.
    FUNCTION technical_severity_score(
        p_predicted_drop_rate    IN NUMBER,
        p_predicted_failure_prob IN NUMBER,
        p_critical_alarm_count   IN NUMBER
    ) RETURN NUMBER DETERMINISTIC;

    -- Rebuilds the triage queue for one prediction timestamp: joins the
    -- latest LSTM forecast + QoE score + subscriber value mix per site,
    -- ranks by composite score, and flags churn risk for high-value
    -- subscribers sitting behind a sustained QoE dip.
    PROCEDURE build_triage_queue(p_prediction_ts IN TIMESTAMP);

    -- Sets SUBSCRIBER.churn_flag = 'Y' for high-value subscribers at a site
    -- whose QoE has stayed below p_threshold for p_consecutive_hours or more.
    PROCEDURE flag_churn_risk(
        p_site_id            IN NUMBER,
        p_threshold           IN NUMBER DEFAULT 50,
        p_consecutive_hours   IN NUMBER DEFAULT 3
    );

END pkg_triage;
/

CREATE OR REPLACE PACKAGE BODY pkg_triage AS

    FUNCTION customer_impact_score(
        p_qoe_score        IN NUMBER,
        p_high_value_count IN NUMBER,
        p_subscriber_count IN NUMBER,
        p_total_arpu       IN NUMBER
    ) RETURN NUMBER DETERMINISTIC IS
        v_qoe_gap      NUMBER;
        v_value_weight NUMBER;
    BEGIN
        v_qoe_gap := GREATEST(0, 100 - NVL(p_qoe_score, 100));

        -- Value weight in [1.0, 2.5]: up to +1.0 when every subscriber on
        -- the site is high-value, plus up to +0.5 more when average ARPU
        -- per subscriber is at/above a $200 reference point.
        v_value_weight := 1
            + LEAST(1,   NVL(p_high_value_count, 0) / NULLIF(p_subscriber_count, 0))
            + LEAST(0.5, NVL(p_total_arpu, 0) / NULLIF(p_subscriber_count, 0) / 200);

        RETURN ROUND(LEAST(100, v_qoe_gap * v_value_weight), 3);
    END customer_impact_score;

    FUNCTION technical_severity_score(
        p_predicted_drop_rate    IN NUMBER,
        p_predicted_failure_prob IN NUMBER,
        p_critical_alarm_count   IN NUMBER
    ) RETURN NUMBER DETERMINISTIC IS
    BEGIN
        RETURN ROUND(LEAST(100,
              (NVL(p_predicted_drop_rate, 0)    * 100 * 0.5)
            + (NVL(p_predicted_failure_prob, 0) * 100 * 0.3)
            + (LEAST(NVL(p_critical_alarm_count, 0), 10) * 2) -- cap alarm contribution at 20 pts
        ), 3);
    END technical_severity_score;

    PROCEDURE flag_churn_risk(
        p_site_id            IN NUMBER,
        p_threshold           IN NUMBER DEFAULT 50,
        p_consecutive_hours   IN NUMBER DEFAULT 3
    ) IS
        v_low_streak NUMBER;
    BEGIN
        -- Count the most recent consecutive QoE readings below threshold,
        -- one reading per score_ts (a regression-model row takes priority
        -- over a rule-based fallback row for the same hour, so a site
        -- scored by both models isn't double-counted or double-hour-ed).
        SELECT COUNT(*) INTO v_low_streak
        FROM (
            SELECT predicted_qoe_score,
                   ROW_NUMBER() OVER (ORDER BY score_ts DESC) AS rn
            FROM (
                SELECT score_ts, predicted_qoe_score,
                       ROW_NUMBER() OVER (
                           PARTITION BY score_ts
                           ORDER BY CASE model_version WHEN 'REG_V1' THEN 0 ELSE 1 END
                       ) AS model_rank
                FROM qoe_score
                WHERE site_id = p_site_id
            )
            WHERE model_rank = 1
        )
        WHERE rn <= p_consecutive_hours
          AND predicted_qoe_score < p_threshold;

        IF v_low_streak >= p_consecutive_hours THEN
            UPDATE subscriber
               SET churn_flag = 'Y',
                   churn_flagged_ts = SYSTIMESTAMP
             WHERE home_site_id = p_site_id
               AND segment = 'HIGH_VALUE'
               AND churn_flag = 'N';
            -- No COMMIT here: this procedure runs both standalone (batch,
            -- caller commits) and from the AFTER STATEMENT section of
            -- trg_qoe_churn_check, where issuing a COMMIT would raise
            -- ORA-04092. The caller is responsible for committing.
        END IF;
    END flag_churn_risk;

    PROCEDURE build_triage_queue(p_prediction_ts IN TIMESTAMP) IS
    BEGIN
        -- Clear any prior run for this exact prediction timestamp so
        -- re-running (e.g. after a late-arriving forecast) doesn't duplicate.
        DELETE FROM triage_queue WHERE prediction_ts = p_prediction_ts;

        INSERT INTO triage_queue (
            site_id, prediction_ts, technical_severity_score, customer_impact_score,
            composite_priority_score, priority_rank, high_value_subscribers_affected,
            churn_risk_subscribers, recommended_action
        )
        SELECT
            ranked.site_id,
            p_prediction_ts,
            ranked.tech_score,
            ranked.impact_score,
            ranked.composite_score,
            RANK() OVER (ORDER BY NVL(ranked.composite_score, 0) DESC) AS priority_rank,
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
                pkg_triage.technical_severity_score(
                    p.predicted_drop_rate, p.predicted_failure_prob, NVL(al.critical_alarm_count, 0)
                ) AS tech_score,
                pkg_triage.customer_impact_score(
                    q.predicted_qoe_score, sv.high_value_count, sv.subscriber_count, sv.total_arpu
                ) AS impact_score,
                -- Composite deliberately weights customer impact slightly
                -- above raw technical severity: this is the "triage by
                -- customer impact, not just technical severity" behavior
                -- the use case asks for.
                ROUND(
                    pkg_triage.customer_impact_score(
                        q.predicted_qoe_score, sv.high_value_count, sv.subscriber_count, sv.total_arpu
                    ) * 0.6
                  + pkg_triage.technical_severity_score(
                        p.predicted_drop_rate, p.predicted_failure_prob, NVL(al.critical_alarm_count, 0)
                    ) * 0.4
                , 3) AS composite_score,
                sv.high_value_count,
                sv.flagged_churn_count
            FROM call_event_prediction p
            JOIN qoe_score q
              ON q.site_id = p.site_id
             AND q.score_ts = (
                    SELECT MAX(q2.score_ts) FROM qoe_score q2
                    WHERE q2.site_id = p.site_id AND q2.score_ts <= p.prediction_ts
                 )
            LEFT JOIN vw_site_subscriber_value sv ON sv.site_id = p.site_id
            LEFT JOIN (
                -- Alarms active as of the prediction timestamp: still open,
                -- or cleared after the fact (so a seeded/backfilled incident
                -- window with a known cleared_ts still counts as active
                -- while p_prediction_ts falls inside it).
                SELECT site_id, COUNT(*) AS critical_alarm_count
                FROM alarm_log
                WHERE severity = 'CRITICAL'
                  AND alarm_ts <= p_prediction_ts
                  AND (cleared_ts IS NULL OR cleared_ts > p_prediction_ts)
                GROUP BY site_id
            ) al ON al.site_id = p.site_id
            WHERE p.prediction_ts = p_prediction_ts
        ) ranked;

        -- Refresh churn-risk flags for every site touched by this run.
        FOR r IN (SELECT DISTINCT site_id FROM triage_queue WHERE prediction_ts = p_prediction_ts) LOOP
            flag_churn_risk(r.site_id);
        END LOOP;

        COMMIT;
    END build_triage_queue;

END pkg_triage;
/

COMMIT;
