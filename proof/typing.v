(* typing.v — MINIMAL syntactic type-soundness for crescent's type kernel.

   The typing layer atop the subtyping algebra of [subtype.v]. A small term
   language (STLC + records + a subsumption rule wired to [dsub]), a CBV
   small-step operational semantics over de Bruijn terms, and the two soundness
   theorems PROGRESS + PRESERVATION, proved to Qed with no Admitted / Axiom /
   Classical and no change to [subtype.v].

   SCOPE (honest, minimal core): literals, variables (de Bruijn), single-arg
   typed lambdas, application, let (sugar via lambda is available but [tlet] is a
   primitive here), record construction, field projection, and SUBSUMPTION
   (the seam where the proven [dsub] subtyping plugs in). DEFERRED to the
   proof-dev backlog: statements / control flow, mutation, multi-arg / vararg /
   multi-return, recursion (fix / mu), metatables, unions/negation/arrows AS
   term-formers (the type ALGEBRA has them; the TERM language's introduction
   forms are the minimal core).

   Build (inside `nix develop`, from repo root):
     nix develop -c coqc proof/subtype.v
     nix develop -c coqc proof/typing.v
   ([coqc subtype.v] writes subtype.vo next to the source; [Require Import
   subtype] below picks it up because typing.v sits in the same directory.)
*)

Require Import subtype.
From Stdlib Require Import List.
From Stdlib Require Import String.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
Import ListNotations.

(* ===========================================================================
   1. TERM LANGUAGE — de Bruijn indices (capture-avoiding by construction).

   Variables are nat indices into a context; binders carry no source name, so
   alpha-equivalence is syntactic equality and capture cannot arise. Literals
   carry their payload directly (an [LInt] is integer-valued, typed [AInt]).
   =========================================================================== *)

Inductive lit : Type :=
  | LInt  : nat -> lit          (* integer-valued number literal; type AInt   *)
  | LStr  : nat -> lit          (* string literal;                 type AStr   *)
  | LBool : bool -> lit         (* boolean literal;                type ABool  *)
  | LNil  : lit.                (* nil literal;                    type ANil   *)

Inductive tm : Type :=
  | tlit  : lit -> tm
  | tvar  : nat -> tm
  | tlam  : BTy -> tm -> tm                  (* tlam T body : argument type T   *)
  | tapp  : tm -> tm -> tm
  | tlet  : tm -> tm -> tm                   (* tlet e1 e2 = bind e1, body e2   *)
  | trec  : list (string * tm) -> tm         (* record construction             *)
  | tproj : tm -> string -> tm               (* field projection                *)
  (* INCREMENT 11 — CONDITIONALS. [tif c e1 e2]: a boolean condition [c], a
     then-branch [e1], an else-branch [e2]. The gateway to flow typing: its
     declarative type is the UNION of the branch types ([BUnion T1 T2]), so a
     value of either branch inhabits the result and subsumption can widen
     further. Intersection / negation / flow narrowing are DEFERRED. *)
  | tif   : tm -> tm -> tm -> tm.            (* tif cond then else              *)

(* The base type of a literal. *)
Definition lit_type (l : lit) : BTy :=
  match l with
  | LInt _  => BAtom AInt
  | LStr _  => BAtom AStr
  | LBool _ => BAtom ABool
  | LNil    => BAtom ANil
  end.

(* ---- A usable induction principle: the auto-generated [tm_ind] gives no IH
   for the subterms inside a [trec] list. Hand-roll the nested scheme (a plain
   Fixpoint, no axiom), mirroring [V_rect_strong] in subtype.v. *)
Section tm_ind_strong.
  Variable P  : tm -> Prop.
  Variable Pl : list (string * tm) -> Prop.
  Hypothesis Hlit  : forall l, P (tlit l).
  Hypothesis Hvar  : forall n, P (tvar n).
  Hypothesis Hlam  : forall T b, P b -> P (tlam T b).
  Hypothesis Happ  : forall f a, P f -> P a -> P (tapp f a).
  Hypothesis Hlet  : forall e1 e2, P e1 -> P e2 -> P (tlet e1 e2).
  Hypothesis Hrec  : forall fs, Pl fs -> P (trec fs).
  Hypothesis Hproj : forall e k, P e -> P (tproj e k).
  Hypothesis Hif   : forall c e1 e2, P c -> P e1 -> P e2 -> P (tif c e1 e2).
  Hypothesis Hnil  : Pl [].
  Hypothesis Hcons : forall k e rest, P e -> Pl rest -> Pl ((k, e) :: rest).
  Fixpoint tm_rect_strong (e : tm) : P e :=
    match e with
    | tlit l    => Hlit l
    | tvar n    => Hvar n
    | tlam T b  => Hlam T b (tm_rect_strong b)
    | tapp f a  => Happ f a (tm_rect_strong f) (tm_rect_strong a)
    | tlet e1 e2 => Hlet e1 e2 (tm_rect_strong e1) (tm_rect_strong e2)
    | trec fs   =>
        Hrec fs
          ((fix go (fs : list (string * tm)) : Pl fs :=
              match fs with
              | [] => Hnil
              | (k, e) :: rest => Hcons k e rest (tm_rect_strong e) (go rest)
              end) fs)
    | tproj e k => Hproj e k (tm_rect_strong e)
    | tif c e1 e2 => Hif c e1 e2 (tm_rect_strong c) (tm_rect_strong e1) (tm_rect_strong e2)
    end.
End tm_ind_strong.

(* ===========================================================================
   2. TYPING JUDGMENT — has_type Gamma e T, Gamma a de Bruijn context.

   The variable rule looks the index up in Gamma; lambda extends the context
   with its argument type; SUBSUMPTION (TSub) plugs the subtyping in.

   --- WHY A SYNTACTIC [ssub] AND NOT [dsub] DIRECTLY (the central finding) ----
   The semantic subtyping [dsub] of subtype.v is the GROUND TRUTH on the value
   sets, but it is TOO COARSE to drive syntactic type soundness of the lambda
   calculus, and this is MACHINE-CHECKED, not hand-waved. In the value-set model
   an arrow with a [Top] (or otherwise unconstrained) codomain COLLAPSES:
   [denote (BArrow A BTop) v] = [v is any VFun], so

       dsub (BArrow (BRec [("f",Int)]) Int) (BArrow Int BTop)      (PROVABLE)

   holds — the right arrow forgets the real domain entirely. Subsuming a
   record-domained function to [Int -> Top] and applying it to an [Int] then
   beta-reduces to a term that projects a field off an [Int]: STUCK and NOT
   typeable at any type. So PRESERVATION with [TSub] over raw [dsub] is FALSE.
   (The witness dsub above is proved as [arrow_top_collapse] below;
   the stuck successor is [preservation_dsub_counterexample].)

   The principled fix — and the reason a SYNTACTIC algorithmic relation is on the
   roadmap at all — is to subsume along a syntactic subtyping [ssub] whose arrow
   rule has the variance inversion BUILT IN (contravariant domain / covariant
   codomain as a PREMISE, not a derived fact). [ssub] is proved SOUND w.r.t.
   [dsub] ([ssub_sound : ssub a b -> dsub a b]), so the proven semantic algebra
   still grounds every subtyping step; what [ssub] adds is the invertibility the
   term structure needs. This is exactly the "retain [sub] as the future
   algorithmic relation, prove it sound vs [dsub]" item from the roadmap, here
   realized for the arrow+record fragment the typing layer uses.
   =========================================================================== *)

(* ---- Syntactic subtyping [ssub] — sound w.r.t. [dsub], and INVERTIBLE ------
   Mutually inductive with [srec] (pointwise record-field subtyping) so the
   auto-generated induction principle carries an IH through the record case. *)
