# v10 kernel differential adjudication: `v10_kernel` vs `v10_cleanroom`

Status: adjudication report, executed 2026-07-29. Compares:

- **A** = `lib/type/v10_kernel/term_algebra/reference.lua` (reference tier
  only — `fast.lua` excluded per task scope) + `lib/type/v10_kernel/replayer/`.
- **B** = `lib/type/v10_cleanroom/term_algebra.lua` +
  `lib/type/v10_cleanroom/replayer.lua`.

Authority: `docs/decisions/typechecker-v10-core-design.md`, in particular the
"Spec adjudications — cleanroom findings F1–F13" section. B was built to
conform to these rulings; A predates them and resolved the same questions
silently. All findings below are judged against the F1–F13 text, not against
either implementation's own comments.

All repros were executed with the vendored LuaJIT (`bin/luajit`) against a
throwaway harness in `/tmp/v10_parity/` (adapters + probe scripts + a seeded
differential fuzzer). The harness is scratch — not committed, per the task
brief — but every result below is a real, reproduced execution, not a
read-through inference. Neither `lib/type/v10_kernel/` nor
`lib/type/v10_cleanroom/` was modified.

---

## Divergences found

### 1. F4 — shift underflow check uses the wrong bound (A-bug, confirmed)

**Ruling (F4):** "shift with negative amounts allowed; index underflow
(below cutoff) is a data error."

**A's bug:** `reference.lua`'s `M.shift`, var case, computes `new_index =
t.index + d` and rejects only when `new_index < 0` — not when `new_index <
cutoff`. Any negative shift landing strictly between 0 and cutoff is wrongly
accepted, silently producing a term whose index no longer denotes the
variable it should.

**Repro:**
```lua
local v = k.build_var(5, sig.sorts.tm)
k.shift(v, -3, 3)   -- index 5 >= cutoff 3, new_index = 2, which is 0 <= 2 < cutoff(3)
```
- **A:** returns `var(2, tm)` with no error — wrong; per F4 this is
  underflow, a data error.
- **B:** returns `nil, "shift: underflow — index 5 shifted by -3 falls
  below cutoff 3"` — correct.

**Fuzz confirmation:** 5000 random `shift`/`subst` cases (seed 999001,
depth-4 terms, `d ∈ [-4,4]`, `cutoff ∈ [0,3]`) reproduce this exact
divergence 360 times (7.2%) — every recorded divergence in that run is this
same bug, none any other shape. A never rejects; B always rejects correctly
per F4's stated boundary.

**Classification: A-bug.** Cites F4 verbatim ("index underflow (below
cutoff)").

---

### 2. F7 — no metavariable-in-subject check in A at all (A-bug, confirmed, serious)

**Ruling (F7):** "match subject containing metavariables is a data error,
distinct from ordinary no-match."

**A's bug:** `reference.lua` has no `.metas`/meta-occurrence cache on any
node at all, and `match_at` never checks whether the subject contains a
metavariable. Worse: when the pattern itself is `meta` at the exact position
where the subject holds a metavariable, `match_at`'s `meta` branch just
binds it directly — no rejection, no error, a metavariable ends up bound
into the output bindings.

**Repro:**
```lua
local subject = k.build(sig.ops.f, { k.build_meta("M", sig.sorts.tm) })  -- f(M)
local pattern = k.build(sig.ops.f, { k.build_meta("P", sig.sorts.tm) })  -- f(P)
k.match(pattern, subject)
```
- **A:** succeeds, `P` is bound to `meta(M, tm)` — a metavariable-containing
  binding silently accepted.
- **B:** `nil, "match: subject term contains a metavariable"` — a data
  error, and `ta.is_no_match(err)` is `false`, correctly distinguishing it
  from ordinary no-match per F7's second requirement.

