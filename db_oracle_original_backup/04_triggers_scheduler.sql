-- ============================================================================
-- 04_triggers_scheduler.sql — automation
--   TRG_QOE_CHURN_CHECK : re-checks churn risk whenever a fresh QoE score
--                         lands for a site (event-driven, not just batch)
--   Scheduler jobs      : hourly refresh of the CDR aggregate + rule-based
--                         QoE fallback score
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Compound trigger: every new QOE_SCORE insert re-evaluates churn risk for
-- that site immediately, rather than waiting for the next triage batch run.
--
-- This has to be a compound trigger, not a plain row-level AFTER INSERT
-- trigger: PKG_TRIAGE.flag_churn_risk queries QOE_SCORE itself (to look at
-- the recent score history), and a row-level trigger querying the very
-- table it fires on raises ORA-04091 (mutating table). Collecting the
-- affected site_ids during the row-level section and running the check
-- once per row from the AFTER STATEMENT section defers that query until
-- the statement's inserts are complete, which is allowed. (flag_churn_risk
-- also does not COMMIT internally, since COMMIT is not permitted from
-- inside any trigger section — the enclosing transaction commits it.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_qoe_churn_check
FOR INSERT ON qoe_score
COMPOUND TRIGGER

    TYPE t_site_ids IS TABLE OF qoe_score.site_id%TYPE;
    v_site_ids t_site_ids := t_site_ids();

    AFTER EACH ROW IS
    BEGIN
        v_site_ids.EXTEND;
        v_site_ids(v_site_ids.LAST) := :NEW.site_id;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
    BEGIN
        FOR i IN 1 .. v_site_ids.COUNT LOOP
            pkg_triage.flag_churn_risk(v_site_ids(i));
        END LOOP;
    END AFTER STATEMENT;

END trg_qoe_churn_check;
/

-- ---------------------------------------------------------------------------
-- Scheduler job: rebuild CALL_VOLUME_HOURLY for the trailing 2 hours, every
-- hour at :05. Trailing window (not just the latest hour) absorbs CDRs that
-- land slightly late.
-- ---------------------------------------------------------------------------
BEGIN
    DBMS_SCHEDULER.DROP_JOB('JOB_REFRESH_CALL_VOLUME', force => TRUE);
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -27475 THEN RAISE; END IF; -- ignore "job does not exist"
END;
/

BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'JOB_REFRESH_CALL_VOLUME',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
            BEGIN
                pkg_feature_engineering.build_call_volume_hourly(
                    p_start_ts => TRUNC(SYSTIMESTAMP, 'HH24') - INTERVAL '2' HOUR,
                    p_end_ts   => TRUNC(SYSTIMESTAMP, 'HH24') + INTERVAL '1' HOUR
                );
            END;
        ]',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=HOURLY; BYMINUTE=5',
        enabled         => TRUE,
        comments        => 'Hourly rebuild of call_volume_hourly from raw CDR (LSTM input feed).'
    );
END;
/

-- ---------------------------------------------------------------------------
-- Scheduler job: rule-based QoE fallback score for every site, every hour
-- at :10 (after the call-volume refresh). The Python regression pipeline
-- normally supersedes this with model_version='REG_V1' rows on its own
-- schedule; this job guarantees a QoE row always exists for triage even if
-- the ML job is delayed or down.
-- ---------------------------------------------------------------------------
BEGIN
    DBMS_SCHEDULER.DROP_JOB('JOB_RULE_BASED_QOE', force => TRUE);
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -27475 THEN RAISE; END IF;
END;
/

BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'JOB_RULE_BASED_QOE',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
            BEGIN
                FOR s IN (SELECT site_id FROM site) LOOP
                    pkg_qoe_scoring.score_site_qoe_rule_based(s.site_id);
                END LOOP;
            END;
        ]',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=HOURLY; BYMINUTE=10',
        enabled         => TRUE,
        comments        => 'Hourly rule-based QoE fallback score per site.'
    );
END;
/

COMMIT;
