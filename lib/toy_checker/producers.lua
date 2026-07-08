if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

-- toy_checker.producers — the four registered producers: Unify, Sub,
-- Instantiate+Generalize, and Infer+Check (the last is where the toy
-- language's actual typing rules live). See init.lua for the top-level
-- design doc and OWNER-CALL list.

local ir = require("lib.toy_checker.ir")
--:: require "lib.toy_checker.ir"
local Pool = require("lib.toy_checker.pool")

local M = {}

-- ========================
-- ObligationArg discrimination — real type predicates (`x is T`), narrowed
-- via the standard early-return idiom, rather than a checked cast: a
-- checked cast requires the target to be a supertype of the source, and
-- ObligationArg (a Type|SchemeCell|Expr union) is not a subtype of any one
-- of its members, so `arg --[[: Type]]` is rejected outright. See
-- docs/typechecker-reference.md's "Type predicates and assertion
-- functions" section.
--
-- Separately: every `ir.*` call below carries an explicit `--[[: T]]`
-- checked cast at its call site. This is NOT papering over toy_checker's
-- own logic — it's working around a real cross-module return-type
-- inference gap in the crescent checker itself: a required module's
-- function return type resolves to `any`/`nil` at the call site rather
-- than the declared return type (confirmed with a 5-line repro: even
-- `local x = ir.mk_int(); print(x.kind)` warns "inference fell back to
-- any"). `--[[: T]]` is a checked (not force) cast — it still requires
-- the call's inferred type to be a valid source (here, `any`/`nil`, both
-- of which are bilaterally assignable), so this is sound, just working
-- around an inference limitation rather than a soundness hole.
-- ========================

--: (x: ObligationArg) -> x is Type
local function is_type_arg(x)
	local k = x.kind
	return k == "int" or k == "string" or k == "bool" or k == "number" or k == "void"
		or k == "fn" or k == "generic" or k == "array" or k == "map" or k == "tyvar" or k == "uvar"
end

--: (x: ObligationArg) -> x is Expr
local function is_expr_arg(x)
	local k = x.kind
	return k == "lit_int" or k == "lit_str" or k == "lit_bool" or k == "lit_unit" or k == "var" or k == "if"
		or k == "binop" or k == "fn_lit" or k == "let" or k == "call" or k == "map_lit"
end

--: (x: ObligationArg) -> x is SchemeCell
local function is_scheme_cell_arg(x)
	return x.kind == "scheme_cell"
end

--: (x: ObligationArg) -> x is (SchemeCell | Scheme)
local function is_scheme_or_cell_arg(x)
	return x.kind == "scheme_cell" or x.kind == "scheme"
end

-- ========================
-- env: ambient typing context threaded through Infer/Check (not a claim
-- position — see init.lua OWNER-CALL "env threading").
-- ========================

--: (Env | nil, string) -> EnvValue | nil
local function env_lookup(env, name)
	while env do
		local v = env.vars[name]
		if v ~= nil then return v end
		env = env.parent
	end
	return nil
end

--: (Env | nil, string, EnvValue) -> Env
local function env_extend(env, name, value)
	return { vars = { [name] = value }, parent = env }
end

-- Extracted to a plain function (not inlined in the for-loop body below):
-- discriminant narrowing (`v.kind == "scheme_cell"`) does not apply to a
-- `for _, v in pairs(...)` iteration variable in this checker (confirmed
-- via a 15-line repro — the same narrowing on a directly-typed function
-- parameter works fine), so the narrowing has to happen inside a real
-- parameter binding instead.
--: (EnvValue, TyvarSet) -> nil
local function accumulate_free_tyvars(v, acc)
	if v.kind == "scheme_cell" then
		local sch = v.bound
		if sch then
			local inner = ir.free_tyvars(sch.type, {}) --[[: TyvarSet]]
			local bound_here = {}
			for _, qv in ipairs(sch.vars) do bound_here[qv] = true end
			for name in pairs(inner) do
				if not bound_here[name] then acc[name] = true end
			end
		end
	else
		ir.free_tyvars(v, acc)
	end
end

--: (Env | nil, TyvarSet) -> nil
local function env_free_tyvars(env, acc)
	while env do
		for _, v in pairs(env.vars) do
			accumulate_free_tyvars(v, acc)
		end
		env = env.parent
	end
end

-- ========================
-- Unify: (in, in) — structural, symmetric, mutates uvars eagerly.
-- ========================

--: (Obligation, PoolObj) -> (string, string | nil)
local function unify_producer(ob, ctx)
	local a0, b0 = ob.args[1], ob.args[2]
	if not is_type_arg(a0) then return "refuted", "Unify expects Type arguments, got " .. tostring(a0.kind) end
	if not is_type_arg(b0) then return "refuted", "Unify expects Type arguments, got " .. tostring(b0.kind) end
	local a, b = ir.deref(a0) --[[: Type]], ir.deref(b0) --[[: Type]]

	if a.kind == "uvar" and b.kind == "uvar" and a.id == b.id then
		return "proved"
	end
	if a.kind == "uvar" then
		if ir.occurs(a, b) then
			return "refuted", "occurs check failed: " .. ir.type_to_string(a) .. " occurs in " .. ir.type_to_string(b)
		end
		ctx:bind(a, b, ob.id)
		return "proved"
	end
	if b.kind == "uvar" then
		if ir.occurs(b, a) then
			return "refuted", "occurs check failed: " .. ir.type_to_string(b) .. " occurs in " .. ir.type_to_string(a)
		end
		ctx:bind(b, a, ob.id)
		return "proved"
	end
	if a.kind ~= b.kind then
		return "refuted", "cannot unify " .. ir.type_to_string(a) .. " with " .. ir.type_to_string(b)
	end
	if a.kind == "int" or a.kind == "string" or a.kind == "bool" or a.kind == "number" or a.kind == "void" then
		return "proved"
	elseif a.kind == "tyvar" then
		if b.kind == "tyvar" and a.name == b.name then return "proved" end
		return "refuted", "rigid type variable mismatch: " .. a.name .. " vs " .. ir.type_to_string(b)
	elseif a.kind == "fn" and b.kind == "fn" then
		if #a.params ~= #b.params then
			return "refuted", "function arity mismatch: " .. ir.type_to_string(a) .. " vs " .. ir.type_to_string(b)
		end
		for i = 1, #a.params do
			ctx:submit("Unify", { a.params[i], b.params[i] }, ob.id, "unify fn param " .. i)
		end
		ctx:submit("Unify", { a.ret, b.ret }, ob.id, "unify fn return")
		return "proved"
	elseif a.kind == "generic" and b.kind == "generic" then
		if a.name ~= b.name then
			return "refuted", "generic type head mismatch: " .. a.name .. " vs " .. b.name
		end
		if #a.args ~= #b.args then
			return "refuted", "generic type arity mismatch: " .. ir.type_to_string(a) .. " vs " .. ir.type_to_string(b)
		end
		for i = 1, #a.args do
			ctx:submit("Unify", { a.args[i], b.args[i] }, ob.id, "unify generic arg " .. i)
		end
		return "proved"
	elseif a.kind == "array" and b.kind == "array" then
		ctx:submit("Unify", { a.elem, b.elem }, ob.id, "unify array elem")
		return "proved"
	elseif a.kind == "map" and b.kind == "map" then
		ctx:submit("Unify", { a.key, b.key }, ob.id, "unify map key")
		ctx:submit("Unify", { a.value, b.value }, ob.id, "unify map value")
		return "proved"
	end
	return "refuted", "unsupported type kind in Unify: " .. tostring(a.kind)
end

-- ========================
-- Sub: (in, in) — a <: b.
-- ========================

-- Sub uses "accumulate" mode dynamically: when one operand is a uvar, it
-- records the known side as a bound on that uvar (via pool:add_lower_bound
-- / pool:add_upper_bound) instead of collapsing to Unify. This preserves
-- subtyping precision — Sub(int, ?x) records "?x >= int" rather than
-- forcing ?x := int, so a later Sub(?x, number) can still prove. When both
-- operands are uvars, Sub defers (returns "deferred" with the left uvar's
-- id) until at least one side resolves.
--
-- No static blocking positions — Sub handles all four ground/uvar
-- combinations itself. This replaces the previous ad-hoc asymmetric
-- blocking on position 1 and the collapse-to-Unify fallback (former
-- OWNER-CALL C, now resolved by the accumulate mechanism).
--: (Obligation, PoolObj) -> (string, string | integer | nil)
local function sub_producer(ob, ctx)
	local a0, b0 = ob.args[1], ob.args[2]
	if not is_type_arg(a0) then return "refuted", "Sub expects Type arguments, got " .. tostring(a0.kind) end
	if not is_type_arg(b0) then return "refuted", "Sub expects Type arguments, got " .. tostring(b0.kind) end
	local a, b = ir.deref(a0) --[[: Type]], ir.deref(b0) --[[: Type]]

	-- Both uvars: defer on the left side's id. When the left resolves,
	-- this obligation re-enters the worklist and dispatches to one of the
	-- three remaining cases below.
	if a.kind == "uvar" and b.kind == "uvar" then
		return "deferred", a.id
	end

	-- Left known, right uvar: record left as a lower bound on right.
	-- "a <: ?b" means a is a lower bound on b.
	if b.kind == "uvar" then
		ctx:add_lower_bound(b --[[: UvarType]], a, ob.id)
		return "proved"
	end

	-- Left uvar, right known: record right as an upper bound on left.
	-- "?a <: b" means b is an upper bound on a.
	if a.kind == "uvar" then
		ctx:add_upper_bound(a --[[: UvarType]], b, ob.id)
		return "proved"
	end

	-- Both ground/compound: structural subtype check.
	if a.kind == "int" and b.kind == "number" then return "proved" end

	if a.kind ~= b.kind then
		return "refuted", ir.type_to_string(a) .. " is not a subtype of " .. ir.type_to_string(b)
	end
	if a.kind == "int" or a.kind == "string" or a.kind == "bool" or a.kind == "number" or a.kind == "void" then
		return "proved"
	elseif a.kind == "tyvar" then
		if b.kind == "tyvar" and a.name == b.name then return "proved" end
		return "refuted", "rigid type variable mismatch: " .. a.name .. " vs " .. ir.type_to_string(b)
	elseif a.kind == "fn" and b.kind == "fn" then
		if #a.params ~= #b.params then
			return "refuted", "function arity mismatch in subtyping: " .. ir.type_to_string(a) .. " vs " .. ir.type_to_string(b)
		end
		for i = 1, #a.params do
			-- contravariant: b's declared param must accept what a's declared param accepts
			ctx:submit("Sub", { b.params[i], a.params[i] }, ob.id, "contravariant fn param " .. i)
		end
		ctx:submit("Sub", { a.ret, b.ret }, ob.id, "covariant fn return")
		return "proved"
	elseif a.kind == "generic" and b.kind == "generic" then
		if a.name ~= b.name or #a.args ~= #b.args then
			return "refuted", "generic head/arity mismatch in subtyping: " .. ir.type_to_string(a) .. " vs " .. ir.type_to_string(b)
		end
		-- OWNER-CALL B: generic type-constructor argument variance. This toy
		-- has no per-parameter variance annotations, so there are two
		-- defensible, semantically-diverging choices: treat all generic
		-- args invariantly (require exact equality via Unify) or
		-- covariantly (recurse via Sub). Covariant would let e.g.
		-- Store<int> <: Store<number>; invariant forbids it. Chose
		-- invariant — it's the conservative default real languages use
		-- absent an explicit variance annotation, and it's what the ECS
		-- test actually needs (generic instantiation via Unify at call
		-- sites, never subtyping between two different generic
		-- instantiations).
		for i = 1, #a.args do
			ctx:submit("Unify", { a.args[i], b.args[i] }, ob.id, "invariant generic arg " .. i)
		end
		return "proved"
	elseif a.kind == "array" and b.kind == "array" then
		ctx:submit("Sub", { a.elem, b.elem }, ob.id, "covariant array elem")
		return "proved"
	elseif a.kind == "map" and b.kind == "map" then
		ctx:submit("Unify", { a.key, b.key }, ob.id, "map key invariant")
		ctx:submit("Sub", { a.value, b.value }, ob.id, "covariant map value")
		return "proved"
	end
	return "refuted", "unsupported type kind in Sub: " .. tostring(a.kind)
end

-- ========================
-- Instantiate: (in scheme/scheme_cell, out uvar). Blocking on position 1 —
-- the only judgment in this toy that needs pool-level deferral, because a
-- scheme is atomic (nothing meaningful to do with half a scheme) whereas a
-- type built from uvars can always be bound to incrementally.
-- ========================

--: (Obligation, PoolObj) -> (string, string | nil)
local function instantiate_producer(ob, ctx)
	local cell_or_scheme, out = ob.args[1], ob.args[2]
	if not is_scheme_or_cell_arg(cell_or_scheme) then
		return "refuted", "Instantiate expects a Scheme or SchemeCell, got " .. tostring(cell_or_scheme.kind)
	end
	if not is_type_arg(out) then
		return "refuted", "Instantiate expects a Type out-position, got " .. tostring(out.kind)
	end
	local scheme
	if cell_or_scheme.kind == "scheme_cell" then
		if not cell_or_scheme.bound then
			return "refuted", "internal error: Instantiate ran against an unresolved scheme_cell"
		end
		scheme = cell_or_scheme.bound
	else
		scheme = cell_or_scheme
	end
	local mapping = {}
	for _, name in ipairs(scheme.vars) do
		mapping[name] = ir.mk_uvar() --[[: Type]]
	end
	local instantiated = ir.substitute_tyvars(scheme.type, mapping) --[[: Type]]
	ctx:submit("Unify", { out, instantiated }, ob.id, "instantiate scheme")
	return "proved"
end

-- ========================
-- Generalize: (in env, in type, out scheme_cell). Real HM-style
-- generalization: vars = free tyvars of `type` not free in `env`. Not
-- degenerate — env is genuinely consulted (see init.lua doc comment).
-- ========================

--: (Obligation, PoolObj) -> (string, string | nil)
local function generalize_producer(ob, ctx)
	local env_arg, ty0, out = ob.args[1], ob.args[2], ob.args[3]
	if not is_type_arg(ty0) then return "refuted", "Generalize expects a Type, got " .. tostring(ty0.kind) end
	if not is_scheme_cell_arg(out) then
		return "refuted", "Generalize expects a SchemeCell out-position, got " .. tostring(out.kind)
	end
	-- `env` isn't one of the moded ObligationArg positions (see init.lua
	-- OWNER-CALL A) — it rides on ob.env, and Generalize's own args[1] is
	-- unused. Read it from ob.env instead.
	local env = ob.env
	local ty = ir.deref(ty0) --[[: Type]]
	local ty_free = ir.free_tyvars(ty, {}) --[[: TyvarSet]]
	local env_free = {}
	env_free_tyvars(env, env_free)
	local vars = {}
	for name in pairs(ty_free) do
		if not env_free[name] then vars[#vars + 1] = name end
	end
	table.sort(vars)
	ctx:resolve(out, ir.mk_scheme(vars, ty) --[[: Scheme]])
	return "proved"
end

-- ========================
-- Infer/Check: the toy language's typing rules.
-- ========================

local infer_expr, check_expr

--: (Expr, Type, Obligation, PoolObj) -> (string, string | nil)
check_expr = function(expr, expected, ob, ctx)
	-- Bidirectional "switch" rule: check-by-infer-then-subtype. This toy
	-- does not push expected types down into if/let/etc for better error
	-- locality (a real bidirectional checker would); punted for size.
	local fresh = ir.mk_uvar() --[[: Type]]
	ctx:submit("Infer", { expr, fresh }, ob.id, "check: infer then subtype", ob.env)
	ctx:submit("Sub", { fresh, expected }, ob.id, "check: subtype against expected")
	return "proved"
end

--: (Expr, Type, Obligation, PoolObj) -> (string, string | nil)
infer_expr = function(expr, out, ob, ctx)
	local env = ob.env

	-- NOTE: branch directly on `expr.kind`, not on `local k = expr.kind`.
	-- Aliasing to a local does NOT narrow the object it was read from (see
	-- docs/typechecker-reference.md's discriminant-narrowing note) — an
	-- earlier version of this dispatch used `local k = expr.kind; if k ==
	-- "var" then ... expr.name ...` and every field access on `expr`
	-- inside those branches came back `T | nil` because only `k` had been
	-- narrowed, not `expr`.
	if expr.kind == "lit_int" then
		ctx:submit("Unify", { out, ir.mk_int() --[[: Type]] }, ob.id, "int literal")
		return "proved"
	elseif expr.kind == "lit_str" then
		ctx:submit("Unify", { out, ir.mk_string() --[[: Type]] }, ob.id, "string literal")
		return "proved"
	elseif expr.kind == "lit_bool" then
		ctx:submit("Unify", { out, ir.mk_bool() --[[: Type]] }, ob.id, "bool literal")
		return "proved"
	elseif expr.kind == "lit_unit" then
		ctx:submit("Unify", { out, ir.mk_void() --[[: Type]] }, ob.id, "unit literal")
		return "proved"

	elseif expr.kind == "var" then
		local found = env_lookup(env, expr.name)
		if not found then
			return "refuted", "unbound variable: " .. expr.name
		end
		if found.kind == "scheme_cell" then
			ctx:submit("Instantiate", { found, out }, ob.id, "instantiate " .. expr.name)
		else
			ctx:submit("Unify", { out, found }, ob.id, "use of " .. expr.name)
		end
		return "proved"

	elseif expr.kind == "if" then
		ctx:submit("Check", { expr.cond, ir.mk_bool() --[[: Type]] }, ob.id, "if condition", env)
		ctx:submit("Infer", { expr.then_, out }, ob.id, "if then-branch", env)
		ctx:submit("Infer", { expr.else_, out }, ob.id, "if else-branch", env)
		return "proved"

	elseif expr.kind == "binop" then
		if expr.op == "mod" then
			ctx:submit("Check", { expr.left, ir.mk_int() --[[: Type]] }, ob.id, "mod lhs", env)
			ctx:submit("Check", { expr.right, ir.mk_int() --[[: Type]] }, ob.id, "mod rhs", env)
			ctx:submit("Unify", { out, ir.mk_int() --[[: Type]] }, ob.id, "mod result")
		elseif expr.op == "eq" then
			ctx:submit("Check", { expr.left, ir.mk_int() --[[: Type]] }, ob.id, "eq lhs", env)
			ctx:submit("Check", { expr.right, ir.mk_int() --[[: Type]] }, ob.id, "eq rhs", env)
			ctx:submit("Unify", { out, ir.mk_bool() --[[: Type]] }, ob.id, "eq result")
		elseif expr.op == "concat" then
			ctx:submit("Check", { expr.left, ir.mk_string() --[[: Type]] }, ob.id, "concat lhs", env)
			ctx:submit("Check", { expr.right, ir.mk_string() --[[: Type]] }, ob.id, "concat rhs", env)
			ctx:submit("Unify", { out, ir.mk_string() --[[: Type]] }, ob.id, "concat result")
		else
			return "refuted", "unsupported binop: " .. expr.op
		end
		return "proved"

	elseif expr.kind == "fn_lit" then
		if expr.type_params and #expr.type_params > 0 then
			-- Generic function literals are only supported as the direct
			-- right-hand side of a `let` (see the `let` case below), where
			-- Generalize can wrap them without needing rank-2 machinery.
			-- A bare generic fn literal anywhere else is an explicit,
			-- stated punt, not an ambiguous fork.
			return "refuted", "generic function literals are only supported as the direct value of a let-binding in this toy"
		end
		-- p.type/expr.ret are TypeAnn, not Type — TypeAnn additionally allows
		-- `tvar_ref` (for generic params), which Type does not, so a plain
		-- checked cast is correctly rejected here (TypeAnn is not a subtype
		-- of Type). This non-generic branch is only reachable when
		-- type_params is empty, so no tvar_ref should actually appear;
		-- ir.resolve_type_vars(ann, {}) both performs the real TypeAnn->Type
		-- conversion and hard-errors if a tvar_ref sneaks in anyway (an
		-- empty mapping can never resolve one) — same convention
		-- resolve_type_vars already uses for an unbound type parameter.
		local param_types = {}
		local body_env = env
		for i, p in ipairs(expr.params) do
			local pt = ir.resolve_type_vars(p.type, {}) --[[: Type]]
			param_types[i] = pt
			body_env = env_extend(body_env, p.name, pt)
		end
		local ret_type
		if expr.ret then
			ret_type = ir.resolve_type_vars(expr.ret, {}) --[[: Type]]
			ctx:submit("Check", { expr.body, ret_type }, ob.id, "fn body check", body_env)
		else
			ret_type = ir.mk_uvar() --[[: Type]]
			ctx:submit("Infer", { expr.body, ret_type }, ob.id, "fn body infer", body_env)
		end
		ctx:submit("Unify", { out, ir.mk_fn(param_types, ret_type) --[[: Type]] }, ob.id, "fn type")
		return "proved"

	elseif expr.kind == "let" then
		if expr.value.kind == "fn_lit" and expr.value.type_params and #expr.value.type_params > 0 then
			local fnv = expr.value
			if not fnv.ret then
				return "refuted", "generic function '" .. expr.name .. "' must have an explicit return type annotation"
			end
			local tyvar_map = {}
			for _, name in ipairs(fnv.type_params) do tyvar_map[name] = ir.mk_tyvar(name) --[[: Type]] end
			local param_types = {}
			local body_env = env
			for i, p in ipairs(fnv.params) do
				local pt = ir.resolve_type_vars(p.type, tyvar_map) --[[: Type]]
				param_types[i] = pt
				body_env = env_extend(body_env, p.name, pt)
			end
			local ret_type = ir.resolve_type_vars(fnv.ret, tyvar_map) --[[: Type]]
			local fn_type = ir.mk_fn(param_types, ret_type) --[[: Type]]
			ctx:submit("Check", { fnv.body, ret_type }, ob.id, "generic fn body check", body_env)
			local scheme_cell = ir.mk_scheme_cell(nil) --[[: SchemeCell]]
			ctx:submit("Generalize", { ir.mk_void() --[[: Type]], fn_type, scheme_cell }, ob.id, "generalize " .. expr.name, env)
			local child_env = env_extend(env, expr.name, scheme_cell)
			ctx:submit("Infer", { expr.body, out }, ob.id, "let body", child_env)
			return "proved"
		else
			local v_out = ir.mk_uvar() --[[: Type]]
			if expr.ann then
				-- Same TypeAnn->Type conversion as the fn_lit case above.
				local ann = ir.resolve_type_vars(expr.ann, {}) --[[: Type]]
				ctx:submit("Check", { expr.value, ann }, ob.id, "let value check against annotation", env)
				ctx:submit("Unify", { v_out, ann }, ob.id, "let binding takes annotated type")
			else
				ctx:submit("Infer", { expr.value, v_out }, ob.id, "let value infer", env)
			end
			local child_env = env_extend(env, expr.name, v_out)
			ctx:submit("Infer", { expr.body, out }, ob.id, "let body", child_env)
			return "proved"
		end

	elseif expr.kind == "call" then
		local fn_out = ir.mk_uvar() --[[: Type]]
		ctx:submit("Infer", { expr.fn, fn_out }, ob.id, "call target", env)
		local param_uvars = {}
		for i, a in ipairs(expr.args) do
			local a_out = ir.mk_uvar() --[[: Type]]
			ctx:submit("Infer", { a, a_out }, ob.id, "call arg " .. i, env)
			local p_uvar = ir.mk_uvar() --[[: Type]]
			param_uvars[i] = p_uvar
			ctx:submit("Sub", { a_out, p_uvar }, ob.id, "call arg " .. i .. " is a subtype of the param")
		end
		local ret_uvar = ir.mk_uvar() --[[: Type]]
		ctx:submit("Unify", { fn_out, ir.mk_fn(param_uvars, ret_uvar) --[[: Type]] }, ob.id, "call target has fn shape")
		ctx:submit("Unify", { out, ret_uvar }, ob.id, "call result")
		return "proved"

	elseif expr.kind == "map_lit" then
		if #expr.entries == 0 then
			-- Punt: an empty map literal has no inferrable value type here
			-- (no bidirectional push-down of an expected type into map
			-- literals in this toy). Documented limitation, not a fork.
			return "refuted", "empty map literal has no inferrable value type in this toy"
		end
		local v0 = ir.mk_uvar() --[[: Type]]
		for i, e in ipairs(expr.entries) do
			ctx:submit("Check", { e.key, ir.mk_string() --[[: Type]] }, ob.id, "map key " .. i, env)
			local v_out = ir.mk_uvar() --[[: Type]]
			ctx:submit("Infer", { e.value, v_out }, ob.id, "map value " .. i, env)
			ctx:submit("Unify", { v_out, v0 }, ob.id, "map value " .. i .. " joins with entry 1")
		end
		ctx:submit("Unify", { out, ir.mk_map(ir.mk_string() --[[: Type]], v0) --[[: Type]] }, ob.id, "map type")
		return "proved"

	end

	return "refuted", "infer: unsupported expression kind: " .. tostring(expr.kind)
end

--: (Obligation, PoolObj) -> (string, string | nil)
local function infer_check_producer(ob, ctx)
	local expr0, ty0 = ob.args[1], ob.args[2]
	if not is_expr_arg(expr0) then
		return "refuted", (ob.judgment) .. " expects an Expr in position 1, got " .. tostring(expr0.kind)
	end
	if not is_type_arg(ty0) then
		return "refuted", (ob.judgment) .. " expects a Type in position 2, got " .. tostring(ty0.kind)
	end
	local expr = expr0
	local ty = ty0
	if ob.judgment == "Infer" then
		return infer_expr(expr, ty, ob, ctx)
	else
		return check_expr(expr, ty, ob, ctx)
	end
end

-- Register every producer onto `pool`.
--: (PoolObj) -> nil
function M.register_all(pool)
	pool:register("Unify", unify_producer)
	-- Sub has no static blocking positions — it handles all four
	-- ground/uvar combinations dynamically via accumulate mode (see
	-- sub_producer above). When both operands are uvars, the producer
	-- returns "deferred" with the left uvar's id.
	pool:register("Sub", sub_producer)
	pool:register("Instantiate", instantiate_producer, { 1 })
	pool:register("Generalize", generalize_producer)
	pool:register("Infer", infer_check_producer)
	pool:register("Check", infer_check_producer)
end

M._env_extend = env_extend -- exposed for tests building initial builtin envs

return M
