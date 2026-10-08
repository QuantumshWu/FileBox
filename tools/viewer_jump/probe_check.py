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
    # What a page does depends on these; the others (decodes, the safe-area keeper...) say nothing
    # about it.
    major = ("open ", "viewer appeared", "viewer disappeared", "dismiss drag", "exit fade", "selection",
             "chrome visible")
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
            if parts[3].startswith(major):
                last_event = parts[3]
            continue
        if height is None or "edgeHost@" not in line:
            continue
        frames += 1
        # Turned sideways: the screen's height is the other side.
        win = re.search(r"win=" + RECT, line)
        screen_mid = float(win.group(4)) / 2 if win else height / 2
        screen_h = float(win.group(4)) if win else height
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
                # Gone below or above the screen (the viewer leaving once faded out): not seen.
                top, h = float(match.group(2)), float(match.group(4))
                if min(top + h, screen_h) - max(top, 0) < 2:
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
    off_page = check_pages(args.log, start)
    sideways = check_sideways(args.log, start, args.tolerance)
    small_pages = check_page_frames(args.log, start)
    off_centre = [e for e in episodes if not by_design(e)]
    print(f"OVERALL: {len(off_centre)} episodes off centre outside drags" if off_centre else "OVERALL: always centred outside drags")
    print(f"FOLDER OVERALL: {folder_moves} moves while it shows through the viewer" if folder_moves
          else "FOLDER OVERALL: never moves while it shows through the viewer")
    print(f"PAGES OVERALL: {off_page} rests off a page boundary" if off_page
          else "PAGES OVERALL: the pager always rests on a page boundary")
    print(f"SIDEWAYS OVERALL: {sideways} episodes off the screen's centre sideways" if sideways
          else "SIDEWAYS OVERALL: always centred sideways while opening, closing and showing or hiding the bars")
    print(f"PAGE FRAMES OVERALL: {small_pages} episodes of a page at rest not filling the screen" if small_pages
          else "PAGE FRAMES OVERALL: a page at rest always fills the screen")
    return 0


def check_page_frames(path, start, tolerance=0.5):
    """A page at rest (the viewer at full size, the pager on a page boundary, nothing dragged, not
    turning) fills the screen: its image scroll view (zoom m=), video host (playerHost m=) and video
    surface (surface m=) all have the window's frame. One laid out inside the safe area (held
    sideways, inside the screen's side insets) shows its picture smaller than it should be."""
    episodes = []
    last_event = ""
    dragging = False
    turning_until = -1.0
    settle_until = -1.0
    landscape = None
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip(chr(10)).split(" ", 3)
        if len(parts) < 4:
            continue
        try:
            stamp = float(parts[0]) - start
        except ValueError:
            continue
        if parts[2] == "EVENT":
            text = parts[3]
            if text.startswith("dismiss drag began") or text == "exit fade=false":
                dragging = True
            elif text.startswith("dismiss drag ended"):
                # Let go without closing: the page springs back first.
                dragging = False
                settle_until = stamp + 0.8
            elif text in ("viewer appeared", "viewer disappeared"):
                dragging = False
            last_event = text
            continue
        if not parts[2].startswith("F"):
            continue
        win = re.search(r"win=" + RECT, line)
        edge = re.search(r"edgeHost@\S+ m=" + RECT, line)
        pager = re.search(r" pager=" + RECT + r" pagerOff=\((-?[0-9.]+),", line)
        if not win or not edge or not pager:
            continue
        W, H = float(win.group(3)), float(win.group(4))
        now = W > H
        if landscape is not None and now != landscape:
            turning_until = stamp + 1.0
        landscape = now
        ex, ey, ew, eh = (float(edge.group(k)) for k in range(1, 5))
        width, offset = float(pager.group(3)), float(pager.group(5))
        at_rest = (abs(ex) <= tolerance and abs(ey) <= tolerance and abs(ew - W) <= tolerance and abs(eh - H) <= tolerance
                   and width > 0 and abs(offset - round(offset / width) * width) <= tolerance
                   and not dragging and stamp >= turning_until and stamp >= settle_until)
        if not at_rest:
            continue
        bad = []
        for segment in line.split(" | "):
            name = segment.split("@", 1)[0] if "@" in segment else None
            if name not in ("zoom", "playerHost", "surface"):
                continue
            m = re.search(r" m=" + RECT, segment)
            if not m:
                continue
            x, y, w, h = (float(m.group(k)) for k in range(1, 5))
            if min(x + w, W) - max(x, 0) < 2:
                continue
            if abs(x) > tolerance or abs(y) > tolerance or abs(w - W) > tolerance or abs(h - H) > tolerance:
                bad.append(f"{name}=[{x:.1f},{y:.1f},{w:.1f},{h:.1f}]")
        if not bad:
            continue
        frame = int(parts[2][1:])
        if episodes and frame - episodes[-1]["last"] <= 3:
            episodes[-1]["last"] = frame
            episodes[-1]["t1"] = stamp
            continue
        episodes.append({"first": frame, "last": frame, "t0": stamp, "t1": stamp, "what": bad[0],
                         "win": f"{W:.0f}x{H:.0f}", "event": last_event})
    print("")
    print("PAGE FRAMES (a page at rest whose image scroll view, video host or surface is not the window's frame)")
    for e in episodes:
        print(f"  {e['t0']:9.3f}-{e['t1']:9.3f}s F{e['first']}-F{e['last']} win {e['win']} {e['what']}  NOT FULL SCREEN"
              f"  after: {e['event']}")
    return len(episodes)


