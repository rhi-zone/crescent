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

## Increment 15 — TYPE-TEST FLOW NARROWING: the `type(x)=="T"` guard (value-conditioned)

The real Lua **`type(x) == "number"`** flow-typing idiom — POSITIVE tag narrowing —
made machine-checked sound. This extends the audited increment-13 `tifn`
binding-narrowing infrastructure with the **same value-conditioned fresh-binding
discipline** (the soundness crux), applied to runtime type-tag tests instead of
truthiness. Modifies `proof/typing.v` + `proof/check.v`; `proof/subtype.v` and
`proof/ssub.v` are **unmodified**. Build order unchanged.

- **Term + tags + op-sem.** A standalone enum `tag = {TgNum, TgStr, TgBool, TgNil,
  TgTable, TgFun}` (the six `type()` tags), with `tag_eq_dec`. `tm` gains
  `ttypetest : tag -> tm -> tm -> tm -> tm`. In `ttypetest g scrut e1 e2`, the
  scrutinee is **bound FRESH** (de Bruijn 0) in BOTH branches. `has_tag : tm -> tag
  -> Prop` reads a value's runtime kind off its head (number literal `LInt` ↦ TgNum
  — the 5.1 model: `type()` is `"number"` for all numbers; `tlam` ↦ TgFun; `trec` ↦
  TgTable; etc.); it is **total on values** (`value_has_some_tag`) with a **unique**
  tag (`has_tag_unique`), and `value_tag_or_not` gives the decidable partition
  progress selects on. The **value-conditioned** step reduces the scrutinee to a
  value, then selects by tag and substitutes into ONLY the selected branch:
  `STtTrue` (tag matches `g` ⇒ `subst 0 v e1`), `STtFalse` (some OTHER tag `g'≠g` ⇒
  `subst 0 v e2`), `STt1` (congruence). `lift`/`subst`/`closed_at` thread the
  branches under one fresh binder (`S k` / `S j`), exactly like `tifn`.
- **Typing (declarative).** `TTypeTest : has_type G c U -> has_type (tag_type g::G)
  e1 T1 -> has_type (U::G) e2 T2 -> has_type G (ttypetest g c e1 e2) (T1∪T2)` — the
  THEN-branch is typed under the **tag-narrowed** binder `tag_type g`; the
  ELSE-branch under the scrutinee's **own type `U`** (a sound OVER-approximation of
  the precise negative narrowing `U ∩ ¬tag_type g`, the deferred intersection/
  negation wall). `tag_type`: TgNum↦`ANum`, TgStr↦`AStr`, TgBool↦`ABool`,
  TgNil↦`ANil`, TgTable↦`BRec []` (the table top-type, every `VTable`),
  TgFun↦`BArrow BBot BTop` (the function top-type, every `VFun`). Result = union of
  branch types. Subsumption-transparent inversion `inv_typetest` threads `TTypeTest`
  through arbitrary `TSub` chains.
- **The bridging lemma (the crux, mirroring `truthy_narrows`).**
  `tag_narrows : has_type [] v U -> value v -> has_tag v g -> has_type [] v
  (tag_type g)` — a value whose runtime tag is `g` genuinely inhabits `tag_type g`.
  Proved by **canonical forms** (case on the value's form, then the tag; mismatched
  pairs excluded because `has_tag` is `False` there), each class subsuming into its
  tag's type by `ssub` atom-order / arrow-`BBot`/`BTop` / record-`SrNil` only — **no
  negation, no `dsub`-in-typing** (the load-bearing soundness move).
- **`progress` + `preservation` re-proved (`Qed`), threading `ttypetest`.**
  - **progress:** the `TTypeTest` case — if the scrutinee is a value, `value_tag_or_not`
    gives either its tag IS `g` (`STtTrue`) or it has some other tag (`STtFalse`);
    else it steps (`STt1`). Always steps or is selected — total because every value
    has a tag.
  - **preservation:** `STtTrue` substitutes a tag-`g` value into the THEN-branch
    (typed under `tag_type g`); `tag_narrows` retypes it via `subst_top`. `STtFalse`
    substitutes into the ELSE-branch (typed under `U`); the scrutinee value already
    HAS type `U` by inversion, so `subst_top` applies with **no narrowing needed**.
    The dead branch is discarded — never substituted — so no contradicted-tag
    residual arises (the same substitution-soundness argument as `tifn`).
  - Threaded through `weakening`, `has_type_closed`, `closed_at`/`closed_at_lift`,
    `subst_lemma`, `tm_rect_strong` / `has_type_mind` (all extended with a
    `ttypetest` case).
- **Checker (`synth`/`check`) + re-proved soundness/principality.** `synth
  (ttypetest g c e1 e2)` synthesizes `c` at `U`, the then-branch under `tag_type g`,
  the else-branch under `U`, returning `Some (U1∪U2)` — no `decide_ssub` obligation
  (the binder type IS the narrowed type). `synth_sound` discharges by `TTypeTest`
  directly; `synth_principal`'s case uses `narrowing_head` to retype the declarative
  else-branch under the SYNTHESIZED scrutinee type `Uc` (which is `≤` the declarative
  `U`) before invoking the else-branch IH, then `SsUnionE`+intro for the union.
  `narrowing` extended. `synth_sound`, `check_sound`, `synth_principal`, `narrowing`
  re-proved `Qed`.
- **THE PAYOFF (both proved).** A number-consumer `h : ANum→Int` applied to the
  then-narrowed scrutinee of declared type `Str∪Num` (the "maybe-number" shape):
  (a) `tt_payoff_types_WITH_narrowing` — the whole `type(x)=="number"` guard TYPES
  (the then-branch sees `var0 : ANum`); (b) `tt_payoff_rejected_WITHOUT_narrowing` —
  the SAME application under the un-narrowed `Str∪Num` is REJECTED at every type
  (`Str∪Num` is not `ssub ≤ ANum` — a string is not a number, refuted semantically at
  `VStr 0`). `Compute`-level: `compute_typetest_payoff_synth` synthesizes the union,
  `compute_typetest_payoff_unnarrowed_None` is `None`; `tt_select_then`/`tt_select_else`
  witness the value-conditioned tag selection.
- **HONEST SCOPE.** **POSITIVE (then-branch) tag narrowing** only. The ELSE-branch is
  OVER-approximated to `U` — sound but imprecise; **precise NEGATIVE narrowing**
  `U ∩ ¬tag_type g` needs an intersection/negation typing rule (the same wall as
  increment-13's `U ∩ truthy_type` — `(A1→B1)∩(A2→B2)` is not `ssub`-below any single
  arrow, so `inv_app` cannot invert it). **Narrowing on non-variable paths** (`x.f`,
  `x[i]`) and **combined truthiness + type-test** in one guard are DEFERRED. No
  soundness subtlety was hit beyond the documented over-approximation: the else-branch
  carries the scrutinee's genuine type, so `STtFalse` preservation needs no bridging
  lemma at all (unlike the then-branch).

`Print Assumptions` on `progress`, `preservation`, `tag_narrows`, `synth_sound`,
`check_sound`, `synth_principal`, `narrowing`, and both payoffs
(`tt_payoff_types_WITH_narrowing`, `tt_payoff_rejected_WITHOUT_narrowing`,
`compute_typetest_payoff_sound`): **Closed under the global context** — no axioms, no
`Admitted`, no `Classical`, no `admit`. `subtype.v` AND `ssub.v` unmodified; whole
chain compiles (`coqc subtype.v && coqc typing.v && coqc ssub.v && coqc check.v`).

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

## Increment 16 — THE IMPERATIVE LAYER: mutable references, store-based soundness

A NEW file `proof/imp.v` (builds on **unmodified** `proof/subtype.v` and
`proof/typing.v`; `proof/ssub.v` / `proof/check.v` also untouched) adds the
**mutation core** — mutable references with a STORE-BASED operational semantics
and STORE TYPING, the classic STLC-with-references metatheory (Software
Foundations "References") instantiated over crescent's atom order + the
contravariant/covariant arrow rule that motivated `ssub`. Build order:
`subtype.v → typing.v → ssub.v → check.v → imp.v`.

- **WHY A NEW TYPE SYNTAX `RTy` (not threading Σ into typing.v).** References
  force a NEW type former `RRef T` — which `subtype.v`'s `BTy` does not have and
  which we may not add (`subtype.v` is unmodified) — and a STORE-TYPING parameter
  Σ on the typing relation. So the imperative layer gets its own `RTy` (atoms +
  `RArrow` + `RRef`, with `RTop`/`RBot`) and its own `rsub` (atom order; arrow
  CONTRA-domain / CO-codomain — the same rule `ssub` uses, the reason
  preservation survives subsumption; `RRef` **INVARIANT**, the standard sound
  reference rule). The structural `_above`-predicate inversion technique from
  `typing.v` is reused for `rsub` (`rsub_arrow_inv`, `rsub_ref_inv`, atom order,
  cross-kind non-subtypings).

