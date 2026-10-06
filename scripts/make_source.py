"""Writes source.json, the SideStore/AltStore "source" that lets the phone install and update FileBox.

Usage (in CI): python3 scripts/make_source.py <path to FileBox.app> <path to FileBox.ipa>

SideStore refuses to install unless the source matches the IPA exactly: bundle ID, version,
build, size, and every entitlement and privacy usage key, so all of these are read from the build.
"""
import datetime
import hashlib
import json
import os
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
ipa = Path(sys.argv[2])
repo = os.environ["GITHUB_REPOSITORY"]
tag = f"build-{os.environ['GITHUB_RUN_NUMBER']}"

info = plistlib.loads((app / "Info.plist").read_bytes())
bundles = [app, *sorted((app / "PlugIns").glob("*.appex"))]

privacy = {}
for bundle in bundles:
    for key, value in plistlib.loads((bundle / "Info.plist").read_bytes()).items():
        if key.startswith("NS") and key.endswith("UsageDescription"):
            privacy[key] = value

entitlements = set()
for path in Path("Support").glob("*.entitlements"):
    entitlements.update(plistlib.loads(path.read_bytes()).keys())

version = info["CFBundleShortVersionString"]
build = info["CFBundleVersion"]
date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
download_url = f"https://github.com/{repo}/releases/download/{tag}/{ipa.name}"
size = ipa.stat().st_size
sha256 = hashlib.sha256(ipa.read_bytes()).hexdigest()

source = {
    "name": "FileBox",
    "identifier": "io.github.quantumshwu.filebox.source",  # never change
    "sourceURL": f"https://github.com/{repo}/releases/latest/download/source.json",
    "apps": [
        {
            "name": "FileBox",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "QuantumshWu",
            "localizedDescription": "自用文件管理器：接收其他 App 分享的图片、视频和文件。",
            "iconURL": f"https://raw.githubusercontent.com/{repo}/main/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": date,
                    "localizedDescription": f"自动构建 {tag}",
                    "downloadURL": download_url,
                    "size": size,
                    "sha256": sha256,
                    "minOSVersion": info.get("MinimumOSVersion", "17.0"),
                }
            ],
            "appPermissions": {
                "entitlements": sorted(entitlements),
                "privacy": privacy,
            },
            # Legacy fields some SideStore builds still read.
            "version": version,
            "versionDate": date,
            "downloadURL": download_url,
            "size": size,
        }
    ],
    "news": [],
}

Path("source.json").write_text(json.dumps(source, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(source, ensure_ascii=False, indent=2))
