(* imp.v — THE IMPERATIVE LAYER: mutable references, store-based soundness.

   The mutation core of crescent's term language: a STORE-BASED operational
   semantics (configurations [term × store]) with STORE TYPING (Σ), and the two
   soundness theorems PROGRESS + PRESERVATION re-proved WITH the store — the
   classic STLC-with-references metatheory (Software Foundations "References"),
   instantiated over crescent's subtyping atoms + the contravariant/covariant
   arrow rule that motivated [typing.v]'s [ssub].

   This file is ADDITIVE and builds on the UNMODIFIED [subtype.v] (it reuses the
   atom poset [Atom]/[atom_le] and the literal/tag vocabulary of [typing.v]). It
   does NOT modify [subtype.v], [typing.v], [ssub.v], or [check.v]. Build order:

     coqc proof/subtype.v
     coqc proof/typing.v
     coqc proof/ssub.v        (* part of the chain; not required by this file *)
     coqc proof/check.v       (* "" *)
     coqc proof/imp.v         (* THIS FILE *)

   WHY A NEW TYPE SYNTAX [RTy] (rather than threading Σ into [typing.v]).
   References force a NEW TYPE FORMER [RRef T] — which [subtype.v]'s [BTy] does
   NOT have and which we may not add ([subtype.v] is unmodified) — and a
   STORE-TYPING parameter Σ on the typing relation (so a location [rloc n] can be
   typed by [nth_error Σ n]). So the imperative layer gets its OWN type syntax
   [RTy] (atoms + arrow + ref) and its OWN subtyping [rsub] (atom order + arrow
   variance — the SAME contravariant-domain / covariant-codomain rule [ssub] uses,
   which is what makes preservation hold under subsumption — and INVARIANT [RRef],
   the standard sound reference rule). The whole core term language (lit / var /
   lam / app / let / if) is re-presented here Σ-threaded and store-based, so the
   classic features keep working WITH the store, alongside the new alloc / deref /
   assign.

   HONEST SCOPE. This layer is the references CORE: lit / var / lam / app / let /
   if + alloc / deref / assign. RECORDS / flow-narrowing (tifn / type-test) /
   recursion (tfix) are NOT re-threaded through Σ here — they are ORTHOGONAL to the
   store (they interact with it only via value-substitution and congruence, both
   already exercised by let / lam / app / if), so re-adding them is mechanical case
   multiplication, recorded as the next increment (TODO.md / proof-kernel.md).
   Mutable TABLE FIELDS (records whose fields are references) and reassignable
   LOCALS are the noteworthy CONSUMERS, built on this ref core — also deferred.

   ASSIGNMENT RESULT (documented choice). [rassign (rloc n) v] writes [v] and
   reduces to the unit value [rlit LNil] (Lua: an assignment yields no useful
   value; [nil] is the canonical "no value"), typed at [runit = RB ANil].
   Returning the assigned value instead is a one-line change; the unit form is the
   stricter obligation (result type fixed, not read off the cell).
*)

Require Import subtype.
Require Import typing.
From Stdlib Require Import List.
From Stdlib Require Import String.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
Import ListNotations.

(* ===========================================================================
   1. REFERENCE TYPES [RTy] — atoms (reusing [subtype.v]'s [Atom]) + arrow + ref.
   Top / Bot included so subsumption has join/meet endpoints exactly as [ssub].
   =========================================================================== *)

Inductive RTy : Type :=
  | RAtom  : Atom -> RTy
  | RTop   : RTy
  | RBot   : RTy
  | RArrow : RTy -> RTy -> RTy
  | RRef   : RTy -> RTy.

Definition runit : RTy := RAtom ANil.

(* the base type of a literal, as an [RTy] (reusing [typing.v]'s [lit_type]
   shape, but literals only ever produce atoms). *)
Definition rlit_type (l : lit) : RTy :=
  match l with
  | LInt _  => RAtom AInt
  | LStr _  => RAtom AStr
  | LBool _ => RAtom ABool
  | LNil    => RAtom ANil
  end.

(* the [RTy] a tag pins (then-branch narrowed type), mirroring [typing.v]'s
   [tag_type]; the function tag pins the function top-type [Bot -> Top], the
   table tag is OUT OF SCOPE here (no records) and pins [RTop] (sound: every
   value is in Top — narrowing to Top is the trivial sound bound). *)
Definition rtag_type (g : tag) : RTy :=
  match g with
  | TgNum   => RAtom ANum
  | TgStr   => RAtom AStr
  | TgBool  => RAtom ABool
  | TgNil   => RAtom ANil
  | TgTable => RTop
  | TgFun   => RArrow RBot RTop
  end.

(* ===========================================================================
   2. SUBTYPING [rsub] — atom order + arrow variance + INVARIANT ref.
   Explicit refl/trans (mirroring [ssub]) so the inversion lemmas thread chains.
   =========================================================================== *)

Inductive rsub : RTy -> RTy -> Prop :=
  | RsRefl  : forall T, rsub T T
  | RsTrans : forall A B C, rsub A B -> rsub B C -> rsub A C
  | RsTop   : forall T, rsub T RTop
  | RsBot   : forall T, rsub RBot T
  | RsAtom  : forall a b, atom_le a b -> rsub (RAtom a) (RAtom b)
  | RsArrow : forall A1 B1 A2 B2,
      rsub A2 A1 -> rsub B1 B2 -> rsub (RArrow A1 B1) (RArrow A2 B2)
  | RsRef   : forall T, rsub (RRef T) (RRef T).   (* INVARIANT *)

(* ---- structural "above" predicates for union-free inversion (the typing.v
   technique, here trivial since there are no connectives — just refl/trans). *)

Definition atom_above_r (x : Atom) (T : RTy) : Prop :=
  match T with
  | RTop    => True
  | RAtom y => atom_le x y \/ x = y
  | _       => False
  end.

Definition arrow_above_r (A1 B1 : RTy) (T : RTy) : Prop :=
  match T with
  | RTop         => True
  | RArrow A2 B2 => rsub A2 A1 /\ rsub B1 B2
  | _            => False
  end.

Definition ref_above_r (S : RTy) (T : RTy) : Prop :=
  match T with
  | RTop    => True
  | RRef S' => S = S'
  | _       => False
  end.

Lemma atom_above_r_mono : forall M C, rsub M C ->
  forall x, atom_above_r x M -> atom_above_r x C.
Proof.
  intros M C H. induction H; intros x0 Hab; simpl in *; try exact I; try exact Hab; try contradiction.
  - apply IHrsub2. apply IHrsub1. exact Hab.
  - (* RsAtom a b, atom_le a b; Hab : atom_le x0 a \/ x0 = a; goal atom_le x0 b \/ x0=b *)
    match goal with [ Hle : atom_le ?a ?b |- _ ] =>
      destruct Hab as [Hx | Hx];
      [ (* atom_le x0 a chained with atom_le a b: every edge has a number atom on the
           right which is never a left endpoint, so this cannot chain — vacuous. *)
        inversion Hx; subst; inversion Hle
      | subst x0; left; exact Hle ] end.
Qed.

Lemma arrow_above_r_mono : forall M C, rsub M C ->
  forall A1 B1, arrow_above_r A1 B1 M -> arrow_above_r A1 B1 C.
Proof.
  intros M C H. induction H; intros Ax Bx Hab; simpl in *; try exact I; try exact Hab; try contradiction.
  - apply IHrsub2. apply IHrsub1. exact Hab.
  - (* RsArrow: recompose contra/co via trans *)
    destruct Hab as [Hd Hc]. split.
    + eapply RsTrans; [ exact H | exact Hd ].
    + eapply RsTrans; [ exact Hc | exact H0 ].
Qed.

Lemma ref_above_r_mono : forall M C, rsub M C ->
  forall S, ref_above_r S M -> ref_above_r S C.
Proof.
  intros M C H. induction H; intros S0 Hab; simpl in *; try exact I; try exact Hab; try contradiction.
  - apply IHrsub2. apply IHrsub1. exact Hab.
Qed.

Lemma rsub_atom_super : forall x T, rsub (RAtom x) T -> atom_above_r x T.
Proof. intros x T H. apply (atom_above_r_mono (RAtom x) T H x). simpl. right; reflexivity. Qed.

Lemma rsub_arrow_super : forall A1 B1 T, rsub (RArrow A1 B1) T -> arrow_above_r A1 B1 T.
Proof. intros A1 B1 T H. apply (arrow_above_r_mono (RArrow A1 B1) T H A1 B1). simpl. split; apply RsRefl. Qed.

Lemma rsub_ref_super : forall S T, rsub (RRef S) T -> ref_above_r S T.
Proof. intros S T H. apply (ref_above_r_mono (RRef S) T H S). simpl. reflexivity. Qed.

(* the consumer inversions *)
Lemma rsub_arrow_inv : forall A1 B1 A2 B2,
  rsub (RArrow A1 B1) (RArrow A2 B2) -> rsub A2 A1 /\ rsub B1 B2.
Proof. intros A1 B1 A2 B2 H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.

Lemma rsub_ref_inv : forall S T, rsub (RRef S) (RRef T) -> S = T.
Proof. intros S T H. apply rsub_ref_super in H. simpl in H. exact H. Qed.

Lemma rsub_atom_atom : forall x y, rsub (RAtom x) (RAtom y) -> atom_le x y \/ x = y.
Proof. intros x y H. apply rsub_atom_super in H. simpl in H. exact H. Qed.

(* cross-kind non-subtypings (contradiction consumers, all structural). *)
Lemma rsub_atom_not_arrow : forall a A B, ~ rsub (RAtom a) (RArrow A B).
Proof. intros a A B H. apply rsub_atom_super in H. simpl in H. exact H. Qed.
Lemma rsub_atom_not_ref : forall a S, ~ rsub (RAtom a) (RRef S).
Proof. intros a S H. apply rsub_atom_super in H. simpl in H. exact H. Qed.
Lemma rsub_arrow_not_atom : forall A B a, ~ rsub (RArrow A B) (RAtom a).
Proof. intros A B a H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.
Lemma rsub_arrow_not_ref : forall A B S, ~ rsub (RArrow A B) (RRef S).
Proof. intros A B S H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.
Lemma rsub_ref_not_atom : forall S a, ~ rsub (RRef S) (RAtom a).
Proof. intros S a H. apply rsub_ref_super in H. simpl in H. exact H. Qed.
Lemma rsub_ref_not_arrow : forall S A B, ~ rsub (RRef S) (RArrow A B).
Proof. intros S A B H. apply rsub_ref_super in H. simpl in H. exact H. Qed.

(* ===========================================================================
   3. TERM LANGUAGE — de Bruijn, the references CORE (see HONEST SCOPE header).
   Reuses [typing.v]'s [lit] / [tag] vocabulary. [rloc n] is a VALUE (a store
   address), not source syntax.
   =========================================================================== *)

