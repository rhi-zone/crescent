# v10 typechecker core design record — term algebra ratified

Status: running design record for the v10 core (cleanroom) design round;
owner-ratified content only; session 2026-07-27.

Continues `docs/decisions/typechecker-v10-core-charter.md` (companion /
prerequisite; read it first for the cleanroom discipline and decision-doc
convention this document follows). Per this repo's decision-doc convention,
only settled conclusions and explicitly-flagged-open items are recorded —
no intermediate wrong turns.

This document is appended to as the design round progresses; each ratified
batch is committed as it lands. It does not modify any historical doc.

---

## Settled (owner-ratified this session)

### Term algebra

**The core's term representation is sorted abstract binding trees (ABTs).**
Operators are declared with arity, binding valence, and argument/result
sorts; de Bruijn binding underneath; display names are cosmetic only. The
kernel is domain-blind: operator vocabularies are declared by registry
entries (theories, later the prefix); the kernel knows only structure.

**Sort discipline: flat named sort set, no subsorting — a hard grammar
rule.** Ill-sorted construction is rejected structurally.

**Metavariables are in-grammar** (a distinguished node): patterns are terms
containing metavariable nodes; first-order matching is a kernel primitive.
Kernel check required: no metavariable may survive in a concluded judgment.

**Metavariables may occur under binders, with shift-aware instantiation**
(de Bruijn shifts applied at instantiation; capture impossible by
construction).

**Miller patterns** (metavars applied to distinct bound variables) are named
as the contained future upgrade path, should quantified alias schemas ever
be needed. **Full HOL-style terms are excluded.**

### Rationale

Recorded compactly, attributed to the session's analysis:

1. **Entailment.** The flat-sort ratification structurally excludes
   HOL-style λ-terms (application requires arrow sorts); the framework
   postmortem's lesson 2 excludes raw trees (per-theory capture-avoidance).
   Sorted ABTs are what remains.

2. **End-state perf ceiling.** De Bruijn ABTs are canonical by construction
   → content-hash = byte hash, hash-consing, O(1) interned equality, maximal
   memo hit rate; no β-redexes are representable → no normalization needed
   in trusted code; first-order matching is deterministic and linear in
   pattern size; nodes are dense (`{op_id, args}`) vs. HOL app-spines —
   favorable constant factors for the LuaJIT perf bar. (Ceiling/asymptotic
   arguments, not measurements.)

3. **Compression ceiling.** Schematic aliases (patterns with metavars,
   AOT-proved once by symbolic replay, cited as one node, nested) give
   log-depth certificates over exponential derivations in both algebras;
   the one HOL-only gain — higher-order alias schemas quantifying over
   contexts/constructors — is an economy-of-statement gain, not a
   capability gain, since the finite declared operator vocabulary lets
   first-order alias families be enumerated and mechanically AOT-proved per
   operator.

4. **Structural safety of the choice.** ABTs are exactly the second-order
   fragment of HOL-style terms — each operator embeds as a constant whose
   valence becomes an arrow-type (e.g. a valence-1 slot ↦ `(tm → tm)`); the
   image is the β-normal, η-long, at-most-second-order, Miller-pattern
   fragment. Ratifying ABTs therefore forecloses nothing: escalation is an
   embedding, not a migration, and the fragment boundary is precisely the
   decidability/perf fence — fence-by-construction rather than
   by-convention, consistent with the flat-sorts and axioms-undischargeable
   rules.

### Mandatory caveat (verbatim in substance)

The precedent claims in the rationale above (LF/HOAS encodings,
second-order abstract syntax literature, Isabelle schematic theorems,
Nuprl's ABT term structure) are from the design session's memory and were
**not verified against external sources in-session.** The owner ratified
the term algebra with this caveat surfaced. External grounding remains an
available follow-up before implementation hardens.

---

## Kernel primitive tiers and trust

### Settled (owner-ratified this session)

**Perf-critical kernel primitives get two implementations, applying the
repo's existing tier doctrine inside the kernel:**

- A **reference tier** that IS the semantic definition: structural equality,
  and eager de Bruijn substitution — simple, obviously correct. **Eager
  substitution is the reference semantics.**
- A **fast tier** as an optimization claim: hash-consed interning with
  pointer equality, and explicit/lazy substitution. The lazy/explicit-subst
  fast tier sits behind the same primitive signature as the reference tier,
  so tier choice is swappable and benchmark-driven at implementation time,
  per the repo's standing perf-work rules.

**Each fast tier's soundness is a named, versioned registry axiom**
(working names, not final: `kernel-interner-sound-v1`,
`kernel-lazy-subst-sound-v1`) — assumed until proven, burned down like any
other axiom. Until proof: mandatory parity tests + parity fuzzing of fast
tier against reference tier, and benchmarks logged, per the repo's standing
multiple-implementation discipline.

**What "proven" will mean, recorded upfront:** a model-level proof
(interner / explicit-substitution calculus proven correct, post-core, in
the proof stack) plus empirical parity/fuzz evidence that the Lua
implementation matches the model — the same model-vs-reality split the
reality-bridge embodies. Proving the LuaJIT code itself is not on any path;
the axiom burns down to "proved at model level + empirically bridged,"
never to zero. This is not to be later read as more than that.

**Run-level trust carveout for kernel axioms (owner-refined design):**

- Kernel-implementation trust is uniform over a replay run — it cannot vary
  per node, so per-node marking carries zero information at pure cost.
  Kernel-config axioms are therefore carved out of per-node taint sets into
  a single **run-level trust label** derived from the kernel configuration
  (e.g. `{eq = reference|interned, subst = eager|lazy}`). Node taint sets
  remain reserved for in-derivation axioms (legacy imports etc.), where
  taint varies per node and means something. This carveout is deliberate,
  not an oversight, and is documented here with this rationale for that
  reason.
- **Anti-laundering rule (extends the unlaunderability invariant):**
  caches/memo tables are keyed (or labeled) by kernel-config hash — a
  judgment produced under a fast config must never be served into a
  reference-config run claiming axiom-freedom. Any persisted or exported
  verdict carries its run label.
- The trust-query API unions both sources: a judgment's effective axiom set
  = node taint ∪ run label.
- **Free property (requirement):** a run under the all-reference config
  carries no kernel axioms — "re-run the slow kernel" is always the escape
  to kernel-axiom-free status.

---

## Explicitly open (flagged, not settled — do not present as decided)

- Concrete primitive set specification: shift/subst, structural equality,
  sorted/valence-checked construction, first-order match + instantiate —
  signatures and error behavior.
- Operator-declaration format for registry entries (how a theory declares
  its vocabulary: names, arities, valences, sorts).
- Pattern-discipline details (exact shift-aware instantiation rules; the
  no-metavars-in-conclusions check's placement).
- Everything downstream per the charter (instantiation checking, taint,
  discharge format, prefix, corroboration).
