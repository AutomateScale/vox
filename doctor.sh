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
# Voom (screen recording + presenter camera) checks
if [ -x "$HOME/vox/cam-bin" ]; then
  echo "  ok   cam-bin present (presenter camera ready)"
else
  if command -v swiftc >/dev/null 2>&1; then
    echo "  FIX  cam-bin missing but swiftc exists — run: swiftc -O ~/vox/cam.swift -o ~/vox/cam-bin"
  else
    echo "  FIX  cam-bin missing and NO swiftc — run: xcode-select --install, then re-run ~/vox/install.sh (presenter camera needs this)"
  fi
fi
SCR=$(sqlite3 ~/Library/"Application Support"/com.apple.TCC/TCC.db   "select auth_value from access where service='kTCCServiceScreenCapture' and client='org.hammerspoon.Hammerspoon';" 2>/dev/null)
case "$SCR" in
  2) echo "  ok   Hammerspoon has Screen Recording permission (Voom can capture)";;
  0|1) echo "  FIX  Hammerspoon DENIED Screen Recording — System Settings > Privacy & Security > Screen Recording > enable Hammerspoon (Voom saves nothing without it)";;
  *) echo "  info couldn't read Screen Recording TCC — check System Settings > Privacy & Security > Screen Recording for Hammerspoon";;
esac

for b in sox ffmpeg whisper-cli whisper-server; do
  [ -x "$BREW/$b" ] && ok "$b" || bad "$b missing — run: bash ~/vox/install.sh"
done
if [ -d /Applications/Hammerspoon.app ]; then
  if codesign --verify /Applications/Hammerspoon.app >/dev/null 2>&1; then
    ok "Vox engine (Hammerspoon.app) — signature intact"
  else
    bad "Vox engine signature BROKEN — permissions will not stick."
    info "Fix: brew reinstall --cask hammerspoon && bash ~/vox/install.sh"
    info "(This happens when the app bundle gets renamed or its icon file replaced."
    info " Vox brands the icon safely via metadata — never edit the .app itself.)"
  fi
else
  bad "Vox engine (Hammerspoon.app) missing"
fi
pgrep -x Hammerspoon >/dev/null && ok "Hammerspoon running" || bad "Hammerspoon not running — open -a Hammerspoon"

echo "[2] Whisper model + server"
CORES="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 4)"
if [ "$(uname -m)" = "arm64" ]; then
  MODEL=~/vox/models/ggml-large-v3-turbo-q5_0.bin
  MODEL_SHA="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
elif [ "$CORES" -le 2 ]; then
  MODEL=~/vox/models/ggml-tiny-q5_1.bin
  MODEL_SHA="818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
else
  MODEL=~/vox/models/ggml-small-q5_1.bin
  MODEL_SHA="ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
fi
if [ ! -f "$MODEL" ]; then
  bad "model missing — run: bash ~/vox/install.sh"
elif [ "$(shasum -a 256 "$MODEL" 2>/dev/null | awk '{print $1}')" = "$MODEL_SHA" ]; then
  ok "model present + checksum verified ($(du -h "$MODEL" | cut -f1))"
else
  bad "model CORRUPT (checksum mismatch) — delete it and re-run install.sh:"
  info "rm '$MODEL' && bash ~/vox/install.sh"
fi
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

HS=/opt/homebrew/bin/hs
[ -x "$HS" ] || HS=/usr/local/bin/hs
if [ -x "$HS" ] && pgrep -x Hammerspoon >/dev/null; then
  ACC=$("$HS" -c "return hs.accessibilityState()" 2>/dev/null | tr -d '[:space:]')
  case "$ACC" in
    true)  ok "Hammerspoon accessibility: GRANTED (hotkey can arm)";;
    false) bad "Hammerspoon accessibility: DENIED — THE HOTKEY WILL NOT WORK.";
           info "Fix: System Settings > Privacy & Security > Accessibility > enable Hammerspoon";
           info "(toggle off/on if already listed), THEN relaunch it so the grant takes:";
           info "    killall Hammerspoon; open -a Hammerspoon";
           info "A live process often ignores the grant until relaunched.";;
    *)     info "couldn't query accessibility via hs CLI — if the hotkey does nothing, grant it in";
           info "System Settings > Privacy & Security > Accessibility > Hammerspoon";;
  esac
else
  info "Accessibility: install the hs CLI or start Hammerspoon to check. If the hotkey does"
  info "nothing, grant it: System Settings > Privacy & Security > Accessibility > Hammerspoon."
