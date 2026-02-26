local urlencode = require("lib.urlencode")

local function assert_eq(a, b, msg)
	if a ~= b then error(msg .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- round-trip: encode then decode
local cases = {
	{ "hello world", "hello%20world" },
	{ "/path?q=1&b=2", "%2fpath%3fq=1%26b=2" },
	{ "café", "caf%c3%a9" },
	{ "a+b=c", "a+b=c" },
	{ "", "" },
}

for _, case in ipairs(cases) do
	local input, expected = case[1], case[2]
	local encoded = urlencode.string_to_urlencode(input)
	assert_eq(encoded, expected, "encode " .. input)
	local decoded = urlencode.urlencode_to_string(encoded)
	assert_eq(decoded, input, "round-trip " .. input)
end

-- decode standalone
assert_eq(urlencode.urlencode_to_string("%2F"), "/", "decode %2F")
assert_eq(urlencode.urlencode_to_string("%2f"), "/", "decode %2f lowercase")
