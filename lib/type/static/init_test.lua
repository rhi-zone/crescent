-- lib/type/static/init_test.lua
-- Tests for the static typechecker.

local assert = require("lib.test.assert")
local types = require("lib.type.static.types")
local env = require("lib.type.static.env")
local unify = require("lib.type.static.unify")
local annotations = require("lib.type.static.annotations")
local checker = require("lib.type.static")
local errors = require("lib.type.static.errors")

local T = types

---------------------------------------------------------------------------
-- types.lua
---------------------------------------------------------------------------

assert.eq(T.NIL().tag, "nil", "primitive nil")
assert.eq(T.BOOLEAN().tag, "boolean", "primitive boolean")
assert.eq(T.NUMBER().tag, "number", "primitive number")
assert.eq(T.INTEGER().tag, "integer", "primitive integer")
assert.eq(T.STRING().tag, "string", "primitive string")
assert.eq(T.ANY().tag, "any", "primitive any")
assert.eq(T.NEVER().tag, "never", "primitive never")

-- literal
local s = T.literal("string", "hello")
assert.eq(s.tag, "literal", "literal tag")
assert.eq(s.kind, "string", "literal kind")
assert.eq(s.value, "hello", "literal value")

-- function type
local fn = T.func({ T.NUMBER(), T.STRING() }, { T.BOOLEAN() })
assert.eq(fn.tag, "function", "func tag")
assert.eq(#fn.params, 2, "func params count")
assert.eq(#fn.returns, 1, "func returns count")

-- union flattens
local u = T.union({ T.union({ T.STRING(), T.NUMBER() }), T.BOOLEAN() })
assert.eq(u.tag, "union", "union tag")
assert.eq(#u.types, 3, "union flattens")

-- union of one
local u1 = T.union({ T.STRING() })
assert.eq(u1.tag, "string", "union of one")

-- union eliminates never
local un = T.union({ T.STRING(), T.NEVER() })
assert.eq(un.tag, "string", "union removes never")

-- display
assert.eq(T.display(T.NUMBER()), "number", "display number")
assert.eq(T.display(T.STRING()), "string", "display string")
assert.eq(T.display(T.func({ T.NUMBER() }, { T.STRING() })), "(number) -> string", "display func")
assert.eq(T.display(T.union({ T.STRING(), T.NUMBER() })), "string | number", "display union")

-- type variable
T.reset_counter()
local v = T.typevar(0)
assert.eq(v.tag, "var", "typevar tag")
v.bound = T.STRING()
assert.eq(T.resolve(v).tag, "string", "typevar resolve")

---------------------------------------------------------------------------
-- env.lua
---------------------------------------------------------------------------

local scope = env.new()
env.bind(scope, "x", T.NUMBER())
assert.eq(env.lookup(scope, "x").tag, "number", "env lookup")
assert.eq(env.lookup(scope, "y"), nil, "env lookup nil")

-- child scope
local parent = env.new()
env.bind(parent, "x", T.NUMBER())
local child = env.child(parent)
env.bind(child, "y", T.STRING())
assert.eq(env.lookup(child, "x").tag, "number", "child sees parent")
assert.eq(env.lookup(child, "y").tag, "string", "child own binding")
assert.eq(env.lookup(parent, "y"), nil, "parent cant see child")

-- shadowing
local p2 = env.new()
env.bind(p2, "x", T.NUMBER())
local c2 = env.child(p2)
env.bind(c2, "x", T.STRING())
assert.eq(env.lookup(c2, "x").tag, "string", "child shadows parent")

---------------------------------------------------------------------------
-- unify.lua
---------------------------------------------------------------------------

assert.ok(unify.unify(T.NUMBER(), T.NUMBER()), "same primitives")
assert.ok(unify.unify(T.INTEGER(), T.NUMBER()), "integer <: number")

local ok_str_num, _ = unify.unify(T.STRING(), T.NUMBER())
assert.ok(not ok_str_num, "different primitives fail")

-- literals
assert.ok(unify.unify(T.literal("string", "hello"), T.STRING()), "literal string <: string")
assert.ok(unify.unify(T.literal("number", 42), T.NUMBER()), "literal number <: number")
assert.ok(unify.unify(T.literal("boolean", true), T.BOOLEAN()), "literal bool <: boolean")

-- any bilateral
assert.ok(unify.unify(T.ANY(), T.NUMBER()), "any -> number")
assert.ok(unify.unify(T.STRING(), T.ANY()), "string -> any")

-- never bottom
assert.ok(unify.unify(T.NEVER(), T.NUMBER()), "never -> number")

-- type var binding
T.reset_counter()
local tv = T.typevar(0)
assert.ok(unify.unify(tv, T.STRING()), "typevar binds")
assert.eq(T.resolve(tv).tag, "string", "typevar resolves after bind")

-- union LHS
local ul = T.union({ T.literal("string", "a"), T.literal("string", "b") })
assert.ok(unify.unify(ul, T.STRING()), "union lhs all match")

-- union RHS
local ur = T.union({ T.STRING(), T.NUMBER() })
assert.ok(unify.unify(T.STRING(), ur), "union rhs match string")
assert.ok(unify.unify(T.NUMBER(), ur), "union rhs match number")
local ok_bool_ur, _ = unify.unify(T.BOOLEAN(), ur)
assert.ok(not ok_bool_ur, "union rhs rejects boolean")

-- function types
assert.ok(unify.unify(
  T.func({ T.NUMBER() }, { T.STRING() }),
  T.func({ T.NUMBER() }, { T.STRING() })
), "func types match")

-- table structural subtyping
local ta = T.table({ x = { type = T.NUMBER(), optional = false }, y = { type = T.STRING(), optional = false } }, {})
local tb = T.table({ x = { type = T.NUMBER(), optional = false } }, {})
assert.ok(unify.unify(ta, tb), "table subtype with extra fields")

-- table missing required field
local ta2 = T.table({ x = { type = T.NUMBER(), optional = false } }, {})
local tb2 = T.table({ x = { type = T.NUMBER(), optional = false }, y = { type = T.STRING(), optional = false } }, {})
local ok_missing, _ = unify.unify(ta2, tb2)
assert.ok(not ok_missing, "table missing required field")

---------------------------------------------------------------------------
-- annotations.lua
---------------------------------------------------------------------------

-- parse primitives
assert.eq(annotations.parse_type("number").tag, "number", "ann parse number")
assert.eq(annotations.parse_type("string").tag, "string", "ann parse string")
assert.eq(annotations.parse_type("boolean").tag, "boolean", "ann parse boolean")
assert.eq(annotations.parse_type("nil").tag, "nil", "ann parse nil")
assert.eq(annotations.parse_type("any").tag, "any", "ann parse any")
assert.eq(annotations.parse_type("never").tag, "never", "ann parse never")

-- optional
local opt = annotations.parse_type("string?")
assert.eq(opt.tag, "union", "ann optional is union")

-- union
local unn = annotations.parse_type("string | number")
assert.eq(unn.tag, "union", "ann union")
assert.eq(#unn.types, 2, "ann union members")

-- function type
local fty = annotations.parse_type("(number, string) -> boolean")
assert.eq(fty.tag, "function", "ann func tag")
assert.eq(#fty.params, 2, "ann func params")
assert.eq(fty.params[1].tag, "number", "ann func param1")
assert.eq(#fty.returns, 1, "ann func returns")
assert.eq(fty.returns[1].tag, "boolean", "ann func return type")

-- void function
local vfn = annotations.parse_type("() -> ()")
assert.eq(vfn.tag, "function", "ann void func")
assert.eq(#vfn.params, 0, "ann void func params")
assert.eq(#vfn.returns, 0, "ann void func returns")

-- record type
local rec = annotations.parse_type("{ name: string, age?: number }")
assert.eq(rec.tag, "table", "ann record tag")
assert.ok(rec.fields.name, "ann record field name")
assert.eq(rec.fields.name.type.tag, "string", "ann record field type")
assert.eq(rec.fields.age.optional, true, "ann record optional field")

-- array type
local arr = annotations.parse_type("[number]")
assert.eq(arr.tag, "table", "ann array tag")
assert.eq(#arr.indexers, 1, "ann array indexer")
assert.eq(arr.indexers[1].value.tag, "number", "ann array elem type")

-- dictionary type
local dict = annotations.parse_type("{ [string]: number }")
assert.eq(dict.tag, "table", "ann dict tag")
assert.eq(dict.indexers[1].key.tag, "string", "ann dict key")
assert.eq(dict.indexers[1].value.tag, "number", "ann dict value")

-- literal types
local sl = annotations.parse_type('"GET"')
assert.eq(sl.tag, "literal", "ann literal string tag")
assert.eq(sl.value, "GET", "ann literal string value")

local nl = annotations.parse_type("42")
assert.eq(nl.tag, "literal", "ann literal number tag")
assert.eq(nl.value, 42, "ann literal number value")

local bl = annotations.parse_type("true")
assert.eq(bl.tag, "literal", "ann literal bool tag")
assert.eq(bl.value, true, "ann literal bool value")

-- named type
local named = annotations.parse_type("MyType")
assert.eq(named.tag, "named", "ann named tag")
assert.eq(named.name, "MyType", "ann named name")

-- generic named type
local gen = annotations.parse_type("Result[number, string]")
assert.eq(gen.tag, "named", "ann generic tag")
assert.eq(gen.name, "Result", "ann generic name")
assert.eq(#gen.args, 2, "ann generic args")

-- multi-return function
local mret = annotations.parse_type("(string) -> (number, string)")
assert.eq(mret.tag, "function", "ann multi-return tag")
assert.eq(#mret.returns, 2, "ann multi-return count")

-- named params
local np = annotations.parse_type("(x: number, y: number) -> number")
assert.eq(np.tag, "function", "ann named params tag")
assert.eq(#np.params, 2, "ann named params count")
assert.eq(np.params[1].tag, "number", "ann named param type")

-- vararg
local va = annotations.parse_type("(string, ...any) -> string")
assert.eq(va.tag, "function", "ann vararg tag")
assert.eq(#va.params, 1, "ann vararg params")
assert.ok(va.vararg, "ann vararg exists")
assert.eq(va.vararg.tag, "any", "ann vararg type")

-- intersection
local inter = annotations.parse_type("Readable & Writable")
assert.eq(inter.tag, "intersection", "ann intersection tag")
assert.eq(#inter.types, 2, "ann intersection members")

-- array suffix
local arrs = annotations.parse_type("string[]")
assert.eq(arrs.tag, "table", "ann array suffix tag")
assert.eq(arrs.indexers[1].value.tag, "string", "ann array suffix elem")

-- extract signatures
local source1 = "--: (number, number) -> number\nlocal function add(a, b) return a + b end\nlocal x = 42 --: number\n"
local map1 = annotations.build_map(source1)
assert.ok(map1[2], "ann sig on next line")
assert.eq(map1[2].kind, "type_annotation", "ann sig kind")
assert.eq(map1[2].type.tag, "function", "ann sig is func")
assert.ok(map1[3], "ann eol")
assert.eq(map1[3].kind, "type_annotation", "ann eol kind")
assert.eq(map1[3].type.tag, "number", "ann eol type")

-- type declarations
local source2 = '--:: Point = { x: number, y: number }\n--:: Color = "red" | "green" | "blue"\n'
local map2 = annotations.build_map(source2)
assert.ok(map2[1], "ann decl line1")
assert.eq(map2[1].kind, "type_decl", "ann decl kind1")
assert.eq(map2[1].name, "Point", "ann decl name1")
assert.ok(map2[2], "ann decl line2")
assert.eq(map2[2].kind, "type_decl", "ann decl kind2")
assert.eq(map2[2].name, "Color", "ann decl name2")

---------------------------------------------------------------------------
-- Full checker integration
---------------------------------------------------------------------------

-- clean code passes
local ok1, _ = checker.check("local x = 1\nlocal y = 'hello'\nlocal z = true\n", "test.lua")
assert.ok(ok1, "clean code passes")

-- arithmetic on string
local ok2, errs2 = checker.check('local x = "hello" + 1\n', "test.lua")
assert.ok(not ok2, "arithmetic on string detected")
assert.ok(errs2:find("arithmetic"), "arithmetic error message")

-- wrong arg type
local ok3, errs3 = checker.check('local x = math.sqrt("hello")\n', "test.lua")
assert.ok(not ok3, "wrong arg type detected")
assert.ok(errs3:find("cannot pass"), "wrong arg error message")

-- annotation mismatch
local ok4, errs4 = checker.check('local x = "hello" --: number\n', "test.lua")
assert.ok(not ok4, "annotation mismatch detected")
assert.ok(errs4:find("not assignable"), "annotation mismatch message")

-- function annotation validates args
local ok5, errs5 = checker.check(
  '--: (number, number) -> number\nlocal function add(a, b) return a + b end\nadd("x", 1)\n',
  "test.lua")
assert.ok(not ok5, "func annotation catches wrong args")
assert.ok(errs5:find("cannot pass"), "func annotation error message")

-- table field access
local ok6, _ = checker.check("local t = { x = 1, y = 'hello' }\nlocal a = t.x\nlocal b = t.y\n", "test.lua")
assert.ok(ok6, "table field access works")

-- control flow scoping
local ok7, _ = checker.check([[
local x = 1
if x then local y = 2 end
while true do local z = 3 break end
for i = 1, 10 do local w = i end
]], "test.lua")
assert.ok(ok7, "control flow scoping works")

-- string concat with table
local ok8, errs8 = checker.check('local t = {}\nlocal x = "hello" .. t\n', "test.lua")
assert.ok(not ok8, "concat with table detected")
assert.ok(errs8:find("concatenate"), "concat error message")

-- type declarations parsed
local ok9, _ = checker.check('--:: Point = { x: number, y: number }\nlocal p = { x = 1, y = 2 }\n', "test.lua")
assert.ok(ok9, "type declarations parsed")

-- module pattern
local ok10, _ = checker.check([[
local M = {}
function M.add(a, b) return a + b end
return M
]], "test.lua")
assert.ok(ok10, "module pattern works")
