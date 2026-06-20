(* subtype.v — mechanized subtype kernel for crescent's value-set lattice.

   Correct-by-construction metatheory: the subtype relation is defined as an
   inductive Prop, and reflexivity + transitivity are PROVED (Qed, no Admitted,
   no added axioms). This is contributor/CI proof tooling — the shipped checker
   (bin/cr) does NOT depend on Rocq/Coq. See docs/proof-kernel.md.

   Compile (inside `nix develop`):  coqc proof/subtype.v
*)

From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
From Stdlib Require Import List.
From Stdlib Require Import Bool.
From Stdlib Require Import String.
Import ListNotations.

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

(* ===========================================================================
   INCREMENT 2 — the type algebra is a distributive lattice up to subtype
   equivalence.

   Nothing below changes the [sub] rules of increment 1: every law is derived
   from the existing constructors + refl/trans. The lub/glb are the union/inter
   connectives; the laws are stated up to [tequiv] (mutual subtyping), never up
   to syntactic [=], because e.g. [TUnion a b] and [TUnion b a] are NOT equal
   terms — they are only subtype-equivalent.
   =========================================================================== *)

(* ---- Type equivalence: mutual subtyping ----------------------------------- *)

Definition tequiv (a b : Ty) : Prop := sub a b /\ sub b a.

