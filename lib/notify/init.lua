if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

--: notify
local M = {}

--- Normalize a message: set defaults for missing fields.
--: (msg: table) -> table
local function normalize(msg)
  if type(msg) ~= "table" then msg = { text = tostring(msg) } end
  if not msg.level then msg.level = "info" end
  if not msg.timestamp then msg.timestamp = os.time() end
  return msg
end

--- Message constructor. Sets defaults (timestamp, level).
--: (fields: table) -> table
function M.message(fields)
  local msg = {}
  if fields then
    for k, v in pairs(fields) do msg[k] = v end
  end
  return normalize(msg)
end

-- ── Channels ────────────────────────────────────────────────────────────

--- Webhook channel: sends HTTP POST with JSON body via injected transport.
--: (opts: table) -> channel
function M.webhook(opts)
  local url = opts.url
  local headers = opts.headers
  local transform = opts.transform
  local transport = opts.transport
  local ch = {}
  --: (msg: table) -> true | nil, string
  function ch:send(msg)
    msg = normalize(msg)
    local body = msg
    if transform then body = transform(msg) end
    if not transport or not transport.post then
      return nil, "no transport configured"
    end
    local ok, err = transport.post(url, body, headers)
    if not ok then return nil, err or "transport error" end
    return true
  end
  return ch
end

