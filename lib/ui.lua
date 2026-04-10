-- lib/ui.lua
-- Tower Control UI powered by Basalt UI framework.
-- Replaces raw CC monitor API with structured Basalt components.
--
-- Dependencies:
--   lib/basalt.lua  - Basalt UI framework (single-file distribution)
--   lib/metrics.lua - Metric type constants and status helpers
--
-- Entry point: ui.run(server)
--   server must expose: getRegistry(), getNodeIndex(), getState(), getNodeState(id),
--                       sendControl(nodeId, cap, val), sendControlToArea(areaId, cap, val),
--                       runNetworkLoop()

local ui = {}
local metrics = require("lib/metrics")


-- ── Colors ────────────────────────────────────────────────────────────────────

local C = {
  bg          = colors.black,
  text        = colors.white,
  dim         = colors.lightGray,
  divider     = colors.lightGray,
  panel       = colors.gray,

  tabBg       = colors.gray,
  tabActive   = colors.black,
  tabText     = colors.white,
  tabDim      = colors.lightGray,

  online      = colors.green,
  degraded    = colors.yellow,
  unreachable = colors.orange,
  offline     = colors.red,

  barFill     = colors.lime,
  barWarn     = colors.yellow,
  barCrit     = colors.red,
  barBg       = colors.gray,

  sliderOn    = colors.green,
  sliderOff   = colors.red,
  sliderDis   = colors.gray,

  btnAllOn    = colors.green,
  btnAllOff   = colors.red,
  btnBack     = colors.gray,
  btnTrigger  = colors.blue,
  btnTriggerR = colors.red,

  pinnedHdr   = colors.cyan,
  rateIn      = colors.lime,
  rateOut     = colors.red,
  warn        = colors.yellow,
}

local STATUS_ICON = {
  online      = "\x07",  -- bullet
  degraded    = "~",
  unreachable = "o",
  offline     = "x",
}

local STATUS_COLOR = {
  online      = C.online,
  degraded    = C.degraded,
  unreachable = C.unreachable,
  offline     = C.offline,
}


-- ── Pure helpers ──────────────────────────────────────────────────────────────

local function formatNum(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000)
  elseif n >= 1000 then return string.format("%.1fk", n / 1000)
  else return tostring(math.floor(n)) end
end

local function barColor(m)
  local st = metrics.status(m)
  if st == "crit" then return C.barCrit end
  if st == "warn" then return C.barWarn end
  return C.barFill
end

local function warnSuffix(m)
  local st = metrics.status(m)
  if st == "crit" or st == "warn" then return " !" end
  return ""
end

local function metricValueStr(m)
  local MT = metrics.TYPE
  if m.type == MT.BAR then
    local pct = m.max > 0 and math.floor((m.value / m.max) * 100) or 0
    return formatNum(m.value) .. "/" .. formatNum(m.max) .. " " .. (m.unit or "") .. " " .. pct .. "%" .. warnSuffix(m)
  elseif m.type == MT.RATE then
    local arrow = m.direction == "in" and "+" or m.direction == "out" and "-" or "~"
    return arrow .. formatNum(m.value) .. " " .. (m.unit or "")
  elseif m.type == MT.VALUE then
    return formatNum(m.value) .. " " .. (m.unit or "") .. warnSuffix(m)
  elseif m.type == MT.TOGGLE then
    return m.value and "ON" or "OFF"
  end
  return tostring(m.value)
end

