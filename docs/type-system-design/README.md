# Unified type-system design

This directory is the **single canonical design** for crescent's type system.
It supersedes the two prior, unreconciled lineages:

- the **rewrite-design lineage** (`docs/typechecker-rewrite-design.md`) — a
  clean-room set-theoretic design (first-class complement, RDNF, MLstruct-style
  constraint solving, narrowing-as-intersection), and
- the **v5 substrate lineage** (`docs/typechecker-v5-operational-semantics.md`
  + `docs/typechecker-v5-constraints.md`) — variadic packs, match types,
  simple-sub bounds ("Spec A"), TLiteral/TRecord, and the dual-interpreter
  parity discipline.

The unified design merges *both*: rewrite-design's lattice and solving algorithm
become the canonical core; the v5 substrate's decisions (packs, match types, the
bound graph, the dual-interpreter discipline) are reconciled into it.

## Standing philosophy (not re-litigated)

`docs/type-system.md` is the **fixed philosophy** and is track-agnostic:
static-by-default; infer aggressively, widen reluctantly; `unknown` never
silently casts away; `any` is a deliberate escape hatch, not a fallback; no
ambient globals; soundness floor non-negotiable. Every module here aligns to it.
It is **not** part of this directory and is never modified by this program; read
it as background.

The binding soundness constraints (the **A-series**,
`docs/typechecker-v5-constraints.md` §A) are the soundness floor every module
must satisfy.

## Status of the absorbed docs

The three docs being absorbed —
`docs/typechecker-rewrite-design.md`,
`docs/typechecker-v5-operational-semantics.md`,
`docs/typechecker-v5-constraints.md` — are **not yet marked SUPERSEDED**. They
are absorbed module-by-module; later modules still cite them as primary sources.
They will be marked SUPERSEDED, with a pointer here, only at **program
completion** (after M-final). Do not retire them early.

## Module map (dependency-ordered)

The ordering **is** the dependency graph: a module may only assume modules above
it. Substrate (M1–M7) precedes consumers (M8 onward). This is the CLAUDE.md
"substrate before consumers" hard rule.

| Module | Name | One-line scope |
|--------|------|----------------|
| **M1** | Core lattice + subtyping algorithm | The set-theoretic lattice with first-class complement `~T`, RDNF, MLstruct-style negation-decomposing constraint solving, narrowing-as-intersection, simple/RDNF dual representation, the emptiness/bail-out procedure, and the bound-graph interface. *The foundation — everything depends on it.* |
| **M2** | Bounds + inference | Polar lower/upper bounds per variable with transitive closure; polar coalescing at generalization; recursive μ via hash-consing; the mandatory in-progress cache. Realizes the M1 bound-graph interface in full. |
| **M3** | Variadic / pack generics | `TPack`/`TPackVar` (single-rest invariant); pack subtyping/equality; arrow args+ret as packs; open/closed alignment (`min(n,m)`); splice semantics. |
| **M4** | HKT / kinds | Kind system + kind inference; type-constructor variables; how kinds gate effect rows, the iterator protocol, and `__index` walking. |
| **M5** | Effect-system architecture | The A/B/C/D choice; effects as a dedicated structurally-compared `TArrow` component (NOT return-pack slot-1); rows/polymorphism; discharge via `pcall`/catch; `Coroutine<Y,S,R>` relationship; propagation; `--:` syntax. |
| **M6** | setmetatable / construction-phase soundness + `__index` | Open→sealed table phase soundness; `__index` chain walking on missing-field lookup; construction-phase mutation safety. |
| **M7** | Record mutability / width-subtyping + field attributes | readonly⇒covariant / mutable⇒invariant variance; width subtyping via open/closed rows; field attributes; named-fields-plus-indexer mixtures; indexer vs open-row distinction. |
| **M8** | Match-type semantics | Symmetric disjoint partition; `_`-as-complement; arm-firing as subtype + emptiness + suspension; capture binding as backward subtyping; suspend-vs-split policy. |
| **M9** | Narrowing / flow + type predicates | Guard→intersection table; branch-exit join as union; user `x is T` predicates; the narrowed-scope second pass. |
| **M10** | Nominal / newtype / opaque | Identity-tagged denotations; newtype/opaque/private; behavior under boolean ops and emptiness (nominal atoms, like skolems). |
| **M11** | Indexed access | `T[K]` as first-class lattice op with distribution; negated keys `T[~"x"]`; the three record-shape semantics; deferred resolution against unbound key-tvars. |
| **M12** | Recursive types | Equi-recursive μ with lazy expansion; closure of the lattice under recursion; hash-consing detection. |
| **M13** | Rank-N / skolemization vs De-Bruijn calculus | Full rank-N via deep-skolemization at subsumption; escape check; reconcile against the v5 De-Bruijn lambda calculus; impredicativity out-of-scope. |
| **M14** | Module / cross-file (`$Require`) | Content-addressed cached interface; manifest dependency tracking; `$Require` reduces to indexed access on a string-literal-keyed module table. |
| **M-final** | Ad-hoc-elimination program | Declarative `pcall`, `coroutine` via `Coroutine<Y,S,R>` + effects, `pairs`/`ipairs` via index-signature generic-for + iterator protocol, effect-head taxonomy, prefix-scoping. The design closes these; deleting handlers is the implementation payoff. |