--- Log channel: calls logger(level, formatted_text).
--: (opts: table) -> channel
function M.log_channel(opts)
  local logger = opts.logger
  local default_level = opts.level or "info"
  local ch = {}
  --: (msg: table) -> true | nil, string
  function ch:send(msg)
    msg = normalize(msg)
    local level = msg.level or default_level
    local parts = {}
    if msg.topic then parts[#parts + 1] = "[" .. msg.topic .. "]" end
    parts[#parts + 1] = msg.text or ""
    if msg.meta then
      local meta_parts = {}
      for k, v in pairs(msg.meta) do
        meta_parts[#meta_parts + 1] = k .. "=" .. tostring(v)
      end
      if #meta_parts > 0 then
        table.sort(meta_parts)
        parts[#parts + 1] = "(" .. table.concat(meta_parts, " ") .. ")"
      end
    end
    local text = table.concat(parts, " ")
    logger(level, text)
    return true
  end
  return ch
end

--- Callback channel: calls a function with the message.
--: (fn: (msg: table) -> unknown) -> channel
function M.callback(fn)
  local ch = {}
  --: (msg: table) -> true | nil, string
  function ch:send(msg)
    msg = normalize(msg)
    local ok, err = pcall(fn, msg)
    if not ok then return nil, tostring(err) end
    return true
  end
  return ch
end

--- Console channel: writes formatted message to stderr.
--: (opts?: table) -> channel
function M.console(opts)
  opts = opts or {}
  local format = opts.format or "text"
  local ch = {}
  --: (msg: table) -> true | nil, string
  function ch:send(msg)
    msg = normalize(msg)
    if format == "json" then
      -- Minimal JSON encoding (no dependency on lib/json)
      local parts = {}
      parts[#parts + 1] = '"level":' .. ("%q"):format(msg.level or "info")
      if msg.topic then parts[#parts + 1] = '"topic":' .. ("%q"):format(msg.topic) end
      if msg.text then parts[#parts + 1] = '"text":' .. ("%q"):format(msg.text) end
      if msg.timestamp then parts[#parts + 1] = '"timestamp":' .. tostring(msg.timestamp) end
      io.stderr:write("{" .. table.concat(parts, ",") .. "}\n")
    else
      local line = "[" .. (msg.level or "info"):upper() .. "]"
      if msg.topic then line = line .. " [" .. msg.topic .. "]" end
      if msg.text then line = line .. " " .. msg.text end
      io.stderr:write(line .. "\n")
    end
    return true
  end
  return ch
end

-- ── Router ──────────────────────────────────────────────────────────────

--- Create a notification router.
--: () -> router
function M.router()
  local routes = {}
  local r = {}

  --- Add a channel with optional routing rules.
  --: (name: string, channel: channel, opts?: table) -> nil
  function r:add(name, channel, opts)
    local route = { name = name, channel = channel }
    if opts then
      if opts.levels then
        local set = {}
        for _, l in ipairs(opts.levels) do set[l] = true end
        route.levels = set
      end
      if opts.topics then
        local set = {}
        for _, t in ipairs(opts.topics) do set[t] = true end
        route.topics = set
      end
      route.filter = opts.filter
    end
    routes[#routes + 1] = route
  end

  --- Send a notification to all matching channels.
  --: (msg: table) -> table[]
  function r:send(msg)
    msg = normalize(msg)
    local results = {}
    for i = 1, #routes do
      local route = routes[i]
      local match = true
      if route.levels and not route.levels[msg.level] then match = false end
      if match and route.topics and not route.topics[msg.topic] then match = false end
      if match and route.filter and not route.filter(msg) then match = false end
      if match then
        local ok, err = route.channel:send(msg)
        results[#results + 1] = { name = route.name, ok = ok, err = err }
      end
    end
    return results
  end

  return r
end

-- ── Wrappers ────────────────────────────────────────────────────────────

--- Batch wrapper: accumulates messages and flushes when threshold hit.
--: (channel: channel, opts: table) -> batched_channel
function M.batch(channel, opts)
  local max_size = opts.max_size or 100
  local max_wait = opts.max_wait
  local transform = opts.transform
  local buffer = {}
  local last_flush = os.time()
  local b = {}

  --- Flush all buffered messages to the underlying channel.
  --: () -> true | nil, string
  function b:flush()
    if #buffer == 0 then
      last_flush = os.time()
      return true
    end
    local msgs = buffer
    buffer = {}
    last_flush = os.time()
    local payload
    if transform then
      payload = transform(msgs)
    else
      payload = { text = #msgs .. " notifications", items = msgs }
    end
    return channel:send(payload)
  end

  --- Buffer a message. Flushes automatically at max_size.
  --: (msg: table) -> true | nil, string
  function b:send(msg)
    msg = normalize(msg)
    buffer[#buffer + 1] = msg
    if #buffer >= max_size then
      return self:flush()
    end
    return true
  end

  --- Check max_wait timer and flush if expired.
  --: () -> true | nil, string
  function b:tick()
    if max_wait and (os.time() - last_flush) >= max_wait then
      return self:flush()
    end
    return true
  end

  --- Return the current buffer size.
  --: () -> number
  function b:pending()
    return #buffer
  end

  return b
end

--- Rate-limit wrapper: drops messages exceeding the per-minute limit.
--: (channel: channel, opts: table) -> rate_limited_channel
function M.rate_limit(channel, opts)
  local max_per_minute = opts.max_per_minute or 60
  local on_drop = opts.on_drop
  local now_fn = opts.now or os.time
  local timestamps = {}
  local rl = {}

  --: (msg: table) -> true | nil, string
  function rl:send(msg)
    local now = now_fn()
    -- Prune timestamps older than 60 seconds
    local cutoff = now - 60
    local j = 1
    for i = 1, #timestamps do
      if timestamps[i] > cutoff then
        timestamps[j] = timestamps[i]
        j = j + 1
      end
    end
    for i = j, #timestamps do timestamps[i] = nil end
    if #timestamps >= max_per_minute then
      if on_drop then on_drop(msg) end
      return nil, "rate limited"
    end
    timestamps[#timestamps + 1] = now
    return channel:send(msg)
  end

  return rl
end

--- Retry wrapper: retries on failure up to max_attempts.
--: (channel: channel, opts: table) -> retry_channel
function M.retry(channel, opts)
  local max_attempts = opts.max_attempts or 3
  local rt = {}

  --: (msg: table) -> true | nil, string
  function rt:send(msg)
    local ok, err
    for _ = 1, max_attempts do
      ok, err = channel:send(msg)
      if ok then return true end
    end
    return nil, err
  end

  return rt
end

return M
