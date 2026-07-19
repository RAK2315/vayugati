"""Phase 9 escalation-driver test: dispatch.py is a thin RPC wrapper around
escalate_stale_task_dispatches() (Postgres) — the escalation RULES are tested
in supabase/tests/100_authority_routing_and_dispatch.sql, not here. This just
proves the wrapper calls the RPC and summarises the result correctly."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import dispatch  # noqa: E402


class _FakeResponse:
    def __init__(self, data):
        self.data = data


class _FakeRpc:
    def __init__(self, data, captured):
        self._data = data
        self._captured = captured

    def execute(self):
        return _FakeResponse(self._data)


class _FakeClient:
    def __init__(self, data, captured):
        self._data = data
        self._captured = captured

    def rpc(self, name, params):
        self._captured["name"] = name
        self._captured["params"] = params
        return _FakeRpc(self._data, self._captured)


def test_run_calls_the_escalation_rpc_and_counts_results(monkeypatch):
    captured = {}
    fake_rows = [{"dispatch_id": 1, "new_status": "overdue"}, {"dispatch_id": 2, "new_status": "escalated"}]
    monkeypatch.setattr(dispatch.db, "client", lambda: _FakeClient(fake_rows, captured))

    result = dispatch.run("delhi")

    assert result == {"tasks_escalated": 2}
    assert captured["name"] == "escalate_stale_task_dispatches"
    assert captured["params"] == {"p_city_code": "delhi"}


def test_run_handles_no_stale_tasks(monkeypatch):
    captured = {}
    monkeypatch.setattr(dispatch.db, "client", lambda: _FakeClient([], captured))

    result = dispatch.run()

    assert result == {"tasks_escalated": 0}
    assert captured["params"] == {"p_city_code": None}
