# static-analysis substrate — first-principles derivation

status: living derivation doc, started 2026-08-13. method: requirements-first — enumerate what a full static-analysis system must be able to judge, map each family to the known minimal logical machinery (grounded in literature, memory-claims marked until checked), and derive the substrate from the closure instead of discovering walls by building into them. owner frame, verbatim: "a typesystem is a subset of static analysis." the requirements list is EVERYTHING — this doc deliberately does not scope down.

## 0. the two-piece frame

- a VERIFIER: given a program + witnesses, re-establishes every claimed fact itself (never existence-checks a proof object, never trusts a witness — witnesses only make checking cheap and search-free). must stay small.
- a PROVER: finds the witnesses. untrusted, arbitrary, replaceable, per-analysis.
- everything else in the design must be derived from what the verifier needs to be able to SAY (judgment expressiveness) and CHECK (decidable re-establishment).

## 1. requirement families (initial enumeration — to be extended with the owner)

gathered from the owner's stated ambition (types incl. hkts, flow typing, temporal facts like `final`, effects, structural typing, arbitrary semantic lints — "kills manual linter passes once and for all"):

- R1 typing judgments with binding structure (scopes, quantifiers, generics/hkts)
- R2 temporal/path-indexed facts (flow narrowing, final/write-once, facts that hold at/between program points, branch-sensitive)
- R3 recursive structures (equi-recursive types, cyclic reasoning)
- R4 existential witnesses (fresh instantiation, "there is a type such that...")
- R5 negative/absence facts (unused-write class lints, "no path does X", purity)
- R6 effects (what a call may do — read/write/throw/yield families)
- R7 open-world composition (new judgment families addable as content, not checker code — the once-and-for-all requirement)

## 2. known-machinery map (UNGROUNDED — every row is a memory-claim pending a literature pass)

- R1 → binding-aware logic: nominal logic / LF-family / HOAS; freshness as first-class
- R2 → path/world-indexed judgments: hoare logic, temporal logic families
- R3 → coinduction / cyclic proof systems
- R4 → existential quantification in the certificate/witness language
- R5 → closed-world negation: stratified negation / well-founded semantics
- R6 → effect systems literature (row-effects etc)
- R7 → the logic itself fixed; vocabularies+rules as declared data (LF-style "logics as signatures" is the closest known shape?)

## 3. history constraint (why requirements-first)

four substrate walls were previously discovered by building into them (freshness, branch-structured facts, cycle-rejection vs recursion, fresh-metavariable citation — see docs/decisions/typechecker-v10-core-design.md and the wall census). each corresponds to a row above. the method error was example-driven substrate design; this doc exists to not repeat it.

## open questions

- (owner) does the R-list cover everything intended? missing families?
- literature grounding pass for section 2 — not yet run
- what the assembled minimal substrate is — the whole point, not yet derived
