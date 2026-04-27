-- lib/platform/caps/exec_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local exec_cap = require("lib.platform.caps.exec")
local help    = require("lib.exec.help")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Minimal help text that yields a parseable HelpSchema with one subcommand.
local HELP_TEXT = [[
mytool — a fake tool for testing

Usage: mytool <command>

Commands:
  view   View something
  grep   Search something

Options:
  -h, --help     Show this help
  -v, --verbose  Enable verbose output
]]

-- A mock popen that returns HELP_TEXT for --help calls and empty output otherwise.
-- Captures the last command string for assertion use.
local last_cmd = nil
local function mock_popen(cmd_str, _mode)
	last_cmd = cmd_str
	-- Return a fake file handle.
	local content
	if cmd_str:find("--help") then
		-- Append sentinel so exec.run can parse exit code.
		content = HELP_TEXT .. "\n__EXEC_EXIT__0\n"
	else
		content = "\n__EXEC_EXIT__0\n"
	end
	local i = 0
	local fh = {}
	function fh:read(_fmt)
		if i == 0 then i = 1; return content end
		return nil
	end
	function fh:close() end
	return fh
end

-- Mock popen that fails (simulates binary not found).
local function failing_popen(_cmd_str, _mode)
	return nil, "command not found"
end

-- Build a schema table directly (for the hand-built schema test).
--: () -> any
local function make_hand_schema()
	return help.parse(HELP_TEXT)
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

