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

-- array type (explicit form: { [number]: T })
local arr = annotations.parse_type("{ [number]: number }")
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
local gen = annotations.parse_type("Result<number, string>")
assert.eq(gen.tag, "named", "ann generic tag")
assert.eq(gen.name, "Result", "ann generic name")
assert.eq(#gen.args, 2, "ann generic args")
assert.eq(gen.args[1].tag, "number", "ann generic arg1")
assert.eq(gen.args[2].tag, "string", "ann generic arg2")

-- nested generics
local nested = annotations.parse_type("Result<Option<number>, string>")
assert.eq(nested.tag, "named", "ann nested generic tag")
assert.eq(nested.name, "Result", "ann nested generic name")
assert.eq(#nested.args, 2, "ann nested generic args")
assert.eq(nested.args[1].tag, "named", "ann nested inner tag")
assert.eq(nested.args[1].name, "Option", "ann nested inner name")
assert.eq(#nested.args[1].args, 1, "ann nested inner args")
assert.eq(nested.args[1].args[1].tag, "number", "ann nested inner arg type")

-- generic with array suffix
local garr = annotations.parse_type("Option<string>[]")
assert.eq(garr.tag, "table", "ann generic array suffix tag")
assert.eq(garr.indexers[1].value.tag, "named", "ann generic array suffix elem")
assert.eq(garr.indexers[1].value.name, "Option", "ann generic array elem name")

-- single generic arg
local sgen = annotations.parse_type("Array<string>")
assert.eq(sgen.tag, "named", "ann single generic tag")
assert.eq(sgen.name, "Array", "ann single generic name")
assert.eq(#sgen.args, 1, "ann single generic args")

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

-- generic type declaration
local source3 = '--:: Pair<A, B> = { first: A, second: B }\n'
local map3 = annotations.build_map(source3)
assert.ok(map3[1], "ann generic decl exists")
assert.eq(map3[1].kind, "type_decl", "ann generic decl kind")
assert.eq(map3[1].name, "Pair", "ann generic decl name")
assert.ok(map3[1].params, "ann generic decl has params")
assert.eq(#map3[1].params, 2, "ann generic decl param count")
assert.eq(map3[1].params[1].name, "A", "ann generic decl param1 name")
assert.eq(map3[1].params[2].name, "B", "ann generic decl param2 name")

-- generic type declaration with constraint
local source4 = '--:: Numeric<T: number> = { value: T }\n'
local map4 = annotations.build_map(source4)
assert.ok(map4[1], "ann constrained decl exists")
assert.eq(map4[1].name, "Numeric", "ann constrained decl name")
assert.eq(#map4[1].params, 1, "ann constrained decl param count")
assert.eq(map4[1].params[1].name, "T", "ann constrained decl param name")
assert.ok(map4[1].params[1].constraint, "ann constrained decl has constraint")
assert.eq(map4[1].params[1].constraint.tag, "number", "ann constrained decl constraint type")

-- display named types
assert.eq(T.display({ tag = "named", name = "MyType", args = {} }), "MyType", "display named")
assert.eq(T.display({ tag = "named", name = "Result", args = { T.NUMBER(), T.STRING() } }),
  "Result<number, string>", "display generic")

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

---------------------------------------------------------------------------
-- Phase 2: Named type resolution
---------------------------------------------------------------------------

-- generic type alias resolves in annotation
local ok_alias, errs_alias = checker.check([[
--:: Pair<A, B> = { first: A, second: B }
local p = { first = 1, second = "hello" } --: Pair<number, string>
]], "test.lua")
assert.ok(ok_alias, "generic type alias resolves: " .. (errs_alias or ""))

-- generic alias mismatch detected
local ok_alias2, errs_alias2 = checker.check([[
--:: Pair<A, B> = { first: A, second: B }
local p = { first = 1, second = 2 } --: Pair<number, string>
]], "test.lua")
assert.ok(not ok_alias2, "generic alias mismatch detected")

-- simple (non-generic) alias resolves
local ok_alias3, errs_alias3 = checker.check([[
--:: Name = string
local x = "hello" --: Name
]], "test.lua")
assert.ok(ok_alias3, "simple alias resolves: " .. (errs_alias3 or ""))

-- forward references between type declarations
local ok_fwd, errs_fwd = checker.check([[
--:: Id = number
--:: Named = { id: Id, name: string }
local x = { id = 1, name = "test" } --: Named
]], "test.lua")
assert.ok(ok_fwd, "forward type references: " .. (errs_fwd or ""))

-- new type constructors
assert.eq(T.tuple({ T.NUMBER(), T.STRING() }).tag, "tuple", "tuple tag")
assert.eq(#T.tuple({ T.NUMBER(), T.STRING() }).elements, 2, "tuple elements")
assert.eq(T.spread(T.NUMBER()).tag, "spread", "spread tag")
assert.eq(T.nominal("UserId", {}, T.NUMBER()).tag, "nominal", "nominal tag")
assert.eq(T.intrinsic("EachField").tag, "intrinsic", "intrinsic tag")
assert.eq(T.type_call(T.intrinsic("Keys"), { T.ANY() }).tag, "type_call", "type_call tag")

-- display new types
assert.eq(T.display(T.tuple({ T.NUMBER(), T.STRING() })), "{ number, string }", "display tuple")
assert.eq(T.display(T.spread(T.NUMBER())), "...number", "display spread")
assert.eq(T.display(T.nominal("UserId", {}, T.NUMBER())), "UserId", "display nominal")
assert.eq(T.display(T.intrinsic("EachField")), "$EachField", "display intrinsic")

---------------------------------------------------------------------------
-- Phase 3: Tuples and Spread
---------------------------------------------------------------------------

-- parse tuple type
local tup = annotations.parse_type("{ number, string }")
assert.eq(tup.tag, "tuple", "ann tuple tag")
assert.eq(#tup.elements, 2, "ann tuple elements")
assert.eq(tup.elements[1].tag, "number", "ann tuple elem1")
assert.eq(tup.elements[2].tag, "string", "ann tuple elem2")

-- parse spread in tuple
local spr = annotations.parse_type("{ ...Base, string }")
assert.eq(spr.tag, "tuple", "ann spread tuple tag")
assert.eq(spr.elements[1].tag, "spread", "ann spread elem tag")

-- record type still works
local rec2 = annotations.parse_type("{ x: number, y: string }")
assert.eq(rec2.tag, "table", "ann record still works")
assert.ok(rec2.fields.x, "ann record field x")
assert.ok(rec2.fields.y, "ann record field y")

-- optional field still works
local optf = annotations.parse_type("{ name: string, age?: number }")
assert.eq(optf.tag, "table", "ann optional field record")
assert.eq(optf.fields.age.optional, true, "ann optional field flag")

-- tuple unification
assert.ok(unify.unify(T.tuple({ T.NUMBER(), T.STRING() }), T.tuple({ T.NUMBER(), T.STRING() })), "tuple unify same")
local ok_tup_mismatch, _ = unify.unify(T.tuple({ T.NUMBER() }), T.tuple({ T.STRING() }))
assert.ok(not ok_tup_mismatch, "tuple unify type mismatch")
local ok_tup_len, _ = unify.unify(T.tuple({ T.NUMBER() }), T.tuple({ T.NUMBER(), T.STRING() }))
assert.ok(not ok_tup_len, "tuple unify length mismatch")

-- tuple not assignable to array
local ok_tup_arr, _ = unify.unify(T.tuple({ T.NUMBER(), T.STRING() }), T.array(T.NUMBER()))
assert.ok(not ok_tup_arr, "tuple not assignable to array")

---------------------------------------------------------------------------
-- Phase 4: Type narrowing
---------------------------------------------------------------------------

-- types_equal
assert.ok(T.types_equal(T.NUMBER(), T.NUMBER()), "types_equal same")
assert.ok(not T.types_equal(T.NUMBER(), T.STRING()), "types_equal diff")
assert.ok(T.types_equal(T.NIL(), T.NIL()), "types_equal nil")

-- subtract
local sub1 = T.subtract(T.union({ T.STRING(), T.NUMBER() }), T.STRING())
assert.eq(sub1.tag, "number", "subtract from union")
local sub2 = T.subtract(T.STRING(), T.STRING())
assert.eq(sub2.tag, "never", "subtract same type")
local sub3 = T.subtract(T.STRING(), T.NUMBER())
assert.eq(sub3.tag, "string", "subtract different type")

-- narrow_to
local nar1 = T.narrow_to(T.union({ T.STRING(), T.NUMBER() }), T.STRING())
assert.eq(nar1.tag, "string", "narrow_to string")

-- type() narrowing in if
local ok_narrow1, errs_narrow1 = checker.check([[
--: string | number
local x = "hello"
if type(x) == "string" then
  local y = x .. " world"
end
]], "test.lua")
assert.ok(ok_narrow1, "type() narrowing: " .. (errs_narrow1 or ""))

-- nil check narrowing
local ok_narrow2, errs_narrow2 = checker.check([[
--: string?
local x = "hello"
if x ~= nil then
  local y = x .. " world"
end
]], "test.lua")
assert.ok(ok_narrow2, "nil check narrowing: " .. (errs_narrow2 or ""))

-- truthiness narrowing
local ok_narrow3, errs_narrow3 = checker.check([[
--: string?
local x = "hello"
if x then
  local y = x .. " world"
end
]], "test.lua")
assert.ok(ok_narrow3, "truthiness narrowing: " .. (errs_narrow3 or ""))

---------------------------------------------------------------------------
-- Phase 5: Module resolution + Prelude
---------------------------------------------------------------------------

-- Prelude aliases available
local ok_prelude1, errs_prelude1 = checker.check([[
--:: MyList = Array<number>
]], "test.lua")
assert.ok(ok_prelude1, "prelude Array alias: " .. (errs_prelude1 or ""))

-- Module resolver finds files
local resolver = require("lib.type.static.resolve")
local lua_path, decl_path = resolver.resolve("lib.path")
assert.ok(lua_path, "resolver finds lib.path")
assert.ok(lua_path:find("lib/path"), "resolver path correct")

-- Resolver returns nil for missing modules
local missing_path = resolver.resolve("lib.nonexistent.module")
assert.eq(missing_path, nil, "resolver nil for missing")

---------------------------------------------------------------------------
-- Phase 6: Nominal types
---------------------------------------------------------------------------

-- newtype creates distinct type
local ok_newtype1, errs_newtype1 = checker.check([[
--:: newtype UserId = number
local x = 42 --: UserId
]], "test.lua")
-- newtype UserId should NOT accept a plain number
assert.ok(not ok_newtype1, "newtype rejects underlying type")

-- newtype declaration parses
local src_nt = '--:: newtype UserId = number\n'
local map_nt = annotations.build_map(src_nt)
assert.ok(map_nt[1], "newtype decl exists")
assert.eq(map_nt[1].nominal, "newtype", "newtype nominal kind")
assert.eq(map_nt[1].name, "UserId", "newtype name")

-- opaque declaration parses
local src_op = '--:: opaque Connection = { handle: number }\n'
local map_op = annotations.build_map(src_op)
assert.ok(map_op[1], "opaque decl exists")
assert.eq(map_op[1].nominal, "opaque", "opaque nominal kind")
assert.eq(map_op[1].name, "Connection", "opaque name")

-- nominal unification: same identity passes
local nom1 = T.nominal("X", 999, T.NUMBER())
local nom2 = T.nominal("X", 999, T.NUMBER())
assert.ok(unify.unify(nom1, nom2), "nominal same identity")

-- nominal unification: different identity fails
local nom3 = T.nominal("X", 998, T.NUMBER())
local ok_nom, _ = unify.unify(nom1, nom3)
assert.ok(not ok_nom, "nominal different identity")

---------------------------------------------------------------------------
-- Phase 7: Match types + Intrinsics
---------------------------------------------------------------------------

-- parse intrinsic
local intr = annotations.parse_type("$Keys")
assert.eq(intr.tag, "intrinsic", "ann intrinsic tag")
assert.eq(intr.name, "Keys", "ann intrinsic name")

-- parse intrinsic with type args
local intr_call = annotations.parse_type("$Keys<{ x: number, y: string }>")
assert.eq(intr_call.tag, "type_call", "ann intrinsic call tag")
assert.eq(intr_call.callee.tag, "intrinsic", "ann intrinsic call callee")
assert.eq(intr_call.callee.name, "Keys", "ann intrinsic call name")
assert.eq(#intr_call.args, 1, "ann intrinsic call args")

-- parse match type
local mt = annotations.parse_type('match number { number => string, string => number }')
assert.eq(mt.tag, "match_type", "ann match type tag")
assert.eq(mt.param.tag, "number", "ann match param")
assert.eq(#mt.arms, 2, "ann match arms count")
assert.eq(mt.arms[1].result.tag, "string", "ann match arm1 result")

-- match evaluation
local matcher = require("lib.type.static.match")
local match_result = matcher.evaluate(T.match_type(T.NUMBER(), {
  { pattern = T.NUMBER(), result = T.STRING() },
  { pattern = T.STRING(), result = T.NUMBER() },
}))
assert.eq(match_result.tag, "string", "match eval number -> string")

local match_result2 = matcher.evaluate(T.match_type(T.BOOLEAN(), {
  { pattern = T.NUMBER(), result = T.STRING() },
  { pattern = T.STRING(), result = T.NUMBER() },
}))
assert.eq(match_result2.tag, "never", "match eval no match -> never")

-- $Keys intrinsic evaluation
local intrinsics = require("lib.type.static.intrinsics")
local keys_result = intrinsics.evaluate("Keys", {
  T.table({ x = { type = T.NUMBER(), optional = false }, y = { type = T.STRING(), optional = false } }, {})
})
assert.eq(keys_result.tag, "union", "Keys produces union")
assert.eq(#keys_result.types, 2, "Keys union members")

-- $Keys end-to-end in checker
local ok_keys, errs_keys = checker.check([[
--:: Point = { x: number, y: number }
--:: PointKey = $Keys<Point>
]], "test.lua")
assert.ok(ok_keys, "Keys end-to-end: " .. (errs_keys or ""))

-- = intrinsic declaration
local src_intr = '--:: EachField<T, F> = intrinsic\n'
local map_intr = annotations.build_map(src_intr)
assert.ok(map_intr[1], "intrinsic decl exists")
assert.ok(map_intr[1].is_intrinsic, "intrinsic decl flag")

-- match type in checker context
local ok_match, errs_match = checker.check([[
--:: ToString<T> = match T { number => string, string => string, boolean => string }
]], "test.lua")
assert.ok(ok_match, "match type decl: " .. (errs_match or ""))

---------------------------------------------------------------------------
-- Phase 8: Overloads + setmetatable
---------------------------------------------------------------------------

-- try_unify (read-only scoring)
local score1, ok_try1 = unify.try_unify(T.NUMBER(), T.NUMBER())
assert.ok(ok_try1, "try_unify same type")
assert.eq(score1, 0, "try_unify exact score")

local score2, ok_try2 = unify.try_unify(T.INTEGER(), T.NUMBER())
assert.ok(ok_try2, "try_unify subtype")
assert.eq(score2, 1, "try_unify subtype score")

local _, ok_try3 = unify.try_unify(T.STRING(), T.NUMBER())
assert.ok(not ok_try3, "try_unify mismatch")

-- setmetatable merges __index fields (field access)
local ok_mt, errs_mt = checker.check([[
local proto = { x = 42 }
local obj = setmetatable({}, { __index = proto })
local result = obj.x
]], "test.lua")
assert.ok(ok_mt, "setmetatable __index: " .. (errs_mt or ""))

-- class pattern: setmetatable + __index (just checking it doesn't crash)
local ok_class, errs_class = checker.check([[
local M = {}
M.__index = M
function M.new()
  return setmetatable({}, M)
end
]], "test.lua")
assert.ok(ok_class, "class pattern: " .. (errs_class or ""))

---------------------------------------------------------------------------
-- Discriminated union narrowing
---------------------------------------------------------------------------

-- Basic field narrowing: x.tag == "a" narrows union in then-branch
local ok_du1, errs_du1 = checker.check([[
local function process(node)
  if node.tag == "number" then
    local n = node.value + 1
  end
end
]], "test.lua")
assert.ok(ok_du1, "field narrowing no crash: " .. (errs_du1 or ""))

-- Field narrowing eliminates a union member in then-branch
local ok_du2, errs_du2 = checker.check([[
--:: NumNode = { tag: "number", value: number }
--:: StrNode = { tag: "string", value: string }
--:: Node = NumNode | StrNode
local function process(node) --: (Node) -> number
  if node.tag == "number" then
    return node.value + 1
  end
  return 0
end
]], "test.lua")
assert.ok(ok_du2, "discriminated union narrows in branch: " .. (errs_du2 or ""))

-- Field narrowing in else-branch removes matched member
local ok_du3, errs_du3 = checker.check([[
--:: ANode = { tag: "a", x: number }
--:: BNode = { tag: "b", y: string }
--:: ABNode = ANode | BNode
local function process(node) --: (ABNode) -> string
  if node.tag == "a" then
    return tostring(node.x)
  else
    return node.y
  end
end
]], "test.lua")
assert.ok(ok_du3, "discriminated union else-branch: " .. (errs_du3 or ""))

-- narrow_by_field unit test on union type
local T = types
local nu = T.table({ tag = { type = T.literal("string", "number"), optional = false }, value = { type = T.NUMBER(), optional = false } }, {})
local su = T.table({ tag = { type = T.literal("string", "string"), optional = false }, value = { type = T.STRING(), optional = false } }, {})
local union_ty = T.union({ nu, su })

local narrowed_pos = T.narrow_by_field(union_ty, "tag", "number", true)
assert.eq(narrowed_pos.tag, "table", "narrow_by_field positive keeps matching member")

local narrowed_neg = T.narrow_by_field(union_ty, "tag", "number", false)
assert.eq(narrowed_neg.tag, "table", "narrow_by_field negative keeps non-matching member")

---------------------------------------------------------------------------
-- Phase 9: Generic function inference
---------------------------------------------------------------------------

-- any dominates union: any | X = any
assert.eq(T.union({ T.ANY(), T.NIL() }).tag, "any", "union any | nil = any")
assert.eq(T.union({ T.NIL(), T.ANY() }).tag, "any", "union nil | any = any")
assert.eq(T.union({ T.STRING(), T.ANY(), T.NUMBER() }).tag, "any", "union with any short-circuits")
-- non-any unions still work
assert.eq(T.union({ T.NIL(), T.STRING() }).tag, "union", "nil | string stays union")

-- apply: higher-order function return type flows from callback
local ok_apply, errs_apply = checker.check([[
local function apply(fn, x)
  return fn(x)
end
local y = apply(function(n) return n + 1 end, 10)
local z = apply(function(s) return s .. "!" end, "hello")
]], "test.lua")
assert.ok(ok_apply, "higher-order apply: " .. (errs_apply or ""))

-- identity: return type matches param type at call sites
local ok_id, errs_id = checker.check([[
local function identity(x)
  return x
end
local a = identity(42)
local b = identity("hi")
]], "test.lua")
assert.ok(ok_id, "identity inference: " .. (errs_id or ""))

-- transform (map-like): element and result types flow through callback
local ok_map, errs_map = checker.check([[
local function transform(list, fn)
  local result = {}
  for i = 1, #list do
    result[i] = fn(list[i])
  end
  return result
end
local nums = transform({1, 2, 3}, function(x) return x * 2 end)
local strs = transform({"a", "b"}, function(s) return s .. s end)
]], "test.lua")
assert.ok(ok_map, "map-like transform: " .. (errs_map or ""))

-- recursive functions are not broken by the fix
local ok_rec, errs_rec = checker.check([[
local function fact(n)
  if n <= 1 then return 1 end
  return n * fact(n - 1)
end
local r = fact(5)
]], "test.lua")
assert.ok(ok_rec, "recursive function not broken: " .. (errs_rec or ""))

---------------------------------------------------------------------------
-- Phase 10: Meta fields (#field syntax)
---------------------------------------------------------------------------

-- M.table() with meta param
local mt1 = T.table({}, {}, nil, { ["__add"] = { type = T.func({T.NUMBER(), T.NUMBER()}, {T.NUMBER()}), optional = false } })
assert.ok(mt1.meta, "table with meta exists")
assert.ok(mt1.meta["__add"], "table meta __add exists")
assert.eq(mt1.meta["__add"].type.tag, "function", "table meta __add is function")

-- parse meta field in table type annotation
local mft = annotations.parse_type("{ x: number, #__add: (any, any) -> any }")
assert.eq(mft.tag, "table", "meta field parse: table tag")
assert.ok(mft.fields.x, "meta field parse: regular field x present")
assert.ok(mft.meta, "meta field parse: meta dict present")
assert.ok(mft.meta["__add"], "meta field parse: __add in meta")
assert.eq(mft.meta["__add"].type.tag, "function", "meta field parse: __add type is function")
assert.eq(mft.meta["__add"].optional, false, "meta field parse: __add not optional")

-- display renders meta fields with # prefix
local mft_disp = T.display(mft)
assert.ok(mft_disp:find("#__add"), "display: meta field has # prefix")
assert.ok(mft_disp:find("x:"), "display: regular field still present")

-- table with no meta fields still displays without # entries
local plain_disp = T.display(T.table({ x = { type = T.NUMBER(), optional = false } }, {}))
assert.ok(not plain_disp:find("#"), "display: plain table has no # prefix")

-- unification: required meta field missing → error
local ua = T.table({}, {}, nil, {})
local ub = T.table({}, {}, nil, { ["__call"] = { type = T.func({}, {}), optional = false } })
local ok_umeta, err_umeta = unify.unify(ua, ub)
assert.ok(not ok_umeta, "unify: missing required meta field fails")
assert.ok(err_umeta and err_umeta:find("__call"), "unify: error names the missing slot")

-- unification: optional meta field missing → ok
local uc = T.table({}, {}, nil, { ["__add"] = { type = T.func({T.NUMBER()}, {T.NUMBER()}), optional = true } })
assert.ok(unify.unify(ua, uc), "unify: missing optional meta field passes")

-- unification: meta field present and matching → ok
local ud = T.table({}, {}, nil, { ["__call"] = { type = T.func({}, {}), optional = false } })
assert.ok(unify.unify(ud, ub), "unify: matching meta field passes")

-- setmetatable handler populates meta for __add, __call etc.
local ok_smt2, errs_smt2 = checker.check([[
local mt = { __add = function(a, b) return a end, __mul = function(a, b) return a end }
local obj = setmetatable({}, mt)
]], "test.lua")
assert.ok(ok_smt2, "setmetatable meta ops: " .. (errs_smt2 or ""))

-- class pattern still works (regression: __call via meta["__call"])
local ok_class2, errs_class2 = checker.check([[
local M = {}
M.__index = M
function M.new()
  return setmetatable({}, M)
end
]], "test.lua")
assert.ok(ok_class2, "class pattern regression: " .. (errs_class2 or ""))

-- Phase 9: Structural operator dispatch via meta slots

-- __add metamethod dispatch: custom type + custom type → metamethod return type
local ok_add, errs_add = checker.check([[
local mt = { __add = function(a, b) return 1 end }
local v = setmetatable({}, mt)
local result = v + v
]], "test.lua")
assert.ok(ok_add, "meta __add dispatch: " .. (errs_add or ""))

-- __add on unknown operand types (no meta) still errors for non-numeric
local ok_bad, errs_bad = checker.check([[
local s = "hello"
local n = s + 1
]], "test.lua")
assert.ok(not ok_bad, "arithmetic on string still errors without meta")
assert.ok(errs_bad and errs_bad:find("arithmetic"), "arithmetic error still reported")

-- __mul metamethod dispatch
local ok_mul, errs_mul = checker.check([[
local mt = { __mul = function(a, b) return {} end }
local v = setmetatable({}, mt)
local r = v * 2
]], "test.lua")
assert.ok(ok_mul, "meta __mul dispatch: " .. (errs_mul or ""))

-- __unm (unary minus) metamethod dispatch
local ok_unm, errs_unm = checker.check([[
local mt = { __unm = function(a) return a end }
local v = setmetatable({}, mt)
local neg = -v
]], "test.lua")
assert.ok(ok_unm, "meta __unm dispatch: " .. (errs_unm or ""))

-- __len (# operator) metamethod dispatch
local ok_len, errs_len = checker.check([[
local mt = { __len = function(a) return 42 end }
local v = setmetatable({}, mt)
local n = #v
]], "test.lua")
assert.ok(ok_len, "meta __len dispatch: " .. (errs_len or ""))

-- __lt (< operator) metamethod dispatch
local ok_lt, errs_lt = checker.check([[
local mt = { __lt = function(a, b) return true end }
local v = setmetatable({}, mt)
local cmp = v < v
]], "test.lua")
assert.ok(ok_lt, "meta __lt dispatch: " .. (errs_lt or ""))

-- __concat metamethod dispatch
local ok_cc, errs_cc = checker.check([[
local mt = { __concat = function(a, b) return a end }
local v = setmetatable({}, mt)
local joined = v .. v
]], "test.lua")
assert.ok(ok_cc, "meta __concat dispatch: " .. (errs_cc or ""))
