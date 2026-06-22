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
   A tiny but real atom lattice: ANil, ABool, AInt, ANum, AFloat, AStr.

   NUMBER ATOMS — LuaJIT 5.1 model (corrected). On LuaJIT 5.1 every number is a
   single IEEE double: [3 == 3.0], an integer-valued number IS a float, and
   [type()] returns ["number"] for both. So there is ONE number type, and
   "integer-valued" is a genuine refinement SUBSET of it:

     - [ANum]  = all numbers (the number type).
     - [AFloat]= the number/double type on 5.1 — float IS number, so [AFloat]
       denotes ALL numbers, exactly like [ANum] (a synonym kept because the
       slice/surface names "float"; see docs/reality-bridge.md fork A′).
     - [AInt]  = the integer-valued numbers — a NON-trivial subset of the
       doubles ([x == floor x], finite). So [AInt <: AFloat] and [AInt <: ANum]
       both hold, and they are PROVED below ([AInt_sub_AFloat], [AInt_sub_ANum]).

   This is the 5.1 picture: no disjoint int/float values. (PUC 5.3/5.4, which tag
   integers as a distinct value, would be version-parametric distinct siblings —
   DEFERRED; see docs/reality-bridge.md.)

   The only non-trivial atom edges are AInt <: ANum and AInt <: AFloat;
   everything else is incomparable at the atom level. *)

Inductive Atom : Type :=
  | ANil
  | ABool
  | AInt
  | ANum
  | AFloat
  | AStr.

(* Declared atom sub-order as a proper (non-reflexive) relation; SRefl in [sub]
   is the sole source of reflexivity so the atom order stays the genuine
   strict-edge data of the lattice. AInt is below BOTH ANum and AFloat (which
   are themselves equivalent on 5.1 — see the dsub-level [AFloat_equiv_ANum]). *)
Inductive atom_le : Atom -> Atom -> Prop :=
  | ALInt   : atom_le AInt ANum
  | ALIntF  : atom_le AInt AFloat.

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
   induction on the SECOND derivation here, where the IH lines up. (The atom
   edges all have AInt on the left and a number atom on the right; no number
   atom is a left endpoint, so the SAtom-on-the-right subcase is vacuous.) *)
Lemma sub_atom_trans : forall a b z,
  atom_le a b -> sub (TAtom b) z -> sub (TAtom a) z.
Proof.
  intros a b z Hab Hbz.
  remember (TAtom b) as tb eqn:Etb.
  revert a b Hab Etb.
  induction Hbz; intros a' b' Hab Etb; try discriminate Etb.
  - (* SRefl: t = TAtom b' *)
    rewrite Etb. apply SAtom; assumption.
  - (* SAtom a b: compose edges; vacuous — no number atom is a left endpoint *)
    injection Etb as <-. inversion Hab; subst; inversion H.
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

(* Atom interpretation: AInt↦NA, ANum↦NB, AFloat↦NB (float ≡ number on 5.1, so
   both number atoms map to the same N5 point), AStr↦NC. So the atom edges
   AInt<:ANum and AInt<:AFloat both map to NA ≤ NB; the rest to bottom. *)
Definition iatom (a : Atom) : N5 :=
  match a with AInt => NA | ANum => NB | AFloat => NB | AStr => NC | _ => B0 end.

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
  - destruct H; reflexivity.        (* SAtom: AInt<:ANum and AInt<:AFloat, both NA ≤ NB *)
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

   The base order [AInt <: ANum] (and [AInt <: AFloat]) is likewise baked into
   the denotation, not asserted. LuaJIT 5.1 has ONE number value (a double), so
   there is a SINGLE number constructor [VNum : NumRep -> V]; the representation
   [NumRep] records whether the double is integer-valued ([NRint z], e.g. [3.0])
   or genuinely non-integer ([NRfrac z], e.g. [1.5]). "Integer-valued" is thus
   DECIDABLE on the value. [atom_denote ANum]/[atom_denote AFloat] accept EVERY
   [VNum _] (all numbers); [atom_denote AInt] accepts only [VNum (NRint _)]. So
   [denote (atom AInt) v -> denote (atom ANum) v] and the same for [AFloat] hold
   definitionally (NRint-numbers are a literal subset of all numbers), while the
   converse fails because [VNum (NRfrac _)] inhabits ANum/AFloat but not AInt.

   [VInt n]/[VFloat n] are kept as NOTATIONS for [VNum (NRint n)]/[VNum (NRfrac
   n)] — so [VInt 3] and [VFloat 3] are NO LONGER distinct values; they denote
   different doubles only when [n] differs and the rep differs. The collapse is
   genuine: there is exactly one [V] value per double, and [VInt 3] is literally
   [VNum (NRint 3)], an integer-valued number that IS a float. (PUC 5.3/5.4's
   tagged-integer values, where [3] and [3.0] are distinct siblings, are the
   version-parametric DEFERRED design — see docs/reality-bridge.md.)
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
  | BRec   : list (string * BTy) -> BTy
  (* INCREMENT 7 — single-arg / single-return function types (ARROWS). [BArrow A
     B] is the type of functions whose every (input,output) pair has: input in A
     ⇒ output in B (the standard semantic-subtyping reading, see [denote]).
     Multi-arg / vararg / multi-return are DEFERRED. *)
  | BArrow : BTy -> BTy -> BTy
  (* SPLIT-STEP 1 of the reference unification — REFERENCE types. A reference is
     a mutable location (a Lua-style box / cell). Two formers are needed, mirroring
     the diagnosis: [BRef T] is the type of references whose CONTENT is typed [T];
     [BAnyRef] is the type of ALL references, content-agnostic (so a truthy
     location can be NARROWED to "is a reference" without committing to its
     content type). References are INVARIANT and lack a clean store-free
     denotation — a location's content type is NOT observable from the value (we
     model a location as a bare [nat] address). So BOTH [BRef _] and [BAnyRef]
     denote exactly the set of all locations [{VRef _}]; the syntactic distinction
     (invariance, any-ref widening) is DEFERRED to [ssub] in a later increment.
     They are OPAQUE LEAVES — exactly like [BArrow] — for the decision procedure:
     any clause carrying a ref literal DEFERS ([gdecide ⇒ DUnknown]). *)
  | BRef : BTy -> BTy
  | BAnyRef : BTy
  (* MULTI-RETURN — TUPLE / VALUE-SEQUENCE type. [BTuple [T1;…;Tk]] is the type of
     a finite POSITIONAL value-sequence (what a multi-return function produces).
     Read POSITIONALLY (NOT structural width/depth like records): a value is in
     [BTuple Ts] iff it is a sequence [VTup vs] of EXACTLY the same length whose
     i-th component inhabits the i-th type. This is the "standard model" sequence
     type used for Lua's contextual adjustment (truncation / last-position spread).
     Like [BArrow]/[BRef] it is an OPAQUE LEAF for the decision procedure — any
     clause carrying a tuple literal DEFERS ([gdecide ⇒ DUnknown]); the Boolean
     laws (proved generically over [denote]) are untouched. Tuple SUBTYPING beyond
     reflexivity / pointwise (and arity-polymorphic spread) is DEFERRED. *)
  | BTuple : list BTy -> BTy.

(* ---- The number representation (LuaJIT 5.1: one double per number) ---------
   A number value is a single double. [NumRep] is the value-level witness of
   whether that double is integer-valued. [NRint z] = an integer-valued double
   (e.g. [3.0]); [NRfrac z] = a genuinely non-integer double (e.g. [1.5]). This
   makes "integer-valued" DECIDABLE structurally (it is the [NRint] head) while
   keeping non-integer numbers representable — so [AInt] is a proper, non-trivial
   subset of the number type, NOT everything. The [z : nat] payload distinguishes
   distinct doubles within each class; classification is head-determined. *)

Inductive NumRep : Type :=
  | NRint  : nat -> NumRep     (* an integer-valued double, e.g. 3.0 *)
  | NRfrac : nat -> NumRep.    (* a genuinely non-integer double, e.g. 1.5 *)

(* ---- The value domain -----------------------------------------------------
   Distinct constructor heads => unrelated atoms denote disjoint sets, decided
   structurally. [VNum] is the SINGLE number kind (one double per value, 5.1);
   integer-valued-ness is the [NRint]/[NRfrac] split INSIDE that one head. *)

Inductive V : Type :=
  | VNum   : NumRep -> V       (* the one number value (a double); see NumRep *)
  | VStr   : nat -> V          (* a string value:  inhabits AStr only       *)
  | VBool  : bool -> V         (* a boolean value: inhabits ABool only      *)
  | VNil   : V                 (* nil:             inhabits ANil only        *)
  (* INCREMENT 5 — table values. A FINITE assoc-list of string keys to
     sub-values. V stays a (nested) INDUCTIVE: VTable carries a list whose
     elements are structurally smaller, so it is well-founded. Cyclic /
     self-referential tables are DEFERRED to the future equirecursive-μ
     increment (they would force a coinductive V — a real fork we do not take
     here). *)
  | VTable : list (string * V) -> V
  (* INCREMENT 7 — function values. A function VALUE is modelled by its FINITE
     input/output graph: a list of (input, output) pairs. [V] stays a (nested)
     INDUCTIVE — both components of each pair are structurally smaller, so it is
     well-founded. [V] appears only POSITIVELY here (as the element type of the
     graph list), so this is Coq-legal: no negative occurrence, no impredicativity
     issue. Cyclic / self-referential function values and higher-order-via-V are
     fine because [V] occurs positively. Multi-arg / vararg / multi-return are
     DEFERRED (single input, single output per pair). *)
  | VFun : list (V * V) -> V
  (* SPLIT-STEP 1 — REFERENCE/location values. A reference VALUE is modelled by a
     bare location address [VRef : nat -> V] — distinct constructor head, so a
     location is disjoint from every scalar / table / function value (decided by
     [discriminate]). The address is just an identity tag; the CONTENT a location
     points at is NOT carried by the value (no store in this model), which is
     precisely why references are content-blind / invariant here. *)
  | VRef : nat -> V
  (* MULTI-RETURN — value-sequence (multivalue). [VTup vs] is a finite POSITIONAL
     sequence of values — the runtime result of a multi-return [return e1,…,ek].
     [V] occurs only POSITIVELY (the element type of the list), so this is
     Coq-legal (no negative occurrence), and the elements are structurally smaller
     (well-founded). Distinct head ⇒ a sequence is disjoint from every scalar /
     table / function / location value (by [discriminate]). *)
  | VTup : list V -> V.

(* ---- VInt / VFloat as NOTATIONS over the single number value --------------
   [VInt n] is literally [VNum (NRint n)] (an integer-valued double) and
   [VFloat n] is [VNum (NRfrac n)] (a non-integer double). These are NOTATIONS,
   not constructors: there is one number value per double. [VInt 3] is an
   integer-valued number that IS a float — exactly the 5.1 picture. The old
   distinct-value reading is gone; these names survive only as readable spellings
   of the two NumRep classes. *)
Notation VInt n := (VNum (NRint n)).
Notation VFloat n := (VNum (NRfrac n)).

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
  (* a second list-property, for the function graph (a list of V*V pairs) *)
  Variable Pg : list (V * V) -> Prop.
  (* a third list-property, for the tuple/value-sequence (a list of V) *)
  Variable Pt : list V -> Prop.
  Hypothesis HInt   : forall n, P (VInt n).
  Hypothesis HFloat : forall n, P (VFloat n).
  Hypothesis HStr   : forall n, P (VStr n).
  Hypothesis HBool  : forall b, P (VBool b).
  Hypothesis HNil   : P VNil.
  Hypothesis HTable : forall l, Pl l -> P (VTable l).
  Hypothesis Hnil   : Pl [].
  Hypothesis Hcons  : forall k v rest, P v -> Pl rest -> Pl ((k, v) :: rest).
  Hypothesis HFun   : forall g, Pg g -> P (VFun g).
  Hypothesis Hgnil  : Pg [].
  Hypothesis Hgcons : forall i o rest, P i -> P o -> Pg rest -> Pg ((i, o) :: rest).
  (* VRef carries a bare [nat] address — a leaf, like VStr; no recursive V. *)
  Hypothesis HRef   : forall n, P (VRef n).
  Hypothesis HTup   : forall l, Pt l -> P (VTup l).
  Hypothesis Htnil  : Pt [].
  Hypothesis Htcons : forall v rest, P v -> Pt rest -> Pt (v :: rest).
  Fixpoint V_rect_strong (v : V) : P v :=
    match v with
    | VNum (NRint n)  => HInt n
    | VNum (NRfrac n) => HFloat n
    | VStr n   => HStr n
    | VBool b  => HBool b
    | VNil     => HNil
    | VRef n   => HRef n
    | VTable l =>
        HTable l
          ((fix go (l : list (string * V)) : Pl l :=
              match l with
              | [] => Hnil
              | (k, vv) :: rest => Hcons k vv rest (V_rect_strong vv) (go rest)
              end) l)
    | VFun g =>
        HFun g
          ((fix gog (g : list (V * V)) : Pg g :=
              match g with
              | [] => Hgnil
              | (i, o) :: rest => Hgcons i o rest (V_rect_strong i) (V_rect_strong o) (gog rest)
              end) g)
    | VTup l =>
        HTup l
          ((fix got (l : list V) : Pt l :=
              match l with
              | [] => Htnil
              | v :: rest => Htcons v rest (V_rect_strong v) (got rest)
              end) l)
    end.
End V_ind_strong.

(* ---- Atom denotation ------------------------------------------------------
   Order and disjointness are visible right here, in the value-set membership,
   never imposed from outside. On LuaJIT 5.1 every number is one double, so
   ANum's set and AFloat's set are BOTH {VNum _} (all numbers — float ≡ number);
   AInt's set is {VNum (NRint _)} — the integer-valued doubles, a literal SUBSET.
   So AInt <: AFloat and AInt <: ANum hold by construction (proved below), with
   no disjoint int/float values. The other atoms pick their own constructor.
   Note [VTable] inhabits NO atom (every atom branch sends it to [False]) — a
   table is structurally not a scalar. *)

Definition atom_denote (a : Atom) (v : V) : Prop :=
  match a with
  | ANil   => match v with VNil    => True | _ => False end
  | ABool  => match v with VBool _ => True | _ => False end
  | AInt   => match v with VNum (NRint _) => True | _ => False end
  | ANum   => match v with VNum _ => True | _ => False end
  | AFloat => match v with VNum _ => True | _ => False end
  | AStr   => match v with VStr _  => True | _ => False end
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
  (* ARROW membership (semantic-subtyping reading). [v] inhabits [BArrow A B] iff
     [v] is a function value [VFun g] and EVERY (i,o) in its graph satisfies
     [denote A i -> denote B o]. Non-function values inhabit no arrow type
     (functions are a disjoint kind from scalars and tables). The graph iteration
     is a STRUCTURAL nested fixpoint over [g] so the recursive [denote A i] /
     [denote B o] calls (at A, B — structural subterms of [BArrow A B]) are
     guard-accepted. The [In]-quantified reading is recovered as
     [denote_arrow_iff] below. *)
  | BArrow A B =>
      match v with
      | VFun g =>
          (fix all_pairs (gg : list (V * V)) : Prop :=
             match gg with
             | [] => True
             | (i, o) :: rest => (denote A i -> denote B o) /\ all_pairs rest
             end) g
      | _ => False
      end
  (* REFERENCE membership — CONTENT-BLIND (the price of invariance). A value
     inhabits [BRef T] iff it is a location [VRef n]; the content type [T] is NOT
     inspected (the value carries no store), so EVERY location inhabits EVERY
     [BRef T]. [BAnyRef] denotes the same set. Denotationally therefore
     [BRef T ≡ BAnyRef ≡ BRef U] for all T,U — the syntactic invariance / any-ref
     distinction is deferred to [ssub] (the safe direction: [ssub ⊊ dsub]). *)
  | BRef _   => match v with VRef _ => True | _ => False end
  | BAnyRef  => match v with VRef _ => True | _ => False end
  (* TUPLE membership — POSITIONAL, EXACT LENGTH. [v] is in [BTuple Ts] iff [v] is
     a value-sequence [VTup vs] of the SAME LENGTH as [Ts] whose i-th component
     inhabits the i-th type. Written as a structural nested fixpoint walking [Ts]
     and [vs] in lockstep (so the recursive [denote T vv] at a structural subterm
     [T] is guard-accepted); the empty tuple matches only the empty sequence. The
     positional reading is recovered as [denote_tuple_iff] below. *)
  | BTuple Ts =>
      match v with
      | VTup vs =>
          (fix all_pos (ts : list BTy) (vv : list V) : Prop :=
             match ts, vv with
             | [], [] => True
             | T :: tr, v0 :: vr => denote T v0 /\ all_pos tr vr
             | _, _ => False
             end) Ts vs
      | _ => False
      end
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

(* The [In]-quantified reading of arrow membership: [v] is in [BArrow A B] iff it
   is a function value [VFun g] every pair of whose graph maps A-inputs to
   B-outputs. (The structural fold above and this [In] form are provably
   equivalent — induction on [g].) *)
Lemma arrow_fold_iff : forall (A B : BTy) (g : list (V * V)),
  (fix all_pairs (gg : list (V * V)) : Prop :=
     match gg with
     | [] => True
     | (i, o) :: rest => (denote A i -> denote B o) /\ all_pairs rest
     end) g
  <-> (forall i o, In (i, o) g -> denote A i -> denote B o).
Proof.
  intros A B g. induction g as [ | [i o] rest IH ]; simpl.
  - split; [ intros _ i o [] | intros _; exact I ].
  - split.
    + intros [Hhd Htl] i' o' [Heq | Hin].
      * injection Heq as <- <-. exact Hhd.
      * apply IH; assumption.
    + intros H. split.
      * apply (H i o). left; reflexivity.
      * apply IH. intros i' o' Hin. apply H. right; assumption.
Qed.

Theorem denote_arrow_iff : forall A B v,
  denote (BArrow A B) v
  <-> exists g, v = VFun g /\ (forall i o, In (i, o) g -> denote A i -> denote B o).
Proof.
  intros A B v. simpl. split.
  - destruct v as [ | | | | ents | g | n | vs ]; try contradiction.
    intros Hfold. exists g. split; [ reflexivity | ]. apply arrow_fold_iff. exact Hfold.
  - intros [g [Hv Hall]]. subst v. apply arrow_fold_iff. exact Hall.
Qed.

(* ---- Decidability of membership (NO classical axiom) ----------------------
   [denote t v] is decidable for every type and value: atoms decide by matching
   the value constructor, and the connectives close decidability under and/or/
   not. This is what lets the classical-flavoured Boolean laws (De Morgan's
   harder direction, excluded middle for the complement/double-negation laws) go
   through CONSTRUCTIVELY — we appeal to this lemma, never to an axiom. *)

Definition atom_dec (a : Atom) (v : V) : {atom_denote a v} + {~ atom_denote a v}.
Proof.
  destruct a; destruct v as [ r | | | | | | | vs ]; try destruct r;
    simpl; (left; exact I) || (right; intro H; exact H).
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
    destruct v as [ | | | | ents | g | n | vs ];
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
  - (* BArrow: membership in an arrow type is DECIDABLE — the graph is finite, and
       for each (i,o) the implication [denote t1 i -> denote t2 o] is decidable
       (decide the antecedent; if it holds, decide the consequent). Constructive,
       no Classical. *)
    destruct v as [ | | | | ents | g | n | vs ];
      try (right; intro H; exact H).
    (* v = VFun g *)
    assert (Hdec :
      { (fix all_pairs (gg : list (V * V)) : Prop :=
           match gg with
           | [] => True
           | (i, o) :: rest => (denote t1 i -> denote t2 o) /\ all_pairs rest
           end) g }
      + { ~ (fix all_pairs (gg : list (V * V)) : Prop :=
           match gg with
           | [] => True
           | (i, o) :: rest => (denote t1 i -> denote t2 o) /\ all_pairs rest
           end) g }).
    { induction g as [ | [i o] rest IHrest ]; simpl.
      - left; exact I.
      - assert (Hpair : { denote t1 i -> denote t2 o } + { ~ (denote t1 i -> denote t2 o) }).
        { destruct (denote_dec t1 i) as [Hi | Hni].
          - destruct (denote_dec t2 o) as [Ho | Hno].
            + left. intros _. exact Ho.
            + right. intro Himp. exact (Hno (Himp Hi)).
          - left. intro Hc. contradiction. }
        destruct Hpair as [Hp | Hnp].
        + destruct IHrest as [Hr | Hnr].
          * left. split; [ exact Hp | exact Hr ].
          * right. intros [_ Hr]. exact (Hnr Hr).
        + right. intros [Hp _]. exact (Hnp Hp). }
    destruct Hdec as [HY | HN]; [ left; exact HY | right; exact HN ].
  - (* BRef: membership is "is v a location?" — decide by the constructor head.
       Constructive, no Classical. *)
    destruct v as [ | | | | | | n | vs ];
      try (right; intro H; exact H). left; exact I.
  - (* BAnyRef: same — decide by the VRef head. *)
    destruct v as [ | | | | | | n | vs ];
      try (right; intro H; exact H). left; exact I.
  - (* BTuple: membership is DECIDABLE — v must be a [VTup vs] of the right length
       and each position decided by recursive [denote_dec]. Constructive, total. *)
    destruct v as [ | | | | | | | vs ];
      try (right; intro H; exact H).
    (* v = VTup vs : walk Ts and vs in lockstep *)
    revert vs.
    induction l as [ | T tr IHtr ]; intro vs.
    + (* empty tuple type: matches exactly the empty sequence *)
      destruct vs as [ | v0 vr ]; [ left; exact I | right; intro H; exact H ].
    + destruct vs as [ | v0 vr ]; [ right; intro H; exact H | ].
      destruct (denote_dec T v0) as [Hd | Hnd].
      * destruct (IHtr vr) as [Hr | Hnr].
        -- left. split; [ exact Hd | exact Hr ].
        -- right. intros [_ Hr]. exact (Hnr Hr).
      * right. intros [Hd _]. exact (Hnd Hd).
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

(* Base order: AInt <: ANum, by construction ([VNum (NRint _)] inhabits both). *)
Theorem base_order_int_num : dsub (BAtom AInt) (BAtom ANum).
Proof. unfold dsub; simpl; intros v H; destruct v as [ r | | | | | | | vs ]; try destruct r; auto. Qed.

(* ---- LuaJIT 5.1 number atoms: int <: float, the genuine value-domain edge ---
   The user's explicit point. On 5.1 an integer-valued number IS a float (one
   double per number), so AInt is a non-trivial SUBSET of the number/float type.
   Both edges are PROVED here directly from the denotation (set inclusion): every
   value in [AInt] (an [NRint] double) is a [VNum _], hence in both [AFloat] and
   [ANum]. No int/float disjointness exists in this model. *)

(* int <: float — the headline 5.1 fact. *)
Theorem AInt_sub_AFloat : dsub (BAtom AInt) (BAtom AFloat).
Proof. unfold dsub; simpl; intros v H; destruct v as [ r | | | | | | | vs ]; try destruct r; auto. Qed.

(* int <: num — same subset relationship against the number type. *)
Theorem AInt_sub_ANum : dsub (BAtom AInt) (BAtom ANum).
Proof. exact base_order_int_num. Qed.

(* float ≡ num on 5.1 — "float" and "number" denote the SAME set (every number is
   a double). So AFloat is a synonym of ANum, not a distinct sibling type. *)
Theorem AFloat_equiv_ANum : dequiv (BAtom AFloat) (BAtom ANum).
Proof.
  split; unfold dsub; simpl; intros v H; destruct v as [ r | | | | | | | vs ];
    try destruct r; auto.
Qed.

(* AFloat is NOT all-integers either: a non-integer number inhabits AFloat but
   not AInt — so AInt is a PROPER subtype of AFloat (the edge is non-trivial). *)
Theorem not_float_sub_int : ~ dsub (BAtom AFloat) (BAtom AInt).
Proof.
  unfold dsub; intro H. specialize (H (VFloat 0)). simpl in H. apply H. exact I.
