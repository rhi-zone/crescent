-- lib/platform/apps/system_dashboard/server_test.lua
-- Tests for the system_dashboard server's registry cap dispatch.
-- Uses fake caps and inline pack sources — no real Windows registry access.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local json   = require("lib.format.json")
local server = require("lib.platform.apps.system_dashboard.server")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Build a fake registry cap.
-- opts.allow_write  : boolean, default false
-- opts.get_fn       : optional override for get()
-- opts.list_keys_fn : optional override for list_keys()
-- opts.list_values_fn : optional override for list_values()
local function make_fake_reg_cap(opts)
	opts = opts or {}
	local allow_write = opts.allow_write or false
	local cap
	cap = {
		_type = "registry",
		get = opts.get_fn or function(_subkey, _name)
			return "FakeValue", "REG_SZ"
		end,
		set = function(_subkey, _name, _value, _vtype)
			if not allow_write then return nil, "registry: write not granted" end
			return true
		end,
		list_keys = opts.list_keys_fn or function(_subkey)
			return { "SubkeyA", "SubkeyB" }
		end,
		list_values = opts.list_values_fn or function(_subkey)
			return { { name = "Foo", type = "REG_SZ" }, { name = "Bar", type = "REG_DWORD" } }
		end,
		attenuate = function(decl)
			local new_write = decl.allow_write
			if new_write == nil then new_write = allow_write end
			if new_write and not allow_write then
				return nil, "registry.attenuate: cannot grant write not held"
			end
			return make_fake_reg_cap({
				allow_write     = new_write,
				get_fn          = opts.get_fn,
				list_keys_fn    = opts.list_keys_fn,
				list_values_fn  = opts.list_values_fn,
			})
		end,
	}
	return cap
end

-- Build a fake fs cap (for user_packs) serving one pack Lua file.
local function make_fake_fs_cap(filename, content)
	return {
		_type = "fs",
		list  = function() return { filename } end,
		read  = function(path)
			if path == filename then return content end
			return nil, "not found: " .. tostring(path)
		end,
	}
end

