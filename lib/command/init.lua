if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local unpack = unpack or unpack  -- LuaJIT uses global unpack

-- ---------------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------------

-- M.command(spec) -> command object
-- spec: { name, execute, undo?, description? }
-- execute(ctx, state, args) -> undo_data or (nil, err)
-- undo(ctx, state, args, undo_data)
function M.command(spec)
  assert(spec and spec.name, "command requires a name")
  assert(spec.execute, "command requires an execute function")
  return {
    name        = spec.name,
    description = spec.description,
    execute     = spec.execute,
    undo        = spec.undo,
  }
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

-- Entry stored on the undo stack:
--   { command, args_list, undo_data, time, is_batch, batch_entries, name }
-- args_list is a table of varargs passed after (command) to history:execute

local History = {}
History.__index = History

-- M.history(opts?) -> history object
-- opts: { max_size, on_execute?, on_undo?, on_redo? }
function M.history(opts)
  opts = opts or {}
  local h = setmetatable({}, History)
  h._undo    = {}   -- stack of entries, index 1 = oldest
  h._redo    = {}   -- stack of entries, index 1 = most-recent-undo (redo order)
  h._max     = opts.max_size
  h._on_exec = opts.on_execute
  h._on_undo = opts.on_undo
  h._on_redo = opts.on_redo
  h._batch   = nil  -- batch accumulator or nil
  h._recording = nil  -- macro recording list or nil
  return h
end

