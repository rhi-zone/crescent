(* subtype.v — mechanized subtype kernel for crescent's value-set lattice.

   Correct-by-construction metatheory: the subtype relation is defined as an
   inductive Prop, and reflexivity + transitivity are PROVED (Qed, no Admitted,
   no added axioms). This is contributor/CI proof tooling — the shipped checker
   (bin/cr) does NOT depend on Rocq/Coq. See docs/proof-kernel.md.

   Compile (inside `nix develop`):  coqc proof/subtype.v
*)

From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.

(* ---- Base atoms with a declared sub-order ---------------------------------
   A tiny but real atom lattice: ANil, ABool, AInt, ANum, AStr, with the only
   non-trivial atom edge being AInt <: ANum (integers are a value-subset of
   numbers). Everything else is incomparable at the atom level. *)

Inductive Atom : Type :=
  | ANil
  | ABool
  | AInt
  | ANum
  | AStr.

(* Declared atom sub-order as a proper (non-reflexive) relation; SRefl in [sub]
   is the sole source of reflexivity so the atom order stays the genuine
   strict-edge data of the lattice. *)
Inductive atom_le : Atom -> Atom -> Prop :=
  | ALInt : atom_le AInt ANum.

(* ---- Types: atoms + lattice connectives ----------------------------------- *)

Inductive Ty : Type :=
  | TAtom  : Atom -> Ty
  | TTop   : Ty
  | TBot   : Ty
  | TUnion : Ty -> Ty -> Ty
  | TInter : Ty -> Ty -> Ty.

