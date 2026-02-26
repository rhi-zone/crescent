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
