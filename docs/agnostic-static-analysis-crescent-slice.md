# Agnostic Static Analysis: Tiny Crescent Slice (`crescent.slice.v1`)

Status: design pass. Mechanization follows against this doc.

This document is ladder rung 5 — the first *real* target of the agnostic
static-analysis ladder and its final validation rung. It instantiates
`docs/agnostic-static-analysis-object-model.md` with a small but real subset of
Crescent/Lua semantics, checked over actual files in `lib/`. It is also the
first consumer of the **ratified kernel** (`docs/decisions/kernel-recommendation.md`,
user-ratified 2026-06-12): a bidirectional checking spine, ONE cycle-guarded
equirecursive subtype relation, local generic instantiation as witnessed
evidence, solvers untrusted, and a separate flow-narrowing layer.

It is hosted on the same substrate the prior four rungs validated unchanged
(`lib/type/analysis/init.lua`). The slice is `crescent.slice.v1`. The substrate
must learn nothing new: no `Type`, `Context`, `Judgment`, `Subtype`, or
`Narrowing` object kind. Types, contexts, subtype witnesses, instantiation
witnesses, and narrowing derivations all ride `ArgValue` claim args and evidence
exactly as STLC's `has_type` did.

This doc derives the slice's semantics **whole, from Lua's value universe** — the
v6 principle restated in the design doc's "First Validation Ladder": *start from
what values the language can produce, not from what the legacy checker
implemented.* The corpus (`lib/type/analysis/corpus/`) orders the tests; it never
orders the design. Where the value-universe derivation strained against the
ratified kernel or the substrate, the strain is reported in §10 — that strain is
the rung's data.

A note on relationship to the ratified decision: this doc is a coherent,
implementable *fragment* of the ratified kernel and of the rewrite-design target
lattice (`docs/typechecker-rewrite-design.md`). Every inclusion and every
deferral below is traceable to §3 of the kernel decision. Any contradiction with
that decision would be a bug in this doc, not a fresh judgment call. §10 records
the one place the derivation pushed on the fence and how it was resolved without
crossing it.

---

## 1. The Value Universe and the Derived Type Grammar

### 1.1 The value universe

