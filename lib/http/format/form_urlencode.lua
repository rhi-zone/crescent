local urlencode_to_string = require("lib.encode.urlencode").urlencode_to_string

local mod = {}

--: ({ method: string, headers: { [string]: { [integer]: string } }, body: string, ... }) -> { [string]: string } | nil
mod.http_request_to_urlencoded_form_body = function (req)
	if req.method ~= "POST" or req.headers["content-type"][1] ~= "application/x-www-form-urlencoded" then return end
	local ret = {}
	for k, v in req.body:gmatch("([^=&]*)=?([^&]*)&?") do
		ret[urlencode_to_string(k)] = urlencode_to_string(v)
	end
	return ret
end

return mod
