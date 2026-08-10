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
local WMODEL = IS_ARM and "ggml-large-v3-turbo-q5_0.bin" or "ggml-small-q5_1.bin"

local C = {
  sox         = BREW .. "/sox",
  ffmpeg      = BREW .. "/ffmpeg",
  whisper     = BREW .. "/whisper-cli",     -- fallback only
  whisperSrv  = BREW .. "/whisper-server",  -- fast path
  serverPort  = 8090,
  serverPortFast   = 8092,
  fastModel        = HOME .. "/vox/models/ggml-tiny.en.bin",
  speculativeDraft = true,
  screenRecDir        = HOME .. "/Movies/VoxRecordings",
  screenRecWebcam     = true,
  screenRecWebcamSize = 180,
  screenRecWebcamPos  = "bottom-left",
  screenRecBgMode     = "chroma",
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

  holdKeycode = 55,                  -- 55 = Left Command. (Right Option = 61)
  holdKeyName = "Left Command",
  -- Ask combo: while holding the talk key, ALSO press this key and the
  -- utterance becomes a QUESTION — Vox answers out loud (alien voice)
  -- instead of pasting. Hold ⌘, tap Left Shift, speak, release.
  askKeycode  = 56,                  -- 56 = Left Shift
  askKeyName  = "Left Shift",
  tapLockMax  = 0.35,                -- press shorter than this counts as a tap
  tailGrace   = 0.25,                -- mic stays open this long after release
                                     -- (last-word syllables are still in the air)
  doubleTapWindow = 0.45,            -- two taps this close = hands-free lock
  minBytes    = 12000,               -- allow short 1-2 word utterances
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
  -- "mini": the little alien stays put and shows every state itself —
  -- listening, thinking, done — so nothing new appears over your work.
  -- "pill": the original 150x70 bar-graph pill that replaced him while
  -- recording. It reads well in a demo and is a lot of screen the rest of
  -- the time.
  hudStyle  = "mini",

  -- Where the recording alien pops up — a SET, pick any combo from the
  -- menubar (persisted): window = he rises out of the window you're
  -- dictating into; center = bottom center; top = top center; side = right
  -- edge. All off / no window found -> bottom center.
  alienPos = { window = true },

  -- Voice vignette: while you dictate, the border of the screen you're
  -- recording on glows — and BREATHES with your voice. Silence = a faint
  -- ring (proof the mic is live); speech = the ring blooms with every word.
  -- Violet slow-breathing = transcribing. Fades away when your words land.
  vignette      = true,
  vignetteColor = { red = 1.0, green = 0.31, blue = 0.85 },  -- Vox magenta
  -- Second ring: a glow hugging the WINDOW your words will land in — the
  -- most precise "dictating here" signal. Skipped for fullscreen windows.
  vignetteWindow = true,

  -- Alien voice output: speaks answers to "Hey Vox..." questions and fact confirmations out loud
  alienVoice      = true,
  alienVoiceName  = "vox",   -- "vox" = OUR OWN alien voice (am_adam + FX) —
                             -- Adam's pick 2026-07-28; raw Kokoro also works:
                             -- "am_adam", "af_heart", "am_fenrir"
  alienVoiceSpeed = 1.0,

  -- Voice commands: "scratch that" / "delete last" / "undo" (and a dozen
  -- other phrasings) undo the last dictation;
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
  convLive    = false,               -- experimental: live word-by-word typing
  alienPlayByPlay = true,            -- the alien narrates sends/handoffs (conv mode)
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
-- menubar choices survive restarts AND git updates: every pick in the menu
-- goes through pref(), which mirrors it into hs.settings (stored in
-- Hammerspoon's plist, outside this repo — the auto-updater can't touch it).
-- Saved picks win over local.lua: they are the most recent expressed intent.
-- Type-checked against the default so a stale saved value can't wedge boot.
local PREFS = { "holdKeycode", "holdKeyName", "duckMode", "duckAudio", "convLive", "alienPlayByPlay",
                "keepInClipboard", "llmCleanup", "translateTo",
                "alienVoiceName", "soundTheme", "language", "memory",
                "screenRecWebcam", "screenRecWebcamPos", "screenRecBgMode" }
local function pref(key, val)
  C[key] = val
  hs.settings.set("vox.pref." .. key, val)
end
do
  local saved = hs.settings.get("vox.alienPos")
  if type(saved) == "table" then C.alienPos = saved end
  for _, k in ipairs(PREFS) do
    local v = hs.settings.get("vox.pref." .. k)
    if v ~= nil and type(v) == type(C[k]) then C[k] = v end
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
-- NOTE: startRecording/stopRecording/convCalibrate/convVadPct are GLOBALS
-- by design. Conversation mode's re-arm loop (insertText, the LLM watcher,
-- the VAD exit callback) calls them from ABOVE their definitions; as locals
-- those call sites compiled against always-nil globals and crashed at fire
-- time — which is why the hands-free loop dead-ended. Globals resolve at
-- call time, and the main chunk is at Lua's 200-local limit anyway.
startRecording        = function() end
stopRecording         = function() end
startScreenRecording  = function() end
stopScreenRecording   = function() end
cancelScreenRecording = function() end
toggleScreenRecording = function() end

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
  elseif task == "translate" or task == "expand" then
    want = C.models.smart                      -- quality IS the product
  elseif task == "reply" or task == "answer" then
    -- spoken answers are 1-3 sentences: the fast model is plenty and
    -- shaves seconds off every "Hey Vox" / ask-mode roundtrip
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
  -- a 0.0 (or sub-real) reading must never become the baseline: nothing can
  -- ever beat a bestLatency of 0, best*2 collapses the slow-threshold to its
  -- 3.2s floor, and machines whose healthy speed is above that refresh-loop
  -- forever. Ignore implausible readings and heal an already-poisoned best.
  if calib.lastLatency >= 0.3
     and (not calib.bestLatency or calib.bestLatency < 0.3
          or calib.lastLatency < calib.bestLatency) then
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

-- ---------------- alien voice synthesis (Kokoro-82M Neural AI) --------
-- Fast path: speak_server.py keeps the model warm (loads once, ~real-time
-- synthesis) — same trick as whisper-server. Fallbacks: one-shot script
-- (slow, reloads model), then plain `say`. /stop hushes instantly.
local SPEECH_PORT = 8093
local speechTask = nil

local function speechServerRunning()
  local p = io.popen("/usr/bin/pgrep -f 'speak_serve[r].py' 2>/dev/null")
  local out = p:read("*a"); p:close()
  return out ~= nil and out ~= ""
end

local function ensureSpeechServer()
  if not C.alienVoice then return end
  local pyBin = HOME .. "/vox/.venv/bin/python"
  local script = HOME .. "/vox/speak_server.py"
  if not (hs.fs.attributes(pyBin) and hs.fs.attributes(script)) then return end
  if speechServerRunning() then return end
  local spawnedAt = hs.timer.secondsSinceEpoch()
  M.speechSrvTask = hs.task.new(pyBin, function(code)
    log("speech server exited (code " .. tostring(code) .. ")")
    -- respawn with backoff — same contract as whisper-server; without this
    -- a crash meant up to 15 min of silence until the heartbeat noticed
    if hs.timer.secondsSinceEpoch() - spawnedAt > 60 then M.spkCrashes = 0 end
    M.spkCrashes = math.min((M.spkCrashes or 0) + 1, 6)
    timers.spkRespawn = hs.timer.doAfter(
      math.min(300, 10 * 2 ^ (M.spkCrashes - 1)), ensureSpeechServer)
  end, { script })
  M.speechSrvTask:start()
  log("speech server starting (model warming)")
end

local function hushAlien()
  if speechTask then
    pcall(function() speechTask:terminate() end)
    speechTask = nil
  end
  hs.http.asyncPost("http://127.0.0.1:" .. SPEECH_PORT .. "/stop", "", nil,
                    function() end)
end

local function speakFallback(clean, voice, speed)
  local pyBin = HOME .. "/vox/.venv/bin/python"
  local script = HOME .. "/vox/speak_kokoro.py"
  if hs.fs.attributes(pyBin) and hs.fs.attributes(script) then
    speechTask = hs.task.new(pyBin, nil, { script, clean, voice, tostring(speed) })
  else
    speechTask = hs.task.new("/usr/bin/say", nil,
                             { "-v", "Samantha", "-r", "185", clean })
  end
  speechTask:start()
end

local function speakAlien(text)
  if not C.alienVoice or not text or #text == 0 then return end
  hushAlien()
  -- Clean up markdown formatting and prompt noise for spoken output
  local clean = text:gsub("```.-```", "")
                    :gsub("`.-`", "")
                    :gsub("[%*_%#]", "")
                    :gsub("%b[]", "")
                    :gsub("%b()", "")
                    :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #clean == 0 then return end
  if #clean > 350 then
    clean = clean:sub(1, 350) .. "..."
  end
  local voice = C.alienVoiceName or "vox"
  local speed = C.alienVoiceSpeed or 1.0
  hs.http.asyncPost("http://127.0.0.1:" .. SPEECH_PORT .. "/speak",
    hs.json.encode({ text = clean, voice = voice, speed = speed }), nil,
    function(status)
      if status ~= 200 then          -- server cold: speak slow, warm it up
        ensureSpeechServer()
        speakFallback(clean, voice, speed)
      end
    end)
end

-- ---------------- alien play-by-play (conv mode) -------------
-- The funny angel on your shoulder. He ONLY speaks while the conv mic is
-- PARKED — if he talked over a live mic, Vox would faithfully type his
-- own jokes, and nobody needs that feedback loop.
ALIEN_QUIPS = {
  sent = {
    "Boom. Sent. Go stretch or something.",
    "Shipped it. Let the silicon sweat now.",
    "Off it goes. I'd cross my fingers if I had bones.",
    "Sent, boss. The robot's thinking — you're winning.",
    "And it's away. Beautiful form on that one.",
  },
  ready = {
    "Answer's up. You're on, champ.",
    "Robot's done talking. Go get 'em.",
    "Your turn. Make it spicy.",
    "Green light. Talk to me.",
    "Mic's coming back hot. Do your thing.",
  },
  timeout = {
    "That took forever and I got bored. Mic's yours.",
    "I stopped watching. Talk whenever, boss.",
  },
}
-- PROMPT-ECHO GUARD: whisper sometimes parrots its context prompt back as
-- the "transcription" of ambiguous audio — Vox then types its own brand
-- cheat-sheet ("AutomateScale, GoHighLevel, GHL, ..."). Verbatim-substring
-- or >=90% token containment (5+ words) = echo, discard.
function isPromptEcho(text, prompt, wordBag)
  if not text or #text < 12 or not prompt or #prompt == 0 then return false end
  local function norm(s) return (" " .. s:lower():gsub("[%s%p]+", " ") .. " ") end
  local t, p = norm(text), norm(prompt)
  if p:find(t, 1, true) then return true end
  -- token-containment is ONLY safe against sentence prompts (the previous
  -- chunk's tail). Against a BAG-OF-WORDS prompt (the vocabulary, which
  -- includes every word Vox has LEARNED from the user) it false-positives
  -- on any long dictation about familiar topics — real speech was being
  -- discarded as "echo". Verbatim-substring is the only vocab-safe check.
  if wordBag then return false end
  local pset = {}
  for w in p:gmatch("%S+") do pset[w] = true end
  local hit, tot = 0, 0
  for w in t:gmatch("%S+") do
    tot = tot + 1
    if pset[w] then hit = hit + 1 end
  end
  return tot >= 5 and (hit / tot) >= 0.9
end