Inductive rtm : Type :=
  | rlit  : lit -> rtm
  | rvar  : nat -> rtm
  | rlam  : RTy -> rtm -> rtm
  | rapp  : rtm -> rtm -> rtm
  | rlet  : rtm -> rtm -> rtm
  | rif   : rtm -> rtm -> rtm -> rtm
  | ralloc  : rtm -> rtm                      (* allocate, returns a fresh loc   *)
  | rderef  : rtm -> rtm                      (* read  !r                        *)
  | rassign : rtm -> rtm -> rtm               (* write r := v  (yields unit/nil) *)
  | rloc    : nat -> rtm.                     (* a store address (a VALUE)       *)

(* hand-rolled nested induction (the [rrec] list of typing.v is gone here, but we
   keep the strong recursor with a [Pl] slot — set to [fun _ => True] at every use
   — so the proofs share one uniform induction shape). *)
Section rtm_ind_strong.
  Variable P  : rtm -> Prop.
  Hypothesis Hlit  : forall l, P (rlit l).
  Hypothesis Hvar  : forall n, P (rvar n).
  Hypothesis Hlam  : forall T b, P b -> P (rlam T b).
  Hypothesis Happ  : forall f a, P f -> P a -> P (rapp f a).
  Hypothesis Hlet  : forall e1 e2, P e1 -> P e2 -> P (rlet e1 e2).
  Hypothesis Hif   : forall c e1 e2, P c -> P e1 -> P e2 -> P (rif c e1 e2).
  Hypothesis Halloc : forall e, P e -> P (ralloc e).
  Hypothesis Hderef : forall e, P e -> P (rderef e).
  Hypothesis Hassign : forall r e, P r -> P e -> P (rassign r e).
  Hypothesis Hloc  : forall n, P (rloc n).
  Fixpoint rtm_rect_strong (e : rtm) : P e :=
    match e with
    | rlit l    => Hlit l
    | rvar n    => Hvar n
    | rlam T b  => Hlam T b (rtm_rect_strong b)
    | rapp f a  => Happ f a (rtm_rect_strong f) (rtm_rect_strong a)
    | rlet e1 e2 => Hlet e1 e2 (rtm_rect_strong e1) (rtm_rect_strong e2)
    | rif c e1 e2 => Hif c e1 e2 (rtm_rect_strong c) (rtm_rect_strong e1) (rtm_rect_strong e2)
    | ralloc e  => Halloc e (rtm_rect_strong e)
    | rderef e  => Hderef e (rtm_rect_strong e)
    | rassign r e => Hassign r e (rtm_rect_strong r) (rtm_rect_strong e)
    | rloc n    => Hloc n
    end.
End rtm_ind_strong.

(* ===========================================================================
   4. STORE TYPING + TYPING JUDGMENT — has_typeR Σ Γ e T.

   Σ : list RTy is the STORE TYPING (the type of the value at each location).
   Γ : list RTy is the de Bruijn variable context. The location rule reads Σ; the
   three reference rules introduce/eliminate [RRef]. Every OTHER rule threads Σ
   UNCHANGED (a fixed parameter from its perspective).
   =========================================================================== *)

Inductive has_typeR : list RTy -> list RTy -> rtm -> RTy -> Prop :=
  | RTLit  : forall S G l, has_typeR S G (rlit l) (rlit_type l)
  | RTVar  : forall S G n T, nth_error G n = Some T -> has_typeR S G (rvar n) T
  | RTLam  : forall S G T body Tb,
      has_typeR S (T :: G) body Tb ->
      has_typeR S G (rlam T body) (RArrow T Tb)
  | RTApp  : forall S G f a A B,
      has_typeR S G f (RArrow A B) ->
      has_typeR S G a A ->
      has_typeR S G (rapp f a) B
  | RTLet  : forall S G e1 e2 A B,
      has_typeR S G e1 A ->
      has_typeR S (A :: G) e2 B ->
      has_typeR S G (rlet e1 e2) B
  (* [rif]: branches must share a common type [T] (reached via [RTSub] on each
     branch — [RTy] has no union former, so the join is taken by subsumption). *)
  | RTIf   : forall S G c e1 e2 T,
      has_typeR S G c (RAtom ABool) ->
      has_typeR S G e1 T ->
      has_typeR S G e2 T ->
      has_typeR S G (rif c e1 e2) T
  | RTSub  : forall S G e A B,
      has_typeR S G e A -> rsub A B -> has_typeR S G e B
  (* --- the imperative layer ----------------------------------------------- *)
  | RTLoc   : forall S G n T,
      nth_error S n = Some T -> has_typeR S G (rloc n) (RRef T)
  | RTAlloc : forall S G e T,
      has_typeR S G e T -> has_typeR S G (ralloc e) (RRef T)
  | RTDeref : forall S G e T,
      has_typeR S G e (RRef T) -> has_typeR S G (rderef e) T
  | RTAssign : forall S G r e T,
      has_typeR S G r (RRef T) ->
      has_typeR S G e T ->
      has_typeR S G (rassign r e) runit.

(* ===========================================================================
   5. VALUES + de Bruijn lift / subst.  Values: literals, lambdas, locations.
   =========================================================================== *)

Inductive rvalue : rtm -> Prop :=
  | RVLit : forall l, rvalue (rlit l)
  | RVLam : forall T b, rvalue (rlam T b)
  | RVLoc : forall n, rvalue (rloc n).

Fixpoint rlift (d k : nat) (e : rtm) : rtm :=
  match e with
  | rlit l    => rlit l
  | rvar n    => if Nat.ltb n k then rvar n else rvar (n + d)
  | rlam T b  => rlam T (rlift d (S k) b)
  | rapp f a  => rapp (rlift d k f) (rlift d k a)
  | rlet e1 e2 => rlet (rlift d k e1) (rlift d (S k) e2)
  | rif c e1 e2 => rif (rlift d k c) (rlift d k e1) (rlift d k e2)
  | ralloc e  => ralloc (rlift d k e)
  | rderef e  => rderef (rlift d k e)
  | rassign r e => rassign (rlift d k r) (rlift d k e)
  | rloc n    => rloc n
  end.

Fixpoint rsubst (j : nat) (s : rtm) (e : rtm) : rtm :=
  match e with
  | rlit l    => rlit l
  | rvar n    =>
      match Nat.compare n j with
      | Lt => rvar n
      | Eq => s
      | Gt => rvar (Nat.pred n)
      end
  | rlam T b  => rlam T (rsubst (S j) (rlift 1 0 s) b)
  | rapp f a  => rapp (rsubst j s f) (rsubst j s a)
  | rlet e1 e2 => rlet (rsubst j s e1) (rsubst (S j) (rlift 1 0 s) e2)
  | rif c e1 e2 => rif (rsubst j s c) (rsubst j s e1) (rsubst j s e2)
  | ralloc e  => ralloc (rsubst j s e)
  | rderef e  => rderef (rsubst j s e)
  | rassign r e => rassign (rsubst j s r) (rsubst j s e)
  | rloc n    => rloc n
  end.

(* ===========================================================================
   6. STORE + CONFIGURATION OPERATIONAL SEMANTICS.

   store := list rtm (location n ↦ nth n store). A configuration is [(e, st)].
   ALL existing reductions/congruences thread the store UNCHANGED; the three
   reference rules MUTATE it: alloc appends, deref reads, assign updates.
   =========================================================================== *)

Definition store := list rtm.

(* update position [n] of a store to [v] (out-of-range: unchanged — never hit on
   well-typed configs, where [n < List.length st]). *)
Fixpoint store_update (n : nat) (v : rtm) (st : store) : store :=
  match st, n with
  | [], _ => []
  | _ :: rest, 0 => v :: rest
  | x :: rest, S n' => x :: store_update n' v rest
  end.

(* the location read; [rlit LNil] as the (never-reached on well-typed) default. *)
Definition store_lookup (n : nat) (st : store) : rtm := nth n st (rlit LNil).

