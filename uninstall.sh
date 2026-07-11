#!/bin/bash
# Vox uninstaller — cleanly removes Vox from this Mac.
#
#   bash ~/vox/uninstall.sh            asks first
#   bash uninstall.sh --yes            no questions (CLI/agents)
#   bash uninstall.sh --yes --purge    also remove Homebrew deps
#                                      (Hammerspoon, whisper-cpp, sox, ollama)
#
# Works even if ~/vox is broken or already gone:
#   curl -fsSL https://raw.githubusercontent.com/AutomateScaleInc/vox/main/uninstall.sh | bash -s -- --yes
set -u

YES=0; PURGE=0
for a in "$@"; do case $a in --yes) YES=1;; --purge) PURGE=1;; esac; done

if [ $YES -eq 0 ]; then
  read -r -p "Remove Vox from this Mac? [y/N] " ans
  case "$ans" in y|Y|yes) ;; *) echo "aborted"; exit 1;; esac
fi

echo "==> Stopping Vox processes..."
pkill -f "whisper-serve[r]" 2>/dev/null
pkill -f "sox.*vox-recording" 2>/dev/null

echo "==> Unwiring Hammerspoon config..."
INIT="$HOME/.hammerspoon/init.lua"
if [ -f "$INIT" ]; then
  sed -i '' \
    -e '/-- Vox (local dictation)/d' \
    -e '/hs\.ipc\.cliInstall/d' \
    -e '\|/vox/?\.lua|d' \
    -e '/require("vox")/d' \
    "$INIT"
  grep -q '[^[:space:]]' "$INIT" || rm -f "$INIT"
fi

if [ -f "$HOME/vox/local.lua" ]; then
  cp "$HOME/vox/local.lua" "$HOME/vox-local.lua.bak"
  echo "==> Personal vocabulary saved to ~/vox-local.lua.bak"
fi
if [ -d "$HOME/vox/memory" ]; then
  cp -R "$HOME/vox/memory" "$HOME/vox-memory.bak"
  echo "==> Alien memory saved to ~/vox-memory.bak"
fi
if [ -f "$HOME/vox/learned.json" ]; then
  cp "$HOME/vox/learned.json" "$HOME/vox-learned.json.bak"
  echo "==> Learned vocabulary saved to ~/vox-learned.json.bak"
fi

echo "==> Removing ~/vox..."
rm -rf "$HOME/vox"

killall Hammerspoon 2>/dev/null || true

if [ $PURGE -eq 1 ]; then
  echo "==> Purging Homebrew packages..."
  brew services stop ollama 2>/dev/null
  brew uninstall --cask hammerspoon 2>/dev/null
  brew uninstall whisper-cpp sox ollama 2>/dev/null
  rm -f /opt/homebrew/bin/hs /usr/local/bin/hs
else
  # relaunch Hammerspoon without Vox (other configs keep working)
  [ -d /Applications/Hammerspoon.app ] && [ -f "$INIT" ] && open -a Hammerspoon
fi

echo
echo "DONE — Vox removed."
echo "Reinstall anytime:"
echo "  git clone https://github.com/AutomateScaleInc/vox.git ~/vox && cd ~/vox && bash install.sh"
echo "  restore personal vocab after: mv ~/vox-local.lua.bak ~/vox/local.lua"
