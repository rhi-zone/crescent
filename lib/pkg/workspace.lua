if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/workspace.lua — workspace support for crescent
--
-- A workspace is a directory containing multiple packages (members), each with
-- their own pkg.lua, sharing a single crescent.lock at the workspace root.
--
-- workspace.lua format (at workspace root):
--
--   return {
--     members = {
--       "lib/pkg",
--       "lib/test",
--       "lib/merge3",
--     },
--   }
--
-- Each member is a path relative to the workspace root containing a pkg.lua.

local manifest = require("lib.pkg.manifest")

local workspace = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Check whether a path exists (file or directory).
local function path_exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

-- Return the parent directory of path, or nil if already at root.
--: (string) -> string
local function parent_dir(path)
	-- Strip trailing slash
	local trimmed = path:gsub("/$", "")
	local parent = trimmed:match("^(.*)/[^/]+$")
	if not parent or parent == "" then
		return "/"
	end
	return parent
end

-- Canonicalise a relative path by joining dir + "/" + rel, collapsing ".." etc.
-- Simple implementation: shell-free, handles common cases.
--: (string, string) -> string
local function join_path(dir, rel)
	if rel:sub(1, 1) == "/" then
		return rel
	end
	local trimmed = dir:gsub("/$", "")
	return trimmed .. "/" .. rel
end

-- ── workspace.load ────────────────────────────────────────────────────────────

--- Load workspace.lua from dir.
-- Returns {members=[path,...]} on success, or nil, err on failure.
--: (string) -> ({ members: string[], ... } | nil, string | nil)
function workspace.load(dir)
	local trimmed_dir = dir:gsub("/$", "")
	local ws_path = trimmed_dir .. "/workspace.lua"
	local chunk, load_err = loadfile(ws_path)
	if not chunk then
		return nil, "failed to load workspace.lua from '" .. trimmed_dir .. "': " .. tostring(load_err)
	end

	local ok, result = pcall(chunk)
	if not ok then
		return nil, "failed to execute workspace.lua in '" .. trimmed_dir .. "': " .. tostring(result)
	end

	-- Validate
	if type(result) ~= "table" then
		return nil, "workspace.lua must return a table (got " .. type(result) .. ")"
	end
	if result.members == nil then
		return nil, "workspace.lua must have a 'members' field"
	end
	if type(result.members) ~= "table" then
		return nil, "workspace.lua 'members' must be an array of strings"
	end
	for i, v in ipairs(result.members) do
		if type(v) ~= "string" then
			return nil, ("workspace.lua 'members[%d]' must be a string"):format(i)
		end
		if v == "" then
			return nil, ("workspace.lua 'members[%d]' must be non-empty"):format(i)
		end
	end
	-- Validate no extraneous top-level keys that indicate a misformatted file
	-- (allow unknown keys for forward compatibility — only 'members' is required)

	return result
end

-- ── workspace.find_root ───────────────────────────────────────────────────────

--- Find the workspace root by walking up from dir.
-- Returns workspace_root_path if a workspace.lua is found in dir or any
-- ancestor, or nil if not in a workspace.
--: (string) -> string | nil
function workspace.find_root(dir)
	-- Canonicalise: convert relative "." to absolute if needed.
	-- We use the os.execute / io.popen approach only as a last resort.
	-- For simple relative paths that start with ".", resolve via shell.
	local start = dir
	if start == "." or start:sub(1, 2) == "./" then
		local fh = io.popen("pwd", "r")
		if fh then
			local raw = fh:read("*a")
			fh:close()
			if raw then
				local cwd = raw:gsub("%s+$", "")
				if start == "." then
					start = cwd
				else
					start = cwd .. "/" .. start:sub(3)
				end
			end
		end
	end

	local current = (start --[[:! string]]):gsub("/$", "") --[[: string]]
	-- Guard against infinite loops: stop at filesystem root.
	local max_depth = 64
	local depth = 0

	while current ~= "" and depth < max_depth do
		local ws_path = current .. "/workspace.lua"
		if path_exists(ws_path) then
			return current
		end
		-- Walk up one level
		local parent = parent_dir(current)
		if parent == current then
			-- At root; no workspace.lua found
			return nil
		end
		current = parent
		depth = depth + 1
	end

	return nil
end

-- ── workspace.collect_constraints ────────────────────────────────────────────

--- Collect all constraints across all workspace members.
-- workspace_dir: root directory containing workspace.lua.
-- Returns: constraints table { [name] = [{constraint, from}, ...] }
-- or nil, err on failure.
function workspace.collect_constraints(workspace_dir)
	local ws, ws_err = workspace.load(workspace_dir)
	if not ws then
		return nil, ws_err
	end

	local all_constraints = {} --: { [string]: { constraint: string, from: string }[] }

	local function add_constraint(name, constraint, from)
		if not all_constraints[name] then
			all_constraints[name] = {}
		end
		all_constraints[name][#all_constraints[name] + 1] = { constraint = constraint, from = from }
	end

	for _, member_rel in ipairs(ws.members) do
		local member_dir = join_path(workspace_dir, member_rel)
		local pkg_path   = member_dir .. "/pkg.lua"

		local m, m_err = manifest.load(pkg_path)
		if not m then
			return nil, ("workspace member %q: %s"):format(member_rel, tostring(m_err))
		end

		local from_label = m.name or member_rel
		local deps = m.deps or {}

		for dep_name, dep_value in pairs(deps) do
			local c = manifest.dep_constraint(dep_value --[[:! string | { constraint: string, include?: string }]])
			add_constraint(dep_name, c, from_label)
		end
	end

	return all_constraints
end

return workspace
