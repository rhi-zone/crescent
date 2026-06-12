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

## 6.5 Increment v2.1 — annotation-grammar reach + union-of-return-tuples

Status: design pass for slice **v2 increment 1**, derived against the two surveys
(`docs/slice-survey-v1.md`: the annotation-grammar survey's out-of-subset histogram
and the end-to-end survey's CHECKED-FINDINGS). This section grows the design FIRST,
whole, from the value universe and the ratified kernel fence
(`docs/decisions/kernel-recommendation.md` §3 — no complement, no match types, no
global solving, no HKT). It is **monotone** over §1–§5: every addition is either a
pure annotation-grammar desugaring (a parser change, no lattice change) or a single
new value-universe-justified constructor with its subtype rule slotted into THE one
relation (§3). Nothing here crosses the fence.

The increment closes the measured top of the demand histogram. Each item below is
derived, then its mechanization surface (grammar / PTy / lowering / subtype / codec)
is named. The demand-ordered scope: named parameters (266 files), `self` (128),
`T[]` array shorthand (88), `{ T }` list shorthand (the CHECKED-FINDINGS gap),
multi-line `--::` aliases (the "unterminated table type" finding), and
union-of-multi-return-tuples `(A, B) | (nil, string)` (the dominant error-return
idiom). **Out of this increment** (recorded as increment 2's headline): cross-module
/ unresolved type aliases (232 files) — a multi-artifact / `require`-boundary
extension, not an annotation-grammar reach.

### 6.5.1 Named parameters `name: T` — names ride `Params`, subtyping ignores them

**Value-universe derivation.** A Lua function value consumes a *positional*
parameter tuple; the parameter *names* are local bindings inside the body, never
part of the value's call ABI. So a parameter name is **diagnostic and binding
metadata**, not a type-algebra distinction: `(a: number) -> number` and
`(b: number) -> number` describe the *same* function values and must be the same
type. This is exactly TypeScript's rule (parameter names are ignored in function
subtyping) and the only sound reading of the universe.

**Grammar + PTy.** `Params.fixed` stays a positional `Ty[]`. A parallel optional
`Params.names: (string | nil)[]` carries the i-th parameter's name when the
annotation supplied one (`nil` for an unnamed positional slot, and for the vararg).
Names are **NOT part of the interner's structural key** (§3.1) — two `fn` types
differing only in parameter names intern to the SAME tid, which is precisely how the
subtype relation comes to ignore them *for free* (tid identity ⇒ name-blind). The
portable `PTy` `fn` node carries `params.names` so the name survives the codec for
diagnostics/lowering, but since names are not in the structural key, the
encode/decode round-trip is name-faithful without affecting claim identity.

**Lowering.** A named param `name: T` binds `name : T` in the function body's Γ
(the `synth_function` context extension, §2.3) — this is the reach that lets the
end-to-end frontend type a body that references its parameters by name. An unnamed
positional param annotation binds nothing (the body must not reference it; if it
does, that is an out-of-subset unannotated-reference, unchanged).

**Subtype relation: no change.** Because names are interner-invisible, `subtype`
already ignores them. This is the cleanest possible discharge of "subtype relation
ignores names (structural)": there is no name-stripping step, no special case — the
names simply never enter the structural key.

### 6.5.2 `self` parameter — an ordinary named first parameter

**Decision (justified from the value universe).** `self` is **an ordinary named
first parameter**, treated identically to §6.5.1's `name: T`, with `name = "self"`.
There is no `self`-specific type rule, no implicit receiver binding, no special
case in the relation or the gen-pass.

**Why this is the right v1 treatment.** The value universe makes `o:m(a)` exactly
`o.m(o, a)` — method-call sugar desugars to passing the receiver as the first
positional argument. So `self` *is* the first positional parameter; its type is
whatever the annotation declares (`self: HamtNode` ⇒ first param type `HamtNode`),
and it binds the name `self` in the body. The annotation grammar always supplies a
type for `self` (it is written `self: T`), so the "default the receiver type when
statically known, else `unknown`" question the prompt raised **does not arise in the
annotation-grammar reach** — the annotation IS the type. (A bare `self` with no
annotation would be the unannotated-parameter case, already out-of-subset and
unchanged; v1 does not synthesize a receiver type from an enclosing module, because
that is cross-statement store inference the slice defers, §9.2.) Treating `self` as
an ordinary named param is therefore the value-universe-faithful, no-special-case
choice: the survey's separate `named-param-self` tag was a *measurement* distinction
(to size the method-signature population), never a semantic one. Both `named-param`
and `named-param-self` are closed by the SAME mechanism.

### 6.5.3 `T[]` array shorthand — pure desugaring to `indexer(integer, T)`

**Derivation.** `T[]` is sugar; the universe has no "array" value kind distinct from
a table used as an integer-keyed map. v1 already spells arrays `{ [integer]: T }` =
`indexer(integer, T)` (§1.3). `T[]` desugars to that **at parse time**; no new
constructor, no PTy change, no subtype rule. The desugaring is in `parse_postfix`
(§5.1's grammar): after parsing an atom (and its `?` postfixes), an empty bracket
pair `[]` rewrites the type to `G.indexer(G.integer(), T)`. `T[][]` nests
(`indexer(integer, indexer(integer, T))`). This is the single canonical array form
post-parse.

### 6.5.4 `{ T }` list shorthand — identical canonical form (decided: YES)

**Decision.** `{ T }` (a table-type body that is a single *bare* type with no
`key:` and no `[K]:`) desugars to the **identical** target as `T[]`:
`indexer(integer, T)`. `{ T }` and `T[]` are the same type post-parse — one
canonical form. This is the recommended resolution of the CHECKED-FINDINGS gap (the
`{ string }`, `{ Listener }` annotations that failed with "expected `:` after field
name"). Justification: both spellings denote "a list of `T`" = an integer-keyed
table of `T`, which the universe produces identically; keeping two distinct internal
forms would be a gratuitous asymmetry (the "collapse asymmetries to primitives"
principle). The parser's `parse_table_type` gains one case: if the first token after
`{` parses as a type (not an `ident :` field, not `[K]:`, not `...`) and is followed
by `}`, the body is a list shorthand. A multi-element `{ A, B }` is **rejected** (a
list shorthand is single-element; `{ A, B }` is neither a record nor a tuple-type in
v1 — tuples live only in function param/return position, §1.3, now §6.5.5). Note the
grammar disambiguation: `{ [K]: V }` (index signature) and `{ key: T }` (record) are
unchanged and take precedence; only a leading bare-type triggers the list reading.

### 6.5.5 Union-of-multi-return-tuples — the one type-algebra growth

This is the increment's only lattice growth — a new constructor — and the survey's
dominant error-return idiom: `(A, B) | (nil, string)`, the Lua "return the value, or
`nil` plus an error message" convention. It is derived from the value universe, not
from the fixtures.

**Value-universe derivation.** A Lua `return` statement genuinely produces *one of
several return shapes*: the success path returns `(value)` or `(value1, value2)`;
the error path returns `(nil, "message")`. A single call site `local a, b = f()`
therefore binds `(a, b)` to one member of a **union of return tuples**. The function
type's *return position* must admit this union. v1 already models a single multi-
return as a return-position tuple (`Ret = { fixed, vararg }`, §1.2); the universe now
forces the return to be a *union whose members are tuples*. This is real algebra
growth (not sugar): the lattice must close return-position tuples under union.

**Grammar: the `tuple` constructor.** A tuple is currently implicit — it exists only
as the `Ret`/`Params` record, never as a first-class `Ty`. To let a *union member* be
a multi-element tuple, v1 admits a new constructor:

```text
  | tuple(fixed: [Ty], vararg: Ty | nil)   -- a positional return/spread tuple
```

A `tuple` is a **return-position-only** value-shape: it denotes the sequence of
values a `return` produces. It is NOT a table (a table is `rec`/`indexer`); it is the
multi-value spread Lua's calling convention produces and consumes. Its sole roles:
(a) a member of a `union` in function *return* position, and (b) the normalized form
of a multi-element `Ret`. A single-element tuple `tuple([A])` normalizes to `A`
(a one-value return is just that value — the universe does not distinguish `return a`
from a one-tuple), so `tuple` only ever has 0 or ≥2 fixed elements (or a vararg). The
interner keys it structurally exactly like `fn`'s tuples (`tids(fixed)|opt_tid(vararg)`).

Justification from the universe and the fence: this is the *minimal* constructor that
expresses the idiom. It is admitted because the universe **produces** multi-value
return sequences and **discriminates** between alternative ones at a call site — the
§1.1 admission rule. It needs no complement, no match type, no global solve, no HKT:
the subtype rule below is the standard structural exists-forall for unions of tuples.

**Where it appears.** Only inside a function's `Ret` (and, symmetrically, a vararg
spread). `Ret` becomes: `Ret = { fixed, vararg }` as before for the simple case, OR
the return is a `union` whose members are `tuple`/non-tuple types. Concretely the
parser, on seeing `(A, B) | (nil, string)` in return position, builds
`union([ tuple([A, B]), tuple([nil, string]) ])`. A return of `T | (nil, string)`
(value-or-error where the success is a single value) builds
`union([ T, tuple([nil, string]) ])` — a union mixing a scalar member and a tuple
member, which is well-formed (a one-value return vs a two-value return).

**Subtype rule (spec).** The relation (§3.2) gains the `tuple` constructor pair,
slotted with the other structural rules:

- **`tuple(Fa, va) <: tuple(Fb, vb)`** — pointwise **covariant** on fixed elements
  (a return tuple is produced, hence covariant, exactly like `Ret`), with the same
  arity interplay as function returns: `A` may produce MORE fixed values than `B`
  needs (extra returns are droppable), so a longer tuple is `<:` a shorter prefix;
  `A` must produce at least `B`'s fixed count (unless `A` has a vararg tail covering
  the remainder). Varargs: covariant on the tail element when both present. This is
  *identical* to the existing `fn`-return rule (§3.2), lifted to the standalone
  constructor — the `fn` return check is refactored to call the same `tuple_sub`
  helper, so there is ONE tuple-subtype rule, not two.
- **`tuple <: union`** and **`union <: union`** — these need NO new rule: they are the
  EXISTING union decomposition (§3.2: `B = union → A <: some member`;
  `A = union → every member <: B`). A `tuple` is just another atom to the union
  rules. So **union-of-tuples `<:` union-of-tuples is the standard exists-forall**
  the relation already implements: `(A,B)|(nil,str) <: (A,B)|(nil,str)|(C)` holds
  because each left tuple member is `<:` some right member. `tuple <: union-of-tuples`
  is `A <: some member`. `union-of-tuples <: union-of-tuples` is the conjunction over
  left members of (disjunction over right members). **The only genuinely new code is
  the `tuple <: tuple` pair**; everything else is the union machinery already proven.
- **A bare value vs a tuple**: `A <: tuple([B])` never arises (one-tuples normalize
  to `A`); `A <: tuple([B, C])` (a scalar against a ≥2 tuple) is **false** (a single
  value cannot satisfy a two-value return), and `tuple([B, C]) <: A` for non-tuple
  `A` is **false** (a multi-value spread is not a single value). These fall out of
  the constructor-pair dispatch returning `false` for unmatched pairs — no special
  case.
- **`integer <: number` / literals / records / fns / μ**: unchanged. A `tuple` may
  contain any `Ty` (including a μ or a union), so the rule recurses through `sub`
  normally, participating in the cycle guard and memo like every other constructor.

**Arity interplay with spreads (explicit).** A vararg in a tuple
(`tuple([A], vararg=B)`) means "A followed by zero or more B" — the Lua
`return a, table.unpack(rest)` shape. The `tuple_sub` rule handles it exactly as the
`fn`-return vararg: B's fixed prefix must be covered by A's fixed-or-vararg, and a
present vararg on both sides is covariant on the tail. No new arity logic beyond
what the `fn` return already specifies; the refactor *shares* it.

**Codec (PTy).** A new portable node `{ k="tuple", fixed=[PTy..], vararg=PTy? }`,
encoded/decoded symmetrically with `fn`'s tuples and validated parse-not-cast (a
`tuple` with fewer than 2 fixed and no vararg is rejected by the decoder — it should
have normalized to its single element or to the empty case, so the non-canonical form
is malformed input). Well-formedness (`type_shape_check`): a `tuple`'s elements are
checked recursively; a `tuple` nested *inside a table field or another tuple's
non-return position* is **ill-formed** (a tuple is return-position-only) — but in v1
the parser only ever constructs a `tuple` in return position, so this is a decoder
guard against a malformed producer, not a parser path.

**Narrowing interplay — deferred to increment 2 (recorded, not rushed).** The
idiom's *consumer* is `local ok, err = f(); if not ok then ... end` — multi-return
destructuring followed by a guard on the first slot. v1's narrowing (§4) refines a
single variable's binding; narrowing `ok` to drop the success tuple and select the
`(nil, string)` member is **multi-return-aware narrowing** (the guard on slot 1
refines the *joint* tuple). No §6.5 fixture *requires* it (the fixtures exercise the
return-position *annotation* and the subtype relation, not the destructuring-narrow
consumer), so per the prompt this is **recorded as increment 2's narrowing item**,
not built here. The relation and the annotation grammar land in this increment; the
flow-narrowing consumer follows when a fixture demands it.

### 6.5.6 Multi-line `--::` alias scanning

**Derivation (a scanner reach, not a semantics change).** The CHECKED-FINDINGS
"unterminated table type" diagnostics (`lib/asm/ir.lua`, `lib/platform/platform_types.lua`,
the ccv2 type files) are all wrapped `--:: Name = {` declarations whose body spans
several `--::` continuation lines. The slice's annotation *semantics* already handle
the full type; only the line *scanner* (`scan_annotation`, the survey's
`extract_annotations`) assumed one directive per line. The reach is purely lexical:
when a `--::` (or `--:`) directive's body has an *unbalanced* `{`/`(` (more opens than
closes) or ends mid-type, the scanner **consumes subsequent `--::` continuation
lines**, concatenating their bodies (stripping the leading `--::`/`--:` and
whitespace) until the brackets balance and the type is complete. The concrete syntax
is exactly the two real examples checked: `--:: Name = {` then `--::   field: T,`
lines then `--:: }`. This is a frontend tokenization fix; the type grammar parser
(`parse_type_ann`) is unchanged — it receives the joined single-line body it always
expected. Recorded honestly: this corrects the §9.3-finding-5 "single-line only"
constraint, which was a *scanner* limitation, never a semantic one.

### 6.5.7 Mechanization surface summary

| Item | Grammar/parser | PTy codec | Subtype | Lowering | Tests |
|---|---|---|---|---|---|
| Named params | `Params.names` (interner-invisible) | `fn.params.names` | none (tid-blind) | bind name in body Γ | parse + codec round-trip + name-blind subtype |
| `self` | same as named (`name="self"`) | same | none | same | one `self:T` parse test |
| `T[]` | desugar in `parse_postfix` | none | none | none | parse → `indexer(integer,T)` |
| `{ T }` | desugar in `parse_table_type` | none | none | none | parse → identical to `T[]` |
| union-of-tuples | `tuple` ctor; parser builds union in return pos | `{k="tuple",...}` | NEW `tuple<:tuple`; reuse union | call-site slot draw unchanged | unit + fuzz (tuple-union generator) + codec |
| multi-line `--::` | scanner continuation in `scan_annotation`/`extract_annotations` | none | none | none | multi-line alias parse |

The fence holds: five of six items are annotation-grammar desugaring or scanner
reach (zero lattice change); the sixth (`tuple`) is one value-universe-justified
constructor whose subtype rule is the standard structural covariance + the EXISTING
union exists-forall. No complement, no match types, no global solving, no HKT.

## 6.6 Increment v2.2 — cross-module type-alias resolution (the multi-artifact derived whole)

Status: design pass for slice **v2 increment 2**, the measured **#1** annotation
survey demand (`docs/slice-survey-v1.md` after-increment-1: `unknown-type-name`,
172 files). It is the first genuinely **multi-artifact** extension: every prior
increment touched one file's annotation grammar; this one resolves a type name
*declared in one module* against an annotation *in another module*. Derived whole
from the **object model** (`docs/agnostic-static-analysis-object-model.md`) and the
real `lib/` idiom — NOT improvised to make a fixture pass. The headline finding
first: **no substrate change is required.** The object model already makes
artifacts first-class, claims carry `subject_artifacts` (plural), dependencies
target other artifacts' content, and trust boundaries carry `covers`. The
multi-artifact story *exists in the model*; this increment **consumes** it. §9.2's
prior note — "a checked cross-module relation … would need the required module's
artifact in the same `CheckRequest`" — is realized here without a single new object
kind: the required module's `--::` aliases enter as artifacts + observations in the
same state, and the consuming claim records a `Dependency` to them.

### 6.6.1 The real idiom (corpus reality, checked before designing)

Two cross-module forms exist in real `lib/` code, both referencing the imported
type by its **bare, unqualified declared name** (no `mod.Type` qualification idiom
exists anywhere in the corpus — verified by grep):

1. **Value-import form (the original fixture's source fire).**
   `lib/dns/tcp_client.lua` does `require("lib.epoll")` and wants to annotate a
   parameter `epoll: epoll | nil`, where `--:: epoll = { fd: integer, wait: ... }`
   is declared in `lib/epoll/init.lua`. Today it is forced to write
   `unknown | nil` with a TODO (`lib/dns/tcp_client.lua:12-15`) — the exact
   `unknown-type-name` the survey counts.

2. **Type-only-import directive form (the *dominant* idiom — 48 files).**
   `--:: require "lib.taskgraph.taskgraph_types"` — a `--::` directive whose body
   is `require "<modpath>"`, importing *only* that module's `--::` aliases into the
   current file's annotation scope (`lib/taskgraph/combinators.lua` then references
   `TaskDef`, `TaskNode` by bare name). This form is purely a *type-level* import:
   it has no runtime value, exists only to make the names visible, and is the
   idiom the corpus uses most. v1's `scan_annotation` already returns `nil` for a
   `--::` without `=` (`crescent_slice_parse.lua`), so this directive is currently
   dropped — and every name it would have imported becomes `unknown-type-name`.

The design must serve **both**: the value-import form (the original fixture, the
tcp_client+epoll pair) and the type-only-import directive (the dominant count).

### 6.6.2 Q1 — the unit of cross-module knowledge, and the visibility rule

**Unit (per the object model).** Each file is an **artifact** (`kind = "source_text"`
for the exporting module, `syntax_tree` for the lowered entry). An alias
declaration `--:: Name = T` in module M is an **observation** about M's artifact
(`predicate = "alias"`, `args = { name, body }`, `source_artifacts = [M]`). Module
N's annotation referencing `Name` **consumes that observation across artifacts**:
N's `has_type`/`checks_against`/`well_typed_type` claim that uses the resolved `Ty`
records a `Dependency { from_claim = <N's claim>, kind = "observation", target =
<M's alias observation>, invalidation = "exporting alias body changed" }`.

**Visibility rule (decided by the corpus, not invented).** Importing module M
brings M's **top-level** `--::` aliases into N's annotation scope **under their bare
declared names**, flat and unqualified — because that is the only form the corpus
uses (`TaskDef`, `epoll`, never `taskgraph_types.TaskDef`). Two import triggers,
both already present in source:

- **`--:: require "lib.x.y"`** (type-only directive) → import lib/x/y's top-level
  aliases. This is the primary, unambiguous trigger: a `--::` directive whose body
  matches `^require%s+"(.+)"$`. It is a *type-import statement*, parsed by the
  scanner, never reaching the type-grammar parser.
- **`local v = require("lib.x.y")`** (value import) → ALSO import lib/x/y's
  top-level aliases into the flat name scope. This serves the original fixture
  (tcp_client requires lib.epoll, then annotates `epoll | nil`). The bare-name
  flattening matches the corpus (the alias is `epoll`, referenced as `epoll`); the
  local binding name (`v`) is irrelevant to *type* visibility, exactly as the
  corpus never qualifies.

**Module-path resolution.** `require("lib.x.y")` → `lib/x/y.lua`; `require("lib.x")`
→ `lib/x/init.lua` if `lib/x.lua` is absent (the standard Lua package layout). Only
**static string-literal** `require` forms inside `lib/` are resolved; a dynamic
`require(var)` is **out-of-subset**, tagged `dynamic-require` (never silently
ignored — a silent skip would manufacture a false-clean). A required module path
outside `lib/` (`require("bit")`, `require("ffi")`) is not an alias source and is
not an error — it simply contributes no aliases.

**Assembly order.** The cross-module alias environment for checking N is assembled
**before** N's own aliases and signatures are processed: (1) collect N's import
triggers (both forms) in source order; (2) for each, read+scan the exporting
module's top-level `--::` aliases and `declare_alias` them into a base env; (3)
process N's own `--::` aliases on top (most-recent-wins, so a local alias shadows an
imported one — the standard lexical rule); (4) parse N's signatures against the
assembled env. This is exactly `scan_source`'s existing two-pass shape, prefixed
with an import pass.

**Caps-first (CLAUDE.md hard constraint).** Reading the exporting module's source is
**I/O**, so the lowering driver accepts a `read_file` capability injected via
`opts`. It is NEVER reached from `io.open` directly inside the library; if a caller
needs cross-module resolution it injects the cap, and if no cap is injected
cross-module imports resolve to **no aliases** (the names stay `unknown-type-name`,
the honest pre-increment behavior) rather than silently reaching for `io`. The
survey/test callers inject a thin `io.open`-backed reader at the edge.

### 6.6.3 Q2 — staleness / invalidation (records correct, implementation minimal)

