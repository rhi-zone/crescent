# M4 — HKT and kinds

*Normative module spec of the unified type-system design. Depends on **M1**
(`01-lattice-and-subtyping.md`, the lattice / RDNF / complement / emptiness /
subtyping algorithm and its "too-complex" bail-out) and **M2**
(`02-bounds-inference.md`, the polar bound graph + termination cache). It
**gates M5** (effect rows), **M6** (`__index` walking / iterator protocol), and
**M11** (indexed access). M4 specifies the **kind system** (the grammar of
kinds), **kind inference** (the substrate has kind CHECKING but no inference —
G2), **type-constructor variables** (`<F: SomeGeneric>` composes as a
constructor applied to arguments, not a plain type variable — F1), and the
**downstream gating interfaces** the kinded modules rely on. It reconciles the
v5 substrate's **De-Bruijn type-lambda calculus** (`types.lua`
`lambda`/`app`/`shift`/`instantiate`; the CHKT/HOUnify machinery in
`op_sem*.lua`) into a kinded HKT design. Aligns to `docs/type-system.md`
(philosophy, fixed) and satisfies the soundness floor of
`docs/typechecker-v5-constraints.md` §A.*

Primary sources reconciled here:

- `docs/typechecker-v5-operational-semantics.md`
  § "Higher-kinded type application (CHKT) + higher-order unification residue
  (HOUnify)" — the **CHKT/HOUnify substrate**: the curried-`App` representation
  of `?F<a₁..aₙ>`, the Miller-pattern-fragment check, `T-CHKT-{Miller, Reduce,
  Rigid-Mismatch, Park}`, `T-HOUnify-{Wake, Stuck}`, `S-Wake-Head`, the
  "never commit a guessed HO solution" soundness floor, and the
  § "Kind discipline (v5.0)" (kind tag `k` opaque, no inference). **M4 ADOPTS
  the CHKT/HOUnify dispatch and the soundness floor**, and adds the kind system
  + kind inference the substrate names as owed.
- `docs/typechecker-v5-operational-semantics.md` § "Subtyping
  (variance-respecting)" — the **declaration-site variance registry**
  (`variance.lua`), `T-CSub-App-Var` (per-position variance from the head's
  registry), and the **two spec gaps** "Variance under Lambda" (G10) and
  "Kind inference" (G2). M4 reconciles the registry into a kinded discipline
  and closes G10.
- `lib/type/experiments/v5_perf/types.lua` — the De-Bruijn calculus:
  `Var(i)` (De-Bruijn level), `Lambda(k, b)`, `App(f, a)`, `Const(name)`,
  `shift` / `instantiate` / `instantiate_pack` (eager-shift β-substitution),
  `effect_apply` / `is_effect` (the `!name` effect-head application chain).
  **M4 describes this substrate and grounds the kind system on it; M4 does not
  edit it.**
- `lib/type/static-v5/op_sem_alt.lua` § `miller_check` / `abstract_body`
  (the second independent encoding) — the **G4 nested-binder gap**
  (`abstract_body` "v5.0 spec gap: nested lambdas need shift-aware rewrite").
- `docs/typechecker-rewrite-design.md` §1.1 (constructor applications, arrow
  variance contra-args/co-ret), §6 (rank-N — **M13's**, cited only at the M13
  seam; **it is thin on kinds**: it names "constructor application: `Fn(...)`,
  `Rec(...)`" and "a quantifier wrapper `Forall(αs, T)`" but specifies **no
  kind grammar, no kind inference, no constructor-variable discipline** — M4
  fills that, consistent with rewrite-design's constructor-plus-boolean frame).
- `docs/typechecker-v5-constraints.md` §H1 ("Is HKT in scope for v5?") — the
  scope decision. **The program plan put HKT in scope** (README module map
  M4; plan §"M4"); M4 therefore **designs it** and does **not** re-open scope.
- `docs/v5-gaps.md` G2 / G4 / G1 / G3 / G10; `docs/typechecker-roadmap.md` F1.

M1 owns the lattice, RDNF, complement, the emptiness procedure, and the
bounded "too-complex" step budget (default `4096`). M2 owns the polar bound
graph, polar coalescing, μ, and the termination cache. M3 owns packs and the
arrow-over-packs shape. **M4 redefines none of them.** M4 adds a *second,
orthogonal* judgement — **kinding** — that classifies type expressions by their
arity-and-shape, and a *constructor application semantics* (β-reduction +
Miller-fragment unification) that sits beside subtyping. The discipline: **the
lattice reasons about value-denoting types (kind `Type`); kinding ensures every
type expression that *reaches* the lattice is fully applied to kind `Type`
first.** This is the M4 frame in one sentence.

---

## 1. The kind system (grammar of kinds)

### 1.1 What a kind is, and what it is not

A **kind classifies a type expression** the way a type classifies a value. A
type of kind `Type` denotes a set of runtime values and is a full M1 lattice
citizen (it may be unioned, intersected, complemented, RDNF-normalized). A type
expression of a *higher* kind — a **type constructor** — is **not** a lattice
citizen: it is a function from types to types, awaiting application. This is the
exact analogue of M3's pack/value-type boundary (M3 §4): just as a `TPack` is
not a lattice element (it is a telescope, surfaced only by arrow decomposition),
a constructor of kind `Type -> Type` is not a lattice element (it is a
type-level function, surfaced only by application). The kind system is the
discipline that keeps non-`Type` expressions off the lattice **by
construction**, exactly as the single-rest invariant keeps two-tailed packs
unrepresentable.

### 1.2 The kind grammar (normative)

```
Kind  ::=  Type                       -- the kind of value-denoting types (`*`)
        |  Kind -> Kind               -- arrow kinds: a type constructor
        |  KVar(κ)                    -- a kind metavariable (kind inference, §2)
```

- **`Type`** (written `*` in the literature; we use the word `Type` to match
  the substrate's `Lambda(k, b)` kind-tag string and to avoid colliding with
  the value-level `*`). The kind of every type that denotes a set of values:
  all M1 constructors (`Const`, `Literal`, `Record`, `Arrow`, `Mu`, nominal
  atoms, `unknown`, `never`), every boolean combination of `Type`-kinded types
  (`A | B`, `A & B`, `~A`), and every **fully-applied** constructor
  (`List<integer>`, `Map<string, integer>`).
- **Arrow kinds `K₁ -> K₂`** classify type constructors. `List : Type -> Type`
  (a unary constructor); `Map : Type -> Type -> Type` (curried binary);
  `Functor`-shaped arguments take `Type -> Type`. **Arrow kinds are
  right-associative and curried** — `Type -> Type -> Type` is
  `Type -> (Type -> Type)` — which is exactly the curried-`App` /
  `Lambda`-chain shape of the substrate (`types.lua`: `App(App(f, a), b)`,
  `lambda(k, lambda(k, body))`). The substrate is already curried; the kind
  grammar names the discipline it follows.
- **`KVar(κ)`** — a **kind metavariable**, the unit of kind *inference* (§2).
  Unbound `KVar` = a not-yet-determined kind; bound = a concrete kind. This is
  the substrate's missing piece (G2: "kind checking exists but kind inference
  does not"): the substrate's `Lambda(k, b)` carries a *string* kind tag `k`
  used as opaque documentation; M4 replaces the opaque tag with a real `Kind`
  carrying `KVar`s so kinds can be *inferred* rather than only *checked*.

There is **no kind polymorphism** (no `forall κ. …` over kinds) and **no
higher kinds beyond what arrow kinds express** (no kind of kinds). The grammar
is **first-order over the single base kind `Type`**: every kind is a finite
right-nested arrow ending in `Type`, i.e. `Type^n -> Type` for some `n ≥ 0`
(`n = 0` is `Type` itself). This is the minimal kind system that makes
`<F: Type -> Type>` expressible, and it is **decidable** (§2.4) — a richer kind
system (kind polymorphism, dependent kinds) is **explicitly out of scope**, in
the same spirit M13 puts impredicativity out of scope. A future need is an
OPEN-QUESTION (§11.4), not a silent extension.

### 1.3 The kinding judgement

`Γ ⊢ τ : K` reads "under kind environment `Γ`, type expression `τ` has kind
`K`". `Γ` maps the De-Bruijn-bound type variables in scope (`Var(i)`, from
enclosing `Lambda` binders and `Forall` quantifiers — M13) and the named
constructors in the registry (`List`, `Map`, …) to their kinds. The rules
(normative):

