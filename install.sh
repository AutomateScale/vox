#!/bin/bash
# Vox installer — drop-in setup for a new Mac.
#   git clone https://github.com/AutomateScaleInc/vox.git ~/vox
#   cd ~/vox && bash install.sh
set -e

REPO="$HOME/vox"
# Hardware-aware model: Apple Silicon flies with large-v3-turbo on the GPU;
# Intel Macs get `small` (5x lighter — the large model crawls on old CPUs).
if [ "$(uname -m)" = "arm64" ]; then
  MODEL_FILE="ggml-large-v3-turbo-q5_0.bin"
  MODEL_SHA="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
else
  MODEL_FILE="ggml-small-q5_1.bin"
  MODEL_SHA="ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
  echo "==> Intel Mac detected — using the lighter Whisper model (~180MB)."
  echo "    Tip: genuinely old Mac? Point it at a fast Mac instead — see"
  echo "    'Remote transcription' in the README."
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
brew services start ollama >/dev/null 2>&1 || true
sleep 5
if ! ollama pull llama3.2:3b; then
  echo "    ⚠️  Ollama pull failed (network?). Basic dictation still works; LLM cleanup /"
  echo "        translation stay off until you run:  ollama pull llama3.2:3b"
fi
# smart model for translation/content/complex replies — only on Macs with RAM to spare
if [ "$(sysctl -n hw.memsize)" -ge 12884901888 ]; then
  echo "    pulling the smart model (~4.7GB) for translation + content work..."
  ollama pull qwen2.5:7b || echo "    (skipped — Vox stays on the fast model until you: ollama pull qwen2.5:7b)"
else
  echo "    <12GB RAM — staying on the fast model only (right call for this Mac)"
fi

echo "==> [4/6] Fallback UI sounds..."
mkdir -p "$REPO/sounds/classic"
if [ ! -f "$REPO/sounds/classic/start.wav" ]; then
  sox -n -r 44100 "$REPO/sounds/classic/start.wav" synth 0.12 sine 500-900 fade h 0.01 0.12 0.06 gain -18
  sox -n -r 44100 "$REPO/sounds/classic/stop.wav"  synth 0.12 sine 900-550 fade h 0.01 0.12 0.06 gain -18
  sox -n -r 44100 "$REPO/sounds/classic/done.wav"  synth 0.05 sine 1250   fade h 0.005 0.05 0.03 gain -20
fi

echo "==> [5/6] Wiring the Vox engine config + hs CLI..."
mkdir -p ~/.hammerspoon
if ! grep -q 'require("vox")' ~/.hammerspoon/init.lua 2>/dev/null; then
  cat >> ~/.hammerspoon/init.lua <<EOF
-- Vox (local dictation)
require("hs.ipc"); pcall(hs.ipc.cliInstall, "$BREW_PREFIX")  -- enables \`hs -c\` CLI for diagnostics
package.path = package.path .. ";" .. os.getenv("HOME") .. "/vox/?.lua"
require("vox")
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

echo "==> [6/6] Applying Vox icon (safe: metadata only, never re-signs the app)..."
if command -v swift >/dev/null 2>&1 && swift "$REPO/brand.swift" /Applications/Hammerspoon.app 2>/dev/null; then
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
  echo "✅ Vox is armed. HOLD RIGHT OPTION (⌥) and speak. Release to paste."
else
  cat <<'EOF'
⏳ Didn't detect the grant yet — no problem. When you're ready:
   1. System Settings > Privacy & Security > Accessibility > enable Hammerspoon
   2. Relaunch:  killall Hammerspoon; open -a Hammerspoon
Then HOLD RIGHT OPTION (⌥) and speak.
EOF
fi

echo
echo "==> Final health check (doctor)..."
bash "$REPO/doctor.sh" || true

cat <<'EOF'

Microphone: macOS prompts the first time you record. If it doesn't, enable
Hammerspoon under System Settings > Privacy & Security > Microphone.

The Vox menu-bar icon is the green alien. Enjoy.
EOF
