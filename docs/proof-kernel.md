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

## Increment 2 — lattice laws up to subtype-equivalence

`proof/subtype.v` (no change to the increment-1 `sub` rules):

- `tequiv a b := sub a b /\ sub b a`, proved an equivalence relation
  (`tequiv_refl`/`_sym`/`_trans`), built on `sub_refl`/`sub_trans'`.
- Lub/glb: `union_lub`, `inter_glb` (plus the injections/projections already
  derived in increment 1).
- All standard **lattice** laws, stated up to `tequiv` (never `=`, since e.g.
  `TUnion a b` ≠ `TUnion b a` syntactically): commutativity, associativity,
  idempotence of both connectives, and both absorption laws. All `Qed`.
- Both distributive laws: the **free-lattice direction** of each holds and is
  proved (`distrib_inter_union_ge`, `distrib_union_inter_le`).

`Print Assumptions` on every result above (and the two below): *Closed under
the global context* — no axioms, no `Admitted`.

### Design lesson #3 — the algebra is a LATTICE, but PROVABLY NOT DISTRIBUTIVE

The hard direction of each distributive law (`a∩(b∪c) ≤ (a∩b)∪(a∩c)` and its
dual) is **not derivable** from the increment-1 `sub` rules. This is not a
proof-search failure: those rules generate exactly the **free lattice** preorder
over the atom poset, and the free lattice on incomparable generators is
non-distributive — distributivity is precisely the law it lacks. Even the
all-atoms instance `(ANum) ∩ (AInt ∪ AStr) ≤ (ANum∩AInt) ∪ (ANum∩AStr)` has no
derivation.

We do not hide this behind `Admitted`. We **prove the unprovability**: the file
defines the pentagon **N5** (the minimal non-distributive lattice) as a model,
`interp_sound` shows every `sub` edge maps to a true N5 order-fact, and the
distributive instance maps to the false fact `n5le NB NA = false`. Hence
`distrib_inter_union_le_unprovable` and `distrib_union_inter_ge_unprovable` are
**positive theorems** (`~ sub ...`), Qed, closed under the global context.

This is a genuine design fork, surfaced not fudged. Making the algebra
distributive requires *either* a general distributivity rule on `sub` (which
forces re-deriving transitivity under the new rule — a change to the increment-1
substrate) *or* moving to the coarser value-set semantics (where `TInter AInt
AStr ≡ Bot`, which `sub` also does not prove). Both are their own increments.

## Increment 3 — the SEMANTIC PIVOT: a Boolean algebra of types

Increment 2 proved the free `sub` lattice is *provably non-distributive* (N5).
Rather than bolt distributivity onto the syntactic relation (the deferred fork),
increment 3 takes the principled route: **stop axiomatizing the order and define
subtyping semantically.** Types denote SETS of values; `A <: B` means
`denote A ⊆ denote B`. Every Boolean-algebra law then collapses to first-order
logic over the denotation — no `sub` rule asserted, no axiom added.

`proof/subtype.v` (new section, additive — increments 1-2 untouched):

- **Negation added to the syntax.** A fresh `BTy` = atoms + `BUnion`/`BInter`/
  `BNeg`/`BTop`/`BBot` (a Boolean algebra of types). (Kept distinct from the
  increment-1 `Ty` so the old free-lattice metatheory still compiles verbatim.)
- **The model — disjointness and order are CONSTRUCTIVE, not asserted.** A
  concrete value domain `V` with distinct constructor heads:
  `VInt | VFloat | VStr | VBool | VNil`. `atom_denote` maps each atom to a
  value-set: `ANum` accepts `{VInt _} ∪ {VFloat _}`, `AInt` accepts `{VInt _}`
  — a *literal subset*, so `AInt <: ANum` holds definitionally. Unrelated atoms
  pick disjoint constructors, so their intersection is empty *by `discriminate`
  on heads*, not by axiom. `denote` lifts to `BTy` with
  `∪↦∨, ∩↦∧, ¬↦~, ⊤↦True, ⊥↦False`.