## Coverage cross-walk

The gating artifact of the whole program is a complete `v5-gaps.md` /
`typechecker-roadmap.md` cross-walk with zero unmapped items and **no item
mapped to a "hardcoded result"** — every closure must be a substrate mechanism.
This table is seeded with the gaps **M1** closes; later modules extend it.

| Gap ID | Source | Closed by | Mechanism (substrate, not result) |
|--------|--------|-----------|-----------------------------------|
| **R3** | `v5-gaps.md` — `T-CSub-Union-R` exact-branch-only (`integer <: (integer \| boolean)` fails; "v5.0 limitation") | M1 | Union-R decided by RDNF emptiness of `A ∧ ¬(B₁∨…∨Bₙ)`, not syntactic branch equality. The decision procedure is the substrate; no per-union special case. |
| **G11** | `v5-gaps.md` — union backtracking admits exact-branch only; no disjunction fallback | M1 | Same RDNF-emptiness substrate as R3. Replaces backtracking search with a single emptiness query — no search, no backtracking. |
| **bounds-spec-gap** *(FULL)* | `v5-gaps.md` — uvar-bounds substrate lives only in `op_sem.lua`, never in the normative spec | M1 (interface) + **M2** (full) | M1 defines the bound-graph as the **variable-handling layer beneath** the RDNF lattice and fixes its interface (§5). **M2** specifies the full mechanism: polar lower/upper bound sets with transitive closure (§3), bind-verifies-bounds + merge-reconciliation (§4), polar coalescing at generalization (§5), μ via hash-consing (§6), the mandatory cache (§7). Meet-of-uppers **not** restored. |
| **R1** | `v5-gaps.md` — `op_sem_alt` has no bounds accumulation; `op_sem` does; dual-interpreter grounding degrades | **M2** | The bounds substrate is specified normatively (M2 §3–§7) so both interpreters encode it **independently**. Cache key, record-before-recursion, and μ-detection key are pinned (M2 §7.3), so the two terminate identically. Resolves "can't close by catching op_sem_alt up" — both re-encode from the spec. |
| **G9** | `v5-gaps.md` — `T-CSub-TVar` routes to `CEq` ignoring bounds | **M2** | The **three variable cases** (M2 §3): `α <: T` records an upper bound, `T <: α` a lower bound, `α <: β` a directional flow edge — all distinct from the `CEq` union-find merge. Subtyping info through a variable is preserved, not collapsed to equality. |
| **"v5.0 limitation" cascade (as a class)** | `v5-gaps.md` R3/G11; `type-system.md` §"G14 dispatcher" — the per-`(tag,tag)` `step_csub` cascade | M1 | The cascade is replaced by structural decomposition + RDNF emptiness over a uniform constructor-plus-boolean representation. New constructors plug in via a decomposition rule + boolean behavior, never a new matrix cell. |
| **G17** | `v5-gaps.md` — variadic generics needed for accurate `pcall`/`coroutine.resume` arg-list/return-pack typing; current approximation correct for known-arity callees only | **M3** | The **pack substrate as a general length-polymorphic mechanism**: `TPack`/`TPackVar` (single-rest invariant, M3 §1), arity-aware equality/subtyping with `min(n,m)` open/closed alignment and the variance-split closed-closed arity — contra (args) exact, co (ret) Lua nil-pad/truncate (M3 §2), the substitution-time splice `R↦pack`/`R↦never` (M3 §3.2), and the arrow `TArrow{args:TPack, ret:TPack}` over packs (M3 §3.1). A callee of **unknown arity** `<F: (...P) -> R>` becomes expressible. **Unblocks M-final** (deletes `build_pcall_ret`/`build_coroutine_create_ret`); consumed there. Name-agnostic substrate, not a `pcall`/`coroutine`-shaped patch. |
| **F1** | `typechecker-roadmap.md` — Higher-kinded types: "the single biggest deficit vs. Haskell … `<F: SomeGeneric>` parses but does not compose — `F` is treated as a type variable, not a type constructor" | **M4** | A constructor variable is a **`UVar` of higher kind, applied via curried `App`, solved by the kind-gated CHKT/HOUnify dispatch** (M4 §3.1–3.2). `F` carries an arrow kind (`Type -> Type`), so `F<A>` composes as a kind-checked application that β-reduces when `F` is known and Miller-unifies when inferred. Functor/Monad shapes expressible. Substrate mechanism (kind + CHKT), name-agnostic. |
| **G2** | `v5-gaps.md` — kind checking exists but kind **inference** does not | **M4** | **Kind inference as first-order equality unification** over `{ Type, (->), KVar }` (M4 §2): the opaque `Lambda` kind tag becomes a real `Kind` with `KVar` leaves; `KEq` decomposes structurally with occurs-check + defaulting-to-`Type`; the CHKT rules are **kind-gated** (M4 §3.2) so arity mismatch surfaces as a precise `kind_mismatch`. Decidable, no bail-out. Substrate mechanism. |
| **G10** | `v5-gaps.md` — variance under Lambda: registry covers named TConst only; anonymous lambdas default invariant | **M4** | **Per-position variance derived from the lambda body's polarity** (M4 §4), reusing M2 §5.1's polarity walk — so `T-CSub-App-Var` is one rule (registry lookup for `Const` heads, structural polarity derivation for `Lambda` heads). A non-trivial `Lambda` in a `CSub` is sound without prior β. Mechanism, not a default or name-keyed hack. |
| **G4** | `v5-gaps.md` — no shift-aware abstraction over nested lambdas; capture-avoiding substitution fails for nested binders | **M4** | **`abstract` made shift-aware** (M4 §5): the Miller-solution abstraction carries a `cutoff` and replaces `UVar(aᵢ.id)` with `Var(n − i + c)` under `c` inner binders, reusing `shift`'s existing cutoff increment. Nested-constructor Miller solutions (`λX. λY. Map<X,Y>`) become representable. Substrate mechanism (reused `shift`). |
| **G1** | `v5-gaps.md` — Miller pattern fragment restricted to UVar/Const args only; complex argument shapes not handled | **M4** | **Full Miller pattern fragment (any rigid distinct argument) specified as the target** (M4 §3.4) — the maximal *decidable, unitary* HO fragment. The decision is pinned: **HKT unification stays in the Miller fragment, does not extend into undecidable full HO unification**, and outside the fragment **reuses M1's bail-out discipline** (`T-CHKT-Park`→`HOUnify`→`T-HOUnify-Stuck` "ambiguous constructor variable" — reject, never guess). Substrate mechanism + justified decidability boundary. |
| **G3** | `v5-gaps.md` — no eta-equivalence in Miller check | **M4** | **η-contraction at the kinding boundary** (M4 §3.5): `λX. F<X>` η-contracts to `F` as a decidable syntactic normalization before CHKT dispatch, so the Miller check compares η-normal forms and treats `λx. F x` and `F` equal **without** a search-reintroducing η-aware unifier. Mechanism (normalization), not a per-case Miller special-case. |
| **F2** | `typechecker-roadmap.md` — Effect tracking: "Walker H landed the yield/throw/pcall plumbing; the missing piece is the **full effect-row inference**" | **M5** | **Effect rows as a dedicated `Row(Effect)` component of `TArrow`** (M5 §3; NOT return-pack slot-1), **subset-on-labels subtyping reduced to M1 `<:`** (M5 §2.4: a row obligation routes to per-label M1 `<:` on `Type`-kinded arguments + set-membership + tail binding), **effect-row inference with effect polymorphism** (M5 §5: body row = row-union over calls, checked subset against the declared row, generalized over an escaping `ρ:Row(Effect)`), and the **determined-fragment / M1-bail-out discipline** (M5 §5.4 — Miller-fragment analogue; under-determined open-open unification rejects via `effect_row_ambiguous`, never guesses). Substrate mechanism, name-agnostic. |
| **adhoc-cluster** *(effect half)* | `v5-gaps.md` — effect-name string-matching `!throw`/`!yield` (5 sites); `Coroutine` 4-level decompose; name-keyed `pcall`/`coroutine` gen-pass dispatch | **M5** (design) → **M-final** (deletes handlers) | **Kinded effect-head taxonomy** (M5 §2.1 — recognition by kind `Effect`, not name spelling) + the **general DISCHARGE rule** (M5 §7.1 — a handler removes a label and reflects it into a value, shape-driven not name-keyed; `pcall`/`create` are two instances) + **declarative pcall/create/resume/yield discharge signatures** (M5 §6, §7.3). The 5 string-match sites, the 4-level decompose, and `effect_stack`/`extract_yield_from_scope` are deleted (M5 §8.4). M5 closes the *design*; M-final deletes the handlers. Name-agnostic substrate, not a name-keyed result. |
| **5.F3-residual** | `v5-gaps.md` — resume-side `S` narrowing incomplete: `coroutine.resume(co, s)` does not bind `S` from the send argument | **M5** | **Both-layers coroutine model** (M5 §6): `S` rides in the body's `!yield<Y,S>` effect row (§6.1), flows through `coroutine.create`'s **discharge** into the `Coroutine<Y,S,R>` value type as a value-type parameter (§6.2), and `resume(co, s)` **binds `S` from the send argument by ordinary value-type subtyping `s <: S`** (§6.3) — no scope inspection, sound under reuse. Substrate mechanism (effect-row label → value-type parameter via discharge), not a result. |
| **G12** *(superseded)* | `v5-gaps.md` (closed `c600a446`) — effect composition via `TIntersection`; F2 enforcement via `CIntersectionMember` | **M5** | **Superseded** by the row component (M5 §8.3): effect composition is **row union** `⊎` (M5 §2.3), not `TIntersection`; the F2 enforcement is a **row subset check** `R_body <: R_decl` (M5 §5.2), not `CIntersectionMember`. G12's intersection plumbing closed effects at the substrate level; M5 re-architects it onto the dedicated row slot per Foundational Decision #2. The `effect_not_permitted` diagnostic is kept; its producer changes. |
| **G6** | `v5-gaps.md` — `μ.__index` chain walk missing: sealed-table missing-field lookup does not traverse the `__index` chain | **M6** | The **`CMetaIndex` chain-walk** (M6 §5): a sealed-table miss walks the `μ.__index` chain, dispatching **structurally** on the shape of `__index` (record / function / `App(F,A)`), reducing an HKT-shaped `__index` via the **M4 reduction interface** (M6 §5.3, M4 §6.2), terminating via a **metatable-identity visited set** (M6 §5.5), and erroring precisely at a terminal miss (M6 §5.4). **Replaces** the v5 `T-CMCall-Sealed-Missing` reject stub. Name-agnostic, structural, terminating substrate — not a name-keyed handler, not a hardcoded result. |
| **H4** *(decided)* | `typechecker-v5-constraints.md` §H4 — sound model of `setmetatable`-post-construction (user-decides; soundness non-negotiable per A1) | **M6** | **Approach A (construction-phase / affine seal)**: `setmetatable` is the **seal** of the open→sealed lifecycle — a table is Open (mutable, off-lattice) during construction and `setmetatable` fixes its type + binds the metatable (M6 §4). The sealed type's observable fields are the own record plus the `__index`-reachable fields (walked lazily, M6 §2/§5). Generalizes the substrate's existing `Φ ∈ {Open, Sealed}` phase map — smallest blast radius; types the D10 corpus (`lib/epoll`) **without** its `--[[:! epoll]]` force cast. Phase discipline (substrate), not a `setmetatable`-shaped special case. **Surfaced for user confirmation** (M6 §11.1 — the alternative is (B) declared-metatable-up-front). |
| **P6** *(interface)* | `v5-gaps.md` — method dispatch edge cases beyond simple `obj:method(...)` not modelled | **M6** (interface) → gen-pass (emission) | M6 fixes the **dispatch interface** (M6 §8): every method dispatch lowers to a §5 `CMetaIndex`/`CMethodCall` + M3 argument-pack subtyping + (for `:`) `self`-unification. The "edge cases" (`obj.method(...)`, field-read of a method, chained `a:b():c()`, union receiver) are **combinations** of these three mechanisms, not new dispatch rules. The closure proper is the gen-pass emission (`constrain.lua`) consuming the M6 interface — a mechanism, not a per-edge-case handler. |
| **Y6** *(shape axis)* | `v5-gaps.md` — `T-CSub-Record-Width` uses `CEq` for named fields on a "fields mutable in v5.0" comment the rule doesn't enforce | **M6** (shape) + **M7** (field variance) | M6 splits the two mutabilities (M6 §6): **shape mutability** (add/remove fields) is **M6's, fully determined by phase and enforced** (`T-CTSet-Sealed-Reject`) — closing the "comment not enforced" half for the shape axis; **field mutability** (reassign a present field → variance) is **M7's** (readonly⇒covariant / mutable⇒invariant, replacing the unconditional-CEq-invariance). M6 guarantees each field has **one fixed type at the seal** (the precondition M7's variance rule needs); M6 does not decide the variance. |

