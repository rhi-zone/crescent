local merge = require("lib.merge").merge
local assert = require("lib.test.assert")

-- basic key merge
local r = merge({ a = 1 }, { b = 2 })
assert.eq(r.a, 1, "key a")
assert.eq(r.b, 2, "key b")

-- later values override
local r2 = merge({ a = 1 }, { a = 2 })
assert.eq(r2.a, 2, "override")

-- array part: later values at same index overwrite
local r3 = merge({ "x", "y" }, { "z" })
assert.eq(r3[1], "z", "array overwrite [1]")
assert.eq(r3[2], "y", "array kept [2]")

-- mixed array and hash
local r4 = merge({ "a", name = "alice" }, { "b", name = "bob" })
assert.eq(r4[1], "b", "mixed array overwrite")
assert.eq(r4.name, "bob", "mixed hash override")

-- empty inputs
local r5 = merge({}, { a = 1 })
assert.eq(r5.a, 1, "empty left")
local r6 = merge({ a = 1 }, {})
assert.eq(r6.a, 1, "empty right")

-- does not mutate inputs
local orig = { a = 1 }
merge(orig, { b = 2 })
assert.eq(orig.b, nil, "no mutation")