- **`dsub a b := ∀ v, denote a v -> denote b v`** is now THE definition of
  subtyping; `dequiv` is mutual `dsub`. The old inductive `sub` is **retained**
  as the future *algorithmic* relation (to be proven sound+complete vs `dsub`).
- **Earlier results re-proved under `dsub`** (all close by unfolding to prop
  logic): refl, trans, lub/glb, comm/assoc/idem/absorption.
- **The payoff — full Boolean-algebra laws, axiom-free:** distributivity **both
  directions** (`ddistrib_inter_union`, `ddistrib_union_inter`), De Morgan both
  (`dde_morgan_union/_inter`), complement (`dcomplement_inter/_union`), double
  negation (`ddouble_neg`), atom disjointness (nine `disjoint_*`), base order
  (`base_order_int_num`).
- **Constructivity without `Classical`.** The "classical-flavoured" laws (De
  Morgan's hard direction, complement, double negation) are discharged via
  `denote_dec` — membership is **decidable** for every type/value — yielding
  excluded-middle and DNE for `denote` *constructively*. No `Classical` import,
  no `Axiom`.
- **Non-vacuity / faithfulness.** `V` is inhabited; each atom is inhabited;
  `dsub` is non-trivial — proved NON-subtypes `~ dsub AStr AInt`,
  `~ dsub Top Bot`, `~ dsub ANum AInt` (numbers aren't all ints); and a
  non-disjoint pair does NOT collapse: `~ dsub (ANum ∩ AInt) Bot` (witness
  `VInt 0`). These prove the model is faithful, not vacuously true.

`Print Assumptions` on every law above + the non-vacuity lemmas: **Closed under
the global context** — no axioms, no `Admitted`. Whole dev compiles clean
(`coqc proof/subtype.v`).

## Increment 4 — DECIDABLE subtyping: an executable decider, sound + complete

Increment 3 made `dsub a b := forall v:V, denote a v -> denote b v` the
*definition* of subtyping — correct, but **not computable**: it quantifies over
the infinite domain `V` (`VInt n` for every `nat n`, etc.). Increment 4 makes it
**decidable by construction** — an executable `decide_dsub : BTy -> BTy -> bool`
proven `= true <-> dsub`.

`proof/subtype.v` (new section, additive — increments 1-3 untouched):

- **The head-class reduction (the lemma the decider rests on).** For the current
  atoms, `denote t v` depends only on `v`'s *constructor head*
  (`VInt`/`VFloat`/`VStr`/`VBool`/`VNil` — five classes), never on the payload
  (the `nat`/`bool` inside). `atom_denote` matches only the head; the connectives
  (`Union`/`Inter`/`Neg`/`Top`/`Bot`) preserve head-dependence. Formalized as
  `head : V -> V` (collapse a value to the canonical representative of its
  class), `head_reps` (the five representatives), and **`denote_head : forall t
  v, denote t v <-> denote t (head v)`** (`Qed`, by induction on `t`), with
  corollary `denote_same_head` (same head ⇒ indistinguishable by any type). This
  is what collapses the universal quantifier over infinite `V` to a finite check.
- **The executable decider.** `decide_dsub a b := forallb (fun h => implb (memb a
  h) (memb b h)) head_reps`, where `memb t v` projects increment 3's decidable
  membership `denote_dec` (`{denote t v}+{~denote t v}`) to a `bool`. It is a
  genuine `bool`-returning function: `Compute (decide_dsub ...)` reduces.
- **Soundness AND completeness:** `decide_dsub_correct : decide_dsub a b = true
  <-> dsub a b` (`Qed`). Completeness (decider → `dsub`): any `v` has head `head
  v`, one of the five reps; the finite check covers it; `denote_head` transports
  membership back to `v`. Soundness (`dsub` → decider): instantiate `dsub` at
  each representative (a concrete witness of its class). Also `dsub_dec : {dsub a
  b}+{~dsub a b}` — the sumbool form, `Defined` (computable).
- **Sanity / agreement.** `Compute` confirms the right answers:
  `decide_dsub AInt ANum = true`, `ANum AInt = false`, `(AInt ∩ AStr) Bot =
  true`, `AStr AInt = false`, `AInt (¬AStr) = true`, `Top (AInt ∪ ¬AInt) = true`
  (excluded middle). And the decider is shown to decide *exactly* `dsub`, not
  some other relation: `agree_*` lemmas prove `dsub ...` for the true cases and
  `~ dsub ...` for the false ones, all routed through `decide_dsub_correct`.

`Print Assumptions decide_dsub_correct`, `denote_head`, `dsub_dec`: **Closed
under the global context** — no axioms, no `Admitted`, no `Classical`. Whole dev
compiles (`coqc proof/subtype.v`).

### SCOPE LIMITATION — this is NOT the final decision procedure

The decider is correct **only because the current atoms make `denote`
head-determined** — membership depends solely on the value's constructor head,
so five representatives suffice to witness the entire infinite domain. This is a
genuine property of the present type system, not a trick, but it does **not**
survive the addition of structural type formers. Once **records/tables** and
**arrows** are added, `denote` will depend on more than the head — the *contents*
of a table, the *behaviour* of a function — and a finite enumeration of head
classes can no longer cover the value space. The five-point decider will then be
**unsound/incomplete** and must be replaced by an **emptiness-based decision
procedure (MLstruct-style)**: decide `dsub a b` by deciding emptiness of `a ∩
¬b`, with the Boolean algebra normalized to a form whose emptiness is decidable
structurally. Do not mistake `decide_dsub` for that procedure; it is the correct
decider for the *atom Boolean algebra* only.

## Staging

- **[done]** mechanized lattice + subtype `refl`/`trans` (Rocq);
  Coq/QuickChick wired into the flake as CI tooling.
- **[done — increment 2]** equivalence relation + lub/glb + the lattice laws
  (comm/assoc/idem/absorption) up to `tequiv`; free-lattice direction of
  distributivity; **machine-checked proof that the hard direction is NOT
  derivable** (N5 model + soundness). Finding: free *lattice*, not distributive.
- **[done — increment 3]** the **semantic pivot**: negation added; clean
  axiom-free denotation over a concrete value domain `V`; `dsub` defined as
  set inclusion; **all Boolean-algebra laws proved as theorems-for-free**
  (distributivity both directions, De Morgan, complement, double negation,
  atom disjointness, base order) with disjointness + order *constructive* (not
  axioms); decidable membership replaces any classical axiom; non-vacuity
  lemmas prove the model is faithful. The distributivity fork from increment 2
  is **resolved by route (b)** — value-set semantics — at the abstract level.
- **[done — increment 4]** **decidable subtyping** for the atom Boolean algebra:
  the head-class reduction (`denote` is head-determined; `denote_head`), an
  executable `decide_dsub : BTy -> BTy -> bool` (and `dsub_dec` sumbool), proven
  **sound + complete against `dsub`** (`decide_dsub_correct`), with `Compute`
  sanity + agreement lemmas. Closed under the global context. Limitation
  recorded above: head-enumeration only works while `denote` is head-determined;
  structural formers break it and need an emptiness-based procedure.
- **[next — structural type formers: records/tables first]** extend `BTy` and
  `denote` with **records/tables** (the Lua-central case: tables are the core
  aggregate), then **arrows**. Denotation gains structure beyond the head, so
  the head-enumeration decider no longer applies — design the **emptiness-based
  decision procedure** (decide `dsub a b` via emptiness of `a ∩ ¬b`, MLstruct-
  style) and prove it sound + complete under the extended denotation.
- **[then — equirecursive μ]** extend `BTy` with recursive types (`μ`) and
  coinductive/contractive denotation; re-establish the laws and the decision
  procedure under recursion.
- **[then — the lib/sem reality bridge]** connect the abstract `V`/`denote` to
  the executable semantics in `lib/sem` as the empirical reality-anchor — the
  one thing proof *cannot* establish: that the model matches real LuaJIT value
  behavior.
