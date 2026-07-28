# v10 typechecker core design record — term algebra ratified

Status: running design record for the v10 core (cleanroom) design round;
owner-ratified content only; session 2026-07-27.

Continues `docs/decisions/typechecker-v10-core-charter.md` (companion /
prerequisite; read it first for the cleanroom discipline and decision-doc
convention this document follows). Per this repo's decision-doc convention,
only settled conclusions and explicitly-flagged-open items are recorded —
no intermediate wrong turns.

This document is appended to as the design round progresses; each ratified
batch is committed as it lands. It does not modify any historical doc.

---

## Settled (owner-ratified this session)

### Term algebra

**The core's term representation is sorted abstract binding trees (ABTs).**
Operators are declared with arity, binding valence, and argument/result
sorts; de Bruijn binding underneath; display names are cosmetic only. The
kernel is domain-blind: operator vocabularies are declared by registry
entries (theories, later the prefix); the kernel knows only structure.

**Sort discipline: flat named sort set, no subsorting — a hard grammar
rule.** Ill-sorted construction is rejected structurally.

**Metavariables are in-grammar** (a distinguished node): patterns are terms
containing metavariable nodes; first-order matching is a kernel primitive.
Kernel check required: no metavariable may survive in a concluded judgment.

**Metavariables may occur under binders, with shift-aware instantiation**
(de Bruijn shifts applied at instantiation; capture impossible by
construction).

**Miller patterns** (metavars applied to distinct bound variables) are named
as the contained future upgrade path, should quantified alias schemas ever
be needed. **Full HOL-style terms are excluded.**

### Refinement: intrinsically-sorted variables (owner-ratified this session)

**Variable nodes carry their sort, symmetric with metavariables:**
`var(k, sort)`. This reconciles three previously-ratified properties that
were jointly unsatisfiable as written — O(1) total `sort_of`, ill-sortedness
unrepresentable, and no deep validation walks. Every node additionally
caches at build a free-variable context (map: live de Bruijn index → sort;
`var(k,s)` carries `{k→s}`; closed terms carry empty); see the primitive
set specification section for how `build` uses this cache. The rejected
alternative, recorded: sortless vars with context-relative sorting — would
have made `sort_of` partial and build's guarantee context-relative,
weakening two ratified properties.

Credit: this refinement, and the non-linear-metavariable shift-adjust
refinement recorded in the primitive set specification section below, both
surfaced because an implementation agent halted on a genuine gap rather
than guessing — the halt discipline working as intended, not a deviation
to patch around silently.

### Rationale

Recorded compactly, attributed to the session's analysis:

1. **Entailment.** The flat-sort ratification structurally excludes
   HOL-style λ-terms (application requires arrow sorts); the framework
   postmortem's lesson 2 excludes raw trees (per-theory capture-avoidance).
   Sorted ABTs are what remains.

2. **End-state perf ceiling.** De Bruijn ABTs are canonical by construction
   → content-hash = byte hash, hash-consing, O(1) interned equality, maximal
   memo hit rate; no β-redexes are representable → no normalization needed
   in trusted code; first-order matching is deterministic and linear in
   pattern size; nodes are dense (`{op_id, args}`) vs. HOL app-spines —
   favorable constant factors for the LuaJIT perf bar. (Ceiling/asymptotic
   arguments, not measurements.)

3. **Compression ceiling.** Schematic aliases (patterns with metavars,
   AOT-proved once by symbolic replay, cited as one node, nested) give
   log-depth certificates over exponential derivations in both algebras;
   the one HOL-only gain — higher-order alias schemas quantifying over
   contexts/constructors — is an economy-of-statement gain, not a
   capability gain, since the finite declared operator vocabulary lets
   first-order alias families be enumerated and mechanically AOT-proved per
   operator.

4. **Structural safety of the choice.** ABTs are exactly the second-order
   fragment of HOL-style terms — each operator embeds as a constant whose
   valence becomes an arrow-type (e.g. a valence-1 slot ↦ `(tm → tm)`); the
   image is the β-normal, η-long, at-most-second-order, Miller-pattern
   fragment. Ratifying ABTs therefore forecloses nothing: escalation is an
   embedding, not a migration, and the fragment boundary is precisely the
   decidability/perf fence — fence-by-construction rather than
   by-convention, consistent with the flat-sorts and axioms-undischargeable
   rules.

### Mandatory caveat (verbatim in substance)

