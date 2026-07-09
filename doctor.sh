#!/bin/bash
# Vox doctor — run `bash ~/vox/doctor.sh` and read (or paste) the report.
# Read-only: changes nothing on your system.

BREW=/opt/homebrew/bin
[ -x $BREW/sox ] || BREW=/usr/local/bin
ok()   { printf "  ✅ %s\n" "$1"; }
bad()  { printf "  ❌ %s\n" "$1"; }
info() { printf "  ·  %s\n" "$1"; }

echo "== Vox doctor =="

echo "[1] Dependencies"
for b in sox whisper-cli whisper-server; do
  [ -x "$BREW/$b" ] && ok "$b" || bad "$b missing — run: bash ~/vox/install.sh"
done
[ -d /Applications/Hammerspoon.app ] && ok "Hammerspoon.app" || bad "Hammerspoon missing"
pgrep -x Hammerspoon >/dev/null && ok "Hammerspoon running" || bad "Hammerspoon not running — open -a Hammerspoon"

echo "[2] Whisper model + server"
MODEL=~/vox/models/ggml-large-v3-turbo-q5_0.bin
[ -f "$MODEL" ] && ok "model present ($(du -h "$MODEL" | cut -f1))" || bad "model missing — run install.sh"
if pgrep -f "whisper-serve[r]" >/dev/null; then ok "whisper-server running"
else info "whisper-server not running (Vox starts it on demand — fine)"; fi

echo "[3] Speech-to-text pipeline (no mic involved)"
T=$(mktemp -d)
say -o "$T/t.aiff" "vox doctor pipeline test" 2>/dev/null
if [ -f "$T/t.aiff" ]; then
  "$BREW/sox" "$T/t.aiff" -r 16000 -c 1 -b 16 "$T/t.wav" 2>/dev/null
  OUT=$("$BREW/whisper-cli" -m "$MODEL" -f "$T/t.wav" -nt -np -l en 2>/dev/null | tr -d '\n' | sed 's/^ *//')
  case "$OUT" in *[Dd]octor*) ok "transcription works: \"$OUT\"";; *) bad "transcription failed (got: \"$OUT\")";; esac
fi

echo "[4] Microphone (records 3s from the DEFAULT input — say something now!)"
"$BREW/sox" -q -d -c 1 -r 16000 -b 16 "$T/mic.wav" trim 0 3 2>"$T/soxerr"
if [ -s "$T/mic.wav" ]; then
  AMP=$("$BREW/sox" "$T/mic.wav" -n stat 2>&1 | awk '/Maximum amplitude/{print $3}')
  echo "     peak level: $AMP  (good > 0.05, quiet < 0.02, silent < 0.005)"
  case "$AMP" in
    0.0000*|0.00[0-4]*) bad "SILENT — wrong input device, muted mic, or Terminal lacks mic permission";;
    0.0[01]*)           info "very quiet — raise input volume / speak closer (Vox normalizes, but more signal = better accuracy)";;
    *)                  ok "mic signal looks healthy";;
  esac
else
  bad "recording failed: $(cat "$T/soxerr" | head -1)"
fi
info "NOTE: this tested the Terminal's mic access. Vox records via Hammerspoon —"
info "System Settings > Privacy & Security > Microphone must list Hammerspoon ON."

echo "[5] Hammerspoon permissions (from TCC database, may need Full Disk Access)"
MIC=$(sqlite3 ~/Library/"Application Support"/com.apple.TCC/TCC.db \
  "select auth_value from access where service='kTCCServiceMicrophone' and client='org.hammerspoon.Hammerspoon';" 2>/dev/null)
case "$MIC" in
  2) ok "Hammerspoon microphone: GRANTED";;
  0) bad "Hammerspoon microphone: DENIED — enable it in System Settings > Privacy & Security > Microphone";;
  *) info "couldn't read TCC db — check System Settings > Privacy & Security > Microphone manually";;
esac
info "Accessibility can't be read from here — if the hotkey works, it's granted."

echo "[6] Default audio input device"
system_profiler SPAudioDataType 2>/dev/null | awk '/Input Source|Default Input Device/{print "     " $0}' | head -6

rm -rf "$T"
echo "== done =="
