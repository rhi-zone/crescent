-- Match types — Phase 4d.
--
-- A match type `match X { P1 => R1 | P2 => R2 | ... | _ => Rn }` is a
-- type-level function from the lattice to itself (rewrite design §5). It is
-- defined piecewise over a **disjoint partition** of the lattice: the explicit
-- arm patterns P_1, ..., P_k are pairwise disjoint by construction, and the
-- wildcard `_` desugars to `~(P_1 ∪ ... ∪ P_k)` — the complement of the union
-- of the other arms' patterns.
--
-- The desugaring is real, not syntactic. `_`'s pattern is the v4 complement
-- type built by the same constructors used everywhere else; once constructed,
-- the wildcard arm participates in arm-matching via the same primitive as
-- every other arm. Nothing in this module special-cases the wildcard at the
-- subtype/emptiness level — its participation falls out of `~T` having a
-- working denotation in 4c.
--
-- ── Forward vs backward evaluation ───────────────────────────────────────
--
-- Forward (given subject X, compute result):
--   For each arm i, test `X <: P_i` (the arm fires) or `X ∩ P_i = ⊥` (it
--   doesn't). Disjointness guarantees at most one non-wildcard arm fires; the
--   wildcard fires iff every non-wildcard arm doesn't. Substitute capture
--   witnesses into the firing arm's result template.
--
-- Backward (given expected result R, constrain subject):
--   For each arm i, test whether R could be the arm's result R_i. The arms
--   whose result template is *compatible* with R contribute their pattern
--   P_i (or for the wildcard, ~union(P_i)) as a constraint on the subject.
--   Result is the union of those contributions.
--
-- Forward and backward use the **same arm-matching primitive**:
--   `M._arm_fires(test_type, pattern, solver)` → "fires" | "never" | "suspended"
-- — defined once and called from both directions. Forward passes
-- (subject, arm.pattern); backward passes (expected_result, arm.result).
--
-- ── Suspension ─────────────────────────────────────────────────────────────
--
-- If the subject has unbound type variables whose bounds do not yet decide
-- "fires" or "never" for at least one arm, evaluation **suspends**. Per the
-- design (§5.3), suspension parks the evaluation on a watchlist for those
-- variables; the general suspension mechanism is shared with deferred
-- indexed-access constraints (4b.2 also defers).
--
-- 4d does NOT implement the general suspension queue. Per CLAUDE.md's
-- "Ad-hoc conditions are strictly forbidden" rule, we will not bolt a
-- one-off pending-match queue on the side. The principled response — and the
-- one consistent with 4b.2's identical decision — is to **reject loudly** at
-- the evaluation site. The error message names the missing mechanism.
--
-- ── Captures ──────────────────────────────────────────────────────────────
--
-- A capture binds a structural fragment of the subject for use in the arm's
-- result. Surface syntax uses `%X` (rewrite design §5.2); at the type-API
-- level a capture is a fresh `V4Var` shared between the arm's pattern and
-- result. Threading the same var through both pattern and result makes
-- forward and backward evaluation symmetric: forward solves
-- `X <: P[%V := α]` for α, then returns `R[%V := α]`; backward solves
-- `R <: R[%V := α]` for α, then returns `P[%V := α]` as a subject
-- constraint. Same shape; only the substitution target swaps.
--
-- Each evaluation **freshens** the captures (creates new vars and substitutes
-- them into pattern and result) so that multiple invocations of the same
-- match type produce independent constraint graphs. The arm's stored capture
-- vars are templates, never solved against directly.
--
-- ── Disjointness check ────────────────────────────────────────────────────
--
-- At construction (`M.make(subject_placeholder, arms, wildcard_result)`), we
-- verify that each non-wildcard arm pattern is pairwise structurally disjoint
-- from every other non-wildcard arm pattern via the emptiness primitive:
-- `is_empty(P_i ∩ P_j)` must hold for all i ≠ j. Overlap is rejected with an
-- error. This IS the load-bearing principle — arms partition the subject's
-- universe; without disjointness, "the arm that fires" is undefined.
--
-- ── Indexed access on negated keys ────────────────────────────────────────
--
-- Match-type wildcards can desugar to `~(literal1 | literal2 | ...)` patterns
-- on string keys. Per design §1.1, `T[~"x"]` is admitted. 4d's forward
-- arm-matching does NOT route the subject through `index.lua` — it tests
-- `X <: P_i` directly, where `P_i` is a record pattern. The complement of the
-- pattern (the wildcard arm) participates as `~P_total` at the subtype level,
-- not as a negated key to `index`. So negated-key indexed access does not
-- actually arise inside 4d. We leave `index.lua` unchanged; if a future
-- caller constructs `T[~"x"]` directly, it would fall through index.lua's
-- existing key analysis and be rejected by analyze_key (which doesn't admit
-- `neg`). Adding the case is one-line work for a later phase that has a real
-- caller for it. See empty.lua's exceptions note (3).

local T = require("lib.type.static-v4.types")
local ST = require("lib.type.static-v4.subtype")
local E = require("lib.type.static-v4.empty")

local M = {}

-- ── Substitution ──────────────────────────────────────────────────────────
-- Pure substitution of variables by id. Used to freshen capture vars per
-- evaluation. Does NOT descend into μ (μ bodies are cyclic in the Lua-table
-- sense; substituting blindly would unfold them); capture vars in 4d are
-- declared by the caller as plain fresh `V.var()`s, and are never expected
-- to lie inside a μ. If a future API places a capture inside a μ, this
-- function will need a μ-aware variant — surface the case rather than
-- silently mishandle it.

local substitute --[[: (V4Type, { [integer]: V4Type }) -> V4Type ]]
--: (V4Type, { [integer]: V4Type }) -> V4Type
substitute = function(t, subst)
	if t.tag == "var" then
		local v = subst[t.id]
		if v ~= nil then return v end
		return t
	elseif t.tag == "top" or t.tag == "bot" or t.tag == "prim" or t.tag == "literal" then
		return t
	elseif t.tag == "fn" then
		local ps = {} --[[: V4Type[] ]]
		for _, p in ipairs(t.params) do ps[#ps + 1] = substitute(p, subst) end
		return T.fn(ps, substitute(t.ret, subst))
	elseif t.tag == "rec" then
		local fs = {} --[[: { [string]: V4Type } ]]
		for k, v in pairs(t.fields) do
			if v ~= nil then fs[k] = substitute(v, subst) end
		end
		local ix = t.indexer
		local new_ix = nil --[[: V4Indexer | nil ]]
		if ix ~= nil then
			new_ix = T.indexer(substitute(ix.key, subst), substitute(ix.value, subst))
		end
		return T.rec(fs, t.open, new_ix)
	elseif t.tag == "union" then
		local ms = {} --[[: V4Type[] ]]
		for _, m in ipairs(t.members) do ms[#ms + 1] = substitute(m, subst) end
		return T.union(ms)
	elseif t.tag == "inter" then
		local ms = {} --[[: V4Type[] ]]
		for _, m in ipairs(t.members) do ms[#ms + 1] = substitute(m, subst) end
		return T.inter(ms)
	elseif t.tag == "neg" then
		return T.neg(substitute(t.body, subst))
	else
		-- t.tag == "mu". μ bodies are cyclic Lua tables; treated as atoms for
		-- substitution. A capture inside a μ would require a deeper rewrite —
		-- not in 4d's scope. Returning the mu node verbatim is sound when no
		-- capture appears inside (the common case in 4d's tests).
		return t
	end
end

-- Detect whether a type expression references any *non-capture* type variable.
-- Captures (the pattern's freshened vars) are expected to receive bounds
-- during the firing probe, but any OTHER variable in either argument means we
-- cannot safely probe without mutating caller-visible state — the variable
-- could later be bound in a way that flips the outcome, and `constrain` would
-- have already widened the variable's bounds during the probe. The principled
-- response (mirroring `empty.lua`'s `pure_subtype` discipline) is to report
-- "suspended" rather than corrupt the variable graph.
--: (V4Type, { [integer]: boolean }) -> boolean
local function mentions_free_var(t, exclude)
	if t.tag == "var" then
		if exclude[t.id] then return false end
		return true
	elseif t.tag == "fn" then
		for _, p in ipairs(t.params) do
			if mentions_free_var(p, exclude) then return true end
		end
		return mentions_free_var(t.ret, exclude)
	elseif t.tag == "rec" then
		for _, v in pairs(t.fields) do
			if v ~= nil and mentions_free_var(v, exclude) then return true end
		end
		local ix = t.indexer
		if ix ~= nil then
			if mentions_free_var(ix.key, exclude) then return true end
			if mentions_free_var(ix.value, exclude) then return true end
		end
		return false
	elseif t.tag == "union" or t.tag == "inter" then
		for _, m in ipairs(t.members) do
			if mentions_free_var(m, exclude) then return true end
		end
		return false
	elseif t.tag == "neg" then
		return mentions_free_var(t.body, exclude)
	else
		-- top / bot / prim / literal / mu — no free var contribution. μ is
		-- opaque here (its body is read on demand by the solver via table
		-- identity, not by syntactic descent).
		return false
	end
end

-- ── Arm-matching primitive ────────────────────────────────────────────────
-- The single primitive shared by forward and backward evaluation. Given a
-- "test type" and a "pattern", decide one of three outcomes:
--   * fires    — test_type <: pattern, witnessed by a successful subtype.
--   * never    — test_type ∩ pattern = ⊥, witnessed by emptiness.
--   * suspended — neither holds (typically because the test_type or pattern
--                 mentions free type variables outside the allowed capture
--                 set).
--
-- The probe is *pure*: it refuses to mutate variables outside `allow_vars`
-- (the capture vars are listed there for the firing direction; backward
-- passes its own freshened captures). When the input mentions any other
-- variable we report "suspended" without running constrain at all — exactly
-- mirroring `empty.lua`'s `pure_subtype` discipline (which prevents
-- emptiness checks from corrupting variable bounds). A non-pure variant is
-- run separately by the caller on a real solver after the outcome is known
-- to be "fires" — see `forward`/`backward`.
--: (V4Type, V4Type, { [integer]: boolean }) -> string
local function arm_outcome(test_type, pattern, allow_vars)
	if mentions_free_var(test_type, allow_vars) or mentions_free_var(pattern, allow_vars) then
		return "suspended"
	end
	-- Both sides are variable-free (modulo allowed captures). The probes are
	-- safe to run because constrain will only mutate the allow_vars captures —
	-- which we own and don't care about here. Use isolated solver states; the
	-- bounds added live only on the fresh vars (if any).
	local s_fires = ST.new_solver()
	local ok = ST.constrain(s_fires, test_type, pattern)
	if ok then return "fires" end
	local s_never = ST.new_solver()
	if E.is_empty(T.inter({ test_type, pattern } --[[: V4Type[] ]]), s_never) then return "never" end
	return "suspended"
end

M._arm_outcome = arm_outcome

-- Build the allow-vars set for an arm: the set of capture variable ids that
-- `arm_outcome` is allowed to mutate during its probes. Captures are
-- pattern-and-result-only, so they don't appear in the subject — but the
-- pattern itself does, and we WANT capture bindings to flow when an arm fires.
--: (V4Type[]) -> { [integer]: boolean }
local function captures_set(captures)
	local s = {} --[[: { [integer]: boolean } ]]
	for _, c in ipairs(captures) do
		if c.tag == "var" then s[c.id] = true end
	end
	return s
end

-- ── Construction and forward evaluation ──────────────────────────────────
--
-- A match arm is a record { pattern, result, captures } where captures is the
-- list of capture variables (V4Var) shared between pattern and result. The
-- arms list is non-empty; the wildcard's result is passed separately because
-- the wildcard's pattern is synthesized as `~(union of other patterns)`.
--
-- Returns the v4 type of the match expression (the firing arm's result with
-- captures bound), or (nil, errmsg) on suspension / disjointness violation /
-- non-exhaustiveness.

-- V4Arm is declared in types.lua (alongside V4Type) so its cross-file
-- references resolve. See the comment there for the workaround rationale.

-- Build the wildcard pattern: ~(union of arm patterns). If there are no
-- non-wildcard arms, the wildcard pattern is ~⊥ = ⊤ — covers everything.
--: (V4Arm[]) -> V4Type
local function wildcard_pattern(arms)
	if #arms == 0 then return T.top() end
	local pats = {} --[[: V4Type[] ]]
	for _, a in ipairs(arms) do pats[#pats + 1] = a.pattern end
	if #pats == 1 then
		local first = pats[1]
		if first == nil then return T.top() end
		return T.neg(first)
	end
	return T.neg(T.union(pats))
end

-- Check that non-wildcard arm patterns are pairwise disjoint. The disjointness
-- check IS the load-bearing principle: without it, "the arm that fires" is
-- not well-defined and forward evaluation could fire two arms for the same
-- subject. Uses 4c's emptiness primitive.
--: (V4Arm[]) -> string | nil
local function check_disjointness(arms)
	local s = ST.new_solver()
	for i = 1, #arms do
		for j = i + 1, #arms do
			local ai, aj = arms[i], arms[j]
			if ai ~= nil and aj ~= nil then
				if not E.is_empty(T.inter({ ai.pattern, aj.pattern } --[[: V4Type[] ]]), s) then
					return "match arms " .. tostring(i) .. " and " .. tostring(j)
						.. " are not disjoint: " .. T.show(ai.pattern)
						.. " ∩ " .. T.show(aj.pattern) .. " is not provably empty"
				end
			end
		end
	end
	return nil
end

-- Freshen the capture vars of an arm: produce a substitution mapping each
-- capture var's id to a fresh `V.var()` whose name preserves the original
-- (for diagnostics). Returns (subst, fresh_captures).
--: (V4Arm) -> ({ [integer]: V4Type }, V4Type[])
local function freshen_captures(arm)
	local subst = {} --[[: { [integer]: V4Type } ]]
	local fresh = {} --[[: V4Type[] ]]
	for _, c in ipairs(arm.captures) do
		if c.tag == "var" then
			local nv = T.var(c.name) --[[: V4Type]]
			subst[c.id] = nv
			fresh[#fresh + 1] = nv
		end
	end
	return subst, fresh
end

-- Forward evaluation. Returns (result_type, nil) on a single firing arm, or
-- (nil, errmsg) if disjointness fails, suspension applies, or no arm covers
-- the subject (non-exhaustive — should be impossible with a wildcard, but we
-- check anyway).
--
-- **Distribution over union subjects (design §5):** if the subject is a union,
-- the match distributes member-wise — each member is matched independently
-- and the results are unioned. This is the lattice-theoretic answer:
-- `match (A ∪ B) { ... } = match A { ... } ∪ match B { ... }`. Without
-- distribution, a union subject would suspend (no single arm fires on the
-- whole union, no single arm's intersection with the whole union is empty);
-- with distribution, each member yields a definite result.
--: (V4Type, V4Arm[], V4Type | nil) -> (V4Type | nil, string | nil)
function M.forward(subject, arms, wildcard_result)
	local err = check_disjointness(arms)
	if err ~= nil then return nil, err end

	-- Distribute over a union subject (rewrite design §5: matches behave as
	-- piecewise functions; per-disjunct evaluation is the lattice answer).
	if subject.tag == "union" then
		local results = {} --[[: V4Type[] ]]
		for _, m in ipairs(subject.members) do
			local r, perr = M.forward(m, arms, wildcard_result)
			if r == nil then return nil, perr end
			results[#results + 1] = r --[[: V4Type]]
		end
		if #results == 1 then return results[1], nil end
		return T.union(results), nil
	end

	-- Test each non-wildcard arm.
	local fired_idx = nil --[[: integer | nil ]]
	local any_suspended = false
	for i, a in ipairs(arms) do
		local outcome = arm_outcome(subject, a.pattern, captures_set(a.captures))
		if outcome == "fires" then
			if fired_idx ~= nil then
				-- Two arms fire on the same subject. This contradicts the
				-- disjointness check above; if we land here it indicates an
				-- incompleteness in `is_empty` (a real overlap that emptiness
				-- failed to recognize). Surface loudly.
				return nil, "match: multiple arms fire on subject " .. T.show(subject)
					.. " (arms " .. tostring(fired_idx) .. " and " .. tostring(i)
					.. "); disjointness check incompleteness — please report"
			end
			fired_idx = i
		elseif outcome == "suspended" then
			any_suspended = true
		end
	end

	-- If exactly one non-wildcard arm fired and no other arm is suspended in a
	-- way that could also fire (disjointness rules out two firings, but a
	-- suspended arm whose fire-test is undecidable could in principle fire —
	-- the disjointness check guarantees it cannot if the firing arm definitely
	-- fires; the suspended ones cannot also fire). So a definite fire wins.
	if fired_idx ~= nil then
		local arm = arms[fired_idx]
		if arm == nil then
			return nil, "internal: fired_idx out of range"
		end
		local subst, _ = freshen_captures(arm)
		local fresh_pattern = substitute(arm.pattern, subst)
		local fresh_result = substitute(arm.result, subst)
		-- Run the subtype on a real (returned) solver so capture bounds are
		-- populated on the freshened vars. The caller observes the bound
		-- captures via the returned result type (which references them).
		local s = ST.new_solver()
		local ok = ST.constrain(s, subject, fresh_pattern)
		if not ok then
			-- Probe said "fires"; the real constrain disagrees. Indicates a
			-- bug in our isolated-probe machinery.
			return nil, "internal: arm fire probe and constrain disagree: "
				.. (s.error or "<no error>")
		end
		return fresh_result, nil
	end

	-- No non-wildcard arm fired. Check the wildcard.
	if wildcard_result ~= nil then
		local wpat = wildcard_pattern(arms)
		local outcome = arm_outcome(subject, wpat, {} --[[: { [integer]: boolean } ]])
		if outcome == "fires" then
			-- Wildcard has no captures — its result is the constant template.
			return wildcard_result, nil
		end
		if outcome == "suspended" or any_suspended then
			return nil, "match: subject " .. T.show(subject)
				.. " requires deferred evaluation (some arm tests are suspended);"
				.. " Phase 4d has no general suspension queue (CLAUDE.md"
				.. " no-temporary-measures). Materialize the subject further."
		end
		-- outcome == "never": subject is disjoint from the wildcard, meaning
		-- subject IS covered by some non-wildcard arm, but none of them
		-- fired in the loop. The only way this happens is if a non-wildcard
		-- arm was suspended (the union of arms' patterns covers the subject
		-- but no single arm definitively fires) — caught above by
		-- any_suspended. If we reach here without suspension the lattice
		-- accounting has gone wrong.
		return nil, "match: subject " .. T.show(subject)
			.. " is covered by the union of arms but no arm fires definitively"
	end

	-- No wildcard. If any arm is suspended, that's why no fire happened.
	if any_suspended then
		return nil, "match: subject " .. T.show(subject)
			.. " requires deferred evaluation (some arm tests are suspended);"
			.. " Phase 4d has no general suspension queue. Materialize the"
			.. " subject further."
	end
	-- Otherwise: subject is in none of the patterns and there is no wildcard.
	-- The match is non-exhaustive for this subject.
	return nil, "match: non-exhaustive — subject " .. T.show(subject)
		.. " matches no arm (and no wildcard provided)"
end

-- ── Backward evaluation ───────────────────────────────────────────────────
--
-- Given an expected result type R, compute the union of arm patterns whose
-- result template is compatible with R. This produces a constraint on the
-- subject. Uses the same `arm_outcome` primitive, with (test_type=R,
-- pattern=arm.result). The arms that could yield R contribute their pattern;
-- the wildcard, if compatible, contributes ~union(patterns).
--
-- "Compatible" here means the arm's result is not provably disjoint from R
-- (outcome ∈ {"fires", "suspended"}); a "never" outcome means the arm
-- cannot produce R and contributes nothing.

--: (V4Arm[], V4Type | nil, V4Type) -> (V4Type | nil, string | nil)
function M.backward(arms, wildcard_result, expected)
	local err = check_disjointness(arms)
	if err ~= nil then return nil, err end

	local contributing = {} --[[: V4Type[] ]]
	-- Track whether ALL arms are "never": then no subject value could produce
	-- the expected result, which is a real error to surface (the call is
	-- impossible).
	local any_possible = false
	for _, a in ipairs(arms) do
		-- Freshen captures so the backward probe doesn't mutate the arm's
		-- template vars (kept consistent with forward).
		local subst, _ = freshen_captures(a)
		local fresh_result = substitute(a.result, subst)
		local fresh_pattern = substitute(a.pattern, subst)
		-- Backward: capture vars appear in BOTH result (the probe target) and
		-- pattern (the contribution). The freshened captures are owned by this
		-- iteration, so they're in the allow-set.
		local allow = {} --[[: { [integer]: boolean } ]]
		for k in pairs(subst) do allow[k] = true end
		-- Also include the *fresh* var ids (the substitution mapped old → new).
		for _, nv in pairs(subst) do
			if nv.tag == "var" then allow[nv.id] = true end
		end
		local outcome = arm_outcome(expected, fresh_result, allow)
		if outcome ~= "never" then
			-- The arm could produce a subset of R. Contribute its pattern as a
			-- subject constraint. Note we also need the capture binding to
			-- flow: if expected <: fresh_result solves capture bounds, the
			-- contributed pattern (which references the same fresh captures)
			-- inherits them. Run the constrain on a real solver to populate.
			local s = ST.new_solver()
			-- We only run the binding direction when fires is the outcome —
			-- otherwise constraining a suspended arm could over-constrain.
			if outcome == "fires" then
				ST.constrain(s, expected, fresh_result)
			end
			contributing[#contributing + 1] = fresh_pattern
			any_possible = true
		end
	end

	if wildcard_result ~= nil then
		local outcome = arm_outcome(expected, wildcard_result, {} --[[: { [integer]: boolean } ]])
		if outcome ~= "never" then
			contributing[#contributing + 1] = wildcard_pattern(arms)
			any_possible = true
		end
	end

	if not any_possible then
		return nil, "match backward: no arm can produce result " .. T.show(expected)
	end
	if #contributing == 1 then return contributing[1], nil end
	return T.union(contributing), nil
end

-- ── Convenience: a match constructor that just runs forward ──────────────
-- The natural caller API. Forward is the default evaluation direction; users
-- wanting backward call `M.backward` explicitly.
--: (V4Type, V4Arm[], V4Type | nil) -> (V4Type | nil, string | nil)
function M.match(subject, arms, wildcard_result)
	return M.forward(subject, arms, wildcard_result)
end

-- Arm constructor — sugar that builds the record literal.
--: (V4Type, V4Type, V4Type[] | nil) -> V4Arm
function M.arm(pattern, result, captures)
	return { pattern = pattern, result = result, captures = captures or ({} --[[: V4Type[] ]]) }
end

return M
