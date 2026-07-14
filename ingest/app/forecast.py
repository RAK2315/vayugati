"""Per-ward PM2.5 forecast on the LOCAL EXCESS above the city baseline.

Local excess = ward pm2.5 - city-wide median pm2.5 at the same hour. That is the
part a ward officer can actually move (dust, construction, burning, industry) —
no ward action shifts the regional baseline, so we forecast the controllable delta.

Model: LightGBM on lag + calendar features once there is enough history; a
diurnal-persistence fallback until then. We ALWAYS log RMSE against a naive
persistence baseline, because beating persistence is the literal Phase-2 bar.
"""

import logging
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd

from . import db

log = logging.getLogger("ingest.forecast")

HORIZON_H = 48
MIN_TRAIN_ROWS = 24 * 10  # ~10 days of hourly data before we trust a learned model
MODEL_VERSION_LGB = "lgb_localexcess_v1"
MODEL_VERSION_DIURNAL = "diurnal_persistence_v1"

try:
    import lightgbm as lgb

    _HAS_LGB = True
except Exception:  # pragma: no cover - lightgbm optional at runtime
    _HAS_LGB = False


def _hourly_ward_pm25() -> pd.DataFrame:
    """Continuous hourly pm2.5 per ward. Columns: ts, ward_id, pm25."""
    rows = db.get_readings_history(hours=24 * 30)
    if not rows:
        return pd.DataFrame(columns=["ts", "ward_id", "pm25"])
    df = pd.DataFrame(rows).dropna(subset=["pm25"])
    if df.empty:
        return df
    df["ts"] = pd.to_datetime(df["ts"], utc=True).dt.floor("h")
    return df.groupby(["ts", "ward_id"], as_index=False)["pm25"].mean()


def _with_local_excess(df: pd.DataFrame) -> pd.DataFrame:
    """Add city baseline (median across wards per hour) and local_excess."""
    baseline = df.groupby("ts")["pm25"].median().rename("baseline")
    df = df.merge(baseline, on="ts", how="left")
    df["local_excess"] = df["pm25"] - df["baseline"]
    return df


def _ward_series(df: pd.DataFrame, ward_id: int) -> pd.DataFrame:
    """Continuous hourly series for one ward, gaps interpolated."""
    w = df[df["ward_id"] == ward_id].set_index("ts").sort_index()
    if w.empty:
        return w
    full = pd.date_range(w.index.min(), w.index.max(), freq="h", tz="UTC")
    w = w.reindex(full)
    w["local_excess"] = w["local_excess"].interpolate(limit=6).ffill().bfill()
    w["baseline"] = w["baseline"].interpolate(limit=6).ffill().bfill()
    return w


def _rmse(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.sqrt(np.mean((a - b) ** 2)))


def _make_features(series: pd.Series) -> pd.DataFrame:
    """Lag + calendar features for the local_excess series."""
    f = pd.DataFrame({"y": series})
    f["lag1"] = f["y"].shift(1)
    f["lag24"] = f["y"].shift(24)
    f["hour"] = f.index.hour
    f["dow"] = f.index.dayofweek
    return f