Qed.

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
  | BArrow _ _ => False
  (* references are OPAQUE leaves — outside the head-decidable fragment, like
     arrows (a location's content type is not head-observable). *)
  | BRef _     => False
  | BAnyRef    => False
  (* tuples inspect their components — outside the head-decidable fragment. *)
  | BTuple _   => False
  end.

(* ---- Head classes: canonical representatives ------------------------------
   [head v] collapses a value to the canonical representative of its
   classification class (erasing the payload). NOTE the number value [VNum]
   needs TWO representatives — [VInt 0 = VNum (NRint 0)] and [VFloat 0 = VNum
   (NRfrac 0)] — because [atom_denote AInt] distinguishes [NRint] from [NRfrac]
   (integer-valued vs non-integer). So although there is a SINGLE number VALUE
   constructor (5.1: one double), classification is determined by the
   [NRint]/[NRfrac] CLASS, and [head] preserves that class. [head_reps]
   enumerates the seven classes (two number reps + str/bool/nil + table + fun;
   the single table/fun representative is only sound for the [atomic] fragment —
   see [head]'s note). *)

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
  (* All functions collapse to the canonical empty function. SOUND ONLY for the
     [atomic] fragment (no [BArrow]): for atomic types [denote] never inspects a
     function's graph — every atom sends [VFun _] to the same answer — so one
     representative suffices. Arrows DO inspect the graph, which is why the
     head-enumeration decider is re-scoped to [atomic] and arrows are deferred. *)
  | VFun _ => VFun []
  (* All locations collapse to the canonical address 0. SOUND ONLY for the
     [atomic] fragment (no [BRef]/[BAnyRef]): for atomic types [denote] never
     inspects a location — every atom sends [VRef _] to the same answer — so one
     representative suffices. References are OPAQUE leaves (like arrows), excluded
     from [atomic], so the head-enumeration decider is not used on them. *)
  | VRef _ => VRef 0
  (* All value-sequences collapse to the canonical empty tuple. SOUND ONLY for the
     [atomic] fragment (no [BTuple]): for atomic types [denote] never inspects a
     sequence — every atom sends [VTup _] to the same answer — so one representative
     suffices. Tuples DO inspect components, so they are OPAQUE leaves (like arrows)
     excluded from [atomic]; the head-enumeration decider is not used on them. *)
  | VTup _ => VTup []
  end.

Definition head_reps : list V :=
  VInt 0 :: VFloat 0 :: VStr 0 :: VBool false :: VNil :: VTable [] :: VFun [] :: VRef 0 :: VTup [] :: nil.

(* [head v] is always one of the seven representatives. *)
Lemma head_in_reps : forall v, In (head v) head_reps.
Proof.
  intro v; destruct v as [ r | | | | | | | vs ]; try destruct r; simpl;
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
Proof. intros a v; destruct a; destruct v as [ r | | | | | | | vs ]; try destruct r; simpl; tauto. Qed.

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
  - contradiction.        (* BArrow: excluded by [atomic] *)
  - contradiction.        (* BRef: excluded by [atomic] *)
  - contradiction.        (* BAnyRef: excluded by [atomic] *)
  - contradiction.        (* BTuple: excluded by [atomic] *)
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
(* 5.1 number atoms by the decider: AInt <: AFloat TRUE; AFloat <: AInt FALSE;
   AFloat <: ANum and ANum <: AFloat BOTH TRUE (float ≡ number on 5.1). *)
Example dec_int_float   : decide_dsub (BAtom AInt) (BAtom AFloat) = true.
Proof. reflexivity. Qed.
Example dec_float_int   : decide_dsub (BAtom AFloat) (BAtom AInt) = false.
Proof. reflexivity. Qed.
Example dec_float_num   : decide_dsub (BAtom AFloat) (BAtom ANum) = true.
Proof. reflexivity. Qed.
Example dec_num_float   : decide_dsub (BAtom ANum) (BAtom AFloat) = true.
Proof. reflexivity. Qed.

(* AGREEMENT with the semantic [dsub]: each decided answer matches the truth.
   (true -> dsub; false -> ~dsub, via [decide_dsub_correct].) *)
Example agree_int_num : dsub (BAtom AInt) (BAtom ANum).
Proof. apply (decide_dsub_correct (BAtom AInt) (BAtom ANum) I I). reflexivity. Qed.
Example agree_int_float : dsub (BAtom AInt) (BAtom AFloat).
Proof. apply (decide_dsub_correct (BAtom AInt) (BAtom AFloat) I I). reflexivity. Qed.
Example agree_not_float_int : ~ dsub (BAtom AFloat) (BAtom AInt).
Proof.
  intro H. apply (decide_dsub_correct (BAtom AFloat) (BAtom AInt) I I) in H. discriminate H.
Qed.
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

(* ===========================================================================
   INCREMENT 6 — GENERAL EMPTINESS-BASED DECISION PROCEDURE (records).

   Increment 4's head-enumeration decider is correct only on the [atomic]
   fragment (no records); records inspect table CONTENTS, so a fixed finite set
   of head-representatives cannot witness the value space. This increment builds
   the standard MLstruct / semantic-subtyping decider:

     subtyping  =  EMPTINESS of  A ∧ ¬B    (the reduction lemma, GENERAL —
                                            [dsub_iff_empty], all [a b : BTy]).

   So the problem reduces to deciding emptiness of ONE type. We decide emptiness
   by DNF normalization + per-conjunct witness construction:

   - [to_dnf] / [to_dnf_neg] normalize a [BTy] to disjunctive normal form over
     LITERALS (positive/negative atom, positive/negative RECORD). With a negated-
     record literal [LNegRec] the normalization is FAITHFUL through records, so
     preservation [to_dnf_pres] holds UNCONDITIONALLY (uses [classic_denote'] /
     [denote_dec] for the De Morgan + double-negation directions). [Qed].

   - [find_wit_fuel n t] CONSTRUCTS a witness value of [t] (or [None]); emptiness
     is [None]. It works clause-by-clause: a scalar clause is decided by the six
     head-representatives (head-determined for non-positive-record literals); a
     record clause builds a witness table from the merged per-key field
     requirements ([field_inter]), recursing [find_wit_fuel] on the intersected
     field types; a single negated record is violated by an absent key or by a
     forced wrong value at one key.

   TERMINATION MEASURE: [rdepth t] — record-nesting depth. Each recursion into a
   field type strictly decreases [rdepth]; [find_wit_fuel] takes fuel
   [S (S (rdepth t))], a STRUCTURAL nat recursion (no [Fix], cannot loop).

   FRAGMENT (honestly delimited — see docs/proof-kernel.md):
   - [flat t]    : every record's field types are record-free ([no_rec]) — i.e.
                   records do not nest. (Covers atoms and one level of records:
                   exactly the record width/depth/atom-disjointness cases.)
   - [dnf_ok (to_dnf t)] : each record-clause of the DNF has AT MOST ONE negated
                   record. The COUPLED case (≥2 negated records sharing keys, from
                   unions of records on the right) is DEFERRED: that branch of
                   [clause_wit] returns [None], which keeps the decider GLOBALLY
                   SOUND ([find_wit_sound], unconditional); only COMPLETENESS is
                   fragment-restricted.

   [decide_empty_correct] / [gdecide_correct] : sound + complete under the
   fragment. [Qed]. Nested records and coupled negated records are the next
   increment (see docs/proof-kernel.md roadmap).
   =========================================================================== *)
(* ============ DNF machinery ============ *)
Inductive Lit :=
  | LPosAtom : Atom -> Lit
  | LNegAtom : Atom -> Lit
  | LPosRec  : list (string * BTy) -> Lit
  | LNegRec  : list (string * BTy) -> Lit
  (* INCREMENT 7 — ARROW literals. A positive/negative arrow literal carries the
     domain and codomain. The witness-finder DEFERS on any clause containing an
     arrow literal (so [gdecide] returns [DUnknown], never a wrong answer); the
     decision procedure does not yet decide arrow subtyping. *)
  | LPosArrow : BTy -> BTy -> Lit
  | LNegArrow : BTy -> BTy -> Lit
  (* SPLIT-STEP 1 — REFERENCE literals, mirroring the arrow literals exactly. A
     positive ref literal carries the content type ([LPosRef T] for [BRef T]);
     [LPosAnyRef]/[LNegAnyRef] are the content-agnostic any-ref. The witness-finder
     DEFERS on any clause containing a ref literal (so [gdecide] returns
     [DUnknown], never a wrong answer): ref subtyping is invariant and decided
     SYNTACTICALLY by [ssub] later, not by [gdecide]. *)
  | LPosRef : BTy -> Lit
  | LNegRef : BTy -> Lit
  | LPosAnyRef : Lit
  | LNegAnyRef : Lit
  (* MULTI-RETURN — TUPLE literals, mirroring the arrow/ref literals. The witness-
     finder DEFERS on any clause containing a tuple literal (so [gdecide] returns
     [DUnknown], never a wrong answer): tuple subtyping is not decided by [gdecide]. *)
  | LPosTuple : list BTy -> Lit
  | LNegTuple : list BTy -> Lit.

Definition denote_lit (l:Lit)(v:V) : Prop :=
  match l with
  | LPosAtom a => atom_denote a v
  | LNegAtom a => ~ atom_denote a v
  | LPosRec f  => denote (BRec f) v
  | LNegRec f  => ~ denote (BRec f) v
  | LPosArrow A B => denote (BArrow A B) v
  | LNegArrow A B => ~ denote (BArrow A B) v
  | LPosRef T => denote (BRef T) v
  | LNegRef T => ~ denote (BRef T) v
  | LPosAnyRef => denote BAnyRef v
  | LNegAnyRef => ~ denote BAnyRef v
  | LPosTuple Ts => denote (BTuple Ts) v
  | LNegTuple Ts => ~ denote (BTuple Ts) v
  end.

Definition Clause := list Lit.
Fixpoint denote_clause (c:Clause)(v:V) : Prop :=
  match c with [] => True | l::r => denote_lit l v /\ denote_clause r v end.

Definition Dnf := list Clause.
Fixpoint denote_dnf (d:Dnf)(v:V) : Prop :=
  match d with [] => False | c::r => denote_clause c v \/ denote_dnf r v end.

(* combinators *)
Definition dnf_or (d1 d2:Dnf) : Dnf := d1 ++ d2.
Definition dnf_and (d1 d2:Dnf) : Dnf :=
  flat_map (fun c1 => map (fun c2 => c1 ++ c2) d2) d1.

Lemma denote_clause_app : forall c1 c2 v,
  denote_clause (c1 ++ c2) v <-> denote_clause c1 v /\ denote_clause c2 v.
Proof.
  induction c1; intros c2 v; simpl.
  - tauto.
  - rewrite IHc1. tauto.
Qed.

Lemma denote_dnf_app : forall d1 d2 v,
  denote_dnf (d1 ++ d2) v <-> denote_dnf d1 v \/ denote_dnf d2 v.
Proof.
  induction d1; intros d2 v; simpl.
  - tauto.
  - rewrite IHd1. tauto.
Qed.

Lemma denote_dnf_or : forall d1 d2 v,
  denote_dnf (dnf_or d1 d2) v <-> denote_dnf d1 v \/ denote_dnf d2 v.
Proof. intros; apply denote_dnf_app. Qed.

Lemma denote_dnf_and : forall d1 d2 v,
  denote_dnf (dnf_and d1 d2) v <-> denote_dnf d1 v /\ denote_dnf d2 v.
Proof.
  induction d1; intros d2 v; unfold dnf_and; simpl.
  - tauto.
  - rewrite denote_dnf_app. fold (dnf_and d1 d2). rewrite IHd1.
    (* first part: map (fun c2 => a ++ c2) d2 *)
    assert (Hmap : denote_dnf (map (fun c2 => a ++ c2) d2) v
                   <-> denote_clause a v /\ denote_dnf d2 v).
    { clear IHd1. induction d2; simpl.
      - tauto.
      - rewrite denote_clause_app, IHd2. tauto. }
    rewrite Hmap. tauto.
Qed.

(* ============ neg_atomic fragment + to_dnf ============ *)
(* neg_atomic t: no BNeg has a BRec in its scope. Records may appear positively;
   negation may only be applied to (compositions of) atoms. *)
Fixpoint neg_atomic (t:BTy) : Prop :=
  match t with
  | BAtom _ => True | BTop => True | BBot => True
  | BUnion a b => neg_atomic a /\ neg_atomic b
  | BInter a b => neg_atomic a /\ neg_atomic b
  | BNeg a => neg_atomic a /\ (fix no_rec (s:BTy) : Prop :=
      match s with
      | BAtom _ | BTop | BBot => True
      | BUnion x y | BInter x y => no_rec x /\ no_rec y
      | BNeg x => no_rec x
      | BRec _ => False
      | BArrow _ _ => False
      | BRef _ => False
      | BAnyRef => False
      | BTuple _ => False end) a
  | BRec fields => (fix nar (fs:list (string*BTy)) : Prop :=
      match fs with [] => True | (_,T)::r => neg_atomic T /\ nar r end) fields
  (* arrows and references are NOT in the record-free decidable fragment (they
     defer). *)
  | BArrow _ _ => False
  | BRef _ => False
  | BAnyRef => False
  | BTuple _ => False
  end.

(* positive / negative DNF, mutually defined by structural recursion. *)
Fixpoint to_dnf (t:BTy) : Dnf :=
  match t with
  | BAtom a => [[LPosAtom a]]
  | BTop => [[]]            (* one empty clause: always true *)
  | BBot => []             (* no clause: always false *)
  | BUnion a b => dnf_or (to_dnf a) (to_dnf b)
  | BInter a b => dnf_and (to_dnf a) (to_dnf b)
  | BNeg a => to_dnf_neg a
  | BRec f => [[LPosRec f]]
  | BArrow A B => [[LPosArrow A B]]
  | BRef T => [[LPosRef T]]
  | BAnyRef => [[LPosAnyRef]]
  | BTuple Ts => [[LPosTuple Ts]]
  end
with to_dnf_neg (t:BTy) : Dnf :=
  match t with
  | BAtom a => [[LNegAtom a]]
  | BTop => []             (* ~Top = Bot *)
  | BBot => [[]]           (* ~Bot = Top *)
  | BUnion a b => dnf_and (to_dnf_neg a) (to_dnf_neg b)  (* De Morgan *)
  | BInter a b => dnf_or (to_dnf_neg a) (to_dnf_neg b)
  | BNeg a => to_dnf a     (* double negation *)
  | BRec f => [[LNegRec f]]
  | BArrow A B => [[LNegArrow A B]]
  | BRef T => [[LNegRef T]]
  | BAnyRef => [[LNegAnyRef]]
  | BTuple Ts => [[LNegTuple Ts]]
  end.

(* Preservation, mutual + UNCONDITIONAL. With [LNegRec] in the literal language,
   [to_dnf_neg] faithfully denotes negation even through records, so no fragment
   restriction is needed at the DNF level. (The fragment restriction reappears,
   if at all, only in the per-clause emptiness decider.) Bundled into one
   conjunction so a single structural fix discharges both directions; the De
   Morgan / double-negation directions use decidability of [denote]. *)
Lemma to_dnf_pres_both : forall t v,
  (denote_dnf (to_dnf t) v <-> denote t v)
  /\ (denote_dnf (to_dnf_neg t) v <-> ~ denote t v).
Proof.
  fix IH 1. intros t v. destruct t; simpl; split.
  - (* BAtom pos *) simpl. tauto.
  - (* BAtom neg *) simpl. tauto.
  - (* BTop pos *) simpl. tauto.
  - (* BTop neg *) simpl. tauto.
  - (* BBot pos *) simpl. tauto.
  - (* BBot neg *) simpl. tauto.
  - (* BUnion pos *) rewrite denote_dnf_or.
    rewrite (proj1 (IH t1 v)), (proj1 (IH t2 v)). tauto.
  - (* BUnion neg *) rewrite denote_dnf_and.
    rewrite (proj2 (IH t1 v)), (proj2 (IH t2 v)). tauto.
  - (* BInter pos *) rewrite denote_dnf_and.
    rewrite (proj1 (IH t1 v)), (proj1 (IH t2 v)). tauto.
  - (* BInter neg *) rewrite denote_dnf_or.
    rewrite (proj2 (IH t1 v)), (proj2 (IH t2 v)).
    destruct (classic_denote' t1 v); destruct (classic_denote' t2 v); tauto.
  - (* BNeg pos *) simpl. rewrite (proj2 (IH t v)). tauto.
  - (* BNeg neg *) simpl. rewrite (proj1 (IH t v)).
    destruct (classic_denote' t v); tauto.
  - (* BRec pos *) simpl. tauto.
  - (* BRec neg *) simpl. tauto.
  - (* BArrow pos *) simpl. tauto.
  - (* BArrow neg *) simpl. tauto.
  - (* BRef pos *) simpl. tauto.
  - (* BRef neg *) simpl. tauto.
  - (* BAnyRef pos *) simpl. tauto.
  - (* BAnyRef neg *) simpl. tauto.
  - (* BTuple pos *) simpl. tauto.
  - (* BTuple neg *) simpl. tauto.
Qed.

Definition to_dnf_pres : forall t v,
  (denote_dnf (to_dnf t) v <-> denote t v) := fun t v => proj1 (to_dnf_pres_both t v).
Definition to_dnf_neg_pres : forall t v,
  (denote_dnf (to_dnf_neg t) v <-> ~ denote t v) := fun t v => proj2 (to_dnf_pres_both t v).

(* record-nesting depth: the TERMINATION MEASURE. Each recursion into a record
   field type strictly decreases rdepth. *)
Fixpoint rdepth (t:BTy) : nat :=
  match t with
  | BAtom _ | BTop | BBot => 0
  | BUnion a b | BInter a b => Nat.max (rdepth a) (rdepth b)
  | BNeg a => rdepth a
  | BRec fs => S ((fix md (xs:list (string*BTy)) : nat :=
      match xs with [] => 0 | (_,T)::r => Nat.max (rdepth T) (md r) end) fs)
  (* arrows are never recursed into by the witness finder (arrow clauses defer),
     so they contribute no record-nesting depth of their own. *)
  | BArrow A B => Nat.max (rdepth A) (rdepth B)
  (* references are never recursed into by the witness finder (ref clauses defer),
     so they contribute no record-nesting depth of their own. *)
  | BRef T => rdepth T
  | BAnyRef => 0
  (* tuples are never recursed into by the witness finder (tuple clauses defer),
     so they contribute no record-nesting depth of their own. *)
  | BTuple Ts => (fix mt (xs:list BTy) : nat :=
      match xs with [] => 0 | T::r => Nat.max (rdepth T) (mt r) end) Ts
  end.

(* scalar-only clause satisfaction at a head value (only atom literals matter;
   a LPosRec literal is never present in the scalar branch). atoms_sat checks
   every literal at v, treating LPosRec as unsatisfiable for a scalar. *)
Definition lit_satb (l:Lit)(v:V) : bool :=
  match l with
  | LPosAtom a => if atom_dec a v then true else false
  | LNegAtom a => if atom_dec a v then false else true
  | LPosRec f  => if denote_dec (BRec f) v then true else false
  | LNegRec f  => if denote_dec (BRec f) v then false else true
  | LPosArrow A B => if denote_dec (BArrow A B) v then true else false
  | LNegArrow A B => if denote_dec (BArrow A B) v then false else true
  | LPosRef T => if denote_dec (BRef T) v then true else false
  | LNegRef T => if denote_dec (BRef T) v then false else true
  | LPosAnyRef => if denote_dec BAnyRef v then true else false
  | LNegAnyRef => if denote_dec BAnyRef v then false else true
  | LPosTuple Ts => if denote_dec (BTuple Ts) v then true else false
  | LNegTuple Ts => if denote_dec (BTuple Ts) v then false else true
  end.
Fixpoint clause_satb (c:Clause)(v:V) : bool :=
  match c with [] => true | l::r => lit_satb l v && clause_satb r v end.

Lemma lit_satb_iff : forall l v, lit_satb l v = true <-> denote_lit l v.
Proof.
  intros l v; destruct l; unfold lit_satb, denote_lit.
  - destruct (atom_dec a v) as [Ha|Ha]; split; intro H.
    + exact Ha.
    + reflexivity.
    + discriminate H.
    + contradiction.
  - destruct (atom_dec a v) as [Ha|Ha]; split; intro H.
    + discriminate H.
    + contradiction.
    + exact Ha.
    + reflexivity.
  - destruct (denote_dec (BRec l) v) as [Hd|Hd]; split; intro H.
    + exact Hd.
    + reflexivity.
    + discriminate H.
    + contradiction.
  - destruct (denote_dec (BRec l) v) as [Hd|Hd]; split; intro H.
    + discriminate H.
    + contradiction.
    + exact Hd.
    + reflexivity.
  - destruct (denote_dec (BArrow b b0) v) as [Hd|Hd]; split; intro H.
    + exact Hd.
    + reflexivity.
    + discriminate H.
    + contradiction.
  - destruct (denote_dec (BArrow b b0) v) as [Hd|Hd]; split; intro H.
    + discriminate H.
    + contradiction.
    + exact Hd.
    + reflexivity.
  - destruct (denote_dec (BRef b) v) as [Hd|Hd]; split; intro H.
    + exact Hd.
    + reflexivity.
    + discriminate H.
    + contradiction.
  - destruct (denote_dec (BRef b) v) as [Hd|Hd]; split; intro H.
    + discriminate H.
    + contradiction.
    + exact Hd.
    + reflexivity.
  - destruct (denote_dec BAnyRef v) as [Hd|Hd]; split; intro H.
    + exact Hd.
    + reflexivity.
    + discriminate H.
    + contradiction.
  - destruct (denote_dec BAnyRef v) as [Hd|Hd]; split; intro H.
    + discriminate H.
    + contradiction.
    + exact Hd.
    + reflexivity.
  - (* LPosTuple *) destruct (denote_dec (BTuple l) v) as [Hd|Hd]; split; intro H.
    + exact Hd.
    + reflexivity.
    + discriminate H.
    + contradiction.
  - (* LNegTuple *) destruct (denote_dec (BTuple l) v) as [Hd|Hd]; split; intro H.
    + discriminate H.
    + contradiction.
    + exact Hd.
    + reflexivity.
Qed.

Lemma clause_satb_iff : forall c v, clause_satb c v = true <-> denote_clause c v.
Proof.
  induction c; intros v; simpl.
  - split; [intros _; exact I | reflexivity].
  - rewrite andb_true_iff, lit_satb_iff, IHc. tauto.
Qed.

(* ===== field intersection ===== *)
(* fold all types listed at key k in fs into one BInter (BTop if none). *)
Fixpoint field_inter (k:string)(fs:list (string*BTy)) : BTy :=
  match fs with
  | [] => BTop
  | (k',T)::r => if string_dec k k' then BInter T (field_inter k r) else field_inter k r
  end.

(* membership in field_inter <-> conjunction over matching entries. *)
Lemma denote_field_inter : forall k fs v,
  denote (field_inter k fs) v <-> (forall T, In (k,T) fs -> denote T v).
Proof.
  induction fs as [|[k' T'] r IH]; intros v; simpl.
  - split; [intros _ T []| intros _; exact I].
  - destruct (string_dec k k') as [<-|Hne]; simpl.
    + rewrite IH. split.
      * intros [HT Hr] T [Heq|Hin]. injection Heq as <-. exact HT. apply Hr; exact Hin.
      * intros H. split. apply (H T'); left; reflexivity.
        intros T Hin. apply H; right; exact Hin.
    + rewrite IH. split.
      * intros Hr T [Heq|Hin]. injection Heq as Ek <-. congruence. apply Hr; exact Hin.
      * intros H T Hin. apply H; right; exact Hin.
Qed.

(* field_inter's types are drawn from fs; size bound proved later via subterm. *)

(* ===== the witness finder (fuel = tsize bound) ===== *)
(* clause analysis: collect positive records (as field-lists). *)
Fixpoint pos_recs (c:Clause) : list (list (string*BTy)) :=
  match c with [] => [] | LPosRec f :: r => f :: pos_recs r | _ :: r => pos_recs r end.
Fixpoint has_pos_atom (c:Clause) : bool :=
  match c with [] => false | LPosAtom _ :: _ => true | _ :: r => has_pos_atom r end.

(* INCREMENT 7 — does the clause contain an arrow literal? Any such clause is
   DEFERRED by the witness finder: arrow subtyping is not yet decided, so we never
   claim a witness exists OR that the clause is empty. This is what keeps the
   exported decider unconditionally sound in the presence of arrows. *)
Fixpoint has_arrow (c:Clause) : bool :=
  match c with
  | [] => false
  | LPosArrow _ _ :: _ => true
  | LNegArrow _ _ :: _ => true
  | _ :: r => has_arrow r
  end.

(* has_arrow distributes over clause append. *)
Lemma has_arrow_app : forall c1 c2,
  has_arrow (c1 ++ c2) = orb (has_arrow c1) (has_arrow c2).
Proof.
  induction c1 as [|l r IH]; simpl; intros c2.
  - reflexivity.
  - destruct l; simpl; try (rewrite IH; reflexivity); reflexivity.
Qed.

(* SPLIT-STEP 1 — does the clause contain a REFERENCE literal? Mirrors
   [has_arrow] exactly. Any clause carrying a ref literal is DEFERRED by the
   witness finder: ref subtyping is invariant and decided syntactically by [ssub]
   later, not by [gdecide]. So [gdecide] never gives a wrong answer about refs —
   it returns [DUnknown]. This keeps the exported decider unconditionally sound in
   the presence of references. *)
Fixpoint has_ref (c:Clause) : bool :=
  match c with
  | [] => false
  | LPosRef _ :: _ => true
  | LNegRef _ :: _ => true
  | LPosAnyRef :: _ => true
  | LNegAnyRef :: _ => true
  | _ :: r => has_ref r
  end.

(* has_ref distributes over clause append. *)
Lemma has_ref_app : forall c1 c2,
  has_ref (c1 ++ c2) = orb (has_ref c1) (has_ref c2).
Proof.
  induction c1 as [|l r IH]; simpl; intros c2.
  - reflexivity.
  - destruct l; simpl; try (rewrite IH; reflexivity); reflexivity.
Qed.

(* MULTI-RETURN — does the clause contain a TUPLE literal? Mirrors [has_arrow] /
   [has_ref] exactly. Any clause carrying a tuple literal is DEFERRED by the
   witness finder (so [gdecide] returns [DUnknown], never a wrong answer about
   tuples). This keeps the exported decider unconditionally sound with tuples. *)
Fixpoint has_tuple (c:Clause) : bool :=
  match c with
  | [] => false
  | LPosTuple _ :: _ => true
  | LNegTuple _ :: _ => true
  | _ :: r => has_tuple r
  end.

Lemma has_tuple_app : forall c1 c2,
  has_tuple (c1 ++ c2) = orb (has_tuple c1) (has_tuple c2).
Proof.
  induction c1 as [|l r IH]; simpl; intros c2.
  - reflexivity.
  - destruct l; simpl; try (rewrite IH; reflexivity); reflexivity.
Qed.

(* find first head rep satisfying all literals of a (scalar) clause. *)
Definition scalar_wit (c:Clause) : option V :=
  find (fun h => clause_satb c h) head_reps.

(* build a witness table from a field requirement list, given a per-key witness
   finder [wf : BTy -> option V]. Returns Some ents iff every key's intersected
   type yields a witness. *)
Definition table_wit (allf:list (string*BTy)) (wf:BTy -> option V) : option V :=
  if forallb (fun kT => match wf (field_inter (fst kT) allf) with Some _ => true | None => false end) allf
  then Some (VTable (map (fun kT => (fst kT, match wf (field_inter (fst kT) allf) with Some v => v | None => VNil end)) allf))
  else None.

(* negated records present in a clause. *)
Fixpoint neg_recs (c:Clause) : list (list (string*BTy)) :=
  match c with [] => [] | LNegRec f :: r => f :: neg_recs r | _ :: r => neg_recs r end.

Definition in_keys (k:string)(fs:list (string*BTy)) : bool :=
  existsb (fun kT => if string_dec k (fst kT) then true else false) fs.

(* first Some in a list of option V. *)
Fixpoint first_some (l:list (option V)) : option V :=
  match l with [] => None | Some v :: _ => Some v | None :: r => first_some r end.

(* table witness for a clause with positive fields [allf] and ONE negated record
   [Nj] to violate. Either Nj has a key not required by allf (base table omits it
   => violated by absence), or we force a wrong value at one of Nj's keys. *)
Definition table_wit_neg (allf Nj:list (string*BTy)) (wf:BTy -> option V) : option V :=
  if existsb (fun kT => negb (in_keys (fst kT) allf)) Nj
  then table_wit allf wf
  else first_some (map (fun kT =>
         table_wit (allf ++ [(fst kT, BNeg (field_inter (fst kT) Nj))]) wf) Nj).

Definition clause_wit (c:Clause) (wf:BTy -> option V) : option V :=
  if has_arrow c || has_ref c || has_tuple c then None    (* arrow/ref/tuple literal: DEFERRED *)
  else
  match pos_recs c with
  | [] => scalar_wit c
  | prs => if has_pos_atom c then None
           else match neg_recs c with
                | [] => table_wit (List.concat prs) wf
                | Nj :: nil => table_wit_neg (List.concat prs) Nj wf
                | _ :: _ :: _ =>
                    (* >1 negated record in a record clause: the coupled
                       field-constraint case, DEFERRED (out of the proven
                       fragment [clause_ok]). Returning None keeps the decider
                       globally SOUND (it never fabricates a false witness); only
                       COMPLETENESS is fragment-restricted. *)
                    None
                end
  end.

(* find witness over a whole DNF: first clause that yields one. *)
Fixpoint dnf_wit (d:Dnf) (wf:BTy -> option V) : option V :=
  match d with
  | [] => None
  | c :: r => match clause_wit c wf with Some v => Some v | None => dnf_wit r wf end
  end.

Fixpoint find_wit_fuel (n:nat) (t:BTy) : option V :=
  match n with
  | 0 => None
  | S n' => dnf_wit (to_dnf t) (find_wit_fuel n')
  end.

Definition decide_empty (t:BTy) : bool :=
  match find_wit_fuel (S (S (rdepth t))) t with None => true | Some _ => false end.

(* [gsub_empty] is the BOOL emptiness-of-(a∧¬b) test. It is FRAGMENT-restricted
   and — crucially — FAIL-OPTIMISTIC outside its fragment, exactly the latent
   trap an adversarial audit found: [find_wit_fuel] returns [None] both when it
   PROVED no witness and when it DEFERRED (the ≥2-coupled-negated-record branch
   of [clause_wit], and nested-record fuel exhaustion), and [None ⇒ true ⇒
   "subtype"]. So a bare [bool] conflates "proven subtype" with "decision
   deferred" and can answer "subtype" for a genuine non-subtype. It is retained
   ONLY as the internal workhorse for the proved-fragment correctness theorems
   ([gsub_empty_correct]); the EXPORTED decision is the three-valued [gdecide]
   below, which is UNCONDITIONALLY SOUND by construction. *)
Definition gsub_empty (a b:BTy) : bool := decide_empty (BInter a (BNeg b)).

(* sanity computes *)
Definition Rfg := BRec [("f"%string,BAtom AInt);("g"%string,BAtom ABool)].
Definition Rf  := BRec [("f"%string,BAtom AInt)].
Definition RfStr := BRec [("f"%string,BAtom AStr)].

(* ===================== CORRECTNESS ===================== *)

(* a literal is "scalar-head-monotone" iff it is not a positive record and not an
   arrow literal — exactly the literals whose denotation depends only on the
   value's head. (Positive records inspect contents; arrow literals inspect the
   graph; both break head-monotonicity.) *)
Definition lit_scalar (l:Lit) : bool :=
  match l with
  | LPosRec _ => false
  | LPosArrow _ _ => false
  | LNegArrow _ _ => false
  | LPosRef _ => false
  | LNegRef _ => false
  | LPosAnyRef => false
  | LNegAnyRef => false
  | LPosTuple _ => false
  | LNegTuple _ => false
  | _ => true
  end.

(* head monotonicity for scalar-head-monotone literals. *)
Lemma lit_denote_head : forall l v, lit_scalar l = true ->
  denote_lit l v -> denote_lit l (head v).
Proof.
  intros l v Hsc H. destruct l; simpl in *; try discriminate Hsc.
  - destruct a; destruct v as [ r | | | | | | | vs ]; try destruct r; simpl in *; tauto.
  - destruct a; destruct v as [ r | | | | | | | vs ]; try destruct r; simpl in *; tauto.
  - (* LNegRec: ~denote (BRec l) v -> ~denote (BRec l) (head v).
       head v is either a scalar / function (not a table => not in BRec) or
       VTable [] (which is in BRec l only if l = []; but then v was in BRec [] too). *)
    intro Hc. apply H. destruct v as [ r | | | | | | | vs ]; [ destruct r | | | | | | | ]; simpl in Hc.
    + destruct Hc as [ents [Hbad _]]; discriminate.
    + destruct Hc as [ents [Hbad _]]; discriminate.
    + destruct Hc as [ents [Hbad _]]; discriminate.
    + destruct Hc as [ents [Hbad _]]; discriminate.
    + destruct Hc as [ents [Hbad _]]; discriminate.
    + (* head (VTable l0) = VTable []; Hc : denote (BRec l) (VTable []) *)
      destruct Hc as [ents [Heq Hfields]]. injection Heq as <-.
      exists l0. split; [reflexivity|].
      destruct l as [|[k T] r]; simpl in *.
      * exact I.
      * destruct Hfields as [[vv [Hlk _]] _]. simpl in Hlk. discriminate Hlk.
    + (* head (VFun g) = VFun []; not a table, so BRec l fails (no ents) *)
      destruct Hc as [ents [Hbad _]]; discriminate.
    + (* head (VRef n) = VRef n; a location is not a table, so BRec l fails *)
      destruct Hc as [ents [Hbad _]]; discriminate.
    + (* head (VTup vs) = VTup []; a sequence is not a table, so BRec l fails *)
      destruct Hc as [ents [Hbad _]]; discriminate.
Qed.

(* a clause with no positive-record literal AND no arrow literal: every literal is
   head-monotone. *)
Fixpoint no_pos_rec (c:Clause) : Prop :=
  match c with [] => True | LPosRec _ :: _ => False
    | LPosArrow _ _ :: _ => False | LNegArrow _ _ :: _ => False
    | LPosRef _ :: _ => False | LNegRef _ :: _ => False
    | LPosAnyRef :: _ => False | LNegAnyRef :: _ => False
    | LPosTuple _ :: _ => False | LNegTuple _ :: _ => False
    | _ :: r => no_pos_rec r end.

Lemma pos_recs_nil_no_pos_rec : forall c,
  pos_recs c = [] -> has_arrow c = false -> has_ref c = false -> has_tuple c = false ->
  no_pos_rec c.
Proof.
  induction c as [|l r IH]; simpl; intros Hp Ha Hr Ht.
  - exact I.
  - destruct l; simpl in *;
      try (apply IH; [exact Hp | exact Ha | exact Hr | exact Ht]);
      try discriminate Hp; try discriminate Ha; try discriminate Hr; try discriminate Ht.
Qed.

Lemma clause_denote_head : forall c v, no_pos_rec c ->
  denote_clause c v -> denote_clause c (head v).
Proof.
  induction c as [|l r IH]; intros v Hnp Hd; simpl in *.
  - exact I.
  - destruct Hd as [Hl Hr]. destruct l; simpl in *.
    + split; [apply (lit_denote_head (LPosAtom a) v); [reflexivity|exact Hl]| apply IH; assumption].
    + split; [apply (lit_denote_head (LNegAtom a) v); [reflexivity|exact Hl]| apply IH; assumption].
    + contradiction.
    + split; [apply (lit_denote_head (LNegRec l) v); [reflexivity|exact Hl]| apply IH; assumption].
    + contradiction.
    + contradiction.
    + contradiction.   (* LPosRef: no_pos_rec is False *)
    + contradiction.   (* LNegRef *)
    + contradiction.   (* LPosAnyRef *)
    + contradiction.   (* LNegAnyRef *)
    + contradiction.   (* LPosTuple *)
    + contradiction.   (* LNegTuple *)
Qed.

Lemma scalar_wit_sound : forall c v, scalar_wit c = Some v -> denote_clause c v.
Proof.
  intros c v H. unfold scalar_wit in H. apply find_some in H. destruct H as [_ Hsat].
  apply clause_satb_iff. exact Hsat.
Qed.

Lemma scalar_wit_complete : forall c, no_pos_rec c ->
  scalar_wit c = None -> forall v, ~ denote_clause c v.
Proof.
  intros c Hnp H v Hd.
  (* Hnp : no_pos_rec c already implies head-monotonicity (excludes arrows too). *)
  (* head v is a rep; it satisfies c (head-monotone); but find returned None *)
  assert (Hh : denote_clause c (head v)) by (apply clause_denote_head; assumption).
  unfold scalar_wit in H.
  pose proof (find_none _ _ H (head v) (head_in_reps v)) as Hf. cbn beta in Hf.
  apply clause_satb_iff in Hh. rewrite Hh in Hf. discriminate Hf.
Qed.

(* ===== table_wit correctness ===== *)
(* the built entry list. *)
Definition built (allf:list (string*BTy))(wf:BTy->option V) : list (string*V) :=
  map (fun kT => (fst kT, match wf (field_inter (fst kT) allf) with Some v => v | None => VNil end)) allf.

(* lookup in the built table: if k occurs in allf, the looked-up value is the
   wf-witness of (field_inter k allf). *)
(* generalized: lookup over a list mapped by an arbitrary key-indexed [sel]. *)
Lemma assoc_lookup_map_sel : forall (sel:string->V)(fs:list (string*BTy)) k,
  (exists T, In (k,T) fs) ->
  assoc_lookup k (map (fun kT => (fst kT, sel (fst kT))) fs) = Some (sel k).
Proof.
  intros sel fs k. induction fs as [|[k0 T0] r IH]; simpl.
  - intros [T []].
  - intros [T Hin]. destruct (string_dec k k0) as [<-|Hne]; simpl.
    + reflexivity.
    + apply IH. destruct Hin as [Heq|Hin']. injection Heq as Ek <-. congruence.
      exists T; exact Hin'.
Qed.

Lemma built_lookup : forall allf wf k T,
  In (k,T) allf ->
  assoc_lookup k (built allf wf) = Some (match wf (field_inter k allf) with Some v => v | None => VNil end).
Proof.
  intros allf wf k T Hin. unfold built.
  apply (assoc_lookup_map_sel
           (fun kk => match wf (field_inter kk allf) with Some v => v | None => VNil end)
           allf k).
  exists T; exact Hin.
Qed.

(* a value MODELS a field requirement list: it is a table all of whose required
   fields are present at the right (per-key intersected) type. *)
Definition table_models (allf:list (string*BTy)) (v:V) : Prop :=
  exists ents, v = VTable ents /\
    forall k, (exists T, In (k,T) allf) ->
      exists w, assoc_lookup k ents = Some w /\ denote (field_inter k allf) w.

(* modeling allf => satisfies every positive record f whose fields ⊆ allf. *)
Lemma table_models_posrec : forall allf v f,
  (forall k T, In (k,T) f -> In (k,T) allf) ->
  table_models allf v -> denote (BRec f) v.
Proof.
  intros allf v f Hsub [ents [Hv Hall]]. subst v. exists ents. split; [reflexivity|].
  (* fold over f *)
  assert (Hgen : forall fs, (forall k T, In (k,T) fs -> In (k,T) allf) ->
    (fix af (xs:list (string*BTy)) : Prop := match xs with [] => True
      | (k,T)::rest => (exists vv, assoc_lookup k ents = Some vv /\ denote T vv) /\ af rest end) fs).
  { induction fs as [|[k T] r IH]; simpl; intros Hs.
    - exact I.
    - split.
      + destruct (Hall k (ex_intro _ T (Hs k T (or_introl eq_refl)))) as [w [Hlk Hw]].
        exists w. split; [exact Hlk|]. apply (denote_field_inter k allf w); [exact Hw|].
        apply Hs. left; reflexivity.
      + apply IH. intros k' T' Hin. apply Hs. right; exact Hin. }
  apply Hgen. exact Hsub.
Qed.

(* table is not a scalar: a VTable satisfies every negated atom literal. *)
Lemma table_neg_atom : forall ents a, ~ atom_denote a (VTable ents).
Proof. intros ents a. destruct a; simpl; auto. Qed.

(* table_wit soundness: if it returns a value, that value models allf. *)
Lemma table_wit_models : forall allf wf v,
  (forall T w, wf T = Some w -> denote T w) ->
  table_wit allf wf = Some v -> table_models allf v.
Proof.
  intros allf wf v Hwfs H. unfold table_wit in H.
  destruct (forallb (fun kT => match wf (field_inter (fst kT) allf) with Some _ => true | None => false end) allf) eqn:Hfb;
    [|discriminate H].
  injection H as <-. exists (built allf wf). split; [reflexivity|].
  intros k [T Hin].
  rewrite (built_lookup allf wf k T Hin).
  rewrite forallb_forall in Hfb.
  pose proof (Hfb (k,T) Hin) as Hk. simpl in Hk.
  destruct (wf (field_inter k allf)) as [w|] eqn:Ew; [|discriminate Hk].
  exists w. split; [reflexivity|]. apply Hwfs. exact Ew.
Qed.

(* forallb = false yields an explicit failing element. *)
Lemma forallb_false_in : forall (A:Type)(f:A->bool)(l:list A),
  forallb f l = false -> exists x, In x l /\ f x = false.
Proof.
  intros A f l. induction l as [|a r IH]; simpl; intros H.
  - discriminate.
  - destruct (f a) eqn:Ea; simpl in H.
    + destruct (IH H) as [x [Hin Hf]]. exists x. split; [right; exact Hin | exact Hf].
    + exists a. split; [left; reflexivity | exact Ea].
Qed.

(* the truly record-free predicate (no BRec anywhere) — needed early. Arrows are
   also excluded: an arrow type is not in the head-decidable record-free fragment
   (arrow clauses defer), so [no_rec (BArrow _ _) := False]. *)
Fixpoint no_rec (s:BTy) : Prop :=
  match s with
  | BAtom _ | BTop | BBot => True
  | BUnion x y | BInter x y => no_rec x /\ no_rec y
  | BNeg x => no_rec x
  | BRec _ => False
  | BArrow _ _ => False
  | BRef _ => False
  | BAnyRef => False
  | BTuple _ => False end.

(* field_inter over a list whose every field type is no_rec is no_rec. *)
Lemma field_inter_no_rec : forall k fs,
  (forall k0 T, In (k0,T) fs -> no_rec T) -> no_rec (field_inter k fs).
Proof.
  intros k fs. induction fs as [|[k0 T0] r IH]; simpl; intros H.
  - exact I.
  - destruct (string_dec k k0) as [<-|Hne]; simpl.
    + split; [apply (H k T0); left; reflexivity | apply IH; intros ka Ta Hin; apply (H ka Ta); right; exact Hin].
    + apply IH. intros ka Ta Hin. apply (H ka Ta). right; exact Hin.
Qed.

(* table_wit completeness: if None, some required key has an empty field type,
   so NO value can model allf. wf-completeness needed only on the queried
   field-intersection types, which are no_rec when allf's fields are no_rec. *)
Lemma table_wit_none : forall allf wf,
  (forall k0 T, In (k0,T) allf -> no_rec T) ->
  (forall T, no_rec T -> wf T = None -> forall v, ~ denote T v) ->
  table_wit allf wf = None -> forall v, ~ table_models allf v.
Proof.
  intros allf wf Hnr Hwfc H v Hm. unfold table_wit in H.
  destruct (forallb (fun kT => match wf (field_inter (fst kT) allf) with Some _ => true | None => false end) allf) eqn:Hfb;
    [discriminate H|].
  destruct (forallb_false_in _ _ _ Hfb) as [[k T] [Hin Hk]]. simpl in Hk.
  destruct (wf (field_inter k allf)) as [w|] eqn:Ew; [discriminate Hk|].
  destruct Hm as [ents [Hv Hall]].
  destruct (Hall k (ex_intro _ T Hin)) as [w [Hlk Hw]].
  exact (Hwfc _ (field_inter_no_rec k allf Hnr) Ew w Hw).
Qed.

(* ===== decompose a table clause's denotation into record requirements ===== *)
Lemma denote_clause_of_table : forall c ents,
  has_pos_atom c = false -> has_arrow c = false -> has_ref c = false ->
  has_tuple c = false ->
  (forall f, In f (pos_recs c) -> denote (BRec f) (VTable ents)) ->
  (forall g, In g (neg_recs c) -> ~ denote (BRec g) (VTable ents)) ->
  denote_clause c (VTable ents).
Proof.
  induction c as [|l r IH]; intros ents Hpa Hha Href Htu Hpr Hnr; simpl in *.
  - exact I.
  - destruct l; simpl in *.
    + discriminate Hpa.   (* LPosAtom excluded *)
    + split; [apply table_neg_atom | apply IH; auto].
    + split; [apply Hpr; left; reflexivity | apply IH; auto].
    + split; [apply Hnr; left; reflexivity | apply IH; auto].
    + discriminate Hha.   (* LPosArrow excluded by has_arrow=false *)
    + discriminate Hha.   (* LNegArrow excluded *)
    + discriminate Href.  (* LPosRef excluded by has_ref=false *)
    + discriminate Href.  (* LNegRef excluded *)
    + discriminate Href.  (* LPosAnyRef excluded *)
    + discriminate Href.  (* LNegAnyRef excluded *)
    + discriminate Htu.   (* LPosTuple excluded by has_tuple=false *)
    + discriminate Htu.   (* LNegTuple excluded *)
Qed.

Lemma denote_clause_components : forall c v,
  denote_clause c v ->
  (forall f, In f (pos_recs c) -> denote (BRec f) v) /\
  (forall g, In g (neg_recs c) -> ~ denote (BRec g) v).
Proof.
  induction c as [|l r IH]; intros v Hd; simpl in *.
  - split; intros ? [].
  - destruct l; simpl in *; destruct Hd as [Hl Hr]; destruct (IH v Hr) as [Hpr Hnr].
    + split; assumption.
    + split; assumption.
    + split; [intros f [Hf|Hf]; [subst; exact Hl | apply Hpr; exact Hf] | exact Hnr].
    + split; [exact Hpr | intros g [Hg|Hg]; [subst; exact Hl | apply Hnr; exact Hg]].
    + split; assumption.   (* LPosArrow: pos_recs/neg_recs unchanged *)
    + split; assumption.   (* LNegArrow *)
    + split; assumption.   (* LPosRef: pos_recs/neg_recs unchanged *)
    + split; assumption.   (* LNegRef *)
    + split; assumption.   (* LPosAnyRef *)
    + split; assumption.   (* LNegAnyRef *)
    + split; assumption.   (* LPosTuple *)
    + split; assumption.   (* LNegTuple *)
Qed.

(* a value satisfying any positive record is a table. *)
Lemma posrec_is_table : forall f v, denote (BRec f) v -> exists ents, v = VTable ents.
Proof. intros f v [ents [Hv _]]. exists ents; exact Hv. Qed.

(* In f prs => f's fields ⊆ concat prs. *)
Lemma in_concat_sub : forall (prs:list (list (string*BTy))) f k T,
  In f prs -> In (k,T) f -> In (k,T) (List.concat prs).
Proof.
  intros prs f k T Hf Hkt. apply in_concat. exists f; split; assumption.
Qed.

(* a value modeling (concat prs) satisfies every positive record in prs. *)
Lemma table_models_allpos : forall prs v,
  table_models (List.concat prs) v -> forall f, In f prs -> denote (BRec f) v.
Proof.
  intros prs v Hm f Hf. apply (table_models_posrec (List.concat prs) v f).
  - intros k T Hkt. apply (in_concat_sub prs f); assumption.
  - exact Hm.
Qed.

(* extract a field from a positive-record membership. *)
Lemma denote_rec_field : forall f ents k T,
  In (k,T) f -> denote (BRec f) (VTable ents) ->
  exists w, assoc_lookup k ents = Some w /\ denote T w.
Proof.
  intros f ents k T Hin Hd. destruct Hd as [ents' [Heq Hfold]]. injection Heq as <-.
  revert Hin Hfold. induction f as [|[k0 T0] r IH]; simpl; intros Hin Hfold.
  - contradiction.
  - destruct Hfold as [Hhd Htl]. destruct Hin as [Heq|Hin'].
    + injection Heq as <- <-. exact Hhd.
    + apply IH; assumption.
Qed.

(* conversely: if v (a table) satisfies every positive record in prs, it models
   concat prs (every required field present at the per-key intersected type). *)
Lemma allpos_table_models : forall prs ents,
  (forall f, In f prs -> denote (BRec f) (VTable ents)) ->
  table_models (List.concat prs) (VTable ents).
Proof.
  intros prs ents Hpos. exists ents. split; [reflexivity|].
  intros k [T Hin].
  (* the looked-up value at k (from any record requiring k) is unique; it lies in
     every type at k, hence in field_inter k (concat prs). *)
  (* first get SOME witness via the entry (k,T). *)
  apply in_concat in Hin. destruct Hin as [f0 [Hf0 Hkt0]].
  destruct (denote_rec_field f0 ents k T Hkt0 (Hpos f0 Hf0)) as [w [Hlk _]].
  exists w. split; [exact Hlk|].
  apply denote_field_inter. intros T' Hin'.
  apply in_concat in Hin'. destruct Hin' as [f1 [Hf1 Hkt1]].
  destruct (denote_rec_field f1 ents k T' Hkt1 (Hpos f1 Hf1)) as [w' [Hlk' Hw']].
  rewrite Hlk in Hlk'. injection Hlk' as <-. exact Hw'.
Qed.

(* ===== algebra of field_inter and in_keys ===== *)
Lemma field_inter_app : forall k l1 l2 v,
  denote (field_inter k (l1 ++ l2)) v <-> (denote (field_inter k l1) v /\ denote (field_inter k l2) v).
Proof.
  intros k l1 l2 v. rewrite !denote_field_inter. split.
  - intros H. split; intros T HT; apply H; apply in_or_app; [left|right]; exact HT.
  - intros [H1 H2] T HT. apply in_app_or in HT. destruct HT; [apply H1|apply H2]; assumption.
Qed.

Lemma field_inter_single : forall k X v,
  denote (field_inter k [(k,X)]) v <-> denote X v.
Proof.
  intros k X v. simpl. destruct (string_dec k k) as [_|Hne]; [|congruence].
  simpl. tauto.
Qed.

Lemma in_keys_true : forall k fs, in_keys k fs = true <-> exists T, In (k,T) fs.
Proof.
  intros k fs. unfold in_keys. rewrite existsb_exists. split.
  - intros [[k0 T0] [Hin Hdec]]. simpl in Hdec. destruct (string_dec k k0); [|discriminate].
    subst. exists T0; exact Hin.
  - intros [T Hin]. exists (k,T). split; [exact Hin|]. simpl.
    destruct (string_dec k k); [reflexivity|congruence].
Qed.

Lemma in_keys_false : forall k fs, in_keys k fs = false <-> ~ exists T, In (k,T) fs.
Proof.
  intros k fs. rewrite <- not_true_iff_false, in_keys_true. tauto.
Qed.

(* ===== violation of a negated record ===== *)
(* lookup of a key NOT in allf returns None in the built table. *)
Lemma assoc_lookup_map_none : forall (g:string*BTy->V)(fs:list (string*BTy)) k,
  (~ exists T, In (k,T) fs) -> assoc_lookup k (map (fun kT => (fst kT, g kT)) fs) = None.
Proof.
  intros g fs k. induction fs as [|[k0 T0] r IH]; simpl; intros Hni.
  - reflexivity.
  - destruct (string_dec k k0) as [<-|Hne].
    + exfalso. apply Hni. exists T0. left; reflexivity.
    + apply IH. intros [T Hin]. apply Hni. exists T. right; exact Hin.
Qed.

Lemma built_lookup_none : forall allf wf k,
  (~ exists T, In (k,T) allf) -> assoc_lookup k (built allf wf) = None.
Proof.
  intros allf wf k Hni. unfold built. apply assoc_lookup_map_none. exact Hni.
Qed.

(* if some Nj-key is absent in ents, BRec Nj fails. *)
Lemma violate_absent : forall Nj ents k T,
  In (k,T) Nj -> assoc_lookup k ents = None -> ~ denote (BRec Nj) (VTable ents).
Proof.
  intros Nj ents k T Hin Hnone Hd.
  destruct (denote_rec_field Nj ents k T Hin Hd) as [w [Hlk _]].
  rewrite Hnone in Hlk. discriminate Hlk.
Qed.

(* if at some Nj-key the value violates field_inter k Nj, BRec Nj fails. *)
Lemma violate_value : forall Nj ents k w,
  assoc_lookup k ents = Some w -> (exists T, In (k,T) Nj) ->
  ~ denote (field_inter k Nj) w -> ~ denote (BRec Nj) (VTable ents).
Proof.
  intros Nj ents k w Hlk [T Hin] Hnv Hd.
  apply Hnv. apply denote_field_inter. intros T' Hin'.
  destruct (denote_rec_field Nj ents k T' Hin' Hd) as [w' [Hlk' Hw']].
  rewrite Hlk in Hlk'. injection Hlk' as <-. exact Hw'.
Qed.

(* models is monotone: modeling a larger requirement list implies modeling a prefix. *)
Lemma table_models_app_l : forall l1 l2 v,
  table_models (l1 ++ l2) v -> table_models l1 v.
Proof.
  intros l1 l2 v [ents [Hv Hall]]. exists ents. split; [exact Hv|].
  intros k [T Hin].
  destruct (Hall k (ex_intro _ T (in_or_app _ _ _ (or_introl Hin)))) as [w [Hlk Hw]].
  exists w. split; [exact Hlk|]. apply (field_inter_app k l1 l2 w) in Hw. tauto.
Qed.

(* first_some semantics. *)
Lemma first_some_some : forall l v, first_some l = Some v -> In (Some v) l.
Proof.
  induction l as [|x r IH]; simpl; intros v H.
  - discriminate.
  - destruct x as [w|]. injection H as <-. left; reflexivity. right; apply IH; exact H.
Qed.

Lemma first_some_none : forall l, first_some l = None -> forall x, In x l -> x = None.
Proof.
  induction l as [|x r IH]; simpl; intros H y Hin.
  - contradiction.
  - destruct x as [w|]. discriminate H. destruct Hin as [<-|Hin']. reflexivity. apply IH; assumption.
Qed.

(* ===== table_wit_neg correctness ===== *)
(* "models allf and violates Nj" — the spec a table-clause-with-one-neg needs. *)
Definition tmv (allf Nj:list (string*BTy)) (v:V) : Prop :=
  table_models allf v /\ ~ denote (BRec Nj) v.

Lemma table_wit_neg_sound : forall allf Nj wf v,
  (forall T w, wf T = Some w -> denote T w) ->
  table_wit_neg allf Nj wf = Some v -> tmv allf Nj v.
Proof.
  intros allf Nj wf v Hwfs H. unfold table_wit_neg in H.
  destruct (existsb (fun kT => negb (in_keys (fst kT) allf)) Nj) eqn:Habs.
  - (* absence branch: v = table_wit allf wf, violates Nj by an absent key *)
    pose proof (table_wit_models allf wf v Hwfs H) as Hm. split; [exact Hm|].
    apply existsb_exists in Habs. destruct Habs as [[k T] [Hin Hneg]].
    simpl in Hneg. apply negb_true_iff in Hneg.
    rewrite in_keys_false in Hneg.
    (* v is the built table; lookup k = None *)
    destruct Hm as [ents [Hv _]].
    unfold table_wit in H.
    destruct (forallb _ allf) eqn:Hfb; [|discriminate H]. injection H as <-.
    injection Hv as <-.
    apply (violate_absent Nj (built allf wf) k T Hin).
    apply built_lookup_none. exact Hneg.
  - (* value branch: v from some key kT of Nj, augmented requirement *)
    pose proof (first_some_some _ _ H) as Hinmap.
    rewrite in_map_iff in Hinmap. destruct Hinmap as [[k T] [Heq Hin]].
    simpl in Heq.
    (* Heq : table_wit (allf ++ [(k, BNeg (field_inter k Nj))]) wf = Some v *)
    pose proof (table_wit_models _ wf v Hwfs Heq) as Hm.
    split.
    + apply (table_models_app_l allf [(k, BNeg (field_inter k Nj))]). exact Hm.
    + (* v models the augmented list; at key k, value ∉ field_inter k Nj => violates Nj *)
      destruct Hm as [ents [Hv Hall]]. subst v.
      assert (Hink : In (k, BNeg (field_inter k Nj)) (allf ++ [(k, BNeg (field_inter k Nj))])).
      { apply in_or_app. right. left. reflexivity. }
      destruct (Hall k (ex_intro _ (BNeg (field_inter k Nj)) Hink)) as [w [Hlk Hw]].
      apply (field_inter_app k allf [(k, BNeg (field_inter k Nj))] w) in Hw.
      destruct Hw as [_ Hw2]. rewrite field_inter_single in Hw2. simpl in Hw2.
      apply (violate_value Nj ents k w Hlk).
      * exists T; exact Hin.
      * exact Hw2.
Qed.

(* if BRec Nj fails on a table whose every Nj-key is present, the failure is a
   wrong VALUE at some Nj key. *)
Lemma violation_wrong_key : forall Nj ents,
  (forall k T, In (k,T) Nj -> exists w, assoc_lookup k ents = Some w) ->
  ~ denote (BRec Nj) (VTable ents) ->
  exists k T w, In (k,T) Nj /\ assoc_lookup k ents = Some w /\ ~ denote T w.
Proof.
  induction Nj as [|[k0 T0] r IH]; intros ents Hpres Hviol; simpl in *.
  - exfalso. apply Hviol. exists ents. split; [reflexivity| exact I].
  - (* either head fails or rest fails *)
    destruct (Hpres k0 T0 (or_introl eq_refl)) as [w0 Hlk0].
    destruct (denote_dec T0 w0) as [Hd0 | Hnd0].
    + (* head ok; recurse on r *)
      assert (Hviolr : ~ denote (BRec r) (VTable ents)).
      { intro Hr. apply Hviol. destruct Hr as [ents' [Heq Hrf]]. injection Heq as <-.
        exists ents. split; [reflexivity|]. split.
        - exists w0. split; [exact Hlk0 | exact Hd0].
        - exact Hrf. }
      destruct (IH ents (fun k T Hin => Hpres k T (or_intror Hin)) Hviolr)
        as [k [T [w [Hin [Hlk Hnd]]]]].
      exists k, T, w. split; [right; exact Hin | split; assumption].
    + (* head fails: that's our witness *)
      exists k0, T0, w0. split; [left; reflexivity | split; [exact Hlk0 | exact Hnd0]].
Qed.

(* helper: existsb false => forall element predicate false. *)
Lemma existsb_false_forall : forall (A:Type)(f:A->bool)(l:list A),
  existsb f l = false -> forall x, In x l -> f x = false.
Proof.
  intros A f l H x Hin. destruct (f x) eqn:E; [|reflexivity].
  exfalso. assert (existsb f l = true) by (apply existsb_exists; exists x; auto).
  rewrite H in *; discriminate.
Qed.

Lemma table_wit_neg_complete : forall allf Nj wf,
  (forall k0 T, In (k0,T) allf -> no_rec T) ->
  (forall k0 T, In (k0,T) Nj -> no_rec T) ->
  (forall T, no_rec T -> wf T = None -> forall v, ~ denote T v) ->
  table_wit_neg allf Nj wf = None -> forall v, ~ tmv allf Nj v.
Proof.
  intros allf Nj wf HnrA HnrN Hwfc H v [Hm Hviol]. unfold table_wit_neg in H.
  destruct (existsb (fun kT => negb (in_keys (fst kT) allf)) Nj) eqn:Habs.
  - (* absence branch returned None: table_wit allf wf = None => no model of allf *)
    exact (table_wit_none allf wf HnrA Hwfc H v Hm).
  - (* value branch: every Nj key is in allf (Habs=false), so present in v;
       violation is by a wrong value => that key's augmented table_wit is Some,
       contradicting first_some=None. *)
    destruct Hm as [ents [Hv Hall]]. subst v.
    (* all Nj keys present *)
    assert (Hpres : forall k T, In (k,T) Nj -> exists w, assoc_lookup k ents = Some w).
    { intros k T Hin.
      pose proof (existsb_false_forall _ _ _ Habs (k,T) Hin) as Hf. simpl in Hf.
      apply negb_false_iff in Hf. rewrite in_keys_true in Hf.
      destruct (Hall k Hf) as [w [Hlk _]]. exists w; exact Hlk. }
    destruct (violation_wrong_key Nj ents Hpres Hviol) as [k [T [w [Hin [Hlk Hnd]]]]].
    (* from ~denote T w with In (k,T) Nj, get ~denote (field_inter k Nj) w *)
    assert (Hnfi : ~ denote (field_inter k Nj) w).
    { intro Hc. apply Hnd. rewrite denote_field_inter in Hc. apply Hc; exact Hin. }
    (* the augmented table_wit at key (k,T) should be Some, but first_some=None *)
    pose proof (first_some_none _ H
      (table_wit (allf ++ [(fst (k,T), BNeg (field_inter (fst (k,T)) Nj))]) wf)
      (in_map _ _ (k,T) Hin)) as Hnone. simpl in Hnone.
    assert (HnrAug : forall k0 T0, In (k0,T0) (allf ++ [(k, BNeg (field_inter k Nj))]) -> no_rec T0).
    { intros k0 T0 Hin0. apply in_app_or in Hin0. destruct Hin0 as [Hin0|Hin0].
      - apply (HnrA k0 T0 Hin0).
      - simpl in Hin0. destruct Hin0 as [Heq|[]]. injection Heq as <- <-.
        simpl. apply field_inter_no_rec. exact HnrN. }
    pose proof (table_wit_none (allf ++ [(k, BNeg (field_inter k Nj))]) wf HnrAug Hwfc Hnone (VTable ents)) as Hno.
    apply Hno.
    (* k is in allf (Habs=false => in_keys k allf=true): get its allf membership *)
    assert (HkA : exists T', In (k,T') allf).
    { pose proof (existsb_false_forall _ _ _ Habs (k,T) Hin) as Hf. simpl in Hf.
      apply negb_false_iff in Hf. rewrite in_keys_true in Hf. exact Hf. }
    (* the value at k lies in field_inter k allf *)
    assert (HwA : denote (field_inter k allf) w).
    { destruct (Hall k HkA) as [w' [Hlk' Hw']]. rewrite Hlk in Hlk'. injection Hlk' as <-.
      exact Hw'. }
    (* VTable ents models allf ++ [(k, ¬field_inter k Nj)] *)
    exists ents. split; [reflexivity|].
    intros k0 [T0 Hin0].
    apply in_app_or in Hin0. destruct Hin0 as [Hin0|Hin0].
    + destruct (Hall k0 (ex_intro _ T0 Hin0)) as [w0 [Hlk0 Hw0]].
      exists w0. split; [exact Hlk0|]. rewrite field_inter_app; split; [exact Hw0|].
      simpl. destruct (string_dec k0 k) as [Ek|Hne]; simpl.
      * subst k0. rewrite Hlk in Hlk0. injection Hlk0 as <-.
        split; [exact Hnfi | exact I].
      * exact I.
    + simpl in Hin0. destruct Hin0 as [Heq|[]]. injection Heq as <- <-.
      exists w. split; [exact Hlk|]. rewrite field_inter_app; split; [exact HwA|].
      simpl. destruct (string_dec k k) as [_|Hne]; [|congruence]. simpl.
      split; [exact Hnfi | exact I].
Qed.

(* ===== clause_wit correctness (under the clause fragment predicate) ===== *)
(* A clause is in the DECIDED fragment iff it has no positive record (pure
   scalar/atom/neg-record clause, handled by head enumeration) OR it has at most
   one negated record. The >1-negated-record-in-a-record-clause case (coupled
   field constraints) is DEFERRED. *)
Definition clause_ok (c:Clause) : Prop :=
  pos_recs c = [] \/ Datatypes.length (neg_recs c) <= 1.

(* wf spec: sound + complete witness finder for smaller types. *)
Definition wf_ok (wf:BTy->option V) : Prop :=
  (forall T w, wf T = Some w -> denote T w) /\
  (forall T, wf T = None -> forall v, ~ denote T v).

(* SOUNDNESS is GLOBAL — needs only wf-soundness, no fragment hypothesis: the
   >1-negated-record branch returns None, so no false witness is ever produced. *)
Lemma clause_wit_sound : forall c wf v,
  (forall T w, wf T = Some w -> denote T w) -> clause_wit c wf = Some v -> denote_clause c v.
Proof.
  intros c wf v Hwfs H. unfold clause_wit in H.
  destruct (has_arrow c) eqn:Hha; [discriminate H|].
  destruct (has_ref c) eqn:Href; [discriminate H|].
  destruct (has_tuple c) eqn:Htu; [discriminate H|]. simpl in H.
  destruct (pos_recs c) as [|p ps] eqn:Hpr.
  - (* scalar branch *) apply scalar_wit_sound. exact H.
  - (* record clause *)
    destruct (has_pos_atom c) eqn:Hpa; [discriminate H|].
    destruct (neg_recs c) as [|Nj rest] eqn:Hnr.
    + (* no negated records *)
      pose proof (table_wit_models _ wf v Hwfs H) as Hm.
      destruct Hm as [ents [Hv Hall]]. subst v.
      apply denote_clause_of_table; [exact Hpa | exact Hha | exact Href | exact Htu | | ].
      * intros f Hf. apply (table_models_allpos (pos_recs c)).
        rewrite Hpr. exists ents; split; [reflexivity| exact Hall]. exact Hf.
      * rewrite Hnr. intros g [].
    + destruct rest as [|Nj2 rest2].
      * (* exactly one negated record *)
        pose proof (table_wit_neg_sound (List.concat (p::ps)) Nj wf v Hwfs H) as Hs.
        destruct Hs as [Hm Hviol].
        destruct Hm as [ents [Hv Hall]]. subst v.
        apply denote_clause_of_table; [exact Hpa | exact Hha | exact Href | exact Htu | | ].
        -- intros f Hf. apply (table_models_allpos (pos_recs c)).
           rewrite Hpr. exists ents; split; [reflexivity| exact Hall]. exact Hf.
        -- rewrite Hnr. intros g [Hg|[]]. subst g. exact Hviol.
      * (* >1 negated record: clause_wit returned None, contradicting H *)
        discriminate H.
Qed.

Definition fields_no_rec (f:list (string*BTy)) : Prop := forall k T, In (k,T) f -> no_rec T.
Definition good_clause (c:Clause) : Prop :=
  (forall f, In f (pos_recs c) -> fields_no_rec f) /\
  (forall f, In f (neg_recs c) -> fields_no_rec f).

Lemma clause_wit_complete : forall c wf,
  (forall T, no_rec T -> wf T = None -> forall v, ~ denote T v) ->
  has_arrow c = false -> has_ref c = false -> has_tuple c = false ->
  good_clause c -> clause_ok c -> clause_wit c wf = None -> forall v, ~ denote_clause c v.
Proof.
  intros c wf Hwfc Hna Hnref Hntu [Hgp Hgn] Hok H v Hd. unfold clause_wit in H.
  rewrite Hna, Hnref, Hntu in H. simpl in H.
  destruct (pos_recs c) as [|p ps] eqn:Hpr.
  - (* scalar *) apply (scalar_wit_complete c (pos_recs_nil_no_pos_rec c Hpr Hna Hnref Hntu) H v Hd).
  - (* record clause: v must be a table satisfying all positive records *)
    destruct (has_pos_atom c) eqn:Hpa.
    + (* has_pos_atom = true AND a positive record present: v would be both a
         scalar and a table — impossible. *)
      clear H Hok.
      assert (Hpex : In p (pos_recs c)) by (rewrite Hpr; left; reflexivity).
      pose proof (denote_clause_components c v Hd) as [Hprc _].
      destruct (posrec_is_table p v (Hprc p Hpex)) as [ents Hve]. subst v.
      (* now show some positive atom holds at VTable ents — contradiction *)
      clear Hpr Hpex Hprc Hgp Hgn Hwfc Hna Hnref Hntu. revert Hd Hpa. induction c as [|l r IH]; simpl; intros Hd Hpa.
      * discriminate Hpa.
      * destruct Hd as [Hl Hd]. destruct l; simpl in *.
        -- apply (table_neg_atom ents a); exact Hl.
        -- apply IH; assumption.
        -- apply IH; assumption.
        -- apply IH; assumption.
        -- exact Hl.   (* LPosArrow: denote (BArrow _ _) (VTable _) = False *)
        -- apply IH; assumption.   (* LNegArrow: ~denote arrow holds; recurse *)
        -- exact Hl.   (* LPosRef: denote (BRef _) (VTable _) = False *)
        -- apply IH; assumption.   (* LNegRef: ~denote ref holds; recurse *)
        -- exact Hl.   (* LPosAnyRef: denote BAnyRef (VTable _) = False *)
        -- apply IH; assumption.   (* LNegAnyRef *)
        -- exact Hl.   (* LPosTuple: denote (BTuple _) (VTable _) = False *)
        -- apply IH; assumption.   (* LNegTuple *)
    + (* no positive atom *)
      pose proof (denote_clause_components c v Hd) as [Hprc Hnrc].
      (* v is a table (satisfies p, a positive record) *)
      assert (Hpex : In p (pos_recs c)) by (rewrite Hpr; left; reflexivity).
      destruct (posrec_is_table p v (Hprc p Hpex)) as [ents ->].
      assert (Hmodels : table_models (List.concat (p::ps)) (VTable ents)).
      { apply allpos_table_models. intros f Hf. apply Hprc. rewrite Hpr. exact Hf. }
      (* fields of concat(p::ps) are no_rec (good_clause positive part) *)
      assert (HnrAllf : forall k0 T, In (k0,T) (List.concat (p::ps)) -> no_rec T).
      { intros k0 T Hin. apply in_concat in Hin. destruct Hin as [f [Hf Hkt]].
        exact (Hgp f Hf k0 T Hkt). }
      destruct (neg_recs c) as [|Nj rest] eqn:Hnr.
      * (* no neg records *)
        apply (table_wit_none _ wf HnrAllf Hwfc H (VTable ents)). exact Hmodels.
      * destruct rest as [|Nj2 rest2].
        -- (* one neg record *)
           assert (HnrNj : forall k0 T, In (k0,T) Nj -> no_rec T).
           { intros k0 T Hin. apply (Hgn Nj (or_introl eq_refl) k0 T Hin). }
           apply (table_wit_neg_complete (List.concat (p::ps)) Nj wf HnrAllf HnrNj Hwfc H (VTable ents)).
           split.
           ++ exact Hmodels.
           ++ exact (Hnrc Nj (or_introl eq_refl)).
        -- exfalso. destruct Hok as [Hpr0|Hlen].
           ++ rewrite Hpr in Hpr0; discriminate.
           ++ rewrite Hnr in Hlen; simpl in Hlen; lia.
Qed.

(* ===== the input fragment: records with neg_atomic (record-free) fields ===== *)
(* fields_flat fs: every field type is neg_atomic (no nested records). *)
Definition fields_flat (fs:list (string*BTy)) : Prop :=
  forall k T, In (k,T) fs -> neg_atomic T.

(* record-free AND arrow-free clause predicate (a pure scalar/atom clause,
   decided by head enumeration; wf never consulted). *)
Definition cl_rf (c:Clause) : Prop :=
  pos_recs c = [] /\ neg_recs c = [] /\ has_arrow c = false /\ has_ref c = false
  /\ has_tuple c = false.

Lemma pos_recs_app : forall c1 c2, pos_recs (c1 ++ c2) = pos_recs c1 ++ pos_recs c2.
Proof. induction c1 as [|l r IH]; simpl; intros c2. reflexivity. destruct l; simpl; rewrite IH; reflexivity. Qed.
Lemma neg_recs_app : forall c1 c2, neg_recs (c1 ++ c2) = neg_recs c1 ++ neg_recs c2.
Proof. induction c1 as [|l r IH]; simpl; intros c2. reflexivity. destruct l; simpl; rewrite IH; reflexivity. Qed.

Lemma cl_rf_app : forall c1 c2, cl_rf c1 -> cl_rf c2 -> cl_rf (c1 ++ c2).
Proof.
  intros c1 c2 [Hp1 [Hn1 [Ha1 [Hr1 Ht1]]]] [Hp2 [Hn2 [Ha2 [Hr2 Ht2]]]]. unfold cl_rf.
  rewrite pos_recs_app, neg_recs_app, has_arrow_app, has_ref_app, has_tuple_app.
  rewrite Hp1, Hp2, Hn1, Hn2, Ha1, Ha2, Hr1, Hr2, Ht1, Ht2.
  split; [reflexivity | split; [reflexivity | split; [reflexivity | split; reflexivity]]].
Qed.

Lemma Forall_cl_rf_and : forall d1 d2,
  Forall cl_rf d1 -> Forall cl_rf d2 -> Forall cl_rf (dnf_and d1 d2).
Proof.
  intros d1 d2 H1 H2. unfold dnf_and. apply Forall_flat_map.
  rewrite Forall_forall in H1 |- *. intros c1 Hc1.
  apply Forall_map. rewrite Forall_forall. intros c2 Hc2.
  apply cl_rf_app; [apply H1; exact Hc1 | rewrite Forall_forall in H2; apply H2; exact Hc2].
Qed.

Lemma Forall_cl_rf_or : forall d1 d2,
  Forall cl_rf d1 -> Forall cl_rf d2 -> Forall cl_rf (dnf_or d1 d2).
Proof. intros d1 d2 H1 H2. unfold dnf_or. apply Forall_app. split; assumption. Qed.

Lemma no_rec_no_rec_lits : forall t,
  no_rec t -> Forall cl_rf (to_dnf t) /\ Forall cl_rf (to_dnf_neg t).
Proof.
  fix IH 1. intros t Hnr. destruct t; simpl in *.
  - split; (constructor; [split; [reflexivity | split; [reflexivity | split; [reflexivity | split; reflexivity]]] | constructor]).
  - split; [ (constructor; [split; [reflexivity | split; [reflexivity | split; [reflexivity | split; reflexivity]]] | constructor]) | constructor ].
  - split; [ constructor | (constructor; [split; [reflexivity | split; [reflexivity | split; [reflexivity | split; reflexivity]]] | constructor]) ].
  - destruct Hnr as [Ha Hb]. split.
    + apply Forall_cl_rf_or; [apply (IH t1 Ha)| apply (IH t2 Hb)].
    + apply Forall_cl_rf_and; [apply (IH t1 Ha)| apply (IH t2 Hb)].
  - destruct Hnr as [Ha Hb]. split.
    + apply Forall_cl_rf_and; [apply (IH t1 Ha)| apply (IH t2 Hb)].
    + apply Forall_cl_rf_or; [apply (IH t1 Ha)| apply (IH t2 Hb)].
  - split; [ apply (proj2 (IH t Hnr)) | apply (proj1 (IH t Hnr)) ].
  - contradiction.       (* BRec: no_rec is False *)
  - contradiction.       (* BArrow: no_rec is False *)
  - contradiction.       (* BRef: no_rec is False *)
  - contradiction.       (* BAnyRef: no_rec is False *)
  - contradiction.       (* BTuple: no_rec is False *)
Qed.

(* clauses that are record-free are clause_ok. *)
Lemma cl_rf_ok : forall c, cl_rf c -> clause_ok c.
Proof. intros c [Hp _]. left; exact Hp. Qed.

Lemma cl_rf_no_arrow : forall c, cl_rf c -> has_arrow c = false.
Proof. intros c [_ [_ [Ha _]]]. exact Ha. Qed.

Lemma cl_rf_no_ref : forall c, cl_rf c -> has_ref c = false.
Proof. intros c [_ [_ [_ [Hr _]]]]. exact Hr. Qed.

Lemma cl_rf_no_tuple : forall c, cl_rf c -> has_tuple c = false.
Proof. intros c [_ [_ [_ [_ Ht]]]]. exact Ht. Qed.

Definition dnf_ok (d:Dnf) : Prop := Forall clause_ok d.

(* no_rec field types in every record literal of a clause. *)
(* flat t: every BRec subterm has no_rec field types. *)
Fixpoint flat (t:BTy) : Prop :=
  match t with
  | BAtom _ | BTop | BBot => True
  | BUnion a b | BInter a b => flat a /\ flat b
  | BNeg a => flat a
  | BRec fs => (fix ff (xs:list (string*BTy)) : Prop :=
      match xs with [] => True | (_,T)::r => no_rec T /\ ff r end) fs
  (* arrows and references are outside the proven-complete fragment (they defer). *)
  | BArrow _ _ => False
  | BRef _ => False
  | BAnyRef => False
  | BTuple _ => False
  end.

Lemma no_rec_flat : forall t, no_rec t -> flat t.
Proof.
  fix IH 1. intros t H. destruct t; simpl in *; try exact I.
  - destruct H; split; [apply IH|apply IH]; assumption.
  - destruct H; split; [apply IH|apply IH]; assumption.
  - apply IH; exact H.
  - contradiction.       (* BRec *)
  - contradiction.       (* BArrow *)
  - contradiction.       (* BRef *)
  - contradiction.       (* BAnyRef *)
  - contradiction.       (* BTuple *)
Qed.

(* field types of a flat record are no_rec. *)
Lemma flat_field_no_rec : forall fs k T,
  (fix ff (xs:list (string*BTy)) : Prop :=
     match xs with [] => True | (_,T)::r => no_rec T /\ ff r end) fs ->
  In (k,T) fs -> no_rec T.
Proof.
  induction fs as [|[k0 T0] r IH]; simpl; intros k T Hff Hin.
  - contradiction.
  - destruct Hff as [Hh Ht]. destruct Hin as [Heq|Hin']. injection Heq as <- <-. exact Hh.
    apply (IH k T Ht Hin').
Qed.


Lemma good_clause_app : forall c1 c2, good_clause c1 -> good_clause c2 -> good_clause (c1 ++ c2).
Proof.
  intros c1 c2 [Hp1 Hn1] [Hp2 Hn2]. unfold good_clause.
  rewrite pos_recs_app, neg_recs_app. split.
  - intros f Hin. apply in_app_or in Hin. destruct Hin as [Hin|Hin]; [apply Hp1|apply Hp2]; exact Hin.
  - intros f Hin. apply in_app_or in Hin. destruct Hin as [Hin|Hin]; [apply Hn1|apply Hn2]; exact Hin.
Qed.

Lemma good_clause_and : forall d1 d2,
  Forall good_clause d1 -> Forall good_clause d2 -> Forall good_clause (dnf_and d1 d2).
Proof.
  intros d1 d2 H1 H2. unfold dnf_and. apply Forall_flat_map.
  rewrite Forall_forall in H1 |- *. intros c1 Hc1. apply Forall_map.
  rewrite Forall_forall. intros c2 Hc2. apply good_clause_app;
    [apply H1; exact Hc1 | rewrite Forall_forall in H2; apply H2; exact Hc2].
Qed.
Lemma good_clause_or : forall d1 d2,
  Forall good_clause d1 -> Forall good_clause d2 -> Forall good_clause (dnf_or d1 d2).
Proof. intros d1 d2 H1 H2. unfold dnf_or. apply Forall_app; split; assumption. Qed.

(* flat t => every record literal in the DNF carries no_rec field types. *)
Lemma flat_good_clauses : forall t,
  flat t -> Forall good_clause (to_dnf t) /\ Forall good_clause (to_dnf_neg t).
Proof.
  fix IH 1. intros t Hf. destruct t; simpl in *.
  - split; (repeat constructor); intros f [].
  - split; [ repeat constructor; intros f [] | constructor ].
  - split; [ constructor | repeat constructor; intros f [] ].
  - destruct Hf as [Ha Hb]. split.
    + apply good_clause_or; [apply (IH t1 Ha)|apply (IH t2 Hb)].
    + apply good_clause_and; [apply (IH t1 Ha)|apply (IH t2 Hb)].
  - destruct Hf as [Ha Hb]. split.
    + apply good_clause_and; [apply (IH t1 Ha)|apply (IH t2 Hb)].
    + apply good_clause_or; [apply (IH t1 Ha)|apply (IH t2 Hb)].
  - split; [ apply (proj2 (IH t Hf)) | apply (proj1 (IH t Hf)) ].
  - (* BRec: to_dnf = [[LPosRec l]], to_dnf_neg = [[LNegRec l]] *)
    split; (constructor; [|constructor]).
    + split; [ intros f [Heq|[]]; subst f; intros k T Hin; exact (flat_field_no_rec l k T Hf Hin)
             | intros f [] ].
    + split; [ intros f [] | intros f [Heq|[]]; subst f; intros k T Hin; exact (flat_field_no_rec l k T Hf Hin) ].
  - (* BArrow: flat is False, vacuous *) contradiction.
  - (* BRef: flat is False *) contradiction.
  - (* BAnyRef: flat is False *) contradiction.
  - (* BTuple: flat is False *) contradiction.
Qed.

Definition dnf_no_arrow (d:Dnf) : Prop := Forall (fun c => has_arrow c = false) d.

Lemma dnf_no_arrow_and : forall d1 d2,
  dnf_no_arrow d1 -> dnf_no_arrow d2 -> dnf_no_arrow (dnf_and d1 d2).
Proof.
  intros d1 d2 H1 H2. unfold dnf_no_arrow, dnf_and in *. apply Forall_flat_map.
  rewrite Forall_forall in H1 |- *. intros c1 Hc1. apply Forall_map.
  rewrite Forall_forall. intros c2 Hc2.
  rewrite Forall_forall in H2.
  rewrite has_arrow_app. rewrite (H1 c1 Hc1). rewrite (H2 c2 Hc2). reflexivity.
Qed.

Lemma dnf_no_arrow_or : forall d1 d2,
  dnf_no_arrow d1 -> dnf_no_arrow d2 -> dnf_no_arrow (dnf_or d1 d2).
Proof. intros d1 d2 H1 H2. unfold dnf_no_arrow, dnf_or. apply Forall_app; split; assumption. Qed.

(* flat t => every clause of its DNF (positive or negated) is arrow-literal-free.
   Since [flat (BArrow _ _) = False], no arrow appears in a flat type at all, so
   [to_dnf]/[to_dnf_neg] emit no arrow literals. *)
Lemma flat_no_arrow : forall t,
  flat t -> dnf_no_arrow (to_dnf t) /\ dnf_no_arrow (to_dnf_neg t).
Proof.
  fix IH 1. intros t Hf. destruct t; simpl in *.
  - split; repeat constructor.
  - split; [repeat constructor | constructor].
  - split; [constructor | repeat constructor].
  - destruct Hf as [Ha Hb]. split.
    + apply dnf_no_arrow_or; [apply (IH t1 Ha)|apply (IH t2 Hb)].
    + apply dnf_no_arrow_and; [apply (IH t1 Ha)|apply (IH t2 Hb)].
  - destruct Hf as [Ha Hb]. split.
    + apply dnf_no_arrow_and; [apply (IH t1 Ha)|apply (IH t2 Hb)].
    + apply dnf_no_arrow_or; [apply (IH t1 Ha)|apply (IH t2 Hb)].
  - split; [apply (proj2 (IH t Hf)) | apply (proj1 (IH t Hf))].
  - (* BRec: literals are LPosRec / LNegRec, has_arrow = false *)
    split; repeat constructor.
  - (* BArrow: flat is False *) contradiction.
  - (* BRef: flat is False *) contradiction.
  - (* BAnyRef: flat is False *) contradiction.
  - (* BTuple: flat is False *) contradiction.
Qed.

(* SPLIT-STEP 1 — the [has_ref]-free analog of [dnf_no_arrow]. A [flat] type
   contains no [BRef]/[BAnyRef] subterm ([flat] sends them to [False]), so its
   DNF emits no ref literals. Mirrors [dnf_no_arrow] / [flat_no_arrow] exactly. *)
Definition dnf_no_ref (d:Dnf) : Prop := Forall (fun c => has_ref c = false) d.

Lemma dnf_no_ref_and : forall d1 d2,
  dnf_no_ref d1 -> dnf_no_ref d2 -> dnf_no_ref (dnf_and d1 d2).
Proof.
  intros d1 d2 H1 H2. unfold dnf_no_ref, dnf_and in *. apply Forall_flat_map.
  rewrite Forall_forall in H1 |- *. intros c1 Hc1. apply Forall_map.
  rewrite Forall_forall. intros c2 Hc2.
  rewrite Forall_forall in H2.
  rewrite has_ref_app. rewrite (H1 c1 Hc1). rewrite (H2 c2 Hc2). reflexivity.
Qed.

Lemma dnf_no_ref_or : forall d1 d2,
  dnf_no_ref d1 -> dnf_no_ref d2 -> dnf_no_ref (dnf_or d1 d2).
Proof. intros d1 d2 H1 H2. unfold dnf_no_ref, dnf_or. apply Forall_app; split; assumption. Qed.

Lemma flat_no_ref : forall t,
  flat t -> dnf_no_ref (to_dnf t) /\ dnf_no_ref (to_dnf_neg t).
Proof.
  fix IH 1. intros t Hf. destruct t; simpl in *.
  - split; repeat constructor.
  - split; [repeat constructor | constructor].
  - split; [constructor | repeat constructor].
  - destruct Hf as [Ha Hb]. split.
    + apply dnf_no_ref_or; [apply (IH t1 Ha)|apply (IH t2 Hb)].
    + apply dnf_no_ref_and; [apply (IH t1 Ha)|apply (IH t2 Hb)].
  - destruct Hf as [Ha Hb]. split.
    + apply dnf_no_ref_and; [apply (IH t1 Ha)|apply (IH t2 Hb)].
    + apply dnf_no_ref_or; [apply (IH t1 Ha)|apply (IH t2 Hb)].
  - split; [apply (proj2 (IH t Hf)) | apply (proj1 (IH t Hf))].
  - (* BRec: literals are LPosRec / LNegRec, has_ref = false *)
    split; repeat constructor.
  - (* BArrow: flat is False *) contradiction.
  - (* BRef: flat is False *) contradiction.
  - (* BAnyRef: flat is False *) contradiction.
  - (* BTuple: flat is False *) contradiction.
Qed.

(* MULTI-RETURN — the [has_tuple]-free analog of [dnf_no_arrow]/[dnf_no_ref]. A
   [flat] type contains no [BTuple] subterm ([flat] sends it to [False]), so its
   DNF emits no tuple literals. Mirrors the arrow/ref versions exactly. *)
Definition dnf_no_tuple (d:Dnf) : Prop := Forall (fun c => has_tuple c = false) d.

Lemma dnf_no_tuple_and : forall d1 d2,
  dnf_no_tuple d1 -> dnf_no_tuple d2 -> dnf_no_tuple (dnf_and d1 d2).
Proof.
  intros d1 d2 H1 H2. unfold dnf_no_tuple, dnf_and in *. apply Forall_flat_map.
  rewrite Forall_forall in H1 |- *. intros c1 Hc1. apply Forall_map.
  rewrite Forall_forall. intros c2 Hc2.
  rewrite Forall_forall in H2.
  rewrite has_tuple_app. rewrite (H1 c1 Hc1). rewrite (H2 c2 Hc2). reflexivity.
Qed.

Lemma dnf_no_tuple_or : forall d1 d2,
  dnf_no_tuple d1 -> dnf_no_tuple d2 -> dnf_no_tuple (dnf_or d1 d2).
Proof. intros d1 d2 H1 H2. unfold dnf_no_tuple, dnf_or. apply Forall_app; split; assumption. Qed.

Lemma flat_no_tuple : forall t,
  flat t -> dnf_no_tuple (to_dnf t) /\ dnf_no_tuple (to_dnf_neg t).
Proof.
  fix IH 1. intros t Hf. destruct t; simpl in *.
  - split; repeat constructor.
  - split; [repeat constructor | constructor].
  - split; [constructor | repeat constructor].
  - destruct Hf as [Ha Hb]. split.
    + apply dnf_no_tuple_or; [apply (IH t1 Ha)|apply (IH t2 Hb)].
    + apply dnf_no_tuple_and; [apply (IH t1 Ha)|apply (IH t2 Hb)].
  - destruct Hf as [Ha Hb]. split.
    + apply dnf_no_tuple_and; [apply (IH t1 Ha)|apply (IH t2 Hb)].
    + apply dnf_no_tuple_or; [apply (IH t1 Ha)|apply (IH t2 Hb)].
  - split; [apply (proj2 (IH t Hf)) | apply (proj1 (IH t Hf))].
  - (* BRec: literals are LPosRec / LNegRec, has_tuple = false *)
    split; repeat constructor.
  - (* BArrow: flat is False *) contradiction.
  - (* BRef: flat is False *) contradiction.
  - (* BAnyRef: flat is False *) contradiction.
  - (* BTuple: flat is False *) contradiction.
Qed.

Lemma no_rec_rdepth0 : forall t, no_rec t -> rdepth t = 0.
Proof.
  fix IH 1. intro t. destruct t; simpl; intro H; try reflexivity.
  - destruct H. rewrite (IH t1), (IH t2); auto.
  - destruct H. rewrite (IH t1), (IH t2); auto.
  - apply IH; exact H.
  - contradiction.       (* BRec *)
  - contradiction.       (* BArrow *)
  - contradiction.       (* BRef: rdepth (BRef T) = rdepth T, needs no_rec=False *)
  (* BAnyRef: rdepth BAnyRef = 0, closed by [reflexivity] above *)
  - contradiction.       (* BTuple: no_rec is False *)
Qed.

(* records appearing in the DNF of t have rdepth <= rdepth t. *)
Definition clause_recs_shallow (d:nat)(c:Clause) : Prop :=
  (forall f, In f (pos_recs c) -> rdepth (BRec f) <= d) /\
  (forall f, In f (neg_recs c) -> rdepth (BRec f) <= d).

Lemma clause_recs_shallow_app : forall d c1 c2,
  clause_recs_shallow d c1 -> clause_recs_shallow d c2 -> clause_recs_shallow d (c1 ++ c2).
Proof.
  intros d c1 c2 [Hp1 Hn1] [Hp2 Hn2]. unfold clause_recs_shallow.
  rewrite pos_recs_app, neg_recs_app. split; intros f Hin; apply in_app_or in Hin.
  - destruct Hin; [apply Hp1|apply Hp2]; assumption.
  - destruct Hin; [apply Hn1|apply Hn2]; assumption.
Qed.

Lemma crs_mono : forall d d' c, d <= d' -> clause_recs_shallow d c -> clause_recs_shallow d' c.
Proof.
  intros d d' c Hle [Hp Hn]. split; intros f Hin;
    [pose proof (Hp f Hin)|pose proof (Hn f Hin)]; lia.
Qed.

Lemma Forall_crs_and : forall d d1 d2,
  Forall (clause_recs_shallow d) d1 -> Forall (clause_recs_shallow d) d2 ->
  Forall (clause_recs_shallow d) (dnf_and d1 d2).
Proof.
  intros d d1 d2 H1 H2. unfold dnf_and. apply Forall_flat_map.
  rewrite Forall_forall in H1 |- *. intros c1 Hc1. apply Forall_map. rewrite Forall_forall.
  intros c2 Hc2. apply clause_recs_shallow_app;
    [apply H1; exact Hc1 | rewrite Forall_forall in H2; apply H2; exact Hc2].
Qed.
Lemma Forall_crs_or : forall d d1 d2,
  Forall (clause_recs_shallow d) d1 -> Forall (clause_recs_shallow d) d2 ->
  Forall (clause_recs_shallow d) (dnf_or d1 d2).
Proof. intros d d1 d2 H1 H2. unfold dnf_or. apply Forall_app; split; assumption. Qed.

Lemma Forall_crs_mono : forall d d' dd,
  d <= d' -> Forall (clause_recs_shallow d) dd -> Forall (clause_recs_shallow d') dd.
Proof.
  intros d d' dd Hle. apply Forall_impl. intros c Hc. apply (crs_mono d d' c Hle Hc).
Qed.

Lemma dnf_recs_shallow : forall t,
  Forall (clause_recs_shallow (rdepth t)) (to_dnf t)
  /\ Forall (clause_recs_shallow (rdepth t)) (to_dnf_neg t).
Proof.
  fix IH 1. intro t. destruct t; simpl.
  - split; (constructor; [split; intros f []|constructor]).
  - split; [ constructor; [split; intros f []|constructor] | constructor ].
  - split; [ constructor | constructor; [split; intros f []|constructor] ].
  - split.
    + apply Forall_crs_or.
      * apply (Forall_crs_mono (rdepth t1)); [lia | apply (proj1 (IH t1))].
      * apply (Forall_crs_mono (rdepth t2)); [lia | apply (proj1 (IH t2))].
    + apply Forall_crs_and.
      * apply (Forall_crs_mono (rdepth t1)); [lia | apply (proj2 (IH t1))].
      * apply (Forall_crs_mono (rdepth t2)); [lia | apply (proj2 (IH t2))].
  - split.
    + apply Forall_crs_and.
      * apply (Forall_crs_mono (rdepth t1)); [lia | apply (proj1 (IH t1))].
      * apply (Forall_crs_mono (rdepth t2)); [lia | apply (proj1 (IH t2))].
    + apply Forall_crs_or.
      * apply (Forall_crs_mono (rdepth t1)); [lia | apply (proj2 (IH t1))].
      * apply (Forall_crs_mono (rdepth t2)); [lia | apply (proj2 (IH t2))].
  - split; [ apply (proj2 (IH t)) | apply (proj1 (IH t)) ].
  - (* BRec l: to_dnf = [[LPosRec l]]; rdepth (BRec l) <= rdepth (BRec l) *)
    split; (constructor; [|constructor]).
    + split; [ intros f [Heq|[]]; subst f; apply Nat.le_refl | intros f [] ].
    + split; [ intros f [] | intros f [Heq|[]]; subst f; apply Nat.le_refl ].
  - (* BArrow: to_dnf = [[LPosArrow A B]] — pos_recs/neg_recs are empty, so
       clause_recs_shallow is vacuous. *)
    split; (constructor; [split; intros f []|constructor]).
  - (* BRef: to_dnf = [[LPosRef T]] — pos_recs/neg_recs empty, vacuous. *)
    split; (constructor; [split; intros f []|constructor]).
  - (* BAnyRef: to_dnf = [[LPosAnyRef]] — pos_recs/neg_recs empty, vacuous. *)
    split; (constructor; [split; intros f []|constructor]).
  - (* BTuple: to_dnf = [[LPosTuple Ts]] — pos_recs/neg_recs empty, vacuous. *)
    split; (constructor; [split; intros f []|constructor]).
Qed.

(* ===== dnf_wit correctness ===== *)
Lemma dnf_wit_sound : forall d wf v,
  (forall T w, wf T = Some w -> denote T w) -> dnf_wit d wf = Some v -> denote_dnf d v.
Proof.
  induction d as [|c r IH]; intros wf v Hwfs H; simpl in *.
  - discriminate.
  - destruct (clause_wit c wf) as [w|] eqn:Ec.
    + injection H as Hwv. left. rewrite <- Hwv. apply (clause_wit_sound c wf w Hwfs Ec).
    + right. apply (IH wf v Hwfs H).
Qed.

Lemma dnf_wit_complete : forall d wf,
  (forall T, no_rec T -> wf T = None -> forall v, ~ denote T v) ->
  dnf_no_arrow d -> dnf_no_ref d -> dnf_no_tuple d ->
  Forall good_clause d -> dnf_ok d -> dnf_wit d wf = None -> forall v, ~ denote_dnf d v.
Proof.
  induction d as [|c r IH]; intros wf Hwfc Hna Href Htu Hgd Hok H v Hd; simpl in *.
  - exact Hd.
  - pose proof (Forall_inv Hgd) as Hgc. pose proof (Forall_inv_tail Hgd) as Hgr.
    pose proof (Forall_inv Hok) as Hokc. pose proof (Forall_inv_tail Hok) as Hokr.
    pose proof (Forall_inv Hna) as Hnac. pose proof (Forall_inv_tail Hna) as Hnar.
    pose proof (Forall_inv Href) as Hrefc. pose proof (Forall_inv_tail Href) as Hrefr.
    pose proof (Forall_inv Htu) as Htuc. pose proof (Forall_inv_tail Htu) as Htur.
    destruct (clause_wit c wf) as [w|] eqn:Ec; [discriminate H|].
    destruct Hd as [Hd|Hd].
    + exact (clause_wit_complete c wf Hwfc Hnac Hrefc Htuc Hgc Hokc Ec v Hd).
    + exact (IH wf Hwfc Hnar Hrefr Htur Hgr Hokr H v Hd).
Qed.

(* ===== MASTER: find_wit_fuel soundness (GLOBAL, unconditional) ===== *)
Lemma find_wit_sound : forall n t v, find_wit_fuel n t = Some v -> denote t v.
Proof.
  induction n as [|n IHn]; intros t v H; simpl in H.
  - discriminate.
  - (* find_wit_fuel (S n) t = dnf_wit (to_dnf t) (find_wit_fuel n) *)
    apply to_dnf_pres.
    apply (dnf_wit_sound (to_dnf t) (find_wit_fuel n) v).
    + intros T w. apply IHn.
    + exact H.
Qed.

(* ===== completeness for RECORD-FREE DNF: wf is never consulted ===== *)
(* a scalar clause (cl_rf) is decided by scalar_wit, ignoring wf. *)
Lemma clause_wit_scalar : forall c wf, cl_rf c -> clause_wit c wf = scalar_wit c.
Proof.
  intros c wf [Hp [_ [Ha [Hr Ht]]]]. unfold clause_wit. rewrite Ha, Hr, Ht, Hp. reflexivity.
Qed.

Lemma dnf_wit_complete_scalar : forall d wf,
  Forall cl_rf d -> dnf_wit d wf = None -> forall v, ~ denote_dnf d v.
Proof.
  induction d as [|c r IH]; intros wf Hcl H v Hd; simpl in *.
  - exact Hd.
  - pose proof (Forall_inv Hcl) as Hc. pose proof (Forall_inv_tail Hcl) as Hr.
    rewrite (clause_wit_scalar c wf Hc) in H.
    destruct (scalar_wit c) eqn:Es; [discriminate H|].
    destruct Hd as [Hd|Hd].
    + apply (scalar_wit_complete c
               (pos_recs_nil_no_pos_rec c (proj1 Hc) (cl_rf_no_arrow c Hc) (cl_rf_no_ref c Hc)
                  (cl_rf_no_tuple c Hc)) Es v Hd).
    + exact (IH wf Hr H v Hd).
Qed.

(* find_wit on a no_rec type: complete at any positive fuel, wf-independent. *)
Lemma find_wit_norec_complete : forall n T,
  no_rec T -> find_wit_fuel (S n) T = None -> forall v, ~ denote T v.
Proof.
  intros n T Hnr H v Hd. simpl in H.
  apply (dnf_wit_complete_scalar (to_dnf T) (find_wit_fuel n)
           (proj1 (no_rec_no_rec_lits T Hnr)) H v).
  apply to_dnf_pres. exact Hd.
Qed.

(* ===== MASTER completeness + the decision-procedure correctness ===== *)
Lemma find_wit_complete : forall t,
  flat t -> dnf_ok (to_dnf t) ->
  find_wit_fuel (S (S (rdepth t))) t = None -> forall v, ~ denote t v.
Proof.
  intros t Hflat Hok H v Hd. simpl in H.
  apply (dnf_wit_complete (to_dnf t) (find_wit_fuel (S (rdepth t)))
           (fun T HT => find_wit_norec_complete (rdepth t) T HT)
           (proj1 (flat_no_arrow t Hflat))
           (proj1 (flat_no_ref t Hflat))
           (proj1 (flat_no_tuple t Hflat))
           (proj1 (flat_good_clauses t Hflat))
           Hok H v).
  apply to_dnf_pres. exact Hd.
Qed.

(* decide_empty is sound + complete on the fragment [flat t] (records have
   record-free field types) with [dnf_ok (to_dnf t)] (<=1 negated record per
   record-clause). *)
Theorem decide_empty_correct : forall t,
  flat t -> dnf_ok (to_dnf t) ->
  (decide_empty t = true <-> (forall v, ~ denote t v)).
Proof.
  intros t Hflat Hok. unfold decide_empty.
  destruct (find_wit_fuel (S (S (rdepth t))) t) as [w|] eqn:E.
  - (* Some w: nonempty *) split.
    + discriminate.
    + intro Hempty. exfalso. apply (Hempty w). apply (find_wit_sound _ _ _ E).
  - (* None: empty *) split.
    + intros _. apply (find_wit_complete t Hflat Hok E).
    + intros _. reflexivity.
Qed.

(* the reduction lemma, GENERAL (all a b): subtyping = emptiness of a ∧ ¬b. *)
Theorem dsub_iff_empty : forall a b,
  (forall v, denote a v -> denote b v) <-> (forall v, ~ denote (BInter a (BNeg b)) v).
Proof.
  intros a b. split.
  - intros Hsub v [Ha Hnb]. apply Hnb. apply Hsub. exact Ha.
  - intros Hemp v Ha. destruct (classic_denote' b v) as [Hb|Hb]; [exact Hb|].
    exfalso. apply (Hemp v). split; [exact Ha | exact Hb].
Qed.

(* [gsub_empty] decides subtyping on the fragment (BOOL form). *)
Theorem gsub_empty_correct : forall a b,
  flat (BInter a (BNeg b)) -> dnf_ok (to_dnf (BInter a (BNeg b))) ->
  (gsub_empty a b = true <-> (forall v, denote a v -> denote b v)).
Proof.
  intros a b Hflat Hok. unfold gsub_empty.
  rewrite (decide_empty_correct _ Hflat Hok).
  symmetry. apply dsub_iff_empty.
Qed.

(* ===== NON-VACUITY: gdecide decides exactly dsub on record + atom cases ===== *)
(* The fragment hypotheses [flat] and [dnf_ok (to_dnf ...)] are DECIDABLE and
   hold for all these cases — discharged by computation. *)

(* width: {f:Int,g:Bool} <: {f:Int}. *)
Example gd_width : gsub_empty Rfg Rf = true.
Proof. reflexivity. Qed.
Example agree_width : forall v, denote Rfg v -> denote Rf v.
Proof.
  assert (Hflat : flat (BInter Rfg (BNeg Rf))) by (simpl; tauto).
  assert (Hok : dnf_ok (to_dnf (BInter Rfg (BNeg Rf)))).
  { unfold dnf_ok. apply Forall_forall. intros c Hc. vm_compute in Hc.
    destruct Hc as [Hc|[]]. subst c. right. vm_compute. lia. }
  apply (gsub_empty_correct Rfg Rf Hflat Hok). reflexivity.
Qed.

(* depth: {f:Int} </: {f:Str}. *)
Example gd_depth : gsub_empty Rf RfStr = false.
Proof. reflexivity. Qed.

(* record vs atom: a record is not an Int. *)
Example gd_rec_atom : gsub_empty Rf (BAtom AInt) = false.
Proof. reflexivity. Qed.

(* disjointness: {f:Int} ∩ Int <: Bot. *)
Example gd_disj : gsub_empty (BInter Rf (BAtom AInt)) BBot = true.
Proof. reflexivity. Qed.

(* atom cases agreeing with the old decide_dsub. *)
Example gd_int_num : gsub_empty (BAtom AInt) (BAtom ANum) = true.
Proof. reflexivity. Qed.
Example gd_num_int : gsub_empty (BAtom ANum) (BAtom AInt) = false.
Proof. reflexivity. Qed.

(* ===========================================================================
   INCREMENT 6, CORRECTED — THREE-VALUED, SOUND-BY-CONSTRUCTION DECISION.

   ADVERSARIAL-AUDIT FINDING (the defect this section fixes). The bool decider
   [gsub_empty] above is FAIL-OPTIMISTIC outside its proven fragment: the
   witness finder [find_wit_fuel] returns [None] both when it has PROVED there
   is no witness AND when it has DEFERRED (the ≥2-coupled-negated-record branch
   of [clause_wit], and nested-record fuel exhaustion). Since [None ⇒
   decide_empty = true ⇒ "subtype"], the bool conflates "proven subtype" with
   "decision deferred", and can claim [a <: b] for a GENUINE NON-subtype it
   cannot actually decide. Concrete witness: a = {h:Int}, b = {f:Int} ∪ {g:Int}.
   Then [a ∧ ¬b] has the coupled-negated-record conjunct, [clause_wit] returns
   [None] (deferred), [gsub_empty a b = true] — but [VTable[("h",VInt 0)]]
   inhabits [a ∧ ¬b], so [~ dsub a b]. A confident WRONG answer.

   THE FIX — distinguish the two meanings of [None] at the source. The witness
   finder becomes THREE-VALUED: [Found v] (a real witness, so a∧¬b nonempty),
   [NoWitness] (PROVED witness-free, so a∧¬b empty), or [Deferred] (could not
   decide). Propagation over a disjunction (DNF): [Found] anywhere ⇒ [Found];
   else any [Deferred] ⇒ [Deferred]; else [NoWitness]. Fuel exhaustion and the
   coupled-negated-record clause both return [Deferred] — NEVER [NoWitness] — so
   [NoWitness] genuinely means empty. The exported [gdecide] maps [Found ⇒
   DNotSub], [NoWitness ⇒ DSub], [Deferred ⇒ DUnknown]; the first two are
   UNCONDITIONALLY SOUND (no [flat]/[dnf_ok] hypothesis), the whole point being
   that no confident-wrong answer is ever produced.
   =========================================================================== *)

Inductive wit_result := Found (v:V) | NoWitness | Deferred.
Inductive decision   := DSub | DNotSub | DUnknown.

(* coercion to the bool-era option-V world (Found↦Some, else None). *)
Definition wr_to_opt (r:wit_result) : option V :=
  match r with Found v => Some v | _ => None end.

(* a three-valued [wf3] is "tame" on a type [T] when it does not defer there. *)
Definition wf3_tame (wf3:BTy->wit_result) (T:BTy) : Prop := wf3 T <> Deferred.

(* the option-V projection of a [wf3]. *)
Definition wf3_opt (wf3:BTy->wit_result) : BTy -> option V :=
  fun T => wr_to_opt (wf3 T).

(* ---- three-valued table builders -----------------------------------------
   A table clause queries [wf3] at each per-key field-intersection. If ANY query
   defers, the whole table builder defers (we cannot prove the field nonempty OR
   empty). Otherwise every query is Found/NoWitness, the [wf3_opt] projection is
   a faithful option-V finder, and we delegate to the bool-era [table_wit] /
   [table_wit_neg], lifting their [option V] back to [wit_result]. This makes the
   three-valued builders agree with the bool-era ones EXACTLY when no deferral
   occurs (the bridge lemmas), so their soundness/emptiness reduce to the
   already-proved [table_wit_models] / [table_wit_none] etc. *)

(* the field-intersection types a [table_wit allf] call queries. *)
Definition tw_queries (allf:list (string*BTy)) : list BTy :=
  map (fun kT => field_inter (fst kT) allf) allf.

(* the extra augmented queries a [table_wit_neg allf Nj] call may issue (one per
   Nj key, the value-branch augmented requirement lists' per-key intersections).
   For DEFERRAL DETECTION we conservatively also include every base query and,
   for each Nj key k, the queries of the augmented list. Over-approximating the
   query set only loses completeness, never soundness. *)
Definition twn_queries (allf Nj:list (string*BTy)) : list BTy :=
  tw_queries allf ++
  flat_map (fun kT => tw_queries (allf ++ [(fst kT, BNeg (field_inter (fst kT) Nj))])) Nj.

Definition any_defer (wf3:BTy->wit_result) (ts:list BTy) : bool :=
  existsb (fun T => match wf3 T with Deferred => true | _ => false end) ts.

Definition table_wit3 (allf:list (string*BTy)) (wf3:BTy->wit_result) : wit_result :=
  if any_defer wf3 (tw_queries allf) then Deferred
  else match table_wit allf (wf3_opt wf3) with
       | Some v => Found v
       | None => NoWitness
       end.

Definition table_wit_neg3 (allf Nj:list (string*BTy)) (wf3:BTy->wit_result) : wit_result :=
  if any_defer wf3 (twn_queries allf Nj) then Deferred
  else match table_wit_neg allf Nj (wf3_opt wf3) with
       | Some v => Found v
       | None => NoWitness
       end.

(* ---- three-valued clause / dnf / fuel finder ----------------------------- *)
Definition clause_wit3 (c:Clause) (wf3:BTy->wit_result) : wit_result :=
  if has_arrow c || has_ref c || has_tuple c then Deferred    (* arrow/ref/tuple literal: DEFERRED, never lie *)
  else
  match pos_recs c with
  | [] => match scalar_wit c with Some v => Found v | None => NoWitness end
  | prs => if has_pos_atom c then NoWitness   (* table ∧ positive scalar atom: empty *)
           else match neg_recs c with
                | [] => table_wit3 (List.concat prs) wf3
                | Nj :: nil => table_wit_neg3 (List.concat prs) Nj wf3
                | _ :: _ :: _ => Deferred       (* coupled negated records: DEFERRED *)
                end
  end.

(* DNF combine: Found wins; else Deferred is contagious; else NoWitness. *)
Fixpoint dnf_wit3 (d:Dnf) (wf3:BTy->wit_result) : wit_result :=
  match d with
  | [] => NoWitness
  | c :: r =>
      match clause_wit3 c wf3 with
      | Found v => Found v
      | NoWitness => dnf_wit3 r wf3
      | Deferred => match dnf_wit3 r wf3 with Found v => Found v | _ => Deferred end
      end
  end.

Fixpoint find_wit3 (n:nat) (t:BTy) : wit_result :=
  match n with
  | 0 => Deferred                 (* fuel exhausted: NEVER claim empty *)
  | S n' => dnf_wit3 (to_dnf t) (find_wit3 n')
  end.

Definition gdecide (a b:BTy) : decision :=
  match find_wit3 (S (S (rdepth (BInter a (BNeg b))))) (BInter a (BNeg b)) with
  | Found _ => DNotSub
  | NoWitness => DSub
  | Deferred => DUnknown
  end.

(* ===== bridge: when no deferral, three-valued = bool-era option-V ===== *)
Lemma clause_wit3_found_bridge : forall c wf3 v,
  clause_wit3 c wf3 = Found v -> clause_wit c (wf3_opt wf3) = Some v.
Proof.
  intros c wf3 v H. unfold clause_wit3, clause_wit in *.
  destruct (has_arrow c); [discriminate H|].
  destruct (has_ref c); [discriminate H|].
  destruct (has_tuple c); [discriminate H|]. cbn [orb] in H |- *.
  destruct (pos_recs c) as [|p ps].
  - destruct (scalar_wit c) as [w|]; [injection H as <-; reflexivity | discriminate].
  - destruct (has_pos_atom c); [discriminate|].
    destruct (neg_recs c) as [|Nj rest].
    + unfold table_wit3 in H.
      destruct (any_defer wf3 (tw_queries (List.concat (p::ps)))); [discriminate|].
      destruct (table_wit (List.concat (p::ps)) (wf3_opt wf3)) as [w|];
        [injection H as <-; reflexivity | discriminate].
    + destruct rest as [|Nj2 rest2].
      * unfold table_wit_neg3 in H.
        destruct (any_defer wf3 (twn_queries (List.concat (p::ps)) Nj)); [discriminate|].
        destruct (table_wit_neg (List.concat (p::ps)) Nj (wf3_opt wf3)) as [w|];
          [injection H as <-; reflexivity | discriminate].
      * discriminate.
Qed.

Lemma clause_wit3_sound : forall c wf3 v,
  (forall T w, wf3 T = Found w -> denote T w) ->
  clause_wit3 c wf3 = Found v -> denote_clause c v.
Proof.
  intros c wf3 v Hwfs H.
  apply (clause_wit_sound c (wf3_opt wf3) v).
  - intros T w HT. unfold wf3_opt, wr_to_opt in HT.
    destruct (wf3 T) as [w'| |] eqn:E; try discriminate HT.
    injection HT as <-. apply (Hwfs T w' E).
  - apply clause_wit3_found_bridge. exact H.
Qed.

Lemma dnf_wit3_sound : forall d wf3 v,
  (forall T w, wf3 T = Found w -> denote T w) ->
  dnf_wit3 d wf3 = Found v -> denote_dnf d v.
Proof.
  induction d as [|c r IH]; intros wf3 v Hwfs H; simpl in H.
  - discriminate.
  - destruct (clause_wit3 c wf3) as [w| |] eqn:Ec.
    + injection H as <-. left. apply (clause_wit3_sound c wf3 w Hwfs Ec).
    + right. apply (IH wf3 v Hwfs H).
    + destruct (dnf_wit3 r wf3) as [w| |] eqn:Er; try discriminate H.
      injection H as <-. right. apply (IH wf3 w Hwfs Er).
Qed.

(* ===== UNCONDITIONAL SOUNDNESS of Found witnesses ===== *)
Theorem find_wit3_sound : forall n t v, find_wit3 n t = Found v -> denote t v.
Proof.
  induction n as [|n IHn]; intros t v H; simpl in H.
  - discriminate.
  - apply to_dnf_pres.
    apply (dnf_wit3_sound (to_dnf t) (find_wit3 n) v).
    + intros T w. apply IHn.
    + exact H.
Qed.

(* ===== UNCONDITIONAL emptiness of NoWitness ===== *)
(* per-key NoWitness emptiness for table_wit3 (no [no_rec] hypothesis: the only
   witness-finder fact used is the IH "wf3 T = NoWitness ⇒ T empty", on ALL T). *)
Lemma table_wit3_nowit_empty : forall allf wf3,
  (forall T, wf3 T = NoWitness -> forall v, ~ denote T v) ->
  table_wit3 allf wf3 = NoWitness -> forall v, ~ table_models allf v.
Proof.
  intros allf wf3 Hwfn H v Hm. unfold table_wit3 in H.
  destruct (any_defer wf3 (tw_queries allf)) eqn:Hdef; [discriminate|].
  destruct (table_wit allf (wf3_opt wf3)) as [w|] eqn:Etw; [discriminate|].
  (* table_wit = None: some required key has wf3_opt = None, i.e. wf3 = NoWitness
     (not Deferred since any_defer=false), so that field type is empty. *)
  unfold table_wit in Etw.
  destruct (forallb (fun kT => match wf3_opt wf3 (field_inter (fst kT) allf) with Some _ => true | None => false end) allf) eqn:Hfb;
    [discriminate Etw|].
  destruct (forallb_false_in _ _ _ Hfb) as [[k T] [Hin Hk]]. simpl in Hk.
  unfold wf3_opt, wr_to_opt in Hk.
  destruct (wf3 (field_inter k allf)) as [w'| |] eqn:Ew; try discriminate Hk.
  - (* NoWitness: field type empty *)
    destruct Hm as [ents [Hv Hall]].
    destruct (Hall k (ex_intro _ T Hin)) as [w [Hlk Hw]].
    exact (Hwfn (field_inter k allf) Ew w Hw).
  - (* Deferred: contradicts any_defer=false (field_inter k allf ∈ tw_queries) *)
    exfalso. unfold any_defer in Hdef.
    assert (existsb (fun T0 => match wf3 T0 with Deferred => true | _ => false end) (tw_queries allf) = true).
    { apply existsb_exists. exists (field_inter k allf). split.
      - unfold tw_queries. apply in_map_iff. exists (k,T). split; [reflexivity|exact Hin].
      - rewrite Ew. reflexivity. }
    rewrite Hdef in H0; discriminate.
Qed.

(* table_wit_neg3 NoWitness emptiness, likewise unconditional. We mirror
   table_wit_neg_complete but replace its [no_rec]+blanket-wf hypotheses with the
   per-type IH "wf3 T = NoWitness ⇒ T empty". The augmented-list queries went
   through any_defer, so any None there is also a genuine NoWitness/empty. *)
Lemma table_wit_neg3_nowit_empty : forall allf Nj wf3,
  (forall T, wf3 T = NoWitness -> forall v, ~ denote T v) ->
  table_wit_neg3 allf Nj wf3 = NoWitness -> forall v, ~ tmv allf Nj v.
Proof.
  intros allf Nj wf3 Hwfn H v [Hm Hviol]. unfold table_wit_neg3 in H.
  destruct (any_defer wf3 (twn_queries allf Nj)) eqn:Hdef; [discriminate|].
  destruct (table_wit_neg allf Nj (wf3_opt wf3)) as [w|] eqn:Etwn; [discriminate|].
  (* wf3_opt is a sound+complete-ENOUGH option finder here: every query the
     bool-era table_wit_neg issues is in twn_queries, hence non-Deferred, hence
     wf3_opt=None ⇔ wf3=NoWitness ⇒ empty. Reduce to table_wit_neg_complete by
     constructing its required hypotheses on the queried types only. *)
  (* It is simplest to redo the case analysis directly. *)
  unfold table_wit_neg in Etwn.
  destruct (existsb (fun kT => negb (in_keys (fst kT) allf)) Nj) eqn:Habs.
  - (* absence branch: table_wit allf (wf3_opt) = None => no model of allf *)
    assert (Hnomodel : forall u, ~ table_models allf u).
    { apply (table_wit3_nowit_empty allf wf3 Hwfn).
      unfold table_wit3. unfold any_defer in *.
      assert (Hsub : forall x, In x (tw_queries allf) -> In x (twn_queries allf Nj)).
      { intros x Hx. unfold twn_queries. apply in_or_app. left. exact Hx. }
      destruct (existsb (fun T => match wf3 T with Deferred => true | _ => false end) (tw_queries allf)) eqn:Ein.
      - apply existsb_exists in Ein. destruct Ein as [x [Hx Hxd]].
        assert (existsb (fun T => match wf3 T with Deferred => true | _ => false end) (twn_queries allf Nj) = true).
        { apply existsb_exists. exists x. split; [apply Hsub; exact Hx | exact Hxd]. }
        rewrite Hdef in H0; discriminate.
      - rewrite Etwn. reflexivity. }
    exact (Hnomodel v Hm).
  - (* value branch: every Nj key present in allf; violation is a wrong value;
       so the augmented table_wit for that key would be Some, contradicting None. *)
    destruct Hm as [ents [Hv Hall]]. subst v.
    assert (Hpres : forall k T, In (k,T) Nj -> exists w, assoc_lookup k ents = Some w).
    { intros k T Hin.
      pose proof (existsb_false_forall _ _ _ Habs (k,T) Hin) as Hf. simpl in Hf.
      apply negb_false_iff in Hf. rewrite in_keys_true in Hf.
      destruct (Hall k Hf) as [w0 [Hlk _]]. exists w0; exact Hlk. }
    destruct (violation_wrong_key Nj ents Hpres Hviol) as [k [T [w0 [Hin [Hlk Hnd]]]]].
    assert (Hnfi : ~ denote (field_inter k Nj) w0).
    { intro Hc. apply Hnd. rewrite denote_field_inter in Hc. apply Hc; exact Hin. }
    (* the augmented requirement list for key k *)
    set (aug := allf ++ [(k, BNeg (field_inter k Nj))]).
    (* first_some over the value branch is None *)
    assert (Hfn : first_some (map (fun kT =>
        table_wit (allf ++ [(fst kT, BNeg (field_inter (fst kT) Nj))]) (wf3_opt wf3)) Nj) = None)
      by exact Etwn.
    pose proof (first_some_none _ Hfn
      (table_wit aug (wf3_opt wf3)) (in_map _ _ (k,T) Hin)) as Hnone.
    simpl in Hnone. fold aug in Hnone.
    (* k present in allf *)
    assert (HkA : exists T', In (k,T') allf).
    { pose proof (existsb_false_forall _ _ _ Habs (k,T) Hin) as Hf. simpl in Hf.
      apply negb_false_iff in Hf. rewrite in_keys_true in Hf. exact Hf. }
    assert (HwA : denote (field_inter k allf) w0).
    { destruct (Hall k HkA) as [w' [Hlk' Hw']]. rewrite Hlk in Hlk'. injection Hlk' as <-.
      exact Hw'. }
    (* VTable ents models aug, so table_wit aug = None forces an empty queried
       field type at one of aug's keys — but the model exhibits a value there,
       contradiction. We replay table_wit3_nowit_empty on aug. *)
    assert (Hnomodel_aug : forall u, ~ table_models aug u).
    { apply (table_wit3_nowit_empty aug wf3 Hwfn).
      unfold table_wit3.
      (* no deferral over aug's queries: they are a subset of twn_queries *)
      assert (Hsub : forall x, In x (tw_queries aug) -> In x (twn_queries allf Nj)).
      { intros x Hx. unfold twn_queries. apply in_or_app. right.
        apply in_flat_map. exists (k,T). split; [exact Hin|].
        unfold aug in Hx. simpl in Hx. exact Hx. }
      destruct (any_defer wf3 (tw_queries aug)) eqn:Eaug.
      - unfold any_defer in Eaug. apply existsb_exists in Eaug.
        destruct Eaug as [x [Hx Hxd]].
        assert (existsb (fun T0 => match wf3 T0 with Deferred => true | _ => false end) (twn_queries allf Nj) = true).
        { apply existsb_exists. exists x. split; [apply Hsub; exact Hx | exact Hxd]. }
        unfold any_defer in Hdef. rewrite Hdef in H0; discriminate.
      - rewrite Hnone. reflexivity. }
    apply (Hnomodel_aug (VTable ents)).
    (* VTable ents models aug *)
    exists ents. split; [reflexivity|].
    intros k0 [T0 Hin0]. unfold aug in Hin0. apply in_app_or in Hin0.
    destruct Hin0 as [Hin0|Hin0].
    + destruct (Hall k0 (ex_intro _ T0 Hin0)) as [w1 [Hlk1 Hw1]].
      exists w1. split; [exact Hlk1|]. unfold aug. rewrite field_inter_app; split; [exact Hw1|].
      simpl. destruct (string_dec k0 k) as [Ek|Hne]; simpl.
      * subst k0. rewrite Hlk in Hlk1. injection Hlk1 as <-.
        split; [exact Hnfi | exact I].
      * exact I.
    + simpl in Hin0. destruct Hin0 as [Heq|[]]. injection Heq as <- <-.
      exists w0. split; [exact Hlk|]. unfold aug. rewrite field_inter_app; split; [exact HwA|].
      simpl. destruct (string_dec k k) as [_|Hne]; [|congruence]. simpl.
      split; [exact Hnfi | exact I].
Qed.

(* clause-level NoWitness emptiness — UNCONDITIONAL (no good_clause / clause_ok /
   flat hypotheses). The fragment predicates are NOT needed because every branch
   that returns NoWitness is genuinely witness-free, and the coupled-negated-
   record branch returns Deferred (not NoWitness). *)
Lemma clause_wit3_nowit_empty : forall c wf3,
  (forall T, wf3 T = NoWitness -> forall v, ~ denote T v) ->
  clause_wit3 c wf3 = NoWitness -> forall v, ~ denote_clause c v.
Proof.
  intros c wf3 Hwfn H v Hd. unfold clause_wit3 in H.
  destruct (has_arrow c) eqn:Hna; [discriminate H|].
  destruct (has_ref c) eqn:Href; [discriminate H|].
  destruct (has_tuple c) eqn:Htu; [discriminate H|]. cbn [orb] in H.
  destruct (pos_recs c) as [|p ps] eqn:Hpr.
  - (* scalar *)
    destruct (scalar_wit c) as [w|] eqn:Es; [discriminate|].
    exact (scalar_wit_complete c (pos_recs_nil_no_pos_rec c Hpr Hna Href Htu) Es v Hd).
  - destruct (has_pos_atom c) eqn:Hpa.
    + (* positive record + positive scalar atom: v both table and scalar — empty *)
      assert (Hpex : In p (pos_recs c)) by (rewrite Hpr; left; reflexivity).
      pose proof (denote_clause_components c v Hd) as [Hprc _].
      destruct (posrec_is_table p v (Hprc p Hpex)) as [ents Hve]. subst v.
      clear H Hpr Hpex Hprc Hwfn Hna Href Htu. revert Hd Hpa. induction c as [|l r IH]; simpl; intros Hd Hpa.
      * discriminate Hpa.
      * destruct Hd as [Hl Hd]. destruct l; simpl in *.
        -- apply (table_neg_atom ents a); exact Hl.
        -- apply IH; assumption.
        -- apply IH; assumption.
        -- apply IH; assumption.
        -- exact Hl.   (* LPosArrow: denote (BArrow _ _)(VTable _) = False *)
        -- apply IH; assumption.   (* LNegArrow *)
        -- exact Hl.   (* LPosRef: denote (BRef _)(VTable _) = False *)
        -- apply IH; assumption.   (* LNegRef *)
        -- exact Hl.   (* LPosAnyRef: denote BAnyRef (VTable _) = False *)
        -- apply IH; assumption.   (* LNegAnyRef *)
        -- exact Hl.   (* LPosTuple: denote (BTuple _)(VTable _) = False *)
        -- apply IH; assumption.   (* LNegTuple *)
    + (* no positive atom: v is a table satisfying all positive records *)
      pose proof (denote_clause_components c v Hd) as [Hprc Hnrc].
      assert (Hpex : In p (pos_recs c)) by (rewrite Hpr; left; reflexivity).
      destruct (posrec_is_table p v (Hprc p Hpex)) as [ents ->].
      assert (Hmodels : table_models (List.concat (p::ps)) (VTable ents)).
      { apply allpos_table_models. intros f Hf. apply Hprc. rewrite Hpr. exact Hf. }
      destruct (neg_recs c) as [|Nj rest] eqn:Hnr.
      * (* no neg records *)
        exact (table_wit3_nowit_empty _ wf3 Hwfn H (VTable ents) Hmodels).
      * destruct rest as [|Nj2 rest2].
        -- (* one neg record *)
           apply (table_wit_neg3_nowit_empty (List.concat (p::ps)) Nj wf3 Hwfn H (VTable ents)).
           split; [exact Hmodels | exact (Hnrc Nj (or_introl eq_refl))].
        -- (* ≥2 neg records: clause_wit3 = Deferred, contradicting NoWitness *)
           discriminate H.
Qed.

(* dnf-level NoWitness emptiness: dnf_wit3 = NoWitness only if NO clause was
   Found and NONE was Deferred — every clause is NoWitness, hence empty. *)
Lemma dnf_wit3_nowit_empty : forall d wf3,
  (forall T, wf3 T = NoWitness -> forall v, ~ denote T v) ->
  dnf_wit3 d wf3 = NoWitness -> forall v, ~ denote_dnf d v.
Proof.
  induction d as [|c r IH]; intros wf3 Hwfn H v Hd; simpl in *.
  - exact Hd.
  - destruct (clause_wit3 c wf3) as [w| |] eqn:Ec.
    + discriminate H.
    + destruct Hd as [Hd|Hd].
      * exact (clause_wit3_nowit_empty c wf3 Hwfn Ec v Hd).
      * exact (IH wf3 Hwfn H v Hd).
    + destruct (dnf_wit3 r wf3); discriminate H.
Qed.

(* ===== UNCONDITIONAL: NoWitness from the master finder ⇒ type empty ===== *)
Theorem find_wit3_nowit_empty : forall n t,
  find_wit3 n t = NoWitness -> forall v, ~ denote t v.
Proof.
  induction n as [|n IHn]; intros t H v Hd; simpl in H.
  - discriminate.
  - apply (dnf_wit3_nowit_empty (to_dnf t) (find_wit3 n) IHn H v).
    apply to_dnf_pres. exact Hd.
Qed.

(* ===========================================================================
   THE TWO UNCONDITIONAL SOUNDNESS THEOREMS — no [flat]/[dnf_ok] hypothesis.
   A definite answer (DSub / DNotSub) is ALWAYS correct, for ALL a b : BTy.
   =========================================================================== *)

(* DSub ⇒ dsub. NoWitness genuinely establishes emptiness of a∧¬b. *)
Theorem gdecide_DSub_sound : forall a b, gdecide a b = DSub -> dsub a b.
Proof.
  intros a b H. unfold gdecide in H.
  destruct (find_wit3 (S (S (rdepth (BInter a (BNeg b))))) (BInter a (BNeg b))) eqn:E;
    try discriminate H.
  (* NoWitness: a∧¬b is empty *)
  unfold dsub. apply dsub_iff_empty.
  intros v. apply (find_wit3_nowit_empty _ _ E).
Qed.

(* DNotSub ⇒ ~dsub. The Found witness inhabits a∧¬b. *)
Theorem gdecide_DNotSub_sound : forall a b, gdecide a b = DNotSub -> ~ dsub a b.
Proof.
  intros a b H. unfold gdecide in H.
  destruct (find_wit3 (S (S (rdepth (BInter a (BNeg b))))) (BInter a (BNeg b))) as [w| |] eqn:E;
    try discriminate H.
  (* Found w: w ∈ a ∧ ¬b, so ¬ (a ⊆ b) *)
  pose proof (find_wit3_sound _ _ _ E) as Hw. simpl in Hw. destruct Hw as [Hwa Hwb].
  intro Hsub. apply Hwb. apply Hsub. exact Hwa.
Qed.

(* ===========================================================================
   COMPLETENESS, FRAGMENT-RESTRICTED: on the proved fragment the answer is
   DEFINITE (never DUnknown). The definite answer then matches dsub by the
   unconditional soundness theorems above.
   =========================================================================== *)

(* On the fragment, the three-valued finder is never Deferred. We reduce to the
   bool-era completeness: under [flat]/[dnf_ok] the bool finder returns [None]
   when empty and [Some] otherwise; the three-valued finder returns Found / NoWit
   correspondingly and — critically — cannot be Deferred. We prove this by a
   bridge: on the record-free recursion (flat fields), wf3 never defers, the
   coupled-negated-record clause never occurs (dnf_ok), and fuel suffices. *)

(* A record-free clause's three-valued witness is the scalar branch (Found or
   NoWitness), never Deferred — for ANY wf3. *)
Lemma clause_wit3_clrf_not_deferred : forall c wf3,
  cl_rf c -> clause_wit3 c wf3 <> Deferred.
Proof.
  intros c wf3 [Hp [_ [Hna [Href Htu]]]] H. unfold clause_wit3 in H.
  rewrite Hna, Href, Htu, Hp in H. cbn [orb] in H.
  destruct (scalar_wit c); discriminate H.
Qed.

(* dnf_wit3 over a record-free DNF is never Deferred (every clause is scalar). *)
Lemma dnf_wit3_clrf_not_deferred : forall d wf3,
  Forall cl_rf d -> dnf_wit3 d wf3 <> Deferred.
Proof.
  induction d as [|c r IH]; intros wf3 Hcl H; simpl in H.
  - discriminate.
  - pose proof (Forall_inv Hcl) as Hc. pose proof (Forall_inv_tail Hcl) as Hr.
    destruct (clause_wit3 c wf3) as [w| |] eqn:Ec.
    + discriminate H.
    + exact (IH wf3 Hr H).
    + exact (clause_wit3_clrf_not_deferred c wf3 Hc Ec).
Qed.

(* A record-free type's three-valued finder, at positive fuel, is never Deferred. *)
Lemma find_wit3_norec_not_deferred : forall n T,
  no_rec T -> find_wit3 (S n) T <> Deferred.
Proof.
  intros n T Hnr. simpl.
  apply (dnf_wit3_clrf_not_deferred (to_dnf T) (find_wit3 n)
           (proj1 (no_rec_no_rec_lits T Hnr))).
Qed.

(* clause_wit3 on a good + clause_ok clause is never Deferred when wf3 doesn't
   defer on the record-free field types it queries. *)
Lemma clause_wit3_not_deferred : forall c wf3,
  (forall T, no_rec T -> wf3 T <> Deferred) ->
  has_arrow c = false -> has_ref c = false -> has_tuple c = false ->
  good_clause c -> clause_ok c -> clause_wit3 c wf3 <> Deferred.
Proof.
  intros c wf3 Hwf Hna Href Htu [Hgp Hgn] Hok H. unfold clause_wit3 in H.
  rewrite Hna, Href, Htu in H. cbn [orb] in H.
  destruct (pos_recs c) as [|p ps] eqn:Hpr.
  - (* scalar *) destruct (scalar_wit c); discriminate H.
  - destruct (has_pos_atom c); [discriminate H|].
    (* fields of concat(p::ps) are no_rec (good_clause) *)
    assert (HnrAllf : forall k0 T, In (k0,T) (List.concat (p::ps)) -> no_rec T).
    { intros k0 T Hin. apply in_concat in Hin. destruct Hin as [f [Hf Hkt]].
      apply (Hgp f Hf k0 T Hkt). }
    destruct (neg_recs c) as [|Nj rest] eqn:Hnr.
    + (* no neg records: table_wit3 — every query is field_inter k (concat),
         which is no_rec, so wf3 doesn't defer => any_defer=false => not Deferred *)
      unfold table_wit3 in H.
      destruct (any_defer wf3 (tw_queries (List.concat (p::ps)))) eqn:Hdef.
      * unfold any_defer in Hdef. apply existsb_exists in Hdef.
        destruct Hdef as [x [Hx Hxd]]. unfold tw_queries in Hx.
        rewrite in_map_iff in Hx. destruct Hx as [[k T] [Hxeq Hin]]. subst x.
        assert (no_rec (field_inter k (List.concat (p::ps)))) by
          (apply field_inter_no_rec; exact HnrAllf).
        destruct (wf3 (field_inter (fst (k,T)) (List.concat (p::ps)))) eqn:E; try discriminate Hxd.
        simpl in E. exact (Hwf _ H0 E).
      * destruct (table_wit (List.concat (p::ps)) (wf3_opt wf3)); discriminate H.
    + destruct rest as [|Nj2 rest2].
      * (* one neg record: twn_queries are all field_inter k of no_rec lists =>
           no_rec => wf3 not Deferred => any_defer=false => not Deferred *)
        assert (HnrNj : forall k0 T, In (k0,T) Nj -> no_rec T).
        { intros k0 T Hin. apply (Hgn Nj (ltac:(left; reflexivity)) k0 T Hin). }
        unfold table_wit_neg3 in H.
        destruct (any_defer wf3 (twn_queries (List.concat (p::ps)) Nj)) eqn:Hdef.
        -- unfold any_defer in Hdef. apply existsb_exists in Hdef.
           destruct Hdef as [x [Hx Hxd]].
           unfold twn_queries in Hx. apply in_app_or in Hx. destruct Hx as [Hx|Hx].
           ++ unfold tw_queries in Hx. rewrite in_map_iff in Hx.
              destruct Hx as [[k T] [Hxeq Hin]]. subst x.
              assert (Hnr0 : no_rec (field_inter (fst (k,T)) (List.concat (p::ps)))) by
                (apply field_inter_no_rec; exact HnrAllf).
              destruct (wf3 (field_inter (fst (k,T)) (List.concat (p::ps)))) eqn:E;
                simpl in Hxd; try discriminate Hxd.
              exact (Hwf _ Hnr0 E).
           ++ apply in_flat_map in Hx. destruct Hx as [[kj Tj] [Hinj Hx]].
              unfold tw_queries in Hx. rewrite in_map_iff in Hx.
              destruct Hx as [[k T] [Hxeq Hin]]. subst x.
              (* field_inter of (allf ++ [(kj, BNeg (field_inter kj Nj))]) is no_rec:
                 allf fields are no_rec; the appended field is BNeg of field_inter of
                 Nj's (no_rec) fields, which is no_rec. *)
              assert (Haug : forall k0 T0, In (k0,T0) (List.concat (p::ps) ++ [(fst (kj,Tj), BNeg (field_inter (fst (kj,Tj)) Nj))]) -> no_rec T0).
              { intros k0 T0 Hin0. apply in_app_or in Hin0. destruct Hin0 as [Hin0|Hin0].
                - exact (HnrAllf k0 T0 Hin0).
                - simpl in Hin0. destruct Hin0 as [Heq|[]]. injection Heq as <- <-.
                  simpl. apply field_inter_no_rec. exact HnrNj. }
              assert (Hnr0 : no_rec (field_inter (fst (k,T)) (List.concat (p::ps) ++ [(fst (kj,Tj), BNeg (field_inter (fst (kj,Tj)) Nj))]))) by
                (apply field_inter_no_rec; exact Haug).
              destruct (wf3 (field_inter (fst (k,T)) (List.concat (p::ps) ++ [(fst (kj,Tj), BNeg (field_inter (fst (kj,Tj)) Nj))]))) eqn:E;
                simpl in Hxd; try discriminate Hxd.
              exact (Hwf _ Hnr0 E).
        -- destruct (table_wit_neg (List.concat (p::ps)) Nj (wf3_opt wf3)); discriminate H.
      * (* ≥2 neg records: excluded by clause_ok *)
        exfalso. destruct Hok as [Hpr0|Hlen].
        -- rewrite Hpr in Hpr0; discriminate.
        -- rewrite Hnr in Hlen; simpl in Hlen; lia.
Qed.

Lemma dnf_wit3_not_deferred : forall d wf3,
  (forall T, no_rec T -> wf3 T <> Deferred) ->
  dnf_no_arrow d -> dnf_no_ref d -> dnf_no_tuple d ->
  Forall good_clause d -> dnf_ok d -> dnf_wit3 d wf3 <> Deferred.
Proof.
  induction d as [|c r IH]; intros wf3 Hwf Hna Href Htu Hgd Hok H; simpl in H.
  - discriminate.
  - pose proof (Forall_inv Hgd) as Hgc. pose proof (Forall_inv_tail Hgd) as Hgr.
    pose proof (Forall_inv Hok) as Hokc. pose proof (Forall_inv_tail Hok) as Hokr.
    pose proof (Forall_inv Hna) as Hnac. pose proof (Forall_inv_tail Hna) as Hnar.
    pose proof (Forall_inv Href) as Hrefc. pose proof (Forall_inv_tail Href) as Hrefr.
    pose proof (Forall_inv Htu) as Htuc. pose proof (Forall_inv_tail Htu) as Htur.
    destruct (clause_wit3 c wf3) as [w| |] eqn:Ec.
    + discriminate H.
    + exact (IH wf3 Hwf Hnar Hrefr Htur Hgr Hokr H).
    + exact (clause_wit3_not_deferred c wf3 Hwf Hnac Hrefc Htuc Hgc Hokc Ec).
Qed.

(* MASTER fragment completeness: on [flat]/[dnf_ok], the finder is never Deferred
   at the standard fuel. *)
Lemma find_wit3_not_deferred : forall t,
  flat t -> dnf_ok (to_dnf t) ->
  find_wit3 (S (S (rdepth t))) t <> Deferred.
Proof.
  intros t Hflat Hok. simpl.
  apply (dnf_wit3_not_deferred (to_dnf t) (find_wit3 (S (rdepth t)))
           (fun T HT => find_wit3_norec_not_deferred (rdepth t) T HT)
           (proj1 (flat_no_arrow t Hflat))
           (proj1 (flat_no_ref t Hflat))
           (proj1 (flat_no_tuple t Hflat))
           (proj1 (flat_good_clauses t Hflat)) Hok).
Qed.

(* gdecide is DEFINITE (≠ DUnknown) on the fragment. *)
Theorem gdecide_complete : forall a b,
  flat (BInter a (BNeg b)) -> dnf_ok (to_dnf (BInter a (BNeg b))) ->
  gdecide a b <> DUnknown.
Proof.
  intros a b Hflat Hok H. unfold gdecide in H.
  destruct (find_wit3 (S (S (rdepth (BInter a (BNeg b))))) (BInter a (BNeg b))) eqn:E;
    try discriminate H.
  exact (find_wit3_not_deferred _ Hflat Hok E).
Qed.

(* and on the fragment the definite answer matches dsub. *)
Theorem gdecide_fragment_correct : forall a b,
  flat (BInter a (BNeg b)) -> dnf_ok (to_dnf (BInter a (BNeg b))) ->
  (gdecide a b = DSub <-> dsub a b) /\ (gdecide a b = DNotSub <-> ~ dsub a b).
Proof.
  intros a b Hflat Hok.
  pose proof (gdecide_complete a b Hflat Hok) as Hdef.
  split; split.
  - apply gdecide_DSub_sound.
  - intro Hsub. destruct (gdecide a b) eqn:E; [reflexivity| |contradiction].
    exfalso. apply (gdecide_DNotSub_sound a b E). exact Hsub.
  - apply gdecide_DNotSub_sound.
  - intro Hns. destruct (gdecide a b) eqn:E; [|reflexivity|contradiction].
    exfalso. apply Hns. apply (gdecide_DSub_sound a b E).
Qed.

(* ===========================================================================
   THE AUDIT-FOUND TRAP IS GONE.

   a = {h:Int}, b = {f:Int} ∪ {g:Int}. The bool decider answered "subtype"
   (DSub-equivalent: gsub_empty a b = true) because [a ∧ ¬b] reduces to a clause
   with TWO coupled negated records and [clause_wit] deferred to [None] ⇒ true.
   But [VTable[("h",VInt 0)]] inhabits [a ∧ ¬b], so [~ dsub a b]. The new
   three-valued [gdecide] returns DUnknown there (NEVER DSub) — no confident
   wrong answer.
   =========================================================================== *)

Definition Ah := BRec [("h"%string, BAtom AInt)].
Definition Bfg := BUnion (BRec [("f"%string, BAtom AInt)])
                          (BRec [("g"%string, BAtom AInt)]).

(* The OLD bool decider was WRONG here: it claimed "empty" (= subtype). *)
Example trap_old_bool_wrong : gsub_empty Ah Bfg = true.
Proof. reflexivity. Qed.

(* But the relation is GENUINELY not a subtype, witnessed by {h=0}. *)
Theorem trap_not_dsub : ~ dsub Ah Bfg.
Proof.
  unfold dsub. intro H.
  specialize (H (VTable [("h"%string, VInt 0)])).
  assert (Hpre : denote Ah (VTable [("h"%string, VInt 0)])).
  { apply denote_rec_iff. exists [("h"%string, VInt 0)]. split; [reflexivity|].
    intros k T Hin. simpl in Hin. destruct Hin as [Heq|[]].
    injection Heq as <- <-. exists (VInt 0). simpl. split; [reflexivity| exact I]. }
  specialize (H Hpre). simpl in H. destruct H as [Hf|Hg].
  - destruct Hf as [ents [Hv [[vv [Hlk _]] _]]]. injection Hv as <-.
    simpl in Hlk. discriminate Hlk.
  - destruct Hg as [ents [Hv [[vv [Hlk _]] _]]]. injection Hv as <-.
    simpl in Hlk. discriminate Hlk.
Qed.

(* The new three-valued decider DEFERS instead of lying: DUnknown, not DSub. *)
Example trap_gdecide_unknown : gdecide Ah Bfg = DUnknown.
Proof. reflexivity. Qed.

(* The load-bearing guarantee: it is IMPOSSIBLE for gdecide to claim DSub here. *)
Theorem trap_not_dsub_claim : gdecide Ah Bfg <> DSub.
Proof. discriminate. Qed.

(* ===========================================================================
   IN-FRAGMENT CASES — the decider still gives correct DEFINITE answers.
   =========================================================================== *)

(* width: {f:Int,g:Bool} <: {f:Int}  =>  DSub. *)
Example gd3_width : gdecide Rfg Rf = DSub.
Proof. reflexivity. Qed.
(* depth fail: {f:Int} </: {f:Str}  =>  DNotSub. *)
Example gd3_depth : gdecide Rf RfStr = DNotSub.
Proof. reflexivity. Qed.
(* record vs atom: {f:Int} </: Int  =>  DNotSub. *)
Example gd3_rec_atom : gdecide Rf (BAtom AInt) = DNotSub.
Proof. reflexivity. Qed.
(* disjointness: {f:Int} ∩ Int <: Bot  =>  DSub. *)
Example gd3_disj : gdecide (BInter Rf (BAtom AInt)) BBot = DSub.
Proof. reflexivity. Qed.
(* atom cases, agreeing with the old decide_dsub. *)
Example gd3_int_num : gdecide (BAtom AInt) (BAtom ANum) = DSub.
Proof. reflexivity. Qed.
Example gd3_num_int : gdecide (BAtom ANum) (BAtom AInt) = DNotSub.
Proof. reflexivity. Qed.
Example gd3_str_int : gdecide (BAtom AStr) (BAtom AInt) = DNotSub.
Proof. reflexivity. Qed.
Example gd3_int_str_bot : gdecide (BInter (BAtom AInt) (BAtom AStr)) BBot = DSub.
Proof. reflexivity. Qed.

(* width DSub routed to a real dsub fact via the unconditional soundness theorem. *)
Example gd3_agree_width : dsub Rfg Rf.
Proof. apply gdecide_DSub_sound. reflexivity. Qed.
(* depth DNotSub routed to a real ~dsub fact. *)
Example gd3_agree_depth : ~ dsub Rf RfStr.
Proof. apply gdecide_DNotSub_sound. reflexivity. Qed.

(* ===========================================================================
   INCREMENT 7 — SINGLE-ARG / SINGLE-RETURN FUNCTION TYPES (ARROWS).

   A function VALUE is its finite input/output graph [VFun g] (g : list (V*V));
   the arrow type [BArrow A B] denotes the functions every pair of whose graph
   maps A-inputs to B-outputs (the standard semantic-subtyping reading):

       denote (BArrow A B) (VFun g)  :=  forall i o, In (i,o) g -> denote A i -> denote B o
       denote (BArrow A B) (non-fun) :=  False.

   The CORE arrow laws — contravariant domain / covariant codomain, and
   disjointness from scalars and records — are theorems-FOR-FREE from this
   denotation (set inclusion), exactly as the record laws were. The decision
   procedure does NOT yet decide arrow subtyping: every clause containing an arrow
   literal is DEFERRED ([has_arrow] guard in [clause_wit]/[clause_wit3]), so
   [gdecide] returns [DUnknown] — never a wrong [DSub]/[DNotSub] — and the
   unconditional soundness theorems [gdecide_DSub_sound]/[gdecide_DNotSub_sound]
   remain TRUE over the extended [BTy] (verified by [Print Assumptions] + the
   arrow-defer sanity examples below).
   =========================================================================== *)

(* ---- CONTRAVARIANCE (domain) + COVARIANCE (codomain) ----------------------
   [dsub A' A] (domain widens) and [dsub B B'] (codomain widens) give
   [dsub (BArrow A B) (BArrow A' B')]. Follows by unfolding [denote] and pushing
   the inclusions through the graph quantifier. *)
Theorem darrow_variance : forall A A' B B',
  dsub A' A -> dsub B B' -> dsub (BArrow A B) (BArrow A' B').
Proof.
  intros A A' B B' HA HB. unfold dsub. intros v Hf.
  apply denote_arrow_iff in Hf. apply denote_arrow_iff.
  destruct Hf as [g [Hv Hall]]. exists g. split; [exact Hv | ].
  intros i o Hin Hi'.
  (* i in A' => (HA) i in A => (Hall) o in B => (HB) o in B' *)
  apply HB. apply (Hall i o Hin). apply HA. exact Hi'.
Qed.

(* the two one-sided corollaries, for readability. *)
Corollary darrow_covariant_cod : forall A B B',
  dsub B B' -> dsub (BArrow A B) (BArrow A B').
Proof. intros A B B' HB. apply darrow_variance; [apply dsub_refl | exact HB]. Qed.

Corollary darrow_contravariant_dom : forall A A' B,
  dsub A' A -> dsub (BArrow A B) (BArrow A' B).
Proof. intros A A' B HA. apply darrow_variance; [exact HA | apply dsub_refl]. Qed.

(* ---- DISJOINTNESS: arrows are a distinct value-kind --------------------------
   No [VFun] inhabits any scalar atom (atoms send [VFun _] to [False]) and no
   [VFun] inhabits any record (records require a [VTable]). Conversely no scalar
   / table inhabits an arrow type. So an arrow intersected with an atom or a
   record is empty. *)
Theorem arrow_disjoint_atom : forall A B a,
  dsub (BInter (BArrow A B) (BAtom a)) BBot.
Proof.
  intros A B a. unfold dsub. intros v [Harr Hat].
  apply denote_arrow_iff in Harr. destruct Harr as [g [Hv _]]. subst v.
  destruct a; simpl in Hat; exact Hat.
Qed.

Theorem arrow_disjoint_rec : forall A B fields,
  dsub (BInter (BArrow A B) (BRec fields)) BBot.
Proof.
  intros A B fields. unfold dsub. intros v [Harr Hrec].
  apply denote_arrow_iff in Harr. destruct Harr as [g [Hv _]]. subst v.
  apply denote_rec_iff in Hrec. destruct Hrec as [ents [Hbad _]]. discriminate Hbad.
Qed.

(* the brief's exact instances. *)
Theorem arrow_disjoint_int :
  dsub (BInter (BArrow (BAtom AInt) (BAtom AInt)) (BAtom AInt)) BBot.
Proof. apply arrow_disjoint_atom. Qed.

Theorem arrow_disjoint_rec_inst : forall fields,
  dsub (BInter (BArrow (BAtom AInt) (BAtom AInt)) (BRec fields)) BBot.
Proof. intro fields. apply arrow_disjoint_rec. Qed.

(* ---- NON-VACUITY / FAITHFULNESS -------------------------------------------
   The arrow semantics is not trivially true: arrow types are inhabited, and
   genuine NON-subtypes have explicit witnesses (so [dsub] over arrows is faithful,
   not a vacuous always-true relation). *)

(* an arrow type is INHABITED: the empty-graph function vacuously satisfies every
   arrow type, and a singleton graph respecting the constraint works too. *)
Theorem arrow_inhabited : exists v, denote (BArrow (BAtom AInt) (BAtom AInt)) v.
Proof.
  exists (VFun [(VInt 0, VInt 0)]). apply denote_arrow_iff.
  exists [(VInt 0, VInt 0)]. split; [reflexivity|].
  intros i o Hin Hi. simpl in Hin. destruct Hin as [Heq|[]].
  injection Heq as <- <-. exact I.
Qed.

(* the EMPTY function inhabits every arrow type (vacuous graph). *)
Theorem empty_fun_in_every_arrow : forall A B, denote (BArrow A B) (VFun []).
Proof.
  intros A B. apply denote_arrow_iff. exists []. split; [reflexivity| intros i o []].
Qed.

(* CODOMAIN non-subtype: Int->Int </: Int->Str. Witness [VFun [(VInt 0, VInt 0)]]:
   it is in Int->Int (0 maps int 0 to int 0) but NOT in Int->Str (the output 0 is
   an int, not a string, and the input 0 IS an int so the constraint bites). *)
Theorem not_arrow_int_int_sub_int_str :
  ~ dsub (BArrow (BAtom AInt) (BAtom AInt)) (BArrow (BAtom AInt) (BAtom AStr)).
Proof.
  unfold dsub. intro H.
  specialize (H (VFun [(VInt 0, VInt 0)])).
  assert (Hpre : denote (BArrow (BAtom AInt) (BAtom AInt)) (VFun [(VInt 0, VInt 0)])).
  { apply denote_arrow_iff. exists [(VInt 0, VInt 0)]. split; [reflexivity|].
    intros i o Hin Hi. simpl in Hin. destruct Hin as [Heq|[]].
    injection Heq as <- <-. exact I. }
  specialize (H Hpre). apply denote_arrow_iff in H.
  destruct H as [g [Hv Hall]]. injection Hv as <-.
  (* the pair (VInt 0, VInt 0) is in g; input VInt 0 ∈ Int, so output VInt 0 ∈ Str — false *)
  pose proof (Hall (VInt 0) (VInt 0) (or_introl eq_refl) I) as Ho. simpl in Ho. exact Ho.
Qed.

(* DOMAIN contravariance non-subtype: Int->Int </: Num->Int. Witness
   [VFun [(VFloat 0, VStr 0)]]: it is VACUOUSLY in Int->Int (VFloat 0 ∉ Int, so the
   constraint is vacuous), but NOT in Num->Int (VFloat 0 ∈ Num, forcing the output
   VStr 0 ∈ Int — false). This is exactly the contravariance witness. *)
Theorem not_arrow_int_int_sub_num_int :
  ~ dsub (BArrow (BAtom AInt) (BAtom AInt)) (BArrow (BAtom ANum) (BAtom AInt)).
Proof.
  unfold dsub. intro H.
  specialize (H (VFun [(VFloat 0, VStr 0)])).
  assert (Hpre : denote (BArrow (BAtom AInt) (BAtom AInt)) (VFun [(VFloat 0, VStr 0)])).
  { apply denote_arrow_iff. exists [(VFloat 0, VStr 0)]. split; [reflexivity|].
    intros i o Hin Hi. simpl in Hin. destruct Hin as [Heq|[]].
    injection Heq as <- <-. simpl in Hi. contradiction.   (* VFloat 0 ∉ Int *) }
  specialize (H Hpre). apply denote_arrow_iff in H.
  destruct H as [g [Hv Hall]]. injection Hv as <-.
  (* input VFloat 0 ∈ Num, so output VStr 0 must be ∈ Int — false *)
  pose proof (Hall (VFloat 0) (VStr 0) (or_introl eq_refl) I) as Ho. simpl in Ho. exact Ho.
Qed.

(* ---- DECISION PROCEDURE STAYS SOUND WITH ARROWS (sanity) -------------------
   Any arrow-involving query reduces to a clause with an arrow literal, which the
   finder defers — so [gdecide] returns [DUnknown], never a confident wrong
   answer. The unconditional soundness theorems still apply (no fragment
   hypothesis), so a definite answer, when given, remains correct. *)

(* an arrow subtyping query DEFERS (DUnknown), never lies. *)
Example gd_arrow_defers :
  gdecide (BArrow (BAtom AInt) (BAtom AInt)) (BArrow (BAtom AInt) (BAtom AStr)) = DUnknown.
Proof. reflexivity. Qed.

(* the load-bearing guarantee: the decider CANNOT claim DSub on this genuine
   non-subtype (it would be unsound — instead it defers). *)
Theorem gd_arrow_not_dsub_claim :
  gdecide (BArrow (BAtom AInt) (BAtom AInt)) (BArrow (BAtom AInt) (BAtom AStr)) <> DSub.
Proof. discriminate. Qed.

(* and on the contravariance non-subtype, likewise DUnknown (never DNotSub-wrong
   or DSub-wrong — it simply defers). *)
Example gd_arrow_contra_defers :
  gdecide (BArrow (BAtom AInt) (BAtom AInt)) (BArrow (BAtom ANum) (BAtom AInt)) = DUnknown.
Proof. reflexivity. Qed.

(* a mixed query — arrow intersected with an atom on the left — also defers (the
   arrow literal forces deferral) rather than risk an unsound definite answer. *)
Example gd_arrow_atom_defers :
  gdecide (BInter (BArrow (BAtom AInt) (BAtom AInt)) (BAtom AInt)) BBot = DUnknown.
Proof. reflexivity. Qed.

(* ---- ARROW DECOMPOSITION LAW (set-theoretic) ------------------------------
   The simplest semantic-subtyping arrow identity: intersection of codomains.

       (A → B) ∩ (A → C)  ≡  A → (B ∩ C).

   This is a genuine model fact, NOT decided by the (arrow-deferring) procedure —
   it is proved directly from [denote] (set inclusion), like the variance laws.
   The finite-graph model VALIDATES it: a function is in both [A→B] and [A→C] iff
   every A-input's output lands in B AND in C, i.e. in B∩C. No faithfulness gap.

   (The harder decomposition facts — [(A→C) ∩ (A'→C) <: (A∪A')→C], and the
   arrow-emptiness laws — are DEFERRED to a future increment; see the note in
   docs/proof-kernel.md. They require either an arrow-aware decision procedure or
   further model lemmas; the codomain-intersection law below is the one the brief
   asks to attempt first, and it closes cleanly.) *)
Theorem darrow_inter_cod : forall A B C,
  dequiv (BInter (BArrow A B) (BArrow A C)) (BArrow A (BInter B C)).
Proof.
  intros A B C. split; unfold dsub.
  - (* (A→B) ∩ (A→C)  <:  A → (B∩C) *)
    intros v [HB HC].
    apply denote_arrow_iff in HB. apply denote_arrow_iff in HC.
    apply denote_arrow_iff.
    destruct HB as [g [Hv HallB]]. destruct HC as [g' [Hv' HallC]].
    subst v. injection Hv' as <-.
    exists g. split; [reflexivity|].
    intros i o Hin Hi. simpl. split; [apply (HallB i o Hin Hi) | apply (HallC i o Hin Hi)].
  - (* A → (B∩C)  <:  (A→B) ∩ (A→C) *)
    intros v HBC. apply denote_arrow_iff in HBC.
    destruct HBC as [g [Hv Hall]]. subst v.
    split; apply denote_arrow_iff; exists g; (split; [reflexivity|]);
      intros i o Hin Hi; destruct (Hall i o Hin Hi) as [Ho1 Ho2]; assumption.
Qed.

(* ===========================================================================
   SPLIT-STEP 1 of the REFERENCE UNIFICATION — BRef + BAnyRef opaque leaves.

   References are added to the Boolean algebra so they can later be unified into
   the typing layer. The DIAGNOSIS insight: references need BOTH a specific
   [BRef T] AND an "any-reference" [BAnyRef] (so a truthy location can be narrowed
   to "is a reference" without committing to a content type).

   References are INVARIANT and lack a clean store-free denotation — a location's
   content type is NOT observable from the value (we model a location as a bare
   [nat] address [VRef n], carrying no store). So BOTH [BRef T] and [BAnyRef]
   denote exactly the set of all locations [{VRef _}], CONTENT-BLIND:

       denote (BRef _) v  =  (exists n, v = VRef n)
       denote BAnyRef  v  =  (exists n, v = VRef n)

   Denotationally therefore [BRef T ≡ BAnyRef ≡ BRef U] for all T,U. The syntactic
   distinction (invariance, any-ref widening) is DEFERRED to [ssub] in the next
   increment — fine, because [ssub ⊊ dsub] in the SAFE direction.

   For the DECISION procedure, references are OPAQUE LEAVES exactly like [BArrow]:
   the literals [LPosRef]/[LNegRef]/[LPosAnyRef]/[LNegAnyRef] are emitted by
   [to_dnf]/[to_dnf_neg], and the witness-finder DEFERS on any clause carrying a
   ref literal (the [has_ref] guard, alongside [has_arrow]) — so [gdecide] returns
   [DUnknown], never a wrong answer about refs. [BRef]/[BAnyRef] are excluded from
   [atomic]/[flat]/[no_rec]/[neg_atomic] (sent to [False]) just as [BArrow] is.
   The two UNCONDITIONAL soundness theorems
   [gdecide_DSub_sound]/[gdecide_DNotSub_sound] therefore stay TRUE over the
   extended [BTy] (refs ⇒ DUnknown ⇒ no claim) — confirmed by [Print Assumptions].
   =========================================================================== *)

(* ---- The membership characterization: BRef/BAnyRef denote exactly all locations.
   These are the [denote_arrow_iff]-analog facts for references. *)
Lemma denote_ref_iff : forall T v, denote (BRef T) v <-> exists n, v = VRef n.
Proof.
  intros T v. simpl. destruct v as [ | | | | | | n | vs ]; split;
    try (intros [n0 Hbad]; discriminate Hbad);
    try contradiction; try (intros _; exact I); intros _; exists n; reflexivity.
Qed.

Lemma denote_anyref_iff : forall v, denote BAnyRef v <-> exists n, v = VRef n.
Proof.
  intros v. simpl. destruct v as [ | | | | | | n | vs ]; split;
    try (intros [n0 Hbad]; discriminate Hbad);
    try contradiction; try (intros _; exact I); intros _; exists n; reflexivity.
Qed.

(* ---- NON-VACUITY / SANITY for references ----------------------------------- *)

(* a concrete location inhabits [BRef BInt] — content-blind: [VRef 0] is in
   [BRef BInt] regardless of what BInt is. *)
Theorem ref_int_inhabited : denote (BRef (BAtom AInt)) (VRef 0).
Proof. simpl. exact I. Qed.

(* a location inhabits [BAnyRef]. *)
Theorem anyref_inhabited : denote BAnyRef (VRef 0).
Proof. simpl. exact I. Qed.

(* a NON-reference value is in NEITHER [BRef _] NOR [BAnyRef]. *)
Theorem nonref_not_ref : forall T, ~ denote (BRef T) (VInt 0).
Proof. intros T H. simpl in H. exact H. Qed.

Theorem nonref_not_anyref : ~ denote BAnyRef (VInt 0).
Proof. intro H. simpl in H. exact H. Qed.

(* CONTENT-BLINDNESS, made precise: [BAnyRef] and [BRef T] denote the SAME set
   (all locations) for every content type T — the price of invariance. The
   syntactic invariance/any-ref distinction is deferred to [ssub]. *)
Theorem anyref_equiv_ref : forall T, dequiv BAnyRef (BRef T).
Proof.
  intro T. split; unfold dsub; intros v H.
  - apply denote_ref_iff. apply denote_anyref_iff. exact H.
  - apply denote_anyref_iff. apply denote_ref_iff in H. exact H.
Qed.

(* and any two specific ref types are denotationally equivalent (content-blind). *)
Theorem ref_equiv_ref : forall T U, dequiv (BRef T) (BRef U).
Proof.
  intros T U. split; unfold dsub; intros v H;
    apply denote_ref_iff; apply denote_ref_iff in H; exact H.
Qed.

(* a reference is DISJOINT from every scalar atom (locations are a distinct kind:
   [VRef] is not any scalar constructor — decided by [discriminate]). *)
Theorem ref_disjoint_atom : forall T a,
  dsub (BInter (BRef T) (BAtom a)) BBot.
Proof.
  intros T a. unfold dsub. intros v [Hr Ha].
  apply denote_ref_iff in Hr. destruct Hr as [n Hv]. subst v.
  destruct a; simpl in Ha; exact Ha.
Qed.

(* a reference is DISJOINT from every record (a location is not a [VTable]). *)
Theorem ref_disjoint_rec : forall T fields,
  dsub (BInter (BRef T) (BRec fields)) BBot.
Proof.
  intros T fields. unfold dsub. intros v [Hr Hrec].
  apply denote_ref_iff in Hr. destruct Hr as [n Hv]. subst v.
  apply denote_rec_iff in Hrec. destruct Hrec as [ents [Hbad _]]. discriminate Hbad.
Qed.

(* a reference is DISJOINT from every arrow (a location is not a [VFun]). *)
Theorem ref_disjoint_arrow : forall T A B,
  dsub (BInter (BRef T) (BArrow A B)) BBot.
Proof.
  intros T A B. unfold dsub. intros v [Hr Harr].
  apply denote_ref_iff in Hr. destruct Hr as [n Hv]. subst v.
  apply denote_arrow_iff in Harr. destruct Harr as [g [Hbad _]]. discriminate Hbad.
Qed.

(* ---- DECISION PROCEDURE STAYS SOUND WITH REFERENCES (sanity) ----------------
   Any ref-involving query reduces to a clause carrying a ref literal, which the
   finder DEFERS — so [gdecide] returns [DUnknown], never a confident wrong
   answer. The unconditional soundness theorems still apply (no fragment
   hypothesis), so a definite answer, when given, remains correct. *)

(* a ref subtyping query DEFERS (DUnknown), never lies. *)
Example gd_ref_defers :
  gdecide (BRef (BAtom AInt)) (BRef (BAtom AStr)) = DUnknown.
Proof. reflexivity. Qed.

(* the any-ref query likewise defers (ref subtyping is decided by [ssub] later). *)
Example gd_anyref_defers : gdecide BAnyRef (BRef (BAtom AInt)) = DUnknown.
Proof. reflexivity. Qed.

(* the load-bearing guarantee: the decider CANNOT claim DSub on a genuine ref
   non-subtyping query (it would be unsound — instead it defers). *)
Theorem gd_ref_not_dsub_claim :
  gdecide (BRef (BAtom AInt)) (BRef (BAtom AStr)) <> DSub.
Proof. discriminate. Qed.

(* a mixed query — a ref intersected with an atom on the left — also defers. *)
Example gd_ref_atom_defers :
  gdecide (BInter (BRef (BAtom AInt)) (BAtom AInt)) BBot = DUnknown.
Proof. reflexivity. Qed.

(* ===========================================================================
   MULTI-RETURN — TUPLE / VALUE-SEQUENCE SEMANTIC FACTS.

   The denotation-level theory of [BTuple] (positional, exact-length), mirroring
   the arrow/ref sections: the [In]-free positional characterization, POINTWISE
   (positional) subtyping, disjointness from every other value-kind, the
   length-mismatch non-subtyping (genuine, non-vacuous), inhabitation, and the
   decider-defers sanity. These are the substrate the typing layer's multi-return
   rules (truncation / last-position spread) rest on.
   =========================================================================== *)

(* The positional characterization: a value is in [BTuple Ts] iff it is a
   value-sequence [VTup vs] of the SAME LENGTH whose i-th component (by [nth_error])
   inhabits the i-th type. (The structural lockstep fold and this [nth_error] form
   are provably equivalent — induction on [Ts]/[vs].) *)
Lemma tuple_fold_iff : forall (Ts:list BTy) (vs:list V),
  (fix all_pos (ts : list BTy) (vv : list V) : Prop :=
     match ts, vv with
     | [], [] => True
     | T :: tr, v0 :: vr => denote T v0 /\ all_pos tr vr
     | _, _ => False
     end) Ts vs
  <-> (List.length Ts = List.length vs /\
       forall i T, nth_error Ts i = Some T ->
         exists v0, nth_error vs i = Some v0 /\ denote T v0).
Proof.
  induction Ts as [|T tr IH]; intros vs; simpl.
  - destruct vs as [|v0 vr]; simpl.
    + split; [intros _; split; [reflexivity| intros [|i] T0 Hb; discriminate Hb] | intros _; exact I].
    + split; [contradiction | intros [Hbad _]; discriminate Hbad].
  - destruct vs as [|v0 vr]; simpl.
    + split; [contradiction | intros [Hbad _]; discriminate Hbad].
    + split.
      * intros [Hd Hrest]. apply IH in Hrest. destruct Hrest as [Hlen Hall].
        split; [rewrite Hlen; reflexivity|].
        intros [|i] T0 Hnth; simpl in Hnth.
        -- injection Hnth as <-. exists v0; split; [reflexivity| exact Hd].
        -- apply Hall; exact Hnth.
      * intros [Hlen Hall]. split.
        -- destruct (Hall 0 T eq_refl) as [v0' [Hv0 Hd]]. simpl in Hv0. injection Hv0 as <-. exact Hd.
        -- apply IH. split; [injection Hlen as Hlen; exact Hlen|].
           intros i T0 Hnth. destruct (Hall (S i) T0 Hnth) as [v0' [Hv0 Hd]].
           simpl in Hv0. exists v0'; split; assumption.
Qed.

Theorem denote_tuple_iff : forall Ts v,
  denote (BTuple Ts) v
  <-> exists vs, v = VTup vs /\
        List.length Ts = List.length vs /\
        (forall i T, nth_error Ts i = Some T ->
           exists v0, nth_error vs i = Some v0 /\ denote T v0).
Proof.
  intros Ts v. simpl. split.
  - destruct v as [ | | | | | | | vs ]; try contradiction.
    intros Hfold. exists vs. split; [reflexivity|]. apply tuple_fold_iff. exact Hfold.
  - intros [vs [Hv Hrest]]. subst v. apply tuple_fold_iff. exact Hrest.
Qed.

(* POINTWISE / POSITIONAL tuple subtyping (depth, covariant): if the two type-
   sequences have the same length and are pointwise [dsub]-related, the tuple
   types are [dsub]-related. (Width / arity-polymorphism are DEFERRED.) *)
Lemma tuple_pointwise_fold : forall Ts Ss vs,
  List.length Ts = List.length Ss ->
  (forall i T S, nth_error Ts i = Some T -> nth_error Ss i = Some S -> dsub T S) ->
  (fix all_pos (ts : list BTy) (vv : list V) : Prop :=
     match ts, vv with [],[] => True | T::tr,v0::vr => denote T v0 /\ all_pos tr vr | _,_ => False end) Ts vs ->
  (fix all_pos (ts : list BTy) (vv : list V) : Prop :=
     match ts, vv with [],[] => True | T::tr,v0::vr => denote T v0 /\ all_pos tr vr | _,_ => False end) Ss vs.
Proof.
  induction Ts as [|T tr IH]; intros Ss vs Hlen Hpt Hd; destruct Ss as [|Sh sr]; simpl in *;
    try discriminate Hlen.
  - exact Hd.
  - destruct vs as [|v0 vr]; [contradiction|]. destruct Hd as [Hdv Hdr].
    split.
    + apply (Hpt 0 T Sh eq_refl eq_refl). exact Hdv.
    + apply (IH sr vr); [injection Hlen as Hlen; exact Hlen | | exact Hdr].
      intros i T0 S0 HT0 HS0. apply (Hpt (S i) T0 S0 HT0 HS0).
Qed.

(* Pointwise / positional tuple subtyping, via the lockstep fold. *)
Theorem dtuple_pointwise : forall Ts Ss,
  List.length Ts = List.length Ss ->
  (forall i T S, nth_error Ts i = Some T -> nth_error Ss i = Some S -> dsub T S) ->
  dsub (BTuple Ts) (BTuple Ss).
Proof.
  intros Ts Ss Hlen Hpt. unfold dsub. intros v. simpl.
  destruct v as [ | | | | | | | vs ]; try contradiction.
  apply tuple_pointwise_fold; assumption.
Qed.

(* DISJOINTNESS — a value-sequence is a distinct value-kind. *)
Theorem tuple_disjoint_atom : forall Ts a,
  dsub (BInter (BTuple Ts) (BAtom a)) BBot.
Proof.
  intros Ts a. unfold dsub. intros v [Ht Ha].
  apply denote_tuple_iff in Ht. destruct Ht as [vs [Hv _]]. subst v.
  destruct a; simpl in Ha; contradiction.
Qed.

Theorem tuple_disjoint_rec : forall Ts g,
  dsub (BInter (BTuple Ts) (BRec g)) BBot.
Proof.
  intros Ts g. unfold dsub. intros v [Ht Hr].
  apply denote_tuple_iff in Ht. destruct Ht as [vs [Hv _]]. subst v.
  apply denote_rec_iff in Hr. destruct Hr as [ents [Hbad _]]. discriminate Hbad.
Qed.

Theorem tuple_disjoint_arrow : forall Ts A B,
  dsub (BInter (BTuple Ts) (BArrow A B)) BBot.
Proof.
  intros Ts A B. unfold dsub. intros v [Ht Harr].
  apply denote_tuple_iff in Ht. destruct Ht as [vs [Hv _]]. subst v.
  apply denote_arrow_iff in Harr. destruct Harr as [g [Hbad _]]. discriminate Hbad.
Qed.

Theorem tuple_disjoint_ref : forall Ts T,
  dsub (BInter (BTuple Ts) (BRef T)) BBot.
Proof.
  intros Ts T. unfold dsub. intros v [Ht Hr].
  apply denote_tuple_iff in Ht. destruct Ht as [vs [Hv _]]. subst v.
  simpl in Hr. contradiction.
Qed.

(* NON-VACUITY: a concrete two-element sequence inhabits its tuple type. *)
Theorem tuple_inhabited :
  denote (BTuple [BAtom AInt; BAtom AStr]) (VTup [VInt 0; VStr 0]).
Proof. apply denote_tuple_iff. exists [VInt 0; VStr 0]. split; [reflexivity|].
  split; [reflexivity|]. intros [|[|[|i]]] T Hnth; simpl in Hnth; try discriminate Hnth.
  - injection Hnth as <-. exists (VInt 0); split; [reflexivity| exact I].
  - injection Hnth as <-. exists (VStr 0); split; [reflexivity| exact I].
Qed.

(* LENGTH MISMATCH is a GENUINE non-subtyping (positional, exact-length — not
   width): a 1-tuple is NOT a 2-tuple (witness: the 1-element sequence). So tuple
   membership is non-vacuous in the length dimension. *)
Theorem tuple_length_matters :
  ~ dsub (BTuple [BAtom AInt]) (BTuple [BAtom AInt; BAtom AInt]).
Proof.
  unfold dsub. intro H.
  specialize (H (VTup [VInt 0])).
  assert (Hpre : denote (BTuple [BAtom AInt]) (VTup [VInt 0])).
  { apply denote_tuple_iff. exists [VInt 0]. split; [reflexivity|]. split; [reflexivity|].
    intros [|i] T Hnth; simpl in Hnth; [injection Hnth as <-; exists (VInt 0); split; [reflexivity|exact I] | destruct i; discriminate Hnth]. }
  specialize (H Hpre). apply denote_tuple_iff in H. destruct H as [vs [Hv [Hlen _]]].
  injection Hv as <-. simpl in Hlen. discriminate Hlen.
Qed.

(* DECISION PROCEDURE stays sound with tuples — any tuple-involving query DEFERS
   (DUnknown), never a confident wrong answer. *)
Example gd_tuple_defers :
  gdecide (BTuple [BAtom AInt]) (BTuple [BAtom AStr]) = DUnknown.
Proof. reflexivity. Qed.

Theorem gd_tuple_not_dsub_claim :
  gdecide (BTuple [BAtom AInt]) (BTuple [BAtom AStr]) <> DSub.
Proof. discriminate. Qed.

(* ===========================================================================
   PRINT ASSUMPTIONS — the three unconditional/headline theorems are closed
   under the global context (no axioms, no Admitted, no Classical) — AND remain
   so after [BArrow] is threaded through the whole development. The core arrow
   laws (variance, disjointness), the extended [denote_dec], and a Boolean law
   are checked too.
   =========================================================================== *)
Print Assumptions gdecide_DSub_sound.
Print Assumptions gdecide_DNotSub_sound.
Print Assumptions gdecide_complete.
Print Assumptions darrow_variance.
Print Assumptions arrow_disjoint_atom.
Print Assumptions arrow_disjoint_rec.
Print Assumptions darrow_inter_cod.
Print Assumptions denote_dec.
Print Assumptions ddistrib_inter_union.
(* LuaJIT 5.1 number-atom correction: int <: float (and <: num), the collapsed
   value domain — all closed under the global context. *)
Print Assumptions AInt_sub_AFloat.
Print Assumptions AInt_sub_ANum.
Print Assumptions AFloat_equiv_ANum.
Print Assumptions base_order_int_num.
Print Assumptions decide_dsub_correct.
(* SPLIT-STEP 1 — the reference substrate. The hand-rolled induction principle
   (extended for VRef), the De Morgan / distributivity Boolean law (re-checked
   post-extension), [denote_dec] (decides ref membership too), and the new ref
   membership + disjointness + content-blindness facts — all closed under the
   global context. *)
Print Assumptions V_rect_strong.
Print Assumptions dde_morgan_inter.
Print Assumptions denote_ref_iff.
Print Assumptions denote_anyref_iff.
Print Assumptions ref_int_inhabited.
Print Assumptions anyref_equiv_ref.
Print Assumptions ref_equiv_ref.
Print Assumptions ref_disjoint_atom.
Print Assumptions ref_disjoint_rec.
Print Assumptions ref_disjoint_arrow.
(* MULTI-RETURN — the tuple / value-sequence substrate: positional membership,
   pointwise subtyping, disjointness from every other kind, length-mismatch
   non-subtyping, inhabitation — all closed under the global context. *)
Print Assumptions denote_tuple_iff.
Print Assumptions dtuple_pointwise.
Print Assumptions tuple_disjoint_atom.
Print Assumptions tuple_disjoint_rec.
Print Assumptions tuple_disjoint_arrow.
Print Assumptions tuple_disjoint_ref.
Print Assumptions tuple_inhabited.
Print Assumptions tuple_length_matters.
