-- ============================================================================
-- 05_seed_data.sql — synthetic demo dataset (Databricks SQL / Delta Lake)
--
-- Creates 6 sites (2 of which suffer a simulated 3-day network incident),
-- ~400 subscribers, 10 days of hourly KPIs + CDR, alarms/events/tickets tied
-- to the incident window, and periodic NPS/CSAT surveys — same shape as the
-- Oracle version, so the Python pipeline (src/train_call_event_model.py,
-- src/train_qoe_model.py) has real signal to learn from: call failures
-- rising ahead of/during the incident, and QoE/CSAT dipping in response.
--
-- IMPORTANT — this is NOT a row-for-row port of the Oracle script. Oracle's
-- version used PL/SQL FOR loops + DBMS_RANDOM, row by row; Databricks SQL
-- has no such procedural loop, so this rewrites the same generator as
-- set-based SQL using sequence()/explode() + rand(). Same sites, same
-- incident window, same statistical shape (busy-hour multiplier, elevated
-- drop/failure rates during the incident, depressed CSAT/NPS afterward) —
-- but the exact random values and row counts will differ from an Oracle run.
--
-- NOTE: this is a bounded demo dataset (~150-250k CDR rows), not production
-- volume. Expect this script to run for a few minutes on a small warehouse.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Sites
-- ---------------------------------------------------------------------------
INSERT INTO site (site_name, region, latitude, longitude, site_type, capacity_erlangs) VALUES
    ('SITE-A-DOWNTOWN',   'NORTH',   40.712776, -74.005974, 'MACRO',      800),
    ('SITE-B-SUBURB',     'SOUTH',   40.650002, -73.949997, 'MACRO',      500),
    ('SITE-C-INDUSTRIAL', 'EAST',    40.729816, -73.958596, 'MACRO',      400),
    ('SITE-D-CAMPUS',     'WEST',    40.678177, -73.944160, 'SMALL_CELL', 300),
    ('SITE-E-MALL',       'CENTRAL', 40.741895, -73.989308, 'INDOOR',     350),
    ('SITE-F-RURAL',      'NORTH',   40.803680, -73.964462, 'MACRO',      200);

