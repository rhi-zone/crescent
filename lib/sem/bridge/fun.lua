-- lib/sem/bridge/fun.lua
-- REALITY BRIDGE — model `VFun` (finite I/O graph) ↔ a REAL LuaJIT function,
-- and model arrow membership `denote (BArrow A B) (VFun g)` ↔ the real-computed
-- arrow verdict. Resolves fork (B) of docs/reality-bridge.md. See that doc.
--
-- THE CORRECTED INSIGHT. The proof's `VFun : list (V*V) -> V` is an EXTENSIONAL
-- FINITE I/O GRAPH — a known, listed set of (input, output) pairs. It is NOT an
-- opaque closure. So a function value IS bridgeable: we CONSTRUCT a real Lua
-- function FROM the graph (an if/elif dispatch comparing the bound input against
-- the real images of i1, i2, …, returning the matching real image of o), and
-- then check real Lua's function-call semantics agrees with the model's
-- graph-lookup denotation. (Only an arbitrary externally-given opaque closure —
-- whose graph is unknown — is unbridgeable; the model NEVER yields such a value.)
--
-- TWO VALIDATION LEGS (both in fun_test.lua):
--   (operational) application = graph lookup. For each (i,o) in the graph, assert
--     `real_f(real_image(i)) == real_image(o)` in real LuaJIT. This validates
--     that real Lua's call semantics matches the model's graph-lookup denotation
--     — the core "input→output is enough" check.
--   (membership) arrow type verdict. The model says `VFun g ∈ (A→B)` iff
--     `∀(i,o)∈g, i∈A → o∈B`. We compute the MODEL verdict (a port of `denote_dec`
--     on the finite graph) and the REAL-computed verdict (for each (i,o)∈g, use
--     the real-Lua atom oracles from lib/sem/bridge/atom.lua: `real(i)∈A` implies
--     `real(o)∈B`), and assert they AGREE.
--
-- SCOPE (honest): SCALAR graph entries only — inputs and outputs are number /
-- string / bool / nil atoms (reuses the atom bridge's value renderer + real atom
-- predicates). DEFERRED (recorded in TODO.md proof-dev backlog): higher-order
-- (functions appearing IN a graph), and table-valued graph entries.

local atom = require("lib.sem.bridge.atom")

--:: require "lib.sem.bridge.atom"

local M = {}

-- ── the scalar atoms an arrow's domain/codomain may range over ───────────────
-- The arrow-bridge restricts A and B in `BArrow A B` to the SCALAR atoms (the
-- atoms the atom bridge already bridges). Higher-order and table arrows defer.
--:: ArrowAtom = "AStr" | "ABool" | "ANil" | "ANum" | "AInt" | "AFloat"
M.arrow_atoms = { "AStr", "ABool", "ANil", "ANum", "AInt", "AFloat" } --[[: ArrowAtom[] ]]