(* An equivalence relation, reusing sub_refl / sub_trans'. *)

Theorem tequiv_refl : forall a, tequiv a a.
Proof. intro a. split; apply sub_refl. Qed.

Theorem tequiv_sym : forall a b, tequiv a b -> tequiv b a.
Proof. intros a b [Hab Hba]. split; assumption. Qed.

Theorem tequiv_trans : forall a b c, tequiv a b -> tequiv b c -> tequiv a c.
Proof.
  intros a b c [Hab Hba] [Hbc Hcb].
  split; eapply sub_trans'; eassumption.
Qed.

(* ---- Union is the least upper bound, Inter the greatest lower bound -------- *)

(* Upper/lower bound parts: the injections/projections (already derived above). *)
(*   sub_union_inl : sub a (TUnion a b)
     sub_union_inr : sub b (TUnion a b)
     sub_inter_prl : sub (TInter a b) a
     sub_inter_prr : sub (TInter a b) b *)

(* Least: any common upper bound dominates the union. *)
Theorem union_lub : forall a b c, sub a c -> sub b c -> sub (TUnion a b) c.
Proof. intros a b c Hac Hbc. apply SUnionE; assumption. Qed.

(* Greatest: any common lower bound is dominated by the intersection. *)
Theorem inter_glb : forall a b c, sub c a -> sub c b -> sub c (TInter a b).
Proof. intros a b c Hca Hcb. apply SInterI; assumption. Qed.

(* ---- Helpers: congruence of the connectives under sub --------------------- *)
(* If components are pointwise ordered, so are the connectives. These follow
   from lub/glb + the injections, and make the law proofs one-liners. *)

Lemma union_mono : forall a a' b b',
  sub a a' -> sub b b' -> sub (TUnion a b) (TUnion a' b').
Proof.
  intros a a' b b' Ha Hb.
  apply union_lub.
  - eapply sub_trans'; [ exact Ha | apply sub_union_inl ].
  - eapply sub_trans'; [ exact Hb | apply sub_union_inr ].
Qed.

Lemma inter_mono : forall a a' b b',
  sub a a' -> sub b b' -> sub (TInter a b) (TInter a' b').
Proof.
  intros a a' b b' Ha Hb.
  apply inter_glb.
  - eapply sub_trans'; [ apply sub_inter_prl | exact Ha ].
  - eapply sub_trans'; [ apply sub_inter_prr | exact Hb ].
Qed.

(* ---- Commutativity -------------------------------------------------------- *)

Theorem union_comm : forall a b, tequiv (TUnion a b) (TUnion b a).
Proof.
  intros a b. split; apply union_lub;
    (apply sub_union_inl || apply sub_union_inr).
Qed.

Theorem inter_comm : forall a b, tequiv (TInter a b) (TInter b a).
Proof.
  intros a b. split; apply inter_glb;
    (apply sub_inter_prl || apply sub_inter_prr).
Qed.

(* ---- Associativity -------------------------------------------------------- *)

Theorem union_assoc : forall a b c,
  tequiv (TUnion (TUnion a b) c) (TUnion a (TUnion b c)).
Proof.
  intros a b c. split.
  - apply union_lub; [ apply union_lub | ].
    + apply sub_union_inl.
    + apply sub_trans' with (b := TUnion b c);
        [ apply sub_union_inl | apply sub_union_inr ].
    + apply sub_trans' with (b := TUnion b c);
        [ apply sub_union_inr | apply sub_union_inr ].
  - apply union_lub; [ | apply union_lub ].
    + apply sub_trans' with (b := TUnion a b);
        [ apply sub_union_inl | apply sub_union_inl ].
    + apply sub_trans' with (b := TUnion a b);
        [ apply sub_union_inr | apply sub_union_inl ].
    + apply sub_union_inr.
Qed.

Theorem inter_assoc : forall a b c,
  tequiv (TInter (TInter a b) c) (TInter a (TInter b c)).
Proof.
  intros a b c. split.
  - apply inter_glb; [ | apply inter_glb ].
    + eapply sub_trans'; [ apply sub_inter_prl | apply sub_inter_prl ].
    + eapply sub_trans'; [ apply sub_inter_prl | apply sub_inter_prr ].
    + apply sub_inter_prr.
  - apply inter_glb; [ apply inter_glb | ].
    + apply sub_inter_prl.
    + eapply sub_trans'; [ apply sub_inter_prr | apply sub_inter_prl ].
    + eapply sub_trans'; [ apply sub_inter_prr | apply sub_inter_prr ].
Qed.

(* ---- Idempotence ---------------------------------------------------------- *)

Theorem union_idem : forall a, tequiv (TUnion a a) a.
Proof.
  intro a. split.
  - apply union_lub; apply sub_refl.
  - apply sub_union_inl.
Qed.

Theorem inter_idem : forall a, tequiv (TInter a a) a.
Proof.
  intro a. split.
  - apply sub_inter_prl.
  - apply inter_glb; apply sub_refl.
Qed.

(* ---- Absorption ----------------------------------------------------------- *)

Theorem absorb_union_inter : forall a b, tequiv (TUnion a (TInter a b)) a.
Proof.
  intros a b. split.
  - apply union_lub; [ apply sub_refl | apply sub_inter_prl ].
  - apply sub_union_inl.
Qed.

Theorem absorb_inter_union : forall a b, tequiv (TInter a (TUnion a b)) a.
Proof.
  intros a b. split.
  - apply sub_inter_prl.
  - apply inter_glb; [ apply sub_refl | apply sub_union_inl ].
Qed.

(* ---- Distributivity — and a machine-checked NEGATIVE result ---------------

   DESIGN LESSON #3 (the real finding of this increment).

   For BOTH distributive laws, ONE direction holds in every lattice and is
   proved below to Qed:

       (a∩b) ∪ (a∩c)  ≤  a ∩ (b∪c)            [union of meets below the meet]
       a ∪ (b∩c)      ≤  (a∪b) ∩ (a∪c)         [the join below the meet of joins]

   The OTHER direction — the inequality whose two directions TOGETHER would make
   the lattice distributive — is *NOT derivable* from the increment-1 [sub]
   rules. This is not a proof-search failure on our part: the rules of [sub]
   generate exactly the *free LATTICE* preorder over the atom poset, and the
   free lattice on three incomparable generators is the non-distributive lattice
   — distributivity is precisely the law a free lattice lacks.

   We do not paper over this with [Admitted]. We PROVE the unprovability, by
   exhibiting a sound model in which the law fails: the pentagon N5, the minimal
   non-distributive lattice. [interp] maps every [Ty] into N5; [interp_sound]
   shows every [sub] edge maps to a true N5 order-fact (so anything derivable in
   [sub] holds in N5); and the specific distributive instance maps to the false
   N5 fact [n5le NB NA = false]. Hence that instance is underivable — a positive
   theorem ([distrib_hard_unprovable]), Qed, closed under the global context.

   PRINCIPLED RESOLUTION (deferred, by design — a genuine fork, not a fudge):
   making the lattice distributive requires *either* adding a general
   distributivity rule to [sub] (which forces re-deriving transitivity under the
   new rule — a substrate change to increment 1, out of scope here), *or* moving
   to the value-set semantics (coarser still: there [TInter AInt AStr] ≡ Bot,
   which [sub] also does not prove). Both are their own increments. The honest
   state recorded here: the algebra is a (proved) LATTICE up to [tequiv]; it is
   provably NOT a distributive lattice under the current rules. See
   docs/proof-kernel.md. *)

(* The free-lattice direction of each law (holds unconditionally). *)

Theorem distrib_inter_union_ge : forall a b c,
  sub (TUnion (TInter a b) (TInter a c)) (TInter a (TUnion b c)).
Proof.
  intros a b c.
  apply union_lub; apply inter_mono;
    (apply sub_refl || apply sub_union_inl || apply sub_union_inr).
Qed.

Theorem distrib_union_inter_le : forall a b c,
  sub (TUnion a (TInter b c)) (TInter (TUnion a b) (TUnion a c)).
Proof.
  intros a b c.
  apply inter_glb; apply union_mono;
    (apply sub_refl || apply sub_inter_prl || apply sub_inter_prr).
Qed.

(* ---- N5 pentagon model: sound for [sub], non-distributive ------------------
   Elements: B0 < NA < NB < T1 ; B0 < NC < T1 ; {NA,NB} incomparable to NC.
   Order and ops are given as total functions and verified by exhaustive
   case analysis (5 elements). *)

Inductive N5 := B0 | NA | NB | NC | T1.

Definition n5le (x y : N5) : bool :=
  match x, y with
  | B0, _ => true | _, T1 => true
  | NA, NA => true | NA, NB => true | NB, NB => true | NC, NC => true
  | _, _ => false end.

Definition n5meet (x y : N5) : N5 :=
  match x, y with
  | B0, _ | _, B0 => B0 | T1, z | z, T1 => z
  | NA, NA => NA | NB, NB => NB | NC, NC => NC
  | NA, NB | NB, NA => NA | NA, NC | NC, NA => B0 | NB, NC | NC, NB => B0 end.

Definition n5join (x y : N5) : N5 :=
  match x, y with
  | T1, _ | _, T1 => T1 | B0, z | z, B0 => z
  | NA, NA => NA | NB, NB => NB | NC, NC => NC
  | NA, NB | NB, NA => NB | NA, NC | NC, NA => T1 | NB, NC | NC, NB => T1 end.

(* Atom interpretation: AInt↦NA, ANum↦NB, AStr↦NC (so the sole atom edge
   AInt<:ANum maps to NA ≤ NB), the rest to bottom. *)
Definition iatom (a : Atom) : N5 :=
  match a with AInt => NA | ANum => NB | AStr => NC | _ => B0 end.

Fixpoint interp (t : Ty) : N5 :=
  match t with
  | TAtom a => iatom a | TTop => T1 | TBot => B0
  | TUnion a b => n5join (interp a) (interp b)
  | TInter a b => n5meet (interp a) (interp b) end.

Lemma n5le_refl : forall x, n5le x x = true. Proof. destruct x; reflexivity. Qed.
Lemma n5le_top  : forall x, n5le x T1 = true. Proof. destruct x; reflexivity. Qed.
Lemma n5join_l : forall x y z, n5le x y = true -> n5le x (n5join y z) = true.
Proof. intros x y z; destruct x,y,z; simpl; auto. Qed.
Lemma n5join_r : forall x y z, n5le x z = true -> n5le x (n5join y z) = true.
Proof. intros x y z; destruct x,y,z; simpl; auto. Qed.
Lemma n5join_e : forall x y z, n5le x z = true -> n5le y z = true -> n5le (n5join x y) z = true.
Proof. intros x y z; destruct x,y,z; simpl; auto. Qed.
Lemma n5meet_l : forall x y z, n5le x z = true -> n5le (n5meet x y) z = true.
Proof. intros x y z; destruct x,y,z; simpl; auto. Qed.
Lemma n5meet_r : forall x y z, n5le y z = true -> n5le (n5meet x y) z = true.
Proof. intros x y z; destruct x,y,z; simpl; auto. Qed.
Lemma n5meet_i : forall x y z, n5le x y = true -> n5le x z = true -> n5le x (n5meet y z) = true.
Proof. intros x y z; destruct x,y,z; simpl; auto. Qed.

(* Soundness: every [sub] edge is a true order-fact in N5. *)
Theorem interp_sound : forall a b, sub a b -> n5le (interp a) (interp b) = true.
Proof.
  intros a b H. induction H; simpl.
  - apply n5le_refl.
  - destruct H; reflexivity.        (* SAtom: only AInt<:ANum, i.e. NA ≤ NB *)
  - apply n5le_top.
  - reflexivity.                    (* SBot: B0 ≤ everything *)
  - apply n5join_l; assumption.
  - apply n5join_r; assumption.
  - apply n5join_e; assumption.
  - apply n5meet_l; assumption.
  - apply n5meet_r; assumption.
  - apply n5meet_i; assumption.
Qed.

(* The hard direction of inter-over-union distributivity is UNDERIVABLE.
   Instance: a:=ANum(NB), b:=AInt(NA), c:=AStr(NC).
     interp LHS = NB ∧ (NA ∨ NC) = NB ∧ T1 = NB
     interp RHS = (NB∧NA) ∨ (NB∧NC) = NA ∨ B0 = NA
     n5le NB NA = false  ⇒  no [sub] derivation exists. *)
Theorem distrib_inter_union_le_unprovable :
  ~ sub (TInter (TAtom ANum) (TUnion (TAtom AInt) (TAtom AStr)))
        (TUnion (TInter (TAtom ANum) (TAtom AInt))
                (TInter (TAtom ANum) (TAtom AStr))).
Proof.
  intro H. apply interp_sound in H. simpl in H. discriminate H.
Qed.

(* Dually, the hard direction of union-over-inter is also UNDERIVABLE.
   Instance: a:=AInt(NA), b:=AStr(NC), c:=ANum(NB).
     interp LHS = (NA∨NC) ∧ (NA∨NB) = T1 ∧ NB = NB
     interp RHS = NA ∨ (NC∧NB) = NA ∨ B0 = NA
     n5le NB NA = false. *)
Theorem distrib_union_inter_ge_unprovable :
  ~ sub (TInter (TUnion (TAtom AInt) (TAtom AStr))
                (TUnion (TAtom AInt) (TAtom ANum)))
        (TUnion (TAtom AInt) (TInter (TAtom AStr) (TAtom ANum))).
Proof.
  intro H. apply interp_sound in H. simpl in H. discriminate H.
Qed.

(* ===========================================================================
   INCREMENT 3 — the SEMANTIC PIVOT: a Boolean algebra of types.

   The free-lattice [sub] of increments 1-2 is PROVABLY non-distributive (the
   N5 result above). Distributivity, De Morgan, complement, double-negation —
   the laws a real type lattice needs — are NOT theorems of any free lattice.
   We therefore stop axiomatizing the order and DEFINE subtyping semantically:
   a type denotes a SET of values, and [A <: B] means [denote A ⊆ denote B].
   Every Boolean-algebra law then collapses to first-order logic over the
   denotation — no [sub] rule is asserted, no axiom is added, and the laws the
   free lattice could not give become theorems for free.

   The old inductive [sub] is RETAINED above as the future *algorithmic*
   relation (to be proven sound + complete against [dsub] in a later stage).
   [dsub] is primary from here on. See docs/proof-kernel.md roadmap.

   --- The model construction (disjointness + order are CONSTRUCTIVE) ---------

   Values live in a concrete inductive domain [V] whose constructors are the
   ground value-kinds. Each constructor is a DISTINCT head, so the denotations
   of unrelated atoms are disjoint *by construction* — disjointness is decided
   by Coq's [discriminate] on constructor heads, not asserted as an axiom.

   The base order [AInt <: ANum] is likewise baked into the denotation, not
   asserted: numbers split into integer values ([VInt]) and non-integer numeric
   values ([VFloat]); [atom_denote ANum] accepts BOTH, [atom_denote AInt]
   accepts only [VInt]. So [denote (atom AInt) v -> denote (atom ANum) v] holds
   definitionally (the [VInt] disjunct of ANum is exactly AInt's denotation),
   while the converse fails because [VFloat] inhabits ANum but not AInt.
   =========================================================================== *)

(* ---- Extend the type syntax with negation (Boolean algebra) ---------------- *)

Inductive BTy : Type :=
  | BAtom  : Atom -> BTy
  | BTop   : BTy
  | BBot   : BTy
  | BUnion : BTy -> BTy -> BTy
  | BInter : BTy -> BTy -> BTy
  | BNeg   : BTy -> BTy
  (* INCREMENT 5 — record/table types. A finite assoc-list of string keys to
     field types. Read OPEN / WIDTH (standard structural subtyping): a value is
     in [BRec fields] iff it is a table that has, for every listed (k,T), some
     value at key k inhabiting T — OTHER keys are allowed. Closed/exact records
     and index signatures are DEFERRED. *)
  | BRec   : list (string * BTy) -> BTy.

(* ---- The value domain -----------------------------------------------------
   Distinct constructor heads => unrelated atoms denote disjoint sets, decided
   structurally. [VInt]/[VFloat] are the two numeric kinds; their union is the
   number kind, [VInt] alone is the integer kind. *)

Inductive V : Type :=
  | VInt   : nat -> V          (* an integer value: inhabits AInt AND ANum *)
  | VFloat : nat -> V          (* a non-integer number: inhabits ANum only  *)
  | VStr   : nat -> V          (* a string value:  inhabits AStr only       *)
  | VBool  : bool -> V         (* a boolean value: inhabits ABool only      *)
  | VNil   : V                 (* nil:             inhabits ANil only        *)
  (* INCREMENT 5 — table values. A FINITE assoc-list of string keys to
     sub-values. V stays a (nested) INDUCTIVE: VTable carries a list whose
     elements are structurally smaller, so it is well-founded. Cyclic /
     self-referential tables are DEFERRED to the future equirecursive-μ
     increment (they would force a coinductive V — a real fork we do not take
     here). *)
  | VTable : list (string * V) -> V.

(* ---- Finite key lookup in a table ----------------------------------------- *)

Fixpoint assoc_lookup (k : string) (ents : list (string * V)) : option V :=
  match ents with
  | [] => None
  | (k', v) :: rest => if string_dec k k' then Some v else assoc_lookup k rest
  end.

(* ---- A usable induction principle for the nested-inductive V --------------
   The auto-generated [V_ind] gives NO induction hypothesis for the sub-values
   inside a [VTable] (Coq does not look through the nested [list]). We hand-roll
   the mutual scheme: a property [P] on values together with a property [Pl] on
   field-lists, with the IH available element-wise. This is the standard
   nested-inductive idiom — not an axiom, a plain [Fixpoint]. *)
Section V_ind_strong.
  Variable P  : V -> Prop.
  Variable Pl : list (string * V) -> Prop.
  Hypothesis HInt   : forall n, P (VInt n).
  Hypothesis HFloat : forall n, P (VFloat n).
  Hypothesis HStr   : forall n, P (VStr n).
  Hypothesis HBool  : forall b, P (VBool b).
  Hypothesis HNil   : P VNil.
  Hypothesis HTable : forall l, Pl l -> P (VTable l).
  Hypothesis Hnil   : Pl [].
  Hypothesis Hcons  : forall k v rest, P v -> Pl rest -> Pl ((k, v) :: rest).
  Fixpoint V_rect_strong (v : V) : P v :=
    match v with
    | VInt n   => HInt n
    | VFloat n => HFloat n
    | VStr n   => HStr n
    | VBool b  => HBool b
    | VNil     => HNil
    | VTable l =>
        HTable l
          ((fix go (l : list (string * V)) : Pl l :=
              match l with
              | [] => Hnil
              | (k, vv) :: rest => Hcons k vv rest (V_rect_strong vv) (go rest)
              end) l)
    end.
End V_ind_strong.

(* ---- Atom denotation ------------------------------------------------------
   Order and disjointness are visible right here, in the value-set membership,
   never imposed from outside. ANum's set is {VInt n} ∪ {VFloat n}; AInt's set
   is {VInt n} — a literal subset. The other atoms pick their own constructor.
   Note [VTable] inhabits NO atom (every atom branch sends it to [False]) — a
   table is structurally not a scalar. *)

Definition atom_denote (a : Atom) (v : V) : Prop :=
  match a with
  | ANil  => match v with VNil    => True | _ => False end
  | ABool => match v with VBool _ => True | _ => False end
  | AInt  => match v with VInt _  => True | _ => False end
  | ANum  => match v with VInt _ | VFloat _ => True | _ => False end
  | AStr  => match v with VStr _  => True | _ => False end
  end.

(* ---- The denotation: types are predicates over V (i.e. sets of values) ---- *)

Fixpoint denote (t : BTy) (v : V) : Prop :=
  match t with
  | BAtom a    => atom_denote a v
  | BTop       => True
  | BBot       => False
  | BUnion a b => denote a v \/ denote b v
  | BInter a b => denote a v /\ denote b v
  | BNeg a     => ~ denote a v
  (* OPEN / WIDTH record membership: v is some table [ents], and every LISTED
     field (k,T) is present in [ents] with a value inhabiting T. Extra keys in
     [ents] are allowed (open). The field-iteration is written as a STRUCTURAL
     nested fixpoint over [fields] (not [forall ... In ...]) so the recursive
     [denote T vv] call — at type T, a structural subterm of [BRec fields] — is
     accepted by the guard checker. The [In]-quantified reading the brief states
     is recovered exactly as [denote_rec_iff] below. *)
  | BRec fields =>
      exists ents, v = VTable ents /\
        (fix all_fields (fs : list (string * BTy)) : Prop :=
           match fs with
           | [] => True
           | (k, T) :: rest =>
               (exists vv, assoc_lookup k ents = Some vv /\ denote T vv)
               /\ all_fields rest
           end) fields
  end.

(* The brief's [In]-quantified reading, recovered as a characterization lemma.
   [denote (BRec fields) v] iff v is a table and every listed field is present
   with a value in its type. (The structural fold above and this [In] form are
   provably equivalent — induction on [fields].) *)
Lemma rec_fold_iff : forall (ents : list (string * V)) (fields : list (string * BTy)),
  (fix all_fields (fs : list (string * BTy)) : Prop :=
     match fs with
     | [] => True
     | (k, T) :: rest =>
         (exists vv, assoc_lookup k ents = Some vv /\ denote T vv) /\ all_fields rest
     end) fields
  <-> (forall k T, In (k, T) fields ->
         exists vv, assoc_lookup k ents = Some vv /\ denote T vv).
Proof.
  intros ents fields. induction fields as [ | [k T] rest IH ]; simpl.
  - split; [ intros _ k T [] | intros _; exact I ].
  - split.
    + intros [Hhd Htl] k' T' [Heq | Hin].
      * injection Heq as <- <-. exact Hhd.
      * apply IH; assumption.
    + intros H. split.
      * apply (H k T). left; reflexivity.
      * apply IH. intros k' T' Hin. apply H. right; assumption.
Qed.

Theorem denote_rec_iff : forall fields v,
  denote (BRec fields) v
  <-> exists ents, v = VTable ents /\
        (forall k T, In (k, T) fields ->
           exists vv, assoc_lookup k ents = Some vv /\ denote T vv).
Proof.
  intros fields v. simpl. split.
  - intros [ents [Hv Hfold]]. exists ents. split; [ exact Hv | ].
    apply rec_fold_iff. exact Hfold.
  - intros [ents [Hv Hall]]. exists ents. split; [ exact Hv | ].
    apply rec_fold_iff. exact Hall.
Qed.

(* ---- Decidability of membership (NO classical axiom) ----------------------
   [denote t v] is decidable for every type and value: atoms decide by matching
   the value constructor, and the connectives close decidability under and/or/
   not. This is what lets the classical-flavoured Boolean laws (De Morgan's
   harder direction, excluded middle for the complement/double-negation laws) go
   through CONSTRUCTIVELY — we appeal to this lemma, never to an axiom. *)

Definition atom_dec (a : Atom) (v : V) : {atom_denote a v} + {~ atom_denote a v}.
Proof.
  destruct a; destruct v; simpl; (left; exact I) || (right; intro H; exact H).
Defined.

Fixpoint denote_dec (t : BTy) (v : V) : {denote t v} + {~ denote t v}.
Proof.
  destruct t; simpl.
  - apply atom_dec.
  - left; exact I.
  - right; intro H; exact H.
  - destruct (denote_dec t1 v); destruct (denote_dec t2 v);
      (left; (left + right); assumption) || (right; intros [H | H]; contradiction).
  - destruct (denote_dec t1 v); destruct (denote_dec t2 v);
      (left; split; assumption) || (right; intros [H1 H2]; contradiction).
  - destruct (denote_dec t v).
    + right; intro H; contradiction.
    + left; assumption.
  - (* BRec: membership stays DECIDABLE and TOTAL. First decide whether v is a
       table; if not, no membership. If [v = VTable ents], decide each listed
       field by [string_dec]-driven lookup + recursive [denote_dec] on the
       field type — finite over [fields]. Constructive, no Classical. *)
    destruct v as [ | | | | | ents ];
      try (right; intros [ents [Hbad _]]; discriminate Hbad).
    (* v = VTable ents *)
    assert (Hdec :
      { (fix all_fields (fs : list (string * BTy)) : Prop :=
           match fs with
           | [] => True
           | (k, T) :: rest =>
               (exists vv, assoc_lookup k ents = Some vv /\ denote T vv)
               /\ all_fields rest
           end) l }
      + { ~ (fix all_fields (fs : list (string * BTy)) : Prop :=
           match fs with
           | [] => True
           | (k, T) :: rest =>
               (exists vv, assoc_lookup k ents = Some vv /\ denote T vv)
               /\ all_fields rest
           end) l }).
    { induction l as [ | [k T] rest IHrest ]; simpl.
      - left; exact I.
      - destruct (assoc_lookup k ents) as [vv | ] eqn:Elk.
        + destruct (denote_dec T vv) as [Hd | Hnd].
          * destruct IHrest as [Hrest | Hnrest].
            -- left. split; [ exists vv; split; [ reflexivity | exact Hd ] | exact Hrest ].
            -- right. intros [_ Hr]. exact (Hnrest Hr).
          * right. intros [[vv' [Elk' Hd']] _].
            injection Elk' as <-. exact (Hnd Hd').
        + right. intros [[vv' [Elk' _]] _]. discriminate Elk'. }
    destruct Hdec as [HY | HN].
    + left. exists ents. split; [ reflexivity | exact HY ].
    + right. intros [ents' [Heq Hf]]. injection Heq as <-. exact (HN Hf).
Defined.

(* Excluded middle and double-negation elimination for [denote], derived from
   decidability — constructive, no [Classical] import. *)
Lemma classic_denote' : forall t v, denote t v \/ ~ denote t v.
Proof. intros t v. destruct (denote_dec t v); auto. Qed.

Lemma NNPP_denote' : forall t v, ~ ~ denote t v -> denote t v.
Proof. intros t v Hnn. destruct (denote_dec t v) as [H | H]; [ exact H | contradiction ]. Qed.

(* ---- Semantic subtyping IS the definition of subtyping --------------------- *)

Definition dsub (a b : BTy) : Prop := forall v : V, denote a v -> denote b v.

Definition dequiv (a b : BTy) : Prop := dsub a b /\ dsub b a.

(* ---- Preorder + lattice results, re-proved under [dsub] -------------------
   Each now closes by unfolding to propositional logic. *)

Theorem dsub_refl : forall a, dsub a a.
Proof. unfold dsub; auto. Qed.

Theorem dsub_trans : forall a b c, dsub a b -> dsub b c -> dsub a c.
Proof. unfold dsub; auto. Qed.

Theorem dequiv_refl : forall a, dequiv a a.
Proof. split; apply dsub_refl. Qed.

Theorem dequiv_sym : forall a b, dequiv a b -> dequiv b a.
Proof. intros a b [H1 H2]; split; assumption. Qed.

Theorem dequiv_trans : forall a b c, dequiv a b -> dequiv b c -> dequiv a c.
Proof.
  intros a b c [H1 H2] [H3 H4]; split; eapply dsub_trans; eassumption.
Qed.

(* Union is the lub, Inter the glb — by construction of [denote]. *)

Theorem dunion_inl : forall a b, dsub a (BUnion a b).
Proof. unfold dsub; simpl; auto. Qed.

Theorem dunion_inr : forall a b, dsub b (BUnion a b).
Proof. unfold dsub; simpl; auto. Qed.

Theorem dinter_prl : forall a b, dsub (BInter a b) a.
Proof. unfold dsub; simpl; tauto. Qed.

Theorem dinter_prr : forall a b, dsub (BInter a b) b.
Proof. unfold dsub; simpl; tauto. Qed.

Theorem dunion_lub : forall a b c, dsub a c -> dsub b c -> dsub (BUnion a b) c.
Proof. unfold dsub; simpl; intros a b c Hac Hbc v [H | H]; auto. Qed.

Theorem dinter_glb : forall a b c, dsub c a -> dsub c b -> dsub c (BInter a b).
Proof. unfold dsub; simpl; auto. Qed.

(* Commutativity / associativity / idempotence / absorption. *)

Theorem dunion_comm : forall a b, dequiv (BUnion a b) (BUnion b a).
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem dinter_comm : forall a b, dequiv (BInter a b) (BInter b a).
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem dunion_assoc : forall a b c,
  dequiv (BUnion (BUnion a b) c) (BUnion a (BUnion b c)).
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem dinter_assoc : forall a b c,
  dequiv (BInter (BInter a b) c) (BInter a (BInter b c)).
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem dunion_idem : forall a, dequiv (BUnion a a) a.
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem dinter_idem : forall a, dequiv (BInter a a) a.
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem dabsorb_union_inter : forall a b, dequiv (BUnion a (BInter a b)) a.
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem dabsorb_inter_union : forall a b, dequiv (BInter a (BUnion a b)) a.
Proof. split; unfold dsub; simpl; tauto. Qed.

(* ===========================================================================
   THE PAYOFF — full Boolean-algebra laws as axiom-free theorems.

   These are exactly what the free lattice (increments 1-2) provably could NOT
   give. Each closes by unfolding [denote] to propositional logic + [tauto].
   No [sub] rule is invoked; no axiom is added.
   =========================================================================== *)

(* ---- Distributivity, BOTH directions (the free-lattice impossibility) ------ *)

Theorem ddistrib_inter_union : forall a b c,
  dequiv (BInter a (BUnion b c)) (BUnion (BInter a b) (BInter a c)).
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem ddistrib_union_inter : forall a b c,
  dequiv (BUnion a (BInter b c)) (BInter (BUnion a b) (BUnion a c)).
Proof. split; unfold dsub; simpl; tauto. Qed.

(* ---- De Morgan, both directions ------------------------------------------- *)

Theorem dde_morgan_union : forall a b,
  dequiv (BNeg (BUnion a b)) (BInter (BNeg a) (BNeg b)).
Proof. split; unfold dsub; simpl; tauto. Qed.

Theorem dde_morgan_inter : forall a b,
  dequiv (BNeg (BInter a b)) (BUnion (BNeg a) (BNeg b)).
Proof.
  (* the BUnion -> BInter-neg direction is intuitionistic; the converse needs
     a case split on decidable membership, supplied by classical reasoning over
     the (decidable) [denote a v]. We avoid an axiom by proving membership
     decidable. *)
  split; unfold dsub; simpl.
  - intros v Hn. destruct (classic_denote' a v) as [Ha | Ha].
    + right. intro Hb. apply Hn. split; assumption.
    + left. exact Ha.
  - intros v H [Ha Hb]. destruct H as [H | H]; auto.
Qed.

(* ---- Complement laws ------------------------------------------------------- *)

Theorem dcomplement_inter : forall a, dequiv (BInter a (BNeg a)) BBot.
Proof.
  split; unfold dsub; simpl.
  - intros v [H Hn]. exact (Hn H).
  - intros v [].
Qed.

Theorem dcomplement_union : forall a, dequiv (BUnion a (BNeg a)) BTop.
Proof.
  split; unfold dsub; simpl.
  - intros; exact I.
  - intros v _. apply classic_denote'.
Qed.

(* ---- Double negation ------------------------------------------------------- *)

Theorem ddouble_neg : forall a, dequiv (BNeg (BNeg a)) a.
Proof.
  split; unfold dsub; simpl.
  - intros v Hnn. apply NNPP_denote'. exact Hnn.
  - intros v H Hn. exact (Hn H).
Qed.

(* ---- Atom disjointness (by CONSTRUCTION) and base order -------------------- *)

(* All unrelated atom pairs intersect to Bot. Proved by destructing the value:
   distinct constructor heads make the conjunction of memberships absurd. No
   axiom — the falsity is decided by [discriminate]/structural match. *)

Ltac disjoint := unfold dsub; simpl; intros v [H1 H2]; destruct v; contradiction.

Theorem disjoint_int_str  : dsub (BInter (BAtom AInt)  (BAtom AStr))  BBot.
Proof. disjoint. Qed.
Theorem disjoint_int_bool : dsub (BInter (BAtom AInt)  (BAtom ABool)) BBot.
Proof. disjoint. Qed.
Theorem disjoint_int_nil  : dsub (BInter (BAtom AInt)  (BAtom ANil))  BBot.
Proof. disjoint. Qed.
Theorem disjoint_str_bool : dsub (BInter (BAtom AStr)  (BAtom ABool)) BBot.
Proof. disjoint. Qed.
Theorem disjoint_str_nil  : dsub (BInter (BAtom AStr)  (BAtom ANil))  BBot.
Proof. disjoint. Qed.
Theorem disjoint_bool_nil : dsub (BInter (BAtom ABool) (BAtom ANil))  BBot.
Proof. disjoint. Qed.
Theorem disjoint_num_str  : dsub (BInter (BAtom ANum)  (BAtom AStr))  BBot.
Proof. disjoint. Qed.
Theorem disjoint_num_bool : dsub (BInter (BAtom ANum)  (BAtom ABool)) BBot.
Proof. disjoint. Qed.
Theorem disjoint_num_nil  : dsub (BInter (BAtom ANum)  (BAtom ANil))  BBot.
Proof. disjoint. Qed.

(* Base order: AInt <: ANum, by construction (VInt inhabits both). *)
Theorem base_order_int_num : dsub (BAtom AInt) (BAtom ANum).
Proof. unfold dsub; simpl; intros v H; destruct v; auto. Qed.

(* ===========================================================================
   NON-VACUITY / FAITHFULNESS — the model is not trivially true.

   A model proving every law but with empty [V] or trivial [denote] is
   worthless. These witnesses show [V] is inhabited and [dsub] is a genuine,
   non-collapsing relation.
   =========================================================================== *)

(* The domain is inhabited — five distinct value witnesses. *)
Theorem V_inhabited : exists v : V, True.
Proof. exists VNil; exact I. Qed.

(* Each atom is genuinely inhabited (denotations are nonempty). *)
Theorem int_inhabited  : exists v, denote (BAtom AInt) v.
Proof. exists (VInt 0); simpl; exact I. Qed.
Theorem num_inhabited  : exists v, denote (BAtom ANum) v.
Proof. exists (VFloat 0); simpl; exact I. Qed.
Theorem str_inhabited  : exists v, denote (BAtom AStr) v.
Proof. exists (VStr 0); simpl; exact I. Qed.

(* Subtyping is NOT trivial — concrete NON-subtypes, each with a witness value
   that is in the LHS denotation but not the RHS. *)

Theorem not_str_sub_int : ~ dsub (BAtom AStr) (BAtom AInt).
Proof.
  unfold dsub; intro H. specialize (H (VStr 0)). simpl in H.
  apply H. exact I.
Qed.

Theorem not_top_sub_bot : ~ dsub BTop BBot.
Proof.
  unfold dsub; intro H. specialize (H VNil). apply H. simpl; exact I.
Qed.

(* Numbers are NOT all ints: ANum </: AInt, witnessed by a non-integer number. *)
Theorem not_num_sub_int : ~ dsub (BAtom ANum) (BAtom AInt).
Proof.
  unfold dsub; intro H. specialize (H (VFloat 0)). simpl in H.
  apply H. exact I.
Qed.

(* A NON-disjoint pair does NOT collapse to Bot: AInt inhabits ANum∩AInt. *)
Theorem num_int_not_bot : ~ dsub (BInter (BAtom ANum) (BAtom AInt)) BBot.
Proof.
  unfold dsub; intro H. specialize (H (VInt 0)). simpl in H.
  apply H. split; exact I.
Qed.

(* ===========================================================================
   INCREMENT 4 — DECIDABLE SUBTYPING: an executable decider, sound + complete.

   [dsub a b := forall v:V, denote a v -> denote b v] is the correct definition
   but is NOT computable: it quantifies over the infinite domain [V] (VInt n for
   every nat n, etc.). This increment makes subtyping DECIDABLE BY CONSTRUCTION
   — an executable [decide_dsub : BTy -> BTy -> bool] proven [= true <-> dsub].

   THE KEY OBSERVATION the decider exploits: for the CURRENT atoms, [denote t v]
   depends only on v's CONSTRUCTOR HEAD (VInt / VFloat / VStr / VBool / VNil —
   five classes), never on the payload (the nat / bool inside). [atom_denote]
   matches only the head; the connectives preserve head-dependence. So the
   universal quantifier over infinite [V] collapses to a finite check over five
   head-representatives.

   SCOPE / HONESTY (recorded in docs/proof-kernel.md): this works ONLY because
   the current atoms make [denote] head-determined. Once STRUCTURAL type formers
   are added — records/tables, arrows — [denote] will depend on more than the
   head (the contents of a table, the behaviour of a function), and this simple
   five-point decider will NOT suffice. A later increment needs an emptiness-
   based decision procedure (MLstruct-style). This decider is correct for the
   atom Boolean algebra, not the final procedure.
   =========================================================================== *)

(* ---- The ATOMIC fragment (no [BRec] anywhere) -----------------------------
   INCREMENT 5 re-scoping. The head-enumeration decider rests on [denote] being
   head-determined, which holds ONLY when no record former appears: a record
   inspects the table's CONTENTS, not just its head. So we carve out the
   [atomic] fragment — types with no [BRec] subterm — and restate the
   increment-4 results (head-dependence, the decider's soundness+completeness)
   as TRUE theorems scoped to it. [denote_dec] itself stays general and total
   (above); only the head-enumeration decider is fragment-restricted. The
   general decision procedure for records (emptiness-based / MLstruct-style) is
   a future increment — see docs/proof-kernel.md. *)

Fixpoint atomic (t : BTy) : Prop :=
  match t with
  | BAtom _    => True
  | BTop       => True
  | BBot       => True
  | BUnion a b => atomic a /\ atomic b
  | BInter a b => atomic a /\ atomic b
  | BNeg a     => atomic a
  | BRec _     => False
  end.

(* ---- Head classes: six canonical representatives --------------------------
   [head v] collapses a value to the canonical representative of its
   constructor class (erasing the payload). [head_reps] enumerates the six
   (five scalars + the table class — but see [head]'s note: the single table
   representative is only sound for the [atomic] fragment). *)

Definition head (v : V) : V :=
  match v with
  | VInt _   => VInt 0
  | VFloat _ => VFloat 0
  | VStr _   => VStr 0
  | VBool _  => VBool false
  | VNil     => VNil
  (* All tables collapse to the canonical empty table. This is SOUND ONLY for
     the [atomic] fragment (no [BRec]): for atomic types, [denote] never inspects
     table contents — every atom sends [VTable _] to the same answer regardless
     of payload — so the table class needs just one representative. Records DO
     inspect contents, which is exactly why the head-enumeration decider is
     re-scoped to [atomic] below and the general procedure is deferred. *)
  | VTable _ => VTable []
  end.

Definition head_reps : list V :=
  VInt 0 :: VFloat 0 :: VStr 0 :: VBool false :: VNil :: VTable [] :: nil.

(* [head v] is always one of the five representatives. *)
Lemma head_in_reps : forall v, In (head v) head_reps.
Proof.
  intro v; destruct v; simpl;
    repeat first [ left; reflexivity | right ].
Qed.

(* ---- HEAD-DEPENDENCE LEMMA ------------------------------------------------
   [denote t] cannot distinguish two values with the same head. The atom case
   is the crux: [atom_denote a] matches only the constructor, so erasing the
   payload (replacing v by [head v]) leaves membership unchanged. The
   connectives propagate this by the IH. Stated as: membership at v equals
   membership at [head v]. *)

(* Atom step: [atom_denote a v] iff [atom_denote a (head v)]. *)
Lemma atom_denote_head : forall a v, atom_denote a v <-> atom_denote a (head v).
Proof. intros a v; destruct a; destruct v; simpl; tauto. Qed.

(* The head-dependence lemma, by induction on the type — RE-SCOPED to the
   [atomic] fragment (increment 5). For an atomic type [denote] never looks past
   the value's head, so membership at v equals membership at [head v]. The
   [BRec] case is discharged by the [atomic] hypothesis (it is [False] there) —
   so this is a TRUE theorem about the atomic fragment, not a broken general
   one. Records genuinely break head-determination (the contents matter), which
   is why the restriction is real and not cosmetic. *)
Theorem denote_head : forall t, atomic t -> forall v, denote t v <-> denote t (head v).
Proof.
  induction t; intros Hat v; simpl in *.
  - apply atom_denote_head.
  - tauto.
  - tauto.
  - destruct Hat as [Ha Hb]. rewrite (IHt1 Ha v), (IHt2 Hb v); tauto.
  - destruct Hat as [Ha Hb]. rewrite (IHt1 Ha v), (IHt2 Hb v); tauto.
  - rewrite (IHt Hat v); tauto.
  - contradiction.        (* BRec: excluded by [atomic] *)
Qed.

(* Two values with the SAME head are indistinguishable by any ATOMIC type —
   the formulation the brief states, re-scoped. Immediate from [denote_head]. *)
Corollary denote_same_head : forall t, atomic t -> forall v1 v2,
  head v1 = head v2 -> (denote t v1 <-> denote t v2).
Proof.
  intros t Hat v1 v2 Hh.
  rewrite (denote_head t Hat v1), (denote_head t Hat v2), Hh. reflexivity.
Qed.

(* ---- Boolean membership from the decidable membership of increment 3 ------
   [denote_dec] gives [{denote t v}+{~denote t v}]; project it to a [bool]. *)

Definition memb (t : BTy) (v : V) : bool :=
  if denote_dec t v then true else false.

Lemma memb_true_iff : forall t v, memb t v = true <-> denote t v.
Proof.
  intros t v. unfold memb. destruct (denote_dec t v) as [H | H]; split;
    intro; first [ assumption | discriminate | contradiction | reflexivity ].
Qed.

(* ---- THE EXECUTABLE DECIDER -----------------------------------------------
   For each head-representative h, check that membership in [a] implies
   membership in [b] (i.e. NOT (a-member AND NOT b-member)). [forallb] over the
   five reps. Genuinely computable: [Compute (decide_dsub ...)] reduces. *)

Definition decide_dsub (a b : BTy) : bool :=
  forallb (fun h => implb (memb a h) (memb b h)) head_reps.

(* ---- SOUNDNESS + COMPLETENESS ---------------------------------------------
   decide_dsub a b = true  <->  dsub a b. *)

(* Helper: forallb true means the predicate holds at every list element. *)
Lemma forallb_forall_true : forall (f : V -> bool) (l : list V),
  forallb f l = true -> forall x, In x l -> f x = true.
Proof.
  intros f l H x Hin. rewrite forallb_forall in H. apply H, Hin.
Qed.

(* RE-SCOPED to the [atomic] fragment (increment 5). Completeness transports
   membership through [denote_head], which holds only for atomic types; hence the
   [atomic a /\ atomic b] hypothesis. This is a TRUE theorem about the atomic
   fragment, explicitly scoped — increment 4's result preserved, not broken. The
   GENERAL decision procedure (records included) is the deferred emptiness-based
   procedure (see docs/proof-kernel.md). Soundness alone needs no atomicity, but
   we state the clean iff under the shared hypothesis. *)
Theorem decide_dsub_correct : forall a b,
  atomic a -> atomic b ->
  (decide_dsub a b = true <-> dsub a b).
Proof.
  intros a b Hata Hatb. unfold decide_dsub, dsub. split.
  - (* COMPLETENESS: decider true -> dsub. Any v has head [head v], which is one
       of the six reps; the finite check covers it; head-dependence (ATOMIC)
       transports membership from [head v] back to v. *)
    intros Hall v Hav.
    pose proof (forallb_forall_true _ _ Hall (head v) (head_in_reps v)) as Hh.
    cbv beta in Hh.
    (* a-member at head v *)
    assert (memb a (head v) = true) as Hma.
    { apply memb_true_iff. apply (denote_head a Hata v). exact Hav. }
    rewrite Hma in Hh. simpl in Hh.
    (* b-member at head v, transported back to v *)
    apply (denote_head b Hatb v). apply memb_true_iff. exact Hh.
  - (* SOUNDNESS: dsub -> decider true. Instantiate dsub at each representative
       (each is a concrete witness value of its head class). *)
    intro Hsub. apply forallb_forall. intros h _.
    destruct (memb a h) eqn:Ea; simpl; [ | reflexivity ].
    apply memb_true_iff. apply Hsub. apply memb_true_iff. exact Ea.
Qed.

(* The sumbool form: subtyping is decidable on the ATOMIC fragment. *)
Definition dsub_dec (a b : BTy) (Hata : atomic a) (Hatb : atomic b)
  : {dsub a b} + {~ dsub a b}.
Proof.
  destruct (decide_dsub a b) eqn:E.
  - left. apply (decide_dsub_correct a b Hata Hatb). exact E.
  - right. intro H. apply (decide_dsub_correct a b Hata Hatb) in H.
    rewrite H in E. discriminate E.
Defined.

(* ---- SANITY / NON-TRIVIALITY ----------------------------------------------
   Concrete answers, each computed by reduction, and confirmed to AGREE with
   the semantic [dsub] (true cases proved [dsub ...], false cases proved
   [~ dsub ...]) — so the decider decides exactly [dsub], not some other
   relation. *)

(* AInt <: ANum is TRUE — integers are numbers. *)
Example dec_int_num   : decide_dsub (BAtom AInt) (BAtom ANum) = true.
Proof. reflexivity. Qed.
(* ANum <: AInt is FALSE — not all numbers are integers. *)
Example dec_num_int   : decide_dsub (BAtom ANum) (BAtom AInt) = false.
Proof. reflexivity. Qed.
(* AInt ∩ AStr <: Bot is TRUE — disjoint atoms intersect empty. *)
Example dec_int_str_bot : decide_dsub (BInter (BAtom AInt) (BAtom AStr)) BBot = true.
Proof. reflexivity. Qed.
(* AStr <: AInt is FALSE. *)
Example dec_str_int   : decide_dsub (BAtom AStr) (BAtom AInt) = false.
Proof. reflexivity. Qed.
(* Neg case: AInt <: ¬AStr is TRUE (an int is never a string). *)
Example dec_int_negstr : decide_dsub (BAtom AInt) (BNeg (BAtom AStr)) = true.
Proof. reflexivity. Qed.
(* Union case: AInt <: AInt ∪ AStr is TRUE. *)
Example dec_int_union : decide_dsub (BAtom AInt) (BUnion (BAtom AInt) (BAtom AStr)) = true.
Proof. reflexivity. Qed.
(* Complement: AInt ∪ ¬AInt <: Top, and Top <: AInt ∪ ¬AInt — both TRUE. *)
Example dec_excluded_middle :
  decide_dsub BTop (BUnion (BAtom AInt) (BNeg (BAtom AInt))) = true.
Proof. reflexivity. Qed.

(* AGREEMENT with the semantic [dsub]: each decided answer matches the truth.
   (true -> dsub; false -> ~dsub, via [decide_dsub_correct].) *)
Example agree_int_num : dsub (BAtom AInt) (BAtom ANum).
Proof. apply (decide_dsub_correct (BAtom AInt) (BAtom ANum) I I). reflexivity. Qed.
Example agree_not_num_int : ~ dsub (BAtom ANum) (BAtom AInt).
Proof.
  intro H. apply (decide_dsub_correct (BAtom ANum) (BAtom AInt) I I) in H. discriminate H.
Qed.
Example agree_int_str_bot : dsub (BInter (BAtom AInt) (BAtom AStr)) BBot.
Proof.
  apply (decide_dsub_correct (BInter (BAtom AInt) (BAtom AStr)) BBot (conj I I) I).
  reflexivity.
Qed.
Example agree_not_str_int : ~ dsub (BAtom AStr) (BAtom AInt).
Proof.
  intro H. apply (decide_dsub_correct (BAtom AStr) (BAtom AInt) I I) in H. discriminate H.
Qed.

(* ===========================================================================
   INCREMENT 5 — RECORD/TABLE TYPES: structural subtyping as theorems-for-free.

   With [BRec] in [BTy], [VTable] in [V], and the OPEN/WIDTH denotation
   (denote_rec_iff), the standard structural subtyping laws — WIDTH (forgetting
   fields), DEPTH/COVARIANCE (refining a field's type), and "records are tables"
   — fall straight out of the semantic [dsub] (set inclusion over [denote]). No
   new [dsub] rule, no axiom, no ad-hoc casing: every law is a direct consequence
   of the denotation, exactly as the Boolean laws were.

   The Boolean-algebra laws of increment 3 (distributivity both directions, De
   Morgan, complement, double negation) were proved generically by unfolding
   [denote] to propositional logic — they NEVER case-analyzed the [BTy]
   constructors — so adding [BRec] leaves them untouched: they still compile
   verbatim. (Confirmed: the whole dev compiles. No generic law needed a fix.)
   =========================================================================== *)

(* ---- WIDTH (general form: field-set inclusion) ----------------------------
   If every field listed in [g] is also listed in [f], then [BRec f <: BRec g]:
   a value satisfying ALL of f's field requirements a fortiori satisfies the
   (fewer) requirements of g. WIDTH (drop the head field) and PERMUTATION
   (reorder fields) are immediate corollaries. This is the open-reading payoff:
   forgetting fields is supertyping, by construction. *)

Theorem drec_width_incl : forall f g : list (string * BTy),
  (forall k T, In (k, T) g -> In (k, T) f) ->
  dsub (BRec f) (BRec g).
Proof.
  intros f g Hincl. unfold dsub. intros v Hf.
  apply denote_rec_iff in Hf. apply denote_rec_iff.
  destruct Hf as [ents [Hv Hall]].
  exists ents. split; [ exact Hv | ].
  intros k T Hin. apply Hall. apply Hincl. exact Hin.
Qed.

(* WIDTH proper: dropping the head field is supertyping. *)
Theorem drec_width : forall k T rest,
  dsub (BRec ((k, T) :: rest)) (BRec rest).
Proof.
  intros k T rest. apply drec_width_incl.
  intros k' T' Hin. right. exact Hin.
Qed.

(* PERMUTATION (a fields-set reordering is subtype-equivalent), via inclusion
   both ways — here the concrete two-field swap, the representative instance. *)
Theorem drec_perm2 : forall k1 T1 k2 T2,
  dequiv (BRec [(k1, T1); (k2, T2)]) (BRec [(k2, T2); (k1, T1)]).
Proof.
  intros k1 T1 k2 T2. split; apply drec_width_incl;
    intros k T Hin; simpl in *; tauto.
Qed.

(* ---- DEPTH / COVARIANCE ---------------------------------------------------
   Refining a field's type downward refines the record downward. Single field
   first, then the general pointwise (list-wise) version. Covariance is the
   honest law for the open reading; it follows because each field requirement
   [denote T vv] is monotone in T under [dsub]. *)

Theorem drec_depth1 : forall k A A',
  dsub A A' -> dsub (BRec [(k, A)]) (BRec [(k, A')]).
Proof.
  intros k A A' HAA'. unfold dsub. intros v Hf.
  apply denote_rec_iff in Hf. apply denote_rec_iff.
  destruct Hf as [ents [Hv Hall]].
  exists ents. split; [ exact Hv | ].
  intros k0 T0 Hin. simpl in Hin. destruct Hin as [Heq | []].
  injection Heq as <- <-.
  destruct (Hall k A (or_introl eq_refl)) as [vv [Elk Hvv]].
  exists vv. split; [ exact Elk | apply HAA'; exact Hvv ].
Qed.

(* General pointwise depth: if the two field-lists share keys position-by-
   position and each field type widens, the record widens. We state it via a
   pointwise [Forall2] over the (shared-key) field types. *)
Theorem drec_depth : forall (fields : list (string * BTy)) (g : string -> BTy -> BTy),
  (forall k T v, denote T v -> denote (g k T) v) ->
  dsub (BRec fields) (BRec (map (fun kT => (fst kT, g (fst kT) (snd kT))) fields)).
Proof.
  intros fields g Hmono. unfold dsub. intros v Hf.
  apply denote_rec_iff in Hf. apply denote_rec_iff.
  destruct Hf as [ents [Hv Hall]]. exists ents. split; [ exact Hv | ].
  intros k T Hin. rewrite in_map_iff in Hin.
  destruct Hin as [[k0 T0] [Heq Hin0]]. simpl in Heq. injection Heq as <- <-.
  destruct (Hall k0 T0 Hin0) as [vv [Elk Hvv]].
  exists vv. split; [ exact Elk | apply Hmono; exact Hvv ].
Qed.

(* ---- RECORDS ARE TABLES ---------------------------------------------------
   There is no dedicated "table atom" in [Atom] (the atoms are scalar kinds:
   nil/bool/int/num/str). The faithful statement is that every record type is a
   subtype of the EMPTY OPEN record [BRec []] — which denotes exactly the
   table-shaped values (any [VTable ents]). So [BRec []] PLAYS the role of the
   table top-type, and every record denotes a subset of "table-shaped" values,
   disjoint from every scalar atom. (A first-class table atom is a future
   refinement; noted in docs/proof-kernel.md.) *)

Theorem drec_is_table : forall fields, dsub (BRec fields) (BRec []).
Proof.
  intro fields. apply drec_width_incl. intros k T [].
Qed.

(* [BRec []] denotes EXACTLY the tables — a value inhabits it iff it is a VTable. *)
Theorem empty_rec_is_tables : forall v,
  denote (BRec []) v <-> exists ents, v = VTable ents.
Proof.
  intro v. rewrite denote_rec_iff. split.
  - intros [ents [Hv _]]. exists ents. exact Hv.
  - intros [ents Hv]. exists ents. split; [ exact Hv | intros k T [] ].
Qed.

(* Records are disjoint from scalars: no table inhabits any atom, so a record
   intersected with any atom is empty. (Representative: with AInt.) *)
Theorem rec_disjoint_atom : forall fields a,
  dsub (BInter (BRec fields) (BAtom a)) BBot.
Proof.
  intros fields a. unfold dsub. intros v [Hr Ha].
  apply denote_rec_iff in Hr. destruct Hr as [ents [Hv _]]. subst v.
  destruct a; simpl in Ha; exact Ha.
Qed.

(* ===========================================================================
   NON-VACUITY for records — the record semantics is not trivially true.
   =========================================================================== *)

(* A record type is INHABITED: exhibit a concrete table witness. *)
Theorem rec_inhabited :
  denote (BRec [("f"%string, BAtom AInt)]) (VTable [("f"%string, VInt 0)]).
Proof.
  apply denote_rec_iff. exists [("f"%string, VInt 0)]. split; [ reflexivity | ].
  intros k T Hin. simpl in Hin. destruct Hin as [Heq | []].
  injection Heq as <- <-. exists (VInt 0). simpl. split; [ reflexivity | exact I ].
Qed.

(* DEPTH does NOT collapse: a record with an int field is NOT a subtype of the
   same record with a string field. Witness: the table {f = 0} inhabits the
   former (0 is an int) but not the latter (0 is not a string). *)
Theorem not_rec_int_sub_str :
  ~ dsub (BRec [("f"%string, BAtom AInt)]) (BRec [("f"%string, BAtom AStr)]).
Proof.
  unfold dsub. intro H.
  specialize (H (VTable [("f"%string, VInt 0)])).
  assert (Hpre : denote (BRec [("f"%string, BAtom AInt)]) (VTable [("f"%string, VInt 0)]))
    by apply rec_inhabited.
  specialize (H Hpre). apply denote_rec_iff in H.
  destruct H as [ents [Hv Hall]]. injection Hv as <-.
  destruct (Hall "f"%string (BAtom AStr) (or_introl eq_refl)) as [vv [Elk Hvv]].
  simpl in Elk. injection Elk as <-. simpl in Hvv. exact Hvv.
Qed.

(* WIDTH is non-trivial in the other direction: the WIDER record (fewer fields)
   is NOT a subtype of the NARROWER one — a table with only {f} does not satisfy
   a {f,g} requirement. So width subtyping is a genuine, non-symmetric edge. *)
Theorem not_rec_narrow_sub_wide :
  ~ dsub (BRec [("f"%string, BAtom AInt)])
         (BRec [("f"%string, BAtom AInt); ("g"%string, BAtom AInt)]).
Proof.
  unfold dsub. intro H.
  specialize (H (VTable [("f"%string, VInt 0)])).
  assert (Hpre : denote (BRec [("f"%string, BAtom AInt)]) (VTable [("f"%string, VInt 0)]))
    by apply rec_inhabited.
  specialize (H Hpre). apply denote_rec_iff in H.
  destruct H as [ents [Hv Hall]]. injection Hv as <-.
  destruct (Hall "g"%string (BAtom AInt) (or_intror (or_introl eq_refl))) as [vv [Elk _]].
  simpl in Elk. discriminate Elk.
Qed.
