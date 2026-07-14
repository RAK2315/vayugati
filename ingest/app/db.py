"""Supabase access. Uses the service_role key: writes bypass RLS by design."""

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
