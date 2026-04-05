-- server.lua
-- Master Control Server for Tower Control System.
-- Handles auto-discovery, node status tracking, ME polling,
-- control commands, and drives the monitor UI.
local protocol = require("lib/protocol")
local metrics = require("lib/metrics")


-- Constants

local VERSION = "0.1.0"
local REGISTRY_FILE = "registry.json"
local CONFIG_FILE = "config.json"

local STATUS = {
    ONLINE = "online",
    DEGRADED = "degraded",
    UNREACHABLE = "unreachable",
    OFFLINE = "offline"
}


-- Config

local function loadConfig()
    if not fs.exists(CONFIG_FILE) then
        return {
            reportInterval = 10,
            degradedAfter = 1,
            unreachableAfter = 3,
            offlineAfter = 5
        }
    end
    local f = fs.open(CONFIG_FILE, "r")
    local cfg = textutils.unserialiseJSON(f.readAll())
    f.close()
    return cfg
end

local config = loadConfig()

local function getThresholds(nodeDef)
    local interval = (nodeDef and nodeDef.reportInterval) or config.reportInterval
    return {
        interval = interval,
        degraded = interval * config.degradedAfter,
        unreachable = interval * config.unreachableAfter,
        offline = interval * config.offlineAfter
    }
end


-- Registry

local function loadRegistry()
    if not fs.exists(REGISTRY_FILE) then
        return {
            areas = {},
            nodes = {},
            watchItems = {}
        }
    end
    local f = fs.open(REGISTRY_FILE, "r")
    local reg = textutils.unserialiseJSON(f.readAll())
    f.close()
    reg.areas = reg.areas or {}
    reg.nodes = reg.nodes or {}
    reg.watchItems = reg.watchItems or {}
    return reg
end

local function saveRegistry(reg)
    local f = fs.open(REGISTRY_FILE, "w")
    f.write(textutils.serialiseJSON(reg))
    f.close()
end

local registry = loadRegistry()

local function buildNodeIndex(reg)
    local idx = {}
    for _, node in ipairs(reg.nodes) do
        idx[node.id] = node
    end
    return idx
end

local nodeIndex = buildNodeIndex(registry)


-- Auto-Discovery

