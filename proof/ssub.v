(* ssub.v — the checker's SYNTACTIC subtyping relation [ssub], solidified.

   BUILD ORDER (inside `nix develop`, from repo root):
     coqc proof/subtype.v        (* the value-set Boolean algebra + dsub *)
     coqc proof/typing.v         (* defines ssub, ssub_sound, the typing layer *)
     coqc proof/ssub.v           (* THIS FILE — builds on both *)

   [subtype.v] is UNMODIFIED. [typing.v] is UNMODIFIED. This file is purely
   additive: it imports [ssub] and its inversion lemmas from [typing.v] and the
   semantic [dsub] from [subtype.v], and adds:

     (1) PREORDER. [ssub_refl], [ssub_trans] as standalone lemmas (the checker's
         metatheory composes subsumption along them). They are immediate from the
         [SsRefl]/[SsTrans] constructors of [ssub] — recorded here as named,
         reusable facts.

     (2) A TOTAL, TERMINATING DECISION PROCEDURE [decide_ssub : BTy -> BTy ->
         bool], proved SOUND AND COMPLETE: [decide_ssub a b = true <-> ssub a b].
         Terminating BY CONSTRUCTION (structural fuel recursion on the combined
         size [bsize a + bsize b]; the measure strictly decreases at every
         recursive call — contravariant arrow domain, covariant codomain, record
         width+depth). NO emptiness/DNF machinery (that was for the SEMANTIC
         [dsub]); [ssub] is syntactic so the decider is clean structural
         recursion. TOTAL over the WHOLE of [BTy]: it returns a definite bool for
         every pair, a clean improvement over [gdecide]'s [DUnknown].

         CONNECTIVE FRAGMENT — total but COARSE (honest scope). [ssub] has NO
         structural rule for the Boolean connectives [BUnion]/[BInter]/[BNeg]:
         its only constructors are [SsRefl], [SsTrans], [SsTop], [SsBot],
         [SsAtom], [SsArrow], [SsRec]. So for a connective type [c] (one whose
         head is [BUnion]/[BInter]/[BNeg]), [ssub c d] holds iff [d = BTop] or
         [c = BBot] (impossible, c is a connective) or [c] and [d] are
         SYNTACTICALLY EQUAL (refl, chained through trans/top/bot — proved as
         [ssub_connective_super] below). [decide_ssub] decides this EXACTLY and
         TOTALLY (via a [BTy] equality test). It is therefore total on all of
         [BTy], but on the connective fragment it only recognises the
         REFLEXIVE/Top/Bot subtypings — it does NOT decide the SEMANTIC Boolean
         subtypings (e.g. [BInter X Y <: X]); those are [dsub]'s job ([gdecide]),
         and routing them through [ssub] is DEFERRED (see TODO.md). This is
         correct: the typing core ([typing.v]) subsumes only along [ssub], whose
         connective subtypings are exactly the structural ones, so [decide_ssub]
         decides precisely what the checker needs.

     (3) THE [ssub]-vs-[dsub] GAP, characterized. [ssub_sound] (in typing.v)
         gives [ssub ⊆ dsub]; the inclusion is STRICT, with TWO precise gap
         instances:
           - [dsub_ssub_gap]: the operationally-unsound arrow/Top collapse
             [dsub (Rec->Int) (Int->Top)] that [dsub] admits and [ssub] correctly
             REJECTS (the central preservation-breaking witness from typing.v).
           - [dsub_ssub_gap_atom]: AT THE ATOM LEVEL, [AFloat] ≡ [ANum] under
             [dsub] (LuaJIT 5.1: both denote ALL numbers) but [ssub] has NO
             declared edge between them, so [dsub (BAtom AFloat) (BAtom ANum)]
             holds while [ssub] does not. [ssub] tracks the DECLARED atom order,
             not the value sets — this is the honest price.
         COINCIDENCE where they agree: on the AFLOAT-FREE atom fragment they are
         EQUAL ([ssub_dsub_coincide_atom]); and the structural direction holds
         generally — every [decide_ssub]-true pair is a [dsub]
         ([decide_ssub_implies_dsub]). The general [ssub]-completeness vs ALL
         operationally-sound subtypings is the DEEP open question (DEFERRED, see
         TODO.md); what is proved here is the precise WHERE-they-differ.

   HARD-CONSTRAINT AUDIT at the end: [Print Assumptions] on [ssub_refl],
   [ssub_trans], [decide_ssub_sound], [decide_ssub_complete], [dsub_ssub_gap] —
   all "Closed under the global context".
*)

Require Import subtype.
Require Import typing.
From Stdlib Require Import List.
From Stdlib Require Import String.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Import ListNotations.

(* ===========================================================================
   1. PREORDER — [ssub] is reflexive and transitive.

   Both are constructors of [ssub] ([SsRefl], [SsTrans]); we expose them as
   named lemmas the typing metatheory composes along. Reflexivity is one rule;
   transitivity here is ALSO one rule (unlike subtype.v's [sub], where
   transitivity was real metatheory — [ssub] bakes [SsTrans] in as a primitive,
   precisely so the typing-layer inversion lemmas can thread an arbitrary number
   of subsumption steps into a single [ssub], see [inv_*] in typing.v).

   NOTE on transitivity's "care at the arrow/record cases": composing two arrow
   subtypings [ssub (A1->B1) (A2->B2)] and [ssub (A2->B2) (A3->B3)] does require
   the contravariant/covariant pieces to compose — but that composition is
   EXACTLY what [SsTrans] provides at the top level, and the structural variance
   recomposition is what [ssub_arrow_super] (typing.v) already proves to derive
   [ssub_arrow_inv]. So transitivity itself is the [SsTrans] constructor; the
   "care" lives in the INVERSION lemmas (already in typing.v), which is where the
   arrow/record variance recomposition genuinely happens. We re-export the
   structural recomposition facts here as [ssub_trans_arrow]/[ssub_trans_rec] to
   make the metatheory self-documenting.
   =========================================================================== *)

Lemma ssub_refl : forall t, ssub t t.
Proof. intro t. apply SsRefl. Qed.

Lemma ssub_trans : forall a b c, ssub a b -> ssub b c -> ssub a c.
Proof. intros a b c Hab Hbc. eapply SsTrans; eassumption. Qed.

(* The arrow case of transitivity, made explicit: composing two arrow subtypings
   recomposes contravariantly in the domain and covariantly in the codomain.
   (This is what [SsTrans] does at arrow types, surfaced via [ssub_arrow_inv].) *)
Lemma ssub_trans_arrow : forall A1 B1 A2 B2 A3 B3,
  ssub (BArrow A1 B1) (BArrow A2 B2) ->
  ssub (BArrow A2 B2) (BArrow A3 B3) ->
  ssub A3 A1 /\ ssub B1 B3.
Proof.
  intros A1 B1 A2 B2 A3 B3 H12 H23.
  apply ssub_arrow_inv in H12. destruct H12 as [Hd12 Hc12].
  apply ssub_arrow_inv in H23. destruct H23 as [Hd23 Hc23].
  split; eapply SsTrans; eassumption.
Qed.

(* The record case of transitivity, made explicit: a field demanded by the final
   record is supplied by the first, with the field types composing. *)
Lemma ssub_trans_rec : forall f g h,
  ssub (BRec f) (BRec g) -> ssub (BRec g) (BRec h) ->
  forall k Th, In (k, Th) h ->
    exists Tf, In (k, Tf) f /\ ssub Tf Th.
Proof.
  intros f g h Hfg Hgh k Th Hin.
  destruct (ssub_rec_inv g h k Th Hgh Hin) as [Tg [Hing Hgth]].
  destruct (ssub_rec_inv f g k Tg Hfg Hing) as [Tf [Hinf Hftg]].
  exists Tf. split; [exact Hinf | eapply SsTrans; eassumption].
Qed.

