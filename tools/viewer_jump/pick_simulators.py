#!/usr/bin/env python3
"""Picks the simulators for the viewer repro on the newest iOS 26 runtime, creating them if needed.

Prints one line per device: "<udid>\t<name>\t<label>". Labels: island (Dynamic Island), notch, and
homebutton (status bar without a sensor housing) when the runtime still has such a phone.
"""
import json
import subprocess
import sys

WANTED = [
    ("island", ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 15 Pro", "iPhone Air"]),
    ("notch", ["iPhone 16e", "iPhone 14", "iPhone 13 mini", "iPhone 13"]),
    ("homebutton", ["iPhone SE (3rd generation)", "iPhone SE (2nd generation)"]),
]


def version_key(runtime):
    return tuple(int(part) for part in runtime.get("version", "0").split(".") if part.isdigit())


def main():
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j"]))
    runtimes = [
        r for r in data["runtimes"]
        if r.get("isAvailable") and r.get("platform", "iOS") == "iOS" and r.get("version", "").startswith("26")
    ]
    if not runtimes:
        runtimes = [r for r in data["runtimes"] if r.get("isAvailable") and "iOS" in r.get("name", "")]
    runtime = max(runtimes, key=version_key)
    print(f"runtime {runtime['identifier']} {runtime.get('version')}", file=sys.stderr)
    supported = {t["name"]: t["identifier"] for t in runtime.get("supportedDeviceTypes", [])}
    if not supported:
        supported = {t["name"]: t["identifier"] for t in data["devicetypes"]}
    devices = [d for d in data["devices"].get(runtime["identifier"], []) if d.get("isAvailable", True)]
    for label, names in WANTED:
        for name in names:
            existing = [d for d in devices if d["name"] == name]
            if existing:
                print(f"{existing[0]['udid']}\t{name}\t{label}")
                break
            if name in supported:
                udid = subprocess.check_output(
                    ["xcrun", "simctl", "create", name, supported[name], runtime["identifier"]]
                ).decode().strip()
                print(f"{udid}\t{name}\t{label}")
                break
        else:
            print(f"no simulator for {label}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
