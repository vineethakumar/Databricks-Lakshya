-- ============================================================================
-- 05_seed_data.sql — synthetic demo dataset
--
-- Creates 6 sites (2 of which suffer a simulated 3-day network incident),
-- ~400 subscribers, 10 days of hourly KPIs + CDR, alarms/events/tickets tied
-- to the incident window, and periodic NPS/CSAT surveys. This gives the
-- Python pipeline (src/train_call_event_model.py, src/train_qoe_model.py)
-- real signal to learn from: call failures rising ahead of/during the
-- incident, and QoE/CSAT dipping in response.
--
-- NOTE: this is a bounded demo dataset (~150-250k CDR rows), not production
-- volume. Expect this script to run for one to a few minutes.
-- ============================================================================

SET SERVEROUTPUT ON;

-- ---------------------------------------------------------------------------
-- Sites
-- ---------------------------------------------------------------------------
INSERT INTO site (site_name, region, latitude, longitude, site_type, capacity_erlangs) VALUES
    ('SITE-A-DOWNTOWN',  'NORTH',   40.712776, -74.005974, 'MACRO', 800);
INSERT INTO site (site_name, region, latitude, longitude, site_type, capacity_erlangs) VALUES
    ('SITE-B-SUBURB',    'SOUTH',   40.650002, -73.949997, 'MACRO', 500);
INSERT INTO site (site_name, region, latitude, longitude, site_type, capacity_erlangs) VALUES
    ('SITE-C-INDUSTRIAL','EAST',    40.729816, -73.958596, 'MACRO', 400);
INSERT INTO site (site_name, region, latitude, longitude, site_type, capacity_erlangs) VALUES
    ('SITE-D-CAMPUS',    'WEST',    40.678177, -73.944160, 'SMALL_CELL', 300);
INSERT INTO site (site_name, region, latitude, longitude, site_type, capacity_erlangs) VALUES
    ('SITE-E-MALL',      'CENTRAL', 40.741895, -73.989308, 'INDOOR', 350);
INSERT INTO site (site_name, region, latitude, longitude, site_type, capacity_erlangs) VALUES
    ('SITE-F-RURAL',     'NORTH',   40.803680, -73.964462, 'MACRO', 200);
COMMIT;

-- ---------------------------------------------------------------------------
-- Subscribers (~400), round-robined across sites, 20/40/40 segment split
-- ---------------------------------------------------------------------------
DECLARE
    TYPE t_site_ids IS TABLE OF site.site_id%TYPE;
    v_site_ids   t_site_ids;
    v_segment    VARCHAR2(20);
    v_arpu       NUMBER;
    v_tenure     NUMBER;
BEGIN
    SELECT site_id BULK COLLECT INTO v_site_ids FROM site ORDER BY site_id;

    FOR i IN 1..400 LOOP
        CASE MOD(i, 10)
            WHEN 0 THEN v_segment := 'HIGH_VALUE';   v_arpu := ROUND(80  + DBMS_RANDOM.VALUE(0,70), 2);
            WHEN 1 THEN v_segment := 'HIGH_VALUE';   v_arpu := ROUND(80  + DBMS_RANDOM.VALUE(0,70), 2);
            WHEN 2 THEN v_segment := 'MEDIUM_VALUE'; v_arpu := ROUND(30  + DBMS_RANDOM.VALUE(0,50), 2);
            WHEN 3 THEN v_segment := 'MEDIUM_VALUE'; v_arpu := ROUND(30  + DBMS_RANDOM.VALUE(0,50), 2);
            WHEN 4 THEN v_segment := 'MEDIUM_VALUE'; v_arpu := ROUND(30  + DBMS_RANDOM.VALUE(0,50), 2);
            WHEN 5 THEN v_segment := 'MEDIUM_VALUE'; v_arpu := ROUND(30  + DBMS_RANDOM.VALUE(0,50), 2);
            ELSE        v_segment := 'LOW_VALUE';    v_arpu := ROUND(10  + DBMS_RANDOM.VALUE(0,20), 2);
        END CASE;

        v_tenure := TRUNC(DBMS_RANDOM.VALUE(1, 96));

        INSERT INTO subscriber (msisdn, segment, plan_type, tenure_months, monthly_arpu, home_site_id)
        VALUES (
            '1555' || LPAD(i, 7, '0'),
            v_segment,
            CASE WHEN v_segment = 'HIGH_VALUE' THEN 'UNLIMITED_PREMIUM' ELSE 'STANDARD' END,
            v_tenure,
            v_arpu,
            v_site_ids(MOD(i, v_site_ids.COUNT) + 1)
        );
    END LOOP;
    COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- Hourly KPIs + CDR, incidents, alarms/events/tickets, CSAT/NPS surveys
