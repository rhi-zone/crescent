# Proof Kernel — mechanized subtype metatheory

## Decision

Crescent's type system is the project's durability spine, and its repeated
v1→v4 failures trace to *ad-hoc accumulation* — bugs caught (or not) after the
fact rather than made unrepresentable. We adopt a **proof assistant** to move
the load-bearing core of the type lattice to **correct-by-construction
prevention**: properties (reflexivity, transitivity, eventually distributivity
and negation laws) are *proved* about the relation, so a malformed rule cannot
typecheck rather than being caught by a test that someone remembered to write.

This is contributor / CI proof tooling. The shipped checker (`bin/cr`) and
`bin/cr test` have **no** dependency on it and run on a bare clone with only the
vendored LuaJIT. The proof assistant lives only in the Nix dev shell.

## Host: Coq / Rocq

Chosen over Lean. One-line rationale: the **PL-metatheory + certified
property-based-testing** ecosystem fit (CompCert, JSCert, QuickChick) is exactly
our problem — mechanizing a subtype lattice and later cross-checking it against
an executable semantics. Lean's momentum is in *mathematics*, not certified
language tooling. Verified in this environment: `coqc` is The Rocq Prover 9.0.1
(nixpkgs pins `coq` + `coqPackages.QuickChick` together at 9.0.1).

## This increment

`proof/subtype.v`: a small but genuinely structured value-set lattice —
atoms with a declared sub-order (`AInt <: ANum`), `Union`, `Inter`, `Top`,
`Bot`; an inductive `sub` relation; **`sub_refl` and `sub_trans` proved to
`Qed`** with no `Admitted` and no added axioms (`Print Assumptions`: closed
under the global context).

### Design lessons (the reason this note exists — so they don't evaporate)

1. **Reflexivity is one rule; transitivity is real metatheory.** Reflexivity at
   compound types does not follow from the lattice rules, so `SRefl` is a
   primitive. That part is trivial.
2. **Naive injection/projection rules block transitivity.** With
   `A∩B <: A` as a no-premise constructor, transitivity is not provable by
   structural induction — the cut type does not shrink (empirically `eauto`
   fanned out to 76 irreducible goals). Two fixes were *both* required:
   - state the injection/projection rules in **composable** form (each with a
     recursive premise); the brief's plain rules become derived lemmas;
   - prove transitivity by **strong induction on the size of the cut type**, the
     one case (`SInterI` then an intersection projection) that recurses at a
     strictly-smaller cut.

## Staging

- **[this increment]** mechanized lattice + subtype `refl`/`trans` (Rocq);
  Coq/QuickChick wired into the flake as CI tooling.
- **[next]** scale toward the real value-set algebra: distributivity, negation /
  complement, the full union/intersection normalization laws; introduce
  QuickChick to fuzz the relation against the normalizer.
- **[then]** connect to the executable semantics in `lib/sem` as the empirical
  reality-anchor — the one thing proof *cannot* establish: that the model
  matches real LuaJIT value behavior.
