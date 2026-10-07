#!/usr/bin/env python3
"""Measures where the viewer's test pattern is in every frame of a simulator screen recording.

The UI test (FileBoxUITests/ViewerJumpUITests.swift) opens pictures and videos seeded by the app in
Debug builds (App/Debug/UITestSeed.swift): a thick red border, a green centre cross and white lines
on dark grey. Every one of them is shown fitted and centred, so on screen its centre is always the
screen's centre, except while a page is dragged away to close. For every frame this finds, along
three vertical columns, the outer top and bottom edge of the red border and the green horizontal
centre line, in points. Then:

* sessions: each stretch of frames in which the pattern shows is one opening of the viewer. For
  each, the largest distance of the pattern's centre (and of the green line) from the screen's
  centre while opening (its first second), while open, and while closing, and whether that is a
  jump (more than --tolerance points). The fly-off of a page swiped away is reported apart.
* steps: for each step of the test, the frames around it with the positions and their difference
  from a reference (detail for reading; the recording lags the test's clock by about a second,
  which is estimated from the sessions and taken off).

Usage:
  measure.py --frames DIR --times frame_times.txt --events events.txt --record-start start.txt \\
             [--probe viewer-probe.log] --out OUTDIR [--copy-frames]
  measure.py --from-csv measurements.csv --events ... --record-start ... --probe ... --out OUTDIR

DIR holds f_000001.png, f_000002.png, ... in order (ffmpeg -fps_mode passthrough), frame_times.txt
the presentation time of each frame (ffprobe frame=pts_time), events.txt lines of
"<unix time> <name>" from the test log, start.txt the unix time the recording started, and
viewer-probe.log the app's layout log (App/Debug/ViewerProbe.swift; gives the screen scale and the
viewer's open and close events).
"""
import argparse
import csv
import glob
import os
import re
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image

COLUMNS = (0.25, 0.5, 0.75)
CSV_KEYS = ["index", "t", "file", "h", "seen", "top_pt", "bot_pt", "centre_pt", "green_pt"]
for _c in COLUMNS:
    CSV_KEYS += [f"red_top@{_c}", f"red_top_inner@{_c}", f"red_bot@{_c}", f"red_bot_inner@{_c}", f"green@{_c}"]


def runs(mask):
    """Start and end (inclusive) of each run of True in a 1-D mask."""
    if not mask.any():
        return []
    padded = np.concatenate(([False], mask, [False]))
    diff = np.diff(padded.astype(np.int8))
    starts = np.where(diff == 1)[0]
    ends = np.where(diff == -1)[0] - 1
    return list(zip(starts.tolist(), ends.tolist()))


def column_metrics(col):
    """col: (H, 3) array. Red border's outer top and bottom, and the green line nearest the middle."""
    r = col[:, 0].astype(np.int32)
    g = col[:, 1].astype(np.int32)
    b = col[:, 2].astype(np.int32)
    red = (r > 100) & (r - g > 55) & (r - b > 55)
    green = (g > 100) & (g - r > 55) & (g - b > 55)
    out = {}
    red_runs = [run for run in runs(red) if run[1] - run[0] >= 2]
    if red_runs:
        out["red_top"] = red_runs[0][0]
        out["red_top_inner"] = red_runs[0][1]
        out["red_bot"] = red_runs[-1][1]
        out["red_bot_inner"] = red_runs[-1][0]
    green_runs = [run for run in runs(green) if 2 <= run[1] - run[0] <= 60]
    if green_runs:
        middle = len(col) / 2
        best = min(green_runs, key=lambda run: abs((run[0] + run[1]) / 2 - middle))
        out["green"] = (best[0] + best[1]) / 2
    return out


def measure_frame(path):
    image = Image.open(path).convert("RGB")
    array = np.asarray(image)
    height, width, _ = array.shape
    result = {"file": os.path.basename(path), "w": width, "h": height}
    for fraction in COLUMNS:
        x = int(round(width * fraction))
        # Three neighbouring columns, so one compression artefact never decides alone.
        strip = np.median(array[:, max(0, x - 1):x + 2, :], axis=1)
        for key, value in column_metrics(strip).items():
            result[f"{key}@{fraction}"] = value
    return result


