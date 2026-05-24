-- lib/type/experiments/v5_perf/variance.lua
-- Declaration-site variance for v5 type constructors.
--
-- Per H4 (HKT picks): each declared type constructor carries a list of
-- variance markers, one per parameter position.  Markers:
--   "co"     - covariant     ( if A <: B  then  F<A> <: F<B> )
--   "contra" - contravariant ( if A <: B  then  F<B> <: F<A> )
--   "inv"    - invariant     ( F<A> <: F<B>  iff  A = B    )
--
-- Storage: a module-level registry keyed by Const name.  Constructors not
-- in the registry default to **invariant** at every position — the sound
-- default per Algebraic Subtyping §3 / TypeScript-array unsoundness
-- discussion (round-1 research report).  Variance must be DECLARED, never
-- inferred from use.
--
-- Arrow variance is FIXED (not in the registry): contravariant in each
-- argument, covariant in each return — see T-CSub-Arrow.
--
-- This module is a sidecar to types.lua: Type AST is untouched (Const
-- still tag/name); variance lives here.  Rationale: variance is a property
-- of the named declaration, not of each occurrence.

local M = {}

-- Variance markers: "co" | "contra" | "inv".
--:: Variance         = string
--:: VarianceList     = { [integer]: Variance }
--:: VarianceRegistry = { [string]: VarianceList }

local _registry = {} --[[: VarianceRegistry ]]

-- Declare a type constructor's per-parameter variance.  Repeated declarations
-- of the same name must agree (any disagreement is a programmer error and
-- silently overwrites — the last declaration wins, on the bet that test
-- isolation handles fixture interference).
--: (string, VarianceList) -> nil
function M.declare(name, vs)
	_registry[name] = vs
end

-- Look up declared variance.  Returns nil if undeclared (caller must treat
-- nil as "invariant at every position").
--: (string) -> VarianceList | nil
function M.lookup(name)
	return _registry[name]
end

-- Variance at position i for a named constructor.  Defaults to "inv".
--: (string, integer) -> Variance
function M.at(name, i)
	local vs = _registry[name]
	if vs == nil then return "inv" end
	local v = vs[i]
	if v == nil then return "inv" end
	return v
end

-- Reset the registry (per-test isolation).
--: () -> nil
function M.reset()
	_registry = {} --[[: VarianceRegistry ]]
end

-- Flip a variance marker (used when descending into a contravariant position).
--: (Variance) -> Variance
function M.flip(v)
	if v == "co" then return "contra" end
	if v == "contra" then return "co" end
	return "inv"
end

return M