- **Term language + values.** `rtm` = the references CORE (de Bruijn): lit / var /
  lam / app / let / if PLUS `ralloc e` (allocate, returns a fresh location),
  `rderef e` (read `!r`), `rassign r e` (write `r := v`), and `rloc n` (a store
  ADDRESS — a VALUE, never source syntax). Values: literals, lambdas, locations.

- **Store + CONFIGURATION op-sem.** `store := list rtm`; `rstep : rtm*store ->
  rtm*store -> Prop`. EVERY existing reduction/congruence threads the store
  UNCHANGED (beta, let, if, the CBV congruences). The three imperative reductions
  MUTATE it: `ralloc v / st ↦ rloc (length st) / st++[v]` (append),
  `rderef (rloc n) / st ↦ store_lookup n st / st` (read),
  `rassign (rloc n) v / st ↦ nil / store_update n v st` (in-place write).
  **Assignment yields the unit value `rlit LNil`** (Lua: an assignment has no
  useful value), typed at `runit = RAtom ANil` — the documented choice (returning
  the assigned value is a one-line change; unit is the stricter obligation).

- **Store typing + extension.** `Σ : list RTy`; `has_typeR Σ Γ e T` — the typing
  judgment threaded with Σ. `RTLoc : nth_error Σ n = Some T -> rloc n : RRef T`;
  alloc ⇒ `RRef T`; deref `RRef T ⇒ T`; assign `RRef T, T ⇒ unit`. Every existing
  rule threads Σ unchanged. `store_well_typed Σ st` (equal length; each stored
  value typed at its Σ-type in the empty context). `extends Σ' Σ` = Σ a PREFIX of
  Σ' (Σ' = Σ ++ ext) — the monotone growth of allocation; `extends_nth_error`
  keeps earlier locations valid.

- **The two soundness theorems, BOTH `Qed` WITH the store.**
  - `progress : has_typeR Σ [] e T -> store_well_typed Σ st -> rvalue e \/ exists
    e' st', rstep (e,st) (e',st')`. By induction on the derivation; the store
    hypothesis fires the deref/assign location cases (a well-typed location is in
    range), alloc-of-a-value always steps.
  - `preservation : has_typeR Σ [] e T -> store_well_typed Σ st -> rstep (e,st)
    (e',st') -> exists Σ', extends Σ' Σ /\ has_typeR Σ' [] e' T /\
    store_well_typed Σ' st'`. By induction on the STEP. The substantive cases:
    **alloc EXTENDS Σ by `[T]`** (the new cell typed; old cells re-typed by
    STORE-WEAKENING + the append being a prefix); **deref** reads `store_lookup n
    st`, typed by the store-well-typedness invariant; **assign** keeps Σ fixed,
    updates the cell in place, and re-establishes `store_well_typed` (the new
    value has the cell's invariant content type; `store_lookup_update_eq` /
    `_neq` localize the change). Congruence cases recurse, threading the
    (possibly extended) Σ' and STORE-WEAKENING the unchanged surroundings.
  Supporting metatheory all `Qed`: subsumption-transparent inversion lemmas for
  every form (incl. loc/alloc/deref/assign), variable weakening, closedness +
  lift-invariance of closed terms, **store-weakening** (`rstore_weakening` —
  typing stable under Σ-extension), the **substitution lemma** adapted to Σ, the
  store-update/lookup lemmas, and canonical forms (arrow⇒lambda, ref⇒location,
  Bool⇒boolean literal).

- **Checker (Σ-threaded), proven SOUND.** Locations never appear in SOURCE, so
  `synthR` runs over source with Σ implicit (no `rloc` case — a source `rloc` is
  rejected). The ref operations: alloc synth ⇒ `RRef` of the operand's type;
  deref ⇒ unwrap `RRef`; assign ⇒ synth the cell to `RRef U`, gate the value
  `≤ U` (the invariant content type) by the total `decide_rsub`, result `runit`.
  `decide_rsub` (atoms by the two declared edges; arrows contra/co via a
  structural FUEL = size, since the contravariant domain swap is not structural on
  either argument; refs by `RTy` equality — invariance) is proved SOUND
  (`decide_rsub_sound`). `synthR_sound` / `checkR_sound` both `Qed`.

- **Sanity (all proved).** (a) allocate an Int ref and dereference it — TYPES
  (`ex_alloc_deref_typed`) and STEPS (`ex_alloc_step` then `ex_deref_step`, reading
  back `7`). (b) **the store actually MUTATES**: `ex_assign_mutates_store` (the
  assign step changes the store), `ex_after_assign_lookup` (the updated cell holds
  `9`), `ex_deref_after_assign` (a deref of the updated store reads `9`, NOT the
  old `7`). (c) a ref-of-int genuinely typed as `RRef AInt`
  (`ex_ref_int_is_ref_int`; the checker agrees, `ex_check_ref_int`). (d) an
  ILL-TYPED assign — a STRING into a `RRef AInt` — is REJECTED at EVERY type
  (`ex_bad_assign_untyped`, refuted via `AStr` not `<: AInt`); the checker rejects
  the source-variable form (`ex_bad_assign_var_check_None`) while the good
  int-into-ref-int CHECKS (`ex_good_assign_var_check`). Plus `progress` /
  `preservation` instantiated on the store (`ex_progress_alloc`,
  `ex_preservation_assign`).

- **`Print Assumptions` on `progress`, `preservation`, `synthR_sound`,
  `checkR_sound`, `ex_assign_mutates_store`, `ex_bad_assign_untyped`,
  `ex_preservation_assign`: Closed under the global context** — no axioms, no
  `Admitted`, no `Classical`. `subtype.v` / `typing.v` / `ssub.v` / `check.v`
  unmodified; whole chain compiles.

- **HONEST SCOPE + DEFERRALS.** This is the references CORE: lit / var / lam / app
  / let / if + alloc / deref / assign. **RECORDS, flow-narrowing (`tifn` /
  type-test), and recursion (`tfix`) are NOT re-threaded through Σ here** — they
  are ORTHOGONAL to the store (they interact with it only via value-substitution
  and congruence, both already exercised by let / lam / app / if), so re-adding
  them is mechanical case multiplication, recorded as the next increment. The
  noteworthy CONSUMERS built on this ref core — Lua's **mutable TABLE FIELDS**
  (records whose fields are references) and **reassignable LOCALS** — are the next
  increment. Aliasing / strong-update precision is deferred. See `TODO.md`.

## Increment 17 — REFERENCE TYPE substrate: `BRef` + `BAnyRef` opaque leaves (split-step 1 of the reference unification)

The first step of unifying references into the type algebra. This increment adds
reference TYPES to the Boolean algebra in `proof/subtype.v` ONLY — so references
can later be unified into the typing layer (`typing.v`/`ssub.v`/`check.v`, the
DEFERRED split-step 2). It is additive — increments 1–7 untouched.

> Increment 16 (`imp.v`) is a SEPARATE, store-based mutation core over its own
> `RTy` ref type. This increment 17 is the reference type former in the SHARED
> Boolean-algebra `BTy` of `subtype.v` — the substrate the eventual unified
> reference subtyping will be built on, distinct from `imp.v`'s standalone `RTy`.

- **The diagnosis insight — TWO formers.** References need BOTH a specific
  `BRef T` (a reference whose content is typed `T`) AND an "any-reference"
  `BAnyRef` (all references, content-agnostic) — so a truthy location can be
  NARROWED to "is a reference" without committing to a content type. `BTy` gains
  both; `V` gains `VRef : nat -> V`, a bare location address (the `nat` is an
  identity tag; the value carries NO store, so a location's content type is NOT
  observable from the value — this is exactly why references are invariant).

- **Denotation — CONTENT-BLIND (the price of invariance).** `denote (BRef _) v`
  and `denote BAnyRef v` BOTH = `exists n, v = VRef n` (the set of ALL locations),
  content-independent. So denotationally `BRef T ≡ BAnyRef ≡ BRef U` for all T,U
  (`anyref_equiv_ref`, `ref_equiv_ref`). The syntactic distinction (invariance,
  any-ref widening) is **DEFERRED to `ssub`** in split-step 2 — fine, because
  `ssub ⊊ dsub` in the SAFE direction. `denote_dec` decides ref membership (is `v`
  a `VRef`?), constructive, `Defined`. `V_rect_strong` extended for `VRef`
  (a leaf, like `VStr`), axiom-free.

- **OPAQUE LEAVES — mirroring `BArrow` exactly.** For the decision machinery:
  literals `LPosRef`/`LNegRef`/`LPosAnyRef`/`LNegAnyRef` (emitted by
  `to_dnf`/`to_dnf_neg`); `to_dnf_pres` stays unconditional. A `has_ref` guard
  (beside `has_arrow`) makes the witness-finder **DEFER** on any clause carrying a
  ref literal — `clause_wit`/`clause_wit3` return `None`/`Deferred` BEFORE the
  scalar/record branches, so `gdecide` returns `DUnknown`, NEVER a wrong answer
  about refs (ref subtyping is decided syntactically by `ssub` later, not by
  `gdecide`). `BRef`/`BAnyRef` excluded from `atomic`/`flat`/`no_rec`/`neg_atomic`
  (sent to `False`), just as `BArrow` is; `cl_rf`/`dnf_no_ref` carry the
  arrow-freeness analog for references.

