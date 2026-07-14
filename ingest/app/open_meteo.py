"""Open-Meteo current weather. Free, no key. Docs: https://open-meteo.com/en/docs"""

import httpx

BASE = "https://api.open-meteo.com/v1/forecast"

CURRENT_VARS = (
    "temperature_2m,relative_humidity_2m,precipitation,"
    "surface_pressure,wind_speed_10m,wind_direction_10m"
)


def get_current(lat: float, lng: float) -> dict:
    """Current weather at a point: {ts_utc, temp_c, humidity, wind_speed, wind_dir, precipitation, pressure}."""
    resp = httpx.get(
        BASE,
        params={
            "latitude": lat,
            "longitude": lng,
            "current": CURRENT_VARS,
            "timezone": "UTC",
        },
        timeout=30,
    )
    resp.raise_for_status()
    cur = resp.json()["current"]
    return {
        "ts_utc": cur["time"] + ":00Z",  # Open-Meteo returns e.g. "2026-07-14T07:15"
        "temp_c": cur["temperature_2m"],
        "humidity": cur["relative_humidity_2m"],
        "wind_speed": cur["wind_speed_10m"],
        "wind_dir": cur["wind_direction_10m"],
        "precipitation": cur["precipitation"],
        "pressure": cur["surface_pressure"],
    }