```
                                              (n, K) ∈ registry
─────────────  K-Const-Value          ─────────────────────────  K-Const-Ctor
Γ ⊢ Const(n) : Type   (n a value type)        Γ ⊢ Const(n) : K

Γ(i) = K                       Γ, (this binder : K₁) ⊢ b : K₂
──────────────  K-Var          ───────────────────────────────────  K-Lambda
Γ ⊢ Var(i) : K                 Γ ⊢ Lambda(K₁, b) : K₁ -> K₂

Γ ⊢ f : K₁ -> K₂      Γ ⊢ a : K₁
──────────────────────────────────  K-App
Γ ⊢ App(f, a) : K₂

Γ ⊢ A : Type    Γ ⊢ B : Type             Γ ⊢ T : Type
─────────────────────────────  K-Bool    ───────────────  K-Neg
Γ ⊢ (A | B) : Type, (A & B) : Type        Γ ⊢ ~T : Type

Γ ⊢ each args.items[i] : Type   Γ ⊢ each ret.items[i] : Type
────────────────────────────────────────────────────────────  K-Arrow
Γ ⊢ Arrow(args, ret) : Type
```

- **`K-App`** is the engine: application **consumes one arrow-kind argument**,
  dropping the kind from `K₁ -> K₂` to `K₂`. A fully-applied constructor
  (`App(App(Map, string), integer)`) has kind `Type`; a partially-applied one
  (`App(Map, string) : Type -> Type`) does not.
- **`K-Bool` / `K-Neg` / `K-Arrow` demand `Type`-kinded operands.** This is the
  normative statement of the M3-analogous boundary: **the lattice's boolean
  operators and the arrow's argument/return packs are well-kinded only over
  `Type`.** `List | Map` is **ill-kinded** (a kind error, §1.4), not a strange
  value type — you cannot union two constructors any more than you can union two
  functions-awaiting-arguments. `List<integer> | List<string>` *is*
  well-kinded (both operands kind `Type`).
- **`K-Lambda`** is where the De-Bruijn binder enters `Γ`: the binder's kind
  `K₁` is pushed for the body. In the substrate today `K₁` is the opaque string
  `k`; M4 makes it a real `Kind`, **inferred** when written as a `KVar` (§2).

### 1.4 Kind errors are first-class diagnostics, not lattice bottoms

A type expression that fails to kind (`List | Map`, `List<integer, string>`
applying a unary constructor to two args, `integer<string>` applying a value
type as a constructor) is a **kind error** — a distinct diagnostic class
`kind_mismatch`, surfaced at the expression's provenance (M1 §6 B-series). It is
**not** reduced to `never` and **not** silently accepted. This matches the
substrate's `T-CHKT-Rigid-Mismatch` ("HKT app on non-constructor: error") and
`T-CEq-Mismatch` ("kind mismatch") dispositions, generalized: **kinding runs
before the lattice sees the type**, so an ill-kinded operand never reaches RDNF
or emptiness. The soundness consequence (§9): the lattice's invariant "every
operand denotes a set of values" is *established by kinding*, not assumed.

---

## 2. Kind inference (closes G2)

The substrate has kind **checking** (the `Lambda(k, b)` tag is consulted; arity
is enforced by lambda-chain length — op-sem § "Kind discipline (v5.0)"). It has
no kind **inference**: a `Lambda` whose binder kind is unknown, or a constructor
variable `<F: …>` whose kind must be discovered from its uses, cannot be
assigned a kind. G2 ("kind checking exists but kind inference does not") is the
gap; this section closes it with a **mechanism**, reusing M2's bound-graph
discipline at the kind level rather than inventing a new solver.

> **G2 gap text** (`v5-gaps.md`): *"Kind checking exists but kind inference does
> not — docs/typechecker-v5-handoff-2026-05-26.md §6."* And the op-sem spec gap:
> *"Kind inference is owed. Without it, `CHKT(?F, args, ?result)` where `?F` is
> bound to a `Lambda` of insufficient arity becomes a `T-CHKT-Reduce` step that
> produces a `CEq` between a still-abstracted lambda and `?result` — the
> resulting unification surfaces as a generic shape mismatch rather than an
> arity error."*

### 2.1 Kind unification is first-order syntactic unification (decidable)

Because the kind grammar (§1.2) is **first-order over the single base kind
`Type`** — every kind is `Type^n -> Type`, a finite right-nested arrow with
`KVar` leaves — **kind inference is ordinary first-order syntactic
unification**: the Robinson/Hindley-Milner algorithm over the two-symbol
signature `{ Type, (->) }` with `KVar` as the unification variable. This is
**decidable, terminating, and unitary** (a most-general unifier exists when one
exists, computed in near-linear time with the occurs-check). It is a strictly
**simpler** discipline than M2's value-type bound graph — there is **no
subtyping on kinds** (`Type` is the only base kind; arrow kinds are invariant by
construction), so kind inference needs **only equality**, never the polar
lower/upper bound machinery. The decision to make kinds **equality-only** (not
subtyped) is normative and is what keeps kind inference trivially decidable; it
is justified in §2.3.

### 2.2 The kind-variable discipline (reuses M2's substitution, not its bounds)

A `KVar(κ)` is a **kind metavariable**, stored in a **kind substitution**
`σ_K : KVar → Kind` parallel to M2's value-type substitution `σ` but **far
simpler**:

- **Binding** is union-find over `KVar` roots, exactly as `subst.lua` binds
  `UVar` roots, with an **occurs-check** (`κ ∈ FV(K)` ⇒ kind error
  `kind_occurs`, the kind-level analogue of `T-CEq-Occurs`). A `KVar` carries
  **no `B.lower`/`B.upper`/`B.edge_*`** — there are no kind bounds because there
  is no kind subtyping (§2.1). This is the precise answer to "does `<F: …>` get
  M2-style bounds?": **at the *kind* level, no** (kinds use equality-only
  union-find); **at the *type* level, yes, but with a constructor-aware
  discipline** (§3.3).
- **The kind-unification constraint** `KEq(K₁, K₂)` decomposes structurally:
  `KEq(Type, Type)` discharges; `KEq(K₁ -> K₂, K₃ -> K₄)` emits
  `KEq(K₁, K₃)` and `KEq(K₂, K₄)`; `KEq(KVar(κ), K)` binds `κ := K` after the
  occurs-check; `KEq(Type, K₁ -> K₂)` (or vice versa) is a **kind error**
  (`kind_mismatch`). This is a five-line decomposition with no boolean algebra,
  no emptiness query, and no bail-out — kind inference **cannot** trip M1's
  "too-complex" budget because it never reaches the lattice.
