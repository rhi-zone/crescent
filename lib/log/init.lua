if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Structured logging with levels and sinks.
-- Callers create named loggers via log.new(); no global logger is forced.
-- Sinks receive structured entry tables and format independently.

local M = {}

-- ---------------------------------------------------------------------------
-- Level constants
-- ---------------------------------------------------------------------------

M.TRACE = 0
M.DEBUG = 1
M.INFO  = 2
M.WARN  = 3
M.ERROR = 4

--:: LevelName = "trace" | "debug" | "info" | "warn" | "error"

local LEVEL_NAMES = { [0] = "TRACE", [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }
local LEVEL_NAMES_LOWER = { [0] = "trace", [1] = "debug", [2] = "info", [3] = "warn", [4] = "error" }

--:: LevelByName = { [string]: integer }
--: LevelByName
local LEVEL_BY_NAME = {
  trace = M.TRACE,
  debug = M.DEBUG,
  info  = M.INFO,
  warn  = M.WARN,
  error = M.ERROR,
}

-- ---------------------------------------------------------------------------
-- Entry type
-- ---------------------------------------------------------------------------

--:: Entry = { level: integer, name: string, msg: string, fields: { [string]: unknown }, time: string }

-- ---------------------------------------------------------------------------
-- Formatters
-- ---------------------------------------------------------------------------

-- Serialize a fields table into key=value pairs (text format).
-- Returns "" when fields is nil or empty.
--: ({ [string]: unknown }) -> string
local function fields_to_text(fields)
  if fields == nil then return "" end
  local parts = {}
  for k, v in pairs(fields) do
    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
  end
  if #parts == 0 then return "" end
  return " " .. table.concat(parts, " ")
end

-- Escape a string value for JSON (minimal: only handles printable ASCII safely).
--: (string) -> string
local function json_escape(s)
  local r = s:gsub('\\', '\\\\')
  r = r:gsub('"', '\\"')
  r = r:gsub('\n', '\\n')
  r = r:gsub('\r', '\\r')
  r = r:gsub('\t', '\\t')
  return r
end

-- Serialize a value to a JSON fragment (string, number, boolean, or fallback string).
-- Accepts any Lua value; branches on type() and tostring()s the rest.
--: (unknown) -> string
local function json_value(v)
  local t = type(v)
  if t == "string" then
    return '"' .. json_escape(tostring(v)) .. '"'
  elseif t == "number" then
    return tostring(v)
  elseif t == "boolean" then
    return v and "true" or "false"
  else
    return '"' .. json_escape(tostring(v)) .. '"'
  end
end

-- Format an entry as a plain text line.
--: (Entry) -> string
local function format_text(entry)
  local level_str = LEVEL_NAMES[entry.level] or "?"
  -- Pad level string to 5 characters for alignment.
  while #level_str < 5 do level_str = level_str .. " " end
  return entry.time .. " " .. level_str .. " [" .. entry.name .. "] " .. entry.msg
    .. fields_to_text(entry.fields) .. "\n"
end

-- Format an entry as a JSON object (one line).
--: (Entry) -> string
local function format_json(entry)
  local parts = {
    '"time":' .. json_value(entry.time),
    '"level":' .. json_value(LEVEL_NAMES_LOWER[entry.level] or "?"),
    '"logger":' .. json_value(entry.name),
    '"msg":' .. json_value(entry.msg),
  }
  if entry.fields ~= nil then
    for k, v in pairs(entry.fields) do
      parts[#parts + 1] = json_value(tostring(k)) .. ":" .. json_value(v)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}\n"
end

-- Lazy-load ansi to avoid a hard dependency.
local _ansi
local function get_ansi()
  if _ansi == nil then
    local ok, a = pcall(require, "lib.ansi")
    _ansi = ok and a or false
  end
  return _ansi
end

-- ANSI color per level.
--: (integer, string) -> string
local function level_colored(level, s)
  local ansi = get_ansi()
  if not ansi or not ansi.enabled then return s end
  if level == M.TRACE then return ansi.dim(s)
  elseif level == M.DEBUG then return ansi.cyan(s)
  elseif level == M.INFO then return ansi.green(s)
  elseif level == M.WARN then return ansi.yellow(s)
  elseif level == M.ERROR then return ansi.bold(ansi.red(s))
  else return s
  end
end

-- Format an entry with ANSI colors.
--: (Entry) -> string
local function format_ansi(entry)
  local ansi = get_ansi()
  local level_str = LEVEL_NAMES[entry.level] or "?"
  while #level_str < 5 do level_str = level_str .. " " end
  local colored_level = level_colored(entry.level, level_str)
  local fields_str = ""
  if entry.fields ~= nil then
    local parts = {}
    for k, v in pairs(entry.fields) do
      local pair = tostring(k) .. "=" .. tostring(v)
      parts[#parts + 1] = (ansi and ansi.enabled) and ansi.dim(pair) or pair
    end
    if #parts > 0 then
      fields_str = " " .. table.concat(parts, " ")
    end
  end
  return entry.time .. " " .. colored_level .. " [" .. entry.name .. "] " .. entry.msg .. fields_str .. "\n"
end

-- ---------------------------------------------------------------------------
-- Built-in sinks
-- ---------------------------------------------------------------------------

-- Detect whether stderr is a tty (fd 2).
local function stderr_is_tty()
  local ffi_ok, ffi = pcall(require, "ffi")
  if not ffi_ok then return false end
  local ok, result = pcall(function()
    -- isatty may already be declared; ignore redeclaration errors.
    pcall(function() ffi.cdef [[ int isatty(int fd); ]] end)
    return ffi.C.isatty(2) == 1
  end)
  return ok and result or false
end

-- Choose the default format for an output (ansi when tty, else text).
--: (boolean) -> string
local function default_format(is_tty)
  local ansi = get_ansi()
  if is_tty and ansi and ansi.enabled then return "ansi" end
  return "text"
end

-- Return a formatter function for the given format name.
--: (string) -> (Entry) -> string
local function get_formatter(fmt)
  if fmt == "json" then return format_json
  elseif fmt == "ansi" then return format_ansi
  else return format_text
  end
end

--:: FileHandle = { write: (FileHandle, string) -> (), close: (FileHandle) -> () }

-- Create a sink that writes to a file handle.
--: (FileHandle, string) -> (Entry) -> nil
local function handle_sink(handle, fmt)
  local formatter = get_formatter(fmt)
  return function(entry)
    handle:write(formatter(entry))
  end
end

-- Sink writing to stderr.
--: (({ format: (string  | nil)} | nil)) -> (Entry) -> nil
M.stderr_sink = function(opts)
  opts = opts or { format = nil } --[[: { format: string | nil } ]]
  local fmt = opts.format or default_format(stderr_is_tty())
  return handle_sink(io.stderr --[[:! { close: (FileHandle) -> (), write: (FileHandle, string) -> () }]], fmt)
end

-- Sink writing to stdout.
--: (({ format: (string  | nil)} | nil)) -> (Entry) -> nil
M.stdout_sink = function(opts)
  opts = opts or { format = nil } --[[: { format: string | nil } ]]
  local ansi = get_ansi()
  local is_tty = ansi and ansi.enabled or false
  local fmt = opts.format or default_format(is_tty)
  return handle_sink(io.stdout --[[:! { close: (FileHandle) -> (), write: (FileHandle, string) -> () }]], fmt)
end

-- Sink appending to a file on disk.
-- write_fn: function(path, data) -> true|nil, string|nil (required). Opens path
-- in append mode and writes data.
--: ((string, string) -> (boolean | nil, string | nil), string, ({ format: (string  | nil)} | nil)) -> (Entry) -> nil
M.file_sink = function(write_fn, path, opts)
  if type(write_fn) ~= "function" then
    error("log.file_sink: write_fn function is required")
  end
  opts = opts or { format = nil } --[[: { format: string | nil } ]]
  local fmt = opts.format or "text"
  local formatter = get_formatter(fmt)
  return function(entry)
    write_fn(path, formatter(entry))
  end
end

-- Sink that buffers entries in memory; returns sink + get_entries().
-- Useful for testing.
--: () -> ((Entry) -> nil, () -> Entry[])
M.collect_sink = function()
  local entries = {}
  local function sink(entry)
    entries[#entries + 1] = entry
  end
  local function get_entries()
    return entries
  end
  return sink, get_entries
end

-- ---------------------------------------------------------------------------
-- Logger
-- ---------------------------------------------------------------------------

--:: SinkList = { [integer]: (Entry) -> nil }
-- LoggerObj is the logger struct type (distinct from the Logger metatable local).
--:: LoggerObj = { _name: string, _level: integer, _sinks: { [integer]: (Entry) -> nil }, _time_fn: () -> string }

local Logger = {}
Logger.__index = Logger

-- Emit an entry at the given level (internal).
--: (LoggerObj, integer, string, ({ [string]: unknown }) | nil) -> nil
local function emit(self, level, msg, fields)
  if level < self._level then return end
  local entry = {
    level  = level,
    name   = self._name,
    msg    = msg,
    fields = fields,
    time   = self._time_fn(),
  }
  local sinks = self._sinks
  for i = 1, #sinks do
    sinks[i](entry)
  end
end

--: (LoggerObj, string, ({ [string]: unknown } | nil)) -> nil
Logger.trace = function(self, msg, fields) emit(self, M.TRACE, msg, fields) end

--: (LoggerObj, string, ({ [string]: unknown } | nil)) -> nil
Logger.debug = function(self, msg, fields) emit(self, M.DEBUG, msg, fields) end

--: (LoggerObj, string, ({ [string]: unknown } | nil)) -> nil
Logger.info = function(self, msg, fields) emit(self, M.INFO, msg, fields) end

--: (LoggerObj, string, ({ [string]: unknown } | nil)) -> nil
Logger.warn = function(self, msg, fields) emit(self, M.WARN, msg, fields) end

--: (LoggerObj, string, ({ [string]: unknown } | nil)) -> nil
Logger.error = function(self, msg, fields) emit(self, M.ERROR, msg, fields) end

-- Change minimum level dynamically.
-- Accepts a level name string ("trace".."error") or an integer constant.
--: (LoggerObj, string | integer) -> nil
Logger.set_level = function(self, level)
  if type(level) == "string" then
    self._level = LEVEL_BY_NAME[level] or M.INFO
  else
    self._level = level
  end
end

-- Add a sink.
--: (LoggerObj, (Entry) -> nil) -> nil
Logger.add_sink = function(self, sink)
  self._sinks[#self._sinks + 1] = sink
end

-- Remove a sink (by identity).
--: (LoggerObj, (Entry) -> nil) -> nil
Logger.remove_sink = function(self, sink)
  local sinks = self._sinks
  for i = 1, #sinks do
    if sinks[i] == sink then
      table.remove(sinks, i)
      return
    end
  end
end

-- Create a child logger inheriting parent's sinks and level, prefixing name.
--: (LoggerObj, string) -> LoggerObj
Logger.child = function(self, suffix)
  return setmetatable({
    _name    = self._name .. "." .. suffix,
    _level   = self._level,
    _sinks   = self._sinks,
    _time_fn = self._time_fn,
  }, Logger)
end

-- ---------------------------------------------------------------------------
-- Public constructor
-- ---------------------------------------------------------------------------

-- Create a new logger.
-- opts.level : string or integer minimum level (default "info")
-- opts.sinks : array of sink functions (default: {log.stderr_sink()})
-- opts.time_fn : function returning timestamp string (required)
--: (string, { level: (string | integer) | nil, sinks: ({ [integer]: (Entry) -> nil }) | nil, time_fn: () -> string } | nil) -> LoggerObj
M.new = function(name, opts)
  opts = opts or {} --[[:! { level: (string | integer) | nil, sinks: ({ [integer]: (Entry) -> nil }) | nil, time_fn: () -> string }]]
  local level = opts.level or "info"
  if type(level) == "string" then
    level = LEVEL_BY_NAME[level] or M.INFO
  end
  local sinks = opts.sinks
  if sinks == nil then
    sinks = { M.stderr_sink() }
  end
  return setmetatable({
    _name    = name,
    _level   = level,
    _sinks   = sinks,
    _time_fn = opts.time_fn,
  }, Logger)
end

return M
