-- lib/github/init.lua
-- GitHub REST API client for crescent.
-- All methods return (value, nil) on success, (nil, errmsg) on failure.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

-- Lazy-load the HTTPS client so that requiring lib.github does not fail
-- in environments where TLS is unavailable (e.g. test runners without libtls).
local _http --: { request: (unknown) -> (unknown, string | nil) } | nil
local function http()
	if not _http then
		_http = (require("lib.https.client") --[[:! { request: (unknown) -> (unknown, string | nil) }]])
	end
	return _http --[[:! { request: (unknown) -> (unknown, string | nil) }]]
end

--:: github_client = { token: string | nil }

local M = {}

local BASE_HOST = "api.github.com"
local API_VERSION = "2022-11-28"

-- Build the common headers table for a client, including Authorization if token is set.
local function make_headers(self)
	local headers = {
		["Accept"] = { "application/vnd.github+json" },
		["X-GitHub-Api-Version"] = { API_VERSION },
	}
	if self.token then
		headers["Authorization"] = { "Bearer " .. self.token }
	end
	return headers
end

-- Send an HTTP request to the GitHub API and return the parsed JSON body.
-- method: HTTP method string (e.g. "GET", "POST", "PATCH")
-- path:   API path starting with "/" (e.g. "/repos/owner/repo/branches")
-- body:   optional request body string (already JSON-encoded)
--: (github_client, string, string, string | nil) -> (unknown, string | nil)
local function request(self, method, path, body)
	local headers = make_headers(self)
	if body then
		headers["Content-Type"] = { "application/json" }
	end
	local res_raw, err = http().request({
		method = method,
		host = BASE_HOST,
		path = path,
		headers = headers,
		body = body,
	})
	if not res_raw then
		return nil, err
	end
	local res = (res_raw --[[:! { status: integer, body: string | nil }]])
	if res.status >= 400 then
		return nil, "github: HTTP " .. res.status .. ": " .. (res.body or "")
	end
	local value, decode_err = json.decode(res.body or "")
	if not value then
		return nil, "github: JSON decode failed: " .. (decode_err or "unknown")
	end
	return value
end

-- client metatable: methods are called as client:method(...)
local client_mt = {}
client_mt.__index = client_mt

client_mt.request = function(self, method, path, body)
	return request(self, method, path, body)
end

-- Repos

-- List branches for a repository.
-- https://docs.github.com/en/rest/branches/branches#list-branches
--: (github_client, string, string) -> (unknown, string | nil)
client_mt.list_branches = function(self, owner, repo)
	return request(self, "GET", "/repos/" .. owner .. "/" .. repo .. "/branches")
end

-- Get a branch.
-- https://docs.github.com/en/rest/branches/branches#get-a-branch
--: (github_client, string, string, string) -> (unknown, string | nil)
client_mt.get_branch = function(self, owner, repo, branch)
	return request(self, "GET", "/repos/" .. owner .. "/" .. repo .. "/branches/" .. branch)
end

-- Rename a branch.
-- https://docs.github.com/en/rest/branches/branches#rename-a-branch
--: (github_client, string, string, string, string) -> (unknown, string | nil)
client_mt.rename_branch = function(self, owner, repo, old_name, new_name)
	local body, err = json.encode({ new_name = new_name })
	if not body then
		return nil, "github: JSON encode failed: " .. (err or "unknown")
	end
	return request(self, "POST", "/repos/" .. owner .. "/" .. repo .. "/branches/" .. old_name .. "/rename", body)
end

-- Construct a new GitHub API client.
-- token is a GitHub personal access token; pass nil for unauthenticated (public API only).
--: (string | nil) -> github_client
M.new = function(token)
	return setmetatable({ token = token }, client_mt)
end

return M