- **Every existing result PRESERVED.** All Boolean-algebra laws (distributivity
  both directions, De Morgan, complement, double-negation), the two UNCONDITIONAL
  soundness theorems `gdecide_DSub_sound`/`gdecide_DNotSub_sound`, `gdecide_complete`,
  `decide_empty`, `to_dnf_pres`, `denote_dec`, `V_rect_strong` — all still close
  `Qed` after the extension (parallel `BRef`/`BAnyRef`/`VRef` cases added wherever
  a `match` over `BTy`/`V`/literals was exhaustive). `gdecide` is still
  unconditionally sound over the extended `BTy` (refs ⇒ `DUnknown` ⇒ no claim);
  sanity `reflexivity`: `gdecide (BRef Int)(BRef Str) = DUnknown`,
  `gdecide BAnyRef (BRef Int) = DUnknown`, with `gd_ref_not_dsub_claim`.

- **Non-vacuity / sanity (all `Qed`).** `ref_int_inhabited` (`denote (BRef Int)
  (VRef 0)`), `anyref_inhabited`; `nonref_not_ref`/`nonref_not_anyref` (a non-ref
  value is in neither); `anyref_equiv_ref` / `ref_equiv_ref` (content-blindness
  made precise — all denote all-refs); `ref_disjoint_atom`/`_rec`/`_arrow` (a
  location is a distinct value-kind, disjoint from scalars/tables/functions by
  `discriminate`).

`Print Assumptions` on the Boolean-algebra laws (`ddistrib_inter_union`,
`dde_morgan_inter`), `gdecide_DSub_sound`/`_DNotSub_sound`/`_complete`,
`denote_dec`, `V_rect_strong`, and the new ref facts (`denote_ref_iff`,
`denote_anyref_iff`, `ref_int_inhabited`, `anyref_equiv_ref`, `ref_equiv_ref`,
`ref_disjoint_atom`/`_rec`/`_arrow`): **Closed under the global context** — no
axioms, no `Admitted`, no `Classical`. Whole dev compiles (`coqc subtype.v`).

- **WHOLE CHAIN re-verified (with care — the brief's "unaffected" premise was
  partly wrong).** `typing.v`/`ssub.v`/`check.v`/`imp.v` do NOT reference
  `BRef`/`BAnyRef`, but they SHARE `subtype.v`'s `V` and `BTy`, so adding the
  `VRef` value constructor and the two `BTy` constructors broke their exhaustive
  `destruct`/`match`. Those were extended with the (semantically inert) new
  branches: in `typing.v` three `destruct v` over `V` gain a `VRef` arm
  (`contradiction` — a location inhabits no atom/record); in `ssub.v`
  `bsize`/`inter_free` gain `BRef`/`BAnyRef` arms, `bty_eq_dec` gains the two
  constructors, and `decide_ssub`'s soundness+completeness gain ref cases —
  references are treated as **REFLEXIVE-ONLY LEAVES** for `ssub` (new substrate:
  `ref_above` + `ref_above_mono` + `ssub_ref_super`/`ssub_anyref_super` +
  `ref_above_to_ssub`, mirroring `atom_above`/`interneg_above`), i.e.
  invariant/non-widening for now; in `check.v` three `synth`-result `destruct` over
  `BTy` gain the two arms. **Real invariant + any-ref-widening ref subtyping is the
  DEFERRED split-step 2** (references unified into the typing layer with
  store-based mutation soundness). The reality bridge (`lib/sem/bridge/`) does NOT
  generate ref values (locations have no observable content type), so its non-ref
  differential tests still pass unchanged — no gating needed.

## Increment 18 — REFERENCE SUBTYPING: invariant `BRef` + any-ref widening (split-step 2 of the reference unification)

Split-step 2 upgrades reference handling from the reflexive-only leaves of
increment 17 to the **real** subtyping rules: INVARIANT `BRef`, ANY-REF
WIDENING, and the one-way ASYMMETRY. `proof/ssub.v` ONLY — `subtype.v`,
`typing.v`, `check.v`, `imp.v` are **byte-unmodified**; the whole chain
(`subtype → typing → ssub → check → imp`) recompiles clean.

- **Why a new relation `rsub`, not new `ssub` constructors.** The rules belong on
  `ssub`, but `ssub` is an inductive in `typing.v`, and the split-step constraint
  freezes `typing.v` (adding an `ssub` constructor is a substrate change to a
  lower layer, out of scope here). Framing the gap as substrate rather than
  hardcoding a result: the reference-aware extension is defined in `ssub.v` as a
  new inductive `rsub` that EMBEDS all of `ssub` (`RsSsub`) and ADDS exactly the
  two reference rules. Split-step 3 will promote these into `ssub`'s inductive and
  `rsub` collapses back into `ssub`.

- **The two rules (`rsub`).**
  `RsRefInv : rsub S T -> rsub T S -> rsub (BRef S) (BRef T)` — INVARIANT (a
  mutable cell is read AND written, so `BRef` is invariant, NOT covariant).
  `RsAnyRef : rsub (BRef U) BAnyRef` — a specific reference IS an any-reference
  (WIDENING). Plus `RsSsub` (embed `ssub`) and `RsTrans`. The ASYMMETRY — **no**
  `rsub BAnyRef (BRef U)` — is the point: an any-ref can't be deref'd/assigned at
  a specific content type, so widening a reference to `BAnyRef` is sound while the
  reverse is not.

- **PREORDER + SOUNDNESS vs `dsub`.** `rsub_refl`/`rsub_trans`.
  `rsub_sound : rsub a b -> dsub a b` — the reference rules collapse to
  EQUAL-denotation inclusions (`denote (BRef _) = denote BAnyRef = {VRef _}`,
  content-blind from increment 17). So `rsub ⊊ dsub` in the safe direction.

- **DECISION PROCEDURE `decide_rsub` (TOTAL + TERMINATING).** Intercepts the four
  reference pairs and delegates everything else to `decide_ssub`:
  `(BRef S, BRef T)` → `bty_eqb S T` short-circuit else
  `decide_rsub S T && decide_rsub T S` (invariant, BOTH directions);
  `(BRef _, BAnyRef)` → `true`; `(BAnyRef, BAnyRef)` → `true`;
  `(BAnyRef, BRef _)` → `false`; else → `decide_ssub`. **Termination:** the only
  recursion is the invariant case, onto strictly-smaller content
  (`bsize S < bsize (BRef S)`); bounded by the combined-`bsize` fuel.

