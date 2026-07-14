"""FastAPI service: hourly ingestion of OpenAQ + Open-Meteo into Supabase.

Run locally:  uvicorn app.main:app --port 8000
Trigger now:  curl -X POST localhost:8000/run
"""

import logging
import threading
from contextlib import asynccontextmanager

from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from . import attribution
from . import classify as classify_mod
from . import config, db, forecast, ingest

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

_lock = threading.Lock()
_intel_lock = threading.Lock()
_last_run: dict | None = None
_last_intel: dict | None = None


def run_ingest() -> dict:
    global _last_run
    if not _lock.acquire(blocking=False):
        raise RuntimeError("ingest already running")
    try:
        _last_run = ingest.run()
        return _last_run
    finally:
        _lock.release()


def run_intel() -> dict:
    """Forecast + attribution pass. Runs after ingest so it sees fresh readings."""
    global _last_intel
    if not _intel_lock.acquire(blocking=False):
        raise RuntimeError("intel already running")
    try:
        _last_intel = {"forecast": forecast.run(), "attribution": attribution.run()}
        return _last_intel
    finally:
        _intel_lock.release()


@asynccontextmanager
async def lifespan(app: FastAPI):
    config.require_env()
    scheduler = BackgroundScheduler(timezone="UTC")
    # minute 10 each hour: CPCB/DPCC stations publish on the hour, give them a head start
    scheduler.add_job(run_ingest, "cron", minute=10)
    # minute 25: recompute forecast + attribution on the freshly-ingested data
    scheduler.add_job(run_intel, "cron", minute=25)
    scheduler.start()

    # first pass immediately: ingest, then intel once readings land
    def _bootstrap():
        try:
            run_ingest()
        except Exception:
            logging.exception("bootstrap ingest failed")
        try:
            run_intel()
        except Exception:
            logging.exception("bootstrap intel failed")

    threading.Thread(target=_bootstrap, daemon=True).start()
    yield
    scheduler.shutdown(wait=False)


app = FastAPI(title="Vayu Gati ingest", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten to Vercel domain in production
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


class ClassifyRequest(BaseModel):
    report_id: int
    description: str
    ward_name: str
    photo_url: str | None = None


@app.get("/health")
def health():
    return {"ok": True, "last_run": _last_run, "last_intel": _last_intel}


@app.post("/run")
def trigger_run():
    try:
        return run_ingest()
    except RuntimeError as e:
        raise HTTPException(status_code=409, detail=str(e))


@app.post("/intel")
def trigger_intel():
    """Recompute forecast + attribution now."""
    try:
        return run_intel()
    except RuntimeError as e:
        raise HTTPException(status_code=409, detail=str(e))


@app.post("/classify")
def classify(req: ClassifyRequest):
    """Classify a report and write ai_category + ai_meta back to the reports row."""
    result = classify_mod.classify_report(req.description, req.ward_name, req.photo_url)
    db.client().table("reports").update(
        {
            "ai_category": result["category"],
            "ai_meta": {
                "confidence": result.get("confidence"),
                "note_draft": result.get("note_draft"),
                "hindi_advisory": result.get("hindi_advisory"),
            },
        }
    ).eq("id", req.report_id).execute()
    return result
