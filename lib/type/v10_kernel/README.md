# v10 kernel prototype

**Status: exploratory, dinner-sized. Not a production module.** This tests
whether the "v10" trust-core shape holds together at all — a domain-blind
certificate *replayer* as the only trusted code, plus an untrusted theory
registry, plus one founding entry (Algorithm W) that proves the registration
protocol end to end. It does not attempt to close every design question; see
`TODO.md` (repo root) for what is deliberately out of scope.

## Files

- `NOTATION.md` — the certificate / rule-schema grammar. Read this first.
- `kernel.lua` — the trusted replayer. Domain-blind: it knows about schemas,
  citations, and structural well-formedness only.
- `registry.lua` — theory registry: `register(schema)` checks shape only
  (never soundness); `lookup(name)` is what the kernel uses during replay.
- `theories/algorithm_w.lua` — Algorithm W, the founding theory entry. An untrusted *producer*:
  it runs its own toy HM-style inference and emits a certificate citing the
  registered W rule schemas. The kernel never executes this file's logic.
- `kernel_test.lua` — a valid certificate replays; three independently
  tampered certificates each fail replay (forged citation, well-foundedness
  cycle, skipped hypothesis discharge); and W's own known limitation is
  demonstrated (not fixed).

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