def check_sideways(path, start, tolerance):
    """While the viewer opens (its first 1.2 s), closes with the button (until it is gone) and for a
    second after the bars show or hide, nothing pages: the pager host, the picture (zoom ... img=,
    imgP=) and the video (surface ... video=) must be centred across the screen too. Lists every
    episode of frames off that centre by more than `tolerance` points, laid out or drawn."""
    episodes = []
    until = -1.0
    reason = ""
    turning_until = -1.0
    landscape = None
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip(chr(10)).split(" ", 3)
        if len(parts) < 4:
            continue
        try:
            stamp = float(parts[0]) - start
        except ValueError:
            continue
        if parts[2] == "EVENT":
            text = parts[3]
            if text == "viewer appeared":
                until, reason = stamp + 1.2, "opening"
            elif text == "exit fade=true":
                until, reason = float("inf"), "closing"
            elif text.startswith("chrome visible"):
                until, reason = stamp + 1.0, text
            elif text.startswith(("selection", "dismiss drag", "exit fade=false", "viewer disappeared")):
                until = -1.0
            continue
        if not parts[2].startswith("F"):
            continue
        win = re.search(r"win=" + RECT, line)
        if not win:
            continue
        width = float(win.group(3))
        now = width > float(win.group(4))
        if landscape is not None and now != landscape:
            turning_until = stamp + 1.0
        landscape = now
        if stamp > until:
            continue
        worst = None
        for segment in line.split(" | "):
            name = segment.split("@", 1)[0] if "@" in segment else None
            keys = {"edgeHost": ("m", "p"), "zoom": ("img", "imgP"), "surface": ("video",)}.get(name)
            if not keys:
                continue
            for key in keys:
                if key in ("p", "imgP") and stamp < turning_until:
                    continue
                match = re.search(r"(?:^| )" + key + "=" + RECT, segment)
                if not match:
                    continue
                x, w = float(match.group(1)), float(match.group(3))
                # A neighbouring page beside the screen.
                if min(x + w, width) - max(x, 0) < 2:
                    continue
                dx = x + w / 2 - width / 2
                if abs(dx) > tolerance and (worst is None or abs(dx) > abs(worst[1])):
                    worst = (f"{name}.{key}", dx)
        if worst is None:
            continue
        frame = int(parts[2][1:])
        if episodes and frame - episodes[-1]["last"] <= 3 and episodes[-1]["reason"] == reason:
            episode = episodes[-1]
        else:
            episode = {"first": frame, "last": frame, "t0": stamp, "max": 0.0, "what": set(), "reason": reason}
            episodes.append(episode)
        episode["last"] = frame
        episode["t1"] = stamp
        episode["what"].add(worst[0])
        if abs(worst[1]) > abs(episode["max"]):
            episode["max"] = worst[1]
    print("")
    print(f"SIDEWAYS (off the screen's centre across it by more than {tolerance} pt while opening, closing with the button,"
          " or showing / hiding the bars)")
    for e in episodes:
        print(f"  {e['t0']:9.3f}-{e['t1']:9.3f}s F{e['first']}-F{e['last']} max {e['max']:+7.2f}pt "
              f"{','.join(sorted(e['what']))}  OFF CENTRE SIDEWAYS  while: {e['reason']}")
    return len(episodes)


def check_pages(path, start, tolerance=0.5, rest=0.3, frames=3):
    """The pager's horizontal offset (edgeHost ... pagerOff=) must come to rest on a page boundary
    (a multiple of the pager's unscaled width): one at rest anywhere else shows the page that far
    off the screen's centre, sideways. Paging moves it on every frame, so only an offset that stays
    put for `rest` seconds over `frames` probe frames counts (a main-thread stall in the middle of a
    swipe logs one frame and then nothing)."""
    episodes = []
    current = None
    last_event = ""
    major = ("open ", "viewer appeared", "viewer disappeared", "dismiss drag", "exit fade", "selection",
             "chrome visible")

    def close(stamp):
        if current is None:
            return
        miss = current["offset"] - round(current["offset"] / current["width"]) * current["width"]
        if abs(miss) > tolerance and stamp - current["t0"] >= rest and current["count"] >= frames:
            episodes.append((current["t0"], stamp, current["frame"], current["offset"], current["width"], miss,
                             current["event"], current["count"]))

    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split(" ", 3)
        if len(parts) < 4:
            continue
        try:
            stamp = float(parts[0]) - start
        except ValueError:
            continue
        if parts[2] == "EVENT":
            if parts[3].startswith(major):
                last_event = parts[3]
            continue
        if not parts[2].startswith("F"):
            continue
        match = re.search(r" pager=" + RECT + r" pagerOff=\((-?[0-9.]+),", line)
        win = re.search(r"win=" + RECT, line)
        edge = re.search(r"edgeHost@\S+ m=" + RECT, line)
        if not match or not win or not edge or float(edge.group(3)) <= 0:
            close(stamp)
            current = None
            continue
        # The pager's own width: its width on screen without the open / close scale.
        scale = float(edge.group(3)) / float(win.group(3))
        width, offset = float(match.group(3)) / scale, float(match.group(5))
        if width <= 0:
            continue
        if current is None or abs(current["offset"] - offset) > 0.01 or abs(current["width"] - width) > 0.5:
            close(stamp)
            current = {"offset": offset, "width": width, "t0": stamp, "last": stamp, "frame": parts[2],
                       "event": last_event, "count": 1}
        else:
            current["last"] = stamp
            current["count"] += 1
    print("")
    print(f"PAGES (the pager resting off a page boundary for {rest}s or more, by more than {tolerance} pt)")
    for t0, t1, frame, offset, width, miss, event, count in episodes:
        print(f"  {t0:9.3f}-{t1:9.3f}s {frame} offset {offset:.2f} (page width {width:.2f}, {count} frames): "
              f"{miss:+.2f}pt OFF PAGE  after: {event}")
    return len(episodes)


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
