#!/usr/bin/env python3
"""Measures where the viewer's test pattern is in every frame of a simulator screen recording.

The UI test (FileBoxUITests/ViewerJumpUITests.swift) opens pictures and videos seeded by the app in
Debug builds (App/Debug/UITestSeed.swift): a thick red border, a green centre cross and white lines
on dark grey. For every frame this finds, along a few vertical columns, the outer top and bottom
edge of the red border and the green horizontal centre line, in points. Then, for each step of the
test, it lists the frames after the step and how far the pattern is from where it finally settles,
so a jump (the pattern moving after it first shows) can be read off directly.

Usage:
  measure.py --frames DIR --times frame_times.txt --events events.txt --record-start start.txt \
             --out OUTDIR [--scale 3] [--copy-frames]
  measure.py --frames DIR --csv-only --out OUTDIR      (just the per-frame CSV)

DIR holds f_000001.png, f_000002.png, ... in order (ffmpeg -fps_mode passthrough), frame_times.txt
the presentation time of each frame (ffprobe frame=pts_time), events.txt lines of
"<unix time> <name>" from the test log, and start.txt the unix time the recording started.
"""
import argparse
import csv
import glob
import os
import shutil
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image

COLUMNS = (0.25, 0.5, 0.75)


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
    """col: (H, 3) int array. Returns red top/bottom and the green line closest to the middle."""
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
        metrics = column_metrics(strip)
        for key, value in metrics.items():
            result[f"{key}@{fraction}"] = value
    return result


