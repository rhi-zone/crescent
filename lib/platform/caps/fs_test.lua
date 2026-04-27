if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local fs = require("lib.platform.caps.fs")

-- stub env: simulates HOME=/home/alice, no Windows vars
local function make_env(vars)
	return function(name)
		return vars[name]
	end
end

local alice_env = make_env({
	HOME = "/home/alice",
})

T.describe("caps.fs _classify_root", function()
	T.it("/ is root_fs", function()
		local class = fs._classify_root("/", alice_env)
		T.eq(class, "root_fs")
	end)

	T.it("/etc is etc", function()
		local class = fs._classify_root("/etc", alice_env)
		T.eq(class, "etc")
	end)

	T.it("/etc/nginx is etc (descendant)", function()
		local class = fs._classify_root("/etc/nginx", alice_env)
		T.eq(class, "etc")
	end)

	T.it("user home encompasses sensitive subdirs", function()
		local class, _, ancestors = fs._classify_root("/home/alice", alice_env)
		T.eq(class, "user_home")
		T.ok(ancestors ~= nil, "should have ancestor labels")
		local found_ssh = false
		for _, a in ipairs(ancestors) do
			if a:find("%.ssh") or a:find("ssh") then found_ssh = true end
		end
		T.ok(found_ssh, "ancestors should include .ssh entry")
	end)

	T.it("~/.ssh is ssh_keys", function()
		local class = fs._classify_root("/home/alice/.ssh", alice_env)
		T.eq(class, "ssh_keys")
	end)

	T.it("~/.gnupg is gpg_keys", function()
		local class = fs._classify_root("/home/alice/.gnupg", alice_env)
		T.eq(class, "gpg_keys")
	end)

	T.it("~/.config is xdg_config", function()
		local class = fs._classify_root("/home/alice/.config", alice_env)
		T.eq(class, "xdg_config")
	end)

	T.it("~/.local is xdg_local_parent encompassing .local/share", function()
		local class, _, ancestors = fs._classify_root("/home/alice/.local", alice_env)
		T.eq(class, "xdg_local_parent")
		T.ok(ancestors ~= nil, "should have ancestor labels for .local")
	end)

	T.it("~/.local/share is xdg_data", function()
		local class = fs._classify_root("/home/alice/.local/share", alice_env)
		T.eq(class, "xdg_data")
	end)

	T.it("subdir of home has class=user_home", function()
		local class = fs._classify_root("/home/alice/myapp", alice_env)
		T.eq(class, "user_home")
	end)

	T.it("path outside any sensitive dir has class=specific, no ancestors", function()
		local class, _, ancestors = fs._classify_root("/opt/myapp", alice_env)
		T.eq(class, "specific")
		T.ok(ancestors == nil or #ancestors == 0, "no sensitive ancestors expected")
	end)

	T.it("/tmp is tmp_dir", function()
		local class = fs._classify_root("/tmp", alice_env)
		T.eq(class, "tmp_dir")
	end)

	T.it("/var/tmp is tmp_dir", function()
		local class = fs._classify_root("/var/tmp", alice_env)
		T.eq(class, "tmp_dir")
	end)

	T.it("/tmp/subdir is tmp_dir (descendant)", function()
		local class = fs._classify_root("/tmp/subdir", alice_env)
		T.eq(class, "tmp_dir")
	end)

	T.it("tilde expansion works for ~/.ssh", function()
		local class = fs._classify_root("~/.ssh", alice_env)
		T.eq(class, "ssh_keys")
	end)

	T.it("tilde expansion works for home itself", function()
		local class = fs._classify_root("~", alice_env)
		T.eq(class, "user_home")
	end)

	T.it("/home is all_user_homes", function()
		local class = fs._classify_root("/home", alice_env)
		T.eq(class, "all_user_homes")
	end)

	T.it("matched_label is returned for known class", function()
		local class, label = fs._classify_root("/home/alice/.ssh", alice_env)
		T.eq(class, "ssh_keys")
		T.ok(label ~= nil, "matched_label should be non-nil for known class")
		T.ok(label:find("ssh") or label:find("SSH"), "label should mention ssh")
	end)

	T.it("matched_label is nil for specific class", function()
		local class, label = fs._classify_root("/opt/myapp", alice_env)
		T.eq(class, "specific")
		T.ok(label == nil, "matched_label should be nil for specific class")
	end)

	T.it("/ has ancestors (all sensitive dirs are under it)", function()
		local class, _, ancestors = fs._classify_root("/", alice_env)
		T.eq(class, "root_fs")
		T.ok(ancestors ~= nil and #ancestors > 0, "/ should encompass many dirs")
	end)
end)

T.describe("caps.fs risk", function()
	T.it("readonly specific path has medium severity", function()
		local result = fs.risk({ type = "fs", root = "/opt/myapp/data" })
		T.eq(result.severity, "medium")
		T.ok(result.text:find("/opt/myapp/data"), "text includes root path")
	end)

	T.it("writable specific path has high severity", function()
		local result = fs.risk({ type = "fs", root = "/opt/myapp/data", allow_write = true })
		T.eq(result.severity, "high")
		T.ok(result.text:find("/opt/myapp/data"), "text includes root path")
	end)

	T.it("missing root uses fallback text", function()
		local result = fs.risk({ type = "fs" })
		T.ok(result ~= nil)
		T.ok(result.text ~= nil)
	end)

	T.it("/tmp read is low severity", function()
		local result = fs.risk({ type = "fs", root = "/tmp" })
		T.eq(result.severity, "low")
	end)

	T.it("/tmp write is medium severity", function()
		local result = fs.risk({ type = "fs", root = "/tmp", allow_write = true })
		T.eq(result.severity, "medium")
	end)

	T.it("risk text is a non-empty string", function()
		local result = fs.risk({ type = "fs", root = "/tmp/app" })
		T.ok(type(result.text) == "string" and #result.text > 0)
	end)

	T.it("risk has severity field", function()
		local result = fs.risk({ type = "fs", root = "/tmp/app" })
		T.ok(result.severity ~= nil)
	end)
end)
