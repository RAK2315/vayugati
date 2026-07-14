"""OpenAQ v3 client. Docs: https://docs.openaq.org"""

import httpx

from . import config

BASE = "https://api.openaq.org/v3"

# OpenAQ parameter name -> readings column
PARAMS = {"pm25": "pm25", "pm10": "pm10", "no2": "no2", "so2": "so2", "co": "co", "o3": "o3"}


def _get(path: str) -> dict:
    resp = httpx.get(
        f"{BASE}{path}",
        headers={"X-API-Key": config.OPENAQ_API_KEY},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def get_location(location_id: int) -> dict:
    """Location metadata: name, coordinates, and its sensors (sensor id -> parameter)."""
    loc = _get(f"/locations/{location_id}")["results"][0]
    return {
        "name": loc["name"],
        "lat": loc["coordinates"]["latitude"],
        "lng": loc["coordinates"]["longitude"],
        "sensors": {s["id"]: s["parameter"]["name"] for s in loc.get("sensors", [])},
    }


def get_latest(location_id: int) -> list[dict]:
    """Latest value per sensor: [{sensor_id, value, ts_utc}, ...]."""
    results = _get(f"/locations/{location_id}/latest")["results"]
    return [
        {
            "sensor_id": r["sensorsId"],
            "value": r["value"],
            "ts_utc": r["datetime"]["utc"],
        }
        for r in results
    ]
