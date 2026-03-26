local t = require("lib.type")
local check = require("lib.type.check").check
local assert = require("lib.test.assert")

-- integer
assert.ok(check(t.integer, 1), "integer 1")
assert.ok(check(t.integer, 0), "integer 0")
assert.ok(check(t.integer, -5), "integer -5")
assert.ok(check(t.integer, 1e10), "integer 1e10")
assert.fail(check(t.integer, 1.5), "integer rejects float")
assert.fail(check(t.integer, "1"), "integer rejects string")
assert.fail(check(t.integer, nil), "integer rejects nil")

-- number
assert.ok(check(t.number, 1), "number int")
assert.ok(check(t.number, 1.5), "number float")
assert.fail(check(t.number, "1"), "number rejects string")

-- string
assert.ok(check(t.string, "hello"), "string")
assert.ok(check(t.string, ""), "string empty")
assert.fail(check(t.string, 1), "string rejects number")

-- boolean
assert.ok(check(t.boolean, true), "boolean true")
assert.ok(check(t.boolean, false), "boolean false")
assert.fail(check(t.boolean, nil), "boolean rejects nil")
assert.fail(check(t.boolean, 0), "boolean rejects 0")

-- nil
assert.ok(check(t["nil"], nil), "nil")
assert.fail(check(t["nil"], false), "nil rejects false")

-- literal
local lit = t.literal("hello")
assert.ok(check(lit, "hello"), "literal match")
assert.fail(check(lit, "world"), "literal mismatch")
assert.fail(check(lit, 1), "literal type mismatch")

-- tuple
local tup = t.tuple({ t.string, t.number })
assert.ok(check(tup, { "a", 1 }), "tuple match")
assert.ok(check(tup, { "a", 1, "extra" }), "tuple allows extra")
assert.fail(check(tup, { 1, "a" }), "tuple wrong order")
assert.fail(check(tup, "not a table"), "tuple rejects non-table")

-- struct
local s = t.struct({ name = t.string, age = t.number })
assert.ok(check(s, { name = "alice", age = 30 }), "struct match")
assert.ok(check(s, { name = "alice", age = 30, extra = true }), "struct allows extra")
assert.fail(check(s, { name = "alice" }), "struct missing field")
assert.fail(check(s, "not a table"), "struct rejects non-table")

-- struct_exact
local se = t.struct_exact({ name = t.string })
assert.ok(check(se, { name = "alice" }), "struct_exact match")
assert.fail(check(se, { name = "alice", extra = true }), "struct_exact rejects extra")
assert.fail(check(se, { name = 1 }), "struct_exact wrong type")

-- array
local arr = t.array(t.number)
assert.ok(check(arr, { 1, 2, 3 }), "array match")
assert.ok(check(arr, {}), "array empty")
assert.fail(check(arr, { 1, "two" }), "array mixed")
assert.fail(check(arr, "not a table"), "array rejects non-table")

-- dictionary
local dict = t.dictionary(t.string, t.number)
assert.ok(check(dict, { a = 1, b = 2 }), "dict match")
assert.ok(check(dict, {}), "dict empty")
assert.fail(check(dict, { a = "one" }), "dict wrong value type")

-- optional
local opt = t.optional(t.string)
assert.ok(check(opt, "hello"), "optional present")
assert.ok(check(opt, nil), "optional nil")
assert.fail(check(opt, 1), "optional wrong type")

-- any_of
local any = t.any_of(t.string, t.number)
assert.ok(check(any, "hello"), "any_of string")
assert.ok(check(any, 42), "any_of number")
assert.fail(check(any, true), "any_of rejects boolean")

-- all_of
local all = t.all_of(t.struct({ name = t.string }), t.struct({ age = t.number }))
assert.ok(check(all, { name = "alice", age = 30 }), "all_of match")
assert.fail(check(all, { name = "alice" }), "all_of partial")

-- ── validate ──────────────────────────────────────────────────────────────────

local validate = require("lib.type.check").validate

-- primitives
do
	local v, err = validate(t.integer, 7)
	assert.eq(v, 7, "validate integer returns value")
	assert.fail(err, "validate integer no error")

	v, err = validate(t.integer, "7")
	assert.fail(v, "validate integer rejects string")
	assert.ok(err, "validate integer has error")
	assert.ok(err:find("integer"), "validate integer error mentions type")

	v, err = validate(t.string, "hi")
	assert.eq(v, "hi", "validate string returns value")
	assert.fail(err)

	v, err = validate(t.boolean, true)
	assert.eq(v, true, "validate boolean true")
	assert.fail(err)
end

