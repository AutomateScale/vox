#!/bin/zsh
# Vox benchmark — objective pipeline numbers for comparing tuning passes.
#   1. Transcription: 5 phrases via macOS `say` -> whisper-server
#      (latency + word accuracy vs the known text)
#   2. Speech: POST /speak -> first audible chunk
#   3. Ask flow: question -> first audible spoken-answer chunk (end to end)
# Run it before and after a change; compare the numbers, not the vibes.
# Usage: zsh ~/vox/bench.sh
set -u
BREW=/opt/homebrew/bin
[ -x "$BREW/sox" ] || BREW=/usr/local/bin
TMP="${TMPDIR:-/tmp}/vox-bench"; mkdir -p "$TMP"

PHRASES=(
  "Open Safari and check the calendar for tomorrow"
  "The quarterly report needs three more revisions before Friday"
  "Close Slack"
  "Remind me to call the doctor about the appointment"
  "Switch to terminal"
)

echo "── transcription (whisper-server, ${#PHRASES[@]} phrases) ──"
total=0; accsum=0; n=0
for p in "${PHRASES[@]}"; do
  say -o "$TMP/b.aiff" "$p" 2>/dev/null
  "$BREW/sox" "$TMP/b.aiff" -r 16000 -c 1 -b 16 "$TMP/b.wav" 2>/dev/null
  t0=$(python3 -c 'import time; print(time.time())')
  out=$(curl -s --max-time 30 -F file=@"$TMP/b.wav" -F temperature=0.0 \
        -F response_format=text -F language=en \
        http://127.0.0.1:8090/inference)
  if [ -z "$(echo "$out" | tr -d '[:space:]')" ]; then
    sleep 2   # server busy (live dictation?) — one retry
    t0=$(python3 -c 'import time; print(time.time())')
    out=$(curl -s --max-time 30 -F file=@"$TMP/b.wav" -F temperature=0.0 \
          -F response_format=text -F language=en \
          http://127.0.0.1:8090/inference)
  fi
  t1=$(python3 -c 'import time; print(time.time())')
  ms=$(python3 -c "print(int(($t1-$t0)*1000))")
  acc=$(python3 - "$p" "$out" <<'PYEOF'
import sys, re
exp = re.findall(r"[a-z']+", sys.argv[1].lower())
got = set(re.findall(r"[a-z']+", sys.argv[2].lower()))
print(100 * sum(1 for w in exp if w in got) // max(1, len(exp)))
PYEOF
)
  total=$((total+ms)); accsum=$((accsum+acc)); n=$((n+1))
  printf "  %5dms  %3d%%  %s\n" "$ms" "$acc" "${out//$'\n'/ }"
done
echo "  ── avg latency: $((total/n))ms · avg word accuracy: $((accsum/n))%"

echo "── speech (POST /speak -> first audio) ──"
python3 - <<'PYEOF'
import glob, json, os, time, urllib.request
t0 = time.time()
urllib.request.urlopen(urllib.request.Request(
    "http://127.0.0.1:8093/speak",
    data=json.dumps({"text": "Speech latency benchmark check.",
                     "voice": "vox", "speed": 1.0}).encode(),
    method="POST"), timeout=3)
while time.time() - t0 < 15:
    for f in glob.glob(os.path.expanduser("~/vox/models/kokoro/srv-*.wav")):
        if os.path.getmtime(f) > t0:
            print(f"  first audio: {int((time.time()-t0)*1000)}ms")
            raise SystemExit
    time.sleep(0.03)
print("  no audio in 15s — is the speech server up?")
PYEOF

echo "── ask flow (question -> first spoken-answer audio, warm) ──"
python3 - <<'PYEOF'
import glob, os, subprocess, time
seen = {f: os.path.getmtime(f)
        for f in glob.glob(os.path.expanduser("~/vox/models/kokoro/srv*.wav"))}
subprocess.run(["/opt/homebrew/bin/hs", "-t", "10", "-c",
    'require("vox").debug.streamAsk("Very briefly, what day is it?")'],
    capture_output=True, timeout=15)
t0 = time.time()   # clock starts when the ask is dispatched, not CLI spawn
while time.time() - t0 < 30:
    for f in glob.glob(os.path.expanduser("~/vox/models/kokoro/srv*.wav")):
        if os.path.getmtime(f) > t0 and os.path.getmtime(f) != seen.get(f):
            print(f"  first answer audio: {int((time.time()-t0)*1000)}ms"
                  " (includes memory search + LLM + synthesis)")
            raise SystemExit
    time.sleep(0.05)
print("  no answer audio in 30s")
PYEOF
echo "done."