convRetried = {}        -- chunk paths that already got their one retry
convMuteUntil = 0       -- while now < this, tick treats audio as non-speech
convMutePurge = false   -- after the window, drop the captured playback bytes
function alienQuip(kind)
  if not C.alienPlayByPlay then return end
  local pool = ALIEN_QUIPS[kind]
  if not pool then return end
  convMuteUntil = hs.timer.secondsSinceEpoch() + 3.0
  convMutePurge = true
  speakAlien(pool[math.random(#pool)])
end
-- ding over a LIVE mic: bell plays, tick ignores it via the mute window
function dingNow(msg)
  convMuteUntil = math.max(convMuteUntil, hs.timer.secondsSinceEpoch() + 2.0)
  convMutePurge = true
  local g = hs.sound.getByName("Glass")
  if g then g:volume(1.0):play() else play("done") end
  if msg then hs.alert.show(msg, 2.0) end
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

local function duckDown(force)
  if not C.duckAudio then return end
  -- conv mode ducks ONCE at toggle-ON (force=true) — per-utterance ducking
  -- would pause/resume the media on every single sentence of the loop
  if convMode and not force then return end
  -- "pause": stop the podcast/music itself (media key) — nothing bleeds into
  -- the mic AND you miss nothing; it resumes the moment you stop talking
  if C.duckMode == "pause" then
    if not duck.paused then duck.paused = true; mediaPlayPause() end
    return
  end
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev or not dev:outputVolume() then
    -- pro interfaces (RODECaster etc.) expose NO software volume or mute to
    -- CoreAudio — hardware faders own it, so fading is impossible. The one
    -- lever left is the media key: pause the video/music, resume on duckUp.
    -- inUse gates it so an idle system doesn't get Music launched by PLAY.
    if not duck.paused and dev and dev:inUse() then
      duck.paused = true
      mediaPlayPause()
      log("duck: no volume control on " .. (dev:name() or "output")
          .. " — pausing media instead")
    end
    return
  end
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
  -- while conv mode is live the duck stays down; toggle-OFF clears convMode
  -- first, so its duckUp() passes this guard and restores the media
  if convMode then return end
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
              level = 0, emote = nil, emoteUntil = 0, mirrors = {} }

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
               nextBlink = 20, blinkUntil = 0, act = {},
               -- "idle" | "rec" (listening) | "work" (transcribing).
               -- The alien is the whole interface in mini style, so his own
               -- colour and pulse have to carry the state that the pill's
               -- bar graph used to.
               mode = "idle", level = 0, emote = nil, emoteUntil = 0 }

-- Declared up here (not next to miniHide, where it used to live) because
-- miniTick has to be able to dismiss the bubble when an emote finishes, and a
-- local declared later would read as a nil global from inside this function.
local bubble = { canvas = nil, timer = nil, hold = nil,
                 dir = nil, open = false, phase = 0,
                 targetW = 0, animStart = 0 }
local MW, MH, MOFF = 118, 30, 45        -- canvas w/h, alien x-offset

local function showAlienToolsMenu()
  local menu = hs.menubar.new(false)
  local function setCamMode(m, name)
    pref("screenRecBgMode", m)
    if screenRec and screenRec.camTask then
      showWebcamOverlay()
    end
    hs.alert.show("Webcam Mode: " .. name, 1.5)
  end
  menu:setMenu({
    { title = "📹 Toggle Presenter Camera Overlay (⌥⇧C)", fn = function() toggleWebcamOverlay() end },
    { title = (screenRec and screenRec.active) and "🛑 Stop Voom Screen Recording (⌥⇧R)" or "▶ Start Voom Screen Recording (⌥⇧R)", fn = function() toggleScreenRecording() end },
    { title = "-" },
    { title = "Camera Presets & Fun Filters:", disabled = true },
    { title = "  ✨ Mint Humanoid Outline", fn = function() setCamMode("mint", "✨ Mint Humanoid Outline") end },
    { title = "  💪 Hero Male Frame (Muscular Shoulder Highlight)", fn = function() setCamMode("hero", "💪 Hero Male Frame") end },
    { title = "  👑 Goddess Fem Frame (Rose-Gold Contour)", fn = function() setCamMode("goddess", "👑 Goddess Fem Frame") end },
    { title = "  ⚡ Cyberpunk Neon Contour", fn = function() setCamMode("cyber", "⚡ Cyberpunk Neon") end },
    { title = "  📷 Raw Camera Floating Circle", fn = function() setCamMode("raw", "📷 Raw Camera Circle") end },
    { title = "-" },
    { title = "🎨 Content Expansion Mode (C)", fn = function() if mini.act.content then mini.act.content() end end },
    { title = "📸 Absorb Screen Text OCR (P)", fn = function() if mini.act.grab then mini.act.grab() end end },
    { title = "💬 Hands-free AI Dictation (Click Alien)", fn = function() if mini.act.talk then mini.act.talk() end end },
    { title = "-" },
    { title = "📂 Open Recordings Folder", fn = function() hs.execute("open '" .. (C.screenRecDir or (HOME .. "/Movies/VoxRecordings")) .. "'") end },
  })
  menu:popupMenu(hs.mouse.absolutePosition())
end

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
  -- 5 Alien Tool Buttons:
  -- 1. Camera Toggle (📹) | 2. Content Mode (C) | 3. Alien Head (Talk) | 4. Absorb Screen (P) | 5. Screen Rec (🔴)
  local btnBg = { red = 0.10, green = 0.12, blue = 0.20, alpha = 0.85 }
  c[9]  = { type = "oval", action = "fill", fillColor = btnBg,
            frame = { x = 2, y = 12, w = 17, h = 17 } }
  c[10] = { type = "text", text = "📹", textSize = 9,
            textAlignment = "center", frame = { x = 2, y = 13.5, w = 17, h = 13 } }
  c[11] = { type = "oval", action = "fill", fillColor = btnBg,
            frame = { x = 22, y = 12, w = 17, h = 17 } }
  c[12] = { type = "text", text = "C", textSize = 10,
            textColor = { red = 0.45, green = 0.97, blue = 0.72, alpha = 1 },
            textAlignment = "center", frame = { x = 22, y = 14.5, w = 17, h = 13 } }
  c[13] = { type = "oval", action = "fill", fillColor = btnBg,
            frame = { x = 79, y = 12, w = 17, h = 17 } }
  c[14] = { type = "text", text = "P", textSize = 10,
            textColor = { red = 0.72, green = 0.52, blue = 1.0, alpha = 1 },
            textAlignment = "center", frame = { x = 79, y = 14.5, w = 17, h = 13 } }
  c[15] = { type = "oval", action = "fill", fillColor = btnBg,
            frame = { x = 99, y = 12, w = 17, h = 17 } }
  c[16] = { type = "text", text = "🔴", textSize = 9,
            textAlignment = "center", frame = { x = 99, y = 13.5, w = 17, h = 13 } }

  c:alpha(0.95)
  c:canvasMouseEvents(true, false, false, true)
  c:mouseCallback(function(_, event, _, x, y)
    if event == "rightMouseDown" then
      showAlienToolsMenu()
      return
    end
    if event ~= "mouseDown" then return end
    if x <= 20 then
      toggleWebcamOverlay()
    elseif x > 20 and x <= 40 and mini.act.content then
      mini.act.content()
    elseif x >= 78 and x <= 97 and mini.act.grab then
      mini.act.grab()
    elseif x > 97 then
      toggleScreenRecording()
    else
      local mods = hs.eventtap.checkKeyboardModifiers()
      if mods.alt or mods.shift then
        toggleScreenRecording()
      elseif mini.act.talk then
        mini.act.talk()
      end
    end
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

  -- ---- state, shown on the alien himself --------------------------------
  -- In mini style he never steps aside for the pill, so he has to say what
  -- is happening. Cyan while listening (brightening with your voice), violet
  -- while transcribing (a slow think-pulse), mint at rest. Same colour
  -- language the pill used, on a tenth of the pixels.
  -- An emote is a short celebration after the words land, and — critically —
  -- it is what ENDS the busy state. The pill used to hide itself at the end of
  -- its own fade-out animation; the success path never calls setUI("idle"), it
  -- just calls hudEmote and trusts that. With the pill gone nothing closed the
  -- loop, so the alien stayed lit and the bubble stayed on screen forever.
  if mini.mode == "emote" and mini.phase >= mini.emoteUntil then
    mini.mode, mini.emote, mini.level = "idle", nil, 0
    if mini.lvlTimer then mini.lvlTimer:stop(); mini.lvlTimer = nil end
    if bubble.canvas then bubble.canvas:hide() end
  end

  local head, glow
  if mini.mode == "emote" then
    local k = mini.emote
    local t = 1 - math.max(0, (mini.emoteUntil - mini.phase) / 12)
    local flare = math.sin(math.min(1, t) * math.pi)        -- swell and settle
    local c1 = (k == "joy")    and { red = 1.0, green = 0.88, blue = 0.42, alpha = 1 }
            or (k == "excite") and { red = 1.0, green = 0.62, blue = 0.78, alpha = 1 }
            or (k == "curious") and { red = 0.62, green = 0.90, blue = 1.0, alpha = 1 }
            or                      { red = 0.62, green = 1.0,  blue = 0.86, alpha = 1 }
    head = { c1, { red = c1.red * 0.62, green = c1.green * 0.78, blue = c1.blue * 0.72, alpha = 1 } }
    glow = 0.95 + flare * 0.05
  elseif mini.mode == "rec" then
    local lv = math.min(1, mini.level * 3.2)
    head = { { red = 0.55 + lv * 0.3, green = 0.95, blue = 1.0, alpha = 1 },
             { red = 0.20, green = 0.72 + lv * 0.2, blue = 0.95, alpha = 1 } }
    glow = 0.95 + lv * 0.05
  elseif mini.mode == "work" then
    local pulse = 0.5 + 0.5 * math.sin(mini.phase * 0.22)
    head = { { red = 0.85, green = 0.72, blue = 1.0, alpha = 1 },
             { red = 0.55, green = 0.36 + pulse * 0.12, blue = 0.95, alpha = 1 } }
    glow = 0.85 + pulse * 0.15
  else
    head = { { red = 0.72, green = 1.0,  blue = 0.88, alpha = 1 },
             { red = 0.40, green = 0.90, blue = 0.66, alpha = 1 } }
    glow = 0.95                       -- unobtrusive when there is nothing to say
  end
  c[1].fillGradientColors = head
  c[5].strokeColor = head[1]
  c[6].fillColor = head[1]
  c:alpha(glow)

  -- Track bottom edge of currently focused highlighted window across all screens
  if C.alienPos and C.alienPos.window then
    local ok, winInfo = pcall(function()
      local w = hs.window.focusedWindow()
      if not w then return nil end
      local wf = w:frame()
      local ws = w:screen() or hs.screen.mainScreen()
      return { frame = wf, screenFrame = ws:fullFrame() }
    end)
    if ok and winInfo and winInfo.frame and winInfo.frame.w > 120 and winInfo.frame.h > 120 then
      local wf = winInfo.frame
      local sf = winInfo.screenFrame
      local targetX = math.max(sf.x + 4, math.min(wf.x + (wf.w - MW) / 2, sf.x + sf.w - MW - 4))
      local targetY = math.max(sf.y + 4, math.min(wf.y + wf.h - 45, sf.y + sf.h - MH - 4))
      c:frame({ x = targetX, y = targetY, w = MW, h = MH })
    end
  end
end

local function miniShow()
  if not C.miniAlien then return end
  -- Only stand aside for the pill when the pill is actually in use.
  if C.hudStyle ~= "mini" and hud.visible then return end
  miniEnsure()
  
  local ok, winInfo = pcall(function()
    local w = hs.window.focusedWindow()
    if not w then return nil end
    local wf = w:frame()
    local ws = w:screen() or hs.screen.mainScreen()
    return { frame = wf, screenFrame = ws:fullFrame() }
  end)
  if C.alienPos and C.alienPos.window and ok and winInfo and winInfo.frame and winInfo.frame.w > 120 and winInfo.frame.h > 120 then
    local wf = winInfo.frame
    local sf = winInfo.screenFrame
    local targetX = math.max(sf.x + 4, math.min(wf.x + (wf.w - MW) / 2, sf.x + sf.w - MW - 4))
    local targetY = math.max(sf.y + 4, math.min(wf.y + wf.h - 45, sf.y + sf.h - MH - 4))
    mini.canvas:frame({ x = targetX, y = targetY, w = MW, h = MH })
  else
    local activeScr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen() or hs.screen.primaryScreen()
    local f = activeScr:fullFrame()
    mini.canvas:frame({ x = f.x + (f.w - MW) / 2, y = f.y + f.h - 34,
                        w = MW, h = MH })
  end
  mini.canvas:show()
  if not mini.timer then
    mini.timer = hs.timer.doEvery(0.25, safeTick("miniTick", miniTick))
  end
end

local function miniHide()
  if mini.timer then mini.timer:stop(); mini.timer = nil end
  if mini.canvas then mini.canvas:hide() end
  if bubble.canvas then bubble.canvas:hide() end
end

-- ---------------- mini bubble: a thought-blob that morphs ------
-- The bubble used to be a fixed 320x48 slab that appeared and vanished with no
-- transition, the same width whether it said "Listening..." or a full
-- sentence. Now it measures the words, grows out of the alien's head, holds at
-- exactly the width it needs, and shrinks back into him — so it reads as HIS
-- thought rather than a notification that happens to be nearby.
-- One table rather than eight locals: the main chunk is close to Lua's
-- 200-local ceiling and separate constants tipped it over.
--
-- The blob is drawn into a canvas sized to the widest it will ever get, and
-- only the ELEMENT frames move. Resizing an hs.canvas window every frame is
-- visibly steppy; resizing a shape inside a stable window is smooth.
local BUB = { H = 30, PADX = 22, MINW = 96, MAXW = 460, TXT = 12.5 }
BUB.CVW, BUB.CVH = BUB.MAXW + 40, BUB.H + 34

function BUB.measure(text)
  local ok, sz = pcall(hs.drawing.getTextDrawingSize, text,
                       { font = { size = BUB.TXT }, paragraphStyle = { alignment = "center" } })
  local w = (ok and sz and sz.w) and sz.w or (#text * 7)
  return math.max(BUB.MINW, math.min(BUB.MAXW, w + BUB.PADX * 2))
end

local function bubbleEnsure()
  if bubble.canvas then return end
  local c = hs.canvas.new({ x = 0, y = 0, w = BUB.CVW, h = BUB.CVH })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)

  -- 1 body · 2 rim · 3/4 the two thought-dots that trail down to his head
  c[1] = { type = "rectangle", action = "fill",
           fillColor = { red = 0.05, green = 0.08, blue = 0.14, alpha = 0.92 },
           roundedRectRadii = { xRadius = BUB.H / 2, yRadius = BUB.H / 2 },
           frame = { x = 0, y = 0, w = BUB.MINW, h = BUB.H } }
  c[2] = { type = "rectangle", action = "stroke",
           strokeColor = { red = 0.22, green = 0.92, blue = 0.75, alpha = 0.75 },
           strokeWidth = 1.2,
           roundedRectRadii = { xRadius = BUB.H / 2, yRadius = BUB.H / 2 },
           frame = { x = 0, y = 0, w = BUB.MINW, h = BUB.H } }
  -- Dots instead of a hard tail: a tail welds the bubble to a fixed point,
  -- whereas dots read as the thought still rising off him and let the body
  -- drift without the join looking broken.
  c[3] = { type = "circle", action = "fill",
           fillColor = { red = 0.05, green = 0.08, blue = 0.14, alpha = 0.9 },
           center = { x = BUB.CVW / 2, y = BUB.H + 9 }, radius = 4 }
  c[4] = { type = "circle", action = "fill",
           fillColor = { red = 0.05, green = 0.08, blue = 0.14, alpha = 0.85 },
           center = { x = BUB.CVW / 2, y = BUB.H + 19 }, radius = 2.4 }
  c[5] = { type = "text", text = "", textSize = BUB.TXT,
           textColor = { red = 0.92, green = 0.98, blue = 0.95, alpha = 1 },
           textAlignment = "center", textLineBreak = "truncateTail",
           frame = { x = 0, y = 7, w = BUB.MINW, h = BUB.H - 12 } }
  bubble.canvas = c
end

-- easeOutBack: overshoots then settles. The overshoot is what makes it feel
-- like a blob inflating rather than a box being resized.
function BUB.ease(t)
  local c1, c3 = 1.70158, 2.70158
  local u = t - 1
  return 1 + c3 * u * u * u + c1 * u * u
end

function BUB.layout(prog, wobblePhase)
  local c = bubble.canvas
  if not c then return end
  local eased = bubble.dir == "out" and (1 - prog) or BUB.ease(prog)
  eased = math.max(0.001, eased)

  -- Width leads, height follows a touch behind, so it unfurls sideways out of
  -- him instead of scaling up like a photograph.
  local w = BUB.MINW + (bubble.targetW - BUB.MINW) * math.min(1, eased)
  w = math.max(18, w * (0.42 + 0.58 * eased))
  local h = BUB.H * (0.5 + 0.5 * math.min(1, eased))

  -- A slow squash/stretch keeps it alive while it sits there — a thought
  -- breathing, not a tooltip parked on screen.
  local wob = math.sin(wobblePhase * 0.09) * 0.9
  local x = (BUB.CVW - w) / 2
  local y = 6 - wob

  c[1].frame = { x = x, y = y, w = w, h = h + wob }
  c[2].frame = { x = x, y = y, w = w, h = h + wob }
  c[1].roundedRectRadii = { xRadius = h / 2, yRadius = h / 2 }
  c[2].roundedRectRadii = { xRadius = h / 2, yRadius = h / 2 }
  c[5].frame = { x = x, y = y + (h - BUB.TXT * 1.35) / 2 + 1, w = w, h = BUB.TXT * 1.5 }
  c[5].textColor = { red = 0.92, green = 0.98, blue = 0.95, alpha = math.max(0, eased * 1.4 - 0.4) }

  -- Dots pop in after the body, so the thought looks like it rose off him.
  local d1 = math.max(0, math.min(1, (eased - 0.25) / 0.5))
  local d2 = math.max(0, math.min(1, (eased - 0.55) / 0.45))
  c[3].radius = 4 * d1
  c[4].radius = 2.4 * d2
  c[3].center = { x = BUB.CVW / 2, y = y + h + 8 }
  c[4].center = { x = BUB.CVW / 2, y = y + h + 17 }
  c:alpha(math.min(1, eased * 1.25))
end

function BUB.tick()
  if not bubble.canvas then return end
  bubble.phase = (bubble.phase or 0) + 1
  local now = hs.timer.secondsSinceEpoch()
  local t = math.min(1, (now - (bubble.animStart or now)) / 0.26)
  BUB.layout(t, bubble.phase)
  if bubble.dir == "out" and t >= 1 then
    bubble.canvas:hide()
    if bubble.timer then bubble.timer:stop(); bubble.timer = nil end
  end
end

local function bubbleShow(text, duration)
  if not C.miniAlien or not text or #text == 0 then return end
  bubbleEnsure()
  local f = hs.screen.primaryScreen():fullFrame()
  bubble.canvas:frame({ x = f.x + (f.w - BUB.CVW) / 2,
                        y = f.y + f.h - 34 - BUB.CVH + 6,
                        w = BUB.CVW, h = BUB.CVH })
  bubble.canvas[5].text = text
  bubble.targetW = BUB.measure(text)

  -- Re-showing while already open re-flows to the new width instead of
  -- replaying the entrance, so consecutive messages morph into each other.
  if bubble.dir ~= "in" or not bubble.open then
    bubble.animStart = hs.timer.secondsSinceEpoch()
  end
  bubble.dir, bubble.open = "in", true
  bubble.canvas:show()
  if not bubble.timer then
    bubble.timer = hs.timer.doEvery(0.03, safeTick("bubbleTick", BUB.tick))
  end

  if bubble.hold then bubble.hold:stop(); bubble.hold = nil end
  if duration and duration > 0 then
    bubble.hold = hs.timer.doAfter(duration, function() bubbleHide() end)
  end
end

function bubbleHide()
  if bubble.hold then bubble.hold:stop(); bubble.hold = nil end
  if not bubble.canvas or not bubble.open then
    if bubble.canvas then bubble.canvas:hide() end
    return
  end
  -- Shrink back into him rather than blinking out.
  bubble.dir, bubble.open = "out", false
  bubble.animStart = hs.timer.secondsSinceEpoch()
  if not bubble.timer then
    bubble.timer = hs.timer.doEvery(0.03, safeTick("bubbleTick", BUB.tick))
  end
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
      for _, m in ipairs(hud.mirrors) do m.canvas:hide() end
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

  -- extra positions: mirror the finished frame (tiny canvas — trivial copy)
  if #hud.mirrors > 0 then
    local img = c:imageFromCanvas()
    local a = puffT and alpha or 1
    for _, m in ipairs(hud.mirrors) do
      m.canvas[1].image = img
      m.canvas:frame({ x = m.x, y = m.y + yOff, w = CV_W, h = CV_H })
      m.canvas:alpha(a)
    end
  end
end

-- where does the alien pop up? C.alienPos is a set: window/center/top/side,
-- menu-selectable, any combo. "window" = he rises out of the window you're
-- dictating into. One alien is real; extra positions get cheap mirrors.
local function hudPositions()
  local f = hs.screen.mainScreen():fullFrame()
  local list, seen = {}, {}
  local function add(x, y, scr)
    local sf = scr and scr:fullFrame() or f
    x = math.max(sf.x + 4, math.min(x, sf.x + sf.w - CV_W - 4))
    y = math.max(sf.y + 4, math.min(y, sf.y + sf.h - CV_H - 4))
    local key = math.floor(x) .. ":" .. math.floor(y)
    if not seen[key] then seen[key] = true; list[#list + 1] = { x = x, y = y } end
  end
  local pos = C.alienPos or {}
  if pos.titlebar then
    local ok, winInfo = pcall(function()
      local w = hs.window.focusedWindow()
      return w and { frame = w:frame(), screen = w:screen() }
    end)
    if ok and winInfo and winInfo.frame and winInfo.frame.w > 120 then
      local wf = winInfo.frame
      add(wf.x + (wf.w - CV_W) / 2, wf.y + 4, winInfo.screen)
    end
  end
  if pos.window then
    local ok, winInfo = pcall(function()
      local w = hs.window.focusedWindow()
      return w and { frame = w:frame(), screen = w:screen() }
    end)
    if ok and winInfo and winInfo.frame and winInfo.frame.w > 120 then
      local wf = winInfo.frame
      add(wf.x + (wf.w - CV_W) / 2, wf.y + wf.h - 34, winInfo.screen)
    end
  end
  if pos.center then add(f.x + (f.w - CV_W) / 2, f.y + f.h - CV_H - 28) end
  if pos.top    then add(f.x + (f.w - CV_W) / 2, f.y + 34) end
  if pos.side   then add(f.x + f.w - CV_W - 8, f.y + (f.h - CV_H) / 2) end
  if #list == 0 then add(f.x + (f.w - CV_W) / 2, f.y + f.h - CV_H - 28) end
  return list
end

-- mirrors re-display the primary canvas's image each tick — at 150x70 the
-- copy is trivial, so N aliens cost barely more than one
local function hudMirrorsBuild(positions)
  for _, m in ipairs(hud.mirrors) do m.canvas:delete() end
  hud.mirrors = {}
  for i = 2, #positions do
    local p = positions[i]
    local c = hs.canvas.new({ x = p.x, y = p.y + 24, w = CV_W, h = CV_H })
    c:level(hs.canvas.windowLevels.overlay)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c:clickActivating(false)
    c[1] = { type = "image", frame = { x = 0, y = 0, w = CV_W, h = CV_H } }
    c:alpha(0)
    c:show()
    hud.mirrors[#hud.mirrors + 1] = { canvas = c, x = p.x, y = p.y }
  end
end

local function hudShow(mode)
  -- Mini style: the alien keeps the stage and changes colour instead of a
  -- 150x70 panel appearing over whatever you were looking at. This is the
  -- default because the pill's real estate cost is paid on every single
  -- dictation, while its extra detail — an 8-bar level meter — is something
  -- the alien's own brightness already conveys.
  if C.hudStyle == "mini" and C.miniAlien then
    mini.mode = mode
    miniShow()
    if not mini.timer then
      mini.timer = hs.timer.doEvery(0.25, safeTick("miniTick", miniTick))
    end
    -- Sample the mic often enough for the glow to track the voice; the mini
    -- tick alone (250ms) is too coarse to read as responsive.
    if not mini.lvlTimer then
      mini.lvlTimer = hs.timer.doEvery(0.08, safeTick("miniLevel", function()
        mini.level = (mini.mode == "rec") and micLevel() or 0
      end))
    end
    return
  end
  miniHide()
  hudEnsure()
  hud.mode = mode
  local col = (mode == "rec")
      and { red = 0.35, green = 0.9,  blue = 1.0, alpha = 0.95 }   -- cyan: listening
      or  { red = 0.72, green = 0.52, blue = 1.0, alpha = 0.95 }   -- violet: thinking
  for i = 1, BARS do hud.canvas[i + 7].fillColor = col end
  if not hud.visible then
    local ps = hudPositions()
    hud.baseX, hud.baseY = ps[1].x, ps[1].y
    hudMirrorsBuild(ps)
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
  if C.hudStyle == "mini" and C.miniAlien then
    mini.mode, mini.level = "idle", 0
    if mini.lvlTimer then mini.lvlTimer:stop(); mini.lvlTimer = nil end
    miniShow()
    return
  end
  if not hud.visible then
    if hud.timer then hud.timer:stop(); hud.timer = nil end
    if hud.canvas then hud.canvas:hide() end
    for _, m in ipairs(hud.mirrors) do m.canvas:hide() end
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
  local ps = hudPositions()
  hud.baseX, hud.baseY = ps[1].x, ps[1].y
  hudMirrorsBuild(ps)
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
  -- In mini style this is the ONLY thing that ends a dictation: the success
  -- path sets state to idle but never calls setUI("idle"), so hudHide and
  -- bubbleHide are never reached. The emote's expiry in miniTick is what
  -- returns the alien to rest and clears the bubble.
  if C.hudStyle == "mini" and C.miniAlien then
    mini.mode, mini.emote = "emote", kind or "done"
    mini.emoteUntil = mini.phase + ((kind == "done") and 8 or 14)   -- 250ms ticks
    if mini.lvlTimer then mini.lvlTimer:stop(); mini.lvlTimer = nil end
    mini.level = 0
    miniShow()
    return
  end
  if not (hud.visible and hud.canvas) then return end
  hud.mode, hud.emote = "emote", kind or "done"
  hud.emoteStart = hud.phase
  hud.emoteUntil = hud.phase + ((kind == "done") and 12 or 26)
  local col = (kind == "joy")    and { red = 1.0,  green = 0.84, blue = 0.32, alpha = 0.95 }
           or (kind == "excite") and { red = 1.0,  green = 0.5,  blue = 0.66, alpha = 0.95 }
           or                        { red = 0.35, green = 0.9,  blue = 1.0,  alpha = 0.9 }
  for i = 1, BARS do hud.canvas[i + 7].fillColor = col end
end

-- ---------------- voice vignette ------------------------------
-- The border of the screen you're dictating on glows, and the glow breathes
-- with your voice: fast attack so it blooms the instant you speak, slow
-- release so it lingers between words like breath. Magenta = recording,
-- violet slow-breathing = transcribing, gentle fade-out when the words land.
-- Perf: two STATIC border canvases (a soft base ring + a deeper voice bloom)
-- whose gradients never re-render — only the window alpha animates (an
-- NSWindow property, no redraw), so 20fps costs ~nothing even at 4K.
local vign = { base = nil, voice = nil, win = nil, timer = nil, frame = nil,
               flowL = nil, flowR = nil, flowFS = 0,
               winObj = nil, winFrame = nil, winCheck = 0,
               mode = nil,        -- nil | "rec" | "work"
               tint = nil,        -- which color the canvases currently show
               anim = nil, animT = 0, level = 0, phase = 0, demo = false }
local VIGN_VIOLET = { red = 0.52, green = 0.30, blue = 1.0 }
local VIGN_PAD = 64                -- window-ring halo room around the frame
-- window ring: a neon glow, not stacked strokes — soft halo + crisp line
local VIGN_WIN_LAYERS = { { w = 8, a = 0.30, blur = 40, ba = 0.90 },
                          { w = 2, a = 0.95, blur = 12, ba = 0.80 } }

-- 5-stop ease-out falloff: fuses into the screen instead of blotching
local function vignStops(color, peak)
  local function s(a)
    return { red = color.red, green = color.green, blue = color.blue, alpha = a }
  end
  return { s(peak), s(peak * 0.55), s(peak * 0.25), s(peak * 0.075), s(0) }
end

-- soft light-orb gradient: lightened core melting into the accent
local function vignFlowStops(color)
  local function s(r, g, b, a) return { red = r, green = g, blue = b, alpha = a } end
  local cr, cg, cb = (color.red + 1) / 2, (color.green + 1) / 2, (color.blue + 1) / 2
  return { s(cr, cg, cb, 0.50), s(color.red, color.green, color.blue, 0.22),
           s(color.red, color.green, color.blue, 0.08),
           s(color.red, color.green, color.blue, 0.02),
           s(color.red, color.green, color.blue, 0) }
end

-- four linear-gradient strips, one per edge; the corner overlaps blend into
-- naturally brighter corners — a true vignette without radial-gradient fuss
local function vignLayer(f, color, peak, thick)
  local c = hs.canvas.new(f)
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)
  local th = math.max(60, math.min(f.w, f.h) * thick)
  local stops = vignStops(color, peak)
  c[1] = { type = "rectangle", action = "fill", fillGradient = "linear",
           fillGradientColors = stops, fillGradientAngle = 90,
           frame = { x = 0, y = 0, w = f.w, h = th } }              -- top
  c[2] = { type = "rectangle", action = "fill", fillGradient = "linear",
           fillGradientColors = stops, fillGradientAngle = 270,
           frame = { x = 0, y = f.h - th, w = f.w, h = th } }       -- bottom
  c[3] = { type = "rectangle", action = "fill", fillGradient = "linear",
           fillGradientColors = stops, fillGradientAngle = 0,
           frame = { x = 0, y = 0, w = th, h = f.h } }              -- left
  c[4] = { type = "rectangle", action = "fill", fillGradient = "linear",
           fillGradientColors = stops, fillGradientAngle = 180,
           frame = { x = f.w - th, y = 0, w = th, h = f.h } }       -- right
  c:alpha(0)
  return c
end

local function vignDelete()
  if vign.base  then vign.base:delete();  vign.base  = nil end
  if vign.voice then vign.voice:delete(); vign.voice = nil end
  if vign.win   then vign.win:delete();   vign.win   = nil end
  if vign.flowL then vign.flowL:delete(); vign.flowL = nil end
  if vign.flowR then vign.flowR:delete(); vign.flowR = nil end
  vign.winObj = nil
end

-- two pre-rendered light orbs that drift along the side edges — the energy.
-- Motion comes from MOVING the canvas window each tick (no re-render), so
-- the flow costs as little as the alpha animation does.
local function vignFlowBuild(f)
  local FS = math.floor(math.min(f.w, f.h) * 0.38)
  local function orb()
    local c = hs.canvas.new({ x = f.x, y = f.y, w = FS, h = FS })
    c:level(hs.canvas.windowLevels.overlay)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c:clickActivating(false)
    c[1] = { type = "oval", action = "fill", fillGradient = "radial",
             fillGradientColors = vignFlowStops(C.vignetteColor) }
    c:alpha(0)
    return c
  end
  vign.flowL, vign.flowR, vign.flowFS = orb(), orb(), FS
end

-- second ring: a glow hugging the window you're dictating INTO — the most
-- precise "your words land here" signal. Skipped for (near-)fullscreen
-- windows, where the screen border already is the window border.
local function vignWinBuild(win)
  if vign.win then vign.win:delete(); vign.win = nil end
  vign.winObj = nil
  if not (C.vignetteWindow and win) then return end
  local ok, f = pcall(function() return win:frame() end)
  if not ok or not f or f.w < 80 or f.h < 60 then return end
  local sf = vign.frame
  if sf and f.w >= sf.w - 24 and f.h >= sf.h - 24 then return end
  local c = hs.canvas.new({ x = f.x - VIGN_PAD, y = f.y - VIGN_PAD,
                            w = f.w + 2 * VIGN_PAD, h = f.h + 2 * VIGN_PAD })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)
  local col = (vign.tint == "work") and VIGN_VIOLET or C.vignetteColor
  for i, L in ipairs(VIGN_WIN_LAYERS) do
    c[i] = { type = "rectangle", action = "stroke",
             strokeColor = { red = col.red, green = col.green,
                             blue = col.blue, alpha = L.a },
             strokeWidth = L.w,
             roundedRectRadii = { xRadius = 14, yRadius = 14 },
             withShadow = true,
             shadow = { blurRadius = L.blur, offset = { h = 0, w = 0 },
                        color = { red = col.red, green = col.green,
                                  blue = col.blue, alpha = L.ba } },
             frame = { x = VIGN_PAD, y = VIGN_PAD, w = f.w, h = f.h } }
  end
  c:alpha(0)
  c:show()
  vign.win, vign.winObj, vign.winFrame, vign.winCheck = c, win, f, 0
end

-- (re)build for the screen holding keyboard focus — that's where you dictate
local function vignEnsure()
  local f = hs.screen.mainScreen():fullFrame()
  if vign.base and vign.frame and vign.frame.x == f.x and vign.frame.y == f.y
     and vign.frame.w == f.w and vign.frame.h == f.h then return end
  vignDelete()
  vign.frame = f
  vign.base  = vignLayer(f, C.vignetteColor, 0.75, 0.085)
  vign.voice = vignLayer(f, C.vignetteColor, 0.95, 0.20)
  vignFlowBuild(f)
  vign.tint  = "rec"
end

local function vignRecolor(color, tint)
  if not vign.base or vign.tint == tint then return end
  vign.tint = tint
  for i = 1, 4 do
    vign.base[i].fillGradientColors  = vignStops(color, 0.75)
    vign.voice[i].fillGradientColors = vignStops(color, 0.95)
  end
  for _, orb in ipairs({ vign.flowL, vign.flowR }) do
    if orb then orb[1].fillGradientColors = vignFlowStops(color) end
  end
  if vign.win then
    for i, L in ipairs(VIGN_WIN_LAYERS) do
      vign.win[i].strokeColor = { red = color.red, green = color.green,
                                  blue = color.blue, alpha = L.a }
      vign.win[i].shadow = { blurRadius = L.blur, offset = { h = 0, w = 0 },
                             color = { red = color.red, green = color.green,
                                       blue = color.blue, alpha = L.ba } }
    end
  end
end

local function vignTick()
  if not vign.base then return end
  vign.phase = vign.phase + 0.05
  if vign.anim == "in" then
    vign.animT = math.min(1, vign.animT + 0.11)
    if vign.animT >= 1 then vign.anim = nil end
  elseif vign.anim == "out" then
    vign.animT = math.max(0, vign.animT - 0.15)
    if vign.animT <= 0 then
      vign.base:hide(); vign.voice:hide()
      if vign.win then vign.win:hide() end
      if vign.flowL then vign.flowL:hide(); vign.flowR:hide() end
      if vign.timer then vign.timer:stop(); vign.timer = nil end
      vign.mode, vign.anim = nil, nil
      return
    end
  end
  local env = vign.animT * (2 - vign.animT)          -- easeOutQuad envelope
  local baseA, voiceA, winA, flowA
  if vign.mode == "work" then
    -- whisper is thinking: both layers breathe violet, slow and calm
    vign.level = vign.level * 0.85
    local breathe = 0.5 + 0.5 * math.sin(vign.phase * 2.6)
    baseA  = 0.42 + 0.20 * breathe
    voiceA = math.max(0.20 + 0.18 * breathe,
                      0.5 * math.min(1, vign.level / 0.16))
    winA   = 0.30 + 0.22 * breathe
    flowA  = 0.08 + 0.08 * breathe
  else
    -- live mic: bloom fast on speech (attack .75), follow drops quickly too
    -- (release .16) — sox --buffer 1024 feeds fresh samples every ~32ms, so
    -- the glow can afford to trust the signal instead of smoothing it away
    local raw
    if vign.demo then
      raw = math.max(0, math.sin(vign.phase * 5.2)) * 0.35
            * (0.6 + 0.4 * math.sin(vign.phase * 1.3))
    else
      raw = (state == "recording") and micLevel() or 0
    end
    local k = (raw > vign.level) and 0.75 or 0.16
    vign.level = vign.level + (raw - vign.level) * k
    local norm = math.min(1, vign.level / 0.16) ^ 0.7
    local breathe = 0.02 + 0.02 * math.sin(vign.phase * 3.4)
    baseA  = 0.32 + 0.20 * norm + breathe
    voiceA = 0.90 * norm
    winA   = 0.22 + 0.72 * norm
    flowA  = 0.10 + 0.40 * norm
  end
  vign.base:alpha(baseA * env)
  vign.voice:alpha(voiceA * env)
  -- the energy: light orbs drifting along the side edges — left rises,
  -- right descends, both wobbling gently. Voice charges their brightness.
  if vign.flowL then
    local f, FS = vign.frame, vign.flowFS
    local wob = math.sin(vign.phase * 1.7) * FS * 0.06
    local pL = (vign.phase * 0.14) % 1
    local pR = (vign.phase * 0.11 + 0.5) % 1
    vign.flowL:topLeft({ x = f.x - FS * 0.55,
                         y = f.y + f.h * (1.10 - 1.20 * pL) - FS / 2 + wob })
    vign.flowR:topLeft({ x = f.x + f.w - FS * 0.45,
                         y = f.y + f.h * (1.20 * pR - 0.10) - FS / 2 - wob })
    vign.flowL:alpha(flowA * env)
    vign.flowR:alpha(flowA * env)
  end
  if vign.win then
    vign.win:alpha(winA * env)
    -- follow the target window if it moves or resizes (~2x per second)
    vign.winCheck = vign.winCheck + 1
    if vign.winCheck % 10 == 0 and vign.winObj then
      local ok, f = pcall(function() return vign.winObj:frame() end)
      if ok and f then
        local o = vign.winFrame
        if f.x ~= o.x or f.y ~= o.y or f.w ~= o.w or f.h ~= o.h then
          if f.w == o.w and f.h == o.h then
            vign.win:topLeft({ x = f.x - VIGN_PAD, y = f.y - VIGN_PAD })
            vign.winFrame = f
          else
            vignWinBuild(vign.winObj)
          end
        end
      else
        vign.win:hide()               -- window closed mid-dictation
        vign.win:delete(); vign.win, vign.winObj = nil, nil
      end
    end
  end
end

local function vignShow()
  if not C.vignette then return end
  vignEnsure()
  vignRecolor(C.vignetteColor, "rec")
  vign.mode = "rec"
  vignWinBuild(hs.window.focusedWindow())
  if not vign.base:isShowing() then
    vign.level, vign.animT = 0, 0
    vign.base:show(); vign.voice:show()
    if vign.flowL then vign.flowL:show(); vign.flowR:show() end
  end
  vign.anim = "in"                       -- also rescues a mid-exit fade
  if not vign.timer then
    vign.timer = hs.timer.doEvery(CORES <= 2 and 0.12 or 0.05,
                                  safeTick("vignTick", vignTick))
  end
end

local function vignWork()
  if not (C.vignette and vign.base and vign.mode) then return end
  vign.mode = "work"
  vignRecolor(VIGN_VIOLET, "work")
end

local function vignHide()
  if not vign.mode then
    if vign.timer then vign.timer:stop(); vign.timer = nil end
    if vign.base then vign.base:hide(); vign.voice:hide() end
    if vign.win then vign.win:hide() end
    if vign.flowL then vign.flowL:hide(); vign.flowR:hide() end
    return
  end
  vign.anim = "out"                      -- vignTick finishes the exit
end

-- fake a full dictation cycle so the effect can be seen without speaking
local function vignDemo()
  vign.demo = true
  vignShow()
  hs.timer.doAfter(6, function() vignWork() end)
  hs.timer.doAfter(9, function() vign.demo = false; vignHide() end)
end

-- ------------------------------------------------------------
-- LOOM-STYLE SCREEN RECORDING
-- ------------------------------------------------------------
local screenRec = {
  active = false,
  task = nil,
  camTask = nil,
  startTime = 0,
  seconds = 0,
  timer = nil,
  outputPath = "",
  hud = nil,
}
_G.screenRec = screenRec

local startScreenRecording, stopScreenRecording, toggleScreenRecording

local function formatRecTime(sec)
  local m = math.floor(sec / 60)
  local s = sec % 60
  return string.format("%02d:%02d", m, s)
end

function toggleScreenRecording()
  if screenRec.active then
    stopScreenRecording()
  else
    startScreenRecording()
  end
end
_G.toggleScreenRecording = toggleScreenRecording

function startScreenRecording()
  if screenRec.active then
    stopScreenRecording()
    return
  end

  local recDir = C.screenRecDir or (HOME .. "/Movies/VoxRecordings")
  os.execute("/bin/mkdir -p '" .. recDir .. "' 2>/dev/null")

  local dateStr = os.date("%Y-%m-%d_%H-%M-%S")
  screenRec.outputPath = recDir .. "/Vox_Recording_" .. dateStr .. ".mp4"
  screenRec.active = true
  screenRec.seconds = 0
  screenRec.startTime = os.time()

  -- 1. Launch Webcam Bubble if enabled
  if C.screenRecWebcam then
    os.execute("/usr/bin/killall -9 cam-bin 2>/dev/null")
    local camBin = HOME .. "/vox/cam-bin"
    local camSwift = HOME .. "/vox/cam.swift"
    if not hs.fs.attributes(camBin) and hs.fs.attributes(camSwift) then
      os.execute("/usr/bin/swiftc -O '" .. camSwift .. "' -o '" .. camBin .. "' 2>/dev/null")
    end
    if hs.fs.attributes(camBin) then
      screenRec.camTask = hs.task.new(camBin, function(code)
        log("camTask exit code: " .. tostring(code))
      end, {
        "--size", tostring(C.screenRecWebcamSize or 240),
        "--position", C.screenRecWebcamPos or "bottom-left"
      })
      screenRec.camTask:start()
    end
  end

  -- 2. Launch ffmpeg process targeting active screen
  local ffmpegBin = C.ffmpeg or "/usr/local/bin/ffmpeg"
  if not hs.fs.attributes(ffmpegBin) then ffmpegBin = "/opt/homebrew/bin/ffmpeg" end
  if not hs.fs.attributes(ffmpegBin) then ffmpegBin = "/usr/bin/ffmpeg" end

  local activeScreen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local allScreens = hs.screen.allScreens()
  local targetScreenIndex = 1
  for idx, scr in ipairs(allScreens) do
    if scr:id() == activeScreen:id() then
      targetScreenIndex = idx
      break
    end
  end

  local screenDeviceInput = tostring(targetScreenIndex) .. ":none"

  local args = {
    "-f", "avfoundation",
    "-pixel_format", "nv12",
    "-i", screenDeviceInput,
    "-vf", "scale=2560:-2",
    "-c:v", "h264_videotoolbox",
    "-allow_sw", "1",
    "-b:v", "6M",
    "-movflags", "+frag_keyframe+empty_moov",
    "-y",
    screenRec.outputPath
  }

  screenRec.task = hs.task.new(ffmpegBin, function(code, stdOut, stdErr)
    log("ffmpeg finished code: " .. tostring(code) .. " stdErr: " .. tostring(stdErr))
    if code ~= 0 then
      os.execute("echo 'FFMPEG ERR (" .. tostring(code) .. "): " .. (stdErr or ""):gsub("'", "") .. "' >> /tmp/vox_ffmpeg.log")
    end
  end, args)

  screenRec.task:start()
  play("start")
  hs.alert.show("🎥 Voom Started (⌥⇧R to stop)", 2.0)

  -- 3. Create Screen Recording HUD Widget
  local mainScreen = hs.screen.mainScreen()
  local screenFrame = mainScreen and mainScreen:frame() or { x = 0, y = 0, w = 1920, h = 1080 }
  local hudW, hudH = 340, 46
  local hudX = screenFrame.x + (screenFrame.w - hudW) / 2
  local hudY = screenFrame.y + screenFrame.h - hudH - 35

  local c = hs.canvas.new({ x = hudX, y = hudY, w = hudW, h = hudH })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })

  -- 1. Container background
  c[1] = {
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0.08, green = 0.09, blue = 0.12, alpha = 0.92 },
    roundedRectRadii = { xRadius = 23, yRadius = 23 },
    strokeColor = { red = 0.2, green = 0.85, blue = 0.75, alpha = 0.8 },
    strokeWidth = 1.5,
  }
  -- 2. Red recording dot
  c[2] = {
    type = "oval",
    action = "fill",
    fillColor = { red = 1.0, green = 0.2, blue = 0.3, alpha = 1.0 },
    frame = { x = 16, y = 16, w = 14, h = 14 }
  }
  -- 3. Timer text
  c[3] = {
    type = "text",
    text = "00:00",
    textColor = { red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0 },
    textFont = ".AppleSystemUIFontBold",
    textSize = 15,
    frame = { x = 36, y = 13, w = 55, h = 24 }
  }
  -- 4 & 5. ALIEN 👽 BUTTON
  c[4] = {
    type = "oval",
    action = "fill",
    fillColor = { red = 0.15, green = 0.45, blue = 0.35, alpha = 0.9 },
    strokeColor = { red = 0.3, green = 0.95, blue = 0.75, alpha = 1.0 },
    strokeWidth = 1.2,
    frame = { x = 96, y = 9, w = 28, h = 28 },
    trackMouseDown = true
  }
  c[5] = {
    type = "text",
    text = "👽",
    textSize = 16,
    textAlignment = "center",
    frame = { x = 96, y = 11, w = 28, h = 24 },
    trackMouseDown = true
  }
  -- 6 & 7. CAM 📷 BUTTON
  c[6] = {
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0.18, green = 0.22, blue = 0.30, alpha = 0.85 },
    roundedRectRadii = { xRadius = 8, yRadius = 8 },
    frame = { x = 132, y = 10, w = 62, h = 26 },
    trackMouseDown = true
  }
  c[7] = {
    type = "text",
    text = C.screenRecWebcam and "📷 Cam" or "📷 OFF",
    textColor = { red = 0.85, green = 0.9, blue = 0.95, alpha = 1.0 },
    textFont = ".AppleSystemUIFontBold",
    textSize = 11,
    textAlignment = "center",
    frame = { x = 132, y = 14, w = 62, h = 20 },
    trackMouseDown = true
  }
  -- 8 & 9. STOP ⏹ BUTTON
  c[8] = {
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0.9, green = 0.25, blue = 0.25, alpha = 0.9 },
    roundedRectRadii = { xRadius = 8, yRadius = 8 },
    frame = { x = 202, y = 10, w = 65, h = 26 },
    trackMouseDown = true
  }
  c[9] = {
    type = "text",
    text = "⏹ Stop",
    textColor = { red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0 },
    textFont = ".AppleSystemUIFontBold",
    textSize = 12,
    textAlignment = "center",
    frame = { x = 202, y = 14, w = 65, h = 20 },
    trackMouseDown = true
  }
  -- 10 & 11. CANCEL ✖ BUTTON
  c[10] = {
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0.25, green = 0.28, blue = 0.35, alpha = 0.8 },
    roundedRectRadii = { xRadius = 8, yRadius = 8 },
    frame = { x = 275, y = 10, w = 52, h = 26 },
    trackMouseDown = true
  }
  c[11] = {
    type = "text",
    text = "✖ Cancel",
    textColor = { red = 0.8, green = 0.8, blue = 0.85, alpha = 1.0 },
    textFont = ".AppleSystemUIFont",
    textSize = 11,
    textAlignment = "center",
    frame = { x = 275, y = 14, w = 52, h = 20 },
    trackMouseDown = true
  }

  c:mouseCallback(function(canvas, event, id, x, y)
    if event == "mouseDown" then
      if id == 4 or id == 5 then
        play("send")
        local quotes = {
          "👽 Vox Alien: Recording live! Show them the magic! ✨",
          "👽 Vox Alien: Rolling! You're crushing this video!",
          "👽 Vox Alien: Mic is hot and screen is sharp! 🚀",
          "👽 Vox Alien: Peak vibe recording in progress!"
        }
        local msg = quotes[math.random(#quotes)]
        hs.alert.show(msg, 2.0)
      elseif id == 6 or id == 7 then
        C.screenRecWebcam = not C.screenRecWebcam
        if screenRec.camTask then
          screenRec.camTask:terminate()
          screenRec.camTask = nil
          os.execute("/usr/bin/killall cam-bin 2>/dev/null")
        elseif C.screenRecWebcam then
          local camBin = HOME .. "/vox/cam-bin"
          if hs.fs.attributes(camBin) then
            screenRec.camTask = hs.task.new(camBin, nil, {
              "--size", tostring(C.screenRecWebcamSize or 180),
              "--position", C.screenRecWebcamPos or "bottom-left"
            })
            screenRec.camTask:start()
          end
        end
        if screenRec.hud then
          screenRec.hud[7].text = C.screenRecWebcam and "📷 Cam" or "📷 OFF"
        end
        hs.alert.show("Webcam Circle: " .. (C.screenRecWebcam and "ON" or "OFF"), 1.2)
      elseif id == 8 or id == 9 then
        stopScreenRecording()
      elseif id == 10 or id == 11 then
        cancelScreenRecording()
      end
    end
  end)

  c:show()
  screenRec.hud = c

  screenRec.timer = hs.timer.doEvery(1.0, safeTick("screenRecTimer", function()
    if not screenRec.active then return end
    screenRec.seconds = screenRec.seconds + 1
    if screenRec.hud then
      screenRec.hud[3].text = formatRecTime(screenRec.seconds)
      local dotAlpha = (screenRec.seconds % 2 == 0) and 1.0 or 0.3
      screenRec.hud[2].fillColor.alpha = dotAlpha
    end
  end))
end

function stopScreenRecording()
  if not screenRec.active then return end
  screenRec.active = false

  if screenRec.timer then
    screenRec.timer:stop()
    screenRec.timer = nil
  end

  if screenRec.hud then
    screenRec.hud:delete()
    screenRec.hud = nil
  end

  if screenRec.camTask then
    screenRec.camTask:terminate()
    screenRec.camTask = nil
  end
  os.execute("/usr/bin/killall cam-bin 2>/dev/null")

  if screenRec.task then
    local pid = screenRec.task:pid()
    if pid and pid > 0 then
      os.execute("/bin/kill -INT " .. tostring(pid) .. " 2>/dev/null")
    else
      pcall(function() screenRec.task:terminate() end)
    end
    local taskToClean = screenRec.task
    screenRec.task = nil
    hs.timer.doAfter(1.0, function()
      if taskToClean and taskToClean:isRunning() then
        pcall(function() taskToClean:terminate() end)
      end
    end)
  end

  play("done")
  local savePath = screenRec.outputPath
  local recTime = screenRec.seconds

  local checkCount = 0
  local function verifySave()
    checkCount = checkCount + 1
    local attr = hs.fs.attributes(savePath)
    if attr and attr.size and attr.size > 0 then
      hs.pasteboard.setContents(savePath)

      -- Auto-reveal in Finder
      hs.execute("/usr/bin/open -R '" .. savePath .. "'")

      local n = hs.notify.new(function(notif)
        local act = notif:activationType()
        if act == hs.notify.activationTypes.actionButtonClicked
           or act == hs.notify.activationTypes.contentsClicked then
          hs.execute("open '" .. savePath .. "'")
        end
      end)
      n:title("🎥 Voom Video Saved!")
      n:subTitle("Duration: " .. formatRecTime(recTime))
      n:informativeText("Saved to: " .. savePath .. "\nRevealed in Finder & copied to clipboard!")
      n:actionButtonTitle("Open Video")
      n:hasActionButton(true)
      n:send()

      hs.alert.show("🎥 Voom video saved & revealed in Finder! (" .. formatRecTime(recTime) .. ")", 3.0)
    elseif checkCount < 7 then
      hs.timer.doAfter(0.5, verifySave)
    else
      hs.alert.show("❌ Voom video failed to save", 2.5)
    end
  end

  hs.timer.doAfter(0.5, verifySave)
end

function cancelScreenRecording()
  if not screenRec.active then return end
  screenRec.active = false

  if screenRec.timer then screenRec.timer:stop(); screenRec.timer = nil end
  if screenRec.hud then screenRec.hud:delete(); screenRec.hud = nil end
  if screenRec.camTask then screenRec.camTask:terminate(); screenRec.camTask = nil end
  os.execute("/usr/bin/killall cam-bin 2>/dev/null")

  if screenRec.task then screenRec.task:terminate(); screenRec.task = nil end

  local savePath = screenRec.outputPath
  hs.timer.doAfter(0.5, function()
    if savePath and hs.fs.attributes(savePath) then
      os.remove(savePath)
    end
  end)

  hs.alert.show("🗑️ Recording cancelled", 1.5)
end

function showWebcamOverlay()
  local camBin = HOME .. "/vox/cam-bin"
  local camSwift = HOME .. "/vox/cam.swift"
  if not hs.fs.attributes(camBin) and hs.fs.attributes(camSwift) then
    os.execute("/usr/bin/swiftc -O '" .. camSwift .. "' -o '" .. camBin .. "' 2>/dev/null")
  end
  if hs.fs.attributes(camBin) then
    os.execute("/usr/bin/killall cam-bin 2>/dev/null")

    -- 1. Calculate Alien Hub Origin (Floating Widget)
    local mainScreen = hs.screen.mainScreen():frame()
    local alienPos = C.alienPos or { x = mainScreen.w / 2, y = mainScreen.h / 2 }
    local alienX = alienPos.x + 35
    local alienY = (mainScreen.h - alienPos.y) - 35

    -- 2. Calculate Active Focused Window Bottom-Right Docking Frame
    local size = C.screenRecWebcamSize or 260
    local width = size * 1.4
    local height = size * 0.95
    local targetX, targetY

    local win = hs.window.focusedWindow()
    if win and win:title() ~= "" and win:role() == "AXWindow" then
      local f = win:frame()
      targetX = f.x + f.w - width - 15
      targetY = (mainScreen.h - (f.y + f.h)) + 15
    else
      targetX = mainScreen.w - width - 35
      targetY = 35
    end

    screenRec.camTask = hs.task.new(camBin, function(code)
      log("camTask exit code: " .. tostring(code))
    end, {
      "--size", tostring(size),
      "--position", C.screenRecWebcamPos or "bottom-right",
      "--mode", C.screenRecBgMode or "mint",
      "--alienX", tostring(alienX),
      "--alienY", tostring(alienY),
      "--targetX", tostring(targetX),
      "--targetY", tostring(targetY)
    })
    screenRec.camTask:start()
    hs.alert.show("🧞‍♂️ Presenter Camera Genie Fly-Out (⌥⇧C)", 1.5)
  end
end

function hideWebcamOverlay()
  if screenRec.camTask then
    screenRec.camTask:terminate()
    screenRec.camTask = nil
  end
  os.execute("/usr/bin/killall cam-bin 2>/dev/null")
  hs.alert.show("📹 Presenter Camera Overlay OFF", 1.5)
end

function toggleWebcamOverlay()
  local p = io.popen("pgrep -f cam-bin")
  local out = p and p:read("*a") or ""
  if p then p:close() end
  if out ~= "" then
    hideWebcamOverlay()
  else
    showWebcamOverlay()
  end
end

_G.startScreenRecording  = startScreenRecording
_G.stopScreenRecording   = stopScreenRecording
_G.cancelScreenRecording  = cancelScreenRecording
_G.showWebcamOverlay     = showWebcamOverlay
_G.hideWebcamOverlay     = hideWebcamOverlay
_G.toggleWebcamOverlay   = toggleWebcamOverlay

pcall(function()
  hs.hotkey.bind({"alt", "shift"}, "C", function()
    toggleWebcamOverlay()
  end)
end)

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
  if mode == "rec" or mode == "lock" then
    hudShow("rec"); vign.demo = false; vignShow()
    bubbleShow(recMode == "ask" and "👽 Ask mode — listening..." or "🎤 Listening...", 0)
  elseif mode == "work" then
    hudShow("work"); vignWork()
    bubbleShow("⚡ Transcribing...", 0)
  else
    hudHide(); vignHide(); bubbleHide()
  end
end

local function reset()
  state, locked, pendingTap, recMode = "idle", false, false, "dictate"
  duckUp()
  if timers.maxRec then timers.maxRec:stop() end
  if timers.stuckKey then timers.stuckKey:stop() end
  if timers.uiDelay then timers.uiDelay:stop(); timers.uiDelay = nil end
  if timers.procWatch then timers.procWatch:stop(); timers.procWatch = nil end
  if timers.convVAD then timers.convVAD:stop(); timers.convVAD = nil end
  if timers.convCap then timers.convCap:stop(); timers.convCap = nil end
  if timers.convDeaf then timers.convDeaf:stop(); timers.convDeaf = nil end
  if timers.convTick then timers.convTick:stop(); timers.convTick = nil end
  if timers.soxKill then timers.soxKill:stop(); timers.soxKill = nil end
  if timers.soxKill9 then timers.soxKill9:stop(); timers.soxKill9 = nil end
  os.remove(C.wav); os.remove(C.wavNorm)  -- privacy: no voice residue on disk
  setUI("idle")
  -- conversation mode must survive empty/failed utterances: every reset
  -- while the mode is ON re-arms the mic (toggle-OFF clears convMode first,
  -- so a deliberate exit never lands here)
  if convMode then
    timers.convRearm = hs.timer.doAfter(0.4, function()
      timers.convRearm = nil
      if convMode and state == "idle" then
        log("Conversation Mode: re-arming after empty/failed utterance")
        locked = true
        startRecording()
      end
    end)
  end
end

-- ---------------- whisper server (keeps model in RAM) --------
local function serverRunning()
  -- [r] trick: the pattern won't match its own shell command line
  local p = io.popen("/usr/bin/pgrep -f 'whisper-serve[r].*" .. C.serverPort .. "' 2>/dev/null")
  local out = p:read("*a"); p:close()
  return out ~= nil and out ~= ""
end

local function fastServerRunning()
  local p = io.popen("/usr/bin/pgrep -f 'whisper-serve[r].*" .. C.serverPortFast .. "' 2>/dev/null")
  local out = p:read("*a"); p:close()
  return out ~= nil and out ~= ""
end

local function ensureFastServer()
  if C.whisperHost ~= "127.0.0.1" then return end
  if not (C.speculativeDraft and hs.fs.attributes(C.fastModel)) then return end
  if fastServerRunning() then return end
  M.fastServerTask = hs.task.new(C.whisperSrv, function(code)
    log("whisper-server-fast exited (code " .. tostring(code) .. ")")
  end, {
    "-m", C.fastModel, "--host", C.serverBind, "--port", tostring(C.serverPortFast),
    "-t", "2", "-l", C.language, "-bo", "1", "-nf", "--prompt", fullVocabulary(),
  })
  M.fastServerTask:start()
  log("whisper-server-fast starting on " .. C.serverBind .. ":" .. C.serverPortFast)
end

local function ensureServer()
  if C.whisperHost ~= "127.0.0.1" then return end  -- thin client: server is remote
  ensureFastServer()
  if serverRunning() then return end
  local spawnedAt = hs.timer.secondsSinceEpoch()
  M.serverTask = hs.task.new(C.whisperSrv, function(code)
    log("whisper-server exited (code " .. tostring(code) .. ")")
    -- respawn instead of waiting to be missed: without this, dictation
    -- limps on the slow CLI path until a self-test or hotkey press notices.
    -- Exponential backoff so a server that can't start at all (deleted
    -- model, bad flag) settles at one attempt / 90s instead of a tight
    -- loop; a minute of healthy uptime resets the clock.
    if hs.timer.secondsSinceEpoch() - spawnedAt > 60 then M.srvCrashes = 0 end
    M.srvCrashes = math.min((M.srvCrashes or 0) + 1, 6)
    timers.srvRespawn = hs.timer.doAfter(
      math.min(90, 3 * 2 ^ (M.srvCrashes - 1)), ensureServer)
  end, {
    "-m", C.model, "--host", C.serverBind, "--port", tostring(C.serverPort),
    "-t", C.threads, "-l", C.language, "-bo", "1", "-nf", "--prompt", fullVocabulary(),
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
  elseif convMode and lastPasteApp == context.app
     and lastPasteTail and lastPasteTail:find("%w")
     and text:find("^[%w\"'%(%[]") then
    -- conv chunks cut MID-SENTENCE: previous chunk often ends on a bare
    -- word ("...conversation, which") — without this bridge the next
    -- chunk glues on ("whichCool")
    text = " " .. text
  end
  lastPasteTail, lastPasteApp = text:sub(-1), context.app

  rememberPaste(text)
  local prev = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)
  -- Clean paste: explicit key event with ONLY cmd flag (overwrites any residual hardware alt/fn flags)
  local vCode = hs.keycodes.map["v"] or 9
  local keyDown = hs.eventtap.event.newKeyEvent(vCode, true)
  keyDown:setFlags({ cmd = true })
  keyDown:post()
  local keyUp = hs.eventtap.event.newKeyEvent(vCode, false)
  keyUp:setFlags({ cmd = true })
  keyUp:post()

  if not C.keepInClipboard then
    -- restore what the user had copied — but only if the clipboard still
    -- holds OUR text (never stomp something they copied in the meantime)
    timers.clipRestore = hs.timer.doAfter(0.8, function()
      if prev and hs.pasteboard.getContents() == text then
        hs.pasteboard.setContents(prev)
      end
    end)
  end
  rememberText(text, nextMemMode)         -- the alien remembers
  nextMemMode = "dictate"
  if convMode then
    -- gapless conversation flow: the mic is LIVE while this paste lands.
    -- Do NOT idle the state machine, beep the speakers (the mic hears
    -- them), hide the recording UI, or touch C.wav — that's the recorder's
    -- open file, not our finished chunk.
    hudEmote(detectEmotion(text))
    if activeSendTrigger then          -- serial-path utterance ended "ok go"
      local trig = activeSendTrigger
      activeSendTrigger = nil
      hs.timer.doAfter(0.25, function()
        local retCode = hs.keycodes.map["return"] or 36
        local rDown = hs.eventtap.event.newKeyEvent(retCode, true)
        rDown:setFlags({}); rDown:post()
        local rUp = hs.eventtap.event.newKeyEvent(retCode, false)
        rUp:setFlags({}); rUp:post()
        log("auto-submitted via '" .. trig .. "' — watching for LLM")
        watchLLMCompletion(hs.window.focusedWindow())
        alienQuip("sent")          -- mic stays LIVE; quip rides the mute window
        hs.alert.show("📨 Sent — still listening. Bell = reply landed.", 3)
      end)
    end
    return
  end
  play("done")
  -- idle everything, but let the alien react to what you said first
  state, locked, pendingTap = "idle", false, false
  duckUp()
  vignHide()                              -- words landed — glow fades now
  if timers.maxRec then timers.maxRec:stop() end
  if menubar then menubar:setIcon(icons.idle, true) end
  hudEmote(detectEmotion(text))
  -- keep ONLY this clip (private 0700 scratch, replaced each dictation):
  -- when words get dropped we can replay the actual audio instead of
  -- guessing. Cancelled recordings are still deleted outright.
  os.rename(C.wav, tmp("last-dictation.wav")); os.remove(C.wavNorm)

  if convMode then
    if activeSendTrigger then
      local trig = activeSendTrigger
      activeSendTrigger = nil
      hs.timer.doAfter(0.12, function()
        local retCode = hs.keycodes.map["return"] or 36
        local rDown = hs.eventtap.event.newKeyEvent(retCode, true)
        rDown:setFlags({})
        rDown:post()
        local rUp = hs.eventtap.event.newKeyEvent(retCode, false)
        rUp:setFlags({})
        rUp:post()
        log("auto-submitted prompt via '" .. trig .. "' trigger — watching for LLM response")
        watchLLMCompletion(context.winObj or hs.window.focusedWindow())
      end)
    else
      -- Regular pause dictation (no send keyword like "ok go"):
      -- Re-arm mic after 0.25s so Conversation Mode stays ON continuously!
      hs.timer.doAfter(0.25, function()
        if convMode and state == "idle" then
          log("Conversation Mode: re-arming mic hands-free")
          locked = true
          startRecording()
        end
      end)
    end
  end
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
    speakAlien(answer)
    state, locked, pendingTap = "idle", false, false
    duckUp()
    vignHide()
    if menubar then menubar:setIcon(icons.idle, true) end
    hudEmote("excite")
  end
end

-- streaming ask: Ollama's token stream -> sentences -> the speech queue.
-- Vox starts TALKING while the model is still writing the rest — perceived
-- latency collapses from "whole answer generated" to "first sentence born".
-- All local: ollama and the speech server both live on 127.0.0.1.
local function streamAsk(question)
  if CORES <= 2 and ollamaIsLocal() and not C.forceLocalLLM then
    memoryLookup(question, 3, function(mem)     -- old non-stream path guards
      llmGenerate(askPrompt(question, mem), "answer", true,
                  answerDeliver(question))
    end)
    return
  end
  memoryLookup(question, 3, function(mem)
    reqId = reqId + 1
    local myId = reqId
    local model = pickModel("answer", false)
    log("ask (streaming) using " .. model)
    hs.http.asyncPost("http://127.0.0.1:" .. SPEECH_PORT .. "/stop", "", nil,
                      function(status)
                        if status ~= 200 then
                          ensureSpeechServer()
                        elseif C.alienVoice then
                          -- instant "Hmm." while the real answer is born —
                          -- pre-rendered, so it's audible within ~300ms
                          hs.http.asyncPost("http://127.0.0.1:" .. SPEECH_PORT
                            .. "/ack", "", nil, function() end)
                        end
                      end)
    local bodyFile = tmp("ask.json")
    local f = io.open(bodyFile, "w")
    f:write(hs.json.encode({
      model = model, stream = true, prompt = askPrompt(question, mem),
      keep_alive = "24h", options = { temperature = 0.6 },
    }))
    f:close()
    local full, sentBuf, pending = "", "", ""
    local function flush()
      local s = sentBuf:gsub("[%*_#`]", ""):gsub("%s+", " ")
                       :gsub("^%s+", ""):gsub("%s+$", "")
      sentBuf = ""
      if #s == 0 then return end
      bubbleShow("👽 " .. s, 4)
      if not C.alienVoice then return end
      local payload = hs.json.encode({ text = s,
        voice = C.alienVoiceName or "vox", speed = C.alienVoiceSpeed or 1.0 })
      local function post(attempt)   -- server may still be warming: retry
        hs.http.asyncPost("http://127.0.0.1:" .. SPEECH_PORT .. "/queue",
          payload, nil, function(status)
            if status ~= 200 and attempt < 4 then
              ensureSpeechServer()
              timers["q" .. (myId % 8)] = hs.timer.doAfter(1.5, function()
                post(attempt + 1)
              end)
            end
          end)
      end
      post(1)
    end
    timers.llmTimeout = hs.timer.doAfter(C.llmTimeout + 20, function()
      if myId == reqId and state ~= "idle" then
        hs.alert.show("Vox: answer timed out", 3)
        reset()
      end
    end)
    M.askTask = hs.task.new("/usr/bin/curl", function(code)
      if myId ~= reqId then return end
      if timers.llmTimeout then timers.llmTimeout:stop() end
      flush()                                   -- speak any trailing words
      local answer = cleanLLMOutput(full)
      if code ~= 0 or #answer == 0 then
        hs.alert.show("Vox: answer failed — is Ollama running?", 3)
        reset()
        return
      end
      hs.pasteboard.setContents(answer)         -- ⌘V pastes it if wanted
      hs.alert.show("👽 " .. answer:sub(1, 400), 9)
      rememberText("Q: " .. question .. " — A: " .. answer, "answer")
      play("done")
      state, locked, pendingTap = "idle", false, false
      duckUp()
      vignHide()
      if menubar then menubar:setIcon(icons.idle, true) end
      hudEmote("excite")
    end, function(_, stdout)
      if myId ~= reqId then return false end
      pending = pending .. (stdout or "")       -- NDJSON lines can split
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then break end
        local line = pending:sub(1, nl - 1)
        pending = pending:sub(nl + 1)
        local ok, d = pcall(hs.json.decode, line)
        if ok and d and d.response then
          full = full .. d.response
          sentBuf = sentBuf .. d.response
          if (#sentBuf > 12 and sentBuf:find("[%.!%?…][\"')]?%s*$"))
             or #sentBuf > 240 then
            flush()
          end
        end
      end
      return true
    end, { "-sN", "--max-time", "90", "-X", "POST",
           "-d", "@" .. bodyFile, C.ollamaUrl })
    M.askTask:start()
  end)
end

-- ---------------- voice actions -------------------------------
-- The alien gets hands: "Hey Vox, open Safari" / ask-mode "close Slack".
-- Deterministic verb parser — no LLM in the loop, so actions fire instantly
-- and never hallucinate. Unrecognized utterances fall through to Q&A.
local APP_ALIASES = {
  ["chrome"] = "Google Chrome", ["google chrome"] = "Google Chrome",
  ["vs code"] = "Visual Studio Code", ["vscode"] = "Visual Studio Code",
  ["code"] = "Visual Studio Code", ["cursor"] = "Cursor",
  ["terminal"] = "Terminal", ["iterm"] = "iTerm",
  ["safari"] = "Safari", ["finder"] = "Finder", ["notes"] = "Notes",
  ["mail"] = "Mail", ["messages"] = "Messages", ["whatsapp"] = "WhatsApp",
  ["slack"] = "Slack", ["spotify"] = "Spotify", ["music"] = "Music",
  ["calendar"] = "Calendar", ["photos"] = "Photos", ["preview"] = "Preview",
  ["calculator"] = "Calculator", ["activity monitor"] = "Activity Monitor",
  ["settings"] = "System Settings", ["system settings"] = "System Settings",
  ["system preferences"] = "System Settings", ["claude"] = "Claude",
}

local SPOKEN_KEYS = {
  enter = "return", ["return"] = "return", escape = "escape", esc = "escape",
  tab = "tab", space = "space", spacebar = "space", delete = "delete",
  backspace = "delete", up = "up", down = "down", left = "left",
  right = "right", home = "home", ["end"] = "end",
}
local SPOKEN_MODS = { command = "cmd", cmd = "cmd", shift = "shift",
                      option = "alt", alt = "alt", control = "ctrl",
                      ctrl = "ctrl", fn = "fn" }

local function resolveApp(name)
  name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%.!%?,]+$", "")
  local lower = name:lower():gsub("^the%s+", ""):gsub("%s+app$", "")
  if APP_ALIASES[lower] then return APP_ALIASES[lower] end
  return (lower:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

local function actionSay(msg, icon)
  speakAlien(msg)
  hs.alert.show((icon or "👽") .. " " .. msg, 2)
end

-- the dictionary: single source of truth for what the alien can DO.
-- Rendered as the on-screen cheat sheet, the menubar submenu, and the
-- README table all come from here — add a verb, document it once.
local ACTION_DICT = {
  { "Apps", {
    { "open / launch / start <app>",   "opens or focuses it" },
    { "close / quit <app>",            "quits it gracefully" },
    { "force quit <app>",              "kills it immediately" },
    { "switch to / go to <app>",       "brings it to the front" },
    { "hide <app>",                    "hides its windows" },
  } },
  { "Windows", {
    { "close this window",             "closes the focused window" },
    { "minimize",                      "minimizes the focused window" },
    { "fullscreen",                    "toggles full screen" },
  } },
  { "Keyboard", {
    { "press <keys> · hit enter",      "press command shift F, hit escape…" },
  } },
  { "System", {
    { "volume up / volume down",       "nudges output ±12%" },
    { "mute / unmute",                 "output audio" },
    { "take a screenshot",             "presses ⌘⇧3" },
    { "voom / record screen",          "Voom screen & presenter recording (⌥⇧R)" },
    { "lock the screen",               "locks the Mac" },
  } },
  { "Brain", {
    { "hey vox, remember <fact>",      "saves it to local memory" },
    { "hey vox, <question>",           "answers out loud from memory" },
    { "what can you do",               "shows this dictionary" },
  } },
}

local help = { canvas = nil, timer = nil }
local function helpHide()
  if help.timer then help.timer:stop(); help.timer = nil end
  if help.canvas then help.canvas:delete(); help.canvas = nil end
end

local function helpShow()
  helpHide()
  local W, PAD, LH, HH = 620, 28, 22, 34
  local rows = 0
  for _, sec in ipairs(ACTION_DICT) do rows = rows + #sec[2] end
  local H = 96 + rows * LH + #ACTION_DICT * HH + PAD
  local f = hs.screen.mainScreen():frame()
  local c = hs.canvas.new({ x = f.x + (f.w - W) / 2,
                            y = f.y + (f.h - H) / 2, w = W, h = H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)
  c[1] = { type = "rectangle", action = "strokeAndFill",
           fillColor = { red = 0.05, green = 0.06, blue = 0.09, alpha = 0.96 },
           strokeColor = { red = 1.0, green = 0.31, blue = 0.85, alpha = 0.55 },
           strokeWidth = 2,
           roundedRectRadii = { xRadius = 18, yRadius = 18 },
           trackMouseDown = true }
  c[2] = { type = "text", text = "👽  Vox — voice dictionary",
           textSize = 20, textColor = { red = 1, green = 0.31, blue = 0.85, alpha = 1 },
           frame = { x = PAD, y = 20, w = W - 2 * PAD, h = 28 } }
  c[3] = { type = "text",
           text = "say it after “Hey Vox,” — or hold ⌘ and tap Left Shift · click to close",
           textSize = 11.5, textColor = { red = 1, green = 1, blue = 1, alpha = 0.45 },
           frame = { x = PAD, y = 50, w = W - 2 * PAD, h = 16 } }
  local y, i = 78, 3
  for _, sec in ipairs(ACTION_DICT) do
    i = i + 1
    c[i] = { type = "text", text = sec[1]:upper(),
             textSize = 11, textColor = { red = 0.61, green = 0.36, blue = 1, alpha = 0.95 },
             frame = { x = PAD, y = y + 10, w = W - 2 * PAD, h = 15 } }
    y = y + HH
    for _, it in ipairs(sec[2]) do
      i = i + 1
      c[i] = { type = "text", text = it[1], textSize = 13,
               textColor = { red = 1, green = 1, blue = 1, alpha = 0.95 },
               frame = { x = PAD, y = y, w = 300, h = LH } }
      i = i + 1
      c[i] = { type = "text", text = it[2], textSize = 13,
               textColor = { red = 1, green = 1, blue = 1, alpha = 0.5 },
               frame = { x = PAD + 310, y = y, w = W - PAD - 310 - PAD, h = LH } }
      y = y + LH
    end
  end
  c:canvasMouseEvents(true, false, false, false)
  c:mouseCallback(function() helpHide() end)
  c:show()
  help.canvas = c
  help.timer = hs.timer.doAfter(60, helpHide)
end

-- returns true if the utterance was an action and was handled
local function performAction(text)
  local t = text:lower():gsub("[%.!%?]+%s*$", ""):gsub("^%s+", "")
  t = t:gsub("^please%s+", ""):gsub("^can you%s+", ""):gsub("^could you%s+", "")
       :gsub("^please%s+", "")

  -- the dictionary itself
  if t:match("^what can you do") or t == "help" or t == "show help"
     or t:match("^show%s+.*%f[%a]commands%f[%A]")
     or t:match("^show%s+.*%f[%a]dictionary%f[%A]") then
    helpShow()
    speakAlien("Here is everything I can do. It is on your screen.")
    return true
  end

  -- open / launch / start <app>
  local arg = t:match("^open%s+(.+)$") or t:match("^launch%s+(.+)$")
           or t:match("^start%s+(.+)$")
  if arg then
    local app = resolveApp(arg)
    if hs.application.launchOrFocus(app) then
      actionSay("Opening " .. app .. ".", "🚀")
    else
      actionSay("I could not find an app called " .. app .. ".")
    end
    return true
  end

  -- close/quit <app> or "close this window"
  local force = t:match("^force%s+quit%s+(.+)$")
  arg = force or t:match("^close%s+(.+)$") or t:match("^quit%s+(.+)$")
  if arg then
    if arg:match("^th[ei]s?%s+window$") or arg == "window"
       or arg == "the window" then
      local w = hs.window.focusedWindow()
      if w then w:close(); actionSay("Window closed.", "🪟") end
      return true
    end
    local app = hs.application.find(resolveApp(arg))
    if app then
      if force then app:kill9() else app:kill() end
      actionSay("Closing " .. app:name() .. ".", "🛑")
    else
      actionSay("I do not see " .. resolveApp(arg) .. " running.")
    end
    return true
  end

  -- switch to / focus / go to <app>
  arg = t:match("^switch%s+to%s+(.+)$") or t:match("^focus%s+(.+)$")
     or t:match("^go%s+to%s+(.+)$") or t:match("^show%s+me%s+(.+)$")
  if arg then
    local app = resolveApp(arg)
    if hs.application.launchOrFocus(app) then
      actionSay("Switching to " .. app .. ".", "🔀")
    else
      actionSay("I could not find " .. app .. ".")
    end
    return true
  end

  -- hide <app>
  arg = t:match("^hide%s+(.+)$")
  if arg then
    local app = hs.application.find(resolveApp(arg))
    if app then app:hide(); actionSay("Hidden.", "🫥")
    else actionSay("I do not see " .. resolveApp(arg) .. " running.") end
    return true
  end

  -- window controls
  if t:match("^minimi[sz]e") then
    local w = hs.window.focusedWindow()
    if w then w:minimize(); actionSay("Minimized.", "🪟") end
    return true
  end
  if t:match("^full%s*screen") or t:match("^toggle%s+full%s*screen") then
    local w = hs.window.focusedWindow()
    if w then w:setFullScreen(not w:isFullScreen()); actionSay("Done.", "🪟") end
    return true
  end

  -- system bits
  if t:match("^voom") or t:match("^start%s+voom") or t:match("^record%s+screen")
     or t:match("^start%s+recording%s+screen") or t:match("^start%s+screen%s+recording")
     or t == "voom" or t == "record screen" then
    actionSay("Starting Voom...", "🎥")
    hs.timer.doAfter(0.5, function() startScreenRecording() end)
    return true
  end
  if t:match("^stop%s+voom") or t:match("^stop%s+recording")
     or t:match("^stop%s+screen%s+recording") or t:match("^end%s+screen%s+recording")
     or t == "stop voom" or t == "stop recording" then
    actionSay("Stopping Voom...", "🛑")
    stopScreenRecording()
    return true
  end
  if t:match("^take%s+a%s+screenshot") or t == "screenshot" then
    hs.eventtap.keyStroke({ "cmd", "shift" }, "3", 0)
    actionSay("Screenshot taken.", "📸")
    return true
  end
  if t:match("^lock%s+the%s+screen$") or t == "lock screen" then
    actionSay("Locking.", "🔒")
    timers.lockDelay = hs.timer.doAfter(1.2, hs.caffeinate.lockScreen)
    return true
  end
  if t:match("^volume%s+up$") or t:match("^turn%s+it%s+up$") then
    local d = hs.audiodevice.defaultOutputDevice()
    if d then d:setOutputVolume(math.min(100, (d:outputVolume() or 50) + 12)) end
    actionSay("Louder.", "🔊")
    return true
  end
  if t:match("^volume%s+down$") or t:match("^turn%s+it%s+down$") then
    local d = hs.audiodevice.defaultOutputDevice()
    if d then d:setOutputVolume(math.max(0, (d:outputVolume() or 50) - 12)) end
    actionSay("Quieter.", "🔉")
    return true
  end
  if t == "mute" or t == "mute the sound" then
    local d = hs.audiodevice.defaultOutputDevice()
    if d then d:setOutputMuted(true) end
    hs.alert.show("🔇 muted", 1.5)
    return true
  end
  if t == "unmute" or t == "unmute the sound" then
    local d = hs.audiodevice.defaultOutputDevice()
    if d then d:setOutputMuted(false) end
    actionSay("Sound is back.", "🔊")
    return true
  end

  -- generic keystroke: "press command shift f" / "hit enter"
  local keys = t:match("^press%s+(.+)$") or t:match("^hit%s+(.+)$")
  if keys then
    local mods, key = {}, nil
    for w in keys:gmatch("[%w]+") do
      if SPOKEN_MODS[w] then
        mods[#mods + 1] = SPOKEN_MODS[w]
      else
        key = SPOKEN_KEYS[w] or w
      end
    end
    if key and (#key == 1 or SPOKEN_KEYS[key] or key:match("^f%d+$")
                or key == "return" or key == "escape" or key == "tab"
                or key == "space" or key == "delete" or key == "up"
                or key == "down" or key == "left" or key == "right") then
      hs.eventtap.keyStroke(mods, key, 0)
      actionSay("Done.", "⌨️")
      return true
    end
  end

  return false
end

-- Whisper mangles two-word commands ("Close Safari" -> "Quo's Safari").
-- When a SHORT utterance matches no verb, ask the fast local model to map
-- it onto the whitelist — it may only answer with an exact command or NO,
-- so the action layer stays deterministic: the LLM can pick from the menu,
-- never invent. Falls through to Q&A on NO/timeout.
local function normalizeAction(text, cb)
  -- app candidates = the usual suspects + what's ACTUALLY running right now,
  -- so "switch to bear" maps correctly the day you install Bear
  local appNames = { "Safari", "Google Chrome", "Terminal", "Slack",
                     "Finder", "Spotify", "Messages", "Notes", "Mail",
                     "Calculator", "System Settings", "Cursor" }
  local seen = {}
  for _, n in ipairs(appNames) do seen[n] = true end
  for _, a in ipairs(hs.application.runningApplications()) do
    local n = a:name()
    if n and #n > 2 and not seen[n] and a:kind() == 1
       and #appNames < 24 then
      seen[n] = true
      appNames[#appNames + 1] = n
    end
  end
  local prompt = table.concat({
    "A voice command was mis-transcribed. Map it to ONE of these exact",
    "command patterns, or reply NO if it is not clearly one of them:",
    "open <app> / close <app> / force quit <app> / switch to <app> /",
    "hide <app> / close this window / minimize / fullscreen /",
    "volume up / volume down / mute / unmute / take a screenshot /",
    "lock the screen / what can you do",
    "Likely app names: " .. table.concat(appNames, ", ") .. ".",
    "Pick the verb that SOUNDS most like the transcript's first word(s):",
    "'clothes', 'quos', 'cloze', 'closed' sound like CLOSE — not open.",
    "Most transcripts are NOT commands — when in doubt, reply NO.",
    "Examples:",
    "\"clothes safari\" -> close Safari",
    "\"oaken chrome\" -> open Google Chrome",
    "\"what's the weather\" -> NO",
    "\"who is doctor smith\" -> NO",
    "\"crucified\" -> NO",
    "Transcript: \"" .. text .. "\"",
    "Reply with ONLY the corrected command, or NO. Nothing else.",
  }, "\n")
  local done = false
  timers.normTimeout = hs.timer.doAfter(6, function()
    if not done then done = true; cb(nil) end
  end)
  hs.http.asyncPost(C.ollamaUrl, hs.json.encode({
    model = pickModel("answer", false), stream = false, prompt = prompt,
    keep_alive = "24h", options = { temperature = 0 },
  }), { ["Content-Type"] = "application/json" }, function(status, body)
    if done then return end
    done = true
    if timers.normTimeout then timers.normTimeout:stop() end
    local cmd
    if status == 200 then
      local ok, d = pcall(hs.json.decode, body)
      if ok and d and d.response then
        cmd = d.response:gsub("[\"'%.]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if cmd:upper() == "NO" or #cmd == 0 or #cmd > 40 then cmd = nil end
      end
    end
    cb(cmd)
  end)
end

-- Deterministic gates on the normalizer's proposal — the LLM can pick from
-- the menu, but code checks its work:
-- (1) the command must share phonetic material with what was actually said
local function soundsPlausible(orig, cmd)
  local o = " " .. orig:lower():gsub("[^%w%s]", "") .. " "
  local oflat = o:gsub("%s", "")
  local hasSig, hit = false, false
  for w in cmd:lower():gmatch("%a+") do
    if #w >= 4 and not (w == "open" or w == "close" or w == "quit"
        or w == "switch" or w == "hide" or w == "force" or w == "this"
        or w == "google") then
      hasSig = true
      if o:find(w, 1, true) or oflat:find(w:sub(1, 3), 1, true) then
        hit = true
      end
    end
  end
  if hasSig then return hit end
  local verb = cmd:lower():match("%a+") or ""
  return oflat:find(verb:sub(1, 3), 1, true) ~= nil
end

-- (2) close/quit/hide/switch may only target a known alias or a RUNNING app
-- ("who is dr kornreich" must never become close Dr Kornreich)
local function appTargetOK(cmd)
  local lc = cmd:lower()
  local arg = lc:match("^force quit%s+(.+)$") or lc:match("^close%s+(.+)$")
           or lc:match("^quit%s+(.+)$") or lc:match("^switch%s+to%s+(.+)$")
           or lc:match("^hide%s+(.+)$")
  if not arg then return true end          -- open/argless: handled gracefully
  if arg:match("window") then return true end
  if APP_ALIASES[arg] then return true end
  return hs.application.find(resolveApp(arg)) ~= nil
end

-- action if it parses; short garbled utterances get one normalizer pass;
-- everything else becomes a question. onAction/onQuestion are callbacks.
local function routeUtterance(text, onAction, onQuestion)
  if performAction(text) then onAction() return end
  local words = select(2, text:gsub("%S+", ""))
  if words <= 5 then
    normalizeAction(text, function(cmd)
      if cmd and soundsPlausible(text, cmd) and appTargetOK(cmd)
         and performAction(cmd) then
        log("action normalized: '" .. text .. "' -> '" .. cmd .. "'")
        onAction()
      else
        onQuestion()
      end
    end)
    return
  end
  onQuestion()
end

-- shared "action finished, back to idle" cleanup
local function actionDone()
  play("done")
  state, locked, pendingTap = "idle", false, false
  duckUp()
  vignHide()
  if menubar then menubar:setIcon(icons.idle, true) end
  hudEmote("excite")
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

-- spoken commands: deterministic, pattern-matched voice control
local function applyVoiceCommands(text)
  if not C.voiceCommands then return text, nil end
  local bare = text:lower():gsub("^[%p%s]+", ""):gsub("[%p%s]+$", ""):gsub("%s+", " ")
  log("Voice command parsed: bare='" .. bare .. "' (raw='" .. text .. "')")

  -- Undo the last dictation. Matched as a SET of phrasings rather than one
  -- blessed wording, because nobody remembers which one the software wanted —
  -- "delete last" was the obvious way to say it and was the one thing missing.
  local UNDO_PHRASES = {
    ["scratch that"] = true, ["scratch"] = true, ["scratch last"] = true,
    ["undo that"] = true,    ["undo"] = true,    ["undo last"] = true,
    ["delete that"] = true,  ["delete last"] = true,
    ["delete the last"] = true, ["delete last one"] = true,
    ["delete the last one"] = true, ["delete last sentence"] = true,
    ["delete the last sentence"] = true, ["delete last line"] = true,
    ["remove that"] = true,  ["remove last"] = true,
    ["nevermind"] = true,    ["never mind"] = true,
    ["forget that"] = true,  ["cancel that"] = true,
  }
  if UNDO_PHRASES[bare] then
    return "", "undo"
  end

  -- Navigation: Back / Forward / Refresh
  if bare:find("^go back") or bare:find("^backwards?") or bare:find("^page back") or bare == "back" then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "[", 0) end, label = "Back" }
  end
  if bare:find("^go forward") or bare:find("^forwards?") or bare:find("^page forward") or bare == "forward" then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "]", 0) end, label = "Forward" }
  end
  if bare:find("refresh") or bare:find("reload") then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "r", 0) end, label = "Reload" }
  end

  -- Window & Tab Closing
  if bare:find("close window") or bare == "close this window" or bare == "shut window" then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "w", 0) end, label = "Close window" }
  end
  if bare:find("close tab") or bare == "close this tab" or bare == "shut tab" or bare == "close" then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "w", 0) end, label = "Close tab" }
  end
  if bare:find("new tab") or bare:find("open tab") then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "t", 0) end, label = "New tab" }
  end
  if bare:find("quit app") or bare:find("close app") or bare:find("shut down app") or bare == "quit" then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "q", 0) end, label = "Quit app" }
  end

  -- Camera Controls
  if bare:find("camera on") or bare:find("show camera") or bare:find("turn camera on") or bare == "camera on" then
    return "", { fn = function() showWebcamOverlay() end, label = "Camera Overlay ON" }
  end
  if bare:find("camera off") or bare:find("hide camera") or bare:find("turn camera off") or bare == "camera off" then
    return "", { fn = function() hideWebcamOverlay() end, label = "Camera Overlay OFF" }
  end
  if bare:find("toggle camera") or bare == "camera" then
    return "", { fn = function() toggleWebcamOverlay() end, label = "Toggle Camera" }
  end

  -- Fullscreen & Expand
  if bare:find("expand") or bare:find("full screen") or bare:find("fullscreen") or bare:find("maximize") then
    return "", { fn = function()
      local win = hs.window.focusedWindow()
      if win then win:toggleFullScreen() end
    end, label = "Toggle Fullscreen" }
  end
  if bare:find("minimize") then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "m", 0) end, label = "Minimize" }
  end

  -- Scrolling
  if bare:find("scroll down") or bare:find("page down") or bare == "down" then
    return "", { fn = function() hs.eventtap.keyStroke({}, "pagedown", 0) end, label = "Scroll down" }
  end
  if bare:find("scroll up") or bare:find("page up") or bare == "up" then
    return "", { fn = function() hs.eventtap.keyStroke({}, "pageup", 0) end, label = "Scroll up" }
  end
  if bare:find("top of page") or bare:find("go to top") then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "up", 0) end, label = "Top of page" }
  end
  if bare:find("bottom of page") or bare:find("go to bottom") then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "down", 0) end, label = "Bottom of page" }
  end

  -- Editing
  if bare:find("select all") then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "a", 0) end, label = "Select all" }
  end
  if bare:find("copy that") or bare == "copy" then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "c", 0) end, label = "Copy" }
  end
  if bare:find("save file") or bare:find("save document") or bare == "save" then
    return "", { fn = function() hs.eventtap.keyStroke({ "cmd" }, "s", 0) end, label = "Save" }
  end

  -- App Openers
  local appName = bare:match("^open%s+(.+)")
  if appName then
    return "", { fn = function() hs.application.launchOrFocus(appName) end, label = "Open " .. appName }
  end

  text = text:gsub("%s*[Nn]ew [Pp]aragraph[%.,:]%s*", "\n\n")
  text = text:gsub("%s*[Nn]ew [Pp]aragraph%s*$", "\n\n")
  text = text:gsub("%s*[Nn]ew [Ll]ine[%.,:]%s*", "\n")
  text = text:gsub("%s*[Nn]ew [Ll]ine%s*$", "\n")
  return text, nil
