-- client.lua
-- Generic Tower Control client.
-- All hardware config comes from node.cfg.
-- Node monitor uses Basalt UI framework (lib/basalt.lua) when available;
-- falls back to headless mode if no monitor is configured or Basalt is missing.

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
-- Supports two paths:
--   Basalt path  : if cfg.nodeMonitorSide is set and lib/basalt.lua is present
--   Headless path: if no monitor configured or Basalt unavailable


-- Headless event loop — no UI, network + timers only
local function headlessLoop()
  local reportTimer = os.startTimer(REPORT_EVERY)
  local pingTimer   = os.startTimer(PING_EVERY)

  sendReport()

  while true do
    local event, p1 = os.pullEvent()

    if event == "modem_message" then
      local senderId, msg = rednet.receive(protocol.CHANNEL, 0)
      if senderId and msg then handleMessage(senderId, msg) end

    elseif event == "timer" and p1 == reportTimer then
      sendReport()
      reportTimer = os.startTimer(REPORT_EVERY)

    elseif event == "timer" and p1 == pingTimer then
      log("SEND ping -> #" .. cfg.serverId)
      protocol.send(cfg.serverId, protocol.msgPing(cfg.nodeId))
      pingTimer = os.startTimer(PING_EVERY)
    end
  end
end


-- Basalt-based node monitor
local function basaltMonitorLoop(basalt, monSide, W, H)
  local CC = {
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

  local function fmtTime()
    local t = os.time("local")
    return string.format("%02d:%02d", math.floor(t), math.floor((t % 1) * 60))
  end
  local function fmtDate()
    local d = os.date("*t")
    if d then return string.format("%04d-%02d-%02d", d.year, d.month, d.day) end
    return ""
  end

  -- Root display attached to the node monitor
  local display = basalt.addMonitor()
  display:setMonitor(monSide)
  display:setBackground(CC.bg)

  -- ── Fixed header (row 1) ──────────────────────────────────────────────────

  local hdrFrame = display:addFrame()
  hdrFrame:setPosition(1, 1)
  hdrFrame:setSize(W, 1)
  hdrFrame:setBackground(CC.header)

  local hdrBg = hdrFrame:addLabel()
  hdrBg:setPosition(1, 1)
  hdrBg:setText(string.rep(" ", W))
  hdrBg:setBackground(CC.header)
  hdrBg:setForeground(CC.header)

  local titleLbl = hdrFrame:addLabel()
  titleLbl:setPosition(2, 1)
  titleLbl:setText(cfg.label or cfg.nodeId)
  titleLbl:setForeground(CC.text)
  titleLbl:setBackground(CC.header)

  local initTs  = fmtTime() .. "  " .. fmtDate()
  local timeLbl = hdrFrame:addLabel()
  timeLbl:setPosition(W - #initTs + 1, 1)
  timeLbl:setText(initTs)
  timeLbl:setForeground(CC.dim)
  timeLbl:setBackground(CC.header)

  -- ── Divider (row 2) ──────────────────────────────────────────────────────

  local divFrame = display:addFrame()
  divFrame:setPosition(1, 2)
  divFrame:setSize(W, 1)
  divFrame:setBackground(CC.bg)

  local divLbl = divFrame:addLabel()
  divLbl:setPosition(1, 1)
  divLbl:setText(string.rep("\x8c", W))
  divLbl:setForeground(CC.divider)
  divLbl:setBackground(CC.bg)

  -- ── Scrollable content (rows 3..H) ───────────────────────────────────────
  -- Note: if your Basalt version uses a different method, adjust here.
  local content = display:addScrollableFrame()
  content:setPosition(1, 3)
  content:setSize(W, H - 2)
  content:setBackground(CC.bg)

  -- Shared refresh flag — written by threads, read by the rebuild thread
  local needsRefresh  = false

  -- Pending actions for trigger controls (handlers may block during sleep(0.5))
  local pendingActions = {}
  local function addAction(fn)
    pendingActions[#pendingActions + 1] = fn
  end

  -- Builds (or rebuilds) the scrollable content area from current state
  local function buildContent()
    content:removeChildren()
    local y  = 1
    local MT = metrics.TYPE

    -- Controls section
    local controls = cfg.controls or {}
    if #controls > 0 then
      local ctrlDiv = content:addLabel()
      ctrlDiv:setPosition(1, y)
      ctrlDiv:setText("\x8c\x8c Controls " .. string.rep("\x8c", math.max(1, W - 12)))
      ctrlDiv:setForeground(CC.divider)
      ctrlDiv:setBackground(CC.bg)
      y = y + 1

      for _, control in ipairs(controls) do
        local ctrlLbl = content:addLabel()
        ctrlLbl:setPosition(2, y)
        ctrlLbl:setText(control.label or control.id)
        ctrlLbl:setForeground(CC.text)
        ctrlLbl:setBackground(CC.bg)

        if control.type == "toggle" then
          local isOn = getLogicalState(control)
          local sliderText = isOn
            and "[\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 ON ]"
            or  "[OFF \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"
          local sx = W - #sliderText + 1

          local capturedControl = control
          local capturedIsOn    = isOn
          local sliderBtn = content:addButton()
          sliderBtn:setPosition(sx, y)
          sliderBtn:setSize(#sliderText, 1)
          sliderBtn:setText(sliderText)
          sliderBtn:setBackground(CC.bg)
          sliderBtn:setForeground(isOn and CC.on or CC.off)
          sliderBtn:setActiveBackground(CC.bg)
          sliderBtn:setActiveForeground(CC.dim)
          sliderBtn:onClick(function()
            -- Toggle is local — just set redstone, no network wait needed
            local newVal = not capturedIsOn
            log("Monitor toggle " .. capturedControl.id .. " -> " .. tostring(newVal))
            local handler = handlers[capturedControl.id]
            if handler then
              pcall(handler, newVal)
              -- Notify server of the local state change
              protocol.send(cfg.serverId, {
                action     = protocol.ACTION.ACK,
                nodeId     = cfg.nodeId,
                capability = capturedControl.id,
                value      = newVal,
                ok         = true,
              })
            end
            needsRefresh = true
          end)

        elseif control.type == "trigger" then
          local trigLabel = "[ TRIGGER ]"
          local trigBg    = control.color == "red" and CC.triggerR or CC.trigger
          local tx        = W - #trigLabel + 1

          local capturedControl = control
          local trigBtn = content:addButton()
          trigBtn:setPosition(tx, y)
          trigBtn:setSize(#trigLabel, 1)
          trigBtn:setText(trigLabel)
          trigBtn:setBackground(trigBg)
          trigBtn:setForeground(colors.white)
          trigBtn:setActiveBackground(trigBg)
          trigBtn:setActiveForeground(CC.dim)
          trigBtn:onClick(function()
            -- Trigger handler sleeps 0.5s — dispatch off main coroutine
            log("Monitor trigger " .. capturedControl.id)
            local capturedHandler = handlers[capturedControl.id]
            addAction(function()
              if capturedHandler then pcall(capturedHandler, true) end
            end)
          end)
        end

        y = y + 1
      end
      y = y + 1
    end

    -- Divider between controls and metrics
    local metDiv = content:addLabel()
    metDiv:setPosition(1, y)
    metDiv:setText(string.rep("\x8c", W))
    metDiv:setForeground(CC.divider)
    metDiv:setBackground(CC.bg)
    y = y + 1

    -- Metrics section (skip TOGGLE type — shown via control sliders)
    local currentMetrics = collectMetrics()
    local hasMetrics     = false

    for _, m in ipairs(currentMetrics) do
      if m.type ~= MT.TOGGLE then
        hasMetrics = true

        local valStr
        if m.type == MT.BAR and m.max and m.max > 0 then
          local function fmt(n)
            if n >= 1000000 then return string.format("%.1fM", n / 1000000)
            elseif n >= 1000 then return string.format("%.1fk", n / 1000)
            else return tostring(math.floor(n)) end
          end
          local pct = math.floor((m.value / m.max) * 100)
          valStr = fmt(m.value) .. "/" .. fmt(m.max) .. " " .. (m.unit or "") .. " " .. pct .. "%"
        elseif m.type == MT.RATE then
          local arrow = m.direction == "in" and "+" or m.direction == "out" and "-" or "~"
          valStr = arrow .. tostring(math.floor(m.value)) .. " " .. (m.unit or "")
        else
          valStr = tostring(math.floor(m.value)) .. " " .. (m.unit or "")
        end

        local nameLbl = content:addLabel()
        nameLbl:setPosition(2, y)
        nameLbl:setText(m.label)
        nameLbl:setForeground(CC.text)
        nameLbl:setBackground(CC.bg)

        local valLbl = content:addLabel()
        valLbl:setPosition(W - #valStr + 1, y)
        valLbl:setText(valStr)
        valLbl:setForeground(CC.dim)
        valLbl:setBackground(CC.bg)
        y = y + 1

        if m.type == MT.BAR and m.max and m.max > 0 then
          local pct = math.max(0, math.min(100, math.floor((m.value / m.max) * 100)))
          local bar = content:addProgressbar()
          bar:setPosition(2, y)
          bar:setSize(W - 2, 1)
          bar:setValue(pct)
          local st = metrics.status(m)
          bar:setForeground(st == "crit" and CC.barCrit or st == "warn" and CC.barWarn or CC.barFill)
          bar:setBackground(CC.barBg)
          y = y + 1
        end
        y = y + 1
      end
    end

    if not hasMetrics then
      local noLbl = content:addLabel()
      noLbl:setPosition(2, y)
      noLbl:setText("No metrics.")
      noLbl:setForeground(CC.dim)
      noLbl:setBackground(CC.bg)
    end
  end

  -- Initial content render
  buildContent()

  -- ── Threads ───────────────────────────────────────────────────────────────

  -- Network + timer thread: handles modem messages and periodic tasks
  local reportTimer = os.startTimer(REPORT_EVERY)
  local pingTimer   = os.startTimer(PING_EVERY)

  basalt.addThread(function()
    while true do
      local event, p1 = os.pullEvent()
      if event == "modem_message" then
        local senderId, msg = rednet.receive(protocol.CHANNEL, 0)
        if senderId and msg then
          handleMessage(senderId, msg)
          needsRefresh = true
        end
      elseif event == "timer" and p1 == reportTimer then
        sendReport()
        reportTimer  = os.startTimer(REPORT_EVERY)
        needsRefresh = true
      elseif event == "timer" and p1 == pingTimer then
        log("SEND ping -> #" .. cfg.serverId)
        protocol.send(cfg.serverId, protocol.msgPing(cfg.nodeId))
        pingTimer = os.startTimer(PING_EVERY)
      end
    end
  end)

  -- Time label updater (every 1s — cheaper than a full rebuild)
  basalt.addThread(function()
    while true do
      os.sleep(1)
      local ts = fmtTime() .. "  " .. fmtDate()
      timeLbl:setPosition(W - #ts + 1, 1)
      timeLbl:setText(ts)
    end
  end)

  -- Auto-refresh trigger (every 5s)
  basalt.addThread(function()
    while true do
      os.sleep(5)
      needsRefresh = true
    end
  end)

  -- Action dispatcher + refresh applicator
  basalt.addThread(function()
    while true do
      os.sleep(0.1)
      if #pendingActions > 0 then
        local fn = table.remove(pendingActions, 1)
        fn()
        needsRefresh = true
      end
      if needsRefresh then
        needsRefresh = false
        buildContent()
      end
    end
  end)

  sendReport()
  basalt.autoUpdate()
end


local function run()
  local monSide = cfg.nodeMonitorSide
  local mon     = monSide and peripheral.wrap(monSide)

  if monSide and not mon then
    log("Monitor '" .. monSide .. "' not found - display disabled.")
    monSide = nil
  end

  -- No monitor configured: run headless
  if not monSide then
    log("Running headless (no monitor configured).")
    headlessLoop()
    return
  end

  -- Monitor available: try to use Basalt
  local ok, basalt = pcall(require, "basalt")
  if not ok then
    log("Basalt not available (" .. tostring(basalt) .. ") - running headless.")
    headlessLoop()
    return
  end

  log("Node monitor on " .. monSide .. " (Basalt UI)")
  mon.setTextScale(0.5)
  local W, H = mon.getSize()

  basaltMonitorLoop(basalt, monSide, W, H)
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