# 2026-07-05 — typechecker declarative core

Durable outputs of the 2026-07-05 owner-led session that interrogated the
semantics-linter redesign sketch (`docs/semantics-linter-working-notes.md`,
NOT modified by this artifact) through ~10 adversarial subagent audits and
arrived at a much-simplified declarative formulation, certified by the
owner.

**The story, one paragraph.** The sketch was machinery-first; the owner
demanded a declarative design ("HM's what, five rules?"). A declarative
draft produced 5 judgment forms and 5 holes — the central hole being a
missing derivation layer between semantics and solver. Parallel audits
placed the design's paradigm (model checking's problem statement, abstract
interpretation's engine, SMT-shaped refutation), enumerated its load-bearing
assumptions A1–A7 with a kill-order, and fought the HM-simplicity challenge
through three concession rounds. Then the owner's question — aren't
annotations just assumptions? — collapsed the three-layer composite: every
annotation-specific distinction died under adjudication, leaving two layers
plus one role bit, which the owner certified as the design's declarative
core: a pool of graded assumptions, mutual-consistency checking with
three-valued verdicts, and one law (a hypothesis must independently survive
as an obligation).

## Files

- `declarative-design.md` — the [OWNER-CERTIFIED] formulation, its
  refinements, and the collapse chain that produced it. Start here.
- `declarative-core-draft.md` — the pre-collapse J1–J5 draft (STATUS header
  explains supersession; holes H1–H5 still live).
- `audits.md` — condensed findings from the session's audits, with
  provenance tags.
- `open-threads.md` — everything still [OPEN] at session end.

## Provenance

Classes: [OWNER-CERTIFIED] (owner said yes in their own words),
[AUDIT-FINDING] (subagent-derived, unrebutted), [OPEN] (unresolved).
Nothing is promoted above its class.

Disk sources (ephemeral, session
`882b7410-8eb6-440b-abe2-10b3d26970b8`): agent transcripts
`acbbde2dfc8cee494` (paradigm placement, bidi adjudication,
annotations-collapse), `a9c1a6ad4033e1f7d` (falsifiability A1–A7,
kill-order), `a375512c62af61986` (HM/MLsub/MLstruct + concession rounds),
and `/tmp/.../declarative-core-draft.md` (copied here). The derivation,
concept-hygiene, and era-comparison audits (audits.md items 1–3) were
foreground audits transcribed from orchestrator-relayed verbatim summaries,
not re-verified from disk transcripts.
