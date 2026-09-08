"""Feature engineering shared by training and inference: turns the flat
per-site-per-hour table from VW_SITE_HOURLY_FEATURES into fixed-length
lookback windows for the LSTM, with next-horizon targets."""
from dataclasses import dataclass

import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler

FEATURE_COLUMNS = [
    "total_calls",
    "dropped_calls",
    "failed_calls",
    "blocked_calls",
    "success_rate",
    "latency_ms",
    "jitter_ms",
    "packet_drop_rate",
    "call_drop_rate",
    "rrc_setup_success_rate",
    "throughput_mbps",
    "alarm_count",
    "critical_alarm_count",
    "event_count",
    "hour_sin",
    "hour_cos",
]

TARGET_COLUMNS = ["predicted_call_volume", "predicted_drop_rate", "predicted_failure_prob"]


def _add_cyclical_hour(df: pd.DataFrame) -> pd.DataFrame:
    hour_of_day = df["hour_ts"].dt.hour
    df["hour_sin"] = np.sin(2 * np.pi * hour_of_day / 24)
    df["hour_cos"] = np.cos(2 * np.pi * hour_of_day / 24)
    return df


def _densify_hourly(site_df: pd.DataFrame) -> pd.DataFrame:
    """Reindexes a single site's rows onto a contiguous hourly range,
    zero-filling gaps (an hour with literally zero call activity)."""
    full_range = pd.date_range(site_df["hour_ts"].min(), site_df["hour_ts"].max(), freq="h")
    site_df = site_df.set_index("hour_ts").reindex(full_range)
    site_df.index.name = "hour_ts"
    fill_zero = [c for c in FEATURE_COLUMNS if c not in ("hour_sin", "hour_cos") and c in site_df.columns]
    site_df[fill_zero] = site_df[fill_zero].fillna(0)
    site_df["success_rate"] = site_df["success_rate"].fillna(1.0)
    site_df["rrc_setup_success_rate"] = site_df["rrc_setup_success_rate"].fillna(1.0)
    site_df = site_df.ffill().fillna(0)
    return site_df.reset_index()


@dataclass
class WindowedDataset:
    X: np.ndarray            # (n_samples, lookback, n_features)
    y: np.ndarray             # (n_samples, 3) -> call_volume, drop_rate, failure_prob
    site_ids: np.ndarray      # (n_samples,)
    target_hour_ts: np.ndarray  # (n_samples,) — the hour each y row describes
    scaler: StandardScaler


def build_windowed_dataset(
    raw_df: pd.DataFrame,
    lookback_hours: int,
    horizon_hours: int,
    scaler: StandardScaler | None = None,
) -> WindowedDataset:
    """Builds sliding [t-lookback : t] -> target-at-(t+horizon) samples,
    grouped per site so windows never cross a site boundary."""
    df = raw_df.copy()
    df = _add_cyclical_hour(df)

    X_list, y_list, site_list, ts_list = [], [], [], []

    for site_id, site_df in df.groupby("site_id"):
        site_df = site_df.sort_values("hour_ts")
        site_df = _densify_hourly(site_df)
        site_df = _add_cyclical_hour(site_df)

        values = site_df[FEATURE_COLUMNS].to_numpy(dtype=float)
        total_calls = site_df["total_calls"].to_numpy(dtype=float)
        dropped = site_df["dropped_calls"].to_numpy(dtype=float)
        failed = site_df["failed_calls"].to_numpy(dtype=float)
        blocked = site_df["blocked_calls"].to_numpy(dtype=float)
        hour_ts = site_df["hour_ts"].to_numpy()

        n = len(site_df)
        for start in range(0, n - lookback_hours - horizon_hours + 1):
            end = start + lookback_hours
            target_idx = end + horizon_hours - 1

            window = values[start:end]
            target_total = total_calls[target_idx]
            target_drop_rate = dropped[target_idx] / target_total if target_total > 0 else 0.0
            target_failure_prob = (
                (dropped[target_idx] + failed[target_idx] + blocked[target_idx]) / target_total
                if target_total > 0 else 0.0
            )

            X_list.append(window)
            y_list.append([target_total, target_drop_rate, target_failure_prob])
            site_list.append(site_id)
            ts_list.append(hour_ts[target_idx])

    X = np.array(X_list)
    y = np.array(y_list)

    n_samples, lookback, n_features = X.shape
    if scaler is None:
        scaler = StandardScaler()
        flat = X.reshape(-1, n_features)
        scaler.fit(flat)

    X_scaled = scaler.transform(X.reshape(-1, n_features)).reshape(n_samples, lookback, n_features)

    return WindowedDataset(
        X=X_scaled,
        y=y,
        site_ids=np.array(site_list),
        target_hour_ts=np.array(ts_list),
        scaler=scaler,
    )


@dataclass
class LatestWindows:
    X: np.ndarray             # (n_sites, lookback, n_features)
    site_ids: np.ndarray      # (n_sites,)
    last_observed_ts: np.ndarray  # (n_sites,) — the most recent hour actually observed


def build_latest_windows(
    raw_df: pd.DataFrame,
    lookback_hours: int,
    scaler: StandardScaler,
) -> LatestWindows:
    """Builds one lookback window per site from its most recent
    `lookback_hours` of history, for feeding straight into inference."""
    df = raw_df.copy()
    df = _add_cyclical_hour(df)

    X_list, site_list, ts_list = [], [], []

    for site_id, site_df in df.groupby("site_id"):
        site_df = site_df.sort_values("hour_ts")
        site_df = _densify_hourly(site_df)
        site_df = _add_cyclical_hour(site_df)

        if len(site_df) < lookback_hours:
            continue

        tail = site_df.tail(lookback_hours)
        window = tail[FEATURE_COLUMNS].to_numpy(dtype=float)

        X_list.append(window)
        site_list.append(site_id)
        ts_list.append(tail["hour_ts"].iloc[-1])

    X = np.array(X_list)
    n_sites, lookback, n_features = X.shape
    X_scaled = scaler.transform(X.reshape(-1, n_features)).reshape(n_sites, lookback, n_features)

    return LatestWindows(
        X=X_scaled,
        site_ids=np.array(site_list),
        last_observed_ts=np.array(ts_list),
    )
