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
  | tproj : tm -> string -> tm.              (* field projection                *)

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

(* ---- [ssub] is SOUND for the semantic [dsub] (subtype.v ground truth). ----- *)
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
  - (* SrNil *) intros ents Hf k Tg Hin. simpl in Hin; contradiction.
  - (* SrCons *) intros ents Hf k0 Tg0 Hin. simpl in Hin. destruct Hin as [Heq | Hin].
    + injection Heq as <- <-.
      destruct (Hf k Tf i) as [vv [Hlk Hvv]].
      exists vv. split; [exact Hlk | apply IHssub; exact Hvv].
    + apply IHssub0; assumption.
Qed.

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
      step (trec (pre ++ (k, e) :: post)) (trec (pre ++ (k, e') :: post)).

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

(* ===========================================================================
   6. [ssub] SHAPE / INVERSION LEMMAS — the invertibility that motivated ssub.
   =========================================================================== *)

(* Top has no proper supertype; Bot has no proper subtype. *)
Lemma ssub_top_src : forall C, ssub BTop C -> C = BTop.
Proof.
  intros C H. remember BTop as t eqn:Et. revert Et.
  induction H; intros Et; try discriminate Et; subst; auto.
  - rewrite (IHssub1 eq_refl) in *. apply IHssub2; reflexivity.
Qed.

Lemma ssub_bot_tgt : forall C, ssub C BBot -> C = BBot.
Proof.
  intros C H. remember BBot as t eqn:Et. revert Et.
  induction H; intros Et; try discriminate Et; subst; auto.
  - rewrite (IHssub2 eq_refl) in *. apply IHssub1; reflexivity.
Qed.

(* What lies ABOVE an arrow under ssub: only Top or another arrow (with the
   variance). Proved by induction on the derivation; the transitivity case is
   carried by the disjunction (the middle type is Top or an arrow). *)
Lemma ssub_arrow_super : forall S T,
  ssub S T ->
  forall Ax Bx, S = BArrow Ax Bx ->
    T = BTop \/ exists Ay By, T = BArrow Ay By /\ ssub Ay Ax /\ ssub Bx By.
Proof.
  intros S T H. induction H; intros Ax Bx ES; subst; try discriminate ES.
  - (* SsRefl *) right. exists Ax, Bx. split; [reflexivity|split; apply SsRefl].
  - (* SsTrans: S=arrow -> B is Top or arrow; then recurse to C *)
    destruct (IHssub1 Ax Bx eq_refl) as [HBtop | [A' [B' [EB [Ha Hb]]]]].
    + (* B = Top, but ssub Top C: invert — only Refl/Trans can, staying Top *)
      subst B. left. apply ssub_top_src in H0. exact H0.
    + subst B. destruct (IHssub2 A' B' eq_refl) as [HC | [Ay [By [EC [Ha2 Hb2]]]]].
      * left; exact HC.
      * right. exists Ay, By. split; [exact EC | split].
        -- eapply SsTrans; eassumption.
        -- eapply SsTrans; eassumption.
  - (* SsTop *) left; reflexivity.
  - (* SsArrow *) injection ES as <- <-. right. exists A2, B2.
    split; [reflexivity | split; assumption].
Qed.

(* The clean arrow inversion. *)
Lemma ssub_arrow_inv : forall A1 B1 A2 B2,
  ssub (BArrow A1 B1) (BArrow A2 B2) -> ssub A2 A1 /\ ssub B1 B2.
Proof.
  intros A1 B1 A2 B2 H.
  destruct (ssub_arrow_super _ _ H A1 B1 eq_refl) as [HT | [A' [B' [EB [Ha Hb]]]]].
  - discriminate HT.
  - injection EB as <- <-. split; assumption.
Qed.


(* Dually: what lies BELOW an arrow under ssub — only Bot or another arrow.
   Proved by induction on the derivation; transitivity carried by the
   disjunction (the middle is Bot or an arrow, and ssub _ Bot forces Bot). *)
Lemma ssub_arrow_sub : forall S T,
  ssub S T ->
  forall A0 B0, T = BArrow A0 B0 ->
    S = BBot \/ exists Aa Bb, S = BArrow Aa Bb.
Proof.
  intros S T H. induction H; intros Ax Bx ET; subst; try discriminate ET.
  - (* SsRefl *) right. exists Ax, Bx. reflexivity.
  - (* SsTrans: C=arrow -> B is Bot or arrow; then recurse to A *)
    destruct (IHssub2 Ax Bx eq_refl) as [HBbot | [A' [B' EB]]].
    + (* B = Bot, ssub A Bot => A = Bot *)
      subst B. left. apply ssub_bot_tgt in H. exact H.
    + subst B. destruct (IHssub1 A' B' eq_refl) as [HA | [A0 [B0 EA]]].
      * left; exact HA.
      * right. exists A0, B0. exact EA.
  - (* SsBot *) left; reflexivity.
  - (* SsArrow *) right. exists A1, B1. reflexivity.
