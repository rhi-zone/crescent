if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Linear scan register allocator (Poletto & Sarkar 1999).
-- Assigns virtual registers to physical registers with spilling.
--
-- ra.allocate(intervals, regfile) -> result
--   intervals: array of {id=int, first=int, last=int, type="gpr"|"simd"}
--   regfile:   {gpr={...}, simd={...}, callee_saved={reg=bool}, aliases={wide=narrow}}
--
-- result: {
--   assignment      = {[vreg_id] = phys_reg_name},
--   spills          = {[vreg_id] = slot_number},
--   callee_saves    = {phys_reg_name, ...},
--   num_spill_slots = int,
-- }

--:: Interval  = { id: integer, first: integer, last: integer, type: string, phys: string, ... }
--:: RegFile   = { gpr: { [integer]: string, ... }, simd: { [integer]: string, ... }, callee_saved: { [string]: boolean, ... }, aliases: { [string]: string, ... }, ... }
--:: AllocResult = { assignment: { [integer]: string, ... }, spills: { [integer]: integer, ... }, callee_saves: { [integer]: string, ... }, num_spill_slots: integer }

local M = {}

-- Insert interval into active list, keeping sorted by last (ascending).
local function active_insert(active, interval)
  --: { [integer]: Interval, ... }
  local active = active
  --: Interval
  local interval = interval
  local n = #active
  local pos = n + 1
  for i = 1, n do
    if active[i].last > interval.last then
      pos = i
      break
    end
  end
  local active_any = active --[[: unknown]]
  table.insert(active_any, pos, interval)
end

-- Build reverse alias map: given aliases = {ymm0="xmm0", ymm1="xmm1", ...}
-- produces both directions: xmm0->ymm0 and ymm0->xmm0.
local function build_alias_pairs(aliases)
  --: { [string]: string, ... }
  local aliases = aliases
  local pairs_map = {} --: { [string]: string, ... }
  for wide, narrow in pairs(aliases) do
    pairs_map[wide]   = narrow
    pairs_map[narrow] = wide
  end
  return pairs_map
end

