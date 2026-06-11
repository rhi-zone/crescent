# Agnostic Static Analysis: STLC Validation

Status: validation design pass, mechanized.

This document instantiates `docs/agnostic-static-analysis-object-model.md` with a
simply-typed lambda calculus (STLC) semantics. It is ladder rung 4 — the first
rung that introduces hosted `type` vocabulary, typing contexts, and the
arg-schema pressure — and per the compressed ladder the last synthetic rung
before a tiny Crescent slice.

This is not a typechecker for any real language. It is a hosted semantics that
reasons about typing judgments. The load-bearing question is whether hosted
`type` vocabulary, typing contexts, and deep derivation trees can live entirely
in claim args and evidence without forcing any of `Type`, `Context`, or
`Judgment` into the substrate.

Mechanized in `lib/type/analysis/stlc.lua` (`stlc.min`) and `stlc_test.lua` (45
assertions). The substrate (`init.lua`) was **not changed**.

## Scope

Included:

- artifact-backed STLC terms (type-annotated abstractions);
- hosted `type` vocabulary (base types + arrow types);
- hosted typing contexts (Γ as ordered bindings inside claim args);
- typing-judgment claims `has_type(Γ, term, T)`;
- the var, abs, app typing rules as evidence methods;
- deep evidence trees (abs/app consume previously-accepted `has_type` claims);
- a trusted-typing boundary (`trusted_type_axiom`).

Excluded:

- type inference (a producer concern; the checker only checks supplied claims);
- subtyping (STLC has structural type identity; `subtype` is rejected as a
  predicate here);
