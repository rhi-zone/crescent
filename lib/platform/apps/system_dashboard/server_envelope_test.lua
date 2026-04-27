-- lib/platform/apps/system_dashboard/server_envelope_test.lua
-- Envelope adapter tests for /api/execute.
--
-- Stubs each cap type and verifies the envelope shape produced by the
-- dispatcher for every primitive listed in `docs/system_dashboard_primitives.md`
-- that the first-pass renderer covers (text, code, key_value, table,
-- status_badge), plus the err envelope.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local json   = require("lib.format.json")
local server = require("lib.platform.apps.system_dashboard.server")

-- ── Stubs ─────────────────────────────────────────────────────────────────────

local function make_shell_cap(run_fn)
	local cap
	cap = {
		_type = "shell",
		run = run_fn,
		attenuate = function() return cap end,
	}
	return cap
end

local function make_reg_cap(opts)
	local cap
	cap = {
		_type = "registry",
		get = opts.get_fn or function() return "value", "REG_SZ" end,
		set = function() return true end,
		list_keys = opts.list_keys_fn or function() return {} end,
		list_values = opts.list_values_fn or function() return {} end,
		attenuate = function() return cap end,
	}
	return cap
end

-- A user_packs fs cap that serves a single inline pack source.
local function make_fs_cap(filename, content)
	return {
		_type = "fs",
		list = function() return { filename } end,
		read = function(p) if p == filename then return content end return nil, "nf" end,
	}
end

local function build(pack_src, caps)
	local user_packs = make_fs_cap("envpack.lua", pack_src)
	local merged = { user_packs = user_packs }
	for k, v in pairs(caps) do merged[k] = v end
	return server.create(merged, {})
end