local function findOrCreateNode(nodeId, computerId, regMsg)
    if nodeIndex[nodeId] then
        nodeIndex[nodeId].computerId = computerId
        return nodeIndex[nodeId]
    end

    local nodeDef = {
        id = nodeId,
        label = regMsg.label or nodeId,
        area = regMsg.area or "unassigned",
        type = regMsg.nodeType or "generic",
        computerId = computerId,
        controls = regMsg.controls or {},
        peripherals = regMsg.peripherals or {},
        pinMetrics = regMsg.pinMetrics or {}
    }

    registry.nodes[#registry.nodes + 1] = nodeDef
    nodeIndex[nodeId] = nodeDef

    local areaFound = false
    for _, area in ipairs(registry.areas) do
        if area.id == nodeDef.area then
            area.nodes[#area.nodes + 1] = nodeId
            areaFound = true
            break
        end
    end
    if not areaFound then
        registry.areas[#registry.areas + 1] = {
            id = nodeDef.area,
            label = nodeDef.area,
            nodes = {nodeId}
        }
    end

    saveRegistry(registry)
    print("[server] Auto-registered: " .. nodeId .. " (\"" .. nodeDef.label .. "\", area: " .. nodeDef.area .. ")")

    return nodeDef
end


-- Runtime State

local state = {}

local function ensureNodeState(nodeId, computerId)
    if not state[nodeId] then
        state[nodeId] = {
            computerId = computerId,
            status = STATUS.OFFLINE,
            lastSeen = 0,
            pingPending = false,
            metrics = {},
            controls = {}
        }
    end
    if computerId then
        state[nodeId].computerId = computerId
    end
    return state[nodeId]
end

local function markSeen(nodeId, computerId)
    local s = ensureNodeState(nodeId, computerId)
    s.lastSeen = os.epoch("utc")
    s.status = STATUS.ONLINE
    s.pingPending = false
end

local function updateMetrics(nodeId, metricList)
    local s = ensureNodeState(nodeId, nil)
    for _, m in ipairs(metricList) do
        s.metrics[m.id] = m
    end
end


-- Status Watchdog

local function runWatchdog()
    local nowMs = os.epoch("utc")

    for nodeId, s in pairs(state) do
        if s.status ~= STATUS.OFFLINE then
            local nodeDef = nodeIndex[nodeId]
            local thresh = getThresholds(nodeDef)
            local elapsed = (nowMs - s.lastSeen) / 1000

            if elapsed >= thresh.offline then
                if s.status ~= STATUS.OFFLINE then
                    s.status = STATUS.OFFLINE
                    s.pingPending = false
                    print("[server] OFFLINE: " .. nodeId)
                end

            elseif elapsed >= thresh.unreachable then
                if s.status ~= STATUS.UNREACHABLE then
                    s.status = STATUS.UNREACHABLE
                    s.pingPending = false
                    print("[server] UNREACHABLE: " .. nodeId)
                end

            elseif elapsed >= thresh.degraded then
                if s.status == STATUS.ONLINE then
                    s.status = STATUS.DEGRADED
                    print("[server] DEGRADED: " .. nodeId .. " - pinging...")
                    if s.computerId then
                        protocol.send(s.computerId, protocol.msgPing(nil))
                        s.pingPending = true
                    end
                end
            end
        end
    end
end


-- ME Bridge Polling

local meBridge = peripheral.find("meBridge")

local function pollME()
    if not meBridge then
        return
    end

    local meMetrics = metrics.collectME(meBridge)
    updateMetrics("me_network", meMetrics)

    for _, item in ipairs(registry.watchItems or {}) do
        local ok, data = pcall(function()
            return meBridge.getItem({
                name = item.name
            })
        end)
        if ok and data then
            updateMetrics("me_network", {metrics.value("item_" .. item.id, item.label, data.amount or 0, "x", {
                warnAt = item.threshold
            })})
        end
    end
end


-- Control Commands

local function sendControl(nodeId, capability, value)
    local s = state[nodeId]
    if not s then
        return false, "Node unknown"
    end

    if s.status == STATUS.UNREACHABLE or s.status == STATUS.OFFLINE then
        return false, "Node is " .. s.status
    end

    if not s.computerId then
        return false, "No computerId for node"
    end

    print("[server] SEND set " .. capability .. "=" .. tostring(value) .. " -> #" .. s.computerId .. " (" .. nodeId ..
              ")")
    local response = protocol.sendAndWait(s.computerId, protocol.msgSet(capability, value), 5)

    if response and response.ok then
        s.controls[capability] = value
        print("[server] RECV ack ok for " .. capability .. " on " .. nodeId)
        return true, "ok"
    else
        local reason = (response and response.message) or "timeout"
        print("[server] RECV ack FAIL for " .. capability .. " on " .. nodeId .. ": " .. reason)
        return false, reason
    end
end

local function sendControlToArea(areaId, capability, value)
    for _, area in ipairs(registry.areas) do
        if area.id == areaId then
            for _, nodeId in ipairs(area.nodes) do
                sendControl(nodeId, capability, value)
            end
            return
        end
    end
end


-- Message Handler

local function handleMessage(senderId, msg)
    if not protocol.isValid(msg) then
        print("[server] RECV invalid message from #" .. tostring(senderId))
        return
    end

    print("[server] RECV " .. tostring(msg.action) .. " from #" .. senderId ..
              (msg.nodeId and (" (" .. msg.nodeId .. ")") or ""))

    local A = protocol.ACTION

    if msg.action == A.REGISTER then
        local nodeId = msg.nodeId
        local nodeDef = findOrCreateNode(nodeId, senderId, msg)
        markSeen(nodeId, senderId)
        local ack = {
            action = A.ACK,
            ok = true,
            message = "registered",
            nodeDef = nodeDef,
            config = config
        }
        print("[server] SEND register ACK -> #" .. senderId)
        protocol.send(senderId, ack)

    elseif msg.action == A.REPORT then
        markSeen(msg.nodeId, senderId)
        if msg.metrics then
            updateMetrics(msg.nodeId, msg.metrics)
        end

    elseif msg.action == A.PING then
        markSeen(msg.nodeId, senderId)
        protocol.send(senderId, protocol.msgPong(nil))

    elseif msg.action == A.PONG then
        if msg.nodeId then
            markSeen(msg.nodeId, senderId)
            print("[server] RECOVERED: " .. msg.nodeId)
        end

    elseif msg.action == A.ACK then
        -- ACK from node monitor toggle – keep controls state in sync
        if msg.nodeId and msg.capability and msg.value ~= nil and msg.ok then
            local s = state[msg.nodeId]
            if s then
                s.controls[msg.capability] = msg.value
            end
        end
    end
end


-- Public API (used by ui.lua)

local server = {}

function server.getRegistry()
    return registry
end
function server.getNodeIndex()
    return nodeIndex
end
function server.getState()
    return state
end
function server.getStatus()
    return STATUS
end
function server.getConfig()
    return config
end
function server.getNodeState(nodeId)
    return state[nodeId]
end

function server.getAreaNodes(areaId)
    for _, area in ipairs(registry.areas) do
        if area.id == areaId then
            local nodes = {}
            for _, nodeId in ipairs(area.nodes) do
                nodes[#nodes + 1] = {
                    def = nodeIndex[nodeId],
                    state = state[nodeId]
                }
            end
            return nodes
        end
    end
    return {}
end

server.sendControl = sendControl
server.sendControlToArea = sendControlToArea


-- Main

print("[server] Tower Control Server v" .. VERSION)
protocol.open()

local timers = {{
    every = 1,
    last = 0,
    fn = runWatchdog
}, {
    every = 5,
    last = 0,
    fn = pollME
}}

local function networkLoop()
    while true do
        local senderId, msg = protocol.receive(1)
        if senderId and msg then
            handleMessage(senderId, msg)
        end

        local now = os.clock()
        for _, t in ipairs(timers) do
            if now - t.last >= t.every then
                t.fn()
                t.last = now
            end
        end
    end
end

local function uiLoop()
    local ok, uiMod = pcall(require, "lib/ui")
    if not ok then
        print("[server] UI load failed: " .. tostring(uiMod))
        print("[server] Running headless.")
        while true do
            os.sleep(60)
        end
    end
    uiMod.run(server)
end

parallel.waitForAny(networkLoop, uiLoop)

return server
