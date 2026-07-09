#!/bin/bash
# Vox installer — run this from the ~/vox folder on any Mac.
# Copy the whole ~/vox folder to the new Mac first (AirDrop / iCloud / git),
# then:  cd ~/vox && bash install.sh
set -e

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

# install with one retry after brew update (stale cask/formula index)
binstall() {
  brew list "$@" >/dev/null 2>&1 && return 0
  brew install "$@" && return 0
  echo "==> '$*' failed — updating Homebrew and retrying once..."
  brew update
  brew install "$@"
}

echo "==> Installing dependencies (Homebrew)..."
binstall --cask hammerspoon
binstall whisper-cpp
binstall sox
binstall ollama

echo "==> Downloading Whisper model (~575MB, skipped if present)..."
mkdir -p ~/vox/models
MODEL=~/vox/models/ggml-large-v3-turbo-q5_0.bin
if [ ! -f "$MODEL" ]; then
  curl -L -o "$MODEL" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
fi

echo "==> Starting Ollama and pulling cleanup model (~2GB, skipped if present)..."
brew services start ollama
sleep 5
ollama pull llama3.2:3b

echo "==> Generating fallback UI sounds (themes normally ship in the folder)..."
mkdir -p ~/vox/sounds/classic
if [ ! -f ~/vox/sounds/classic/start.wav ]; then
  sox -n -r 44100 ~/vox/sounds/classic/start.wav synth 0.12 sine 500-900 fade h 0.01 0.12 0.06 gain -18
  sox -n -r 44100 ~/vox/sounds/classic/stop.wav  synth 0.12 sine 900-550 fade h 0.01 0.12 0.06 gain -18
  sox -n -r 44100 ~/vox/sounds/classic/done.wav  synth 0.05 sine 1250   fade h 0.005 0.05 0.03 gain -20
fi

echo "==> Wiring up Hammerspoon config..."
mkdir -p ~/.hammerspoon
if ! grep -q 'require("vox")' ~/.hammerspoon/init.lua 2>/dev/null; then
  cat >> ~/.hammerspoon/init.lua <<'EOF'
-- Vox (local dictation)
require("hs.ipc"); pcall(hs.ipc.cliInstall, "/opt/homebrew")  -- enables `hs -c` CLI for diagnostics
package.path = package.path .. ";" .. os.getenv("HOME") .. "/vox/?.lua"
require("vox")
EOF
fi

echo "==> Launching Hammerspoon..."
open -a Hammerspoon
sleep 2

# Open the Accessibility pane directly — this grant cannot be scripted (Apple TCC),
# and WITHOUT IT THE HOTKEY DOES NOTHING. This is the #1 "Vox isn't working" cause.
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true

cat <<'EOF'

============================================================
  DONE — but ONE manual step remains that no script can do.
============================================================

macOS blocks scripts from granting these two permissions
(Apple TCC — a human must flip them). Do them now:

  1. ACCESSIBILITY  <-- REQUIRED, or the hotkey is dead silent
     I just opened: System Settings > Privacy & Security >
     Accessibility.  Enable **Hammerspoon** (toggle off/on if
     already listed).

     THEN RELAUNCH HAMMERSPOON so the grant actually takes:
         killall Hammerspoon; open -a Hammerspoon
     (A running app usually ignores the grant until relaunched —
      this is the step everyone misses.)

  2. MICROPHONE     — macOS prompts the first time you record.
     If it doesn't: same pane, Microphone > enable Hammerspoon.

Then: HOLD RIGHT OPTION (⌥) and speak. Release to transcribe + paste.
Quick-tap Right Option to lock hands-free recording; tap again to stop.

If the hotkey does nothing, it is ALWAYS step 1 (grant + relaunch).
Verify with:  bash ~/vox/doctor.sh
EOF
