-- lib/platform/caps/shell.lua
-- shell_cap() -> cap_table, revoke_fn
-- Runs arbitrary shell command strings. stdout and stderr merged.
--
-- Capability API:
--   cap.run(cmd) -> output: string | nil, err: string
--   cap.run_stream(cmd) -> iter | nil, err
--     iter() returns:
--       (line, nil)  — one stdout line (trailing newline stripped) per call
--       (nil, nil)   — end of stream
--       (nil, err)   — read error
--     iter:close() terminates the underlying process. Idempotent. Safe to
--     call after EOF.
--   cap.attenuate(sub_decl) -> sub_cap, sub_revoke_fn | nil, errmsg
--     sub_decl.type = "shell" (default) | "exec"
--     When type="exec", sub_decl is forwarded to exec_caps.new as manifest_entry.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Build a streaming iterator wrapping a popen file handle.
-- Returns a callable table with a :close method (idempotent).
--: (unknown) -> unknown
local function make_line_iter(fh_in)
	local fh = fh_in --: any
	local closed = false
	local iter = {} --: any
	setmetatable(iter, { __call = function(_self) --: (any) -> string | nil, string | nil
		if closed then return nil, nil end
		local line = fh:read("*l")
		if line == nil then
			closed = true
			pcall(fh.close, fh)
			return nil, nil
		end
		return line, nil
	end })
	function iter:close()
		if closed then return end
		closed = true
		pcall(fh.close, fh)
	end
	return iter
end

local function open_stream(cmd)
	if type(cmd) ~= "string" then return nil, "shell: command must be a string" end
	local fh, err = io.popen(cmd .. " 2>&1", "r")
	if not fh then return nil, "shell: popen failed: " .. tostring(err) end
	return make_line_iter(fh)
end

function M.shell_cap()
	local revoked = false

	local function attenuate(sub_decl)
		if revoked then return nil, "capability revoked" end

		--: any
		local sd = sub_decl or {}
		local sub_type = sd.type or "shell"

		if sub_type == "shell" then
			local sub_revoked = false

			local sub_cap = {
				_type = "shell",
				run = function(cmd)
					if sub_revoked then return nil, "shell: capability revoked" end
					if revoked then return nil, "shell: capability revoked" end
					if type(cmd) ~= "string" then return nil, "shell: command must be a string" end
					local fh, err = io.popen(cmd .. " 2>&1", "r")
					if not fh then return nil, "shell: popen failed: " .. tostring(err) end
					local out = fh:read("*a")
					fh:close()
					return out or ""
				end,
				run_stream = function(cmd)
					if sub_revoked then return nil, "shell: capability revoked" end
					if revoked then return nil, "shell: capability revoked" end
					return open_stream(cmd)
				end,
			}

			-- attenuate on sub_cap produces further shell sub-caps chained through
			-- sub_revoked and the parent's revoked.
			sub_cap.attenuate = function(inner_decl)
				if sub_revoked then return nil, "capability revoked" end
				if revoked then return nil, "capability revoked" end

				--: any
				local id = inner_decl or {}
				local inner_type = id.type or "shell"

				if inner_type == "shell" then
					local inner_revoked = false
					local inner_cap = {
						_type = "shell",
						run = function(cmd)
							if inner_revoked then return nil, "shell: capability revoked" end
							if sub_revoked then return nil, "shell: capability revoked" end
							if revoked then return nil, "shell: capability revoked" end
							if type(cmd) ~= "string" then return nil, "shell: command must be a string" end
							local fh, err = io.popen(cmd .. " 2>&1", "r")
							if not fh then return nil, "shell: popen failed: " .. tostring(err) end
							local out = fh:read("*a")
							fh:close()
							return out or ""
						end,
						run_stream = function(cmd)
							if inner_revoked then return nil, "shell: capability revoked" end
							if sub_revoked   then return nil, "shell: capability revoked" end
							if revoked       then return nil, "shell: capability revoked" end
							return open_stream(cmd)
						end,
					}
					-- Further attenuation not implemented at this depth; add if needed.
					inner_cap.attenuate = function()
						return nil, "attenuation depth limit reached"
					end
					local function inner_revoke() inner_revoked = true end
					return inner_cap, inner_revoke
				elseif inner_type == "exec" then
					local exec_caps = require("lib.platform.caps.exec")
					return exec_caps.new(inner_decl, {
						parent_revoked_fn = function()
							return sub_revoked or revoked
						end,
					})
				else
					return nil, "unknown attenuation type: " .. tostring(inner_type)
				end
			end

			local function sub_revoke() sub_revoked = true end
			return sub_cap, sub_revoke

		elseif sub_type == "exec" then
			local exec_caps = require("lib.platform.caps.exec")
			return exec_caps.new(sub_decl, {
				parent_revoked_fn = function() return revoked end,
			})

		else
			return nil, "unknown attenuation type: " .. tostring(sub_type)
		end
	end

	local cap = {
		_type = "shell",
		run = function(cmd)
			if revoked then return nil, "shell: capability revoked" end
			if type(cmd) ~= "string" then return nil, "shell: command must be a string" end
			local fh, err = io.popen(cmd .. " 2>&1", "r")
			if not fh then return nil, "shell: popen failed: " .. tostring(err) end
			local out = fh:read("*a")
			fh:close()
			return out or ""
		end,
		run_stream = function(cmd)
			if revoked then return nil, "shell: capability revoked" end
			return open_stream(cmd)
		end,
		attenuate = attenuate,
	}

	local function revoke() revoked = true end

	return cap, revoke
end

function M.risk(_)
	return { severity = "critical", text = "Runs arbitrary shell commands as your user. Can exfiltrate data, install malware, modify any file you own, or pivot to other systems." }
end

return M