end

-- GLOBALS by design (same reason as startRecording/stopRecording): reset()
-- and insertText sit EARLIER in this file and participate in the conv loop
-- (re-arm, send-trigger submit). As locals declared here, those upstream
-- references compiled to always-nil globals and the loop silently died
-- after every utterance. Globals resolve at call time from anywhere.
convMode = false
activeSendTrigger = nil
convToggleTs = 0
convLastTail = nil        -- previous chunk's text tail: whisper decode context
convHealStrikes = 0       -- consecutive stall-heals: drives restart backoff
convChunkStart = 44       -- byte offset where the NEXT chunk begins in C.wav
-- VAD silence threshold, calibrated per toggle. A fixed 0.2% assumed a
-- near-silent mic; this room's floor measures ~0.6% RMS on the RODECaster,
-- so "below 0.2%" never happened and the auto-stop never fired. We sample
-- the floor for 0.6s at toggle-ON and set the threshold above it.
convVadPct = nil
function convCalibrate(done)
  local floorWav = tmp("convfloor.wav")
  M.convCalTask = hs.task.new("/bin/sh", function(_, out)
    local rms = tonumber((out or ""):match("RMS%s+amplitude:%s+([%d%.]+)"))
    if rms then
      -- 2.5x the noise floor, clamped to a sane band (4x treated quiet
      -- speech as silence on the low-gain RODECaster — chopped mid-word)
      convVadPct = math.max(0.4, math.min(6, rms * 2.5 * 100))
      log(string.format("conv VAD calibrated: floor RMS %.2f%% -> threshold %.2f%%",
        rms * 100, convVadPct))
    else
      convVadPct = 1.0
      log("conv VAD calibration failed — using 1.0% default")
    end
    os.remove(floorWav)
    if done then done() end
  end, { "-c", string.format(
    "%s -q -d -c 1 -r 16000 -b 16 %s trim 0 0.6 2>/dev/null; %s %s -n stat 2>&1",
    C.sox, floorWav, C.sox, floorWav) })
  M.convCalTask:start()
