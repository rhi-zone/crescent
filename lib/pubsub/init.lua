if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Pub/sub event bus with topic patterns, filtering, and middleware.
local M = {}
M._tier = "pure"

--:: SubEntry = { id: integer, handler: (unknown) -> unknown, filter: ((unknown) -> boolean) | nil, once: boolean }

-- Split a topic string into segments on ".".
--: (string) -> { [integer]: string }
local function split_segments(s)
  local segs = {}
  local i = 1
  local len = #s
  while i <= len do
    local j = s:find(".", i, true)
    if j then
      segs[#segs + 1] = s:sub(i, j - 1)
      i = j + 1
    else
      segs[#segs + 1] = s:sub(i)
      break
    end
  end
  return segs
end

-- Match a single segment against a pattern segment.
-- Supports "?" as single-character wildcard within a segment.
--: (string, string) -> boolean
local function match_segment(seg, pat)
  if pat == "*" or pat == "**" or pat == "#" then
    return true
  end
  if not pat:find("?", 1, true) then
    return seg == pat
  end
  -- Pattern has "?" wildcards — match character by character.
  local si, pi = 1, 1
  local slen, plen = #seg, #pat
  while si <= slen and pi <= plen do
    local pc = pat:sub(pi, pi)
    if pc == "?" then
      si = si + 1
      pi = pi + 1
    elseif pc == seg:sub(si, si) then
      si = si + 1
      pi = pi + 1
    else
      return false
    end
  end
  return (si > slen and pi > plen) and true or false
end

--- Test whether a concrete topic matches a pattern.
-- Wildcards:
--   *   — one segment (no dots)
--   **  — zero or more segments
--   #   — zero or more segments (MQTT-style alias for **)
--   ?   — any single character within a segment
-- @param topic   string  concrete topic, e.g. "user.profile.updated"
-- @param pattern string  pattern, e.g. "user.*" or "user.#"
-- @return boolean
function M.matches_pattern(topic, pattern)
  if pattern == "#" or pattern == "**" then
    return true
  end
  if pattern == topic then
    return true
  end
  local tsegs = split_segments(topic)
  local psegs = split_segments(pattern)
  local ti, pi = 1, 1
  local tlen, plen = #tsegs, #psegs
  while ti <= tlen and pi <= plen do
    local ps = psegs[pi]
    if ps == "**" or ps == "#" then
      -- Greedy: consume all remaining topic segments (requires at least 1).
      return ti <= tlen
    elseif ps == "*" then
      ti = ti + 1
      pi = pi + 1
    elseif match_segment(tsegs[ti], ps) then
      ti = ti + 1
      pi = pi + 1
    else
      return false
    end
  end
  return ti > tlen and pi > plen
end

-- Counter for unique subscriber IDs.
local _next_id = 0
local function new_id()
  _next_id = _next_id + 1
  return _next_id
end

--- Create a new pub/sub bus.
-- @return Bus
function M.new()
  -- subs[topic_pattern] = array of { id, handler, filter, once }
  local subs = {} --: { [string]: any }
  -- middleware stack: array of function(topic, msg, next)
  local middleware = {}
  -- async queue: array of { topic, data }
  local async_queue = {}

  local bus = {}

  --- Subscribe to a topic pattern.
  -- @param pattern  string
  -- @param handler  function(msg)
  -- @param opts     table|nil  { filter = function(msg)->bool, once = bool }
  -- @return function  unsubscribe
  function bus:subscribe(pattern, handler, opts)
    opts = opts or {}
    local id = new_id()
    if not subs[pattern] then
      subs[pattern] = {}
    end
    local list = subs[pattern]
    list[#list + 1] = {
      id      = id,
      handler = handler,
      filter  = opts.filter,
      once    = opts.once or false,
    }
    return function()
      local lst = subs[pattern]
      if not lst then return end
      for i = 1, #lst do
        if lst[i].id == id then
          table.remove(lst, i)
          break
        end
      end
      if #(subs[pattern] or {}) == 0 then
        subs[pattern] = nil
      end
    end
  end

  --- Subscribe, auto-unsubscribing after the first matching message.
  -- @param pattern string
  -- @param handler function(msg)
  -- @param opts    table|nil
  -- @return function  unsubscribe
  function bus:once(pattern, handler, opts)
    opts = opts or {}
    opts.once = true
    return self:subscribe(pattern, handler, opts)
  end

  --- Remove all subscribers for an exact pattern string.
  -- @param pattern string
  function bus:unsubscribe_all(pattern)
    subs[pattern] = nil
  end

  --- Add middleware. Each middleware receives (topic, msg, next).
  -- Call next() to continue delivery; omitting next() blocks delivery.
  -- @param fn function(topic, msg, next)
  function bus:use(fn)
    middleware[#middleware + 1] = fn
  end

  -- Internal: deliver msg to all matching subscribers for a topic.
  local function deliver(topic, msg)
    -- Collect matching subs (snapshot to handle once-removal during iteration).
    local matched = {}
    for pattern, list in pairs(subs) do
      if M.matches_pattern(topic, pattern) then
        for i = 1, #list do
          matched[#matched + 1] = { sub = list[i], pattern = pattern }
        end
      end
    end
    -- Fire handlers, removing once-subs.
    local to_remove = {}
    for i = 1, #matched do
      local sub = matched[i].sub
      local pat = matched[i].pattern
      if (not sub.filter) or sub.filter(msg) then
        sub.handler(msg)
        if sub.once then
          to_remove[#to_remove + 1] = { pattern = pat, id = sub.id }
        end
      end
    end
    for i = 1, #to_remove do
      local pat = to_remove[i].pattern
      local rid = to_remove[i].id
      local lst = subs[pat]
      if lst then
        for j = 1, #lst do
          if lst[j].id == rid then
            table.remove(lst, j)
            break
          end
        end
        if #lst == 0 then
          subs[pat] = nil
        end
      end
    end
  end

  -- Internal: run middleware chain then deliver.
  local function run_middleware(topic, msg, idx)
    if idx > #middleware then
      deliver(topic, msg)
      return
    end
    local called = false
    middleware[idx](topic, msg, function()
      if not called then
        called = true
        run_middleware(topic, msg, idx + 1)
      end
    end)
  end

  --- Publish a message to a topic.
  -- @param topic string
  -- @param data  any
  function bus:publish(topic, data)
    run_middleware(topic, data, 1)
  end

  --- Queue a publish for deferred delivery. Call bus:flush() to deliver.
  -- @param topic string
  -- @param data  any
  function bus:publish_async(topic, data)
    async_queue[#async_queue + 1] = { topic = topic, data = data }
  end

  --- Deliver all queued async publishes in order.
  function bus:flush()
    -- Snapshot the queue; new async publishes during flush go to next cycle.
    local q = async_queue
    async_queue = {}
    for i = 1, #q do
      run_middleware(q[i].topic, q[i].data, 1)
    end
  end

  --- Count active subscribers matching an exact pattern string.
  -- @param pattern string
  -- @return integer
  function bus:subscriber_count(pattern)
    return subs[pattern] and #subs[pattern] or 0
  end

  --- Return array of all patterns that currently have subscribers.
  -- @return string[]
  function bus:topics()
    local result = {}
    for pattern in pairs(subs) do
      result[#result + 1] = pattern
    end
    table.sort(result)
    return result
  end

  --- Remove all subscribers and middleware, clear async queue.
  function bus:clear()
    subs = {}
    middleware = {}
    async_queue = {}
  end

  return bus
end

return M
