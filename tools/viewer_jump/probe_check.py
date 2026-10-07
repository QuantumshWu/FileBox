#!/usr/bin/env python3
"""Checks the app's layout probe log (App/Debug/ViewerProbe.swift) for pages that are not centred.

Every display frame in which something changed, the probe writes the window frames of the viewer's
pager host (edgeHost), its image views (zoom ... img=) and the video picture (surface ... video=),
as laid out (m=) and as drawn (p=, presentation values, which include the open / close scale).
All of them are centred on the screen when the pager has the whole screen, whatever the scale, so
this lists every frame whose centre is off the screen's centre by more than --tolerance points, with
the status bar state and the safe area at that moment.

Usage: probe_check.py viewer-probe.log [--tolerance 0.5] [--start record_start.txt]
"""
import argparse
import re
import sys

RECT = r"\[(-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+)\]"


def centre_y(match):
    y, h = float(match.group(2)), float(match.group(4))
    return y + h / 2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--tolerance", type=float, default=0.5)
    parser.add_argument("--start", help="record_start.txt, to print times relative to the recording")
    args = parser.parse_args()
    start = float(open(args.start).read().strip()) if args.start else 0.0
    height = None
    off = []
    checked = 0
    frames = 0
    last_event = ""
    for line in open(args.log, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        parts = line.split(" ", 3)
        if len(parts) < 4:
            continue
        stamp = float(parts[0]) - start
        if parts[2] == "start" or parts[3].startswith("screen="):
            match = re.search(r"screen=\(([0-9.]+), ([0-9.]+)\)", line)
            if match:
                height = float(match.group(2))
            continue
        if parts[2] == "EVENT":
            last_event = parts[3]
            continue
        if height is None or "edgeHost@" not in line:
            continue
        frames += 1
        # Turned sideways: the screen's height is the other side.
        win = re.search(r"win=" + RECT, line)
        screen_mid = float(win.group(4)) / 2 if win else height / 2
        status = re.search(r"sb=(\w+)", line)
        safe = re.search(r"pvSafe=(\{[^}]*\})", line)
        for segment in line.split(" | "):
            name = segment.split("@", 1)[0] if "@" in segment else None
            if name not in ("edgeHost", "zoom", "surface", "playerHost"):
                continue
            # Off-screen neighbours (paging) are left out by the probe; a page moving sideways is fine.
            for key in ("m", "p", "img", "imgP", "video"):
                match = re.search(r"(?:^| )" + key + "=" + RECT, segment)
                if not match:
                    continue
                checked += 1
                cy = centre_y(match)
                if abs(cy - screen_mid) > args.tolerance:
                    off.append((stamp, parts[2], name, key, cy - screen_mid, status.group(1) if status else "?",
                                safe.group(1) if safe else "?", last_event))
    # One line per episode: consecutive probe frames with something off centre.
    episodes = []
    for item in off:
        frame = int(item[1][1:]) if item[1].startswith("F") else 0
        if episodes and frame - episodes[-1]["last"] <= 3 and item[7] == episodes[-1]["event"]:
            episode = episodes[-1]
        else:
            episode = {"first": frame, "last": frame, "t0": item[0], "t1": item[0], "max": 0.0, "event": item[7],
                       "what": set(), "sb": set(), "safe": item[6]}
            episodes.append(episode)
        episode["last"] = frame
        episode["t1"] = item[0]
        episode["what"].add(item[2])
        episode["sb"].add(item[5])
        if abs(item[4]) > abs(episode["max"]):
            episode["max"] = item[4]
    by_design = lambda e: e["event"].startswith("dismiss drag") or e["event"] == "exit fade=false"
    dragging = sum(1 for e in episodes if by_design(e))
    print(f"checked {checked} rects in {frames} probe frames; {len(off)} off the screen centre by more than "
          f"{args.tolerance} pt, in {len(episodes)} episodes ({dragging} while a page was dragged to close)")
    for e in episodes:
        kind = "dragged / swiped away (by design)" if by_design(e) else "OFF CENTRE"
        print(f"  {e['t0']:9.3f}-{e['t1']:9.3f}s F{e['first']}-F{e['last']} max {e['max']:+7.2f}pt "
              f"{','.join(sorted(e['what']))} sb={'/'.join(sorted(e['sb']))} safe={e['safe']}  {kind}  after: {e['event']}")
    off_centre = [e for e in episodes if not by_design(e)]
    print(f"OVERALL: {len(off_centre)} episodes off centre outside drags" if off_centre else "OVERALL: always centred outside drags")
    return 0


if __name__ == "__main__":
    sys.exit(main())
