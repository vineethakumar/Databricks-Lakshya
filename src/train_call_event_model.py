"""Trains the call-event LSTM (call volume / drop rate / failure
probability forecast) from VW_SITE_HOURLY_FEATURES and saves the artifact.

Usage:
    python -m src.train_call_event_model
"""
import numpy as np
from sklearn.metrics import mean_absolute_error

from . import config
from .data_loader import load_site_hourly_features
from .features import build_windowed_dataset
from .models.call_event_lstm import CallEventLSTM


def main() -> None:
    print("Loading site-hourly features from VW_SITE_HOURLY_FEATURES ...")
    raw_df = load_site_hourly_features()
    print(f"  {len(raw_df)} rows across {raw_df['site_id'].nunique()} sites")

    dataset = build_windowed_dataset(
        raw_df,
        lookback_hours=config.LSTM_LOOKBACK_HOURS,
        horizon_hours=config.LSTM_HORIZON_HOURS,
    )
    print(f"  {dataset.X.shape[0]} training windows "
          f"(lookback={config.LSTM_LOOKBACK_HOURS}h, horizon={config.LSTM_HORIZON_HOURS}h)")

    # Time-ordered split (not random) so we validate on the future, matching
    # how the model will actually be used at inference time.
    order = np.argsort(dataset.target_hour_ts)
    split = int(len(order) * 0.85)
    train_idx, test_idx = order[:split], order[split:]

    model = CallEventLSTM.train(
        dataset.X[train_idx], dataset.y[train_idx], dataset.scaler,
        lookback_hours=config.LSTM_LOOKBACK_HOURS,
    )

    preds = model.predict(dataset.X[test_idx])
    actual = dataset.y[test_idx]
    print("\nHold-out MAE:")
    print(f"  call_volume  : {mean_absolute_error(actual[:, 0], preds[:, 0]):.2f} calls")
    print(f"  drop_rate    : {mean_absolute_error(actual[:, 1], preds[:, 1]):.4f}")
    print(f"  failure_prob : {mean_absolute_error(actual[:, 2], preds[:, 2]):.4f}")

    out_dir = config.MODEL_DIR / "call_event_lstm"
    model.save(out_dir)
    print(f"\nSaved model to {out_dir}")


if __name__ == "__main__":
    main()
