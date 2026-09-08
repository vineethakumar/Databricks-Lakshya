"""Trains the KPI -> QoE regression model from VW_QOE_TRAINING_DATA and
saves the artifact.

Usage:
    python -m src.train_qoe_model
"""
from sklearn.metrics import mean_absolute_error, r2_score
from sklearn.model_selection import train_test_split

from . import config
from .data_loader import load_qoe_training_data
from .models.qoe_regression import QoERegressor, compute_composite_qoe_label


def main() -> None:
    print("Loading KPI -> survey training data from VW_QOE_TRAINING_DATA ...")
    df = load_qoe_training_data()
    print(f"  {len(df)} labeled rows")

    train_df, test_df = train_test_split(df, test_size=0.2, random_state=42)

    model = QoERegressor.train(train_df)

    preds = model.predict(test_df)
    actual = compute_composite_qoe_label(test_df)
    print("\nHold-out performance:")
    print(f"  MAE : {mean_absolute_error(actual, preds):.2f} (0-100 scale)")
    print(f"  R^2 : {r2_score(actual, preds):.3f}")

    out_dir = config.MODEL_DIR / "qoe_regression"
    model.save(out_dir)
    print(f"\nSaved model to {out_dir}")


if __name__ == "__main__":
    main()