-- optional
do
	local v, err = validate(t.optional(t.integer), nil)
	assert.fail(v, "validate optional nil: value is nil")
	assert.fail(err, "validate optional nil: no error")

	v, err = validate(t.optional(t.integer), 5)
	assert.eq(v, 5, "validate optional present")
	assert.fail(err)

	v, err = validate(t.optional(t.integer), "bad")
	assert.fail(v, "validate optional wrong type")
	assert.ok(err)
end

-- struct error paths
do
	local s = t.struct({ age = t.integer, name = t.string })
	local _, err = validate(s, { age = "bad", name = "Alice" })
	assert.ok(err, "struct validate error")
	assert.ok(err:find("age"), "struct error includes field name")

	-- nested struct: dotted path
	local ns = t.struct({ address = t.struct({ city = t.string }) })
	_, err = validate(ns, { address = { city = 99 } })
	assert.ok(err)
	assert.ok(err:find("address"), "nested path includes parent")
	assert.ok(err:find("city"), "nested path includes field")

	-- struct_exact rejects extras
	local se = t.struct_exact({ x = t.integer })
	_, err = validate(se, { x = 1, y = 2 })
	assert.ok(err)
	assert.ok(err:find("unexpected"), "struct_exact unexpected field error")

	-- returns original table on success
	local tbl = { x = 1 }
	local v, _ = validate(t.struct({ x = t.integer }), tbl)
	assert.ok(v == tbl, "validate struct returns same table ref")
end

-- array error path includes index
do
	local _, err = validate(t.array(t.integer), { 1, 2, "bad" })
	assert.ok(err)
	assert.ok(err:find("%[3%]"), "array error includes index")
end

-- any_of / all_of
do
	local v, err = validate(t.any_of(t.integer, t.string), 3)
	assert.eq(v, 3); assert.fail(err)

	_, err = validate(t.any_of(t.integer, t.string), true)
	assert.ok(err, "any_of no match error")

	v, err = validate(t.all_of(t.struct({ x = t.integer }), t.struct({ y = t.string })), { x = 1, y = "a" })
	assert.ok(v); assert.fail(err)
end

-- ── coerce ────────────────────────────────────────────────────────────────────

local coerce = require("lib.type.check").coerce

-- scalar coercions
do
	-- integer ← integer string
	local v, err = coerce(t.integer, "42")
	assert.eq(v, 42, "coerce integer from string"); assert.fail(err)

	-- integer rejects non-integer string
	_, err = coerce(t.integer, "3.5")
	assert.ok(err, "coerce integer rejects float string")

	-- integer rejects non-integer number
	_, err = coerce(t.integer, 3.5)
	assert.ok(err, "coerce integer rejects float number")

	-- number ← numeric string
	v, err = coerce(t.number, "2.5")
	assert.eq(v, 2.5, "coerce number from string"); assert.fail(err)

	-- number rejects non-numeric string
	_, err = coerce(t.number, "abc")
	assert.ok(err)

	-- string ← number
	v, err = coerce(t.string, 42)
	assert.eq(v, "42", "coerce string from number"); assert.fail(err)

	-- string rejects boolean
	_, err = coerce(t.string, true)
	assert.ok(err)

	-- boolean is strict
	v, err = coerce(t.boolean, true)
	assert.eq(v, true); assert.fail(err)
	_, err = coerce(t.boolean, 1)
	assert.ok(err, "coerce boolean rejects number")
end

-- struct: returns fresh copy with coerced fields
do
	local s = t.struct({ x = t.integer, label = t.string })
	local v, err = coerce(s, { x = "7", label = 99 })
	assert.fail(err)
	assert.eq(v.x, 7, "coerce struct field integer")
	assert.eq(v.label, "99", "coerce struct field string")

	local orig = { x = "7", label = 99 }
	v, _ = coerce(s, orig)
	assert.ok(v ~= orig, "coerce struct returns fresh table")
end

-- array: fresh copy with coerced items
do
	local v, err = coerce(t.array(t.integer), { "1", "2", "3" })
	assert.fail(err)
	assert.eq(v[1], 1); assert.eq(v[2], 2); assert.eq(v[3], 3)
end

-- optional coercion
do
	local v, err = coerce(t.optional(t.integer), nil)
	assert.fail(v); assert.fail(err, "coerce optional nil: no error")

	v, err = coerce(t.optional(t.integer), "5")
	assert.eq(v, 5, "coerce optional coerces inner"); assert.fail(err)
end

-- any_of: first matching variant wins
do
	-- "10" coerces to integer 10 (integer is tried first)
	local s = t.any_of(t.integer, t.string)
	local v, err = coerce(s, "10")
	assert.fail(err); assert.eq(v, 10, "coerce any_of picks first coercible")

	-- true: string coercer rejects boolean, boolean coercer accepts
	local s2 = t.any_of(t.string, t.boolean)
	v, err = coerce(s2, true)
	assert.fail(err); assert.eq(v, true, "coerce any_of falls through to bool")
end