- **Generalization at kind level is monomorphic**: there is no kind polymorphism
  (§1.2), so a `KVar` left unbound at the end of kinding a declaration is
  **defaulted to `Type`** (the kind-level analogue of "an unconstrained value
  variable that occurs nowhere is `never`/`unknown`"). Defaulting-to-`Type` is
  the principled choice: an unconstrained position that is never applied is a
  value type. This default is normative and parity-pinned (§7).

### 2.3 Why kinds are equality-only (no kind subtyping)

A subtyping relation on kinds would be needed only if `Type -> Type` could be a
subkind of `Type` (it cannot — a constructor is categorically not a value type;
§1.1) or if arrow kinds had variance (they do not — kinding is about *arity and
shape*, not about the variance of the *type-level function*, which is a separate
concern handled by the **value-level** variance registry, §4). So the kind
lattice is the two-element discrete order `{ Type } ∪ { arrow kinds }` with no
nontrivial `<:`. Making kind inference equality-only is therefore not an
under-powering: there is no sound kind-subtyping relation to be more powerful
*about*. This mirrors M3's decision that pack vars use a simpler binding
discipline than M2's polar bounds (M3 §5.2) — same reasoning (one positional
solution, computed deterministically, not a lattice of candidates), applied one
level up.

### 2.4 Kind inference is decidable; it never bails via M1's mechanism

Because kind unification is first-order syntactic unification over a finite
signature (§2.1), it is **decidable and terminating** with the standard
occurs-check; it does **not** need — and never invokes — M1's "too-complex"
emptiness bail-out (M1 §3.4, the `4096` step budget). That bail-out exists for
the **value-type** lattice's worst-case-exponential DNF-emptiness decision; the
kind level has no DNF, no negation, no emptiness — only equality decomposition.
This is the M4-specific answer to the program's "decidable, or bails via M1's
mechanism" requirement: **the kind judgement is outright decidable and needs no
bail-out; the *HKT unification* judgement (constructor-variable solving, §3) is
where undecidability could arise, and *that* reuses M1's bail-out (§3.4)** — the
two are kept separate precisely so the always-decidable part never pays for the
sometimes-hard part.

---

## 3. Type-constructor variables (closes F1)

This is the headline gap. Today `<F: SomeGeneric>` parses but `F` is treated as
a plain type variable, so `F<A>` does not compose — F applied to an argument is
not understood as a constructor application.

> **F1 gap text** (`typechecker-roadmap.md`): *"Higher-kinded types … The single
> biggest deficit vs. Haskell. Blocks every functor/monad/traversable-shaped
> abstraction. `<F: SomeGeneric>` parses but does not compose — `F` is treated
> as a type variable, not a type constructor."*

### 3.1 A constructor variable is a `UVar` of higher kind, applied via `App`

The decision is to **reuse the existing substrate representation, not invent a
new one**: a constructor variable `F` is an ordinary `UVar(f)` whose **kind**
is an arrow kind (`Type -> Type` for a unary `<F>`), and an application `F<A>`
is the curried `App(UVar(f), A)` — exactly the
`App(...App(App(?F, a₁), a₂)..., aₙ)` representation the CHKT substrate already
uses (op-sem § "Higher-kinded type application"). What was missing is **not a
new node** but **(a) a kind on the variable** (so the solver knows `F` is a
constructor, not a value type — closing F1's "treated as a type variable") and
**(b) the kind-checked, β-reducing application semantics** the CHKT machinery
provides. M4 unifies these: **a constructor variable is a `UVar` carrying a
higher `Kind`; an application is `App`; solving it is the CHKT/HOUnify
dispatch.**

This is why F1 is closed by a *mechanism* and not a patch: there is no
`pcall`-style name-keyed handling, no `$`-encoding. `<F: Type -> Type>` is a
`UVar` with a kind annotation; `F<A>` is `App`; and the *general* CHKT rules
(adopted §3.2) decide it for **any** constructor, named or variable.

### 3.2 The CHKT/HOUnify dispatch (adopted from the substrate, kind-gated)

M4 adopts the substrate's CHKT/HOUnify dispatch **verbatim in structure**, with
one addition: every rule is **kind-gated** — it fires only after the kinding
judgement (§1.3) has assigned `?F` an arrow kind of the right arity. The rules
(op-sem § "Rules", adopted):

- **`T-CHKT-Miller`** — the application is in the **Miller pattern fragment**
  (§3.4): `?F` unbound, args rigid and pairwise-distinct, body's free vars
  within the args' vars. The unique most-general solution
  `?F := λ…λ. abstract(result, args)` is committed. **Kind side-condition
  (new):** the inferred λ-chain kind (`Type^n -> Type` for `n` args) must unify
  (§2) with `?F`'s kind; a mismatch is a `kind_mismatch`, not a shape error.
  This is precisely the substrate's owed kind-checking extension (op-sem
  "Spec gap (v5.0)"): with kind inference (§2), an arity mismatch surfaces as an
  **arity/kind error** rather than a downstream generic shape mismatch.
- **`T-CHKT-Reduce`** — `?F` is bound to a `Lambda`-chain; **β-reduce**
  (`instantiate` / `iter-instantiate`, the eager-shift substrate operation) and
  emit `CEq(reduced, ?result)`. The peel depth is exactly `#args` (the closed
  G16 dispatch). **Kind side-condition (new):** `#args ≤` the chain's kind arity
  (`depth` of the arrow kind); over-application is a `kind_mismatch`.
- **`T-CHKT-Rigid-Mismatch`** — `?F` deref'd to a rigid **value type**
  (`Const("number")`, a record, …): HKT application on a non-constructor —
  `kind_mismatch`. With kinds, this is subsumed by `K-App` failing
  (`Γ ⊢ ?F : Type`, not an arrow kind), but the operational rule is retained as
  the solver-time realization.
- **`T-CHKT-Park`** + **`T-HOUnify-{Wake, Stuck}`** + **`S-Wake-Head`** — when
  the Miller fragment does **not** apply and `?F` is still unbound, emit a
  `HOUnify` residue and **park on head-rigidity** of `?F` (head-watchers, not
  ordinary watchers — it must not wake on uvar↔uvar unions). When `?F`'s head
  becomes rigid, retry as CHKT. **At quiescence a surviving `HOUnify` is an
  "ambiguous constructor variable" error** — *never a guessed solution*. M4
  adopts this **soundness floor unchanged**: outside the decidable Miller
  fragment, we **reject** (`T-HOUnify-Stuck`), we do not search and do not guess
  (§3.4, §9).

### 3.3 Constructor-variable bounds — the M2 reconciliation (the central seam)

The program explicitly asks: *does `<F: SomeGeneric>` get M2-style bounds at
kind `Type -> Type`, or a different discipline?* The resolved answer, normative:

> A constructor variable `F : Type -> Type` does **NOT** carry an M2 polar
> bound graph at its own (higher) kind. M2's `B.lower`/`B.upper`/`B.edge_*` are
> defined for **value-type variables (kind `Type`)** — bounds are simple types
> in the lattice (M2 §2), and the lattice is a boolean algebra of *value sets*
> (M1 §1.1). A `Type -> Type` constructor is **not a value set** (§1.1), so it
> has **no lower/upper bound in the lattice** — `F <: G` between two unapplied
> constructors has no denotation (you cannot ask whether one type-level function
> is a subset of another; there are no values to compare). A constructor
> variable's constraints are therefore **kind-equality** (§2) plus the
> **CHKT/HOUnify** application discipline (§3.2), **not** polar value bounds.

