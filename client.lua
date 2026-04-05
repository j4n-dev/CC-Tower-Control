-- client.lua
-- Generic Tower Control client.
-- All hardware config comes from node.cfg.
-- Node monitor uses native CC monitor API only.

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


-- Logging

local function log(msg)
  print("[client:" .. cfg.nodeId .. "] " .. msg)
end


-- Version

local function loadVersion()
  if not fs.exists("version") then return "?" end
  local f = fs.open("version", "r")
  local v = f.readAll():match("^%s*(.-)%s*$")
  f.close()
  return v
end

local VERSION_STR = loadVersion()


-- Dynamic Control Handlers

local handlers = {}

for _, control in ipairs(cfg.controls or {}) do
  local side   = control.side
  local invert = control.invert or false

  if control.type == "toggle" then
    handlers[control.id] = function(value)
      -- value is the LOGICAL value (true = on)
      -- invert maps logical to physical
      local actual = invert and (not value) or value
      log("SET " .. control.id .. " logical=" .. tostring(value)
          .. " physical=" .. tostring(actual) .. " side=" .. side)
      redstone.setOutput(side, actual)
    end

  elseif control.type == "trigger" then
    handlers[control.id] = function(_)
      log("TRIGGER " .. control.id .. " on " .. side)
      redstone.setOutput(side, not invert)
      os.sleep(0.5)
      redstone.setOutput(side, invert)
    end
  end
end


-- Logical state helper
-- Reads physical redstone and applies invert to get logical ON/OFF

local function getLogicalState(control)
  local raw = redstone.getOutput(control.side)
  if control.invert then
    return not raw
  else
    return raw
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

  for _, control in ipairs(cfg.controls or {}) do
    if control.type == "toggle" then
      result[#result + 1] = metrics.toggle(
        control.id, control.label, getLogicalState(control)
      )
    end
  end

  return result
end


-- Registration

local function register()
  log("Registering with server #" .. cfg.serverId .. "...")
  local msg       = protocol.msgRegister(cfg.nodeId)
  msg.label       = cfg.label
  msg.area        = cfg.area
  msg.nodeType    = cfg.nodeType or "generic"
  msg.controls    = cfg.controls
  msg.peripherals = cfg.peripherals

  log("SEND register -> #" .. cfg.serverId)
  local response = protocol.sendAndWait(cfg.serverId, msg, 10)

  if response and response.ok then
    log("RECV register ACK")
    if response.config then
      REPORT_EVERY = response.config.reportInterval or REPORT_EVERY
      PING_EVERY   = math.max(REPORT_EVERY * 3, 30)
      log("Intervals: report=" .. REPORT_EVERY .. "s ping=" .. PING_EVERY .. "s")
    end
  else
    log("No register ACK - continuing anyway")
  end
end


-- Message Handler

local function handleMessage(senderId, msg)
  if not protocol.isValid(msg) then
    log("RECV invalid message from #" .. tostring(senderId))
    return
  end

  local A = protocol.ACTION
  log("RECV " .. tostring(msg.action) .. " from #" .. senderId)

  if msg.action == A.SET then
    local handler = handlers[msg.capability]
    if handler then
      local ok, err = pcall(handler, msg.value)
      protocol.send(senderId, protocol.msgAck(
        cfg.nodeId, ok, ok and "ok" or tostring(err)
      ))
    else
      log("Unknown capability: " .. tostring(msg.capability))
      protocol.send(senderId, protocol.msgAck(
        cfg.nodeId, false, "unknown: " .. tostring(msg.capability)
      ))
    end

  elseif msg.action == A.QUERY then
    log("SEND report (query) -> #" .. senderId)
    protocol.send(senderId, protocol.msgReport(cfg.nodeId, collectMetrics()))

  elseif msg.action == A.PING then
    log("SEND pong -> #" .. senderId)
    protocol.send(senderId, protocol.msgPong(cfg.nodeId))

  elseif msg.action == A.UPDATE then
    log("Update requested. Rebooting...")
    os.sleep(1)
    os.reboot()
  end
end


-- Network Loop
-- Uses os.startTimer instead of protocol.receive timeout
-- so the event loop stays shared and doesn't steal events

local function sendReport()
  log("SEND report -> #" .. cfg.serverId)
  protocol.send(cfg.serverId, protocol.msgReport(cfg.nodeId, collectMetrics()))
