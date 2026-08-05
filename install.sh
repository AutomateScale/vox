#!/bin/bash
# Vox installer — drop-in setup for a new Mac.
#   git clone https://github.com/AutomateScale/vox.git ~/vox
#   cd ~/vox && bash install.sh
set -e

REPO="$HOME/vox"
# Hardware-aware model: Apple Silicon flies with large-v3-turbo on the GPU;
# Intel Macs get `small` (5x lighter — the large model crawls on old CPUs).
CORES="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 4)"
if [ "$(uname -m)" = "arm64" ]; then
  MODEL_FILE="ggml-large-v3-turbo-q5_0.bin"
  MODEL_SHA="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
elif [ "$CORES" -le 2 ]; then
  # ancient Intel (2012 MBA class): tiny is the only model that keeps up
  MODEL_FILE="ggml-tiny-q5_1.bin"
  MODEL_SHA="818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
  echo "==> Old Intel Mac ($CORES cores) — using the tiny Whisper model (~31MB)."
  echo "    Better accuracy option: borrow a fast Mac over LAN — 'Remote"
  echo "    transcription' in the README."
else
  MODEL_FILE="ggml-small-q5_1.bin"
  MODEL_SHA="ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
  echo "==> Intel Mac detected — using the lighter Whisper model (~180MB)."
fi
MODEL="$REPO/models/$MODEL_FILE"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_FILE"

# --- Homebrew: find it, or say exactly how to get it -------------
if ! command -v brew >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/brew ]; then          # Apple Silicon, not on PATH
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then           # Intel
    eval "$(/usr/local/bin/brew shellenv)"
  else
    echo "Homebrew is not installed on this Mac. Install it first:"
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo "then re-run:  cd ~/vox && bash install.sh"
    exit 1
  fi
fi
BREW_PREFIX="$(brew --prefix)"

# install with one retry after brew update (stale cask/formula index)
binstall() {
  brew list "$@" >/dev/null 2>&1 && return 0
  brew install "$@" && return 0
  echo "==> '$*' failed — updating Homebrew and retrying once..."
  brew update
  brew install "$@"
}

echo "==> [1/6] Installing dependencies (Homebrew)..."
binstall --cask hammerspoon
binstall whisper-cpp
binstall sox
binstall ollama

echo "==> [2/6] Whisper model ($MODEL_FILE) — download + checksum verify..."
mkdir -p "$REPO/models"
verify_model() { [ -f "$MODEL" ] && \
  [ "$(shasum -a 256 "$MODEL" 2>/dev/null | awk '{print $1}')" = "$MODEL_SHA" ]; }
if verify_model; then
  echo "    model present and verified ✅"
else
  [ -f "$MODEL" ] && echo "    existing model failed checksum — re-downloading..."
  ok=0
  for attempt in 1 2 3; do
    echo "    download attempt $attempt/3..."
    curl -fL -C - -o "$MODEL" "$MODEL_URL" || true      # -C - resumes a partial
    if verify_model; then ok=1; break; fi
    echo "    incomplete/corrupt — restarting fresh..."
    rm -f "$MODEL"
    sleep 2
  done
  if [ "$ok" = 1 ]; then
    echo "    model downloaded and verified ✅"
  else
    echo "    ❌ model download failed after 3 tries — check your connection and re-run."
    echo "       (Everything else installs fine; Vox just can't transcribe until the model is present.)"
  fi
fi

echo "==> [3/6] Ollama models (OPTIONAL — dictation works without them)..."
# These are the biggest downloads in the whole install (up to ~7GB) and NOTHING
# in the core dictation path needs them. Running them in the foreground meant a
# user on hotel wifi stared at a progress bar for 40 minutes before they could
# say a single word. They now run detached: dictation is live in ~2 minutes and
# the LLM features light up on their own as each model lands.
brew services start ollama >/dev/null 2>&1 || true

# Model list is built per-machine, then handed to one background worker.
# ARRAY, not a space-joined string: an unquoted string expansion relies on
# word-splitting, which zsh does NOT do by default — under zsh all three names
# arrive as a single argv and every pull "fails". An array is unambiguous.
OLLAMA_MODELS=(llama3.2:3b nomic-embed-text)
if [ "$(sysctl -n hw.memsize)" -ge 12884901888 ]; then
  OLLAMA_MODELS+=(qwen2.5:7b)                 # translation + content work (~4.7GB)
else
  echo "    <12GB RAM — staying on the fast model only (right call for this Mac)"
fi