-- Main allocator.
M.allocate = function(intervals, regfile)
  --: { [integer]: Interval, ... }
  local intervals = intervals
  --: RegFile
  local regfile = regfile

  -- assignment: vreg_id → physical register name (nil means spilled/unassigned).
  local assignment      = {} --: { [integer]: string | nil, ... }
  local spills          = {} --: { [integer]: integer, ... }
  local num_spill_slots = 0

  -- Copy and stable-sort intervals by first (start point).
  local sorted = {} --: { [integer]: Interval, ... }
  for i = 1, #intervals do
    sorted[i] = intervals[i]
  end
  -- Stable insertion sort (input is typically small; stable for determinism).
  for i = 2, #sorted do
    local v = sorted[i] --: Interval
    local j = i - 1
    while j >= 1 and sorted[j].first > v.first do
      sorted[j + 1] = sorted[j]
      j = j - 1
    end
    sorted[j + 1] = v
  end

  -- Free register pools (copies so we don't mutate regfile).
  local free_gpr  = {} --: { [integer]: string, ... }
  local free_simd = {} --: { [integer]: string, ... }
  local rf_gpr    = regfile.gpr
  local rf_simd   = regfile.simd
  for i = 1, #rf_gpr  do free_gpr[i]  = rf_gpr[i]  end
  for i = 1, #rf_simd do free_simd[i] = rf_simd[i] end

  -- alias_pairs maps any register name to its counterpart (bidirectional).
  local alias_pairs = build_alias_pairs(regfile.aliases)

  -- blocked_aliases: set of register names that must not be allocated because
  -- their alias is currently assigned to a live interval.
  -- Uses "true" to mark blocked; remove by setting to false (never nil).
  local blocked_aliases = {} --: { [string]: boolean, ... }

  -- active: array of live intervals, sorted by last ascending.
  -- Each entry carries a .phys field set to its physical register name.
  local active = {} --: { [integer]: Interval, ... }

  -- Sentinel empty pool for unrecognised types (returned by free_pool when
  -- type is neither "gpr" nor "simd").  Declared once to give it a known type.
  local empty_pool = {} --: { [integer]: string, ... }

  local function free_pool(typ)
    --: string
    local typ = typ
    if typ == "gpr"  then return free_gpr  end
    if typ == "simd" then return free_simd end
    return empty_pool
  end

  -- Remove a specific register from a free pool (by value).
  local function pool_remove(pool, reg)
    --: { [integer]: string, ... }
    local pool = pool
    --: string
    local reg = reg
    for i = 1, #pool do
      if pool[i] == reg then
        table.remove(pool, i)
        return
      end
    end
  end

  -- Unblock the alias of a register when it expires.
  local function unblock_alias(reg)
    --: string
    local reg = reg
    local other = alias_pairs[reg]
    if other then
      blocked_aliases[other] = false
    end
  end

  -- Block the alias of a register when it is assigned.
  local function block_alias(reg)
    --: string
    local reg = reg
    local other = alias_pairs[reg]
    if other then
      blocked_aliases[other] = true
    end
  end

  -- Pop a usable register from pool (skipping blocked aliases).
  -- Returns nil if none available.
  --: ({ [integer]: string, ... }) -> string | nil
  local pool_pop = function(pool)
    --: { [integer]: string, ... }
    local pool = pool
    for i = #pool, 1, -1 do
      local reg = pool[i]
      if not blocked_aliases[reg] then
        table.remove(pool, i)
        return reg
      end
    end
    return nil
  end

  -- Expire active intervals whose last < current first; return their regs to pools.
  local function expire(current_first)
    --: integer
    local current_first = current_first
    -- active is sorted by last ascending; expire from the front.
    while #active > 0 do
      local j = active[1] --: Interval
      if j.last >= current_first then break end
      local active_any = active --[[: unknown]]
      table.remove(active_any, 1)
      local pool = free_pool(j.type)
      pool[#pool + 1] = j.phys
      unblock_alias(j.phys)
    end
  end

  -- Allocate a spill slot.
  local function new_slot()
    num_spill_slots = num_spill_slots + 1
    return num_spill_slots
  end

  for _, interval_raw in ipairs(sorted) do
    local interval = interval_raw --: Interval
    expire(interval.first)

    local pool = free_pool(interval.type)
    local reg  = pool_pop(pool)

    if reg then
      -- Assign physical register.
      assignment[interval.id] = reg
      block_alias(reg)
      interval.phys = reg
      active_insert(active, interval)
    else
      -- Spill: find active interval of same type with the largest last.
      -- spill_idx = 0 means "not found".
      local spill_idx  = 0
      local spill_last = -1
      for i = 1, #active do
        local ai = active[i] --: Interval
        if ai.type == interval.type and ai.last > spill_last then
          spill_last = ai.last
          spill_idx  = i
        end
      end

      if spill_idx > 0 and active[spill_idx].last > interval.last then
        -- Steal the spilled interval's register for the current interval.
        local victim = active[spill_idx] --: Interval
        local stolen = victim.phys
        do
          local active_any2 = active --[[: unknown]]
          table.remove(active_any2, spill_idx)
        end
        -- Victim goes to a spill slot.
        local victim_id = victim.id --[[:! integer]]
        assignment[victim_id] = nil
        spills[victim_id] = new_slot()
        unblock_alias(stolen)

        -- Assign stolen register to current interval.
        assignment[interval.id] = stolen
        block_alias(stolen)
        interval.phys = stolen
        active_insert(active, interval)
      else
        -- Current interval gets a spill slot.
        spills[interval.id] = new_slot()
      end
    end
  end

  -- Collect callee-saved registers that were assigned.
  local callee_saves_set = {} --: { [string]: boolean, ... }
  local callee_saves     = {} --: { [integer]: string, ... }
  local rf_cs = regfile.callee_saved
  for _, phys_raw in pairs(assignment) do
    local phys = --[[:! string]] phys_raw
    if phys and rf_cs[phys] and not callee_saves_set[phys] then
      callee_saves_set[phys] = true
      callee_saves[#callee_saves + 1] = phys
    end
  end
  table.sort(callee_saves)

  return {
    assignment      = assignment,
    spills          = spills,
    callee_saves    = callee_saves,
    num_spill_slots = num_spill_slots,
  }
end

return M