- polymorphism, type variables, unification;
- substitution / evaluation (that is the untyped-lambda rung's job);
- substrate-level types, contexts, judgments, or binders.

## Design Pressure

The untyped-lambda rung forced a decision about binding without inheriting the
rejected framework's binder model. STLC adds three new pressures at once:

1. **Hosted `type` vocabulary without substrate types.** `has_type(Γ, t, T)`
   carries `T` (a base type or an arrow over base/arrow types) and `Γ` as hosted
   values *inside the claim args*. If the rung forces a substrate `Type`,
   `Context`, or `Judgment` object kind, the agnostic design has failed — and
   that is a valid finding to record, not something to force past.

2. **Typing contexts as hosted data.** The object-model pass removed
   `Claim.scope` precisely to force this test: Γ must live in `args`. The
   questions: does claim identity behave correctly when Γ is part of structural
   identity, and does context extension Γ,x:A work as an evidence input across
   separately-evidenced claims?

3. **Derivations as deep evidence.** This is the first rung where evidence trees
   nest: an `app_rule` over two `has_type` premises, one of which is itself an
   `abs_rule` over another `has_type` premise. Unknown-propagation and
   order-independence must survive multi-level derivations.

The intended result is:

```text
type, context, and derivation are hosted vocabulary; the substrate still tracks
claims, evidence, dependencies, trust, and unknown/rejected results unchanged.
```

## Semantics Entry

```text
SemanticsEntry {
  id = "stlc.min",
  version = "0",
  claim_predicates = [
    "has_type",
    "well_typed_type"
  ],
  observation_predicates = [
    "term_shape",
    "type_shape"
  ],
  evidence_methods = [
    "var_rule",
    "abs_rule",
    "app_rule",
    "type_shape_check",
    "trusted_type_axiom"
  ],
  trusted_methods = [
    "trusted_type_axiom"
  ]
}
```

The substrate does not interpret any of these predicates or methods. `stlc.min`
owns their meaning.

## Hosted Grammars (opaque to the substrate)

### Type

```text
Type =
  base(name)
| arrow(from: Type, to: Type)
```

STLC has no subtyping, so type identity is **structural** — two types are equal
iff their serializations are equal (`type_eq` via the substrate's `_serialize`).
A richer subtyping discipline would be a *different* hosted semantics, and the
adversarial checks below reject promoting `subtype` into `stlc.min`.

### Term

```text
StTerm =
  var(name)
| lam(param, paramType: Type, body: StTerm)
| app(fn: StTerm, arg: StTerm)
```

Abstractions are type-annotated (`lam(x, A, body)` is `λx:A. body`), so the abs
rule has the binder's domain type without inference. Terms are stored in
artifacts and referenced by Id, exactly as in the untyped-lambda rung.

### Context

```text
Context = [ Binding ... ]      Binding = { name, type: Type }
```

Γ is an *ordered list* of bindings with most-recent-wins lookup, so shadowing is
expressible and order is significant. The context lives inside `has_type` args as
plain `ArgValue` data; the substrate sees only its serialization. There is **no**
substrate context slot — `Claim.scope` was removed for exactly this reason
(object model, "Removed: Claim.scope").

## Claim Forms

### has_type

```text
has_type(Γ, term_ref, T)
```

Under typing context Γ (hosted data inline in args), the term in artifact
`term_ref` has type `T` (hosted data inline). Γ and `T` are structurally part of
claim identity, so `has_type(Γ1, t, T)` and `has_type(Γ2, t, T)` are distinct
claims — see "Claim identity under context".

### well_typed_type

```text
well_typed_type(T)
```

`T` is a structurally valid STLC type. Not strictly needed by the rules
(`parse_type` validates inline), kept as an explicit predicate so a
well-formedness obligation can be made first-class if a later rung wants it.
Validated by `type_shape_check`.

## Evidence Methods (the typing rules)

Each rule re-derives its conclusion from the artifact term plus its premise
claims, then checks the asserted `(Γ, term, T)` in the claim against what the
rule produces. The checker validates its own inputs (parse-not-cast) and never
trusts their shape — this is the hosted-checker trust discipline.

### var_rule (Var)

```text
x:A ∈ Γ
─────────── (most-recent-wins lookup)
Γ ⊢ x : A
```

No premise claims. The term must be a variable bound in Γ, and the asserted type
must match the binding. Depends only on the term artifact content.

### abs_rule (Abs)

```text
Γ,x:A ⊢ body : B
────────────────────────
Γ ⊢ (λx:A. body) : A→B
```

One premise: the body typed under the **extended** context Γ,x:A. The extension
is a hosted operation (`extend`) on the context data; the checker computes Γ,x:A
and compares it *structurally* to the premise claim's own context. It also checks
that the asserted arrow's domain is the binder annotation, the premise term is
the abstraction body, and the premise type is the arrow codomain.

Dependencies: the accepted body premise claim, the abstraction's term artifact,
the body's term artifact.

### app_rule (App)

```text
Γ ⊢ f : A→B    Γ ⊢ a : A
──────────────────────────
Γ ⊢ (f a) : B
```

Two premises, both under the conclusion's context Γ (no extension). The checker
verifies both premises share Γ structurally, the premise terms are the
application's fn/arg, the fn premise type is an arrow whose domain equals the arg
premise type, and the codomain equals the asserted type.

Dependencies: both accepted premise claims, the application's term artifact.

### type_shape_check

Validates `well_typed_type(T)` by parsing `T` as a Type.

### trusted_type_axiom

Admits `has_type(Γ, term, T)` through a visible trust boundary (e.g. an external
or FFI signature) named in the evidence result. The verdict does not check the
typing; it admits it under explicit trust, recorded as a trusted-boundary
dependency and surfaced in the trust summary.

## Worked Examples

All four are mechanized in `stlc_test.lua`.

### 1. Acceptance — identity, two-level derivation

```text
artifacts: body = var(x), ident = lam(x, A, var(x))
premise:    (x:A) ⊢ x : A            via var_rule          [no inputs]
conclusion:  ⊢ (λx:A. x) : A→A        via abs_rule          [input = premise]
```

Result: both accepted. The conclusion's `dependency_graph` carries an
`accepted_claim` edge to the var premise and an `artifact_content` edge to the
abstraction term — the deep-evidence edge is visible.

A genuinely three-level derivation is also mechanized:
`⊢ (λf:A→B. λa:A. f a) : (A→B)→(A→B)` — abs over abs over app over two vars.

### 2. Acceptance — application

```text
artifacts: tf = var(f), ta = var(a), tapp = app(var(f), var(a))
Γ = f:A→B, a:A
  Γ ⊢ f : A→B     via var_rule
  Γ ⊢ a : A       via var_rule
  Γ ⊢ (f a) : B   via app_rule   [inputs = the two var claims]
```

Result: all accepted; the app conclusion depends on both premises.

### 3. Rejection — ill-typed term

Self-application `(x x)` with `x:A`: the function premise `x:A` does not have an
arrow type, so `app_rule` rejects.

```text
Γ = x:A
  Γ ⊢ x : A          accepted (var)
  Γ ⊢ (x x) : A      rejected (app_rule: function premise is not an arrow)
```

Also mechanized: abs with the wrong arrow domain, var on an unbound variable, and
app with an argument-type mismatch — each rejected.

The rejection is an *evidence outcome*, not a claim of falsity: it only fails
under `stlc.min`'s rules.

### 4. Unknown propagation through a deep derivation

The innermost var premise is given no evidence (unknown). The abs above it cannot
fire, so the conclusion stays unknown — never rejected.

```text
  (x:A) ⊢ x : A        unknown   (no evidence)
   ⊢ (λx:A. x) : A→A    unknown   (premise unavailable)
  rejected count: 0     (unavailable ≠ refused)
```

This is the substrate's `unknown`-is-not-proof rule operating across a multi-level
typing derivation: an unaccepted premise propagates `unknown` up the tree, and
the abs rule returns `unknown` (retry), distinct from `rejected`.

## Claim Identity Under Context

This is the load-bearing probe for **open question 4** (binders without the
framework representation) as it interacts with contexts and types.

The position established by the prior rungs is taken here without exception:
**substrate claim identity is purely structural; finer hosted identities are
hosted business** (object model, arg-schema findings). The mechanization probes
this for contexts:

- **Γ is part of structural identity.** `has_type(Γ1, t, T)` and
  `has_type(Γ2, t, T)` are *distinct* substrate claims when Γ1 ≠ Γ2
  (`stlc_test.lua`). This is correct and necessary: a judgment's truth depends on
  its context, so two judgments differing only in Γ are genuinely different
  facts.
- **Structurally identical Γ yields the same claim key.** Two independently
  constructed but structurally equal contexts produce the same claim — identity
  is stable, not object-identity-based.
- **Binding order is part of identity.** `[x:A, x:B]` and `[x:B, x:A]` are
  distinct claims, because Γ is an ordered list and shadowing changes lookup. The
  substrate gets this for free from structural serialization of the list.
- **Context extension across separately-evidenced claims works.** The abs
  premise lives under Γ,x:A, evidenced by its *own* `var_rule`; `abs_rule`
  computes Γ,x:A as hosted data and compares it structurally to the premise
  claim's context. A premise under the wrong context is rejected. Context
  extension is therefore an ordinary cross-claim relation — the extended-context
  claim is a separate claim with its own evidence — not a substrate operation.

The conclusion for the tiny Crescent slice that inherits this position:
**typing contexts ride structural claim identity with no substrate support and no
divergence.** Unlike alpha-equivalence (where structural identity is *finer* than
the hosted notion), contexts want exactly structural identity — two judgments are
the same fact iff their contexts are structurally the same list. STLC does not
exercise the structural-vs-hosted *divergence* the lambda rung found; it confirms
the structural default is *right* for contexts. See "Arg-schema finding" below.

## Arg-Schema Finding (object model open item)

The lambda rung found that structural substrate identity is *finer* than the
hosted alpha-equivalence: `λx.x` and `λy.y` are one fact to the lambda semantics
but two claims to the substrate, and the lambda checker reconciles this inside
its own evidence (alpha-normal-form comparison), never by asking the substrate to
merge claims.

STLC reproduces the same divergence at the *type* level and resolves it the same
way:

- **Types ride structural identity cleanly.** Arrow types compare structurally;
  STLC has no subtyping, so structural type identity is exactly the hosted
  notion. No divergence at the type level.
- **Terms-in-judgments inherit the lambda divergence.**
  `has_type(Γ, λx:A.x, A→A)` and `has_type(Γ, λy:A.y, A→A)` are distinct
  substrate claims (alpha-variant terms). The mechanized probe confirms this and
  then shows STLC **does not need them unified**: each alpha-variant is derived
  independently from its own var premise, and both succeed. STLC never has to ask
  the substrate to treat alpha-variant judgments as one claim. The structural
  default is therefore not just tolerable but *sufficient* — the hosted semantics
  builds a separate derivation per syntactic representative, which is exactly what
  a syntax-directed type checker does anyway.

The position recorded for open item "claim-arg schemas vs structural identity":
**no schema mechanism is forced, and no claim-identity override is needed.** Two
hosted notions live over the structural substrate identity without the substrate
learning either — alpha-equivalence (finer than structural; reconciled in
evidence) and structural type/context identity (equal to structural; free). The
tiny Crescent slice inherits: do not add an arg-schema or claim-identity-override
mechanism to the substrate on STLC's account; the structural default carried
every STLC judgment.

## Adversarial Checks

Mechanized in `stlc_test.lua`.

### Do not promote type vocabulary to substrate predicates

`type_of`, `subtype` (and by the same path `context`, `binder`) are not
`stlc.min` claim predicates. The registry rejects a `CheckRequest` containing
them — the registry is a contract, not a wish list — with an error naming the
predicate. The substrate never learns what a type or subtype is.

### Reject evidence methods not in the registry contract

An evidence method not listed for `stlc.min@0` (here `unification`) is rejected by
`validate_request` before any checking, with an error naming the method.
Inference-flavored methods do not get in by the back door.

### Substrate stores no Type/Context/Judgment objects

An adversarial test walks every Id stored in the analysis state after running the
identity derivation and asserts each lives in a substrate-owned space
(`artifact`/`claim`/`ev`/`trust`/`observation`) — never `type`, `context`,
`binder`, or `judgment`. It further asserts every artifact's `kind` is the
descriptive `syntax_tree`, never a substrate `Type`/`Context` kind: the type and
context exist only inside opaque claim args.

## Design Pressure Found

What buckled: **nothing in the substrate.** No substrate change was required.
`stlc.min` is a pure consumer of the existing claim database, dependency tracker,
and worklist checker. The three new pressures resolved as follows:

- **Hosted `type` vocabulary stayed hosted.** Types are `ArgValue` data inside
  claim args, parsed-not-cast at the checker boundary exactly like `Prop` and
  `LamTerm`. The substrate's `ArgValue` boundary (the object-model finding that
  opaque args must be serializable data, not TS-`unknown`) carried arrow types
  with no change. No `Type` object kind appeared.

- **Typing contexts stayed hosted, and structural identity was correct for
  them.** Γ rode `args` with no substrate slot. The `Claim.scope` removal is
  *vindicated*: contexts need no dedicated slot, and structural claim identity is
  exactly right for context-dependent judgments (finer would be wrong, coarser
  would be unsound). Context extension Γ,x:A is a cross-claim relation, not a
  substrate primitive.

- **Deep evidence trees worked under the existing worklist fixpoint.** abs-over-
  app-over-var (three levels) is accepted; unknown propagates up an
  unevidenced-premise tree as `unknown` (never `rejected`); and shuffled
  submission orders over the full derivation converge to the same accepted set.
  The order-independence the lambda rung first exercised holds across the deeper
  STLC trees with no new mechanism — premise-not-yet-accepted returns `unknown`
  (retry), the same discipline `beta_step` needed.

One observation carried forward from the lambda rung holds again: the
`Dependency` edge from a conclusion to a premise records *that* the conclusion
depends on the premise but not the premise's *role* (function premise vs argument
premise vs body premise). For `stlc.min` the pinned per-method input order names
the role positionally (app_rule input 1 = fn, input 2 = arg), so the unrole'd
edge is acceptable, as in the lambda rung. A hosted semantics with many distinct
premise roles wanting role-tagged edges remains a future-pass finding, not a
defect here.

