-- lib/type/experiments/v5_perf/types.lua
-- v5 typechecker perf-experiment Type AST.
--
-- Type ::= UVar(TVarId)           -- opaque to beta, scheduler-introduced
--        | Var(LvlIdx)            -- De Bruijn level for bound type vars
--        | App(Type, Type)
--        | Lambda(Kind, Type)
--        | Const(name)            -- nil | boolean | number | string | etc.
--        | Record(fields)         -- { k -> Type }
--        | Arrow(args, rets)      -- (Type[]) -> (Type[])
--        | Union(Type[])
--
-- IMPORTANT: branch directly on `t.tag == "literal-string"` so the v4
-- typechecker narrows the discriminated union (per lib/type/static-v4/types.lua
-- "Tag string constants are exposed for callers... Inside this module we use
-- the string literals directly").

local M = {}

--:: TUVar         = { tag: "uvar", id: integer }
--:: TVarBnd       = { tag: "var", i: integer }
--:: TApp          = { tag: "app", f: V5Type, a: V5Type }
--:: TLambda       = { tag: "lambda", k: string, b: V5Type }
--:: TConst        = { tag: "const", name: string }
--:: TRowVar       = { tag: "rowvar", id: integer }
--:: TRecord       = { tag: "record", fields: { [string]: V5Type }, row: TRowVar | nil }
--:: TPackVar      = { tag: "packvar", id: integer }
--:: TPack         = { tag: "pack", items: V5Type[], rest: TPackVar | nil }
--:: TArrow        = { tag: "arrow", args: TPack, ret: TPack }
--:: TUnion        = { tag: "union", xs: V5Type[] }
--:: TIntersection = { tag: "intersection", parts: V5Type[] }
--:: V5Type        = TUVar | TVarBnd | TApp | TLambda | TConst | TRowVar | TRecord | TPackVar | TPack | TArrow | TUnion | TIntersection

--: (integer) -> V5Type
function M.uvar(id) return { tag = "uvar", id = id } end
--: (integer) -> V5Type
function M.var(i) return { tag = "var", i = i } end
--: (V5Type, V5Type) -> V5Type
function M.app(f, a) return { tag = "app", f = f, a = a } end
--: (string, V5Type) -> V5Type
function M.lambda(k, b) return { tag = "lambda", k = k, b = b } end
--: (string) -> V5Type
function M.const(name) return { tag = "const", name = name } end
--: (integer) -> V5Type
function M.rowvar(id) return { tag = "rowvar", id = id } end
--: ({ [string]: V5Type }) -> V5Type
function M.record(fields) return { tag = "record", fields = fields, row = nil } end
--: ({ [string]: V5Type }, TRowVar) -> V5Type
function M.record_open(fields, row) return { tag = "record", fields = fields, row = row } end
--: (V5Type[]) -> V5Type
function M.intersection(parts) return { tag = "intersection", parts = parts } end
-- pack(items, rest): a TPack node.  `rest` is nil (closed: exact arity #items)
-- or a TPackVar (open: matches #items positions then a tail bound to the var).
-- The one-open-pack invariant (a sequence has at most one open segment) is an
-- invariant of the data type — a TPack carries a single optional `rest`.
--: (V5Type[], TPackVar | nil) -> V5Type
function M.pack(items, rest) return { tag = "pack", items = items, rest = rest } end
-- packvar(id): a pack metavariable (open-tail position).  Ids are gensym like
-- UVar / TRowVar; they do NOT participate in De Bruijn (shift/instantiate leave
-- packvar ids unchanged).  Bound in a separate `pack_bindings` map.
--: (integer) -> V5Type
function M.packvar(id) return { tag = "packvar", id = id } end
-- arrow(args_list, rets_list): build an arrow whose `args` and `ret` are CLOSED
-- packs over the given positional lists (the common fixed-arity case).  An
-- explicit open arrow is built directly with `M.pack(list, packvar)`.
--: (V5Type[], V5Type[]) -> V5Type
function M.arrow(args_list, rets_list)
	local args_items = {} --[[: V5Type[] ]]
	for i = 1, #args_list do
		local v = args_list[i]
		if v ~= nil then args_items[i] = v end
	end
	local ret_items = {} --[[: V5Type[] ]]
	for i = 1, #rets_list do
		local v = rets_list[i]
		if v ~= nil then ret_items[i] = v end
	end
	return {
		tag = "arrow",
		args = { tag = "pack", items = args_items, rest = nil },
		ret  = { tag = "pack", items = ret_items, rest = nil },
	}
end
--: (V5Type[]) -> V5Type
function M.union(xs) return { tag = "union", xs = xs } end

-- Effect-type API.  Effects ARE types — represented as TConst with a "!"
-- prefix so they fit the existing taxonomy without parallel infrastructure.
-- `effect("io")` -> Const("!io"); higher-arity effects (`!throw<E>`,
-- `!yield<Y,R>`) are built via App chains over the effect head Const.
--: (string) -> V5Type
function M.effect(name) return { tag = "const", name = "!" .. name } end
--: (V5Type, V5Type[]) -> V5Type
function M.effect_apply(eff, args)
	local cur = eff
	for i = 1, #args do
		local a = args[i]
		if a ~= nil then cur = { tag = "app", f = cur, a = a } end
	end
	return cur
end
-- Returns true iff t is an effect-type head (Const named "!...").
--: (V5Type) -> boolean
function M.is_effect_head(t)
	if t.tag == "const" then
		local n = t.name
		return n:sub(1, 1) == "!"
	end
	return false
end
-- Returns true iff t is an effect-typed value: an effect head or an
-- application chain ultimately headed by one.
--: (V5Type) -> boolean
function M.is_effect(t)
	local cur = t
	while cur.tag == "app" do cur = cur.f end
	return M.is_effect_head(cur)
end

-- shift_pack(p, d, cutoff): shift each item of a TPack at cutoff; the rest
-- TPackVar id is a gensym (like UVar) and is preserved unchanged.  Returns a
-- TPack (so it can populate an arrow's args/ret without an unprovable cast).
--: (TPack, integer, integer) -> TPack
function M.shift_pack(p, d, cutoff)
	local items = {} --[[: V5Type[] ]]
	for i = 1, #p.items do
		local v = p.items[i]
		if v ~= nil then local sh = M.shift(v, d, cutoff) --[[: V5Type ]]; items[i] = sh end
	end
	return { tag = "pack", items = items, rest = p.rest }
end

-- shift(t, d, cutoff): add d to every Var index >= cutoff. Used under binders
-- when β-reducing. Eager shift on bind.
--: (V5Type, integer, integer) -> V5Type
function M.shift(t, d, cutoff)
	if t.tag == "uvar" or t.tag == "const" or t.tag == "rowvar" or t.tag == "packvar" then
		return t
	elseif t.tag == "var" then
		if t.i >= cutoff then return { tag = "var", i = t.i + d } end
		return t
	elseif t.tag == "app" then
		return { tag = "app", f = M.shift(t.f, d, cutoff), a = M.shift(t.a, d, cutoff) }
	elseif t.tag == "lambda" then
		return { tag = "lambda", k = t.k, b = M.shift(t.b, d, cutoff + 1) }
	elseif t.tag == "record" then
		local out = {} --[[: { [string]: V5Type } ]]
		for fk, fv in pairs(t.fields) do
			if fv ~= nil then
				local sh = M.shift(fv, d, cutoff) --[[: V5Type ]]
				out[fk] = sh
			end
		end
		return { tag = "record", fields = out, row = t.row }
	elseif t.tag == "pack" then
		return M.shift_pack(t, d, cutoff)
	elseif t.tag == "arrow" then
		return { tag = "arrow", args = M.shift_pack(t.args, d, cutoff), ret = M.shift_pack(t.ret, d, cutoff) }
	elseif t.tag == "union" then
		local xs = {} --[[: V5Type[] ]]
		for i = 1, #t.xs do
			local v = t.xs[i]
			if v ~= nil then local sh = M.shift(v, d, cutoff) --[[: V5Type ]]; xs[i] = sh end
		end
		return { tag = "union", xs = xs }
	elseif t.tag == "intersection" then
		local parts = {} --[[: V5Type[] ]]
		for i = 1, #t.parts do
			local v = t.parts[i]
			if v ~= nil then local sh = M.shift(v, d, cutoff) --[[: V5Type ]]; parts[i] = sh end
		end
		return { tag = "intersection", parts = parts }
	end
	error("shift: unreachable")
end

-- instantiate_pack(p, arg, depth): instantiate each item of a TPack; the rest
-- TPackVar is preserved (capture binding is a substitution/evaluation concern,
-- not relocated by instantiate).  Returns a TPack.
--: (TPack, V5Type, integer) -> TPack
function M.instantiate_pack(p, arg, depth)
	local items = {} --[[: V5Type[] ]]
	for i = 1, #p.items do
		local v = p.items[i]
		if v ~= nil then local sh = M.instantiate(v, arg, depth) --[[: V5Type ]]; items[i] = sh end
	end
	return { tag = "pack", items = items, rest = p.rest }
end

-- instantiate(body, arg, depth): substitute Var(depth) := arg in body,
-- decrementing outer indices. Used by β.
--: (V5Type, V5Type, integer) -> V5Type
function M.instantiate(body, arg, depth)
	if body.tag == "uvar" or body.tag == "const" or body.tag == "rowvar" or body.tag == "packvar" then
		return body
	elseif body.tag == "var" then
		if body.i == depth then return M.shift(arg, depth, 0) end
		if body.i > depth then return { tag = "var", i = body.i - 1 } end
		return body
	elseif body.tag == "app" then
		return { tag = "app", f = M.instantiate(body.f, arg, depth), a = M.instantiate(body.a, arg, depth) }
	elseif body.tag == "lambda" then
		return { tag = "lambda", k = body.k, b = M.instantiate(body.b, arg, depth + 1) }
	elseif body.tag == "record" then
		local out = {} --[[: { [string]: V5Type } ]]
		for fk, fv in pairs(body.fields) do
			if fv ~= nil then local sh = M.instantiate(fv, arg, depth) --[[: V5Type ]]; out[fk] = sh end
		end
		return { tag = "record", fields = out, row = body.row }
	elseif body.tag == "pack" then
		return M.instantiate_pack(body, arg, depth)
	elseif body.tag == "arrow" then
		return { tag = "arrow", args = M.instantiate_pack(body.args, arg, depth), ret = M.instantiate_pack(body.ret, arg, depth) }
	elseif body.tag == "union" then
		local xs = {} --[[: V5Type[] ]]
		for i = 1, #body.xs do
			local v = body.xs[i]
			if v ~= nil then local sh = M.instantiate(v, arg, depth) --[[: V5Type ]]; xs[i] = sh end
		end
		return { tag = "union", xs = xs }
	elseif body.tag == "intersection" then
		local parts = {} --[[: V5Type[] ]]
		for i = 1, #body.parts do
			local v = body.parts[i]
			if v ~= nil then local sh = M.instantiate(v, arg, depth) --[[: V5Type ]]; parts[i] = sh end
		end
		return { tag = "intersection", parts = parts }
	end
	error("instantiate: unreachable")
end

-- Structural equality (used after substitution-walk to settle CEq).
--: (V5Type, V5Type) -> boolean
function M.equal(a, b)
	if a == b then return true end
	if a.tag ~= b.tag then return false end
	if a.tag == "uvar" and b.tag == "uvar" then return a.id == b.id end
	if a.tag == "var" and b.tag == "var" then return a.i == b.i end
	if a.tag == "const" and b.tag == "const" then return a.name == b.name end
	if a.tag == "rowvar" and b.tag == "rowvar" then return a.id == b.id end
	if a.tag == "packvar" and b.tag == "packvar" then return a.id == b.id end
	if a.tag == "app" and b.tag == "app" then
		if not M.equal(a.f, b.f) then return false end
		return M.equal(a.a, b.a)
	end
	if a.tag == "lambda" and b.tag == "lambda" then
		if a.k ~= b.k then return false end
		return M.equal(a.b, b.b)
	end
	if a.tag == "record" and b.tag == "record" then
		local af, bf = a.fields, b.fields
		for k, _ in pairs(af) do if bf[k] == nil then return false end end
		for k, v in pairs(bf) do
			local av = af[k]
			if av == nil or not M.equal(av, v) then return false end
		end
		-- Compare row extension: both nil (closed) or same rowvar id.
		if a.row == nil and b.row == nil then return true end
		if a.row == nil or b.row == nil then return false end
		return a.row.id == b.row.id
	end
	if a.tag == "pack" and b.tag == "pack" then
		if #a.items ~= #b.items then return false end
		for i = 1, #a.items do if not M.equal(a.items[i], b.items[i]) then return false end end
		-- rest agreement: both nil (closed) or both TPackVar with equal id.
		if a.rest == nil and b.rest == nil then return true end
		if a.rest == nil or b.rest == nil then return false end
		return a.rest.id == b.rest.id
	end
	if a.tag == "arrow" and b.tag == "arrow" then
		if not M.equal(a.args, b.args) then return false end
		return M.equal(a.ret, b.ret)
	end
	if a.tag == "union" and b.tag == "union" then
		if #a.xs ~= #b.xs then return false end
		for i = 1, #a.xs do if not M.equal(a.xs[i], b.xs[i]) then return false end end
		return true
	end
	if a.tag == "intersection" and b.tag == "intersection" then
		if #a.parts ~= #b.parts then return false end
		for i = 1, #a.parts do if not M.equal(a.parts[i], b.parts[i]) then return false end end
		return true
	end
	return false
end

-- Free-tvar collector: walks t and sets acc[tvar_id] = true for each UVar.
--: (V5Type, { [integer]: boolean }) -> nil
function M.collect_uvars(t, acc)
	if t.tag == "uvar" then acc[t.id] = true
	elseif t.tag == "app" then
		M.collect_uvars(t.f, acc); M.collect_uvars(t.a, acc)
	elseif t.tag == "lambda" then M.collect_uvars(t.b, acc)
	elseif t.tag == "record" then
		for _, fv in pairs(t.fields) do M.collect_uvars(fv, acc) end
	elseif t.tag == "pack" then
		for i = 1, #t.items do M.collect_uvars(t.items[i], acc) end
		-- A TPackVar contributes no UVar; its bound contents (in pack_bindings)
		-- are walked at substitution time, not from the syntactic AST.
	elseif t.tag == "arrow" then
		M.collect_uvars(t.args, acc)
		M.collect_uvars(t.ret, acc)
	elseif t.tag == "union" then
		for i = 1, #t.xs do M.collect_uvars(t.xs[i], acc) end
	elseif t.tag == "intersection" then
		for i = 1, #t.parts do M.collect_uvars(t.parts[i], acc) end
	end
end

-- deref_pack(p, pack_bindings): the substitution-time splice.  Walk `p`,
-- replacing a bound `rest` TPackVar by its binding and FLATTENING (splicing) the
-- binding's items into p.items, recursively, until `rest` is nil (closed) or an
-- unbound TPackVar.  `pack_bindings` is `{ [packvar-id]: TPack }`.
--
-- Example: pack([true], rest=R) with R ↦ pack([int, str], nil)
--   becomes pack([true, int, str], nil).  R ↦ pack([], nil) (empty / never)
--   collapses to pack([true], nil).  A binding may itself be open, in which
--   case the resolved rest carries through (the new `rest` is the binding's
--   own rest, which we then continue to resolve).
--: (V5Type, { [integer]: V5Type }) -> V5Type
function M.deref_pack(p, pack_bindings)
	if p.tag ~= "pack" then return p end
	local items = {} --[[: V5Type[] ]]
	for i = 1, #p.items do
		local v = p.items[i]
		if v ~= nil then items[#items + 1] = v end
	end
	--: TPackVar | nil
	local rest = p.rest
	-- Guard against a (malformed) cyclic binding by bounding the splice depth to
	-- the number of distinct bindings encountered.
	local seen = {} --[[: { [integer]: boolean } ]]
	while rest ~= nil do
		local bnd = pack_bindings[rest.id]
		if bnd == nil then break end
		if seen[rest.id] then break end
		seen[rest.id] = true
		if bnd.tag ~= "pack" then break end
		for i = 1, #bnd.items do
			local v = bnd.items[i]
			if v ~= nil then items[#items + 1] = v end
		end
		rest = bnd.rest
	end
	return { tag = "pack", items = items, rest = rest }
end

-- pack_head_key(p): the structural head token for the Spec A termination cache,
-- extended to packs as ⟨"pack", #items, rest-id-or-nil⟩.  The per-item head
-- hashes are appended by the caller (op_sem head_key) — this returns only the
-- pack's own head token.
--: (V5Type) -> string
function M.pack_head_key(p)
	if p.tag ~= "pack" then return p.tag end
	local rest = p.rest
	local rid = "nil"
	if rest ~= nil then rid = tostring(rest.id) end
	return "pack#" .. tostring(#p.items) .. "#" .. rid
end

return M