Lua's runtime produces values of exactly these kinds (LuaJIT 5.1, the Crescent
target): `nil`, `boolean`, `number`, `string`, `table`, `function`. (`userdata`,
`thread`, and FFI `cdata` exist; the slice defers `cdata`/`userdata`/`thread`
types — see §1.4 — because no v1 corpus fixture produces them and the value
universe's *table/function/scalar* core is what the corpus exercises.) Crescent
adds, at the *type* level only (no new runtime values), literal singleton types
and the boolean lattice of the rewrite-design.

The derivation rule is mechanical: **a type constructor is admitted into v1 iff it
is required to describe, or to discriminate between, values the universe can
produce — and the ratified kernel's §3 admits it.** Nothing is admitted because a
fixture needs it; fixtures only schedule the tests.

### 1.2 The grammar (derived)

```text
Ty =
  -- primitives: one per value kind the slice describes
    nil
  | boolean
  | number
  | integer                         -- integer <: number (LuaJIT integer subkind)
  | string
  | function                        -- the untyped-function top (any callable)
  | unknown                         -- TS-unknown: top; caller must narrow
  | never                           -- bottom; uninhabited; union-absorbed

  -- literal singletons: a value is sometimes known exactly
  | lit_bool(b)                     -- true | false
  | lit_int(n)                      -- 42
  | lit_num(x)                      -- 3.14   (non-integer-valued)
  | lit_str(s)                      -- "GET"

  -- functions: function values carry an arity/shape
  | fn(params: Params, ret: Ret)    -- params contravariant, ret covariant

  -- tables: the structural heart of the universe
  | rec(fields: [Field], rows: Rows)        -- record with closed/open row
  | indexer(key: Ty, val: Ty)               -- { [K]: V }   (distinct from rows)
  | rec_with_indexer(fields, rows, indexer) -- named fields + an index signature

  -- boolean lattice (v1 fragment: union + intersection only; NO complement)
  | union(members: [Ty])            -- A | B
  | inter(members: [Ty])            -- A & B

  -- recursion: tables can be self-referential
  | mu(var, body)                   -- equirecursive μX.T, hash-consed
  | tyvar(var)                      -- bound occurrence of a μ variable

Field  = { key: string, ty: Ty, optional: bool, readonly: bool }
Params = { fixed: [Ty], vararg: Ty | nil }     -- (A, B, ...C)
Ret    = { fixed: [Ty], vararg: Ty | nil }     -- multi-return as a return-tuple;
                                               --   () -> (A, B) is fixed=[A,B]
Rows   = "closed" | "open"          -- "open" is the `...` structural marker
```

### 1.3 Justification of each constructor *from the universe*

- **`nil`, `boolean`, `number`, `string`** — one primitive per scalar value kind.
  `nil` is load-bearing because Lua makes absence a first-class value (`t.x` on a
  missing key yields `nil`); the universe forces `nil` into the lattice, and a
  union `T | nil` is the canonical "maybe present" shape.
- **`integer`** — LuaJIT distinguishes integer-valued numbers; the rewrite-design
  lattice (§1.1) and the reference both pin `integer <: number`. This is a
  *subkind* of `number`, not a separate value kind, so it enters as a primitive
  with a single hard-wired subtype edge `integer <: number`. Justified: the
  universe produces integer-valued numbers, and discriminating them (`tonumber`
  returns `number | nil`; `math.floor` returns `integer`) is a real distinction
  the corpus's stdlib typing exercises.
- **`function`** — the function value kind, untyped. Needed as the top of the
  function sublattice for "any callable" annotations (`--: function` in the
  reference) and as the join of incomparable `fn` shapes.
- **`unknown` / `never`** — top and bottom. `unknown` is forced by the universe:
  a value whose kind is not yet discriminated must have *some* type, and that type
  must be one the caller cannot use without narrowing — exactly TS-`unknown`.
  `never` is the empty union / uninhabited type, forced by union normalization
  (`union([])` = `never`) and by narrowing a value to a kind it cannot have.
  `any` does **not** exist in the slice (CLAUDE.md: "`any` does not exist — do not
  write it").
- **Literal singletons** — the universe produces *particular* values (`"GET"`,
  `42`, `true`), and Lua programs branch on them. A type system that cannot name
  `"GET"` cannot describe a discriminated union keyed on a string tag, which is
  the dominant Lua idiom. Each literal is a singleton subtype of its base
  (`"GET" <: string`, `42 <: integer <: number`, `true <: boolean`). Derived from
  the universe's ability to produce known values, not from any fixture.
- **`fn` (function types)** — function values have an arity and a shape. The
  universe produces multi-return (`return a, b`) and varargs (`...`), so the
  function type must carry **`Ret` as a return-position tuple** (multiple returns)
  and **`Params`/`Ret` with an optional trailing `vararg`** (varargs-as-tuple-
  spread). Contravariant params / covariant return is the only sound variance for
  a value that is *called*. Justified by the universe: a function value is exactly
  "a thing that consumes a parameter tuple and produces a return tuple."
- **`rec` / `indexer` / `rec_with_indexer` (tables)** — the table is the
  universe's one compound value, and it carries the most structure. The universe
  produces:
  - tables with *named string keys* → `rec` with `Field` list;
  - tables whose keys are absent/optional (`t.x` may be `nil`) → `optional` on a
    `Field`;
  - tables used as *maps* with homogeneous key/value type → `indexer` `{ [K]: V }`;
  - tables that are *both* (named fields plus a map tail) → `rec_with_indexer`;
  - tables that are *extensible* (more fields may be present than listed) → the
    **open row** marker `...`.
  The hard distinction the reference mandates is preserved: **`...` (open row) is a
  structural subtyping marker — "at least these fields, reading an unlisted field
  yields `unknown`" — and `{ [K]: V }` (indexer) is an index signature — "any key
  of type `K` maps to `V`."** They are different constructors (`Rows = "open"`
  vs `indexer(...)`), never conflated. CLAUDE.md: "Confusing them is wrong on
  either side." Tuples (`{ A, B, C }`) are `rec` with integer-literal positional
  keys; they are not a separate constructor (reference: "tuples are tables with
  positional integer-literal slots").
- **`union` / `inter`** — the boolean lattice's two *monotone* operators. The
  universe forces union: a function can `return x or nil`, producing `T | nil`; a
  discriminated value is `LoginCmd | LogoutCmd`. Intersection is forced by
  *narrowing* (a narrowed value is `T & string`) and by overloaded-function types
  (`(A -> r) & (B -> r)`). Both are admitted by kernel §3 ("**unions**
  (check-against-each); **intersections**"). **Complement `~T` is NOT admitted** —
  see §1.4.
- **`mu` (equirecursive recursion)** — the universe's tables can be
  self-referential: `HamtNode = Leaf | Interior` where `Interior.children`
  contains `HamtNode`. A value of a recursive type is produced and traversed at
  runtime (the `lookup`/`tree_sum` fixtures), so the type lattice must close under
  recursion. The kernel mandates **equirecursive μ via hash-consing from day one**
  (§3.3, the TODO:826 fix): structural identity → tid identity makes cycle
  detection sound and retires the stack-overflow class. Equirecursive (not
  isorecursive): `μX.T` and its one-step unfolding `T[μX.T/X]` are *the same type*,
  no fold/unfold coercions — because Lua values carry no roll/unroll tag.

### 1.4 What is absent, and why (the ratified deferral list)

Each absence below is the kernel decision's §3 deferral list, restated at the
grammar level. None is a result deficit; each is a substrate/lattice extension
behind the subtype-relation boundary with a written un-defer trigger (kernel §3
table). The slice does **not** smuggle any back in.

| Absent constructor | Why absent (derivation + kernel cite) | Un-defer trigger (kernel §3) |
|---|---|---|
| **Complement `~T`** | The universe does not *produce* a "not-T" value; complement is a lattice operation, not a value kind. v1's narrowing covers truthy branches by **intersection-with-a-positive-atom** and approximates falsy branches *soundly wider* without `~T` (§4). Kernel §3.5: narrowing "*without* requiring complement in v1." | A corpus count showing `T & ~Atom` falsy branches are load-bearing in real `lib/` code, AND a ⊥-certificate witness the substrate checker validates locally. |
| **Match types** (`match X { ... }`) | Type-level computation over types; no value-universe justification (types are not values here). Kernel §3 defers; reduction is two subtype queries + emptiness, which v1 lacks (no emptiness/complement). | Complement landed (prerequisite) AND measured corpus demand beyond existing `$`-intrinsics. |
| **RDNF / biunification / coalescing** as the subtype producer | v1's subtype relation is the structural + equirecursive + union/intersection *fragment* of the rewrite-design lattice. RDNF is the negation-complete machinery; absent because complement is absent. | The structural relation hits an expressiveness wall a real `lib/` type forces, AND the EXPTIME-emptiness benchmark clears timeout-30 on the corpus. |
| **Parametric / semantic-subtyping polymorphism** | The slice's one inference is **local generic instantiation at call sites** (§3 of the grammar has no `forall` constructor; instantiation is a witnessed substitution, §2.4). Full parametric polymorphism is a *replacement* bar for crescent's working rank-N, not a gap. Kernel §3.4. | Only if structural + local instantiation proves insufficient on the corpus (high evidence required; must not regress working rank-N). |
| **Rank-N beyond local, HKT, effects** | No value-universe pressure in the slice; no corpus fixture produces a higher-rank value, a kinded type, or an effect. Kernel §3 defers all three. | Rank-N: a corpus site local instantiation cannot check. HKT: an independently-justified kinding layer. Effects: a second effect beyond a first. |
| **`cdata` / `userdata` / `thread` types** | Value kinds the universe *can* produce, but no v1 corpus fixture does, and each needs FFI-cdef or coroutine machinery out of slice scope. Recorded as a value-universe-justified absence, distinct from the kernel deferrals. | A corpus fixture (real `lib/` file) producing an FFI `cdata` or coroutine value that the slice's syntax subset reaches. |
| **`newtype` / nominal opaqueness, indexed-access `T[K]`, `typeof`** | Lattice operations / type-expression forms with no v1 corpus demand; rewrite-design features, not value kinds. | A corpus fixture forcing nominal identity or type-expression projection. |
| **Metatables / metamethod slots (`#__add`)** | The universe produces metatable-bearing values, but no v1 fixture's *checked syntax* (§5) reads a metamethod; operator dispatch on metatables is deferred with the imperative-store pressure. | A corpus fixture whose checked syntax dispatches an operator through a metamethod. |

The fence (kernel §3): **v1 is the bidirectional kernel + the
structural/union/intersection/μ fragment of the lattice.** Not RDNF, not
complement, not match types, not parametric semantic subtyping, not HKT/effects.

---

## 2. The Hosted Semantics `crescent.slice.v1`

The slice is one `SemanticsEntry`. The substrate routes checking to its hosted
checker; it interprets none of the predicates or methods below. This mirrors
`stlc.min` exactly — types and contexts ride `ArgValue`, the checker
parses-not-casts, and every accepted claim carries `unverified_checker_trust`.

### 2.1 Semantics entry

```text
SemanticsEntry {
  id = "crescent.slice.v1",
  version = "0",
  claim_predicates = [
    "has_type",        -- bidirectional synthesis result: term ⇒ T under Γ
    "checks_against",  -- bidirectional check: term ⇐ T under Γ succeeds
    "subtype",         -- A <: B   (the ONE subtype relation, as a claim)
    "narrows",         -- under guard g on path p, x has refined type T'
    "well_typed_type"  -- T is a structurally valid slice type (well-formedness)
  ],
  observation_predicates = [
    "syntax",          -- a parsed Lua syntax node (produced by the parser frontend)
    "annotation"       -- a --: / --:: annotation attached to a node
  ],
  evidence_methods = [
    -- synthesis rules (term ⇒ T)
    "synth_lit", "synth_var", "synth_call", "synth_table",
    "synth_index", "synth_function", "synth_and_or_not",
    -- checking rules (term ⇐ T)
    "check_against", "check_cast",
    -- the subtype relation, as evidence for a `subtype` claim
    "subtype_witness",
    -- local generic instantiation at a call site (witnessed substitution)
    "instantiate_witness",
    -- narrowing derivations
    "narrow_guard",
    -- well-formedness
    "type_shape_check",
    -- trusted boundary (FFI / external decl / force cast)
    "trusted_signature"
  ],
  trusted_methods = [ "trusted_signature" ]
}
```

The substrate learns **nothing** from these. As in STLC, the adversarial checks
(§2.6) confirm no `Type`/`Context`/`Judgment`/`Subtype`/`Narrowing` object kind
is ever stored, and the registry rejects any predicate/method not listed.

### 2.2 Claim forms (all context-in-args, per the STLC/lambda-rung rule)

```text
has_type(Γ, node_ref, T)
    Under typing context Γ (hosted data inline in args, an ordered binding list
    exactly as stlc.min's Context), the syntax node in artifact `node_ref`
    SYNTHESIZES type T. Γ and T are structurally part of claim identity, so
    has_type(Γ1, n, T) ≠ has_type(Γ2, n, T) — inherited verbatim from STLC's
    "Claim identity under context."

checks_against(Γ, node_ref, T)
    Under Γ, the node CHECKS against expected type T. Distinct predicate from
    has_type: synthesis produces a type; checking consumes one. This is the
    bidirectional spine made into two claim forms (synth ⇒ / check ⇐), so the
    inference boundary is visible in the claim, not hidden in the checker.

subtype(A, B)
    A <: B holds under the v1 subtype relation. A and B are hosted Ty data inline
    in args; structurally part of claim identity (so subtype(A,B) and subtype(B,A)
    are distinct claims, like alpha_eq's two orderings). NO context — subtyping is
    context-free in v1 (no bounded type variables in scope).

narrows(Γ, guard_ref, x, T_true, T_false)
    Under Γ, the guard syntax in `guard_ref` refines variable `x` to T_true on the
    truthy path and T_false on the falsy path. A SEPARATE positive claim (like
    lambda's free_in / not_free_in): the flow layer consumes synthesized types and
    produces refinement facts; it does not mutate has_type claims.

well_typed_type(T)
    T parses as a structurally valid slice Ty. Kept first-class so a well-
    formedness obligation (e.g. an indexer key that is not a primitive) can be
    surfaced, exactly as stlc.min keeps it.
```

`Γ` (`Context`) is the STLC binding list extended to slice types:
`Context = [{ name: string, type: Ty }]`, ordered, most-recent-wins, structurally
part of identity. No `Claim.scope`; it rides `args`. **This is the verbatim STLC
position** — the slice inherits it without a substrate change.

### 2.3 Evidence methods — the bidirectional rules

Each rule is an evidence method modeled on `stlc.min`'s var/abs/app: it
re-derives its conclusion from the artifact syntax node plus its premise claims,
checks the asserted `(Γ, node, T)` against what the rule produces, and records
dependencies (`artifact_content` for the node, `accepted_claim` for each
premise). The checker **validates its own inputs** (parse-not-cast); it never
trusts arg shape. Premise-not-yet-accepted returns `UNKNOWN` (retry), never
`REJECTED` — the order-independence discipline `beta_step` and `app_rule`
established.

**Synthesis rules** (`has_type(Γ, node, T)`):

- `synth_lit` — a literal node synthesizes its singleton type (`42` ⇒ `lit_int(42)`,
  `"GET"` ⇒ `lit_str("GET")`, `true` ⇒ `lit_bool(true)`, `nil` ⇒ `nil`). No
  premises; depends on the node artifact only.
- `synth_var` — a variable reference synthesizes its binding in Γ (most-recent-wins
  lookup), exactly `var_rule`. The asserted T must equal the binding. No premises.
- `synth_call` — application `f(a1..an)` ⇒ the function's return type, *after*
  checking each argument against the corresponding parameter (covariant return,
  contravariant params). Premises: `has_type(Γ, f_node, fn(P, R))` and one
  `checks_against(Γ, ai_node, P.fixed[i])` per argument (or the vararg tail). For a
  **multi-return** callee, the synthesized type of the call in a single-value
  context is `R.fixed[1]` (or `nil` if `R` is empty); in a multi-assignment
  context (`local a, b = f()`) the slots draw from `R.fixed` positionally, with
  absent slots `nil`. If `f`'s type is generic, the premise is an
  `instantiate_witness` (§2.4) producing the monomorphic `fn` first.
- `synth_table` — a table constructor `{ k1 = v1, ... }` ⇒ a `rec` (or
  `rec_with_indexer` if positional/integer-keyed entries are present) whose fields
  are the synthesized types of each value. Premises: one `has_type` per value
  expression. **Widening to a declared element type** (the table-construction-
  widening fixture) is *not* done by this rule — synthesis produces the precise
  literal-typed record; widening happens at the **checking boundary** (`check_against`
  against `{ [integer]: Insn, ... }`), where each entry is checked `<: Insn`. This
  is the bidirectional discipline: synthesis is precise, checking flows the
  expected (wider) type inward. (Resolves the fixture without a "two-step
  unknown→any→T" hack — see §6.)
- `synth_index` — field/index access `t.k` or `t[e]`:
  - on a `rec` with field `k` ⇒ that field's type (`nil`-joined if `optional`);
  - on a closed `rec` without `k` ⇒ reject (no such field);
  - on an *open* `rec` (`...`) without a listed `k` ⇒ `unknown` (the reference's
    open-row rule: reading an unlisted field on `...` yields `unknown`, NOT the
    indexer type);
  - on an `indexer(K, V)` with key `e` checking `<: K` ⇒ `V`;
  - on a `union` ⇒ the access distributes: accessible iff `k` is present in ALL
    members, result is the union of per-member results (reference: "only fields
    present in ALL members"). On an `inter` ⇒ present in ANY member.
- `synth_function` — a function definition `function(p1..pn) ... end` with `--:`
  param annotations ⇒ `fn(P, R)` where `P` is the annotated params and `R` is
  synthesized/checked from the body's `return` statements (joined by union across
  return paths). The body is checked under `Γ` extended with the params (context
  extension, the STLC `abs_rule` pattern). Premises: one `has_type`/`checks_against`
  per return statement under the extended Γ.
- `synth_and_or_not` — boolean connectives:
  - `a and b` ⇒ if `a` synthesizes a type known *truthy* and known type, the
    result is `(typeof a minus falsy) | typeof b`; for the common case where both
    operands are `boolean` (comparison results), the result is `boolean` — **not**
    `nil | boolean` (the boolean-narrowing fixture). The rule computes
    `falsy(A) = A & (nil | false-singleton)` as the part dropped on the truthy
    side; with no complement, it uses the *positive* decomposition: if `A <: boolean`
    then `a and b : boolean` directly (both branches boolean).
  - `a or b` ⇒ `(typeof a minus falsy) | typeof b`.
  - `not a` ⇒ `boolean`.

**Checking rules** (`checks_against(Γ, node, T)`):

- `check_against` — the mode-switch. To check `node ⇐ T`: synthesize `node ⇒ S`
  (premise `has_type(Γ, node, S)`), then require `subtype(S, T)` (premise). This
  is the *only* place synthesis meets an expected type, and it is where annotations
  (`--: T` on a local, a param, a return) act as the **inference boundary** — they
  switch to checking mode and flow `T` inward. Premises: `has_type(Γ, node, S)` and
  `subtype(S, T)`.
- `check_cast` — a checked cast `e --[[: T]]` checks `e ⇐ T` and yields `T` as the
  node's type. The cast is a checking boundary: it requires full subtyping
  (`subtype(synth(e), T)`), exactly `check_against`, then *asserts* `T` downstream.
  It is **never an inference source** — checking flows `T` in; nothing writes back
  to a synthesis variable. This is the construction that retires `solve.lua:579`
  (kernel §3.2). A force cast `e --[[:! T]]` is `trusted_signature`, not
  `check_cast` — see §2.5.

**The subtype relation** (`subtype(A, B)`): method `subtype_witness`, specified in
full in §3. It is a pure, total, cycle-guarded function; the evidence is its
boolean verdict plus (on rejection) a counterexample witness.

**Local generic instantiation**: `instantiate_witness`, §2.4.

**Narrowing**: `narrow_guard`, §4.

**Well-formedness**: `type_shape_check` validates `well_typed_type(T)` by parsing
`T` (and checking indexer keys are admissible). Verbatim STLC pattern.

### 2.4 Local generic instantiation as witnessed evidence

The slice grammar has no `forall` constructor (parametric polymorphism is
deferred, §1.4). But the corpus has *generic stdlib calls* (`pairs`, `tonumber`
return `number | nil`) and higher-order calls. The kernel's one real inference
(§3.4) is **local generic instantiation at call sites as witnessed evidence**: an
*untrusted producer* proposes a finite substitution `σ` (a map from the callee's
type parameters to slice types), and the checker validates the application rule
under `σ` *post-hoc* — the fixpoint-rung witness pattern.

```text
instantiate_witness for has_type(Γ, call_node, T):
  inputs:
    - has_type(Γ, f_node, G)            where G is the callee's generic type
    - one checks_against premise per argument, under the SUBSTITUTED params
  result payload (the witness, untrusted):
    - σ : { [tyvar_name]: Ty }          the proposed substitution
  the checker:
    - applies σ to G, obtaining a monomorphic fn(P, R);
    - checks each argument premise was checked against σ-applied P (structurally);
    - checks the asserted call type T equals σ-applied R;
    - NEVER infers σ itself — it only validates the proposed σ.
```

This keeps the checker a *checker* (evidence before inference): inference is the
producer's job; the checker validates a proposed witness, exactly as
`fixpoint_witness` validates a proposed assignment without computing it. In v1 the
generic callees are the handful of stdlib aliases (`pairs<T>`, `ipairs<T>`,
`tonumber`), declared as trusted signatures (§2.5) carrying their type
parameters; the producer's σ is checked against the actual argument types.

### 2.5 Trusted boundaries

`trusted_signature` admits a `has_type` / `checks_against` claim through a visible
trust boundary, recorded as a `trusted_boundary` dependency and surfaced in the
trust summary (verbatim `trusted_type_axiom` shape). Three v1 uses:

- **stdlib signatures** — `tonumber : (string) -> (number | nil)`,
  `string.sub : (string, integer, integer) -> string`, `pairs<T> : ...`,
  `math.floor : (number) -> integer`, etc. These are external declarations; the
  slice does not check the stdlib, it trusts its signatures (the explicit-stdlib-
  declaration model, CLAUDE.md "No ambient globals by default").
- **FFI / cross-module signatures** — a `require`d module's exported type, or an
  FFI cdef. (The cross-module-alias fixture's *cross-module form* is a trusted
  boundary in v1; the in-file form is checked. See §7.)
- **Force casts `--[[:! T]]`** — the escape hatch. A force cast admits the node's
  type as `T` through a *named, visible* trust boundary. It is **never** an
  inference source and **never** `check_cast` (which requires full subtyping). Per
  CLAUDE.md, force casts are "almost never correct"; the slice records every one as
  a trust boundary so the trust summary surfaces them — matching the corpus's
  hamt/table fixtures, whose force casts a *correct* checker would replace with
  narrowing or widening (those fixtures expect 0 errors *and* expect the narrowing/
  widening to make the force cast unnecessary — see §7).

Every accepted claim also carries `unverified_checker_trust(M.ID, M.VERSION)`
while the checker is hand-written Lua — the object-model hosted-checker-trust
obligation, inherited unchanged.

### 2.6 The substrate learns nothing — adversarial checks

Mechanization must include these (the STLC pattern, extended):

- **No type/context/judgment/subtype/narrowing object kind.** Walk every Id stored
  in the analysis state after a full slice derivation; assert each lives in a
  substrate space (`artifact`/`claim`/`ev`/`trust`/`observation`), never `type`,
  `context`, `subtype`, `narrowing`, `flow`, or `judgment`. Assert every artifact
  `kind` is the descriptive `syntax_tree`, never a `Type`/`Subtype`/`Flow` kind.
- **Registry is a contract.** A `CheckRequest` with a predicate not listed
  (`type_of`, `assignable`, `flow_fact`) is rejected by `validate_request` naming
  the predicate. An evidence method not listed (`unify`, `solve`, `coalesce`,
  `rdnf`, `widen`) is rejected naming the method. Inference/solver methods do not
  enter by the back door — the solver is the *untrusted producer* outside the
  registry, feeding witnesses to `subtype_witness` / `instantiate_witness`.
- **The subtype relation is not a substrate primitive.** Assert the substrate
  stores `subtype(A,B)` as an ordinary opaque claim; `A` and `B` are `ArgValue`
  data the substrate compares structurally and never interprets as types.
- **Narrowing is not checker-internal state.** Assert refinements are `narrows`
  *claims* with `narrow_guard` evidence and dependency edges, not hidden mutable
  bindings inside the checker.

---

## 3. The Subtype Relation

The kernel ratifies **ONE** subtype relation: a single pure, total, cycle-guarded
function. This section specifies it precisely. It is the substrate-before-
consumers piece (§8 schedules it and its fuzz first).

### 3.1 Shape and guarantees

```text
subtype(A: Ty, B: Ty) -> (bool, Counterexample | nil)
```

- **Pure** — no mutation of `A`, `B`, or any shared state; depends only on its
  arguments.
- **Total** — terminates on every well-formed `(A, B)`, including mutually
  recursive μ types. Termination is by the cycle guard (§3.3); a non-terminating
  query is a soundness bug (CLAUDE.md timeout-30 rule), not a slow case.
- **Cycle-guarded coinductive** — `A <: B` is the *greatest* fixed point: when the
  relation revisits a pair `(A, B)` already on the assumption stack, it returns
  `true` (the coinductive hypothesis), exactly as the fixpoint rung's witness
  reads asserted values from its own payload rather than re-deriving them. This is
  what makes `μX. (Leaf | {children: X}) <: μY. (Leaf | {children: Y})` decide
  without divergence.
- **Hash-consed identity** — every `Ty` is interned to a structural tid on
  construction; `mu` and `tyvar` participate. Two structurally-equal types share a
  tid, so the cycle guard's "already seen `(A, B)`" test is a tid-pair lookup, O(1),
  and sound (kernel §3.3, TODO:826).

### 3.2 Rules per constructor pair

The relation is decided by the structure of `B` first (the rewrite-design's "every
notion reduces to subtyping" lattice, restricted to the v1 fragment). Reflexivity
(`A <: A` by tid identity) and the coinductive hypothesis short-circuit before
these.

- **`B = unknown`** → `true` (top). **`A = never`** → `true` (bottom).
  **`A = unknown`, `B ≠ unknown`** → `false`. **`B = never`, `A ≠ never`** → `false`.
- **Primitives**: `integer <: number` (the one hard-wired edge); otherwise primitive
  `<:` holds iff equal. `lit_int(n) <: integer <: number`; `lit_int(n) <: lit_int(n)`;
  `lit_str(s) <: string`; `lit_bool(b) <: boolean`. A literal `<:` its base and
  itself; bases are not `<:` their literals.
- **`B = union([b1..bn])`** → `A <: B` iff `A <: bi` for **some** `i`
  (check-against-each on the right). **`A = union([a1..am])`** → `A <: B` iff `ai <: B`
  for **every** `i` (every member must be below). (Both together handle
  `union <: union`.)
- **`B = inter([b1..bn])`** → `A <: B` iff `A <: bi` for **every** `i`.
  **`A = inter([a1..am])`** → `A <: B` iff `ai <: B` for **some** `i`.
- **Functions** `fn(P, R) <: fn(P', R')` → params **contravariant**
  (`P'.fixed[i] <: P.fixed[i]` pointwise, vararg handled as a tail spread) and
  return **covariant** (`R.fixed[i] <: R'.fixed[i]` pointwise; a longer return
  tuple is `<:` a shorter prefix since extra returns are droppable). Arity: `A` may
  accept *fewer* fixed params than `B` only if `A` has a vararg covering the rest;
  `A` may return *more* than `B` needs.
- **Records** `rec(F, rows) <: rec(F', rows')`:
  - **width**: every field in `F'` must be present in `F` with a `<:` field type;
  - **depth**: `field_A.ty <: field_B.ty` (covariant for readonly/by-value;
    invariant for mutable fields is deferred — v1 treats fields covariantly and
    records the mutable-field-invariance gap in §10);
  - **optional**: a `B'` optional field may be absent in `A`, or present with type
    `<: (B'.ty | nil)`; a required `B'` field must be present and non-optional in `A`;
  - **open row**: `rows' = "open"` (B is open) accepts any `A` satisfying the named
    fields (A may have more, listed or not). `rows = "open"` (A is open) is `<:` a
    *closed* `B` only if A's listed fields exactly cover B and A's unlisted tail is
    irrelevant to B — conservatively, an open A is NOT `<:` a closed B (the open
    tail could carry a field that violates closedness), so this returns `false`.
    This is the `...`-is-a-structural-marker rule.
- **Indexers** `indexer(K, V) <: indexer(K', V')` → `K' <: K` (contravariant key)
  and `V <: V'` (covariant value). `rec_with_indexer` decomposes to the conjunction
  of its `rec` part and its `indexer` part. A `rec` with integer-literal fields
  (a tuple) is `<:` an `indexer(integer, V)` iff every field type `<: V`.
  **Crucially, an open-row `rec` is NOT automatically an `indexer`** — the
  `...`-vs-indexer distinction is enforced here: `{ name: string, ... } <: { [string]: unknown }`
  is **false** (the open tail is "unknown other fields," not "every string key maps
  to unknown").
- **μ / tyvar**: `mu(X, T) <: B` unfolds `A` to `T[mu(X,T)/X]` (equirecursive: the
  μ and its unfolding are the same type) and recurses, *after pushing `(A, B)` onto
  the cycle-guard stack*; symmetrically for `B = mu(...)`. A `tyvar` only appears
  bound under its `mu`, so it is resolved by the unfold. Hash-consing makes the
  unfold's tid stable, so the guard fires on the second visit.

### 3.3 The cycle guard (termination + soundness)

A single assumption stack of tid-pairs. On entry to `subtype(A, B)`:

1. if `tid(A) == tid(B)` → return `true` (reflexivity by interning);
2. if `(tid(A), tid(B))` is on the stack → return `true` (coinductive hypothesis);
3. otherwise push `(tid(A), tid(B))`, decide by §3.2 (unfolding μ as needed), pop,
   return.

Because tids are finite (the input types are finite even though their unfoldings
are infinite) and each pair is pushed at most once per path, the stack is bounded
and the function is total. This is the TODO:826 fix realized: structural identity
→ tid identity makes the "already seen" test sound. An *unwitnessed* recursion
(one with no base case) cannot occur, because every μ has a non-recursive arm
(`Leaf`, `nil`) that the union decomposition reaches — the same "missing base case
is the real error" lesson the fixpoint rung recorded.

### 3.4 Fragment-of-the-target-lattice coherence

This relation is a **coherent fragment** of the rewrite-design lattice
(`docs/typechecker-rewrite-design.md` §1–§2), so growth toward it is monotone, not
a rewrite:

- §1.1 constructors: v1 has primitives + `integer<:number`, literals, records/
  indexers/tuples, functions (contra/co, multi-return tuple, vararg spread),
  equirecursive μ. v1 omits top/bottom-as-`any` (keeps `unknown`/`never`),
  universal quantification, type-level functions, nominal opaqueness, indexed
  access — all deferred (§1.4).
- §1.2 boolean operations: v1 has **union and intersection** under the same
  set-theoretic reading (`A | B` = set union, `A & B` = set intersection). v1
  omits **complement** — the one operator the rewrite-design's RDNF/emptiness
  machinery exists to support. Every v1 rule above is exactly the rewrite-design
  rule with the `~T` cases elided.
- §1.3 subtyping-as-the-primary-relation: v1 takes this verbatim — assignability,
  conformance, field-access legality, and narrowing all reduce to `subtype`
  queries. There is no separate assignability relation.
- §2 algorithm: v1 decides subtyping **syntactically by constructor decomposition
  with a cycle guard** (the rewrite-design §2.3 "why not decide syntactically"
  notes this is incomplete *with complement*; without complement the syntactic
  decision is complete for the v1 fragment). When complement un-defers, the
  syntactic decision is replaced by RDNF emptiness *behind this same function
  boundary* — the consumer (`subtype_witness`) does not change.

The monotonicity claim: a type checkable as `A <: B` in v1 is checkable as `A <: B`
in the full lattice (no v1 acceptance becomes a full-lattice rejection), because v1
is the full rules minus the complement cases, and adding complement only adds
*decidable* cases (and may *accept more*, e.g. exhaustiveness). v1 never accepts
something the full lattice rejects, because v1's rules are a subset of the full
rules with no extra permissiveness. The one watch-item is the *conservative*
open-row-vs-closed and open-row-vs-indexer `false` results (§3.2): the full
lattice with row variables may *accept* some of these; v1 rejecting them is sound
(wider rejection), and un-deferring row polymorphism only *adds* acceptances. This
is recorded as the monotonicity boundary in §10.

### 3.5 Fuzz invariants (mandated; the relation will get a fast tier)

CLAUDE.md mandates parity tests, parity fuzzing, and benchmarks for any
multi-implementation spec. This relation will eventually have a fast tier (the
RDNF/emptiness producer behind the boundary, or an FFI-accelerated structural
decision), so its invariants are defined now and fuzzed against the v1 reference:

- **Reflexivity** — for every generated `T`, `subtype(T, T) = true`. (Trivially by
  tid interning, but fuzzed to catch interning bugs.)
- **`unknown`/`never` laws** — `subtype(T, unknown) = true`, `subtype(never, T) = true`,
  and (for `T ∉ {unknown}`) `subtype(unknown, T) = false`, (for `T ∉ {never}`)
  `subtype(T, never) = false`.
- **Transitivity sampling** — for sampled triples `(A, B, C)`: if `subtype(A,B)` and
  `subtype(B,C)` then `subtype(A,C)`. (Sampled, not exhaustive — transitivity over
  the full lattice is expensive; sampling catches decomposition bugs.)
- **μ-unfolding equivalence** — for every generated `mu(X, T)`,
  `subtype(mu(X,T), unfold(mu(X,T))) = true` AND
  `subtype(unfold(mu(X,T)), mu(X,T)) = true` (equirecursive: a μ and its one-step
  unfolding are mutually subtypes, hence equal).
- **Union/intersection lattice laws** — `subtype(A, union([A,B])) = true`,
  `subtype(inter([A,B]), A) = true`, `subtype(union([A,B]), C) = subtype(A,C) and subtype(B,C)`,
  `subtype(A, inter([B,C])) = subtype(A,B) and subtype(A,C)`.
- **Termination under fuzz** — every generated query returns within timeout-30; a
  hang is a fuzz failure (replayable via `FUZZ_SEED`, per `lib/test/`).

The fuzz generator (`lib/test/arb`) produces well-formed `Ty` including bounded-
depth μ and wide unions/intersections — the §5.1 corpus-performance benchmark
draws its adversarial types (hamt/proto/prolog/protocol_buffer shapes) from this
same generator plus the widest `lib/` unions a `grep` finds.

---

## 4. The Flow-Narrowing Layer

A **separate pass** (kernel §3.5; TypeScript's architecture), layered orthogonally
over synthesis. It consumes synthesized types (`has_type` claims) and produces
refinement facts (`narrows` claims). It is **not** checker-internal mutable state:
each refinement is a derived claim with `narrow_guard` evidence and visible
dependency edges, exactly as the fixpoint rung made dataflow facts into claims.

### 4.1 v1 narrowing forms (derived from the universe's discriminators)

The universe lets a program *discriminate* a value's kind/shape. v1 recognizes the
discriminators the corpus produces, each expressed as **intersection-with-a-
positive-atom** on the truthy branch and a **sound wider approximation** on the
falsy branch (no complement, kernel §3.5):

| Guard form | Truthy refinement | Falsy refinement (v1, no `~T`) |
|---|---|---|
| `if x then` | `x : T & ~(nil\|false)` → v1: `T` with `nil` and `false` union-members *dropped* | `T` (unrefined; sound wider) |
| `if x ~= nil` / `if x == nil` | drop `nil` member (truthy) | the `nil` member alone (falsy: positive, sound) |
| `type(x) == "string"` etc. | `x : T & string` → v1: the `string` member of the union `T` | `T` (unrefined; sound wider) |
| `x == "GET"` (literal eq) | `x : lit_str("GET")` (the singleton) | `T` (unrefined; sound wider) |
| `x.tag == "leaf"` (tag discriminant, **literal tag only**) | the union members of `x` whose `tag` field admits `lit_str("leaf")` | `T` (unrefined; sound wider) |
| `not g` | swap the truthy/falsy refinements of `g` | swap |
| `g1 and g2` | apply both truthy refinements (intersection) | `T` (sound wider) |
| `g1 or g2` | union of truthy refinements | `T` (sound wider) |

The **positive decomposition** is the key v1 move: instead of `T & ~string` on the
falsy branch (which needs complement), v1 keeps `T` unrefined there. This is
**sound but less precise** — it never narrows the falsy branch to something it is
not. The §5.4 soundness check (from the kernel decision) enumerates `lib/` falsy
branches and confirms the v1 approximation is *wider, never unsound*; if any site
is made unsound, complement un-defers immediately. For union *truthy* narrowing
(the dominant corpus case — `T | nil` guarded to `T`, tag-discriminated unions),
v1's positive decomposition (keep the matching members, drop the rest) is exact,
because dropping a union member is a positive operation that needs no complement.

### 4.2 `narrow_guard` evidence

```text
narrow_guard for narrows(Γ, guard_ref, x, T_true, T_false):
  inputs:
    - has_type(Γ, x_node, T)            the synthesized pre-guard type of x
  the checker:
    - parses the guard syntax in guard_ref;
    - identifies the refining atom (primitive / literal / tag-shape / truthy);
    - computes T_true by the positive decomposition over T (drop non-matching
      union members / intersect with the positive atom);
    - computes T_false = T (the sound wider approximation), EXCEPT for the
      nil-guard, where the falsy branch is the positive `nil` member;
    - checks the asserted (T_true, T_false) structurally equal what it computed.
  dependencies: has_type(Γ, x_node, T) [accepted_claim], guard_ref [artifact].
```

A downstream `has_type` for an occurrence of `x` *inside* the truthy branch is
synthesized under a Γ where `x`'s binding is `T_true` — context extension /
shadowing, the STLC `extend` operation. The flow layer thus feeds the synthesis
layer through Γ, never by mutation. This is how `task.done` typechecks after
`if not task then return end` (the local-return-narrowing fixture): the guard
produces `narrows(Γ, _, task, TaskNode, nil)`, and the post-guard `task.done`
access synthesizes under `task : TaskNode`.

---

## 5. The Lua Syntax Subset

v1 checks the syntax forms below; everything else is a **named exclusion** (the
node parses but the slice produces no claim, or rejects with "syntax form outside
v1"). The subset is derived from what the corpus's checked syntax actually uses,
intersected with what the value universe + bidirectional spine can check soundly.

### 5.1 Included

- **`local` declarations** with optional `--: T` annotations.
  `local x = e` synthesizes `x`'s type from `e`; `local x = e --: T` **checks**
  `e ⇐ T` (annotation = inference boundary) and binds `x : T`. Multi-assignment
  `local a, b = f()` draws slots from a multi-return `R` positionally.
- **Function definitions** — module-boundary (`function M.foo(...)`,
  `M.foo = function(...)`) and local (`local function f(...)`). Params carry `--:`
  annotations; the body is checked under Γ extended with the params; `return`
  statements are checked against the declared return (or synthesized and joined if
  unannotated). The annotation-density measurement (kernel §5.2: 90% of files
  carry `--:`) makes this the common, well-annotated case.
- **Calls** `f(a1..an)` — `synth_call`, with argument checking and (for generic
  stdlib callees) `instantiate_witness`.
- **Returns** `return e1..en` — including multi-return; checked against the
  function's declared `Ret` tuple, or synthesized and joined across return paths.
- **Table constructors** `{ k = v, [i] = v, v, ... }` — `synth_table`; widening to
  a declared element type happens at the checking boundary.
- **Field / index access and assignment** — `t.k`, `t[e]` (read: `synth_index`);
  `t.k = v`, `t[e] = v` (write: check `v ⇐` the field/element type; for a table
  built by sequential assignment, each write is checked against the *declared*
  element type when the table has a declared type, resolving the table-construction-
  widening fixture).
- **`if` / `elseif` / `else` chains** — each branch test is a guard consumed by the
  flow layer (§4); the branch body is checked under the refined Γ. `elseif` chains
  thread the accumulated falsy refinements (sound wider) into subsequent tests.
- **`--::` alias forms** the corpus uses — type-alias declarations
  (`--:: Foo = { ... }`, `--:: AnyCmd = LoginCmd | LogoutCmd`,
  `--:: HamtNode = Leaf | Interior` including recursive aliases). An alias declares
  a named `Ty`; recursive aliases parse to `mu`. Aliases are resolved at parse time
  into the `Ty` grammar (a name-to-`Ty` environment in the producer, not a
  substrate concept).
- **Checked casts `e --[[: T]]`** — `check_cast`, a checking boundary requiring
  full subtyping. **Force casts `e --[[:! T]]`** — `trusted_signature`, recorded as
  a visible trust boundary, never an inference source.

### 5.2 The `for-in` decision (explicitly justified)

**Decision: `for-in` IS included in v1, restricted to `pairs`/`ipairs` over a
table, via a *trusted iterator signature*, not a general iterator-protocol
mechanism.**

Reasoning from the value universe and the corpus:

- The universe's `for k, v in pairs(t) do ... end` is the dominant table-traversal
  idiom, and **two corpus fixtures require it**: `fixture_pairs_return_leak.lua`
  (a table built by `pairs()` loops must have a clean element type) and the
  `tree_sum`/`lookup` recursion fixtures use `pairs` over `Interior.children`.
  Excluding `for-in` would put these fixtures out of the syntax subset, defeating
  the rung's purpose (a *real* `lib/` slice).
- The *general* Lua iterator protocol (`for vars in f, s, var do`) is a
  three-value stateful-iterator contract that needs the function-type machinery to
  type an arbitrary iterator `f` and its control variable — genuine substrate-
  adjacent complexity with **no v1 corpus demand** (no fixture uses a custom
  iterator).
- The principled v1 inclusion is therefore: **`for-in` over `pairs(t)`/`ipairs(t)`
  only**, where `pairs`/`ipairs` are trusted generic stdlib signatures
  (`pairs<T> : (T) -> iterator-of (Keys<T>, Values<T>)`, modeled in v1 *without*
  the `$PairsReturn` match-type intrinsic by directly binding the loop variables
  from the table's key/value types). The loop body is checked under Γ extended with
  `k : key-type`, `v : value-type` derived from `t`'s `indexer`/`rec` type. This is
  the value-universe-natural form (it types exactly the corpus's loops) and uses
  the already-present `instantiate_witness` + `trusted_signature` machinery — no
  new substrate, no iterator-protocol primitive.
- **Deferred with a trigger**: the general iterator protocol (`for vars in expr`
  with a non-`pairs`/`ipairs` expression) is **excluded** in v1, un-deferred when a
  corpus fixture (real `lib/` file) drives a custom stateful iterator through the
  checked syntax. This is the honest "loops can be included if the universe
  derivation makes them natural" resolution: `pairs`/`ipairs` are natural and
  demanded; general iterators are neither yet.

Numeric `for i = a, b, c do` is **included** (it produces `i : integer` over the
loop body, no iterator protocol). `while` / `repeat` test positions reuse the flow
layer's guard recognition (same as `if`).

The **imperative-store / capability-reachability pressure** the design doc said
this rung absorbs (`docs/agnostic-static-analysis-design.md`, ladder §5) shows up
exactly here, in table-field *assignment* and sequential mutation
(`insns[1] = ...; insns[2] = ...`). v1 handles it by **checking each write against
the declared element type** (a flow-insensitive, sound treatment), not by a full
store abstraction. A genuinely flow-sensitive store (a field's type changing across
statements) is deferred; §10 records this as the one place imperative-store
pressure pushed on the slice.

### 5.3 Named exclusions

Outside v1's checked syntax (parse, produce no claim or reject as "outside v1"),
each with the deferral rationale: general `for-in` iterators (§5.2 trigger);
`goto`/labels (control flow with no corpus demand); coroutines (`thread` values,
deferred with `cdata`); metatable assignment / metamethod operator dispatch
(deferred with metatable types, §1.4); string-pattern operations beyond `tonumber`/
`string.sub` signatures (trusted-signature surface only); multiple-assignment
*swap* idioms and tuple-destructuring beyond multi-return call slots;
`...`-varargs *inside a function body* beyond the trailing-spread param type (the
type is carried; iterating `select('#', ...)` is deferred).

---

## 6. Worked Examples

### 6.1 Full synth/check derivation (multi-level, context-in-args)

Source: a reduced `fixture_local_return_narrowing.lua` shape.

```lua
--:: TaskNode = { id: string, done: boolean }
--: (string) -> boolean
local function task_done(id)
  local task = get_task(id)          -- get_task : (string) -> (TaskNode | nil)
  if not task then return false end
  return task.done
end
```

Artifacts (syntax nodes), each an `artifact` of kind `syntax_tree`:
`n_call = call(get_task, [var id])`, `n_local = local(task, n_call)`,
`n_guard = not(var task)`, `n_ret1 = return(lit false)`,
`n_field = index(var task, "done")`, `n_ret2 = return(n_field)`.

Let `Γ0 = [id : string]`, `TN = rec({id:string, done:boolean}, closed)`,
`MaybeTN = union([TN, nil])`.

```text
1.  has_type(Γ0, n_call, MaybeTN)                 via synth_call
       premises: has_type(Γ0, get_task, fn((string),(MaybeTN)))   [trusted_signature]
                 checks_against(Γ0, var id, string)                [check_against]
         check_against premise: has_type(Γ0, var id, string) [synth_var]
                                 subtype(string, string)     [subtype_witness → true]
2.  has_type(Γ0, n_local, MaybeTN)                bind task : MaybeTN
       (a local without --: annotation binds the synthesized type)
       Let Γ1 = Γ0, task : MaybeTN.
3.  narrows(Γ1, n_guard, task, never, TN)         via narrow_guard
       inputs: has_type(Γ1, var task, MaybeTN)
       `not task` truthy = task is falsy = drop TN, keep nil → but the guard
       BODY returns, so the post-guard Γ uses the FALSY refinement: task : TN.
       (truthy here narrows to nil-only and exits; the fall-through path is falsy.)
       Let Γ2 = Γ0, task : TN.    -- shadowing, via extend
4.  has_type(Γ2, n_field, boolean)                via synth_index
       premise: has_type(Γ2, var task, TN)        [synth_var: task : TN in Γ2]
       index TN.done = boolean.
5.  checks_against(Γ2, n_ret2, boolean)           via check_against
       premise: has_type(Γ2, n_field, boolean); subtype(boolean, boolean) → true
       (return checked against the declared return type boolean) ✓
```

Every premise is a separately-evidenced claim; the conclusion's
`dependency_graph` carries `accepted_claim` edges to each, and `artifact_content`
edges to the syntax nodes. `Γ` rides args throughout; the substrate stores no
context object. The narrowing at step 3 fed the synthesis at step 4 *through Γ2*,
never by mutation. **Accepted; 0 errors** — matching the fixture's expected verdict.

### 6.2 Subtype derivation involving μ

Source: `fixture_hamt_recursion.lua` shape.

```text
HamtNode = μX. union([ Leaf, Interior(X) ])
  Leaf      = rec({kind:integer, key:unknown}, closed)
  Interior(X) = rec({kind:integer, children: indexer(integer, X)}, closed)
```

Query: is the recursive value passed to `lookup(child, key)` — where `child` is
synthesized as `HamtNode` (the `indexer` value type of `Interior.children`) — a
subtype of the param type `HamtNode`?

```text
subtype(HamtNode, HamtNode)
  tid(A) == tid(B)  → true   (reflexivity by interning; the μ is hash-consed,
                              so child's HamtNode and the param's HamtNode share a tid)
```

A non-trivial μ query — `subtype(Interior(HamtNode), HamtNode)`:

```text
subtype(Interior(HamtNode), μX.union([Leaf, Interior(X)]))
  B is μ → unfold B to union([Leaf, Interior(HamtNode)]); push (A,B)
  B is union → A <: some member:
     subtype(Interior(HamtNode), Interior(HamtNode))  → tid-equal → true
  → true
```

The cycle guard's push of `(A, B)` means a recursive descent into
`Interior.children`'s element type (`HamtNode <: HamtNode`) that re-reaches the
pushed pair returns `true` by the coinductive hypothesis — **no stack overflow**,
the TODO:826 / commit-56810b60 class retired by construction. The narrowing
`if node.kind == NODE_LEAF` (integer-tag discriminant, §4.1) refines `node` to
`Leaf` *without a force cast*, so `node.key` accesses cleanly — matching the
fixture's "narrows without a force cast" expected verdict.

### 6.3 Narrowing derivation

Source: `fixture_boolean_narrowing.lua`.

```lua
--: (number) -> boolean
local function is_negative_zero(n)
  return n == 0 and 1 / n < 0
end
```

```text
Γ0 = [n : number]
synth `n == 0`        : boolean      (comparison → boolean)   [synth_call on ==]
synth `1 / n < 0`     : boolean      (comparison → boolean)
synth `(n==0) and (1/n<0)` via synth_and_or_not:
    A = boolean (left operand type).  A <: boolean → the positive `and`-of-booleans
    rule fires: result is boolean (NOT nil | boolean — the legacy bug was modeling
    `and` as "left-if-falsy | right" without using that both sides are boolean).
checks_against(Γ0, return-expr, boolean): subtype(boolean, boolean) → true ✓
```

**Accepted; return type `boolean`** — matching the fixture. The narrowing layer's
`and` rule (§4.1) is what supplies the precise `boolean` instead of the legacy
`nil | boolean`.

### 6.4 Rejection with counterevidence

```lua
--:: Leaf = { kind: integer, key: unknown }
--: (Leaf) -> integer
local function bad(leaf)
  return leaf.kind + leaf.missing   -- `missing` is not a field of Leaf
end
```

```text
synth_index(Γ, index(var leaf, "missing"), ?)
  leaf : Leaf = rec({kind:integer, key:unknown}, CLOSED)
  field "missing" absent, row is closed → REJECTED
  counterevidence: { kind: "no_such_field", record: Leaf, field: "missing" }
```

The `subtype` counterexample shape (`subtype_witness` returning
`(false, Counterexample)`) and the `synth_index` no-such-field rejection both
populate `RejectedClaim.counterevidence` — the substrate's rejection-with-
counterexample slot. **Rejected**, as a correct checker must (this is a *new*
rejection the slice produces correctly, not a corpus fixture, illustrating the
counterevidence path).

---

## 7. Acceptance Criteria

### 7.1 Per-fixture acceptance mapping

The corpus (`lib/type/analysis/corpus/corpus.md`) is the acceptance bar.
`crescent.slice.v1` must produce the **Expected Verdict (correct checker)** column
— *all eleven expect "Accepts" / 0 errors* — for every fixture **within v1's
syntax subset**. The mapping, fixture by fixture:

| Fixture | v1 verdict required | In v1 syntax subset? | Mechanism |
|---|---|---|---|
| `fixture_boolean_narrowing.lua` | **Accepts**, return type `boolean` | Yes | `synth_and_or_not` positive `and`-of-booleans (§4.1, §6.3) |
| `fixture_local_return_narrowing.lua` | **Accepts**, 0 errors | Yes | unannotated-local synth + `narrow_guard` nil-guard (§6.1) |
| `fixture_union_alias_over_named_types.lua` | **Accepts**, 0 errors | Yes | union `Ty`, `synth_index` distribution (field in ALL members) |
| `fixture_tonumber_return_type.lua` | **Accepts**, 0 errors | Yes | trusted `tonumber`/`string.sub`/`math.floor` signatures + nil-guard narrowing |
| `fixture_pairs_return_leak.lua` | **Accepts**, 0 errors | Yes | `for-in pairs` (§5.2), loop-var binding from indexer type; no `$PairsReturn` (slice has no match-type intrinsic to leak) |
| `fixture_coinductive_recursive_types.lua` | **Accepts**, 0 errors | Yes | `mu` + cycle-guarded `subtype`; `is_just`/nil discriminated narrowing |
| `fixture_table_construction_widening.lua` | **Accepts**, 0 errors | Yes | write-checks-against-declared-element-type (§5.1); checked-cast `--[[: ...]]` boundary |
| `fixture_hamt_recursion.lua` | **Accepts**, 0 errors, **narrows without force cast** | Yes | `mu` + integer-tag `narrow_guard` (§6.2); the fixture's `--[[:! Leaf]]` force casts become unnecessary |
| `fixture_cast_not_inference_source.lua` | **Accepts** the redundant cast (no hard error) | Yes (in-function form) | force cast = `trusted_signature` (visible boundary, never an inference source, never `check_cast`); no REDUNDANT_CAST hard error |
| `fixture_cross_module_type_alias.lua` | **Accepts** the **in-file** form, 0 errors | In-file: Yes. Cross-module: **trusted boundary** | in-file alias resolves to `Ty`; nil-guard narrowing. Cross-module alias propagation across `require` is a trusted signature in v1 (the `require` return type is a trusted boundary) — the fixture's in-file form is the checked case |
| `fixture_closure_param_typing.lua` | **Accepts**, 0 errors, second multi-return slot `() -> ()` | **Partially**: see note | `synth_call` multi-return slot inference must keep slot 2 = `fn((),())` independent of the typed inner closure |

**The closure-param fixture note (be explicit, per the prompt):**
`fixture_closure_param_typing.lua` exercises higher-order functions, closure type
inference, and **call-site return-slot inference under a typed closure argument**.
Its *syntax* is in the v1 subset (function definitions, calls, multi-return
destructuring `local n1, c1 = with_scope(...)`). The substantive question is
whether v1's `synth_call` keeps the second multi-return slot (`c1 : () -> ()`)
independent of the typed inner closure `w`. Under the bidirectional spine this is
**structurally correct by construction**: `with_scope`'s declared return is
`(Node, () -> ())`, and `synth_call` draws slot 2 directly from the *declared*
`Ret.fixed[2] = fn((),())` — it does not re-infer the return from the argument, so
the typed closure cannot corrupt it (the legacy bug was exactly this corruption via
bidirectional unify writing back). **v1 must accept it, 0 errors, `c1 : () -> ()`.**
The one v1 limitation to record: v1 requires `with_scope` to be **annotated**
(`--: ((Signal) -> Node) -> (Node, () -> ())`, which the fixture provides);
fully-unannotated higher-order return-slot *inference* (synthesizing the closure's
return without an annotation) leans on richer local inference and is the boundary
case — annotated, it is in scope and must pass; unannotated, it is the
local-inference edge flagged in §10. Since the fixture is annotated, **it is in v1
and must pass.**

**Summary:** all 11 fixtures are in v1's syntax subset and must produce 0 errors
(the cross-module fixture's checked form is the in-file alias; its cross-module
form is a trusted boundary, which is an *accept*, not an error). No fixture is
out-of-subset. The closure fixture passes via declared-return-slot inference.

### 7.2 Non-regression and typecheck criteria

- **No regression of the 153 existing analysis assertions.** `bin/cr test
  lib/type/analysis/` must still report 153 passing (5 files) before the slice's
  own tests are added; after, the count rises by the slice's assertions with all
  prior 153 intact. The slice is a pure consumer of the unchanged substrate
  (`init.lua` is not modified — §2.6 / §10 confirm).
- **Every new file typechecks under timeout-30.** `timeout 30 bin/cr check
  lib/type/analysis/crescent_slice.lua` (and any helper files) must pass with no
  new errors, per the pre-commit hook.
- **The subtype relation clears the §5.1 performance benchmark** (kernel §5.1,
  highest priority): every adversarial corpus type and the widest `lib/` unions
  decide within timeout-30. A single query exceeding it is a soundness/termination
  signal, not a slow case — it blocks the slice.

---

## 8. Implementation Plan (mechanization passes)

Ordered substrate-before-consumers. Each pass is sized for one agent and ends with
a commit; the slice's hosted checker lives in `lib/type/analysis/crescent_slice.lua`
(+ `crescent_slice_test.lua`), importing the unchanged substrate.

**Pass 1 — The `Ty` grammar + hash-consing + the subtype relation + its fuzz. ✅ DONE (2026-06-12).**
*Substrate-before-consumers: this is the foundation every later pass calls.*
Build the `Ty` constructors, the hash-cons interner (structural tid identity,
including `mu`/`tyvar`), and `subtype(A, B) -> (bool, Counterexample?)` per §3 with
the cycle guard. Build the §3.5 fuzz suite (reflexivity, `unknown`/`never` laws,
transitivity sampling, μ-unfolding equivalence, union/intersection laws,
termination-under-fuzz with `FUZZ_SEED` replay) and the §5.1 performance benchmark
(adversarial corpus types + widest `lib/` unions, timeout-30). No claims/evidence
yet — this is a pure, independently-tested function. Gate: all fuzz invariants
hold; benchmark clears timeout-30; results to `docs/perf/log.md`.

*Mechanized:* `lib/type/analysis/slice_ty.lua` (grammar + hash-cons interner,
de-Bruijn-indexed equirecursive μ so alpha-equivalent μ types share a tid),
`lib/type/analysis/slice_subtype.lua` (`is_subtype` / witnessed `subtype`),
`lib/type/analysis/slice_subtype_test.lua` (interner identity + every subtype rule
family + the §6.2 worked μ example + the §3.5 fuzz invariants; seeded `FUZZ_SEED`
default `0xC0FFEE`, 4454 assertions), `lib/type/analysis/slice_subtype_bench.lua`
(§5.1 benchmark). Gates met: all fuzz invariants hold; benchmark clears timeout-30
with ~20000× headroom on the worst query (`docs/perf/log.md`, 2026-06-12 entry); the
153 prior analysis assertions are intact (full suite 4607). `bin/cr check` is clean
on every new file. Findings recorded in §9.3.

**Pass 2 — Synthesis evidence methods + the `crescent.slice.v1` registry entry. ✅ DONE (2026-06-12).**
Register the semantics (§2.1). Build the parser-frontend adapter (Lua syntax →
`syntax_tree` artifacts + `--:`/`--::` annotation observations; aliases resolved to
`Ty`). Build the synthesis rules (`synth_lit`, `synth_var`, `synth_call`,
`synth_table`, `synth_index`, `synth_function`, `synth_and_or_not`) and the checking
rules (`check_against`, `check_cast`) as evidence methods, each parse-not-cast,
each consuming `has_type`/`checks_against`/`subtype` premises. Build
`trusted_signature` (stdlib + FFI + force-cast boundaries) and `instantiate_witness`
(local generic instantiation, §2.4). Mechanize §6.1 and §6.3–§6.4 derivations.
Gate: the synth/check worked examples accept; rejection produces counterevidence;
order-independence (shuffled submission) holds across the deep trees (the STLC
discipline); §2.6 adversarial checks (no substrate object kinds; registry rejects
solver methods) pass.

*Mechanized:* `lib/type/analysis/slice_ty_arg.lua` (the `Ty` ⇄ `ArgValue`
portable codec — types ride claim args as plain data, parse-not-cast back to
interned `Ty` — plus `type_shape_check` well-formedness **enforcing μ
contractiveness**, §9.3 finding 1: a non-contractive μ is a well-formedness
rejection, never silently top), `lib/type/analysis/crescent_slice.lua` (the
hosted checker: the registry entry with pinned evidence-method inputs per
version, all seven synth rules + the two check rules, `subtype_witness`
discharging the Pass 1 relation with counterexample-on-rejection,
`instantiate_witness` validating a proposed σ post-hoc, `trusted_signature` for
stdlib/FFI/force-cast boundaries; context-in-args throughout, the STLC
discipline), `lib/type/analysis/crescent_slice_parse.lua` (the parser-frontend
adapter: the v1 annotation type-grammar parser — primitives, literals, functions
incl. multi-return/vararg, records, index signatures with the `...`-vs-indexer
distinction preserved structurally, unions/intersections, named aliases,
recursive aliases → μ — plus `--:`/`--::` directive scanning; reuses no legacy
checker machinery, low coupling), and `lib/type/analysis/crescent_slice_test.lua`
(70 assertions: §6.1's synth/check derivation, per-rule unit tests, rejection-
with-counterevidence (§6.4 + subtype counterexample), `instantiate_witness`
accept/reject, `trusted_signature`/`check_cast`, μ-contractiveness accept/reject,
shuffled-order convergence, the §2.6 adversarial checks, and the adapter). Gates
met: worked examples accept; rejections carry counterevidence; order-independence
holds; the substrate stores no Type/Context/Subtype/Narrowing object kind and the
registry rejects unlisted predicates/solver methods; the substrate (`init.lua`)
was **not touched**, as §9 predicted. `bin/cr check` clean on every new file;
full `bin/cr test lib/type/analysis/` green at 4677 (4607 prior intact + 70).
Findings recorded in §9.4. **Pass 3** (narrowing) and **Pass 4** (corpus +
for-in/numeric-for) remain.

**Pass 3 — The flow-narrowing layer. ✅ DONE (2026-06-12).** Build `narrow_guard` (§4) as a separate pass:
the `narrows` claim form, the v1 guard recognizers (truthy, `type(x)==`, literal-eq,
tag-discriminant, `and`/`or`/`not` composition), the positive-decomposition truthy
refinement and sound-wider falsy approximation. Wire refinements into synthesis via
Γ-extension (refined occurrences synthesize under the refined binding). Mechanize
§6.1's narrowing step and §6.2's integer-tag narrowing. Gate: narrowing is derived
*claims* with visible dependency edges (not checker state — adversarial check);
falsy-branch soundness probe (kernel §5.4: enumerate `lib/` falsy sites, confirm v1
approximation is wider-never-unsound).

*Mechanized:* `lib/type/analysis/slice_narrow.lua` (the pure refinement core: the
`Guard` grammar for the five v1 forms + and/or/not, `refine(guard, x, T)`
computing the positive-decomposition truthy refinement — drop non-matching union
members / pick the positive atom / select tag-admitting members — and the
sound-wider falsy approximation, with the nil-guard's exact two-sided positivity;
imports slice_ty + slice_subtype only, NOT the substrate), the `narrows` claim
builder + `narrow_guard` evidence method + guard decoder in
`lib/type/analysis/crescent_slice.lua` (the evidence re-derives both branch
refinements from the one accepted `has_type` pre-guard premise and the guard
artifact, checks the asserted `(T_true, T_false)` structurally, and records
`accepted_claim`/`artifact_content` deps — Γ-fed, never mutable state), guard
recognition in `lib/type/analysis/crescent_slice_parse.lua`
(`recognize_guard(expr)` mapping an if/elseif/while test expression to a portable
Guard, operand-order symmetric), and tests:
`lib/type/analysis/slice_narrow_test.lua` (32 assertions: per-form units, nil-guard
exact two-sided, tag-field μ-unfold selection, and/or/not composition, the explicit
falsy-sound-wider-NOT-exact-complement probe) + 40 new assertions in
`crescent_slice_test.lua` (the §6.1 nil-guard derivation, the tag discriminant §6.2,
`and`-composition of the boolean-narrowing shape, a worked multi-branch if/elseif
derivation, the §5.4 falsy-soundness assertion that a complement falsy is REJECTED,
and the adversarial substrate-agnosticism checks: a foreign-semantics `narrows`
claim does not route; `narrow_guard` cannot evidence a `has_type` claim; the
substrate stores no narrowing/flow object kind after a derivation; the guard rides
an ordinary `syntax_tree` artifact). Gates met: narrowing is derived CLAIMS with
visible dependency edges, not checker state (adversarial walk passes); the
falsy-branch soundness probe holds (the v1 approximation is wider, and a
complement-precise falsy is a rejection, fencing kernel §5.4). `bin/cr check` clean
on every new/modified file; full `bin/cr test lib/type/analysis/` green at 4749
(4677 prior intact + 72). Findings in §9.5. **Pass 4** (corpus + for-in/numeric-for)
remains.

**Pass 4 — Corpus validation + `for-in pairs`/numeric-`for` + non-regression. ✅ DONE (2026-06-12).**
Add the `for-in pairs`/`ipairs` and numeric-`for` syntax handling (§5.2). Run all 11
corpus fixtures through `crescent.slice.v1` and assert the §7.1 verdicts (all 0
errors / accepts). Confirm the prior analysis assertions intact and every new
file typechecks under timeout-30. Update `docs/static-analysis-map.md` rung-5 status
to "mechanized" and this doc's Next Pass. Gate: §7 acceptance criteria all met.

*Mechanized:* the `for-in pairs`/`ipairs` + numeric-`for` loop-variable typing in
`lib/type/analysis/crescent_slice.lua` — `synth_loop_var` (a loop-variable node
binds DIRECTLY from the iterated table's key/value types via the pure `pairs_kv` /
`ipairs_kv` derivation; no `$PairsReturn`-style intrinsic, §9.1) and
`synth_numeric_for_var` (the numeric-for control variable binds `integer | number`
per §5.2), both registered evidence methods on `has_type` over a `has_type(table)`
premise — reusing the existing premise/Γ-coherence discipline, no new substrate.
The corpus runner is `lib/type/analysis/corpus_test.lua` (40 assertions): each of
the 11 fixtures' checked behavior routed end-to-end through `crescent.slice.v1` with
the §7.1 verdict + the named mechanism assertions (hamt tag-narrowed branch type =
`Leaf`; boolean `and` ⇒ `boolean`; pairs loop-var = the indexer value type;
recursive-μ subtype reflexive without overflow; union-field distribution; force
cast = visible trust boundary; declared-return-slot independence). **Result: 11/11
Accept (0 errors), matching every Expected Verdict — the grading moment passed.** No
fixture-keyed carve-out; the one corpus-forced change was the *principled* μ-unfold
in `slice_narrow.lua`'s `members_of` (§9.6). Gates met: full `bin/cr test
lib/type/analysis/` green at 4789 (4749 prior intact + 40); `bin/cr check` clean
(0 errors) on every touched file; the substrate (`init.lua`) was again **not**
touched. Findings in §9.6.

Each pass: commit on completion (`feat(analysis): crescent slice v1 — <pass>`),
benchmark results (pass 1) to `docs/perf/log.md`, findings recorded in this doc's
Mechanization Findings section (added by the passes).

---

## 9. Design-Pressure Honesty

Where the value-universe derivation strained against the ratified kernel or the
substrate. This is the rung's data; recorded honestly, not smoothed.

### 9.1 Resolved without crossing the fence

- **Falsy-branch narrowing wants complement; v1 forbids it.** The universe's
  `if type(x) == "string"` falsy branch is *semantically* `T & ~string`. v1 cannot
  express it (no complement, kernel §3.5). The strain resolved by the **positive
  decomposition**: truthy branches narrow exactly (drop non-matching union members
  — a positive operation), and falsy branches stay `T` (sound wider). This is
  sound and covers every corpus fixture (all of which narrow on the *truthy* side —
  `if task`, `if node.kind == LEAF`, `if a.is_just`). The fence held: complement
  did not sneak back. The cost is falsy-branch *precision*, with the kernel's §5.4
  un-defer trigger watching for an unsound site.

- **Table-construction widening wants flow-sensitive store typing; v1 is
  flow-insensitive on stores.** The universe builds tables by sequential mutation
  (`insns[1]=..; insns[2]=..`) where the element type *widens* across statements.
  A full store abstraction (a field's type evolving per statement) is the
  imperative-store pressure the design doc routed to this rung. v1 resolves it
  *without* a store abstraction by checking each write against the **declared**
  element type (bidirectional: the declared `{ [integer]: Insn, ... }` flows the
  expected `Insn` inward at each write). This accepts the fixture without the
  legacy "unknown→any→T two-step" hack and without a store model. The strain is
  real: a table built *without* a declared type, widening purely by inference
  across writes, is the boundary case v1 does not flow-sensitively type (§9.2).

- **`$PairsReturn` leak vanishes by construction.** The legacy fire was an internal
  match-type intrinsic (`$PairsReturn`) leaking into user-visible types. v1 has
  *no match-type intrinsics* (deferred, §1.4), so there is nothing to leak — the
  `for-in pairs` loop binds `k`/`v` directly from the table's key/value types via a
  trusted signature. The deferral *removed* the fire rather than fixing it. This is
  a clean win, recorded because it shows the value-universe derivation (no intrinsic
  unless the universe forces it) pre-empting a legacy class of bug.

### 9.2 Strain recorded as future-pass / un-defer boundaries (not crossed)

- **Mutable-field invariance.** §3.2 treats record fields covariantly. Sound
  subtyping of *mutable* table fields is invariant (a writable `{x: integer}` is
  not `<: {x: number}`). v1's covariant treatment is **unsound for mutation through
  an aliased wider type** — but no v1 corpus fixture writes through a widened field
  alias, so the unsoundness is unreachable in v1's checked syntax. Recorded as a
  must-fix when the slice grows write-through-alias syntax: field variance must
  split readonly (covariant) from mutable (invariant). This is the sharpest strain;
  it is fenced (unreachable in v1) but explicitly named, not hidden.

- **Open-row-vs-closed / open-row-vs-indexer conservative `false`.** §3.2 returns
  `false` for an open `rec` against a closed `rec` or an `indexer`. The full lattice
  with row variables may *accept* some of these. v1's rejection is sound (wider
  rejection, never unsound) and monotone (§3.4: un-deferring row polymorphism only
  adds acceptances). Recorded as the monotonicity boundary: a `lib/` site needing
  open-row-`<:`-indexer un-defers row polymorphism, not a v1 rule change.

- **Fully-unannotated higher-order return-slot inference.** The closure-param
  fixture passes *annotated* (§7.1). Fully-unannotated synthesis of a closure's
  return slot leans on richer local inference than v1's check-against-annotation
  spine provides. v1 requires the annotation (the corpus carries it; kernel §5.2
  measured 90% annotation density). Recorded as the local-inference edge; its
  un-defer is a corpus site that *lacks* the annotation and cannot be checked — at
  which point the §6 annotation-density re-evaluation trigger (kernel §6) fires.

- **Cross-module alias propagation is a trusted boundary, not a checked relation.**
  The cross-module fixture's checked form is the *in-file* alias; the cross-module
  `require`-boundary alias is a trusted signature in v1. This is honest (the
  `require` return type is genuinely an external declaration to the slice) but means
  v1 does not *check* cross-module alias coherence — it trusts it. Recorded; a
  checked cross-module relation is a multi-artifact extension (the slice would need
  the required module's artifact in the same `CheckRequest`), deferred.

None of these crosses the ratified fence. Each is a sound v1 approximation with a
named un-defer trigger, exactly the kernel's §3-deferral discipline applied at the
slice's own boundaries. **What buckled in the substrate: nothing** — the slice is a
pure consumer of the unchanged claim database, dependency tracker, and worklist
checker, exactly as STLC was. The value-universe derivation produced a semantics
the substrate hosts with no new object kind; the strain was entirely against the
*kernel's deferral fence* (where it held) and the *precision* of sound
approximations (where it is recorded), never against the substrate's shape.

### 9.3 Mechanization findings — Pass 1 (the `Ty` grammar + subtype relation)

Recorded honestly per the prompt: places where the §3 spec was ambiguous or
under-determined and the mechanization had to make a conservative call. None
crosses the fence; all are spec-tightening, not spec-contradiction. Each was
resolved in the most conservative direction and is now load-bearing in the
implementation.

- **μ contractiveness is an implicit well-formedness precondition (sharpest
  finding).** §3.3 states "every μ has a non-recursive arm (`Leaf`, `nil`)" as the
  reason no unwitnessed recursion occurs. The fuzz exposed that this is not just a
  property of the *corpus* types — it is a **well-formedness requirement on the
  grammar**. A *non-contractive* μ — one whose bound variable occurs **unguarded**,
  i.e. as a bare union member (`μX.(nil | X)`) rather than under a constructor
  (`μX.(nil | {next: X})`), or whose body is `never` (`μX.never`) — is outside the
  slice grammar. For such a type the cycle-guarded coinductive relation reads the
  μ as **top** (the greatest fixed point of an unguarded recursion), which is *not*
  what the type is meant to denote (`μX.(nil|X)` is semantically `nil`; `μX.never`
  is `never`). This is sound for the *defined* (contractive) fragment but the
  relation does not detect ill-formed input. **Resolution:** contractiveness is
  recorded as a precondition of `well_typed_type` (§2.2) — a μ is well-formed iff
  every occurrence of its bound variable is guarded under a `rec`/`indexer`/`fn`
  constructor. The fuzz generator only emits contractive μ (its recursive arm is
  always under a constructor). Pass 2's `type_shape_check` must enforce
  contractiveness when it validates `well_typed_type(μ...)`. The §3.3 phrase "every
  μ has a non-recursive arm" is hereby read as "every μ is contractive," which is
  the precise statement. (This is a *new* well-formedness obligation the value-
  universe derivation did not surface, only the fuzz did — the rung's data.)

- **`inter <: union` requires trying BOTH "exists" decompositions (transitivity
  completeness).** §3.2 says the relation is "decided by the structure of `B`
  first," and lists `B = union → A <: some member` and `A = inter → some member <:
  B` as separate rules. Taken literally as an ordered cascade that commits to the
  first matching rule, this is **incomplete**: for `(a ∩ b) <: (c ∪ d)` where the
  intersection is below the union via an *intersected member* (e.g. `(fn ∩ U) <: U`
  through the `A=inter` rule) but **no single union member of `B` dominates the
  whole intersection**, committing to the `B=union` rule alone returns a wrong
  `false`, and transitivity sampling falsifies. **Resolution:** the two "exists"
  rules are both attempted — a `false` from `B=union` falls through to the
  `A=inter` rule before the relation gives up. The "decide by `B` first" framing is
  read as a *for-all*-rules-first ordering (`A=union`, `B=inter` decompose before
  the exists rules), not a single-rule commitment. This is the sound completion of
  the fragment; it adds no acceptance the full lattice would reject (it only stops
  rejecting pairs that genuinely hold).

- **Top/bottom law ordering relative to μ-unfold and connectives.** §3.2 lists the
  always-true (`B=unknown`, `A=never`) and always-false (`A=unknown`/`B≠unknown`,
  `B=never`/`A≠never`) laws together "before these" structural rules. Mechanization
  found the always-**false** laws must come *after* μ-unfold and connective
  decomposition: a μ may unfold to a bottom (`μX.never` reaches `never`), and an
  intersection may be empty via a bottom member, so a premature `B=never → false`
  cuts off the decomposition that would correctly decide `inter <: never` or
  `μX.never <: never`. The always-**true** laws are safe first (they hold
  regardless of shape). **Resolution:** always-true laws → μ-unfold → connective
  decomposition → always-false laws → primitive/structural rules. Sound and total.

- **`rec_with_indexer` named fields are governed by the rec part, not the index
  signature.** §3.2 says `rec_with_indexer` "decomposes to the conjunction of its
  `rec` part and its `indexer` part." Mechanization clarified that a field B *names*
  in its rec part is checked **only** against B's named-field type — the index
  signature applies solely to keys B does *not* name. (Otherwise a record with
  `tag: string` and an `{[string]: number}` indexer would wrongly require its own
  `tag` field to satisfy `string <: number`.) This is the standard TypeScript
  reading and is implicit in "conjunction of the rec part and the indexer part";
  recorded because the naive decomposition over-constrains.

- **Substrate/tooling note (not a spec finding): `--::` declarations are
  single-line.** The annotation parser does not support multi-line `--::` alias
  continuation, and cross-module type *aliases* do not share nominal identity
  across `require` (only structural inference unifies). Mechanization keeps each
  alias on one line and uses generic helper signatures (`<T>(...) -> {ty: T, ...}`)
  so field-constructor helpers unify with the interner's field type across the
  module boundary without force casts. This is a tooling constraint on how the
  slice is *written*, not a property of the slice's semantics.

**What buckled in the substrate during Pass 1: nothing** — Pass 1 is a pure,
self-contained function pair (`slice_ty` + `slice_subtype`) that does not import
the substrate (`init.lua` untouched), exactly as §10 predicted.

### 9.4 Mechanization findings — Pass 2 (synth/check methods + adapter)

Recorded honestly per the prompt. None crosses the fence; all are
implementation-shape decisions forced by the substrate/grammar, resolved
conservatively, and now load-bearing.

- **Types ride args as a *portable* encoding, not the interned `Ty` directly
  (sharpest Pass-2 finding).** An interned `Ty` (Pass 1) carries a `tid`,
  cross-references to other interned nodes, and **de-Bruijn `tyvar` indices** — it
  is not serializable as a claim arg, and the substrate's structural claim
  identity (`_serialize`) would key on unstable tids. Resolution: a PORTABLE
  `PTy` tag-tree (no tids; μ binders named at encode time so alpha-equivalent μ
  encode to structurally-equal trees) rides `ArgValue`, and the checker
  `parse-not-casts` it back through the interner (`slice_ty_arg.lua`). This is the
  exact STLC `parse_type` discipline applied to a richer grammar. Claim identity is
  then over the canonical portable form, so `has_type(Γ, n, μX.…)` is stable across
  interner generations. (The substrate still learns nothing — it sees only opaque
  `ArgValue`.)

- **Local generic instantiation keeps free type-parameters in the portable layer
  ONLY — never interned.** §2.4 frames the `instantiate_witness` input as
  `has_type(Γ, f_node, G)` "where G is the callee's generic type." But G has FREE
  type-parameter variables, and **free `tyvar`s are not a v1 grammar construct**
  (the grammar has no `forall`; `tyvar` exists only bound under a μ). Interning a
  free-tyvar `Ty` is therefore impossible. Resolution: the generic callee G is
  carried in the *witness payload* as a portable `PTy` with free `{k="tyvar",
  var=name}` nodes, and σ-application is a **portable-tree substitution**
  (`apply_subst_pty`) that produces a monomorphic `PTy`, decoded to an interned
  `Ty` only after σ is applied. The checker validates the σ-applied application
  post-hoc; it never infers σ — the fixpoint-rung witness pattern, intact. This is
  a *tightening* of §2.4's framing (G lives in the payload, not in a has_type
  premise that could never intern), not a contradiction.

- **The rejection-with-counterevidence slot is the diagnostic string.** §6.4 and
  the object model speak of `RejectedClaim.counterevidence`, but the substrate's
  `HostedChecker` return tuple has no dedicated counterexample slot (it returns
  `(result, diagnostic, deps, trust)`). Resolution: the `subtype_witness`
  counterexample (the offending constructor pair) and the `synth_index`
  no-such-field datum are surfaced **in the diagnostic string** the substrate
  already records on rejection. This is honest (the counterevidence is visible and
  testable) and needs no substrate change; a structured counterevidence slot would
  be a substrate extension, deferred with no v1 demand beyond the string.

- **`synth_table` array entries synthesize an `indexer(integer, V)`, not
  integer-literal-keyed fields.** §2.3 says synth_table yields a `rec` or
  `rec_with_indexer` "if positional/integer-keyed entries are present." A naive
  "tuple as integer-literal-string-keyed `rec`" does NOT subtype a declared
  `{ [integer]: Insn, ... }` (the field key `lit_str("1")` is not `<: integer`).
  Resolution: positional entries synthesize a precise `indexer(integer,
  union-of-elements)` (or a `rec_with_indexer` when named fields coexist), so the
  precise element union flows to the checking boundary and widens to the declared
  element type via the Pass-1 indexer rule. This is the clarification that makes
  the table-construction-widening fixture's checking boundary work without a store
  model (§9.1) — recorded because the "tuple" framing is the wrong lowering here.

- **`CheckResult.accepted_claims` is requested-scoped (test-harness note, not a
  spec finding).** The substrate populates `accepted_claims` only for
  `requested_claims`; a premise accepted internally but not requested does not
  appear there. Slice tests that assert a *premise* was accepted must request it
  explicitly. Inherited substrate behavior, surfaced here because the slice's deep
  trees make it easy to assert on an un-requested premise.

**What buckled in the substrate during Pass 2: nothing** — the slice is a pure
consumer of the unchanged claim database, dependency tracker, and worklist
checker. `init.lua` is byte-for-byte unchanged; the value-universe semantics is
hosted with no new substrate object kind, exactly as STLC and §9 predicted. The
strain was entirely in the *encoding* of types-as-args (resolved by the portable
codec) and the *framing* of generic instantiation (resolved by keeping free
tyvars portable), never against the substrate's shape.

### 9.5 Mechanization findings — Pass 3 (the flow-narrowing layer)

Recorded honestly per the prompt. None crosses the fence; all are
spec-tightenings forced by the mechanization, resolved conservatively, now
load-bearing. The deferral fence (no complement) held throughout — and is now
*tested as a fence*, not merely respected.

- **The `narrow_guard` premise is the pre-guard type, and Γ must agree with it
  (sharpest Pass-3 finding).** §4.2 frames the input as `has_type(Γ, x_node, T)` —
  "the synthesized pre-guard type of x." Mechanization found this needs THREE
  coherence checks the prose left implicit, all enforced: (1) the premise context
  must equal the conclusion's Γ (the refinement is *of* the pre-guard context);
  (2) the refined variable `x` must be bound in Γ; and (3) `x`'s binding in Γ must
  EQUAL the premise's asserted type `T` — otherwise a producer could feed a
  `has_type` for an *unrelated* node/type and claim a refinement of `x`. With all
  three, the narrowing is genuinely Γ-fed: the downstream truthy-branch synthesis
  runs under `extend(Γ, x, T_true)` and the rule guarantees `T_true` was computed
  from `x`'s actual pre-guard binding. This is a tightening of §4.2's
  single-premise framing, not a contradiction — the premise alone underdetermines
  *which* variable's binding `T` is, so the Γ-agreement check pins it.

- **Operand-order symmetry of comparisons is an adapter responsibility, not a
  refinement-core one.** §4.1 lists `x == "GET"` and `x.tag == "leaf"` with the
  variable on the left, but real Lua writes `"GET" == x` and `NODE_LEAF == n.kind`
  freely. Resolution: `recognize_guard` (the adapter) normalizes operand order by a
  rank heuristic (the var/index/`type()`-call operand becomes the refining side),
  so the pure `refine` core never sees orientation. This keeps the core's Guard
  grammar canonical (one shape per form) and the symmetry localized to the
  frontend, where it belongs. Recorded because the naive "left operand is the
  variable" reading would silently miss half the corpus's guards.

- **`type(x) == "<name>"` member-matching must enumerate the literal SUBKINDS, and
  must NOT match `unknown`.** §4.1's `type(x) == "string"` truthy = "the `string`
  member of the union `T`." Mechanization found "the string member" is really "every
  union member whose runtime `type()` is `"string"`" — which includes `lit_str`
  singletons, and for `"number"` includes `integer`/`lit_int`/`lit_num`, for
  `"table"` includes `rec`/`rec_with_indexer`/`indexer`, etc. (the §1 subkind
  lattice surfacing in narrowing). Critically, an `unknown` member is NOT matched
  (it could be any runtime kind — keeping it on the truthy branch would be an
  *unsound* narrow) and NOT dropped either (it stays via the falsy sound-wider T);
  the positive decomposition only keeps members it can *prove* match. Recorded
  because "the string member" undercounts the matching set and over-trusts
  `unknown`.

- **`x == lit` against an impossible target narrows truthy to `never`, not to the
  bare singleton.** §4.1 gives `x == "GET"` truthy = `lit_str("GET")`. Mechanization
  found this is only correct when `"GET"` is a *possible* value of `T` (`lit <: T`);
  when it is not (e.g. `x : integer` guarded `x == "GET"`), the truthy branch is
  unreachable and its refinement is `never` (the empty type), not a spurious
  `lit_str("GET")` that contradicts `T`. The rule checks `lit <: T` and yields
  `never` on failure. This is a soundness tightening (it never invents a value `T`
  cannot hold); `never` correctly marks the dead branch.

- **The tag discriminant unfolds a μ union-member ONCE before reading its tag
  field.** §4.1's tag form selects "the union members whose `tag` field admits the
  literal." Mechanization found that in the discriminated-union / hamt idiom a
  union member is frequently *itself* a μ (the recursive arm), so `member_admits_tag`
  unfolds a `mu` member one step (and distributes over a post-unfold union) before
  inspecting fields — otherwise the recursive arm is never matched and the
  discriminant silently drops it. This reuses the Pass-1 equirecursive `unfold`; no
  new machinery. Recorded because the flat "members whose tag field admits" reading
  misses μ-wrapped arms.

- **The falsy fence is now a TEST, not just a discipline (the §5.4 probe,
  realized).** Kernel §5.4 asks for an enumeration confirming the v1 falsy
  approximation is "wider, never unsound." Mechanization realizes this as an
  *executable* assertion: for `type(x)=="string"` over `string | number`, the
  checker ACCEPTS the falsy refinement `string | number` (the sound-wider T) and
  REJECTS the complement-precise falsy `number`. So an attempt to smuggle complement
  precision in — even a *correct* `~string` — is a rejection, because the rule
  re-derives the sound-wider T and the asserted exact-complement does not match. The
  fence is enforced by construction: there is no code path that produces `T & ~Atom`,
  and a claim asserting it cannot be evidenced. The ONE form whose complementary
  branch is exact — the nil-guard — is exact *positively* (the `nil` member is a
  union member, dropped or kept by the same positive operation), so it needs no
  complement and is not an exception to the fence.

**What buckled in the substrate during Pass 3: nothing** — the narrowing layer is a
pure consumer of the unchanged claim database. `init.lua` is byte-for-byte
unchanged; refinements are `narrows` claims with `narrow_guard` evidence and
`accepted_claim`/`artifact_content` dependency edges — never checker-internal
mutable state, confirmed by the adversarial walk (no `narrowing`/`flow`/`judgment`
id space appears; the guard rides an ordinary `syntax_tree` artifact). The
`narrows`/`narrow_guard` registry entries reserved by Pass 2 needed no change. The
strain was entirely in the *precision* of the sound approximations (recorded above)
and the *coherence checks* binding a refinement to its pre-guard Γ, never against
the substrate's shape.

### 9.6 Mechanization findings — Pass 4 (corpus validation + loop forms)

Recorded honestly per the prompt. The corpus run is the rung's grading moment, so
this section is the honest result: **all 11 fixtures Accept (0 errors), matching
every §7.1 Expected Verdict.** Nothing failed to reach its expected verdict; the
findings below are the spec-tightenings the loop-form mechanization and the
end-to-end run forced, each resolved without a fixture-keyed carve-out.

- **The μ-unfold must happen at the narrowing TARGET, not only at union members
  (sharpest Pass-4 finding — the one corpus-forced change).** §6.2 specifies that
  `if node.kind == NODE_LEAF` over `node : HamtNode` refines `node` to `Leaf`. But
  `HamtNode` is a `mu` whose body is a union (`Leaf | Interior`); Pass 3's
  `refine_tag_eq` ran the positive decomposition over `members_of(HamtNode)`, and
  `members_of` treated the bare `mu` as a one-element list (it only split a literal
  `union`). The whole μ was therefore kept on the truthy branch instead of just the
  `Leaf` arm. The fix is **principled, not fixture-keyed**: `members_of` now unfolds
  a `mu` target once (equirecursive: a μ and its unfolding are the same type) before
  splitting — the *identical* `G.unfold` Pass 3 already applies inside
  `member_admits_tag` to μ-wrapped union arms, now lifted to the discrimination
  target. This is the equirecursive discipline applied symmetrically (target and
  members), not a special case keyed on hamt or on any name. It is sound for every
  narrowing form (the falsy branch still returns the original `T`; truthy is the
  re-unioned unfolded members, which equals the μ's denotation), and all Pass-3
  narrow tests (32) + slice tests (110) stay green under it. Recorded because the
  flat `members_of` reading silently under-narrowed a μ-typed discriminant — exactly
  the hamt fixture's "narrow without a force cast" requirement.

- **`for-in pairs`/`ipairs` is loop-variable BINDING, not an iterator-protocol
  type.** §5.2 mandates `for-in` over `pairs`/`ipairs` only, "binding the loop
  variables from the table's key/value types … using the already-present
  `instantiate_witness` + `trusted_signature` machinery — no new substrate." The
  mechanization realizes this as two `has_type` evidence methods (`synth_loop_var`
  over a `has_type(table)` premise; `synth_numeric_for_var` with no premise), each
  computing the bound type from a pure derivation (`pairs_kv` / `ipairs_kv` over the
  table's `indexer`/`rec` structure). This is a *tightening* of §5.2's framing: the
  loop var's type is derived directly from the iterated table's `Ty` — there is no
  generic iterator callee to instantiate, because v1 admits only `pairs`/`ipairs`,
  whose key/value projection IS the trusted signature. The `$PairsReturn` leak
  vanishes by construction (§9.1): there is no intrinsic type in the projection to
  leak. `pairs_kv` over a `rec` yields `(string, fieldValueUnion)`; over an
  `indexer(K,V)` yields `(K,V)`; over a union distributes; over a μ unfolds — the
  same value-universe table grammar, no new constructor.

- **The numeric-for control variable is `integer | number`, kept as the literal
  union the doc names.** §5.2's rule binds `i : integer` over integer bounds, else
  `number`; v1 does not flow-track the bounds, so `synth_numeric_for_var` binds the
  conservative `integer | number` (the doc's stated v1 rule). The interner keeps
  both arms (distinct tids) rather than absorbing `integer` into `number` — sound
  (`integer <: number`, so the union denotes `number`) and faithful to the doc.

- **The corpus runner models CHECKED BEHAVIOR as the typing derivation, not by
  re-parsing `.lua` source (test-harness decision, not a spec finding).** Each
  fixture is exercised by constructing the claim graph for its load-bearing
  expressions — the derivation a correct checker concludes — and routing it through
  the hosted checker, exactly as the per-rule slice tests do. This is the faithful
  end-to-end test of `crescent.slice.v1` (every evidence method on the real
  registry), and it keeps the runner independent of a full Lua-statement frontend
  (the adapter's expression/statement lowering is exercised by its own unit tests).
  A fixture that did NOT reach its verdict would be recorded here as the rung's data;
  none did.

- **An annotated `-> Field` helper poisons local-generic inference of `G.rec`'s
  result across the test module (tooling constraint on how the test is WRITTEN, not
  a slice-semantics property).** A `--: (string, Ty) -> Field` field-constructor
  helper makes the bidirectional local-generic inference of `G.rec(...)`'s *result*
  leak `Field` into `Ty` positions module-wide (the same annotation-density
  fragility §9.3 finding 5 noted for cross-module aliases). The runner keeps the
  helper unannotated (tolerating one "no signature" lint warning) so `G.rec(...)`
  synthesizes `Ty` cleanly. This is a constraint on the *test's* phrasing, mirroring
  §9.3 finding 5; it says nothing about the slice's checked semantics.

**What buckled in the substrate during Pass 4: nothing** — the loop-form methods
are ordinary `has_type` evidence on the unchanged registry, and the corpus runner is
a pure consumer of the unchanged claim database. `init.lua` is byte-for-byte
unchanged across all four passes. The ladder's final rung lands with the agnostic
substrate validated from propositional logic through a real Crescent slice without a
single Crescent-specific substrate primitive.

---

## 10. Next Pass

Mechanization, in the four passes of §8, against this document — no further design
decisions required. **Pass 1 is DONE** (2026-06-12): the `Ty` grammar + hash-consed
interner + the subtype relation + its fuzz invariants + the §5.1 performance
benchmark, all in `lib/type/analysis/slice_{ty,subtype}.lua` (+ `_test`/`_bench`),
with findings in §9.3 and benchmark numbers in `docs/perf/log.md`. The substrate was
not touched, as predicted.

**Pass 2 is DONE** (2026-06-12): the synthesis/checking evidence methods + the
`crescent.slice.v1` registry entry + the parser-frontend adapter +
`trusted_signature` + `instantiate_witness` + `type_shape_check` (μ
contractiveness enforced), in `lib/type/analysis/{slice_ty_arg,crescent_slice,
crescent_slice_parse}.lua` (+ `crescent_slice_test.lua`, 70 assertions). This was
the first pass that imports the substrate — and it forced **no** substrate change
(`init.lua` byte-for-byte unchanged), exactly as §9 predicted on the STLC
precedent. Findings in §9.4.

**Pass 3 is DONE** (2026-06-12): the flow-narrowing layer — the `narrows` claim
builder + `narrow_guard` evidence method + guard decoder in `crescent_slice.lua`,
the pure refinement core `slice_narrow.lua` (the `Guard` grammar, the five v1
forms + and/or/not, positive-decomposition truthy / sound-wider falsy, the
nil-guard's exact two-sided positivity, tag-field μ-unfold selection), and guard
recognition (`recognize_guard`) in `crescent_slice_parse.lua`, with
`slice_narrow_test.lua` (32 assertions) + 40 new in `crescent_slice_test.lua`.
Refinements are derived `narrows` CLAIMS with visible dependency edges, Γ-fed into
synthesis by `extend`; the falsy fence is enforced as a TEST (a complement-precise
falsy is rejected). The substrate was again **not** touched (`init.lua`
byte-for-byte unchanged); the Pass-2-reserved `narrows`/`narrow_guard` registry
entries needed no change. Full `bin/cr test lib/type/analysis/` green at 4749
(4677 prior intact + 72). Findings in §9.5.

**Pass 4 is DONE** (2026-06-12): the `for-in pairs`/`ipairs` + numeric-`for`
loop-variable typing (`synth_loop_var` / `synth_numeric_for_var` + the pure
`pairs_kv`/`ipairs_kv` derivations in `crescent_slice.lua`, §5.2) and the corpus
validation runner (`corpus_test.lua`, 40 assertions). **All 11 fixtures Accept
(0 errors), matching every §7.1 Expected Verdict — the grading moment passed.** The
one corpus-forced change was the *principled* μ-unfold at the narrowing target in
`slice_narrow.lua`'s `members_of` (the equirecursive `unfold` lifted from members to
the discrimination target — not a fixture-keyed carve-out); no name-keyed or
fixture-keyed handler entered the checker. The substrate was again **not** touched
(`init.lua` byte-for-byte unchanged across all four passes). Full `bin/cr test
lib/type/analysis/` green at 4789 (4749 prior intact + 40). Findings in §9.6.

**All four mechanization passes are complete.** This is the ladder's final rung, and
it has landed: the agnostic substrate is validated from propositional logic through
a real Crescent slice without a single Crescent-specific substrate primitive — the
design doc's falsifiable bet (time-to-first-real-Crescent-claim) settled at the
target. No further mechanization passes remain; future work is *un-deferral* of the
fenced extensions (complement / RDNF / match types / row polymorphism / parametric
polymorphism / `cdata`/`userdata`/`thread` / metatables) each behind its written
§1.4 / §3.4 trigger, never a substrate rewrite.
