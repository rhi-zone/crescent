-- lib/sem/value.lua
-- The PARAMETRIC value algebra for the formal Lua semantics (S1 + S2).
--
-- WHY PARAMETRIC (forced, not speculative): the Lua 5.3 integer/float split
-- means a fixed value representation is dead on arrival. S2 introduces an
-- int/float-split NUMBER MODEL as a NEW instance of a `NumberModel` interface,
-- not a rewrite of step/prim. step.lua / prim.lua reach numbers ONLY through the
-- value algebra; the number representation (single-double vs int/float pair) is
-- PRIVATE to the number model.
--
-- THE S2 PROVING SPLIT — arithmetic lives in the NUMBER MODEL, not in prim.lua.
-- prim.lua's `prim_arith` does NOT compute `x + y` on raw Lua numbers; it asks
-- the value algebra `va.arith(op, a, b)` to combine two number Values into a
-- result Value. This is the factoring that lets 5.3/5.4 keep a distinct integer
-- subtype with 64-bit wraparound, `/`-always-float, `//` floor-division, and
-- integer/float coercion — ALL inside the model, with ZERO version branches in
-- step.lua / prim.lua. (If arithmetic stayed on raw doubles in prim, the int
-- subtype would be unrepresentable and the split would leak as version branches.)
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

-- math.type result: integer/float for the dual model, nil for non-numbers and
-- for the single-double model (where `math.type` does not exist pre-5.3).
--:: NumSubtype = "integer" | "float"

-- The private runtime representation: a discriminated union on `tag`. Callers
-- (step/prim) NEVER read these fields directly — they go through the algebra,
-- which narrows on `tag` internally. The union shape makes the accessors total
-- without force casts: each accessor narrows by kind first.
--
-- VNumber carries `sub`: the number SUBTYPE ("integer" | "float"). For the
-- single-double model every number is tagged "float" internally (it is never
-- observed — `math_type` returns nil there); for the dual model `sub`
-- distinguishes 3 (integer) from 3.0 (float). The raw Lua double is `n`; for an
-- integer the model guarantees `n` holds an exact 64-bit-wrapped integer value.
--:: VNil     = { tag: "nil" }
--:: VBool    = { tag: "boolean", b: boolean }
--:: VNumber  = { tag: "number", n: number, sub: NumSubtype }
--:: VString  = { tag: "string", s: string }
--:: VTable   = { tag: "table", addr: integer }
--:: VClosure = { tag: "closure", addr: integer }
--:: Value = VNil | VBool | VNumber | VString | VTable | VClosure