- **SOUNDNESS (FULL) + COMPLETENESS (reference fragment).** `decide_rsub_sound`
  (full). Completeness for each reference pair: `decide_rsub_anyref_complete`,
  `decide_rsub_anyref_refl`, `decide_rsub_invariant_complete` (relative to
  `ssub`-witnessed content equivalence on the inter-free content fragment). The
  ASYMMETRY is decided (`decide_rsub_anyref_not_ref`) AND a sound non-subtyping
  (`rsub_anyref_not_ref : ~ rsub BAnyRef (BRef U)`, via the monotone-under-`rsub`
  inversion predicates `rsub_ref_above`/`rsub_anyref_above`, closed under
  `RsTrans` by `rsub_above_mono`). **Deferred frontier (honest, mirrors
  `decide_ssub_complete`'s own inter-free restriction):** a reference SOURCE into a
  UNION/INTERSECTION target whose disjuncts are content-equivalent-but-not-
  syntactically-equal references is decided SOUNDLY but not completely — the
  delegated `decide_ssub` cannot observe ref-invariance through a connective.
  Closing it needs `decide_rsub` to grow its own connective-target clauses
  (substrate, split-step 3).

- **`Compute`/proof SANITY (all `Qed`/`reflexivity`).**
  `decide_rsub (BRef Int)(BRef Int) = true`;
  `decide_rsub (BRef Int)(BRef Str) = false`;
  **`decide_rsub (BRef Int)(BRef Num) = false`** even though
  `decide_ssub Int Num = true` — invariance is NOT covariance, the soundness
  point (`sanity_ref_not_covariant`); `decide_rsub (BRef Int) BAnyRef = true`;
  `decide_rsub BAnyRef (BRef Int) = false`; `decide_rsub BAnyRef BAnyRef = true`;
  nested `BRef (BRef Int)` reflexive; `~ rsub BAnyRef (BRef Int)`.

- **Assumption audit — Closed under the global context.** `rsub_refl`,
  `rsub_trans`, `rsub_sound`, `decide_rsub_sound`,
  `decide_rsub_invariant_complete`, `decide_rsub_anyref_complete`,
  `decide_rsub_anyref_not_ref`, `rsub_anyref_not_ref`, `sanity_ref_not_covariant`,
  `sanity_anyref_not_ref` — all **Closed under the global context** (no axioms, no
  `Admitted`, no `Classical`).

- **NEXT (split-step 3, DEFERRED).** Thread store + references into the typing
  layer: promote `RsRefInv`/`RsAnyRef` into `ssub`'s inductive in `typing.v`
  (collapsing `rsub` back into `ssub`), give `decide_rsub` its own
  connective-target clauses to close the union/inter-of-refs completeness frontier,
  and add store-based mutation soundness (deref/assign typing, preservation over a
  typed store).

## Increment 19 — THE REFERENCES UNIFICATION (split-step 3): one store-aware typed language

Split-step 3 lands the unification the prior increments staged: the separate
imperative file `proof/imp.v` is **RETIRED** and its store + reference machinery
is threaded into the MAIN proof chain, so records, flow-narrowing
(`tifn`/`ttypetest`), recursion (`tfix`), references, and the store now coexist
in ONE language with ONE `has_type`. Commits `1e7f7fe5` (unify store + references
into the typing layer) + `01aae498` (retire `imp.v`; algorithmic checker over the
unified store language).

- **What unified.** `typing.v`'s term language gains `talloc`/`tderef`/`tassign`/
  `tloc` and a store-typing `Σ`-threaded `has_type Sig G e T`; `subtype.v`'s
  `BRef`/`BAnyRef` (increment 17) are the reference types; `ssub.v`'s `rsub`
  (increment 18) is the subsumption relation `TSub` now subsumes along; `check.v`'s
  `synth`/`check` are Σ-threaded over the unified language. The whole chain
  (`subtype → typing → ssub → check`) compiles with `imp.v` gone.

- **Preserved (`Qed`, Print Assumptions closed).** `progress` + `preservation`
  over the unified, store-threaded judgment; `synth_sound` / `check_sound` over the
  Σ-threaded checker. Store-weakening, the Σ-adapted substitution lemma, and the
  store invariant carry through.

- **The COST — algorithmic principality fenced (framed as substrate, NOT
  hardcoded).** Under the unified layer the declarative inversion lemmas conclude
  the reference-aware `rsub` (since `TSub` subsumes along `rsub`), and the
  union-typed term-formers (`tif`/`tifn`/`ttypetest`) need union-elimination at the
  `rsub` level — `rsub a c -> rsub b c -> rsub (BUnion a b) c` — to recompose
  branch principalities. `rsub` has NO such structural rule (it embeds `ssub`'s
  `SsUnionE` + the two reference rules + transitivity; a branch subtyping through
  ref-widening has no `ssub` witness to feed `SsUnionE`). So `rsub`-level
  principality needs a NEW SUBSTRATE rule (an `rsub` union-elim / join-completeness
  lemma); the reference-free fragment also needs an `rsub`→`ssub` collapse lemma to
  restore the prior principality cleanly. Both are DEFERRED together — recorded as
  a substrate need in `TODO.md`, never faked. The checker stays SOUND and
  EXECUTABLE on the whole unified language; only the principality META-property is
  fenced. See the framed-deferral comment at `proof/check.v:560-580`.

- **DEFERRED frontiers carried forward** (all in `TODO.md`): the `decide_rsub`
  reference-source-into-connective completeness gap (its own connective-target
  clauses); the named CONSUMERS of the ref core — Lua's mutable TABLE FIELDS and
  reassignable LOCALS, aliasing / strong-update precision; precise reference
  narrowing (truthy location → `BAnyRef` is sound-but-imprecise).

## Increment M4 — MUTABLE TABLES + REASSIGNABLE LOCALS, via the reference core (records-of-refs)

The named CONSUMERS of the unified store layer (deferred at increments 16/19):
Lua's mutable tables and reassignable locals. Modifies **only** `proof/typing.v`
(additive — new section M4 after the increment-19 examples); `subtype.v`,
`ssub.v`, `check.v` are **unmodified**, and `typing.v`'s core inductives (`tm`,
`has_type`, `step`, `ssub`/`rsub`) are **untouched** (`git diff`: 392 insertions,
0 deletions). Build order unchanged.

### Approach — PROVEN ENCODING, not first-class forms (and why)

The brief offered two routes; the **encoding** route is strictly cleaner here and
was taken. The reference + record machinery is already fully proved (increment 19
even ships ref-of-record examples), so Lua's mutation needs **no new core terms**:
it desugars into `talloc`/`tderef`/`tassign`/`trec`/`tproj`, and soundness is
**inherited** — `progress`/`preservation` (both still `Qed`, unmodified) already
cover those term-formers, so every encoded operation is automatically sound. There
was no awkwardness forcing first-class table-mutation terms, so adding them (and
re-proving their progress/preservation cases) would be pure redundancy. The cores
staying byte-for-byte unmodified is the evidence the encoding is faithful.

### The encoding (the key insight)

A Lua mutable table of type `{x:T, y:U}` is a **record of reference cells**
`BRec [("x", BRef T); ("y", BRef U)]`:

- the **field SET is FIXED** — the record STRUCTURE is immutable and
  width/depth-**covariant** (inherited from `BRec`, subtype.v);
- each **field is a mutable `BRef` cell** — so per-field mutation is **INVARIANT**,
  the sound rule, inherited from `BRef`'s invariance (`rsub` `RsRefInv`).

Operations desugar with no new term-formers:

| Lua surface | desugaring |
|---|---|
| mutable table literal `{x = e}` | `trec [("x", talloc e)]` (a ref per field) |
| field read `t.x` | `tderef (tproj t "x")` |
| field write `t.x := v` | `tassign (tproj t "x") v` |
| reassignable `local x = e` | `talloc e` (a ref cell) |
| local reassign `x := v` | `tassign x v` |

**Aliasing** — the defining Lua-table property — is **shared cells**: two bindings
to the SAME record value `trec [("x", tloc l)]` share store location `l`, so a
write through one is observed through the other (it is literally the same cell).

### What is proved (all `Qed`, all `Print Assumptions` Closed under the global context)

A small reflexive-transitive closure `multistep` (of `step` over configurations,
a plain inductive) sequences the read-after-write / aliasing reductions. Then the
five required examples:

1. **Mutation reads the NEW value.** `mutation_typed` / `mutation_steps`: build
   `{x=7}` (backed by a cell), `tlet (t.x := 9) (t.x)` types at `Int` and, from
   store `[7]`, **multi-steps to the literal `9`** in store `[9]` — the read
   observes the written value, not the old.
2. **Aliasing through shared cells.** `aliasing_typed` / `aliasing_steps`:
   `let a = <table> in let b = a in (a.x := 9); b.x` — `a` and `b` are the same
   closed table value (shared location 0); it types at `Int` and **multi-steps to
   `9`**, the mutation through `a` observed by the read through `b`.
3. **Field invariance (soundness).** `field_invariance_rejected`: writing a STRING
   into a `BRef Int` field is **rejected at EVERY type** — proved via the existing
   `rsub_ref_inv` (`BRef` invariance) composing the cell's true type `BRef Int`
   through the projection and refuting semantically at `VStr 0`.
   `field_invariance_accepted`: the well-typed `Int`-into-`Int` write IS accepted
   (yields `nil`). `field_cell_invariant`: `~ rsub (BRef Int) (BRef Num)` — a
   `BRef Int` field cannot be covariantly used as `BRef Num` even though
   `Int <: Num` at the value level.
4. **Covariant structure composes with invariant cells.**
   `covariant_width_over_cells`: `{x:BRef Int; y:BRef Str} <: {x:BRef Int}` (drop a
   field is supertyping on the immutable field set), the surviving `x` cell kept at
   the EXACT same invariant `BRef Int`. `covariant_structure_composes`: the
   two-cell table VALUE types at the one-field mutable-table type by subsumption.
   `covariant_field_still_invariant`: the projected `x` of the wider table is still
   an invariant `BRef Int` — covariant structure does NOT relax per-field invariance.
5. **Reassignable local.** `reassign_local_typed` / `reassign_local_steps`:
   `local x = 7; x := 9; x` (encoded `talloc`/`tassign`/`tderef`) types at `Int`
   and, from the empty store, **multi-steps to `9`** in store `[9]`.

### Honest scope / deferrals

Tables as records-of-refs, **FIXED string-keyed field set**. DEFERRED (backlog):
dynamic field add/remove, metatables, non-string keys, array part,
nil-assignment-deletes-key, and flow-sensitive **strong-update** precision on a
uniquely-owned cell.

`Print Assumptions` on `mutation_typed`/`mutation_steps`/`aliasing_typed`/
`aliasing_steps`/`field_invariance_rejected`/`field_invariance_accepted`/
`field_cell_invariant`/`covariant_structure_composes`/
`covariant_field_still_invariant`/`reassign_local_typed`/`reassign_local_steps`:
**Closed under the global context** — no axioms, no `Admitted`, no `Classical`.
Whole chain compiles (`coqc subtype.v && coqc typing.v && coqc ssub.v && coqc
check.v`); cores unmodified.

## Increment 20 — PRIMITIVE BINARY OPERATORS: arithmetic + comparison (real computation)