This is the exact analogue of M3's resolution for pack variables (M3 §5):
*the metavariable itself carries no polar bounds; its **applied results** flow
through M2.* Concretely:

- **The constructor variable `F` itself**: kind-equality only (§2.2), bound by
  Miller-fragment unification (`T-CHKT-Miller`) or by an explicit
  `<F: SomeGeneric>` annotation that **kind-checks** `F` against `SomeGeneric`'s
  kind. No `B.lower`/`B.upper`, no flow edges, no coalescing. This parallels M3
  §5.1's "a pack var is bound by alignment, not bound accumulation" — here, a
  constructor var is bound by Miller unification, not bound accumulation.
- **Each *application* `F<A>` reduces to a value type of kind `Type`**, and
  *that value type* flows through M2's bound graph normally. When `F` is bound
  to `λX. List<X>` and `F<A>` β-reduces (`T-CHKT-Reduce`) to `List<A>`, the
  resulting `List<A>` is a kind-`Type` value type with full M2 bounds, full M1
  lattice membership, and per-position variance from the registry (§4). So **no
  expressiveness is lost**: the subtyping flow happens on the *applied*
  value-type results (M2 + M1), the higher-kinded composition happens on the
  constructor variable (kind unification + CHKT). The two concerns are cleanly
  separated, exactly as M3 separates pack-arity (binding) from item-subtyping
  (M2 flow).
- **An *applied* constructor variable can be a value-type bound.** Just as M3
  §5.3 lets a pack-typed arrow be an M2 bound value carried opaquely, an
  **applied** constructor variable `F<A>` (kind `Type`) may appear in
  `B.lower`/`B.upper` of some value-type variable. M2 stores it unchanged
  (M2 §2: bounds are simple types); when M2 re-emits a `CSub` against it, the
  obligation dispatches into M1's structural decomposition for `App`-headed
  types (M1 §3.1 `App(n,…) <: App(n,…)` via the §4 variance registry), and if
  `F` is still an unbound constructor variable the `App <: App` decomposition
  **parks via the CHKT/HOUnify head-rigidity machinery** (§3.2) until `F`'s
  head rigidifies. This is the precise seam: **M2's bound graph carries
  applied-constructor bounds opaquely and re-emits; M4's CHKT dispatch decides**
  — the same "re-emit, the lattice/HKT decides" pattern as M1 §5.2 (negation)
  and M3 §5.3 (pack arity).

> **Why a constructor variable must not get polar bounds (soundness).** If `F`
> carried a `B.upper` value type `U`, the closure invariant (M2 §3.5,
> `⋃lowers <: ⋂uppers`) would re-emit `CSub(L, U)` mixing a constructor and a
> value type — an ill-kinded obligation. Kind-gating (§1.4) makes that
> unrepresentable: a `CSub` whose sides have **different kinds** is a
> `kind_mismatch` at generation, never an admitted bound. So the
> "constructor vars carry no value bounds" rule is not a stylistic choice; it
> is forced by kind soundness. The only bounds a constructor variable
> participates in are bounds on its **applications** (kind `Type`), which is
> exactly where M2 belongs.

### 3.4 The Miller-pattern fragment and the bail-out decision (closes G1)

The substrate restricts the Miller-pattern check to **`UVar` or `Const`
arguments** (op-sem "Note on the v5.0 restriction"; G1: *"Miller pattern
fragment restricted to UVar/Const args only; complex argument shapes not
handled"*). The decision M4 makes, normative:

> **HKT unification stays in the Miller-pattern fragment; it does NOT extend to
> general higher-order unification. Outside the fragment, M4 reuses M1's
> bounded "too-complex" bail-out — it does not invent a new bail-out, and it
> does not guess.**

Rationale (this is the decision the program asked M4 to make and justify):

1. **General higher-order unification is undecidable** (Goldfarb 1981). The
   Miller *pattern* fragment (a higher-order variable applied to **distinct
   rigid arguments**) is the maximal fragment with **decidable, unitary** HO
   unification (Miller 1991) — a unique most-general unifier when one exists.
   Staying in it is the principled boundary: it is the kind-level analogue of
   M1's choice to keep the value lattice in a decidable regime and **bail
   rather than enter an undecidable search** (M1 §3.4, §9.2.7 "restricting the
   boolean algebra is rejected" — here, *extending into full HO unification is
   rejected* for the same reason: it trades a decidable mechanism for an
   undecidable search).
2. **The bail-out reuses M1's machinery, not a new one** (the program's explicit
   instruction). When an application is **outside** the Miller fragment and `?F`
   stays unbound, the disposition is `T-CHKT-Park` → `HOUnify` →
   (at quiescence) `T-HOUnify-Stuck` = **"ambiguous constructor variable"
   error**. This is *exactly* M1's bail-out **discipline**: a bounded,
   deterministic procedure that, on hitting the limit of the decidable fragment,
   **rejects with a named diagnostic at the originating provenance** rather than
   looping, guessing, or widening to `any`. M4 does **not** add a second step
   budget: the CHKT dispatch is already bounded (the worklist is finite, each
   park-and-wake fires at most once per head-rigidification, S-Wake-Head is
   monotone — op-sem termination sketch), so the *only* unbounded risk would be
   entering full HO search, which M4 declines. Where a CHKT re-emits a `CEq` on
   β-reduced bodies that themselves contain non-trivial negation (rare; only via
   a `Type`-kinded match-type head, M8), *that* `CEq` routes through M1's
   value-level emptiness and inherits M1's `4096` budget — so the single shared
   bail-out (M1 §3.4) covers the only place HKT solving can become
   value-lattice-hard.
3. **Extending the fragment is admissible later, but only within decidability.**
   G1's "complex argument shapes" can be widened from `UVar`/`Const` to **any
   rigid distinct argument** (the *full* Miller fragment — arbitrary rigid trees
   with the occurs/alpha-equivalence engine) without leaving decidability; that
   widening is **specced as closing G1 in full** (§10) and is a substrate
   extension (a richer `abstract`/occurs engine), **not** a move into
   undecidable territory. M4 closes G1 by **specifying the full-Miller fragment
   as the target** and recording the substrate work (the alpha-equivalence +
   occurs engine, and the nested-binder shift of §5) as the blast radius. What
   M4 does **not** do is extend past the pattern fragment — that boundary is
   fixed here, with reason.

### 3.5 Eta-equivalence (closes G3)

> **G3 gap text** (`v5-gaps.md`): *"No eta-equivalence in Miller check."* And
> op-sem: *"`λx. F x` vs `F` are not considered equal in the Miller check."*

M4's decision: **η-equivalence is normative for constructor identity, realized
by η-contraction at the kinding boundary, not by an η-aware unifier.** A
constructor `λX. F<X>` (where `F : Type -> Type` and `X` is the bound var) is
**η-contracted to `F`** as a *kinding-time normalization*, before CHKT
dispatch. Concretely: when kinding produces a `Lambda(K, App(f, Var(0)))` whose
body applies `f` to exactly the bound variable and `f` does not mention `Var(0)`
(the standard η-redex side-condition), it normalizes to `f`. This is decidable
(a syntactic check at lambda-construction time), it composes with the
Miller-fragment check (the unifier sees η-normal forms, so `λx. F x` and `F`
compare equal without an η-aware unification engine), and it stays inside the
decidable fragment (η-contraction is a *normalization*, not a search). **Why
contraction at the boundary, not an η-aware unifier:** an η-aware higher-order
unifier reintroduces the search the Miller fragment was chosen to avoid;
normalizing to η-normal forms keeps the unifier first-order-pattern-shaped while
delivering the equivalence. G3 is closed by this normalization mechanism, not by
a per-case `λx. F x ≟ F` special-case in the Miller check.

