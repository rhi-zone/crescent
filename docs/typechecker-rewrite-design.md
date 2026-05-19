# Typechecker rewrite design

## 0. Frame

This document is a clean-room design for crescent's typechecker, derived from
the set-theoretic foundation committed to in `docs/type-system.md` (commit
b4bb9667) and the feature surface in `docs/typechecker-reference.md`, checked
against published external references on constraint-based subtyping and
set-theoretic types. The reference points are Parreaux's *simple-sub* (ICFP
2020), its negation-aware extension *MLstruct* (Parreaux & Chau,
OOPSLA 2022), and the *semantic subtyping* line of work by Frisch, Castagna,
and Benzaken (LICS 2002; JACM; PPDP/ICALP 2005). The design is meant to be
implementable from those references plus the canonical crescent docs alone.

This document is *not* a description of any code currently in
`lib/type/static/`. None of the existing implementation files were read in
the preparation of this document. Where this design contradicts code that
exists today, the design wins — that is the entire point of writing it. The
existing implementation is treated as suspect and will be replaced; reasoning
about what it does now is precisely the contamination this rewrite is meant
to escape.

## 1. Foundation recap

From `type-system.md` and `typechecker-reference.md`, the type lattice
crescent has committed to is a *set-theoretic lattice with first-class
complement*. Every type denotes a set of runtime values, and the operations
on types are the boolean-algebra operations on those sets.

### 1.1 Type constructors

- **Primitives.** `nil`, `boolean`, `number`, `integer`, `string`, `cdata`,
  with `integer <: number`.
- **Literals.** `42`, `"GET"`, `true`. Each literal is a singleton subtype of
  its base primitive.
- **Top and bottom.** `unknown` (top, callers must narrow), `never` (bottom,
  uninhabited). `any` is distinguished from `unknown`: it is a bilateral
  escape hatch, not a top type.
- **Products / records.** `{ a: A, b: B }`. Optional fields, readonly fields,
  open/closed row, named-field-plus-indexer mixtures. Tuples
  `{ A, B, C }` are tables with positional integer-literal slots.
- **Indexers.** `{ [K]: V }`. Distinct from open-row `...`.
- **Functions.** `(A, B) -> C`, contravariant in parameters, covariant in
  return. Multi-return as a return-position tuple. Varargs as a trailing
  spread parameter.
- **Fixed points.** Equi-recursive types with lazy expansion. The lattice
  closes under recursion via a `μX. T` constructor.
- **Universal quantification.** `<T>(...)`. Full rank-N supported at call-site
  subsumption (skolemize, check escape, deep-skolemize at subsumption per
  Peyton Jones et al. 2007). Bounds `<T: U>` are structural subtyping
  constraints.
- **Type-level functions.** Generic aliases `Foo<T, U> = ...` and match-type
  evaluators `match X { P1 => R1 | P2 => R2 }`.
- **Nominal opaqueness.** `newtype`, `opaque`, `private` — identity wrappers
  whose denotation is the underlying set tagged with a fresh nominal token,
  so structural equivalence does not unify them.
- **Indexed access.** `T["k"]`, `T[K]` — projection on a type expression.
  First-class lattice operation with distribution rules: `T[K1 | K2] =
  T[K1] | T[K2]`. Negated keys are accepted: `T[~"x"]` is the type of
  fields whose key isn't `"x"`. Against an unbound key-type-variable,
  indexed access becomes a deferred constraint (resolved when the variable
  is bound), analogous to suspended match-type evaluation. Expected
  semantics on the three record shapes:
  - Closed record `{ "x": A, "y": B }`: `T[~"x"] = T["y"] = B`.
  - Open record `{ "x": A, ... }`: `T[~"x"]` includes the row-variable's
    unknown keys, so the result may be wider than the user expects
    (e.g. `A_other_fields | unknown`). Not unsound; honest.
  - Indexer-typed record `{ [string]: V }`: `T[~"x"] = V`.

### 1.2 Boolean operations

The lattice is closed under three boolean operators:

- **Union** `A | B` — set union.
- **Intersection** `A & B` — set intersection.
- **Complement** `~T` — the set of values not in `T`. Involutive (`~~T = T`),
  De Morgan dualizes union and intersection, `~never = unknown`,
  `~unknown = never`.

These are first-class: any well-formed type expression can appear inside any
boolean operator, and the type system reasons about them under boolean-algebra
laws — distributivity, absorption, complement, involution.

