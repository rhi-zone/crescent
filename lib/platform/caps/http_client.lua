-- lib/platform/caps/http_client.lua
-- http_client_cap(opts) -> capability table, revoke_fn
-- Stub: provides the interface shape. Actual requests require lib/http wiring.
--
-- opts.host : string (restrict requests to this host, nil = any)
--
-- Capability API (passed to sandbox as caps.http_client):
--   cap.get(url, headers?)    -> {status, headers, body} | nil, err
--   cap.post(url, body, headers?) -> {status, headers, body} | nil, err
--   cap.request(opts)         -> {status, headers, body} | nil, err

local M = {}

function M.http_client_cap(opts)
	opts = opts or {}
	local allowed_host = opts.host
	local revoked = false

	local function check_host(url)
		if revoked then return nil, "http_client: capability revoked" end
		if not allowed_host then return true end
		-- Simple host check: url must contain the allowed host
		if not url:find(allowed_host, 1, true) then
			return nil, "http_client: host '" .. tostring(allowed_host) .. "' required, got '" .. tostring(url) .. "'"
		end
		return true
	end

	local cap = {
		get = function(url, headers)
			local ok, err = check_host(url)
			if not ok then return nil, err end
			-- Stub: real implementation would use lib/http
			return nil, "http_client: not yet implemented"
		end,
		post = function(url, body, headers)
			local ok, err = check_host(url)
			if not ok then return nil, err end
			return nil, "http_client: not yet implemented"
		end,
		request = function(req)
			local ok, err = check_host(req and req.url or "")
			if not ok then return nil, err end
			return nil, "http_client: not yet implemented"
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
