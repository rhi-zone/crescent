-- lib/service_registry/init.lua
-- In-process service registry with health checks, load balancing, and events.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Registry constructor ─────────────────────────────────────────────────────

--- Create a new service registry.
-- opts.clock: function returning current time (required)
-- opts.ttl: seconds before unrefreshed entry expires (default 30)
function M.new(opts)
  opts = opts or {}
  local reg = {}
  reg._clock = opts.clock
  reg._ttl = opts.ttl or 30
  reg._services = {}   -- [name] = { [id] = instance_table }
  reg._rr = {}         -- [name] = round-robin counter
  reg._watchers = {}   -- [name] = { fn, ... }
  reg._counter = 0     -- global registration counter

  -- ── Internal helpers ───────────────────────────────────────────────────────

  local function fire(name, event, instance)
    local watchers = reg._watchers[name]
    if watchers then
      for i = 1, #watchers do
        watchers[i](event, instance)
      end
    end
  end

  local function is_expired(inst)
    if reg._ttl <= 0 then return false end
    return (inst.last_seen + reg._ttl) < reg._clock()
  end

  local function is_visible(inst)
    return inst._healthy and not is_expired(inst)
  end

  -- ── Registration ──────────────────────────────────────────────────────────

  function reg:register(name, info)
    info = info or {}
    reg._counter = reg._counter + 1
    local id = name .. "#" .. reg._counter
    local now = reg._clock()
    local inst = {
      id = id,
      name = name,
      host = info.host,
      port = info.port,
      meta = info.meta or {},
      tags = info.tags or {},
      registered_at = now,
      last_seen = now,
      _healthy = true,
      active_connections = 0,
    }
    if not reg._services[name] then
      reg._services[name] = {}
    end
    reg._services[name][id] = inst
    fire(name, "register", inst)
    return id
  end

  function reg:deregister(id)
    -- search all services for the id
    for name, instances in pairs(reg._services) do
      if instances[id] then
        local inst = instances[id]
        instances[id] = nil
        fire(name, "deregister", inst)
        return
      end
    end
  end

  function reg:deregister_all(name)
    local instances = reg._services[name]
    if not instances then return end
    -- snapshot keys before iterating
    local ids = {}
    for id in pairs(instances) do
      ids[#ids + 1] = id
    end
    for i = 1, #ids do
      local id = ids[i]
      local inst = instances[id]
      instances[id] = nil
      fire(name, "deregister", inst)
    end
    reg._services[name] = {}
  end

  -- ── Health management ────────────────────────────────────────────────────

  local function find_instance(id)
    for _, instances in pairs(reg._services) do
      if instances[id] then
        return instances[id]
      end
    end
    return nil
  end

  function reg:healthy(id)
    local inst = find_instance(id)
    if not inst then return nil, "instance not found: " .. tostring(id) end
    inst._healthy = true
    inst.last_seen = reg._clock()
    fire(inst.name, "healthy", inst)
    return true
  end

  function reg:unhealthy(id)
    local inst = find_instance(id)
    if not inst then return nil, "instance not found: " .. tostring(id) end
    inst._healthy = false
    fire(inst.name, "unhealthy", inst)
    return true
  end

  function reg:heartbeat(id)
    local inst = find_instance(id)
    if not inst then return nil, "instance not found: " .. tostring(id) end
    inst.last_seen = reg._clock()
    inst._healthy = true
    fire(inst.name, "healthy", inst)
    return true
  end

  -- ── Connection tracking ──────────────────────────────────────────────────

  function reg:connection_open(id)
    local inst = find_instance(id)
    if not inst then return nil, "instance not found: " .. tostring(id) end
    inst.active_connections = inst.active_connections + 1
    return true
  end

  function reg:connection_close(id)
    local inst = find_instance(id)
    if not inst then return nil, "instance not found: " .. tostring(id) end
    if inst.active_connections > 0 then
      inst.active_connections = inst.active_connections - 1
    end
    return true
  end

  -- ── TTL eviction ─────────────────────────────────────────────────────────

  function reg:evict_expired()
    for name, instances in pairs(reg._services) do
      local expired_ids = {}
      for id, inst in pairs(instances) do
        if is_expired(inst) then
          expired_ids[#expired_ids + 1] = id
        end
      end
      for i = 1, #expired_ids do
        local id = expired_ids[i]
        local inst = instances[id]
        instances[id] = nil
        fire(name, "expired", inst)
      end
    end
  end

  -- ── Discovery ────────────────────────────────────────────────────────────

  local function tags_match(inst_tags, filter_tags)
    --: unknown
    --: unknown
    if not filter_tags or #(filter_tags --[[:! { [integer]: string }]]) == 0 then return true end
    -- build a set of instance tags
    local tag_set = {} --: { [string]: boolean }
    local inst_tags_ = inst_tags --[[:! { [integer]: string }]]
    for i = 1, #inst_tags_ do
      tag_set[inst_tags_[i]] = true
    end
    for i = 1, #filter_tags do
      if not tag_set[filter_tags[i]] then
        return false
      end
    end
    return true
  end

  function reg:discover(name, filter)
    reg:evict_expired()
    filter = filter or {}
    local instances = reg._services[name]
    if not instances then return {} end
    local result = {}
    for _, inst in pairs(instances) do
      local inst_ = inst --[[:! { _healthy: boolean | nil, tags: unknown, ... }]]
      if is_visible(inst_) and tags_match(inst_.tags, filter.tags) then
        result[#result + 1] = inst
      end
    end
    return result
  end

  -- ── Load balancing ───────────────────────────────────────────────────────

  function reg:get(name, strategy)
    strategy = strategy or "round_robin"
    local instances = reg:discover(name)
    if #instances == 0 then
      return nil, "no healthy instances for service: " .. tostring(name)
    end

    if strategy == "random" then
      local idx = math.floor(math.random() * #instances) + 1
      return instances[idx]

    elseif strategy == "least_conn" then
      -- sort by active_connections ascending (stable: also by id for determinism)
      table.sort(instances, function(a, b)
        if a.active_connections ~= b.active_connections then
          return a.active_connections < b.active_connections
        end
        return a.id < b.id
      end)
      return instances[1]

    else
      -- round_robin (default)
      if not reg._rr[name] then reg._rr[name] = 0 end
      -- use 0-based index mod length, then convert to 1-based
      local idx = (reg._rr[name] % #instances) + 1
      reg._rr[name] = reg._rr[name] + 1
      return instances[idx]
    end
  end

  -- ── Watchers ──────────────────────────────────────────────────────────────

  function reg:watch(name, fn)
    if not reg._watchers[name] then
      reg._watchers[name] = {}
    end
    reg._watchers[name][#reg._watchers[name] + 1] = fn
    return function()
      local watchers = reg._watchers[name]
      if not watchers then return end
      for i = 1, #watchers do
        if watchers[i] == fn then
          table.remove(watchers, i)
          return
        end
      end
    end
  end

  -- ── Services list ─────────────────────────────────────────────────────────

  function reg:services()
    local names = {}
    for name in pairs(reg._services) do
      names[#names + 1] = name
    end
    table.sort(names)
    return names
  end

  -- ── Stats ────────────────────────────────────────────────────────────────

  function reg:stats()
    reg:evict_expired()
    local total = 0
    local healthy = 0
    local unhealthy = 0
    local by_service = {}
    for name, instances in pairs(reg._services) do
      local svc_total = 0
      local svc_healthy = 0
      for _, inst in pairs(instances) do
        svc_total = svc_total + 1
        total = total + 1
        if inst._healthy then
          svc_healthy = svc_healthy + 1
          healthy = healthy + 1
        else
          unhealthy = unhealthy + 1
        end
      end
      by_service[name] = { total = svc_total, healthy = svc_healthy }
    end
    return {
      total = total,
      healthy = healthy,
      unhealthy = unhealthy,
      by_service = by_service,
    }
  end

  return reg
end

return M
