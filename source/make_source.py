#!/usr/bin/env python3
"""Write the SideStore/AltStore source for Photoshopper3000.

SideStore needs a top-level `downloadURL` (and version/size) on the app even when
`versions[]` is present; AltStore uses `versions[]`. Both are filled, and older
versions are kept by reading the currently published source.
"""
import argparse, datetime, json, urllib.request

REPO = "MCDuckler/photoshopper-ios"
PAGES = "https://mcduckler.github.io/photoshopper-ios"

ap = argparse.ArgumentParser()
ap.add_argument("--version", required=True)
ap.add_argument("--build", required=True)
ap.add_argument("--url", required=True)
ap.add_argument("--size", type=int, required=True)
ap.add_argument("--sha256", required=True)
ap.add_argument("--out", required=True)
a = ap.parse_args()

old_versions = []
try:
    with urllib.request.urlopen(f"{PAGES}/apps.json", timeout=15) as r:
        old = json.load(r)
    old_versions = old["apps"][0].get("versions", [])
except Exception:
    pass

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
desc = ("Carries the photos you select in Photoshopper3000 into a Photos album, "
        "so iCloud Photos has them everywhere. Re-edits replace the old version.")
entry = {
    "version": a.version,
    "buildVersion": a.build,
    "date": now,
    "localizedDescription": f"Build {a.build}",
    "downloadURL": a.url,
    "size": a.size,
    "sha256": a.sha256,
    "minOSVersion": "17.0",
}
versions = [entry] + [v for v in old_versions if v.get("buildVersion") != a.build][:9]

source = {
    "name": "Photoshopper3000",
    "identifier": "dance.duckduck.p3k.source",
    "subtitle": "Rendered photos into your Photos library",
    "website": f"https://github.com/{REPO}",
    "iconURL": f"{PAGES}/icon.png",
    "tintColor": "#E4002B",
    "apps": [{
        "name": "Photoshopper3000",
        "bundleIdentifier": "dance.duckduck.p3k",
        "developerName": "MCDuckler",
        "subtitle": "Sync edits to iCloud Photos",
        "localizedDescription": desc,
        "iconURL": f"{PAGES}/icon.png",
        "tintColor": "#E4002B",
        "category": "photo-video",
        # SideStore reads these top-level fields; AltStore reads versions[].
        "version": a.version,
        "versionDate": now,
        "downloadURL": a.url,
        "size": a.size,
        "versions": versions,
        "appPermissions": {
            "entitlements": [],
            "privacy": {
                "NSPhotoLibraryUsageDescription": "Puts your rendered photos into a Photos album and replaces them when you re-edit.",
                "NSLocalNetworkUsageDescription": "Finds your Photoshopper server on the local network.",
                "NSCameraUsageDescription": "Scans the server's pairing QR code.",
            },
        },
        "screenshots": [],
    }],
    "news": [],
}
with open(a.out, "w") as f:
    json.dump(source, f, indent=2)
print(f"wrote {a.out}: {a.version} ({a.build}), {len(versions)} versions")
