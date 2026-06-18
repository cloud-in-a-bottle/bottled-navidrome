"""First-boot helper: ensure a Navidrome admin user exists.

Navidrome refuses to honour reverse-proxy (ext-auth) login until at least
one admin user exists; otherwise it forces its interactive "create admin"
wizard.  We can't seed the user directly in SQLite because Navidrome stores
passwords encrypted at rest (a hand-written row fails decryption on login),
so instead we drive Navidrome's own first-run endpoint, which creates the
admin with a correctly-encrypted (random, unused) password.

The OpenHost owner subsequently logs in via the trusted reverse-proxy
Remote-User header, never this password.

Usage: python3 seed_admin.py <owner_username>
Idempotent: if an admin already exists (firstTime == false), it exits 0.
"""

from __future__ import annotations

import http.client
import json
import os
import secrets
import sys
import time

PORT = int(os.environ.get("ND_PORT", "4533"))
HOST = "127.0.0.1"
HOSTHDR = f"{HOST}:{PORT}"


def _get(path: str) -> tuple[int, str]:
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        conn.request("GET", path, headers={"Host": HOSTHDR})
        resp = conn.getresponse()
        return resp.status, resp.read().decode("utf-8", "replace")
    finally:
        conn.close()


def _post_json(path: str, payload: dict) -> tuple[int, str]:
    body = json.dumps(payload)
    conn = http.client.HTTPConnection(HOST, PORT, timeout=10)
    try:
        conn.request(
            "POST",
            path,
            body,
            {"Content-Type": "application/json", "Host": HOSTHDR},
        )
        resp = conn.getresponse()
        return resp.status, resp.read().decode("utf-8", "replace")
    finally:
        conn.close()


def main() -> int:
    username = sys.argv[1] if len(sys.argv) > 1 else "admin"
    password = secrets.token_urlsafe(24)

    # Wait for Navidrome to start serving, and decide whether setup is needed.
    needs_setup = False
    for _ in range(90):
        try:
            status, html = _get("/app/")
        except OSError:
            time.sleep(1)
            continue
        if status == 200:
            if '"firstTime":false' in html:
                print("[seed] admin already exists; nothing to do")
                return 0
            if '"firstTime":true' in html:
                needs_setup = True
                break
            # Served but firstTime flag not found; give it another beat.
        time.sleep(1)

    if not needs_setup:
        print("[seed] could not confirm first-run state; skipping admin creation")
        return 0

    status, body = _post_json("/auth/createAdmin", {"username": username, "password": password})
    if status in (200, 201):
        print(f"[seed] created admin '{username}' via /auth/createAdmin")
        return 0
    print(f"[seed] createAdmin returned status={status} body={body[:300]!r}")
    # Don't fail the boot; worst case the owner sees the create-admin screen.
    return 0


if __name__ == "__main__":
    sys.exit(main())
