#!/bin/bash
# Double-click me in Finder. Terminal opens and installs Vox — no typing.
# (If macOS says "unidentified developer": right-click me → Open → Open.)
cd "$HOME" || exit 1
clear
cat <<'BANNER'

   👽  Installing Vox — local AI dictation for your Mac
   ───────────────────────────────────────────────────
   Sit back. This handles everything and asks for two
   macOS permissions near the end. ~5 minutes.

BANNER
curl -fsSL https://automatescale.com/vox/install | bash
echo
echo "Done. You can close this window."