The object model's `Dependency.invalidation` field must be **populated correctly**
even though the v1 driver's incremental story is "re-check everything." Each
cross-artifact `Dependency` from N's claim to M's alias observation carries
`invalidation = "exporting alias '<Name>' body changed in <modpath>"`. A concrete
encoding that crosses a cache boundary would additionally digest M's artifact
content (the object model's `Artifact.digest`, optional at model level); the v1
driver records the *relation* (which claim depends on which exporting observation)
so an incremental/audit tool can recompute it — it does not itself diff digests.
This satisfies the model's rule: "the substrate does not compute every invalidation
relation by itself; it must store them so incremental and audit tools can reason."
Re-check-everything is the acceptable v1 *evaluation* strategy; the *records* are
the deliverable and they are precise.

### 6.6.4 Q3 — cycles (mutually-requiring modules, mutually-referencing aliases)

Modules legitimately require each other (`lib.taskgraph.exec` ↔ `lib.taskgraph.context`),
and a `--:: require` cycle is possible. The resolution **terminates by a principled
verdict**, not the μ machinery and not a hang:

- **Import resolution is acyclic by construction via a visited set.** The import
  pass tracks the set of module paths already being resolved on the current chain.
  Re-encountering a path on the chain **stops** (the aliases it would contribute are
  already in-flight or will be contributed once); it does not recurse into it again.
  This is the standard import-cycle break, and it is *sound for aliases* because an
  alias environment is a monotone accumulation — visiting M once contributes all of
  M's top-level aliases; a second visit on the same chain would contribute nothing
  new. So a cycle terminates with the union of every reachable module's aliases.

- **Why not μ here?** The μ machinery (§3) decides *subtyping* of recursive
  *types*; an import cycle is a cycle in the *module graph*, a different object.
  A cross-module *type* alias whose body references another module's alias that in
  turn references the first **does NOT reduce to the in-file recursive case** — each
  exporting module is parsed independently, before the other's names are installed.
  When A's alias body references B's name and A is parsed first, B's name is absent
  from the alias env at parse time; the result is an `unknown-type-name` error in
  A's export, not a μ binding. This is the **honest behavior**: mutual cross-module
  aliases error at v1. It is consistent with in-file forward references (§9.8
  deferral: names must be declared before use in the current flat env). The fix —
  two-phase name-installation-then-parse — is a unified substrate mechanism covering
  both in-file and cross-module forward/mutual aliases; it is recorded as a single
  deferral item in §9.11 with its trigger condition. (Audit round 2, F2 retraction:
  this section originally claimed mutual cross-module aliases reduce to the in-file
  recursive case via `declare_alias`'s μ-placeholder. That claim was false and has
  been corrected here and in `crescent_slice_xmodule.lua`'s docstring.)

- **Depth bound.** The visited set bounds recursion depth to the number of distinct
  `lib/` modules on a chain (finite); termination is structural, not timeout-based.

### 6.6.5 Q4 — trust (an imported alias is cross-artifact information)

**Yes — an imported alias rides a trust boundary**, and it is made visible per the
object model's trust obligations. The importing check **trusts the exporting
module's parse**: N's checker validates N's annotations, but it admits the *shape*
of M's alias `Ty` on the basis of M's `--::` declaration, which N did not itself
re-derive from M's runtime semantics. This is exactly a `TrustBoundary`:

```text
TrustBoundary {
  kind    = "cross_module_alias",
  issuer  = "crescent.slice.v1",
  covers  = <the exporting module path + the imported alias name(s)>,
  policy  = "alias Ty admitted from exporting module's --:: declaration; the
             exporting module's parse is trusted, not re-checked"
}
```

Each cross-module-resolved claim records a `Dependency { kind = "trusted_boundary",
target = <this boundary> }` **in addition to** the `observation` dependency on the
exporting alias. The trust summary therefore surfaces *every* cross-module alias
admission, exactly as force casts and stdlib signatures are surfaced (§2.5). This
is the honest position §9.2 named — "cross-module alias propagation is a trusted
boundary, not a checked relation" — now made a *visible, recorded* boundary rather
than an invisible gap. The boundary is distinct from the stdlib boundary (§7.1's
`slice-stdlib`): a `cross_module_alias` boundary `covers` a specific exporting
module + name set, so an audit can see precisely which other artifact each claim
trusted.

What is **checked** vs **trusted**, made precise: the *resolution* (Name → the M's
`Ty` data) is checked — N's parser really parses M's `--::` body into the slice `Ty`
grammar, parse-not-cast, and a malformed exporting alias is a real error attributed
to M. What is *trusted* is that M's `--::` declaration faithfully describes M's
exported value (the same trust v1 already grants every `--::` alias about its own
module's values). So cross-module resolution does not *add* trust beyond what an
in-file alias already carries; it makes the *cross-artifact* hop where that trust is
transferred **visible** as a boundary.

### 6.6.6 Mechanization surface summary

| Item | Where | What it does | Substrate? |
|---|---|---|---|
| `--:: require "x"` scan | `crescent_slice_parse.scan_annotation` | recognize the type-only import directive → `{ kind = "import", module = "x" }` | none |
| value-`require` import detection | the lowering/survey import pass | static-string `require("lib.x")` → module path; dynamic → `dynamic-require` marker | none |
| module-path → file path | new pure helper | `lib.x.y` → `lib/x/y.lua` \| `lib/x/init.lua` | none |
| top-level alias extraction | reuse `scan_annotation_at` + `declare_alias` over the exporting source | the exporting module's `--::` aliases into a base env | none |
| import pass (cap-injected) | `crescent_slice_lower` + `slice_survey`, `opts.read_file` | acyclic-visited resolution, base env assembly before local aliases | none |
| cross-artifact `Dependency` | the lowering builder | claim → exporting alias observation (`kind="observation"`, invalidation) | uses existing `A.dependency` |
| `cross_module_alias` `TrustBoundary` | the lowering builder | one boundary per exporting module, `covers` = module+names | uses existing `A.trust_boundary` |
| exporting artifacts/observations | the import pass | M's `source_text` artifact + per-alias `observation` added to the state | uses existing `A.add_artifact`/`A.add_observation` |

**The fence holds and the substrate is untouched.** Every row is either a scanner /
path / pure-helper reach (zero lattice change, no new type constructor) or a use of
an *existing* substrate object kind (`Dependency`, `TrustBoundary`, `Artifact`,
`Observation`) for the multi-artifact relation the object model already supports.
No complement, no match types, no global solving, no HKT, no new claim predicate,
no new evidence method, **no `init.lua` change.** This is the design's prediction
discharged: cross-module resolution is a *consumer* of the multi-artifact model, not
an extension of it.

## 6.7 Increment v2.3 — the end-to-end statement-coverage front

Status: design pass for slice **v2 increment 3**, the measured top of the *end-to-end*
(statement-lowering) survey histogram (`docs/slice-survey-v1.md`, "v1 end-to-end"):
operator typing (`operator-concat` 702 files, `operator-arith` 286), module/`require`
access (`unbound-name:package` 681, `unbound-name:require` 396), unannotated-function
handling (471), assignment forms (`assign` 696, `field-assign` 440, `multi-assign`
312), and method calls (`method-call` 214). These are the largest gap between the slice
and a checker one can point at an arbitrary `lib/` file: end-to-end CHECKED-CLEAN sits
at 0.6% (5 files), ~99% out-of-subset, dominated entirely by these statement forms.

Each addition below is derived **whole from Lua's value universe** (the v6 principle),
metatable-free for v1 (the §1.4 metatable deferral binds), then its mechanization
surface is named. The kernel fence (§3, ratified) binds: no complement, no match
types, no global solving, no HKT, no new subtype machinery beyond the existing
structural relation. The no-special-casing hard constraint binds: every rule is a
value-universe derivation expressed as an evidence method the substrate routes blind,
never a name-keyed handler. The dependency-honest order — operators and assignments
before module access (module access *consumes* operator/assignment typing in real
bodies) — is the landing order if the scope must be split.

### 6.7.1 Operator typing — derived from Lua's evaluation semantics (metatable-free)

**Value-universe derivation.** A Lua operator is a value-to-value function whose
result kind is fixed by the operand kinds *when no metatable participates*. v1 types
the metatable-free core exactly and tags the metatable-dependent operands as
out-of-subset (a *deferral*, never an error claim — v1 cannot know the metatable, so
claiming a type error would be unsound). The derivation pins each result from what the
LuaJIT VM actually produces:

- **Arithmetic `+ - * / % ^`.** Over `number`/`integer` operands the result is a
  number. The integer-vs-number result rule, pinned from the LuaJIT 5.1 value
  universe (the Crescent target):
  - LuaJIT 5.1 numbers are IEEE doubles; there is no separate integer *runtime* tag
    (unlike Lua 5.3). The slice's `integer` is a *type-level subkind* (`integer <:
    number`, §1.2), describing integer-*valued* doubles.
  - `/` and `^` **always** produce `number` (division and exponentiation are
    real-valued: `4 / 2` is the double `2.0`, `2 ^ 2` is `4.0` — integer-valued, but
    the operator's *type* is `number` because the universe does not guarantee an
    integer-valued result for arbitrary operands, e.g. `1 / 3`). Decision: `/` and
    `^` synthesize `number` unconditionally. Justified: the result kind is `number`
    for *all* operand pairs; narrowing to `integer` would be unsound.
  - `+ - * %` over two `integer`-typed operands synthesize `integer` (integer-valued
    operands under these operators yield integer-valued results — `3 + 4`, `7 % 3`,
    `3 * 4`, `5 - 2` are all integer-valued doubles). If *either* operand is a
    non-integer `number`, the result is `number`. Decision: `+ - * %` synthesize
    `integer` iff both operands are `<: integer`, else `number`. (Literal operands
    `lit_int`/`lit_num` are `<: integer`/`<: number` respectively, so `1 + 2`
    synthesizes `integer` — precise enough for the corpus's index arithmetic, without
    a constant-folding rule, which is out of scope: v1 does not fold `1 + 2` to
    `lit_int(3)`, only to `integer`.)
  - Operands must each be `<: number`. A `lit_int`/`lit_num`/`integer`/`number`
    operand qualifies. Anything else (a `string`, a `rec`, a `union` not `<: number`)
    is the **metatable-dependent** case: tagged `operator-metamethod-arith`
    (deferral + trigger: a corpus fixture whose checked syntax dispatches arithmetic
    through a metamethod), never a type-error claim.
- **Concat `..`.** Over `string|number` operands the result is `string` (Lua coerces
  a number operand to its string form). Decision: each operand must be `<:
  union(string, number)` (a `lit_str`, `string`, `lit_int`, `lit_num`, `integer`,
  `number`, or a union of these qualifies); the result is `string`. A non-string,
  non-number operand is `operator-metamethod-concat` (deferral). The result is the
  base `string` type, never a `lit_str` (v1 does not fold concatenation).
- **Order comparisons `< <= > >=`.** The universe permits these only over
  *compatible primitive pairs*: two numbers, or two strings (Lua errors at runtime on
  mixed or table operands without `__lt`/`__le`). Decision: both operands must be `<:
  number`, **or** both `<: string`; the result is `boolean`. Mixed (one number, one
  string) or non-primitive operands are `operator-metamethod-compare` (deferral —
  v1 cannot know the operands carry comparison metamethods). Result `boolean`.
- **Equality `== ~=`.** The universe permits these over *any* two values (Lua's `==`
  never errors; absent `__eq` it is identity/primitive equality). Decision: operands
  are unrestricted (each merely synthesized to keep it in-subset); the result is
  `boolean`. The narrowing layer (§4) already consumes `==`/`~=` guards (`lit_eq`,
  `nil_eq`, `tag_eq`); this rule supplies the *expression* type `boolean` for
  `==`/`~=` used in non-guard position (e.g. `return a == b`).
- **Length `#`.** Over `string` or `table` (`rec`/`indexer`/`rec_with_indexer`/an
  open row) the result is `integer` (a length is a non-negative integer-valued
  count). Decision: operand `<: string` OR operand is a table kind ⇒ `integer`. A
  non-string non-table operand is `operator-metamethod-len` (deferral). Result
  `integer`.
- **Unary minus `-`.** Over `number`/`integer` ⇒ same kind as the operand
  (`-x : integer` if `x <: integer`, else `number`). Non-numeric ⇒
  `operator-metamethod-unm` (deferral).
- **Unary `not`.** Over *any* value ⇒ `boolean` (Lua's `not` is total and
  metatable-blind: `not v` is `false` for truthy `v`, `true` for `nil`/`false`).
  This is the EXISTING `synth_and_or_not` `not` rule (§2.3), already implemented —
  the operator front merely routes `#`/`-` here is NOT it; `not` stays where it is.

**Why this is metatable-free-honest.** Every "deferral" branch is the case where a
*metatable* could change the result kind. v1 has no metatable types (§1.4), so it
*cannot* claim the result type — but it also must not claim a type *error*, because a
metatable might make the operation legal. The tag is therefore `operator-metamethod-*`
(out-of-subset deferral with an un-defer trigger), exactly the §1.4 posture, never an
`operator-type-error`. This is the sole sound v1 reading. The result-type rules above
are precisely the rewrite-design's operator typing with the metamethod arms elided —
monotone, like every prior increment.

**Mechanization surface.** One new evidence method `synth_binop` (binary operators)
and one `synth_unop` (unary `#`/`-`; `not` stays in `synth_and_or_not`). Both are
pure derivations over the operand types (read from premise `has_type` claims), keyed
**only** by the operator string and the structural operand kinds — no name-keying.
The lowering's existing `synth_expr` `binop`/`unop` arms (which currently mark every
arithmetic/concat as out-of-subset) are replaced by emission of these methods when
the operands are in the metatable-free core, and the `operator-metamethod-*` marker
otherwise. The result type for `/`,`^` is unconditional `number`; for `+,-,*,%` is
`integer`-if-both-`<:integer`-else-`number`; for `..` is `string`; for comparisons /
equality is `boolean`; for `#` is `integer`.

### 6.7.2 Module/`require` access — the M-table convention as module-type synthesis

**Value-universe derivation.** A Lua module is a *value* — the table a file `return`s.
The dominant convention (`docs/conventions.md`): `local M = {}` … `function M.f(...)`
… `return M`. The module's value type is therefore the `rec` synthesized from the
assignments to `M` (each `function M.f` / `M.f = …` adds a field). A consumer's
`local x = require("lib.y")` binds `x` to `lib.y`'s *module value type*, making
`x.f(...)` a checkable field access + call. This is the value-universe-faithful
reading: `require` returns the required file's returned value, whose type is the
M-table `rec`.

This extends the increment-2 cross-module machinery (`crescent_slice_xmodule.lua`),
which already reads a required module's *aliases* across the artifact boundary. The
extension: also synthesize and export the module's **value type** (the M-table `rec`),
alongside its aliases. The exporting file's M-table synthesis is the source; the
entry's `require` binds the result.

**The M-table synthesis rule (pure, derived).** Over the exporting module's lowered
statements, accumulate a `rec` field set:
- `local M = {}` (or `local M = { … }`) establishes the module table local and its
  initial fields.
- `function M.f(params) … end` with a `--:` signature adds field `f : fn(P, R)` (the
  signature's type). Without a signature, field `f` is added with the
  unannotated-function synthesized type (§6.7.3) — the module type reflects what
  *exists*, annotated or not.
- `M.f = <expr>` adds field `f : typeof <expr>` (synthesized).
- `return M` (or `return { f = …, … }`) fixes the module value type to the
  accumulated `rec` (closed row — a module exports exactly its assigned fields). A
  `return <table-literal>` synthesizes directly via `synth_table` (§2.3).

Only the **statically resolvable** require resolves: `require("lib.y")` /
`require "lib.y"` with a *string-literal* argument. A dynamic/computed require
(`require(var)`, `require(prefix .. name)`) stays tagged `dynamic-require` (the
existing marker), un-deferred when a corpus fixture forces it. The module-path → file
helper and the read-file cap are the increment-2 ones, reused.

**Stdlib `require`/`package` and global stdlib.** `require` *itself*, `package`, and
the stdlib globals (`string`, `math`, `table`, `tostring`, `tonumber`, `pairs`,
`ipairs`, `io`, `os`) are not module values synthesized from source — they are the
*explicit stdlib declarations* (§2.5, CLAUDE.md "No ambient globals by default";
`tonumber`/`string.sub`/`math.floor` already exist as trusted signatures in the
hand-built corpus). Decision for v1: a small, **explicit, injected stdlib-cap table**
(a `{ [name]: Ty }` of the handful the corpus's checked syntax reaches —
`tonumber`, `tostring`, `string` (a `rec` of `sub`/`format`/…), `math` (a `rec` of
`floor`/`max`/…), `pairs`/`ipairs` (already special loop forms), `table`) is bound
into the lowering's top-level Γ as ordinary `trusted_signature`-backed bindings, NOT
reached from `_G` (caps-first: the stdlib model is injected via `opts.stdlib`, never
an `io`/`_G` reach; absent the cap, these names stay `unbound-name:*`, never a silent
global). This makes `tonumber(s)`, `string.sub(s,i,j)`, `math.floor(x)` synthesize
their declared return types via the EXISTING `synth_call` + `trusted_signature`
methods — no new method. This is the §9.8 "no stdlib/global model" gap closed *as an
injected capability*, the only fence-honest way. `require` is bound as a special
form recognized by the lowering (a `require("lit")` call resolves to the module type),
not a value in Γ — because its return type is *path-dependent*, which no fixed `fn`
type expresses; the lowering resolves it at the call site (like the cross-module
import pass), recording a `cross_module_value` trust boundary.

**Mechanization surface.** No new evidence method (the M-table `rec` is a synthesized
type bound in Γ; field access + call use existing `synth_index`/`synth_call`). A new
pure `synth_module_type(exporting_lowered)` helper in `crescent_slice_xmodule.lua`
that walks the exporting file's statements and accumulates the `rec`. The lowering's
`require("lit")` recognition binds the resolved module type; the injected `opts.stdlib`
cap binds stdlib names. One new trust-boundary tag `cross_module_value` (uses the
existing `A.trust_boundary`). Substrate untouched.

### 6.7.3 Unannotated functions — synthesize params `unknown`, return from the body

**Value-universe derivation.** A function value exists whether or not it carries a
`--:` annotation. v1's §7.1 *prefers* annotations (and the kernel §5.2 measurement
keeps the annotation gap a lint concern), but the checker must type what *exists*. The
value-universe reading of a `local function f(a, b) … end` with no signature: each
parameter's type is **`unknown`** (the function makes no static promise about its
inputs — the caller-side narrowing posture: a body that uses `a` without narrowing is
itself out-of-subset, which is the correct pressure, not an error), and the return is
**synthesized from the body** (the union across `return` paths, exactly the annotated
`synth_function` return-join, but *driving* the return type rather than checking
against a declared one).

- **Params ⇒ `unknown`.** Each param binds `name : unknown` in the body Γ. This
  forces narrowing (the §1.3 `unknown` posture): a body that reads `a.field` without
  first narrowing `a` hits `synth_index` on `unknown` → out-of-subset (no field on
  `unknown`), which is the honest "this body needs an annotation to check" signal —
  NOT a soundness hole. The function still *types* (its `fn(unknown.., R)` shape is
  synthesized); the body coverage is what may fall out of subset.
- **Return ⇒ body synthesis.** The function's `R` is the union of the synthesized
  types of each `return e` (and `nil` for a fall-through path / a bare `return`),
  joined — the existing return-join logic, run in *synthesis* mode (no declared `R`
  to check against). A body with no `return` synthesizes `R = ()` (the empty return).
- **Module-boundary unannotated functions.** A `function M.f(...)` with no signature
  is the same: params `unknown`, return body-synthesized, AND the synthesized
  `fn(unknown.., R)` surfaces as field `f` in the module type (§6.7.2). The
  conventions doc says boundaries *should* be annotated; the checker still types what
  exists, and the annotation-gap measurement (kernel §5.2) stays a lint concern, not
  a checker hole.

**Why `unknown` not a fresh inference variable.** v1 has no global solving / no
parametric inference (§1.4, fenced). A fresh unification variable for an unannotated
param is precisely the global-solving the fence excludes. `unknown` is the
fence-honest choice: it is sound (the caller must narrow), it needs no solver, and it
makes the annotation pressure *visible* (an unannotated body that depends on its
param shape falls out of subset, demanding the annotation the conventions want). This
is the §10 local-inference edge resolved by the posture, not by a solver.

**Mechanization surface.** The existing `synth_function` evidence method already
checks a body against a declared `R`. For the unannotated case, the lowering binds
each param `: unknown`, lowers the body in *synthesis* mode, and joins the return
types into `R` — emitting the same `synth_function` premises but with the
lowering-computed `R` (the producer supplies `R`; the checker validates the body
checks against it, unchanged). No new evidence method; the lowering's `localfunc`/
`funcdecl` arm gains the no-signature branch (replacing the current
`unannotated-function` marker). The return-join is a pure helper.

### 6.7.4 Assignment forms — multiple assignment, swap, field/index chains

**Value-universe derivation.** Lua's assignment is a *parallel* binding of a target
list to a value list, with the multi-return tuple machinery (§6.5.5,
`fea86aa1`) supplying the width rules: the value list is flattened (the *last* value
expands to its full multi-return tuple; earlier values contribute one each), then
assigned positionally to the targets; surplus targets bind `nil`, surplus values are
dropped.

- **Multiple assignment `a, b = f()`** (already partially handled): the RHS multi-
  return `R` supplies slots positionally (`a : R.fixed[1]`, `b : R.fixed[2]`, absent
  ⇒ `nil`). The width rule generalizes to `a, b = e1, e2` (each `ei` a single value)
  and `a, b, c = e1, f()` (the *last* expression expands to its tuple; earlier
  contribute one). This is the §6.5.5 tuple-flatten rule applied to the assignment
  target list.
- **Swap `a, b = b, a`**: a pure case of the parallel rule — the RHS values are
  synthesized under the *pre-assignment* Γ (Lua evaluates the whole RHS before any
  binding), so `a, b = b, a` binds `a : typeof b`, `b : typeof a` with no temporary.
  v1's flow-insensitivity makes this trivially correct: the targets' new types are
  the RHS slot types, computed once. No special swap rule — it is the parallel rule.
- **Field/index assignment chains `t.k = v`, `t.a.b = v`, `t[i] = v`**: a *write*
  checks `v ⇐ field-type` (the existing `assign` field-write rule, §5.2,
  flow-insensitive sound treatment). The chain `t.a.b = v` synthesizes `t.a`'s type
  (an `index` read), then checks `v ⇐ (t.a).b`-field-type. An integer-literal /
  static-string dynamic key `t[1] = v` / `t["k"] = v` is a static field write
  (already handled as `index`); a *dynamic* key `t[e] = v` with a non-literal `e`
  over an `indexer(K, V)` table checks `e ⇐ K` and `v ⇐ V` (the index-signature
  write rule) — this closes the `dynamic-index-assign` marker for the
  *indexer-typed* case (e.g. `merged[k] = v` where `merged : { [string]: integer }`),
  while a dynamic key over a *closed rec* stays out-of-subset (no element type to
  check against).
- **Compound lowering.** Lua 5.1 has no `+=`; "compound" here is the multi-target /
  multi-value flatten above. No `+=` desugaring is needed (the target does not exist
  in the language).

**Width rules (pinned from the multi-return tuple machinery).** Flatten the value
list: values `1..n-1` contribute their single (multi-return-collapsed) type; value
`n` contributes its full tuple (`R.fixed` ++ vararg) if it is a multi-return call,
else its single type. Zip against the target list: target `i` gets flattened-value
`i`, or `nil` if the flattened list is shorter. This is exactly the §6.5.5 `Ret`
tuple semantics lifted to the assignment-statement target list — ONE width rule,
shared with the local-declaration multi-bind.

**Mechanization surface.** No new evidence method (assignments emit
`check_against` for field/indexer writes and bind target types in Γ; the multi-bind
draws from the existing multi-return `Ret`). The lowering's `local` (multi-name) and
`assign` (multi-target) arms gain the shared flatten-and-zip helper; the `assign` arm
gains the indexer-typed dynamic-key write branch (check `e ⇐ K`, `v ⇐ V`). The
field-chain `t.a.b = v` reuses `synth_index` for the object path. Substrate untouched.

### 6.7.5 Method calls `o:m(args)` — desugar to `o.m(o, args)`

**Value-universe derivation.** The universe makes `o:m(a)` *exactly* `o.m(o, a)` —
method-call sugar passes the receiver as the first positional argument (§6.5.2 pinned
`self` as an ordinary named first parameter for this reason). So a method call
desugars, at lowering time, to: synthesize `o`'s type, read field `m` off it
(`synth_index` → the method's `fn` type, whose first param is `self`), then a
`synth_call` with `o` prepended to the argument list. The named-`self`-param machinery
from increment 1 (§6.5.2) is consumed directly: the method's `fn` type already carries
`self : T` as `params.fixed[1]`, so the desugared call checks `o ⇐ self-param-type`
as its first argument — no `self`-specific rule.

- `o:m(a1..an)` ⇒ `synth_index(o, "m")` yields `fn((self_T, P1..Pn), R)`; the call
  checks `o ⇐ self_T` and `ai ⇐ Pi`, synthesizing `R.fixed[1]`. Identical to
  `o.m(o, a1..an)` — the desugaring is literal.
- Receiver `o` is synthesized once and its node reused for both the field-access
  object and the first argument (Lua evaluates `o` once for `o:m()`).
- A method definition `function o:m(...)` (the def side) desugars to a first
  parameter `self` — already handled as `is_method` in the lowering (currently
  marked `named-param-self`); the increment turns that marker into the actual
  `self`-prepended param binding (§6.5.2's "ordinary named first param"), so the body
  binds `self : <receiver-type>`. Since v1 does not synthesize a receiver type from
  an enclosing module (the §9.2 cross-statement-store deferral), the method def's
  `self` type comes from the `--:` signature's first param (`self: T`) when present;
  an unannotated method `self` is `unknown` (§6.7.3).

**Mechanization surface.** No new evidence method (method call = `synth_index` +
`synth_call`, both existing). The lowering's `parse_suffixed` `:` arm (currently
emitting the `method-call` out-of-subset marker) builds a desugared call node
(receiver prepended to args); `synth_call_expr` types it. The method-def `is_method`
arm prepends the `self` param binding. Substrate untouched.

### 6.7.6 Mechanization surface summary

| Item | Where | New evidence method? | Subtype change? | Substrate? |
|---|---|---|---|---|
| operator typing | lowering `binop`/`unop` arms; `synth_binop`/`synth_unop` in `crescent_slice` | `synth_binop`, `synth_unop` (pure, operand-kind-keyed) | none | none |
| module/`require` access | `synth_module_type` in `crescent_slice_xmodule`; lowering `require` recognition + injected `opts.stdlib` cap | none (reuses `synth_index`/`synth_call`/`trusted_signature`) | none | none (existing trust boundary) |
| unannotated functions | lowering `localfunc`/`funcdecl` no-sig branch + return-join helper | none (reuses `synth_function` with producer-supplied `R`) | none | none |
| assignment forms | lowering `local`/`assign` flatten-and-zip + indexer-write branch | none (reuses `check_against`) | none | none |
| method calls | lowering `:` desugar to `o.m(o, …)` | none (reuses `synth_index`+`synth_call`) | none | none |

**The fence holds.** Two new evidence methods (`synth_binop`, `synth_unop`), both pure
value-universe derivations over operand kinds — no complement, no match types, no
global solving, no HKT, no name-keying. Everything else is lowering reach over the
EXISTING methods. The metatable-dependent operator cases are out-of-subset *deferrals*
with un-defer triggers (§1.4 posture), never type-error claims. Unannotated params are
`unknown` (the fence-honest non-solver choice), not fresh inference variables. The
substrate is untouched (`init.lua` byte-for-byte), as every prior pass predicted.

---

## 6.8 Increment v2.4 — the globals model + module-value-type synthesis + unannotated closures

Status: design pass for slice **v2 increment 4**, the measured new e2e front after
increment 3 (`docs/slice-survey-v1.md` after-increment-3: `unbound-name:package` 683
files, `require` 409, `table` 324, `unannotated-closure` 393) and the **§10.4 tail**
increment 3 recorded (the `require`-returns-the-module-VALUE-type synthesis). Each
item is derived whole from the value universe and the no-ambient-globals posture
(`docs/type-system.md`; CLAUDE.md "No ambient globals by default" / "Caps-first,
everywhere"): the slice assumes NO global name is ambient — every name is a local, a
`require`, or an **explicit stdlib declaration injected as a capability**, never `_G`.

### 6.8.1 The stdlib declaration set — extend the injected cap to the corpus's demand

**Posture derivation.** Increment 3 established the injected `opts.stdlib` cap (§6.7.2):
a `{ [name]: Ty }` of stdlib names bound into the top-level Γ as ordinary
`trusted_signature`-backed bindings, NEVER reached from `_G`. Increment 4 *extends the
set* to the names the corpus's checked syntax actually reaches — the survey's
unbound-name histogram IS the demand list. The SHAPES are ported from the legacy
checker's `lib/type/static/stdlib_types.lua` (read for the shapes, NOT imported — no
legacy machinery crosses the boundary); each is expressed in the **slice grammar**.

The set added (each in the metatable-free core): `type`, `print`, `error`, `rawequal`,
`rawlen`, `collectgarbage` (precise, in-fence); `package`, `table`, `os`, `io` as
**records** (open recs + indexers — `package = { path: string, loaded: { [string]:
unknown }, ... }`; `table = { insert, remove, concat, sort, unpack, maxn }`; `os`/`io`
as **cap-shaped surfaces** the library never reaches, only the injected model
supplies); and the extended `math` (`random`/`pi`/`sin`/`log`/`pow`/`fmod`).

**Where the true type needs out-of-fence features → soundest in-fence approximation +
recorded deferral.** The slice grammar has NO generics (`forall`), NO match types, NO
meta-spread, NO intersection-overload resolution at call sites — but the legacy
signatures use all four. Each such name is declared as the **soundest in-fence
approximation** (an `unknown` where the true type would refine), recorded in §9.13 with
the precise type it should eventually have:

| Name | True type (legacy) | v1 in-fence approximation | What is lost (§9.13 deferral) |
|---|---|---|---|
| `pcall` | `<F: (...P)->R, P, R>(f: F, ...P) -> ...PcallReturn<F>` | `(function, ...unknown) -> (boolean, unknown)` | variadic generics + the `PcallReturn` match type (the `(true, ...R) \| (false, string)` shape) |
| `xpcall` | same + handler | `(function, function, ...unknown) -> (boolean, unknown)` | same |
| `assert` | `<T>(val: T, ...) -> T` | `(unknown, ...unknown) -> unknown` | the `T -> T` identity refinement (a generic) |
| `setmetatable` | `<T, MT>(T, MT) -> T & MT & { #...MT }` | `(unknown, unknown) -> unknown` | generic + intersection + meta-spread |
| `getmetatable` | `<T>(T) -> MetaOf<T>` | `(unknown) -> unknown` | the `MetaOf` match type |
| `rawget`/`rawset` | `<T>(T, k) -> Values<T> \| nil` / `-> T` | `(unknown, unknown[, unknown]) -> unknown` | the `Values<T>` match type |
| `select` | `("#" -> integer) & ((integer, ...) -> unknown)` | `(unknown, ...unknown) -> unknown` | the intersection-overload |
| `next` | `<T>(T, Keys<T> \| nil) -> (Keys<T> \| nil, Values<T> \| nil)` | `(unknown, ...unknown) -> unknown` | the `Keys`/`Values` match types |
| `unpack` | `<V>({ [integer]: V, ... }, i?, j?) -> ...V` | `(unknown, ...integer) -> unknown` | generic + the vararg-spread return |
| `string.find`/`match`/`gmatch` | `$FindReturn<P>` / `$PatternReturn<P>` | fixed `(int\|nil, int\|nil)` / `string\|nil` / `() -> ...` | the pattern-literal-driven capture arity (already a §9.8 deferral, inherited) |

`pcall`/coroutine **effect machinery stays out** (the `$Throw`/`$Catch` intrinsics and
the `thread` value kind, §1.4 fence). The approximations are **sound** — an `unknown`
result forces the caller to narrow; an over-narrow approximation would be the
violation, and there is none. `pairs`/`ipairs` remain the special loop forms (§5.2),
not values in the cap.

### 6.8.2 `require` returns the module's VALUE type — the §10.4 tail, lifted to exports

**Value-universe derivation (§6.7.2, now realized).** A Lua module is the *value* a file
`return`s; its type is the synthesized type of that returned value (the M-table `rec`
under the `local M = {} … function M.f … return M` convention). A consumer's
`local x = require("lib.y")` binds `x` to lib.y's module value type, making `x.f(...)` a
checkable cross-module field-access + call.

**M-table synthesis (the accumulation rule).** Increment 3 synthesized a module type for
the ENTRY file only when it `return`s a table literal. Increment 4 lifts this to the
real convention: as the exporting module's statements lower, each `function M.f` /
`M.f = <expr>` **accumulates** field `f` into the table-local `M`'s record (rebinding
`M` to the grown rec, most-recent-wins), and the top-level `return M` (captured at
`func_depth == 0`) fixes the module's exported value type. An annotated `function M.f`
contributes `f : fn(P, R)` (the signature); an annotated `M.f = <closure>` checks the
closure against the sig (check-mode, §6.8.3) and contributes the sig; an unannotated one
contributes `fn(unknown.., unknown)` (the module type reflects what *exists*, §6.7.3).

