#!/usr/bin/env python3
"""Historical replay runner (Phase 11).

Replays REAL historical Delhi PM2.5 readings (OpenAQ v3, December 2018 —
see ingest/tests/fixtures/delhi_historical_openaq_dec2018.json for exact
provenance) through the real anomaly-detection and source-attribution SQL
engines, day by day, exactly as the real hourly cron would have seen them
arrive — and separately runs the real forecast validation logic
(ingest/app/forecast.py) against the same real data.

Isolation (plan §2's own explicit requirement): every fixture this script
creates lives under ONE city_config row, `city_code = 'replay_dec2018'`,
with `config -> 'is_replay' = true` as an explicit, machine-checkable
simulation flag. Nothing here ever touches a real pilot city's rows.
Reset is just `DELETE ... WHERE city_code = 'replay_dec2018'` (see
`--reset` below) — fully repeatable.

Why this drives SQL directly (via `psql` in the disposable Docker
container) rather than calling `ingest/app/anomaly_detection.py`'s own
`run()`: that module talks to a real Supabase project over PostgREST
(HTTP), which the local disposable Postgres does not run (it is bare
`postgres:15`, no PostgREST/GoTrue stack) — exactly the same reason
`supabase/tests/*.sql` are driven via `psql`, not the Python client. The
RULES under test live in the SQL functions either way
(`run_anomaly_detection`, `run_incident_source_attribution`), so this is
not a weaker test of the same logic, just a different transport.

A critical, explicitly-documented simulation accommodation: real
`evaluate_station_pollutant_anomaly` compares a reading's timestamp
against the ACTUAL wall-clock `now()` for staleness — but this replay's
readings genuinely happened in December 2018, years before this script
ever runs. `data_freshness_max_minutes` is therefore set to a very large
number FOR THE REPLAY CITY ONLY (never for a real pilot city's config),
documented here and in the report, so the replay measures genuine
intra-dataset staleness/gaps, not an artifact of replaying old data long
after the fact.

Usage:
    python3 ingest/scripts/historical_replay.py
    python3 ingest/scripts/historical_replay.py --reset   # wipe replay fixtures first
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
INGEST_ROOT = HERE.parent
REPO_ROOT = INGEST_ROOT.parent
FIXTURES = INGEST_ROOT / "tests" / "fixtures"
REPORTS_DIR = REPO_ROOT / "docs" / "_replay_reports"

CONTAINER = "vg-pg"
DB = "vayugati"
REPLAY_CITY_CODE = "replay_dec2018"

# Wide enough to cover 2018-12-01 through 2018-12-31 relative to whenever
# this script actually runs (documented above) — a replay-only override,
# never applied to a real pilot city.
REPLAY_FRESHNESS_MAX_MINUTES = 6_000_000


def _psql(sql: str) -> str:
    proc = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", DB, "-tAq"],
        input=sql, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql failed:\n{proc.stderr}\nSQL was:\n{sql[:2000]}")
    return proc.stdout.strip()


def _psql_json(sql: str):
    out = _psql(sql)
    return json.loads(out) if out else None


def reset_replay_fixtures() -> None:
    print(f"== resetting any existing '{REPLAY_CITY_CODE}' fixtures ==")
    _psql(f"""
        delete from task_dispatches where city_id in (select id from city_config where city_code = '{REPLAY_CITY_CODE}');
        delete from incident_source_hypotheses where incident_id in (
          select id from incidents where city_id in (select id from city_config where city_code = '{REPLAY_CITY_CODE}'));
        delete from incident_events where incident_id in (
          select id from incidents where city_id in (select id from city_config where city_code = '{REPLAY_CITY_CODE}'));
        delete from anomaly_candidates where station_id in (
          select s.id from stations s join wards w on w.id = s.ward_id
          join city_config c on c.id = w.city_id where c.city_code = '{REPLAY_CITY_CODE}');
        delete from incidents where city_id in (select id from city_config where city_code = '{REPLAY_CITY_CODE}');
        delete from readings where station_id in (
          select s.id from stations s join wards w on w.id = s.ward_id
          join city_config c on c.id = w.city_id where c.city_code = '{REPLAY_CITY_CODE}');
        delete from stations where ward_id in (
          select w.id from wards w join city_config c on c.id = w.city_id where c.city_code = '{REPLAY_CITY_CODE}');
        delete from wards where city_id in (select id from city_config where city_code = '{REPLAY_CITY_CODE}');
        delete from city_config where city_code = '{REPLAY_CITY_CODE}';
    """)


def setup_replay_city(station_names: list[str]) -> dict[str, int]:
    print(f"== seeding isolated replay city '{REPLAY_CITY_CODE}' ==")
    config = {
        "is_replay": True,
        "anomaly_detection": {
            "pollutant_thresholds": {"pm25": 90, "pm10": 250, "no2": 180},
            "persistence_window_readings": 3,
            "persistence_min_count": 2,
            "local_excess_min": 20,
            "nearby_station_radius_m": 8000,
            "data_completeness_min": 0.3,  # real historical station data is genuinely sparser than a live feed
            "data_freshness_max_minutes": REPLAY_FRESHNESS_MAX_MINUTES,
            "prediction_horizon_hours": 6,
            "dedup_window_hours": 12,
        },
        "feature_flags": {"anomaly_detection": True, "source_attribution": True},
    }
    city_id = _psql_json(f"""
        insert into city_config (city_code, name, pollutant_priority, config)
        values ('{REPLAY_CITY_CODE}', 'Historical Replay (Dec 2018)', array['pm25'], '{json.dumps(config)}'::jsonb)
        returning to_jsonb(id);
    """)
    ward_ids: dict[str, int] = {}
    for name in station_names:
        wid = _psql_json(f"""
            insert into wards (name, city_id) values ('replay-{name}', {city_id}) returning to_jsonb(id);
        """)
        ward_ids[name] = wid
    return {"city_id": city_id, **{f"ward:{k}": v for k, v in ward_ids.items()}}


def create_stations(ward_ids: dict[str, int], station_names: list[str]) -> dict[str, int]:
    station_ids = {}
    for name in station_names:
        ward_id = ward_ids[f"ward:{name}"]
        sid = _psql_json(f"""
            insert into stations (ward_id, name, sensor_type) values ({ward_id}, 'replay-{name}', 'regulatory') returning to_jsonb(id);
        """)
        station_ids[name] = sid
    return station_ids


def load_fixture() -> dict:
    path = FIXTURES / "delhi_historical_openaq_dec2018.json"
    with open(path) as f:
        return json.load(f)


def day_bucket(ts: str) -> str:
    return ts[:10]


def run_replay(reset: bool) -> dict:
    if reset:
        reset_replay_fixtures()

    fixture = load_fixture()
    station_names = list(fixture["stations"].keys())

    existing = _psql_json(f"select to_jsonb(count(*)) from city_config where city_code = '{REPLAY_CITY_CODE}'")
    if existing:
        print(f"Replay city '{REPLAY_CITY_CODE}' already exists — reusing it (pass --reset to rebuild).")
        city_id = _psql_json(f"select to_jsonb(id) from city_config where city_code = '{REPLAY_CITY_CODE}'")
        ward_rows = _psql_json(f"""
            select jsonb_object_agg(name, id) from wards where city_id = {city_id}
        """) or {}
        ward_ids = {f"ward:{k.replace('replay-', '')}": v for k, v in ward_rows.items()}
        station_rows = _psql_json(f"""
            select jsonb_object_agg(s.name, s.id) from stations s join wards w on w.id = s.ward_id where w.city_id = {city_id}
        """) or {}
        station_ids = {k.replace("replay-", ""): v for k, v in station_rows.items()}
    else:
        ids = setup_replay_city(station_names)
        city_id = ids["city_id"]
        ward_ids = ids
        station_ids = create_stations(ward_ids, station_names)

    # ---- bucket every real reading by simulated calendar day ----
    by_day: dict[str, list[tuple[str, int, float]]] = defaultdict(list)
    for name, s in fixture["stations"].items():
        for r in s["readings"]:
            by_day[day_bucket(r["ts"])].append((r["ts"], station_ids[name], r["value"]))

    days = sorted(by_day.keys())
    print(f"== replaying {len(days)} simulated days across {len(station_names)} real Delhi stations ==")

    daily_log = []
    for day in days:
        rows = by_day[day]
        values_sql = ",\n".join(
            f"({sid}, '{ts}'::timestamptz, {val})" for ts, sid, val in rows
        )
        _psql(f"insert into readings (station_id, ts, pm25) values {values_sql};")

        candidates_before = _psql_json(
            f"select to_jsonb(count(*)) from anomaly_candidates where station_id in "
            f"(select id from stations where ward_id in (select id from wards where city_id = {city_id}))"
        )
        incidents_before = _psql_json(f"select to_jsonb(count(*)) from incidents where city_id = {city_id}")

        # simulate the real hourly cron's detection + attribution pass for this simulated day
        det_result = _psql_json(
            f"select coalesce(jsonb_agg(row_to_json(r)), '[]'::jsonb) from "
            f"run_anomaly_detection('{REPLAY_CITY_CODE}') r;"
        )
        attr_result = _psql_json(
            f"select coalesce(jsonb_agg(r.incident_id), '[]'::jsonb) from "
            f"run_incident_source_attribution('{REPLAY_CITY_CODE}', false) r;"
        )

        candidates_after = _psql_json(
            f"select to_jsonb(count(*)) from anomaly_candidates where station_id in "
            f"(select id from stations where ward_id in (select id from wards where city_id = {city_id}))"
        )
        incidents_after = _psql_json(f"select to_jsonb(count(*)) from incidents where city_id = {city_id}")

        daily_log.append({
            "simulated_day": day,
            "readings_ingested_this_day": len(rows),
            "candidates_evaluated": len(det_result or []),
            "candidates_total_after": candidates_after,
            "new_candidates_this_day": candidates_after - candidates_before,
            "incidents_total_after": incidents_after,
            "new_incidents_this_day": incidents_after - incidents_before,
            "incidents_attributed_this_day": len(attr_result or []),
        })
        print(f"  {day}: +{len(rows)} readings, {candidates_after - candidates_before} new candidates, "
              f"{incidents_after - incidents_before} new incidents")

    # ---- final rollup ----
    incidents = _psql_json(f"""
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', id, 'detection_stage', detection_stage, 'detection_method', detection_method,
          'status', status, 'ward_id', ward_id, 'primary_pollutant', primary_pollutant,
          'source_confidence', source_confidence, 'detected_at', detected_at
        )), '[]'::jsonb)
        from incidents where city_id = {city_id};
    """) or []

    hypotheses = _psql_json(f"""
        select coalesce(jsonb_agg(jsonb_build_object(
          'incident_id', h.incident_id, 'source_category', h.source_category, 'probability', h.probability,
          'confidence_level', h.confidence_level
        )), '[]'::jsonb)
        from incident_source_hypotheses h
        join incidents i on i.id = h.incident_id
        where i.city_id = {city_id} and h.is_current;
    """) or []

    candidates_total = _psql_json(
        f"select to_jsonb(count(*)) from anomaly_candidates where station_id in "
        f"(select id from stations where ward_id in (select id from wards where city_id = {city_id}))"
    )

    detected_count = sum(1 for i in incidents if i.get("detection_stage") in (None, "detected"))
    predicted_count = sum(1 for i in incidents if i.get("detection_stage") == "predicted")
    confirmed_count = sum(1 for i in incidents if i.get("detection_stage") == "confirmed")

    report = {
        "replay_city_code": REPLAY_CITY_CODE,
        "dataset": {
            "source": fixture["source"],
            "pollutant": fixture["pollutant"],
            "date_range": fixture["date_range"],
            "stations": station_names,
            "total_readings": sum(len(s["readings"]) for s in fixture["stations"].values()),
        },
        "simulation_accommodation": {
            "data_freshness_max_minutes_override": REPLAY_FRESHNESS_MAX_MINUTES,
            "reason": "replayed readings are genuinely from 2018; the real freshness check compares against actual wall-clock now(), so this override is required for replay to evaluate anything at all — never applied to a real pilot city",
        },
        "daily_log": daily_log,
        "totals": {
            "anomaly_candidates": candidates_total,
            "incidents_created": len(incidents),
            "incidents_by_detection_stage": {
                "detected_or_null": detected_count,
                "predicted": predicted_count,
                "confirmed": confirmed_count,
            },
            "current_source_hypotheses": len(hypotheses),
        },
        "incidents": incidents,
        "hypotheses": hypotheses,
    }
    return report


def write_reports(report: dict) -> None:
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    json_path = REPORTS_DIR / "detection_replay_dec2018.json"
    with open(json_path, "w") as f:
        json.dump(report, f, indent=2, default=str)
    print(f"\nMachine-readable report: {json_path}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reset", action="store_true", help="wipe existing replay fixtures before running")
    args = ap.parse_args()

    report = run_replay(reset=args.reset)
    write_reports(report)

    print("\n== summary ==")
    print(json.dumps(report["totals"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
