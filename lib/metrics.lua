-- lib/metrics.lua
-- Metric type definitions and collection helpers.
-- Clients use this to build their report payloads.
-- Server uses the type info to render correctly.

local metrics = {}

-- ─────────────────────────────────────────
-- Metric Types
-- ─────────────────────────────────────────
-- bar    → value + max, rendered as progressbar
--          optional: warnAt (0.0–1.0 ratio), critAt
-- rate   → value with direction (in/out/net), colored arrow
-- value  → plain number, optional warnAt / critAt (absolute)
-- toggle → boolean, shown as ON/OFF indicator

metrics.TYPE = {
  BAR    = "bar",
  RATE   = "rate",
  VALUE  = "value",
  TOGGLE = "toggle",
}

-- ─────────────────────────────────────────
-- Metric Constructors
-- ─────────────────────────────────────────

---@param id string
---@param label string
---@param value number
---@param max number
---@param unit string
---@param opts table|nil  { warnAt, critAt }
function metrics.bar(id, label, value, max, unit, opts)
  opts = opts or {}
  return {
    id     = id,
    label  = label,
    value  = value,
    max    = max,
    unit   = unit,
    type   = metrics.TYPE.BAR,
    warnAt = opts.warnAt,  -- ratio, e.g. 0.85
    critAt = opts.critAt,  -- ratio, e.g. 0.95
  }
end

---@param id string
---@param label string
---@param value number
---@param unit string
---@param direction string  "in" | "out" | "net"
function metrics.rate(id, label, value, unit, direction)
  return {
    id        = id,
    label     = label,
    value     = value,
    unit      = unit,
    type      = metrics.TYPE.RATE,
    direction = direction,  -- "in" = green ↑, "out" = red ↓, "net" = neutral
  }
end

---@param id string
---@param label string
---@param value number
---@param unit string
---@param opts table|nil  { warnAt, critAt }  absolute values
function metrics.value(id, label, value, unit, opts)
  opts = opts or {}
  return {
    id     = id,
    label  = label,
    value  = value,
    unit   = unit,
    type   = metrics.TYPE.VALUE,
    warnAt = opts.warnAt,
    critAt = opts.critAt,
  }
end

---@param id string
---@param label string
---@param value boolean
function metrics.toggle(id, label, value)
  return {
    id    = id,
    label = label,
    value = value,
    type  = metrics.TYPE.TOGGLE,
  }
end

-- ─────────────────────────────────────────
-- Peripheral Collectors
-- Wrap these in pcall on the client – peripherals may not exist.
-- ─────────────────────────────────────────

--- Collect Forge Energy metrics from a wrapped peripheral.
--- Works with Mekanism, Powah, Bigger Reactors, etc.
---@param p table  peripheral.wrap() result
---@param prefix string  e.g. "fe" or "reactor"
---@return table[]
function metrics.collectFE(p, prefix)
  prefix = prefix or "fe"
  local result = {}

  local ok, stored  = pcall(function() return p.getEnergy() end)
  local ok2, max    = pcall(function() return p.getMaxEnergy() end)
  local ok3, input  = pcall(function() return p.getEnergyNeeded and p.getLastInput and p.getLastInput() end)
  local ok4, output = pcall(function() return p.getLastOutput and p.getLastOutput() end)

  if ok and ok2 and stored and max then
    result[#result+1] = metrics.bar(
      prefix .. "_stored", "FE Stored", stored, max, "FE",
      { warnAt = 0.1, critAt = 0.05 }  -- warn when getting LOW
    )
  end

  if ok3 and input then
    result[#result+1] = metrics.rate(prefix .. "_input", "FE Input", input, "FE/t", "in")
  end

  if ok4 and output then
    result[#result+1] = metrics.rate(prefix .. "_output", "FE Output", output, "FE/t", "out")
  end

  return result
end

--- Collect Create stress / SU metrics.
--- Requires CC:C Bridge or Create: Crafts & Additions.
---@param p table  peripheral.wrap() result
---@return table[]
function metrics.collectCreate(p)
  local result = {}

  local ok1, stress   = pcall(function() return p.getStress() end)
  local ok2, capacity = pcall(function() return p.getStressCapacity() end)

  if ok1 and ok2 and stress and capacity then
    result[#result+1] = metrics.bar(
      "su_stress", "SU Stress", stress, capacity, "SU",
      { warnAt = 0.75, critAt = 0.9 }
    )
  end

  return result
end

--- Collect AE2 / ME network metrics via Advanced Peripherals ME Bridge.
---@param p table  peripheral.wrap() result
---@return table[]
function metrics.collectME(p)
  local result = {}

  local function try(fn) local ok, v = pcall(fn); return ok and v or nil end

  local energy    = try(function() return p.getEnergyStorage() end)
  local maxEnergy = try(function() return p.getMaxEnergyStorage() end)
  local usage     = try(function() return p.getEnergyUsage() end)
  local items     = try(function() return p.getUsedItemStorage() end)
  local maxItems  = try(function() return p.getTotalItemStorage() end)
  local fluids    = try(function() return p.getUsedFluidStorage() end)
  local maxFluids = try(function() return p.getTotalFluidStorage() end)

  if energy and maxEnergy then
    result[#result+1] = metrics.bar(
      "me_energy", "ME Energy", energy, maxEnergy, "AE",
      { warnAt = 0.1 }
    )
  end

  if usage then
    result[#result+1] = metrics.rate("me_usage", "ME Usage", usage, "AE/t", "out")
  end

  if items and maxItems then
    result[#result+1] = metrics.bar(
      "me_items", "Item Storage", items, maxItems, "slots",
      { warnAt = 0.85, critAt = 0.95 }
    )
  end

  if fluids and maxFluids then
    result[#result+1] = metrics.bar(
      "me_fluids", "Fluid Storage", fluids, maxFluids, "mB",
      { warnAt = 0.85, critAt = 0.95 }
    )
  end

  return result
end

-- ─────────────────────────────────────────
-- Utility
-- ─────────────────────────────────────────

--- Merge multiple metric arrays into one.
function metrics.merge(...)
  local result = {}
  for _, list in ipairs({...}) do
    for _, m in ipairs(list) do
      result[#result+1] = m
    end
  end
  return result
end

--- Check if a metric is in warning or critical state.
--- Returns: "ok" | "warn" | "crit"
---@param m table  metric object
---@return string
function metrics.status(m)
  if m.type == metrics.TYPE.BAR and m.max and m.max > 0 then
    local ratio = m.value / m.max
    if m.critAt and ratio <= m.critAt then return "crit" end
    if m.warnAt and ratio <= m.warnAt then return "warn" end

  elseif m.type == metrics.TYPE.VALUE then
    if m.critAt and m.value >= m.critAt then return "crit" end
    if m.warnAt and m.value >= m.warnAt then return "warn" end
  end

  return "ok"
end

return metrics
