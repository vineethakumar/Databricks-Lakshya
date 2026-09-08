"""Regression model mapping network KPIs (+ subscriber segment) to a single
0-100 QoE score, trained against real NPS/CSAT survey outcomes.

The composite label blends CSAT (1-5) and NPS (-100..100), both rescaled to
0-100, so the model has one continuous target instead of two differently
scaled ones. This is the ML counterpart to the PL/SQL rule-based fallback
(db/03_packages.sql: pkg_qoe_scoring.rule_based_qoe) — same inputs, learned
weights instead of hand-picked ones.
"""
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

NUMERIC_FEATURES = [
    "latency_ms",
    "jitter_ms",
    "packet_drop_rate",
    "call_drop_rate",
    "rrc_setup_success_rate",
    "throughput_mbps",
]
CATEGORICAL_FEATURES = ["segment"]


def compute_composite_qoe_label(df: pd.DataFrame) -> pd.Series:
    csat_0_100 = (df["csat_score"] - 1) / 4 * 100        # 1..5 -> 0..100
    nps_0_100 = (df["nps_score"] + 100) / 200 * 100       # -100..100 -> 0..100
    return (csat_0_100 * 0.5 + nps_0_100 * 0.5).clip(0, 100)


def _build_pipeline() -> Pipeline:
    preprocessor = ColumnTransformer(
        transformers=[
            ("numeric", StandardScaler(), NUMERIC_FEATURES),
            ("categorical", OneHotEncoder(handle_unknown="ignore"), CATEGORICAL_FEATURES),
        ]
    )
    return Pipeline(steps=[
        ("preprocess", preprocessor),
        ("regressor", GradientBoostingRegressor(
            n_estimators=200, max_depth=3, learning_rate=0.05, random_state=42
        )),
    ])


class QoERegressor:
    def __init__(self, pipeline: Pipeline):
        self.pipeline = pipeline

    @classmethod
    def train(cls, df: pd.DataFrame) -> "QoERegressor":
        X = df[NUMERIC_FEATURES + CATEGORICAL_FEATURES]
        y = compute_composite_qoe_label(df)

        pipeline = _build_pipeline()
        pipeline.fit(X, y)
        return cls(pipeline)

    def predict(self, df: pd.DataFrame) -> np.ndarray:
        X = df[NUMERIC_FEATURES + CATEGORICAL_FEATURES]
        return np.clip(self.pipeline.predict(X), 0, 100)

    def save(self, out_dir: Path) -> None:
        out_dir.mkdir(parents=True, exist_ok=True)
        joblib.dump(self.pipeline, out_dir / "qoe_pipeline.pkl")

    @classmethod
    def load(cls, out_dir: Path) -> "QoERegressor":
        pipeline = joblib.load(out_dir / "qoe_pipeline.pkl")
        return cls(pipeline)