-- ---------------------------------------------------------------------------
-- Subscribers (~400), round-robined across sites, 20/40/40 segment split
-- (i%10 IN (0,1) -> HIGH_VALUE, (2,3,4,5) -> MEDIUM_VALUE, else LOW_VALUE —
-- same split as Oracle's CASE MOD(i,10) block)
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Hourly KPIs, 10 days x 24 hours x 6 sites.
-- Incident window: SITE-C-INDUSTRIAL and SITE-E-MALL, days 7-9 of the
-- 10-day history (72 hours) — same window Oracle used.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- CDR: for every (site, hour), generate call_count call rows via
-- LATERAL VIEW explode(sequence(...)) — the set-based replacement for
-- Oracle's "FOR c IN 1..v_call_count LOOP". Result thresholds
-- (call_drop / pkt_drop*2 / rrc-failure) reuse the same KPI row so the
-- CDR outcome mix matches the KPI severity for that site-hour, same as
-- the Oracle version.
-- ---------------------------------------------------------------------------
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

-- One row per call with its outcome roll (0-1) and start-time offset fixed
-- up front, so the later result/duration CASE expressions all agree with
-- each other instead of each re-rolling rand() independently.
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
    END AS result
FROM _cdr_rolls;

INSERT INTO cdr (call_id, subscriber_id, site_id, call_start_ts, call_end_ts, duration_sec, call_type, call_result, termination_cause_code)
SELECT
    concat('CALL-', date_format(cc.hour_ts, 'yyyyMMddHH'), '-', cc.site_id, '-', cc.call_num) AS call_id,
    element_at(ss.sub_ids, CAST(FLOOR(rand() * ss.sub_count) AS INT) + 1)                      AS subscriber_id,
    cc.site_id,
    cc.hour_ts + (cc.start_offset_sec * INTERVAL 1 SECONDS)                                    AS call_start_ts,
    CASE WHEN cc.result IN ('SUCCESS', 'DROPPED')
         THEN cc.hour_ts + (cc.start_offset_sec * INTERVAL 1 SECONDS) + (d.duration_sec * INTERVAL 1 SECONDS)
         ELSE NULL END                                                                         AS call_end_ts,
    d.duration_sec,
    'VOICE'                                                                                    AS call_type,
    cc.result                                                                                  AS call_result,
    CASE cc.result WHEN 'SUCCESS' THEN NULL WHEN 'DROPPED' THEN 16 WHEN 'FAILED' THEN 34 ELSE 22 END AS termination_cause_code
FROM _cdr_calls cc
JOIN _site_subs ss ON ss.site_id = cc.site_id
CROSS JOIN LATERAL (
    SELECT CASE cc.result
        WHEN 'SUCCESS' THEN CAST(rand() * 590 + 10 AS INT)   -- 10-600s
        WHEN 'DROPPED' THEN CAST(rand() * 115 + 5 AS INT)    -- 5-120s
        ELSE 0 END AS duration_sec
) d;

-- ---------------------------------------------------------------------------
-- Alarms + network events tied to the incident window (bad sites only)
-- ---------------------------------------------------------------------------
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

-- Tickets from affected subscribers during the incident: 20 per bad site,
-- opened at a random point in the 72h incident window, resolved 30-600 min
-- later — same as Oracle's "FOR t IN 1..20 LOOP" per bad site.
INSERT INTO ticket (subscriber_id, site_id, opened_ts, closed_ts, resolution_time_min, category, priority, root_cause)
SELECT
    element_at(ss.sub_ids, CAST(FLOOR(rand() * ss.sub_count) AS INT) + 1) AS subscriber_id,
    bad.site_id,
    opened_ts,
    opened_ts + (resolution_min * 60 * INTERVAL 1 SECONDS)                AS closed_ts,
    resolution_min,
    'DROPPED_CALLS',
    'P2',
    'Backhaul link degradation'
FROM (SELECT site_id FROM site WHERE site_name IN ('SITE-C-INDUSTRIAL', 'SITE-E-MALL')) bad
JOIN _site_subs ss ON ss.site_id = bad.site_id
LATERAL VIEW explode(sequence(1, 20)) t AS ticket_num
CROSS JOIN LATERAL (
    SELECT
        (date_trunc('DAY', current_timestamp()) - INTERVAL 3 DAYS) + (CAST(rand() * 259200 AS INT) * INTERVAL 1 SECONDS) AS opened_ts,
        CAST(rand() * 570 + 30 AS INT) AS resolution_min
) g;

-- ---------------------------------------------------------------------------
-- CSAT/NPS surveys — one every ~7 days per subscriber; depressed for
-- subscribers whose home site was mid-incident (or just after) at survey
-- time. Same schedule as Oracle: first survey 3 days into the 10-day
-- history, then every 7 days until now.
-- ---------------------------------------------------------------------------
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
    date_trunc('DAY', current_timestamp()) - INTERVAL 7 DAYS,   -- start + 3 days into the 10-day history
    date_trunc('DAY', current_timestamp()),                     -- last survey <= today, same bound Oracle's WHILE loop hit
    INTERVAL 7 DAYS
)) sv AS survey_ts;

-- ---------------------------------------------------------------------------
-- Backfill call_volume_hourly for the whole seeded window so the LSTM
-- pipeline and views have data immediately (normally the scheduled job in
-- 04_jobs_workflow.yml does this hourly on an ongoing basis).
-- ---------------------------------------------------------------------------
DECLARE OR REPLACE VARIABLE v_start_ts TIMESTAMP DEFAULT date_trunc('DAY', current_timestamp()) - INTERVAL 10 DAYS;
DECLARE OR REPLACE VARIABLE v_end_ts   TIMESTAMP DEFAULT date_trunc('DAY', current_timestamp()) + INTERVAL 1 DAYS;

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
    WHERE call_start_ts >= v_start_ts AND call_start_ts < v_end_ts
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

-- No COMMIT needed: Databricks SQL autocommits every DDL/DML statement.
