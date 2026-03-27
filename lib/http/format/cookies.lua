-- RFC 6265 §4.2.1 — Cookie header parsing
-- cookie-header = "Cookie:" OWS cookie-string OWS
-- cookie-string = cookie-pair *( ";" SP cookie-pair )
-- cookie-pair   = cookie-name "=" cookie-value

local mod = {}

--: (http_request) -> { [string]: string }?
mod.parse_cookies = function(req)
	local cookie_hdr = (req.headers["cookie"] or {})[1]
	if not cookie_hdr then return nil end
	local cookies = {}
	-- RFC 6265 §4.2.1 — pairs separated by "; "
	local pos = 1
	local len = #cookie_hdr
	while pos <= len do
		local eq = cookie_hdr:find("=", pos, true)
		if not eq then break end
		local name = cookie_hdr:sub(pos, eq - 1)
		local semi = cookie_hdr:find("; ", eq + 1, true)
		local value
		if semi then
			value = cookie_hdr:sub(eq + 1, semi - 1)
			pos = semi + 2
		else
			value = cookie_hdr:sub(eq + 1)
			pos = len + 1
		end
		cookies[name] = value
	end
	return cookies
end

-- Backward-compatible alias
mod.http_request_to_cookies = mod.parse_cookies

return mod