### 1.3 Subtyping as the primary relation

The semantic interpretation of `A <: B` is "the set denoted by A is a subset
of the set denoted by B." Every other notion — assignability, conformance,
overload resolution, exhaustiveness, narrowing — reduces to subtyping queries
on this lattice. There is no separate "assignability" relation that differs
from subtyping; there is no special equality relation that is not "subtype in
both directions."

### 1.4 Narrowing as intersection

Flow-sensitive refinement is *intersection with the discriminating type or
its complement*. After `if type(x) == "string"`, the type of `x` is
`T & string` in the truthy branch and `T & ~string` in the falsy branch.
Discriminant-field narrowing, `nil` guards, literal-equality tests, and
user-defined `x is T` predicates all desugar to this single primitive.

This is the single most important consequence of committing to complement.
Narrowing was previously a separate calculus full of special cases; it now
collapses to a uniform operation that the subtyping algorithm already has to
support to handle `~T` annotations.

## 2. Subtyping algorithm

### 2.1 Choice of algorithm: MLstruct-style constraint solving

The chosen algorithm is *constraint generation plus per-variable lower/upper
bound propagation*, in the lineage of MLsub → simple-sub (Parreaux 2020) →
MLstruct (Parreaux & Chau 2022). "Bisubstitution" is MLsub's
(Dolan 2017) framing; simple-sub and MLstruct deliberately replace it with
the explicit bounds-on-variables construction (§3.2 of the MLstruct paper):
"the constraint solver attaches a set of lower and upper bounds to each type
variable, and maintain[s] the transitive closure of these constraints." We
use that construction; we keep the word "bisubstitution" only as a pointer
to the MLsub lineage, not as the operation performed.

This is one of two viable algorithmic families for a set-theoretic lattice:

1. **Set-theoretic / CDuce-style** (Frisch, Castagna, Benzaken). Subtyping is
   decided by checking emptiness of types in a syntactic boolean algebra; the
   algorithm puts types in a disjunctive normal form (DNF) of atoms and
   reduces `A <: B` to `A & ~B = never`. Strong on full negation and pattern
   exhaustiveness; weak on type inference (CDuce historically required
   annotations).
2. **Constraint-based / simple-sub-style** (Parreaux). Subtyping is decided
   incrementally during inference by attaching polar lower and upper bounds
   to each type variable; user-facing types are recovered by coalescing those
   bounds into a compact form with unions, intersections, and recursive
   wrappers. Strong on inference (principal types, no annotations needed);
   originally lacked negation.

MLstruct is the synthesis: it extends simple-sub's constraint-based inference
with structural negation, putting constraints in *reduced disjunctive normal
form* (RDNF, §5.2 of the paper — a DNF in which incompatible intersections
and unions are reduced to ⊥ and ⊤) and using the boolean-algebra laws to
decide subtyping at constraint-solve time. RDNF is indexed by a level: level-0
RDNF does not contain class or alias types at the top level (they have been
expanded); level-1 RDNF retains them. This is the design
crescent should target because:

- Crescent's commitment to "infer aggressively, widen reluctantly" (Principle 1
  of `type-system.md`) requires principal-type inference, which the
  constraint-based line gives and the set-theoretic line does not.
- The complement operator `~T` is now part of the surface syntax, so
  whichever algorithm is chosen must handle negation natively. Bolting
  negation onto simple-sub is the work MLstruct already did.
- Pattern-exhaustiveness checking (match types, narrowing) needs the DNF
  emptiness check that CDuce provides; MLstruct retains that as a subroutine
  inside the inference framework.

### 2.2 Sketch of the algorithm

#### Constraint generation

The checker walks the program AST and emits constraints of the form
`A <: B`. Variables introduced by `let`, function parameters, and unknown
intermediate expressions become *type variables*, each carrying a *lower
bound* and an *upper bound*. As the walk encounters operations, it emits
constraints that incrementally tighten those bounds.

For a function call `f(x)`:
- `f` has some type `Tf`. Fresh variables `α` (param) and `β` (return) are
  created. Constraints emitted: `Tf <: α -> β`, `Tx <: α`. The call
  expression's type is `β`.

For a field access `x.k`:
- Fresh `α`. Emit `Tx <: { k: α, ... }`. Expression type is `α`.

