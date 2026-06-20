-- lib/sem/value.lua
-- The PARAMETRIC value algebra for the formal Lua semantics (S1).
--
-- WHY PARAMETRIC (forced, not speculative): the Lua 5.3 integer/float split
-- means a fixed value representation is dead on arrival. S2 will introduce an
-- int/float-split value algebra as a NEW instance of this interface, not a
-- rewrite of step/prim. Therefore: the number representation lives behind
-- `number_make` / `number_value` / `number_*` operations on a value-algebra
-- record, and step.lua / prim.lua reach values ONLY through a value algebra.
--
-- DISCIPLINE: step.lua and prim.lua must never inspect a raw Lua type tag of a
-- value (no `type(v)`, no `v.tag == ...`). All value observation goes through
-- `algebra.kind_of`, `algebra.equal`, and the typed accessors here. The raw Lua
-- representation of a value (a tagged table) is private to THIS module.
--
-- A value is one of the universe scalar/reference kinds (docs/agnostic-static-
-- analysis-crescent-slice.md §1.1):
--   nil | boolean | number | string | table-ref | closure
--
-- table-ref and closure carry an opaque store address (an integer the store
-- assigns); the value itself holds no mutable state — mutation goes through the
-- store in config.lua.

local M = {}

--:: ValKind = "nil" | "boolean" | "number" | "string" | "table" | "closure"

-- The private runtime representation: a discriminated union on `tag`. Callers
-- (step/prim) NEVER read these fields directly — they go through the algebra,
-- which narrows on `tag` internally. The union shape makes the accessors total
-- without force casts: each accessor narrows by kind first.
--:: VNil     = { tag: "nil" }
--:: VBool    = { tag: "boolean", b: boolean }
--:: VNumber  = { tag: "number", n: number }
--:: VString  = { tag: "string", s: string }
--:: VTable   = { tag: "table", addr: integer }
--:: VClosure = { tag: "closure", addr: integer }
--:: Value = VNil | VBool | VNumber | VString | VTable | VClosure

-- The value-algebra record. A Profile selects ONE of these. S1 ships exactly
-- `luajit51`; S2 adds an int/float-split instance with the SAME interface.
--:: ValueAlgebra = {
--::   nil_v: Value,
--::   bool: (boolean) -> Value,
--::   number: (number) -> Value,
--::   string: (string) -> Value,
--::   table_ref: (integer) -> Value,
--::   closure: (integer) -> Value,
--::   kind_of: (Value) -> string,
--::   bool_value: (Value) -> boolean,
--::   number_value: (Value) -> number,
--::   string_value: (Value) -> string,
--::   addr_value: (Value) -> integer,
--::   truthy: (Value) -> boolean,
--::   equal: (Value, Value) -> boolean,
--::   number_add: (number, number) -> number,
--::   number_sub: (number, number) -> number,
--::   number_mul: (number, number) -> number,
--::   number_div: (number, number) -> number,
--::   number_mod: (number, number) -> number,
--::   number_lt: (number, number) -> boolean,
--::   number_le: (number, number) -> boolean,
--::   number_tostring: (number) -> string,
--:: }

-- ── Fault sentinel ──────────────────────────────────────────────────────────
-- A fault is a STUCK primitive: a configuration the relation has no rule for.
-- It is a single shared sentinel table, distinguishable by identity. The
-- fault's classification string lives on the config (config.lua), not here.
local FAULT = { __sem_fault = true }

--: () -> { __sem_fault: boolean }
function M.fault() return FAULT end

--: (unknown) -> boolean
function M.is_fault(x)
	return x == FAULT
end

-- ── The luajit51 value algebra ──────────────────────────────────────────────
-- LuaJIT 5.1: a single `number` kind (IEEE double); no int/float split. S2's
-- algebra will split this.

local NIL = { tag = "nil" } --[[: Value]]
local TRUE = { tag = "boolean", b = true } --[[: Value]]
local FALSE = { tag = "boolean", b = false } --[[: Value]]

--: (boolean) -> Value
local function mk_bool(x) return x and TRUE or FALSE end

