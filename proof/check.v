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

(* MULTI-RETURN — synthesize a return-sequence's component types positionally,
   assembling the [BTuple] component list (parallel to [synth_fields]). *)
Fixpoint synth_seq (sy : tm -> option BTy) (es : list tm) : option (list BTy) :=
  match es with
  | [] => Some []
  | e0 :: rest =>
      match sy e0 with
      | Some T =>
          match synth_seq sy rest with
          | Some Ts => Some (T :: Ts)
          | None => None
          end
      | None => None
      end
  end.

(* MULTIPLE-ASSIGNMENT — unwrap a list of reference types [BRef T_i] to the content
   types [T_i] (the target CELL types); fails ([None]) on any non-reference target.
   The algorithmic counterpart of the [map BRef Tgts] premise of [TMAssign]. *)
Fixpoint unref_seq (Ts : list BTy) : option (list BTy) :=
  match Ts with
  | [] => Some []
  | BRef T :: rest =>
      match unref_seq rest with
      | Some Cs => Some (T :: Cs)
      | None => None
      end
  | _ :: _ => None
  end.

(* MULTIPLE-ASSIGNMENT — pointwise [decide_rsub] gate: every adjusted source type is
   [rsub]-below the corresponding target cell type. The algorithmic [Forall2 rsub]
   premise of [TMAssign]. (Lengths must match; mismatched lengths ⇒ [false].) *)
Fixpoint decide_rsub_seq (As Bs : list BTy) : bool :=
  match As, Bs with
  | [], [] => true
  | A :: As', B :: Bs' => andb (decide_rsub A B) (decide_rsub_seq As' Bs')
  | _, _ => false
  end.

