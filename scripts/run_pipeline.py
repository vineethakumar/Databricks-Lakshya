"""End-to-end demo runner: train both models, then run one batch inference +
triage-queue rebuild pass. Assumes the DB already has seed data loaded
(docker-compose runs db/05_seed_data.sql automatically on first startup).

Usage:
    python scripts/run_pipeline.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import predict_and_score, train_call_event_model, train_qoe_model


def main() -> None:
    print("=" * 70)
    print("STEP 1/3: training call-event LSTM")
    print("=" * 70)
    train_call_event_model.main()

    print("\n" + "=" * 70)
    print("STEP 2/3: training QoE regression model")
    print("=" * 70)
    train_qoe_model.main()

    print("\n" + "=" * 70)
    print("STEP 3/3: batch inference + triage queue rebuild")
    print("=" * 70)
    predict_and_score.main()


if __name__ == "__main__":
    main()
