-- Copy this file to local.lua and customize. local.lua is gitignored, so
-- your personal vocabulary never ends up in the repo.
return {
  -- Names, brands, and jargon Whisper should spell correctly:
  -- vocabulary = "YourCompany, YourClient, YourProduct, kubernetes, Postgres.",

  -- Deterministic fixes for words Whisper keeps getting wrong:
  -- corrections = {
  --   ["your company"] = "YourCompany",
  --   ["post gress"]   = "Postgres",
  -- },

  -- Old/slow Mac? Borrow a fast Mac's transcription over your LAN:
  --   on THIS slow Mac:  whisperHost = "192.168.1.50",   -- the fast Mac's IP
  --   on the FAST Mac:   serverBind  = "0.0.0.0",        -- accept LAN requests
  -- (LAN-only; keep both defaults unless you need this.)

  -- Ancient hardware, LAN-less, but you WANT the LLM to run anyway? OK:
  -- forceLocalLLM = true,   -- enables smart-reply / expand / cleanup on
  --                         -- <=2-core CPUs where Vox normally refuses.
  -- ollamaModel   = "llama3.2:1b",   -- smallest useful reply model (~10-20s
  --                                  -- per short reply on a 2012 MBA).
  -- models        = { fast = "llama3.2:1b", smart = "llama3.2:1b" },

  -- Any other config key from vox.lua works here too:
  -- language = "fr",
  -- holdKeycode = 54, holdKeyName = "Right Command",
  -- duckLevel = 0.25,
}
