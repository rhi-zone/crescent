# Typechecker Framework Postmortem

Status: postmortem of a rejected direction. Retained as prior art and as a
record of why the rejection happened, so the failure mechanism is not lost.

The framework direction was rejected in commit `f3966774`
("docs: mark framework as rejected static analysis direction"). The map
(`docs/static-analysis-map.md`) records the rejection but states the reasoning
only as a single negative — "not automatically the right architecture just
because it is more general." This document reconstructs, from the record, what
was actually built, what its stated limits were, and what the rejection rested
on. It distinguishes documented reasons (quoted) from inferred ones (marked
"inferred").

## What Was Built And Validated

The framework was a three-layer design (`docs/typechecker-framework.md`, "Core
Distinction"): a theory-agnostic derivation checker and evidence format; a
theory layer (syntax classes, judgments, rules, oracles, soundness obligations);
and frontends that emit theory-specific evidence.

The implementation under `lib/type/framework/` reached a working binder-replay
milestone. By commit history, in order:

- `1cdb0d97` feat(type): validate framework certificates — shape validation
  (`shape.lua`, +532 lines with tests).
- `217cd2bc` feat(type): add first-order framework replay — `replay.lua`
  (+577 lines with tests).
- `846949d7` feat(type): add framework alpha normalization — `alpha.lua`
  (+239 lines with tests).
- `7b4934a8` feat(type): make replay alpha-aware (+186 lines).
- `db28fb73` feat(type): match scoped framework patterns (+282 lines).
- `146cced9` feat(type): replay binder conditions (+108 lines).
- `8c2d5fa7` refactor(type): carry replay binding scopes (+55/-23).

Each feature commit landed with tests. The replay test suite validates
alpha-equality for repeated metavariable matches, alpha-stable root digests,
`cond_binder_eq`/`cond_binder_neq`, and `cond_alpha_eq`
(`lib/type/framework/replay_test.lua`).

The binder-replay spec (`docs/typechecker-framework-binder-replay.md`) calls F4
"the first milestone capable of replaying STLC", requiring scoped opening,
binder identity equality/inequality, alpha-equivalence, and capture-avoiding
syntactic substitution (`cond_subst`). The last feature commit (`8c2d5fa7`,
"carry replay binding scopes") corresponds to that F4 binder-scope plumbing.

So: at the point of rejection, the framework had a shape validator, first-order
replay, alpha-aware replay, scoped pattern matching, and binder conditions — all
with passing tests — i.e. it had reached the milestone defined as STLC-capable.

## Stated Limits

The framework documents were explicit about what the framework was not
(`docs/typechecker-framework.md`, "Non-Goals"):

- not a universal inference engine;
- not a universal subtyping algorithm;
- not a claim that all type systems are sound;
- not a replacement for language-specific frontends;
- not a promise that every real-world checker can avoid trusted oracles.

The same doc was explicit that the framework must not define what a type is,
what subtyping means, whether inference exists, or any concrete runtime — those
are theory choices ("Framework must not define").

The framework's own validation bar was multiple unrelated theories, not Crescent
MR0: "The framework is not considered viable because it handles Crescent MR0. It
must be stress-tested against multiple unrelated theories." The planned theories
were STLC, a System F subset, a nominal OO sketch, a structural flow sketch, and
an imperative state sketch ("Validation Ladder").

## What The Rejection Rested On

The rejection commit `f3966774` is **purely documentary**. It adds
`docs/static-analysis-map.md` and relabels the framework docs from "current
track" to "rejected". It changes no implementation file. It cites no failing
test, no theory the framework could not express, and no demonstrated soundness
defect.

The documented reason, quoted in full from the map
(`docs/static-analysis-map.md`, "Framework" limits):

> - dead as "the next Crescent typechecker";
> - dead as the current type-system-agnostic framework direction;
> - not a Crescent typechecker;
> - not a source of Crescent semantics;
> - not automatically the right architecture just because it is more general.

And the framework doc's restated status (quoted):

> Status: rejected as the static-analysis direction. It is retained as prior
> art, not as the current Crescent typechecker direction[.]

The honest conclusion the record supports: **the framework was rejected on
judgment, not on a demonstrated defect.** It reached its STLC-capable milestone
with tests; no recorded artifact shows it failing a validation theory or
producing an unsound acceptance. The rejection is a judgment that the generality
was premature theory-specific commitment to a *shape* (theory/evidence-DAG/replay)
before the substrate question was settled — captured in "not automatically the
right architecture just because it is more general." The commit immediately
preceding the rejection (`e9615bde`, "docs: record project value framing")
reframes project values; the rejection follows from that reframing, not from a
framework failure.

Inferred (not stated in the record): that the framework's representation
*pre-committed* to derivation DAGs and binder-aware replay as the universal
shape, when the agnostic redesign wanted to withhold even "evidence is a
derivation tree" as a substrate assumption. The agnostic object model makes this
explicit — "The substrate does not require all evidence to be proof trees"
(`docs/agnostic-static-analysis-object-model.md`, Evidence) — which reads as a
direct reaction to the framework's DAG-centric model. This is the most plausible
mechanism, but it is reconstruction; the rejection commit does not say it.

What the record does **not** support, and this postmortem will not manufacture:
a tidy story in which the framework was tried against its validation theories
and broke. It was not run against System F, the nominal sketch, the flow sketch,
or the state sketch; those theories were planned, not validated. The rejection
preceded that stress test rather than resulting from it.

## Lessons Carried Forward

These are the framework's validated, substrate-independent findings. They are
not tied to the rejected representation, and the agnostic direction must
preserve them.

### Source binder names are never semantic identity

The framework established this directly: "Replay must never compare binder
source names as semantic identity"; "binder IDs are source labels only; semantic
binder identity is lexical position after F1 projection"
(`docs/typechecker-framework-binder-replay.md`, "Scope Model"). The replay tests
enforce it (alpha-equality for repeated metavariable matches).

The agnostic lambda pass independently re-derived the same finding from first
principles — "`name` and `param` are source labels in the artifact... not
semantically stable binder identities by themselves"
(`docs/agnostic-static-analysis-lambda.md`). Two independent design tracks
converging on this is strong evidence it is a real, representation-independent
constraint, not an artifact of either design.

### Capture-avoidance must be checkable, not assumed

The framework's `cond_subst` made capture-avoidance a *checked* condition:
replay "rejects if substitution would capture a free reference from
`replacement` and cannot be avoided by alpha-renaming binders in `source`"
(`docs/typechecker-framework-binder-replay.md`, "Syntactic Substitution"), and
it explicitly does not beta-reduce, normalize, or prove semantic equality. The
agnostic lambda pass carries this forward as a checkable cross-evidence
dependency (`not_free_in` produced by a separate `free_var_scan`, consumed by
`beta_step`) rather than an assumption inside the substitution code.

### Alpha-stable digests and identity

The framework required alpha-stable root digests — "two alpha-equivalent proofs
producing different root digests" was a rejected fixture, and "STLC alpha-renamed
fixtures produce the same root digest" was an F4 acceptance criterion
(`docs/typechecker-framework-binder-replay.md`, "Rejected STLC Fixtures",
"F4 Acceptance"). Any agnostic identity scheme for claim args under binders must
preserve alpha-stability; the object model names structural-identity-vs-hosted-
identity (alpha-equality) as an open divergence the mechanization must probe
(`docs/agnostic-static-analysis-object-model.md`, "Open item: claim-arg schemas
vs structural identity").

### The trust discipline

The framework's strongest structural defense: only the framework checker and the
declarative theory spec are trusted; "Frontends, inference engines, solvers,
annotation parsers, and IDE integrations are evidence producers... not trusted
for soundness", and computation that cannot be declarative "must appear as
evidence-producing code whose outputs are checked, or as an explicit
oracle/trusted plugin boundary" (`docs/typechecker-framework.md`, "Core
Distinction"). The agnostic docs initially dropped this for hosted checkers and
must re-state it — see the object model's "Design Obligation: Hosted-Checker
Trust" (`docs/agnostic-static-analysis-object-model.md`), which applies the same
discipline to per-semantics Lua checkers. This is the single most important
finding to carry forward, because losing it is how ad-hoc accumulation re-enters.