(* Structural size, used as the well-founded measure (on the CUT type) in the
   transitivity proof — see DESIGN LESSON #2. *)
Fixpoint tsize (t : Ty) : nat :=
  match t with
  | TAtom _ => 1
  | TTop => 1
  | TBot => 1
  | TUnion a b => S (tsize a + tsize b)
  | TInter a b => S (tsize a + tsize b)
  end.

(* ---- Subtype relation -----------------------------------------------------
   The union/intersection rules are stated in their TRANSITIVITY-ADMITTING
   (composable) form: each injection/projection rule carries a recursive
   premise. This is the central DESIGN LESSON of this increment (see the
   transitivity proof). The plain rules the brief asks for —

       A <: A∪B,   B <: A∪B,   A∩B <: A,   A∩B <: B

   — are NOT primitive here; they are RECOVERED as one-line lemmas
   (sub_union_inl, etc.) from the composable rules instantiated with SRefl. The
   elimination/introduction rules (SUnionE / SInterI) are exactly as in the
   declarative presentation. *)

Inductive sub : Ty -> Ty -> Prop :=
  (* reflexivity as a primitive (needed for compound types — see sub_refl) *)
  | SRefl  : forall t, sub t t
  (* lifted atom order *)
  | SAtom  : forall a b, atom_le a b -> sub (TAtom a) (TAtom b)
  (* Top is greatest, Bot is least *)
  | STop   : forall t, sub t TTop
  | SBot   : forall t, sub TBot t
  (* union: composable injections + elimination *)
  | SUnionInL : forall a b c, sub a b -> sub a (TUnion b c)
  | SUnionInR : forall a b c, sub a c -> sub a (TUnion b c)
  | SUnionE   : forall a b c, sub a c -> sub b c -> sub (TUnion a b) c
  (* intersection: dual — composable projections + introduction *)
  | SInterPL : forall a b c, sub a c -> sub (TInter a b) c
  | SInterPR : forall a b c, sub b c -> sub (TInter a b) c
  | SInterI  : forall a b c, sub c a -> sub c b -> sub c (TInter a b).

(* ---- Reflexivity ----------------------------------------------------------
   DESIGN LESSON #1: reflexivity at COMPOUND types does not follow from the
   union/inter rules alone — e.g. nothing builds [sub (TUnion a b) (TUnion a b)]
   bottom-up without already having reflexivity at a and b. So SRefl is a
   primitive constructor, and refl is then immediate. *)

Theorem sub_refl : forall t, sub t t.
Proof.
  intro t. apply SRefl.
Qed.

(* ---- The brief's plain injection/projection rules, as derived lemmas ------ *)

Lemma sub_union_inl : forall a b, sub a (TUnion a b).
Proof. intros a b. apply SUnionInL, SRefl. Qed.

Lemma sub_union_inr : forall a b, sub b (TUnion a b).
Proof. intros a b. apply SUnionInR, SRefl. Qed.

Lemma sub_inter_prl : forall a b, sub (TInter a b) a.
Proof. intros a b. apply SInterPL, SRefl. Qed.

Lemma sub_inter_prr : forall a b, sub (TInter a b) b.
Proof. intros a b. apply SInterPR, SRefl. Qed.

(* ---- Atom transitivity helper ---------------------------------------------
   The SAtom case of full transitivity has no induction hypothesis of its own
   (SAtom carries no sub-derivation), yet [sub (TAtom b) z] may inject into a
   union whose premise needs composing with the atom edge. We discharge that by
   induction on the SECOND derivation here, where the IH lines up. (The only
   atom edge is AInt<:ANum, so the SAtom-on-the-right subcase is vacuous.) *)
Lemma sub_atom_trans : forall a b z,
  atom_le a b -> sub (TAtom b) z -> sub (TAtom a) z.
Proof.
  intros a b z Hab Hbz.
  remember (TAtom b) as tb eqn:Etb.
  revert a b Hab Etb.
  induction Hbz; intros a' b' Hab Etb; try discriminate Etb.
  - (* SRefl: t = TAtom b' *)
    rewrite Etb. apply SAtom; assumption.
  - (* SAtom a b: compose edges; vacuous given the single edge *)
    injection Etb as <-. inversion Hab; subst. inversion H.
  - (* STop *) apply STop.
  - (* SUnionInL *) apply SUnionInL. apply IHHbz with (b := b'); assumption.
  - (* SUnionInR *) apply SUnionInR. apply IHHbz with (b := b'); assumption.
  - (* SInterI *)
    apply SInterI;
      [ apply IHHbz1 with (b := b') | apply IHHbz2 with (b := b') ]; assumption.
Qed.

(* ---- Top-on-the-left helper -----------------------------------------------
   Same shape of gap as the atom helper: the STop case of full transitivity has
   no IH, but [sub TTop z] can inject into a union/intersection whose premise
   needs composing. If Top is below z, then z is above EVERYTHING — proved by
   induction on the derivation [sub TTop z]. *)
Lemma sub_top_above : forall z, sub TTop z -> forall x, sub x z.
Proof.
  intros z Htz.
  remember TTop as tt eqn:Ett.
  induction Htz; intros x'; subst; try discriminate Ett.
  - (* SRefl: z = TTop *) apply STop.
  - (* STop: z = TTop *) apply STop.
  - (* SUnionInL *) apply SUnionInL. apply IHHtz; reflexivity.
  - (* SUnionInR *) apply SUnionInR. apply IHHtz; reflexivity.
  - (* SInterI *)
    apply SInterI; [ apply IHHtz1 | apply IHHtz2 ]; reflexivity.
Qed.

(* ---- Union/intersection one-sided composition helpers ---------------------
   These are the inversion/projection lemmas that the SUnionIn* / SInterP* cases
   of full transitivity need. Each says a component composes through the whole
   connective, and each is proved by induction on the SECOND derivation (where
   the IH lines up at a strictly-smaller derivation). They are the
   transitivity-admitting payoff made concrete: with the composable rules, these
   are routine inductions; with the naive rules they would each re-hit the
   same cut-type-doesn't-shrink wall. *)

Lemma sub_union_l : forall a b z, sub (TUnion a b) z -> sub a z.
Proof.
  intros a b z H. remember (TUnion a b) as u eqn:Eu.
  revert a b Eu. induction H; intros a' b' Eu; try discriminate Eu.
  - rewrite Eu. apply sub_union_inl.
  - apply STop.
  - apply SUnionInL. eapply IHsub; eassumption.
  - apply SUnionInR. eapply IHsub; eassumption.
  - injection Eu as <- <-. assumption.        (* SUnionE: left premise is sub a z *)
  - apply SInterI; [ eapply IHsub1 | eapply IHsub2 ]; eassumption.
Qed.

Lemma sub_union_r : forall a b z, sub (TUnion a b) z -> sub b z.
Proof.
  intros a b z H. remember (TUnion a b) as u eqn:Eu.
  revert a b Eu. induction H; intros a' b' Eu; try discriminate Eu.
  - rewrite Eu. apply sub_union_inr.
  - apply STop.
  - apply SUnionInL. eapply IHsub; eassumption.
  - apply SUnionInR. eapply IHsub; eassumption.
  - injection Eu as <- <-. assumption.        (* SUnionE: right premise is sub b z *)
  - apply SInterI; [ eapply IHsub1 | eapply IHsub2 ]; eassumption.
Qed.

(* ---- Transitivity ---------------------------------------------------------
   DESIGN LESSON #2 (the real payoff of this increment): with the NAIVE rules
   (plain [A∩B <: A] etc. as no-premise constructors), transitivity is NOT
   provable by structural induction — neither induction on a derivation nor on
   the cut type is well-founded, because e.g.

       sub (TInter (TAtom a) q) (TAtom a)      [projection, no premise]
       sub (TAtom a) z
       --------------------------------------- ?
       sub (TInter (TAtom a) q) z

   needs to compose at cut type [TAtom a], which is no smaller than the cut type
   we started with. Empirically (eauto fanned out to 76 irreducible goals) the
   naive formulation does not close.

   TWO fixes were both needed (this is the honest, hard-won lesson):

   (1) State the injection/projection rules in COMPOSABLE form (each with a
       recursive premise: [sub a c -> sub (TInter a b) c] rather than
       [sub (TInter a b) a]). The plain rules the brief specifies are then
       DERIVED lemmas (sub_inter_prl etc.). This is what lets the inversion
       lemmas (sub_union_l/r, sub_atom_trans, sub_top_above) go through.

   (2) Even so, the SInterI case followed by an intersection-projection on the
       right composes at cut type [a] (a strict sub-term of the cut [TInter a b])
       — so a plain structural induction is STILL not well-founded. Transitivity
       therefore needs STRONG induction on the SIZE of the cut type [tsize b].
       The strong IH supplies the recursion at the strictly-smaller cut.

   So: composable rules make most cases routine; the size measure closes the one
   irreducibly recursive case. Reflexivity is one rule; transitivity is real
   metatheory. That asymmetry is the lesson worth carrying to the next stage. *)

(* We prove transitivity by STRONG (well-founded) induction on the size of the
   CUT type b. The atom/Top/union helpers above discharge the cases whose cut is
   an atom / Top / union (those compose without a smaller-cut recursion). The
   genuinely recursive case is SInterI followed by a union-injection on the
   right: it reduces to composing at cut type [a] (a strict sub-term of the
   intersection cut [TInter a b]) — which is exactly the strictly-smaller-cut
   the strong IH provides. This is why a plain structural induction is not enough
   and the size measure is needed (DESIGN LESSON #2). *)
Theorem sub_trans : forall n x b z,
  tsize b <= n -> sub x b -> sub b z -> sub x z.
Proof.
  induction n as [ | n IHn ]; intros x b z Hn Hxb Hbz.
  - (* tsize b <= 0 is impossible: every type has size >= 1 *)
    destruct b; simpl in Hn; lia.
  - (* induction on the FIRST derivation; the strong IH IHn is used only in the
       SInterI/union-injection case at a strictly-smaller cut. *)
    revert z Hbz. induction Hxb; intros z' Hbz.
    + (* SRefl *) exact Hbz.
    + (* SAtom *) apply sub_atom_trans with (b := b); assumption.
    + (* STop *) apply sub_top_above; assumption.
    + (* SBot *) apply SBot.
    + (* SUnionInL: push second derivation onto left component, then IHHxb *)
      apply IHHxb; [ simpl in Hn; lia | apply sub_union_l with (b := c); assumption ].
    + (* SUnionInR: onto right component *)
      apply IHHxb; [ simpl in Hn; lia | apply sub_union_r with (a := b); assumption ].
    + (* SUnionE *)
      apply SUnionE;
        [ apply IHHxb1 | apply IHHxb2 ]; (simpl in Hn; lia) || assumption.
    + (* SInterPL: sub a c => sub (TInter a b) c; cut at c. *)
      apply SInterPL.
      apply IHHxb; [ simpl in Hn; lia | assumption ].
    + (* SInterPR *)
      apply SInterPR.
      apply IHHxb; [ simpl in Hn; lia | assumption ].
    + (* SInterI: sub c a, sub c b => sub c (TInter a b); then sub (TInter a b) z'.
         Invert the second derivation. The SUnionInL/SUnionInR subcases recurse
         at cut type [TInter a b] but on a STRICTLY SMALLER second derivation,
         so we use IHHxb-style recursion; the projection subcases drop to cut [a]
         or [b] — strictly smaller types — handled by the strong IH IHn. *)
      remember (TInter a b) as i eqn:Ei.
      induction Hbz; try discriminate Ei.
      * (* SRefl: z = TInter a b *) rewrite Ei. apply SInterI; assumption.
      * (* STop *) apply STop.
      * (* SUnionInL *) apply SUnionInL. apply IHHbz; assumption.
      * (* SUnionInR *) apply SUnionInR. apply IHHbz; assumption.
      * (* SInterPL: premise sub a0 z, with TInter a0 b0 = TInter a b => a0=a.
           Need sub c z from sub c a (Hxb1) and sub a z; cut at [a], smaller. *)
        injection Ei as Ea Eb. subst.
        apply IHn with (b := a); [ | assumption | assumption ].
        simpl in Hn; lia.
      * (* SInterPR: symmetric, cut at [b]. *)
        injection Ei as Ea Eb. subst.
        apply IHn with (b := b); [ | assumption | assumption ].
        simpl in Hn; lia.
      * (* SInterI on the right: rebuild *)
        apply SInterI; [ apply IHHbz1 | apply IHHbz2 ]; assumption.
Qed.

(* The clean external statement: transitivity, with the size accountant erased. *)
Corollary sub_trans' : forall x b z, sub x b -> sub b z -> sub x z.
Proof.
  intros x b z. apply (sub_trans (tsize b)). apply Nat.le_refl.
Qed.
