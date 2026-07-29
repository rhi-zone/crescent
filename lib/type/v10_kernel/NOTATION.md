# v10 kernel — term algebra and certificate notation

This describes the grammar this directory's theories and pilot are built
against: the CANONICAL v10 core in `lib/type/v10_cleanroom/` (sorted ABT
term algebra + certificate replayer), per the owner-ratified canon swap
(`docs/decisions/typechecker-v10-core-design.md`, "Canon swap: cleanroom
core" and the F1–F13 adjudications). The core that used to live in this
directory (`term_algebra/`, `replayer/`) is retired; see `README.md`.

## Term grammar (`lib/type/v10_cleanroom/term_algebra.lua`)

Exactly three node forms, sorted, de Bruijn-indexed:

```
var(index, sort)     -- bound-variable reference; intrinsically sorted
build(decl, args)    -- operator node; args validated against the decl
meta(id, sort)       -- metavariable; legal in PATTERN positions only
```

Operator vocabularies are declared once per theory via
`declare_signature(spec)`:

```
spec = {
  name: string, version: integer,
  sorts: { sortname, ... },                              -- owned sorts
  imports: { { from = Signature, sorts = { sortname, ... } }, ... }?,  -- cited sorts (identity preserved)
  ops: { [opname]: { result: sortname, args: { { sort: sortname, binds: { sortname, ... }? }, ... } } },
}
```

`build(decl, args)` is the ONLY way to construct an operator term;
ill-sorted or malformed terms are unrepresentable, not merely rejected.
Sort and operator identity are declared-object identity — never name
equality; a sort imported from another signature IS that signature's own
sort object. The full primitive set: `equal`/`shift`/`subst`/`match`/
`match_into`/`instantiate`/`is_ground`/`is_closed`/`sort_of`/`is_no_match`.
Reference tier only — structural equality and eager substitution ARE the
semantic definition (the fast tier retired with the old core and will be
rebuilt separately).

## Certificate grammar (`lib/type/v10_cleanroom/replayer.lua`)

Rule/axiom declarations live in a REGISTRY (`new_registry()`); `(name,
version)` is unique per registry (F11), and a replayer instance resolves
citations only against the registry it was built over:

```
declare_rule(reg,  { name, version, premises: pattern[], conclusion: pattern,
                     discharges: { premise: integer, hypothesis: pattern }[]? })
declare_axiom(reg, { name, version, pattern })   -- schematic; ground = zero-metavariable case
```

Certificate nodes are PLAIN TABLES (no constructors — the replayer
validates, never trusts; malformed citations are rejected at replay):

```
{ kind = "hypothesis", judgment = <ground, closed term> }
{ kind = "axiom", axiom = <AxiomDecl>, bindings = { [meta id] = <ground, closed term> }? }
{ kind = "rule", rule = <RuleDecl>, premises = { node... },
  discharge = { [slot index] = { <hypothesis node>... } }? }
```

Hypothesis identity is the LEAF NODE OBJECT itself (F8): there are no
hypothesis id strings. Two distinct leaves carrying the same judgment are
two hypotheses; a DAG-shared leaf is one. Axiom-citation bindings are
plain terms at depth 0, each ground AND closed (F12); axiom nodes admit no
discharge form.

`replay(rp, root)` — the ACCEPTANCE channel — computes `(conclusion,
taint, open)` bottom-up per node, memoized, by matching a cited rule's
premise patterns against the ACTUAL premises' (recursively replayed)
conclusions in one shared binding environment, then instantiating the
rule's conclusion pattern. EVERY node's computed conclusion must be ground
AND closed (F9, strict); root acceptance additionally requires the
open-hypothesis set empty. Nothing inside a certificate can lie about its
content: a producer bug yields a different conclusion, never a
wrong-but-accepted one.

`observe(rp, node)` — the owner-ratified READ-ONLY observation entry point
— returns the per-node `(conclusion, taint, open)` triple with the open
set in plain view, sharing the same memoized computation, stopped before
the root checks. It carries NO acceptance signal (its result shape is
structurally distinct from `replay`'s); use it to inspect
deliberately-open derivations (e.g. theory tests over undischargeable
hypotheses).

**Discharge**: labeled, by explicit node citation. A rule schema declares
discharge slots as `(premise index, hypothesis pattern)`; a citing node
names, per slot, the SET of open hypothesis LEAF NODES it discharges there
(node references, never content). Replay checks each named node is open in
the cited premise's own open set and that its carried judgment equals
`instantiate(slot pattern, bindings)`; valid nodes are subtracted,
everything unnamed stays open and bubbles upward.

**Taint**: a node property, computed bottom-up by set union, keyed by
citation key (`citation_key(name, version)` = `"name@version"`) with the
declaration OBJECT as the value (identity-by-declaration). Kernel-config
(tier) trust is carved out into the run-level trust label, never mixed
into node taint; `effective_axiom_set(result)` unions both.

**DAG sharing**: a certificate node may be cited as a premise of more than
one parent. There is no single node-level discharge verdict computed once
against the whole DAG — each parent's own replay independently unions its
premises' open sets and subtracts what ITS OWN discharge slots name. A
shared subderivation with an open hypothesis is validly discharged through
one parent and left open through another; root acceptance on each parent's
own root reflects that parent's own obligation.

## Ported theory entries (`theories/`)

`theories/hm.lua` declares the shared Hindley-Milner judgment vocabulary
(`hm-judgment` signature: `int_ty`/`bool_ty`/`arrow_ty`/`has_type`) and rule
schemas (`hm-abs`, `hm-app`, `hm-let`) plus an axiom (`hm-ax-lit`) into a
caller-owned registry. `theories/algorithm_w.lua` and
`theories/algorithm_j.lua` are untrusted PRODUCERS — Algorithm W
(functional substitution map) and Algorithm J (mutable ref cells /
union-find), the same toy four-construct lambda calculus
(lit/var/abs/app/let), de Bruijn-indexed, deliberately non-generalizing on
`let` — that emit certificates over `hm.lua`'s vocabulary. The replayer
never runs either producer's code.

### Port notes (carried findings, restated for the canonical grammar)

- **Rule/axiom identity is the declared object.** Sharing a rule between
  W and J is holding a reference to the same declared object; the only
  scoping is the registry it was declared into (a replayer resolves
  citations against exactly one registry).
- **No construction-time citation validation.** Certificate nodes are
  plain tables; a malformed citation (wrong premise count, forged
  declaration table) is rejected at replay, the grammar's sole validation
  point.
- **A rule's discharge target must be an explicit premise**, not an
  out-of-band payload: discharge-slot patterns are checked structurally
  against the SAME shared bindings environment the rule's own premise
  matches produce, so `hm-abs`/`hm-let` cite the hypothesis they introduce
  as an explicit premise (the standard natural-deduction shape).
- **A variable reference needs no rule at all.** DAG-sharing the
  hypothesis leaf node itself wherever the bound name is referenced
  already IS that judgment — and under F8 the node reference is also
  literally the hypothesis's identity.
- **Two-pass certificate construction.** Terms must be ground the instant
  they're built; there is no cross-node "same unification variable,
  resolved later" identity. Both theories run their real inference to
  completion first, THEN re-walk the term deterministically building
  certificate nodes from fully-resolved types.
- **App's argument/domain consistency is independently verified by replay
  itself**, via a shared (non-linear) metavariable across `hm-app`'s two
  premise patterns.
- **No cosmetic node fields.** Nodes carry only what replay needs; `locus`
  and display names live in the untrusted producers' own data only.
- **Two concrete base types, not an arbitrary `con(name)`.** Operators
  carry no free-form payload; each base type is its own declared nullary
  operator (`int_ty`, `bool_ty`).

Binder representation (de Bruijn indices for the OBJECT-language lambda
terms the theories infer over) lives entirely in the untrusted producers —
it was never part of the trusted core's grammar.
