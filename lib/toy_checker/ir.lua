if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

-- toy_checker.ir — types, toy-language AST shapes, and the claim-IR obligation
-- vocabulary (judgment names + fixed mode signatures). See init.lua for the
-- full design rationale; this file is just constructors and structural
-- helpers over types (deref, occurs check, free type variables, structural
-- substitution).

local M = {}

-- ========================
-- TYPES
-- ========================
-- A Type is a tagged union on `kind`.
-- Mode kinds: "in", "out", "accumulate".
-- "in": value must be ground before the obligation can run; defer otherwise.
-- "out": the obligation produces this value.
-- "accumulate": records a constraint (upper/lower bound) on the variable;
--   the obligation can run immediately without the variable being ground.
--   Sub uses accumulate dynamically when one operand is a uvar — see
--   producers.lua sub_producer.
--:: Type = { kind: "int" } | { kind: "string" } | { kind: "bool" } | { kind: "number" } | { kind: "void" } | { kind: "fn", params: Type[], ret: Type } | { kind: "generic", name: string, args: Type[] } | { kind: "array", elem: Type } | { kind: "map", key: Type, value: Type } | { kind: "tyvar", name: string } | { kind: "uvar", id: integer, bound: Type | nil, lower_bounds: Type[], upper_bounds: Type[] }
--:: Scheme = { kind: "scheme", vars: string[], type: Type }
--:: SchemeCell = { kind: "scheme_cell", id: integer, bound: Scheme | nil }

-- ========================
-- TOY-LANGUAGE AST
-- ========================
-- Hand-built Lua-table ASTs (no parser). A raw type *annotation* is its own
-- tagged union, TypeAnn — distinct from Type because it may additionally
-- reference a not-yet-resolved generic parameter via `tvar_ref`, which
-- resolve_type_vars() eliminates before an annotation becomes a real Type.
-- NOTE: the function-*literal* AST node is tagged "fn_lit", not "fn" — "fn"
-- is already Type's function-type tag, and giving both the same tag would
-- make ObligationArg (below) an undischargeable union (two variants, same
-- discriminant, different field shapes).
--:: TypeAnn = { kind: "int" } | { kind: "string" } | { kind: "bool" } | { kind: "number" } | { kind: "void" } | { kind: "tvar_ref", name: string } | { kind: "fn", params: TypeAnn[], ret: TypeAnn } | { kind: "generic", name: string, args: TypeAnn[] } | { kind: "array", elem: TypeAnn } | { kind: "map", key: TypeAnn, value: TypeAnn }
--:: Param = { name: string, type: TypeAnn }
--:: MapEntry = { key: Expr, value: Expr }
--:: Expr = { kind: "lit_int", value: integer } | { kind: "lit_str", value: string } | { kind: "lit_bool", value: boolean } | { kind: "lit_unit" } | { kind: "var", name: string } | { kind: "if", cond: Expr, then_: Expr, else_: Expr } | { kind: "binop", op: string, left: Expr, right: Expr } | { kind: "fn_lit", params: Param[], ret: TypeAnn | nil, body: Expr, type_params: string[] | nil } | { kind: "let", name: string, ann: TypeAnn | nil, value: Expr, body: Expr } | { kind: "call", fn: Expr, args: Expr[] } | { kind: "map_lit", entries: MapEntry[] }

-- ========================
-- TYPING CONTEXT (env) — see init.lua OWNER-CALL A: threaded as auxiliary
-- state on obligations, not itself a claim.
-- ========================
--:: EnvValue = Type | SchemeCell
--:: Env = { vars: { [string]: EnvValue }, parent: Env | nil }

local _next_id = 0
--: () -> integer
local function next_id()
	_next_id = _next_id + 1
	return _next_id
end

-- Base types are shared immutable leaves — safe to alias, they carry no identity.
M.INT = { kind = "int" }
M.STRING = { kind = "string" }
M.BOOL = { kind = "bool" }
M.NUMBER = { kind = "number" }
M.VOID = { kind = "void" }

--: () -> Type
function M.mk_int() return M.INT end
--: () -> Type
function M.mk_string() return M.STRING end
--: () -> Type
function M.mk_bool() return M.BOOL end
--: () -> Type
function M.mk_number() return M.NUMBER end
--: () -> Type
function M.mk_void() return M.VOID end

