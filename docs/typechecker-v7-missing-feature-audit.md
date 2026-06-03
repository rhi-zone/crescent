# Typechecker v7 Missing Feature Audit

This audit mines v4/v5/design documents for features that are not yet admitted,
not yet classified, or not yet precise enough in the v7 kernel.

It is an audit, not an admission list. A feature remains outside v7 until the
kernel has well-formedness rules, semantic rules, failure behavior, soundness
obligations, and certificate nodes for it.

## Classification Legend

- **Admitted core:** already represented by the first v7 kernel.
- **Candidate core extension:** likely needed for a full checker, but not yet
  specified.
- **Contextual-control effect:** belongs to the `throws`/`yields` effect frame.
- **Trusted bridge:** depends on module, FFI, declaration, filesystem, or runtime
  environment state.
- **Type-level computation:** belongs in match/intrinsic/kinding machinery.
- **Surface/directive feature:** parser or annotation surface; must elaborate to
  kernel rules.
- **Deferred power feature:** useful but not first-kernel material.
- **Reject / unsafe boundary:** do not model as sound unless explicit trusted
  boundary exists.

## Feature Matrix

| Feature | Source evidence | v7 status | Why it matters | Ad-hocness risk | Recommended v7 classification |
|---|---|---|---|---|---|
| Caps-first stdlib / optional caps prelude | `docs/typechecker-v4-stdlib-design.md` §1.2; CLAUDE caps-first; subagent audit | Direction corrected: stdlib is not checker core and concrete stdlib declaration sets are outside the v7 semantic spec. | Prevents ambient `io`/`os`/`debug` authority from leaking into every checked library while still allowing app-level opt-in declarations. | High if modeled as `io`/`os` effects, ambient globals, implicit checker defaults, or kernel rules. | External declaration input only; selected declarations carry provenance and trust, but v7 does not specify a concrete stdlib set. |
| Operators and structural metamethod lookup | `docs/v5-gaps.md` P6; `docs/typechecker-v5-constraints.md` C2; `lib/type/static/CLAUDE.md` solver rules; `docs/typechecker-ast-walker-design.md` operator sections | Direction chosen: `OpCheck` derives through target-profile primitive rules, metatable lookup plus call, or explicit raw primitive capabilities; LuaJIT target table now records first concrete rows. | Arithmetic/comparison/concat/unary operations and user numeric/string-like types are ordinary Lua semantics. | Per-operator predicates, hardcoded `is_numeric` tests, or method-name dispatch repeat the v4/v5 ad-hoc path. | Core extension chosen; remaining work is certificates, exact table-length proofs, and FFI/cdata operators. |
| Numeric tower and literal integer/float distinction | `docs/v5-gaps.md` parser-int-float; `docs/type-system.md` literal semantics; TODO tuple/numeric entries | Direction chosen: first target is `luajit51-crescent`; `integer` is a semantic refinement, while ordinary arithmetic widens unless a profile rule proves integer preservation. | `1`, `1.0`, integer arithmetic, `%`, `/`, bit ops, and Lua 5.4 integer semantics differ. | Treating integer-valued floats as integers is unsound for target-specific semantics. | Target-profile extension chosen; remaining work is exact integer-preservation and numeric-string conversion transcription. |
| `type(x)` narrowing | `docs/typechecker-v4-stdlib-design.md` §1.1/§2; `TODO.md` de-specialcase builtins | Direction chosen: external declarations may bind `type` to a primitive predicate-capable value or trusted guard declaration; shadowed names do not narrow. | `if type(x) == "string"` is core Lua narrowing. | Dispatching on callee name `type` is name magic. | Candidate core extension: primitive predicate spec for the `type` binding, with certificate node. |
| Truthiness and boolean control-flow narrowing | `docs/typechecker-v5-constraints.md` D11; TODO narrowing entries | Direction chosen: explicit `Truthiness` rule with Lua falsey/truthy facts under target profile. | `if x then`, `if not x then return`, and short-circuit expressions dominate Lua code. | Local branch hacks can lose alias invalidation or nil/false precision. | Core extension chosen; remaining work is detailed join/invalidation and certificate transcription. |
| `and` / `or` expression typing | TODO entries around `C_OR`; typechecker references | Direction chosen: separate `AndExpr`/`OrExpr` control-flow judgments, not `OpCheck`. | Lua idioms use `x or fallback` and `cond and a or b`; these are value-producing control flow. | Treating as boolean operators loses returned value types; treating as union too early loses flow facts. | Core extension chosen; preserve first-value semantics and branch facts. |
| For-in iterator protocol | `docs/v5-gaps.md` P6/Y1; `docs/typechecker-v4-stdlib-design.md` `pairs`/`ipairs`; TODO for-in entries | Not represented in v7. | `pairs`, `ipairs`, and custom iterators are central Lua constructs. | Name-keyed `pairs`/`ipairs` handlers were a known v5 failure. | Candidate core extension: generic iterator protocol over returned iterator/state/control triple; external declarations may consume it. |
| Numeric for loop typing | `docs/v5-gaps.md` P6; v5 gen-pass entries | Not represented in v7. | Loop variables and bounds have numeric obligations. | Easy to silently widen loop variable to `unknown` or `number`. | Candidate core extension: statement rule emitting numeric subtype obligations. |
| Method dispatch with `:` | `docs/v5-gaps.md` P6; `docs/type-system-design/06-setmetatable-construction.md`; `docs/typechecker-v5-constraints.md` D9 | Direction chosen: lower through lookup plus call. | Lua method calls are syntax for self-passing plus field/metatable lookup. | Special-casing `obj:method` separately from field-read/call creates inconsistent semantics. | Core extension: lower to `LookupField(obj, method)` plus call with self argument. |
| Metatable `__index` chain walking | `docs/v5-gaps.md` G6; `docs/type-system-design/06-setmetatable-construction.md`; consolidation audit | Direction chosen: built-in lookup relation with dependencies. | Class-like OO in real corpus depends on `__index`. | Chain walking can become name-keyed/cyclic/unterminating; unknown `__newindex` can make post-setmetatable writes unsafe. | Core extension: structural, terminating metatable-index judgment with dependency invalidation. |
| `setmetatable` seal semantics | `docs/type-system-design/06-setmetatable-construction.md`; v7 setmetatable pass | Decision chosen: fixes metatable without sealing. | Construction-phase table typing and OO idioms depend on this. | Allowing absent-field extension after unknown `__newindex` would be unsound. | Kernel direction: setmetatable fixes metatable state; later writes must prove raw/own-field semantics or reject. |
| Raw operations (`rawget`, `rawset`, `rawequal`, `rawlen`) | `docs/typechecker-v4-stdlib-design.md` stdlib scope | Direction chosen: raw lookup/assignment primitives bypass metamethods but not invalidation; LuaJIT has rawget/rawset/rawequal globals but no rawlen global. | Raw ops bypass metamethods and interact with table identity/indexers. | Treating them as ordinary field ops may incorrectly include metatable behavior. | Core primitive extension plus external declarations; `$RawLen` is target-dependent. |
| `select` | `docs/typechecker-v4-stdlib-design.md` §2; `TODO.md` de-specialcase builtins | Not represented. | Vararg manipulation is common and affects pack precision. | Literal-`"#"` branch and index-tail branch invite name/literal special cases. | Candidate pack extension: stdlib declaration over packs plus literal overloads; reject until pack generics are specified. |
| Varargs and open packs | v7 pack design pass chooses closed/rest/variable tails and movement kinds; `docs/type-system-design/03-variadic-packs.md`; `docs/v5-gaps.md` G17 | Direction chosen; detailed transcription pending. | Needed for real Lua calls, `pcall`, iterators, `select`, vararg functions. | Approximating unknown arity as scalar `unknown` loses soundness/precision. | Core design: rest-pack movement, pack variables, variadic generics, and expression-list spread rules. |
| Last-position multi-return spread | `docs/v5-gaps.md` P5/Y3; TODO multi-return entries | Partially covered by pack movement, but not statement-level rule. | `return f()` and `a,b = f()` are central Lua semantics. | Flattening to positional records or slotwise unions loses correlation. | Admitted-core gap: add expression-list expansion rules over `PackAlt`. |
| `pcall` / `xpcall` | `docs/typechecker-v4-stdlib-design.md`; `docs/type-system-design/05-effects.md`; `docs/v5-gaps.md` P2/G17/Y1 | Reclassified as contextual-control effect candidate. | Needed for error handling and many force casts. | Name-keyed pcall handlers were a known failure; flat boolean/unknown result is too weak. | Contextual-control effect: `throws(E)` discharge plus pack-correlated success/failure result. |
| `error` / assertion failure | `docs/typechecker-v4-stdlib-design.md`; `docs/type-system-design/05-effects.md`; v7 effects section | Reclassified as contextual-control effect candidate. | Distinguishes normal return from nonlocal exit; `assert` narrowing depends on normal continuation. | Modeling as `never` only ignores enclosing arrow totality; modeling as return type is wrong. | Contextual-control effect or explicit outside-theorem boundary; decide before stdlib precision. |
| Coroutines / async / `yield` | `docs/type-system-design/05-effects.md`; `docs/typechecker-roadmap.md` F2; `docs/v5-gaps.md` 5.F3 residual | Reclassified as contextual-control effect candidate. | Precise `Coroutine<Y,S,R>` requires carrying yield/resume protocol from body to `create` and `resume`. | Scope-stack inspection and name-keyed coroutine handlers were v5 failure modes. | Contextual-control effect: `yields(Y,S)` discharged by `coroutine.create` into `Coroutine<Y,S,R>`. |
| Module declarations and exports | `docs/typechecker-v5-constraints.md` D12/D14; `docs/v5-gaps.md` P4; `docs/type-system-design/README.md` M14 | Direction chosen: `ModuleEnv` with provenance/trust kind. | Full checker must type `M = {}; M.foo = ...; return M` and cross-file imports. | Loader/cache side effects and `unknown` fallback can silently erase checking. | Trusted or checked module-boundary rule over immutable `ModuleEnv`; unresolved modules reject unless unsafe. |
| `--:: require` declaration import | v5 gaps P4; user discussion; current v4 docs | Direction chosen: annotation import edge into `DeclEnv`/`ModuleEnv`. | Declaration imports are per-module, not global; needed to avoid duplicate types. | Treating annotations as global or file-local incorrectly causes duplication/visibility bugs. | Surface/directive feature elaborating to module declaration environment, not runtime require. |
| `_G` / `$GlobalScope` | `lib/type/static/CLAUDE.md`; TODO; semantic mining | Direction chosen: bridge over explicit `DeclEnv`. | `_G` should reflect explicit declarations without ambient globals. | Easy to reintroduce ambient fallback or load-order dependence. | Trusted declaration bridge with certificate of declaration environment; no fallback indexer. |
| FFI `cdef`, `ffi.C`, `ffi.load` | `docs/typechecker-v5-constraints.md` D13; `docs/typechecker-v4-stdlib-design.md`; semantic mining | Direction chosen: `FfiEnv` with provenance/trust kind. | LuaJIT FFI is core to Crescent libraries. | C parser approximation, file-local state, and missing-symbol semantics are trusted-boundary risks. | Trusted FFI declaration environment; `$FfiC` only projects certified/parsed declarations. |
| Concrete stdlib declaration sets | `docs/typechecker-v4-stdlib-design.md` caps stdlib; TODO multi-target support | Reframed: target profiles are semantic inputs; concrete stdlib declaration sets are project/driver config outside v7 spec. | LuaJIT/Lua 5.1/5.4 and caps policies change globals, numerics, FFI, coroutine behavior. | One ambient stdlib file hides target assumptions; putting stdlib in spec makes it look like kernel semantics. | External declaration input with provenance; no concrete stdlib declaration set in v7 semantic spec. |
| Ambient IO / OS / debug globals | `docs/typechecker-v4-stdlib-design.md` §1.2; CLAUDE caps-first | Covered by caps-first stdlib/profile item above, but worth keeping as a negative case. | Sound caps-first checking requires absence of ambient authority. | Adding `io`/`os` globals for convenience violates sandboxability. | Reject by default; optional trusted application profile may declare them explicitly as cap values. |
| Opaque / newtype / unseal | `CONTEXT.md`; `docs/opaque-two-arg-spec.md`; `docs/v5-gaps.md` P5/Y10; semantic mining | `$Opaque` candidate; newtype/unseal not in kernel. | Nominal abstraction and module privacy depend on stable identities and scoped unsealing. | Call-site identity hacks or global unseal can break abstraction. | Type-level/nominal extension: stable origin IDs, scoped unseal, module boundary rules. |
| `augment` declarations | `docs/v5-gaps.md` P5/Y10; v4 implementation docs | Not classified. | Used to merge fields into existing type bindings. | Mutating aliases post-hoc can violate phase/order assumptions. | Surface/directive feature; elaborate to explicit type-binding extension with order/provenance rules, or defer. |
| Templates | v7 template section; v5 gaps P3 | Partially specified in v7. | Needed for call-site body instantiation and construction helpers. | Can become implicit mutation summaries if generalized carelessly. | Candidate core extension already started; needs certificate shape and first-class restrictions pinned. |
| Generic function body checking / skolemization | `docs/v5-gaps.md` P6; `docs/type-system-design/13` rank-N module | Direction chosen: rank-1 generics with skolems/escape checks. | Generic signatures must be checked for all instantiations, not by example. | Free typevars absorbing body constraints cause unsound acceptance. | Core extension: rank-1 generics with `forall` intro/elim certificates before rank-N. |
| HKTs / kinds | roadmap F1; `docs/type-system-design/04-hkt-kinds.md`; v5 gaps G1-G5/G10 | Boundary chosen: base kinds plus first-order named `TypeFn`; arbitrary HKTs deferred. | Needed for type constructors and higher-order type functions. | Admitting constructor variables without kinding reintroduces ad-hoc application. | Defer arbitrary HKTs; allow restricted named first-order type functions. |
| Match types | `lib/type/static/CLAUDE.md`; `docs/type-system-design/08`; v5 gaps P5 | Direction chosen: kinded first-order match substrate. | Replaces helper intrinsics, enables `Keys`, `PairsReturn`, transformations. | Eager/speculative evaluation with diagnostics or wrong suspension can be unsound. | Type-level computation extension: match well-formedness, partition, suspension/rejection, correlation rules. |
| Pattern types / capture sigil | v5 gaps P5; `lib/type/static/CLAUDE.md` capture and pattern notes | Direction chosen: match/type-level surface only after kinded patterns. | Needed for match aliases and type-level destructuring. | Bare-name capture fallback and field-order-dependent captures were known footguns. | Type-level computation surface; admit only explicit `%` capture and deterministic patterns. |
| `$Throw` / `$Catch` type-level diagnostics | `docs/throw-catch-types-spec.md`; semantic mining | Candidate intrinsic, distinct from runtime `throws(E)`. | Useful for authored type-level contract errors. | Diagnostic side effects during speculative type evaluation are order-sensitive. | Type-level computation extension with committed-path diagnostics, not runtime effect. |
| Indexed access `T[K]` | `docs/type-system-design/11`; TODO FFI/accessor entries | Not in v7 kernel except record read operations. | Needed for `T[K]` aliases, FFI maps, metatable/indexer reasoning. | Hardcoding `$IndexAccess` or string encodings repeats prefix-scoping failure. | Candidate type-level computation/core record operation with distribution and bounded deferral. |
| Record field attributes: optional / readonly | `docs/type-system-design/07-records.md`; v7 records include fields with flags | Partially admitted. v7 has flags and subtyping sketch, but no surface/directive mapping. | Optional/readonly determine width and variance. | Prefix encodings like `$opt_`/`$ro_` are retired; mutable/covariant confusion is unsound. | Admitted-core gap: finish field presence/write/read rules and surface mapping. |
| Indexers vs open rows | CLAUDE hard rule; v7 records section | Partially admitted. | Distinguishes unknown extra named fields from typed dynamic keys. | Treating `...` and `[K]:V` as interchangeable causes false acceptance. | Admitted-core gap: add explicit read/write/indexer movement rules and tests. |
| Recursive types / μ | `docs/type-system-design/12`; TODO recursive type issues | v7 Type domain lacks μ. | Real data structures and aliases can be recursive. | Naive expansion causes nontermination; hash-consing/guarding required. | Deferred/core extension: equi- or iso-recursive rule with guarded expansion and certificate normalization. |
| Type aliases, scoped names, and shadowing | many docs; prefix-scoping; v5 gaps | v7 has no type-binding environment beyond `Δ` placeholder. | All annotation/type-level syntax depends on scoped aliases. | Treating aliases as global caused previous duplication/confusion. | Surface/type-environment extension: scoped type bindings, module-local aliases, import rules. |
| Overload ambiguity and branch selection | v7 call rules cover basic overloads | Partially admitted. | Need deterministic rejection/acceptance when multiple branches match, especially with posts/effects. | First-match semantics can hide unsound branch facts. | Admitted-core gap: add ambiguity rules for return packs, postconditions, and effects. |
| Assertion signatures / runtime asserts | v7 covers postconditions but not stdlib `assert` fully | Partially admitted. | `assert(x)` narrows and may throw. | Treating assertion as pure narrowing ignores failure; treating as return type is wrong. | Fact transition plus contextual-control failure effect once `throws` admitted. |
| Type assertions / force casts | v7 covers checked/force assertions | Partially admitted. | Existing corpus has many force casts; auditability matters. | Force casts as inference sources or silent proof are unsound. | Unsafe boundary: certificate `UnsafeNode`, never inference source. |
| `unknown` movement restrictions | v7 design pass chooses domain-governed elimination. | Direction chosen; kernel transcription pending. | `unknown` as denotational top can still be misused if operations add fallback branches. | Allowing concrete consumption silently makes it `any`. | Every operation must state its domain; unknown may move only through preservation, total observation, proven refinement, or unsafe boundary. |
| `any` | v7 says not in Type; v5 constraints say no any | Mostly admitted as unsafe boundary. | Existing docs/code still have explicit any; must be auditable. | Letting any into sound algebra invalidates theorem. | Unsafe boundary only; grep-able certificate/audit event. |
| Error diagnostics / provenance | v5 gaps G5/Y8/Y9; soundness validation certificate nodes | v7 certificate docs mention stable IDs, not diagnostic provenance. | Proof failures and user errors need source mapping without storing spans in types. | Adding spans to type nodes pollutes semantics; losing provenance blocks usable errors. | Implementation/certificate adjunct: source provenance on obligations/nodes, not in Type. |
| LSP/hover/go-to-def | TODO LSP entries | Not semantic. | Important tooling but not soundness kernel. | Can accidentally rely on checker side effects like pending require metadata. | Defer as implementation layer over certified facts. |

