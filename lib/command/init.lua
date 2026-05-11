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

--:: HistCmd = { name: string, execute: unknown, undo: unknown, description: unknown }
--:: HistEntry = { command: HistCmd, args_list: { [integer]: unknown }, undo_data: unknown, time: unknown, name: unknown, is_batch: unknown, batch_entries: unknown }
--:: HistObj = { _undo: { [integer]: HistEntry }, _redo: { [integer]: HistEntry }, _max: unknown, _on_exec: unknown, _on_undo: unknown, _on_redo: unknown, _batch: unknown, _recording: unknown, _time_fn: () -> unknown }

local History = {}
History.__index = History

-- M.history(opts?) -> history object
-- opts: { max_size, on_execute?, on_undo?, on_redo? }
function M.history(opts)
  assert(opts and opts.time_fn, "history requires opts.time_fn")
  local opts_any = opts --[[: unknown]]
  local opts_ = opts_any --[[:! { time_fn: () -> unknown, max_size: unknown, on_execute: unknown, on_undo: unknown, on_redo: unknown, ... }]]
  local h_any = setmetatable({}, History) --[[: unknown]]
  local h = h_any --[[:! HistObj]]
  h._undo    = {}   -- stack of entries, index 1 = oldest
  h._redo    = {}   -- stack of entries, index 1 = most-recent-undo (redo order)
  h._max     = opts_.max_size
  h._on_exec = opts_.on_execute
  h._on_undo = opts_.on_undo
  h._on_redo = opts_.on_redo
  h._batch   = nil  -- batch accumulator or nil
  h._recording = nil  -- macro recording list or nil
  h._time_fn = opts_.time_fn
  return h
end

