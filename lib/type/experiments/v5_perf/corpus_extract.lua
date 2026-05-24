-- lib/type/experiments/v5_perf/corpus_extract.lua
-- Synthetic constraint extractor.  Greps a Lua source file for patterns
-- that a real gen pass would emit constraints for, and produces a list
-- of constraints approximating the gen-pass output.
--
-- NOT a real Lua parser — pattern-based heuristics only.  Goal: produce
-- ~500–2000 constraints per file that exercise the same scheduler shape
-- as a real run (mix of CEq from annotations, CTableOpen/Set/Seal from
-- module-table patterns, CMethodCall from method calls).

local types_mod      = require("lib.type.experiments.v5_perf.types")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")

local M = {}

--:: Allocator    = { n: integer, by_name: { [string]: integer } }
--:: ExtractResult = { constraints: V5Constraint[], tvar_counter: integer, file: string }

--: (Allocator) -> integer
local function alloc(a)
	a.n = a.n + 1
	return a.n
end

-- Lookup-or-allocate a tvar id keyed by name.  Cross-line/cross-constraint
-- name reuse is what produces real wake-up activity in the solver: two
-- CTableSet against the same name share a tvar root, so the second set
-- forces the first to react if it was inert.
--: (Allocator, string) -> integer
local function alloc_named(a, name)
	local existing = a.by_name[name]
	if existing ~= nil then return existing end
	a.n = a.n + 1
	a.by_name[name] = a.n
	return a.n
end