def load_lines(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return [line.strip() for line in handle if line.strip()]


def median(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    n = len(values)
    return values[n // 2] if n % 2 else (values[n // 2 - 1] + values[n // 2]) / 2


def summary_values(row, scale):
    """Top edge, bottom edge, centre (points), from whichever columns saw them."""
    tops = [row.get(f"red_top@{c}") for c in COLUMNS]
    bots = [row.get(f"red_bot@{c}") for c in COLUMNS]
    greens = [row.get(f"green@{c}") for c in (0.25, 0.75)]
    top = median([t for t in tops if t is not None])
    bot = median([b for b in bots if b is not None])
    green = median([g for g in greens if g is not None])
    seen = sum(t is not None for t in tops) + sum(g is not None for g in greens)
    to_pt = lambda v: None if v is None else v / scale
    centre = None
    if top is not None and bot is not None:
        centre = (top + bot) / 2
    return to_pt(top), to_pt(bot), to_pt(centre), to_pt(green), seen


def fmt(value, digits=2):
    return "-" if value is None else f"{value:.{digits}f}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", required=True)
    parser.add_argument("--times")
    parser.add_argument("--events")
    parser.add_argument("--record-start")
    parser.add_argument("--out", required=True)
    parser.add_argument("--scale", type=float, default=3.0)
    parser.add_argument("--before", type=float, default=0.4, help="seconds before a step to report")
    parser.add_argument("--after", type=float, default=1.6, help="seconds after a step to report")
    parser.add_argument("--copy-frames", action="store_true", help="copy each step's frames (half size JPEG)")
    parser.add_argument("--csv-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    frames = sorted(glob.glob(os.path.join(args.frames, "f_*.png")))
    if not frames:
        print("no frames", file=sys.stderr)
        return 1
    times = None
    if args.times:
        times = [float(line.split(",")[0]) for line in load_lines(args.times) if line.split(",")[0] not in ("", "N/A")]
        if len(times) != len(frames):
            print(f"warning: {len(times)} times for {len(frames)} frames", file=sys.stderr)
    with Pool(args.jobs) as pool:
        rows = pool.map(measure_frame, frames, chunksize=8)
    for index, row in enumerate(rows):
        row["index"] = index + 1
        row["t"] = times[index] if times and index < len(times) else None
        top, bot, centre, green, seen = summary_values(row, args.scale)
        row.update({"top_pt": top, "bot_pt": bot, "centre_pt": centre, "green_pt": green, "seen": seen})

    keys = ["index", "t", "file", "seen", "top_pt", "bot_pt", "centre_pt", "green_pt"]
    for c in COLUMNS:
        keys += [f"red_top@{c}", f"red_top_inner@{c}", f"red_bot@{c}", f"red_bot_inner@{c}", f"green@{c}"]
    with open(os.path.join(args.out, "measurements.csv"), "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    if args.csv_only or not (args.events and args.record_start and times):
        return 0

    start = float(load_lines(args.record_start)[0])
    events = []
    for line in load_lines(args.events):
        parts = line.split()
        if len(parts) >= 2:
            try:
                events.append((float(parts[0]) - start, parts[1]))
            except ValueError:
                pass
    # Only the step itself ("<name>" printed after the action returned), not ".begin".
    begins = {name[:-6]: t for t, name in events if name.endswith(".begin")}
    steps = [(begins.get(name, t), t, name) for t, name in events if not name.endswith(".begin")]

    report = []
    report.append(f"frames={len(rows)} scale={args.scale} recording start={start:.3f}")
    report.append("Positions in points from the top of the screen; d* = difference from the settled value")
    report.append("(median of the last 5 frames of the window). centre = middle of the red border's top")
    report.append("and bottom edges, green = the green centre line.")
    for index, (t_begin, t_end, name) in enumerate(steps):
        next_begin = steps[index + 1][0] if index + 1 < len(steps) else t_end + 10
        lo = t_begin - args.before
        hi = min(t_end + args.after + (t_end - t_begin), next_begin - 0.05)
        window = [row for row in rows if row["t"] is not None and lo <= row["t"] <= hi]
        report.append("")
        report.append(f"=== {name}  (step {t_begin:.3f}s .. {t_end:.3f}s in the recording; frames {lo:.3f}..{hi:.3f}s)")
        if not window:
            report.append("  no frames")
            continue
        tail = [row for row in window if row["seen"] >= 2][-5:]
        settled = {
            key: median([row[key] for row in tail]) for key in ("top_pt", "bot_pt", "centre_pt", "green_pt")
        }
        report.append(
            "  settled: top=%s bot=%s centre=%s green=%s height=%s" % (
                fmt(settled["top_pt"]), fmt(settled["bot_pt"]), fmt(settled["centre_pt"]), fmt(settled["green_pt"]),
                fmt(None if settled["top_pt"] is None or settled["bot_pt"] is None else settled["bot_pt"] - settled["top_pt"]),
            )
        )
        report.append("  frame      t(s)   seen    top     bot  centre   green |   dTop   dBot dCentre dGreen")
        max_centre = 0.0
        max_green = 0.0
        first_visible = None
        for row in window:
            d = {}
            for key in ("top_pt", "bot_pt", "centre_pt", "green_pt"):
                d[key] = None if row[key] is None or settled[key] is None else row[key] - settled[key]
            if row["seen"] >= 2 and first_visible is None:
                first_visible = row["index"]
            if first_visible is not None and row["seen"] >= 2:
                if d["centre_pt"] is not None:
                    max_centre = max(max_centre, abs(d["centre_pt"]))
                if d["green_pt"] is not None:
                    max_green = max(max_green, abs(d["green_pt"]))
            report.append(
                "  %6d %8.3f %5d %7s %7s %7s %7s | %6s %6s %7s %6s" % (
                    row["index"], row["t"], row["seen"], fmt(row["top_pt"]), fmt(row["bot_pt"]), fmt(row["centre_pt"]),
                    fmt(row["green_pt"]), fmt(d["top_pt"]), fmt(d["bot_pt"]), fmt(d["centre_pt"]), fmt(d["green_pt"]),
                )
            )
        report.append(
            f"  SUMMARY {name}: first visible frame={first_visible} max|dCentre|={max_centre:.2f}pt max|dGreen|={max_green:.2f}pt"
        )
        if args.copy_frames:
            folder = os.path.join(args.out, "frames", f"{index + 1:02d}_{name}")
            os.makedirs(folder, exist_ok=True)
            for row in window:
                source = os.path.join(args.frames, row["file"])
                with Image.open(source) as image:
                    small = image.convert("RGB").resize((image.width // 2, image.height // 2), Image.LANCZOS)
                    small.save(os.path.join(folder, f"{row['index']:06d}_{row['t']:.3f}.jpg"), quality=90)
    text = "\n".join(report) + "\n"
    with open(os.path.join(args.out, "report.txt"), "w", encoding="utf-8") as handle:
        handle.write(text)
    print("\n".join(line for line in report if line.startswith("  SUMMARY") or line.startswith("===")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
