import numpy as np
import pandas as pd

from src.features import build_latest_windows, build_windowed_dataset


def _make_site_df(site_id: int, n_hours: int, start: str = "2026-01-01") -> pd.DataFrame:
    hours = pd.date_range(start, periods=n_hours, freq="h")
    rng = np.random.default_rng(42)
    return pd.DataFrame({
        "site_id": site_id,
        "hour_ts": hours,
        "total_calls": rng.integers(50, 150, n_hours),
        "dropped_calls": rng.integers(0, 5, n_hours),
        "failed_calls": rng.integers(0, 5, n_hours),
        "blocked_calls": rng.integers(0, 3, n_hours),
        "success_rate": rng.uniform(0.9, 1.0, n_hours),
        "latency_ms": rng.uniform(20, 60, n_hours),
        "jitter_ms": rng.uniform(1, 8, n_hours),
        "packet_drop_rate": rng.uniform(0, 0.02, n_hours),
        "call_drop_rate": rng.uniform(0, 0.02, n_hours),
        "rrc_setup_success_rate": rng.uniform(0.9, 1.0, n_hours),
        "throughput_mbps": rng.uniform(40, 120, n_hours),
        "alarm_count": rng.integers(0, 2, n_hours),
        "critical_alarm_count": rng.integers(0, 1, n_hours),
        "event_count": rng.integers(0, 1, n_hours),
        "capacity_erlangs": 500,
        "region": "NORTH",
        "site_type": "MACRO",
    })


def test_build_windowed_dataset_shapes():
    df = pd.concat([_make_site_df(1, 60), _make_site_df(2, 60)], ignore_index=True)

    dataset = build_windowed_dataset(df, lookback_hours=24, horizon_hours=6)

    expected_per_site = 60 - 24 - 6 + 1
    assert dataset.X.shape == (expected_per_site * 2, 24, 16)
    assert dataset.y.shape == (expected_per_site * 2, 3)
    assert set(dataset.site_ids) == {1, 2}
    # targets should be finite and within sane bounds
    assert np.all(dataset.y[:, 0] >= 0)
    assert np.all((dataset.y[:, 1] >= 0) & (dataset.y[:, 1] <= 1))
    assert np.all((dataset.y[:, 2] >= 0) & (dataset.y[:, 2] <= 1))


def test_build_latest_windows_uses_most_recent_hours():
    df = _make_site_df(1, 48)

    dataset = build_windowed_dataset(df, lookback_hours=24, horizon_hours=6)
    latest = build_latest_windows(df, lookback_hours=24, scaler=dataset.scaler)

    assert latest.X.shape == (1, 24, 16)
    assert latest.last_observed_ts[0] == df["hour_ts"].max()
