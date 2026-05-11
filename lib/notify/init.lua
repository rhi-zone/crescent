if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local M = {}

--:: notify_msg = { level?: string, topic?: string, text?: string, timestamp?: number, meta?: { [string]: unknown }, time_fn?: () -> number, _time_fn?: () -> number, ... }
--:: channel = { send: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil) }
--:: notify = { send: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil) }
--:: router = { send: (self: unknown, msg: notify_msg) -> { name: string, ok: boolean | nil, err: string | nil }[], add: (self: unknown, name: string, channel: channel, opts: ({ levels?: string[], topics?: string[], filter?: (msg: notify_msg) -> boolean } | nil)) -> nil }
--:: retry_channel = { send: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil) }
--:: rate_limited_channel = { send: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil) }
--:: batched_channel = { send: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil), flush: (self: unknown) -> (boolean | nil, string | nil) }
--:: webhook_opts = { url: string, headers?: { [string]: string }, transform?: (msg: notify_msg) -> unknown, transport?: { post: (url: string, body: unknown, headers: ({ [string]: string } | nil)) -> (boolean | nil, string | nil) }, time_fn: () -> number }
--:: log_channel_opts = { logger: (level: string, text: string) -> nil, level?: string, time_fn: () -> number }
--:: callback_opts = { time_fn: () -> number }
--:: console_opts = { format?: string, time_fn: () -> number }
--:: router_opts = { time_fn: () -> number }
--:: route_add_opts = { levels?: string[], topics?: string[], filter?: (msg: notify_msg) -> boolean }
--:: batch_opts = { max_size?: integer, max_wait?: number, transform?: (msgs: notify_msg[]) -> notify_msg, time_fn: () -> number }
--:: rate_limit_opts = { rate?: number, burst?: number, max_per_minute?: number, on_drop?: (msg: notify_msg) -> nil, time_fn: () -> number }
--:: retry_opts = { max_attempts?: integer, backoff?: number, time_fn: () -> number }

--- Normalize a message: set defaults for missing fields.
--: (msg: notify_msg, (() -> number) | nil) -> notify_msg
local function normalize(msg, time_fn)
  if type(msg) ~= "table" then msg = { text = tostring(msg) } --[[: notify_msg]] end
  if not msg.level then msg.level = "info" end
  if not msg.timestamp and time_fn then msg.timestamp = time_fn() end
  return msg
end

--- Message constructor. Sets defaults (timestamp, level).
--: (fields: notify_msg) -> notify_msg
function M.message(fields)
  assert(fields and fields.time_fn, "message requires fields.time_fn")
  local time_fn = fields.time_fn --[[:! () -> number]]
  local msg = {} --[[: notify_msg]]
  for k, v in pairs(fields) do
    if k ~= "time_fn" then msg[k] = v end
  end
  msg._time_fn = time_fn
  return normalize(msg, time_fn)
end

-- ── Channels ────────────────────────────────────────────────────────────

--- Webhook channel: sends HTTP POST with JSON body via injected transport.
--: (opts: webhook_opts) -> channel
function M.webhook(opts)
  assert(opts and opts.time_fn, "webhook requires opts.time_fn")
  local url = opts.url
  local headers = opts.headers
  local transform = opts.transform
  local transport = opts.transport
  local wh_time_fn = opts.time_fn
  local ch = {}
  --: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil)
  function ch.send(self, msg)
    msg = normalize(msg, wh_time_fn)
    local body --: unknown
    body = msg
    if transform then
      local tf = transform --[[:! (msg: notify_msg) -> unknown]]
      body = tf(msg)
    end
    if not transport or not transport.post then
      return nil, "no transport configured"
    end
    local tp = transport --[[:! { post: (url: string, body: unknown, headers: ({ [string]: string } | nil)) -> (boolean | nil, string | nil) }]]
    local ok, err = tp.post(url, body, headers)
    if not ok then return nil, err or "transport error" end
    return true, nil
  end
  return ch
end

--- Log channel: calls logger(level, formatted_text).
--: (opts: log_channel_opts) -> channel
function M.log_channel(opts)
  assert(opts and opts.time_fn, "log_channel requires opts.time_fn")
  local logger = opts.logger
  local default_level = opts.level or "info"
  local lc_time_fn = opts.time_fn
  local ch = {}
  --: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil)
  function ch.send(self, msg)
    msg = normalize(msg, lc_time_fn)
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
    return true, nil
  end
  return ch
end

--- Callback channel: calls a function with the message.
--: (fn: (msg: notify_msg) -> unknown, opts: callback_opts) -> channel
function M.callback(fn, opts)
  assert(opts and opts.time_fn, "callback requires opts.time_fn")
  local cb_time_fn = opts.time_fn
  local ch = {}
  --: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil)
  function ch.send(self, msg)
    msg = normalize(msg, cb_time_fn)
    local ok, err = pcall(fn, msg)
    if not ok then return nil, tostring(err) end
    return true, nil
  end
  return ch
end

--- Console channel: writes formatted message to stderr.
--: (opts: console_opts) -> channel
function M.console(opts)
  assert(opts and opts.time_fn, "console requires opts.time_fn")
  local format = opts.format or "text"
  local con_time_fn = opts.time_fn
  local ch = {}
  --: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil)
  function ch.send(self, msg)
    msg = normalize(msg, con_time_fn)
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
    return true, nil
  end
  return ch
