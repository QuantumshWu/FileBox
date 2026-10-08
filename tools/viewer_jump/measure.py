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
* the folder underneath: while the viewer fades in or out, or a page is swiped away, the folder
  shows through it. For every opening and closing step, how far the folder is from where it is
  without the viewer (before the tap for an opening, after the close for a closing), in each frame:
  the vertical shift that best lines up the frame's rows of brightness with the reference frame's
  (normalised correlation, so the black fading over it does not matter). "band" uses the rows the
  picture does not cover, "thumbs" the list's thumbnail column through the picture (only while the
  picture is still faint). A frame counts when the match is clear.

Usage:
  measure.py --frames DIR --times frame_times.txt --events events.txt --record-start start.txt \\
             [--probe viewer-probe.log] --out OUTDIR [--copy-frames]
  measure.py --from-csv measurements.csv --events ... --record-start ... --probe ... --out OUTDIR

DIR holds f_000001.png, f_000002.png, ... in order (ffmpeg -fps_mode passthrough), frame_times.txt
the presentation time of each frame (the video packets' pts, sorted: simctl's recordings repeat a
pts now and then, and ffmpeg's own frame times then fall back to the dts), events.txt lines of
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
# Just inside the picture's left and right red border, where the viewer's bars never are: these see
# the picture's full height even while the bars cover its top or bottom edge in the middle columns.
EDGE_COLUMNS = (0.008, 0.992)
CSV_KEYS = ["index", "t", "file", "h", "seen", "top_pt", "bot_pt", "centre_pt", "green_pt", "estimate_pt"]
for _c in COLUMNS + EDGE_COLUMNS:
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
    luma = array.astype(np.float32) @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    # Brightness of each row (whole width, and the list's thumbnail column), for the folder's position.
    result["_rows"] = luma.mean(axis=1)
    result["_thumbs"] = luma[:, int(width * 0.04):int(width * 0.15)].mean(axis=1)
    for fraction in COLUMNS + EDGE_COLUMNS:
        x = min(width - 2, max(1, int(round(width * fraction))))
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


# A picture in the viewer is never shorter than this (a 2:1 picture on a 375 pt wide screen is
# 187 pt); the folder's thumbnails showing through the fading viewer always are.
MIN_HEIGHT_PT = 140


def summary_values(row, scale):
    """Top edge, bottom edge, centre, green line and the combined centre estimate (points), from the
    columns that saw a red border tall enough to be the viewer's picture (not a thumbnail)."""
    tops, bots, centres, greens = [], [], [], []
    for c in COLUMNS:
        t, b = row.get(f"red_top@{c}"), row.get(f"red_bot@{c}")
        if t is None or b is None or (b - t) / scale < MIN_HEIGHT_PT:
            continue
        tops.append(t)
        bots.append(b)
        # Each column's own middle: while paging, columns can see two different pictures.
        centres.append((t + b) / 2)
        g = row.get(f"green@{c}") if c != 0.5 else None
        if g is not None and t < g < b:
            greens.append(g)
    edges = []
    for c in EDGE_COLUMNS:
        t, b = row.get(f"red_top@{c}"), row.get(f"red_bot@{c}")
        if t is not None and b is not None and (b - t) / scale >= MIN_HEIGHT_PT:
            edges.append((t + b) / 2)
    to_pt = lambda v: None if v is None else v / scale
    seen = len(centres) + len(greens) + len(edges)
    # The pattern's centre: from the side borders when the picture reaches the screen's sides and
    # they agree (the bars never cover them), otherwise the median of every estimate (each column's
    # middle of the red border and each green line), so one column caught by a page sliding past or
    # a bar over an edge never decides alone.
    if edges and max(edges) - min(edges) <= 2 * scale:
        estimate = median(edges)
    else:
        estimate = median(edges + centres + greens)
    return (to_pt(median(tops)), to_pt(median(bots)), to_pt(median(centres)), to_pt(median(greens)),
            to_pt(estimate), seen)


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
    sideways = []
    if not path or not os.path.exists(path):
        return scale, height, events, sideways
    landscape = False
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
        window = re.search(r"win=\[[-0-9.]+,[-0-9.]+,([0-9.]+),([0-9.]+)\]", line)
        if window and parts[2].startswith("F"):
            now = float(window.group(1)) > float(window.group(2))
            if now != landscape:
                landscape = now
                if now:
                    sideways.append([float(parts[0]) - start, None])
                elif sideways:
                    sideways[-1][1] = float(parts[0]) - start
    return scale, height, events, sideways


def probe_status_bar(path):
    """The status bar's height (pt) when it shows upright, from the probe log."""
    best = None
    if not path or not os.path.exists(path):
        return best
    for line in load_lines(path):
        match = re.search(r"sbH=([0-9.]+) \| win=\[[-0-9.]+,[-0-9.]+,([0-9.]+),([0-9.]+)\]", line)
        if match and float(match.group(2)) < float(match.group(3)):
            value = float(match.group(1))
            if value > 0 and (best is None or value > best):
                best = value
    return best


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
    if row.get("estimate_pt") is None or row.get("sideways"):
        return None
    return abs(row["estimate_pt"] - mid)


def analyse_session(session, mid, args, swiped=False):
    """Splits a session into opening, open and closing, and finds the largest shift in each."""
    t0 = session[0]["t"]
    t1 = session[-1]["t"]
    devs = [deviation(row, mid) for row in session]
    # A page swiped away (the app logged a dismiss drag) follows the finger and flies off: that is
    # everything after the last centred frame. A fading close ends where it was.
    fly_start = len(session)
    last = next((d for d in reversed(devs) if d is not None), None)
    if last is not None and last > args.tolerance and (swiped or last > 20):
        centred = [k for k, d in enumerate(devs) if d is not None and d <= args.tolerance]
        fly_start = centred[-1] + 1 if centred else 0
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


def to_points(profile, scale):
    """A per-pixel-row profile averaged into rows of one point."""
    k = max(1, int(round(scale)))
    n = len(profile) // k
    return profile[:n * k].reshape(n, k).mean(axis=1)


def best_shift(frame, ref, mask, max_shift=40):
    """The shift s (points; positive = the frame's content is lower) that best matches frame[y] with
    ref[y - s] over the rows in mask, its normalised correlation, and the correlation at s = 0."""
    n = len(frame)
    ys = np.nonzero(mask)[0]
    scores = {}
    for shift in range(-max_shift, max_shift + 1):
        y = ys[(ys - shift >= 0) & (ys - shift < n) & mask[np.clip(ys - shift, 0, n - 1)]]
        if len(y) < 40:
            continue
        a = frame[y] - frame[y].mean()
        b = ref[y - shift] - ref[y - shift].mean()
        denom = np.sqrt((a * a).sum() * (b * b).sum())
        if denom <= 1e-6:
            continue
        scores[shift] = float((a * b).sum() / denom)
    if not scores:
        return None, None, None
    best = max(scores, key=scores.get)
    peak = scores[best]
    refined = float(best)
    if best - 1 in scores and best + 1 in scores:
        l, c, r = scores[best - 1], peak, scores[best + 1]
        curve = l - 2 * c + r
        if curve < 0:
            refined = best + 0.5 * (l - r) / curve
    return refined, peak, scores.get(0)


def folder_shift(rows, index_of, ref_index, frame_index, scale, top_margin, bottom_margin, picture, kind):
    """Shift of the folder in one frame against the reference frame (see the module notes)."""
    ref_row, row = rows[index_of[ref_index]], rows[index_of[frame_index]]
    key = "_rows_pt" if kind == "band" else "_thumbs_pt"
    if row.get(key) is None or ref_row.get(key) is None:
        return None
    frame, ref = row[key], ref_row[key]
    n = min(len(frame), len(ref))
    frame, ref = frame[:n], ref[:n]
    mask = np.zeros(n, dtype=bool)
    mask[int(top_margin):max(int(top_margin), n - int(bottom_margin))] = True
    if kind == "band":
        extents = list(picture)
        if row.get("seen", 0) >= 2 and row.get("top_pt") is not None and row.get("bot_pt") is not None:
            extents.append((row["top_pt"], row["bot_pt"]))
        for top, bot in extents:
            mask[max(0, int(top - 8)):min(n, int(bot + 9))] = False
    shift, peak, at_zero = best_shift(frame, ref, mask)
    if shift is None:
        return None
    # The folder must really show there: rows of one flat colour (the black of an opaque viewer)
    # match anything.
    contrast = min(float(frame[mask].std()), float(ref[mask].std())) if mask.any() else 0.0
    clear = peak >= (0.6 if kind == "band" else 0.75) and contrast >= 2.0
    return {"shift": shift, "peak": peak, "zero": at_zero, "clear": clear, "rows": int(mask.sum()),
            "contrast": contrast}


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
    parser.add_argument("--folder-tolerance", type=float, default=1.5, help="largest shift (pt) of the folder that is not a move")
    parser.add_argument("--copy-frames", action="store_true", help="copy each step's frames (half size JPEG)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    start = float(load_lines(args.record_start)[0]) if args.record_start else 0.0
    probe_scale, probe_height, probe_events, sideways = probe_info(args.probe, start)
    status_bar = probe_status_bar(args.probe)
    scale = args.scale or probe_scale or 3.0

    if args.from_csv:
        rows = read_csv(args.from_csv)
        args.copy_frames = False
        saved_path = os.path.join(os.path.dirname(os.path.abspath(args.from_csv)), "profiles.npz")
        if os.path.exists(saved_path):
            saved = np.load(saved_path)
            if len(saved["rows"]) == len(rows):
                for row, band, thumbs in zip(rows, saved["rows"], saved["thumbs"]):
                    row["_rows_pt"] = band.astype(np.float32)
                    row["_thumbs_pt"] = thumbs.astype(np.float32)
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
            row["_rows_pt"] = to_points(row.pop("_rows"), scale)
            row["_thumbs_pt"] = to_points(row.pop("_thumbs"), scale)
        # Kept for --from-csv runs: one point per row is enough for the folder's position.
        np.savez_compressed(
            os.path.join(args.out, "profiles.npz"),
            rows=np.array([row["_rows_pt"] for row in rows], dtype=np.float16),
            thumbs=np.array([row["_thumbs_pt"] for row in rows], dtype=np.float16),
        )
    for row in rows:
        top, bot, centre, green, estimate, seen = summary_values(row, scale)
        row.update({"top_pt": top, "bot_pt": bot, "centre_pt": centre, "green_pt": green, "estimate_pt": estimate,
                    "seen": seen})
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
    drags = [t for t, text in probe_events if text == "dismiss drag began"]
    lags = []
    for session in sessions:
        before = [t for t in appeared if t <= session[0]["t"]]
        if before:
            lags.append(session[0]["t"] - before[-1])
    lag = median([l for l in lags if 0 <= l < 5]) or 0.0
    # From a second before the window turned (the recording's lag varies by a few tenths of a second,
    # and the turn starts on screen as the window turns) until a second after it is upright again.
    turned = [(a + lag - 1.0, (b if b is not None else 1e9) + lag + 1.0) for a, b in sideways]
    for row in rows:
        row["sideways"] = row["t"] is not None and any(a <= row["t"] <= b for a, b in turned)
    verdict_lines = [
        "",
        f"SESSIONS (largest distance of the pattern's centre from the screen centre {fmt(mid)}pt, in any frame;",
        f"a jump is more than {args.tolerance:.2f} pt; opening = first {args.opening:.1f}s, closing = last {args.closing:.1f}s;",
        f"the recording lags the app's clock by about {lag:.2f}s)",
        "  #  file                 frames         t(s)            opening            open               closing            verdict",
    ]
    any_jump = False
    fly_frames = set()
    for number, session in enumerate(sessions, 1):
        t0 = session[0]["t"]
        label = "?"
        candidates = [text[5:] for t, text in opens if t + lag <= t0 + 0.2]
        if candidates:
            label = candidates[-1]
        t_end = session[-1]["t"]
        nxt = sessions[number][0]["t"] if number < len(sessions) else t_end + 10
        swiped = any(t0 <= t + lag <= min(t_end + 1.0, nxt) for t in drags)
        phases, fly = analyse_session(session, mid, args, swiped)
        fly_frames.update(row["index"] for row in fly)
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
        if any(row.get("sideways") for row in session):
            verdict += " (sideways frames left to the probe check)"
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
    step_lines = [
        "",
        "STEP SUMMARY (frames in each step's window in which the picture shows, not counting a page flying off",
        "after a swipe; largest distance of the pattern's centre from the screen centre)",
        "  step                             kind          frames  first   max|d|  verdict",
    ]
    for index, (t_begin, t_end, name) in enumerate(steps):
        kind = step_kind(name)
        if kind == "other":
            continue
        next_begin = steps[index + 1][0] if index + 1 < len(steps) else t_end + 10
        lo = t_begin - args.before
        hi = min(t_end + args.after + (t_end - t_begin), next_begin - 0.05)
        shown = [row for row in rows if row["t"] is not None and lo <= row["t"] <= hi and row["seen"] >= 2
                 and row["index"] not in fly_frames and row.get("estimate_pt") is not None
                 and not row.get("sideways")]
        worst = max((abs(row["estimate_pt"] - mid) for row in shown), default=None)
        if not shown:
            verdict = "no frames with the picture"
        else:
            verdict = "OK" if worst <= args.tolerance else "JUMP"
        if kind == "close-swipe":
            verdict += " (fly-off excluded)"
        if kind == "rotate":
            verdict = "sideways: see the probe check"
        first = ("f" + str(shown[0]["index"])) if shown else "-"
        step_lines.append(f"  {name:32s} {kind:12s} {len(shown):6d} {first:>6s} {fmt(worst):>8s}  {verdict}")
    report += step_lines

    # The folder underneath, while it can be seen through the viewer.
    index_of = {row["index"]: k for k, row in enumerate(rows)}
    have_profiles = any(row.get("_rows_pt") is not None for row in rows)
    folder_lines = [
        "",
        "FOLDER UNDERNEATH (vertical shift of the folder against where it is without the viewer, in frames",
        "where it shows clearly through the viewer; band = rows outside the picture, thumbs = the list's",
        f"thumbnail column; a move is more than {args.folder_tolerance:.2f} pt)",
        "  step                             kind          ref     clear  max|shift|  at      verdict",
    ]
    folder_detail = {}
    any_move = False
    if have_profiles and mid is not None:
        top_margin = (status_bar or 20.0) + 2
        bottom_margin = 100
        for index, (t_begin, t_end, name) in enumerate(steps):
            kind = step_kind(name)
            if kind not in ("open", "close-button", "close-swipe"):
                continue
            next_begin = steps[index + 1][0] if index + 1 < len(steps) else t_end + 10
            lo = t_begin - 0.05
            hi = min(t_end + args.after + (t_end - t_begin), next_begin - 0.05)
            window = [row for row in rows if row["t"] is not None and lo <= row["t"] <= hi and not row.get("sideways")]
            if not window:
                continue
            if kind == "open":
                # The last frame before the tap: the recorder writes none while nothing moves, so
                # it can be seconds old.
                before = [row for row in rows if row["t"] is not None and t_begin - 60 <= row["t"] < t_begin - 0.05]
                ref = before[-1] if before else None
            else:
                ref = window[-1]
            if ref is None or ref.get("sideways"):
                continue
            # Where the picture is once open (it is smaller while it grows in).
            settled = [(row["top_pt"], row["bot_pt"]) for row in window
                       if row.get("seen", 0) >= 2 and row.get("top_pt") is not None and row.get("bot_pt") is not None]
            picture = [(min(t for t, _ in settled), max(b for _, b in settled))] if settled and kind == "open" else []
            results = []
            for row in window:
                if row is ref:
                    continue
                band = folder_shift(rows, index_of, ref["index"], row["index"], scale, top_margin, bottom_margin, picture, "band")
                thumbs = folder_shift(rows, index_of, ref["index"], row["index"], scale, top_margin, bottom_margin, picture, "thumbs")
                pick = band if band and band["clear"] else (thumbs if thumbs and thumbs["clear"] else None)
                results.append((row, band, thumbs, pick))
            folder_detail[name] = {r[0]["index"]: r for r in results}
            clear = [r for r in results if r[3] is not None]
            worst = max(clear, key=lambda r: abs(r[3]["shift"]), default=None)
            if worst is None:
                verdict = "folder not seen"
                cell = "-"
                at = "-"
            else:
                moved = abs(worst[3]["shift"]) > args.folder_tolerance
                any_move = any_move or moved
                verdict = "MOVES" if moved else "OK"
                cell = f"{worst[3]['shift']:+.2f}"
                at = f"f{worst[0]['index']}"
            folder_lines.append(f"  {name:32s} {kind:12s} f{ref['index']:<6d} {len(clear):5d}  {cell:>10s}  {at:7s} {verdict}")
    else:
        folder_lines.append("  (no frame profiles)")
    folder_lines.append(f"  FOLDER OVERALL: {'MOVES' if any_move else 'never moves while it shows'}")
    report += folder_lines

    report.append("")
    report.append("STEPS (test steps moved by the lag above; positions in points from the top of the screen;")
    report.append("dC / dG = centre / green line minus the screen centre; folder = the folder's shift, see above)")
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
        report.append("  frame      t(s)  seen     top     bot  centre   green |     dC     dG  dEstimate | folder band (corr)  thumbs (corr)")
        detail = folder_detail.get(name, {})
        for row in window:
            dc = None if row["centre_pt"] is None or mid is None else row["centre_pt"] - mid
            dg = None if row["green_pt"] is None or mid is None else row["green_pt"] - mid
            de = None if row.get("estimate_pt") is None or mid is None else row["estimate_pt"] - mid
            folder = ""
            if row["index"] in detail:
                _, band, thumbs, _ = detail[row["index"]]
                show = lambda m: "-" if m is None else f"{m['shift']:+6.2f} ({m['peak']:.2f}){'' if m['clear'] else '?'}"
                folder = f" | {show(band):>18s} {show(thumbs):>18s}"
            report.append(
                "  %6d %8.3f %5d %7s %7s %7s %7s | %6s %6s %6s%s" % (
                    row["index"], row["t"], row["seen"], fmt(row["top_pt"]), fmt(row["bot_pt"]),
                    fmt(row["centre_pt"]), fmt(row["green_pt"]), fmt(dc), fmt(dg), fmt(de), folder,
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
    print("\n".join(verdict_lines + step_lines + folder_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