--: (number) -> Value
local function mk_number(x) return { tag = "number", n = x } --[[: Value]] end

--: (string) -> Value
local function mk_string(x) return { tag = "string", s = x } --[[: Value]] end

--: (integer) -> Value
local function mk_table_ref(addr) return { tag = "table", addr = addr } --[[: Value]] end

--: (integer) -> Value
local function mk_closure(addr) return { tag = "closure", addr = addr } --[[: Value]] end

-- kind_of returns the runtime tag string. NOTE (typechecker substrate gap,
-- recorded in TODO.md): a union of string literals is not assignable to itself
-- in *function-return* position (it widens to `string`); it works fine as a
-- record field value. So the declared return is `string`, not `ValKind`.
-- Callers compare against the literal kind strings ("number", "table", ...),
-- which is sound; only closed-set exhaustiveness checking is forfeited here.
--: (Value) -> string
local function kind_of(v) return v.tag end

-- Accessors are partial: callers must have established the kind via kind_of
-- first. Each narrows on `tag` and errors (programming error) on misuse.
--: (Value) -> boolean
local function bool_value(v)
	if v.tag == "boolean" then return v.b end
	error("bool_value: not a boolean", 2)
end

--: (Value) -> number
local function number_value(v)
	if v.tag == "number" then return v.n end
	error("number_value: not a number", 2)
end

--: (Value) -> string
local function string_value(v)
	if v.tag == "string" then return v.s end
	error("string_value: not a string", 2)
end

--: (Value) -> integer
local function addr_value(v)
	if v.tag == "table" then return v.addr end
	if v.tag == "closure" then return v.addr end
	error("addr_value: not a reference", 2)
end

-- Lua truthiness: everything except nil and false is truthy.
--: (Value) -> boolean
local function truthy(v)
	if v.tag == "nil" then return false end
	if v.tag == "boolean" then return v.b end
	return true
end

-- Value equality (Lua `==` for the S1 kinds): scalars compare by payload,
-- table/closure compare by store address (reference identity).
--: (Value, Value) -> boolean
local function equal(a, b)
	if a.tag == "nil" and b.tag == "nil" then return true end
	if a.tag == "boolean" and b.tag == "boolean" then return a.b == b.b end
	if a.tag == "number" and b.tag == "number" then return a.n == b.n end
	if a.tag == "string" and b.tag == "string" then return a.s == b.s end
	if a.tag == "table" and b.tag == "table" then return a.addr == b.addr end
	if a.tag == "closure" and b.tag == "closure" then return a.addr == b.addr end
	return false
end

--: (number, number) -> number
local function n_add(x, y) return x + y end
--: (number, number) -> number
local function n_sub(x, y) return x - y end
--: (number, number) -> number
local function n_mul(x, y) return x * y end
--: (number, number) -> number
local function n_div(x, y) return x / y end
-- Lua modulo: a - floor(a/b)*b (matches LuaJIT semantics for the % operator).
--: (number, number) -> number
local function n_mod(x, y) return x - math.floor(x / y) * y end
--: (number, number) -> boolean
local function n_lt(x, y) return x < y end
--: (number, number) -> boolean
local function n_le(x, y) return x <= y end

-- Number → string for concatenation. LuaJIT renders an integer-valued double
-- with %g-style: "1" not "1.0", "1.5" as-is. tostring matches this for doubles.
--: (number) -> string
local function n_tostring(x) return tostring(x) end

M.luajit51 = {
	nil_v = NIL,
	bool = mk_bool,
	number = mk_number,
	string = mk_string,
	table_ref = mk_table_ref,
	closure = mk_closure,
	kind_of = kind_of,
	bool_value = bool_value,
	number_value = number_value,
	string_value = string_value,
	addr_value = addr_value,
	truthy = truthy,
	equal = equal,
	number_add = n_add,
	number_sub = n_sub,
	number_mul = n_mul,
	number_div = n_div,
	number_mod = n_mod,
	number_lt = n_lt,
	number_le = n_le,
	number_tostring = n_tostring,
}

return M