local function post(handler, alias_id)
	local req = {
		method = "POST", path = "/api/execute",
		body = json.encode({ alias_id = alias_id, action_index = 0 }),
	}
	local res = { headers = {} }
	handler(req, res)
	return json.decode(res.body or "")
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("system_dashboard envelope output", function()

	T.describe("text envelope from shell stdout", function()
		local pack_src = [[
return {
  name = "envtest",
  aliases = {
    { id = "e-text", actions = { {
      caps = { sh = { type = "shell", reason = "test" } },
      exec = { cap = "sh", args = "echo hello" },
    } } },
  },
}
]]
		local sh = make_shell_cap(function() return "hello\n" end)
		local srv = build(pack_src, { shell = sh })
		local r = post(srv.handler, "e-text")
		T.ok(r.ok == true, "expected ok")
		T.eq(r.body.type, "text")
		T.eq(r.body.text, "hello")
		T.ok(type(r.cite) == "table", "expected cite array")
		T.eq(r.cite[1].kind, "command")
	end)

	T.describe("code envelope from shell stdout", function()
		local pack_src = [[
return {
  name = "envtest",
  aliases = {
    { id = "e-code", actions = { {
      caps = { sh = { type = "shell", reason = "test" } },
      exec = { cap = "sh", args = "df -h", output = { type = "code", lang = "shell" } },
    } } },
  },
}
]]
		local sh = make_shell_cap(function() return "Filesystem  Size\n/dev/sda1  100G\n" end)
		local srv = build(pack_src, { shell = sh })
		local r = post(srv.handler, "e-code")
		T.ok(r.ok == true, "expected ok: " .. tostring(r.error))
		T.eq(r.body.type, "code")
		T.eq(r.body.lang, "shell")
		T.ok(r.body.text:find("Filesystem") ~= nil, "code body should contain stdout")
	end)

	T.describe("key_value envelope from registry list_values", function()
		local pack_src = [[
return {
  name = "envtest",
  aliases = {
    { id = "e-kv", actions = { {
      caps = { reg = { type = "registry", reason = "test", root = "HKCU\\test", allow_write = false } },
      exec = { cap = "reg", op = "list_values", output = "key_value" },
    } } },
  },
}
]]
		local reg = make_reg_cap({
			list_values_fn = function() return { { name = "A", value = "1" }, { name = "B", value = "2" } } end,
		})
		local srv = build(pack_src, { registry = reg })
		local r = post(srv.handler, "e-kv")
		T.ok(r.ok == true, "expected ok: " .. tostring(r.error))
		T.eq(r.body.type, "key_value")
		T.eq(#r.body.pairs, 2)
		T.eq(r.body.pairs[1].key, "A")
		T.eq(r.body.pairs[1].value.type, "text")
		T.eq(r.body.pairs[1].value.text, "1")
		T.eq(r.cite[1].kind, "registry_key")
	end)

	T.describe("table envelope from shell stdout with skip_header", function()
		local pack_src = [[
return {
  name = "envtest",
  aliases = {
    { id = "e-tab", actions = { {
      caps = { sh = { type = "shell", reason = "test" } },
      exec = {
        cap = "sh", args = "df -h",
        output = {
          type = "table",
          skip_header = true,
          columns = {
            { key = "filesystem", label = "Filesystem", type = "string" },
            { key = "size",       label = "Size",       type = "bytes"  },
            { key = "mounted",    label = "Mounted",    type = "string" },
          },
        },
      },
    } } },
  },
}
]]
		local sh = make_shell_cap(function()
			return "Filesystem Size Mounted\n/dev/sda1 100G /\n/dev/sdb1 200G /home\n"
		end)
		local srv = build(pack_src, { shell = sh })
		local r = post(srv.handler, "e-tab")
		T.ok(r.ok == true, "expected ok: " .. tostring(r.error))
		T.eq(r.body.type, "table")
		T.eq(#r.body.columns, 3)
		T.eq(#r.body.rows, 2)
		T.eq(r.body.rows[1].filesystem, "/dev/sda1")
		T.eq(r.body.rows[1].size, "100G")
		T.eq(r.body.rows[1].mounted, "/")
	end)

	T.describe("status_badge envelope: matching pattern uses on_match state", function()
		local pack_src = [[
return {
  name = "envtest",
  aliases = {
    { id = "e-badge-ok", actions = { {
      caps = { sh = { type = "shell", reason = "test" } },
      exec = {
        cap = "sh", args = "systemctl is-active sshd",
        output = {
          type = "status_badge",
          on_match = { pattern = "^active", label = "sshd: active",   state = "ok"   },
          default  = {                       label = "sshd: inactive", state = "warn" },
        },
      },
    } } },
  },
}
]]
		local sh = make_shell_cap(function() return "active\n" end)
		local srv = build(pack_src, { shell = sh })
		local r = post(srv.handler, "e-badge-ok")
		T.ok(r.ok == true, "expected ok: " .. tostring(r.error))
		T.eq(r.body.type, "status_badge")
		T.eq(r.body.state, "ok")
		T.eq(r.body.label, "sshd: active")
	end)

	T.describe("status_badge envelope: non-matching pattern uses default", function()
		local pack_src = [[
return {
  name = "envtest",
  aliases = {
    { id = "e-badge-warn", actions = { {
      caps = { sh = { type = "shell", reason = "test" } },
      exec = {
        cap = "sh", args = "systemctl is-active sshd",
        output = {
          type = "status_badge",
          on_match = { pattern = "^active", label = "sshd: active",   state = "ok"   },
          default  = {                       label = "sshd: inactive", state = "warn" },
        },
      },
    } } },
  },
}
]]
		local sh = make_shell_cap(function() return "inactive\n" end)
		local srv = build(pack_src, { shell = sh })
		local r = post(srv.handler, "e-badge-warn")
		T.ok(r.ok == true, "expected ok: " .. tostring(r.error))
		T.eq(r.body.type, "status_badge")
		T.eq(r.body.state, "warn")
		T.eq(r.body.label, "sshd: inactive")
	end)

	T.describe("err envelope when cap returns nil, errmsg", function()
		local pack_src = [[
return {
  name = "envtest",
  aliases = {
    { id = "e-err", actions = { {
      caps = { sh = { type = "shell", reason = "test" } },
      exec = { cap = "sh", args = "false" },
    } } },
  },
}
]]
		local sh = make_shell_cap(function() return nil, "boom" end)
		local srv = build(pack_src, { shell = sh })
		local r = post(srv.handler, "e-err")
		T.ok(r.ok == false, "expected ok=false")
		T.eq(r.error, "boom")
	end)

end)
