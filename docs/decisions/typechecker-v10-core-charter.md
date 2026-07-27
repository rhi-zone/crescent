# v10 typechecker core charter — ratified decisions and cleanroom discipline

Status: decision record, ratified by owner, session 2026-07-27.

Continues `docs/decisions/typechecker-v10-design-sync.md` (that document's
open-items list is the direct predecessor of the resolutions recorded here).
This document records owner-ratified conclusions from a live design session;
per this repo's decision-doc convention (see `typechecker-v10-proposal.md`
§2's framing, restated in design-sync's own preamble), only settled
conclusions and explicitly-flagged-open items are recorded — no intermediate
wrong turns.

**Prerequisite reading:** `docs/decisions/typechecker-version-history.md`,
`docs/decisions/typechecker-v10-proposal.md`, and
`docs/decisions/typechecker-v10-design-sync.md`. Read all three first.

---

## Settled (owner-ratified this session)

**1. Term representation: structured terms, not opaque strings.** A
judgment's content (`type_str` etc.) is a structured term — typed syntax as
data, de Bruijn binding — not an opaque string. This closes the upstream
fork design-sync §5.1 flagged as blocking schematic-instantiation design
("is a judgment's content an opaque string or a structured term?"). It is
forced by the already-settled §3 generic-primitives direction
(design-sync §3): substitution and structural equality cannot operate on
opaque strings, so the primitives design already implied this answer before
it was stated as its own decision.

**2. Scope: full stack.** Completion means the full beyond-SOTA typechecker
(semantic-analysis linter) — kernel + primitives + schematic instantiation +
axiom/taint + prefix v1 + theories + migration + the corroboration layer
exercised against a real, mature theory. Not a deliverable-tier stopping
point short of that.

**3. Cleanroom execution discipline.** The pure core (kernel, generic
primitives, schematic instantiation, taint, certificate/evidence grammar) is
derived from first principles. Implementing and designing agents must NOT
read v3 (`lib/type/static/`), v5 (`lib/type/static-v5/`), v9
(`proof/typing.v`), `lib/type/framework/`, or declc code. Crescent's own
prior art is irrelevant until the core is done; lineage enters only as the
distilled lessons already recorded in decision docs (the framework
postmortem's three lessons, declc's Hole H1, the version-history graveyard).
The sole sanctioned prior-art crossing is the prefix-v1 deliberate
extraction from `proof/typing.v`, scheduled strictly post-core, performed by
a dedicated agent whose output document is what everyone else reads.

**4. Design authority over artifact.** The term-grammar/primitives design
round is first-principles (external precedent like LCF-family kernels and de
Bruijn theory is admissible; crescent prior art is not, including surveying
the current `lib/type/v10_kernel/` as design input). Once the design is
ratified, the existing `lib/type/v10_kernel/` is brought into conformance
with it — the design is authoritative; the artifact is rewritten where it
diverges. Current-state survey happens only at that integration phase,
firewalled from design.

**5. Docs policy.** Historical docs (design-sync, version-history, proposal,
inventories) are frozen — not patched. Settled state from this point forward
is recorded in fresh v10-line docs; this charter is the first.

## Resolved (design-sync open items 1 and 2, evidence-backed this session)

**Item 1 (v5 op-sem citation discrepancy): resolved — the earlier sourced
finding stands; fable's later citation is retracted.** Direct re-reading
confirmed `lib/type/static-v5/op_sem.lua` + `op_sem_alt.lua` formalize v5's
own solver step relation, not crescent-Lua language semantics: state
(`OpSemState`, `op_sem.lua:98`) ranges over union-find subst / constraint
worklist / bound-graph; all rules are constraint-simplification steps
(`rule_T_CEq_UU` etc., `op_sem.lua:492–1621`); zero evaluation/value
vocabulary in either file; header describes the solver loop
(S-Step/S-Park/S-Wake/S-Quiesce). They are off-target for the prefix role.

**Item 2 (v3 "founding shape" ambiguity): resolved — pattern only; code
off-limits.** v3 contributes the abstract generate-then-solve shape as
lineage; its code is not substrate. Evidence: the gen/solve split in
`lib/type/static/` (`constrain.lua` → `solve.lua`) communicates through
ad-hoc `ctx._foo` fields that `docs/typechecker-ad-hoc-inventory-verification.md`
categorizes as inter-phase message buses — they ARE the split's
communication mechanism (the constraint schema cannot carry the metadata),
so code reuse imports the documented failure mode by construction. Also: the
widely-cited "105+ instances / 18 distinct fields" figure is stale — the
verification doc corrected it to ~90 total / 30 distinct fields, and
`typechecker-version-history.md` cites only the uncorrected figures. A fresh
grep (2026-07-27) finds 42 distinct names / 167 occurrences across
`lib/type/static/` incl. `rules/` (drift since the inventory; still
concentrated in `constrain.lua` at 87 and `solve.lua` at 32). Per the
docs-frozen policy, version-history is NOT being patched; this charter is
the correction of record.

## Explicitly open (flagged, not settled — do not present as decided)

- Whether "the core is language-agnostic / zero crescent-Lua content" is
  exactly the owner's intended reading of "the pure core should not need
  v3/v5/v9/lua shit" (it matches the already-settled "kernel stays empty of
  domain content," but stronger readings are possible) — awaiting owner
  confirmation.
- Design-sync open items 3–6 (schematic instantiation design, discharge-
  certificate format, taint-propagation worked example, corroboration
  layer) — now scheduled as campaign tasks, unresolved as designs.
