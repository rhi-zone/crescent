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

(* INCREMENT 15 — the runtime type-tags [type()] can return — one per value kind.
   Note (LuaJIT 5.1 number model): [type()] returns ["number"] for ALL numbers,
   so [TgNum] corresponds to the whole number type [ANum]; there is no integer/
   float tag split at the [type()] level. *)
Inductive tag : Type :=
  | TgNum   : tag            (* type(x) == "number"   *)
  | TgStr   : tag            (* type(x) == "string"   *)
  | TgBool  : tag            (* type(x) == "boolean"  *)
  | TgNil   : tag            (* type(x) == "nil"      *)
  | TgTable : tag            (* type(x) == "table"    *)
  | TgFun   : tag            (* type(x) == "function" *)
  (* SPLIT-STEP 3 — the reference/location runtime tag. In real Lua a userdata /
     boxed cell would carry its own type(); here a location [tloc] is a distinct
     runtime kind, so it gets its own tag [TgRef]. [type()]-on-a-location pins the
     ANY-REFERENCE type [BAnyRef] (see [tag_type]) — content-blind, exactly the
     narrowing a truthy/tag-tested location supports. *)
  | TgRef   : tag.           (* a reference/location  *)

Definition tag_eq_dec (g1 g2 : tag) : {g1 = g2} + {g1 <> g2}.
Proof. decide equality. Defined.

Inductive lit : Type :=
  | LInt  : nat -> lit          (* integer-valued number literal; type AInt   *)
  | LStr  : nat -> lit          (* string literal;                 type AStr   *)
  | LBool : bool -> lit         (* boolean literal;                type ABool  *)
  | LNil  : lit.                (* nil literal;                    type ANil   *)

(* INCREMENT 19 — PRIMITIVE BINARY OPERATORS (real computation). [primop] is the
   operator tag carried by [tprim]. Arithmetic: [PAdd]/[PSub]/[PMul]/[PDiv]
   (Lua [+ - * /]); comparison: [PLt]/[PLe]/[PEq] (Lua [< <= ==]). DEFERRED
   (backlog): concat, modulo, floor-div [//], bitwise, and metamethod-dispatch
   operators; precise Int-preserving arithmetic result types (Int+Int : AInt);
   general structural [==] (here [==] is numbers-only). *)
Inductive primop : Type :=
  | PAdd | PSub | PMul | PDiv      (* arithmetic — result ANum *)
  | PLt  | PLe  | PEq.             (* comparison — result ABool *)

Inductive tm : Type :=
  | tlit  : lit -> tm
  | tvar  : nat -> tm
  (* INCREMENT 19 — a binary primitive application [tprim op a b]. *)
  | tprim : primop -> tm -> tm -> tm
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
  | tif   : tm -> tm -> tm -> tm             (* tif cond then else              *)
  (* INCREMENT 13 — TRUTHINESS FLOW NARROWING (occurrence typing, value-
     conditioned). [tifn c e1 e2] is the NARROWING conditional: the scrutinee [c]
     is BOUND FRESH (de Bruijn index 0) in BOTH branches, at a NARROWED type —
     truthy-part [U ∩ truthy_type] in [e1], falsy-part [U ∩ falsy_type] in [e2]
     (where [U] is the scrutinee's type). Lua truthiness: [c] may be ANY type (not
     just Bool); falsy = {nil, false}, truthy = everything else.

     WHY A BINDING FORM (the crux of soundness under substitution semantics). A
     plain [tif (tvar n) e1 e2] narrowing the FREE context entry [n] is UNSOUND
     under de Bruijn substitution: an enclosing [SLet]/[SBeta] substitutes the
     bound value into BOTH branches BEFORE the conditional selects, so the DEAD
     branch — carrying the now-false narrowing assumption (e.g. truthy value
     pushed into the falsy-narrowed else-branch) — becomes an ill-typed residual.
     Value-conditioned op-sem fixes the SELECTED branch but NOT the blindly-
     substituted dead branch. The fix: bind the scrutinee FRESH in each branch and
     have the value-conditioned step substitute the value into ONLY the selected
     branch ([SIfnTrue]/[SIfnFalse] reduce to [subst 0 v e1] / [subst 0 v e2]),
     discarding the other. The narrowing then attaches at the binder, the dead
     branch is never substituted into, and soundness closes. (See the increment-13
     note in proof-kernel.md for the full diagnosis: this is the genuine refinement
     of the prior "value-conditioned op-sem" diagnosis, which was incomplete for
     substitution semantics.) *)
  | tifn  : tm -> tm -> tm -> tm             (* tifn cond then else (narrowing)  *)
  (* INCREMENT 14 — GENERAL RECURSION (single fixpoint). [tfix T body]: de Bruijn
     index 0 in [body] is the RECURSIVE SELF-REFERENCE, of type [T]; the whole
     [tfix T body] has type [T]. The unfold-rule operational form ([SFix] below)
     reduces [tfix T body] to [subst 0 (tfix T body) body] — replacing the self-ref
     by the fixpoint itself. This is the simplest sound encoding: it always steps
     (never a value), so type soundness TOLERATES NON-TERMINATION — progress and
     preservation do NOT require termination (a recursive unfold always steps and
     preserves typing). The annotation [T] makes it synthesizable (the checker
     synthesizes [body] under [T::G] and returns [T]). Lua's [local function f =
     ...] (which is recursion) is the derivable consumer. MUTUAL recursion and
     recursive TYPES (equirecursive μ) are DEFERRED (backlog). *)
  | tfix  : BTy -> tm -> tm                  (* tfix T body : recursive self-ref *)
  (* INCREMENT 15 — TYPE-TEST FLOW NARROWING (occurrence typing, value-conditioned).
     [ttypetest g scrut e1 e2] is the real Lua [type(x) == "T"] guard: it tests
     whether [scrut]'s RUNTIME value has the type-tag [g] (g ∈ {TgNum, TgStr,
     TgBool, TgNil, TgTable, TgFun} — the [type()] tags). The scrutinee is BOUND
     FRESH (de Bruijn 0) in BOTH branches. The THEN-branch [e1] sees the bound var
     at [tag_type g] (the type the tag pins — TgNum↦ANum, etc.); the ELSE-branch
     [e2] sees it at the scrutinee's own type [U] (a sound OVER-approximation —
     precise negative narrowing [U ∩ ¬tag_type g] needs intersection/negation,
     DEFERRED).

     SAME BINDING DISCIPLINE AS [tifn] (the soundness crux). A non-binding type
     test narrowing a FREE context entry is UNSOUND under de Bruijn substitution:
     an enclosing [SLet]/[SBeta] substitutes the bound value into BOTH branches
     before the test selects, so the DEAD branch carries a now-false narrowing
     assumption and becomes an ill-typed residual. The fix: bind the scrutinee
     fresh in each branch and have the value-conditioned step substitute the value
     into ONLY the selected branch ([STtTrue]/[STtFalse]). The narrowing attaches
     at the binder; the dead branch is never substituted into; soundness closes. *)
  | ttypetest : tag -> tm -> tm -> tm -> tm
  (* SPLIT-STEP 3 — MUTABLE REFERENCES (the imperative layer, ported from imp.v,
     unified into the MAIN term language). [talloc e] allocates a fresh cell
     holding [e], reducing to a fresh location; [tderef e] reads [!e]; [tassign r e]
     writes [r := e] (yields the unit value [tlit LNil]); [tloc n] is a store
     address — a VALUE, not source syntax (it appears only at runtime, produced by
     [talloc]). The store-based operational semantics + store typing [Σ] give
     soundness; see [step] (now over configurations) and [has_type Σ ...]. *)
  | talloc  : tm -> tm                       (* allocate, returns a fresh loc   *)
  | tderef  : tm -> tm                       (* read  !r                        *)
  | tassign : tm -> tm -> tm                 (* write r := v  (yields unit/nil) *)
  | tloc    : nat -> tm.                     (* a store address (a VALUE)       *)

(* The type a tag pins (the THEN-branch narrowed type). TgNum ↦ ANum (all numbers,
   per the 5.1 [type()] model), the other scalars to their atoms, TgTable to the
   open empty record [BRec []] (the table top-type, exactly the [VTable] values —
   see subtype.v [empty_rec_is_tables]), TgFun to [BArrow BBot BTop] (the function
   top-type, every function value — every [VFun] inhabits it vacuously/by Top). *)
