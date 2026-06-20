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

> **Increment-5 re-scoping (see below).** Adding the [BRec] record former made
> `denote_head` and `decide_dsub_correct` FALSE in general (records inspect a
> table's *contents*, not just its head). They were **restated and re-proved
> under an `atomic` hypothesis** — `atomic : BTy -> Prop` holds iff no `BRec`
> subterm occurs — so they remain TRUE theorems about the atomic fragment,
> explicitly scoped, rather than broken general claims. `denote_dec` itself
> stays **general and total** (it decides record membership too); only the
> head-ENUMERATION decider is fragment-restricted.

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

## Increment 5 — RECORD/TABLE types: structural subtyping, Boolean laws preserved

The first **structural** type former — tables are the Lua-central aggregate.
`proof/subtype.v` (new section, additive — increments 1-3 untouched; increment 4
re-scoped, see above):

- **Value-domain extension.** `V` gains `VTable : list (string * V) -> V` — a
  table is a FINITE assoc-list of string keys to sub-values. `V` stays a (nested)
  **inductive**; the elements are structurally smaller, so it is well-founded.
  The auto-generated `V_ind` is too weak for the nested list, so we hand-roll a
  mutual induction scheme `V_rect_strong` (a plain `Fixpoint`, no axiom).
  **Cyclic / self-referential tables are DEFERRED** to the future
  equirecursive-μ increment — they would force a *coinductive* `V`, a genuine
  fork we do not take here.
- **Record former.** `BTy` gains `BRec : list (string * BTy) -> BTy`. Reading is
  **OPEN / WIDTH** (standard structural subtyping): `v ∈ BRec fields` iff `v` is
  a table `VTable ents` and every LISTED `(k,T)` is present in `ents` with a
  value inhabiting `T` — *other* keys allowed. **Closed/exact records and index
  signatures are DEFERRED.** The denotation is written as a structural nested
  fixpoint over `fields` (so the recursive `denote T vv` call is guard-accepted);
  the brief's `∀ k T, In (k,T) fields -> …` reading is recovered exactly as
  `denote_rec_iff`.
- **`denote_dec` extended, stays general + total.** Deciding record membership
  is still decidable & constructive: check `v` is a table, then each listed
  field by `string_dec`-driven lookup + recursive `denote_dec` on the field type
  (finite over `fields`). No `Classical`.
- **Structural subtyping laws — theorems-for-free from the semantics:**
  - **WIDTH** — `drec_width` (drop the head field is supertyping) and the
    general field-set-inclusion form `drec_width_incl`; PERMUTATION
    (`drec_perm2`) as a corollary.
  - **DEPTH / COVARIANCE** — `drec_depth1` (`dsub A A' -> dsub (BRec [(k,A)])
    (BRec [(k,A')])`) and the general pointwise `drec_depth`.
  - **records are tables** — there is no dedicated table *atom*, so the faithful
    statement is `drec_is_table : dsub (BRec fields) (BRec [])`, with `BRec []`
    playing the table top-type: `empty_rec_is_tables` proves it denotes EXACTLY
    the `VTable` values. `rec_disjoint_atom` proves records are disjoint from
    every scalar atom. (A first-class table atom is a future refinement.)
  All `Qed`, all derived from the semantic `dsub` (set inclusion) — no new `dsub`
  rule, no axiom, no ad-hoc casing.
- **Boolean-algebra laws STILL hold — confirmed, no fix needed.** The increment-3
  laws (distributivity both directions, De Morgan, complement, double negation)
  were proved generically by unfolding `denote` to propositional logic; they
  never case-analyzed the `BTy` constructors, so adding `BRec` leaves them
  untouched — they compile verbatim. (`Print Assumptions ddistrib_inter_union`,
  `dde_morgan_inter`: Closed under the global context.)
- **Increment 4 preserved, not broken.** `atomic : BTy -> Prop` (no `BRec`
  subterm); `denote_head` and `decide_dsub_correct` restated under `atomic` and
  re-proved — TRUE theorems about the atomic fragment. `head`/`head_reps` gain a
  single table representative `VTable []`, sound only for `atomic` (where
  `denote` ignores table contents). The **general decision procedure for records
  is deferred** to the emptiness-based / MLstruct-style procedure.
- **Non-vacuity.** `rec_inhabited` exhibits a concrete table witness;
  `not_rec_int_sub_str` (with witness `{f=0}`) shows depth does NOT collapse;
  `not_rec_narrow_sub_wide` shows width is a genuine non-symmetric edge. So the
  record semantics is not vacuously true.

`Print Assumptions` on the structural laws, the re-scoped `decide_dsub_correct`
and `denote_head`, and the extended `denote_dec`: **Closed under the global
context** — no axioms, no `Admitted`, no `Classical`. Whole dev compiles
(`coqc proof/subtype.v`).

## Increment 6 — GENERAL emptiness-based decision procedure (records)

Increment 4's head-enumeration decider is correct only on the `atomic` fragment:
records inspect a table's *contents*, so a fixed finite set of head-reps cannot
witness the value space (recorded as the increment-5 scope limitation). Increment
6 builds the standard **MLstruct / semantic-subtyping** decider.

`proof/subtype.v` (new section, additive — increments 1–5 untouched; the atomic
`decide_dsub` stays as-is, `gdecide` is the new general relation):

- **The reduction lemma — GENERAL, all `a b : BTy`.** `dsub_iff_empty`:
  `(forall v, denote a v -> denote b v) <-> (forall v, ~ denote (BInter a (BNeg
  b)) v)`. Subtyping **is** emptiness of `A ∧ ¬B`. Proved directly by unfolding
  `denote`, using `classic_denote'` (decidability of `denote`) for the `<-`
  direction. Holds *with records present* — no fragment restriction. So the
  problem reduces to deciding emptiness of one type.

- **DNF normalization, with negated records.** A literal is a positive/negative
  atom or a positive/negative **record** (`LPosAtom | LNegAtom | LPosRec |
  LNegRec`). `to_dnf` / `to_dnf_neg` are a mutually-structural pair (NNF + De
  Morgan + double-negation distribution). Because `LNegRec` faithfully denotes
  `~ denote (BRec f)`, the **preservation lemma is UNCONDITIONAL**:
  `to_dnf_pres : denote_dnf (to_dnf t) v <-> denote t v` (and the negative dual),
  proved by one structural fixpoint; the De Morgan / double-negation directions
  use `classic_denote'`. `Qed`.

- **Emptiness by witness construction.** `find_wit_fuel n t : option V`
  *constructs* an inhabitant of `t` (or `None`). `decide_empty t := match
  find_wit_fuel (S (S (rdepth t))) t with None => true | _ => false end`;
  `gdecide a b := decide_empty (BInter a (BNeg b))`. Per clause of the DNF:
  - **scalar clause** (no positive record): decided by the six
    head-representatives — `LPosAtom`/`LNegAtom`/`LNegRec` literals are
    head-monotone (`lit_denote_head`), so a satisfiable scalar clause is
    satisfied by some rep.
  - **positive-record clause**: build a witness *table* from the merged per-key
    field requirements `field_inter k (concat positive-records)`, recursing
    `find_wit_fuel` on each intersected field type; a positive record + a
    positive scalar atom in the same clause is empty (table ≠ scalar).
  - **one negated record** `Nj`: violate it by an *absent* key (a key of `Nj`
    not positively required — the built table omits it) or by a *forced wrong
    value* at one positively-required key (`field_inter k allf ∩ ¬field_inter k
    Nj` inhabited).

- **TERMINATION — by construction.** Measure `rdepth t` = record-nesting depth.
  Every recursive `find_wit_fuel` call is on a field-intersection type whose
  `rdepth` is **strictly smaller** (`dnf_recs_shallow` + `field_inter` depth =
  max field depth). `find_wit_fuel` is a plain **structural nat recursion on
  fuel** (no `Fix`, no well-founded combinator) — it cannot loop; fuel
  `S (S (rdepth t))` is provably sufficient.

- **FRAGMENT decided (honestly delimited).** `decide_empty`/`gdecide` are proved
  sound + complete **under two predicates**:
  - `flat t` — every record's field types are record-free (`no_rec`); records do
    not nest. Covers atoms and one level of records — exactly width / depth /
    record-vs-atom disjointness.
  - `dnf_ok (to_dnf t)` — each record-clause of the DNF has **at most one
    negated record**.
  The **coupled case — ≥2 negated records sharing keys** (which arises from a
  *union of records on the right* of a subtyping query) — is **DEFERRED**: that
  branch of `clause_wit` returns `None`. This keeps the decider **globally
  SOUND** (`find_wit_sound`, *unconditional* — it never fabricates a false
  witness); only **completeness** is fragment-restricted. Nested records (depth
  ≥ 2 field types) are likewise deferred via `flat`.

- **Correctness.** `decide_empty_correct : flat t -> dnf_ok (to_dnf t) ->
  (decide_empty t = true <-> forall v, ~ denote t v)`; `gdecide_correct` is the
  subtyping corollary via `dsub_iff_empty`. Both `Qed`. The DNF-preservation
  `to_dnf_pres`, the global `find_wit_sound`, and the fragment completeness
  `find_wit_complete` are all `Qed`.

- **Non-vacuity / agreement.** `Compute`/`reflexivity` confirm the right answers
  on records and atoms (the decider COMPUTES): `gdecide {f:Int;g:Bool} {f:Int} =
  true` (width), `gdecide {f:Int} {f:Str} = false` (depth), `gdecide {f:Int} Int
  = false` (record vs atom), `gdecide ({f:Int} ∩ Int) Bot = true` (disjoint),
  `gdecide Int Num = true` / `gdecide Num Int = false` (atoms, agreeing with the
  old `decide_dsub`). `agree_width` routes the width answer through
  `gdecide_correct` to a real `dsub` fact — so `gdecide` decides *exactly* `dsub`
  on the covered fragment, not some other relation.

`Print Assumptions dsub_iff_empty`, `decide_empty_correct`, `gdecide_correct`,
`to_dnf_pres`, `find_wit_sound`: **Closed under the global context** — no axioms,
no `Admitted`, no `Classical`. Whole dev compiles (`coqc proof/subtype.v`).

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
- **[done — increment 5: records/tables]** the first **structural** former:
  `V` gains `VTable` (finite assoc-list; nested-inductive, cyclic deferred to
  μ), `BTy` gains `BRec` (OPEN/WIDTH reading; closed records + index signatures
  deferred). `denote_dec` extended (general, total). Structural subtyping laws
  proved for free: **WIDTH** (`drec_width`/`_incl`), **DEPTH/COVARIANCE**
  (`drec_depth1`/`drec_depth`), records-are-tables (`drec_is_table`,
  `empty_rec_is_tables`, `rec_disjoint_atom`). Boolean-algebra laws confirmed
  still holding (generic over `denote`, no fix needed). Increment 4's
  head-decider re-scoped to the `atomic` fragment (`denote_head`,
  `decide_dsub_correct` under `atomic`) — TRUE theorems, not broken.
  Non-vacuity proved. Closed under the global context.
- **[done — increment 6: emptiness-based decision procedure]** the general
  MLstruct-style decider. Reduction lemma `dsub_iff_empty` (GENERAL — subtyping =
  emptiness of `A ∧ ¬B`, all `a b`). DNF normalization with negated-record
  literals, faithful through records (`to_dnf_pres`, unconditional). Emptiness by
  witness construction `find_wit_fuel` (structural fuel recursion; measure
  `rdepth` = record-nesting depth, strictly decreasing — terminating by
  construction, no `Fix`). Decided fragment: `flat` (records' field types
  record-free — one level of records) + `dnf_ok` (≤1 negated record per
  record-clause). Globally SOUND (`find_wit_sound`); complete on the fragment
  (`decide_empty_correct`, `gdecide_correct`). `Compute`/agreement non-vacuity on
  width/depth/record-vs-atom/disjoint/atom cases. Closed under the global
  context.
- **[next — close the emptiness deferrals, substrate-first]** in priority order,
  each an enabling substrate before its consumers:
  **(a)** **coupled negated records** — ≥2 negated records sharing keys in one
  conjunct (arising from unions of records on the right). The principled fix is a
  per-negated-record witnessing-key *assignment search* with per-key intersected
  `¬`-requirements; lifts `dnf_ok`'s "≤1 negated record" restriction.
  **(b)** **nested records** — field types that are themselves records; lifts the
  `flat` restriction. The `find_wit_fuel`/`rdepth` machinery already supports the
  recursion structurally; the proof obligation is threading the field-completeness
  through deeper `rdepth`, not new substrate.
  **(c)** **index signatures and closed/exact records** (deferred record
  refinements; closed records need a "no other keys" denotation, index sigs a
  `∀ key`-quantified field); **(d)** a first-class **table atom** (records
  subtype an atom, not just `BRec []`).
- **[then — arrows with variance — LIKELY DESIGN FORK]** function types with
  co/contra-variance. **Flagged as a probable no-default fork:** modelling
  function VALUES in the concrete domain `V` is the open question — a function is
  not a finite structure like a table, so the head-class / finite-witness style
  that drives `find_wit_fuel` does not obviously transfer. Options span
  (i) an *extensional* finite-graph approximation, (ii) an *intensional* opaque
  arrow atom with a separate variance rule, (iii) a step-indexed / logical-
  relation denotation. This should be decided (design-it-twice) before
  implementation, not chosen by default.
- **[then — equirecursive μ]** extend `BTy` with recursive types (`μ`) and
  coinductive/contractive denotation; re-establish the laws and the decision
  procedure under recursion.
- **[then — the lib/sem reality bridge]** connect the abstract `V`/`denote` to
  the executable semantics in `lib/sem` as the empirical reality-anchor — the
  one thing proof *cannot* establish: that the model matches real LuaJIT value
  behavior.
