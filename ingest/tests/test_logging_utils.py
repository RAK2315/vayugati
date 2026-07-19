"""Phase 10 job-run tracking tests: run_tracked's four real behaviours —
success, lock contention (never calls fn), a failing fn (caught, never
re-raised), and a bookkeeping failure (still runs fn, doesn't lose the
job). All against a fully mocked db.client() — no live Supabase."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import logging_utils  # noqa: E402


class _FakeResponse:
    def __init__(self, data):
        self.data = data


class _FakeRpc:
    def __init__(self, data, calls, name, params):
        self._data = data
        calls.append((name, params))

    def execute(self):
        return _FakeResponse(self._data)


class _FakeClient:
    """rpc_data maps rpc name -> return value (or an Exception instance to raise)."""

    def __init__(self, rpc_data, calls):
        self._rpc_data = rpc_data
        self._calls = calls

    def rpc(self, name, params):
        value = self._rpc_data.get(name)
        if isinstance(value, Exception):
            raise value
        return _FakeRpc(value, self._calls, name, params)


def test_run_tracked_calls_fn_and_completes_on_success(monkeypatch):
    calls = []
    fake = _FakeClient({"start_job_run": 42, "complete_job_run": None}, calls)
    monkeypatch.setattr(logging_utils.db, "client", lambda: fake)

    result = logging_utils.run_tracked("forecast", lambda: {"ok": True})

    assert result == {"ok": True}
    names = [c[0] for c in calls]
    assert names == ["start_job_run", "complete_job_run"]
    assert calls[1][1]["p_run_id"] == 42


def test_run_tracked_skips_fn_entirely_on_lock_contention(monkeypatch):
    calls = []
    fake = _FakeClient({"start_job_run": None}, calls)
    monkeypatch.setattr(logging_utils.db, "client", lambda: fake)
    fn_called = []

    result = logging_utils.run_tracked("anomaly_detection", lambda: fn_called.append(1))

    assert result is None
    assert fn_called == []  # fn must NEVER be called when the lock is contended
    assert [c[0] for c in calls] == ["start_job_run"]


def test_run_tracked_never_reraises_a_failing_fn(monkeypatch):
    calls = []
    fake = _FakeClient({"start_job_run": 7, "fail_job_run": None}, calls)
    monkeypatch.setattr(logging_utils.db, "client", lambda: fake)

    def boom():
        raise ValueError("synthetic failure")

    result = logging_utils.run_tracked("attribution", boom)  # must not raise

    assert result is None
    names = [c[0] for c in calls]
    assert names == ["start_job_run", "fail_job_run"]
    assert calls[1][1]["p_run_id"] == 7
    assert "synthetic failure" in calls[1][1]["p_error_message"]
    assert calls[1][1]["p_error_category"] == "validation"


def test_run_tracked_still_runs_fn_when_start_job_run_itself_fails(monkeypatch):
    calls = []
    fake = _FakeClient({"start_job_run": RuntimeError("db blip")}, calls)
    monkeypatch.setattr(logging_utils.db, "client", lambda: fake)

    result = logging_utils.run_tracked("ingest", lambda: "ran anyway")

    # Losing job_runs tracking must never mean losing the job itself.
    assert result == "ran anyway"


def test_categorize_error_maps_common_exception_types():
    assert logging_utils.categorize_error(ValueError("x")) == "validation"
    assert logging_utils.categorize_error(TimeoutError("x")) == "timeout"
    assert logging_utils.categorize_error(ConnectionError("x")) == "network"
    assert logging_utils.categorize_error(RuntimeError("x")) == "unknown"
