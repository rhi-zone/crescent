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
--:: TArrow        = { tag: "arrow", args: V5Type[], ret: V5Type }
--:: TUnion        = { tag: "union", xs: V5Type[] }
--:: TIntersection = { tag: "intersection", parts: V5Type[] }
--:: V5Type        = TUVar | TVarBnd | TApp | TLambda | TConst | TRowVar | TRecord | TArrow | TUnion | TIntersection

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
--: (V5Type[], V5Type[]) -> V5Type
function M.arrow(args, rets_list)
	local fields = {} --[[: { [string]: V5Type } ]]
	for i = 1, #rets_list do
		local v = rets_list[i]
		if v ~= nil then fields[tostring(i)] = v end
	end
	return { tag = "arrow", args = args, ret = { tag = "record", fields = fields, row = nil } }
end
--: (V5Type[]) -> V5Type
function M.union(xs) return { tag = "union", xs = xs } end

-- shift(t, d, cutoff): add d to every Var index >= cutoff. Used under binders
-- when β-reducing. Eager shift on bind.
--: (V5Type, integer, integer) -> V5Type
function M.shift(t, d, cutoff)
	if t.tag == "uvar" or t.tag == "const" or t.tag == "rowvar" then
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
	elseif t.tag == "arrow" then
		local args = {} --[[: V5Type[] ]]
		for i = 1, #t.args do
			local v = t.args[i]
			if v ~= nil then local sh = M.shift(v, d, cutoff) --[[: V5Type ]]; args[i] = sh end
		end
		local ret = M.shift(t.ret, d, cutoff) --[[: V5Type ]]
		return { tag = "arrow", args = args, ret = ret }
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

-- instantiate(body, arg, depth): substitute Var(depth) := arg in body,
-- decrementing outer indices. Used by β.
--: (V5Type, V5Type, integer) -> V5Type
function M.instantiate(body, arg, depth)
	if body.tag == "uvar" or body.tag == "const" or body.tag == "rowvar" then
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
	elseif body.tag == "arrow" then
		local args = {} --[[: V5Type[] ]]
		for i = 1, #body.args do
			local v = body.args[i]
			if v ~= nil then local sh = M.instantiate(v, arg, depth) --[[: V5Type ]]; args[i] = sh end
		end
		local ret = M.instantiate(body.ret, arg, depth) --[[: V5Type ]]
		return { tag = "arrow", args = args, ret = ret }
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
	if a.tag == "arrow" and b.tag == "arrow" then
		if #a.args ~= #b.args then return false end
		for i = 1, #a.args do if not M.equal(a.args[i], b.args[i]) then return false end end
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
	elseif t.tag == "arrow" then
		for i = 1, #t.args do M.collect_uvars(t.args[i], acc) end
		M.collect_uvars(t.ret, acc)
	elseif t.tag == "union" then
		for i = 1, #t.xs do M.collect_uvars(t.xs[i], acc) end
	elseif t.tag == "intersection" then
		for i = 1, #t.parts do M.collect_uvars(t.parts[i], acc) end
	end
end

return M
