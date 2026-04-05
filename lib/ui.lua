-- lib/ui.lua
-- Basalt 1 UI for Tower Control System.
-- Basalt 1 API:
--   basalt.createFrame()          main frame (terminal)
--   basalt.addMonitor("side")     monitor frame
--   basalt.autoUpdate()           event loop (blocking)
--   frame:addLabel/Button/etc.
--   element:setForegroundColor()  / :setBackgroundColor()
--   element:setTextColor()        (alias)

local ui = {}

-- ─────────────────────────────────────────
-- Constants
-- ─────────────────────────────────────────
local COLORS = {
  bg          = colors.black,
  bgPanel     = colors.gray,
  bgTab       = colors.gray,
  bgTabActive = colors.black,
  divider     = colors.lightGray,
  text        = colors.white,
  textDim     = colors.lightGray,
  textLabel   = colors.white,

  online      = colors.green,
  degraded    = colors.yellow,
  unreachable = colors.orange,
  offline     = colors.red,

  barNormal   = colors.lime,
  barWarn     = colors.yellow,
  barCrit     = colors.red,
  barBg       = colors.gray,

  sliderOn    = colors.green,
  sliderOff   = colors.red,
  sliderDis   = colors.gray,

  btnBack     = colors.gray,
  btnAllOn    = colors.green,
  btnAllOff   = colors.red,

  pinnedHdr   = colors.cyan,
  rateIn      = colors.lime,
  rateOut     = colors.red,
  rateNet     = colors.white,

  warn        = colors.yellow,
  crit        = colors.red,
}

local STATUS_ICON = {
  online      = "\x07",
  degraded    = "\x14",
  unreachable = "\x09",
  offline     = "\xd7",
}

local STATUS_COLOR = {
  online      = COLORS.online,
  degraded    = COLORS.degraded,
  unreachable = COLORS.unreachable,
  offline     = COLORS.offline,
}

-- ─────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────
local function statusIcon(status)
  return STATUS_ICON[status] or "?"
end

local function statusColor(status)
  return STATUS_COLOR[status] or COLORS.textDim
end

local function barColor(m)
  local ms = require("lib/metrics")
  local st = ms.status(m)
  if st == "crit" then return COLORS.barCrit end
  if st == "warn" then return COLORS.barWarn end
  return COLORS.barNormal
end

local function warnIcon(m)
  local ms = require("lib/metrics")
  local st = ms.status(m)
  if st == "crit" or st == "warn" then return " !" end
  return ""
end

local function formatNum(n)
  if n >= 1000000 then
    return string.format("%.1fM", n / 1000000)
  elseif n >= 1000 then
    return string.format("%.1fk", n / 1000)
  else
    return tostring(math.floor(n))
  end
end

local function formatMetricValue(m)
  local MT = require("lib/metrics").TYPE
  if m.type == MT.BAR then
    local pct = m.max > 0 and math.floor((m.value / m.max) * 100) or 0
    return formatNum(m.value) .. " / " .. formatNum(m.max) .. " " .. (m.unit or "") ..
           "   " .. pct .. "%" .. warnIcon(m)
  elseif m.type == MT.RATE then
    local arrow = m.direction == "in"  and "\x18 " or
                  m.direction == "out" and "\x19 " or "~ "
    return arrow .. formatNum(m.value) .. " " .. (m.unit or "")
  elseif m.type == MT.VALUE then
    return formatNum(m.value) .. " " .. (m.unit or "") .. warnIcon(m)
  elseif m.type == MT.TOGGLE then
    return m.value and "ON" or "OFF"
  end
  return tostring(m.value)
end

-- ─────────────────────────────────────────
-- Pinned Metrics
-- ─────────────────────────────────────────
local function getPinnedFor(targetId, server)
  local registry = server.getRegistry()
  local result   = {}
  for _, node in ipairs(registry.nodes) do
    for _, pin in ipairs(node.pinMetrics or {}) do
      if pin.to == targetId then
        local ns = server.getNodeState(node.id)
        if ns and ns.metrics and ns.metrics[pin.metricId] then
          result[#result + 1] = {
            metric      = ns.metrics[pin.metricId],
            sourceLabel = node.label or node.id,
          }
        end
      end
    end
  end
  return result
