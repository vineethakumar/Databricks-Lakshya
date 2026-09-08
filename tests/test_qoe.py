import pandas as pd

from src.config import qoe_band, risk_level
from src.models.qoe_regression import compute_composite_qoe_label


def test_qoe_band_thresholds():
    assert qoe_band(90) == "EXCELLENT"
    assert qoe_band(75) == "GOOD"
    assert qoe_band(55) == "FAIR"
    assert qoe_band(35) == "POOR"
    assert qoe_band(10) == "CRITICAL"


def test_risk_level_thresholds():
    assert risk_level(0.25) == "CRITICAL"
    assert risk_level(0.12) == "HIGH"
    assert risk_level(0.05) == "MODERATE"
    assert risk_level(0.01) == "LOW"


def test_composite_qoe_label_bounds_and_direction():
    df = pd.DataFrame({
        "csat_score": [1, 5, 3],
        "nps_score": [-100, 100, 0],
    })
    label = compute_composite_qoe_label(df)

    assert label.iloc[0] == 0       # worst possible survey -> 0
    assert label.iloc[1] == 100     # best possible survey -> 100
    assert label.between(0, 100).all()
    assert label.iloc[1] > label.iloc[2] > label.iloc[0]
