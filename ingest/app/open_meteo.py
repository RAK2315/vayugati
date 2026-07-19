"""Open-Meteo current + hourly-forecast weather. Free, no key. Docs: https://open-meteo.com/en/docs"""

import httpx

BASE = "https://api.open-meteo.com/v1/forecast"

CURRENT_VARS = (
    "temperature_2m,relative_humidity_2m,precipitation,"
    "surface_pressure,wind_speed_10m,wind_direction_10m"
)

HOURLY_VARS = (
    "temperature_2m,relative_humidity_2m,precipitation,"
    "wind_speed_10m,wind_direction_10m"
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


def get_hourly_forecast(lat: float, lng: float, hours: int = 48) -> list[dict]:
    """Real, genuinely-forecasted (not persisted) hourly weather for the next
    `hours` hours — the "weather forecast" input plan §3 asks for, distinct
    from `get_current`'s single now-reading. Open-Meteo's free tier already
    provides up to 16 days of hourly forecast; we only ask for what the
    pollutant forecast horizon actually needs.

    Returns [{ts_utc, temp_c, humidity, wind_speed, wind_dir, precipitation}, ...].
    """
    resp = httpx.get(
        BASE,
        params={
            "latitude": lat,
            "longitude": lng,
            "hourly": HOURLY_VARS,
            "forecast_hours": hours,
            "timezone": "UTC",
        },
        timeout=30,
    )
    resp.raise_for_status()
    h = resp.json()["hourly"]
    out = []
    for i, t in enumerate(h["time"]):
        out.append(
            {
                "ts_utc": t + ":00Z",
                "temp_c": h["temperature_2m"][i],
                "humidity": h["relative_humidity_2m"][i],
                "wind_speed": h["wind_speed_10m"][i],
                "wind_dir": h["wind_direction_10m"][i],
                "precipitation": h["precipitation"][i],
            }
        )
    return out