--: (Type[], Type) -> Type
function M.mk_fn(params, ret)
	return { kind = "fn", params = params, ret = ret }
end

--: (string, Type[]) -> Type
function M.mk_generic(name, args)
	return { kind = "generic", name = name, args = args }
end

--: (Type) -> Type
function M.mk_array(elem)
	return { kind = "array", elem = elem }
end

--: (Type, Type) -> Type
function M.mk_map(key, value)
	return { kind = "map", key = key, value = value }
end

--: (string) -> Type
function M.mk_tyvar(name)
	return { kind = "tyvar", name = name }
end

--: () -> Type
function M.mk_uvar()
	return { kind = "uvar", id = next_id(), bound = nil, lower_bounds = {}, upper_bounds = {} }
end

--: (string[], Type) -> Scheme
function M.mk_scheme(vars, type_)
	return { kind = "scheme", vars = vars, type = type_ }
end

-- bound: an already-resolved Scheme, or nil for a pending cell (Generalize will fill it).
--: (Scheme | nil) -> SchemeCell
function M.mk_scheme_cell(bound)
	return { kind = "scheme_cell", id = next_id(), bound = bound }
end

-- Follow uvar bindings to the representative type. Non-uvars deref to themselves.
--: (Type) -> Type
function M.deref(t)
	while t.kind == "uvar" do
		local b = t.bound
		if not b then break end
		t = b
	end
	return t
end

