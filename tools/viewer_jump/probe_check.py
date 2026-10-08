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
    parser.add_argument("--folder-tolerance", type=float, default=0.5)
    parser.add_argument("--start", help="record_start.txt, to print times relative to the recording")
    args = parser.parse_args()
    start = float(open(args.start).read().strip()) if args.start else 0.0
    height = None
    off = []
    checked = 0
    frames = 0
    last_event = ""
    landscape = None
    turning_until = -1.0
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
        if win:
            now = float(win.group(3)) > float(win.group(4))
            if landscape is not None and now != landscape:
                # While the interface turns, UIKit animates every view's drawn bounds from the old
                # shape to the new one; only the laid-out values must be in place at once.
                turning_until = stamp + 1.0
                last_event = "turned " + ("sideways" if now else "upright")
            landscape = now
        status = re.search(r"sb=(\w+)", line)
        safe = re.search(r"pvSafe=(\{[^}]*\})", line)
        for segment in line.split(" | "):
            name = segment.split("@", 1)[0] if "@" in segment else None
            if name not in ("edgeHost", "zoom", "surface", "playerHost"):
                continue
            # Off-screen neighbours (paging) are left out by the probe; a page moving sideways is fine.
            for key in ("m", "p", "img", "imgP", "video"):
                if key in ("p", "imgP") and stamp < turning_until:
                    continue
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
    # The open and close fades: drawn opacity and scale (presentation values of the pager host) must
    # move one way only, from the frame the viewer appears (or starts closing) until it is done.
    width = None
    phases = []
    current = None
    for line in open(args.log, encoding="utf-8", errors="replace"):
        parts = line.rstrip(chr(10)).split(" ", 3)
        if len(parts) < 4:
            continue
        stamp = float(parts[0]) - start
        if parts[2] == "EVENT":
            text = parts[3]
            if text == "viewer appeared":
                current = {"kind": "open", "t": stamp, "values": []}
                phases.append(current)
            elif text == "exit fade=true":
                current = {"kind": "close", "t": stamp, "values": []}
                phases.append(current)
            elif text in ("viewer disappeared", "exit fade=false") or text.startswith("chrome") or text.startswith("selection"):
                current = None
            continue
        if current is None or "edgeHost@" not in line:
            continue
        if current["kind"] == "open" and stamp - current["t"] > 1.0:
            current = None
            continue
        win = re.search(r"win=" + RECT, line)
        if win:
            width = float(win.group(3))
        seg = line.split("edgeHost@", 1)[1]
        m = re.search(r" m=" + RECT, seg)
        p = re.search(r" p=" + RECT, seg)
        a = re.search(r" a=([0-9.]+)", seg)
        if m and p and a and width:
            current["values"].append((stamp, parts[2], float(m.group(3)) / width, float(p.group(3)) / width, float(a.group(1))))
    bad = 0
    print("")
    print("FADES (pager host as drawn: opacity a, scale s; must only grow while opening, only shrink while closing)")
    for phase in phases:
        values = phase["values"]
        sign = 1 if phase["kind"] == "open" else -1
        reversals = []
        for (t0, f0, m0, s0, a0), (t1, f1, m1, s1, a1) in zip(values, values[1:]):
            if sign * (a1 - a0) < -0.02 or sign * (s1 - s0) < -0.002:
                reversals.append(f"{f1}: a {a0:.2f}->{a1:.2f} s {s0:.4f}->{s1:.4f}")
        split = sum(1 for v in values if abs(v[2] - v[3]) > 0.0005)
        seq = " ".join(f"{v[4]:.2f}/{v[3]:.3f}" for v in values)
        verdict = "OK" if not reversals else "REVERSES: " + "; ".join(reversals)
        bad += bool(reversals)
        print(f"  {phase['kind']:5s} at {phase['t']:9.3f}s  {len(values)} frames ({split} with laid-out != drawn)  {verdict}")
        print(f"        a/s: {seq}")
    print(f"FADES OVERALL: {'all one way' if not bad else str(bad) + ' fades reverse'}")
    folder_moves = check_folder(args.log, start, args.folder_tolerance)
    off_centre = [e for e in episodes if not by_design(e)]
    print(f"OVERALL: {len(off_centre)} episodes off centre outside drags" if off_centre else "OVERALL: always centred outside drags")
    print(f"FOLDER OVERALL: {folder_moves} moves while it shows through the viewer" if folder_moves
          else "FOLDER OVERALL: never moves while it shows through the viewer")
    return 0


