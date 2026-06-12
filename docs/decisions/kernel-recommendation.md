# Decision: typechecker kernel recommendation

**Status: ratified — user-ratified 2026-06-12, in-session.** The recommendation
below is adopted. Implementation proceeds under the v1 scope defined in §3;
re-evaluation triggers in §6 remain active.

_Prior status:_ recommendation — awaited user ratification; nothing adopted
until ratified.

**Date:** June 2026
**Evaluated:** four advocate cases, one per candidate kernel — (1) HM + extensions,
(2) algebraic subtyping (MLsub / simple-sub / MLstruct), (3) set-theoretic /
semantic subtyping (CDuce / Elixir lineage), (4) bidirectional checking + local
inference (Pierce–Turner lineage). Verbatim cases archived in the appendix as the
evaluation record.
**Context substrate:** the kernel is to be *hosted on* the agnostic static-analysis
substrate (`docs/agnostic-static-analysis-design.md`, `-stlc.md`, `-fixpoint.md`,
`lib/type/analysis/stlc.lua`) — untrusted producers, claims, evidence checked by a
smaller trusted checker, with derivations and fixpoint witnesses as the two proven
evidence shapes.

---

## 1. Scoring matrix

Each criterion scored ●●● (strong) / ●●○ (partial) / ●○○ (weak), with a one-line
justification grounded in the repo where a claim was checkable.

