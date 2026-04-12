if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- compound(commands, desc?) -> command
-- Groups multiple commands into a single undoable unit.
-- ---------------------------------------------------------------------------
function M.compound(commands, desc)
  return {
    execute = function()
      for i = 1, #commands do
        commands[i].execute()
      end
    end,
    undo = function()
      for i = #commands, 1, -1 do
        commands[i].undo()
      end
    end,
    describe = function()
      if desc then return desc end
      local parts = {}
      for i = 1, #commands do
        local cmd = commands[i]
        if cmd.describe then
          parts[#parts + 1] = cmd.describe()
        else
          parts[#parts + 1] = "(command)"
        end
      end
      return table.concat(parts, "; ")
    end,
  }
end

-- ---------------------------------------------------------------------------
-- history(opts?) -> history_obj
-- Manages an undo/redo stack.
--   opts.max_size  — max entries in undo stack (default: unlimited)
-- ---------------------------------------------------------------------------
function M.history(opts)
  opts = opts or {}
  local max_size = opts.max_size  -- nil = unlimited

  local undo_stack = {}  -- [1] = oldest, [#] = most recent
  local redo_stack = {}

  -- batch/transaction state
  local batch_commands = nil  -- non-nil when inside a batch or transaction

  local h = {}

  -- Push a command onto the undo stack, respecting max_size.
  local function push_undo(cmd)
    undo_stack[#undo_stack + 1] = cmd
    if max_size and #undo_stack > max_size then
      table.remove(undo_stack, 1)
    end
  end

  -- Execute a command and record it (or accumulate if inside a batch).
  function h:execute(cmd)
    if cmd == nil then return nil, "command is nil" end
    local ok, err = pcall(cmd.execute)
    if not ok then return nil, err end
    if batch_commands then
      batch_commands[#batch_commands + 1] = cmd
    else
      -- Clear redo stack on new execution outside a batch
      redo_stack = {}
      push_undo(cmd)
    end
    return true
  end

  function h:can_undo()
    return #undo_stack > 0
  end

  function h:can_redo()
    return #redo_stack > 0
  end

  function h:undo()
    if #undo_stack == 0 then return nil, "nothing to undo" end
    local cmd = undo_stack[#undo_stack]
    undo_stack[#undo_stack] = nil
    local ok, err = pcall(cmd.undo)
    if not ok then
      -- Restore the command to the undo stack since undo failed
      undo_stack[#undo_stack + 1] = cmd
      return nil, err
    end
    redo_stack[#redo_stack + 1] = cmd
    return true
  end

  function h:redo()
    if #redo_stack == 0 then return nil, "nothing to redo" end
    local cmd = redo_stack[#redo_stack]
    redo_stack[#redo_stack] = nil
    local ok, err = pcall(cmd.execute)
    if not ok then
      redo_stack[#redo_stack + 1] = cmd
      return nil, err
    end
    push_undo(cmd)
    return true
  end

  -- batch(fn): execute fn; all commands inside are grouped as one undo step.
  function h:batch(fn)
    local prev = batch_commands
    batch_commands = {}
    local ok, err = pcall(fn)
    local collected = batch_commands
    batch_commands = prev
    if not ok then return nil, err end
    if #collected > 0 then
      local group = M.compound(collected)
      -- Don't call execute again — commands already ran. Just record.
      if batch_commands then
        batch_commands[#batch_commands + 1] = group
      else
        redo_stack = {}
        push_undo(group)
      end
    end
    return true
  end

  -- transaction(fn): like batch, but rolls back all executed commands on error.
  function h:transaction(fn)
    local prev = batch_commands
    batch_commands = {}
    local ok, err = pcall(fn)
    local collected = batch_commands
    batch_commands = prev
    if not ok then
      -- Roll back in reverse order
      for i = #collected, 1, -1 do
        pcall(collected[i].undo)
      end
      return nil, err
    end
    if #collected > 0 then
      local group = M.compound(collected)
      if batch_commands then
        batch_commands[#batch_commands + 1] = group
      else
        redo_stack = {}
        push_undo(group)
      end
    end
    return true
  end

  function h:size()
    return #undo_stack
  end

  function h:redo_size()
    return #redo_stack
  end

  function h:peek_undo()
    return undo_stack[#undo_stack]
  end

  function h:peek_redo()
    return redo_stack[#redo_stack]
  end

  -- Returns array of descriptions, oldest first (undo stack order).
  function h:list()
    local result = {}
    for i = 1, #undo_stack do
      local cmd = undo_stack[i]
      if cmd.describe then
        result[#result + 1] = cmd.describe()
      else
        result[#result + 1] = "(command)"
      end
    end
    return result
  end

  function h:clear()
    undo_stack = {}
    redo_stack = {}
  end

  return h
end

-- ---------------------------------------------------------------------------
-- queue() -> queue_obj
-- Sequential execution queue.
-- ---------------------------------------------------------------------------
function M.queue()
  local items = {}

  local q = {}

  function q:push(fn)
    items[#items + 1] = fn
  end

  function q:run_next()
    if #items == 0 then return nil, "queue is empty" end
    local fn = table.remove(items, 1)
    local ok, err = pcall(fn)
    if not ok then return nil, err end
    return true
  end

  function q:run_all()
    while #items > 0 do
      local ok, err = self:run_next()
      if not ok then return nil, err end
    end
    return true
  end

  function q:size()
    return #items
  end

  function q:clear()
    items = {}
  end

  return q
end

-- ---------------------------------------------------------------------------
-- priority_queue() -> priority_queue_obj
-- Queue ordered by priority (higher number = runs first).
-- ---------------------------------------------------------------------------
function M.priority_queue()
  -- Each entry: { fn = fn, priority = n }
  local items = {}

  local pq = {}

  function pq:push(fn, priority)
    priority = priority or 0
    items[#items + 1] = { fn = fn, priority = priority }
    -- Insertion sort to keep items ordered descending by priority
    local i = #items
    while i > 1 and items[i].priority > items[i - 1].priority do
      items[i], items[i - 1] = items[i - 1], items[i]
      i = i - 1
    end
  end

  function pq:run_next()
    if #items == 0 then return nil, "queue is empty" end
    local entry = table.remove(items, 1)
    local ok, err = pcall(entry.fn)
    if not ok then return nil, err end
    return true
  end

  function pq:run_all()
    while #items > 0 do
      local ok, err = self:run_next()
      if not ok then return nil, err end
    end
    return true
  end

  function pq:size()
    return #items
  end

  function pq:clear()
    items = {}
  end

  return pq
end

return M