The first **computing** increment: the term core gains binary PRIMITIVE
operators so programs actually compute. Arithmetic `+ - * /` and comparison
`< <= ==`, **sound and 5.1-faithful at the type level**. Modifies
`proof/typing.v` + `proof/check.v`; `proof/subtype.v` and `proof/ssub.v` are
**byte-unmodified**. Build order unchanged.

- **Term language.** `tm` gains `tprim : primop -> tm -> tm -> tm` where
  `primop = PAdd | PSub | PMul | PDiv | PLt | PLe | PEq`. (DEFERRED, recorded in
  the backlog: concat, modulo, floor-div `//`, bitwise, metamethod-dispatch
  operators.) `tprim` is NOT a value — a fully-evaluated primop computes.
- **Typing (declarative).** Two rules. `TPrimArith` (op ∈ {`PAdd`,`PSub`,`PMul`,
  `PDiv`}): operands at `ANum`, result `ANum`. `TPrimCmp` (op ∈ {`PLt`,`PLe`,
  `PEq`}): operands at `ANum`, result the boolean type `BAtom ABool`. Operands are
  demanded at `ANum`; with subsumption (`TSub`) an `AInt` operand works since
  `AInt <: ANum`. **Precise Int-preserving result types (`Int+Int : AInt`) are
  DEFERRED** — the sound `ANum` result suffices. **`==` is numbers-only here**
  (general structural equality is DEFERRED). The two rules are gated by boolean
  classifiers `arith_op`/`cmp_op` (no name-keyed special-casing — the gate is
  ordinary data, and the two op-classes are provably disjoint, used in the
  preservation cross-cases).
- **Operational semantics.** Left-to-right operand congruence (`SPrim1` reduces
  the left operand; `SPrim2`, left a value, reduces the right), then COMPUTE. The
  term literal language has a single number literal `LInt nat` (integer-valued —
  the 5.1 number model has one number value per double), so number VALUES are
  `tlit (LInt n)`. **Arithmetic** on two number literals `tlit (LInt m)`,
  `tlit (LInt n)` yields `tlit (LInt (prim_arith op m n))` via NAT arithmetic
  (`PAdd ↦ m+n`, `PSub ↦ m-n`, `PMul ↦ m*n`) — so `3 + 4` reduces concretely to
  `7`. **`PDiv` uses `Nat.div`** (a representative integer-valued result): the
  term literal language has no fractional literal, the value model abstracts the
  exact double, and soundness needs only "the result is a number" — an
  integer-valued representative is sound (`AInt <: ANum`). **Comparison** on two
  number literals yields `tlit (LBool (prim_cmp op m n))` via the real nat
  comparison (`PLt ↦ Nat.ltb`, `PLe ↦ Nat.leb`, `PEq ↦ Nat.eqb`) — so `3 < 4`
  reduces concretely to `true`. A `tprim` on a NON-number operand is **STUCK** (a
  type error the checker prevents — progress only fires on well-typed terms).
- **Progress + preservation re-proved, both `Qed`.** Progress: a well-typed
  `tprim` has `ANum`-typed operands; by the new **canonical-forms lemma**
  `canon_num` (a closed value of type `BAtom ANum` is a number literal
  `tlit (LInt n)` — non-number literals refuted SEMANTICALLY via the value model,
  lambdas/records/locations via the not-atom shape facts), if both operands are
  values they are number literals and the operator COMPUTES (`SPrimArith` /
  `SPrimCmp`); otherwise an operand steps (`SPrim1` / `SPrim2`). Preservation: the
  arithmetic result `tlit (LInt _)` types at `AInt <: ANum` (then subsumed to the
  goal); the comparison result `tlit (LBool _)` types at `ABool`; the congruence
  cases recurse with store-weakening. `tprim` is threaded through every metatheory
  lemma — the strong term-induction principle (`tm_rect_strong`), `lift`/`subst`,
  `closed_at` + `closed_at_lift` + `has_type_closed`, `weakening`, `subst_lemma`,
  `store_weakening`, and the new subsumption-transparent inversion lemma
  `inv_prim` (concluding operands at `ANum` plus the arith/cmp result disjunction).
- **Bidirectional checker (`check.v`).** `synth (tprim op a b)` CHECKS both
  operands against `ANum` (via `decide_ssub` at the mode switch), returning `ANum`
  (arithmetic) or `ABool` (comparison). `synth_sound` / `check_sound` re-proved
  `Qed` (the new case discharges its two domain obligations by `decide_ssub_sound`
  + `TSub`, then `TPrimArith`/`TPrimCmp`); `narrowing` and `proj_free` threaded.
- **SANITY (`Compute` + proofs).** `3 + 4` types at `ANum` and steps to
  `tlit (LInt 7)` (`ex_add_typed`/`ex_add_steps`); `3 < 4` types at the boolean
  type and steps to `true` (`ex_lt_typed`/`ex_lt_steps`); the chain `(3 + 4) * 2`
  types at `ANum` and **multi-steps to `14`** (`ex_chain_steps`, exercising the
  operand congruence); `"s" + 1` is REJECTED at every type
  (`ex_bad_add_untyped` : `~ has_type …`) and `synth = None`
  (`compute_bad_add_None`). Checker sanity: `synth (3 + 4) = Some ANum`,
  `synth (3 < 4) = Some ABool`, both `check` + `check_sound`.

### Honest scope / deferrals

`+ - * /` and `< <= ==` on numbers. DEFERRED (backlog): **precise Int-preserving
result types** (`Int+Int : AInt` — needs the arithmetic rule to track the
integer-valued refinement through the operands; the sound `ANum` result is used
now); **concat / modulo / `//` / bitwise / metamethod-dispatch operators**;
**general structural `==`** (here equality is numbers-only). `PDiv` produces an
integer-valued representative (the term literal language has no fractional
literal); a faithful float result awaits a fractional number literal.

`Print Assumptions` on `progress`, `preservation`, `ex_add_typed`,
`ex_add_steps`, `ex_lt_typed`, `ex_lt_steps`, `ex_chain_steps`,
`ex_bad_add_untyped` (typing.v) and `synth_sound`, `check_sound`,
`compute_add_sound`, `compute_lt_sound`, `compute_bad_add_None` (check.v):
**Closed under the global context** — no axioms, no `Admitted`, no `Classical`.
Whole chain compiles (`coqc subtype.v && coqc typing.v && coqc ssub.v && coqc
check.v`); `subtype.v` + `ssub.v` byte-unmodified.

## Increment 21 — IMPERATIVE STATEMENT FORMS + a real while-loop (encoded; end-to-end imperative soundness)

Lua's imperative statement forms are shown to **encode soundly** into the existing
core with **NO new core terms** — soundness inherited from the already-proven
`progress` + `preservation` (increment 8, extended through the reference layer in
increment 16/19). All additions live in `proof/typing.v`; `subtype.v`, `ssub.v`,
`check.v` are **byte-unmodified** (only their `.vo`s recompile). The capstone is a
REAL imperative program — a `while`-loop that mutates a reference counter and
computes a running sum.

### The encodings (plain `Definition`s over existing constructors)

- **UNIT / "returns nothing".** A statement that produces no value yields the unit
  value `tlit LNil`; its type is `Tunit := BAtom ANil`.
- **SEQUENCING** `s1 ; s2` ⇒ `tseq s1 s2 := tlet s1 (lift 1 0 s2)`. Evaluate `s1`
  for its effect, bind-and-discard its value, run `s2`. Lifting `s2` past the
  discard-binder makes that binder UNUSED, so `s2`'s free de Bruijn variables keep
  their original meaning — sequencing is transparent to the surrounding scope. The
  cancellation lemma `subst_lift_cancel : forall e s k, subst k s (lift 1 k e) = e`
  (proved for ALL terms by the strong induction principle, record case included) is
  what makes `tseq a b` step to `b` once `a` is a value (`tseq_step_value`).
  Typing: `tseq_typed` (`a:Ta, b:Tb ⊢ tseq a b : Tb`, via `TLet` + front-weakening).
- **IF-STATEMENT** `if c then s1 else s2 end` ⇒ `tif c s1 s2` (already core,
  increment 11). Each branch is a statement; a do-nothing branch is `tlit LNil`.