For an annotation `--: T` on `expr`:
- Emit `Texpr <: T` (and depending on the form, `T <: Texpr` for mutual
  equality on local bindings — see `type-system.md` §"typeof in function
  signatures").

#### Bound propagation

When `A <: B` is solved with at least one variable on either side (MLstruct
§3.2):

- If `α <: T` and `T` is a non-variable type, add `T` to `α`'s *upper bound*.
  Then for every existing lower bound `L` of `α`, emit `L <: T` to maintain
  the transitive closure (the invariant: union of lower bounds always remains
  a subtype of the intersection of upper bounds).
- If `T <: α`, add `T` to `α`'s *lower bound*. For every existing upper bound
  `U` of `α`, emit `T <: U`.
- If `α <: β`, link the two variables: `β`'s lower bounds flow into `α`'s
  lower bounds, `α`'s upper bounds flow into `β`'s upper bounds.

A cache of in-progress subtyping relationships is mandatory: type-variable
bound graphs may contain cycles, and since types are regular the cache
guarantees termination — when a constraint already in the cache is
re-encountered, it is assumed to hold and the recursion stops (MLstruct §3.2).

The property carried over from MLsub: a type variable accumulates a union of
lower bounds and an intersection of upper bounds. Inference never needs to
commit to a single representative; it accumulates both extremes and defers
the choice until coalescing.

#### Non-variable decomposition

When both sides of a constraint are non-variable, decompose by structure:

- `(A1, A2) -> B <: (A1', A2') -> B'` → `A1' <: A1`, `A2' <: A2`, `B <: B'`
  (contravariant params, covariant return).
- `{ k: A } <: { k: B }` → `A <: B`. Width subtyping handled by closed vs
  open rows.
- `A | B <: C` → `A <: C` and `B <: C`.
- `A <: B & C` → `A <: B` and `A <: C`.
- `A <: B | C` — non-trivial; see §2.4.
- Two atomic types (e.g. `integer <: number`): consult a fixed lattice.
- Mismatched constructors: error.

#### Complement decomposition

This is the MLstruct contribution (§3.3, §5.2). With `~T` in the language,
constraints like `A <: ~B` and `~A <: B` arise. The solver does *not* in
general treat them as a generic "emptiness check": MLstruct's actual
algorithm is to merge `A` and `¬B` into a single normal form and reduce a
constraint `A <: B` to deciding `dnf₀(A ∧ ¬B) <: ⊥` against a structured
shape (§5.3, rule referencing `dnf₀(τ₁ ∧ ¬τ₂)`). Constraints are normalized
to the shape `τ_con <: τ_dis` where (§3.3.2):

- `τ_con` is `⊤`, `⊥`, or an intersection of a non-empty subset of
  `{ #C, τ₁ → τ₂, { x : τ } }` (one nominal tag, one function shape, one
  record-field shape — at most one of each).
- `τ_dis` is `⊤`, `⊥`, `(τ₁ → τ₂) ∨ #C`, `{ x : τ } ∨ #C`, or `#C ∨ #C'`.

Reaching this shape always leaves at most one matching pair across the two
sides, so the constraint reduces to a single smaller subtype obligation on
matching constructors — preserving losslessness and therefore principal
types. Different constructor shapes are disjoint by design (function values
are not records), and same-shape obligations reduce by structural
decomposition.

**Naked vs. operational negation.** MLstruct (Parreaux & Chau, OOPSLA 2022,
v8.0, §2.2.5 footnote 10) observes that **naked** negation of a function or
record type — `¬(τ₁ → τ₂)` or `¬{ x : τ }` considered as a standalone type
representing "everything in the universe that isn't this function/record" —
is a peculiar object: algebraically well-defined as the Boolean complement,
but with a value-domain extension that is large, unenumerable, and not
something a user would write down by choice. Only **negation on nominal
tags `¬#C`** has the intuitive "all values not of tag C" reading as a
free-standing type. The CDuce/Frisch/Castagna/Benzaken line takes the
opposite trade: fully set-theoretic negation at the cost of giving up
principal type inference. We follow MLstruct.

This is a caveat about how to *think* about naked `~T`, not a constraint on
what crescent supports. In crescent's actual uses of negation — narrowing,
match-type wildcards, discriminated-union dispatch — negation never appears
naked. It always appears in intersection with a positive type, where it
does the useful work of removing one alternative from a known union. Worked
example:

```
(A | B | (A → B)) ∩ ¬(A → B)
  = (A ∩ ¬(A → B)) | (B ∩ ¬(A → B)) | ((A → B) ∩ ¬(A → B))    -- distrib.
  = A | B | ⊥                                                  -- T ∩ ¬T = ⊥;
                                                                  cross-shape
                                                                  disjointness
  = A | B
```

The same derivation handles discriminated-union narrowing structurally:
`({ kind: "foo", ... } | { kind: "bar", ... }) ∩ ¬{ kind: "foo", ... }`
reduces to `{ kind: "bar", ... }` by distribution and self-cancellation of
the matching disjunct.

**Implementation discipline.** The simplifier MUST distribute intersection
over union and MUST recognize `T ∩ ¬T = ⊥` (the latter is already part of
RDNF reduction in §5.2). With those two rules, the simplifier collapses
`(... | T | ...) ∩ ¬T` to `(... | ...)` automatically, and the "essentially
uninhabited" worry of the naked frame does not arise in practice because
naked negation does not survive simplification when a positive context is
present. No surface-syntax restriction on `~T` is necessary or appropriate:
users may write `~T` for `T` of any shape (function, record, nominal,
union, intersection), and the simplifier handles it uniformly.

**DNF emptiness checking is deferred until forced, not universal.** DNF
emptiness is worst-case exponential in the number of conjuncts, but it
does not need to be run on every constraint. Emptiness checks only fire at
specific decision points: subtype queries involving non-trivial negation,
match-arm dispatch against negated atoms, and narrowing-simplification of
complex inputs. The solver therefore (a) defers emptiness checks until a
decision point forces one, (b) caches results keyed on the post-
simplification form, and (c) times out on pathological cases with a
diagnostic pointing at the originating expression. The "competitive with
tsgo" bar is met by avoiding gratuitous checks, not by adopting a more
restricted boolean algebra.

For match-type wildcards over record/function patterns — e.g.
`MetaOf<T> = match T { { #...%M } => M, _ => nil }` where the `_` arm
desugars to `~{ #...%M }` — the dispatch decision is a disjointness check
on `T` against the pattern, not an inhabitation check on `~{ #...%M }`. The
"essentially uninhabited" concern is therefore structurally irrelevant to
match-type semantics: the wildcard's complement type is never asked "what
values are you?", only "is the scrutinee disjoint from the other arms?".

#### Coalescing (user-facing recovery)

After inference finishes, type variables with accumulated bounds are
*coalesced* into user-facing types: a variable appearing positively becomes
the union of its lower bounds; a variable appearing negatively becomes the
intersection of its upper bounds. Recursive bounds (a variable whose bounds
mention itself) become a `μX. ...` wrapper, detected by hash-consing during
the walk (Parreaux 2020).

A simplification pass merges co-occurring variables, drops dominated bounds,
and produces a compact normal form for display and for caching.

### 2.3 Why not "decide subtyping syntactically"

A naive subtyping algorithm matches on type-tag pairs and dispatches one rule
per (tag, tag) combination. This is what generates the kind of ad-hoc,
quadratic, per-feature dispatch the rules in CLAUDE.md call out as
"context-poisoning." The constraint-based algorithm has the opposite
property: it expresses subtyping as a small set of structural decomposition
rules plus an emptiness check; new type constructors plug in by defining
their decomposition rule and their behavior under boolean operations, not by
adding cases to a giant matrix.

### 2.4 Constraints with unions/intersections and a variable

Constraints of the shape `τ₁ <: τ₂ ∨ α` or `α ∧ τ₁ <: τ₂` cannot be
decomposed by structural recursion alone without losing information or
backtracking. MLstruct (§3.3.1) resolves this by *moving the non-variable
part to the other side using negation*:

- `τ₁ <: τ₂ ∨ α` is rewritten to `τ₁ ∧ ¬τ₂ <: α` (a new lower bound for `α`).
- `α ∧ τ₁ <: τ₂` is rewritten to `α <: τ₂ ∨ ¬τ₁` (a new upper bound for `α`).

When both transformations apply, either choice is sound. This is the central
use of negation in the solver: it is what lets union/intersection constraints
involving variables make progress without backtracking, preserving principal
types. For the variable-free case, see §2.2 above (RDNF normalization).

## 3. Constraint vocabulary

The solver should expose a single primitive constraint type:

- **`A <: B`** — subtype constraint. All other inference obligations reduce
  to this.

Equality `A = B` is `A <: B ∧ B <: A`. Type-level match-arm matching reduces
to subtyping plus emptiness (see §5).

Beyond the primitive there are two derived obligations whose presence in the
queue is observable but which are *expressed* in terms of subtype constraints:

- **Match-type evaluation pending** — a marker on a pending type
  `match X { ... }` whose scrutinee `X` contains unresolved variables. Once
  `X` is sufficiently determined, the marker fires arm-matching constraints.
- **Skolem escape check** — emitted at a rank-N call site when a forall is
  instantiated. The check is "no skolem variable appears in the
  post-coalescing principal type of the caller's context."

There are no constraint kinds for "this is a function," "this supports
arithmetic," "this is iterable," etc. Those are *uses*; they all reduce to
`A <: <some structural shape>`. The rule in `type-system.md` §10 ("prefer
principled solutions over special cases") and the
`lib/type/static/CLAUDE.md` warning ("Never add a new predicate or special
case to the solver") are upheld by construction: the algorithm has nowhere
to put a new predicate.

The closed set of constraints is `{ <: }`, full stop.

### 3.1 Effect tracking

Crescent commits to effect tracking when language features require it.
Coroutines need it (yield as a typed effect). `pcall`/`error` likely needs
it (throw as a typed effect). Async/await, if added, needs it (await as an
effect). The scope is: track which effects appear, infer them on function
types, allow user annotation.

The initial effect set is small and extensible per-feature: `yield` and
`throw` to start, with new effects added as features land. Crescent
deliberately does **not** design a full Koka/Eff row-of-effects calculus
upfront — the row-of-effects machinery is heavy, and committing to it
before more than two effects exist would over-engineer the surface. The
constraint vocabulary therefore stays `{ <: }`: effects ride on function
arrow types as an additional, structurally compared component, and effect
subtyping reduces to subset constraints on effect labels, which is itself
a `<:` query.

## 4. Type representation

Following Parreaux's distinction:

### 4.1 Simple types — the inference-time representation

A *simple type* is one of:

- a primitive token,
- a literal,
- a constructor application: `Fn(params, ret)`, `Rec(fields, row, meta)`,
  `Ind(K, V)`, `Tup(slots)`, etc.,
- a type variable `α` carrying mutable `lower_bounds : list<SimpleType>` and
  `upper_bounds : list<SimpleType>`,
- a boolean combination: `Union(A, B)`, `Inter(A, B)`, `Neg(T)`,
- a quantifier wrapper: `Forall(αs, T)`, `Skolem(α, level)`,
- a recursive wrapper: `Mu(X, T)`.

Simple types are *not* normalized eagerly. Constraint solving manipulates
them in their raw form; only when the user observes a type (error message,
hover, generalization checkpoint) is it coalesced.

This is critical for performance: eagerly normalizing every intermediate
constraint to DNF would blow up exponentially on union/intersection-heavy
programs.

### 4.2 RDNF — the normal form used by the solver and by display

MLstruct uses *reduced disjunctive normal form* (RDNF, §5.2). A type in
RDNF has the shape:

```
⋁_i  (  P_i_fn?  ∧  P_i_rec?  ∧  P_i_tag?  ∧  ⋀_j ¬N_ij  )
```

where each disjunct contains **at most one positive function-arrow shape,
at most one positive record-field shape, at most one positive nominal tag**,
plus a set of negated atoms. Incompatible intersections (two unrelated
nominal tags, distinct top-level constructors of the same kind) reduce to
⊥; identifications such as `{x:τ} ∨ (π₁ → π₂) ≡ ⊤` reduce to ⊤. RDNF is
indexed by level: level-0 has all class/alias types expanded; level-1
retains them.

The "compact type" terminology is from simple-sub (Parreaux 2020) and refers
to the coalesced display form. In MLstruct, the same display form is
recovered by running the simplification pipeline (§3.5: removing polar
occurrences of variables, removing variables sandwiched between identical
bounds, hash-consing recursive types, plus Boolean-algebra simplifications
on unions/intersections/negations such as distributivity and factorization).
Concretely: RDNF is the solver-internal normal form; the user-facing
"compact type" is RDNF plus those simplifications.

Hash-consing on the post-simplification form yields structural equality,
which the rest of the system (subtyping cache, match arm dispatch, IDE
hover) can rely on.

**Practical note (MLstruct §3.3.2 last paragraph, footnote 25):** the
implementation does not always put the *entire* constraint into RDNF when
that would do needless work. On-the-fly decomposition (as sketched in §2
above) is used where it suffices; full RDNF normalization is invoked when
the constraint's shape requires it. This is a performance, not soundness,
distinction.

### 4.3 Why design from scratch

The shape of the in-memory representation is load-bearing. A representation
that bakes in a fixed tag-set with one slot per "kind of type" forces the
solver to special-case each kind. A representation built around constructor
application + a uniform boolean-combination layer is open: adding a new
constructor adds one decomposition rule and inherits boolean handling for
free.

The crescent rewrite should use the constructor-plus-boolean form. The
existing in-memory layout is not a constraint on this design.

## 5. Match types

`match X { P1 => R1 | P2 => R2 | ... | _ => Rn }` is a type-level function
from the lattice to itself. Per `typechecker-reference.md`, `_` is sugar for
`~(P1 | P2 | ... | Pn-1)` — the complement of the union of the explicit
arms' patterns. So a match expression with N arms is a function of the
scrutinee `X` defined piecewise on a *disjoint partition* of the lattice.

### 5.1 Arm-matching as subtyping plus emptiness

The arm `Pi => Ri` *fires* on a scrutinee `X` when `X <: Pi`. Because `_`
desugars to a complement of the other patterns, the arms are exhaustive and
disjoint by construction, and "the arm that fires" is well-defined.

The primitive operation is therefore: given `X` and `Pi`, decide one of

- **fires** (`X <: Pi`),
- **never fires** (`X & Pi <: never`),
- **suspended** (neither holds yet because `X` mentions unresolved variables).

This is two subtype queries plus the standard emptiness check. No new solver
primitive.

### 5.2 Capture binding

A pattern can contain captures `%P`. Successful match must produce a binding
`P ↦ T_P` such that substituting back into `Pi` yields a supertype of `X`.
This is the *backward* direction — taking `X <: Pi[P ↦ ?]` and solving for
`?`. The standard treatment is to fresh-bind a variable for each capture,
add the constraint `X <: Pi[P ↦ α_P]`, and let the constraint solver compute
`α_P`'s bounds. The arm's result `Ri` is then computed in the environment
extended with `P ↦ α_P` (coalesced).

This makes forward and backward arm-matching symmetric: both are subtype
queries on the same lattice with the same solver. There is no separate
"pattern matching algorithm."

### 5.3 Suspension and commit

If `X` is fully resolved at the point the match is evaluated, the result is
determined: exactly one arm fires (because `_` was desugared into the
complement; the union of all arms exhausts the lattice). The solver
substitutes and returns the corresponding `Ri`.

If `X` contains free type variables whose bounds do not yet determine
`X <: Pi` for any single arm, the match-type evaluation *suspends*. The
pending evaluation parks on a watchlist for those variables; when their
bounds tighten sufficiently to determine an arm, the suspension fires.

Suspension is preferable to splitting (taking the union over all possibly
matching arms) because it preserves principal types. Splitting is permitted
as a last resort if a variable's bounds are sealed (generalization
boundary), in which case the result type is the union of the result types of
each arm that may still fire.

## 6. Rank-N polymorphism

A function with an explicit `<T>` quantifier denotes a polymorphic type.
Use sites split into two cases:

- **Rank-1 use** (the function itself is called): instantiate the quantifier
  at the call site with fresh variables and let inference flow.
- **Higher-rank use** (the polymorphic function is passed as an argument):
  the parameter type is a `forall`. Subsume by *skolemization*: replace each
  bound variable in the forall with a fresh skolem constant, then check the
  argument's type against the skolemized body. After the body check, perform
  an *escape check*: no skolem may appear in the principal type of any
  context that outlives the call.

Crescent commits to **full rank-N polymorphism**, not predicative-only.
The foundation is simple-sub's level-based generalization plus MLstruct's
`#F` flexible nominal tags as skolems; lifting to full rank-N requires
deep-skolemization at subsumption points per Peyton Jones et al.,
"Practical type inference for arbitrary-rank types" (2007). This is
non-trivial but well-trodden. With set-theoretic types, the skolem appears
as an opaque atomic constructor in the lattice; emptiness and subtyping
treat it the same way they treat any nominal opaque type.

**Relation to MLstruct.** MLstruct itself is rank-1: polymorphism in λ¬ is
attached solely to top-level `def` bindings (§4.1.1), and local `let` is
desugared to immediately-applied λ (i.e., monomorphic). Let-polymorphism is
explicitly described as "orthogonal to the features presented in this paper,
and can be handled by using a level-based algorithm [Parreaux 2020] on top
of the core algorithm." Rank-N is therefore **not** a feature of the MLstruct
paper.

However, MLstruct's subsumption check (§3.4, `≤@`) already contains the
machinery rank-N needs: to decide `∀Ξ₁. τ₁ ≤@ ∀Ξ₂. τ₂`, it instantiates
the LHS quantifier with fresh flexible variables and turns the RHS
quantifier's variables into rigid "flexible nominal tags" `#F` — skolems by
another name — which coexist with unrelated tags without reducing to ⊥.
The constraint solver then runs unchanged. Lifting this from a once-at-
declaration check to a recursive, at-each-quantifier check is a non-trivial
extension (it requires escape checking, level-correct generalization at
nested binders, and predicativity discipline for storing forall-typed
values in records) but it is *consistent with* the MLstruct subtyping
algorithm: the algorithm itself never needs to change, only the points at
which skolems are introduced and the escape check is run.

The non-trivial part is therefore the *architecture* (when to skolemize,
when to generalize, where to run escape checks), not the *subtyping
algorithm*.

Impredicativity (forall-typed values stored inside record fields, used in
HKT dispatch through record-of-generic-functions) is a separate axis from
rank-N depth. Crescent commits to full rank-N; impredicativity is not part
of that commitment. The design space for impredicativity is genuinely
unsolved in the surrounding research, and the rank-N commitment above does
not pin a choice. If impredicativity is later wanted, Quick Look boxed
impredicative polymorphism (Serrano et al. 2020) is the indicated
discipline. Until then, HKT dispatch through records of generic functions
remains an expressiveness gap per `typechecker-reference.md` §HKT.

## 7. Narrowing

With complement in the lattice, flow-sensitive refinement is *exactly
intersection with a positive or negative atom*:

| Guard form                      | Truthy branch type   | Falsy branch type     |
|---------------------------------|----------------------|-----------------------|
| `if x then ...`                 | `T & ~nil & ~false`  | `T & (nil \| false)`  |
| `if x ~= nil then ...`          | `T & ~nil`           | `T & nil`             |
| `if type(x) == "string"`        | `T & string`         | `T & ~string`         |
| `if x == "GET"`                 | `T & "GET"`          | `T & ~"GET"`          |
| `if x.tag == "leaf"`            | `T & { tag: "leaf" }`| `T & ~{ tag: "leaf"}` |
| `if is_str(x)` (predicate)      | `T & string`         | `T & ~string`         |

No special-case code path per guard kind. The narrowing pass walks the AST,
identifies the *refining atom* of each guard (a primitive type, a literal, a
record shape, a user-predicate's declared `x is T` target), and emits the
appropriate intersection on each branch.

The branch-exit join is *union*: at the join point, the narrowed type is the
union of the narrowed types from each predecessor branch.

Per `type-system.md` "Open problem", the *un-narrowed type variable*
generated during constraint emission must not be queried inside the
narrowed scope. The clean fix in the rewrite: the narrowing pass runs
*after* generalization fixes variable identities, but operates on the
already-solved types in the narrowed scope's view, re-emitting any
subtype obligations from inside the narrowed scope as constraints on the
intersected type rather than on the original variable. This is the
"second pass" hinted at in `type-system.md` Decisions §"Type narrowing,"
made explicit: constraint generation in narrowed scopes consults the
flow-typed environment, not the raw inference environment.

## 8. Implementation tier and reference

**Closest external implementation: MLstruct.**

The rewrite session should use the MLstruct paper (Parreaux & Chau,
OOPSLA 2022, *MLstruct: Principal Type Inference in a Boolean Algebra of
Structural Types* — extended v8.0 PDF on lptk.github.io) and the simple-sub
source (LPTK/simple-sub on GitHub) as guides:

- *simple-sub* gives the cleanest implementation of polar bounds,
  bisubstitution, level-based generalization, recursive type detection via
  hash-consing, and coalescing into compact types. Read this first as the
  algorithmic skeleton.
- *MLstruct* gives the negation extension: bounds in DNF, per-constructor-shape
  emptiness checking, and the constraint-decomposition rules for `~T`. This
  is the part that simple-sub lacks and that crescent needs.

The semantic-subtyping line (Frisch/Castagna/Benzaken) is the reference for
the *emptiness check itself* and for the *match-type semantics*. Read it as
the spec for what "subtyping under boolean operations" should compute, not
as the implementation strategy.

The rewrite is not literally a port of either codebase — crescent has match
types, nominal opaque types, indexed access, FFI cdef integration, and other
features that neither reference handles directly. But the lattice, the
constraint vocabulary, the inference algorithm, and the type representation
should be derivable as the MLstruct construction adapted to crescent's
constructor set.

## 9. Scope and open questions

### 9.1 Covered by this design

- The set-theoretic lattice with union, intersection, complement.
- Product, function, indexer, tuple, fixed-point, universal-quantification
  constructors.
- Literal types, nominal opaque types (newtype, opaque, private fields).
- Match types with `_` as sugar for complement.
- Flow-sensitive narrowing as intersection.
- Rank-N polymorphism with predicative skolemization.
- Type-level functions via match-type evaluation.
- Recursive types via equi-recursive μ.

### 9.2 Resolved design questions

1. **RESOLVED: Rank-N polymorphism.** Crescent commits to full rank-N, not
   predicative-only. Foundation: simple-sub's level-based generalization
   plus MLstruct's `#F` flexible nominal tags as skolems; lift to full
   rank-N via deep-skolemization at subsumption per Peyton Jones et al.
   2007. Commitment lives in §1.1 and §6. Impredicativity remains a
   separate, unresolved axis and is not part of this commitment.

2. **RESOLVED: Variance.** Inferred from structural position; no user
   annotation syntax. For structural types (functions, records, unions,
   intersections), variance falls out of structural subtyping rules
   automatically. For named generics defined via type aliases, variance is
   inferred from how the type variable appears in the definition:
   covariant in positive positions, contravariant in negative positions,
   invariant if both. Reference: OCaml's variance-inference discipline.

3. **RESOLVED: `$EachField` and `$`-prefixed intrinsics.** Kept as
   intrinsics; not integrated with match types. TypeScript's mapped types
   + `keyof` + conditional types + `infer` became a Turing-complete
   sub-language at the type level. Crescent's `$EachField`, `$Require`,
   `$Throw`, etc. as `$`-prefixed intrinsics are honest — opaque-to-user
   mechanisms with specific purposes, not a sublanguage. Match types are
   not extended to subsume them.

4. **RESOLVED: FFI cdef integration.** Not architectural. The cdef parser
   produces types in crescent's lattice; the typechecker consumes them as
   `(name, type)` bindings in the environment. The pipeline belongs in a
   separate "cdef-to-type pipeline" document when implementation reaches
   that point. Out of scope for this architectural design.

5. **RESOLVED: Indexed access and `$Require`.** Indexed access `T[K]` is a
   first-class lattice operation with distribution rules; negated keys are
   accepted. Detailed semantics in §1.1. With this resolution, `$Require`
   plumbing reduces to ordinary indexed access on a module table whose
   keys are string-literal singletons; no additional design surface is
   required at the lattice level.

6. **RESOLVED: Coroutine effects.** Effect tracking is in scope when
   features require it. Coroutines need it (yield as an effect);
   `pcall`/`error` likely needs it (throw as an effect); async/await
   would need it (await as an effect). Start with a small effect set
   (`yield`, `throw`), extensible per-feature; do not design a full
   Koka/Eff row-of-effects calculus upfront. Commitment lives in §3.1.

7. **RESOLVED: DNF emptiness performance.** Emptiness checking is
   deferred until forced by a specific decision point (subtype queries
   involving non-trivial negation, match-arm dispatch with negated atoms,
   narrowing-simplification of complex inputs), results are cached, and
   pathological cases time out with a diagnostic. The worst-case
   exponential is real but not gratuitously triggered. Implementation
   discipline lives in §2.2 (Complement decomposition). The fallback of
   restricting the boolean algebra is rejected.

### 9.3 Still open

1. **Annotation soundness for `--[[: T]]` casts on `unknown` actuals.**
   `type-system.md` Principle 4 footnote flags this. Under the
   set-theoretic lattice, the cast `--[[: T]] x` where `x: unknown` should
   require `unknown <: T`, which is false unless `T = unknown`. The current
   tolerated behavior contradicts this. The rewrite must pick one — either
   tighten the rule (and accept the migration cost) or specify a separate,
   visible "narrowing cast" form. Awaiting user decision.

### 9.4 Tally

Of the original eight §9 questions, **seven are RESOLVED** (§9.2.1–7) and
**one remains open** (§9.3.1, the cast-on-`unknown` soundness question).
