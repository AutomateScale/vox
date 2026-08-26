# Building on Vox — read this before your first commit

You're working on LIVE infrastructure: Adam dictates through HEAD of this repo
all day on Archon, and **auto-update hard-resets every fleet Mac to
`origin/main` within ~6 hours**. Broken main = fleet-wide outage. Act like it.

## The gate (non-negotiable)
- `ci/validate.sh` runs on every push via the versioned pre-push hook
  (self-installed by vox.lua boot). **Never `--no-verify`.**
- **Parse-clean is NOT load-clean.** A 2026-08 merge left duplicate lines; a
  "fix" made it parse while one function silently swallowed 3,500 lines. After
  any conflicted merge: `sh ci/validate.sh` **and** boot once (`hs.reload`,
  watch the console for errors) before pushing.
- Ship to **main only** — side branches get wiped by the auto-updater's reset.
- Announce big merges on the fleet stream BEFORE pushing; other agents and
  terminals work this repo in parallel.

## vox.lua landmines
- **200-local limit**: the main chunk is at Lua's cap. New top-level
  definitions must be **globals** with a `-- global: 200-local limit` comment.
- **Anchor every timer** in the `timers` table. Anonymous `hs.timer.doAfter`
  gets GC'd — this once caused five zombie sox recorders.
- **Settings window** is ONE giant `string.format`: every `%s` must line up
  positionally with its arg. validate checks the count; YOU keep the order.
- **Duplicate positioners exist.** Before adding placement/movement behavior,
  grep for ALL setters first (`w = MW`, `:frame(`). The alien had TWO
  window-follow positioners; patching one and not the other cost hours.
  User pin `vox.pref.miniAlienPin` outranks every auto-positioner.
- **whisper-server heals itself** (wedge-kill on double self-test failure).
  Don't add parallel supervision. Recurring jobs go in the fleet
  `fleet_schedules` table (pg_cron spine), never new launchd/cron on a node.
- `.vox-lkg` (bootguard rollback target) only advances on a CLEAN tree —
  don't leave test artifacts in the repo.

## cam.swift landmines
- **Committing cam.swift does nothing until compiled**:
  `swiftc -O cam.swift -o cam-bin` — on every machine that runs it.
- `logMsg` writes to **stderr** (vox.lua's stream callback reads both).
- `trackedBodyRect` is **normalized 0-1 with a flipped Y axis** — map it like
  the bust-dissolve does. Feeding it raw puts things in a corner of nowhere.
- Sticky matte (mic anti-blink) accumulates residue BY DESIGN — anything that
  needs *position* must read the RAW mask, never the smoothed one.
- Motion smoothing: use critically-damped springs, never deadbands
  (deadband = stick-slip = "stiff AND twitchy").
- Canon's EOS virtual camera lies: accepts the 1080 preset, delivers 720
  frames, and wedges (frame-freeze watchdogs exit(3) → vox.lua recycles it).
  The Cam Link path is the honest one.
- Single-instance guard: a second cam-bin makes BOTH suicide. Restarts are
  serialized in vox.lua (`showWebcamOverlay`) — use it, don't pkill+spawn.

## Verifying like you mean it
- Boot check: `hs -c "print(type(panicReset))"` → `function` means loaded.
- Dictation check: the pipeline self-test logs PASSED/FAILED in the console.
- The console is the flight recorder: settings clicks, cam preset/dimensions,
  alien pin moves are all logged. Read it before theorizing.
- When a user report contradicts your model, instrument first (tripwire logs),
  patch second. Three "obvious" fixes for the alien-pin bug were wrong; the
  logged evidence found the real one in minutes.
