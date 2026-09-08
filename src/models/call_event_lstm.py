"""LSTM time-series model: forecasts call volume, drop rate, and failure
probability `horizon_hours` ahead from `lookback_hours` of site history."""
from pathlib import Path

import joblib
import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models


def build_model(lookback_hours: int, n_features: int) -> tf.keras.Model:
    inputs = layers.Input(shape=(lookback_hours, n_features), name="site_hourly_window")

    x = layers.LSTM(64, return_sequences=True)(inputs)
    x = layers.Dropout(0.2)(x)
    x = layers.LSTM(32)(x)
    x = layers.Dropout(0.2)(x)
    shared = layers.Dense(32, activation="relu")(x)

    # Three heads: call volume is an unbounded count, drop rate and failure
    # probability are rates in [0, 1] so they get a sigmoid head.
    #
    # The call_volume head deliberately uses a LINEAR (no) activation, not
    # relu: a relu on a single-unit output is prone to dying during early
    # training (if its pre-activation is negative for most examples, its
    # gradient is exactly zero everywhere and it never recovers — observed
    # in practice as call_volume_loss/mae staying frozen across every
    # epoch). Negative predictions are clipped to zero downstream instead
    # (see predict_and_score.py: float(max(0, call_volume))).
    call_volume = layers.Dense(1, name="call_volume")(shared)
    drop_rate = layers.Dense(1, activation="sigmoid", name="drop_rate")(shared)
    failure_prob = layers.Dense(1, activation="sigmoid", name="failure_prob")(shared)

    model = models.Model(inputs=inputs, outputs=[call_volume, drop_rate, failure_prob])
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
        loss={
            "call_volume": "mse",
            "drop_rate": "binary_crossentropy",
            "failure_prob": "binary_crossentropy",
        },
        loss_weights={"call_volume": 1.0, "drop_rate": 5.0, "failure_prob": 5.0},
        metrics={"call_volume": "mae", "drop_rate": "mae", "failure_prob": "mae"},
    )
    return model


class CallEventLSTM:
    """Wraps the Keras model + its feature scaler as a single artifact."""

    def __init__(self, model: tf.keras.Model, scaler, lookback_hours: int):
        self.model = model
        self.scaler = scaler
        self.lookback_hours = lookback_hours

    @classmethod
    def train(
        cls,
        X: np.ndarray,
        y: np.ndarray,
        scaler,
        lookback_hours: int,
        epochs: int = 30,
        batch_size: int = 32,
        validation_split: float = 0.15,
    ) -> "CallEventLSTM":
        n_features = X.shape[2]
        model = build_model(lookback_hours, n_features)

        early_stop = tf.keras.callbacks.EarlyStopping(
            monitor="val_loss", patience=5, restore_best_weights=True
        )

        model.fit(
            X,
            {"call_volume": y[:, 0], "drop_rate": y[:, 1], "failure_prob": y[:, 2]},
            epochs=epochs,
            batch_size=batch_size,
            validation_split=validation_split,
            callbacks=[early_stop],
            verbose=2,
        )
        return cls(model, scaler, lookback_hours)

    def predict(self, X: np.ndarray) -> np.ndarray:
        call_volume, drop_rate, failure_prob = self.model.predict(X, verbose=0)
        return np.column_stack([
            call_volume.flatten(),
            drop_rate.flatten(),
            failure_prob.flatten(),
        ])

    def save(self, out_dir: Path) -> None:
        out_dir.mkdir(parents=True, exist_ok=True)
        self.model.save(out_dir / "model.keras")
        joblib.dump({"scaler": self.scaler, "lookback_hours": self.lookback_hours}, out_dir / "meta.pkl")

    @classmethod
    def load(cls, out_dir: Path) -> "CallEventLSTM":
        model = tf.keras.models.load_model(out_dir / "model.keras")
        meta = joblib.load(out_dir / "meta.pkl")
        return cls(model, meta["scaler"], meta["lookback_hours"])