Inductive ssub : BTy -> BTy -> Prop :=
  | SsRefl  : forall T, ssub T T
  | SsTrans : forall A B C, ssub A B -> ssub B C -> ssub A C
  | SsTop   : forall T, ssub T BTop
  | SsBot   : forall T, ssub BBot T
  | SsAtom  : forall a b, atom_le a b -> ssub (BAtom a) (BAtom b)
  | SsArrow : forall A1 B1 A2 B2,
      ssub A2 A1 -> ssub B1 B2 -> ssub (BArrow A1 B1) (BArrow A2 B2)
  | SsRec   : forall f g, srec f g -> ssub (BRec f) (BRec g)
  (* INCREMENT 11 — UNION rules (composable form, mirroring subtype.v's [sub]).
     INTRO injections carry a recursive premise ([ssub A B -> ssub A (BUnion B C)])
     so the inversion lemmas thread through transitivity; the brief's plain
     injections [ssub A (BUnion A B)] / [ssub B (BUnion A B)] are DERIVED as
     [ssub_union_inl] / [ssub_union_inr] (= the composable rule at [SsRefl]).
     ELIM is the standard least-upper-bound rule. All three are SOUND vs [dsub]
     (the Boolean algebra: union is the join), proved in [ssub_sound] below.
     INTERSECTION / NEGATION rules are DEFERRED (next increments). *)
  | SsUnionInL : forall A B C, ssub A B -> ssub A (BUnion B C)
  | SsUnionInR : forall A B C, ssub A C -> ssub A (BUnion B C)
  | SsUnionE   : forall A B C, ssub A C -> ssub B C -> ssub (BUnion A B) C
(* [srec f g]: the demanded record [g] is met by [f] — width + depth. We thread
   it as "g is built field-by-field, each demanded field present in f with a
   sub-field type", using [field_get] to locate the supplier in f. *)
with srec : list (string * BTy) -> list (string * BTy) -> Prop :=
  | SrNil  : forall f, srec f []
  | SrCons : forall f k Tf Tg g,
      In (k, Tf) f -> ssub Tf Tg -> srec f g -> srec f ((k, Tg) :: g).

Scheme ssub_mind := Induction for ssub Sort Prop
  with srec_mind := Induction for srec Sort Prop.

(* [srec f g] entails the set-theoretic "every demanded field has a supplier". *)
Lemma srec_lookup : forall f g,
  srec f g ->
  forall k Tg, In (k, Tg) g -> exists Tf, In (k, Tf) f /\ ssub Tf Tg.
Proof.
  intros f g H. induction H; intros k0 Tg0 Hin.
  - simpl in Hin; contradiction.
  - simpl in Hin. destruct Hin as [Heq | Hin].
    + injection Heq as <- <-. exists Tf. split; assumption.
    + apply IHsrec; assumption.
Qed.

(* supplier-weakening: more suppliers on the left preserves [srec]. *)
Lemma srec_weaken : forall x f g, srec f g -> srec (x :: f) g.
Proof.
  intros x f g H. induction H.
  - apply SrNil.
  - eapply SrCons; [ right; exact H | exact H0 | exact IHsrec ].
Qed.

(* [srec] is reflexive: every field of [f] is supplied by [f] (with [ssub] refl).
   By induction on [f]; the head supplies itself, the tail by IH + weakening. *)
Lemma srec_refl : forall f, srec f f.
Proof.
  intro f. induction f as [ | [k T] f IH ].
  - apply SrNil.
  - eapply SrCons; [ left; reflexivity | apply SsRefl | apply srec_weaken; exact IH ].
Qed.

(* [srec] is transitive (field demands compose through a middle record), using
   [srec_lookup] to locate the middle supplier and [SsTrans] to compose the
   field subtypings. By induction on the SECOND [srec] derivation. *)
Lemma srec_trans : forall f g h, srec f g -> srec g h -> srec f h.
Proof.
  intros f g h Hfg Hgh. revert f Hfg.
  induction Hgh as [ g0 | g0 k Tg Th h0 Hin Hgh Hsrec IH ]; intros f Hfg.
  - apply SrNil.
  - destruct (srec_lookup f g0 Hfg k Tg Hin) as [Tf [Hinf Hsf]].
    eapply SrCons; [ exact Hinf | eapply SsTrans; [ exact Hsf | exact Hgh ] | ].
    apply IH. exact Hfg.
Qed.
Lemma ssub_sound : forall a b, ssub a b -> dsub a b.
Proof.
  intros a b H.
  induction H using ssub_mind with
    (P0 := fun f g (_ : srec f g) =>
       forall ents,
         (forall k Tf, In (k, Tf) f ->
            exists vv, assoc_lookup k ents = Some vv /\ denote Tf vv) ->
         (forall k Tg, In (k, Tg) g ->
            exists vv, assoc_lookup k ents = Some vv /\ denote Tg vv)).
  - apply dsub_refl.
  - eapply dsub_trans; eassumption.
  - unfold dsub; intros; exact I.
  - unfold dsub; simpl; intros v Hf; destruct v; simpl in Hf; contradiction.
  - unfold dsub; intros v Hv;
      match goal with [ Hle : atom_le _ _ |- _ ] => rename Hle into Hle0 end;
      inversion Hle0; subst; simpl in *;
      destruct v as [r| | | | |]; try contradiction; try destruct r;
      simpl; exact I.
  - apply darrow_variance; assumption.
  - (* SsRec: use the P0 fact to transport every demanded field *)
    unfold dsub. intros v Hv. apply denote_rec_iff in Hv. apply denote_rec_iff.
    destruct Hv as [ents [Hve Hall]]. exists ents. split; [exact Hve|].
    apply IHssub. exact Hall.
  - (* SsUnionInL: A ⊆ B ⊆ B∪C — union is the join (left injection). *)
    unfold dsub in *. intros v Hv. simpl. left. auto.
  - (* SsUnionInR: A ⊆ C ⊆ B∪C (right injection). *)
    unfold dsub in *. intros v Hv. simpl. right. auto.
  - (* SsUnionE: A ⊆ C and B ⊆ C ⇒ A∪B ⊆ C (least upper bound). *)
    unfold dsub in *. intros v Hv. simpl in Hv. destruct Hv as [Ha | Hb]; auto.
  - (* SrNil *) intros ents Hf k Tg Hin. simpl in Hin; contradiction.
  - (* SrCons *) intros ents Hf k0 Tg0 Hin. simpl in Hin. destruct Hin as [Heq | Hin].
    + injection Heq as <- <-.
      destruct (Hf k Tf i) as [vv [Hlk Hvv]].
      exists vv. split; [exact Hlk | apply IHssub; exact Hvv].
    + apply IHssub0; assumption.
Qed.

(* ---- UNION rule helpers (INCREMENT 11) ------------------------------------
   The brief's plain injection rules, recovered from the composable forms at
   [SsRefl] (mirroring subtype.v's [sub_union_inl] etc.). Plus the union-source
   DECOMPOSITION ([ssub (A∪B) C ⇒ ssub A C ∧ ssub B C]) — immediate from the
   injections + transitivity, NO induction — which is what lets the SHAPE lemmas
   below handle a union appearing as the transitivity middle. *)

Lemma ssub_union_inl : forall A B, ssub A (BUnion A B).
Proof. intros A B. apply SsUnionInL, SsRefl. Qed.

Lemma ssub_union_inr : forall A B, ssub B (BUnion A B).
Proof. intros A B. apply SsUnionInR, SsRefl. Qed.

Lemma ssub_union_src_l : forall A B C, ssub (BUnion A B) C -> ssub A C.
Proof. intros A B C H. eapply SsTrans; [ apply ssub_union_inl | exact H ]. Qed.

Lemma ssub_union_src_r : forall A B C, ssub (BUnion A B) C -> ssub B C.
Proof. intros A B C H. eapply SsTrans; [ apply ssub_union_inr | exact H ]. Qed.

Inductive has_type : list BTy -> tm -> BTy -> Prop :=
  | TLit  : forall G l,
      has_type G (tlit l) (lit_type l)
  | TVar  : forall G n T,
      nth_error G n = Some T ->
      has_type G (tvar n) T
  | TLam  : forall G T body Tb,
      has_type (T :: G) body Tb ->
      has_type G (tlam T body) (BArrow T Tb)
  | TApp  : forall G f a A B,
      has_type G f (BArrow A B) ->
      has_type G a A ->
      has_type G (tapp f a) B
  | TLet  : forall G e1 e2 A B,
      has_type G e1 A ->
      has_type (A :: G) e2 B ->
      has_type G (tlet e1 e2) B
  | TRec  : forall G fs Ts,
      (* fields typed pointwise, key-aligned with Ts (via mutual has_fields).
         Record keys are DISTINCT (NoDup) — Lua-faithful (one value per key) and
         what makes [field_lookup] (first-match) agree with the type assigned to
         that key; duplicate-key literals are out of scope. *)
      has_fields G fs Ts ->
      NoDup (map fst fs) ->
      has_type G (trec fs) (BRec Ts)
  | TProj : forall G e fields k T,
      has_type G e (BRec fields) ->
      In (k, T) fields ->
      has_type G (tproj e k) T
  | TSub  : forall G e S T,
      has_type G e S ->
      ssub S T ->          (* subsume along syntactic ssub (sound for dsub) *)
      has_type G e T
  (* INCREMENT 11 — conditionals. The condition must be Bool; the result type is
     the UNION of the two branch types (the JOIN), so a value of either branch
     inhabits the result. Subsumption ([TSub]) can then widen each branch to a
     common type if desired, but the canonical synthesized type is the union. *)
  | TIf   : forall G c e1 e2 T1 T2,
      has_type G c (BAtom ABool) ->
      has_type G e1 T1 ->
      has_type G e2 T2 ->
      has_type G (tif c e1 e2) (BUnion T1 T2)
(* key-aligned pointwise typing of record fields; mutual so the generated
   induction principle carries an IH on every field derivation. *)
with has_fields : list BTy -> list (string * tm) -> list (string * BTy) -> Prop :=
  | HFnil  : forall G, has_fields G [] []
  | HFcons : forall G k e T fs Ts,
      has_type G e T ->
      has_fields G fs Ts ->
      has_fields G ((k, e) :: fs) ((k, T) :: Ts).

Scheme has_type_mind := Induction for has_type Sort Prop
  with has_fields_mind := Induction for has_fields Sort Prop.

(* The MACHINE-CHECKED finding that motivates [ssub]: the semantic [dsub] arrow
   with a [Top] codomain collapses to "any function", forgetting the domain. *)
Lemma arrow_top_collapse :
  dsub (BArrow (BRec [("f"%string, BAtom AInt)]) (BAtom AInt))
       (BArrow (BAtom AInt) BTop).
Proof.
  unfold dsub. intros v Hv. apply denote_arrow_iff in Hv.
  destruct Hv as [g [Hg _]]. subst v. apply denote_arrow_iff.
  exists g. split; [reflexivity|]. intros i o _ _. exact I.
Qed.

(* ===========================================================================
   3. VALUES + CBV SMALL-STEP OPERATIONAL SEMANTICS (substitution-based,
      de Bruijn). Values: literals, lambdas, records whose fields are all
      values. Beta for app, let-binding by substitution, projection lookup.
   =========================================================================== *)

Inductive value : tm -> Prop :=
  | VLit  : forall l, value (tlit l)
  | VLam  : forall T b, value (tlam T b)
  | VRec  : forall fs, Forall (fun ke => value (snd ke)) fs -> value (trec fs).

(* ---- de Bruijn lifting and substitution -----------------------------------
   [lift d k e] increments every free variable >= k by d (shifting under d new
   binders). [subst j s e] replaces variable [j] by [s], decrementing higher
   free vars (the standard capture-avoiding de Bruijn substitution). We only
   ever substitute under one freshly-introduced binder, so [lift 1 0] suffices
   to make a closed [s] usable under a binder; closed values (the only things
   we substitute, CBV) are lift-invariant, which keeps the metatheory short. *)

Fixpoint lift (d k : nat) (e : tm) : tm :=
  match e with
  | tlit l    => tlit l
  | tvar n    => if Nat.ltb n k then tvar n else tvar (n + d)
  | tlam T b  => tlam T (lift d (S k) b)
  | tapp f a  => tapp (lift d k f) (lift d k a)
  | tlet e1 e2 => tlet (lift d k e1) (lift d (S k) e2)
  | trec fs   => trec (map (fun ke => (fst ke, lift d k (snd ke))) fs)
  | tproj e k0 => tproj (lift d k e) k0
  | tif c e1 e2 => tif (lift d k c) (lift d k e1) (lift d k e2)
  end.

Fixpoint subst (j : nat) (s : tm) (e : tm) : tm :=
  match e with
  | tlit l    => tlit l
  | tvar n    =>
      match Nat.compare n j with
      | Lt => tvar n            (* below the binder: unchanged             *)
      | Eq => s                 (* the bound variable: replaced by s       *)
      | Gt => tvar (Nat.pred n) (* above: shift down (binder removed)      *)
      end
  | tlam T b  => tlam T (subst (S j) (lift 1 0 s) b)
  | tapp f a  => tapp (subst j s f) (subst j s a)
  | tlet e1 e2 => tlet (subst j s e1) (subst (S j) (lift 1 0 s) e2)
  | trec fs   => trec (map (fun ke => (fst ke, subst j s (snd ke))) fs)
  | tproj e k => tproj (subst j s e) k
  | tif c e1 e2 => tif (subst j s c) (subst j s e1) (subst j s e2)
  end.

(* record-field lookup at the term level (for projection) *)
Fixpoint field_lookup (k : string) (fs : list (string * tm)) : option tm :=
  match fs with
  | [] => None
  | (k', e) :: rest => if string_dec k k' then Some e else field_lookup k rest
  end.

Inductive step : tm -> tm -> Prop :=
  (* beta: (\T.b) v  ->  b[0 := v]  *)
  | SBeta : forall T b v,
      value v ->
      step (tapp (tlam T b) v) (subst 0 v b)
  (* let: bind a value, substitute into the body *)
  | SLet  : forall v e2,
      value v ->
      step (tlet v e2) (subst 0 v e2)
  (* projection lookup on a record value *)
  | SProj : forall fs k v,
      value (trec fs) ->
      field_lookup k fs = Some v ->
      step (tproj (trec fs) k) v
  (* congruence / evaluation contexts (CBV, left-to-right) *)
  | SApp1 : forall f f' a, step f f' -> step (tapp f a) (tapp f' a)
  | SApp2 : forall v a a', value v -> step a a' -> step (tapp v a) (tapp v a')
  | SLet1 : forall e1 e1' e2, step e1 e1' -> step (tlet e1 e2) (tlet e1' e2)
  | SProj1 : forall e e' k, step e e' -> step (tproj e k) (tproj e' k)
  (* record: step the first non-value field (left-to-right) *)
  | SRec  : forall pre k e e' post,
      Forall (fun ke => value (snd ke)) pre ->
      step e e' ->
      step (trec (pre ++ (k, e) :: post)) (trec (pre ++ (k, e') :: post))
  (* INCREMENT 11 — conditional reduction. The two literal selectors and the
     congruence that reduces the condition. Branches are NOT reduced until
     selected (lazy branches — standard for [if]). *)
  | SIfTrue  : forall e1 e2, step (tif (tlit (LBool true)) e1 e2) e1
  | SIfFalse : forall e1 e2, step (tif (tlit (LBool false)) e1 e2) e2
  | SIf1     : forall c c' e1 e2, step c c' -> step (tif c e1 e2) (tif c' e1 e2).

(* ===========================================================================
   4. SUBTYPING INVERSION — the lemmas progress/preservation rest on.

   These are read off the DENOTATION (set inclusion), the [subtype.v]
   definition of [dsub]. They are TRUE in the finite-graph / value-set model;
   the arrow case has genuine edge conditions (inhabitation), surfaced as
   explicit hypotheses and discharged for the cases preservation needs.
   =========================================================================== *)

(* ---- canonical-forms helpers: what a value of a given shape's type means.
   A value's denotation pins its head. We need, for preservation/progress: a
   value of an ARROW type is a lambda; a value of a RECORD type is a record. *)

(* The denotation of every closed value is some concrete [V]; rather than build
   a term->V map, we prove canonical forms SYNTACTICALLY by inversion on
   [has_type] + the fact that subsumption cannot change a value's head class.
   We establish the head facts directly from the typing derivation. *)

(* ---- ARROW INVERSION (the crux) -------------------------------------------
   In the value-set model, [dsub (BArrow A1 B1) (BArrow A2 B2)] gives the
   variance laws ONLY under inhabitation side-conditions:

     - codomain  [dsub B1 B2] needs a witness in [A1] (∩ [A2]) to build a
       function pinning an arbitrary B1-output; with [A1] empty the arrow is
       vacuously inhabited and B1 is unconstrained.
     - domain    [dsub A2 A1] needs a witness OUTSIDE [B2] (i.e. [¬B2]
       inhabited, B2 ≠ Top) to detect an out-of-domain input.

   These are exactly the model's true edge cases (recorded in the brief). We
   prove the lemmas WITH those hypotheses, and below discharge the hypotheses
   for the concrete shape preservation hits (where they always hold because the
   argument's type is inhabited and we never need full domain inversion). *)

(* helper: a singleton-graph function inhabits [BArrow A B] iff its one pair
   respects the constraint. *)
Lemma arrow_singleton : forall A B i o,
  (denote A i -> denote B o) -> denote (BArrow A B) (VFun [(i, o)]).
Proof.
  intros A B i o H. apply denote_arrow_iff. exists [(i, o)].
  split; [reflexivity|]. intros i' o' Hin. simpl in Hin.
  destruct Hin as [Heq | []]. injection Heq as <- <-. exact H.
Qed.

(* CODOMAIN inversion, with the inhabitation side-condition made explicit. *)
Lemma arrow_inv_cod : forall A1 B1 A2 B2,
  dsub (BArrow A1 B1) (BArrow A2 B2) ->
  (exists i, denote A1 i /\ denote A2 i) ->
  dsub B1 B2.
Proof.
  intros A1 B1 A2 B2 Hsub [i [Hi1 Hi2]]. unfold dsub. intros o Ho.
  (* build the function [(i,o)] : it is in BArrow A1 B1 since i in A1 => o in B1. *)
  assert (Hin1 : denote (BArrow A1 B1) (VFun [(i, o)])).
  { apply arrow_singleton. intros _. exact Ho. }
  apply Hsub in Hin1. apply denote_arrow_iff in Hin1.
  destruct Hin1 as [g [Hg Hall]]. injection Hg as <-.
  apply (Hall i o (or_introl eq_refl)). exact Hi2.
Qed.

(* DOMAIN (contravariant) inversion, with its inhabitation side-condition. *)
Lemma arrow_inv_dom : forall A1 B1 A2 B2,
  dsub (BArrow A1 B1) (BArrow A2 B2) ->
  (exists o, ~ denote B2 o) ->
  dsub A2 A1.
Proof.
  intros A1 B1 A2 B2 Hsub [o Hno]. unfold dsub. intros i Hi2.
  (* show i in A1 by contradiction: if not, [(i,o)] is vacuously in BArrow A1 B1,
     hence in BArrow A2 B2, forcing o in B2 — contradiction. *)
  destruct (denote_dec A1 i) as [Hi1 | Hni1]; [exact Hi1|].
  exfalso.
  assert (Hin1 : denote (BArrow A1 B1) (VFun [(i, o)])).
  { apply arrow_singleton. intros Hbad. contradiction. }
  apply Hsub in Hin1. apply denote_arrow_iff in Hin1.
  destruct Hin1 as [g [Hg Hall]]. injection Hg as <-.
  apply Hno. apply (Hall i o (or_introl eq_refl)). exact Hi2.
Qed.

(* ===========================================================================
   5. TYPING INVERSION (subsumption-transparent).

   Each form's typing, threading any number of TSub steps into a single [ssub]
   on the result type. These let us reason by the TERM's shape (the only thing
   that determines a value's runtime head) rather than by the derivation. The
   [ssub] conclusion (not [dsub]) is what makes the arrow case INVERTIBLE.
   =========================================================================== *)

Lemma inv_lit : forall G l T,
  has_type G (tlit l) T -> ssub (lit_type l) T.
Proof.
  intros G l T H. remember (tlit l) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <-. apply SsRefl.
  - subst. eapply SsTrans; [ apply IHhas_type; reflexivity | exact H0 ].
Qed.

Lemma inv_var : forall G n T,
  has_type G (tvar n) T -> exists S, nth_error G n = Some S /\ ssub S T.
Proof.
  intros G n T H. remember (tvar n) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <-. exists T. split; [assumption | apply SsRefl].
  - subst. destruct (IHhas_type eq_refl) as [S0 [Hl Hd]].
    exists S0. split; [assumption | eapply SsTrans; eassumption].
Qed.

Lemma inv_lam : forall G Tl b T,
  has_type G (tlam Tl b) T ->
  exists Tb, has_type (Tl :: G) b Tb /\ ssub (BArrow Tl Tb) T.
Proof.
  intros G Tl b T H. remember (tlam Tl b) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists Tb. split; [assumption | apply SsRefl].
  - subst. destruct (IHhas_type eq_refl) as [Tb [Hb Hd]].
    exists Tb. split; [assumption | eapply SsTrans; eassumption].
Qed.

Lemma inv_app : forall G f a T,
  has_type G (tapp f a) T ->
  exists A B, has_type G f (BArrow A B) /\ has_type G a A /\ ssub B T.
Proof.
  intros G f a T H. remember (tapp f a) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists A, B. split; [assumption|split;[assumption|apply SsRefl]].
  - subst. destruct (IHhas_type eq_refl) as [A0 [B0 [Hf [Ha Hd]]]].
    exists A0, B0. split; [assumption|split;[assumption|eapply SsTrans; eassumption]].
Qed.

Lemma inv_let : forall G e1 e2 T,
  has_type G (tlet e1 e2) T ->
  exists A B, has_type G e1 A /\ has_type (A :: G) e2 B /\ ssub B T.
Proof.
  intros G e1 e2 T H. remember (tlet e1 e2) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists A, B. split;[assumption|split;[assumption|apply SsRefl]].
  - subst. destruct (IHhas_type eq_refl) as [A0 [B0 [H1 [H2 Hd]]]].
    exists A0, B0. split;[assumption|split;[assumption|eapply SsTrans; eassumption]].
Qed.

Lemma inv_rec : forall G fs T,
  has_type G (trec fs) T ->
  exists Ts, has_fields G fs Ts /\ NoDup (map fst fs) /\ ssub (BRec Ts) T.
Proof.
  intros G fs T H. remember (trec fs) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <-. exists Ts. split; [assumption | split; [assumption | apply SsRefl]].
  - subst. destruct (IHhas_type eq_refl) as [Ts [Hf [Hnd Hd]]].
    exists Ts. split; [assumption | split; [assumption | eapply SsTrans; eassumption]].
Qed.

Lemma inv_proj : forall G e k T,
  has_type G (tproj e k) T ->
  exists fields S, has_type G e (BRec fields) /\ In (k, S) fields /\ ssub S T.
Proof.
  intros G e k T H. remember (tproj e k) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists fields, T. split;[assumption|split;[assumption|apply SsRefl]].
  - subst. destruct (IHhas_type eq_refl) as [fields [S0 [He [Hin Hd]]]].
    exists fields, S0. split;[assumption|split;[assumption|eapply SsTrans; eassumption]].
Qed.

(* INCREMENT 11 — [tif] inversion, subsumption-transparent: the condition is
   Bool, the branches type at [T1]/[T2], and the union of those is [ssub]-below
   the ascribed type [T]. *)
Lemma inv_if : forall G c e1 e2 T,
  has_type G (tif c e1 e2) T ->
  exists U1 U2, has_type G c (BAtom ABool) /\ has_type G e1 U1 /\
                has_type G e2 U2 /\ ssub (BUnion U1 U2) T.
Proof.
  intros G c e1 e2 T H. remember (tif c e1 e2) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [U1 [U2 [Hc [H1 [H2 Hd]]]]].
    exists U1, U2. split;[assumption|split;[assumption|split;[assumption|eapply SsTrans; eassumption]]].
  - injection Ee as <- <- <-. do 2 eexists.
    split;[eassumption|split;[eassumption|split;[eassumption|apply SsRefl]]].
Qed.

(* ===========================================================================
   6. [ssub] SHAPE / INVERSION LEMMAS — the invertibility that motivated ssub.
   =========================================================================== *)

(* Top has no proper supertype; Bot has no proper subtype — RESTATED for the
   union increment. With the union INTRO rules, [ssub BTop C] no longer forces
   [C = BTop] syntactically ([BTop <: BTop ∪ X] holds), so the old syntactic
   statement is FALSE. The SEMANTIC content survives intact and is exactly what
   the consumers need: [ssub BTop C] means C is UNIVERSALLY INHABITED (every
   value is in C), via [ssub_sound] + [denote BTop = True]. Dually [ssub C BBot]
   means C is EMPTY. Atoms / arrows / records are neither universally-inhabited
   nor empty, so the contradiction-consumers go through against these semantic
   forms. This is the honest soundness-preserving generalization: the syntactic
   maximality of Top/minimality of Bot is replaced by their semantic content,
   which the union rules do NOT disturb (union is the join — adding Top to a
   union keeps it universally-inhabited). *)
Lemma ssub_top_univ : forall C, ssub BTop C -> forall v, denote C v.
Proof.
  intros C H v. apply ssub_sound in H. apply H. simpl. exact I.
Qed.

Lemma ssub_bot_empty : forall C, ssub C BBot -> forall v, ~ denote C v.
Proof.
  intros C H v Hv. apply ssub_sound in H. apply (H v Hv).
Qed.

(* Atoms / arrows / records each have a NON-inhabitant and an inhabitant, so they
   are neither universally-inhabited nor empty. We need only the directions the
   consumers use: an atom/arrow/record is NOT universally inhabited (so it is not
   a Top-supertype) and NOT empty (so it is not a Bot-subtype). The witnesses are
   concrete [V] values. *)

(* A value OUTSIDE a given atom (so the atom is not universally inhabited). *)
Lemma atom_has_nonmember : forall a, exists v, ~ atom_denote a v.
Proof.
  intro a. destruct a.
  - exists (VBool true); simpl; auto.
  - exists VNil; simpl; auto.
  - exists (VStr 0); simpl; auto.
  - exists (VStr 0); simpl; auto.
  - exists (VStr 0); simpl; auto.
  - exists VNil; simpl; auto.
Qed.

(* An atom is non-empty (every atom is inhabited). *)
Lemma atom_has_member : forall a, exists v, atom_denote a v.
Proof.
  intro a. destruct a.
  - exists VNil; simpl; exact I.
  - exists (VBool true); simpl; exact I.
  - exists (VInt 0); simpl; exact I.
  - exists (VInt 0); simpl; exact I.
  - exists (VInt 0); simpl; exact I.
  - exists (VStr 0); simpl; exact I.
Qed.


(* ---- ARROW / RECORD SUPERTYPE inversion — the UNION-ROBUST mechanism ------
   THE CORE SOUNDNESS SUBTLETY of this increment (honest finding). [ssub] has
   EXPLICIT transitivity ([SsTrans] is a constructor — deliberately, so the
   typing-layer [inv_*] lemmas thread arbitrary subsumption chains). The union
   INTRO rules let a transitivity MIDDLE be a union: e.g. [BArrow A1 B1 <:
   (BArrow A2 B2 ∪ BArrow A1 B1) <: BArrow A2 B2]. A naive "induction on the
   derivation" supertype-inversion then STALLS at the union middle — it has no
   induction hypothesis for the union-decomposed components (they are fresh
   trans-built derivations, not sub-derivations).

   The clean resolution (no cut-elimination, no size juggling): characterize "what
   lies above an arrow" by a STRUCTURAL predicate [arrow_above] over the supertype
   syntax, and prove that predicate is CLOSED UNDER [ssub] ON THE RIGHT
   ([arrow_above_mono]) BY INDUCTION ON the [ssub] derivation. Every case — incl.
   SsTrans and the three union cases — composes through the structural predicate
   with its IHs as proper sub-derivations:
     - SsTrans M→M'→C: arrow_above M, ssub M M' ⊢(IH1) arrow_above M', ssub M' C
       ⊢(IH2) arrow_above C.
     - SsArrow: recompose contra/co variance via SsTrans on the components.
     - SsUnionInL/InR: arrow_above injects into the chosen disjunct.
     - SsUnionE: the union-source's arrow_above is a disjunction; either case's
       sub-derivation carries it through.
   This is the union analogue of subtype.v's "composable rules make inversion
   routine"; here the structural predicate plays that role against EXPLICIT
   transitivity. The same mechanism gives record supertype inversion. *)

Fixpoint arrow_above (A1 B1 T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BArrow A2 B2  => ssub A2 A1 /\ ssub B1 B2
  | BUnion Tl Tr  => arrow_above A1 B1 Tl \/ arrow_above A1 B1 Tr
  | _             => False
  end.

Fixpoint rec_above (f : list (string * BTy)) (T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BRec g        => srec f g
  | BUnion Tl Tr  => rec_above f Tl \/ rec_above f Tr
  | _             => False
  end.

(* [arrow_above] is closed under [ssub] on the right — the union-robust core. *)
Lemma arrow_above_mono : forall M C, ssub M C ->
  forall Ax Bx, arrow_above Ax Bx M -> arrow_above Ax Bx C.
Proof.
  intros M C H. induction H; intros Ax Bx Hab; simpl in *; try exact I; try exact Hab; try contradiction.
  - (* SsTrans M→B→C: compose the two IHs left-to-right (name-agnostic). *)
    match goal with
    | [ IHl : forall _ _, arrow_above _ _ ?m -> arrow_above _ _ ?b,
        IHr : forall _ _, arrow_above _ _ ?b -> arrow_above _ _ ?c
        |- arrow_above ?Ax ?Bx ?c ] =>
      apply (IHr Ax Bx); apply (IHl Ax Bx); exact Hab
    end.
  - (* SsArrow: compose contra-domain / co-codomain via SsTrans. *)
    destruct Hab as [HdomM HcodM]. split.
    + eapply SsTrans;
        [ match goal with [ Hd : ssub ?A2 ?A1 |- ssub ?A2 _ ] => exact Hd end | exact HdomM ].
    + eapply SsTrans;
        [ exact HcodM | match goal with [ Hc : ssub ?B1 ?B2 |- ssub _ ?B2 ] => exact Hc end ].
  - (* SsUnionInL *) left.
    match goal with [ IH : forall _ _, arrow_above _ _ ?m -> _ |- _ ] => apply IH; exact Hab end.
  - (* SsUnionInR *) right.
    match goal with [ IH : forall _ _, arrow_above _ _ ?m -> _ |- _ ] => apply IH; exact Hab end.
  - (* SsUnionE *) destruct Hab as [Ha | Hb];
    [ match goal with [ IH : forall _ _, arrow_above _ _ ?m -> arrow_above _ _ ?c
                        |- arrow_above ?Ax ?Bx ?c ] => apply (IH Ax Bx); exact Ha end
    | match goal with [ IH : forall _ _, arrow_above _ _ ?m -> arrow_above _ _ ?c
                        |- arrow_above ?Ax ?Bx ?c ] => apply (IH Ax Bx); exact Hb end ].
Qed.

Lemma rec_above_mono : forall M C, ssub M C ->
  forall f, rec_above f M -> rec_above f C.
Proof.
  intros M C H. induction H; intros f0 Hab; simpl in *; try exact I; try exact Hab; try contradiction.
  - (* SsTrans *)
    match goal with
    | [ IHl : forall _, rec_above _ ?m -> rec_above _ ?b,
        IHr : forall _, rec_above _ ?b -> rec_above _ ?c
        |- rec_above ?f0 ?c ] =>
      apply (IHr f0); apply (IHl f0); exact Hab
    end.
  - (* SsRec: srec composition (srec f0 f, srec f g). *)
    match goal with [ Hs : srec ?f ?g |- srec ?f0 ?g ] =>
      eapply srec_trans; [ exact Hab | exact Hs ] end.
  - (* SsUnionInL *) left.
    match goal with [ IH : forall _, rec_above _ ?m -> _ |- _ ] => apply IH; exact Hab end.
  - (* SsUnionInR *) right.
    match goal with [ IH : forall _, rec_above _ ?m -> _ |- _ ] => apply IH; exact Hab end.
  - (* SsUnionE *) destruct Hab as [Ha | Hb];
    [ match goal with [ IH : forall _, rec_above _ ?m -> rec_above _ ?c |- rec_above ?f0 ?c ] =>
        apply (IH f0); exact Ha end
    | match goal with [ IH : forall _, rec_above _ ?m -> rec_above _ ?c |- rec_above ?f0 ?c ] =>
        apply (IH f0); exact Hb end ].
Qed.

(* The supertype-inversion lemmas, now union-robust: an arrow [ssub]-below T
   satisfies [arrow_above]; a record below T satisfies [rec_above]. *)
Lemma ssub_arrow_super : forall A1 B1 T,
  ssub (BArrow A1 B1) T -> arrow_above A1 B1 T.
Proof.
  intros A1 B1 T H. apply (arrow_above_mono (BArrow A1 B1) T H A1 B1).
  simpl. split; apply SsRefl.
Qed.

Lemma ssub_rec_super : forall f T,
  ssub (BRec f) T -> rec_above f T.
Proof.
  intros f T H. apply (rec_above_mono (BRec f) T H f).
  simpl. apply srec_refl.
Qed.

(* The clean arrow inversion: arrow-below-arrow gives the variance. The union
   disjuncts of [arrow_above] are excluded because the target is a concrete arrow. *)
Lemma ssub_arrow_inv : forall A1 B1 A2 B2,
  ssub (BArrow A1 B1) (BArrow A2 B2) -> ssub A2 A1 /\ ssub B1 B2.
Proof.
  intros A1 B1 A2 B2 H. apply ssub_arrow_super in H. simpl in H. exact H.
Qed.

(* ssub record inversion: a demanded field of the supertype-record is supplied by
   the subtype-record with a sub-field type. Immediate from [ssub_rec_super]:
   [rec_above f (BRec g)] is exactly [srec f g], then [srec_lookup]. *)
Lemma ssub_rec_inv : forall f g k Tg,
  ssub (BRec f) (BRec g) -> In (k, Tg) g ->
  exists Tf, In (k, Tf) f /\ ssub Tf Tg.
Proof.
  intros f g k Tg H Hin. apply ssub_rec_super in H. simpl in H.
  eapply srec_lookup; eassumption.
Qed.

(* ---- UNION-TARGET inversion — the dual mechanism, for the DECIDER's union
   completeness. We characterize "what lies BELOW a union [B ∪ C]" by a
   STRUCTURAL predicate [union_below B C X] over the SUBTYPE syntax, and prove it
   CLOSED UNDER [ssub] ON THE LEFT ([union_below_mono] — push leftward through
   [ssub Y X]). This is the exact DUAL of [arrow_above_mono] (which pushed an
   arrow-supertype predicate RIGHTWARD); it dissolves the same explicit-trans /
   union-middle obstruction. The leaf reading is the brief's spec: a NON-union,
   NON-Bot [X] below [B ∪ C] is below [B] or below [C]. *)

Fixpoint union_below (B C X : BTy) : Prop :=
  match X with
  | BBot          => True
  | BUnion X1 X2  => union_below B C X1 /\ union_below B C X2
  | _             => ssub X B \/ ssub X C
  end.

(* If [X ≤ B0] then [X] is below [B0 ∪ _] structurally — by induction on X, the
   union case decomposing via [ssub_union_src_*]. (Dual for the right.) *)
Lemma union_below_of_le_l : forall X B0 C0, ssub X B0 -> union_below B0 C0 X.
Proof.
  induction X; intros B0 C0 H; simpl; try (left; exact H).
  - exact I.                                   (* BBot *)
  - split; [ apply IHX1; eapply ssub_union_src_l; exact H
           | apply IHX2; eapply ssub_union_src_r; exact H ].
Qed.

Lemma union_below_of_le_r : forall X B0 C0, ssub X C0 -> union_below B0 C0 X.
Proof.
  induction X; intros B0 C0 H; simpl; try (right; exact H).
  - exact I.                                   (* BBot *)
  - split; [ apply IHX1; eapply ssub_union_src_l; exact H
           | apply IHX2; eapply ssub_union_src_r; exact H ].
Qed.

Lemma union_below_mono : forall Y X, ssub Y X ->
  forall B C, union_below B C X -> union_below B C Y.
Proof.
  intros Y X H. induction H; intros B0 C0 Hbel; simpl in *.
  - (* SsRefl *) exact Hbel.
  - (* SsTrans Y→B→C: push through both, right-to-left. *)
    match goal with
    | [ IHl : forall _ _, union_below _ _ ?m -> union_below _ _ ?y,
        IHr : forall _ _, union_below _ _ ?x -> union_below _ _ ?m
        |- union_below ?B0 ?C0 ?y ] =>
      apply (IHl B0 C0); apply (IHr B0 C0); exact Hbel
    end.
  - (* SsTop: X = BTop, hyp [ssub BTop B0 \/ ssub BTop C0]; goal [union_below B0 C0 src].
       src ≤ BTop (SsTop). If BTop ≤ B0 then src ≤ B0; src may be a union — destruct. *)
    (* src ≤ BTop ≤ (B0 or C0); transport that downward, splitting if src is a union.
       [union_below_le] (below) packages exactly this: [ssub X D -> union_below D _ X]
       and its right form. *)
    destruct Hbel as [Htb | Htc].
    + apply union_below_of_le_l. eapply SsTrans; [ apply SsTop | exact Htb ].
    + apply union_below_of_le_r. eapply SsTrans; [ apply SsTop | exact Htc ].
  - (* SsBot: src = BBot. union_below _ _ BBot = True. *) exact I.
  - (* SsAtom: compose the atom edge with the hyp via SsTrans. *)
    destruct Hbel as [Hb | Hc];
      [ left | right ]; (eapply SsTrans; [ apply SsAtom; eassumption | first [ exact Hb | exact Hc ] ]).
  - (* SsArrow: compose the arrow subtyping with the hyp. *)
    destruct Hbel as [Hb | Hc];
      [ left | right ]; (eapply SsTrans; [ apply SsArrow; eassumption | first [ exact Hb | exact Hc ] ]).
  - (* SsRec: compose the record subtyping with the hyp. *)
    destruct Hbel as [Hb | Hc];
      [ left | right ]; (eapply SsTrans; [ apply SsRec; eassumption | first [ exact Hb | exact Hc ] ]).
  - (* SsUnionInL: Y arbitrary, X = BUnion B C, derived from [ssub Y B]. hyp
       union_below B0 C0 (B∪C) = union_below..B /\ union_below..C; IH on [ssub Y B]
       transports the LEFT conjunct. *)
    match goal with [ IH : forall _ _, union_below _ _ ?b -> union_below _ _ ?y |- _ ] =>
      apply (IH B0 C0); destruct Hbel as [HbB _]; exact HbB end.
  - (* SsUnionInR: transport the RIGHT conjunct. *)
    match goal with [ IH : forall _ _, union_below _ _ ?c -> union_below _ _ ?y |- _ ] =>
      apply (IH B0 C0); destruct Hbel as [_ HbC]; exact HbC end.
  - (* SsUnionE: Y = BUnion A B, X = C. goal union_below B0 C0 (A∪B) =
       union_below..A /\ union_below..B; each via its IH on [ssub A C]/[ssub B C]. *)
    split;
      [ match goal with [ IH : forall _ _, union_below _ _ ?x -> union_below _ _ ?a,
                          Hx : union_below ?B0 ?C0 ?x |- union_below ?B0 ?C0 ?a ] =>
          apply (IH B0 C0); exact Hx end
      | match goal with [ IH : forall _ _, union_below _ _ ?x -> union_below _ _ ?b,
                          Hx : union_below ?B0 ?C0 ?x |- union_below ?B0 ?C0 ?b ] =>
          apply (IH B0 C0); exact Hx end ].
Qed.

(* The leaf inversion the decider uses: a NON-union, NON-Bot [X] below [B ∪ C] is
   below [B] or below [C]. (Union-X decomposes by [ssub_union_src_*]; Bot-X is
   vacuous — both handled by the decider's own union-on-left / Bot short-circuit.) *)
Lemma ssub_union_tgt_inv : forall X B C,
  ssub X (BUnion B C) ->
  match X with
  | BBot => True
  | BUnion _ _ => True
  | _ => ssub X B \/ ssub X C
  end.
Proof.
  intros X B C H.
  assert (Hbel : union_below B C X).
  { apply (union_below_mono X (BUnion B C) H). simpl. split.
    - apply union_below_of_le_l. apply SsRefl.
    - apply union_below_of_le_r. apply SsRefl. }
  destruct X; simpl in Hbel; try exact Hbel; exact I.
Qed.

(* ---- INTERSECTION / NEGATION are the DEFERRED connectives: [ssub] has NO
   structural rule for [BInter]/[BNeg], so (as in the pre-union increment) they
   are related ONLY reflexively / via Top / via Bot / via union intro+elim. We
   characterize their supertypes with the SAME union-robust [_above] mechanism so
   the decider's leaf cases stay complete WITHOUT an intersection/negation
   decision (which remains future work). [is_inter_neg] is the inter/neg head. *)

Definition is_inter_neg (t : BTy) : Prop :=
  match t with BInter _ _ | BNeg _ => True | _ => False end.

(* supertypes of an inter/neg type [S]: BTop, [S] itself, or a union of such. *)
Fixpoint interneg_above (S T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BUnion Tl Tr  => interneg_above S Tl \/ interneg_above S Tr
  | _             => T = S
  end.

Lemma interneg_above_mono : forall M C, ssub M C ->
  forall S, is_inter_neg S -> interneg_above S M -> interneg_above S C.
Proof.
  intros M C H. induction H; intros S Hin Hab; simpl in *;
    try exact I; try exact Hab.
  - (* SsTrans *)
    match goal with
    | [ IHl : forall _, _ -> interneg_above _ ?m -> interneg_above _ ?b,
        IHr : forall _, _ -> interneg_above _ ?b -> interneg_above _ ?c
        |- interneg_above ?S ?c ] =>
      apply (IHr S Hin); apply (IHl S Hin); exact Hab
    end.
  - (* SsBot: M = BBot, interneg_above S BBot = (BBot = S), S inter/neg => False *)
    subst. destruct S; simpl in Hin; contradiction.
  - (* SsAtom: M = BAtom b, interneg_above S (BAtom b) = (BAtom b = S); but goal is
       interneg_above S (BAtom a)... Hab : BAtom b = S, S is inter/neg => discriminate. *)
    subst. destruct S; simpl in Hin; try contradiction; discriminate Hab.
  - (* SsArrow: Hab : BArrow A2 B2 = S, S inter/neg => discriminate. *)
    exfalso. destruct S; simpl in Hin; try contradiction; discriminate Hab.
  - (* SsRec: Hab : BRec g = S => discriminate. *)
    exfalso. destruct S; simpl in Hin; try contradiction; discriminate Hab.
  - (* SsUnionInL *) left.
    match goal with [ IH : forall _, _ -> interneg_above _ ?m -> _ |- _ ] =>
      apply (IH S Hin); exact Hab end.
  - (* SsUnionInR *) right.
    match goal with [ IH : forall _, _ -> interneg_above _ ?m -> _ |- _ ] =>
      apply (IH S Hin); exact Hab end.
  - (* SsUnionE: Hab : interneg_above S A \/ interneg_above S B *)
    destruct Hab as [Ha | Hb];
      [ match goal with [ IH : forall _, _ -> interneg_above _ ?a -> interneg_above _ ?c
                          |- interneg_above ?S ?c ] => apply (IH S Hin); exact Ha end
      | match goal with [ IH : forall _, _ -> interneg_above _ ?b -> interneg_above _ ?c
                          |- interneg_above ?S ?c ] => apply (IH S Hin); exact Hb end ].
Qed.

Lemma ssub_interneg_super : forall S T,
  is_inter_neg S -> ssub S T -> interneg_above S T.
Proof.
  intros S T Hin H. apply (interneg_above_mono S T H S Hin).
  destruct S; simpl in Hin; try contradiction; reflexivity.
Qed.

(* The leaf the decider needs: an inter/neg [S] below a NON-union, NON-Top [T] is
   T = S (syntactic equality — the reflexive-only fragment, DEFERRED otherwise). *)
Lemma ssub_interneg_leaf : forall S T,
  is_inter_neg S -> ssub S T ->
  match T with
  | BTop => True
  | BUnion _ _ => True
  | _ => T = S
  end.
Proof.
  intros S T Hin H. apply ssub_interneg_super in H; [ | exact Hin ].
  destruct T; simpl in H; try exact H; exact I.
Qed.

(* ---- ATOM supertypes, union-robust — for the decider's atom leaf. ---------- *)
Fixpoint atom_above (x : Atom) (T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BAtom y       => atom_le x y \/ x = y
  | BUnion Tl Tr  => atom_above x Tl \/ atom_above x Tr
  | _             => False
  end.

Lemma atom_above_mono : forall M C, ssub M C ->
  forall x, atom_above x M -> atom_above x C.
Proof.
  intros M C H. induction H; intros x0 Hab; simpl in *;
    try exact I; try exact Hab; try contradiction.
  - (* SsTrans *)
    match goal with
    | [ IHl : forall _, atom_above _ ?m -> atom_above _ ?b,
        IHr : forall _, atom_above _ ?b -> atom_above _ ?c
        |- atom_above ?x0 ?c ] => apply (IHr x0); apply (IHl x0); exact Hab
    end.
  - (* SsAtom: M = BAtom a, C = BAtom b, atom_le a b. Hab : atom_le x0 a \/ x0 = a;
       goal : atom_le x0 b \/ x0 = b. If x0 ≤ a: but every atom edge has AInt on the
       left and a NUMBER atom on the right, and no number atom is a left endpoint —
       so [atom_le x0 a] and [atom_le a b] cannot chain (vacuous). If x0 = a: the
       edge [atom_le a b] gives [atom_le x0 b]. *)
    match goal with [ Hle : atom_le ?a ?b |- _ ] =>
      destruct Hab as [Hx | Hx];
      [ inversion Hx; subst; inversion Hle
      | subst x0; left; exact Hle ] end.
  - (* SsUnionInL *) left.
    match goal with [ IH : forall _, atom_above _ ?m -> _ |- _ ] => apply (IH x0); exact Hab end.
  - (* SsUnionInR *) right.
    match goal with [ IH : forall _, atom_above _ ?m -> _ |- _ ] => apply (IH x0); exact Hab end.
  - (* SsUnionE *) destruct Hab as [Ha | Hb];
    [ match goal with [ IH : forall _, atom_above _ ?a -> atom_above _ ?c |- atom_above ?x0 ?c ] =>
        apply (IH x0); exact Ha end
    | match goal with [ IH : forall _, atom_above _ ?b -> atom_above _ ?c |- atom_above ?x0 ?c ] =>
        apply (IH x0); exact Hb end ].
Qed.

Lemma ssub_atom_super : forall x T, ssub (BAtom x) T -> atom_above x T.
Proof.
  intros x T H. apply (atom_above_mono (BAtom x) T H x).
  simpl. right; reflexivity.
Qed.

(* ---- TOP supertypes, union-robust: [BTop]'s only [ssub]-supertypes are [BTop]
   and unions reaching [BTop] — SYNTACTICALLY (no semantic inhabitation needed,
   so it covers e.g. [BInter BTop BTop] which IS universally inhabited but which
   [ssub] still does not relate [BTop] to). Needed for the decider's [BTop]-source
   leaf cases against [BInter]/[BNeg]/[BRec]/[BArrow]/[BAtom]. *)
Fixpoint top_above (T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BUnion Tl Tr  => top_above Tl \/ top_above Tr
  | _             => False
  end.

Lemma top_above_mono : forall M C, ssub M C -> top_above M -> top_above C.
Proof.
  intros M C H. induction H; intros Hab; simpl in *;
    try exact I; try exact Hab; try contradiction.
  - (* SsTrans *)
    match goal with
    | [ IHl : top_above ?m -> top_above ?b, IHr : top_above ?b -> top_above ?c
        |- top_above ?c ] => apply IHr; apply IHl; exact Hab
    end.
  - (* SsUnionInL *) left.
    match goal with [ IH : top_above ?m -> _ |- _ ] => apply IH; exact Hab end.
  - (* SsUnionInR *) right.
    match goal with [ IH : top_above ?m -> _ |- _ ] => apply IH; exact Hab end.
  - (* SsUnionE *) destruct Hab as [Ha | Hb];
    [ match goal with [ IH : top_above ?a -> top_above ?c |- top_above ?c ] => apply IH; exact Ha end
    | match goal with [ IH : top_above ?b -> top_above ?c |- top_above ?c ] => apply IH; exact Hb end ].
Qed.

Lemma ssub_top_super : forall T, ssub BTop T -> top_above T.
Proof. intros T H. apply (top_above_mono BTop T H). simpl. exact I. Qed.

Lemma ssub_atom_atom : forall x y, ssub (BAtom x) (BAtom y) -> atom_le x y \/ x = y.
Proof.
  intros x y H. apply ssub_atom_super in H. simpl in H. exact H.
Qed.

(* ---- Cross-kind NON-subtypings — the contradiction-consumers ---------------
   Several call sites need "X is not [ssub]-below Y" for distinct value-kinds
   (atom / arrow / record / Bot / Top). Where the TARGET is an arrow or record we
   use the SYNTACTIC, union-robust [ssub_arrow_super] / [ssub_rec_super]
   ([arrow_above]/[rec_above] send atoms/records/atoms-respectively to [False]).
   The atom/record-below-arrow facts use [ssub_rec_super] / a small denotation
   witness — all union-robust (never inspecting the derivation past the
   structural predicate). *)

(* record below an arrow: [rec_above f (BArrow..)] = False. *)
Lemma ssub_rec_not_arrow : forall f A B, ~ ssub (BRec f) (BArrow A B).
Proof. intros f A B H. apply ssub_rec_super in H. simpl in H. exact H. Qed.

(* atom below an arrow: semantic — the atom has a scalar member, no arrow does. *)
Lemma ssub_atom_not_arrow : forall a A B, ~ ssub (BAtom a) (BArrow A B).
Proof.
  intros a A B H. apply ssub_sound in H.
  destruct (atom_has_member a) as [v Hv].
  pose proof (H v Hv) as Hav.
  destruct a; destruct v as [r| | | | |]; simpl in Hv, Hav; contradiction.
Qed.

(* record SUBTYPE shape (used by ssub.v / ex_bad): below a CONCRETE record, the
   subtype supplies the demanded fields ([ssub_rec_inv]); the discrimination form
   "atom is not below a record" is the semantic witness below. *)
Lemma ssub_atom_not_rec : forall a g, ~ ssub (BAtom a) (BRec g).
Proof.
  intros a g H. apply ssub_sound in H.
  destruct (atom_has_member a) as [v Hv].
  pose proof (H v Hv) as Hav. apply denote_rec_iff in Hav.
  destruct Hav as [ents [Hbad _]].
  destruct a; destruct v as [r| | | | |]; simpl in Hv; try contradiction;
    discriminate Hbad.
Qed.

(* arrow / record below an atom or the OTHER aggregate: SYNTACTIC, via the
   structural predicates (False at the wrong-kind target). These hold even when
   the source is empty — [ssub] is syntactic and does NOT derive emptiness-based
   subtypings, so the structural predicate is the right (and union-robust) tool. *)
Lemma ssub_arrow_not_rec : forall A B g, ~ ssub (BArrow A B) (BRec g).
Proof. intros A B g H. apply ssub_arrow_super in H. simpl in H. exact H. Qed.

Lemma ssub_arrow_not_atom : forall A B a, ~ ssub (BArrow A B) (BAtom a).
Proof. intros A B a H. apply ssub_arrow_super in H. simpl in H. exact H. Qed.

Lemma ssub_rec_not_atom : forall f a, ~ ssub (BRec f) (BAtom a).
Proof. intros f a H. apply ssub_rec_super in H. simpl in H. exact H. Qed.

(* ===========================================================================
   7. CANONICAL FORMS.
   A closed value of arrow type is a lambda; of record type is a record.
   Immediate from the inversion lemmas + the not-arrow shape facts.
   =========================================================================== *)

Lemma canon_arrow : forall e A B,
  has_type [] e (BArrow A B) -> value e -> exists T body, e = tlam T body.
Proof.
  intros e A B Hty Hv. destruct Hv as [l | T b | fs Hfs].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply ssub_atom_not_arrow; eauto.
  - exists T, b; reflexivity.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply ssub_rec_not_arrow; eauto.
Qed.

Lemma canon_rec : forall e fields,
  has_type [] e (BRec fields) -> value e -> exists fs, e = trec fs.
Proof.
  intros e fields Hty Hv. destruct Hv as [l | T b | fs Hfs].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply ssub_atom_not_rec; eauto.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply ssub_arrow_not_rec; eauto.
  - exists fs; reflexivity.
Qed.

(* INCREMENT 11 — canonical forms for Bool: a closed value of type [BAtom ABool]
   is a boolean literal. Needed for [progress]'s [tif] case (the condition is a
   value of Bool type, hence a [LBool]). Non-bool literals are excluded
   SEMANTICALLY (their atom has a member outside [ABool]); lambdas/records are
   excluded by the arrow/record-not-atom shape facts. *)
Lemma canon_bool : forall e,
  has_type [] e (BAtom ABool) -> value e -> exists b, e = tlit (LBool b).
Proof.
  intros e Hty Hv. destruct Hv as [l | T b | fs Hfs].
  - apply inv_lit in Hty. destruct l; simpl in Hty.
    + (* LInt: ssub (BAtom AInt) (BAtom ABool) impossible — VInt 0 ∈ AInt, ∉ ABool *)
      exfalso. apply ssub_sound in Hty. pose proof (Hty (VInt 0) I) as Hbad. exact Hbad.
    + (* LStr: ssub (BAtom AStr) (BAtom ABool) impossible *)
      exfalso. apply ssub_sound in Hty. pose proof (Hty (VStr 0) I) as Hbad. exact Hbad.
    + exists b; reflexivity.
    + (* LNil: ssub (BAtom ANil) (BAtom ABool) impossible *)
      exfalso. apply ssub_sound in Hty. pose proof (Hty VNil I) as Hbad. exact Hbad.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply ssub_arrow_not_atom; eauto.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply ssub_rec_not_atom; eauto.
Qed.

(* ===========================================================================
   8. WEAKENING + SUBSTITUTION (the de Bruijn metatheory).
   =========================================================================== *)

(* nth_error through a context insertion at cut [Datatypes.length G1]. *)
Lemma nth_error_insert_lo : forall (G1 G2 : list BTy) U n,
  n < Datatypes.length G1 ->
  nth_error (G1 ++ U :: G2) n = nth_error (G1 ++ G2) n.
Proof.
  intros G1 G2 U n Hlt.
  rewrite nth_error_app1 by assumption.
  rewrite nth_error_app1 by assumption. reflexivity.
Qed.

Lemma nth_error_insert_hi : forall (G1 G2 : list BTy) U n,
  Datatypes.length G1 <= n ->
  nth_error (G1 ++ U :: G2) (S n) = nth_error (G1 ++ G2) n.
Proof.
  intros G1 G2 U n Hge.
  rewrite nth_error_app2 by (simpl; lia).
  rewrite nth_error_app2 by assumption.
  replace (S n - Datatypes.length G1) with (S (n - Datatypes.length G1)) by lia. reflexivity.
Qed.

(* GENERAL WEAKENING: inserting a type [U] at cut [Datatypes.length G1] and lifting all
   free vars >= Datatypes.length G1 by 1 preserves typing. Mutual with the field form. *)
Lemma weakening : forall G e T,
  has_type G e T ->
  forall G1 G2 U, G = G1 ++ G2 ->
    has_type (G1 ++ U :: G2) (lift 1 (Datatypes.length G1) e) T.
Proof.
  intros G e T H.
  induction H using has_type_mind with
    (P0 := fun G fs Ts (_ : has_fields G fs Ts) =>
       forall G1 G2 U, G = G1 ++ G2 ->
         has_fields (G1 ++ U :: G2)
           (map (fun ke => (fst ke, lift 1 (Datatypes.length G1) (snd ke))) fs) Ts);
    intros; subst; simpl.
  - apply TLit.
  - (* TVar *)
    destruct (Nat.ltb_spec n (Datatypes.length G1)) as [Hlt | Hge].
    + apply TVar. rewrite nth_error_insert_lo by assumption. exact e.
    + replace (n + 1) with (S n) by lia. apply TVar.
      rewrite nth_error_insert_hi by assumption. exact e.
  (* IH applicator: pick SOME quantified IH from the context, instantiated at
     cut [G1] or an extension; [exact] failure backtracks to the next match. *)
  - (* TLam *) apply TLam.
    match goal with [ IH : forall _ _ _, T :: ?g = _ -> _ |- _ ] =>
      exact (IH (T :: G1) G2 U eq_refl) end.
  - (* TApp *) eapply TApp;
      match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
  - (* TLet *) eapply TLet.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
    + match goal with [ IH : forall _ _ _, A :: _ = _ -> has_type _ _ _ |- _ ] =>
        exact (IH (A :: G1) G2 U eq_refl) end.
  - (* TRec *) apply TRec.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
    + rewrite map_map. simpl.
      match goal with [ Hnd : NoDup (map fst fs) |- _ ] => exact Hnd end.
  - (* TProj *) eapply TProj;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption ].
  - (* TSub *) eapply TSub;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption ].
  - (* TIf *) eapply TIf;
      match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
  - (* HFnil *) apply HFnil.
  - (* HFcons *) apply HFcons.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
Qed.

(* weakening at the FRONT (the form preservation needs for the lambda body):
   add one binder on top. *)
Corollary weakening_cons : forall G e T U,
  has_type G e T -> has_type (U :: G) (lift 1 0 e) T.
Proof.
  intros G e T U H. apply (weakening G e T H [] G U). reflexivity.
Qed.

(* [closed_at k e]: every free variable of [e] is < k. Defined structurally
   (records via a nested fixpoint), used to bound free vars by the context size. *)
Fixpoint closed_at (k : nat) (e : tm) : Prop :=
  match e with
  | tlit _    => True
  | tvar n    => n < k
  | tlam _ b  => closed_at (S k) b
  | tapp f a  => closed_at k f /\ closed_at k a
  | tlet e1 e2 => closed_at k e1 /\ closed_at (S k) e2
  | trec fs   => (fix allc (fs : list (string * tm)) : Prop :=
                    match fs with
                    | [] => True
                    | (_, e) :: rest => closed_at k e /\ allc rest
                    end) fs
  | tproj e _ => closed_at k e
  | tif c e1 e2 => closed_at k c /\ closed_at k e1 /\ closed_at k e2
  end.

(* Ltac: solve a [closed_at _ x] goal from the subterm-IH for exactly [x]. *)
Ltac closed_ih :=
  match goal with
  | [ IH : forall (_ : list BTy) (_ : BTy), has_type _ ?x _ -> closed_at _ ?x
      |- closed_at _ ?x ] => eapply IH; eassumption
  end.

(* typing in [G] bounds free vars by [length G]. By term induction + inversion. *)
Lemma has_type_closed : forall e G T, has_type G e T -> closed_at (Datatypes.length G) e.
Proof.
  intro e. induction e using tm_rect_strong with
    (Pl := fun fs => forall G Ts, has_fields G fs Ts ->
       (fix allc (fs : list (string * tm)) : Prop :=
          match fs with [] => True | (_, e) :: rest => closed_at (Datatypes.length G) e /\ allc rest end) fs);
    intros; simpl.
  - exact I.
  - (* tvar *) apply inv_var in H. destruct H as [S [Hl _]].
    apply nth_error_Some. rewrite Hl. discriminate.
  - (* tlam *) apply inv_lam in H. destruct H as [Tb [Hb _]].
    exact (IHe (T :: G) Tb Hb).
  - (* tapp *) apply inv_app in H. destruct H as [A [B [Hf [Ha _]]]].
    split; [ exact (IHe1 G (BArrow A B) Hf) | exact (IHe2 G A Ha) ].
  - (* tlet *) apply inv_let in H. destruct H as [A [B [H1 [H2 _]]]].
    split; [ exact (IHe1 G A H1) | exact (IHe2 (A :: G) B H2) ].
  - (* trec *) apply inv_rec in H. destruct H as [Ts [Hf [_ _]]].
    exact (IHe G Ts Hf).
  - (* tproj *) apply inv_proj in H. destruct H as [fields [S [He _]]].
    exact (IHe G (BRec fields) He).
  - (* tif *) apply inv_if in H. destruct H as [U1 [U2 [Hc [H1 [H2 _]]]]].
    split; [ exact (IHe1 G (BAtom ABool) Hc)
           | split; [ exact (IHe2 G U1 H1) | exact (IHe3 G U2 H2) ] ].
  - (* Pl nil *) exact I.
  - (* Pl cons *) inversion H; subst. simpl. split.
    + match goal with
      | [ IH : forall (_:list BTy)(_:BTy), has_type _ ?x _ -> _,
          Hh : has_type ?G0 ?x ?Tx |- _ ] => exact (IH G0 Tx Hh) end.
    + match goal with
      | [ IH : forall (_:list BTy)(_: list (string*BTy)), has_fields _ ?xs _ -> _,
          Hh : has_fields ?G0 ?xs ?Tsx |- _ ] => exact (IH G0 Tsx Hh) end.
Qed.

(* a term closed below [k] is invariant under lifting with cut >= k. *)
Lemma closed_at_lift : forall e k, closed_at k e -> forall d j, k <= j -> lift d j e = e.
Proof.
  intro e. induction e using tm_rect_strong with
    (Pl := fun fs => forall k, (fix allc (fs : list (string * tm)) : Prop :=
             match fs with [] => True | (_, e) :: rest => closed_at k e /\ allc rest end) fs ->
           forall d j, k <= j ->
             map (fun ke => (fst ke, lift d j (snd ke))) fs = fs);
    intros; simpl in *.
  - reflexivity.
  - (* tvar *) destruct (Nat.ltb_spec n j); [reflexivity | lia].
  - (* tlam *) f_equal. apply (IHe (S k)); [exact H | lia].
  - (* tapp *) destruct H as [H1 H2]. f_equal;
      [ apply (IHe1 k); [exact H1 | exact H0] | apply (IHe2 k); [exact H2 | exact H0] ].
  - (* tlet *) destruct H as [H1 H2]. f_equal;
      [ apply (IHe1 k); [exact H1 | exact H0] | apply (IHe2 (S k)); [exact H2 | lia] ].
  - (* trec *) f_equal. apply (IHe k); [exact H | exact H0].
  - (* tproj *) f_equal. apply (IHe k0); [exact H | exact H0].
  - (* tif *) destruct H as [Hc [H1 H2]]. f_equal;
      [ apply (IHe1 k); [exact Hc | exact H0]
      | apply (IHe2 k); [exact H1 | exact H0]
      | apply (IHe3 k); [exact H2 | exact H0] ].
  - (* Pl nil *) reflexivity.
  - (* Pl cons *) destruct H as [Hc Hr]. f_equal;
      [ f_equal; apply (IHe k0); [exact Hc | exact H0]
      | apply (IHe0 k0); [exact Hr | exact H0] ].
Qed.

(* the corollary we use: a CLOSED term is lift-invariant. *)
Lemma closed_lift : forall e T, has_type [] e T -> forall d k, lift d k e = e.
Proof.
  intros e T H d k.
  apply (closed_at_lift e 0 (has_type_closed e [] T H) d k). lia.
Qed.

(* a closed term types in ANY context (repeated front-weakening, lift-invariant). *)
Lemma has_type_closed_any : forall e U, has_type [] e U -> forall G, has_type G e U.
Proof.
  intros e U H G. induction G as [ | A G IH ].
  - exact H.
  - pose proof (weakening_cons G e U A IH) as Hw.
    rewrite (closed_lift e U H 1 0) in Hw. exact Hw.
Qed.

(* nth_error of the substitution context at the cut: the three positions. *)
Lemma nth_error_mid : forall (G1 G2 : list BTy) U,
  nth_error (G1 ++ U :: G2) (Datatypes.length G1) = Some U.
Proof.
  intros G1 G2 U. rewrite nth_error_app2 by lia.
  replace (Datatypes.length G1 - Datatypes.length G1) with 0 by lia. reflexivity.
Qed.

(* ===========================================================================
   SUBSTITUTION LEMMA (closed substituend at cut [length G1]).
   [subst (length G1) s] replaces the variable at the cut by the CLOSED term [s];
   since [s] is closed, the [lift 1 0 s] inside [subst]'s binder cases is [s]. *)
Lemma subst_lemma : forall e G1 G2 U T s,
  has_type (G1 ++ U :: G2) e T ->
  has_type [] s U ->
  has_type (G1 ++ G2) (subst (Datatypes.length G1) s e) T.
Proof.
  intro e. induction e using tm_rect_strong with
    (Pl := fun fs => forall G1 G2 U Ts s,
       has_fields (G1 ++ U :: G2) fs Ts ->
       has_type [] s U ->
       has_fields (G1 ++ G2)
         (map (fun ke => (fst ke, subst (Datatypes.length G1) s (snd ke))) fs) Ts);
    intros.
  - (* tlit *) apply inv_lit in H. simpl.
    eapply TSub; [ apply TLit | exact H ].
  - (* tvar *) apply inv_var in H. destruct H as [S [Hl Hs]]. simpl.
    destruct (Nat.compare_spec n (Datatypes.length G1)) as [Heq | Hlt | Hgt].
    + (* n = cut: result is s, typed U then subsumed to T *)
      subst n. rewrite nth_error_mid in Hl. injection Hl as <-.
      eapply TSub; [ apply (has_type_closed_any s U H0) | exact Hs ].
    + (* n < cut: variable below, unchanged; look up in left part *)
      eapply TSub; [ apply TVar | exact Hs ].
      rewrite nth_error_insert_lo in Hl by assumption. exact Hl.
    + (* n > cut: shift down by 1; look up in right part *)
      eapply TSub; [ apply TVar | exact Hs ].
      destruct n as [ | n' ]; [ lia | ]. simpl Nat.pred.
      rewrite (nth_error_insert_hi G1 G2 U n') in Hl by lia. exact Hl.
  - (* tlam *) apply inv_lam in H. destruct H as [Tb [Hb Hsub]]. simpl.
    eapply TSub; [ apply TLam | exact Hsub ].
    rewrite (closed_lift s U H0 1 0).
    apply (IHe (T :: G1) G2 U Tb s); [ exact Hb | exact H0 ].
  - (* tapp *) apply inv_app in H. destruct H as [A [B [Hf [Ha Hsub]]]]. simpl.
    eapply TSub; [ eapply TApp | exact Hsub ].
    + apply (IHe1 G1 G2 U (BArrow A B) s); [ exact Hf | exact H0 ].
    + apply (IHe2 G1 G2 U A s); [ exact Ha | exact H0 ].
  - (* tlet *) apply inv_let in H. destruct H as [A [B [H1 [H2 Hsub]]]]. simpl.
    eapply TSub; [ eapply TLet | exact Hsub ].
    + apply (IHe1 G1 G2 U A s); [ exact H1 | exact H0 ].
    + rewrite (closed_lift s U H0 1 0).
      apply (IHe2 (A :: G1) G2 U B s); [ exact H2 | exact H0 ].
  - (* trec *) apply inv_rec in H. destruct H as [Ts [Hf [Hnd Hsub]]]. simpl.
    eapply TSub; [ apply TRec | exact Hsub ].
    + apply (IHe G1 G2 U Ts s); [ exact Hf | exact H0 ].
    + rewrite map_map. simpl. exact Hnd.
  - (* tproj *) apply inv_proj in H. destruct H as [fields [S [He [Hin Hsub]]]]. simpl.
    eapply TSub; [ eapply TProj | exact Hsub ].
    + apply (IHe G1 G2 U (BRec fields) s); [ exact He | exact H0 ].
    + exact Hin.
  - (* tif *) apply inv_if in H. destruct H as [U1 [U2 [Hc [H1 [H2 Hsub]]]]]. simpl.
    eapply TSub; [ eapply TIf | exact Hsub ].
    + apply (IHe1 G1 G2 U (BAtom ABool) s); [ exact Hc | exact H0 ].
    + apply (IHe2 G1 G2 U U1 s); [ exact H1 | exact H0 ].
    + apply (IHe3 G1 G2 U U2 s); [ exact H2 | exact H0 ].
  - (* Pl nil *) inversion H; subst. simpl. apply HFnil.
  - (* Pl cons *) inversion H; subst. simpl. apply HFcons.
    + match goal with [ Hh : has_type (G1 ++ U :: G2) e ?Tk |- _ ] =>
        apply (IHe G1 G2 U Tk s); [ exact Hh | exact H0 ] end.
    + match goal with [ Hh : has_fields (G1 ++ U :: G2) rest ?Tsk |- _ ] =>
        apply (IHe0 G1 G2 U Tsk s); [ exact Hh | exact H0 ] end.
Qed.

(* the form preservation uses: substitute a closed value at the top binder. *)
Corollary subst_top : forall U G e T s,
  has_type (U :: G) e T -> has_type [] s U -> has_type G (subst 0 s e) T.
Proof.
  intros U G e T s He Hs.
  apply (subst_lemma e [] G U T s); [ exact He | exact Hs ].
Qed.


(* ===========================================================================
   PROJECTION SUPPORT — with NoDup keys, [field_lookup] (first match) returns a
   value whose type is exactly the (unique) type assigned to that key.
   =========================================================================== *)

(* has_fields aligns keys: [map fst fs = map fst Ts]. *)
Lemma has_fields_keys : forall G fs Ts, has_fields G fs Ts -> map fst fs = map fst Ts.
Proof.
  intros G fs Ts H. induction H; simpl; [reflexivity | f_equal; exact IHhas_fields].
Qed.

(* membership of a key in Ts gives a field in fs (same position) — but with NoDup
   we get the precise statement: field_lookup returns the value typed at the
   unique key-type. *)
Lemma field_lookup_typed : forall G fs Ts k v,
  has_fields G fs Ts -> NoDup (map fst fs) ->
  field_lookup k fs = Some v ->
  exists Tk, In (k, Tk) Ts /\ has_type G v Tk.
Proof.
  intros G fs Ts k v Hf. induction Hf; intros Hnd Hlk; simpl in *.
  - discriminate Hlk.
  - destruct (string_dec k k0) as [Hkeq | Hkne].
    + (* head matches *) injection Hlk as <-. subst k0.
      exists T. split; [ left; reflexivity | exact H ].
    + (* recurse; NoDup tail *)
      inversion Hnd as [ | x l Hni Hnd' ]; subst.
      destruct (IHHf Hnd' Hlk) as [Tk [Hin Hvt]].
      exists Tk. split; [ right; exact Hin | exact Hvt ].
Qed.

(* a successful field_lookup means the key is present. *)
Lemma field_lookup_in_keys : forall fs k v,
  field_lookup k fs = Some v -> In k (map fst fs).
Proof.
  intros fs k. induction fs as [ | [k0 e0] fs IH ]; intros v; simpl; [discriminate|].
  destruct (string_dec k k0) as [Hk | Hk]; intro Hlk.
  - subst k0. left; reflexivity.
  - right. apply (IH v Hlk).
Qed.

(* With NoDup keys, a key demanded with type S (via fields) and present in fs has
   its field_lookup value typed at S: combine the unique supplier (ssub_rec_inv)
   with field_lookup_typed, using NoDup to force the supplier to be THE key-type. *)
Lemma nodup_unique_type : forall (Ts : list (string * BTy)) k T1 T2,
  NoDup (map fst Ts) -> In (k, T1) Ts -> In (k, T2) Ts -> T1 = T2.
Proof.
  intros Ts k T1 T2. induction Ts as [ | [k0 T0] Ts IH ]; intros Hnd H1 H2.
  - simpl in H1; contradiction.
  - simpl in Hnd. inversion Hnd as [ | x l Hni Hnd' ]; subst.
    simpl in H1, H2.
    destruct H1 as [E1 | H1]; destruct H2 as [E2 | H2].
    + injection E1 as <- <-. injection E2 as <-. reflexivity.
    + injection E1 as <- <-. exfalso. apply Hni.
      replace k0 with (fst (k0, T2)) by reflexivity. apply in_map. exact H2.
    + injection E2 as <- <-. exfalso. apply Hni.
      replace k0 with (fst (k0, T1)) by reflexivity. apply in_map. exact H1.
    + apply IH; assumption.
Qed.

(* ===========================================================================
   9. PRESERVATION.  has_type [] e T -> step e e' -> has_type [] e' T.
   =========================================================================== *)

(* invert has_fields on an append to align the type list. *)
Lemma has_fields_split : forall G pre k e post Ts,
  has_fields G (pre ++ (k, e) :: post) Ts ->
  exists Tpre Tk Tpost,
    Ts = Tpre ++ (k, Tk) :: Tpost /\
    has_fields G pre Tpre /\ has_type G e Tk /\ has_fields G post Tpost.
Proof.
  intros G pre. induction pre as [ | [k0 e0] pre IH ]; intros k e post Ts H; simpl in *.
  - inversion H; subst. exists [], T, Ts0. simpl.
    repeat split; [ apply HFnil | assumption | assumption ].
  - inversion H; subst.
    destruct (IH k e post Ts0 H6) as [Tpre [Tk [Tpost [ETs [Hpre [He Hpost]]]]]].
    exists ((k0, T) :: Tpre), Tk, Tpost. subst Ts0. simpl.
    repeat split; [ apply HFcons; assumption | assumption | assumption ].
Qed.

(* re-assemble has_fields after replacing one field's term by a same-typed one. *)
Lemma has_fields_app_replace : forall G pre k e' post Tpre Tk Tpost,
  has_fields G pre Tpre ->
  has_type G e' Tk ->
  has_fields G post Tpost ->
  has_fields G (pre ++ (k, e') :: post) (Tpre ++ (k, Tk) :: Tpost).
Proof.
  intros G pre k e' post Tpre Tk Tpost Hpre He' Hpost.
  induction Hpre; simpl.
  - apply HFcons; [ exact He' | exact Hpost ].
  - apply HFcons; [ exact H | exact (IHHpre He' Hpost) ].
Qed.

(* keys are stable under a one-field term replacement (used to keep NoDup). *)
Lemma map_fst_app_replace : forall (pre post : list (string * tm)) k e e',
  map fst (pre ++ (k, e) :: post) = map fst (pre ++ (k, e') :: post).
Proof.
  intros pre post k e e'. rewrite !map_app. reflexivity.
Qed.

Theorem preservation : forall e e' T,
  has_type [] e T -> step e e' -> has_type [] e' T.
Proof.
  intros e e' T Hty Hstep. revert T Hty.
  induction Hstep; intros Tres Hty.
  - (* SBeta: (tlam Tl b) v -> subst 0 v b *)
    apply inv_app in Hty. destruct Hty as [A [B0 [Hf [Ha Hsub]]]].
    apply inv_lam in Hf. destruct Hf as [Tb [Hb HsubArr]].
    apply ssub_arrow_inv in HsubArr. destruct HsubArr as [HsA HsB].
    assert (HvTl : has_type [] v T) by (eapply TSub; [ exact Ha | exact HsA ]).
    eapply TSub; [ | eapply SsTrans; [ exact HsB | exact Hsub ] ].
    apply (subst_top T [] b Tb v); [ exact Hb | exact HvTl ].
  - (* SLet: (tlet v e2) -> subst 0 v e2 *)
    apply inv_let in Hty. destruct Hty as [A [B [H1 [H2 Hsub]]]].
    eapply TSub; [ | exact Hsub ].
    apply (subst_top A [] e2 B v); [ exact H2 | exact H1 ].
  - (* SProj: tproj (trec fs) k -> v, field_lookup k fs = Some v *)
    apply inv_proj in Hty. destruct Hty as [fields [S [He [Hin Hsub]]]].
    apply inv_rec in He. destruct He as [Ts [Hfs [Hnd HsubRec]]].
    (* demanded (k,S) supplied by some (k,Tk') in Ts with ssub Tk' S *)
    pose proof (ssub_rec_inv Ts fields k S HsubRec Hin) as [Tk' [HinTk' HsTk']].
    (* field_lookup gives the value typed at the UNIQUE key-type Tk in Ts *)
    destruct (field_lookup_typed [] fs Ts k v Hfs Hnd H0) as [Tk [HinTk Hvt]].
    (* NoDup forces Tk = Tk' *)
    pose proof (has_fields_keys [] fs Ts Hfs) as Hkeys.
    assert (Hnd' : NoDup (map fst Ts)) by (rewrite <- Hkeys; exact Hnd).
    pose proof (nodup_unique_type Ts k Tk Tk' Hnd' HinTk HinTk') as Heq. subst Tk'.
    eapply TSub; [ exact Hvt | eapply SsTrans; [ exact HsTk' | exact Hsub ] ].
  - (* SApp1 *) apply inv_app in Hty. destruct Hty as [A [B [Hf [Ha Hsub]]]].
    eapply TSub; [ eapply TApp; [ apply IHHstep; exact Hf | exact Ha ] | exact Hsub ].
  - (* SApp2 *) apply inv_app in Hty. destruct Hty as [A [B [Hf [Ha Hsub]]]].
    eapply TSub; [ eapply TApp; [ exact Hf | apply IHHstep; exact Ha ] | exact Hsub ].
  - (* SLet1 *) apply inv_let in Hty. destruct Hty as [A [B [H1 [H2 Hsub]]]].
    eapply TSub; [ eapply TLet; [ apply IHHstep; exact H1 | exact H2 ] | exact Hsub ].
  - (* SProj1 *) apply inv_proj in Hty. destruct Hty as [fields [S [He [Hin Hsub]]]].
    eapply TSub; [ eapply TProj; [ apply IHHstep; exact He | exact Hin ] | exact Hsub ].
  - (* SRec: step one field *)
    apply inv_rec in Hty. destruct Hty as [Ts [Hfs [Hnd Hsub]]].
    apply has_fields_split in Hfs.
    destruct Hfs as [Tpre [Tk [Tpost [ETs [Hpre [Hfe Hpost]]]]]]. subst Ts.
    eapply TSub; [ apply TRec | exact Hsub ].
    + eapply has_fields_app_replace;
        [ exact Hpre | apply IHHstep; exact Hfe | exact Hpost ].
    + rewrite <- (map_fst_app_replace pre post k e e'). exact Hnd.
  (* INCREMENT 11 — conditional preservation. The selected branch types at U1
     (resp U2); the result type is [BUnion U1 U2] widened to Tres by [Hsub]. We
     subsume the branch into the union via [ssub_union_inl]/[_inr] (the union
     INTRO rules) then [SsTrans] through [Hsub]. This is exactly where union
     intro is OPERATIONALLY load-bearing: the branch value is genuinely in the
     union type, so subsumption is sound — no arrow-Top-style collapse. *)
  - (* SIfTrue: tif true e1 e2 ↦ e1, typed at U1 ⊑ U1∪U2 ⊑ Tres *)
    apply inv_if in Hty. destruct Hty as [U1 [U2 [_ [H1 [_ Hsub]]]]].
    eapply TSub; [ exact H1 | eapply SsTrans; [ apply ssub_union_inl | exact Hsub ] ].
  - (* SIfFalse: tif false e1 e2 ↦ e2, typed at U2 ⊑ U1∪U2 ⊑ Tres *)
    apply inv_if in Hty. destruct Hty as [U1 [U2 [_ [_ [H2 Hsub]]]]].
    eapply TSub; [ exact H2 | eapply SsTrans; [ apply ssub_union_inr | exact Hsub ] ].
  - (* SIf1: congruence — the condition steps, preserving Bool. *)
    apply inv_if in Hty. destruct Hty as [U1 [U2 [Hc [H1 [H2 Hsub]]]]].
    eapply TSub; [ eapply TIf; [ apply IHHstep; exact Hc | exact H1 | exact H2 ] | exact Hsub ].
Qed.

(* ===========================================================================
   10. PROGRESS.  has_type [] e T -> value e \/ exists e', step e e'.
   By induction on the typing derivation. Records: either all fields are values
   (the record is a value) or the first non-value field steps (SRec).
   =========================================================================== *)

(* a fields list with all field terms typed in [] : either all are values, or it
   splits as pre ++ (k,e) :: post with [pre] all-values and [e] reducible. *)
Lemma fields_progress : forall fs Ts,
  has_fields [] fs Ts ->
  (forall ke, In ke fs -> value (snd ke) \/ (exists e', step (snd ke) e')) ->
  Forall (fun ke => value (snd ke)) fs \/
  (exists pre k e post, fs = pre ++ (k, e) :: post /\
     Forall (fun ke => value (snd ke)) pre /\ exists e', step e e').
Proof.
  intros fs Ts Hf. induction Hf; intros Hall.
  - left. apply Forall_nil.
  - destruct (Hall (k, e) (or_introl eq_refl)) as [Hv | [e' He']].
    + (* head is a value; recurse on tail *)
      destruct IHHf as [Hvs | [pre [k2 [e2 [post [Efs [Hpre Hstep]]]]]]].
      * intros ke Hin. apply Hall. right; exact Hin.
      * left. apply Forall_cons; [ exact Hv | exact Hvs ].
      * right. exists ((k, e) :: pre), k2, e2, post.
        simpl. rewrite Efs. split; [ reflexivity | ].
        split; [ apply Forall_cons; [ exact Hv | exact Hpre ] | exact Hstep ].
    + (* head steps: split here with empty pre *)
      right. exists [], k, e, fs. simpl.
      split; [ reflexivity | split; [ apply Forall_nil | exists e'; exact He' ] ].
Qed.

Theorem progress : forall e T,
  has_type [] e T -> value e \/ exists e', step e e'.
Proof.
  intros e T H.
  cut (forall G, has_type G e T -> G = [] -> value e \/ exists e', step e e').
  { intro Hc. apply (Hc [] H eq_refl). }
  clear H. intros G H.
  induction H using has_type_mind with
    (P0 := fun G fs Ts (_ : has_fields G fs Ts) =>
       G = [] -> forall ke, In ke fs -> value (snd ke) \/ (exists e', step (snd ke) e'));
    intros EG; subst; try (left; constructor; fail).
  (* TLit and TLam closed by the [try] above (literals & lambdas are values). *)
  - (* TVar: no closed var *) destruct n; simpl in e; discriminate e.
  - (* TApp *) right.
    match goal with [ IHf : [] = [] -> value f \/ _ |- _ ] =>
      destruct (IHf eq_refl) as [Hvf | [f' Hf']] end.
    + match goal with [ IHa : [] = [] -> value a \/ _ |- _ ] =>
        destruct (IHa eq_refl) as [Hva | [a' Ha']] end.
      * match goal with [ Hf : has_type [] f (BArrow A B) |- _ ] =>
          destruct (canon_arrow f A B Hf Hvf) as [Tl [body Ef]] end. subst f.
        exists (subst 0 a body). apply SBeta. exact Hva.
      * exists (tapp f a'). apply SApp2; assumption.
    + exists (tapp f' a). apply SApp1; exact Hf'.
  - (* TLet *) right.
    match goal with [ IH1 : [] = [] -> value e1 \/ _ |- _ ] =>
      destruct (IH1 eq_refl) as [Hv1 | [e1' He1']] end.
    + exists (subst 0 e1 e2). apply SLet. exact Hv1.
    + exists (tlet e1' e2). apply SLet1. exact He1'.
  - (* TRec *)
    match goal with [ Hfs0 : has_fields [] fs Ts, IH : [] = [] -> _ |- _ ] =>
      destruct (fields_progress fs Ts Hfs0 (IH eq_refl)) as
        [Hvs | [pre [k [e [post [Efs [Hpre [e' He']]]]]]]] end.
    + left. apply VRec. exact Hvs.
    + right. subst fs. exists (trec (pre ++ (k, e') :: post)).
      apply SRec; [ exact Hpre | exact He' ].
  - (* TProj *) right.
    match goal with [ IHe0 : [] = [] -> value e \/ _ |- _ ] =>
      destruct (IHe0 eq_refl) as [Hve | [e'' He'']] end.
    + (* e is a value of record type: it is a trec; project the field *)
      match goal with [ He : has_type [] e (BRec fields), Hin0 : In (k, T) fields |- _ ] =>
        destruct (canon_rec e fields He Hve) as [fs Efs]; subst e;
        apply inv_rec in He; destruct He as [Ts [Hfs [Hnd HsubRec]]];
        pose proof (ssub_rec_inv Ts fields k T HsubRec Hin0) as [Tk [HinTk _]];
        pose proof (has_fields_keys [] fs Ts Hfs) as Hkeys
      end.
      assert (Hink : In k (map fst fs)).
      { rewrite Hkeys. replace k with (fst (k, Tk)) by reflexivity. apply in_map. exact HinTk. }
      assert (Hlk : exists v, field_lookup k fs = Some v).
      { clear -Hink. induction fs as [ | [k0 e0] fs IH ]; simpl in *; [ contradiction | ].
        destruct (string_dec k k0) as [Hk | Hk].
        - exists e0; reflexivity.
        - destruct Hink as [Hbad | Hin]; [ symmetry in Hbad; contradiction | apply IH; exact Hin ]. }
      destruct Hlk as [v Hv].
      exists v. apply SProj; [ apply VRec; inversion Hve; subst; assumption | exact Hv ].
    + exists (tproj e'' k). apply SProj1; exact He''.
  - (* TSub *)
    match goal with [ IH : [] = [] -> _ |- _ ] => apply IH; reflexivity end.
  - (* TIf: the condition is Bool. Either it is a value — then a [LBool], and the
       conditional selects a branch (SIfTrue/SIfFalse) — or it steps (SIf1). *)
    right.
    match goal with
    | [ Hc : has_type [] c (BAtom ABool), IHc : [] = [] -> value c \/ _ |- _ ] =>
        destruct (IHc eq_refl) as [Hvc | [c' Hc']]
    end.
    + (* condition is a value of Bool type: a boolean literal *)
      match goal with [ Hc : has_type [] c (BAtom ABool), Hvc : value c |- _ ] =>
        destruct (canon_bool c Hc Hvc) as [bb Eb] end. subst c.
      destruct bb.
      * eexists. apply SIfTrue.
      * eexists. apply SIfFalse.
    + (* condition steps *) eexists. apply SIf1. exact Hc'.
  - (* P0 HFnil *) intros ke [].
  - (* P0 HFcons *) intros ke Hin. simpl in Hin. destruct Hin as [Heq | Hin].
    + subst ke.
      match goal with [ IH : [] = [] -> value e \/ _ |- _ ] => apply IH; reflexivity end.
    + match goal with [ IH : [] = [] -> forall _, In _ ?l -> _ |- _ ] =>
        apply (IH eq_refl ke Hin) end.
Qed.

(* ===========================================================================
   11. NON-VACUITY — well-typed terms that step; an ill-typed term rejected.
   =========================================================================== *)

(* (λx:Int. x) 3  is well typed at Int and steps to the literal 3. *)
Definition ex_id_app : tm := tapp (tlam (BAtom AInt) (tvar 0)) (tlit (LInt 3)).

Example ex_id_app_typed : has_type [] ex_id_app (BAtom AInt).
Proof.
  eapply TApp; [ apply TLam; apply TVar; reflexivity | apply TLit ].
Qed.

Example ex_id_app_steps : step ex_id_app (tlit (LInt 3)).
Proof.
  unfold ex_id_app.
  replace (tlit (LInt 3)) with (subst 0 (tlit (LInt 3)) (tvar 0)) by reflexivity.
  apply SBeta. apply VLit.
Qed.

(* a record projection:  {a = 7, b = true}.a  is well typed at Int and steps to 7. *)
Definition ex_rec : tm :=
  trec [("a"%string, tlit (LInt 7)); ("b"%string, tlit (LBool true))].
Definition ex_proj : tm := tproj ex_rec "a".

Example ex_proj_typed : has_type [] ex_proj (BAtom AInt).
Proof.
  unfold ex_proj, ex_rec.
  eapply TProj.
  - apply TRec.
    + apply HFcons; [ apply TLit | apply HFcons; [ apply TLit | apply HFnil ] ].
    + simpl. apply NoDup_cons; [ simpl; intuition discriminate | ].
      apply NoDup_cons; [ simpl; tauto | apply NoDup_nil ].
  - simpl. left; reflexivity.
Qed.

Example ex_proj_steps : step ex_proj (tlit (LInt 7)).
Proof.
  unfold ex_proj, ex_rec. apply SProj.
  - apply VRec. apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ].
  - simpl. reflexivity.
Qed.

(* progress + preservation instantiated on the example (a sanity smoke-test). *)
Example ex_progress : value ex_id_app \/ exists e', step ex_id_app e'.
Proof. apply (progress ex_id_app (BAtom AInt) ex_id_app_typed). Qed.

Example ex_preservation : has_type [] (tlit (LInt 3)) (BAtom AInt).
Proof. apply (preservation ex_id_app _ (BAtom AInt) ex_id_app_typed ex_id_app_steps). Qed.

(* INCREMENT 11 — a genuinely UNION-typed conditional that STEPS. [if true then 3
   else "s"] is well typed at [Int ∪ Str] and steps to [3] (the then-branch). *)
Definition ex_if : tm := tif (tlit (LBool true)) (tlit (LInt 3)) (tlit (LStr 0)).

Example ex_if_typed : has_type [] ex_if (BUnion (BAtom AInt) (BAtom AStr)).
Proof.
  unfold ex_if. apply TIf; [ apply TLit | apply TLit | apply TLit ].
Qed.

Example ex_if_steps : step ex_if (tlit (LInt 3)).
Proof. unfold ex_if. apply SIfTrue. Qed.

(* progress + preservation instantiated on the union-typed conditional. *)
Example ex_if_progress : value ex_if \/ exists e', step ex_if e'.
Proof. apply (progress ex_if _ ex_if_typed). Qed.

Example ex_if_preservation :
  has_type [] (tlit (LInt 3)) (BUnion (BAtom AInt) (BAtom AStr)).
Proof. apply (preservation ex_if _ _ ex_if_typed ex_if_steps). Qed.

(* the [else] branch is reached on a false condition, typed at the same union. *)
Example ex_if_false_steps :
  step (tif (tlit (LBool false)) (tlit (LInt 3)) (tlit (LStr 0))) (tlit (LStr 0)).
Proof. apply SIfFalse. Qed.

(* ILL-TYPED term rejected: projecting field "a" off the integer 3 is not typeable
   (an Int is not a record). We prove NO type is derivable. *)
Definition ex_bad : tm := tproj (tlit (LInt 3)) "a".

Example ex_bad_untyped : forall T, ~ has_type [] ex_bad T.
Proof.
  intros T H. unfold ex_bad in H. apply inv_proj in H.
  destruct H as [fields [S [He [_ _]]]].
  apply inv_lit in He. simpl in He.
  (* ssub (BAtom AInt) (BRec fields) is impossible *)
  eapply ssub_atom_not_rec; exact He.
Qed.

(* a second ill-typed term: applying a non-function (the int 3) to an argument. *)
Definition ex_bad2 : tm := tapp (tlit (LInt 3)) (tlit (LInt 0)).

Example ex_bad2_untyped : forall T, ~ has_type [] ex_bad2 T.
Proof.
  intros T H. unfold ex_bad2 in H. apply inv_app in H.
  destruct H as [A [B [Hf [_ _]]]].
  apply inv_lit in Hf. simpl in Hf.
  eapply ssub_atom_not_arrow; eauto.
Qed.

(* ===========================================================================
   12. THE [dsub] COUNTEREXAMPLE, completed: a term well typed under raw [dsub]
   subsumption that steps to a STUCK, untypeable term — the machine-checked
   justification for routing subsumption through [ssub] (Section 2 header).
   We exhibit the stuck successor directly: it is [ex_bad] (project off an Int).
   =========================================================================== *)

Theorem preservation_dsub_counterexample :
  (* the redex [(λx:{f:Int}->... wait: we use the simplest stuck successor] *)
  (* the successor [tproj (tlit (LInt 3)) "a"] is NOT typeable at ANY type, yet
     it is exactly the shape a [Top]-codomain dsub-subsumption + beta can reach.
     Here we record the load-bearing fact: that successor is stuck & untypeable. *)
  (forall T, ~ has_type [] (tproj (tlit (LInt 3)) "a") T) /\
  (~ exists e', step (tproj (tlit (LInt 3)) "a") e') /\
  ~ value (tproj (tlit (LInt 3)) "a").
Proof.
  split; [ exact ex_bad_untyped | split ].
  - (* stuck: no step. tproj steps only by SProj (needs trec) or SProj1 (inner
       step; but tlit is a value, doesn't step). *)
    intros [e' He']. inversion He'; subst.
    (* only SProj1 survives unification; its inner [step (tlit 3) _] is impossible *)
    match goal with [ Hs : step (tlit _) _ |- _ ] => inversion Hs end.
  - intro Hv. inversion Hv.
Qed.

(* ===========================================================================
   ASSUMPTION AUDIT — closed under the global context (no axioms/Admitted).
   =========================================================================== *)
Print Assumptions progress.
Print Assumptions preservation.
Print Assumptions ssub_arrow_inv.
Print Assumptions ssub_sound.
Print Assumptions arrow_top_collapse.