local function getPinnedFor(targetId, server)
  local result = {}
  for _, node in ipairs(server.getRegistry().nodes) do
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
  local targets, seen = {}, {}
  for _, pin in ipairs(nodeDef.pinMetrics or {}) do
    if not seen[pin.to] then
      targets[#targets + 1] = pin.to
      seen[pin.to] = true
    end
  end
  return targets
end

local function loadVersion()
  if not fs.exists("version") then return "?" end
  local f = fs.open("version", "r")
  local v = f.readAll():match("^%s*(.-)%s*$")
  f.close()
  return v
end

local function fmtTime()
  local t = os.time("local")
  return string.format("%02d:%02d", math.floor(t), math.floor((t % 1) * 60))
end

local function fmtDate()
  local d = os.date("*t")
  if d then return string.format("%02d.%02d.%04d", d.day, d.month, d.year) end
  return ""
end


-- ── Basalt component builders ─────────────────────────────────────────────────

-- Adds a horizontal divider label to parent at (1, y) spanning W chars.
local function addDivider(parent, W, y, label)
  local lbl = parent:addLabel()
  lbl:setPosition(1, y)
  lbl:setBackground(C.bg)
  if label and label ~= "" then
    local left  = "\x8c\x8c "
    local right = " " .. string.rep("\x8c", math.max(1, W - #label - #left - 1))
    lbl:setText(left .. label .. right)
  else
    lbl:setText(string.rep("\x8c", W))
  end
  lbl:setForeground(C.divider)
  return lbl
end

-- Adds a metric display block to parent starting at y.
-- Layout: name label (left) + value label (right), optional Progressbar below.
-- Returns the next y position after this block (includes a blank gap line).
local function addMetricBlock(parent, W, y, m, sourceLabel)
  local MT  = metrics.TYPE
  local val = metricValueStr(m)
  local lbl = m.label
  if sourceLabel then lbl = lbl .. " [" .. sourceLabel .. "]" end

  -- Truncate label if it would overlap the value
  local maxNameLen = W - #val - 3
  if #lbl > maxNameLen then lbl = lbl:sub(1, maxNameLen) end

  local nameLbl = parent:addLabel()
  nameLbl:setPosition(2, y)
  nameLbl:setForeground(C.text)
  nameLbl:setBackground(C.bg)
  nameLbl:setText(lbl)

  local valFg = (warnSuffix(m) ~= "") and C.warn or C.dim
  if m.type == MT.RATE then
    valFg = m.direction == "in" and C.rateIn or
            m.direction == "out" and C.rateOut or C.dim
  end

  local valLbl = parent:addLabel()
  valLbl:setPosition(W - #val + 1, y)
  valLbl:setForeground(valFg)
  valLbl:setBackground(C.bg)
  valLbl:setText(val)

  y = y + 1

  if m.type == MT.BAR and m.max and m.max > 0 then
    local pct = math.max(0, math.min(100, math.floor((m.value / m.max) * 100)))
    -- Basalt Progressbar: setSize sets the bar width, setValue sets 0-100 fill
    local bar = parent:addProgressbar()
    bar:setPosition(2, y)
    bar:setSize(W - 2, 1)
    bar:setValue(pct)
    bar:setForeground(barColor(m))
    bar:setBackground(C.barBg)
    y = y + 1
  end

  return y + 1  -- blank gap between metrics
end


-- ── View builders ─────────────────────────────────────────────────────────────

-- Populates a Scrollable content frame with the area overview.
--   onNodeSelect(nodeId) : called when a node row is clicked
--   addAction(fn)        : queues a blocking fn for background dispatch
local function buildAreaView(content, W, area, server, onNodeSelect, addAction)
  local state = server.getState()
  local idx   = server.getNodeIndex()
  local y = 1

  -- All ON / All OFF row-buttons
  local onLabel  = " All ON "
  local offLabel = " All OFF"
  local onX      = W - #onLabel - #offLabel + 1
  local aId      = area.id

  local onBtn = content:addButton()
  onBtn:setPosition(onX, y)
  onBtn:setSize(#onLabel, 1)
  onBtn:setText(onLabel)
  onBtn:setBackground(C.btnAllOn)
  onBtn:setForeground(colors.white)
  onBtn:setActiveBackground(C.btnAllOn)
  onBtn:setActiveForeground(colors.lightGray)
  onBtn:onClick(function()
    addAction(function()
      server.sendControlToArea(aId, "power", true)
      server.sendControlToArea(aId, "light", true)
    end)
  end)

  local offBtn = content:addButton()
  offBtn:setPosition(onX + #onLabel, y)
  offBtn:setSize(#offLabel, 1)
  offBtn:setText(offLabel)
  offBtn:setBackground(C.btnAllOff)
  offBtn:setForeground(colors.white)
  offBtn:setActiveBackground(C.btnAllOff)
  offBtn:setActiveForeground(colors.lightGray)
  offBtn:onClick(function()
    addAction(function()
      server.sendControlToArea(aId, "power", false)
      server.sendControlToArea(aId, "light", false)
    end)
  end)
  y = y + 2

  addDivider(content, W, y, "Nodes")
  y = y + 1

  for _, nodeId in ipairs(area.nodes or {}) do
    local nodeDef = idx[nodeId]
    local ns      = state[nodeId]
    if nodeDef then
      local status = (ns and ns.status) or "offline"
      local label  = nodeDef.label or nodeId

      -- Status icon: 1-char, colored, non-clickable (col 2)
      local iconLbl = content:addLabel()
      iconLbl:setPosition(2, y)
      iconLbl:setText(STATUS_ICON[status] or "?")
      iconLbl:setForeground(STATUS_COLOR[status] or C.dim)
      iconLbl:setBackground(C.bg)

      -- Node name + ">" arrow as a clickable button spanning cols 4..W
      -- Avoid overdraw: button is placed after icon label at col 4
      local capturedId = nodeId
      local rowBtn = content:addButton()
      rowBtn:setPosition(4, y)
      rowBtn:setSize(W - 3, 1)
      -- Pad label to fill button width, with ">" at far right
      local padded = label .. string.rep(" ", math.max(0, W - 4 - #label)) .. ">"
      rowBtn:setText(padded)
      rowBtn:setBackground(C.bg)
      rowBtn:setForeground(C.text)
      rowBtn:setActiveBackground(C.panel)
      rowBtn:setActiveForeground(C.text)
      rowBtn:onClick(function() onNodeSelect(capturedId) end)

      -- Separator line below node row
      local sep = content:addLabel()
      sep:setPosition(2, y + 1)
      sep:setText(string.rep("\x8c", W - 2))
      sep:setForeground(C.panel)
      sep:setBackground(C.bg)
      y = y + 2
    end
  end

  -- Pinned metrics at bottom of area view
  local pinned = getPinnedFor(area.id, server)
  if #pinned > 0 then
    y = y + 1
    addDivider(content, W, y, "Pinned")
    y = y + 1
    for _, p in ipairs(pinned) do
      y = addMetricBlock(content, W, y, p.metric, p.sourceLabel)
    end
  end
end

-- Populates a Scrollable content frame with the node detail view.
--   onBack()    : called when the Back button is clicked
--   addAction() : queues a blocking action for background dispatch
local function buildDetailView(content, W, nodeId, server, onBack, addAction)
  local idx   = server.getNodeIndex()
  local state = server.getState()
  local nodeDef = idx[nodeId]
  local ns      = state[nodeId]
  local y = 1

  if not nodeDef then
    local errLbl = content:addLabel()
    errLbl:setPosition(2, y)
    errLbl:setText("Node not found: " .. tostring(nodeId))
    errLbl:setForeground(C.warn)
    errLbl:setBackground(C.bg)
    return
  end

  local status   = (ns and ns.status) or "offline"
  local disabled = (status == "unreachable" or status == "offline")

  -- Back button + node status icon + node name
  local backBtn = content:addButton()
  backBtn:setPosition(1, y)
  backBtn:setSize(8, 1)
  backBtn:setText(" < Back ")
  backBtn:setBackground(C.btnBack)
  backBtn:setForeground(C.text)
  backBtn:setActiveBackground(colors.lightGray)
  backBtn:setActiveForeground(C.text)
  backBtn:onClick(onBack)

  local sIconLbl = content:addLabel()
  sIconLbl:setPosition(10, y)
  sIconLbl:setText(STATUS_ICON[status] or "?")
  sIconLbl:setForeground(STATUS_COLOR[status] or C.dim)
  sIconLbl:setBackground(C.bg)

  local nodeNameLbl = content:addLabel()
  nodeNameLbl:setPosition(12, y)
  nodeNameLbl:setText(nodeDef.label or nodeId)
  nodeNameLbl:setForeground(C.text)
  nodeNameLbl:setBackground(C.bg)
  y = y + 2

  -- Controls section
  local controls = nodeDef.controls or {}
  if #controls > 0 then
    addDivider(content, W, y, "Controls")
    y = y + 1

    for _, control in ipairs(controls) do
      -- Control label (left-aligned)
      local ctrlLbl = content:addLabel()
      ctrlLbl:setPosition(2, y)
      ctrlLbl:setText(control.label or control.id)
      ctrlLbl:setForeground(disabled and C.sliderDis or C.text)
      ctrlLbl:setBackground(C.bg)

      if control.type == "toggle" then
        local val = (ns and ns.controls and ns.controls[control.id]) or false
        local sliderText, sliderFg

        if disabled then
          sliderText = "[ ............ ]"
          sliderFg   = C.sliderDis
        elseif val then
          sliderText = "[ \x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 ON  ]"
          sliderFg   = C.sliderOn
        else
          sliderText = "[ OFF \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"
          sliderFg   = C.sliderOff
        end

        local sx = W - #sliderText + 1

        if disabled then
          -- Non-clickable disabled state
          local disLbl = content:addLabel()
          disLbl:setPosition(sx, y)
          disLbl:setText(sliderText)
          disLbl:setForeground(sliderFg)
          disLbl:setBackground(C.bg)
        else
          -- Clickable slider button — dispatches via pending queue to avoid blocking onClick
          local capturedControl = control
          local capturedVal     = val
          local sliderBtn = content:addButton()
          sliderBtn:setPosition(sx, y)
          sliderBtn:setSize(#sliderText, 1)
          sliderBtn:setText(sliderText)
          sliderBtn:setBackground(C.bg)
          sliderBtn:setForeground(sliderFg)
          sliderBtn:setActiveBackground(C.bg)
          sliderBtn:setActiveForeground(colors.lightGray)
          sliderBtn:onClick(function()
            addAction(function()
              local ok, err = server.sendControl(nodeId, capturedControl.id, not capturedVal)
              if not ok then print("[ui] Control error: " .. tostring(err)) end
            end)
          end)
        end

      elseif control.type == "trigger" then
        if disabled then
          local disLbl = content:addLabel()
          disLbl:setPosition(W - 12, y)
          disLbl:setText("[ ......... ]")
          disLbl:setForeground(C.sliderDis)
          disLbl:setBackground(C.bg)
        else
          local trigLabel = "[ TRIGGER ]"
          local trigBg    = control.color == "red" and C.btnTriggerR or C.btnTrigger
          local tx        = W - #trigLabel + 1
          local capturedControl = control
          local trigBtn = content:addButton()
          trigBtn:setPosition(tx, y)
          trigBtn:setSize(#trigLabel, 1)
          trigBtn:setText(trigLabel)
          trigBtn:setBackground(trigBg)
          trigBtn:setForeground(colors.white)
          trigBtn:setActiveBackground(trigBg)
          trigBtn:setActiveForeground(colors.lightGray)
          trigBtn:onClick(function()
            addAction(function()
              server.sendControl(nodeId, capturedControl.id, true)
            end)
          end)
        end
      end

      y = y + 2
    end
  end

  -- Metrics section (skip TOGGLE type — already shown via controls)
  local metricList = {}
  if ns and ns.metrics then
    for _, m in pairs(ns.metrics) do
      if m.type ~= metrics.TYPE.TOGGLE then
        metricList[#metricList + 1] = m
      end
    end
  end

  if #metricList > 0 then
    y = y + 1
    addDivider(content, W, y, "Metrics")
    y = y + 1
    for _, m in ipairs(metricList) do
      y = addMetricBlock(content, W, y, m, nil)
    end
  end

  -- "Pinned in" section — shows which areas this node's metrics are pinned to
  local targets = getPinnedTargets(nodeDef)
  if #targets > 0 then
    y = y + 1
    addDivider(content, W, y, "Pinned in")
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
      local pinLbl = content:addLabel()
      pinLbl:setPosition(2, y)
      pinLbl:setText(targetLabel .. ": " .. table.concat(pinnedHere, ", "))
      pinLbl:setForeground(C.pinnedHdr)
      pinLbl:setBackground(C.bg)
      y = y + 1
    end
  end
end

-- Populates a Scrollable content frame with the ME Network overview.
local function buildMEView(content, W, server)
  local ns     = server.getNodeState("me_network") or { metrics = {}, status = "offline" }
  local status = ns.status or "offline"
  local y = 1

  local titleLbl = content:addLabel()
  titleLbl:setPosition(2, y)
  titleLbl:setText("ME Network")
  titleLbl:setForeground(C.text)
  titleLbl:setBackground(C.bg)

  local statusLbl = content:addLabel()
  statusLbl:setPosition(W - 1, y)
  statusLbl:setText(STATUS_ICON[status] or "?")
  statusLbl:setForeground(STATUS_COLOR[status] or C.dim)
  statusLbl:setBackground(C.bg)
  y = y + 2

  -- Core ME metrics in a fixed display order
  for _, id in ipairs({"me_energy", "me_usage", "me_items", "me_fluids"}) do
    local m = ns.metrics and ns.metrics[id]
    if m then y = addMetricBlock(content, W, y, m, nil) end
  end

  -- Watch items (sorted alphabetically)
  local watchItems = {}
  if ns.metrics then
    for id, m in pairs(ns.metrics) do
      if id:sub(1, 5) == "item_" then watchItems[#watchItems + 1] = m end
    end
  end
  if #watchItems > 0 then
    y = y + 1
    addDivider(content, W, y, "Watch Items")
    y = y + 1
    table.sort(watchItems, function(a, b) return a.label < b.label end)
    for _, m in ipairs(watchItems) do
      y = addMetricBlock(content, W, y, m, nil)
    end
  end

  -- Pinned metrics from other nodes
  local pinned = getPinnedFor("me_network", server)
  if #pinned > 0 then
    y = y + 1
    addDivider(content, W, y, "Pinned from nodes")
    y = y + 1
    for _, p in ipairs(pinned) do
      y = addMetricBlock(content, W, y, p.metric, p.sourceLabel)
    end
  end
end


-- ── Entry point ───────────────────────────────────────────────────────────────

function ui.run(server)
  -- Find the monitor peripheral
  local monName
  for _, side in ipairs({"top", "bottom", "left", "right", "front", "back"}) do
    if peripheral.getType(side) == "monitor" then
      monName = side; break
    end
  end
  if not monName then
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == "monitor" then
        monName = name; break
      end
    end
  end
  if not monName then
    print("[ui] No monitor found – running headless.")
    -- Fall back to running network loop without a UI
    server.runNetworkLoop()
    return
  end

  -- Configure text scale before Basalt reads monitor dimensions.
  -- Scale 0.5 gives the highest text resolution on advanced monitors.
  local mon = peripheral.wrap(monName)
  mon.setTextScale(0.5)
  local W, H = mon.getSize()

  local basalt = require("basalt")

  -- Create Basalt monitor display rooted on this monitor
  local display = basalt.addMonitor()
  display:setMonitor(monName)
  display:setBackground(C.bg)

  -- Register the server's network loop as a Basalt-managed thread.
  -- Basalt's cooperative scheduler distributes all os.pullEvent results to
  -- every registered thread, so the network loop receives modem_message
  -- events without conflicting with Basalt's own event dispatch.
  basalt.addThread(server.runNetworkLoop)


  -- ── Fixed layout: header (row 1) ──────────────────────────────────────────

  local headerFrame = display:addFrame()
  headerFrame:setPosition(1, 1)
  headerFrame:setSize(W, 1)
  headerFrame:setBackground(C.tabBg)

  -- Background fill for header (ensure full-width color)
  local headerBg = headerFrame:addLabel()
  headerBg:setPosition(1, 1)
  headerBg:setText(string.rep(" ", W))
  headerBg:setBackground(C.tabBg)
  headerBg:setForeground(C.tabBg)

  local titleLbl = headerFrame:addLabel()
  titleLbl:setPosition(2, 1)
  titleLbl:setText("City Control Center v" .. loadVersion())
  titleLbl:setForeground(C.text)
  titleLbl:setBackground(C.tabBg)

  local initTime = fmtTime() .. "  " .. fmtDate()
  local timeLbl = headerFrame:addLabel()
  timeLbl:setPosition(W - #initTime + 1, 1)
  timeLbl:setText(initTime)
  timeLbl:setForeground(C.tabDim)
  timeLbl:setBackground(C.tabBg)


  -- ── Fixed layout: tab bar (row 2) ─────────────────────────────────────────

  local tabFrame = display:addFrame()
  tabFrame:setPosition(1, 2)
  tabFrame:setSize(W, 1)
  tabFrame:setBackground(C.tabBg)

  -- Background fill
  local tabBgLbl = tabFrame:addLabel()
  tabBgLbl:setPosition(1, 1)
  tabBgLbl:setText(string.rep(" ", W))
  tabBgLbl:setBackground(C.tabBg)
  tabBgLbl:setForeground(C.tabBg)


  -- ── Fixed layout: divider (row 3) ─────────────────────────────────────────

  local divFrame = display:addFrame()
  divFrame:setPosition(1, 3)
  divFrame:setSize(W, 1)
  divFrame:setBackground(C.bg)

  local divLbl = divFrame:addLabel()
  divLbl:setPosition(1, 1)
  divLbl:setText(string.rep("\x8c", W))
  divLbl:setForeground(C.divider)
  divLbl:setBackground(C.bg)


  -- ── Scrollable content frame (rows 4..H) ──────────────────────────────────
  -- Basalt's ScrollableFrame manages a virtual canvas that extends beyond the
  -- visible area; scrolling is handled natively via touch-drag or scroll buttons.
  --
  -- Note: If your Basalt version uses a different method name (e.g. addFrame with
  -- scroll enabled), adjust the method call here accordingly.
  local content = display:addScrollableFrame()
  content:setPosition(1, 4)
  content:setSize(W, H - 3)
  content:setBackground(C.bg)


  -- ── View state ────────────────────────────────────────────────────────────

  local registry = server.getRegistry()
  local areas    = registry.areas or {}

  -- Full area list with ME Network as the last tab
  local allAreas = {}
  for _, a in ipairs(areas) do allAreas[#allAreas + 1] = a end
  allAreas[#allAreas + 1] = { id = "me_network", label = "ME Network" }

  local activeArea = allAreas[1] and allAreas[1].id or nil
  local activeNode = nil

  -- Pending actions queue: control commands are dispatched off the main
  -- event coroutine to avoid blocking Basalt's event loop during sendAndWait.
  local pendingActions = {}
  local needsRefresh   = false

  local function addAction(fn)
    pendingActions[#pendingActions + 1] = fn
  end

  -- Tab button references keyed by area.id for highlight management
  local tabButtons = {}

  -- Forward declaration needed because switchView is mutually recursive
  local switchView


  -- ── Tab bar population ────────────────────────────────────────────────────

  local function buildTabBar()
    tabFrame:removeChildren()
    tabButtons = {}

    -- Re-add background fill after removeChildren
    local bg = tabFrame:addLabel()
    bg:setPosition(1, 1)
    bg:setText(string.rep(" ", W))
    bg:setBackground(C.tabBg)
    bg:setForeground(C.tabBg)

    local tx = 1
    for _, area in ipairs(allAreas) do
      local label    = " " .. (area.label or area.id) .. " "
      local isActive = (area.id == activeArea) and (activeNode == nil)

      local tabBtn = tabFrame:addButton()
      tabBtn:setPosition(tx, 1)
      tabBtn:setSize(#label, 1)
      tabBtn:setText(label)
      tabBtn:setBackground(isActive and C.tabActive or C.tabBg)
      tabBtn:setForeground(isActive and C.tabText or C.tabDim)
      tabBtn:setActiveBackground(isActive and C.tabActive or C.tabBg)
      tabBtn:setActiveForeground(C.tabText)

      local capturedId = area.id
      tabBtn:onClick(function()
        switchView(capturedId, nil)
      end)

      tabButtons[area.id] = tabBtn
      tx = tx + #label + 1
    end
  end


  -- ── View switcher ─────────────────────────────────────────────────────────

  switchView = function(areaId, nodeId)
    activeArea = areaId or activeArea
    activeNode = nodeId

    -- Update tab highlight: active tab is the area tab when not in node detail
    for id, btn in pairs(tabButtons) do
      local isActive = (id == activeArea) and (activeNode == nil)
      btn:setBackground(isActive and C.tabActive or C.tabBg)
      btn:setForeground(isActive and C.tabText or C.tabDim)
      btn:setActiveBackground(isActive and C.tabActive or C.tabBg)
    end

    -- Clear content and rebuild for the active view.
    -- removeChildren() also resets the Scrollable's scroll position.
    content:removeChildren()

    if activeNode then
      buildDetailView(content, W, activeNode, server,
        function() switchView(activeArea, nil) end,
        addAction)

    elseif activeArea == "me_network" then
      buildMEView(content, W, server)

    else
      local area
      for _, a in ipairs(areas) do
        if a.id == activeArea then area = a; break end
      end
      if area then
        buildAreaView(content, W, area, server,
          function(nId) switchView(activeArea, nId) end,
          addAction)
      end
    end
  end


  -- ── Initial render ────────────────────────────────────────────────────────

  buildTabBar()
  switchView(activeArea, nil)


  -- ── Background threads ────────────────────────────────────────────────────

  -- Time label updater: updates every 1s without a full re-render
  basalt.addThread(function()
    while true do
      os.sleep(1)
      local ts = fmtTime() .. "  " .. fmtDate()
      timeLbl:setPosition(W - #ts + 1, 1)
      timeLbl:setText(ts)
    end
  end)

  -- Auto-refresh trigger: marks the view dirty every 5s so network state
  -- changes (node status, metrics) are reflected without user interaction
  basalt.addThread(function()
    while true do
      os.sleep(5)
      needsRefresh = true
    end
  end)

  -- Action dispatcher + refresh applicator.
  -- Processes one queued control action per tick (each action may block up to 5s
  -- for sendAndWait), then applies any pending refresh.
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
        switchView(activeArea, activeNode)
      end
    end
  end)


  -- Start Basalt's event loop. This call blocks forever and distributes
  -- all CC:T events to Basalt components and registered threads.
  basalt.autoUpdate()
end

return ui
