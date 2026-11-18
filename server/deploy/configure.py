#!/usr/bin/env python3
"""Create a private first-deployment environment without printing its secrets."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="Public DNS hostname, without https://")
    parser.add_argument("--email", required=True, help="ACME certificate contact email")
    args = parser.parse_args()
    host = args.host.lower()
    if len(host) > 253 or "." not in host or any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in host.split(".")
    ):
        parser.error("--host must be a DNS hostname without a port, path or scheme")
    if not re.fullmatch(r"[A-Za-z0-9.!+_%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}", args.email):
        parser.error("--email must be a valid email address")
    root = Path(__file__).resolve().parent
    content = (root / ".env.example").read_text()
    replacements = {
        "POSTMERE_HOST": host,
        "POSTMERE_ACME_EMAIL": args.email,
        "POSTMERE_ADMIN_DB_PASSWORD": secrets.token_hex(32),
        "POSTMERE_OWNER_DB_PASSWORD": secrets.token_hex(32),
        "POSTMERE_RUNTIME_DB_PASSWORD": secrets.token_hex(32),
        "POSTMERE_CREDENTIAL_KEYS": "'" + json.dumps({"1": base64.b64encode(secrets.token_bytes(32)).decode()}, separators=(",", ":")) + "'",
        "POSTMERE_RATE_LIMIT_KEY": base64.b64encode(secrets.token_bytes(32)).decode(),
    }
    for key, value in replacements.items():
        content = re.sub(rf"^{key}=.*$", lambda _: f"{key}={value}", content, flags=re.MULTILINE)
    path = root / ".env"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        parser.error(".env already exists; refusing to replace credentials or encryption keys")
    with os.fdopen(descriptor, "w") as destination:
        destination.write(content)
    (root / "secrets").mkdir(exist_ok=True, mode=0o700)
    print("Created private .env. Add provider OAuth and optional APNs settings before deployment.")


if __name__ == "__main__":
    main()