## Mechanization Findings (lib/type/analysis)

- **The object model survived STLC with no substrate change.** Rung 4 is the
  rung the design called "genuinely load-bearing" — first hosted `type`
  vocabulary, contexts, and arg-schema pressure. It passed: 45 assertions, 108
  prior assertions preserved (153 total), substrate untouched.

- **Structural identity is the *right* default for contexts (open item 4
  moved).** The lambda rung established that structural identity is finer than
  hosted alpha-equivalence and the hosted checker reconciles the gap in evidence.
  STLC adds the complementary data point: for typing contexts, structural
  identity is *exactly* the hosted notion, so there is no divergence and nothing
  to reconcile. The arg-schema open item is now answered for STLC: no schema
  mechanism and no identity override is needed; two hosted identity notions (alpha
  in evidence, structural for contexts/types) coexist over the one structural
  substrate identity. Recorded in the object-model doc.

- **A type-annotated binder removes inference from the abs rule cleanly.**
  Because `lam` carries `paramType`, `abs_rule` reads the domain from the term and
  checks consistency, rather than inferring it. This keeps the checker a *checker*
  — the design's "evidence before inference" invariant — and leaves inference to a
  (future, untrusted) producer that would emit the same `has_type` claims for the
  checker to validate.

## Next Pass

This was the last synthetic rung. The next rung is the tiny Crescent slice: a
small but real subset of Crescent/Lua semantics checked over actual files in
`lib/`, with capability-reachability and imperative-store pressure absorbed from
the real target. The slice inherits the position this rung established:
**structural substrate claim identity carries hosted types and contexts with no
arg-schema or identity-override mechanism**, and hosted reconciliation of any
finer identity (alpha-equivalence) stays in evidence. No further synthetic rungs
are scheduled. See `docs/agnostic-static-analysis-design.md`, "Next Pass".
