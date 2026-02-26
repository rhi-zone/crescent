local form = require("lib.http.format.form_urlencode")

local function assert_eq(a, b, msg)
	if a ~= b then error(msg .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- parse urlencoded form body
local req = {
	method = "POST",
	headers = { ["content-type"] = { "application/x-www-form-urlencoded" } },
	body = "name=John%20Doe&email=john%40example.com",
}
local f = form.http_request_to_urlencoded_form_body(req)
assert(f, "should parse form body")
assert_eq(f.name, "John Doe", "decoded name")
assert_eq(f.email, "john@example.com", "decoded email")

-- wrong method returns nil
local req_get = {
	method = "GET",
	headers = { ["content-type"] = { "application/x-www-form-urlencoded" } },
	body = "a=b",
}
assert_eq(form.http_request_to_urlencoded_form_body(req_get), nil, "GET returns nil")

-- wrong content-type returns nil
local req_json = {
	method = "POST",
	headers = { ["content-type"] = { "application/json" } },
	body = "a=b",
}
assert_eq(form.http_request_to_urlencoded_form_body(req_json), nil, "json content-type returns nil")