end

local function getPinnedTargets(nodeDef)
  local targets = {}
  local seen    = {}
  for _, pin in ipairs(nodeDef.pinMetrics or {}) do
    if not seen[pin.to] then
      targets[#targets + 1] = pin.to
      seen[pin.to] = true
    end
  end
  return targets
end

-- ─────────────────────────────────────────
-- Render Helpers
-- All use Basalt 1 API: setForegroundColor / setBackgroundColor
-- ─────────────────────────────────────────
local function addDivider(frame, y, label)
  local w, _ = frame:getSize()
  local line
  if label and label ~= "" then
    line = "\x8c\x8c " .. label .. " " .. string.rep("\x8c", math.max(0, w - #label - 5))
  else
    line = string.rep("\x8c", w)
  end
  frame:addLabel()
    :setPosition(1, y)
    :setText(line)
    :setForegroundColor(COLORS.divider)
  return y + 1
end

local function addMetricBar(frame, y, m, sourceLabel)
  local w, _ = frame:getSize()
  local MT   = require("lib/metrics").TYPE

  local labelText = m.label
  if sourceLabel then
    labelText = labelText .. "  [" .. sourceLabel .. "]"
  end
  local valText = formatMetricValue(m)

  frame:addLabel()
    :setPosition(2, y)
    :setText(labelText)
    :setForegroundColor(COLORS.textLabel)

  frame:addLabel()
    :setPosition(w - #valText, y)
    :setText(valText)
    :setForegroundColor(warnIcon(m) ~= "" and COLORS.warn or COLORS.textDim)

  y = y + 1

  if m.type == MT.BAR and m.max and m.max > 0 then
    local barW   = w - 2
    local filled = math.floor((m.value / m.max) * barW)
    filled       = math.max(0, math.min(barW, filled))
    local bar    = string.rep("\x8f", filled) .. string.rep("\x8c", barW - filled)

    frame:addLabel()
      :setPosition(2, y)
      :setText(bar)
      :setForegroundColor(barColor(m))
      :setBackgroundColor(COLORS.barBg)

    y = y + 1

  elseif m.type == MT.RATE then
    local col = m.direction == "in"  and COLORS.rateIn  or
                m.direction == "out" and COLORS.rateOut or
                COLORS.rateNet
    frame:addLabel()
      :setPosition(w - #valText, y - 1)
      :setText(valText)
      :setForegroundColor(col)
  end

  return y + 1
end

local function addSlider(frame, y, control, currentValue, disabled, onToggle)
  local label = control.label or control.id
  local isOn  = currentValue

  frame:addLabel()
    :setPosition(2, y)
    :setText(label)
    :setForegroundColor(disabled and COLORS.textDim or COLORS.textLabel)

  if disabled then
    frame:addLabel()
      :setPosition(20, y)
      :setText("[ .......... ]")
      :setForegroundColor(COLORS.sliderDis)
  else
    local sliderText, sliderCol
    if isOn then
      sliderText = "[ \x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 ON  ]"
      sliderCol  = COLORS.sliderOn
    else
      sliderText = "[ OFF \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"
      sliderCol  = COLORS.sliderOff
    end

    local btn = frame:addButton()
      :setPosition(18, y)
      :setSize(#sliderText, 1)
      :setText(sliderText)
      :setForegroundColor(sliderCol)
      :setBackgroundColor(COLORS.bg)

    btn:onClick(function()
      if onToggle then onToggle(control.id, not isOn) end
    end)
  end

  return y + 2
end

-- ─────────────────────────────────────────
-- Screen Builders
-- ─────────────────────────────────────────
local function buildAreaScreen(frame, area, server, onNodeSelect)
  local w, _  = frame:getSize()
  local y     = 1
  local state = server.getState()
  local idx   = server.getNodeIndex()

  frame:addButton()
    :setPosition(w - 16, y)
    :setSize(8, 1)
    :setText(" All ON")
    :setForegroundColor(colors.white)
    :setBackgroundColor(COLORS.btnAllOn)
    :onClick(function()
      server.sendControlToArea(area.id, "power", true)
      server.sendControlToArea(area.id, "light", true)
    end)

  frame:addButton()
    :setPosition(w - 7, y)
    :setSize(8, 1)
    :setText("All OFF")
    :setForegroundColor(colors.white)
    :setBackgroundColor(COLORS.btnAllOff)
    :onClick(function()
      server.sendControlToArea(area.id, "power", false)
      server.sendControlToArea(area.id, "light", false)
    end)

  y = y + 2
  y = addDivider(frame, y, "Nodes")
  y = y + 1

  for _, nodeId in ipairs(area.nodes or {}) do
    local nodeDef = idx[nodeId]
    local ns      = state[nodeId]
    if nodeDef then
      local status = (ns and ns.status) or "offline"

      frame:addLabel()
        :setPosition(2, y)
        :setText(statusIcon(status))
        :setForegroundColor(statusColor(status))

      local label = nodeDef.label or nodeId
      local btn = frame:addButton()
        :setPosition(4, y)
        :setSize(w - 6, 1)
        :setText(label .. string.rep(" ", math.max(1, w - 6 - #label - 1)) .. ">")
        :setForegroundColor(COLORS.text)
        :setBackgroundColor(COLORS.bg)

      local capturedId = nodeId
      btn:onClick(function()
        if onNodeSelect then onNodeSelect(capturedId) end
      end)

      y = y + 1

      frame:addLabel()
        :setPosition(2, y)
        :setText(string.rep("\x8c", w - 3))
        :setForegroundColor(COLORS.bgPanel)
      y = y + 1
    end
  end

  local pinned = getPinnedFor(area.id, server)
  if #pinned > 0 then
    y = y + 1
    y = addDivider(frame, y, "Pinned")
    y = y + 1
    for _, p in ipairs(pinned) do
      y = addMetricBar(frame, y, p.metric, p.sourceLabel)
    end
  end
end

local function buildDetailScreen(frame, nodeId, server, onBack)
  local w, _    = frame:getSize()
  local y       = 1
  local idx     = server.getNodeIndex()
  local state   = server.getState()
  local nodeDef = idx[nodeId]
  local ns      = state[nodeId]

  if not nodeDef then
    frame:addLabel():setPosition(2, 2):setText("Node not found: " .. nodeId)
    return
  end

  local status   = (ns and ns.status) or "offline"
  local disabled = status == "unreachable" or status == "offline"

  frame:addButton()
    :setPosition(1, y)
    :setSize(10, 1)
    :setText("< Back")
    :setForegroundColor(COLORS.text)
    :setBackgroundColor(COLORS.btnBack)
    :onClick(function()
      if onBack then onBack() end
    end)

  frame:addLabel()
    :setPosition(12, y)
    :setText(statusIcon(status))
    :setForegroundColor(statusColor(status))

  frame:addLabel()
    :setPosition(14, y)
    :setText(nodeDef.label or nodeId)
    :setForegroundColor(COLORS.text)

  y = y + 2

  local controls = nodeDef.controls or {}
  if #controls > 0 then
    y = addDivider(frame, y, "Controls")
    y = y + 1

    for _, control in ipairs(controls) do
      if control.type == "toggle" then
        local currentVal = ns and ns.controls and ns.controls[control.id] or false
        y = addSlider(frame, y, control, currentVal, disabled, function(capId, newVal)
          local ok, err = server.sendControl(nodeId, capId, newVal)
          if not ok then
            print("[ui] Control failed: " .. tostring(err))
          end
        end)

      elseif control.type == "trigger" then
        frame:addLabel()
          :setPosition(2, y)
          :setText(control.label or control.id)
          :setForegroundColor(disabled and COLORS.textDim or COLORS.textLabel)

        if not disabled then
          local col = control.color == "red" and COLORS.crit or colors.blue
          local btn = frame:addButton()
            :setPosition(18, y)
            :setSize(12, 1)
            :setText("[ TRIGGER ]")
            :setForegroundColor(colors.white)
            :setBackgroundColor(col)

          local capturedId = control.id
          btn:onClick(function()
            server.sendControl(nodeId, capturedId, true)
          end)
        else
          frame:addLabel()
            :setPosition(18, y)
            :setText("[ ........ ]")
            :setForegroundColor(COLORS.sliderDis)
        end
        y = y + 2
      end
    end
  end

  local metricList = {}
  if ns and ns.metrics then
    for _, m in pairs(ns.metrics) do
      if m.type ~= require("lib/metrics").TYPE.TOGGLE then
        metricList[#metricList + 1] = m
      end
    end
  end

  if #metricList > 0 then
    y = y + 1
    y = addDivider(frame, y, "Metrics")
    y = y + 1
    for _, m in ipairs(metricList) do
      y = addMetricBar(frame, y, m, nil)
    end
  end

  local targets = getPinnedTargets(nodeDef)
  if #targets > 0 then
    y = y + 1
    y = addDivider(frame, y, "Pinned in")
    y = y + 1

    local reg = server.getRegistry()
    for _, targetId in ipairs(targets) do
      local targetLabel = targetId
      for _, area in ipairs(reg.areas) do
        if area.id == targetId then targetLabel = area.label or targetId; break end
      end
      for _, node in ipairs(reg.nodes) do
        if node.id == targetId then targetLabel = node.label or targetId; break end
      end

      local pinnedHere = {}
      for _, pin in ipairs(nodeDef.pinMetrics or {}) do
        if pin.to == targetId then
          pinnedHere[#pinnedHere + 1] = pin.metricId
        end
      end

      frame:addLabel()
        :setPosition(2, y)
        :setText(targetLabel .. ": " .. table.concat(pinnedHere, ", "))
        :setForegroundColor(COLORS.pinnedHdr)

      y = y + 1
    end
  end
end

local function buildMEScreen(frame, server)
  local w, _ = frame:getSize()
  local y    = 1
  local ns   = server.getNodeState("me_network") or { metrics = {}, status = "offline" }
  local status = ns.status or "offline"

  frame:addLabel()
    :setPosition(2, y)
    :setText("ME Network")
    :setForegroundColor(COLORS.text)

  frame:addLabel()
    :setPosition(w - 3, y)
    :setText(statusIcon(status))
    :setForegroundColor(statusColor(status))

  y = y + 2

  local meOrder = { "me_energy", "me_usage", "me_items", "me_fluids" }
  for _, id in ipairs(meOrder) do
    local m = ns.metrics and ns.metrics[id]
    if m then y = addMetricBar(frame, y, m, nil) end
  end

  local watchItems = {}
  if ns.metrics then
    for id, m in pairs(ns.metrics) do
      if id:sub(1, 5) == "item_" then
        watchItems[#watchItems + 1] = m
      end
    end
  end

  if #watchItems > 0 then
    y = y + 1
    y = addDivider(frame, y, "Watch Items")
    y = y + 1

    table.sort(watchItems, function(a, b) return a.label < b.label end)

    for _, m in ipairs(watchItems) do
      local val    = formatNum(m.value)
      local warn   = warnIcon(m)
      local col    = warn ~= "" and COLORS.warn or COLORS.textDim
      local barW   = math.floor(w * 0.5)
      local thresh = m.warnAt or 0
      local ratio  = thresh > 0 and math.min(1, m.value / thresh) or 0
      local filled = math.floor(ratio * barW)
      local bar    = string.rep("\x8f", filled) .. string.rep("\x8c", barW - filled)

      frame:addLabel()
        :setPosition(2, y)
        :setText(m.label)
        :setForegroundColor(COLORS.textLabel)

      frame:addLabel()
        :setPosition(2 + barW + 2, y)
        :setText(val .. warn)
        :setForegroundColor(col)

      y = y + 1

      frame:addLabel()
        :setPosition(2, y)
        :setText(bar)
        :setForegroundColor(warn ~= "" and COLORS.barWarn or COLORS.barNormal)
        :setBackgroundColor(COLORS.barBg)

      y = y + 2
    end
  end

  local pinned = getPinnedFor("me_network", server)
  if #pinned > 0 then
    y = y + 1
    y = addDivider(frame, y, "Pinned from nodes")
    y = y + 1
    for _, p in ipairs(pinned) do
      y = addMetricBar(frame, y, p.metric, p.sourceLabel)
    end
  end
end

-- ─────────────────────────────────────────
-- Main UI Entry Point
-- Basalt 1: addMonitor(name) for monitor frames, autoUpdate() for event loop
-- ─────────────────────────────────────────
function ui.run(server)
  local ok, basalt = pcall(require, "basalt")
  if not ok then
    error("[ui] Basalt not found.")
  end

  -- Find monitor peripheral name
  local monitorName = peripheral.find and peripheral.getName(peripheral.find("monitor"))
  if not monitorName then
    -- fallback: scan sides
    for _, side in ipairs({"top","bottom","left","right","front","back"}) do
      if peripheral.getType(side) == "monitor" then
        monitorName = side
        break
      end
    end
  end

  if not monitorName then
    error("[ui] No monitor found.")
  end

  local mon = peripheral.wrap(monitorName)
  mon.setTextScale(0.5)
  local w, h = mon.getSize()

  local registry   = server.getRegistry()
  local areas      = registry.areas or {}
  local TAB_H      = 2
  local contentH   = h - TAB_H

  local activeArea = areas[1] and areas[1].id or nil
  local activeNode = nil

  -- scrollOffset per view key
  local scrollOffset = {}
  local needsRebuild = false

  -- ── Direct terminal rendering helpers ────────────────────────
  -- We render content directly to the monitor to avoid Basalt
  -- internal state issues when rebuilding during event handling.

  local function setCursor(x, y)
    mon.setCursorPos(x, y)
  end

  local function writeColored(x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    mon.setTextColor(fg or COLORS.text)
    mon.setBackgroundColor(bg or COLORS.bg)
    mon.write(text)
  end

  local function clearContent()
    mon.setBackgroundColor(COLORS.bg)
    for row = TAB_H + 1, h do
      mon.setCursorPos(1, row)
      mon.write(string.rep(" ", w))
    end
  end

  -- Render a metric directly to monitor, returns next y
  local function renderMetricBar(y, m, sourceLabel, yMin, yMax)
    if y > yMax then return y end
    local MT = require("lib/metrics").TYPE

    local labelText = m.label
    if sourceLabel then labelText = labelText .. "  [" .. sourceLabel .. "]" end
    local valText = formatMetricValue(m)

    writeColored(2, y, labelText, COLORS.textLabel, COLORS.bg)
    writeColored(w - #valText, y, valText,
      warnIcon(m) ~= "" and COLORS.warn or COLORS.textDim, COLORS.bg)
    y = y + 1

    if m.type == MT.BAR and m.max and m.max > 0 and y <= yMax then
      local barW   = w - 2
      local filled = math.floor((m.value / m.max) * barW)
      filled       = math.max(0, math.min(barW, filled))
      local bar    = string.rep("\x8f", filled) .. string.rep("\x8c", barW - filled)
      writeColored(2, y, bar, barColor(m), COLORS.barBg)
      y = y + 1
    elseif m.type == MT.RATE then
      local col = m.direction == "in"  and COLORS.rateIn  or
                  m.direction == "out" and COLORS.rateOut or COLORS.rateNet
      writeColored(w - #valText, y - 1, valText, col, COLORS.bg)
    end

    return y + 1
  end

  local function renderDivider(y, label, yMax)
    if y > yMax then return y end
    local line
    if label and label ~= "" then
      line = "\x8c\x8c " .. label .. " " .. string.rep("\x8c", math.max(0, w - #label - 5))
    else
      line = string.rep("\x8c", w)
    end
    writeColored(1, y, line, COLORS.divider, COLORS.bg)
    return y + 1
  end

  -- ── Tab bar (Basalt) ─────────────────────────────────────────
  local monFrame = basalt.addMonitor(monitorName)
  monFrame:setBackground(COLORS.bgTab)

  local tabButtons = {}

  local function updateTabBar()
    -- Update button colors to reflect active tab
    for areaId, btn in pairs(tabButtons) do
      local isActive = areaId == activeArea
      btn:setForegroundColor(isActive and COLORS.text or COLORS.textDim)
      btn:setBackgroundColor(isActive and COLORS.bgTabActive or COLORS.bgTab)
    end
  end

  local x = 1
  for _, area in ipairs(areas) do
    local label = " " .. (area.label or area.id) .. " "
    local btn = monFrame:addButton()
      :setPosition(x, 1)
      :setSize(#label, 1)
      :setText(label)
      :setForegroundColor(area.id == activeArea and COLORS.text or COLORS.textDim)
      :setBackgroundColor(area.id == activeArea and COLORS.bgTabActive or COLORS.bgTab)

    local capturedId = area.id
    btn:onClick(function()
      activeArea = capturedId
      activeNode = nil
      scrollOffset[activeArea] = 0
      needsRebuild = true
    end)

    tabButtons[area.id] = btn
    x = x + #label + 1
  end

  -- ── Content renderer ─────────────────────────────────────────
  local function renderContent()
    clearContent()
    updateTabBar()

    local yMin   = TAB_H + 1
    local yMax   = h
    local viewKey = activeNode or activeArea or ""
    local offset  = scrollOffset[viewKey] or 0

    -- We render into a virtual buffer then slice by offset
    -- Simple approach: render all, clip to monitor height
    local y = yMin - offset

    local function vy(row) return row end  -- virtual y

    if activeArea == "me_network" then
      local ns     = server.getNodeState("me_network") or { metrics = {}, status = "offline" }
      local status = ns.status or "offline"

      if y >= yMin and y <= yMax then
        writeColored(2, y, "ME Network", COLORS.text, COLORS.bg)
        writeColored(w - 3, y, statusIcon(status), statusColor(status), COLORS.bg)
      end
      y = y + 2

      local meOrder = { "me_energy", "me_usage", "me_items", "me_fluids" }
      for _, id in ipairs(meOrder) do
        local m = ns.metrics and ns.metrics[id]
        if m then
          if y >= yMin then
            y = renderMetricBar(y, m, nil, yMin, yMax)
          else
            -- skip lines above scroll
            local skip = require("lib/metrics").TYPE
            local lines = (m.type == skip.BAR and m.max and m.max > 0) and 3 or 2
            y = y + lines
          end
        end
      end

      -- Watch items
      local watchItems = {}
      if ns.metrics then
        for id, m in pairs(ns.metrics) do
          if id:sub(1, 5) == "item_" then watchItems[#watchItems + 1] = m end
        end
      end

      if #watchItems > 0 then
        y = y + 1
        if y >= yMin and y <= yMax then y = renderDivider(y, "Watch Items", yMax)
        else y = y + 1 end
        y = y + 1

        table.sort(watchItems, function(a, b) return a.label < b.label end)
        for _, m in ipairs(watchItems) do
          if y >= yMin and y <= yMax then
            y = renderMetricBar(y, m, nil, yMin, yMax)
          else
            y = y + 3
          end
        end
      end

      -- Pinned
      local pinned = getPinnedFor("me_network", server)
      if #pinned > 0 then
        y = y + 1
        if y >= yMin and y <= yMax then y = renderDivider(y, "Pinned from nodes", yMax)
        else y = y + 1 end
        y = y + 1
        for _, p in ipairs(pinned) do
          if y >= yMin and y <= yMax then
            y = renderMetricBar(y, p.metric, p.sourceLabel, yMin, yMax)
          else
            y = y + 3
          end
        end
      end

    elseif activeNode then
      local idx     = server.getNodeIndex()
      local state   = server.getState()
      local nodeDef = idx[activeNode]
      local ns      = state[activeNode]

      if not nodeDef then
        writeColored(2, yMin, "Node not found: " .. activeNode, COLORS.crit, COLORS.bg)
        return
      end

      local status   = (ns and ns.status) or "offline"
      local disabled = status == "unreachable" or status == "offline"

      -- Back button rendered via Basalt would conflict, so render as text hint
      if y >= yMin and y <= yMax then
        writeColored(2, y, "[ < Back ]", COLORS.textDim, COLORS.bg)
        writeColored(14, y, statusIcon(status), statusColor(status), COLORS.bg)
        writeColored(16, y, nodeDef.label or activeNode, COLORS.text, COLORS.bg)
      end
      y = y + 2

      -- Controls
      local controls = nodeDef.controls or {}
      if #controls > 0 then
        if y >= yMin and y <= yMax then y = renderDivider(y, "Controls", yMax)
        else y = y + 1 end
        y = y + 1

        for _, control in ipairs(controls) do
          if y >= yMin and y <= yMax then
            local currentVal = ns and ns.controls and ns.controls[control.id] or false
            writeColored(2, y, control.label or control.id,
              disabled and COLORS.textDim or COLORS.textLabel, COLORS.bg)

            if control.type == "toggle" then
              local sliderText, sliderCol
              if disabled then
                sliderText = "[ .......... ]"
                sliderCol  = COLORS.sliderDis
              elseif currentVal then
                sliderText = "[ \x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 ON  ]"
                sliderCol  = COLORS.sliderOn
              else
                sliderText = "[ OFF \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"
                sliderCol  = COLORS.sliderOff
              end
              writeColored(18, y, sliderText, sliderCol, COLORS.bg)
            elseif control.type == "trigger" then
              local col = disabled and COLORS.sliderDis or
                          (control.color == "red" and COLORS.crit or colors.blue)
              writeColored(18, y, "[ TRIGGER ]", colors.white, col)
            end
          end
          y = y + 2
        end
      end

      -- Metrics
      local metricList = {}
      if ns and ns.metrics then
        for _, m in pairs(ns.metrics) do
          if m.type ~= require("lib/metrics").TYPE.TOGGLE then
            metricList[#metricList + 1] = m
          end
        end
      end

      if #metricList > 0 then
        y = y + 1
        if y >= yMin and y <= yMax then y = renderDivider(y, "Metrics", yMax)
        else y = y + 1 end
        y = y + 1
        for _, m in ipairs(metricList) do
          if y >= yMin then
            y = renderMetricBar(y, m, nil, yMin, yMax)
          else
            y = y + 3
          end
        end
      end

      -- Pinned in
      local targets = getPinnedTargets(nodeDef)
      if #targets > 0 then
        y = y + 1
        if y >= yMin and y <= yMax then y = renderDivider(y, "Pinned in", yMax)
        else y = y + 1 end
        y = y + 1
        local reg = server.getRegistry()
        for _, targetId in ipairs(targets) do
          local targetLabel = targetId
          for _, area in ipairs(reg.areas) do
            if area.id == targetId then targetLabel = area.label or targetId; break end
          end
          local pinnedHere = {}
          for _, pin in ipairs(nodeDef.pinMetrics or {}) do
            if pin.to == targetId then pinnedHere[#pinnedHere + 1] = pin.metricId end
          end
          if y >= yMin and y <= yMax then
            writeColored(2, y, targetLabel .. ": " .. table.concat(pinnedHere, ", "),
              COLORS.pinnedHdr, COLORS.bg)
          end
          y = y + 1
        end
      end

    else
      -- Area overview
      local area
      for _, a in ipairs(areas) do
        if a.id == activeArea then area = a; break end
      end

      if area then
        local state = server.getState()
        local idx   = server.getNodeIndex()

        if y >= yMin and y <= yMax then
          writeColored(w - 16, y, " All ON ", COLORS.text, COLORS.btnAllOn)
          writeColored(w - 7,  y, "All OFF ", COLORS.text, COLORS.btnAllOff)
        end
        y = y + 2

        if y >= yMin and y <= yMax then y = renderDivider(y, "Nodes", yMax)
        else y = y + 1 end
        y = y + 1

        for _, nodeId in ipairs(area.nodes or {}) do
          local nodeDef = idx[nodeId]
          local ns      = state[nodeId]
          if nodeDef then
            if y >= yMin and y <= yMax then
              local status = (ns and ns.status) or "offline"
              local label  = nodeDef.label or nodeId
              writeColored(2, y, statusIcon(status), statusColor(status), COLORS.bg)
              writeColored(4, y, label, COLORS.text, COLORS.bg)
              writeColored(w - 1, y, ">", COLORS.textDim, COLORS.bg)
            end
            y = y + 1
            if y >= yMin and y <= yMax then
              writeColored(2, y, string.rep("\x8c", w - 3), COLORS.bgPanel, COLORS.bg)
            end
            y = y + 1
          end
        end

        local pinned = getPinnedFor(area.id, server)
        if #pinned > 0 then
          y = y + 1
          if y >= yMin and y <= yMax then y = renderDivider(y, "Pinned", yMax)
          else y = y + 1 end
          y = y + 1
          for _, p in ipairs(pinned) do
            if y >= yMin then
              y = renderMetricBar(y, p.metric, p.sourceLabel, yMin, yMax)
            else
              y = y + 3
            end
          end
        end
      end
    end

    -- Scroll indicator
    if y - 1 > yMax then
      writeColored(w, yMax, "\x19", COLORS.textDim, COLORS.bg)
    end
    if offset > 0 then
      writeColored(w, yMin, "\x18", COLORS.textDim, COLORS.bg)
    end
  end

  -- ── Touch handler for content area ───────────────────────────
  -- We intercept monitor_touch events manually for content clicks
  local function handleTouch(mx, my)
    local yMin = TAB_H + 1

    -- Scroll arrows
    if mx == w and my == h then
      local viewKey = activeNode or activeArea or ""
      scrollOffset[viewKey] = (scrollOffset[viewKey] or 0) + 2
      needsRebuild = true
      return
    end
    if mx == w and my == yMin then
      local viewKey = activeNode or activeArea or ""
      scrollOffset[viewKey] = math.max(0, (scrollOffset[viewKey] or 0) - 2)
      needsRebuild = true
      return
    end

    if my < yMin then return end  -- tab bar handled by Basalt

    local offset  = scrollOffset[activeNode or activeArea or ""] or 0
    local virtualY = my + offset

    if activeNode then
      -- Back button on row yMin (virtual row yMin)
      if virtualY == yMin and mx <= 10 then
        activeNode = nil
        scrollOffset[activeArea] = scrollOffset[activeArea] or 0
        needsRebuild = true
        return
      end

      -- Toggle controls: find by position
      local idx     = server.getNodeIndex()
      local state   = server.getState()
      local nodeDef = idx[activeNode]
      local ns      = state[activeNode]
      if not nodeDef then return end

      local status   = (ns and ns.status) or "offline"
      local disabled = status == "unreachable" or status == "offline"
      if disabled then return end

      local scanY = yMin + 2  -- after header
      local controls = nodeDef.controls or {}
      if #controls > 0 then
        scanY = scanY + 2  -- divider + blank
        for _, control in ipairs(controls) do
          if virtualY == scanY and mx >= 18 then
            if control.type == "toggle" then
              local currentVal = ns and ns.controls and ns.controls[control.id] or false
              local ok, err = server.sendControl(activeNode, control.id, not currentVal)
              if not ok then print("[ui] Control failed: " .. tostring(err)) end
              needsRebuild = true
            elseif control.type == "trigger" then
              server.sendControl(activeNode, control.id, true)
            end
            return
          end
          scanY = scanY + 2
        end
      end

    elseif activeArea ~= "me_network" then
      -- Node list: each node takes 2 rows
      local area
      for _, a in ipairs(areas) do
        if a.id == activeArea then area = a; break end
      end
      if not area then return end

      local idx    = server.getNodeIndex()
      local scanY  = yMin + 4  -- header + divider + blank
      for _, nodeId in ipairs(area.nodes or {}) do
        local nodeDef = idx[nodeId]
        if nodeDef then
          if virtualY == scanY then
            activeNode = nodeId
            scrollOffset[nodeId] = scrollOffset[nodeId] or 0
            needsRebuild = true
            return
          end
          scanY = scanY + 2
        end
      end
    end
  end

  -- ── Main event loop ───────────────────────────────────────────
  renderContent()

  local function eventLoop()
    while true do
      local event, p1, p2, p3 = os.pullEvent()

      if event == "monitor_touch" and p1 == monitorName then
        if p3 >= TAB_H + 1 then  -- below tab bar
          handleTouch(p2, p3)
        end
        -- tab bar clicks handled by basalt.autoUpdate below

      elseif event == "timer" then
        -- periodic refresh
      end

      if needsRebuild then
        needsRebuild = false
        renderContent()
      end
    end
  end

  local function refreshLoop()
    while true do
      os.sleep(5)
      renderContent()
    end
  end

  -- autoUpdate handles tab bar clicks; eventLoop handles content clicks
  parallel.waitForAny(
    function() basalt.autoUpdate() end,
    eventLoop,
    refreshLoop
  )
end

return ui