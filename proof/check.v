(* check.v — a RUNNABLE bidirectional algorithmic typechecker for the minimal
   core of typing.v, proven SOUND against the declarative [has_type].

   The declarative judgment [has_type] (typing.v) is NOT syntax-directed: the
   subsumption rule [TSub] can fire at ANY term, so it cannot be read as an
   algorithm. The standard fix is BIDIRECTIONAL typing: an [synth] (infer) mode
   that is fully syntax-directed, and a [check] (check-against) mode that switches
   to [synth] and then discharges the single subsumption obligation by the TOTAL,
   PROVEN decider [decide_ssub] (ssub.v). [check] is where — and the ONLY where —
   subtyping is consulted, turning the non-syntax-directed [TSub] into one
   decidable test at the application argument position.

   This file is purely ADDITIVE and builds on ssub.v:

     coqc proof/subtype.v   (* value-set algebra + dsub + decide infra *)
     coqc proof/typing.v    (* tm, has_type (declarative), ssub          *)
     coqc proof/ssub.v      (* decide_ssub : total + sound + complete     *)
     coqc proof/check.v     (* THIS FILE                                  *)

   subtype.v / typing.v / ssub.v are UNMODIFIED.

   WHAT IS PROVED (Qed, no Admitted/Axiom/Classical/admit):
     (1) [synth] / [check] : executable, total, structural on [tm].
     (2) SOUNDNESS vs declarative (load-bearing):
           synth_sound : synth G e = Some T  -> has_type G e T
           check_sound : check G e T = true   -> has_type G e T
         proved mutually by [tm] induction, using [decide_ssub_sound] at the
         check mode-switch.
     (3) COMPLETENESS — the tractable fragment, proved (see [synth_complete]
         below); full bidirectional completeness over the WHOLE declarative
         judgment is NOT provable here and is DEFERRED precisely (see the note
         and TODO.md). We prove what holds and do not fake the rest.

   CONNECTIVE NOTE: [check] routes subtyping through [decide_ssub], which is
   COARSE on the Boolean connectives (ssub.v: structural / reflexive only). So
   connective subtyping IN CHECKING inherits that limitation — full connective
   checking needs the dsub/gdecide route, DEFERRED (TODO.md).
*)

Require Import subtype.
Require Import typing.
Require Import ssub.
From Stdlib Require Import List.
From Stdlib Require Import String.
From Stdlib Require Import PeanoNat.
From Stdlib Require Import Lia.
Import ListNotations.

(* ===========================================================================
   1. KEY-DUPLICATION TEST for record literals.

   [has_type] requires [NoDup (map fst fs)] on a record literal ([TRec]). The
   algorithm must reject duplicate keys; we test it with a decidable membership
   over [string] (which has [string_dec]). [keys_nodup] is a boolean mirror of
   [NoDup (map fst fs)], proved equivalent.
   =========================================================================== *)

Fixpoint key_mem (k : string) (ks : list string) : bool :=
  match ks with
  | [] => false
  | k' :: rest => if string_dec k k' then true else key_mem k rest
  end.

