if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local M = {}

local CAP_MODULES = --[[:! { [string]: string }]] {
	cli         = "lib.platform.caps.cli",
	create_instance = "lib.platform.caps.create_instance",
	db          = "lib.platform.caps.db",
	exec        = "lib.platform.caps.exec",
	fs          = "lib.platform.caps.fs",
	http_client = "lib.platform.caps.http_client",
	http_server = "lib.platform.caps.http_server",
	kv          = "lib.platform.caps.kv",
	llm         = "lib.platform.caps.llm",
	registry    = "lib.platform.caps.registry",
	self        = "lib.platform.caps.self",
	self_write  = "lib.platform.caps.self",
	shared_db   = "lib.platform.caps.shared_db",
	shell       = "lib.platform.caps.shell",
	stderr      = "lib.platform.caps.stderr",
	stdin       = "lib.platform.caps.stdin",
	stdout      = "lib.platform.caps.stdout",
	time        = "lib.platform.caps.time",
}

function M.risk(decl)
	local decl_ = decl --[[:! { type: string, ... }]]
	local path = CAP_MODULES[decl_.type]
	if not path then return nil end
	local mod_raw = require(path)
	local mod_ = mod_raw --[[:! { risk: unknown | nil }]]
	if not mod_.risk then return nil end
	local risk_fn = mod_.risk --[[:! (unknown) -> unknown]]
	return risk_fn(decl_)
end

return M
