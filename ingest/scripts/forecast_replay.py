#!/usr/bin/env python3
"""Forecast replay evaluation (Phase 11) — the real Phase 8 validation
logic (`ingest/app/forecast._validate`) run against REAL historical Delhi
PM2.5 data (OpenAQ v3, December 2018 — same fixture as
`historical_replay.py`'s detection replay; see
`ingest/tests/fixtures/delhi_historical_openaq_dec2018.json` for exact
provenance), not synthetic data.

No database, no network — this calls forecast.py's own internal,
pure functions directly (same technique as `ingest/tests/test_forecast.py`),
so this is a genuine test of the real validation methodology, just fed
real historical values instead of engineered synthetic ones.

Weather: real Open-Meteo historical archive data for ONE representative
Delhi coordinate (Okhla) is applied to all four wards — a documented
simplification (see the report's own caveat), not a claim of per-station
weather.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
INGEST_ROOT = HERE.parent
REPO_ROOT = INGEST_ROOT.parent
FIXTURES = INGEST_ROOT / "tests" / "fixtures"
REPORTS_DIR = REPO_ROOT / "docs" / "_replay_reports"

sys.path.insert(0, str(INGEST_ROOT))
from app import forecast  # noqa: E402


def load_readings() -> list[dict]:
    with open(FIXTURES / "delhi_historical_openaq_dec2018.json") as f:
        fixture = json.load(f)
    rows = []
    for ward_idx, (name, s) in enumerate(fixture["stations"].items(), start=1):
        for r in s["readings"]:
            rows.append({"ts": r["ts"], "ward_id": ward_idx, "pm25": r["value"], "pm10": None, "no2": None, "aqi": None})
    return rows, {i + 1: name for i, name in enumerate(fixture["stations"].keys())}


def load_weather() -> list[dict]:
    with open(FIXTURES / "delhi_historical_weather_dec2018.json") as f:
        fixture = json.load(f)
    rows = []
    for ward_id in range(1, 5):  # applied to all 4 replay wards — documented simplification, see module docstring
        for r in fixture["readings"]:
            rows.append({
                "ts": r["ts"], "ward_id": ward_id, "temp_c": r["temp_c"], "humidity": r["humidity"],
                "wind_speed": r["wind_speed"], "wind_dir": r["wind_dir"], "precipitation": r["precipitation"],
            })
    return rows


def main() -> int:
    reading_rows, ward_names = load_readings()
    weather_rows = load_weather()

    hourly = forecast._hourly_ward_pollutant(reading_rows, "pm25")
    hourly = forecast._with_local_excess(hourly)
    city_avg = forecast._city_avg_series(hourly)
    weather_df = forecast._hourly_ward_weather(weather_rows)
    weather_by_ward = {
        wid: weather_df[weather_df["ward_id"] == wid].set_index("ts").sort_index()
        for wid in ward_names
    }

    threshold = 90.0  # Delhi's own configured pm25 anomaly threshold (city_config seed)
    results = {}
    for ward_id, name in ward_names.items():
        w = forecast._ward_series(hourly, ward_id)
        if w.empty or len(w) < 24:
            results[name] = {"status": "insufficient_data", "rows": len(w)}
            continue

        method, metrics, max_validated, beats_overall = forecast._validate(
            w, weather_by_ward[ward_id], city_avg,
            threshold=threshold, baseline_value_at_split=float(w["baseline"].iloc[-1]),
            min_mae_improvement_pct=forecast.DEFAULT_MIN_MAE_IMPROVEMENT_PCT,
        )
        results[name] = {
            "status": "validated" if metrics else "insufficient_holdout",
            "rows": len(w),
            "method_selected": method,
            "max_validated_horizon_hours": max_validated,
            "beats_persistence_overall": beats_overall,
            "per_horizon": metrics,
        }
        print(f"{name}: rows={len(w)} method={method} max_validated_horizon={max_validated} beats_persistence={beats_overall}")
        for h, m in metrics.items():
            print(f"    {h}h: MAE={m['mae']} (persistence MAE={m['persistence_mae']}) RMSE={m['rmse']} bias={m['bias']} beats_persistence={m['beats_persistence']}")

    report = {
        "dataset": "Real OpenAQ v3 historical PM2.5, December 2018, 4 Delhi stations (Okhla/Narela/Wazirpur/Rohini) — see ingest/tests/fixtures/delhi_historical_openaq_dec2018.json",
        "weather_caveat": "Real Open-Meteo historical weather for ONE representative coordinate (Okhla) applied to all 4 wards — a documented replay simplification, not per-station weather.",
        "threshold_used": threshold,
        "results": results,
    }
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(REPORTS_DIR / "forecast_replay_dec2018.json", "w") as f:
        json.dump(report, f, indent=2, default=str)
    print(f"\nMachine-readable report: {REPORTS_DIR / 'forecast_replay_dec2018.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
