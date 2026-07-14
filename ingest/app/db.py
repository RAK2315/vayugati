"""Supabase access. Uses the service_role key: writes bypass RLS by design."""

from datetime import datetime, timedelta, timezone
from functools import lru_cache

from supabase import Client, create_client

from . import config


@lru_cache(maxsize=1)
def client() -> Client:
    config.require_env()
    return create_client(config.SUPABASE_URL, config.SUPABASE_SERVICE_ROLE_KEY)


def get_wards() -> dict[str, dict]:
    """wards.name -> {id, lat, lng}"""
    rows = client().table("wards").select("id, name, lat, lng").execute().data
    return {r["name"]: r for r in rows}


def get_station_by_ref(external_ref: str) -> dict | None:
    rows = (
        client()
        .table("stations")
        .select("id, external_ref")
        .eq("external_ref", external_ref)
        .execute()
        .data
    )
    return rows[0] if rows else None


def insert_station(
    ward_id: int, name: str, external_ref: str, lat: float | None, lng: float | None
) -> dict:
    row = {
        "ward_id": ward_id,
        "name": name,
        "source": "dpcc",  # OpenAQ wraps DPCC/CPCB; refine per station later if needed
        "external_ref": external_ref,
        "lat": lat,
        "lng": lng,
    }
    return client().table("stations").insert(row).execute().data[0]


def upsert_reading(row: dict) -> None:
    # merge-duplicates: only the columns present in `row` are updated,
    # so a later sensor for the same hour fills in, not wipes, the rest.
    client().table("readings").upsert(row, on_conflict="station_id,ts").execute()


def upsert_weather(row: dict) -> None:
    client().table("weather").upsert(row, on_conflict="ward_id,ts").execute()


# ── history reads (for forecast + attribution) ───────────────────────────────

def get_readings_history(hours: int = 24 * 30) -> list[dict]:
    """Flattened readings joined to their ward: [{ts, ward_id, pm25, pm10, aqi}]."""
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
    rows = (
        client()
        .table("readings")
        .select("ts, pm25, pm10, aqi, stations(ward_id)")
        .gte("ts", cutoff)
        .order("ts")
        .limit(50000)
        .execute()
        .data
    )
    out = []
    for r in rows:
        st = r.get("stations")
        ward_id = st.get("ward_id") if isinstance(st, dict) else (st[0]["ward_id"] if st else None)
        if ward_id is None:
            continue
        out.append(
            {"ts": r["ts"], "ward_id": ward_id, "pm25": r["pm25"], "pm10": r["pm10"], "aqi": r["aqi"]}
        )
    return out


def get_weather_history(hours: int = 24 * 30) -> list[dict]:
    """[{ts, ward_id, wind_dir, wind_speed, temp_c, humidity, precipitation}]."""
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
    return (
        client()
        .table("weather")
        .select("ts, ward_id, wind_dir, wind_speed, temp_c, humidity, precipitation")
        .gte("ts", cutoff)
        .order("ts")
        .limit(50000)
        .execute()
        .data
    )


# ── forecast + attribution writes ────────────────────────────────────────────

def replace_forecasts(ward_id: int, rows: list[dict]) -> None:
    """Swap in a fresh forecast generation for a ward (delete old, insert new)."""
    client().table("forecasts").delete().eq("ward_id", ward_id).execute()
    if rows:
        client().table("forecasts").insert(rows).execute()


def replace_attribution(ward_id: int, row: dict) -> None:
    """Keep one current attribution per ward."""
    client().table("attributions").delete().eq("ward_id", ward_id).execute()
    client().table("attributions").insert(row).execute()
