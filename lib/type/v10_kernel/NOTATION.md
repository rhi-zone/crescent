# v10 kernel — term algebra and certificate notation

This describes the CURRENT `lib/type/v10_kernel/` grammar: sorted ABT term
algebra (`term_algebra/`) plus a certificate replayer built on top of it
(`replayer/`). The retired prototype this directory used to hold
(`kernel.lua`, `registry.lua`, opaque-string certificates keyed by rule
name) has been ported onto this grammar and removed — see
`docs/decisions/typechecker-v10-core-design.md` and
`docs/decisions/typechecker-v10-core-charter.md` for the ratified design
this page restates in this directory's own words, and the "Port notes"
section below for what changed structurally in the port.

## Term grammar (`term_algebra/`)

Exactly three node forms, sorted, de Bruijn-indexed:

```
var(index, sort)     -- bound-variable reference; intrinsically sorted
op(decl, args)        -- operator node; args[i] = { bound_count, term }
meta(id, sort)         -- metavariable; legal in PATTERN positions only
```

Operator vocabularies are declared once per theory via
`term_algebra.declare_signature(spec)`:

```
spec = {
  name: string, version: integer,
  sorts: { sortname, ... },
  ops: { [opname]: { result: sortname, args: { { sort: sortname, binds: { sortname, ... } | nil }, ... } | nil } },
}
```

`build(decl, args)` is the ONLY way to construct a term; ill-sorted or
malformed terms are unrepresentable, not merely rejected. See
`term_algebra/reference.lua`'s header for the full primitive set
(`equal`/`shift`/`subst`/`match`/`instantiate`/`is_ground`/`is_closed`/
`sort_of`) and the reference-vs-fast tier split.

## Certificate grammar (`replayer/`)

Exactly three certificate node kinds (`replayer/certificate.lua`):

```
hypothesis(id, judgment)              -- leaf; the ONLY content-carrying
                                          node kind; unchecked at
                                          construction, validated only at
                                          discharge
cite_axiom(axiom_decl, bindings)      -- cites a declared axiom; conclusion
                                          = instantiate(axiom.pattern, bindings)
cite_rule(rule_decl, premises,
          discharges)                 -- cites a declared rule schema +
                                          premise nodes + per-discharge-slot
                                          hypothesis-id sets
```

Rule/axiom schemas are declared once via `replayer.declare_rule(spec)` /
`replayer.declare_axiom(spec)` (`replayer/registry.lua`):

```
RuleDecl  = { premises: pattern[], conclusion: pattern, discharges: { premise: integer, pattern: pattern }[] }
AxiomDecl = { pattern: pattern }   -- schematic; ground = zero-metavariable case
```

Certificate nodes carry NO conclusions — `replayer.new(k):replay(node)`
computes `(conclusion, taint, open)` bottom-up per node, memoized, by
matching a cited rule's premise patterns against the ACTUAL premises'
(recursively replayed) conclusions in one shared binding environment, then
instantiating the rule's conclusion pattern. Nothing inside a certificate
can lie about its content: a producer bug yields a different conclusion,
never a wrong-but-accepted one.

**Discharge**: labeled, by explicit hypothesis-id citation. A rule schema
declares discharge slots as `(premise_index, hypothesis_pattern)`; a citing
node names, per slot, the SET of open hypothesis ids it discharges there
(ids only, never content). Replay checks each named id is open in the cited
premise's own open-hypothesis set and that its carried judgment equals
`instantiate(slot_pattern, bindings)`; valid ids are subtracted, everything
unnamed stays open and bubbles upward. `replay_root` additionally requires
the conclusion be ground AND closed, and the open-hypothesis set empty.

