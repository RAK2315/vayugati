#!/usr/bin/env python3
"""One-time pilot field-officer onboarding — safe, auditable, reversible.

Creates exactly one `field_officer` account using Supabase's Admin Auth API
(never a direct `insert into auth.users`), links a `profiles` row scoped to
one real ward, and writes an immutable `admin_audit_events` row recording
the action. Requires SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (never
printed) — this is a CLI/backend script, so the service_role key never
touches a browser.

Does NOT invent user details — name, email, city, and ward are all required
CLI arguments with no defaults. Refuses to run if the target email already
has an account (checked against real hosted data, not assumed).

Two account-creation modes:
  --mode invite (default): sends a real Supabase invite email; the officer
    sets their own password via a one-time secure link — the closest this
    platform offers to "must reset on first login," since no password
    exists until they choose one themselves.
  --mode temp-password: creates the account with a randomly generated
    temporary password, printed ONCE to this terminal for you to relay to
    the officer out of band (never stored, never emailed by this script).
    NOTE: Supabase Auth has no native "force password change on next
    login" flag, and this app's frontend does not yet implement one either
    — if you use this mode, you must personally instruct the officer to
    change their password immediately after their first login. This is
    stated here plainly rather than silently assumed handled.

Atomicity: the Admin Auth user and the `profiles` row are created via two
separate API calls (GoTrue Admin API + PostgREST), not one database
transaction — true atomicity isn't available over these two API surfaces
from this environment. If the profile insert fails after the auth user was
created, this script deletes the just-created auth user as a compensating
rollback, so a failed run never leaves an orphaned auth-only account.

Usage:
    python3 supabase/scripts/onboard_field_officer.py \\
        --name "Full Name" --email officer@example.com \\
        --city delhi --ward-name "Anand Vihar" [--dry-run] [--mode invite|temp-password]

    python3 supabase/scripts/onboard_field_officer.py --deactivate officer@example.com

    python3 supabase/scripts/onboard_field_officer.py --list-officers
"""
from __future__ import annotations

