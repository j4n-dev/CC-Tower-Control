-- setup.lua
-- Guided first-time setup for a Tower Control client node.
-- Called by bootstrap.lua when no node.cfg exists.
-- Scans peripherals and all 6 redstone sides interactively.
-- Detects monitors and asks if they should be used as node displays.
-- Writes a complete node.cfg that the client uses on every boot.

local setup = {}

-- ─────────────────────────────────────────
-- Terminal Helpers
-- ─────────────────────────────────────────
local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function header(text)
  local w, _ = term.getSize()
  local line  = string.rep("─", w)
  print(line)
  print((" "):rep(math.floor((w - #text) / 2)) .. text)
  print(line)
end

local function prompt(text, default)
  if default and default ~= "" then
    io.write(text .. " [" .. tostring(default) .. "]: ")
  else
    io.write(text .. ": ")
  end
  local input = read()
  if input == "" and default ~= nil then
    return default
  end
  return input
end

local function promptYN(text, default)
  local d = default and "Y/n" or "y/N"
  io.write(text .. " [" .. d .. "]: ")
  local input = read():lower()
  if input == "" then return default end
  return input == "y"
end

local function choose(text, options)
  while true do
    io.write(text .. " [" .. table.concat(options, "/") .. "]: ")
    local input = read():lower()
    for _, opt in ipairs(options) do
      if input == opt then return opt end
    end
    print("  Invalid. Choose: " .. table.concat(options, ", "))
  end
end

local function slugify(str)
  return str:lower()
            :gsub("[äÄ]", "ae")
            :gsub("[öÖ]", "oe")
            :gsub("[üÜ]", "ue")
            :gsub("[ß]",  "ss")
            :gsub("[^a-z0-9]+", "_")
            :gsub("^_+", "")
            :gsub("_+$", "")
end

-- ─────────────────────────────────────────
-- Peripheral Scan
-- ─────────────────────────────────────────
local SIDES = { "top", "bottom", "left", "right", "front", "back" }

-- Known peripheral categories:
--   modem   → network, skip silently
--   metric  → user assigns a monitoring role
--   monitor → display, ask if node monitor
--   skip    → ignore
local PERIPHERAL_TYPES = {
  modem                 = "modem",
  meBridge              = "metric",
  stressometer          = "metric",
  mekanismEnergyStorage = "metric",
  energyStorage         = "metric",
  monitor               = "monitor",
}

local METRIC_ROLES = { "fe", "create", "me", "skip" }

local function scanPeripherals()
  local found    = {}
  local occupied = {}

  for _, side in ipairs(SIDES) do
    local pType = peripheral.getType(side)
    if pType then
      found[#found + 1] = { side = side, pType = pType }
      occupied[side]    = pType
    end
  end

  -- Wired peripherals (not on a direct side)
  for _, name in ipairs(peripheral.getNames()) do
    local pType = peripheral.getType(name)
    if pType and not occupied[name] then
      found[#found + 1] = { side = name, pType = pType, wired = true }
    end
  end

  return found, occupied
end

local function configurePeripherals(found)
  local configured = {}
  local monitors   = {}

  if #found == 0 then
    print("  Keine Peripherals gefunden.")
    return configured, monitors
  end

  print("")
  print("--- Peripherals ---")

  for _, p in ipairs(found) do
    local category = PERIPHERAL_TYPES[p.pType] or "metric"

    if category == "modem" then
      -- Skip silently – just note it
      print("  " .. p.side .. "  [" .. p.pType .. "]  → Netzwerk-Modem (automatisch)")

    elseif category == "monitor" then
      -- Monitors are handled separately below
      print("  " .. p.side .. "  [monitor]  → Display erkannt")
      monitors[#monitors + 1] = { side = p.side }

    elseif category == "metric" then
      io.write("  " .. p.side .. "  [" .. p.pType .. "]  → Rolle? ")
      io.write("[" .. table.concat(METRIC_ROLES, "/") .. "]: ")
      local role = read():lower()

      local validRole = false
      for _, r in ipairs(METRIC_ROLES) do
        if role == r then validRole = true; break end
      end

      if not validRole or role == "skip" then
        print("    skipped.")
      else
        configured[#configured + 1] = {
          side  = p.side,
          pType = p.pType,
          role  = role,
        }
        print("    → " .. role)
      end
    end
  end

  return configured, monitors
end

-- ─────────────────────────────────────────
-- Monitor Configuration
-- ─────────────────────────────────────────
local function configureMonitors(monitors)
  if #monitors == 0 then
    return nil
  end

  print("")
  print("--- Monitor ---")

  local nodeMonitor = nil

  for _, m in ipairs(monitors) do
    print("  Monitor gefunden: " .. m.side)
    local use = promptYN("  Als Node-Display verwenden?", true)
    if use then
      -- Only one node monitor per client
      nodeMonitor = m.side
      print("  → Node-Display aktiviert auf Seite: " .. m.side)
      -- Only ask about the first monitor; extras are ignored
      break
    else
      print("  → Ignoriert.")
    end
  end

  return nodeMonitor
end

-- ─────────────────────────────────────────
-- Redstone Side Config
-- ─────────────────────────────────────────
local function configureSides(occupied)
  local controls = {}

  print("")
  print("--- Redstone Sides ---")

  for _, side in ipairs(SIDES) do
    if occupied[side] then
      print("  " .. side .. "  → belegt von [" .. occupied[side] .. "], skip")
    else
      local use = promptYN("  " .. side .. "  → Als Control verwenden?", false)
      if use then
        print("")
        local id     = prompt("    ID (z.B. light, power, machines)")
        local label  = prompt("    Label (Anzeigename)", id)
        local cType  = choose("    Typ", { "toggle", "trigger" })
        local invert = false
        if cType == "toggle" then
          invert = promptYN("    Invertiert? (OFF = Redstone an)", false)
        end

        controls[#controls + 1] = {
          id     = id,
          label  = label,
          type   = cType,
          side   = side,
          invert = invert or nil,  -- omit false to keep config clean
        }
        print("")
      end
    end
  end

  return controls
end

-- ─────────────────────────────────────────
-- Main Setup Flow
-- ─────────────────────────────────────────
function setup.run()
  clear()
  header("Tower Control – Node Setup")
  print("")

  -- 1. Identity
  local label  = prompt("Node Label (z.B. 'Etage 2 - Schmelze')")
  local area   = prompt("Area (z.B. tower, village_north)")
  local nodeId = prompt("Node ID", slugify(label))

  print("")
  print("Server Computer ID:")
  print("  (Oeffne den Server-Computer und fuehre 'id' aus)")
  local serverId = tonumber(prompt("Server ID"))

  -- 2. Peripheral scan
  print("")
  print("Scanne Peripherals...")
  local found, occupied = scanPeripherals()

  -- 3. Configure metric peripherals + detect monitors
  local peripherals, monitors = configurePeripherals(found)

  -- 4. Configure monitor if found
  local nodeMonitorSide = configureMonitors(monitors)
  -- Mark monitor side as occupied so redstone config skips it
  if nodeMonitorSide then
    occupied[nodeMonitorSide] = "monitor"
  end

  -- 5. Redstone sides
  local controls = configureSides(occupied)

  -- 6. Summary
  print("")
  header("Zusammenfassung")
  print("  Node ID:      " .. nodeId)
  print("  Label:        " .. label)
  print("  Area:         " .. area)
  print("  Server ID:    " .. tostring(serverId))
  print("  Controls:     " .. #controls)
  print("  Peripherals:  " .. #peripherals)
  if nodeMonitorSide then
    print("  Node-Display: " .. nodeMonitorSide)
  else
    print("  Node-Display: keiner")
  end
  print("")

  local confirm = promptYN("Konfiguration speichern?", true)
  if not confirm then
    print("Abgebrochen. Setup wird beim naechsten Boot erneut gestartet.")
    return nil
  end

  -- 7. Build and return config
  local cfg = {
    role             = "client",
    nodeId           = nodeId,
    label            = label,
    area             = area,
    serverId         = serverId,
    controls         = controls,
    peripherals      = peripherals,
    nodeMonitorSide  = nodeMonitorSide,  -- nil if no monitor configured
  }

  return cfg
end

return setup