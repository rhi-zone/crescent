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