-- ---------------------------------------------------------------------------
DECLARE
    v_start_date   TIMESTAMP := TRUNC(SYSTIMESTAMP) - INTERVAL '10' DAY;
    v_end_date     TIMESTAMP := TRUNC(SYSTIMESTAMP);
    v_hour         TIMESTAMP;

    TYPE t_site_rec IS RECORD (site_id NUMBER, is_bad_site CHAR(1), is_high_capacity CHAR(1));
    TYPE t_site_tab IS TABLE OF t_site_rec;
    v_sites        t_site_tab;

    -- Incident window: days 7-9 of the 10-day history (72 hours)
    v_incident_start TIMESTAMP := v_start_date + INTERVAL '7' DAY;
    v_incident_end    TIMESTAMP := v_start_date + INTERVAL '10' DAY;

    v_is_incident  BOOLEAN;
    v_hour_of_day  NUMBER;
    v_busy_factor  NUMBER;
    v_base_calls   NUMBER;
    v_call_count   NUMBER;

    v_latency      NUMBER; v_jitter NUMBER; v_pkt_drop NUMBER;
    v_call_drop    NUMBER; v_rrc_success NUMBER; v_throughput NUMBER;

    TYPE t_sub_ids IS TABLE OF subscriber.subscriber_id%TYPE;
    v_sub_ids      t_sub_ids;

    v_roll         NUMBER;
    v_result       VARCHAR2(20);
    v_call_ts      TIMESTAMP;
    v_duration     NUMBER;
