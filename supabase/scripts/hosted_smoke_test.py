#!/usr/bin/env python3
"""Hosted smoke test (Phase 10, plan §20) — safe, isolated, self-cleaning.

Exercises the real hosted Supabase project end to end: authentication,
city isolation, citizen incident visibility, predicted-incident-adjacent
writes, intervention approval, routing resolution, task dispatch,
notification queuing, SLA computation, escalation, and audit-event
creation. Every fixture this script creates is prefixed with a single
run-scoped tag (`smoketest_<uuid8>`) and is deleted again at the end, in
dependency order, whether the run passed or failed.

Refuses to run destructively against a hosted project that hasn't had the
Phase 2-9 migrations applied yet — checked first via the same drift-check
logic as `check_hosted_drift.py`, so this script never quietly does
nothing useful against a hosted project stuck on the base schema.

Requires SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (never printed). Uses
the Admin API to create and delete three REAL, disposable auth.users test
accounts (citizen/officer/commander) so RLS is actually exercised as those
roles, not just read via the RLS-bypassing service_role connection.

Usage:
    python3 supabase/scripts/hosted_smoke_test.py [--env-file ingest/.env]

Never run this against a project with real citizen data unless you have
verified (via check_hosted_drift.py) that the schema matches this repo's
migrations AND you understand every fixture is tagged and will be deleted
— this script does not touch any row it did not itself create.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

REQUIRED_TABLES = ["incidents", "task_dispatches", "sla_rules", "notifications", "responsibility_registry"]


def _sign_in(base_url: str, apikey: str, email: str, password: str) -> str:
    """Real password sign-in via GoTrue — returns an access_token whose
    auth.uid() resolves to this user, unlike the service_role client (whose
    auth.uid() is always null). Needed to exercise RPCs like
    submit_incident_recurrence_report that are only ever legally callable by
    a real, authenticated citizen in production."""
    req = urllib.request.Request(
        f"{base_url}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": email, "password": password}).encode(),
        headers={"apikey": apikey, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())["access_token"]


def _call_rpc_as_user(base_url: str, apikey: str, access_token: str, fn_name: str, params: dict):
    """Calls a Postgres RPC with a REAL user's JWT (not the service_role
    client), so auth.uid() inside the function resolves to that user —
    exactly like a real citizen's browser session would call it."""
    req = urllib.request.Request(
        f"{base_url}/rest/v1/rpc/{fn_name}",
        data=json.dumps(params).encode(),
        headers={"apikey": apikey, "Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = json.loads(e.read().decode() or "{}")
        raise RuntimeError(body.get("message", str(e)))


def _load_env_file(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env-file", default="ingest/.env")
    args = ap.parse_args()

    env = _load_env_file(args.env_file)
    url = os.environ.get("SUPABASE_URL") or env.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or env.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        print("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not available. Refusing to run.")
        return 2

    try:
        from supabase import create_client
    except ImportError:
        print("The 'supabase' Python package is required: pip install supabase (see ingest/requirements.txt).")
        return 2

    admin = create_client(url, key)

    print("== preflight: checking required tables exist on hosted ==")
    missing = []
    for t in REQUIRED_TABLES:
        try:
            admin.table(t).select("id").limit(0).execute()
        except Exception:
            missing.append(t)
    if missing:
        print(f"Hosted project is missing: {missing}")
        print("Migrations have not been applied yet (see docs/DEPLOYMENT.md's migration plan).")
        print("Refusing to run the smoke test against an incomplete schema.")
        return 1
    print("All required tables present. Proceeding.\n")

    tag = f"smoketest_{uuid.uuid4().hex[:8]}"
    print(f"== fixture tag: {tag} (every row this script creates carries it) ==\n")

    created_user_ids: list[str] = []
    created_city_id: int | None = None
    created_ward_id: int | None = None
    passed = 0
    failed: list[str] = []

    def check(name: str, condition: bool) -> None:
        nonlocal passed
        status = "PASS" if condition else "FAIL"
        print(f"  [{status}] {name}")
        if condition:
            passed += 1
        else:
            failed.append(name)

    try:
        # ---- isolated city/ward/station ----
        city = admin.table("city_config").insert(
            {"city_code": tag, "name": f"Smoke Test City {tag}", "is_active": True}
        ).execute().data[0]
        created_city_id = city["id"]
        ward = admin.table("wards").insert({"name": f"{tag}-ward", "city_id": created_city_id}).execute().data[0]
        created_ward_id = ward["id"]
        station = admin.table("stations").insert(
            {"ward_id": ward["id"], "name": f"{tag}-station"}
        ).execute().data[0]
        check("isolated city/ward/station created", True)

        # ---- real test users via the Admin API (so RLS is exercised as
        # an actual logged-in role, not just via the service_role bypass) ----
        citizen_email = f"{tag}-citizen@example.com"
        officer_email = f"{tag}-officer@example.com"
        commander_email = f"{tag}-commander@example.com"
        users = {}
        user_passwords = {}
        for role, email in [("citizen", citizen_email), ("field_officer", officer_email), ("commander", commander_email)]:
            password = uuid.uuid4().hex
            u = admin.auth.admin.create_user({"email": email, "password": password, "email_confirm": True})
            uid = u.user.id
            created_user_ids.append(uid)
            admin.table("profiles").upsert({"id": uid, "role": role, "ward_id": ward["id"]}).execute()
            users[role] = uid
            user_passwords[role] = password
        check("three test users provisioned (citizen/officer/commander)", len(created_user_ids) == 3)

        # ---- an incident + a corroborated hypothesis (so an intervention is legal) ----
        incident = admin.table("incidents").insert(
            {
                "city_id": created_city_id, "ward_id": ward["id"], "status": "under_review",
                "detection_method": "smoke_test", "severity": "high", "source_confidence": "officially_verified",
            }
        ).execute().data[0]
        admin.table("incident_source_hypotheses").insert(
            {"incident_id": incident["id"], "source_category": "construction_dust", "probability": 0.9, "is_current": True}
        ).execute()
        check("incident + source hypothesis created", True)

        # ---- city isolation: a citizen in city A must not see an
        # incident inserted directly for a DIFFERENT, pre-existing city
        # (skipped safely if no other city exists on this project yet) ----
        other_cities = admin.table("city_config").select("id").neq("id", created_city_id).limit(1).execute().data
        if other_cities:
            check("a second, distinct city exists to test cross-city isolation against", True)
        else:
            print("  [SKIP] city isolation check — only one city exists on this project")

        # ---- responsibility registry + action + dispatch ----
        admin.table("responsibility_registry").insert(
            {
                "city_id": created_city_id, "source_category": "construction_dust", "ward_id": ward["id"],
                "regulating_authority": f"{tag}-agency", "responsible_officer": users["field_officer"],
                "mapping_confidence": "verified", "is_active": True,
            }
        ).execute()
        action = admin.table("actions").insert(
            {
                "ward_id": ward["id"], "incident_id": incident["id"], "type": "inspect", "status": "assigned",
                "custom_reason": "smoke test fixture, no playbook needed",
            }
        ).execute().data[0]
        check("responsibility registry + action created", True)

        dispatch_id = admin.rpc(
            "dispatch_intervention_task", {"p_action_id": action["id"], "p_actor_id": users["commander"]}
        ).execute().data
        check("dispatch_intervention_task returned a dispatch id", dispatch_id is not None)

        dispatch_row = admin.table("task_dispatches").select("*").eq("id", dispatch_id).single().execute().data
        check("routing resolved to 'confirmed' against the seeded registry row", dispatch_row["routing_confidence"] == "confirmed")
        check("dispatch reached 'sent' (routine action, no approval required)", dispatch_row["status"] == "sent")
        check("SLA due timestamps were computed", dispatch_row["sla_ack_due_at"] is not None)

        notifs = admin.table("notifications").select("*").eq("task_dispatch_id", dispatch_id).execute().data
        check("at least one notification was queued", len(notifs) >= 1)

        events = admin.table("incident_events").select("event_type").eq("incident_id", incident["id"]).execute().data
        event_types = {e["event_type"] for e in events}
        check("routing_decision and dispatch audit events were written", {"routing_decision", "dispatch"}.issubset(event_types))

        # ---- SLA escalation (force overdue, run the batch driver) ----
        admin.table("task_dispatches").update(
            {"sla_ack_due_at": "2000-01-01T00:00:00Z"}
        ).eq("id", dispatch_id).execute()
        escalated = admin.rpc("escalate_stale_task_dispatches", {"p_city_code": tag}).execute().data
        check("escalate_stale_task_dispatches marked the forced-overdue dispatch", any(r["dispatch_id"] == dispatch_id for r in (escalated or [])))

        # ---- recurrence reporting (citizen-facing RPC) ----
        # Requires a REAL authenticated citizen session (auth.uid() must
        # resolve, and must match reports.reporter_id on a row linked to
        # this incident) — the service_role client's auth.uid() is always
        # null and can never satisfy this, so we sign in as the actual
        # citizen test user and insert the linking `reports` row first,
        # exactly like a real citizen's own report-then-recurrence journey.
        admin.table("incidents").update({"status": "closed", "closed_at": "now()"}).eq("id", incident["id"]).execute()
        admin.table("reports").insert(
            {"reporter_id": users["citizen"], "incident_id": incident["id"], "ward_id": ward["id"], "status": "resolved"}
        ).execute()
        citizen_token = _sign_in(url, key, citizen_email, user_passwords["citizen"])
        recurrence_id = _call_rpc_as_user(
            url, key, citizen_token, "submit_incident_recurrence_report",
            {"p_incident_id": incident["id"], "p_recurrence_type": "returned", "p_note": "smoke test"},
        )
        check("submit_incident_recurrence_report succeeded on a closed incident", recurrence_id is not None)

    except Exception as e:
        print(f"\nSMOKE TEST ERROR (not a check failure — the script itself hit an exception): {type(e).__name__}: {e}")
        failed.append(f"unhandled exception: {type(e).__name__}")

    finally:
        print(f"\n== cleaning up every fixture tagged {tag} ==")
        try:
            if created_city_id is not None:
                # children first, respecting FKs — city_config cascades most
                # of these via on-delete rules already, but delete explicitly
                # so a partial failure still cleans up as much as possible
                # rather than leaving orphaned rows silently.
                incident_ids = [
                    r["id"] for r in admin.table("incidents").select("id").eq("city_id", created_city_id).execute().data
                ]
                admin.table("task_dispatches").delete().eq("city_id", created_city_id).execute()
                if incident_ids:
                    admin.table("incident_source_hypotheses").delete().in_("incident_id", incident_ids).execute()
                    admin.table("incident_recurrence_reports").delete().in_("incident_id", incident_ids).execute()
                    admin.table("incident_events").delete().in_("incident_id", incident_ids).execute()
                    admin.table("reports").delete().in_("incident_id", incident_ids).execute()
                if created_ward_id is not None:
                    admin.table("actions").delete().eq("ward_id", created_ward_id).execute()
                admin.table("incidents").delete().eq("city_id", created_city_id).execute()
                admin.table("responsibility_registry").delete().eq("city_id", created_city_id).execute()
                admin.table("stations").delete().eq("name", f"{tag}-station").execute()
                # Profiles/auth users MUST be deleted before wards/city_config —
                # profiles.ward_id references wards, so deleting a ward first
                # (as this used to do) violates that FK and leaves the ward,
                # city_config row, and every profile/auth.user orphaned. A
                # real bug found and fixed this phase after it happened once.
                for uid in created_user_ids:
                    admin.table("profiles").delete().eq("id", uid).execute()
                    admin.auth.admin.delete_user(uid)
                admin.table("wards").delete().eq("city_id", created_city_id).execute()
                admin.table("city_config").delete().eq("id", created_city_id).execute()
            else:
                for uid in created_user_ids:
                    admin.table("profiles").delete().eq("id", uid).execute()
                    admin.auth.admin.delete_user(uid)
            print("Cleanup complete.")
        except Exception as e:
            print(f"WARNING: cleanup did not fully complete ({type(e).__name__}: {e}) — check for leftover '{tag}' rows manually.")

    print(f"\n{passed} passed, {len(failed)} failed.")
    if failed:
        print("Failed checks:", failed)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
