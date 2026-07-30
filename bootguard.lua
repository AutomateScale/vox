-- Vox boot guard — VOX-BOOT-GUARD v1
-- The one file that must never break: it loads Vox, and if a freshly
-- deployed vox.lua fails to load (syntax error, bad merge, half-pulled
-- update), it rolls the repo back to the last commit that loaded cleanly
-- and boots that instead. Dictation survives a broken deploy.
--
-- State files (gitignored, machine-local):
--   .vox-lkg         last commit that completed a full load (vox.lua
--                    records it at the end of a successful boot)
--   .vox-bad-commit  commit that failed to load — the updater refuses to
--                    re-pull it until origin/main moves past it

require("hs.ipc")
for _, prefix in ipairs({ "/opt/homebrew", "/usr/local" }) do
  if hs.fs.attributes(prefix .. "/bin") then
    pcall(hs.ipc.cliInstall, prefix)
    break
  end
end
local HOME = os.getenv("HOME")
package.path = package.path .. ";" .. HOME .. "/vox/?.lua"

local function sh(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  return (out:gsub("%s+$", ""))
end

local ok, err = pcall(require, "vox")
if ok then return end

print("VOX LOAD FAILED: " .. tostring(err))
local git   = "cd \"" .. HOME .. "/vox\" && /usr/bin/git "
local lkg   = sh("cat \"" .. HOME .. "/vox/.vox-lkg\"")
local head  = sh(git .. "rev-parse HEAD")
local dirty = sh(git .. "status --porcelain")

if lkg == "" or head == "" or lkg == head or dirty ~= "" then
  -- nothing safe to roll back to (first install, local edits, or the
  -- last-known-good IS what just failed) — leave the repo alone
  hs.alert.show("Vox failed to load — no clean rollback available, see console", 8)
  print(string.format("VOX: rollback skipped (lkg=%s head=%s dirty=%s)",
    lkg == "" and "none" or lkg:sub(1, 7), head:sub(1, 7),
    dirty ~= "" and "yes" or "no"))
  return
end

-- remember the culprit so checkForUpdates won't pull it straight back
sh("echo " .. head .. " > \"" .. HOME .. "/vox/.vox-bad-commit\"")
sh(git .. "reset --hard " .. lkg)
package.loaded["vox"] = nil
local ok2, err2 = pcall(require, "vox")
if ok2 then
  hs.alert.show("Vox: broken update rolled back to last-known-good ✓", 6)
  print("VOX: rolled back " .. head:sub(1, 7) .. " -> " .. lkg:sub(1, 7))
else
  hs.alert.show("Vox failed to load even after rollback — see console", 8)
  print("VOX ROLLBACK LOAD FAILED: " .. tostring(err2))
end
