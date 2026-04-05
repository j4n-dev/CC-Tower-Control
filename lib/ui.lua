-- lib/ui.lua
-- Tower Control UI using native CC monitor API only.
-- No external frameworks.
--
-- Monitor API used:
--   mon.setTextScale(scale)
--   mon.getSize()             -> w, h
--   mon.clear()
--   mon.setCursorPos(x, y)
--   mon.setTextColor(color)
--   mon.setBackgroundColor(color)
--   mon.write(text)
-- Input via os.pullEvent("monitor_touch") -> side, x, y

local ui = {}

-- ─────────────────────────────────────────
-- Colors
-- ─────────────────────────────────────────
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
  online      = "\x07",
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

-- ─────────────────────────────────────────
-- Draw helpers
-- ─────────────────────────────────────────
local mon, W, H

local function put(x, y, text, fg, bg)
  if y < 1 or y > H or x > W then return end
  if x < 1 then
    text = text:sub(1 - x + 1)
    x = 1
  end
  local maxLen = W - x + 1
  if maxLen <= 0 or #text == 0 then return end
  if #text > maxLen then text = text:sub(1, maxLen) end
  mon.setCursorPos(x, y)
  mon.setTextColor(fg or C.text)
  mon.setBackgroundColor(bg or C.bg)
  mon.write(text)
end

local function fillLine(y, fg, bg)
  put(1, y, string.rep(" ", W), fg, bg)
end

