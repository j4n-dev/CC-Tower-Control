-- lib/ui.lua
-- Basalt-based UI for Tower Control System.
-- Requires Basalt: https://basalt.madefor.cc
-- Install: wget https://basalt.madefor.cc/install.lua run

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

  btnArea     = colors.blue,
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
  online      = "\x07",   -- bullet
  degraded    = "\x14",   -- half circle approximation
  unreachable = "\x09",   -- circle
  offline     = "\xd7",   -- X
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
  if st == "crit" then return COLORS.barCrit  end
  if st == "warn" then return COLORS.barWarn  end
  return COLORS.barNormal
end

local function warnIcon(m)
  local ms = require("lib/metrics")
  local st = ms.status(m)
  if st == "crit" then return " \x21" end  -- !
  if st == "warn" then return " \x21" end
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
    local arrow = m.direction == "in" and "\x18 " or
                  m.direction == "out" and "\x19 " or "~ "
    return arrow .. formatNum(m.value) .. " " .. (m.unit or "")
  elseif m.type == MT.VALUE then
    return formatNum(m.value) .. " " .. (m.unit or "") .. warnIcon(m)
  elseif m.type == MT.TOGGLE then
    return m.value and "AN" or "AUS"
  end
  return tostring(m.value)
end

-- ─────────────────────────────────────────
-- Pinned Metrics Resolution
-- ─────────────────────────────────────────

-- Returns list of { metric, sourceLabel } pinned TO a given area/node id
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

-- Returns list of target IDs this node pins metrics to
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
-- Render Helpers (Basalt frame builders)
-- ─────────────────────────────────────────