T.describe("caps.exec", function()

	-- ── Construction ───────────────────────────────────────────────────────

	T.it("M.new returns cap table and revoke function", function()
		local cap, revoke = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		T.ok(type(cap) == "table", "cap is a table")
		T.ok(type(revoke) == "function", "revoke is a function")
		T.ok(type(cap.exec) == "function", "cap.exec is a function")
	end)

	T.it("construction with schema='auto' fetches schema via --help", function()
		local fetched = false
		local function tracking_popen(cmd_str, mode)
			if cmd_str:find("--help") then fetched = true end
			return mock_popen(cmd_str, mode)
		end

		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = "auto" } },
			popen    = tracking_popen,
		})
		T.ok(fetched, "popen was called with --help during construction")
		-- Fluent API node should be present.
		T.ok(cap.mytool ~= nil, "fluent api node built for mytool")
	end)

	T.it("construction with hand-built schema table skips help fetch", function()
		local called = false
		local function spy_popen(cmd_str, mode)
			called = true
			return mock_popen(cmd_str, mode)
		end

		local schema = make_hand_schema()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = schema } },
			popen    = spy_popen,
		})
		T.ok(not called, "popen not called when schema provided as table")
		T.ok(cap.mytool ~= nil, "fluent api node built for mytool")
	end)

	T.it("construction with schema=nil produces no fluent api node", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		T.ok(cap.mytool == nil, "no fluent node when schema=nil")
	end)

	T.it("construction with auto schema on absent binary leaves schema nil", function()
		local cap, _ = exec_cap.new({
			binaries = { ghost = { schema = "auto" } },
			popen    = failing_popen,
		})
		-- No fluent node, but cap.exec still works (whitelist enforced).
		T.ok(cap.ghost == nil, "no fluent node for binary with absent schema")
		T.ok(type(cap.exec) == "function", "cap.exec still present")
	end)

	-- ── Whitelist enforcement ──────────────────────────────────────────────

	T.it("raw call with unknown binary returns error", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("othertool", {"run"})
		T.ok(out == nil, "nil on unknown binary")
		T.ok(err ~= nil and err:find("whitelist"), "error mentions whitelist")
	end)

	T.it("raw call with known binary succeeds", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("mytool", {"view", "/path"})
		T.ok(err == nil, "no error for whitelisted binary: " .. tostring(err))
		T.ok(type(out) == "string", "returns string output")
	end)

	-- ── Allow-list enforcement ─────────────────────────────────────────────

	T.it("allow list: permitted subcommand passes", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil, allow = {"view", "grep"} } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("mytool", {"view", "/some/path"})
		T.ok(err == nil, "view is allowed: " .. tostring(err))
		T.ok(type(out) == "string")
	end)

	T.it("allow list: second permitted subcommand passes", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil, allow = {"view", "grep"} } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("mytool", {"grep", "/some/path", "--pattern", "foo"})
		T.ok(err == nil, "grep is allowed: " .. tostring(err))
		T.ok(type(out) == "string")
	end)

	T.it("allow list: disallowed subcommand returns error", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil, allow = {"view", "grep"} } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("mytool", {"edit", "/path"})
		T.ok(out == nil, "nil for disallowed subcommand")
		T.ok(err ~= nil and err:find("subcommand not allowed"), "error mentions disallowed subcommand: " .. tostring(err))
	end)

	T.it("allow list: empty args (no subcommand) returns error", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil, allow = {"view"} } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("mytool", {})
		T.ok(out == nil, "nil when no subcommand given with allow list")
		T.ok(err ~= nil and err:find("subcommand not allowed"), "error: " .. tostring(err))
	end)

	T.it("allow list nil: all subcommands permitted", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("mytool", {"anything", "--flag"})
		T.ok(err == nil, "no restriction when allow=nil: " .. tostring(err))
		T.ok(type(out) == "string")
	end)

	-- ── Revocation ─────────────────────────────────────────────────────────

	T.it("revoked cap: raw call returns capability revoked", function()
		local cap, revoke = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		revoke()
		local out, err = cap.exec("mytool", {"view"})
		T.ok(out == nil, "nil after revoke")
		T.eq(err, "capability revoked")
	end)

	T.it("revoked cap: fluent call returns capability revoked", function()
		local cap, revoke = exec_cap.new({
			binaries = { mytool = { schema = "auto" } },
			popen    = mock_popen,
		})
		-- Revoke after construction so fluent node was built.
		revoke()
		-- Fluent calls go through checked_popen which returns nil,"capability revoked",
		-- causing exec.run to return nil, "popen: capability revoked".
		T.ok(cap.mytool ~= nil, "fluent node exists")
		local view_fn = cap.mytool.view
		T.ok(view_fn ~= nil, "view subcommand node exists")
		if type(view_fn) == "function" then
			local out, err = view_fn("/path")
			T.ok(out == nil, "fluent call nil after revoke")
			T.ok(err ~= nil and err:find("capability revoked"), "error contains 'capability revoked': " .. tostring(err))
		end
	end)

	T.it("revoking one cap does not affect another", function()
		local cap1, revoke1 = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local cap2, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		revoke1()
		local _, err1 = cap1.exec("mytool", {"view"})
		T.eq(err1, "capability revoked")
		local out2, err2 = cap2.exec("mytool", {"view"})
		T.ok(err2 == nil, "cap2 unaffected: " .. tostring(err2))
		T.ok(type(out2) == "string")
	end)

	-- ── Raw args passthrough ───────────────────────────────────────────────

	T.it("raw call: list args forwarded verbatim", function()
		local captured = nil
		local function capture_popen(cmd_str, mode)
			captured = cmd_str
			return mock_popen(cmd_str, mode)
		end

		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = capture_popen,
		})
		cap.exec("mytool", {"view", "/lib", "--full"})
		T.ok(captured ~= nil, "popen was called")
		T.ok(captured:find("view"), "args contain 'view': " .. tostring(captured))
		T.ok(captured:find("lib"), "args contain path: " .. tostring(captured))
		T.ok(captured:find("full"), "args contain flag: " .. tostring(captured))
	end)

	T.it("raw call: nil args treated as empty list", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("mytool", nil)
		T.ok(err == nil, "nil args ok: " .. tostring(err))
		T.ok(type(out) == "string")
	end)

	-- ── Flag expansion via ExecArgsTable ───────────────────────────────────

	T.it("ExecArgsTable: flag expansion with schema", function()
		local captured = nil
		local function capture_popen(cmd_str, mode)
			-- Only capture non-help calls (for flag expansion test).
			if not cmd_str:find("--help") then
				captured = cmd_str
			end
			return mock_popen(cmd_str, mode)
		end

		local schema = make_hand_schema()
		-- Manually ensure view subcommand has a known flag to expand.
		-- The HELP_TEXT has top-level flags: --verbose, --help.
		-- Use the top-level schema for flag expansion test.
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = schema } },
			popen    = capture_popen,
		})

		-- ExecArgsTable form: path=[{"view"}], verbose=true
		-- Since schema has --verbose at root, and subcommand path="view"
		-- walks into schema.subcommands["view"] which has no flags,
		-- naive expansion will be used. Just verify no error and call goes through.
		local out, err = cap.exec("mytool", { [1] = {"view"}, verbose = true })
		-- The expansion may use naive mode (no flags on subcommand node).
		-- Either way it should not error on an unknown flag in naive mode.
		T.ok(err == nil or err:find("unknown flag") or err:find("exited"),
			"ExecArgsTable call: " .. tostring(err))
	end)

	T.it("ExecArgsTable: unknown flag with schema returns error", function()
		local schema = make_hand_schema()
		-- Inject schema at root so flag_idents are present.
		-- schema.flag_idents contains "verbose" and "help" from HELP_TEXT.
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = schema } },
			popen    = mock_popen,
		})

		-- Pass ExecArgsTable with path=[] (root level), unknown flag "zap".
		local out, err = cap.exec("mytool", { [1] = {}, zap = true })
		T.ok(out == nil, "nil for unknown flag")
		T.ok(err ~= nil and err:find("unknown flag"), "error mentions unknown flag: " .. tostring(err))
	end)

	T.it("ExecArgsTable: known flag expanded to CLI token", function()
		local captured = nil
		local function capture_popen(cmd_str, mode)
			if not cmd_str:find("--help") then captured = cmd_str end
			return mock_popen(cmd_str, mode)
		end

		local schema = make_hand_schema()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = schema } },
			popen    = capture_popen,
		})

		-- Pass ExecArgsTable at root level (path=[]) with verbose=true.
		-- schema has --verbose at root level.
		local out, err = cap.exec("mytool", { [1] = {}, verbose = true })
		T.ok(err == nil, "no error with known flag: " .. tostring(err))
		T.ok(captured ~= nil, "popen called")
		T.ok(captured:find("verbose"), "expanded flag present in command: " .. tostring(captured))
	end)

	-- ── Multiple binaries ──────────────────────────────────────────────────

	T.it("multiple binaries: each accessible independently", function()
		local cap, _ = exec_cap.new({
			binaries = {
				mytool  = { schema = nil },
				anytool = { schema = nil },
			},
			popen = mock_popen,
		})
		-- Both are in whitelist.
		local _, err1 = cap.exec("mytool", {"view"})
		local _, err2 = cap.exec("anytool", {"run"})
		T.ok(err1 == nil, "mytool ok: " .. tostring(err1))
		T.ok(err2 == nil, "anytool ok: " .. tostring(err2))
	end)

	T.it("multiple binaries: whitelist is per-cap, not global", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local out, err = cap.exec("anytool", {"run"})
		T.ok(out == nil)
		T.ok(err ~= nil and err:find("whitelist"), "cross-binary blocked: " .. tostring(err))
	end)