-- The value-algebra record. A Profile selects ONE of these. The number-model
-- operations (`arith`, `int`, `float`, `math_type`, `number_tostring`) are the
-- version-parametric surface; everything else (kinds, references, equality,
-- truthiness) is shared across all models.
--:: ValueAlgebra = {
--::   model: string,
--::   nil_v: Value,
--::   bool: (boolean) -> Value,
--::   number: (number) -> Value,
--::   int: (number) -> Value,
--::   float: (number) -> Value,
--::   string: (string) -> Value,
--::   table_ref: (integer) -> Value,
--::   closure: (integer) -> Value,
--::   kind_of: (Value) -> ValKind,
--::   math_type: (Value) -> (NumSubtype | nil),
--::   bool_value: (Value) -> boolean,
--::   number_value: (Value) -> number,
--::   string_value: (Value) -> string,
--::   addr_value: (Value) -> integer,
--::   truthy: (Value) -> boolean,
--::   equal: (Value, Value) -> boolean,
--::   arith: (string, Value, Value) -> (Value | nil),
--::   number_lt: (Value, Value) -> boolean,
--::   number_le: (Value, Value) -> boolean,
--::   number_tostring: (Value) -> string,
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

-- ── shared (model-independent) value machinery ───────────────────────────────

local NIL = { tag = "nil" } --[[: Value]]
local TRUE = { tag = "boolean", b = true } --[[: Value]]
local FALSE = { tag = "boolean", b = false } --[[: Value]]

--: (boolean) -> Value
local function mk_bool(x) return x and TRUE or FALSE end

--: (string) -> Value
local function mk_string(x) return { tag = "string", s = x } --[[: Value]] end

--: (integer) -> Value
local function mk_table_ref(addr) return { tag = "table", addr = addr } --[[: Value]] end

--: (integer) -> Value
local function mk_closure(addr) return { tag = "closure", addr = addr } --[[: Value]] end

-- kind_of returns the runtime tag string, typed as the closed `ValKind` union so
-- callers get exhaustiveness checking on kinds.
--: (Value) -> ValKind
local function kind_of(v) return v.tag end

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
-- table/closure compare by store address (reference identity). NOTE on numbers:
-- Lua `==` compares numbers by MATHEMATICAL value across subtypes (1 == 1.0 is
-- true in 5.3/5.4), so number equality is by raw `n`, NOT by subtype. This is
-- correct for BOTH models and needs no version branch.
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

-- numeric comparison takes Values (so a model could compare across subtypes if
-- it ever needed to); for both current models the raw double order is correct.
--: (Value) -> number
local function num(v)
	if v.tag == "number" then return v.n end
	error("number expected", 2)
end

--: (Value, Value) -> boolean
local function number_lt(a, b) return num(a) < num(b) end
--: (Value, Value) -> boolean
local function number_le(a, b) return num(a) <= num(b) end

-- ── number-model parameterisation ────────────────────────────────────────────
-- Each model supplies: int/float constructors, a `number` default constructor,
-- `math_type`, an arithmetic combinator over number Values, and number→string.
-- Building a full ValueAlgebra from a model wires the shared machinery around it.

--:: NumberModel = {
--::   name: string,
--::   int: (number) -> Value,
--::   float: (number) -> Value,
--::   number: (number) -> Value,
--::   math_type: (Value) -> (NumSubtype | nil),
--::   arith: (string, Value, Value) -> (Value | nil),
--::   tostring: (Value) -> string,
--:: }

--: (NumberModel) -> ValueAlgebra
local function algebra_of(model)
	return {
		model = model.name,
		nil_v = NIL,
		bool = mk_bool,
		number = model.number,
		int = model.int,
		float = model.float,
		string = mk_string,
		table_ref = mk_table_ref,
		closure = mk_closure,
		kind_of = kind_of,
		math_type = model.math_type,
		bool_value = bool_value,
		number_value = number_value,
		string_value = string_value,
		addr_value = addr_value,
		truthy = truthy,
		equal = equal,
		arith = model.arith,
		number_lt = number_lt,
		number_le = number_le,
		number_tostring = model.tostring,
	}
end

-- ── single-double number model (LuaJIT 5.1, PUC 5.1, 5.2) ────────────────────
-- ONE number kind (IEEE double). `//` is NOT a valid operator in 5.1/5.2 (a
-- syntax error); the Profile's rule-set gates it, so this model never sees an
-- "idiv" op for the genuine 5.1/5.2 profiles. `math.type` does not exist pre-5.3
-- → `math_type` returns nil. `/`, `+`, `-`, `*`, `%` are all double arithmetic.

--: (number) -> Value
local function dbl_make(x) return { tag = "number", n = x, sub = "float" } --[[: Value]] end

--: (Value) -> (NumSubtype | nil)
local function dbl_math_type(_v) return nil end

-- single-double arithmetic: every op is plain double arithmetic; the result is
-- always one number kind. `mod` is Lua's `a - floor(a/b)*b`. `idiv` (only
-- reachable for LuaJIT, which DOES accept `//` as floor(a/b)) yields a double.
--: (string, Value, Value) -> (Value | nil)
local function dbl_arith(op, a, b)
	if a.tag ~= "number" or b.tag ~= "number" then return nil end
	local x, y = a.n, b.n
	if op == "add" then return dbl_make(x + y) end
	if op == "sub" then return dbl_make(x - y) end
	if op == "mul" then return dbl_make(x * y) end
	if op == "div" then return dbl_make(x / y) end
	if op == "mod" then return dbl_make(x - math.floor(x / y) * y) end
	if op == "idiv" then return dbl_make(math.floor(x / y)) end
	if op == "pow" then return dbl_make(x ^ y) end
	return nil
end

-- Number → string for the single-double model. Matches the real interpreters'
-- (5.1/5.2/LuaJIT) tostring on doubles: an integral value renders "%d" (so -0.0
-- and 0.0 both render "0", as the real %d does — Lua's `tostring(-0.0)` would
-- give "-0", which the real side's integral `%d` path does NOT, so we follow the
-- real %d path for cross-side agreement), else "%.14g".
--: (Value) -> string
local function dbl_tostring(v)
	if v.tag ~= "number" then error("dbl_tostring: not a number", 2) end
	local n = v.n
	if n ~= n then return "nan" end
	if n == math.huge then return "inf" end
	if n == -math.huge then return "-inf" end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	return string.format("%.14g", n)
end

local DBL_MODEL = {
	name = "double",
	int = dbl_make, float = dbl_make, number = dbl_make,
	math_type = dbl_math_type, arith = dbl_arith, tostring = dbl_tostring,
} --[[: NumberModel]]