**Flow through the xmodule machinery, with digest records.** The module type is computed
by **recursively lowering the exporting module** within the existing acyclic-import pass
(`crescent_slice_xmodule.lua`'s cap-injected reader, §6.6) — a consumer of the
multi-artifact object model, exactly like §6.6's alias resolution, **no new substrate**.
Because each recursive lower runs its own interner generation, the module type is
computed BEFORE the entry interns anything and carried as a **portable PTy** (the
`slice_ty_arg` encoding), which the entry decodes in its own generation at the `require`
call site. The resolution rides a `cross_module_value` trust boundary (the existing
`A.trust_boundary`), with the increment-2 digest records for staleness.

**Only statically-resolvable, only `lib.`.** `require("lib.y")` / `require "lib.y"` with
a *string-literal* argument resolves; a dynamic/computed require stays `dynamic-require`
(the existing marker). A non-`lib.` path (`bit`, `ffi`) contributes no module type (it is
a trusted FFI/external boundary, not a slice-checked module). An unreadable or
out-of-subset-returning module does NOT resolve — the `require` falls through to the
ordinary unbound-name path, **never a silent success**.

**Cycles: `unknown` with a tag (honest, terminating).** A `_mod_visited` set on the
resolution stack breaks require cycles: a module already being resolved resolves to
`unknown` (the documented cyclic-require tag) — honest and terminating, the existing
visited-set discipline (§6.6.4). A depth cap bounds deep require chains (perf +
termination), the same fence-honest "wider, never unsound" posture.

### 6.8.3 Unannotated closures — check-mode closure typing (bidirectionality's move)

**Value-universe derivation.** An anonymous `function(a, b) … end` in expression position
is a function value whether or not it carries an annotation. The §6.7.3 unannotated-NAMED
rule (params `unknown`, return body-synthesized) extends to expression closures
directly — that is **synthesis mode**. The new construction is **check mode**: when the
closure *flows into an annotated slot* (a callback parameter of a known `fn` type, an
annotated `local`, an annotated `M.f = closure`), the CHECKING mode pushes the expected
fn type's **param types onto the closure params** — bidirectionality's signature move,
already the kernel's shape (the `check_against` mode-switch, §2.3), now applied to the
closure's parameter binding rather than only its return.

```text
synth_func_expr (synthesis mode):  function(a,b) … end ⇒ fn(unknown, unknown, R)
    params bind `unknown`; return R = unknown (the §6.7.3 fence-honest choice — a fresh
    inference variable would be the global solving the fence excludes; the body's returns
    check `<: unknown`, always holds; the closure value forces callers to narrow).

check_func_expr (check mode, against expected fn(P, R')):
    push P.fixed[i] onto param i (the expected param types flow inward);
    check the body's returns against R' (the declared return);
    the closure's value type is the expected fn type exactly.

check_expr (the mode switch):
    e is a `func` node AND want is an `fn` type  → check_func_expr (push params inward)
    otherwise                                    → synth(e) then subtype(synth(e), want)
```

**§6.8.3 ARITY DECISION (audit round 3, F2 fix, §9.14).** A closure with FEWER declared
params than the expected fn type is **valid Lua** — extra call args are discarded at
runtime. `check_func_expr` accepts arity-less-or-equal: it pushes only the params the
closure DECLARES (the body context is extended with exactly those params), and uses the
EXPECTED fn type `want` as the closure's fn type for the `has_type` claim (the
`fty_override` parameter of `build_closure`). This makes the substrate's
`check_against` wrapper trivially hold — `subtype(want, want)` — without requiring
`subtype(under-declared-arity, want)` which would be false. The `synth_function`
verifier does not reject because it iterates over `params_node` (the closure's declared
params), not over `pfixed`; under-declared params simply leave those param slots unbound
in the body context (they receive runtime values that are discarded). A closure with
MORE declared params than the expected type stays a rejection (`type-mismatch` marker:
`closure expects more params than the annotated type supplies`).

This is spec'd in §6.8 as **check-mode closure typing**: the bidirectional spine's
inference boundary, applied to a closure's parameters. The closure's `has_type` claim
carries `synth_function` evidence (the EXISTING method — node `t="function"` with named
params, each return a `checks_against` premise under the param-extended Γ), so the
substrate verifies it exactly as a statement func-def's body; no new evidence method.

### 6.8.4 Mechanization surface summary

| Item | Where | New evidence method? | Subtype change? | Substrate? |
|---|---|---|---|---|
| stdlib globals model | `default_stdlib()` extended in `crescent_slice_lower`; injected `opts.stdlib` cap | none (`trusted_signature` bindings in Γ) | none | none |
| `require`→module value type | `compute_module_types` (recursive lower → portable PTy) + `resolve_module_type` + `ctx_set_field` M-table accumulation in `crescent_slice_lower` | none (reuses `synth_index`/`synth_call`/`trusted_signature`) | none | none (existing trust boundary) |
| check-mode closures | `synth_func_expr`/`check_func_expr`/`check_expr` + `build_closure` in `crescent_slice_lower` | none (reuses `synth_function` with producer-supplied premises) | none | none |

**The fence holds.** ZERO new evidence methods this increment — every item is lowering
reach over the EXISTING methods (`trusted_signature` for stdlib + require boundaries,
`synth_function` for closures, `synth_index`/`synth_call` for cross-module access). No
complement, no match types, no global solving, no HKT, no name-keying. The stdlib model
is an **injected capability** (caps-first), never a `_G` reach. Unannotated closure
params/returns are `unknown` (the fence-honest non-solver choice), not fresh inference
variables. Module types flow through the EXISTING multi-artifact xmodule machinery (a
consumer, like §6.6). The substrate (`init.lua`) is **untouched**, byte-for-byte.

---

## 6.9 Increment v2.5 — the multi-return / dynamic-index statement family

Status: design pass for slice **v2 increment 5**, the measured top of the e2e
histogram after increment 4 (`docs/slice-survey-v1.md` after-increment-4:
`dynamic-index` 589 files, `multi-return` 482, `dynamic-index-assign` 477,
`multi-assign` 466). Derived whole from the value universe; the §6.5.5 `tuple`
machinery is the substrate for the multi-value items; `index_result` (§3) is the
substrate for the dynamic-index items. The headline finding first, as every
prior increment: **no substrate change.** The design pass projected zero new
evidence methods; mechanization corrected that to **exactly one** —
`synth_tuple`, the value-position dual of `synth_table`, which the multi-return
statement genuinely needs (§6.9.3, §9.15 finding 1). Every other item is lowering
reach over the EXISTING methods, plus one value-universe-justified sharpening of
the `index_result` *result* (a closed `rec` under a dynamic key).

### 6.9.1 The measured demand (diagnosed before designing)

Increment 3 (§6.7.4) already landed *basic* assignment forms — multi-assign
flatten-and-zip, indexer-typed dynamic-key writes. Yet these four tags top the
histogram. The survey records each file's lowering markers; sampling 15 real
sites per tag across the corpus (`lib/mediator`, `lib/memoize`, `lib/wire`,
`lib/dns`, `lib/websocket`, `lib/ecs`, `lib/email`, …) pins the residual
sub-shapes precisely — the tag names hide them:

- **`dynamic-index` (591 measured)** is overwhelmingly `t[expr]` *reads* — the
  EXPRESSION-position dynamic key the lowering rejects WHOLESALE (`synth_expr`'s
  `indexdyn` arm emits the marker unconditionally, never calling `index_result`).
  Real sites: `handlers[fname]`, `event_lists[fname]`, `list[i]`, `cmd_mw[i]`,
  `lru.map[key]`, `weak_cache[k]`. The objects are table-locals bound to an
  **indexer** (`{ [K]: V }`), a **rec-with-indexer**, or a **closed rec**. The
  read result is fully determined by `index_result` — which already handles
  indexer / rec-with-indexer / open-row — for every shape EXCEPT the closed rec
  under a dynamic key (§6.9.2). So the dominant gap is **the lowering never
  reaching the existing `index_result`**, plus one missing result rule.
- **`multi-return` (482)** is the `return a, b` STATEMENT — the return-position
  multi-value form. Single-return is handled; the moment a return has ≥2 values
  the lowering marks it out-of-subset (`return nil, "msg"` the error idiom,
  `return v, true`, `return node.value, true`, `return mw(...)` where the last is
  a multi-value call). The §6.5.5 `tuple` constructor and its subtype rule ALREADY
  EXIST — this item is the lowering building the joint `tuple` from the value list
  and checking/capturing it (§6.9.3).
- **`multi-assign` (466)** — the residue after increment 3 is the
  **method-call / call as the LAST RHS value** feeding a multi-target list:
  `n, err = r:uint32_be()`, `send, close = tcp_client(...)`, `code, resp =
  smtp_read_response(self._transport)`, `ok, err = self._db:execute(SCHEMA)`. The
  `flatten_values` helper spreads only a `call`-to-a-known-`fn`-local as the last
  value; it does NOT spread a **`methodcall`** (the dominant idiom) nor a call to
  a function reached by field access — those collapse to ONE slot and the second
  target binds `nil`, after which the marker fires. The fix is to spread any
  last-value whose synthesized type is a known multi-return tuple, regardless of
  the syntactic call form (§6.9.4).
- **`dynamic-index-assign` (479)** — the residue after increment 3 (indexer-typed
  writes landed) is the **closed-rec dynamic write** `t[e] = v` where `t` is a
  closed `rec` with no index signature (`parts[i] = …` where `parts` is an array
  built field-by-field, `map[victim.key] = nil`). The sound write rule is the dual
  of §6.9.2's read rule (§6.9.5).

This diagnosis IS the demand: design against the closed-rec dynamic key, the
return-statement tuple, and the methodcall-last-value spread — not against the
tag names.

### 6.9.2 Dynamic-index reads — `index_result`, lifted to expression position

**Value-universe derivation.** `t[e]` with a non-literal `e` reads one of `t`'s
values. The result is fully determined by `t`'s type:

- `t : indexer(K, V)` and `e : K' <: K` ⇒ **`V`** (the index-signature read,
  already in `index_result`).
- `t : rec_with_indexer` ⇒ **`union(field-value-types) | V`** when `e <: K`
  (**amended in audit round 4, A-F1 — see §9.17**). The original rule returned `V`
  only, which is unsound when the named fields disagree with the indexer value type:
  a dynamic key hitting a listed field yields the field's type, not the indexer `V`.
  The field union is unioned with `V` (the indexer value covers keys not matching any
  listed field); no `nil` is appended because `e <: K` means every key is covered by
  the indexer and no key can miss.
- `t : rec` **open-row** ⇒ **`unknown`** (the `...`-open-row meaning: an unlisted
  read yields `unknown` — already in `index_result`, line 452).
- `t : rec` **closed**, no index signature, dynamic key ⇒ **the union of all
  listed field value types `| nil`**. This is the universe's sound result and the
  ONLY new rule: a dynamic key may hit ANY listed field (so the value is `f1 |
  f2 | … | fn`) OR miss every field (Lua returns `nil` for an absent key, so
  `| nil`). It is NOT `unknown`: a closed rec promises NO field outside its list
  exists, so the read cannot produce a value of any other type — `union(fields) |
  nil` is strictly more precise than `unknown` and is what the closed-row promise
  earns. (For an EMPTY closed rec `{}` the union is empty, so the result is
  `nil` — every dynamic read misses.) This is the dual of the open-row rule: open
  rows admit unlisted fields ⇒ `unknown`; closed rows do not ⇒ the field union.

**Mechanization.** `index_result`'s closed-rec dynamic-key path (the `key_ty ~=
nil` branch that currently falls through to `return nil` at the closed-rec tail)
returns `G.union(field-value-types ++ { nil })`. The lowering's `synth_expr`
`indexdyn` arm STOPS emitting the marker unconditionally: it synthesizes the
object, synthesizes the key, calls `index_result(obj_ty, nil, key_ty)`, and on a
non-nil result emits a `synth_index` claim (the dynamic-key node carries the key
ref, exactly like the static-field `index` node carries the field name). A `nil`
result (object is not a table, or a truly un-indexable shape) keeps the marker —
the honest out-of-subset deferral, never a forged result.

### 6.9.3 Multi-return statement — the §6.5.5 tuple, built at the `return` site

**Value-universe derivation.** `return e1, …, en` produces the multi-value
sequence the §6.5.5 `tuple` constructor denotes. The value list flattens by the
same width rule as assignment (§6.7.4): values `1..n-1` contribute one value each
(multi-return-collapsed); value `n` spreads its full tuple when it is a
multi-return call. The joint shape is `tuple([t1, …, tn])` (with a vararg tail if
the last value spreads a vararg). Its role:

- **Top-level return** (`func_depth == 0`): the joint `tuple` becomes the module's
  exported VALUE type (§6.7.2 capture), so a consumer's `require` binding sees the
  multi-value export. The FIRST top-level return still wins.
- **Return inside an annotated function body**: the joint `tuple` is checked
  `⇐ ret_ty` via the EXISTING tuple-subtype rule (§6.5.5 — `tuple <: tuple`,
  `tuple <: union`). A declared return `(A, B) | (nil, string)` is a
  union-of-tuples; the actual `return nil, "msg"` builds `tuple([nil, lit"msg"])`
  and the union exists-forall accepts it against the `(nil, string)` member. This
  is the §6.5.5 relation's CONSUMER — the increment that motivates it (§6.5.5
  predicted "the flow-narrowing consumer follows when a fixture demands it"; the
  multi-return STATEMENT is the producer consumer it predicted).
- **Return inside an unannotated function body** (`ret_ty == nil`, synthesis
  mode): each value's claim is requested (as single-return already does); the
  synthesized function return is `unknown` (§6.7.3 fence-honest choice — no
  body-join), so the multi-value shape is not yet reflected in the synthesized
  `fn` type. Recorded as a §9.15 deferral (the body-synthesized multi-return join),
  identical in spirit to the single-return `unknown` synthesis already shipped.

**Mechanization (corrected at mechanization time — §9.15 finding 1).** The `return`
arm's `#values > 1` branch STOPS marking out-of-subset: it runs the §6.7.4
`flatten_values` helper to build the slot list and synthesizes a `tuple` Ty from the
slots. The design's first claim — "no new evidence method, reuse `check_against`" —
was WRONG and was corrected against the substrate: `check_against` requires a
`has_type` premise whose claim type IS the value being checked, and there was no
claim asserting `has_type(tuple_node, jtuple)`. The tuple is a CONSTRUCTED value
(the multi-value sequence) and, exactly like a table constructor, needs its own
SYNTHESIS rule. So the increment admits **one new evidence method, `synth_tuple`** —
the value-position dual of `synth_table`: N `has_type` premises (one per fixed
slot), the conclusion `has_type(tuple_node, G.tuple(slot-types))`. The `tuple`
constructor and its subtype rule remain §6.5.5's (untouched); `synth_tuple` only
BUILDS the tuple has_type claim the §6.5.5 relation then consumes. In check mode the
`return` arm emits a `check_against` of that tuple claim against `ret_ty` (the
declared multi-value return is threaded as the joint `tuple` Ty, not just its first
slot, so the §6.5.5 `tuple <: tuple` / `tuple <: union-of-tuples` rule fires); in
capture mode it fixes the module return type to the tuple. The
`return f()`-multi-spread (the last value spreading into ≥2 slots with no per-slot
claim) cannot meet `synth_tuple`'s per-slot-premise contract and is the §9.15
deferral (a tuple-spread-premise mechanism).

### 6.9.4 Multi-assign — spread any multi-return last value (methodcall + field-call)

**Value-universe derivation.** `a, b = <last>` binds `(a, b)` to the multi-value
sequence `<last>` produces — the §6.7.4 width rule. The producer's SYNTACTIC form
(`f()`, `o:m()`, `t.f()`) is irrelevant; only its synthesized RETURN TUPLE matters.
Increment 3's `flatten_values` keyed the spread on "the last value is a `call`
node whose `fn` is a name bound to an `fn`-typed local" — too narrow: it misses
`methodcall` (the dominant `n, err = r:uint32_be()` idiom) and a call through a
field (`a, b = mod.f()`).

**Mechanization.** `flatten_values` is generalized: for the LAST value, it
synthesizes the value's type AND recovers the producing function's `Ret` from the
synthesized expression — for a `call` via the existing fn-local lookup, and now for
a `methodcall` via the desugared method's `fn` type (the `synth_methodcall_expr`
already resolves `o.m`'s `fn`; the helper reads its `ret`), and for a `call` whose
`fn` is a field access via `synth_index`. When the recovered `Ret` has ≥2 fixed
elements, the slots spread exactly as today (slot 1 carries the call's claim id,
slots 2..n carry only the type — the §6.5.5 tuple draw). When the producer's return
is a single value (or its tuple is unrecoverable), it contributes one slot, and
surplus targets bind `nil` — the honest width rule, NOT a marker. The marker now
fires ONLY when a value is genuinely out-of-subset (synthesis returns nil), never
merely because a target outran the values.

### 6.9.5 Dynamic-index-assign over a closed rec — the write dual of §6.9.2

**Value-universe derivation.** `t[e] = v` with a closed `rec` `t` (no index
signature) and a dynamic key `e` writes `v` into one of `t`'s fields. The sound
check: `v` must be assignable to WHATEVER field the write lands on — but the key
is dynamic, so the write may target ANY field; the conservative sound obligation
is `v ⇐ union(all listed field value types)` (the write must satisfy every field
it could reach is too strong — the universe writes to exactly one, so `v` need
only be `<:` the union of what those fields admit IS NOT sound either). **Resolved
honestly:** a dynamic write into a closed rec whose fields have DIFFERENT types
cannot be soundly checked field-by-field without knowing which field — the sound
treatment is to require `v ⇐ union(field types)` AND record that the write WIDENS
the rec (any field could now hold `v`). v1 is flow-insensitive and does not mutate
a rec's field types post-hoc, so the precise widening is out of reach. The
in-fence sound choice: when all listed fields share ONE value type `V` (the common
case — an array-like or homogeneous map built field-by-field, `parts[i] = str`),
check `v ⇐ V`; when fields are heterogeneous, the write stays out-of-subset
(`dynamic-index-assign` deferral, §9.15) rather than forge an unsound
field-by-field check. The homogeneous closed-rec write is the measured common
case; the heterogeneous one is a recorded deferral with its un-defer trigger
(a rec-field-widening pass).

**Mechanization.** The `assign` arm's `indexdyn` target branch, after the existing
indexer probe fails, computes the closed-rec field-value union; if the rec is
homogeneous (one distinct field value type) it checks `v ⇐ V` (reusing
`emit_check_against`), else it marks. No new evidence method.

### 6.9.6 Mechanization surface summary

