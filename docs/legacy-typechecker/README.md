# Legacy typechecker docs (pre-foundation, quarantined)

**These documents describe the typechecker as it existed before crescent committed to a set-theoretic type foundation with `~T` complement (commit `b4bb9667`, 2026-05-19).**

They are kept for historical reference only. They describe an architecture, a paradigm, and a set of implementation decisions that have since been rejected. Reading them as a guide to current or future work will produce wrong-shaped code.

## Status

- `typechecker-handler-shape-audit.md` — analysis of the 5 handler shapes in the pre-foundation solver. Verdicts here were superseded by the foundation commit.
- `typechecker-operational-semantics.md` — three-round-polished spec for the pre-foundation constraint solver. Describes the OutsideIn-style two-phase architecture that crescent has since abandoned.
- `typechecker-hm-fit-audit.md` — audit testing whether canonical HM could serve as the rewrite substrate. Verdict: no. Useful only for the falsification.
- `typechecker-session-handoff.md` — handoff briefing from prior session. Describes the pre-foundation rework approach that has been superseded.
- `POLISH.md` — polish-loop state for the now-quarantined operational-semantics spec.

## Canonical sources to read instead

- `docs/type-system.md` — the type system's design rationale, including the set-theoretic foundation commitment.
- `docs/typechecker-reference.md` — feature surface, including `~T` complement and match-type `_` sugar semantics.

## Do not

- Cite these documents as authoritative.
- Update them with new design decisions.
- Use them as the starting point for any rewrite session.

If a feature description in these docs is still accurate and useful, propagate it to the canonical docs explicitly — don't reference the legacy version.
