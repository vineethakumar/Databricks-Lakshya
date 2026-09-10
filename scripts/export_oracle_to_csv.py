"""Exports the two feature views straight from Oracle into local CSV
files -- useful to inspect the exact data backend/app.py trains on
without a SQL client.

Usage:
    python -m scripts.export_oracle_to_csv
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.oracle_db import build_db, fetch_df

OUT_DIR = Path(__file__).resolve().parent.parent / "data" / "oracle_export"

VIEWS = ["vw_site_hourly_features", "vw_qoe_training_data", "vw_site_subscriber_value"]


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    conn = build_db()
    try:
        for view in VIEWS:
            df = fetch_df(conn, f"SELECT * FROM {view}")
            out_path = OUT_DIR / f"{view}.csv"
            df.to_csv(out_path, index=False)
            print(f"  {view}: {len(df)} rows -> {out_path}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
