-- client.lua
-- Generic Tower Control client.
-- All hardware config comes from node.cfg.
-- Node monitor uses native CC monitor API only - no frameworks.
local protocol = require("lib/protocol")
local metrics = require("lib/metrics")

-- ─────────────────────────────────────────
-- Config
-- ─────────────────────────────────────────
local VERSION = "0.1.0"
local CFG_FILE = "node.cfg"
local REPORT_EVERY = 10
local PING_EVERY = 30

local function loadConfig()
    assert(fs.exists(CFG_FILE), "[client] node.cfg not found. Run bootstrap.lua.")
    local f = fs.open(CFG_FILE, "r")
    local cfg = textutils.unserialiseJSON(f.readAll())
    f.close()
    assert(cfg.nodeId, "[client] node.cfg missing nodeId")
    assert(cfg.serverId, "[client] node.cfg missing serverId")
    return cfg
end

local cfg = loadConfig()

-- ─────────────────────────────────────────
-- Dynamic Control Handlers
-- ─────────────────────────────────────────
local handlers = {}

for _, control in ipairs(cfg.controls or {}) do
    local side = control.side
    local invert = control.invert or false

    if control.type == "toggle" then
        handlers[control.id] = function(value)
            redstone.setOutput(side, invert and not value or value)
        end

    elseif control.type == "trigger" then
        handlers[control.id] = function(_)
            redstone.setOutput(side, not invert)
            os.sleep(0.5)
            redstone.setOutput(side, invert)
        end
    end
end

