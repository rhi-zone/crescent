# Crescent type system vs canonical HM — fit audit

## Methodology

This audit reads the surface of crescent's type system as documented in
`docs/type-system.md`, `docs/typechecker-reference.md`,
`docs/typechecker-rank-n.md`, `docs/typechecker-hm-phase2.md`, and the
`lib/type/static/CLAUDE.md` rules — supplemented by the TAG enumeration in
`lib/type/static/types.lua` and a sampling of `type_soundness_test.lua`
describe blocks (especially the H2 record-of-generics pins around 3875-3990
and the rank-N pins). Classification is by surface feature, not by current
implementation. For each feature, the question is "does this fit the
canonical bidirectional-HM walk (CHECK/SYNTH + unification + let-gen,
optionally with deep-skolemization for rank-N), or does it require a named
extension that breaks HM's properties (principal types, decidability via
unification alone, no backtracking)?"

The adversarial bias is applied: when a feature *can* be construed as an HM
extension, the question asked is "does the combination with other features
still keep the extension well-behaved?" An extension that's individually
benign but interacts badly with others is recorded as not-HM.

## Feature coverage table

| Feature | In canonical HM? | If no, what extension? |
|---|---|---|
| Monotype inference, scalar/function/table | yes | — |
| Let-generalization at function/local bindings | yes | — |
| Bidirectional CHECK/SYNTH | yes | — |
| Mutual recursion (two-pass) | yes | — |
| Rank-N polymorphism with explicit `<T>` annotation | yes | Peyton Jones et al. *Practical type inference for arbitrary-rank types* — accepted as still HM-shaped (skolemization + escape check). `docs/typechecker-rank-n.md` is exactly this design. |
| Impredicativity (`Maybe (∀a. a -> a)` as a stored value) | no | System F (impredicative). Crescent explicitly does NOT have this — declared an expressiveness gap in `typechecker-reference.md` "Soundness status". OK to remain absent under HM. |
| First-class union types `A \| B` | no | Distributive subtyping. HM has no first-class unions — narrowing union members at use sites requires distribution and per-branch checking. Open records + literal discriminants compound this (see `narrow.lua` field_disc / `Block` pattern in `lib/type/static/CLAUDE.md` lines 220-235). |
| First-class intersection types `A & B` (incl. overloaded callable) | no | Intersection types / refinement intersections. Overload resolution (`(A)->nil & (B)->nil`, soundness tests line 800/2017) requires trying each branch — non-confluent under pure unification; needs backtracking or constraint-based dispatch. |
| Subtyping (`C_SUB` shape, `integer <: number`, literal `<:` base, structural record width/depth) | no | MLsub / co/contravariant subtyping (a.k.a. "HM with subtyping"). Doable as a known extension but it is not equality-unification HM. Pervasive in crescent: `--[[: T]]` is a subtype check, function param contravariance, optional `T \| nil`. |
| Row polymorphism (open records `{ x: T, ... }`) | yes (with extension) | Rémy/Wand row polymorphism — standard HM extension. Crescent uses it pervasively. |
| Closed-vs-open records as distinct kinds | yes (with row-poly) | Same extension as above. |
| Optional fields `x?: T` | no | Width subtyping + presence variables. Row-poly alone doesn't give optional; needs presence flags or `T \| nil` collapsing. |
| Readonly fields / field attributes | no | Variance per field / qualified type system. Not in HM. |
| Index signatures `{ [string]: T }` | no | Map/dict types as a separate type former; combines with subtyping for `{[K]:V}` vs named fields. |
| Tuple types `{ A, B, C }` distinct from arrays | yes-ish | Tuple is a product type — HM handles it. But tuple-vs-indexer disambiguation and the brace-tuple positional-slot rule depend on subtyping rules. |
| Multi-return / multi-value calls | yes | Tuple sugar; the surface is HM-compatible. |
| Varargs `...T`, spreads `...(T)`, multi-return splicing `(true, ...R)` | partial | Beyond plain HM — needs a sequence/spread calculus. Doable as a row-style extension on tuples. |
| Literal types `"GET"`, `42`, `true` | no | Singleton types with subtyping (`42 <: integer <: number`). Outside HM; requires subtyping. |
| `nil`, `never`, `unknown`, `any` (bottom/top/dynamic) | no | Top/bottom + gradual typing. HM has no top/bottom and no dynamic boundary. Crescent's `any`-as-firewall (Principle 3) is a gradual-typing concept. |
| Nominal types: `newtype`, `opaque` | yes (with extension) | Nominal type generators are a standard HM extension (Haskell `newtype`). Compatible. |
| Discriminated-union narrowing via literal discriminant fields | no | Flow-sensitive typing (TypeScript / CFA-based). Not in HM. `narrow.lua`'s field_disc is path-sensitive refinement. |
| `if type(x) == "string"` narrowing | no | Flow typing + typecase. Standard TS extension; not HM. |
| Nil-check narrowing (`if x`, `if x ~= nil`) | no | Flow typing. Not HM. |
| User-defined type predicates (`x is T`) | no | Refinement types + flow typing. TS-style. Not HM. |
| Assertion functions (`asserts x is T`) | no | Effect-tagged refinement. Not HM. |
| Match types (`match T { ... }`, capture sigils `%X`, wildcards) | no | Type-level pattern matching / GADT-flavored type families. Beyond HM. Closer to OutsideIn/X or TypeScript conditional types. Crescent has these as a first-class library mechanism — `Keys<T>`, `Values<T>`, `PcallReturn`, `ParamOf`, etc. are all defined this way. |
| Conditional types (`match T { string => true, _ => false }`) | no | TS conditional types / type-level case. Requires type-level reduction; not HM. |
| Type-level computation via `match` + `$EachField` (mapped types: `Partial<T>`, `Readonly<T>`) | no | Mapped types / type-level fold. Requires a type-level evaluator. Not HM. |
| Indexed-access types `T["name"]` | no | Type-level projection. Not HM. |
| Higher-kinded types (`F<A>`, `Functor<F>`, `<F: Maybe>` bound) | no | System Fω. Crescent emits `C_HKT_DECOMPOSE` to recover `F` and `A` from `F<A>` at unification — this is HKT unification, not first-order HM unification. H2 pins (soundness tests 3875-3990) are exactly this feature. |
| Bounded polymorphism `<T: Bound>` | yes (with subtyping) | Bounded quantification (System F<:). Standard but not HM. |
| Generic constraints checked structurally | no | Same as above. |
| Generic defaults `<T = string>` | partial | Default-instantiation is an extension; tolerable in HM-with-defaults. |
| Mutual / circular type-param bounds (fixed-point iteration in solver) | no | Constraint-based polymorphism with fixed-point solving. Not HM (unification doesn't iterate to fixed point). |
| `typeof` in signatures (mutual equality constraints) | partial | `typeof x` reduces to equality on already-inferred types — HM-compatible *if* used after the referent is known. Mutual `typeof` uses union-find, still HM-compatible. |
| Metamethod-driven semantics (`__add`, `__index`, `__call`) | no | Type classes / qualified types. `a + b` with arbitrary user `__add` types is a *qualified-type* constraint à la `Num a => a -> a -> a`. Doable as an HM extension (Haskell does it), but pulls HM toward OutsideIn for full generality. |
| `setmetatable` merging meta slots into a type (`T & { #...MT }`) | no | Intersection + meta-spread. Requires intersection types and a meta-slot type former. Not HM. |
| Overload resolution by argument types (`(A)->nil & (B)->nil`) | no | Intersection of functions + best-match dispatch. Requires backtracking or principled overload algorithm; not HM. |
| Pcall/coroutine multi-return wrapping | partial | Tuple algebra; an extension on top of multi-return. |
| FFI cdef-driven types (`$FfiC`) | partial | External type ingestion — not a type-system feature per se, but typing arbitrary C types requires more than HM monotypes (e.g. pointers, fixed arrays, layouts). |
| Module-pattern open-table refinement (`local M = {}; M.foo = ...`) | no | Flow-sensitive type refinement on mutable bindings. Requires effect tracking on assignment. Not HM. |
| Recursive/equi-recursive types with lazy expansion | yes (with extension) | μ-types / equi-recursive. Standard HM extension. |
| String pattern types (`$PatternReturn<P>`) | no | Type-level computation over string literals. Beyond HM. |
| Skolem escape check | yes | Standard part of rank-N HM. |
| Variance (currently invariant; planned: inferred) | no | Variance inference for parameterized types. Not in pure HM (HM types are second-order invariant by default; variance is an additional analysis). |

## Features that fit canonical HM

- Monotype inference; let-gen; CHECK/SYNTH bidirectional walk; mutual recursion.
- Rank-N polymorphism with explicit `<T>` annotation, skolemization, and per-call escape check (the design in `docs/typechecker-rank-n.md` is textbook).
- Row polymorphism for open records (`{ x: T, ... }`).
- Recursive types via μ-binders / equi-recursive lazy expansion.
- Nominal type generators (`newtype`, `opaque`) as opaque wrappers around HM types.
- `typeof` reducing to deferred unification on a named variable.

## Features that require named extensions

- **Subtyping** (`C_SUB`, `integer <: number`, literal `<:` base, function param contravariance, structural width subtyping) — extension toward **MLsub** or "HM with subtyping." This is the largest single deviation by surface area.
- **First-class unions and intersections** (`A | B`, `A & B`, overloaded callable) — requires **distributive subtyping** plus backtracking overload resolution; pulls toward **MLstruct / set-theoretic types** (Castagna et al.).
- **Flow-sensitive typing / narrowing** (nil-check, `type(x)==`, literal discriminants, predicates, assertion functions, `if x.field then`) — **CFA / occurrence typing** (Tobin-Hochstadt) layered on top of inference. Crescent's design doc explicitly says "narrowing is a post-solve pass, not inference" (Decisions: Type narrowing) but the surface still requires it.
- **Match types / conditional types / mapped types** (`match T { ... }`, `$EachField`, `Keys<T>`, `Partial<T>`) — **type-level computation** / **type families** (Haskell) or **conditional types** (TypeScript). Requires a type-level evaluator and reduction strategy. Not unification.
- **Higher-kinded types with bound dispatch** (`Functor<F>`, `<F: Maybe>`, `C_HKT_DECOMPOSE`) — **System Fω with bounded quantification**. The H2 pins show crescent already needs to *decompose* `F<A>` to recover `F` from a record-stored generic — that is HKT unification.
- **Qualified-typing for metamethods** (`a + b` requiring `__add`, `__index` chains, `setmetatable` adding meta slots) — **type classes / qualified types** in HM-speak; combined with intersection produces something stronger.
- **Singleton/literal types** with the implicit lattice to their base — **subtyping + singleton kinds**. Not HM.
- **Gradual typing boundary** (`any`, `unknown`) — **gradual typing** (Siek/Taha). Not HM.
- **Variance** (planned, inferred) — **variance analysis**. Not HM.

## Paradigm verdict

**Crescent's type system is fundamentally NOT HM-shaped. It is closer to a hybrid of MLstruct / set-theoretic types (for the union/intersection/subtyping core) + TypeScript-style conditional types and flow typing (for `match` and narrowing) + System Fω (for HKT). Implementing canonical HM and bolting on the missing features is the WRONG approach because the features interact in ways that break HM's properties.**

The killer feature interactions, specifically:

1. **Intersection + subtyping + overload resolution.** Pure HM unification is equality-based and confluent. Overloaded callable `(A) -> nil & (B) -> nil` requires choosing *one* arm based on the argument type — that's a non-confluent search step. Combined with subtyping (the argument may be a subtype of multiple arms, or of an intersection of arms), unification alone cannot decide. This is the standard reason HM extensions to intersection types become either undecidable or require backtracking constraint solvers.

2. **Match types + HKT + bound dispatch (the H2 family).** `Functor<F: Maybe>` with `map: <A, B>(F<A>, (A) -> B) -> F<B>` requires the typechecker to *decompose* an applied type `F<A>` at unification time to recover `F` and `A` separately. Standard HM unification cannot do this — applied type constructors are unified head-by-head, not decomposed. Crescent already has `C_HKT_DECOMPOSE` for this; that constraint shape is foreign to HM. Combined with match types (`match T { F<A> => ... }`) the type system needs a type-level reducer, which lives outside HM entirely. The current `docs/typechecker-h2-correct-design-v3.md` Phase F work is precisely about getting decomposition into the solver — a clear signal the design is constraint-based, not unification-based.

3. **Flow-sensitive narrowing + union types + literal discriminants.** `Block = { type: "heading", level: integer } | { type: "paragraph", content: string }` plus `if block.type == "heading" then block.level else block.content end` requires occurrence typing / CFA on the union. HM has no flow sensitivity — types are assigned per binding, not per program point. Crescent's own design (`type-system.md`, Type narrowing section) acknowledges the "open problem" that constraints generated inside narrowed scopes reference the un-narrowed type variable, which is the exact wart of trying to layer flow typing onto a constraint-generation pipeline that does not natively support program-point types.

4. **Subtyping pervasiveness.** Every `--[[: T]]` cast, every literal-to-base coercion, every optional widening, every open-record assignment, and every function-param contravariance is a subtyping check. The repo-wide constraint kind for this is `C_SUB`. HM's substrate is `C_EQ`. Replacing the substrate's primary constraint shape with subtyping is not "HM with an extension"; it is a different system that happens to share let-gen and skolems.

The combination of (1)+(2)+(3) is what places crescent outside HM-with-extensions. Each individually has a known HM-flavored treatment, but the three together produce constraints whose interaction requires a general constraint solver with backtracking, deferred resolution, fixed-point iteration on bounded type-param mutual constraints, and type-level reduction — i.e. the architecture that the existing `lib/type/static/solve.lua` and `constrain.lua` evolved into.

The named paradigm that best fits the feature set is **constraint-based subtyping with type-level computation**, in the tradition of **MLstruct** (Parreaux et al.) for the algebraic-subtyping core, plus **TypeScript-style conditional/mapped types** for the type-level computation, plus **occurrence typing** for narrowing. None of those alone is HM; their union definitely is not.

## Implementation implication

Given the verdict — "not HM" — the rewrite target should NOT be a canonical bidirectional HM walk with extension points bolted on. The substrate must be a constraint-based subtyping engine from the start. Specifically:

- The primary constraint is `C_SUB(σ, τ)`, not `C_EQ(σ, τ)`. Unification is a *special case* of subtype simplification, not the base operation.
- The solver must handle deferred constraints: bounds (`C_BOUND`), HKT decomposition (`C_HKT_DECOMPOSE`), overload-resolution callable arms, and match-type reduction are all non-immediately-resolvable. A worklist with deferred-then-retry is intrinsic, not an HM hack.
- Type-level computation (`match`, `$EachField`) needs a small type-level evaluator with normalization. This evaluator is *consulted by* the solver, not folded into unification.
- Narrowing belongs in a separate post-solve pass that operates on resolved types and re-checks constraints generated under narrowed assumptions. The "open problem" in `type-system.md` is real and is a design constraint on this pass, not something the substrate can sweep under the rug.
- Rank-N skolemization + escape check is a localized HM-style mechanic and slots into the constraint solver fine; it is one of the few places where the HM design literature transfers directly.
- Row polymorphism for open records is the only structural feature that imports cleanly from HM-with-rows literature; reuse it.

The result is closer to the *current* `solve.lua` / `constrain.lua` architecture in shape — constraint queue + deferred work + type-level eval — than to a canonical HM walk. That does not mean the current implementation is right; it means the *category* the rewrite should target is "constraint-based subtyping engine," not "HM checker." The status quo's category is correct; its execution may not be.

This audit deliberately does not recommend whether to rewrite or not.

## Adversarial notes

The three features whose verdict I am least confident about:

1. **Literal types + subtyping to base.** I called this "not HM." But there is a tradition (Pottier's PhD work on MLsub; Dolan's MLsub) of integrating singleton types into HM-with-subtyping cleanly. If MLsub-style polarized subtyping is considered "still HM," the verdict on subtyping softens. A repro that might falsify my classification:

   ```lua
   --: <T>(T) -> T
   local function id(x) return x end
   local x = id(42)  -- inferred 42 or integer?
   local y --: integer = id(42)  -- works iff 42 <: integer flows through the call
   ```

   If crescent's behavior here matches MLsub-style polar inference (with bisubstitution), the substrate may be closer to MLsub than I've described.

2. **HKT decomposition vs. "just" type constructor unification.** Standard HM does unify `F<A>` with `G<B>` by `F~G, A~B`. The H2 hard case is when `F` is itself a forall-bound type variable that needs to be *recovered* from an applied form — that is what `C_HKT_DECOMPOSE` does. But it is conceivable that a sufficiently careful HM-with-HKT setup (à la GHC's `Type -> Type` kinds with type-constructor variables) handles this without a foreign constraint kind. Repro that would test this:

   ```lua
   --:: Functor<F> = { map: <A, B>(F<A>, (A) -> B) -> F<B> }
   --:: declare functor_maybe = Functor<Maybe>
   local x = { tag = "none" } --: Maybe<integer>
   local y = functor_maybe.map(x, function(a) return tostring(a) end)
   -- Does y get inferred as Maybe<string> via head-unification alone,
   -- or does F genuinely need to be solved separately from F<A>?
   ```

   If the H2 Phase F design ends up being expressible as type-constructor unification with kind annotations rather than a foreign `C_HKT_DECOMPOSE` constraint, the HKT verdict softens.

3. **Narrowing as post-solve vs. as inference.** I called occurrence typing un-HM-able. But the design *intent* in `type-system.md` is that narrowing operates on *already-resolved* types, post-solve. If that strict separation holds, the inference substrate doesn't itself need flow sensitivity — it only needs to produce types that a post-solve pass can refine. That would put narrowing in the "tooling on top of HM" category rather than "in the substrate." Repro that exposes the boundary:

   ```lua
   local function f(x)  -- inferred <T>(x: T) -> ?
     if type(x) == "string" then return x:upper() end
     return nil
   end
   ```

   If the body's `x:upper()` constraint is generated against the un-narrowed `T` and the post-solve pass cannot retroactively allow it, the substrate is leaking — and narrowing belongs *inside* inference, not on top of it. The "Open problem" in `type-system.md` line 222 is exactly this question; my verdict assumes it can be resolved cleanly, but I am not certain.

If any of these three classifications flip on closer inspection, the paradigm verdict softens from "fundamentally not HM" toward "HM with a large but principled extension set." I would not bet on the flip — the intersection of all three plus the unambiguously non-HM features (match types, overload resolution, `$EachField`, gradual `any`) keeps the verdict robust — but a reader doing this audit independently should test these three points before accepting the verdict wholesale.
