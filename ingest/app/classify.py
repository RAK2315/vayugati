"""Claude-based report classification: text -> source_category + officer note + Hindi advisory."""

import base64
import json
import logging
import re

import anthropic
import httpx

from . import config

log = logging.getLogger("ingest.classify")

CATEGORIES = [
    "construction_dust",
    "road_dust",
    "open_burning",
    "industrial",
    "vehicular",
    "waste",
    "other",
]

_SYSTEM = """\
You are an air-pollution enforcement assistant for Delhi, India.

A citizen has filed a pollution complaint, possibly with a photo of the source.
Use both the text and the photo (if present) to classify it and draft two short texts.

Respond with ONLY valid JSON — no prose before or after — in this exact shape:
{
  "category": "<one of: construction_dust | road_dust | open_burning | industrial | vehicular | waste | other>",
  "confidence": <0.0-1.0>,
  "note_draft": "<1-2 sentence enforcement note in English for the field officer>",
  "hindi_advisory": "<1-2 sentence acknowledgement + advisory in Hindi for the citizen>"
}
"""

# media types Claude's vision API accepts
_IMAGE_TYPES = {"image/jpeg", "image/png", "image/gif", "image/webp"}


def _fetch_image_block(photo_url: str) -> dict | None:
    """Download a report photo and return a Claude image content block, or None."""
    try:
        resp = httpx.get(photo_url, timeout=20, follow_redirects=True)
        resp.raise_for_status()
        media_type = resp.headers.get("content-type", "").split(";")[0].strip()
        if media_type not in _IMAGE_TYPES:
            media_type = "image/jpeg"  # best-effort default
        data = base64.standard_b64encode(resp.content).decode("ascii")
        return {
            "type": "image",
            "source": {"type": "base64", "media_type": media_type, "data": data},
        }
    except Exception:
        log.warning("could not fetch report photo: %s", photo_url)
        return None


def classify_report(description: str, ward_name: str, photo_url: str | None = None) -> dict:
    """Call Claude to classify a citizen report (text + optional photo). Returns the JSON dict."""
    api_key = config.ANTHROPIC_API_KEY
    if not api_key:
        log.warning("No ANTHROPIC_API_KEY set — returning stub classification")
        return {
            "category": "other",
            "confidence": 0.0,
            "note_draft": "Classification unavailable: ANTHROPIC_API_KEY not configured.",
            "hindi_advisory": "आपकी शिकायत दर्ज हो गई है।",
        }

    client = anthropic.Anthropic(api_key=api_key)

    content: list[dict] = [{"type": "text", "text": f"Ward: {ward_name}\nComplaint: {description}"}]
    if photo_url:
        block = _fetch_image_block(photo_url)
        if block:
            content.append(block)

    msg = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=400,
        system=_SYSTEM,
        messages=[{"role": "user", "content": content}],
    )

    raw = msg.content[0].text.strip()
    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", raw, re.DOTALL)
        if m:
            result = json.loads(m.group())
        else:
            log.warning("Claude returned non-JSON: %s", raw[:200])
            result = {
                "category": "other",
                "confidence": 0.5,
                "note_draft": raw[:300],
                "hindi_advisory": "आपकी शिकायत दर्ज हो गई है।",
            }

    if result.get("category") not in CATEGORIES:
        result["category"] = "other"

    return result
