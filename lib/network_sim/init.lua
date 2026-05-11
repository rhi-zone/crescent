if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Rng = { float: (self: Rng) -> number, int: (self: Rng, a: integer, b: integer) -> integer, next: (self: Rng) -> integer }
--:: NetMsg = { from: unknown, to: unknown, msg: unknown, deliver_at: integer, id: integer }
--:: NetTickResult = { delivered: { [integer]: NetMsg }, dropped: { [integer]: NetMsg } }
--:: Net = {
--::   _nodes: { [string]: function },
--::   _queue: { [integer]: NetMsg },
--::   _history: { [integer]: NetMsg },
--::   _partitions: { [string]: boolean | nil },
--::   _latency: { [string]: number | nil },
--::   _loss: { [string]: number | nil },
--::   _dup: { [string]: number | nil },
--::   _rng: Rng,
--::   _next_msg_id: integer,
--::   _default_latency: number,
--::   tick_count: integer,
--::   send: (self: Net, from: unknown, to: unknown, msg: unknown, opts: unknown | nil) -> (integer | nil, string | nil),
--::   broadcast: (self: Net, from: unknown, msg: unknown, opts: unknown | nil) -> ({ integer } | nil, string | nil),
--::   pending: (self: Net) -> { [integer]: NetMsg },
--::   tick: (self: Net, n: integer | nil) -> NetTickResult,
--::   ...
--:: }

-- Deterministic LCG RNG (same parameters as lib/test/arb.lua)
local function make_rng(seed)
  local state = seed or 12345
  local rng = {}
  function rng:next()
    state = (state * 1664525 + 1013904223) % 4294967296
    return state
  end
  function rng:float()
    return self:next() / 4294967296
  end
  function rng:int(a, b)
    return a + self:next() % (b - a + 1)
  end
  return rng --[[:! Rng]]
end

-- Partition key: directed edge a -> b
local function pkey(a, b)
  return tostring(a) .. "\0" .. tostring(b)
end