## Highest-Risk Missing Classifications

1. **Unknown movement transcription.** v7 now chooses `unknown` as denotational
   top with operation-domain-governed elimination. The remaining work is to
   transcribe that decision into each movement and operation judgment before
   implementation, because it affects every annotation, call, cast, and bridge
   fallback.
2. **Open/rest pack transcription.** v7 now chooses closed/rest/variable tails
   and movement kinds. Remaining work is detailed rules for rest tails, pack
   variables, varargs, expression-list spread, and certificate nodes.
3. **Contextual-control effect transcription.** v7 now chooses effectful arrows
   for the full design, with `throws(E)` and `yields(Y,S)` as the initial
   contextual-control effects. Remaining work is sequencing, subtyping,
   overload, discharge, and certificate rules. They should not expand into
   `io`/cap/mutation effects by default.
4. **Module/provenance transcription.** v7 now chooses explicit immutable
   environments with provenance for modules, declarations, and FFI. Remaining
   work is detailed bridge specs and certificate rules.
5. **Metatable lookup transcription.** v7 now chooses built-in lookup and
   assignment relations with dependency invalidation. Remaining work is detailed
   rule transcription, target protected-metatable behavior, and certificates.
6. **Type-level computation transcription.** v7 now chooses rank-1 generics and
   kinded first-order type-level computation. Remaining work is detailed rules
   for skolemization, match reduction, field descriptors, recursive aliases, and
   certificates.