-- Convert a textual type annotation fragment into a synthetic V5Type.
-- Coarse: arrow on `->`, union on `|`, fresh tvar on `{`, else Const.
--: (string, Allocator) -> V5Type
local function annotation_to_type(s, a)
	if s:find("->", 1, true) then
		local lhs_, rhs_ = s:match("^(.-)%s*%->%s*(.*)$")
		local lhs = lhs_ or ""
		local _rhs = rhs_ or ""
		local args = {} --[[: V5Type[] ]]
		for _tok in lhs:gmatch("[%w_]+") do
			local u = types_mod.uvar(alloc(a)) --[[: V5Type ]]
			args[#args + 1] = u
		end
		local ret = types_mod.uvar(alloc(a)) --[[: V5Type ]]
		local rets = { ret }
		return types_mod.arrow(args, rets)
	end
	if s:find("|", 1, true) then
		local xs = {} --[[: V5Type[] ]]
		for part in (s .. "|"):gmatch("([^|]+)|") do
			local trim = part:match("^%s*(.-)%s*$")
			if trim ~= nil and trim ~= "" then
				local u = types_mod.uvar(alloc(a)) --[[: V5Type ]]
				xs[#xs + 1] = u
			end
		end
		if #xs >= 2 then return types_mod.union(xs) end
	end
	if s:find("{", 1, true) then
		return types_mod.uvar(alloc(a))
	end
	local nm = s:match("[%w_]+") or "const"
	return types_mod.const(nm)
end

-- Extract constraints from a single line of source.  Appends to `out`.
--: (string, integer, V5Constraint[], Allocator, string) -> nil
local function process_line(line, lineno, out, a, file)
	-- 1. `--: T -> U` style annotation.
	local sig = line:match("^%s*%-%-:%s*(.+)$")
	if sig ~= nil and not sig:match("^:") then
		local prov = constraint_mod.prov(file, lineno, "declared")
		local tv = types_mod.uvar(alloc(a)) --[[: V5Type ]]
		local sigty = annotation_to_type(sig, a) --[[: V5Type ]]
		local ce = constraint_mod.eq(tv, sigty, prov) --[[: V5Constraint ]]
		out[#out + 1] = ce
	end
	-- 2. `--:: Name = T | U | ...` ADT declaration.  CEq per variant.
	local adt = line:match("^%s*%-%-::%s*[%w_]+%s*=%s*(.+)$")
	if adt ~= nil then
		local prov = constraint_mod.prov(file, lineno, "declared")
		for variant in (adt .. "|"):gmatch("([^|]+)|") do
			local tv = types_mod.uvar(alloc(a)) --[[: V5Type ]]
			local vty = annotation_to_type(variant, a) --[[: V5Type ]]
			local ce = constraint_mod.eq(tv, vty, prov) --[[: V5Constraint ]]
			out[#out + 1] = ce
		end
	end
	-- 3. `local M = {}` start of a module: open the row.
	local mod_name = line:match("^%s*local%s+([%w_]+)%s*=%s*{%s*}%s*$")
	if mod_name ~= nil then
		local prov = constraint_mod.prov(file, lineno, "inferred")
		local tv = alloc_named(a, mod_name)
		local co = constraint_mod.table_open(tv, prov) --[[: V5Constraint ]]
		out[#out + 1] = co
	end
	-- 4. `X.field = ...` field assignment -> CTableSet on receiver's tvar.
	--    Receiver tvar pooled by name so all `M.x`, `M.y`, ... share root M.
	for recv, field in line:gmatch("([%w_]+)%.([%w_]+)%s*=") do
		local prov = constraint_mod.prov(file, lineno, "inferred")
		local recv_tv = alloc_named(a, recv)
		local val_tv  = types_mod.uvar(alloc(a)) --[[: V5Type ]]
		local cs = constraint_mod.table_set(recv_tv, field, val_tv, prov) --[[: V5Constraint ]]
		out[#out + 1] = cs
	end
	-- 5. `obj:method(...)` method calls -> CMethodCall on pooled receiver.
	--    Method-call constraints are the prime source of REACTIVATIONS:
	--    they go inert when the receiver is unbound, then wake when the
	--    receiver's table gains the named field.
	for recv, method in line:gmatch("([%w_]+):([%w_]+)%(") do
		local prov = constraint_mod.prov(file, lineno, "synthesized")
		local recv_tv = alloc_named(a, recv)
		local ret_tv  = alloc(a)
		local cm = constraint_mod.method_call(recv_tv, method, ret_tv, prov) --[[: V5Constraint ]]
		out[#out + 1] = cm
	end
	-- 6. `setmetatable(M, mt)` -> CTableSeal on M's pooled tvar.
	local seal_recv = line:match("setmetatable%s*%(%s*([%w_]+)%s*,")
	if seal_recv ~= nil then
		local prov = constraint_mod.prov(file, lineno, "declared")
		local tv = alloc_named(a, seal_recv)
		local cz = constraint_mod.table_seal(tv, nil, prov) --[[: V5Constraint ]]
		out[#out + 1] = cz
	end
	-- 7. `local x = expr` (with initializer) -> CEq between fresh lhs tvar
	--    and a fresh rhs tvar (we don't actually parse the RHS — synthetic).
	--    Captures the bulk of constraints in real Lua code.
	for name in line:gmatch("local%s+([%w_]+)%s*=") do
		local prov = constraint_mod.prov(file, lineno, "inferred")
		-- Pool the lhs tvar by name so subsequent method calls / field
		-- assignments on this local share the same root (forcing the
		-- solver to actually do union-find + wake-up work).
		local lhs = types_mod.uvar(alloc_named(a, name)) --[[: V5Type ]]
		local rhs = types_mod.uvar(alloc(a)) --[[: V5Type ]]
		local ce = constraint_mod.eq(lhs, rhs, prov) --[[: V5Constraint ]]
		out[#out + 1] = ce
	end
	-- 8. `function name(args)` or `local function name(args)` -> CEq per arg
	--    (treat each parameter as a fresh tvar equated to a param tvar).
	local fargs = line:match("function[^%(]*%(([^%)]*)%)")
	if fargs ~= nil and type(fargs) == "string" and fargs ~= "" then
		local prov = constraint_mod.prov(file, lineno, "declared")
		for arg in fargs:gmatch("[%w_]+") do
			local lhs = types_mod.uvar(alloc(a)) --[[: V5Type ]]
			local rhs = types_mod.uvar(alloc(a)) --[[: V5Type ]]
			local ce = constraint_mod.eq(lhs, rhs, prov) --[[: V5Constraint ]]
			out[#out + 1] = ce
			-- Suppress unused-arg warning
			local _ = arg
		end
	end
	-- 9. Function calls `f(...)` (not method calls) — emit a fresh CEq
	--    between the call's return tvar and a synthesized arrow result.
	for _fn in line:gmatch("([%w_]+)%(") do
		if _fn ~= "function" and _fn ~= "if" and _fn ~= "while" and _fn ~= "for" then
			local prov = constraint_mod.prov(file, lineno, "synthesized")
			local lhs = types_mod.uvar(alloc(a)) --[[: V5Type ]]
			local rhs = types_mod.uvar(alloc(a)) --[[: V5Type ]]
			local ce = constraint_mod.eq(lhs, rhs, prov) --[[: V5Constraint ]]
			out[#out + 1] = ce
		end
	end
end

-- Read all lines from file `file` via io.open; extract constraints.
-- `read_all` is injected for testing without filesystem (defaults to a
-- real file read via io.open).
--: (string, ((string) -> string) | nil) -> ExtractResult
function M.extract(file, read_all)
	local source --[[: string | nil ]]
	if read_all ~= nil then
		source = read_all(file)
	else
		local fh = io.open(file, "r")
		if fh == nil then error("corpus_extract: cannot open " .. file) end
		source = fh:read("*a")
		fh:close()
	end
	if source == nil then error("corpus_extract: empty read for " .. file) end
	local out = {} --[[: V5Constraint[] ]]
	local a = { n = 0, by_name = {} --[[: { [string]: integer } ]] } --[[: Allocator ]]
	local lineno = 0
	for line in source:gmatch("([^\n]*)\n?") do
		lineno = lineno + 1
		process_line(line, lineno, out, a, file)
	end
	return { constraints = out, tvar_counter = a.n, file = file }
end

return M