-- Create a new simulated network
-- opts: { seed=42, default_latency=1 }
function M.network(opts)
  opts = opts or {}
  --: Net
  local net = {} --[[:! Net]]
  net._nodes = {}        -- id -> handler fn
  net._queue = {}        -- array of { from, to, msg, deliver_at, id }
  net._history = {}      -- array of { tick, type, from, to, msg }
  net._partitions = {}   -- pkey -> true
  net._latency = {}      -- pkey -> latency override
  net._loss = {}         -- pkey -> 0-1 rate
  net._dup = {}          -- pkey -> 0-1 rate
  net._rng = make_rng(opts.seed or 42)
  net._default_latency = opts.default_latency or 1
  net.tick_count = 0
  net._next_msg_id = 1

  -- Register or update a node
  function net:node(id, handler)
    if type(id) == "nil" then return nil, "node id required" end
    if type(handler) ~= "function" then return nil, "handler must be a function" end
    self._nodes[id] = handler
    return self
  end

  -- List all node IDs
  function net:nodes()
    local ids = {}
    for id in pairs(self._nodes) do
      ids[#ids + 1] = id
    end
    return ids
  end

  -- Remove a node
  function net:remove_node(id)
    self._nodes[id] = nil
    return self
  end

  -- Queue a message from `from` to `to`
  -- opts: { delay=nil, reliable=true }
  -- Returns msg_id or (nil, errmsg)
  function net:send(from, to, msg, opts)
    if not self._nodes[from] then return nil, "unknown source node: " .. tostring(from) end
    if not self._nodes[to] then return nil, "unknown destination node: " .. tostring(to) end
    opts = opts or {}

    local reliable = opts.reliable
    if reliable == nil then reliable = true end

    local delay = opts.delay
    if delay == nil then
      delay = net._latency[pkey(from, to)]
      if delay == nil then delay = --[[:! number]] net._default_latency end
    end

    local id = net._next_msg_id
    net._next_msg_id = net._next_msg_id + 1

    net._queue[#net._queue + 1] = {
      from = from,
      to = to,
      msg = msg,
      deliver_at = net.tick_count + delay,
      id = id,
      reliable = reliable,
    }
    return id
  end

  -- Broadcast from `from` to all other nodes
  -- Returns array of msg_ids, or (nil, errmsg)
  function net:broadcast(from, msg, opts)
    if not self._nodes[from] then return nil, "unknown source node: " .. tostring(from) end
    local ids = {}
    for id in pairs(self._nodes) do
      if id ~= from then
        local mid, err = net:send(from, id, msg, opts)
        if not mid then return nil, err end
        ids[#ids + 1] = mid
      end
    end
    return ids
  end

  -- Advance simulation by n ticks (default 1)
  -- Returns { delivered=[{from,to,msg}], dropped=[{from,to,msg}] }
  function net:tick(n)
    n = n or 1
    local all_delivered = {}
    local all_dropped = {}

    for _ = 1, n do
      net.tick_count = net.tick_count + 1
      local remaining = {}
      local deliver_now = {}

      for _, entry in ipairs(net._queue) do
        if entry.deliver_at <= net.tick_count then
          deliver_now[#deliver_now + 1] = entry
        else
          remaining[#remaining + 1] = entry
        end
      end

      net._queue = remaining

      for _, entry in ipairs(deliver_now) do
        local from, to, msg = entry.from, entry.to, entry.msg

        -- Check partition
        local partitioned = net._partitions[pkey(from, to)]

        -- Check loss rate (skip if reliable)
        local lost = false
        if not entry.reliable and not partitioned then
          local loss = net._loss[pkey(from, to)]
          if loss and loss > 0 then
            if net._rng:float() < loss then
              lost = true
            end
          end
        end
        if partitioned then lost = true end

        if lost then
          all_dropped[#all_dropped + 1] = { from = from, to = to, msg = msg }
          net._history[#net._history + 1] = {
            tick = net.tick_count, type = "dropped",
            from = from, to = to, msg = msg,
          }
        else
          -- Check duplicate rate
          local dup = net._dup[pkey(from, to)]
          local do_dup = false
          if dup and dup > 0 then
            if net._rng:float() < dup then
              do_dup = true
            end
          end

          -- Deliver
          local handler = net._nodes[to]
          if handler then
            handler(msg, from, net)
          end
          all_delivered[#all_delivered + 1] = { from = from, to = to, msg = msg }
          net._history[#net._history + 1] = {
            tick = net.tick_count, type = "delivered",
            from = from, to = to, msg = msg,
          }

          -- Deliver duplicate if applicable
          if do_dup and handler then
            handler(msg, from, net)
            all_delivered[#all_delivered + 1] = { from = from, to = to, msg = msg }
            net._history[#net._history + 1] = {
              tick = net.tick_count, type = "delivered",
              from = from, to = to, msg = msg,
              duplicate = true,
            }
          end
        end
      end
    end

    return { delivered = all_delivered, dropped = all_dropped }
  end

  -- Partition: drop all messages between a and b (both directions)
  function net:partition(node_a, node_b)
    self._partitions[pkey(node_a, node_b)] = true
    self._partitions[pkey(node_b, node_a)] = true
    return self
  end

  -- Heal partition between a and b
  function net:heal(node_a, node_b)
    self._partitions[pkey(node_a, node_b)] = nil
    self._partitions[pkey(node_b, node_a)] = nil
    return self
  end

  -- Partition two groups from each other (every pair across groups)
  function net:partition_all(group_a, group_b)
    for _, a in ipairs(group_a) do
      for _, b in ipairs(group_b) do
        self._partitions[pkey(a, b)] = true
        self._partitions[pkey(b, a)] = true
      end
    end
    return self
  end

  -- Set per-link latency override
  function net:set_latency(from, to, latency)
    self._latency[pkey(from, to)] = latency
    return self
  end

  -- Set per-link loss rate (0-1)
  function net:set_loss_rate(from, to, rate)
    if rate < 0 or rate > 1 then return nil, "loss rate must be 0-1" end
    self._loss[pkey(from, to)] = rate
    return self
  end

  -- Set per-link duplicate rate (0-1)
  function net:set_duplicate_rate(from, to, rate)
    if rate < 0 or rate > 1 then return nil, "duplicate rate must be 0-1" end
    self._dup[pkey(from, to)] = rate
    return self
  end

  -- Pending messages in flight
  function net:pending()
    local result = {}
    for _, entry in ipairs(self._queue) do
      result[#result + 1] = {
        from = entry.from,
        to = entry.to,
        msg = entry.msg,
        deliver_at = entry.deliver_at,
      }
    end
    return result
  end

  -- Full event history
  function net:history()
    return self._history
  end

  -- Deterministic random float [0, 1)
  function net:random()
    return self._rng:float()
  end

  -- Deterministic random integer [a, b]
  function net:random_int(a, b)
    return self._rng:int(a, b)
  end

  return net
end

-- Simple reliable broadcast helper
-- Sends msg from `nodes[1]` to all others, then ticks until all delivered.
-- Returns a function that, when called with the network, drives until idle.
-- Usage: M.reliable_broadcast(net, nodes, msg) => ticks until no pending
--: (Net, { unknown }, unknown) -> nil
function M.reliable_broadcast(network, nodes, msg)
  local sender = nodes[1]
  network:broadcast(sender, msg)
  -- Tick until queue is empty (up to 1000 ticks as safety)
  for _ = 1, 1000 do
    if #network:pending() == 0 then break end
    network:tick()
  end
end

-- Simple majority vote consensus
-- Each node proposes `proposal`; after exchange, returns value with majority.
-- Each node sends its proposal to all others; first tick delivers; result tallied.
-- Returns winning value, or nil if no majority.
--: (Net, { unknown }, unknown) -> unknown
function M.majority_vote(network, nodes, proposal)
  local votes = {}
  -- Each node sends its proposal to all others
  for _, id in ipairs(nodes) do
    for _, other in ipairs(nodes) do
      if other ~= id then
        network:send(id, other, { type = "vote", value = proposal })
      end
    end
    -- Also count own vote
    votes[proposal] = (votes[proposal] or 0) + 1
  end

  -- Tick until queue is empty (up to 1000 ticks)
  for _ = 1, 1000 do
    if #network:pending() == 0 then break end
    local result = network:tick()
    for _, ev in ipairs(result.delivered) do
      if type(ev.msg) == "table" and ev.msg.type == "vote" then
        local v = ev.msg.value
        votes[v] = (votes[v] or 0) + 1
      end
    end
  end

  local majority = math.floor(#nodes / 2) + 1
  for val, count in pairs(votes) do
    if count >= majority then return val end
  end
  return nil
end

return M
