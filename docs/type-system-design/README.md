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

(R3 and G11 share the same root and the same fix; bounds-spec-gap, R1, and G9
likewise share the missing-bounds-substrate root; all are kept separate per the
`v5-gaps.md` rule against consolidation.)
