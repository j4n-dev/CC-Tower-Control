-- bootstrap.lua  (= startup.lua on every computer)
-- One-liner install:
--   wget https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap.lua startup.lua && reboot
--
-- On every boot:
--   1. Ensure Basalt is installed (all computers, needed for node monitors too)
--   2. Pull latest version from GitHub if changed
--   3. Run guided setup if no node.cfg exists
--   4. Launch server.lua or client.lua based on role

-- ─────────────────────────────────────────
-- CONFIG – set to your repo
-- ─────────────────────────────────────────
local GITHUB_RAW  = "https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main"
local CFG_FILE    = "node.cfg"
local VERSION_URL = GITHUB_RAW .. "/version"

-- Both clients and server get ui.lua – clients need it for node monitors
local CLIENT_FILES = {
  "lib/protocol.lua",
  "lib/metrics.lua",
  "lib/ui.lua",
  "client.lua",
  "setup.lua",
  "version",
}

local SERVER_FILES = {
  "lib/protocol.lua",
  "lib/metrics.lua",
  "lib/ui.lua",
  "server.lua",
  "setup.lua",
  "version",
}

-- ─────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────
local function readFile(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local s = f.readAll()
  f.close()
  return s
end

local function writeFile(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(content)
  f.close()
end

local function httpGet(url)
  local ok, response = pcall(http.get, url)
  if not ok or not response then return nil end
  local body = response.readAll()
  response.close()
  return body
end

local function trim(s)
  return s and s:match("^%s*(.-)%s*$") or ""
end

-- ─────────────────────────────────────────
-- Basalt Installer
-- Runs on every computer – clients need Basalt for node monitors.
-- Skipped silently if already installed.
-- ─────────────────────────────────────────
local function ensureBasalt()
  if fs.exists("basalt.lua") then return end
  print("[bootstrap] Installing Basalt...")
  local body = httpGet("https://raw.githubusercontent.com/Pyroxenium/Basalt/refs/heads/master/docs/install.lua release")
  if not body then
    print("[bootstrap] Could not reach Basalt CDN – UI will be unavailable.")
    print("[bootstrap] Continuing without Basalt...")
    return
  end
  writeFile("basalt_install.lua", body)
  shell.run("basalt_install.lua")
  fs.delete("basalt_install.lua")
  print("[bootstrap] Basalt installed.")
end

-- ─────────────────────────────────────────
-- Version Check & Update
-- ─────────────────────────────────────────
local function checkAndUpdate(fileList)
  print("[bootstrap] Checking for updates...")

  local remote = trim(httpGet(VERSION_URL) or "")
  if remote == "" then
    print("[bootstrap] GitHub unreachable – skipping update.")
    return
  end

  local local_ = trim(readFile("version") or "")

  if local_ == remote then
    print("[bootstrap] Up to date (" .. local_ .. ")")
    return
  end

  print("[bootstrap] Updating " .. local_ .. " → " .. remote)

  for _, file in ipairs(fileList) do
    local body = httpGet(GITHUB_RAW .. "/" .. file)
    if body then
      writeFile(file, body)
      print("  ✓ " .. file)
    else
      print("  ✗ " .. file .. " (failed – keeping existing)")
    end
  end

  print("[bootstrap] Done. Rebooting...")
  os.sleep(1)
  os.reboot()
end

-- ─────────────────────────────────────────
-- Role Selection
-- Called only on first boot when no node.cfg exists.
-- ─────────────────────────────────────────
local function selectRole()
  print("")
  print("=== Tower Control – First Boot ===")
  print("")
  print("Is this the SERVER (control center)? [y/n]")
  local ans = read():lower()

  if ans == "y" then
    writeFile(CFG_FILE, textutils.serialiseJSON({
      role   = "server",
      nodeId = "server",
    }))
    print("Server role saved.")
    os.sleep(1)
    os.reboot()
  end

  -- Client: run guided setup
  local setup = require("setup")
  local cfg   = setup.run()

  if not cfg then
    print("[bootstrap] Setup cancelled. Halting.")
    return
  end

  writeFile(CFG_FILE, textutils.serialiseJSON(cfg))
  print("[bootstrap] node.cfg saved.")
  os.sleep(1)
  os.reboot()
end

-- ─────────────────────────────────────────
-- Main
-- ─────────────────────────────────────────
print("Tower Control – Bootstrap")
print("==========================")

-- Determine file list based on existing role (if any)
local existingCfg
if fs.exists(CFG_FILE) then
  local f = fs.open(CFG_FILE, "r")
  existingCfg = textutils.unserialiseJSON(f.readAll())
  f.close()
end

local isServer = existingCfg and existingCfg.role == "server"
local fileList = isServer and SERVER_FILES or CLIENT_FILES

-- 1. Basalt first – needed before anything else runs
ensureBasalt()

-- 2. Update files from GitHub
checkAndUpdate(fileList)

-- 3. First-time setup if no config yet
if not fs.exists(CFG_FILE) then
  selectRole()
  return
end

-- 4. Launch
local f   = fs.open(CFG_FILE, "r")
local cfg = textutils.unserialiseJSON(f.readAll())
f.close()

if cfg.role == "server" then
  print("[bootstrap] Starting server...")
  shell.run("server.lua")
else
  print("[bootstrap] Starting client: " .. (cfg.nodeId or "?"))
  shell.run("client.lua")
end