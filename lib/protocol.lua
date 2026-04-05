-- lib/protocol.lua
-- Message protocol for Tower Control System
-- All communication between server and clients goes through here.

local protocol = {}

protocol.CHANNEL = "tower_ctrl"
protocol.TIMEOUT  = 5  -- seconds to wait for a response


-- Message Types


protocol.ACTION = {
  -- Client --> Server
  REGISTER  = "register",   -- Client announces itself on boot
  REPORT    = "report",     -- Client pushes metric data
  ACK       = "ack",        -- Generic acknowledgement

  -- Server --> Client
  SET       = "set",        -- Set a control value
  QUERY     = "query",      -- Request immediate metric report
  UPDATE    = "update",     -- Server tells client to re-download & reboot

  -- Bidirectional
  PING      = "ping",
  PONG      = "pong",
}


-- Message Constructors


--- Client boot registration
function protocol.msgRegister(nodeId)
  return {
    action  = protocol.ACTION.REGISTER,
    nodeId  = nodeId,
    time    = os.epoch("utc"),
  }
end

--- Metric report from client
function protocol.msgReport(nodeId, metrics)
  return {
    action  = protocol.ACTION.REPORT,
    nodeId  = nodeId,
    metrics = metrics,
    time    = os.epoch("utc"),
  }
end

--- Control command from server
function protocol.msgSet(capability, value)
  return {
    action     = protocol.ACTION.SET,
    capability = capability,
    value      = value,
  }
end

--- Query request from server
function protocol.msgQuery()
  return { action = protocol.ACTION.QUERY }
end

--- ACK response
function protocol.msgAck(nodeId, ok, message)
  return {
    action  = protocol.ACTION.ACK,
    nodeId  = nodeId,
    ok      = ok,
    message = message,
  }
end

--- Ping / Pong
function protocol.msgPing(nodeId)
  return { action = protocol.ACTION.PING, nodeId = nodeId }
end

function protocol.msgPong(nodeId)
  return { action = protocol.ACTION.PONG, nodeId = nodeId }
end

--- Update notification (server --> client)
function protocol.msgUpdate()
  return { action = protocol.ACTION.UPDATE }
end


-- Send / Receive Helpers


--- Open the first available modem.
--- Call once on startup.
function protocol.open()
  local modem = peripheral.find("modem")
  if not modem then
    error("[protocol] No modem found. Attach a modem to this computer.")
  end
  rednet.open(peripheral.getName(modem))
end

--- Send a message to a specific computer ID.
---@param targetId number
---@param msg table
function protocol.send(targetId, msg)
  rednet.send(targetId, msg, protocol.CHANNEL)
end

--- Broadcast a message to all computers on the network.
---@param msg table
function protocol.broadcast(msg)
  rednet.broadcast(msg, protocol.CHANNEL)
end

--- Wait for the next message on our channel.
--- Returns: senderId (number), msg (table)
--- Blocks until a message arrives (or timeout if given).
---@param timeout number|nil  seconds, nil = block forever
---@return number|nil, table|nil
function protocol.receive(timeout)
  local senderId, msg = rednet.receive(protocol.CHANNEL, timeout)
  return senderId, msg
end

--- Send a message and wait for an ACK response.
--- Returns the ACK message or nil on timeout.
---@param targetId number
---@param msg table
---@param timeout number|nil
---@return table|nil
function protocol.sendAndWait(targetId, msg, timeout)
  protocol.send(targetId, msg)
  local deadline = (timeout or protocol.TIMEOUT)
  local start    = os.clock()

  while true do
    local remaining = deadline - (os.clock() - start)
    if remaining <= 0 then return nil end

    local senderId, response = protocol.receive(remaining)
    if senderId == targetId and response then
      return response
    end
  end
end


-- Validation


--- Basic sanity check on incoming messages.
---@param msg any
---@return boolean
function protocol.isValid(msg)
  return type(msg) == "table" and type(msg.action) == "string"
end

return protocol
