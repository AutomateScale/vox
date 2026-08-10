# Vox — Local Dictation (Willow / Wispr Flow replacement)

**Built by [AutomateScale](https://automatescale.com)** — AI automation &
agent systems. Vox home: **[automatescale.com/vox](https://automatescale.com/vox)**

Press-and-hold dictation that runs 100% on your Mac. No cloud, no subscription,
no surprise platform updates. You own every line of it.

## vs. the subscription apps

|  | **Vox** | Wispr Flow | Willow Voice | Aqua Voice |
|---|---|---|---|---|
| Price | **Free, forever** | $15/mo (free: 2k words/wk) | $15/mo | $8/mo |
| Your voice goes | **Nowhere — 100% local** | Their cloud | Their cloud | Their cloud |
| Open source | **MIT** | No | No | No |
| Hands-free conversation loop | **Yes** — talk, auto-send, bell, repeat | No | No | No |
| Live word-by-word w/ revisions | **Yes** | No | No | Real-time display |
| Personal memory + knowledge graph | **Yes, local, browsable** | No | Style memory | Custom dictionary |
| Voice actions (apps, screenshots…) | **Yes, deterministic** | Text edits only | No | No |
| Works offline | **Yes** | No | No | No |
| **Voom**: screen recording + AI presenter cutout | **Yes — built in, free** | No | No | No |
| Platforms | macOS | Mac/Win/iOS/Android | Mac/Win | Mac/Win |

*Competitor pricing/features as of August 2026 from public pages — tell us if
they've changed; an honest comparison is the only useful kind.*

**Voom** (⌥⇧R or just say *"Voom"*) also covers what [Loom](https://www.loom.com)
charges $15–18/user/mo for — screen recording with voice narration — plus the
transparent AI person-cutout overlay that is mmhmm's flagship feature. Local,
instant MP4s, no upload, no seat license.

## How it works

```
Hold Left ⌘   →  sox records mic  →  whisper-server transcribes (persistent
              local server, model held in RAM, Metal GPU)  →  pasted at your
              cursor. Optional: Ollama LLM cleanup pass (menubar toggle).
```

A little green alien lives in a pill at the bottom center of the screen —
he bobs, blinks, and his antenna sways while waveform bars dance on both
sides of him (cyan = listening, violet = thinking). The pill bounces in
and sinks away.

- **Hold Right Option (⌥)** (or Left Command) — push-to-talk. Release = transcribe + paste (~1.0s).
- **Press Fn + Option** — **Hands-Free Conversation Mode**: toggle once and just
  talk. Every natural pause pastes automatically and the mic keeps listening —
  no keys, ever. Say *"send"* / *"ok send"* / *"ok go"* and Vox submits, watches
  the reply render, and rings a bell 🔔 the moment it's verified listening again.
  The mic stays hot while the LLM thinks. Optional **alien play-by-play**
  narrates the loop ("Boom. Sent. Go stretch or something.").
- **Live word-by-word typing** (experimental, menubar toggle) — words appear
  ~1s behind your voice and get *revised in place* as Whisper refines them
  with context — iPhone-dictation feel, in any app. Text stabilizes
  left-to-right while you keep talking.
- **The deep sweep** — on "send", the whole paragraph gets one more pass:
  artifacts stripped, false starts collapsed, then a local LLM fixes obvious
  mishears from context ("deep-sea sweep" → "deep sweep") under strict
  never-rephrase guards. Self-healing capture underneath: continuous-stream
  recording, byte-level stall detection, zombie reaping, engine wake-and-retry
  on every chunk.
- **Hold ⌘ + tap Left Shift (⇧)** — ask mode: your words become a question
  and the alien answers on screen AND out loud (voice pickable in the menu).
- **Triple-tap** — smart reply: reads the window on screen, drafts the response.
- **Right Option (⌥) + hold** — expand mode: speak a rough idea, get polished content.
- **"Hey Vox, …"** — ask a question; the alien answers from its local memory.
- **Press Option + Shift + R (⌥⇧R)** — **Voom (Screen & Presenter Recording)**:
  instantly records your screen and voice with zero-background transparent person cutout overlay, live circular webcam bubble, on-screen recording HUD (timer, alien cheer 👽, stop, cancel), hardware-accelerated MP4 output saved to `~/Movies/VoxRecordings/`, auto-copying file path to clipboard, and one-click notification play. Also triggerable by voice: *"Voom"* / *"stop Voom"*.
- **Voice actions** — "Hey Vox, open Safari" / "close Slack" / "switch to
  Chrome" / "minimize" / "press command W" / "volume up" / "take a
  screenshot" / "Voom" / "lock the screen". Works in ask mode too (⌘+⇧). Deterministic
  parser, no LLM — actions fire instantly and never hallucinate.
- **Voice commands** — "scratch that" undoes; "new paragraph." / "new line." break.
- **Tiny idle alien** — click = dictate hands-free, C = speak-to-content,
  P = absorb the screen into your knowledge base.
- **The brain** — every dictation remembered locally, auto-linked into a
  browsable wiki, feeding Whisper's vocabulary and all AI features.
  Export/merge between Macs: `python3 ~/vox/mem.py export`.
- **Make replies sound like you** — `cp identity.example.md identity.md` and
  describe yourself; Vox writes smart replies and content in your voice.
- **Semantic memory** — recall by *meaning*, not just keywords: "the hospital
  in Brussels" finds a memory that only says "Jules Bordet". Local embedding
  model (nomic-embed-text via Ollama); word-match is the automatic fallback,
  so recall never degrades. Backfill old memories: `python3 ~/vox/mem.py embed`.
- **Double-tap the hold key (Left ⌘)** — locks recording hands-free. Tap once more to stop.
  (A single stray tap is discarded quietly.)
- **Voice vignette** — the border of the screen you're dictating on glows and
  BREATHES with your voice: silence = a faint ring (the mic is live), speech =
  the ring blooms with every word. A second ring hugs the exact WINDOW your
  words will land in. Violet slow-breathing = transcribing; everything fades
  the moment your words paste. Pure feedback, fully click-through. Tune in
  local.lua: `vignette = false`, `vignetteWindow = false`, `vignetteColor`.
- **Alien position** — menu → "Alien position": the recording alien pops out
  of the window you're dictating into (default), and/or bottom center, top
  center, right edge — any combo at once, remembered across restarts.
- **Menu bar alien** — white = idle, coral = recording, violet = transcribing.
  Menu has toggles: hold key, music ducking, AI cleanup, translation, sound
  theme, language.
- **Music ducking** — playing audio fades to 35% while you dictate and ramps
  back the moment you release. Toggle in the menu.

## Conversation Mode: Built for Vibe Coding

Vibe coding is pairing with AI assistants (Antigravity, Cursor, Claude Code, Windsurf) at the speed of thought. **Hands-Free Conversation Mode (`Fn + Option`)** transforms your Mac into a voice-driven coding cockpit:

1. **Uninterrupted Flow**: Toggle Conversation Mode once (`Fn + Option`) and talk naturally. Vox captures your voice and automatically pastes text into your prompt window during speech pauses—no holding keys.
2. **Hands-Free Prompt Dispatch**: Say **`"send"`**, **`"ok send"`**, or **`"ok go"`** to automatically submit your prompt to the AI agent.
3. **The Hot-Mic Loop & Audio Bell 🔔**:
   - The microphone stays hot while the AI agent generates code or runs shell commands.
   - The moment your AI assistant finishes its turn, Vox plays a clear audio bell 🔔 to let you know it's ready for your next instruction.
   - Review code diffs and dictate your next feature request without touching the keyboard.
4. **Context-Aware Deep Sweep & Local Memory**: On dispatch, Vox runs a deep-sweep cleanup pass that collapses stutters, strips false starts, and enforces exact technical spelling (`Supabase`, `GHL`, `RAG`, `Tailwind`, `TypeScript`, `Next.js`) via your local dictionary (`local.lua`).

## Using Antigravity, Cursor, or Claude Code?

Just tell your AI coding assistant:

```
install Vox from automatescale.com/vox
```

It runs the install and walks you through the permissions.

## Install on a new Mac — one line

```bash
curl -fsSL https://automatescale.com/vox/install | bash
```

Bootstraps git/Homebrew if missing, clones or updates the repo, runs the full
installer, auto-detects your Accessibility grant, and triggers the Microphone
prompt. Safe to re-run anytime. Manual equivalent:

```bash
git clone https://github.com/AutomateScale/vox.git ~/vox
cd ~/vox && bash install.sh
```

Once installed, **Vox keeps itself updated** — it fast-forwards to the latest
`main` on launch and every 6 hours (menu: "Check for updates now").

(The Whisper model isn't in the repo — install.sh downloads it.)

## Personal vocabulary (private)

Copy `local.example.lua` to `local.lua` and add your names, brands, and
jargon. `local.lua` is gitignored — your personal terms never leave your
machine. Any config key from `vox.lua` can be overridden there (hotkey,
language, ducking level, ...). Sync it between your own Macs by hand or
iCloud, not through the repo.

Grant the two permissions when macOS prompts (Accessibility + Microphone for
Hammerspoon). That's it.

## Tuning (edit the CONFIG block at the top of `vox.lua`)

| Setting | What it does |
|---|---|
| `holdKeycode` | Hotkey. 55 = Left ⌘ (default), 61 = Right ⌥, 54 = Right ⌘ |
| `language` | `"en"` (default, fastest), `"fr"` for French dictation, `"auto"` (+1s). Also switchable from the menubar |
| `translateTo` | `"off"` (default, fastest), `"English"`, `"French"`, `"Spanish"`, or `"Dutch"`. Also switchable from the menubar |
| `vocabulary` | Words Whisper must spell correctly. Add client names, jargon. |
| `corrections` | Deterministic post-fixes ("super base" → "Supabase"). Add your own as Whisper surprises you. |
| `soundTheme` | `"sleek"` (glide + reverb) or `"classic"` (simple sweeps). Also in menubar. |
| `llmCleanup` | Default `false` (fast, faithful). `true` adds a context-aware LLM rewrite pass (~2s extra, may lightly reword) |
| `ollamaModel` | Swap for a bigger model (e.g. `qwen2.5:7b`) if you want smarter cleanup |

After editing: click the Hammerspoon menu bar icon → **Reload Config**.

## Latency (M4, measured)

- Whisper large-v3-turbo via persistent server, language pinned: ~1s per
  utterance (even 20s+ clips — auto-detect used to cost an extra ~1s pass)
- Brand-name corrections dictionary: 0ms (deterministic find/replace)
- Total: **~1.5s from key-release to pasted text** (LLM cleanup off)
- With LLM cleanup toggled on: add ~1.5–3s
- With translation toggled on: add the local Ollama pass (~1.5–3s on a warm
  model). Normal dictation stays on the fast path.

## Files

- `vox.lua` — the entire app (one file, ~250 lines of Lua)
- `models/ggml-large-v3-turbo-q5_0.bin` — Whisper model (575MB)
- `install.sh` — one-command setup for new Macs
- `~/.hammerspoon/init.lua` — just loads `vox.lua`

## Troubleshooting

- **Nothing pastes** → check Accessibility permission for Hammerspoon.
- **"transcription failed"** → open log (menu bar → Open log console).
- **Cleanup weird/slow** → toggle "LLM cleanup" off in the menu; raw Whisper is already very good.
- **Ollama down** → Vox auto-falls back to raw transcript after 10s. Restart with `brew services restart ollama`.

## Troubleshooting

**It stopped loading after an update** — hard-reset to the latest clean release:

```bash
cd ~/vox && git fetch origin && git reset --hard origin/main
killall Hammerspoon; open -a Hammerspoon
```

(Your `local.lua` and downloaded models are untracked — a hard reset never touches them.)

**Hotkey does nothing (app looks fine)** — Accessibility isn't granted.
System Settings → Privacy & Security → Accessibility → enable **Hammerspoon**
(toggle off/on if already enabled). Vox picks the key up within ~15 seconds
of the grant — no restart needed.

**See the actual error** — click the Hammerspoon menubar icon → Console, or:

```bash
open -a Hammerspoon   # if it isn't running
```

The console shows `[vox]` log lines and any load errors in red.

**Transcripts are empty or garbage** — your mic level is too low. Check the
input device and its volume in System Settings → Sound → Input, and speak
closer. Vox normalizes quiet audio, but it can't fix silence.

**Anything else — run the doctor:**

```bash
bash ~/vox/doctor.sh
```

It checks dependencies, model, the whole transcription pipeline, mic signal
level, and permissions, and tells you what's wrong in plain language.

**Fresh install from scratch:**

```bash
rm -rf ~/vox
git clone https://github.com/AutomateScale/vox.git ~/vox
cd ~/vox && bash install.sh
```

## Uninstall

```bash
bash ~/vox/uninstall.sh
```

Or from anywhere (even if ~/vox is broken), no questions asked:

```bash
cd ~
curl -fsSL https://raw.githubusercontent.com/AutomateScale/vox/main/uninstall.sh | bash -s -- --yes
```

(The `cd ~` matters: if your terminal is inside ~/vox when it gets deleted,
every next command fails with "no such file or directory".)

Backs up your `local.lua` to `~/vox-local.lua.bak`, unwires Hammerspoon
(preserving any non-Vox config), and removes `~/vox`. Add `--purge` to also
remove the Homebrew packages.

Full copy-ready command reference: https://automatescale.com/vox-docs

## Old or slow Macs

Two options, automatic first:

1. **Lighter model (automatic)** — Intel Macs get Whisper `small` (~180MB)
   instead of the 575MB large model. Slower and slightly less accurate than
   Apple Silicon, but usable.
2. **Remote transcription (recommended for really old machines)** — let a fast
   Mac on your LAN do the thinking. On the fast Mac's `local.lua`:
   `serverBind = "0.0.0.0"`. On the old Mac's `local.lua`:
   `whisperHost = "<fast Mac's LAN IP>"`. The old Mac records (cheap) and the
   M-series Mac transcribes in ~1s. LAN-only — nothing leaves your network.