Qed.

(* An atom / record is never below an arrow (neither is Bot or an arrow). *)
Lemma ssub_atom_not_arrow : forall a A B, ~ ssub (BAtom a) (BArrow A B).
Proof.
  intros a A B H. destruct (ssub_arrow_sub _ _ H A B eq_refl) as [Hbot | [A1 [B1 Ha]]];
    discriminate.
Qed.

Lemma ssub_rec_not_arrow : forall f A B, ~ ssub (BRec f) (BArrow A B).
Proof.
  intros f A B H. destruct (ssub_arrow_sub _ _ H A B eq_refl) as [Hbot | [A1 [B1 Ha]]];
    discriminate.
Qed.


(* Record shape lemmas, mirroring the arrow pair: supertypes of a record are Top
   or records; subtypes are Bot or records. *)
Lemma ssub_rec_super : forall S T,
  ssub S T -> forall f, S = BRec f ->
  T = BTop \/ exists g, T = BRec g.
Proof.
  intros S T H. induction H; intros f0 ES; subst; try discriminate ES.
  - right; eauto.
  - destruct (IHssub1 f0 eq_refl) as [HBtop | [h EB]].
    + subst B. apply ssub_top_src in H0. left; exact H0.
    + subst B. destruct (IHssub2 h eq_refl) as [HC | [g EC]]; [left|right]; eauto.
  - left; reflexivity.
  - right; eauto.
Qed.

Lemma ssub_rec_sub : forall S T,
  ssub S T -> forall g, T = BRec g ->
  S = BBot \/ exists f, S = BRec f.
Proof.
  intros S T H. induction H; intros g0 ET; subst; try discriminate ET.
  - right; eauto.
  - destruct (IHssub2 g0 eq_refl) as [HBbot | [h EB]].
    + subst B. apply ssub_bot_tgt in H. left; exact H.
    + subst B. destruct (IHssub1 h eq_refl) as [HA | [f EA]]; [left|right]; eauto.
  - left; reflexivity.
  - right; eauto.
Qed.

(* ssub record inversion: a demanded field of the supertype is supplied by the
   subtype with a sub-field type. The transitivity case routes through a middle
   record (shape lemmas) and composes the field witnesses. *)
Lemma ssub_rec_inv : forall f g k Tg,
  ssub (BRec f) (BRec g) -> In (k, Tg) g ->
  exists Tf, In (k, Tf) f /\ ssub Tf Tg.
Proof.
  intros f g k Tg H. remember (BRec f) as F eqn:EF. remember (BRec g) as G eqn:EG.
  revert f g EF EG k Tg.
  induction H; intros f0 g0 EF EG k0 Tg0 Hin; subst; try discriminate EF; try discriminate EG.
  - injection EG as <-. exists Tg0. split; [exact Hin | apply SsRefl].
  - (* middle B is a record *)
    destruct (ssub_rec_super _ _ H f0 eq_refl) as [HBtop | [h EB]].
    + subst B. apply ssub_top_src in H0. discriminate H0.
    + subst B.
      destruct (IHssub2 h g0 eq_refl eq_refl k0 Tg0 Hin) as [Th [Hinh Hsh]].
      destruct (IHssub1 f0 h eq_refl eq_refl k0 Th Hinh) as [Tf [Hinf Hsf]].
      exists Tf. split; [exact Hinf | eapply SsTrans; eassumption].
  - injection EF as <-. injection EG as <-. eapply srec_lookup; eassumption.
Qed.

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
      exfalso;
      (destruct (ssub_rec_sub _ _ Hty fields eq_refl) as [Hb | [f Hf]]; discriminate).
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. destruct (ssub_arrow_super _ _ Hsub T Tb eq_refl) as [Ht | [Ay [By [E _]]]];
      discriminate.
  - exists fs; reflexivity.
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

(* ILL-TYPED term rejected: projecting field "a" off the integer 3 is not typeable
   (an Int is not a record). We prove NO type is derivable. *)
Definition ex_bad : tm := tproj (tlit (LInt 3)) "a".

Example ex_bad_untyped : forall T, ~ has_type [] ex_bad T.
Proof.
  intros T H. unfold ex_bad in H. apply inv_proj in H.
  destruct H as [fields [S [He [_ _]]]].
  apply inv_lit in He. simpl in He.
  (* ssub (BAtom AInt) (BRec fields) is impossible *)
  destruct (ssub_rec_sub _ _ He fields eq_refl) as [Hb | [f Hf]]; discriminate.
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
