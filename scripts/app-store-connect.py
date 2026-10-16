#!/usr/bin/env python3
"""Inspect AppleTree's release state using Apple's public API.

Credentials stay in the runner environment and a private temporary key file.
No submission endpoint is implemented. Only curated, non-secret metadata is
written to the snapshot artifact.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
APP_ID = "6796500800"


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def create_token(key_id, issuer_id, key):
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 600,
                             "aud": "appstoreconnect-v1"}).encode())
    message = header + b"." + payload
    with tempfile.NamedTemporaryFile() as key_file:
        os.chmod(key_file.name, 0o600)
        key_file.write(key.encode())
        key_file.flush()
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_file.name],
                             input=message, capture_output=True, check=True).stdout
    # OpenSSL returns ASN.1 DER; JWT ES256 requires fixed-width R || S.
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2 or der[2] != 0x02:
        raise ValueError("Unexpected ES256 signature encoding")
    r_size = der[3]
    offset = 4 + r_size
    if der[offset] != 0x02 or offset + 2 + der[offset + 1] != len(der):
        raise ValueError("Unexpected ES256 signature integers")
    r = int.from_bytes(der[4:offset], "big").to_bytes(32, "big")
    s = int.from_bytes(der[offset + 2:], "big").to_bytes(32, "big")
    return (message + b"." + b64(r + s)).decode()


class Client:
    def __init__(self):
        self.token = create_token(os.environ["APP_STORE_CONNECT_KEY_ID"],
                                  os.environ["APP_STORE_CONNECT_ISSUER_ID"],
                                  os.environ["APP_STORE_CONNECT_API_KEY"])

    def request(self, path):
        url = path if path.startswith("https:") else API + path
        if urllib.parse.urlsplit(url).netloc != "api.appstoreconnect.apple.com":
            raise ValueError("Refusing to send Apple credentials to another host")
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + self.token,
                                                       "Accept": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"Apple API {error.code}: {error.read().decode()[:4000]}") from None

    def all(self, path):
        result = []
        while path:
            response = self.request(path)
            result.extend(response["data"])
            path = response.get("links", {}).get("next")
        return result


def snapshot(client):
    app = client.request(f"/v1/apps/{APP_ID}")["data"]
    versions = client.all(f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=MAC_OS&limit=50")
    infos = client.all(f"/v1/apps/{APP_ID}/appInfos?limit=50")
    builds = client.all(f"/v1/builds?filter[app]={APP_ID}&limit=50&include=preReleaseVersion")
    for version in versions:
        version["localizations"] = client.all(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")
        version["build"] = client.request(f"/v1/appStoreVersions/{version['id']}/build").get("data")
        for locale in version["localizations"]:
            locale["screenshotSets"] = client.all(f"/v1/appStoreVersionLocalizations/{locale['id']}/appScreenshotSets")
            for screenshots in locale["screenshotSets"]:
                screenshots["screenshots"] = client.all(f"/v1/appScreenshotSets/{screenshots['id']}/appScreenshots")
    for info in infos:
        info["localizations"] = client.all(f"/v1/appInfos/{info['id']}/appInfoLocalizations")
    result = {"app": app, "versions": versions, "appInfos": infos, "builds": builds}
    try:
        result["certificates"] = [{"id": item["id"], "attributes": {
            key: item["attributes"].get(key) for key in
            ["name", "certificateType", "expirationDate", "serialNumber"]}}
            for item in client.all("/v1/certificates?limit=50")]
    except RuntimeError as error:
        result["certificateAccess"] = str(error)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["snapshot"])
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = snapshot(Client())
    Path(args.output).write_text(json.dumps(result, indent=2))
    print(json.dumps({"app": result["app"]["attributes"]["name"],
                      "versions": [{"id": item["id"], "version": item["attributes"]["versionString"],
                                    "state": item["attributes"].get("appStoreState")}
                                   for item in result["versions"]],
                      "buildCount": len(result["builds"])}))


if __name__ == "__main__":
    main()