The precedent claims in the rationale above (LF/HOAS encodings,
second-order abstract syntax literature, Isabelle schematic theorems,
Nuprl's ABT term structure) are from the design session's memory and were
**not verified against external sources in-session.** The owner ratified
the term algebra with this caveat surfaced. External grounding remains an
available follow-up before implementation hardens.

---

## Kernel primitive tiers and trust

### Settled (owner-ratified this session)

**Perf-critical kernel primitives get two implementations, applying the
repo's existing tier doctrine inside the kernel:**

- A **reference tier** that IS the semantic definition: structural equality,
  and eager de Bruijn substitution — simple, obviously correct. **Eager
  substitution is the reference semantics.**
- A **fast tier** as an optimization claim: hash-consed interning with
  pointer equality, and explicit/lazy substitution. The lazy/explicit-subst
  fast tier sits behind the same primitive signature as the reference tier,
  so tier choice is swappable and benchmark-driven at implementation time,
  per the repo's standing perf-work rules.

**Each fast tier's soundness is a named, versioned registry axiom**
(working names, not final: `kernel-interner-sound-v1`,
`kernel-lazy-subst-sound-v1`) — assumed until proven, burned down like any
other axiom. Until proof: mandatory parity tests + parity fuzzing of fast
tier against reference tier, and benchmarks logged, per the repo's standing
multiple-implementation discipline.

**What "proven" will mean, recorded upfront:** a model-level proof
(interner / explicit-substitution calculus proven correct, post-core, in
the proof stack) plus empirical parity/fuzz evidence that the Lua
implementation matches the model — the same model-vs-reality split the
reality-bridge embodies. Proving the LuaJIT code itself is not on any path;
the axiom burns down to "proved at model level + empirically bridged,"
never to zero. This is not to be later read as more than that.

**Run-level trust carveout for kernel axioms (owner-refined design):**

- Kernel-implementation trust is uniform over a replay run — it cannot vary
  per node, so per-node marking carries zero information at pure cost.
  Kernel-config axioms are therefore carved out of per-node taint sets into
  a single **run-level trust label** derived from the kernel configuration
  (e.g. `{eq = reference|interned, subst = eager|lazy}`). Node taint sets
  remain reserved for in-derivation axioms (legacy imports etc.), where
  taint varies per node and means something. This carveout is deliberate,
  not an oversight, and is documented here with this rationale for that
  reason.
- **Anti-laundering rule (extends the unlaunderability invariant):**
  caches/memo tables are keyed (or labeled) by kernel-config hash — a
  judgment produced under a fast config must never be served into a
  reference-config run claiming axiom-freedom. Any persisted or exported
  verdict carries its run label.
- The trust-query API unions both sources: a judgment's effective axiom set
  = node taint ∪ run label.
- **Free property (requirement):** a run under the all-reference config
  carries no kernel axioms — "re-run the slow kernel" is always the escape
  to kernel-axiom-free status.

---

## Primitive set specification

### Settled (owner-ratified this session)

Working names throughout; final names to be checked against
`docs/conventions.md` naming rules at implementation.

**Term grammar — exactly three node forms:**

- `var(k, sort)` — de Bruijn index; intrinsically sorted, symmetric with
  `meta(id, sort)` (refinement — see term algebra section above).
- `op(op_id, a1..an)` — operator node; each argument is `(bound_count,
  term)` matching the operator's declared valence.
- `meta(id, sort)` — metavariable node; legal in pattern positions only.

**Cached per node at build (refinement, owner-ratified this session):**
sort (`sort_of`, O(1)) and a free-variable context — a map from live de
Bruijn index to sort (`var(k,s)` carries `{k→s}`; closed terms carry
empty). `build` validates binder sorts from these caches with no deep walk:
for an argument with `binds = {s1..sn}`, indices `0..n-1` of that
argument's context must match where present; matched entries discharge,
the remainder shifts down by `n`, and contexts merge across arguments with
a same-index-same-sort consistency check. Node context = the merge; node
sort = `decl.result`. Cost named at ratification: one small per-node map,
dedup'd under hash-consing. Falls out and ratified with it: `subst` is
sort-safe (`sort_of(replacement)` must equal the target var's sort — error
otherwise), and closedness is O(1) (empty context) — replay's conclusions
are required ground AND closed.

**Declarations (registry-side; the kernel validates against them, stores
none of their meaning):**

- Sort: a bare name in the flat sort set.
- Operator: name, result sort, per-argument `(sort, valence)` where
  valence = list of sorts of the variables bound in that argument.

**Primitives** (all data errors return `(nil, errmsg)` per repo
convention):

- `build(op_decl, args)` — the ONLY way to construct a term; checks arity,
  argument sorts, valences. Ill-sorted/ill-formed terms are unrepresentable,
  not detected. (Ratified explicitly: sole-constructor over
  raw-construction-plus-check — validity by construction.)
- `equal(a, b)` — reference: structural walk; fast: pointer-eq on interned
  nodes (under `kernel-interner-sound-v1`).
- `shift(t, d, cutoff)` — de Bruijn shift.
- `subst(t, k, u)` — capture-avoiding by construction; reference: eager;
  fast: explicit-subst (under `kernel-lazy-subst-sound-v1`).
- `match(pattern, term)` — first-order, deterministic, no search;
  shift-aware under binders; returns bindings (meta id → term + binding
  depth) or `nil, err`. Non-linear patterns ALLOWED (ratified explicitly):
  a metavariable occurring more than once binds on first occurrence and
  each later occurrence is checked with `equal` at bind time — rules like
  W-App need shared-metavariable premises, and moving that equality outside
  the primitive into per-rule convention was rejected.
  **Refinement, owner-ratified this session — non-linear metavariables
  across binder depths (shift-adjust):** a match binding stores `(term,
  binding depth of first occurrence)`; a later occurrence at depth `d'` is
  checked via `equal(candidate, shift(stored, d'-d))` rather than plain
  `equal`. Match and `instantiate` remain exact inverses. Candidates
  referencing binders strictly between the two depths fail naturally —
  correct, since no consistent binding exists. The rejected alternative,
  recorded: outright rejection of depth-mismatched recurrence — would
  silently narrow expressible rules and diverge from `instantiate`'s shift
  semantics.
- `instantiate(pattern, bindings)` — applies shifts per binding depth;
  unbound metavariable is an error.
- `is_ground(t)` — no metavariable nodes; the kernel refuses any concluded
  judgment that is not ground.
- `sort_of(t)` — O(1), sort stored at build.

Kernel config `{eq, subst}` → run-level trust label, caches keyed by config
hash, per the kernel primitive tiers and trust section above.

This closes the "concrete primitive set specification" open item below.

---

## Operator signature format

### Settled (owner-ratified this session)

Closes the "operator-declaration format for registry entries — the
concrete Lua shape" open item.

- `kernel.declare_signature(spec) -> sig | nil, errmsg`; `spec = { name,
  version, sorts = { names... }, ops = { opname = { result = sortname,
  args = { { sort = sortname, binds = { sortnames... }? }... } } } }`.
  Validation happens entirely at declaration (unknown sorts, duplicate
  ops, malformed valences rejected); the result is an immutable signature
  holding kernel-interned decl objects — after declaration succeeds no
  malformed decl is observable (validity-by-construction, third
  application of the fence pattern).
- `build(decl, args)` takes a pre-resolved decl object (`sig.ops.X`), not
  registry+name — no hot-path lookup. Node `bound_count` is stamped by
  `build` from `#binds`; callers never supply it (refines the ratified
  grammar: `bound_count`'s source is the decl).
- Operator identity = declared-object identity (+version): same-named ops
  in different signatures are different operators; vocabulary sharing =
  citing the same signature object (this is how the prefix's shared
  vocabulary will be imported). Terminology fixed: "signature".

---

## Schematic instantiation: conclusions are computed

### Settled (owner-ratified this session)

Task-4 fork A. This is also where the "no-metavars-in-conclusions check's
placement" open item resolves: the check (`is_ground`) is enforced during
replay, immediately after instantiating a rule's conclusion pattern and
before the derivation node's conclusion exists at all.

- A rule schema = premise patterns + conclusion pattern in the one term
  grammar. Replay of a node citing rule R: match R's premise patterns
  against the cited premises' conclusions in ONE shared binding
  environment (non-linearity across premises = same mechanism as within a
  pattern), instantiate R's conclusion pattern, require `is_ground`. This
  realizes the "conclusions produced by primitive calls" resolution
  literally.
- Derivation nodes carry NO conclusions; replay derives them bottom-up.
  Externally claimed statements are compared only at roots/exports.
  Consequence, recorded explicitly: nothing inside a certificate can lie
  about content — a producer bug yields a different conclusion, never a
  wrong-but-accepted one. Optional per-node conclusion annotations are
  permitted for debugging/tooling; the kernel verifies them when present
  and never needs them.

---

## Replayer: certificates, taint, discharge

### Settled (owner-ratified this session)

Tasks 5+6 merged: axiom/taint mechanism and discharge format, designed as
one object. Closes the standing discharge-certificate format open item
carried from design-sync, and closes the "taint" and "discharge format"
items from the downstream catch-all below.

**Sequencing.** The fresh replayer is built now over term_algebra,
cleanroom, with taint and discharge as birth structure — never
retrofitted. The existing `kernel.lua` is not read, not patched; it gets
retired/ported at the conformance task, per the charter's firewall.

**Axioms are schematic.** An axiom declaration is a named, owned,
versioned registry object carrying a judgment pattern; a citing node
supplies bindings; the kernel computes the axiom node's conclusion by
instantiating the declaration's pattern. Ground axioms are the
zero-metavariable special case — schematic strictly subsumes ground, and
that subsumption is the basis of the ratification. Assumption content
therefore never rides in certificates; the can't-lie property (schematic
instantiation section above) survives axioms.

**Certificate/derivation grammar — three node kinds:**

1. Rule-citation node — cites a rule schema + premise nodes; conclusion
   computed per the ratified match/instantiate replay algorithm.
2. Axiom-citation node — cites a declared axiom (+ bindings); conclusion =
   `instantiate(declaration pattern, bindings)`. Axiom nodes admit NO
   discharge form — enforced at schema/grammar validation; this is the
   stated condition keeping taint a node property.
3. Hypothesis node — a leaf introducing an assumption, carrying its
   assumed judgment as a term. The ONLY content-carrying node kind, and
   its content is CHECKED, not trusted: validated at discharge time
   (below).

**Taint.** A node property, computed bottom-up by set union: node's taint
= own axiom citation (if any) ∪ union of premises' taints. Memoized per
node, parent-independent. Kernel-config axioms stay in the run-level label
per the earlier carveout; effective axiom set = node taint ∪ run label.

**Discharge: bottom-up open-hypothesis sets.** Every node has a computed
set of open (undischarged) hypothesis ids below it: a hypothesis leaf
contributes itself; a rule node's open set = union of premises' open sets
MINUS the hypotheses its schema discharges. A rule schema declares
discharge slots as `(premise index, hypothesis pattern)`; at replay, the
discharged hypothesis's carried judgment must equal `instantiate(hypothesis
pattern, bindings)` — this is what makes hypothesis content checked.
Validity = root's open set is empty.

DAG sharing needs no extra mechanism: a shared subderivation has one fixed
open set; each parent subtracts within its own computation only — nothing
is ever globally marked discharged, which structurally prevents
re-introducing the historical all-paths discharge bug (the c4b62ec2
lesson). Fable's acceptance case (shared node, two parents with different
discharge contexts → identical taint, potentially different discharge
status) falls out of the formulation and is REQUIRED as an executable
test.

**Replay** = one bottom-up pass per node computing `(conclusion, taint
set, open-hypothesis set)`, all memoized; root checks: conclusion ground
AND closed, open set empty; run-level trust label attached; caches keyed
by kernel-config hash.

**Side conditions note.** Remain deferred/undesigned (removability
requirement stands, per the clarified open item below); rule schemas in
this replayer have NO side-condition slot — a rule needing one halts to
the owner.

---

## Explicitly open (flagged, not settled — do not present as decided)

- Side conditions in rule schemas (task-4 fork B) — UNDESIGNED, owner
  deliberately deferred. Owner-stated requirement, clarified: side-condition
  forms must be REMOVABLE — never hardcoded into the trusted core such that
  removal breaks the kernel. Forms, if any, must be declared registry
  objects (deletable, versionable, outside the trust boundary). This is NOT
  a zero-footprint-when-unused requirement: a generic kernel hook/slot is
  admissible under this constraint. The owner is explicitly unsure whether
  the removability/zero-footprint distinction is ultimately load-bearing;
  both readings were surfaced and the distinction itself is recorded here
  so a future design round evaluates candidates against the intended
  (removability) reading. Until resolved, rules requiring side conditions
  are inexpressible — such a rule halts to the owner rather than being
  worked around. The fork remains deferred; no approach is chosen (none of
  the three candidates discussed — none-in-v1 / mechanism-now-empty-
  vocabulary / starter set — has been chosen).
- Everything downstream per the charter (prefix, corroboration).
