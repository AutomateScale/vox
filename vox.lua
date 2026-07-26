-- ============================================================
-- VOX — local push-to-talk dictation (Willow/Wispr replacement)
-- Hold RIGHT OPTION (⌥) and speak. Release to transcribe + paste.
-- Quick-tap Right Option to LOCK recording (hands-free); tap again to stop.
--
-- Pipeline: sox (mic) -> whisper-server (persistent, model in RAM, Metal)
--           -> Ollama (local LLM cleanup, screen-context aware) -> paste
-- Everything runs on-device. No cloud. No subscription.
-- ============================================================

local M = {}

-- Enable the `hs` command-line tool so Vox can be inspected/driven from a
-- terminal (and remotely by fleet agents): e.g. `hs -c "print(1+1)"`.
pcall(function()
  require("hs.ipc")
  local prefix = hs.fs.attributes("/opt/homebrew/bin") and "/opt/homebrew"
                 or "/usr/local"
  hs.ipc.cliInstall(prefix)
end)

-- ---------------- CONFIG (edit freely) ----------------------
local HOME = os.getenv("HOME")

-- Private scratch dir (0700) instead of world-readable /tmp. Recordings,
-- screenshots and OCR text are the most sensitive things Vox touches — they
-- must never sit in shared /tmp (mode 1777) where another local account can
-- read them in the moment before deletion. TMPDIR is already a per-user 0700
-- dir on macOS; we still make our own subdir and lock it down for the /tmp
-- fallback case. Every /tmp/vox-* path in this file routes through TMP.
local TMP = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
            .. "/vox-" .. (os.getenv("USER") or "user")
os.execute("/bin/mkdir -p '" .. TMP .. "' 2>/dev/null; "
           .. "/bin/chmod 700 '" .. TMP .. "' 2>/dev/null")
local function tmp(name) return TMP .. "/" .. name end

-- hardware-aware defaults (tiers validated on real fleet hardware):
--   Apple Silicon        -> large-v3-turbo on Metal (~1.5s)
--   modern Intel (4+ cores) -> small (large HANGS without Metal)
--   ancient Intel (<=2 cores, e.g. 2012 MBA) -> tiny (~4s, still usable)
local IS_ARM, CORES = false, 4
do
  local p = io.popen("/usr/bin/uname -m")
  if p then IS_ARM = (p:read("*a") or ""):find("arm64") ~= nil; p:close() end
  local q = io.popen("/usr/sbin/sysctl -n hw.physicalcpu")
  if q then CORES = tonumber(q:read("*a")) or 4; q:close() end
end
local BREW = IS_ARM and "/opt/homebrew/bin" or "/usr/local/bin"
local WMODEL = IS_ARM and "ggml-large-v3-turbo-q5_0.bin"
            or (CORES <= 2 and "ggml-tiny-q5_1.bin" or "ggml-small-q5_1.bin")

local C = {
  sox         = BREW .. "/sox",
  whisper     = BREW .. "/whisper-cli",     -- fallback only
  whisperSrv  = BREW .. "/whisper-server",  -- fast path
  serverPort  = 8090,
  -- whisperHost: where transcription happens. Keep 127.0.0.1 normally.
  -- Old/slow Mac? Point it at a fast Mac running Vox on your LAN
  -- (that Mac sets serverBind = "0.0.0.0" in ITS local.lua) and this
  -- machine becomes a thin client — recording is cheap, the M-series
  -- Mac does the thinking.
  whisperHost = "127.0.0.1",
  serverBind  = "127.0.0.1",
  model       = HOME .. "/vox/models/" .. WMODEL,
  wav         = tmp("recording.wav"),
  wavNorm    = tmp("norm.wav"),
  language    = "en",                -- "en", "fr", or "auto" (auto costs ~+1s
                                     -- per dictation: extra detection pass)
  -- never oversubscribe the CPU (a 2-core MBA with 8 threads = thrash)
  threads     = tostring(math.max(1, math.min(IS_ARM and 8 or 4, CORES))),
  soundsDir   = HOME .. "/vox/sounds/",
  soundTheme  = "classic",           -- "classic" or "sleek" (menubar toggle)
  soundVolume = 0.5,

  -- Vocabulary hint fed to Whisper so it spells your world correctly.
  -- Put YOUR names/brands/jargon in ~/vox/local.lua (untracked) —
  -- see local.example.lua.
  vocabulary  = "Hammerspoon, Ollama, Whisper, Supabase, n8n, SaaS, CRM, API.",

  -- Local LLM cleanup pass. OFF by default: whisper large-v3-turbo already
  -- punctuates well, and the LLM adds 1.5-3s and sometimes paraphrases.
  -- Toggle from the menubar when you want context-aware rewriting.
  llmCleanup  = false,
  -- Opt-in escape hatch for ancient-hardware users who explicitly WANT the
  -- local LLM to run even on <=2-core CPUs where it'll take 15-60s per pass.
  -- Off by default — Vox's normal behavior on such Macs is to refuse smart-
  -- reply / expand / cleanup so it doesn't feel broken. Set true in local.lua
  -- if you've picked a small model (e.g. llama3.2:1b) and can wait.
  forceLocalLLM = false,
  translateTo = "off",                -- "off", "English", "French", "Spanish", "Dutch"
  ollamaUrl   = "http://localhost:11434/api/generate",
  ollamaModel = "llama3.2:3b",       -- legacy fallback if the router finds nothing
  llmTimeout  = 10,                  -- secs before falling back to raw text

  -- Adaptive brain: fast model for mechanical work (cleanup, quick replies),
  -- smart model where quality IS the product (translation, content, complex
  -- replies). Low-RAM Macs (<12GB) stay on fast automatically.
  models = {
    fast  = "llama3.2:3b",
    smart = "qwen2.5:7b",
  },

  holdKeycode = 61,                  -- 61 = Right Option. (Right Cmd = 54)
  holdKeyName = "Right Option",
  tapLockMax  = 0.35,                -- press shorter than this counts as a tap
  tailGrace   = 0.35,                -- mic stays open this long after release
                                     -- (last-word syllables are still in the air)
  doubleTapWindow = 0.45,            -- two taps this close = hands-free lock
  minBytes    = 24000,               -- ignore recordings under ~0.7s
  maxRecordSecs = 180,               -- auto-stop a forgotten locked recording

  -- Keep the transcript in the clipboard after pasting, so ⌘V re-pastes it
  -- if it landed in the wrong window. Off = restore whatever you had copied.
  keepInClipboard = true,

  -- When you dictate twice in a row into the same app, insert the missing
  -- space between "...sentence." and "Next sentence" automatically.
  autoSpace = true,

  -- Screen-aware dictation: while you talk, OCR the window you're dictating
  -- into and feed the visible names/jargon to Whisper as spelling hints —
  -- reply to someone and their name is spelled right on the first try.
  -- (Needs the Screen Recording grant; skipped silently without it.)
  screenContext = true,

  -- Tiny idle alien: a minimal, mostly-still cutie at the bottom edge when
  -- Vox is idle. Click him to start/stop a hands-free dictation.
  miniAlien = true,

  -- Voice commands: say "scratch that" to undo the last dictation;
  -- say "new paragraph." / "new line." (as their own clause) for breaks.
  voiceCommands = true,

  -- The alien's brain: every dictation is remembered in ~/vox/memory/
  -- (human-readable journal + instant full-text recall). LOCAL ONLY.
  -- memoryRAG feeds relevant memories into expand/smart-reply prompts.
  -- Export/import the whole brain between Macs:  python3 ~/vox/mem.py export
  memory      = true,
  memoryRAG   = true,
  fillerFilter = true,               -- strip "uh"/"um" etc. from transcripts
  apiEnable   = true,
  apiPort     = 8091,                -- localhost-only pulse API
  memoryWebhook = "",                -- optional: POST each memory to a URL

  -- The ONLY thing Vox ever sends off this Mac is the update check (a git
  -- fetch of code metadata from GitHub — never your audio, text, or memory).
  -- Set false for a fully dark, zero-outbound machine (update manually with
  -- git pull).
  autoUpdate  = true,

  -- Smart ducking: fade playing audio down (not off) while recording,
  -- ramp it back when done. Cleaner mic signal without killing the vibe.
  duckAudio   = true,
  duckLevel   = 0.15,                -- audio drops to 15% while recording
  duckMode    = "duck",              -- "duck" | "mute" | "pause" (pause media)

  -- Deterministic post-transcription fixes: zero latency, never paraphrases.
  -- Matched case-insensitively; spaces in keys also match hyphens.
  corrections = {
    ["super base"] = "Supabase",
    ["supa base"]  = "Supabase",
    ["n eight n"]  = "n8n",
  },
}

