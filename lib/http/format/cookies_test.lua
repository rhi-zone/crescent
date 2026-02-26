local cookies = require("lib.http.format.cookies")

local function assert_eq(a, b, msg)
	if a ~= b then error(msg .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- parse cookies from request headers
local req = {
	headers = { cookie = { "session=abc123; theme=dark; lang=en" } },
}
local c = cookies.http_request_to_cookies(req)
assert(c, "should parse cookies")
assert_eq(c.session, "abc123", "session cookie")
assert_eq(c.theme, "dark", "theme cookie")
assert_eq(c.lang, "en", "lang cookie")

-- no cookie header
local req_none = { headers = {} }
local c_none = cookies.http_request_to_cookies(req_none)
assert_eq(c_none, nil, "no cookies returns nil")
