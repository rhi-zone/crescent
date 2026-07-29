# v10 kernel: theory entries + pilot over the canonical cleanroom core

Status: this directory holds the ported Hindley-Milner theory entries
(`theories/`) and the flow-narrowing pilot (`pilot/`), built on the
CANONICAL v10 core in `lib/type/v10_cleanroom/` (term algebra + certificate
replayer), per the owner-ratified canon swap
(`docs/decisions/typechecker-v10-core-design.md`, "Canon swap: cleanroom
core").

The core that used to live here (`term_algebra/` + `replayer/`, including
the fast tier) is retired — git history preserves it. The retirement
evidence is the differential adjudication
(`docs/typechecker-v10-parity-adjudication.md`): 7 confirmed divergences
against the F1–F13 rulings, all bugs in the prior implementation (the F8
hypothesis-identity conflation being soundness-relevant), zero
cleanroom-side bugs. The fast tier was built against the retired core's
internals and retires with it; it will be rebuilt against the canonical
reference as a separate, axiom-carrying effort (`kernel-interner-sound` /
`kernel-lazy-subst-sound`) — see `TODO.md`.

## Files

- `NOTATION.md` — the term-algebra + certificate grammar as this
  directory's consumers use it. Read this first.
- `lib/type/v10_cleanroom/` (elsewhere, the core itself) —
  `term_algebra.lua` (sorted ABTs, de Bruijn binding, reference tier:
  `declare_signature`/`var`/`meta`/`build`/`equal`/`shift`/`subst`/
  `match`/`instantiate`/`is_ground`/`is_closed`/`sort_of`) and
  `replayer.lua` (registries, `declare_rule`/`declare_axiom`, root-strict
  `replay`, read-only `observe`, taint, explicit discharge).
- `theories/hm.lua` — the shared Hindley-Milner judgment vocabulary
  (`hm-judgment` signature + `hm-abs`/`hm-app`/`hm-let` rule schemas +
  `hm-ax-lit` axiom) both theory entries build certificates against,
  declared into a caller-owned registry.
- `theories/algorithm_w.lua` — Algorithm W: an untrusted producer
  (functional-substitution-map unification) emitting certificates over
  `hm.lua`'s vocabulary. `theories/algorithm_w_test.lua`: valid
  certificate replays, tampered certificates (malformed citation,
  well-foundedness cycle, skipped hypothesis discharge) fail replay, and
  the algorithm's documented weakness (no let-generalization) rejects a
  program a real let-polymorphic checker would accept.
- `theories/algorithm_j.lua` — Algorithm J: the same Damas-Milner
  algorithm in its classic imperative reformulation (mutable ref cells +
  union-find-style mutation). `theories/algorithm_j_test.lua`: same shape
  as W's suite, plus a direct check that W and J certify the identical
  conclusion for the identical term.
- `theories/discharge_scope_test.lua` — the four DAG-shared-discharge
  scenarios the historical kernel used to motivate its ancestor-scoped
  discharge check, re-verified against the ratified core's different
  (per-parent, not per-shared-node) discharge mechanism.
- `pilot/` — the flow-narrowing pilot: `addr_v1.lua` (program-point
  addressing signature), `narrow_pilot_v1.lua` (pilot type vocabulary),
  `flow_narrow_v1.lua` (narrowing theory: rules + syntax-facts axiom),
  `pilot_initial_facts_v1.lua` (annotation-facts axiom),
  `prover_narrow.lua`/`prover_addr.lua`/`prover.lua` (the two-pass
  certificate-emitting prover over real crescent source), each with its
  test file.

## History

An earlier session built an exploratory prototype here (`kernel.lua` +
`registry.lua`), retired at the conformance task. Its successor — this
directory's own cleanroom `term_algebra/` + `replayer/` — was then itself
superseded by the fable cleanroom reimplementation in
`lib/type/v10_cleanroom/` after the differential adjudication found seven
A-side bugs against the owner-ratified F1–F13 rulings and none on the
cleanroom side. Dependents (the theory entries and the pilot) were ported
onto the canonical API meaning-preserved; the porting-era findings
recorded in `NOTATION.md`'s "Port notes" (two-pass construction,
hypothesis-as-premise, DAG-shared variable references, concrete base-type
operators) carry over unchanged in meaning.
