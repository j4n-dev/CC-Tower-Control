-- client.lua
-- Generic Tower Control client.
-- All hardware config (sides, labels, peripherals) comes from node.cfg.
-- If a node monitor is configured, renders a locked single-node UI via Basalt.
-- Controls on the monitor are executed locally (no server round-trip needed).

local protocol = require("lib/protocol")
local metrics  = require("lib/metrics")


-- Config

local VERSION      = "0.1.0"
local CFG_FILE     = "node.cfg"
local REPORT_EVERY = 10
local PING_EVERY   = 30

local function loadConfig()
  assert(fs.exists(CFG_FILE), "[client] node.cfg not found. Run bootstrap.lua.")
  local f   = fs.open(CFG_FILE, "r")
  local cfg = textutils.unserialiseJSON(f.readAll())
  f.close()
  assert(cfg.nodeId,   "[client] node.cfg missing nodeId")
  assert(cfg.serverId, "[client] node.cfg missing serverId")
  return cfg
end

local cfg = loadConfig()


-- Dynamic Control Handlers
-- Built from cfg.controls at startup.
-- Executing a handler directly applies the redstone change locally.

local handlers = {}

for _, control in ipairs(cfg.controls or {}) do
  local side   = control.side
  local invert = control.invert or false

  if control.type == "toggle" then
    handlers[control.id] = function(value)
      local actual = invert and not value or value
      redstone.setOutput(side, actual)
    end

  elseif control.type == "trigger" then
    handlers[control.id] = function(_value)
      local active   = not invert
      local inactive = invert
      redstone.setOutput(side, active)
      os.sleep(0.5)
      redstone.setOutput(side, inactive)
    end
  end
end


-- Metric Collection

