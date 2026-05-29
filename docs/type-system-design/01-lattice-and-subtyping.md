# M1 — Core lattice and subtyping algorithm

*Normative module spec of the unified type-system design. Foundation: every
other module assumes this one. Aligns to `docs/type-system.md` (philosophy,
fixed) and satisfies the soundness floor of
`docs/typechecker-v5-constraints.md` §A.*

Primary sources reconciled here:

- `docs/typechecker-rewrite-design.md` §1–4 (the lattice, RDNF, MLstruct-style
  constraint solving with negation-based decomposition, the simple/RDNF dual
  representation). **The canonical core.**
- `docs/typechecker-v5-operational-semantics.md` § "Subtyping
  (variance-respecting)" and § "Simple-sub bounds (normative)" (the v5 substrate
  being re-architected, and the Spec-A bound graph reconciled as the variable
  layer beneath the lattice).
- `docs/typechecker-v5-constraints.md` §A (the soundness floor).
- `docs/type-system.md` § "Union, intersection, and complement", § "Decisions —
  Implementation Details / Operational Semantics Dispatch" (the cascade
  re-architected here).

External references (as in rewrite-design §0): simple-sub (Parreaux, ICFP 2020);
MLstruct (Parreaux & Chau, OOPSLA 2022); semantic subtyping
(Frisch/Castagna/Benzaken).

---

## 1. The lattice

### 1.1 Type constructors

A **type denotes a set of runtime values**; the type operators are the
boolean-algebra operations on those sets (rewrite-design §1). The constructors:

- **Primitives.** `nil`, `boolean`, `number`, `integer`, `string`, `cdata`,
  with `integer <: number`. AST: `Const(name)`.
- **Literals.** `42`, `"GET"`, `true`. A literal is a singleton subtype of its
  base primitive. AST: `Literal{base, value}` (the v5 TLiteral node;
  `type-system.md` § "Literal types"). `42 <: integer <: number`,
  `"GET" <: string`, `true <: boolean` are lattice edges, **not** `$`-name
  string matches.
- **Top / bottom.** `unknown` (top; callers must narrow), `never` (bottom;
  uninhabited). `any` is **distinct** from `unknown` — a bilateral escape hatch,
  not a top type, and per the philosophy `any` does not appear in normal code
  (constraints §A2, §A3).
- **Records.** `Record{fields, indexes, row}` — the v5 TRecord three-region node
  (named fields with per-field attributes, index signatures, open/closed row).
  Detailed subtyping deferred to **M7**; M1 treats a record as one positive
  constructor shape for normalization purposes.
- **Arrows.** `Arrow(args, ret)`, contravariant args, covariant return; args and
  ret are **packs** (M3). The effect component is a dedicated arrow slot (M5),
  not a return-pack member.
- **Packs.** `Pack{items, rest}` — tuples, multi-return, varargs (M3).
- **Applications / constructors.** `App(f, a)` — `Foo<T>` etc.; variance per the
  head's registry entry (M4/M7).
- **Fixed points.** `Mu(X, T)` — equi-recursive, lazy expansion (M12).
- **Quantifiers.** `Forall(αs, T)`, `Skolem(α, level)` (M13).
- **Type variables.** `UVar(α)` carrying mutable bounds (see §5; full in M2).
- **Nominal atoms.** newtype/opaque/private — identity-tagged; treated by the
  lattice as opaque atoms, like skolems (M10).
- **Indexed access.** `T[K]` — first-class lattice op (M11).

### 1.2 Boolean operators — first-class, with complement

