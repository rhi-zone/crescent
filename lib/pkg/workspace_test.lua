if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local workspace = require("lib.pkg.workspace")

-- ── test helpers ──────────────────────────────────────────────────────────────

-- Create a temp directory and return its path.
local function mktmpdir()
	local name = os.tmpname()
	os.remove(name)  -- os.tmpname creates a file; we want a dir
	os.execute(("mkdir -p %q"):format(name))
	return name
end

-- Write content to path, creating parent dirs as needed.
local function write_file(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	if dir then
		os.execute(("mkdir -p %q"):format(dir))
	end
	local f = io.open(path, "w")
	if not f then error("cannot write: " .. path) end
	f:write(content)
	f:close()
end

-- Remove a directory tree.
local function rmtree(path)
	os.execute(("rm -rf %q"):format(path))
end

-- ── workspace.load: valid workspace.lua ─────────────────────────────────────

T.describe("workspace.load", function()
	T.it("parses a valid workspace.lua", function()
		local dir = mktmpdir()
		write_file(dir .. "/workspace.lua", [[
return {
  members = {
    "lib/pkg",
    "lib/test",
    "lib/merge3",
  },
}
]])
		local ws, err = workspace.load(dir)
		T.ok(ws,       "load returns table")
		T.ok(not err,  "load returns no error")
		T.eq(#ws.members, 3, "three members")
		T.eq(ws.members[1], "lib/pkg",    "first member")
		T.eq(ws.members[2], "lib/test",   "second member")
		T.eq(ws.members[3], "lib/merge3", "third member")
		rmtree(dir)
	end)

	T.it("returns nil, err when workspace.lua is missing", function()
		local dir = mktmpdir()
		local ws, err = workspace.load(dir)
		T.ok(not ws,  "missing workspace.lua returns nil")
		T.ok(err,     "missing workspace.lua returns error")
		rmtree(dir)
	end)

	T.it("returns nil, err when workspace.lua does not return a table", function()
		local dir = mktmpdir()
		write_file(dir .. "/workspace.lua", "return 42\n")
		local ws, err = workspace.load(dir)
		T.ok(not ws, "non-table return → nil")
		T.ok(err and err:find("table"), "error mentions 'table'")
		rmtree(dir)
	end)

	T.it("returns nil, err when members field is missing", function()
		local dir = mktmpdir()
		write_file(dir .. "/workspace.lua", "return {}\n")
		local ws, err = workspace.load(dir)
		T.ok(not ws, "missing members → nil")
		T.ok(err and err:find("members"), "error mentions 'members'")
		rmtree(dir)
	end)

	T.it("returns nil, err when members is not a table", function()
		local dir = mktmpdir()
		write_file(dir .. "/workspace.lua", "return { members = 'bad' }\n")
		local ws, err = workspace.load(dir)
		T.ok(not ws, "non-table members → nil")
		T.ok(err and err:find("members"), "error mentions 'members'")
		rmtree(dir)
	end)

	T.it("returns nil, err when a member entry is not a string", function()
		local dir = mktmpdir()
		write_file(dir .. "/workspace.lua", "return { members = { 'lib/pkg', 99 } }\n")
		local ws, err = workspace.load(dir)
		T.ok(not ws, "non-string member → nil")
		T.ok(err and err:find("members"), "error mentions 'members'")
		rmtree(dir)
	end)

	T.it("returns nil, err when a member string is empty", function()
		local dir = mktmpdir()
		write_file(dir .. "/workspace.lua", "return { members = { '' } }\n")
		local ws, err = workspace.load(dir)
		T.ok(not ws, "empty member string → nil")
		T.ok(err, "returns error string")
		rmtree(dir)
	end)

	T.it("returns nil, err when workspace.lua has a syntax error", function()
		local dir = mktmpdir()
		write_file(dir .. "/workspace.lua", "return { members = {\n")
		local ws, err = workspace.load(dir)
		T.ok(not ws, "syntax error → nil")
		T.ok(err, "returns error string")
		rmtree(dir)
	end)

	T.it("returns nil, err when workspace.lua raises a runtime error", function()
		local dir = mktmpdir()
		write_file(dir .. "/workspace.lua", "error('boom')\n")
		local ws, err = workspace.load(dir)
		T.ok(not ws, "runtime error → nil")
		T.ok(err and err:find("boom"), "error includes original message")
		rmtree(dir)
	end)
end)

-- ── workspace.find_root ───────────────────────────────────────────────────────

T.describe("workspace.find_root", function()
	T.it("finds root when called from the workspace root itself", function()
		local root = mktmpdir()
		write_file(root .. "/workspace.lua", "return { members = {} }\n")
		local found = workspace.find_root(root)
		T.eq(found, root, "find_root returns workspace root")
		rmtree(root)
	end)

	T.it("finds root when called from a member subdirectory", function()
		local root = mktmpdir()
		write_file(root .. "/workspace.lua", "return { members = { 'lib/pkg' } }\n")
		os.execute(("mkdir -p %q"):format(root .. "/lib/pkg"))
		local found = workspace.find_root(root .. "/lib/pkg")
		T.eq(found, root, "find_root walks up to workspace root")
		rmtree(root)
	end)

	T.it("finds root when called from a deeply nested member directory", function()
		local root = mktmpdir()
		write_file(root .. "/workspace.lua", "return { members = { 'a/b/c' } }\n")
		os.execute(("mkdir -p %q"):format(root .. "/a/b/c"))
		local found = workspace.find_root(root .. "/a/b/c")
		T.eq(found, root, "find_root walks up through multiple levels")
		rmtree(root)
	end)

	T.it("returns nil when no workspace.lua in any ancestor", function()
		local dir = mktmpdir()
		-- No workspace.lua anywhere in the temp subtree
		local found = workspace.find_root(dir)
		T.ok(not found, "find_root returns nil when no workspace")
		rmtree(dir)
	end)
end)

-- ── workspace.collect_constraints ────────────────────────────────────────────

T.describe("workspace.collect_constraints", function()
	T.it("collects constraints from two members, no conflict", function()
		local root = mktmpdir()

		write_file(root .. "/workspace.lua", [[
return { members = { "pkga", "pkgb" } }
]])
		write_file(root .. "/pkga/pkg.lua", [[
return {
  name    = "pkga",
  version = "1.0.0",
  deps    = { sha1 = "^1.0" },
}
]])
		write_file(root .. "/pkgb/pkg.lua", [[
return {
  name    = "pkgb",
  version = "1.0.0",
  deps    = { lunajson = "^1.3" },
}
]])

		local constraints, err = workspace.collect_constraints(root)
		T.ok(constraints, "collect_constraints returns table")
		T.ok(not err,     "collect_constraints returns no error")

		-- sha1 constraint from pkga
		T.ok(constraints.sha1, "sha1 constraint present")
		T.eq(#constraints.sha1, 1, "exactly one sha1 constraint")
		T.eq(constraints.sha1[1].constraint, "^1.0",  "sha1 constraint value")
		T.eq(constraints.sha1[1].from,       "pkga",  "sha1 constraint from pkga")

		-- lunajson constraint from pkgb
		T.ok(constraints.lunajson, "lunajson constraint present")
		T.eq(#constraints.lunajson, 1, "exactly one lunajson constraint")
		T.eq(constraints.lunajson[1].constraint, "^1.3",  "lunajson constraint value")
		T.eq(constraints.lunajson[1].from,       "pkgb",  "lunajson constraint from pkgb")

		rmtree(root)
	end)

	T.it("records multiple constraints when different members depend on the same package", function()
		local root = mktmpdir()

		write_file(root .. "/workspace.lua", [[
return { members = { "pkga", "pkgb" } }
]])
		write_file(root .. "/pkga/pkg.lua", [[
return {
  name    = "pkga",
  version = "1.0.0",
  deps    = { sha1 = "^1.0" },
}
]])
		write_file(root .. "/pkgb/pkg.lua", [[
return {
  name    = "pkgb",
  version = "1.0.0",
  deps    = { sha1 = "^1.2" },
}
]])

		local constraints, err = workspace.collect_constraints(root)
		T.ok(constraints, "collect returns table")
		T.ok(not err,     "collect returns no error")

		-- Two separate sha1 constraints from different members
		T.ok(constraints.sha1, "sha1 present")
		T.eq(#constraints.sha1, 2, "two sha1 constraints (one per member)")

		-- Both from-labels are recorded
		local froms = {}
		for _, c in ipairs(constraints.sha1) do
			froms[c.from] = c.constraint
		end
		T.eq(froms["pkga"], "^1.0", "pkga sha1 constraint")
		T.eq(froms["pkgb"], "^1.2", "pkgb sha1 constraint")

		rmtree(root)
	end)

	T.it("returns nil, err when workspace.lua is missing", function()
		local root = mktmpdir()
		local constraints, err = workspace.collect_constraints(root)
		T.ok(not constraints, "missing workspace.lua → nil")
		T.ok(err, "returns error string")
		rmtree(root)
	end)

	T.it("returns nil, err when a member pkg.lua is missing", function()
		local root = mktmpdir()
		write_file(root .. "/workspace.lua", [[
return { members = { "nonexistent" } }
]])
		local constraints, err = workspace.collect_constraints(root)
		T.ok(not constraints, "missing member pkg.lua → nil")
		T.ok(err, "returns error string")
		rmtree(root)
	end)

	T.it("handles a member with no deps gracefully", function()
		local root = mktmpdir()
		write_file(root .. "/workspace.lua", [[
return { members = { "leaf" } }
]])
		write_file(root .. "/leaf/pkg.lua", [[
return {
  name    = "leaf",
  version = "0.1.0",
  deps    = {},
}
]])
		local constraints, err = workspace.collect_constraints(root)
		T.ok(constraints, "member with empty deps returns table")
		T.ok(not err,     "no error")
		T.eq(next(constraints), nil, "no constraints collected")
		rmtree(root)
	end)

	T.it("uses member name as the 'from' label (not the path)", function()
		local root = mktmpdir()
		write_file(root .. "/workspace.lua", [[
return { members = { "sub/mypkg" } }
]])
		write_file(root .. "/sub/mypkg/pkg.lua", [[
return {
  name    = "mypkg",
  version = "1.0.0",
  deps    = { sha1 = "^1.0" },
}
]])
		local constraints, err = workspace.collect_constraints(root)
		T.ok(constraints, "returns table")
		T.ok(not err, "no error")
		T.ok(constraints.sha1, "sha1 constraint present")
		T.eq(constraints.sha1[1].from, "mypkg", "from label is package name, not path")
		rmtree(root)
	end)
end)

-- ── CLI parse_args: --workspace flag ─────────────────────────────────────────

T.describe("cli.parse_args --workspace", function()
	local cli = require("lib.pkg.cli")

	T.it("--workspace flag is parsed and set to true", function()
		local r = cli.parse_args({ "install", "--workspace" })
		T.eq(r.command,   "install", "command is install")
		T.eq(r.workspace, true,      "--workspace flag is true")
	end)

	T.it("workspace is false by default", function()
		local r = cli.parse_args({ "install" })
		T.eq(r.workspace, false, "workspace is false by default")
	end)

	T.it("--workspace can appear before command", function()
		local r = cli.parse_args({ "--workspace", "install" })
		T.eq(r.command,   "install", "command parsed after --workspace")
		T.eq(r.workspace, true,      "--workspace flag is true")
	end)
end)

-- ── cmd_install workspace detection ──────────────────────────────────────────

T.describe("cmd_install workspace detection", function()
	local cli = require("lib.pkg.cli")

	T.it("find_root is called when workspace.lua present; project_dir is workspace root", function()
		-- Set up a temp workspace with one member
		local root = mktmpdir()
		write_file(root .. "/workspace.lua", [[
return { members = { "pkgmain" } }
]])
		write_file(root .. "/pkgmain/pkg.lua", [[
return {
  name    = "pkgmain",
  version = "1.0.0",
  deps    = {},
}
]])

		-- When workspace.lua exists at root, find_root(root) returns root.
		local found = workspace.find_root(root)
		T.eq(found, root, "workspace root detected correctly")

		-- The install would use root as project_dir (no deps to install, just verify)
		-- We verify the workspace root is found, not that install succeeds end-to-end
		-- (install requires registry/network which is out of scope for unit tests).

		rmtree(root)
	end)
end)