local function collectMetrics()
  local result = {}

  for _, p in ipairs(cfg.peripherals or {}) do
    local peri = peripheral.wrap(p.side)
    if peri then
      if p.role == "fe" then
        result = metrics.merge(result, metrics.collectFE(peri, "fe"))
      elseif p.role == "create" then
        result = metrics.merge(result, metrics.collectCreate(peri))
      elseif p.role == "me" then
        result = metrics.merge(result, metrics.collectME(peri))
      end
    end
  end

  -- Current logical state of all toggle controls
  for _, control in ipairs(cfg.controls or {}) do
    if control.type == "toggle" then
      local raw     = redstone.getOutput(control.side)
      local logical = control.invert and not raw or raw
      result[#result + 1] = metrics.toggle(control.id, control.label, logical)
    end
  end

  return result
end


-- Registration

local function register()
  print("[client] Registering as " .. cfg.nodeId .. "...")

  local msg        = protocol.msgRegister(cfg.nodeId)
  msg.label        = cfg.label
  msg.area         = cfg.area
  msg.nodeType     = cfg.nodeType or "generic"
  msg.controls     = cfg.controls
  msg.peripherals  = cfg.peripherals

  local response = protocol.sendAndWait(cfg.serverId, msg, 10)

  if response and response.ok then
    print("[client] Registered. Server acknowledged.")
  else
    print("[client] No server response - will retry on next report.")
  end
end


-- Message Handler

local function handleMessage(senderId, msg)
  if not protocol.isValid(msg) then return end

  local A = protocol.ACTION

  if msg.action == A.SET then
    local handler = handlers[msg.capability]
    if handler then
      local ok, err = pcall(handler, msg.value)
      protocol.send(senderId, protocol.msgAck(
        cfg.nodeId, ok, ok and "ok" or tostring(err)
      ))
    else
      protocol.send(senderId, protocol.msgAck(
        cfg.nodeId, false, "unknown capability: " .. tostring(msg.capability)
      ))
    end

  elseif msg.action == A.QUERY then
    local m = collectMetrics()
    protocol.send(senderId, protocol.msgReport(cfg.nodeId, m))

  elseif msg.action == A.PING then
    protocol.send(senderId, protocol.msgPong(cfg.nodeId))

  elseif msg.action == A.UPDATE then
    print("[client] Update requested by server. Rebooting...")
    os.sleep(1)
    os.reboot()
  end
end


-- Network Loop

local function sendReport()
  protocol.send(cfg.serverId, protocol.msgReport(cfg.nodeId, collectMetrics()))
end

local function networkLoop()
  local lastReport = os.clock()
  local lastPing   = os.clock()

  while true do
    local senderId, msg = protocol.receive(1)

    if senderId and msg then
      handleMessage(senderId, msg)
    end

    local now = os.clock()

    if now - lastReport >= REPORT_EVERY then
      sendReport()
      lastReport = now
    end

    if now - lastPing >= PING_EVERY then
      protocol.send(cfg.serverId, protocol.msgPing(cfg.nodeId))
      lastPing = now
    end
  end
end


-- Node Monitor UI
-- Locked to this node. Controls are applied locally.
-- Refreshes every 5 seconds.

local function monitorLoop()
  local monitorSide = cfg.nodeMonitorSide
  if not monitorSide then return end

  local ok, basalt = pcall(require, "basalt")
  if not ok then
    print("[client] Basalt not available - node monitor disabled.")
    return
  end

  local mon = peripheral.wrap(monitorSide)
  if not mon then
    print("[client] Monitor on '" .. monitorSide .. "' not found - node monitor disabled.")
    return
  end

  mon.setTextScale(0.5)
  local w, h = mon.getSize()

  -- Colors
  local C = {
    bg       = colors.black,
    text     = colors.white,
    dim      = colors.lightGray,
    divider  = colors.lightGray,
    sliderOn = colors.green,
    sliderOff= colors.red,
    barNorm  = colors.lime,
    barWarn  = colors.yellow,
    barCrit  = colors.red,
    barBg    = colors.gray,
    warn     = colors.yellow,
  }

  local STATUS_ICON  = { online="*", degraded="~", unreachable="o", offline="X" }
  local STATUS_COLOR = {
    online      = colors.green,
    degraded    = colors.yellow,
    unreachable = colors.orange,
    offline     = colors.red,
  }

  local function formatNum(n)
    if n >= 1000000 then return string.format("%.1fM", n/1000000)
    elseif n >= 1000 then return string.format("%.1fk", n/1000)
    else return tostring(math.floor(n)) end
  end

  local function render()
    mon.setBackgroundColor(C.bg)
    mon.clear()

    local frame = basalt.addFrame()
      :setMonitor(mon)
      :setPosition(1, 1)
      :setSize(w, h)
      :setBackground(C.bg)

    local y = 1

    -- Header: status icon + label
    local currentMetrics = collectMetrics()

    -- Find online status from toggle metrics (best proxy we have locally)
    -- Node is always "online" from its own perspective
    frame:addLabel()
      :setPosition(2, y)
      :setText("*")
      :setForegroundColor(colors.green)

    frame:addLabel()
      :setPosition(4, y)
      :setText(cfg.label or cfg.nodeId)
      :setForegroundColor(C.text)

    y = y + 2

    -- Divider
    frame:addLabel()
      :setPosition(1, y)
      :setText(string.rep("\x8c", w))
      :setForegroundColor(C.divider)
    y = y + 1

    -- Controls
    if #(cfg.controls or {}) > 0 then
      frame:addLabel()
        :setPosition(2, y)
        :setText("Controls")
        :setForegroundColor(C.dim)
      y = y + 1

      for _, control in ipairs(cfg.controls or {}) do
        if control.type == "toggle" then
          -- Get current logical state
          local raw     = redstone.getOutput(control.side)
          local isOn    = control.invert and not raw or raw

          frame:addLabel()
            :setPosition(2, y)
            :setText(control.label or control.id)
            :setForegroundColor(C.text)

          local sliderText, sliderCol
          if isOn then
            sliderText = "[\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 AN ]"
            sliderCol  = C.sliderOn
          else
            sliderText = "[AUS \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"
            sliderCol  = C.sliderOff
          end

          local btn = frame:addButton()
            :setPosition(w - #sliderText - 1, y)
            :setSize(#sliderText, 1)
            :setText(sliderText)
            :setForegroundColor(sliderCol)
            :setBackgroundColor(C.bg)

          -- Capture loop variables
          local capturedControl = control
          local capturedIsOn    = isOn
          btn:onClick(function()
            local newVal = not capturedIsOn
            local handler = handlers[capturedControl.id]
            if handler then
              pcall(handler, newVal)
              -- Also notify server so its state stays in sync
              protocol.send(cfg.serverId, {
                action     = protocol.ACTION.ACK,
                nodeId     = cfg.nodeId,
                capability = capturedControl.id,
                value      = newVal,
                ok         = true,
              })
              render()  -- re-render immediately after toggle
            end
          end)

          y = y + 1

        elseif control.type == "trigger" then
          frame:addLabel()
            :setPosition(2, y)
            :setText(control.label or control.id)
            :setForegroundColor(C.text)

          local col = control.color == "red" and C.barCrit or colors.blue
          local btn = frame:addButton()
            :setPosition(w - 14, y)
            :setSize(12, 1)
            :setText("[AUSLOESEN]")
            :setForegroundColor(colors.white)
            :setBackgroundColor(col)

          local capturedControl = control
          btn:onClick(function()
            local handler = handlers[capturedControl.id]
            if handler then pcall(handler, true) end
          end)

          y = y + 1
        end
      end

      y = y + 1
    end

    -- Divider before metrics
    frame:addLabel()
      :setPosition(1, y)
      :setText(string.rep("\x8c", w))
      :setForegroundColor(C.divider)
    y = y + 1

    -- Metrics
    local MT = metrics.TYPE
    local hasMetrics = false

    for _, m in ipairs(currentMetrics) do
      if m.type ~= MT.TOGGLE then
        hasMetrics = true

        -- Label + value on one line
        local valStr
        if m.type == MT.BAR and m.max and m.max > 0 then
          local pct = math.floor((m.value / m.max) * 100)
          valStr = formatNum(m.value) .. "/" .. formatNum(m.max) .. " " .. (m.unit or "") .. "  " .. pct .. "%"
        elseif m.type == MT.RATE then
          local arrow = m.direction == "in" and "+" or m.direction == "out" and "-" or "~"
          valStr = arrow .. formatNum(m.value) .. " " .. (m.unit or "")
        else
          valStr = formatNum(m.value) .. " " .. (m.unit or "")
        end

        frame:addLabel()
          :setPosition(2, y)
          :setText(m.label)
          :setForegroundColor(C.text)

        frame:addLabel()
          :setPosition(w - #valStr - 1, y)
          :setText(valStr)
          :setForegroundColor(C.dim)

        y = y + 1

        -- Progress bar for BAR type
        if m.type == MT.BAR and m.max and m.max > 0 then
          local barW   = w - 2
          local ratio  = m.value / m.max
          local filled = math.floor(ratio * barW)
          filled       = math.max(0, math.min(barW, filled))
          local bar    = string.rep("\x8f", filled) .. string.rep("\x8c", barW - filled)

          local ms = metrics
          local st = ms.status(m)
          local barCol = st == "crit" and C.barCrit or
                         st == "warn" and C.barWarn or
                         C.barNorm

          frame:addLabel()
            :setPosition(2, y)
            :setText(bar)
            :setForegroundColor(barCol)
            :setBackgroundColor(C.barBg)

          y = y + 1
        end

        y = y + 1  -- spacing between metrics
      end
    end

    if not hasMetrics then
      frame:addLabel()
        :setPosition(2, y)
        :setText("Keine Metriken.")
        :setForegroundColor(C.dim)
    end

    basalt.autoUpdate()
  end

  -- Initial render + refresh loop
  render()

  while true do
    os.sleep(5)
    render()
  end
end


-- Main

print("[client] Tower Control Client v" .. VERSION)
print("[client] Node: " .. cfg.nodeId .. " (\"" .. (cfg.label or "") .. "\")")

if cfg.nodeMonitorSide then
  print("[client] Node monitor: " .. cfg.nodeMonitorSide)
else
  print("[client] No node monitor configured.")
end

protocol.open()
register()

-- Initial metric report
local function sendReport()
  protocol.send(cfg.serverId, protocol.msgReport(cfg.nodeId, collectMetrics()))
end
sendReport()

-- Run network loop and monitor UI in parallel.
-- If no monitor is configured, monitorLoop returns immediately
-- and parallel just runs networkLoop alone.
parallel.waitForAny(networkLoop, monitorLoop)