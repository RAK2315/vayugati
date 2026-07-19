"""One ingestion run: OpenAQ station readings + Open-Meteo weather -> Supabase."""

import logging
import time
from datetime import datetime, timezone

from . import aqi, config, db, open_meteo, openaq

log = logging.getLogger("ingest")


def _hour_floor_utc(ts_iso: str) -> str:
    dt = datetime.fromisoformat(ts_iso.replace("Z", "+00:00")).astimezone(timezone.utc)
    return dt.replace(minute=0, second=0, microsecond=0).isoformat()


def _ensure_station(entry: dict, wards: dict[str, dict]) -> int | None:
    """Find or create the stations row for a configured station. Returns station id."""
    ref = str(entry["openaq_location_id"])
    existing = db.get_station_by_ref(ref)
    if existing:
        return existing["id"]

    ward = wards.get(entry["ward"])
    if ward is None:
        log.error("ward %r not found in wards table, skipping station %s", entry["ward"], ref)
        return None

    meta = openaq.get_location(entry["openaq_location_id"])
    created = db.insert_station(ward["id"], meta["name"], ref, meta["lat"], meta["lng"])
    log.info("registered station %s (%s) for ward %s", meta["name"], ref, entry["ward"])
    return created["id"]


def _ingest_station(entry: dict, wards: dict[str, dict]) -> int:
    """Pull latest readings for one station. Returns rows upserted."""
    station_id = _ensure_station(entry, wards)
    if station_id is None:
        return 0

    sensors = openaq.get_location(entry["openaq_location_id"])["sensors"]
    latest = openaq.get_latest(entry["openaq_location_id"])

    # group sensor values into one row per hour
    by_hour: dict[str, dict] = {}
    for m in latest:
        param = sensors.get(m["sensor_id"])
        col = openaq.PARAMS.get(param or "")
        if col is None or m["value"] is None or m["value"] < 0:
            continue
        ts = _hour_floor_utc(m["ts_utc"])
        by_hour.setdefault(ts, {})[col] = m["value"]

    for ts, values in by_hour.items():
        row = {"station_id": station_id, "ts": ts, **values}
        row_aqi = aqi.compute_aqi(values.get("pm25"), values.get("pm10"))
        if row_aqi is not None:
            row["aqi"] = row_aqi
        db.upsert_reading(row)
    return len(by_hour)


def run() -> dict:
    """One full ingestion pass. Safe to run every hour; upserts are idempotent."""
    summary = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "stations_configured": 0,
        "stations_skipped_no_id": [],
        "readings_upserted": 0,
        "weather_upserted": 0,
        "errors": [],
    }

    stations = config.load_stations()
    summary["stations_configured"] = len(stations)
    wards = db.get_wards()

    for entry in stations:
        if not entry.get("openaq_location_id"):
            summary["stations_skipped_no_id"].append(entry["ward"])
            continue
        try:
            summary["readings_upserted"] += _ingest_station(entry, wards)
        except Exception as e:  # one bad station must not kill the run
            log.exception("station for ward %s failed", entry["ward"])
            summary["errors"].append(f"{entry['ward']}: {e}")

    if summary["stations_skipped_no_id"]:
        log.warning(
            "no openaq_location_id configured for: %s — fill stations.yaml",
            ", ".join(summary["stations_skipped_no_id"]),
        )

    for name, ward in wards.items():
        if ward["lat"] is None or ward["lng"] is None:
            continue
        try:
            # A brief pause between calls — hitting Open-Meteo for all
            # configured wards back-to-back with zero delay produced real
            # 429s from a real deployment (Render's shared egress IP), never
            # reproduced by local/disposable-Postgres testing since that
            # never made this many real sequential API calls.
            time.sleep(0.5)
            w = open_meteo.get_current(ward["lat"], ward["lng"])
            db.upsert_weather(
                {
                    "ward_id": ward["id"],
                    "ts": _hour_floor_utc(w["ts_utc"]),
                    "temp_c": w["temp_c"],
                    "humidity": w["humidity"],
                    "wind_speed": w["wind_speed"],
                    "wind_dir": w["wind_dir"],
                    "precipitation": w["precipitation"],
                    "pressure": w["pressure"],
                }
            )
            summary["weather_upserted"] += 1
        except Exception as e:
            log.exception("weather for ward %s failed", name)
            summary["errors"].append(f"weather {name}: {e}")

    summary["finished_at"] = datetime.now(timezone.utc).isoformat()
    log.info("ingest done: %s", summary)
    return summary