7. **Operator/metamethod transcription.** v7 now chooses `OpCheck` with
   target-profile primitive rules, metatable lookup plus call, and raw primitive
   capabilities. Remaining work is detailed target tables, equality restrictions,
   truthiness/short-circuit rules, `__call` integration, and certificates.
8. **Target table completion.** v7 now chooses `luajit51-crescent` and has a
   first concrete target table. Remaining work is numeric-string grammar,
   exact integer preservation, table length proofs, and cdata operators.
9. **External declaration interface.** v7 should specify how checked/trusted
   declaration inputs enter certificates without specifying a concrete stdlib.

## Immediate Consolidation Recommendations

1. Add a v7 section for `unknown` movement: decide "top denotation, restricted
   concrete consumption" or another explicit rule.
2. Promote open/rest packs from "open question" to the next core-spec task.
3. Add a contextual-control effects mini-spec for `throws(E)` and
   `yields(Y,S)` before typing `error`, `pcall`, or `coroutine`.
4. Transcribe `ModuleEnv`, `DeclEnv`, `FfiEnv`, and `TargetProfile` bridge rules
   before writing `$Require`, `$GlobalScope`, or `$FfiC` `IntrinsicSpec`s.
5. Transcribe metatable lookup/assignment judgments before importing M6
   `__index` walking.
6. Transcribe rank-1 generics and first-order type-level computation before
   adding `$EachField` or deleting helper intrinsics.
7. Transcribe operator/metamethod lookup and truthiness rules as separate
   substrate, not as stdlib-name special cases.
8. Complete remaining `luajit51-crescent` target tables before relying on
   unresolved precision in implementation.
9. Specify external declaration input replay before relying on globals files,
   external declarations or trusted primitive values.