(* ===========================================================================
   2. SIZE MEASURE for [BTy] — the termination accountant for [decide_ssub].

   [bsize] counts constructors, summing field/sub-type sizes. The recursive
   calls of [decide_ssub] go to strictly-smaller [bsize]-sums:
     - arrow domain  [decide_ssub A2 A1] : bsize A2 + bsize A1 < the arrow pair
     - arrow codom   [decide_ssub B1 B2] : bsize B1 + bsize B2 < the arrow pair
     - record field  [decide_ssub Tf Tg] : each strictly inside its [BRec].
   =========================================================================== *)

Fixpoint bsize (t : BTy) : nat :=
  match t with
  | BAtom _ => 1
  | BTop => 1
  | BBot => 1
  | BUnion a b => S (bsize a + bsize b)
  | BInter a b => S (bsize a + bsize b)
  | BNeg a => S (bsize a)
  | BArrow a b => S (bsize a + bsize b)
  | BRec fs => S ((fix ms (xs : list (string * BTy)) : nat :=
                     match xs with
                     | [] => 0
                     | (_, T) :: r => bsize T + ms r
                     end) fs)
  end.

Lemma bsize_pos : forall t, 1 <= bsize t.
Proof. intro t; destruct t; simpl; lia. Qed.

(* a field's size is < the record's size (used for the record-depth recursion). *)
Lemma bsize_field_lt : forall fs k T, In (k, T) fs -> bsize T < bsize (BRec fs).
Proof.
  intro fs. induction fs as [ | [k0 T0] fs IH ]; intros k T Hin; simpl in *.
  - contradiction.
  - destruct Hin as [Heq | Hin].
    + injection Heq as <- <-. lia.
    + specialize (IH k T Hin). simpl in IH. lia.
Qed.

(* ===========================================================================
   3. DECIDABLE EQUALITY on [BTy] — needed for the connective fragment (where
   [ssub] relates two connective types only when they are syntactically equal,
   modulo Top/Bot). [Atom] and [string] have decidable equality; [BTy] is built
   from them, so [BTy] equality is decidable. We derive it with [decide equality]
   after supplying the list/atom/string decisions. *)
(* =========================================================================== *)

Definition atom_eq_dec (a b : Atom) : {a = b} + {a <> b}.
Proof. decide equality. Defined.

(* decidable equality for [BTy] (and its nested record-field lists). *)
Definition bty_eq_dec : forall (a b : BTy), {a = b} + {a <> b}.
Proof.
  fix REC 1. intros a b.
  destruct a as [a1| | |a1 a2|a1 a2|a1|f|A1 B1];
  destruct b as [b1| | |b1 b2|b1 b2|b1|g|A2 B2];
    try (right; discriminate); try (left; reflexivity).
  - (* BAtom *) destruct (atom_eq_dec a1 b1); [left|right]; congruence.
  - (* BUnion *) destruct (REC a1 b1); destruct (REC a2 b2);
      try (right; congruence). left; congruence.
  - (* BInter *) destruct (REC a1 b1); destruct (REC a2 b2);
      try (right; congruence). left; congruence.
  - (* BNeg *) destruct (REC a1 b1); [left|right]; congruence.
  - (* BRec — compare the field lists with a local nested fixpoint over f, with
       g universally quantified so the recursion shrinks BOTH lists. The element
       comparison reuses the outer [REC]. We first prove list equality is
       decidable, then map it back through the [BRec] constructor. *)
    assert (Hlist : forall (l1 l2 : list (string * BTy)), {l1 = l2} + {l1 <> l2}).
    { fix RECL 1. intros l1 l2.
      destruct l1 as [ | [kf Tf] f' ]; destruct l2 as [ | [kg Tg] g' ];
        try (right; discriminate); try (left; reflexivity).
      destruct (string_dec kf kg) as [Hk | Hk]; [ | right; congruence ].
      destruct (REC Tf Tg) as [HT | HT]; [ | right; congruence ].
      destruct (RECL f' g') as [Hl | Hl].
      - left; congruence.
      - right; congruence. }
    destruct (Hlist f g) as [Hl | Hl].
    + left; congruence.
    + right. congruence.
  - (* BArrow *) destruct (REC A1 A2); destruct (REC B1 B2);
      try (right; congruence). left; congruence.
Defined.

Definition bty_eqb (a b : BTy) : bool :=
  if bty_eq_dec a b then true else false.

Lemma bty_eqb_true : forall a b, bty_eqb a b = true <-> a = b.
Proof.
  intros a b. unfold bty_eqb. destruct (bty_eq_dec a b); split; intro H;
    (reflexivity || discriminate || assumption || (subst; reflexivity) || contradiction).
Qed.

(* decidable [atom_le] (the atom sub-order: only [AInt<:ANum], [AInt<:AFloat]). *)
Definition atom_le_dec (a b : Atom) : {atom_le a b} + {~ atom_le a b}.
Proof.
  destruct a; destruct b;
    try (left; constructor);
    right; intro H; inversion H.
Defined.

Definition atom_le_b (a b : Atom) : bool :=
  if atom_le_dec a b then true else false.

Lemma atom_le_b_true : forall a b, atom_le_b a b = true <-> atom_le a b.
Proof.
  intros a b. unfold atom_le_b. destruct (atom_le_dec a b); split; intro H;
    (reflexivity || discriminate || assumption || contradiction).
Qed.