BEGIN
    SELECT site_id,
           CASE WHEN site_name IN ('SITE-C-INDUSTRIAL','SITE-E-MALL') THEN 'Y' ELSE 'N' END,
           CASE WHEN capacity_erlangs >= 500 THEN 'Y' ELSE 'N' END
      BULK COLLECT INTO v_sites
      FROM site ORDER BY site_id;

    FOR si IN 1..v_sites.COUNT LOOP

        SELECT subscriber_id BULK COLLECT INTO v_sub_ids
        FROM subscriber WHERE home_site_id = v_sites(si).site_id;

        CONTINUE WHEN v_sub_ids.COUNT = 0;

        v_hour := v_start_date;
        WHILE v_hour < v_end_date LOOP

            v_is_incident := (v_sites(si).is_bad_site = 'Y')
                              AND v_hour >= v_incident_start
                              AND v_hour <  v_incident_end;

            v_hour_of_day := TO_NUMBER(TO_CHAR(v_hour, 'HH24'));
            v_busy_factor := CASE
                WHEN v_hour_of_day BETWEEN 8 AND 22 THEN 1.5
                ELSE 0.4
            END;

            -- ---- KPI simulation ----
            IF v_is_incident THEN
                v_latency     := ROUND(120 + DBMS_RANDOM.VALUE(0, 80), 2);
                v_jitter      := ROUND(15  + DBMS_RANDOM.VALUE(0, 10), 2);
                v_pkt_drop    := ROUND(0.04 + DBMS_RANDOM.VALUE(0, 0.05), 4);
                v_call_drop   := ROUND(0.12 + DBMS_RANDOM.VALUE(0, 0.15), 4);
                v_rrc_success := ROUND(0.75 - DBMS_RANDOM.VALUE(0, 0.15), 4);
                v_throughput  := ROUND(20 + DBMS_RANDOM.VALUE(0, 15), 2);
            ELSE
                v_latency     := ROUND(25 + DBMS_RANDOM.VALUE(0, 20), 2);
                v_jitter      := ROUND(2  + DBMS_RANDOM.VALUE(0, 3), 2);
                v_pkt_drop    := ROUND(0.001 + DBMS_RANDOM.VALUE(0, 0.005), 4);
                v_call_drop   := ROUND(0.005 + DBMS_RANDOM.VALUE(0, 0.01), 4);
                v_rrc_success := ROUND(0.97 + DBMS_RANDOM.VALUE(0, 0.03), 4);
                v_throughput  := ROUND(80 + DBMS_RANDOM.VALUE(0, 60), 2);
            END IF;

            INSERT INTO network_kpi (
                site_id, kpi_ts, latency_ms, jitter_ms, packet_drop_rate,
                call_drop_rate, rrc_setup_success_rate, throughput_mbps
            ) VALUES (
                v_sites(si).site_id, v_hour, v_latency, v_jitter, v_pkt_drop,
                v_call_drop, LEAST(v_rrc_success, 1), v_throughput
            );

            -- ---- CDR simulation ----
            v_base_calls := CASE WHEN v_sites(si).is_high_capacity = 'Y' THEN 40 ELSE 20 END;
            v_call_count := GREATEST(1, ROUND(v_base_calls * v_busy_factor * DBMS_RANDOM.VALUE(0.7, 1.3)));

            FOR c IN 1..v_call_count LOOP
                v_roll := DBMS_RANDOM.VALUE(0, 1);
                IF v_roll < v_call_drop THEN
                    v_result := 'DROPPED';
                ELSIF v_roll < v_call_drop + (v_pkt_drop * 2) THEN
                    v_result := 'FAILED';
                ELSIF v_roll < v_call_drop + (v_pkt_drop * 2) + (1 - v_rrc_success) * 0.3 THEN
                    v_result := 'BLOCKED';
                ELSE
                    v_result := 'SUCCESS';
                END IF;

                v_call_ts  := v_hour + NUMTODSINTERVAL(DBMS_RANDOM.VALUE(0, 3599), 'SECOND');
                v_duration := CASE WHEN v_result = 'SUCCESS' THEN TRUNC(DBMS_RANDOM.VALUE(10, 600))
                                   WHEN v_result = 'DROPPED' THEN TRUNC(DBMS_RANDOM.VALUE(5, 120))
                                   ELSE 0 END;

                INSERT INTO cdr (
                    call_id, subscriber_id, site_id, call_start_ts, call_end_ts,
                    duration_sec, call_type, call_result, termination_cause_code
                ) VALUES (
                    'CALL-' || TO_CHAR(v_hour, 'YYYYMMDDHH24') || '-' || v_sites(si).site_id || '-' || c,
                    v_sub_ids(TRUNC(DBMS_RANDOM.VALUE(1, v_sub_ids.COUNT + 1))),
                    v_sites(si).site_id,
                    v_call_ts,
                    CASE WHEN v_result IN ('SUCCESS','DROPPED') THEN v_call_ts + NUMTODSINTERVAL(v_duration, 'SECOND') ELSE NULL END,
                    v_duration,
                    'VOICE',
                    v_result,
                    CASE v_result WHEN 'SUCCESS' THEN NULL WHEN 'DROPPED' THEN 16 WHEN 'FAILED' THEN 34 ELSE 22 END
                );
            END LOOP;

            v_hour := v_hour + INTERVAL '1' HOUR;
        END LOOP;
    END LOOP;
    COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- Alarms + network events tied to the incident window (bad sites only)
-- ---------------------------------------------------------------------------
DECLARE
    v_start_date      TIMESTAMP := TRUNC(SYSTIMESTAMP) - INTERVAL '10' DAY;
    v_incident_start  TIMESTAMP := v_start_date + INTERVAL '7' DAY;
    v_incident_end    TIMESTAMP := v_start_date + INTERVAL '10' DAY;
