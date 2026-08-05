#!/bin/bash
# Build (and optionally sign + notarize) the Vox disk image.
#
#   bash make-dmg.sh                 -> unsigned Vox.dmg, fine for testing
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=vox-notary \
#     bash make-dmg.sh               -> signed, notarized, stapled Vox.dmg
#
# WHY A DMG AND NOT A .PKG: a .pkg postinstall runs as root, and Homebrew
# flatly refuses to run as root. The install genuinely has to execute as the
# logged-in user, so the native-feeling path is a disk image the user opens
# and double-clicks. Same reason we don't ship a .app: there is no app here,
# only a bootstrap that hands off to install.sh.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$REPO/dist"
STAGE="$DIST/stage"
DMG="$DIST/Vox.dmg"
VOLNAME="Install Vox"

rm -rf "$DIST"
mkdir -p "$STAGE"

# --- contents ------------------------------------------------------
cp "$REPO/Install Vox.command" "$STAGE/Install Vox.command"
chmod +x "$STAGE/Install Vox.command"

cat > "$STAGE/README.txt" <<'TXT'
Vox — local AI dictation for Mac

1. Double-click "Install Vox".
2. If macOS says the developer can't be verified:
   right-click "Install Vox" -> Open -> Open. (One time only.)
3. Sit back. It installs everything and asks for two macOS
   permissions near the end (Accessibility + Microphone).

Dictation works within a couple of minutes. The larger AI models
keep downloading in the background and switch themselves on.

Docs: https://automatescale.com/vox-docs
TXT

# --- build ---------------------------------------------------------
echo "==> Building $DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null
echo "    built: $(du -h "$DMG" | cut -f1)"

# --- sign + notarize (optional) ------------------------------------
# Without a Developer ID these steps are skipped and the DMG still works —
# users just get the one-time right-click -> Open dance documented above.
if [ -z "${DEVELOPER_ID:-}" ]; then
  cat <<'EOF'

⚠️  UNSIGNED build — no DEVELOPER_ID set.
    Users will see "unidentified developer" and must right-click -> Open.
    To ship a clean double-click experience you need:
      1. Apple Developer Program membership ($99/yr)
      2. A "Developer ID Application" certificate in this Mac's keychain
      3. A stored notary profile:
           xcrun notarytool store-credentials vox-notary \
             --apple-id <you@apple.id> --team-id <TEAMID> \
             --password <app-specific-password>
    Then re-run:
      DEVELOPER_ID="Developer ID Application: NAME (TEAMID)" \
      NOTARY_PROFILE=vox-notary bash make-dmg.sh
EOF
  exit 0
fi

echo "==> Signing the bootstrap script..."
codesign --force --timestamp --options runtime \
  --sign "$DEVELOPER_ID" "$STAGE/Install Vox.command"

# Re-build so the image carries the SIGNED script, not the unsigned copy.
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

echo "==> Signing the disk image..."
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

if [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "⚠️  Signed but NOT notarized (no NOTARY_PROFILE). Gatekeeper will still warn."
  exit 0
fi

echo "==> Submitting to Apple for notarization (this takes a few minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the ticket..."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "✅ Notarized and stapled: $DMG"
echo "   Verify a clean machine's view with:  spctl -a -t open --context context:primary-signature -v \"$DMG\""
