# v10 kernel: term algebra + replayer + ported theory entries

Status: the ratified v10 core (`term_algebra/`, `replayer/`), cleanroom-built
against `docs/decisions/typechecker-v10-core-design.md` and
`docs/decisions/typechecker-v10-core-charter.md`, plus two theory entries
(`theories/algorithm_w.lua`, `theories/algorithm_j.lua`) ported onto it from
an earlier exploratory prototype. The prototype's own trust core
(`kernel.lua`, `registry.lua`) has been retired — git history preserves it;
this directory now holds only the current core and the ported theories. See
`NOTATION.md`'s "Port notes" section for exactly what changed structurally
in the port, and why.

## Files

- `NOTATION.md` — the term-algebra + certificate grammar. Read this first.
- `term_algebra/` — the trusted term algebra: sorted ABTs, de Bruijn binding,
  reference and fast tiers, `declare_signature`/`build`/`equal`/`shift`/
  `subst`/`match`/`instantiate`. `term_algebra/term_algebra_test.lua` and
  `term_algebra/term_algebra_parity_test.lua` (173 + 11 assertions) cover
  both tiers and their parity.
- `replayer/` — the trusted certificate replayer built over `term_algebra/`:
  registry declarations (`declare_rule`/`declare_axiom`), certificate node
  constructors (`hypothesis`/`cite_axiom`/`cite_rule`), and the replay engine
  (conclusion computation, taint, discharge, root acceptance).
  `replayer/replayer_test.lua` (144 assertions) covers declaration
  validation, replay success/failure paths, taint propagation, memoization/
  anti-laundering across kernel configs, and the MANDATORY DAG-shared-
  discharge acceptance case.
- `theories/hm.lua` — the shared Hindley-Milner judgment vocabulary
  (`hm-judgment` signature + `hm-abs`/`hm-app`/`hm-let` rule schemas +
  `hm-ax-lit` axiom) both ported theory entries build certificates against.
- `theories/algorithm_w.lua` — Algorithm W, ported: an untrusted producer
  (functional-substitution-map unification) emitting certificates over
  `hm.lua`'s vocabulary. `theories/algorithm_w_test.lua` (26 assertions):
  valid certificate replays across both term_algebra tiers, tampered
  certificates (well-foundedness cycle, skipped hypothesis discharge) fail
  replay, and the algorithm's documented weakness (no let-generalization)
  rejects a program a real let-polymorphic checker would accept.
- `theories/algorithm_j.lua` — Algorithm J, ported: the same Damas-Milner
  algorithm in its classic imperative reformulation (mutable ref cells +
  union-find-style mutation). `theories/algorithm_j_test.lua`
  (22 assertions): same shape as `algorithm_w_test.lua`, plus a direct
  check that W and J certify the identical conclusion for the identical
  term.
- `theories/discharge_scope_test.lua` (30 assertions) — the four DAG-shared-
  discharge scenarios the retired prototype used to motivate its
  ancestor-scoped discharge check, re-verified against the ratified core's
  different (per-parent, not per-shared-node) discharge mechanism. See its
  header and `NOTATION.md`'s "DAG sharing" section for how the two
  mechanisms correspond.

## What this directory used to be, and what happened to it

An earlier session built an exploratory, dinner-sized prototype here
(`kernel.lua` + `registry.lua` as the trust core, `theories/algorithm_w.lua`
+ `theories/algorithm_j.lua` as untrusted producers over opaque,
name-cited, string-payload certificates) to test whether the "v10"
validate-only-kernel shape held together at all. It did, and it
subsequently paused pending design sync with an external collaborator
("fable" — see `docs/decisions/typechecker-v10-design-sync.md`). That sync
produced `docs/decisions/typechecker-v10-core-charter.md` (cleanroom
discipline + scope) and `docs/decisions/typechecker-v10-core-design.md`
(the ratified term algebra + replayer design), built fresh over first
principles without reading the prototype (per the charter's firewall). Once
that design was ratified, this directory's prototype was brought into
conformance with it: the two theory entries were ported onto the new
grammar (this is that port), and the prototype's own trust core
(`kernel.lua`, `registry.lua`) — superseded by `term_algebra/` +
`replayer/` — was removed. `docs/decisions/typechecker-v10-core-design.md`'s
"Replayer: certificates, taint, discharge" section states the sequencing
explicitly: "The existing `kernel.lua` is not read, not patched; it gets
retired/ported at the conformance task."

## Choices made porting Algorithm W / Algorithm J (see NOTATION.md for detail)

- **Two-pass certificate construction** (type inference to completion, then
  a deterministic second walk building certificate nodes from the
  now-fully-resolved types) — forced by term_algebra's ground-term
  discipline having no analog to a "resolved later, from elsewhere"
  placeholder the way a shared substitution map or mutable cell provides.
- **The hypothesis a rule discharges is cited as an explicit premise of
  that rule**, not merely referenced somewhere inside another premise's
  subtree — forced by discharge-slot patterns only having access to
  bindings from the rule's own declared premise matches.
- **A variable reference needs no wrapping rule** — DAG-sharing the
  hypothesis leaf node directly wherever the bound name is referenced
  already is its derivation.
- **Two concrete base-type operators (`int_ty`, `bool_ty`)** rather than one
  polymorphic `con(name)` — term_algebra operators carry no free-form string
  payload.

None of these were expressiveness gaps requiring owner escalation — each is
a translation-mechanism difference the ratified design's own primitives
(schematic axioms, non-linear metavariables across premises, DAG-shared
certificate nodes) already provide for. See `NOTATION.md`'s "Port notes" for
the full correspondence, including two places where the new core is
strictly MORE verified than the retired prototype was (App's argument/
domain consistency; a rule's discharge target actually matching its
declared pattern) rather than merely equivalent to it.