The lattice is closed under three operators (`type-system.md` § "Union,
intersection, and complement"; rewrite-design §1.2):

- **Union** `A | B` — set union. AST `Union(xs)`.
- **Intersection** `A & B` — set intersection. AST `Intersection(parts)`.
- **Complement** `~T` — the set of values not in `T`. AST `Neg(T)`.

`~T` is **first-class**: it may appear inside any operator, and the system
reasons under boolean-algebra laws. The complement laws are **normative**:

- **Involution:** `~~T ≡ T`.
- **De Morgan:** `~(A | B) ≡ ~A & ~B`; `~(A & B) ≡ ~A | ~B`.
- **Top/bottom duals:** `~never ≡ unknown`; `~unknown ≡ never`.
- **Complement / self-cancellation:** `T & ~T ≡ never`; `T | ~T ≡ unknown`.

`~` (not `!`) is the surface token, because `!` is reserved for the force-cast
`--[[:! T]]` (`type-system.md`). Complement is what makes the match-type `_` arm
well-defined: `_` desugars to `~(P₁ | … | Pₙ₋₁)` (M8); it is also the falsy-branch
operator for narrowing (§4).

This is a **deliberate addition** over the implemented v5 substrate, which has
**no complement node**: `op_sem.lua` carries `union`, `intersection`, `arrow`,
`record`, `const`, `literal`, `pack`, `app` — but no `Neg`. Adding `Neg` is part
of M1's blast radius (§7).

### 1.3 Subtyping is the primary relation

`A <: B` means "the set denoted by A ⊆ the set denoted by B" (rewrite-design
§1.3). Every other notion — assignability, conformance, overload resolution,
exhaustiveness, narrowing — reduces to subtyping queries. There is **no separate
assignability relation**, and equality is `A <: B ∧ B <: A`. This matches the
v5 constraint vocabulary already (`CSub`, with `CEq` a derived pair) and is
preserved.

---

## 2. Two representations: simple types and RDNF

Following Parreaux's distinction (rewrite-design §4.1–4.2), M1 mandates **two
representations**, used at different times:

### 2.1 Simple types — the inference-time form

A *simple type* is a primitive, a literal, a constructor application, a `UVar`
with mutable bounds, a boolean combination (`Union`/`Intersection`/`Neg`), a
quantifier wrapper, or a `Mu`. **Simple types are not normalized eagerly.**
Constraint solving manipulates them raw; RDNF is computed only when a decision
point forces it (§3.3) or when a type is observed (error, hover, generalization
checkpoint).

This is **load-bearing for performance** (rewrite-design §4.1): eagerly
normalizing every intermediate constraint to DNF blows up exponentially on
union/intersection-heavy programs. It is also why M1 keeps the v5 substrate's
on-the-fly structural decomposition (§3.1) as the common path: most constraints
never need RDNF.

### 2.2 RDNF — the solver/display normal form

**Restricted disjunctive normal form** (MLstruct §5.2; rewrite-design §4.2). A
type in RDNF has the shape

```
⋁_i ( P_i_fn? ∧ P_i_rec? ∧ P_i_tag? ∧ ⋀_j ¬N_ij )
```

where each disjunct contains **at most one positive arrow shape, at most one
positive record shape, at most one positive nominal tag**, plus a set of negated
atoms. Reductions are normative:

- Incompatible positive intersections (two distinct top-level constructors of the
  same kind; two unrelated nominal tags) reduce to **`never`** (`⊥`).
- Cross-shape identities (a value cannot be both a function and a record) make
  cross-shape intersections `never`, and the dual unions that exhaust the
  universe reduce to **`unknown`** (`⊤`).
- `T & ¬T` reduces to `never` within a disjunct.

**Level indexing.** RDNF is indexed by a level (rewrite-design §4.2, §2.1):
**level-0** RDNF has all class/alias/match-type heads expanded; **level-1**
retains them. Emptiness (§3) is decided at level-0; display may use level-1 to
keep names. The level is the termination knob for alias/recursion expansion
(M12).

**Dual representation, normatively (rewrite-design §4.1–4.2):** the solver works
on **simple types**; it computes RDNF for a sub-expression **only when forced**.
The user-facing "compact type" is RDNF plus a simplification pipeline (coalescing
removed variables, hash-consing recursive types, distributivity/factorization).
Hash-consing the post-simplification form gives structural equality that the
subtyping cache, match-arm dispatch, and IDE hover all rely on.

---

## 3. The subtyping algorithm

The chosen algorithm is **MLstruct-style constraint solving**: constraint
generation plus per-variable polar bound propagation, with **negation-based
decomposition** as the mechanism for everything the naive cascade special-cased
(rewrite-design §2.1). The constraint vocabulary is **exactly `{ <: }`**
(rewrite-design §3): equality is the conjunction of both directions; match-arm
matching is subtyping plus emptiness (M8). There are no `is-a-function`,
`supports-arithmetic`, `is-iterable` predicate constraints — those are *uses*
that reduce to `A <: <structural shape>` (rewrite-design §3). **The algorithm
has nowhere to put a new predicate**; this is how the no-special-casing hard
constraint is upheld by construction.

### 3.1 Structural decomposition (the common path)

When both sides of `A <: B` are non-variable, decompose by structure
(rewrite-design §2.2):

- `Arrow(A) <: Arrow(B)` → params contravariant, returns covariant (via pack
  subtyping, M3).
- `Record <: Record` → width + per-field variance (M7).
- `App(n, …) <: App(n, …)` → per-position variance from the head registry (M4/M7).
- `A | B <: C` → `A <: C` ∧ `B <: C`.
- `A <: B & C` → `A <: B` ∧ `A <: C`.
- Two lattice atoms (`integer <: number`, literal widening, reflexivity) → a
  single `atomic_subtype` consultation against the fixed base lattice. This is
  the v5 Spec-A `atomic_subtype` relation (op_sem.lua), **kept**: it is already a
  single relation, not a cascade, and M1 reuses it as the atom oracle.
- Mismatched constructors of incompatible shape → `never`-emptiness ⇒ error.

This path is **the same on-the-fly decomposition** the v5 substrate already uses
and that MLstruct §3.3.2 endorses for performance: full RDNF is invoked only when
the constraint's shape requires it (next).

### 3.2 Variables and the move-across-via-negation rule

Constraints of the shape `τ₁ <: τ₂ ∨ α` or `α ∧ τ₁ <: τ₂` cannot decompose by
structural recursion alone without losing information or backtracking. MLstruct
resolves this by **moving the non-variable part across the turnstile using
negation** (rewrite-design §2.4; MLstruct §3.3.1):

- `τ₁ <: τ₂ ∨ α`  ⟹  `τ₁ ∧ ¬τ₂ <: α`   (a new **lower bound** for `α`)
- `α ∧ τ₁ <: τ₂`  ⟹  `α <: τ₂ ∨ ¬τ₁`   (a new **upper bound** for `α`)

When both apply, either choice is sound, but they build *different* bound-graph
shapes (one adds a lower bound, the other an upper). **Deterministic tie-break
(normative): prefer the lower-bound form** — i.e. apply the `τ₁ ∧ ¬τ₂ <: α`
transform when both are applicable to the same constraint. This is mandated so
that both interpreters (`op_sem.lua` and `op_sem_alt.lua`) build byte-identical
bound graphs and the parity discipline holds; leaving the choice open would let
the two diverge. **This is the central use of negation in the solver**: it lets
union/intersection constraints involving variables make progress without
backtracking, preserving principal types. It is also precisely
what the v5 substrate could not do — `op_sem.lua`'s `T-CSub-Union-R` admits only
exact branch equality and `T-CSub-Intersection-Decomp` errors when all parts are
uvars (`all_parts_unresolved`), because it has no `¬` to move across. M1 replaces
both with this rule. (Bound storage and propagation: §5, full in M2.)

### 3.3 Emptiness — `A <: B` as `A ∧ ¬B <: never`

For constraints where structural decomposition does not directly settle the
relation — in particular **non-trivial negation, RHS-union subtyping, and
match-arm dispatch against negated atoms** — the subtype query reduces to an
**emptiness decision** (rewrite-design §2.2, §5.1; MLstruct §5.3):

```
A <: B   ⟺   dnf₀(A ∧ ¬B) ≡ never
```

The constraint is normalized to the form `τ_con <: τ_dis` (rewrite-design
§2.2/§3.3.2) where `τ_con` is `⊤`, `⊥`, or an intersection of at most one
nominal tag, one arrow shape, one record shape, and `τ_dis` is `⊤`, `⊥`,
`(arrow) ∨ #C`, `{record} ∨ #C`, or `#C ∨ #C'`. Reaching this shape always leaves
**at most one matching pair** across the two sides, so the obligation reduces to a
single smaller subtype obligation on matching constructors — losslessly,
preserving principal types. Different constructor shapes are disjoint by design,
and same-shape obligations reduce by §3.1.

**Naked negation is a thinking caveat, not a restriction** (rewrite-design §2.2,
MLstruct §2.2.5 fn 10): a standalone `¬(arrow)` or `¬{record}` denotes a large,
unenumerable set, but in crescent's actual uses — narrowing, match `_`,
discriminated-union dispatch — negation **never appears naked**. It appears in
intersection with a positive type, where it removes one alternative from a known
union. Worked example (rewrite-design §2.2):

```
(A | B | (A → B)) ∩ ¬(A → B)
  = (A ∩ ¬(A → B)) | (B ∩ ¬(A → B)) | ((A → B) ∩ ¬(A → B))   -- distribute
  = A | B | never                                            -- self-cancel + cross-shape
  = A | B
```

**Normative simplifier discipline** (rewrite-design §2.2): the simplifier MUST
distribute intersection over union and MUST recognize `T ∩ ¬T = never`. With
those two rules, `(… | T | …) ∩ ¬T` collapses to `(… | …)` automatically. No
surface-syntax restriction on `~T` is necessary or appropriate.

### 3.4 The emptiness decision procedure and bail-out (normative)

DNF emptiness is worst-case exponential in the number of conjuncts. The
procedure is therefore **deferred until forced, not universal** (rewrite-design
§2.2, §9.2.7). M1 specifies it normatively:

1. **Fires only at decision points.** Emptiness is computed only at: (a) subtype
   queries involving non-trivial negation; (b) match-arm dispatch against negated
   atoms (M8); (c) narrowing-simplification of complex inputs (§4). Ordinary
   constraints take the §3.1 structural path and never trigger it.
2. **Cached on the post-simplification form.** Results are memoized keyed on the
   hash-consed post-simplification RDNF (§2.2), so repeated queries on the same
   normalized shape are O(1). This generalizes the v5 substrate's existing
   `subcache` (op_sem.lua) — which keys `CSub(L,U)` obligations by structural
   head hash — to also key emptiness results.
3. **Bounded by a deterministic step count (normative).** A single emptiness
   decision is bounded by a **machine-independent, reproducible step budget** —
   **not** wall-clock. The budget is a count of **RDNF conjuncts expanded /
   normalization steps** taken during the one decision; **the default is
   `4096`**. This count is **part of the normative semantics**: both interpreters
   (`op_sem.lua` and `op_sem_alt.lua`) use the *identical* budget and therefore
   bail at the *identical* point, so the parity discipline's byte-identical
   results hold (a wall-clock bound would make the two interpreters' bail-out
   points diverge — rejected). On exceeding the budget it **does not loop or
   guess**: it emits a diagnostic that **names the originating expression** (the
   source span carried on the constraint's provenance — constraints §B11). The
   diagnostic class is `emptiness_check_timed_out`, carrying the originating span
   and the normalized shape (truncated) for the report.
4. **Conservative post-timeout disposition.** A timed-out **subtype query** is
   treated as **failed** (not a subtype) — the sound direction: it reports a type
   error at the originating expression rather than silently accepting an
   unverified relation (this honors the soundness floor §A1 and "`unknown` never
   casts away" §A2 — we never admit an unproven `<:`). A timed-out **match-arm
   disjointness** check is treated as **not-disjoint** (the arm is conservatively
   kept live / suspended; M8), again never silently committing. Both dispositions
   reject rather than accept; neither widens to `any`. This is consistent with
   §A14: exceeding a bound is a **diagnostic**, not a slow success.

The "competitive with tsgo" bar (constraints §E3) is met by **avoiding
gratuitous checks** (most constraints stay on the structural path), not by
adopting a more restricted boolean algebra. The fallback of restricting the
boolean algebra is **rejected** (rewrite-design §9.2.7).

> **Soundness-floor reconciliation.** §A14 says a typecheck exceeding the
> per-file timeout is a soundness/termination bug, not slowness. M1's *internal*
> emptiness bail-out is finer-grained: it bounds a single emptiness decision so
> the whole-file check terminates *within* §A14's ceiling and produces a
> diagnostic, rather than running until the outer `timeout 30` kills the process
> with no message. Because the step budget is a deterministic count rather than a
> wall-clock duration, it **tightens, never loosens**, the §A14 floor: a decision
> that would exceed `4096` steps is cut short and reported regardless of machine
> speed, so the whole-file `timeout 30` of v5-constraints §A14 stays satisfiable
> on any host. The bail-out exists **to keep §A14 satisfiable**, not to
> evade it. A program that trips many emptiness bail-outs is reporting a real
> problem (pathological negation usage), surfaced precisely.

### 3.5 Why not the cascade

A naive algorithm matches on type-tag pairs and dispatches one rule per
`(tag, tag)` combination — the quadratic, per-feature dispatch CLAUDE.md brands
context-poisoning, and the **documented v1→v4 failure root cause**. The
constraint-based algorithm has the opposite property (rewrite-design §2.3): a
small set of structural decomposition rules + the emptiness check; a **new
constructor plugs in by defining its decomposition rule and its behavior under
boolean operators**, not by adding cells to a matrix. This is the same
no-special-casing hard constraint, now enforced architecturally.

---

## 4. Narrowing as intersection (the single refinement primitive)

Flow-sensitive refinement is **intersection with the discriminating type or its
complement** (rewrite-design §1.4, §7; `type-system.md` § "Type narrowing").
After `if type(x) == "string"`, `x` is `T & string` in the truthy branch and
`T & ~string` in the falsy branch. The full guard table (rewrite-design §7):

| Guard form                  | Truthy branch        | Falsy branch          |
|-----------------------------|----------------------|-----------------------|
| `if x then …`               | `T & ~nil & ~false`  | `T & (nil \| false)`  |
| `if x ~= nil then …`        | `T & ~nil`           | `T & nil`             |
| `if type(x) == "string"`    | `T & string`         | `T & ~string`         |
| `if x == "GET"`             | `T & "GET"`          | `T & ~"GET"`          |
| `if x.tag == "leaf"`        | `T & { tag: "leaf" }`| `T & ~{ tag: "leaf"}` |
| `if is_str(x)` (predicate)  | `T & string`         | `T & ~string`         |

There is **no special-case code path per guard kind**: a narrowing pass
identifies the *refining atom* of each guard and emits the appropriate
intersection. The branch-exit **join is union**. This is the single most
important consequence of committing to complement (rewrite-design §1.4): the
falsy branch's `T & ~A` is exactly the `~A` the subtyping algorithm already
supports for `~T` annotations and for match `_`. M1 owns the *primitive*; the
full narrowing/flow story (predicates, the narrowed-scope second pass) is **M9**.

This is a deliberate addition over the v5 substrate, which has no `Neg` node and
therefore cannot represent the falsy branch's `~A`. Closing the narrowing gaps
in M9 depends on M1's complement.

---

## 5. The bound-graph interface (variable layer beneath the lattice)

The RDNF lattice handles *structure*; **type variables** are handled by a
**polar bound graph** that sits beneath it. M1 reconciles the v5 substrate's
"Spec A" simple-sub bound graph (op-sem § "Simple-sub bounds (normative)") as
exactly this layer and **fixes its interface**; **M2 specifies it in full**
(polar coalescing, generalization, recursive μ via hash-consing).

### 5.1 What M1 fixes (the interface)

- **Two distinct relations on variables, one addressing scheme** (op-sem
  § "central coexistence"): *equality* (`CEq`, binding `α := τ`) uses the
  union-find substitution and **merges roots**; *subtyping between two unbound
  variables* (`α <: β`) records a **directional bound-graph edge** `α → β` and
  does **NOT** merge — the relation is asymmetric and `α <: β` without `β <: α`
  is a legal state. All bound storage and all edges are keyed by the union-find
  **root** (`subst.find(id)`), so a later `CEq` merge inherits the other root's
  bounds and edges.
- **Three variable cases, each done-with-re-emission** (op-sem § "T-CSub-TVar —
  three cases"), all cache-guarded:
  - **Upper** `α <: T`: add `T` to `upper[r]`; ∀ `L ∈ lower[r]`, re-emit
    `CSub(L, T)`.
  - **Lower** `T <: α`: add `T` to `lower[r]`; ∀ `U ∈ upper[r]`, re-emit
    `CSub(T, U)`.
  - **Flow** `α <: β`: record edge; a **lower** `L` of α flows **forward** to β
    (`L <: α <: β ⇒ L <: β`), an **upper** `U` of β flows **backward** to α
    (`α <: β <: U ⇒ α <: U`), re-emitting the cross-product.
- **The closure invariant** `⋃lowers <: ⋂uppers` is *maintained* by eager
  re-emission (every lower meets every upper through a `CSub`), **not separately
  checked**. A genuine violation (`integer <: α`, `α <: string`) surfaces as a
  `CSub(integer, string)` the atomic/structural rules reject, blamed at the
  originating provenance.
- **Bind verifies bounds** (op-sem § "T-CEq-Bind"): binding `α := τ` re-emits
  `CSub(L, τ)` for every lower and `CSub(τ, U)` for every upper (cache-guarded).
- **The mandatory in-progress cache** (op-sem § "Bound-add with cache";
  rewrite-design §2.2): keyed by structural head hash (top-level tag plus, for a
  uvar leaf, its union-find root id). **Record-before-recursion** cuts cycles on
  regular (cyclic) bound-graphs — `S-Sub-CacheHit` discharges a re-encountered
  key by assuming it holds. **Mandatory, not an optimization**: without it,
  transitive re-emission on a cyclic graph diverges (this is the §A14 / B3
  termination guarantee).

### 5.2 What the negation rule (§3.2) adds to the interface

The §3.2 move-across-via-negation rule produces lower/upper bounds that **may
contain `¬τ`** (e.g. `τ₁ ∧ ¬τ₂` as a lower of `α`). The bound graph stores them
unchanged as simple types; the closure re-emissions (`CSub(L, U)`) route through
the emptiness procedure (§3.3–3.4) when a bound is a non-trivial negation. This
is the precise point where M1's lattice and the variable layer meet: **bounds are
simple types in the full lattice, including `Neg`; the bound graph never needs to
understand negation itself — it re-emits, and the lattice decides.**

### 5.3 What M1 does NOT re-introduce

M1 explicitly does **not** re-introduce the v5 substrate's pre-Spec-A
**"meet of uppers" path** (the `G9-P4` quiescence behavior, `v5-gaps.md`): a
single representative upper computed by meeting all uppers at quiescence. The
principled treatment is the polar bound sets above, coalesced **only at
generalization** (M2). The meet-of-uppers shortcut is superseded; M2 must not
restore it (plan note for M2, and `v5-gaps.md` bounds-spec-gap decision).

---

## 6. Soundness alignment (constraints §A)

- **§A1 (soundness floor).** Subtyping never accepts an unproven relation: the
  §3.4 timeout disposition **rejects** rather than accepts; structural and
  atomic rules reject mismatches; the closure invariant surfaces violations as
  rejected `CSub`s.
- **§A2 (`unknown` never casts away).** `unknown` is `⊤`; `unknown <: T` for
  narrower `T` is false and is rejected — no permissive path. A timed-out query
  involving `unknown` rejects (§3.4).
- **§A3 (`any` does not exist) / §A4 (no internal force casts).** M1 introduces
  no `any` and no escape hatch; the emptiness bail-out rejects, it does not widen
  to `any` or force-accept.
- **§A14 (single timeout).** §3.4's internal bail-out exists to keep the per-file
  `timeout 30` satisfiable while still producing a diagnostic; it is not an
  evasion (see §3.4 reconciliation box).
- **B-series (scheduling/provenance).** M1's solving is one worklist drained to
  quiescence (no pass cap, §B1–B4 — preserved from the v5 substrate); every
  re-emitted obligation carries the originating constraint's provenance (§B9,
  §B11), so conflicts and timeouts blame the source expression.

No item here is closed by a hardcoded result: R3/G11 (§closes below) are closed
by the **emptiness decision procedure** (a substrate mechanism), not by a
union-shaped special case.

---

## 7. Migration / blast-radius note (for the later implementation program)

M1 is the **heaviest re-architecture** in the program. This section describes the
migration; it does **not** perform it (the design program writes no code).

**Re-architected substrate:** `lib/type/static-v5/op_sem.lua` and
`op_sem_alt.lua` — specifically the `step_csub` dispatcher and its
`rule_T_CSub_*` cascade (op_sem.lua), plus the parallel cascade in `op_sem_alt`.

1. **Add the `Neg` constructor.** `types.lua` (the v5_perf AST) gains a `Neg{t}`
   node; `subst.lua` (deref/substitution), `variance.lua`, and both interpreters
   gain `Neg` handling. **Without `Neg`, neither narrowing's falsy branch nor
   match `_` nor the move-across rule is representable.** This is the single
   largest individual change and the substrate-before-consumers reason M1 is
   first.
2. **Replace `T-CSub-Union-R`** (op_sem.lua, the exact-branch `types.equal` loop;
   `v5-gaps.md` R3) with the emptiness route `A ∧ ¬(B₁∨…∨Bₙ) <: never`. Removes
   the "v5.0 limitation" rejection of `integer <: (integer | boolean)`.
3. **Replace `T-CSub-Intersection-Decomp`** (op_sem.lua, the `all_parts_unresolved`
   error path) with the §3.2 move-across-via-negation rule — `(α ∧ τ₁) <: τ₂ ⟹
   α <: τ₂ ∨ ¬τ₁`. Removes the "no disjunctive scheduler in v5.0" stuck error.
4. **Add the RDNF normalizer + emptiness procedure** with the level index,
   post-simplification hash-consing, the cache extension (generalize `subcache`),
   and the bounded timeout-with-diagnostic. This is new code, not a rewrite, but
   it is the most algorithmically delicate piece (the soundness of §3.3–3.4 rides
   on it).
5. **Keep, do not rewrite:** the Spec-A `atomic_subtype` relation (op_sem.lua —
   already a single relation, the atom oracle of §3.1); the bound-graph
   `add_upper`/`add_lower`/edge machinery and the `subcache` termination protocol
   (op-sem § "Simple-sub bounds (normative)"); the union-find substitution. These
   are the v5 substrate decisions M1 **reconciles in**, not against.
6. **The cascade dispatch contracts G14/G15/G16** (`type-system.md` § "Operational
   Semantics Dispatch", closed `bad931a6`) are **partly obsoleted**: G14 (the
   12-step `step_csub` priority order) is replaced by structural-decomposition +
   emptiness; its priority-ordering rationale (Refl→TVar→Top/Bottom→…) is
   subsumed by §3.1's "atoms via the oracle, variables via §5, structure
   otherwise". G15 (CTableSet cascade) and G16 (CHKT peel) are **not** touched by
   M1 — they belong to M6 and M4. The migration must re-derive G14's soundness
   under the new dispatch and record it.

**Parity discipline (carries forward).** Both `op_sem.lua` and `op_sem_alt.lua`
must independently encode the M1 algorithm; the parity fixtures are a deliverable
of the implementation program. M1's spec is written so two independent encodings
remain possible (the rules are stated as relations + re-emissions, not as a
single reference implementation). **R1** (`v5-gaps.md` — op_sem_alt lags op_sem
on bounds) is resolved at implementation time by both interpreters encoding §5
from this spec rather than one catching up to the other.

**Behavior conservation (§A11).** The 2809 tests stay green at every commit;
behavior is conserved across the migration, mechanism is not. The migration is
staged (add `Neg` → normalizer → replace Union-R → replace Intersection-Decomp →
emptiness procedure), each stage a green commit.

---

## 8. Closes

- **R3** (`v5-gaps.md`) — `T-CSub-Union-R` exact-branch-only ("v5.0 limitation").
  Closed by the **emptiness decision procedure** (§3.3–3.4): `A <: B₁∨…∨Bₙ` is
  `A ∧ ¬(B₁∨…∨Bₙ) <: never`, so `integer <: (integer | boolean)` succeeds.
  Mechanism, not a union special case.
- **G11** (`v5-gaps.md`) — union backtracking admits exact-branch only; no
  disjunction fallback. Closed by the **same emptiness substrate** — there is no
  search to backtrack; one emptiness query decides it.
- **bounds-spec-gap (partial)** (`v5-gaps.md`) — uvar-bounds substrate
  unspecified in the normative doc. M1 **defines the bound graph as the
  variable-handling layer beneath the RDNF lattice and fixes its interface**
  (§5); **M2** specifies polar coalescing and the rest in full. The "meet of
  uppers" path is explicitly *not* re-introduced (§5.3).
- **The "v5.0 limitation" cascade as a class** — the per-`(tag,tag)` `step_csub`
  dispatch is replaced by structural decomposition + RDNF emptiness over a uniform
  constructor-plus-boolean representation (§3.5).

Each closure is a **substrate mechanism**, not a hardcoded result, per the
CLAUDE.md planning rules and the cross-walk discipline in `README.md`.

---

## 9. Open questions (for the reviewer — genuine forks not resolved unilaterally)

1. **Emptiness timeout budget — shape and unit.** **RESOLVED** (folded into §3.4):
   the budget is a deterministic **count of RDNF conjuncts expanded /
   normalization steps**, **default `4096`**, **not** wall-clock. It is part of
   the normative semantics — both interpreters use the identical count and bail at
   the identical point, so parity fixtures (§F2) stay byte-identical. The
   step-count form was preferred over wall-clock precisely because wall-clock would
   make the two interpreters' bail-out points machine-dependently diverge.

2. **Where exactly does RDNF level-0 expansion stop for match-type heads?**
   **DEFERRED — confirm jointly at M8.** §2.2 says level-0 expands
   class/alias/match-type heads. A match-type head whose scrutinee is an
   unresolved variable cannot be expanded (M8 suspends it). Does level-0 RDNF
   treat an unexpandable match head as an **opaque atom** (so emptiness reasons
   around it conservatively) or does reaching one **force the whole emptiness
   query to suspend**? M1 leans opaque-atom; that lean is **conservatively sound**
   (it never admits an unproven `<:`), but it couples M1 to M8's suspension model,
   so the final choice is confirmed jointly with M8.

3. **Cache invalidation across `CEq` merges.** **DEFERRED — to M2 if a rekey is
   ever needed.** §5.1 keys the cache by structural head hash including the
   union-find root id. When `CEq` merges roots, prior cache entries keyed on the
   loser root are stale-but-harmless (they assume an obligation that is now
   subsumed). M1 treats them as harmless: the monotonicity argument (assuming a
   now-stronger fact) stands. Should a merge-time cache rekey ever prove necessary,
   M2 is the natural owner (it costs a pass over `C` per merge); M1 does not
   require it.

4. **`Neg` in the user-facing display.** **DEFERRED — UX batch.** A coalesced type
   may legitimately contain `~T` (e.g. a falsy-branch type `T & ~nil` that does
   not simplify away). Should the display normalizer (§2.2) ever *eliminate* a
   surviving `~T` by re-expressing it positively where the lattice is finite (e.g.
   `boolean & ~true` → `false`), or always render `~T` verbatim? This is a
   display/UX fork with **no soundness content**; deferred to the UX batch so it is
   decided once rather than per-error-message.

5. **Does the negation move-across rule (§3.2) need a determinism tie-break?**
   **RESOLVED** (folded into §3.2): **yes — prefer the lower-bound form.** When
   both `τ₁ <: τ₂ ∨ α` and `α ∧ τ₁ <: τ₂` shapes are simultaneously applicable to
   the *same* constraint, both interpreters apply the `τ₁ ∧ ¬τ₂ <: α` (lower-bound)
   transform, so they build byte-identical bound graphs and parity-fixture
   determinism (§F2) holds.
