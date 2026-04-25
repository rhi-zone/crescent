if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- opts.popen, opts.open, opts.remove, opts.tmpname are caller-injected I/O functions.
--:: RunOpts   = { popen: (string, string) -> (File | nil, string | nil), stderr: string | nil }
--:: RunExOpts = { popen: (string, string) -> (File | nil, string | nil), open: (string, string | nil) -> (File | nil, string | nil), remove: (string) -> (boolean | nil, string | nil), tmpname: () -> string }

local SENTINEL = "__EXEC_EXIT__"

-- Single-quote a string for POSIX shell.
--: (string) -> string
local function shell_quote(s)
	local escaped = s:gsub("'", "'\\''")
	return "'" .. escaped .. "'"
end

-- Build a shell command string from cmd + args list.
--: (string, string[]) -> string
local function build_cmdstr(cmd, args)
	local parts = { shell_quote(cmd) }
	for _, arg in ipairs(args or {}) do
		parts[#parts + 1] = shell_quote(arg)
	end
	return table.concat(parts, " ")
end

-- Parse the exit code sentinel appended to raw popen output.
-- Returns stdout (without sentinel line) and exit code.
-- LuaJIT popen close() does not return exit code (Lua 5.1 behaviour),
-- so we embed it as a trailing sentinel line instead.
--: (string) -> string, number
local function parse_sentinel(raw)
	local out, code_str = raw:match("^(.*)\n" .. SENTINEL .. "(%d+)\n?$")
	if out and code_str then
		return out, tonumber(code_str) or 0
	end
	return raw, 0
end

-- Run a subprocess and capture stdout.
--
-- opts.popen   fn   io.popen-compatible function (required)
-- opts.stderr  str  "merge" (2>&1) | "discard" (2>/dev/null) | nil (pass through to tty)
--
-- Returns stdout on success, or nil + errmsg on non-zero exit or popen failure.
--: (string, string[], RunOpts) -> string | nil, string | nil
function M.run(cmd, args, opts)
	local popen = opts.popen
	local cmdstr = build_cmdstr(cmd, args)

	if opts.stderr == "merge" then
		cmdstr = cmdstr .. " 2>&1"
	elseif opts.stderr == "discard" then
		cmdstr = cmdstr .. " 2>/dev/null"
	end

	local augmented = cmdstr .. "; printf '\\n" .. SENTINEL .. "%d' $?"
	local fh, err = popen(augmented, "r")
	if not fh then
		return nil, "popen: " .. tostring(err)
	end

	local raw = fh:read("*a") or ""
	fh:close()

	local out, code = parse_sentinel(raw)
	if code ~= 0 then
		return nil, cmd .. " exited with code " .. tostring(code)
	end
	return out
end

-- Run a subprocess and return stdout, stderr, and exit code separately.
-- Uses a temp file for stderr; simpler callers should prefer run().
--
-- opts.popen    fn  io.popen-compatible function (required)
-- opts.open     fn  io.open-compatible function (required)
-- opts.remove   fn  os.remove-compatible function (required)
-- opts.tmpname  fn  os.tmpname-compatible function (required)
--
-- Returns stdout, stderr, code on success, or nil + errmsg on popen failure.
--: (string, string[], RunExOpts) -> string | nil, string | nil, number | nil
function M.run_ex(cmd, args, opts)
	local popen   = opts.popen
	local open    = opts.open
	local remove  = opts.remove
	local tmpname = opts.tmpname

	local stderr_path = tmpname() .. ".stderr"
	local cmdstr    = build_cmdstr(cmd, args) .. " 2>" .. shell_quote(stderr_path)
	local augmented = cmdstr .. "; printf '\\n" .. SENTINEL .. "%d' $?"

	local fh, err = popen(augmented, "r")
	if not fh then
		remove(stderr_path)
		return nil, "popen: " .. tostring(err)
	end

	local raw = fh:read("*a") or ""
	fh:close()

	local stderr = ""
	--: File | nil
	local ef = open(stderr_path, "r")
	if ef ~= nil then
		stderr = ef:read("*a") or ""
		ef:close()
	end
	remove(stderr_path)

	local stdout, code = parse_sentinel(raw)
	if code ~= 0 then
		local msg = "exit " .. tostring(code)
		if stderr ~= "" then msg = msg .. ": " .. stderr end
		return nil, msg
	end
	return stdout, stderr, code
end

return M
