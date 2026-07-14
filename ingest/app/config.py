"""Env + station config. All secrets come from env vars, never hardcoded."""

import os
from pathlib import Path

import yaml
from dotenv import load_dotenv

load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
OPENAQ_API_KEY = os.getenv("OPENAQ_API_KEY", "")

STATIONS_FILE = Path(__file__).resolve().parent.parent / "stations.yaml"


def require_env() -> None:
    missing = [
        name
        for name, val in [
            ("SUPABASE_URL", SUPABASE_URL),
            ("SUPABASE_SERVICE_ROLE_KEY", SUPABASE_SERVICE_ROLE_KEY),
            ("OPENAQ_API_KEY", OPENAQ_API_KEY),
        ]
        if not val
    ]
    if missing:
        raise RuntimeError(
            f"Missing env vars: {', '.join(missing)}. Copy .env.example to .env and fill it in."
        )


def load_stations() -> list[dict]:
    """Returns [{ward: str, openaq_location_id: int | None}, ...]."""
    with open(STATIONS_FILE) as f:
        data = yaml.safe_load(f)
    return data["stations"]