- **BLOCK / local scope** ⇒ `tlet` nesting (already core).
- **WHILE** `while c do body end` ⇒
  `twhile c body := tfix Tunit (tif c (tseq body (tvar 0)) (tlit LNil))`. The
  fixpoint's self-reference is de Bruijn 0; one unfold (`twhile_unfold`, derived
  from `SFix`) re-evaluates `c` against the CURRENT store, and if `c` is true runs
  `body` (which MUTATES the store) then re-invokes the self-ref `tvar 0` — looping;
  when `c` becomes false the else-branch `tlit LNil` terminates with the unit
  value. Because `c`/`body` sit under the self-ref binder, the caller writes them
  with surrounding locals shifted up by one. Typing: `twhile_typed`
  (`c : Bool` and `body : Tunit` under `Tunit :: G` ⊢ `twhile c body : Tunit`; the
  `tif`'s declared `Tunit ∪ Tunit` is subsumed to `Tunit` via `SsUnionE`).

### The REAL imperative program that TYPES (the key correctness result)

`sumloop_prog n` encodes

```
local i = ref 0;
local s = ref 0;
while (!i < n) do  s := !s + !i;  i := !i + 1  end;
!s
```

with `talloc`/`tderef`/`tassign`/`tprim PLt`/`tprim PAdd` and the `twhile`
encoding. **`sumloop_prog_typed : forall n, has_type [] [] (sumloop_prog n) (BAtom
ANum)`** (`Qed`) — a real imperative Lua program typechecks. The loop body alone is
`sumloop_loop_typed` (`twhile … : Tunit`, store-typing-agnostic — the cells are
reached by de Bruijn `tvar`, never a `tloc` literal, so `S` is left universally
quantified and no `TLoc` is used).

**Number-typing note.** The cells are `BRef ANum`, not `BRef AInt`: arithmetic
(`tprim PAdd`) produces `ANum` (the declared `TPrimArith` result), and a mutable
`BRef` cell is INVARIANT, so storing `!s + !i : ANum` back requires a `Num` cell.
The initial `LInt 0 : AInt` widens to `ANum` at allocation by subsumption. This is
exactly Lua's single-number-type model.

### It steps correctly (concrete bound, reduced end-to-end)

For a minimal concrete instance — a single-cell counter loop `while (!i<1) do i:=
!i+1 end` with `i` at `tloc 0` starting at `0` — the reduction is machine-checked
END-TO-END through the store:

- `cinc_one_iter` : from store `[0]` the loop **unfolds**, the condition reads the
  CURRENT store (`0 < 1` = true), the body **mutates** the cell (`i ↦ 1`), and
  control returns to the loop — leaving store `[1]`. (The store-dependent condition
  gating a store-mutating body is the dynamic crux.)
- `cinc_terminates` : the SECOND unfold reads the NEW store `[1]`, the condition
  `1 < 1` is FALSE, and the loop terminates with `nil`.
- `cinc_loop_runs` (their composition) : from store `[0]` the loop runs to `nil` in
  store `[1]` — a real imperative loop computed to its end. `cinc_loop_typed`
  types it at `Tunit`.

The full SUM loop reduces by the SAME mechanism (alloc, unfold, store-read
condition, mutate, re-unfold, terminate, final read), only with more iterations and
a second cell; its TYPING is the proved `sumloop_prog_typed`. The single-cell
instance is reduced fully to keep the reduction trace honest about depth.

### Sequencing- and if-with-mutation

- **Sequencing with mutation** `(t.x := 9) ; t.x` reads `9` —
  `seq_mutation_typed` (at `AInt`) + `seq_mutation_steps` (store `[7]` → `9` in
  store `[9]`), the `;` form over the mutable-table encoding.
- **If-statement with mutation** `if cond then (r:=1) else (r:=2) end ; !r` reads
  the TAKEN branch's value — `if_mut_typed`, with `if_mut_true_steps` (→ `1`, store
  `[1]`) and `if_mut_false_steps` (→ `2`, store `[2]`).

### Divergence tolerance (soundness without termination)

`while true do () end` = `twhile (tlit (LBool true)) (tlit LNil)` is **well-typed**
at `Tunit` (`while_true_typed`) and **DIVERGES**: `while_true_diverges` shows one
full cycle returns the loop to ITSELF (same config), so it never reaches a value —
it steps forever; `while_true_not_stuck` shows it is not a value yet always steps.
Type soundness TOLERATES non-termination (inherited from `tfix`, increment 14): a
divergent loop is sound because it is never a stuck non-value. `while`'s
termination relies on the body mutating the state the condition reads; general
termination is neither provided nor needed for soundness.

### Honest scope / deferrals

The encoded statement forms are sequencing, if-statement, block, and while.
DEFERRED to the backlog: `break` / `return` / `goto` (non-local control flow —
needs labelled exits / continuations) and numeric `for` + generic `for-in`
(iterator protocols).

`Print Assumptions` on `subst_lift_cancel`, `tseq_typed`, `tseq_step_value`,
`twhile_unfold`, `twhile_typed`, `sumloop_prog_typed`, `sumloop_loop_typed`,
`cinc_one_iter`, `cinc_terminates`, `cinc_loop_runs`, `cinc_loop_typed`,
`seq_mutation_typed`, `seq_mutation_steps`, `if_mut_typed`, `if_mut_true_steps`,
`if_mut_false_steps`, `while_true_typed`, `while_true_diverges`,
`while_true_not_stuck`: **Closed under the global context** — no axioms, no
`Admitted`, no `Classical`. Whole chain compiles (`coqc subtype.v && coqc typing.v
&& coqc ssub.v && coqc check.v`); `subtype.v` + `ssub.v` + `check.v` byte-unmodified.

## Increment 21 — TYPE ANNOTATIONS / ASCRIPTION (`tannot`): guide inference; the op-sem-bridge synth-gap on the sum-loop closed

The general mechanism for guiding inference where `synth` is incomplete. A new
term-former `tannot : BTy -> tm -> tm` ascribes a term to a type; it directly
closes the bridge-surfaced gap where an annotated ref cell makes the sum-loop
synthesize.

### Term / typing / op-sem

- **Term** `tannot T e` — ascribe `e` to type `T`. NOT a value (it strips).
- **Typing** `TAnnot : has_type S G e T -> has_type S G (tannot T e) T`. With
  subsumption (`TSub`), an `e` at a SUBTYPE of `T` also ascribes (synthesize `e`'s
  least type, subsume to `T`, then ascribe) — this is what an up-ascription
  `(3 : Num)` relies on (`AInt <: ANum`).
- **Op-sem — RUNTIME ERASURE (value-strip choice).** `SAnnot1` congruence-reduces
  under the annotation; `SAnnotV : value v -> step (tannot T v, st) (v, st)` STRIPS
  it once the body is a value. The value-strip composes cleanly with CBV (an
  annotation never blocks reduction, never persists into a value), which is why
  this choice keeps progress + preservation clean: progress — `tannot T v` always
  steps (strip), `tannot T e` with reducible `e` steps by congruence; preservation
  — congruence preserves the annotation type, the strip yields `v : T` because the
  ascribed body was checked (`inv_annot`).

### synth / check — the point (annotation → CHECK mode)

`synth (tannot T e)` = synthesize `e`'s least type `Se`, gate `decide_rsub Se T`,
and on success return the ANNOTATION `T` (not `Se`). The annotation DRIVES the
checker into CHECK mode — `e` is checked against `T` rather than synthesized — and
downstream consumers see `T`, the type the programmer demanded. This is how an
annotation guides inference: a value whose synthesized type is too specific can be
ascended to the wider `T` a later use requires. `synth_sound` / `check_sound`
re-proved (the `tannot` case applies `TAnnot` after a `TSub` discharged by
`decide_rsub_sound`).

### progress + preservation re-proved

Both re-proved to `Qed` with the `tannot` cases (and `tannot` threaded through
`tm_rect_strong`, `has_type_mind`, `inv_annot`, `weakening`, `store_weakening`,
`has_type_closed` / `closed_at` / `closed_at_lift`, `subst_lemma`,
`subst_lift_cancel`, `narrowing`). Preservation: `tannot T e` steps to
`tannot T e'` (preserves `T`) or to `v` (which has type `T` since the annotation
was checked — `inv_annot` gives `e : Ta` with `rsub Ta T`).

### THE FIX — the op-sem-bridge-surfaced synth gap on a real imperative loop

The counting/sum loop (§ increment 20) allocates a counter + accumulator. WITHOUT
an annotation, `talloc (tlit (LInt 0))` synthesizes `BRef AInt` (an Int cell); the
body stores an arithmetic result `!s + !i : ANum` back, and a `BRef` cell is
INVARIANT — `ANum` is NOT storable into a `BRef AInt` — so **`synth` of the whole
un-annotated loop returns `None`** (`sumloop_unann_None`). This is exactly the
bridge-surfaced incompleteness: a sound program the synthesizer cannot infer,
because `talloc` commits the cell to the too-specific initialiser type. (Note: the
`has_type`-side `sumloop_prog_typed` of increment 20 already typed the loop, by
manually subsuming `LInt 0` to `ANum` at allocation — it is the SYNTHESIZER that
could not infer this without guidance.)

WITH the cells annotated — `talloc (tannot (BAtom ANum) (tlit (LInt 0)))` — the
cell synthesizes `BRef ANum` (the annotation ascends `LInt 0 : AInt` to `ANum`
before `talloc` reads its type), able to hold the arithmetic result. The whole loop
then synthesizes **`Some (BAtom ANum)`** (`sumloop_ann_synths`) and is sound
(`sumloop_ann_sound` via `check_sound`). The annotation GUIDED the inference — the
contrast (`None` un-annotated vs `Some ANum` annotated) closes the gap.

### Sanity

