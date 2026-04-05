-- bootstrap.lua  (= startup.lua on every computer)
-- One-liner install:
--   wget https://raw.githubusercontent.com/j4n-dev/CC-Tower-Control/master/bootstrap.lua startup.lua && reboot
--
-- On every boot:
--   1. Pull latest version from GitHub if changed
--   2. Run guided setup if no node.cfg exists
--   3. Launch server.lua or client.lua based on role


-- CONFIG - set to your repo

local GITHUB_RAW  = "https://raw.githubusercontent.com/j4n-dev/CC-Tower-Control/master"
local CFG_FILE    = "node.cfg"
local VERSION_URL = GITHUB_RAW .. "/version"

-- Both clients and server get ui.lua - clients need it for node monitors
local CLIENT_FILES = {
  "lib/protocol.lua",
  "lib/metrics.lua",
  "lib/ui.lua",
  "client.lua",
  "setup.lua",
  "config.json",
  "version",
}

local SERVER_FILES = {
  "lib/protocol.lua",
  "lib/metrics.lua",
  "lib/ui.lua",
  "server.lua",
  "setup.lua",
  "config.json",
  "version",
}


-- Helpers

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

-- Version Check & Update

local function checkAndUpdate(fileList)
  print("[bootstrap] Checking for updates...")

  local remote = trim(httpGet(VERSION_URL) or "")
  if remote == "" then
    print("[bootstrap] GitHub unreachable - skipping update.")
    return
  end

  local local_ = trim(readFile("version") or "")

  if local_ == remote then
    print("[bootstrap] Up to date (" .. local_ .. ")")
    return
  end

  print("[bootstrap] Updating " .. local_ .. " --> " .. remote)

  for _, file in ipairs(fileList) do
    local body = httpGet(GITHUB_RAW .. "/" .. file)
    if body then
      writeFile(file, body)
      print("[SUCCESS]" .. file)
    else
      print("[FAILED]" .. file .. " (failed - keeping existing)")
    end
  end

  print("[bootstrap] Done. Reboot now? [y/n]")
  os.sleep(1)
  local ans = read():lower()
  if ans == "y" then
    os.reboot()
  end
end


-- Role Selection
-- Called only on first boot when no node.cfg exists.

local function selectRole()
  print("")
  print("=== Tower Control - First Boot ===")
  print("")
  print("Is this the SERVER (control center)? [y/n]")
  local ans = read():lower()

  if ans == "y" then
    writeFile(CFG_FILE, textutils.serialiseJSON({
      role   = "server",
      nodeId = "server",
    }))
    print("Server role saved.")

    print("Finished initial setup. Reboot now? [y/n]")
    os.sleep(1)

      local ans = read():lower()
  if ans == "y" then
    os.reboot()
  end
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


-- Main


-- Determine file list based on existing role (if any)
local existingCfg
if fs.exists(CFG_FILE) then
  local f = fs.open(CFG_FILE, "r")
  existingCfg = textutils.unserialiseJSON(f.readAll())
  f.close()
end

local isServer = existingCfg and existingCfg.role == "server"
local fileList = isServer and SERVER_FILES or CLIENT_FILES

-- 1. First-time setup if no config yet
if not fs.exists(CFG_FILE) then
  selectRole()
  return
end

print("Tower Control - Bootstrap")
print("==========================")

-- 2. Check for updates
checkAndUpdate(fileList)

-- 3. Launch
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