fi

echo "[6] The alien's brain (memory + knowledge graph)"
if [ -f ~/vox/memory/vox-memory.db ]; then
  STATS=$(/usr/bin/python3 ~/vox/mem.py stats 2>/dev/null)
  echo "     $STATS"
  case "$STATS" in
    *'"entries": 0'*) info "brain is empty — dictate, or absorb screens with the P button";;
    *'"embedded": 0'*) ok "brain healthy (word-match recall; for meaning-based recall: ollama pull nomic-embed-text && python3 ~/vox/mem.py embed)";;
    *entries*)        ok "brain healthy (semantic recall active)";;
    *)                bad "brain unreadable — check: python3 ~/vox/mem.py stats";;
  esac
else
  info "no brain yet — it forms on your first dictation"
fi
[ -f ~/vox/identity.md ] && ok "identity notes present (replies sound like you)"   || info "no ~/vox/identity.md — smart replies won't sound like you. Set it up: cp ~/vox/identity.example.md ~/vox/identity.md && open -e ~/vox/identity.md"

echo "[7] Pulse API (localhost) + auth guard"
API=$(curl -s --max-time 3 http://127.0.0.1:8091/status 2>/dev/null)
case "$API" in
  *pipeline*)
    ok "API answering on :8091"
    # security regression check: a forged-Host request must be rejected
    FORGED=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
              -H "Host: evil.example" http://127.0.0.1:8091/status 2>/dev/null)
    XSITE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
              -H "Origin: https://evil.example" http://127.0.0.1:8091/recent 2>/dev/null)
    if [ "$FORGED" = "403" ] && [ "$XSITE" = "403" ]; then
      ok "API auth guard active (forged-Host + cross-site both blocked)"
    else
      bad "API AUTH GUARD MISSING — a web page could read your memory!"
      info "forged-Host=$FORGED xsite=$XSITE (both must be 403). Update Vox:"
      info "cd ~/vox && git pull --ff-only && killall Hammerspoon; open -a Hammerspoon"
    fi;;
  *) info "API not answering (fine if Vox just started; check apiEnable)";;
esac

echo "[8] Screen reader (triple-tap replies + P button)"
if [ -x ~/vox/ocr-bin ]; then ok "ocr-bin compiled"
elif command -v swiftc >/dev/null 2>&1; then
  info "ocr-bin not built yet — compiles itself on first use"
else
  info "no Swift toolchain — screen features unavailable until Xcode CLT installed"
fi

echo "[9] AI brain (Ollama — powers Hey Vox, smart reply, expand, translate)"
OLL=$(curl -s --max-time 3 http://localhost:11434/api/tags 2>/dev/null)
if [ -n "$OLL" ]; then
  ok "Ollama reachable"
  for m in llama3.2:3b qwen2.5:7b nomic-embed-text; do
    case "$OLL" in
      *"$m"*) ok "model $m present";;
      *)      info "model $m not pulled — some AI features degrade (ollama pull $m)";;
    esac
  done
else
  info "Ollama not running — dictation works fine, but Hey Vox / smart reply /"
  info "expand / translate are unavailable until: brew services start ollama"
fi

echo "[10] Default audio input device"
system_profiler SPAudioDataType 2>/dev/null | awk '/Input Source|Default Input Device/{print "     " $0}' | head -6

echo "[11] Deploy safety (bootguard + watchdog)"
if grep -q 'require("bootguard")' "$HOME/.hammerspoon/init.lua" 2>/dev/null; then
  ok "bootguard loader active — a broken update rolls back automatically"
else
  info "init.lua still loads vox directly — bootguard arms itself on next Vox load"
fi
if [ -s "$HOME/vox/.vox-lkg" ]; then
  ok "last-known-good commit recorded ($(cut -c1-7 "$HOME/vox/.vox-lkg"))"
else
  info "no last-known-good recorded yet — written after the next successful load"
fi
if launchctl print "gui/$(id -u)/com.vox.watchdog" >/dev/null 2>&1; then
  ok "engine watchdog loaded — Hammerspoon relaunches within 5 min if it dies"
else
  info "engine watchdog not loaded — installs itself on next Vox load"
fi
[ -s "$HOME/vox/.vox-bad-commit" ] && \
  info "quarantined broken commit: $(cut -c1-7 "$HOME/vox/.vox-bad-commit") — updater skips it until upstream moves on"

rm -rf "$T"
echo "== done =="