(R3 and G11 share the same root and the same fix; bounds-spec-gap, R1, and G9
likewise share the missing-bounds-substrate root; all are kept separate per the
`v5-gaps.md` rule against consolidation. G17 is closed by M3 and **consumed** by
M-final — M3 supplies the variadic-generics substrate, M-final deletes the
name-keyed handlers that lower onto it. M4's six closures — F1, G2, G10, G4, G1,
G3 — all sit on one substrate, the **kind system + kind-gated CHKT/HOUnify
dispatch**: F1/G2 are the kind system and its inference; G10 is variance derived
from polarity; G4/G1/G3 are the De-Bruijn-calculus reconciliation — shift-aware
abstraction, the Miller-fragment boundary, and η-contraction. M4 also **gates
M5/M6/M11** by reserving the `Effect`/`Row(Effect)` kinds and guaranteeing every
operand reaching the value lattice kinds to `Type`. M5's closures — F2, the
effect half of adhoc-cluster, 5.F3-residual, and the supersession of G12 — all
sit on one substrate, the **`Row(Effect)` arrow component + subset-on-labels
subtyping reduced to M1 `<:` + the general DISCHARGE operation**: F2 is the row
inference; the adhoc-effect-half is the kinded effect-head taxonomy + shape-driven
discharge replacing the name-keyed sites; 5.F3-residual is the both-layers
coroutine model where `S` rides the yield effect row and discharges into
`Coroutine<Y,S,R>`; G12 is the intersection-encoding re-architected onto the row.
M5 also **supersedes** `docs/type-system.md`'s "Effect types … not in scope"
non-goal — the user has overridden it; effects are now in scope and fully
designed (M5). The type-system.md non-goal list is updated at **program
completion** (M-final), not piecemeal; M5 §preamble flags the supersession.

M6's closures — G6, the H4 decision, the P6 interface, and the shape-axis half
of Y6 — all sit on one substrate, the **open→sealed phase discipline + the
metatable-aware `CMetaIndex` chain walk**: H4 is decided as **Approach A**
(`setmetatable` is the seal of the construction phase; surfaced for user
confirmation, M6 §11.1); G6 is the structural, terminating chain walk that
replaces the v5 reject stub, reducing an `App(F,A)` `__index` via M4's §6.2
interface and cutting cyclic chains with a metatable-identity visited set; P6 is
the dispatch *interface* every edge case lowers onto; and the Y6 shape axis is
the phase-enforced "no field added/re-typed after seal." M6 **finalizes no
record-width / field-mutability / attribute rules** — those are M7, which
reconciles its field-variance rules (the *other* half of Y6) with M6's phase
ordering and the §5 lookup.)