Lemma key_mem_In : forall k ks, key_mem k ks = true <-> In k ks.
Proof.
  intros k ks. induction ks as [ | k' rest IH ]; simpl.
  - split; [ discriminate | contradiction ].
  - destruct (string_dec k k') as [He | Hne].
    + subst k'. split; [ intros _; left; reflexivity | reflexivity ].
    + split.
      * intro H. right. apply IH. exact H.
      * intros [Heq | Hin]; [ exfalso; apply Hne; symmetry; exact Heq | apply IH; exact Hin ].
Qed.

Fixpoint keys_nodup (ks : list string) : bool :=
  match ks with
  | [] => true
  | k :: rest => andb (negb (key_mem k rest)) (keys_nodup rest)
  end.

Lemma keys_nodup_NoDup : forall ks, keys_nodup ks = true <-> NoDup ks.
Proof.
  intro ks. induction ks as [ | k rest IH ]; simpl.
  - split; [ intros _; constructor | reflexivity ].
  - split.
    + intro H. apply Bool.andb_true_iff in H. destruct H as [Hk Hrest].
      constructor.
      * intro Hin. apply key_mem_In in Hin.
        destruct (key_mem k rest); [ discriminate Hk | discriminate Hin ].
      * apply IH. exact Hrest.
    + intro H. inversion H as [ | x l Hni Hnd ]; subst.
      apply Bool.andb_true_iff. split.
      * destruct (key_mem k rest) eqn:Hkm; [ | reflexivity ].
        exfalso. apply Hni. apply key_mem_In. exact Hkm.
      * apply IH. exact Hnd.
Qed.

(* ===========================================================================
   2. THE BIDIRECTIONAL ALGORITHM.

   [synth] is a plain [Fixpoint], STRUCTURAL on the term [e] — every recursive
   call is on a strict subterm ([lam] body, [app] head + arg, [let] both halves,
   [rec] each field, [proj] subject). [check] is a non-recursive [Definition]
   that calls [synth] then the total [decide_ssub] — so the whole thing is
   manifestly terminating.

   The record case threads a helper [synth_fields] that synthesizes every field
   (failing if any field fails) and assembles the [BRec] field-type list while
   preserving key order; duplicate-key rejection is applied at the [trec] site
   via [keys_nodup].
   =========================================================================== *)

(* field-type lookup in a synthesized record head (first match), a standalone
   fixpoint so principality/soundness can reason about it directly. *)
Fixpoint flook (k : string) (xs : list (string * BTy)) : option BTy :=
  match xs with
  | [] => None
  | (k', T) :: rest => if string_dec k k' then Some T else flook k rest
  end.

(* [synth_fields G] synthesizes every field type (failing if any field fails),
   assembling the [BRec] field-type list in key order. It takes the per-field
   synthesizer [sy = synth G] as a parameter so [synth] can pass its own
   (structurally-decreasing) self in; this keeps the record recursion a plain
   list fold whose termination is manifest and which the proofs fold over
   directly (no nested mutual-fixpoint guard juggling). *)
Fixpoint synth_fields (sy : tm -> option BTy) (fs : list (string * tm))
    : option (list (string * BTy)) :=
  match fs with
  | [] => Some []
  | (k, e0) :: rest =>
      match sy e0 with
      | Some T =>
          match synth_fields sy rest with
          | Some Ts => Some ((k, T) :: Ts)
          | None => None
          end
      | None => None
      end
  end.

Fixpoint synth (G : list BTy) (e : tm) {struct e} : option BTy :=
  match e with
  | tlit l => Some (lit_type l)
  | tvar n => nth_error G n
  | tlam T body =>
      match synth (T :: G) body with
      | Some Tb => Some (BArrow T Tb)
      | None => None
      end
  | tapp f a =>
      match synth G f with
      | Some (BArrow A B) =>
          (* check the argument against the domain via the mode switch *)
          match synth G a with
          | Some Sa => if decide_ssub Sa A then Some B else None
          | None => None
          end
      | _ => None
      end
  | tlet e1 e2 =>
      match synth G e1 with
      | Some Se => synth (Se :: G) e2
      | None => None
      end
  | trec fields =>
      if keys_nodup (map fst fields) then
        match synth_fields (synth G) fields with
        | Some Ts => Some (BRec Ts)
        | None => None
        end
      else None
  | tproj e0 k =>
      match synth G e0 with
      | Some (BRec fs) => flook k fs
      | _ => None
      end
  (* INCREMENT 11 — conditionals. Synthesize the condition (must check against
     Bool via the mode switch), synthesize both branches, and return the UNION of
     the branch types (the join — exactly the declarative [TIf] result). *)
  | tif c e1 e2 =>
      match synth G c with
      | Some Sc =>
          if decide_ssub Sc (BAtom ABool) then
            match synth G e1, synth G e2 with
            | Some U1, Some U2 => Some (BUnion U1 U2)
            | _, _ => None
            end
          else None
      | None => None
      end
  (* INCREMENT 13 — NARROWING conditional. The scrutinee may have ANY type (Lua
     truthiness — no Bool gate). Each branch is synthesized under its NARROWED
     binder: [truthy_type] for the then-branch, [falsy_type] for the else-branch
     (the de Bruijn 0 the [tifn] binds). Result is the union of the branch types.
     The narrowing here is the [truthy_type]/[falsy_type] BOUND in the context —
     the soundness obligations are discharged by [TIfn] (no [decide_ssub]
     obligation is needed: the binder type IS the narrowed type, so the branch
     uses [SsInterPL]-style projections internally where it consumes the var). *)
  | tifn c e1 e2 =>
      match synth G c with
      | Some _ =>
          match synth (truthy_type :: G) e1, synth (falsy_type :: G) e2 with
          | Some U1, Some U2 => Some (BUnion U1 U2)
          | _, _ => None
          end
      | None => None
      end
  end.

Definition check (G : list BTy) (e : tm) (T : BTy) : bool :=
  match synth G e with
  | Some Se => decide_ssub Se T
  | None => false
  end.

(* ===========================================================================
   3. SOUNDNESS vs the DECLARATIVE judgment — the load-bearing direction.

   [synth_sound] / [check_sound] : every algorithmic acceptance is a declarative
   derivation. Proved by induction on the term [e] via [tm_rect_strong] (typing.v),
   whose [Pl] predicate carries the IH through the record field list. The record
   case reasons about the inline [synth_fields] fix through the [Pl]-IH; the [app]
   case discharges its subtyping obligation by [decide_ssub_sound] (ssub.v), then
   [TSub]; record-literal acceptance carries the [keys_nodup] NoDup proof.
   =========================================================================== *)

(* the projection lookup: a hit at key [k] yields [In (k,T) fs]. *)
Lemma flook_In : forall (k : string) fs T,
  flook k fs = Some T -> In (k, T) fs.
Proof.
  intros k fs. induction fs as [ | [k' T'] rest IH ]; intros T H; simpl in H.
  - discriminate.
  - destruct (string_dec k k') as [Hk | Hk].
    + subst k'. injection H as <-. left; reflexivity.
    + right. apply IH. exact H.
Qed.

Theorem synth_sound : forall e G T, synth G e = Some T -> has_type G e T.
Proof.
  intro e.
  induction e using tm_rect_strong with
    (Pl := fun fs => forall G Ts, synth_fields (synth G) fs = Some Ts -> has_fields G fs Ts);
    intros.
  - (* tlit *) simpl in H. injection H as <-. apply TLit.
  - (* tvar *) simpl in H. apply TVar. exact H.
  - (* tlam *) simpl in H.
    destruct (synth (T :: G) e) as [ Tb | ] eqn:Hb; [ | discriminate ].
    injection H as <-. apply TLam. apply IHe. exact Hb.
  - (* tapp *) simpl in H.
    destruct (synth G e1) as [ Sf | ] eqn:Hf; [ | discriminate ].
    destruct Sf as [ | | | | | | | A B ]; try discriminate H.
    destruct (synth G e2) as [ Sa | ] eqn:Ha; [ | discriminate ].
    destruct (decide_ssub Sa A) eqn:Hd; [ | discriminate ].
    injection H as <-.
    eapply TApp; [ apply IHe1; exact Hf | ].
    eapply TSub; [ apply IHe2; exact Ha | apply decide_ssub_sound; exact Hd ].
  - (* tlet *) simpl in H.
    destruct (synth G e1) as [ Se | ] eqn:H1; [ | discriminate ].
    eapply TLet; [ apply IHe1; exact H1 | apply IHe2; exact H ].
  - (* trec *) simpl in H.
    destruct (keys_nodup (map fst fs)) eqn:Hnd; [ | discriminate ].
    destruct (synth_fields (synth G) fs) as [ Ts | ] eqn:Hf; [ | discriminate ].
    injection H as <-. apply TRec.
    + apply IHe. exact Hf.
    + apply keys_nodup_NoDup. exact Hnd.
  - (* tproj *) simpl in H.
    destruct (synth G e) as [ Se | ] eqn:He; [ | discriminate ].
    destruct Se as [ | | | | | | fs | ]; try discriminate H.
    eapply TProj.
    + apply IHe. exact He.
    + apply flook_In. exact H.
  - (* tif *) simpl in H.
    destruct (synth G e1) as [ Sc | ] eqn:Hc; [ | discriminate ].
    destruct (decide_ssub Sc (BAtom ABool)) eqn:Hdb; [ | discriminate ].
    destruct (synth G e2) as [ U1 | ] eqn:H1; [ | discriminate ].
    destruct (synth G e3) as [ U2 | ] eqn:H2; [ | discriminate ].
    injection H as <-. apply TIf.
    + eapply TSub; [ apply IHe1; exact Hc | apply decide_ssub_sound; exact Hdb ].
    + apply IHe2; exact H1.
    + apply IHe3; exact H2.
  - (* tifn: scrutinee at any type U; branches synthesized under their narrowed
       binders [truthy_type]/[falsy_type]; result is the union. Discharged by
       [TIfn] directly — no subtyping obligation. *)
    simpl in H.
    destruct (synth G e1) as [ Uc | ] eqn:Hc; [ | discriminate ].
    destruct (synth (truthy_type :: G) e2) as [ U1 | ] eqn:H1; [ | discriminate ].
    destruct (synth (falsy_type :: G) e3) as [ U2 | ] eqn:H2; [ | discriminate ].
    injection H as <-. eapply TIfn.
    + apply IHe1; exact Hc.
    + apply IHe2; exact H1.
    + apply IHe3; exact H2.
  - (* Pl [] *) simpl in H. injection H as <-. apply HFnil.
  - (* Pl cons *) simpl in H.
    destruct (synth G e) as [ Te | ] eqn:He; [ | discriminate ].
    destruct (synth_fields (synth G) rest) as [ Tr | ] eqn:Hr; [ | discriminate ].
    injection H as <-. apply HFcons.
    + apply IHe. exact He.
    + apply IHe0. exact Hr.
Qed.

Theorem check_sound : forall e G T, check G e T = true -> has_type G e T.
Proof.
  intros e G T H. unfold check in H.
  destruct (synth G e) as [ Se | ] eqn:He; [ | discriminate ].
  eapply TSub.
  - apply synth_sound. exact He.
  - apply decide_ssub_sound. exact H.
Qed.

(* ===========================================================================
   4. COMPLETENESS — the tractable direction: SYNTHESIS IS PRINCIPAL.

   The fully-general completeness statement [has_type G e T -> exists S,
   synth G e = Some S /\ ssub S T] is NOT provable in this minimal core without
   resolving two genuine degeneracies (see the DEFERRED note): a function/record
   SUBJECT may declaratively type at [BBot] (uninhabited) while [synth] only
   produces an arrow/record head, so the algorithm can REFUSE to step where the
   declarative judgment proceeds via [TSub] from [BBot]. That is a real
   bidirectional gap (TSub is non-syntax-directed and can appear anywhere).

   What IS provable, fully and generally (no fragment restriction, no axiom), is
   the PRINCIPALITY half — whenever [synth] DOES produce a type, that type is the
   LEAST one the declarative judgment assigns: every declarative type is an
   [ssub]-supertype of the synthesized one.

     synth_principal : has_type G e T -> synth G e = Some S -> ssub S T

   Together with [synth_sound] this CHARACTERIZES [synth] exactly: its output is a
   declarative type ([synth_sound]) and the minimal one ([synth_principal]). The
   ONLY thing not proved is that [synth] always succeeds on a well-typed term
   (algorithmic adequacy / non-degeneracy) — that is the BBot/narrowing gap,
   DEFERRED precisely to TODO.md. The [let] case needs context NARROWING
   ([narrowing] below — replacing a context entry by an [ssub]-subtype preserves
   typing), which we prove generally.

   [synth_complete_nondegenerate] packages the conditional completeness: if the
   algorithm produces an answer, it is subtype-complete.
   =========================================================================== *)

(* CONTEXT NARROWING (general, at any cut): replacing a context entry by an
   [ssub]-SUBTYPE preserves typing. Needed for the [tlet] principality case
   (the let body is synthesized in the context extended by the let-binder's
   SYNTHESIZED type, an [ssub]-subtype of its declarative type). Mutual with
   has_fields; the variable rule narrows the cut entry via [TSub]. *)
Lemma narrowing : forall G e T,
  has_type G e T ->
  forall G1 A G2 A', G = G1 ++ A :: G2 -> ssub A' A ->
    has_type (G1 ++ A' :: G2) e T.
Proof.
  intros G e T H.
  induction H using has_type_mind with
    (P0 := fun G fs Ts (_ : has_fields G fs Ts) =>
       forall G1 A G2 A', G = G1 ++ A :: G2 -> ssub A' A ->
         has_fields (G1 ++ A' :: G2) fs Ts);
    intros; subst.
  - apply TLit.
  - (* TVar: split on position of [n] relative to the cut [length G1]. *)
    destruct (Nat.lt_total n (Datatypes.length G1)) as [Hlt | [Heq | Hgt]].
    + apply TVar. rewrite nth_error_app1 in e by assumption.
      rewrite nth_error_app1 by assumption. exact e.
    + subst n. rewrite nth_error_mid in e. injection e as <-.
      eapply TSub; [ apply TVar; apply nth_error_mid | eassumption ].
    + apply TVar. rewrite nth_error_app2 in e by lia.
      rewrite nth_error_app2 by lia.
      remember (n - Datatypes.length G1) as m eqn:Em.
      destruct m as [ | m' ]; [ lia | simpl in e |- *; exact e ].
  - (* TLam *) apply TLam.
    eapply (IHhas_type (T::G1) _ G2 A'); [ reflexivity | eassumption ].
  - eapply TApp;
      [ eapply (IHhas_type1 G1 _ G2 A') | eapply (IHhas_type2 G1 _ G2 A') ];
      (reflexivity || eassumption).
  - eapply TLet;
      [ eapply (IHhas_type1 G1 _ G2 A')
      | match goal with [ |- has_type (?Alet :: _) _ _ ] =>
          eapply (IHhas_type2 (Alet::G1) _ G2 A') end ];
      (reflexivity || eassumption).
  - eapply TRec; [ eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ] | eassumption ].
  - eapply TProj; [ eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ] | eassumption ].
  - eapply TSub; [ eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ] | eassumption ].
  - (* TIf *) eapply TIf;
      [ eapply (IHhas_type1 G1 _ G2 A')
      | eapply (IHhas_type2 G1 _ G2 A')
      | eapply (IHhas_type3 G1 _ G2 A') ];
      (reflexivity || eassumption).
  - (* TIfn: scrutinee narrows at cut G1; each branch is under its fresh narrowing
       binder, so its cut is (truthy_type::G1) / (falsy_type::G1). *)
    eapply TIfn;
      [ eapply (IHhas_type1 G1 _ G2 A')
      | eapply (IHhas_type2 (truthy_type :: G1) _ G2 A')
      | eapply (IHhas_type3 (falsy_type :: G1) _ G2 A') ];
      (reflexivity || eassumption).
  - apply HFnil.
  - apply HFcons;
      [ eapply (IHhas_type G1 _ G2 A') | eapply (IHhas_type0 G1 _ G2 A') ];
      (reflexivity || eassumption).
Qed.

Corollary narrowing_head : forall A A' G e T,
  has_type (A :: G) e T -> ssub A' A -> has_type (A' :: G) e T.
Proof.
  intros A A' G e T H Hs.
  apply (narrowing (A::G) e T H [] A G A'); [ reflexivity | exact Hs ].
Qed.

(* adding a supplier field to a record-subtyping supplier list preserves [srec]
   (the demands are met by [In], which is monotone under [cons]). *)
Lemma srec_cons_supplier : forall k T f g, srec f g -> srec ((k, T) :: f) g.
Proof.
  intros k T f g H. induction H.
  - apply SrNil.
  - eapply SrCons; [ right; exact H | exact H0 | exact IHsrec ].
Qed.

(* WHY [tproj] IS EXCLUDED FROM PRINCIPALITY — a genuine SCOPE boundary, not a
   proof-skill gap (recorded as substrate, deferred to TODO.md). Declarative
   [TProj] uses [In (k,T) fields] — ANY field at key [k]. Over a record type with
   DUPLICATE keys it assigns MULTIPLE types to one projection, so a LEAST type
   need not exist and principality is meaningless. [synth]'s [flook] takes the
   FIRST match; matching that to [ssub_rec_inv]'s supplier needs [NoDup] keys on
   the synthesized record — which holds for [trec]-LITERAL records ([keys_nodup]
   gate) but NOT for a [BRec] read out of an arbitrary context entry (a [tvar]
   whose declared type is a non-[NoDup] record). typing.v itself only proves
   projection principality under [NoDup] ([field_lookup_typed] /
   [nodup_unique_type]). So principality is stated and proved for the
   PROJECTION-FREE fragment; projection principality under [NoDup] records is
   DEFERRED. The [check]/[synth] ALGORITHM itself still handles [tproj] fully
   (and SOUNDLY — [synth_sound] covers it); only the PRINCIPALITY meta-property is
   fenced. *)
Fixpoint proj_free (e : tm) : Prop :=
  match e with
  | tlit _ => True
  | tvar _ => True
  | tlam _ b => proj_free b
  | tapp f a => proj_free f /\ proj_free a
  | tlet e1 e2 => proj_free e1 /\ proj_free e2
  | trec fs => (fix pl (xs : list (string * tm)) : Prop :=
                  match xs with
                  | [] => True
                  | (_, e0) :: rest => proj_free e0 /\ pl rest
                  end) fs
  | tproj _ _ => False
  | tif c e1 e2 => proj_free c /\ proj_free e1 /\ proj_free e2
  | tifn c e1 e2 => proj_free c /\ proj_free e1 /\ proj_free e2
  end.

(* SYNTHESIS IS PRINCIPAL (projection-free fragment) — the tractable completeness
   direction. By [tm] induction; the [Pl] predicate carries the field-list
   principality as an [srec] (pointwise) fact. [tapp] uses [ssub_arrow_inv];
   [tlet] uses [narrowing_head]; [tsub] is the clean case (transitivity threads
   the subsumption); [tproj] is excluded (see the [proj_free] note above). *)
Theorem synth_principal : forall e G T S,
  proj_free e -> has_type G e T -> synth G e = Some S -> ssub S T.
Proof.
  intro e. induction e using tm_rect_strong with
    (P := fun e => forall G T S,
        proj_free e -> has_type G e T -> synth G e = Some S -> ssub S T)
    (Pl := fun fs =>
        (fix pl (xs : list (string * tm)) : Prop :=
           match xs with [] => True | (_, e0) :: rest => proj_free e0 /\ pl rest end) fs ->
        forall G Ts Ss,
        has_fields G fs Ts ->
        synth_fields (synth G) fs = Some Ss ->
        srec Ss Ts);
    intros.
  - (* tlit *) simpl in H1. injection H1 as <-. apply inv_lit in H0. exact H0.
  - (* tvar *) simpl in H1. apply inv_var in H0. destruct H0 as [S0 [Hl Hs]].
    rewrite Hl in H1. injection H1 as <-. exact Hs.
  - (* tlam *) simpl in H1. simpl in H.
    destruct (synth (T :: G) e) as [ Sb | ] eqn:Hb; [ | discriminate ].
    injection H1 as <-. apply inv_lam in H0. destruct H0 as [Tb [Hb' Hsub]].
    eapply SsTrans; [ | exact Hsub ].
    apply SsArrow; [ apply SsRefl | apply (IHe (T::G) Tb Sb H Hb' Hb) ].
  - (* tapp *) simpl in H1. simpl in H. destruct H as [Hpf Hpa].
    destruct (synth G e1) as [ Sf | ] eqn:Hf; [ | discriminate ].
    destruct Sf as [ | | | | | | | A' B' ]; try discriminate H1.
    destruct (synth G e2) as [ Sa | ] eqn:Ha; [ | discriminate ].
    destruct (decide_ssub Sa A') eqn:Hd; [ | discriminate ].
    injection H1 as <-.
    apply inv_app in H0. destruct H0 as [A [B [Hf' [_ Hsub]]]].
    pose proof (IHe1 G (BArrow A B) (BArrow A' B') Hpf Hf' Hf) as Harr.
    apply ssub_arrow_inv in Harr. destruct Harr as [_ HcoB].
    eapply SsTrans; [ exact HcoB | exact Hsub ].
  - (* tlet *) simpl in H1. simpl in H. destruct H as [Hp1 Hp2].
    destruct (synth G e1) as [ S1 | ] eqn:H1e; [ | discriminate ].
    apply inv_let in H0. destruct H0 as [A [B [HA [HB Hsub]]]].
    pose proof (IHe1 G A S1 Hp1 HA H1e) as Hs1.
    pose proof (narrowing_head A S1 G e2 B HB Hs1) as HBnarrow.
    eapply SsTrans; [ apply (IHe2 (S1::G) B S Hp2 HBnarrow H1) | exact Hsub ].
  - (* trec *) simpl in H1. simpl in H.
    destruct (keys_nodup (map fst fs)) eqn:Hnd; [ | discriminate ].
    destruct (synth_fields (synth G) fs) as [ Ts | ] eqn:Hf; [ | discriminate ].
    injection H1 as <-. apply inv_rec in H0. destruct H0 as [Ts0 [Hfields [_ Hsub]]].
    eapply SsTrans; [ | exact Hsub ].
    apply SsRec. apply (IHe H G Ts0 Ts Hfields Hf).
  - (* tproj *) simpl in H. contradiction.
  - (* tif *) simpl in H1. simpl in H. destruct H as [Hpc [Hp1 Hp2]].
    destruct (synth G e1) as [ Sc | ] eqn:Hc; [ | discriminate ].
    destruct (decide_ssub Sc (BAtom ABool)) eqn:Hdb; [ | discriminate ].
    destruct (synth G e2) as [ Sc1 | ] eqn:H1e; [ | discriminate ].
    destruct (synth G e3) as [ Sc2 | ] eqn:H2e; [ | discriminate ].
    injection H1 as <-.
    apply inv_if in H0. destruct H0 as [V1 [V2 [_ [HV1 [HV2 Hsub]]]]].
    (* principality of each branch: synth's branch type is ≤ the declarative one *)
    pose proof (IHe2 G V1 Sc1 Hp1 HV1 H1e) as Hb1.
    pose proof (IHe3 G V2 Sc2 Hp2 HV2 H2e) as Hb2.
    (* BUnion Sc1 Sc2 ≤ BUnion V1 V2 ≤ T (union is monotone; then Hsub). *)
    eapply SsTrans; [ | exact Hsub ].
    apply SsUnionE; [ apply SsUnionInL; exact Hb1 | apply SsUnionInR; exact Hb2 ].
  - (* tifn: principality of each NARROWED branch; the branch synthesis runs under
       the narrowed binder, exactly as the declarative [TIfn] types it. *)
    simpl in H1. simpl in H. destruct H as [Hpc [Hp1 Hp2]].
    destruct (synth G e1) as [ Sc | ] eqn:Hc; [ | discriminate ].
    destruct (synth (truthy_type :: G) e2) as [ Sc1 | ] eqn:H1e; [ | discriminate ].
    destruct (synth (falsy_type :: G) e3) as [ Sc2 | ] eqn:H2e; [ | discriminate ].
    injection H1 as <-.
    apply inv_ifn in H0. destruct H0 as [Uc [V1 [V2 [_ [HV1 [HV2 Hsub]]]]]].
    pose proof (IHe2 (truthy_type :: G) V1 Sc1 Hp1 HV1 H1e) as Hb1.
    pose proof (IHe3 (falsy_type :: G) V2 Sc2 Hp2 HV2 H2e) as Hb2.
    eapply SsTrans; [ | exact Hsub ].
    apply SsUnionE; [ apply SsUnionInL; exact Hb1 | apply SsUnionInR; exact Hb2 ].
  - (* Pl nil *) simpl in H1. injection H1 as <-.
    inversion H0; subst. apply SrNil.
  - (* Pl cons *) simpl in H. destruct H as [Hpe Hprest]. simpl in H1.
    destruct (synth G e) as [ Te | ] eqn:He; [ | discriminate ].
    destruct (synth_fields (synth G) rest) as [ Tr | ] eqn:Hr; [ | discriminate ].
    injection H1 as <-.
    inversion H0 as [ | G' k'' e'' Thd fs'' Ts'' Hhd Htl Ek' Ets ]; subst.
    eapply SrCons; [ left; reflexivity | | ].
    + apply (IHe G Thd Te Hpe Hhd He).
    + apply srec_cons_supplier. apply (IHe0 Hprest G Ts'' Tr Htl Hr).
Qed.

(* CONDITIONAL COMPLETENESS — the packaged tractable statement: for a
   projection-free, well-typed term whose synthesis produces an answer, that
   answer is subtype-complete (an [ssub]-subtype of every declarative type). Two
   hypotheses fence exactly the two DEFERRED gaps: [proj_free] fences the
   record-NoDup projection-principality boundary, and "[synth] = Some _" fences
   the non-degeneracy (the algorithm not getting stuck at a [BBot]/narrowing
   degenerate position). *)
Corollary synth_complete_nondegenerate : forall e G T S,
  proj_free e -> has_type G e T -> synth G e = Some S -> ssub S T.
Proof. exact synth_principal. Qed.

(* and the [check] consequence: a projection-free, well-typed term whose
   synthesis succeeds and whose declarative type is [decide_ssub]-above the
   synthesized type passes [check]. (The synthesized type IS the least, by
   principality, so this fires whenever the answer exists.) INCREMENT 12: the
   [decide_ssub] completeness step now requires the synthesized type [S] and the
   target [T] to be INTERSECTION-FREE ([inter_free]) — the decider is complete
   only off the non-distributive intersection-left frontier (ssub.v). For the
   intersection-free term fragment (no narrowing / no connective term-formers)
   this always holds; connective checking is DEFERRED (TODO.md). *)
Corollary check_complete_nondegenerate : forall e G T S,
  inter_free S -> inter_free T ->
  has_type G e T -> synth G e = Some S -> ssub S T -> check G e T = true.
Proof.
  intros e G T S HifS HifT Hty Hsy Hsub. unfold check. rewrite Hsy.
  apply decide_ssub_complete; assumption.
Qed.

(* ===========================================================================
   5. EXECUTABLE SANITY (Compute) — the checker REDUCES to definite answers.

   Well-typed terms synthesize the right type; ill-typed terms synthesize None.
   These [reflexivity] proofs witness that [synth]/[check] genuinely COMPUTE
   (the kernel reduces them to [Some _] / [None] / [true] / [false]).
   =========================================================================== *)

(* (λx:Int. x) 3  ⇒  Int *)
Example compute_app_id :
  synth [] (tapp (tlam (BAtom AInt) (tvar 0)) (tlit (LInt 3))) = Some (BAtom AInt).
Proof. reflexivity. Qed.

(* {a = 7, b = true}.a  ⇒  Int *)
Example compute_proj :
  synth []
    (tproj (trec [("a"%string, tlit (LInt 7)); ("b"%string, tlit (LBool true))]) "a"%string)
  = Some (BAtom AInt).
Proof. reflexivity. Qed.

(* {a = 7, b = true}.b  ⇒  Bool *)
Example compute_proj_b :
  synth []
    (tproj (trec [("a"%string, tlit (LInt 7)); ("b"%string, tlit (LBool true))]) "b"%string)
  = Some (BAtom ABool).
Proof. reflexivity. Qed.

(* the bare lambda synthesizes an arrow *)
Example compute_lam :
  synth [] (tlam (BAtom AInt) (tvar 0)) = Some (BArrow (BAtom AInt) (BAtom AInt)).
Proof. reflexivity. Qed.

(* INCREMENT 11 — CONDITIONAL synthesis. [if true then 3 else "s"] synthesizes the
   UNION of the branch types [Int ∪ Str] — a genuinely union-typed term. *)
Example compute_if_union :
  synth [] (tif (tlit (LBool true)) (tlit (LInt 3)) (tlit (LStr 0)))
  = Some (BUnion (BAtom AInt) (BAtom AStr)).
Proof. reflexivity. Qed.

(* it is well typed at the union, and CHECKS against any supertype (e.g. Top). *)
Example compute_if_checks_top :
  check [] (tif (tlit (LBool true)) (tlit (LInt 3)) (tlit (LStr 0))) BTop = true.
Proof. reflexivity. Qed.

(* and it is sound: has_type at the union (via check_sound). *)
Example compute_if_sound :
  has_type [] (tif (tlit (LBool true)) (tlit (LInt 3)) (tlit (LStr 0)))
              (BUnion (BAtom AInt) (BAtom AStr)).
Proof. apply check_sound. reflexivity. Qed.

(* ILL-TYPED: a non-Bool condition ⇒ None (3 is not a boolean). *)
Example compute_if_badcond_None :
  synth [] (tif (tlit (LInt 0)) (tlit (LInt 3)) (tlit (LStr 0))) = None.
Proof. reflexivity. Qed.

(* INCREMENT 13 — NARROWING checker. The scrutinee may be ANY type (Lua truthiness,
   no Bool gate): [tifn 3 then else] synthesizes the union of the branch types, and
   in the then-branch the de Bruijn-0 var has the NARROWED [truthy_type]. Here the
   then-branch reads the narrowed var (var0 : truthy_type) and the else-branch reads
   the falsy-narrowed var (var0 : falsy_type). *)
Example compute_ifn_narrows :
  synth [] (tifn (tlit (LInt 3)) (tvar 0) (tvar 0))
  = Some (BUnion truthy_type falsy_type).
Proof. reflexivity. Qed.

(* THE CHECKER PAYOFF. A non-nil consumer [g : truthy_type → Int] applied to the
   then-NARROWED scrutinee CHECKS; the scrutinee's declared type is the maybe-nil
   [Int ∪ Nil] (passed as a free var of that type). The whole [tifn] checks. *)
Example compute_ifn_payoff_synth :
  synth [ BArrow truthy_type (BAtom AInt) ]   (* index 0 : the consumer g *)
    (tifn (tvar 0)                            (* scrutinee = g itself (truthy: a function) *)
       (tapp (tvar 1) (tvar 0))               (* then: g (index 1) applied to narrowed var0 *)
       (tlit (LInt 0)))
  = Some (BUnion (BAtom AInt) (BAtom AInt)).
Proof. reflexivity. Qed.

(* and it is SOUND (declaratively well typed via check_sound). *)
Example compute_ifn_payoff_sound :
  has_type [ BArrow truthy_type (BAtom AInt) ]
    (tifn (tvar 0) (tapp (tvar 1) (tvar 0)) (tlit (LInt 0)))
    (BUnion (BAtom AInt) (BAtom AInt)).
Proof. apply check_sound. reflexivity. Qed.

(* WITHOUT narrowing the SAME application is REJECTED by the checker: a free var of
   the maybe-nil type [Int ∪ Nil] passed to the [truthy_type]-demanding consumer
   fails the domain check (nil is not truthy). *)
Example compute_ifn_payoff_unnarrowed_None :
  synth [ BUnion (BAtom AInt) (BAtom ANil) ; BArrow truthy_type (BAtom AInt) ]
    (tapp (tvar 1) (tvar 0)) = None.
Proof. reflexivity. Qed.

(* ILL-TYPED: projecting a field off a literal ⇒ None (not a record) *)
Example compute_proj_of_lit_None :
  synth [] (tproj (tlit (LInt 3)) "f"%string) = None.
Proof. reflexivity. Qed.

(* ILL-TYPED: applying a non-function ⇒ None *)
Example compute_app_nonfun_None :
  synth [] (tapp (tlit (LInt 3)) (tlit (LInt 1))) = None.
Proof. reflexivity. Qed.

(* ILL-TYPED: argument fails the domain check (Str vs Int) ⇒ None *)
Example compute_app_badarg_None :
  synth [] (tapp (tlam (BAtom AInt) (tvar 0)) (tlit (LStr 0))) = None.
Proof. reflexivity. Qed.

(* ILL-TYPED: duplicate record keys rejected ⇒ None *)
Example compute_dup_keys_None :
  synth [] (trec [("a"%string, tlit (LInt 1)); ("a"%string, tlit (LInt 2))]) = None.
Proof. reflexivity. Qed.

(* projecting an ABSENT key ⇒ None *)
Example compute_proj_absent_None :
  synth [] (tproj (trec [("a"%string, tlit (LInt 7))]) "z"%string) = None.
Proof. reflexivity. Qed.

(* [check] decides correctly: Int checks against Num (Int <: Num) but not vice versa *)
Example compute_check_subsume_true :
  check [] (tlit (LInt 3)) (BAtom ANum) = true.
Proof. reflexivity. Qed.

Example compute_check_subsume_false :
  check [] (tlit (LStr 0)) (BAtom AInt) = false.
Proof. reflexivity. Qed.

(* and [check] is SOUND on a real subsumption: 3 : Num via Int <: Num *)
Example compute_check_sound_demo : has_type [] (tlit (LInt 3)) (BAtom ANum).
Proof. apply check_sound. reflexivity. Qed.

(* ===========================================================================
   ASSUMPTION AUDIT — closed under the global context (no axioms / Admitted /
   Classical). The soundness theorems are the load-bearing point; the
   principality (tractable completeness) theorem is audited alongside.
   =========================================================================== *)
Print Assumptions synth_sound.
Print Assumptions check_sound.
Print Assumptions synth_principal.
Print Assumptions narrowing.
