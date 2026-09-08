"""Synthetic data generator + pure-Python PKG_TRIAGE mirror shared by
scripts/demo_local_no_db.py, scripts/generate_mock_csv.py, and
scripts/demo_from_csv.py.

Same story as db/05_seed_data.sql: 3 sites, one (SITE-C-INDUSTRIAL) hits a
2-day incident partway through the window. Column names match what the
Oracle views produce (db/02_views.sql: VW_SITE_HOURLY_FEATURES /
VW_QOE_TRAINING_DATA) so the exact same src/features.py and src/models/
code paths run whether the data came from Oracle or from here.
"""
import numpy as np
import pandas as pd

rng = np.random.default_rng(7)

SITES = [
    # (site_name, capacity_erlangs, high_value_count, subscriber_count, total_arpu, is_bad_site)
    ("SITE-A-DOWNTOWN",   800, 6, 30, 1800.0, False),
    ("SITE-B-SUBURB",     500, 3, 30, 1100.0, False),
    ("SITE-C-INDUSTRIAL", 400, 9, 30, 2200.0, True),   # the incident site
]
N_DAYS = 8
INCIDENT_START_DAY = 6
INCIDENT_DURATION_HOURS = 48  # spans the last 2 days of the window, so the
                              # incident is still "live" at the most recent
                              # hour of data — otherwise the latest lookback
                              # window used for inference would already be
                              # entirely post-incident and every site would
                              # look identical at "now"
LOOKBACK_HOURS = 24
HORIZON_HOURS = 6


def make_site_hourly_features(site_name: str, capacity: int, is_bad: bool) -> tuple[pd.DataFrame, pd.Timestamp]:
    """KPI + call-volume rows for one site, one row per hour. Mirrors the
    shape of VW_SITE_HOURLY_FEATURES (db/02_views.sql)."""
    start = pd.Timestamp("2026-08-01 00:00:00")
    hours = pd.date_range(start, periods=N_DAYS * 24, freq="h")
    incident_start = start + pd.Timedelta(days=INCIDENT_START_DAY)
    incident_end = incident_start + pd.Timedelta(hours=INCIDENT_DURATION_HOURS)

    rows = []
    for hour in hours:
        is_incident = is_bad and incident_start <= hour < incident_end
        busy = 1.5 if 8 <= hour.hour <= 22 else 0.4

        if is_incident:
            latency, jitter = 120 + rng.uniform(0, 80), 15 + rng.uniform(0, 10)
            pkt_drop, call_drop = 0.04 + rng.uniform(0, 0.05), 0.12 + rng.uniform(0, 0.15)
            rrc_success, throughput = max(0, 0.75 - rng.uniform(0, 0.15)), 20 + rng.uniform(0, 15)
            alarm_count, critical_alarm_count = 1, 1
        else:
            latency, jitter = 25 + rng.uniform(0, 20), 2 + rng.uniform(0, 3)
            pkt_drop, call_drop = 0.001 + rng.uniform(0, 0.005), 0.005 + rng.uniform(0, 0.01)
            rrc_success, throughput = min(1, 0.97 + rng.uniform(0, 0.03)), 80 + rng.uniform(0, 60)
            alarm_count, critical_alarm_count = 0, 0

        base_calls = 40 if capacity >= 500 else 20
        total_calls = max(1, round(base_calls * busy * rng.uniform(0.7, 1.3)))
        dropped = round(total_calls * call_drop)
        failed = round(total_calls * pkt_drop * 2)
        blocked = round(total_calls * (1 - rrc_success) * 0.3)
        success_rate = max(0, 1 - (dropped + failed + blocked) / total_calls)

        rows.append({
            "site_id": site_name, "hour_ts": hour,
            "total_calls": total_calls, "dropped_calls": dropped,
            "failed_calls": failed, "blocked_calls": blocked, "success_rate": success_rate,
            "latency_ms": latency, "jitter_ms": jitter, "packet_drop_rate": pkt_drop,
            "call_drop_rate": call_drop, "rrc_setup_success_rate": rrc_success, "throughput_mbps": throughput,
            "alarm_count": alarm_count, "critical_alarm_count": critical_alarm_count, "event_count": 0,
            "capacity_erlangs": capacity, "region": "DEMO", "site_type": "MACRO",
        })
    return pd.DataFrame(rows), incident_start


