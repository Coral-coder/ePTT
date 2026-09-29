#!/usr/bin/env python3
"""Revoke the throwaway development certificates CI runs leave behind.

Every archive on a fresh GitHub runner has Xcode create a new "Apple Development: Created via
API" certificate (the runner keeps no private key), and Apple caps how many an account may hold.
This revokes only development certificates with that name; distribution signing (cloud
managed, used for TestFlight) and developers' own Xcode certificates are left alone.

Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8). Standard library plus the openssl
command line tool. Never fails the build: problems are printed as warnings.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
DEV_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT"}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """ECDSA DER signature to JOSE r||s (32 bytes each)."""
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        length = der[i + 1]
        parts.append(der[i + 2:i + 2 + length].lstrip(b"\x00").rjust(32, b"\x00"))
        i += 2 + length
    return parts[0] + parts[1]


def token() -> str:
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
                         input=signing_input, capture_output=True, check=True).stdout
    return signing_input.decode() + "." + b64url(der_to_raw(der))


def call(method: str, url: str, jwt: str):
    request = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {jwt}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None


def main() -> int:
    try:
        jwt = token()
        listing = call("GET", f"{API}/certificates?limit=200&fields[certificates]=name,certificateType", jwt)
    except Exception as error:  # noqa: BLE001 - housekeeping must never fail the build
        print(f"::warning::Couldn't list signing certificates: {error}")
        return 0
    stale = [c for c in listing.get("data", [])
             if c["attributes"].get("certificateType") in DEV_TYPES
             and "Created via API" in (c["attributes"].get("name") or "")]
    print(f"{len(stale)} CI development certificate(s) to revoke")
    for cert in stale:
        try:
            call("DELETE", f"{API}/certificates/{cert['id']}", jwt)
            print(f"Revoked {cert['attributes'].get('name')} ({cert['id']})")
        except urllib.error.HTTPError as error:
            print(f"::warning::Couldn't revoke {cert['id']}: HTTP {error.code}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
