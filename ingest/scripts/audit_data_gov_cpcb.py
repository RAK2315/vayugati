#!/usr/bin/env python3
"""Authenticated audit of the official data.gov.in CPCB real-time AQI
resource (id 3b01bcb8-0b14-4abf-b6f2-c1bfd384ba69) — a read-only, one-shot
probe to see what this feed actually looks like, so a future decision about
whether/how to use it can be made from real field shapes instead of docs
alone.

NOT wired into production ingest. Does not write to Supabase. Does not
touch OpenAQ. Safe to run repeatedly.

Security: DATA_GOV_API_KEY is read from env and used only in the outgoing
request's query string — this script never prints, logs, or writes the key
anywhere, including in the generated report.

Usage (run from the ingest/ directory, with ingest/.env filled in):
    python scripts/audit_data_gov_cpcb.py
"""
from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx

# make the `app` package importable when run as a plain script from ingest/
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config  # noqa: E402

RESOURCE_ID = "3b01bcb8-0b14-4abf-b6f2-c1bfd384ba69"
BASE_URL = f"https://api.data.gov.in/resource/{RESOURCE_ID}"
REPORT_PATH = Path(__file__).resolve().parent.parent.parent / "docs" / "data" / "data-gov-cpcb-authenticated-audit.md"


def fetch_delhi_sample() -> dict:
    """One authenticated GET, Delhi only, capped at 20 rows. Raises on a
    non-2xx response (caller decides how to report that - see main())."""
    resp = httpx.get(
        BASE_URL,
        params={
            "api-key": config.DATA_GOV_API_KEY,
            "format": "json",
            "limit": 20,
            "filters[state]": "Delhi",
        },
        # api.data.gov.in silently hangs (no response at all, not even an
        # error) on httpx's default "python-httpx/x.x" User-Agent - some
        # infra-level filter on their end, confirmed by the exact same
        # request succeeding instantly with any ordinary client UA. Not a
        # spoof of anything - just avoiding a library default that this one
        # host happens to black-hole.
        headers={"User-Agent": "vayugati-cpcb-audit/1.0"},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def summarize(payload: dict) -> dict:
    """Everything below is field NAMES, counts, and non-identifying sample
    values already public on the CPCB feed itself - never the API key,
    never a raw request/response dump."""
    records = payload.get("records", [])
    fields = sorted({key for r in records for key in r.keys()})
    station_names = sorted({r.get("station") for r in records if r.get("station")})
    timestamps = sorted({r.get("last_update") for r in records if r.get("last_update")})
    pollutant_ids = sorted({r.get("pollutant_id") for r in records if r.get("pollutant_id")})
    has_lat_lng = any(r.get("latitude") not in (None, "") and r.get("longitude") not in (None, "") for r in records)

    return {
        "records_returned": len(records),
        "reported_total": payload.get("total"),
        "reported_count": payload.get("count"),
        "fields": fields,
        "sample_station_names": station_names[:8],
        "timestamp_examples": timestamps[:5],
        "pollutant_ids": pollutant_ids,
        "has_lat_lng": has_lat_lng,
    }


def render_report(summary: dict | None, error: str | None) -> str:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# data.gov.in CPCB API — Authenticated Audit",
        "",
        f"Run: {now}",
        f"Resource: `{RESOURCE_ID}` (https://api.data.gov.in/resource/{RESOURCE_ID})",
        "Request: `format=json&limit=20&filters[state]=Delhi`",
        "",
        "This is a one-shot, read-only field-shape probe. **Not** wired into",
        "production ingest — `app/ingest.py` still runs on OpenAQ exactly as",
        "before this audit. No database writes, no OpenAQ changes.",
        "",
    ]

    if error:
        lines += [
            "## Result: call failed",
            "",
            f"```\n{error}\n```",
            "",
            "No further data available from this run. The API key itself is never",
            "logged or included above — see `ingest/app/config.py` for how it's",
            "read from `DATA_GOV_API_KEY`.",
        ]
        return "\n".join(lines) + "\n"

    assert summary is not None
    lines += [
        "## Result: call succeeded",
        "",
        f"- **Records returned:** {summary['records_returned']}",
        f"- **Reported total (API's own `total` field):** {summary['reported_total']}",
        f"- **Reported count (API's own `count` field):** {summary['reported_count']}",
        f"- **Lat/lng present on records:** {'yes' if summary['has_lat_lng'] else 'no'}",
        "",
        "### Available fields",
        "",
        "".join(f"- `{f}`\n" for f in summary["fields"]) or "_none_",
        "### Sample station names",
        "",
        "".join(f"- {s}\n" for s in summary["sample_station_names"]) or "_none_",
        "### Timestamp examples (`last_update`)",
        "",
        "".join(f"- {t}\n" for t in summary["timestamp_examples"]) or "_none_",
        "### Pollutant IDs seen",
        "",
        "".join(f"- {p}\n" for p in summary["pollutant_ids"]) or "_none_",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    if not config.DATA_GOV_API_KEY:
        print("DATA_GOV_API_KEY is not set — copy ingest/.env.example to ingest/.env and fill it in.")
        return 1

    error: str | None = None
    summary: dict | None = None
    try:
        payload = fetch_delhi_sample()
        summary = summarize(payload)
    except httpx.HTTPStatusError as exc:
        # exc.request.url includes the api-key query param - never print the
        # request object itself, only the status line.
        error = f"HTTP {exc.response.status_code} from data.gov.in (see docs/data/data-gov-cpcb-authenticated-audit.md)."
    except httpx.HTTPError as exc:
        error = f"{type(exc).__name__}: request failed."

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(render_report(summary, error))

    if error:
        print(f"Call failed: {error}")
        print(f"Report written to {REPORT_PATH}")
        return 1

    assert summary is not None
    print(f"Records returned: {summary['records_returned']}")
    print(f"Available fields: {', '.join(summary['fields'])}")
    print(f"Sample station names: {', '.join(summary['sample_station_names'])}")
    print(f"Timestamp examples: {', '.join(summary['timestamp_examples'])}")
    print(f"Pollutant IDs: {', '.join(summary['pollutant_ids'])}")
    print(f"Lat/lng present: {'yes' if summary['has_lat_lng'] else 'no'}")
    print(f"Report written to {REPORT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