**Classification: A-bug.** Cites F7 directly; A implements neither half of
the ruling (no distinct data error, and the specific pattern-is-meta case
doesn't even fail structurally).

---

### 3. F8 — hypothesis identity is string-id-keyed in A, causing conflation (A-bug, confirmed, the most serious finding)

**Ruling (F8):** "The certificate leaf's object identity IS the hypothesis
id... Two leaves carrying the same judgment are two distinct hypotheses...
a DAG-shared leaf is one hypothesis."

**A's bug:** `certificate.lua`'s `M.hypothesis(id, judgment)` takes an
explicit **string** id, and `replay.lua`'s `replay_hyp` keys the open set by
that string (`open = { [hyp.id] = hyp.judgment }`). Two structurally
distinct hypothesis node objects that happen to share a string id are
indistinguishable in every open-set merge (`for id, judgment in pairs(pr.open)
do open[id] = judgment end` is a plain table write — last writer wins).

**Repro:** two distinct hypothesis objects, both id `"h1"`, carrying
**different** judgments (`c0` and `c1` of a two-constant signature), fed as
the two premises of a rule with conclusion `pair(X,Y)`:
```lua
local hyp1 = replayer.hypothesis("h1", judgment_c0)
local hyp2 = replayer.hypothesis("h1", judgment_c1)  -- hyp1 ~= hyp2 (distinct objects)
local node = replayer.cite_rule(rule, { hyp1, hyp2 })
local result = r:replay(node)
```
- **A:** replay succeeds; `result.open` has exactly **one** entry (`h1`),
  the second hypothesis's contribution silently overwritten. A derivation
  that should carry two independent open obligations reports one — and if
  a later discharge names `"h1"` it discharges what the certificate author
  believed was one specific assumption but the kernel treats as both.
- **B:** (leaves have no id field at all — the node reference itself is the
  identity, verified `hyp1 ~= hyp2` via Lua `==`) `replay` fails with `"2
  undischarged hypothesis(es) at root"` — both correctly kept open and
  distinct.

**Classification: A-bug.** This is a soundness-relevant conflation, not a
cosmetic difference — cites F8's explicit "two distinct hypotheses" clause.
Confirmed rigorously via direct execution; not merely inferred from source
reading.

---

### 4. F11 — no registry object in A; no way to enforce (name, version) uniqueness at all (A-bug, structural, confirmed)

**Ruling (F11):** "(name, version) uniqueness is enforced per registry."
Also: "Reject at declare-time: ...a conclusion-pattern or slot-pattern
metavariable not a subset of the union of premise-pattern metavariables."

**A's bug, part 1 (structural):** `replayer/registry.lua`'s `declare_rule`
and `declare_axiom` are standalone functions taking no registry parameter
at all; `replayer/init.lua` exposes them directly
(`M.declare_rule = registry.declare_rule`). Grepped the entire
`lib/type/v10_kernel/` tree (including `theories/`, `pilot/`) for any
registry-like wrapper — none exists; comments in
`theories/algorithm_w_test.lua` and `theories/algorithm_j.lua` explicitly
confirm this is deliberate ("there is no registry step to reuse into").
There is structurally no way to enforce `(name, version)` uniqueness in A.

**Repro (confirmed):**
```lua
local rule1 = replayer.declare_rule({ name = "dup-rule", version = 1, ... })
local rule2 = replayer.declare_rule({ name = "dup-rule", version = 1, ... })  -- SAME name+version
```
- **A:** both succeed, no error — cannot reject, no registry object exists
  to check against.
- **B:** `M.declare_rule(reg, spec)` — second call on the same registry
  returns `nil, "declare_rule: 'dup-rule-b@1' is already declared in this
  registry"`.

**A's bug, part 2 (metavariable subset check absent):**
```lua
local premise_pat = k.build(sig.ops.c0, {})            -- ground, no metavariables
local conclusion_pat = k.build_meta("Z", sig.sorts.tm)  -- Z unbound by any premise
replayer.declare_rule({ premises = { premise_pat }, conclusion = conclusion_pat, ... })
```
- **A:** accepted at declare-time — the failure only surfaces later, at
  replay, as `"instantiate: unbound metavariable 'Z'"`.
- **B:** rejected immediately: `"declare_rule: conclusion metavariable 'Z'
  does not occur in any premise"`.

**Classification: A-bug** (both parts). Cites F11 directly, both clauses.

---

### 5. F10 — hypothesis judgment groundness/closedness never enforced in A (A-bug, confirmed)

**Ruling (F10):** "hypothesis leaf judgments must be ground AND closed at
construction. Metavariables in hypotheses are rejected."

**A's bug:** `certificate.lua`'s `M.hypothesis(id, judgment)` only checks
`type(judgment) == "table"` and that it has a `.tag` field — no
groundness/closedness check. Worse, `replay.lua`'s `replay_hyp` also never
checks: `return { conclusion = hyp.judgment, taint = {}, open = { [hyp.id] =
hyp.judgment } }` — no `is_ground`/`is_closed` call anywhere in the
hypothesis path.

**Repro:**
```lua
local judgment = k.build(sig.ops.p, { k.build_meta("M", sig.sorts.tm) })  -- p(M), non-ground
local hyp = replayer.hypothesis("h1", judgment)      -- accepted
local r = replayer.new(k)
r:replay(hyp)                                        -- ALSO succeeds
```
- **A:** both construction and replay succeed with a metavariable-carrying
  judgment — F10 is unenforced anywhere. Same result for a non-closed
  (free-variable) judgment.
- **B:** `replay` rejects both: `"replay: hypothesis judgment contains a
  metavariable"` and `"replay: hypothesis judgment must be closed"`
  respectively. (B has no separate "construction" step for hypothesis nodes
  — they are plain tables — so the check is at first replay; this is judged
  equivalent to "construction" for B's grammar, since a plain table isn't
  validated at all until replay touches it. A, by contrast, DOES have an
  explicit `hypothesis()` constructor and still skips the check there and
  at every later point.)

**Classification: A-bug.** Cites F10 directly.

---

### 6. F12 — extra axiom-citation binding not rejected in A (A-bug, confirmed)

**Ruling (F12):** "bindings supplied for metavariables not in the declared
pattern are rejected (no silent ignoring)."

**Repro:**
```lua
local pat = k.build_meta("X", sig.sorts.tm)
local axiom = replayer.declare_axiom({ pattern = pat, ... })
local node = replayer.cite_axiom(axiom, { X = {term=c0,depth=0}, Y = {term=c0,depth=0} })  -- Y not in pattern
r:replay(node)
```
- **A:** succeeds silently — the extra `Y` binding is ignored (never read
  by `instantiate`, which only walks the pattern's own metavariables).
- **B:** `nil, "replay: axiom binding for 'Y' — no such metavariable in the
  axiom pattern"`.

**Classification: A-bug.** Cites F12 directly ("no silent ignoring").

---

### 7. F13 — same metavariable id, two different sorts, not rejected in A (A-bug, confirmed)

**Ruling (F13):** "the same `id` appearing with two different sorts in one
pattern is a validation error at declaration."

**Repro:**
```lua
local m_tm  = k.build_meta("X", sig.sorts.tm)
local m_jdg = k.build_meta("X", sig.sorts.jdg)
k.build(sig.ops.mix, { m_tm, m_jdg })   -- X used at both tm and jdg in one op node
```
- **A:** accepted — no error. (Consistent with finding #2: A has no
  metavariable-occurrence tracking of any kind, so it cannot detect this
  either.)
- **B:** `nil, "build: metavariable 'X' occurs with two different sorts"`.

**Classification: A-bug.** Cites F13 directly. Root cause is the same
structural gap as finding #2 (F7): A's term representation carries no
metavariable-occurrence cache at all, so every ruling that depends on
knowing "which metavariables occur in this term, at what sort" (F7, F11's
subset check, F13) is unenforceable in A without adding that cache.

---

## Rulings checked with no divergence found

Each below was executed against both sides (not merely read) and produced
identical accept/reject verdicts and, where applicable, identical
serialized conclusions (differing only in error-message text, which is
shape-only and not dwelt on):

- **F1** (binds order / list-position ↔ index): both accept the correctly-
  sorted binder-position var and both reject the mis-sorted one, at the
  same position.
- **F2** (subst pure replacement, no renumbering): both produce
  `f(var(9), var(5))` from `subst(f(var(0),var(5)), 0, var(9))` — index 5
  untouched.
- **F3** (subst no-op when k not free, no sort check): both succeed as a
  no-op when substituting a wrong-sorted replacement at a non-free index.
- **F5** (pre-order traversal fixes first-occurrence depth; F4-in-match
  underflow becomes ordinary match failure): both correctly fail to match
  `pair(lam(X), X)` against `pair(lam(var 0), c0)` (no consistent binding
  across the binder-depth gap) — same outcome, different error text.
- **F6** (all name collisions reject, including own-sort-vs-import): both
  reject an import whose local name collides with an owned sort.

## Fuzz-stats

Differential fuzzer at `/tmp/v10_parity/fuzz.lua` (seeded, not committed).
Generates random terms over a shared 5-op signature (`z`, `s`, `pair`,
`lam` [1 binder], `lam2` [2 binders]) up to depth 4, and random patterns
with metavariables `X`/`Y` at random leaf positions up to depth 3.

| run | seed | shift/subst cases | shift/subst divergences | match cases | match divergences | wall clock |
|---|---|---|---|---|---|---|
| small | 424242 | 800 | 72 (9.0%) | 800 | 0 | 0.04s |
| large | 999001 | 5000 | 360 (7.2%) | 5000 | 0 | 0.24s |

Every recorded divergence in both runs is the F4 shift-underflow bug
(finding #1); no other divergence shape appeared in fuzzing beyond what the
targeted probes above already found. Match fuzzing found 0 divergences
because the generator only produces **ground** subject terms (no
metavariables in subject position) — see harness gaps below; F7 was only
caught by the targeted probe, not by this fuzz round.

## Known gaps in this harness — UNTESTED, not "same behavior"

- **F9** (per-node ground/closed check, not just root). Not independently
  exercised beyond the leaf-level check exercised by F10's repro. Under the
  ratified grammar, rule/axiom conclusions are always built by
  `instantiate` from patterns containing only `meta`/`op` nodes (never a
  bare free `var` outside a binder-scoped position reachable from the
  root), so a non-root node computing a non-closed conclusion did not look
  constructible with the harness's rule/axiom vocabulary in the time
  available. **UNTESTED** — not verified identical, not verified different.
- **Match fuzzing never generates a metavariable-containing subject.** The
  ground-term generator used for match subjects intentionally builds
  meta-free terms (subjects are always ground in this harness), so the
  fuzz round cannot rediscover finding #2 (F7) on its own — only the
  targeted probe did. Any other F7-shaped divergence hiding in a subtler
  metavariable-under-binder subject position is **UNTESTED**.
- **`fast.lua` (A's fast tier) was excluded entirely, per the task's
  explicit scope** — not compared at all, not even for parity against A's
  own reference tier (that is `term_algebra_parity_test.lua`'s job, a
  different axis than this adjudication).
- **DAG-sharing with divergent per-parent discharge contexts** (the
  charter's "Fable's acceptance case" — one shared node, two parents with
  different discharge status) was not built as an explicit repro in this
  session; B's own `replayer_test.lua` states it implements this as a
  required test, and its passing is taken on the strength of that file,
  not independently re-derived here.
- **No fuzzing of `declare_signature`/`declare_rule`/`declare_axiom` reject
  paths beyond the targeted F6/F11 probes** — e.g. random malformed specs,
  operator-vs-import collisions, discharge-slot out-of-range indices beyond
  the one case checked. Declare-time validation as a whole is UNTESTED
  beyond the specific clauses probed above.
- **No benchmarking / no attempt to compare A's fast tier's parity
  discipline** — out of scope per the task, noted so it isn't mistaken for
  an oversight.
- **The "Explicitly open" side-conditions section**: neither A nor B
  implements a side-condition mechanism in rule schemas (grepped both
  trees — no side-condition field in either `declare_rule` shape); this is
  correct per that section's deferral and is not a violation.

## Summary of classifications

All 7 confirmed divergences are **A-bugs** — B has no confirmed violations
of any F1–F13 ruling in this session's testing. This matches the task's
framing ("B was built under the rulings, has no excuse") but is reported
here as an empirical result, not an assumed one: every B behavior cited
above as "correct" was independently executed and observed, not taken on
faith from B's own comments.

No **new-underdetermination** (spec/rulings genuinely silent) was found
during this session's probing — every divergence traced to an A-side gap
against an existing, unambiguous F-ruling.