-- ── dual integer/float number model (PUC 5.3, 5.4) ───────────────────────────
-- TWO number subtypes. Internally an integer Value carries an exact integer in
-- `n` (a Lua double can represent integers exactly to 2^53; the 64-bit
-- wraparound is implemented over that representable range below — see
-- `wrap_note`). `math.type` distinguishes them. Rules:
--   * `+ - * ` of (int, int)            → int (with 64-bit wraparound)
--   * `+ - * ` with any float operand   → float
--   * `/`  ALWAYS                        → float (even int/int)
--   * `//` (idiv) (int,int)             → int (floor); with a float → float floor
--   * `%`  follows the same int/float promotion as `+`
--   * `^`  ALWAYS                        → float (like 5.3/5.4)
--
-- wrap_note: genuine Lua 5.3/5.4 integers are 64-bit two's-complement and wrap
-- at 2^63. A Lua-5.1-double host cannot represent the full 64-bit range
-- exactly, so this pure-Lua model wraps within the 53-bit EXACTLY-REPRESENTABLE
-- range it CAN model faithfully (see `wrap53`). The differential harness
-- (Loop-α) therefore confines its integer-arithmetic generators to operands
-- whose results stay inside the exactly-representable window, where this model
-- is byte-for-byte faithful to real 5.3/5.4. Full 64-bit wraparound is a
-- substrate need (an exact int64 — FFI `int64_t` or a pure-Lua bignum), recorded
-- in TODO.md; it is NOT faked here.

local WRAP = 9007199254740992  -- 2^53: the exactly-representable integer modulus

-- wrap an integer-valued double into the signed window (-2^52 .. 2^52-1).
--: (number) -> number
local function wrap53(x)
	-- reduce modulo 2^53 into [-2^52, 2^52)
	local half = WRAP / 2
	local r = x % WRAP
	if r >= half then r = r - WRAP end
	return r
end

--: (number) -> Value
local function int_make(x) return { tag = "number", n = wrap53(x), sub = "integer" } --[[: Value]] end
--: (number) -> Value
local function float_make(x) return { tag = "number", n = x, sub = "float" } --[[: Value]] end

-- the default `number` constructor for the dual model: an integral value becomes
-- an integer, a non-integral value a float. (Used by the lowering for literals;
-- the source distinguishes `3` from `3.0` via explicit int/float constructors,
-- but a computed default still needs a rule.)
--: (number) -> Value
local function dual_number(x)
	if x == math.floor(x) and x == x and x ~= math.huge and x ~= -math.huge then
		return int_make(x)
	end
	return float_make(x)
end

--: (Value) -> (NumSubtype | nil)
local function dual_math_type(v)
	if v.tag ~= "number" then return nil end
	return v.sub
end

-- true iff a number Value is an integer subtype.
--: (Value) -> boolean
local function is_int(v)
	if v.tag ~= "number" then return false end
	return v.sub == "integer"
end

-- dual-model arithmetic. The promotion rule: an op stays integer iff BOTH
-- operands are integer AND the op preserves integerness (`/` and `^` never do).
--: (string, Value, Value) -> (Value | nil)
local function dual_arith(op, a, b)
	if a.tag ~= "number" or b.tag ~= "number" then return nil end
	local x, y = a.n, b.n
	local both_int = is_int(a) and is_int(b)
	if op == "div" then return float_make(x / y) end       -- ALWAYS float
	if op == "pow" then return float_make(x ^ y) end       -- ALWAYS float
	if op == "add" then
		if both_int then return int_make(x + y) end
		return float_make(x + y)
	end
	if op == "sub" then
		if both_int then return int_make(x - y) end
		return float_make(x - y)
	end
	if op == "mul" then
		if both_int then return int_make(x * y) end
		return float_make(x * y)
	end
	if op == "mod" then
		local r = x - math.floor(x / y) * y
		if both_int then return int_make(r) end
		return float_make(r)
	end
	if op == "idiv" then
		local r = math.floor(x / y)
		if both_int then return int_make(r) end
		return float_make(r)
	end
	return nil
end

-- Number → string matching 5.3/5.4 tostring: an integer renders with no decimal
-- ("3"), a float renders %.14g and ALWAYS shows a marker for integral values
-- ("3.0", not "3"). This is a REAL cross-version delta (5.1 prints "3" for the
-- double 3.0; 5.3/5.4 print "3.0" for the float 3.0) and it flows entirely from
-- the model, no version branch in prim/step.
--: (Value) -> string
local function dual_tostring(v)
	if v.sub == "integer" then return string.format("%d", v.n) end
	-- float: reproduce 5.3/5.4's "%.14g" with a forced ".0" for integral floats.
	local n = v.n
	if n ~= n then return "nan" end
	if n == math.huge then return "inf" end
	if n == -math.huge then return "-inf" end
	local s = string.format("%.14g", n)
	if not s:find("[.eEni]") then s = s .. ".0" end
	return s
end

local DUAL_MODEL = {
	name = "intfloat",
	int = int_make, float = float_make, number = dual_number,
	math_type = dual_math_type, arith = dual_arith, tostring = dual_tostring,
} --[[: NumberModel]]

-- ── the exported value algebras ──────────────────────────────────────────────
-- Two value algebras, one per number model. Profiles select these. All share the
-- identical reference/equality/truthiness machinery — ONLY the number model
-- differs, which is precisely the parametric-value-algebra claim.
M.single_double = algebra_of(DBL_MODEL)
M.dual_intfloat = algebra_of(DUAL_MODEL)

-- back-compat name: the S1 luajit51 algebra IS the single-double model.
M.luajit51 = M.single_double

return M
