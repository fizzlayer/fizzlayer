#!/usr/bin/env python3
"""Write the public SPA config. Refuses a service-role key. Never prints secrets."""

import base64
import json
import os
import sys
from typing import Optional


def fail(message: str) -> None:
    sys.stderr.write(message + "\n")
    sys.exit(1)


def jwt_payload(key: str) -> Optional[dict]:
    parts = key.split(".")
    if len(parts) != 3:
        return None
    try:
        padded = parts[1] + "=" * (-len(parts[1]) % 4)
        parsed = json.loads(base64.urlsafe_b64decode(padded))
        return parsed if isinstance(parsed, dict) else None
    except Exception:
        return None


def accept_key(key: str) -> None:
    if not key:
        return
    service = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if service and key == service:
        fail("SUPABASE_ANON_KEY is the service-role key. Refusing to embed it.")
    payload = jwt_payload(key)
    if payload is not None:
        role = payload.get("role")
        if role == "service_role" or "service_role" in json.dumps(payload):
            fail("SUPABASE_ANON_KEY looks like a service_role credential. Refusing to embed it.")
        if role != "anon":
            fail("SUPABASE_ANON_KEY must be the anon JWT or a publishable key.")
        return
    if key.startswith("sb_publishable_") and " " not in key and "service_role" not in key and len(key) > 20:
        return
    fail("SUPABASE_ANON_KEY must be the anon JWT or a publishable key.")


def accept_url(url: str) -> None:
    if not url:
        return
    if "@" in url or " " in url:
        fail("SUPABASE_URL isn't usable from the browser.")
    if url.startswith("https://") and len(url) > len("https://"):
        return
    if url.startswith("http://localhost:") or url.startswith("http://127.0.0.1:"):
        return
    fail("SUPABASE_URL must be https, or http on localhost.")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: write_spa_config.py OUTPUT")
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_ANON_KEY", "").strip() or os.environ.get(
        "SUPABASE_PUBLISHABLE_KEY", ""
    ).strip()
    accept_url(url)
    accept_key(key)
    out = sys.argv[1]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"supabaseUrl": url, "supabaseAnonKey": key}, handle)
        handle.write("\n")
    os.chmod(out, 0o644)
    if url and key:
        print("wrote spa config")
    else:
        print("wrote spa config (sign-in disabled until SUPABASE_URL and SUPABASE_ANON_KEY are set)")


if __name__ == "__main__":
    main()
