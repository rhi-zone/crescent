if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- opts.popen and opts.tmpfile are caller-injected functions; `any` is intentional —
-- the typechecker cannot know the concrete signature at the call site.
--:: RunOpts   = { popen: any, stderr: string | nil }
--:: RunExOpts = { popen: any, tmpfile: any }

local SENTINEL = "__EXEC_EXIT__"

-- Single-quote a string for POSIX shell.
--: (string) -> string
local function shell_quote(s)
	-- Local assignment adjusts gsub's two returns to one.
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
-- opts.popen   fn   injected io.popen (required in sandboxes; defaults to io.popen outside)
-- opts.stderr  str  "merge" (2>&1) | "discard" (2>/dev/null) | nil (pass through to tty)
--
-- Returns stdout on success, or nil + errmsg on non-zero exit or popen failure.
--: (string, string[], RunOpts | nil) -> string | nil, string | nil
function M.run(cmd, args, opts)
	--: any
	local popen = opts and opts.popen or io.popen
	local cmdstr = build_cmdstr(cmd, args)

	if opts and opts.stderr == "merge" then
		cmdstr = cmdstr .. " 2>&1"
	elseif opts and opts.stderr == "discard" then
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
-- opts.popen    fn  injected io.popen
-- opts.tmpfile  fn  injected temp path factory (suffix) -> path; defaults to os.tmpname
--
-- Returns stdout, stderr, code on success, or nil + errmsg on popen failure.
--: (string, string[], RunExOpts | nil) -> string | nil, string | nil, number | nil
function M.run_ex(cmd, args, opts)
	--: any
	local popen   = opts and opts.popen   or io.popen
	--: any
	local tmpfile = opts and opts.tmpfile or function(s) return os.tmpname() .. (s or "") end

	local stderr_path = tmpfile(".stderr")
	local cmdstr    = build_cmdstr(cmd, args) .. " 2>" .. shell_quote(stderr_path)
	local augmented = cmdstr .. "; printf '\\n" .. SENTINEL .. "%d' $?"

	local fh, err = popen(augmented, "r")
	if not fh then
		os.remove(stderr_path)
		return nil, "popen: " .. tostring(err)
	end

	local raw = fh:read("*a") or ""
	fh:close()

	local stderr = ""
	local ef = io.open(stderr_path, "r")
	if ef ~= nil then
		--: any  -- narrowing file*|nil to file* not yet supported by typechecker
		local fef = ef
		stderr = fef:read("*a") or ""
		fef:close()
	end
	os.remove(stderr_path)

	local stdout, code = parse_sentinel(raw)
	if code ~= 0 then
		local msg = "exit " .. tostring(code)
		if stderr ~= "" then msg = msg .. ": " .. stderr end
		return nil, msg
	end
	return stdout, stderr, code
end

return M