-- internal: push an entry onto the undo stack, respecting max_size
local function push_undo(h, entry)
  local stack = h._undo
  stack[#stack + 1] = entry
  if h._max and #stack > h._max then
    table.remove(stack, 1)
  end
end

-- Execute a single command entry (does NOT push to history).
-- Returns undo_data or (nil, err).
local function raw_execute(command, args_list)
  -- args_list: { state, args, ... } — all varargs after (command)
  local ok, result = pcall(command.execute, unpack(args_list))
  if not ok then
    return nil, result
  end
  return result
end

-- Undo a single entry (does NOT manipulate stacks).
-- Returns true or (false, err).
local function raw_undo(entry)
  if entry.is_batch then
    -- undo in reverse order
    for i = #entry.batch_entries, 1, -1 do
      local sub = entry.batch_entries[i]
      local ok, err = raw_undo(sub)
      if not ok then return false, err end
    end
    return true
  end
  local command = entry.command
  if not command.undo then
    return false, "command '" .. command.name .. "' does not support undo"
  end
  -- undo(ctx, state, args, undo_data) — same varargs as execute plus undo_data appended
  local args = entry.args_list
  -- build call: command.undo(args[1], args[2], ..., undo_data)
  local all = {}
  for i = 1, #args do all[i] = args[i] end
  all[#all + 1] = entry.undo_data
  local ok, err = pcall(command.undo, unpack(all))
  if not ok then return false, err end
  return true
end

-- Re-execute an entry (for redo). Returns undo_data or (nil, err).
local function raw_redo(entry)
  if entry.is_batch then
    local new_batch_entries = {}
    for i = 1, #entry.batch_entries do
      local sub = entry.batch_entries[i]
      local undo_data, err = raw_execute(sub.command, sub.args_list)
      if undo_data == nil and err then
        -- partial redo failed — undo what we've done so far in reverse
        for j = i - 1, 1, -1 do
          raw_undo(new_batch_entries[j])
        end
        return nil, err
      end
      new_batch_entries[i] = {
        command   = sub.command,
        args_list = sub.args_list,
        undo_data = undo_data,
        time      = os.time(),
      }
    end
    entry.batch_entries = new_batch_entries
    return true
  end
  local undo_data, err = raw_execute(entry.command, entry.args_list)
  if undo_data == nil and err then return nil, err end
  entry.undo_data = undo_data
  return undo_data
end

-- history:execute(command, ...) -> undo_data or (nil, err)
-- All args after command are forwarded to command.execute
function History:execute(command, ...)
  local args_list = { ... }

  if self._batch then
    -- Accumulate into batch
    local undo_data, err = raw_execute(command, args_list)
    if undo_data == nil and err then return nil, err end
    local entry = {
      command   = command,
      args_list = args_list,
      undo_data = undo_data,
      time      = os.time(),
    }
    self._batch[#self._batch + 1] = entry
    if self._on_exec then self._on_exec(command, ...) end
    if self._recording then
      self._recording[#self._recording + 1] = { command = command, args_list = args_list }
    end
    return undo_data
  end

  local undo_data, err = raw_execute(command, args_list)
  if undo_data == nil and err then return nil, err end

  local entry = {
    command   = command,
    args_list = args_list,
    undo_data = undo_data,
    time      = os.time(),
    name      = command.name,
  }
  push_undo(self, entry)
  -- New execute clears redo stack
  self._redo = {}

  if self._on_exec then self._on_exec(command, ...) end
  if self._recording then
    self._recording[#self._recording + 1] = { command = command, args_list = args_list }
  end
  return undo_data
end

-- history:undo(...) -> bool
-- Varargs are passed as the first args to command.undo (ctx, state — same as execute)
function History:undo(...)
  local stack = self._undo
  if #stack == 0 then return false end
  local entry = stack[#stack]
  local ok, err = raw_undo(entry)
  if not ok then return false, err end
  stack[#stack] = nil
  self._redo[#self._redo + 1] = entry
  if self._on_undo then self._on_undo(entry.command or entry) end
  return true
end

-- history:redo(...) -> bool
function History:redo(...)
  local stack = self._redo
  if #stack == 0 then return false end
  local entry = stack[#stack]
  local _, err = raw_redo(entry)
  if err then return false, err end
  stack[#stack] = nil
  push_undo(self, entry)
  if self._on_redo then self._on_redo(entry.command or entry) end
  return true
end

function History:can_undo()
  return #self._undo > 0
end

function History:can_redo()
  return #self._redo > 0
end

function History:undo_depth()
  return #self._undo
end

function History:redo_depth()
  return #self._redo
end

-- history:entries() -> array of { command, args, time }
function History:entries()
  local result = {}
  for i = 1, #self._undo do
    local e = self._undo[i]
    result[i] = {
      command = e.command or e,
      name    = e.name or (e.command and e.command.name),
      args    = e.args_list,
      time    = e.time,
    }
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Batch / Transaction
-- ---------------------------------------------------------------------------

function History:begin_batch()
  if self._batch then
    error("begin_batch called while batch already in progress")
  end
  self._batch = {}
end

function History:commit_batch(name)
  if not self._batch then
    error("commit_batch called without begin_batch")
  end
  local entries = self._batch
  self._batch = nil
  if #entries == 0 then return end
  local batch_entry = {
    is_batch      = true,
    batch_entries = entries,
    name          = name or "batch",
    time          = os.time(),
    command       = { name = name or "batch" },  -- for callbacks
  }
  push_undo(self, batch_entry)
  self._redo = {}
end

function History:rollback_batch()
  if not self._batch then
    error("rollback_batch called without begin_batch")
  end
  local entries = self._batch
  self._batch = nil
  -- Undo all accumulated entries in reverse
  for i = #entries, 1, -1 do
    raw_undo(entries[i])
  end
end

-- history:transaction(name, fn) -> true or (false, err)
-- fn errors cause rollback of all commands executed during the transaction
function History:transaction(name, fn)
  self:begin_batch()
  local ok, err = pcall(fn)
  if ok then
    self:commit_batch(name)
    return true
  else
    self:rollback_batch()
    return false, err
  end
end

-- ---------------------------------------------------------------------------
-- Clear
-- ---------------------------------------------------------------------------

function History:clear()
  self._undo = {}
  self._redo = {}
end

function History:clear_redo()
  self._redo = {}
end

-- ---------------------------------------------------------------------------
-- Macro recording / playback
-- ---------------------------------------------------------------------------

-- history:record() — starts recording subsequent execute calls
function History:record()
  if self._recording then
    error("record called while already recording")
  end
  self._recording = {}
end

-- history:stop_record() -> macro (list of {command, args_list})
function History:stop_record()
  if not self._recording then
    error("stop_record called without record")
  end
  local macro = self._recording
  self._recording = nil
  return macro
end

-- history:play(macro, ...) — replay a macro; same varargs prepend is NOT done;
-- the recorded args_list is replayed verbatim (the state/ctx were captured at record time)
function History:play(macro, ...)
  for i = 1, #macro do
    local step = macro[i]
    -- If caller passed new args, use them; otherwise use recorded args
    local args_list
    if select("#", ...) > 0 then
      -- Caller provided leading args to override; splice into front of args_list
      -- Convention: the recorded args_list[1] is ctx/state, so we replace index 1..n
      -- with the passed varargs, keeping the rest (args table) from recording.
      local passed = { ... }
      args_list = {}
      for j = 1, #passed do args_list[j] = passed[j] end
      -- append remaining recorded args beyond the replaced positions
      for j = #passed + 1, #step.args_list do
        args_list[#args_list + 1] = step.args_list[j]
      end
    else
      args_list = step.args_list
    end
    local undo_data, err = raw_execute(step.command, args_list)
    if undo_data == nil and err then return nil, err end
    local entry = {
      command   = step.command,
      args_list = args_list,
      undo_data = undo_data,
      time      = os.time(),
      name      = step.command.name,
    }
    push_undo(self, entry)
    self._redo = {}
    if self._on_exec then self._on_exec(step.command, unpack(args_list)) end
  end
  return true
end

return M