-- Draw a horizontal divider label
local function addDivider(frame, y, label)
  local w, _ = frame:getSize()
  local line
  if label and label ~= "" then
    local pad = string.rep("\x8c", 2)  -- horizontal line chars
    line = pad .. " " .. label .. " " .. string.rep("\x8c", w - #label - 5)
  else
    line = string.rep("\x8c", w)
  end
  frame:addLabel()
    :setPosition(1, y)
    :setText(line)
    :setForegroundColor(COLORS.divider)
  return y + 1
end

-- Draw a metric bar row (label line + bar line)
-- Returns next y position
local function addMetricBar(frame, y, m, sourceLabel)
  local w, _ = frame:getSize()
  local MT   = require("lib/metrics").TYPE

  -- Label line
  local labelText = m.label
  if sourceLabel then
    labelText = labelText .. "  \x5b" .. sourceLabel .. "\x5d"
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

  -- Bar (only for BAR type)
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
    -- Rate: colored arrow + value already shown above, just add spacing
    -- Color the value line based on direction
    local col = m.direction == "in"  and COLORS.rateIn  or
                m.direction == "out" and COLORS.rateOut or
                COLORS.rateNet
    -- Re-draw value with proper color (overwrite)
    frame:addLabel()
      :setPosition(w - #valText, y - 1)
      :setText(valText)
      :setForegroundColor(col)
  end

  return y + 1  -- spacing
end

-- Draw a toggle slider control
-- Returns next y position
local function addSlider(frame, y, control, currentValue, disabled, onToggle)
  local label   = control.label or control.id
  local isOn    = currentValue
  local slotW   = 14

  -- Label
  frame:addLabel()
    :setPosition(2, y)
    :setText(label)
    :setForegroundColor(disabled and COLORS.textDim or COLORS.textLabel)

  if disabled then
    -- Greyed out, not interactive
    frame:addLabel()
      :setPosition(20, y)
      :setText("\x5b \xc2\xc2\xc2\xc2\xc2\xc2\xc2\xc2\xc2\xc2 \x5d")
      :setForegroundColor(COLORS.sliderDis)
  else
    local sliderText, sliderCol
    if isOn then
      sliderText = "[ \x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 AN  ]"
      sliderCol  = COLORS.sliderOn
    else
      sliderText = "[ AUS \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"
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

-- Build area overview screen content into a scrollable frame
local function buildAreaScreen(scrollFrame, area, server, onNodeSelect)
  local w, _  = scrollFrame:getSize()
  local y     = 1
  local state = server.getState()
  local idx   = server.getNodeIndex()

  -- "Alle AN/AUS" buttons
  scrollFrame:addButton()
    :setPosition(w - 16, y)
    :setSize(8, 1)
    :setText(" Alle AN")
    :setForegroundColor(colors.white)
    :setBackgroundColor(COLORS.btnAllOn)
    :onClick(function()
      server.sendControlToArea(area.id, "power", true)
      server.sendControlToArea(area.id, "light", true)
    end)

  scrollFrame:addButton()
    :setPosition(w - 7, y)
    :setSize(8, 1)
    :setText("Alle AUS")
    :setForegroundColor(colors.white)
    :setBackgroundColor(COLORS.btnAllOff)
    :onClick(function()
      server.sendControlToArea(area.id, "power", false)
      server.sendControlToArea(area.id, "light", false)
    end)

  y = y + 2
  y = addDivider(scrollFrame, y, "Nodes")
  y = y + 1

  -- Node list
  for _, nodeId in ipairs(area.nodes or {}) do
    local nodeDef = idx[nodeId]
    local ns      = state[nodeId]
    if nodeDef then
      local status   = (ns and ns.status) or "offline"
      local icon     = statusIcon(status)
      local iconCol  = statusColor(status)
      local label    = nodeDef.label or nodeId

      -- Status icon
      scrollFrame:addLabel()
        :setPosition(2, y)
        :setText(icon)
        :setForegroundColor(iconCol)

      -- Node label as clickable button
      local btn = scrollFrame:addButton()
        :setPosition(4, y)
        :setSize(w - 6, 1)
        :setText(label .. string.rep(" ", w - 6 - #label - 1) .. ">")
        :setForegroundColor(COLORS.text)
        :setBackgroundColor(COLORS.bg)

      local capturedId = nodeId
      btn:onClick(function()
        if onNodeSelect then onNodeSelect(capturedId) end
      end)

      y = y + 1

      -- Divider between nodes
      scrollFrame:addLabel()
        :setPosition(2, y)
        :setText(string.rep("\x8c", w - 3))
        :setForegroundColor(COLORS.bgPanel)
      y = y + 1
    end
  end

  -- Pinned metrics section
  local pinned = getPinnedFor(area.id, server)
  if #pinned > 0 then
    y = y + 1
    y = addDivider(scrollFrame, y, "Eingeblendet")
    y = y + 1

    for _, p in ipairs(pinned) do
      y = addMetricBar(scrollFrame, y, p.metric, p.sourceLabel)
    end
  end

  -- Set scroll frame content height
  scrollFrame:setScrollable(true)
  scrollFrame:setHeight(math.max(y, 1))
end

-- Build node detail screen
local function buildDetailScreen(frame, nodeId, server, onBack)
  local w, h  = frame:getSize()
  local y     = 1
  local idx   = server.getNodeIndex()
  local state = server.getState()
  local nodeDef = idx[nodeId]
  local ns      = state[nodeId]

  if not nodeDef then
    frame:addLabel():setPosition(2,2):setText("Node not found: " .. nodeId)
    return
  end

  local status  = (ns and ns.status) or "offline"
  local disabled = status == "unreachable" or status == "offline"

  -- Back button
  frame:addButton()
    :setPosition(1, y)
    :setSize(10, 1)
    :setText("< Zuruck")
    :setForegroundColor(COLORS.text)
    :setBackgroundColor(COLORS.btnBack)
    :onClick(function()
      if onBack then onBack() end
    end)

  -- Status + label
  frame:addLabel()
    :setPosition(12, y)
    :setText(statusIcon(status))
    :setForegroundColor(statusColor(status))

  frame:addLabel()
    :setPosition(14, y)
    :setText(nodeDef.label or nodeId)
    :setForegroundColor(COLORS.text)

  y = y + 2

  -- Controls section
  local controls = nodeDef.controls or {}
  if #controls > 0 then
    y = addDivider(frame, y, "Controls")
    y = y + 1

    for _, control in ipairs(controls) do
      if control.type == "toggle" then
        local currentVal = false
        if ns and ns.controls then
          currentVal = ns.controls[control.id] or false
        end

        y = addSlider(frame, y, control, currentVal, disabled, function(capId, newVal)
          local ok, err = server.sendControl(nodeId, capId, newVal)
          if not ok then
            -- Could show error toast here in future
            print("[ui] Control failed: " .. tostring(err))
          end
        end)

      elseif control.type == "trigger" then
        frame:addLabel()
          :setPosition(2, y)
          :setText(control.label or control.id)
          :setForegroundColor(disabled and COLORS.textDim or COLORS.textLabel)

        if not disabled then
          local col = control.color == "red" and COLORS.crit or COLORS.btnArea
          local btn = frame:addButton()
            :setPosition(18, y)
            :setSize(12, 1)
            :setText("[ AUSLOESEN ]")
            :setForegroundColor(colors.white)
            :setBackgroundColor(col)

          local capturedId = control.id
          btn:onClick(function()
            server.sendControl(nodeId, capturedId, true)
          end)
        else
          frame:addLabel()
            :setPosition(18, y)
            :setText("[ .......... ]")
            :setForegroundColor(COLORS.sliderDis)
        end
        y = y + 2
      end
    end
  end

  -- Metrics section
  local metricList = {}
  if ns and ns.metrics then
    for _, m in pairs(ns.metrics) do
      -- Skip toggle metrics (already shown in controls)
      if m.type ~= require("lib/metrics").TYPE.TOGGLE then
        metricList[#metricList + 1] = m
      end
    end
  end

  if #metricList > 0 then
    y = y + 1
    y = addDivider(frame, y, "Metriken")
    y = y + 1

    for _, m in ipairs(metricList) do
      y = addMetricBar(frame, y, m, nil)
    end
  end

  -- "Gepinnt in" section
  local targets = getPinnedTargets(nodeDef)
  if #targets > 0 then
    y = y + 1
    y = addDivider(frame, y, "Gepinnt in")
    y = y + 1

    local reg = server.getRegistry()
    for _, targetId in ipairs(targets) do
      -- Find label for target
      local targetLabel = targetId
      for _, area in ipairs(reg.areas) do
        if area.id == targetId then
          targetLabel = area.label or targetId
          break
        end
      end
      for _, node in ipairs(reg.nodes) do
        if node.id == targetId then
          targetLabel = node.label or targetId
          break
        end
      end

      -- List which metrics are pinned there
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

-- Build ME Network screen
local function buildMEScreen(frame, server)
  local w, _   = frame:getSize()
  local y      = 1
  local ns     = server.getNodeState("me_network") or { metrics = {}, status = "offline" }
  local status = ns.status or "offline"

  -- Header with last-seen
  frame:addLabel()
    :setPosition(2, y)
    :setText("ME Network")
    :setForegroundColor(COLORS.text)

  frame:addLabel()
    :setPosition(w - 3, y)
    :setText(statusIcon(status))
    :setForegroundColor(statusColor(status))

  y = y + 2

  -- ME metrics
  local MT = require("lib/metrics").TYPE
  local meOrder = {
    "me_energy", "me_usage", "me_items", "me_fluids"
  }

  local shown = {}
  for _, id in ipairs(meOrder) do
    local m = ns.metrics and ns.metrics[id]
    if m then
      shown[id] = true
      y = addMetricBar(frame, y, m, nil)
    end
  end

  -- Watch items section
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

    -- Sort by label
    table.sort(watchItems, function(a, b) return a.label < b.label end)

    for _, m in ipairs(watchItems) do
      -- Compact single-line format for watch items
      local val     = formatNum(m.value)
      local warn    = warnIcon(m)
      local col     = warn ~= "" and COLORS.warn or COLORS.textDim
      local barW    = math.floor(w * 0.5)
      local thresh  = m.warnAt or 0
      local ratio   = thresh > 0 and math.min(1, m.value / thresh) or 0
      local filled  = math.floor(ratio * barW)
      local bar     = string.rep("\x8f", filled) ..
                      string.rep("\x8c", barW - filled)

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

  -- Pinned from other nodes
  local pinned = getPinnedFor("me_network", server)
  if #pinned > 0 then
    y = y + 1
    y = addDivider(frame, y, "Eingeblendet von anderen Nodes")
    y = y + 1

    for _, p in ipairs(pinned) do
      y = addMetricBar(frame, y, p.metric, p.sourceLabel)
    end
  end
end

-- ─────────────────────────────────────────
-- Tab Bar
-- ─────────────────────────────────────────
local function buildTabBar(basalt, monitor, areas, activeAreaId, onTabSelect)
  local w, _  = monitor:getSize()
  local tabBar = basalt.createFrame()
    :setMonitor(monitor)
    :setPosition(1, 1)
    :setSize(w, 1)
    :setBackground(COLORS.bgTab)

  local x = 1
  for _, area in ipairs(areas) do
    local label  = " " .. (area.label or area.id) .. " "
    local isActive = area.id == activeAreaId
    local btn = tabBar:addButton()
      :setPosition(x, 1)
      :setSize(#label, 1)
      :setText(label)
      :setForegroundColor(isActive and COLORS.text or COLORS.textDim)
      :setBackgroundColor(isActive and COLORS.bgTabActive or COLORS.bgTab)

    local capturedId = area.id
    btn:onClick(function()
      if onTabSelect then onTabSelect(capturedId) end
    end)

    x = x + #label + 1
  end

  return tabBar
end

-- ─────────────────────────────────────────
-- Main UI Entry Point
-- ─────────────────────────────────────────
function ui.run(server)
  -- Load Basalt
  local ok, basalt = pcall(require, "basalt")
  if not ok then
    error("[ui] Basalt not found. Install: wget https://basalt.madefor.cc/install.lua run")
  end

  local monitor = peripheral.find("monitor")
  if not monitor then
    error("[ui] No monitor found.")
  end
  monitor.setTextScale(0.5)

  local registry   = server.getRegistry()
  local areas      = registry.areas or {}
  local w, h       = monitor.getSize()

  -- State
  local activeArea = areas[1] and areas[1].id or nil
  local activeNode = nil  -- nil = area view, string = detail view

  -- Content frame (below tab bar)
  local TAB_H    = 2
  local contentH = h - TAB_H

  local function rebuild()
    -- Clear monitor
    monitor.setBackgroundColor(COLORS.bg)
    monitor.clear()

    -- Tab bar
    buildTabBar(basalt, monitor, areas, activeArea, function(areaId)
      activeArea = areaId
      activeNode = nil
      rebuild()
    end)

    -- Content frame
    local content = basalt.createFrame()
      :setMonitor(monitor)
      :setPosition(1, TAB_H + 1)
      :setSize(w, contentH)
      :setBackground(COLORS.bg)

    -- ME Network: own screen
    if activeArea == "me_network" then
      local scroll = content:addScrollableFrame()
        :setPosition(1, 1)
        :setSize(w, contentH)
        :setBackground(COLORS.bg)
      buildMEScreen(scroll, server)

    elseif activeNode then
      -- Node detail view
      buildDetailScreen(content, activeNode, server,
        function()
          activeNode = nil
          rebuild()
        end
      )

    else
      -- Area overview
      local area
      for _, a in ipairs(areas) do
        if a.id == activeArea then area = a; break end
      end

      if area then
        local scroll = content:addScrollableFrame()
          :setPosition(1, 1)
          :setSize(w, contentH)
          :setBackground(COLORS.bg)

        buildAreaScreen(scroll, area, server, function(nodeId)
          activeNode = nodeId
          rebuild()
        end)
      end
    end

    basalt.autoUpdate()
  end

  -- Auto-refresh every 5 seconds
  local function refreshLoop()
    while true do
      os.sleep(5)
      rebuild()
    end
  end

  -- Initial render
  rebuild()

  -- Run refresh in parallel with Basalt event loop
  parallel.waitForAny(
    function() basalt.autoUpdate() end,
    refreshLoop
  )
end

return ui
