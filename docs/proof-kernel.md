# Proof Kernel — mechanized subtype metatheory

> **Deferred / scoped-out / future items** from every increment below are
> consolidated into ONE authoritative backlog: `TODO.md` §"Proof-dev /
> type-system backlog (deferred items)". The per-increment notes here keep their
> in-context deferral callouts, but that section is the single source of truth —
> add new deferrals there too.

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
atoms with a declared sub-order (`AInt <: ANum`, and — added with the LuaJIT 5.1
number correction — `AInt <: AFloat`, since an integer-valued number IS a float),
`Union`, `Inter`, `Top`, `Bot`; an inductive `sub` relation; **`sub_refl` and
`sub_trans` proved to `Qed`** with no `Admitted` and no added axioms
(`Print Assumptions`: closed under the global context).

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
  concrete value domain `V` with distinct constructor heads. **LuaJIT 5.1 number
  correction (fork A′):** numbers are ONE value — every 5.1 number is a single
  IEEE double (`3 == 3.0`, an integer-valued number IS a float). So `V` has a
  single number constructor `VNum : NumRep -> V`, where `NumRep := NRint nat |
  NRfrac nat` records (decidably) whether the double is integer-valued (`NRint`,
  e.g. `3.0`) or genuinely non-integer (`NRfrac`, e.g. `1.5`). The full domain is
  `VNum | VStr | VBool | VNil | VTable | VFun`. `VInt n`/`VFloat n` are NOTATIONS
  for `VNum (NRint n)`/`VNum (NRfrac n)` — there is exactly ONE number value per
  double, so `VInt 3` and `VFloat 3` are no longer distinct (the old two-number
  design tagged integers like PUC 5.3/5.4 — deferred, version-parametric).
  `atom_denote` maps each atom to a value-set: `ANum` and `AFloat` BOTH accept
  every `VNum _` (float ≡ number on 5.1), `AInt` accepts `{VNum (NRint _)}` — a
  *literal subset*, so **`AInt <: AFloat` and `AInt <: ANum` hold definitionally**
  (proved as `AInt_sub_AFloat`, `AInt_sub_ANum`, with `AFloat_equiv_ANum`). No
  int/float disjointness. Unrelated atoms pick disjoint constructors, so their
  intersection is empty *by `discriminate` on heads*, not by axiom. `denote`
  lifts to `BTy` with `∪↦∨, ∩↦∧, ¬↦~, ⊤↦True, ⊥↦False`.
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
  atoms, `denote t v` depends only on `v`'s *classification class* — the number
  class (`NRint` vs `NRfrac` inside the single `VNum`) plus the other heads
  (`VStr`/`VBool`/`VNil`), never on the `nat` payload. (The two number classes
  exist because `atom_denote AInt` distinguishes integer-valued `NRint` from
  non-integer `NRfrac`.) `atom_denote` matches only this class; the connectives
  (`Union`/`Inter`/`Neg`/`Top`/`Bot`) preserve head-dependence. Formalized as
  `head : V -> V` (collapse a value to the canonical representative of its
  class), `head_reps` (the representatives), and **`denote_head : forall t
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

- **FRAGMENT decided (honestly delimited).** The BOOL emptiness test
  `decide_empty`/`gsub_empty` is proved sound + complete **under two predicates**:
  - `flat t` — every record's field types are record-free (`no_rec`); records do
    not nest. Covers atoms and one level of records — exactly width / depth /
    record-vs-atom disjointness.
  - `dnf_ok (to_dnf t)` — each record-clause of the DNF has **at most one
    negated record**.
  The **coupled case — ≥2 negated records sharing keys** (which arises from a
  *union of records on the right* of a subtyping query) — and **nested records**
  (`flat` violations) are **DEFERRED**. See the corrected sub-increment below for
  how the deferral is surfaced soundly.

- **Correctness (bool form).** `decide_empty_correct : flat t -> dnf_ok (to_dnf t)
  -> (decide_empty t = true <-> forall v, ~ denote t v)`; `gsub_empty_correct` is
  the subtyping corollary via `dsub_iff_empty`. Both `Qed`. The DNF-preservation
  `to_dnf_pres`, the global `find_wit_sound`, and the fragment completeness
  `find_wit_complete` are all `Qed`.

### Increment 6 CORRECTED — three-valued, UNCONDITIONALLY SOUND `gdecide`

**The defect (adversarial audit).** The bool form was **fail-OPTIMISTIC**
outside its fragment. `find_wit_fuel` returns `None` both when it has *proved*
no witness AND when it *deferred* (the ≥2-coupled-negated-record branch of
`clause_wit`, and nested-record fuel exhaustion). Since `None ⇒ decide_empty =
true ⇒ "subtype"`, a bare `bool` conflates "proven subtype" with "decision
deferred", and can claim `a <: b` for a genuine NON-subtype. Demonstrated
witness: `a = {h:Int}`, `b = {f:Int} ∪ {g:Int}` → `gsub_empty a b = true`
(`trap_old_bool_wrong`) but `~ dsub a b` (`trap_not_dsub`, witness
`VTable[("h",VInt 0)]`). A confident WRONG answer — a latent unsoundness trap.

**The fix.** The witness finder is made **three-valued**:
`wit_result := Found (v:V) | NoWitness | Deferred`. The deferred clause (≥2
coupled negated records) and **fuel exhaustion** both return `Deferred` —
**never** `NoWitness` — so `NoWitness` now genuinely means "proved witness-free".
Propagation over the DNF disjunction: `Found` anywhere ⇒ `Found`; else any
`Deferred` ⇒ `Deferred`; else `NoWitness`. The table builders (`table_wit3`,
`table_wit_neg3`) propagate `Deferred` from any deferred sub-query. The exported
`gdecide a b : decision` (`DSub | DNotSub | DUnknown`) maps `Found ⇒ DNotSub`,
`NoWitness ⇒ DSub`, `Deferred ⇒ DUnknown`.

- **TWO UNCONDITIONAL soundness theorems** (no `flat`/`dnf_ok` hypothesis, for
  ALL `a b : BTy` — a definite answer is *never* wrong):
  - `gdecide_DSub_sound : gdecide a b = DSub -> dsub a b`. Rests on
    `find_wit3_nowit_empty : find_wit3 n t = NoWitness -> forall v, ~ denote t v`
    (proved unconditionally — the NoWitness path was reworked to establish
    emptiness genuinely, using a per-query "`wf3 T = NoWitness ⇒ T empty`"
    invariant rather than the old `no_rec`/`dnf_ok` hypotheses) + `dsub_iff_empty`.
  - `gdecide_DNotSub_sound : gdecide a b = DNotSub -> ~ dsub a b`. From
    `find_wit3_sound : find_wit3 n t = Found v -> denote t v` (witness validity).
- **Completeness, fragment-restricted.** `gdecide_complete : flat (a ∧ ¬b) ->
  dnf_ok (to_dnf (a ∧ ¬b)) -> gdecide a b <> DUnknown` — on the fragment the
  answer is always definite; `gdecide_fragment_correct` then shows that definite
  answer matches `dsub`. The fragment predicates now characterize **completeness
  (no-`DUnknown`) only** — soundness no longer depends on them.
- **The trap is gone, verified.** `gdecide {h:Int} ({f:Int}∪{g:Int}) = DUnknown`
  (`trap_gdecide_unknown`, by `reflexivity`), and `trap_not_dsub_claim :
  gdecide ... <> DSub`. In-fragment cases still definite and correct:
  `gdecide {f:Int;g:Bool} {f:Int} = DSub` (width), `gdecide {f:Int} {f:Str} =
  DNotSub` (depth), `gdecide {f:Int} Int = DNotSub` (record vs atom),
  `gdecide ({f:Int}∩Int) Bot = DSub` (disjoint), atoms agreeing with the old
  `decide_dsub`. `gd3_agree_width`/`gd3_agree_depth` route definite answers
  through the unconditional soundness theorems to real `dsub` / `~dsub` facts.

The old bool `decide_dsub` (atomic fragment) and `gsub_empty` (the internal
fragment workhorse, retained for `gsub_empty_correct`) stay; `gdecide` is the
three-valued general relation.

`Print Assumptions dsub_iff_empty`, `decide_empty_correct`, `gsub_empty_correct`,
`to_dnf_pres`, `find_wit_sound`, **`gdecide_DSub_sound`, `gdecide_DNotSub_sound`,
`gdecide_complete`**: **Closed under the global context** — no axioms, no
`Admitted`, no `Classical`. Whole dev compiles (`coqc proof/subtype.v`).

## Increment 7 — SINGLE-ARG / SINGLE-RETURN FUNCTION TYPES (arrows)

The first **behavioural** type former. Single input / single output per call;
**multi-return / vararg DEFERRED**. Function VALUES are modelled by their FINITE
input/output graph — a de-risk choice that keeps the value domain a plain
positive inductive (no coinduction, no step-indexing).

`proof/subtype.v` (new section, additive — increments 1–6 untouched; the decider
is threaded but stays unconditionally sound):

- **Value-domain extension.** `V` gains `VFun : list (V * V) -> V` — a function
  value is a finite list of (input, output) pairs. `V` occurs only POSITIVELY (as
  the element type of the graph list), so this is Coq-legal: no negative
  occurrence. Cyclic / higher-order-via-`V` values are fine (positive `V`); the
  hand-rolled `V_rect_strong` is extended with the `VFun` case (a second
  list-property `Pg` over the graph; a plain `Fixpoint`, no axiom).
- **Type former.** `BTy` gains `BArrow : BTy -> BTy -> BTy`.
- **Denotation (semantic-subtyping reading).**
  `denote (BArrow A B) (VFun g) := forall i o, In (i,o) g -> denote A i -> denote
  B o`; `denote (BArrow _ _) v := False` for any non-`VFun` `v` (functions are a
  distinct value-kind, disjoint from scalars and tables). Written as a structural
  nested fixpoint over the graph (so the recursive `denote A i` / `denote B o`
  calls at structural subterms `A`, `B` are guard-accepted); the `In`-quantified
  reading is recovered as `denote_arrow_iff`.
- **`denote_dec` extended, stays general + total.** Arrow membership is decidable:
  the graph is finite, and for each pair the implication `denote A i -> denote B
  o` is decided (decide the antecedent; if it holds, decide the consequent).
  Constructive, no `Classical`; `Defined`.
- **CORE arrow laws — theorems-for-free from the denotation:**
  - **CONTRA/COVARIANCE** — `darrow_variance`: `dsub A' A -> dsub B B' -> dsub
    (BArrow A B) (BArrow A' B')` (contravariant domain, covariant codomain), with
    one-sided corollaries `darrow_covariant_cod` / `darrow_contravariant_dom`.
    Follows by unfolding `denote` + pushing the inclusions through the graph
    quantifier.
  - **DISJOINTNESS** — arrows are a distinct kind: `arrow_disjoint_atom`
    (`(A→B) ∩ atom <: Bot`) and `arrow_disjoint_rec` (`(A→B) ∩ record <: Bot`),
    since `VFun ≠` scalar/table heads (`discriminate`).
- **Boolean-algebra laws STILL hold — confirmed, no fix needed.** The increment-3
  laws were proved generically by unfolding `denote` to propositional logic; they
  never case-analyzed the `BTy` constructors, so adding `BArrow` leaves them
  untouched — they compile verbatim. (`Print Assumptions ddistrib_inter_union`:
  Closed under the global context.)
- **DECIDER STAYS UNCONDITIONALLY SOUND — arrow ⇒ Deferred ⇒ DUnknown.** Adding
  `BArrow` touches `denote`, `denote_dec`, the DNF/literal machinery, the
  witness-finder, and `atomic`/`flat`. All are threaded: a new **arrow literal**
  kind (`LPosArrow`/`LNegArrow`), `to_dnf`/`to_dnf_neg` emit them, `to_dnf_pres`
  stays unconditional. The witness-finder gains a `has_arrow` guard: **any clause
  containing an arrow literal returns `Deferred`** (three-valued `clause_wit3`) /
  `None` (bool-era `clause_wit`), BEFORE the scalar/record branches — so the
  finder NEVER claims a witness exists or that an arrow-involving clause is empty.
  `atomic`, `no_rec`, `flat`, `neg_atomic` all send `BArrow` to `False` (arrows
  are outside the head-decidable / proven-complete fragment), and `cl_rf` is
  strengthened to require arrow-freeness. The **two unconditional soundness
  theorems are re-established for the extended `BTy`** (all `a b`, arrows
  included): `gdecide_DSub_sound : gdecide a b = DSub -> dsub a b` and
  `gdecide_DNotSub_sound : gdecide a b = DNotSub -> ~ dsub a b` remain TRUE —
  arrows ⇒ `DUnknown` ⇒ no claim. Sanity (`reflexivity`): `gdecide (Int→Int)
  (Int→Str) = DUnknown`, `gdecide (Int→Int) (Num→Int) = DUnknown`, and
  `gd_arrow_not_dsub_claim : gdecide (Int→Int) (Int→Str) <> DSub`.
- **Non-vacuity / faithfulness.** Arrow types are inhabited (`arrow_inhabited`;
  `empty_fun_in_every_arrow` — the empty graph vacuously inhabits every arrow).
  CORRECT non-subtypes with explicit witnesses:
  - `~ dsub (Int→Int) (Int→Str)` — codomain, witness `VFun [(VInt 0, VInt 0)]`;
  - `~ dsub (Int→Int) (Num→Int)` — domain contravariance, witness
    `VFun [(VFloat 0, VStr 0)]` (vacuously in `Int→Int` since `VFloat ∉ Int`, but
    not in `Num→Int` since `VFloat ∈ Num` forces the `VStr` output into `Int`).
- **DECOMPOSITION LAW — codomain intersection CLOSES; the rest DEFERRED.**
  `darrow_inter_cod : dequiv ((A→B) ∩ (A→C)) (A → (B∩C))` is proved both
  directions, directly from `denote` (set inclusion). **The finite-graph model
  VALIDATES it — no faithfulness gap / no fork.** The harder decomposition facts —
  `(A→C) ∩ (A'→C) <: (A∪A')→C` and the arrow-emptiness laws — are DEFERRED to a
  future increment (they need either an arrow-aware decision procedure or further
  model lemmas). No intended arrow law was found to FAIL in the finite-graph model,
  so no genuine model-design fork was hit at this increment.

`Print Assumptions` on `gdecide_DSub_sound`, `gdecide_DNotSub_sound`,
`gdecide_complete`, `darrow_variance`, `arrow_disjoint_atom`, `arrow_disjoint_rec`,
`darrow_inter_cod`, `denote_dec`, `ddistrib_inter_union`: **Closed under the
global context** — no axioms, no `Admitted`, no `Classical`. Whole dev compiles
(`coqc proof/subtype.v`).

## Increment 8 — TYPING LAYER: minimal syntactic type soundness (progress + preservation)

The first **typing** increment, atop the subtyping algebra. A NEW file
`proof/typing.v` (builds on `proof/subtype.v`, which is **unmodified**) defines a
small term language, a typing judgment using the subtyping algebra, a CBV
small-step operational semantics, and proves **progress + preservation** — the
de-risk skeleton for a sound typechecker. Build: `coqc proof/subtype.v` then
`coqc proof/typing.v` (typing.v `Require Import subtype`s the `.vo` next to it).

- **Term language — de Bruijn.** `tm` = literals (`tlit` over `lit` = int/str/
  bool/nil) · `tvar n` · `tlam T body` (single typed arg) · `tapp` · `tlet` ·
  `trec` (record) · `tproj` (field projection). De Bruijn indices make
  capture-avoidance structural and alpha-equivalence syntactic (respecting the
  carry-forward findings: source names ≠ binder identity).
- **Typing judgment.** `has_type : list BTy -> tm -> BTy -> Prop` over a de
  Bruijn context, mutual with `has_fields` for records (so the generated
  induction principle carries a per-field IH). Rules: lit↦its base atom, var↦
  context lookup, lam↦`BArrow`, app, let, rec↦`BRec` (with **`NoDup` keys** —
  Lua-faithful, makes first-match `field_lookup` agree with the key's type),
  proj, and **SUBSUMPTION (`TSub`)**.
- **Operational semantics.** CBV substitution-based `step : tm -> tm -> Prop`
  over de Bruijn (lift/subst defined): beta, let-bind, projection lookup, the CBV
  congruence/eval-context rules, and left-to-right record-field reduction.
  `value` = literals / lambdas / all-value records.
- **The two soundness theorems, both `Qed`.** `progress : has_type [] e T ->
  value e \/ exists e', step e e'` and `preservation : has_type [] e T -> step e
  e' -> has_type [] e' T`. Supporting metatheory all `Qed`: canonical forms
  (`canon_arrow`/`canon_rec`), general weakening + a closed-term lift-invariance
  lemma, the **substitution lemma** (closed substituend at the cut), subsumption-
  transparent typing-inversion lemmas, and the subtyping-inversion lemmas.

### The central FINDING — semantic `dsub` is too coarse; subsume via syntactic `ssub`

Driving subsumption with the raw semantic `dsub` of subtype.v makes
**preservation FALSE**, and this is machine-checked, not asserted. In the
value-set model an arrow with a `Top` (or otherwise unconstrained) codomain
COLLAPSES: `denote (BArrow A BTop) v` ⟺ `v` is any function value, so

  `dsub (BArrow (BRec [("f",Int)]) Int) (BArrow Int BTop)`   — **provable**
  (`arrow_top_collapse`)

holds, letting a record-domained function be subsumed to `Int -> Top`, applied to
an `Int`, and beta-reduced to a term that projects a field off an `Int`: STUCK and
untypeable at any type (`preservation_dsub_counterexample`). The principled fix —
and the reason a syntactic *algorithmic* relation has been on the roadmap since
increment 3 — is to subsume along a syntactic subtyping **`ssub`** whose arrow
rule has variance inversion BUILT IN (contravariant domain / covariant codomain
as a premise). `ssub` is proved **sound** w.r.t. `dsub` (`ssub_sound : ssub a b
-> dsub a b`), so the proven semantic Boolean algebra still grounds every
subtyping step; what `ssub` adds is the invertibility (`ssub_arrow_inv`,
`ssub_rec_inv`) the term structure needs. This realizes the increment-3 deferral
"retain `sub` as the future algorithmic relation, prove it sound vs `dsub`" for
the arrow+record fragment.

The guarded **`dsub` arrow inversion** is ALSO proved, documenting the model's
true edge cases: `arrow_inv_cod` needs `A1 ∩ A2` inhabited (else `BArrow BBot B1`
is vacuously huge and `B1` is unconstrained); `arrow_inv_dom` needs `¬B2`
inhabited (`B2 ≠ Top`, the collapse above). These are the "harder arrow laws"
backlog item, surfaced precisely rather than faked.

### Non-vacuity + assumption audit

`(λx:Int. x) 3` is well typed at `Int` and steps to `3` (`ex_id_app_*`); a record
projection `{a=7,b=true}.a` is well typed at `Int` and steps to `7`
(`ex_proj_*`); two ill-typed terms are proved **rejected at every type**
(`ex_bad_untyped`: project a field off an int; `ex_bad2_untyped`: apply a
non-function). So the judgment is not vacuous.

`Print Assumptions` on `progress`, `preservation`, `ssub_arrow_inv`,
`ssub_sound`, `arrow_top_collapse`: **Closed under the global context** — no
axioms, no `Admitted`, no `Classical`. `subtype.v` is unmodified; the whole dev
compiles (`coqc proof/subtype.v && coqc proof/typing.v`).

**DEFERRED (honest minimal core).** Statements / control flow, mutation /
references, multi-arg / vararg / multi-return, recursion (`tfix`/μ), metatables,
union/negation/arrow types as TERM introduction forms, duplicate-key record
literals, `ssub` completeness vs `dsub`, and the reality bridge to `lib/sem`.
All recorded in `TODO.md` §"Typing layer".

## Increment 9 — `ssub` solidified: preorder + total decision procedure + the `dsub`/`ssub` gap

A NEW file `proof/ssub.v` (builds on **unmodified** `proof/subtype.v` and
`proof/typing.v`) makes the checker's syntactic subtyping relation `ssub` — the
one `TSub` subsumes along, already proved sound vs `dsub` (`ssub_sound`) — into a
solid, runnable, characterized relation. Build order:
`coqc proof/subtype.v` → `coqc proof/typing.v` → `coqc proof/ssub.v`.

- **PREORDER.** `ssub_refl : forall t, ssub t t` and
  `ssub_trans : forall a b c, ssub a b -> ssub b c -> ssub a c`, exposed as named
  lemmas (the typing metatheory composes subsumption along them). Both are the
  `SsRefl`/`SsTrans` constructors of `ssub` — `ssub` bakes transitivity in as a
  primitive (unlike `subtype.v`'s free-lattice `sub`, where transitivity was real
  size-induction metatheory). The arrow/record "care" that transitivity needs
  lives in the INVERSION lemmas already in `typing.v` (`ssub_arrow_inv`,
  `ssub_rec_inv`), surfaced here as `ssub_trans_arrow` / `ssub_trans_rec`
  (contra/co recomposition at arrows; per-field composition at records).

- **A TOTAL, TERMINATING DECISION PROCEDURE `decide_ssub : BTy -> BTy -> bool`,
  proved SOUND AND COMPLETE:** `decide_ssub_correct : decide_ssub a b = true <->
  ssub a b` (`Qed`), with corollaries `decide_ssub_sound`, `decide_ssub_complete`,
  `decide_ssub_false` (false ⇒ `~ ssub`), and the sumbool `ssub_dec`.
  - **Terminating BY CONSTRUCTION.** A structural fuel recursion on the combined
    size measure `bsize a + bsize b` (stated explicitly); every recursive call
    strictly decreases the sum — contravariant arrow domain (`decide A2 A1`),
    covariant codomain (`decide B1 B2`), record width+depth (each field strictly
    inside its `BRec`, via `bsize_field_lt`). NO emptiness/DNF machinery (that was
    for the SEMANTIC `dsub`); `ssub` is syntactic, so this is clean structural
    recursion. The top-level `decide_ssub a b := decide_ssub_fuel (bsize a +
    bsize b) a b` uses exactly-sufficient fuel.
  - **TOTAL over the WHOLE of `BTy`** — a definite `bool` for every pair, a clean
    improvement over `gdecide`'s `DUnknown`.
  - **FRAGMENT that is total-decidable EXACTLY (honest scope):** the structural
    fragment `ssub` actually relates — **atoms** (by the declared atom order),
    **arrows** (contra/co), **records** (width + depth), plus `Top`/`Bot`. On the
    **Boolean connectives** (`BUnion`/`BInter`/`BNeg`) `ssub` has NO structural
    rule: its constructors are `SsRefl`/`SsTrans`/`SsTop`/`SsBot`/`SsAtom`/
    `SsArrow`/`SsRec` only. So `ssub c d` for a connective-headed `c` holds iff
    `d = BTop` or `c = BBot` or `c = d` SYNTACTICALLY (`ssub_connective_super` /
    `ssub_connective_sub`, proved by derivation induction). `decide_ssub` decides
    THIS exactly and totally (via a derived `BTy` equality test `bty_eq_dec`) — it
    is total on connectives but COARSE: it recognises only the reflexive/Top/Bot
    connective subtypings, NOT the semantic Boolean ones (e.g. `BInter X Y <: X`).
    Deciding connective-`ssub` semantically is `dsub`'s job (`gdecide`) and is
    DEFERRED (TODO.md). This is correct: the typing core subsumes only along
    `ssub`, whose connective subtypings ARE exactly the structural ones, so
    `decide_ssub` decides precisely what the checker needs.
  - **`Compute` sanity (non-vacuity — returns BOTH true and false, decides
    exactly `ssub`):** the crux `decide_ssub (Rec→Int) (Int→Top) = false` (ssub
    correctly REJECTS the unsound collapse, unlike `dsub`); contravariant
    `decide_ssub (Num→Int)(Int→Int) = true`, `decide_ssub (Int→Int)(Num→Int) =
    false`; covariant codomain true/false; record width true/false; record depth
    `{a:Int} <: {a:Num} = true`, reverse false; atoms; Top/Bot; and the connective
    coarseness `decide_ssub (Int∩Str) Int = false`. `agree_*`-style examples route
    definite answers back to real `ssub` / `~ssub` facts.

- **THE `ssub`-vs-`dsub` GAP, characterized — `ssub_sound` gives `ssub ⊆ dsub`;
  the inclusion is STRICT, with TWO precise gap instances:**
  - `dsub_ssub_gap`: `dsub (BArrow Rec Int) (BArrow Int Top) /\ ~ ssub (BArrow Rec
    Int) (BArrow Int Top)` — the operationally-unsound arrow/Top collapse `dsub`
    admits (`arrow_top_collapse`, typing.v) and `ssub` correctly rejects (the
    central preservation-breaking witness).
  - `dsub_ssub_gap_atom`: a SECOND, atom-level instance — `dsub (BAtom AFloat)
    (BAtom ANum) /\ ~ ssub (BAtom AFloat) (BAtom ANum)`. On LuaJIT 5.1 `AFloat`
    and `ANum` BOTH denote all numbers (float ≡ number), so they are
    `dsub`-equivalent, but the SYNTACTIC atom order `atom_le` has NO edge between
    them (only `AInt <: ANum`, `AInt <: AFloat`). `ssub` tracks the DECLARED
    order, not the value sets — the honest price.
  - **COINCIDENCE where they agree:** on the AFLOAT-FREE atom fragment `ssub` and
    `dsub` are EQUAL (`ssub_dsub_coincide_atom`, with `dsub_atom_atom_noafloat`
    proving the converse by value-witness refutation); and the structural
    direction holds generally — every `decide_ssub`-true pair is a `dsub`
    (`decide_ssub_implies_dsub`).
  - **The general `ssub`-completeness vs ALL operationally-sound subtypings is the
    DEEP open characterization question — DEFERRED** (TODO.md). What is proved
    here is the precise WHERE-they-differ (the two gap instances) and
    WHERE-they-coincide (afloat-free atoms; the structural ⊆ direction), as
    partial progress.

- **WIRING.** The subtyping side of the typing layer is now runnable:
  `subsumption_decidable : has_type G e S -> decide_ssub S T = true -> has_type G
  e T` makes `TSub`'s `ssub` premise discharge by the executable `decide_ssub`;
  `subsumption_step_undecidable_false` is the negative side. (Full algorithmic
  typechecking is a later increment — only the subtyping decision is wired here.)

`Print Assumptions` on `ssub_refl`, `ssub_trans`, `decide_ssub_sound`,
`decide_ssub_complete`, `decide_ssub_correct`, `dsub_ssub_gap`,
`dsub_ssub_gap_atom`, `ssub_dsub_coincide_atom`: **Closed under the global
context** — no axioms, no `Admitted`, no `Classical`. `subtype.v` AND `typing.v`
are unmodified; the whole dev compiles
(`coqc proof/subtype.v && coqc proof/typing.v && coqc proof/ssub.v`).

## Increment 10 — BIDIRECTIONAL ALGORITHMIC CHECKER, proven SOUND vs declarative typing

A NEW file `proof/check.v` (builds on **unmodified** `proof/subtype.v`,
`proof/typing.v`, `proof/ssub.v`) turns the declarative `has_type` of increment 8
into a RUNNABLE, proven-sound typechecker. Build order:
`coqc proof/subtype.v` → `coqc proof/typing.v` → `coqc proof/ssub.v` →
`coqc proof/check.v`.

The declarative judgment is NOT syntax-directed: the subsumption rule `TSub`
fires at any term, so it is not an algorithm. The fix is BIDIRECTIONAL typing —
a syntax-directed `synth` (infer) mode and a `check` (check-against) mode that
switches to `synth` and discharges the one subsumption obligation via the TOTAL,
proven `decide_ssub` (increment 9). `check` is the ONLY place subtyping is
consulted, exactly at the application argument position.

- **The algorithm (executable, total, structural on `tm`).**
  `synth : list BTy -> tm -> option BTy`: lit ⇒ base atom; var ⇒ context lookup;
  `tlam T b` ⇒ `synth (T::G) b = Some Tb` then `BArrow T Tb`; `tapp f a` ⇒ head
  synths to `BArrow A B`, arg synths to `Sa`, `decide_ssub Sa A` gates `Some B`;
  `tlet e1 e2` ⇒ synth `e1 = S`, synth `(S::G) e2`; `trec fs` ⇒ `keys_nodup`
  gate (rejects duplicate keys, the `NoDup` invariant), then `synth_fields`
  assembles `BRec`; `tproj e k` ⇒ subject synths to `BRec fs`, `flook k fs`.
  `check G e T := match synth G e with Some S => decide_ssub S T | None => false end`.
  `Compute` reduces every case to a definite `Some _`/`None`/`true`/`false`
  (witnessed: `synth [] ((λx:Int.x) 3) = Some Int`; `{a=7,b=true}.a = Some Int`;
  ill-typed `(3).f`, `3 1`, duplicate-key literal ⇒ `None`).

- **SOUNDNESS vs declarative — the load-bearing direction, both `Qed`.**
  `synth_sound : synth G e = Some T -> has_type G e T` and
  `check_sound : check G e T = true -> has_type G e T`, proved mutually by `tm`
  induction (the `tm_rect_strong` `Pl` carries the record-field IH), using
  `decide_ssub_sound` at the `check` mode-switch + `TSub`. **`Print Assumptions`
  on both: Closed under the global context.** This makes the runnable checker
  sound against the proven declarative semantics.

- **COMPLETENESS — the tractable fragment, proved (`Qed`), the rest DEFERRED
  precisely (not faked).** Full bidirectional completeness over the WHOLE
  declarative judgment is NOT provable in this minimal core: `TSub` is
  non-syntax-directed (can appear anywhere), and there are two genuine
  degeneracies — a function/record SUBJECT may declaratively type at `BBot`
  (uninhabited) where `synth` only produces an arrow/record head; and projection
  over a non-`NoDup` record assigns multiple types, so a LEAST type need not
  exist. What IS proved, generally and axiom-free, is **principality**:
  `synth_principal : proj_free e -> has_type G e T -> synth G e = Some S ->
  ssub S T` — whenever `synth` produces a type, it is the LEAST type the
  declarative judgment assigns. Together with `synth_sound` this characterizes
  `synth` exactly (its output is a declarative type, and the minimal one). The
  `tlet` case needs context **narrowing** (`narrowing` — replacing a context
  entry by an `ssub`-subtype preserves typing — proved generally here). `tproj`
  principality is fenced to the `proj_free` fragment: it requires `NoDup` keys to
  match `flook`'s first match to the subtyping supplier (typing.v itself only
  proves projection principality under `NoDup`). **`Print Assumptions` on
  `synth_principal` and `narrowing`: Closed under the global context.**

- **CONNECTIVE NOTE (honest scope).** `check` routes subtyping through
  `decide_ssub`, which is COARSE on the Boolean connectives (increment 9:
  structural/reflexive only). So connective subtyping IN CHECKING inherits that
  limitation — full connective checking needs the `dsub`/`gdecide` route,
  DEFERRED (see TODO.md).

DEFERRED from this increment (recorded honestly, minimal core only): algorithmic
adequacy / non-degeneracy (`synth` succeeds on every well-typed term — blocked by
the `BBot`/narrowing degenerate positions); `tproj` principality under `NoDup`
records; full connective subtyping in checking (inherits `ssub`'s structural-only
limitation); and everything already deferred at the typing layer (statements,
mutation, multi-arg/return, recursion, metatables, union/neg/arrow as term
intro forms).

## Increment 11 — CONDITIONALS + UNION TYPES (union-`ssub` decided, soundness preserved)

The gateway to flow typing: the term core gains a **conditional** (`tif`), and
`ssub` / `decide_ssub` gain **union** rules — proven sound vs `dsub` and
operationally safe (progress + preservation still hold). **INTERSECTION,
NEGATION, and flow NARROWING are DEFERRED** (next increments); this increment is
honestly scoped to *unions only*. Modifies `proof/typing.v`, `proof/ssub.v`,
`proof/check.v`; `proof/subtype.v` is **unmodified**. Build order unchanged.

- **Term language.** `tm` gains `tif : tm -> tm -> tm -> tm` (boolean condition,
  then-branch, else-branch). Op-sem: `tif (lit true) e1 e2 ↦ e1`,
  `tif (lit false) e1 e2 ↦ e2` (lazy branches), and a congruence `SIf1` reducing
  the condition. Values unchanged.
- **Typing (declarative).** `TIf : has_type G c Bool -> has_type G e1 T1 ->
  has_type G e2 T2 -> has_type G (tif c e1 e2) (BUnion T1 T2)` — the JOIN of the
  branch types; subsumption (`TSub`) widens further.
- **UNION rules added to `ssub`** (composable form, mirroring subtype.v's `sub`):
  `SsUnionInL : ssub A B -> ssub A (B∪C)`, `SsUnionInR : ssub A C -> ssub A (B∪C)`
  (intro), `SsUnionE : ssub A C -> ssub B C -> ssub (A∪B) C` (elim). The brief's
  plain injections are derived at `SsRefl` (`ssub_union_inl/inr`). **Proven SOUND
  vs `dsub`** (`ssub_sound` extended: union is the join in the Boolean algebra).
- **`decide_ssub` decides union subtyping, TOTAL + terminating.** New clauses,
  ordered: **union-on-LEFT first** (`A∪B <: C` iff `decide A C && decide B C` —
  `SsUnionE`, converse by intro+trans), then **union-on-RIGHT** for a non-union
  `a` (`a <: B∪C` iff `decide a B || decide a C` — `SsUnionInL/InR`). **Termination
  measure unchanged:** structural fuel on `bsize a + bsize b`; each union step
  strips one connective constructor off `a` or `b`, so the sum strictly decreases
  at every recursive call. Re-proven **sound + complete** vs the extended `ssub`
  (`decide_ssub_correct`), still **total** over all of `BTy`.

### The soundness subtlety this increment surfaces (and the principled fix)

`ssub` has **explicit transitivity** (`SsTrans` is a constructor — deliberate, so
the typing-layer `inv_*` lemmas thread arbitrary subsumption chains). The union
INTRO rules let a transitivity MIDDLE be a union (e.g.
`A1→B1 <: (A2→B2 ∪ A1→B1) <: A2→B2`), and a naive "induction on the derivation"
supertype-inversion **STALLS at the union middle** — no IH for the
union-decomposed components (they are fresh trans-built derivations). The old
shape lemmas (`ssub_top_src`, `ssub_connective_super`, …) became **outright
FALSE** under unions (`BTop <: BTop∪X`; a `BUnion` is genuinely below/above other
types via elim/intro).

**The fix (no cut-elimination, no size juggling):** characterize "what lies
above/below" by a STRUCTURAL predicate over the type syntax — `arrow_above`,
`rec_above`, `atom_above`, `top_above`, `interneg_above`, and the dual
`union_below` — and prove each **closed under `ssub`** (`*_above_mono` /
`union_below_mono`) **by induction on the `ssub` derivation**. Every case — incl.
`SsTrans` and the three union cases — composes through the structural predicate
with its IHs as proper sub-derivations (the union analogue of subtype.v's
"composable rules make inversion routine", here against explicit transitivity).
This yields the union-robust inversions the decider's completeness needs:
`ssub_arrow_inv`, `ssub_rec_inv`, `ssub_union_src_l/r` (elim),
`ssub_union_tgt_inv` (intro), the atom leaf `ssub_atom_atom`, and the
cross-kind not-`ssub` facts. `BInter`/`BNeg` stay the **DEFERRED** connectives:
no structural rule, decided reflexively, leaf completeness via
`ssub_interneg_leaf`.

### Operational safety — preservation holds with unions

The union rules do **not** reintroduce an arrow-Top-style unsoundness. In
`preservation`, the `tif` selector cases (`SIfTrue`/`SIfFalse`) subsume the chosen
branch into the union via `ssub_union_inl`/`_inr` then `SsTrans` through the
ascribed type — the branch value is *genuinely* in the union, so subsumption is
sound. `progress` adds the `tif` case via a new canonical-forms-for-Bool lemma
(`canon_bool`: a closed `Bool` value is a boolean literal). Both `Qed`.

### `synth`/`check` for `tif` + re-proved soundness

`synth (tif c e1 e2)`: synthesize `c` and check it against `Bool` (the mode
switch / `decide_ssub`), synthesize both branches, return `BUnion` of the branch
types. `synth_sound`/`check_sound` re-proved (`Qed`); `synth_principal` extended
(union monotonicity: `SsUnionE` + the injections). The check switch routes union
subtyping through the extended `decide_ssub`.

### Non-vacuity + assumption audit

`if true then 3 else "s"` synthesizes `Int ∪ Str` (`compute_if_union`), checks
against `Top`, is `has_type` at the union, and **steps to `3`** (`ex_if_*`);
`decide_ssub Int (Int∪Str) = true`, `decide_ssub (Int∪Int) Int = true` (elim),
`decide_ssub (Int∪Str) Num = false` (Str ⊄ Num), `decide_ssub Bool (Int∪Str) =
false` — union subtyping decides correctly (the `sanity_union_*` examples route
definite answers back to real `ssub`/`~ssub` facts). A non-Bool condition gives
`synth = None`.

`Print Assumptions` on `progress`, `preservation`, `ssub_sound`,
`decide_ssub_correct`, `synth_sound`, `check_sound` (and 31 audited results
across the chain): **Closed under the global context** — no axioms, no
`Admitted`, no `Classical`. `subtype.v` is unmodified; the whole chain compiles
(`coqc subtype.v && coqc typing.v && coqc ssub.v && coqc check.v`).

**DEFERRED (recorded honestly — unions only this increment):** intersection /
negation as `ssub` rules and as term-introduction forms; flow NARROWING (the
actual flow-typing payoff — narrowing a variable's type inside a `tif` branch by
the condition); semantic connective subtyping in `ssub` (still `dsub`/`gdecide`'s
job); and everything already deferred at the typing layer.

## Increment 12 — INTERSECTION + NEGATION in `ssub`; flow narrowing DEFERRED (with proof)

Adds the **intersection GLB rules** (and the negation discipline) to `ssub` — the
substrate flow narrowing was meant to consume — proven SOUND vs `dsub` with
**preservation re-proved** (`Qed`). Modifies `proof/typing.v`, `proof/ssub.v`,
`proof/check.v`; **`proof/subtype.v` unmodified**. Build order unchanged.

### Intersection `ssub` rules (composable GLB, dual to the union rules)

- `SsInterPL : ssub A C -> ssub (A∩B) C`, `SsInterPR : ssub B C -> ssub (A∩B) C`
  (composable PROJECTIONS); `SsInterI : ssub C A -> ssub C B -> ssub C (A∩B)`
  (INTRODUCTION / GLB). Brief's plain projections derived at `SsRefl`
  (`ssub_inter_prl/prr`); target decomposition `ssub_inter_tgt_l/r`.
- **Proven SOUND vs `dsub`** — `ssub_sound` extended: intersection is the meet
  (`dinter_prl`/`dinter_prr`/`dinter_glb` of the proven Boolean algebra). All
  three new cases close by unfolding `denote` to propositional logic.
- **NEGATION stays reflexive-only in `ssub`** (no structural `BNeg` rule). The
  COMPLEMENT disjointness `A ∩ ¬A <: Bot` that narrowing relies on is kept a
  **semantic (`dsub`) fact** (`dcomplement_inter`, subtype.v), used operationally
  — NOT an `ssub` rule. Adding it as a rule would force `ssub` to decide
  empty-intersection reachability (an emptiness problem — `dsub`'s job), breaking
  the clean decision procedure. Honest, deliberate scoping.

### The inversion machinery, re-architected for intersection

The supertype-side predicates (`arrow_above`, `rec_above`, `atom_above`,
`top_above`, `interneg_above`) each gain a `BInter Tl Tr => P Tl /\ P Tr` case
(an arrow/atom/… lies above an intersection iff above BOTH); their `*_mono`
lemmas are extended for the three new `ssub` cases. **The old leftward predicate
`union_below` is RETIRED** — it becomes provably non-monotone once intersection
rules exist (the inter-LEFT vs union-RIGHT cross is the non-distributive
frontier; no structural `BInter` form satisfies `SsInterPL`/`SsInterPR`/`SsInterI`
simultaneously — shown by three pairwise-incompatible attempts). Replaced by the
SOUNDNESS CONVERSES of the `_above` predicates (`atom_above_sound`,
`arrow_above_sound`, `rec_above_sound`, `top_above_sound`, `interneg_above_sound`
— `K_above S T -> ssub S T`, by induction on `T`), which yield connective-target
inversion for a LEAF source uniformly across union AND intersection targets
(`ssub_union_tgt_inv`, `ssub_inter_tgt_inv`).

### `decide_ssub` — TOTAL + SOUND everywhere; COMPLETE on the inter-free fragment

New clauses, ordered: union-on-LEFT, **inter-on-RIGHT (GLB)**, union-on-RIGHT,
**inter-on-LEFT (projection)**, leaves. Termination measure unchanged
(`bsize a + bsize b`, strictly decreasing). The correctness statement is **split**:

- **`decide_ssub_sound` — UNCONDITIONAL** (the load-bearing direction): every
  accepted pair — *including all intersection/negation pairs* — is a genuine
  `ssub`. The decider never claims a non-subtyping.
- **`decide_ssub_complete` — on the INTERSECTION-FREE fragment**
  (`inter_free a -> inter_free b -> ssub a b -> decide_ssub a b = true`). There
  the `BInter` clauses never fire and the decision coincides with the (complete)
  increment-11 atom/arrow/record/union decider.

**Why completeness is fragment-scoped — a REAL finding, not a skill gap.** Once
intersection PROJECTIONS (`SsInterPL`) enter, a full `<->` `decide_ssub_correct`
is **impossible**: the inter-LEFT vs union-RIGHT / inter-RIGHT cross is exactly
the **distributivity frontier** — `ssub (A∩B) C` need not reduce to a single
projection, and no clause order is complete for it (inter-left-vs-union-right
wants inter-left first; inter-left-vs-inter-right wants inter-right first —
contradictory). This mirrors subtype.v's machine-checked **N5 non-distributivity**
of the free lattice. Deciding the cross is the emptiness/distributivity route
(`dsub`/`gdecide`), DEFERRED. A **concrete sound-incompleteness witness** is
recorded: `decide_ssub ((Int∪Str)∩Bool) (Int∪Str) = false`
(`sanity_inter_union_cross_incomplete`) while the subtyping genuinely HOLDS
(`sanity_inter_union_cross_holds`, via `SsInterPL`+`SsRefl`) — incompleteness, not
unsoundness; the left type is not `inter_free`, so it is off the complete fragment
(no false claim). Inter-on-the-RIGHT (GLB) is decided *completely* (it is a full
iff via `SsInterI`); only inter-on-the-LEFT is the deferred frontier.

### Preservation re-proved; `synth`/`check` re-proved

`progress` + `preservation` **re-proved `Qed`** (the new `ssub` rules touch only
the inversion lemmas they consume, whose interfaces are unchanged). `synth_sound`,
`check_sound`, `synth_principal`, `narrowing` re-proved. `check_complete_nondegenerate`
now carries `inter_free` hypotheses on the synthesized/target types (connective
checking inherits the decider's fragment).

### PART B — flow NARROWING (truthiness occurrence typing): DEFERRED, with proof

Narrowing was ATTEMPTED and **deferred precisely** — it hits TWO genuine forks,
not budget/skill limits:

1. **Operational soundness fork (the occurrence-typing subtlety).** Progress /
   preservation are stated for CLOSED terms (`has_type [] e T`). A narrowing rule
   on `tif (tvar n) e1 e2` is only meaningful under a binder; when that binder
   substitutes (beta/let), the substitution lemma provides a value typed at the
   variable's DECLARED type `U`, **not** at the narrowed `U ∩ ¬falsy`. For a falsy
   value this is unsatisfiable — narrowing is sound only *conditioned on branch
   selection*, which happens AFTER substitution. This is proved concretely:
   `false : Bool` is NOT in `Bool ∩ ¬(nil∪bool)` (the narrowed type a naive
   context-narrowing substitution lemma would demand) — a checked refutation via
   `ssub_inter_tgt_r` + `ssub_sound` + the `VBool false` witness. Closing it needs
   the operational semantics restructured so narrowing is tied to value-conditioned
   branch steps (not pure context narrowing) — a substrate change, out of scope.
2. **Checker-payoff fork (the distributivity frontier).** The narrowed obligation
   `T ∩ ¬falsy <: T` has intersection on the LEFT — exactly OFF `decide_ssub`'s
   completeness fragment (the non-distributive cross above). So even a sound
   declarative narrowing could not be *algorithmically* verified completely by
   `check` without the emptiness/`gdecide` route.

The `ssub` substrate Part B needs (intersection GLB, complement-as-`dsub`-fact) is
**landed and sound**; the narrowing itself is the deferred increment.

### Assumption audit

`Print Assumptions` on `progress`, `preservation`, `ssub_sound`,
`decide_ssub_sound`, `decide_ssub_complete`, `synth_sound`, `check_sound` (31
audited results across the chain): **Closed under the global context** — no
axioms, no `Admitted`, no `Classical`. `subtype.v` unmodified; whole chain
compiles (`coqc subtype.v && coqc typing.v && coqc ssub.v && coqc check.v`).

## Increment 13 — SOUND FLOW NARROWING: truthiness occurrence typing (value-conditioned)

The actual flow-typing payoff, machine-checked: sound **truthiness occurrence
typing** — the `and`/`or`-nil class, the bug class that motivated the whole
proof effort. Modifies `proof/typing.v`, `proof/check.v`; **`proof/subtype.v`
AND `proof/ssub.v` unmodified**. Build order unchanged.

### The refined diagnosis — value-conditioned op-sem ALONE is not enough

Increment 12 deferred narrowing with the diagnosis "narrowing is sound only
CONDITIONED ON BRANCH SELECTION; needs value-conditioned branch steps." That is
**necessary but INCOMPLETE for de Bruijn SUBSTITUTION semantics**, and the gap is
the genuine finding of this increment. A `tif (tvar n) e1 e2` narrowing the FREE
context entry `n` (then-branch `n : U∩¬falsy`, else-branch `n : U∩falsy`) is still
unsound even with value-conditioned selection, because an enclosing `SLet`/`SBeta`
substitutes the bound value into **BOTH** branches *before* the conditional
selects. The DEAD branch then carries a now-contradicted narrowing assumption —
e.g. a truthy value pushed into the falsy-narrowed else-branch, which used `n`
falsy-ly — and becomes an **ill-typed residual**. Value-conditioning fixes the
SELECTED branch; it does nothing for the blindly-substituted dead one. (This is
why the prior increment's `subst_lemma`-based attempt could not close: the
substitution lemma supplies the value at one type for both branches.)

### The fix that closes — a BINDING narrowing-conditional `tifn`

`tm` gains `tifn c e1 e2` (distinct from the increment-11 `tif`, which stays the
Bool-condition / union-typing / non-narrowing form). The scrutinee is **bound
FRESH (de Bruijn 0)** in each branch at the narrowed type, and the value-
conditioned op-sem substitutes the scrutinee into **ONLY the selected branch**:

- `SIfnTrue : value v -> truthy_value v -> step (tifn v e1 e2) (subst 0 v e1)`
- `SIfnFalse: value v -> falsy_value v  -> step (tifn v e1 e2) (subst 0 v e2)`
- `SIfn1 : step c c' -> step (tifn c e1 e2) (tifn c' e1 e2)` (reduce scrutinee first)

`truthy_value`/`falsy_value` are the Lua partition on values (falsy = `nil` or
`false`; truthy = everything else), total on values (`value_truthy_or_falsy`).
The unselected branch is **discarded by the step — never substituted into** — so
no dead-branch residual ever exists. That is the structural fix the substitution
semantics needs.

### Typing rule + the bridging lemmas (the operational⇒type justification)

```
TIfn : has_type G c U ->
       has_type (truthy_type :: G) e1 T1 ->
       has_type (falsy_type :: G) e2 T2 ->
       has_type G (tifn c e1 e2) (BUnion T1 T2)