-- ── scalar model values (reuse the atom bridge's value constructors) ─────────
-- A graph entry is a pair of SCALAR ModelValues. We reuse atom.lua's renderer
-- (`value_to_lua_expr`) and atom membership port (`model_denote_atom`).
--:: ScalarValue = ModelValue
--:: GraphPair   = { i: ScalarValue, o: ScalarValue }
--:: Graph       = GraphPair[]

-- A model function value: the VFun head carrying a finite scalar I/O graph.
--:: MVFunGraph = { head: "VFunGraph", graph: Graph }

--: (Graph) -> MVFunGraph
function M.vfun_graph(graph) return { head = "VFunGraph", graph = graph } end

-- ── value equality predicate for the real dispatch ───────────────────────────
-- The real Lua function built from a graph dispatches by comparing the call
-- argument against each graph input's REAL IMAGE. Scalar values compare with `==`
-- in real Lua (number/string/bool/nil all have value `==`). nil needs care: a
-- function argument that is nil compares `== nil` fine. So `==` is the correct
-- and faithful dispatch comparison for the scalar fragment.

-- ── model `VFun graph` → real Lua function SOURCE ────────────────────────────
-- Emit the SOURCE of a real Lua function realizing exactly `graph`: an if/elif
-- chain over the graph inputs (compared by `==` against each input's real image),
-- returning the matching output's real image. A call whose argument matches no
-- listed input falls through to `error(...)` (outside the known graph — the model
-- says nothing there; the operational leg never probes such inputs). The function
-- is emitted as an EXPRESSION (a `function(x) ... end` literal) so a caller can
-- bind it or apply it inline.
--: (Graph) -> string
function M.graph_to_lua_function_expr(graph)
	local lines = {} --[[: { [integer]: string } ]]
	lines[#lines + 1] = "function(x)"
	for k = 1, #graph do
		local pair = graph[k]
		local in_expr  = atom.value_to_lua_expr(pair.i) --[[: string]]
		local out_expr = atom.value_to_lua_expr(pair.o) --[[: string]]
		-- Compare the argument against this input's real image; on match, return
		-- this output's real image. `==` is value equality for scalars.
		lines[#lines + 1] = "  if x == (" .. in_expr .. ") then return (" .. out_expr .. ") end"
	end
	-- Out-of-graph application: the model graph is the FULL extension, so any
	-- argument not listed is outside the function's defined domain.
	lines[#lines + 1] = "  error('crbridge: argument outside graph domain')"
	lines[#lines + 1] = "end"
	return table.concat(lines, "\n")
end

-- ── model arrow membership verdict (a port of `denote_dec (BArrow A B) (VFun g)`)
-- The proof's BArrow denotation: `VFun g ∈ BArrow A B` iff for EVERY (i,o) in g,
-- `denote A i -> denote B o`. We port that exactly, atom-by-atom, over the finite
-- graph: for each pair, if the input is in A (per the atom port) then the output
-- must be in B; if the input is NOT in A the conjunct is vacuously satisfied.
-- This mirrors proof/subtype.v `denote_dec`'s BArrow case (the per-pair decidable
-- implication, folded with conjunction over the finite graph).
--: (ArrowAtom, ArrowAtom, MVFunGraph) -> boolean
function M.model_arrow_verdict(a_dom, a_cod, vfun)
	local g = vfun.graph
	for k = 1, #g do
		local pair = g[k]
		local in_A = atom.model_denote_atom(a_dom, pair.i)
		if in_A then
			local out_B = atom.model_denote_atom(a_cod, pair.o)
			if not out_B then
				return false -- a witness: input in A whose output is NOT in B
			end
		end
	end
	return true
end

-- ── per-pair REAL arrow predicate (for the real-computed verdict) ────────────
-- The membership leg's REAL side. For a single graph pair (i,o), the real-Lua
-- reading of the arrow conjunct `denote A i -> denote B o` is: "if i's real image
-- is in A (per the atom REAL predicate) then o's real image is in B". We emit a
-- Lua boolean EXPRESSION over two bound names `xi` (the real input image) and
-- `xo` (the real output image) computing exactly that implication.
--: (ArrowAtom, ArrowAtom) -> string
function M.pair_real_implication_expr(a_dom, a_cod)
	-- atom.atom_real_predicate is written over a bound name `x`; rebind it per side
	-- by substituting the variable. The predicates reference only `x` (and globals
	-- type/math), so a textual rebinding to xi/xo is sound.
	local dom_pred = atom.atom_real_predicate(a_dom) --[[: string]]
	local cod_pred = atom.atom_real_predicate(a_cod) --[[: string]]
	local dom_xi = (dom_pred:gsub("%f[%w]x%f[%W]", "xi"))
	local cod_xo = (cod_pred:gsub("%f[%w]x%f[%W]", "xo"))
	-- implication `p -> q` is `(not p) or q`.
	return "((not (" .. dom_xi .. ")) or (" .. cod_xo .. "))"
end

return M