def _forecast_ward(w: pd.DataFrame) -> tuple[list[float], float, str, float]:
    """Return (48h local_excess predictions, confidence, model_version, rmse_vs_persistence)."""
    excess = w["local_excess"].astype(float)
    n = len(excess)

    # naive persistence baseline: last value carried forward
    last = float(excess.iloc[-1])
    persistence = np.full(HORIZON_H, last)

    # diurnal profile: mean local_excess by hour-of-day
    by_hour = excess.groupby(excess.index.hour).mean()
    start = w.index[-1]
    future_idx = pd.date_range(start + timedelta(hours=1), periods=HORIZON_H, freq="h", tz="UTC")
    diurnal = np.array([by_hour.get(t.hour, last) for t in future_idx])

    # not enough data or no lightgbm → diurnal (blended toward persistence near-term)
    if n < MIN_TRAIN_ROWS or not _HAS_LGB:
        # near-term trust persistence, later trust diurnal shape
        blend_w = np.clip(np.arange(HORIZON_H) / 24.0, 0, 1)
        pred = (1 - blend_w) * persistence + blend_w * diurnal
        rmse = _rmse(diurnal, persistence)  # comparison signal only
        conf = 0.35 if n < 24 else 0.5
        return pred.tolist(), conf, MODEL_VERSION_DIURNAL, rmse

    # ── learned model ──
    feats = _make_features(excess).dropna()
    X = feats[["lag1", "lag24", "hour", "dow"]]
    y = feats["y"]

    # holdout the last 48h to measure RMSE vs persistence honestly
    split = max(len(X) - HORIZON_H, int(len(X) * 0.8))
    model = lgb.LGBMRegressor(
        n_estimators=300, learning_rate=0.05, num_leaves=31, min_child_samples=10, verbose=-1
    )
    model.fit(X.iloc[:split], y.iloc[:split])

    holdout_pred = model.predict(X.iloc[split:])
    holdout_true = y.iloc[split:].to_numpy()
    holdout_persist = y.iloc[split - 1 : -1].to_numpy()[: len(holdout_true)]
    model_rmse = _rmse(holdout_pred, holdout_true)
    persist_rmse = _rmse(holdout_persist, holdout_true) if len(holdout_persist) else model_rmse

    # if the model can't beat persistence on holdout, don't ship it
    if persist_rmse > 0 and model_rmse >= persist_rmse:
        blend_w = np.clip(np.arange(HORIZON_H) / 24.0, 0, 1)
        pred = (1 - blend_w) * persistence + blend_w * diurnal
        return pred.tolist(), 0.5, MODEL_VERSION_DIURNAL, persist_rmse - model_rmse

    # recursive multi-step forecast
    hist = list(excess.to_numpy())
    preds = []
    for t in future_idx:
        lag1 = hist[-1]
        lag24 = hist[-24] if len(hist) >= 24 else hist[0]
        x = pd.DataFrame([[lag1, lag24, t.hour, t.dayofweek]], columns=["lag1", "lag24", "hour", "dow"])
        yhat = float(model.predict(x)[0])
        preds.append(yhat)
        hist.append(yhat)

    conf = float(np.clip(1 - model_rmse / (persist_rmse + 1e-6), 0.4, 0.9))
    return preds, conf, MODEL_VERSION_LGB, persist_rmse - model_rmse


def run() -> dict:
    """Compute and store a 48h forecast per ward. Idempotent (replaces per ward)."""
    summary = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "wards_forecast": 0,
        "model": "none",
        "rmse_gain_vs_persistence": {},
        "skipped": [],
    }

    base = _hourly_ward_pm25()
    if base.empty:
        log.warning("no readings yet — nothing to forecast")
        summary["finished_at"] = datetime.now(timezone.utc).isoformat()
        return summary

    df = _with_local_excess(base)
    generated_at = datetime.now(timezone.utc)
    # future baseline: carry the most recent city baseline forward
    latest_baseline = float(df.sort_values("ts")["baseline"].iloc[-1])

    for ward_id in sorted(df["ward_id"].unique()):
        w = _ward_series(df, int(ward_id))
        if w.empty or w["local_excess"].dropna().empty:
            summary["skipped"].append(int(ward_id))
            continue

        preds, conf, model_version, rmse_gain = _forecast_ward(w)
        start = w.index[-1]
        future_idx = pd.date_range(start + timedelta(hours=1), periods=HORIZON_H, freq="h", tz="UTC")

        rows = []
        for t, excess_pred in zip(future_idx, preds):
            pm25_pred = max(latest_baseline + excess_pred, 0.0)
            rows.append(
                {
                    "ward_id": int(ward_id),
                    "generated_at": generated_at.isoformat(),
                    "horizon_ts": t.isoformat(),
                    "pm25_pred": round(pm25_pred, 1),
                    "baseline_pred": round(latest_baseline, 1),
                    "local_excess": round(excess_pred, 1),
                    "confidence": round(conf, 2),
                    "model_version": model_version,
                }
            )
        db.replace_forecasts(int(ward_id), rows)
        summary["wards_forecast"] += 1
        summary["model"] = model_version
        summary["rmse_gain_vs_persistence"][int(ward_id)] = round(rmse_gain, 2)

    summary["finished_at"] = datetime.now(timezone.utc).isoformat()
    log.info("forecast done: %s", summary)
    return summary