Inductive rstep : rtm * store -> rtm * store -> Prop :=
  (* beta *)
  | RSBeta : forall T b v st,
      rvalue v -> rstep (rapp (rlam T b) v, st) (rsubst 0 v b, st)
  (* let *)
  | RSLet  : forall v e2 st,
      rvalue v -> rstep (rlet v e2, st) (rsubst 0 v e2, st)
  (* if *)
  | RSIfTrue  : forall e1 e2 st, rstep (rif (rlit (LBool true)) e1 e2, st) (e1, st)
  | RSIfFalse : forall e1 e2 st, rstep (rif (rlit (LBool false)) e1 e2, st) (e2, st)
  (* congruences (CBV, left-to-right) — store threaded through unchanged *)
  | RSApp1 : forall f f' a st st', rstep (f, st) (f', st') -> rstep (rapp f a, st) (rapp f' a, st')
  | RSApp2 : forall v a a' st st', rvalue v -> rstep (a, st) (a', st') -> rstep (rapp v a, st) (rapp v a', st')
  | RSLet1 : forall e1 e1' e2 st st', rstep (e1, st) (e1', st') -> rstep (rlet e1 e2, st) (rlet e1' e2, st')
  | RSIf1  : forall c c' e1 e2 st st', rstep (c, st) (c', st') -> rstep (rif c e1 e2, st) (rif c' e1 e2, st')
  (* --- the imperative reductions ------------------------------------------ *)
  (* alloc: a VALUE allocates a fresh cell at the end; returns its location *)
  | RSAlloc : forall v st, rvalue v ->
      rstep (ralloc v, st) (rloc (List.length st), app st [v])
  | RSAlloc1 : forall e e' st st', rstep (e, st) (e', st') -> rstep (ralloc e, st) (ralloc e', st')
  (* deref: read the cell at a location value *)
  | RSDeref : forall n st,
      rstep (rderef (rloc n), st) (store_lookup n st, st)
  | RSDeref1 : forall e e' st st', rstep (e, st) (e', st') -> rstep (rderef e, st) (rderef e', st')
  (* assign: write a VALUE to the cell at a location value; yields unit (nil) *)
  | RSAssign : forall n v st, rvalue v ->
      rstep (rassign (rloc n) v, st) (rlit LNil, store_update n v st)
  | RSAssign1 : forall r r' e st st', rstep (r, st) (r', st') -> rstep (rassign r e, st) (rassign r' e, st')
  | RSAssign2 : forall v e e' st st', rvalue v -> rstep (e, st) (e', st') ->
      rstep (rassign v e, st) (rassign v e', st').

