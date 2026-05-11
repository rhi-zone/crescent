if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Mediator pattern: commands, queries, events, and middleware.
-- Commands/queries: one registered handler, dispatched via send/query.
-- Events: multiple handlers, dispatched via emit (errors collected, not thrown).
-- Middleware: pipeline wrapping send/query dispatch; FIFO order (first registered = outermost).
-- Namespaces: sub-mediator that prefixes all names.
local M = {}
M._tier = "pure"

-- Internal constructor for a mediator instance.
-- Accepts an optional prefix string for namespace sub-mediators, and an
-- optional reference to a parent mediator (shares handler/middleware tables).
local function make_mediator(prefix, parent)
  local prefix_ = (prefix or nil) --[[:! string | nil]]
  local med = {}

  -- If parent provided, share their tables so namespace dispatch hits parent state.
  local handlers     = parent and parent._handlers     or {}
  local event_lists  = parent and parent._event_lists  or {}
  local global_mw    = (parent and parent._global_mw    or {}) --[[:! { [integer]: unknown }]]
  local command_mw   = parent and parent._command_mw   or {}

  -- Expose for namespace children.
  med._handlers    = handlers
  med._event_lists = event_lists
  med._global_mw   = global_mw
  med._command_mw  = command_mw

  local function full_name(name)
    if prefix_ then return prefix_ .. "." .. name end
    return name
  end

  --- Register a command handler (one per name; last write wins).
  -- @param name string
  -- @param handler (payload) -> result, err
  function med:register(name, handler)
    handlers[full_name(name)] = handler
  end

  --- Alias for register — signals read-only / query intent.
  function med:register_query(name, handler)
    handlers[full_name(name)] = handler
  end

  --- Build the dispatch chain for a given full command name and invoke it.
  -- Middleware order: global middlewares wrap command-specific ones, which wrap
  -- the handler. All lists are in registration order (FIFO = outermost first).
  local function dispatch(fname, payload)
    local handler = handlers[fname]
    if not handler then
      return nil, "no handler registered for '" .. fname .. "'"
    end

    -- Innermost call: the actual handler.
    local function invoke(_name, _payload)
      return handler(_payload)
    end

    -- Build chain: command-specific middleware wraps handler.
    local cmd_mw = command_mw[fname]
    local chain = invoke
    if cmd_mw then
      for i = #cmd_mw, 1, -1 do
        local mw = cmd_mw[i]
        local next_fn = chain
        chain = function(_name, _payload)
          return mw(_name, _payload, next_fn)
        end
      end
    end

    -- Global middleware wraps command-specific chain (outermost).
    for i = #global_mw, 1, -1 do
      local mw = (global_mw[i] --[[:! (unknown, unknown, unknown) -> unknown]])
      local next_fn = chain
      chain = function(_name, _payload)
        return mw(_name, _payload, next_fn)
      end
    end

    return chain(fname, payload)
  end

  --- Dispatch a command. Returns (result, err).
  function med:send(name, payload)
    return dispatch(full_name(name), payload)
  end

  --- Alias for send — signals read-only / query intent.
  function med:query(name, payload)
    return dispatch(full_name(name), payload)
  end

  --- Subscribe to an event. Returns a handle with a remove() method.
  -- Multiple handlers per event are supported; all are called on emit.
  function med:on(name, handler)
    local fname = full_name(name)
    if not event_lists[fname] then
      event_lists[fname] = {}
    end
    local list = event_lists[fname]
    list[#list + 1] = handler

    local handle = {}
    function handle:remove()
      local l = event_lists[fname]
      if not l then return end
      for i = 1, #l do
        if l[i] == handler then
          table.remove(l, i)
          return
        end
      end
    end
    return handle
  end

  --- Unsubscribe a specific handler from an event.
  function med:off(name, handler)
    local fname = full_name(name)
    local list = event_lists[fname]
    if not list then return end
    for i = 1, #list do
      if list[i] == handler then
        table.remove(list, i)
        return
      end
    end
  end

  --- Publish an event. All handlers are called synchronously.
  -- Errors in handlers are caught and collected; they do not abort other handlers.
  -- Returns an array of error strings (empty on full success).
  function med:emit(name, payload)
    local fname = full_name(name)
    local list = event_lists[fname]
    local errors = {}
    if not list then return errors end
    for i = 1, #list do
      local ok, err = pcall(list[i], payload)
      if not ok then
        errors[#errors + 1] = err
      end
    end
    return errors
  end

  --- Add middleware.
  -- use(mw)         — global middleware (runs for every send/query)
  -- use(name, mw)   — command-specific middleware (runs only for that command)
  -- Middleware signature: function(name, payload, next) -> result, err
  -- Middleware is applied FIFO: first registered is outermost.
  function med:use(name_or_mw, mw)
    if type(name_or_mw) == "function" then
      -- Global middleware.
      global_mw[#global_mw + 1] = name_or_mw
    else
      -- Command-specific middleware.
      local fname = full_name(name_or_mw)
      if not command_mw[fname] then
        command_mw[fname] = {}
      end
      command_mw[fname][#command_mw[fname] + 1] = mw
    end
  end

  --- Create a sub-mediator that prefixes all names with the given prefix.
  -- The sub-mediator shares handler/event/middleware tables with the parent.
  function med:namespace(ns_prefix)
    local ns_ = ns_prefix --[[:! string]]
    local combined = prefix_ and (prefix_ .. "." .. ns_) or ns_
    return make_mediator(combined, med)
  end

  return med
end

--- Create a new mediator instance.
function M.new()
  local make_any = (make_mediator --[[:! (unknown, unknown) -> unknown]])
  return make_any(nil, nil)
end

return M