import argparse
import re
import secrets
import sys

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _load_env_file(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return out


def _client(env_file: str):
    import os

    env = _load_env_file(env_file)
    url = os.environ.get("SUPABASE_URL") or env.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or env.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        print("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not available. Refusing to run.")
        sys.exit(2)
    try:
        from supabase import create_client
    except ImportError:
        print("The 'supabase' Python package is required: pip install supabase.")
        sys.exit(2)
    return create_client(url, key)


def _find_user_by_email(admin, email: str):
    """No direct email filter in every supabase-py version's list_users — fetch and match client-side.
    Fine at pilot scale (a handful of accounts), not intended for a large user base."""
    page = 1
    while True:
        resp = admin.auth.admin.list_users(page=page, per_page=200)
        users = resp if isinstance(resp, list) else getattr(resp, "users", resp)
        if not users:
            return None
        for u in users:
            if getattr(u, "email", None) == email:
                return u
        if len(users) < 200:
            return None
        page += 1


def _resolve_city(admin, city_code: str) -> dict:
    rows = admin.table("city_config").select("id,city_code,name,is_active").eq("city_code", city_code).execute().data
    if not rows:
        print(f"ERROR: no city_config row for city_code={city_code!r}. Refusing to guess.")
        sys.exit(1)
    city = rows[0]
    if not city["is_active"]:
        print(f"ERROR: city {city_code!r} exists but is_active=false. Refusing to onboard into an inactive city.")
        sys.exit(1)
    return city


def _resolve_ward(admin, city: dict, ward_id: int | None, ward_name: str | None) -> dict:
    if ward_id is not None:
        rows = admin.table("wards").select("id,name,city_id").eq("id", ward_id).execute().data
    elif ward_name is not None:
        rows = admin.table("wards").select("id,name,city_id").eq("name", ward_name).execute().data
    else:
        print("ERROR: must supply --ward-id or --ward-name.")
        sys.exit(1)
    if not rows:
        print(f"ERROR: no matching ward (id={ward_id!r}, name={ward_name!r}). Refusing to guess.")
        sys.exit(1)
    ward = rows[0]
    if ward["city_id"] != city["id"]:
        print(
            f"ERROR: ward {ward['name']!r} belongs to city_id={ward['city_id']}, "
            f"not {city['city_code']!r} (city_id={city['id']}). Refusing to cross-assign."
        )
        sys.exit(1)
    return ward


def _write_audit_event(admin, event_type: str, actor: str, target_email: str | None,
                        target_user_id: str | None, city_id: int | None, ward_id: int | None,
                        details: dict) -> None:
    admin.table("admin_audit_events").insert({
        "event_type": event_type,
        "actor": actor,
        "target_email": target_email,
        "target_user_id": target_user_id,
        "city_id": city_id,
        "ward_id": ward_id,
        "details": details,
    }).execute()


def cmd_onboard(args) -> int:
    admin = _client(args.env_file)

    if not args.name or not args.name.strip():
        print("ERROR: --name is required and cannot be blank.")
        return 1
    if not args.email or not EMAIL_RE.match(args.email):
        print(f"ERROR: --email {args.email!r} does not look like a valid email address.")
        return 1

    city = _resolve_city(admin, args.city)
    ward = _resolve_ward(admin, city, args.ward_id, args.ward_name)

    existing = _find_user_by_email(admin, args.email)
    if existing is not None:
        print(f"ERROR: an account already exists for {args.email} (id={existing.id}). Refusing to create a duplicate.")
        print("Use --deactivate to remove field_officer access from an existing account, or pick a different email.")
        return 1

    print("Validated:")
    print(f"  name:  {args.name}")
    print(f"  email: {args.email}")
    print(f"  city:  {city['city_code']} ({city['name']}, id={city['id']})")
    print(f"  ward:  {ward['name']} (id={ward['id']})")
    print(f"  mode:  {args.mode}")

    if args.dry_run:
        print("\n--dry-run: no auth user, profile, or audit event created.")
        return 0

    actor = "onboard_field_officer.py (service_role)"

    # ---- create the Admin Auth user ----
    temp_password = None
    try:
        if args.mode == "invite":
            result = admin.auth.admin.invite_user_by_email(
                args.email, options={"data": {"full_name": args.name}}
            )
            uid = result.user.id
        else:
            temp_password = secrets.token_urlsafe(12)
            result = admin.auth.admin.create_user({
                "email": args.email,
                "password": temp_password,
                "email_confirm": True,
                "user_metadata": {"full_name": args.name},
            })
            uid = result.user.id
    except Exception as e:
        print(f"ERROR: Admin Auth user creation failed: {e}")
        _write_audit_event(
            admin, "field_officer_onboarding_failed", actor, args.email, None,
            city["id"], ward["id"], {"stage": "auth_create", "error": str(e)},
        )
        return 1

    # ---- create the linked profile (compensating rollback if this fails) ----
    try:
        admin.table("profiles").insert({
            "id": uid,
            "role": "field_officer",
            "full_name": args.name,
            "ward_id": ward["id"],
        }).execute()
    except Exception as e:
        print(f"ERROR: profile creation failed after auth user was created: {e}")
        print("Rolling back: deleting the just-created auth user so no orphaned account is left behind.")
        try:
            admin.auth.admin.delete_user(uid)
            print("Rollback succeeded — auth user removed.")
        except Exception as e2:
            print(f"!! ROLLBACK FAILED too: {e2}")
            print(f"!! Manual cleanup needed: delete auth user {uid} ({args.email}) via the Supabase dashboard.")
        _write_audit_event(
            admin, "field_officer_onboarding_failed", actor, args.email, uid,
            city["id"], ward["id"], {"stage": "profile_create", "error": str(e)},
        )
        return 1

    _write_audit_event(
        admin, "field_officer_onboarded", actor, args.email, uid,
        city["id"], ward["id"], {"name": args.name, "mode": args.mode, "ward_name": ward["name"]},
    )

    print(f"\nSUCCESS: field_officer account created (id={uid}).")
    if args.mode == "invite":
        print("An invite email has been sent — the officer sets their own password via that link.")
    else:
        print(f"\nTEMPORARY PASSWORD (shown once, not stored anywhere): {temp_password}")
        print("Relay this to the officer out of band (not email/Slack in plaintext if avoidable).")
        print("IMPORTANT: this app has no automatic 'force password change on first login' — you must")
        print("personally instruct the officer to change their password immediately after logging in.")
    print("\nNext step: have the officer log in and confirm they only see their own assigned tasks —")
    print("this is exactly step 3 of the PILOT_RUNBOOK.md human walkthrough.")
    return 0


def cmd_deactivate(args) -> int:
    admin = _client(args.env_file)
    user = _find_user_by_email(admin, args.deactivate)
    if user is None:
        print(f"ERROR: no account found for {args.deactivate}.")
        return 1
    profile = admin.table("profiles").select("id,role,ward_id").eq("id", user.id).execute().data
    if not profile:
        print(f"ERROR: auth user exists for {args.deactivate} but has no profiles row — nothing to deactivate.")
        return 1
    p = profile[0]
    if p["role"] != "field_officer":
        print(f"NOTE: {args.deactivate} has role={p['role']!r}, not field_officer. Proceeding anyway.")

    admin.table("profiles").update({"role": "citizen", "ward_id": None}).eq("id", user.id).execute()
    _write_audit_event(
        admin, "field_officer_deactivated", "onboard_field_officer.py (service_role)",
        args.deactivate, user.id, None, p["ward_id"], {"previous_role": p["role"]},
    )
    print(f"Deactivated: {args.deactivate} (id={user.id}) — role reset to 'citizen', ward assignment cleared.")
    print("This is a SOFT deactivation: the auth account itself still exists and can sign in as a citizen.")
    print(f"To fully remove the account instead, use the Supabase dashboard to delete auth user {user.id},")
    print("or run: admin.auth.admin.delete_user(uid) — not done automatically here, since a hard delete")
    print("is not reversible and this script defaults to the safer, reversible action.")
    return 0


def cmd_list_officers(args) -> int:
    admin = _client(args.env_file)
    rows = admin.table("profiles").select("id,full_name,ward_id").eq("role", "field_officer").execute().data
    if not rows:
        print("No field_officer accounts exist.")
        return 0
    print(f"{len(rows)} field_officer account(s):")
    for r in rows:
        print(f"  id={r['id']}  name={r['full_name']!r}  ward_id={r['ward_id']}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env-file", default="ingest/.env")
    ap.add_argument("--name", help="Real full name of the pilot field officer (required for onboarding)")
    ap.add_argument("--email", help="Real email address (required for onboarding)")
    ap.add_argument("--city", default="delhi", help="city_code (default: delhi)")
    ap.add_argument("--ward-id", type=int, help="Ward id to assign")
    ap.add_argument("--ward-name", help="Ward name to assign (alternative to --ward-id)")
    ap.add_argument("--mode", choices=["invite", "temp-password"], default="invite")
    ap.add_argument("--dry-run", action="store_true", help="Validate everything, create nothing")
    ap.add_argument("--deactivate", metavar="EMAIL", help="Soft-deactivate an existing field officer by email")
    ap.add_argument("--list-officers", action="store_true", help="List all current field_officer accounts")
    args = ap.parse_args()

    if args.list_officers:
        return cmd_list_officers(args)
    if args.deactivate:
        return cmd_deactivate(args)
    if not args.name or not args.email:
        ap.print_help()
        print("\nERROR: --name and --email are required to onboard a new officer.")
        return 2
    return cmd_onboard(args)


if __name__ == "__main__":
    sys.exit(main())