---

## 4. Variance under Lambda (closes G10)

> **G10 gap text** (`v5-gaps.md`): *"Variance under Lambda: registry covers
> named TConst only; anonymous lambdas default invariant."* And op-sem spec gap
> 2: *"The registry covers named constructors only; type lambdas don't yet carry
> variance. Acceptable for v5.0 since CHKT already β-reduces lambdas to
> structural shapes before dispatch."*

The substrate's variance registry (`variance.lua`) assigns a per-parameter
variance list to **named** constructors (`T-CSub-App-Var` looks up
`variance.at(n, i)`); an **anonymous** `Lambda` carries no registry entry and so
defaults to **invariant**. G10 is the gap. M4 closes it by **deriving variance
from the lambda body structurally**, not by extending the registry with
anonymous entries (there is no name to key on — a registry entry for an
anonymous lambda would be exactly the special-casing the hard rule forbids).

### 4.1 Variance is a property of the body, computed by polarity

A type lambda `λX. body` has, at its single parameter position, a variance
determined by the **polarity at which `X` (the bound `Var`) occurs in `body`** —
the *same* polarity M2 §5.1 already threads for coalescing (even number of
contravariant flips = covariant; odd = contravariant; both = invariant; absent =
bivariant, treated as invariant for soundness). The contravariant flips are the
same two M2 fixed: **arrow-argument positions** and **`Neg`/complement
occurrences**. So:

- `λX. List<X>` — `X` occurs covariantly (List's parameter is covariant, no
  flips) ⇒ the lambda is **covariant** in its parameter.
- `λX. (X) -> integer` — `X` occurs in an arrow-argument position (one
  contravariant flip) ⇒ **contravariant**.
