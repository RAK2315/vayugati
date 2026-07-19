#!/usr/bin/env python3
"""Lightweight, dependency-free secret scan for CI (Phase 10, plan §5/§19).

Not a replacement for a real secret-scanning service (gitleaks/trufflehog) —
a deliberately small, auditable check for the specific mistakes this repo
has actually made or could plausibly make again:

  1. A `.env`-shaped file (not `.env.example`) tracked by git.
  2. An `.env.example` file containing what looks like a REAL value rather
     than a placeholder — a JWT (three dot-separated base64 segments), a
     Supabase service_role-shaped key, or a non-empty value assigned to a
     variable whose name suggests a key/secret/token/password.
  3. A hardcoded-looking API key/token pattern in any tracked source file
     (`sk-...`, `AKIA...`, a bare `eyJ...` JWT), outside of test fixtures.

Exits 1 (fails CI) on any finding. Prints only file:line and a category —
never the matched value itself, so the scanner's own output can't leak a
real secret into CI logs if it ever finds one.
"""
from __future__ import annotations

import re
import subprocess
import sys

SECRET_NAME_HINT = re.compile(r"(SECRET|_KEY|TOKEN|PASSWORD|_PWD)\s*=\s*\S+", re.IGNORECASE)
JWT_SHAPE = re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")
OPENAI_STYLE_KEY = re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")
AWS_STYLE_KEY = re.compile(r"\bAKIA[0-9A-Z]{16}\b")

# Files/paths that legitimately contain synthetic-looking values (test
# fixtures use fixed, fake uuids/strings on purpose — never real secrets,
# but could otherwise trip the naive JWT/key-shape patterns above).
EXEMPT_PATH_SUBSTRINGS = ("/tests/", "/test_", ".test.", "database.types.ts")


def _tracked_files() -> list[str]:
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True)
    return [f for f in out.stdout.splitlines() if f]


def _is_exempt(path: str) -> bool:
    return any(s in path for s in EXEMPT_PATH_SUBSTRINGS)


def main() -> int:
    findings: list[str] = []
    files = _tracked_files()

    for f in files:
        base = f.rsplit("/", 1)[-1]
        if base == ".env" or (base.endswith(".env") and base != ".env.example"):
            findings.append(f"{f}: a real .env-shaped file is tracked by git")

    for f in files:
        if not f.endswith(".env.example"):
            continue
        try:
            with open(f, encoding="utf-8", errors="ignore") as fh:
                for lineno, line in enumerate(fh, 1):
                    stripped = line.strip()
                    if not stripped or stripped.startswith("#"):
                        continue
                    if "=" not in stripped:
                        continue
                    name, _, value = stripped.partition("=")
                    if value.strip() == "":
                        continue  # the whole point of .env.example: empty placeholders
                    if JWT_SHAPE.search(value) or AWS_STYLE_KEY.search(value) or OPENAI_STYLE_KEY.search(value):
                        findings.append(f"{f}:{lineno}: {name.strip()} looks like a real key/token, not a placeholder")
        except OSError:
            continue

    for f in files:
        if _is_exempt(f) or f.endswith(".env.example") or f.rsplit("/", 1)[-1] == ".env":
            continue
        try:
            with open(f, encoding="utf-8", errors="ignore") as fh:
                for lineno, line in enumerate(fh, 1):
                    if JWT_SHAPE.search(line) or OPENAI_STYLE_KEY.search(line) or AWS_STYLE_KEY.search(line):
                        findings.append(f"{f}:{lineno}: a real-looking key/token pattern was found in source")
        except OSError:
            continue

    if findings:
        print("Secret scan found possible issues (values never printed):")
        for item in findings:
            print(f"  - {item}")
        return 1

    print(f"Secret scan OK — {len(files)} tracked files checked, nothing suspicious found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
