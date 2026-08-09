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

- Sort: a declared object in the flat sort set, owned by exactly one
  signature (+ version) — identity-by-declaration, not a bare name (see
  "Sort identity" section below; this line amended by that ratification).
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
  **Amended below (sort identity ratification): `spec` also gains an
  `imports` clause for citing sorts owned by another signature; the
  `sorts` field declares sorts owned by THIS signature.** Validation
  happens entirely at declaration (unknown sorts, duplicate ops,
  malformed valences rejected, and — per the amendment — unresolvable
  imports rejected); the result is an immutable signature holding
  kernel-interned decl objects — after declaration succeeds no malformed
  decl is observable (validity-by-construction, third application of the
  fence pattern).
- `build(decl, args)` takes a pre-resolved decl object (`sig.ops.X`), not
  registry+name — no hot-path lookup. Node `bound_count` is stamped by
  `build` from `#binds`; callers never supply it (refines the ratified
  grammar: `bound_count`'s source is the decl).
- Operator identity = declared-object identity (+version): same-named ops
  in different signatures are different operators; vocabulary sharing =
  citing the same signature object (this is how the prefix's shared
  vocabulary will be imported). Terminology fixed: "signature".

### Sort identity: identity-by-declaration + explicit imports (owner-ratified)

Ratified amendment, closing an asymmetry in the original spec above,
surfaced by the pilot signature design (`docs/typechecker-v10-pilot-
signatures-proposal.md`, commit `9f91a58b`): sorts were bare unversioned
strings with no owning-signature identity, so unrelated signatures
declaring a same-named sort were silently interchangeable — accidental
vocabulary coincidence, the inverse of declc's H1 failure.

- **Sort identity = declared object identity (owning signature +
  version)** — exactly the already-ratified operator-identity principle
  (above) applied to sorts. Sort equality is object identity, never name
  equality.
- `declare_signature` gains an explicit **imports clause** for citing
  sorts owned by another signature (e.g. the shared addressing
  signature's point/path). The precise Lua field shape of `imports` is
  left to implementation-time, consistent with this document's existing
  working-names convention for the primitive set — no shape is ratified
  here beyond: it names a source signature and the sorts cited from it,
  and declaration fails if the citation cannot be resolved.
- **The flat-sort ratification is UNTOUCHED** — still a flat set, no
  subsorting; only identity semantics change.
- Rejected alternatives, recorded: merging signatures (forfeits
  declared-once-shared addressing) and sort-name convention (unenforced
  coincidence — the documented graveyard pattern).

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
discharge slots as `(premise index, hypothesis pattern)` — what kind of
assumption the rule may close. Validity = root's open set is empty.

**Refinement, owner-ratified this session — discharge slots resolve to
instances by explicit id citation** (labeled discharge, the standard
natural-deduction mechanism; surfaced because the replayer builder halted
on a genuine gap — the prior text didn't specify how a schema-level
discharge slot picks out hypothesis instances):

- Schema level unchanged: slots = `(premise_index, hypothesis_pattern)`.
- Certificate level: a rule-citation node carries, per slot, the SET of
  hypothesis ids it discharges. Ids only, never content — the can't-lie
  property is preserved.
- Replay checks each named id: it must be open in the cited premise's
  open-hypothesis set (citing a non-open id rejects), and its carried
  judgment must equal `instantiate(slot pattern, shared bindings)`
  (mismatch rejects — this makes judgment-mismatch-at-discharge a real,
  testable failure mode). Valid ids are subtracted; all unnamed
  hypotheses stay open and bubble upward (nested unrelated hypothetical
  contexts compose untouched). An empty id-set per slot is legal —
  vacuous discharge, standard ND.
- Rejected alternatives, recorded with reasons: filter-and-subtract
  (auto-discharge all judgment-matching open hyps — makes
  mismatch-at-discharge unreachable as an error and removes deliberate
  keep-open control) and discharge-all-and-verify (force-checks unrelated
  outer hypotheses against a pattern they were never meant to satisfy —
  breaks nested composability).

DAG sharing needs no extra mechanism: a shared subderivation has one fixed
open set; each parent subtracts within its own computation only — nothing
is ever globally marked discharged, which structurally prevents
re-introducing the historical all-paths discharge bug (the c4b62ec2
lesson). Fable's acceptance case (shared node, two parents with different
discharge contexts → identical taint, potentially different discharge
status) falls out of the formulation and is REQUIRED as an executable
test.

**Replay** = one bottom-up pass per node computing `(conclusion, taint
set, open-hypothesis set)`, all memoized. **Amended by F9 below (spec
adjudications section): EVERY node's computed conclusion must be ground
AND closed, not only the root's** — a node failing this check is a
replay error at that node. Root additionally checks open set empty;
run-level trust label attached; caches keyed by kernel-config hash. (The
prior wording here — "root checks: conclusion ground AND closed" — is
superseded; the root's ground/closed check is now redundant belt over
the per-node requirement, not the sole enforcement point.)

**Side conditions note.** Remain deferred/undesigned (removability
requirement stands, per the clarified open item below); rule schemas in
this replayer have NO side-condition slot — a rule needing one halts to
the owner.

---

## Pilot: flow-narrowing on the kernel — plan of record

This is a PLAN record, not a ratifications section: the items below are
scheduled work and framing, not owner-ratified design conclusions. Ratified
content stays exclusively under "Settled" sections above.

### Status note — execution mode change

The owner has delegated pilot execution to the design session ("execute,
surface when something comes up"). Decisions made under this delegation
are marked **fable-delegation-tier**: derived and recorded, explicitly NOT
owner-ratified, and re-openable without ceremony. Owner-ratified items
(the "Settled" sections above) remain the only fully settled tier —
fable-delegation-tier content must not be read as equivalent to them.

**Owner directive, 2026-08-09: campaign mode is now rapid-iteration/
fail-fast.** In-flight design calls are made at delegation tier (recorded,
reopenable); owner ratification is reserved for soundness-relevant forks
and dead-ends. A composition build (second theory + spine vocabulary over
`addr-v1` — the architecture's central claim) is in flight under this
mode.

### Context (recorded so the plan's motivation survives)

The campaign's open risk, owner-articulated: there is no confirmation the
architecture yields a beyond-SOTA analysis engine. The known decomposition:

- **Risk 1** — certificate-shapeability of serious analyses.
- **Risk 2** — emit+replay overhead at real scale.
- On top of both: the **corroboration bet** (power-by-composition), which
  the design-sync already records as the sharpest unresolved point.

MLstruct-class single-calculus systems are the floor the owner explicitly
wants exceeded; power-by-composition over the trust substrate is the only
known route that isn't the graveyard's fused-monolith shape. The pilot
converts risks 1+2 from faith to measurement; the corroboration/power test
is a planned successor with its increment defined (second theory +
corroboration wiring over the same addressing signature).

### Plan of record — five steps, each one artifact

1. **Program-point addressing signature** — structural-path addressing
   from chunk root, declared once, shared by all theories (the declc-H1
   counter-move; evaluated against the framework postmortem's three
   lessons). Under design now (proposal doc forthcoming at
   `docs/typechecker-v10-pilot-signatures-proposal.md`).
2. **Pilot type vocabulary signature** — pilot-scoped (primitives / union /
   nil-falsy), versioned, not the full type algebra.

   **Note (owner-ratified):** signature 1 (`addr-v1`) and signature 2
   (`narrow-pilot-v1`) from the pilot signature proposal proceed to
   implementation on the basis of the sort-identity-by-declaration
   ratification above — `holds_at`'s declaration, previously blocked, is
   unblocked via sort imports (citing `addr-v1`'s point/path sorts from
   `narrow-pilot-v1`).
3. **Flow-narrowing theory** — rule schemas over 1+2; guard forms from
   real crescent usage; theory soundness enters as a named axiom (no
   prefix anchor yet — deliberate, priced). Any rule needing a side
   condition halts to the owner (the deferred side-condition fork, faced
   with a concrete case).

   **Executed (fable-delegation-tier, not owner-ratified) —
   `lib/type/v10_kernel/pilot/flow_narrow_v1.lua` +
   `..._test.lua`.** Declares `{name="narrow-pilot-v1", version=2}`
   (additive extension of step 2's signature — same op set + one new op;
   a distinct declared object from v1, per operator/sort identity rules,
   so v1's own module/tests are untouched) importing `point`/`path` from
   `addr-v1`. Grepped real usage first (`| nil` ~6600 hits vs 3+-way
   unions ~180 across `lib/`) to keep scope honest rather than assumed.

   **Reality-boundary resolution (the pilot's version of "how do ground
   facts about a file enter the derivation"):** one new judgment op,
   `guard_selects(guard_point, branch_point, var_path, target_ty)`,
   covering all three in-scope guard forms (`type(x)==/~="T"`, `x==/~=nil`,
   bare truthiness) uniformly via `target_ty` — asserted only via a single
   schematic axiom, `pilot-syntax-facts-v1` (fully-metavariable pattern;
   every concrete instance is an untrusted-prover axiom CITATION, never a
   hypothesis), which tags every derivation using it with that axiom key.
   No kernel change — the ratified schematic-axiom mechanism already
   covers this; confirms the brief's anticipation that it would.
   Documented in the module as the reusable pattern for every future
   theory needing syntax facts.

   **Rule table** (two rules, signature `narrow-pilot-v1` v2):
   | rule | premises | conclusion | informal statement |
   |---|---|---|---|
   | `narrow-select-match` v1 | `holds_at(Pg,X,ty_union(TA,Rest))`, `guard_selects(Pg,Pb,X,TA)` | `holds_at(Pb,X,TA)` | on the branch the guard's syntax fact names as matching, the variable narrows to the selected member |
   | `narrow-select-rest` v1 | same two premises | `holds_at(Pb,X,Rest)` | on the other branch, the variable narrows to everything else in the union |

   Polarity (`==`/`~=`) and then/else selection are not in the judgment or
   rules at all — purely which rule + which point the (untrusted, later)
   prover cites; the shared non-linear metavariable `TA` across both
   premises is what makes this sound rather than a rubber stamp (same
   mechanism as `hm-app`'s argument/domain forcing). Arbitrary-width
   unions are handled by re-citing `narrow-select-rest` against a
   possibly-union `Rest`, not by enumeration. No rule required a side
   condition — HALT was not triggered. One explicit, flagged (not halted)
   scope limit: a guard over an already-monomorphic (non-union) fact
   doesn't match either premise shape — out of scope, not mishandled.

   Tests (both term_algebra tiers): clean declaration; each rule replays a
   hand-built certificate to its expected conclusion; a malformed variant
   of each (mismatched `target_ty`, mismatched variable path) is rejected
   at replay; the syntax-facts axiom itself rejects a discharge form; a
   two-guard chain (truthiness peel, then a `type()`-tag peel on the
   remainder) replays end-to-end; taint carries exactly the syntax-facts
   axiom key, deduplicated across repeated citations.
4. **Certificate-emitting prover** — crescent parser + narrowing analysis
   (v3 readable now, post-core), two-pass emission per the W/J-port
   pattern.

   **Executed (fable-delegation-tier, not owner-ratified) —
   `lib/type/v10_kernel/pilot/prover_addr.lua`,
   `prover_narrow.lua`, `prover.lua`.** Then extended further into a
   fixpoint/control-flow line, beyond the original step-4 scope:
   `fixpoint_v1.lua`, `fixpoint_prover.lua` — loop-invariant certificates,
   if/else branch-join chaining, assign-call-transfer. Commits
   `4a741cae`, `1a491500`, `0dae97e6` (all dated 2026-07-30).
5. **Measurement** on real `lib/` files vs the v3 checker: judgments
   derived+replayed, precision deltas, wall-clock emit+replay vs check
   time.

   **Status (fable-delegation-tier, not owner-ratified) — started
   2026-08-09, deliberately STOPPED by owner call:** measuring a
   narrowing-only analyzer is useless until the analyzer demonstrates real
   precision. Measurement is re-queued behind the composition work (second
   theory + spine vocabulary over `addr-v1` — see the fail-fast-mode entry
   below).

   **Open items tracked in TODO.md only (not yet promoted into this
   record's own open-items list), findable from here:**
   - `TODO.md:48` — a `--::` type-visibility bug: type visibility breaks
     across a two-hop `require` once the requiring file contains any
     `--:`-annotated local function, even one whose signature references
     none of the required types. Filed against
     `lib/type/static/constrain.lua`'s cross-file type-declaration
     collection; not investigated further (typechecker-internals
     territory, outside this milestone's scope).
   - `TODO.md:50` — the assign-copy-transfer fork: `fixpoint_prover.lua`
     does not attempt `assign-copy-transfer` (neither self-copy nor a copy
     from a different tracked variable) at all. Self-copy specifically is
     flagged as needing an owner call — closing it would depart from the
     uniform `Pa = exit_of(own path)` addressing convention. Parked since
     2026-07-30, per the halt discipline rather than resolved unilaterally.

### Parked (unchanged status)

Awaiting owner attention after the pilot produces evidence — status
unchanged by this plan record:

- Tier-1 proof-restructure proposal's five forks
  (`docs/typechecker-v10-proof-restructure-proposal.md`, commit
  `be6b8f71`).
- Reality-bridge tier 2.
- Coverage-formalization tier 3.
- The compositionality-canary charter wording (strict vs permissive).

### Completed (un-parked)

- **`ssub.v` proof-script fix — completed at commit `d8b53036`.**
  Formerly parked as: diagnosed `decide_rsub_fuel_sound` at
  `ssub.v:1381`, tactic-time blowup from a blind 121-case
  destruct+`first[]` search. Root cause confirmed structurally: the
  original destructed the full 121-goal cross product though only the
  four ref-head corners genuinely case-split on the pair. Fix destructs
  `a` alone, delegates nine constructors in one step, sub-destructs `b`
  only under `BRef`/`BAnyRef`, rewritten in the file's own
  disciplined-bullet style. `ssub.v`: >320s hang → ~9.7s clean;
  downstream chain verified (`check.v` ~8.1s, `bridge_exec_oracle.v`
  ~0.2s); theorem statement byte-identical, proof script only. The full
  v9 proof chain now compiles again for the first time in the repo's
  recorded history, under Rocq 9.0.1.

---

## Spec adjudications — cleanroom findings F1–F13

### Settled (owner-ratified this session)

**Status line: the halt discipline worked as designed again.** A
cleanroom reimplementation of the ratified spec above halted on 13
genuine underdeterminations rather than guessing past them; each is
adjudicated below. This is the same discipline credited earlier in this
document (the intrinsically-sorted-variables and non-linear-metavariable
refinements) recurring at a different layer of the build.

- **F1 — binds order.** `binds[i+1]` corresponds to de Bruijn index `i`
  (list position order, matching the spec sentence's juxtaposition).
  Convention now fixed.
- **F2 — `subst(t, k, u)` semantics.** Pure replacement, no index
  renumbering (TAPL `[k↦u]t`); indices `> k` are untouched. β-style
  decrementing subst is NOT the primitive; expressible as `shift ∘ subst`
  if ever needed.
- **F3 — `subst` when `k` is not free in `t`.** No-op success; no sort
  check applies (there is no target occurrence to check against).
  Documented as such.
- **F4 — `shift` with negative amounts.** Allowed; index underflow
  (below cutoff) is a data error (`nil, errmsg`). `match` internally
  converts underflow arising during non-linear/depth adjustment into
  ordinary match failure — this makes the already-ratified "candidates
  referencing binders strictly between the two depths fail naturally"
  literal rather than aspirational.
- **F5 — `match` traversal order.** Pre-order, left-to-right, is the
  defined order; "first occurrence" and its recorded binding depth are
  normative to that order. Given F4, accept/reject is order-invariant;
  binding output is normalized to preorder-first.
- **F6 — `declare_signature` name collisions.** ALL name collisions
  reject: duplicate names within `sorts`, own sort vs. import, import vs.
  import. No precedence/shadowing rules, ever. An operator's result sort
  MAY be an imported sort.
- **F7 — `match` subject containing metavariables.** A data error,
  distinct from ordinary no-match. The primitive is strict;
  pattern-vs-pattern matching is not a supported operation.
- **F8 — hypothesis identity.** The certificate leaf's object identity
  IS the hypothesis id; there is no separate id field. Two leaves
  carrying the same judgment are two distinct hypotheses (standard ND); a
  DAG-shared leaf is one hypothesis. "A hypothesis leaf contributes
  itself" (replayer section above) is literal, not shorthand.
- **F9 — CONTRADICTION RESOLVED: per-node vs. root-only ground/closed
  check.** The strict reading is ratified: EVERY node's computed
  conclusion must be ground AND closed, not only the root's. The root
  check remains as a redundant belt. Rationale: an open intermediate
  judgment asserts nothing — the derivation has no term-level binder that
  could close it; kernel-conservative. The prior replayer-section
  wording (closedness enforced at root only) is superseded — see the
  amendment applied to the "Replayer: certificates, taint, discharge"
  section above.
- **F10 — hypothesis leaf judgments.** Must be ground AND closed at
  construction. Metavariables in hypotheses are rejected (would smuggle
  unification into discharge).
- **F11 — declaration-time validation, extended.** Reject at
  `declare`-time: a discharge-slot `premise_index` out of range; a
  conclusion-pattern or slot-pattern metavariable not a subset of the
  union of premise-pattern metavariables (a rule that can never replay is
  malformed at birth). `(name, version)` uniqueness is enforced per
  registry; taint-set element identity is the declaration OBJECT
  (identity-by-declaration, consistent with the sorts/ops ratification
  above), with `(name, version)` serving only as the display/citation
  key.
- **F12 — axiom-citation bindings.** Plain terms at depth 0; each must be
  ground AND closed; bindings supplied for metavariables not in the
  declared pattern are rejected (no silent ignoring).
- **F13 — sort discipline at binding.** Certified as entailed by the
  already-ratified "ill-sorted terms unrepresentable" property: `match`
  binding `meta(id, s)` to a term of sort `≠ s` fails; `instantiate`
  rejects mis-sorted bindings. Metavariable identity is `id` alone; the
  same `id` appearing with two different sorts in one pattern is a
  validation error at declaration.

**Provenance note.** These 13 readings were resolved SILENTLY by the
existing `lib/type/v10_kernel` implementation — it was built before they
were ever asked as questions. A cross-parity adjudication of that
implementation against the cleanroom build is the planned next step;
divergences found there will be judged against the rulings F1–F13 record
above, not the other way around.

---

## Canon swap: cleanroom core

### Settled (owner-ratified this session)

**`lib/type/v10_cleanroom/`** (the fable cleanroom reimplementation,
built from spec under the F1–F13 adjudications above, commits
`810097ff`/`248b1a1b`) **is now the canonical v10 kernel core.**

The prior implementation (`lib/type/v10_kernel/term_algebra/` +
`replayer/`) retires, on the evidence of the differential adjudication
(`docs/typechecker-v10-parity-adjudication.md`, commit `30f3867f`): 7
confirmed divergences, all bugs in the prior implementation against
rulings F4/F7/F8/F10/F11/F12/F13 — the F8 hypothesis-identity conflation
being soundness-relevant — with zero cleanroom-side bugs and zero new
underdeterminations.

- Dependents (HM theories, pilot modules) port to the canonical API,
  meaning-preserved.
- The fast tier retires with the old core and will be rebuilt against
  the canonical reference as a separate, axiom-carrying effort
  (`kernel-interner-sound` / `kernel-lazy-subst-sound` names unchanged).
- The adjudicator's untested areas (deep F9, broad declare-time fuzz,
  meta-in-subject fuzz, independently-derived DAG discharge case) become
  **required additions to the canonical test suite**, rather than
  assumed-same.

**Process note for the record:** the swap validates the
cleanroom+adjudication pattern — same-author tests (510 assertions)
missed all 7 divergences; the spec-first cleanroom found 13 spec gaps
before writing code and implemented clean.

### Read-only observation entry point (owner-ratified)

The canonical replayer gains a **read-only OBSERVATION entry point**
alongside root-strict acceptance — surfaced by the dependent port: four
theory tests legitimately observe interior derivation state (taint and
open-hypothesis sets of deliberately-open derivations), which a
root-only surface cannot express.

- **Semantics:** returns the already-ratified per-node computed triple
  `(conclusion, taint set, open-hypothesis set)`, with the open set in
  plain view.
- **Carries NO acceptance** — no flag or result shape mistakable for a
  verdict. Root-strict replay remains the sole acceptance channel.
- **Same memoization and config-hash keying** — same bottom-up
  computation, stopped before root checks; no separate computation path.
- **Rationale recorded:** this exposes ratified computation, it does not
  add semantics.
- The prior single-entry-point shape in the cleanroom build was an
  implementation choice under spec delegation, now superseded.

---

## Owner-stated design goals

**Status: settled as goals; recorded verbatim in substance.**

1. Extreme modularity — to the point that a kid can build a toy version of
   the architecture that is still useful in its own right.
2. Scale to zero — removability; nothing hardcoded into the core such that
   removing it breaks the kernel (consistent with the earlier side-condition
   carveout's clarified reading).
3. Perf is never carelessly left on the table.
4. Scales up to full Lua, modularly — including arbitrary strictness of
   static analysis depending on configuration.
5. Ecosystem mental model: ts-eslint + typescript — a base checker plus
   pluggable, user-authorable rule/theory packages in one ecosystem.

---

## Named open items

**Status: new, undesigned — each needs its own ratification round.**

1. **Portable core spec.** The four-piece core (claims-as-data /
   reasons-as-citations / page-sized citation checker / assumption ledger)
   written as a standalone, implementation-independent specification, such
   that a from-scratch toy implementation is a conforming replayer able to
   check real certificates. Serves goal 1.
2. **Profile/acceptance-policy object.** A declared, first-class
   configuration object = theory set + tower depth + required trust
   stratum (proved / proved-modulo-{named axioms} / asserted) per judgment
   kind. Strictness is an acceptance policy over trust labels, never an
   analysis knob. Invariant stated in-session and owner-approved for
   recording: SOUNDNESS IS NEVER CONFIGURABLE — a looser profile derives
   fewer judgments, never wrong ones. Serves goal 4.
3. **Plugin/DX surface.** Config format, project-local theory declaration,
   third-party theory authorship via the registry; a user theory without
   soundness certificates enters axiom-tainted and profiles decide whether
   tainted judgments gate. Downstream of item 2. Serves goal 5.

These three items are also carried in the open-items list below.

---

## Admission discipline (boundary addition)

**Status: owner-endorsed direction; design pending.** This supersedes the
earlier "coexistence axiom" idea raised in this session's conversation —
that idea is not recorded as live and should not be treated as settled or
in-flight.

- Composition-safety is the ADMISSION CRITERION for a feature/theory, not
  a property hunted afterward: a feature enters only through a constructor
  requiring its refinement certificate against the spine and discharge of
  coexistence obligations at every visible overlap. Fence-by-construction
  applied at the feature level, same law as ill-sorted-terms-unrepresentable.
- The feature-definition language is deliberately constrained so
  preservation/composition obligations are derivable (the same move that
  made replay decidable). Where a legitimate feature cannot fit, that is a
  SUBSTRATE GAP: extend the formalism (itself proven) or leave the feature
  undone. Never admit with a tracked assumption attached.
- Overlap between features' commitments is syntactically visible at
  declaration (shared spine judgment forms), which is what makes
  obligations mechanically generatable.

---

## Corroboration/co-solving design-input note

**Status: FLAGGED — unratified sketch. Prior-art claims are from-memory
and require grounding before hardening**, per the same discipline as the
term algebra section's mandatory caveat above. This is design input, not a
ratified conclusion; do not treat any bullet below as settled.

- Exchange is SPINE-MEDIATED ONLY: all cross-theory facts are judgments in
  layer (spine) vocabulary; there is no pairwise/bridge vocabulary between
  theories (supersedes the bridge-rules idea raised earlier in-session). A
  needed fact with no spine home = missing judgment form = substrate gap,
  halts to owner.
- Mechanism sketch: shared fact store (blackboard) + worklist; provers
  post partial judgments and subscribe via their rules' premise patterns;
  directed/stateful provers participate by suspend-on-query/wake-on-fact;
  provenance recorded as `(rule, premise ids)` per fact; certificate nodes
  materialize lazily on export. Kernel/replay never sees any of this.
- Prior-art candidates to ground then pick (owner decision):
  datalog-with-lattices (flix-style; stratified negation as the
  absence-fact treatment; semi-naive evaluation; widening/lattice cells
  for boundedness) vs. CHR (cooperating solvers over a shared constraint
  store); Nelson-Oppen/DPLL(T) as protocol precedent. Adopt a published
  formalism as-written for the generic engine; implement small in pure
  Lua.
- Perf requirements (owner goal 3 applied): the exchange unit is an
  interned term plus a provenance pair, NOTHING richer (no
  envelopes/translation layers — they reintroduce marshalling); indexed
  dispatch by `(head operator, program point)` — never store scans;
  semi-naive deltas; lattice cells not fact piles for quantitative
  domains; LuaJIT hygiene per repo doctrine. Generic engine is the floor;
  bespoke provers are unconstrained and trust-free to swap (certificates
  the only channel); the exchange protocol must be ENGINE-AGNOSTIC
  (registry objects, not engine artifacts).
- Merge-time overlap analysis (from the admission discipline section
  above) is where sibling-conflict hunting happens; at use time, conflicts
  surface as underivable/contradictory judgments — fail-closed.

---

## Corroboration proof-of-concept: spine-mediated composition, first evidence

**Status: fable-delegation-tier throughout — derived and recorded under the
pilot-execution delegation note above, explicitly NOT owner-ratified,
re-openable without ceremony.** Every design call in this section is a
delegated-execution decision. This is the first concrete evidence for the
"Corroboration/co-solving design-input note" section's central bet
(power-by-composition over the trust substrate), built directly against the
spine-mediated-exchange principle recorded there ("no pairwise/bridge
vocabulary between theories, ever"), and against the earlier pilot's own
`narrow-pilot-v1` precedent, which this build explicitly corrects — see
below.

### The correction: a genuinely spine-mediated composition, not a shared signature

The existing pilot (`flow_narrow_v1.lua` / `fixpoint_v1.lua`) grew narrowing's
and the fixpoint/effects content's judgment vocabulary
(`holds_at`/`stmt_seq`/`stmt_preserves`/`assign_*`/...) inside ONE
jointly-version-bumped signature, `narrow-pilot-v1`, successively extended by
different theory modules. Read against this session's own spine-mediated
principle, that shape IS pairwise/bridge vocabulary — whichever theory bumps
the version next is deciding the other's vocabulary surface, exactly the
declc-era H1 coupling the addressing signature (`addr-v1`) was already built
to avoid at the addressing layer. This build does not modify or retract that
existing precedent (still valid, still tested, still canon for its own
scope) — it adds a NEW, corrected composition alongside it, demonstrating
the principle the existing precedent did not yet embody.

### What was built (`lib/type/v10_kernel/pilot/`)

1. **`effects_spine_v1.lua`** — the FIRST spine signature beyond `addr-v1`,
   owned by neither theory ("the layer"). One judgment,
   `preserves(from: point, to: point, x: path)`, importing `point`/`path`
   from `addr-v1`. Working defaults from the orchestrating brief, adopted
   as-is (no rule in the build taught otherwise): positive preservation
   judgment; negation internalized in the producing theory (the prover
   decides non-interference structurally, never a rule/kernel-level
   negative premise); locals only (enforced for free — the shared
   addressing signature has no field-projection operator at all, so
   "no aliasing theory exists" needs no extra guard here).
2. **`assign_effects_v1.lua`** — the effects THEORY: its own signature
   (`assign-effects-v1`), never importing from or requiring
   `flow_narrow_v1.lua`. One reality-boundary judgment
   (`stmt_preserves_fact`), one schematic axiom, one grounding rule
   (`preserves-transfer`, axiom-tainted) and one pure rule
   (`preserves-trans`, transitivity over the spine's own shape — genuine
   rule content, not axiom pass-through, taint-free beyond what its
   premises already carry).
3. **`narrow_persist_v1.lua`** — the WIRING: one rule, `narrow-persist`
   (`holds_at(P,X,T), preserves(P,Q,X) |- holds_at(Q,X,T)`), declared with
   **no new signature at all** — `declare_rule` takes plain premise/
   conclusion terms, not a signature, so composition needed no vocabulary
   of its own; narrowing's existing `narrow-pilot-v1` v1 signature (from
   the original pilot, unmodified) and the new spine are cited exactly as
   the design brief specified: "narrowing's rules consume spine
   preservation judgments as ordinary premises." Sort compatibility (the
   metavariable `P`/`Q`/`X` typing both `holds_at` and `preserves`
   simultaneously) falls out of shared `addr-v1` import identity, not a
   special case — the same declared-object sort-identity ratification the
   core design already fixed for exactly this purpose.
4. **`prover_effects.lua`** — a fresh, deliberately narrow real-AST walker
   (not a modification of `prover_narrow.lua`/`prover.lua`/
   `fixpoint_prover.lua`, all left untouched) that finds `--:`-annotated
   two-member-six-tag-union locals/parameters guarded by a single-clause
   `if/else`, certifies the match branch via `flow_narrow_v1` exactly as
   the existing real-file prover does, then — only when the branch's own
   first statement is structurally verified non-interfering (a bare call,
   or a fresh local declaration, per the same §8.3(a) reasoning
   `fixpoint_prover.lua` already documents) — composes `narrow-persist`
   to derive `holds_at` at a LATER point neither `flow_narrow_v1` alone,
   nor this walker alone without the effects theory, can reach.

### Real-file result

Scanning all 569 `lib/*/init.lua` files (script not committed — a one-off
corpus scan), exactly one real, unmodified function triggered the composed
derivation: `lib/table_ext/init.lua`'s `M.flatten(t, depth)`
(`--: (unknown, number | nil) -> ...`), guarded by
`if depth == nil then depth_ = math.huge else depth_ = depth end`. The
then-branch assigns to `depth_` (a different local), never touching
`depth` — the effects theory certifies that non-interference and
`narrow-persist` derives `depth : nil` at the exit of that assignment, a
fact `flow_narrow_v1`'s own rules have no way to reach on their own (they
narrow only at a branch's entry, never past a subsequent statement).
Low real-corpus incidence (1 of 569 — most guards live deeper in call
chains or on chained/elseif conditions this narrow demonstration walker
does not attempt) is a scope-of-demonstration fact, not a claim about the
architecture's applicability; `prover_effects.lua`'s header records the
walker's scope limits explicitly (single-clause `if` only, first branch
statement only) as a narrowness-of-THIS-PROVER choice, not a limit of the
composition mechanism itself.

### The three-leg proof (`narrow_persist_v1_test.lua`, certificate level — the rigorous evidence)

- **(a) fail-closed baseline**: narrowing + `narrow-persist` declared, the
  effects theory declared NOWHERE. Two independent, structural dead ends,
  both asserted: citing a foreign (different-registry) effects citation is
  rejected by `resolve_citation` ("not declared in this replayer's
  registry"); assuming `preserves` as a hypothesis instead leaves it
  permanently open, and root-strict `replay` rejects ("undischarged
  hypothesis"). No certificate rooted in this registry's own declarations
  can ever produce a closed, hypothesis-free `preserves` fact.
- **(b) derives**: narrowing + the effects theory + the spine, all
  declared. Root-strict replay accepts, zero open hypotheses, conclusion
  is `holds_at` at the later point `Q`, taint names exactly the three
  axioms actually trusted (flow's syntax facts, the initial-fact axiom,
  the effects theory's own syntax facts) — no additional cost for citing a
  spine judgment as an ordinary premise beyond what was already trusted.
- **(c) scale to zero**: asserted structurally, not narrated — registry
  (a) is built by the identical sequence of calls registry (b) uses, MINUS
  the one call to `assign_effects_v1.declare_vocabulary`. Removing the
  effects theory is not calling that one function; nothing else changes,
  nothing is left dangling.

All three legs, plus unit coverage for every new module (32 files
batch-typechecked clean; 459 assertions across the pilot test suite, zero
regressions in the pre-existing 14 test files), are committed at
`lib/type/v10_kernel/pilot/{effects_spine_v1,assign_effects_v1,
narrow_persist_v1,prover_effects}{,_test}.lua`.

### Delegation-tier calls made, recorded compactly

- Working defaults from the brief (positive preservation, negation
  internalized in the producer, locals-only) adopted without modification
  — no rule built here needed a different reading.
- Spine signature location: `lib/type/v10_kernel/pilot/` (beside
  `addr_v1.lua`, the existing layer-owned precedent), not a new top-level
  directory — matches the existing "vocabulary lives beside pilot/, rules
  live in pilot/ too until a prefix exists" convention.
- `preserves-trans` (transitivity) added as a genuine rule beyond the
  brief's literal ask, to give the effects theory real inferential content
  distinct from pure axiom-wrapping — reusable by any future `preserves`
  producer, not special-cased to this one theory.
- `narrow-persist` declared with NO signature bump of `narrow-pilot-v1` —
  a stronger reading of "ordinary premises" than modifying narrowing's own
  vocabulary would have been; chosen because `declare_rule` structurally
  permits it (rules are registry-scoped, not signature-scoped) and it is
  the more literal form of "zero pairwise vocabulary."
- `prover_effects.lua`'s scope (single-clause `if`, first-branch-statement
  safety check only) was narrowed deliberately to keep the demonstration
  tractable; flagged in-module as a walker limitation, not a composition
  limitation — extending it (elseif chains, multi-statement chains via
  `preserves-trans`, table-field-free alias tracking) is future work, not
  a gap in what was proven here.

No H1-style failure was hit: composition fired cleanly at both the
certificate level (exhaustive, mechanical) and on real, unmodified
repository source (one confirmed instance). This corroborates — on a small
but real first data point — the corroboration note's central architectural
claim: two theories sharing zero pairwise vocabulary compose through a
declared spine judgment to derive precision neither reaches alone.

---

## Corroboration engine build — iteration 3, phase 1 (engine only)

**Status: fable-delegation-tier, not owner-ratified, re-openable.** Responds
to a line-count audit + blocker scan diagnosis: the 2,126 lines of bespoke
per-theory AST-walker provers (`prover_narrow`/`prover_effects`/
`fixpoint_prover`/`prover`/`prover_addr`, `lib/type/v10_kernel/pilot/`) are
hand-rolled evaluation a generic engine should subsume; separately, elseif
chains block guard analysis on a majority of the audited corpus, and the
fix is evaluation plumbing, not theory content. Owner kill-criterion:
≤2000 total non-blank non-comment lines for a working modular checker.
Delegation-tier formalism pick, adopted as-written (not re-derived this
session): semi-naive Datalog over term-algebra facts, stratified negation,
head-operator-indexed dispatch, no pairwise theory vocabulary — the
generic-engine floor the "Corroboration/co-solving design-input note"
above sketched, now built.

**Built and committed (`74e32ced`):** `lib/type/v10_kernel/pilot/engine.lua`
(188 non-blank/non-comment code lines, budget target ≤500) + `engine_test.lua`.
Facts are ground kernel terms; rules fire by matching an
already-declared `RuleDecl`'s own premise patterns against the fact store
via the kernel's `match_into`/`instantiate` (no bespoke matcher — the
engine reuses the replayer's own first-order matching, run forward instead
of checked backward). Per-fact provenance (rule/axiom + premise fact
refs) is structurally identical to the replayer's own `CertNode` grammar
(confirmed by reading `replay_axiom`/`replay_rule` before writing
`to_certificate`, not assumed) — certificate export is a five-line mirror,
not a translation layer, matching the design-input note's "certificate
nodes materialize lazily on export" literally. Stratified negation is
built and exercised by a standalone test (not yet cited by any ported
theory — recorded honestly as built-but-not-load-bearing). Lattice cells
were deliberately NOT built: no rule in scope needs a quantitative domain;
framed as substrate not yet needed, not a result deficit. Indexing is
head-operator only (the first half of "(head operator, program point)");
program-point sub-indexing is an honest gap, not silently assumed done.

**Soundness-relevant validation:** `engine_test.lua` reproduces the
existing narrow-persist three-leg proof's "leg (b), DERIVES" scenario
(`narrow_persist_v1_test.lua`) end-to-end through the engine — same axiom
citations seeded, the SAME already-declared `RuleDecl` objects from
`flow_narrow_v1`/`assign_effects_v1`/`narrow_persist_v1` registered
unmodified (no rule content rewritten to "port" them — registering an
existing `RuleDecl` into the engine IS the port), run to a 3-fact
fixpoint, exported, and replayed against the REAL kernel replayer:
root-strict accept, taint set identical (the same 3 axioms) to the
hand-built certificate. The engine adds no trust, only bookkeeping the
kernel independently re-verifies. Full `lib/type/v10_kernel/` suite (17
files, 523 assertions) regresses zero.

**Tripwire checked:** no commits since the corroboration proof-of-concept
(`5f698703`) touch `prover_effects.lua`/`prover_narrow.lua` — nothing to
flag, nothing built on.

**Honestly NOT done this iteration (do not read as complete):**
- The thin AST-to-base-facts extractor (elseif chains as ordinary
  control-flow edges/guard facts) — no code written.
- Retiring any walker prover file — none deleted; the 2,126-line figure is
  unchanged.
- Corpus re-measurement (composition-only derivation count vs the 1/569
  baseline) — not run; no elseif-chain extraction exists yet to change
  that number, so re-measuring now would not be meaningful.
- Diagnostics formatting / driver for end-to-end use.

Line-count table (measured, non-blank/non-comment):

| bucket | files | lines |
|---|---|---|
| trusted core (cleanroom) | `term_algebra.lua` + `replayer.lua` + `init.lua` | 928 |
| theory vocab+rules (existing, unmodified) | `addr_v1`, `flow_narrow_v1`, `narrow_pilot_v1`, `effects_spine_v1`, `assign_effects_v1`, `narrow_persist_v1`, `pilot_initial_facts_v1` | 346 |
| **engine (new)** | `engine.lua` | **188** |
| walker provers (not yet retired) | `prover.lua`, `prover_addr.lua`, `prover_narrow.lua`, `prover_effects.lua`, `fixpoint_v1.lua`, `fixpoint_prover.lua` | 2,461 |
| extractor | — | not built |

Total against the 2,000-line budget is not yet meaningful while the
walker provers (the thing the engine is meant to replace) are still
present alongside the new engine — the budget number matters once
extraction is thin and the walkers are retired, not before.

---

## Corroboration engine build — iteration 3, phase 2 (AST→base-facts extractor)

**Status: fable-delegation-tier, not owner-ratified, re-openable.** Built:
`lib/type/v10_kernel/pilot/extractor_v1.lua` + `_test.lua` — the only
component in the engine line that reads a parsed AST. It contains no
analysis: it walks the borrowed cleanroom parser's nodes and seeds ground
base facts into an engine store via `engine.seed` (axiom citations against
the theories' existing schematic reality-boundary axioms). No new signature,
no new axiom, no new rule was declared — every fact it emits already had a
declared vocabulary home.

**HALT (new, blocking, surfaced not filled): the two narrowing rules cannot
both be run FORWARD over the current `guard_selects` judgment.** A walker
chooses which rule to cite; an engine does not — every registered rule fires
on every matching fact. `narrow-select-match` and `narrow-select-rest` share
one premise pair, so a single `guard_selects(Pg,Pb,X,TA)` fact derives BOTH
`holds_at(Pb,X,TA)` and `holds_at(Pb,X,Rest)` at the SAME point. Measured,
not reasoned: seeding one guard fact with both rules registered derives
exactly those two facts. One is false of the source (on the then-branch of
`type(x) == "string"`, x is `string`, not `nil`). The branch ROLE lives
nowhere in the judgment — `flow_narrow_v1.lua`'s own header records that as
deliberate, on the explicit assumption of a prover that chooses. Closing this
is a THEORY-level decision (a branch-role argument on the guard judgment plus
two rules keyed on it, or some other mechanism); it is not a fill-in the
execution tier is entitled to make, so it halts here. Until it is decided:

- The extractor emits `guard_selects` only for the branch the axiom's own
  reading licenses (the branch reached WHEN the guard selects `target_ty`),
  never the complementary one.
- A driver must register `narrow-select-match` and NOT `narrow-select-rest`
  (`extractor_v1.M.SOUND_NARROW_RULES` states this in code).
- Rest-branch narrowing (an `else` block's residual type) is therefore
  unreachable through the engine, and `cf_join`/`narrow-join` facts are not
  emitted at all (they could never fire with only one branch narrowed).
  `prover.lua` still derives rest-branch judgments; that is one reason it
  cannot be retired.

**What the extractor does reach, that no walker did:** guard extraction at
EVERY clause of an elseif chain (the phase-1-flagged corpus blocker), routing
a failing clause's selected branch to the next clause's own test point — a
literally true reading of the guard axiom, so no vocabulary was invented; and
`preserves`-mediated persistence along WHOLE statement chains in every
branch, versus `prover_effects.lua`'s single first statement of a
single-clause `if`. Both were verified by replaying every derived `holds_at`
against the real kernel replayer, root-strict, in the paired test.

**Recorded delegation-tier calls:**
- The declared type enters at the guard point (`exit_of` the clause's test
  path), not at the declaration site. Anchoring at the declaration and
  flowing it forward would need a preservation fact for a NON-STATEMENT span
  (previous statement exit → guard-test exit); both `stmt_preserves_fact` and
  `stmt_preserves` are documented as statement-paired, so that span has no
  vocabulary home. Recorded as a substrate gap; the existing
  re-ground-at-the-guard-point idiom (`prover.lua`, `fixpoint_prover.lua`)
  was followed instead of stretching a reading or minting a judgment.
- Preservation is emitted on the SPINE route (`assign_effects_v1`) only, not
  also on `fixpoint_v1`'s single-theory `stmt_seq`/`stmt_preserves` route:
  both would derive the same `holds_at` facts, and since the engine dedups
  structurally-equal facts, whichever fired first would own the provenance —
  making any composition-only measurement an artifact of evaluation order.
- The "this statement does not write X" negative check runs in the extractor,
  on the AST — the effects theory's own recorded working default ("negation
  internalized in the producing theory"). An unrecognized statement kind ends
  the chain; it is never assumed safe.
- `assign_copies` facts are NOT emitted and `assign-copy-transfer` is not
  registered: the assign-copy-transfer fork (TODO.md:50) is parked pending an
  owner call, and a forward engine would resolve its cross-variable half for
  free. Left untouched.
- `assign_call` facts are not emitted (callee resolution + return-annotation
  parsing): they feed only the loop-invariant line, whose walker cannot be
  retired regardless, so they would add lines against the budget for no
  measured derivation. Recorded as scope, not as done.
- A tracked variable re-declared by a later `local` is DROPPED from scope
  rather than re-tracked — conservative; no fact is emitted about a path
  later occurrences no longer denote.
- `flow_narrow_v1` (`narrow-pilot-v1` v2) and `fixpoint_v1` (v4) declare
  axioms and rules under the SAME (name, version) keys, so they cannot be
  declared into one registry (F11). Any driver picks exactly one. Recorded
  because it constrains every future driver, not just the test.

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
- Portable core spec (named open item 1, above) — undesigned.
- Profile/acceptance-policy object (named open item 2, above) — undesigned.
- Plugin/DX surface (named open item 3, above) — undesigned, downstream of
  item 2.
- Admission discipline / composition-safety formal design (see "Admission
  discipline" section above) — owner-endorsed direction, design pending.
- Everything downstream per the charter (prefix, corroboration — the
  latter has an unratified design-input sketch recorded in the
  "Corroboration/co-solving design-input note" section above, not yet a
  design).
