"""FastAPI service: hourly ingestion of OpenAQ + Open-Meteo into Supabase.

Run locally:  uvicorn app.main:app --port 8000
Trigger now:  curl -X POST localhost:8000/run
"""

import logging
import threading
from contextlib import asynccontextmanager

from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import FastAPI, HTTPException

from . import config, ingest

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

_lock = threading.Lock()
_last_run: dict | None = None


def run_ingest() -> dict:
    global _last_run
    if not _lock.acquire(blocking=False):
        raise RuntimeError("ingest already running")
    try:
        _last_run = ingest.run()
        return _last_run
    finally:
        _lock.release()


@asynccontextmanager
async def lifespan(app: FastAPI):
    config.require_env()
    scheduler = BackgroundScheduler(timezone="UTC")
    # minute 10 each hour: CPCB/DPCC stations publish on the hour, give them a head start
    scheduler.add_job(run_ingest, "cron", minute=10)
    scheduler.start()
    # first pull immediately so history starts accumulating now
    threading.Thread(target=run_ingest, daemon=True).start()
    yield
    scheduler.shutdown(wait=False)


app = FastAPI(title="Vayu Gati ingest", lifespan=lifespan)


@app.get("/health")
def health():
    return {"ok": True, "last_run": _last_run}


@app.post("/run")
def trigger_run():
    try:
        return run_ingest()
    except RuntimeError as e:
        raise HTTPException(status_code=409, detail=str(e))
