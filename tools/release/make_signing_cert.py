#!/usr/bin/env python3
"""One-time: make an Apple Development certificate for CI and store it as GitHub secrets.

Run by .github/workflows/make-signing-cert.yml. It:
1. makes a new private key on the runner and asks App Store Connect for an Apple Development
   certificate for it;
2. bundles key and certificate into a .p12 with a random password;
3. writes DEV_CERT_P12 (base64 .p12) and DEV_CERT_PASSWORD straight into the Coral
   environment's secrets through the GitHub API, sealed to that environment's public key.

Nothing is printed, saved as an artifact or committed. The TestFlight workflow then loads that
one certificate on every run, so Xcode stops making new ones.

Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, SECRETS_TOKEN (a fine-grained token that can
write this repository's environment secrets), GITHUB_REPOSITORY, and the packages
`cryptography` and `pynacl`.
"""
import base64
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID
from nacl import encoding, public

ASC = "https://api.appstoreconnect.apple.com/v1"
GH = "https://api.github.com"
ENVIRONMENT = "Coral"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def asc_token() -> str:
    with open(os.environ["ASC_KEY_PATH"], "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    r, s = decode_dss_signature(key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256())))
    return signing_input + "." + b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def request(method: str, url: str, headers: dict, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={**headers, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:400]
        sys.exit(f"::error::{method} {url.split('?')[0]} failed: HTTP {error.code} {detail}")


def github_headers() -> dict:
    return {"Authorization": f"Bearer {os.environ['SECRETS_TOKEN']}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"}


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    env_url = f"{GH}/repos/{repo}/environments/{ENVIRONMENT}/secrets"
    # Check the GitHub token first, so a bad token doesn't leave an unused certificate behind.
    sealing = request("GET", f"{env_url}/public-key", github_headers())

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "NXTPTT CI")]))
           .sign(key, hashes.SHA256()))
    response = request("POST", f"{ASC}/certificates", {"Authorization": f"Bearer {asc_token()}"}, {
        "data": {"type": "certificates", "attributes": {
            "certificateType": "DEVELOPMENT",
            "csrContent": csr.public_bytes(serialization.Encoding.PEM).decode()}}})
    cert = x509.load_der_x509_certificate(base64.b64decode(response["data"]["attributes"]["certificateContent"]))

    password = secrets.token_hex(16)
    print(f"::add-mask::{password}")
    # SHA-1 / 3DES: the format macOS `security import` reads reliably.
    encryption = (serialization.PrivateFormat.PKCS12.encryption_builder()
                  .kdf_rounds(50000)
                  .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
                  .hmac_hash(hashes.SHA1())
                  .build(password.encode()))
    p12 = pkcs12.serialize_key_and_certificates(b"NXTPTT CI", key, cert, None, encryption)

    box = public.SealedBox(public.PublicKey(sealing["key"].encode(), encoding.Base64Encoder()))
    for name, value in [("DEV_CERT_P12", base64.b64encode(p12).decode()), ("DEV_CERT_PASSWORD", password)]:
        sealed = base64.b64encode(box.encrypt(value.encode())).decode()
        request("PUT", f"{env_url}/{name}", github_headers(), {"encrypted_value": sealed, "key_id": sealing["key_id"]})
        print(f"Stored {name} in the {ENVIRONMENT} environment")
    print(f"Certificate {response['data']['id']} ({cert.subject.rfc4514_string()}), "
          f"valid until {cert.not_valid_after_utc:%Y-%m-%d}. You can delete SECRETS_TOKEN now.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