```

The scrutinee may have ANY type `U` (Lua truthiness — no Bool gate). Preservation
of `SIfnTrue` rests on the **bridging lemma** `truthy_narrows : has_type [] v U ->
value v -> truthy_value v -> has_type [] v truthy_type` (dually `falsy_narrows`):
the value's operational TRUTHINESS gives it the narrowed TYPE, so `subst_top`
retypes the selected branch. Proof shape (the load-bearing soundness move): case
on the value's CANONICAL FORM; each non-nil class subsumes into `truthy_type` by
an `ssub` **UNION INTRODUCTION** (`SsUnionInL/InR` + atom/arrow/record membership)
— **no negation rule, no `dsub`-in-typing**, entirely through the existing sound
`ssub` union rules.

`truthy_type` = positive union of every non-nil value class
(`ABool ∪ ANum ∪ AStr ∪ BRec[] ∪ (BBot→BTop)`), denoting exactly the non-nil
values (so it CONTAINS every truthy value). `falsy_type` = `nil ∪ bool`
(over-approx — see the substrate gap). **The value model has NO singleton-false
type** (`ABool` denotes both `true` and `false`), so the exact falsy set
`{nil, false}` is inexpressible as a `BTy`; the two expressible bounds are both
SOUND (truthy under-approximates the complement of falsy; falsy over-approximates
falsy), inexact only at the true/false split. Recorded as a substrate gap.

### Operational safety — progress + preservation re-proved (`Qed`)

`preservation`: the three `tifn` step cases. `SIfnTrue`/`SIfnFalse` use
`inv_ifn` + the bridging lemma + `subst_top` + union-injection subsumption;
`SIfn1` is the scrutinee congruence (preserves `U`). `progress`: the `TIfn` case
— if the scrutinee is a value, `value_truthy_or_falsy` selects a branch
(`SIfnTrue`/`SIfnFalse`); else it steps (`SIfn1`). No canonical-forms lemma needed
(any value is truthy or falsy). All inversion/weakening/substitution/closed-ness
lemmas thread the `tifn` (fresh-binder) case.

### `synth`/`check` for `tifn` + re-proved soundness

`synth (tifn c e1 e2)`: synthesize `c` at ANY type (no Bool gate), synthesize each
branch under its narrowed binder (`truthy_type :: G` / `falsy_type :: G`), return
`BUnion` of the branch types. No `decide_ssub` obligation is emitted — the binder
type IS the narrowed type, so the narrowing is discharged by `TIfn` directly (the
branch projects the narrowed var where it consumes it). `synth_sound`/`check_sound`
re-proved (`Qed`); `synth_principal` extended (branch principality under the
narrowed binders); the general `narrowing` lemma threads the `tifn` fresh-binder
case.

### THE PAYOFF — narrowing-required term types, un-narrowed term rejected (both `Qed`)

The consumer `g := λ(_:truthy_type). 0 : truthy_type → Int` accepts ANY non-nil
value. The narrowing-required term binds a maybe-nil scrutinee (`Int ∪ Nil`) and,
in the then-branch, applies `g` to the (now-narrowed-truthy) scrutinee:

- **(a) WITH narrowing it TYPES** — `payoff_types_WITH_narrowing`: in the
  then-branch the bound var has `truthy_type`, so `g (var)` is well-typed; the
  whole `tifn` types at `Int ∪ Int`. Operationally it steps (`payoff_steps_then`).
- **(b) WITHOUT narrowing the SAME use is REJECTED** —
  `payoff_rejected_WITHOUT_narrowing`: under a context where the scrutinee carries
  its declared maybe-nil type `Int ∪ Nil`, `g (var)` is ill-typed AT EVERY type,
  because `Int ∪ Nil` is NOT `ssub`-below `truthy_type` (nil is not truthy —
  refuted semantically at `VNil` through `ssub_sound`).

At the checker: `compute_ifn_payoff_synth` synthesizes the union, `…_sound` is
`has_type` via `check_sound`, `…_unnarrowed_None` shows the un-narrowed
application gives `synth = None`. This is the `and`/`or`-nil narrowing soundness
made machine-checked — the class of bug that started the effort.

### Scope — covered vs deferred

**Covered:** variable-condition truthiness narrowing (the `tifn` binding form),
both narrowing directions sound, the payoff. **Deferred (honest substrate gaps,
in TODO.md):** (1) full occurrence-typing precision `U ∩ truthy_type` (carry the
declared type into the branch) — needs an intersection-INTRODUCTION rule `TInter`
whose ARROW inversion is the hard core of intersection types (`(A1→B1)∩(A2→B2)`
is not `ssub`-below any single arrow); (2) an exact falsy partition (needs a
singleton-false type — a `subtype.v` change); (3) type-test narrowing
`type(x)=="number"`; (4) narrowing on non-variable paths (`x.f`, `x[i]`);
(5) distributive simplification `(T∪nil)∩¬nil <: T` — `dsub`-true, `ssub`-false
(the N5 non-distributive frontier; the `gdecide` emptiness route).

### Assumption audit

`Print Assumptions` on `progress`, `preservation`, `truthy_narrows`,
`falsy_narrows`, `payoff_types_WITH_narrowing`, `payoff_rejected_WITHOUT_narrowing`,
`synth_sound`, `check_sound`, `synth_principal`, `narrowing` (35 audited results
across the chain): **Closed under the global context** — no axioms, no
`Admitted`, no `Classical`, no `admit`. `subtype.v` AND `ssub.v` unmodified;
whole chain compiles (`coqc subtype.v && coqc typing.v && coqc ssub.v && coqc
check.v`).

## Increment 14 — GENERAL RECURSION (single fixpoint); soundness tolerates non-termination

The term core gains **general recursion** — necessary for real programs. A single
fixpoint former `tfix`, with the unfold operational rule. The key metatheory point:
**type soundness holds even with non-termination** — progress and preservation do
NOT require termination. A recursive unfold always *steps* (progress is immediate)
and *preserves the type* (the substitution lemma), with no well-foundedness
argument anywhere. Modifies `proof/typing.v` + `proof/check.v`; `proof/subtype.v`
and `proof/ssub.v` are **unmodified**. Build order unchanged.

- **Term + op-sem.** `tm` gains `tfix : BTy -> tm -> tm`. In `tfix T body`, de
  Bruijn index 0 of `body` is the RECURSIVE SELF-REFERENCE, of type `T`; the whole
  `tfix T body` has type `T`. The operational rule is the **unfold** (chosen for
  the cleanest progress/preservation — simplest and sound):
  `SFix : step (tfix T body) (subst 0 (tfix T body) body)` — substitute the
  fixpoint itself for its self-reference. It has NO premise: `tfix` is **never a
  value** and **never stuck**, so progress is trivial; `value` is unchanged (no
  `tfix` value form). `lift`/`subst`/`closed_at` thread it under one fresh binder
  (`S k` / `S j`), exactly like the other binders.
- **Typing (declarative).** `TFix : has_type (T :: G) body T -> has_type G (tfix T
  body) T` — the body, given the recursive binding `T` at de Bruijn 0, has type
  `T`. The annotation `T` is what makes the form synthesizable. Subsumption-
  transparent inversion `inv_fix : has_type G (tfix Tf body) T -> has_type (Tf ::
  G) body Tf /\ ssub Tf T` threads `TFix` through arbitrary `TSub` chains.
- **`progress` + `preservation` re-proved (`Qed`), threading `tfix`.**
  - **progress:** the `TFix` case is immediate — `right; eexists; apply SFix` — a
    fixpoint always steps. (The `value`-first `try` in the proof falls through since
    `tfix` has no `value` constructor.)
  - **preservation:** the `SFix` case unfolds `tfix T body ↦ subst 0 (tfix T body)
    body`. `inv_fix` gives `has_type (T::[]) body T` and `ssub T Tres`;
    `subst_top T [] body T (tfix T body)` substitutes the WHOLE fixpoint (typed `T`
    by `TFix` on the body) for the `:T` self-reference, preserving `T`; then `TSub`
    to `Tres`. **This is where divergence is "fine":** the substituted-in term is
    `tfix…` again (it will step again), but the type `T` is invariant, so
    preservation closes with NO termination argument.
  - Threaded through all inversion / weakening / closedness / substitution lemmas
    (`weakening`, `has_type_closed`, `closed_at`/`closed_at_lift`, `subst_lemma`)
    via the `tfix` case of `tm_rect_strong` / `has_type_mind` (both extended with a
    `tfix` case).
- **Checker (`synth`/`check`) + re-proved soundness.** `synth (tfix T body)` CHECKS
  `body` against the annotation `T` under the self-ref binder `T::G` (synthesize
  `body`, gate `decide_ssub Sb T`), returning `Some T`. `synth_sound` discharges it
  by `TFix` after a `TSub` from the synthesized `Sb` to `T`; `synth_principal`'s
  `tfix` case is immediate (the synthesized type IS the annotation, and `inv_fix`'s
  `ssub annotation T` is exactly the principality obligation). `narrowing` extended.
  `synth_sound`, `check_sound`, `synth_principal`, `narrowing` re-proved `Qed`.
- **Sanity (`Compute` + proofs).**
  - A **recursive function** types and reduces a step: `tfix (Int→Int) (λx:Int.x)`
    types at `Int→Int` (`rec_fn_typed`), `synth` gives the annotated type
    (`compute_fix_synth`), and it steps via `SFix` (`rec_fn_steps`,
    `rec_fn_preservation`).
  - A **DIVERGING** term is well-typed and ALWAYS steps (never stuck):
    `diverge := tfix Int (tvar 0)` — its body IS the self-reference, so it types at
    `Int` (`diverge_typed`) and unfolds to ITSELF (`diverge_steps : step diverge
    diverge`); `diverge_progress` (never stuck), `diverge_not_value`,
    `diverge_preservation` (the type `Int` is invariant under the looping unfold,
    forever). `synth` still synthesizes its annotation (`compute_fix_diverge_synth`).
    This is the machine-checked statement that **type soundness tolerates
    non-termination**.
  - `synth`/`check` accept a well-typed recursive term (`compute_fix_synth`,
    `compute_fix_checks`, `compute_fix_sound` via `check_sound`); an annotation/body
    mismatch is rejected (`compute_fix_badbody_None`).
- **HONEST SCOPE.** This is **general (single) recursion** via `tfix`. **Mutual
  recursion** and **recursive TYPES** (equirecursive μ — the coinductive-`V` fork)
  are DEFERRED (backlog). A Lua-faithful `local function f = …` (which IS recursion)
  is the **derivable** consumer of `tfix`.

`Print Assumptions` on `progress`, `preservation`, `synth_sound`, `check_sound`
(plus `rec_fn_typed`, `diverge_progress`, `diverge_preservation`): **Closed under
the global context** — no axioms, no `Admitted`, no `Classical`, no `admit`.
`subtype.v` AND `ssub.v` unmodified; whole chain compiles (`coqc subtype.v && coqc
typing.v && coqc ssub.v && coqc check.v`).

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
  construction, no `Fix`). **CORRECTED (audit fix):** the exported decision is
  the **three-valued** `gdecide : BTy -> BTy -> decision`
  (`DSub | DNotSub | DUnknown`), **UNCONDITIONALLY SOUND by construction** —
  `DSub ⇒ dsub` and `DNotSub ⇒ ¬dsub` for **all** types (`gdecide_DSub_sound`,
  `gdecide_DNotSub_sound`, no fragment hypothesis), `DUnknown` on deferred cases.
  This replaces the prior `bool` `gsub_empty`, which was fail-optimistic
  (`None`-deferred ⇒ "subtype") and could claim a false subtype — the latent
  trap an adversarial audit found (`a={h:Int}`, `b={f:Int}∪{g:Int}`). The
  three-valued finder distinguishes "proved no witness" (`NoWitness`) from
  "deferred" (`Deferred`); fuel exhaustion and the coupled-negated-record clause
  both yield `Deferred`. Fragment predicates `flat` (one level of records) +
  `dnf_ok` (≤1 negated record per record-clause) now characterize
  **completeness only** (`gdecide_complete`: no `DUnknown` on the fragment). The
  bool `gsub_empty`/`decide_empty` are retained as internal fragment workhorses.
  `Compute`/`reflexivity` non-vacuity: trap → `DUnknown`; width/depth/
  record-vs-atom/disjoint/atom cases definite + correct. Closed under the global
  context.
- **[next — close the emptiness deferrals, substrate-first]** in priority order,
  each an enabling substrate before its consumers:
  **(a)** **coupled negated records** — ≥2 negated records sharing keys in one
  conjunct (arising from unions of records on the right). Currently surfaced as
  `gdecide ... = DUnknown` (the `Deferred` clause), so no wrong answer is ever
  produced; closing it makes those cases definite. The principled fix is a
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
- **[done — increment 7: arrows (single→single, finite-graph)]** the first
  **behavioural** former, taken via the **extensional finite-graph** route
  (option (i) of the prior fork): `V` gains `VFun : list (V*V) -> V` (positive
  inductive — no coinduction / step-indexing), `BTy` gains `BArrow A B` with the
  semantic-subtyping denotation `∀(i,o)∈g, i∈A → o∈B`. `denote_dec` extended
  (general, total). **CONTRA/COVARIANCE** (`darrow_variance`) and **DISJOINTNESS**
  from atoms and records (`arrow_disjoint_atom`/`_rec`) proved for free from the
  denotation. Boolean laws confirmed still holding (generic over `denote`).
  **Decider stays UNCONDITIONALLY SOUND**: arrow literals (`LPosArrow`/`LNegArrow`)
  threaded through the DNF; a `has_arrow` guard DEFERS any arrow-involving clause
  (`Deferred`/`None`) — `gdecide` returns `DUnknown`, never a wrong `DSub`/
  `DNotSub`; the two unconditional soundness theorems are re-established for the
  extended `BTy`. `atomic`/`no_rec`/`flat`/`neg_atomic` exclude arrows;
  `cl_rf` strengthened to arrow-free. Non-vacuity: arrow types inhabited; correct
  non-subtypes `~dsub (Int→Int)(Int→Str)` and `~dsub (Int→Int)(Num→Int)` with
  explicit `VFun` witnesses. **Decomposition law `(A→B)∩(A→C) ≡ A→(B∩C)` CLOSES**
  (`darrow_inter_cod`) — finite-graph model validates it, no faithfulness fork.
  Closed under the global context. **DEFERRED:** multi-return / vararg; the
  arrow-aware *decision procedure* (arrow subtyping is currently `DUnknown`); the
  harder decomposition laws (`(A→C)∩(A'→C) <: (A∪A')→C`, arrow-emptiness).
- **[done — increment 8: typing layer]** minimal syntactic type soundness in a
  NEW file `proof/typing.v` (on unmodified `subtype.v`): de Bruijn term language
  (lit/var/lam/app/let/rec/proj), `has_type` judgment with **subsumption**, CBV
  substitution-based small-step semantics, and **progress + preservation both
  `Qed`** (canonical forms, weakening, substitution lemma, arrow + record
  inversion). FINDING: raw `dsub` subsumption makes preservation FALSE (the
  `A→Top` arrow collapse, `arrow_top_collapse` + `preservation_dsub_counterexample`);
  TSub therefore subsumes along a syntactic `ssub` proved sound vs `dsub`
  (`ssub_sound`) with built-in arrow-variance inversion — realizing the
  increment-3 "algorithmic relation, sound vs `dsub`" deferral for the
  arrow+record fragment. Guarded `dsub` arrow inversion proved with explicit
  inhabitation side-conditions. Non-vacuity (terms that step; ill-typed rejected)
  + `Print Assumptions` closed under the global context. DEFERRED: statements,
  mutation, multi-arg/return, recursion (μ), metatables, term-level
  union/neg/arrow intro, dup-key records, `ssub` completeness, the reality bridge.
- **[done — increment 9: `ssub` solidified]** a NEW file `proof/ssub.v` (on
  unmodified `subtype.v` + `typing.v`) makes the checker's subsumption relation
  `ssub` a solid runnable relation: **PREORDER** (`ssub_refl`/`ssub_trans` as
  named lemmas; arrow/record recomposition surfaced as `ssub_trans_arrow`/`_rec`);
  a **TOTAL, TERMINATING decision procedure** `decide_ssub : BTy -> BTy -> bool`,
  **sound + complete** (`decide_ssub_correct : decide_ssub a b = true <-> ssub a
  b`), terminating by construction (structural fuel recursion on `bsize a + bsize
  b`; no DNF/emptiness machinery — `ssub` is syntactic), **total over all `BTy`**
  (a definite bool, improving on `gdecide`'s `DUnknown`). Total-decidable fragment
  is EXACTLY what `ssub` relates: atoms/arrows/records + Top/Bot structurally,
  connectives COARSELY (reflexive/Top/Bot only — semantic Boolean connective-`ssub`
  DEFERRED to `dsub`/`gdecide`). **`dsub`/`ssub` GAP characterized:** two strict
  gap instances — the arrow/Top collapse `dsub (Rec→Int)(Int→Top)` (`dsub_ssub_gap`,
  the preservation-breaker `ssub` rejects) AND the atom-level `AFloat`≡`ANum`
  (`dsub_ssub_gap_atom` — dsub-equal, no `ssub` edge); COINCIDENCE on afloat-free
  atoms (`ssub_dsub_coincide_atom`) and the structural ⊆ direction generally
  (`decide_ssub_implies_dsub`). General `ssub`-completeness vs all
  operationally-sound subtypings is the DEEP open question, DEFERRED. Subtyping
  side WIRED into the typing layer (`subsumption_decidable`). `Compute` sanity
  (esp. `decide_ssub (Rec→Int)(Int→Top) = false`). Closed under the global context.
- **[done — increment 10: bidirectional algorithmic checker]** a NEW file
  `proof/check.v` (on unmodified `subtype.v` + `typing.v` + `ssub.v`) turns the
  declarative `has_type` into a RUNNABLE checker, proven SOUND. `synth`/`check`
  (infer + check-against) are executable, total, structural on `tm`; `check`
  switches to `synth` and discharges the lone subsumption obligation via the
  total `decide_ssub`. **SOUNDNESS** (`synth_sound`/`check_sound`, both `Qed`,
  `Print Assumptions` Closed) makes the runnable checker sound vs the proven
  declarative semantics. **COMPLETENESS** is the tractable **principality** half:
  `synth_principal` (`proj_free e -> has_type G e T -> synth G e = Some S ->
  ssub S T`) — synth's output is the LEAST declarative type — proved generally
  (incl. a generally-proved context **`narrowing`** lemma for the `let` case),
  `Print Assumptions` Closed. DEFERRED precisely (not faked): algorithmic
  adequacy (synth succeeds on every well-typed term — blocked by `BBot`/narrowing
  degenerate positions), `tproj` principality under `NoDup` records, and full
  connective subtyping in checking (inherits `ssub`'s structural-only limit).
  `Compute` sanity: well-typed ⇒ `Some`/right type, ill-typed ⇒ `None`.
- **[done — increment 11: conditionals + union types]** the gateway to flow
  typing, in `proof/typing.v` + `proof/ssub.v` + `proof/check.v` (on unmodified
  `subtype.v`). `tm` gains `tif` (op-sem: literal-selectors + condition
  congruence; lazy branches); declarative `TIf` types it at `BUnion T1 T2` (the
  JOIN). `ssub`/`decide_ssub` gain **UNION** rules (composable intro `SsUnionInL/InR`
  + elim `SsUnionE`), **sound vs `dsub`** (`ssub_sound` extended) and **decided**
  (union-left `&&` / union-right `||`; same `bsize a + bsize b` fuel measure,
  strictly decreasing). **`decide_ssub_correct` re-proven sound + complete + total.**
  KEY SOUNDNESS FINDING: explicit `SsTrans` + union intro lets a transitivity
  MIDDLE be a union, breaking naive derivation-induction inversion (the old
  `ssub_top_src` / `ssub_connective_super` shape lemmas become FALSE). Fixed by
  STRUCTURAL "above/below" predicates (`arrow_above`/`rec_above`/`atom_above`/
  `top_above`/`interneg_above`/`union_below`) proven CLOSED UNDER `ssub` by
  derivation induction — union-robust inversions (`ssub_arrow_inv`, `ssub_rec_inv`,
  `ssub_union_src_l/r`, `ssub_union_tgt_inv`). **`progress` + `preservation` still
  hold** (the `tif` cases subsume the selected branch into the union via the
  injection rules — operationally sound, no arrow-Top collapse). `synth`/`check`
  handle `tif` (synth ⇒ `BUnion` of branch synths); `synth_sound`/`check_sound`/
  `synth_principal` re-proven. Non-vacuity: `if true then 3 else "s"` synths
  `Int∪Str`, steps to `3`; `decide_ssub Int (Int∪Str)=true`, `(Int∪Int) Int=true`,
  `(Int∪Str) Num=false`. **DEFERRED: intersection, negation, flow NARROWING.**
  `Print Assumptions` closed under the global context; `subtype.v` unmodified.
- **[done — increment 13: truthiness flow narrowing (value-conditioned)]** sound
  occurrence typing for the `and`/`or`-nil class. See the Increment 13 section
  below. The refined diagnosis: value-conditioned op-sem ALONE is insufficient
  under de Bruijn substitution semantics — narrowing the free context entry of a
  `tif (tvar n)` is unsound because an enclosing substitution pushes the value
  into the DEAD branch (carrying a false assumption) before selection. The fix is
  a BINDING narrowing-conditional `tifn` whose value-conditioned step substitutes
  the scrutinee into ONLY the selected branch. Payoff typechecks with narrowing,
  rejected without — both `Qed`.
- **[then — full occurrence-typing precision + intersection/negation term forms]**
  carry the scrutinee's declared type INTO the narrowed branch (`U ∩ truthy_type`,
  not the bound alone) — needs an intersection-introduction rule `TInter` whose
  arrow inversion is the hard core of intersection-type systems; add a
  literal-false type for the exact falsy partition; type-test narrowing
  (`type(x)=="T"`) and narrowing on non-variable paths.
- **[then — arrow decision procedure + multi-return]** make arrow subtyping
  DEFINITE (lift the `has_arrow`-defer), and generalise to multi-arg / multi-
  return / vararg function types.
- **[then — equirecursive μ]** extend `BTy` with recursive types (`μ`) and
  coinductive/contractive denotation; re-establish the laws and the decision
  procedure under recursion.
- **[then — the lib/sem reality bridge]** connect the abstract `V`/`denote` to
  the executable semantics in `lib/sem` as the empirical reality-anchor — the
  one thing proof *cannot* establish: that the model matches real LuaJIT value
  behavior.