Definition tag_type (g : tag) : BTy :=
  match g with
  | TgNum   => BAtom ANum
  | TgStr   => BAtom AStr
  | TgBool  => BAtom ABool
  | TgNil   => BAtom ANil
  | TgTable => BRec []
  | TgFun   => BArrow BBot BTop
  (* SPLIT-STEP 3 — a location's tag pins the ANY-REFERENCE type [BAnyRef]: every
     location [tloc n] inhabits [BAnyRef] (content-blind), and a specific [BRef U]
     widens into it ([rsub (BRef U) BAnyRef], the any-ref rule). This is exactly
     why [BAnyRef] exists — a truthy / tag-tested location narrows to "is a
     reference" without committing to its content type. *)
  | TgRef   => BAnyRef
  end.

(* The base type of a literal. *)
Definition lit_type (l : lit) : BTy :=
  match l with
  | LInt _  => BAtom AInt
  | LStr _  => BAtom AStr
  | LBool _ => BAtom ABool
  | LNil    => BAtom ANil
  end.

(* INCREMENT 19 — primop classification + the (nat-level) computation. Arithmetic
   ops produce a NUMBER, comparison ops a BOOLEAN. The TERM literal language has a
   single number literal [LInt nat] (integer-valued), so number VALUES are
   [tlit (LInt n)]; arithmetic computes via nat arithmetic. [PDiv] uses [Nat.div]
   (a representative integer-valued result — the term literal language has no
   fractional literal; the value model abstracts the exact double, and soundness
   needs only "the result is a number", so an integer-valued representative is
   sound — its type [AInt <: ANum] is the declared arithmetic result). Comparison
   computes the real nat comparison so the sanity examples ([3 < 4 = true]) reduce
   concretely. *)
Definition arith_op (op : primop) : bool :=
  match op with PAdd | PSub | PMul | PDiv => true | _ => false end.
Definition cmp_op (op : primop) : bool :=
  match op with PLt | PLe | PEq => true | _ => false end.

Definition prim_arith (op : primop) (m n : nat) : nat :=
  match op with
  | PAdd => m + n
  | PSub => m - n
  | PMul => m * n
  | PDiv => Nat.div m n
  | _    => 0
  end.

Definition prim_cmp (op : primop) (m n : nat) : bool :=
  match op with
  | PLt => Nat.ltb m n
  | PLe => Nat.leb m n
  | PEq => Nat.eqb m n
  | _   => false
  end.

(* ---- A usable induction principle: the auto-generated [tm_ind] gives no IH
   for the subterms inside a [trec] list. Hand-roll the nested scheme (a plain
   Fixpoint, no axiom), mirroring [V_rect_strong] in subtype.v. *)
Section tm_ind_strong.
  Variable P  : tm -> Prop.
  Variable Pl : list (string * tm) -> Prop.
  Hypothesis Hlit  : forall l, P (tlit l).
  Hypothesis Hvar  : forall n, P (tvar n).
  Hypothesis Hprim : forall op a b, P a -> P b -> P (tprim op a b).
  Hypothesis Hlam  : forall T b, P b -> P (tlam T b).
  Hypothesis Happ  : forall f a, P f -> P a -> P (tapp f a).
  Hypothesis Hlet  : forall e1 e2, P e1 -> P e2 -> P (tlet e1 e2).
  Hypothesis Hrec  : forall fs, Pl fs -> P (trec fs).
  Hypothesis Hproj : forall e k, P e -> P (tproj e k).
  Hypothesis Hif   : forall c e1 e2, P c -> P e1 -> P e2 -> P (tif c e1 e2).
  Hypothesis Hifn  : forall c e1 e2, P c -> P e1 -> P e2 -> P (tifn c e1 e2).
  Hypothesis Hfix  : forall T b, P b -> P (tfix T b).
  Hypothesis Htt   : forall g c e1 e2, P c -> P e1 -> P e2 -> P (ttypetest g c e1 e2).
  Hypothesis Halloc  : forall e, P e -> P (talloc e).
  Hypothesis Hderef  : forall e, P e -> P (tderef e).
  Hypothesis Hassign : forall r e, P r -> P e -> P (tassign r e).
  Hypothesis Hloc    : forall n, P (tloc n).
  Hypothesis Hnil  : Pl [].
  Hypothesis Hcons : forall k e rest, P e -> Pl rest -> Pl ((k, e) :: rest).
  Fixpoint tm_rect_strong (e : tm) : P e :=
    match e with
    | tlit l    => Hlit l
    | tvar n    => Hvar n
    | tprim op a b => Hprim op a b (tm_rect_strong a) (tm_rect_strong b)
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
    | tifn c e1 e2 => Hifn c e1 e2 (tm_rect_strong c) (tm_rect_strong e1) (tm_rect_strong e2)
    | tfix T b  => Hfix T b (tm_rect_strong b)
    | ttypetest g c e1 e2 =>
        Htt g c e1 e2 (tm_rect_strong c) (tm_rect_strong e1) (tm_rect_strong e2)
    | talloc e  => Halloc e (tm_rect_strong e)
    | tderef e  => Hderef e (tm_rect_strong e)
    | tassign r e => Hassign r e (tm_rect_strong r) (tm_rect_strong e)
    | tloc n    => Hloc n
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
  (* INCREMENT 12 — INTERSECTION rules (composable GLB form, dual to UNION,
     mirroring subtype.v's [sub]). PROJECTIONS carry a recursive premise
     ([ssub A C -> ssub (BInter A B) C]) so inversion threads through explicit
     transitivity; the brief's plain projections [ssub (BInter A B) A] /
     [ssub (BInter A B) B] are DERIVED as [ssub_inter_prl] / [ssub_inter_prr]
     (= the composable rule at [SsRefl]). INTRO is the greatest-lower-bound rule.
     All three are SOUND vs [dsub] (the Boolean algebra: intersection is the
     meet — [dinter_prl]/[dinter_prr]/[dinter_glb]), proved in [ssub_sound]. *)
  | SsInterPL : forall A B C, ssub A C -> ssub (BInter A B) C
  | SsInterPR : forall A B C, ssub B C -> ssub (BInter A B) C
  | SsInterI  : forall A B C, ssub C A -> ssub C B -> ssub C (BInter A B)
  (* INCREMENT 12 — NEGATION stays REFLEXIVE-ONLY in [ssub] (no structural rule
     for [BNeg]). The COMPLEMENT disjointness [A ∩ ¬A <: Bot] that flow NARROWING
     relies on is a SEMANTIC ([dsub]) fact ([dcomplement_inter], subtype.v), used
     operationally in preservation — NOT an [ssub] rule. Adding it as an [ssub]
     rule would force [ssub] to decide empty-intersection reachability (an
     emptiness problem — [dsub]'s job), breaking the clean total decision
     procedure. So narrowing's soundness goes through [ssub_sound]+[denote], and
     [BNeg] keeps its reflexive-only decider treatment. (See [ssub_interneg_leaf]:
     now restricted to the [BNeg] head; [BInter] is decided structurally below.) *)
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
      destruct v as [r| | | | | |]; try contradiction; try destruct r;
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
  - (* SsInterPL: A ⊆ C ⇒ A∩B ⊆ C (left projection / meet below). *)
    unfold dsub in *. intros v Hv. simpl in Hv. destruct Hv as [Ha _]; auto.
  - (* SsInterPR: B ⊆ C ⇒ A∩B ⊆ C (right projection). *)
    unfold dsub in *. intros v Hv. simpl in Hv. destruct Hv as [_ Hb]; auto.
  - (* SsInterI: C ⊆ A and C ⊆ B ⇒ C ⊆ A∩B (greatest lower bound). *)
    unfold dsub in *. intros v Hv. simpl. split; auto.
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

(* INCREMENT 12 — INTERSECTION helpers, dual to the union ones. The brief's plain
   projections, recovered from the composable forms at [SsRefl]; plus the
   intersection-TARGET DECOMPOSITION ([ssub C (A∩B) ⇒ ssub C A ∧ ssub C B]) —
   immediate from the projections + transitivity, NO induction — used by the
   decider's intersection-on-right completeness. *)

Lemma ssub_inter_prl : forall A B, ssub (BInter A B) A.
Proof. intros A B. apply SsInterPL, SsRefl. Qed.

Lemma ssub_inter_prr : forall A B, ssub (BInter A B) B.
Proof. intros A B. apply SsInterPR, SsRefl. Qed.

Lemma ssub_inter_tgt_l : forall C A B, ssub C (BInter A B) -> ssub C A.
Proof. intros C A B H. eapply SsTrans; [ exact H | apply ssub_inter_prl ]. Qed.

Lemma ssub_inter_tgt_r : forall C A B, ssub C (BInter A B) -> ssub C B.
Proof. intros C A B H. eapply SsTrans; [ exact H | apply ssub_inter_prr ]. Qed.

(* ===========================================================================
   SPLIT-STEP 3 — REFERENCE-AWARE SUBTYPING [rsub] (unified into the typing layer).

   The reference unification's final move: subsumption in the MAIN typing layer
   ([TSub]) must be reference-aware. [ssub] (above) is the non-reference core —
   atoms / arrows / records / unions / intersections — proved sound vs [dsub] and
   INVERTIBLE (the [_above] machinery). References add exactly TWO rules that
   [ssub] cannot have (a mutable cell is read AND written, so [BRef] is INVARIANT,
   not covariant; and a specific reference widens to the any-reference [BAnyRef]):

     1. INVARIANT [BRef]:   [rsub (BRef S) (BRef T)]  iff  [S ≡ T] (both directions).
     2. ANY-REF WIDENING:   [rsub (BRef U) BAnyRef]   for every [U].

   [rsub] EMBEDS all of [ssub] ([RsSsub]) and ADDS these two rules — so there is
   ONE reference-aware relation, [rsub], with [ssub] as its embedded core (NO
   duplicate ref relation: [ssub.v]'s former standalone [rsub] is RETIRED in favour
   of this one, and [imp.v]'s [rsub] likewise). [TSub] subsumes along [rsub].

   This is exactly [ssub.v]'s split-step-2 [rsub], PROMOTED into [typing.v] (the
   layer that owns [ssub]) so the typing layer can subsume references soundly. It
   is proved a preorder + sound vs [dsub] here; the DECISION procedure
   [decide_rsub] stays in [ssub.v] (downstream).
   =========================================================================== *)

Inductive rsub : BTy -> BTy -> Prop :=
  | RsSsub   : forall a b, ssub a b -> rsub a b
  | RsTrans  : forall a b c, rsub a b -> rsub b c -> rsub a c
  | RsRefInv : forall S T, rsub S T -> rsub T S -> rsub (BRef S) (BRef T)
  | RsAnyRef : forall U, rsub (BRef U) BAnyRef.

Lemma rsub_refl : forall t, rsub t t.
Proof. intro t. apply RsSsub. apply SsRefl. Qed.

Lemma rsub_trans : forall a b c, rsub a b -> rsub b c -> rsub a c.
Proof. intros a b c Hab Hbc. eapply RsTrans; eassumption. Qed.

(* SOUNDNESS vs [dsub]: the reference rules collapse to equal-denotation inclusions
   ([denote (BRef _) = denote BAnyRef = {VRef _}], subtype.v). *)
Lemma rsub_sound : forall a b, rsub a b -> dsub a b.
Proof.
  intros a b H. induction H.
  - apply ssub_sound. exact H.
  - eapply dsub_trans; eassumption.
  - intros v Hv. simpl in *. destruct v; try contradiction; exact I.
  - intros v Hv. simpl in *. destruct v; try contradiction; exact I.
Qed.

(* The reference-SOURCE inversion lemmas + cross-kind not-subtypings live AFTER the
   [ssub] shape machinery (section 6) — they reuse [srec]/[atom_has_member] etc.
   Search for "SPLIT-STEP 3 — [rsub] reference inversion". *)

(* ===========================================================================
   INCREMENT 13 — TRUTHINESS TYPES (the falsy / truthy partition of the value
   space, for flow narrowing).

   Lua falsy = {nil, false}; truthy = everything else. The value model
   (subtype.v) has NO singleton-false type ([ABool] denotes both [VBool true]
   and [VBool false] — there is no atom carving out just [false]). So the EXACT
   falsy set {VNil, VBool false} is NOT expressible as a [BTy]. We pick the two
   expressible bounds that make the narrowing SOUND in both directions (and prove
   the bridging lemmas against them):

     - [truthy_type] : the POSITIVE union of every NON-NIL value class
       (ABool ∪ ANum ∪ AStr ∪ {table} ∪ {function}). It denotes EXACTLY the
       non-nil values, so it CONTAINS every operationally-truthy value (truthy ⟹
       non-nil). Narrowing the THEN-branch to [U ∩ truthy_type] is sound: a
       truthy scrutinee really inhabits [truthy_type]. Crucially [truthy_type] is
       POSITIVE — its [ssub] memberships are union INTRODUCTIONS ([SsUnionInL/InR]),
       so the bridge needs NO negation rule (ssub has none) and NO dsub-in-typing.
     - [falsy_type] : [BUnion (BAtom ANil) (BAtom ABool)] — nil OR bool. An
       OVER-approximation of falsy: it contains [VNil] (falsy) and [VBool false]
       (falsy), and also [VBool true] (not falsy — the inexactness). Narrowing the
       ELSE-branch to [U ∩ falsy_type] is sound because every falsy value (nil or
       false) inhabits [falsy_type]; the over-approximation only makes the
       narrowed type WEAKER (still a true upper bound on the else scrutinee).

   The inexactness (no singleton-false) is the precise SUBSTRATE GAP for fully-
   exact truthiness narrowing; recorded in proof-kernel.md / TODO.md. Both
   narrowing directions are SOUND against these bounds — proved below. *)

(* SPLIT-STEP 3 — [truthy_type] gains a [BAnyRef] arm: a LOCATION is truthy (non-
   nil), so the truthy partition must contain the any-reference type. This is
   exactly why [BAnyRef] exists — a truthy location narrows to "is a reference"
   (content-blind) via [BRef U <: BAnyRef] (the any-ref [rsub] rule) then injects
   into [truthy_type]. So a truthy [tloc] genuinely inhabits [truthy_type], keeping
   [truthy_narrows] sound with references present. *)
Definition truthy_type : BTy :=
  BUnion (BAtom ABool)
    (BUnion (BAtom ANum)
       (BUnion (BAtom AStr)
          (BUnion (BRec [])
             (BUnion (BArrow BBot BTop) BAnyRef)))).

Definition falsy_type : BTy :=
  BUnion (BAtom ANil) (BAtom ABool).

(* [has_type S G e T] — S : store typing (the type of the value at each store
   location), G : de Bruijn variable context. S is threaded UNCHANGED through every
   non-reference rule (it is a fixed parameter from their perspective); the location
   rule [TLoc] reads it, and the three reference rules introduce/eliminate [BRef].
   SUBSUMPTION [TSub] subsumes along the reference-aware [rsub]. *)
Inductive has_type : list BTy -> list BTy -> tm -> BTy -> Prop :=
  | TLit  : forall S G l,
      has_type S G (tlit l) (lit_type l)
  | TVar  : forall S G n T,
      nth_error G n = Some T ->
      has_type S G (tvar n) T
  (* INCREMENT 19 — PRIMITIVE OPERATORS. Operands are typed at [ANum] (with
     subsumption an [AInt] operand works, [AInt <: ANum]). Arithmetic
     ([PAdd]/[PSub]/[PMul]/[PDiv]) yields [ANum]; comparison ([PLt]/[PLe]/[PEq])
     yields the boolean type [ABool]. Precise Int-preserving result types
     ([Int+Int : AInt]) are DEFERRED — the sound [ANum] result suffices here. *)
  | TPrimArith : forall S G op a b,
      arith_op op = true ->
      has_type S G a (BAtom ANum) ->
      has_type S G b (BAtom ANum) ->
      has_type S G (tprim op a b) (BAtom ANum)
  | TPrimCmp : forall S G op a b,
      cmp_op op = true ->
      has_type S G a (BAtom ANum) ->
      has_type S G b (BAtom ANum) ->
      has_type S G (tprim op a b) (BAtom ABool)
  | TLam  : forall S G T body Tb,
      has_type S (T :: G) body Tb ->
      has_type S G (tlam T body) (BArrow T Tb)
  | TApp  : forall S G f a A B,
      has_type S G f (BArrow A B) ->
      has_type S G a A ->
      has_type S G (tapp f a) B
  | TLet  : forall S G e1 e2 A B,
      has_type S G e1 A ->
      has_type S (A :: G) e2 B ->
      has_type S G (tlet e1 e2) B
  | TRec  : forall S G fs Ts,
      has_fields S G fs Ts ->
      NoDup (map fst fs) ->
      has_type S G (trec fs) (BRec Ts)
  | TProj : forall S G e fields k T,
      has_type S G e (BRec fields) ->
      In (k, T) fields ->
      has_type S G (tproj e k) T
  | TSub  : forall S G e A T,
      has_type S G e A ->
      rsub A T ->          (* subsume along reference-aware rsub (sound for dsub) *)
      has_type S G e T
  | TIf   : forall S G c e1 e2 T1 T2,
      has_type S G c (BAtom ABool) ->
      has_type S G e1 T1 ->
      has_type S G e2 T2 ->
      has_type S G (tif c e1 e2) (BUnion T1 T2)
  (* INCREMENT 13 — NARROWING CONDITIONAL (truthiness occurrence typing). The
     scrutinee [c] (ANY type [U], Lua-truthy-tested) is BOUND FRESH (de Bruijn 0)
     in each branch at the NARROWED type: [truthy_type] in the then-branch [e1],
     [falsy_type] in the else-branch [e2]. Result = union of branch types. The
     fresh-binding is what makes narrowing sound under substitution semantics (see
     the [tifn] term-language note): the value-conditioned step substitutes the
     scrutinee into ONLY the selected branch, so no dead-branch residual carries a
     contradicted narrowing assumption.

     SCOPE (honest): the bound type is the truthy/falsy BOUND ALONE, not [U ∩
     truthy_type]. Carrying [U ∩ ...] (full occurrence-typing precision) needs an
     intersection-INTRODUCTION typing rule [TInter] whose ARROW inversion is the
     hard core of intersection-type systems ((A1→B1)∩(A2→B2) is NOT ssub-below any
     single arrow) — DEFERRED as intersection-type substrate (proof-kernel.md /
     TODO.md). Narrowing to the bound alone is SOUND and delivers the load-bearing
     payoff (a non-nil consumer applied to a then-narrowed scrutinee), which is the
     [and]/[or]-nil class that motivated this effort. *)
  | TIfn  : forall S G c e1 e2 U T1 T2,
      has_type S G c U ->
      has_type S (truthy_type :: G) e1 T1 ->
      has_type S (falsy_type :: G) e2 T2 ->
      has_type S G (tifn c e1 e2) (BUnion T1 T2)
  (* INCREMENT 14 — GENERAL RECURSION. The body, given the recursive binding [T]
     (de Bruijn 0 : T), has type [T]; the whole [tfix T body] then has type [T].
     The annotation [T] is what makes the form synthesizable. Type soundness holds
     even though [tfix] may diverge — the unfold step always makes progress and
     preserves the type [T] (substituting a [tfix…:T] for the self-ref [:T]). *)
  | TFix  : forall S G T body,
      has_type S (T :: G) body T ->
      has_type S G (tfix T body) T
  (* INCREMENT 15 — TYPE-TEST NARROWING. The scrutinee [c] has ANY type [U]. It is
     BOUND FRESH (de Bruijn 0) in each branch: the THEN-branch [e1] under
     [tag_type g] (the type the tag pins — POSITIVE narrowing, sound because a
     value whose runtime tag is [g] genuinely inhabits [tag_type g], proved as
     [tag_narrows]); the ELSE-branch [e2] under [U] (the scrutinee's own type — a
     sound OVER-approximation of the negative narrowing [U ∩ ¬tag_type g], whose
     PRECISE form needs intersection/negation and is DEFERRED). Result = union of
     branch types. The fresh-binding makes narrowing sound under substitution
     semantics, exactly as for [tifn]: the value-conditioned step substitutes the
     scrutinee into ONLY the selected branch. *)
  | TTypeTest : forall S G g c e1 e2 U T1 T2,
      has_type S G c U ->
      has_type S (tag_type g :: G) e1 T1 ->
      has_type S (U :: G) e2 T2 ->
      has_type S G (ttypetest g c e1 e2) (BUnion T1 T2)
  (* SPLIT-STEP 3 — THE IMPERATIVE RULES (ported from imp.v, unified here). *)
  (* a location [tloc n] is typed by the store-typing entry at [n], boxed [BRef]. *)
  | TLoc   : forall S G n T,
      nth_error S n = Some T ->
      has_type S G (tloc n) (BRef T)
  (* alloc of an [e : T] yields a reference [BRef T]. *)
  | TAlloc : forall S G e T,
      has_type S G e T ->
      has_type S G (talloc e) (BRef T)
  (* deref of an [e : BRef T] yields [T]. *)
  | TDeref : forall S G e T,
      has_type S G e (BRef T) ->
      has_type S G (tderef e) T
  (* assign [r := e] where [r : BRef T] and [e : T] yields the unit value (nil). *)
  | TAssign : forall S G r e T,
      has_type S G r (BRef T) ->
      has_type S G e T ->
      has_type S G (tassign r e) (BAtom ANil)
(* key-aligned pointwise typing of record fields; mutual so the generated
   induction principle carries an IH on every field derivation. *)
with has_fields : list BTy -> list BTy -> list (string * tm) -> list (string * BTy) -> Prop :=
  | HFnil  : forall S G, has_fields S G [] []
  | HFcons : forall S G k e T fs Ts,
      has_type S G e T ->
      has_fields S G fs Ts ->
      has_fields S G ((k, e) :: fs) ((k, T) :: Ts).

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
  | VRec  : forall fs, Forall (fun ke => value (snd ke)) fs -> value (trec fs)
  (* SPLIT-STEP 3 — a location is a value (a store address). *)
  | VLoc  : forall n, value (tloc n).

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
  | tprim op a b => tprim op (lift d k a) (lift d k b)
  | tlam T b  => tlam T (lift d (S k) b)
  | tapp f a  => tapp (lift d k f) (lift d k a)
  | tlet e1 e2 => tlet (lift d k e1) (lift d (S k) e2)
  | trec fs   => trec (map (fun ke => (fst ke, lift d k (snd ke))) fs)
  | tproj e k0 => tproj (lift d k e) k0
  | tif c e1 e2 => tif (lift d k c) (lift d k e1) (lift d k e2)
  (* tifn binds the scrutinee fresh (de Bruijn 0) in each branch: lift the
     branches under one new binder ([S k]); the scrutinee [c] itself is not under
     the fresh binder, so it lifts at [k]. *)
  | tifn c e1 e2 => tifn (lift d k c) (lift d (S k) e1) (lift d (S k) e2)
  (* tfix binds the self-reference fresh (de Bruijn 0) in the body: lift the body
     under one new binder ([S k]). *)
  | tfix T b  => tfix T (lift d (S k) b)
  (* ttypetest binds the scrutinee fresh (de Bruijn 0) in each branch: lift the
     branches under one new binder ([S k]); the scrutinee [c] lifts at [k]. *)
  | ttypetest g c e1 e2 =>
      ttypetest g (lift d k c) (lift d (S k) e1) (lift d (S k) e2)
  (* SPLIT-STEP 3 — reference ops recurse at [k]; a location is closed. *)
  | talloc e  => talloc (lift d k e)
  | tderef e  => tderef (lift d k e)
  | tassign r e => tassign (lift d k r) (lift d k e)
  | tloc n    => tloc n
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
  | tprim op a b => tprim op (subst j s a) (subst j s b)
  | tlam T b  => tlam T (subst (S j) (lift 1 0 s) b)
  | tapp f a  => tapp (subst j s f) (subst j s a)
  | tlet e1 e2 => tlet (subst j s e1) (subst (S j) (lift 1 0 s) e2)
  | trec fs   => trec (map (fun ke => (fst ke, subst j s (snd ke))) fs)
  | tproj e k => tproj (subst j s e) k
  | tif c e1 e2 => tif (subst j s c) (subst j s e1) (subst j s e2)
  (* tifn branches are under one fresh binder: substitute at [S j] with [s]
     lifted past that binder; the scrutinee [c] is not under the binder. *)
  | tifn c e1 e2 =>
      tifn (subst j s c) (subst (S j) (lift 1 0 s) e1) (subst (S j) (lift 1 0 s) e2)
  (* tfix body is under one fresh binder (the self-ref): substitute at [S j] with
     [s] lifted past that binder. *)
  | tfix T b  => tfix T (subst (S j) (lift 1 0 s) b)
  (* ttypetest branches are under one fresh binder: substitute at [S j] with [s]
     lifted past that binder; the scrutinee [c] is not under the binder. *)
  | ttypetest g c e1 e2 =>
      ttypetest g (subst j s c)
        (subst (S j) (lift 1 0 s) e1) (subst (S j) (lift 1 0 s) e2)
  (* SPLIT-STEP 3 — reference ops substitute at [j]; a location is closed. *)
  | talloc e  => talloc (subst j s e)
  | tderef e  => tderef (subst j s e)
  | tassign r e => tassign (subst j s r) (subst j s e)
  | tloc n    => tloc n
  end.

(* record-field lookup at the term level (for projection) *)
Fixpoint field_lookup (k : string) (fs : list (string * tm)) : option tm :=
  match fs with
  | [] => None
  | (k', e) :: rest => if string_dec k k' then Some e else field_lookup k rest
  end.

(* ---- INCREMENT 13 — TRUTHINESS predicates on VALUES (Lua semantics) --------
   Falsy = nil literal or the boolean [false]; truthy = every other value
   (numbers, strings, [true], lambdas, records). These drive the value-
   conditioned narrowing-conditional step: a truthy scrutinee selects the
   then-branch, a falsy one the else-branch. [truthy_value]/[falsy_value] are
   defined on TERMS but only meaningful on values; [truthy_or_falsy_value] proves
   the partition is total on values (used in progress). *)
Definition falsy_value (v : tm) : Prop :=
  v = tlit (LBool false) \/ v = tlit LNil.

Definition truthy_value (v : tm) : Prop :=
  ~ falsy_value v.

(* a value is either truthy or falsy (decidably) — the total partition. *)
Lemma value_truthy_or_falsy : forall v, value v -> truthy_value v \/ falsy_value v.
Proof.
  intros v Hv. unfold truthy_value, falsy_value.
  destruct Hv as [l | T b | fs Hfs | n].
  - destruct l as [n | n | [|] | ].
    + left. intros [H | H]; discriminate.
    + left. intros [H | H]; discriminate.
    + left. intros [H | H]; discriminate.     (* LBool true *)
    + right. left. reflexivity.                (* LBool false *)
    + right. right. reflexivity.               (* LNil *)
  - left. intros [H | H]; discriminate.
  - left. intros [H | H]; discriminate.
  - (* tloc: a location is TRUTHY *) left. intros [H | H]; discriminate.
Qed.

(* truthy and falsy are mutually exclusive (a value is not both). *)
Lemma truthy_not_falsy : forall v, truthy_value v -> falsy_value v -> False.
Proof. intros v Ht Hf. exact (Ht Hf). Qed.

(* ---- INCREMENT 15 — the RUNTIME TYPE-TAG of a term (Lua [type()]) ----------
   [has_tag v g] holds iff value [v]'s runtime kind matches tag [g]. Defined on
   TERMS (only meaningful on values), driving the value-conditioned type-test
   step: a scrutinee value whose tag is [g] selects the then-branch, else the
   else-branch. The number tag matches the single number literal [LInt] (the 5.1
   number model: [type()] returns "number" for every number). [has_tag] is TOTAL
   on values ([value_has_some_tag]) and the tag is UNIQUE ([has_tag_unique]) —
   together the total partition the type test selects on (used in progress). *)
Definition has_tag (v : tm) (g : tag) : Prop :=
  match g, v with
  | TgNum,   tlit (LInt _)  => True
  | TgStr,   tlit (LStr _)  => True
  | TgBool,  tlit (LBool _) => True
  | TgNil,   tlit LNil      => True
  | TgTable, trec _         => True
  | TgFun,   tlam _ _       => True
  | TgRef,   tloc _         => True       (* SPLIT-STEP 3 — a location's tag *)
  | _, _ => False
  end.

(* every value has SOME tag (the type-test always selects a branch). *)
Lemma value_has_some_tag : forall v, value v -> exists g, has_tag v g.
Proof.
  intros v Hv. destruct Hv as [l | T b | fs Hfs | n].
  - destruct l as [n | n | bb | ].
    + exists TgNum; exact I.
    + exists TgStr; exact I.
    + exists TgBool; exact I.
    + exists TgNil; exact I.
  - exists TgFun; exact I.
  - exists TgTable; exact I.
  - exists TgRef; exact I.                (* tloc *)
Qed.

(* a value's tag is unique (it cannot match two distinct tags). *)
Lemma has_tag_unique : forall v g1 g2, has_tag v g1 -> has_tag v g2 -> g1 = g2.
Proof.
  intros v g1 g2 H1 H2. destruct g1; destruct g2; try reflexivity;
    destruct v; try destruct l; simpl in H1, H2; contradiction.
Qed.

(* DECIDABLE: a value either has tag [g] or it has some OTHER tag. The total
   partition the type-test selects on (mirrors [value_truthy_or_falsy]). *)
Lemma value_tag_or_not : forall v g,
  value v -> has_tag v g \/ (exists g', g' <> g /\ has_tag v g').
Proof.
  intros v g Hv. destruct (value_has_some_tag v Hv) as [g0 Hg0].
  destruct (tag_eq_dec g0 g) as [Heq | Hne].
  - subst g0. left; exact Hg0.
  - right. exists g0. split; [exact Hne | exact Hg0].
Qed.

(* ---- STORE + CONFIGURATION operational semantics (ported from imp.v) --------
   [store := list tm] (location n ↦ nth n store). [step] is now over CONFIGURATIONS
   [(e, st)]: every pre-existing reduction/congruence threads the store UNCHANGED;
   the three reference reductions MUTATE it — [talloc] appends, [tderef] reads,
   [tassign] updates. *)

Definition store := list tm.

Fixpoint store_update (n : nat) (v : tm) (st : store) : store :=
  match st, n with
  | [], _ => []
  | _ :: rest, 0 => v :: rest
  | x :: rest, S n' => x :: store_update n' v rest
  end.

Definition store_lookup (n : nat) (st : store) : tm := nth n st (tlit LNil).

Inductive step : tm * store -> tm * store -> Prop :=
  (* beta: (\T.b) v  ->  b[0 := v]  *)
  | SBeta : forall T b v st,
      value v ->
      step (tapp (tlam T b) v, st) (subst 0 v b, st)
  (* let: bind a value, substitute into the body *)
  | SLet  : forall v e2 st,
      value v ->
      step (tlet v e2, st) (subst 0 v e2, st)
  (* projection lookup on a record value *)
  | SProj : forall fs k v st,
      value (trec fs) ->
      field_lookup k fs = Some v ->
      step (tproj (trec fs) k, st) (v, st)
  (* INCREMENT 19 — PRIMITIVE operators. Left-to-right congruence reduces the
     operands to values; then a fully-evaluated primop COMPUTES. Arithmetic on two
     number values [tlit (LInt m)], [tlit (LInt n)] yields [tlit (LInt (prim_arith
     op m n))] (nat arithmetic — [3 + 4 = 7]); comparison yields [tlit (LBool
     (prim_cmp op m n))] (the real nat comparison — [3 < 4 = true]). A [tprim] on a
     non-number operand is STUCK (a type error the checker prevents). *)
  | SPrim1 : forall op a a' b st st',
      step (a, st) (a', st') -> step (tprim op a b, st) (tprim op a' b, st')
  | SPrim2 : forall op v b b' st st',
      value v -> step (b, st) (b', st') -> step (tprim op v b, st) (tprim op v b', st')
  | SPrimArith : forall op m n st,
      arith_op op = true ->
      step (tprim op (tlit (LInt m)) (tlit (LInt n)), st)
           (tlit (LInt (prim_arith op m n)), st)
  | SPrimCmp : forall op m n st,
      cmp_op op = true ->
      step (tprim op (tlit (LInt m)) (tlit (LInt n)), st)
           (tlit (LBool (prim_cmp op m n)), st)
  (* congruence / evaluation contexts (CBV, left-to-right) — store threaded *)
  | SApp1 : forall f f' a st st', step (f, st) (f', st') -> step (tapp f a, st) (tapp f' a, st')
  | SApp2 : forall v a a' st st', value v -> step (a, st) (a', st') -> step (tapp v a, st) (tapp v a', st')
  | SLet1 : forall e1 e1' e2 st st', step (e1, st) (e1', st') -> step (tlet e1 e2, st) (tlet e1' e2, st')
  | SProj1 : forall e e' k st st', step (e, st) (e', st') -> step (tproj e k, st) (tproj e' k, st')
  (* record: step the first non-value field (left-to-right) *)
  | SRec  : forall pre k e e' post st st',
      Forall (fun ke => value (snd ke)) pre ->
      step (e, st) (e', st') ->
      step (trec (pre ++ (k, e) :: post), st) (trec (pre ++ (k, e') :: post), st')
  (* INCREMENT 11 — conditional reduction. *)
  | SIfTrue  : forall e1 e2 st, step (tif (tlit (LBool true)) e1 e2, st) (e1, st)
  | SIfFalse : forall e1 e2 st, step (tif (tlit (LBool false)) e1 e2, st) (e2, st)
  | SIf1     : forall c c' e1 e2 st st', step (c, st) (c', st') -> step (tif c e1 e2, st) (tif c' e1 e2, st')
  (* INCREMENT 13 — NARROWING conditional, VALUE-CONDITIONED. *)
  | SIfnTrue  : forall v e1 e2 st,
      value v -> truthy_value v -> step (tifn v e1 e2, st) (subst 0 v e1, st)
  | SIfnFalse : forall v e1 e2 st,
      value v -> falsy_value v -> step (tifn v e1 e2, st) (subst 0 v e2, st)
  | SIfn1     : forall c c' e1 e2 st st', step (c, st) (c', st') -> step (tifn c e1 e2, st) (tifn c' e1 e2, st')
  (* INCREMENT 14 — RECURSIVE UNFOLD. *)
  | SFix      : forall T body st, step (tfix T body, st) (subst 0 (tfix T body) body, st)
  (* INCREMENT 15 — TYPE-TEST narrowing, VALUE-CONDITIONED. *)
  | STtTrue  : forall g v e1 e2 st,
      value v -> has_tag v g -> step (ttypetest g v e1 e2, st) (subst 0 v e1, st)
  | STtFalse : forall g g' v e1 e2 st,
      value v -> g' <> g -> has_tag v g' -> step (ttypetest g v e1 e2, st) (subst 0 v e2, st)
  | STt1     : forall g c c' e1 e2 st st',
      step (c, st) (c', st') -> step (ttypetest g c e1 e2, st) (ttypetest g c' e1 e2, st')
  (* SPLIT-STEP 3 — THE IMPERATIVE REDUCTIONS (ported from imp.v). *)
  (* alloc: a VALUE allocates a fresh cell at the end; returns its location *)
  | SAlloc : forall v st, value v ->
      step (talloc v, st) (tloc (List.length st), app st [v])
  | SAlloc1 : forall e e' st st', step (e, st) (e', st') -> step (talloc e, st) (talloc e', st')
  (* deref: read the cell at a location value *)
  | SDeref : forall n st,
      step (tderef (tloc n), st) (store_lookup n st, st)
  | SDeref1 : forall e e' st st', step (e, st) (e', st') -> step (tderef e, st) (tderef e', st')
  (* assign: write a VALUE to the cell at a location value; yields unit (nil) *)
  | SAssign : forall n v st, value v ->
      step (tassign (tloc n) v, st) (tlit LNil, store_update n v st)
  | SAssign1 : forall r r' e st st', step (r, st) (r', st') -> step (tassign r e, st) (tassign r' e, st')
  | SAssign2 : forall v e e' st st', value v -> step (e, st) (e', st') ->
      step (tassign v e, st) (tassign v e', st').

(* STORE well-typedness + extension (ported from imp.v). [store_well_typed S st]:
   same length, each stored value has its S-type (closed — stored values are
   closed). [extends S' S]: S' is S with cells appended (the monotone growth of
   allocation). *)
Definition store_well_typed (S : list BTy) (st : store) : Prop :=
  List.length S = List.length st /\
  (forall n T, nth_error S n = Some T -> has_type S [] (store_lookup n st) T).

Definition extends (S' S : list BTy) : Prop := exists ext, S' = S ++ ext.

Lemma extends_refl : forall S, extends S S.
Proof. intro S. exists []. rewrite app_nil_r. reflexivity. Qed.

Lemma extends_trans : forall A B C, extends B A -> extends C B -> extends C A.
Proof.
  intros A B C [e1 H1] [e2 H2]. subst. exists (e1 ++ e2). rewrite app_assoc. reflexivity.
Qed.

Lemma extends_app1 : forall S T, extends (S ++ [T]) S.
Proof. intros S T. exists [T]. reflexivity. Qed.

Lemma extends_nth_error : forall S' S n T,
  extends S' S -> nth_error S n = Some T -> nth_error S' n = Some T.
Proof.
  intros S' S n T [ext He] Hn. subst S'.
  rewrite nth_error_app1; [ exact Hn | apply nth_error_Some; rewrite Hn; discriminate ].
Qed.

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

(* All inversion lemmas now thread [S] (store typing, fixed) and conclude [rsub]
   (the subsumption relation [TSub] uses). The [TSub] case composes via [RsTrans];
   the base case is [rsub_refl]. *)

Lemma inv_lit : forall S G l T,
  has_type S G (tlit l) T -> rsub (lit_type l) T.
Proof.
  intros S G l T H. remember (tlit l) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <-. apply rsub_refl.
  - subst. eapply RsTrans; [ apply IHhas_type; reflexivity | exact H0 ].
Qed.

(* INCREMENT 19 — primop inversion (subsumption-transparent). The result type is
   [ANum] (arithmetic) or [ABool] (comparison); both subsume to [T]. The operands
   are typed at [ANum]. *)
Lemma inv_prim : forall S G op a b T,
  has_type S G (tprim op a b) T ->
  has_type S G a (BAtom ANum) /\ has_type S G b (BAtom ANum) /\
  ((arith_op op = true /\ rsub (BAtom ANum) T) \/
   (cmp_op op = true /\ rsub (BAtom ABool) T)).
Proof.
  intros S G op a b T H. remember (tprim op a b) as e eqn:Ee.
  induction H; try discriminate Ee.
  - (* TPrimArith *) injection Ee as <- <- <-.
    split; [assumption|split;[assumption| left; split;[assumption|apply rsub_refl]]].
  - (* TPrimCmp *) injection Ee as <- <- <-.
    split; [assumption|split;[assumption| right; split;[assumption|apply rsub_refl]]].
  - (* TSub *) subst. destruct (IHhas_type eq_refl) as [Ha [Hb [[Har Hd]|[Hcr Hd]]]].
    + split;[assumption|split;[assumption| left; split;[assumption|eapply RsTrans; eassumption]]].
    + split;[assumption|split;[assumption| right; split;[assumption|eapply RsTrans; eassumption]]].
Qed.

Lemma inv_var : forall S G n T,
  has_type S G (tvar n) T -> exists U, nth_error G n = Some U /\ rsub U T.
Proof.
  intros S G n T H. remember (tvar n) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <-. exists T. split; [assumption | apply rsub_refl].
  - subst. destruct (IHhas_type eq_refl) as [U0 [Hl Hd]].
    exists U0. split; [assumption | eapply RsTrans; eassumption].
Qed.

Lemma inv_lam : forall S G Tl b T,
  has_type S G (tlam Tl b) T ->
  exists Tb, has_type S (Tl :: G) b Tb /\ rsub (BArrow Tl Tb) T.
Proof.
  intros S G Tl b T H. remember (tlam Tl b) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists Tb. split; [assumption | apply rsub_refl].
  - subst. destruct (IHhas_type eq_refl) as [Tb [Hb Hd]].
    exists Tb. split; [assumption | eapply RsTrans; eassumption].
Qed.

Lemma inv_app : forall S G f a T,
  has_type S G (tapp f a) T ->
  exists A B, has_type S G f (BArrow A B) /\ has_type S G a A /\ rsub B T.
Proof.
  intros S G f a T H. remember (tapp f a) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists A, B. split; [assumption|split;[assumption|apply rsub_refl]].
  - subst. destruct (IHhas_type eq_refl) as [A0 [B0 [Hf [Ha Hd]]]].
    exists A0, B0. split; [assumption|split;[assumption|eapply RsTrans; eassumption]].
Qed.

Lemma inv_let : forall S G e1 e2 T,
  has_type S G (tlet e1 e2) T ->
  exists A B, has_type S G e1 A /\ has_type S (A :: G) e2 B /\ rsub B T.
Proof.
  intros S G e1 e2 T H. remember (tlet e1 e2) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists A, B. split;[assumption|split;[assumption|apply rsub_refl]].
  - subst. destruct (IHhas_type eq_refl) as [A0 [B0 [H1 [H2 Hd]]]].
    exists A0, B0. split;[assumption|split;[assumption|eapply RsTrans; eassumption]].
Qed.

Lemma inv_rec : forall S G fs T,
  has_type S G (trec fs) T ->
  exists Ts, has_fields S G fs Ts /\ NoDup (map fst fs) /\ rsub (BRec Ts) T.
Proof.
  intros S G fs T H. remember (trec fs) as e eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <-. exists Ts. split; [assumption | split; [assumption | apply rsub_refl]].
  - subst. destruct (IHhas_type eq_refl) as [Ts [Hf [Hnd Hd]]].
    exists Ts. split; [assumption | split; [assumption | eapply RsTrans; eassumption]].
Qed.

Lemma inv_proj : forall S G e k T,
  has_type S G (tproj e k) T ->
  exists fields U, has_type S G e (BRec fields) /\ In (k, U) fields /\ rsub U T.
Proof.
  intros S G e k T H. remember (tproj e k) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - injection Ee as <- <-. exists fields, T. split;[assumption|split;[assumption|apply rsub_refl]].
  - subst. destruct (IHhas_type eq_refl) as [fields [U0 [He [Hin Hd]]]].
    exists fields, U0. split;[assumption|split;[assumption|eapply RsTrans; eassumption]].
Qed.

Lemma inv_if : forall S G c e1 e2 T,
  has_type S G (tif c e1 e2) T ->
  exists U1 U2, has_type S G c (BAtom ABool) /\ has_type S G e1 U1 /\
                has_type S G e2 U2 /\ rsub (BUnion U1 U2) T.
Proof.
  intros S G c e1 e2 T H. remember (tif c e1 e2) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [U1 [U2 [Hc [H1 [H2 Hd]]]]].
    exists U1, U2. split;[assumption|split;[assumption|split;[assumption|eapply RsTrans; eassumption]]].
  - injection Ee as <- <- <-. do 2 eexists.
    split;[eassumption|split;[eassumption|split;[eassumption|apply rsub_refl]]].
Qed.

Lemma inv_ifn : forall S G c e1 e2 T,
  has_type S G (tifn c e1 e2) T ->
  exists U T1 T2, has_type S G c U /\
                  has_type S (truthy_type :: G) e1 T1 /\
                  has_type S (falsy_type :: G) e2 T2 /\
                  rsub (BUnion T1 T2) T.
Proof.
  intros S G c e1 e2 T H. remember (tifn c e1 e2) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [U [T1 [T2 [Hc [H1 [H2 Hd]]]]]].
    exists U, T1, T2.
    split;[assumption|split;[assumption|split;[assumption|eapply RsTrans; eassumption]]].
  - injection Ee as <- <- <-. do 3 eexists.
    split;[eassumption|split;[eassumption|split;[eassumption|apply rsub_refl]]].
Qed.

Lemma inv_fix : forall S G Tf body T,
  has_type S G (tfix Tf body) T ->
  has_type S (Tf :: G) body Tf /\ rsub Tf T.
Proof.
  intros S G Tf body T H. remember (tfix Tf body) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [Hb Hd].
    split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <- <-. split; [assumption | apply rsub_refl].
Qed.

Lemma inv_typetest : forall S G g c e1 e2 T,
  has_type S G (ttypetest g c e1 e2) T ->
  exists U T1 T2, has_type S G c U /\
                  has_type S (tag_type g :: G) e1 T1 /\
                  has_type S (U :: G) e2 T2 /\
                  rsub (BUnion T1 T2) T.
Proof.
  intros S G g c e1 e2 T H. remember (ttypetest g c e1 e2) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [U [T1 [T2 [Hc [H1 [H2 Hd]]]]]].
    exists U, T1, T2.
    split;[assumption|split;[assumption|split;[assumption|eapply RsTrans; eassumption]]].
  - injection Ee as <- <- <- <-. do 3 eexists.
    split;[eassumption|split;[eassumption|split;[eassumption|apply rsub_refl]]].
Qed.

(* SPLIT-STEP 3 — REFERENCE inversion lemmas (ported from imp.v's [rinv_*]). *)
Lemma inv_loc : forall S G n T,
  has_type S G (tloc n) T -> exists U, nth_error S n = Some U /\ rsub (BRef U) T.
Proof.
  intros S G n T H. remember (tloc n) as e eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [U [Hl Hd]].
    exists U. split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <-. exists T. split; [assumption | apply rsub_refl].
Qed.

Lemma inv_alloc : forall S G e T,
  has_type S G (talloc e) T -> exists U, has_type S G e U /\ rsub (BRef U) T.
Proof.
  intros S G e T H. remember (talloc e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [U [He Hd]].
    exists U. split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <-. exists T. split; [assumption | apply rsub_refl].
Qed.

Lemma inv_deref : forall S G e T,
  has_type S G (tderef e) T -> exists U, has_type S G e (BRef U) /\ rsub U T.
Proof.
  intros S G e T H. remember (tderef e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [U [He Hd]].
    exists U. split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <-. exists T. split; [assumption | apply rsub_refl].
Qed.

Lemma inv_assign : forall S G r e T,
  has_type S G (tassign r e) T ->
  exists U, has_type S G r (BRef U) /\ has_type S G e U /\ rsub (BAtom ANil) T.
Proof.
  intros S G r e T H. remember (tassign r e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [U [Hr [He Hd]]].
    exists U. split;[assumption|split;[assumption|eapply RsTrans; eassumption]].
  - injection Ee as <- <-. exists T. split;[assumption|split;[assumption|apply rsub_refl]].
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
  (* INCREMENT 12 — an arrow lies above [Tl∩Tr] iff above BOTH (meet-on-right). *)
  | BInter Tl Tr  => arrow_above A1 B1 Tl /\ arrow_above A1 B1 Tr
  | _             => False
  end.

Fixpoint rec_above (f : list (string * BTy)) (T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BRec g        => srec f g
  | BUnion Tl Tr  => rec_above f Tl \/ rec_above f Tr
  | BInter Tl Tr  => rec_above f Tl /\ rec_above f Tr
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
  - (* SsInterPL: Hab : arrow_above Ax Bx A /\ arrow_above Ax Bx B; use the LEFT. *)
    destruct Hab as [Ha _].
    match goal with [ IH : forall _ _, arrow_above _ _ ?m -> _ |- _ ] => apply (IH Ax Bx); exact Ha end.
  - (* SsInterPR: use the RIGHT conjunct. *)
    destruct Hab as [_ Hb].
    match goal with [ IH : forall _ _, arrow_above _ _ ?m -> _ |- _ ] => apply (IH Ax Bx); exact Hb end.
  - (* SsInterI: goal arrow_above Ax Bx (A∩B) = both; each via its IH on Hab. *)
    split;
      [ match goal with [ IH : forall _ _, arrow_above _ _ ?m -> arrow_above _ _ ?a
                          |- arrow_above ?Ax ?Bx ?a ] => apply (IH Ax Bx); exact Hab end
      | match goal with [ IH : forall _ _, arrow_above _ _ ?m -> arrow_above _ _ ?b
                          |- arrow_above ?Ax ?Bx ?b ] => apply (IH Ax Bx); exact Hab end ].
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
  - (* SsInterPL *) destruct Hab as [Ha _].
    match goal with [ IH : forall _, rec_above _ ?m -> _ |- _ ] => apply (IH f0); exact Ha end.
  - (* SsInterPR *) destruct Hab as [_ Hb].
    match goal with [ IH : forall _, rec_above _ ?m -> _ |- _ ] => apply (IH f0); exact Hb end.
  - (* SsInterI *) split;
      [ match goal with [ IH : forall _, rec_above _ ?m -> rec_above _ ?a |- rec_above ?f0 ?a ] =>
          apply (IH f0); exact Hab end
      | match goal with [ IH : forall _, rec_above _ ?m -> rec_above _ ?b |- rec_above ?f0 ?b ] =>
          apply (IH f0); exact Hab end ].
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


(* ---- NEGATION is the sole remaining DEFERRED connective: [ssub] has NO
   structural rule for [BNeg] (INCREMENT 12 added structural intersection rules,
   so [BInter] is now decided structurally — only [BNeg] stays reflexive-only).
   We characterize [BNeg]'s supertypes with the SAME union/inter-robust [_above]
   mechanism so the decider's [BNeg]-leaf cases stay complete WITHOUT a negation
   decision (which remains future work). [is_inter_neg] is now the [BNeg] head
   ONLY (the name kept for continuity; it picks the reflexive-only connective). *)

Definition is_inter_neg (t : BTy) : Prop :=
  match t with BNeg _ => True | _ => False end.

(* supertypes of a [BNeg] type [S]: BTop, [S] itself, a union of such (one
   disjunct), or an intersection of such (BOTH conjuncts — meet-on-right). *)
Fixpoint interneg_above (S T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BUnion Tl Tr  => interneg_above S Tl \/ interneg_above S Tr
  | BInter Tl Tr  => interneg_above S Tl /\ interneg_above S Tr
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
  - (* SsInterPL: Hab : interneg_above S A /\ interneg_above S B; LEFT. *)
    destruct Hab as [Ha _].
    match goal with [ IH : forall _, _ -> interneg_above _ ?m -> _ |- _ ] =>
      apply (IH S Hin); exact Ha end.
  - (* SsInterPR: RIGHT. *)
    destruct Hab as [_ Hb].
    match goal with [ IH : forall _, _ -> interneg_above _ ?m -> _ |- _ ] =>
      apply (IH S Hin); exact Hb end.
  - (* SsInterI: goal interneg_above S (A∩B) = both; each via its IH on Hab. *)
    split;
      [ match goal with [ IH : forall _, _ -> interneg_above _ ?m -> interneg_above _ ?a
                          |- interneg_above ?S ?a ] => apply (IH S Hin); exact Hab end
      | match goal with [ IH : forall _, _ -> interneg_above _ ?m -> interneg_above _ ?b
                          |- interneg_above ?S ?b ] => apply (IH S Hin); exact Hab end ].
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
  | BInter _ _ => True
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
  | BInter Tl Tr  => atom_above x Tl /\ atom_above x Tr
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
  - (* SsInterPL *) destruct Hab as [Ha _].
    match goal with [ IH : forall _, atom_above _ ?m -> _ |- _ ] => apply (IH x0); exact Ha end.
  - (* SsInterPR *) destruct Hab as [_ Hb].
    match goal with [ IH : forall _, atom_above _ ?m -> _ |- _ ] => apply (IH x0); exact Hb end.
  - (* SsInterI *) split;
      [ match goal with [ IH : forall _, atom_above _ ?m -> atom_above _ ?a |- atom_above ?x0 ?a ] =>
          apply (IH x0); exact Hab end
      | match goal with [ IH : forall _, atom_above _ ?m -> atom_above _ ?b |- atom_above ?x0 ?b ] =>
          apply (IH x0); exact Hab end ].
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
  | BInter Tl Tr  => top_above Tl /\ top_above Tr
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
  - (* SsInterPL *) destruct Hab as [Ha _].
    match goal with [ IH : top_above ?m -> _ |- _ ] => apply IH; exact Ha end.
  - (* SsInterPR *) destruct Hab as [_ Hb].
    match goal with [ IH : top_above ?m -> _ |- _ ] => apply IH; exact Hb end.
  - (* SsInterI *) split;
      [ match goal with [ IH : top_above ?m -> top_above ?a |- top_above ?a ] => apply IH; exact Hab end
      | match goal with [ IH : top_above ?m -> top_above ?b |- top_above ?b ] => apply IH; exact Hab end ].
Qed.

Lemma ssub_top_super : forall T, ssub BTop T -> top_above T.
Proof. intros T H. apply (top_above_mono BTop T H). simpl. exact I. Qed.

Lemma ssub_atom_atom : forall x y, ssub (BAtom x) (BAtom y) -> atom_le x y \/ x = y.
Proof.
  intros x y H. apply ssub_atom_super in H. simpl in H. exact H.
Qed.

(* ---- CONNECTIVE-TARGET inversion — the DECIDER's union/intersection-target
   completeness, via the SUPERTYPE [_above] predicates' SOUNDNESS converses.

   INCREMENT 12 — the OLD [union_below] (a leftward subtype-side predicate)
   becomes UNPROVABLE-monotone once intersection [ssub] rules exist: the
   intersection-on-the-LEFT vs union-on-the-RIGHT cross is exactly the
   NON-DISTRIBUTIVE frontier (mirroring subtype.v's N5: the free lattice is
   provably non-distributive). E.g. [(B∪C)∩X <: B∪C] holds (via [SsInterPL] from
   refl) yet is NOT below [B] nor below [C] alone — so the leaf disjunction
   [ssub X B \/ ssub X C] is NOT preserved by [SsInterPL], and [union_below_mono]
   genuinely fails (no structural [BInter] form satisfies all of
   [SsInterPL]/[SsInterPR]/[SsInterI] simultaneously — proven by the three
   pairwise-incompatible attempts).

   The CLEAN replacement: invert a connective TARGET against a LEAF source using
   the RIGHTWARD [_above] predicates (already extended with the [BInter] [/\]
   case, monotone-closed under [ssub]) plus their SOUNDNESS converses
   ([K_above S T -> ssub S T], by induction on T). The decider strips
   union/inter SOURCES first (union-on-left elim, inter-on-left projection), so
   target inversion is only ever needed for a LEAF source — exactly where the
   [_above] route is robust, handling union AND intersection targets uniformly. *)

(* SOUNDNESS converses of the [_above] predicates: the predicate IMPLIES the
   subtyping. Each by induction on the supertype [T]; the union case picks the
   holding disjunct ([SsUnionInL]/[InR]), the intersection case meets both
   ([SsInterI]), Top is [SsTop], the leaf rebuilds the kind's [ssub]. *)
Lemma atom_above_sound : forall x T, atom_above x T -> ssub (BAtom x) T.
Proof.
  intros x T. induction T; simpl; intro Hab; try contradiction.
  - destruct Hab as [Hle | Heq]; [ apply SsAtom; exact Hle | subst; apply SsRefl ].
  - apply SsTop.
  - destruct Hab as [Hl | Hr]; [ apply SsUnionInL; apply IHT1; exact Hl
                               | apply SsUnionInR; apply IHT2; exact Hr ].
  - destruct Hab as [Hl Hr]; apply SsInterI; [ apply IHT1; exact Hl | apply IHT2; exact Hr ].
Qed.

Lemma top_above_sound : forall T, top_above T -> ssub BTop T.
Proof.
  intro T. induction T; simpl; intro Hab; try contradiction.
  - apply SsTop.
  - destruct Hab as [Hl | Hr]; [ apply SsUnionInL; apply IHT1; exact Hl
                               | apply SsUnionInR; apply IHT2; exact Hr ].
  - destruct Hab as [Hl Hr]; apply SsInterI; [ apply IHT1; exact Hl | apply IHT2; exact Hr ].
Qed.

Lemma arrow_above_sound : forall A1 B1 T, arrow_above A1 B1 T -> ssub (BArrow A1 B1) T.
Proof.
  intros A1 B1 T. induction T; simpl; intro Hab; try contradiction.
  - apply SsTop.
  - destruct Hab as [Hl | Hr]; [ apply SsUnionInL; apply IHT1; exact Hl
                               | apply SsUnionInR; apply IHT2; exact Hr ].
  - destruct Hab as [Hl Hr]; apply SsInterI; [ apply IHT1; exact Hl | apply IHT2; exact Hr ].
  - destruct Hab as [Hd Hc]; apply SsArrow; assumption.
Qed.

Lemma rec_above_sound : forall f T, rec_above f T -> ssub (BRec f) T.
Proof.
  intros f T. induction T; simpl; intro Hab; try contradiction.
  - apply SsTop.
  - destruct Hab as [Hl | Hr]; [ apply SsUnionInL; apply IHT1; exact Hl
                               | apply SsUnionInR; apply IHT2; exact Hr ].
  - destruct Hab as [Hl Hr]; apply SsInterI; [ apply IHT1; exact Hl | apply IHT2; exact Hr ].
  - apply SsRec; exact Hab.
Qed.

Lemma interneg_above_sound : forall S T, is_inter_neg S -> interneg_above S T -> ssub S T.
Proof.
  intros S T Hin. induction T; simpl; intro Hab;
    try (rewrite <- Hab; apply SsRefl).
  - apply SsTop.
  - destruct Hab as [Hl | Hr]; [ apply SsUnionInL; apply IHT1; exact Hl
                               | apply SsUnionInR; apply IHT2; exact Hr ].
  - destruct Hab as [Hl Hr]; apply SsInterI; [ apply IHT1; exact Hl | apply IHT2; exact Hr ].
Qed.

(* UNION-TARGET leaf inversion: a LEAF [X] (atom/arrow/rec/neg) below [B ∪ C] is
   below [B] or below [C]. Read off the kind's [_above] predicate at [B ∪ C]
   (a disjunction by the [BUnion] case), then [_above_sound] rebuilds the [ssub].
   Bot/Top/Union/Inter sources are handled by the decider's own prior clauses, so
   here they return [True]. *)
Lemma ssub_union_tgt_inv : forall X B C,
  ssub X (BUnion B C) ->
  match X with
  | BAtom _ | BArrow _ _ | BRec _ | BNeg _ => ssub X B \/ ssub X C
  | _ => True
  end.
Proof.
  intros X B C H. destruct X; try exact I.
  - (* BAtom *) apply ssub_atom_super in H. simpl in H.
    destruct H as [Hl | Hr]; [ left; apply atom_above_sound; exact Hl
                             | right; apply atom_above_sound; exact Hr ].
  - (* BNeg *) apply (ssub_interneg_super (BNeg X) (BUnion B C) I) in H. simpl in H.
    destruct H as [Hl | Hr]; [ left; apply (interneg_above_sound (BNeg X) B I); exact Hl
                             | right; apply (interneg_above_sound (BNeg X) C I); exact Hr ].
  - (* BRec *) apply ssub_rec_super in H. simpl in H.
    destruct H as [Hl | Hr]; [ left; apply rec_above_sound; exact Hl
                             | right; apply rec_above_sound; exact Hr ].
  - (* BArrow *) apply ssub_arrow_super in H. simpl in H.
    destruct H as [Hl | Hr]; [ left; apply arrow_above_sound; exact Hl
                             | right; apply arrow_above_sound; exact Hr ].
Qed.

(* INTERSECTION-TARGET leaf inversion: a LEAF [X] below [B ∩ C] is below BOTH
   (read off the [/\] [BInter] case of the kind's [_above]). Used by the decider's
   intersection-on-right completeness for leaf sources. *)
Lemma ssub_inter_tgt_inv : forall X B C,
  ssub X (BInter B C) ->
  match X with
  | BAtom _ | BArrow _ _ | BRec _ | BNeg _ => ssub X B /\ ssub X C
  | _ => True
  end.
Proof.
  intros X B C H. destruct X; try exact I.
  - apply ssub_atom_super in H. simpl in H.
    destruct H as [Hl Hr]; split; apply atom_above_sound; assumption.
  - apply (ssub_interneg_super (BNeg X) (BInter B C) I) in H. simpl in H.
    destruct H as [Hl Hr]; split; apply (interneg_above_sound (BNeg X) _ I); assumption.
  - apply ssub_rec_super in H. simpl in H.
    destruct H as [Hl Hr]; split; apply rec_above_sound; assumption.
  - apply ssub_arrow_super in H. simpl in H.
    destruct H as [Hl Hr]; split; apply arrow_above_sound; assumption.
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
  destruct a; destruct v as [r| | | | | |]; simpl in Hv, Hav; contradiction.
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
  destruct a; destruct v as [r| | | | | |]; simpl in Hv; try contradiction;
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
   SPLIT-STEP 3 — [rsub] reference inversion (relocated here: needs the [ssub]
   shape machinery above — [srec], [atom_has_member], [denote_rec_iff]). These
   are the reference-source inversion + cross-kind not-subtyping consumers the
   canonical-forms / preservation cases below use.
   =========================================================================== *)
(* supertypes of [BRef S] under [rsub]. *)
Fixpoint rsub_ref_above (S T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BAnyRef       => True
  | BRef T'       => rsub S T' /\ rsub T' S
  | BUnion Tl Tr  => rsub_ref_above S Tl \/ rsub_ref_above S Tr
  | BInter Tl Tr  => rsub_ref_above S Tl /\ rsub_ref_above S Tr
  | _             => False
  end.

(* supertypes of [BAnyRef] under [rsub] — the same MINUS any [BRef _]. *)
Fixpoint rsub_anyref_above (T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BAnyRef       => True
  | BUnion Tl Tr  => rsub_anyref_above Tl \/ rsub_anyref_above Tr
  | BInter Tl Tr  => rsub_anyref_above Tl /\ rsub_anyref_above Tr
  | _             => False
  end.

Lemma rsub_ref_above_ssub_mono : forall M C, ssub M C ->
  forall S, rsub_ref_above S M -> rsub_ref_above S C.
Proof.
  intros M C H. induction H; intros S0 Hab; simpl in *;
    try exact I; try exact Hab; try contradiction.
  - apply IHssub2. apply IHssub1. exact Hab.
  - left. apply IHssub. exact Hab.
  - right. apply IHssub. exact Hab.
  - destruct Hab as [Ha|Hb]; [ apply IHssub1 | apply IHssub2 ]; assumption.
  - destruct Hab as [Ha _]. apply IHssub. exact Ha.
  - destruct Hab as [_ Hb]. apply IHssub. exact Hb.
  - split; [ apply IHssub1 | apply IHssub2 ]; exact Hab.
Qed.

Lemma rsub_anyref_above_ssub_mono : forall M C, ssub M C ->
  rsub_anyref_above M -> rsub_anyref_above C.
Proof.
  intros M C H. induction H; intro Hab; simpl in *;
    try exact I; try exact Hab; try contradiction.
  - apply IHssub2. apply IHssub1. exact Hab.
  - left. apply IHssub. exact Hab.
  - right. apply IHssub. exact Hab.
  - destruct Hab as [Ha|Hb]; [ apply IHssub1 | apply IHssub2 ]; assumption.
  - destruct Hab as [Ha _]. apply IHssub. exact Ha.
  - destruct Hab as [_ Hb]. apply IHssub. exact Hb.
  - split; [ apply IHssub1 | apply IHssub2 ]; exact Hab.
Qed.

Lemma rsub_above_mono : forall M C, rsub M C ->
  (forall S, rsub_ref_above S M -> rsub_ref_above S C) /\
  (rsub_anyref_above M -> rsub_anyref_above C).
Proof.
  intros M C H. induction H.
  - split;
      [ apply rsub_ref_above_ssub_mono; exact H | apply rsub_anyref_above_ssub_mono; exact H ].
  - destruct IHrsub1 as [Hr1 Ha1]. destruct IHrsub2 as [Hr2 Ha2].
    split; [ intros S Hab; apply Hr2; apply Hr1; exact Hab
           | intro Hab; apply Ha2; apply Ha1; exact Hab ].
  - split.
    + intros S0 Hab. simpl in Hab. destruct Hab as [HS0S HSS0]. simpl.
      split; [ eapply rsub_trans; eassumption | eapply rsub_trans; eassumption ].
    + intro Hab. simpl in Hab. contradiction.
  - split; [ intros S _; simpl; exact I | intro Hab; simpl in Hab; contradiction ].
Qed.

Lemma rsub_ref_super : forall S T, rsub (BRef S) T -> rsub_ref_above S T.
Proof.
  intros S T H. apply (proj1 (rsub_above_mono (BRef S) T H) S).
  simpl. split; apply rsub_refl.
Qed.

Lemma rsub_anyref_super : forall T, rsub BAnyRef T -> rsub_anyref_above T.
Proof.
  intros T H. apply (proj2 (rsub_above_mono BAnyRef T H)). simpl. exact I.
Qed.

(* consumer inversions the typing metatheory needs. *)
Lemma rsub_ref_inv : forall S T, rsub (BRef S) (BRef T) -> rsub S T /\ rsub T S.
Proof. intros S T H. apply rsub_ref_super in H. simpl in H. exact H. Qed.

Lemma rsub_anyref_not_ref : forall U, ~ rsub BAnyRef (BRef U).
Proof. intros U H. apply rsub_anyref_super in H. simpl in H. exact H. Qed.

(* an [rsub] whose source is a NON-reference, NON-connective leaf (atom / arrow /
   record / Bot / Neg) reduces to an [ssub] — the two ref rules cannot fire with
   such a source, so the embedded [ssub] is the only contributor. Proved by
   inducting and showing the ref constructors are unreachable from a leaf source.
   We need only the consumers below (arrow inv, atom/arrow/rec NOT below a ref),
   which we read off the [ssub] [_above] predicates after stripping [RsSsub]. *)

(* arrow inversion through [rsub]: an [rsub]-arrow-below-arrow gives variance.
   A [BArrow] source can only be related to a [BArrow] target via [RsSsub]
   (the ref rules have [BRef]/[BAnyRef] sources/targets), so [rsub] collapses to
   [ssub] here and [ssub_arrow_inv] applies. *)
Fixpoint rsub_arrow_above (A1 B1 T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BArrow A2 B2  => rsub A2 A1 /\ rsub B1 B2
  | BUnion Tl Tr  => rsub_arrow_above A1 B1 Tl \/ rsub_arrow_above A1 B1 Tr
  | BInter Tl Tr  => rsub_arrow_above A1 B1 Tl /\ rsub_arrow_above A1 B1 Tr
  | _             => False
  end.

Lemma rsub_arrow_above_ssub_mono : forall M C, ssub M C ->
  forall A1 B1, rsub_arrow_above A1 B1 M -> rsub_arrow_above A1 B1 C.
Proof.
  intros M C H. induction H; intros Ax Bx Hab; simpl in *;
    try exact I; try exact Hab; try contradiction.
  - apply IHssub2; [ ]. apply IHssub1; exact Hab.
  - (* SsArrow: recompose contra/co via rsub trans *)
    destruct Hab as [Hd Hc]. split;
      [ eapply rsub_trans; [ apply RsSsub; eassumption | exact Hd ]
      | eapply rsub_trans; [ exact Hc | apply RsSsub; eassumption ] ].
  - left. apply IHssub; exact Hab.
  - right. apply IHssub; exact Hab.
  - destruct Hab as [Ha|Hb]; [ apply IHssub1 | apply IHssub2 ]; assumption.
  - destruct Hab as [Ha _]. apply IHssub; exact Ha.
  - destruct Hab as [_ Hb]. apply IHssub; exact Hb.
  - split; [ apply IHssub1 | apply IHssub2 ]; exact Hab.
Qed.

Lemma rsub_arrow_above_mono : forall M C, rsub M C ->
  forall A1 B1, rsub_arrow_above A1 B1 M -> rsub_arrow_above A1 B1 C.
Proof.
  intros M C H. induction H; intros Ax Bx Hab; simpl in *.
  - eapply rsub_arrow_above_ssub_mono; eassumption.
  - apply IHrsub2. apply IHrsub1. exact Hab.
  - (* RsRefInv: source BRef, rsub_arrow_above _ _ (BRef _) = False *) contradiction.
  - (* RsAnyRef: source BRef, False *) contradiction.
Qed.

Lemma rsub_arrow_super : forall A1 B1 T, rsub (BArrow A1 B1) T -> rsub_arrow_above A1 B1 T.
Proof.
  intros A1 B1 T H. apply (rsub_arrow_above_mono (BArrow A1 B1) T H A1 B1).
  simpl. split; apply rsub_refl.
Qed.

Lemma rsub_arrow_inv : forall A1 B1 A2 B2,
  rsub (BArrow A1 B1) (BArrow A2 B2) -> rsub A2 A1 /\ rsub B1 B2.
Proof. intros A1 B1 A2 B2 H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.

(* ---- cross-kind NON-subtypings through [rsub] (contradiction consumers). The
   arrow/record/atom-not-below-a-reference facts use the [_above] predicate (False
   at a [BRef]/[BAnyRef] target); the atom/arrow/record-not-arrow/atom facts route
   through [rsub_sound] + the value model (an arrow/atom value is not a location,
   etc.). These are what canonical forms below need. *)

(* an atom is not [rsub]-below an arrow (semantic: atom member is no function). *)
Lemma rsub_atom_not_arrow : forall a A B, ~ rsub (BAtom a) (BArrow A B).
Proof.
  intros a A B H. apply rsub_sound in H.
  destruct (atom_has_member a) as [v Hv]. pose proof (H v Hv) as Hav.
  destruct a; destruct v as [r| | | | | |]; simpl in Hv, Hav; contradiction.
Qed.

(* an atom is not [rsub]-below a record (semantic). *)
Lemma rsub_atom_not_rec : forall a g, ~ rsub (BAtom a) (BRec g).
Proof.
  intros a g H. apply rsub_sound in H.
  destruct (atom_has_member a) as [v Hv]. pose proof (H v Hv) as Hav.
  apply denote_rec_iff in Hav. destruct Hav as [ents [Hbad _]].
  destruct a; destruct v as [r| | | | | |]; simpl in Hv; try contradiction; discriminate Hbad.
Qed.

(* an atom is not [rsub]-below a reference (semantic: atom member is not a loc). *)
Lemma rsub_atom_not_ref : forall a S, ~ rsub (BAtom a) (BRef S).
Proof.
  intros a S H. apply rsub_sound in H.
  destruct (atom_has_member a) as [v Hv]. pose proof (H v Hv) as Hav.
  destruct a; destruct v as [r| | | | | |]; simpl in Hv, Hav; contradiction.
Qed.
Lemma rsub_atom_not_anyref : forall a, ~ rsub (BAtom a) BAnyRef.
Proof.
  intros a H. apply rsub_sound in H.
  destruct (atom_has_member a) as [v Hv]. pose proof (H v Hv) as Hav.
  destruct a; destruct v as [r| | | | | |]; simpl in Hv, Hav; contradiction.
Qed.

(* an arrow is not [rsub]-below a record / atom / reference (structural via the
   arrow [_above] predicate, which is False at those targets). *)
Lemma rsub_arrow_not_rec : forall A B g, ~ rsub (BArrow A B) (BRec g).
Proof. intros A B g H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.
Lemma rsub_arrow_not_atom : forall A B a, ~ rsub (BArrow A B) (BAtom a).
Proof. intros A B a H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.
Lemma rsub_arrow_not_ref : forall A B S, ~ rsub (BArrow A B) (BRef S).
Proof. intros A B S H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.
Lemma rsub_arrow_not_anyref : forall A B, ~ rsub (BArrow A B) BAnyRef.
Proof. intros A B H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.

(* a record is not [rsub]-below an arrow / atom / reference. We reuse the [ssub]
   record [_above] by promoting through [rsub]: a [BRec] source relates only via
   [RsSsub] (ref rules need [BRef]/[BAnyRef] sources), so [rsub_sound] + the value
   model refutes the ref/atom cases, and the arrow case via the rec [_above]. *)

(* record/arrow not below a reference, structurally (rec_above / arrow_above are
   False at ref targets). For records we promote [ssub]'s [rec_above]. *)
Fixpoint rsub_rec_above (f : list (string * BTy)) (T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BRec g        => srec f g
  | BUnion Tl Tr  => rsub_rec_above f Tl \/ rsub_rec_above f Tr
  | BInter Tl Tr  => rsub_rec_above f Tl /\ rsub_rec_above f Tr
  | _             => False
  end.

Lemma rsub_rec_above_ssub_mono : forall M C, ssub M C ->
  forall f, rsub_rec_above f M -> rsub_rec_above f C.
Proof.
  intros M C H. induction H; intros f0 Hab; simpl in *;
    try exact I; try exact Hab; try contradiction.
  - apply IHssub2. apply IHssub1. exact Hab.
  - eapply srec_trans; [ exact Hab | eassumption ].
  - left. apply IHssub; exact Hab.
  - right. apply IHssub; exact Hab.
  - destruct Hab as [Ha|Hb]; [ apply IHssub1 | apply IHssub2 ]; assumption.
  - destruct Hab as [Ha _]. apply IHssub; exact Ha.
  - destruct Hab as [_ Hb]. apply IHssub; exact Hb.
  - split; [ apply IHssub1 | apply IHssub2 ]; exact Hab.
Qed.

Lemma rsub_rec_above_mono : forall M C, rsub M C ->
  forall f, rsub_rec_above f M -> rsub_rec_above f C.
Proof.
  intros M C H. induction H; intros f0 Hab; simpl in *.
  - eapply rsub_rec_above_ssub_mono; eassumption.
  - apply IHrsub2. apply IHrsub1. exact Hab.
  - contradiction.
  - contradiction.
Qed.

Lemma rsub_rec_super : forall f T, rsub (BRec f) T -> rsub_rec_above f T.
Proof.
  intros f T H. apply (rsub_rec_above_mono (BRec f) T H f). simpl. apply srec_refl.
Qed.

Lemma rsub_rec_not_atom : forall f a, ~ rsub (BRec f) (BAtom a).
Proof. intros f a H. apply rsub_rec_super in H. simpl in H. exact H. Qed.
Lemma rsub_rec_not_arrow : forall f A B, ~ rsub (BRec f) (BArrow A B).
Proof. intros f A B H. apply rsub_rec_super in H. simpl in H. exact H. Qed.
Lemma rsub_rec_not_ref : forall f S, ~ rsub (BRec f) (BRef S).
Proof. intros f S H. apply rsub_rec_super in H. simpl in H. exact H. Qed.
Lemma rsub_rec_not_anyref : forall f, ~ rsub (BRec f) BAnyRef.
Proof. intros f H. apply rsub_rec_super in H. simpl in H. exact H. Qed.

(* the [rsub] record inversion (demanded field supplied), via [rsub_rec_super]. *)
Lemma rsub_rec_inv : forall f g k Tg,
  rsub (BRec f) (BRec g) -> In (k, Tg) g ->
  exists Tf, In (k, Tf) f /\ ssub Tf Tg.
Proof.
  intros f g k Tg H Hin. apply rsub_rec_super in H. simpl in H.
  eapply srec_lookup; eassumption.
Qed.

(* a reference SOURCE is not [rsub]-below an atom / arrow / record (read off the
   [rsub_ref_above] predicate, False at those targets); a [BRef] is below another
   [BRef] only invariantly, below [BAnyRef], [BTop], or unions/inters of such. *)
Lemma rsub_ref_not_atom : forall S a, ~ rsub (BRef S) (BAtom a).
Proof. intros S a H. apply rsub_ref_super in H. simpl in H. exact H. Qed.
Lemma rsub_ref_not_arrow : forall S A B, ~ rsub (BRef S) (BArrow A B).
Proof. intros S A B H. apply rsub_ref_super in H. simpl in H. exact H. Qed.
Lemma rsub_ref_not_rec : forall S g, ~ rsub (BRef S) (BRec g).
Proof. intros S g H. apply rsub_ref_super in H. simpl in H. exact H. Qed.

(* an any-ref SOURCE is not below an atom/arrow/record either. *)
Lemma rsub_anyref_not_atom : forall a, ~ rsub BAnyRef (BAtom a).
Proof. intros a H. apply rsub_anyref_super in H. simpl in H. exact H. Qed.
Lemma rsub_anyref_not_arrow : forall A B, ~ rsub BAnyRef (BArrow A B).
Proof. intros A B H. apply rsub_anyref_super in H. simpl in H. exact H. Qed.
Lemma rsub_anyref_not_rec : forall g, ~ rsub BAnyRef (BRec g).
Proof. intros g H. apply rsub_anyref_super in H. simpl in H. exact H. Qed.

(* ===========================================================================
   7. CANONICAL FORMS.
   A closed value of arrow type is a lambda; of record type is a record.
   Immediate from the inversion lemmas + the not-arrow shape facts.
   =========================================================================== *)

Lemma canon_arrow : forall S e A B,
  has_type S [] e (BArrow A B) -> value e -> exists T body, e = tlam T body.
Proof.
  intros S e A B Hty Hv. destruct Hv as [l | T b | fs Hfs | n].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_arrow; eauto.
  - exists T, b; reflexivity.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply rsub_rec_not_arrow; eauto.
  - (* tloc: a location is not [rsub]-below an arrow *)
    apply inv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_arrow; eauto.
Qed.

Lemma canon_rec : forall S e fields,
  has_type S [] e (BRec fields) -> value e -> exists fs, e = trec fs.
Proof.
  intros S e fields Hty Hv. destruct Hv as [l | T b | fs Hfs | n].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_rec; eauto.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_rec; eauto.
  - exists fs; reflexivity.
  - apply inv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_rec; eauto.
Qed.

(* SPLIT-STEP 3 — canonical form for references: a closed value of [BRef T] is a
   location. (Ported from imp.v's [rcanon_ref].) *)
Lemma canon_ref : forall S e T,
  has_type S [] e (BRef T) -> value e -> exists n, e = tloc n.
Proof.
  intros S e T Hty Hv. destruct Hv as [l | Tl b | fs Hfs | n].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_ref; eauto.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_ref; eauto.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply rsub_rec_not_ref; eauto.
  - exists n; reflexivity.
Qed.

(* INCREMENT 19 — canonical forms for NUMBER: a closed value of type [BAtom ANum]
   is an integer-valued number literal [tlit (LInt n)] (the only number literal in
   the term language; the 5.1 number model has one number value per double).
   Non-number literals are excluded SEMANTICALLY (their atom has a member outside
   [ANum]); lambdas/records/locations by the arrow/record/ref-not-atom shape facts.
   This is the progress crux for [tprim]: a well-typed primop's operands, when
   values, are number literals, so the operator computes. *)
Lemma canon_num : forall S e,
  has_type S [] e (BAtom ANum) -> value e -> exists n, e = tlit (LInt n).
Proof.
  intros S e Hty Hv. destruct Hv as [l | T b | fs Hfs | n].
  - apply inv_lit in Hty. destruct l; simpl in Hty.
    + exists n; reflexivity.
    + exfalso. apply rsub_sound in Hty. pose proof (Hty (VStr 0) I) as Hbad. exact Hbad.
    + exfalso. apply rsub_sound in Hty. pose proof (Hty (VBool b) I) as Hbad. exact Hbad.
    + exfalso. apply rsub_sound in Hty. pose proof (Hty VNil I) as Hbad. exact Hbad.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_atom; eauto.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply rsub_rec_not_atom; eauto.
  - apply inv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_atom; eauto.
Qed.

(* INCREMENT 11 — canonical forms for Bool: a closed value of type [BAtom ABool]
   is a boolean literal. Needed for [progress]'s [tif] case (the condition is a
   value of Bool type, hence a [LBool]). Non-bool literals are excluded
   SEMANTICALLY (their atom has a member outside [ABool]); lambdas/records are
   excluded by the arrow/record-not-atom shape facts. *)
Lemma canon_bool : forall S e,
  has_type S [] e (BAtom ABool) -> value e -> exists b, e = tlit (LBool b).
Proof.
  intros S e Hty Hv. destruct Hv as [l | T b | fs Hfs | n].
  - apply inv_lit in Hty. destruct l; simpl in Hty.
    + exfalso. apply rsub_sound in Hty. pose proof (Hty (VInt 0) I) as Hbad. exact Hbad.
    + exfalso. apply rsub_sound in Hty. pose proof (Hty (VStr 0) I) as Hbad. exact Hbad.
    + exists b; reflexivity.
    + exfalso. apply rsub_sound in Hty. pose proof (Hty VNil I) as Hbad. exact Hbad.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_atom; eauto.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply rsub_rec_not_atom; eauto.
  - (* tloc: a location is not [rsub]-below an atom *)
    apply inv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_atom; eauto.
Qed.

(* ===========================================================================
   INCREMENT 13 — THE TRUTHY/FALSY VALUE-NARROWING BRIDGING LEMMAS.

   The operational justification of flow narrowing: a value's TRUTHINESS, an
   operational fact, gives it the narrowed TYPE. These are the lemmas preservation
   uses to retype the selected branch after the value-conditioned step substitutes
   the scrutinee in.

     truthy_narrows : value v -> truthy_value v -> has_type [] v truthy_type
     falsy_narrows  : value v -> falsy_value v  -> has_type [] v falsy_type

   PROOF SHAPE (no negation, no dsub-in-typing — the load-bearing soundness move):
   case on the value's CANONICAL FORM. Each non-nil value class (number/string/
   true/lambda/record) subsumes into [truthy_type] by a UNION INTRODUCTION [ssub]
   ([SsUnionInL]/[SsUnionInR] + the atom/arrow/record membership), which [ssub]
   HAS. So the truthiness→narrowed-type step goes entirely through the existing
   sound [ssub] union rules. A falsy value is [nil] or [false], each an atom
   below [falsy_type = nil ∪ bool] by union introduction. *)

Lemma truthy_narrows : forall S v U,
  has_type S [] v U -> value v -> truthy_value v -> has_type S [] v truthy_type.
Proof.
  intros S v U Hty Hv Ht. unfold truthy_type.
  destruct Hv as [l | T b | fs Hfs | n].
  - (* literal: truthy ⇒ LInt / LStr / LBool true *)
    destruct l as [n | n | [|] | ].
    + (* LInt : AInt ≤ ANum ≤ truthy_type *)
      eapply TSub; [ apply (TLit S [] (LInt n)) | ]. apply RsSsub. simpl.
      apply SsUnionInR. apply SsUnionInL. apply SsAtom. apply ALInt.
    + (* LStr : AStr ≤ truthy_type *)
      eapply TSub; [ apply (TLit S [] (LStr n)) | ]. apply RsSsub. simpl.
      apply SsUnionInR. apply SsUnionInR. apply SsUnionInL. apply SsRefl.
    + (* LBool true : ABool ≤ truthy_type (left disjunct) *)
      eapply TSub; [ apply (TLit S [] (LBool true)) | ]. apply RsSsub. simpl.
      apply SsUnionInL. apply SsRefl.
    + (* LBool false : FALSY — excluded *)
      exfalso. apply Ht. left. reflexivity.
    + (* LNil : FALSY — excluded *)
      exfalso. apply Ht. right. reflexivity.
  - (* lambda: subsume its arrow to [BArrow BBot BTop], inject into the union. *)
    apply inv_lam in Hty. destruct Hty as [Tb [Hb _]].
    eapply TSub; [ apply TLam; exact Hb | ]. apply RsSsub.
    apply SsUnionInR. apply SsUnionInR. apply SsUnionInR. apply SsUnionInR.
    apply SsUnionInL. apply SsArrow; [ apply SsBot | apply SsTop ].
  - (* record: subsume [BRec Ts] to [BRec []], inject into the union. *)
    apply inv_rec in Hty. destruct Hty as [Ts [Hf [Hnd _]]].
    eapply TSub; [ apply TRec; [ exact Hf | exact Hnd ] | ]. apply RsSsub.
    apply SsUnionInR. apply SsUnionInR. apply SsUnionInR. apply SsUnionInL.
    apply SsRec. apply SrNil.
  - (* SPLIT-STEP 3 — tloc: a TRUTHY LOCATION narrows to [BAnyRef] (the rightmost
       union arm). Its real type is [BRef U] (by [inv_loc]); [rsub (BRef U) BAnyRef]
       (the any-ref rule), then inject [BAnyRef] into [truthy_type]. THE reason
       [BAnyRef] exists. *)
    apply inv_loc in Hty. destruct Hty as [U0 [Hl _]].
    eapply TSub; [ apply (TLoc S [] n U0 Hl) | ].
    eapply RsTrans; [ apply RsAnyRef | ]. apply RsSsub.
    apply SsUnionInR. apply SsUnionInR. apply SsUnionInR. apply SsUnionInR.
    apply SsUnionInR. apply SsRefl.
Qed.

Lemma falsy_narrows : forall S v,
  value v -> falsy_value v -> has_type S [] v falsy_type.
Proof.
  intros S v Hv Hf. unfold falsy_type. destruct Hf as [Ef | En]; subst v.
  - (* false : ABool ≤ nil ∪ bool (right disjunct) *)
    eapply TSub; [ apply (TLit S [] (LBool false)) | ]. apply RsSsub. simpl.
    apply SsUnionInR. apply SsRefl.
  - (* nil : ANil ≤ nil ∪ bool (left disjunct) *)
    eapply TSub; [ apply (TLit S [] LNil) | ]. apply RsSsub. simpl.
    apply SsUnionInL. apply SsRefl.
Qed.

(* ===========================================================================
   INCREMENT 15 — THE TYPE-TAG VALUE-NARROWING BRIDGING LEMMA (the crux, mirroring
   [truthy_narrows]).

   The operational justification of type-test flow narrowing: a value whose
   RUNTIME TAG is [g] genuinely has the narrowed TYPE [tag_type g]. This is the
   lemma preservation uses to retype the then-branch after the value-conditioned
   step substitutes the scrutinee in.

     tag_narrows : has_type [] v U -> value v -> has_tag v g
                     -> has_type [] v (tag_type g)

   PROOF SHAPE (canonical forms; no negation, no dsub-in-typing — the load-bearing
   soundness move): case on the value's canonical form, then on the tag. Each
   value class inhabits its tag's type directly — a number literal at [ANum] (via
   [AInt ≤ ANum]), a string at [AStr], etc.; a lambda at [BArrow BBot BTop] (its
   real arrow subsumes by [BBot ≤ dom] contra, [cod ≤ BTop] co); a record at
   [BRec []] (every table; [srec Ts [] = SrNil]). Mismatched (value-class, tag)
   pairs are excluded by [has_tag] being [False] there. *)
Lemma tag_narrows : forall S v U g,
  has_type S [] v U -> value v -> has_tag v g -> has_type S [] v (tag_type g).
Proof.
  intros S v U g Hty Hv Hg. destruct Hv as [l | T b | fs Hfs | n].
  - (* literal: the tag is forced by the literal kind *)
    destruct l as [n | n | bb | ]; destruct g; simpl in Hg; try contradiction;
      simpl tag_type.
    + (* LInt, TgNum : AInt ≤ ANum *)
      eapply TSub; [ apply (TLit S [] (LInt n)) | ]. apply RsSsub. apply SsAtom. apply ALInt.
    + (* LStr, TgStr *) apply (TLit S [] (LStr n)).
    + (* LBool, TgBool *) apply (TLit S [] (LBool bb)).
    + (* LNil, TgNil *) apply (TLit S [] LNil).
  - (* lambda: the only matching tag is TgFun *)
    destruct g; simpl in Hg; try contradiction. simpl tag_type.
    apply inv_lam in Hty. destruct Hty as [Tb [Hb _]].
    eapply TSub; [ apply TLam; exact Hb | ]. apply RsSsub.
    apply SsArrow; [ apply SsBot | apply SsTop ].
  - (* record: the only matching tag is TgTable *)
    destruct g; simpl in Hg; try contradiction. simpl tag_type.
    apply inv_rec in Hty. destruct Hty as [Ts [Hf [Hnd _]]].
    eapply TSub; [ apply TRec; [ exact Hf | exact Hnd ] | ]. apply RsSsub.
    apply SsRec. apply SrNil.
  - (* SPLIT-STEP 3 — tloc: the only matching tag is TgRef; [tag_type TgRef =
       BAnyRef]. A location's real type is [BRef U0]; [rsub (BRef U0) BAnyRef]. *)
    destruct g; simpl in Hg; try contradiction. simpl tag_type.
    apply inv_loc in Hty. destruct Hty as [U0 [Hl _]].
    eapply TSub; [ apply (TLoc S [] n U0 Hl) | ]. apply RsAnyRef.
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
Lemma weakening : forall Sg G e T,
  has_type Sg G e T ->
  forall G1 G2 U, G = G1 ++ G2 ->
    has_type Sg (G1 ++ U :: G2) (lift 1 (Datatypes.length G1) e) T.
Proof.
  intros Sg G e T H.
  induction H using has_type_mind with
    (P0 := fun Sg G fs Ts (_ : has_fields Sg G fs Ts) =>
       forall G1 G2 U, G = G1 ++ G2 ->
         has_fields Sg (G1 ++ U :: G2)
           (map (fun ke => (fst ke, lift 1 (Datatypes.length G1) (snd ke))) fs) Ts);
    intros; subst; simpl.
  - apply TLit.
  - (* TVar *)
    destruct (Nat.ltb_spec n (Datatypes.length G1)) as [Hlt | Hge].
    + apply TVar. rewrite nth_error_insert_lo by assumption. exact e.
    + replace (n + 1) with (Datatypes.S n) by lia. apply TVar.
      rewrite nth_error_insert_hi by assumption. exact e.
  - (* TPrimArith *) apply TPrimArith;
      [ assumption | apply (IHhas_type1 G1 G2 U eq_refl) | apply (IHhas_type2 G1 G2 U eq_refl) ].
  - (* TPrimCmp *) apply TPrimCmp;
      [ assumption | apply (IHhas_type1 G1 G2 U eq_refl) | apply (IHhas_type2 G1 G2 U eq_refl) ].
  (* IH applicator: pick SOME quantified IH from the context, instantiated at
     cut [G1] or an extension; [exact] failure backtracks to the next match. *)
  - (* TLam *) apply TLam.
    match goal with [ IH : forall _ _ _, T :: ?g = _ -> _ |- _ ] =>
      exact (IH (T :: G1) G2 U eq_refl) end.
  - (* TApp *) eapply TApp;
      match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
  - (* TLet *) eapply TLet.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
    + match goal with [ IH : forall _ _ _, A :: _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH (A :: G1) G2 U eq_refl) end.
  - (* TRec *) apply TRec.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
    + rewrite map_map. simpl.
      match goal with [ Hnd : NoDup (map fst fs) |- _ ] => exact Hnd end.
  - (* TProj *) eapply TProj;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption ].
  - (* TSub *) eapply TSub;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption ].
  - (* TIf *) eapply TIf;
      match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
  - (* TIfn: scrutinee IH at cut G1; branch IHs under their fresh binder, cut
       (truthy_type::G1) / (falsy_type::G1). *)
    eapply TIfn.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U0 eq_refl) end.
    + match goal with [ IH : forall _ _ _, truthy_type :: _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH (truthy_type :: G1) G2 U0 eq_refl) end.
    + match goal with [ IH : forall _ _ _, falsy_type :: _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH (falsy_type :: G1) G2 U0 eq_refl) end.
  - (* TFix: the body is under the recursive self-ref binder [T], so its cut is
       [T::G1]. *)
    apply TFix.
    match goal with [ IH : forall _ _ _, T :: ?g = _ -> _ |- _ ] =>
      exact (IH (T :: G1) G2 U eq_refl) end.
  - (* TTypeTest: scrutinee IH at cut G1; then-branch under fresh binder cut
       (tag_type g :: G1); else-branch under fresh binder cut (U0 :: G1). *)
    eapply TTypeTest.
    + match goal with [ IH : forall _ _ _, G1 ++ G2 = _ -> has_type _ _ _ U |- _ ] =>
        exact (IH G1 G2 U0 eq_refl) end.
    + match goal with [ IH : forall _ _ _, tag_type g :: _ = _ -> has_type _ _ _ T1 |- _ ] =>
        exact (IH (tag_type g :: G1) G2 U0 eq_refl) end.
    + match goal with [ IH : forall _ _ _, U :: _ = _ -> has_type _ _ _ T2 |- _ ] =>
        exact (IH (U :: G1) G2 U0 eq_refl) end.
  - (* TLoc: closed, store lookup unchanged by var-context weakening *) apply TLoc. exact e.
  - (* TAlloc *) apply TAlloc.
    match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
      exact (IH G1 G2 U eq_refl) end.
  - (* TDeref *) eapply TDeref.
    match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
      exact (IH G1 G2 U eq_refl) end.
  - (* TAssign *) eapply TAssign;
      match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
  - (* HFnil *) apply HFnil.
  - (* HFcons *) apply HFcons.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
Qed.

(* weakening at the FRONT (the form preservation needs for the lambda body):
   add one binder on top. *)
Corollary weakening_cons : forall Sg G e T U,
  has_type Sg G e T -> has_type Sg (U :: G) (lift 1 0 e) T.
Proof.
  intros Sg G e T U H. apply (weakening Sg G e T H [] G U). reflexivity.
Qed.

(* [closed_at k e]: every free variable of [e] is < k. Defined structurally
   (records via a nested fixpoint), used to bound free vars by the context size. *)
Fixpoint closed_at (k : nat) (e : tm) : Prop :=
  match e with
  | tlit _    => True
  | tvar n    => n < k
  | tprim _ a b => closed_at k a /\ closed_at k b
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
  (* tifn binds the scrutinee fresh in each branch: branches closed at [S k]. *)
  | tifn c e1 e2 => closed_at k c /\ closed_at (S k) e1 /\ closed_at (S k) e2
  (* tfix binds the self-reference fresh: body closed at [S k]. *)
  | tfix _ b  => closed_at (S k) b
  (* ttypetest binds the scrutinee fresh in each branch: branches closed at [S k]. *)
  | ttypetest _ c e1 e2 => closed_at k c /\ closed_at (S k) e1 /\ closed_at (S k) e2
  (* SPLIT-STEP 3 — reference ops recurse at [k]; a location is closed. *)
  | talloc e  => closed_at k e
  | tderef e  => closed_at k e
  | tassign r e => closed_at k r /\ closed_at k e
  | tloc _    => True
  end.

(* typing in [G] bounds free vars by [length G]. By term induction + inversion.
   [S] (store typing) is universally available and threaded through inversion. *)
Lemma has_type_closed : forall e Sg G T, has_type Sg G e T -> closed_at (Datatypes.length G) e.
Proof.
  intro e. induction e using tm_rect_strong with
    (Pl := fun fs => forall Sg G Ts, has_fields Sg G fs Ts ->
       (fix allc (fs : list (string * tm)) : Prop :=
          match fs with [] => True | (_, e) :: rest => closed_at (Datatypes.length G) e /\ allc rest end) fs);
    intros; simpl.
  - exact I.
  - (* tvar *) apply inv_var in H. destruct H as [U [Hl _]].
    apply nth_error_Some. rewrite Hl. discriminate.
  - (* tprim *) apply inv_prim in H. destruct H as [Ha [Hb _]].
    split; [ exact (IHe1 Sg G (BAtom ANum) Ha) | exact (IHe2 Sg G (BAtom ANum) Hb) ].
  - (* tlam *) apply inv_lam in H. destruct H as [Tb [Hb _]].
    exact (IHe Sg (T :: G) Tb Hb).
  - (* tapp *) apply inv_app in H. destruct H as [A [B [Hf [Ha _]]]].
    split; [ exact (IHe1 Sg G (BArrow A B) Hf) | exact (IHe2 Sg G A Ha) ].
  - (* tlet *) apply inv_let in H. destruct H as [A [B [H1 [H2 _]]]].
    split; [ exact (IHe1 Sg G A H1) | exact (IHe2 Sg (A :: G) B H2) ].
  - (* trec *) apply inv_rec in H. destruct H as [Ts [Hf [_ _]]].
    exact (IHe Sg G Ts Hf).
  - (* tproj *) apply inv_proj in H. destruct H as [fields [U [He _]]].
    exact (IHe Sg G (BRec fields) He).
  - (* tif *) apply inv_if in H. destruct H as [U1 [U2 [Hc [H1 [H2 _]]]]].
    split; [ exact (IHe1 Sg G (BAtom ABool) Hc)
           | split; [ exact (IHe2 Sg G U1 H1) | exact (IHe3 Sg G U2 H2) ] ].
  - (* tifn *) apply inv_ifn in H. destruct H as [U [T1 [T2 [Hc [H1 [H2 _]]]]]].
    split; [ exact (IHe1 Sg G U Hc)
           | split; [ exact (IHe2 Sg (truthy_type :: G) T1 H1)
                    | exact (IHe3 Sg (falsy_type :: G) T2 H2) ] ].
  - (* tfix *) apply inv_fix in H. destruct H as [Hb _].
    exact (IHe Sg (T :: G) T Hb).
  - (* ttypetest *) apply inv_typetest in H. destruct H as [U [T1 [T2 [Hc [H1 [H2 _]]]]]].
    split; [ exact (IHe1 Sg G U Hc)
           | split; [ exact (IHe2 Sg (tag_type g :: G) T1 H1)
                    | exact (IHe3 Sg (U :: G) T2 H2) ] ].
  - (* talloc *) apply inv_alloc in H. destruct H as [U [He _]]. exact (IHe Sg G U He).
  - (* tderef *) apply inv_deref in H. destruct H as [U [He _]]. exact (IHe Sg G (BRef U) He).
  - (* tassign *) apply inv_assign in H. destruct H as [U [Hr [He _]]].
    split; [ exact (IHe1 Sg G (BRef U) Hr) | exact (IHe2 Sg G U He) ].
  - (* tloc *) exact I.
  - (* Pl nil *) exact I.
  - (* Pl cons *) inversion H; subst. simpl. split.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_:BTy), has_type _ _ ?x _ -> _,
          Hh : has_type ?Sg0 ?G0 ?x ?Tx |- _ ] => exact (IH Sg0 G0 Tx Hh) end.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_: list (string*BTy)), has_fields _ _ ?xs _ -> _,
          Hh : has_fields ?Sg0 ?G0 ?xs ?Tsx |- _ ] => exact (IH Sg0 G0 Tsx Hh) end.
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
  - (* tprim *) destruct H as [H1 H2]. f_equal;
      [ apply (IHe1 k); [exact H1 | exact H0] | apply (IHe2 k); [exact H2 | exact H0] ].
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
  - (* tifn: scrutinee at k; branches at S k (lift cut also rises by one). *)
    destruct H as [Hc [H1 H2]]. f_equal;
      [ apply (IHe1 k); [exact Hc | exact H0]
      | apply (IHe2 (S k)); [exact H1 | lia]
      | apply (IHe3 (S k)); [exact H2 | lia] ].
  - (* tfix: body at S k (lift cut also rises by one). *)
    f_equal. apply (IHe (S k)); [exact H | lia].
  - (* ttypetest: scrutinee at k; branches at S k (lift cut also rises by one). *)
    destruct H as [Hc [H1 H2]]. f_equal;
      [ apply (IHe1 k); [exact Hc | exact H0]
      | apply (IHe2 (S k)); [exact H1 | lia]
      | apply (IHe3 (S k)); [exact H2 | lia] ].
  - (* talloc *) f_equal. apply (IHe k); [exact H | exact H0].
  - (* tderef *) f_equal. apply (IHe k); [exact H | exact H0].
  - (* tassign *) destruct H as [H1 H2]. f_equal;
      [ apply (IHe1 k); [exact H1 | exact H0] | apply (IHe2 k); [exact H2 | exact H0] ].
  - (* tloc *) reflexivity.
  - (* Pl nil *) reflexivity.
  - (* Pl cons *) destruct H as [Hc Hr]. f_equal;
      [ f_equal; apply (IHe k0); [exact Hc | exact H0]
      | apply (IHe0 k0); [exact Hr | exact H0] ].
Qed.

(* the corollary we use: a CLOSED term is lift-invariant. [S]/[T] implicit so the
   many call sites [closed_lift s H 1 0] are unchanged in shape. *)
Lemma closed_lift : forall e {S T}, has_type S [] e T -> forall d k, lift d k e = e.
Proof.
  intros e S T H d k.
  apply (closed_at_lift e 0 (has_type_closed e S [] T H) d k). lia.
Qed.

(* a closed term types in ANY context (repeated front-weakening, lift-invariant). *)
Lemma has_type_closed_any : forall e S U, has_type S [] e U -> forall G, has_type S G e U.
Proof.
  intros e S U H G. induction G as [ | A G IH ].
  - exact H.
  - pose proof (weakening_cons S G e U A IH) as Hw.
    rewrite (closed_lift e H 1 0) in Hw. exact Hw.
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
Lemma subst_lemma : forall e Sg G1 G2 U T s,
  has_type Sg (G1 ++ U :: G2) e T ->
  has_type Sg [] s U ->
  has_type Sg (G1 ++ G2) (subst (Datatypes.length G1) s e) T.
Proof.
  intro e. induction e using tm_rect_strong with
    (Pl := fun fs => forall Sg G1 G2 U Ts s,
       has_fields Sg (G1 ++ U :: G2) fs Ts ->
       has_type Sg [] s U ->
       has_fields Sg (G1 ++ G2)
         (map (fun ke => (fst ke, subst (Datatypes.length G1) s (snd ke))) fs) Ts);
    intros.
  - (* tlit *) apply inv_lit in H. simpl.
    eapply TSub; [ apply TLit | exact H ].
  - (* tvar *) apply inv_var in H. destruct H as [W [Hl Hs]]. simpl.
    destruct (Nat.compare_spec n (Datatypes.length G1)) as [Heq | Hlt | Hgt].
    + (* n = cut: result is s, typed U then subsumed to T *)
      subst n. rewrite nth_error_mid in Hl. injection Hl as <-.
      eapply TSub; [ apply (has_type_closed_any s Sg U H0) | exact Hs ].
    + (* n < cut *)
      eapply TSub; [ apply TVar | exact Hs ].
      rewrite nth_error_insert_lo in Hl by assumption. exact Hl.
    + (* n > cut *)
      eapply TSub; [ apply TVar | exact Hs ].
      destruct n as [ | n' ]; [ lia | ]. simpl Nat.pred.
      rewrite (nth_error_insert_hi G1 G2 U n') in Hl by lia. exact Hl.
  - (* tprim *) apply inv_prim in H. destruct H as [Ha [Hb Hres]]. simpl.
    pose proof (IHe1 Sg G1 G2 U (BAtom ANum) s Ha H0) as Ha'.
    pose proof (IHe2 Sg G1 G2 U (BAtom ANum) s Hb H0) as Hb'.
    destruct Hres as [[Har Hd] | [Hcr Hd]].
    + eapply TSub; [ apply TPrimArith; [ exact Har | exact Ha' | exact Hb' ] | exact Hd ].
    + eapply TSub; [ apply TPrimCmp; [ exact Hcr | exact Ha' | exact Hb' ] | exact Hd ].
  - (* tlam *) apply inv_lam in H. destruct H as [Tb [Hb Hsub]]. simpl.
    eapply TSub; [ apply TLam | exact Hsub ].
    rewrite (closed_lift s H0 1 0).
    apply (IHe Sg (T :: G1) G2 U Tb s); [ exact Hb | exact H0 ].
  - (* tapp *) apply inv_app in H. destruct H as [A [B [Hf [Ha Hsub]]]]. simpl.
    eapply TSub; [ eapply TApp | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U (BArrow A B) s); [ exact Hf | exact H0 ].
    + apply (IHe2 Sg G1 G2 U A s); [ exact Ha | exact H0 ].
  - (* tlet *) apply inv_let in H. destruct H as [A [B [H1 [H2 Hsub]]]]. simpl.
    eapply TSub; [ eapply TLet | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U A s); [ exact H1 | exact H0 ].
    + rewrite (closed_lift s H0 1 0).
      apply (IHe2 Sg (A :: G1) G2 U B s); [ exact H2 | exact H0 ].
  - (* trec *) apply inv_rec in H. destruct H as [Ts [Hf [Hnd Hsub]]]. simpl.
    eapply TSub; [ apply TRec | exact Hsub ].
    + apply (IHe Sg G1 G2 U Ts s); [ exact Hf | exact H0 ].
    + rewrite map_map. simpl. exact Hnd.
  - (* tproj *) apply inv_proj in H. destruct H as [fields [W [He [Hin Hsub]]]]. simpl.
    eapply TSub; [ eapply TProj | exact Hsub ].
    + apply (IHe Sg G1 G2 U (BRec fields) s); [ exact He | exact H0 ].
    + exact Hin.
  - (* tif *) apply inv_if in H. destruct H as [U1 [U2 [Hc [H1 [H2 Hsub]]]]]. simpl.
    eapply TSub; [ eapply TIf | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U (BAtom ABool) s); [ exact Hc | exact H0 ].
    + apply (IHe2 Sg G1 G2 U U1 s); [ exact H1 | exact H0 ].
    + apply (IHe3 Sg G1 G2 U U2 s); [ exact H2 | exact H0 ].
  - (* tifn *)
    apply inv_ifn in H. destruct H as [Uc [T1 [T2 [Hc [H1 [H2 Hsub]]]]]]. simpl.
    rewrite (closed_lift s H0 1 0).
    eapply TSub; [ eapply TIfn | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U Uc s); [ exact Hc | exact H0 ].
    + apply (IHe2 Sg (truthy_type :: G1) G2 U T1 s); [ exact H1 | exact H0 ].
    + apply (IHe3 Sg (falsy_type :: G1) G2 U T2 s); [ exact H2 | exact H0 ].
  - (* tfix *)
    apply inv_fix in H. destruct H as [Hb Hsub]. simpl.
    rewrite (closed_lift s H0 1 0).
    eapply TSub; [ apply TFix | exact Hsub ].
    apply (IHe Sg (T :: G1) G2 U T s); [ exact Hb | exact H0 ].
  - (* ttypetest *)
    apply inv_typetest in H. destruct H as [Uc [T1 [T2 [Hc [H1 [H2 Hsub]]]]]]. simpl.
    rewrite (closed_lift s H0 1 0).
    eapply TSub; [ eapply TTypeTest | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U Uc s); [ exact Hc | exact H0 ].
    + apply (IHe2 Sg (tag_type g :: G1) G2 U T1 s); [ exact H1 | exact H0 ].
    + apply (IHe3 Sg (Uc :: G1) G2 U T2 s); [ exact H2 | exact H0 ].
  - (* SPLIT-STEP 3 — talloc *)
    apply inv_alloc in H. destruct H as [W [He Hsub]]. simpl.
    eapply TSub; [ apply TAlloc | exact Hsub ].
    apply (IHe Sg G1 G2 U W s); [ exact He | exact H0 ].
  - (* tderef *)
    apply inv_deref in H. destruct H as [W [He Hsub]]. simpl.
    eapply TSub; [ eapply TDeref | exact Hsub ].
    apply (IHe Sg G1 G2 U (BRef W) s); [ exact He | exact H0 ].
  - (* tassign *)
    apply inv_assign in H. destruct H as [W [Hr [He Hsub]]]. simpl.
    eapply TSub; [ eapply TAssign | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U (BRef W) s); [ exact Hr | exact H0 ].
    + apply (IHe2 Sg G1 G2 U W s); [ exact He | exact H0 ].
  - (* tloc: closed location, substitution is the identity; store lookup unchanged. *)
    apply inv_loc in H. destruct H as [W [Hl Hsub]]. simpl.
    eapply TSub; [ apply TLoc; exact Hl | exact Hsub ].
  - (* Pl nil *) inversion H; subst. simpl. apply HFnil.
  - (* Pl cons *) inversion H; subst. simpl. apply HFcons.
    + match goal with [ Hh : has_type ?Sg0 (G1 ++ U :: G2) e ?Tk |- _ ] =>
        apply (IHe Sg0 G1 G2 U Tk s); [ exact Hh | exact H0 ] end.
    + match goal with [ Hh : has_fields ?Sg0 (G1 ++ U :: G2) rest ?Tsk |- _ ] =>
        apply (IHe0 Sg0 G1 G2 U Tsk s); [ exact Hh | exact H0 ] end.
Qed.

(* the form preservation uses: substitute a closed value at the top binder. *)
Corollary subst_top : forall S U G e T s,
  has_type S (U :: G) e T -> has_type S [] s U -> has_type S G (subst 0 s e) T.
Proof.
  intros S U G e T s He Hs.
  apply (subst_lemma e S [] G U T s); [ exact He | exact Hs ].
Qed.

(* ===========================================================================
   SPLIT-STEP 3 — STORE-WEAKENING + STORE LEMMAS (ported from imp.v).
   =========================================================================== *)

(* STORE-WEAKENING: typing is stable under store-typing EXTENSION (new cells never
   invalidate earlier location lookups; [extends_nth_error] does the [TLoc] work).
   By mutual induction on the typing derivation. *)
Lemma store_weakening : forall S G e T,
  has_type S G e T -> forall S', extends S' S -> has_type S' G e T.
Proof.
  intros S G e T H.
  induction H using has_type_mind with
    (P0 := fun S G fs Ts (_ : has_fields S G fs Ts) =>
       forall S', extends S' S -> has_fields S' G fs Ts);
    intros S' Hext.
  - apply TLit.
  - apply TVar; eassumption.
  - apply TPrimArith; [ assumption | apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext ].
  - apply TPrimCmp; [ assumption | apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext ].
  - apply TLam; apply IHhas_type; exact Hext.
  - eapply TApp; [ apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext ].
  - eapply TLet; [ apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext ].
  - eapply TRec; [ apply IHhas_type; exact Hext | eassumption ].
  - eapply TProj; [ apply IHhas_type; exact Hext | eassumption ].
  - eapply TSub; [ apply IHhas_type; exact Hext | eassumption ].
  - eapply TIf; [ apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext | apply IHhas_type3; exact Hext ].
  - eapply TIfn; [ apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext | apply IHhas_type3; exact Hext ].
  - apply TFix; apply IHhas_type; exact Hext.
  - eapply TTypeTest; [ apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext | apply IHhas_type3; exact Hext ].
  - apply TLoc. eapply extends_nth_error; eassumption.
  - apply TAlloc; apply IHhas_type; exact Hext.
  - eapply TDeref; apply IHhas_type; exact Hext.
  - eapply TAssign; [ apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext ].
  - apply HFnil.
  - apply HFcons; [ apply IHhas_type; exact Hext | apply IHhas_type0; exact Hext ].
Qed.

(* has_fields store-weakening — the field-list analogue, via [store_weakening]
   applied pointwise (proved directly by induction on the field derivation). *)
Lemma has_fields_store_weaken : forall S G fs Ts,
  has_fields S G fs Ts -> forall S', extends S' S -> has_fields S' G fs Ts.
Proof.
  intros S G fs Ts H. induction H; intros S' Hext.
  - apply HFnil.
  - apply HFcons; [ eapply store_weakening; [ exact H | exact Hext ] | apply IHhas_fields; exact Hext ].
Qed.

(* store_lookup past the end of an appended store: the appended cell. *)
Lemma store_lookup_app_last : forall st v,
  store_lookup (List.length st) (app st [v]) = v.
Proof.
  intros st v. unfold store_lookup. rewrite app_nth2 by lia.
  replace (List.length st - List.length st) with 0 by lia. reflexivity.
Qed.

Lemma store_lookup_app_lo : forall n st v,
  n < List.length st -> store_lookup n (app st [v]) = store_lookup n st.
Proof.
  intros n st v Hlt. unfold store_lookup. rewrite app_nth1 by assumption. reflexivity.
Qed.

Lemma store_update_length : forall n v st,
  List.length (store_update n v st) = List.length st.
Proof.
  intros n v st. revert n. induction st as [ | x rest IH ]; intros [ | n' ]; simpl; auto.
Qed.

Lemma store_lookup_update_eq : forall n v st,
  n < List.length st -> store_lookup n (store_update n v st) = v.
Proof.
  intros n v st. revert n. induction st as [ | x rest IH ]; intros [ | n' ] Hlt; simpl in *.
  - lia.
  - lia.
  - reflexivity.
  - unfold store_lookup. simpl. apply (IH n'). lia.
Qed.

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
   PROJECTION SUPPORT — with NoDup keys, [field_lookup] (first match) returns a
   value whose type is exactly the (unique) type assigned to that key.
   =========================================================================== *)

(* has_fields aligns keys: [map fst fs = map fst Ts]. *)
Lemma has_fields_keys : forall S G fs Ts, has_fields S G fs Ts -> map fst fs = map fst Ts.
Proof.
  intros S G fs Ts H. induction H; simpl; [reflexivity | f_equal; exact IHhas_fields].
Qed.

(* membership of a key in Ts gives a field in fs (same position) — but with NoDup
   we get the precise statement: field_lookup returns the value typed at the
   unique key-type. *)
Lemma field_lookup_typed : forall S G fs Ts k v,
  has_fields S G fs Ts -> NoDup (map fst fs) ->
  field_lookup k fs = Some v ->
  exists Tk, In (k, Tk) Ts /\ has_type S G v Tk.
Proof.
  intros S G fs Ts k v Hf. induction Hf; intros Hnd Hlk; simpl in *.
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
Lemma has_fields_split : forall S G pre k e post Ts,
  has_fields S G (pre ++ (k, e) :: post) Ts ->
  exists Tpre Tk Tpost,
    Ts = Tpre ++ (k, Tk) :: Tpost /\
    has_fields S G pre Tpre /\ has_type S G e Tk /\ has_fields S G post Tpost.
Proof.
  intros S G pre. induction pre as [ | [k0 e0] pre IH ]; intros k e post Ts H; simpl in *.
  - inversion H; subst. exists [], T, Ts0. simpl.
    repeat split; [ apply HFnil | assumption | assumption ].
  - inversion H; subst.
    destruct (IH k e post Ts0 H7) as [Tpre [Tk [Tpost [ETs [Hpre [He Hpost]]]]]].
    exists ((k0, T) :: Tpre), Tk, Tpost. subst Ts0. simpl.
    repeat split; [ apply HFcons; assumption | assumption | assumption ].
Qed.

(* re-assemble has_fields after replacing one field's term by a same-typed one. *)
Lemma has_fields_app_replace : forall S G pre k e' post Tpre Tk Tpost,
  has_fields S G pre Tpre ->
  has_type S G e' Tk ->
  has_fields S G post Tpost ->
  has_fields S G (pre ++ (k, e') :: post) (Tpre ++ (k, Tk) :: Tpost).
Proof.
  intros S G pre k e' post Tpre Tk Tpost Hpre He' Hpost.
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

(* PRESERVATION with the store (references formulation). By induction on the STEP
   over configurations. Non-store reductions keep [S] (witness [extends_refl]);
   congruence cases recurse, getting an extended [S'] and store-weakening the
   unchanged surroundings; [SAlloc] EXTENDS [S]; [SDeref]/[SAssign] keep [S] fixed
   and use the store-well-typedness invariant. *)
Theorem preservation : forall S e T st e' st',
  has_type S [] e T ->
  store_well_typed S st ->
  step (e, st) (e', st') ->
  exists S', extends S' S /\ has_type S' [] e' T /\ store_well_typed S' st'.
Proof.
  intros S e T st e' st' Hty Hwt Hstep.
  revert T Hty. remember (e, st) as cfg eqn:Ecfg. remember (e', st') as cfg' eqn:Ecfg'.
  revert e st e' st' Ecfg Ecfg' Hwt.
  induction Hstep; intros e0 st0 e0' st0' Ecfg Ecfg' Hwt T0 Hty;
    injection Ecfg as <- <-; injection Ecfg' as <- <-.
  - (* SBeta *)
    apply inv_app in Hty. destruct Hty as [A [B0 [Hf [Ha Hsub]]]].
    apply inv_lam in Hf. destruct Hf as [Tb [Hb HsubArr]].
    apply rsub_arrow_inv in HsubArr. destruct HsubArr as [HsA HsB].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    assert (HvTl : has_type S [] v T) by (eapply TSub; [ exact Ha | exact HsA ]).
    eapply TSub; [ | eapply RsTrans; [ exact HsB | exact Hsub ] ].
    apply (subst_top S T [] b Tb v); [ exact Hb | exact HvTl ].
  - (* SLet *)
    apply inv_let in Hty. destruct Hty as [A [B [H1 [H2 Hsub]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ | exact Hsub ].
    apply (subst_top S A [] e2 B v); [ exact H2 | exact H1 ].
  - (* SProj *)
    apply inv_proj in Hty. destruct Hty as [fields [W [He [Hin Hsub]]]].
    apply inv_rec in He. destruct He as [Ts [Hfs [Hnd HsubRec]]].
    pose proof (rsub_rec_inv Ts fields k W HsubRec Hin) as [Tk' [HinTk' HsTk']].
    destruct (field_lookup_typed S [] fs Ts k v Hfs Hnd H0) as [Tk [HinTk Hvt]].
    pose proof (has_fields_keys S [] fs Ts Hfs) as Hkeys.
    assert (Hnd' : NoDup (map fst Ts)) by (rewrite <- Hkeys; exact Hnd).
    pose proof (nodup_unique_type Ts k Tk Tk' Hnd' HinTk HinTk') as Heq. subst Tk'.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ exact Hvt | eapply RsTrans; [ apply RsSsub; exact HsTk' | exact Hsub ] ].
  - (* SPrim1: reduce the left operand *)
    apply inv_prim in Hty. destruct Hty as [Ha [Hb Hres]].
    destruct (IHHstep a st a' st' eq_refl eq_refl Hwt (BAtom ANum) Ha)
      as [S' [Hext [Ha' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    destruct Hres as [[Har Hd] | [Hcr Hd]].
    + eapply TSub; [ apply TPrimArith;
        [ exact Har | exact Ha' | eapply store_weakening; [ exact Hb | exact Hext ] ] | exact Hd ].
    + eapply TSub; [ apply TPrimCmp;
        [ exact Hcr | exact Ha' | eapply store_weakening; [ exact Hb | exact Hext ] ] | exact Hd ].
  - (* SPrim2: left is a value, reduce the right operand *)
    apply inv_prim in Hty. destruct Hty as [Ha [Hb Hres]].
    destruct (IHHstep b st b' st' eq_refl eq_refl Hwt (BAtom ANum) Hb)
      as [S' [Hext [Hb' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    destruct Hres as [[Har Hd] | [Hcr Hd]].
    + eapply TSub; [ apply TPrimArith;
        [ exact Har | eapply store_weakening; [ exact Ha | exact Hext ] | exact Hb' ] | exact Hd ].
    + eapply TSub; [ apply TPrimCmp;
        [ exact Hcr | eapply store_weakening; [ exact Ha | exact Hext ] | exact Hb' ] | exact Hd ].
  - (* SPrimArith: both operands are number literals; the result is [LInt _ : AInt
       <: ANum]. The arithmetic result type is [ANum] (subsumed to [T]). *)
    apply inv_prim in Hty. destruct Hty as [Ha [Hb Hres]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    destruct Hres as [[_ Hd] | [Hcr _]].
    + (* arithmetic: result [LInt _] types at [AInt <: ANum], then subsumed to [T] *)
      eapply TSub;
        [ eapply TSub; [ apply (TLit S [] (LInt (prim_arith op m n)))
                       | apply RsSsub; apply SsAtom; apply ALInt ]
        | exact Hd ].
    + (* a comparison op cannot also be arithmetic (SPrimArith carries [arith_op
         op = true], but [cmp_op op = true] is impossible for the same op). *)
      destruct op; simpl in H, Hcr; discriminate.
  - (* SPrimCmp: both operands are number literals; the result is [LBool _ : ABool].
       The comparison result type is [ABool] (subsumed to [T]). *)
    apply inv_prim in Hty. destruct Hty as [Ha [Hb Hres]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    destruct Hres as [[Har _] | [_ Hd]].
    + (* an arithmetic op cannot also be a comparison. *)
      destruct op; simpl in H, Har; discriminate.
    + eapply TSub; [ apply (TLit S [] (LBool (prim_cmp op m n))) | exact Hd ].
  - (* SApp1 *) apply inv_app in Hty. destruct Hty as [A [B [Hf [Ha Hsub]]]].
    destruct (IHHstep f st f' st' eq_refl eq_refl Hwt (BArrow A B) Hf)
      as [S' [Hext [Hf' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TApp; [ exact Hf' | eapply store_weakening; [ exact Ha | exact Hext ] ] | exact Hsub ].
  - (* SApp2 *) apply inv_app in Hty. destruct Hty as [A [B [Hf [Ha Hsub]]]].
    destruct (IHHstep a st a' st' eq_refl eq_refl Hwt A Ha)
      as [S' [Hext [Ha' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TApp; [ eapply store_weakening; [ exact Hf | exact Hext ] | exact Ha' ] | exact Hsub ].
  - (* SLet1 *) apply inv_let in Hty. destruct Hty as [A [B [H1 [H2 Hsub]]]].
    destruct (IHHstep e1 st e1' st' eq_refl eq_refl Hwt A H1)
      as [S' [Hext [H1' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TLet; [ exact H1' | eapply store_weakening; [ exact H2 | exact Hext ] ] | exact Hsub ].
  - (* SProj1 *) apply inv_proj in Hty. destruct Hty as [fields [W [He [Hin Hsub]]]].
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt (BRec fields) He)
      as [S' [Hext [He' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TProj; [ exact He' | exact Hin ] | exact Hsub ].
  - (* SRec: step one field *)
    apply inv_rec in Hty. destruct Hty as [Ts [Hfs [Hnd Hsub]]].
    apply has_fields_split in Hfs.
    destruct Hfs as [Tpre [Tk [Tpost [ETs [Hpre [Hfe Hpost]]]]]]. subst Ts.
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt Tk Hfe)
      as [S' [Hext [Hfe' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ apply TRec | exact Hsub ].
    + eapply has_fields_app_replace;
        [ eapply has_fields_store_weaken; [ exact Hpre | exact Hext ]
        | exact Hfe'
        | eapply has_fields_store_weaken; [ exact Hpost | exact Hext ] ].
    + rewrite <- (map_fst_app_replace pre post k e e'). exact Hnd.
  - (* SIfTrue *)
    apply inv_if in Hty. destruct Hty as [U1 [U2 [_ [H1 [_ Hsub]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ exact H1 | eapply RsTrans; [ apply RsSsub; apply ssub_union_inl | exact Hsub ] ].
  - (* SIfFalse *)
    apply inv_if in Hty. destruct Hty as [U1 [U2 [_ [_ [H2 Hsub]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ exact H2 | eapply RsTrans; [ apply RsSsub; apply ssub_union_inr | exact Hsub ] ].
  - (* SIf1 *)
    apply inv_if in Hty. destruct Hty as [U1 [U2 [Hc [H1 [H2 Hsub]]]]].
    destruct (IHHstep c st c' st' eq_refl eq_refl Hwt (BAtom ABool) Hc)
      as [S' [Hext [Hc' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub;
      [ eapply TIf; [ exact Hc'
                    | eapply store_weakening; [ exact H1 | exact Hext ]
                    | eapply store_weakening; [ exact H2 | exact Hext ] ]
      | exact Hsub ].
  - (* SIfnTrue: THE NARROWING CRUX *)
    apply inv_ifn in Hty. destruct Hty as [U [T1 [T2 [Hc [H1 [H2 Hsub]]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub;
      [ apply (subst_top S truthy_type [] e1 T1 v);
          [ exact H1 | apply (truthy_narrows S v U Hc); assumption ]
      | eapply RsTrans; [ apply RsSsub; apply ssub_union_inl | exact Hsub ] ].
  - (* SIfnFalse *)
    apply inv_ifn in Hty. destruct Hty as [U [T1 [T2 [Hc [H1 [H2 Hsub]]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub;
      [ apply (subst_top S falsy_type [] e2 T2 v);
          [ exact H2 | apply (falsy_narrows S); assumption ]
      | eapply RsTrans; [ apply RsSsub; apply ssub_union_inr | exact Hsub ] ].
  - (* SIfn1 *)
    apply inv_ifn in Hty. destruct Hty as [U [T1 [T2 [Hc [H1 [H2 Hsub]]]]]].
    destruct (IHHstep c st c' st' eq_refl eq_refl Hwt U Hc)
      as [S' [Hext [Hc' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub;
      [ eapply TIfn; [ exact Hc'
                     | eapply store_weakening; [ exact H1 | exact Hext ]
                     | eapply store_weakening; [ exact H2 | exact Hext ] ]
      | exact Hsub ].
  - (* SFix *)
    pose proof (inv_fix S [] T body T0 Hty) as [Hb Hsub].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ | exact Hsub ].
    apply (subst_top S T [] body T (tfix T body));
      [ exact Hb | apply TFix; exact Hb ].
  - (* STtTrue: THE TYPE-TEST NARROWING CRUX *)
    apply inv_typetest in Hty. destruct Hty as [U [T1 [T2 [Hc [Hthen [Helse Hsub]]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub;
      [ apply (subst_top S (tag_type g) [] e1 T1 v);
          [ exact Hthen | apply (tag_narrows S v U g Hc); assumption ]
      | eapply RsTrans; [ apply RsSsub; apply ssub_union_inl | exact Hsub ] ].
  - (* STtFalse *)
    apply inv_typetest in Hty. destruct Hty as [U [T1 [T2 [Hc [Hthen [Helse Hsub]]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub;
      [ apply (subst_top S U [] e2 T2 v); [ exact Helse | exact Hc ]
      | eapply RsTrans; [ apply RsSsub; apply ssub_union_inr | exact Hsub ] ].
  - (* STt1 *)
    apply inv_typetest in Hty. destruct Hty as [U [T1 [T2 [Hc [Hthen [Helse Hsub]]]]]].
    destruct (IHHstep c st c' st' eq_refl eq_refl Hwt U Hc)
      as [S' [Hext [Hc' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub;
      [ eapply TTypeTest; [ exact Hc'
                          | eapply store_weakening; [ exact Hthen | exact Hext ]
                          | eapply store_weakening; [ exact Helse | exact Hext ] ]
      | exact Hsub ].
  (* SPLIT-STEP 3 — THE IMPERATIVE REDUCTIONS. *)
  - (* SAlloc: talloc v / st -> tloc (length st) / st ++ [v]. EXTEND S by [T]. *)
    apply inv_alloc in Hty. destruct Hty as [U [Hv Hsub]].
    destruct Hwt as [Hlen Hcells].
    exists (app S [U]). split; [ apply extends_app1 | ]. split.
    + eapply TSub; [ apply TLoc | exact Hsub ].
      rewrite <- Hlen. rewrite nth_error_app2 by lia.
      replace (List.length S - List.length S) with 0 by lia. reflexivity.
    + split.
      * rewrite !length_app. rewrite Hlen. reflexivity.
      * intros n Tn Hn.
        destruct (Nat.lt_total n (List.length S)) as [Hlt | [Heq | Hgt]].
        -- rewrite nth_error_app1 in Hn by assumption.
           rewrite store_lookup_app_lo by lia.
           eapply store_weakening; [ apply Hcells; exact Hn | apply extends_app1 ].
        -- subst n. rewrite nth_error_app2 in Hn by lia.
           replace (List.length S - List.length S) with 0 in Hn by lia. simpl in Hn.
           injection Hn as <-. rewrite Hlen. rewrite store_lookup_app_last.
           eapply store_weakening; [ exact Hv | apply extends_app1 ].
        -- rewrite nth_error_app2 in Hn by lia.
           assert (Hbad : n - List.length S >= 1) by lia.
           destruct (n - List.length S) as [ | m ]; [ lia | simpl in Hn; destruct m; discriminate Hn ].
  - (* SAlloc1 *) apply inv_alloc in Hty. destruct Hty as [U [He Hsub]].
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt U He) as [S' [Hext [He' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ apply TAlloc; exact He' | exact Hsub ].
  - (* SDeref: tderef (tloc n) / st -> store_lookup n st / st, S fixed *)
    apply inv_deref in Hty. destruct Hty as [U [Hloc Hsub]].
    apply inv_loc in Hloc. destruct Hloc as [W [Hn Href]].
    apply rsub_ref_inv in Href. destruct Href as [HWU _].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    destruct Hwt as [_ Hcells].
    eapply TSub; [ apply Hcells; exact Hn | eapply RsTrans; [ exact HWU | exact Hsub ] ].
  - (* SDeref1 *) apply inv_deref in Hty. destruct Hty as [U [He Hsub]].
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt (BRef U) He) as [S' [Hext [He' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TDeref; exact He' | exact Hsub ].
  - (* SAssign: tassign (tloc n) v / st -> nil / store_update n v st, S fixed *)
    apply inv_assign in Hty. destruct Hty as [U [Hr [Hv Hsub]]].
    apply inv_loc in Hr. destruct Hr as [W [Hn Href]].
    apply rsub_ref_inv in Href. destruct Href as [HWU HUW].
    exists S. split; [ apply extends_refl | ]. split.
    + eapply TSub; [ apply (TLit S []) | exact Hsub ].
    + destruct Hwt as [Hlen Hcells].
      assert (Hnlt : n < List.length st).
      { rewrite <- Hlen. apply nth_error_Some. rewrite Hn. discriminate. }
      split.
      * rewrite store_update_length. exact Hlen.
      * intros m Tm Hm.
        destruct (Nat.eq_dec m n) as [Heq | Hne].
        -- subst m. rewrite Hn in Hm. injection Hm as <-.
           rewrite store_lookup_update_eq by assumption.
           (* v : U (= W content); cell typed at W; need [v : W]. We have [HUW : rsub U W]. *)
           eapply TSub; [ exact Hv | exact HUW ].
        -- rewrite store_lookup_update_neq by (intro Hc; apply Hne; symmetry; exact Hc).
           apply Hcells; exact Hm.
  - (* SAssign1 *) apply inv_assign in Hty. destruct Hty as [U [Hr [He Hsub]]].
    destruct (IHHstep r st r' st' eq_refl eq_refl Hwt (BRef U) Hr) as [S' [Hext [Hr' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TAssign; [ exact Hr' | eapply store_weakening; [ exact He | exact Hext ] ] | exact Hsub ].
  - (* SAssign2 *) apply inv_assign in Hty. destruct Hty as [U [Hr [He Hsub]]].
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt U He) as [S' [Hext [He' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TAssign; [ eapply store_weakening; [ exact Hr | exact Hext ] | exact He' ] | exact Hsub ].
Qed.

(* ===========================================================================
   10. PROGRESS.  has_type [] e T -> value e \/ exists e', step e e'.
   By induction on the typing derivation. Records: either all fields are values
   (the record is a value) or the first non-value field steps (SRec).
   =========================================================================== *)

(* a fields list with all field terms typed in [] : either all are values, or it
   splits as pre ++ (k,e) :: post with [pre] all-values and [e] reducible
   (in the current store [st]). *)
Lemma fields_progress : forall S fs Ts st,
  has_fields S [] fs Ts ->
  (forall ke, In ke fs -> value (snd ke) \/ (exists e' st', step (snd ke, st) (e', st'))) ->
  Forall (fun ke => value (snd ke)) fs \/
  (exists pre k e post, fs = pre ++ (k, e) :: post /\
     Forall (fun ke => value (snd ke)) pre /\ exists e' st', step (e, st) (e', st')).
Proof.
  intros S fs Ts st Hf. induction Hf; intros Hall.
  - left. apply Forall_nil.
  - destruct (Hall (k, e) (or_introl eq_refl)) as [Hv | [e' [st' He']]].
    + destruct IHHf as [Hvs | [pre [k2 [e2 [post [Efs [Hpre Hstep]]]]]]].
      * intros ke Hin. apply Hall. right; exact Hin.
      * left. apply Forall_cons; [ exact Hv | exact Hvs ].
      * right. exists ((k, e) :: pre), k2, e2, post.
        simpl. rewrite Efs. split; [ reflexivity | ].
        split; [ apply Forall_cons; [ exact Hv | exact Hpre ] | exact Hstep ].
    + right. exists [], k, e, fs. simpl.
      split; [ reflexivity | split; [ apply Forall_nil | exists e', st'; exact He' ] ].
Qed.

(* PROGRESS with the store. The store hypothesis [store_well_typed S st] is used in
   the [tderef]/[tassign] location cases (a well-typed location is IN RANGE, so the
   read/write step fires). [talloc] of a value always steps. *)
Theorem progress : forall S e T st,
  has_type S [] e T -> store_well_typed S st ->
  value e \/ exists e' st', step (e, st) (e', st').
Proof.
  intros S0 e0 T0 st0 H0 Hwt0.
  cut (forall S G e T, has_type S G e T -> G = [] ->
         forall st, store_well_typed S st ->
           value e \/ exists e' st', step (e, st) (e', st')).
  { intro Hc. apply (Hc S0 [] e0 T0 H0 eq_refl st0 Hwt0). }
  clear S0 e0 T0 st0 H0 Hwt0. intros S G e T H.
  induction H using has_type_mind with
    (P0 := fun S G fs Ts (_ : has_fields S G fs Ts) =>
       G = [] -> forall st, store_well_typed S st ->
         forall ke, In ke fs -> value (snd ke) \/ (exists e' st', step (snd ke, st) (e', st')));
    intros EG; subst; try (intros st Hwt; left; constructor; fail).
  - (* TVar: no closed var *) intros st Hwt. destruct n; simpl in e; discriminate e.
  - (* TPrimArith *) intros st Hwt. right.
    match goal with [ IHa : [] = [] -> forall st, _ -> value a \/ _ |- _ ] =>
      destruct (IHa eq_refl st Hwt) as [Hva | [a' [sta Ha']]] end.
    + match goal with [ IHb : [] = [] -> forall st, _ -> value b \/ _ |- _ ] =>
        destruct (IHb eq_refl st Hwt) as [Hvb | [b' [stb Hb']]] end.
      * (* both values: canonical-forms ⇒ number literals ⇒ COMPUTE *)
        match goal with [ Ha : has_type S [] a (BAtom ANum) |- _ ] =>
          destruct (canon_num S a Ha Hva) as [m Ea] end.
        match goal with [ Hb : has_type S [] b (BAtom ANum) |- _ ] =>
          destruct (canon_num S b Hb Hvb) as [nn Eb] end.
        subst a b. exists (tlit (LInt (prim_arith op m nn))), st.
        apply SPrimArith; assumption.
      * exists (tprim op a b'), stb. apply SPrim2; assumption.
    + exists (tprim op a' b), sta. apply SPrim1; exact Ha'.
  - (* TPrimCmp *) intros st Hwt. right.
    match goal with [ IHa : [] = [] -> forall st, _ -> value a \/ _ |- _ ] =>
      destruct (IHa eq_refl st Hwt) as [Hva | [a' [sta Ha']]] end.
    + match goal with [ IHb : [] = [] -> forall st, _ -> value b \/ _ |- _ ] =>
        destruct (IHb eq_refl st Hwt) as [Hvb | [b' [stb Hb']]] end.
      * match goal with [ Ha : has_type S [] a (BAtom ANum) |- _ ] =>
          destruct (canon_num S a Ha Hva) as [m Ea] end.
        match goal with [ Hb : has_type S [] b (BAtom ANum) |- _ ] =>
          destruct (canon_num S b Hb Hvb) as [nn Eb] end.
        subst a b. exists (tlit (LBool (prim_cmp op m nn))), st.
        apply SPrimCmp; assumption.
      * exists (tprim op a b'), stb. apply SPrim2; assumption.
    + exists (tprim op a' b), sta. apply SPrim1; exact Ha'.
  - (* TApp *) intros st Hwt. right.
    match goal with [ IHf : [] = [] -> forall st, _ -> value f \/ _ |- _ ] =>
      destruct (IHf eq_refl st Hwt) as [Hvf | [f' [stf Hf']]] end.
    + match goal with [ IHa : [] = [] -> forall st, _ -> value a \/ _ |- _ ] =>
        destruct (IHa eq_refl st Hwt) as [Hva | [a' [sta Ha']]] end.
      * match goal with [ Hf : has_type S [] f (BArrow A B) |- _ ] =>
          destruct (canon_arrow S f A B Hf Hvf) as [Tl [body Ef]] end. subst f.
        exists (subst 0 a body), st. apply SBeta. exact Hva.
      * exists (tapp f a'), sta. apply SApp2; assumption.
    + exists (tapp f' a), stf. apply SApp1; exact Hf'.
  - (* TLet *) intros st Hwt. right.
    match goal with [ IH1 : [] = [] -> forall st, _ -> value e1 \/ _ |- _ ] =>
      destruct (IH1 eq_refl st Hwt) as [Hv1 | [e1' [st1 He1']]] end.
    + exists (subst 0 e1 e2), st. apply SLet. exact Hv1.
    + exists (tlet e1' e2), st1. apply SLet1. exact He1'.
  - (* TRec *) intros st Hwt.
    match goal with [ Hfs0 : has_fields S [] fs Ts, IH : [] = [] -> _ |- _ ] =>
      destruct (fields_progress S fs Ts st Hfs0 (IH eq_refl st Hwt)) as
        [Hvs | [pre [k [e [post [Efs [Hpre [e' [st' He']]]]]]]]] end.
    + left. apply VRec. exact Hvs.
    + right. subst fs. exists (trec (pre ++ (k, e') :: post)), st'.
      apply SRec; [ exact Hpre | exact He' ].
  - (* TProj *) intros st Hwt. right.
    match goal with [ IHe0 : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
      destruct (IHe0 eq_refl st Hwt) as [Hve | [e'' [st'' He'']]] end.
    + match goal with [ He : has_type S [] e (BRec fields), Hin0 : In (k, T) fields |- _ ] =>
        destruct (canon_rec S e fields He Hve) as [fs Efs]; subst e;
        apply inv_rec in He; destruct He as [Ts [Hfs [Hnd HsubRec]]];
        pose proof (rsub_rec_inv Ts fields k T HsubRec Hin0) as [Tk [HinTk _]];
        pose proof (has_fields_keys S [] fs Ts Hfs) as Hkeys
      end.
      assert (Hink : In k (map fst fs)).
      { rewrite Hkeys. replace k with (fst (k, Tk)) by reflexivity. apply in_map. exact HinTk. }
      assert (Hlk : exists v, field_lookup k fs = Some v).
      { clear -Hink. induction fs as [ | [k0 e0] fs IH ]; simpl in *; [ contradiction | ].
        destruct (string_dec k k0) as [Hk | Hk].
        - exists e0; reflexivity.
        - destruct Hink as [Hbad | Hin]; [ symmetry in Hbad; contradiction | apply IH; exact Hin ]. }
      destruct Hlk as [v Hv].
      exists v, st. apply SProj; [ apply VRec; inversion Hve; subst; assumption | exact Hv ].
    + exists (tproj e'' k), st''. apply SProj1; exact He''.
  - (* TSub *) intros st Hwt.
    match goal with [ IH : [] = [] -> _ |- _ ] => apply (IH eq_refl st Hwt) end.
  - (* TIf *) intros st Hwt. right.
    match goal with
    | [ Hc : has_type S [] c (BAtom ABool), IHc : [] = [] -> forall st, _ -> value c \/ _ |- _ ] =>
        destruct (IHc eq_refl st Hwt) as [Hvc | [c' [stc Hc']]]
    end.
    + match goal with [ Hc : has_type S [] c (BAtom ABool), Hvc : value c |- _ ] =>
        destruct (canon_bool S c Hc Hvc) as [bb Eb] end. subst c.
      destruct bb.
      * exists e1, st. apply SIfTrue.
      * exists e2, st. apply SIfFalse.
    + exists (tif c' e1 e2), stc. apply SIf1. exact Hc'.
  - (* TIfn *) intros st Hwt. right.
    match goal with
    | [ IHc : [] = [] -> forall st, _ -> value c \/ _ |- _ ] =>
        destruct (IHc eq_refl st Hwt) as [Hvc | [c' [stc Hc']]]
    end.
    + destruct (value_truthy_or_falsy c Hvc) as [Htr | Hfa].
      * exists (subst 0 c e1), st. apply SIfnTrue; assumption.
      * exists (subst 0 c e2), st. apply SIfnFalse; assumption.
    + exists (tifn c' e1 e2), stc. apply SIfn1. exact Hc'.
  - (* TFix: always steps *)
    intros st Hwt. right. exists (subst 0 (tfix T body) body), st. apply SFix.
  - (* TTypeTest *) intros st Hwt. right.
    match goal with
    | [ IHc : [] = [] -> forall st, _ -> value c \/ _ |- _ ] =>
        destruct (IHc eq_refl st Hwt) as [Hvc | [c' [stc Hc']]]
    end.
    + destruct (value_tag_or_not c g Hvc) as [Hyes | [g' [Hne Hg']]].
      * exists (subst 0 c e1), st. apply STtTrue; assumption.
      * exists (subst 0 c e2), st. eapply STtFalse; eassumption.
    + exists (ttypetest g c' e1 e2), stc. apply STt1. exact Hc'.
  (* TLoc is a VALUE — discharged by the [try (...; constructor)] prelude (VLoc). *)
  - (* TAlloc *) intros st Hwt. right.
    match goal with [ IH : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
      destruct (IH eq_refl st Hwt) as [Hv | [e' [st' He']]] end.
    + exists (tloc (List.length st)), (app st [e]). apply SAlloc. exact Hv.
    + exists (talloc e'), st'. apply SAlloc1. exact He'.
  - (* TDeref *) intros st Hwt. right.
    match goal with [ IH : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
      destruct (IH eq_refl st Hwt) as [Hv | [e' [st' He']]] end.
    + match goal with [ He : has_type S [] e (BRef T) |- _ ] =>
        destruct (canon_ref S e T He Hv) as [n En] end. subst e.
      exists (store_lookup n st), st. apply SDeref.
    + exists (tderef e'), st'. apply SDeref1. exact He'.
  - (* TAssign *) intros st Hwt. right.
    match goal with [ IHr : [] = [] -> forall st, _ -> value r \/ _ |- _ ] =>
      destruct (IHr eq_refl st Hwt) as [Hvr | [r' [str Hr']]] end.
    + match goal with [ IHe : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
        destruct (IHe eq_refl st Hwt) as [Hve | [e' [ste He']]] end.
      * match goal with [ Hr : has_type S [] r (BRef T) |- _ ] =>
          destruct (canon_ref S r T Hr Hvr) as [n En] end. subst r.
        exists (tlit LNil), (store_update n e st). apply SAssign. exact Hve.
      * exists (tassign r e'), ste. apply SAssign2; assumption.
    + exists (tassign r' e), str. apply SAssign1. exact Hr'.
  - (* P0 HFnil *) intros st Hwt ke [].
  - (* P0 HFcons *) intros st Hwt ke Hin. simpl in Hin. destruct Hin as [Heq | Hin].
    + subst ke.
      match goal with [ IH : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
        apply (IH eq_refl st Hwt) end.
    + match goal with [ IH : [] = [] -> forall st, _ -> forall _, In _ ?l -> _ |- _ ] =>
        apply (IH eq_refl st Hwt ke Hin) end.
Qed.

(* ===========================================================================
   11. NON-VACUITY — well-typed terms that step; an ill-typed term rejected.
   =========================================================================== *)


(* the empty store is well-typed under the empty store-typing — the base config. *)
Lemma store_well_typed_nil : store_well_typed [] [].
Proof. split; [ reflexivity | intros n T Hn; destruct n; simpl in Hn; discriminate ]. Qed.

(* (λx:Int. x) 3 is well typed at Int and steps (in any store) to the literal 3. *)
Definition ex_id_app : tm := tapp (tlam (BAtom AInt) (tvar 0)) (tlit (LInt 3)).

Example ex_id_app_typed : has_type [] [] ex_id_app (BAtom AInt).
Proof. eapply TApp; [ apply TLam; apply TVar; reflexivity | apply TLit ]. Qed.

Example ex_id_app_steps : forall st, step (ex_id_app, st) (tlit (LInt 3), st).
Proof.
  intro st. unfold ex_id_app.
  replace (tlit (LInt 3)) with (subst 0 (tlit (LInt 3)) (tvar 0)) by reflexivity.
  apply SBeta. apply VLit.
Qed.

(* {a = 7, b = true}.a is well typed at Int and steps to 7. *)
Definition ex_rec : tm :=
  trec [("a"%string, tlit (LInt 7)); ("b"%string, tlit (LBool true))].
Definition ex_proj : tm := tproj ex_rec "a".

Example ex_proj_typed : has_type [] [] ex_proj (BAtom AInt).
Proof.
  unfold ex_proj, ex_rec.
  eapply TProj.
  - apply TRec.
    + apply HFcons; [ apply TLit | apply HFcons; [ apply TLit | apply HFnil ] ].
    + simpl. apply NoDup_cons; [ simpl; intuition discriminate | ].
      apply NoDup_cons; [ simpl; tauto | apply NoDup_nil ].
  - simpl. left; reflexivity.
Qed.

(* progress + preservation instantiated on the example (a sanity smoke-test). *)
Example ex_progress : value ex_id_app \/ exists e' st', step (ex_id_app, []) (e', st').
Proof. apply (progress [] ex_id_app (BAtom AInt) [] ex_id_app_typed store_well_typed_nil). Qed.

Example ex_preservation :
  exists S', extends S' [] /\ has_type S' [] (tlit (LInt 3)) (BAtom AInt) /\ store_well_typed S' [].
Proof.
  apply (preservation [] ex_id_app (BAtom AInt) [] (tlit (LInt 3)) []
           ex_id_app_typed store_well_typed_nil (ex_id_app_steps [])).
Qed.

(* a genuinely UNION-typed conditional that STEPS. *)
Definition ex_if : tm := tif (tlit (LBool true)) (tlit (LInt 3)) (tlit (LStr 0)).

Example ex_if_typed : has_type [] [] ex_if (BUnion (BAtom AInt) (BAtom AStr)).
Proof. unfold ex_if. apply TIf; [ apply TLit | apply TLit | apply TLit ]. Qed.

Example ex_if_steps : forall st, step (ex_if, st) (tlit (LInt 3), st).
Proof. intro st. unfold ex_if. apply SIfTrue. Qed.

(* ILL-TYPED term rejected: projecting field "a" off the integer 3. *)
Definition ex_bad : tm := tproj (tlit (LInt 3)) "a".

Example ex_bad_untyped : forall S T, ~ has_type S [] ex_bad T.
Proof.
  intros S T H. unfold ex_bad in H. apply inv_proj in H.
  destruct H as [fields [W [He [_ _]]]].
  apply inv_lit in He. simpl in He.
  eapply rsub_atom_not_rec; exact He.
Qed.

(* applying a non-function. *)
Definition ex_bad2 : tm := tapp (tlit (LInt 3)) (tlit (LInt 0)).

Example ex_bad2_untyped : forall S T, ~ has_type S [] ex_bad2 T.
Proof.
  intros S T H. unfold ex_bad2 in H. apply inv_app in H.
  destruct H as [A [B [Hf [_ _]]]].
  apply inv_lit in Hf. simpl in Hf.
  eapply rsub_atom_not_arrow; eauto.
Qed.

(* ===========================================================================
   INCREMENT 13 — THE TRUTHINESS-NARROWING PAYOFF (M2: now Σ-threaded).
   A non-nil consumer applied to a then-narrowed maybe-nil scrutinee TYPES; the
   same use WITHOUT narrowing is REJECTED.
   =========================================================================== *)

Definition g_consumer : tm := tlam truthy_type (tlit (LInt 0)).

Example g_consumer_typed : has_type [] [] g_consumer (BArrow truthy_type (BAtom AInt)).
Proof. apply TLam. apply (TLit [] (truthy_type :: []) (LInt 0)). Qed.

Definition payoff_term : tm :=
  tlet g_consumer
    (tlet (tlit (LInt 5))
      (tifn (tvar 0)
        (tapp (tvar 2) (tvar 0))
        (tlit (LInt 0)))).

Example payoff_types_WITH_narrowing :
  has_type [] [] payoff_term (BUnion (BAtom AInt) (BAtom AInt)).
Proof.
  unfold payoff_term.
  eapply TLet; [ apply g_consumer_typed | ].
  eapply TLet.
  - eapply TSub; [ apply (TLit [] _ (LInt 5))
                 | apply RsSsub; apply (ssub_union_inl (BAtom AInt) (BAtom ANil)) ].
  - eapply TIfn.
    + apply TVar. reflexivity.
    + eapply TApp.
      * apply (TVar _ _ 2). reflexivity.
      * apply (TVar _ _ 0). reflexivity.
    + apply (TLit _ _ (LInt 0)).
Qed.

Example payoff_rejected_WITHOUT_narrowing :
  forall T, ~ has_type []
    [ BUnion (BAtom AInt) (BAtom ANil) ; BArrow truthy_type (BAtom AInt) ]
    (tapp (tvar 1) (tvar 0)) T.
Proof.
  intros T H. apply inv_app in H.
  destruct H as [A [B [Hf [Ha _]]]].
  apply inv_var in Hf. destruct Hf as [Sf [Hlf Hsf]]. simpl in Hlf. injection Hlf as <-.
  apply rsub_arrow_inv in Hsf. destruct Hsf as [Hdom _].
  apply inv_var in Ha. destruct Ha as [Sa [Hla Hsa]]. simpl in Hla. injection Hla as <-.
  pose proof (RsTrans _ _ _ Hsa Hdom) as Hbad.
  apply rsub_sound in Hbad. unfold dsub in Hbad.
  assert (HnilU : denote (BUnion (BAtom AInt) (BAtom ANil)) VNil) by (simpl; right; exact I).
  pose proof (Hbad VNil HnilU) as Hnil_truthy.
  unfold truthy_type in Hnil_truthy. simpl in Hnil_truthy.
  destruct Hnil_truthy as [Hb | [Hn | [Hs | [Hr | [Har | Hrf]]]]];
    simpl in *; try contradiction.
  destruct Hr as [ents [Hc _]]; discriminate.
Qed.

(* ===========================================================================
   INCREMENT 15 — THE TYPE-TEST NARROWING PAYOFF (Σ-threaded).
   =========================================================================== *)

Definition h_consumer : tm := tlam (BAtom ANum) (tlit (LInt 0)).

Example h_consumer_typed : has_type [] [] h_consumer (BArrow (BAtom ANum) (BAtom AInt)).
Proof. apply TLam. apply (TLit [] (BAtom ANum :: []) (LInt 0)). Qed.

Definition tt_payoff_term : tm :=
  tlet h_consumer
    (tlet (tlit (LInt 5))
      (ttypetest TgNum (tvar 0)
        (tapp (tvar 2) (tvar 0))
        (tlit (LInt 0)))).

Example tt_payoff_types_WITH_narrowing :
  has_type [] [] tt_payoff_term (BUnion (BAtom AInt) (BAtom AInt)).
Proof.
  unfold tt_payoff_term.
  eapply TLet; [ apply h_consumer_typed | ].
  eapply TLet.
  - eapply TSub; [ apply (TLit [] _ (LInt 5)) | ].
    apply RsSsub. apply SsUnionInR. apply SsAtom. apply ALInt.
  - eapply (TTypeTest _ _ TgNum _ _ _ (BUnion (BAtom AStr) (BAtom ANum))).
    + apply TVar. reflexivity.
    + eapply TApp.
      * apply (TVar _ _ 2). reflexivity.
      * apply (TVar _ _ 0). reflexivity.
    + apply (TLit _ _ (LInt 0)).
Qed.

Example tt_payoff_rejected_WITHOUT_narrowing :
  forall T, ~ has_type []
    [ BUnion (BAtom AStr) (BAtom ANum) ; BArrow (BAtom ANum) (BAtom AInt) ]
    (tapp (tvar 1) (tvar 0)) T.
Proof.
  intros T H. apply inv_app in H.
  destruct H as [A [B [Hf [Ha _]]]].
  apply inv_var in Hf. destruct Hf as [Sf [Hlf Hsf]]. simpl in Hlf. injection Hlf as <-.
  apply rsub_arrow_inv in Hsf. destruct Hsf as [Hdom _].
  apply inv_var in Ha. destruct Ha as [Sa [Hla Hsa]]. simpl in Hla. injection Hla as <-.
  pose proof (RsTrans _ _ _ Hsa Hdom) as Hbad.
  apply rsub_sound in Hbad. unfold dsub in Hbad.
  assert (HstrU : denote (BUnion (BAtom AStr) (BAtom ANum)) (VStr 0)) by (simpl; left; exact I).
  pose proof (Hbad (VStr 0) HstrU) as Hstr_num. simpl in Hstr_num. exact Hstr_num.
Qed.

(* type-test selection by runtime tag. *)
Example tt_select_then : forall st,
  step (ttypetest TgNum (tlit (LInt 5)) (tvar 0) (tlit (LInt 9)), st)
       (subst 0 (tlit (LInt 5)) (tvar 0), st).
Proof. intro st. apply STtTrue; [ apply VLit | exact I ]. Qed.

(* ===========================================================================
   INCREMENT 14 — GENERAL RECURSION sanity (configuration form).
   =========================================================================== *)
Definition rec_fn : tm := tfix (BArrow (BAtom AInt) (BAtom AInt))
                                (tlam (BAtom AInt) (tvar 0)).

Example rec_fn_typed : has_type [] [] rec_fn (BArrow (BAtom AInt) (BAtom AInt)).
Proof. unfold rec_fn. apply TFix. apply TLam. apply TVar. reflexivity. Qed.

Example rec_fn_steps : forall st,
  step (rec_fn, st) (subst 0 rec_fn (tlam (BAtom AInt) (tvar 0)), st).
Proof. intro st. unfold rec_fn. apply SFix. Qed.

Definition diverge : tm := tfix (BAtom AInt) (tvar 0).

Example diverge_typed : has_type [] [] diverge (BAtom AInt).
Proof. unfold diverge. apply TFix. apply TVar. reflexivity. Qed.

Example diverge_progress :
  value diverge \/ exists e' st', step (diverge, []) (e', st').
Proof. apply (progress [] diverge (BAtom AInt) [] diverge_typed store_well_typed_nil). Qed.

(* ===========================================================================
   M3 — COMPOSING-FEATURES SANITY (the unified store language exercises every
   feature TOGETHER, machine-checked): a ref holding a record; flow-narrowing a
   deref'd ref; a recursive function over a ref; an ill-typed assign rejected.
   =========================================================================== *)

(* (1) A REFERENCE HOLDING A RECORD. [alloc {a = 7}] : BRef (BRec [("a",Int)]). *)
Definition ref_of_rec : tm := talloc (trec [("a"%string, tlit (LInt 7))]).

Example ref_of_rec_typed :
  has_type [] [] ref_of_rec (BRef (BRec [("a"%string, BAtom AInt)])).
Proof.
  unfold ref_of_rec. apply TAlloc. apply TRec.
  - apply HFcons; [ apply TLit | apply HFnil ].
  - simpl. apply NoDup_cons; [ simpl; tauto | apply NoDup_nil ].
Qed.

(* derefencing it recovers the record; projecting [a] gives Int. *)
Example deref_proj_typed :
  has_type [] [] (tproj (tderef ref_of_rec) "a"%string) (BAtom AInt).
Proof.
  eapply TProj.
  - apply TDeref. apply ref_of_rec_typed.
  - simpl. left; reflexivity.
Qed.

(* (2) FLOW-NARROW A DEREF'D REF. A location is truthy, so a [tifn] on a deref'd
   reference narrows the bound var to [truthy_type] in the then-branch — and a
   non-nil consumer applies. Here we directly exercise the truthy-location bridge:
   a closed location [tloc 0] (under store-typing [[BAtom AInt]]) narrows to
   [truthy_type] via [BAnyRef]. *)
Example loc_narrows_to_truthy :
  has_type [ BAtom AInt ] [] (tloc 0) truthy_type.
Proof.
  apply (truthy_narrows [ BAtom AInt ] (tloc 0) (BRef (BAtom AInt))).
  - apply TLoc. reflexivity.
  - apply VLoc.
  - intros [Hb | Hn]; discriminate.
Qed.

(* and a tag-test on a location narrows it to [BAnyRef] (= tag_type TgRef). *)
Example loc_narrows_to_anyref :
  has_type [ BAtom AInt ] [] (tloc 0) BAnyRef.
Proof.
  apply (tag_narrows [ BAtom AInt ] (tloc 0) (BRef (BAtom AInt)) TgRef).
  - apply TLoc. reflexivity.
  - apply VLoc.
  - exact I.
Qed.

(* (3) A RECURSIVE FUNCTION OVER A REF: [tfix (BRef Int -> Int) (λr:BRef Int. !r)]
   — a recursive function that dereferences its reference argument, typed at
   [BRef Int -> Int]. Exercises [tfix] + [tderef] together. *)
Definition rec_over_ref : tm :=
  tfix (BArrow (BRef (BAtom AInt)) (BAtom AInt))
       (tlam (BRef (BAtom AInt)) (tderef (tvar 0))).

Example rec_over_ref_typed :
  has_type [] [] rec_over_ref (BArrow (BRef (BAtom AInt)) (BAtom AInt)).
Proof.
  unfold rec_over_ref. apply TFix. apply TLam. apply TDeref. apply TVar. reflexivity.
Qed.

(* (4) AN ILL-TYPED ASSIGN IS REJECTED: writing a STRING into a [BRef Int] cell.
   The content type is INVARIANT, so [tassign (loc:BRef Int) "s"] is untypeable
   (a string is not [rsub]-below Int — the assign value must match the content). *)
Example ill_typed_assign_rejected :
  forall T, ~ has_type [ BAtom AInt ] [] (tassign (tloc 0) (tlit (LStr 0))) T.
Proof.
  intros T H. apply inv_assign in H. destruct H as [U [Hr [He _]]].
  (* the cell [tloc 0] has type [BRef U] with [U]'s store entry = Int (invariant). *)
  apply inv_loc in Hr. destruct Hr as [W [Hn Href]]. simpl in Hn. injection Hn as <-.
  apply rsub_ref_inv in Href. destruct Href as [HWU HUW].
  (* the value is a string [: AStr] subsumed to U; combined with U ≡ Int (= W),
     a string would inhabit Int — refute semantically at [VStr 0]. *)
  apply inv_lit in He. simpl in He.
  pose proof (RsTrans _ _ _ He HUW) as Hbad.   (* rsub AStr W, W = BAtom AInt *)
  apply rsub_sound in Hbad. pose proof (Hbad (VStr 0) I) as Hcontra.
  simpl in Hcontra. exact Hcontra.
Qed.

(* and the WELL-typed assign (string into a [BRef Str] cell) DOES type, yielding
   the unit/nil result type. *)
Example well_typed_assign :
  has_type [ BAtom AStr ] [] (tassign (tloc 0) (tlit (LStr 0))) (BAtom ANil).
Proof.
  eapply TAssign; [ apply TLoc; reflexivity | apply TLit ].
Qed.

(* the assign STEPS (writes the cell, yields nil) under a matching store. *)
Example well_typed_assign_steps :
  step (tassign (tloc 0) (tlit (LStr 0)), [tlit (LStr 9)])
       (tlit LNil, store_update 0 (tlit (LStr 0)) [tlit (LStr 9)]).
Proof. apply SAssign. apply VLit. Qed.

(* ===========================================================================
   M4 — MUTABLE TABLES + REASSIGNABLE LOCALS, via the PROVEN reference core
   (records-of-refs). NO new core terms: Lua's mutation is ENCODED into the
   existing reference + record machinery, so soundness is LARGELY INHERITED —
   [progress] / [preservation] already cover [talloc]/[tderef]/[tassign]/[trec]/
   [tproj], so every encoded operation is automatically sound.

   THE ENCODING (the key insight). A Lua mutable table of type [{x:T, y:U}] is a
   RECORD OF REFERENCE CELLS [BRec [("x", BRef T); ("y", BRef U)]]:

     - the FIELD SET is FIXED — the record STRUCTURE is immutable and
       width/depth-COVARIANT (inherited from [BRec], subtype.v);
     - each FIELD is a mutable [BRef] CELL — so per-field mutation is INVARIANT,
       the sound rule, inherited from [BRef]'s invariance (subtype.v / [rsub]).

   The OPERATIONS desugar (no new term-formers):

     - mutable table literal [{x = e}]   ⇒  [trec [("x", talloc e)]]   (a ref per field)
     - field READ      [t.x]             ⇒  [tderef (tproj t "x")]
     - field WRITE     [t.x := v]        ⇒  [tassign (tproj t "x") v]
     - reassignable local [local x = e]  ⇒  a ref cell [talloc e]
     - local reassign  [x := v]          ⇒  [tassign x v]

   ALIASING — the defining Lua-table property — is SHARED CELLS: two bindings to
   the SAME record VALUE [trec [("x", tloc l)]] share location [l], so a write
   through one is observed through the other (it is the same store cell [l]).

   HONEST SCOPE: tables as records-of-refs, FIXED string-keyed field set. Dynamic
   field add/remove, metatables, non-string keys, array part, and nil-assignment-
   deletes-key are DEFERRED (TODO.md / proof-kernel.md backlog).
   =========================================================================== *)

(* ---- multi-step (reflexive-transitive closure of [step]) — the sequential
   read-after-write / aliasing examples chain several reductions, so we need the
   transitive closure of the single-step relation over configurations. A plain
   inductive, no axiom. *)
Inductive multistep : tm * store -> tm * store -> Prop :=
  | MSrefl : forall c, multistep c c
  | MSstep : forall c1 c2 c3, step c1 c2 -> multistep c2 c3 -> multistep c1 c3.

Lemma multistep_trans : forall a b c, multistep a b -> multistep b c -> multistep a c.
Proof.
  intros a b c Hab Hbc. induction Hab; [ exact Hbc | ].
  eapply MSstep; [ eassumption | apply IHHab; exact Hbc ].
Qed.

(* one-step lift, for readability. *)
Lemma multistep_one : forall a b, step a b -> multistep a b.
Proof. intros a b H. eapply MSstep; [ exact H | apply MSrefl ]. Qed.

(* ---- The mutable-table TYPE (a record of reference cells) and its VALUE form.
   [mtable_ty] = the type [{x : BRef Int}] — a one-field mutable table whose [x]
   field is an Int cell. [mtable_val l] = the runtime table VALUE backed by the
   store location [l] (a record holding the location [tloc l]). *)
Definition mtable_ty : BTy := BRec [("x"%string, BRef (BAtom AInt))].
Definition mtable_val (l : nat) : tm := trec [("x"%string, tloc l)].

(* a table value is a [value] (a record whose only field is a location value). *)
Lemma mtable_val_value : forall l, value (mtable_val l).
Proof.
  intro l. unfold mtable_val. apply VRec. apply Forall_cons; [ apply VLoc | apply Forall_nil ].
Qed.

(* the table value types at [mtable_ty] under any store-typing whose entry [l] is
   Int — the encoding's central typing fact (a record of [BRef Int] cells). *)
Lemma mtable_val_typed : forall S l,
  nth_error S l = Some (BAtom AInt) ->
  has_type S [] (mtable_val l) mtable_ty.
Proof.
  intros S l Hl. unfold mtable_val, mtable_ty. apply TRec.
  - apply HFcons; [ apply TLoc; exact Hl | apply HFnil ].
  - simpl. apply NoDup_cons; [ simpl; tauto | apply NoDup_nil ].
Qed.

(* projecting the [x] field of the table value yields the LOCATION (a [BRef Int]).
   This is the shared mechanism behind both read and write. *)
Lemma mtable_proj_x : forall S l,
  nth_error S l = Some (BAtom AInt) ->
  has_type S [] (tproj (mtable_val l) "x"%string) (BRef (BAtom AInt)).
Proof.
  intros S l Hl. eapply TProj; [ apply mtable_val_typed; exact Hl | simpl; left; reflexivity ].
Qed.

(* projection STEPS to the field's location (a record-value projection). *)
Lemma mtable_proj_x_steps : forall l st,
  step (tproj (mtable_val l) "x"%string, st) (tloc l, st).
Proof.
  intros l st. unfold mtable_val. apply SProj.
  - apply mtable_val_value.
  - simpl. reflexivity.
Qed.

(* ===========================================================================
   EXAMPLE 1 — MUTATION reads the NEW value.
   Build a mutable table {x = 7}, assign t.x := 9, then read t.x back as 9.
   Encoded: read = [tderef (tproj t "x")], write = [tassign (tproj t "x") 9].
   We run the WHOLE program in the store: alloc the cell, then a [tlet]
   sequences "write 9" before "read x", and the read observes 9.
   =========================================================================== *)

(* The desugared mutable-table program built from a literal {x = 7}: allocate the
   field cell, bind the table, then (assign 9; read x). We work at the already-
   allocated VALUE form (the table backed by location 0 in store [7]) since the
   literal {x=7} reduces to that (alloc appends the cell). *)

(* TYPING: with the cell at location 0 holding Int, the read-after-write program
   [tlet (t.x := 9) (t.x)] is well typed at Int. *)
Example mutation_typed :
  has_type [ BAtom AInt ] []
    (tlet (tassign (tproj (mtable_val 0) "x"%string) (tlit (LInt 9)))
          (tderef (tproj (mtable_val 0) "x"%string)))
    (BAtom AInt).
Proof.
  eapply TLet.
  - (* the write: tassign (proj t x : BRef Int) (9 : Int) : nil *)
    eapply TAssign; [ apply mtable_proj_x; reflexivity | apply TLit ].
  - (* the read, in the EXTENDED context (the let binds the nil result, unused):
       the table value is closed, so it types under any context via store-only. *)
    apply has_type_closed_any.
    apply TDeref. apply mtable_proj_x. reflexivity.
Qed.

(* STEPS: starting from store [7], the program multi-steps to the literal 9.
   (1) the write: proj ⇒ loc 0, then assign 9 ⇒ nil, store becomes [9];
   (2) let binds nil (the body is closed, unaffected);
   (3) the read: proj ⇒ loc 0, then deref ⇒ 9. *)
Example mutation_steps :
  multistep
    (tlet (tassign (tproj (mtable_val 0) "x"%string) (tlit (LInt 9)))
          (tderef (tproj (mtable_val 0) "x"%string)),
     [tlit (LInt 7)])
    (tlit (LInt 9), [tlit (LInt 9)]).
Proof.
  (* write: project the field to its location 0 (store unchanged) *)
  eapply MSstep.
  { apply SLet1. apply SAssign1. apply mtable_proj_x_steps. }
  (* assign 9 to location 0: store [7] -> [9], yields nil *)
  eapply MSstep.
  { apply SLet1. apply SAssign. apply VLit. }
  (* let binds the nil value; body is closed so subst is identity *)
  eapply MSstep.
  { apply SLet. apply VLit. }
  (* read: project to location 0 *)
  eapply MSstep.
  { simpl. apply SDeref1. apply mtable_proj_x_steps. }
  (* deref location 0 in store [9] reads 9 *)
  eapply MSstep.
  { apply SDeref. }
  simpl. apply MSrefl.
Qed.

(* ===========================================================================
   EXAMPLE 2 — ALIASING (the defining Lua-table property).
   Two bindings [a], [b] to the SAME table value (shared cell, location 0).
   A field mutation through [a] is observed through [b]: [let a = <table> in
   let b = a in (a.x := 9); b.x] reads 9.
   Both [a] and [b] are the SAME closed table value [mtable_val 0], so they share
   store location 0 — a write via [a] mutates the cell [b] reads.
   =========================================================================== *)

(* The aliasing program, fully desugared. After the two lets bind the (closed)
   table value, [a] and [b] are both [mtable_val 0]; we sequence the write via
   the first alias and the read via the second with a [tlet]. *)
Definition alias_prog : tm :=
  tlet (mtable_val 0)                                    (* a := <table>           *)
    (tlet (tvar 0)                                       (* b := a                 *)
      (tlet (tassign (tproj (tvar 1) "x"%string) (tlit (LInt 9)))  (* a.x := 9     *)
            (tderef (tproj (tvar 1) "x"%string)))).      (* b.x  (reads via alias) *)

(* In this program, after the binders, de Bruijn [tvar 1] in the innermost body
   refers to [b] (which equals [a] = the table value): the write and the read go
   through the SAME location. TYPING at Int. *)
Example aliasing_typed :
  has_type [ BAtom AInt ] [] alias_prog (BAtom AInt).
Proof.
  unfold alias_prog.
  eapply TLet; [ apply mtable_val_typed; reflexivity | ].
  eapply TLet; [ apply TVar; reflexivity | ].
  eapply TLet.
  - (* a.x := 9 : the cell at [b]/[a] is BRef Int; 9 : Int *)
    eapply TAssign.
    + eapply TProj; [ apply TVar; reflexivity | simpl; left; reflexivity ].
    + apply TLit.
  - (* b.x : read the SAME cell, : Int *)
    eapply TDeref. eapply TProj; [ apply TVar; reflexivity | simpl; left; reflexivity ].
Qed.

(* STEPS: from store [7], the aliasing program multi-steps to 9 — the write
   through [a] is observed by the read through [b] (both touch location 0). *)
Example aliasing_steps :
  multistep (alias_prog, [tlit (LInt 7)]) (tlit (LInt 9), [tlit (LInt 9)]).
Proof.
  unfold alias_prog.
  (* bind a := <table value> (a value already) *)
  eapply MSstep. { apply SLet. apply mtable_val_value. }
  (* the body, with [a] substituted: tlet (tvar 0 -> table) ... ; subst 0 (table) (tvar 0) = table *)
  simpl.
  (* bind b := a (= the table value) *)
  eapply MSstep. { apply SLet. apply mtable_val_value. }
  simpl.
  (* write a.x := 9: project -> loc 0, then assign -> nil, store [7] -> [9] *)
  eapply MSstep. { apply SLet1. apply SAssign1. apply mtable_proj_x_steps. }
  eapply MSstep. { apply SLet1. apply SAssign. apply VLit. }
  (* let binds nil; body (closed read through the shared cell) survives *)
  eapply MSstep. { apply SLet. apply VLit. }
  simpl.
  (* read b.x: project -> loc 0, deref -> 9 (the value written via a) *)
  eapply MSstep. { apply SDeref1. apply mtable_proj_x_steps. }
  eapply MSstep. { apply SDeref. }
  simpl. apply MSrefl.
Qed.

(* ===========================================================================
   EXAMPLE 3 — FIELD INVARIANCE (soundness). Assigning a WRONG-typed value to a
   field is REJECTED: [t.x := "str"] where [x : Int] is untypeable, because the
   field is a [BRef Int] cell and [BRef] is INVARIANT (a [BRef Int] is NOT usable
   as a [BRef Num], let alone a string sink). The WELL-typed assign IS accepted.
   =========================================================================== *)

(* the ILL-typed write — a string into an Int field cell — is rejected at EVERY
   type. Reuses the proven [rsub_ref_inv] (BRef invariance) + semantic refutation. *)
Example field_invariance_rejected :
  forall T, ~ has_type [ BAtom AInt ] []
              (tassign (tproj (mtable_val 0) "x"%string) (tlit (LStr 0))) T.
Proof.
  intros T H. apply inv_assign in H. destruct H as [U [Hr [He _]]].
  (* the field projection has type [BRef U]; invert it to the field's true type. *)
  apply inv_proj in Hr. destruct Hr as [fields [W [Htab [Hin Href]]]].
  (* the table value's field-set is exactly [("x", BRef Int)]. *)
  apply inv_rec in Htab. destruct Htab as [Ts [Hfs [_ Hrec]]].
  unfold mtable_val in Hfs. inversion Hfs as [ | S0 G0 k0 e0 T0 fs0 Ts0 Hloc Hrest Hke ]; subst.
  inversion Hrest; subst. clear Hrest.
  (* Ts = [("x", BRef Int)] (the loc 0 has store entry Int). *)
  apply inv_loc in Hloc. destruct Hloc as [W0 [Hn Hlsub]]. simpl in Hn. injection Hn as <-.
  apply rsub_rec_super in Hrec. simpl in Hrec.
  (* [W] (the projected field type as BRef) supplies the demanded field; relate to BRef Int. *)
  destruct (srec_lookup _ _ Hrec "x"%string W Hin) as [Tf [HinTf HsubTf]].
  simpl in HinTf. destruct HinTf as [Heq | []]. injection Heq as <-.
  (* The cell's synthesized type [Tf] satisfies [BRef Int <: Tf] (Hlsub, the loc's
     store entry is Int) and supplies the demanded [W] ([HsubTf : ssub Tf W]);
     [Href : rsub W (BRef U)]. Compose the chain: BRef Int <: Tf <: W <: BRef U,
     so by INVARIANCE U ≡ Int. The value [He : rsub AStr U]: a string would inhabit
     Int — refute at [VStr 0]. *)
  pose proof (RsTrans _ _ _ Hlsub
                (RsTrans _ _ _ (RsSsub _ _ HsubTf) Href)) as HrefInt.  (* rsub (BRef Int) (BRef U) *)
  apply rsub_ref_inv in HrefInt. destruct HrefInt as [HIntU HUInt].
  apply inv_lit in He. simpl in He.  (* He : rsub AStr U *)
  apply rsub_sound in He.            (* dsub AStr U *)
  apply rsub_sound in HUInt.         (* dsub U Int *)
  pose proof (He (VStr 0) I) as HUstr.
  pose proof (HUInt (VStr 0) HUstr) as Hbad.
  simpl in Hbad. exact Hbad.
Qed.

(* the WELL-typed write — an Int into the Int field cell — IS accepted, yielding
   the unit/nil result type. *)
Example field_invariance_accepted :
  has_type [ BAtom AInt ] []
    (tassign (tproj (mtable_val 0) "x"%string) (tlit (LInt 9))) (BAtom ANil).
Proof.
  eapply TAssign; [ apply mtable_proj_x; reflexivity | apply TLit ].
Qed.

(* and a DIRECT statement of the cell's invariance: a [BRef Int] field cannot be
   used as a [BRef Num] (the invariant rule — covariant use is REJECTED), even
   though [Int <: Num] holds at the value level. *)
Example field_cell_invariant :
  ~ rsub (BRef (BAtom AInt)) (BRef (BAtom ANum)).
Proof.
  intro H. apply rsub_ref_inv in H. destruct H as [_ HNumInt].
  (* HNumInt : rsub Num Int — would make every number an Int; refute at VFloat 0. *)
  apply rsub_sound in HNumInt.
  pose proof (HNumInt (VFloat 0) I) as Hbad. simpl in Hbad. exact Hbad.
Qed.

(* ===========================================================================
   EXAMPLE 4 — COVARIANT STRUCTURE still works, composing with invariant cells.
   The record-of-refs is width-subtypeable on its IMMUTABLE field set: a table
   with an EXTRA field is a subtype on the smaller field set — and this composes
   with the per-field invariant [BRef] cells (the field types match exactly).
   =========================================================================== *)

(* a two-field mutable table [{x : BRef Int; y : BRef Str}] WIDTH-subtypes to the
   one-field [{x : BRef Int}] — dropping a field is supertyping (covariant
   structure), while the surviving [x] cell stays the SAME invariant [BRef Int]. *)
Example covariant_width_over_cells :
  rsub (BRec [("x"%string, BRef (BAtom AInt)); ("y"%string, BRef (BAtom AStr))])
       (BRec [("x"%string, BRef (BAtom AInt))]).
Proof.
  apply RsSsub. apply SsRec.
  (* demanded field [x : BRef Int] is supplied by the wider record's [x], same type. *)
  eapply SrCons; [ simpl; left; reflexivity | apply SsRefl | apply SrNil ].
Qed.

(* the wider table VALUE (backed by two cells, locations 0 and 1) types at the
   NARROWER mutable-table type by subsumption — covariant width composing with the
   invariant cells (the [x] cell's [BRef Int] is preserved EXACTLY). *)
Definition mtable2_val : tm :=
  trec [("x"%string, tloc 0); ("y"%string, tloc 1)].

Example covariant_structure_composes :
  has_type [ BAtom AInt ; BAtom AStr ] [] mtable2_val mtable_ty.
Proof.
  unfold mtable2_val, mtable_ty.
  eapply TSub.
  - (* the wide record types at its full field set *)
    apply TRec.
    + apply HFcons; [ apply TLoc; reflexivity | ].
      apply HFcons; [ apply TLoc; reflexivity | apply HFnil ].
    + simpl. apply NoDup_cons;
        [ simpl; intros [H|[]]; discriminate | apply NoDup_cons; [ simpl; tauto | apply NoDup_nil ] ].
  - (* subsume WIDTH-wise to the one-field mutable-table type (invariant x cell kept) *)
    apply covariant_width_over_cells.
Qed.

(* and the projected [x] of the WIDER table is STILL an invariant [BRef Int] cell —
   confirming covariant structure does NOT relax the per-field invariance. *)
Example covariant_field_still_invariant :
  has_type [ BAtom AInt ; BAtom AStr ] []
    (tproj mtable2_val "x"%string) (BRef (BAtom AInt)).
Proof.
  unfold mtable2_val.
  eapply TProj.
  - apply TRec.
    + apply HFcons; [ apply TLoc; reflexivity | ].
      apply HFcons; [ apply TLoc; reflexivity | apply HFnil ].
    + simpl. apply NoDup_cons;
        [ simpl; intros [H|[]]; discriminate | apply NoDup_cons; [ simpl; tauto | apply NoDup_nil ] ].
  - simpl. left; reflexivity.
Qed.

(* ===========================================================================
   EXAMPLE 5 — REASSIGNABLE LOCAL: a local as a ref cell, reassigned, reads the
   NEW value. [local x = 7; x := 9; x] reads 9. Encoded: the local is a ref cell
   [talloc 7]; reassignment is [tassign x 9]; reading is [tderef x].
   =========================================================================== *)

(* The full reassignable-local program (un-allocated form): allocate the cell, bind
   it as [x] (de Bruijn 0), reassign 9, then read. Built with [tlet]s. *)
Definition reassign_local_prog : tm :=
  tlet (talloc (tlit (LInt 7)))                 (* local x = 7  (x : BRef Int)        *)
    (tlet (tassign (tvar 0) (tlit (LInt 9)))    (* x := 9                             *)
          (tderef (tvar 1))).                   (* read x  (de Bruijn 1 past the nil) *)

(* TYPING at Int: the local cell is [BRef Int]; reassigning 9 is well typed
   (invariant, exact match); reading yields Int. *)
Example reassign_local_typed :
  has_type [] [] reassign_local_prog (BAtom AInt).
Proof.
  unfold reassign_local_prog.
  apply TLet with (A := BRef (BAtom AInt)).
  { apply TAlloc. apply TLit. }
  apply TLet with (A := BAtom ANil).
  { eapply TAssign with (T := BAtom AInt); [ apply TVar; reflexivity | apply TLit ]. }
  (* read: de Bruijn 1 (past the nil binding) is the cell : BRef Int *)
  apply TDeref. apply TVar. reflexivity.
Qed.

(* STEPS: from the EMPTY store, the program multi-steps to 9 — the reassignment
   wrote the cell, the read observes the NEW value. *)
Example reassign_local_steps :
  multistep (reassign_local_prog, []) (tlit (LInt 9), [tlit (LInt 9)]).
Proof.
  unfold reassign_local_prog.
  (* alloc 7: append the cell, location 0, store [] -> [7] *)
  eapply MSstep. { apply SLet1. apply SAlloc. apply VLit. }
  simpl.
  (* bind x := loc 0 *)
  eapply MSstep. { apply SLet. apply VLoc. }
  simpl.
  (* reassign x := 9: write location 0, store [7] -> [9], yields nil *)
  eapply MSstep. { apply SLet1. apply SAssign. apply VLit. }
  (* bind the nil result *)
  eapply MSstep. { apply SLet. apply VLit. }
  simpl.
  (* read x: deref location 0 in store [9] reads 9 *)
  eapply MSstep. { apply SDeref. }
  simpl. apply MSrefl.
Qed.

(* ===========================================================================
   INCREMENT 19 — PRIMITIVE OPERATOR SANITY (real computation).
   3 + 4 types at ANum and multi-steps to 7; 3 < 4 types at Bool and steps to
   true; "s" + 1 is REJECTED (operand not a number); a well-typed arithmetic chain.
   =========================================================================== *)

(* [3 + 4] is well typed at [ANum] and steps (single step) to [7]. *)
Definition ex_add : tm := tprim PAdd (tlit (LInt 3)) (tlit (LInt 4)).

Example ex_add_typed : has_type [] [] ex_add (BAtom ANum).
Proof.
  unfold ex_add. apply TPrimArith; [ reflexivity | | ];
    (eapply TSub; [ apply (TLit [] [] (LInt _)) | apply RsSsub; apply SsAtom; apply ALInt ]).
Qed.

Example ex_add_steps : forall st,
  step (ex_add, st) (tlit (LInt 7), st).
Proof.
  intro st. unfold ex_add.
  replace (tlit (LInt 7)) with (tlit (LInt (prim_arith PAdd 3 4))) by reflexivity.
  apply SPrimArith. reflexivity.
Qed.

(* and via [Compute] the arithmetic genuinely reduces. *)
Example compute_add : prim_arith PAdd 3 4 = 7. Proof. reflexivity. Qed.

(* [3 < 4] types at the boolean type and steps to [true]. *)
Definition ex_lt : tm := tprim PLt (tlit (LInt 3)) (tlit (LInt 4)).

Example ex_lt_typed : has_type [] [] ex_lt (BAtom ABool).
Proof.
  unfold ex_lt. apply TPrimCmp; [ reflexivity | | ];
    (eapply TSub; [ apply (TLit [] [] (LInt _)) | apply RsSsub; apply SsAtom; apply ALInt ]).
Qed.

Example ex_lt_steps : forall st,
  step (ex_lt, st) (tlit (LBool true), st).
Proof.
  intro st. unfold ex_lt.
  replace (tlit (LBool true)) with (tlit (LBool (prim_cmp PLt 3 4))) by reflexivity.
  apply SPrimCmp. reflexivity.
Qed.

Example compute_lt : prim_cmp PLt 3 4 = true. Proof. reflexivity. Qed.

(* a WELL-TYPED arithmetic chain: [(3 + 4) * 2] types at [ANum] and multi-steps to
   [14]. Exercises the operand congruence (the inner [3+4] reduces first). *)
Definition ex_chain : tm :=
  tprim PMul (tprim PAdd (tlit (LInt 3)) (tlit (LInt 4))) (tlit (LInt 2)).

Example ex_chain_typed : has_type [] [] ex_chain (BAtom ANum).
Proof.
  unfold ex_chain. apply TPrimArith; [ reflexivity | apply ex_add_typed | ].
  eapply TSub; [ apply (TLit [] [] (LInt 2)) | apply RsSsub; apply SsAtom; apply ALInt ].
Qed.

Example ex_chain_steps :
  multistep (ex_chain, []) (tlit (LInt 14), []).
Proof.
  unfold ex_chain.
  (* reduce the inner [3 + 4] to [7] under the left operand *)
  eapply MSstep. { apply SPrim1. apply SPrimArith. reflexivity. }
  (* now [7 * 2] computes to [14] *)
  eapply MSstep. { apply SPrimArith. reflexivity. }
  simpl. apply MSrefl.
Qed.

(* progress + preservation instantiated on [3 + 4] (a sanity smoke-test). *)
Example ex_add_progress :
  value ex_add \/ exists e' st', step (ex_add, []) (e', st').
Proof. apply (progress [] ex_add (BAtom ANum) [] ex_add_typed store_well_typed_nil). Qed.

Example ex_add_preservation :
  exists S', extends S' [] /\ has_type S' [] (tlit (LInt 7)) (BAtom ANum) /\ store_well_typed S' [].
Proof.
  apply (preservation [] ex_add (BAtom ANum) [] (tlit (LInt 7)) []
           ex_add_typed store_well_typed_nil (ex_add_steps [])).
Qed.

(* ILL-TYPED: [ "s" + 1 ] is REJECTED — the string operand is not a number. Proved
   at EVERY type (a string [: AStr] is not [rsub]-below [ANum]). *)
Definition ex_bad_add : tm := tprim PAdd (tlit (LStr 0)) (tlit (LInt 1)).

Example ex_bad_add_untyped : forall S T, ~ has_type S [] ex_bad_add T.
Proof.
  intros S T H. unfold ex_bad_add in H. apply inv_prim in H.
  destruct H as [Ha [_ _]].
  apply inv_lit in Ha. simpl in Ha.   (* Ha : rsub AStr ANum *)
  apply rsub_sound in Ha. pose proof (Ha (VStr 0) I) as Hbad. exact Hbad.
Qed.

(* ===========================================================================
   INCREMENT 20 — IMPERATIVE STATEMENT FORMS (encoded over the existing core).

   Lua's imperative statements are shown to encode SOUNDLY into the existing
   term language with NO new core terms — soundness is inherited from the already-
   proven progress + preservation. The encodings are plain [Definition]s over the
   existing constructors; each is documented. The capstone is a REAL imperative
   program: a [while]-loop that mutates a reference counter and computes a sum.

   THE ENCODINGS
   -------------
   - UNIT / "returns nothing":  a statement that produces no value yields the unit
     value [tlit LNil]; its type is [Tunit := BAtom ANil].
   - SEQUENCING  [s1 ; s2]  ==>  [tseq s1 s2 := tlet s1 (lift 1 0 s2)].  Evaluate
     [s1] (for its effect), bind+discard its value, then run [s2]. Lifting [s2]
     past the binder makes the binder UNUSED, so [s2]'s free variables keep their
     original de Bruijn meaning — sequencing is transparent to the surrounding
     scope (proved [seq_step] / [tseq_typed]).
   - IF-STATEMENT  [if c then s1 else s2 end]  ==>  [tif c s1 s2]  (already in the
     core; the conditional). Each branch is a statement; a "do-nothing" else is
     [tlit LNil].
   - BLOCK / local scope  ==>  [tlet] nesting (already in the core: [local x = e;
     rest] is [tlet e rest]).
   - WHILE  [while c do body end]  ==>  recursion:
       [twhile c body := tfix Tunit (tif c (tseq body (tvar 0)) (tlit LNil))].
     The fixpoint's self-reference is de Bruijn 0; one unfold re-evaluates [c]
     against the CURRENT store, and if [c] is true runs [body] (which MUTATES the
     store) then re-invokes the self-reference [tvar 0] — looping. When [c] becomes
     false the else-branch [tlit LNil] terminates the loop with the unit value.
     Because [c]/[body] sit under the fix's self-ref binder, the caller writes them
     with surrounding locals shifted up by one (de Bruijn). Termination is NOT
     required for soundness: [tfix] always steps and preserves its type, so even a
     non-terminating loop is sound (see [while_true_diverges] below).

   SCOPE (honest). The encoded statement forms are: sequencing, if-statement,
   block, and while. DEFERRED to the backlog: [break] / [return] / [goto] (non-
   local control flow — needs labelled exits / continuations), numeric [for] and
   generic [for-in] (iterator protocols). [while]'s TERMINATION relies on the loop
   body mutating the state the condition reads; general termination is neither
   provided nor needed (soundness tolerates divergence).
   =========================================================================== *)

Definition Tunit : BTy := BAtom ANil.

(* SEQUENCING. [tseq a b] runs [a] for effect, discards its value, runs [b]; [b]
   is lifted past the discard-binder so its free vars are unchanged. *)
Definition tseq (a b : tm) : tm := tlet a (lift 1 0 b).

(* WHILE. The fixpoint re-evaluates [c] (current store) each unfold; true ⇒ run
   [body] then recurse via the self-ref [tvar 0]; false ⇒ stop with [tlit LNil]. *)
Definition twhile (c body : tm) : tm :=
  tfix Tunit (tif c (tseq body (tvar 0)) (tlit LNil)).

(* ---- The de Bruijn cancellation [tseq] rests on: substituting at [k] into a term
   lifted at [k] is the identity (the lifted term has no [k]-variable, and the
   shift-up is exactly undone). Proved for ALL terms by the strong induction
   principle (the record case carries its per-field IH). *)
Lemma subst_lift_cancel : forall e s k, subst k s (lift 1 k e) = e.
Proof.
  intro e.
  induction e using tm_rect_strong with
    (Pl := fun fs => forall ss kk,
       map (fun ke => (fst ke, subst kk ss (snd ke)))
           (map (fun ke => (fst ke, lift 1 kk (snd ke))) fs) = fs);
    intros ss kk; simpl; try reflexivity.
  - (* tvar n: case n<k unchanged, n>=k shifted up by 1 then subst at k cancels *)
    destruct (Nat.ltb_spec n kk) as [Hlt | Hge]; simpl.
    + destruct (Nat.compare_spec n kk) as [He|He|He]; try reflexivity; lia.
    + destruct (Nat.compare_spec (n+1) kk) as [He|He|He]; try lia.
      f_equal. lia.
  - (* tprim *) rewrite IHe1, IHe2; reflexivity.
  - (* tlam *) rewrite IHe; reflexivity.
  - (* tapp *) rewrite IHe1, IHe2; reflexivity.
  - (* tlet *) rewrite IHe1, IHe2; reflexivity.
  - (* trec *) f_equal. apply IHe.
  - (* tproj *) rewrite IHe; reflexivity.
  - (* tif *) rewrite IHe1, IHe2, IHe3; reflexivity.
  - (* tifn *) rewrite IHe1, IHe2, IHe3; reflexivity.
  - (* tfix *) rewrite IHe; reflexivity.
  - (* ttypetest *) rewrite IHe1, IHe2, IHe3; reflexivity.
  - (* talloc *) rewrite IHe; reflexivity.
  - (* tderef *) rewrite IHe; reflexivity.
  - (* tassign *) rewrite IHe1, IHe2; reflexivity.
  - (* Pl cons *) rewrite IHe, IHe0; reflexivity.
Qed.

(* TYPING the sequencing form: [a : Ta], [b : Tb] ⇒ [tseq a b : Tb]. The discard-
   binder gets [a]'s type; [b] is lifted past it (a [weakening_cons] of a closed-
   under-the-original-context [b]). We only need it for a [b] that types in the
   SAME context [G] (sequencing keeps the scope), so lift-then-type = type. *)
Lemma tseq_typed : forall S G a b Ta Tb,
  has_type S G a Ta ->
  has_type S G b Tb ->
  has_type S G (tseq a b) Tb.
Proof.
  intros S G a b Ta Tb Ha Hb. unfold tseq.
  eapply TLet; [ exact Ha | ].
  (* [lift 1 0 b] under [Ta :: G] : same as [b] under [G], by front-weakening. *)
  apply (weakening_cons S G b Tb Ta Hb).
Qed.

(* STEPPING the sequencing form: once [a] is a value, [tseq a b] steps to [b]
   (the binder is discarded by [subst_lift_cancel]). *)
Lemma tseq_step_value : forall a b st,
  value a -> step (tseq a b, st) (b, st).
Proof.
  intros a b st Hv. unfold tseq.
  replace b with (subst 0 a (lift 1 0 b)) at 2 by apply subst_lift_cancel.
  apply SLet; exact Hv.
Qed.

(* congruence: [tseq] steps its first component (it is a [tlet]). *)
Lemma tseq_step1 : forall a a' b st st',
  step (a, st) (a', st') -> step (tseq a b, st) (tseq a' b, st').
Proof. intros a a' b st st' H. unfold tseq. apply SLet1; exact H. Qed.

(* one unfold of [twhile]: it always steps (a [tfix]) to the conditional body
   with the self-reference substituted by the whole loop. *)
Lemma twhile_unfold : forall c body st,
  step (twhile c body, st)
       (tif (subst 0 (twhile c body) c)
            (tseq (subst 0 (twhile c body) body) (twhile c body))
            (tlit LNil), st).
Proof.
  intros c body st. unfold twhile at 1.
  (* SFix unfolds tfix T b to subst 0 (tfix T b) b *)
  pose proof (SFix Tunit (tif c (tseq body (tvar 0)) (tlit LNil)) st) as H.
  (* compute the substitution through tif/tseq; the self-ref [tvar 0] in the
     tseq's recursive tail becomes the whole loop. *)
  simpl in H.
  (* unfold [tseq] in H's RHS to align with the goal's [tseq]. *)
  unfold tseq in H. simpl in H.
  unfold twhile, tseq. exact H.
Qed.

(* TYPING [twhile]: if [c : Bool] and [body : Tunit] (a statement) under the self-
   ref binding [Tunit :: G], then [twhile c body : Tunit]. The loop result is the
   unit value (nil). *)
Lemma twhile_typed : forall S G c body,
  has_type S (Tunit :: G) c (BAtom ABool) ->
  has_type S (Tunit :: G) body Tunit ->
  has_type S G (twhile c body) Tunit.
Proof.
  intros S G c body Hc Hbody. unfold twhile. apply TFix.
  eapply TSub.
  - apply TIf with (T1 := Tunit) (T2 := Tunit).
    + exact Hc.
    + (* the body, sequenced with the self-ref recursive call [tvar 0 : Tunit] *)
      eapply tseq_typed; [ exact Hbody | apply TVar; reflexivity ].
    + (* the else-branch: the unit value *) apply (TLit S (Tunit :: G) LNil).
  - (* the if's declared type is [Tunit ∪ Tunit]; subsume to [Tunit]. *)
    apply RsSsub. apply SsUnionE; apply SsRefl.
Qed.

(* ===========================================================================
   EXAMPLE 6 — A REAL IMPERATIVE PROGRAM that TYPES: a counting / sum loop.

     local i = ref 0;
     local s = ref 0;
     while (!i < n) do  s := !s + !i;  i := !i + 1  end;
     !s

   Encoded with [talloc]/[tderef]/[tassign]/[tprim PLt]/[tprim PAdd] and the
   [twhile] encoding. De Bruijn (under the two outer [tlet]s, then under the fix
   self-ref binder inside [twhile]): the cell [s] is the closest local and [i] the
   next, both shifted up by one for the fix binder — so inside the loop body/cond,
   [s] = de Bruijn 1 and [i] = de Bruijn 2. This is the KEY correctness result:
   a real imperative Lua program typechecks (proved at [ANil] for the loop, [ANum]
   for the whole program via the final read).

   NUMBER TYPING NOTE. The cells are [BRef ANum], not [BRef AInt]: arithmetic
   ([tprim PAdd]) produces [ANum] (the declared arithmetic result type — see
   [TPrimArith]), and a mutable [BRef] cell is INVARIANT, so to store [!s + !i :
   ANum] back into the cell the cell must be a [Num] cell. The initial [LInt 0]
   (which types at [AInt]) widens to [ANum] by subsumption at allocation. This is
   exactly Lua's number model: there is one number type. *)
   (* =========================================================================== *)

(* the loop condition  [ !i < n ]  with [i] at de Bruijn 2 (under fix + 2 lets). *)
Definition sumloop_cond (n : nat) : tm :=
  tprim PLt (tderef (tvar 2)) (tlit (LInt n)).

(* the loop body  [ s := !s + !i ; i := !i + 1 ]  ([s]=dB1, [i]=dB2). *)
Definition sumloop_body : tm :=
  tseq
    (tassign (tvar 1) (tprim PAdd (tderef (tvar 1)) (tderef (tvar 2))))
    (tassign (tvar 2) (tprim PAdd (tderef (tvar 2)) (tlit (LInt 1)))).

(* the whole program (un-allocated): alloc i, alloc s, the while, then read s.
   Outside the fix the cells are [s]=dB0, [i]=dB1; the final [!s] reads dB1 (past
   the unit result of the while if we sequence it — here we sequence while ; !s). *)
Definition sumloop_prog (n : nat) : tm :=
  tlet (talloc (tlit (LInt 0)))           (* local i = ref 0   (i = dB0)        *)
    (tlet (talloc (tlit (LInt 0)))        (* local s = ref 0   (s = dB0, i=dB1) *)
      (tseq (twhile (sumloop_cond n) sumloop_body)   (* while ... end          *)
            (tderef (tvar 0)))).          (* !s  (s = dB0 here)                 *)

(* TYPING the loop alone (body + cond) in the context [Tunit (fix self-ref) ::
   BRef Num (s) :: BRef Num (i)]: it is a unit statement. The cells are reached by
   de Bruijn [tvar], so the store-typing [S] is irrelevant (left universally
   quantified) — no [TLoc] is used. *)
Lemma sumloop_loop_typed : forall S n,
  has_type S [ BRef (BAtom ANum) ; BRef (BAtom ANum) ]
    (twhile (sumloop_cond n) sumloop_body) Tunit.
Proof.
  intros S n. apply twhile_typed.
  - (* condition  !i < n : Bool. [i] = de Bruijn 2 under [Tunit :: BRef Num :: BRef Num]. *)
    unfold sumloop_cond. apply TPrimCmp; [ reflexivity | | ].
    + apply TDeref with (T := BAtom ANum). apply TVar. reflexivity.
    + eapply TSub; [ apply (TLit _ _ (LInt n)) | apply RsSsub; apply SsAtom; apply ALInt ].
  - (* body : two assignments sequenced, each a unit statement. *)
    unfold sumloop_body. eapply tseq_typed.
    + (* s := !s + !i  ([s]=dB1, [i]=dB2) : nil — the Num sum into the Num cell *)
      eapply TAssign with (T := BAtom ANum).
      * apply TVar. reflexivity.
      * apply TPrimArith; [ reflexivity | | ].
        -- apply TDeref with (T := BAtom ANum). apply TVar. reflexivity.
        -- apply TDeref with (T := BAtom ANum). apply TVar. reflexivity.
    + (* i := !i + 1  ([i]=dB2) : nil *)
      eapply TAssign with (T := BAtom ANum).
      * apply TVar. reflexivity.
      * apply TPrimArith; [ reflexivity | | ].
        -- apply TDeref with (T := BAtom ANum). apply TVar. reflexivity.
        -- eapply TSub; [ apply (TLit _ _ (LInt 1)) | apply RsSsub; apply SsAtom; apply ALInt ].
Qed.

(* THE KEY RESULT: the whole imperative program TYPES at [ANum]. (The body's
   arithmetic and assignments are all well typed; the while is a unit statement;
   the final [!s] reads the Num cell.) *)
Example sumloop_prog_typed : forall n,
  has_type [] [] (sumloop_prog n) (BAtom ANum).
Proof.
  intro n. unfold sumloop_prog.
  (* The cells are reached purely through de Bruijn VARIABLES ([tvar]), never
     through a [tloc] literal, so the store-typing [S] is never consulted and can
     stay [[]] for the WHOLE program: [TAlloc] produces [BRef Num] directly from
     the contained value's type, no [S] lookup. The initial [LInt 0 : AInt] widens
     to [ANum] at alloc (Lua's single number type). *)
  apply TLet with (A := BRef (BAtom ANum)).
  { apply TAlloc with (T := BAtom ANum).
    eapply TSub; [ apply (TLit [] [] (LInt 0)) | apply RsSsub; apply SsAtom; apply ALInt ]. }
  apply TLet with (A := BRef (BAtom ANum)).
  { apply TAlloc with (T := BAtom ANum).
    eapply TSub; [ apply (TLit [] _ (LInt 0)) | apply RsSsub; apply SsAtom; apply ALInt ]. }
  (* now in context [BRef Num (s, dB0) ; BRef Num (i, dB1)], type [while ; !s].
     [sumloop_loop_typed] needs store entries at 0,1 — but the loop reads its cells
     via [tvar] (de Bruijn), not [tloc], so those [S] hypotheses are vacuously
     dischargeable at any [S] with Num at 0,1; we instantiate at [[Num;Num]]. *)
  eapply tseq_typed.
  - (* the while loop, a unit statement (store-typing-agnostic: cells via tvar). *)
    apply sumloop_loop_typed.
  - (* the final read  !s  ([s] = de Bruijn 0) : Num. *)
    apply TDeref with (T := BAtom ANum). apply TVar. reflexivity.
Qed.

(* ===========================================================================
   EXAMPLE 7 — THE LOOP STEPS CORRECTLY (concrete small bound).

   We take a MINIMAL concrete instance and reduce it END-TO-END through the store:
   a single-cell counter loop  [ while (!i < 1) do i := !i + 1 end ]  with [i]
   starting at 0. The loop unfolds, the condition reads the CURRENT store (0 < 1 =
   true), the body MUTATES the cell (i ↦ 1), it re-unfolds, the condition is now
   false (1 < 1 = false), and the loop terminates with the unit value. This
   exhibits the load-bearing dynamics: store-dependent condition, mutating body,
   store-driven termination.

   (The full SUM loop [sumloop_prog] reduces by the SAME mechanism — alloc, unfold,
   store-read condition, mutate, re-unfold, terminate, final read — only with more
   iterations and a second cell; the typing of that full program is proved above
   in [sumloop_prog_typed]. We reduce the single-cell instance fully to keep the
   reduction trace machine-checked end-to-end and honest about depth.)
   =========================================================================== *)

(* the counter loop body  [ i := !i + 1 ]  with [i] at de Bruijn 0 (under just the
   fix self-ref binder, i.e. the cell is the only surrounding local — but here we
   keep [i] as a closed LOCATION [tloc 0] so the reduction is concrete in the
   store; the loop has no free locals, the self-ref is dB0). *)
Definition cinc_cond (n : nat) : tm := tprim PLt (tderef (tloc 0)) (tlit (LInt n)).
Definition cinc_body : tm :=
  tassign (tloc 0) (tprim PAdd (tderef (tloc 0)) (tlit (LInt 1))).
Definition cinc_loop (n : nat) : tm := twhile (cinc_cond n) cinc_body.

(* since [cinc_cond]/[cinc_body] are CLOSED (only [tloc 0], a value), the fix-
   unfold substitution leaves them unchanged. *)
Lemma cinc_cond_closed : forall n s, subst 0 s (cinc_cond n) = cinc_cond n.
Proof. intros n s. reflexivity. Qed.
Lemma cinc_body_closed : forall s, subst 0 s cinc_body = cinc_body.
Proof. intro s. reflexivity. Qed.

(* ONE FULL ITERATION, store-driven, machine-checked: from store [0], the loop
   unfolds, the condition [0 < 1] reads the store and is TRUE, the body runs and
   MUTATES the cell to [1], and control returns to the loop — leaving store [1].
   This is the increment's dynamic crux: a store-dependent condition gating a
   store-mutating body. *)
Lemma cinc_one_iter :
  multistep (cinc_loop 1, [tlit (LInt 0)])
            (cinc_loop 1, [tlit (LInt 1)]).
Proof.
  unfold cinc_loop.
  (* unfold the fixpoint *)
  eapply MSstep. { apply twhile_unfold. }
  rewrite cinc_cond_closed, cinc_body_closed.
  (* evaluate the condition  !(loc 0) < 1 : read the store -> 0 < 1 *)
  eapply MSstep. { apply SIf1. apply SPrim1. apply SDeref. }
  simpl.
  eapply MSstep. { apply SIf1. apply SPrimCmp. reflexivity. }
  (* 0 < 1 = true: select the then-branch (body ; loop) *)
  eapply MSstep. { apply SIfTrue. }
  (* run the body  loc0 := !loc0 + 1 : read 0, add 1, write 1 -> store [1] *)
  eapply MSstep. { apply tseq_step1. apply SAssign2; [ apply VLoc | apply SPrim1; apply SDeref ]. }
  simpl.
  eapply MSstep. { apply tseq_step1. apply SAssign2; [ apply VLoc | apply SPrimArith; reflexivity ]. }
  simpl.
  eapply MSstep. { apply tseq_step1. apply SAssign. apply VLit. }
  (* the body finished (nil); the sequence discards it and yields the loop. *)
  eapply MSstep. { apply tseq_step_value. apply VLit. }
  apply MSrefl.
Qed.

(* TERMINATION (concrete): after the mutating iteration, the SECOND unfold reads
   the NEW store [1], the condition [1 < 1] is FALSE, and the loop terminates with
   the unit value [nil]. Composed with [cinc_one_iter], the whole loop from store
   [0] runs to [nil] in store [1] — a real imperative loop computed to its end. *)
Lemma cinc_terminates :
  multistep (cinc_loop 1, [tlit (LInt 1)])
            (tlit LNil, [tlit (LInt 1)]).
Proof.
  unfold cinc_loop.
  eapply MSstep. { apply twhile_unfold. }
  rewrite cinc_cond_closed, cinc_body_closed.
  eapply MSstep. { apply SIf1. apply SPrim1. apply SDeref. }
  simpl.
  eapply MSstep. { apply SIf1. apply SPrimCmp. reflexivity. }
  (* 1 < 1 = false: select the else-branch (nil) — the loop ENDS. *)
  eapply MSstep. { apply SIfFalse. }
  apply MSrefl.
Qed.

(* THE WHOLE COUNTER LOOP, end-to-end: from store [0] it runs to the unit value in
   store [1] (one mutating iteration, then store-driven termination). *)
Example cinc_loop_runs :
  multistep (cinc_loop 1, [tlit (LInt 0)]) (tlit LNil, [tlit (LInt 1)]).
Proof.
  eapply multistep_trans; [ apply cinc_one_iter | apply cinc_terminates ].
Qed.

(* and the counter loop TYPES (a unit statement) under the store-typing [Num]
   (the cell is a Num cell — arithmetic result type, invariant cell). *)
Example cinc_loop_typed :
  has_type [ BAtom ANum ] [] (cinc_loop 1) Tunit.
Proof.
  unfold cinc_loop. apply twhile_typed.
  - unfold cinc_cond. apply TPrimCmp; [ reflexivity | | ].
    + apply TDeref with (T := BAtom ANum). apply TLoc. reflexivity.
    + eapply TSub; [ apply (TLit _ _ (LInt 1)) | apply RsSsub; apply SsAtom; apply ALInt ].
  - unfold cinc_body. eapply TAssign with (T := BAtom ANum).
    + apply TLoc. reflexivity.
    + apply TPrimArith; [ reflexivity | | ].
      * apply TDeref with (T := BAtom ANum). apply TLoc. reflexivity.
      * eapply TSub; [ apply (TLit _ _ (LInt 1)) | apply RsSsub; apply SsAtom; apply ALInt ].
Qed.

(* ===========================================================================
   EXAMPLE 8 — SEQUENCING WITH MUTATION:  [ (t.x := 9) ; t.x ]  reads 9.
   The [;] form (a [tseq]) runs the write for its effect, then reads the cell.
   =========================================================================== *)

Example seq_mutation_typed :
  has_type [ BAtom AInt ] []
    (tseq (tassign (tproj (mtable_val 0) "x"%string) (tlit (LInt 9)))
          (tderef (tproj (mtable_val 0) "x"%string)))
    (BAtom AInt).
Proof.
  eapply tseq_typed.
  - eapply TAssign; [ apply mtable_proj_x; reflexivity | apply TLit ].
  - apply TDeref. apply mtable_proj_x. reflexivity.
Qed.

Example seq_mutation_steps :
  multistep
    (tseq (tassign (tproj (mtable_val 0) "x"%string) (tlit (LInt 9)))
          (tderef (tproj (mtable_val 0) "x"%string)),
     [tlit (LInt 7)])
    (tlit (LInt 9), [tlit (LInt 9)]).
Proof.
  (* write: proj -> loc 0, assign 9 -> nil, store [7] -> [9] *)
  eapply MSstep. { apply tseq_step1. apply SAssign1. apply mtable_proj_x_steps. }
  eapply MSstep. { apply tseq_step1. apply SAssign. apply VLit. }
  (* the sequence discards the nil and runs the read (free vars preserved) *)
  eapply MSstep. { apply tseq_step_value. apply VLit. }
  (* read: proj -> loc 0, deref -> 9 *)
  eapply MSstep. { apply SDeref1. apply mtable_proj_x_steps. }
  eapply MSstep. { apply SDeref. }
  simpl. apply MSrefl.
Qed.

(* ===========================================================================
   EXAMPLE 9 — IF-STATEMENT WITH MUTATION:
     [ if cond then (r := 1) else (r := 2) end ; !r ]  reads the taken branch.
   Encoded with [tif] (the if-statement) + [tseq] + the reference [r] = [tloc 0].
   =========================================================================== *)

(* the program, parameterized by the boolean condition value. *)
Definition if_mut_prog (b : bool) : tm :=
  tseq
    (tif (tlit (LBool b))
         (tassign (tloc 0) (tlit (LInt 1)))
         (tassign (tloc 0) (tlit (LInt 2))))
    (tderef (tloc 0)).

Example if_mut_typed : forall b,
  has_type [ BAtom AInt ] [] (if_mut_prog b) (BAtom AInt).
Proof.
  intro b. unfold if_mut_prog. eapply tseq_typed.
  - (* the if-statement: both branches are unit assignments. *)
    eapply TSub.
    + apply TIf with (T1 := BAtom ANil) (T2 := BAtom ANil).
      * apply TLit.
      * eapply TAssign with (T := BAtom AInt); [ apply TLoc; reflexivity | apply TLit ].
      * eapply TAssign with (T := BAtom AInt); [ apply TLoc; reflexivity | apply TLit ].
    + apply RsSsub. apply SsUnionE; apply SsRefl.
  - (* the read  !r : Int *)
    apply TDeref with (T := BAtom AInt). apply TLoc. reflexivity.
Qed.

(* TRUE branch taken: [r := 1] then [!r] reads 1, store [0] -> [1]. *)
Example if_mut_true_steps :
  multistep (if_mut_prog true, [tlit (LInt 0)]) (tlit (LInt 1), [tlit (LInt 1)]).
Proof.
  unfold if_mut_prog.
  eapply MSstep. { apply tseq_step1. apply SIfTrue. }
  eapply MSstep. { apply tseq_step1. apply SAssign. apply VLit. }
  eapply MSstep. { apply tseq_step_value. apply VLit. }
  eapply MSstep. { apply SDeref. }
  simpl. apply MSrefl.
Qed.

(* FALSE branch taken: [r := 2] then [!r] reads 2, store [0] -> [2]. *)
Example if_mut_false_steps :
  multistep (if_mut_prog false, [tlit (LInt 0)]) (tlit (LInt 2), [tlit (LInt 2)]).
Proof.
  unfold if_mut_prog.
  eapply MSstep. { apply tseq_step1. apply SIfFalse. }
  eapply MSstep. { apply tseq_step1. apply SAssign. apply VLit. }
  eapply MSstep. { apply tseq_step_value. apply VLit. }
  eapply MSstep. { apply SDeref. }
  simpl. apply MSrefl.
Qed.

(* ===========================================================================
   EXAMPLE 10 — DIVERGENCE TOLERANCE: [while true do () end] is WELL-TYPED and
   DIVERGES (steps forever, never stuck). Type soundness TOLERATES non-termination
   — progress + preservation hold for [tfix], so a divergent loop is SOUND (it is
   always able to step; it is never a stuck non-value). The loop body here is the
   unit statement [()] = [tlit LNil] (de Bruijn 0 unused under the fix binder, so
   it is closed). We show: (1) it TYPES at [Tunit]; (2) from ANY store it steps
   back to itself in a fixed number of steps (a non-terminating reduction cycle).
   =========================================================================== *)

(* [while true do () end] — condition is the literal [true], body the unit value. *)
Definition while_true : tm := twhile (tlit (LBool true)) (tlit LNil).

Example while_true_typed :
  has_type [] [] while_true Tunit.
Proof.
  unfold while_true. apply twhile_typed.
  - apply (TLit [] [Tunit] (LBool true)).
  - apply (TLit [] [Tunit] LNil).
Qed.

(* DIVERGENCE: one full cycle returns the loop to ITSELF (same config), so it
   never reaches a value — it steps forever. Witnessed as a multistep loop -> loop.
   The cycle: unfold, condition is the literal [true] (no store read needed),
   select then-branch, run the unit body, the sequence yields the loop again. *)
Example while_true_diverges : forall st,
  multistep (while_true, st) (while_true, st) /\ while_true <> tlit LNil.
Proof.
  intro st. split.
  - unfold while_true.
    eapply MSstep. { apply twhile_unfold. }
    simpl.
    (* condition is the literal true; select the then-branch *)
    eapply MSstep. { apply SIfTrue. }
    (* body is the unit value already; the sequence discards it, yields the loop *)
    eapply MSstep. { apply tseq_step_value. apply VLit. }
    apply MSrefl.
  - discriminate.
Qed.

(* and a DIRECT progress witness: the loop is NOT a value, yet it CAN step (it is
   never stuck) — exactly what divergence-tolerant soundness guarantees. *)
Example while_true_not_stuck :
  ~ value while_true /\ exists e' st', step (while_true, []) (e', st').
Proof.
  split.
  - intro Hv. unfold while_true, twhile in Hv. inversion Hv.
  - eexists. eexists. apply twhile_unfold.
Qed.

(* ===========================================================================
   ASSUMPTION AUDIT — closed under the global context.
   =========================================================================== *)
Print Assumptions progress.
Print Assumptions preservation.
Print Assumptions ex_add_typed.
Print Assumptions ex_add_steps.
Print Assumptions ex_lt_typed.
Print Assumptions ex_lt_steps.
Print Assumptions ex_chain_steps.
Print Assumptions ex_bad_add_untyped.
Print Assumptions truthy_narrows.
Print Assumptions falsy_narrows.
Print Assumptions tag_narrows.
Print Assumptions rsub_sound.
Print Assumptions payoff_types_WITH_narrowing.
Print Assumptions payoff_rejected_WITHOUT_narrowing.
Print Assumptions tt_payoff_types_WITH_narrowing.
Print Assumptions loc_narrows_to_truthy.
Print Assumptions deref_proj_typed.
Print Assumptions rec_over_ref_typed.
Print Assumptions ill_typed_assign_rejected.
Print Assumptions arrow_top_collapse.
(* M4 — mutable tables + reassignable locals (records-of-refs encoding). *)
Print Assumptions mutation_typed.
Print Assumptions mutation_steps.
Print Assumptions aliasing_typed.
Print Assumptions aliasing_steps.
Print Assumptions field_invariance_rejected.
Print Assumptions field_invariance_accepted.
Print Assumptions field_cell_invariant.
Print Assumptions covariant_structure_composes.
Print Assumptions covariant_field_still_invariant.
Print Assumptions reassign_local_typed.
Print Assumptions reassign_local_steps.
(* INCREMENT 20 — imperative statements + the real while-loop (encoded). *)
Print Assumptions subst_lift_cancel.
Print Assumptions tseq_typed.
Print Assumptions tseq_step_value.
Print Assumptions twhile_unfold.
Print Assumptions twhile_typed.
Print Assumptions sumloop_prog_typed.
Print Assumptions sumloop_loop_typed.
Print Assumptions cinc_one_iter.
Print Assumptions cinc_terminates.
Print Assumptions cinc_loop_runs.
Print Assumptions cinc_loop_typed.
Print Assumptions seq_mutation_typed.
Print Assumptions seq_mutation_steps.
Print Assumptions if_mut_typed.
Print Assumptions if_mut_true_steps.
Print Assumptions if_mut_false_steps.
Print Assumptions while_true_typed.
Print Assumptions while_true_diverges.
Print Assumptions while_true_not_stuck.