def median(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    n = len(values)
    return values[n // 2] if n % 2 else (values[n // 2 - 1] + values[n // 2]) / 2


def summary_values(row, scale):
    """Top edge, bottom edge, centre, green line (points) from whichever columns saw them."""
    tops = [row.get(f"red_top@{c}") for c in COLUMNS]
    bots = [row.get(f"red_bot@{c}") for c in COLUMNS]
    greens = [row.get(f"green@{c}") for c in (0.25, 0.75)]
    top = median(tops)
    bot = median(bots)
    green = median(greens)
    seen = sum(t is not None for t in tops) + sum(g is not None for g in greens)
    to_pt = lambda v: None if v is None else v / scale
    # Each column's own middle: while paging, columns can see two different pictures.
    centre = median([(t + b) / 2 for t, b in zip(tops, bots) if t is not None and b is not None])
    return to_pt(top), to_pt(bot), to_pt(centre), to_pt(green), seen


def read_csv(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as handle:
        for raw in csv.DictReader(handle):
            row = {}
            for key, value in raw.items():
                if key == "file":
                    row[key] = value
                elif value in ("", None):
                    row[key] = None
                else:
                    number = float(value)
                    row[key] = int(number) if key in ("index", "seen", "h") else number
            rows.append(row)
    return rows


def load_lines(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return [line.strip() for line in handle if line.strip()]


def fmt(value, digits=2):
    return "-" if value is None else f"{value:.{digits}f}"


def probe_info(path, start):
    """Screen scale, screen height (pt) and the app's events (seconds after the recording started)."""
    scale = None
    height = None
    events = []
    if not path or not os.path.exists(path):
        return scale, height, events
    for line in load_lines(path):
        parts = line.split(" ", 3)
        if len(parts) < 4:
            continue
        if parts[2] == "start" or parts[3].startswith("screen="):
            match = re.search(r"scale=([0-9.]+)", line)
            if match:
                scale = float(match.group(1))
            match = re.search(r"screen=\(([0-9.]+), ([0-9.]+)\)", line)
            if match:
                height = max(float(match.group(1)), float(match.group(2)))
        if parts[2] == "EVENT":
            try:
                events.append((float(parts[0]) - start, parts[3]))
            except ValueError:
                pass
    return scale, height, events


def step_kind(name):
    if name.startswith("open") or "-open-" in name:
        return "open"
    if name.startswith("page"):
        return "page"
    if "chrome" in name:
        return "chrome"
    if "close-button" in name:
        return "close-button"
    if "swipe-down" in name:
        return "close-swipe"
    if "landscape-button" in name or "portrait-button" in name:
        return "rotate"
    return "other"


def find_sessions(rows, gap=4):
    """Stretches of frames in which the pattern shows (gaps of a few frames allowed)."""
    sessions = []
    for row in rows:
        if row["seen"] is None or row["seen"] < 2 or row["t"] is None:
            continue
        if sessions and row["index"] - sessions[-1][-1]["index"] <= gap:
            sessions[-1].append(row)
        else:
            sessions.append([row])
    return [s for s in sessions if len(s) >= 3]


def deviation(row, mid):
    values = [abs(row[key] - mid) for key in ("centre_pt", "green_pt") if row[key] is not None]
    return max(values) if values else None


def analyse_session(session, mid, args):
    """Splits a session into opening, open and closing, and finds the largest shift in each."""
    t0 = session[0]["t"]
    t1 = session[-1]["t"]
    devs = [deviation(row, mid) for row in session]
    # A page swiped away moves further and further from the centre until it is gone: the trailing
    # run of frames whose deviation keeps growing past the tolerance is that fly-off.
    fly_start = len(session)
    i = len(session) - 1
    while i > 0 and devs[i] is not None and devs[i] > args.tolerance:
        prev = devs[i - 1]
        if prev is None or prev > devs[i] + 0.5:
            break
        i -= 1
    if i < len(session) - 1 and devs[len(session) - 1] is not None and devs[len(session) - 1] > 20:
        fly_start = i + 1
    phases = {"opening": [], "open": [], "closing": []}
    for k, row in enumerate(session[:fly_start]):
        if row["t"] - t0 <= args.opening:
            phases["opening"].append((row, devs[k]))
        elif fly_start == len(session) and t1 - row["t"] <= args.closing:
            phases["closing"].append((row, devs[k]))
        else:
            phases["open"].append((row, devs[k]))
    result = {}
    for phase, items in phases.items():
        worst = None
        for row, dev in items:
            if dev is not None and (worst is None or dev > worst[1]):
                worst = (row, dev)
        result[phase] = (len(items), worst)
    fly = session[fly_start:] if fly_start < len(session) else []
    return result, fly


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", help="directory of f_000001.png ... frames")
    parser.add_argument("--from-csv", help="report again from an earlier measurements.csv instead of frames")
    parser.add_argument("--times")
    parser.add_argument("--events")
    parser.add_argument("--record-start")
    parser.add_argument("--probe")
    parser.add_argument("--out", required=True)
    parser.add_argument("--scale", type=float, help="screen scale (default: from the probe log, else 3)")
    parser.add_argument("--before", type=float, default=0.4, help="seconds before a step to list")
    parser.add_argument("--after", type=float, default=1.6, help="seconds after a step to list")
    parser.add_argument("--opening", type=float, default=1.0, help="seconds after the first frame counted as opening")
    parser.add_argument("--closing", type=float, default=0.5, help="seconds before the last frame counted as closing")
    parser.add_argument("--tolerance", type=float, default=1.0, help="largest shift (pt) that is not a jump")
    parser.add_argument("--copy-frames", action="store_true", help="copy each step's frames (half size JPEG)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    start = float(load_lines(args.record_start)[0]) if args.record_start else 0.0
    probe_scale, probe_height, probe_events = probe_info(args.probe, start)
    scale = args.scale or probe_scale or 3.0

    if args.from_csv:
        rows = read_csv(args.from_csv)
        args.copy_frames = False
    else:
        frames = sorted(glob.glob(os.path.join(args.frames or ".", "f_*.png")))
        if not frames:
            print("no frames", file=sys.stderr)
            return 1
        times = []
        if args.times:
            times = [float(line.split(",")[0]) for line in load_lines(args.times) if line.split(",")[0] not in ("", "N/A")]
            if len(times) != len(frames):
                print(f"warning: {len(times)} times for {len(frames)} frames", file=sys.stderr)
        with Pool(args.jobs) as pool:
            rows = pool.map(measure_frame, frames, chunksize=8)
        for index, row in enumerate(rows):
            row["index"] = index + 1
            row["t"] = times[index] if index < len(times) else None
    for row in rows:
        top, bot, centre, green, seen = summary_values(row, scale)
        row.update({"top_pt": top, "bot_pt": bot, "centre_pt": centre, "green_pt": green, "seen": seen})
    if not args.from_csv:
        with open(os.path.join(args.out, "measurements.csv"), "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=CSV_KEYS, extrasaction="ignore")
            writer.writeheader()
            for row in rows:
                writer.writerow(row)

    height_px = next((row["h"] for row in rows if row.get("h")), None)
    mid = height_px / scale / 2 if height_px else (probe_height / 2 if probe_height else None)
    report = [f"frames={len(rows)} scale={scale} screen height={fmt(None if mid is None else mid * 2)}pt "
              f"recording start={start:.3f}"]

    # Sessions: the verdicts.
    sessions = find_sessions(rows)
    opens = [(t, text) for t, text in probe_events if text.startswith("open ")]
    appeared = [t for t, text in probe_events if text == "viewer appeared"]
    lags = []
    for session in sessions:
        before = [t for t in appeared if t <= session[0]["t"]]
        if before:
            lags.append(session[0]["t"] - before[-1])
    lag = median([l for l in lags if 0 <= l < 5]) or 0.0
    verdict_lines = [
        "",
        f"SESSIONS (largest distance of the pattern's centre or green line from the screen centre {fmt(mid)}pt;",
        f"a jump is more than {args.tolerance:.2f} pt; opening = first {args.opening:.1f}s, closing = last {args.closing:.1f}s;",
        f"the recording lags the app's clock by about {lag:.2f}s)",
        "  #  file                 frames         t(s)            opening            open               closing            verdict",
    ]
    any_jump = False
    for number, session in enumerate(sessions, 1):
        t0 = session[0]["t"]
        label = "?"
        candidates = [text[5:] for t, text in opens if t + lag <= t0 + 0.2]
        if candidates:
            label = candidates[-1]
        phases, fly = analyse_session(session, mid, args)
        cells = []
        jump = False
        for phase in ("opening", "open", "closing"):
            count, worst = phases[phase]
            if not count:
                cells.append("-")
                continue
            if worst is None:
                cells.append("n/a")
                continue
            row, dev = worst
            cells.append(f"{dev:5.2f}@f{row['index']}")
            if dev > args.tolerance:
                jump = True
        verdict = "JUMP" if jump else "OK"
        if fly:
            verdict += f" (swiped away from f{fly[0]['index']})"
        any_jump = any_jump or jump
        verdict_lines.append(
            f"  {number:<2d} {label[:20]:20s} f{session[0]['index']}-f{session[-1]['index']:<6d} "
            f"{t0:7.3f}-{session[-1]['t']:7.3f}  {cells[0]:18s} {cells[1]:18s} {cells[2]:18s} {verdict}"
        )
    verdict_lines.append(f"  OVERALL: {'JUMP' if any_jump else 'no jump'}")
    report += verdict_lines

    # Steps: detail for reading.
    steps = []
    if args.events:
        events = []
        for line in load_lines(args.events):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    events.append((float(parts[0]) - start + lag, parts[1]))
                except ValueError:
                    pass
        begins = {name[:-6]: t for t, name in events if name.endswith(".begin")}
        steps = [(begins.get(name, t), t, name) for t, name in events if not name.endswith(".begin")]
    report.append("")
    report.append("STEPS (test steps moved by the lag above; positions in points from the top of the screen;")
    report.append("dC / dG = centre / green line minus the screen centre)")
    for index, (t_begin, t_end, name) in enumerate(steps):
        kind = step_kind(name)
        next_begin = steps[index + 1][0] if index + 1 < len(steps) else t_end + 10
        lo = t_begin - args.before
        hi = min(t_end + args.after + (t_end - t_begin), next_begin - 0.05)
        window = [row for row in rows if row["t"] is not None and lo <= row["t"] <= hi]
        report.append("")
        report.append(f"=== {name} [{kind}]  step {t_begin:.3f}..{t_end:.3f}s, frames {lo:.3f}..{hi:.3f}s")
        if not window:
            report.append("  no frames")
            continue
        report.append("  frame      t(s)  seen     top     bot  centre   green |     dC     dG")
        for row in window:
            dc = None if row["centre_pt"] is None or mid is None else row["centre_pt"] - mid
            dg = None if row["green_pt"] is None or mid is None else row["green_pt"] - mid
            report.append(
                "  %6d %8.3f %5d %7s %7s %7s %7s | %6s %6s" % (
                    row["index"], row["t"], row["seen"], fmt(row["top_pt"]), fmt(row["bot_pt"]),
                    fmt(row["centre_pt"]), fmt(row["green_pt"]), fmt(dc), fmt(dg),
                )
            )
        if args.copy_frames:
            folder = os.path.join(args.out, "frames", f"{index + 1:02d}_{name}")
            os.makedirs(folder, exist_ok=True)
            for row in window:
                source = os.path.join(args.frames, row["file"])
                with Image.open(source) as image:
                    small = image.convert("RGB").resize((image.width // 2, image.height // 2), Image.LANCZOS)
                    small.save(os.path.join(folder, f"{row['index']:06d}_{row['t']:.3f}.jpg"), quality=90)

    if probe_events:
        report.append("")
        report.append("APP EVENTS (probe log, seconds after the recording started, plus the lag)")
        for t, text in probe_events:
            report.append(f"  {t + lag:8.3f}  {text}")

    with open(os.path.join(args.out, "report.txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(report) + "\n")
    print("\n".join(verdict_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