def make_qoe_training_rows(site_name: str, is_bad: bool) -> list[dict]:
    """A handful of KPI -> NPS/CSAT rows per segment, spanning normal and
    (for the bad site) degraded conditions, so the regressor sees both.
    Mirrors the shape of VW_QOE_TRAINING_DATA (db/02_views.sql)."""
    rows = []
    for segment in ("HIGH_VALUE", "MEDIUM_VALUE", "LOW_VALUE"):
        for _ in range(40):
            degraded = is_bad and rng.uniform(0, 1) < 0.5
            if degraded:
                latency, jitter = 120 + rng.uniform(0, 80), 15 + rng.uniform(0, 10)
                pkt_drop, call_drop = 0.04 + rng.uniform(0, 0.05), 0.12 + rng.uniform(0, 0.15)
                rrc_success, throughput = max(0, 0.75 - rng.uniform(0, 0.15)), 20 + rng.uniform(0, 15)
                nps, csat = rng.uniform(-80, -10), rng.integers(1, 3)
            else:
                latency, jitter = 25 + rng.uniform(0, 20), 2 + rng.uniform(0, 3)
                pkt_drop, call_drop = 0.001 + rng.uniform(0, 0.005), 0.005 + rng.uniform(0, 0.01)
                rrc_success, throughput = min(1, 0.97 + rng.uniform(0, 0.03)), 80 + rng.uniform(0, 60)
                nps, csat = rng.uniform(10, 70), rng.integers(3, 6)

            rows.append({
                "site_id": site_name,
                "latency_ms": latency, "jitter_ms": jitter, "packet_drop_rate": pkt_drop,
                "call_drop_rate": call_drop, "rrc_setup_success_rate": rrc_success,
                "throughput_mbps": throughput, "segment": segment,
                "nps_score": nps, "csat_score": min(csat, 5),
            })
    return rows


def make_site_meta_row(site_name: str, capacity: int, hv_count: int, sub_count: int, arpu: float, is_bad: bool) -> dict:
    """One row per site: the subscriber-value mix used to weight customer
    impact. Mirrors VW_SITE_SUBSCRIBER_VALUE (db/02_views.sql)."""
    return {
        "site_id": site_name,
        "capacity_erlangs": capacity,
        "high_value_count": hv_count,
        "subscriber_count": sub_count,
        "total_arpu": arpu,
        "is_bad_site": is_bad,
    }


def generate_all() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Generates the full mock dataset: (site_hourly_features, qoe_training_data, site_meta)."""
    site_frames = []
    qoe_rows = []
    meta_rows = []
    for site_name, capacity, hv_count, sub_count, arpu, is_bad in SITES:
        df, _incident_start = make_site_hourly_features(site_name, capacity, is_bad)
        site_frames.append(df)
        qoe_rows.extend(make_qoe_training_rows(site_name, is_bad))
        meta_rows.append(make_site_meta_row(site_name, capacity, hv_count, sub_count, arpu, is_bad))

    raw_df = pd.concat(site_frames, ignore_index=True)
    qoe_df = pd.DataFrame(qoe_rows)
    site_meta_df = pd.DataFrame(meta_rows)
    return raw_df, qoe_df, site_meta_df


# --- Pure-Python mirror of db/03_packages.sql: PKG_TRIAGE -------------------
# Same formulas as the PL/SQL functions, so triage rankings computed here
# match what the real database would produce given the same inputs.

def technical_severity_score(predicted_drop_rate, predicted_failure_prob, critical_alarm_count) -> float:
    return round(min(100,
        predicted_drop_rate * 100 * 0.5
        + predicted_failure_prob * 100 * 0.3
        + min(critical_alarm_count, 10) * 2
    ), 3)


def customer_impact_score(qoe_score, high_value_count, subscriber_count, total_arpu) -> float:
    qoe_gap = max(0, 100 - qoe_score)
    value_weight = (
        1
        + min(1, high_value_count / subscriber_count)
        + min(0.5, (total_arpu / subscriber_count) / 200)
    )
    return round(min(100, qoe_gap * value_weight), 3)


def recommended_action(composite_score: float) -> str:
    if composite_score >= 75:
        return "Dispatch field team immediately; notify high-value accounts proactively."
    if composite_score >= 50:
        return "Schedule capacity/maintenance intervention within 24h."
    if composite_score >= 25:
        return "Monitor; add to next maintenance window."
    return "No action required."