end


-- Node Monitor UI
-- Native CC monitor API only.
-- Shares the event loop with networkLoop via timers.

local function run()
  local monSide = cfg.nodeMonitorSide
  local mon     = monSide and peripheral.wrap(monSide)

  if monSide and not mon then
    log("Monitor '" .. monSide .. "' not found - display disabled.")
    monSide = nil
  end

  if mon then
    log("Node monitor on " .. monSide)
    mon.setTextScale(0.5)
  end

  local W, H = mon and mon.getSize() or 0, 0

  local C = {
    bg       = colors.black,
    text     = colors.white,
    dim      = colors.lightGray,
    divider  = colors.lightGray,
    on       = colors.green,
    off      = colors.red,
    barFill  = colors.lime,
    barWarn  = colors.yellow,
    barCrit  = colors.red,
    barBg    = colors.gray,
    trigger  = colors.blue,
    triggerR = colors.red,
    header   = colors.gray,
  }

  local function put(x, y, text, fg, bg)
    if not mon then return end
    if y < 1 or y > H or x > W then return end
    local maxLen = W - x + 1
    if maxLen <= 0 then return end
    if #text > maxLen then text = text:sub(1, maxLen) end
    mon.setCursorPos(x, y)
    mon.setTextColor(fg or C.text)
    mon.setBackgroundColor(bg or C.bg)
    mon.write(text)
  end

  local function formatNum(n)
    if n >= 1000000 then return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then return string.format("%.1fk", n / 1000)
    else return tostring(math.floor(n)) end
  end

  local function formatTime()
    local t = os.time("local")
    return string.format("%02d:%02d", math.floor(t), math.floor((t % 1) * 60))
  end

  local function formatDate()
    local d = os.date("*t")
    if d then
      return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
    end
    return ""
  end

  local buttons = {}
  local function addBtn(x1, y1, x2, y2, action)
    buttons[#buttons + 1] = { x1=x1, y1=y1, x2=x2, y2=y2, action=action }
  end
  local function hitTest(mx, my)
    for _, b in ipairs(buttons) do
      if mx >= b.x1 and mx <= b.x2 and my >= b.y1 and my <= b.y2 then
        return b.action
      end
    end
  end

  local function render()
    if not mon then return end
    log("Monitor render")
    mon.setBackgroundColor(C.bg)
    mon.clear()
    buttons = {}

    local y  = 1
    local MT = metrics.TYPE

    -- Header row: node label left, time+date right
    local timeStr = formatTime() .. "  " .. formatDate()
    local title   = cfg.label or cfg.nodeId
    mon.setCursorPos(1, y)
    mon.setTextColor(C.text)
    mon.setBackgroundColor(C.header)
    mon.write(string.rep(" ", W))
    put(2, y, title, C.text, C.header)
    put(W - #timeStr, y, timeStr, C.dim, C.header)
    y = y + 1

    put(1, y, string.rep("\x8c", W), C.divider, C.bg)
    y = y + 1

    -- Controls
    local controls = cfg.controls or {}
    if #controls > 0 then
      put(2, y, "Controls", C.dim, C.bg)
      y = y + 1

      for _, control in ipairs(controls) do
        put(2, y, control.label or control.id, C.text, C.bg)

        if control.type == "toggle" then
          -- Read logical state fresh at render time
          local isOn = getLogicalState(control)

          local sliderText = isOn
            and "[\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 ON ]"
            or  "[OFF \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"
          local sx = W - #sliderText
          put(sx, y, sliderText, isOn and C.on or C.off, C.bg)

          -- Capture current logical state at button-creation time
          local capturedIsOn    = isOn
          local capturedControl = control
          addBtn(sx, y, W, y, function()
            local newVal = not capturedIsOn
            log("Monitor toggle " .. capturedControl.id .. " -> " .. tostring(newVal))
            local handler = handlers[capturedControl.id]
            if handler then
              pcall(handler, newVal)
              protocol.send(cfg.serverId, {
                action     = protocol.ACTION.ACK,
                nodeId     = cfg.nodeId,
                capability = capturedControl.id,
                value      = newVal,
                ok         = true,
              })
            end
            render()
          end)

        elseif control.type == "trigger" then
          local trigLabel = "[ TRIGGER ]"
          local trigBg    = control.color == "red" and C.triggerR or C.trigger
          local tx        = W - #trigLabel
          put(tx, y, trigLabel, colors.white, trigBg)
          local capturedControl = control
          addBtn(tx, y, W, y, function()
            log("Monitor trigger " .. capturedControl.id)
            local handler = handlers[capturedControl.id]
            if handler then pcall(handler, true) end
          end)
        end

        y = y + 1
      end
      y = y + 1
    end

    put(1, y, string.rep("\x8c", W), C.divider, C.bg)
    y = y + 1

    -- Metrics
    local currentMetrics = collectMetrics()
    local hasMetrics     = false

    for _, m in ipairs(currentMetrics) do
      if m.type ~= MT.TOGGLE then
        hasMetrics = true

        local valStr
        if m.type == MT.BAR and m.max and m.max > 0 then
          local pct = math.floor((m.value / m.max) * 100)
          valStr = formatNum(m.value) .. "/" .. formatNum(m.max)
                   .. " " .. (m.unit or "") .. " " .. pct .. "%"
        elseif m.type == MT.RATE then
          local arrow = m.direction == "in" and "+" or m.direction == "out" and "-" or "~"
          valStr = arrow .. formatNum(m.value) .. " " .. (m.unit or "")
        else
          valStr = formatNum(m.value) .. " " .. (m.unit or "")
        end

        put(2, y, m.label, C.text, C.bg)
        put(W - #valStr, y, valStr, C.dim, C.bg)
        y = y + 1

        if m.type == MT.BAR and m.max and m.max > 0 then
          local bw     = W - 2
          local filled = math.max(0, math.min(bw,
            math.floor((m.value / m.max) * bw)))
          local bar    = string.rep("\x8f", filled)
                         .. string.rep("\x8c", bw - filled)
          local st     = metrics.status(m)
          local fc     = st == "crit" and C.barCrit
                         or st == "warn" and C.barWarn
                         or C.barFill
          put(2, y, bar, fc, C.barBg)
          y = y + 1
        end
        y = y + 1
      end
    end

    if not hasMetrics then
      put(2, y, "No metrics.", C.dim, C.bg)
    end
  end

  
  -- Shared event loop
  -- All timers registered here; networkLoop and monitorLoop
  -- both handled in the same os.pullEvent loop to avoid
  -- one loop stealing events from the other.
  
  local reportTimer  = os.startTimer(REPORT_EVERY)
  local pingTimer    = os.startTimer(PING_EVERY)
  local refreshTimer = mon and os.startTimer(5) or nil

  -- Initial state
  sendReport()
  render()

  while true do
    local event, p1, p2, p3 = os.pullEvent()

    -- Network: incoming message
    if event == "modem_message" then
      -- protocol.receive uses rednet which wraps modem_message
      -- We need to re-queue it so rednet can process it
      -- Instead, use rednet.receive with timeout 0 to drain
      local senderId, msg = rednet.receive(protocol.CHANNEL, 0)
      if senderId and msg then
        handleMessage(senderId, msg)
        render()
      end

    -- Monitor touch
    elseif event == "monitor_touch" and p1 == monSide then
      local action = hitTest(p2, p3)
      if action then action() end

    -- Report timer
    elseif event == "timer" and p1 == reportTimer then
      sendReport()
      render()
      reportTimer = os.startTimer(REPORT_EVERY)

    -- Ping timer
    elseif event == "timer" and p1 == pingTimer then
      log("SEND ping -> #" .. cfg.serverId)
      protocol.send(cfg.serverId, protocol.msgPing(cfg.nodeId))
      pingTimer = os.startTimer(PING_EVERY)

    -- Monitor refresh timer (time display)
    elseif event == "timer" and p1 == refreshTimer then
      render()
      refreshTimer = os.startTimer(5)
    end
  end
end


-- Main

log("Tower Control Client v" .. VERSION_STR)
log("Label: " .. (cfg.label or "?") .. ", Area: " .. (cfg.area or "?"))
log("Server ID: " .. cfg.serverId)
log("Monitor: " .. (cfg.nodeMonitorSide or "none"))
log("Controls: " .. #(cfg.controls or {}))
log("Peripherals: " .. #(cfg.peripherals or {}))

protocol.open()
register()

run()