- `λX. (X) -> X` — `X` occurs both contra (arg) and co (ret) ⇒ **invariant**.
- `λX. integer` — `X` absent ⇒ bivariant, **treated as invariant** (the sound
  default, matching the registry's undeclared default).

**This is not a second variance notion.** It is M2's polarity walk (M2 §5.1)
applied to a lambda body to *derive* the per-position variance that the registry
*stores* for named constructors. A **named** constructor's registry entry is
then understood as the *cached, declaration-site-checked* result of this same
walk over the constructor's definition — so `T-CSub-App-Var` (registry lookup)
and the lambda case (structural derivation) are **one rule**: look up the
variance if the head is a registered `Const`; derive it by polarity if the head
is a `Lambda`. No special-casing: both paths produce a per-position variance
from the same polarity discipline.

### 4.2 The subtyping rule, generalized over heads

M1 §3.1's `App(n,…) <: App(n,…)` decomposition is generalized: for
`App-headed L <: App-headed R` with the **same head** (same registered `Const`,
or β-equal `Lambda` after `T-CHKT-Reduce`), emit per-position `subgoal(vᵢ, …)`
where `vᵢ` is the variance of position `i` — **from the registry if the head is
a `Const`, from the §4.1 polarity walk if the head is a `Lambda`.** The
substrate already β-reduces lambdas to structural shapes before dispatch (op-sem
gap 2's "acceptable because CHKT β-reduces first"); M4 makes the **un-reduced**
lambda case sound *without* requiring prior β by deriving variance directly,
which is needed whenever a `Lambda` appears in a `CSub` LHS/RHS without a prior
reduction (op-sem gap 2's "owed when a corpus example exercises a non-trivial
`Lambda` in a CSub without prior β"). G10 is closed by the **structural variance
derivation** (a mechanism over polarity), not by a default or a name-keyed
registry hack.

---

## 5. Nested-binder substitution (closes G4)

> **G4 gap text** (`v5-gaps.md`): *"No shift-aware abstraction over nested
> lambdas; capture-avoiding substitution fails for nested binders —
> lib/type/static-v5/op_sem_alt.lua."* The substrate `abstract_body`
> (op_sem_alt.lua) explicitly: *"v5.0 spec gap: nested lambdas need shift-aware
> rewrite. For v5.0 minimal-core we leave the inner lambda body as-is."*

The CHKT Miller solution (`T-CHKT-Miller`) abstracts a result type into a
λ-chain by replacing each `UVar(aᵢ.id)` with the De-Bruijn level `Var(n - i)`
(op-sem § "Miller pattern fragment check"; `abstract_body` in op_sem_alt). When
the result contains an **inner `Lambda`**, the inner binder shifts the De-Bruijn
levels: a `Var` that refers to the *outer* abstraction, when it appears *under*
the inner binder, must be **shifted by the inner binder's depth** — otherwise it
either captures the inner binder's variable or refers to the wrong level. The
substrate handles only the no-inner-lambda case (`abstract_body` leaves the
inner lambda body as-is, with the comment that "uvars and De-Bruijn vars don't
mix" — true only until the abstraction *introduces* a `Var` under an existing
binder, which is exactly the nested case). M4 closes G4 normatively:

> **`abstract` is shift-aware.** Abstracting `UVar(aᵢ.id) ↦ Var(level)` while
> descending under a binder increments the target level by the binder depth
> crossed, using the **same `shift` discipline** the substrate already
> implements for β-reduction (`types.lua` `shift(t, d, cutoff)`, which adds `d`
> to every `Var ≥ cutoff` and increments `cutoff` under each `Lambda` —
> `shift(t.b, d, cutoff + 1)`). Concretely: `abstract` carries a `cutoff` (the
> number of binders crossed); the replacement for `UVar(aᵢ.id)` at a point under
> `c` inner binders is `Var(n - i + c)` (the outer level **shifted past** the
> inner binders). This is the De-Bruijn dual of capture-avoiding substitution
> and is **the existing `shift` machinery applied during abstraction** rather
> than a new mechanism.

The choice between the op-sem's two flagged options ("rejected at abstraction
time, or supported via shift-aware abstract?") is resolved: **supported via
shift-aware abstract** — rejection would make nested-constructor results
unrepresentable (`λX. λY. Map<X, Y>` as a Miller solution), which would cap HKT
at non-nested constructors and re-open F1 for the multi-parameter case. The
mechanism is the existing `shift`'s `cutoff` discipline reused at abstraction
time. G4 is closed by **reusing `shift`'s cutoff increment** (a substrate
mechanism), not by a nested-lambda special-case.

---

## 6. Downstream gating interfaces (for M5, M6, M11)

M4 gates three later modules. This section states the **concrete interfaces**
each relies on — the property the program requires of M4 so those modules can
build without re-deciding kinds.

### 6.1 M5 (effect rows) — the interface

M5 represents effects as a **dedicated structurally-compared component of
`TArrow`** (Foundational Decision #2; M3 §3.1 reserved the seam) with
**subset-on-labels subtyping** over effect **rows**. M4 supplies:

- **The kind of effects.** An effect (`!throw`, `!yield`, the substrate's
  `Const("!name")` heads with `effect_apply` building `App(Const("!name"),
  arg)` chains — `types.lua` `effect`/`effect_apply`/`is_effect`) is **kinded**:
  a nullary effect label is kind `Effect` (a **new base kind M4 reserves for
  M5**, distinct from `Type` so an effect can never be unioned with a value type
  or land in a value-type position — the §1.4 kind-error discipline enforces
  "`T & !effect` on a non-arrow value is meaningless and must not be
  representable", which is exactly Foundational Decision #2's requirement). A
  parameterized effect (an effect constructor) has kind `Type -> Effect` or
  `Effect -> Effect` as M5 needs.
- **The row kind.** M5's effect **rows** are kinded `Row(Effect)` (a row of
  effect labels), a third base-kind-family M4 reserves. M4's commitment: **rows
  are kinded entities outside the value lattice** (parallel to packs, M3 §4, and
  to constructors, §1.1) — a `Row(Effect)` is never a lattice operand, so
  subset-on-labels subtyping (M5's rule) is decided by M5's row machinery, not
  by M1's value emptiness. M4 fixes only that **the effect component of an arrow
  is kind `Row(Effect)`, the arrow itself is kind `Type`, and the kinding rule
  `K-Arrow` (§1.3) extends in M5 to additionally demand the effect component
  kind `Row(Effect)`** — leaving the row subtyping algorithm to M5.
- **Why M4 must precede M5.** M5 cannot decide where the effect component lives
  or that it stays off the lattice without the kind discipline that says "an
  effect is not kind `Type`, so it cannot be a value-type operand." That is the
  substrate-before-consumers reason M4 gates M5. M4 reserves `Effect` and
  `Row(Effect)` as kinds; M5 specifies their inference and subtyping.

### 6.2 M6 (`__index` walking / iterator protocol) — the interface

M6 walks `__index` chains on missing-field lookup and resolves the iterator
protocol; the substrate flags chain-walking as *"owed when CHKT lands (because
metatables can be type-applications)"* (op-sem § "What this spec does NOT cover"
item 3) and *"chain-walking interacts with HKT-shaped metatables"* (op-sem
T-CTSeal note). M4 supplies:

- **Metatables can be type-applications, kind-checked.** A metatable whose
  `__index` is `App(F, A)` (an HKT-shaped metatable) is resolved by **kinding
  the application to `Type`** (§1.3 `K-App`) and **β-reducing it**
  (`T-CHKT-Reduce`, §3.2) to a concrete record before the field walk. M4's
  interface to M6: **`__index` resolution may require a CHKT reduction step; M6
  invokes M4's β-reduction (`instantiate`) on a kind-`Type`-checked application
  to obtain the record whose fields it walks.** M6 never walks an unreduced or
  ill-kinded `__index`; kinding (§1.4) guarantees the walked target is a
  `Type`-kinded record.
- **The iterator protocol is a constructor interface.** A `pairs`/`ipairs`
  iterator (M-final's iterator protocol) is typed as a constructor-shaped
  interface (an iterator over `Iter<K, V>`-style application). M4's interface:
  **the iterator's element-type relationship is an HKT application
  (`Iter<K, V>` is `App(App(Iter, K), V)`, kind `Type`), so the generic-for
  rule M6/M-final defines lowers onto CHKT application + the index-signature
  generic, not a name-keyed `pairs` handler.** M4 fixes that the iterator
  protocol is *expressible* as a kinded constructor; M6 (the `__index`/protocol
  walk) and M-final (the `pairs`/`ipairs` declarations) consume it.
- **Why M4 must precede M6.** M6's chain-walk soundness depends on "the walked
  `__index` is a fully-applied `Type`-kinded record," which only kinding
  establishes. M4 gates M6 on this guarantee.

### 6.3 M11 (indexed access) — the interface

M11 makes `T[K]` a first-class lattice op with distribution
(`T[K₁|K₂] = T[K₁] | T[K₂]`), negated keys, and the three record-shape
semantics. M4 supplies:

- **`T[K]` requires `T : Type` and `K : Type`.** Indexed access is **kind-gated
  to value-type operands** (§1.4): `List[integer]` where `List : Type -> Type`
  is a **kind error** (you index a *value*, not a constructor — to index a
  list-of-ints you write `List<integer>[index]`, indexing the *applied* type).
  M4's interface: **M11 may assume both operands of `T[K]` kind to `Type`**; an
  ill-kinded index is a `kind_mismatch` caught before M11's lattice
  distribution runs.
- **Indexing through an HKT application reduces first.** `F<A>[K]` where `F` is
  a constructor variable is resolved by β-reducing `F<A>` (`T-CHKT-Reduce`,
  §3.2) to a `Type`-kinded record/type, *then* applying M11's indexed-access
  semantics. M4's interface: **M11's `T[K]` sees a `Type`-kinded, fully-reduced
  `T`; any HKT application in `T` is discharged by M4's CHKT reduction before
  M11's distribution rule fires.** This is the kind-level guarantee that lets
  M11 define `T[K]` over the value lattice without a constructor case.
- **Why M4 must precede M11.** M11's distribution and negated-key rules are
  defined over the value lattice; they are sound only because kinding guarantees
  `T` and `K` are value types. M4 gates M11 on the `Type`-kind guarantee.

---

## 7. Parity discipline (identical across interpreters)

The kind system and CHKT dispatch must produce **byte-identical** results in
`op_sem.lua` and `op_sem_alt.lua` (the dual-interpreter premise; M1 §F2 parity
fixtures). M4's parity-load-bearing quantities, all **fully spec-determined**
(no representation freedom):

1. **Kind unification is equality-only first-order unification** (§2.1) with a
   fixed decomposition order (`KEq(K₁->K₂, K₃->K₄) ⇒ KEq(K₁,K₃), KEq(K₂,K₄)`,
   left-then-right) and the union-find occurs-check — both interpreters run the
   identical algorithm and bind the identical `KVar` roots.
2. **Unbound-`KVar` defaulting to `Type`** at declaration close (§2.2) — pinned,
   so neither interpreter leaves a kind ambiguous differently.
3. **The Miller-fragment membership test** (§3.4, op-sem § "Miller pattern
   fragment check") — the exact side-conditions (`?F` unbound, args rigid +
   pairwise-distinct, FV-subset) are spec-fixed, so both interpreters classify
   the *same* applications as in/out of the fragment and `Park` at the *same*
   points.
4. **η-contraction at the kinding boundary** (§3.5) — the syntactic η-redex
   side-condition is fixed, so both interpreters normalize the *same* lambdas to
   η-normal form before unification.
5. **Shift-aware abstraction's `cutoff` discipline** (§5) — the
   `Var(n - i + c)` replacement and the `shift` cutoff increment are the
   substrate's existing `shift`/`instantiate`, so both interpreters abstract
   nested binders identically.
6. **The CHKT/HOUnify head-rigidity park/wake** (§3.2, op-sem `S-Wake-Head`) —
   head-watchers vs ordinary watchers, the at-quiescence `T-HOUnify-Stuck`
   error — adopted unchanged from the substrate, already parity-encoded.

Because kind inference is decidable equality-unification (no bail-out, §2.4) and
the CHKT dispatch is the already-parity-tested substrate machinery, M4 adds **no
new bail-out point** — the only bail-out remains M1's value-level `4096` budget,
reached only when a β-reduced `CEq` body carries non-trivial negation (§3.4).
Both interpreters therefore bail at the identical point (M1's pin) or not at all.

---

## 8. Reconciliation of the De-Bruijn calculus into the kinded design

The v5 substrate's type-lambda calculus (`types.lua`:
`Var` / `Lambda` / `App` / `shift` / `instantiate`; the CHKT dispatch in
`op_sem*.lua`) is **the realization layer of M4's kind system**, reconciled as
follows:

- **`Var(i)` (De-Bruijn level) is a kind-`Type` bound type variable** introduced
  by an enclosing `Lambda` or `Forall` binder. `K-Var` (§1.3) reads its kind
  from `Γ`. De-Bruijn levels (not names) are the substrate's representation; M4
  keeps it (the eager-shift discipline, op-sem § "Solver-tvar identity vs De
  Bruijn levels": `UVar` gensyms never shift, `Var` shift under β) — kinds are
  layered *on top* of the existing De-Bruijn machinery, not in place of it.
- **`Lambda(k, b)` is a type constructor**; M4 **upgrades the opaque string kind
  tag `k` to a real `Kind`** (carrying `KVar`s, §1.2). This is the one
  substrate *data* change M4 implies (§9 blast radius): `k : string` →
  `k : Kind`. The β-reduction (`instantiate`, eager shift on bind) is unchanged.
- **`App(f, a)` is constructor application**; `K-App` (§1.3) kinds it,
  `T-CHKT-Reduce` β-reduces it. Curried multi-argument application
  (`App(App(Map, x), y)`) is the curried arrow kind `Type -> Type -> Type` —
  the substrate's currying *is* the kind grammar's currying (§1.2).
- **`shift` / `instantiate` are the capture-avoiding substitution engine**; §5
  extends abstraction (the Miller-solution direction) to be shift-aware,
  reusing `shift`'s `cutoff` increment. β-reduction (`instantiate`) already
  handles nested binders correctly (`instantiate(body.b, arg, depth + 1)`); only
  the *inverse* (abstraction) had the G4 gap.
- **The CHKT/HOUnify machinery is the constructor-application solver**; M4
  adopts it (§3.2) and **kind-gates** it (every rule now has a kind
  side-condition that, with kind inference §2, turns the substrate's "arity
  mismatch surfaces as a downstream shape error" into a precise `kind_mismatch`
  at the application site).
- **`effect_apply` / `is_effect`** (the `Const("!name")` application chains) are
  reconciled in §6.1: an effect head is kind `Effect` (M5's reserved kind), an
  effect application is `App` at kind `Effect`. M4 reserves the kind; M5 uses it.

**No contradiction with rewrite-design.** rewrite-design §1.1 names "constructor
application `Fn(...)`, `Rec(...)`" and "`App(n, …) <: App(n, …)` per-position
variance" but is **thin on kinds** (it specifies no kind grammar, no kind
inference, no constructor-variable discipline — it leaves HKT as a deferred
roadmap item, §6's "HKT dispatch through records of generic functions remains an
expressiveness gap"). M4 **fills** that thinness with the De-Bruijn calculus
already in the v5 substrate, kinded — consistent with rewrite-design's
constructor-plus-boolean lattice frame (M1 §3.5), since a kinded constructor is
exactly "one decomposition rule (`K-App` + `T-CSub-App-Var`) plus boolean
handling on its `Type`-kinded applications."

---

## 9. Migration / blast-radius note (for the later implementation program)

M4 changes the implemented v5 substrate. M4 performs **no** migration (the
design program writes no code); it records the cost.

1. **`Lambda`'s kind tag becomes a real `Kind` (`types.lua`).** `Lambda(k, b)`'s
   `k : string` (opaque documentation tag) becomes `k : Kind` (§1.2, with
   `KVar` leaves). New data: a `Kind` AST (`Type`, arrow kinds, `KVar`) and a
   kind substitution `σ_K` (§2.2) parallel to `subst.lua`'s value substitution.
   This is the enabling substrate for kind **inference** (G2). Gated before the
   CHKT kind side-conditions (§3.2) can fire.
2. **Kind inference (§2) is new, but small.** First-order equality unification
   over `{ Type, (->), KVar }` with occurs-check + defaulting-to-`Type`. No
   bounds, no lattice, no bail-out — far smaller than M2's value bound graph.
   Both interpreters encode it independently (§7 parity).
3. **CHKT/HOUnify dispatch is already implemented** (`op_sem*.lua`, adopted §3.2
   verbatim in structure). The changes are **additive kind side-conditions**
   (§3.2) — each CHKT rule gains a kind-unification check that turns a downstream
   shape error into a `kind_mismatch`. This is the substrate's owed
   "kind-checking extension" (op-sem "Spec gap (v5.0)").
4. **Variance-under-Lambda (G10).** `T-CSub-App-Var` (op_sem `rule_T_CSub_App_Var`,
   op_sem_alt likewise) gains the `Lambda`-head case: derive per-position
   variance by the §4.1 polarity walk when the head is a `Lambda`, look up the
   registry when it is a `Const`. The polarity walk is M2 §5.1's, reused.
5. **Shift-aware abstraction (G4).** `abstract_body` (op_sem_alt; the matching
   op_sem path) gains the `cutoff` increment under inner `Lambda`s (§5), reusing
   `shift`'s discipline. This replaces the "leave the inner lambda body as-is"
   stub.
6. **η-contraction (G3).** A normalization at `Lambda` construction / kinding
   boundary (§3.5). New, small, decidable.
7. **Reserved kinds `Effect` and `Row(Effect)` (§6.1)** are **declared by M4,
   used by M5** — no M4 code beyond the kind grammar; M5 owns their inference.

**Keep, do not rewrite** (substrate decisions M4 reconciles *in*, unchanged):
the De-Bruijn `Var`/`Lambda`/`App` calculus and `shift`/`instantiate`
(§8 — kinds layer on top); the CHKT/HOUnify dispatch and head-rigidity park/wake
(§3.2 — adopted, only kind-gated); the variance **registry** for named
constructors (§4 — the `Lambda` case is *added*, the registry *kept*); the
curried-`App` representation of `?F<a₁..aₙ>` (§3.1); the
`effect_apply`/`is_effect` chains (§6.1 — kinded, not changed).

**Parity discipline (carries forward).** Both interpreters independently encode
the kind judgement, kind inference, the kind-gated CHKT rules, the §4 variance
derivation, the §5 shift-aware abstraction, and §3.5 η-contraction; the parity
fixtures are a deliverable of the implementation program. M4 is written as
relations + a first-order kind unifier + reused substrate operations (not a
single reference implementation), so the two encodings remain possible and
decide identically (§7).

**Behavior conservation (§A11).** The test suite stays green at every migration
commit. Staging: add the `Kind` AST + `σ_K` → kind inference (equality
unification) → kind-gate the CHKT rules (G2 precision) → add the `Lambda`-head
variance case (G10) → shift-aware abstraction (G4) → η-contraction (G3). Each a
green commit. The CHKT dispatch itself is behavior-conserving (already
implemented); the new content is kinds + the four closed gaps' mechanisms.

---

## 10. Closes

- **F1** (`typechecker-roadmap.md`):
  > *"Higher-kinded types … `<F: SomeGeneric>` parses but does not compose — `F`
  > is treated as a type variable, not a type constructor."*

  Closed by **representing a constructor variable as a `UVar` of higher kind,
  applied via curried `App`, solved by the kind-gated CHKT/HOUnify dispatch**
  (§3.1–3.2). `F` is no longer a plain type variable: it carries an arrow kind
  (`Type -> Type`), so `F<A>` composes as a kind-checked application that
  β-reduces (`T-CHKT-Reduce`) when `F` is known and Miller-unifies
  (`T-CHKT-Miller`) when it is inferred. Functor/Monad/Traversable shapes are
  expressible. Substrate mechanism (kind + CHKT), name-agnostic, no special-case.

- **G2** (`v5-gaps.md`): *"Kind checking exists but kind inference does not."*

  Closed by **kind inference as first-order equality unification over
  `{ Type, (->), KVar }`** (§2): the opaque `Lambda` kind tag becomes a real
  `Kind` carrying `KVar`s; `KEq` decomposes structurally with an occurs-check
  and defaulting-to-`Type`; the CHKT rules are kind-gated (§3.2) so an arity
  mismatch surfaces as a precise `kind_mismatch` rather than a downstream shape
  error (the substrate's owed extension). Decidable, no bail-out (§2.4).
  Substrate mechanism.

- **G10** (`v5-gaps.md`): *"Variance under Lambda: registry covers named TConst
  only; anonymous lambdas default invariant."*

  Closed by **deriving per-position variance from the lambda body's polarity**
  (§4) — M2 §5.1's polarity walk reused, so `T-CSub-App-Var` is one rule
  (registry lookup for `Const` heads, structural polarity derivation for
  `Lambda` heads). A non-trivial `Lambda` in a `CSub` is sound without prior β.
  Substrate mechanism, not a default or a name-keyed registry hack.

- **G4** (`v5-gaps.md`): *"No shift-aware abstraction over nested lambdas;
  capture-avoiding substitution fails for nested binders."*

  Closed by **making `abstract` shift-aware** (§5): the Miller-solution
  abstraction carries a `cutoff` and replaces `UVar(aᵢ.id)` with
  `Var(n - i + c)` under `c` inner binders, reusing `shift`'s existing `cutoff`
  increment. Nested-constructor Miller solutions (`λX. λY. Map<X,Y>`) become
  representable. The op-sem's fork is resolved to **supported via shift-aware
  abstract** (not rejected-at-abstraction). Substrate mechanism (reused `shift`).

- **G1** (`v5-gaps.md`): *"Miller pattern fragment restricted to UVar/Const args
  only; complex argument shapes not handled."*

  Closed by **specifying the full Miller pattern fragment (any rigid distinct
  argument) as the target** (§3.4) — the maximal *decidable, unitary* HO
  fragment — and recording the substrate work (alpha-equivalence + occurs
  engine, plus §5's nested-binder shift) as the blast radius. The decision is
  pinned: **HKT unification stays in the Miller fragment; it does not extend
  into undecidable full HO unification**, and outside the fragment it **reuses
  M1's bail-out discipline** (`T-CHKT-Park` → `HOUnify` → `T-HOUnify-Stuck`
  "ambiguous constructor variable" error — reject, never guess). Substrate
  mechanism + an explicit, justified decidability boundary.

- **G3** (`v5-gaps.md`): *"No eta-equivalence in Miller check."*

  Closed by **η-contraction at the kinding boundary** (§3.5): `λX. F<X>`
  η-contracts to `F` as a decidable syntactic normalization before CHKT
  dispatch, so the Miller check compares η-normal forms and treats `λx. F x` and
  `F` as equal **without** an η-aware (search-reintroducing) unifier. Substrate
  mechanism (normalization), not a per-case Miller special-case.

Each closure is a **substrate mechanism**, not a hardcoded result, per the
CLAUDE.md planning rules and the README cross-walk discipline.

---

## 11. Open questions (for the reviewer — genuine forks not resolved unilaterally)

1. **M3's pack-var kind question — RESOLVED here (confirming M3's lean).** M3
   §9.4 deferred: *"does a pack var need a kind under M4? M3's lean: pack vars
   are **outside** the kind system, parallel to row vars."* **M4 confirms the
   lean: a `TPackVar` is outside the kind system.** Reason: kinds classify
   type expressions that *reach the lattice* (kind `Type`) or *await application
   to `Type`* (arrow kinds). A pack var is **neither** — it is a binding-time
   *arity* device for a telescope (M3 §5.2), bound by alignment, never applied,
   never a lattice operand (M3 §4.1). It has no `Type`-vs-arrow distinction to
   make: the *items* inside a pack are kind `Type` (and kind-checked as such by
   `K-Arrow`'s "each `args.items[i] : Type`", §1.3), but the pack var binding
   the tail is a length variable, not a kinded entity — exactly as a row var
   (`TRowVar`) is outside the kind system and is a separate `row_bindings`
   metavariable. Were a pack var kinded, we would need a "`Pack` kind"
   participating in kind unification, which would buy nothing (pack alignment is
   already decided deterministically by M3 §2, not by kind inference) and would
   couple M3's clean binding discipline to M4's machinery for no gain. **The
   pack-var-kind question is closed: pack vars are outside the kind system, like
   row vars** — confirming M3's lean with the structural reason. (The kind
   system *does* touch packs at exactly one well-kinded seam: `K-Arrow` requires
   each pack *item* to kind `Type`; the pack *itself* is unkinded.)

2. **Should `Row(Effect)` and `Effect` be M4-owned kinds or M5-owned?**
   **DEFERRED — confirm jointly at M5.** §6.1 *reserves* `Effect` and
   `Row(Effect)` as kinds so M4's kind-error discipline can forbid an effect in
   a value-type position (Foundational Decision #2's "`T & !effect` on a
   non-arrow value must not be representable"). Whether the *grammar entry* for
   these kinds lives in M4's kind AST or is added by M5 is a packaging detail
   with no soundness content (M4 must reserve the *distinction*; M5 owns the
   *inference and subtyping* of rows). M4's lean: M4 reserves the base kinds
   `Effect` and the `Row(_)` kind-former in the grammar; M5 specifies their
   semantics. Conservatively sound either way (reserving an unused kind admits
   no programs); confirmed jointly with M5.

3. **Kind annotation surface syntax for `<F: Type -> Type>`.** **DEFERRED — UX
   batch / M-final.** M4 fixes the *semantics* (a constructor variable carries an
   arrow kind). The *surface syntax* in `--:`/`--::` annotations — whether
   `<F: Type -> Type>`, `<F<_>>`, or an inferred bare `<F>` whose kind is
   discovered from uses (§2) — is a syntax fork with no soundness content.
   M4's lean: support **both** an explicit `<F: K>` kind annotation and an
   inferred bare `<F>` (kind inferred from `F`'s applications, defaulting to
   `Type` if never applied, §2.2). Deferred to the annotation-syntax batch so it
   is decided once with the other `--::` syntax; the inference mechanism (§2) is
   fixed regardless of the chosen surface.

4. **Kind polymorphism / higher kinds beyond `Type^n -> Type`.** **OUT OF SCOPE
   — flagged, not opened.** §1.2 fixes the kind grammar at first-order over the
   single base kind `Type` (no `forall κ`, no kind of kinds). This is the
   minimal system that closes F1 and keeps kind inference trivially decidable
   (§2.4). A future need (e.g. a `forall κ. …` over kinds for a kind-polymorphic
   container) is an **explicit out-of-scope** marker here, in the same spirit
   M13 puts impredicativity out of scope — recorded as an OPEN-QUESTION so a
   later module *escalates to a substrate extension* rather than silently
   widening the grammar. No current corpus item needs it; if one arises it is a
   new substrate decision, not a quiet `KVar`-grammar addition.

5. **Full-Miller occurs/alpha engine timing.** **DEFERRED — confirm at
   implementation.** §3.4 closes G1 by *specifying* the full Miller fragment
   (any rigid distinct argument) as the target, but the substrate today admits
   only `UVar`/`Const` args. Whether the implementation widens to full-Miller in
   one step or stages (UVar/Const → arbitrary rigid trees) is an implementation
   sequencing detail, not a design fork: the *fragment boundary* (Miller, not
   full HO) is fixed (§3.4), and the staging is behavior-conserving (each stage
   admits strictly more programs, never changes a decided result). Confirmed at
   implementation; no design content outstanding.