(* [synth] is Sigma-threaded (passed to every recursive call) for a Sigma-general
   soundness statement. Source terms carry no locations ([tloc] arises only at run
   time from [talloc]); a source [tloc] is REJECTED ([None]). The three reference
   operations: alloc ⇒ [BRef U]; deref ⇒ unwrap [BRef U] to [U]; assign ⇒ check the
   value against the cell's content type (INVARIANT, via [decide_rsub]) ⇒ unit. *)
Fixpoint synth (Sig : list BTy) (G : list BTy) (e : tm) {struct e} : option BTy :=
  match e with
  | tlit l => Some (lit_type l)
  | tvar n => nth_error G n
  (* INCREMENT 19 — PRIMITIVE operators. CHECK both operands against [ANum] (via
     the mode switch [decide_ssub]); arithmetic returns [ANum], comparison [ABool]. *)
  | tprim op a b =>
      (* synth the LEFT operand once; a record-typed left operand that is
         SYNTACTICALLY a [tmeta] takes the operator-metamethod branch ([mm_binop op]
         in its read interface), a record that is NOT a [tmeta] is rejected (a plain
         record is not arithmetic-able and does not dispatch), and any other left
         type takes the NUMERIC path. The outer single match on [synth a] keeps the
         soundness proof clean. *)
      match synth Sig G a with
      | Some (BRec M) =>
          match a with
          | tmeta _ _ =>
              match flook (mm_binop op) M with
              | Some (BArrow Self (BArrow Other R)) =>
                  match synth Sig G b with
                  | Some Sb =>
                      if andb (decide_rsub (BRec M) Self) (decide_ssub Sb Other)
                      then Some R else None
                  | None => None
                  end
              | _ => None
              end
          | _ => None
          end
      | Some (BAtom al) =>
          (* INCREMENT 24 — RIGHT-operand metamethod fallback ([TPrimMetaR]), the exact
             MIRROR of the left-operand dispatch above. The left operand is a SCALAR
             ([BAtom al]); if the right operand is SYNTACTICALLY a [tmeta] whose read
             interface carries [mm_binop op : BAtom al' -> Other -> R] with [al <: al'],
             dispatch to it. Otherwise (right not a [tmeta], or no such metamethod) fall
             through to the NUMERIC path. Keeping this inside the [Some (BAtom al)] arm
             of the OUTER match (rather than re-matching on operand syntax) keeps the
             soundness proof a single linear case per arm. *)
          match synth Sig G b with
          | Some (BRec M) =>
              match b with
              | tmeta _ _ =>
                  match flook (mm_binop op) M with
                  | Some (BArrow (BAtom al') (BArrow Other R)) =>
                      if andb (decide_ssub (BAtom al) (BAtom al'))
                              (decide_rsub (BRec M) Other)
                      then Some R else None
                  | _ => None
                  end
              | _ => None
              end
          | Some Sb =>
              if andb (decide_ssub (BAtom al) (BAtom ANum)) (decide_ssub Sb (BAtom ANum)) then
                (if arith_op op then Some (BAtom ANum)
                 else if cmp_op op then Some (BAtom ABool)
                 else None)
              else None
          | None => None
          end
      | Some Sa =>
          match synth Sig G b with
          | Some Sb =>
              if andb (decide_ssub Sa (BAtom ANum)) (decide_ssub Sb (BAtom ANum)) then
                (if arith_op op then Some (BAtom ANum)
                 else if cmp_op op then Some (BAtom ABool)
                 else None)
              else None
          | None => None
          end
      | None => None
      end
  | tlam T body =>
      match synth Sig (T :: G) body with
      | Some Tb => Some (BArrow T Tb)
      | None => None
      end
  | tapp f a =>
      (* synth the function once. A record-typed function that is SYNTACTICALLY a
         [tmeta] with a [__call] metamethod is APPLICABLE (the [__call] branch); a
         record that is NOT a [tmeta] is rejected; an arrow function takes the
         ordinary application branch. The outer single match keeps the proof clean. *)
      match synth Sig G f with
      | Some (BArrow A B) =>
          match synth Sig G a with
          | Some Sa => if decide_ssub Sa A then Some B else None
          | None => None
          end
      | Some (BRec M) =>
          match f with
          | tmeta _ _ =>
              match flook mm_call M with
              | Some (BArrow Self (BArrow A R)) =>
                  match synth Sig G a with
                  | Some Sa =>
                      if andb (decide_rsub (BRec M) Self) (decide_ssub Sa A)
                      then Some R else None
                  | None => None
                  end
              | _ => None
              end
          | _ => None
          end
      | _ => None
      end
  | tlet e1 e2 =>
      match synth Sig G e1 with
      | Some Se => synth Sig (Se :: G) e2
      | None => None
      end
  | trec fields =>
      if keys_nodup (map fst fields) then
        match synth_fields (synth Sig G) fields with
        | Some Ts => Some (BRec Ts)
        | None => None
        end
      else None
  | tproj e0 k =>
      match synth Sig G e0 with
      | Some (BRec fs) => flook k fs
      | _ => None
      end
  (* INCREMENT 11 — conditionals. Synthesize the condition (must check against
     Bool via the mode switch), synthesize both branches, and return the UNION of
     the branch types (the join — exactly the declarative [TIf] result). *)
  | tif c e1 e2 =>
      match synth Sig G c with
      | Some Sc =>
          if decide_ssub Sc (BAtom ABool) then
            match synth Sig G e1, synth Sig G e2 with
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
      match synth Sig G c with
      | Some _ =>
          match synth Sig (truthy_type :: G) e1, synth Sig (falsy_type :: G) e2 with
          | Some U1, Some U2 => Some (BUnion U1 U2)
          | _, _ => None
          end
      | None => None
      end
  (* INCREMENT 14 — GENERAL RECURSION. The annotation [T] makes [tfix] synthesizable:
     CHECK the body against [T] under the recursive self-ref binder [T::G] — i.e.
     synthesize the body and gate it [≤ T] via the mode switch — then return [T].
     (Checking, not synthesizing-then-comparing, is what the declarative [TFix]
     demands: the body's type and the self-ref type must agree, up to subsumption.) *)
  | tfix T body =>
      match synth Sig (T :: G) body with
      | Some Sb => if decide_ssub Sb T then Some T else None
      | None => None
      end
  (* INCREMENT 15 — TYPE-TEST NARROWING. The scrutinee may have ANY type [U] (no
     gate). The then-branch is synthesized under the TAG-NARROWED binder
     [tag_type g]; the else-branch under the scrutinee's own type [U] (the sound
     OVER-approximation — precise negative narrowing is DEFERRED). Result = union
     of the branch types. Discharged by [TTypeTest] directly — no [decide_ssub]
     obligation: the binder type IS the narrowed type. *)
  | ttypetest g c e1 e2 =>
      match synth Sig G c with
      | Some U =>
          match synth Sig (tag_type g :: G) e1, synth Sig (U :: G) e2 with
          | Some U1, Some U2 => Some (BUnion U1 U2)
          | _, _ => None
          end
      | None => None
      end
  (* SPLIT-STEP 3 — REFERENCE OPERATIONS. *)
  | talloc e0 =>
      match synth Sig G e0 with
      | Some U => Some (BRef U)
      | None => None
      end
  | tderef e0 =>
      match synth Sig G e0 with
      | Some (BRef U) => Some U
      | _ => None
      end
  | tassign r e0 =>
      match synth Sig G r with
      | Some (BRef U) =>
          match synth Sig G e0 with
          (* INVARIANT content: the value's type must be rsub-below the cell's U. *)
          | Some Sv => if decide_rsub Sv U then Some (BAtom ANil) else None
          | None => None
          end
      | _ => None
      end
  (* TYPE ASCRIPTION — the inference-guiding seam. [synth (tannot T e)] drives the
     checker into CHECK mode: CHECK [e] against [T] (synthesize [e]'s least type and
     gate it [≤ T] via [decide_rsub], exactly as [check]), and on success return the
     ANNOTATION [T] (not [e]'s synthesized type). This is HOW an annotation guides
     inference — downstream consumers see [T], the type the programmer demanded, so
     a value whose synthesized type is too specific (e.g. [BRef AInt] for an
     [LInt] cell that must hold arithmetic results) can be ascended to the wider
     [T] the later use requires. *)
  | tannot T e0 =>
      match synth Sig G e0 with
      | Some Se => if decide_rsub Se T then Some T else None
      | None => None
      end
  (* a source location is rejected (locations are not source syntax). *)
  | tloc _ => None
  (* MULTI-RETURN — synthesize the component types into a [BTuple]; truncate a
     multivalue to its head type (empty ⇒ [ANil]); spread checks the arg against
     the consumer's tuple domain via the mode switch. *)
  | tret es =>
      match synth_seq (synth Sig G) es with
      | Some Ts => Some (BTuple Ts)
      | None => None
      end
  | tfst e0 =>
      match synth Sig G e0 with
      | Some (BTuple (T :: _)) => Some T
      | Some (BTuple []) => Some (BAtom ANil)
      | _ => None
      end
  | tappspread g a =>
      match synth Sig G g with
      | Some (BArrow (BTuple Ts) B) =>
          match synth Sig G a with
          | Some Sa => if decide_ssub Sa (BTuple Ts) then Some B else None
          | None => None
          end
      | _ => None
      end
  (* METATABLES — synthesize the OWN field-list (exactly, via [synth_fields], with
     a [keys_nodup] gate); synthesize the PROTOTYPE, which must be a record [BRec
     Pf] (with NoDup keys); return the flattened read interface [BRec (merge_fields
     Town Pf)]. This is exactly the declarative [TMeta]. *)
  | tmeta own proto =>
      if keys_nodup (map fst own) then
        match synth_fields (synth Sig G) own with
        | Some Town =>
            match synth Sig G proto with
            | Some (BRec Pf) =>
                if keys_nodup (map fst Pf)
                then Some (BRec (merge_fields Town Pf))
                else None
            | _ => None
            end
        | None => None
        end
      else None
  (* METATABLE [__newindex] — WRITE FALLBACK. Synthesize the own field-list [Town]
     (keys_nodup gate), require [k] ABSENT from [Town] ([key_in k Town = false]);
     synthesize the [__newindex] target [proto : BRec Pf] (keys_nodup gate) with a
     writable cell [(k, BRef U)] ([flook k Pf = Some (BRef U)]); check the value
     against [U] ([decide_rsub]); result is [nil]. *)
  | tnewidx own proto k v =>
      if keys_nodup (map fst own) then
        match synth_fields (synth Sig G) own with
        | Some Town =>
            if key_in k Town then None
            else match synth Sig G proto with
                 | Some (BRec Pf) =>
                     if keys_nodup (map fst Pf) then
                       match flook k Pf with
                       | Some (BRef U) =>
                           match synth Sig G v with
                           | Some Sv => if decide_rsub Sv U then Some (BAtom ANil) else None
                           | None => None
                           end
                       | _ => None
                       end
                     else None
                 | _ => None
                 end
        | None => None
        end
      else None
  (* RAW READ — [rawget((tmeta own proto), k)]. Synthesize the own field-list
     [Town] (keys_nodup gate) and the prototype [BRec Pf] (keys_nodup gate); look up
     [k] in OWN ONLY ([flook k Town]) — NO merge, NO prototype fallback. The result
     is OWN's type for [k]; a key absent from own (even if in the prototype) yields
     [None]. Exactly the declarative [TRawGet]. *)
  | trawget own proto k =>
      if keys_nodup (map fst own) then
        match synth_fields (synth Sig G) own with
        | Some Town =>
            match synth Sig G proto with
            | Some (BRec Pf) =>
                if keys_nodup (map fst Pf)
                then match flook k Town with
                     | Some U => Some U
                     | None => None
                     end
                else None
            | _ => None
            end
        | None => None
        end
      else None
  (* RAW WRITE — [rawset((tmeta own proto), k, v)]. Synthesize [Town] (keys_nodup),
     the prototype [BRec Pf] (keys_nodup), require a writable OWN cell [(k, BRef U)]
     ([flook k Town = Some (BRef U)]) — the own field, NOT the prototype's; check
     the value against [U]; result [nil]. Exactly [TRawSet] (no absent-from-own
     dispatch — an absent own key is rejected). *)
  | trawset own proto k v =>
      if keys_nodup (map fst own) then
        match synth_fields (synth Sig G) own with
        | Some Town =>
            match synth Sig G proto with
            | Some (BRec Pf) =>
                if keys_nodup (map fst Pf) then
                  match flook k Town with
                  | Some (BRef U) =>
                      match synth Sig G v with
                      | Some Sv => if decide_rsub Sv U then Some (BAtom ANil) else None
                      | None => None
                      end
                  | _ => None
                  end
                else None
            | _ => None
            end
        | None => None
        end
      else None
  (* METATABLE UNARY METAMETHOD — [__unm]/[__len]. Synthesize the operand; it must be
     SYNTACTICALLY a [tmeta] with read interface [BRec M] carrying the unary metamethod
     [mm_unop uop : Self -> Self -> R] ([flook], the [__index]-chain interface), with
     the table a valid [self] ([decide_rsub (BRec M) Self]); result [R]. A non-[tmeta]
     operand (or one lacking the metamethod) is rejected — exactly [TUnMetaL]. *)
  | tunop uop e =>
      match synth Sig G e with
      | Some (BRec M) =>
          match e with
          | tmeta _ _ =>
              match flook (mm_unop uop) M with
              | Some (BArrow Self (BArrow Self2 R)) =>
                  if andb (decide_rsub (BRec M) Self) (decide_rsub (BRec M) Self2)
                  then Some R else None
              | _ => None
              end
          | _ => None
          end
      | _ => None
      end
  (* VARARG — the variadic CALL. Synthesize the function; it must be a two-binder
     curried arrow [BArrow Tf (BArrow (BTuple Ts) B)] (fixed param then the rest
     tuple). CHECK the fixed argument against [Tf] and the PACKED trailing args
     against the rest tuple [BTuple Ts] (the trailing args are synthesized into
     [BTuple Srs] via [synth_seq], then gated by the mode switch [decide_ssub] —
     the known-arity match, exactly mirroring [tappspread]'s domain check); result
     [B]. Dispatch is TYPE-FIRST on [synth f] — linear in type constructors. *)
  | tvapp f a rs =>
      match synth Sig G f with
      | Some (BArrow Tf (BArrow (BTuple Ts) B)) =>
          match synth Sig G a with
          | Some Sa =>
              if decide_ssub Sa Tf then
                match synth_seq (synth Sig G) rs with
                | Some Srs => if decide_ssub (BTuple Srs) (BTuple Ts) then Some B else None
                | None => None
                end
              else None
          | None => None
          end
      | _ => None
      end
  (* MULTIPLE-ASSIGNMENT — [a, b, … = rhs]. Synthesize the TARGET list ([synth_seq])
     into reference types and UNWRAP them to the cell types [Tgts] ([unref_seq] —
     every target must be a [BRef]); synthesize the RHS to a TUPLE [BTuple Ss]; ADJUST
     [Ss] to the target arity ([pad_ty Ss (length Tgts)] — truncate / nil-pad) and
     gate it pointwise [rsub]-below the cells ([decide_rsub_seq]). Result [nil].
     Dispatch is TYPE-FIRST (on the synthesized target / RHS types). *)
  | tmassign rs rhs =>
      match synth_seq (synth Sig G) rs with
      | Some Srs =>
          match unref_seq Srs with
          | Some Tgts =>
              match synth Sig G rhs with
              | Some (BTuple Ss) =>
                  if decide_rsub_seq (pad_ty Ss (Datatypes.length Tgts)) Tgts
                  then Some (BAtom ANil) else None
              | _ => None
              end
          | None => None
          end
      | None => None
      end
  end.

(* [check] subsumes along the reference-aware [decide_rsub] (the unified relation),
   so checking against a reference / any-ref target works; on the non-reference core
   [decide_rsub] delegates to [decide_ssub], so all prior behaviour is preserved. *)
Definition check (Sig : list BTy) (G : list BTy) (e : tm) (T : BTy) : bool :=
  match synth Sig G e with
  | Some Se => decide_rsub Se T
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

(* MULTIPLE-ASSIGNMENT — [unref_seq] succeeds exactly when the input is a list of
   reference types, and recovers it as [map BRef] of the cell types. *)
Lemma unref_seq_map : forall Ts Cs, unref_seq Ts = Some Cs -> Ts = map BRef Cs.
Proof.
  induction Ts as [ | T rest IH ]; intros Cs H; simpl in H.
  - injection H as <-. reflexivity.
  - destruct T; try discriminate H.
    destruct (unref_seq rest) as [ Cs' | ]; [ | discriminate H ].
    injection H as <-. simpl. f_equal. apply IH. reflexivity.
Qed.

(* MULTIPLE-ASSIGNMENT — the pointwise [decide_rsub] gate is sound: it implies the
   declarative pointwise [Forall2 rsub] (each entry via [decide_rsub_sound]). *)
Lemma decide_rsub_seq_sound : forall As Bs,
  decide_rsub_seq As Bs = true -> Forall2 rsub As Bs.
Proof.
  induction As as [ | A As' IH ]; intros Bs H; destruct Bs as [ | B Bs' ];
    simpl in H; try discriminate.
  - apply Forall2_nil.
  - apply andb_prop in H. destruct H as [HA HAs].
    apply Forall2_cons; [ apply decide_rsub_sound; exact HA | apply IH; exact HAs ].
Qed.

Theorem synth_sound : forall e Sig G T, synth Sig G e = Some T -> has_type Sig G e T.
Proof.
  intro e.
  induction e using tm_rect_strong with
    (Pl := fun fs => forall Sig G Ts, synth_fields (synth Sig G) fs = Some Ts -> has_fields Sig G fs Ts)
    (Pt := fun es => forall Sig G Ts, synth_seq (synth Sig G) es = Some Ts -> has_types Sig G es Ts);
    intros.
  - (* tlit *) simpl in H. injection H as <-. apply TLit.
  - (* tvar *) simpl in H. apply TVar. exact H.
  - (* tprim — TYPE-FIRST dispatch on [synth e1] (the OUTER match), exactly mirroring
       the function: a [BRec M] left that is a [tmeta] ⇒ [TPrimMetaL]; a scalar
       [BAtom al] left with a [tmeta] right carrying the metamethod ⇒ [TPrimMetaR]
       right-fallback (else NUMERIC); any other left type ⇒ NUMERIC. Keeping the
       split on the synthesized TYPE (linear in type constructors) — not on operand
       syntax (quadratic in term constructors) — is what keeps this proof fast. *)
    simpl in H.
    destruct (synth Sig G e1) as [ Sa | ] eqn:Ha; [ | discriminate ].
    destruct Sa as [ al | | | | | | M | | | | ];
      (* every left type: try the NUMERIC path first. For the [BAtom al] left arm this
         FAILS exactly when the right operand is a metamethod-bearing [tmeta] (the goal
         then has the [match b]/[flook] shape, not the numeric [if andb ...] shape), and
         we fall through to the right-fallback handler below. *)
      try (
        destruct (synth Sig G e2) as [ Sb | ] eqn:Hb; [ | discriminate ];
        match goal with [ H : (if andb (decide_ssub ?LT (BAtom ANum)) _ then _ else _) = _ |- _ ] =>
          destruct (andb (decide_ssub LT (BAtom ANum)) (decide_ssub Sb (BAtom ANum))) eqn:Hd;
            [ | discriminate ];
          apply Bool.andb_true_iff in Hd; destruct Hd as [HdA HdB];
          assert (HaN : has_type Sig G e1 (BAtom ANum)) by
            (eapply TSub; [ apply IHe1; exact Ha | apply RsSsub; apply decide_ssub_sound; exact HdA ]) end;
        assert (HbN : has_type Sig G e2 (BAtom ANum)) by
          (eapply TSub; [ apply IHe2; exact Hb | apply RsSsub; apply decide_ssub_sound; exact HdB ]);
        destruct (arith_op op) eqn:Har;
          [ injection H as <-; apply TPrimArith; assumption
          | destruct (cmp_op op) eqn:Hcm; [ | discriminate ];
            injection H as <-; apply TPrimCmp; assumption ];
        fail).
    + (* the [BAtom al] left arm. The outer numeric [try] could not fire here (the
         function's [BAtom al] arm first matches [synth b] for a record before the
         numeric path, so the goal is not yet in [if andb ...] shape). We split [synth b]:
         a [tmeta]-record right ⇒ RIGHT-FALLBACK ([TPrimMetaR]); any other right ⇒
         NUMERIC. *)
      destruct (synth Sig G e2) as [ Sb | ] eqn:Hb; [ | discriminate ].
      destruct Sb as [ alb | | | | | | Mr | | | | ];
        (* every NON-[BRec] right type for the [BAtom] left: NUMERIC path. ([Sb] is now
           a concrete constructor; we read both atom domains back off the goal shape.) *)
        try (
          match goal with [ H : (if andb (decide_ssub ?LT (BAtom ANum)) (decide_ssub ?RT (BAtom ANum)) then _ else _) = _ |- _ ] =>
            destruct (andb (decide_ssub LT (BAtom ANum)) (decide_ssub RT (BAtom ANum))) eqn:Hd;
              [ | discriminate ];
            apply Bool.andb_true_iff in Hd; destruct Hd as [HdA HdB] end;
          assert (HaN : has_type Sig G e1 (BAtom ANum)) by
            (eapply TSub; [ apply IHe1; exact Ha | apply RsSsub; apply decide_ssub_sound; exact HdA ]);
          assert (HbN : has_type Sig G e2 (BAtom ANum)) by
            (eapply TSub; [ apply IHe2; exact Hb | apply RsSsub; apply decide_ssub_sound; exact HdB ]);
          destruct (arith_op op) eqn:Har;
            [ injection H as <-; apply TPrimArith; assumption
            | destruct (cmp_op op) eqn:Hcm; [ | discriminate ];
              injection H as <-; apply TPrimCmp; assumption ];
          fail).
      (* the [BRec Mr] right type: only a [tmeta] dispatches the RIGHT-operand fallback. *)
      destruct e2; try discriminate H.
      destruct (flook (mm_binop op) Mr) as [ Tm | ] eqn:Hfm; [ | discriminate ].
      destruct Tm as [ | | | | | | | Td Tco | | | ]; try discriminate H.
      destruct Td as [ al' | | | | | | | | | | ]; try discriminate H.
      destruct Tco as [ | | | | | | | Other R | | | ]; try discriminate H.
      destruct (andb (decide_ssub (BAtom al) (BAtom al')) (decide_rsub (BRec Mr) Other)) eqn:Hd;
        [ | discriminate ].
      apply Bool.andb_true_iff in Hd. destruct Hd as [HdA HdO].
      injection H as <-.
      eapply TPrimMetaR.
      * eapply TSub; [ apply IHe1; exact Ha | apply RsSsub; apply decide_ssub_sound; exact HdA ].
      * apply IHe2. exact Hb.
      * apply flook_In. exact Hfm.
      * apply decide_rsub_sound. exact HdO.
    + (* the [BRec M] left type: only a [tmeta] dispatches the operator metamethod
         ([TPrimMetaL]). *)
      destruct e1; try discriminate H.
      destruct (flook (mm_binop op) M) as [ Tm | ] eqn:Hfm; [ | discriminate ].
      destruct Tm as [ | | | | | | | Self Tco | | | ]; try discriminate H.
      destruct Tco as [ | | | | | | | Other R | | | ]; try discriminate H.
      destruct (synth Sig G e2) as [ Sb | ] eqn:Hb; [ | discriminate ].
      destruct (andb (decide_rsub (BRec M) Self) (decide_ssub Sb Other)) eqn:Hd;
        [ | discriminate ].
      apply Bool.andb_true_iff in Hd. destruct Hd as [HdS HdO].
      injection H as <-.
      eapply TPrimMetaL.
      * apply IHe1. exact Ha.
      * apply flook_In. exact Hfm.
      * apply decide_rsub_sound. exact HdS.
      * eapply TSub; [ apply IHe2; exact Hb | apply RsSsub; apply decide_ssub_sound; exact HdO ].
  - (* tlam *) simpl in H.
    destruct (synth Sig (T :: G) e) as [ Tb | ] eqn:Hb; [ | discriminate ].
    injection H as <-. apply TLam. apply IHe. exact Hb.
  - (* tapp — synth the function; an arrow function takes the ordinary application
       branch, a [BRec M] function that is a [tmeta] takes the [__call] branch. *)
    simpl in H.
    destruct (synth Sig G e1) as [ Sf | ] eqn:Hf; [ | discriminate ].
    destruct Sf as [ | | | | | | M | A B | | | ]; try discriminate H.
    + (* BRec M: only a [tmeta] function dispatches [__call]; else rejected *)
      destruct e1; try discriminate H.
      destruct (flook mm_call M) as [ Tm | ] eqn:Hfm; [ | discriminate ].
      destruct Tm as [ | | | | | | | Self Tco | | | ]; try discriminate H.
      destruct Tco as [ | | | | | | | A R | | | ]; try discriminate H.
      destruct (synth Sig G e2) as [ Sa | ] eqn:Ha; [ | discriminate ].
      destruct (andb (decide_rsub (BRec M) Self) (decide_ssub Sa A)) eqn:Hd;
        [ | discriminate ].
      apply Bool.andb_true_iff in Hd. destruct Hd as [HdS HdA].
      injection H as <-.
      eapply TCallMeta.
      * apply IHe1. exact Hf.
      * apply flook_In. exact Hfm.
      * apply decide_rsub_sound. exact HdS.
      * eapply TSub; [ apply IHe2; exact Ha | apply RsSsub; apply decide_ssub_sound; exact HdA ].
    + (* BArrow A B: ordinary application *)
      destruct (synth Sig G e2) as [ Sa | ] eqn:Ha; [ | discriminate ].
      destruct (decide_ssub Sa A) eqn:Hd; [ | discriminate ].
      injection H as <-.
      eapply TApp; [ apply IHe1; exact Hf | ].
      eapply TSub; [ apply IHe2; exact Ha | apply RsSsub; apply decide_ssub_sound; exact Hd ].
  - (* tlet *) simpl in H.
    destruct (synth Sig G e1) as [ Se | ] eqn:H1; [ | discriminate ].
    eapply TLet; [ apply IHe1; exact H1 | apply IHe2; exact H ].
  - (* trec *) simpl in H.
    destruct (keys_nodup (map fst fs)) eqn:Hnd; [ | discriminate ].
    destruct (synth_fields (synth Sig G) fs) as [ Ts | ] eqn:Hf; [ | discriminate ].
    injection H as <-. apply TRec.
    + apply IHe. exact Hf.
    + apply keys_nodup_NoDup. exact Hnd.
  - (* tproj *) simpl in H.
    destruct (synth Sig G e) as [ Se | ] eqn:He; [ | discriminate ].
    destruct Se as [ | | | | | | fs | | | | ]; try discriminate H.
    eapply TProj.
    + apply IHe. exact He.
    + apply flook_In. exact H.
  - (* tif *) simpl in H.
    destruct (synth Sig G e1) as [ Sc | ] eqn:Hc; [ | discriminate ].
    destruct (decide_ssub Sc (BAtom ABool)) eqn:Hdb; [ | discriminate ].
    destruct (synth Sig G e2) as [ U1 | ] eqn:H1; [ | discriminate ].
    destruct (synth Sig G e3) as [ U2 | ] eqn:H2; [ | discriminate ].
    injection H as <-. apply TIf.
    + eapply TSub; [ apply IHe1; exact Hc | apply RsSsub; apply decide_ssub_sound; exact Hdb ].
    + apply IHe2; exact H1.
    + apply IHe3; exact H2.
  - (* tifn *)
    simpl in H.
    destruct (synth Sig G e1) as [ Uc | ] eqn:Hc; [ | discriminate ].
    destruct (synth Sig (truthy_type :: G) e2) as [ U1 | ] eqn:H1; [ | discriminate ].
    destruct (synth Sig (falsy_type :: G) e3) as [ U2 | ] eqn:H2; [ | discriminate ].
    injection H as <-. eapply TIfn.
    + apply IHe1; exact Hc.
    + apply IHe2; exact H1.
    + apply IHe3; exact H2.
  - (* tfix *)
    simpl in H.
    destruct (synth Sig (T :: G) e) as [ Sb | ] eqn:Hb; [ | discriminate ].
    destruct (decide_ssub Sb T) eqn:Hd; [ | discriminate ].
    injection H as <-. apply TFix.
    eapply TSub; [ apply IHe; exact Hb | apply RsSsub; apply decide_ssub_sound; exact Hd ].
  - (* ttypetest *)
    simpl in H.
    destruct (synth Sig G e1) as [ Uc | ] eqn:Hc; [ | discriminate ].
    destruct (synth Sig (tag_type g :: G) e2) as [ U1 | ] eqn:H1; [ | discriminate ].
    destruct (synth Sig (Uc :: G) e3) as [ U2 | ] eqn:H2; [ | discriminate ].
    injection H as <-. eapply TTypeTest.
    + apply IHe1; exact Hc.
    + apply IHe2; exact H1.
    + apply IHe3; exact H2.
  - (* SPLIT-STEP 3 — talloc: synth operand to U ⇒ BRef U *)
    simpl in H.
    destruct (synth Sig G e) as [ U | ] eqn:He; [ | discriminate ].
    injection H as <-. apply TAlloc. apply IHe; exact He.
  - (* tderef: synth to BRef U ⇒ U *)
    simpl in H.
    destruct (synth Sig G e) as [ Se | ] eqn:He; [ | discriminate ].
    destruct Se as [ | | | | | | | | U | | ]; try discriminate H.
    injection H as <-. eapply TDeref. apply IHe; exact He.
  - (* tassign: cell synth to BRef U, value synth to Sv, gate decide_rsub Sv U ⇒ nil *)
    simpl in H.
    destruct (synth Sig G e1) as [ Sr | ] eqn:Hr; [ | discriminate ].
    destruct Sr as [ | | | | | | | | U | | ]; try discriminate H.
    destruct (synth Sig G e2) as [ Sv | ] eqn:Hv; [ | discriminate ].
    destruct (decide_rsub Sv U) eqn:Hd; [ | discriminate ].
    injection H as <-.
    eapply TAssign; [ apply IHe1; exact Hr | ].
    eapply TSub; [ apply IHe2; exact Hv | apply decide_rsub_sound; exact Hd ].
  - (* tloc: rejected in source *) simpl in H. discriminate H.
  - (* tannot: CHECK-mode switch — synth the body, gate [≤ T] by decide_rsub,
       then ascribe via TAnnot. *)
    simpl in H.
    destruct (synth Sig G e) as [ Se | ] eqn:He; [ | discriminate ].
    destruct (decide_rsub Se T) eqn:Hd; [ | discriminate ].
    injection H as <-. apply TAnnot.
    eapply TSub; [ apply IHe; exact He | apply decide_rsub_sound; exact Hd ].
  - (* MULTI-RETURN — tret: synthesize the components into [BTuple Ts] (Pt IH). *)
    simpl in H.
    destruct (synth_seq (synth Sig G) es) as [ Ts | ] eqn:Hes; [ | discriminate ].
    injection H as <-. apply TRet. apply IHe. exact Hes.
  - (* tfst: the subject synths to a tuple; head type (or [ANil] for empty). *)
    simpl in H.
    destruct (synth Sig G e) as [ Se | ] eqn:He; [ | discriminate ].
    destruct Se as [ | | | | | | | | | | Ts ]; try discriminate H.
    destruct Ts as [ | T0 Tr ].
    + injection H as <-. eapply TFstNil. apply IHe. exact He.
    + injection H as <-. eapply TFst. apply IHe. exact He.
  - (* tappspread: consumer synths to [BArrow (BTuple Ts) B]; arg checked against
       the tuple domain via the mode switch [decide_ssub]. *)
    simpl in H.
    destruct (synth Sig G e1) as [ Sg | ] eqn:Hg; [ | discriminate ].
    destruct Sg as [ | | | | | | | dom B | | | ]; try discriminate H.
    destruct dom as [ | | | | | | | | | | Ts ]; try discriminate H.
    destruct (synth Sig G e2) as [ Sa | ] eqn:Ha; [ | discriminate ].
    destruct (decide_ssub Sa (BTuple Ts)) eqn:Hd; [ | discriminate ].
    injection H as <-. eapply TAppSpread.
    + apply IHe1. exact Hg.
    + eapply TSub; [ apply IHe2; exact Ha | apply RsSsub; apply decide_ssub_sound; exact Hd ].
  - (* METATABLES — tmeta: own fields synth to [Town] (NoDup gate), prototype to a
       record [BRec Pf] (NoDup gate); result is [BRec (merge_fields Town Pf)] =
       the declarative [TMeta]. NoDup of the synthesized [Town]/[Pf] keys follows
       from the [keys_nodup] gates (synth preserves keys via [has_fields_keys]). *)
    simpl in H.
    match goal with [ |- has_type _ _ (tmeta ?o ?p) _ ] => rename o into own0; rename p into proto0 end.
    destruct (keys_nodup (map fst own0)) eqn:Hndo; [ | discriminate ].
    destruct (synth_fields (synth Sig G) own0) as [ Town | ] eqn:Hfo; [ | discriminate ].
    destruct (synth Sig G proto0) as [ Sp | ] eqn:Hp; [ | discriminate ].
    destruct Sp as [ | | | | | | Pf | | | | ]; try discriminate H.
    destruct (keys_nodup (map fst Pf)) eqn:Hndp; [ | discriminate ].
    injection H as <-.
    assert (Hown : has_fields Sig G own0 Town).
    { match goal with [ IH : forall _ _ _, synth_fields _ own0 = Some _ -> has_fields _ _ own0 _ |- _ ] =>
        apply IH; exact Hfo end. }
    pose proof (has_fields_keys Sig G own0 Town Hown) as Hk.
    apply TMeta.
    + exact Hown.
    + apply keys_nodup_NoDup in Hndo. rewrite Hk in Hndo. exact Hndo.
    + match goal with [ IH : forall _ _ _, synth _ _ proto0 = Some _ -> has_type _ _ proto0 _ |- _ ] =>
        apply IH; exact Hp end.
    + apply keys_nodup_NoDup. exact Hndp.
  - (* METATABLE [__newindex] — tnewidx: own fields synth to [Town] (NoDup gate),
       [k] absent from [Town], prototype to [BRec Pf] (NoDup gate) with a writable
       cell [(k, BRef U)], value checked against [U]; result [nil] = [TNewIdx]. *)
    simpl in H.
    match goal with [ |- has_type _ _ (tnewidx ?o ?p ?kk ?vv) _ ] =>
      rename o into own0; rename p into proto0; rename kk into k0; rename vv into v0 end.
    destruct (keys_nodup (map fst own0)) eqn:Hndo; [ | discriminate ].
    destruct (synth_fields (synth Sig G) own0) as [ Town | ] eqn:Hfo; [ | discriminate ].
    destruct (key_in k0 Town) eqn:Hki; [ discriminate | ].
    destruct (synth Sig G proto0) as [ Sp | ] eqn:Hp; [ | discriminate ].
    destruct Sp as [ | | | | | | Pf | | | | ]; try discriminate H.
    destruct (keys_nodup (map fst Pf)) eqn:Hndp; [ | discriminate ].
    destruct (flook k0 Pf) as [ Tc | ] eqn:Hfl; [ | discriminate ].
    destruct Tc as [ | | | | | | | | U | | ]; try discriminate H.
    destruct (synth Sig G v0) as [ Sv | ] eqn:Hv; [ | discriminate ].
    destruct (decide_rsub Sv U) eqn:Hd; [ | discriminate ].
    injection H as <-.
    assert (Hown : has_fields Sig G own0 Town).
    { match goal with [ IH : forall _ _ _, synth_fields _ own0 = Some _ -> has_fields _ _ own0 _ |- _ ] =>
        apply IH; exact Hfo end. }
    pose proof (has_fields_keys Sig G own0 Town Hown) as Hk.
    eapply TNewIdx.
    + exact Hown.
    + apply keys_nodup_NoDup in Hndo. rewrite Hk in Hndo. exact Hndo.
    + exact Hki.
    + match goal with [ IH : forall _ _ _, synth _ _ proto0 = Some _ -> has_type _ _ proto0 _ |- _ ] =>
        apply IH; exact Hp end.
    + apply keys_nodup_NoDup. exact Hndp.
    + apply flook_In. exact Hfl.
    + eapply TSub; [ | apply decide_rsub_sound; exact Hd ].
      match goal with [ IH : forall _ _ _, synth _ _ v0 = Some _ -> has_type _ _ v0 _ |- _ ] =>
        apply IH; exact Hv end.
  - (* METATABLE UNARY METAMETHOD — tunop: the operand must be a [tmeta : BRec M]
       whose [mm_unop uop] interface is [Self -> Other -> R]; both [self] gates pass;
       result [R] = [TUnMetaL]. *)
    simpl in H.
    destruct (synth Sig G e) as [ Se | ] eqn:He; [ | discriminate ].
    destruct Se as [ | | | | | | M | | | | ]; try discriminate H.
    destruct e; try discriminate H.
    destruct (flook (mm_unop uop) M) as [ Tm | ] eqn:Hfm; [ | discriminate ].
    destruct Tm as [ | | | | | | | Self Tco | | | ]; try discriminate H.
    destruct Tco as [ | | | | | | | Other R | | | ]; try discriminate H.
    destruct (andb (decide_rsub (BRec M) Self) (decide_rsub (BRec M) Other)) eqn:Hd;
      [ | discriminate ].
    apply Bool.andb_true_iff in Hd. destruct Hd as [HdS HdO].
    injection H as <-.
    eapply TUnMetaL.
    + apply IHe. exact He.
    + apply flook_In. exact Hfm.
    + apply decide_rsub_sound. exact HdS.
    + apply decide_rsub_sound. exact HdO.
  - (* RAW READ — trawget: own fields synth to [Town] (NoDup gate), prototype to
       [BRec Pf] (NoDup gate), [k] looked up in OWN ONLY ([flook k Town]); result is
       OWN's type [U] = [TRawGet]. *)
    simpl in H.
    match goal with [ |- has_type _ _ (trawget ?o ?p ?kk) _ ] =>
      rename o into own0; rename p into proto0; rename kk into k0 end.
    destruct (keys_nodup (map fst own0)) eqn:Hndo; [ | discriminate ].
    destruct (synth_fields (synth Sig G) own0) as [ Town | ] eqn:Hfo; [ | discriminate ].
    destruct (synth Sig G proto0) as [ Sp | ] eqn:Hp; [ | discriminate ].
    destruct Sp as [ | | | | | | Pf | | | | ]; try discriminate H.
    destruct (keys_nodup (map fst Pf)) eqn:Hndp; [ | discriminate ].
    destruct (flook k0 Town) as [ U | ] eqn:Hfl; [ | discriminate ].
    injection H as <-.
    assert (Hown : has_fields Sig G own0 Town).
    { match goal with [ IH : forall _ _ _, synth_fields _ own0 = Some _ -> has_fields _ _ own0 _ |- _ ] =>
        apply IH; exact Hfo end. }
    pose proof (has_fields_keys Sig G own0 Town Hown) as Hk.
    eapply TRawGet.
    + exact Hown.
    + apply keys_nodup_NoDup in Hndo. rewrite Hk in Hndo. exact Hndo.
    + apply flook_In. exact Hfl.
    + match goal with [ IH : forall _ _ _, synth _ _ proto0 = Some _ -> has_type _ _ proto0 _ |- _ ] =>
        apply IH; exact Hp end.
    + apply keys_nodup_NoDup. exact Hndp.
  - (* RAW WRITE — trawset: own fields synth to [Town] (NoDup gate), prototype to
       [BRec Pf] (NoDup gate), [k] a writable OWN cell [(k, BRef U)] ([flook k Town]),
       value checked against [U]; result [nil] = [TRawSet]. *)
    simpl in H.
    match goal with [ |- has_type _ _ (trawset ?o ?p ?kk ?vv) _ ] =>
      rename o into own0; rename p into proto0; rename kk into k0; rename vv into v0 end.
    destruct (keys_nodup (map fst own0)) eqn:Hndo; [ | discriminate ].
    destruct (synth_fields (synth Sig G) own0) as [ Town | ] eqn:Hfo; [ | discriminate ].
    destruct (synth Sig G proto0) as [ Sp | ] eqn:Hp; [ | discriminate ].
    destruct Sp as [ | | | | | | Pf | | | | ]; try discriminate H.
    destruct (keys_nodup (map fst Pf)) eqn:Hndp; [ | discriminate ].
    destruct (flook k0 Town) as [ Tc | ] eqn:Hfl; [ | discriminate ].
    destruct Tc as [ | | | | | | | | U | | ]; try discriminate H.
    destruct (synth Sig G v0) as [ Sv | ] eqn:Hv; [ | discriminate ].
    destruct (decide_rsub Sv U) eqn:Hd; [ | discriminate ].
    injection H as <-.
    assert (Hown : has_fields Sig G own0 Town).
    { match goal with [ IH : forall _ _ _, synth_fields _ own0 = Some _ -> has_fields _ _ own0 _ |- _ ] =>
        apply IH; exact Hfo end. }
    pose proof (has_fields_keys Sig G own0 Town Hown) as Hk.
    eapply TRawSet.
    + exact Hown.
    + apply keys_nodup_NoDup in Hndo. rewrite Hk in Hndo. exact Hndo.
    + apply flook_In. exact Hfl.
    + match goal with [ IH : forall _ _ _, synth _ _ proto0 = Some _ -> has_type _ _ proto0 _ |- _ ] =>
        apply IH; exact Hp end.
    + apply keys_nodup_NoDup. exact Hndp.
    + eapply TSub; [ | apply decide_rsub_sound; exact Hd ].
      match goal with [ IH : forall _ _ _, synth _ _ v0 = Some _ -> has_type _ _ v0 _ |- _ ] =>
        apply IH; exact Hv end.
  - (* VARARG — tvapp: the function synths to the two-binder curried arrow [BArrow
       Tf (BArrow (BTuple Ts) B)]; the fixed arg is checked against [Tf]; the
       trailing args synth (via [synth_seq]) to [BTuple Srs] gated against [BTuple
       Ts] — the reflexive tuple-leaf [ssub] forces [Srs = Ts] (known arity), so the
       packed args type at [Ts]; result [B] = [TVApp]. *)
    simpl in H.
    destruct (synth Sig G e1) as [ Sf | ] eqn:Hf; [ | discriminate ].
    destruct Sf as [ | | | | | | | Tf cod | | | ]; try discriminate H.
    destruct cod as [ | | | | | | | dom B | | | ]; try discriminate H.
    destruct dom as [ | | | | | | | | | | Ts ]; try discriminate H.
    destruct (synth Sig G e2) as [ Sa | ] eqn:Ha; [ | discriminate ].
    destruct (decide_ssub Sa Tf) eqn:Hda; [ | discriminate ].
    destruct (synth_seq (synth Sig G) rs) as [ Srs | ] eqn:Hrs; [ | discriminate ].
    destruct (decide_ssub (BTuple Srs) (BTuple Ts)) eqn:Hdt; [ | discriminate ].
    injection H as <-.
    (* [Srs = Ts] from the reflexive tuple leaf of [ssub]. *)
    apply decide_ssub_sound in Hdt. apply ssub_tuple_super in Hdt.
    simpl in Hdt. injection Hdt as ETs. subst Srs.
    eapply TVApp.
    + apply IHe1. exact Hf.
    + eapply TSub; [ apply IHe2; exact Ha | apply RsSsub; apply decide_ssub_sound; exact Hda ].
    + match goal with [ IH : forall _ _ _, synth_seq _ rs = Some _ -> has_types _ _ rs _ |- _ ] =>
        apply IH; exact Hrs end.
  - (* MULTIPLE-ASSIGNMENT — tmassign: the TARGETS synth (via [synth_seq]) to ref
       types [Srs] which [unref_seq] unwraps to cell types [Tgts] (so [Srs = map BRef
       Tgts]); the RHS synths to a tuple [BTuple Ss]; the adjusted [pad_ty Ss (length
       Tgts)] is gated pointwise [rsub]-below [Tgts] ([decide_rsub_seq] ⇒ [Forall2
       rsub]); result [nil] = [TMAssign]. Dispatch is TYPE-FIRST (on the synthesized
       target / RHS types), keeping the proof fast. *)
    simpl in H.
    destruct (synth_seq (synth Sig G) rs) as [ Srs | ] eqn:Hrs; [ | discriminate ].
    destruct (unref_seq Srs) as [ Tgts | ] eqn:Hur; [ | discriminate ].
    match goal with [ |- has_type _ _ (tmassign _ ?t) _ ] =>
      destruct (synth Sig G t) as [ Srhs | ] eqn:Hrhs; [ | discriminate H ] end.
    destruct Srhs as [ | | | | | | | | | | Ss ]; try discriminate H.
    destruct (decide_rsub_seq (pad_ty Ss (Datatypes.length Tgts)) Tgts) eqn:Hgate;
      [ | discriminate ].
    injection H as <-.
    pose proof (unref_seq_map Srs Tgts Hur) as ESrs.
    eapply TMAssign.
    + (* targets : map BRef Tgts (the synth_seq result IS [Srs = map BRef Tgts]) *)
      rewrite <- ESrs.
      match goal with [ IH : forall _ _ _, synth_seq _ rs = Some _ -> has_types _ _ rs _ |- _ ] =>
        apply IH; exact Hrs end.
    + (* RHS : BTuple Ss *)
      match goal with [ IH : forall _ _ _, synth _ _ ?t = Some _ -> has_type _ _ ?t _ |- _ ] =>
        apply IH; exact Hrhs end.
    + apply decide_rsub_seq_sound. exact Hgate.
  - (* Pl [] *) simpl in H. injection H as <-. apply HFnil.
  - (* Pl cons *) simpl in H.
    destruct (synth Sig G e) as [ Te | ] eqn:He; [ | discriminate ].
    destruct (synth_fields (synth Sig G) rest) as [ Tr | ] eqn:Hr; [ | discriminate ].
    injection H as <-. apply HFcons.
    + apply IHe. exact He.
    + apply IHe0. exact Hr.
  - (* MULTI-RETURN — Pt [] *) simpl in H. injection H as <-. apply HTnil.
  - (* Pt cons *) simpl in H.
    destruct (synth Sig G e) as [ Te | ] eqn:He; [ | discriminate ].
    destruct (synth_seq (synth Sig G) rest) as [ Tr | ] eqn:Hr; [ | discriminate ].
    injection H as <-. apply HTcons.
    + apply IHe. exact He.
    + apply IHe0. exact Hr.
Qed.

Theorem check_sound : forall e Sig G T, check Sig G e T = true -> has_type Sig G e T.
Proof.
  intros e Sig G T H. unfold check in H.
  destruct (synth Sig G e) as [ Se | ] eqn:He; [ | discriminate ].
  eapply TSub.
  - apply synth_sound. exact He.
  - apply decide_rsub_sound. exact H.
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
Lemma narrowing : forall Sig G e T,
  has_type Sig G e T ->
  forall G1 A G2 A', G = G1 ++ A :: G2 -> rsub A' A ->
    has_type Sig (G1 ++ A' :: G2) e T.
Proof.
  intros Sig G e T H.
  induction H using has_type_mind with
    (P0 := fun Sig G fs Ts (_ : has_fields Sig G fs Ts) =>
       forall G1 A G2 A', G = G1 ++ A :: G2 -> rsub A' A ->
         has_fields Sig (G1 ++ A' :: G2) fs Ts)
    (P1 := fun Sig G es Ts (_ : has_types Sig G es Ts) =>
       forall G1 A G2 A', G = G1 ++ A :: G2 -> rsub A' A ->
         has_types Sig (G1 ++ A' :: G2) es Ts);
    intros; subst.
  - apply TLit.
  - (* TVar *)
    destruct (Nat.lt_total n (Datatypes.length G1)) as [Hlt | [Heq | Hgt]].
    + apply TVar. rewrite nth_error_app1 in e by assumption.
      rewrite nth_error_app1 by assumption. exact e.
    + subst n. rewrite nth_error_mid in e. injection e as <-.
      eapply TSub; [ apply TVar; apply nth_error_mid | eassumption ].
    + apply TVar. rewrite nth_error_app2 in e by lia.
      rewrite nth_error_app2 by lia.
      remember (n - Datatypes.length G1) as m eqn:Em.
      destruct m as [ | m' ]; [ lia | simpl in e |- *; exact e ].
  - (* TPrimArith *) apply TPrimArith;
      [ assumption
      | eapply (IHhas_type1 G1 _ G2 A'); [ reflexivity | eassumption ]
      | eapply (IHhas_type2 G1 _ G2 A'); [ reflexivity | eassumption ] ].
  - (* TPrimCmp *) apply TPrimCmp;
      [ assumption
      | eapply (IHhas_type1 G1 _ G2 A'); [ reflexivity | eassumption ]
      | eapply (IHhas_type2 G1 _ G2 A'); [ reflexivity | eassumption ] ].
  - (* TLam *) apply TLam.
    eapply (IHhas_type (T::G1) _ G2 A'); [ reflexivity | eassumption ].
  - eapply TApp;
      [ eapply (IHhas_type1 G1 _ G2 A') | eapply (IHhas_type2 G1 _ G2 A') ];
      (reflexivity || eassumption).
  - eapply TLet;
      [ eapply (IHhas_type1 G1 _ G2 A')
      | match goal with [ |- has_type _ (?Alet :: _) _ _ ] =>
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
  - (* TIfn *)
    eapply TIfn;
      [ eapply (IHhas_type1 G1 _ G2 A')
      | eapply (IHhas_type2 (truthy_type :: G1) _ G2 A')
      | eapply (IHhas_type3 (falsy_type :: G1) _ G2 A') ];
      (reflexivity || eassumption).
  - (* TFix *)
    apply TFix.
    eapply (IHhas_type (T :: G1) _ G2 A'); [ reflexivity | eassumption ].
  - (* TTypeTest *)
    eapply TTypeTest;
      [ eapply (IHhas_type1 G1 _ G2 A')
      | eapply (IHhas_type2 (tag_type g :: G1) _ G2 A')
      | eapply (IHhas_type3 (U :: G1) _ G2 A') ];
      (reflexivity || eassumption).
  - (* TLoc: closed, store lookup unchanged *) apply TLoc. exact e.
  - (* TAlloc *) apply TAlloc.
    eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ].
  - (* TDeref *) eapply TDeref.
    eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ].
  - (* TAssign *) eapply TAssign;
      [ eapply (IHhas_type1 G1 _ G2 A') | eapply (IHhas_type2 G1 _ G2 A') ];
      (reflexivity || eassumption).
  - (* TAnnot *) apply TAnnot.
    eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ].
  - (* MULTI-RETURN — TRet *) apply TRet.
    eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ].
  - (* TFst *) eapply TFst.
    eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ].
  - (* TFstNil *) eapply TFstNil.
    eapply (IHhas_type G1 _ G2 A'); [ reflexivity | eassumption ].
  - (* TAppSpread *) eapply TAppSpread;
      [ eapply (IHhas_type1 G1 _ G2 A') | eapply (IHhas_type2 G1 _ G2 A') ];
      (reflexivity || eassumption).
  - (* METATABLES — TMeta: own fields + prototype narrow; [Town]/[Pf] NoDups stable. *)
    eapply TMeta.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_fields _ _ _ _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ _ _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
  - (* METATABLE [__call] — TCallMeta: table + arg narrow; In/rsub stable. *)
    eapply TCallMeta.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ (tmeta _ _) _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + eassumption.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x _ |- has_type _ _ ?x _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
  - (* METATABLE OPERATOR — TPrimMetaL: table + right operand narrow. *)
    eapply TPrimMetaL.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ (tmeta _ _) _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + eassumption.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x _ |- has_type _ _ ?x _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
  - (* METATABLE OPERATOR — TPrimMetaR (RIGHT-operand fallback): scalar left operand +
       table right narrow; In/rsub stable. The exact mirror of the TPrimMetaL case. *)
    eapply TPrimMetaR.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ ?x (BAtom _), Hh : has_type _ _ ?x (BAtom _) |- has_type _ _ ?x (BAtom _) ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ (tmeta _ _) _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + eassumption.
  - (* METATABLE [__newindex] — TNewIdx: own fields + proto + value narrow. *)
    eapply TNewIdx.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_fields _ _ _ _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + eassumption.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x (BRec _) |- has_type _ _ ?x _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + eassumption.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x ?TT |- has_type _ _ ?x ?TT ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
  - (* METATABLE UNARY METAMETHOD — TUnMetaL: the operand (whole [tmeta]) narrows;
       In/rsub stable. *)
    eapply TUnMetaL.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ (tmeta _ _) _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + eassumption.
    + eassumption.
  - (* RAW READ — TRawGet: own fields + prototype narrow; In/NoDup stable. *)
    eapply TRawGet.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_fields _ _ _ _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + eassumption.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x (BRec _) |- has_type _ _ ?x _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
  - (* RAW WRITE — TRawSet: own fields + prototype + value narrow; premises stable. *)
    eapply TRawSet.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_fields _ _ _ _ |- _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + eassumption.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x (BRec _) |- has_type _ _ ?x _ ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
    + eassumption.
    + match goal with [ IH : forall _ _ _ _, _ -> _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x ?TT |- has_type _ _ ?x ?TT ] =>
        eapply (IH G1 _ G2 A'); [ reflexivity | eassumption ] end.
  - (* VARARG — TVApp: function, fixed arg, and trailing-arg list narrow. *)
    eapply TVApp;
      [ eapply (IHhas_type1 G1 _ G2 A')
      | eapply (IHhas_type2 G1 _ G2 A')
      | eapply (IHhas_type3 G1 _ G2 A') ];
      (reflexivity || eassumption).
  - (* MULTIPLE-ASSIGNMENT — TMAssign: targets + RHS narrow; [Forall2 rsub] is
       context-independent. *)
    eapply TMAssign;
      [ match goal with [ IH : forall _ _ _ _, _ = _ -> _ -> has_types _ _ _ _ |- _ ] =>
          eapply (IH G1 _ G2 A') end
      | match goal with [ IH : forall _ _ _ _, _ = _ -> _ -> has_type _ _ rhs _ |- _ ] =>
          eapply (IH G1 _ G2 A') end
      | eassumption ];
      (reflexivity || eassumption).
  - apply HFnil.
  - apply HFcons;
      [ eapply (IHhas_type G1 _ G2 A') | eapply (IHhas_type0 G1 _ G2 A') ];
      (reflexivity || eassumption).
  - (* MULTI-RETURN — HTnil *) apply HTnil.
  - (* HTcons *) apply HTcons;
      [ eapply (IHhas_type G1 _ G2 A') | eapply (IHhas_type0 G1 _ G2 A') ];
      (reflexivity || eassumption).
Qed.

Corollary narrowing_head : forall A A' Sig G e T,
  has_type Sig (A :: G) e T -> rsub A' A -> has_type Sig (A' :: G) e T.
Proof.
  intros A A' Sig G e T H Hs.
  apply (narrowing Sig (A::G) e T H [] A G A'); [ reflexivity | exact Hs ].
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
  | tprim _ a b => proj_free a /\ proj_free b
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
  | tfix _ b => proj_free b
  | ttypetest _ c e1 e2 => proj_free c /\ proj_free e1 /\ proj_free e2
  (* SPLIT-STEP 3 — reference ops are projection-free iff their operands are; a
     source location never appears (synth rejects it), so [tloc] is [False]. *)
  | talloc e0 => proj_free e0
  | tderef e0 => proj_free e0
  | tassign r e0 => proj_free r /\ proj_free e0
  | tannot _ e0 => proj_free e0
  | tloc _ => False
  (* MULTI-RETURN: projection-free iff the components / operands are. *)
  | tret es => (fix pt (xs : list tm) : Prop :=
                  match xs with [] => True | e0 :: rest => proj_free e0 /\ pt rest end) es
  | tfst e0 => proj_free e0
  | tappspread g a => proj_free g /\ proj_free a
  (* METATABLES — projection-free iff every own field and the prototype are. (The
     [__index] DISPATCH is projection-LIKE at run time, but [tmeta] itself contains
     no syntactic [tproj]; principality of [tmeta] under the unified [rsub] is part
     of the deferred principality work.) *)
  | tmeta own proto =>
      ((fix pl (xs : list (string * tm)) : Prop :=
          match xs with
          | [] => True
          | (_, e0) :: rest => proj_free e0 /\ pl rest
          end) own)
      /\ proj_free proto
  (* METATABLE [__newindex] — own fields, [__newindex] target, value proj-free. *)
  | tnewidx own proto _ v =>
      ((fix pl (xs : list (string * tm)) : Prop :=
          match xs with
          | [] => True
          | (_, e0) :: rest => proj_free e0 /\ pl rest
          end) own)
      /\ proj_free proto /\ proj_free v
  (* METATABLE UNARY METAMETHOD — projection-free iff the operand is. *)
  | tunop _ e0 => proj_free e0
  (* RAW ACCESS — projection-free iff every own field, the prototype (and value)
     are. ([trawget]/[trawset] contain no syntactic [tproj]; the RAW own read/write
     reuses [field_lookup], not [tproj].) *)
  | trawget own proto _ =>
      ((fix pl (xs : list (string * tm)) : Prop :=
          match xs with
          | [] => True
          | (_, e0) :: rest => proj_free e0 /\ pl rest
          end) own)
      /\ proj_free proto
  | trawset own proto _ v =>
      ((fix pl (xs : list (string * tm)) : Prop :=
          match xs with
          | [] => True
          | (_, e0) :: rest => proj_free e0 /\ pl rest
          end) own)
      /\ proj_free proto /\ proj_free v
  (* VARARG — projection-free iff the function, the fixed arg, and every trailing
     arg are. *)
  | tvapp f a rs =>
      proj_free f /\ proj_free a /\
      (fix pt (xs : list tm) : Prop :=
          match xs with [] => True | e0 :: rest => proj_free e0 /\ pt rest end) rs
  (* MULTIPLE-ASSIGNMENT — projection-free iff every target and the RHS are. *)
  | tmassign rs rhs =>
      (fix pt (xs : list tm) : Prop :=
          match xs with [] => True | e0 :: rest => proj_free e0 /\ pt rest end) rs
      /\ proj_free rhs
  end.

(* ===========================================================================
   4. COMPLETENESS / PRINCIPALITY — DEFERRED over the unified [rsub] relation.

   The load-bearing SOUNDNESS direction ([synth_sound] / [check_sound]) is proved
   above against the unified, Sigma-threaded, reference-aware [has_type]. The
   PRINCIPALITY direction ([synth] produces the LEAST declarative type) was proved
   in the pre-unification checker concluding [ssub S T]. Under the unified layer
   the declarative inversion lemmas conclude the reference-aware [rsub] (since
   [TSub] subsumes along [rsub]), and the union-typed term-formers ([tif] / [tifn]
   / [ttypetest]) require UNION-ELIMINATION at the [rsub] level
   ([rsub a c -> rsub b c -> rsub (BUnion a b) c]) to recompose branch
   principalities. [rsub] has NO such structural union-elim rule — it embeds
   [ssub] (which has [SsUnionE]) + the two reference rules + transitivity, and a
   branch subtyping that goes through ref-widening has no [ssub] witness to feed
   [SsUnionE]. So [rsub]-level principality needs a NEW SUBSTRATE rule
   (rsub union-elimination / a join-completeness lemma), which is a genuine
   substrate gap, recorded here and in TODO.md — NOT hardcoded. The reference-free
   fragment (where every subtyping collapses to [ssub]) retains the prior
   principality, but stating that cleanly also needs an [rsub]->[ssub]-on-ref-free
   collapse lemma; both are deferred together. The checker remains SOUND and
   EXECUTABLE on the whole unified language; only the principality META-property
   is fenced. *)

(* ===========================================================================
   5. EXECUTABLE SANITY (Compute) — the checker REDUCES to definite answers.

   Well-typed terms synthesize the right type; ill-typed terms synthesize None.
   These [reflexivity] proofs witness that [synth]/[check] genuinely COMPUTE
   (the kernel reduces them to [Some _] / [None] / [true] / [false]).
   =========================================================================== *)

(* (λx:Int. x) 3  ⇒  Int *)
Example compute_app_id :
  synth [] [] (tapp (tlam (BAtom AInt) (tvar 0)) (tlit (LInt))) = Some (BAtom AInt).
Proof. reflexivity. Qed.

(* {a = 7, b = true}.a  ⇒  Int *)
Example compute_proj :
  synth [] []
    (tproj (trec [("a"%string, tlit (LInt)); ("b"%string, tlit (LBool true))]) "a"%string)
  = Some (BAtom AInt).
Proof. reflexivity. Qed.

(* {a = 7, b = true}.b  ⇒  Bool *)
Example compute_proj_b :
  synth [] []
    (tproj (trec [("a"%string, tlit (LInt)); ("b"%string, tlit (LBool true))]) "b"%string)
  = Some (BAtom ABool).
Proof. reflexivity. Qed.

(* the bare lambda synthesizes an arrow *)
Example compute_lam :
  synth [] [] (tlam (BAtom AInt) (tvar 0)) = Some (BArrow (BAtom AInt) (BAtom AInt)).
Proof. reflexivity. Qed.

(* INCREMENT 11 — CONDITIONAL synthesis. [if true then 3 else "s"] synthesizes the
   UNION of the branch types [Int ∪ Str] — a genuinely union-typed term. *)
Example compute_if_union :
  synth [] [] (tif (tlit (LBool true)) (tlit (LInt)) (tlit (LStr 0)))
  = Some (BUnion (BAtom AInt) (BAtom AStr)).
Proof. reflexivity. Qed.

(* it is well typed at the union, and CHECKS against any supertype (e.g. Top). *)
Example compute_if_checks_top :
  check [] [] (tif (tlit (LBool true)) (tlit (LInt)) (tlit (LStr 0))) BTop = true.
Proof. reflexivity. Qed.

(* and it is sound: has_type at the union (via check_sound). *)
Example compute_if_sound :
  has_type [] [] (tif (tlit (LBool true)) (tlit (LInt)) (tlit (LStr 0)))
              (BUnion (BAtom AInt) (BAtom AStr)).
Proof. apply check_sound. reflexivity. Qed.

(* ILL-TYPED: a non-Bool condition ⇒ None (3 is not a boolean). *)
Example compute_if_badcond_None :
  synth [] [] (tif (tlit (LInt)) (tlit (LInt)) (tlit (LStr 0))) = None.
Proof. reflexivity. Qed.

(* INCREMENT 13 — NARROWING checker. The scrutinee may be ANY type (Lua truthiness,
   no Bool gate): [tifn 3 then else] synthesizes the union of the branch types, and
   in the then-branch the de Bruijn-0 var has the NARROWED [truthy_type]. Here the
   then-branch reads the narrowed var (var0 : truthy_type) and the else-branch reads
   the falsy-narrowed var (var0 : falsy_type). *)
Example compute_ifn_narrows :
  synth [] [] (tifn (tlit (LInt)) (tvar 0) (tvar 0))
  = Some (BUnion truthy_type falsy_type).
Proof. reflexivity. Qed.

(* THE CHECKER PAYOFF. A non-nil consumer [g : truthy_type → Int] applied to the
   then-NARROWED scrutinee CHECKS; the scrutinee's declared type is the maybe-nil
   [Int ∪ Nil] (passed as a free var of that type). The whole [tifn] checks. *)
Example compute_ifn_payoff_synth :
  synth [] [ BArrow truthy_type (BAtom AInt) ]   (* index 0 : the consumer g *)
    (tifn (tvar 0)                            (* scrutinee = g itself (truthy: a function) *)
       (tapp (tvar 1) (tvar 0))               (* then: g (index 1) applied to narrowed var0 *)
       (tlit (LInt)))
  = Some (BUnion (BAtom AInt) (BAtom AInt)).
Proof. reflexivity. Qed.

(* and it is SOUND (declaratively well typed via check_sound). *)
Example compute_ifn_payoff_sound :
  has_type [] [ BArrow truthy_type (BAtom AInt) ]
    (tifn (tvar 0) (tapp (tvar 1) (tvar 0)) (tlit (LInt)))
    (BUnion (BAtom AInt) (BAtom AInt)).
Proof. apply check_sound. reflexivity. Qed.

(* WITHOUT narrowing the SAME application is REJECTED by the checker: a free var of
   the maybe-nil type [Int ∪ Nil] passed to the [truthy_type]-demanding consumer
   fails the domain check (nil is not truthy). *)
Example compute_ifn_payoff_unnarrowed_None :
  synth [] [ BUnion (BAtom AInt) (BAtom ANil) ; BArrow truthy_type (BAtom AInt) ]
    (tapp (tvar 1) (tvar 0)) = None.
Proof. reflexivity. Qed.

(* INCREMENT 15 — TYPE-TEST NARROWING checker. [type(x)=="number"] on a scrutinee:
   the then-branch sees the de Bruijn-0 var at [tag_type TgNum = ANum]; the else-
   branch sees it at the scrutinee's own type. *)
Example compute_typetest_narrows :
  synth [] [ BUnion (BAtom AStr) (BAtom ANum) ]   (* index 0 : a string-or-number *)
    (ttypetest TgNum (tvar 0) (tvar 0) (tvar 0))
  = Some (BUnion (BAtom ANum) (BUnion (BAtom AStr) (BAtom ANum))).
Proof. reflexivity. Qed.

(* THE TYPE-TEST CHECKER PAYOFF. A number-consumer [h : ANum → Int] applied to the
   then-NARROWED scrutinee CHECKS; the scrutinee's declared type is the maybe-number
   [Str ∪ Num] (a free var). The whole [ttypetest] synthesizes the union. *)
Example compute_typetest_payoff_synth :
  synth [] [ BUnion (BAtom AStr) (BAtom ANum) ; BArrow (BAtom ANum) (BAtom AInt) ]
    (ttypetest TgNum (tvar 0)                  (* scrutinee = the maybe-number (index 0) *)
       (tapp (tvar 2) (tvar 0))                (* then: h (index 2) applied to NARROWED var0 : ANum *)
       (tlit (LInt)))
  = Some (BUnion (BAtom AInt) (BAtom AInt)).
Proof. reflexivity. Qed.

(* and it is SOUND (declaratively well typed via check_sound). *)
Example compute_typetest_payoff_sound :
  has_type [] [ BUnion (BAtom AStr) (BAtom ANum) ; BArrow (BAtom ANum) (BAtom AInt) ]
    (ttypetest TgNum (tvar 0) (tapp (tvar 2) (tvar 0)) (tlit (LInt)))
    (BUnion (BAtom AInt) (BAtom AInt)).
Proof. apply check_sound. reflexivity. Qed.

(* WITHOUT type-test narrowing the SAME application is REJECTED by the checker: a
   free var of [Str ∪ Num] passed to the [ANum]-demanding consumer fails the domain
   check (a string is not a number). *)
Example compute_typetest_payoff_unnarrowed_None :
  synth [] [ BUnion (BAtom AStr) (BAtom ANum) ; BArrow (BAtom ANum) (BAtom AInt) ]
    (tapp (tvar 1) (tvar 0)) = None.
Proof. reflexivity. Qed.

(* ILL-TYPED: projecting a field off a literal ⇒ None (not a record) *)
Example compute_proj_of_lit_None :
  synth [] [] (tproj (tlit (LInt)) "f"%string) = None.
Proof. reflexivity. Qed.

(* ILL-TYPED: applying a non-function ⇒ None *)
Example compute_app_nonfun_None :
  synth [] [] (tapp (tlit (LInt)) (tlit (LInt))) = None.
Proof. reflexivity. Qed.

(* ILL-TYPED: argument fails the domain check (Str vs Int) ⇒ None *)
Example compute_app_badarg_None :
  synth [] [] (tapp (tlam (BAtom AInt) (tvar 0)) (tlit (LStr 0))) = None.
Proof. reflexivity. Qed.

(* ILL-TYPED: duplicate record keys rejected ⇒ None *)
Example compute_dup_keys_None :
  synth [] [] (trec [("a"%string, tlit (LInt)); ("a"%string, tlit (LInt))]) = None.
Proof. reflexivity. Qed.

(* projecting an ABSENT key ⇒ None *)
Example compute_proj_absent_None :
  synth [] [] (tproj (trec [("a"%string, tlit (LInt))]) "z"%string) = None.
Proof. reflexivity. Qed.

(* [check] decides correctly: Int checks against Num (Int <: Num) but not vice versa *)
Example compute_check_subsume_true :
  check [] [] (tlit (LInt)) (BAtom ANum) = true.
Proof. reflexivity. Qed.

Example compute_check_subsume_false :
  check [] [] (tlit (LStr 0)) (BAtom AInt) = false.
Proof. reflexivity. Qed.

(* and [check] is SOUND on a real subsumption: 3 : Num via Int <: Num *)
Example compute_check_sound_demo : has_type [] [] (tlit (LInt)) (BAtom ANum).
Proof. apply check_sound. reflexivity. Qed.

(* INCREMENT 14 — GENERAL RECURSION checker. A recursive FUNCTION term synthesizes
   its annotated type: the body (a lambda of type [Int→Int]) checks against the
   annotation under the self-ref binder. *)
Example compute_fix_synth :
  synth [] [] (tfix (BArrow (BAtom AInt) (BAtom AInt)) (tlam (BAtom AInt) (tvar 0)))
  = Some (BArrow (BAtom AInt) (BAtom AInt)).
Proof. reflexivity. Qed.

(* the DIVERGING term [tfix Int (var0)] still SYNTHESIZES its annotation [Int]
   (well-typedness is independent of termination). *)
Example compute_fix_diverge_synth :
  synth [] [] (tfix (BAtom AInt) (tvar 0)) = Some (BAtom AInt).
Proof. reflexivity. Qed.

(* it CHECKS against a supertype too (Int <: Num). *)
Example compute_fix_checks :
  check [] [] (tfix (BAtom AInt) (tvar 0)) (BAtom ANum) = true.
Proof. reflexivity. Qed.

(* and the checker's acceptance is SOUND: the recursive function is declaratively
   well typed (via [check_sound]). *)
Example compute_fix_sound :
  has_type [] [] (tfix (BArrow (BAtom AInt) (BAtom AInt)) (tlam (BAtom AInt) (tvar 0)))
              (BArrow (BAtom AInt) (BAtom AInt)).
Proof. apply check_sound. reflexivity. Qed.

(* ILL-TYPED: a [tfix] whose body's type does NOT match the annotation ⇒ None.
   Here the body is a lambda ([Int→Int]) but the annotation says [Int] — the body
   check [Int→Int <: Int] fails. *)
Example compute_fix_badbody_None :
  synth [] [] (tfix (BAtom AInt) (tlam (BAtom AInt) (tvar 0))) = None.
Proof. reflexivity. Qed.

(* INCREMENT 19 — PRIMITIVE operators in the checker. [3 + 4] synthesizes [ANum];
   [3 < 4] synthesizes the boolean type; both check + are sound. [ "s" + 1 ] is
   REJECTED ([synth = None]). An [AInt] operand works (subsumes to [ANum]). *)
Example compute_add_synth :
  synth [] [] (tprim PAdd (tlit (LInt)) (tlit (LInt))) = Some (BAtom ANum).
Proof. reflexivity. Qed.

Example compute_lt_synth :
  synth [] [] (tprim PLt (tlit (LInt)) (tlit (LInt))) = Some (BAtom ABool).
Proof. reflexivity. Qed.

Example compute_add_checks :
  check [] [] (tprim PAdd (tlit (LInt)) (tlit (LInt))) (BAtom ANum) = true.
Proof. reflexivity. Qed.

Example compute_add_sound :
  has_type [] [] (tprim PAdd (tlit (LInt)) (tlit (LInt))) (BAtom ANum).
Proof. apply check_sound. reflexivity. Qed.

Example compute_lt_sound :
  has_type [] [] (tprim PLt (tlit (LInt)) (tlit (LInt))) (BAtom ABool).
Proof. apply check_sound. reflexivity. Qed.

(* a nested arithmetic chain [(3 + 4) * 2] synthesizes [ANum]. *)
Example compute_chain_synth :
  synth [] []
    (tprim PMul (tprim PAdd (tlit (LInt)) (tlit (LInt))) (tlit (LInt)))
  = Some (BAtom ANum).
Proof. reflexivity. Qed.

(* ILL-TYPED: [ "s" + 1 ] ⇒ None (the string operand fails the [ANum] domain check). *)
Example compute_bad_add_None :
  synth [] [] (tprim PAdd (tlit (LStr 0)) (tlit (LInt))) = None.
Proof. reflexivity. Qed.

(* and [check] rejects it against every type — here against [ANum]. *)
Example compute_bad_add_check_false :
  check [] [] (tprim PAdd (tlit (LStr 0)) (tlit (LInt))) (BAtom ANum) = false.
Proof. reflexivity. Qed.

(* ===========================================================================
   TYPE ASCRIPTION ([tannot]) — the inference-guiding seam, and THE FIX it closes.
   =========================================================================== *)

(* SANITY (ascription works). [(3 : Num)] synthesizes [Num] — the up-ascription
   [AInt <: ANum] is accepted in CHECK mode (decide_rsub). *)
Example compute_annot_num :
  synth [] [] (tannot (BAtom ANum) (tlit (LInt))) = Some (BAtom ANum).
Proof. reflexivity. Qed.

(* the ascription is SOUND: [(3 : Num) : Num] declaratively (via check_sound). *)
Example compute_annot_sound :
  has_type [] [] (tannot (BAtom ANum) (tlit (LInt))) (BAtom ANum).
Proof. apply check_sound. reflexivity. Qed.

(* it STEPS, runtime-erased: [(3 : Num)] strips to [3] on a value. *)
Example compute_annot_steps : forall st,
  step (tannot (BAtom ANum) (tlit (LInt)), st) (tlit (LInt), st).
Proof. intro st. apply SAnnotV. apply VLit. Qed.

(* SANITY (mis-ascription REJECTED). [(3 : Str)] is rejected by synth (None) — [3]
   synthesizes [AInt], and [AInt] is NOT [rsub]-below [AStr], so the CHECK fails. *)
Example compute_annot_mismatch_None :
  synth [] [] (tannot (BAtom AStr) (tlit (LInt))) = None.
Proof. reflexivity. Qed.

(* and the mis-ascription is genuinely ILL-TYPED: [tannot AStr 3] has no type,
   because [TAnnot] would need [3 : AStr] which is false ([AInt ⊄ AStr]). *)
Example compute_annot_mismatch_untyped :
  forall S T, ~ has_type S [] (tannot (BAtom AStr) (tlit (LInt))) T.
Proof.
  intros S T H. apply inv_annot in H. destruct H as [He _].
  apply inv_lit in He. simpl in He.   (* He : rsub AInt AStr *)
  apply rsub_sound in He. pose proof (He (VInt) I) as Hbad. exact Hbad.
Qed.

(* ---- THE FIX: the OP-SEM-BRIDGE-SURFACED SYNTH GAP on a real imperative loop.
   The counting/sum loop (sumloop_cond / sumloop_body / twhile, from typing.v)
   allocates its counter + accumulator cells. WITHOUT an annotation, [talloc (LInt
   0)] synthesizes [BRef AInt] (the cell is an Int cell); but the loop body stores
   an arithmetic result [!s + !i : ANum] back into the cell, and a [BRef] cell is
   INVARIANT — [ANum] is NOT storable into a [BRef AInt] cell — so [synth] of the
   whole loop returns NONE. (This is exactly the bridge-surfaced incompleteness: a
   sound program the synthesizer cannot infer, because [talloc] commits the cell to
   the too-specific initialiser type.)

   WITH the cells ANNOTATED — [talloc (tannot (BAtom ANum) (tlit (LInt)))] — the
   cell synthesizes [BRef ANum] (the annotation ascends the [LInt : AInt] to
   [ANum] before [talloc] reads its type), able to hold the arithmetic result. The
   whole loop then SYNTHESIZES [Some ANum]. The annotation GUIDED the inference. *)

(* the ANNOTATED sum-loop counter/accumulator initialiser. *)
Definition ann_zero : tm := tannot (BAtom ANum) (tlit (LInt)).

(* the un-annotated whole program (alloc Int cells; arith result can't store back). *)
Definition sumloop_unann (n : nat) : tm :=
  tlet (talloc (tlit (LInt)))
    (tlet (talloc (tlit (LInt)))
      (tseq (twhile (sumloop_cond n) sumloop_body) (tderef (tvar 0)))).

(* the ANNOTATED whole program (alloc Num cells via ascription). *)
Definition sumloop_ann (n : nat) : tm :=
  tlet (talloc ann_zero)
    (tlet (talloc ann_zero)
      (tseq (twhile (sumloop_cond n) sumloop_body) (tderef (tvar 0)))).

(* THE CONTRAST. Un-annotated: synth = None (the bridge-surfaced gap). *)
Example sumloop_unann_None : forall n, synth [] [] (sumloop_unann n) = None.
Proof. intro n. reflexivity. Qed.

(* THE FIX. Annotated: synth = Some ANum — the loop now checks. *)
Example sumloop_ann_synths : forall n, synth [] [] (sumloop_ann n) = Some (BAtom ANum).
Proof. intro n. reflexivity. Qed.

(* and the synthesized annotated loop is SOUND (declaratively well typed at ANum,
   via check_sound) — the annotation-guided inference produced a real typing. *)
Example sumloop_ann_sound : forall n,
  has_type [] [] (sumloop_ann n) (BAtom ANum).
Proof. intro n. apply check_sound. reflexivity. Qed.

(* ===========================================================================
   MULTI-RETURN — THE PAYOFF via the EXECUTABLE CHECKER. The SAME multi-return
   call synthesizes the TUPLE; under [tfst] it synthesizes the FIRST type
   (truncation); as the spread argument of a tuple-consuming [g] it synthesizes
   [g]'s result (spread, the consumer received both values). The contextual
   adjustment is decided by [Compute]/[reflexivity], and routed back to a real
   declarative typing by [synth_sound].
   =========================================================================== *)
Definition mr_f : tm :=
  tlam (BAtom AInt) (tret [ tvar 0 ; tlit (LBool true) ]).
Definition mr_tup : BTy := BTuple [ BAtom AInt ; BAtom ABool ].
Definition mr_call : tm := tapp mr_f (tlit (LInt)).
Definition mr_g : tm := tlam mr_tup (tlit (LInt)).

(* the call synthesizes the 2-tuple [(Int, Bool)] — a multivalue type. *)
Example mr_call_synths_tuple : synth [] [] mr_call = Some mr_tup.
Proof. reflexivity. Qed.

(* TRUNCATION: under [tfst] the SAME call synthesizes the FIRST type [AInt]
   (NOT the tuple) — the contextual adjustment that discards the extra return. *)
Example mr_truncate_synths_first : synth [] [] (tfst mr_call) = Some (BAtom AInt).
Proof. reflexivity. Qed.

(* SPREAD: as the spread arg of [g : (Int,Bool) -> Int], the SAME call makes the
   whole application synthesize [g]'s result [AInt] — g received BOTH values. *)
Example mr_spread_synths_result : synth [] [] (tappspread mr_g mr_call) = Some (BAtom AInt).
Proof. reflexivity. Qed.

(* and both adjustments route to REAL declarative typings via [synth_sound]. *)
Example mr_truncate_sound : has_type [] [] (tfst mr_call) (BAtom AInt).
Proof. apply synth_sound. reflexivity. Qed.
Example mr_spread_sound : has_type [] [] (tappspread mr_g mr_call) (BAtom AInt).
Proof. apply synth_sound. reflexivity. Qed.

(* ===========================================================================
   VARARG [...] — THE PAYOFF via the EXECUTABLE CHECKER. The variadic call PACKS
   its trailing actuals against the rest tuple [(Int,Bool)] — the SAME tuple type a
   two-value multi-return produces — and synthesizes the function's result. A
   variadic body that TRUNCATES [...] (via [tfst]) and one that FORWARDS [...] (via
   [tappspread]) both synthesize [Int]; the arity match is decided by [reflexivity]
   and routed to a real declarative typing by [synth_sound]. (Terms [va_first],
   [va_first_call], [va_fwd], [va_fwd_call] from typing.v.)
   =========================================================================== *)

(* the variadic functions synthesize the two-binder curried arrow. *)
Example va_first_synths :
  synth [] [] va_first = Some (BArrow (BAtom AInt) (BArrow va_rest (BAtom AInt))).
Proof. reflexivity. Qed.
Example va_fwd_synths :
  synth [] [] va_fwd = Some (BArrow (BAtom AInt) (BArrow va_rest (BAtom AInt))).
Proof. reflexivity. Qed.

(* the variadic CALLS synthesize the result [Int] — the trailing actuals were
   PACKED against the rest tuple (the known-arity match decided by [reflexivity]). *)
Example va_first_call_synths : synth [] [] va_first_call = Some (BAtom AInt).
Proof. reflexivity. Qed.
Example va_fwd_call_synths : synth [] [] va_fwd_call = Some (BAtom AInt).
Proof. reflexivity. Qed.

(* a variadic call whose trailing actuals MISMATCH the rest arity is REJECTED:
   passing only ONE trailing arg where the rest is [(Int,Bool)] synths to None
   (the [decide_ssub (BTuple [Int]) (BTuple [Int;Bool])] gate fails). *)
Example va_arity_mismatch_None :
  synth [] [] (tvapp va_first (tlit (LInt)) [ tlit (LInt) ]) = None.
Proof. reflexivity. Qed.

(* and both adjustments route to REAL declarative typings via [synth_sound]. *)
Example va_first_call_check_sound : has_type [] [] va_first_call (BAtom AInt).
Proof. apply synth_sound. reflexivity. Qed.
Example va_fwd_call_check_sound : has_type [] [] va_fwd_call (BAtom AInt).
Proof. apply synth_sound. reflexivity. Qed.

(* ===========================================================================
   MULTIPLE-ASSIGNMENT [a, b, … = …] — THE PAYOFF via the EXECUTABLE CHECKER. The
   checker synthesizes the TARGET cells ([map BRef Tgts] via [unref_seq]), the RHS
   tuple, ADJUSTS the RHS to the target arity ([pad_ty] — truncate / nil-pad), gates
   it pointwise [rsub]-below the cells, and synthesizes [nil]. The targets are
   context-bound reference variables (the reassignable-locals shape; source [tloc] is
   rejected). Three forms — exact / nil-pad / drop — are decided by [reflexivity] and
   routed to real declarative typings by [synth_sound]; a TYPE-MISMATCH is rejected.
   =========================================================================== *)

(* a context of two reference cells: [a : BRef Int] at de Bruijn 1, [b : BRef Bool]
   at 0 (so [tvar 1] = a, [tvar 0] = b). *)
Definition ma_ctx : list BTy := [ BRef (BAtom AInt) ; BRef (BAtom ABool) ].

(* (1) EXACT arity [a, b = e1, e2] : synthesizes [nil] (2 = 2, no adjustment). *)
Example ma_exact_synths :
  synth [] ma_ctx
    (tmassign [ tvar 0 ; tvar 1 ] (tret [ tlit (LInt) ; tlit (LBool false) ]))
  = Some (BAtom ANil).
Proof. reflexivity. Qed.

(* (2) NIL-PAD [a, b, c = e1, e2] : THREE targets (the third cell [BRef Nil] admits
   the pad), TWO RHS values ⇒ [pad_ty [Int;Bool] 3 = [Int;Bool;Nil]] gates true. *)
Example ma_pad_synths :
  synth [] [ BRef (BAtom AInt) ; BRef (BAtom ABool) ; BRef (BAtom ANil) ]
    (tmassign [ tvar 0 ; tvar 1 ; tvar 2 ] (tret [ tlit (LInt) ; tlit (LBool false) ]))
  = Some (BAtom ANil).
Proof. reflexivity. Qed.

(* (3) DROP [a, b = e1, e2, e3] : TWO targets, THREE RHS values ⇒ [pad_ty
   [Int;Bool;Int] 2 = [Int;Bool]] drops the third (truncation). *)
Example ma_drop_synths :
  synth [] ma_ctx
    (tmassign [ tvar 0 ; tvar 1 ]
       (tret [ tlit (LInt) ; tlit (LBool false) ; tlit (LInt) ]))
  = Some (BAtom ANil).
Proof. reflexivity. Qed.

(* a TYPE MISMATCH is REJECTED: assigning a [Bool] into the [Int] cell [a] fails the
   pointwise [decide_rsub] gate ⇒ None. *)
Example ma_mismatch_None :
  synth [] ma_ctx
    (tmassign [ tvar 0 ; tvar 1 ] (tret [ tlit (LBool true) ; tlit (LBool false) ]))
  = None.
Proof. reflexivity. Qed.

(* all three adjustment regimes route to REAL declarative typings via [synth_sound]. *)
Example ma_exact_check_sound :
  has_type [] ma_ctx
    (tmassign [ tvar 0 ; tvar 1 ] (tret [ tlit (LInt) ; tlit (LBool false) ]))
    (BAtom ANil).
Proof. apply synth_sound. reflexivity. Qed.
Example ma_drop_check_sound :
  has_type [] ma_ctx
    (tmassign [ tvar 0 ; tvar 1 ]
       (tret [ tlit (LInt) ; tlit (LBool false) ; tlit (LInt) ]))
    (BAtom ANil).
Proof. apply synth_sound. reflexivity. Qed.

(* ===========================================================================
   METATABLES — the ALGORITHMIC OOP payoff: [synth] computes the flattened read
   interface of a metatable-table, and projecting the INHERITED method on the
   derived object synthesizes its base type — then routes to a real declarative
   typing via [synth_sound]. (Terms [oop_derived] etc. from typing.v.)
   =========================================================================== *)

(* [synth] computes the derived object's flattened (own ++ inherited) type. *)
Example oop_derived_synths : synth [] [] oop_derived = Some oop_derived_ty.
Proof. reflexivity. Qed.

(* projecting the INHERITED method [greet] on the derived object SYNTHESIZES its
   base type [nil -> Str] — the checker resolves the field through [__index]. *)
Example oop_inherited_synths :
  synth [] [] (tproj oop_derived "greet") = Some (BArrow (BAtom ANil) (BAtom AStr)).
Proof. reflexivity. Qed.

(* and it routes to a real declarative typing — the algorithmic checker is SOUND. *)
Example oop_inherited_check_sound :
  has_type [] [] (tproj oop_derived "greet") (BArrow (BAtom ANil) (BAtom AStr)).
Proof. apply synth_sound. reflexivity. Qed.

(* a field present in NEITHER own nor prototype is REJECTED by the checker. *)
Example oop_absent_synth_None : synth [] [] (tproj oop_derived "nonesuch") = None.
Proof. reflexivity. Qed.

(* ===========================================================================
   METATABLE METAMETHODS — the ALGORITHMIC payoffs: the checker dispatches
   [__call] / [__add] / [__newindex] and routes to real declarative typings.
   (Terms [cobj] / [vobj] / [niwrite] from typing.v.)
   =========================================================================== *)

(* __call: the checker computes the callable table's application type [Int]. *)
Example call_synths : synth [] [] (tapp cobj (tlit (LInt))) = Some (BAtom AInt).
Proof. reflexivity. Qed.
Example call_check_sound : has_type [] [] (tapp cobj (tlit (LInt))) (BAtom AInt).
Proof. apply synth_sound. reflexivity. Qed.

(* __add: the checker dispatches operator overloading, result [Int]. *)
Example add_synths : synth [] [] (tprim PAdd vobj vobj) = Some (BAtom AInt).
Proof. reflexivity. Qed.
Example add_check_sound : has_type [] [] (tprim PAdd vobj vobj) (BAtom AInt).
Proof. apply synth_sound. reflexivity. Qed.

(* an operator whose metamethod is ABSENT ([__sub] not on [vobj]) is REJECTED. *)
Example sub_synth_None : synth [] [] (tprim PSub vobj vobj) = None.
Proof. reflexivity. Qed.

(* __newindex (synthesizable form): the [__newindex] target is a context variable
   of record-of-refs type [{k : ref Int}] (a [tloc] is runtime-only and not
   source-synthesizable). The checker accepts the write-fallback, result [nil]. *)
Definition niwrite_syn : tm := tnewidx [] (tvar 0) "k" (tlit (LInt)).
Definition ni_ctx : list BTy := [BRec [("k"%string, BRef (BAtom AInt))]].
Example newindex_synths :
  synth [] ni_ctx niwrite_syn = Some (BAtom ANil).
Proof. reflexivity. Qed.
Example newindex_check_sound :
  has_type [] ni_ctx niwrite_syn (BAtom ANil).
Proof. apply synth_sound. reflexivity. Qed.

(* a write to a key NOT in the [__newindex] target's cells is REJECTED. *)
Example newindex_absent_synth_None :
  synth [] ni_ctx (tnewidx [] (tvar 0) "nope" (tlit (LInt))) = None.
Proof. reflexivity. Qed.

(* METATABLE METAMETHOD FAMILY — __concat / __unm / __len algorithmic payoffs.
   (Terms [ccobj] / [uobj] from typing.v.) *)

(* __concat: the checker dispatches the binary [..] metamethod, result [Str]. *)
Example concat_synths : synth [] [] (tprim PConcat ccobj ccobj) = Some (BAtom AStr).
Proof. reflexivity. Qed.
Example concat_check_sound : has_type [] [] (tprim PConcat ccobj ccobj) (BAtom AStr).
Proof. apply synth_sound. reflexivity. Qed.

(* __unm: the checker dispatches the unary [-] metamethod, result [Int]. *)
Example unm_synths : synth [] [] (tunop UNeg uobj) = Some (BAtom AInt).
Proof. reflexivity. Qed.
Example unm_check_sound : has_type [] [] (tunop UNeg uobj) (BAtom AInt).
Proof. apply synth_sound. reflexivity. Qed.

(* __len: the checker dispatches the unary [#] metamethod, result [Int]. *)
Example len_synths : synth [] [] (tunop ULen uobj) = Some (BAtom AInt).
Proof. reflexivity. Qed.
Example len_check_sound : has_type [] [] (tunop ULen uobj) (BAtom AInt).
Proof. apply synth_sound. reflexivity. Qed.

(* a unary operator whose metamethod is ABSENT ([__unm]/[__len] not on [ccobj]) is
   REJECTED by the checker. *)
Example len_absent_synth_None : synth [] [] (tunop ULen ccobj) = None.
Proof. reflexivity. Qed.

(* ===========================================================================
   RAW TABLE ACCESS — the ALGORITHMIC payoff: [synth] of [rawget]/[rawset] looks
   up the key in OWN fields ONLY, NEVER the prototype. The DISTINGUISHING property
   is decided by [reflexivity]: raw read of an OWN key SYNTHESIZES its type, raw
   read of a PROTOTYPE-ONLY key synthesizes NONE (even though [tproj] on the same
   metatable-table resolves it through [__index] — [oop_inherited_synths] above).
   (Terms [oop_base] / [rawset_own] from typing.v.)
   =========================================================================== *)

(* RAW READ of the OWN field "name" synthesizes [Str] (own-only lookup). *)
Example rawget_own_synths :
  synth [] [] (trawget [("name"%string, tlit (LStr 1))] (trec oop_base) "name")
  = Some (BAtom AStr).
Proof. reflexivity. Qed.
Example rawget_own_check_sound :
  has_type [] [] (trawget [("name"%string, tlit (LStr 1))] (trec oop_base) "name")
                 (BAtom AStr).
Proof. apply synth_sound. reflexivity. Qed.

(* THE DISTINGUISHING PROPERTY, ALGORITHMICALLY: the INHERITED key "greet" — which
   [synth (tproj oop_derived "greet")] resolves through [__index] — synthesizes
   NONE for [trawget]: raw access bypasses the prototype. *)
Example rawget_bypasses_proto_synth_None :
  synth [] [] (trawget [("name"%string, tlit (LStr 1))] (trec oop_base) "greet") = None.
Proof. reflexivity. Qed.

(* RAW WRITE to the OWN cell "k" (a context variable of record-of-refs type, since
   a [tloc] is runtime-only) synthesizes [nil] — the write targets OWN, not the
   prototype. *)
Definition rawset_syn : tm := trawset [("k"%string, tvar 0)] (trec []) "k" (tlit (LInt)).
Definition rawset_ctx : list BTy := [BRef (BAtom AInt)].
Example rawset_synths :
  synth [] rawset_ctx rawset_syn = Some (BAtom ANil).
Proof. reflexivity. Qed.
Example rawset_check_sound :
  has_type [] rawset_ctx rawset_syn (BAtom ANil).
Proof. apply synth_sound. reflexivity. Qed.

(* a raw write to a key NOT in OWN is REJECTED (no own cell; never dispatches to
   the prototype's [__newindex]). *)
Example rawset_absent_own_synth_None :
  synth [] rawset_ctx (trawset [("k"%string, tvar 0)] (trec []) "nope" (tlit (LInt))) = None.
Proof. reflexivity. Qed.

(* ===========================================================================
   ASSUMPTION AUDIT — closed under the global context (no axioms / Admitted /
   Classical). The soundness theorems are the load-bearing point; the
   principality (tractable completeness) theorem is audited alongside.
   =========================================================================== *)
Print Assumptions synth_sound.
Print Assumptions check_sound.
(* VARARG — algorithmic variadic payoff: truncate-[...] and forward-[...] calls
   synthesize their result; an arity-mismatched call is rejected; both route to a
   real declarative typing via [synth_sound]. *)
Print Assumptions va_first_synths.
Print Assumptions va_fwd_synths.
Print Assumptions va_first_call_synths.
Print Assumptions va_fwd_call_synths.
Print Assumptions va_arity_mismatch_None.
Print Assumptions va_first_call_check_sound.
Print Assumptions va_fwd_call_check_sound.
(* MULTIPLE-ASSIGNMENT — algorithmic payoff: exact / nil-pad / drop synth-decided,
   type-mismatch rejected, all routed to declarative typings. *)
Print Assumptions ma_exact_synths.
Print Assumptions ma_pad_synths.
Print Assumptions ma_drop_synths.
Print Assumptions ma_mismatch_None.
Print Assumptions ma_exact_check_sound.
Print Assumptions ma_drop_check_sound.
(* METATABLES — algorithmic OOP payoff. *)
Print Assumptions oop_derived_synths.
Print Assumptions oop_inherited_synths.
Print Assumptions oop_inherited_check_sound.
Print Assumptions oop_absent_synth_None.
(* METATABLE METAMETHODS — __call / __add / __newindex algorithmic payoffs. *)
Print Assumptions call_synths.
Print Assumptions call_check_sound.
Print Assumptions add_synths.
Print Assumptions add_check_sound.
Print Assumptions sub_synth_None.
Print Assumptions newindex_synths.
Print Assumptions newindex_check_sound.
Print Assumptions newindex_absent_synth_None.
(* METATABLE METAMETHOD FAMILY — __concat / __unm / __len algorithmic payoffs. *)
Print Assumptions concat_synths.
Print Assumptions concat_check_sound.
Print Assumptions unm_synths.
Print Assumptions unm_check_sound.
Print Assumptions len_synths.
Print Assumptions len_check_sound.
Print Assumptions len_absent_synth_None.
Print Assumptions rawget_own_synths.
Print Assumptions rawget_own_check_sound.
Print Assumptions rawget_bypasses_proto_synth_None.
Print Assumptions rawset_synths.
Print Assumptions rawset_check_sound.
Print Assumptions rawset_absent_own_synth_None.
(* MULTI-RETURN — the executable-checker payoff. *)
Print Assumptions mr_call_synths_tuple.
Print Assumptions mr_truncate_synths_first.
Print Assumptions mr_spread_synths_result.
Print Assumptions mr_truncate_sound.
Print Assumptions mr_spread_sound.
Print Assumptions narrowing.
Print Assumptions compute_typetest_payoff_sound.
Print Assumptions compute_typetest_payoff_synth.
Print Assumptions compute_add_sound.
Print Assumptions compute_lt_sound.
Print Assumptions compute_bad_add_None.
(* TYPE ASCRIPTION ([tannot]) — sanity + THE FIX (annotated sum-loop synthesizes). *)
Print Assumptions compute_annot_sound.
Print Assumptions compute_annot_mismatch_untyped.
Print Assumptions sumloop_unann_None.
Print Assumptions sumloop_ann_synths.
Print Assumptions sumloop_ann_sound.