-- Structural children of a compound type, for occurs-check / free-var walks.
-- Base types, tyvar, uvar, scheme_cell have no children.
--: (Type) -> Type[]
function M.type_children(t)
	if t.kind == "fn" then
		local c = {}
		for i, p in ipairs(t.params) do c[i] = p end
		c[#c + 1] = t.ret
		return c
	elseif t.kind == "generic" then
		return t.args
	elseif t.kind == "array" then
		return { t.elem }
	elseif t.kind == "map" then
		return { t.key, t.value }
	end
	return {}
end

-- Is `t` fully ground (no unresolved uvars anywhere inside)?
-- Rigid tyvars count as ground — they are fixed names, not holes.
--: (Type) -> boolean
function M.is_ground(t)
	t = M.deref(t)
	if t.kind == "uvar" then return false end
	for _, c in ipairs(M.type_children(t)) do
		if not M.is_ground(c) then return false end
	end
	return true
end

-- Does uvar `u` occur anywhere inside `t` (after dereferencing)?
--: (Type, Type) -> boolean
function M.occurs(u, t)
	t = M.deref(t)
	if t.kind == "uvar" then
		return t.id == u.id
	end
	for _, c in ipairs(M.type_children(t)) do
		if M.occurs(u, c) then return true end
	end
	return false
end

--:: TyvarSet = { [string]: boolean }

-- Free rigid type variables (tyvar names) appearing in `t`, after dereferencing uvars.
--: (Type, TyvarSet) -> TyvarSet
function M.free_tyvars(t, acc)
	t = M.deref(t)
	if t.kind == "tyvar" then
		acc[t.name] = true
	end
	for _, c in ipairs(M.type_children(t)) do
		M.free_tyvars(c, acc)
	end
	return acc
end

--:: TyvarMapping = { [string]: Type }

-- Structural substitution of rigid tyvars by `mapping[name] -> Type`, used by
-- Instantiate to turn a scheme's bound tyvars into fresh uvars per call site.
-- Pre-declared local (not M.substitute_tyvars) for the recursive calls: see
-- docs/lua-gotchas.md self-reference note — going through the module table
-- for a self-recursive call left the checker unable to settle the return
-- type at one call site when both arguments of the same call were
-- themselves recursive calls (the `map` branch below).
local substitute_tyvars
--: (Type, TyvarMapping) -> Type
substitute_tyvars = function(t, mapping)
	if t.kind == "tyvar" then
		return mapping[t.name] or t
	elseif t.kind == "fn" then
		local ps = {}
		for i, p in ipairs(t.params) do ps[i] = substitute_tyvars(p, mapping) end
		return M.mk_fn(ps, substitute_tyvars(t.ret, mapping))
	elseif t.kind == "generic" then
		local as = {}
		for i, a in ipairs(t.args) do as[i] = substitute_tyvars(a, mapping) end
		return M.mk_generic(t.name, as)
	elseif t.kind == "array" then
		return M.mk_array(substitute_tyvars(t.elem, mapping))
	elseif t.kind == "map" then
		return M.mk_map(substitute_tyvars(t.key, mapping), substitute_tyvars(t.value, mapping))
	end
	return t
end
M.substitute_tyvars = substitute_tyvars

-- Resolve raw AST type-annotation nodes (which reference generic params via
-- {kind="tvar_ref", name=...}) into concrete types, given a name->tyvar mapping.
-- Used once, at the point a generic function's own annotations are elaborated.
local resolve_type_vars
--: (TypeAnn, TyvarMapping) -> Type
resolve_type_vars = function(ann, mapping)
	if ann.kind == "tvar_ref" then
		local v = mapping[ann.name]
		if not v then error("toy_checker: unbound type parameter '" .. ann.name .. "' in annotation", 2) end
		return v
	elseif ann.kind == "fn" then
		local ps = {}
		for i, p in ipairs(ann.params) do ps[i] = resolve_type_vars(p, mapping) end
		return M.mk_fn(ps, resolve_type_vars(ann.ret, mapping))
	elseif ann.kind == "generic" then
		local as = {}
		for i, a in ipairs(ann.args) do as[i] = resolve_type_vars(a, mapping) end
		return M.mk_generic(ann.name, as)
	elseif ann.kind == "array" then
		return M.mk_array(resolve_type_vars(ann.elem, mapping))
	elseif ann.kind == "map" then
		return M.mk_map(resolve_type_vars(ann.key, mapping), resolve_type_vars(ann.value, mapping))
	end
	-- remaining cases (int/string/bool/number/void) are structurally identical in Type and TypeAnn
	return ann --[[: Type]]
end
M.resolve_type_vars = resolve_type_vars

--: (Type) -> string
function M.type_to_string(t)
	t = M.deref(t)
	if t.kind == "int" or t.kind == "string" or t.kind == "bool" or t.kind == "number" or t.kind == "void" then
		return t.kind
	elseif t.kind == "uvar" then
		return "?" .. t.id
	elseif t.kind == "tyvar" then
		return t.name
	elseif t.kind == "fn" then
		local ps = {}
		for i, p in ipairs(t.params) do ps[i] = M.type_to_string(p) end
		return "(" .. table.concat(ps, ", ") .. ") -> " .. M.type_to_string(t.ret)
	elseif t.kind == "generic" then
		local as = {}
		for i, a in ipairs(t.args) do as[i] = M.type_to_string(a) end
		return t.name .. "<" .. table.concat(as, ", ") .. ">"
	elseif t.kind == "array" then
		return M.type_to_string(t.elem) .. "[]"
	else
		return "{[" .. M.type_to_string(t.key) .. "]: " .. M.type_to_string(t.value) .. "}"
	end
end

-- ========================
-- CLAIM IR: judgment names + fixed mode signatures
-- ========================
-- Every obligation is (judgment name, positional args, positional modes).
-- Modes are fixed per judgment (this toy never varies a judgment's own
-- signature at the call site — see init.lua doc comment on why that's not
-- the same thing as the pool doing name-keyed dispatch).
--:: Modes = { [integer]: string }
M.JUDGMENT_MODES = {
	Infer       = { "in", "out" },
	Check       = { "in", "in" },
	Sub         = { "in", "in" },
	Unify       = { "in", "in" },
	Instantiate = { "in", "out" },
	Generalize  = { "in", "in", "out" },
} --[[: { [string]: Modes } ]]

-- An obligation's positional args are heterogeneous *across* judgments but
-- always one of these three kinds of value; the pool itself stays
-- judgment-agnostic (see pool.lua), so this is deliberately a flat union
-- rather than a per-judgment tuple type.
--:: ObligationArg = Type | SchemeCell | Expr
--:: Obligation = { id: integer, judgment: string, modes: Modes, args: ObligationArg[], parent: integer | nil, desc: string, env: Env | nil }

return M