-- Personal overrides: ~/vox/local.lua (gitignored) returns a table that is
-- merged over the config above. Keep private vocabulary/corrections there.
-- Every override is TYPE-CHECKED against the default — a typo in local.lua
-- (duckLevel = "high") falls back to the default instead of crashing later.
do
  local defaults = {}
  for k, v in pairs(C) do defaults[k] = v end
  local f = loadfile(HOME .. "/vox/local.lua")
  if f then
    local ok, o = pcall(f)
    if ok and type(o) == "table" then
      for k, v in pairs(o) do C[k] = v end
    end
  end
  local bad = {}
  for k, dv in pairs(defaults) do
    if C[k] ~= nil and type(C[k]) ~= type(dv) then
      bad[#bad + 1] = k
      C[k] = dv
    end
  end
  if #bad > 0 then
    hs.timer.doAfter(3, function()
      hs.alert.show("Vox: ignored bad local.lua value(s): "
        .. table.concat(bad, ", "), 5)
    end)
  end
end
-- ------------------------------------------------------------

local state   = "idle"               -- idle | recording | processing
local locked  = false
local pendingTap = false             -- first tap of a possible double-tap
local lockAt  = 0                    -- when hands-free lock engaged
local recMode = "dictate"            -- dictate | expand (shift+key)
local recGen  = 0                    -- invalidates stale recorder callbacks
local keyDownAt = 0
local context = { app = "", title = "" }
local recTask, menubar
local timers  = {}                   -- anchored refs so timers survive GC
local duck                           -- ducking state (defined below)
local reqId   = 0                    -- guards against late LLM responses

local function log(msg) print("[vox] " .. msg) end

-- repeating timers must never die from one bad frame: pcall each tick,
-- log the first error per name, keep ticking
local tickErrs = {}
local function safeTick(name, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok and not tickErrs[name] then
      tickErrs[name] = true
      log("ERROR in " .. name .. " (suppressing repeats): " .. tostring(err))
    end
  end
end

-- ---------------- learning vocabulary -------------------------
-- Vox remembers the words you actually use (locally, in learned.json —
-- word frequencies only, never full transcripts) and feeds the distinctive
-- ones back into Whisper so recognition gets sharper the more you dictate.
local LEARNED_PATH = HOME .. "/vox/learned.json"
local learned = {}

local function loadLearned()
  local f = io.open(LEARNED_PATH, "r")
  if not f then return end
  local ok, data = pcall(hs.json.decode, f:read("*a"))
  f:close()
  if ok and type(data) == "table" then learned = data end
end
loadLearned()

local function saveLearned()
  -- prune one-offs if the store gets big
  local n = 0
  for _ in pairs(learned) do n = n + 1 end
  if n > 2000 then
    for k, e in pairs(learned) do
      if e.n <= 1 then learned[k] = nil end
    end
  end
  local f = io.open(LEARNED_PATH, "w")
  if f then f:write(hs.json.encode(learned)); f:close() end
end

local function learnFrom(text)
  for pos, w in text:gmatch("()([%a][%a'%-]+)") do
    local lw = w:lower()
    if #lw >= 4 then
      local e = learned[lw] or { n = 0, cap = 0, form = w }
      e.n = e.n + 1
      local before = text:sub(math.max(1, pos - 2), pos - 1)
      local atStart = (pos == 1) or before:find("[%.!%?]%s?$") ~= nil
      if w:find("^%u") and not atStart then
        e.cap = e.cap + 1
        e.form = w                 -- remember the capitalized form
      end
      learned[lw] = e
    end
  end
  if timers.learnSave then timers.learnSave:stop() end
  timers.learnSave = hs.timer.doAfter(4, saveLearned)
end

local function learnedCount()
  local n = 0
  for _ in pairs(learned) do n = n + 1 end
  return n
end

-- distinctive = mostly-capitalized mid-sentence (names/brands) or absent
-- from the system dictionary (jargon) and used repeatedly
local sysDict           -- loaded once (boot-time via buildLearnedVocab)
local function systemDict()
  if sysDict then return sysDict end
  sysDict = {}
  local f = io.open("/usr/share/dict/words", "r")
  if f then
    for line in f:lines() do sysDict[line:lower()] = true end
    f:close()
  end
  return sysDict
end

-- dictionary check that also catches inflections the word list lacks
-- (Founders -> founder, Hiring -> hire, Trusted -> trust)
local function isCommonWord(wl)
  local d = systemDict()
  if d[wl] then return true end
  local SLANG = { gonna = true, gotta = true, wanna = true, kinda = true,
                  sorta = true, okay = true, yeah = true }
  if SLANG[wl] then return true end
  for _, try in ipairs({ wl:gsub("s$", ""), wl:gsub("es$", ""),
                         wl:gsub("ed$", ""), wl:gsub("ed$", "e"),
                         wl:gsub("ing$", ""), wl:gsub("ing$", "e"),
                         wl:gsub("'s$", ""), wl:gsub("n't$", ""),
                         wl:gsub("'t$", ""), wl:gsub("'re$", ""),
                         wl:gsub("'ve$", ""), wl:gsub("'ll$", ""),
                         wl:gsub("'d$", "") }) do
    if try ~= wl and d[try] then return true end
  end
  return false
end

local function buildLearnedVocab()
  local dict = systemDict()
  local cands = {}
  for lw, e in pairs(learned) do
    local proper  = e.cap >= 2 and (e.cap / e.n) > 0.5
    local unusual = (not dict[lw]) and e.n >= 3
    if (proper or unusual) and not isCommonWord(lw) then
      cands[#cands + 1] = { form = e.form, score = e.n + e.cap * 2 }
    end
  end
  table.sort(cands, function(a, b) return a.score > b.score end)
  local parts, len = {}, 0
  for _, cd in ipairs(cands) do
    len = len + #cd.form + 2
    if len > 350 then break end    -- whisper's prompt budget is finite
    parts[#parts + 1] = cd.form
  end
  return table.concat(parts, ", ")
end

-- the brain teaches the ears: the memory's top proper-noun entities
-- (people, brands, places you actually talk about) join Whisper's vocabulary
local function brainVocab()
  local p = io.popen("/usr/bin/python3 " .. HOME
                     .. "/vox/mem.py entities -n 25 2>/dev/null")
  if not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  local parts, len = {}, 0
  for line in out:gmatch("[^\n]+") do
    local ok, e = pcall(hs.json.decode, line)
    if ok and e and e.entity and e.entity:find("%u")
       and not isCommonWord(e.entity:lower()) then   -- real names only
      len = len + #e.entity + 2
      if len > 220 then break end
      parts[#parts + 1] = e.entity
    end
  end
  return table.concat(parts, ", ")
end

local vocabCache = nil
local function fullVocabulary()
  if not vocabCache then
    local extra = buildLearnedVocab()      -- reads the system dictionary once
    local brains = brainVocab()
    vocabCache = C.vocabulary
      .. (extra ~= "" and (" " .. extra .. ".") or "")
      .. (brains ~= "" and (" " .. brains .. ".") or "")
  end
  return vocabCache
end
local function invalidateVocab() vocabCache = nil end

-- ---------------- the alien's brain ---------------------------
-- Full transcripts flow into ~/vox/memory/ via mem.py: a human-readable
-- monthly journal plus a SQLite full-text index for instant recall.
local nextMemMode = "dictate"          -- tag set by generators before paste

local function rememberText(text, mode)
  if not C.memory or #text < 2 then return end
  M.memTask = hs.task.new("/usr/bin/python3", nil,
    { HOME .. "/vox/mem.py", "add", "--text", text,
      "--app", context.app or "", "--mode", mode or "dictate" })
  M.memTask:start()
  if C.memoryWebhook ~= "" then       -- optional pulse to n8n/anything
    pcall(hs.http.asyncPost, C.memoryWebhook,
      hs.json.encode({ ts = os.time(), app = context.app, mode = mode,
                       text = text }),
      { ["Content-Type"] = "application/json" }, function() end)
  end
end

local function memoryLookup(query, n, cb)
  if not (C.memory and C.memoryRAG) then cb("") return end
  M.memQTask = hs.task.new("/usr/bin/python3", function(code, out)
    local parts = {}
    for line in (out or ""):gmatch("[^\n]+") do
      local ok, e = pcall(hs.json.decode, line)
      if ok and e and e.text then
        parts[#parts + 1] = "- " .. e.text:sub(1, 300)
      end
    end
    cb(#parts > 0 and table.concat(parts, "\n") or "")
  end, { HOME .. "/vox/mem.py", "search", query, "-n", tostring(n or 3) })
  M.memQTask:start()
end

-- ---------------- adaptive brain router -----------------------
-- Fast when we can be fast, concentrated when we need to be concentrated.
local lowRam = false
do
  local p = io.popen("/usr/sbin/sysctl -n hw.memsize")
  if p then
    local v = tonumber(p:read("*a")) or 0
    p:close()
    lowRam = v > 0 and v < 12 * 1024 * 1024 * 1024
  end
end

local availableModels = {}
local function refreshModels()
  hs.http.asyncGet(C.ollamaUrl:gsub("/api/generate", "/api/tags"), nil,
    function(status, body)
      if status ~= 200 then return end
      local ok, d = pcall(hs.json.decode, body)
      if ok and d and d.models then
        availableModels = {}
        for _, m in ipairs(d.models) do availableModels[m.name] = true end
      end
    end)
end

-- is the LLM running on THIS machine (vs a fast Mac on the LAN)?
local function ollamaIsLocal()
  return C.ollamaUrl:find("//127%.0%.0%.1") ~= nil
      or C.ollamaUrl:find("//localhost") ~= nil
end

-- task: cleanup | translate | reply | expand · complex: judgement hint
local function pickModel(task, complex)
  local want
  if lowRam and ollamaIsLocal() then
    want = C.models.fast     -- 8GB Macs never swap-thrash; remote brain = no cap
  elseif task == "translate" or task == "expand" or task == "answer" then
    want = C.models.smart                      -- quality IS the product
  elseif task == "reply" then
    want = complex and C.models.smart or C.models.fast
  else
    want = C.models.fast                       -- mechanical: speed wins
  end
  if availableModels[want] then return want end
  if availableModels[C.models.fast] then return C.models.fast end
  return C.ollamaModel
end

-- ---------------- pipeline lock-in ----------------------------
-- "If it works once, lock it in." Vox verifies its own transcription
-- pipeline end-to-end (synthesized speech -> transcript), records the proven
-- configuration in calibration.json, and when the locked path starts failing
-- it walks the fallback chain by itself and locks in whatever works.
local CALIB_PATH = HOME .. "/vox/calibration.json"
local calib = {}
do
  local f = io.open(CALIB_PATH, "r")
  if f then
    local ok, d = pcall(hs.json.decode, f:read("*a"))
    f:close()
    if ok and type(d) == "table" then calib = d end
  end
end

local function saveCalib()
  local f = io.open(CALIB_PATH, "w")
  if f then f:write(hs.json.encode(calib)); f:close() end
end

local currentRev = "unknown"
do
  local p = io.popen("cd \"$HOME/vox\" && /usr/bin/git rev-parse --short HEAD 2>/dev/null")
  if p then currentRev = (p:read("*a") or ""):gsub("%s+", ""); p:close() end
end

-- what the user configured, before any self-healing overrides
local configuredHost = C.whisperHost
if calib.forceLocal and C.whisperHost ~= "127.0.0.1" then
  log("calibration: remote brain was failing — running local until re-verified")
  C.whisperHost = "127.0.0.1"
end

local function noteTranscribeSuccess(secs)
  calib.mode = (C.whisperHost == "127.0.0.1") and "local" or ("remote " .. C.whisperHost)
  calib.lastLatency = math.floor(secs * 10) / 10
  if not calib.bestLatency or calib.lastLatency < calib.bestLatency then
    calib.bestLatency = calib.lastLatency
  end
  calib.verifiedAt, calib.verifiedRev = os.time(), currentRev
  calib.remoteFails = 0
  saveCalib()
end

local function noteRemoteFail()
  calib.remoteFails = (calib.remoteFails or 0) + 1
  if calib.remoteFails >= 2 and not calib.forceLocal then
    calib.forceLocal = true
    C.whisperHost = "127.0.0.1"
    hs.alert.show("Vox: remote brain failing — locked to local transcription."
      .. " Menu: Verify pipeline to retry.", 4)
  end
  saveCalib()
end

-- ---------------- sounds (subtle, synthesized) ---------------
local sounds = {}
local function loadSounds()
  for _, n in ipairs({ "start", "stop", "done" }) do
    local s = hs.sound.getByFile(C.soundsDir .. C.soundTheme .. "/" .. n .. ".wav")
    if s then s:volume(C.soundVolume) end
    sounds[n] = s
  end
end
loadSounds()
local function play(n)
  local s = sounds[n]
  if not s then return end
  -- boost cues while system volume is ducked so they stay audible
  s:volume((duck and duck.active and C.duckLevel > 0.05)
           and math.min(1, C.soundVolume / C.duckLevel) or C.soundVolume)
  s:stop(); s:play()
end

-- ---------------- smart audio ducking -------------------------
duck = { active = false, orig = nil, dev = nil }

local function rampVolume(target, steps, interval, onDone)
  if timers.duck then timers.duck:stop() end
  local dev = duck.dev
  if not dev then return end
  local from = dev:outputVolume() or 0
  local n = 0
  timers.duck = hs.timer.doEvery(interval, function()
    n = n + 1
    dev:setOutputVolume(from + (target - from) * (n / steps))
    if n >= steps then
      timers.duck:stop()
      if onDone then onDone() end
    end
  end)
end

local function mediaPlayPause()
  hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
  hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
end

local function duckDown()
  if not C.duckAudio then return end
  -- "pause": stop the podcast/music itself (media key) — nothing bleeds into
  -- the mic AND you miss nothing; it resumes the moment you stop talking
  if C.duckMode == "pause" then
    if not duck.paused then duck.paused = true; mediaPlayPause() end
    return
  end
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev or not dev:outputVolume() then return end
  local vol = dev:outputVolume()
  if vol < 3 then return end                 -- nothing meaningful playing
  if not duck.active then                    -- don't clobber orig mid-restore
    duck.orig, duck.dev, duck.active = vol, dev, true
  end
  -- "mute": total silence while the mic is open — zero contamination
  local target = (C.duckMode == "mute") and 0 or duck.orig * C.duckLevel
  rampVolume(target, 5, 0.05)                -- quick fade down
end

local function duckUp()
  if duck.paused then duck.paused = false; mediaPlayPause() end
  if not duck.active then return end
  rampVolume(duck.orig, 8, 0.06, function() duck.active = false end)
end

-- ---------------- HUD: cute alien + bars, bottom center ------
-- A little green alien lives in the pill: bobs, blinks, blushes, and reacts
-- to your voice. The pill puffs in and out of a cloud of smoke.
local PILL_W, PILL_H, BARS = 100, 28, 8
local CV_W, CV_H = 150, 70            -- canvas is bigger than the pill so the
local OX, OY = (CV_W - PILL_W) / 2, 30  -- smoke has room to billow
local PUFFS = 7
local hud = { canvas = nil, timer = nil, mode = "rec", phase = 0,
              visible = false, anim = nil, animT = 0,
              nextBlink = 30, blinkUntil = 0, baseX = 0, baseY = 0,
              level = 0, emote = nil, emoteUntil = 0 }

-- live mic level: peek at the tail of the growing recording (16-bit PCM)
local function micLevel()
  local f = io.open(C.wav, "rb")
  if not f then return 0 end
  local size = f:seek("end")
  local n = 3200                       -- last ~100ms of audio
  if size < 44 + n then f:close(); return 0 end
  f:seek("set", size - n)
  local d = f:read(n)
  f:close()
  if not d then return 0 end
  local peak = 0
  for i = 1, #d - 1, 8 do
    local lo, hi = d:byte(i, i + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    if v < 0 then v = -v end
    if v > peak then peak = v end
  end
  return peak / 32768
end

-- what mood did the speaker leave the alien in?
local function detectEmotion(t)
  local s = t:lower()
  if s:find("haha") or s:find("%f[%a]lol%f[%A]") or s:find("lmao")
     or s:find("funny") or s:find("joke") or s:find("hilarious") then
    return "joy"
  end
  local _, excl = t:gsub("!", "")
  if excl >= 2 then return "excite" end
  if t:find("%?%s*$") then return "curious" end
  if excl >= 1 then return "excite" end
  return "done"
end

local ALIEN = { red = 0.45, green = 0.97, blue = 0.72, alpha = 1 }   -- mint green
local EYES  = { red = 0.02, green = 0.06, blue = 0.12, alpha = 0.95 }

local function easeOutBack(t)   -- overshoot = the cute bounce
  local c1, c3 = 1.70158, 2.70158
  local u = t - 1
  return 1 + c3 * u * u * u + c1 * u * u
end

-- ---------------- idle mini-alien -----------------------------
-- When Vox is idle, a tiny alien rests at the bottom edge with two little
-- buttons: C = speak-to-content, P = absorb the screen into memory.
-- Click the alien himself for hands-free dictation.
local mini = { canvas = nil, timer = nil, phase = 0,
               nextBlink = 20, blinkUntil = 0, act = {} }
local MW, MH, MOFF = 74, 30, 24        -- canvas w/h, alien x-offset

local function miniEnsure()
  if mini.canvas then return end
  local c = hs.canvas.new({ x = 0, y = 0, w = MW, h = MH })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)             -- clicks don't steal app focus
  c[1] = { type = "oval", action = "fill", fillGradient = "radial",
           fillGradientColors = {
             { red = 0.72, green = 1.0,  blue = 0.88, alpha = 1 },
             { red = 0.40, green = 0.90, blue = 0.66, alpha = 1 } },
           fillGradientCenter = { x = -0.35, y = -0.45 },
           frame = { x = MOFF + 6, y = 12, w = 14, h = 15 } }
  c[2] = { type = "oval", action = "fill", fillColor = EYES,
           frame = { x = MOFF + 9, y = 16.5, w = 3, h = 4 } }
  c[3] = { type = "oval", action = "fill", fillColor = EYES,
           frame = { x = MOFF + 14, y = 16.5, w = 3, h = 4 } }
  c[4] = { type = "arc", action = "stroke", strokeColor = EYES,
           strokeWidth = 1, center = { x = MOFF + 13, y = 22 }, radius = 2.2,
           startAngle = 135, endAngle = 225 }
  c[5] = { type = "segments", action = "stroke", strokeColor = ALIEN,
           strokeWidth = 1.2,
           coordinates = { { x = MOFF + 13, y = 12 }, { x = MOFF + 13, y = 8 } } }
  c[6] = { type = "oval", action = "fill", fillColor = ALIEN,
           frame = { x = MOFF + 11.6, y = 5.4, w = 2.8, h = 2.8 } }
  c[7] = { type = "oval", action = "fill",
           fillColor = { red = 1, green = 1, blue = 1, alpha = 0.85 },
           frame = { x = MOFF + 10.7, y = 17.2, w = 1.2, h = 1.4 } }
  c[8] = { type = "oval", action = "fill",
           fillColor = { red = 1, green = 1, blue = 1, alpha = 0.85 },
           frame = { x = MOFF + 15.7, y = 17.2, w = 1.2, h = 1.4 } }
  -- C button (content) and P button (absorb screen)
  local btnBg = { red = 0.10, green = 0.12, blue = 0.20, alpha = 0.85 }
  c[9]  = { type = "oval", action = "fill", fillColor = btnBg,
            frame = { x = 2, y = 12, w = 17, h = 17 } }
  c[10] = { type = "text", text = "C", textSize = 10,
            textColor = { red = 0.45, green = 0.97, blue = 0.72, alpha = 1 },
            textAlignment = "center", frame = { x = 2, y = 14.5, w = 17, h = 13 } }
  c[11] = { type = "oval", action = "fill", fillColor = btnBg,
            frame = { x = MW - 19, y = 12, w = 17, h = 17 } }
  c[12] = { type = "text", text = "P", textSize = 10,
            textColor = { red = 0.72, green = 0.52, blue = 1.0, alpha = 1 },
            textAlignment = "center", frame = { x = MW - 19, y = 14.5, w = 17, h = 13 } }
  c:alpha(0.55)
  c:canvasMouseEvents(true, false, false, false)
  c:mouseCallback(function(_, event, _, x, y)
    if event ~= "mouseDown" then return end
    if x <= 22 and mini.act.content then mini.act.content()
    elseif x >= MW - 22 and mini.act.grab then mini.act.grab()
    elseif mini.act.talk then mini.act.talk() end
  end)
  mini.canvas = c
end

local function miniTick()
  local c = mini.canvas
  if not c then return end
  mini.phase = mini.phase + 1
  local bob = math.sin(mini.phase * 0.12) * 0.8
  if mini.phase >= mini.nextBlink then
    mini.blinkUntil = mini.phase + 1
    mini.nextBlink = mini.phase + 24 + math.random(48)
  end
  -- rare personality bits: a glance around, an antenna twitch, a tiny hop
  if not mini.nextBit then
    mini.nextBit = mini.phase + 240 + math.random(720)   -- first in 1-4 min
  end
  if mini.phase >= mini.nextBit then
    mini.bit = ({ "look", "twitch", "hop" })[math.random(3)]
    mini.bitStart, mini.bitUntil = mini.phase, mini.phase + 10
    mini.nextBit = mini.phase + 480 + math.random(960)   -- next in 2-6 min
  end
  local inBit = mini.bit and mini.phase < mini.bitUntil
  local lookX = 0
  local swayAmp = 1.2
  if inBit then
    local t = (mini.phase - mini.bitStart) / 10
    if mini.bit == "look" then
      lookX = math.sin(t * math.pi * 2) * 1.7           -- glance left, right
    elseif mini.bit == "twitch" then
      swayAmp = 3.4                                      -- excited antenna
    elseif mini.bit == "hop" then
      bob = bob - math.sin(t * math.pi) * 3.2            -- one happy hop
    end
  end
  local eh = (mini.phase < mini.blinkUntil) and 0.8 or 4
  local ey = 18.5 - eh / 2 + bob
  c[1].frame = { x = MOFF + 6, y = 12 + bob, w = 14, h = 15 }
  c[2].frame = { x = MOFF + 9 + lookX,  y = ey, w = 3, h = eh }
  c[3].frame = { x = MOFF + 14 + lookX, y = ey, w = 3, h = eh }
  c[4].center = { x = MOFF + 13, y = 22 + bob }
  local sway = math.sin(mini.phase * (swayAmp > 2 and 0.5 or 0.08)) * swayAmp
  c[5].coordinates = { { x = MOFF + 13, y = 12 + bob },
                       { x = MOFF + 13 + sway, y = 8 + bob } }
  c[6].frame = { x = MOFF + 11.6 + sway, y = 5.4 + bob, w = 2.8, h = 2.8 }
  local ga = eh > 2 and 0.85 or 0
  c[7].fillColor = { red = 1, green = 1, blue = 1, alpha = ga }
  c[8].fillColor = { red = 1, green = 1, blue = 1, alpha = ga }
  c[7].frame = { x = MOFF + 10.7 + lookX, y = ey + eh * 0.15, w = 1.2, h = 1.4 }
  c[8].frame = { x = MOFF + 15.7 + lookX, y = ey + eh * 0.15, w = 1.2, h = 1.4 }
end

local function miniShow()
  if not C.miniAlien or hud.visible then return end
  miniEnsure()
  -- primary screen, always: mainScreen() follows keyboard focus, which on
  -- multi-monitor setups strands the alien on whatever display had focus
  local f = hs.screen.primaryScreen():fullFrame()
  mini.canvas:frame({ x = f.x + (f.w - MW) / 2, y = f.y + f.h - 34,
                      w = MW, h = MH })
  mini.canvas:show()
  if not mini.timer then
    mini.timer = hs.timer.doEvery(0.25, safeTick("miniTick", miniTick))
  end
end

local function miniHide()
  if mini.timer then mini.timer:stop(); mini.timer = nil end
  if mini.canvas then mini.canvas:hide() end
end

-- element indices: 1 pill · 2 head · 3/4 eyes · 5 smile · 6 antenna ·
-- 7 antenna tip · 8..15 bars · 16/17 eye glints · 18/19 blush · 20.. smoke
local function hudEnsure()
  if hud.canvas then return end
  local c = hs.canvas.new({ x = 0, y = 0, w = CV_W, h = CV_H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c[1] = { type = "rectangle", action = "fill",              -- pill
           fillColor = { red = 0.04, green = 0.04, blue = 0.09, alpha = 0.6 },
           roundedRectRadii = { xRadius = PILL_H / 2, yRadius = PILL_H / 2 },
           frame = { x = OX, y = OY, w = PILL_W, h = PILL_H } }
  c[2] = { type = "oval", action = "fill",                   -- head w/ shading
           fillGradient = "radial",
           fillGradientColors = {
             { red = 0.72, green = 1.0,  blue = 0.88, alpha = 1 },
             { red = 0.40, green = 0.90, blue = 0.66, alpha = 1 },
           },
           fillGradientCenter = { x = -0.35, y = -0.45 },
           frame = { x = CV_W / 2 - 7, y = OY + 6, w = 14, h = 15 } }
  c[3] = { type = "oval", action = "fill", fillColor = EYES,         -- eye L
           frame = { x = 0, y = -10, w = 3.4, h = 4.6 } }
  c[4] = { type = "oval", action = "fill", fillColor = EYES,         -- eye R
           frame = { x = 0, y = -10, w = 3.4, h = 4.6 } }
  c[5] = { type = "arc", action = "stroke", strokeColor = EYES,      -- smile
           strokeWidth = 1.1, center = { x = CV_W / 2, y = OY + 16 },
           radius = 2.4, startAngle = 135, endAngle = 225 }
  c[6] = { type = "segments", action = "stroke", strokeColor = ALIEN, -- antenna
           strokeWidth = 1.2,
           coordinates = { { x = CV_W / 2, y = OY + 6 }, { x = CV_W / 2, y = OY + 2.5 } } }
  c[7] = { type = "oval", action = "fill", fillColor = ALIEN,        -- tip
           frame = { x = CV_W / 2 - 1.5, y = OY + 0.6, w = 3, h = 3 } }
  for i = 1, BARS do
    c[i + 7] = { type = "rectangle", action = "fill",                -- bars
                 fillColor = { red = 0.35, green = 0.9, blue = 1.0, alpha = 0.95 },
                 roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
                 frame = { x = 0, y = -10, w = 3, h = 4 } }
  end
  for i = 16, 17 do                                                  -- glints
    c[i] = { type = "oval", action = "fill",
             fillColor = { red = 1, green = 1, blue = 1, alpha = 0.9 },
             frame = { x = 0, y = -10, w = 1.5, h = 1.8 } }
  end
  for i = 18, 19 do                                                  -- blush
    c[i] = { type = "oval", action = "fill",
             fillColor = { red = 1.0, green = 0.55, blue = 0.65, alpha = 0.22 },
             frame = { x = 0, y = -10, w = 3.6, h = 2.1 } }
  end
  for i = 0, PUFFS - 1 do                                            -- smoke
    c[20 + i] = { type = "oval", action = "fill",
                  fillColor = { red = 0.86, green = 0.93, blue = 1.0, alpha = 0 },
                  frame = { x = -30, y = -30, w = 1, h = 1 } }
  end
  for k = 0, 2 do                                                    -- thought dots
    c[27 + k] = { type = "oval", action = "fill",
                  fillColor = { red = 0.72, green = 0.52, blue = 1.0, alpha = 0 },
                  frame = { x = -10, y = -10, w = 2, h = 2 } }
  end
  for k = 0, 2 do                                                    -- comet trail
    c[30 + k] = { type = "oval", action = "fill",
                  fillColor = { red = 0.8, green = 0.6, blue = 1.0, alpha = 0 },
                  frame = { x = -10, y = -10, w = 2, h = 2 } }
  end
  hud.canvas = c
end

local function hudTick()
  local c = hud.canvas
  if not c then return end
  hud.phase = hud.phase + 0.4

  -- entrance / exit (pill motion) + smoke puffs
  local yOff, alpha, puffT = 0, 1, nil
  if hud.anim == "in" then
    hud.animT = math.min(1, hud.animT + 0.14)
    yOff  = (1 - easeOutBack(hud.animT)) * 24
    alpha = math.min(1, hud.animT * 2.5)
    puffT = hud.animT
    if hud.animT >= 1 then hud.anim = nil end
  elseif hud.anim == "out" then
    hud.animT = math.min(1, hud.animT + 0.16)
    yOff, alpha = hud.animT * hud.animT * 20, 1 - hud.animT * 1.1
    if alpha < 0 then alpha = 0 end
    puffT = hud.animT
    if hud.animT >= 1 then
      hud.visible = false
      if hud.timer then hud.timer:stop(); hud.timer = nil end
      c:hide()
      miniShow()               -- the tiny idle alien takes back the stage
      return
    end
  end
  c:frame({ x = hud.baseX, y = hud.baseY + yOff, w = CV_W, h = CV_H })

  -- smoke: blooms outward and fades as the pill arrives/leaves
  for i = 0, PUFFS - 1 do
    local el = c[20 + i]
    if puffT then
      -- staggered per-puff timing makes the poof feel alive
      local pt = math.max(0, math.min(1, puffT * 1.2 - i * 0.045))
      local ang = (i / PUFFS) * 6.283 + 0.55
      local spread = (18 + (i % 3) * 8) * (0.3 + pt * 1.0)
      local px = CV_W / 2 + math.cos(ang) * spread
      local py = OY + PILL_H / 2 + math.sin(ang) * spread * 0.55 - pt * 13
      local r = 7 + pt * 20 + (i % 3) * 3
      el.frame = { x = px - r / 2, y = py - r / 2, w = r, h = r }
      el.fillColor = { red = 0.87, green = 0.94, blue = 1.0,
                       alpha = math.max(0, (1 - pt) * 0.5) }
    else
      el.fillColor = { red = 0.86, green = 0.93, blue = 1.0, alpha = 0 }
    end
  end

  -- pill + face fade together (elements 1..19 share the canvas alpha via
  -- per-element handling being overkill; canvas alpha covers the smoke too,
  -- so we fade the pill/face by alpha on the pill and rely on motion)
  c:alpha(puffT and alpha or 1)
  local working = (hud.mode == "work")
  local breathe = working and (0.08 + math.sin(hud.phase * 0.9) * 0.07) or 0
  c[1].fillColor = { red = 0.04 + breathe * 0.6, green = 0.04,
                     blue = 0.09 + breathe, alpha = (0.6 + breathe) * alpha }
  -- comet with fading tail orbits the pill while the alien works
  for k = 0, 2 do
    local el = c[30 + k]
    if working then
      local a = hud.phase * 1.25 - k * 0.38
      local px = OX + PILL_W / 2 + math.cos(a) * (PILL_W / 2 + 7)
      local py = OY + PILL_H / 2 + math.sin(a) * (PILL_H / 2 + 6)
      local rr = 3.6 - k * 0.9
      el.frame = { x = px - rr / 2, y = py - rr / 2, w = rr, h = rr }
      el.fillColor = { red = 0.8, green = 0.62, blue = 1.0,
                       alpha = (0.95 - k * 0.3) * alpha }
    else
      el.fillColor = { red = 0.8, green = 0.62, blue = 1.0, alpha = 0 }
    end
  end

  -- live voice level (smoothed) drives everything while listening
  if hud.mode == "rec" then
    hud.level = hud.level * 0.55 + micLevel() * 0.45
  end
  local norm = math.min(1, hud.level / 0.12)

  -- alien: mood-driven face
  local eyeW, eyeH, smileR, smileW = 3.4, 4.8, 2.4, 1.1
  local bobAmp, bobSpd, antSway = 1.4, 0.45, 1.6
  local eyeDart, orbit = 0, false

  if hud.mode == "rec" then
    eyeH   = 4.4 + norm * 2.2
    bobAmp = 1.4 + norm * 1.6
    if hud.phase >= hud.nextBlink then
      hud.blinkUntil = hud.phase + 1.3
      hud.nextBlink  = hud.phase + 16 + math.random() * 24
    end
    if hud.phase < hud.blinkUntil then eyeH = 1.1 end
  elseif hud.mode == "work" then
    -- THINKING looks nothing like listening: antenna spins like a radar,
    -- eyes dart side to side, thought dots rise, bars do a KITT sweep
    orbit   = true
    eyeDart = math.sin(hud.phase * 0.35) * 1.4
    bobAmp, bobSpd = 0.9, 0.65
  elseif hud.mode == "emote" then
    if hud.emote == "joy" then        -- laughing squint + big grin + bounce
      eyeW, eyeH, smileR, smileW = 4.4, 1.5, 3.7, 1.6
      bobAmp, bobSpd = 2.8, 1.15
    elseif hud.emote == "excite" then -- big sparkly eyes, quick bounce
      eyeW, eyeH = 4.6, 6.2
      bobAmp, bobSpd = 2.2, 0.9
    elseif hud.emote == "curious" then -- wide eyes, antenna swings wondering
      eyeH, antSway = 5.6, 4.2
    elseif hud.emote == "dance" then   -- the keep-warm groove: subtle sway
      bobAmp, bobSpd, antSway = 1.9, 0.95, 3.0
      smileR = 3.0
    end
    if hud.phase >= hud.emoteUntil and hud.anim ~= "out" then
      hud.anim, hud.animT = "out", 0
    end
  end

  local bob = math.sin(hud.phase * bobSpd) * bobAmp
  local sway = (hud.mode == "emote" and hud.emote == "dance")
               and math.sin(hud.phase * 0.5) * 3.5 or 0
  local ax, ay = CV_W / 2 + sway, OY + 13.5 + bob
  c[2].frame = { x = ax - 7, y = ay - 7.5, w = 14, h = 15 }
  local eyeCY = ay - 2.2
  local ex = ax + eyeDart
  c[3].frame = { x = ex - 1.6 - eyeW, y = eyeCY - eyeH / 2, w = eyeW, h = eyeH }
  c[4].frame = { x = ex + 1.6,        y = eyeCY - eyeH / 2, w = eyeW, h = eyeH }
  -- sparkle glints track the eyes (hidden mid-blink / joy-squint)
  local glintA = (eyeH > 2.4) and 0.9 or 0
  c[16].fillColor = { red = 1, green = 1, blue = 1, alpha = glintA }
  c[17].fillColor = { red = 1, green = 1, blue = 1, alpha = glintA }
  c[16].frame = { x = ex - 1.6 - eyeW + eyeW * 0.52, y = eyeCY - eyeH / 2 + eyeH * 0.14, w = 1.5, h = 1.8 }
  c[17].frame = { x = ex + 1.6 + eyeW * 0.52,        y = eyeCY - eyeH / 2 + eyeH * 0.14, w = 1.5, h = 1.8 }
  -- blush cheeks, a touch stronger when he's excited or joyful
  local blushA = 0.22 + ((hud.emote == "joy" or hud.emote == "excite")
                         and hud.mode == "emote" and 0.16 or 0)
  c[18].fillColor = { red = 1.0, green = 0.55, blue = 0.65, alpha = blushA }
  c[19].fillColor = { red = 1.0, green = 0.55, blue = 0.65, alpha = blushA }
  c[18].frame = { x = ax - 8.6, y = ay + 1.2, w = 3.6, h = 2.1 }
  c[19].frame = { x = ax + 5.0, y = ay + 1.2, w = 3.6, h = 2.1 }
  c[5].center = { x = ax, y = ay + 2.2 }
  c[5].radius = smileR
  c[5].strokeWidth = smileW
  -- antenna: radar-spin while thinking, victory twirl when the text lands
  local twirl = hud.mode == "emote"
                and (hud.phase - (hud.emoteStart or -99)) < 5
  local tipX, tipY
  if orbit or twirl then
    local spd = twirl and 2.4 or 1.1
    tipX = ax + math.cos(hud.phase * spd) * (twirl and 5.4 or 4.6)
    tipY = ay - 11.5 + math.sin(hud.phase * spd) * (twirl and 3.0 or 2.4)
  else
    tipX = ax + math.sin(hud.phase * 0.6) * antSway
    tipY = ay - 11
  end
  c[6].coordinates = { { x = ax, y = ay - 7.5 }, { x = tipX, y = tipY + 1 } }
  if twirl then                        -- tip flares white during the twirl
    c[7].fillColor = { red = 1, green = 1, blue = 1, alpha = 0.95 }
    c[7].frame = { x = tipX - 2, y = tipY - 3.3, w = 4, h = 4 }
  else
    c[7].fillColor = ALIEN
    c[7].frame = { x = tipX - 1.5, y = tipY - 2.8, w = 3, h = 3 }
  end
  -- thought dots: "..." rising above his head while he works
  for k = 0, 2 do
    local el = c[27 + k]
    if hud.mode == "work" then
      local a = math.max(0, math.sin(hud.phase * 0.8 - k * 1.1))
      local rr = 1.7 + k * 0.7
      el.fillColor = { red = 0.72, green = 0.52, blue = 1.0, alpha = a * 0.85 }
      el.frame = { x = ax + 7.5 + k * 4.2 - rr / 2,
                   y = ay - 10.5 - k * 3.4 - rr / 2, w = rr, h = rr }
    else
      el.fillColor = { red = 0.72, green = 0.52, blue = 1.0, alpha = 0 }
    end
  end

  -- bars flank the alien; while listening YOUR VOICE sets the height
  for i = 1, BARS do
    local d = (i <= 4) and (5 - i) or (i - 4)   -- distance from alien: 1..4
    local h
    if hud.mode == "rec" then
      local wave = math.abs(math.sin(hud.phase + d * 0.9))
      h = 4 + norm * (15 - d * 1.8) * (0.5 + wave * 0.5) + math.random() * 1.5
    elseif hud.mode == "emote" then
      h = 4 + math.abs(math.sin(hud.phase * 0.7 + d)) * 2.5
    else                           -- thinking: KITT sweep = clearly BUSY
      local pos = ((math.sin(hud.phase * 0.55) + 1) / 2) * (BARS - 1) + 1
      h = 4 + 13 * math.max(0, 1 - math.abs(i - pos) * 0.55)
    end
    local x = (i <= 4) and (OX + 12 + (i - 1) * 7)
                        or (OX + PILL_W - 36 + (i - 5) * 7)
    c[i + 7].frame = { x = x, y = OY + (PILL_H - h) / 2, w = 3, h = h }
  end
end

local function hudShow(mode)
  miniHide()
  hudEnsure()
  hud.mode = mode
  local col = (mode == "rec")
      and { red = 0.35, green = 0.9,  blue = 1.0, alpha = 0.95 }   -- cyan: listening
      or  { red = 0.72, green = 0.52, blue = 1.0, alpha = 0.95 }   -- violet: thinking
  for i = 1, BARS do hud.canvas[i + 7].fillColor = col end
  if not hud.visible then
    local f = hs.screen.mainScreen():fullFrame()
    hud.baseX = f.x + (f.w - CV_W) / 2
    hud.baseY = f.y + f.h - CV_H - 28
    hud.visible, hud.anim, hud.animT = true, "in", 0
    hud.emote = nil
    hud.canvas:alpha(0)
    hud.canvas:frame({ x = hud.baseX, y = hud.baseY + 24, w = CV_W, h = CV_H })
    hud.canvas:show()
  elseif hud.anim == "out" then    -- caught mid-exit: come back
    hud.anim, hud.animT = "in", 0
  end
  -- weak hardware gets a calmer alien: 8fps instead of 20
  if not hud.timer then
    hud.timer = hs.timer.doEvery(CORES <= 2 and 0.12 or 0.05,
                                 safeTick("hudTick", hudTick))
  end
end

local function hudHide()
  if not hud.visible then
    if hud.timer then hud.timer:stop(); hud.timer = nil end
    if hud.canvas then hud.canvas:hide() end
    return
  end
  hud.anim, hud.animT = "out", 0   -- hudTick finishes the exit
end

-- the keep-warm heartbeat: a quick, subtle groove at the bottom of the screen
local function hudDance()
  if hud.visible or state ~= "idle" then return end  -- never interrupt work
  miniHide()
  hudEnsure()
  hud.mode, hud.emote = "emote", "dance"
  hud.emoteUntil = hud.phase + 26
  local col = { red = 0.45, green = 0.97, blue = 0.72, alpha = 0.7 }
  for i = 1, BARS do hud.canvas[i + 7].fillColor = col end
  local f = hs.screen.mainScreen():fullFrame()
  hud.baseX = f.x + (f.w - CV_W) / 2
  hud.baseY = f.y + f.h - CV_H - 28
  hud.visible, hud.anim, hud.animT = true, "in", 0
  hud.canvas:alpha(0)
  hud.canvas:frame({ x = hud.baseX, y = hud.baseY + 24, w = CV_W, h = CV_H })
  hud.canvas:show()
  if not hud.timer then
    hud.timer = hs.timer.doEvery(CORES <= 2 and 0.12 or 0.05,
                                 safeTick("hudTick", hudTick))
  end
end

-- brief post-transcript reaction: the alien responds to what you said
local function hudEmote(kind)
  if not (hud.visible and hud.canvas) then return end
  hud.mode, hud.emote = "emote", kind or "done"
  hud.emoteStart = hud.phase
  hud.emoteUntil = hud.phase + ((kind == "done") and 12 or 26)
  local col = (kind == "joy")    and { red = 1.0,  green = 0.84, blue = 0.32, alpha = 0.95 }
           or (kind == "excite") and { red = 1.0,  green = 0.5,  blue = 0.66, alpha = 0.95 }
           or                        { red = 0.35, green = 0.9,  blue = 1.0,  alpha = 0.9 }
  for i = 1, BARS do hud.canvas[i + 7].fillColor = col end
end

-- branded menubar icon: tiny alien silhouette with punched-out eyes.
-- idle = monochrome template (adapts to menubar theme), rec = coral,
-- work = violet.
local function alienImage(fill)
  local cc = hs.canvas.new({ x = 0, y = 0, w = 20, h = 20 })
  local col = (fill == "template") and { alpha = 1 } or fill
  cc[1] = { type = "oval", action = "fill", fillColor = col,
            frame = { x = 4.5, y = 6.5, w = 11, h = 12 } }              -- head
  cc[2] = { type = "segments", action = "stroke", strokeColor = col,
            strokeWidth = 1.3,
            coordinates = { { x = 10, y = 6.5 }, { x = 10, y = 3.2 } } } -- antenna
  cc[3] = { type = "oval", action = "fill", fillColor = col,
            frame = { x = 8.7, y = 1, w = 2.6, h = 2.6 } }               -- tip
  cc[4] = { type = "oval", action = "fill", fillColor = { alpha = 1 },
            compositeRule = "destinationOut",
            frame = { x = 6.8, y = 9.8, w = 2.4, h = 3.4 } }             -- eye L
  cc[5] = { type = "oval", action = "fill", fillColor = { alpha = 1 },
            compositeRule = "destinationOut",
            frame = { x = 10.8, y = 9.8, w = 2.4, h = 3.4 } }            -- eye R
  local img = cc:imageFromCanvas()
  if fill == "template" then img = img:template(true) end
  return img
end

local icons = {
  idle = alienImage("template"),
  rec  = alienImage({ red = 1.0,  green = 0.36, blue = 0.36, alpha = 1 }),
  work = alienImage({ red = 0.72, green = 0.52, blue = 1.0,  alpha = 1 }),
}

local function setUI(mode)
  if menubar then
    local key = (mode == "lock") and "rec" or mode
    menubar:setIcon(icons[key] or icons.idle, mode == "idle")
  end
  if mode == "rec" or mode == "lock" then hudShow("rec")
  elseif mode == "work" then hudShow("work")
  else hudHide() end
end

local function reset()
  state, locked, pendingTap = "idle", false, false
  duckUp()
  if timers.maxRec then timers.maxRec:stop() end
  if timers.stuckKey then timers.stuckKey:stop() end
  os.remove(C.wav); os.remove(C.wavNorm)  -- privacy: no voice residue on disk
  setUI("idle")
end

-- ---------------- whisper server (keeps model in RAM) --------
local function serverRunning()
  -- [r] trick: the pattern won't match its own shell command line
  local p = io.popen("/usr/bin/pgrep -f 'whisper-serve[r].*" .. C.serverPort .. "' 2>/dev/null")
  local out = p:read("*a"); p:close()
  return out ~= nil and out ~= ""
end

local function ensureServer()
  if C.whisperHost ~= "127.0.0.1" then return end  -- thin client: server is remote
  if serverRunning() then return end
  M.serverTask = hs.task.new(C.whisperSrv, function(code)
    log("whisper-server exited (code " .. tostring(code) .. ")")
  end, {
    "-m", C.model, "--host", C.serverBind, "--port", tostring(C.serverPort),
    "-t", C.threads, "-l", C.language, "--prompt", fullVocabulary(),
    "--carry-initial-prompt",  -- keep vocabulary active past 30s of speech
  })
  M.serverTask:start()
  log("whisper-server starting on " .. C.serverBind .. ":" .. C.serverPort)
end

-- ---------------- context capture ---------------------------
local function captureContext()
  local app = hs.application.frontmostApplication()
  local win = hs.window.focusedWindow()
  context = {
    app   = app and app:name() or "unknown app",
    title = win and win:title() or "",
  }
end

-- ---------------- paste result -------------------------------
local lastPasteTail, lastPasteApp = nil, nil

-- last 10 pastes, newest first — an app eating your dictation shouldn't
-- mean the words are gone; the menubar can re-paste any of them
local pasteHistory = {}

local function rememberPaste(text)
  table.insert(pasteHistory, 1, text)
  if #pasteHistory > 10 then table.remove(pasteHistory) end
end

local function insertText(text)
  -- smart spacing: consecutive dictations into the same app shouldn't
  -- produce "everything.Distribution" — bridge the gap ourselves
  if C.autoSpace and lastPasteApp == context.app
     and lastPasteTail and lastPasteTail:find("[%.!%?…;:,%)\"']")
     and text:find("^[%w\"'%(%[]") then
    text = " " .. text
  end
  lastPasteTail, lastPasteApp = text:sub(-1), context.app

  rememberPaste(text)
  local prev = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  if not C.keepInClipboard then
    -- restore what the user had copied — but only if the clipboard still
    -- holds OUR text (never stomp something they copied in the meantime)
    timers.clipRestore = hs.timer.doAfter(0.8, function()
      if prev and hs.pasteboard.getContents() == text then
        hs.pasteboard.setContents(prev)
      end
    end)
  end
  play("done")
  rememberText(text, nextMemMode)         -- the alien remembers
  nextMemMode = "dictate"
  -- idle everything, but let the alien react to what you said first
  state, locked, pendingTap = "idle", false, false
  duckUp()
  if timers.maxRec then timers.maxRec:stop() end
  if menubar then menubar:setIcon(icons.idle, true) end
  hudEmote(detectEmotion(text))
  -- keep ONLY this clip (private 0700 scratch, replaced each dictation):
  -- when words get dropped we can replay the actual audio instead of
  -- guessing. Cancelled recordings are still deleted outright.
  os.rename(C.wav, tmp("last-dictation.wav")); os.remove(C.wavNorm)
end

-- ---------------- LLM cleanup --------------------------------
local function cleanLLMOutput(s)
  s = s:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
  -- models love appending meta-commentary; strip trailing "Note:" paragraphs
  s = s:gsub("\n+%s*%(?[Nn]ote:.*$", "")
  s = s:gsub("\n+%s*%(?[Tt]ranslation [Nn]ote.*$", "")
  -- Strip trailing horizontal-rule separators (---, ***, ===, ___) and any
  -- orphan quote/apostrophe/backtick chars models leave hanging. Three
  -- passes because the model sometimes stacks them, e.g. [...text." ---- '"]
  for _ = 1, 3 do
    s = s:gsub("[%s\n]*[%-=*_]+%s*$", "")
    s = s:gsub("[%s\n'\"`\u{2018}\u{2019}\u{201C}\u{201D}]+$", "")
  end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s:sub(1, 1) == '"' and s:sub(-1) == '"' then s = s:sub(2, -2) end
  return s
end

-- generic local-LLM generation (smart reply, expand) — pastes the result
local function llmGenerate(prompt, label, complex, deliver)
  if CORES <= 2 and ollamaIsLocal() and not C.forceLocalLLM then
    hs.alert.show("Vox: " .. label .. " needs a brain — point ollamaUrl at a"
      .. " fast Mac on your LAN (see local.example.lua), or set"
      .. " forceLocalLLM=true and use a tiny model like llama3.2:1b", 5)
    reset()
    return
  end
  reqId = reqId + 1
  local myId, done = reqId, false
  local model = pickModel(label, complex)
  log(label .. " using " .. model)
  local body = hs.json.encode({
    model = model, stream = false, prompt = prompt,
    keep_alive = "24h",
    options = { temperature = (label == "reply") and 0.4 or 0.6 },
  })
  local tmo = C.llmTimeout + (model == C.models.smart and 40 or 20)
  timers.llmTimeout = hs.timer.doAfter(tmo, function()
    if not done and myId == reqId then
      done = true
      hs.alert.show("Vox: " .. label .. " timed out", 3)
      reset()
    end
  end)
  hs.http.asyncPost(C.ollamaUrl, body,
    { ["Content-Type"] = "application/json" },
    function(status, respBody)
      if done or myId ~= reqId then return end
      done = true
      if status == 200 then
        local ok, parsed = pcall(hs.json.decode, respBody)
        local out = ok and parsed and parsed.response and cleanLLMOutput(parsed.response)
        if out and #out > 0 then
          if deliver then
            deliver(out)
          else
            nextMemMode = label
            insertText(out)
          end
          return
        end
      end
      hs.alert.show("Vox: " .. label .. " failed — is Ollama running?", 3)
      reset()
    end)
end

-- the alien knows who it speaks for: ~/vox/identity.md (local, untracked)
-- is injected into reply/expand prompts so output sounds like YOU and knows
-- your history. Edit it anytime; read fresh on every use.
local function identityNotes()
  local f = io.open(HOME .. "/vox/identity.md", "r")
  if not f then return "" end
  local s = f:read("*a") or ""
  f:close()
  return s:sub(1, 900)
end

local function expandPrompt(note, mem)
  return table.concat({
    "Expand the following spoken note into polished written content, in the",
    "speaker's own voice — clear, direct, punchy. Structure it well; 2-4 short",
    "paragraphs unless the note implies otherwise. Do NOT invent facts they",
    "didn't say; amplify, sharpen, and organize what they DID say.",
    "They are writing in the app \"" .. context.app .. "\" — match that medium.",
    (identityNotes() ~= "" and
      ("About the writer (their own identity notes):\n" .. identityNotes())
      or ""),
    (mem and mem ~= "" and
      ("Possibly relevant notes from the user's own local memory (use only"
       .. " if genuinely helpful):\n" .. mem) or ""),
    "Output ONLY the content. No preamble, no notes.",
    "",
    "Spoken note:",
    note,
  }, "\n")
end

-- "Hey Vox, ..." — ask the alien; it answers from its own memory
local function askPrompt(q, mem)
  return table.concat({
    "Answer the user's question in 1-3 concise sentences, speaking directly",
    "to them. Their own local notes are the primary source of truth.",
    "IMPORTANT: the user is the person in 'About the user'. People named in",
    "the notes (clients, doctors, contacts) are OTHER people — never confuse",
    "them with the user.",
    (identityNotes() ~= "" and ("About the user:\n" .. identityNotes()) or ""),
    (mem ~= "" and ("Their local memory notes:\n" .. mem) or ""),
    "If the notes don't fully answer it, say what IS known and name the gap.",
    "Output ONLY the answer. No preamble.",
    "",
    "Question:",
    q,
  }, "\n")
end

local function answerDeliver(question)
  return function(answer)
    hs.pasteboard.setContents(answer)          -- ⌘V pastes it if wanted
    hs.alert.show("👽 " .. answer:sub(1, 400), 9)
    rememberText("Q: " .. question .. " — A: " .. answer, "answer")
    play("done")
    state, locked, pendingTap = "idle", false, false
    duckUp()
    if menubar then menubar:setIcon(icons.idle, true) end
    hudEmote("excite")
  end
end

-- Screen OCR is a vertical wall of UI chrome — menus, unread counters, nav
-- links, truncated edge labels. Fed raw to the LLM it produces vague, off-
-- target replies. Shed the slop: keep only lines that read like real content
-- (a sentence, or a substantial 5+ word phrase) and are mostly letters.
-- Mirrors mem.py clean_ocr so memory and replies see the same clean signal.
local function cleanScreenText(raw)
  local good = {}
  for ln in (raw .. "\n"):gmatch("(.-)\n") do
    local s = ln:gsub("^[%s%p]+", ""):gsub("[%s|]+$", "")
    if #s >= 10 then
      local _, letters = s:gsub("%a", "")
      local wc = 0
      for _ in s:gmatch("%a%a+") do wc = wc + 1 end
      local sentence = s:find("[%.%?!][\"'%)]?$") ~= nil
      if letters >= #s * 0.6 and ((sentence and wc >= 3) or wc >= 5) then
        good[#good + 1] = s
      end
    end
  end
  return (table.concat(good, " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The user's actual selection is the truest signal of "what they're looking
-- at / want a reply to". Read it via the accessibility API (no clipboard
-- clobber). Best-effort — any failure just falls back to cleaned screen OCR.
local function selectedText()
  local ok, sel = pcall(function()
    local ax = require("hs.axuielement")
    local sys = ax.systemWideElement()
    local focused = sys and sys:attributeValue("AXFocusedUIElement")
    return focused and focused:attributeValue("AXSelectedText")
  end)
  if ok and type(sel) == "string" then
    local t = sel:gsub("^%s+", ""):gsub("%s+$", "")
    if #t >= 3 then return t:sub(1, 4000) end
  end
  return nil
end

-- Read ONLY the one window the user is working in — never the whole display.
-- A full-screen grab (-m) sweeps in notification banners, other apps, and the
-- wallpaper, which then leak into the reply. Fall through the frontmost app's
-- focused/main window; return nil if we truly can't isolate one (the caller
-- then declines rather than grabbing the whole screen).
local function targetWindowId()
  local win = hs.window.focusedWindow()
  if not win then
    local app = hs.application.frontmostApplication()
    win = app and (app:focusedWindow() or app:mainWindow())
  end
  return win and win:id()
end

-- triple-tap: read the ACTIVE window, draft the best reply at the cursor
local function smartReply()
  if state ~= "idle" then return end
  state = "processing"
  captureContext()
  local sel = selectedText()           -- grab the selection NOW, before focus moves
  setUI("work")
  play("start")
  local wid  = targetWindowId()
  local shot, ocrOut = tmp("screen.png"), tmp("ocr.txt")
  local ocrBin = HOME .. "/vox/ocr-bin"
  -- capture ONLY the target window (-l <id> excludes overlaid notifications).
  -- No window to isolate? Read nothing rather than grabbing the whole screen —
  -- the reply then rests on the selection, or we tell the user to click in.
  local cmd = wid and string.format(
    "[ -x %s ] || /usr/bin/swiftc -O %s -o %s 2>/dev/null; " ..
    "/usr/sbin/screencapture -x -l %d %s && %s %s > %s 2>/dev/null",
    ocrBin, HOME .. "/vox/ocr.swift", ocrBin, wid, shot, ocrBin, shot, ocrOut)
    or "true"
  M.replyTask = hs.task.new("/bin/sh", function()
    local f = io.open(ocrOut, "r")
    local rawScreen = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(shot); os.remove(ocrOut)   -- privacy: no screen residue
    -- shed the slop immediately; keep raw only as a thin fallback
    local screenText = cleanScreenText(rawScreen:sub(1, 8000))
    if #screenText:gsub("%s", "") < 40 then screenText = rawScreen:sub(1, 3000) end
    -- with no selection AND no readable window, there's nothing to reply to
    if not sel and #screenText:gsub("%s", "") < 20 then
      hs.alert.show(wid and ("Vox: couldn't read the window (grant Screen"
        .. " Recording to Hammerspoon in Privacy & Security)")
        or "Vox: click into the window you want a reply in, then triple-tap", 4)
      reset()
      return
    end
    -- the key context is the selection if present, else the cleaned screen
    local focus = sel or screenText
    local _, qs = focus:gsub("%?", "")
    local complex = #focus > 1200 or qs >= 2
    -- the alien consults its memory about the key context before replying
    memoryLookup(focus:sub(-350):gsub("[^%w%s%-']", ""), 3, function(mem)
      llmGenerate(table.concat({
        "You are drafting a reply ON BEHALF of the user; they will send it as",
        "their own message. Reply to the KEY MESSAGE below — be specific to it,",
        "match its tone and language, stay natural and concise, sound human.",
        "Do not respond to UI labels, menus, or navigation — only the real",
        "message/conversation.",
        (sel and ("The user SELECTED this exact text — reply to THIS"
          .. " specifically:\n" .. sel) or
          ("Cleaned message/conversation from their screen (app: \""
           .. context.app .. "\"), most recent part matters most:\n" .. screenText)),
        (sel and screenText ~= "" and ("Surrounding screen context (secondary,"
          .. " use only if it helps):\n" .. screenText:sub(1, 1500)) or ""),
        (identityNotes() ~= "" and
          ("You are replying AS this person — their own identity notes:\n"
           .. identityNotes()) or ""),
        (mem ~= "" and
          ("The user's own local memory has possibly relevant notes (use only"
           .. " if genuinely helpful):\n" .. mem) or ""),
        "Output ONLY the reply text. No preamble, no quotes, no notes.",
      }, "\n"), "reply", complex)
    end)
  end, { "-c", cmd })
  M.replyTask:start()
end

local function llmPostProcess(raw)
  reqId = reqId + 1
  local myId = reqId
  local done = false

  local tasks = {}
  if C.llmCleanup then
    tasks[#tasks + 1] = "Fix punctuation, capitalization, sentence breaks, and obvious transcription errors."
    tasks[#tasks + 1] = "Remove filler words (um, uh, you know, like when used as filler)."
  else
    tasks[#tasks + 1] = "Keep punctuation readable, but do not rewrite beyond what is necessary."
  end
  if C.translateTo ~= "off" then
    tasks[#tasks + 1] = "Translate the final output into " .. C.translateTo .. "."
  end

  local prompt = table.concat({
    "You post-process raw speech-to-text dictation output.",
    table.concat(tasks, "\n"),
    "Keep the speaker's exact wording and meaning. Do NOT paraphrase, summarize, answer, or add anything.",
    "Preserve technical terms and brand names exactly: " .. C.vocabulary,
    "The user is dictating into the app \"" .. context.app .. "\""
      .. (context.title ~= "" and (" (window: \"" .. context.title .. "\")") or "")
      .. ". Match the formatting to that context.",
    "The app/window info is CONTEXT ONLY — never include it in the output, and never add a subject line, greeting, or signature the speaker did not say.",
    "Return ONLY the final text. No preamble, no quotes, no explanation,"
      .. " and NEVER append a note or commentary after it.",
    "",
    "Raw dictation:",
    raw,
  }, "\n")

  local model = pickModel(C.translateTo ~= "off" and "translate" or "cleanup")
  local body = hs.json.encode({
    model  = model,
    stream = false,
    prompt = prompt,
    keep_alive = "24h",           -- keep model in RAM, no cold-start lag
    options = { temperature = 0.1 },
  })

  -- fallback: paste raw if Ollama is slow or down
  -- (translation + the smart model earn extra headroom — timeout pastes English)
  local tmo = C.llmTimeout
      + (C.translateTo ~= "off" and 10 or 0)
      + (model == C.models.smart and 15 or 0)
  timers.llmTimeout = hs.timer.doAfter(tmo, function()
    if not done and myId == reqId then
      done = true
      log("LLM timeout — pasting raw transcript")
      insertText(raw)
    end
  end)

  hs.http.asyncPost(C.ollamaUrl, body,
    { ["Content-Type"] = "application/json" },
    function(status, respBody)
      if done or myId ~= reqId then return end
      done = true
      if status == 200 then
        local ok, parsed = pcall(hs.json.decode, respBody)
        local out = ok and parsed and parsed.response and cleanLLMOutput(parsed.response)
        if out and #out > 0 then
          insertText(out)
          return
        end
      end
      log("LLM post-process failed (status " .. tostring(status) .. ") — pasting raw")
      insertText(raw)
    end)
end

-- ---------------- transcription ------------------------------
-- case-insensitive brand/jargon fixes; " " in keys also matches "-" and "  "
local function applyCorrections(text)
  for wrong, right in pairs(C.corrections) do
    local pat = wrong:gsub("%a", function(ch)
      return "[" .. ch:lower() .. ch:upper() .. "]"
    end):gsub(" ", "[%%s%%-]+")
    text = text:gsub("%f[%w]" .. pat .. "%f[%W]", right)
  end
  return text
end

-- deterministic filler removal: "uh"/"um" and friends vanish, punctuation
-- and capitalization get repaired. Conservative list — real words are safe.
local FILLERS = { "uh", "uhh", "uhhh", "um", "umm", "ummm", "uhm", "erm", "ehm" }
local function cleanFillers(text)
  if not C.fillerFilter then return text end
  for _, f in ipairs(FILLERS) do
    local pat = f:gsub("%a", function(ch)
      return "[" .. ch:lower() .. ch:upper() .. "]"
    end)
    text = text:gsub("%f[%w]" .. pat .. "%f[%W][,%.;]?%s*", "")
  end
  text = text:gsub("^%s*[,%.;]%s*", "")        -- orphaned leading punctuation
  text = text:gsub("%s+([,%.;!%?])", "%1")     -- space before punctuation
  text = text:gsub(",%s*,", ",")               -- doubled commas
  text = text:gsub(",%s*([%.!%?;])", "%1")     -- "Good,." -> "Good."
  text = text:gsub("([%.!%?])%s*,", "%1")      -- ". ," -> "."
  text = text:gsub(",(%a)", ", %1")            -- ",word" -> ", word" (not 1,000)
  text = text:gsub("%s%s+", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("^(%l)", string.upper)      -- repair sentence starts
  text = text:gsub("([%.!%?]%s+)(%l)", function(a, b) return a .. b:upper() end)
  return text
end

-- Whisper sometimes loops one sentence over and over on unclear audio
-- ("I'm going to use the same thing..." x8). Keep at most 2 consecutive
-- identical sentences; collapse the rest.
local function collapseRepeats(text)
  local parts = {}
  for s in text:gmatch("[^%.!%?]+[%.!%?]?%s*") do parts[#parts + 1] = s end
  local out, lastNorm, count = {}, nil, 0
  for _, s in ipairs(parts) do
    local norm = s:lower():gsub("[%p%s]+", " ")
                  :gsub("^%s+", ""):gsub("%s+$", "")
    if norm ~= "" and norm == lastNorm then
      count = count + 1
      if count < 2 then out[#out + 1] = s end
    else
      lastNorm, count = norm, 0
      out[#out + 1] = s
    end
  end
  return table.concat(out)
end

-- spoken commands: deterministic, punctuation-gated so normal speech
-- ("the new line of products") is never mangled
local function applyVoiceCommands(text)
  if not C.voiceCommands then return text, false end
  local bare = text:lower():gsub("^%s+", ""):gsub("[%p%s]+$", "")
  if bare == "scratch that" or bare == "undo that" or bare == "delete that" then
    return "", true
  end
  text = text:gsub("%s*[Nn]ew [Pp]aragraph[%.,:]%s*", "\n\n")
  text = text:gsub("%s*[Nn]ew [Pp]aragraph%s*$", "\n\n")
  text = text:gsub("%s*[Nn]ew [Ll]ine[%.,:]%s*", "\n")
  text = text:gsub("%s*[Nn]ew [Ll]ine%s*$", "\n")
  return text, false
end

local function handleTranscript(raw, t0)
  local text = raw:gsub("%[BLANK_AUDIO%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("%s*\n%s*", " ")            -- server returns wrapped lines
  text = applyCorrections(text)
  text = cleanFillers(text)
  text = collapseRepeats(text)
  local undo
  text, undo = applyVoiceCommands(text)
  if undo then
    hs.eventtap.keyStroke({ "cmd" }, "z", 0)   -- undo the last paste
    play("done")
    hs.alert.show("↩︎ scratched", 1)
    reset()
    return
  end
  learnFrom(text)                              -- vocabulary compounds over time
  log(string.format("whisper done in %.1fs: %s",
      hs.timer.secondsSinceEpoch() - t0, text:sub(1, 80)))
  if #text == 0 then reset() return end
  if CORES <= 2 and ollamaIsLocal() and not C.forceLocalLLM
     and (recMode == "expand" or C.llmCleanup or C.translateTo ~= "off") then
    recMode = "dictate"
    log("ancient hardware + local LLM: skipping LLM features, pasting raw")
    insertText(text)                 -- never lose the user's words
    return
  end
  local ql = text:lower()
  local qs = ql:match("^hey,?%s*vox[,!%.%s]+()") or ql:match("^hey,?%s*alien[,!%.%s]+()")
  if qs then
    local rest = text:sub(qs)
    -- "Hey Vox, remember (that) ..." — save a fact to the brain, no paste
    local fact = rest:match("^[Rr]emember%s+that%s+(.+)")
              or rest:match("^[Rr]emember%s+(.+)")
    if fact and #fact > 2 then
      context.app = "Hey Vox"
      rememberText(fact:gsub("%s+$", ""), "note")
      play("done")
      hs.alert.show("🧠 got it — remembered", 2)
      hudEmote("excite")
      state, locked, pendingTap = "idle", false, false
      duckUp()
      if menubar then menubar:setIcon(icons.idle, true) end
      return
    end
    if #rest > 3 then                -- otherwise it's a question
      memoryLookup(rest, 5, function(mem)
        llmGenerate(askPrompt(rest, mem), "answer", true, answerDeliver(rest))
      end)
      return
    end
  end
  if recMode == "expand" then
    recMode = "dictate"
    llmGenerate(expandPrompt(text), "expand")
  elseif C.llmCleanup or C.translateTo ~= "off" then
    llmPostProcess(text)
  else
    insertText(text)
  end
end

-- slow path: only used if the server is down (also restarts it)
local function transcribeCLI(t0)
  M.sttTask = hs.task.new(C.whisper, function(code, out, err)
    if code ~= 0 then
      log("whisper-cli failed: " .. tostring(err))
      hs.alert.show("Vox: transcription failed")
      reset()
      return
    end
    handleTranscript(out, t0)
  end, {
    "-m", C.model, "-f", C.wavNorm, "-nt", "-np",
    "-l", C.language, "-t", C.threads, "--prompt", fullVocabulary(),
  })
  M.sttTask:start()
end

local function transcribe()
  local attr = hs.fs.attributes(C.wav)
  if not attr or attr.size < C.minBytes then
    log("recording too short, ignoring")
    reset()
    return
  end

  local t0 = hs.timer.secondsSinceEpoch()
  -- timeout scales with recording length AND machine speed: a 2-core Intel
  -- gets ~4x realtime headroom, Apple Silicon barely needs 1x
  local durSecs  = math.max(1, (attr.size - 44) / 32000)
  local factor   = IS_ARM and 1.5 or (CORES <= 2 and 6 or 3)
  local maxTime  = math.ceil(20 + durSecs * factor)

  -- vocabulary for THIS dictation: saved words + what's visible on screen
  local promptStr = fullVocabulary()
  local cf = io.open(tmp("ctx.txt"), "r")
  if cf then
    local ctxText = cf:read("*a") or ""
    cf:close()
    os.remove(tmp("ctx.txt"))                -- privacy: single use
    -- ONLY true proper nouns (absent from the dictionary) may enter the
    -- prompt. Title Case marketing copy ("Qualified Leads On Autopilot")
    -- used to flood it and Whisper mimicked the style — Adam got a whole
    -- transcript As, A, Comma, Separated, Title, Case, List
    local seen, words, len = {}, {}, 0
    for raw in ctxText:gmatch("%u[%w'%-]+") do
      local w = raw:gsub("[^%w%-']", "")
      if #w >= 3 and not seen[w:lower()] and not isCommonWord(w:lower()) then
        seen[w:lower()] = true
        len = len + #w + 2
        if len > 140 then break end
        words[#words + 1] = w
      end
    end
    if #words > 0 then
      promptStr = promptStr .. " " .. table.concat(words, ", ")
    end
  end
  promptStr = promptStr:gsub('[\\"$`]', "")  -- shell-safe in double quotes

  -- clean + normalize quiet mics, then hit the persistent server
  local langArg = (C.language ~= "auto")
      and (" -F language=" .. C.language) or ""
  local cmd = string.format(
    -- trailing-silence trim (reverse/silence/reverse) kills Whisper's
    -- phantom "Yeah." hallucination on the breath after key-release.
    -- Gentle on purpose: 0.6%/0.3s — last words trail off quietly and the
    -- old 1.5%/0.15s ate them as "silence"; the pad keeps Whisper from
    -- clipping the decode at the cut
    "%s %s %s highpass 80 norm -3 reverse silence 1 0.30 0.6%% reverse" ..
    " pad 0 0.15 2>/dev/null || cp %s %s; " ..
    "/usr/bin/curl -s --max-time %d -F file=@%s -F temperature=0.0 " ..
    "-F prompt=\"%s\" -F response_format=text%s http://%s:%d/inference",
    C.sox, C.wav, C.wavNorm, C.wav, C.wavNorm, maxTime, C.wavNorm,
    promptStr, langArg, C.whisperHost, C.serverPort)

  M.sttTask = hs.task.new("/bin/sh", function(code, out, err)
    local ok = (code == 0) and out and #out:gsub("%s", "") > 0
               and not out:find('"error"')
    if ok then
      noteTranscribeSuccess(hs.timer.secondsSinceEpoch() - t0)
      handleTranscript(out, t0)
    elseif C.whisperHost ~= "127.0.0.1" then
      noteRemoteFail()
      -- remote brain unreachable: fall back to the local model if we have one
      if hs.fs.attributes(C.model) then
        log("remote server unreachable — falling back to local whisper-cli")
        transcribeCLI(t0)
      else
        hs.alert.show("Vox: transcription server " .. C.whisperHost
          .. " unreachable — is the fast Mac awake?", 4)
        reset()
      end
    else
      log("server unavailable — falling back to whisper-cli and restarting server")
      ensureServer()
      transcribeCLI(t0)
    end
  end, { "-c", cmd })
  M.sttTask:start()
end

-- ---------------- recording ----------------------------------
local function startRecording()
  if state ~= "idle" then return end
  state = "recording"
  captureContext()
  os.remove(C.wav)
  recGen = recGen + 1
  local myGen = recGen
  recTask = hs.task.new(C.sox, function(code, _, _)
    -- only transcribe if THIS recording ended intentionally (not cancelled)
    if state == "processing" and myGen == recGen then transcribe() end
  end, { "-q", "-d", "-c", "1", "-r", "16000", "-b", "16", C.wav })
  recTask:start()
  -- screen-aware dictation: OCR the target window WHILE recording (free time)
  if C.screenContext and CORES > 2 then
    local win = hs.window.focusedWindow()
    local wid = win and win:id()
    if wid then
      local ocrBin = HOME .. "/vox/ocr-bin"
      local ctxPng, ctxTxt = tmp("ctx.png"), tmp("ctx.txt")
      M.ctxTask = hs.task.new("/bin/sh", nil, { "-c", string.format(
        "[ -x %s ] && /usr/sbin/screencapture -x -l %d %s" ..
        " 2>/dev/null && %s %s > %s 2>/dev/null;" ..
        " rm -f %s", ocrBin, wid, ctxPng, ocrBin, ctxPng, ctxTxt, ctxPng) })
      M.ctxTask:start()
    end
  end
  duckDown()
  setUI("rec")
  play("start")
  -- safety: a forgotten locked recording stops itself
  timers.maxRec = hs.timer.doAfter(C.maxRecordSecs, function()
    if state == "recording" then
      hs.alert.show("Vox: auto-stopped after "
        .. math.floor(C.maxRecordSecs / 60) .. " min", 3)
      locked = false
      stopRecording()
    end
  end)
  -- sticky-key watchdog: macOS sometimes drops the key-release event; if the
  -- key is no longer physically held, stop instead of recording forever
  timers.stuckKey = hs.timer.doEvery(1.0, function()
    if state == "recording" and not locked and not pendingTap then
      local mods = hs.eventtap.checkKeyboardModifiers()
      local held = ((C.holdKeycode == 61 or C.holdKeycode == 58) and mods.alt)
                or ((C.holdKeycode == 54 or C.holdKeycode == 55) and mods.cmd)
      if not held and (hs.timer.secondsSinceEpoch() - keyDownAt) > 1.2 then
        log("missed key-release detected — stopping recording")
        stopRecording()
      end
    end
  end)
  log("recording started (" .. context.app .. ")")
end

local function cancelRecording()
  if state ~= "recording" then return end
  state = "idle"
  recGen = recGen + 1            -- invalidates the recorder's exit callback
  if recTask and recTask:isRunning() then recTask:terminate() end
  reset()
end

local function stopRecording()
  if state ~= "recording" then return end
  state = "processing"
  if timers.maxRec then timers.maxRec:stop() end
  if timers.stuckKey then timers.stuckKey:stop() end
  setUI("work")
  duckUp()                       -- music fades back while we transcribe
  play("stop")
  -- tail grace: people release the key WHILE saying the last word — keep
  -- the mic open a beat longer so its final syllables actually get recorded
  timers.tailGrace = hs.timer.doAfter(C.tailGrace, function()
    if recTask and recTask:isRunning() then
      recTask:interrupt()        -- SIGINT lets sox finalize the WAV
    else
      transcribe()
    end
  end)
end

-- the mini alien's three powers
local function miniStart(mode)
  if state == "idle" then
    keyDownAt = hs.timer.secondsSinceEpoch()
    recMode = mode
    startRecording()
    locked = true
    lockAt = hs.timer.secondsSinceEpoch()
    setUI("lock")
  elseif state == "recording" and locked then
    locked = false
    stopRecording()
  end
end
mini.act.talk    = function() miniStart("dictate") end
mini.act.content = function()
  if state == "idle" then hs.alert.show("🎨 content mode — speak, click to finish", 2) end
  miniStart("expand")
end
mini.act.grab = function()
  local wid = targetWindowId()
  local app = hs.application.frontmostApplication()
  local appName = app and app:name() or "screen"
  if not wid then
    hs.alert.show("Vox: click into the window you want to absorb first", 3)
    return
  end
  local ocrBin = HOME .. "/vox/ocr-bin"
  hs.alert.show("📸 absorbing window…", 1)
  local grabPng, grabTxt = tmp("grab.png"), tmp("grab.txt")
  M.grabTask = hs.task.new("/bin/sh", function()
    local f = io.open(grabTxt, "r")
    local txt = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(grabTxt)
    txt = txt:sub(1, 6000)
    if #txt:gsub("%s", "") < 20 then
      hs.alert.show("Vox: nothing readable (Screen Recording granted?)", 3)
      return
    end
    context.app = appName
    rememberText(txt, "grab")
    hs.alert.show("🧠 absorbed into memory ✓", 2)
  end, { "-c", string.format(
    "[ -x %s ] || /usr/bin/swiftc -O %s -o %s 2>/dev/null; " ..
    "/usr/sbin/screencapture -x -l %d %s && %s %s" ..
    " > %s 2>/dev/null; rm -f %s",
    ocrBin, HOME .. "/vox/ocr.swift", ocrBin,
    wid, grabPng, ocrBin, grabPng, grabTxt, grabPng) })
  M.grabTask:start()
end

-- ---------------- hotkey: hold-to-talk + tap-to-lock ---------
local flagTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  if e:getKeyCode() ~= C.holdKeycode then return false end
  local pressed = e:getFlags().alt or e:getFlags().cmd  -- covers ⌥ or ⌘ keys

  if pressed then
    if state == "recording" and locked then
      locked = false
      if (hs.timer.secondsSinceEpoch() - lockAt) < C.doubleTapWindow then
        cancelRecording()        -- third rapid tap: smart-reply from screen
        smartReply()
      else
        stopRecording()          -- tap ends a locked recording
      end
    elseif state == "recording" and pendingTap then
      pendingTap = false         -- second tap of a double-tap: lock on
      if timers.tapWait then timers.tapWait:stop() end
      locked = true
      lockAt = hs.timer.secondsSinceEpoch()
      setUI("lock")
    elseif state == "idle" then
      keyDownAt = hs.timer.secondsSinceEpoch()
      recMode = e:getFlags().shift and "expand" or "dictate"
      startRecording()
    end
  else -- released
    if state == "recording" and not locked then
      if (hs.timer.secondsSinceEpoch() - keyDownAt) >= C.tapLockMax then
        stopRecording()          -- normal push-to-talk release
      else
        -- quick tap: recording continues briefly awaiting a second tap
        -- (double-tap = hands-free lock); no second tap = discard quietly
        pendingTap = true
        timers.tapWait = hs.timer.doAfter(C.doubleTapWindow, function()
          if pendingTap then
            pendingTap = false
            cancelRecording()
          end
        end)
      end
    end
  end
  return false
end)

-- ---------------- pipeline self-test --------------------------
-- Synthesized speech through the REAL transcription path; pass = lock in.
local selfTesting = false
local function selfTest(interactive)
  if selfTesting or state ~= "idle" then return end
  selfTesting = true
  local wav = tmp("selftest.wav")
  local aiff = tmp("selftest.aiff")
  local cmd = string.format(
    "/usr/bin/say -o %s 'vox self test passed' && " ..
    "%s %s -r 16000 -c 1 -b 16 %s 2>/dev/null && " ..
    "rm -f %s && " ..
    "/usr/bin/curl -s --max-time %d -F file=@%s -F temperature=0.0 " ..
    "-F response_format=text -F language=en http://%s:%d/inference",
    aiff, C.sox, aiff, wav, aiff, (CORES <= 2 and 120 or 30), wav,
    C.whisperHost, C.serverPort)
  local t0 = hs.timer.secondsSinceEpoch()
  M.selfTestTask = hs.task.new("/bin/sh", function(code, out)
    selfTesting = false
    os.remove(wav)
    local secs = hs.timer.secondsSinceEpoch() - t0
    local ok = (code == 0) and out
               and out:lower():gsub("[%-%.]", " "):find("self%s+test") ~= nil
    if ok then
      noteTranscribeSuccess(secs)
      log(string.format("pipeline self-test PASSED in %.1fs via %s",
          secs, C.whisperHost))
      -- engine decay: a pass far slower than our best means the long-running
      -- server has degraded — refresh it and re-verify (found empirically:
      -- ~12h-old servers drift 1s -> 9s; a restart fully restores them).
      -- Floor is 3.2s, not 4.5: the drift plateaus around 4.1s on fast Macs
      -- and sat under the old threshold for hours at double latency. Slow
      -- Macs stay protected by the best*2 term (tiny-model best ~4s -> 8s).
      if C.whisperHost == "127.0.0.1" and calib.bestLatency
         and secs > math.max(3.2, calib.bestLatency * 2) and not M.refreshing then
        M.refreshing = true
        log(string.format("engine slow (%.1fs vs best %.1fs) — refreshing",
            secs, calib.bestLatency))
        os.execute("/usr/bin/pkill -f 'whisper-serve[r].*" .. C.serverPort .. "'")
        timers.refresh1 = hs.timer.doAfter(2, ensureServer)
        timers.refresh2 = hs.timer.doAfter(30, function()
          M.refreshing = false
          selfTest(false)
        end)
      end
      if interactive then
        hs.alert.show(string.format("Vox verified ✓ %.1fs (%s)", secs,
          calib.mode), 3)
      end
    else
      log("pipeline self-test FAILED via " .. C.whisperHost)
      if C.whisperHost ~= "127.0.0.1" then
        noteRemoteFail()               -- may lock to local
        timers.selfRetry = hs.timer.doAfter(3, function() selfTest(interactive) end)
      else
        ensureServer()                 -- server may have died; heal + retry once
        if not timers.selfHealed then
          timers.selfHealed = hs.timer.doAfter(15, function()
            timers.selfHealed = nil
            selfTest(interactive)
          end)
        elseif interactive then
          hs.alert.show("Vox: self-test failing — run: bash ~/vox/doctor.sh", 5)
        end
      end
    end
  end, { "-c", cmd })
  M.selfTestTask:start()
end

-- verify automatically after every code update (rev change) — untouched
-- installs stay silent
if calib.verifiedRev ~= currentRev then
  timers.selfTestBoot = hs.timer.doAfter(75, function() selfTest(false) end)
end

-- ---------------- self-update --------------------------------
-- Fast-forward to origin/main; fleet-wide fixes reach every Mac unattended.
local function checkForUpdates(interactive)
  M.updTask = hs.task.new("/bin/sh", function(code, out)
    out = (out or ""):gsub("%s+$", "")
    if code == 0 and out:find("updated") then
      -- never hot-reload mid-dictation: wait for idle, then apply
      local function applyWhenIdle()
        if state == "idle" then
          hs.alert.show("Vox updated — reloading…", 2)
          timers.updReload = hs.timer.doAfter(1.5, hs.reload)
        else
          timers.updWait = hs.timer.doAfter(20, applyWhenIdle)
        end
      end
      applyWhenIdle()
    elseif code == 0 and out:find("current") then
      if interactive then hs.alert.show("Vox is up to date ✓", 2) end
    else
      if interactive then hs.alert.show("Vox update check failed — see console", 3) end
      log("update check failed: " .. out)
    end
  end, { "-c",
    "cd \"$HOME/vox\" || exit 3; " ..
    -- only ever update from the canonical repo (defense against remote swap).
    -- Both URLs are ours: repo transferred AutomateScaleInc -> AutomateScale
    -- (2026-07-24 account consolidation); the old address 301s to the new
    "R=$(/usr/bin/git remote get-url origin); " ..
    "[ \"$R\" = \"https://github.com/AutomateScale/vox.git\" ] || " ..
    "[ \"$R\" = \"https://github.com/AutomateScaleInc/vox.git\" ] || " ..
    "{ echo wrong-remote; exit 3; }; " ..
    "/usr/bin/git fetch -q origin main && " ..
    "if [ \"$(/usr/bin/git rev-list --count HEAD..origin/main)\" = 0 ]; " ..
    "then echo current; " ..
    "else /usr/bin/git pull -q --ff-only origin main && echo updated || { " ..
    -- upstream history rewritten: self-heal, preserving any local work
    "  if [ -z \"$(/usr/bin/git status --porcelain)\" ]; then " ..
    "    /usr/bin/git branch \"rescue-$(/bin/date +%s)\" >/dev/null 2>&1; " ..
    "    /usr/bin/git reset --hard origin/main >/dev/null 2>&1 && echo updated; " ..
    "  else echo diverged-dirty; fi; }; " ..
    "fi" })
  M.updTask:start()
end
if C.autoUpdate then
  timers.updDaily = hs.timer.doEvery(6 * 3600, function() checkForUpdates(false) end)
  timers.updBoot  = hs.timer.doAfter(90, function() checkForUpdates(false) end)
end

-- ---------------- menubar ------------------------------------
menubar = hs.menubar.new()
menubar:setIcon(icons.idle, true)
menubar:setMenu(function()
  return {
    { title = "Vox — local dictation, by AutomateScale", fn = function()
        hs.urlevent.openURL("https://automatescale.com/vox")
      end },
    { title = "Hold " .. C.holdKeyName .. " to talk · double-tap to lock", disabled = true },
    { title = "Triple-tap: smart reply · Shift+key: expand to content", disabled = true },
    { title = "\"Hey Vox, …\" ask a question · \"Hey Vox, remember …\" save a fact", disabled = true },
    { title = "-" },
    { title = "Recent dictations", menu = (function()
        if #pasteHistory == 0 then
          return { { title = "nothing yet — dictate something", disabled = true } }
        end
        local items = {}
        for _, t in ipairs(pasteHistory) do
          local label = t:gsub("%s+", " ")
          if #label > 60 then label = label:sub(1, 57) .. "…" end
          items[#items + 1] = { title = label, fn = function()
            -- menu click steals focus for a beat; paste after it returns
            timers.repaste = hs.timer.doAfter(0.25, function() insertText(t) end)
          end }
        end
        return items
      end)() },
    { title = "While recording", menu = {
        { title = "Duck audio to 15%", checked = C.duckMode == "duck",
          fn = function() C.duckMode = "duck"; hs.alert.show("Recording: duck audio", 1) end },
        { title = "Mute audio (zero mic bleed)", checked = C.duckMode == "mute",
          fn = function() C.duckMode = "mute"; hs.alert.show("Recording: mute audio", 1) end },
        { title = "Pause media (podcast/music pauses + resumes)", checked = C.duckMode == "pause",
          fn = function() C.duckMode = "pause"; hs.alert.show("Recording: pause media", 1) end },
      } },
    { title = "Hold key", menu = {
        { title = "Right Option", checked = C.holdKeycode == 61,
          fn = function() C.holdKeycode = 61; C.holdKeyName = "Right Option"; hs.alert.show("Vox key: Right Option", 1) end },
        { title = "Right Command", checked = C.holdKeycode == 54,
          fn = function() C.holdKeycode = 54; C.holdKeyName = "Right Command"; hs.alert.show("Vox key: Right Command", 1) end },
        { title = "Left Option", checked = C.holdKeycode == 58,
          fn = function() C.holdKeycode = 58; C.holdKeyName = "Left Option"; hs.alert.show("Vox key: Left Option", 1) end },
        { title = "Left Command", checked = C.holdKeycode == 55,
          fn = function() C.holdKeycode = 55; C.holdKeyName = "Left Command"; hs.alert.show("Vox key: Left Command", 1) end },
      } },
    { title = "Tiny idle alien (click him to dictate)", checked = C.miniAlien,
      fn = function()
        C.miniAlien = not C.miniAlien
        if C.miniAlien then miniShow() else miniHide() end
      end },
    { title = "Keep dictation in clipboard (⌘V re-paste)", checked = C.keepInClipboard,
      fn = function() C.keepInClipboard = not C.keepInClipboard end },
    { title = "Duck music while recording", checked = C.duckAudio,
      fn = function() C.duckAudio = not C.duckAudio end },
    { title = "AI cleanup (slower, may reword)", checked = C.llmCleanup,
      fn = function() C.llmCleanup = not C.llmCleanup end },
    { title = "Translate output", menu = {
        { title = "Off (fastest)", checked = C.translateTo == "off",
          fn = function() C.translateTo = "off"; hs.alert.show("Vox translation: off", 1) end },
        { title = "English", checked = C.translateTo == "English",
          fn = function() C.translateTo = "English"; hs.alert.show("Vox translates to English", 1) end },
        { title = "French", checked = C.translateTo == "French",
          fn = function() C.translateTo = "French"; hs.alert.show("Vox translates to French", 1) end },
        { title = "Spanish", checked = C.translateTo == "Spanish",
          fn = function() C.translateTo = "Spanish"; hs.alert.show("Vox translates to Spanish", 1) end },
        { title = "Dutch", checked = C.translateTo == "Dutch",
          fn = function() C.translateTo = "Dutch"; hs.alert.show("Vox translates to Dutch", 1) end },
      } },
    { title = "Sound theme", menu = {
        { title = "Sleek", checked = C.soundTheme == "sleek",
          fn = function() C.soundTheme = "sleek"; loadSounds(); play("done") end },
        { title = "Classic", checked = C.soundTheme == "classic",
          fn = function() C.soundTheme = "classic"; loadSounds(); play("done") end },
      } },
    { title = "Language", menu = {
        { title = "English (fastest)", checked = C.language == "en",
          fn = function() C.language = "en" end },
        { title = "Français", checked = C.language == "fr",
          fn = function() C.language = "fr" end },
        { title = "Auto-detect (+1s)", checked = C.language == "auto",
          fn = function() C.language = "auto" end },
      } },
    { title = "Pipeline: " .. (calib.mode or "unverified")
        .. (calib.lastLatency and (" · " .. calib.lastLatency .. "s ✓") or ""),
      disabled = true },
    { title = "Verify pipeline now", fn = function()
        calib.forceLocal = nil
        C.whisperHost = configuredHost
        saveCalib()
        selfTest(true)
      end },
    { title = "Check for updates now", fn = function() checkForUpdates(true) end },
    { title = "Run doctor (Terminal)", fn = function()
        hs.task.new("/usr/bin/open", nil,
          { "-b", "com.apple.Terminal", HOME .. "/vox/doctor.sh" }):start()
      end },
    { title = "Open log console", fn = hs.openConsole },
    { title = "-" },
    { title = "Cancel current recording", fn = function()
        if recTask and recTask:isRunning() then recTask:terminate() end
        reset()
      end },
    { title = "AI brain: " .. (lowRam and "fast only (low RAM)"
        or (availableModels[C.models.smart] and "adaptive — fast + smart"
        or "fast only (smart model not pulled)")), disabled = true },
    { title = "Remember dictations (local memory)", checked = C.memory,
      fn = function() C.memory = not C.memory end },
    { title = "Recent dictations", menu = (function()
        if not C.memory then
          return { { title = "(memory is off)", disabled = true } }
        end
        local items = {}
        local p = io.popen("/usr/bin/python3 " .. HOME
                           .. "/vox/mem.py recent -n 8 2>/dev/null")
        if p then
          for line in (p:read("*a") or ""):gmatch("[^\n]+") do
            local ok, e = pcall(hs.json.decode, line)
            if ok and e and e.text and e.mode ~= "ingest" and e.mode ~= "grab" then
              local label = e.text:gsub("%s+", " "):sub(1, 58)
              if #e.text > 58 then label = label .. "…" end
              items[#items + 1] = { title = label, fn = function()
                hs.pasteboard.setContents(e.text)
                hs.eventtap.keyStroke({ "cmd" }, "v", 0)
              end }
            end
          end
          p:close()
        end
        if #items == 0 then
          items[1] = { title = "(nothing yet — dictate something)", disabled = true }
        end
        return items
      end)() },
    { title = "Open memory wiki 👽", fn = function()
        -- weave prints one JSON line per artifact (wiki, then graph)
        M.weaveTask = hs.task.new("/usr/bin/python3", function(code, out)
          local ok, res = pcall(hs.json.decode, (out or ""):match("[^\n]+") or "")
          if code == 0 and ok and res and res.wiki then
            hs.task.new("/usr/bin/open", nil, { res.wiki }):start()
          else
            hs.alert.show("Wiki build failed — see console", 3)
          end
        end, { HOME .. "/vox/mem.py", "weave" })
        M.weaveTask:start()
      end },
    { title = "Open knowledge graph 🕸", fn = function()
        M.graphTask = hs.task.new("/usr/bin/python3", function(code, out)
          local ok, res = pcall(hs.json.decode, (out or ""):match("[^\n]+") or "")
          if code == 0 and ok and res and res.graph then
            hs.task.new("/usr/bin/open", nil, { res.graph }):start()
          else
            hs.alert.show("Graph build failed — see console", 3)
          end
        end, { HOME .. "/vox/mem.py", "graph" })
        M.graphTask:start()
      end },
    { title = "Export brain (to Desktop)", fn = function()
        M.expTask = hs.task.new("/usr/bin/python3", function(code)
          hs.alert.show(code == 0 and "🧠 Brain exported to Desktop ✓"
                                   or "Export failed", 3)
        end, { HOME .. "/vox/mem.py", "export" })
        M.expTask:start()
      end },
    { title = "Learned vocabulary: " .. learnedCount() .. " words", disabled = true },
    { title = "Apply learned words now (restart engine)", fn = function()
        saveLearned()
        invalidateVocab()
        os.execute("/usr/bin/pkill -f 'whisper-serve[r].*" .. C.serverPort .. "'")
        timers.srvVocab = hs.timer.doAfter(1, ensureServer)
        hs.alert.show("Vox: engine restarting with your learned vocabulary", 2)
      end },
    { title = "Restart whisper server", fn = function()
        os.execute("/usr/bin/pkill -f 'whisper-serve[r].*" .. C.serverPort .. "'")
        timers.srvRestart = hs.timer.doAfter(1, ensureServer)
      end },
  }
end)

-- Without Accessibility access macOS silently drops all key events —
-- prompt for it instead of dying quietly.
if not hs.accessibilityState() then
  hs.accessibilityState(true)   -- opens the system permission dialog
  hs.alert.show("Vox needs Accessibility: System Settings > Privacy & Security"
    .. " > Accessibility > enable \"Hammerspoon\" (Vox's engine), then relaunch"
    .. " — hotkey works right after", 8)
end

-- ---------------- keep-warm ----------------------------------
-- After idle, macOS pages the model out of RAM and the first dictation pays
-- a reload tax. A 0.3s silent inference every 15 min keeps it hot, and we
-- warm immediately on wake/unlock — the moments that predict "about to talk".
-- The LLM pays the same reload tax: the first Hey Vox / smart reply after
-- Ollama restarts cold-loads the smart model (~4.7GB) and can blow the
-- timeout. An empty-prompt generate preloads it with keep_alive, so the
-- first real question is always warm. Only on Macs that use the smart model.
local function warmBrain()
  if lowRam or CORES <= 2 or not ollamaIsLocal() then return end
  hs.http.asyncPost(C.ollamaUrl,
    hs.json.encode({ model = C.models.smart, prompt = "",
                     keep_alive = "24h" }),
    { ["Content-Type"] = "application/json" }, function() end)
end

local function warmUp()
  if C.whisperHost ~= "127.0.0.1" then return end
  local warmWav = tmp("warm.wav")
  local cmd = string.format(
    "[ -f %s ] || %s -n -r 16000 -c 1 -b 16 %s" ..
    " trim 0.0 0.3 2>/dev/null; " ..
    "/usr/bin/curl -s --max-time 90 -F file=@%s " ..
    "-F temperature=0.0 -F response_format=text -F language=en " ..
    "http://127.0.0.1:%d/inference >/dev/null 2>&1",
    warmWav, C.sox, warmWav, warmWav, C.serverPort)
  M.warmTask = hs.task.new("/bin/sh", nil, { "-c", cmd })
  M.warmTask:start()
  warmBrain()
  hudDance()          -- heartbeat you can see: a subtle groove per ping
end

M.wakeWatcher = hs.caffeinate.watcher.new(function(ev)
  if ev == hs.caffeinate.watcher.systemDidWake
     or ev == hs.caffeinate.watcher.screensDidUnlock then
    ensureServer()                      -- server may have died during sleep
    timers.warmWake = hs.timer.doAfter(4, warmUp)
  end
end)
M.wakeWatcher:start()
M.screenWatcher = hs.screen.watcher.new(function()
  timers.miniReposition = hs.timer.doAfter(2, function()
    if mini.canvas and mini.canvas:isShowing() then miniShow() end
  end)
end)
M.screenWatcher:start()
timers.warmLoop = hs.timer.doEvery(900, warmUp)
-- daily brain backup — the memory is irreplaceable (it only exists on this
-- disk) so snapshot it to iCloud Drive, keeping the newest 7. In zero-
-- outbound mode (autoUpdate=false) it stays local in ~/vox/backups instead.
local function brainBackup()
  local mode = C.autoUpdate and "" or "local"
  M.backupTask = hs.task.new("/usr/bin/python3", function(code, out)
    if code == 0 then
      log("brain backup ok: " .. (out or ""):gsub("%s+$", ""))
    else
      log("brain backup FAILED (code " .. tostring(code) .. ")")
    end
  end, { HOME .. "/vox/mem.py", "backup", mode })
  M.backupTask:start()
end
timers.backupBoot = hs.timer.doAfter(300, brainBackup)
timers.backupLoop = hs.timer.doEvery(86400, brainBackup)
timers.miniBoot = hs.timer.doAfter(2, miniShow)
-- long-running whisper-server drifts slow; a scheduled idle refresh keeps
-- the 1.5s dictation feel permanent
-- decay recurs every ~2h in practice — periodic self-test carries the
-- auto-refresh machinery, so slowness is caught before a human feels it
timers.selfTestLoop = hs.timer.doEvery(2 * 3600 + 300, function()
  if state == "idle" then selfTest(false) end
end)
timers.engineRefresh = hs.timer.doEvery(4 * 3600, function()
  if state == "idle" and C.whisperHost == "127.0.0.1" then
    log("scheduled engine refresh")
    os.execute("/usr/bin/pkill -f 'whisper-serve[r].*" .. C.serverPort .. "'")
    timers.engineRe2 = hs.timer.doAfter(2, ensureServer)
  end
end)

-- ---------------- local pulse API -----------------------------
-- localhost-only: agents on THIS machine can read the alien's mind.
--   GET  /status     pipeline + calibration + memory stats
--   GET  /search?q=  recall from memory (JSON lines)
--   GET  /recent     latest memories
--   POST /ingest     request body -> memory
if C.apiEnable then
  local function runMem(args)
    local p = io.popen("/usr/bin/python3 " .. HOME .. "/vox/mem.py " .. args)
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
  end
  M.api = hs.httpserver.new(false, false)
  M.api:setInterface("localhost")
  M.api:setPort(C.apiPort)
  M.api:setCallback(function(method, path, headers, body)
    local JSON = { ["Content-Type"] = "application/json" }
    -- Localhost binding is NOT a security boundary: any web page you visit can
    -- reach 127.0.0.1 from your browser. Two guards keep the alien's mind (your
    -- private dictation memory) sealed to real local agents only:
    --   1. Host must be loopback — defeats DNS-rebinding (an attacker page at
    --      evil.com -> 127.0.0.1 still sends "Host: evil.com").
    --   2. Reject any Origin/Referer — browsers stamp those on cross-site
    --      fetch/XHR/form POST; curl and native agents don't. So a page can't
    --      read /search·/recent·/entities or poison memory via /ingest.
    local h = {}
    if type(headers) == "table" then
      for k, v in pairs(headers) do h[tostring(k):lower()] = v end
    end
    local host = tostring(h.host or ""):gsub("%s", "")
    local hostOK = host == "" or host:match("^localhost:?%d*$")
      or host:match("^127%.0%.0%.1:?%d*$") or host:match("^%[?::1%]?:?%d*$")
    if not hostOK or h.origin or h.referer then
      return '{"error":"forbidden"}', 403, JSON
    end
    if path:find("^/status") then
      return hs.json.encode({
        state = state, pipeline = calib.mode, latency = calib.lastLatency,
        rev = currentRev, learnedWords = learnedCount(),
        memory = runMem("stats"):gsub("%s+$", ""),
      }), 200, JSON
    elseif path:find("^/search") then
      local q = (path:match("[?&]q=([^&]*)") or ""):gsub("+", " ")
        :gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        :gsub("[^%w%s%-']", "")
      return runMem('search "' .. q .. '" -n 5'), 200, JSON
    elseif path:find("^/recent") then
      return runMem("recent"), 200, JSON
    elseif path:find("^/entities") then
      return runMem("entities -n 40"), 200, JSON
    elseif path:find("^/wiki") then
      local e = (path:match("[?&]e=([^&]*)") or ""):gsub("+", " ")
        :gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        :gsub("[^%w%s%-']", "")
      return runMem('wiki "' .. e .. '"'), 200,
             { ["Content-Type"] = "text/plain" }
    elseif method == "POST" and path:find("^/ingest") and body and #body > 1 then
      rememberText(body:sub(1, 8000), "api")
      return '{"ok":true}', 200, JSON
    end
    return '{"error":"unknown route"}', 404, JSON
  end)
  if pcall(function() M.api:start() end) then
    log("pulse API on http://127.0.0.1:" .. C.apiPort)
  end
end
timers.warmBoot = hs.timer.doAfter(10, warmUp)

-- survive reboots: Vox re-arms itself at every login, no human needed
pcall(hs.autoLaunch, true)

flagTap:start()
ensureServer()
refreshModels()
timers.modelsRetry = hs.timer.doAfter(45, refreshModels)  -- ollama may boot slow

-- macOS also disables event taps it thinks are stuck; watchdog revives ours
-- (and picks the hotkey up automatically once Accessibility gets granted).
timers.tapWatchdog = hs.timer.doEvery(15, function()
  if not flagTap:isEnabled() and hs.accessibilityState() then
    flagTap:start()
    log("hotkey listener re-enabled by watchdog")
  end
end)
-- belt and braces: re-check a few seconds after load in case the first
-- spawn attempt raced with config reload
timers.srvCheck = hs.timer.doAfter(5, ensureServer)

-- Stuck-state watchdog (Relic): if we're in "recording" or "processing" way
-- beyond any legitimate flow (LLM callback died silently, timer misfired,
-- forceLocalLLM taking too long on ancient hardware), force reset so the
-- alien pill hides itself and the next hotkey press works.
local stuckSince = { recording = 0, processing = 0 }
timers.stateWatchdog = hs.timer.doEvery(5, function()
  local now = hs.timer.secondsSinceEpoch()
  if state == "recording" or state == "processing" then
    if stuckSince[state] == 0 then stuckSince[state] = now end
    local limit = (state == "recording") and (C.maxRecordSecs + 15)
                  or (IS_ARM and 60 or 240)
    if now - stuckSince[state] > limit then
      log("state watchdog: forcing reset (stuck in " .. state .. ")")
      state, locked, pendingTap = "idle", false, false
      if recTask and recTask:isRunning() then recTask:terminate() end
      reset()
      stuckSince.recording, stuckSince.processing = 0, 0
    end
  else
    stuckSince.recording, stuckSince.processing = 0, 0
  end
end)

-- Anchor everything in the module table so Lua GC never collects
-- the eventtap, menubar, canvas, or timers (classic Hammerspoon gotcha).
M.flagTap, M.menubar, M.timers, M.hud, M.sounds = flagTap, menubar, timers, hud, sounds
M.mini = mini
M.debug = { hudShow = hudShow, hudHide = hudHide, play = play,
            fix = applyCorrections, smartReply = smartReply,
            commands = applyVoiceCommands, collapse = collapseRepeats,
            handle = handleTranscript,
            selfTest = selfTest, dance = hudDance, fillers = cleanFillers,
            history = function() return pasteHistory end,
            duckDown = duckDown, duckUp = duckUp, config = C,
            miniInfo = function()
              if not mini.canvas then return "no canvas" end
              local f = mini.canvas:frame()
              return string.format("visible=%s x=%d y=%d",
                tostring(mini.canvas:isShowing()), f.x, f.y)
            end, miniShow = miniShow }

log("Vox loaded. Hold " .. C.holdKeyName .. " to dictate.")
hs.alert.show("🎤 Vox ready — hold " .. C.holdKeyName .. " to dictate", 2)

return M