end

function parseSendTrigger(tStr)  -- global: see note above convMode
  if not tStr or #tStr == 0 then return tStr, nil end
  local clean = tStr:gsub("[%s%.!%?%-%_,;]+$", "")
  local lower = clean:lower()
  -- Deliberate phrases ONLY. "out"/"over"/"go"/"enter" were pruned after
  -- "...how that's gonna be playing OUT" auto-submitted mid-thought —
  -- common sentence-enders must never be submit commands.
  local triggers = { "ok send", "okay send", "oksend", "okaysend", "ok go", "okay go", "ok, go", "okay, go", "okgo", "okaygo", "send it", "send", "submit", "roger" }
  for _, trig in ipairs(triggers) do
    if lower == trig then
      return "", trig
    end
    local tail = " " .. trig
    if lower:sub(-#tail) == tail then
      local prefix = clean:sub(1, #clean - #trig):gsub("[%s%,;%-%_]+$", "")
      -- "Okay send" should submit WITHOUT pasting the "Okay": when all
      -- that precedes the trigger is verbal filler, erase it entirely
      local bare = prefix:lower():gsub("%p", ""):gsub("^%s+", ""):gsub("%s+$", "")
      if bare == "" or bare == "ok" or bare == "okay" or bare == "alright"
         or bare == "all right" or bare == "yeah" or bare == "yep"
         or bare == "um" or bare == "uh" or bare == "so" or bare == "and" then
        return "", trig
      end
      return prefix, trig
    end
  end
  return tStr, nil
end

-- Re-arm the conv mic and ding ONLY once audio bytes are verifiably
-- flowing — a stillborn recorder (common on this device) used to eat the
-- user's first sentences right after a ding that promised "I'm listening".
function armThenDing(msg)
  if not (convMode and state == "idle") then return end
  locked = true
  startRecording()
  local tries = 0
  local function check()
    timers.armDing = nil
    if not convMode then return end
    local a = hs.fs.attributes(C.wav)
    if a and a.size > 44 then
      local g = hs.sound.getByName("Glass")
      if g then g:volume(1.0):play() else play("done") end
      hs.alert.show(msg, 2.0)
      log("mic verified live — ding")
      return
    end
    tries = tries + 1
    if tries < 10 then
      timers.armDing = hs.timer.doAfter(0.5, check)   -- tick heals meanwhile
    else
      log("mic still not flowing after 5s — dinging anyway (heal continues)")
      local g = hs.sound.getByName("Glass")
      if g then g:volume(1.0):play() else play("done") end
      hs.alert.show(msg, 2.0)
    end
  end
  timers.armDing = hs.timer.doAfter(0.6, check)
end

function watchLLMCompletion(win)  -- global: see note above convMode
  if not convMode then return end
  local wid = win and win:id()
  if not wid then return end
  local ocrBin = HOME .. "/vox/ocr-bin"
  if not hs.fs.attributes(ocrBin) then return end

  if timers.convWatch then timers.convWatch:stop(); timers.convWatch = nil end
  local lastLen, stableCount, maxChecks, watchDone = -1, 0, 40, false

  timers.convWatch = hs.timer.doEvery(0.6, function()
    maxChecks = maxChecks - 1
    if not convMode or maxChecks <= 0 then
      if timers.convWatch then timers.convWatch:stop(); timers.convWatch = nil end
      if convMode and state == "idle" then
        log("LLM watch timeout — bell (mic never left)")
        alienQuip("timeout")
        timers.dingDelay = hs.timer.doAfter(C.alienPlayByPlay and 2.0 or 0.05, function()
          timers.dingDelay = nil
          dingNow("🔔 Still listening.")
          if convMode and state == "idle" then
            armThenDing("🔔 Listening...")
          end
        end)
      end
      return
    end
    local tmpPng, tmpTxt = tmp("conv.png"), tmp("conv.txt")
    M.convTask = hs.task.new("/bin/sh", function(code, out, err)
      local cf = io.open(tmpTxt, "r")
      if cf then
        local txt = cf:read("*a") or ""
        cf:close()
        os.remove(tmpTxt)
        local curLen = #txt:gsub("%s", "")
        if curLen > 30 and curLen == lastLen then
          stableCount = stableCount + 1
          if stableCount >= 2 and not watchDone then
            watchDone = true          -- in-flight OCR callbacks double-fire
            if timers.convWatch then timers.convWatch:stop(); timers.convWatch = nil end
            log("LLM response completed — bell (mic never left)")
            alienQuip("ready")
            timers.dingDelay = hs.timer.doAfter(C.alienPlayByPlay and 2.0 or 0.05, function()
          timers.dingDelay = nil
              dingNow("🔔 Reply's in — mic is live.")
              if convMode and state == "idle" then   -- edge: mic somehow off
                armThenDing("🔔 Listening...")
              end
            end)
          end
        else
          stableCount = 0
          lastLen = curLen
        end
      end
    end, { "-c", string.format("/usr/sbin/screencapture -x -l %d %s 2>/dev/null && %s %s > %s 2>/dev/null; rm -f %s", wid, tmpPng, ocrBin, tmpPng, tmpTxt, tmpPng) })
    M.convTask:start()
  end)
end

local function handleTranscript(raw, t0)
  -- transcription made it — the processing watchdog must not fire mid-LLM
  if timers.procWatch then timers.procWatch:stop(); timers.procWatch = nil end
  local text = raw:gsub("%[BLANK_AUDIO%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if isPromptEcho(text, fullVocabulary(), true) then
    log("dictation: PROMPT ECHO discarded (" .. text:sub(1, 40) .. ")")
    reset()
    return
  end
  text = text:gsub("%s*\n%s*", " ")            -- server returns wrapped lines
  text = applyCorrections(text)
  text = cleanFillers(text)
  text = collapseRepeats(text)

  local cleanedText, trig = parseSendTrigger(text)
  if trig then
    text = cleanedText
    activeSendTrigger = trig
    log("vocal send trigger detected ('" .. trig .. "') — auto-submitting prompt")
  end
  local cmdResult
  text, cmdResult = applyVoiceCommands(text)
  if cmdResult == "undo" then
    hs.timer.doAfter(0.08, function()
      hs.eventtap.keyStroke({ "cmd" }, "z", 0)   -- undo the last paste
    end)
    play("done")
    hs.alert.show("↩︎ scratched", 1)
    reset()
    return
  elseif type(cmdResult) == "table" and cmdResult.fn then
    play("done")
    hs.alert.show("⚡ " .. cmdResult.label, 1)
    speakAlien(cmdResult.label)
    hs.timer.doAfter(0.08, function()
      cmdResult.fn()                             -- execute after 80ms keyup delay
    end)
    reset()
    return
  end
  learnFrom(text)                              -- vocabulary compounds over time
  log(string.format("whisper done in %.1fs: %s",
      hs.timer.secondsSinceEpoch() - t0, text:sub(1, 80)))
  if #text == 0 then reset() return end
  if CORES <= 2 and ollamaIsLocal() and not C.forceLocalLLM
     and (recMode == "expand" or recMode == "ask"
          or C.llmCleanup or C.translateTo ~= "off") then
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
      speakAlien("Fact remembered.")
      hs.alert.show("🧠 got it — remembered", 2)
      hudEmote("excite")
      state, locked, pendingTap = "idle", false, false
      duckUp()
      vignHide()
      if menubar then menubar:setIcon(icons.idle, true) end
      return
    end
    if #rest > 3 then
      routeUtterance(rest,
        function() context.app = "Hey Vox"; actionDone() end,
        function() streamAsk(rest) end)
      return
    end
  end
  if recMode == "ask" then
    -- ⌘ + ask-key combo: the whole utterance is a question — no "Hey Vox"
    -- prefix needed; the alien answers on screen AND out loud
    recMode = "dictate"
    if #text > 3 then
      routeUtterance(text,
        function() context.app = "Hey Vox"; actionDone() end,
        function() streamAsk(text) end)
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

-- ---------------- conversation-mode chunk pipeline ------------
-- Side-band transcription for the gapless loop: operates on a STASHED
-- chunk file while the live recorder keeps rolling on C.wav. Touches no
-- recording state, no timers, no reset() — a failed chunk just logs and
-- dies; the loop never notices. Global (see note above convMode).
-- Extract the finished chunk from the CONTINUOUSLY-RUNNING recording by
-- byte range — the recorder is NEVER restarted per chunk. Restarting per
-- sentence rolled the stall dice on this flaky device every few seconds
-- (observed: a stall every 10-20s, each eating the user's words). Now the
-- dice roll once per session; the stream just rolls on.
convLastActivity = 0
function convExtract()
  convLastActivity = hs.timer.secondsSinceEpoch()
  local a = hs.fs.attributes(C.wav)
  local size = a and a.size or 0
  local len = size - convChunkStart
  if len < 12000 then convChunkStart = size return end   -- <0.4s: nothing real
  local from = convChunkStart
  convChunkStart = size
  local chunk = tmp("conv-chunk-" .. tostring(size) .. ".wav")
  M.extractTask = hs.task.new("/bin/sh", function(code)
    if code == 0 then
      if C.convLive then
        convFinalPending = true     -- hold partials until this final lands
        convTranscribeLive(chunk)
      else convTranscribe(chunk) end
    else os.remove(chunk) end
  end, { "-c", string.format(
    "/usr/bin/tail -c +%d %s | /usr/bin/head -c %d | " ..
    "%s -t raw -r 16000 -e signed -b 16 -c 1 - %s",
    from + 1, C.wav, len, C.sox, chunk) })
  M.extractTask:start()
end

-- Park the conv mic entirely (no chunk kept). Used the moment a send
-- trigger fires: while the LLM answers, the watcher hammers screenshots
-- and the ding plays through the SAME flaky device — capture during that
-- window just stall-spirals (observed: 8 heals in 27s post-send). The
-- watcher's completion/timeout re-arm brings the mic back after the ding.
function convPause()
  if not (convMode and state == "recording") then return end
  recGen = recGen + 1
  if timers.convTick then timers.convTick:stop(); timers.convTick = nil end
  local pid = recTask and recTask:isRunning() and recTask:pid() or nil
  if recTask and recTask:isRunning() then recTask:interrupt() end
  if pid then
    timers["kill" .. pid] = hs.timer.doAfter(0.5, function()
      timers["kill" .. pid] = nil
      os.execute("/bin/kill -9 " .. pid .. " 2>/dev/null")
    end)
  end
  os.remove(C.wav)
  state = "idle"
  log("conv mic parked while LLM answers — ding re-arms it")
  -- the park is otherwise invisible and reads as "it died" — say it
  hs.alert.show("⏸ Sent — mic off while the reply writes.\nDing = talk again.", 4)
  alienQuip("sent")
end

-- Cut the current conv recording into a chunk and restart the mic.
-- Bumps recGen FIRST so the dying recorder's exit callback is inert, gives
-- sox a beat to finalize the WAV after SIGINT (with a guaranteed kill
-- behind it), then stashes the file, re-arms, and transcribes in parallel.
-- discard=true throws the audio away (silent recycle / deaf heal).
function convHandoff(discard)
  if not (convMode and state == "recording") then return end
  recGen = recGen + 1
  if timers.convTick then timers.convTick:stop(); timers.convTick = nil end
  local pid = recTask and recTask:isRunning() and recTask:pid() or nil
  if recTask and recTask:isRunning() then recTask:interrupt() end
  if pid then
    timers["kill" .. pid] = hs.timer.doAfter(0.6, function()
      timers["kill" .. pid] = nil
      os.execute("/bin/kill -9 " .. pid .. " 2>/dev/null")
    end)
  end
  local beat = 0.15 + math.min((convHealStrikes or 0) * 0.5, 3)
  timers.convHandoff = hs.timer.doAfter(beat, function()
    timers.convHandoff = nil
    if not convMode then                 -- toggled off mid-handoff
      os.remove(C.wav)
      return
    end
    local chunk = tmp("conv-chunk-" .. tostring(recGen) .. ".wav")
    os.remove(chunk)
    os.rename(C.wav, chunk)
    state = "idle"
    locked = true
    startRecording()
    if discard then os.remove(chunk) else convTranscribe(chunk) end
  end)
end

function convTranscribe(chunk)
  local norm = chunk .. "-n.wav"
  -- carry the previous chunk's tail as decode context: whisper continues
  -- "...the one conversation, which" far more accurately than starting cold
  local promptStr = (fullVocabulary() .. " "
    .. (convLastTail or "")):gsub('[\\"$`]', "")
  local cmd = string.format(
    "%s %s %s highpass 80 norm -3 silence 1 0.1 0.6%% reverse" ..
    " silence 1 0.30 0.6%% reverse pad 0 0.15 2>/dev/null || cp %s %s; " ..
    "SIZE=$(/usr/bin/stat -f%%z %s 2>/dev/null || echo 0); " ..
    "[ \"$SIZE\" -lt 8000 ] && exit 42; " ..
    "/usr/bin/curl -s --max-time 30 -F file=@%s -F temperature=0.0 " ..
    "-F prompt=\"%s\" -F response_format=text http://%s:%d/inference",
    C.sox, chunk, norm, chunk, norm, norm, norm,
    promptStr, C.whisperHost, C.serverPort)
  M.convSttTask = hs.task.new("/bin/sh", function(code, out)
    if code == 42 then
      os.remove(chunk); os.remove(norm)
      log("conv chunk: silence, skipped")
      return
    end
    if code ~= 0 or not out or #out:gsub("%s", "") == 0
       or out:find('"error"') then
      -- BRAIN RESILIENCE: the serial path retries and falls back; chunks
      -- must too, or a cold/dead whisper-server silently eats every chunk
      -- ("only works when I toggle off"). Wake the server, retry once.
      if not convRetried[chunk] then
        convRetried[chunk] = true
        log("conv chunk transcribe failed — waking engine, retry in 3s")
        ensureServer()
        timers.convRetry = hs.timer.doAfter(3, function()
          timers.convRetry = nil
          convTranscribe(chunk)
        end)
        return
      end
      convRetried[chunk] = nil
      os.remove(chunk); os.remove(norm)
      log("conv chunk LOST after retry (code " .. tostring(code) .. ")")
      hs.alert.show("⚠️ Vox: transcription engine down — chunk lost", 3)
      return
    end
    convRetried[chunk] = nil
    os.remove(chunk); os.remove(norm)
    local text = out:gsub("%[BLANK_AUDIO%]", ""):gsub("%s*\n%s*", " ")
                    :gsub("^%s+", ""):gsub("%s+$", "")
    -- drop non-speech annotations: whisper renders dings/music the mic
    -- overhears as "(bell dings)" / "[Music]" / "..." — never paste those
    if #text == 0 or text:match("^[%(%[].*[%)%]]%.?$")
       or text:match("^[%.%s…]+$") then
      log("conv chunk: non-speech (" .. text:sub(1, 30) .. "), skipped")
      return
    end
    if isPromptEcho(text, promptStr, true) then
      log("conv chunk: PROMPT ECHO discarded (" .. text:sub(1, 40) .. ")")
      return
    end
    text = applyCorrections(text)
    text = cleanFillers(text)
    text = collapseRepeats(text)
    local cleaned, trig = parseSendTrigger(text)
    if #cleaned > 0 then convLastTail = cleaned:sub(-160) end
    log("conv chunk: " .. (trig and ("[" .. trig .. "] ") or "") .. cleaned:sub(1, 60))
    if #cleaned > 0 then insertText(cleaned) end
    if trig then
      timers.convSubmit = hs.timer.doAfter(#cleaned > 0 and 0.25 or 0.05, function()
        timers.convSubmit = nil
        local retCode = hs.keycodes.map["return"] or 36
        local rDown = hs.eventtap.event.newKeyEvent(retCode, true)
        rDown:setFlags({}); rDown:post()
        local rUp = hs.eventtap.event.newKeyEvent(retCode, false)
        rUp:setFlags({}); rUp:post()
        log("conv: auto-submitted via '" .. trig .. "' — watching for LLM")
        watchLLMCompletion(hs.window.focusedWindow())
        alienQuip("sent")          -- mic stays LIVE; quip rides the mute window
        hs.alert.show("📨 Sent — still listening. Bell = reply landed.", 3)
      end)
    end
  end, { "-c", cmd })
  M.convSttTask:start()
end

-- ---------------- live word-by-word typing (experimental) -----
-- Types partial hypotheses as you speak and REVISES them with backspaces
-- as whisper refines — iPhone-dictation feel over the continuous stream.
-- Only the last ~90 chars are revisable (commit horizon); earlier text is
-- frozen so the line stabilizes left-to-right behind the voice.
convTypedBuf = ""
convLedger = ""          -- everything typed on screen since the last send
convPartialBusy = false
convPartialTs = 0

-- DEEP SWEEP: on send, re-clean the WHOLE paragraph (past the 90-char
-- revision horizon): ellipsis litter, no-space boundary echoes
-- ("paragraph?paragraph?"), fillers, spacing — then revise the screen
-- with one unlimited-depth diff before the Return fires.
-- revise on-screen text from `t` to `c` with one unlimited-depth diff
function screenRevise(t, c)
  if t == c then return end
  local maxi = math.min(#t, #c)
  local lcp = 0
  while lcp < maxi and t:sub(lcp + 1, lcp + 1) == c:sub(lcp + 1, lcp + 1) do
    lcp = lcp + 1
  end
  while lcp > 0 do
    local byt = t:byte(lcp + 1)
    if byt and byt >= 0x80 and byt < 0xC0 then lcp = lcp - 1 else break end
  end
  local eraseChars = (lcp < #t) and (utf8.len(t, lcp + 1) or (#t - lcp)) or 0
  for _ = 1, eraseChars do hs.eventtap.keyStroke({}, "delete", 0) end
  local toType = c:sub(lcp + 1)
  if #toType > 0 then hs.eventtap.keyStrokes(toType) end
end

-- Deep sweep, two passes: (1) instant regex hygiene, (2) a fast local-LLM
-- SEMANTIC pass — "deep-sea sweep" becomes "deep sweep" because the model
-- reads context ("just think about it" — Adam). The Return fires via cb()
-- once, whether the LLM answers, fails, or times out at 5s.
function convSweep(cb)
  cb = cb or function() end
  local t = convLedger .. convTypedBuf
  if #t == 0 then cb() return end
  local c = t
  c = c:gsub("%s*%.%.%.+%s*", " ")
  c = c:gsub("%s*…+%s*", " ")
  c = c:gsub("(%a[%w']*%p)%1", "%1")        -- "word?word?" boundary echo
  c = cleanFillers(c)
  c = c:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if c ~= t then
    screenRevise(t, c)
    log(string.format("deep sweep: regex pass revised %d -> %d chars", #t, #c))
  end
  convLedger, convTypedBuf = c, ""
  if not ollamaIsLocal() or #c < 20 or #c > 1500 then cb() return end
  local done = false
  local function finish()
    if not done then done = true; cb() end
  end
  timers.sweepTimeout = hs.timer.doAfter(5, finish)
  hs.http.asyncPost(C.ollamaUrl, hs.json.encode({
    model = C.models.fast, stream = false,
    options = { temperature = 0, num_predict = 500 },
    prompt = "Fix ONLY obvious speech-to-text transcription errors in the dictation below: "
      .. "mistranscribed words that don't fit the context, duplicated false starts, stray artifacts. "
      .. "Keep the speaker's exact wording, tone, slang and profanity. Never rephrase, summarize, "
      .. "censor, or add words. Reply with ONLY the corrected text and nothing else.\n\nDICTATION:\n" .. c,
  }), { ["Content-Type"] = "application/json" }, function(status, body)
    if timers.sweepTimeout then timers.sweepTimeout:stop(); timers.sweepTimeout = nil end
    if not done and status == 200 then
      local ok, j = pcall(hs.json.decode, body)
      local fixed = ok and j and j.response or nil
      if fixed then
        fixed = fixed:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        local cur = convLedger
        -- content guards: models sometimes REWRITE instead of correct.
        -- (a) any CJK/Hangul/Cyrillic script = hallucination, reject.
        -- (b) >=75% of the speaker's words must survive, or reject.
        local foreign = fixed:find("[\208-\214\228-\237]") ~= nil
        local keep, total = 0, 0
        if not foreign then
          local fixedSet = {}
          for w in fixed:lower():gmatch("[%w']+") do fixedSet[w] = true end
          for w in cur:lower():gmatch("[%w']+") do
            total = total + 1
            if fixedSet[w] then keep = keep + 1 end
          end
        end
        if not foreign and total > 0 and (keep / total) >= 0.75
           and #fixed > 0 and fixed ~= cur
           and #fixed > math.floor(#cur * 0.5)
           and #fixed < math.floor(#cur * 1.6) then
          screenRevise(cur, fixed)
          convLedger = fixed
          log("deep sweep: semantic pass applied")
        elseif fixed ~= cur then
          log(string.format(
            "deep sweep: semantic pass REJECTED (foreign=%s overlap=%.0f%%)",
            tostring(foreign), total > 0 and keep / total * 100 or 0))
        end
      end
    end
    finish()
  end)
end

function liveSync(hyp, final)
  if hyp == nil then return end
  hyp = hyp:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #hyp == 0 and not final then return end
  local typed = convTypedBuf
  local commitLen = math.max(0, #typed - 90)
  if commitLen > 0 and hyp:sub(1, commitLen) ~= typed:sub(1, commitLen) then
    -- hypothesis rewrote text beyond the horizon: extend-only, never churn
    if #hyp <= #typed then return end
    local toType = hyp:sub(#typed + 1)
    hs.eventtap.keyStrokes(toType)
    convTypedBuf = typed .. toType
    return
  end
  local maxi = math.min(#typed, #hyp)
  local lcp = commitLen
  while lcp < maxi and typed:sub(lcp + 1, lcp + 1) == hyp:sub(lcp + 1, lcp + 1) do
    lcp = lcp + 1
  end
  -- never split a UTF-8 sequence: retreat to a char boundary
  while lcp > commitLen do
    local byt = typed:byte(lcp + 1)
    if byt and byt >= 0x80 and byt < 0xC0 then lcp = lcp - 1 else break end
  end
  local toType = hyp:sub(lcp + 1)
  local eraseChars = (lcp < #typed) and (utf8.len(typed, lcp + 1) or (#typed - lcp)) or 0
  for _ = 1, eraseChars do hs.eventtap.keyStroke({}, "delete", 0) end
  if #toType > 0 then hs.eventtap.keyStrokes(toType) end
  convTypedBuf = typed:sub(1, lcp) .. toType
end

convFinalPending = false
function convPartial()
  if convPartialBusy or convFinalPending then return end
  local a = hs.fs.attributes(C.wav)
  local size = a and a.size or 0
  local len = size - convChunkStart
  if len < 8000 or len > 640000 then return end   -- 0.25s .. 20s window
  convPartialBusy = true
  convPartialTs = hs.timer.secondsSinceEpoch()
  local pw = tmp("conv-partial.wav")
  local prompt = ((convLastTail or "") .. " "):gsub('[\\"$`]', "")
  M.partialTask = hs.task.new("/bin/sh", function(code, out)
    convPartialBusy = false
    os.remove(pw)
    if code ~= 0 or not out then ensureServer() return end
    if not (convMode and C.convLive and state == "recording") then return end
    local text = out:gsub("%[BLANK_AUDIO%]", ""):gsub("%s*\n%s*", " ")
                    :gsub("^%s+", ""):gsub("%s+$", "")
    if text:match("^[%(%[].*[%)%]]%.?$") or text:match("^[%.%s…]+$") then return end
    if isPromptEcho(text, convLastTail) then return end  -- tail echo
    -- whisper renders thinking-breaths as "..." — never type them
    text = text:gsub("%s*%.%.%.+", ""):gsub("%s*…+", ""):gsub("%s+", " ")
    liveSync(text, false)
  end, { "-c", string.format(
    "/usr/bin/tail -c +%d %s | /usr/bin/head -c %d | " ..
    "%s -t raw -r 16000 -e signed -b 16 -c 1 - %s && " ..
    "/usr/bin/curl -s --max-time 6 -F file=@%s -F temperature=0.0 " ..
    "-F language=en -F prompt=\"%s\" -F response_format=text http://%s:%d/inference",
    convChunkStart + 1, C.wav, len, C.sox, pw, pw, prompt,
    C.whisperHost, C.serverPort) })
  M.partialTask:start()
end

function convTranscribeLive(chunk)
  local prompt = (fullVocabulary() .. " " .. (convLastTail or "")):gsub('[\\"$`]', "")
  M.convSttTask = hs.task.new("/bin/sh", function(code, out)
    if code ~= 0 or not out or #out:gsub("%s", "") == 0 or out:find('"error"') then
      if not convRetried[chunk] then
        convRetried[chunk] = true
        log("live final transcribe failed — waking engine, retry in 3s")
        ensureServer()
        timers.convRetry = hs.timer.doAfter(3, function()
          timers.convRetry = nil
          convTranscribeLive(chunk)
        end)
        return
      end
      convRetried[chunk] = nil
      os.remove(chunk)
      convFinalPending = false
      convLedger = convLedger .. convTypedBuf   -- stands as typed
      convTypedBuf = ""
      hs.alert.show("⚠️ Vox: engine down — text kept as typed, not swept", 3)
      return
    end
    convRetried[chunk] = nil
    os.remove(chunk)
    convFinalPending = false        -- partials may flow again
    local text = out:gsub("%[BLANK_AUDIO%]", ""):gsub("%s*\n%s*", " ")
                    :gsub("^%s+", ""):gsub("%s+$", "")
    if text:match("^[%(%[].*[%)%]]%.?$") or text:match("^[%.%s…]+$") then
      liveSync("", true)            -- junk: erase the revisable tail
      convLedger = convLedger .. convTypedBuf
      convTypedBuf = ""
      return
    end
    if isPromptEcho(text, prompt, true) then
      log("live final: PROMPT ECHO discarded (" .. text:sub(1, 40) .. ")")
      convLedger = convLedger .. convTypedBuf
      convTypedBuf = ""
      return
    end
    text = applyCorrections(text)
    text = text:gsub("%s*%.%.%.+", ""):gsub("%s*…+", ""):gsub("%s+", " ")
    local cleaned, trig = parseSendTrigger(text)
    liveSync(cleaned, true)
    if #cleaned > 0 then
      convLastTail = cleaned:sub(-160)
      hs.eventtap.keyStrokes(" ")
      convLedger = convLedger .. convTypedBuf .. " "
    else
      convLedger = convLedger .. convTypedBuf
    end
    convTypedBuf = ""
    log("live chunk final: " .. (trig and ("[" .. trig .. "] ") or "") .. cleaned:sub(1, 60))
    if trig then
      timers.convSubmit = hs.timer.doAfter(0.15, function()
        timers.convSubmit = nil
        convFinalPending = true     -- no partial typing during sweep/submit
        convSweep(function()        -- regex + semantic passes, then submit
          local retCode = hs.keycodes.map["return"] or 36
          local rD = hs.eventtap.event.newKeyEvent(retCode, true); rD:setFlags({}); rD:post()
          local rU = hs.eventtap.event.newKeyEvent(retCode, false); rU:setFlags({}); rU:post()
          convLedger = ""           -- sent: fresh paragraph
          convFinalPending = false  -- partials may flow again
          log("live: auto-submitted via '" .. trig .. "'")
          watchLLMCompletion(hs.window.focusedWindow())
          alienQuip("sent")         -- mic stays LIVE; quip rides the mute window
          hs.alert.show("📨 Sent — still listening. Bell = reply landed.", 3)
        end)
      end)
    end
  end, { "-c", string.format(
    "/usr/bin/curl -s --max-time 20 -F file=@%s -F temperature=0.0 " ..
    "-F language=en -F prompt=\"%s\" -F response_format=text http://%s:%d/inference",
    chunk, prompt, C.whisperHost, C.serverPort) })
  M.convSttTask:start()
end

-- slow path: only used if the server is down (also restarts it)
-- screen-OCR cache: rapid consecutive dictations into the SAME window reuse
-- the words instead of re-screenshotting + re-OCRing every time (Gemini's
-- idea; hoisted here so it actually persists across recordings, and it
-- stores the text — ctx.txt is single-use, so a bare skip would silently
-- drop screen context on the follow-up dictation)
local ocrCache = { wid = nil, ts = 0, txt = nil }

-- first-touch latency killer: after idle macOS pages the whisper model out
-- of RAM and the first dictation pays the reload tax. A tiny silent
-- inference fired the moment a deliberate hold starts forces the page-in
-- WHILE the user is still talking — by key-release the server is hot.
local lastWhisperTouch = 0
local function warmPing()
  if C.whisperHost ~= "127.0.0.1" then return end
  local now = hs.timer.secondsSinceEpoch()
  if (now - lastWhisperTouch) < 120 then return end
  lastWhisperTouch = now
  local warmWav = tmp("warm.wav")
  M.warmPingTask = hs.task.new("/bin/sh", nil, { "-c", string.format(
    "[ -f %s ] || %s -n -r 16000 -c 1 -b 16 %s trim 0.0 0.3 2>/dev/null; " ..
    "/usr/bin/curl -s --max-time 90 -F file=@%s -F temperature=0.0 " ..
    "-F response_format=text http://127.0.0.1:%d/inference >/dev/null 2>&1",
    warmWav, C.sox, warmWav, warmWav, C.serverPort) })
  M.warmPingTask:start()
end

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
  lastWhisperTouch = t0              -- any request keeps the model hot
  -- timeout scales with recording length AND machine speed: a 2-core Intel
  -- gets ~4x realtime headroom, Apple Silicon barely needs 1x. Base is short
  -- on ARM — a warm server answers in ~1s, and a slow first answer gets one
  -- RETRY below instead of a 20s stare
  local durSecs  = math.max(1, (attr.size - 44) / 32000)
  local factor   = IS_ARM and 1.5 or (CORES <= 2 and 6 or 3)
  local maxTime  = math.ceil((IS_ARM and 10 or 20) + durSecs * factor)

  -- vocabulary for THIS dictation: saved words + what's visible on screen
  local promptStr = fullVocabulary()
  -- bias short command utterances: "Close Safari" once arrived as
  -- "Quo's Safari" (and once as "Crucified"!) — seed the verbs + app names
  promptStr = promptStr
    .. " Close Safari. Open Chrome. Quit Slack. Switch to Terminal."
    .. " Minimize. Fullscreen. Mute. Take a screenshot. Lock the screen."
  local cf = io.open(tmp("ctx.txt"), "r")
  if cf then
    local ctxText = cf:read("*a") or ""
    cf:close()
    os.remove(tmp("ctx.txt"))                -- privacy: single use
    ocrCache.txt = ctxText                   -- reusable within the 15s window
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
  local function buildCmdPort(port, timeLimit)
    return string.format(
      "%s %s %s highpass 80 norm -3 reverse silence 1 0.25 0.4%% reverse pad 0.10 0.25 2>/dev/null || cp %s %s; " ..
      "SIZE=$(/usr/bin/stat -f%%z %s 2>/dev/null || echo 0); " ..
      "[ \"$SIZE\" -lt 1200 ] && exit 42; " ..
      "/usr/bin/curl -s --max-time %d -F file=@%s -F temperature=0.0 -F best_of=1 -F no_fallback=true " ..
      "-F prompt=\"%s\" -F response_format=text%s http://%s:%d/inference",
      C.sox, C.wav, C.wavNorm, C.wav, C.wavNorm,
      C.wavNorm,
      timeLimit, C.wavNorm,
      promptStr, langArg, C.whisperHost, port)
  end

  local myGen = recGen
  local specDraftState = nil
  local specKeyTap = nil
  local pass1Done, pass2Done = false, false

  local function stopSpecWatcher()
    if specKeyTap then pcall(function() specKeyTap:stop() end); specKeyTap = nil end
  end

  if C.speculativeDraft and fastServerRunning() then
    M.fastSttTask = hs.task.new("/bin/sh", function(code, out)
      if pass2Done then return end
      if code == 0 and out and #out:gsub("%s", "") > 0 and not out:find('"error"') then
        pass1Done = true
        local draftText = out:gsub("%[BLANK_AUDIO%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        draftText = draftText:gsub("%s*\n%s*", " ")
        draftText = applyCorrections(draftText)
        draftText = cleanFillers(draftText)
        draftText = collapseRepeats(draftText)
        local cleanedText = parseSendTrigger(draftText)
        draftText = applyVoiceCommands(cleanedText)
        if #draftText > 0 and state == "processing" and not pass2Done then
          log("speculative engine: FAST DRAFT landed (" .. draftText:sub(1, 40) .. ")")
          specDraftState = { text = draftText, app = context.app, time = hs.timer.secondsSinceEpoch(), userTyped = false }
          insertText(draftText)
          stopSpecWatcher()
          specKeyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function()
            if specDraftState then specDraftState.userTyped = true end
            stopSpecWatcher()
            return false
          end)
          specKeyTap:start()
        end
      end
    end, { "-c", buildCmdPort(C.serverPortFast, 4) })
    M.fastSttTask:start()
  end

  local function run(attempt)
    M.sttTask = hs.task.new("/bin/sh", function(code, out, err)
      pass2Done = true
      stopSpecWatcher()
      if code == 42 then
        log("accidental tap — no speech in recording, discarded quietly")
        reset()
        return
      end
      local ok = (code == 0) and out and #out:gsub("%s", "") > 0
                 and not out:find('"error"')
      if ok then
        noteTranscribeSuccess(hs.timer.secondsSinceEpoch() - t0)
        local finalText = out:gsub("%[BLANK_AUDIO%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        finalText = finalText:gsub("%s*\n%s*", " ")
        finalText = applyCorrections(finalText)
        finalText = cleanFillers(finalText)
        finalText = collapseRepeats(finalText)
        local cleanedFinal, trig = parseSendTrigger(finalText)
        if trig then activeSendTrigger = trig; finalText = cleanedFinal end
        local cmdRes
        finalText, cmdRes = applyVoiceCommands(finalText)
        if type(cmdRes) == "table" or cmdRes == "undo" then
          handleTranscript(out, t0)
          return
        end
        if specDraftState and not specDraftState.userTyped
           and context.app == specDraftState.app
           and (hs.timer.secondsSinceEpoch() - specDraftState.time) < 4.0 then
          if finalText ~= specDraftState.text and #finalText > 0 then
            log(string.format("speculative engine: REVISING draft '%s' -> '%s'", specDraftState.text, finalText))
            screenRevise(specDraftState.text, finalText)
            rememberPaste(finalText)
            play("done")
          else
            log("speculative engine: PERFECT MATCH! Fast draft was 100% accurate.")
          end
          learnFrom(finalText)
          reset()
        else
          handleTranscript(out, t0)
        end
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
      elseif attempt == 1 and serverRunning() then
        -- server alive but slow (model paging back into RAM after idle):
        -- ONE retry with a longer window beats cold-loading the whole model
        -- a second time via whisper-cli
        log("server slow (model paging in?) — one retry with longer window")
        run(2)
      else
        log("server unavailable — falling back to whisper-cli and restarting server")
        ensureServer()
        transcribeCLI(t0)
      end
    end, { "-c", buildCmdPort(C.serverPort, maxTime * attempt) })
    M.sttTask:start()
  end
  run(1)
  -- hard ceiling: "thinking" may never hang the state machine. Kill the
  -- pipeline, free the hotkey, tell the user, move on
  timers.procWatch = hs.timer.doAfter(maxTime * 3 + 10, function()
    timers.procWatch = nil
    if state == "processing" and myGen == recGen then
      if M.sttTask and M.sttTask:isRunning() then M.sttTask:terminate() end
      hs.alert.show("Vox: transcription timed out — try again", 2)
      ensureServer()
      reset()
    end
  end)
end

-- ---------------- recording ----------------------------------
function startRecording()  -- global by design: see note at top state vars
  if state ~= "idle" then return end
  state = "recording"
  recGen = recGen + 1
  local myGen = recGen
  captureContext()
  os.remove(C.wav)
  -- ZOMBIE REAPER: exactly ONE recorder may exist. Un-anchored kill timers
  -- were GC'd before firing (the classic Hammerspoon gotcha this file's
  -- footer warns about) and wedged sox processes stacked up overnight —
  -- five of them once interleaved garbage into the same wav. Sweep clean
  -- before every spawn.
  os.execute("/usr/bin/pkill -9 -f 'sox.*" .. C.wav .. "' 2>/dev/null")
  -- PLAIN capture always — including conversation mode. sox's silence
  -- effect on a live coreaudio stream proved rotten on this rig: it wedged
  -- pre-arm, wedged post-arm, ignored TERM, and its deafness was
  -- indistinguishable from a quiet user. Normal hold-to-talk (plain
  -- capture) has been rock solid all along, so conv mode now records the
  -- exact same way and the pause detection lives in Lua (convTick below),
  -- where every decision is observable and loggable.
  local soxArgs = { "--buffer", "1024", "-q", "-d", "-c", "1", "-r", "16000", "-b", "16", C.wav }

  recTask = hs.task.new(C.sox, function(code, _, _)
    if convMode and state == "recording" and myGen == recGen then
      -- conv chunks end via convHandoff() (which bumps recGen first), so a
      -- gen-matching exit here means the recorder DIED on its own — restart
      log("conv recorder died unexpectedly (code " .. tostring(code) .. ") — restarting")
      state = "idle"
      locked = true
      timers.convRestart = hs.timer.doAfter(0.2, function()
        timers.convRestart = nil
        if convMode and state == "idle" then startRecording() end
      end)
    elseif state == "processing" and myGen == recGen then
      transcribe()
    end
  end, soxArgs)
  recTask:start()
  -- CONV TICK: Lua-side pause detection over the plain capture. Every
  -- 0.4s, peak-analyze the last 0.45s of audio (raw tail pipe — no wav
  -- header games on a growing file). Speech = peak over the calibrated
  -- threshold. 3 quiet ticks (~1.2s) after speech = chunk boundary ->
  -- convHandoff. Plain capture writes bytes CONSTANTLY (silence included),
  -- so a recorder that stops growing for ~3s is deterministically DEAF —
  -- no probabilistic room-probing needed. Silent 20s files recycle
  -- (discard) so chunks never carry long dead lead-ins; 90s of nonstop
  -- sound (music/monologue) force-cuts with transcription.
  if convMode then
    convChunkStart = 44          -- fresh stream file: chunk offset resets
    if (convLastActivity or 0) == 0 then convLastActivity = hs.timer.secondsSinceEpoch() end
    if timers.convTick then timers.convTick:stop() end
    local hadSpeech, silentTicks, lastSize, stallTicks, busy =
      false, 0, 0, 0, false
    local myTickGen = recGen
    timers.convTick = hs.timer.doEvery(0.4, function()
      if not (convMode and state == "recording" and myTickGen == recGen) then
        if timers.convTick then timers.convTick:stop(); timers.convTick = nil end
        return
      end
      -- overnight hygiene: 30 min without a single chunk = nobody's here.
      if (hs.timer.secondsSinceEpoch() - (convLastActivity or 0)) > 1800 then
        log("conv mode idle 30min — auto-off")
        convMode = false
        if timers.convTick then timers.convTick:stop(); timers.convTick = nil end
        recGen = recGen + 1
        if recTask and recTask:isRunning() then recTask:terminate() end
        os.execute("/usr/bin/pkill -9 -f 'sox.*" .. C.wav .. "' 2>/dev/null")
        state = "idle"
        duckUp()
        setUI("idle")
        hs.alert.show("👽 Conversation mode auto-off (30 min idle)", 3)
        return
      end
      local a = hs.fs.attributes(C.wav)
      local size = a and a.size or 0
      if size == lastSize then stallTicks = stallTicks + 1 else stallTicks = 0 end
      lastSize = size
      -- even pure silence writes bytes every ~32ms, so 1.6s without a
      -- single byte = the stream has stalled (this RODECaster stalls
      -- OFTEN — observed twice a minute). Cold device opens get 4s grace.
      if stallTicks == 0 and size > 44 then convHealStrikes = 0 end
      local stallLimit = (size <= 44) and 6 or 4
      if stallTicks >= stallLimit then
        convHealStrikes = (convHealStrikes or 0) + 1
        log("conv recorder DEAF (stream stalled) — healing (strike "
            .. convHealStrikes .. ")")
        convHandoff(true)
        return
      end
      if size < 14500 or busy then return end
      busy = true
      M.tickTask = hs.task.new("/bin/sh", function(_, out)
        busy = false
        if not (convMode and state == "recording" and myTickGen == recGen) then return end
        local peak = tonumber((out or ""):match("Maximum%s+amplitude:%s+([%d%.]+)")) or 0
        local thr = (convVadPct or 0.5) / 100
        if hs.timer.secondsSinceEpoch() < (convMuteUntil or 0) then
          peak = 0                    -- our own bell/quip audio: not speech
        elseif convMutePurge then
          convMutePurge = false
          if not hadSpeech then convChunkStart = size end  -- drop playback bytes
        end
        if peak >= thr then
          hadSpeech = true
          silentTicks = 0
        elseif hadSpeech then
          silentTicks = silentTicks + 1
          -- 2 ticks (~0.8s) — snappier phrase turnaround; the continuous
          -- stream + decode-context carry keep accuracy through short cuts
          if silentTicks >= 2 then
            log(string.format("pause detected (peak %.2f%% < %.2f%%) — extracting chunk",
              peak * 100, thr * 100))
            convExtract()                       -- stream keeps rolling
            hadSpeech, silentTicks = false, 0
            return
          end
        end
        if C.convLive and hadSpeech then
          if (hs.timer.secondsSinceEpoch() - convPartialTs) > 1.1 then
            convPartial()
          end
        end
        local chunkSecs = (size - convChunkStart) / 32000
        if not hadSpeech and chunkSecs > 20 then
          convChunkStart = size                 -- drop dead air, zero cost
        elseif chunkSecs > 90 then
          log("90s continuous sound — force-extracting chunk")
          convExtract()
          hadSpeech, silentTicks = false, 0
        end
        -- session file cap: ~10 min of continuous stream -> one quiet
        -- restart at a silent moment (the only restart left in the loop)
        if size > 19000000 and not hadSpeech then
          log("stream file at ~10min — recycling recorder at a quiet moment")
          convHandoff(true)
        end
      end, { "-c", string.format(
        "/usr/bin/tail -c 14400 %s | %s -t raw -r 16000 -e signed -b 16 -c 1 - -n stat 2>&1",
        C.wav, C.sox) })
      M.tickTask:start()
    end)
  end
  -- screen-aware dictation: OCR the target window WHILE recording (free time)
  local function startCtxOCR()
    if not (C.screenContext and CORES > 2) then return end
    local win = hs.window.focusedWindow()
    local wid = win and win:id()
    local now = hs.timer.secondsSinceEpoch()
    if wid and ocrCache.wid == wid and (now - ocrCache.ts) < 15
       and ocrCache.txt then
      -- replay the cached words so transcribe() finds them as usual
      local cf = io.open(tmp("ctx.txt"), "w")
      if cf then cf:write(ocrCache.txt); cf:close() end
      log("reusing cached screen OCR words for window " .. tostring(wid))
      return
    end
    if wid then
      ocrCache.wid, ocrCache.ts, ocrCache.txt = wid, now, nil
      local ocrBin = HOME .. "/vox/ocr-bin"
      local ctxPng, ctxTxt = tmp("ctx.png"), tmp("ctx.txt")
      M.ctxTask = hs.task.new("/bin/sh", nil, { "-c", string.format(
        "[ -x %s ] && /usr/sbin/screencapture -x -l %d %s" ..
        " 2>/dev/null && %s %s > %s 2>/dev/null;" ..
        " rm -f %s", ocrBin, wid, ctxPng, ocrBin, ctxPng, ctxTxt, ctxPng) })
      M.ctxTask:start()
    end
  end
  -- Command-key hold: ⌘ is also every shortcut chord's modifier, so a quick
  -- ⌘C must not beep, flash the vignette, or screenshot-OCR the window.
  -- The mic starts NOW (first words are never lost); sound + UI + OCR fire
  -- only once the press outlives a tap. Quick taps get discarded before
  -- that, so shortcuts stay silent and cheap.
  if C.holdKeycode == 54 or C.holdKeycode == 55 then
    local function fanfare()
      timers.uiDelay = nil
      if state ~= "recording" then return end
      if pendingTap then       -- tap verdict still pending: look again soon
        timers.uiDelay = hs.timer.doAfter(0.15, fanfare)
        return
      end
      -- hold is deliberate: NOW hush a talking alien (never at raw ⌘-press —
      -- with ⌘ as hold key, every shortcut chord would cut his voice off)
      warmPing()                 -- model pages in while the user talks
      hushAlien()
      duckDown()
      setUI(locked and "lock" or "rec")
      play("start")
      startCtxOCR()
      if recMode == "ask" then
        hs.alert.show("👽 ask mode — Vox will answer out loud", 1.2)
      end
    end
    timers.uiDelay = hs.timer.doAfter(C.tapLockMax + 0.03, fanfare)
  else
    -- dedicated hold key (no shortcut ambiguity): hush + fanfare right away
    warmPing()                   -- model pages in while the user talks
    hushAlien()
    duckDown()
    setUI(convMode and "lock" or "rec")
    if not convMode then
      -- conv re-arms are SILENT and skip per-chunk screen OCR: the mic
      -- would hear the beep, and a screenshot every sentence is churn
      play("start")
      startCtxOCR()
    end
    if recMode == "ask" then
      hs.alert.show("👽 ask mode — Vox will answer out loud", 1.2)
    end
  end
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
  local stuckMisses = 0
  timers.stuckKey = hs.timer.doEvery(1.0, function()
    if state == "recording" and not locked and not pendingTap then
      local mods = hs.eventtap.checkKeyboardModifiers()
      local held = ((C.holdKeycode == 61 or C.holdKeycode == 58) and mods.alt)
                or ((C.holdKeycode == 54 or C.holdKeycode == 55) and mods.cmd)
      if not held and (hs.timer.secondsSinceEpoch() - keyDownAt) > 1.2 then
        -- some apps (secure input, Electron quirks) make the modifier
        -- read flake for a beat — ONE miss must never kill a live
        -- dictation mid-sentence. Three consecutive misses = real.
        stuckMisses = stuckMisses + 1
        if stuckMisses >= 3 then
          log("missed key-release x3 (" .. context.app .. ") — stopping recording")
          stopRecording()
        end
      else
        stuckMisses = 0
      end
    end
  end)
  log("recording started (" .. context.app .. ")")
end

local function cancelRecording()
  if state ~= "recording" then return end
  state = "idle"
  recGen = recGen + 1            -- invalidates the recorder's exit callback
  if timers.convVAD then timers.convVAD:stop(); timers.convVAD = nil end
  if recTask and recTask:isRunning() then
    local pid = recTask:pid()
    recTask:terminate()
    -- wedged sox (unarmed VAD gate) ignores TERM — make death certain
    if pid then
      timers["kill" .. pid] = hs.timer.doAfter(0.5, function()
        timers["kill" .. pid] = nil
        os.execute("/bin/kill -9 " .. pid .. " 2>/dev/null")
      end)
    end
  end
  reset()
end

function stopRecording()  -- global by design: see note at top state vars
  if state ~= "recording" then return end
  state = "processing"
  if timers.maxRec then timers.maxRec:stop() end
  if timers.stuckKey then timers.stuckKey:stop() end
  if timers.convVAD then timers.convVAD:stop(); timers.convVAD = nil end
  if timers.convCap then timers.convCap:stop(); timers.convCap = nil end
  if timers.convDeaf then timers.convDeaf:stop(); timers.convDeaf = nil end
  if timers.convTick then timers.convTick:stop(); timers.convTick = nil end
  setUI("work")
  duckUp()                       -- music fades back while we transcribe
  play("stop")
  -- tail grace: people release the key WHILE saying the last word — keep
  -- the mic open a beat longer so its final syllables actually get recorded
  timers.tailGrace = hs.timer.doAfter(C.tailGrace, function()
    if recTask and recTask:isRunning() then
      recTask:interrupt()        -- SIGINT lets sox finalize the WAV
      -- conv-mode wedge: sox stuck in a coreaudio read with an un-armed VAD
      -- gate ignores SIGINT (and even SIGTERM — observed live). Escalate
      -- until it actually dies; its exit callback still fires on a kill and
      -- runs transcribe() as usual, so the pipeline continues either way.
      timers.soxKill = hs.timer.doAfter(0.7, function()
        timers.soxKill = nil
        if recTask and recTask:isRunning() then
          local pid = recTask:pid()
          recTask:terminate()
          timers.soxKill9 = hs.timer.doAfter(0.5, function()
            timers.soxKill9 = nil
            if pid and recTask and recTask:isRunning() then
              log("sox ignored TERM — SIGKILL " .. pid)
              os.execute("/bin/kill -9 " .. pid .. " 2>/dev/null")
            end
          end)
        end
      end)
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
-- is THIS key's own modifier flag down? (flags can't tell left from right,
-- but the event's keycode + the flag family together can)
local function keyFlagDown(fl, kc)
  if kc == 56 or kc == 60 then return fl.shift end
  if kc == 58 or kc == 61 then return fl.alt end
  if kc == 54 or kc == 55 then return fl.cmd end
  return false
end

local flagTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  local kc = e:getKeyCode()
  -- ask combo: ask-key pressed while a recording is running -> question mode.
  -- Silent unless the hold is already deliberate — ⌘⇧3/⌘⇧4-style shortcut
  -- chords pass through without an "ask mode" flash (their recording gets
  -- discarded as a quick tap anyway, which also resets the mode).
  if kc == C.askKeycode and kc ~= C.holdKeycode then
    if state == "recording" and keyFlagDown(e:getFlags(), kc)
       and recMode ~= "ask" then
      recMode = "ask"
      if locked or (hs.timer.secondsSinceEpoch() - keyDownAt) > C.tapLockMax then
        hs.alert.show("👽 ask mode — Vox will answer out loud", 1.2)
      end
    end
    return false
  end
  local flags = e:getFlags()
  -- Fn+Option TOGGLE — fires only when BOTH modifiers are actually down
  -- (a key PRESS). The old `or kc == 61/58` clause also matched the Option
  -- RELEASE while Fn was still held, which instantly toggled the mode back
  -- OFF — that's why conversation mode felt like it had to be held down.
  if flags.fn and flags.alt then
    local now = hs.timer.secondsSinceEpoch()
    if (now - convToggleTs) > 0.6 then
      convToggleTs = now
      convMode = not convMode
      convLedger, convTypedBuf = "", ""
      convLastActivity = hs.timer.secondsSinceEpoch()
      if convMode then
        play("start")
        hs.alert.show("👽 Hands-Free Conversation Mode ON\nSay 'ok go' or 'send' to submit (Fn+Option to stop)", 2.5)
        duckDown(true)             -- pause media ONCE for the whole session
        ensureServer()             -- wake the BRAIN too, not just the mic
        -- Option-first chord order starts a plain hold-to-talk recording a
        -- few ms before the toggle lands. CANCEL it properly (recGen bump
        -- invalidates its exit callback) — a bare terminate() left state
        -- 'recording', which SKIPPED calibration and armed the session on
        -- a wrong default threshold. convMode flips off around the cancel
        -- so reset()'s conv re-arm can't race the calibrated arm below.
        if state == "recording" then
          convMode = false
          cancelRecording()
          convMode = true
        end
        if state == "idle" then
          -- measure the room's noise floor first so the VAD threshold is
          -- real for THIS mic and room, then arm
          convCalibrate(function()
            if convMode and state == "idle" then
              locked = true
              startRecording()
            end
          end)
        end
      else
        play("done")
        hs.alert.show("Conversation Mode OFF", 1.5)
        if timers.convWatch then timers.convWatch:stop(); timers.convWatch = nil end
        if timers.convRearm then timers.convRearm:stop(); timers.convRearm = nil end
        if state == "recording" then stopRecording() end
        duckUp()                 -- convMode is false now: media resumes
      end
    end
    return true
  end

  if convMode then
    -- In Conversation Mode, normal Option key taps do not interrupt the loop
    return false
  end

  if kc ~= C.holdKeycode then return false end
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
      -- (soft-start's deferred fanfare sees the lock and fires in full)
      setUI("lock")
    elseif state == "idle" then
      keyDownAt = hs.timer.secondsSinceEpoch()
      local flags = e:getFlags()
      local isOptHold = (C.holdKeycode == 61 or C.holdKeycode == 58)
      local isCmdHold = (C.holdKeycode == 54 or C.holdKeycode == 55)
      local hasShift  = flags.shift == true
      local hasAlt    = (not isOptHold) and flags.alt == true
      local hasCmd    = (not isCmdHold) and flags.cmd == true

      -- shift + hold key = ask · extra modifier (cmd/alt) = expand
      recMode = hasShift and "ask"
             or ((hasAlt or hasCmd) and "expand")
             or "dictate"
      startRecording()
    end
  else -- released
    if state == "recording" and not locked then
      if (hs.timer.secondsSinceEpoch() - keyDownAt) >= C.tapLockMax then
        -- PHANTOM-RELEASE DEBOUNCE: some apps synthesize flagsChanged
        -- events while the key is still physically down — Vox would cut
        -- off mid-sentence (never in Terminal, often elsewhere). Verify
        -- the modifier is genuinely up before stopping; if it's still
        -- held, ignore the ghost. A real missed release is caught by the
        -- stuck-key watchdog within ~3s.
        timers.relCheck = hs.timer.doAfter(0.12, function()
          timers.relCheck = nil
          if state ~= "recording" or locked then return end
          local mods = hs.eventtap.checkKeyboardModifiers()
          local stillHeld = ((C.holdKeycode == 61 or C.holdKeycode == 58) and mods.alt)
                         or ((C.holdKeycode == 54 or C.holdKeycode == 55) and mods.cmd)
          if stillHeld then
            log("phantom key-release ignored (" .. context.app .. ")")
            return
          end
          stopRecording()        -- normal push-to-talk release
        end)
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
         and calib.bestLatency >= 0.3
         and secs > math.max(3.2, calib.bestLatency * 2) and not M.refreshing then
        if M.refreshedAt
           and hs.timer.secondsSinceEpoch() - M.refreshedAt < 600 then
          -- we JUST refreshed and a brand-new server still tests this slow:
          -- that's the machine's real current speed (memory pressure, cold
          -- cache), not engine decay. Adopt it as the baseline instead of
          -- thrashing kill/reload every 30s — the loop that burned CPU on
          -- 8GB Macs whose healthy latency sits above the 3.2s floor.
          calib.bestLatency = math.floor(secs * 10) / 10
          saveCalib()
          log(string.format(
            "engine still %.1fs after refresh — adopting as baseline", secs))
        else
          M.refreshedAt = hs.timer.secondsSinceEpoch()
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
    -- a commit that failed to boot (see bootguard.lua) stays quarantined
    -- until upstream moves past it — never pull a known-broken deploy twice
    "if [ -f .vox-bad-commit ] && " ..
    "[ \"$(/usr/bin/git rev-parse origin/main)\" = \"$(cat .vox-bad-commit)\" ]; " ..
    "then echo current; " ..
    "elif [ \"$(/usr/bin/git rev-list --count HEAD..origin/main)\" = 0 ]; " ..
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
if M and M.menubar then pcall(function() M.menubar:delete() end); M.menubar = nil end
if menubar then pcall(function() menubar:delete() end); menubar = nil end
menubar = hs.menubar.new()
menubar:setIcon(icons.idle, true)
menubar:setMenu(function()
  return {
    { title = "Vox — local dictation, by AutomateScale", fn = function()
        hs.urlevent.openURL("https://automatescale.com/vox")
      end },
    { title = "Hold " .. C.holdKeyName .. " to talk · double-tap to lock", disabled = true },
    { title = "Triple-tap: smart reply · Right Option+key: expand to content", disabled = true },
    { title = "\"Hey Vox, …\" ask a question · \"Hey Vox, remember …\" save a fact", disabled = true },
    { title = "Hold key + " .. C.askKeyName .. " = ask mode — Vox answers out loud", disabled = true },
    { title = "Voice actions — dictionary", menu = (function()
        local items = {
          { title = "Show cheat sheet on screen", fn = helpShow },
          { title = "(or say: \"Hey Vox, what can you do?\")", disabled = true },
        }
        for _, sec in ipairs(ACTION_DICT) do
          items[#items + 1] = { title = "-" }
          items[#items + 1] = { title = "— " .. sec[1] .. " —", disabled = true }
          for _, it in ipairs(sec[2]) do
            items[#items + 1] = { title = it[1] .. "  ·  " .. it[2],
                                  disabled = true }
          end
        end
        return items
      end)() },
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
    { title = "-" },
    { title = "🎥 Voom — Screen & Presenter Recording", menu = {
        { title = (screenRec and screenRec.active) and "🛑 Stop Voom Recording (⌥⇧R)" or "▶ Start Voom Recording (⌥⇧R)",
          fn = function() toggleScreenRecording() end },
        { title = "📷 Include Webcam Bubble", checked = C.screenRecWebcam,
          fn = function()
            pref("screenRecWebcam", not C.screenRecWebcam)
            hs.alert.show("Webcam Bubble: " .. (C.screenRecWebcam and "ON" or "OFF"), 1.5)
          end },
        { title = "Webcam Background Mode", menu = {
            { title = "🟢 GPU Chroma Key (Keys out Green Screen)", checked = (C.screenRecBgMode == "chroma" or C.screenRecBgMode == "keygreen"),
              fn = function() pref("screenRecBgMode", "chroma"); hs.alert.show("Webcam: GPU Chroma Key 🟢", 1.5) end },
            { title = "✨ AI Person Cutout (Auto Background Removal)", checked = (C.screenRecBgMode == "cutout" or C.screenRecBgMode == "transparent"),
              fn = function() pref("screenRecBgMode", "cutout"); hs.alert.show("Webcam: AI Person Cutout ✨", 1.5) end },
            { title = "📷 Raw Camera Circle", checked = (C.screenRecBgMode == "off"),
              fn = function() pref("screenRecBgMode", "off"); hs.alert.show("Webcam: Raw Camera 📷", 1.5) end },
          } },
        { title = "📂 Open Recordings Folder",
          fn = function() hs.execute("open '" .. (C.screenRecDir or (HOME .. "/Movies/VoxRecordings")) .. "'") end },
        { title = "🎬 Play Latest Recording",
          disabled = (not screenRec or screenRec.outputPath == "" or not hs.fs.attributes(screenRec.outputPath)),
          fn = function()
            if screenRec and screenRec.outputPath ~= "" and hs.fs.attributes(screenRec.outputPath) then
              hs.execute("open '" .. screenRec.outputPath .. "'")
            end
          end },
      } },
    { title = "While recording", menu = {
        { title = "Duck audio to 15%", checked = C.duckMode == "duck",
          fn = function() pref("duckMode", "duck"); hs.alert.show("Recording: duck audio", 1) end },
        { title = "Mute audio (zero mic bleed)", checked = C.duckMode == "mute",
          fn = function() pref("duckMode", "mute"); hs.alert.show("Recording: mute audio", 1) end },
        { title = "Pause media (podcast/music pauses + resumes)", checked = C.duckMode == "pause",
          fn = function() pref("duckMode", "pause"); hs.alert.show("Recording: pause media", 1) end },
      } },
    { title = "Alien play-by-play (conv mode)", checked = C.alienPlayByPlay,
      fn = function()
        pref("alienPlayByPlay", not C.alienPlayByPlay)
        hs.alert.show("Alien play-by-play: " .. (C.alienPlayByPlay and "ON" or "OFF"), 1.5)
      end },
    { title = "Live word-by-word typing (experimental)", checked = C.convLive,
      fn = function()
        pref("convLive", not C.convLive)
        hs.alert.show("Live word-by-word typing: " .. (C.convLive and "ON" or "OFF"), 1.5)
      end },
    { title = "Hands-Free Conversation Mode (Fn+Option)", checked = convMode,
      fn = function()
        convMode = not convMode
        if convMode then
          play("start")
          hs.alert.show("👽 Hands-Free Conversation Mode ON\nSay 'send' or 'over' when done talking (Fn+Option to stop)", 2.5)
          duckDown(true)           -- pause media ONCE for the whole session
          ensureServer()
          if state == "recording" then  -- stale hold-rec: cancel cleanly
            convMode = false
            cancelRecording()
            convMode = true
          end
          if state == "idle" then
            convCalibrate(function()
              if convMode and state == "idle" then
                locked = true
                startRecording()
              end
            end)
          end
        else
          play("done")
          hs.alert.show("Conversation Mode OFF", 1.5)
          if timers.convWatch then timers.convWatch:stop(); timers.convWatch = nil end
          if timers.convRearm then timers.convRearm:stop(); timers.convRearm = nil end
          if state == "recording" then stopRecording() end
          duckUp()               -- convMode is false now: media resumes
        end
      end },
    { title = "Hold key", menu = {
        { title = "Right Option", checked = C.holdKeycode == 61,
          fn = function() pref("holdKeycode", 61); pref("holdKeyName", "Right Option"); hs.alert.show("Vox key: Right Option", 1) end },
        { title = "Right Command", checked = C.holdKeycode == 54,
          fn = function() pref("holdKeycode", 54); pref("holdKeyName", "Right Command"); hs.alert.show("Vox key: Right Command", 1) end },
        { title = "Left Option", checked = C.holdKeycode == 58,
          fn = function() pref("holdKeycode", 58); pref("holdKeyName", "Left Option"); hs.alert.show("Vox key: Left Option", 1) end },
        { title = "Left Command", checked = C.holdKeycode == 55,
          fn = function() pref("holdKeycode", 55); pref("holdKeyName", "Left Command"); hs.alert.show("Vox key: Left Command", 1) end },
      } },
    { title = "Alien position (pick any combo)", menu = (function()
        local defs = {
          { "window",   "Bottom edge of highlighted window (Default)" },
          { "titlebar", "Docked flush in window titlebar" },
          { "center",   "Bottom center of the screen" },
          { "top",      "Top center of the screen" },
          { "side",     "Right edge, mid-height" },
        }
        local items = {}
        for _, d in ipairs(defs) do
          local k = d[1]
          items[#items + 1] = { title = d[2], checked = C.alienPos[k] == true,
            fn = function()
              C.alienPos[k] = (not C.alienPos[k]) or nil
              hs.settings.set("vox.alienPos", C.alienPos)
              local on = {}
              for _, e in ipairs(defs) do
                if C.alienPos[e[1]] then on[#on + 1] = e[1] end
              end
              hs.alert.show("Alien: " .. (#on > 0
                and table.concat(on, " + ") or "bottom center"), 1.5)
            end }
        end
        return items
      end)() },
    { title = "Tiny idle alien (click him to dictate)", checked = C.miniAlien,
      fn = function()
        C.miniAlien = not C.miniAlien
        if C.miniAlien then miniShow() else miniHide() end
      end },
    { title = "Big pill while recording (instead of just the alien)",
      checked = C.hudStyle ~= "mini",
      fn = function()
        C.hudStyle = (C.hudStyle == "mini") and "pill" or "mini"
        -- Tear down whichever overlay is now wrong so the change is visible
        -- immediately rather than at the next dictation.
        hudHide(); miniHide()
        mini.mode, mini.level = "idle", 0
        if C.miniAlien then miniShow() end
        hs.alert.show(C.hudStyle == "mini"
          and "Vox: state shows on the alien" or "Vox: big pill while recording", 1.5)
      end },
    { title = "Alien voice playback (Kokoro Neural AI)", menu = {
        { title = "Voice output (on/off)", checked = C.alienVoice,
          fn = function()
            C.alienVoice = not C.alienVoice
            hs.alert.show("Alien voice: " .. (C.alienVoice and "on" or "off"), 1)
            if C.alienVoice then speakAlien("Kokoro neural voice online.") end
          end },
        { title = "-" },
        { title = "👽 Vox (our own alien — neural + FX)", checked = C.alienVoiceName == "vox",
          fn = function() pref("alienVoiceName", "vox"); speakAlien("This is my own voice. Pretty voxy, right?") end },
        { title = "❤️ Heart (Warm, Silky Female — Top Neural)", checked = C.alienVoiceName == "af_heart",
          fn = function() pref("alienVoiceName", "af_heart"); speakAlien("Heart voice active.") end },
        { title = "🌹 Bella (Expressive, Smooth Female)", checked = C.alienVoiceName == "af_bella",
          fn = function() pref("alienVoiceName", "af_bella"); speakAlien("Bella voice active.") end },
        { title = "🌊 River (Calm & Atmospheric Female)", checked = C.alienVoiceName == "af_river",
          fn = function() pref("alienVoiceName", "af_river"); speakAlien("River voice active.") end },
        { title = "⚡ Nova (Dynamic, Modern Female)", checked = C.alienVoiceName == "af_nova",
          fn = function() pref("alienVoiceName", "af_nova"); speakAlien("Nova voice active.") end },
        { title = "🕶️ Adam (Deep, Smooth Male)", checked = C.alienVoiceName == "am_adam",
          fn = function() pref("alienVoiceName", "am_adam"); speakAlien("Adam voice active.") end },
        { title = "🐺 Fenrir (Rich, Dark Male)", checked = C.alienVoiceName == "am_fenrir",
          fn = function() pref("alienVoiceName", "am_fenrir"); speakAlien("Fenrir voice active.") end },
      } },
    { title = "Keep dictation in clipboard (⌘V re-paste)", checked = C.keepInClipboard,
      fn = function() pref("keepInClipboard", not C.keepInClipboard) end },
    { title = "Duck music while recording", checked = C.duckAudio,
      fn = function() pref("duckAudio", not C.duckAudio) end },
    { title = "AI cleanup (slower, may reword)", checked = C.llmCleanup,
      fn = function() pref("llmCleanup", not C.llmCleanup) end },
    { title = "Translate output", menu = {
        { title = "Off (fastest)", checked = C.translateTo == "off",
          fn = function() pref("translateTo", "off"); hs.alert.show("Vox translation: off", 1) end },
        { title = "English", checked = C.translateTo == "English",
          fn = function() pref("translateTo", "English"); hs.alert.show("Vox translates to English", 1) end },
        { title = "French", checked = C.translateTo == "French",
          fn = function() pref("translateTo", "French"); hs.alert.show("Vox translates to French", 1) end },
        { title = "Spanish", checked = C.translateTo == "Spanish",
          fn = function() pref("translateTo", "Spanish"); hs.alert.show("Vox translates to Spanish", 1) end },
        { title = "Dutch", checked = C.translateTo == "Dutch",
          fn = function() pref("translateTo", "Dutch"); hs.alert.show("Vox translates to Dutch", 1) end },
      } },
    { title = "Sound theme", menu = {
        { title = "Sleek", checked = C.soundTheme == "sleek",
          fn = function() pref("soundTheme", "sleek"); loadSounds(); play("done") end },
        { title = "Classic", checked = C.soundTheme == "classic",
          fn = function() pref("soundTheme", "classic"); loadSounds(); play("done") end },
      } },
    { title = "Language", menu = {
        { title = "English (fastest)", checked = C.language == "en",
          fn = function() pref("language", "en") end },
        { title = "Français", checked = C.language == "fr",
          fn = function() pref("language", "fr") end },
        { title = "Auto-detect (+1s)", checked = C.language == "auto",
          fn = function() pref("language", "auto") end },
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
      fn = function() pref("memory", not C.memory) end },
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
  hs.http.asyncPost(C.ollamaUrl,                 -- the ask/reply model too
    hs.json.encode({ model = C.models.fast, prompt = "",
                     keep_alive = "24h" }),
    { ["Content-Type"] = "application/json" }, function() end)
end

local function warmUp()
  if C.whisperHost ~= "127.0.0.1" then return end
  lastWhisperTouch = hs.timer.secondsSinceEpoch()  -- warmPing can stand down
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
-- keep the alien's voice warm too (kokoro model in RAM = instant speech).
-- Immediate + one delayed attempt (boot-time spawns have raced before),
-- then a 15-min heartbeat.
ensureSpeechServer()
timers.speechSrvBoot = hs.timer.doAfter(8, ensureSpeechServer)
timers.speechSrvLoop = hs.timer.doEvery(900, ensureSpeechServer)
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

-- Sentinel: respawn-on-exit only covers tasks THIS Lua state spawned. A
-- server adopted across an hs.reload (it was already running, so ensure*
-- never attached a callback) dies unsupervised — this catches that case
-- within a minute. Both checks are a single pgrep when all is well.
timers.srvSentinel = hs.timer.doEvery(60, function()
  if state == "idle" then
    ensureServer()
    ensureSpeechServer()
  end
end)

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

M.screenRecHotkey = hs.hotkey.bind({ "alt", "shift" }, "R", function()
  toggleScreenRecording()
end)

M.startScreenRecording  = startScreenRecording
M.stopScreenRecording   = stopScreenRecording
M.cancelScreenRecording = cancelScreenRecording
M.toggleScreenRecording = toggleScreenRecording
M.screenRec             = screenRec

-- Anchor everything in the module table so Lua GC never collects
-- the eventtap, menubar, canvas, or timers (classic Hammerspoon gotcha).
M.flagTap, M.menubar, M.timers, M.hud, M.sounds = flagTap, menubar, timers, hud, sounds
M.mini, M.vign = mini, vign
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
            end, miniShow = miniShow,
            vignDemo = vignDemo, vignShow = vignShow,
            vignWork = vignWork, vignHide = vignHide,
            streamAsk = streamAsk, speak = speakAlien,
            act = performAction, helpShow = helpShow,
            route = routeUtterance,
            helpInfo = function()
              if not help.canvas then return "no canvas" end
              local f = help.canvas:frame()
              return string.format("showing=%s x=%d y=%d w=%d h=%d",
                tostring(help.canvas:isShowing()), f.x, f.y, f.w, f.h)
            end }

-- ---------------- deploy safety net --------------------------
-- Reaching this line means the whole file parsed and every subsystem above
-- initialized — record this commit as last-known-good so bootguard.lua can
-- roll back to it if a future update fails to load. Clean tree only: a
-- dirty repo means local work, and we never want to reset onto that.
M.lkgTask = hs.task.new("/bin/sh", nil, { "-c",
  "cd \"$HOME/vox\" || exit 0; " ..
  "[ -z \"$(/usr/bin/git status --porcelain)\" ] || exit 0; " ..
  "/usr/bin/git rev-parse HEAD > .vox-lkg" })
M.lkgTask:start()

-- Fleet Macs update by git pull and never re-run install.sh, so vox.lua
-- keeps the two machine-local bootstrap pieces current itself:
-- (1) ~/.hammerspoon/init.lua -> guarded loader. Only the stock
--     require("vox") line is swapped; a customized init.lua is preserved.
local initPath = HOME .. "/.hammerspoon/init.lua"
local initFile = io.open(initPath, "r")
local initSrc = initFile and initFile:read("*a") or ""
if initFile then initFile:close() end
if initSrc:find('require("vox")', 1, true)
   and not initSrc:find("bootguard", 1, true) then
  local patched = initSrc:gsub('require%("vox"%)',
    'require("bootguard")  -- guarded load: rolls back a broken Vox update', 1)
  local w = io.open(initPath, "w")
  if w then
    w:write(patched); w:close()
    log("init.lua upgraded to bootguard loader")
  end
end

-- (2) a launchd watchdog that revives the engine itself: Hammerspoon
--     crashing (or being quit) meant Vox stayed dead until a human noticed.
--     Every 5 min: if the engine isn't running, relaunch it in background;
--     Vox re-arms automatically on load. Removed by uninstall.sh.
local WD_LABEL = "com.vox.watchdog"
local WD_MARK  = "vox-watchdog-v1"
local wdPlist  = HOME .. "/Library/LaunchAgents/" .. WD_LABEL .. ".plist"
local wdFile = io.open(wdPlist, "r")
local wdSrc = wdFile and wdFile:read("*a") or ""
if wdFile then wdFile:close() end
if not wdSrc:find(WD_MARK, 1, true) then
  local w = io.open(wdPlist, "w")
  if w then
    w:write([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.vox.watchdog</string>
  <!-- ]] .. WD_MARK .. [[ — installed and version-managed by vox.lua -->
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>/usr/bin/pgrep -xq Hammerspoon || /usr/bin/open -ga Hammerspoon</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
]])
    w:close()
    M.wdTask = hs.task.new("/bin/sh", nil, { "-c",
      "/bin/launchctl bootout gui/$(id -u)/" .. WD_LABEL .. " 2>/dev/null; " ..
      "/bin/launchctl bootstrap gui/$(id -u) \"" .. wdPlist .. "\"" })
    M.wdTask:start()
    log("engine watchdog installed (" .. WD_MARK .. ")")
  end
end

log("Vox loaded. Hold " .. C.holdKeyName .. " to dictate.")
hs.alert.show("🎤 Vox ready — hold " .. C.holdKeyName .. " to dictate", 2)

return M