`(3 : Num)` synthesizes `Num` (`compute_annot_num`), is sound
(`compute_annot_sound`), and steps runtime-erased to `3` (`compute_annot_steps`). A
mis-ascription `(3 : Str)` is REJECTED by `synth` (= `None`,
`compute_annot_mismatch_None`) and is genuinely ill-typed
(`compute_annot_mismatch_untyped` : `~ has_type … (tannot AStr 3)` — `TAnnot` would
need `3 : AStr`, false since `AInt ⊄ AStr`).

### Honest scope / building block

Honest scope: type ascription via `tannot`. This is also the building block for
surface `local x : T = e` (ascribe the bound expression) and function param/return
type annotations (ascribe at the binder / the body). Those surface forms are not
themselves built here — only the ascription primitive they rest on.

`Print Assumptions` on `progress`, `preservation`, `synth_sound`, `check_sound`,
`sumloop_ann_synths` (+ `compute_annot_sound`, `compute_annot_mismatch_untyped`,
`sumloop_unann_None`, `sumloop_ann_sound`): **Closed under the global context** — no
axioms, no `Admitted`, no `Classical`. Whole chain compiles
(`coqc subtype.v && coqc typing.v && coqc ssub.v && coqc check.v`); `subtype.v` +
`ssub.v` byte-unmodified (only `typing.v` + `check.v` changed).

**Deferred (separate gap, unchanged):** `PDiv` float-faithfulness — `prim_arith`'s
`PDiv` uses `Nat.div` (a representative integer-valued result), not the exact Lua
double-division semantics; the value model abstracts the exact double, so soundness
needs only "the result is a number", but exact-`/`-faithfulness to real Lua remains
a deferred reality-bridge gap (NOT closed by this increment).

## Increment 22 — MULTI-RETURN VALUES: value-sequences + contextual adjustment (truncation + last-position spread)

Lua's distinctive feature: a function returns a **sequence** of values, **adjusted
by the syntactic context of the call**. The hard part is the contextual
ADJUSTMENT, not the multiple values. This increment lands the **return-side**
multivalue + the two core adjustments — **truncation** (most positions) and
**last-position spread** (known arity) — machine-checked, all `Qed`. Modifies
`proof/subtype.v` (the sequence-type substrate), `proof/typing.v` (term forms,
op-sem, progress/preservation), `proof/check.v` (synth/check). `proof/ssub.v` is
threaded (tuples are reflexive-only leaves). Build order unchanged.

### The multivalue MODEL (the standard model)

- **Sequence/tuple TYPE — a new `BTy` former in `subtype.v`.** `BTuple : list BTy
  -> BTy`. `BTuple [T1;…;Tk]` is the type of a finite **POSITIONAL, EXACT-LENGTH**
  value-sequence (NOT structural width/depth like records). Value domain gains
  `VTup : list V -> V` (positive occurrence, well-founded; the hand-rolled
  `V_rect_strong` extended with a third list-property `Pt`). `denote (BTuple Ts)
  (VTup vs)` = same length and pointwise `denote (Ts[i]) vs[i]` (structural
  lockstep fold; the `nth_error` reading recovered as `denote_tuple_iff`).
- **`BTuple` is an OPAQUE LEAF for the decision procedure**, exactly like `BArrow`
  / `BRef`: new `LPosTuple`/`LNegTuple` literals; a `has_tuple` clause guard sends
  any tuple-bearing clause to `DEFER` (`None` / `Deferred`); `atomic`/`no_rec`/
  `flat`/`neg_atomic`/`cl_rf` all send `BTuple` to `False`; `head`/`head_reps` gain
  the canonical `VTup []`. The two **unconditional soundness theorems**
  (`gdecide_DSub_sound`, `gdecide_DNotSub_sound`) and `gdecide_complete` are
  re-established for the extended `BTy` (tuple ⇒ `DUnknown` ⇒ no claim;
  `gd_tuple_defers`, `gd_tuple_not_dsub_claim`). The Boolean-algebra laws are
  untouched (proved generically over `denote`).
- **Tuple semantic facts (`Qed`):** `denote_tuple_iff` (positional membership),
  `dtuple_pointwise` (positional/covariant subtyping at equal length),
  `tuple_disjoint_{atom,rec,arrow,ref}` (a sequence is a distinct value-kind),
  `tuple_inhabited`, and **`tuple_length_matters`** (`~ dsub (BTuple [Int]) (BTuple
  [Int;Int])` — exact-length is a GENUINE, non-vacuous edge, not width).

### The ADJUSTMENT (the crux), in `typing.v`

Three term forms make the contextual adjustment explicit, so the SAME multivalue
is adjusted differently per position:

- **`tret es` — the RETURN-SEQUENCE** (`return e1,…,ek`). Evaluates components
  left-to-right (`SRet`); all-values ⇒ the multivalue VALUE `VRet`. Typed
  `BTuple Ts` via a mutual `has_types` judgment (pointwise) — `TRet`.
- **`tfst e` — TRUNCATION** (the "most positions" adjustment: `local x = f()`,
  operand position, non-last call arg). Binds the FIRST value. Typing `TFst`: a
  multivalue `: BTuple (T::Ts)` truncates to its head type `T`; the EMPTY tuple
  `BTuple []` truncates to `nil` (`TFstNil`). Op-sem `SFstCons` (head) / `SFstNil`
  (nil) — the extra returns are operationally discarded.
- **`tappspread g a` — LAST-POSITION SPREAD** (`g(f())`, `f()` last). The
  known-arity consumer `g : BTuple Ts -> B` receives the WHOLE sequence; the
  spread delivers `a : BTuple Ts`; result `B` (`TAppSpread`). Op-sem `SAppSpread`
  splices the whole multivalue into `g` (like `SBeta`).

### The soundness-subtlety surfaced and resolved (honest finding)

A multivalue is a VALUE, so it can reach a **truthiness flow-narrowing scrutinee**
(`tifn`). But `truthy_type` is the explicit union of the OTHER (non-tuple)
value-kinds — a multivalue inhabits NONE of them, so `truthy_narrows` is FALSE for
multivalues, and there is no "top-tuple" type to widen `truthy_type` with without
collapsing the narrowing payoff. **Faithful Lua resolution (taken):** a multivalue
in a boolean test is TRUNCATED first. So `truthy_value` is refined to EXCLUDE
multivalues (`is_multi` is a third classification; `value_truthy_or_falsy` is now a
3-way partition truthy/falsy/multi), and `SIfnMultiCons`/`SIfnMultiNil` truncate a
multivalue scrutinee BEFORE the test. `truthy_narrows`/`falsy_narrows` stay
multivalue-free, and preservation's new `SIfnMulti` cases close. (`ttypetest` needs
no such fix: `tag_type TgMulti = BTop`, every value subsumes to `BTop`, so
`tag_narrows` is sound for multivalues directly.)

### Metatheory re-proved (`Qed`)

`weakening`, `subst_lemma`, `has_type_closed`, `closed_at_lift`,
`subst_lift_cancel`, `store_weakening` all gain the third mutual motive (`P1` /
`Pt`) and the `tret`/`tfst`/`tappspread`/`has_types` cases. Canonical forms gain
`canon_tuple` (a tuple-typed value is a `tret`) and the `VRet` refutations
(`rsub_tuple_not_{atom,arrow,rec,ref,anyref}` + the reverse). **`progress` and
`preservation` re-proved** for every new step rule (`SRet`, `SFstCons`/`SFstNil`/
`SFst1`, `SAppSpread`/`_1`/`_2`, `SIfnMulti{Cons,Nil}`), all `Qed`. In `check.v`,
`synth` gains the three cases (with a `synth_seq` helper); **`synth_sound` /
`check_sound` re-proved** (third motive); `narrowing` likewise.

### THE PAYOFF (machine-checked contextual adjustment)

`f := λx:Int. return x, true  :  Int -> (Int, Bool)` — a real multi-return
function (result type `BTuple [AInt; ABool]`, a SEQUENCE, not a single value). The
call `f 3 : (Int, Bool)`. The SAME `f 3`:

- **TRUNCATION:** `tfst (f 3) : AInt` (`mr_truncate_typed`) — the FIRST value, NOT
  the tuple; steps `⤳* 3` (`mr_truncate_steps`), discarding the `Bool`.
- **SPREAD:** `g (f 3) : AInt` with `g : (Int,Bool) -> Int` (`mr_spread_typed`) —
  `g` receives BOTH values; steps `⤳* 0` (`mr_spread_steps`).
- The executable checker decides the same adjustment by `reflexivity`
  (check.v): `synth (f 3) = Some (Int,Bool)`, `synth (tfst (f 3)) = Some Int`
  (truncation), `synth (g (f 3)) = Some Int` (spread); routed to real typings by
  `synth_sound` (`mr_truncate_sound`, `mr_spread_sound`). `progress` fires on both
  (`mr_truncate_progress`, `mr_spread_progress`).

The distinctive Lua feature — same call truncated in one position, spread in
another — is machine-checked.

### Scope (honest) — DEFERRED