def folder_values(line):
    """The folder's list content origin (laid out, drawn), navigation bar top (laid out, drawn),
    the list's identity and the root controller's additional top inset, from one probe frame line."""
    values = {}
    for key in ("c0", "c0p"):
        match = re.search(r" " + key + r"=(-?[0-9.]+)", line)
        if match:
            values[key] = float(match.group(1))
    for key in ("nav", "navP"):
        match = re.search(r" " + key + "=" + RECT, line)
        if match:
            values[key] = float(match.group(2))
    match = re.search(r" list@(\w+)", line)
    if match:
        values["list"] = match.group(1)
    match = re.search(r"root safe=\{([-0-9.]+),[^}]*\} add=\{([-0-9.]+),", line)
    if match:
        values["rootTop"] = float(match.group(1))
        values["addTop"] = float(match.group(2))
    match = re.search(r"win=" + RECT, line)
    if match:
        values["landscape"] = float(match.group(3)) > float(match.group(4))
    return values


def check_folder(path, start, tolerance):
    """The folder underneath the viewer (App/Debug/ViewerProbe.swift folderState) while it can be
    seen: from the tap until the viewer has faded in, while a page is dragged, and from the start of
    a close until 1.5 s after the viewer is gone. Every probe frame's list content origin and
    navigation bar top, laid out and drawn, against their values just before (the open, the drag,
    the close). Behind the opaque viewer the folder may scroll to the page shown (so closing lands
    on it); that is listed but not counted."""
    lines = []
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split(" ", 3)
        if len(parts) < 4:
            continue
        try:
            stamp = float(parts[0]) - start
        except ValueError:
            continue
        lines.append((stamp, parts[2], parts[3], line))
    # Windows in which the folder can be seen, with their names.
    windows = []
    open_at = appeared = drag = exit_at = None
    for stamp, kind, text, _ in lines:
        if kind != "EVENT":
            continue
        if text.startswith("open "):
            open_at = stamp
            label = text[5:]
        elif text == "viewer appeared" and open_at is not None:
            appeared = stamp
            windows.append(("opening " + label, open_at, appeared + 0.8))
        elif text == "dismiss drag began":
            drag = stamp
        elif text.startswith("exit fade="):
            exit_at = stamp
            if drag is not None and stamp - drag < 5:
                windows.append(("drag " + label, drag, stamp))
            drag = None
        elif text == "viewer disappeared" and exit_at is not None:
            windows.append(("closing " + label, exit_at, stamp + 1.5))
            exit_at = None
            open_at = None
    print("")
    print(f"FOLDER UNDERNEATH (list content origin c0 / c0p and navigation bar top nav / navP, laid out / drawn, in points;")
    print(f"while it shows through the viewer; a move is more than {tolerance} pt from its value when the window began)")
    moves = 0
    frames_seen = 0
    for name, t0, t1 in windows:
        reference = None
        list_id = None
        worst = (0.0, None, None)
        extra = set()
        sideways = False
        count = 0
        for stamp, kind, text, line in lines:
            if not kind.startswith("F"):
                continue
            values = folder_values(line)
            if stamp < t0:
                if "c0" in values or "nav" in values:
                    reference = values
                continue
            if stamp > t1:
                break
            if reference is None:
                reference = values
            count += 1
            frames_seen += 1
            if values.get("landscape") != reference.get("landscape"):
                sideways = True
            if "addTop" in values:
                extra.add(values["addTop"])
            if values.get("list") != reference.get("list"):
                list_id = values.get("list")
                continue
            for key in ("c0", "c0p", "nav", "navP"):
                if key in values and key in reference:
                    d = values[key] - reference[key]
                    if abs(d) > abs(worst[0]):
                        worst = (d, key, kind)
        moved = abs(worst[0]) > tolerance and not sideways
        moves += moved
        verdict = "MOVES" if moved else "OK"
        if sideways:
            verdict += " (the phone turned: the folder turns with it)"
        if list_id:
            verdict += " (another list)"
        where = f"{worst[0]:+7.2f}pt {worst[1]} at {worst[2]}" if worst[1] else "   0.00pt"
        extra_text = "/".join(f"{v:.0f}" for v in sorted(extra)) if extra else "-"
        print(f"  {t0:9.3f}-{t1:9.3f}s  {name[:44]:44s} {count:4d} frames  max {where:28s} rootAddTop={extra_text:6s} {verdict}")
    print(f"  {len(windows)} windows, {frames_seen} probe frames")
    return moves


if __name__ == "__main__":
    sys.exit(main())