**Taint**: a node property, computed bottom-up by set union (own axiom
citation, if any, union of premises' taints). Kernel-config (tier) trust is
carved out into a separate run-level label (`{eq, subst}`), never mixed into
node taint — see `replayer/replay.lua`'s header.

**DAG sharing**: a certificate node may be cited as a premise of more than
one parent. There is no single node-level discharge verdict computed once
against the whole DAG — each parent's own replay independently unions its
premises' open sets and subtracts what ITS OWN discharge slots name. A
shared subderivation with an open hypothesis is validly discharged through
one parent and left open through another; `replay_root` on each parent's own
root reflects that parent's own obligation. See
`replayer/replayer_test.lua`'s "MANDATORY: DAG-shared discharge" case.

## Ported theory entries (`theories/`)

`theories/hm.lua` declares the shared Hindley-Milner judgment vocabulary
(`hm-judgment` signature: `int_ty`/`bool_ty`/`arrow_ty`/`has_type`) and rule
schemas (`hm-abs`, `hm-app`, `hm-let`) plus an axiom (`hm-ax-lit`), built
against a caller-supplied `term_algebra` tier instance. `theories/algorithm_w.lua`
and `theories/algorithm_j.lua` are untrusted PRODUCERS — Algorithm W
(functional substitution map) and Algorithm J (mutable ref cells /
union-find), the same toy four-construct lambda calculus (lit/var/abs/app/let)
as the retired prototype, still de Bruijn-indexed, still deliberately
non-generalizing on `let` — that emit certificates over `hm.lua`'s
vocabulary. The replayer never runs either producer's code.

### Port notes (what changed going from the retired prototype to this grammar)

- **No name-keyed citation.** The retired kernel resolved a node's `rule`
  field by string name against a per-theory `Registry`. `cite_rule`/
  `cite_axiom` take the declared rule/axiom OBJECT directly — there is no
  registry, no name lookup, and therefore no "citation to an unregistered
  name" failure mode; a malformed citation is instead rejected by
  `cite_rule`'s own shape validation at construction time, earlier and
  stronger than the retired design's replay-time-only check.
- **Rule/axiom identity is the declared object, not a per-theory
  registration.** `algorithm_j.lua` shares `theories/hm.lua`'s vocabulary
  with `algorithm_w.lua` even more directly than the retired prototype's
  "J re-registers W's schemas into its own registry" — there is no
  registration step at all; both simply hold a reference to the same
  declared objects.
- **A rule's discharge target must be an explicit premise, not an
  out-of-band payload.** The retired prototype recorded a fresh
  hypothesis's type in `Hypothesis.payload`, fully opaque to the kernel,
  and discharged it via an unchecked id list. The new core's discharge
  slots are checked structurally (`instantiate(slot_pattern, bindings)`
  must equal the discharged hypothesis's actual judgment), and a rule's
  bindings only ever come from matching its OWN declared premises — so
  `hm-abs`/`hm-let` cite the hypothesis they introduce as an explicit
  premise of the rule itself (the standard natural-deduction shape: the
  assumption you discharge is a premise of the intro rule), not merely
  something a var-lookup happens to reference somewhere inside another
  premise's subtree.
- **A variable reference needs no rule at all.** The retired prototype's
  `W-Var`/`assumes` was a 0-premise node restating a hypothesis's judgment.
  Under the new core, DAG-sharing the hypothesis leaf node itself wherever
  the bound name is referenced already IS that judgment (replay computes a
  hypothesis leaf's conclusion as its own carried judgment) — no wrapping
  schema needed.
- **Two-pass certificate construction.** Term algebra terms must be ground
  the instant they're built; there is no cross-node "same unification
  variable, resolved later" identity the way a shared substitution map (W)
  or mutable cell (J) provided. Both theories now run their real inference
  to completion first (unchanged from the retired algorithm), THEN
  re-walk the term a second, deterministic time building certificate nodes
  from the now-fully-resolved types. See `algorithm_w.lua`'s and
  `algorithm_j.lua`'s headers for the full rationale.
- **App's argument/domain consistency is now independently verified by
  replay itself**, via a shared (non-linear) metavariable across `hm-app`'s
  two premise patterns — the retired kernel's opaque `conclusion` payload
  meant this consistency was entirely the untrusted producer's own
  responsibility, unverified by the trust core.
- **No cosmetic node fields.** The retired grammar's `locus` and cosmetic
  display names rode along on every node/hypothesis. The new certificate
  grammar has no room for them (nodes carry only what replay needs); this
  drops nothing semantically load-bearing, since the retired kernel never
  checked those fields either.
- **Two concrete base types, not an arbitrary `con(name)`.** `term_algebra`
  operators carry no free-form payload field, so each base type the ported
  theories exercise (`integer`, `boolean`) is its own declared nullary
  operator (`int_ty`, `bool_ty`) rather than one polymorphic `con(name)`
  constructor. Adding another base type means declaring another operator in
  `hm.lua`, not passing a new string.

Binder representation (de Bruijn indices for the OBJECT-language lambda
terms `algorithm_w.lua`/`algorithm_j.lua` infer over) is unchanged from the
retired prototype and lives entirely in those files' own untrusted
producers — it was never part of the trusted kernel/replayer's grammar
either before or after this port.
