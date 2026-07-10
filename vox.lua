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
local C = {
  sox         = "/opt/homebrew/bin/sox",
  whisper     = "/opt/homebrew/bin/whisper-cli",     -- fallback only
  whisperSrv  = "/opt/homebrew/bin/whisper-server",  -- fast path
  serverPort  = 8090,
  model       = HOME .. "/vox/models/ggml-large-v3-turbo-q5_0.bin",
  wav         = "/tmp/vox-recording.wav",
  wavNorm     = "/tmp/vox-norm.wav",
  language    = "en",                -- "en", "fr", or "auto" (auto costs ~+1s
                                     -- per dictation: extra detection pass)
  threads     = "8",
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
  translateTo = "off",                -- "off", "English", "French", "Spanish", "Dutch"
  ollamaUrl   = "http://localhost:11434/api/generate",
  ollamaModel = "llama3.2:3b",
  llmTimeout  = 10,                  -- secs before falling back to raw text

  holdKeycode = 61,                  -- 61 = Right Option. (Right Cmd = 54)
  holdKeyName = "Right Option",
  tapLockMax  = 0.35,                -- press shorter than this counts as a tap
  doubleTapWindow = 0.45,            -- two taps this close = hands-free lock
  minBytes    = 24000,               -- ignore recordings under ~0.7s

  -- Smart ducking: fade playing audio down (not off) while recording,
  -- ramp it back when done. Cleaner mic signal without killing the vibe.
  duckAudio   = true,
  duckLevel   = 0.35,                -- music drops to 35% of current volume

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
do
  local f = loadfile(HOME .. "/vox/local.lua")
  if f then
    local ok, o = pcall(f)
    if ok and type(o) == "table" then
      for k, v in pairs(o) do C[k] = v end
    end
  end
end
-- ------------------------------------------------------------

local state   = "idle"               -- idle | recording | processing
local locked  = false
local pendingTap = false             -- first tap of a possible double-tap
local keyDownAt = 0
local context = { app = "", title = "" }
local recTask, menubar
local timers  = {}                   -- anchored refs so timers survive GC
local duck                           -- ducking state (defined below)
local reqId   = 0                    -- guards against late LLM responses

local function log(msg) print("[vox] " .. msg) end

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
  s:volume((duck and duck.active)
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

local function duckDown()
  if not C.duckAudio then return end
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev or not dev:outputVolume() then return end
  local vol = dev:outputVolume()
  if vol < 3 then return end                 -- nothing meaningful playing
  if not duck.active then                    -- don't clobber orig mid-restore
    duck.orig, duck.dev, duck.active = vol, dev, true
  end
  rampVolume(duck.orig * C.duckLevel, 5, 0.05)          -- quick fade down
end

local function duckUp()
  if not duck.active then return end
  rampVolume(duck.orig, 8, 0.06, function() duck.active = false end)
end

-- ---------------- HUD: cute alien + bars, bottom center ------
-- A little green alien lives in the pill: bobs, blinks, antenna wiggles.
-- Slides up with a bounce on entry, sinks away on exit.
local HUD_W, HUD_H, BARS = 100, 28, 8   -- alien centered, 4 bars each side
local hud = { canvas = nil, timer = nil, mode = "rec", phase = 0,
              visible = false, anim = nil, animT = 0,
              nextBlink = 30, blinkUntil = 0, baseX = 0, baseY = 0 }

local ALIEN = { red = 0.45, green = 0.97, blue = 0.72, alpha = 1 }   -- mint green
local EYES  = { red = 0.02, green = 0.06, blue = 0.12, alpha = 0.95 }

local function easeOutBack(t)   -- overshoot = the cute bounce
  local c1, c3 = 1.70158, 2.70158
  local u = t - 1
  return 1 + c3 * u * u * u + c1 * u * u
end

local function hudEnsure()
  if hud.canvas then return end
  local c = hs.canvas.new({ x = 0, y = 0, w = HUD_W, h = HUD_H })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c[1] = { type = "rectangle", action = "fill",              -- pill
           fillColor = { red = 0.04, green = 0.04, blue = 0.09, alpha = 0.6 },
           roundedRectRadii = { xRadius = HUD_H / 2, yRadius = HUD_H / 2 } }
  c[2] = { type = "oval", action = "fill", fillColor = ALIEN,        -- head
           frame = { x = HUD_W / 2 - 7, y = 6, w = 14, h = 15 } }
  c[3] = { type = "oval", action = "fill", fillColor = EYES,         -- eye L
           frame = { x = 15, y = 10, w = 3.4, h = 4.6 } }
  c[4] = { type = "oval", action = "fill", fillColor = EYES,         -- eye R
           frame = { x = 21.5, y = 10, w = 3.4, h = 4.6 } }
  c[5] = { type = "arc", action = "stroke", strokeColor = EYES,      -- smile
           strokeWidth = 1.1, center = { x = 20, y = 16 }, radius = 2.4,
           startAngle = 135, endAngle = 225 }
  c[6] = { type = "segments", action = "stroke", strokeColor = ALIEN, -- antenna
           strokeWidth = 1.2, coordinates = { { x = 20, y = 6 }, { x = 20, y = 2.5 } } }
  c[7] = { type = "oval", action = "fill", fillColor = ALIEN,        -- antenna tip
           frame = { x = 18.6, y = 0.6, w = 3, h = 3 } }
  for i = 1, BARS do
    c[i + 7] = { type = "rectangle", action = "fill",                -- bars
                 fillColor = { red = 0.35, green = 0.9, blue = 1.0, alpha = 0.95 },
                 roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
                 frame = { x = 0, y = HUD_H / 2 - 2, w = 3, h = 4 } }
  end
  hud.canvas = c
end

local function hudTick()
  local c = hud.canvas
  if not c then return end
  hud.phase = hud.phase + 0.4

  -- entrance / exit
  local yOff, alpha = 0, 1
  if hud.anim == "in" then
    hud.animT = math.min(1, hud.animT + 0.14)
    yOff  = (1 - easeOutBack(hud.animT)) * 24
    alpha = math.min(1, hud.animT * 2.5)
    if hud.animT >= 1 then hud.anim = nil end
  elseif hud.anim == "out" then
    hud.animT = math.min(1, hud.animT + 0.18)
    yOff, alpha = hud.animT * hud.animT * 24, 1 - hud.animT
    if hud.animT >= 1 then
      hud.visible = false
      if hud.timer then hud.timer:stop(); hud.timer = nil end
      c:hide()
      return
    end
  end
  c:alpha(alpha)
  c:frame({ x = hud.baseX, y = hud.baseY + yOff, w = HUD_W, h = HUD_H })

  -- alien: gentle bob, occasional blink, antenna sway
  local bob = math.sin(hud.phase * 0.45) * 1.4
  local ax, ay = HUD_W / 2, 13.5 + bob
  c[2].frame = { x = ax - 7, y = ay - 7.5, w = 14, h = 15 }
  if hud.phase >= hud.nextBlink then
    hud.blinkUntil = hud.phase + 1.3
    hud.nextBlink  = hud.phase + 16 + math.random() * 24
  end
  local eyeH  = (hud.phase < hud.blinkUntil) and 1.1 or 4.6
  local eyeCY = ay - 2.2
  c[3].frame = { x = ax - 5,   y = eyeCY - eyeH / 2, w = 3.4, h = eyeH }
  c[4].frame = { x = ax + 1.6, y = eyeCY - eyeH / 2, w = 3.4, h = eyeH }
  c[5].center = { x = ax, y = ay + 2.2 }
  local tipX = ax + math.sin(hud.phase * 0.6) * 1.6
  c[6].coordinates = { { x = ax, y = ay - 7.5 }, { x = tipX, y = ay - 11 } }
  c[7].frame = { x = tipX - 1.5, y = ay - 13.8, w = 3, h = 3 }

  -- bars flank the alien symmetrically, tallest near the center
  for i = 1, BARS do
    local d = (i <= 4) and (5 - i) or (i - 4)   -- distance from alien: 1..4
    local h
    if hud.mode == "rec" then      -- lively waveform while listening
      h = 5 + math.abs(math.sin(hud.phase + d * 0.9)) * (13 - d * 2)
            + math.random() * 2
    else                           -- wave radiating out from the alien
      h = 5 + (math.sin(hud.phase - d * 0.8) + 1) * 4.5
    end
    local x = (i <= 4) and (12 + (i - 1) * 7) or (HUD_W - 36 + (i - 5) * 7)
    c[i + 7].frame = { x = x, y = (HUD_H - h) / 2, w = 3, h = h }
  end
end

local function hudShow(mode)
  hudEnsure()
  hud.mode = mode
  local col = (mode == "rec")
      and { red = 0.35, green = 0.9,  blue = 1.0, alpha = 0.95 }   -- cyan: listening
      or  { red = 0.72, green = 0.52, blue = 1.0, alpha = 0.95 }   -- violet: thinking
  for i = 1, BARS do hud.canvas[i + 7].fillColor = col end
  if not hud.visible then
    local f = hs.screen.mainScreen():fullFrame()
    hud.baseX = f.x + (f.w - HUD_W) / 2
    hud.baseY = f.y + f.h - HUD_H - 42
    hud.visible, hud.anim, hud.animT = true, "in", 0
    hud.canvas:alpha(0)
    hud.canvas:frame({ x = hud.baseX, y = hud.baseY + 24, w = HUD_W, h = HUD_H })
    hud.canvas:show()
  elseif hud.anim == "out" then    -- caught mid-exit: come back
    hud.anim, hud.animT = "in", 0
  end
  if not hud.timer then hud.timer = hs.timer.doEvery(0.05, hudTick) end
end

local function hudHide()
  if not hud.visible then
    if hud.timer then hud.timer:stop(); hud.timer = nil end
    if hud.canvas then hud.canvas:hide() end
    return
  end
  hud.anim, hud.animT = "out", 0   -- hudTick finishes the exit
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
  if serverRunning() then return end
  M.serverTask = hs.task.new(C.whisperSrv, function(code)
    log("whisper-server exited (code " .. tostring(code) .. ")")
  end, {
    "-m", C.model, "--host", "127.0.0.1", "--port", tostring(C.serverPort),
    "-t", C.threads, "-l", C.language, "--prompt", C.vocabulary,
    "--carry-initial-prompt",  -- keep vocabulary active past 30s of speech
  })
  M.serverTask:start()
  log("whisper-server starting on port " .. C.serverPort)
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
local function insertText(text)
  local prev = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  timers.clipRestore = hs.timer.doAfter(0.8, function()
    if prev then hs.pasteboard.setContents(prev) end
  end)
  play("done")
  reset()
end

-- ---------------- LLM cleanup --------------------------------
local function cleanLLMOutput(s)
  s = s:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s:sub(1, 1) == '"' and s:sub(-1) == '"' then s = s:sub(2, -2) end
  return s
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
    "Return ONLY the cleaned text. No preamble, no quotes, no explanation.",
    "",
    "Raw dictation:",
    raw,
  }, "\n")

  local body = hs.json.encode({
    model  = C.ollamaModel,
    stream = false,
    prompt = prompt,
    keep_alive = "24h",           -- keep model in RAM, no cold-start lag
    options = { temperature = 0.1 },
  })

  -- fallback: paste raw if Ollama is slow or down
  timers.llmTimeout = hs.timer.doAfter(C.llmTimeout, function()
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

local function handleTranscript(raw, t0)
  local text = raw:gsub("%[BLANK_AUDIO%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("%s*\n%s*", " ")            -- server returns wrapped lines
  text = applyCorrections(text)
  log(string.format("whisper done in %.1fs: %s",
      hs.timer.secondsSinceEpoch() - t0, text:sub(1, 80)))
  if #text == 0 then reset() return end
  if C.llmCleanup or C.translateTo ~= "off" then llmPostProcess(text) else insertText(text) end
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
    "-l", C.language, "-t", C.threads, "--prompt", C.vocabulary,
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
  -- clean + normalize quiet mics, then hit the persistent server
  local langArg = (C.language ~= "auto")
      and (" -F language=" .. C.language) or ""
  local cmd = string.format(
    "%s %s %s highpass 80 norm -3 2>/dev/null || cp %s %s; " ..
    "/usr/bin/curl -s --max-time 30 -F file=@%s -F temperature=0.0 " ..
    "-F response_format=text%s http://127.0.0.1:%d/inference",
    C.sox, C.wav, C.wavNorm, C.wav, C.wavNorm, C.wavNorm, langArg, C.serverPort)

  M.sttTask = hs.task.new("/bin/sh", function(code, out, err)
    local ok = (code == 0) and out and #out:gsub("%s", "") > 0
               and not out:find('"error"')
    if ok then
      handleTranscript(out, t0)
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
  recTask = hs.task.new(C.sox, function(code, _, _)
    if state == "processing" then transcribe() end
  end, { "-q", "-d", "-c", "1", "-r", "16000", "-b", "16", C.wav })
  recTask:start()
  duckDown()
  setUI("rec")
  play("start")
  log("recording started (" .. context.app .. ")")
end

local function cancelRecording()
  if state ~= "recording" then return end
  state = "idle"                 -- recTask callback won't transcribe now
  if recTask and recTask:isRunning() then recTask:terminate() end
  reset()
end

local function stopRecording()
  if state ~= "recording" then return end
  state = "processing"
  setUI("work")
  duckUp()                       -- music fades back while we transcribe
  play("stop")
  if recTask and recTask:isRunning() then
    recTask:interrupt()          -- SIGINT lets sox finalize the WAV
  else
    transcribe()
  end
end

-- ---------------- hotkey: hold-to-talk + tap-to-lock ---------
local flagTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  if e:getKeyCode() ~= C.holdKeycode then return false end
  local pressed = e:getFlags().alt or e:getFlags().cmd  -- covers ⌥ or ⌘ keys

  if pressed then
    if state == "recording" and locked then
      locked = false
      stopRecording()            -- tap ends a locked recording
    elseif state == "recording" and pendingTap then
      pendingTap = false         -- second tap of a double-tap: lock on
      if timers.tapWait then timers.tapWait:stop() end
      locked = true
      setUI("lock")
    elseif state == "idle" then
      keyDownAt = hs.timer.secondsSinceEpoch()
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

-- ---------------- self-update --------------------------------
-- Fast-forward to origin/main; fleet-wide fixes reach every Mac unattended.
local function checkForUpdates(interactive)
  M.updTask = hs.task.new("/bin/sh", function(code, out)
    out = (out or ""):gsub("%s+$", "")
    if code == 0 and out:find("updated") then
      hs.alert.show("Vox updated — reloading…", 2)
      timers.updReload = hs.timer.doAfter(1.5, hs.reload)
    elseif code == 0 and out:find("current") then
      if interactive then hs.alert.show("Vox is up to date ✓", 2) end
    else
      if interactive then hs.alert.show("Vox update check failed — see console", 3) end
      log("update check failed: " .. out)
    end
  end, { "-c",
    "cd \"$HOME/vox\" && /usr/bin/git fetch -q origin main && " ..
    "if [ \"$(/usr/bin/git rev-list --count HEAD..origin/main)\" = 0 ]; " ..
    "then echo current; " ..
    "else /usr/bin/git pull -q --ff-only origin main && echo updated; fi" })
  M.updTask:start()
end
timers.updDaily = hs.timer.doEvery(6 * 3600, function() checkForUpdates(false) end)
timers.updBoot  = hs.timer.doAfter(90, function() checkForUpdates(false) end)

-- ---------------- menubar ------------------------------------
menubar = hs.menubar.new()
menubar:setIcon(icons.idle, true)
menubar:setMenu(function()
  return {
    { title = "Vox — local dictation", disabled = true },
    { title = "Hold " .. C.holdKeyName .. " to talk · double-tap to lock", disabled = true },
    { title = "-" },
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
    .. " > Accessibility > enable Hammerspoon, then relaunch it — hotkey works right after",
    8)
end

flagTap:start()
ensureServer()

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

-- Anchor everything in the module table so Lua GC never collects
-- the eventtap, menubar, canvas, or timers (classic Hammerspoon gotcha).
M.flagTap, M.menubar, M.timers, M.hud, M.sounds = flagTap, menubar, timers, hud, sounds
M.debug = { hudShow = hudShow, hudHide = hudHide, play = play,
            fix = applyCorrections }

log("Vox loaded. Hold " .. C.holdKeyName .. " to dictate.")
hs.alert.show("🎤 Vox ready — hold " .. C.holdKeyName .. " to dictate", 2)

return M
