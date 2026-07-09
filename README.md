# Vox — Local Dictation (Willow / Wispr Flow replacement)

Press-and-hold dictation that runs 100% on your Mac. No cloud, no subscription,
no surprise platform updates. You own every line of it.

## How it works

```
Hold Right ⌥  →  sox records mic  →  whisper-server transcribes (persistent
              local server, model held in RAM, Metal GPU)  →  pasted at your
              cursor. Optional: Ollama LLM cleanup pass (menubar toggle).
```

A little green alien lives in a pill at the bottom center of the screen —
he bobs, blinks, and his antenna sways while waveform bars dance on both
sides of him (cyan = listening, violet = thinking). The pill bounces in
and sinks away.

- **Hold Right Option (⌥)** — push-to-talk. Release = transcribe + paste.
- **Double-tap Right Option** — locks recording hands-free. Tap once more to stop.
  (A single stray tap is discarded quietly.)
- **Menu bar alien** — white = idle, coral = recording, violet = transcribing.
  Menu has toggles: hold key, music ducking, AI cleanup, translation, sound
  theme, language.
- **Music ducking** — playing audio fades to 35% while you dictate and ramps
  back the moment you release. Toggle in the menu.

## Install on a new Mac

```bash
git clone https://github.com/AutomateScaleInc/vox.git ~/vox
cd ~/vox && bash install.sh
```

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
| `holdKeycode` | Hotkey. 61 = Right ⌥ (default), 54 = Right ⌘ |
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

**Fresh install from scratch:**

```bash
rm -rf ~/vox
git clone https://github.com/AutomateScaleInc/vox.git ~/vox
cd ~/vox && bash install.sh
```