| Criterion | (1) HM+ext | (2) AlgSub | (3) SetSub | (4) Bidir |
|---|---|---|---|---|
| **Corpus coverage** (20 families, `typechecker-reference.md`) | ●●○ — native rows/generics/tuples; unions/complement/literals/match are the research-grade jump that *is* candidate 2 | ●●● — the 20 families reduce to `{ <: }` + boolean normalization; `_`-as-complement, narrowing-as-intersection are native | ●●● — native algebra *is* the declared surface algebra (union/inter/complement, `_` = complement definitionally) | ●●○ — structural subtyping incl. unions/width/optional native; **complement + match types are foreign to the core**, each a separate subsystem |
| **Fire fit** (recursive-type stack overflows TODO:826; cast-as-inference solve.lua:579) | ●○○ — classical occurs-check *forbids* recursion; needs the extension. Doesn't touch 579 | ●●○ — equirecursive μ via hash-consing is this lineage's solved baseline; TODO:826 literally requests simple-sub coalescing. Global solver does **not** retire 579 by construction | ●●○ — recursive structural types native (coinductive, cycle-detection *is* termination); retires the 826 class. Global emptiness check doesn't retire 579 | ●●● — no-global-solver makes the 579 class *structurally unreachable* (checking flows expected type in, nothing writes back); needs an explicit cycle-guarded equirecursive subtype relation for 826 |
| **Substrate hosting** (witness-checkable on the analysis ladder) | ●●○ — MGU/solver-substitution is a fixpoint-style whole-assignment witness; principality not locally witnessable (OK, annotations are ground truth) | ●●○ — biunification's final polar bound assignment maps onto the fixpoint rung; **coalescing/simplification + suspension scheduling are trusted producers without per-step witnesses yet**; RDNF emptiness needs ⊥-certificates | ●●○ — subtyping = one emptiness check, witness-friendly (DNF + per-clause vacuity reasons, checker validates locally); recursive subtyping = greatest-fixpoint witness (the validated rung). Counterexamples native → `RejectedClaim.counterevidence` | ●●● — **already rehearsed**: `stlc.lua` var/abs/app *are* bidirectional rules checked as evidence methods that re-derive and validate their own inputs; syntax-directedness is exactly what makes derivations checkable. Hosting question answered for this kernel uniquely |
| **Cost / risk** (timeout-30 rule, twice-failed history, error quality) | ●●○ — set-theoretic extension is research-grade (biunification, type ballooning); but reuses crescent's existing constrain/solve + working rank-1/N | ●○○ — **this well was drunk twice (V4Neg) and did not stabilize; v5 rejected v4 wholesale**; RDNF emptiness EXPTIME vs timeout-30; error-message ballooning is the lineage's defining liability | ●●○ — EXPTIME subtype decision vs timeout-30; **polymorphism is research-grade and UNSHIPPED** (Elixir defers parametric past v1.20, flags recursive/parametric as possibly "unfeasible"); would re-derive crescent's working rank-N on harder ground | ●●● — subtyping concentrated in ONE pure/testable/fuzzable function; industry-maximal prior art (TS/Flow/Scala3/Swift); honest cost: needs annotations HM wouldn't (you can't have both no-write-back and HM-complete inference) |
| **Posture** (no-special-casing, caps, data-over-code) | ●●○ — keeps v3 architecture; narrowing is an orthogonal bolt-on (a seam, not a reduction) | ●●● — algorithm "has nowhere to put a special case" (the no-special-casing constraint served structurally) — **but** that exact claim was the v4 promise that failed by accumulation | ●●● — one emptiness primitive; narrowing/match/exhaustiveness all collapse to it; counterexamples as data | ●●● — every rule is syntax-directed evidence (data over code); solvers pushed to the untrusted-producer side by construction |

**Reading of the matrix.** No single column dominates. Candidate 2/3 win *type
algebra* and *corpus coverage*; they lose *cost/risk* — 2 to its own twice-failed
history and EXPTIME-vs-timeout tension, 3 to unshipped research-grade polymorphism
that would regress working rank-N. Candidate 4 wins *substrate hosting*, *cost/risk*,
and the *579 fire* — and loses *type-algebra coverage* (complement and match types
are explicitly outside its core). Candidate 1 is, by its own advocate's admission,
"HM + extensions becomes the algebraic-subtyping artifact" — i.e. it collapses into
candidate 2 the moment it reaches the set-theoretic universe the corpus actually
uses.

---

## 2. Recommendation

**Recommend a principled hybrid: bidirectional checking *discipline* (candidate 4)
as the kernel spine and trust architecture, over a cycle-guarded equirecursive
structural subtype relation that grows toward the set-theoretic lattice
(candidates 2/3) on demand — with every solver kept on the untrusted,
witness-producing side of the substrate boundary.** The cases decompose cleanly
along two orthogonal axes — *checking discipline* vs *type algebra* — and the
evidence points to different winners on each, which is precisely the signature of a
hybrid being right rather than a single candidate. The decisive asymmetry is the
substrate: `stlc.lua` proves the bidirectional kernel is *already hosted* — its
rules are evidence methods a smaller checker re-derives and validates — whereas
every global-solver candidate must still invent per-step witnesses for coalescing,
simplification, and suspension scheduling that do not exist yet. Bidirectionality
also retires the `solve.lua:579` cast-as-inference fire *by construction* (checking
mode flows the expected type inward; nothing writes back to an inference variable),
which is the same statement as CLAUDE.md's "casts must never be inference sources."
The type algebra is then a property of the *subtype relation*, not the kernel: a
single pure function, fuzzable and witness-checkable in isolation, that starts
structural+equirecursive and is extended toward union/intersection/complement
exactly as far as the corpus forces and the timeout-30 budget allows. This is *not*
a rejection of `docs/typechecker-rewrite-design.md` — that MLstruct design survives
as the **specification of the subtype relation's target lattice and its emptiness/
RDNF machinery**, relocated from "the kernel" to "the untrusted producer behind the
subtype function." Choosing the hybrid honors the one piece of history that binds
hardest: the algebraic kernel was tried twice as *the whole checker* and failed by
ad-hoc accumulation; hosting the same algebra as an untrusted, witness-checked
producer behind a bidirectional spine is the structurally different bet the v5
substrate was built to enable. The corpus's pervasive annotation density
(770/856 lib/ files carry at least one `--:` annotation — measured 2026-06-12;
see §5.2 benchmark below) pre-pays bidirectionality's one real cost, the
annotation burden, making this the lowest-risk path to a kernel that still
reaches the declared lattice.

---

## 3. v1 scope (precise — this is the fence against "all four candidates")

**Spine: candidate 4's v1 list is the skeleton.** v1 is a synth/check kernel whose
rules are evidence methods extending `stlc.lua`'s shape, plus ONE subtype relation
function. Concretely v1 contains, and contains only:

1. **Synth/check evidence methods** (`synth ⊢ e ⇒ T`, `check ⊢ e ⇐ T`) modeled on
   `stlc.lua`'s var/abs/app — each a checker that re-derives its conclusion and
   validates its own inputs, with deep premise nesting already proven by the STLC
   rung.
2. **Annotations and casts as checking boundaries** — `--: T` / `--[[: T]]` switch
   to checking mode; this is what retires `solve.lua:579` by construction. `--[[:! T]]`
   force casts remain the escape hatch, never an inference source.
3. **ONE subtype relation** — a single pure, cycle-guarded function over:
   primitives + the `integer <: number` lattice; literal singletons; structural
   tables (width, optional, readonly, indexers, `...` open rows); functions
   (contravariant params, covariant return, multi-return as return-position tuple);
   tuples; **unions** (check-against-each); **intersections**; and **equirecursive
   μ from day one via hash-consing** (this is the TODO:826 fix — structural identity
   → tid identity makes cycle detection sound and retires the stack-overflow class).
4. **Local generic instantiation at call sites as witnessed evidence** — the one
   real inference in the kernel: an untrusted producer proposes a finite
   substitution, the checker validates the app rule under it (post-hoc witness,
   the fixpoint-rung pattern).
5. **A separate flow-narrowing layer** for the truthy/falsy/`type()`/equality
   guards, layered orthogonally (TypeScript's architecture) — expressed as
   intersection-with-atom against the v1 subtype relation, *without* requiring
   complement in v1 (the falsy branches that need `~T` are deferred; see below).
6. **The fire corpus (hamt, proto, prolog, protocol_buffer, taskgraph) as a
   falsification suite**, plus a subtype-relation performance harness (§5).

**The MLstruct rewrite-design doc's role in v1:** it is the *target spec for the
subtype relation*, consumed incrementally. v1 implements the structural +
equirecursive + union/intersection fragment of its lattice. Its complement /
RDNF / biunification / coalescing machinery is **out of v1** and lives behind the
subtype-function boundary as the un-deferral target.

### Explicitly deferred (with un-defer triggers)

| Deferred item | Lineage | Un-defer trigger (the evidence that promotes it) |
|---|---|---|
| **Complement `~T` as a first-class lattice operation** (and the full falsy-branch narrowing it enables) | 2/3 | A corpus count showing flow-narrowing's `T & ~Atom` falsy branches are load-bearing in real `lib/` code (not just example files), AND a ⊥-certificate witness shape for emptiness that the substrate checker can validate locally. Until both, falsy branches stay at the pre-complement approximation. |
| **Match types** (`match X { ... }`, `_` = complement) | 2/3 | Complement landed (prerequisite) AND a measured corpus demand for type-level match beyond the existing `$`-intrinsics. Implemented as the rewrite-design §5 reduction (two subtype queries + emptiness), never as per-arm code. |
| **MLstruct RDNF / biunification / coalescing** as the subtype producer | 2 | The structural subtype function hits an expressiveness wall the corpus forces (a real `lib/` type the v1 fragment cannot decide) AND the EXPTIME-emptiness benchmark (§5) clears the timeout-30 budget on the actual corpus. This is the moment `typechecker-rewrite-design.md` is consumed wholesale behind the boundary. |
| **Parametric/semantic-subtyping polymorphism** (candidate 3's crown) | 3 | Only if the structural+local-instantiation inference proves insufficient on the corpus. Note: crescent already has working rank-1/rank-N; v1 must not regress it, so this is a *replacement* bar, not a *gap* — high evidence required. |
| **Rank-N depth beyond local instantiation, HKT, effects** | all | Rank-N: a corpus site that local instantiation cannot check. HKT: a kinding layer independently justified (today an acknowledged gap per reference §HKT). Effects: a second effect beyond a hypothetical first, per rewrite-design §3.1's own "don't design the row calculus upfront." |

The fence: v1 is candidate 4's kernel + the structural/union/intersection/μ fragment
of candidate 2's lattice. It is **not** RDNF, **not** complement, **not** match types,
**not** parametric semantic subtyping, **not** HKT/effects. Each of those is a named,
isolated extension behind a single function boundary with a written un-defer trigger.

---

## 4. What survives from existing in-repo work

- **`docs/typechecker-rewrite-design.md` (MLstruct design):** survives as the
  *specification of the subtype relation's target lattice* and its emptiness/RDNF/
  coalescing machinery — **relocated** from "the kernel" to "the untrusted producer
  behind the subtype function." Its §1 lattice, §2 decomposition rules, §5 match-type
  reduction, and §7 narrowing-as-intersection are directly reused as the extension
  roadmap. What does *not* survive is its framing of biunification/coalescing as the
  *top-level inference engine*; the hybrid demotes those to witness-producing
  producers. Estimate: the lattice/algebra content (≈§1–§2, §5, §7) survives largely
  intact; the "this is the whole checker" architectural framing (§0, §8) is
  superseded by the hosting model.
- **`lib/type/analysis/stlc.lua` and the substrate:** survives as the literal
  foundation — the kernel extends its evidence-method shape.
- **Working rank-1 / rank-N machinery (TODO H-series):** survives as a *correctness
  bar* — v1 must not regress it. Local instantiation is the v1 mechanism; fuller
  rank-N is deferred but the existing behavior is the floor.
- **`solve.lua:579` and the cast-as-inference fire (TODO lines 748/784/786):**
  retired by the kernel's construction, not patched — the destructive bidirectional
  `unify` has no analogue in a checking-mode kernel.
- **The missing `docs/typechecker-hm-fit-audit.md`:** confirmed absent from the tree
  (verified). The "HM rejected as substrate" reasoning is genuinely lost; candidate 1's
  reconstruction (classical HM rejected, constrain/solve architecture retained) is
  plausible but **unverifiable from the repo** and is recorded as advocate inference,
  not established fact.

---

## 5. Risks and early-warning benchmarks

**Run these BEFORE any commitment to building, not after.**

1. **Subtype-relation performance on the real corpus (highest priority).** The
   EXPTIME-emptiness / timeout-30 tension is the most likely failure mode of the
   deferred algebraic extensions, and a real risk even for v1's union handling.
   *Benchmark:* exercise the v1 structural+union+μ subtype function against every
   adversarial type in the fire corpus (hamt/proto/prolog/protocol_buffer) and the
   widest union/intersection types `grep` finds in `lib/`. Any single query
   exceeding the timeout-30 budget is a soundness/termination signal (per CLAUDE.md),
   not a "slow case" — it blocks the corresponding extension's un-defer.
2. **Annotation-density reality check.** Bidirectionality trades inference for
   annotations. *Benchmark:* sample unannotated polymorphic intermediates across
   `lib/` and confirm the synth direction covers them without demanding annotations
   HM would not. If a meaningful fraction needs new annotations, the cost estimate
   was wrong — re-weigh against candidate 1/2's principal inference.

   **Measured 2026-06-12** (pre-build, as §5 mandates):

   | Metric | Count |
   |---|---|
   | Total `.lua` files under `lib/` (excl. `*_test.lua` and corpus fixtures) | 856 |
   | Files containing at least one `--:` annotation | 770 (90%) |
   | Files defining module-boundary functions (`M.foo = function` / `function M.foo`) | 621 |
   | Of those: all module-fn defs have an adjacent `--:` within 3 preceding lines | 296 (48%) |
   | Of those: at least one module-fn def lacks an adjacent `--:` | 325 (52%) |

   *Method:* `find lib/ -name "*.lua" ! -name "*_test.lua" ! -path
   "lib/type/analysis/corpus/*"` for the file list; `grep -l -- '--:'` for (b);
   `grep -E '^(M\.foo = function|function M\.foo)'` (generalised) for module-fn
   detection; awk 3-line lookback for adjacent-annotation classification.
   "Adjacent" = any `--:` line in the 3 lines immediately preceding the `function`
   keyword line.

   *Assessment:* The 90% file-level annotation density comfortably supports the
   "local inference suffices" premise — bidirectionality's cost is pre-paid at the
   file level. The module-boundary picture is more granular: 296/621 files have
   every exported function annotated; 325/621 have at least one gap. The gaps are
   real (spot-checked: `lib/test/arb.lua` has 4 unannotated module functions out
   of 17), but the density is high enough that the synth direction will cover the
   majority of call sites without new annotation demand. This does not trigger the
   §6 re-evaluation condition ("substantially more annotation than the corpus
   already carries"). Gaps are work items for the annotation pass that v1 build
   work will drive naturally.
3. **Witness-checker overhead on the substrate.** Every kernel rule produces evidence
   a smaller checker validates. *Benchmark:* derivation-checking time on the deepest
   real files vs the tsgo bar. If post-hoc witness validation dominates, the hosting
   advantage erodes.
4. **Falsy-branch approximation soundness.** v1 narrows truthy branches by
   intersection but defers complement. *Check:* enumerate the `lib/` flow sites whose
   falsy branch genuinely needs `~T`; confirm the v1 approximation is sound (wider,
   never unsound). If any site is made *unsound* by the deferral, complement un-defers
   immediately.

---

## 6. Re-evaluation triggers

Revisit this recommendation if any hold:

- The subtype-performance benchmark (§5.1) shows even the v1 structural+union
  fragment cannot clear timeout-30 on the corpus — the *whole* set-theoretic
  direction is then in question, not just the deferred extensions.
- The annotation-density check (§5.2) shows bidirectionality demands substantially
  more annotation than the corpus already carries — candidate 1/2's principal
  inference regains weight.
- A third independent attempt at the algebraic kernel is proposed as *the kernel*
  (not as a witness-producer) — the twice-failed history (V4Neg) makes this require
  explicit justification of what is structurally different this time.
- The substrate's witness model changes such that global-solver outputs become
  cheaply checkable per-step — this would lift candidate 2/3's main hosting penalty
  and could promote them from producer-behind-the-boundary to kernel.
- The missing HM-fit audit resurfaces and contradicts the reconstructed "classical
  HM rejected, architecture retained" reasoning.

---

## Appendix: evaluation record — the four advocate cases

**Case 1 — HM + extensions (qualified accept).** Accepts HM's two-phase
constrain/solve *discipline* (already crescent's v3 architecture), not classical
HM's type universe. Concedes the corpus's set-theoretic universe (unions, complement,
literals, tag-narrowing) forces the MLsub/MLstruct extension — at which point
"HM + extensions" and "algebraic subtyping" become the same artifact. Coverage:
~7 native, ~5 elaborated, ~7 research-level, 0 unexpressible. Confirmed the cited
`typechecker-hm-fit-audit.md` does not exist (the rejection reasoning is lost).

**Case 2 — algebraic subtyping (MLsub/simple-sub/MLstruct).** Strongest paper fit;
the *only* candidate with a complete in-repo clean-room design
(`typechecker-rewrite-design.md`). 20 families reduce to `{ <: }` + boolean
normalization; equirecursive μ via hash-consing is its solved baseline (TODO:826).
Decisive counterweight: this well was drunk twice (V4Neg) and did not stabilize; v5
rejected v4 wholesale. Argues the algorithm wasn't what failed — the missing
substrate-hosting discipline was, and now exists. Resists hosting: coalescing/
simplification/suspension are trusted producers without per-step witnesses yet;
RDNF emptiness is EXPTIME.

**Case 3 — set-theoretic / semantic subtyping (CDuce / Elixir).** The only candidate
whose native algebra *is* crescent's declared surface algebra; occurrence typing is
its home turf, production-proven in Elixir v1.20 (June 2026); recursive structural
types and counterexample diagnostics native (→ `RejectedClaim.counterevidence`).
Decisive risks: polymorphism is research-grade and *unshipped* (Elixir defers
parametric past v1.20; flags recursive/parametric as possibly "unfeasible"), and it
would re-derive crescent's working rank-N on harder ground; EXPTIME decision vs
timeout-30.

**Case 4 — bidirectional + local inference (Pierce–Turner).** Best-matched-to-reality:
the annotation-burden objection is pre-paid (770/856 lib/ files annotated — measured
2026-06-12; see §5.2);
the no-global-solver stance makes the `solve.lua:579` fire structurally unreachable;
and the substrate has *already rehearsed* the kernel — `stlc.lua`'s var/abs/app are
bidirectional rules whose syntax-directedness makes derivations checkable evidence.
Honest weaknesses: match types / type-level computation foreign to the core (a second
subsystem); complement requires a research-grade set-theoretic subtype relation
(isolated in one function); you cannot have both no-write-back and HM-complete
inference.

---

### Verification log (what the judge checked vs took on advocate authority)

**Verified against the repo:**
- `docs/typechecker-rewrite-design.md` exists and is the complete MLstruct-derived
  clean-room design Case 2 described (read in full; derivation from simple-sub +
  MLstruct + CDuce confirmed in §0, §2.1, §8).
- `docs/typechecker-hm-fit-audit.md` is **absent** from the tree (Case 1's claim of
  lost reasoning confirmed).
- TODO:826 is verbatim the hash-cons-unions-for-sound-cycle-detection item, and the
  recursive-type stack-overflow class (hamt/proto/prolog/protocol_buffer) is real
  and documented.
- `solve.lua:579` is the documented destructive-`unify` cast/param-binding site
  behind the "casts must never be inference sources" fire (TODO lines 748/784/786/788),
  with attribution already corrected in-repo (`try_unify`/`types_overlap` exonerated).
- `lib/type/analysis/stlc.lua` is bidirectional in shape: var/abs/app as evidence
  methods, a checker that re-derives conclusions and validates its own inputs (never
  trusting their shape), with deep premise nesting (abs over has_type, app over two).
  Case 4's central hosting claim holds.
- The substrate vocabulary (`agnostic-static-analysis-design.md`): producers
  untrusted by default, evidence checked by a smaller checker, "solver result with
  checkable witnesses" an explicit evidence form, and the fixpoint rung
  (`-fixpoint.md`) validates a whole-assignment witness post-hoc — the pattern all
  three solver candidates map onto.
- `typechecker-reference.md` exposes ~20 type families across the surface (section
  heads confirmed).

**Measured (2026-06-12; replaces advocate figures):**
- Annotation density — see §5.2. Advocate figures (843/1469 and 841-file) were
  approximate; the re-count supersedes them. The order of magnitude held.
- The V4Neg twice-failed history and its derivation from MLstruct §3.2 + simple-sub
  watchers (Case 2) — CLAUDE.md's ad-hoc-accumulation rule names the v1→v4 failure,
  corroborating the pattern, but the specific `typechecker-v4-deferred-constraints-design.md`
  derivation was not opened.
- Elixir v1.20's production occurrence typing and its deferral of parametric
  polymorphism (Case 3) — external claim, not repo-checkable.
- The published external-reference characterizations (simple-sub <500 lines, POPL'25
  Boolean-Algebraic Subtyping, Dunfield–Krishnaswami survey, Peyton Jones et al. 2007)
  — taken as cited.
