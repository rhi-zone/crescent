if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local M = {}

local function fs_risk(decl)
	local root = decl.root or "a configured directory"
	if decl.readonly then
		return { severity = "medium", text = "Reads files under " .. root .. "." }
	end
	return { severity = "high", text = "Reads and writes files under " .. root .. ". Can modify or delete anything in that directory tree." }
end

local function http_client_risk(decl)
	local host = decl.host or "a configured host"
	if decl.paths then
		return { severity = "medium", text = "Sends HTTP requests to " .. host .. " restricted to configured paths and methods." }
	end
	return { severity = "high", text = "Sends arbitrary HTTP requests to " .. host .. ". Can leak data or trigger side effects on that host." }
end

local function db_risk(decl)
	if decl.readonly then
		return { severity = "low", text = "Reads a private SQLite database. No writes." }
	end
	return { severity = "low", text = "Reads and writes a private SQLite database. Data is isolated to this app." }
end

local function shared_db_risk(decl)
	if decl.readonly then
		return { severity = "low", text = "Reads a shared SQLite database." }
	end
	return { severity = "medium", text = "Reads and writes a shared SQLite database accessible to multiple apps." }
end

local function self_risk(decl)
	if decl.writable then
		return { severity = "medium", text = "Reads and writes the app's own bundle. Can modify the app's files." }
	end
	return { severity = "low", text = "Reads the app's own bundle (tarball entries, metadata). Cannot access other apps." }
end

local function registry_risk(decl)
	if decl.allow_write == false or decl.allow_write == nil then
		return { severity = "medium", text = "Reads Windows Registry keys under a configured root." }
	end
	return { severity = "high", text = "Reads and writes Windows Registry keys under a configured root. Registry writes can affect system behavior." }
end

local RISKS = {
	shell       = function() return { severity = "critical", text = "Runs arbitrary shell commands as your user. Can exfiltrate data, install malware, modify any file you own, or pivot to other systems." } end,
	exec        = function() return { severity = "high",     text = "Runs whitelisted binaries with controlled arguments. Severity depends on which binaries are whitelisted; network-capable tools (git, npm, curl) can fetch and execute arbitrary code." } end,
	fs          = fs_risk,
	http_client = http_client_risk,
	db          = db_risk,
	shared_db   = shared_db_risk,
	kv          = function() return { severity = "low",    text = "Reads and writes a private key-value store. Data is isolated to this app." } end,
	llm         = function() return { severity = "medium", text = "Sends prompts and receives responses from a language model API. Prompt content may leave your machine." } end,
	http_server = function() return { severity = "low",    text = "Accepts inbound HTTP connections on a local port. Exposes an HTTP endpoint." } end,
	self        = self_risk,
	self_write  = function() return { severity = "medium", text = "Reads and writes the app's own bundle. Can modify the app's files." } end,
	time        = function() return { severity = "low",    text = "Provides the current wall-clock time. No side effects." } end,
	stdout      = function() return { severity = "low",    text = "Writes to standard output." } end,
	stderr      = function() return { severity = "low",    text = "Writes to standard error." } end,
	stdin       = function() return { severity = "low",    text = "Reads from standard input." } end,
	cli         = function() return { severity = "low",    text = "Reads the command-line arguments passed to the app." } end,
	registry    = registry_risk,
}

function M.describe(decl)
	local fn = RISKS[decl.type]
	if not fn then return nil end
	return fn(decl)
end

return M
