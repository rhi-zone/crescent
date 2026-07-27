# v10 kernel prototype

**Status: exploratory, dinner-sized. Not a production module.** This tests
whether the "v10" trust-core shape holds together at all — a domain-blind
certificate *replayer* as the only trusted code, plus an untrusted theory
registry, plus a running collection of theory entries registered one at a
time, each one's registration attempt used to pressure-test the kernel +
evidence-grammar + registry architecture (not to prove any single
algorithm's precision). Algorithm W was the founding entry, proving the
registration protocol end to end; Algorithm J is the second entry, added
specifically to stress-test registry/kernel *genericity* against a
structurally different producer (see "Algorithm J: the genericity finding"
below). It does not attempt to close every design question; see `TODO.md`
(repo root) for what is deliberately out of scope.

## Files

- `NOTATION.md` — the certificate / rule-schema grammar. Read this first.
- `kernel.lua` — the trusted replayer. Domain-blind: it knows about schemas,
  citations, and structural well-formedness only.
- `registry.lua` — theory registry: `register(schema)` checks shape only
  (never soundness); `lookup(name)` is what the kernel uses during replay.
- `theories/algorithm_w.lua` — Algorithm W, the founding theory entry. An untrusted *producer*:
  it runs its own toy HM-style inference and emits a certificate citing the
  registered W rule schemas. The kernel never executes this file's logic.
- `theories/algorithm_j.lua` — Algorithm J, the second theory entry: the
  same Damas-Milner algorithm as W, in its classic imperative reformulation
  (mutable ref cells + union-find-style `prune`/mutation instead of W's
  functional substitution map). An untrusted producer exactly like W. See
  "Algorithm J: the genericity finding" below.
- `kernel_test.lua` — Algorithm W's suite: a valid certificate replays;
  three independently tampered certificates each fail replay (forged
  citation, well-foundedness cycle, skipped hypothesis discharge); and W's
  own known limitation is demonstrated (not fixed).
- `algorithm_j_test.lua` — Algorithm J's suite, mirroring kernel_test.lua's
  shape exactly: a valid J certificate replays through the same kernel with
  zero kernel changes; the same three tamper categories fail replay; and J
  reproduces W's identical non-generalizing-let limitation on the identical
  term (not just a similar one), confirming W and J certify the same
  things.

## Choices made for this prototype (simplest workable option, stated plainly)

- **Directory name**: `v10_kernel`, following the existing sibling
  convention of `<version>_<short-descriptor>` (`v7_mr0`) alongside bare
  `static-vN` and `v9`.
- **Certificate serialization**: a plain nested Lua table (no wire format).
  In line with "pure Lua is the baseline"; a real wire format is a separate,
  later concern.
- **Judgment/rule-schema shape**: kept to exactly what W's four constructs
  need — one judgment (`has_type`), five rule names, and two structural
  flags (`assumes`, `discharges`) per schema. See `NOTATION.md`.
- **Hypothesis discharge check**: id-match over the reachable node set, not
  lexical-ancestry-checked. Stated as a simplification, not a closure — see
  `NOTATION.md`'s "Stated simplification" section and `TODO.md`.
- **Algorithm W's let-binding**: does not generalize (no let-polymorphism).
  This is what produces the documented "first call site pins the type
  variable" weakness on purpose — see `w.lua`'s header comment and
  `kernel_test.lua`'s "known limitation" case.
- **Algorithm J's let-binding**: matches W — also does not generalize, on
  purpose, so W and J are comparable on the same known weakness rather than
  J accidentally being "more correct." See `algorithm_j.lua`'s header and
  `algorithm_j_test.lua`'s "known limitation" case.
- **Algorithm J's rule-schema registration**: reuses W's `RULES` table
  verbatim rather than declaring an identical duplicate — see "Algorithm J:
  the genericity finding" above for why that's correct, and the naming
  tradeoff (J's certificates cite rules prefixed `W-`) it leaves open.
- **Term binder representation**: de Bruijn indices, not source names — see
  "De Bruijn indices: standardizing term binders" below.

## De Bruijn indices: standardizing term binders (2026-07-27)

Both theories originally represented lambda terms with named string binders
(`{ tag = "abs", param = "x", ... }`) and looked up variables through a
metatable-chained, name-keyed environment (`env[name]`, innermost binding
shadowing outer ones because `setmetatable(..., { __index = env })`
resolves innermost-first). Both now use de Bruijn indices instead: `var`
terms carry an integer `index` (0 = nearest enclosing binder), and the
environment each theory's `infer` threads is a depth-indexed list extended
by prepending one entry per binder — never looked up by name. A purely
cosmetic display name still rides alongside every binder and reference
(`abs.param`, `let.name`, `var.name`) for hypothesis-payload and
conclusion readability only; it is never consulted for lookup or any
identity/soundness-relevant comparison. Full grammar and rationale in
`NOTATION.md`'s "Term binder representation: de Bruijn indices" section.

This was a deliberate design decision, not scope creep — made this session
after weighing it against the three carry-forward lessons from the rejected
`lib/type/framework/` attempt (`docs/typechecker-framework-postmortem.md`):

- **Binder identity as lexical position (Lesson 1) and alpha-stable digests
  (Lesson 3) are now structurally resolved** — true by construction of the
  representation, not by an implementation accident (previously, shadowing
  only worked because Lua's table-chain lookup happens to resolve
  innermost-first; the certificate grammar itself tracked nothing about
  binder identity).
- **Capture-avoidance as a checked condition (Lesson 2) is only partially
  addressed, and is NOT being claimed as closed.** De Bruijn shift/subst is
  capture-avoiding by construction of one correct algorithm, which narrows
  what a future checked condition needs to verify — but the kernel's
  discipline is to trust no producer's code (W and J are untrusted producers
  `kernel.lua` never runs), and nothing here replays or verifies that either
  producer's `infer` actually implements that correct algorithm. This
  remains open; see `TODO.md`.

Unification and the rest of the type-level machinery (`unify`, `resolve`,
`deep_resolve`, `show_type` in `algorithm_w.lua`; the mutable-cell/
union-find analogues in `algorithm_j.lua`) operate purely on `WType`/`JType`
and needed no changes — only the term representation and the environment-
threading in `infer`'s `abs`/`let`/`var` cases changed. `kernel.lua` and
`registry.lua` needed zero changes: both already treat `conclusion` and
hypothesis `payload` as fully opaque, with no code path that distinguishes a
de Bruijn payload from a named one.

## Algorithm J: the genericity finding

Algorithm J was built to answer one question: does a producer built in a
structurally different implementation style — mutable ref cells and
union-find-style mutation, instead of W's functional substitution map —
register and replay through the exact same `kernel.lua` and evidence
grammar with zero kernel/registry changes, zero special-casing? Yes.
`kernel.lua` and `registry.lua` were not touched to build `algorithm_j.lua`
or `algorithm_j_test.lua`. This held because `registry.lua` already scopes
schemas per `Registry` instance (one per theory) and `kernel.lua` only ever
checks a certificate's citations against the ONE registry passed to
`M.replay` — it has no way to know, and never needs to know, that a schema
object is also registered under a different theory name elsewhere.

**Do W and J share rule schemas, or does J register its own?** They share
them, literally — `algorithm_j.lua`'s `register_rules` iterates
`algorithm_w.lua`'s exported `M.RULES` table and registers those same five
schema objects (W-Lit/W-Var/W-Abs/W-App/W-Let) into J's own registry
instance. This is correct, not just convenient: a `RuleSchema` (judgment +
arity + assumes/discharges) describes a JUDGMENT, and W and J derive the
exact same judgment (Damas-Milner `has_type` over the same four-construct
calculus) — the schema was never W-specific to begin with, only
W-registered-first. The one cost is cosmetic: J's certificates cite rules
literally named `W-Lit` etc., which reads oddly for a J-derived
certificate. Renaming to algorithm-neutral names (`HM-Lit`, ...) would fix
that but touches `algorithm_w.lua`'s already-committed names and
`kernel_test.lua`'s existing by-name lookups — judged out of scope for this
entry; see `TODO.md`.

**What this confirms about the evidence grammar's design** (not just a code
fact — a design finding worth keeping): `NOTATION.md`'s `RuleSchema` shape
is already algorithm-agnostic by construction, because it only ever
describes the judgment a node concludes and the node's structural shape
(premise arity, assumes/discharges permission) — never anything about HOW a
producer derives that conclusion. Algorithm J needed no new schema fields,
no new judgment, no kernel awareness of "mutation" vs "substitution." The
distinction between W and J is entirely inside each theory file's untrusted
`infer`/`unify`; the certificate the kernel replays is, correctly, blind to
it.

