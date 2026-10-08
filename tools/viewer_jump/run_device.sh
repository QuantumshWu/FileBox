#!/bin/bash
# Runs the viewer UI test on one simulator while recording its screen, then measures the frames.
#   run_device.sh <udid> <label> <out dir>
# Expects the UI test already built into ./DerivedData (xcodebuild build-for-testing), and ffmpeg,
# ffprobe and a python3 with Pillow and numpy on PATH.
set -uo pipefail
UDID="$1"
LABEL="$2"
OUT="$3"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"
WORK="$(mktemp -d)"

now() { python3 -c 'import time; print("%.3f" % time.time())'; }

echo "== $LABEL ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light || true
# Let the home screen finish its first-boot work.
sleep 20

# Install first, so the probe log from an earlier run can be removed.
APP="$(find DerivedData/Build/Products -maxdepth 2 -name FileBox.app -path '*iphonesimulator*' | head -1)"
xcrun simctl install "$UDID" "$APP"
DATA="$(xcrun simctl get_app_container "$UDID" io.github.quantumshwu.filebox data 2>/dev/null || true)"
[ -n "$DATA" ] && rm -f "$DATA/Library/Caches/viewer-probe.log"

xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/recording.mp4" > "$OUT/record.log" 2>&1 &
REC=$!
for _ in $(seq 1 200); do
  grep -q "Recording started" "$OUT/record.log" 2>/dev/null && break
  sleep 0.05
done
now > "$OUT/record_start.txt"
cat "$OUT/record.log"

# VIEWER_TEST: one or more test methods of ViewerJumpUITests, separated by spaces.
ONLY=()
for TEST in ${VIEWER_TEST:-testViewerOpenPageToggleClose}; do
  ONLY+=(-only-testing:"FileBoxUITests/ViewerJumpUITests/$TEST")
done
xcodebuild test-without-building \
  -project FileBox.xcodeproj \
  -scheme FileBoxUITests \
  -destination "id=$UDID" \
  -derivedDataPath DerivedData \
  "${ONLY[@]}" \
  -parallel-testing-enabled NO \
  -resultBundlePath "$OUT/result.xcresult" \
  > "$OUT/test.log" 2>&1
TEST_STATUS=$?
echo "test exit $TEST_STATUS"
sleep 1
kill -INT "$REC" 2>/dev/null
wait "$REC" 2>/dev/null
ls -l "$OUT/recording.mp4" || true

grep -a "UITEST-EVENT" "$OUT/test.log" | sed 's/.*UITEST-EVENT //' | sort -u -k1,1n > "$OUT/events.txt"
tail -40 "$OUT/test.log"
DATA="$(xcrun simctl get_app_container "$UDID" io.github.quantumshwu.filebox data 2>/dev/null || true)"
[ -n "$DATA" ] && cp "$DATA/Library/Caches/viewer-probe.log" "$OUT/" 2>/dev/null
xcrun simctl shutdown "$UDID" || true

if [ -s "$OUT/recording.mp4" ]; then
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height,avg_frame_rate,nb_frames,duration -of default=nw=1 "$OUT/recording.mp4" | tee "$OUT/stream.txt"
  # The packets' pts, sorted: simctl repeats a pts now and then, and ffprobe's frame times then
  # fall back to the dts, which run seconds apart from the pts.
  ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$OUT/recording.mp4" | sort -g > "$OUT/frame_times.txt"
  mkdir -p "$WORK/frames"
  ffmpeg -v error -i "$OUT/recording.mp4" -fps_mode passthrough "$WORK/frames/f_%06d.png"
  echo "frames: $(ls "$WORK/frames" | wc -l) times: $(wc -l < "$OUT/frame_times.txt")"
  python3 "$ROOT/tools/viewer_jump/measure.py" \
    --frames "$WORK/frames" --times "$OUT/frame_times.txt" --events "$OUT/events.txt" \
    --record-start "$OUT/record_start.txt" --probe "$OUT/viewer-probe.log" --out "$OUT" --copy-frames
fi
if [ -s "$OUT/viewer-probe.log" ]; then
  python3 "$ROOT/tools/viewer_jump/probe_check.py" "$OUT/viewer-probe.log" --start "$OUT/record_start.txt" > "$OUT/probe_check.txt"
  cat "$OUT/probe_check.txt"
fi
rm -rf "$WORK"
exit $TEST_STATUS