-- internal: push an entry onto the undo stack, respecting max_size
--: (HistObj, HistEntry) -> nil
local function push_undo(h, entry)
  local h_ = h --[[:! HistObj]]
  local entry_ = entry --[[:! HistEntry]]
  local stack = h_._undo
  stack[#stack + 1] = entry_
  if h_._max and #stack > h_._max then
    table.remove(stack, 1)
  end
end

-- Execute a single command entry (does NOT push to history).
-- Returns undo_data or (nil, err).
--: (HistCmd, { [integer]: unknown }) -> unknown
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
  local entry_ = entry --[[:! HistEntry]]
  if entry_.is_batch then
    -- undo in reverse order
    local batch = entry_.batch_entries --[[:! { [integer]: HistEntry }]]
    for i = #batch, 1, -1 do
      local sub = batch[i]
      local ok, err = raw_undo(sub)
      if not ok then return false, err end
    end
    return true
  end
  local command = entry_.command
  if not command.undo then
    return false, "command '" .. command.name .. "' does not support undo"
  end
  -- undo(ctx, state, args, undo_data) — same varargs as execute plus undo_data appended
  local args = entry_.args_list
  -- build call: command.undo(args[1], args[2], ..., undo_data)
  local all = {} --: { [integer]: unknown }
  for i = 1, #args do all[i] = args[i] end
  all[#all + 1] = entry_.undo_data
  local ok, err = pcall(command.undo, unpack(all))
  if not ok then return false, err end
  return true
end

-- Re-execute an entry (for redo). Returns undo_data or (nil, err).
local function raw_redo(entry, time_fn)
  local entry_ = entry --[[:! HistEntry]]
  local time_fn_ = time_fn --[[:! () -> unknown]]
  if entry_.is_batch then
    local new_batch_entries = {} --: { [integer]: HistEntry }
    local batch = entry_.batch_entries --[[:! { [integer]: HistEntry }]]
    for i = 1, #batch do
      local sub = batch[i]
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
        time      = time_fn_(),
        name      = sub.name,
        is_batch  = false,
        batch_entries = nil,
      }
    end
    entry_.batch_entries = new_batch_entries
    return true
  end
  local undo_data, err = raw_execute(entry_.command, entry_.args_list)
  if undo_data == nil and err then return nil, err end
  entry_.undo_data = undo_data
  return undo_data
end

-- history:execute(command, ...) -> undo_data or (nil, err)
-- All args after command are forwarded to command.execute
--: (self: HistObj, command: HistCmd, ...unknown) -> unknown
function History:execute(command, ...)
  local args_list = { ... } --: { [integer]: unknown }

  if self._batch then
    -- Accumulate into batch
    local undo_data, err = raw_execute(command, args_list)
    if undo_data == nil and err then return nil, err end
    local entry_any = {
      command   = command,
      args_list = args_list,
      undo_data = undo_data,
      time      = self._time_fn(),
      name      = nil,
      is_batch  = false,
      batch_entries = nil,
    } --[[: unknown]]
    local entry = entry_any --[[:! HistEntry]]
    local batch = self._batch --[[:! { [integer]: HistEntry }]]
    batch[#batch + 1] = entry
    local on_exec = self._on_exec
    if on_exec then (on_exec --[[:! (...unknown) -> unknown]])(command, ...) end
    local rec = self._recording
    if rec then
      local recording = rec --[[:! { [integer]: { command: HistCmd, args_list: { [integer]: unknown } } }]]
      recording[#recording + 1] = { command = command, args_list = args_list }
    end
    return undo_data
  end

  local undo_data, err = raw_execute(command, args_list)
  if undo_data == nil and err then return nil, err end

  local entry = {
    command   = command,
    args_list = args_list,
    undo_data = undo_data,
    time      = self._time_fn(),
    name      = command.name,
    is_batch  = false,
    batch_entries = nil,
  } --: HistEntry
  push_undo(self, entry)
  -- New execute clears redo stack
  self._redo = {}

  local on_exec = self._on_exec
  if on_exec then (on_exec --[[:! (...unknown) -> unknown]])(command, ...) end
  local rec = self._recording
  if rec then
    local recording = rec --[[:! { [integer]: { command: HistCmd, args_list: { [integer]: unknown } } }]]
    recording[#recording + 1] = { command = command, args_list = args_list }
  end
  return undo_data
end

-- history:undo(...) -> bool
-- Varargs are passed as the first args to command.undo (ctx, state — same as execute)
--: (self: HistObj, ...unknown) -> (boolean | nil, string | nil)
function History:undo(...)
  local stack = self._undo
  if #stack == 0 then return false end
  local entry = stack[#stack]
  local ok, err = raw_undo(entry)
  if not ok then return false, tostring(err) end
  stack[#stack] = nil
  self._redo[#self._redo + 1] = entry
  local on_undo = self._on_undo
  if on_undo then (on_undo --[[:! (unknown) -> unknown]])(entry.command or entry) end
  return true
end

-- history:redo(...) -> bool
--: (self: HistObj, ...unknown) -> (boolean | nil, string | nil)
function History:redo(...)
  local stack = self._redo
  if #stack == 0 then return false end
  local entry = stack[#stack]
  local _, err = raw_redo(entry, self._time_fn)
  if err then return false, tostring(err) end
  stack[#stack] = nil
  push_undo(self, entry)
  local on_redo = self._on_redo
  if on_redo then (on_redo --[[:! (unknown) -> unknown]])(entry.command or entry) end
  return true
end

--: (self: HistObj) -> boolean
function History:can_undo()
  return #self._undo > 0
end

--: (self: HistObj) -> boolean
function History:can_redo()
  return #self._redo > 0
end

--: (self: HistObj) -> integer
function History:undo_depth()
  return #self._undo
end

--: (self: HistObj) -> integer
function History:redo_depth()
  return #self._redo
end

-- history:entries() -> array of { command, args, time }
--: (self: HistObj) -> { [integer]: unknown }
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

--: (self: HistObj) -> nil
function History:begin_batch()
  if self._batch then
    error("begin_batch called while batch already in progress")
  end
  self._batch = {}
end

--: (self: HistObj, name: string | nil) -> nil
function History:commit_batch(name)
  if not self._batch then
    error("commit_batch called without begin_batch")
  end
  local entries = self._batch --[[:! { [integer]: HistEntry }]]
  self._batch = nil
  if #entries == 0 then return end
  local batch_entry = {
    is_batch      = true,
    batch_entries = entries,
    name          = name or "batch",
    time          = self._time_fn(),
    command       = { name = name or "batch", execute = nil, undo = nil, description = nil },
    args_list     = {},
    undo_data     = nil,
  } --[[:! HistEntry]]
  push_undo(self, batch_entry)
  self._redo = {}
end

--: (self: HistObj) -> nil
function History:rollback_batch()
  if not self._batch then
    error("rollback_batch called without begin_batch")
  end
  local entries = self._batch --[[:! { [integer]: HistEntry }]]
  self._batch = nil
  -- Undo all accumulated entries in reverse
  for i = #entries, 1, -1 do
    raw_undo(entries[i])
  end
end

-- history:transaction(name, fn) -> true or (false, err)
-- fn errors cause rollback of all commands executed during the transaction
--: (self: HistObj, name: string | nil, fn: () -> nil) -> (boolean, string | nil)
function History:transaction(name, fn)
  History.begin_batch(self)
  local ok, err = pcall(fn)
  if ok then
    History.commit_batch(self, name)
    return true
  else
    History.rollback_batch(self)
    return false, err
  end
end

-- ---------------------------------------------------------------------------
-- Clear
-- ---------------------------------------------------------------------------

--: (self: HistObj) -> nil
function History:clear()
  self._undo = {}
  self._redo = {}
end

--: (self: HistObj) -> nil
function History:clear_redo()
  self._redo = {}
end

-- ---------------------------------------------------------------------------
-- Macro recording / playback
-- ---------------------------------------------------------------------------

-- history:record() — starts recording subsequent execute calls
--: (self: HistObj) -> nil
function History:record()
  if self._recording then
    error("record called while already recording")
  end
  self._recording = {}
end

-- history:stop_record() -> macro (list of {command, args_list})
--: (self: HistObj) -> unknown
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
--: (self: HistObj, macro: { [integer]: unknown }, ...unknown) -> (boolean | nil, string | nil)
function History:play(macro, ...)
  for i = 1, #macro do
    local step = macro[i] --[[:! { command: HistCmd, args_list: { [integer]: unknown } }]]
    -- If caller passed new args, use them; otherwise use recorded args
    local args_list --: { [integer]: unknown } | nil
    if select("#", ...) > 0 then
      -- Caller provided leading args to override; splice into front of args_list
      -- Convention: the recorded args_list[1] is ctx/state, so we replace index 1..n
      -- with the passed varargs, keeping the rest (args table) from recording.
      local passed = { ... } --: { [integer]: unknown }
      local al = {} --: { [integer]: unknown }
      for j = 1, #passed do al[j] = passed[j] end
      -- append remaining recorded args beyond the replaced positions
      for j = #passed + 1, #step.args_list do
        al[#al + 1] = step.args_list[j]
      end
      args_list = al
    else
      args_list = step.args_list
    end
    local al_ = (args_list or step.args_list) --[[:! { [integer]: unknown }]]
    local undo_data, err = raw_execute(step.command, al_)
    if undo_data == nil and err then return nil, err end
    local entry = {
      command   = step.command,
      args_list = al_,
      undo_data = undo_data,
      time      = self._time_fn(),
      name      = step.command.name,
      is_batch  = false,
      batch_entries = nil,
    } --: HistEntry
    push_undo(self, entry)
    self._redo = {}
    local on_exec = self._on_exec
    if on_exec then (on_exec --[[:! (...unknown) -> unknown]])(step.command, unpack(al_)) end
  end
  return true
end

return M