-- ─────────────────────────────────────────
-- Metric Collection
-- ─────────────────────────────────────────
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
            local raw = redstone.getOutput(control.side)
            local logical = control.invert and not raw or raw
            result[#result + 1] = metrics.toggle(control.id, control.label, logical)
        end
    end

    return result
end

-- ─────────────────────────────────────────
-- Registration
-- ─────────────────────────────────────────
local function register()
    print("[client] Registering as " .. cfg.nodeId .. "...")
    local msg = protocol.msgRegister(cfg.nodeId)
    msg.label = cfg.label
    msg.area = cfg.area
    msg.nodeType = cfg.nodeType or "generic"
    msg.controls = cfg.controls
    msg.peripherals = cfg.peripherals

    local response = protocol.sendAndWait(cfg.serverId, msg, 10)
    if response and response.ok then
        print("[client] Registered.")
    else
        print("[client] No server response - will retry on next report.")
    end
end

-- ─────────────────────────────────────────
-- Message Handler
-- ─────────────────────────────────────────
local function handleMessage(senderId, msg)
    if not protocol.isValid(msg) then
        return
    end
    local A = protocol.ACTION

    if msg.action == A.SET then
        local handler = handlers[msg.capability]
        if handler then
            local ok, err = pcall(handler, msg.value)
            protocol.send(senderId, protocol.msgAck(cfg.nodeId, ok, ok and "ok" or tostring(err)))
        else
            protocol.send(senderId, protocol.msgAck(cfg.nodeId, false, "unknown: " .. tostring(msg.capability)))
        end

    elseif msg.action == A.QUERY then
        protocol.send(senderId, protocol.msgReport(cfg.nodeId, collectMetrics()))

    elseif msg.action == A.PING then
        protocol.send(senderId, protocol.msgPong(cfg.nodeId))

    elseif msg.action == A.UPDATE then
        print("[client] Update requested. Rebooting...")
        os.sleep(1)
        os.reboot()
    end
end

-- ─────────────────────────────────────────
-- Network Loop
-- ─────────────────────────────────────────
local function sendReport()
    protocol.send(cfg.serverId, protocol.msgReport(cfg.nodeId, collectMetrics()))
end

local function networkLoop()
    local lastReport = os.clock()
    local lastPing = os.clock()

    while true do
        local senderId, msg = protocol.receive(1)
        if senderId and msg then
            handleMessage(senderId, msg)
        end

        local now = os.clock()
        if now - lastReport >= REPORT_EVERY then
            sendReport();
            lastReport = now
        end
        if now - lastPing >= PING_EVERY then
            protocol.send(cfg.serverId, protocol.msgPing(cfg.nodeId))
            lastPing = now
        end
    end
end

-- ─────────────────────────────────────────
-- Node Monitor UI
-- Native CC monitor API. No frameworks.
-- ─────────────────────────────────────────
local function monitorLoop()
    local monSide = cfg.nodeMonitorSide
    if not monSide then
        return
    end

    local mon = peripheral.wrap(monSide)
    if not mon then
        print("[client] Monitor '" .. monSide .. "' not found.")
        return
    end

    mon.setTextScale(0.5)
    local W, H = mon.getSize()

    local C = {
        bg = colors.black,
        text = colors.white,
        dim = colors.lightGray,
        divider = colors.lightGray,
        on = colors.green,
        off = colors.red,
        dis = colors.gray,
        barFill = colors.lime,
        barWarn = colors.yellow,
        barCrit = colors.red,
        barBg = colors.gray,
        trigger = colors.blue,
        triggerR = colors.red
    }

    local function put(x, y, text, fg, bg)
        if y < 1 or y > H or x > W then
            return
        end
        local maxLen = W - x + 1
        if maxLen <= 0 then
            return
        end
        if #text > maxLen then
            text = text:sub(1, maxLen)
        end
        mon.setCursorPos(x, y)
        mon.setTextColor(fg or C.text)
        mon.setBackgroundColor(bg or C.bg)
        mon.write(text)
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

    -- Button registry for touch input
    local buttons = {}
    local function addBtn(x1, y1, x2, y2, action)
        buttons[#buttons + 1] = {
            x1 = x1,
            y1 = y1,
            x2 = x2,
            y2 = y2,
            action = action
        }
    end
    local function hitTest(mx, my)
        for _, b in ipairs(buttons) do
            if mx >= b.x1 and mx <= b.x2 and my >= b.y1 and my <= b.y2 then
                return b.action
            end
        end
    end

    local function render()
        mon.setBackgroundColor(C.bg)
        mon.clear()
        buttons = {}

        local y = 1
        local currentMetrics = collectMetrics()
        local MT = metrics.TYPE

        -- Header
        put(2, y, "*", C.on, C.bg)
        put(4, y, cfg.label or cfg.nodeId, C.text, C.bg)
        y = y + 2

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
                    local raw = redstone.getOutput(control.side)
                    local isOn = control.invert and not raw or raw
                    local sliderText = isOn and "[\x8c\x8c\x8c\x8c\x8c\x8c\x8c\x95 ON ]" or
                                           "[OFF \x95\x8c\x8c\x8c\x8c\x8c\x8c\x8c ]"
                    local sx = W - #sliderText
                    put(sx, y, sliderText, isOn and C.on or C.off, C.bg)

                    local cc = control
                    addBtn(sx, y, W, y, function()
                        local newVal = not (control.invert and not redstone.getOutput(cc.side) or
                                           redstone.getOutput(cc.side))
                        local handler = handlers[cc.id]
                        if handler then
                            pcall(handler, newVal)
                            protocol.send(cfg.serverId, {
                                action = protocol.ACTION.ACK,
                                nodeId = cfg.nodeId,
                                capability = cc.id,
                                value = newVal,
                                ok = true
                            })
                        end
                        render()
                    end)

                elseif control.type == "trigger" then
                    local trigLabel = "[ TRIGGER ]"
                    local bg = control.color == "red" and C.triggerR or C.trigger
                    local tx = W - #trigLabel
                    put(tx, y, trigLabel, colors.white, bg)
                    local cc = control
                    addBtn(tx, y, W, y, function()
                        local handler = handlers[cc.id]
                        if handler then
                            pcall(handler, true)
                        end
                    end)
                end

                y = y + 1
            end
            y = y + 1
        end

        put(1, y, string.rep("\x8c", W), C.divider, C.bg)
        y = y + 1

        -- Metrics
        local hasMetrics = false
        for _, m in ipairs(currentMetrics) do
            if m.type ~= MT.TOGGLE then
                hasMetrics = true

                local valStr
                if m.type == MT.BAR and m.max and m.max > 0 then
                    local pct = math.floor((m.value / m.max) * 100)
                    valStr = formatNum(m.value) .. "/" .. formatNum(m.max) .. " " .. (m.unit or "") .. " " .. pct .. "%"
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
                    local bw = W - 2
                    local filled = math.max(0, math.min(bw, math.floor((m.value / m.max) * bw)))
                    local bar = string.rep("\x8f", filled) .. string.rep("\x8c", bw - filled)
                    local st = metrics.status(m)
                    local fc = st == "crit" and C.barCrit or st == "warn" and C.barWarn or C.barFill
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

    render()

    local refreshTimer = os.startTimer(5)

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "monitor_touch" and p1 == monSide then
            local action = hitTest(p2, p3)
            if action then
                action()
            end

        elseif event == "timer" and p1 == refreshTimer then
            render()
            refreshTimer = os.startTimer(5)
        end
    end
end

-- ─────────────────────────────────────────
-- Main
-- ─────────────────────────────────────────
print("[client] Tower Control Client v" .. VERSION)
print("[client] Node: " .. cfg.nodeId .. " (\"" .. (cfg.label or "") .. "\")")
print("[client] Monitor: " .. (cfg.nodeMonitorSide or "none"))

protocol.open()
register()
sendReport()

parallel.waitForAny(networkLoop, monitorLoop)