(* ===========================================================================
   7. STORE WELL-TYPEDNESS + STORE EXTENSION.

   [store_well_typed Σ st]: same length, and each stored value has its Σ-type
   (closed — typed in the EMPTY context, since stored values are closed). Store
   EXTENSION [extends Σ' Σ]: Σ' is Σ with zero or more cells appended (a prefix
   relation), the standard monotone growth of allocation.
   =========================================================================== *)

Definition store_well_typed (S : list RTy) (st : store) : Prop :=
  List.length S = List.length st /\
  (forall n T, nth_error S n = Some T -> has_typeR S [] (store_lookup n st) T).

(* Σ' extends Σ iff Σ is a prefix of Σ' (Σ' = Σ ++ extra). *)
Definition extends (S' S : list RTy) : Prop := exists ext, S' = S ++ ext.

Lemma extends_refl : forall S, extends S S.
Proof. intro S. exists []. rewrite app_nil_r. reflexivity. Qed.

Lemma extends_trans : forall A B C, extends B A -> extends C B -> extends C A.
Proof.
  intros A B C [e1 H1] [e2 H2]. subst. exists (e1 ++ e2). rewrite app_assoc. reflexivity.
Qed.

Lemma extends_app1 : forall S T, extends (S ++ [T]) S.
Proof. intros S T. exists [T]. reflexivity. Qed.

(* nth_error is preserved by extension (a prefix keeps its earlier entries). *)
Lemma extends_nth_error : forall S' S n T,
  extends S' S -> nth_error S n = Some T -> nth_error S' n = Some T.
Proof.
  intros S' S n T [ext He] Hn. subst S'.
  rewrite nth_error_app1; [ exact Hn | apply nth_error_Some; rewrite Hn; discriminate ].
Qed.

(* ===========================================================================
   8. SUBSUMPTION-TRANSPARENT INVERSION LEMMAS.
   Each form's typing, threading any number of [RTSub] steps into one [rsub].
   =========================================================================== *)

Lemma rinv_lit : forall S G l T,
  has_typeR S G (rlit l) T -> rsub (rlit_type l) T.
Proof.
  intros S G l T H. remember (rlit l) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <-. apply RsRefl.
  - subst. eapply RsTrans; [ apply IHhas_typeR; reflexivity | exact H0 ].
Qed.

Lemma rinv_var : forall S G n T,
  has_typeR S G (rvar n) T -> exists U, nth_error G n = Some U /\ rsub U T.
Proof.
  intros S G n T H. remember (rvar n) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <-. exists T. split; [assumption | apply RsRefl].
  - subst. destruct (IHhas_typeR eq_refl) as [U [Hl Hd]].
    exists U. split; [assumption | eapply RsTrans; eassumption].
Qed.

Lemma rinv_lam : forall S G Tl b T,
  has_typeR S G (rlam Tl b) T ->
  exists Tb, has_typeR S (Tl :: G) b Tb /\ rsub (RArrow Tl Tb) T.
Proof.
  intros S G Tl b T H. remember (rlam Tl b) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists Tb. split; [assumption | apply RsRefl].
  - subst. destruct (IHhas_typeR eq_refl) as [Tb [Hb Hd]].
    exists Tb. split; [assumption | eapply RsTrans; eassumption].
Qed.

Lemma rinv_app : forall S G f a T,
  has_typeR S G (rapp f a) T ->
  exists A B, has_typeR S G f (RArrow A B) /\ has_typeR S G a A /\ rsub B T.
Proof.
  intros S G f a T H. remember (rapp f a) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists A, B. split; [assumption|split;[assumption|apply RsRefl]].
  - subst. destruct (IHhas_typeR eq_refl) as [A0 [B0 [Hf [Ha Hd]]]].
    exists A0, B0. split;[assumption|split;[assumption|eapply RsTrans; eassumption]].
Qed.

Lemma rinv_let : forall S G e1 e2 T,
  has_typeR S G (rlet e1 e2) T ->
  exists A B, has_typeR S G e1 A /\ has_typeR S (A :: G) e2 B /\ rsub B T.
Proof.
  intros S G e1 e2 T H. remember (rlet e1 e2) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists A, B. split;[assumption|split;[assumption|apply RsRefl]].
  - subst. destruct (IHhas_typeR eq_refl) as [A0 [B0 [H1 [H2 Hd]]]].
    exists A0, B0. split;[assumption|split;[assumption|eapply RsTrans; eassumption]].
Qed.

Lemma rinv_if : forall S G c e1 e2 T,
  has_typeR S G (rif c e1 e2) T ->
  exists U, has_typeR S G c (RAtom ABool) /\ has_typeR S G e1 U /\
            has_typeR S G e2 U /\ rsub U T.
Proof.
  intros S G c e1 e2 T H. remember (rif c e1 e2) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <- <-. exists T.
    split;[assumption|split;[assumption|split;[assumption|apply RsRefl]]].
  - subst. destruct (IHhas_typeR eq_refl) as [U [Hc [H1 [H2 Hd]]]].
    exists U. split;[assumption|split;[assumption|split;[assumption|eapply RsTrans; eassumption]]].
Qed.

Lemma rinv_loc : forall S G n T,
  has_typeR S G (rloc n) T -> exists U, nth_error S n = Some U /\ rsub (RRef U) T.
Proof.
  intros S G n T H. remember (rloc n) as e eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_typeR eq_refl) as [U [Hl Hd]].
    exists U. split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <-. exists T. split; [assumption | apply RsRefl].
Qed.

Lemma rinv_alloc : forall S G e T,
  has_typeR S G (ralloc e) T -> exists U, has_typeR S G e U /\ rsub (RRef U) T.
Proof.
  intros S G e T H. remember (ralloc e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_typeR eq_refl) as [U [He Hd]].
    exists U. split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <-. exists T. split; [assumption | apply RsRefl].
Qed.

Lemma rinv_deref : forall S G e T,
  has_typeR S G (rderef e) T -> exists U, has_typeR S G e (RRef U) /\ rsub U T.
Proof.
  intros S G e T H. remember (rderef e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_typeR eq_refl) as [U [He Hd]].
    exists U. split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <-. exists T. split; [assumption | apply RsRefl].
Qed.

Lemma rinv_assign : forall S G r e T,
  has_typeR S G (rassign r e) T ->
  exists U, has_typeR S G r (RRef U) /\ has_typeR S G e U /\ rsub runit T.
Proof.
  intros S G r e T H. remember (rassign r e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_typeR eq_refl) as [U [Hr [He Hd]]].
    exists U. split;[assumption|split;[assumption|eapply RsTrans; eassumption]].
  - injection Ee as <- <-. exists T. split;[assumption|split;[assumption|apply RsRefl]].
Qed.

(* ===========================================================================
   9. WEAKENING + STORE-WEAKENING + SUBSTITUTION.
   =========================================================================== *)

Lemma rnth_error_insert_lo : forall (G1 G2 : list RTy) U n,
  n < List.length G1 -> nth_error (G1 ++ U :: G2) n = nth_error (G1 ++ G2) n.
Proof.
  intros G1 G2 U n Hlt. rewrite nth_error_app1 by assumption.
  rewrite nth_error_app1 by assumption. reflexivity.
Qed.

Lemma rnth_error_insert_hi : forall (G1 G2 : list RTy) U n,
  List.length G1 <= n -> nth_error (G1 ++ U :: G2) (S n) = nth_error (G1 ++ G2) n.
Proof.
  intros G1 G2 U n Hge. rewrite nth_error_app2 by (simpl; lia).
  rewrite nth_error_app2 by assumption.
  replace (S n - List.length G1) with (S (n - List.length G1)) by lia. reflexivity.
Qed.

Lemma rnth_error_mid : forall (G1 G2 : list RTy) U,
  nth_error (G1 ++ U :: G2) (List.length G1) = Some U.
Proof.
  intros G1 G2 U. rewrite nth_error_app2 by lia.
  replace (List.length G1 - List.length G1) with 0 by lia. reflexivity.
Qed.

(* VARIABLE WEAKENING: insert a binder at the cut, lift free vars >= cut. *)
Lemma rweakening : forall S G e T,
  has_typeR S G e T ->
  forall G1 G2 U, G = G1 ++ G2 ->
    has_typeR S (G1 ++ U :: G2) (rlift 1 (List.length G1) e) T.
Proof.
  intros S G e T H.
  induction H; intros G1 G2 U0 EG; subst; simpl.
  - apply RTLit.
  - (* RTVar *)
    destruct (Nat.ltb_spec n (List.length G1)) as [Hlt | Hge].
    + apply RTVar. rewrite rnth_error_insert_lo by assumption. exact H.
    + replace (n + 1) with (Datatypes.S n) by lia. apply RTVar.
      rewrite rnth_error_insert_hi by assumption. exact H.
  - (* RTLam *) apply RTLam. exact (IHhas_typeR (T :: G1) G2 U0 eq_refl).
  - (* RTApp *) eapply RTApp; [ exact (IHhas_typeR1 G1 G2 U0 eq_refl) | exact (IHhas_typeR2 G1 G2 U0 eq_refl) ].
  - (* RTLet *) eapply RTLet;
      [ exact (IHhas_typeR1 G1 G2 U0 eq_refl) | exact (IHhas_typeR2 (A :: G1) G2 U0 eq_refl) ].
  - (* RTIf *) eapply RTIf;
      [ exact (IHhas_typeR1 G1 G2 U0 eq_refl)
      | exact (IHhas_typeR2 G1 G2 U0 eq_refl)
      | exact (IHhas_typeR3 G1 G2 U0 eq_refl) ].
  - (* RTSub *) eapply RTSub; [ exact (IHhas_typeR G1 G2 U0 eq_refl) | exact H0 ].
  - (* RTLoc *) apply RTLoc. exact H.
  - (* RTAlloc *) apply RTAlloc. exact (IHhas_typeR G1 G2 U0 eq_refl).
  - (* RTDeref *) eapply RTDeref. exact (IHhas_typeR G1 G2 U0 eq_refl).
  - (* RTAssign *) eapply RTAssign;
      [ exact (IHhas_typeR1 G1 G2 U0 eq_refl) | exact (IHhas_typeR2 G1 G2 U0 eq_refl) ].
Qed.

Corollary rweakening_cons : forall S G e T U,
  has_typeR S G e T -> has_typeR S (U :: G) (rlift 1 0 e) T.
Proof. intros S G e T U H. apply (rweakening S G e T H [] G U). reflexivity. Qed.

(* closedness: typing in [G] bounds free vars by [List.length G]. *)
Fixpoint rclosed_at (k : nat) (e : rtm) : Prop :=
  match e with
  | rlit _    => True
  | rvar n    => n < k
  | rlam _ b  => rclosed_at (S k) b
  | rapp f a  => rclosed_at k f /\ rclosed_at k a
  | rlet e1 e2 => rclosed_at k e1 /\ rclosed_at (S k) e2
  | rif c e1 e2 => rclosed_at k c /\ rclosed_at k e1 /\ rclosed_at k e2
  | ralloc e  => rclosed_at k e
  | rderef e  => rclosed_at k e
  | rassign r e => rclosed_at k r /\ rclosed_at k e
  | rloc _    => True
  end.

Lemma rhas_type_closed : forall e S G T, has_typeR S G e T -> rclosed_at (List.length G) e.
Proof.
  intro e. induction e using rtm_rect_strong;
    try exact I; intros Sg Gg Tg H; simpl; try exact I.
  - (* rvar *) apply rinv_var in H. destruct H as [U [Hl _]].
    apply nth_error_Some. rewrite Hl. discriminate.
  - (* rlam *) apply rinv_lam in H. destruct H as [Tb [Hb _]]. exact (IHe Sg (T :: Gg) Tb Hb).
  - (* rapp *) apply rinv_app in H. destruct H as [A [B [Hf [Ha _]]]].
    split; [ exact (IHe1 Sg Gg (RArrow A B) Hf) | exact (IHe2 Sg Gg A Ha) ].
  - (* rlet *) apply rinv_let in H. destruct H as [A [B [H1 [H2 _]]]].
    split; [ exact (IHe1 Sg Gg A H1) | exact (IHe2 Sg (A :: Gg) B H2) ].
  - (* rif *) apply rinv_if in H. destruct H as [U [Hc [H1 [H2 _]]]].
    split; [ exact (IHe1 Sg Gg (RAtom ABool) Hc)
           | split; [ exact (IHe2 Sg Gg U H1) | exact (IHe3 Sg Gg U H2) ] ].
  - (* ralloc *) apply rinv_alloc in H. destruct H as [U [He _]]. exact (IHe Sg Gg U He).
  - (* rderef *) apply rinv_deref in H. destruct H as [U [He _]]. exact (IHe Sg Gg (RRef U) He).
  - (* rassign *) apply rinv_assign in H. destruct H as [U [Hr [He _]]].
    split; [ exact (IHe1 Sg Gg (RRef U) Hr) | exact (IHe2 Sg Gg U He) ].
Qed.

Lemma rclosed_at_lift : forall e k, rclosed_at k e -> forall d j, k <= j -> rlift d j e = e.
Proof.
  intro e. induction e using rtm_rect_strong;
    try exact I; try (intros; reflexivity); intros k Hc d j Hkj; simpl in *.
  - (* rvar *) destruct (Nat.ltb_spec n j); [reflexivity | lia].
  - (* rlam *) f_equal. apply (IHe (S k)); [exact Hc | lia].
  - (* rapp *) destruct Hc as [H1 H2]. f_equal; [ apply (IHe1 k) | apply (IHe2 k) ]; (assumption || exact Hkj).
  - (* rlet *) destruct Hc as [H1 H2]. f_equal; [ apply (IHe1 k); [exact H1 | exact Hkj] | apply (IHe2 (S k)); [exact H2 | lia] ].
  - (* rif *) destruct Hc as [Hc1 [H1 H2]]. f_equal; [ apply (IHe1 k) | apply (IHe2 k) | apply (IHe3 k) ]; (assumption || exact Hkj).
  - (* ralloc *) f_equal. apply (IHe k); [exact Hc | exact Hkj].
  - (* rderef *) f_equal. apply (IHe k); [exact Hc | exact Hkj].
  - (* rassign *) destruct Hc as [H1 H2]. f_equal; [ apply (IHe1 k) | apply (IHe2 k) ]; (assumption || exact Hkj).
Qed.

Lemma rclosed_lift : forall e S T, has_typeR S [] e T -> forall d k, rlift d k e = e.
Proof.
  intros e S T H d k. apply (rclosed_at_lift e 0 (rhas_type_closed e S [] T H) d k). lia.
Qed.

(* a closed term types in ANY context. *)
Lemma rhas_type_closed_any : forall e S U, has_typeR S [] e U -> forall G, has_typeR S G e U.
Proof.
  intros e S U H G. induction G as [ | A G IH ].
  - exact H.
  - pose proof (rweakening_cons S G e U A IH) as Hw.
    rewrite (rclosed_lift e S U H 1 0) in Hw. exact Hw.
Qed.

(* STORE-WEAKENING: typing is stable under store-typing EXTENSION (the new cells
   never invalidate earlier location lookups; [extends_nth_error] does the work
   in the [RTLoc] case). By induction on the typing derivation. *)
Lemma rstore_weakening : forall S G e T,
  has_typeR S G e T -> forall S', extends S' S -> has_typeR S' G e T.
Proof.
  intros S G e T H. induction H; intros S' Hext.
  - apply RTLit.
  - apply RTVar; exact H.
  - apply RTLam; apply IHhas_typeR; exact Hext.
  - eapply RTApp; [ apply IHhas_typeR1; exact Hext | apply IHhas_typeR2; exact Hext ].
  - eapply RTLet; [ apply IHhas_typeR1; exact Hext | apply IHhas_typeR2; exact Hext ].
  - eapply RTIf; [ apply IHhas_typeR1; exact Hext | apply IHhas_typeR2; exact Hext | apply IHhas_typeR3; exact Hext ].
  - eapply RTSub; [ apply IHhas_typeR; exact Hext | exact H0 ].
  - apply RTLoc. eapply extends_nth_error; eassumption.
  - apply RTAlloc; apply IHhas_typeR; exact Hext.
  - eapply RTDeref; apply IHhas_typeR; exact Hext.
  - eapply RTAssign; [ apply IHhas_typeR1; exact Hext | apply IHhas_typeR2; exact Hext ].
Qed.

(* SUBSTITUTION LEMMA (closed substituend at cut [List.length G1]). *)
Lemma rsubst_lemma : forall e S G1 G2 U T s,
  has_typeR S (G1 ++ U :: G2) e T ->
  has_typeR S [] s U ->
  has_typeR S (G1 ++ G2) (rsubst (List.length G1) s e) T.
Proof.
  intro e. induction e using rtm_rect_strong;
    try exact I; intros Sg G1 G2 U0 Tr s H Hs.
  - (* rlit *) apply rinv_lit in H. simpl. eapply RTSub; [ apply RTLit | exact H ].
  - (* rvar *) apply rinv_var in H. destruct H as [U [Hl Hsub]]. simpl.
    destruct (Nat.compare_spec n (List.length G1)) as [Heq | Hlt | Hgt].
    + subst n. rewrite rnth_error_mid in Hl. injection Hl as <-.
      eapply RTSub; [ apply (rhas_type_closed_any s Sg U0 Hs) | exact Hsub ].
    + eapply RTSub; [ apply RTVar | exact Hsub ].
      rewrite rnth_error_insert_lo in Hl by assumption. exact Hl.
    + eapply RTSub; [ apply RTVar | exact Hsub ].
      destruct n as [ | n' ]; [ lia | ]. simpl Nat.pred.
      rewrite (rnth_error_insert_hi G1 G2 U0 n') in Hl by lia. exact Hl.
  - (* rlam *) apply rinv_lam in H. destruct H as [Tb [Hb Hsub]]. simpl.
    eapply RTSub; [ apply RTLam | exact Hsub ].
    rewrite (rclosed_lift s Sg U0 Hs 1 0).
    apply (IHe Sg (T :: G1) G2 U0 Tb s); [ exact Hb | exact Hs ].
  - (* rapp *) apply rinv_app in H. destruct H as [A [B [Hf [Ha Hsub]]]]. simpl.
    eapply RTSub; [ eapply RTApp | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U0 (RArrow A B) s); [ exact Hf | exact Hs ].
    + apply (IHe2 Sg G1 G2 U0 A s); [ exact Ha | exact Hs ].
  - (* rlet *) apply rinv_let in H. destruct H as [A [B [H1 [H2 Hsub]]]]. simpl.
    eapply RTSub; [ eapply RTLet | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U0 A s); [ exact H1 | exact Hs ].
    + rewrite (rclosed_lift s Sg U0 Hs 1 0).
      apply (IHe2 Sg (A :: G1) G2 U0 B s); [ exact H2 | exact Hs ].
  - (* rif *) apply rinv_if in H. destruct H as [V [Hc [H1 [H2 Hsub]]]]. simpl.
    eapply RTSub; [ eapply RTIf | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U0 (RAtom ABool) s); [ exact Hc | exact Hs ].
    + apply (IHe2 Sg G1 G2 U0 V s); [ exact H1 | exact Hs ].
    + apply (IHe3 Sg G1 G2 U0 V s); [ exact H2 | exact Hs ].
  - (* ralloc *) apply rinv_alloc in H. destruct H as [V [He Hsub]]. simpl.
    eapply RTSub; [ apply RTAlloc | exact Hsub ].
    apply (IHe Sg G1 G2 U0 V s); [ exact He | exact Hs ].
  - (* rderef *) apply rinv_deref in H. destruct H as [V [He Hsub]]. simpl.
    eapply RTSub; [ eapply RTDeref | exact Hsub ].
    apply (IHe Sg G1 G2 U0 (RRef V) s); [ exact He | exact Hs ].
  - (* rassign *) apply rinv_assign in H. destruct H as [V [Hr [He Hsub]]]. simpl.
    eapply RTSub; [ eapply RTAssign | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U0 (RRef V) s); [ exact Hr | exact Hs ].
    + apply (IHe2 Sg G1 G2 U0 V s); [ exact He | exact Hs ].
  - (* rloc *) apply rinv_loc in H. destruct H as [V [Hl Hsub]]. simpl.
    eapply RTSub; [ apply RTLoc; exact Hl | exact Hsub ].
Qed.

Corollary rsubst_top : forall S U G e T s,
  has_typeR S (U :: G) e T -> has_typeR S [] s U -> has_typeR S G (rsubst 0 s e) T.
Proof.
  intros S U G e T s He Hs. apply (rsubst_lemma e S [] G U T s); [ exact He | exact Hs ].
Qed.

(* ===========================================================================
   10. CANONICAL FORMS.  A closed value of arrow type is a lambda; of ref type a
   location; of Bool a boolean literal.
   =========================================================================== *)

Lemma rcanon_arrow : forall S e A B,
  has_typeR S [] e (RArrow A B) -> rvalue e -> exists T body, e = rlam T body.
Proof.
  intros S e A B Hty Hv. destruct Hv as [l | T b | n].
  - apply rinv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_arrow; eauto.
  - exists T, b; reflexivity.
  - apply rinv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_arrow; eauto.
Qed.

Lemma rcanon_ref : forall S e T,
  has_typeR S [] e (RRef T) -> rvalue e -> exists n, e = rloc n.
Proof.
  intros S e T Hty Hv. destruct Hv as [l | Tl b | n].
  - apply rinv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_ref; eauto.
  - apply rinv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_ref; eauto.
  - exists n; reflexivity.
Qed.

Lemma rcanon_bool : forall S e,
  has_typeR S [] e (RAtom ABool) -> rvalue e -> exists b, e = rlit (LBool b).
Proof.
  intros S e Hty Hv. destruct Hv as [l | T b | n].
  - apply rinv_lit in Hty. destruct l; simpl in Hty.
    + apply rsub_atom_atom in Hty. destruct Hty as [Hle | Heq]; [ inversion Hle | discriminate ].
    + apply rsub_atom_atom in Hty. destruct Hty as [Hle | Heq]; [ inversion Hle | discriminate ].
    + exists b; reflexivity.
    + apply rsub_atom_atom in Hty. destruct Hty as [Hle | Heq]; [ inversion Hle | discriminate ].
  - apply rinv_lam in Hty. destruct Hty as [Tb [_ Hsub]]. exfalso. eapply rsub_arrow_not_atom; eauto.
  - apply rinv_loc in Hty. destruct Hty as [U [_ Hsub]]. exfalso. eapply rsub_ref_not_atom; eauto.
Qed.

(* ===========================================================================
   11. PROGRESS (with the store).
     has_typeR Σ [] e T -> store_well_typed Σ st ->
       rvalue e \/ exists e' st', rstep (e,st) (e',st').
   By induction on the typing derivation. The store hypothesis is used in the
   [rderef]/[rassign] location cases (a well-typed location is in range, so the
   read / write step fires). [ralloc] of a value always steps (RSAlloc).
   =========================================================================== *)

Theorem progress : forall S e T,
  has_typeR S [] e T ->
  forall st, store_well_typed S st ->
    rvalue e \/ exists e' st', rstep (e, st) (e', st').
Proof.
  intros S e T H.
  remember (@nil RTy) as G eqn:EG.
  induction H; intros st Hwt; subst.
  - (* RTLit *) left; constructor.
  - (* RTVar: no closed var *) destruct n; simpl in H; discriminate H.
  - (* RTLam *) left; constructor.
  - (* RTApp *) right.
    destruct (IHhas_typeR1 eq_refl st Hwt) as [Hvf | [f' [st' Hf']]].
    + destruct (IHhas_typeR2 eq_refl st Hwt) as [Hva | [a' [st' Ha']]].
      * destruct (rcanon_arrow S f A B H Hvf) as [Tl [body Ef]]. subst f.
        exists (rsubst 0 a body), st. apply RSBeta. exact Hva.
      * exists (rapp f a'), st'. apply RSApp2; assumption.
    + exists (rapp f' a), st'. apply RSApp1; exact Hf'.
  - (* RTLet *) right.
    destruct (IHhas_typeR1 eq_refl st Hwt) as [Hv1 | [e1' [st' He1']]].
    + exists (rsubst 0 e1 e2), st. apply RSLet. exact Hv1.
    + exists (rlet e1' e2), st'. apply RSLet1. exact He1'.
  - (* RTIf *) right.
    destruct (IHhas_typeR1 eq_refl st Hwt) as [Hvc | [c' [st' Hc']]].
    + destruct (rcanon_bool S c H Hvc) as [bb Eb]. subst c. destruct bb.
      * exists e1, st. apply RSIfTrue.
      * exists e2, st. apply RSIfFalse.
    + exists (rif c' e1 e2), st'. apply RSIf1. exact Hc'.
  - (* RTSub *) apply IHhas_typeR; [ reflexivity | exact Hwt ].
  - (* RTLoc *) left; constructor.
  - (* RTAlloc *) right.
    destruct (IHhas_typeR eq_refl st Hwt) as [Hv | [e' [st' He']]].
    + exists (rloc (List.length st)), (app st [e]). apply RSAlloc. exact Hv.
    + exists (ralloc e'), st'. apply RSAlloc1. exact He'.
  - (* RTDeref *) right.
    destruct (IHhas_typeR eq_refl st Hwt) as [Hv | [e' [st' He']]].
    + destruct (rcanon_ref S e T H Hv) as [n En]. subst e.
      exists (store_lookup n st), st. apply RSDeref.
    + exists (rderef e'), st'. apply RSDeref1. exact He'.
  - (* RTAssign *) right.
    destruct (IHhas_typeR1 eq_refl st Hwt) as [Hvr | [r' [st' Hr']]].
    + destruct (IHhas_typeR2 eq_refl st Hwt) as [Hve | [e' [st' He']]].
      * destruct (rcanon_ref S r T H Hvr) as [n En]. subst r.
        exists (rlit LNil), (store_update n e st). apply RSAssign. exact Hve.
      * exists (rassign r e'), st'. apply RSAssign2; assumption.
    + exists (rassign r' e), st'. apply RSAssign1. exact Hr'.
Qed.

(* ===========================================================================
   12. STORE LEMMAS for preservation.
   =========================================================================== *)

(* store_lookup past the end of an appended store: the appended cell. *)
Lemma store_lookup_app_last : forall st v,
  store_lookup (List.length st) (app st [v]) = v.
Proof.
  intros st v. unfold store_lookup. rewrite app_nth2 by lia.
  replace (List.length st - List.length st) with 0 by lia. reflexivity.
Qed.

(* store_lookup within the original store is unchanged by appending. *)
Lemma store_lookup_app_lo : forall n st v,
  n < List.length st -> store_lookup n (app st [v]) = store_lookup n st.
Proof.
  intros n st v Hlt. unfold store_lookup. rewrite app_nth1 by assumption. reflexivity.
Qed.

(* store_update preserves length. *)
Lemma store_update_length : forall n v st,
  List.length (store_update n v st) = List.length st.
Proof.
  intros n v st. revert n. induction st as [ | x rest IH ]; intros [ | n' ]; simpl; auto.
Qed.

(* store_lookup at the updated position: the new value (when in range). *)
Lemma store_lookup_update_eq : forall n v st,
  n < List.length st -> store_lookup n (store_update n v st) = v.
Proof.
  intros n v st. revert n. induction st as [ | x rest IH ]; intros [ | n' ] Hlt; simpl in *.
  - lia.
  - lia.
  - reflexivity.
  - unfold store_lookup. simpl. apply (IH n'). lia.
Qed.

(* store_lookup at a DIFFERENT position: unchanged by the update. *)
Lemma store_lookup_update_neq : forall n m v st,
  n <> m -> store_lookup m (store_update n v st) = store_lookup m st.
Proof.
  intros n m v st. revert n m. induction st as [ | x rest IH ]; intros [ | n' ] [ | m' ] Hne; simpl in *.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - exfalso; apply Hne; reflexivity.
  - unfold store_lookup. reflexivity.
  - unfold store_lookup. reflexivity.
  - unfold store_lookup. simpl. apply (IH n' m'). lia.
Qed.

(* ===========================================================================
   13. PRESERVATION (with the store).
     has_typeR Σ [] e T -> store_well_typed Σ st -> rstep (e,st) (e',st') ->
       exists Σ', extends Σ' Σ /\ has_typeR Σ' [] e' T /\ store_well_typed Σ' st'.
   By induction on the STEP. Congruence cases recurse (extending Σ, re-typing the
   subterm, store-weakening the unchanged surroundings). The three imperative
   reductions are the substantive cases: alloc EXTENDS Σ (the standard store-typing
   growth); deref/assign keep Σ fixed and use the store-well-typedness invariant.
   =========================================================================== *)

Theorem preservation : forall S e T st e' st',
  has_typeR S [] e T ->
  store_well_typed S st ->
  rstep (e, st) (e', st') ->
  exists S', extends S' S /\ has_typeR S' [] e' T /\ store_well_typed S' st'.
Proof.
  intros S e T st e' st' Hty Hwt Hstep.
  revert T Hty. remember (e, st) as cfg eqn:Ecfg. remember (e', st') as cfg' eqn:Ecfg'.
  revert e st e' st' Ecfg Ecfg' Hwt.
  induction Hstep; intros e0 st0 e0' st0' Ecfg Ecfg' Hwt T0 Hty;
    injection Ecfg as <- <-; injection Ecfg' as <- <-.
  - (* RSBeta: (rlam T b) v -> subst 0 v b, store unchanged *)
    apply rinv_app in Hty. destruct Hty as [A [B0 [Hf [Ha Hsub]]]].
    apply rinv_lam in Hf. destruct Hf as [Tb [Hb HsubArr]].
    apply rsub_arrow_inv in HsubArr. destruct HsubArr as [HsA HsB].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    assert (HvTl : has_typeR S [] v T) by (eapply RTSub; [ exact Ha | exact HsA ]).
    eapply RTSub; [ | eapply RsTrans; [ exact HsB | exact Hsub ] ].
    apply (rsubst_top S T [] b Tb v); [ exact Hb | exact HvTl ].
  - (* RSLet: (rlet v e2) -> subst 0 v e2, store unchanged *)
    apply rinv_let in Hty. destruct Hty as [A [B [H1 [H2 Hsub]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply RTSub; [ | exact Hsub ].
    apply (rsubst_top S A [] e2 B v); [ exact H2 | exact H1 ].
  - (* RSIfTrue *) apply rinv_if in Hty. destruct Hty as [U [_ [H1 [_ Hsub]]]].
    exists S. split; [ apply extends_refl | split; [ eapply RTSub; [ exact H1 | exact Hsub ] | exact Hwt ] ].
  - (* RSIfFalse *) apply rinv_if in Hty. destruct Hty as [U [_ [_ [H2 Hsub]]]].
    exists S. split; [ apply extends_refl | split; [ eapply RTSub; [ exact H2 | exact Hsub ] | exact Hwt ] ].
  - (* RSApp1: f steps *) apply rinv_app in Hty. destruct Hty as [A [B [Hf [Ha Hsub]]]].
    destruct (IHHstep f st f' st' eq_refl eq_refl Hwt (RArrow A B) Hf)
      as [S' [Hext [Hf' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply RTSub; [ eapply RTApp; [ exact Hf' | eapply rstore_weakening; [ exact Ha | exact Hext ] ] | exact Hsub ].
  - (* RSApp2: a steps (v value) *) apply rinv_app in Hty. destruct Hty as [A [B [Hf [Ha Hsub]]]].
    destruct (IHHstep a st a' st' eq_refl eq_refl Hwt A Ha)
      as [S' [Hext [Ha' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply RTSub; [ eapply RTApp; [ eapply rstore_weakening; [ exact Hf | exact Hext ] | exact Ha' ] | exact Hsub ].
  - (* RSLet1: e1 steps *) apply rinv_let in Hty. destruct Hty as [A [B [H1 [H2 Hsub]]]].
    destruct (IHHstep e1 st e1' st' eq_refl eq_refl Hwt A H1)
      as [S' [Hext [H1' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply RTSub; [ eapply RTLet; [ exact H1' | eapply rstore_weakening; [ exact H2 | exact Hext ] ] | exact Hsub ].
  - (* RSIf1: c steps *) apply rinv_if in Hty. destruct Hty as [U [Hc [H1 [H2 Hsub]]]].
    destruct (IHHstep c st c' st' eq_refl eq_refl Hwt (RAtom ABool) Hc)
      as [S' [Hext [Hc' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply RTSub;
      [ eapply RTIf;
          [ exact Hc'
          | eapply rstore_weakening; [ exact H1 | exact Hext ]
          | eapply rstore_weakening; [ exact H2 | exact Hext ] ]
      | exact Hsub ].
  (* --- the imperative reductions ----------------------------------------- *)
  - (* RSAlloc: ralloc v / st -> rloc (length st) / st ++ [v]. EXTEND Σ by [T]. *)
    apply rinv_alloc in Hty. destruct Hty as [U [Hv Hsub]].
    destruct Hwt as [Hlen Hcells].
    exists (app S [U]). split; [ apply extends_app1 | ].
    split.
    + (* rloc (length st) : RRef U (Σ' has U at that index), subsumed to T0 *)
      eapply RTSub; [ apply RTLoc | exact Hsub ].
      rewrite <- Hlen. rewrite nth_error_app2 by lia.
      replace (List.length S - List.length S) with 0 by lia. reflexivity.
    + (* store_well_typed (Σ++[U]) (st++[v]) *)
      split.
      * rewrite !length_app. rewrite Hlen. reflexivity.
      * intros n Tn Hn.
        destruct (Nat.lt_total n (List.length S)) as [Hlt | [Heq | Hgt]].
        -- (* old cell: lookup unchanged, type via Hcells + store_weakening *)
           rewrite nth_error_app1 in Hn by assumption.
           rewrite store_lookup_app_lo by lia.
           eapply rstore_weakening; [ apply Hcells; exact Hn | apply extends_app1 ].
        -- (* the new cell at index length S: value v at type U *)
           subst n. rewrite nth_error_app2 in Hn by lia.
           replace (List.length S - List.length S) with 0 in Hn by lia. simpl in Hn.
           injection Hn as <-. rewrite Hlen. rewrite store_lookup_app_last.
           eapply rstore_weakening; [ exact Hv | apply extends_app1 ].
        -- (* out of range: nth_error = None *)
           rewrite nth_error_app2 in Hn by lia.
           assert (Hbad : n - List.length S >= 1) by lia.
           destruct (n - List.length S) as [ | m ]; [ lia | simpl in Hn; destruct m; discriminate Hn ].
  - (* RSAlloc1: e steps *) apply rinv_alloc in Hty. destruct Hty as [U [He Hsub]].
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt U He) as [S' [Hext [He' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply RTSub; [ apply RTAlloc; exact He' | exact Hsub ].
  - (* RSDeref: rderef (rloc n) / st -> store_lookup n st / st, Σ unchanged *)
    apply rinv_deref in Hty. destruct Hty as [U [Hloc Hsub]].
    apply rinv_loc in Hloc. destruct Hloc as [W [Hn Href]].
    apply rsub_ref_inv in Href. subst W.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    destruct Hwt as [_ Hcells].
    eapply RTSub; [ apply Hcells; exact Hn | exact Hsub ].
  - (* RSDeref1: e steps *) apply rinv_deref in Hty. destruct Hty as [U [He Hsub]].
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt (RRef U) He) as [S' [Hext [He' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply RTSub; [ eapply RTDeref; exact He' | exact Hsub ].
  - (* RSAssign: rassign (rloc n) v / st -> nil / store_update n v st, Σ fixed *)
    apply rinv_assign in Hty. destruct Hty as [U [Hr [Hv Hsub]]].
    apply rinv_loc in Hr. destruct Hr as [W [Hn Href]].
    apply rsub_ref_inv in Href. subst W.
    exists S. split; [ apply extends_refl | ]. split.
    + (* result is nil : runit, subsumed to T0 (rsub runit T0 = Hsub) *)
      eapply RTSub; [ apply (RTLit S []) | exact Hsub ].
    + (* store_well_typed S (store_update n v st): length preserved; cell n now v:U;
         other cells unchanged. *)
      destruct Hwt as [Hlen Hcells].
      assert (Hnlt : n < List.length st).
      { rewrite <- Hlen. apply nth_error_Some. rewrite Hn. discriminate. }
      split.
      * rewrite store_update_length. exact Hlen.
      * intros m Tm Hm.
        destruct (Nat.eq_dec m n) as [Heq | Hne].
        -- subst m. rewrite Hn in Hm. injection Hm as <-.
           rewrite store_lookup_update_eq by assumption. exact Hv.
        -- rewrite store_lookup_update_neq by (intro Hc; apply Hne; symmetry; exact Hc).
           apply Hcells; exact Hm.
  - (* RSAssign1: r steps *) apply rinv_assign in Hty. destruct Hty as [U [Hr [He Hsub]]].
    destruct (IHHstep r st r' st' eq_refl eq_refl Hwt (RRef U) Hr) as [S' [Hext [Hr' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply RTSub; [ eapply RTAssign; [ exact Hr' | eapply rstore_weakening; [ exact He | exact Hext ] ] | exact Hsub ].
  - (* RSAssign2: e steps (v value) *) apply rinv_assign in Hty. destruct Hty as [U [Hr [He Hsub]]].
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt U He) as [S' [Hext [He' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply RTSub; [ eapply RTAssign; [ eapply rstore_weakening; [ exact Hr | exact Hext ] | exact He' ] | exact Hsub ].
Qed.

(* ===========================================================================
   14. THE CHECKER — Σ-THREADED bidirectional synthesis, proven SOUND.

   Locations never appear in SOURCE (they arise only at run time from [ralloc]),
   so the checker runs over source terms with Σ = [] and has NO [rloc] case (a
   source [rloc] is rejected — [None]). It threads Σ structurally anyway (passed
   to every recursive call) so the soundness statement is Σ-general. The three
   reference operations:
     - alloc:  synth the operand to [U] ⇒ [RRef U].
     - deref:  synth to [RRef U] ⇒ unwrap to [U].
     - assign: synth the cell to [RRef U] and the value to [Sv]; gate [Sv ≤ U]
       (the invariant content type) by [decide_rsub]; result [runit].
   Subtyping is decided by a small total [decide_rsub] (atoms by [decide_atom_le],
   arrows by contra/co recursion, refs by syntactic equality — invariance).
   =========================================================================== *)

(* decidable [Atom] equality (subtype.v does not export one). *)
Definition atom_eq_dec (a b : Atom) : {a = b} + {a <> b}.
Proof. decide equality. Defined.

(* decidable atom order (reusing subtype.v's two edges). *)
Definition decide_atom_le (a b : Atom) : bool :=
  match a, b with
  | AInt, ANum   => true
  | AInt, AFloat => true
  | _, _ => false
  end.

Lemma decide_atom_le_sound : forall a b, decide_atom_le a b = true -> atom_le a b.
Proof. intros [] []; simpl; intro H; try discriminate; constructor. Qed.

(* decidable [RTy] equality (for the invariant ref rule). *)
Fixpoint rty_eqb (A B : RTy) : bool :=
  match A, B with
  | RAtom a, RAtom b => if atom_eq_dec a b then true else false
  | RTop, RTop => true
  | RBot, RBot => true
  | RArrow A1 B1, RArrow A2 B2 => andb (rty_eqb A1 A2) (rty_eqb B1 B2)
  | RRef A', RRef B' => rty_eqb A' B'
  | _, _ => false
  end.

Lemma rty_eqb_eq : forall A B, rty_eqb A B = true -> A = B.
Proof.
  induction A; intros [] H; simpl in H; try discriminate.
  - destruct (atom_eq_dec a a0); [ subst; reflexivity | discriminate ].
  - reflexivity.
  - reflexivity.
  - apply Bool.andb_true_iff in H. destruct H as [H1 H2].
    f_equal; [ apply IHA1; exact H1 | apply IHA2; exact H2 ].
  - f_equal. apply IHA; exact H.
Qed.

(* the total subtyping decider for [rsub]. The arrow case recurses on the
   CONTRAVARIANT domain ([decide A2 A1] — swapped args), so it is not structural
   on either argument alone; we use a structural fuel = size of [A] (every
   recursive call's [A]-component is a strict subterm of the current [A], so the
   fuel strictly decreases). Sound; completeness not needed for soundness. *)
Fixpoint rsize (A : RTy) : nat :=
  match A with
  | RAtom _ => 1 | RTop => 1 | RBot => 1
  | RArrow A1 B1 => S (rsize A1 + rsize B1)
  | RRef A' => S (rsize A')
  end.

Fixpoint decide_rsub_fuel (n : nat) (A B : RTy) : bool :=
  match n with
  | 0 => false
  | S n' =>
    match A, B with
    | _, RTop => true
    | RBot, _ => true
    | RAtom a, RAtom b => orb (decide_atom_le a b) (if atom_eq_dec a b then true else false)
    | RArrow A1 B1, RArrow A2 B2 =>
        andb (decide_rsub_fuel n' A2 A1) (decide_rsub_fuel n' B1 B2)
    | RRef A', RRef B' => rty_eqb A' B'      (* INVARIANT: equal content *)
    | _, _ => false
    end
  end.

Definition decide_rsub (A B : RTy) : bool := decide_rsub_fuel (rsize A + rsize B) A B.

(* fuel monotonicity: more fuel never changes a [true] answer (used to align the
   recursive calls' fuel with the top-level budget). *)
Lemma decide_rsub_fuel_sound : forall n A B,
  decide_rsub_fuel n A B = true -> rsub A B.
Proof.
  induction n as [ | n IH ]; intros A B H; simpl in H; [ discriminate | ].
  destruct A; destruct B; simpl in H; try discriminate;
    try (apply RsTop); try (apply RsBot).
  - apply Bool.orb_true_iff in H. destruct H as [Hle | Heq].
    + apply RsAtom. apply decide_atom_le_sound. exact Hle.
    + destruct (atom_eq_dec a a0); [ subst; apply RsRefl | discriminate ].
  - apply Bool.andb_true_iff in H. destruct H as [Hd Hc].
    apply RsArrow; [ apply IH; exact Hd | apply IH; exact Hc ].
  - apply rty_eqb_eq in H. subst. apply RsRef.
Qed.

Lemma decide_rsub_sound : forall A B, decide_rsub A B = true -> rsub A B.
Proof. intros A B H. unfold decide_rsub in H. eapply decide_rsub_fuel_sound; exact H. Qed.

Fixpoint synthR (G : list RTy) (e : rtm) {struct e} : option RTy :=
  match e with
  | rlit l => Some (rlit_type l)
  | rvar n => nth_error G n
  | rlam T body =>
      match synthR (T :: G) body with Some Tb => Some (RArrow T Tb) | None => None end
  | rapp f a =>
      match synthR G f with
      | Some (RArrow A B) =>
          match synthR G a with
          | Some Sa => if decide_rsub Sa A then Some B else None
          | None => None
          end
      | _ => None
      end
  | rlet e1 e2 =>
      match synthR G e1 with Some Se => synthR (Se :: G) e2 | None => None end
  | rif c e1 e2 =>
      match synthR G c with
      | Some Sc =>
          if decide_rsub Sc (RAtom ABool) then
            match synthR G e1, synthR G e2 with
            | Some U1, Some U2 => if rty_eqb U1 U2 then Some U1 else None
            | _, _ => None
            end
          else None
      | None => None
      end
  | ralloc e0 =>
      match synthR G e0 with Some U => Some (RRef U) | None => None end
  | rderef e0 =>
      match synthR G e0 with Some (RRef U) => Some U | _ => None end
  | rassign r e0 =>
      match synthR G r with
      | Some (RRef U) =>
          match synthR G e0 with
          | Some Sv => if decide_rsub Sv U then Some runit else None
          | None => None
          end
      | _ => None
      end
  | rloc _ => None     (* locations are not source syntax *)
  end.

Definition checkR (G : list RTy) (e : rtm) (T : RTy) : bool :=
  match synthR G e with Some Se => decide_rsub Se T | None => false end.

(* SOUNDNESS vs the declarative judgment (any Σ — the algorithm never inspects
   it, since source has no locations). *)
Theorem synthR_sound : forall e S G T, synthR G e = Some T -> has_typeR S G e T.
Proof.
  intro e. induction e using rtm_rect_strong; intros Sg G Tr H; simpl in H.
  - injection H as <-. apply RTLit.
  - apply RTVar. exact H.
  - destruct (synthR (T :: G) e) as [ Tb | ] eqn:Hb; [ | discriminate ].
    injection H as <-. apply RTLam. apply IHe. exact Hb.
  - destruct (synthR G e1) as [ Sf | ] eqn:Hf; [ | discriminate ].
    destruct Sf as [ | | | A B | ]; try discriminate H.
    destruct (synthR G e2) as [ Sa | ] eqn:Ha; [ | discriminate ].
    destruct (decide_rsub Sa A) eqn:Hd; [ | discriminate ].
    injection H as <-. eapply RTApp; [ apply IHe1; exact Hf | ].
    eapply RTSub; [ apply IHe2; exact Ha | apply decide_rsub_sound; exact Hd ].
  - destruct (synthR G e1) as [ Se | ] eqn:H1; [ | discriminate ].
    eapply RTLet; [ apply IHe1; exact H1 | apply IHe2; exact H ].
  - destruct (synthR G e1) as [ Sc | ] eqn:Hc; [ | discriminate ].
    destruct (decide_rsub Sc (RAtom ABool)) eqn:Hdb; [ | discriminate ].
    destruct (synthR G e2) as [ U1 | ] eqn:Ht; [ | discriminate ].
    destruct (synthR G e3) as [ U2 | ] eqn:Hf; [ | discriminate ].
    destruct (rty_eqb U1 U2) eqn:Heq; [ | discriminate ].
    apply rty_eqb_eq in Heq. subst U2. injection H as <-. apply RTIf.
    + eapply RTSub; [ apply IHe1; exact Hc | apply decide_rsub_sound; exact Hdb ].
    + apply IHe2; exact Ht.
    + apply IHe3; exact Hf.
  - destruct (synthR G e) as [ U | ] eqn:He; [ | discriminate ].
    injection H as <-. apply RTAlloc. apply IHe. exact He.
  - destruct (synthR G e) as [ Se | ] eqn:He; [ | discriminate ].
    destruct Se as [ | | | | U ]; try discriminate H.
    injection H as <-. apply RTDeref. apply IHe. exact He.
  - destruct (synthR G e1) as [ Sr | ] eqn:Hr; [ | discriminate ].
    destruct Sr as [ | | | | U ]; try discriminate H.
    destruct (synthR G e2) as [ Sv | ] eqn:He; [ | discriminate ].
    destruct (decide_rsub Sv U) eqn:Hd; [ | discriminate ].
    injection H as <-. eapply RTAssign; [ apply IHe1; exact Hr | ].
    eapply RTSub; [ apply IHe2; exact He | apply decide_rsub_sound; exact Hd ].
  - discriminate H.    (* rloc: synthR = None *)
Qed.

Theorem checkR_sound : forall e S G T, checkR G e T = true -> has_typeR S G e T.
Proof.
  intros e S G T H. unfold checkR in H.
  destruct (synthR G e) as [ Se | ] eqn:He; [ | discriminate ].
  eapply RTSub; [ apply synthR_sound; exact He | apply decide_rsub_sound; exact H ].
Qed.

(* ===========================================================================
   15. SANITY (all proved).
   (a) allocate a ref, read it back — types AND steps.
   (b) assign then read — the NEW value (the store actually MUTATES).
   (c) a ref-of-int used as ref-of-int (the invariant content type).
   (d) an ill-typed assign (string into a [RRef Int]) is REJECTED.
   =========================================================================== *)

(* --- (a) allocate an Int ref and dereference it, at the EMPTY store. -------- *)
Definition ex_alloc_deref : rtm := rderef (ralloc (rlit (LInt 7))).

Example ex_alloc_deref_typed :
  has_typeR [] [] ex_alloc_deref (RAtom AInt).
Proof.
  unfold ex_alloc_deref. apply RTDeref. apply RTAlloc. apply RTLit.
Qed.

(* it steps: alloc the value (store [7]), then deref reads back [7]. *)
Example ex_alloc_step :
  rstep (ex_alloc_deref, []) (rderef (rloc 0), [rlit (LInt 7)]).
Proof.
  unfold ex_alloc_deref. apply RSDeref1. apply RSAlloc. apply RVLit.
Qed.

Example ex_deref_step :
  rstep (rderef (rloc 0), [rlit (LInt 7)]) (rlit (LInt 7), [rlit (LInt 7)]).
Proof.
  replace (rlit (LInt 7)) with (store_lookup 0 [rlit (LInt 7)]) at 2 by reflexivity.
  apply RSDeref.
Qed.

(* --- (b) assign then read: the store MUTATES — deref returns the NEW value. -
   Start from a store holding [7] at location 0 (Σ = [Int]). Assign [9], then a
   deref of location 0 reads [9], NOT [7]. We show the assign STEP changes the
   store, and the subsequent deref reads the updated cell. *)
Example ex_assign_mutates_store :
  rstep (rassign (rloc 0) (rlit (LInt 9)), [rlit (LInt 7)])
        (rlit LNil, store_update 0 (rlit (LInt 9)) [rlit (LInt 7)]).
Proof. apply RSAssign. apply RVLit. Qed.

(* the updated store holds [9] at location 0 (the mutation is observable). *)
Example ex_after_assign_lookup :
  store_lookup 0 (store_update 0 (rlit (LInt 9)) [rlit (LInt 7)]) = rlit (LInt 9).
Proof. reflexivity. Qed.

(* and a deref of the UPDATED store reads the new value [9] (not the old [7]). *)
Example ex_deref_after_assign :
  rstep (rderef (rloc 0), store_update 0 (rlit (LInt 9)) [rlit (LInt 7)])
        (rlit (LInt 9), store_update 0 (rlit (LInt 9)) [rlit (LInt 7)]).
Proof.
  replace (rlit (LInt 9))
    with (store_lookup 0 (store_update 0 (rlit (LInt 9)) [rlit (LInt 7)])) at 2 by reflexivity.
  apply RSDeref.
Qed.

(* the assign is WELL-TYPED at the unit type, under Σ = [Int] (cell 0 : Int). *)
Example ex_assign_typed :
  has_typeR [RAtom AInt] [] (rassign (rloc 0) (rlit (LInt 9))) runit.
Proof.
  eapply RTAssign; [ apply RTLoc; reflexivity | apply RTLit ].
Qed.

(* --- (c) a ref-of-int genuinely typed as ref-of-int (invariant content). ---- *)
Example ex_ref_int_is_ref_int :
  has_typeR [] [] (ralloc (rlit (LInt 0))) (RRef (RAtom AInt)).
Proof. apply RTAlloc. apply RTLit. Qed.

(* and the CHECKER agrees (synthR over source): alloc-of-int synthesizes ref-int. *)
Example ex_check_ref_int :
  synthR [] (ralloc (rlit (LInt 0))) = Some (RRef (RAtom AInt)).
Proof. reflexivity. Qed.

(* --- (d) ill-typed assign REJECTED: writing a STRING into a [RRef Int]. ------
   Under Σ = [Int] (cell 0 : Int), [rassign (rloc 0) "s"] is NOT typeable at any
   type — the value [AStr] is not [rsub]-below the cell content type [AInt]. We
   prove NO type is derivable. *)
Example ex_bad_assign_untyped :
  forall T, ~ has_typeR [RAtom AInt] [] (rassign (rloc 0) (rlit (LStr 0))) T.
Proof.
  intros T H. apply rinv_assign in H. destruct H as [U [Hr [He _]]].
  (* the cell type U: rloc 0 : RRef U with nth_error [Int] 0 = Some U' and RRef U' <: RRef U *)
  apply rinv_loc in Hr. destruct Hr as [W [Hn Href]].
  simpl in Hn. injection Hn as <-. apply rsub_ref_inv in Href. subst U.
  (* He : "s" : U = RAtom AInt — impossible (AStr not <: AInt) *)
  apply rinv_lit in He. simpl in He.
  apply rsub_atom_atom in He. destruct He as [Hle | Heq]; [ inversion Hle | discriminate ].
Qed.

(* the CHECKER also rejects it (synthR = None — the [decide_rsub AStr AInt] gate). *)
Example ex_bad_assign_check_None :
  synthR [RAtom AInt] (rassign (rloc 0) (rlit (LStr 0))) = None.
Proof. reflexivity. Qed.    (* rloc not source — but the gate is the point; see below *)

(* (the above is None because [rloc] is non-source; the genuine TYPE-LEVEL
   rejection is [ex_bad_assign_untyped]. A source-level ill-typed assign through a
   variable of ref type is rejected by the same [decide_rsub] gate:) *)
Example ex_bad_assign_var_check_None :
  synthR [RRef (RAtom AInt)] (rassign (rvar 0) (rlit (LStr 0))) = None.
Proof. reflexivity. Qed.

(* the GOOD source-level assign (int into ref-int via a var) CHECKS. *)
Example ex_good_assign_var_check :
  synthR [RRef (RAtom AInt)] (rassign (rvar 0) (rlit (LInt 5))) = Some runit.
Proof. reflexivity. Qed.

(* --- progress + preservation instantiated, exercising the store. ------------ *)
Example ex_progress_alloc :
  rvalue ex_alloc_deref \/ exists e' st', rstep (ex_alloc_deref, []) (e', st').
Proof.
  apply (progress [] ex_alloc_deref (RAtom AInt) ex_alloc_deref_typed []).
  split; [ reflexivity | intros n T Hn; destruct n; simpl in Hn; discriminate ].
Qed.

(* preservation across the assign step: the store stays well-typed at Σ=[Int],
   and the result (nil) types at unit. *)
Example ex_preservation_assign :
  exists S', extends S' [RAtom AInt] /\
    has_typeR S' [] (rlit LNil) runit /\
    store_well_typed S' (store_update 0 (rlit (LInt 9)) [rlit (LInt 7)]).
Proof.
  apply (preservation [RAtom AInt] (rassign (rloc 0) (rlit (LInt 9))) runit
           [rlit (LInt 7)] (rlit LNil) (store_update 0 (rlit (LInt 9)) [rlit (LInt 7)])).
  - exact ex_assign_typed.
  - split; [ reflexivity | ].
    intros n T Hn. destruct n as [ | n' ]; simpl in Hn.
    + injection Hn as <-. apply RTLit.
    + destruct n'; discriminate Hn.
  - apply RSAssign. apply RVLit.
Qed.

(* ===========================================================================
   ASSUMPTION AUDIT — closed under the global context (no axioms/Admitted).
   =========================================================================== *)
Print Assumptions progress.
Print Assumptions preservation.
Print Assumptions synthR_sound.
Print Assumptions checkR_sound.
Print Assumptions ex_assign_mutates_store.
Print Assumptions ex_bad_assign_untyped.
Print Assumptions ex_preservation_assign.
