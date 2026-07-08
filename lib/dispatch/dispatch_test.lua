local dispatch = require("lib.dispatch")
local assert = require("lib.test.assert")

-- dispatcher_from_table: dispatch keyed by a field on the first argument
local by_type = dispatch.dispatcher_from_table("type", {
	echo = function(msg) return msg.value end,
	double = function(msg) return msg.value * 2 end,
})
assert.eq(by_type({ type = "echo", value = "hi" }), "hi", "keyed by field")
assert.eq(by_type({ type = "double", value = 21 }), 42, "keyed by field, second handler")

-- unknown key raises
local ok, err = pcall(function() return by_type({ type = "missing" }) end)
assert.fail(ok, "unknown key raises")
assert.ok(tostring(err):find("no handler for key"), "error mentions the missing key")

-- dispatcher_from_table_by: dispatch keyed by a custom function of all args
local function key_of(a)
	if type(a) == "string" then return a end
	error("expected string key")
end
local by_first_arg = dispatch.dispatcher_from_table_by(key_of, {
	add = function(_a, b, c) return b + c end,
	sub = function(_a, b, c) return b - c end,
})
assert.eq(by_first_arg("add", 3, 4), 7, "keyed by custom function")
assert.eq(by_first_arg("sub", 10, 4), 6, "keyed by custom function, second handler")
