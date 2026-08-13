#!/bin/sh
# Vox pre-push validation gate — born from the 2026-08-13 merge incident:
# a merge left duplicate-line artifacts, a follow-up "fix" made the file
# PARSE while one function silently swallowed 3,500 lines. Parse-clean is
# not load-clean; this gate catches the whole class before it reaches main
# (vox auto-update hard-resets every fleet Mac to origin/main).
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/vox")" || exit 1
fail() { echo "❌ VOX VALIDATE FAILED: $1" >&2; exit 1; }

# 1. Lua must parse
command -v luac >/dev/null && { luac -p vox.lua || fail "vox.lua does not parse (luac)"; }

# 2. no leftover conflict markers
grep -nE '^(<<<<<<< |======$|>>>>>>> )' vox.lua cam.swift bootguard.lua 2>/dev/null \
  && fail "merge conflict markers present"

# 3. adjacent duplicate lines = classic bad-merge artifact
awk '{ line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
       if (line == prev && length(line) > 16 && line !~ /^(--|end|else|\}|\))/ )
         { print FILENAME ":" NR ": duplicated: " line; found=1 }
       prev=line }
     END { exit found }' vox.lua || fail "adjacent duplicate lines (merge artifact?)"

# 4. Swift must parse (syntax-only, fast; full compile happens on deploy)
command -v swiftc >/dev/null && { swiftc -parse cam.swift 2>/dev/null || fail "cam.swift does not parse"; }

# 5. the settings HTML string.format placeholder/arg contract
command -v python3 >/dev/null && { python3 ci/check-settings-format.py || fail "settings string.format placeholders != args"; }

echo "✅ vox validate passed"
