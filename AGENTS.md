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
- **cam-bin rebuilds itself** when cam.swift is newer than the binary
  (async, ~5s, on the next presenter launch — `showWebcamOverlay`). To
  test a change by hand: `swiftc -O cam.swift -o cam-bin`.
- **ONE launch animation.** `startEmergeTween` is a manual 60Hz tween
  that sets the window frame directly. Never add an NSWindow `animator()`
  / `NSAnimationContext` frame animation on the presenter window: three
  overlapping ones snapped it back to a 30x30 box at the alien and it
  stayed there ("very small camera", 2026-09). The window is created at
  its FINAL rect for the same reason.
- **Canon process names (Archon, EOS Webcam Utility 2.x):** the feed
  process is `EOSWebcamService`; the "Pro Helper"/EWCProxy names are a
  legacy build. **Do not bounce it.** `pkill EOSWebcamService` is the
  session-close that knocks the M50 off Archon's USB hub (gone in ~3s,
  needs a power-cycle). `cam-keepalive` holds the virtual-camera session
  as a fallback; `eos-bin` (libgphoto2 PTP, `eos.c`) is the replacement
  path and never opens "EOS Webcam Utility". Canon's camera extension
  exclusive-owns USB via DriverKit while it is enabled (`gp_camera_init`
  returns -53). Disable it in System Settings → Camera Extensions;
  `/tmp/vox-eos.ready` going live auto-switches the presenter. The
  utility's "camera disconnected" splash is a real image at 60 fps:
  `checkStaticFrame` reports `FEED_STATIC` — a camera that is switched
  off cannot be fixed by restarting anything. `system_profiler` never
  lists "Canon".
- **Both cameras are fixed-rate formats** (Cam Link 4K 50 fps, EOS 60 fps);
  the 30 fps cap is software in `captureOutput`. Don't remove it — the
  full pipeline at 60 fps was ~50% of a core plus WindowServer.
- `logMsg` writes to **stderr** (vox.lua's stream callback reads both).
- `trackedBodyRect` is **normalized 0-1 with a flipped Y axis** — map it like
  the bust-dissolve does. Feeding it raw puts things in a corner of nowhere.
- Sticky matte (mic anti-blink) accumulates residue BY DESIGN — anything that
  needs *position* must read the RAW mask, never the smoothed one.
- Motion smoothing: use critically-damped springs, never deadbands
  (deadband = stick-slip = "stiff AND twitchy").
- Canon's EOS virtual camera lies: accepts the 1080 preset, delivers 720
  frames, and wedges. `cam.swift` now forces 720p on that device. Prefer
  **Cam Link (HDMI)** when it has a picture, then **Canon EOS (PTP)**
  once `eos-bin` is ready, never the utility. Freeze recovery restarts
  cam-bin only — it must not bounce Canon helpers.
- Single-instance guard: a second cam-bin makes BOTH suicide. Restarts are
  serialized in vox.lua (`showWebcamOverlay`) — use it, don't pkill+spawn.

## Never kill an `hs -c` client mid-call
- `hs -c` run under a timeout that kills the client (`perl -e 'alarm..'`,
  `timeout`, Ctrl-C) **crashes Hammerspoon**: hs.ipc replies into the
  dead client's message port and faults in `CFMessagePortSendRequest`
  (crash report 2026-09-04 15:49, EXC_BREAKPOINT in libipc.dylib). Before
  that it floods the console with "already recursing, refusing request"
  at thousands of lines/second. Stale `hs -c` processes from dead agent
  shells do the same — `pkill -f '^hs -c'` them, never leave them.
- Read state through the pulse API instead when you can:
  `curl -H "Host: localhost" http://127.0.0.1:8091/status`.
- cam-keepalive is spawned DETACHED (nohup) for exactly this reason: an
  hs.task child dies with Hammerspoon, and so does the Canon session.

## Verifying like you mean it
- Boot check: `hs -c "print(type(panicReset))"` → `function` means loaded.
- Dictation check: the pipeline self-test logs PASSED/FAILED in the console.
- The console is the flight recorder: settings clicks, cam preset/dimensions,
  alien pin moves are all logged. Read it before theorizing.
- When a user report contradicts your model, instrument first (tripwire logs),
  patch second. Three "obvious" fixes for the alien-pin bug were wrong; the
  logged evidence found the real one in minutes.