local function divider(y, label)
  if label and label ~= "" then
    local left  = "\x8c\x8c "
    local right = " " .. string.rep("\x8c", math.max(1, W - #label - #left - 1))
    put(1, y, left .. label .. right, C.divider, C.bg)
  else
    put(1, y, string.rep("\x8c", W), C.divider, C.bg)
  end
end

local function formatNum(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000)
  elseif n >= 1000 then return string.format("%.1fk", n / 1000)
  else return tostring(math.floor(n)) end
end

local function barColor(m)
  local ms = require("lib/metrics")
  local st = ms.status(m)
  if st == "crit" then return C.barCrit end
  if st == "warn" then return C.barWarn end
  return C.barFill
end

local function warnSuffix(m)
  local ms = require("lib/metrics")
  local st = ms.status(m)
  if st == "crit" or st == "warn" then return " !" end
  return ""
end

local function metricValueStr(m)
  local MT = require("lib/metrics").TYPE
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

-- Draw one metric block. Returns next y.
local function drawMetric(y, m, sourceLabel)
  if y > H then return y end
  local MT  = require("lib/metrics").TYPE
  local val = metricValueStr(m)

  local label = m.label
  if sourceLabel then label = label .. " [" .. sourceLabel .. "]" end

  -- Label left, value right
  put(2, y, label, C.text, C.bg)
  put(W - #val, y, val,
    (warnSuffix(m) ~= "") and C.warn or C.dim, C.bg)
  y = y + 1

  if m.type == MT.BAR and m.max and m.max > 0 then
    local bw     = W - 2
    local filled = math.max(0, math.min(bw, math.floor((m.value / m.max) * bw)))
    local bar    = string.rep("\x8f", filled) .. string.rep("\x8c", bw - filled)
    put(2, y, bar, barColor(m), C.barBg)
    y = y + 1
  elseif m.type == MT.RATE then
    local col = m.direction == "in" and C.rateIn or
                m.direction == "out" and C.rateOut or C.dim
    put(W - #val, y - 1, val, col, C.bg)
  end

  return y + 1  -- blank line between metrics
end

-- ─────────────────────────────────────────
-- Button registry
-- Clickable regions stored per render cycle.
-- ─────────────────────────────────────────
local buttons = {}  -- { x1, y1, x2, y2, action }

local function addButton(x1, y1, x2, y2, action)
  buttons[#buttons + 1] = { x1=x1, y1=y1, x2=x2, y2=y2, action=action }
end

local function hitTest(mx, my)
  for _, b in ipairs(buttons) do
    if mx >= b.x1 and mx <= b.x2 and my >= b.y1 and my <= b.y2 then
      return b.action
    end
  end
  return nil
end

-- ─────────────────────────────────────────
-- Pinned metrics helpers
-- ─────────────────────────────────────────
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

-- ─────────────────────────────────────────
-- Screen renderers
-- Each returns the next unused y row.
-- ─────────────────────────────────────────

local function drawAreaScreen(y, area, server, state, idx)
  -- All ON / All OFF buttons
  local onLabel  = " All ON "
  local offLabel = " All OFF"
  local onX      = W - #onLabel - #offLabel
  put(onX, y, onLabel, colors.white, C.btnAllOn)
  addButton(onX, y, onX + #onLabel - 1, y, function()
    server.sendControlToArea(area.id, "power", true)
    server.sendControlToArea(area.id, "light", true)
  end)
  put(onX + #onLabel, y, offLabel, colors.white, C.btnAllOff)
  addButton(onX + #onLabel, y, W, y, function()
    server.sendControlToArea(area.id, "power", false)
    server.sendControlToArea(area.id, "light", false)
  end)
  y = y + 2

  divider(y, "Nodes")
  y = y + 1

  for _, nodeId in ipairs(area.nodes or {}) do
    local nodeDef = idx[nodeId]
    local ns      = state[nodeId]
    if nodeDef then
      local status = (ns and ns.status) or "offline"
      local icon   = STATUS_ICON[status] or "?"
      local label  = nodeDef.label or nodeId

      put(2, y, icon, STATUS_COLOR[status] or C.dim, C.bg)
      put(4, y, label, C.text, C.bg)
      put(W, y, ">", C.dim, C.bg)

      local capturedId = nodeId
      addButton(1, y, W, y, function() return "node:" .. capturedId end)

      y = y + 1
      put(2, y, string.rep("\x8c", W - 2), C.panel, C.bg)
      y = y + 1
    end
  end

  local pinned = getPinnedFor(area.id, server)
  if #pinned > 0 then
    y = y + 1
    divider(y, "Pinned")
    y = y + 1
    for _, p in ipairs(pinned) do
      y = drawMetric(y, p.metric, p.sourceLabel)
    end
  end

  return y
end

local function drawDetailScreen(y, nodeId, server, state, idx)
  local nodeDef  = idx[nodeId]
  local ns       = state[nodeId]

  if not nodeDef then
    put(2, y, "Node not found: " .. nodeId, C.warn, C.bg)
    return y + 1
  end

  local status   = (ns and ns.status) or "offline"
  local disabled = status == "unreachable" or status == "offline"

  -- Back button
  local backLabel = "< Back"
  put(1, y, " " .. backLabel .. " ", C.text, C.btnBack)
  addButton(1, y, #backLabel + 2, y, function() return "back" end)
  put(#backLabel + 4, y, STATUS_ICON[status] or "?", STATUS_COLOR[status] or C.dim, C.bg)
  put(#backLabel + 6, y, nodeDef.label or nodeId, C.text, C.bg)
  y = y + 2

  -- Controls
  local controls = nodeDef.controls or {}
  if #controls > 0 then
    divider(y, "Controls")
    y = y + 1

    for _, control in ipairs(controls) do
      put(2, y, control.label or control.id,
        disabled and C.sliderDis or C.text, C.bg)

      if control.type == "toggle" then
        local val = ns and ns.controls and ns.controls[control.id] or false
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

        local sx = W - #sliderText
        put(sx, y, sliderText, sliderFg, C.bg)

        if not disabled then
          local capturedControl = control
          local capturedVal     = val
          addButton(sx, y, W, y, function()
            local ok, err = server.sendControl(nodeId, capturedControl.id, not capturedVal)
            if not ok then print("[ui] Control error: " .. tostring(err)) end
            return "refresh"
          end)
        end

      elseif control.type == "trigger" then
        if not disabled then
          local trigLabel = "[ TRIGGER ]"
          local trigBg    = control.color == "red" and C.btnTriggerR or C.btnTrigger
          local tx        = W - #trigLabel
          put(tx, y, trigLabel, colors.white, trigBg)

          local capturedControl = control
          addButton(tx, y, W, y, function()
            server.sendControl(nodeId, capturedControl.id, true)
            return "refresh"
          end)
        else
          put(W - 11, y, "[ ......... ]", C.sliderDis, C.bg)
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
    divider(y, "Metrics")
    y = y + 1
    for _, m in ipairs(metricList) do
      y = drawMetric(y, m, nil)
    end
  end

  -- Pinned in
  local targets = getPinnedTargets(nodeDef)
  if #targets > 0 then
    y = y + 1
    divider(y, "Pinned in")
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
      put(2, y, targetLabel .. ": " .. table.concat(pinnedHere, ", "), C.pinnedHdr, C.bg)
      y = y + 1
    end
  end

  return y
end

local function drawMEScreen(y, server)
  local ns     = server.getNodeState("me_network") or { metrics = {}, status = "offline" }
  local status = ns.status or "offline"

  put(2, y, "ME Network", C.text, C.bg)
  put(W - 1, y, STATUS_ICON[status] or "?", STATUS_COLOR[status] or C.dim, C.bg)
  y = y + 2

  local meOrder = { "me_energy", "me_usage", "me_items", "me_fluids" }
  for _, id in ipairs(meOrder) do
    local m = ns.metrics and ns.metrics[id]
    if m then y = drawMetric(y, m, nil) end
  end

  local watchItems = {}
  if ns.metrics then
    for id, m in pairs(ns.metrics) do
      if id:sub(1, 5) == "item_" then watchItems[#watchItems + 1] = m end
    end
  end

  if #watchItems > 0 then
    y = y + 1
    divider(y, "Watch Items")
    y = y + 1
    table.sort(watchItems, function(a, b) return a.label < b.label end)
    for _, m in ipairs(watchItems) do
      y = drawMetric(y, m, nil)
    end
  end

  local pinned = getPinnedFor("me_network", server)
  if #pinned > 0 then
    y = y + 1
    divider(y, "Pinned from nodes")
    y = y + 1
    for _, p in ipairs(pinned) do
      y = drawMetric(y, p.metric, p.sourceLabel)
    end
  end

  return y
end

-- ─────────────────────────────────────────
-- Main render
-- ─────────────────────────────────────────
local function render(server, areas, activeArea, activeNode, scrollY)
  mon.setBackgroundColor(C.bg)
  mon.clear()
  buttons = {}

  -- Tab bar (row 1)
  fillLine(1, C.tabDim, C.tabBg)
  local tx = 1
  for _, area in ipairs(areas) do
    local label    = " " .. (area.label or area.id) .. " "
    local isActive = area.id == activeArea
    put(tx, 1, label,
      isActive and C.tabText or C.tabDim,
      isActive and C.tabActive or C.tabBg)
    local capturedId = area.id
    addButton(tx, 1, tx + #label - 1, 1, function() return "tab:" .. capturedId end)
    tx = tx + #label + 1
  end

  -- Divider row 2
  put(1, 2, string.rep("\x8c", W), C.divider, C.bg)

  -- Content starts at row 3, offset by scroll
  local contentStart = 3
  local state        = server.getState()
  local idx          = server.getNodeIndex()

  -- We render to a virtual surface by offsetting y
  local function vy(y) return y - scrollY + contentStart - 1 end

  -- Override put to apply scroll offset
  local origPut = put
  local function sput(x, y, text, fg, bg)
    origPut(x, vy(y), text, fg, bg)
  end
  local function sdivider(y, label)
    local sy = vy(y)
    if sy < contentStart or sy > H then return end
    divider(sy, label)
  end
  local function sdrawMetric(y, m, sourceLabel)
    -- Adjust y for scroll, skip if off screen
    local MT = require("lib/metrics").TYPE
    local lines = (m.type == MT.BAR and m.max and m.max > 0) and 3 or 2
    if vy(y + lines - 1) < contentStart then return y + lines end
    if vy(y) > H then return y + lines end

    local val   = metricValueStr(m)
    local label = m.label
    if sourceLabel then label = label .. " [" .. sourceLabel .. "]" end

    local sy = vy(y)
    if sy >= contentStart and sy <= H then
      origPut(2, sy, label, C.text, C.bg)
      origPut(W - #val, sy, val,
        (warnSuffix(m) ~= "") and C.warn or C.dim, C.bg)
    end

    if m.type == MT.BAR and m.max and m.max > 0 then
      local bw     = W - 2
      local filled = math.max(0, math.min(bw, math.floor((m.value / m.max) * bw)))
      local bar    = string.rep("\x8f", filled) .. string.rep("\x8c", bw - filled)
      local sby    = vy(y + 1)
      if sby >= contentStart and sby <= H then
        origPut(2, sby, bar, barColor(m), C.barBg)
      end
      return y + 3
    elseif m.type == MT.RATE then
      local col = m.direction == "in" and C.rateIn or
                  m.direction == "out" and C.rateOut or C.dim
      local sy2 = vy(y)
      if sy2 >= contentStart and sy2 <= H then
        origPut(W - #val, sy2, val, col, C.bg)
      end
    end
    return y + 2
  end

  -- Scroll-aware button registration
  local function saddButton(x1, y1, x2, y2, action)
    addButton(x1, vy(y1), x2, vy(y2), action)
  end

  -- Render content
  local y = 1  -- virtual y (before scroll)

  if activeArea == "me_network" then
    local ns     = server.getNodeState("me_network") or { metrics = {}, status = "offline" }
    local status = ns.status or "offline"

    do local sy = vy(y); if sy >= contentStart and sy <= H then
      origPut(2, sy, "ME Network", C.text, C.bg)
      origPut(W - 1, sy, STATUS_ICON[status] or "?", STATUS_COLOR[status] or C.dim, C.bg)
    end end
    y = y + 2

    for _, id in ipairs({ "me_energy", "me_usage", "me_items", "me_fluids" }) do
      local m = ns.metrics and ns.metrics[id]
      if m then y = sdrawMetric(y, m, nil) end
    end

    local watchItems = {}
    if ns.metrics then
      for id, m in pairs(ns.metrics) do
        if id:sub(1, 5) == "item_" then watchItems[#watchItems + 1] = m end
      end
    end
    if #watchItems > 0 then
      y = y + 1
      do local sy = vy(y); if sy >= contentStart and sy <= H then sdivider(y, "Watch Items") end end
      y = y + 1
      table.sort(watchItems, function(a, b) return a.label < b.label end)
      for _, m in ipairs(watchItems) do y = sdrawMetric(y, m, nil) end
    end

    local pinned = getPinnedFor("me_network", server)
    if #pinned > 0 then
      y = y + 1
      do local sy = vy(y); if sy >= contentStart and sy <= H then sdivider(y, "Pinned from nodes") end end
      y = y + 1
      for _, p in ipairs(pinned) do y = sdrawMetric(y, p.metric, p.sourceLabel) end
    end

  elseif activeNode then
    local nodeDef  = idx[activeNode]
    local ns       = state[activeNode]

    if not nodeDef then
      do local sy = vy(y); if sy >= contentStart and sy <= H then
        origPut(2, sy, "Node not found: " .. activeNode, C.warn, C.bg)
      end end
      return y + 1
    end

    local status   = (ns and ns.status) or "offline"
    local disabled = status == "unreachable" or status == "offline"

    -- Back button
    local backLabel = " < Back "
    do local sy = vy(y); if sy >= contentStart and sy <= H then
      origPut(1, sy, backLabel, C.text, C.btnBack)
      origPut(#backLabel + 2, sy, STATUS_ICON[status] or "?", STATUS_COLOR[status] or C.dim, C.bg)
      origPut(#backLabel + 4, sy, nodeDef.label or activeNode, C.text, C.bg)
    end end
    saddButton(1, y, #backLabel, y, function() return "back" end)
    y = y + 2

    local controls = nodeDef.controls or {}
    if #controls > 0 then
      do local sy = vy(y); if sy >= contentStart and sy <= H then sdivider(y, "Controls") end end
      y = y + 1

      for _, control in ipairs(controls) do
        do local sy = vy(y); if sy >= contentStart and sy <= H then
          origPut(2, sy, control.label or control.id,
            disabled and C.sliderDis or C.text, C.bg)

          if control.type == "toggle" then
            local val = ns and ns.controls and ns.controls[control.id] or false
            local sliderText, sliderFg
            if disabled then
              sliderText = "[ ............ ]"; sliderFg = C.sliderDis
            elseif val then
              sliderText = "[ \x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 ON  ]"; sliderFg = C.sliderOn
            else
              sliderText = "[ OFF \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"; sliderFg = C.sliderOff
            end
            local sx = W - #sliderText
            origPut(sx, sy, sliderText, sliderFg, C.bg)
            if not disabled then
              local cc, cv = control, val
              saddButton(sx, y, W, y, function()
                local ok, err = server.sendControl(activeNode, cc.id, not cv)
                if not ok then print("[ui] " .. tostring(err)) end
                return "refresh"
              end)
            end

          elseif control.type == "trigger" then
            if not disabled then
              local trigLabel = "[ TRIGGER ]"
              local trigBg    = control.color == "red" and C.btnTriggerR or C.btnTrigger
              local tx2       = W - #trigLabel
              origPut(tx2, sy, trigLabel, colors.white, trigBg)
              local cc = control
              saddButton(tx2, y, W, y, function()
                server.sendControl(activeNode, cc.id, true)
                return "refresh"
              end)
            else
              origPut(W - 11, sy, "[ ......... ]", C.sliderDis, C.bg)
            end
          end
        end end
        y = y + 2
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
      do local sy = vy(y); if sy >= contentStart and sy <= H then sdivider(y, "Metrics") end end
      y = y + 1
      for _, m in ipairs(metricList) do y = sdrawMetric(y, m, nil) end
    end

    local targets = getPinnedTargets(nodeDef)
    if #targets > 0 then
      y = y + 1
      do local sy = vy(y); if sy >= contentStart and sy <= H then sdivider(y, "Pinned in") end end
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
        do local sy = vy(y); if sy >= contentStart and sy <= H then
          origPut(2, sy, targetLabel .. ": " .. table.concat(pinnedHere, ", "), C.pinnedHdr, C.bg)
        end end
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
      -- All ON / OFF
      local onLabel  = " All ON "
      local offLabel = " All OFF"
      local onX      = W - #onLabel - #offLabel + 1
      do local sy = vy(y); if sy >= contentStart and sy <= H then
        origPut(onX, sy, onLabel, colors.white, C.btnAllOn)
        origPut(onX + #onLabel, sy, offLabel, colors.white, C.btnAllOff)
      end end
      saddButton(onX, y, onX + #onLabel - 1, y, function()
        server.sendControlToArea(area.id, "power", true)
        server.sendControlToArea(area.id, "light", true)
        return "refresh"
      end)
      saddButton(onX + #onLabel, y, W, y, function()
        server.sendControlToArea(area.id, "power", false)
        server.sendControlToArea(area.id, "light", false)
        return "refresh"
      end)
      y = y + 2

      do local sy = vy(y); if sy >= contentStart and sy <= H then sdivider(y, "Nodes") end end
      y = y + 1

      for _, nodeId in ipairs(area.nodes or {}) do
        local nodeDef = idx[nodeId]
        local ns      = state[nodeId]
        if nodeDef then
          local status = (ns and ns.status) or "offline"
          local label  = nodeDef.label or nodeId
          do local sy = vy(y); if sy >= contentStart and sy <= H then
            origPut(2, sy, STATUS_ICON[status] or "?", STATUS_COLOR[status] or C.dim, C.bg)
            origPut(4, sy, label, C.text, C.bg)
            origPut(W, sy, ">", C.dim, C.bg)
          end end
          local capturedId = nodeId
          saddButton(1, y, W, y, function() return "node:" .. capturedId end)
          y = y + 1

          do local sy = vy(y); if sy >= contentStart and sy <= H then
            origPut(2, sy, string.rep("\x8c", W - 2), C.panel, C.bg)
          end end
          y = y + 1
        end
      end

      local pinned = getPinnedFor(area.id, server)
      if #pinned > 0 then
        y = y + 1
        do local sy = vy(y); if sy >= contentStart and sy <= H then sdivider(y, "Pinned") end end
        y = y + 1
        for _, p in ipairs(pinned) do y = sdrawMetric(y, p.metric, p.sourceLabel) end
      end
    end
  end

  -- Scroll indicators
  local totalVirtual = y - 1
  if scrollY > 0 then
    origPut(W, contentStart, "\x18", C.dim, C.bg)
    addButton(W, contentStart, W, contentStart, function() return "scroll:-3" end)
  end
  if totalVirtual > (H - contentStart + 1 + scrollY) then
    origPut(W, H, "\x19", C.dim, C.bg)
    addButton(W, H, W, H, function() return "scroll:3" end)
  end
end

-- ─────────────────────────────────────────
-- Entry point
-- ─────────────────────────────────────────
function ui.run(server)
  local monName = nil
  for _, side in ipairs({"top","bottom","left","right","front","back"}) do
    if peripheral.getType(side) == "monitor" then
      monName = side; break
    end
  end
  if not monName then
    -- Try wired peripherals
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == "monitor" then
        monName = name; break
      end
    end
  end
  if not monName then
    print("[ui] No monitor found – running headless.")
    while true do os.sleep(60) end
  end

  mon = peripheral.wrap(monName)
  mon.setTextScale(0.5)
  W, H = mon.getSize()

  local registry   = server.getRegistry()
  local areas      = registry.areas or {}
  local activeArea = areas[1] and areas[1].id or nil
  local activeNode = nil
  local scrollY    = 0  -- virtual rows scrolled past top

  local function doRender()
    render(server, areas, activeArea, activeNode, scrollY)
  end

  local function handleAction(action)
    if not action then return end
    if action:sub(1, 4) == "tab:" then
      activeArea = action:sub(5)
      activeNode = nil
      scrollY    = 0
      doRender()
    elseif action:sub(1, 5) == "node:" then
      activeNode = action:sub(6)
      scrollY    = 0
      doRender()
    elseif action == "back" then
      activeNode = nil
      scrollY    = 0
      doRender()
    elseif action == "refresh" then
      doRender()
    elseif action:sub(1, 7) == "scroll:" then
      local delta = tonumber(action:sub(8)) or 0
      scrollY = math.max(0, scrollY + delta)
      doRender()
    end
  end

  doRender()

  local refreshTimer = os.startTimer(5)

  while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "monitor_touch" and p1 == monName then
      local action = hitTest(p2, p3)
      if type(action) == "function" then
        local result = action()
        handleAction(result)
      else
        handleAction(action)
      end

    elseif event == "timer" and p1 == refreshTimer then
      doRender()
      refreshTimer = os.startTimer(5)
    end
  end
end

return ui