| Item | Where | New evidence method? | Subtype change? | Substrate? |
|---|---|---|---|---|
| dynamic-index read | `synth_expr` `indexdyn` arm → `index_result` (2-premise `synth_index`); closed-rec dynamic-key result in `index_result` | none (reuses `synth_index`, dynamic-key form) | none (one new RESULT rule, not a relation rule) | none |
| multi-return statement | `return` arm builds the tuple via `synth_tuple`, checks `⇐ ret_ty` / captures module type | **`synth_tuple`** (the value-position dual of `synth_table`) | none (uses §6.5.5's `tuple<:`) | none |
| multi-assign (methodcall/field-call last) | `flatten_values` generalized to recover any producer's `Ret` | none (reuses value claims) | none | none |
| dynamic-index-assign (closed rec) | `assign` `indexdyn` arm; `index_write_target` homogeneous-rec write | none (reuses `check_against`) | none | none |

**The fence holds — with ONE new evidence method, honestly admitted.** The design
first claimed zero new methods; mechanization corrected that (§9.15 finding 1): the
multi-return statement needs **`synth_tuple`**, the value-position dual of the
existing `synth_table` — N `has_type` premises build a `has_type(tuple_node,
G.tuple(...))` claim, derived from the universe (a multi-value return IS a
constructed value needing a synthesis rule, exactly as a table constructor is). It
adds no subtype relation, no constructor (the `tuple` ctor and `tuple <:` rule are
§6.5.5's, untouched), no solver. The other lattice-adjacent change is ONE new RESULT
rule in `index_result` (closed-rec dynamic key ⇒ `union(fields) | nil`) — a
sharpening of an existing function's return, the closed-row dual of the open-row
`unknown`, NOT a relation rule. The `synth_index` rule gains a 2-premise dynamic-key
form (the node grammar already declared `key?: Node`); it is the same index rule,
not a special case. Heterogeneous closed-rec dynamic writes, body-synthesized
multi-return joins, and the `return f()` multi-spread are recorded §9.15 deferrals
with un-defer triggers, never forged. No complement, no match types, no global
solving, no HKT, no name-keying. The substrate (`init.lua`) is **untouched**,
byte-for-byte.

## 6.10 Increment v2.6 — the empty-fresh-table dynamic write + the diagnose-first re-ranking of the residual family

Status: design pass for slice **v2 increment 6**, the §9.15 deferrals that gate
the histogram top after increment 5 (`dynamic-index` 512, `dynamic-index-assign`
482, `multi-assign` 450, `multi-return` 317). Derived whole; the headline finding
is itself the load-bearing result of the increment: **diagnosis contradicted the
deferrals' framing.** Per-marker corpus measurement (the increment-5 harness,
extended to report each marker's REASON, not just its tag) showed the four top
tags are dominated NOT by the named §9.15 mechanisms — those already work — but by
DOWNSTREAM expression coverage. One clean, sound, in-fence item remains in this
family; everything else is correctly re-framed as substrate gaps in OTHER families.

### 6.10.1 The measured demand (diagnosed before designing)

The harness lowered every corpus file and bucketed each top-tag marker by its
firing reason (total marker counts, not file counts):

- **`dynamic-index-assign` (3869 markers):** `wt-nil objkind=rec-EMPTY` is **2548**
  — the fresh-table build idiom `out = {}; out[k] = v` (a `pairs`-copy/merge,
  `out[render_field] = …`). The heterogeneous closed-rec write the §9.15.4 deferral
  named is **≈1 site** (essentially dead). `obj-oos` (580) and `key-oos` (452) are
  downstream object/key coverage.
- **`multi-assign` (2440 markers):** `local x,y = f(args)` where the producer fn IS
  recovered but the CALL synth-fails on an ARGUMENT (924 `prodfty=fn`) or the callee
  is `unknown`/unannotated (339 + 297 `prodfty=nil`). The multi-assign MECHANISM
  works (increment 5 landed the method-call/field-call spread); the marker fires
  because an *argument expression* or the *callee* is out-of-subset. The dominant
  residue is **argument-expression coverage**, not assignment.
- **`multi-return` (1815 markers):** `return a, b` where `flatten_values` fails on a
  VALUE (`name` 719, `binop` 605, `call` 187, `nil` 174). The return-tuple mechanism
  works; the marker fires because a *value expression* is out-of-subset. The
  `return f()` SPREAD case the §9.15.5 deferral named occurs **0 times** in the
  entire corpus.
- **`dynamic-index` read (5058 markers):** `obj-oos` (1737, the object name/index
  expr itself out-of-subset), object `unknown` (877), `key-oos` (745), and
  **`indexer keyed by a union key` (876)**. The union-key residue is, on inspection,
  overwhelmingly `union{integer, number}` (1332 of the indexer/rwi misses) — a key
  that synthesizes to `integer | number` because integer arithmetic yields `number`.
  `number </: integer`, so the access is SOUNDLY rejected; the precision gap is
  UPSTREAM (integer-preserving arithmetic), not an index rule.

**This diagnosis IS the increment's primary result.** It demonstrates the
prompt's discipline — verify, don't assume: three of the four named §9.15 deferrals
are either dead in the corpus (§9.15.5, 0 sites; §9.15.4-heterogeneous, ≈1 site) or
not the actual blocker (the multi-assign/multi-return tags are downstream coverage
symptoms). One genuine in-fence item survives.

### 6.10.2 The empty-fresh-table dynamic write — `index_write_target` over an empty closed rec

**Value-universe derivation.** `t[e] = v` where `t : rec{}` (an EMPTY closed rec,
the fresh `out = {}` local before any field is written). The rec lists NO field, so
there is **no declared element type a write could violate**. The sound write target
is therefore `unknown`: `v ⇐ unknown` rejects no correct program. It is SOUND, not
merely permissive, because the READ side is already closed off: `index_result` over
an empty closed rec returns `nil` for every dynamic read and reject/`nil` for every
static read (§6.9.2), so accepting the write can never license an unsound read. The
rec stays `{}` (v1 is flow-insensitive — no widening), which is the SEPARATE
read-side deferral, not this write's concern. This is the **WRITE dual of the
open-row rule** (open row ⇒ `unknown` write target because the element type is
hidden): an empty closed rec has no element type to constrain, exactly as an open
row hides its element type. No special case — the same "no known element type ⇒ no
constraint" principle, applied to the empty-field structural case.

**Mechanization.** `index_write_target`'s `rec` branch: when `#fields == 0` (after
the open-row check), return `G.unknown()` instead of `nil`. This is the ONLY code
change of the increment — one branch in one function. The §9.15.3 split (the
write target is its OWN function, NOT a reuse of `index_result`) is what makes this
sound and local: the READ rule still returns `nil` for the empty rec (no false
reads), while the WRITE rule returns `unknown` (accepts the write). Heterogeneous
closed recs still return `nil` (re-deferred, §9.16 — ≈1 corpus site).

### 6.10.3 The three named deferrals — verdicts against the corpus

- **§9.15.4 (heterogeneous/EMPTY closed-rec write) — SPLIT and PARTIALLY CLOSED.**
  The corpus showed the deferral was 2548-EMPTY / ≈1-heterogeneous. The EMPTY case is
  **implemented** (§6.10.2) — its un-defer trigger ("rec-field-widening") was wrong:
  no widening is needed, because `unknown` is the sound write target under
  flow-insensitivity. The HETEROGENEOUS case is **re-deferred** (§9.16) with the same
  trigger, now noted as essentially dead (≈1 site).
- **§9.15.5 (`return f()` multi-spread) — RE-DEFERRED, zero corpus demand.** The
  bare-spread `return f()` form occurs **0 times** across 867 corpus files; the
  per-value `return a, b` form (in-subset since increment 5) is universal. Recorded
  in §9.16 as a dead deferral — un-defer ONLY if a real site appears.
- **§9.15.6 (body-synthesized multi-return join) — RE-DEFERRED, behind the shared
  pass.** Unchanged: an unannotated multi-return body still synthesizes `unknown`,
  behind the same local-return-type-collection pass the §6.8 closure-return join
  waits on. Not a top-tag blocker (the top tags are downstream coverage, §6.10.1).

### 6.10.4 Mechanization surface summary

| Item | Where | New evidence method? | Subtype change? | Substrate? |
|---|---|---|---|---|
| empty-fresh-table dynamic write | `index_write_target` `rec` branch: `#fields == 0 ⇒ unknown` | none (reuses `check_against`) | none (one RESULT rule, the write dual of open-row) | none |

**The fence holds — one branch, zero new methods.** No new evidence method, no
subtype-relation change, no constructor, no solver. The single change is one RESULT
rule in `index_write_target` (empty closed rec ⇒ `unknown` write target), the write
dual of the open-row rule, sound because the empty-rec READ rule admits nothing. The
diagnosis is the increment's load-bearing finding: the top tags are dominated by
downstream coverage (argument-expression, value-expression, integer-preserving
arithmetic) and by a deferral whose real shape (empty) the corpus re-ranked away
from its named shape (heterogeneous). No complement, no match types, no global
solving, no name-keying. The substrate (`init.lua`) is **untouched**, byte-for-byte.

## 6.11 Increment v2.7 — field-path narrowing (the §9.8 deferral, soundness boundary explicit)

Status: design pass for slice **v2 increment 7**. This un-defers the §9.8
field-path-narrowing deferral whose trigger fired three times: the coinductive
fixture's FINDINGS verdict (§9.8, `if node.left then tree_sum(node.left)`),
increment-4's cross-module boundary, and **all 11** of audit round 4's
false-positive files (`docs/artifacts/typechecker-run-2026-06-12/audit-round-4.md`,
§9.17). Derived whole; the soundness boundary — *when a path refinement dies* — is
the load-bearing design content, made executable as the invalidation test fence.

### 6.11.1 The value-universe derivation (what a path refinement is)

v1's flow layer (§4) narrows a *variable binding*: a guard refines `x`'s entry in Γ,
and a downstream occurrence of `x` synthesizes under the refined Γ. A **path** `x.f`
is not a binding — it is a *read* through `x`. Narrowing `x.f` means: after a guard
proves `x.f` is non-`nil` (or a specific kind), a later read `x.f` synthesizes the
refined type instead of re-reading the declared field type.

**The key derivation: a path is an opaque refinement-target NAME.** The pure
refinement function `NAR.refine(guard, x, T)` (slice_narrow.lua) matches its target
`x` by *string equality* — it never inspects `x`'s structure. So a path `"x.f"` is a
valid refinement target with **zero changes to the narrowing core, the `Guard`
grammar, or the `narrow_guard` evidence method**: the refined "variable" is the path
string `"x.f"`, its pre-guard type is `index_result(typeof x, f)`, and the refinement
binds `"x.f" : T_true` as an ordinary (synthetic-named) Γ entry. A downstream read
`x.f` consults Γ for the path binding `"x.f"` before computing `index_result`. The
path is to the field-read what the variable name is to the var-read.

**Depth bound: 1 (`x.f`), justified by the corpus.** The round-4 false-positive
samples are uniformly depth-1: `opts_t.title`, `opts_t.description` (rehype_meta,
12 sites), `node.left`/`node.right` (coinductive), `node.children`/`node.value`
(rehype_infer_title), `task_inputs[k]` field reads (agent/render). The two depth-2
reads in the corpus (`root.data.title`, `ast.data.title`) are *not* guard-narrowed —
they are unconditional writes through a `--[[:!]]`-cast local, not a narrowing site.
Depth-2 (`x.f.g`) is therefore **deferred with a trigger** (a real guarded `x.f.g`
read appears): it is a strictly additive extension (a longer path string, the same
opaque-name machinery), recorded §9.18, never forged.

### 6.11.2 The invalidation rule — the soundness boundary (EXPLICIT)

Narrowing `x.f` is sound only while *nothing can have mutated the path* since the
guard. A variable refinement is immune to this (re-binding `x` shadows the
refinement, the lowering already handles it); a path refinement is **fragile** —
`x.f` can change without `x` changing, through `x.f = …`, through a write to an
*alias* of `x`, or through a *call* that holds `x` (by argument or upvalue) and
mutates `x.f`. Crescent is soundness-first (docs/type-system.md): no TS-style
pragmatic unsoundness. The rule is derived from the value universe *without* escape
or effect analysis (v1 has neither), so it is the **sound-conservative rule**:

> **A path refinement `x.f` dies (the binding is dropped, the read falls back to the
> declared field type) after any statement that can mutate the path or alias the
> base. Concretely, within the refined block, the refinement is invalidated by:**
>
> 1. **any function or method call** (statement-position, or inside an assignment
>    RHS / condition) — a call may receive the base `x` by reference and mutate
>    `x.f`, or reach `x` through an upvalue/global and mutate it. v1 has no
>    purity/effect knowledge, so **any call invalidates** mutable-base path
>    refinements;
> 2. **any assignment** — base reassignment `x = …`; write-through any field of the
>    base `x.f = …` / `x.g = …`; dynamic write `x[e] = …`; **and a write through
>    ANY lvalue** `y.h = …` / `y[e] = …` (aliasing is undecidable in v1: `y` could
>    be `x`, per §6.11.3).

**Why no narrower rule is justifiable WITHOUT escape analysis.** A narrower rule
("only calls that *reach* `x` invalidate") requires knowing a call's argument/upvalue
reach — escape analysis the slice does not have. A "writes only to the *named* base"
rule is unsound under aliasing (§6.11.3). The honest position: take the conservative
rule, record the imprecision, and un-defer toward a purity/effects substrate
(`docs/effects.md`) — when the slice can prove a callee pure and a base un-escaped,
the call-invalidation relaxes. Recorded §9.18 with that trigger.

**Readonly fields survive calls and writes — justified.** The grammar carries a
`readonly` field marker (`{ key, ty, optional, readonly }`). A `readonly` field
*cannot be reassigned through any alias* — that is exactly what the marker means in
the value universe ("no write can occur to this field"). So a readonly path
refinement is immune to both call-invalidation and write-invalidation: no call and no
write, through any alias, can change a readonly field. This is not a special case —
it is the direct value-universe reading of the readonly marker, the same reading that
makes readonly fields covariant where mutable fields are invariant (§9.2). A readonly
path refinement therefore survives the whole block. (The corpus's narrowed paths are
mutable record fields, so this is a soundness-completeness statement, not a corpus
demand; it is the principled boundary, recorded as such.)

**Granularity: statement-level, invalidate-AFTER.** The refinement is dropped
*after* the invalidating statement's claims are lowered, never before. This is the
load-bearing soundness-AND-precision point: in `if node.left then s = s +
tree_sum(node.left) end`, the body is one assignment whose RHS calls
`tree_sum(node.left)`. The path read `node.left` is synthesized as the call argument
*within* that statement — it reads `T_true = TreeNode` *before* the call's
invalidation applies to subsequent statements. The read happens-before the call;
the invalidation governs the *next* statement. Statement-granular invalidate-after is
both sound (the call cannot have run when the argument is typed) and precise enough to
type the guarded read (the dominant idiom: guard, then immediately use in a call).

### 6.11.3 Aliasing — the worked example (why "any write-through-any-lvalue")

```lua
--:: Node = { f: integer | nil }
--: (Node) -> integer
local function g(x)
  local y = x            -- y aliases x (same table)
  if x.f then            -- refine x.f : integer (drop nil)
    y.f = nil            -- writes x.f THROUGH the alias y — x.f is now nil!
    return x.f           -- UNSOUND if x.f still read as integer
  end
  return 0
end
```

`local y = x` makes `y` and `x` the **same table**; `y.f = nil` mutates `x.f`. A rule
that invalidated only writes to the *syntactic* base (`x.f = …`) would miss this and
read `x.f` as `integer` at the `return`, accepting an unsound program (the value is
`nil`). The conservative rule — **any write through any field/index lvalue
invalidates all path refinements** — covers it: `y.f = nil` is a write-through-an-
lvalue, so it drops the `x.f` refinement, and `return x.f` re-reads the declared
`integer | nil`, correctly *rejecting* the `-> integer` annotation. v1 cannot decide
`y == x`, so it must assume it; the alias case is subsumed by the call/write
conservative rule, no alias analysis required. (The same statement is *also* a
write — covered by clause 2 — and the worked example is the executable invalidation
test `path_refinement_dies_after_alias_write`.)

### 6.11.4 Interaction with μ / unions (the coinductive fixture's exact shape)

`node : TreeNode` where `TreeNode = μX. { value: integer, left: X | nil, right: X |
nil }`. The path `node.left` synthesizes via `index_result(TreeNode, "left")`. The
existing `index_result` rule unfolds the μ once (equirecursive) and reads the `left`
field: `TreeNode | nil`. The guard `if node.left then` refines the *path*
`"node.left"` by the truthy decomposition (§4.1, `refine_truthy`): drop the `nil`
member → `TreeNode`. This is **exactly** the existing variable-truthy refinement,
applied to the path's synthesized type — no μ-specific machinery. The path-refinement
applies to the *unfolded view* (the field read already unfolded), consistent with the
tag-discriminant μ-unfold (§6.2): both read a field of a μ-typed value by unfolding
once, then narrow the result positively. `tree_sum(node.left)` then synthesizes
`node.left : TreeNode` (from the path binding) and checks `TreeNode <: TreeNode` →
accepts. The fixture moves FINDINGS → CLEAN.

### 6.11.5 Mechanization surface

Refinements stay **derived claims** — a path narrowing is a `narrows` claim with
`narrow_guard` evidence, identical to a variable narrowing, because the path is an
opaque target name (§6.11.1). The narrowing CORE (slice_narrow.lua) and the
`narrow_guard` evidence method (crescent_slice.lua) are **byte-for-byte unchanged**.
The substrate (`init.lua`) is **untouched**. The changes are at three seams:

| Item | Where | New evidence method? | Subtype change? | Substrate? |
|---|---|---|---|---|
| recognize `x.f` as a guard target path | `recognize_guard`/`recognize_cmp` (`crescent_slice_parse.lua`): a `truthy`/`nil_eq`/`lit_eq` guard whose target is an `index`-over-`var` carries `var = "x.f"` (the path string) | none | none | none |
| path pre-type + binding + invalidation | `crescent_slice_lower.lua` `if`/`lower_block`: synth `index_result(typeof x, f)`, bind `"x.f" : T_true` in body Γ, drop path bindings after invalidating statements | none (reuses `emit_narrows`/`narrow_guard`) | none | none |
| read `x.f` consults the path binding | `synth_index_expr` (`crescent_slice_lower.lua`): `ctx_get(ctx, base.."."..field)` before `index_result` | none | none | none |

The invalidation points are **emitted by the lowering** (the design's clause: drop
the path binding from the block Γ after an invalidating statement); the refinement
itself remains a visible `narrows` claim. No complement, no match types, no global
solving, no escape analysis, no name-keying — the path is a string name threaded
through the existing variable-narrowing machinery, and the soundness boundary is the
lowering's invalidation discipline, fenced executably by the §9.18 invalidation
tests.

## 6.12 Increment v2.8 — dependency-ordered alias declaration (forward-sibling refs)

Status: design pass for slice **v2 increment 8**. This un-defers the §9.8 / §9.11
two-phase-alias deferral ("forward/mutual alias references require two-phase
name-installation-then-parse"), whose trigger has now FIRED with measured demand.

### 6.12.1 The measured demand (diagnose-first)

Both frontiers re-measured against HEAD `9f396092`. The PRECISION frontier (the 16
e2e CHECKED-FINDINGS files) holds two concrete, deterministic alias-resolution gaps
its first diagnostics name: `lib/socket/init.lua` carries an `xmodule-alias-error`
(`server_socket`'s body names `server_client`, declared LATER), and
`lib/tcp/client.lua` carries one too (via `lib/ljsocket`). Probing the whole corpus
for the FORM — an alias whose body names a SIBLING alias declared later in the same
batch — found **154 forward-sibling references across 29 files**, split by a cycle
test into:

- **63 PURE-FORWARD (acyclic) references across 16 files** — aliases declared out of
  dependency order with NO cycle (`server_socket → server_client`; the
  `Expr = ExprCall | ExprNeg | …` parent-union family where the members sit below the
  union; `DiceNode`/`NegNode`, `HamtNode`/`HamtInterior`, `Block`/`Func`, …). These
  are the increment's target.
- **55 CYCLIC (mutual) references across 21 files** — genuine mutually-recursive
  families (`A` body names `B`, `B` body names `A`). A single-binder equirecursive μ
  (slice_ty's μ is de Bruijn, one binder) cannot express a multi-equation family;
  this is a substrate gap, deferred honestly (§9.19).

This ranked FIRST over the coverage frontier's top forms (`dynamic-index` 510,
`multi-assign` 452, `multi-return` 317 — each a major statement-lowering undertaking
whose residue increments 5/6 already traced to upstream precision) on the
soundness-value × demand product: it is a PRECISION fix (it converts an honest
forward-reference ERROR into the CORRECT resolved type — never a wrong type), it is
the literal §9.8/§9.11 named deferral, and it clears the largest *named* precision
form measured. A competing precision candidate — the tuple type `{ A, B }`
(`ljsocket`'s `timeout_connected`) — has ≈1 corpus site and is deferred (§9.19).

### 6.12.2 The derived whole (no special-casing)

Source order is just ONE valid order: it resolves a BACKWARD reference (a later alias
naming an earlier one) but not a FORWARD one. The strictly-correct generalization is
to declare each alias AFTER the siblings it references — a **topological order over
the intra-batch dependency graph**. This is pure graph topology, not a name-keyed
handler:

1. **Edge set.** For each alias decl, its body's standalone-identifier tokens that
   name another decl in the SAME batch (excluding self — a self-reference is already
   bound by `declare_alias`'s μ placeholder, §6.11/§9.7, so it is NOT a batch edge).
2. **Order.** DFS post-order with on-stack cycle detection. A back-edge (a dependency
   currently on the DFS stack) is NOT recursed through, so a cycle member keeps its
   source position. Independent aliases tie-break on source order, so a batch with no
   forward references reproduces today's declaration order byte-for-byte.
3. **Declaration.** Declare in that order via the unchanged per-alias `declare_alias`
   (μ for self-recursion, well-formedness gate, `(nil, errmsg)` on failure). Failures
   are attributed back to the SOURCE LINE via an input-index ↔ line map, so a marker
   still points at the right place under the reorder.

`declare_alias` itself is **byte-for-byte unchanged** — the same load-bearing pattern
as §6.11 (the change is the ORDER aliases are fed to it, not the per-alias machinery).

### 6.12.3 The soundness boundary — the cyclic family stays an honest error

A genuine mutual cycle (`A ↔ B`) cannot be broken by ordering: whichever member is
declared first names a not-yet-present sibling and errors, exactly as today. The
dependency-ordering pass therefore NEVER silently binds a cyclic family to a wrong
type — it produces the SAME honest forward-reference error. This is the executable
fence (a `declare_aliases_ordered` test asserts `A ↔ B` errors honestly, NOT
resolves). The principled fix for cyclic families is a **multi-binder μ** (a system of
mutually-recursive type equations), a slice_ty substrate gap recorded §9.19 with the
now-measured trigger (55 refs / 21 files), never hardcoded.

### 6.12.4 Mechanization surface

Three seams, mirroring the import/scan split:

| Seam | File | Change |
|---|---|---|
| Order + batch-declare | `crescent_slice_parse.lua` | `alias_decl_order(decls)` (pure topo) + `declare_aliases_ordered(env, decls)` (declare in that order, per-input-index results) |
| In-file aliases | `crescent_slice_lower.lua` | `scan_source` COLLECTS alias decls (with source line), then batch-declares in dependency order; failure markers attributed by line |
| Cross-module aliases | `crescent_slice_xmodule.lua` | `import_top_level_aliases` collects this module's batch and installs in `alias_decl_order`; the F1 cross-exporter collision check is unaffected by intra-module reordering |

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
with large headroom on the worst query (`docs/perf/log.md`, 2026-06-12 entries); the
153 prior analysis assertions are intact (full suite 4607). `bin/cr check` is clean
on every new file. Findings recorded in §9.3.

> **NOTE (audit round 1, finding 4, §9.7).** Pass 1's bench did NOT include a
> shared-subterm DAG, and the relation was exponential on that shape (`{ a: child,
> b: child }` chains — >120s at depth 30). The original "~20000× headroom on the
> worst query" claim was therefore **measured on too narrow a shape set**. The fix
> adds per-query memoization and the DAG shape to the bench; the corrected
> headroom numbers are in the audit-round-1 perf-log entry (the depth-30 DAG query
> drops from unmeasurable to ~0.007 ms/query). See §9.7 finding 4.

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

**Pass 5 — The statement-lowering frontend (source text → claim/evidence graph). ✅ DONE (2026-06-12).**
The survey pass (§10.1, `docs/slice-survey-v1.md`) honestly exposed that the corpus
fixtures were validated via *hand-built* derivations: the §5 syntax subset was
specced but never wired from source text. Pass 5 closes that — the missing driver
that turns a real Lua source file into the slice's artifact + claim/evidence graph
end-to-end. `lib/type/analysis/crescent_slice_lower.lua`: given (source, filename)
it produces (state, requested claims, observations, expected-verdict, markers) ready
for the substrate's `CheckRequest`. Scope is exactly §5's subset (local decls with
`--:`, function defs, calls/multi-returns, table constructors, field/index
access+assign, if/elseif with the five guard forms incl. post-guard fall-through
narrowing, for-in pairs/ipairs, numeric-for, while/repeat, `--::` aliases,
checked/force casts). Out-of-subset statements emit a **construct-tagged marker**
(consistent with the survey's tags) — never a silent skip (silent skips manufacture
false CLEAN verdicts).

*Mechanized:* `lib/type/analysis/crescent_slice_lower.lua` (a self-contained §5
statement lexer + recursive-descent parser producing the slice node grammar
DIRECTLY, plus the lowering pass that walks it under a typing context and emits
claims targeting the EXISTING evidence methods — no new method added; reuses
`parse_type_ann`/`declare_alias`/`recognize_guard` from the adapter),
`lib/type/analysis/corpus_lower_test.lua` (70 assertions: all 11 fixtures
source-text → lower → substrate check → verdict), and the end-to-end survey mode
(`slice_survey.lua --e2e`, `M.run_e2e`/`survey_file_e2e`).

**Parser-reuse decision (the prompt required this explicitly):** the production Lua
parser `lib/type/static/parse.lua` is **NOT reused**. It emits flat bit-packed
`ASTNode` records into an FFI arena keyed by `defs`/`intern`/`lex`, and carries
`--:`/`--::` annotations on a SEPARATE comment stream — consuming it read-only would
import all of that coupling for a syntax subset far smaller than full Lua. The
low-coupling choice (CLAUDE.md "Keep coupling low") is a focused statement
lexer+parser in the slice namespace. No legacy checker semantics enter; only §5
syntax is reproduced.

**The fixture finding (the point of the pass).** Under real lowering, **2 of 11**
fixtures are CLEAN (`local_return_narrowing`, `union_alias_over_named_types`); the
other **9 are OUT-OF-SUBSET** — and *every* in-subset claim the lowering emits
ACCEPTS (0 rejections, 0 unknowns, 0 diagnostics across all 11). The divergence
from the hand-built corpus_test is the rung's data: the hand-built graphs silently
**assumed away** exactly the §5 boundaries real source hits — stdlib calls
(`tonumber`/`string.sub`/`math.floor`/`pairs`), arithmetic/concat operators
(`1/n`, `s+v`, `..`), named parameters (`node: HamtNode`), `t[e] = v` dynamic-key
writes, unannotated closures, and field-path narrowing (`if node.left then`). Each
is a real §5 deferral (§1.4 / §7.1), traced to root cause in §9.8 — none is a
checker soundness gap. The hand-built `corpus_test.lua` is retained as a unit test
of the evidence methods (it asserts they accept the IDEALIZED graph); the
load-bearing corpus assertion is now the lowered path. Findings in §9.8.

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

  > **CORRECTED by audit round 1, finding 1 (§9.7).** Pass 2 only *half*-enforced
  > this: contractiveness gated `well_typed_type` but **nothing called it** on the
  > types entering `subtype_witness`, `has_type`/`checks_against`,
  > `instantiate_witness`, or `declare_alias`. A non-contractive μ reachable from
  > plain annotation syntax (`--:: T = number | T`) therefore still read as top in
  > the relation and type-checked unsoundly. The fix makes well-formedness a HARD
  > PRECONDITION at every type-consuming evidence-method entry (reject with a
  > diagnostic) and in `declare_alias` (return `(nil, errmsg)`). The audit also
  > settled the degenerate non-occurring-binder case (`μX.never`, `μX.number`):
  > rejected as ill-formed — a binder that never occurs denotes its body verbatim
  > and should be written as the body. See §9.7 finding 1.

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

- **`type(x) == "<name>"` member-matching must enumerate the literal SUBKINDS.**
  §4.1's `type(x) == "string"` truthy = "the `string` member of the union `T`."
  Mechanization found "the string member" is really "every union member whose
  runtime `type()` is `"string"`" — which includes `lit_str` singletons, and for
  `"number"` includes `integer`/`lit_int`/`lit_num`, for `"table"` includes
  `rec`/`rec_with_indexer`/`indexer`, etc. (the §1 subkind lattice surfacing in
  narrowing).

  > **CORRECTED by audit round 1, finding 3 (§9.7).** This finding originally also
  > claimed an `unknown` member is "NOT matched and NOT dropped — it stays via the
  > falsy sound-wider T." That was **wrong** and produced a soundness-adjacent
  > wrong-rejection: narrowing a bare `unknown` by `type(x)=="string"` collapsed the
  > truthy branch to `never` (no member matched), breaking the canonical TS-`unknown`
  > idiom `if type(x)=="string" then x:upper() end`. The correct rule is the general
  > one: truthy narrowing is `T ∩ positive`, decomposed per member as `member ∩
  > positive`. A member that *proves* the runtime type contributes itself; a member
  > the guard *cannot exclude* — `unknown`, the top — contributes the positive set
  > itself (`unknown ∩ string = string`). It is NOT an `unknown` special case; it is
  > the intersection rule, of which `keep_members` is the all-or-nothing instance.
  > See §9.7 finding 3.

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

### 9.7 Adversarial audit — round 1 (post-mechanization)

After all four mechanization passes landed, the slice was subjected to an
adversarial audit: an attacker constructed execution repros probing for soundness
holes, wrong rejections, and termination failures. **Five confirmed findings** were
reproduced by execution and fixed; each is now a permanent regression test
(`crescent_slice_test.lua`, the "audit round 1" describe blocks). Recorded honestly
per the prompt — including the prior sections' claims this audit FALSIFIED, and the
*survivals* (attacks that found nothing), because a survival is evidence too.

**The five findings (what was wrong, and the fix):**

1. **Well-formedness was not a precondition anywhere load-bearing (blocking,
   unsound).** §9.3 recorded contractiveness as a precondition of `well_typed_type`,
   but Pass 2 only *half*-enforced it: NOTHING gated the types entering
   `subtype_witness`, `has_type`/`checks_against`, `instantiate_witness`, or
   `declare_alias` through `TA.well_formed`. A non-contractive μ reachable from
   plain annotation syntax (`--:: T = number | T`, also `T = T?`, `T = T`) read as
   **top** in the cycle-guarded relation, so `subtype(string, μX.(number|X))` was
   accepted and `checks_against` let a string value type-check against a number
   type. **Fix:** well-formedness is now a HARD PRECONDITION at every type-consuming
   evidence-method entry (reject with a diagnostic; gated at claim/method entry, not
   inside the relation's recursion — the §9.3 performance note), AND `declare_alias`
   validates and returns `(nil, errmsg)` per convention. The latent degenerate case
   — a μ whose binder never occurs (`μX.never`, `μX.number`) — is **decided:
   rejected as ill-formed** (it denotes its body verbatim; write the body directly;
   the interner cannot normalize it away because `mu_raw` interns before
   well-formedness runs, so the gate is the right place to reject). This corrects
   §9.3's "Pass 2's `type_shape_check` must enforce" — it specifies the obligation
   but did not wire it to the load-bearing entry points.

2. **`lit_int` accepted non-integers and collided interner keys (blocking, unsound,
   codec-only reach).** `decode({k="lit_int", n=3.5})` succeeded, and `G.lit_int(3.5)`
   interned to the SAME tid as `lit_int(3)` via the old `string.format("%d", …)` key
   (which truncated `3.5 → "3"`), making `lit_int(3.5) <: lit_int(3)` and
   `lit_int(3.5) <: integer` both wrongly true. **Fix:** integer-valuedness is
   validated in BOTH the `lit_int` constructor (returns `(nil, errmsg)` on a
   non-integer) and the decoder (rejects → decode failure, parse-not-cast); the key
   is now `%.17g` (exact double value, never a truncation). The **2^53 boundary** is
   documented in the tests as the decided behavior: integers beyond 2^53 are not
   separately representable as doubles, so `lit_int(2^53)` and `lit_int(2^53+1)`
   share a tid — a fundamental IEEE-754 limitation, not a bug; both are integer-
   valued and well-formed.

3. **Narrowing `unknown` via `type_eq`/`tag_eq` truthy yielded `never`
   (wrong-rejection).** `keep_members` dropped the `unknown` member, collapsing the
   canonical idiom `if type(x)=="string" then x:upper() end` (over `x : unknown`) to
   an uninhabitable branch. (`lit_eq` did NOT have this bug — it reasons via
   `lit <: T`.) **Fix:** the guard forms are unified under the general rule —
   truthy refinement is `T ∩ positive`, decomposed per member as `member ∩ positive`:
   a member that *proves* the guard contributes itself; a member the guard *cannot
   exclude* (`unknown`, the top) contributes the positive set itself
   (`type_eq "string"` → `string`; `tag_eq "leaf"` → the open rec `{ tag: "leaf",
   ... }`, expressible in the v1 grammar). `keep_members` is the all-or-nothing
   instance of this; the `unknown` case is NOT special-cased. This corrects §9.5's
   wrong "unknown is NOT matched and stays via the falsy T" claim (annotated inline
   in §9.5).

4. **`subtype` exponential on shared-subterm DAGs (hang).** The `seen` set covered
   only μ-unfold pairs; rec/union/fn descent re-explored shared interned subterms —
   O(2^n), >120s at depth 30 on `{ a: child, b: child }` chains. **Fix:** per-query
   memoization covering ALL constructor descents (interned tid-pairs are a trivial,
   sound key). The coinductive correctness argument is preserved — an in-progress μ
   pair short-circuits via the coinductive hypothesis BEFORE the memo write, so a
   provisional `true` is never cached; only fully-decided pairs are memoized. The
   contravariant-recursion / memo-poisoning tests (which the audit confirmed survive)
   guard this. The DAG shape was added to `slice_subtype_bench.lua`, the full bench
   re-run, `docs/perf/log.md` updated (depth-30 DAG: unmeasurable → ~0.007 ms/query),
   and §5.1/§7.2/§8's "~20000× headroom on the worst query" claim corrected (it was
   measured on too narrow a shape set — annotated inline in §8).

5. **`instantiate_witness` never bound G to the callee (spec-gap, soundness-
   relevant).** `payload.generic` came straight from the untrusted producer; a
   fabricated generic gave any call any return type — the real callee's type was
   never consulted. **Fix:** per §2.4's stated input, the `has_type(Γ, f_node, G)`
   premise is now REQUIRED as the first input, and the payload's portable G must
   structurally equal that premise's asserted type (compared via `A._serialize` on
   the raw PTy — the generic carries free tyvars, which do not intern, so the
   premise rides a `trusted_signature` whose raw `type` arg is the generic; the
   `trusted_signature` method is now handled before the type-decode preamble so an
   un-decodable generic can ride a trusted has_type claim). A fabricated or
   mismatched generic is rejected. This corrects §9.4's account (which framed G as
   payload-only with no binding obligation to the callee).

**Survivals (attacks that found nothing — evidence too):**

- **Record-field covariance unsoundness is unreachable within v1 syntax.** The
  §9.2 mutable-field-invariance gap (fields treated covariantly) was probed; it
  remains *unreachable* in v1's checked syntax (no fixture writes through a widened
  field alias), so the audit did not disprove the §9.2 fencing — it stands.
- **Memo-poisoning withstood.** After adding memoization (finding 4), the attacker
  probed for a coinductive result poisoned by a cached provisional `true`; the
  contravariant-recursion and equirecursive-μ tests stayed green, confirming only
  non-provisional verdicts are cached.
- **Codec contractiveness held except the gated entry points.** The portable codec
  faithfully round-trips contractiveness; the hole was purely the *missing gate
  calls* (finding 1), not a codec defect.
- **Parser guard recognition — no false positives.** `recognize_guard` was probed
  with non-guard comparisons (`x < 0`) and malformed shapes; it correctly returned
  `nil` (no spurious narrowing), so no wrong narrow entered from the frontend.

**What buckled in the substrate during the audit fixes: nothing** — every fix is in
the slice modules (`slice_ty`, `slice_ty_arg`, `slice_subtype`, `slice_narrow`,
`crescent_slice`, `crescent_slice_parse`); `init.lua` is still byte-for-byte
unchanged. The full suite is green at 4789 + the audit regression assertions; the two
prior `instantiate_witness` tests were updated to supply the now-required callee
premise (they asserted accept/reject behavior that the finding-5 fix re-grounds on
the callee's true type — called out in the commit message).

### 9.8 Mechanization findings — Pass 5 (the statement-lowering frontend)

**The lowering is sound; the divergence is at the §5 boundary, not in the checker.**
Across all 11 fixtures driven source-text → lower → substrate check, the substrate
ACCEPTS every claim the lowering emits — 0 rejections, 0 unknowns, 0 diagnostics.
The lowering only emits a claim after it has itself verified the form is in-subset
and the subtype/narrow obligation holds; anything else becomes a construct-tagged
marker. So the honest split (2 CLEAN, 9 OUT-OF-SUBSET) is purely a *coverage* fact
about §5's statement subset, not a precision or soundness fact about the checker.

**Per-fixture divergence from the hand-built corpus_test, each chased to root.**

- `boolean_narrowing` → OUT-OF-SUBSET on `operator-arith` (`1 / n < 0`). v1 has no
  numeric-operator synth rule (§1.4 metamethod deferral). The hand-built graph used
  a pre-typed `b : boolean` instead of the division — assuming the operator away.
- `tonumber_return_type` → OUT-OF-SUBSET on `unbound-name:tonumber/string/math`.
  The hand-built graph injected trusted stdlib signatures; real lowering has no
  stdlib/global model (caps-first: globals are not ambient, CLAUDE.md).
- `pairs_return_leak` → OUT-OF-SUBSET on `dynamic-index-assign` (`merged[k] = v`)
  and `operator-arith` (`s + v`). The `for _, v in pairs(t)` loop-var binding DID
  lower and accept (the in-subset part works); the leak vanishes by construction.
- `coinductive_recursive_types` → OUT-OF-SUBSET on field-path narrowing
  (`if node.left then`) + `+`. v1's narrowing refines a *variable* binding (§4); a
  field-PATH guard (`node.left`) needs path narrowing v1 does not have. Without it,
  `tree_sum(node.left)` legitimately fails `TreeNode|nil <: TreeNode` — an honest
  type-mismatch marker, not a bug.
- `table_construction_widening` → OUT-OF-SUBSET on `dynamic-index-assign`
  (`insns[1] = {...}`). §5.1's write-checking is the static-field form; the
  integer-dynamic-key write needs a premise the 1-form rule lacks.
- `hamt_recursion` → OUT-OF-SUBSET on `named-param` (`node: HamtNode`) and a
  forward-referenced alias (`Interior` references `HamtNode` before its declaration;
  the per-file alias env is built top-to-bottom, so the μ is only formed at
  `HamtNode`'s own line). Both are real v1 deferrals (named params are the survey's
  #1 demand; forward aliases need a two-pass alias env).
- `cast_not_inference_source` → OUT-OF-SUBSET on `operator-concat`
  (`tostring(n) .. ":"`) + unbound `tostring`.
- `cross_module_type_alias` → OUT-OF-SUBSET on `named-param`
  (`cb: () -> nil, epoll: Epoll | nil`).
- `closure_param_typing` → OUT-OF-SUBSET on `unannotated-closure` (the inner
  `function(s) ... end` lambdas). v1 function *synthesis* requires a declared `fn`
  type (§7.1); an unannotated closure in expression position is the §10
  local-inference edge.

**Post-guard fall-through narrowing was the one lowering mechanism Pass 5 had to
build** to make `local_return_narrowing` CLEAN: `if not task then return end`
narrows the *rest of the block* by the guard's FALSY refinement (the §6.1 worked
example, step 3). The lowering detects a single-clause `if` whose body
unconditionally exits and applies `narrow_guard`'s falsy branch to the enclosing
context. This is principled (it IS §6.1), not a fixture carve-out.

**High-value finding 1 — parser non-termination on real code (FIXED).** The
end-to-end survey (the first time the *parser* ran over real `lib/`) hung
indefinitely on `lib/actor/init.lua`. Root cause: a statement emitting an
out-of-subset marker (method call in an `if` test; a stray `then` reached as a
statement start) could return WITHOUT consuming the confusing token, so
`parse_block`'s loop spun forever. Fixed with a **progress guard** — `parse_block`
records `pos` before each `parse_statement` and force-advances one token if it did
not move (the standard recursive-descent recovery invariant). The hand-built corpus
never exercised the parser, so this class was invisible until Pass 5.

**High-value finding 2 — substrate scaling (FIXED in the substrate loop; residual
TIMEOUT now hosted-checker-bound).** `lib/type/v7_mr0/init.lua` lowers to 713
requested claims (2724 claims/evidence). Pass 5 recorded `A.check`'s fixpoint as
re-sweeping every pending evidence object each round (O(sweeps × evidence)) and
left it for a future optimization. That optimization landed (`perf(analysis)`,
`docs/perf/log.md` 2026-06-12): `A.check` is now a **dependency-driven worklist**
— when an evidence accepts its claim it re-queues only the evidence whose declared
inputs reference that claim (a `dependents` index built once over all input edges),
sound because every hosted checker reads accepted-ness solely through its own input
Ids; plus per-check **memoization** of structural claim keys (each deep-args
serialize happens once, not once per accepted-ness probe). A synthetic reverse-order
chain — the adversarial case for a re-sweep — is now linear (5 000 claims: 5.26s →
0.011s, ~460×); the real file dropped 21.6s → 14.5s. Both refinements are pure
substrate vocabulary and behavior-identical: all 4906 assertions across the six
hosted semantics pass unchanged. The file nonetheless **stays the survey's 1
TIMEOUT** because its remaining 14.5s splits ~5.3s substrate (the structural-identity
serialization floor for 2724 deep args) and ~8.5s **inside the hosted slice checker**
(repeated `parse_ctx`/`parse_type`/`subtype` per call). The substrate loop is no
longer the bottleneck; the residual cost is a hosted-semantics follow-up the
substrate must not reach into.

**The end-to-end survey headline:** **0.3% CHECKED-CLEAN** (3 files) ·
0.3% CHECKED-FINDINGS · 98.6% OUT-OF-SUBSET · 0.6% NO-ANNOTATION · 1 TIMEOUT, over
865 files. The collapse from the annotation-only 26.6% to 0.3% is honest data: the
§5 *statement* subset is far narrower than the annotation grammar alone. The
end-to-end construct ranking (`operator-concat`/`operator-arith`,
`unbound-name:require/package`, `unannotated-function`, `assign`/`field-assign`,
`method-call`, `multi-assign`, `named-param`) is slice-v2's statement-lowering build
order, the way §10.1 ranked the type-grammar work. Full numbers + the findings in
`docs/slice-survey-v1.md` ("v1 end-to-end" section).

### 9.9 Mechanization findings — slice v2 increment 1 (§6.5)

Recorded honestly per the prompt. The increment landed the six §6.5 items; the
findings below are the spec-tightenings the mechanization forced, each resolved
without crossing the ratified fence (no complement, match types, global solving,
HKT). The annotation survey's CHECKED-CLEAN more than doubled (26.6% → 55.8%) and
OUT-OF-SUBSET halved (58.4% → 29.7%); the e2e CHECKED-CLEAN rose 3 → 5
(`docs/slice-survey-v1.md`, "after v2 increment 1").

- **Names are interner-INVISIBLE, which discharges name-blind subtyping for free
  (the sharpest, cleanest finding).** §6.5.1's "subtyping ignores names" was
  realized not by a name-stripping step in the relation but by EXCLUDING `names`
  from the interner's structural key (`M.fn`). Two `fn` types differing only in
  parameter names therefore intern to the SAME tid, so `subtype` ignores them
  *structurally* — there is no special case, no name comparison, nowhere for a
  name to leak into the algebra. `self` is then literally an ordinary named first
  param (`name="self"`), so the survey's separate `named-param-self` tag closed by
  the identical mechanism — confirming it was a *measurement* split, never a
  semantic one (§6.5.2). The codec carries names in the portable `fn` node for
  diagnostics/lowering without affecting claim identity (names are not in the key).

- **`{ T }` and `T[]` collapse to ONE canonical form, and a multi-element
  `{ A, B }` is rejected — which surfaced the tuple-type-in-table-position gap.**
  Both spellings desugar to `indexer(integer, T)` and intern to the same tid
  (§6.5.3/§6.5.4 — "collapse asymmetries to primitives"). The decision to reject
  `{ A, B }` (a positional tuple as a *table element*) is what made the survey's
  residual CHECKED-FINDINGS honest: real code writes `{ [integer]: { A, B } }` and
  `{{A, B}}` (a 2-tuple as a list element), which v1 admits ONLY in fn
  param/return position (the return-position `tuple` of §6.5.5), NOT as a table
  element. This is a *new, deeper* residue the increased reach exposed — recorded
  as increment 2's "tuple-type in table position" item, distinct from the
  return-position tuple this increment added. It is a grammar gap, not a soundness
  gap: rejecting the unsupported element form is sound (wider rejection).

- **The `tuple` constructor needed NO new union machinery — only `tuple <: tuple`.**
  §6.5.5's union-of-multi-return-tuples decomposed cleanly: `tuple <: union`,
  `union <: union`, and `tuple <: union-of-tuples` are all the EXISTING union
  exists-forall (a `tuple` is just another atom to the union rules). The only new
  code is the `tuple <: tuple` covariant rule — and it shares the SAME helper
  (`tuple_sub`) the `fn`-return rule was refactored to call, so there is one
  tuple-subtype rule, not two. A one-element tuple normalizes to its element at
  construction (`G.tuple`), so the constructor only ever holds 0 or ≥2 fixed (or a
  vararg); the codec rejects a non-canonical one-fixed-no-vararg tuple
  (parse-not-cast). Scalar-vs-tuple and tuple-vs-non-tuple incomparability falls
  out of the constructor-pair dispatch returning `false` — no special case. The
  fuzz generator was extended to emit tuples and tuple unions; the exists-forall and
  reflexivity laws hold across the seeded run (5654 subtype assertions, up from 4454).

- **Multi-line `--::` was a SCANNER reach, not a semantics change (corrects §9.3
  finding 5).** The "unterminated table type" CHECKED-FINDINGS were all wrapped
  `--:: Name = {` declarations; the type-grammar parser always handled the full
  type — only the line scanner assumed one directive per line. The fix
  (`scan_annotation_at`) joins continuation lines while the directive's brackets
  are unbalanced (string-literal-aware balance), feeding `parse_type_ann` the
  joined single-line body it always expected. Both consumers (the survey's
  `extract_annotations` and the lowering's first pass) skip the consumed
  continuation lines so they are not re-scanned as separate failing directives.
  This corrects §9.3 finding 5's "single-line only" claim — it was always a
  scanner limitation, never a slice-semantics property.

- **Corpus verdict deltas (honest, recorded).** Under real lowering, two fixtures
  moved off the `named-param` boundary: `cross_module_type_alias` (named params now
  lower; the NEXT boundary is the unannotated closure + a cross-module `require`
  field) and `hamt_recursion` (named param `node: HamtNode` now lowers; the NEXT
  boundary is the FORWARD-referenced alias — `Interior` references `HamtNode` before
  its `--::` line, a single-pass-alias-env gap recorded for increment 2). Both stay
  OUT-OF-SUBSET on a deeper, real §5 boundary; the corpus_lower_test verdict
  assertions were updated to the new boundary (the split is still 2 CLEAN / 9
  OUT-OF-SUBSET / 0 rejections — the soundness invariant held).

**Out of this increment, recorded as increment 2's headline:** cross-module /
unresolved type-alias resolution — the new survey #1 at **172 files** (down from
232: some files were *also* blocked on named-param and are now clean, isolating the
alias demand). It is a `require`-boundary / multi-artifact extension (§2.5, §9.2), not
an annotation-grammar reach; the slice trusts cross-module aliases rather than
checking them, and a checked relation needs the required module's artifact in the
same `CheckRequest`. Also deferred to increment 2 (a fixture demanded none here):
multi-return-aware narrowing for the `local ok, err = f(); if not ok` consumer
(§6.5.5) — the relation and annotation grammar landed; the flow-narrowing consumer
follows when a fixture forces it.

**What buckled in the substrate during increment 1: nothing** — every change is in
the slice modules (`slice_ty`, `slice_subtype`, `slice_ty_arg`, `crescent_slice_parse`,
`crescent_slice_lower`, `slice_survey`); `init.lua` is byte-for-byte unchanged across
all five passes AND this increment. The full analysis suite is green at 6157
(4905 prior intact + the increment's units/codec/fuzz). `bin/cr check` is clean on
every touched file.

### 9.10 Mechanization findings — slice v2 increment 2 (§6.6, cross-module aliases)

The first genuinely **multi-artifact** increment, and the design's central
prediction was discharged exactly: **no substrate change was required.** Recorded
honestly per the prompt — including the headline finding (no substrate requirement
surfaced), the measured collapse with honest residue, and the tooling constraints
the mechanization hit.

- **The substrate requirement the prompt asked about did NOT surface — and that is
  the load-bearing finding.** §6.6 predicted, and the mechanization confirmed, that
  cross-module resolution is a *consumer* of the multi-artifact object model, not an
  extension of it. The exporting module's source rides an existing `Artifact`
  (`kind = "source_text"`), its `--::` aliases ride existing `Observation`s
  (`predicate = "alias"`, plural `source_artifacts`), the cross-artifact hop rides an
  existing `TrustBoundary` (`kind = "cross_module_alias"`, populated `covers`), and
  each consuming claim's reliance rides an existing `Dependency` (with a populated
  `invalidation` field). All four object kinds already existed; `init.lua` is
  byte-for-byte unchanged. The concurrent `init.lua` work was never reached. This
  validates the object-model claim that artifacts are first-class and the
  multi-artifact story "exists in the model" — increment 2 only had to assemble it.

- **TWO cross-module idioms in real code; the `--:: require` directive is the
  dominant one (the corpus reality the prompt mandated checking first).** The
  original fixture's source fire (dns/tcp_client requiring lib.epoll) is the
  *value-require* form. But the corpus's dominant idiom (48 files, the whole
  taskgraph cluster) is the **`--:: require "lib.x"` type-only directive** — a `--::`
  whose body is `require "<path>"`, importing *only* that module's aliases. v1's
  scanner returned `nil` for it (it has no `=`), so it was silently dropped and every
  name it would import became `unknown-type-name`. Recognizing it
  (`scan_annotation`'s new `import` kind) is what resolves the taskgraph cluster.
  Both forms reference imported types by **bare, unqualified name** — no `mod.Type`
  qualification idiom exists anywhere in the corpus (verified by grep), which decided
  the flat-name visibility rule.

- **The collapse is real but modest (172 → 152), and the residue is genuine, not
  hidden failure.** Resolution fires exactly for files whose unresolved name is
  declared as a TOP-LEVEL `--::` alias in a `require`d module. The 152-file residue
  is honestly *not* this shape: `lib/actor/init.lua` (the former #1 example) has zero
  cross-module imports (its `unknown-type-name` is `cdata`-adjacent / `declare`d);
  `Ctx` (26 files) is resolved by the legacy checker through a deeper-scope path the
  slice's top-level-alias import does not reach. The slice does not chase these by
  special-casing — they are recorded as residue. (The CHECKED-FINDINGS rise 11 → 22
  is the *expected* consequence of resolving names: a file whose blocking unknown
  name now resolves can surface a deeper, previously-masked annotation finding.)

- **Caps-first held with no friction.** Reading an exporting module's source is I/O;
  the resolver (`crescent_slice_xmodule.lua`) takes a `read_file` cap and never
  touches `io`. The lowering driver and the survey inject a thin `io.open`-backed
  reader at their edges. With no cap, cross-module imports resolve to no aliases —
  the honest pre-increment behavior, exercised by a test. This is the CLAUDE.md
  caps-first constraint satisfied by construction, not retrofitted.

- **Cycles terminate by a visited set, orthogonal to the μ machinery (the Q3
  decision, confirmed).** A `--:: require` cycle (mutually-requiring modules) is a
  cycle in the *module graph*, broken by a visited-set on module paths — distinct
  from the μ cycle guard that decides recursive *type* subtyping. A cross-module
  *recursive type* still reduces to a `mu` via the existing `declare_alias`
  placeholder-binding path once both names are co-visible. Both mechanisms already
  existed; the increment composes them. Tested with a two-module require cycle.

- **The true cross-module fixture is now a two-file corpus fixture, and it exposes
  the §5 statement-lowering boundary (honest, not hidden).** `corpus/xmod/` holds
  the exporting `epoll.lua` (declares `Epoll`) and the entry `tcp_client.lua`
  (references `Epoll` by bare name across the `require`). The *annotation* resolves
  cleanly — `Epoll` is no longer `unknown-type-name`, and the resolution rides a
  visible `cross_module_alias` trust boundary. But the entry's *statements* (a
  value-`require`, a `mod.new()` method call) are out-of-§5-subset, so the lowered
  file is OUT-OF-SUBSET — the same statement-lowering gaps §9.8 ranked, orthogonal to
  the alias resolution this increment delivers. The test asserts the alias-resolution
  win (no `unknown-type-name:Epoll`, the trust boundary present, the dependencies
  recorded) rather than a CLEAN end-to-end verdict the §5 subset cannot yet give.

- **The transitive-alias typecheck constraint (a tooling note, not a semantics
  finding).** The new modules reference the `Ty`/`PTy` aliases the slice carries on
  its `--::` declarations. The real typechecker resolves a bare type name in a
  transitively-required file against the *entry's* assembled alias env, so a new file
  that requires the slice modules must also `require` `slice_ty`/`slice_ty_arg`
  (whose `--::` declare `Ty`/`PTy`) for those names to resolve — mirroring §9.3
  finding 5's cross-module-alias-visibility note for the *real* checker (the same
  phenomenon this increment addresses at the *slice* level). This is a constraint on
  how the slice modules are written, not a property of the slice's checked semantics.

**What buckled in the substrate during increment 2: nothing.** The increment adds
two scanner/resolver modules (`crescent_slice_xmodule.lua` + its test) and threads a
`read_file` cap through the lowering driver and the survey; `init.lua` is
byte-for-byte unchanged. Full `bin/cr test lib/type/analysis/` green at 6193
(6157 prior intact + 36). `bin/cr check` is clean on every new file and introduces
no regression on every modified file.

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

**Pass 5 is DONE** (2026-06-12): the statement-lowering frontend
(`crescent_slice_lower.lua`) — the missing driver that turns real Lua source text
into the slice's artifact + claim/evidence graph end-to-end, the gap the survey
honestly exposed. All 11 fixtures now drive source-text → lower → substrate check
(`corpus_lower_test.lua`, 70 assertions, the load-bearing corpus assertion);
`corpus_test.lua`'s hand-built derivations are retained as evidence-method unit
tests. The §5 statement subset is reproduced with a self-contained lexer+parser
(the production `lib/type/static/parse.lua` was NOT reused — too coupled to its FFI
arena; decision in §8 Pass 5). Under real lowering 2/11 fixtures are CLEAN and 9/11
OUT-OF-SUBSET with 0 rejections anywhere — the honest data the hand-built graphs
had assumed away (§9.8). Two high-value findings: a parser non-termination on real
code (FIXED with a progress guard) and a substrate-scaling TIMEOUT on a 713-claim
file (RECORDED). Full `bin/cr test lib/type/analysis/` green at 4905 (4835 prior +
70). The substrate (`init.lua`) was again **not** touched. Findings in §9.8; the
end-to-end survey headline in §10.1 / `docs/slice-survey-v1.md`.

**All five mechanization passes are complete.** This is the ladder's final rung, and
it has landed: the agnostic substrate is validated from propositional logic through
a real Crescent slice — now driven from actual source text, not hand-built graphs —
without a single Crescent-specific substrate primitive. The design doc's falsifiable
bet (time-to-first-real-Crescent-claim) settled at the target. No further
mechanization passes remain; future work is *un-deferral* of the fenced extensions
(complement / RDNF / match types / row polymorphism / parametric polymorphism /
`cdata`/`userdata`/`thread` / metatables) and the §9.8-ranked statement-lowering
gaps (operator typing, global/module model, unannotated-function inference, the
assignment forms), each behind its written §1.4 / §3.4 trigger or the demand
ranking, never a substrate rewrite.

### 10.1 Survey pass — DONE (2026-06-12): the v2 demand ranking

The survey pass drove the slice's parser-frontend adapter over the **whole real
`lib/` corpus** (864 `.lua` files, excluding `*_test.lua` and
`lib/type/analysis/corpus/`) and produced the demand-ranked report
`docs/slice-survey-v1.md`. The runner is `lib/type/analysis/slice_survey.lua` — a
reusable measurement tool, re-run after every v2 increment.

**What the survey measures (two modes since Pass 5).** The *default* mode is an
**annotation-grammar conformance** survey: the slice adapter consumes the `--:` /
`--::` seam, every annotation parsed through `parse_type_ann` / `declare_alias`, the
file classified by whether all its annotations sit inside v1. (At the time this
section was first written, v1 had no whole-Lua-statement lowering — the corpus_test
hand-built derivations — so this was the only honest reading.) **Pass 5 added the
`--e2e` mode** (`slice_survey.lua --e2e`, `M.run_e2e`): the full statement-lowering
frontend driven over the corpus — source text → lower → substrate check — which is
CHECKED-CLEAN only when a file's annotations AND its checked statements both sit
inside §5. The end-to-end headline and its findings are in §9.8 and the
"v1 end-to-end" section of `docs/slice-survey-v1.md`; the annotation-only numbers
below are the prior measurement, kept as-is.

**Headline split (864 files).** 26.6% CHECKED-CLEAN · 1.6% CHECKED-FINDINGS ·
58.4% OUT-OF-SUBSET · 13.3% NO-ANNOTATION · **0 timeouts, 0 crashes** (the
audit-fixed hang class has no survivor on real code; per-file budget 5s, total
runtime ~0.3s).

**Adapter instrumentation (error reporting only).** The survey extended the
adapter's *failure paths* to emit a **construct tag** per out-of-subset rejection
— it never changed what the adapter accepts. New tags: `named-param` /
`named-param-self` (positional-only params in v1), `generic-application`
(`Name<…>`), `array-postfix` (`T[]` shorthand; v1 spells arrays
`{ [integer]: T }`), `intrinsic-dollar` (`$Require`/`$PairsReturn`), `cdata` /
`userdata` / `thread`, and `unknown-type-name:X` (a name the per-file alias env
did not resolve — overwhelmingly a cross-module / imported / `declare`d alias).
The full analysis suite stayed green (4835 assertions) across the change.

**The demand histogram (slice v2's build order, collapsed view).**

| Rank | Construct | Files | Share |
|--:|---|--:|--:|
| 1 | named parameters (`name: T`) | 266 | 30.8% |
| 2 | cross-module / unresolved type alias | 232 | 26.9% |
| 3 | `self` parameter | 128 | 14.8% |
| 4 | `T[]` array shorthand | 88 | 10.2% |
| 5 | generic application (`Name<…>`) | 27 | 3.1% |
| 6 | `$`-intrinsic | 25 | 2.9% |
| 7 | trailing tokens (misc) | 23 | 2.7% |
| 8 | `cdata` | 13 | 1.5% |

Reading it (demand only, no design): named/`self` parameters (1+3 = 394 files) and
cross-module alias resolution (232) dominate; `T[]` array shorthand (88) is the
largest pure-grammar gap. These four are the v2 demand front. Each is currently a
v1 deferral — named params and `T[]` are annotation-grammar surface (parser
extensions, no lattice change), cross-module aliases are §2.5's trusted-boundary
form generalized, `$`-intrinsics and generics touch §1.4's fenced extensions. The
survey does not design these; it ranks them.

**CHECKED-FINDINGS (14 files) — genuine residue.** After construct-tagging, the
findings reduce to three real sub-patterns, none of which is a checker soundness
bug: (1) **multi-line `--::` table aliases** (the single-line-scan limitation,
§9.3 finding 5, surfacing on wrapped declarations — `lib/asm/ir.lua`,
`lib/platform/platform_types.lua`, the ccv2 type files); (2) **union-of-multi-
return-tuples** (`(A, B) | (nil, string)`, the pervasive error-return idiom —
`lib/ed25519/init.lua`, `lib/finite_field/init.lua`); (3) **`{ T }` list/set
shorthand** (`{ string }`, `{ Listener }` — `lib/nat_lang/init.lua`,
`lib/event/init.lua`). All three are grammar/adapter gaps recorded for v2, not
slice precision failures. Full per-file list with diagnostics in
`docs/slice-survey-v1.md`.

### 10.2 Slice v2 increment 1 — DONE (2026-06-12)

Increment 1 (§6.5) landed the annotation-grammar + frontend reach the histogram
ranked at the top: named parameters, `self`, `T[]` array shorthand, `{ T }` list
shorthand, multi-line `--::` aliases, and union-of-multi-return-tuples. Design grew
first (§6.5, derived whole), then the mechanization in the same commit:
`slice_ty.lua` (the `tuple` constructor + name-bearing `Params`), `slice_subtype.lua`
(the `tuple_sub` helper backing both `fn`-return and the new `tuple <: tuple` rule),
`slice_ty_arg.lua` (the `tuple` codec node + well-formedness), `crescent_slice_parse.lua`
(named-param parsing, `T[]`/`{ T }` desugar, return-position union-of-tuples,
multi-line `scan_annotation_at`), and the two scanner consumers
(`crescent_slice_lower.lua`, `slice_survey.lua`). The three CHECKED-FINDINGS
sub-patterns §10.1 flagged (multi-line aliases, union-of-tuples, `{ T }` list) are
all resolved; findings in §9.9.

**Survey re-run headlines** (`docs/slice-survey-v1.md`, "after v2 increment 1"):
annotation CHECKED-CLEAN **26.6% → 55.8%** (230 → 483 files), OUT-OF-SUBSET **58.4%
→ 29.7%**; e2e CHECKED-CLEAN 3 → 5. The new annotation-survey #1 is
`unknown-type-name` (172 files) — **cross-module / unresolved type aliases, the
explicit increment-2 headline item** (a `require`-boundary / multi-artifact
extension, not an annotation-grammar reach). The ratified fence held throughout: no
complement, match types, global solving, or HKT; five of six items are
desugaring/scanner reach (zero lattice change) and the sixth (`tuple`) is one
value-universe-justified constructor whose subtype rule is covariance + the existing
union exists-forall. The substrate (`init.lua`) was again **not** touched. Full
analysis suite green at 6157.

### 10.3 Slice v2 increment 2 — DONE (2026-06-12)

Increment 2 (§6.6) landed cross-module type-alias resolution — the measured #1
demand (`unknown-type-name`, 172 files). Design grew first (§6.6, the multi-artifact
derived whole, consuming the object model rather than extending it), then the
mechanization in the same commit: `crescent_slice_xmodule.lua` (the resolver — the
`--:: require` directive + value-require trigger collection, module-path → file-path
resolution, acyclic-visited cross-module import pass with an injected `read_file`
cap), the `import` directive kind in `crescent_slice_parse.lua`'s `scan_annotation`,
the import pass + cross-artifact Artifact/Observation/TrustBoundary/Dependency
records threaded into `crescent_slice_lower.lua`'s `M.lower` (cap-injected), and the
cross-module seeding in `slice_survey.lua` (both annotation and `--e2e` modes). The
true cross-module fixture (the tcp_client+epoll pattern the original
`fixture_cross_module_type_alias.lua` could only approximate in-file) is now the
two-file `corpus/xmod/` fixture, asserted end-to-end in
`crescent_slice_xmodule_test.lua` (36 assertions).

**Survey re-run headlines** (`docs/slice-survey-v1.md`, "after v2 increment 2"):
annotation `unknown-type-name` **172 → 152** files (−20), OUT-OF-SUBSET **29.7% →
27.8%**, CHECKED-CLEAN 483 → 489. The collapse is real but modest and the 152
residue is **genuine** (names with no top-level-`--::`-export source — `cdata`/
`declare`d types, legacy-checker deeper-scope resolution), recorded honestly, never
forced by special-casing. The e2e survey is unchanged (statement-lowering-bound).

**No substrate requirement surfaced** — the central finding (§9.10): cross-module
resolution is a pure consumer of the multi-artifact object model, so `init.lua` was
**not** touched (the concurrent init.lua work was never reached). Full analysis suite
green at 6193 (6157 prior intact + 36).

### 9.11 Adversarial audit round 2 (cross-module alias surface)

Execution-confirmed findings against the cross-module alias surface
(`crescent_slice_xmodule.lua`, `crescent_slice_parse.lua`, `crescent_slice_lower.lua`).
All four findings were fixed; one prior claim was retracted. Round 1's fixes held
throughout; the trust-recording scope (round 1 found it over-broad, never under)
remained as recorded. Full analysis suite green at 6226 (6193 prior intact + 33 new
regression tests).

**F1 [unsound — fixed]: silent last-wins collision between exporters.** `import_top_level_aliases`
installed bare names unconditionally. Decision: DETECTED AND REJECTED — importing a
name already present from a DIFFERENT exporter with a DIFFERENT tid is an error
diagnostic naming both modules and the colliding name; identical tids (same interned
Ty) dedupe silently. Entry-local `--::` shadowing an import stays allowed (the
shadow is applied in `scan_source` after the import pass, which is the verified
lexical-scope rule). Implemented at the import-installation seam in
`import_top_level_aliases` (new `origin` map tracks name → first exporter);
`declare_alias`'s general in-file semantics are unchanged. Regression tests: a-then-b
and b-then-a both error identically; same-type double import dedupes; local shadow
works.

**F2 [doc defect + false claim — retracted]: mutual cross-module aliases do NOT reduce
to the in-file recursive case.** The `crescent_slice_xmodule.lua` docstring (~lines
80-82 in the original) and §6.6.4 claimed that mutual cross-module aliases reduce to
the in-file recursive case via `declare_alias`'s μ-placeholder the moment the names
are co-visible in the flat env. This is false: each exporting module is parsed before
the other's names are installed. The correct behavior is: mutual cross-module aliases
produce `unknown-type-name` errors on the referencing side — the SAME honest-error
behavior as in-file forward references (§9.8 deferral). Implementation: no code
change (the honest-error behavior was already correct); corrected the docstring in
`crescent_slice_xmodule.lua` and §6.6.4. Deferral recorded: **forward/mutual alias
references (in-file and cross-module) both require two-phase name-installation-then-
parse.** Trigger: a real `lib/` pair where M's alias body legitimately references N's
alias declared in a separate module (and N's references M's). No such trigger has
been confirmed in the corpus as a v1 gap requiring resolution; recorded for the next
increment. Regression test: mutual forward reference errors honestly (AT referencing
BT before BT is installed → AT absent or errored, BT succeeds).

**F3 [hardening — fixed]: malformed paths reached the cap.** `candidate_paths` built
file paths from any require string without validating segments, so `lib..secret` or
`lib.x.....` could reach the injected `read_file` cap. Decision: validate all
dot-separated segments (each non-empty, matching `[%a%d_]+`) BEFORE building any
file path; malformed → `out-of-subset/invalid-require` marker, cap never called.
Implemented in `valid_modpath_segments` (new pure helper exported as
`M.valid_modpath_segments`); `read_module` and `resolve` call it before any path
construction. Regression tests: both attack strings refused without cap reach; the
`valid_modpath_segments` boundary (leading/trailing/doubled dots, empty string)
exercised; legitimate paths still reach the cap normally.

**F4 [record precision — fixed]: invalidation anchored to path, not content.** The
exporting `Artifact` id was path-only (`"xmod-src:" .. rec.path`), so a body change
was invisible to an id diff; the `Dependency.invalidation` string was generic ("body
changed"). Decision: compute a CRC32-hex digest of the exporting source text (using
`lib.hash.crc32`, the existing pure-Lua/FFI tier — no new dependency); include it in
(a) the `Artifact` id (`"xmod-src:" .. path .. "@" .. digest`), and (b) the
`Dependency.invalidation` string (`"exporting module " .. path .. " body changed
(digest:" .. digest .. ")"`). The `ImportRecord` type alias gains a `digest: string`
field. No `init.lua` change. Regression tests: same-path changed-body → different
digest; the lower-level dependency invalidation string contains `"digest:"`.

**Survivals (attacks that found nothing — evidence too):**

- **No-cap behavior held.** Resolving with `opts = nil` still produces an empty env
  and zero imports; dynamic-require markers are still emitted. The cap-first invariant
  is unbroken.

- **Cycle termination held.** The visited-set cycle break is unaffected by the
  origin-map and collision logic; the cycle-termination regression test passes.

- **Round 1 fixes held.** Well-formedness as a hard precondition of `declare_alias`,
  `lit_int` integer validation, `unknown` narrowing, subtype DAG memoization, and
  `instantiate_witness` callee binding all continued to pass; no regression on any
  of the 28 round-1 regression tests.

- **Trust recording scope.** Round 1 found trust recording over-broad-never-under
  (every requested claim rides every cross-module trust boundary regardless of which
  alias it actually used). This remains a known imprecision — the over-broad direction
  is conservative (never under), and the fix requires per-alias claim attribution,
  which is a future increment. The round 2 audit did not find a case where the
  over-broad recording hides an actual soundness gap; the recorded boundaries are
  still auditable.

### 9.12 Mechanization findings — slice v2 increment 3 (§6.7, the e2e statement front)

Increment 3 landed the §6.7 items in the dependency-honest order (operators +
assignments + method calls + unannotated functions + the injected stdlib cap). The
findings, each resolved without crossing the ratified fence (no complement, match
types, global solving, HKT) and with no `init.lua` change:

- **Two new evidence methods, both pure operand-kind derivations.** `synth_binop`
  and `synth_unop` (§6.7.1) are the increment's only new vocabulary. Each is keyed
  ONLY by the operator string and the structural operand kinds — no name-keying, no
  special case. The result-type rules are pinned from the LuaJIT 5.1 value universe:
  `/` and `^` always synthesize `number` (real-valued); `+ - * %` synthesize
  `integer` iff both operands are `<: integer`, else `number`; `..` over
  `string|number` ⇒ `string`; order comparisons over compatible primitive pairs ⇒
  `boolean`; `==`/`~=` over anything ⇒ `boolean`; `#` over string/table ⇒ `integer`;
  unary `-` preserves the operand's integer/number kind. The metatable-dependent
  operand cases (table + table, `#` on a non-string non-table, mixed-type comparison)
  are out-of-subset **deferrals** (`operator-metamethod-*`) with un-defer triggers —
  NEVER type-error claims, because v1 cannot know the metatable (the §1.4 posture).

- **`local function` recursion was a latent bug the operator front exposed.** Before
  operators, `s + tree_sum(node.left)` was blocked at `+` BEFORE the recursive call
  was looked up, so `tree_sum`'s self-reference was never resolved. With `+` in
  subset, the lowering reached the call and `tree_sum` was `unbound-name`. Root cause:
  a `local function f` is in scope inside its OWN body (Lua's `local f; f = function…`
  desugaring), but the lowering bound the name only in the OUTER context. Fixed by
  binding the function name in the body context too (annotated and unannotated). A
  genuine finding the prior subset masked — exactly the "something unexpected is a
  signal" discipline.

- **The honest type-mismatch surfaced by reaching further.** `coinductive_recursive_
  types` moved OUT-OF-SUBSET → FINDINGS: operators unblocked the body, so the lowering
  now reaches `tree_sum(node.left)` where `node.left : TreeNode | nil` legitimately
  fails `<: TreeNode`. v1 narrows a VARIABLE binding, not a FIELD PATH (`if node.left
  then` does not refine `node.left`). This is the field-path-narrowing deferral
  (§9.8), now a visible `type-mismatch` finding rather than a hidden operator block —
  every REQUESTED claim still accepts (0 rejections). The fixture's expected verdict
  was updated honestly; the field-path narrow is the recorded un-defer trigger, NOT
  bent.

- **Unannotated functions: `unknown` params, not fresh inference variables.** §6.7.3
  binds each unannotated param `: unknown` and synthesizes the return from the body.
  `unknown` is the fence-honest choice: a fresh unification variable would be the
  global solving the fence excludes; `unknown` is sound (the caller/body must narrow)
  and makes the annotation pressure VISIBLE (an unannotated body that depends on its
  param shape falls out of subset, demanding the annotation the conventions want).
  This resolves the §10 local-inference edge for NAMED functions by posture, not by a
  solver. The expression-position ANONYMOUS closure (`unannotated-closure`, 393 files)
  remains the residual local-inference edge.

- **The stdlib model is an INJECTED capability, never a `_G` reach.** §6.7.2's stdlib
  cap (`tonumber`/`tostring`/`string`/`math` as ordinary `Ty` bindings) is injected
  via `opts.stdlib`; absent the cap, the names stay `unbound-name:*` (caps-first,
  CLAUDE.md "No ambient globals by default"). The corpus test lowers WITHOUT the cap
  (so `tonumber_return_type`/`cast_not_inference_source` stay OUT-OF-SUBSET on unbound
  names); the survey injects it (so they type). The cap is built in the current
  interner generation (after `M.lower`'s `G.reset()`), and `default_stdlib()` is the
  model a caller may inject — the library itself never reads `_G`/`io`.

- **Method calls are a literal desugaring, consuming the increment-1 `self` machinery.**
  §6.7.5: `o:m(args)` lowers to `o.m(o, args)` — `synth_index(o, "m")` + `synth_call`
  with `o` prepended, checking `o ⇐ self-param-type`. No method-call evidence method,
  no `self`-specific rule; `self` is the ordinary named first param (§6.5.2). The
  receiver is synthesized once.

- **The whole-file CHECKED-CLEAN headline (5, 0.6%) is gated by the file's LAST
  out-of-subset construct.** This is the honest, load-bearing finding: the construct
  HISTOGRAM moved dramatically (operators, method-calls, named-function inference all
  dropped out of the top ranking), but a file goes whole-file CLEAN only when EVERY
  statement is in-subset, and the long tail of GLOBALS (`package`/`require`/`table`/
  `setmetatable`/`pcall`), ANONYMOUS CLOSURES, and multi-return/dynamic-key forms
  still leaves at least one out-of-subset construct in nearly every real `lib/` file.
  The e2e number moving requires the GLOBALS model and `require`-returns-module-VALUE-
  type synthesis too — the dependency-honest TAIL recorded in §10.4.

### 10.4 Slice v2 increment 3 — DONE (operators + assignments + methods + unannotated + stdlib cap), module-value-type TAIL recorded (2026-06-12)

Increment 3 (§6.7) landed the e2e statement-coverage front in the dependency-honest
order. Design grew first (§6.7, each item derived whole from the value universe),
then the mechanization in the same commit: `synth_binop`/`synth_unop` + the pure
`binop_result`/`unop_result` operator-typing helpers in `crescent_slice.lua`
(registered, no `init.lua` change); the lowering reach in `crescent_slice_lower.lua`
(operator emission, multi-assign/swap flatten-and-zip, indexer-typed dynamic-key
write, `o:m()` desugar, unannotated-function `unknown`-param + body-synthesized
return, the injected `opts.stdlib` cap + `M.default_stdlib()`); the survey injects
the stdlib cap (`slice_survey.lua --e2e`); unit + e2e tests
(`crescent_slice_test.lua` +27, `corpus_lower_test.lua` +26, 6282 total).

**Survey re-run headlines** (`docs/slice-survey-v1.md`, "after v2 increment 3",
`--e2e`): whole-file CHECKED-CLEAN stays **5 (0.6%)** with **0 TIMEOUT** — gated by
each file's LAST out-of-subset construct (§9.12 final finding). The CONSTRUCT
histogram is the real delta: `operator-concat` (702) and `operator-arith:+` (286)
GONE, `method-call` (214) GONE (desugared), `unannotated-function` (named) dropped
out; the new front is globals (`unbound-name:package` 683, `require` 409, `table`
324, `setmetatable` 223), assignment/multi-return forms (`field-assign` 514,
`dynamic-index` 500, `multi-assign` 435, `multi-return` 429), and anonymous closures
(`unannotated-closure` 393). The residual `operator-metamethod-*` (302 across arith/
len) are the GENUINE metatable cases — deferrals, not errors. Corpus split moved 2/9
CLEAN/OUT → **3 CLEAN / 1 FINDINGS / 7 OUT-OF-SUBSET**, 0 rejections.

**The dependency-honest TAIL (recorded, not crossed).** The §6.7.2 `require`-returns-
the-module-VALUE-type synthesis (the M-table convention: lower the exporting module,
accumulate its `rec` from `function M.f` / `M.f = …` assignments, bind the result so
`x.f(...)` is cross-module callable) and the broader globals model (`package`,
`table`, `setmetatable`, `pcall`, …) are the LARGEST remaining e2e blockers and the
module-access half of the increment scope. They are recorded as the next pass's
substrate need: cross-module module-VALUE-type synthesis requires recursively lowering
the exporting module within the existing acyclic-import pass (a consumer of the
multi-artifact model, like §6.6's alias resolution — no new substrate), and the
globals model is more explicit-stdlib-declaration cap surface (§6.7.2). Landing them
is what moves the whole-file e2e CHECKED-CLEAN number off 0.6%. The fence held
throughout; the substrate (`init.lua`) was again **not** touched.

### 9.13 Mechanization findings — slice v2 increment 4 (§6.8, globals + module-value-types + closures)

Increment 4 landed the §6.8 items in the dependency-honest order (stdlib globals +
expression-position closures first, then `require`-returns-the-module-VALUE-type). Each
resolved without crossing the ratified fence (no complement, match types, global
solving, HKT) and with **ZERO new evidence methods** and **no `init.lua` change**.

- **ZERO new evidence methods — the increment is pure lowering reach.** The stdlib
  globals are `trusted_signature` bindings in Γ; the `require`→module-type resolution is
  `synth_index`/`synth_call`/`trusted_signature` over a synthesized `rec`; the closures
  use the EXISTING `synth_function` method (node `t="function"`, named params, each
  return a `checks_against` premise under the param-extended Γ — verified by the
  substrate exactly as a statement func-def body). The whole increment is lowering reach,
  the cleanest fence-honest shape a pass has had.

- **Check-mode closures are bidirectionality's signature move, applied to parameters.**
  §6.8.3: a `func` node flowing into an annotated `fn` slot routes through `check_expr`
  → `check_func_expr`, which pushes the expected param types onto the closure params (the
  CHECKING mode flowing inward). The mode switch is the kernel's `check_against` shape;
  the closure's value type is the expected fn type exactly. A closure in synthesis
  position binds params `unknown` and a `unknown` return (the §6.7.3 fence-honest
  non-solver choice — a fresh inference variable would be the global solving the fence
  excludes). The body-synthesized return JOIN (§6.8) is the residual precision deferral:
  v1 uses `unknown`, matching the existing named-unannotated treatment; the precise join
  un-defers with a local-return-type-collection pass (no solver, just a sink).

- **The stdlib model is an INJECTED capability, extended to the corpus demand — never a
  `_G` reach.** §6.8.1: the cap grew from increment 3's `tonumber`/`tostring`/`string`/
  `math` to cover `type`/`print`/`error`/`package`/`table`/`os`/`io`/`pcall`/`assert`/
  `setmetatable`/`select`/`next`/`rawget`/`rawset`/… The corpus test lowers WITHOUT the
  cap (so the names stay `unbound-name:*` — caps-first); the survey injects it. The
  out-of-fence signatures (variadic generics, match types, meta-spread, intersection
  overloads) are declared as the **soundest in-fence approximation** (`unknown` where the
  true type refines), each a recorded deferral with its precise eventual type (§6.8.1
  table). The approximations are sound — an `unknown` forces the caller to narrow; an
  over-narrow one would be the violation, and there is none.

- **STDLIB-APPROXIMATION DEFERRALS RECORDED** (the precise type each should eventually
  have, all blocked on the §1.4-fenced features): `pcall`/`xpcall` →
  `<F:(...P)->R,P,R>(f:F,...P) -> ...PcallReturn<F>` (variadic generics + the
  `(true,...R)|(false,string)` match type); `assert` → `<T>(T,...) -> T` (generic
  identity refinement); `setmetatable` → `<T,MT>(T,MT) -> T & MT & {#...MT}` (generic +
  intersection + meta-spread); `getmetatable` → `<T>(T) -> MetaOf<T>` (match type);
  `rawget`/`rawset`/`next` → the `Keys<T>`/`Values<T>` match types; `select` → the
  `("#")->integer & ((integer,...)->unknown)` intersection-overload; `unpack` →
  `<V>(...) -> ...V` (generic + vararg-spread return); `string.find`/`match`/`gmatch` →
  the `$FindReturn<P>`/`$PatternReturn<P>` pattern-literal capture-arity intrinsics
  (inherited §9.8 deferral). `pcall`/coroutine **effect machinery stays out** (the
  `$Throw`/`$Catch` intrinsics + the `thread` value kind, the §1.4 fence).

- **`require` returns the module's VALUE type — the §10.4 tail, realized through the
  EXISTING xmodule machinery.** §6.8.2: a static `require("lib.y")` resolves to the
  exporting module's synthesized M-table `rec`, accumulated as `function M.f` / `M.f = …`
  grow the table-local `M`'s record (the `ctx_set_field` accumulation rule) and fixed by
  the top-level `return M` (captured at `func_depth == 0`). The module type is computed by
  **recursively lowering the exporting module** within the cap-injected acyclic-import
  pass — a consumer of the multi-artifact model, like §6.6's alias resolution, NO new
  substrate. Because each recursive lower runs its own interner generation, the module
  type is carried as a **portable PTy** and decoded in the entry's generation at the
  `require` call site; the resolution rides a `cross_module_value` trust boundary. Cycles
  resolve to `unknown` (the honest, terminating cyclic-require tag via the `_mod_visited`
  set); a depth cap bounds deep chains. A non-lib / unreadable / out-of-subset-returning
  module does NOT resolve — the `require` falls through to the unbound-name path, never a
  silent success.

- **TIMEOUT root cause found and fixed (the "something unexpected is a signal"
  discipline).** The first un-memoized draft of the recursive module-type precompute
  re-lowered each transitively-required module from scratch at every diamond node, so a
  require-heavy file (`lib/type/static/check.lua`) fanned out exponentially under the
  depth-6 bound and took **74.76s** — far over the 5s per-file budget, i.e. a termination
  bug, not a slow case (CLAUDE.md timeout rule). Root cause: NO cross-module memoization
  in the precompute. Fixed with a **shared PTy cache** keyed by module path, threaded
  through the whole recursion (`_mod_cache`), so each distinct module's value type is
  computed at most once per top-level entry. `check.lua` dropped **74.76s → 0.79s
  (~95×)**; the survey's TIMEOUTs cleared. PTy is generation-independent, so the shared
  cache is sound across the recursion's distinct interner generations.

- **The whole-file CHECKED-CLEAN headline finally broke off the increment-3 floor.** The
  e2e gate (every checked statement in-subset) had been pinned at 5 (0.6%) through
  increment 3 by the GLOBALS + closures + require tail. Increment 4 lands exactly that
  tail: **CHECKED-CLEAN 5 → 22 (0.6% → 2.5%), ~4.4× — with 0 TIMEOUT** (after the
  shared-cache perf fix; the un-memoized draft had spiked to 21 timeouts before it). The
  construct histogram's new front is the assignment / multi-return
  statement family (`dynamic-index`, `multi-return`, `dynamic-index-assign`,
  `multi-assign`) and the remaining `unbound-name:require` (the non-lib / dynamic /
  out-of-subset-returning requires that legitimately do not resolve), plus the genuine
  `operator-metamethod-*` deferrals — the dependency-honest next front.

### 10.5 Slice v2 increment 4 — DONE (globals model + module-value-type synthesis + unannotated closures) (2026-06-12)

Increment 4 (§6.8) landed the measured new e2e front and the §10.4 module-value-type
tail in the dependency-honest order (stdlib globals + closures, then require-module-
types). Design grew first (§6.8, each item derived whole from the value universe + the
no-ambient-globals posture), then the mechanization in the same commit, all in
`crescent_slice_lower.lua` (NO `init.lua` change, ZERO new evidence methods):

- the extended `default_stdlib()` (`type`/`print`/`error`/`package`/`table`/`os`/`io`/
  `pcall`/`assert`/`setmetatable`/… as injected `opts.stdlib` cap bindings, §6.8.1, with
  the out-of-fence approximations recorded in §9.13);
- expression-position closures: `synth_func_expr` (synthesis mode, params `unknown`),
  `check_func_expr` (check mode, expected param types pushed inward), `check_expr` (the
  mode switch), `build_closure` (the shared body-builder emitting `synth_function`
  evidence), wired into call-args / annotated-locals / annotated `M.f = closure` (§6.8.3);
- `require`→module-value-type: `compute_module_types` (recursive lower → portable PTy,
  shared-cache memoized), `resolve_module_type` (decode in the entry generation),
  `ctx_set_field` (M-table accumulation over `function M.f` / `M.f = …`), module-return
  capture at `func_depth == 0` (§6.8.2);
- unit + e2e tests (`corpus_lower_test.lua` +46: synthesis/check-mode closures,
  annotated-local closures, extended stdlib, cross-module require-value-type with a
  fixed-module read_file harness, M-table accumulation, honest no-such-field /
  unresolved-require boundaries). Full analysis suite green at 6328 assertions
  (6282 + 46); `timeout 30 bin/cr check` clean on the one touched lib file
  (`crescent_slice_lower.lua`).

**Survey re-run headlines** (`docs/slice-survey-v1.md`, "after v2 increment 4", `--e2e`,
867 files): whole-file **CHECKED-CLEAN 5 → 22 (0.6% → 2.5%), ~4.4×**, CHECKED-FINDINGS
0 → 6, OUT-OF-SUBSET 856 → 833, **TIMEOUT 0** (the shared-cache perf fix cleared the 21
the un-memoized draft introduced). The construct histogram's new front: the assignment /
multi-return statement family (`dynamic-index` 589, `multi-return` 482,
`dynamic-index-assign` 477, `multi-assign` 466), the residual `unbound-name:require`
(224 — the non-lib / dynamic / out-of-subset-returning requires that do not resolve),
and the genuine `operator-metamethod-*` deferrals (202/160/136). The whole-file
CHECKED-CLEAN number broke off the increment-3 floor of 5 (0.6%) — the GLOBALS model,
`require`-returns-the-module-VALUE-type synthesis, and check-mode closures together are
what move it. The fence held throughout; the substrate (`init.lua`) was again **not**
touched.

---

### 9.14 Adversarial audit round 3 — increment 3/4 surface (2026-06-12)

Full findings, reproductions, and survivals: `docs/artifacts/typechecker-run-2026-06-12/audit-round-3.md`.

#### F1 [unsound — FIXED]: module-table reassignment ignored; stale rec crosses the require boundary

**Root cause.** The name-target assignment path (`M = <expr>`) requested the RHS value
claim but did not rebind `M` in the `SliceCtx`. The accumulated shadow rec from `function
M.f` / `M.f = …` remained the active binding for `M`; a later `return M` captured the
stale rec as the module value type, and a consumer's `lib.f(1)` was accepted for a
runtime nil-call.

**Fix.** `lower_stmt` assign branch, `tgt.k == "name"` path (line ~2200 in
`crescent_slice_lower.lua`): after requesting the RHS value claim, push a new `ctx` entry
rebinding the name to the RHS type. A post-rebind `return M` now reads the post-rebind
type (the reset empty table `{}`, or whatever the RHS synthesizes).

**Regression tests** (`corpus_lower_test.lua`, "audit-round-3 F1" suite):
- `M = {}` after `M.f` accumulation: consumer `lib.f(1)` is no longer CLEAN (becomes
  OUT-OF-SUBSET or FINDINGS — the phantom-field acceptance is gone).
- `M = N` (rebind to another table with `g`, not `f`): `lib.f(1)` is no longer CLEAN.
- `M = {}` BEFORE accumulation, then `M.f` added: `lib.f(1)` is still CLEAN (fields
  added AFTER the rebind accumulate correctly onto the new binding).
- Plain accumulation without rebind: CLEAN (regression guard, no regressions).

**Survival.** The fix only affects top-level (non-branch) assignment to a name target.
Inside an if/while/for body, `lower_block` passes a COPY of the context (`body_ctx`);
a rebind inside a branch is local to that copy and does not propagate to the parent
context. This leaves the **conditional-rebind case** (e.g. `if cond then M = {} end`)
still using the pre-branch `M` type for `return M` — the join machinery to merge branch
outcomes does not exist in v1. Status: recorded deferral. Un-defer trigger: a context-
join pass at the end of each if/while/for block (no solver required, just a meet over
the name's post-branch candidates; out-of-scope for v1's posture of `unknown` at joins).

#### F2 [precision — FIXED]: fewer-param closure into a wider fn slot over-rejected

**Root cause.** `check_func_expr` called `build_closure` which constructed the fn type
from only the closure's DECLARED params (fewer than `want`'s fixed params). The outer
`check_expr` wrapper then called `emit_check_against(scid, inner_fty, want)` where
`inner_fty ≠ want`, so `subtype(inner_fty, want)` failed even though the code is correct
Lua (extra call args are discarded at runtime).

**Fix.** Pass `want` as the `fty_override` parameter of `build_closure` (new optional 6th
parameter). `build_closure` emits `has_type(ctx, node, want)` (the full expected type)
rather than the inner under-arity type. The outer `check_against` wrapper then emits
`subtype(want, want)` which holds trivially, and the substrate's `check_against` rule
sees `spr.type == sub.a == want`. The body is still verified under the closure's
DECLARED params only (the `synth_function` verifier iterates over `params_node`, not
`pfixed`, so under-declared params are simply absent from the body context — correct
Lua: undeclared extra args are discarded). The arity decision is pinned in §6.8.3:
fewer params → accepted; more params → `type-mismatch` rejection (the extra declared
params would receive `nil` at runtime against a slot that doesn't supply them —
rejecting here is the sound posture; a future `nil`-admitting-widening pass could relax
it, but that requires a `nil | T` analysis pass that v1 does not have).

**Regression tests** (`corpus_lower_test.lua`, "audit-round-3 F2" suite):
- 1-param closure into `(integer, integer) -> nil` slot: CLEAN (was FINDINGS pre-fix).
- 0-param closure into `(integer) -> nil` slot: CLEAN (was FINDINGS pre-fix).
- Exact-arity closure: still CLEAN (no regression).
- More-params closure: still FINDINGS/OUT-OF-SUBSET (the rejection path is preserved).

#### F3 [precision — PARTIAL FIX]: aliased / conditional / wrapped exports under-populate the module type

Three forms — aliased exports (`local A = M; A.f = …; return M`), conditional exports
(`if cond then function M.f … end`), and wrapped returns (`return setmetatable(M, {})`)
— all degrade to OUT-OF-SUBSET (safe: under-populates rather than over-accepts). This
is a precision gap, not unsoundness.

**Trivial alias case fixed.** `local A = M; A.f = …; return M` — the single-direct-alias
form is now tracked. When `local A = <name>` is lowered at module top level (`func_depth
== 0`) and the RHS name's type is a `rec`, `A → M` is recorded in `lc.mod_table_aliases`.
`ctx_set_field` (now with an optional 5th `mod_table_aliases` parameter) mirrors each
field accumulation onto the aliased original: `ctx_set_field(ctx, "A", "f", …)` also
pushes a new binding for `M` with `f` added. A later `return M` then reads the
propagated rec. All four `ctx_set_field` call sites updated.

**Regression tests** (`corpus_lower_test.lua`, "audit-round-3 F3" suite):
- `local A = M; function A.f(x) … end; return M`: consumer `lib.f(1)` is CLEAN.
- `local A = M; A.inc = function(x) … end; return M`: consumer `lib.inc(7)` is CLEAN.

**Surviving deferrals** (recorded with un-defer triggers; §9.14):

| Case | Status | Un-defer trigger |
|---|---|---|
| Conditional rebind: `if cond then M = {} end; return M` | deferral | context-join pass at if/while/for block exit |
| Conditional export: `if cond then function M.f … end; return M` | deferral | same context-join pass |
| Aliased conditional export: `local A = M; if cond then A.f = … end; return M` | deferral | same context-join pass |
| Wrapped return: `return setmetatable(M, {})` | deferral (out-of-subset, safe) | `setmetatable` generic-identity type (`§6.8.1` deferral) |
| Alias chain: `local A = M; local B = A; B.f = …; return M` | deferral | alias chain analysis |

#### Survivals (from the audit report)

All survivals from `docs/artifacts/typechecker-run-2026-06-12/audit-round-3.md` held
through the fix pass:

- Operators (§6.7.1): all sound (integer/number class split, chain propagation, `..`,
  comparison and equality, `#`, unary `-`). No regression.
- Stdlib declaration soundness (§9.13): all sound-loose, no nil flow-through. No regression.
- Module-type cache and cycles (§6.8.2): no poisoning, no staleness, honest cycles.
  No regression.
- Check-mode closures (the non-F2 cases): direct-arg check-mode, closure-via-local
  (synth path), closure into `unknown`-typed slot, union-of-fn slot (precision
  deferral, documented), nested closures, more-params rejection, recursion through
  a closure — all held.
- Round-1 / round-2 regression spot-checks: collision detection, two-module same-field,
  recursive-alias typed field, well-formedness gate, subtype DAG memoization — all held.

---

### 9.15 Mechanization findings — slice v2 increment 5 (§6.9, the multi-return / dynamic-index family)

Recorded honestly per the prompt. The increment landed the four §6.9 items; the
substrate forced one design correction (the new evidence method), and three honest
deferrals surfaced. No checker soundness bug.

1. **The design's "zero new evidence methods" was WRONG — `synth_tuple` is needed
   (the sharpest finding).** §6.9.3 first claimed the multi-return statement reuses
   `check_against`. Mechanization rejected it: `check_against` requires a `has_type`
   premise whose claim type IS the checked value, and nothing asserted
   `has_type(tuple_node, jtuple)`. A multi-value return is a CONSTRUCTED value (the
   value sequence) and, exactly like a table constructor, needs a SYNTHESIS rule.
   The fix is `synth_tuple` — the value-position dual of `synth_table`: N `has_type`
   premises (one per fixed slot, context-matched), conclusion `has_type(tuple_node,
   G.tuple(slot-types))`. It adds no subtype relation, no constructor (the `tuple`
   ctor and `tuple <:` rule are §6.5.5's, untouched), no solver. The design doc was
   corrected in the SAME commit (§6.9 intro, §6.9.3, §6.9.6). This is the
   substrate-honesty discipline: a projected "no new method" that the substrate
   contradicts is corrected to the real method, not forced through with a
   special-cased premise.

2. **The body's declared return must be threaded as the JOINT tuple, not just its
   first slot.** The pre-existing single-return path passed `fret.fixed[1]` as the
   body `ret_ty` (a single Ty). A multi-return check needs the whole declared tuple,
   so the funcdecl/localfunc arm now passes `G.tuple(fret.fixed, fret.vararg)` when
   the declared return has ≥2 fixed (or a vararg), else `fixed[1]`. A SINGLE return
   against a multi-value declared tuple is then correctly `v <: tuple([A,B])` =
   false (a single value cannot satisfy a 2-value return) — sound, no special case.
   A union-of-tuples declared return `(A,B) | (nil, string)` parses as a
   single-element `Ret` whose `fixed[1]` is the union, so the single-slot path
   already carries it and the §6.5.5 exists-forall fires (verified by the
   `return nil, "boom"` test).

3. **The closed-rec dynamic-key RESULT rule must NOT be reused as the WRITE target
   (a real bug, caught by the corpus).** The first draft used `index_result` for
   both the read and the write-target probe. With the new closed-rec read rule
   (`union(fields) | nil`), an EMPTY closed rec `{}` (the `merged = {}` /
   `insns = {}` fixtures) made the dynamic write target `union({nil}) = nil`, so a
   write `merged[k] = v` checked `v <: nil` and REJECTED — turning two
   OUT-OF-SUBSET fixtures into spurious FINDINGS. Root-caused and fixed by splitting
   out `index_write_target` (§6.9.5): the WRITE dual returns the indexer/rec-with-
   indexer element type, `unknown` for an open row, the single field type for a
   HOMOGENEOUS closed rec, and `nil` (out-of-subset) for a heterogeneous or empty
   closed rec. The corpus is the spec — the regression was the signal.

4. **Deferral — heterogeneous closed-rec dynamic write.** `t[e] = v` over a closed
   rec whose fields have DIFFERENT types cannot be soundly checked field-by-field
   without knowing which field the dynamic key hits; v1 is flow-insensitive and
   cannot widen the rec. The homogeneous case (`{ a: integer, b: integer }`, an
   array/map built field-by-field) checks `v ⇐ V`; the heterogeneous case stays
   out-of-subset (`dynamic-index-assign`). **Un-defer trigger:** a rec-field-widening
   pass (mutating the rec's field types post-write).

5. **Deferral — `return f()` multi-spread.** When the last return value SPREADS into
   ≥2 slots (a multi-return call whose tuple fills slots 2..n), those slots carry no
   per-slot `has_type` claim, so `synth_tuple`'s per-slot-premise contract cannot be
   met. The dominant `return a, b` (each value its own claim) form is in-subset; the
   `return f()` spread is out-of-subset. **Un-defer trigger:** a tuple-spread-premise
   mechanism (a `synth_tuple` variant taking the producing call's claim + an arity).

6. **Deferral — body-synthesized multi-return join.** An UNANNOTATED function with a
   multi-return body still synthesizes return `unknown` (the §6.7.3 fence-honest
   choice — no body-join), so the multi-value shape is not reflected in the
   synthesized `fn` type. Identical in spirit to the single-return `unknown`
   synthesis already shipped. **Un-defer trigger:** a local-return-type-collection
   pass (the same sink the §6.8 closure-return join is deferred behind).

**Survivals.** The dynamic-index READ rule is sound over every shape: indexer /
rec-with-indexer (element type, key-checked), open-row rec (`unknown`), closed rec
(`union(fields) | nil`, strictly more precise than `unknown`), union/inter/μ (the
existing recursion). The `synth_index` 2-premise dynamic-key form re-verifies both
the object AND the key node refs against their premises (no forged key type). The
multi-assign method-call / field-call spread recovers the producer's `Ret` from the
synthesized fn type, never from the syntactic form. Full analysis suite green at
6421 assertions (6374 + 47); both touched lib files (`crescent_slice.lua`,
`crescent_slice_lower.lua`) typecheck clean (0 new errors vs HEAD); 0 TIMEOUT in the
e2e survey.

### 10.6 Slice v2 increment 5 — DONE (the multi-return / dynamic-index family) (2026-06-12)

Increment 5 (§6.9) landed the measured top of the e2e histogram — the
multi-return / dynamic-index statement family — diagnosed first (15 real sites per
tag pinned the residual sub-shapes the tag names hid), designed whole against the
measured demand (§6.9), then mechanized in the SAME commit:

- dynamic-index READS reach `index_result` through `synth_expr`'s `indexdyn` arm
  (a 2-premise `synth_index` dynamic-key form) + the new closed-rec-under-dynamic-key
  result rule (`union(fields) | nil`, the closed-row dual of the open-row `unknown`);
- the `return a, b` STATEMENT builds the §6.5.5 tuple via the one new evidence method
  `synth_tuple` (the value-position dual of `synth_table`), checked `⇐ ret_ty` (the
  declared multi-value return threaded as the joint tuple) or captured as the module
  value type;
- `flatten_values` spreads any multi-return LAST value (method-call / field-call), so
  `n, err = r:read()` (the dominant idiom) binds both slots;
- homogeneous closed-rec dynamic WRITES check `v ⇐ V` via the new `index_write_target`
  (the write dual of `index_result`); heterogeneous/empty stay out-of-subset.

ONE new evidence method (`synth_tuple`), honestly admitted after the design's
zero-method projection was contradicted by the substrate (§9.15 finding 1); ONE new
`index_result` result rule + its `index_write_target` write dual; everything else
lowering reach. Substrate (`init.lua`) **not touched**.

**Survey re-run headlines** (`docs/slice-survey-v1.md`, "after v2 increment 5",
`--e2e`, 868 files): whole-file **CHECKED-CLEAN 22 → 25 (2.5% → 2.9%)**,
CHECKED-FINDINGS 6 → 9, OUT-OF-SUBSET 833 → 828, **TIMEOUT 0**. The smaller
whole-file jump than increment 4's is the honest, load-bearing finding: the e2e gate
is the LAST out-of-subset construct per file, and these family files carry several
remaining blockers each, so closing the family moves the CONSTRUCT histogram far more
than the gate — `multi-return` 482 → 317 (−165), `dynamic-index` 589 → 512 (−77),
`multi-assign` 466 → 450 (−16). The new front (most-blocking after this family):
`call-non-function` (calling an `unknown`-typed value), `iterate-non-table` /
`general-iterator` (generic-for over non-table / stdlib iterators), and the
string-method `no-such-field:sub`/`gsub`/`match` (a stdlib-string-method-on-a-value
follow-up). The corpus 11-fixture split moved 3 CLEAN / 1 FINDINGS / 7 OUT-OF-SUBSET
→ 4 CLEAN / 1 FINDINGS / 6 OUT-OF-SUBSET (closure_param_typing → CLEAN, the
multi-return was its last boundary), 0 rejections anywhere. The fence held; the
substrate was again **not** touched. Full report:
`docs/artifacts/typechecker-run-2026-06-12/increment-5.md`.

### 9.16 Mechanization findings — slice v2 increment 6 (§6.10, the empty-fresh-table dynamic write + the diagnose-first re-ranking)

Recorded honestly per the prompt. The increment's primary result is the DIAGNOSIS:
per-marker corpus measurement contradicted the framing of the three named §9.15
deferrals. One sound in-fence item landed; the rest is correctly re-framed as
substrate gaps in other families. No checker soundness bug.

1. **The §9.15.4 deferral's real shape is EMPTY, not heterogeneous (the sharpest
   finding).** The deferral named "heterogeneous/empty closed-rec dynamic write." The
   corpus says: **2548 EMPTY** (`out = {}; out[k] = v`, the fresh-table build idiom),
   **≈1 heterogeneous**. The empty case is **implemented** — `index_write_target`
   over an empty closed rec returns `unknown` (no declared field ⇒ no constraint;
   sound because the empty-rec READ rule never admits a value, so the accepted write
   licenses no unsound read). The named un-defer trigger ("rec-field-widening") was
   WRONG for the empty case: no widening is needed; `unknown` is the sound target
   under flow-insensitivity. This is the WRITE dual of the open-row rule, not a
   special case. Corpus marker count `dynamic-index-assign` 3869 → 1321 (−2548).

2. **§9.15.5 (`return f()` multi-spread) has ZERO corpus demand.** Instrumenting the
   spread marker across all 867 files: **0 occurrences.** The per-value `return a, b`
   form (in-subset since increment 5) is universal; the bare-spread `return f()` does
   not occur. Re-deferred as a DEAD deferral — un-defer only if a real site appears.
   A worked example of "verify, don't assume": the deferral was recorded as a likely
   blocker; the corpus says it is not one.

3. **The top tags are dominated by DOWNSTREAM coverage, not the family mechanism.**
   The per-marker reason histogram (the increment-5 harness extended to report each
   marker's FIRING REASON) showed: `multi-assign` (2440 markers) is ~1560
   `local x,y = f(args)` where the producer fn IS recovered but the CALL synth-fails
   on an ARGUMENT or an `unknown` callee — argument-expression coverage, not
   assignment. `multi-return` (1815) is `return a, b` where a VALUE expression
   (`name`/`binop`/`call`) is out-of-subset — value-expression coverage. The
   assignment/return MECHANISMS landed in increment 5; the markers are downstream
   symptoms. Framed as substrate: **argument/value-expression coverage** is the next
   front, NOT more multi-assign/return work.

4. **The `dynamic-index` indexer-union-key residue is an ARITHMETIC-PRECISION gap.**
   The 876 `indexer` reads rejected under a union key are overwhelmingly (1332 incl.
   rwi) `union{integer, number}` — a key that synthesizes to `integer | number`
   because integer arithmetic yields `number`. `number </: integer`, so the access is
   SOUNDLY rejected. Framed as substrate: **integer-preserving arithmetic** (operator
   typing), a different family — NOT an index-rule gap. Adding an "admit number into
   `[integer]`" rule would be unsound special-casing; refused.

5. **The CHECKED-FINDINGS rise (9 → 13) is reach, not regression.** Four files whose
   LAST out-of-subset construct was the empty-rec write now lower past it and reach
   the check stage, surfacing their PRE-EXISTING downstream findings (recursive-type /
   field-path-narrowing type-mismatches — the §9.8 deferral family). Verified: the one
   file with a rejection (`lib/unified/rehype_meta/init.lua`) ALREADY had `rej=1,
   unk=1` at HEAD — the empty-rec change did not introduce it; it only stopped masking
   it earlier. No soundness regression.

**Survivals.** The empty-rec write rule is sound (the read side admits nothing).
Homogeneous and heterogeneous closed-rec writes are unchanged (homogeneous ⇒ `V`,
heterogeneous ⇒ out-of-subset). The §9.15.6 body-synthesized multi-return join is
re-deferred unchanged (behind the shared local-return-type-collection pass). Full
analysis suite green at 6427 assertions (6421 + 6 net); the touched lib file
(`crescent_slice.lua`) typechecks clean (0 errors, same 4 warnings as HEAD — no
regression); 0 TIMEOUT in the e2e survey.

### 10.7 Slice v2 increment 6 — DONE (the empty-fresh-table dynamic write + the diagnose-first re-ranking) (2026-06-12)

Increment 6 (§6.10) burned down the §9.15 deferrals gating the histogram top —
**diagnosis-first, and the diagnosis was the load-bearing result.** Per-marker
corpus measurement (not file-count) showed the three named deferrals were either the
WRONG shape (§9.15.4 is 2548-empty / ≈1-heterogeneous), DEAD (§9.15.5, 0 sites), or
not the actual blocker (the `multi-assign`/`multi-return` tags are downstream
argument/value-expression coverage symptoms — the mechanisms landed in increment 5).

One sound in-fence item landed: the **empty-fresh-table dynamic write**
(`out = {}; out[k] = v`). `index_write_target` over an empty closed rec returns
`unknown` (no declared field ⇒ no constraint; sound because the empty-rec READ rule
admits nothing). ONE branch in ONE function; no new evidence method, no subtype
change, no substrate change (`init.lua` byte-for-byte).

**Survey re-run headlines** (`docs/slice-survey-v1.md`, "after v2 increment 6",
`--e2e`, 867 files): whole-file **CHECKED-CLEAN 25 → 26**, CHECKED-FINDINGS 9 → 13
(reach, not regression — finding 5), OUT-OF-SUBSET 827 → 822, **TIMEOUT 0**. The
CONSTRUCT-histogram delta is the honest progress measure: **`dynamic-index-assign`
fell from #2 (482 files) to #4 (282 files), −200 files; the per-MARKER count fell
3869 → 1321 (−2548, exactly the empty-rec writes).** The corpus 11-fixture split
moved 4 CLEAN / 1 FINDINGS / 6 OUT-OF-SUBSET → **6 CLEAN / 1 FINDINGS / 4
OUT-OF-SUBSET** (pairs_return_leak + table_construction_widening → CLEAN, both their
last boundary), 0 rejections anywhere. The fence held; the substrate was again
**not** touched. Full report:
`docs/artifacts/typechecker-run-2026-06-12/increment-6.md`.

### 9.17 Adversarial audit round 4 — fixes (2026-06-12)

Fixes for the two findings from `docs/artifacts/typechecker-run-2026-06-12/audit-round-4.md`.
Full test suite green at **6467 assertions** (6427 + 40 net).

**Adjudication tally** (round 4): **0 TRUE POSITIVE / 11 FALSE POSITIVE / 2 ANNOTATION-GAP.**
The checker found zero real bugs in the corpus this round; all 13 CHECKED-FINDINGS
rejections were slice precision gaps (11 wrong-rejections) or fenced out-of-subset
annotations (2). This is honest data about where the checker is: the new dynamic-read
and narrowing machinery reaches correct corpus code but lacks the precision to accept
all of it — the precision gaps are exactly the known deferrals (field-path narrowing,
cross-module alias resolution, closure/capability-closure synthesis).

---

#### A-F1 [HIGH soundness]: `rec_with_indexer` dynamic-key READ now unions field types

**Finding (reproduced).** `index_result` over a `rec_with_indexer` under a dynamic
key returned ONLY the index-signature value type `V`, dropping all listed field value
types. A runtime key matching a listed field yields the field's type, not `V`; when
the field and indexer disagree the pre-fix result was unsound (accepted an unsound
return annotation `integer` for a table `{ a: string, [string]: integer }`).

**Root cause.** The `rec_with_indexer` dynamic-key branch (§6.9.2) was a direct copy
of the `indexer`-only path: `return obj_ty.val`. The `rec` (closed, no indexer)
branch immediately below it DOES union the field types (§6.9.2 new rule from
increment 5), but `rec_with_indexer` omitted the equivalent union. The branch text
predated the slice (pass 2, `5f53fff3`) and was unreachable for dynamic reads until
increment 5 routed `t[e]` through `index_result`'s `key_ty` path.

**Fix.** `crescent_slice.lua` `index_result`'s `rec_with_indexer` dynamic-key path:
instead of returning `obj_ty.val`, build `vals = { obj_ty.val }` then append every
listed field's value type and return `G.union(vals)`. No `nil` appended: `key_ty <:
obj_ty.key` means every possible key is covered by the indexer (no key can miss), so
the indexer's `V` already accounts for "any key not matching a listed field". The
AGREEING case (`{ a: integer, [string]: integer }`) normalizes correctly: the union
collapses to `integer`. The §6.9.2 rule is amended above (the bullet now reads
`union(field-value-types) | V`).

**Tests.** Two new direct `index_result` call tests in
`lib/type/analysis/crescent_slice_test.lua` (audit round 4 suite):
- DISAGREE case: `{ a: string, [string]: integer }` dynamic read → `string | integer`
  (not `integer` alone).
- AGREE case: `{ a: integer, [string]: integer }` dynamic read → `integer` (normalized).
- Static read `.a` unchanged: still returns `string` (field type, not indexer val).

Two new e2e tests in `lib/type/analysis/corpus_lower_test.lua`:
- `fixture_rec_with_indexer_dynamic_read`: function declared `-> (string | integer)` is CLEAN.
- Inline: function declared `-> integer` is FINDINGS (type-mismatch, correctly detected).

**Regression.** No pre-existing test broken.

---

#### Dominant false-positive: `and`-guard does not narrow its bare-variable left operand

**Finding (reproduced).** The slice narrows a bare truthy test (`if x then`) but NOT
when `x` is the left operand of an `and`-compound (`if x and <expr> then`). Three
places all required the same fix: (1) the guard recognizer (`recognize_guard` in
`crescent_slice_parse.lua`), (2) the lowering's AST-to-guard-node converter
(`ast_to_guard_node` in `crescent_slice_lower.lua`), and (3) the lowering's variable
extractor (`guard_var` in `crescent_slice_lower.lua`).

**Root cause (recognition).** `recognize_guard` for `and`/`or` required BOTH operands
to be recognized guards; if either returned nil the whole `and` returned nil, losing
the narrowing from the recognized side. A BARE VARIABLE is itself a v1 guard form
(the `truthy` form, present since pass 3); `if x and <unrecognized>` should narrow `x`
via the truthy guard even when `<unrecognized>` fails recognition. For `or` this is
NOT sound (dropping a disjunct forges a false guarantee), so only `and` is relaxed.

**Root cause (lowering).** The same partial-guard problem existed in
`ast_to_guard_node`: `x and <non-guard-AST>` returned nil (the right side failed
conversion), so `guard_var` was never called. Additionally, `guard_var` only checked
the top-level `g.var` and one level of `not`; it returned nil for any `and` guard
(even when both sides were recognized), so `if x and x ~= ""` never narrowed `x`
even with both sides recognized.

**Fix (three touch points):**
1. `recognize_guard` (`crescent_slice_parse.lua`): for `and`, when one side fails,
   return the other (the recognized side is still sound in the truthy branch). For
   `or`, still require both.
2. `ast_to_guard_node` (`crescent_slice_lower.lua`): same relaxation for `and`.
3. `guard_var` (`crescent_slice_lower.lua`): for an `and` guard, recurse into the
   left sub-guard to extract its variable (the left conjunct narrows first; if it
   has a variable, that is the primary refinement target).

**Tests.** Four new tests in the audit round 4 suite in
`lib/type/analysis/crescent_slice_test.lua`:
- `x and <call>` (right unrecognized) → truthy guard for `x`.
- `x and y ~= ""` (both recognized) → `and` guard with both conjuncts.
- `<call> and x` (left unrecognized) → truthy guard for `x`.
- `x or <call>` (right unrecognized) → nil (or must not drop a disjunct).

Three new e2e tests in `lib/type/analysis/corpus_lower_test.lua`:
- `fixture_and_guard_narrows_left`: `if s and s ~= ""` narrows `s` to `string` — CLEAN.
- Inline: `if x and flag` with both recognized narrows `x` to `string` — CLEAN.

**Corpus effect.** The 11 false-positive corpus files from the round-4 audit (`--e2e`)
all retain CHECKED-FINDINGS because their remaining root causes are the documented
§9.8 field-path-narrowing deferral or cross-module alias-resolution precision — not
the bare-variable `and`-guard gap. The bare-variable fix operates correctly on the
probe pattern it was designed for (B5a/B5b/B5c isolation verified CLEAN); the actual
corpus files use FIELD PATHS (`opts_t.title`, etc.) which are the §9.8 deferral and
are not in scope for this fix. **CHECKED-FINDINGS remains 13 (unchanged from round
4 post-increment-6).** The 2 ANNOTATION-GAP files are unchanged (recorded, not checker
work).

**Summary:** the `and`-guard fix is at the right seam — recognition and extraction,
not new semantics — and correctly resolves the probe isolation case. The field-path
version of the pattern remains a §9.8 deferral, trigger for un-deferral is
field-path narrowing.

### 9.18 Mechanization findings — slice v2 increment 7 (§6.11, field-path narrowing)

The §9.8 field-path-narrowing deferral, un-deferred. Design §6.11; full report
`docs/artifacts/typechecker-run-2026-06-12/increment-7.md`. Full analysis suite green
at **6489 assertions** (6467 + 22 net: 19 new field-path/invalidation tests minus the
coinductive deferral assertions replaced by CLEAN assertions). `timeout 30 bin/cr
check` clean on the touched implementation files (`crescent_slice_parse.lua`,
`crescent_slice_lower.lua`: 0 errors).

**The implementation finding — the narrowing CORE needed ZERO changes.** The design's
load-bearing insight held under mechanization: a field path `"x.f"` is an opaque
refinement-target NAME, so `slice_narrow.lua` (the pure refinement function), the
`Guard` grammar, and the `narrow_guard` evidence method (`crescent_slice.lua`) are
**byte-for-byte unchanged**, and the substrate (`init.lua`) is untouched. The path is
threaded through the existing variable-narrowing machinery as a string. The three
seams that changed: (1) recognition (`recognize_guard`/`recognize_cmp`: a bare-truthy
path `if x.f` and a path nil-eq `x.f == nil` carry `var = "x.f"`); (2) lowering (the
`if`-handler synthesizes the path pre-type via `index_result`, binds `"x.f"` as a
synthetic Γ entry, and emits invalidation; `synth_index_expr` consults the path
binding before the declared field read); (3) the invalidation discipline in
`lower_block` (the soundness fence).

**The invalidation rule (the soundness boundary, EXECUTABLE).** A path refinement
dies AFTER any statement that can mutate the path or alias the base: any
call/method-call (a callee may mutate `x.f` through an argument or upvalue — no
escape analysis, so any call invalidates) and any assignment (write-through any
lvalue, since aliasing is undecidable in v1, §6.11.3). Granularity is statement-level,
invalidate-AFTER: the guarded read inside a statement (e.g. `tree_sum(node.left)`'s
argument) reads the live refinement before the call's effect reaches the *next*
statement. The fence is three executable tests (`corpus_lower_test.lua` v2.7
invalidation block): the refinement DIES after a call, after a write-through, and
after the §6.11.3 alias write — each correctly REJECTS the post-mutation read. A
direct probe confirmed the narrowing produces the CORRECT refined type (`if
n.children then ipairs(n.children)` is CLEAN), so the residual findings below are
soundness-of-rejection-correct precision boundaries, never wrong types.

**Corpus effect (e2e survey, 867 files, honest numbers).**

| Class | Baseline (HEAD `b4559472`) | Increment 7 | Δ |
|---|--:|--:|--:|
| CHECKED-CLEAN | 26 (3.0%) | 26 (3.0%) | — |
| CHECKED-FINDINGS | 13 (1.5%) | 16 (1.8%) | +3 |
| OUT-OF-SUBSET | 822 (94.8%) | 819 (94.5%) | −3 |

- **The coinductive fixture (the §9.8 trigger fixture) moved FINDINGS → CLEAN** —
  whole-file, 0 markers, 0 rejections. The exact deferral that fired three times is
  closed. (The fixture is in `lib/type/analysis/corpus/`, excluded from the 867-file
  survey set, so it does not appear in the table; it is the increment's headline
  acceptance result.)
- **Three files moved OUT-OF-SUBSET → CHECKED-FINDINGS** (`agent/preset.lua`,
  `unified/rehype_shift_heading/init.lua`, `unified/rehype_urls/init.lua`): field-path
  narrowing unblocked their lowering past a prior out-of-subset marker, so they now
  lower far enough to REACH their next boundary (a cross-module `HastNode` alias / a
  visitor-callback `unknown` return), surfaced as a `type-mismatch`. This is forward
  progress (more of each file lowers), not a regression — the marker is a sound
  refusal (`emit_check_against` marks only when `is_subtype` genuinely fails; the
  substrate has 0 rejections), and the narrowing itself produces correct types.
- **The 11 round-4 false-positive corpus files do NOT all clear.** Field-path
  narrowing was ONE of several compounding root causes. The honest per-file next
  boundary:
  - `rehype_meta`, `rehype_document`, `rehype_infer_title` — the `if opts_t.title and
    …` narrowing now works (verified in isolation, CLEAN), but each compounds with a
    cross-module `HastNode` alias and `el()`/`text()` module-local functions whose
    returns are `unknown` (the §6.8 closure/unannotated-named synthesis boundary). Next
    boundary: **cross-module alias resolution + unannotated-module-function return
    synthesis.**
  - `taskgraph/frontier`, `type/v7_mr0/fixtures` — cross-module `FrontierNode` write /
    deeply-optional record literals. Next boundary: **cross-module value-type
    resolution** (the §9.10 trusted-boundary deferral), not field-path narrowing.
  - `agent/render` — `pairs(task_inputs)` keys typed `unknown` + cross-module
    `val_to_str`. Next boundary: **`pairs`-key typing + cross-module resolution**, not
    field-path (the guards are `if v ~= nil` over a `pairs` loop variable, not a path).
  - `base64url`, `math/init`, `caps/kv`, `caps/time` — `unknown`-claim ABSTENTIONS
    (cross-module value-type / capability-closure / closure-check synthesis). Next
    boundary: **module-value-type / closure synthesis** (§9.13), unrelated to paths.
  - `socket/init` — `xmodule-alias-error` (sibling-alias resolution). Next boundary:
    **cross-module sibling-alias import** (§9.11), unrelated to paths.

**Deferrals recorded (un-defer triggers).**

- **Depth-2 paths (`x.f.g`).** §6.11.1 set the depth bound at 1, justified by the
  corpus (the only depth-2 reads are unconditional writes through casts, not guarded
  narrowing sites). Un-defer: a real guarded `x.f.g` read in a `lib/` file. Strictly
  additive (a longer path string, the same opaque-name machinery).
- **Call-invalidation relaxation (purity/effects).** The conservative "any call
  invalidates a mutable-base path refinement" is sound without escape analysis but
  imprecise: a provably-pure callee, or a base proven not to escape, would let the
  refinement survive. Un-defer: a purity/effects substrate (`docs/effects.md`) that
  lets the slice prove a callee pure and a base un-escaped. Recorded honestly as the
  imprecision the conservative rule accepts.
- **Readonly-field survival is implemented in principle, untested by corpus.** §6.11.2
  derives that a readonly path refinement survives calls/writes (no write can reach a
  readonly field). The corpus's narrowed paths are all mutable record fields, so this
  is a soundness-completeness statement; if a readonly narrowed path appears, it is the
  acceptance test for the readonly-survival branch.

**Regression.** No pre-existing test broken; the only updated tests are the
coinductive fixture's (FINDINGS → CLEAN) and the 11-fixture honest-split tally
(7 CLEAN / 0 FINDINGS / 4 OUT-OF-SUBSET, was 6 / 1 / 4).

### 9.19 Mechanization findings — slice v2 increment 8 (§6.12, dependency-ordered alias declaration)

The §9.8 / §9.11 two-phase-alias deferral, un-deferred for its ACYCLIC case. Design
§6.12; full report `docs/artifacts/typechecker-run-2026-06-12/increment-8.md`. Full
analysis suite green at **6501 assertions** (6489 + 12 new). `timeout 30 bin/cr check`
clean on the three touched implementation files (`crescent_slice_parse.lua`,
`crescent_slice_lower.lua`, `crescent_slice_xmodule.lua`: 0 errors; lower's 20
warnings are pre-existing nested-closure signature notes, unchanged from HEAD).

**The diagnosis ranked dependency-ordered alias declaration FIRST.** Probing the
corpus for the forward-sibling FORM (an alias whose body names a sibling declared
later in the same batch) found **154 references across 29 files**, split by a cycle
test into **63 pure-forward (acyclic) refs / 16 files** (the target) and **55 cyclic
(mutual) refs / 21 files** (the multi-binder-μ substrate gap, deferred below). It beat
the coverage-frontier top forms (`dynamic-index` 510, `multi-assign` 452,
`multi-return` 317) on soundness-value × demand: a precision fix converting an honest
forward-reference ERROR into the CORRECT resolved type, the literal §9.8/§9.11 named
deferral, largest named precision form measured.

**The implementation finding — `declare_alias` needed ZERO changes.** The derived
whole (§6.12.2) held: a forward-sibling reference is a DECLARATION-ORDER problem, not a
per-alias-machinery problem. `alias_decl_order` (pure DFS topo, on-stack cycle
detection) feeds the unchanged `declare_alias` in dependency order;
`declare_aliases_ordered` attributes per-input-index results back to source lines.
Self-reference is excluded from the batch edge set (it is already μ-bound), and an
independent batch reproduces source order byte-for-byte. Wired into BOTH the in-file
path (`scan_source`) and the cross-module import path (`import_top_level_aliases`,
collision check unaffected by intra-module reorder).

**The soundness fence (EXECUTABLE).** A genuine mutual cycle (`A ↔ B`) is NOT silently
resolved — whichever member declares first names a not-yet-present sibling and errors
honestly, the SAME behavior as today. A `declare_aliases_ordered` test asserts the
cycle errors (`T.fail(res[1].ok and res[2].ok)`); the forward-sibling and parent-union
tests assert clean resolution; an `alias_decl_order` test asserts a dependency
precedes its dependent. Cross-module: a test imports a module whose `server_socket`
forward-references `server_client` and asserts `#errors == 0`.

**Corpus effect (e2e survey, 867 files, honest numbers).**

| Class | Increment 7 | Increment 8 | Δ |
|---|--:|--:|--:|
| CHECKED-CLEAN | 26 | 27 | +1 |
| CHECKED-FINDINGS | 16 | 15 | −1 |
| OUT-OF-SUBSET | 819 | 817 | −2 |
| NO-ANNOTATION | 6 | 8 | +2 |

- **`lib/socket/init.lua` moved FINDINGS → CLEAN** (rej=0, unk=0, 0 markers): it
  imports `lib/socket/server.lua`, whose `server_socket → server_client` forward
  reference now resolves under dependency ordering, clearing the `xmodule-alias-error`
  that was its only finding. This is the +1 CHECKED-CLEAN and the −1 CHECKED-FINDINGS.
- **Two files moved OUT-OF-SUBSET → NO-ANNOTATION** (+2 / −2): their own alias batch
  now resolves cleanly, so the markers that had blocked them are gone and no requested
  claim remains. Forward progress — alias resolution no longer blocks them.
- **Annotation-grammar survey** (`docs/slice-survey-v1.md`, regenerated): CHECKED-CLEAN
  489 (unchanged — the annotation survey parses each annotation against a FLAT env, so
  the batch-ordering benefit surfaces in the e2e path, not here), `unknown-type-name`
  collapsed bucket 152 → 151, OUT-OF-SUBSET 241 → 240.
- **The non-clearing findings files are unchanged in cause** — their next boundaries
  (cross-module `HastNode`/`FrontierNode` value-type resolution, `el()`/`text()`
  unannotated-function returns, `pairs`-key typing, capability-closure synthesis,
  module-value-type abstention) are all unrelated to forward-sibling alias ordering, as
  §9.18 already named. `lib/tcp/client.lua` still errors via `lib/ljsocket`'s
  `LjSocket` — but the cause is the **tuple type `{ A, B }`** (`timeout_connected`), a
  SEPARATE deferral (below), confirmed by `LjSocket`'s `alias-error` being
  `{ T } list shorthand must be a single type`, not a forward reference.

**Deferrals recorded (un-defer triggers).**

- **Cyclic (mutual) alias families — multi-binder μ.** A genuine mutually-recursive
  family (`A` names `B`, `B` names `A`) cannot be ordered into resolution; slice_ty's μ
  is single-binder (de Bruijn, one variable), so a family of N mutually-recursive
  equations is a substrate gap. Measured trigger has fired: **55 cyclic refs across 21
  files** (`Expr`/its members where members reference back into `Expr`, `Machine`/
  `Instance`, `CFG`/`Func`, …). Un-defer: a multi-binder μ in slice_ty (a system of
  simultaneous recursive type equations) that lets a family resolve as one fixed point.
  NOT hardcoded — the cyclic case keeps the honest error until the substrate exists.
- **Tuple type `{ A, B }` (fixed positional/heterogeneous list).** ≈1 corpus site
  (`ljsocket`'s `timeout_connected: { string | nil, string | integer | nil }`), which
  blocks `LjSocket` and, transitively, `tcp/client`. The parser rejects a brace group
  with a top-level comma and no `key:`/`[K]:` as "list shorthand must be a single
  type." Un-defer: implement the `tuple` Ty kind at the annotation-grammar seam (the
  kind already exists in slice_ty for function params/returns; it needs to be admitted
  as a standalone table type). Low demand; deferred behind the cyclic-family substrate.

**Regression.** No pre-existing test broken. The 12 new tests are forward-sibling
resolution (`server_socket`/`Expr`-union), the independent-batch source-order
invariant, the mutual-cycle honest-error fence, the `alias_decl_order` precedence
assertion, and the cross-module forward-sibling import.

### 10.8 Slice v2 increment 8 — DONE (dependency-ordered alias declaration) (2026-06-12)

Un-deferred the §9.8/§9.11 two-phase-alias deferral for its acyclic case (§6.12,
§9.19). Forward-sibling alias references resolve under a topological declaration order
(pure graph topology, `declare_alias` unchanged); genuine mutual cycles stay an honest
error behind the multi-binder-μ substrate deferral. e2e: CHECKED-CLEAN 26 → 27,
CHECKED-FINDINGS 16 → 15, OUT-OF-SUBSET 819 → 817 (`lib/socket/init.lua` FINDINGS →
CLEAN). Suite green at 6501 assertions. Survey re-run headlines:
`docs/slice-survey-v1.md`, "after v2 increment 8".
