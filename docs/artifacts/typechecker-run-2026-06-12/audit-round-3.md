# Adversarial audit round 3 — slice v2 increments 3 & 4

**Target.** Commits `381abe3d` (increment 3: operator typing, assignment forms,
method calls, stdlib cap, unannotated functions) and `aa5ece64` (increment 4: globals
model, module-value-type synthesis, check-mode closure typing, the memoized
module-type cache). Primary files: `lib/type/analysis/crescent_slice_lower.lua`,
plus `synth_binop`/`synth_unop`/`binop_result`/`unop_result` in
`lib/type/analysis/crescent_slice.lua`.

**Method.** Execution-led per §9.7/§9.11 (rounds 1–2). Every claim below was produced
by lowering a hostile source through `crescent_slice_lower.lower`, running it through
the substrate `A.check`, and reading the verdict / requested-claim outcome / markers.
Driver: a scratch `run(entry, modules, with_stdlib)` harness (the corpus-test seam) in
`/tmp`. LuaJIT numeric semantics were verified by RUNNING the vendored LuaJIT, not by
trusting the doc. Nothing was fixed; this is a report.

**Baseline.** Full analysis suite green at 6328 assertions (`bin/cr test
lib/type/analysis/`) before and after the audit — no source touched.

**Severity scale** (round-1 vocabulary): `unsound` (over-acceptance / false-negative —
the top severity under the project's "wider, never unsound" posture) > `hardening` /
`precision` (over-rejection / false-positive — sound but imprecise) > `doc defect`.

---

## Findings

### F1 [unsound — NOT fixed]: module-table reassignment is ignored; the synthesized module value type is stale

**Repro.** Exporting module `lib/re.lua`:

```lua
local M = {}
--: (integer) -> integer
function M.f(x) return x + 1 end
M = {}            -- M rebound to a FRESH empty table
return M
```

Entry:

```lua
--: () -> integer
local function run()
  local lib = require("lib.re")
  return lib.f(1)   -- f does not exist on the runtime export
end
return { run = run }
```

**Observed.** `VERDICT=CLEAN req=3 acc=3 rej=0 unk=0 diags=0`. The cross-module
`lib.f(1)` checks clean.

**Why it is wrong.** At runtime the module returns the *empty* table (`M = {}`
clobbered the accumulated table), so `lib.f` is `nil` and `lib.f(1)` is a
call-on-nil error. The synthesized module value type still carries `f` because the
accumulation never honored the reassignment.

**Stronger variant (reassignment to a DIFFERENT table).** `lib/re2.lua`:

```lua
local M = {}
--: (integer) -> integer
function M.f(x) return x + 1 end
--: { g: integer }
local N = { g = 5 }
M = N             -- exported value now has g, not f
return M
```

Same entry → `VERDICT=CLEAN`. The runtime export has `g`, not `f`; the consumer's
`lib.f(1)` is accepted against a phantom field. Control (`M` never gains `f`) correctly
yields `OUT-OF-SUBSET / no-such-field:f`, isolating the accumulation as the cause.

**Root cause** (`crescent_slice_lower.lua`). A plain name target assignment
`M = <expr>` is handled flow-insensitively at lines 2150–2153:

```lua
elseif tgt and tgt.k == "name" then
    -- reassigning a local: v1 is flow-insensitive; just request the value.
    lc.requested[#lc.requested + 1] = vcid
    return
```

It requests the value claim but does NOT rebind `M` in the `SliceCtx`. The
shadowing rec accumulated by `function M.f` / `M.f = …` (via `ctx_set_field`, line
939, which appends a most-recent-wins shadow entry) therefore remains the active
binding for the name `M`. When the top-level `return M` synthesizes `M`'s type
(`synth_var`, captured into `module_ret_ty` at line 1975), it reads the stale
accumulated rec including `f`. The reassignment value (`{}` / `N`) is synthesized and
its claim requested, but its TYPE never replaces the `M` binding.

**Blast radius.** This is the module-VALUE-type path landed in increment 4, so the
phantom field propagates across the `require` boundary into every consumer
(`compute_module_types` → portable PTy → `resolve_module_type` at the call site). A
consumer trusting the phantom field emits a clean call claim for a runtime nil-call.
Within `lib/`, the `local M = {} … return M` convention without reassignment is the
norm, so the reachable surface is modules that reassign the module-table local after
accumulating fields — uncommon but not exotic (e.g. `M = setmetatable(M, …)` is
expressed as `return setmetatable(M, …)` and is OUT-OF-SUBSET, see F3-adjacent, but a
bare `M = expr` rebind is in-grammar and silently mis-typed).

**Fix direction (do not apply — recorded as the substrate need).** The name-target
assignment path must rebind `M` in the ctx to the synthesized type of the RHS (the
same shadow-entry mechanism `ctx_set_field` already uses), so a later `return M` reads
the post-reassignment type. The principled framing: *flow-insensitive name
reassignment must still update the name→type binding for the module-return capture;
the current path updates the claim stream but not the environment.* It is not a
result deficit ("re.lua produces the wrong field set") but a substrate gap in the
assignment lowering's environment maintenance. Care: rebinding to a synthesized rec is
straightforward; rebinding to a non-rec (e.g. `M = some_call()`) should make the
module type the RHS type or fall to `unknown`, never retain the stale rec.

---

### F2 [precision / false-positive — NOT fixed]: a closure with FEWER params than the expected fn type is over-rejected

**Repro.**

```lua
--: ((integer, integer) -> nil) -> nil
local function apply(f) return nil end
--: () -> nil
local function main()
  return apply(function(a) return nil end)   -- 1-param closure into a 2-param slot
end
return { main = main }
```

**Observed.** `VERDICT=FINDINGS … MARKERS: type-mismatch {value not a subtype of
expected}`. The 1-param closure is rejected against the 2-param callback slot.

**Why it is wrong (imprecise, not unsound).** Passing a 1-param function where a
2-param callback is expected is valid Lua — extra arguments are discarded. Confirmed by
running LuaJIT: `apply(function(a) return a end)` with `apply` calling `f(1, 2)` runs and
returns `1`. The slice rejects valid code; it never accepts bad code, so this is
over-rejection (precision), not an unsoundness.

**Root cause.** `check_func_expr` (line 1712) explicitly documents and permits the
fewer-params case ("the closure may declare FEWER params than expected … Lua ignores
extra arguments", lines 1718–1720) and builds the closure's fn type from its OWN param
count — `(integer) -> nil`. But `check_expr` (line 1738) then wraps that synthesized
type in `emit_check_against(scid, sref, sty=(integer)->nil, want=(integer,integer)->nil)`
(line 1754). The subtype relation `(integer) -> nil <: (integer, integer) -> nil` is
false under standard function-width rules (a 1-arg function is not safely callable with
2 args in a strict checker), so the wrapper rejects what `check_func_expr` intended to
accept. The doc (§6.8.3, line 1822) states "the closure's value type is the expected fn
type exactly" — but `build_closure` sets it to the closure's own arity, contradicting
the spec; the wrapper then enforces the contradiction.

**Note.** The exact-arity (`cl1_exact`) and zero-expected (`cl1_zero`) cases are CLEAN;
only the fewer-than-expected case mis-fires. The MORE-params case is correctly rejected
with its own dedicated marker (`closure expects more params than the annotated type
supplies`, line 1722).

**Fix direction.** Either (a) make `check_func_expr` set the closure's value type to
`want` exactly (as the spec states), so the wrapper's `subtype(want, want)` holds
trivially; or (b) have `check_expr` skip the post-subtype wrap when it took the
check-mode closure branch (the check-mode body-return premises already establish the
claim). Recorded as a spec/impl divergence in the check-mode closure machinery.

---

### F3 [precision / false-negative-of-precision — NOT fixed]: module type does not track table aliasing or conditional/wrapped exports

These are three reproduced cases of the same class: the module-value-type accumulation
keys on the *object name* and only fires for the `local M = {} … function M.f … return
M` shape. Each below is sound (it under-populates the module type, yielding
OUT-OF-SUBSET / no-such-field rather than a false accept), so they are precision gaps,
not unsoundness — but they are recorded because they bound what the §10.4 tail actually
covers.

- **Aliased module table** (`mv1`): `local M = {}; local A = M; function A.f(x) …;
  return M` → `lib.f` is `no-such-field:f` (OUT-OF-SUBSET). `A.f` accumulates onto the
  name `A`, and `return M` reads `M`'s (empty) rec. Sound (rejects), imprecise.
- **Conditional export** (`mv2`): `if flag then function M.f(x) … end` → `no-such-field:f`.
  The accumulation happens inside the `if` body's ctx and does not survive to the
  top-level `M` binding. Sound, imprecise.
- **Wrapped return** (`mv4`): `return setmetatable(M, {})` → `no-such-field:f`. The
  module return is the `setmetatable(…)` call result (declared `(unknown,unknown) ->
  unknown`, §9.13), so the module value type is `unknown`-ish and `f` is not found.
  Sound (consumer must narrow `unknown`), imprecise — and notably this is the form a
  reassigning module SHOULD take, which is why F1's `M = expr` rebind (in-grammar) is
  the dangerous sibling while `return setmetatable(M,…)` degrades safely.

**Note on the asymmetry with F1.** F3's wrapped/aliased forms degrade to
OUT-OF-SUBSET or `unknown` (safe); F1's bare `M = expr` rebind retains the stale rec
(unsafe). The same accumulation machinery is safe when the export is *wrapped or
re-aliased* and unsafe when the module-table *name is rebound* — because only the
rebind path leaves a stale name→rec binding live for `return M` to read.

---

## Survivals (attacks that found nothing — evidence too)

### Operators (§6.7.1) — all sound

LuaJIT 5.1 numeric semantics verified by running the vendored binary (no `math.type` in
5.1; all numbers are doubles at runtime — the slice's `integer`/`number` split is a
static value-class abstraction).

- `^` and `/` on integer operands → `number`: assigning `2 ^ 2` or `6 / 3` to an
  `integer` return slot is correctly REJECTED. (LuaJIT `2^2` is the double `4`; the
  static `number` class is honest.)
- `+ - * %` integer iff both operands integer: `1 + 2.5` → number, rejected against an
  `integer` slot; `(-5) % 3` → integer (verified `(-5)%3==1`, `5%(-3)==-1`, both
  integer-valued for integer operands), accepted. Mixed and number cases reject
  correctly.
- Operator chains propagate the class: `(2 ^ 2) % 2` → number (the `^` taints the
  chain), rejected against `integer`; `(1 + 1) * 2` → integer, accepted.
- `..` → string regardless of int/number operands; `1 .. 2` rejected against `integer`,
  accepted against `string`.
- `#` on string and on any table → integer (sound: even `#{x=1}` is an integer at
  runtime, value 0; the static `integer` result holds). `#` on a field-only rec is
  CLEAN (imprecise on the *value* but type-sound).
- Comparisons `< <= > >=` only over num/num or str/str; `"a" < 3` defers as
  `operator-metamethod-compare` (out-of-core), never a boolean type-claim. Equality
  `== ~=` is total boolean over disjoint operands (metatable-blind), `"a" == 3` CLEAN.
- Unary `-` preserves the class: `-2.5` → number, rejected against `integer`.

No tag was swallowed in any chain; no operator produced a type-error claim where the
fence requires a deferral.

### Stdlib declaration soundness (§9.13) — all sound-loose, no nil flow-through

Every §9.13 approximation declares the result `unknown` (or `T | nil`) where the true
type would refine, forcing the caller to narrow. Probed each for a nil/loose flow-through
into a concrete slot:

- `assert(x)` declared `(unknown, …unknown) -> unknown` (loses the `T -> T` identity):
  `assert(x)` used directly as `integer` is REJECTED (no identity refinement to exploit;
  the loose return forces narrowing). No nil flows through.
- `select("#")` / `select(2, …)` declared `(unknown, …unknown) -> unknown`: result used
  as `integer` rejected.
- `next(t)`, `rawget(t, k)`, `setmetatable({}, {})`, `pcall(…)`'s 2nd return — each
  `unknown`, each rejected when used as a concrete type unguarded.
- `tonumber("3")` declared `(unknown, …integer) -> number | nil`: used as `number`
  unguarded → REJECTED (the `| nil` is honored). `type(3)` → `string` (precise) → CLEAN.
- `error` declared `(unknown, …integer) -> never`, `os.exit` → `never`: control-flow
  soundness preserved (no return). `math.floor/ceil` → `integer` is sound under the
  static value-class abstraction (the result is integer-valued).

Reviewed every entry in `default_stdlib()` (lines 2290–2410) for an OVER-tight (unsound)
declaration: none found. Every approximation is wider-or-equal to the true type. Arg-side
declarations (`pcall` requires a `func` first arg, etc.) are sound requirements.

### Module-type cache & cycles (§6.8.2, the 95× fix) — no poisoning, no staleness

- **Per-entry cache, no cross-entry poisoning.** The shared PTy cache (`_mod_cache`,
  line 2449) is created fresh in each top-level `compute_module_types`; it is threaded
  only DOWN the recursion of one entry. Two `M.lower` calls in one process with a CHANGED
  module body (same path) produce different results — `lower1` sees field `f`, `lower2`
  (module now exports `g`) correctly reports `no-such-field:f`. No stale serve.
- **No stdlib-cap variance.** Cache key is path-only, but `opts.stdlib` is constant
  within a single recursion (`sub_opts.stdlib = opts.stdlib`, line 2477) and the cache
  lifetime is one recursion; no two entries with different caps share a cache instance.
- **Cycles resolve to `unknown` and are NOT cached.** A require cycle (`visited[tmod]`,
  line 2460) yields `out[tmod] = unknown` but does NOT write `cache[tmod]` (only concrete
  `mrt ~= nil` results are cached, lines 2485–2488), so no half-built type is memoized.
  Verified: in a real `a ⇆ b` cycle, `b.NONEXISTENT(x)` inside `a` is CLEAN (the cyclic
  import is `unknown`, honest and terminating); the entry's use of `a.f` against `a`'s
  declared sig still checks. Diamond (`entry → a,c → shared`) resolves the shared module
  once and correctly. The depth-6 cap (line 2443) bounds deep chains.

### Check-mode closures — the rest held

- **Direct-arg check-mode works**: a closure passed DIRECTLY into an annotated fn slot
  pushes param types inward; the SAME closure expression passed directly into TWO
  differently-annotated slots (`(integer)->nil` and `(string)->nil`) is CLEAN for both
  (`cl5b`). No first-use poisoning — the claim is keyed per-use (content-addressed), not
  per-closure-expression.
- **Closure via a `local` binding is NOT check-mode** (synth `(unknown)->unknown`), so
  `local c = function(a) … end; ai(c)` rejects against `(integer)->nil` because
  `unknown` return is not `<: nil`. Sound (over-reject); a documented precision boundary
  (check-mode reaches only direct annotated slots, not through an intervening `local`).
  This is not new to round 3.
- **Closure into `unknown`-typed slot**: CLEAN (`(unknown) -> nil` slot is not an `fn`
  kind, so synth + `subtype(synth, unknown)` holds). Sound.
- **Union-of-fn expected slot**: routes through SYNTH (the union is not `fn` kind), so
  `(unknown)->unknown` is rejected against the union — sound over-reject, precision
  deferral (check-mode doesn't distribute over a union slot).
- **Nested closure** (callback returning callback) and **MORE-params** rejection both
  behave (the more-params case fires its dedicated marker, not a crash).
- **Recursion through a closure**: the increment-3 local-function self-bind fix held
  (`local function loop(n) … loop(nil) … end` is CLEAN; the name binds in its own body).

### Round-1 / round-2 regression spot-checks — all held

- **Round-2 collision detection through the require path**: two required modules both
  exporting alias `T` with DIFFERENT bodies still fire `xmodule-alias-error … collision:
  name 'T' already imported from 'lib.p' … incompatible type (tid mismatch)`. The
  module-VALUE-type path is orthogonal to the alias-import path; the F1 (round-2)
  collision logic in `import_top_level_aliases` is untouched and active.
- **Two modules exporting the SAME field name `f`** (NOT a collision): `p.f` and `q.f`
  both usable, CLEAN — no false collision across the value-type path.
- **Round-1 well-formedness gate on synthesized M-table recs**: a module with a
  duplicated `function M.f` (most-recent-wins) produces a well-formed rec the substrate
  accepts cleanly (the second sig wins; passing the first sig's arg type is correctly
  rejected). A module exporting a recursive-alias-typed field (`--:: Node = { next: Node
  | nil }`, `M.make() -> Node`) crosses the boundary CLEAN — the μ type is well-formed
  through the new path.
- **Round-1 fixes** (lit_int integer validation, `unknown` narrowing, subtype DAG
  memoization, well-formedness as a hard `declare_alias` precondition) and **round-2
  fixes** (path-segment validation, digest records, mutual-alias retraction) showed no
  regression on the new operator / closure / module-value paths.

---

## Summary

| # | Severity | Status | One line |
|---|---|---|---|
| F1 | unsound | not fixed | module-table reassignment (`M = expr`) ignored → stale module value type crosses the require boundary as a phantom field |
| F2 | precision | not fixed | fewer-param closure into a wider fn slot over-rejected (check-mode builds the wrong arity, the wrapper rejects it) |
| F3 | precision | not fixed | module type misses aliased / conditional / wrapped exports (under-populates → OUT-OF-SUBSET; safe) |

**Worst finding:** F1. A module that accumulates fields and then rebinds its module-table
local (`M = {}` / `M = N`) before `return M` exports a value type that still carries the
pre-rebind fields; because this is the increment-4 module-VALUE-type path, the phantom
field is trusted across `require` and a consumer's `lib.f(…)` is accepted for a runtime
nil-call.

**Rounds 1–2 fixes:** held. Operator typing, stdlib approximations, the module-type
cache (no poisoning, no staleness, honest cycles), round-2 collision detection through
the new require path, and round-1 well-formedness on synthesized recs all survived the
attacks. One unsound finding (F1) and two precision findings (F2, F3) are new to the
increment-3/4 surfaces; none regress a prior fix.

Full analysis suite green (6328 assertions) throughout — no source modified.