end

-- ── Router ──────────────────────────────────────────────────────────────

--- Create a notification router.
--: (opts: router_opts) -> router
function M.router(opts)
  assert(opts and opts.time_fn, "router requires opts.time_fn")
  local rt_time_fn = opts.time_fn
  local routes = {} --[[: { name: string, channel: channel, levels: { [string]: boolean } | nil, topics: { [string]: boolean } | nil, filter: ((msg: notify_msg) -> boolean) | nil }[] ]]
  local r = {}

  --- Add a channel with optional routing rules.
  --: (self: unknown, name: string, channel: channel, opts: (route_add_opts | nil)) -> nil
  function r.add(self, name, channel, add_opts)
    local levels --: { [string]: boolean } | nil
    local topics --: { [string]: boolean } | nil
    local filter --: ((msg: notify_msg) -> boolean) | nil
    if add_opts then
      if add_opts.levels then
        local set = {} --[[: { [string]: boolean }]]
        for _, l in ipairs(add_opts.levels) do set[l] = true end
        levels = set
      end
      if add_opts.topics then
        local set = {} --[[: { [string]: boolean }]]
        for _, t in ipairs(add_opts.topics) do set[t] = true end
        topics = set
      end
      filter = add_opts.filter
    end
    routes[#routes + 1] = { name = name, channel = channel, levels = levels, topics = topics, filter = filter }
  end

  --- Send a notification to all matching channels.
  --: (self: unknown, msg: notify_msg) -> { name: string, ok: boolean | nil, err: string | nil }[]
  function r.send(self, msg)
    local m = normalize(msg, rt_time_fn)
    local results = {}
    for i = 1, #routes do
      local route = routes[i]
      local match = true
      if route.levels and not route.levels[m.level] then match = false end
      if match and route.topics and not route.topics[m.topic] then match = false end
      if match and route.filter and not route.filter(m) then match = false end
      if match then
        local ok, err = route.channel:send(m)
        results[#results + 1] = { name = route.name, ok = ok, err = err }
      end
    end
    return results
  end

  return r
end

-- ── Wrappers ────────────────────────────────────────────────────────────

--- Batch wrapper: accumulates messages and flushes when threshold hit.
--: (channel: channel, opts: batch_opts) -> batched_channel
function M.batch(channel, opts)
  assert(opts and opts.time_fn, "batch requires opts.time_fn")
  local bat_time_fn = opts.time_fn
  local max_size = opts.max_size or 100
  local max_wait = opts.max_wait
  local transform = opts.transform
  local buffer = {}
  local last_flush = bat_time_fn()
  local b = {}

  --- Flush all buffered messages to the underlying channel.
  --: (self: unknown) -> (boolean | nil, string | nil)
  function b.flush(self)
    if #buffer == 0 then
      last_flush = bat_time_fn()
      return true, nil
    end
    local msgs = buffer
    buffer = {}
    last_flush = bat_time_fn()
    local payload --: notify_msg | nil
    if transform then
      local tf = transform --[[:! (msgs: notify_msg[]) -> notify_msg]]
      payload = tf(msgs)
    else
      payload = { text = #msgs .. " notifications", items = msgs }
    end
    return channel:send(payload)
  end

  --- Buffer a message. Flushes automatically at max_size.
  --: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil)
  function b.send(self, msg)
    msg = normalize(msg, bat_time_fn)
    buffer[#buffer + 1] = msg
    if #buffer >= max_size then
      return b.flush(self)
    end
    return true, nil
  end

  --- Check max_wait timer and flush if expired.
  --: (self: unknown) -> (boolean | nil, string | nil)
  function b.tick(self)
    local now = bat_time_fn() --[[:! number]]
    local lf = last_flush --[[:! number]]
    if max_wait then
      local mw = max_wait --[[:! number]]
      if (now - lf) >= mw then
        return b.flush(self)
      end
    end
    return true, nil
  end

  --- Return the current buffer size.
  --: (self: unknown) -> number
  function b.pending(self)
    return #buffer
  end

  return b
end

--- Rate-limit wrapper: drops messages exceeding the per-minute limit.
--: (channel: channel, opts: rate_limit_opts) -> rate_limited_channel
function M.rate_limit(channel, opts)
  assert(opts and opts.time_fn, "rate_limit requires opts.time_fn")
  local max_per_minute = opts.max_per_minute or 60
  local on_drop = opts.on_drop
  local now_fn = opts.time_fn
  local timestamps = {}
  local rl = {}

  --: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil)
  function rl.send(self, msg)
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
      if on_drop then local od = on_drop --[[:! (msg: notify_msg) -> nil]]; od(msg) end
      return nil, "rate limited"
    end
    timestamps[#timestamps + 1] = now
    return channel:send(msg)
  end

  return rl
end

--- Retry wrapper: retries on failure up to max_attempts.
--: (channel: channel, opts: retry_opts) -> retry_channel
function M.retry(channel, opts)
  local max_attempts = opts.max_attempts or 3
  local rt = {}

  --: (self: unknown, msg: notify_msg) -> (boolean | nil, string | nil)
  function rt.send(self, msg)
    local ok, err
    for _ = 1, max_attempts do
      ok, err = channel:send(msg)
      if ok then return true, nil end
    end
    return nil, err or "retry failed"
  end

  return rt
end

return M
