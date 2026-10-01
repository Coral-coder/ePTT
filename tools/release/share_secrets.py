#!/usr/bin/env python3
"""Copy this repository's App Store Connect and signing secrets into other repositories.

Run by .github/workflows/share-secrets.yml. GitHub never lets anyone read a secret back, so the
only way to copy one is from inside a workflow that already has it: each value arrives here as
an environment variable, is sealed to the target repository's public key and written as a
repository secret there through the GitHub API. Nothing is printed, saved or committed.

Needs SECRETS_TOKEN (a fine-grained token with Secrets read/write on every target repository),
TARGET_REPOS (space or comma separated repository names, same owner as this one),
GITHUB_REPOSITORY_OWNER, SHARED_SECRETS (the names to copy) and the package `pynacl`.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

from nacl import encoding, public

GH = "https://api.github.com"


def request(method: str, url: str, body=None):
    headers = {"Authorization": f"Bearer {os.environ['SECRETS_TOKEN']}", "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=headers),
                                    timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:400]
        sys.exit(f"::error::{method} {url} failed: HTTP {error.code} {detail}\n"
                 "Check that SECRETS_TOKEN covers that repository with Secrets read/write.")


def main() -> int:
    owner = os.environ["GITHUB_REPOSITORY_OWNER"]
    targets = os.environ["TARGET_REPOS"].replace(",", " ").split()
    names = os.environ["SHARED_SECRETS"].split()
    present = {name: os.environ[name] for name in names if os.environ.get(name)}
    missing = [name for name in names if name not in present]
    if missing:
        print(f"Not set here, so not copied: {' '.join(missing)}")
    if not targets or not present:
        sys.exit("::error::Nothing to do: no target repositories or no secrets set")

    for repo in targets:
        url = f"{GH}/repos/{owner}/{repo}/actions/secrets"
        sealing = request("GET", f"{url}/public-key")
        box = public.SealedBox(public.PublicKey(sealing["key"].encode(), encoding.Base64Encoder()))
        for name, value in present.items():
            sealed = base64.b64encode(box.encrypt(value.encode())).decode()
            request("PUT", f"{url}/{name}", {"encrypted_value": sealed, "key_id": sealing["key_id"]})
        print(f"{owner}/{repo}: stored {' '.join(present)}")
    print("Done. You can delete SECRETS_TOKEN (or remove those repositories from it) now.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