To make W and J genuinely comparable rather than superficially similar,
`algorithm_j.lua` deliberately reproduces W's documented non-generalizing-
let weakness (see its header) — `algorithm_j_test.lua`'s "known limitation"
case runs the identical term `kernel_test.lua` uses and gets the identical
rejection shape (a `cannot unify` error on the second, differently-typed
call site).

## Relationship to prior art in this repo

- `lib/type/framework/` attempted a much more general version of the same
  idea (theory-agnostic derivation checker + evidence format) and reached a
  working alpha-aware, binder-scoped replay milestone before being rejected
  — documented reason: "not automatically the right architecture just
  because it is more general," not a demonstrated defect
  (`docs/typechecker-framework-postmortem.md`). This prototype deliberately
  does NOT carry over `framework/`'s alpha-stability / binder-identity /
  capture-avoidance machinery — that is out of scope here (see `TODO.md`).
- `lib/type/v9/certificate.lua` is a reserved, no-op certificate-emitter
  seam in the current v9 checker lineage; it is unrelated code (a stub
  waiting for a real emitter in a different architecture), not reused here.
- `docs/decisions/kernel-recommendation.md` is a separate, already-ratified
  decision about the *checking-discipline* kernel (bidirectional +
  cycle-guarded subtyping) for the v9 lineage's own "v1 scope." That
  document's "v1" is unrelated to this directory's "v10" — different
  session, different question (subtyping-algorithm choice vs.
  trust-architecture shape).
- `docs/decisions/typechecker-v10-proposal.md` is the design-conversation
  record this prototype tests (the proposal + its in-session critical
  evaluation, not yet a ratified plan). This README does not restate it.