PULL_LOG="$REPO/.ollama-pull.log"
PULL_STAMP="$REPO/.ollama-pull.done"
rm -f "$PULL_STAMP"

# Detached worker: retries each model up to 3 times (ollama resumes partial
# blobs on its own, so a retry costs only what was actually lost). setsid-style
# nohup so closing the Terminal window can't orphan-kill the download.
nohup bash -c '
  REPO="$1"; shift
  LOG="$REPO/.ollama-pull.log"
  : > "$LOG"
  # Ollama needs a moment after brew services start before it accepts pulls.
  for _ in $(seq 1 30); do
    ollama list >/dev/null 2>&1 && break
    sleep 2
  done
  failed=""
  for m in "$@"; do
    ok=0
    for attempt in 1 2 3; do
      echo "[$(date +%H:%M:%S)] pulling $m (attempt $attempt/3)" >> "$LOG"
      if ollama pull "$m" >> "$LOG" 2>&1; then ok=1; break; fi
      sleep 5
    done
    [ "$ok" = 1 ] || failed="$failed $m"
  done
  if [ -n "$failed" ]; then
    echo "INCOMPLETE:$failed" > "$REPO/.ollama-pull.done"
  else
    echo "OK" > "$REPO/.ollama-pull.done"
  fi
' _ "$REPO" "${OLLAMA_MODELS[@]}" >/dev/null 2>&1 &

echo "    ⬇️  Downloading in the BACKGROUND: ${OLLAMA_MODELS[*]}"
echo "    Dictation does NOT wait for these — keep installing."
echo "    Progress:  tail -f ~/vox/.ollama-pull.log"

echo "==> [4/6] Fallback UI sounds..."
mkdir -p "$REPO/sounds/classic"
if [ ! -f "$REPO/sounds/classic/start.wav" ]; then
  sox -n -r 44100 "$REPO/sounds/classic/start.wav" synth 0.12 sine 500-900 fade h 0.01 0.12 0.06 gain -18
  sox -n -r 44100 "$REPO/sounds/classic/stop.wav"  synth 0.12 sine 900-550 fade h 0.01 0.12 0.06 gain -18
  sox -n -r 44100 "$REPO/sounds/classic/done.wav"  synth 0.05 sine 1250   fade h 0.005 0.05 0.03 gain -20
fi

echo "==> [5/6] Wiring the Vox engine config + hs CLI..."
mkdir -p ~/.hammerspoon
if grep -q 'require("vox")' ~/.hammerspoon/init.lua 2>/dev/null \
   && ! grep -q 'bootguard' ~/.hammerspoon/init.lua; then
  # older install: swap the direct load for the guarded one
  sed -i '' 's|require("vox")|require("bootguard")  -- guarded load: rolls back a broken Vox update|' \
    ~/.hammerspoon/init.lua
elif ! grep -q 'require("bootguard")' ~/.hammerspoon/init.lua 2>/dev/null; then
  cat >> ~/.hammerspoon/init.lua <<EOF
-- Vox (local dictation) — bootguard loads Vox and rolls back broken updates
package.path = package.path .. ";" .. os.getenv("HOME") .. "/vox/?.lua"
require("bootguard")
EOF
fi
# ensure the hs CLI is linked even if cliInstall can't write its manpage
HS_BIN="/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"
[ -x "$HS_BIN" ] && ln -sf "$HS_BIN" "$BREW_PREFIX/bin/hs" 2>/dev/null || true

# Heal a damaged engine first (a broken signature revokes the permission
# grants and kills the hotkey — the classic "someone rebranded the bundle" bug)
if ! codesign --verify /Applications/Hammerspoon.app >/dev/null 2>&1; then
  echo "==> Engine app signature invalid — reinstalling the engine..."
  brew reinstall --cask hammerspoon
fi

echo "==> Compiling the screen-reader (for triple-tap smart replies)..."
if command -v swiftc >/dev/null 2>&1 && [ ! -x "$REPO/ocr-bin" ]; then
  swiftc -O "$REPO/ocr.swift" -o "$REPO/ocr-bin" 2>/dev/null \
    && echo "    ocr-bin ready ✅" \
    || echo "    (skipped — compiles itself on first triple-tap instead)"
fi

echo "==> [6/6] Applying Vox icon (once — re-branding can reset TCC grants on older macOS)..."
if [ -f "/Applications/Hammerspoon.app/Icon"$'\r' ]; then
  echo "    already branded — skipping (protects the Accessibility grant)"
