-- lib/expand_c/expand_c/init.lua
-- C macro expansion via cc -E.
-- Injects popen_fn capability so the library is sandbox-safe.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ---------------------------------------------------------------------------
-- Default standard headers included when invoking cc -E
-- ---------------------------------------------------------------------------

-- Common POSIX + standard C headers to include for symbol lookup.
local UNIX_HEADERS = [[
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <float.h>
#include <limits.h>
#include <stdint.h>
#include <wctype.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <sys/syscall.h>
#include <sys/epoll.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
]]

local WIN_HEADERS = [[
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <float.h>
#include <limits.h>
#include <stdint.h>
#include <wctype.h>
#include <errno.h>
#include <conio.h>
]]

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--:: expand_c_result = { [string]: string }

-- Expand C preprocessor macros for a list of symbol names.
-- Returns a table mapping each name to its expanded value string,
-- or nil and an error message on failure.
--
-- opts.popen_fn — required; injected popen capability.
--   Signature: popen_fn(cmd: string, mode: string) -> unknown
-- opts.platform — optional; "win" skips POSIX headers (default: auto-detect
--   from jit.os if available, otherwise "unix").
-- opts.extra_headers — optional string of additional #include directives.
--
--: ({ [integer]: string }, { popen_fn: (string, string) -> unknown, ... }) -> ({ [string]: string } | nil, string | nil)
M.expand = function(names, opts)
  if not opts or not opts.popen_fn then
    return nil, "expand_c: opts.popen_fn is required"
  end
  if #names == 0 then return {}, nil end

  local popen_fn = opts.popen_fn

  -- Detect platform for header selection
  local platform = opts.platform
  if not platform then
    -- jit is a LuaJIT global; check carefully
    local ok, jit_os = pcall(function() return (jit --[[:! { os: string }]]).os end)
    if ok and jit_os then
      platform = (jit_os == "Windows") and "win" or "unix"
    else
      platform = "unix"
    end
  end

  local headers = (platform == "win") and WIN_HEADERS or UNIX_HEADERS
  if opts.extra_headers then
    headers = headers .. (opts.extra_headers --[[:! string]]) .. "\n"
  end

  -- Build the result extraction macros.
  -- Each name N becomes: RESULT_N=__STR__(N)
  local parts = {} --: { [integer]: string }
  for _, name in ipairs(names) do
    parts[#parts + 1] = "RESULT_" .. name .. "=__STR__(" .. name .. ")\n"
  end

  -- Build the cc -E command via a here-doc piped to cc.
  local cmd = [[cat <<'END' | cc -E -
]] .. headers .. [[
#define __STR___(a) #a
#define __STR__(a) __STR___(a)
]] .. table.concat(parts) .. [[

END]]

  local raw_f = popen_fn(cmd, "r")
  if not raw_f then
    return nil, "expand_c: failed to open pipe to cc -E"
  end
  local f = raw_f --[[:! { read: (unknown, string) -> string | nil }]]

  local result = {} --: { [string]: string }
  while true do
    local line = f.read(f, "*line") --: string | nil
    if not line then break end
    local name, value = line:match("RESULT_(.-=)\"(.+)\"")
    if name and value then
      result[name:sub(1, -2)] = value  -- strip trailing "=" from name
    end
  end

  return result, nil
end

-- Convenience: expand a single symbol name.
-- Returns (value_string | nil, errmsg | nil).
--: (string, { popen_fn: (string, string) -> unknown, ... }) -> (string | nil, string | nil)
M.expand_one = function(name, opts)
  local result, err = M.expand({ name }, opts)
  if not result then return nil, err end
  return result[name], nil
end

return M