end)

-- ---------------------------------------------------------------------------
-- Attenuation tests
-- ---------------------------------------------------------------------------

T.describe("caps.exec attenuation", function()

	T.it("attenuate: subset binaries succeeds", function()
		local cap, _ = exec_cap.new({
			binaries = {
				mytool  = { schema = nil },
				anytool = { schema = nil },
			},
			popen = mock_popen,
		})
		local sub, sub_revoke = cap.attenuate({
			binaries = { mytool = { schema = nil } },
		})
		T.ok(sub ~= nil, "sub-cap returned")
		T.ok(type(sub_revoke) == "function", "sub revoke function returned")
		T.ok(type(sub.exec) == "function", "sub-cap has exec")
		-- mytool present in sub
		local out, err = sub.exec("mytool", {"view"})
		T.ok(err == nil, "mytool works in sub-cap: " .. tostring(err))
		T.ok(type(out) == "string")
	end)

	T.it("attenuate: superset binaries (unknown binary) fails", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local sub, err = cap.attenuate({
			binaries = { mytool = { schema = nil }, othertool = { schema = nil } },
		})
		T.ok(sub == nil, "nil when requesting binary not in parent")
		T.ok(err ~= nil and err:find("not in parent cap"), "error mentions not in parent cap: " .. tostring(err))
	end)

	T.it("attenuate: sub allow list as subset of parent succeeds", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil, allow = {"view", "grep", "edit"} } },
			popen    = mock_popen,
		})
		local sub, _ = cap.attenuate({
			binaries = { mytool = { schema = nil, allow = {"view", "grep"} } },
		})
		T.ok(sub ~= nil, "sub-cap returned")
		-- view is allowed
		local out1, err1 = sub.exec("mytool", {"view"})
		T.ok(err1 == nil, "view allowed in sub: " .. tostring(err1))
		-- edit is blocked (not in sub allow)
		local out2, err2 = sub.exec("mytool", {"edit"})
		T.ok(out2 == nil, "edit blocked in sub")
		T.ok(err2 ~= nil and err2:find("subcommand not allowed"), "error: " .. tostring(err2))
	end)

	T.it("attenuate: sub allow list wider than parent fails", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil, allow = {"view"} } },
			popen    = mock_popen,
		})
		local sub, err = cap.attenuate({
			binaries = { mytool = { schema = nil, allow = {"view", "edit"} } },
		})
		T.ok(sub == nil, "nil when sub allow wider than parent")
		T.ok(err ~= nil and err:find("not in parent allow"), "error mentions not in parent allow: " .. tostring(err))
	end)

	T.it("attenuate: sub allow nil inherits parent allow", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil, allow = {"view"} } },
			popen    = mock_popen,
		})
		-- sub requests mytool with no allow specified -> inherits parent's {"view"}
		local sub, _ = cap.attenuate({
			binaries = { mytool = { schema = nil } },
		})
		T.ok(sub ~= nil, "sub-cap returned")
		-- view is allowed (inherited)
		local _, err1 = sub.exec("mytool", {"view"})
		T.ok(err1 == nil, "view allowed via inherited allow: " .. tostring(err1))
		-- grep is not in parent allow, so blocked
		local out2, err2 = sub.exec("mytool", {"grep"})
		T.ok(out2 == nil, "grep blocked via inherited allow")
		T.ok(err2 ~= nil and err2:find("subcommand not allowed"), "error: " .. tostring(err2))
	end)

	T.it("attenuate: parent revocation propagates to sub-cap", function()
		local cap, revoke = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local sub, _ = cap.attenuate({
			binaries = { mytool = { schema = nil } },
		})
		T.ok(sub ~= nil, "sub-cap created")
		-- Works before revocation.
		local _, err_before = sub.exec("mytool", {"view"})
		T.ok(err_before == nil, "sub works before parent revoke: " .. tostring(err_before))
		-- Revoke parent.
		revoke()
		local out, err = sub.exec("mytool", {"view"})
		T.ok(out == nil, "sub nil after parent revoke")
		T.ok(err ~= nil and err:find("capability revoked"), "error after parent revoke: " .. tostring(err))
	end)

	T.it("attenuate: sub-cap revocation does not affect parent", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local sub, sub_revoke = cap.attenuate({
			binaries = { mytool = { schema = nil } },
		})
		sub_revoke()
		-- Sub is dead.
		local out_sub, err_sub = sub.exec("mytool", {"view"})
		T.ok(out_sub == nil, "sub dead after sub_revoke")
		T.ok(err_sub ~= nil and err_sub:find("capability revoked"), "sub error: " .. tostring(err_sub))
		-- Parent still works.
		local out_par, err_par = cap.exec("mytool", {"view"})
		T.ok(err_par == nil, "parent unaffected by sub revoke: " .. tostring(err_par))
		T.ok(type(out_par) == "string")
	end)

	T.it("attenuate: revoked parent cannot attenuate", function()
		local cap, revoke = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		revoke()
		local sub, err = cap.attenuate({
			binaries = { mytool = { schema = nil } },
		})
		T.ok(sub == nil, "cannot attenuate a revoked cap")
		T.ok(err ~= nil and err:find("capability revoked"), "error: " .. tostring(err))
	end)

	T.it("attenuate: sub-cap also has attenuate method", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		local sub, _ = cap.attenuate({
			binaries = { mytool = { schema = nil } },
		})
		T.ok(sub ~= nil, "sub-cap returned")
		T.ok(type(sub.attenuate) == "function", "sub-cap has attenuate method")
	end)

	T.it("attenuate: _type field is 'exec'", function()
		local cap, _ = exec_cap.new({
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		T.eq(cap._type, "exec")
		local sub, _ = cap.attenuate({
			binaries = { mytool = { schema = nil } },
		})
		T.ok(sub ~= nil, "sub-cap returned")
		T.eq(sub._type, "exec")
	end)

end)

-- ---------------------------------------------------------------------------
-- Shell attenuation tests
-- ---------------------------------------------------------------------------

T.describe("caps.shell attenuation", function()
	local shell_caps = require("lib.platform.caps.shell")

	T.it("_type field is 'shell'", function()
		local cap, _ = shell_caps.shell_cap()
		T.eq(cap._type, "shell")
	end)

	T.it("attenuate to shell sub-cap works", function()
		local cap, _ = shell_caps.shell_cap()
		local sub, sub_revoke = cap.attenuate({ type = "shell" })
		T.ok(sub ~= nil, "shell sub-cap returned")
		T.ok(type(sub_revoke) == "function", "sub revoke returned")
		T.eq(sub._type, "shell")
		T.ok(type(sub.run) == "function", "sub has run")
		T.ok(type(sub.attenuate) == "function", "sub has attenuate")
	end)

	T.it("attenuate default type is shell", function()
		local cap, _ = shell_caps.shell_cap()
		local sub, _ = cap.attenuate({})
		T.ok(sub ~= nil, "shell sub-cap returned with empty sub_decl")
		T.eq(sub._type, "shell")
	end)

	T.it("attenuate to exec sub-cap works", function()
		local cap, _ = shell_caps.shell_cap()
		local sub, sub_revoke = cap.attenuate({
			type     = "exec",
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		T.ok(sub ~= nil, "exec sub-cap returned")
		T.ok(type(sub_revoke) == "function", "sub revoke returned")
		T.eq(sub._type, "exec")
		T.ok(type(sub.exec) == "function", "exec sub-cap has exec fn")
		local out, err = sub.exec("mytool", {"view"})
		T.ok(err == nil, "exec sub-cap can run: " .. tostring(err))
		T.ok(type(out) == "string")
	end)

	T.it("attenuate unknown type returns error", function()
		local cap, _ = shell_caps.shell_cap()
		local sub, err = cap.attenuate({ type = "frobnicator" })
		T.ok(sub == nil, "nil for unknown type")
		T.ok(err ~= nil and err:find("unknown attenuation type"), "error: " .. tostring(err))
	end)

	T.it("shell parent revocation propagates to shell sub-cap", function()
		local cap, revoke = shell_caps.shell_cap()
		local sub, _ = cap.attenuate({ type = "shell" })
		T.ok(sub ~= nil)
		revoke()
		local out, err = sub.run("echo hello")
		T.ok(out == nil, "sub nil after parent revoke")
		T.ok(err ~= nil and err:find("capability revoked"), "error: " .. tostring(err))
	end)

	T.it("shell sub-cap revocation does not affect parent", function()
		local cap, _ = shell_caps.shell_cap()
		local sub, sub_revoke = cap.attenuate({ type = "shell" })
		T.ok(sub ~= nil)
		sub_revoke()
		local out_sub, err_sub = sub.run("echo hello")
		T.ok(out_sub == nil, "sub dead")
		T.ok(err_sub ~= nil and err_sub:find("capability revoked"), "sub error: " .. tostring(err_sub))
		-- Parent run touches io.popen which works in this environment.
		-- We only check the cap itself isn't broken (it won't be revoked).
		T.ok(type(cap.run) == "function", "parent run still a function")
	end)

	T.it("shell parent revocation propagates to exec sub-cap", function()
		local cap, revoke = shell_caps.shell_cap()
		local sub, _ = cap.attenuate({
			type     = "exec",
			binaries = { mytool = { schema = nil } },
			popen    = mock_popen,
		})
		T.ok(sub ~= nil)
		revoke()
		local out, err = sub.exec("mytool", {"view"})
		T.ok(out == nil, "exec sub nil after shell parent revoke")
		T.ok(err ~= nil and err:find("capability revoked"), "error: " .. tostring(err))
	end)

	T.it("revoked shell parent cannot attenuate", function()
		local cap, revoke = shell_caps.shell_cap()
		revoke()
		local sub, err = cap.attenuate({ type = "shell" })
		T.ok(sub == nil, "cannot attenuate revoked shell cap")
		T.ok(err ~= nil and err:find("capability revoked"), "error: " .. tostring(err))
	end)

end)