elif command -v swift >/dev/null 2>&1 && swift "$REPO/brand.swift" /Applications/Hammerspoon.app 2>/dev/null; then
  touch /Applications/Hammerspoon.app 2>/dev/null || true
  killall Dock 2>/dev/null || true
  echo "    Vox alien icon applied ✅"
else
  echo "    (icon step skipped — non-fatal; the menu-bar alien still shows)"
fi

echo "==> Launching Vox..."
open -a Hammerspoon
sleep 3
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true

# --- Guided Accessibility grant: auto-detect + auto-relaunch --------
HS="$BREW_PREFIX/bin/hs"
hs_acc() { perl -e 'alarm 6; exec @ARGV' "$HS" -c "return tostring(hs.accessibilityState())" 2>/dev/null; }

cat <<'EOF'

============================================================
  ONE step macOS won't let a script do: grant ACCESSIBILITY
============================================================
I opened System Settings > Privacy & Security > Accessibility.
Enable **Hammerspoon** — that's Vox's engine (the alien icon).
I'll detect it and relaunch Vox
automatically — you do NOT need to relaunch by hand.
EOF

# Name the hold key by READING the config rather than hardcoding it. This line
# said "RIGHT OPTION" long after the default moved to Left Command (55), so new
# users granted both permissions, pressed the documented key, got nothing, and
# concluded Vox was broken. Derive it and it can never drift again.
hold_key_name() {
  local kc
  kc="$(sed -n 's/^[[:space:]]*holdKeycode[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
        "$REPO/vox.lua" 2>/dev/null | head -1)"
  case "$kc" in
    55) echo "LEFT COMMAND (⌘)"   ;;
    54) echo "RIGHT COMMAND (⌘)"  ;;
    61) echo "RIGHT OPTION (⌥)"   ;;
    58) echo "LEFT OPTION (⌥)"    ;;
    *)  echo "your hold key (see the menu-bar alien → Hold key)" ;;
  esac
}
HOLD_KEY="$(hold_key_name)"

echo
printf "Waiting for the Accessibility grant"
granted=0
for i in $(seq 1 40); do            # ~2 minutes, then give up gracefully
  if [ "$(hs_acc)" = "true" ]; then granted=1; break; fi
  printf "."
  sleep 3
done
echo

if [ "$granted" = 1 ]; then
  echo "✅ Accessibility granted — relaunching Vox so it takes effect..."
  killall Hammerspoon 2>/dev/null || true
  sleep 2
  open -a Hammerspoon
  sleep 3
  # Trigger the one-time MICROPHONE prompt now, while a human is watching,
  # instead of surprising them mid-first-dictation. Records 0.5s of nothing.
  echo "==> Triggering the Microphone permission prompt (click Allow)..."
  MIC_CMD="local t=hs.task.new(\"$BREW_PREFIX/bin/sox\",nil,{\"-q\",\"-d\",\"-c\",\"1\",\"-r\",\"16000\",\"/tmp/vox-micprompt.wav\",\"trim\",\"0\",\"0.5\"}); t:start()"
  "$HS" -c "$MIC_CMD" >/dev/null 2>&1 || true
  sleep 3
  rm -f /tmp/vox-micprompt.wav
  echo "✅ Vox is armed. HOLD $HOLD_KEY and speak. Release to paste."
else
  cat <<EOF
⏳ Didn't detect the grant yet — no problem. When you're ready:
   1. System Settings > Privacy & Security > Accessibility > enable Hammerspoon
   2. Relaunch:  killall Hammerspoon; open -a Hammerspoon
Then HOLD $HOLD_KEY and speak.
EOF
fi

echo
echo "==> Final health check (doctor)..."
bash "$REPO/doctor.sh" || true

cat <<EOF

Microphone: macOS prompts the first time you record. If it doesn't, enable
Hammerspoon under System Settings > Privacy & Security > Microphone.

The Vox menu-bar icon is the green alien. Enjoy.
EOF

# --- Background model downloads: say where they stand ---------------
if [ -f "$PULL_STAMP" ]; then
  case "$(cat "$PULL_STAMP")" in
    OK) echo "✅ AI models finished downloading — cleanup, translation and Q&A are live." ;;
    INCOMPLETE:*)
      echo "⚠️  Some AI models didn't finish: $(cut -d: -f2 <"$PULL_STAMP")"
      echo "    Dictation works. Retry anytime:  bash ~/vox/install.sh" ;;
  esac
else
  echo "⬇️  AI models are STILL DOWNLOADING in the background — that's fine."
  echo "    Dictation works right now. Cleanup/translation/Q&A switch on by themselves."
  echo "    Watch:  tail -f ~/vox/.ollama-pull.log"
fi