-- Build a pack Lua source string with one alias containing one action.
-- exec_table is a table serialised literally into the source.
-- caps_allow_write controls the registry cap decl in the action.
local function make_pack_src(alias_id, exec_table, caps_allow_write)
	local aw = caps_allow_write and "true" or "false"
	-- Serialise exec_table fields as a Lua table literal.
	local exec_fields = {}
	for k, v in pairs(exec_table) do
		local val
		if type(v) == "string" then
			val = string.format("%q", v)
		elseif type(v) == "number" or type(v) == "boolean" then
			val = tostring(v)
		else
			val = tostring(v)
		end
		exec_fields[#exec_fields + 1] = k .. " = " .. val
	end
	local exec_src = "{ " .. table.concat(exec_fields, ", ") .. " }"
	return string.format([[
return {
  name    = "test-pack",
  aliases = {
    {
      id      = %q,
      title   = "Test alias",
      actions = {
        {
          label = "Test action",
          caps  = {
            reg = {
              type        = "registry",
              reason      = "test",
              root        = "HKCU\\test",
              allow_write = %s,
            },
          },
          exec = %s,
        },
      },
    },
  },
}
]], alias_id, aw, exec_src)
end

-- POST helper: send JSON to /api/execute and return decoded response.
local function post_execute(handler, alias_id, action_index)
	local req = {
		method = "POST",
		path   = "/api/execute",
		body   = json.encode({ alias_id = alias_id, action_index = action_index or 0 }),
	}
	local res = { headers = {} }
	handler(req, res)
	local ok2, decoded = pcall(json.decode, res.body or "")
	if not ok2 then return nil, "bad json: " .. tostring(res.body) end
	return decoded
end

-- Build a server with the given fake caps and a user_packs fs cap containing
-- pack_src.
local function make_server_with_pack(pack_src, reg_cap_opts)
	local fake_reg   = make_fake_reg_cap(reg_cap_opts or {})
	local user_packs = make_fake_fs_cap("test_pack.lua", pack_src)
	local caps       = { registry = fake_reg, user_packs = user_packs }
	local srv        = server.create(caps, {})
	return srv, fake_reg
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("system_dashboard registry dispatch", function()

	T.describe("get op returns value", function()
		local pack_src = make_pack_src("test-reg-get",
			{ cap = "reg", op = "get", name = "ProductName" }, false)
		local srv = make_server_with_pack(pack_src, {
			get_fn = function(_sk, _name) return "Windows 11 Pro", "REG_SZ" end,
		})
		local resp = post_execute(srv.handler, "test-reg-get", 0)
		T.ok(resp ~= nil, "response is nil")
		T.ok(resp.ok == true, "expected ok=true, got error: " .. tostring(resp and resp.error))
		T.eq(resp.output, "Windows 11 Pro")
	end)

	T.describe("list_values op returns array", function()
		local pack_src = make_pack_src("test-reg-lv",
			{ cap = "reg", op = "list_values" }, false)
		local srv = make_server_with_pack(pack_src, {
			list_values_fn = function(_sk)
				return { { name = "App1", type = "REG_SZ" }, { name = "App2", type = "REG_SZ" } }
			end,
		})
		local resp = post_execute(srv.handler, "test-reg-lv", 0)
		T.ok(resp ~= nil, "response is nil")
		T.ok(resp.ok == true, "expected ok=true, got error: " .. tostring(resp and resp.error))
		T.ok(type(resp.output) == "table", "output should be a table/array")
		T.eq(#resp.output, 2)
	end)

	T.describe("list_keys op returns array", function()
		local pack_src = make_pack_src("test-reg-lk",
			{ cap = "reg", op = "list_keys" }, false)
		local srv = make_server_with_pack(pack_src, {
			list_keys_fn = function(_sk) return { "KeyA", "KeyB", "KeyC" } end,
		})
		local resp = post_execute(srv.handler, "test-reg-lk", 0)
		T.ok(resp ~= nil, "response is nil")
		T.ok(resp.ok == true, "expected ok=true, got error: " .. tostring(resp and resp.error))
		T.eq(#resp.output, 3)
	end)

	T.describe("set rejected when allow_write=false", function()
		-- Cap has allow_write=false; action decl also says false → attenuated cap
		-- will deny set() with "write not granted".
		local pack_src = make_pack_src("test-reg-set-ro",
			{ cap = "reg", op = "set", name = "Foo", value = "Bar", vtype = "REG_SZ" }, false)
		local srv = make_server_with_pack(pack_src, { allow_write = false })
		local resp = post_execute(srv.handler, "test-reg-set-ro", 0)
		T.ok(resp ~= nil, "response is nil")
		T.ok(resp.ok == false, "expected ok=false for write-denied set")
		T.ok(resp.error ~= nil, "expected error message")
		T.ok(resp.error:find("write") ~= nil, "error should mention write: " .. tostring(resp.error))
	end)

	T.describe("unknown op returns error", function()
		local pack_src = make_pack_src("test-reg-badop",
			{ cap = "reg", op = "delete" }, false)
		local srv = make_server_with_pack(pack_src, {})
		local resp = post_execute(srv.handler, "test-reg-badop", 0)
		T.ok(resp ~= nil, "response is nil")
		T.ok(resp.ok == false, "expected ok=false for unknown op")
		T.ok(resp.error ~= nil, "expected error message")
		T.ok(resp.error:find("op") ~= nil, "error should mention op: " .. tostring(resp.error))
	end)

	T.describe("unknown vtype returns error", function()
		-- Cap with allow_write=true so set() itself wouldn't be blocked by write check.
		local pack_src = make_pack_src("test-reg-badvtype",
			{ cap = "reg", op = "set", name = "Foo", value = "Bar", vtype = "REG_BOGUS" }, true)
		local srv = make_server_with_pack(pack_src, { allow_write = true })
		local resp = post_execute(srv.handler, "test-reg-badvtype", 0)
		T.ok(resp ~= nil, "response is nil")
		T.ok(resp.ok == false, "expected ok=false for unknown vtype")
		T.ok(resp.error ~= nil, "expected error message")
		T.ok(resp.error:find("vtype") ~= nil, "error should mention vtype: " .. tostring(resp.error))
	end)

end)