Return-side multivalue + truncation + last-position spread at **known arity** (the
consumer's tuple parameter pins the arity). DEFERRED (TODO.md backlog): the
function-side **vararg `...`**, **multiple-assignment `a,b = f()`**,
**table-collect `{f()}`**, **full arity-polymorphic spread** (a spread whose arity
is not fixed by the consumer), **semantic tuple subtyping** via `gdecide` and a
**top-tuple** type (tuple `ssub` is reflexive/pointwise only), and the
multivalue-as-flow-narrowing-scrutinee precision (currently truncated-first).

`Print Assumptions` on `progress`, `preservation`, `synth_sound`, `check_sound`,
the tuple substrate (`denote_tuple_iff`, `dtuple_pointwise`, `tuple_disjoint_*`,
`tuple_length_matters`), and the payoff (`mr_truncate_typed`, `mr_truncate_steps`,
`mr_spread_typed`, `mr_spread_steps`, `mr_*_synths_*`, `mr_*_sound`,
`mr_*_progress`): **Closed under the global context** — no axioms, no `Admitted`,
no `Classical`. Whole chain compiles (`coqc proof/subtype.v` → `typing.v` →
`ssub.v` → `check.v`).

## Increment 21 — METATABLES: static read-only `__index` field-lookup fallback (prototype inheritance / OOP)

The biggest missing real-Lua construct: tables whose missing-field accesses fall
back to a metatable's `__index`. Scoped to the MOST CENTRAL metamethod —
read-only `__index` as a TABLE/record (single or chained prototypes). Modifies
`proof/typing.v` and `proof/check.v`; `subtype.v` and `ssub.v` are **unmodified**
(NO new type-level former — the model lives entirely at the typing layer over the
existing `BRec`). Build order unchanged.

### The `__index` model — type-level representation + dispatch op-sem

- **Term former.** `tmeta : list (string * tm) -> tm -> tm`. `tmeta own proto` is a
  metatable-table: `own` is the OWN-field record-literal field-list, `proto` is the
  `__index` target (itself a record or another `tmeta` — a prototype CHAIN). The
  own fields are a literal field-list, NOT an arbitrary term (see the soundness
  fork below). Value: `VMeta` — a value once all own fields are values and `proto`
  is a value (parallel to `trec`/`VRec`).
- **Type-level representation — FLATTENING over existing records (no `subtype.v`
  change).** `merge_fields own proto = own ++ drop_shadowed own proto`: own fields
  kept, prototype fields whose key is NOT shadowed by an own key appended (Lua: own
  wins). `TMeta` types `tmeta own proto : BRec (merge_fields Town Pf)` where
  `own : Town` (exactly, via `has_fields`) and `proto : BRec Pf`. So the derived
  table's READ interface is exactly its own ∪ inherited fields — inheritance is a
  structural record extension; an inherited method is directly projectable at the
  derived table, at its prototype type. The merge has `NoDup` keys
  (`merge_fields_nodup`) so first-match projection agrees with the key's type.
- **Dispatch op-sem (the heart).** Field access `tproj (tmeta own proto) k` on a
  metatable-table VALUE resolves the key: `SMetaProjOwn` — `k` is a direct own
  field (`field_lookup k own = Some v`) ⇒ step to `v`; `SMetaProjProto` — `k` is
  absent from own (`= None`) ⇒ step to `tproj proto k`, which then resolves
  recursively through `proto`'s own `__index` chain. Congruence `SMeta1`/`SMeta2`
  build the table left-to-right (own fields, then prototype).

### The SOUNDNESS FORK — own must be a LITERAL field-list, not a subsumed term

Driving `TMeta` with `own : BRec Town` for an ARBITRARY (subsumable) term makes
**preservation FALSE**. Width-subsumption can let `Town` UNDER-report own's runtime
keys: own value `{k = 5}` (k:Int) subsumed to `BRec []`, prototype `{k = "s"}`
(k:Str). Then `tmeta own proto : BRec (merge [] [(k,Str)]) = {k:Str}`, so
`tproj … k : Str` — but the runtime dispatch finds `k` in own and returns the
Int `5`. A confident WRONG type. The principled resolution (not a hardcode): an
object's own field TABLE is concrete, so `TMeta` takes `own` as a record-literal
field-list typed EXACTLY by `has_fields S G own Town` — `Town` then faithfully
lists own's runtime keys, the merge resolves an own key to OWN's type and a
non-own key to the prototype's, and the dispatch matches typing. The prototype
keeps arbitrary subsumption (it is only read at `BRec Pf`). Recorded so the fork
is surfaced, not fudged.

### Metatheory re-proved

- **`progress` + `preservation` re-proved to `Qed`**, with the four new step rules.
  - `SMetaProjOwn`: `field_lookup k own = Some v` ⇒ `k` is an own key ⇒ the merge
    resolves `k` to OWN's type `Tk` (`merge_in_own`); the merge⊆fields inversion +
    `NoDup` (`nodup_unique_type`) forces the projected field type, and
    `field_lookup_typed` gives `v : Tk`. Sound.
  - `SMetaProjProto`: `field_lookup k own = None` ⇒ `key_in k Town = false` ⇒ the
    merge resolves `k` to the PROTOTYPE's type (`merge_in_proto`); `tproj proto k`
    types at that prototype field. Sound.
  - Progress dispatches via the extended canonical form `canon_rec`: a `BRec`-typed
    value is now `trec fs` OR `tmeta own proto`, and the metatable case always
    steps (own-or-prototype lookup).
  - Supporting lemmas all `Qed`: `inv_meta`, `merge_fields_nodup`,
    `merge_fields_key_in`, `merge_in_own`/`merge_in_proto`, `drop_shadowed_key`,
    `key_in_iff`; and the de Bruijn metatheory (`weakening`, `subst_lemma`,
    `closed_at`/`has_type_closed`/`closed_at_lift`/`subst_lift_cancel`,
    `store_weakening`) extended for the new `tmeta` term shape (own a field-list,
    so the `tm_rect_strong` `Pl` IH carries the per-own-field recursion).

### synth / check, re-proved sound

`synth (tmeta own proto)`: synthesize the own field-list (via `synth_fields`, with
a `keys_nodup` gate), synthesize the prototype (must be `BRec Pf`, NoDup keys),
return `BRec (merge_fields Town Pf)` — exactly the declarative `TMeta`.
**`synth_sound` / `check_sound` re-proved to `Qed`** (the `tmeta` case folds the
`Pl` field-IH; `NoDup Town` from the `keys_nodup` gate + `has_fields_keys`).
`narrowing` extended for the `tmeta` case. `proj_free` gets a `tmeta` arm.

### THE PAYOFF — prototype inheritance / OOP, machine-checked

A base object with a method `greet : nil -> string`; a derived object
`tmeta [(name, "…")] (trec [(greet, λ. "…")])` with own field `name` and
`__index = base`:
- **`oop_derived_typed`** — the derived object types at `BRec {name:Str, greet:nil→Str}`
  (own PLUS inherited).
- **`oop_inherited_typed`** — the INHERITED method `greet` is directly projectable
  on the derived object at its base type `nil → Str` (resolved through `__index`).
- **`oop_inherited_steps`** — the DISPATCH operationally: `tproj derived "greet"`
  `⤳ SMetaProjProto` (fall through to the prototype, `greet` not an own field)
  `⤳ SProj` (look up `greet` in the base) — reaching the base's method.
- **`oop_own_typed` / `oop_own_steps`** — an OWN field (`name`) resolves directly
  (`SMetaProjOwn`), no fallback.
- **`oop_absent_rejected`** — a field present in NEITHER own NOR prototype
  (`nonesuch`) is REJECTED at every type (the merge introduces no new keys —
  `merge_fields_key_in` — and own/prototype keys are exactly `{name}`/`{greet}`).
- Algorithmically (check.v): `oop_derived_synths`, `oop_inherited_synths` (synth
  computes the inherited method's base type), `oop_inherited_check_sound` (routed
  to a real declarative typing by `synth_sound`), `oop_absent_synth_None` (the
  checker rejects the absent field by `reflexivity`).

This is real Lua single-inheritance OOP, mechanized.

### Scope (honest) — DEFERRED (backlog)

Static, read-only `__index` field lookup (single or chained), `__index` as a
TABLE/record. DEFERRED: `__newindex` (write fallback), operator/comparison
metamethods (`__add`/`__eq`/`__lt`/…), `__call`, `__index` as a FUNCTION, dynamic
metatable MUTATION (`setmetatable`), and `rawget`/`rawset`.

`Print Assumptions` on `progress`, `preservation`, `synth_sound`, `check_sound`,
the OOP payoff (`oop_derived_typed`, `oop_inherited_typed`, `oop_inherited_steps`,
`oop_own_typed`, `oop_own_steps`, `oop_absent_rejected`) and the algorithmic
payoff (`oop_*_synths`, `oop_inherited_check_sound`, `oop_absent_synth_None`):
**Closed under the global context** — no axioms, no `Admitted`, no `Classical`.
Whole chain compiles (`coqc proof/subtype.v` → `typing.v` → `ssub.v` → `check.v`).