BEGIN
    FOR s IN (SELECT site_id FROM site WHERE site_name IN ('SITE-C-INDUSTRIAL','SITE-E-MALL')) LOOP
        INSERT INTO alarm_log (site_id, alarm_ts, cleared_ts, alarm_type, severity, alarm_description)
        VALUES (s.site_id, v_incident_start, v_incident_end, 'CAPACITY_DEGRADATION', 'CRITICAL',
                'Sustained elevated call-drop rate and RRC setup failures.');

        INSERT INTO network_event (site_id, event_ts, event_type, event_severity, event_description)
        VALUES (s.site_id, v_incident_start, 'FIBER_LINK_DEGRADATION', 'SEVERE',
                'Backhaul link degradation detected upstream of site.');

        -- Tickets from affected subscribers during the incident
        FOR t IN 1..20 LOOP
            DECLARE
                v_sub_id     subscriber.subscriber_id%TYPE;
                v_opened     TIMESTAMP := v_incident_start + NUMTODSINTERVAL(DBMS_RANDOM.VALUE(0, 259200), 'SECOND');
                v_resolution NUMBER := TRUNC(DBMS_RANDOM.VALUE(30, 600));
            BEGIN
                SELECT subscriber_id INTO v_sub_id FROM (
                    SELECT subscriber_id FROM subscriber
                    WHERE home_site_id = s.site_id
                    ORDER BY DBMS_RANDOM.VALUE
                ) WHERE ROWNUM = 1;

                INSERT INTO ticket (
                    subscriber_id, site_id, opened_ts, closed_ts, resolution_time_min,
                    category, priority, root_cause
                ) VALUES (
                    v_sub_id, s.site_id, v_opened, v_opened + NUMTODSINTERVAL(v_resolution * 60, 'SECOND'),
                    v_resolution, 'DROPPED_CALLS', 'P2', 'Backhaul link degradation'
                );
            END;
        END LOOP;
    END LOOP;
    COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- CSAT/NPS surveys — one every ~7 days per subscriber; depressed for
-- subscribers whose home site was mid-incident (or just after) at survey time
-- ---------------------------------------------------------------------------
DECLARE
    v_start_date TIMESTAMP := TRUNC(SYSTIMESTAMP) - INTERVAL '10' DAY;
    v_survey_ts  TIMESTAMP;
    v_nps        NUMBER;
    v_csat       NUMBER;
BEGIN
    FOR sub IN (
        SELECT s.subscriber_id, s.segment, si.site_name
        FROM subscriber s JOIN site si ON si.site_id = s.home_site_id
    ) LOOP
        v_survey_ts := v_start_date + INTERVAL '3' DAY;  -- one mid-window survey
        WHILE v_survey_ts < SYSTIMESTAMP LOOP
            IF sub.site_name IN ('SITE-C-INDUSTRIAL','SITE-E-MALL')
               AND v_survey_ts >= v_start_date + INTERVAL '7' DAY THEN
                v_nps  := TRUNC(DBMS_RANDOM.VALUE(-80, -10));
                v_csat := TRUNC(DBMS_RANDOM.VALUE(1, 3));
            ELSE
                v_nps  := TRUNC(DBMS_RANDOM.VALUE(10, 70));
                v_csat := TRUNC(DBMS_RANDOM.VALUE(3, 6));
            END IF;

            INSERT INTO customer_satisfaction (subscriber_id, survey_ts, nps_score, csat_score, channel)
            VALUES (sub.subscriber_id, v_survey_ts, v_nps, LEAST(v_csat, 5), 'SMS');

            v_survey_ts := v_survey_ts + INTERVAL '7' DAY;
        END LOOP;
    END LOOP;
    COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- Backfill call_volume_hourly for the whole seeded window so the LSTM
-- pipeline and views have data immediately (normally the scheduler job does
-- this hourly on an ongoing basis — see 04_triggers_scheduler.sql).
-- ---------------------------------------------------------------------------
BEGIN
    pkg_feature_engineering.build_call_volume_hourly(
        p_start_ts => TRUNC(SYSTIMESTAMP) - INTERVAL '10' DAY,
        p_end_ts   => TRUNC(SYSTIMESTAMP) + INTERVAL '1' DAY
    );
END;
/

COMMIT;