(* ===========================================================================
   4. THE DECISION PROCEDURE — [decide_ssub].

   Structural fuel recursion: fuel bounds the combined size [bsize a + bsize b].
   Every recursive call strictly decreases the sum, so fuel [bsize a + bsize b]
   is provably sufficient. The structure:

     - [b = BTop]         => true        (SsTop)
     - [a = BBot]         => true        (SsBot)
     - else by heads:
       - atoms            => [atom_le_b] or equal  (SsAtom / SsRefl)
       - arrows           => contra domain && co codomain  (SsArrow)
       - records          => [decide_srec] (width + depth)  (SsRec)
       - any other pair   => [bty_eqb a b]  (refl ONLY — the connective fragment
                             and cross-head pairs collapse to syntactic equality)

   The [bty_eqb] fall-through is what makes the decider TOTAL on the connective
   fragment WITHOUT deciding semantic Boolean subtyping: it recognises exactly
   the reflexive subtypings [ssub] has there.

   The record-field decision [decide_srec] is a plain structural fixpoint over
   the DEMANDED list [g]; the per-field subtyping is the [rec] parameter, into
   which we thread [decide_ssub_fuel n'] (the field sizes are strictly smaller
   than the record sizes, so [n'] is always sufficient fuel — established in the
   correctness proof).
   =========================================================================== *)

Fixpoint decide_srec (rec : BTy -> BTy -> bool)
                     (f : list (string * BTy)) (g : list (string * BTy)) : bool :=
  match g with
  | [] => true
  | (k, Tg) :: g' =>
      (fix find (ff : list (string * BTy)) : bool :=
         match ff with
         | [] => false
         | (k', Tf) :: ff' =>
             if string_dec k k' then
               (if rec Tf Tg then true else find ff')
             else find ff'
         end) f
      && decide_srec rec f g'
  end.

Fixpoint decide_ssub_fuel (n : nat) (a b : BTy) : bool :=
  match n with
  | 0 => false
  | S n' =>
      match b with
      | BTop => true
      | _ =>
          match a with
          | BBot => true
          | _ =>
              match a, b with
              (* INCREMENT 11 — UNION clauses. UNION-ON-LEFT FIRST (elimination):
                 [A∪B <: C] iff [A <: C] AND [B <: C] (matches [SsUnionE]; the
                 converse holds by intro+trans). Each recursive call shrinks the
                 size sum [bsize a1 + bsize b < bsize (A∪B) + bsize b], so the
                 fuel measure [bsize a + bsize b] still strictly decreases. *)
              | BUnion a1 a2, _ =>
                  andb (decide_ssub_fuel n' a1 b) (decide_ssub_fuel n' a2 b)
              (* INCREMENT 12 — INTERSECTION-ON-RIGHT (GLB introduction), checked
                 BEFORE union-on-right and inter-on-left so the [SsInterI] /
                 [SsInterPL]+[SsInterPR] interplay is decided completely: [a <: B∩C]
                 iff [a <: B] AND [a <: C] — a FULL iff ([ssub_inter_tgt_l]/[_r]
                 forward, [SsInterI] back), sound AND complete with NO fragment
                 restriction. [bsize a + bsize b1 < bsize a + bsize (B∩C)]. *)
              | _, BInter b1 b2 =>
                  andb (decide_ssub_fuel n' a b1) (decide_ssub_fuel n' a b2)
              (* UNION-ON-RIGHT (introduction), for a NON-union [a] (union-a is
                 caught above): [a <: B∪C] iff [a <: B] OR [a <: C] (matches
                 [SsUnionInL]/[SsUnionInR]; completeness via [ssub_union_tgt_inv]).
                 [bsize a + bsize b1 < bsize a + bsize (B∪C)]. *)
              | _, BUnion b1 b2 =>
                  orb (decide_ssub_fuel n' a b1) (decide_ssub_fuel n' a b2)
              (* INCREMENT 12 — INTERSECTION-ON-LEFT (projection), for a [b] that is
                 NOT a connective (union/inter caught above): [A∩B <: b] iff
                 [A <: b] OR [B <: b] (matches [SsInterPL]/[SsInterPR]). SOUND
                 unconditionally; COMPLETE only on the intersection-free-LEFT
                 fragment ([inter_free a]) — the inter-left / union-right /
                 inter-right CROSS is the NON-DISTRIBUTIVE frontier (subtype.v's
                 N5), where [ssub (A∩B) b] need NOT reduce to a single projection.
                 So [decide_ssub] is TOTAL + SOUND everywhere, COMPLETE on
                 [inter_free a]; the rest is DEFERRED (the emptiness/distributivity
                 problem is [dsub]/[gdecide]'s job). See [decide_ssub_complete]. *)
              | BInter a1 a2, _ =>
                  orb (decide_ssub_fuel n' a1 b) (decide_ssub_fuel n' a2 b)
              | BAtom x, BAtom y => orb (atom_le_b x y) (bty_eqb a b)
              | BArrow A1 B1, BArrow A2 B2 =>
                  andb (decide_ssub_fuel n' A2 A1) (decide_ssub_fuel n' B1 B2)
              | BRec f, BRec g => decide_srec (decide_ssub_fuel n') f g
              | _, _ => bty_eqb a b
              end
          end
      end
  end.

Definition decide_ssub (a b : BTy) : bool :=
  decide_ssub_fuel (bsize a + bsize b) a b.

(* ===========================================================================
   5. SHAPE LEMMAS for the COMPLETENESS direction.

   INCREMENT 11 RE-ARCHITECTURE. The UNION rules added to [ssub] make the old
   "[is_connective] super/sub is Top/itself only" lemmas FALSE for [BUnion]
   (a union is now genuinely below/above other types via intro/elim). They are
   replaced by the UNION-ROBUST inversion lemmas proved in typing.v via the
   [_above]/[union_below] structural-predicate mechanism (closed under [ssub] by
   induction, surviving the explicit-transitivity / union-middle obstruction):

     - [ssub_atom_atom]        (atom leaf — typing.v)
     - [ssub_arrow_super] / [ssub_arrow_inv]   (arrow — typing.v)
     - [ssub_rec_super]  / [ssub_rec_inv]      (record — typing.v)
     - [ssub_union_src_l/r], [ssub_union_tgt_inv]  (union elim / intro — typing.v)
     - [ssub_interneg_leaf]    (BInter/BNeg leaf: reflexive-only — DEFERRED — typing.v)
     - the cross-kind not-[ssub] facts (typing.v)

   [BInter]/[BNeg] remain the DEFERRED connectives: [ssub] has no structural rule
   for them, so the decider treats them reflexively (via [bty_eqb]); their leaf
   completeness is [ssub_interneg_leaf]. We re-export [is_inter_neg] from typing.v
   for the decider's leaf reasoning.
   =========================================================================== *)

(* ===========================================================================
   6. SOUNDNESS + COMPLETENESS of the fuel decider, then of [decide_ssub].

   We prove, by strong induction on fuel [n], that whenever [n] is sufficient
   ([bsize a + bsize b <= n]) the decider agrees with [ssub]. The record case
   threads the same statement to the field types (strictly smaller, so [n'] is
   sufficient).
   =========================================================================== *)

(* ---- The record-field decider's correctness, parameterized by a [rec] that is
   correct on all field pairs occurring (we feed it field sizes via the caller).
   SOUNDNESS of [decide_srec]: if it returns true and [rec Tf Tg = true ->
   ssub Tf Tg] for the queried pairs, then [srec f g]. We use a clean uniform
   hypothesis: [rec] is correct ([rec Tf Tg = true <-> ssub Tf Tg]) on every
   pair whose combined size is within budget — but for soundness we only need the
   forward direction on the pairs that actually fire. *)

(* find-loop soundness: a successful [find] yields an [In] supplier with [rec].
   The [rec]-correctness hypothesis is restricted to suppliers [Tf] DRAWN FROM
   [f] (so the caller can supply the per-field size bound). *)
Lemma decide_srec_find_sound : forall (rec : BTy -> BTy -> bool) k Tg f,
  (forall Tf, In (k, Tf) f -> rec Tf Tg = true -> ssub Tf Tg) ->
  (fix find (ff : list (string * BTy)) : bool :=
     match ff with
     | [] => false
     | (k', Tf) :: ff' =>
         if string_dec k k' then (if rec Tf Tg then true else find ff') else find ff'
     end) f = true ->
  exists Tf, In (k, Tf) f /\ ssub Tf Tg.
Proof.
  intros rec k Tg f Hrec. induction f as [ | [k' Tf] f' IH ]; simpl; intro Hfind.
  - discriminate.
  - destruct (string_dec k k') as [Hke | Hkne].
    + subst k'. destruct (rec Tf Tg) eqn:Hr.
      * exists Tf. split; [left; reflexivity | apply (Hrec Tf); [left; reflexivity | exact Hr]].
      * destruct IH as [Tf2 [Hin Hs]].
        { intros Tf0 Hin0 Hr0. apply (Hrec Tf0); [right; exact Hin0 | exact Hr0]. }
        { exact Hfind. }
        exists Tf2. split; [right; exact Hin | exact Hs].
    + destruct IH as [Tf2 [Hin Hs]].
      { intros Tf0 Hin0 Hr0. apply (Hrec Tf0); [right; exact Hin0 | exact Hr0]. }
      { exact Hfind. }
      exists Tf2. split; [right; exact Hin | exact Hs].
Qed.

(* SOUNDNESS of [decide_srec], with [rec] correct only on (supplier ∈ f, demand
   ∈ g) field pairs. *)
Lemma decide_srec_sound : forall (rec : BTy -> BTy -> bool) f g,
  (forall k Tf Tg, In (k, Tf) f -> In (k, Tg) g -> rec Tf Tg = true -> ssub Tf Tg) ->
  decide_srec rec f g = true -> srec f g.
Proof.
  intros rec f g. revert f. induction g as [ | [k Tg] g' IH ]; intros f Hrec Hdec; simpl in Hdec.
  - apply SrNil.
  - apply andb_true_iff in Hdec. destruct Hdec as [Hfind Hrest].
    destruct (decide_srec_find_sound rec k Tg f) as [Tf [Hin Hs]].
    { intros Tf0 Hin0 Hr0. apply (Hrec k Tf0 Tg Hin0); [ left; reflexivity | exact Hr0 ]. }
    { exact Hfind. }
    eapply SrCons; [ exact Hin | exact Hs | ].
    apply IH; [ | exact Hrest ].
    intros k0 Tf0 Tg0 Hinf Hing Hr0. apply (Hrec k0 Tf0 Tg0 Hinf); [ right; exact Hing | exact Hr0 ].
Qed.

(* COMPLETENESS of the find-loop / [decide_srec]: from [srec f g] and [rec]
   complete on the queried pairs, the decider returns true. *)
Lemma decide_srec_find_complete : forall (rec : BTy -> BTy -> bool) k Tg Tf f,
  (rec Tf Tg = true) ->
  In (k, Tf) f ->
  (fix find (ff : list (string * BTy)) : bool :=
     match ff with
     | [] => false
     | (k', Tf0) :: ff' =>
         if string_dec k k' then (if rec Tf0 Tg then true else find ff') else find ff'
     end) f = true.
Proof.
  intros rec k Tg Tf f Hrec. induction f as [ | [k' Tf0] f' IH ]; simpl; intros Hin.
  - contradiction.
  - destruct Hin as [Heq | Hin].
    + injection Heq as Hk1 Hk2. subst k' Tf0.
      destruct (string_dec k k) as [_ | Hne]; [ | contradiction ].
      rewrite Hrec. reflexivity.
    + destruct (string_dec k k') as [Hke | Hkne].
      * destruct (rec Tf0 Tg); [reflexivity | apply IH; assumption].
      * apply IH; assumption.
Qed.

Lemma decide_srec_complete : forall (rec : BTy -> BTy -> bool) f g,
  (forall k Tf Tg, In (k, Tf) f -> In (k, Tg) g -> ssub Tf Tg -> rec Tf Tg = true) ->
  srec f g -> decide_srec rec f g = true.
Proof.
  intros rec f g Hrec H. induction H as [ f0 | f0 k Tf Tg g0 Hin Hsf Hsrec IHsrec ]; simpl.
  - reflexivity.
  - apply andb_true_iff. split.
    + eapply (decide_srec_find_complete rec k Tg Tf f0); [ | exact Hin ].
      apply (Hrec k Tf Tg Hin); [ left; reflexivity | exact Hsf ].
    + apply IHsrec.
      intros k0 Tf0 Tg0 Hinf Hing Hs0.
      apply (Hrec k0 Tf0 Tg0 Hinf); [ right; exact Hing | exact Hs0 ].
Qed.

(* From a whole-record subtyping to the pointwise [srec]: build [srec f g] by a
   helper that, GIVEN every demand of [g] is supplied from [f], assembles the
   chain. The supply fact comes from [ssub_rec_inv] applied to [Hs] for each
   member of [g] — and crucially [g]'s members are all members of the FIXED
   original list, so one [Hs] serves all (avoiding a non-terminating list-shrink
   that re-derives [Hs] at each tail). *)
Lemma srec_of_supply : forall f g,
  (forall k Tg, In (k, Tg) g -> exists Tf, In (k, Tf) f /\ ssub Tf Tg) ->
  srec f g.
Proof.
  intros f g. induction g as [ | [k Tg] g' IH ]; intro Hsup.
  - apply SrNil.
  - destruct (Hsup k Tg (or_introl eq_refl)) as [Tf [Hin Hsf]].
    eapply SrCons; [ exact Hin | exact Hsf | ].
    apply IH. intros k0 Tg0 Hin0. apply Hsup. right; exact Hin0.
Qed.

Lemma ssub_rec_to_srec : forall f g, ssub (BRec f) (BRec g) -> srec f g.
Proof.
  intros f g Hs. apply srec_of_supply.
  intros k Tg Hin. apply (ssub_rec_inv f g k Tg Hs Hin).
Qed.

(* ---- The decider's correctness, INCREMENT 12. The decider branches
   UNION-ON-LEFT, INTER-ON-RIGHT, UNION-ON-RIGHT, INTER-ON-LEFT, then the head
   leaves. SOUNDNESS is UNCONDITIONAL (every clause maps to an [ssub] rule, so the
   decider NEVER claims a non-subtyping). COMPLETENESS is proved on the
   INTERSECTION-FREE fragment [inter_free a /\ inter_free b] — there the new
   [BInter] clauses never fire and the decision coincides with the (complete)
   increment-11 atom/arrow/record/union decider. Intersection subtyping is decided
   SOUNDLY everywhere; the COMPLETE decision of intersection-on-the-LEFT
   (projection) is the NON-DISTRIBUTIVE frontier (subtype.v's N5 — the free
   lattice is provably non-distributive: [ssub (A∩B) C] need NOT reduce to a
   single projection), DEFERRED to the emptiness/distributivity decision
   ([dsub]/[gdecide]); see TODO.md / docs/proof-kernel.md. Termination measure
   unchanged: [bsize a + bsize b], strictly decreasing at every recursive call. *)

(* [inter_free t]: no [BInter] occurs anywhere in [t]. On this fragment the
   decider is complete (the [BInter] clauses never fire). *)
Fixpoint inter_free (t : BTy) : Prop :=
  match t with
  | BAtom _ => True
  | BTop => True
  | BBot => True
  | BUnion a b => inter_free a /\ inter_free b
  | BInter _ _ => False
  | BNeg a => inter_free a
  | BArrow a b => inter_free a /\ inter_free b
  | BRec fs => (fix il (xs : list (string * BTy)) : Prop :=
                  match xs with [] => True | (_, T) :: r => inter_free T /\ il r end) fs
  end.

(* One-step computation of [decide_ssub_fuel] when neither short-circuit fires. *)
Lemma decide_ssub_step : forall n a b,
  b <> BTop -> a <> BBot ->
  decide_ssub_fuel (S n) a b =
    match a, b with
    | BUnion a1 a2, _ => andb (decide_ssub_fuel n a1 b) (decide_ssub_fuel n a2 b)
    | _, BInter b1 b2 => andb (decide_ssub_fuel n a b1) (decide_ssub_fuel n a b2)
    | _, BUnion b1 b2 => orb (decide_ssub_fuel n a b1) (decide_ssub_fuel n a b2)
    | BInter a1 a2, _ => orb (decide_ssub_fuel n a1 b) (decide_ssub_fuel n a2 b)
    | BAtom x, BAtom y => orb (atom_le_b x y) (bty_eqb a b)
    | BArrow A1 B1, BArrow A2 B2 => andb (decide_ssub_fuel n A2 A1) (decide_ssub_fuel n B1 B2)
    | BRec f, BRec g => decide_srec (decide_ssub_fuel n) f g
    | _, _ => bty_eqb a b
    end.
Proof.
  intros n a b HbTop HaBot. simpl.
  destruct b; try reflexivity; try (exfalso; apply HbTop; reflexivity);
    destruct a; try reflexivity; try (exfalso; apply HaBot; reflexivity).
Qed.

(* Helper tactics applied per (a-head, b-head). The [b] order after excluding
   BTop is: Atom, Bot, Union, Inter, Neg, Rec, Arrow. *)

(* ============================ SOUNDNESS (unconditional) ===================== *)
Lemma decide_ssub_fuel_sound : forall n a b,
  decide_ssub_fuel n a b = true -> ssub a b.
Proof.
  intro n. induction n as [ | n IHn ]; intros a b Hd.
  - simpl in Hd. discriminate.
  - destruct (bty_eq_dec b BTop) as [HbTop | HbTop].
    { subst b. apply SsTop. }
    destruct (bty_eq_dec a BBot) as [HaBot | HaBot].
    { subst a. apply SsBot. }
    rewrite (decide_ssub_step n a b HbTop HaBot) in Hd.
    (* shorthand discharges for the connective-target clauses on a leaf [a]. *)
    destruct a as [ax| | |a1 a2|a1 a2|a1|af|A1 B1];
      try (exfalso; apply HaBot; reflexivity).
    + (* a = BAtom : b ∈ {Atom,Bot,Union,Inter,Neg,Rec,Arrow} *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity).
      * apply orb_true_iff in Hd. destruct Hd as [Hle | Heq].
        -- apply SsAtom. apply atom_le_b_true. exact Hle.
        -- apply bty_eqb_true in Heq. rewrite Heq. apply SsRefl.
      * apply bty_eqb_true in Hd. discriminate.       (* Bot *)
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Union *)
          [ apply SsUnionInL; apply IHn; exact H1 | apply SsUnionInR; apply IHn; exact H2 ].
      * apply andb_true_iff in Hd. destruct Hd as [H1 H2];   (* Inter *)
          apply SsInterI; [ apply IHn; exact H1 | apply IHn; exact H2 ].
      * apply bty_eqb_true in Hd. discriminate.       (* Neg *)
      * apply bty_eqb_true in Hd. discriminate.       (* Rec *)
      * apply bty_eqb_true in Hd. discriminate.       (* Arrow *)
    + (* a = BTop *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (apply bty_eqb_true in Hd; discriminate).
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Union *)
          [ apply SsUnionInL; apply IHn; exact H1 | apply SsUnionInR; apply IHn; exact H2 ].
      * apply andb_true_iff in Hd. destruct Hd as [H1 H2];   (* Inter *)
          apply SsInterI; [ apply IHn; exact H1 | apply IHn; exact H2 ].
    + (* a = BUnion: union-on-left elim *)
      apply andb_true_iff in Hd. destruct Hd as [H1 H2].
      apply SsUnionE; [ apply IHn; exact H1 | apply IHn; exact H2 ].
    + (* a = BInter *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity).
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Atom: inter-left *)
          [ apply SsInterPL; apply IHn; exact H1 | apply SsInterPR; apply IHn; exact H2 ].
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Bot: inter-left *)
          [ apply SsInterPL; apply IHn; exact H1 | apply SsInterPR; apply IHn; exact H2 ].
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Union: union-right *)
          [ apply SsUnionInL; apply IHn; exact H1 | apply SsUnionInR; apply IHn; exact H2 ].
      * apply andb_true_iff in Hd. destruct Hd as [H1 H2];   (* Inter: GLB *)
          apply SsInterI; [ apply IHn; exact H1 | apply IHn; exact H2 ].
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Neg: inter-left *)
          [ apply SsInterPL; apply IHn; exact H1 | apply SsInterPR; apply IHn; exact H2 ].
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Rec: inter-left *)
          [ apply SsInterPL; apply IHn; exact H1 | apply SsInterPR; apply IHn; exact H2 ].
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Arrow: inter-left *)
          [ apply SsInterPL; apply IHn; exact H1 | apply SsInterPR; apply IHn; exact H2 ].
    + (* a = BNeg *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (apply bty_eqb_true in Hd; rewrite Hd; apply SsRefl).
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Union *)
          [ apply SsUnionInL; apply IHn; exact H1 | apply SsUnionInR; apply IHn; exact H2 ].
      * apply andb_true_iff in Hd. destruct Hd as [H1 H2];   (* Inter *)
          apply SsInterI; [ apply IHn; exact H1 | apply IHn; exact H2 ].
    + (* a = BRec *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (apply bty_eqb_true in Hd; discriminate).
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Union *)
          [ apply SsUnionInL; apply IHn; exact H1 | apply SsUnionInR; apply IHn; exact H2 ].
      * apply andb_true_iff in Hd. destruct Hd as [H1 H2];   (* Inter *)
          apply SsInterI; [ apply IHn; exact H1 | apply IHn; exact H2 ].
      * apply SsRec. apply (decide_srec_sound (decide_ssub_fuel n) af bg);   (* Rec *)
          [ intros kk Tf Tg HinF HinG Hr; apply IHn; exact Hr | exact Hd ].
    + (* a = BArrow *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (apply bty_eqb_true in Hd; discriminate).
      * apply orb_true_iff in Hd. destruct Hd as [H1 | H2];   (* Union *)
          [ apply SsUnionInL; apply IHn; exact H1 | apply SsUnionInR; apply IHn; exact H2 ].
      * apply andb_true_iff in Hd. destruct Hd as [H1 H2];   (* Inter *)
          apply SsInterI; [ apply IHn; exact H1 | apply IHn; exact H2 ].
      * apply andb_true_iff in Hd. destruct Hd as [Hdom Hcod];   (* Arrow *)
          apply SsArrow; [ apply IHn; exact Hdom | apply IHn; exact Hcod ].
Qed.

(* ============= COMPLETENESS on the intersection-free fragment =============== *)
Lemma decide_ssub_fuel_complete : forall n a b,
  bsize a + bsize b <= n -> inter_free a -> inter_free b ->
  ssub a b -> decide_ssub_fuel n a b = true.
Proof.
  intro n. induction n as [ | n IHn ]; intros a b Hn Hifa Hifb Hs.
  - pose proof (bsize_pos a); pose proof (bsize_pos b); lia.
  - destruct (bty_eq_dec b BTop) as [HbTop | HbTop].
    { subst b. simpl. reflexivity. }
    destruct (bty_eq_dec a BBot) as [HaBot | HaBot].
    { subst a. simpl. destruct b; try reflexivity; exfalso; apply HbTop; reflexivity. }
    rewrite (decide_ssub_step n a b HbTop HaBot).
    destruct a as [ax| | |a1 a2|a1 a2|a1|af|A1 B1];
      try (exfalso; apply HaBot; reflexivity);
      try (simpl in Hifa; contradiction).
    + (* a = BAtom *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (simpl in Hifb; contradiction); simpl in Hn.
      * apply ssub_atom_atom in Hs. apply orb_true_iff.       (* Atom *)
        destruct Hs as [Hle | Heq];
          [ left; apply atom_le_b_true; exact Hle
          | right; subst; apply bty_eqb_true; reflexivity ].
      * exfalso. apply ssub_atom_super in Hs. exact Hs.       (* Bot *)
      * destruct Hifb as [Hb1 Hb2].                            (* Union *)
        pose proof (ssub_union_tgt_inv (BAtom ax) b1 b2 Hs) as Hinv. simpl in Hinv.
        apply orb_true_iff. destruct Hinv as [H1 | H2];
          [ left; apply (IHn (BAtom ax) b1); [ simpl in Hn |- *; lia | exact I | exact Hb1 | exact H1 ]
          | right; apply (IHn (BAtom ax) b2); [ simpl in Hn |- *; lia | exact I | exact Hb2 | exact H2 ] ].
      * exfalso. apply ssub_atom_super in Hs. exact Hs.       (* Neg *)
      * exfalso. eapply ssub_atom_not_rec; exact Hs.          (* Rec *)
      * exfalso. eapply ssub_atom_not_arrow; exact Hs.        (* Arrow *)
    + (* a = BTop *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (simpl in Hifb; contradiction); simpl in Hn;
        try (exfalso; apply ssub_top_super in Hs; simpl in Hs; exact Hs).
      * destruct Hifb as [Hb1 Hb2]. apply ssub_top_super in Hs. simpl in Hs.   (* Union *)
        apply orb_true_iff. destruct Hs as [H1 | H2];
          [ left; apply (IHn BTop b1); [ simpl in Hn |- *; lia | exact I | exact Hb1 | apply top_above_sound; exact H1 ]
          | right; apply (IHn BTop b2); [ simpl in Hn |- *; lia | exact I | exact Hb2 | apply top_above_sound; exact H2 ] ].
    + (* a = BUnion: union-on-left elim *)
      simpl in Hn. destruct Hifa as [Hifa1 Hifa2]. apply andb_true_iff. split;
        [ apply (IHn a1 b); [ simpl in Hn |- *; lia | exact Hifa1 | exact Hifb | eapply ssub_union_src_l; exact Hs ]
        | apply (IHn a2 b); [ simpl in Hn |- *; lia | exact Hifa2 | exact Hifb | eapply ssub_union_src_r; exact Hs ] ].
    + (* a = BNeg *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (simpl in Hifb; contradiction); simpl in Hn;
        try (apply (ssub_interneg_leaf (BNeg a1) _ I) in Hs; simpl in Hs;
             apply bty_eqb_true; symmetry; exact Hs).
      * destruct Hifb as [Hb1 Hb2].                            (* Union *)
        pose proof (ssub_union_tgt_inv (BNeg a1) b1 b2 Hs) as Hinv. simpl in Hinv.
        apply orb_true_iff. destruct Hinv as [H1 | H2];
          [ left; apply (IHn (BNeg a1) b1); [ simpl in Hn |- *; lia | exact Hifa | exact Hb1 | exact H1 ]
          | right; apply (IHn (BNeg a1) b2); [ simpl in Hn |- *; lia | exact Hifa | exact Hb2 | exact H2 ] ].
    + (* a = BRec *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (simpl in Hifb; contradiction); simpl in Hn.
      * exfalso. eapply ssub_rec_not_atom; exact Hs.          (* Atom *)
      * exfalso. apply ssub_rec_super in Hs. simpl in Hs. exact Hs.   (* Bot *)
      * destruct Hifb as [Hb1 Hb2].                            (* Union *)
        pose proof (ssub_union_tgt_inv (BRec af) b1 b2 Hs) as Hinv. simpl in Hinv.
        apply orb_true_iff. destruct Hinv as [H1 | H2];
          [ left; apply (IHn (BRec af) b1); [ simpl in Hn |- *; lia | exact Hifa | exact Hb1 | exact H1 ]
          | right; apply (IHn (BRec af) b2); [ simpl in Hn |- *; lia | exact Hifa | exact Hb2 | exact H2 ] ].
      * exfalso. apply ssub_rec_super in Hs. simpl in Hs. exact Hs.   (* Neg *)
      * assert (Hbud : forall k Tf Tg, In (k,Tf) af -> In (k,Tg) bg -> bsize Tf + bsize Tg <= n).   (* Rec *)
        { intros kk Tf Tg HinF HinG.
          pose proof (bsize_field_lt af kk Tf HinF) as HF;
          pose proof (bsize_field_lt bg kk Tg HinG) as HG; simpl in HF, HG; lia. }
        apply (decide_srec_complete (decide_ssub_fuel n) af bg).
        -- intros kk Tf Tg HinF HinG Hsf.
           apply (IHn Tf Tg);
             [ apply (Hbud kk Tf Tg HinF HinG)
             | clear -Hifa HinF;
               induction af as [ | [k0 T0] af' IHaf ]; simpl in *;
               [ contradiction
               | destruct Hifa as [HfT Hfr]; destruct HinF as [Heq | Hin];
                 [ injection Heq as <- <-; exact HfT | apply IHaf; [ exact Hfr | exact Hin ] ] ]
             | clear -Hifb HinG;
               induction bg as [ | [k0 T0] bg' IHbg ]; simpl in *;
               [ contradiction
               | destruct Hifb as [HfT Hfr]; destruct HinG as [Heq | Hin];
                 [ injection Heq as <- <-; exact HfT | apply IHbg; [ exact Hfr | exact Hin ] ] ]
             | exact Hsf ].
        -- exact (ssub_rec_to_srec af bg Hs).
      * exfalso. eapply ssub_rec_not_arrow; exact Hs.          (* Arrow *)
    + (* a = BArrow *)
      destruct b as [bx| | |b1 b2|b1 b2|b1|bg|A2 B2];
        try (exfalso; apply HbTop; reflexivity);
        try (simpl in Hifb; contradiction); simpl in Hn; simpl in Hifa.
      * exfalso. eapply ssub_arrow_not_atom; exact Hs.        (* Atom *)
      * exfalso. apply ssub_arrow_super in Hs. simpl in Hs. exact Hs.   (* Bot *)
      * destruct Hifb as [Hb1 Hb2].                            (* Union *)
        pose proof (ssub_union_tgt_inv (BArrow A1 B1) b1 b2 Hs) as Hinv. simpl in Hinv.
        apply orb_true_iff. destruct Hinv as [H1 | H2];
          [ left; apply (IHn (BArrow A1 B1) b1); [ simpl in Hn |- *; lia | simpl; exact Hifa | exact Hb1 | exact H1 ]
          | right; apply (IHn (BArrow A1 B1) b2); [ simpl in Hn |- *; lia | simpl; exact Hifa | exact Hb2 | exact H2 ] ].
      * exfalso. apply ssub_arrow_super in Hs. simpl in Hs. exact Hs.   (* Neg *)
      * exfalso. eapply ssub_arrow_not_rec; exact Hs.          (* Rec *)
      * destruct Hifa as [HifA1 HifB1]. destruct Hifb as [HifA2 HifB2].   (* Arrow *)
        apply ssub_arrow_inv in Hs. destruct Hs as [Hdom Hcod].
        apply andb_true_iff. split;
          [ apply (IHn A2 A1); [ simpl in Hn |- *; lia | exact HifA2 | exact HifA1 | exact Hdom ]
          | apply (IHn B1 B2); [ simpl in Hn |- *; lia | exact HifB1 | exact HifB2 | exact Hcod ] ].
Qed.

(* ===========================================================================
   7. THE EXPORTED THEOREMS — INCREMENT 12.

   [decide_ssub] is TOTAL and SOUND on the WHOLE of [BTy] (every accepted pair is
   a genuine [ssub], including all intersection/negation pairs). COMPLETENESS is
   exported on the INTERSECTION-FREE fragment [inter_free a /\ inter_free b]
   ([decide_ssub_complete]); the intersection-on-the-LEFT cross is the
   NON-DISTRIBUTIVE frontier and is DEFERRED (see the lemma comment + TODO.md).
   =========================================================================== *)

(* SOUNDNESS — UNCONDITIONAL, the load-bearing direction (the checker subsumes
   along [ssub], so a [decide_ssub]-true must be a real [ssub]). *)
Corollary decide_ssub_sound : forall a b, decide_ssub a b = true -> ssub a b.
Proof. intros a b H. unfold decide_ssub in H. apply decide_ssub_fuel_sound in H. exact H. Qed.

(* COMPLETENESS — on the intersection-free fragment. *)
Corollary decide_ssub_complete : forall a b,
  inter_free a -> inter_free b -> ssub a b -> decide_ssub a b = true.
Proof.
  intros a b Ha Hb H. unfold decide_ssub.
  apply decide_ssub_fuel_complete; [ apply Nat.le_refl | exact Ha | exact Hb | exact H ].
Qed.

(* The correctness iff, on the intersection-free fragment. *)
Theorem decide_ssub_correct : forall a b,
  inter_free a -> inter_free b -> (decide_ssub a b = true <-> ssub a b).
Proof.
  intros a b Ha Hb. split;
    [ apply decide_ssub_sound | apply decide_ssub_complete; assumption ].
Qed.

(* TOTAL on the fragment: [false] means NOT [ssub] (when both sides inter-free). *)
Corollary decide_ssub_false : forall a b,
  inter_free a -> inter_free b -> decide_ssub a b = false -> ~ ssub a b.
Proof.
  intros a b Ha Hb Hf Hs. apply (decide_ssub_complete a b Ha Hb) in Hs.
  rewrite Hs in Hf. discriminate.
Qed.

(* The sumbool form — a runnable decision procedure for [ssub] on the inter-free
   fragment (where the decider is complete, so [false] is a genuine refutation). *)
Definition ssub_dec (a b : BTy) (Ha : inter_free a) (Hb : inter_free b)
  : {ssub a b} + {~ ssub a b}.
Proof.
  destruct (decide_ssub a b) eqn:Hd.
  - left. apply decide_ssub_sound. exact Hd.
  - right. apply (decide_ssub_false a b Ha Hb). exact Hd.
Defined.

(* ===========================================================================
   8. [Compute] SANITY — non-vacuity: [decide_ssub] returns BOTH true and false
   on real cases, and decides EXACTLY [ssub].
   =========================================================================== *)

(* contravariant domain: Int <: Num, so (Num->Int) <: (Int->Int) is TRUE; the
   reverse (Int->Int) <: (Num->Int) is FALSE (you cannot widen the domain). *)
Example sanity_arrow_dom_true :
  decide_ssub (BArrow (BAtom ANum) (BAtom AInt)) (BArrow (BAtom AInt) (BAtom AInt)) = true.
Proof. reflexivity. Qed.

Example sanity_arrow_dom_false :
  decide_ssub (BArrow (BAtom AInt) (BAtom AInt)) (BArrow (BAtom ANum) (BAtom AInt)) = false.
Proof. reflexivity. Qed.

(* covariant codomain: (Int->Int) <: (Int->Num) TRUE; reverse FALSE. *)
Example sanity_arrow_cod_true :
  decide_ssub (BArrow (BAtom AInt) (BAtom AInt)) (BArrow (BAtom AInt) (BAtom ANum)) = true.
Proof. reflexivity. Qed.

Example sanity_arrow_cod_false :
  decide_ssub (BArrow (BAtom AInt) (BAtom ANum)) (BArrow (BAtom AInt) (BAtom AInt)) = false.
Proof. reflexivity. Qed.

(* WIDTH: {a:Int, b:Bool} <: {a:Int} TRUE; the reverse FALSE (missing field). *)
Example sanity_rec_width_true :
  decide_ssub (BRec [("a"%string, BAtom AInt); ("b"%string, BAtom ABool)])
              (BRec [("a"%string, BAtom AInt)]) = true.
Proof. reflexivity. Qed.

Example sanity_rec_width_false :
  decide_ssub (BRec [("a"%string, BAtom AInt)])
              (BRec [("a"%string, BAtom AInt); ("b"%string, BAtom ABool)]) = false.
Proof. reflexivity. Qed.

(* DEPTH: {a:Int} <: {a:Num} TRUE (Int<:Num); {a:Num} <: {a:Int} FALSE. *)
Example sanity_rec_depth_true :
  decide_ssub (BRec [("a"%string, BAtom AInt)]) (BRec [("a"%string, BAtom ANum)]) = true.
Proof. reflexivity. Qed.

Example sanity_rec_depth_false :
  decide_ssub (BRec [("a"%string, BAtom ANum)]) (BRec [("a"%string, BAtom AInt)]) = false.
Proof. reflexivity. Qed.

(* THE CRUX — [ssub] correctly REJECTS the operationally-unsound arrow/Top
   collapse that [dsub] admits: decide_ssub (Rec->Int) (Int->Top) = FALSE.
   (Contravariant domain demands Int <: Rec, which is false.) *)
Example sanity_rec_arrow_top_FALSE :
  decide_ssub (BArrow (BRec [("f"%string, BAtom AInt)]) (BAtom AInt))
              (BArrow (BAtom AInt) BTop) = false.
Proof. reflexivity. Qed.

(* atoms + Top/Bot *)
Example sanity_atom_true : decide_ssub (BAtom AInt) (BAtom ANum) = true.
Proof. reflexivity. Qed.
Example sanity_atom_false : decide_ssub (BAtom AStr) (BAtom AInt) = false.
Proof. reflexivity. Qed.
Example sanity_top : decide_ssub (BRec [("f"%string, BAtom AInt)]) BTop = true.
Proof. reflexivity. Qed.
Example sanity_bot : decide_ssub BBot (BArrow (BAtom AInt) (BAtom AInt)) = true.
Proof. reflexivity. Qed.
Example sanity_refl_connective :
  decide_ssub (BUnion (BAtom AInt) (BAtom AStr)) (BUnion (BAtom AInt) (BAtom AStr)) = true.
Proof. reflexivity. Qed.
(* INCREMENT 12 — INTERSECTION sanity. The decider now DECIDES intersection
   structurally: GLB on the right (full), projection on the left (sound). *)

(* PROJECTION (inter-on-left): Int∩Str <: Int (left projection) — now TRUE (the
   increment-11 decider returned false here; intersection is now a real rule). *)
Example sanity_inter_proj_l : decide_ssub (BInter (BAtom AInt) (BAtom AStr)) (BAtom AInt) = true.
Proof. reflexivity. Qed.
Example sanity_inter_proj_r : decide_ssub (BInter (BAtom AInt) (BAtom AStr)) (BAtom AStr) = true.
Proof. reflexivity. Qed.
(* GLB (inter-on-right): Int <: Int∩Int; Int <: Num∩Num (Int≤Num both sides). *)
Example sanity_inter_glb_refl : decide_ssub (BAtom AInt) (BInter (BAtom AInt) (BAtom AInt)) = true.
Proof. reflexivity. Qed.
Example sanity_inter_glb_num : decide_ssub (BAtom AInt) (BInter (BAtom ANum) (BAtom ANum)) = true.
Proof. reflexivity. Qed.
(* GLB rejects when a conjunct fails: Int ⊄ Int∩Str (Int ⊄ Str). *)
Example sanity_inter_glb_false : decide_ssub (BAtom AInt) (BInter (BAtom AInt) (BAtom AStr)) = false.
Proof. reflexivity. Qed.
(* NON-DISTRIBUTIVE frontier — a CONCRETE INCOMPLETENESS WITNESS (DEFERRED,
   honestly, and SOUND): [(Int∪Str)∩Bool <: Int∪Str] HOLDS in [ssub] (via
   [SsInterPL] from refl: [(Int∪Str)∩Bool <: Int∪Str]), yet [decide_ssub] returns
   FALSE on it — because the UNION-ON-RIGHT clause fires BEFORE the inter-on-left
   clause, reducing to [decide ((Int∪Str)∩Bool) Int OR ... Str], neither of which
   holds. This is exactly the inter-left / union-right CROSS = the distributivity
   gap (subtype.v's N5). The answer is SOUND (false never claims a subtyping); the
   LEFT type is NOT [inter_free], so this pair is OFF the completeness fragment —
   no false claim, just an honest "not decided". (Deciding it needs the
   emptiness/distributivity route — [dsub]/[gdecide].) *)
Example sanity_inter_union_cross_incomplete :
  decide_ssub (BInter (BUnion (BAtom AInt) (BAtom AStr)) (BAtom ABool))
              (BUnion (BAtom AInt) (BAtom AStr)) = false.
Proof. reflexivity. Qed.
(* yet the subtyping genuinely HOLDS (so this is incompleteness, not unsoundness). *)
Example sanity_inter_union_cross_holds :
  ssub (BInter (BUnion (BAtom AInt) (BAtom AStr)) (BAtom ABool))
       (BUnion (BAtom AInt) (BAtom AStr)).
Proof. apply SsInterPL. apply SsRefl. Qed.

(* INCREMENT 11 — UNION sanity. The decider now DECIDES union subtyping (intro on
   the right, elim on the left), no longer reflexive-only on [BUnion]. *)

(* INTRO: Int <: Int ∪ Str (left injection); Str <: Int ∪ Str (right). *)
Example sanity_union_intro_l : decide_ssub (BAtom AInt) (BUnion (BAtom AInt) (BAtom AStr)) = true.
Proof. reflexivity. Qed.
Example sanity_union_intro_r : decide_ssub (BAtom AStr) (BUnion (BAtom AInt) (BAtom AStr)) = true.
Proof. reflexivity. Qed.
(* a non-member: Bool ⊄ Int ∪ Str. *)
Example sanity_union_intro_false : decide_ssub (BAtom ABool) (BUnion (BAtom AInt) (BAtom AStr)) = false.
Proof. reflexivity. Qed.
(* ELIM (idempotence-style): Int ∪ Int <: Int. *)
Example sanity_union_elim_idem : decide_ssub (BUnion (BAtom AInt) (BAtom AInt)) (BAtom AInt) = true.
Proof. reflexivity. Qed.
(* ELIM with the atom order: Int ∪ Int <: Num (each branch ≤ Num). *)
Example sanity_union_elim_num : decide_ssub (BUnion (BAtom AInt) (BAtom AInt)) (BAtom ANum) = true.
Proof. reflexivity. Qed.
(* but Int ∪ Str ⊄ Num (Str ⊄ Num). *)
Example sanity_union_elim_false : decide_ssub (BUnion (BAtom AInt) (BAtom AStr)) (BAtom ANum) = false.
Proof. reflexivity. Qed.
(* the brief's case: Int <: Int ∪ Str = true; (Int ∪ Str) <: Num = false (Str). *)
Example sanity_union_intoNum_false : decide_ssub (BUnion (BAtom AInt) (BAtom AStr)) (BAtom ANum) = false.
Proof. reflexivity. Qed.
(* union–union: Int ∪ Str <: Str ∪ Int (commutativity, both directions). *)
Example sanity_union_comm :
  decide_ssub (BUnion (BAtom AInt) (BAtom AStr)) (BUnion (BAtom AStr) (BAtom AInt)) = true.
Proof. reflexivity. Qed.
(* union subtyping decides EXACTLY ssub (routes through decide_ssub_sound/false). *)
Example sanity_union_agree_true : ssub (BAtom AInt) (BUnion (BAtom AInt) (BAtom AStr)).
Proof. apply decide_ssub_sound. reflexivity. Qed.
Example sanity_union_agree_false : ~ ssub (BUnion (BAtom AInt) (BAtom AStr)) (BAtom ANum).
Proof. apply decide_ssub_false; [ simpl; tauto | simpl; tauto | reflexivity ]. Qed.

(* decides EXACTLY ssub: the true cases ARE ssub, the false cases are NOT. *)
Example sanity_agree_true : ssub (BArrow (BAtom ANum) (BAtom AInt)) (BArrow (BAtom AInt) (BAtom AInt)).
Proof. apply decide_ssub_sound. reflexivity. Qed.
Example sanity_agree_false :
  ~ ssub (BArrow (BRec [("f"%string, BAtom AInt)]) (BAtom AInt)) (BArrow (BAtom AInt) BTop).
Proof. apply decide_ssub_false; [ simpl; tauto | simpl; tauto | reflexivity ]. Qed.

(* ===========================================================================
   9. THE [ssub]-vs-[dsub] GAP — characterized.

   [ssub_sound] (typing.v): ssub ⊆ dsub. The inclusion is STRICT, and the gap is
   exactly the operationally-unsound subtypings [dsub] admits.
   =========================================================================== *)

(* (a) THE GAP WITNESS — a concrete [dsub]-but-not-[ssub] pair: the arrow/Top
   collapse. [dsub] admits it ([arrow_top_collapse], typing.v); [ssub] correctly
   rejects it (contravariant domain demands [ssub Int Rec], false). *)
Theorem dsub_ssub_gap :
  dsub (BArrow (BRec [("f"%string, BAtom AInt)]) (BAtom AInt))
       (BArrow (BAtom AInt) BTop)
  /\ ~ ssub (BArrow (BRec [("f"%string, BAtom AInt)]) (BAtom AInt))
            (BArrow (BAtom AInt) BTop).
Proof.
  split.
  - exact arrow_top_collapse.
  - apply decide_ssub_false; [ simpl; tauto | simpl; tauto | reflexivity ].
Qed.

(* (b) COINCIDENCE on the ATOM fragment — and a SECOND, PRECISE gap instance.

   On atoms [ssub] and [dsub] AGREE EXCEPT at the [AFloat]/[ANum] pair. On
   LuaJIT 5.1 [AFloat] and [ANum] both denote ALL numbers (float ≡ number), so
   [dsub (BAtom AFloat) (BAtom ANum)] and its converse BOTH hold semantically —
   but the SYNTACTIC atom order [atom_le] has NO edge between [AFloat] and [ANum]
   (only [AInt <: ANum] and [AInt <: AFloat]). So [ssub] does NOT relate them.
   This is a SECOND, atom-level instance of the [dsub]-strictly-coarser-than-
   [ssub] gap (the first being the arrow/Top collapse). It is the price of the
   syntactic relation tracking the DECLARED order rather than the value sets.

   We prove coincidence on the atoms EXCLUDING the [AFloat] endpoint, where the
   two relations agree exactly, and exhibit the [AFloat]/[ANum] gap separately. *)

Definition no_afloat (a : Atom) : Prop :=
  match a with AFloat => False | _ => True end.

(* a dsub between two NON-AFloat atoms forces the declared order / equality. *)
Lemma dsub_atom_atom_noafloat : forall x y,
  no_afloat x -> no_afloat y ->
  dsub (BAtom x) (BAtom y) -> ssub (BAtom x) (BAtom y).
Proof.
  intros x y Hx Hy H. unfold dsub in H.
  destruct x; destruct y; simpl in Hx, Hy; try contradiction;
    first
      [ apply SsRefl
      | apply SsAtom; (apply ALInt || apply ALIntF)
      | exfalso;
        first
          [ exact (H VNil I)
          | exact (H (VBool true) I)
          | exact (H (VInt 0) I)
          | exact (H (VNum (NRfrac 0)) I)
          | exact (H (VStr 0) I) ] ].
Qed.

(* COINCIDENCE on the AFloat-free atom fragment: ssub = dsub there. *)
Theorem ssub_dsub_coincide_atom : forall x y,
  no_afloat x -> no_afloat y ->
  (ssub (BAtom x) (BAtom y) <-> dsub (BAtom x) (BAtom y)).
Proof.
  intros x y Hx Hy. split.
  - intro Hs. apply ssub_sound. exact Hs.
  - apply dsub_atom_atom_noafloat; assumption.
Qed.

(* THE SECOND GAP INSTANCE — atom-level: AFloat ≡ ANum under dsub, but NOT under
   ssub (no declared edge). A concrete dsub-but-not-ssub pair among atoms. *)
Theorem dsub_ssub_gap_atom :
  dsub (BAtom AFloat) (BAtom ANum) /\ ~ ssub (BAtom AFloat) (BAtom ANum).
Proof.
  split.
  - (* AFloat ⊆ ANum: both denote all numbers *)
    unfold dsub. intros v Hv. destruct v as [r| | | | |]; simpl in Hv; try contradiction.
    simpl. exact I.
  - (* no ssub: decide_ssub returns false *)
    apply decide_ssub_false; [ simpl; tauto | simpl; tauto | reflexivity ].
Qed.

(* (c) COINCIDENCE direction in general: every [decide_ssub]-accepted pair IS a
   [dsub] (ssub ⊆ dsub via ssub_sound), so on the WHOLE structural fragment the
   decider's TRUE answers are sound for [dsub] too. *)
Corollary decide_ssub_implies_dsub : forall a b,
  decide_ssub a b = true -> dsub a b.
Proof.
  intros a b H. apply ssub_sound. apply decide_ssub_sound. exact H.
Qed.

(* ===========================================================================
   10. WIRING — the typing layer's [ssub] uses are now DECIDABLE.
   The subsumption rule [TSub] of typing.v fires [ssub S T]; [ssub_dec] / 
   [decide_ssub] is its executable counterpart. We expose the bridge directly:
   given a derivation [has_type G e S], whether it can be subsumed to [T] is
   decided by [decide_ssub S T].
   =========================================================================== *)

Theorem subsumption_decidable : forall G e S T,
  has_type G e S ->
  decide_ssub S T = true ->
  has_type G e T.
Proof.
  intros G e S T He Hd. eapply TSub; [ exact He | apply decide_ssub_sound; exact Hd ].
Qed.

(* and the negative side: if the decider says false on the INTERSECTION-FREE
   fragment (where it is complete), no subsumption step from S reaches T. (Off
   that fragment, [false] only means "not decided true" — the intersection-left /
   distributivity gap — so the refutation needs [inter_free].) *)
Theorem subsumption_step_undecidable_false : forall S T,
  inter_free S -> inter_free T -> decide_ssub S T = false -> ~ ssub S T.
Proof. intros S T HS HT. apply (decide_ssub_false S T HS HT). Qed.

(* ===========================================================================
   ASSUMPTION AUDIT — closed under the global context (no axioms/Admitted).
   =========================================================================== *)
Print Assumptions ssub_refl.
Print Assumptions ssub_trans.
Print Assumptions decide_ssub_sound.
Print Assumptions decide_ssub_complete.
Print Assumptions decide_ssub_correct.
Print Assumptions dsub_ssub_gap.
Print Assumptions dsub_ssub_gap_atom.
Print Assumptions ssub_dsub_coincide_atom.
