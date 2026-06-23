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
  | TgRef   : tag            (* a reference/location  *)
  (* MULTI-RETURN — the runtime tag of a value-SEQUENCE (multivalue). Lua's
     [type()] is never actually applied to a raw multivalue (multivalues are
     contextually adjusted away first), but our calculus makes [tret] a value, so
     totality of [value_has_some_tag] needs it a tag. A multivalue's tag pins only
     [BTop] (see [tag_type]) — the SOUND over-approximation: a tag-tested multivalue
     narrows to "some value" with no further commitment. *)
  | TgMulti : tag.           (* a value-sequence (multivalue) *)

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
  | PLt  | PLe  | PEq              (* comparison — result ABool *)
  (* METATABLE OPERATOR — CONCATENATION ([..], metamethod [__concat]). [PConcat]
     is a binary operator carried by [tprim], BUT it has NO built-in numeric path:
     [arith_op PConcat = false] and [cmp_op PConcat = false], so [SPrimArith] /
     [SPrimCmp] never fire on it. Its ONLY typing rule is the metamethod dispatch
     ([TPrimMetaL]/[SPrimMetaL] via [mm_binop PConcat = "__concat"]) — i.e. [..] is
     a PURE operator-metamethod here (plain-string concatenation is a separate,
     DEFERRED concern; the value model has no string-content concatenation). This
     reuses the existing binary-operator metamethod machinery with no new term
     form: it is exactly the "more metamethods extend the existing [mm_binop]
     records-of-refs encoding" increment. *)
  | PConcat.                       (* concatenation [..] — metamethod-only (__concat) *)

(* METATABLE UNARY OPERATOR tags. [UNeg] is unary minus ([-x], metamethod [__unm]);
   [ULen] is the length operator ([#x], metamethod [__len]). Like [PConcat] these
   are METAMETHOD-ONLY here (the value model has no built-in numeric negation /
   length to fall back on — that is a separate, DEFERRED concern); their sole
   typing/step rules are the unary metamethod dispatch ([TUnMetaL]/[SUnMetaL] via
   [mm_unop]). Faithful Lua semantics: a unary metamethod is invoked with the
   operand passed TWICE ([__unm(x, x)] / [__len(x, x)]), modelled as a curried
   [Self -> Self -> R] applied to the operand and then to itself — exactly mirroring
   the binary [Self -> Other -> R] dispatch, so the SAME arrow + [__index]-chain
   machinery is reused with no new lookup mechanism. *)
Inductive unop : Type :=
  | UNeg     (* unary minus [-x] — metamethod __unm *)
  | ULen.    (* length [#x]      — metamethod __len *)

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
  | tloc    : nat -> tm                      (* a store address (a VALUE)       *)
  (* TYPE ANNOTATION / ASCRIPTION. [tannot T e] ascribes [e] to type [T]: it is
     the general mechanism for GUIDING INFERENCE where [synth] is incomplete. It
     drives the bidirectional checker into CHECK mode — [synth (tannot T e)] CHECKS
     [e] against [T] (rather than synthesizing [e]) and returns [T]. This is the
     building block for surface [local x : T = e] and function param/return type
     annotations. Operationally an annotation is RUNTIME-ERASED (it strips on a
     value, [SAnnotV]; congruence under it, [SAnnot1]); [tannot T e] is NOT itself a
     value. Declaratively [tannot T e : T] when [e : T] (with subsumption, [e] at a
     subtype of [T] also works — [TAnnot]). *)
  | tannot  : BTy -> tm -> tm                (* ascription  (e : T)             *)
  (* MULTI-RETURN VALUES — Lua's distinctive feature: a function returns a
     SEQUENCE of values, adjusted by the SYNTACTIC CONTEXT of the call.

     [tret es] is the RETURN-SEQUENCE form: [return e1,…,ek]. It evaluates its
     components left-to-right; when all are values it IS the multivalue VALUE [tret
     vs] (modelled at the value level by [VTup vs]). Its declarative type is the
     TUPLE type [BTuple [T1;…;Tk]].

     The CONTEXTUAL ADJUSTMENT (the crux, Lua-faithful) is realized by two
     adjuster forms, so the SAME multivalue is adjusted differently per position:

     - [tfst e] — TRUNCATION (the "most positions" adjustment): take the FIRST
       value of the multivalue [e] (or [nil] if empty). This is what [local x =
       f()] does (bind the first), what an operand position [f() + 1] does, and
       what a non-last call argument does. Typing: a multivalue [: BTuple (T::Ts)]
       truncates to its head type [T] (empty tuple ↦ [nil]).

     - [tappspread g e] — LAST-POSITION SPREAD: [g(f())] with [f()] in the LAST
       argument position SPREADS all of [f()]'s values into [g]. The known-arity
       consumer [g] takes the whole sequence ([g : BTuple Ts -> B]); the spread
       delivers the entire multivalue [e : BTuple Ts], yielding [B]. (Single-arg
       lambdas + a tuple-typed parameter is the faithful known-arity model;
       arity-polymorphic spread is DEFERRED.)

     DEFERRED (backlog): vararg [...] (the function-side variadic), table-collect
     [{f()}], multiple-assignment [a,b = f()], and full arity-polymorphic spread. *)
  | tret       : list tm -> tm               (* return e1,…,ek  (multivalue)    *)
  | tfst       : tm -> tm                     (* truncate a multivalue to its 1st *)
  | tappspread : tm -> tm -> tm              (* g(f()) — last-position spread    *)
  (* METATABLES — STATIC, READ-ONLY [__index] FIELD-LOOKUP FALLBACK (prototype
     inheritance / OOP). [tmeta own proto] is a table whose OWN fields are the
     record [own] and whose metatable's [__index] target is [proto] (itself a
     record or another [tmeta] — a prototype CHAIN). Field access [tproj (tmeta
     own proto) k] resolves: if [k] is a DIRECT (own) field, use it; ELSE fall
     back to [proto.k] (and recursively through [proto]'s own [__index] chain) —
     this is the dynamic DISPATCH, realized by the op-sem [SMetaProjOwn] /
     [SMetaProjProto] below. TYPING flattens the read interface: a [tmeta] of own
     fields [Town] over a prototype of read-type [BRec Pfields] has type [BRec
     (merge_fields Town Pfields)] — own fields PLUS inherited fields not shadowed
     by own (Lua: own wins). So an inherited method's type is visible at the
     derived table, and an absent-everywhere field is a type error the checker
     rejects. DEFERRED (backlog): operator/[__eq]/[__lt]/[__call] metamethods,
     [__newindex] (write fallback), dynamic metatable MUTATION, [rawget]/[rawset],
     and [__index] as a FUNCTION (here [__index] is a table/record only). The OWN
     fields are a record-literal field-list directly (not an arbitrary term): an
     object's own field table is concrete, and this pins the OWN type to exactly
     its keys — see [TMeta]'s soundness note for why a subsumed own term would
     break preservation. *)
  | tmeta      : list (string * tm) -> tm -> tm   (* tmeta own_fields proto *)
  (* METATABLE METAMETHOD — [__newindex] WRITE FALLBACK. [tnewidx tbl k v] is the
     field-write [tbl.k = v]. When [tbl] is a metatable-table [tmeta own ni] and [k]
     is ABSENT from [own], it dispatches to the metatable's [__newindex] TABLE [ni]:
     the write goes through to [ni]'s cell for [k] (the records-of-refs encoding — a
     writable field is a mutable [BRef] cell). This mirrors the [__index] read
     fallback on the assignment side. NOT a value (a write computes to [nil]).
     DEFERRED: own-present rawset (own is an immutable literal here), [__newindex]
     as a FUNCTION, dynamic metatable mutation. *)
  | tnewidx    : list (string * tm) -> tm -> string -> tm -> tm
       (* tnewidx own proto k v : the write [(tmeta own proto).k = v]. The table is
          given by its OWN field-list + [__newindex] target [proto] DIRECTLY (not a
          nested [tmeta] subterm), so the own fields are typed EXACTLY by
          [has_fields] — the same exactness discipline as [TMeta] (a subsumed table
          would let [Town] under-report own's keys and mis-route the dispatch). *)
  (* METATABLE UNARY METAMETHOD — [tunop uop e] is the unary operator [-e] / [#e]
     ([uop ∈ {UNeg, ULen}]). When [e] is a metatable-table [tmeta own proto] whose
     read interface carries the unary metamethod [mm_unop uop : Self -> Self -> R],
     it dispatches to [(e.<mm>) e e] (the operand passed twice, Lua-faithful). Reuses
     the [__index] chain + curried arrow application — no new lookup machinery, the
     unary analogue of [tprim]'s [TPrimMetaL]/[SPrimMetaL]. NOT a value (it computes).
     DEFERRED: built-in numeric negation / table length (metamethod-only here). *)
  | tunop      : unop -> tm -> tm             (* tunop uop e : unary [-e] / [#e] *)
  (* RAW TABLE ACCESS — [rawget]/[rawset]. These BYPASS the metatable
     [__index]/[__newindex] fallback: they reduce DIRECTLY to the underlying
     record-of-refs read/write on the table's OWN fields, WITHOUT ever consulting
     the prototype. The DISTINGUISHING property versus [tproj]/[tnewidx] on a
     [tmeta]: a key present in the PROTOTYPE but ABSENT from OWN is resolved by the
     ordinary [tproj] ([SMetaProjProto]) yet is NOT reachable by [trawget] (raw
     access never falls through) — machine-checked in the payoff lemmas.

     The table is given DIRECTLY by its OWN field-list [own] + [__index]/[__newindex]
     prototype-position target [proto] (NOT a nested [tmeta] subterm), exactly as
     [tnewidx] takes its operands — so the own fields are typed EXACTLY by
     [has_fields] (the same exactness discipline as [TMeta]/[TNewIdx]; a subsumed
     own table would let the own type under-report own's keys).

     [trawget own proto k] = [rawget((tmeta own proto), k)]: the RAW read of own
     field [k]. It REUSES the own-field primitive [field_lookup k own] — literally
     the [SMetaProjOwn] own arm WITHOUT the [SMetaProjProto] fallback. Typing: an
     own key [(k, T) ∈ Town] gives result [T]. (A key absent from own is a type
     error the checker rejects — Lua's runtime [nil] for an absent raw key is NOT
     modelled here, mirroring the static fragment's [TProj] which also requires the
     key present; that is recorded as deferred, not faked.)

     [trawset own proto k v] = [rawset((tmeta own proto), k, v)]: the RAW write of
     own field [k]. Like [tnewidx] it goes through the records-of-refs write — but
     to OWN's cell, never the prototype's. The own field for [k] is a mutable
     [BRef T] cell ([(k, BRef T) ∈ Town]); the write reduces to [tassign (own's
     cell for k) v] and assigns a [v : T] into it, yielding [nil]. This is exactly
     [TNewIdx]'s write side with the cell read from OWN ([field_lookup k own])
     instead of the prototype, and WITHOUT the absent-from-own dispatch. Neither
     form is a value (both compute). DEFERRED: raw access on a key absent from own
     returning [nil] (needs the static fragment to model absent-key reads). *)
  | trawget    : list (string * tm) -> tm -> string -> tm
       (* trawget own proto k : [rawget((tmeta own proto), k)] — raw own read *)
  | trawset    : list (string * tm) -> tm -> string -> tm -> tm
       (* trawset own proto k v : [rawset((tmeta own proto), k, v)] — raw own write *)
  (* VARARG [...] — the FUNCTION-SIDE variadic, the PARAMETER-side mirror of
     multi-return. A variadic function [function(x, ...) body end] binds, in
     ADDITION to its fixed parameter [x], the TRAILING actual arguments as a
     single MULTIVALUE — the rest — which behaves EXACTLY like a multi-return
     result: TRUNCATED to one value in expression position ([tfst]) and SPREAD in
     last position ([tappspread]). So the rest is just a [BTuple]-typed binding and
     [...] inside the body is the de Bruijn reference to it; the existing
     [tret]/[tfst]/[tappspread] substrate carries truncation and spread — they are
     NOT duplicated here.
     The one genuinely NEW piece is PACKING: at a variadic CALL the trailing
     actuals beyond the fixed parameter are collected INTO the rest multivalue.
     [tvapp f a rs] is that call: variadic function [f], fixed argument [a], and
     the trailing-argument list [rs]. A variadic function is modelled by its
     two-binder curried shape [tlam T (tlam (BTuple Ts) body)] — fixed param at de
     Bruijn index 1, the rest [...] at index 0 — so [tvapp] reuses [tapp]/[tret]:
     it PACKS [rs] into [tret rs] and applies [f] to [a] and then to that packed
     rest (see [SVApp]). No new arrow type, no new binder kind — the rest type is
     the EXISTING [BTuple Ts]; index signatures are NOT involved (deferred
     substrate, and orthogonal). *)
  | tvapp      : tm -> tm -> list tm -> tm
       (* tvapp f a rs : variadic call — f's fixed arg a, trailing args rs packed *)
  (* MULTIPLE-ASSIGNMENT [a, b, ... = e1, e2, ...] — the LHS-side CONSUMER of the
     SAME multi-value substrate that multi-return and vararg PRODUCE. [tmassign rs
     rhs]: [rs] is the list of N TARGET reference expressions (each a [tloc] / [BRef
     T] cell, exactly the reassignable-local machinery), and [rhs] is the RHS PACKED
     as a single MULTIVALUE ([tret …] / any [BTuple]-typed term — e.g. a call's
     result). Multiple-assignment is the GENERALIZATION of the multi-return
     adjustments: the RHS multivalue is adjusted to EXACTLY the LHS arity N. Lua 5.1
     semantics: extra RHS values are DROPPED (truncation — the [tfst] direction) and
     MISSING RHS values are PADDED WITH NIL ([= nil], the adjust-UP direction that
     truncation alone does not cover). BOTH directions are the SAME pure normalizer
     [pad_tm] / [pad_ty] (truncate-or-pad-with-[nil] to length N) — no new substrate,
     no new subtyping, no index signatures: padding is just [tlit LNil : BAtom ANil].
     The last-position spread [a, b = f()] needs nothing new: the RHS is whatever
     [f()] evaluates to — a [tret] multivalue — so it is already covered by packing
     the RHS as one [BTuple]-typed term. Evaluation order: ALL targets and the RHS
     are evaluated to values (left-to-right via congruences), THEN every assignment
     is performed at once ([SMAssign]) — faithful to Lua's "compute everything, then
     assign". Each adjusted value is written via the EXISTING store-update used by
     [tassign]; the whole form yields the unit value [nil]. *)
  | tmassign   : list tm -> tm -> tm.
       (* tmassign rs rhs : a,b,…(N targets) = rhs (packed multivalue) *)

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
  (* MULTI-RETURN — a tag-tested multivalue narrows only to [BTop] (every value
     inhabits [BTop] by subsumption, so [tag_narrows] stays sound). *)
  | TgMulti => BTop
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

(* ===========================================================================
   METATABLE METAMETHOD NAMES — the metamethod-name TABLE. This is ORDINARY DATA
   (a map from the syntactic construct to the reserved field key), NOT name-keyed
   special-casing in the gen-pass/solver: dispatch is a GENERAL field-lookup of
   the metamethod key in the table's OWN fields, and the key is selected by this
   pure function. The construct (a [primop], or the literal [__call]/[__newindex]
   forms) determines the key; the dispatch machinery is uniform across keys.

   [mm_call] / [mm_newindex] are the [__call] / [__newindex] metamethod keys;
   [mm_arith] / [mm_cmp] map each arithmetic / comparison [primop] to its operator
   metamethod key ([__add]/[__sub]/[__mul] and [__eq]/[__lt]/[__le]). Lua's actual
   names — the protocol the runtime uses. *)
Definition mm_call     : string := "__call".
Definition mm_newindex : string := "__newindex".

(* the binary-operator metamethod key for a primop (the Lua name). Arithmetic and
   comparison both flow through one lookup; the name is the only op-specific datum. *)
Definition mm_binop (op : primop) : string :=
  match op with
  | PAdd => "__add"
  | PSub => "__sub"
  | PMul => "__mul"
  | PDiv => "__div"
  | PLt  => "__lt"
  | PLe  => "__le"
  | PEq  => "__eq"
  | PConcat => "__concat"
  end.

(* the unary-operator metamethod key for a [unop] (the Lua name). One general lookup
   through the [__index] chain, the name is the only op-specific datum (ordinary
   data, NOT name-keyed special-casing — the dispatch machinery is uniform). *)
Definition mm_unop (uop : unop) : string :=
  match uop with
  | UNeg => "__unm"
  | ULen => "__len"
  end.

(* MULTIPLE-ASSIGNMENT — the ARITY NORMALIZER (the SAME adjustment in both
   directions). [pad_tm vs n] adjusts a value/term list to EXACTLY length [n]:
   it TRUNCATES when [vs] is longer (Lua DROPS the extra RHS values — the [tfst]
   direction) and PADS with [tlit LNil] when [vs] is shorter (Lua fills missing
   targets with [nil] — the adjust-UP direction). [pad_ty] is the TYPE-level mirror,
   padding with [BAtom ANil] — so [pad_ty] commutes with [pad_tm] under typing
   ([has_types vs Ss ⇒ has_types (pad_tm vs n) (pad_ty Ss n)], proved below). No new
   substrate: the pad value is just [nil]. *)
Fixpoint pad_tm (vs : list tm) (n : nat) : list tm :=
  match n with
  | 0 => []
  | S k => match vs with
           | [] => tlit LNil :: pad_tm [] k
           | v :: rest => v :: pad_tm rest k
           end
  end.

Fixpoint pad_ty (Ts : list BTy) (n : nat) : list BTy :=
  match n with
  | 0 => []
  | S k => match Ts with
           | [] => BAtom ANil :: pad_ty [] k
           | T :: rest => T :: pad_ty rest k
           end
  end.


(* ---- A usable induction principle: the auto-generated [tm_ind] gives no IH
   for the subterms inside a [trec] list. Hand-roll the nested scheme (a plain
   Fixpoint, no axiom), mirroring [V_rect_strong] in subtype.v. *)
Section tm_ind_strong.
  Variable P  : tm -> Prop.
  Variable Pl : list (string * tm) -> Prop.
  Variable Pt : list tm -> Prop.        (* for the [tret] component list *)
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
  Hypothesis Hannot  : forall T e, P e -> P (tannot T e).
  Hypothesis Hret    : forall es, Pt es -> P (tret es).
  Hypothesis Hfst    : forall e, P e -> P (tfst e).
  Hypothesis Hspread : forall g a, P g -> P a -> P (tappspread g a).
  Hypothesis Hmeta   : forall own proto, Pl own -> P proto -> P (tmeta own proto).
  Hypothesis Hnewidx : forall own proto k v, Pl own -> P proto -> P v ->
                       P (tnewidx own proto k v).
  Hypothesis Hunop   : forall uop e, P e -> P (tunop uop e).
  Hypothesis Hrawget : forall own proto k, Pl own -> P proto -> P (trawget own proto k).
  Hypothesis Hrawset : forall own proto k v, Pl own -> P proto -> P v ->
                       P (trawset own proto k v).
  (* VARARG — the trailing-argument list uses the SAME [Pt] IH as [tret]'s
     component list (both are positional term sequences). *)
  Hypothesis Hvapp   : forall f a rs, P f -> P a -> Pt rs -> P (tvapp f a rs).
  (* MULTIPLE-ASSIGNMENT — the target list uses the SAME [Pt] IH (a positional term
     sequence, exactly like [tret]'s components); the RHS uses [P]. *)
  Hypothesis Hmassign : forall rs rhs, Pt rs -> P rhs -> P (tmassign rs rhs).
  Hypothesis Hnil  : Pl [].
  Hypothesis Hcons : forall k e rest, P e -> Pl rest -> Pl ((k, e) :: rest).
  Hypothesis Htnil : Pt [].
  Hypothesis Htcons : forall e rest, P e -> Pt rest -> Pt (e :: rest).
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
    | tannot T e => Hannot T e (tm_rect_strong e)
    | tret es =>
        Hret es
          ((fix got (es : list tm) : Pt es :=
              match es with
              | [] => Htnil
              | e :: rest => Htcons e rest (tm_rect_strong e) (got rest)
              end) es)
    | tfst e => Hfst e (tm_rect_strong e)
    | tappspread g a => Hspread g a (tm_rect_strong g) (tm_rect_strong a)
    | tmeta own proto =>
        Hmeta own proto
          ((fix gom (fs : list (string * tm)) : Pl fs :=
              match fs with
              | [] => Hnil
              | (k, e) :: rest => Hcons k e rest (tm_rect_strong e) (gom rest)
              end) own)
          (tm_rect_strong proto)
    | tnewidx own proto k v =>
        Hnewidx own proto k v
          ((fix goni (fs : list (string * tm)) : Pl fs :=
              match fs with
              | [] => Hnil
              | (k0, e) :: rest => Hcons k0 e rest (tm_rect_strong e) (goni rest)
              end) own)
          (tm_rect_strong proto) (tm_rect_strong v)
    | tunop uop e => Hunop uop e (tm_rect_strong e)
    | trawget own proto k =>
        Hrawget own proto k
          ((fix gorg (fs : list (string * tm)) : Pl fs :=
              match fs with
              | [] => Hnil
              | (k0, e) :: rest => Hcons k0 e rest (tm_rect_strong e) (gorg rest)
              end) own)
          (tm_rect_strong proto)
    | trawset own proto k v =>
        Hrawset own proto k v
          ((fix gors (fs : list (string * tm)) : Pl fs :=
              match fs with
              | [] => Hnil
              | (k0, e) :: rest => Hcons k0 e rest (tm_rect_strong e) (gors rest)
              end) own)
          (tm_rect_strong proto) (tm_rect_strong v)
    | tvapp f a rs =>
        Hvapp f a rs (tm_rect_strong f) (tm_rect_strong a)
          ((fix gova (rs : list tm) : Pt rs :=
              match rs with
              | [] => Htnil
              | e :: rest => Htcons e rest (tm_rect_strong e) (gova rest)
              end) rs)
    | tmassign rs rhs =>
        Hmassign rs rhs
          ((fix goma (rs : list tm) : Pt rs :=
              match rs with
              | [] => Htnil
              | e :: rest => Htcons e rest (tm_rect_strong e) (goma rest)
              end) rs)
          (tm_rect_strong rhs)
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
      destruct v as [r| | | | | | |]; try contradiction; try destruct r;
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

(* ---- METATABLES — the FLATTENED read interface ----------------------------
   [merge_fields own proto] is the type-level [__index] flatten: own fields are
   kept, and prototype fields whose key is NOT shadowed by an own key are
   appended. Lua's resolution order — OWN field wins over inherited — is exactly
   this: a key present in [own] takes [own]'s type, otherwise [proto]'s. The
   result is the visible READ interface of [tmeta own proto] (the inherited
   methods become directly projectable, at their prototype types). *)

Fixpoint key_in (k : string) (fs : list (string * BTy)) : bool :=
  match fs with
  | [] => false
  | (k', _) :: rest => if string_dec k k' then true else key_in k rest
  end.

(* prototype fields not shadowed by an own key. *)
Fixpoint drop_shadowed (own proto : list (string * BTy)) : list (string * BTy) :=
  match proto with
  | [] => []
  | (k, T) :: rest =>
      if key_in k own then drop_shadowed own rest
      else (k, T) :: drop_shadowed own rest
  end.

Definition merge_fields (own proto : list (string * BTy)) : list (string * BTy) :=
  own ++ drop_shadowed own proto.

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
  (* TYPE ASCRIPTION. [tannot T e] has type [T] when [e] has type [T]. Combined
     with subsumption [TSub], an [e] at a SUBTYPE of [T] also ascribes to [T]
     (synthesize [e]'s least type, subsume to [T], then ascribe). The annotation
     is the inference-guiding seam: it is the declarative counterpart of the
     checker's CHECK-mode switch (see [synth (tannot T e)] in check.v). *)
  | TAnnot : forall S G e T,
      has_type S G e T ->
      has_type S G (tannot T e) T
  (* MULTI-RETURN — the return-sequence has the TUPLE type of its components'
     types (positional). [has_types] (mutual, below) types the component list
     pointwise into a type list [Ts]; then [tret es : BTuple Ts]. *)
  | TRet  : forall S G es Ts,
      has_types S G es Ts ->
      has_type S G (tret es) (BTuple Ts)
  (* MULTI-RETURN — TRUNCATION (the "most positions" contextual adjustment). A
     multivalue typed [BTuple (T::Ts)] truncates to its FIRST value, of type [T].
     This is what binds the first return in [local x = f()], what an operand
     position uses, and what a non-last call argument passes. The NON-empty case
     ([T::Ts]) gives the head type; the EMPTY multivalue [BTuple []] truncates to
     [nil] ([TFstNil]) — Lua's "no values ⇒ nil". *)
  | TFst  : forall S G e T Ts,
      has_type S G e (BTuple (T :: Ts)) ->
      has_type S G (tfst e) T
  | TFstNil : forall S G e,
      has_type S G e (BTuple []) ->
      has_type S G (tfst e) (BAtom ANil)
  (* MULTI-RETURN — LAST-POSITION SPREAD. [g(f())] with [f()] last SPREADS all of
     [f()]'s values into [g]. The known-arity consumer [g] takes the whole
     sequence ([g : BTuple Ts -> B]); the spread delivers the entire multivalue
     ([a : BTuple Ts]); the result is [B]. (Arity-polymorphic spread is DEFERRED;
     here the consumer's parameter type pins the arity — the faithful known-arity
     case.) *)
  | TAppSpread : forall S G g a Ts B,
      has_type S G g (BArrow (BTuple Ts) B) ->
      has_type S G a (BTuple Ts) ->
      has_type S G (tappspread g a) B
  (* METATABLES — STATIC, READ-ONLY [__index] field-lookup fallback. [own] is the
     OWN-field record [BRec Town]; [proto] is the [__index] target, whose
     (flattened) READ type is the record [BRec Pfields]. The metatable-table
     [tmeta own proto] has the MERGED read type [BRec (merge_fields Town Pfields)]
     — own fields plus inherited (prototype) fields not shadowed by own. The
     [NoDup] premises on BOTH field lists make the merge [NoDup] (own keys
     distinct, surviving prototype keys distinct and disjoint from own — proved
     [merge_fields_nodup]), so projection's first-match agrees with the key's type
     exactly. Inheritance is thus a structural extension: an inherited method is
     directly projectable at the derived table (its prototype type), realizing
     real Lua OOP. (A prototype CHAIN is the case where [proto] is itself a
     [tmeta]: its flattened type is again a [BRec], so chaining composes.) *)
  | TMeta : forall S G ofs proto Town Pfields,
      (* OWN fields are a record-literal field-list typed EXACTLY by [has_fields]
         (NOT an arbitrary subsumed term): [Town] then faithfully lists own's
         runtime keys, so the merge resolves an own key to OWN's type and a
         non-own key to the prototype's — matching the runtime dispatch. Allowing
         [own] to be a width-SUBSUMED term would let [Town] under-report own's
         keys; a key present in own's runtime record but dropped from [Town] would
         be typed via the PROTOTYPE while dispatched to OWN — UNSOUND. Pinning own
         to its literal field-list (an object's own field table is concrete)
         closes this. The PROTOTYPE keeps arbitrary subsumption (read at [BRec]). *)
      has_fields S G ofs Town ->
      NoDup (map fst Town) ->
      has_type S G proto (BRec Pfields) ->
      NoDup (map fst Pfields) ->
      has_type S G (tmeta ofs proto) (BRec (merge_fields Town Pfields))
  (* METATABLE METAMETHOD — [__call] (callable tables). A metatable-table
     [tmeta ofs proto] whose READ INTERFACE [BRec M] (its merged own+inherited type)
     carries a [__call] metamethod [Self -> Arg -> R] is APPLICABLE:
     [tapp (tmeta ofs proto) arg] dispatches to [(table.__call) table arg] — the
     table is passed as [self], then the argument (Lua [t(x)] = [__call(t, x)]). The
     metamethod is CURRIED ([Self -> Arg -> R]) so the single-arg arrow machinery is
     reused; the table's record type must be a valid [self] ([rsub] the [Self]
     domain). The metamethod is reached by the SAME [__index] chain that resolves any
     field ([tproj] — own field or inherited through [proto]), so the metamethod may
     be inherited; membership is on the MERGED type [M], one ordinary field lookup,
     not a hardcoded handler. Result is the metamethod's codomain [R]. (Multi-arg /
     multi-return [__call] interaction is DEFERRED.) *)
  | TCallMeta : forall S G ofs proto M Self A R arg,
      has_type S G (tmeta ofs proto) (BRec M) ->
      In (mm_call, BArrow Self (BArrow A R)) M ->
      rsub (BRec M) Self ->
      has_type S G arg A ->
      has_type S G (tapp (tmeta ofs proto) arg) R
  (* METATABLE METAMETHOD — BINARY OPERATOR overloading ([__add]/[__sub]/[__mul] and
     [__eq]/[__lt]/[__le]). A primop [tprim op a b] whose LEFT operand [a] is a
     metatable-table whose read interface [BRec M] carries the operator's metamethod
     [Self -> Other -> R] dispatches to [(a.<mm>) a b] (Lua tries the LEFT operand's
     metamethod first). Curried, reusing the arrow machinery; result [R]. The
     metamethod key is selected by [mm_binop op] — ordinary data, one general lookup
     through the [__index] chain; the number path ([TPrimArith]/[TPrimCmp]) is kept
     for plain numbers, so the two coexist. *)
  | TPrimMetaL : forall S G op ofs proto M Self Other R b,
      has_type S G (tmeta ofs proto) (BRec M) ->
      In (mm_binop op, BArrow Self (BArrow Other R)) M ->
      rsub (BRec M) Self ->
      has_type S G b Other ->
      has_type S G (tprim op (tmeta ofs proto) b) R
  (* METATABLE METAMETHOD — BINARY OPERATOR overloading, RIGHT-operand fallback.
     The exact MIRROR of [TPrimMetaL]: a primop [tprim op a b] whose RIGHT operand
     [b] is a metatable-table whose read interface [BRec M] carries the operator's
     metamethod [Self -> Other -> R] dispatches to [(b.<mm>) a b] (Lua, having found
     no metamethod on the LEFT operand, tries the RIGHT operand's metamethod). The
     metamethod's CURRIED argument order is unchanged — [(metamethod) a b] — only
     the table that PROVIDES it differs. Same [mm_binop op] key, same [__index]-chain
     resolution ([tproj]), same arrow machinery; no new lookup mechanism.

     The LEFT operand [a] is required to be a SCALAR — typed at an ATOM [BAtom al]
     (number / string / bool / nil) — which is the faithful, prototypical
     right-fallback shape ([1 + obj], [obj] carrying [__add]): a non-table value
     provides no metamethod. This [BAtom] domain is the discriminator that keeps
     LEFT vs RIGHT dispatch disjoint, and it is robust where a syntactic one is not:
     (1) STABLE UNDER SUBSTITUTION (a [BAtom]-typed operand stays [BAtom]-typed,
     whereas "syntactically not a [tmeta]" is destroyed when a variable is
     substituted by a [tmeta] value); (2) STEP-DISJOINT from [SPrimMetaL] (a
     [BAtom]-typed value is canonically a literal, never a [tmeta], so [SPrimMetaL]
     never fires on it); (3) lets preservation refute the [TPrimMetaR] inversion at
     the [SPrimMetaL] site by canonical forms ([tmeta] cannot inhabit [BAtom]).
     [a : BAtom al], [b = tmeta ofs proto : BRec M] with [mm_binop op : BAtom al ->
     Other -> R] and [rsub (BRec M) Other]; result [R].
     DEFERRED (a genuinely narrower concern, not faked): a left operand that is
     itself a [tmeta] missing the metamethod key, falling through to the right —
     that needs a runtime [__index]-chain resolution side-condition (the [tproj]
     reduction), which this static fragment does not expose as a decidable premise. *)
  | TPrimMetaR : forall S G op a al ofs proto M Other R,
      has_type S G a (BAtom al) ->
      has_type S G (tmeta ofs proto) (BRec M) ->
      In (mm_binop op, BArrow (BAtom al) (BArrow Other R)) M ->
      rsub (BRec M) Other ->
      has_type S G (tprim op a (tmeta ofs proto)) R
  (* METATABLE METAMETHOD — [__newindex] (write fallback). [tnewidx (tmeta ofs ni) k v]
     is the Lua field-write [t.k = v]: when [k] is ABSENT from the table's OWN fields,
     it dispatches to the metatable's [__newindex]. Here [__newindex] is a TABLE
     (the [ni] prototype-position target) holding the writable cells: the
     write-through goes into [ni]'s cell for [k] — the records-of-refs encoding,
     where the target field is a mutable [BRef] cell. So [ni : BRec Pf] with
     [(k, BRef T) ∈ Pf], and the write assigns a [v : T] into that cell, yielding
     the unit value [nil]. [k] must NOT be an own key (absent-from-own is the
     dispatch condition; the own-present case is a rawset on the immutable own
     record — DEFERRED, the genuine dynamic-mutation fork). [__newindex] as a
     FUNCTION is also DEFERRED. *)
  | TNewIdx : forall S G ofs proto Town Pf k v T,
      has_fields S G ofs Town ->
      NoDup (map fst Town) ->
      key_in k Town = false ->
      has_type S G proto (BRec Pf) ->
      NoDup (map fst Pf) ->
      In (k, BRef T) Pf ->
      has_type S G v T ->
      has_type S G (tnewidx ofs proto k v) (BAtom ANil)
  (* METATABLE UNARY METAMETHOD — [__unm]/[__len]. A unary operator [tunop uop e]
     whose operand [e] is a metatable-table whose read interface [BRec M] carries the
     unary metamethod [mm_unop uop : Self -> Other -> R] dispatches to [(e.<mm>) e e]
     (operand passed TWICE — Lua-faithful unary metamethod calling convention).
     Curried, reusing the arrow machinery; the table's record type must be a valid
     [self] for BOTH argument positions ([rsub (BRec M) Self] and [rsub (BRec M)
     Other] — the metamethod may declare distinct domains, both fed the operand).
     Result [R]. The metamethod key is selected by [mm_unop uop] — ordinary data, ONE
     general lookup through the [__index] chain (so it may be inherited); the unary
     analogue of [TPrimMetaL] (with the right operand bound to the operand itself). *)
  | TUnMetaL : forall S G uop ofs proto M Self Other R,
      has_type S G (tmeta ofs proto) (BRec M) ->
      In (mm_unop uop, BArrow Self (BArrow Other R)) M ->
      rsub (BRec M) Self ->
      rsub (BRec M) Other ->
      has_type S G (tunop uop (tmeta ofs proto)) R
  (* RAW READ — [rawget((tmeta own proto), k)]. The OWN field-list is typed EXACTLY
     by [has_fields] (same exactness discipline as [TMeta]/[TNewIdx]). The key [k]
     must be a DIRECT (own) field — [(k, T) ∈ Town] — and the result is OWN's type
     [T] for it. Raw access NEVER consults [proto]: there is no merge and no
     fallback, so an inherited (prototype-only) key is NOT typeable here (the
     distinguishing static property versus [TProj] on the merged read interface).
     [proto] is still typed (a [BRec], the prototype shape) so the table is
     well-formed, but its fields play no part in the result. *)
  | TRawGet : forall S G ofs proto Town Pf k T,
      has_fields S G ofs Town ->
      NoDup (map fst Town) ->
      In (k, T) Town ->
      has_type S G proto (BRec Pf) ->
      NoDup (map fst Pf) ->
      has_type S G (trawget ofs proto k) T
  (* RAW WRITE — [rawset((tmeta own proto), k, v)]. The records-of-refs write of
     [TNewIdx], but to OWN's cell, NEVER the prototype's, and WITHOUT the
     absent-from-own dispatch: [k] must be a DIRECT own field whose value is a
     writable [BRef T] cell ([(k, BRef T) ∈ Town]); the write assigns a [v : T]
     into that cell, yielding the unit value [nil]. [proto] is typed for
     well-formedness but is never written. *)
  | TRawSet : forall S G ofs proto Town Pf k v T,
      has_fields S G ofs Town ->
      NoDup (map fst Town) ->
      In (k, BRef T) Town ->
      has_type S G proto (BRec Pf) ->
      NoDup (map fst Pf) ->
      has_type S G v T ->
      has_type S G (trawset ofs proto k v) (BAtom ANil)
  (* VARARG — the variadic CALL. The variadic function [f] has the two-binder
     curried type [BArrow T (BArrow (BTuple Ts) B)] — a fixed parameter of type
     [T] then the REST of type [BTuple Ts]. The fixed actual [a : T]; the TRAILING
     actuals [rs] are typed pointwise into [Ts] ([has_types], exactly as a
     [tret]'s components are) — i.e. they are PACKED into the rest multivalue. The
     result is [B]. Operationally [SVApp] packs [rs] into [tret rs] and applies
     [f] to [a] and then to that packed rest; this rule types that exactly. *)
  | TVApp : forall S G f a rs T Ts B,
      has_type S G f (BArrow T (BArrow (BTuple Ts) B)) ->
      has_type S G a T ->
      has_types S G rs Ts ->
      has_type S G (tvapp f a rs) B
  (* MULTIPLE-ASSIGNMENT — [a, b, … = rhs]. The [N] TARGETS [rs] are typed pointwise
     as reference cells [BRef Tgt_i] ([has_types rs (map BRef Tgts)]); the RHS is the
     PACKED multivalue at its TUPLE type [BTuple Ss]. The RHS is ADJUSTED to arity
     [N = length Tgts] by [pad_ty] (truncate or [nil]-pad) and each adjusted source
     type must be [rsub]-below the corresponding target CELL type ([Forall2 rsub]) —
     exactly the per-assignment obligation [tassign] imposes, lifted pointwise. A
     [nil]-padded slot supplies [BAtom ANil], so a target survives padding only when
     its cell type ADMITS nil ([rsub (BAtom ANil) Tgt_i]) — faithful to Lua. Result:
     the unit value [nil]. The adjustment REUSES the multi-value substrate: no new
     subtyping, no index signatures; [pad_ty]/[pad_tm] are the generalization of
     [tfst]-truncation to arbitrary arity, adding only [nil]-pad in the other
     direction. *)
  | TMAssign : forall S G rs rhs Tgts Ss,
      has_types S G rs (map BRef Tgts) ->
      has_type S G rhs (BTuple Ss) ->
      Forall2 rsub (pad_ty Ss (Datatypes.length Tgts)) Tgts ->
      has_type S G (tmassign rs rhs) (BAtom ANil)
(* key-aligned pointwise typing of record fields; mutual so the generated
   induction principle carries an IH on every field derivation. *)
with has_fields : list BTy -> list BTy -> list (string * tm) -> list (string * BTy) -> Prop :=
  | HFnil  : forall S G, has_fields S G [] []
  | HFcons : forall S G k e T fs Ts,
      has_type S G e T ->
      has_fields S G fs Ts ->
      has_fields S G ((k, e) :: fs) ((k, T) :: Ts)
(* MULTI-RETURN — positional pointwise typing of a return-sequence's components.
   Mutual so the generated induction principle carries a per-component IH. *)
with has_types : list BTy -> list BTy -> list tm -> list BTy -> Prop :=
  | HTnil  : forall S G, has_types S G [] []
  | HTcons : forall S G e T es Ts,
      has_type S G e T ->
      has_types S G es Ts ->
      has_types S G (e :: es) (T :: Ts).

Scheme has_type_mind := Induction for has_type Sort Prop
  with has_fields_mind := Induction for has_fields Sort Prop
  with has_types_mind := Induction for has_types Sort Prop.

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
  | VLoc  : forall n, value (tloc n)
  (* MULTI-RETURN — a fully-evaluated return-sequence is a VALUE (the multivalue):
     all its components are values. (Models [VTup vs] at the value level.) *)
  | VRet  : forall es, Forall value es -> value (tret es)
  (* METATABLES — a metatable-table is a VALUE once all its OWN fields are values
     and its prototype is a value. (Own is a record-literal field-list, exactly
     like [trec]'s [VRec] requirement.) *)
  | VMeta : forall own proto,
      Forall (fun ke => value (snd ke)) own -> value proto ->
      value (tmeta own proto).

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
  (* annotation: the type [T] is closed (no de Bruijn vars); lift the body at [k]. *)
  | tannot T e => tannot T (lift d k e)
  (* MULTI-RETURN: no new binders — components / adjuster operands lift at [k]. *)
  | tret es => tret (map (lift d k) es)
  | tfst e => tfst (lift d k e)
  | tappspread g a => tappspread (lift d k g) (lift d k a)
  (* METATABLES: no new binders — own fields and prototype lift at [k]. *)
  | tmeta own proto =>
      tmeta (map (fun ke => (fst ke, lift d k (snd ke))) own) (lift d k proto)
  (* __newindex write: no new binders — own fields, proto, and value lift at [k]. *)
  | tnewidx own proto k0 v =>
      tnewidx (map (fun ke => (fst ke, lift d k (snd ke))) own) (lift d k proto) k0 (lift d k v)
  (* unary metamethod: no new binders — the operand lifts at [k]. *)
  | tunop uop e => tunop uop (lift d k e)
  (* RAW ACCESS: no new binders — own fields, proto (and value) lift at [k]. *)
  | trawget own proto k0 =>
      trawget (map (fun ke => (fst ke, lift d k (snd ke))) own) (lift d k proto) k0
  | trawset own proto k0 v =>
      trawset (map (fun ke => (fst ke, lift d k (snd ke))) own) (lift d k proto) k0 (lift d k v)
  (* VARARG: no new binders at the CALL — function, fixed arg, and each trailing
     arg lift at [k]. *)
  | tvapp f a rs => tvapp (lift d k f) (lift d k a) (map (lift d k) rs)
  (* MULTIPLE-ASSIGNMENT: no new binders — each target and the RHS lift at [k]. *)
  | tmassign rs rhs => tmassign (map (lift d k) rs) (lift d k rhs)
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
  (* annotation: substitute into the body at [j]; the type is closed. *)
  | tannot T e => tannot T (subst j s e)
  (* MULTI-RETURN: no new binders — substitute into components / operands at [j]. *)
  | tret es => tret (map (subst j s) es)
  | tfst e => tfst (subst j s e)
  | tappspread g a => tappspread (subst j s g) (subst j s a)
  (* METATABLES: no new binders — substitute into own fields and prototype at [j]. *)
  | tmeta own proto =>
      tmeta (map (fun ke => (fst ke, subst j s (snd ke))) own) (subst j s proto)
  (* __newindex write: no new binders — substitute into own fields, proto, value. *)
  | tnewidx own proto k0 v =>
      tnewidx (map (fun ke => (fst ke, subst j s (snd ke))) own) (subst j s proto) k0 (subst j s v)
  (* unary metamethod: no new binders — substitute into the operand at [j]. *)
  | tunop uop e => tunop uop (subst j s e)
  (* RAW ACCESS: no new binders — substitute into own fields, proto (and value). *)
  | trawget own proto k0 =>
      trawget (map (fun ke => (fst ke, subst j s (snd ke))) own) (subst j s proto) k0
  | trawset own proto k0 v =>
      trawset (map (fun ke => (fst ke, subst j s (snd ke))) own) (subst j s proto) k0 (subst j s v)
  (* VARARG: no new binders at the CALL — substitute into function, fixed arg, and
     each trailing arg at [j]. *)
  | tvapp f a rs => tvapp (subst j s f) (subst j s a) (map (subst j s) rs)
  (* MULTIPLE-ASSIGNMENT: no new binders — substitute into each target + the RHS. *)
  | tmassign rs rhs => tmassign (map (subst j s) rs) (subst j s rhs)
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

(* MULTI-RETURN — a multivalue is its OWN classification for truthiness flow
   narrowing. In Lua a multivalue in a boolean test is TRUNCATED to its first
   value BEFORE the test; our calculus makes [tret] a value, so we classify it
   separately ([is_multi]) and the narrowing conditional TRUNCATES it first
   ([SIfnMulti]) rather than substituting a raw multivalue into a branch (which
   would carry a contradicted [truthy_type]/[falsy_type] narrowing). This keeps
   [truthy_narrows]/[falsy_narrows] free of multivalues — the sound, Lua-faithful
   discipline. *)
Definition is_multi (v : tm) : Prop := exists es, v = tret es.

(* [truthy_value] now EXCLUDES multivalues (they take the truncation path): a
   value is truthy iff it is neither falsy nor a multivalue. *)
Definition truthy_value (v : tm) : Prop :=
  ~ falsy_value v /\ ~ is_multi v.

(* a value is truthy, falsy, OR a multivalue — the total 3-way partition. *)
Lemma value_truthy_or_falsy : forall v,
  value v -> truthy_value v \/ falsy_value v \/ is_multi v.
Proof.
  intros v Hv. unfold truthy_value, falsy_value, is_multi.
  destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
  - destruct l as [n | n | [|] | ].
    + left. split; [intros [H | H]; discriminate | intros [es H]; discriminate].
    + left. split; [intros [H | H]; discriminate | intros [es H]; discriminate].
    + left. split; [intros [H | H]; discriminate | intros [es H]; discriminate]. (* true *)
    + right. left. left. reflexivity.                (* LBool false *)
    + right. left. right. reflexivity.               (* LNil *)
  - left. split; [intros [H | H]; discriminate | intros [es H]; discriminate].
  - left. split; [intros [H | H]; discriminate | intros [es H]; discriminate].
  - (* tloc: TRUTHY *) left. split; [intros [H | H]; discriminate | intros [es H]; discriminate].
  - (* tret: a MULTIVALUE — the third class *) right. right. exists es. reflexivity.
  - (* tmeta: a TABLE — TRUTHY *)
    left. split; [intros [H | H]; discriminate | intros [es H]; discriminate].
Qed.

(* truthy and falsy are mutually exclusive (a value is not both). *)
Lemma truthy_not_falsy : forall v, truthy_value v -> falsy_value v -> False.
Proof. intros v [Ht _] Hf. exact (Ht Hf). Qed.

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
  | TgTable, tmeta _ _      => True       (* METATABLES — a metatable-table is a table *)
  | TgFun,   tlam _ _       => True
  | TgRef,   tloc _         => True       (* SPLIT-STEP 3 — a location's tag *)
  | TgMulti, tret _         => True       (* MULTI-RETURN — a multivalue's tag *)
  | _, _ => False
  end.

(* every value has SOME tag (the type-test always selects a branch). *)
Lemma value_has_some_tag : forall v, value v -> exists g, has_tag v g.
Proof.
  intros v Hv. destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
  - destruct l as [n | n | bb | ].
    + exists TgNum; exact I.
    + exists TgStr; exact I.
    + exists TgBool; exact I.
    + exists TgNil; exact I.
  - exists TgFun; exact I.
  - exists TgTable; exact I.
  - exists TgRef; exact I.                (* tloc *)
  - exists TgMulti; exact I.              (* tret — a multivalue *)
  - exists TgTable; exact I.              (* tmeta — a metatable-table *)
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

(* MULTIPLE-ASSIGNMENT — perform N writes at once. [rs] are the TARGET terms
   (location values [tloc n_i]); [vs] are the ALREADY-ADJUSTED values to write
   (length [N], from [pad_tm]). Each pair writes [v_i] into the cell [n_i] via the
   EXISTING [store_update]; a non-location target (impossible for a well-typed
   reduction, where every target is a [tloc] value) is skipped. This is the "compute
   everything, then assign" model — all writes applied together in [SMAssign]. *)
Fixpoint store_massign (rs : list tm) (vs : list tm) (st : store) : store :=
  match rs, vs with
  | (tloc n) :: rs', v :: vs' => store_massign rs' vs' (store_update n v st)
  | _ :: rs', _ :: vs' => store_massign rs' vs' st
  | _, _ => st
  end.

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
  (* MULTI-RETURN — a MULTIVALUE scrutinee of a narrowing conditional TRUNCATES to
     its first value (or [nil] if empty) BEFORE the truthiness test, exactly as Lua
     adjusts [if f() then ...] to test [f()]'s first value. This keeps the raw
     multivalue out of the branch (which carries a [truthy_type]/[falsy_type]
     narrowing the multivalue does not satisfy). *)
  | SIfnMultiCons : forall v rest e1 e2 st,
      value (tret (v :: rest)) -> step (tifn (tret (v :: rest)) e1 e2, st) (tifn v e1 e2, st)
  | SIfnMultiNil  : forall e1 e2 st,
      step (tifn (tret []) e1 e2, st) (tifn (tlit LNil) e1 e2, st)
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
      step (tassign v e, st) (tassign v e', st')
  (* TYPE ANNOTATION — RUNTIME ERASURE. The annotation is congruence-reduced under
     ([SAnnot1]) until its body is a value, then STRIPPED ([SAnnotV]). This
     value-strip composes cleanly with CBV evaluation contexts (an annotation never
     blocks reduction and never persists into a value), which keeps progress (a
     [tannot T v] always steps — strip — and a [tannot T e] with reducible [e] steps
     by congruence) and preservation (preserves [T]: congruence keeps the
     annotation type; the strip yields [v : T] since the annotation was checked)
     clean. [tannot T v] is NOT a value (it strips). *)
  | SAnnot1 : forall T e e' st st', step (e, st) (e', st') ->
      step (tannot T e, st) (tannot T e', st')
  | SAnnotV : forall T v st, value v -> step (tannot T v, st) (v, st)
  (* MULTI-RETURN — operational rules. *)
  (* [tret] evaluates its components left-to-right (the first non-value steps);
     once all are values it IS the multivalue value. *)
  | SRet  : forall pre e e' post st st',
      Forall value pre ->
      step (e, st) (e', st') ->
      step (tret (pre ++ e :: post), st) (tret (pre ++ e' :: post), st')
  (* TRUNCATION reduction: [tfst] of a fully-evaluated multivalue takes its HEAD
     (or [nil] if the sequence is empty). This is the operational adjustment that
     discards the extra values. *)
  | SFstCons : forall v rest st,
      value (tret (v :: rest)) ->
      step (tfst (tret (v :: rest)), st) (v, st)
  | SFstNil  : forall st,
      step (tfst (tret []), st) (tlit LNil, st)
  | SFst1    : forall e e' st st', step (e, st) (e', st') -> step (tfst e, st) (tfst e', st')
  (* SPREAD reduction: [tappspread (\(BTuple Ts). body) <multivalue>] SPLICES the
     whole value-sequence into [g] by substituting the multivalue at the binder.
     The consumer binds the entire sequence (the known-arity tuple parameter). *)
  | SAppSpread : forall T body mv st,
      value mv ->
      step (tappspread (tlam T body) mv, st) (subst 0 mv body, st)
  | SAppSpread1 : forall g g' a st st',
      step (g, st) (g', st') -> step (tappspread g a, st) (tappspread g' a, st')
  | SAppSpread2 : forall v a a' st st',
      value v -> step (a, st) (a', st') -> step (tappspread v a, st) (tappspread v a', st')
  (* METATABLES — congruence: build the table left-to-right. Step the first
     non-value OWN field (left-to-right, exactly like [SRec]); once all own fields
     are values, step the prototype. *)
  | SMeta1 : forall pre k e e' post proto st st',
      Forall (fun ke => value (snd ke)) pre ->
      step (e, st) (e', st') ->
      step (tmeta (pre ++ (k, e) :: post) proto, st)
           (tmeta (pre ++ (k, e') :: post) proto, st')
  | SMeta2 : forall own proto proto' st st',
      Forall (fun ke => value (snd ke)) own ->
      step (proto, st) (proto', st') ->
      step (tmeta own proto, st) (tmeta own proto', st')
  (* METATABLES — the [__index] DISPATCH (the heart of the construct). A
     projection on a metatable-table VALUE [tmeta own proto] resolves the key: if
     [k] is a DIRECT (own) field, step to its value ([SMetaProjOwn]); ELSE fall
     back to projecting the PROTOTYPE ([SMetaProjProto], which then resolves
     recursively through [proto]'s own [__index] chain). This is the runtime
     prototype-inheritance lookup. *)
  | SMetaProjOwn : forall own proto k v st,
      value (tmeta own proto) ->
      field_lookup k own = Some v ->
      step (tproj (tmeta own proto) k, st) (v, st)
  | SMetaProjProto : forall own proto k st,
      value (tmeta own proto) ->
      field_lookup k own = None ->
      step (tproj (tmeta own proto) k, st) (tproj proto k, st)
  (* METATABLE METAMETHOD — [__call] DISPATCH. Applying a metatable-table VALUE
     [tmeta own proto] to a VALUE [arg] dispatches to [(table.__call) table arg] —
     the metamethod is RESOLVED BY THE SAME [__index] CHAIN as any field (the
     [tproj (tmeta own proto) mm_call] subterm steps via [SMetaProjOwn]/[Proto]),
     then applied to the table as [self] and to [arg]. Reuses [tproj] + two [tapp]/
     [SBeta] — no new lookup machinery; the metamethod may be inherited. *)
  | SCallMeta : forall own proto arg st,
      value (tmeta own proto) ->
      value arg ->
      step (tapp (tmeta own proto) arg, st)
           (tapp (tapp (tproj (tmeta own proto) mm_call) (tmeta own proto)) arg, st)
  (* METATABLE METAMETHOD — BINARY OPERATOR DISPATCH (LEFT operand). A primop whose
     LEFT operand is a metatable-table VALUE dispatches to [(a.<mm>) a b] — the
     operator metamethod [mm_binop op] resolved through the [__index] chain
     ([tproj]), applied to the left operand as [self] and the right operand [b].
     (Lua tries the left operand's metamethod first.) Reuses [tproj] + [tapp]. The
     plain-number path fires only on two number literals; a metatable left operand
     takes THIS rule. *)
  | SPrimMetaL : forall op own proto b st,
      value (tmeta own proto) ->
      step (tprim op (tmeta own proto) b, st)
           (tapp (tapp (tproj (tmeta own proto) (mm_binop op)) (tmeta own proto)) b, st)
  (* METATABLE METAMETHOD — BINARY OPERATOR DISPATCH (RIGHT operand). The mirror of
     [SPrimMetaL]: a primop whose RIGHT operand is a metatable-table VALUE, with the
     LEFT operand already a VALUE, dispatches to [(b.<mm>) a b] — the operator
     metamethod [mm_binop op] resolved through the RIGHT table's [__index] chain
     ([tproj]), applied to the left operand [a] and the right operand [b] (same
     curried argument order [a b]; only the table that provides the metamethod
     differs). [value a] sequences left-before-right (Lua tries the left operand
     first). The left operand is a LITERAL [tlit l] — the canonical form of the
     scalar ([BAtom]) left that [TPrimMetaR] types — which is syntactically never a
     [tmeta], so this never overlaps [SPrimMetaL] and preservation discriminates the
     LEFT-fallback inversion cleanly. Progress fires it exactly when the left is a
     scalar value (a literal, by canonical forms) and the right is a metatable
     value. *)
  | SPrimMetaR : forall op l own proto st,
      value (tmeta own proto) ->
      step (tprim op (tlit l) (tmeta own proto), st)
           (tapp (tapp (tproj (tmeta own proto) (mm_binop op)) (tlit l)) (tmeta own proto), st)
  (* METATABLE METAMETHOD — [__newindex] WRITE-FALLBACK DISPATCH. [tnewidx own ni k v]
     — the write [(tmeta own ni).k = v] — with [k] ABSENT from [own]
     ([field_lookup k own = None]) and own fields + [ni] + [v] all VALUES dispatches
     the write to the [__newindex] target [ni]: it becomes [tassign (tproj ni k) v] —
     project [ni]'s cell for [k] (the projection machinery resolves it to a [tloc])
     and assign [v] into that mutable cell (the records-of-refs write). Congruences
     [SNewIdx1] (own fields, like [SRec]), [SNewIdx2] (proto), [SNewIdx3] (value)
     reduce the operands left-to-right first. *)
  | SNewIdx : forall own ni k v st,
      Forall (fun ke => value (snd ke)) own ->
      value ni ->
      value v ->
      field_lookup k own = None ->
      step (tnewidx own ni k v, st)
           (tassign (tproj ni k) v, st)
  | SNewIdx1 : forall pre k0 e e' post proto k v st st',
      Forall (fun ke => value (snd ke)) pre ->
      step (e, st) (e', st') ->
      step (tnewidx (pre ++ (k0, e) :: post) proto k v, st)
           (tnewidx (pre ++ (k0, e') :: post) proto k v, st')
  | SNewIdx2 : forall own proto proto' k v st st',
      Forall (fun ke => value (snd ke)) own ->
      step (proto, st) (proto', st') ->
      step (tnewidx own proto k v, st) (tnewidx own proto' k v, st')
  | SNewIdx3 : forall own proto k v v' st st',
      Forall (fun ke => value (snd ke)) own -> value proto ->
      step (v, st) (v', st') ->
      step (tnewidx own proto k v, st) (tnewidx own proto k v', st')
  (* METATABLE UNARY METAMETHOD — DISPATCH. A unary operator [tunop uop e] whose
     operand is a metatable-table VALUE [tmeta own proto] dispatches to [(e.<mm>) e e]
     — the metamethod [mm_unop uop] resolved through the [__index] chain ([tproj]),
     applied to the operand as BOTH arguments (Lua passes the operand twice for unary
     metamethods). Reuses [tproj] + two [tapp]/[SBeta] — the unary analogue of
     [SPrimMetaL]; no new lookup machinery, the metamethod may be inherited. *)
  | SUnMetaL : forall uop own proto st,
      value (tmeta own proto) ->
      step (tunop uop (tmeta own proto), st)
           (tapp (tapp (tproj (tmeta own proto) (mm_unop uop)) (tmeta own proto)) (tmeta own proto), st)
  (* unary metamethod — congruence: reduce the operand to a value first. *)
  | SUnop1 : forall uop e e' st st',
      step (e, st) (e', st') -> step (tunop uop e, st) (tunop uop e', st')
  (* RAW READ DISPATCH — [trawget own proto k] with own fields + proto all VALUES
     resolves the RAW own read: [field_lookup k own] (the SAME own-field primitive
     [SMetaProjOwn] uses) steps DIRECTLY to the own value [v]. There is NO
     prototype-fallback rule: raw access never consults [proto] (contrast
     [SMetaProjProto]). Congruences [SRawGet1]/[SRawGet2] reduce own / proto first. *)
  | SRawGet : forall own proto k v st,
      Forall (fun ke => value (snd ke)) own ->
      value proto ->
      field_lookup k own = Some v ->
      step (trawget own proto k, st) (v, st)
  | SRawGet1 : forall pre k0 e e' post proto k st st',
      Forall (fun ke => value (snd ke)) pre ->
      step (e, st) (e', st') ->
      step (trawget (pre ++ (k0, e) :: post) proto k, st)
           (trawget (pre ++ (k0, e') :: post) proto k, st')
  | SRawGet2 : forall own proto proto' k st st',
      Forall (fun ke => value (snd ke)) own ->
      step (proto, st) (proto', st') ->
      step (trawget own proto k, st) (trawget own proto' k, st')
  (* RAW WRITE DISPATCH — [trawset own proto k v] with own fields + proto + value
     all VALUES resolves the RAW own write: the own cell for [k]
     ([field_lookup k own = Some cell], a [tloc] by typing) is assigned [v] — it
     becomes [tassign cell v] (the records-of-refs write, [SAssign]). This is
     [SNewIdx]'s write WITH the cell read from OWN ([field_lookup k own]) instead of
     the prototype ([tproj ni k]), and WITHOUT any absent-from-own dispatch. No
     prototype rule exists; raw write never writes [proto]. Congruences
     [SRawSet1]/[SRawSet2]/[SRawSet3] reduce own / proto / value first. *)
  | SRawSet : forall own proto k v cell st,
      Forall (fun ke => value (snd ke)) own ->
      value proto ->
      value v ->
      field_lookup k own = Some cell ->
      step (trawset own proto k v, st) (tassign cell v, st)
  | SRawSet1 : forall pre k0 e e' post proto k v st st',
      Forall (fun ke => value (snd ke)) pre ->
      step (e, st) (e', st') ->
      step (trawset (pre ++ (k0, e) :: post) proto k v, st)
           (trawset (pre ++ (k0, e') :: post) proto k v, st')
  | SRawSet2 : forall own proto proto' k v st st',
      Forall (fun ke => value (snd ke)) own ->
      step (proto, st) (proto', st') ->
      step (trawset own proto k v, st) (trawset own proto' k v, st')
  | SRawSet3 : forall own proto k v v' st st',
      Forall (fun ke => value (snd ke)) own -> value proto ->
      step (v, st) (v', st') ->
      step (trawset own proto k v, st) (trawset own proto k v', st')
  (* VARARG — operational rules. The PACK reduction: once the variadic function
     [vf], the fixed argument [va], and ALL trailing arguments [rs] are values, the
     trailing arguments are COLLECTED into the rest multivalue [tret rs] and the
     two-binder curried function is applied to [va] and then to that packed rest —
     reusing the EXISTING [tapp]/[tret]/[SBeta] machinery (no new binding form).
     This is the PARAMETER-side mirror of [tret]: [tret] PRODUCES a multivalue at
     return; [SVApp] CONSTRUCTS the rest multivalue at the binding site. *)
  | SVApp  : forall vf va rs st,
      value vf -> value va -> Forall value rs ->
      step (tvapp vf va rs, st) (tapp (tapp vf va) (tret rs), st)
  (* congruences — evaluate the function, then the fixed argument, then the
     trailing arguments left-to-right (the same discipline as [SApp1]/[SApp2] and
     [SRet]). *)
  | SVApp1 : forall f f' a rs st st',
      step (f, st) (f', st') -> step (tvapp f a rs, st) (tvapp f' a rs, st')
  | SVApp2 : forall vf a a' rs st st',
      value vf -> step (a, st) (a', st') ->
      step (tvapp vf a rs, st) (tvapp vf a' rs, st')
  | SVApp3 : forall vf va pre e e' post st st',
      value vf -> value va -> Forall value pre ->
      step (e, st) (e', st') ->
      step (tvapp vf va (pre ++ e :: post), st) (tvapp vf va (pre ++ e' :: post), st')
  (* MULTIPLE-ASSIGNMENT — operational rules. The main reduction [SMAssign]: once
     every TARGET [rs] is a value (a location [tloc n]) and the RHS is a fully
     evaluated multivalue [tret vs], the RHS is ADJUSTED to the target arity by
     [pad_tm] (truncate the extra values / pad the missing slots with [nil]) and ALL
     the adjusted values are written at once ([store_massign]) — "compute
     everything, then assign". The form yields the unit value [nil]. This REUSES the
     [tassign] store-update; the [tret] multivalue is the SAME one a call / vararg
     produces. *)
  | SMAssign : forall rs vs st,
      Forall value rs -> Forall value vs ->
      step (tmassign rs (tret vs), st)
           (tlit LNil, store_massign rs (pad_tm vs (List.length rs)) st)
  (* congruences — evaluate the targets left-to-right (so each is a location value),
     THEN the RHS multivalue (the same left-to-right discipline as [SRet]/[SVApp]). *)
  | SMAssign1 : forall pre r r' post rhs st st',
      Forall value pre ->
      step (r, st) (r', st') ->
      step (tmassign (pre ++ r :: post) rhs, st)
           (tmassign (pre ++ r' :: post) rhs, st')
  | SMAssign2 : forall rs rhs rhs' st st',
      Forall value rs ->
      step (rhs, st) (rhs', st') ->
      step (tmassign rs rhs, st) (tmassign rs rhs', st').

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

(* INCREMENT 19 + METATABLE OPERATOR METAMETHODS — primop inversion (subsumption-
   transparent), now a DISJUNCTION between the NUMERIC path and the LEFT-operand
   metamethod dispatch:
   - NUMERIC: operands typed at [ANum]; result [ANum] (arith) or [ABool] (cmp),
     subsumed to [T].
   - METAMETHOD: the LEFT operand is a metatable-table [tmeta ofs proto] whose own
     fields carry the operator metamethod [mm_binop op : Self -> Other -> R]; the
     table's merged record [rsub]'s [Self]; the right operand [b : Other]; result
     [R] subsumed to [T]. *)
Lemma inv_prim : forall S G op a b T,
  has_type S G (tprim op a b) T ->
  (has_type S G a (BAtom ANum) /\ has_type S G b (BAtom ANum) /\
   ((arith_op op = true /\ rsub (BAtom ANum) T) \/
    (cmp_op op = true /\ rsub (BAtom ABool) T)))
  \/
  (exists ofs proto M Self Other R,
     a = tmeta ofs proto /\
     has_type S G (tmeta ofs proto) (BRec M) /\
     In (mm_binop op, BArrow Self (BArrow Other R)) M /\
     rsub (BRec M) Self /\
     has_type S G b Other /\ rsub R T)
  \/
  (* RIGHT-operand metamethod fallback (mirror): [b = tmeta ofs proto : BRec M]
     carries [mm_binop op : BAtom al -> Other -> R], left operand [a : BAtom al]
     (a scalar), the right table [rsub]'s [Other], result [R] subsumed to [T]. *)
  (exists al ofs proto M Other R,
     b = tmeta ofs proto /\
     has_type S G a (BAtom al) /\
     has_type S G (tmeta ofs proto) (BRec M) /\
     In (mm_binop op, BArrow (BAtom al) (BArrow Other R)) M /\
     rsub (BRec M) Other /\ rsub R T).
Proof.
  intros S G op a b T H. remember (tprim op a b) as e eqn:Ee.
  induction H; try discriminate Ee.
  - (* TPrimArith *) injection Ee as <- <- <-. left.
    split; [assumption|split;[assumption| left; split;[assumption|apply rsub_refl]]].
  - (* TPrimCmp *) injection Ee as <- <- <-. left.
    split; [assumption|split;[assumption| right; split;[assumption|apply rsub_refl]]].
  - (* TSub *) subst. destruct (IHhas_type eq_refl) as
      [ [Ha [Hb [[Har Hd]|[Hcr Hd]]]]
      | [ [ofs [proto [M [Self [Other [R [Ea Hrest]]]]]]]
        | [al [ofs [proto [M [Other [R [Eb Hrest]]]]]]] ] ].
    + left. split;[assumption|split;[assumption| left; split;[assumption|eapply RsTrans; eassumption]]].
    + left. split;[assumption|split;[assumption| right; split;[assumption|eapply RsTrans; eassumption]]].
    + right; left. exists ofs, proto, M, Self, Other, R.
      destruct Hrest as [Htbl [Hin [Hself [Hb Hd]]]].
      split; [assumption|]. split; [assumption|]. split; [assumption|].
      split; [assumption|]. split; [assumption|]. eapply RsTrans; eassumption.
    + right; right. exists al, ofs, proto, M, Other, R.
      destruct Hrest as [Ha [Htbl [Hin [Hother Hd]]]].
      split; [assumption|]. split; [assumption|]. split; [assumption|].
      split; [assumption|]. split; [assumption|].
      eapply RsTrans; eassumption.
  - (* TPrimMetaL *) injection Ee as <- <- <-. right; left.
    exists ofs, proto, M, Self, Other, R.
    split; [reflexivity|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. split; [assumption|]. apply rsub_refl.
  - (* TPrimMetaR *) injection Ee as <- <- <-. right; right.
    exists al, ofs, proto, M, Other, R.
    split; [reflexivity|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. split; [assumption|]. apply rsub_refl.
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

(* METATABLE [__call] — application inversion is now a DISJUNCTION: the ordinary
   ARROW application ([f : A -> B]) OR a [__call] metatable dispatch (the function
   is a metatable-table [tmeta ofs proto] whose own [mm_call] field is
   [Self -> A -> R]; the table's merged record [rsub]'s [Self]; the argument
   [a : A]; result [R] subsumed to [T]). *)
Lemma inv_app : forall S G f a T,
  has_type S G (tapp f a) T ->
  (exists A B, has_type S G f (BArrow A B) /\ has_type S G a A /\ rsub B T)
  \/
  (exists ofs proto M Self A R,
     f = tmeta ofs proto /\
     has_type S G (tmeta ofs proto) (BRec M) /\
     In (mm_call, BArrow Self (BArrow A R)) M /\
     rsub (BRec M) Self /\
     has_type S G a A /\ rsub R T).
Proof.
  intros S G f a T H. remember (tapp f a) as e eqn:Ee.
  induction H; try discriminate Ee.
  - (* TApp *) injection Ee as <- <-. left.
    exists A, B. split; [assumption|split;[assumption|apply rsub_refl]].
  - (* TSub *) subst. destruct (IHhas_type eq_refl) as
      [ [A0 [B0 [Hf [Ha Hd]]]] | [ofs [proto [M [Self [A0 [R [Ef Hrest]]]]]]] ].
    + left. exists A0, B0. split; [assumption|split;[assumption|eapply RsTrans; eassumption]].
    + right. exists ofs, proto, M, Self, A0, R.
      destruct Hrest as [Htbl [Hin [Hself [Ha Hd]]]].
      split; [assumption|]. split; [assumption|]. split; [assumption|].
      split; [assumption|]. split; [assumption|]. eapply RsTrans; eassumption.
  - (* TCallMeta *) injection Ee as <- <-. right.
    exists ofs, proto, M, Self, A, R.
    split; [reflexivity|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. split; [assumption|]. apply rsub_refl.
Qed.

(* METATABLE [__newindex] — inversion of the write [tnewidx tbl k v]. The table is
   a metatable-table whose own fields omit [k]; the [__newindex] target [proto]
   (read at [BRec Pf]) has a writable cell [(k, BRef T) ∈ Pf]; the written value
   [v : T]; result is [ANil] subsumed to the goal. *)
Lemma inv_newidx : forall S G ofs proto k v T,
  has_type S G (tnewidx ofs proto k v) T ->
  exists Town Pf U,
    has_fields S G ofs Town /\ NoDup (map fst Town) /\
    key_in k Town = false /\
    has_type S G proto (BRec Pf) /\ NoDup (map fst Pf) /\ In (k, BRef U) Pf /\
    has_type S G v U /\ rsub (BAtom ANil) T.
Proof.
  intros S G ofs proto k v T H. remember (tnewidx ofs proto k v) as e eqn:Ee.
  induction H; try discriminate Ee.
  - (* TSub *) subst. destruct (IHhas_type eq_refl) as
      [Town [Pf [U Hrest]]].
    exists Town, Pf, U.
    destruct Hrest as [Hfs [Hno [Hni [Hp [Hnp [Hin [Hv Hd]]]]]]].
    split; [assumption|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. eapply RsTrans; eassumption.
  - (* TNewIdx *) injection Ee as <- <- <- <-.
    eexists Town, Pf, _.
    split; [eassumption|]. split; [eassumption|].
    split; [eassumption|]. split; [eassumption|]. split; [eassumption|].
    split; [eassumption|]. split; [eassumption|]. apply rsub_refl.
Qed.

(* RAW READ — inversion of [trawget ofs proto k]. The own field-list types
   EXACTLY ([has_fields], NoDup keys), [k] is a DIRECT own field [(k,U) ∈ Town],
   the prototype is a [BRec], and the read type [U] subsumes (via [TSub]) to the
   observed [T]. *)
Lemma inv_rawget : forall S G ofs proto k T,
  has_type S G (trawget ofs proto k) T ->
  exists Town Pf U,
    has_fields S G ofs Town /\ NoDup (map fst Town) /\
    In (k, U) Town /\
    has_type S G proto (BRec Pf) /\ NoDup (map fst Pf) /\ rsub U T.
Proof.
  intros S G ofs proto k T H. remember (trawget ofs proto k) as e eqn:Ee.
  induction H; try discriminate Ee.
  - (* TSub *) subst. destruct (IHhas_type eq_refl) as [Town [Pf [U Hrest]]].
    exists Town, Pf, U.
    destruct Hrest as [Hfs [Hno [Hin [Hp [Hnp Hd]]]]].
    split; [assumption|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. split; [assumption|]. eapply RsTrans; eassumption.
  - (* TRawGet *) injection Ee as <- <- <-.
    eexists Town, Pf, _.
    split; [eassumption|]. split; [eassumption|]. split; [eassumption|].
    split; [eassumption|]. split; [eassumption|]. apply rsub_refl.
Qed.

(* RAW WRITE — inversion of [trawset ofs proto k v]. The own field-list types
   EXACTLY, [k] is a DIRECT own field whose cell is writable [(k, BRef U) ∈ Town],
   the prototype is a [BRec], the value types at [U], and [nil] subsumes to [T]. *)
Lemma inv_rawset : forall S G ofs proto k v T,
  has_type S G (trawset ofs proto k v) T ->
  exists Town Pf U,
    has_fields S G ofs Town /\ NoDup (map fst Town) /\
    In (k, BRef U) Town /\
    has_type S G proto (BRec Pf) /\ NoDup (map fst Pf) /\
    has_type S G v U /\ rsub (BAtom ANil) T.
Proof.
  intros S G ofs proto k v T H. remember (trawset ofs proto k v) as e eqn:Ee.
  induction H; try discriminate Ee.
  - (* TSub *) subst. destruct (IHhas_type eq_refl) as [Town [Pf [U Hrest]]].
    exists Town, Pf, U.
    destruct Hrest as [Hfs [Hno [Hin [Hp [Hnp [Hv Hd]]]]]].
    split; [assumption|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. split; [assumption|]. split; [assumption|].
    eapply RsTrans; eassumption.
  - (* TRawSet *) injection Ee as <- <- <- <-.
    eexists Town, Pf, _.
    split; [eassumption|]. split; [eassumption|]. split; [eassumption|].
    split; [eassumption|]. split; [eassumption|]. split; [eassumption|].
    apply rsub_refl.
Qed.

(* METATABLE UNARY METAMETHOD — inversion of [tunop uop e]. The operand is a
   metatable-table [tmeta ofs proto : BRec M] whose read interface carries the
   unary metamethod [mm_unop uop : Self -> Self -> R]; the table's merged record
   [rsub]'s [Self]; result [R] subsumed to [T]. (Subsumption-transparent, like the
   binary [inv_prim] but without the numeric path — [tunop] has no numeric form.) *)
Lemma inv_unop : forall S G uop e T,
  has_type S G (tunop uop e) T ->
  exists ofs proto M Self Other R,
    e = tmeta ofs proto /\
    has_type S G (tmeta ofs proto) (BRec M) /\
    In (mm_unop uop, BArrow Self (BArrow Other R)) M /\
    rsub (BRec M) Self /\ rsub (BRec M) Other /\ rsub R T.
Proof.
  intros S G uop e T H. remember (tunop uop e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - (* TSub *) subst. destruct (IHhas_type eq_refl) as
      [ofs [proto [M [Self [Other [R [Ee0 [Htbl [Hin [Hself [Hother Hd]]]]]]]]]]].
    exists ofs, proto, M, Self, Other, R.
    split; [assumption|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. split; [assumption|]. eapply RsTrans; eassumption.
  - (* TUnMetaL *) injection Ee as <- <-. exists ofs, proto, M, Self, Other, R.
    split; [reflexivity|]. split; [assumption|]. split; [assumption|].
    split; [assumption|]. split; [assumption|]. apply rsub_refl.
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

(* TYPE ASCRIPTION inversion (subsumption-transparent). [tannot Ta e : T] means the
   ascribed type [Ta] is [rsub]-below [T] and [e : Ta]. Preservation's strip case
   uses this: the stripped value [v] retains type [T] because the annotation was
   checked ([e : Ta], [Ta <: T]). *)
Lemma inv_annot : forall S G Ta e T,
  has_type S G (tannot Ta e) T ->
  has_type S G e Ta /\ rsub Ta T.
Proof.
  intros S G Ta e T H. remember (tannot Ta e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [He Hd].
    split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <- <-. split; [assumption | apply rsub_refl].
Qed.

(* MULTI-RETURN — inversion lemmas (subsumption-transparent), mirroring the others.
   [inv_ret]: the return-sequence types its components into [Ts], and [BTuple Ts]
   subsumes to [T]. [inv_fst]: the truncated subject is a multivalue, whose head
   type (or [ANil] for the empty tuple) subsumes to [T]. [inv_appspread]: the
   spread consumer is an arrow over a tuple and the arg is that tuple. *)
Lemma inv_ret : forall S G es T,
  has_type S G (tret es) T ->
  exists Ts, has_types S G es Ts /\ rsub (BTuple Ts) T.
Proof.
  intros S G es T H. remember (tret es) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [Ts [Hes Hd]].
    exists Ts. split; [assumption | eapply RsTrans; eassumption].
  - injection Ee as <-. exists Ts. split; [assumption | apply rsub_refl].
Qed.

Lemma inv_fst : forall S G e T,
  has_type S G (tfst e) T ->
  (exists T0 Ts, has_type S G e (BTuple (T0 :: Ts)) /\ rsub T0 T) \/
  (has_type S G e (BTuple []) /\ rsub (BAtom ANil) T).
Proof.
  intros S G e T H. remember (tfst e) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [[T0 [Ts [He Hd]]] | [He Hd]].
    + left. exists T0, Ts. split; [assumption | eapply RsTrans; eassumption].
    + right. split; [assumption | eapply RsTrans; eassumption].
  - (* TFst: hyp is [has_type S G e (BTuple (T :: Ts))], T is the goal's result *)
    injection Ee as <-. left. exists T, Ts. split; [assumption | apply rsub_refl].
  - (* TFstNil: result is [ANil] *)
    injection Ee as <-. right. split; [assumption | apply rsub_refl].
Qed.

Lemma inv_appspread : forall S G g a T,
  has_type S G (tappspread g a) T ->
  exists Ts B, has_type S G g (BArrow (BTuple Ts) B) /\
               has_type S G a (BTuple Ts) /\ rsub B T.
Proof.
  intros S G g a T H. remember (tappspread g a) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [Ts [B [Hg [Ha Hd]]]].
    exists Ts, B. split; [assumption|split;[assumption|eapply RsTrans; eassumption]].
  - injection Ee as <- <-. exists Ts, B.
    split; [assumption|split;[assumption|apply rsub_refl]].
Qed.

(* VARARG — inversion of the variadic call [tvapp f a rs] (subsumption-transparent,
   mirroring [inv_app] / [inv_appspread]). The variadic function is a two-binder
   curried arrow [BArrow T (BArrow (BTuple Ts) B)]; the fixed arg is [: T]; the
   trailing args are [: Ts] pointwise; and [B] subsumes to the result. *)
Lemma inv_vapp : forall S G f a rs R,
  has_type S G (tvapp f a rs) R ->
  exists Tf Ts B, has_type S G f (BArrow Tf (BArrow (BTuple Ts) B)) /\
                  has_type S G a Tf /\ has_types S G rs Ts /\ rsub B R.
Proof.
  intros S G f a rs R H. remember (tvapp f a rs) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [Tf [Ts [B [Hf [Ha [Hrs Hd]]]]]].
    exists Tf, Ts, B.
    split; [assumption|split;[assumption|split;[assumption|eapply RsTrans; eassumption]]].
  - injection Ee as <- <- <-. exists T, Ts, B.
    split; [assumption|split;[assumption|split;[assumption|apply rsub_refl]]].
Qed.

(* MULTIPLE-ASSIGNMENT — inversion of [tmassign rs rhs] (subsumption-transparent,
   mirroring [inv_vapp]). The result is always [BAtom ANil]; the targets type
   pointwise as [map BRef Tgts]; the RHS at [BTuple Ss]; and the adjusted source
   types [pad_ty]-subtype the target cells. The subsumed result subsumes from
   [BAtom ANil]. *)
Lemma inv_massign : forall S G rs rhs R,
  has_type S G (tmassign rs rhs) R ->
  exists Tgts Ss, has_types S G rs (map BRef Tgts) /\
                  has_type S G rhs (BTuple Ss) /\
                  Forall2 rsub (pad_ty Ss (Datatypes.length Tgts)) Tgts /\
                  rsub (BAtom ANil) R.
Proof.
  intros S G rs rhs R H. remember (tmassign rs rhs) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl) as [Tgts [Ss [Hrs [Hrhs [Hadj Hd]]]]].
    exists Tgts, Ss.
    split; [assumption|split;[assumption|split;[assumption|eapply RsTrans; eassumption]]].
  - injection Ee as <- <-. exists Tgts, Ss.
    split; [assumption|split;[assumption|split;[assumption|apply rsub_refl]]].
Qed.

(* METATABLES — inversion of [tmeta own proto]. Reading through subsumption, a
   metatable-table types at any [T] [rsub]-above the MERGED read record [BRec
   (merge_fields Town Pfields)], where [own : BRec Town] (NoDup keys) and [proto :
   BRec Pfields] (NoDup keys). This is what lets the proj cases recover the own /
   prototype field suppliers and the merge structure. *)
Lemma inv_meta : forall S G ofs proto T,
  has_type S G (tmeta ofs proto) T ->
  exists Town Pfields,
    has_fields S G ofs Town /\ NoDup (map fst Town) /\
    has_type S G proto (BRec Pfields) /\ NoDup (map fst Pfields) /\
    rsub (BRec (merge_fields Town Pfields)) T.
Proof.
  intros S G ofs proto T H. remember (tmeta ofs proto) as e0 eqn:Ee.
  induction H; try discriminate Ee.
  - subst. destruct (IHhas_type eq_refl)
      as [Town [Pfields [Ho [Hno [Hp [Hnp Hd]]]]]].
    exists Town, Pfields.
    repeat (split; [assumption|]). eapply RsTrans; eassumption.
  - injection Ee as <- <-. exists Town, Pfields.
    repeat (split; [assumption|]). apply rsub_refl.
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
  destruct a; destruct v as [r| | | | | | |]; simpl in Hv, Hav; contradiction.
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
  destruct a; destruct v as [r| | | | | | |]; simpl in Hv; try contradiction;
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
  destruct a; destruct v as [r| | | | | | |]; simpl in Hv, Hav; contradiction.
Qed.

(* an atom is not [rsub]-below a record (semantic). *)
Lemma rsub_atom_not_rec : forall a g, ~ rsub (BAtom a) (BRec g).
Proof.
  intros a g H. apply rsub_sound in H.
  destruct (atom_has_member a) as [v Hv]. pose proof (H v Hv) as Hav.
  apply denote_rec_iff in Hav. destruct Hav as [ents [Hbad _]].
  destruct a; destruct v as [r| | | | | | |]; simpl in Hv; try contradiction; discriminate Hbad.
Qed.

(* an atom is not [rsub]-below a reference (semantic: atom member is not a loc). *)
Lemma rsub_atom_not_ref : forall a S, ~ rsub (BAtom a) (BRef S).
Proof.
  intros a S H. apply rsub_sound in H.
  destruct (atom_has_member a) as [v Hv]. pose proof (H v Hv) as Hav.
  destruct a; destruct v as [r| | | | | | |]; simpl in Hv, Hav; contradiction.
Qed.
Lemma rsub_atom_not_anyref : forall a, ~ rsub (BAtom a) BAnyRef.
Proof.
  intros a H. apply rsub_sound in H.
  destruct (atom_has_member a) as [v Hv]. pose proof (H v Hv) as Hav.
  destruct a; destruct v as [r| | | | | | |]; simpl in Hv, Hav; contradiction.
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

(* MULTI-RETURN — [rsub] TUPLE-source supertypes (reflexive leaf, like records/
   refs). A [BTuple Ts] relates via [rsub] only via the embedded [ssub] (the ref
   rules need [BRef]/[BAnyRef] sources), and [ssub] treats tuples reflexively, so
   [rsub (BTuple Ts) T] is exactly [rsub_tuple_above Ts T]. *)
Fixpoint rsub_tuple_above (Ts : list BTy) (T : BTy) : Prop :=
  match T with
  | BTop          => True
  | BTuple Ss     => Ss = Ts
  | BUnion Tl Tr  => rsub_tuple_above Ts Tl \/ rsub_tuple_above Ts Tr
  | BInter Tl Tr  => rsub_tuple_above Ts Tl /\ rsub_tuple_above Ts Tr
  | _             => False
  end.

Lemma rsub_tuple_above_ssub_mono : forall M C, ssub M C ->
  forall Ts, rsub_tuple_above Ts M -> rsub_tuple_above Ts C.
Proof.
  intros M C H. induction H; intros Ts0 Hab; simpl in *;
    try exact I; try exact Hab; try contradiction.
  - apply IHssub2. apply IHssub1. exact Hab.
  - left. apply IHssub; exact Hab.
  - right. apply IHssub; exact Hab.
  - destruct Hab as [Ha|Hb]; [ apply IHssub1 | apply IHssub2 ]; assumption.
  - destruct Hab as [Ha _]. apply IHssub; exact Ha.
  - destruct Hab as [_ Hb]. apply IHssub; exact Hb.
  - split; [ apply IHssub1 | apply IHssub2 ]; exact Hab.
Qed.

Lemma rsub_tuple_above_mono : forall M C, rsub M C ->
  forall Ts, rsub_tuple_above Ts M -> rsub_tuple_above Ts C.
Proof.
  intros M C H. induction H; intros Ts0 Hab; simpl in *.
  - eapply rsub_tuple_above_ssub_mono; eassumption.
  - apply IHrsub2. apply IHrsub1. exact Hab.
  - contradiction.
  - contradiction.
Qed.

Lemma rsub_tuple_super : forall Ts T, rsub (BTuple Ts) T -> rsub_tuple_above Ts T.
Proof.
  intros Ts T H. apply (rsub_tuple_above_mono (BTuple Ts) T H Ts). simpl. reflexivity.
Qed.

Lemma rsub_tuple_not_atom : forall Ts a, ~ rsub (BTuple Ts) (BAtom a).
Proof. intros Ts a H. apply rsub_tuple_super in H. simpl in H. exact H. Qed.
Lemma rsub_tuple_not_arrow : forall Ts A B, ~ rsub (BTuple Ts) (BArrow A B).
Proof. intros Ts A B H. apply rsub_tuple_super in H. simpl in H. exact H. Qed.
Lemma rsub_tuple_not_rec : forall Ts g, ~ rsub (BTuple Ts) (BRec g).
Proof. intros Ts g H. apply rsub_tuple_super in H. simpl in H. exact H. Qed.
Lemma rsub_tuple_not_ref : forall Ts S, ~ rsub (BTuple Ts) (BRef S).
Proof. intros Ts S H. apply rsub_tuple_super in H. simpl in H. exact H. Qed.
Lemma rsub_tuple_not_anyref : forall Ts, ~ rsub (BTuple Ts) BAnyRef.
Proof. intros Ts H. apply rsub_tuple_super in H. simpl in H. exact H. Qed.

(* and the reverse: an atom / arrow / record / reference source is NOT [rsub]-below
   a TUPLE (the [_above] predicates send a [BTuple] target to [False]). *)
Lemma rsub_atom_not_tuple : forall a Ts, ~ rsub (BAtom a) (BTuple Ts).
Proof.
  intros a Ts H. apply rsub_sound in H.
  destruct (atom_has_member a) as [v Hv]. pose proof (H v Hv) as Hav.
  apply denote_tuple_iff in Hav. destruct Hav as [vs [Hbad _]].
  destruct a; destruct v as [r| | | | | | |]; simpl in Hv; try contradiction; discriminate Hbad.
Qed.
Lemma rsub_arrow_not_tuple : forall A B Ts, ~ rsub (BArrow A B) (BTuple Ts).
Proof. intros A B Ts H. apply rsub_arrow_super in H. simpl in H. exact H. Qed.
Lemma rsub_rec_not_tuple : forall f Ts, ~ rsub (BRec f) (BTuple Ts).
Proof. intros f Ts H. apply rsub_rec_super in H. simpl in H. exact H. Qed.
Lemma rsub_ref_not_tuple : forall S Ts, ~ rsub (BRef S) (BTuple Ts).
Proof. intros S Ts H. apply rsub_ref_super in H. simpl in H. exact H. Qed.
Lemma rsub_anyref_not_tuple : forall Ts, ~ rsub BAnyRef (BTuple Ts).
Proof. intros Ts H. apply rsub_anyref_super in H. simpl in H. exact H. Qed.

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
  intros S e A B Hty Hv. destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_arrow; eauto.
  - exists T, b; reflexivity.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply rsub_rec_not_arrow; eauto.
  - (* tloc: a location is not [rsub]-below an arrow *)
    apply inv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_arrow; eauto.
  - (* tret: a multivalue is not [rsub]-below an arrow *)
    apply inv_ret in Hty. destruct Hty as [Ts [_ Hsub]].
    exfalso. eapply rsub_tuple_not_arrow; eauto.
  - (* tmeta: a metatable-table (BRec) is not [rsub]-below an arrow *)
    apply inv_meta in Hty. destruct Hty as [Town [Pf [_ [_ [_ [_ Hsub]]]]]].
    exfalso. eapply rsub_rec_not_arrow; eauto.
Qed.

(* METATABLES — canonical form for RECORD type now has TWO table shapes: a plain
   record [trec fs] OR a metatable-table [tmeta own proto] (also a [BRec]-typed
   value, since [TMeta]'s result type is a [BRec]). The projection cases dispatch
   on which one. *)
Lemma canon_rec : forall S e fields,
  has_type S [] e (BRec fields) -> value e ->
  (exists fs, e = trec fs) \/ (exists own proto, e = tmeta own proto).
Proof.
  intros S e fields Hty Hv. destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_rec; eauto.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_rec; eauto.
  - left. exists fs; reflexivity.
  - apply inv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_rec; eauto.
  - apply inv_ret in Hty. destruct Hty as [Ts [_ Hsub]].
    exfalso. eapply rsub_tuple_not_rec; eauto.
  - right. exists own, proto; reflexivity.
Qed.

(* SPLIT-STEP 3 — canonical form for references: a closed value of [BRef T] is a
   location. (Ported from imp.v's [rcanon_ref].) *)
Lemma canon_ref : forall S e T,
  has_type S [] e (BRef T) -> value e -> exists n, e = tloc n.
Proof.
  intros S e T Hty Hv. destruct Hv as [l | Tl b | fs Hfs | n | es Hes | own proto Hvo Hvp].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_ref; eauto.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_ref; eauto.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply rsub_rec_not_ref; eauto.
  - exists n; reflexivity.
  - apply inv_ret in Hty. destruct Hty as [Ts [_ Hsub]].
    exfalso. eapply rsub_tuple_not_ref; eauto.
  - apply inv_meta in Hty. destruct Hty as [Town [Pf [_ [_ [_ [_ Hsub]]]]]].
    exfalso. eapply rsub_rec_not_ref; eauto.
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
  intros S e Hty Hv. destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
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
  - apply inv_ret in Hty. destruct Hty as [Ts [_ Hsub]].
    exfalso. eapply rsub_tuple_not_atom; eauto.
  - apply inv_meta in Hty. destruct Hty as [Town [Pf [_ [_ [_ [_ Hsub]]]]]].
    exfalso. eapply rsub_rec_not_atom; eauto.
Qed.

(* canonical forms for ANY ATOM type: a closed value of type [BAtom al] is a
   literal [tlit l] — every other value shape (lambda / record / location / tuple /
   metatable) is refuted by the corresponding [rsub_*_not_atom] fact. This is what
   the binary RIGHT-operand metamethod fallback needs: a scalar ([BAtom]-typed)
   left operand, when a value, is a literal, hence syntactically not a [tmeta]. *)
Lemma canon_atom : forall S e al,
  has_type S [] e (BAtom al) -> value e -> exists l, e = tlit l.
Proof.
  intros S e al Hty Hv. destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
  - exists l; reflexivity.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_atom; eauto.
  - apply inv_rec in Hty. destruct Hty as [Ts [_ [_ Hsub]]].
    exfalso. eapply rsub_rec_not_atom; eauto.
  - apply inv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_atom; eauto.
  - apply inv_ret in Hty. destruct Hty as [Ts [_ Hsub]].
    exfalso. eapply rsub_tuple_not_atom; eauto.
  - apply inv_meta in Hty. destruct Hty as [Town [Pf [_ [_ [_ [_ Hsub]]]]]].
    exfalso. eapply rsub_rec_not_atom; eauto.
Qed.

(* INCREMENT 11 — canonical forms for Bool: a closed value of type [BAtom ABool]
   is a boolean literal. Needed for [progress]'s [tif] case (the condition is a
   value of Bool type, hence a [LBool]). Non-bool literals are excluded
   SEMANTICALLY (their atom has a member outside [ABool]); lambdas/records are
   excluded by the arrow/record-not-atom shape facts. *)
Lemma canon_bool : forall S e,
  has_type S [] e (BAtom ABool) -> value e -> exists b, e = tlit (LBool b).
Proof.
  intros S e Hty Hv. destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
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
  - apply inv_ret in Hty. destruct Hty as [Ts [_ Hsub]].
    exfalso. eapply rsub_tuple_not_atom; eauto.
  - apply inv_meta in Hty. destruct Hty as [Town [Pf [_ [_ [_ [_ Hsub]]]]]].
    exfalso. eapply rsub_rec_not_atom; eauto.
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
  intros S v U Hty Hv [Hnf Hnm]. unfold truthy_type.
  destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
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
      exfalso. apply Hnf. left. reflexivity.
    + (* LNil : FALSY — excluded *)
      exfalso. apply Hnf. right. reflexivity.
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
  - (* tret: EXCLUDED — a multivalue is not [truthy_value] (it takes the
       truncation path [SIfnMulti]), so [Hnm : ~ is_multi (tret es)] is false. *)
    exfalso. apply Hnm. exists es. reflexivity.
  - (* METATABLES — a metatable-table is a TABLE, hence TRUTHY. Subsume its merged
       record type to [BRec []] (the table arm), inject into the union — exactly
       like a plain record. *)
    apply inv_meta in Hty. destruct Hty as [Town [Pf [Ho [Hno [Hp [Hnp _]]]]]].
    eapply TSub; [ apply (TMeta S [] own proto Town Pf Ho Hno Hp Hnp) | ].
    apply RsSsub.
    apply SsUnionInR. apply SsUnionInR. apply SsUnionInR. apply SsUnionInL.
    apply SsRec. apply SrNil.
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
  intros S v U g Hty Hv Hg. destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
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
  - (* tret: the only matching tag is TgMulti; [tag_type TgMulti = BTop], and every
       value subsumes to [BTop] ([SsTop]) — the sound over-approximation. *)
    destruct g; simpl in Hg; try contradiction. simpl tag_type.
    eapply TSub; [ exact Hty | ]. apply RsSsub. apply SsTop.
  - (* METATABLES — the only matching tag is TgTable; [tag_type TgTable = BRec []].
       Subsume the merged record type to [BRec []] (every table). *)
    destruct g; simpl in Hg; try contradiction. simpl tag_type.
    apply inv_meta in Hty. destruct Hty as [Town [Pf [Ho [Hno [Hp [Hnp _]]]]]].
    eapply TSub; [ apply (TMeta S [] own proto Town Pf Ho Hno Hp Hnp) | ].
    apply RsSsub. apply SsRec. apply SrNil.
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
           (map (fun ke => (fst ke, lift 1 (Datatypes.length G1) (snd ke))) fs) Ts)
    (P1 := fun Sg G es Ts (_ : has_types Sg G es Ts) =>
       forall G1 G2 U, G = G1 ++ G2 ->
         has_types Sg (G1 ++ U :: G2)
           (map (lift 1 (Datatypes.length G1)) es) Ts);
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
  - (* TAnnot *) apply TAnnot.
    match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
      exact (IH G1 G2 U eq_refl) end.
  - (* MULTI-RETURN — TRet: components weaken pointwise (the [P1]/has_types IH). *)
    apply TRet.
    match goal with [ IH : forall _ _ _, _ = _ -> has_types _ _ _ _ |- _ ] =>
      exact (IH G1 G2 U eq_refl) end.
  - (* TFst: the multivalue subject weakens (head type unchanged). *)
    eapply TFst.
    match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
      exact (IH G1 G2 U eq_refl) end.
  - (* TFstNil *) eapply TFstNil.
    match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
      exact (IH G1 G2 U eq_refl) end.
  - (* TAppSpread: both the consumer and the multivalue arg weaken. *)
    eapply TAppSpread;
      match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
  - (* METATABLES — TMeta: own fields (has_fields IH) + prototype weaken; the
       merged type and the [Town]/[Pf] [NoDup] premises are var-context-independent. *)
    apply TMeta;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | assumption
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ proto) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | assumption ].
  - (* METATABLE [__call] — TCallMeta: the table (whole [tmeta]) and the argument
       weaken; the [In]/[rsub] premises are context-independent. *)
    eapply TCallMeta;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ (tmeta _ _)) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption | assumption
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ arg) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end ].
  - (* METATABLE OPERATOR — TPrimMetaL: the table and the right operand [b] weaken. *)
    eapply TPrimMetaL;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ (tmeta _ _)) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption | assumption
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ b) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end ].
  - (* METATABLE OPERATOR — TPrimMetaR: the left operand [a] and the table weaken. *)
    eapply TPrimMetaR;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ a) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ (tmeta _ _)) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption | assumption ].
  - (* METATABLE [__newindex] — TNewIdx: own fields (has_fields IH), prototype, and
       value weaken; [key_in]/[NoDup]/[In] premises are context-independent. *)
    eapply TNewIdx;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | assumption | eassumption
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ proto) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | assumption | eassumption
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ v) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end ].
  - (* METATABLE UNARY METAMETHOD — TUnMetaL: the operand (whole [tmeta]) weakens;
       the [In]/[rsub] premises are context-independent. *)
    eapply TUnMetaL;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ (tmeta _ _)) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption | assumption | assumption ].
  - (* RAW READ — TRawGet: own fields + prototype weaken; [In]/[NoDup] premises
       are context-independent. *)
    eapply TRawGet;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | assumption | eassumption
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ proto) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | assumption ].
  - (* RAW WRITE — TRawSet: own fields + prototype + value weaken; the premises are
       context-independent. *)
    eapply TRawSet;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | assumption | eassumption
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ proto) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | assumption
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ v) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end ].
  - (* VARARG — TVApp: function, fixed arg, and trailing-arg list all weaken. *)
    eapply TVApp;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ f) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ a) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | match goal with [ IH : forall _ _ _, _ = _ -> has_types _ _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end ].
  - (* MULTIPLE-ASSIGNMENT — TMAssign: targets + RHS weaken; [Forall2 rsub] is
       type-level (lift-stable), so it carries unchanged. *)
    eapply TMAssign;
      [ match goal with [ IH : forall _ _ _, _ = _ -> has_types _ _ _ _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ (lift _ _ rhs) _ |- _ ] =>
          exact (IH G1 G2 U eq_refl) end
      | eassumption ].
  - (* HFnil *) apply HFnil.
  - (* HFcons *) apply HFcons.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_fields _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
  - (* MULTI-RETURN — HTnil (empty component list) *) apply HTnil.
  - (* HTcons *) apply HTcons.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_type _ _ _ _ |- _ ] =>
        exact (IH G1 G2 U eq_refl) end.
    + match goal with [ IH : forall _ _ _, _ = _ -> has_types _ _ _ _ |- _ ] =>
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
  (* annotation: body closed at [k] (the type carries no vars). *)
  | tannot _ e => closed_at k e
  (* MULTI-RETURN: no new binders — components / operands closed at [k]. *)
  | tret es => (fix allc (es : list tm) : Prop :=
                  match es with [] => True | e :: rest => closed_at k e /\ allc rest end) es
  | tfst e => closed_at k e
  | tappspread g a => closed_at k g /\ closed_at k a
  (* METATABLES: no new binders — own fields and prototype closed at [k]. *)
  | tmeta own proto =>
      (fix allc (fs : list (string * tm)) : Prop :=
         match fs with
         | [] => True
         | (_, e) :: rest => closed_at k e /\ allc rest
         end) own
      /\ closed_at k proto
  (* __newindex write: no new binders — own fields, proto, and value closed at [k]. *)
  | tnewidx own proto _ v =>
      (fix allc (fs : list (string * tm)) : Prop :=
         match fs with
         | [] => True
         | (_, e) :: rest => closed_at k e /\ allc rest
         end) own
      /\ closed_at k proto /\ closed_at k v
  (* unary metamethod: no new binders — the operand closed at [k]. *)
  | tunop _ e => closed_at k e
  (* RAW ACCESS: no new binders — own fields, proto (and value) closed at [k]. *)
  | trawget own proto _ =>
      (fix allc (fs : list (string * tm)) : Prop :=
         match fs with
         | [] => True
         | (_, e) :: rest => closed_at k e /\ allc rest
         end) own
      /\ closed_at k proto
  | trawset own proto _ v =>
      (fix allc (fs : list (string * tm)) : Prop :=
         match fs with
         | [] => True
         | (_, e) :: rest => closed_at k e /\ allc rest
         end) own
      /\ closed_at k proto /\ closed_at k v
  (* VARARG: no new binders at the CALL — function, fixed arg, and each trailing
     arg closed at [k]. *)
  | tvapp f a rs =>
      closed_at k f /\ closed_at k a /\
      (fix allc (rs : list tm) : Prop :=
         match rs with [] => True | e :: rest => closed_at k e /\ allc rest end) rs
  (* MULTIPLE-ASSIGNMENT: no new binders — each target and the RHS closed at [k]. *)
  | tmassign rs rhs =>
      (fix allc (rs : list tm) : Prop :=
         match rs with [] => True | e :: rest => closed_at k e /\ allc rest end) rs
      /\ closed_at k rhs
  end.

(* typing in [G] bounds free vars by [length G]. By term induction + inversion.
   [S] (store typing) is universally available and threaded through inversion. *)
Lemma has_type_closed : forall e Sg G T, has_type Sg G e T -> closed_at (Datatypes.length G) e.
Proof.
  intro e. induction e using tm_rect_strong with
    (Pl := fun fs => forall Sg G Ts, has_fields Sg G fs Ts ->
       (fix allc (fs : list (string * tm)) : Prop :=
          match fs with [] => True | (_, e) :: rest => closed_at (Datatypes.length G) e /\ allc rest end) fs)
    (Pt := fun es => forall Sg G Ts, has_types Sg G es Ts ->
       (fix allc (es : list tm) : Prop :=
          match es with [] => True | e :: rest => closed_at (Datatypes.length G) e /\ allc rest end) es);
    intros; simpl.
  - exact I.
  - (* tvar *) apply inv_var in H. destruct H as [U [Hl _]].
    apply nth_error_Some. rewrite Hl. discriminate.
  - (* tprim *) apply inv_prim in H.
    destruct H as [ [Ha [Hb _]]
                  | [ [ofs [proto [M [Self [Other [R [Ea Hrest]]]]]]]
                    | [al [ofs [proto [M [Other [R [Eb Hrest]]]]]]] ] ].
    + split; [ exact (IHe1 Sg G (BAtom ANum) Ha) | exact (IHe2 Sg G (BAtom ANum) Hb) ].
    + (* LEFT metamethod: left operand [e1 = tmeta ofs proto : BRec M], right [e2 : Other] *)
      subst e1.
      destruct Hrest as [Htbl [Hin [Hself [Hb _]]]].
      split; [ exact (IHe1 Sg G (BRec M) Htbl) | exact (IHe2 Sg G Other Hb) ].
    + (* RIGHT metamethod: left operand [e1 : BAtom al], right [e2 = tmeta ofs proto : BRec M] *)
      subst e2.
      destruct Hrest as [Ha [Htbl [Hin [Hother _]]]].
      split; [ exact (IHe1 Sg G (BAtom al) Ha) | exact (IHe2 Sg G (BRec M) Htbl) ].
  - (* tlam *) apply inv_lam in H. destruct H as [Tb [Hb _]].
    exact (IHe Sg (T :: G) Tb Hb).
  - (* tapp *) apply inv_app in H.
    destruct H as [ [A [B [Hf [Ha _]]]] | [ofs [proto [M [Self [A [R [Ef Hrest]]]]]]] ].
    + split; [ exact (IHe1 Sg G (BArrow A B) Hf) | exact (IHe2 Sg G A Ha) ].
    + (* [__call]: function [e1 = tmeta ofs proto : BRec M], argument [e2 : A] *)
      subst e1.
      destruct Hrest as [Htbl [Hin [Hself [Ha _]]]].
      split; [ exact (IHe1 Sg G (BRec M) Htbl) | exact (IHe2 Sg G A Ha) ].
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
  - (* tannot *) apply inv_annot in H. destruct H as [He _]. exact (IHe Sg G T He).
  - (* MULTI-RETURN — tret: components closed (the Pt IH over the component list). *)
    apply inv_ret in H. destruct H as [Ts [Hes _]]. exact (IHe Sg G Ts Hes).
  - (* tfst: the multivalue subject is closed. *)
    apply inv_fst in H. destruct H as [[T0 [Ts [He _]]] | [He _]];
      [ exact (IHe Sg G (BTuple (T0 :: Ts)) He) | exact (IHe Sg G (BTuple []) He) ].
  - (* tappspread: both the consumer and the multivalue arg are closed. *)
    apply inv_appspread in H. destruct H as [Ts [B [Hg [Ha _]]]].
    split; [ exact (IHe1 Sg G (BArrow (BTuple Ts) B) Hg) | exact (IHe2 Sg G (BTuple Ts) Ha) ].
  - (* METATABLES — tmeta: all own fields closed (Pl IH) + prototype closed. *)
    apply inv_meta in H. destruct H as [Town [Pf [Ho [_ [Hp [_ _]]]]]].
    split.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_:list (string*BTy)), has_fields _ _ ?xs _ -> _ |- _ ] =>
          exact (IH Sg G Town Ho) end.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_:BTy), has_type _ _ ?x _ -> _,
          Hh : has_type ?Sg0 ?G0 ?x ?Tx |- _ ] => exact (IH Sg G (BRec Pf) Hp) end.
  - (* METATABLE [__newindex] — tnewidx: own fields (Pl IH), proto, value closed. *)
    apply inv_newidx in H.
    destruct H as [Town [Pf [U [Hfs [Hno [Hni [Hp [Hnp [Hin [Hv _]]]]]]]]]].
    split; [ | split ].
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_:list (string*BTy)), has_fields _ _ ?xs _ -> _ |- _ ] =>
          exact (IH Sg G Town Hfs) end.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:BTy),
          has_type _ _ ?x _ -> closed_at _ ?x, Hh : has_type _ _ ?x (BRec _) |- _ ] =>
        exact (IH Sg G (BRec Pf) Hp) end.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:BTy),
          has_type _ _ ?x _ -> closed_at _ ?x, Hh : has_type _ _ ?x U |- _ ] =>
        exact (IH Sg G U Hv) end.
  - (* METATABLE UNARY METAMETHOD — tunop: the operand (a [tmeta]) is closed. *)
    apply inv_unop in H.
    destruct H as [ofs [proto [M [Self [Other [R [Ee [Htbl _]]]]]]]]. subst e.
    exact (IHe Sg G (BRec M) Htbl).
  - (* RAW READ — trawget: own fields (Pl IH) + proto closed. *)
    apply inv_rawget in H. destruct H as [Town [Pf [U [Hfs [_ [_ [Hp [_ _]]]]]]]].
    split.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_:list (string*BTy)), has_fields _ _ ?xs _ -> _ |- _ ] =>
          exact (IH Sg G Town Hfs) end.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:BTy),
          has_type _ _ ?x _ -> closed_at _ ?x, Hh : has_type _ _ ?x (BRec _) |- _ ] =>
        exact (IH Sg G (BRec Pf) Hp) end.
  - (* RAW WRITE — trawset: own fields (Pl IH), proto, value closed. *)
    apply inv_rawset in H.
    destruct H as [Town [Pf [U [Hfs [_ [_ [Hp [_ [Hv _]]]]]]]]].
    split; [ | split ].
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_:list (string*BTy)), has_fields _ _ ?xs _ -> _ |- _ ] =>
          exact (IH Sg G Town Hfs) end.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:BTy),
          has_type _ _ ?x _ -> closed_at _ ?x, Hh : has_type _ _ ?x (BRec _) |- _ ] =>
        exact (IH Sg G (BRec Pf) Hp) end.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:BTy),
          has_type _ _ ?x _ -> closed_at _ ?x, Hh : has_type _ _ ?x U |- _ ] =>
        exact (IH Sg G U Hv) end.
  - (* VARARG — tvapp: function, fixed arg, and trailing-arg list (Pt IH) closed. *)
    apply inv_vapp in H. destruct H as [Tf [Ts [B [Hf [Ha [Hrs _]]]]]].
    split; [ | split ].
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:BTy),
          has_type _ _ ?x _ -> _, Hh : has_type _ _ ?x (BArrow Tf _) |- _ ] =>
          exact (IH Sg G (BArrow Tf (BArrow (BTuple Ts) B)) Hh) end.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:BTy),
          has_type _ _ ?x _ -> _, Hh : has_type _ _ ?x Tf |- _ ] =>
          exact (IH Sg G Tf Hh) end.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:list BTy),
          has_types _ _ ?xs _ -> _, Hh : has_types _ _ ?xs Ts |- _ ] =>
          exact (IH Sg G Ts Hh) end.
  - (* MULTIPLE-ASSIGNMENT — tmassign: target list (Pt IH) + RHS (P IH) closed. *)
    apply inv_massign in H. destruct H as [Tgts [Ss [Hrs [Hrhs [_ _]]]]].
    split.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:list BTy),
          has_types _ _ ?xs _ -> _, Hh : has_types _ _ ?xs (map BRef Tgts) |- _ ] =>
          exact (IH Sg G (map BRef Tgts) Hh) end.
    + match goal with [ IH : forall (_:list BTy)(_:list BTy)(_:BTy),
          has_type _ _ ?x _ -> _, Hh : has_type _ _ ?x (BTuple Ss) |- _ ] =>
          exact (IH Sg G (BTuple Ss) Hh) end.
  - (* Pl nil *) exact I.
  - (* Pl cons *) inversion H; subst. simpl. split.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_:BTy), has_type _ _ ?x _ -> _,
          Hh : has_type ?Sg0 ?G0 ?x ?Tx |- _ ] => exact (IH Sg0 G0 Tx Hh) end.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_: list (string*BTy)), has_fields _ _ ?xs _ -> _,
          Hh : has_fields ?Sg0 ?G0 ?xs ?Tsx |- _ ] => exact (IH Sg0 G0 Tsx Hh) end.
  - (* MULTI-RETURN — Pt nil *) exact I.
  - (* Pt cons *) inversion H; subst. simpl. split.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_:BTy), has_type _ _ ?x _ -> _,
          Hh : has_type ?Sg0 ?G0 ?x ?Tx |- _ ] => exact (IH Sg0 G0 Tx Hh) end.
    + match goal with
      | [ IH : forall (_:list BTy)(_:list BTy)(_: list BTy), has_types _ _ ?xs _ -> _,
          Hh : has_types ?Sg0 ?G0 ?xs ?Tsx |- _ ] => exact (IH Sg0 G0 Tsx Hh) end.
Qed.

(* a term closed below [k] is invariant under lifting with cut >= k. *)
Lemma closed_at_lift : forall e k, closed_at k e -> forall d j, k <= j -> lift d j e = e.
Proof.
  intro e. induction e using tm_rect_strong with
    (Pl := fun fs => forall k, (fix allc (fs : list (string * tm)) : Prop :=
             match fs with [] => True | (_, e) :: rest => closed_at k e /\ allc rest end) fs ->
           forall d j, k <= j ->
             map (fun ke => (fst ke, lift d j (snd ke))) fs = fs)
    (Pt := fun es => forall k, (fix allc (es : list tm) : Prop :=
             match es with [] => True | e :: rest => closed_at k e /\ allc rest end) es ->
           forall d j, k <= j -> map (lift d j) es = es);
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
  - (* tannot *) f_equal. apply (IHe k); [exact H | exact H0].
  - (* MULTI-RETURN — tret: components lift-invariant (the Pt IH). *)
    f_equal. apply (IHe k); [exact H | exact H0].
  - (* tfst *) f_equal. apply (IHe k); [exact H | exact H0].
  - (* tappspread *) destruct H as [H1 H2]. f_equal;
      [ apply (IHe1 k); [exact H1 | exact H0] | apply (IHe2 k); [exact H2 | exact H0] ].
  - (* METATABLES — tmeta: own fields (Pl IH) + proto lift-invariant. *)
    destruct H as [H1 H2]. f_equal.
    + match goal with
      | [ IH : forall k, _ -> forall d j, k <= j -> map _ ?xs = ?xs |- _ ] =>
          apply (IH k); [exact H1 | exact H0] end.
    + match goal with
      | [ IH : forall k, closed_at k ?x -> forall d j, k <= j -> lift d j ?x = ?x |- _ ] =>
          apply (IH k); [exact H2 | exact H0] end.
  - (* METATABLE [__newindex] — tnewidx: own fields (Pl IH), proto, value lift-inv.
       NB the constructor's string key shadows the nat cut, so reference IHs by
       their conclusion shape and let unification fill the cut ([eapply]). *)
    destruct H as [H1 [H2 H3]]. f_equal;
      [ match goal with
        | [ IH : forall k0, _ -> forall d j, k0 <= j -> map _ ?xs = ?xs |- map _ ?xs = ?xs ] =>
            eapply IH; [exact H1 | exact H0] end
      | match goal with
        | [ IH : forall k0, closed_at k0 ?x -> forall d j, k0 <= j -> lift d j ?x = ?x
            |- lift _ _ ?x = ?x ] => eapply IH; [exact H2 | exact H0] end
      | match goal with
        | [ IH : forall k0, closed_at k0 ?x -> forall d j, k0 <= j -> lift d j ?x = ?x
            |- lift _ _ ?x = ?x ] => eapply IH; [exact H3 | exact H0] end ].
  - (* unary metamethod — tunop: the operand is lift-invariant. *)
    f_equal. apply (IHe k); [exact H | exact H0].
  - (* RAW READ — trawget: own fields (Pl IH) + proto lift-invariant. NB the string
       key shadows the cut — reference IHs by conclusion shape, [eapply]. *)
    destruct H as [H1 H2]. f_equal;
      [ match goal with
        | [ IH : forall k0, _ -> forall d j, k0 <= j -> map _ ?xs = ?xs |- map _ ?xs = ?xs ] =>
            eapply IH; [exact H1 | exact H0] end
      | match goal with
        | [ IH : forall k0, closed_at k0 ?x -> forall d j, k0 <= j -> lift d j ?x = ?x
            |- lift _ _ ?x = ?x ] => eapply IH; [exact H2 | exact H0] end ].
  - (* RAW WRITE — trawset: own fields (Pl IH), proto, value lift-invariant. *)
    destruct H as [H1 [H2 H3]]. f_equal;
      [ match goal with
        | [ IH : forall k0, _ -> forall d j, k0 <= j -> map _ ?xs = ?xs |- map _ ?xs = ?xs ] =>
            eapply IH; [exact H1 | exact H0] end
      | match goal with
        | [ IH : forall k0, closed_at k0 ?x -> forall d j, k0 <= j -> lift d j ?x = ?x
            |- lift _ _ ?x = ?x ] => eapply IH; [exact H2 | exact H0] end
      | match goal with
        | [ IH : forall k0, closed_at k0 ?x -> forall d j, k0 <= j -> lift d j ?x = ?x
            |- lift _ _ ?x = ?x ] => eapply IH; [exact H3 | exact H0] end ].
  - (* VARARG — tvapp: function, fixed arg, and trailing-arg list lift-invariant. *)
    destruct H as [H1 [H2 H3]]. f_equal;
      [ match goal with
        | [ IH : forall k0, closed_at k0 ?x -> forall d j, k0 <= j -> lift d j ?x = ?x
            |- lift _ _ ?x = ?x ] => eapply IH; [exact H1 | exact H0] end
      | match goal with
        | [ IH : forall k0, closed_at k0 ?x -> forall d j, k0 <= j -> lift d j ?x = ?x
            |- lift _ _ ?x = ?x ] => eapply IH; [exact H2 | exact H0] end
      | match goal with
        | [ IH : forall k0, _ -> forall d j, k0 <= j -> map _ ?xs = ?xs |- map _ ?xs = ?xs ] =>
            eapply IH; [exact H3 | exact H0] end ].
  - (* MULTIPLE-ASSIGNMENT — tmassign: target list + RHS lift-invariant. *)
    destruct H as [H1 H2]. f_equal;
      [ match goal with
        | [ IH : forall k0, _ -> forall d j, k0 <= j -> map _ ?xs = ?xs |- map _ ?xs = ?xs ] =>
            eapply IH; [exact H1 | exact H0] end
      | match goal with
        | [ IH : forall k0, closed_at k0 ?x -> forall d j, k0 <= j -> lift d j ?x = ?x
            |- lift _ _ ?x = ?x ] => eapply IH; [exact H2 | exact H0] end ].
  - (* Pl nil *) reflexivity.
  - (* Pl cons *) destruct H as [Hc Hr]. f_equal;
      [ f_equal; apply (IHe k0); [exact Hc | exact H0]
      | apply (IHe0 k0); [exact Hr | exact H0] ].
  - (* MULTI-RETURN — Pt nil *) reflexivity.
  - (* Pt cons *) destruct H as [Hc Hr]. f_equal;
      [ apply (IHe k); [exact Hc | exact H0]
      | apply (IHe0 k); [exact Hr | exact H0] ].
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
         (map (fun ke => (fst ke, subst (Datatypes.length G1) s (snd ke))) fs) Ts)
    (Pt := fun es => forall Sg G1 G2 U Ts s,
       has_types Sg (G1 ++ U :: G2) es Ts ->
       has_type Sg [] s U ->
       has_types Sg (G1 ++ G2)
         (map (subst (Datatypes.length G1) s) es) Ts);
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
  - (* tprim *) apply inv_prim in H.
    destruct H as [ [Ha [Hb Hres]]
                  | [ [ofs [proto [M [Self [Other [R [Ea Hrest]]]]]]]
                    | [al [ofs [proto [M [Other [R [Eb Hrest]]]]]] ] ] ]; simpl.
    + (* NUMERIC path *)
      pose proof (IHe1 Sg G1 G2 U (BAtom ANum) s Ha H0) as Ha'.
      pose proof (IHe2 Sg G1 G2 U (BAtom ANum) s Hb H0) as Hb'.
      destruct Hres as [[Har Hd] | [Hcr Hd]].
      * eapply TSub; [ apply TPrimArith; [ exact Har | exact Ha' | exact Hb' ] | exact Hd ].
      * eapply TSub; [ apply TPrimCmp; [ exact Hcr | exact Ha' | exact Hb' ] | exact Hd ].
    + (* LEFT METAMETHOD path: left operand [tmeta ofs proto : BRec M], reconstruct
         TPrimMetaL via the whole-table IH (substitution preserves [BRec M]). *)
      subst e1.
      destruct Hrest as [Htbl [Hin [Hself [Hb Hd]]]].
      eapply TSub; [ eapply (TPrimMetaL Sg (G1 ++ G2) _ _ _ M Self Other R) | exact Hd ].
      * match goal with
        | [ IH : forall _ _ _ _ _ _, has_type _ _ (tmeta ofs proto) _ -> _ -> has_type _ _ _ _ |- _ ] =>
            apply (IH Sg G1 G2 U (BRec M) s); [ exact Htbl | exact H0 ] end.
      * exact Hin.
      * exact Hself.
      * apply (IHe2 Sg G1 G2 U Other s); [ exact Hb | exact H0 ].
    + (* RIGHT METAMETHOD path (mirror): right operand [tmeta ofs proto : BRec M],
         left [e1 : BAtom al] (a scalar — its type is stable under substitution, so
         TPrimMetaR re-applies directly). *)
      subst e2.
      destruct Hrest as [Ha [Htbl [Hin [Hother Hd]]]].
      eapply TSub; [ eapply (TPrimMetaR Sg (G1 ++ G2) _ _ al _ _ M Other R) | exact Hd ].
      * apply (IHe1 Sg G1 G2 U (BAtom al) s); [ exact Ha | exact H0 ].
      * match goal with
        | [ IH : forall _ _ _ _ _ _, has_type _ _ (tmeta ofs proto) _ -> _ -> has_type _ _ _ _ |- _ ] =>
            apply (IH Sg G1 G2 U (BRec M) s); [ exact Htbl | exact H0 ] end.
      * exact Hin.
      * exact Hother.
  - (* tlam *) apply inv_lam in H. destruct H as [Tb [Hb Hsub]]. simpl.
    eapply TSub; [ apply TLam | exact Hsub ].
    rewrite (closed_lift s H0 1 0).
    apply (IHe Sg (T :: G1) G2 U Tb s); [ exact Hb | exact H0 ].
  - (* tapp *) apply inv_app in H.
    destruct H as [ [A [B [Hf [Ha Hsub]]]] | [ofs [proto [M [Self [A [R [Ef Hrest]]]]]]] ]; simpl.
    + eapply TSub; [ eapply TApp | exact Hsub ].
      * apply (IHe1 Sg G1 G2 U (BArrow A B) s); [ exact Hf | exact H0 ].
      * apply (IHe2 Sg G1 G2 U A s); [ exact Ha | exact H0 ].
    + (* [__call] path: function [tmeta ofs proto : BRec M], reconstruct TCallMeta
         via the whole-table IH (substitution preserves [BRec M]). *)
      subst e1.
      destruct Hrest as [Htbl [Hin [Hself [Ha Hd]]]].
      eapply TSub; [ eapply (TCallMeta Sg (G1 ++ G2) _ _ M Self A R) | exact Hd ].
      * match goal with
        | [ IH : forall _ _ _ _ _ _, has_type _ _ (tmeta ofs proto) _ -> _ -> has_type _ _ _ _ |- _ ] =>
            apply (IH Sg G1 G2 U (BRec M) s); [ exact Htbl | exact H0 ] end.
      * exact Hin.
      * exact Hself.
      * apply (IHe2 Sg G1 G2 U A s); [ exact Ha | exact H0 ].
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
  - (* tannot *) apply inv_annot in H. destruct H as [He Hsub]. simpl.
    eapply TSub; [ apply TAnnot | exact Hsub ].
    apply (IHe Sg G1 G2 U T s); [ exact He | exact H0 ].
  - (* MULTI-RETURN — tret: substitute into each component (the Pt IH). *)
    apply inv_ret in H. destruct H as [Ts [Hes Hsub]]. simpl.
    eapply TSub; [ apply TRet | exact Hsub ].
    apply (IHe Sg G1 G2 U Ts s); [ exact Hes | exact H0 ].
  - (* tfst: substitute into the multivalue subject; head/empty type preserved. *)
    apply inv_fst in H. destruct H as [[T0 [Ts [He Hsub]]] | [He Hsub]]; simpl.
    + eapply TSub; [ eapply TFst | exact Hsub ].
      apply (IHe Sg G1 G2 U (BTuple (T0 :: Ts)) s); [ exact He | exact H0 ].
    + eapply TSub; [ eapply TFstNil | exact Hsub ].
      apply (IHe Sg G1 G2 U (BTuple []) s); [ exact He | exact H0 ].
  - (* tappspread: substitute into both consumer and multivalue arg. *)
    apply inv_appspread in H. destruct H as [Ts [B [Hg [Ha Hsub]]]]. simpl.
    eapply TSub; [ eapply TAppSpread | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U (BArrow (BTuple Ts) B) s); [ exact Hg | exact H0 ].
    + apply (IHe2 Sg G1 G2 U (BTuple Ts) s); [ exact Ha | exact H0 ].
  - (* METATABLES — tmeta: substitute into own fields (the Pl IH, preserving [Town]
       EXACTLY — no subsumption slack) and the prototype; [Town]/[Pf] and the
       [NoDup] premises are substitution-invariant, so [TMeta] re-applies and the
       merged result type [merge_fields Town Pf] is unchanged. *)
    apply inv_meta in H. destruct H as [Town [Pf [Ho [Hno [Hp [Hnp Hsub]]]]]]. simpl.
    eapply TSub; [ apply (TMeta Sg (G1 ++ G2) _ _ Town Pf) | exact Hsub ].
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_fields _ _ ?xs _ -> _ |- _ ] =>
          apply (IH Sg G1 G2 U Town s); [ exact Ho | exact H0 ] end.
    + exact Hno.
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_type _ _ ?x _ -> _ -> has_type _ _ _ _,
          Hh : has_type _ _ ?x _ |- _ ] =>
          apply (IH Sg G1 G2 U (BRec Pf) s); [ exact Hp | exact H0 ] end.
    + exact Hnp.
  - (* METATABLE [__newindex] — tnewidx: substitute into own fields (Pl IH, EXACT
       [Town]), proto, and value; [Town] (hence [key_in k Town]) and [Pf] preserved,
       so [TNewIdx] re-applies at [ANil]. *)
    apply inv_newidx in H.
    destruct H as [Town [Pf [W [Hfs [Hno [Hni [Hp [Hnp [Hin [Hv Hd]]]]]]]]]].
    simpl.
    eapply TSub; [ apply (TNewIdx Sg (G1 ++ G2) _ _ Town Pf k _ W) | exact Hd ].
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_fields _ _ ?xs _ -> _ |- _ ] =>
          apply (IH Sg G1 G2 U Town s); [ exact Hfs | exact H0 ] end.
    + exact Hno.
    + exact Hni.
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_type _ _ ?x _ -> _ -> has_type _ _ _ _,
          Hh : has_type _ _ ?x (BRec Pf) |- _ ] =>
          apply (IH Sg G1 G2 U (BRec Pf) s); [ exact Hp | exact H0 ] end.
    + exact Hnp.
    + exact Hin.
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_type _ _ ?x _ -> _ -> has_type _ _ _ _,
          Hh : has_type _ _ ?x W |- _ ] =>
          apply (IH Sg G1 G2 U W s); [ exact Hv | exact H0 ] end.
  - (* METATABLE UNARY METAMETHOD — tunop: substitute into the operand (a [tmeta]
       typed [BRec M]); substitution preserves [BRec M] and the [In]/[rsub] premises
       are substitution-invariant, so [TUnMetaL] re-applies at [R]. *)
    apply inv_unop in H.
    destruct H as [ofs [proto [M [Self [Other [R [Ee [Htbl [Hin [Hself [Hother Hd]]]]]]]]]]]. subst e.
    simpl.
    eapply TSub; [ eapply (TUnMetaL Sg (G1 ++ G2) uop _ _ M Self Other R) | exact Hd ].
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_type _ _ ?x _ -> _ -> has_type _ _ _ _,
          Hh : has_type _ _ ?x (BRec M) |- _ ] =>
          apply (IH Sg G1 G2 U (BRec M) s); [ exact Htbl | exact H0 ] end.
    + exact Hin.
    + exact Hself.
    + exact Hother.
  - (* RAW READ — trawget: substitute into own fields (Pl IH, EXACT [Town]) and
       proto; [Town]/[Pf]/[In]/[NoDup] preserved, so [TRawGet] re-applies at [W]. *)
    apply inv_rawget in H.
    destruct H as [Town [Pf [W [Hfs [Hno [Hin [Hp [Hnp Hd]]]]]]]]. simpl.
    eapply TSub; [ apply (TRawGet Sg (G1 ++ G2) _ _ Town Pf k W) | exact Hd ].
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_fields _ _ ?xs _ -> _ |- _ ] =>
          apply (IH Sg G1 G2 U Town s); [ exact Hfs | exact H0 ] end.
    + exact Hno.
    + exact Hin.
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_type _ _ ?x _ -> _ -> has_type _ _ _ _,
          Hh : has_type _ _ ?x (BRec Pf) |- _ ] =>
          apply (IH Sg G1 G2 U (BRec Pf) s); [ exact Hp | exact H0 ] end.
    + exact Hnp.
  - (* RAW WRITE — trawset: substitute into own fields (Pl IH, EXACT [Town]), proto,
       and value; premises preserved, so [TRawSet] re-applies at [ANil]. *)
    apply inv_rawset in H.
    destruct H as [Town [Pf [W [Hfs [Hno [Hin [Hp [Hnp [Hv Hd]]]]]]]]]. simpl.
    eapply TSub; [ apply (TRawSet Sg (G1 ++ G2) _ _ Town Pf k _ W) | exact Hd ].
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_fields _ _ ?xs _ -> _ |- _ ] =>
          apply (IH Sg G1 G2 U Town s); [ exact Hfs | exact H0 ] end.
    + exact Hno.
    + exact Hin.
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_type _ _ ?x _ -> _ -> has_type _ _ _ _,
          Hh : has_type _ _ ?x (BRec Pf) |- _ ] =>
          apply (IH Sg G1 G2 U (BRec Pf) s); [ exact Hp | exact H0 ] end.
    + exact Hnp.
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_type _ _ ?x _ -> _ -> has_type _ _ _ _,
          Hh : has_type _ _ ?x W |- _ ] =>
          apply (IH Sg G1 G2 U W s); [ exact Hv | exact H0 ] end.
  - (* VARARG — tvapp: substitute into the function, the fixed arg, and each
       trailing arg; the curried arrow / tuple types are preserved, so [TVApp]
       re-applies. *)
    apply inv_vapp in H. destruct H as [Tf [Ts [B [Hf [Ha [Hrs Hsub]]]]]]. simpl.
    eapply TSub; [ eapply TVApp | exact Hsub ].
    + apply (IHe1 Sg G1 G2 U (BArrow Tf (BArrow (BTuple Ts) B)) s); [ exact Hf | exact H0 ].
    + apply (IHe2 Sg G1 G2 U Tf s); [ exact Ha | exact H0 ].
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_types _ _ rs _ -> _ |- _ ] =>
          apply (IH Sg G1 G2 U Ts s); [ exact Hrs | exact H0 ] end.
  - (* MULTIPLE-ASSIGNMENT — tmassign: substitute into each target + the RHS; the
       target ref-types / RHS tuple type / [Forall2 rsub] are all preserved, so
       [TMAssign] re-applies (subsumed by [rsub (BAtom ANil) T] from inv). *)
    apply inv_massign in H. destruct H as [Tgts [Ss [Hrs [Hrhs [Hadj Hsub]]]]]. simpl.
    eapply TSub; [ eapply TMAssign | exact Hsub ].
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_types _ _ ?xs _ -> _ -> has_types _ _ _ _,
          Hh : has_types _ _ ?xs (map BRef Tgts) |- _ ] =>
          apply (IH Sg G1 G2 U (map BRef Tgts) s); [ exact Hh | exact H0 ] end.
    + match goal with
      | [ IH : forall _ _ _ _ _ _, has_type _ _ ?x _ -> _ -> has_type _ _ _ _,
          Hh : has_type _ _ ?x (BTuple Ss) |- _ ] =>
          apply (IH Sg G1 G2 U (BTuple Ss) s); [ exact Hh | exact H0 ] end.
    + exact Hadj.
  - (* Pl nil *) inversion H; subst. simpl. apply HFnil.
  - (* Pl cons *) inversion H; subst. simpl. apply HFcons.
    + match goal with [ Hh : has_type ?Sg0 (G1 ++ U :: G2) e ?Tk |- _ ] =>
        apply (IHe Sg0 G1 G2 U Tk s); [ exact Hh | exact H0 ] end.
    + match goal with [ Hh : has_fields ?Sg0 (G1 ++ U :: G2) rest ?Tsk |- _ ] =>
        apply (IHe0 Sg0 G1 G2 U Tsk s); [ exact Hh | exact H0 ] end.
  - (* MULTI-RETURN — Pt nil *) inversion H; subst. simpl. apply HTnil.
  - (* Pt cons *) inversion H; subst. simpl. apply HTcons.
    + match goal with [ Hh : has_type ?Sg0 (G1 ++ U :: G2) e ?Tk |- _ ] =>
        apply (IHe Sg0 G1 G2 U Tk s); [ exact Hh | exact H0 ] end.
    + match goal with [ Hh : has_types ?Sg0 (G1 ++ U :: G2) rest ?Tsk |- _ ] =>
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
       forall S', extends S' S -> has_fields S' G fs Ts)
    (P1 := fun S G es Ts (_ : has_types S G es Ts) =>
       forall S', extends S' S -> has_types S' G es Ts);
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
  - apply TAnnot; apply IHhas_type; exact Hext.
  - (* MULTI-RETURN — TRet *) apply TRet.
    match goal with [ IH : forall _, extends _ _ -> has_types _ _ _ _ |- _ ] => apply IH; exact Hext end.
  - (* TFst *) eapply TFst; apply IHhas_type; exact Hext.
  - (* TFstNil *) eapply TFstNil; apply IHhas_type; exact Hext.
  - (* TAppSpread *) eapply TAppSpread; [ apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext ].
  - (* METATABLES — TMeta: own fields + proto store-weaken; merge type + NoDups stable. *)
    apply TMeta;
      [ match goal with [ IH : forall _, extends _ _ -> has_fields _ _ _ _ |- _ ] => apply IH; exact Hext end
      | assumption
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ _ _ |- _ ] => apply IH; exact Hext end
      | assumption ].
  - (* METATABLE [__call] — TCallMeta: table + arg store-weaken; In/rsub stable. *)
    eapply TCallMeta;
      [ match goal with [ IH : forall _, extends _ _ -> has_type _ _ (tmeta _ _) _ |- _ ] => apply IH; exact Hext end
      | eassumption | assumption
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x _ |- has_type _ _ ?x _ ] => apply IH; exact Hext end ].
  - (* METATABLE OPERATOR — TPrimMetaL: table + right operand store-weaken. *)
    eapply TPrimMetaL;
      [ match goal with [ IH : forall _, extends _ _ -> has_type _ _ (tmeta _ _) _ |- _ ] => apply IH; exact Hext end
      | eassumption | assumption
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x _ |- has_type _ _ ?x _ ] => apply IH; exact Hext end ].
  - (* METATABLE OPERATOR — TPrimMetaR: left operand + table store-weaken. *)
    eapply TPrimMetaR;
      [ match goal with [ IH : forall _, extends _ _ -> has_type _ _ a _ |- has_type _ _ a _ ] => apply IH; exact Hext end
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ (tmeta _ _) _ |- _ ] => apply IH; exact Hext end
      | eassumption | assumption ].
  - (* METATABLE [__newindex] — TNewIdx: own fields + proto + value store-weaken. *)
    eapply TNewIdx;
      [ match goal with [ IH : forall _, extends _ _ -> has_fields _ _ _ _ |- _ ] => apply IH; exact Hext end
      | assumption | eassumption
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x (BRec _) |- has_type _ _ ?x _ ] => apply IH; exact Hext end
      | assumption | eassumption
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x ?TT |- has_type _ _ ?x ?TT ] => apply IH; exact Hext end ].
  - (* METATABLE UNARY METAMETHOD — TUnMetaL: the operand (whole [tmeta]) store-weakens. *)
    eapply TUnMetaL;
      [ match goal with [ IH : forall _, extends _ _ -> has_type _ _ (tmeta _ _) _ |- _ ] => apply IH; exact Hext end
      | eassumption | assumption | assumption ].
  - (* RAW READ — TRawGet: own fields + proto store-weaken; premises stable. *)
    eapply TRawGet;
      [ match goal with [ IH : forall _, extends _ _ -> has_fields _ _ _ _ |- _ ] => apply IH; exact Hext end
      | assumption | eassumption
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x (BRec _) |- has_type _ _ ?x _ ] => apply IH; exact Hext end
      | assumption ].
  - (* RAW WRITE — TRawSet: own fields + proto + value store-weaken; premises stable. *)
    eapply TRawSet;
      [ match goal with [ IH : forall _, extends _ _ -> has_fields _ _ _ _ |- _ ] => apply IH; exact Hext end
      | assumption | eassumption
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x (BRec _) |- has_type _ _ ?x _ ] => apply IH; exact Hext end
      | assumption
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ ?x _, Hh : has_type _ _ ?x ?TT |- has_type _ _ ?x ?TT ] => apply IH; exact Hext end ].
  - (* VARARG — TVApp: function, fixed arg, and trailing-arg list store-weaken. *)
    eapply TVApp; [ apply IHhas_type1; exact Hext | apply IHhas_type2; exact Hext
                  | apply IHhas_type3; exact Hext ].
  - (* MULTIPLE-ASSIGNMENT — TMAssign: targets + RHS store-weaken; [Forall2 rsub]
       is type-level (store-independent). *)
    eapply TMAssign;
      [ match goal with [ IH : forall _, extends _ _ -> has_types _ _ _ _ |- _ ] =>
          apply IH; exact Hext end
      | match goal with [ IH : forall _, extends _ _ -> has_type _ _ rhs _ |- _ ] =>
          apply IH; exact Hext end
      | eassumption ].
  - apply HFnil.
  - apply HFcons; [ apply IHhas_type; exact Hext | apply IHhas_type0; exact Hext ].
  - (* MULTI-RETURN — HTnil *) apply HTnil.
  - (* HTcons *) apply HTcons; [ apply IHhas_type; exact Hext | apply IHhas_type0; exact Hext ].
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

(* MULTI-RETURN — the same split/reassemble for a return-sequence's component list,
   used by the [SRet] left-to-right reduction case of preservation. *)
Lemma has_types_split : forall S G pre e post Ts,
  has_types S G (pre ++ e :: post) Ts ->
  exists Tpre Te Tpost,
    Ts = Tpre ++ Te :: Tpost /\
    has_types S G pre Tpre /\ has_type S G e Te /\ has_types S G post Tpost.
Proof.
  intros S G pre. induction pre as [ | e0 pre IH ]; intros e post Ts H; simpl in *.
  - inversion H; subst. exists [], T, Ts0. simpl.
    repeat split; [ apply HTnil | assumption | assumption ].
  - inversion H; subst.
    match goal with [ Hrec : has_types S G (pre ++ e :: post) ?Tss |- _ ] =>
      destruct (IH e post Tss Hrec) as [Tpre [Te [Tpost [ETs [Hpre [He Hpost]]]]]] end.
    exists (T :: Tpre), Te, Tpost. subst. simpl.
    repeat split; [ apply HTcons; assumption | assumption | assumption ].
Qed.

Lemma has_types_app_replace : forall S G pre e' post Tpre Te Tpost,
  has_types S G pre Tpre ->
  has_type S G e' Te ->
  has_types S G post Tpost ->
  has_types S G (pre ++ e' :: post) (Tpre ++ Te :: Tpost).
Proof.
  intros S G pre e' post Tpre Te Tpost Hpre He' Hpost.
  induction Hpre; simpl.
  - apply HTcons; [ exact He' | exact Hpost ].
  - apply HTcons; [ exact H | exact (IHHpre He' Hpost) ].
Qed.

(* store-weakening for a component list (the [SRet] case needs it for the
   unchanged components after extending the store typing). *)
Lemma has_types_store_weaken : forall S G es Ts,
  has_types S G es Ts -> forall S', extends S' S -> has_types S' G es Ts.
Proof.
  intros S G es Ts H. induction H; intros S' Hext.
  - apply HTnil.
  - apply HTcons; [ eapply store_weakening; eassumption | apply IHhas_types; exact Hext ].
Qed.

(* ===========================================================================
   METATABLES — structural facts about the flattened [merge_fields] read type.
   These connect the projection-dispatch op-sem to the merged typing: an OWN key
   keeps own's type in the merge; a non-own key takes the prototype's type; and
   the merge has [NoDup] keys (so projection's first-match agrees).
   =========================================================================== *)

(* [key_in] reflects key membership of the field-list. *)
Lemma key_in_iff : forall k (fs : list (string * BTy)),
  key_in k fs = true <-> In k (map fst fs).
Proof.
  intros k fs. induction fs as [ | [k0 T0] fs IH ]; simpl.
  - split; [ discriminate | contradiction ].
  - destruct (string_dec k k0) as [Hk | Hk].
    + subst k0. split; [ intros _; left; reflexivity | reflexivity ].
    + split.
      * intro Hin. right. apply IH; exact Hin.
      * intros [Hbad | Hin]; [ symmetry in Hbad; contradiction | apply IH; exact Hin ].
Qed.

(* an OWN field survives into the merge unchanged (own wins). *)
Lemma merge_in_own : forall k T Town Pf,
  In (k, T) Town -> In (k, T) (merge_fields Town Pf).
Proof.
  intros k T Town Pf Hin. unfold merge_fields. apply in_or_app. left. exact Hin.
Qed.

(* a PROTOTYPE field whose key is NOT shadowed by own survives into the merge. *)
Lemma merge_in_proto : forall k T Town Pf,
  In (k, T) Pf -> key_in k Town = false -> In (k, T) (merge_fields Town Pf).
Proof.
  intros k T Town Pf Hin Hns. unfold merge_fields. apply in_or_app. right.
  induction Pf as [ | [k0 T0] Pf IH ]; simpl in *; [ contradiction | ].
  destruct (key_in k0 Town) eqn:Ek0.
  - (* k0 shadowed: it is dropped; (k,T) must be in the tail *)
    destruct Hin as [E | Hin].
    + injection E as <- <-. rewrite Hns in Ek0. discriminate.
    + apply IH; exact Hin.
  - destruct Hin as [E | Hin].
    + injection E as <- <-. left; reflexivity.
    + right. apply IH; exact Hin.
Qed.

(* every key of [drop_shadowed Town Pf] is a key of [Pf] and is NOT an own key. *)
Lemma drop_shadowed_key : forall k Town Pf,
  In k (map fst (drop_shadowed Town Pf)) ->
  In k (map fst Pf) /\ key_in k Town = false.
Proof.
  intros k Town Pf. induction Pf as [ | [k0 T0] Pf IH ]; simpl; [ contradiction | ].
  destruct (key_in k0 Town) eqn:Ek0; simpl.
  - intro Hin. destruct (IH Hin) as [Hk Hns]. split; [ right; exact Hk | exact Hns ].
  - intros [E | Hin].
    + subst k0. split; [ left; reflexivity | exact Ek0 ].
    + destruct (IH Hin) as [Hk Hns]. split; [ right; exact Hk | exact Hns ].
Qed.

(* every key of the merge is an own key or a prototype key (the merge introduces
   no new keys) — the basis for rejecting a genuinely-absent field. *)
Lemma merge_fields_key_in : forall k Town Pf,
  In k (map fst (merge_fields Town Pf)) ->
  In k (map fst Town) \/ In k (map fst Pf).
Proof.
  intros k Town Pf Hin. unfold merge_fields in Hin. rewrite map_app in Hin.
  apply in_app_or in Hin. destruct Hin as [HT | HD].
  - left; exact HT.
  - right. apply (drop_shadowed_key k Town Pf HD).
Qed.

(* the merge has NoDup keys: own keys are distinct; surviving prototype keys are
   distinct (sublist of Pf's) and disjoint from own (they were not shadowed). *)
Lemma merge_fields_nodup : forall Town Pf,
  NoDup (map fst Town) -> NoDup (map fst Pf) ->
  NoDup (map fst (merge_fields Town Pf)).
Proof.
  intros Town Pf Hno Hnp. unfold merge_fields. rewrite map_app.
  apply NoDup_app; [ exact Hno | | ].
  - (* NoDup (map fst (drop_shadowed Town Pf)) — sublist of Pf's keys *)
    clear Hno. induction Pf as [ | [k0 T0] Pf IH ]; simpl; [ constructor | ].
    inversion Hnp as [ | x l Hni Hnp' ]; subst.
    destruct (key_in k0 Town) eqn:Ek0; simpl.
    + apply IH; exact Hnp'.
    + constructor; [ | apply IH; exact Hnp' ].
      intro Hk. apply Hni. apply (drop_shadowed_key k0 Town Pf Hk).
  - (* disjointness: a surviving prototype key is not an own key *)
    intros k Hown Hdrop. apply (drop_shadowed_key k Town Pf) in Hdrop.
    destruct Hdrop as [_ Hns]. apply key_in_iff in Hown.
    rewrite Hown in Hns. discriminate.
Qed.

(* PRESERVATION with the store (references formulation). By induction on the STEP
   over configurations. Non-store reductions keep [S] (witness [extends_refl]);
   congruence cases recurse, getting an extended [S'] and store-weakening the
   unchanged surroundings; [SAlloc] EXTENDS [S]; [SDeref]/[SAssign] keep [S] fixed
   and use the store-well-typedness invariant. *)
(* METATABLE METAMETHODS — a metatable-table steps only to another metatable-table
   (its only reductions are [SMeta1]/[SMeta2], building own fields / the prototype).
   Used in preservation's [SPrim1]/[SApp1] metamethod cases to re-apply
   [TPrimMetaL]/[TCallMeta] (which need the left/function operand syntactically a
   [tmeta]). *)
Lemma tmeta_step_shape : forall own proto st e' st',
  step (tmeta own proto, st) (e', st') ->
  exists own' proto', e' = tmeta own' proto'.
Proof.
  intros own proto st e' st' Hstep.
  inversion Hstep; subst; eauto.
Qed.

(* MULTIPLE-ASSIGNMENT — the arity normalizer COMMUTES with typing: if the RHS
   component values [vs] type pointwise into [Ss], then the ADJUSTED values [pad_tm
   vs n] type pointwise into the ADJUSTED types [pad_ty Ss n]. Truncation drops a
   typed pair from both lists; nil-padding adds [tlit LNil : BAtom ANil] on the term
   side and [BAtom ANil] on the type side (the SAME [TLit] witness). This is exactly
   the producer/consumer symmetry: the adjustment is the SAME on values and types. *)
Lemma pad_commute : forall n S G vs Ss,
  has_types S G vs Ss -> has_types S G (pad_tm vs n) (pad_ty Ss n).
Proof.
  induction n; intros S G vs Ss Hts; simpl.
  - apply HTnil.
  - inversion Hts; subst; simpl.
    + (* vs = [], Ss = [] : pad both with nil *)
      apply HTcons; [ apply (TLit S G LNil) | apply IHn; apply HTnil ].
    + (* vs = e :: es, Ss = T :: Ts : keep the head pair, recurse *)
      apply HTcons; [ assumption | apply IHn; assumption ].
Qed.

(* MULTIPLE-ASSIGNMENT — a pointwise typing pins the list lengths equal. *)
Lemma has_types_length : forall S G es Ts,
  has_types S G es Ts -> List.length es = List.length Ts.
Proof. intros S G es Ts H. induction H; simpl; [ reflexivity | f_equal; assumption ]. Qed.

(* MULTIPLE-ASSIGNMENT — pointwise subsumption of a value list: [vs : As] and [As]
   pointwise [rsub]-below [Bs] gives [vs : Bs] (apply [TSub] at each position). The
   per-assignment subsumption [tassign] allows, lifted to the whole tuple. *)
Lemma has_types_subsume : forall S G vs As Bs,
  has_types S G vs As -> Forall2 rsub As Bs -> has_types S G vs Bs.
Proof.
  intros S G vs As Bs Hts. revert Bs.
  induction Hts; intros Bs Hf2; inversion Hf2; subst.
  - apply HTnil.
  - apply HTcons; [ eapply TSub; eassumption | apply IHHts; assumption ].
Qed.

(* MULTIPLE-ASSIGNMENT — the MULTI-WRITE preserves store well-typedness. Targets
   [rs] are reference cells typed [map BRef Tgts] and are all VALUES (so each is a
   location [tloc n] by [canon_ref]); the adjusted values [vs] type at the CELL types
   [Tgts]. Writing every [v_i] into its cell [n_i] ([store_massign]) preserves
   [store_well_typed S] — the store typing [S] is FIXED (no allocation): this is
   exactly the [SAssign] preservation argument (cell type matches via [inv_loc] +
   [rsub_ref_inv]) iterated over all N targets. *)
Lemma store_massign_preserves : forall S rs Tgts vs st,
  has_types S [] rs (map BRef Tgts) ->
  Forall value rs ->
  has_types S [] vs Tgts ->
  store_well_typed S st ->
  store_well_typed S (store_massign rs vs st).
Proof.
  intros S rs. induction rs as [ | r rs' IH ];
    intros Tgts vs st Hrs Hval Hvs Hwt.
  - (* no targets *) simpl. destruct vs; simpl; exact Hwt.
  - (* rs = r :: rs', so map BRef Tgts = BRef Tgt0 :: ... ⇒ Tgts = Tgt0 :: Tgts' *)
    destruct Tgts as [ | Tgt0 Tgts' ]; simpl in Hrs; inversion Hrs; subst.
    inversion Hval; subst.
    (* the head target is a location value *)
    match goal with [ Hr : has_type S [] r (BRef Tgt0) |- _ ] =>
      destruct (canon_ref S r Tgt0 Hr ltac:(assumption)) as [n En] end. subst r.
    (* the adjusted value list: vs = v :: vs', v : Tgt0 *)
    inversion Hvs; subst.
    simpl.
    (* write v into cell n, preserving well-typedness, then recurse *)
    eapply IH; [ eassumption | assumption | eassumption | ].
    (* store_update n v st is well-typed: cell n has type Tgt0 (inv_loc) and v : Tgt0 *)
    match goal with [ Hr : has_type S [] (tloc n) (BRef Tgt0) |- _ ] =>
      apply inv_loc in Hr; destruct Hr as [W [Hn Href]] end.
    apply rsub_ref_inv in Href. destruct Href as [HWU HUW].
    destruct Hwt as [Hlen Hcells].
    assert (Hnlt : n < List.length st).
    { rewrite <- Hlen. apply nth_error_Some. rewrite Hn. discriminate. }
    split.
    + rewrite store_update_length. exact Hlen.
    + intros m Tm Hm.
      destruct (Nat.eq_dec m n) as [Heq | Hne].
      * subst m. rewrite Hn in Hm. injection Hm as <-.
        rewrite store_lookup_update_eq by assumption.
        (* v : Tgt0; cell typed at W; [rsub Tgt0 W] from [HUW] *)
        eapply TSub; [ eassumption | exact HUW ].
      * rewrite store_lookup_update_neq by (intro Hc; apply Hne; symmetry; exact Hc).
        apply Hcells; exact Hm.
Qed.

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
    apply inv_app in Hty.
    destruct Hty as [ [A [B0 [Hf [Ha Hsub]]]] | [ofs [proto [M [Self [A [R [Ef _]]]]]]] ];
      [ | discriminate Ef ].
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
  - (* SPrim1: reduce the left operand (NUMERIC, LEFT-METAMETHOD, or RIGHT-METAMETHOD) *)
    apply inv_prim in Hty.
    destruct Hty as [ [Ha [Hb Hres]]
                    | [ [ofs [proto [M [Self [Other [R [Ea [Htbl [Hin [Hself [Hb Hd]]]]]]]]]]]
                      | [al [ofs [proto [M [Other [R [Eb [Ha [Htbl [Hin [Hother Hd]]]]]]]]]]] ] ].
    + destruct (IHHstep a st a' st' eq_refl eq_refl Hwt (BAtom ANum) Ha)
        as [S' [Hext [Ha' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      destruct Hres as [[Har Hd] | [Hcr Hd]].
      * eapply TSub; [ apply TPrimArith;
          [ exact Har | exact Ha' | eapply store_weakening; [ exact Hb | exact Hext ] ] | exact Hd ].
      * eapply TSub; [ apply TPrimCmp;
          [ exact Hcr | exact Ha' | eapply store_weakening; [ exact Hb | exact Hext ] ] | exact Hd ].
    + (* LEFT metamethod: left operand [tmeta ofs proto : BRec M] steps; preserved by IH;
         the stepped operand is again a [tmeta] ([tmeta_step_shape]) so [TPrimMetaL]
         re-applies. *)
      subst a.
      destruct (tmeta_step_shape ofs proto st a' st' Hstep) as [own' [proto' Ea']].
      subst a'.
      destruct (IHHstep (tmeta ofs proto) st (tmeta own' proto') st' eq_refl eq_refl Hwt (BRec M) Htbl)
        as [S' [Hext [Htbl' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply (TPrimMetaL S' [] op own' proto' M Self Other R) | exact Hd ].
      * exact Htbl'.
      * exact Hin.
      * exact Hself.
      * eapply store_weakening; [ exact Hb | exact Hext ].
    + (* RIGHT metamethod: left operand [a : BAtom al] steps; right table unchanged;
         [TPrimMetaR] re-applies with the stepped left operand (still [BAtom al]). *)
      subst b.
      destruct (IHHstep a st a' st' eq_refl eq_refl Hwt (BAtom al) Ha)
        as [S' [Hext [Ha' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply (TPrimMetaR S' [] op a' al ofs proto M Other R) | exact Hd ].
      * exact Ha'.
      * eapply store_weakening; [ exact Htbl | exact Hext ].
      * exact Hin.
      * exact Hother.
  - (* SPrim2: left is a value, reduce the right operand (NUMERIC, LEFT-META, or RIGHT-META) *)
    apply inv_prim in Hty.
    destruct Hty as [ [Ha [Hb Hres]]
                    | [ [ofs [proto [M [Self [Other [R [Ea [Htbl [Hin [Hself [Hb Hd]]]]]]]]]]]
                      | [al [ofs [proto [M [Other [R [Eb [Ha [Htbl [Hin [Hother Hd]]]]]]]]]]] ] ].
    + destruct (IHHstep b st b' st' eq_refl eq_refl Hwt (BAtom ANum) Hb)
        as [S' [Hext [Hb' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      destruct Hres as [[Har Hd] | [Hcr Hd]].
      * eapply TSub; [ apply TPrimArith;
          [ exact Har | eapply store_weakening; [ exact Ha | exact Hext ] | exact Hb' ] | exact Hd ].
      * eapply TSub; [ apply TPrimCmp;
          [ exact Hcr | eapply store_weakening; [ exact Ha | exact Hext ] | exact Hb' ] | exact Hd ].
    + (* LEFT metamethod: left operand is the value [v = tmeta ofs proto]; right operand
         [b : Other] steps; preserved by IH; left operand unchanged. *)
      rewrite Ea in *.
      destruct (IHHstep b st b' st' eq_refl eq_refl Hwt Other Hb)
        as [S' [Hext [Hb' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply (TPrimMetaL S' [] op ofs proto M Self Other R) | exact Hd ].
      * eapply store_weakening; [ exact Htbl | exact Hext ].
      * exact Hin.
      * exact Hself.
      * exact Hb'.
    + (* RIGHT metamethod: the right operand is [tmeta ofs proto : BRec M] and it steps;
         [tmeta_step_shape] keeps it a [tmeta]; [TPrimMetaR] re-applies, left [a]
         unchanged. *)
      subst b.
      destruct (tmeta_step_shape ofs proto st b' st' Hstep) as [own' [proto' Eb']].
      subst b'.
      destruct (IHHstep (tmeta ofs proto) st (tmeta own' proto') st' eq_refl eq_refl Hwt (BRec M) Htbl)
        as [S' [Hext [Htbl' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply (TPrimMetaR S' [] op v al own' proto' M Other R) | exact Hd ].
      * eapply store_weakening; [ exact Ha | exact Hext ].
      * exact Htbl'.
      * exact Hin.
      * exact Hother.
  - (* SPrimArith: both operands are number literals (the NUMERIC path; a metamethod
       operand is a [tmeta], not a number literal — both refuted). *)
    apply inv_prim in Hty.
    destruct Hty as [ [Ha [Hb Hres]]
                    | [ [ofs [proto [M [Self [Other [R [Ea _]]]]]]]
                      | [al [ofs [proto [M [Other [R [Eb _]]]]]] ] ] ];
      [ | discriminate Ea | discriminate Eb ].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    destruct Hres as [[_ Hd] | [Hcr _]].
    + eapply TSub;
        [ eapply TSub; [ apply (TLit S [] (LInt (prim_arith op m n)))
                       | apply RsSsub; apply SsAtom; apply ALInt ]
        | exact Hd ].
    + destruct op; simpl in H, Hcr; discriminate.
  - (* SPrimCmp: both operands are number literals (NUMERIC path; both metamethods refuted). *)
    apply inv_prim in Hty.
    destruct Hty as [ [Ha [Hb Hres]]
                    | [ [ofs [proto [M [Self [Other [R [Ea _]]]]]]]
                      | [al [ofs [proto [M [Other [R [Eb _]]]]] ] ] ] ];
      [ | discriminate Ea | discriminate Eb ].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    destruct Hres as [[Har _] | [_ Hd]].
    + destruct op; simpl in H, Har; discriminate.
    + eapply TSub; [ apply (TLit S [] (LBool (prim_cmp op m n))) | exact Hd ].
  - (* SApp1: function steps (ARROW or METAMETHOD-table function) *)
    apply inv_app in Hty.
    destruct Hty as [ [A [B [Hf [Ha Hsub]]]] | [ofs [proto [M [Self [A [R [Ef [Htbl [Hin [Hself [Ha Hd]]]]]]]]]]] ].
    + destruct (IHHstep f st f' st' eq_refl eq_refl Hwt (BArrow A B) Hf)
        as [S' [Hext [Hf' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply TApp; [ exact Hf' | eapply store_weakening; [ exact Ha | exact Hext ] ] | exact Hsub ].
    + (* metamethod: function [tmeta ofs proto : BRec M] steps; preserved by IH; the
         stepped function is again a [tmeta] ([tmeta_step_shape]) so [TCallMeta]
         re-applies. *)
      subst f.
      destruct (tmeta_step_shape ofs proto st f' st' Hstep) as [own' [proto' Ef']].
      subst f'.
      destruct (IHHstep (tmeta ofs proto) st (tmeta own' proto') st' eq_refl eq_refl Hwt (BRec M) Htbl)
        as [S' [Hext [Htbl' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply (TCallMeta S' [] own' proto' M Self A R) | exact Hd ].
      * exact Htbl'.
      * exact Hin.
      * exact Hself.
      * eapply store_weakening; [ exact Ha | exact Hext ].
  - (* SApp2: function is a VALUE, argument steps (ARROW or METAMETHOD) *)
    apply inv_app in Hty.
    destruct Hty as [ [A [B [Hf [Ha Hsub]]]] | [ofs [proto [M [Self [A [R [Ef [Htbl [Hin [Hself [Ha Hd]]]]]]]]]]] ].
    + destruct (IHHstep a st a' st' eq_refl eq_refl Hwt A Ha)
        as [S' [Hext [Ha' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply TApp; [ eapply store_weakening; [ exact Hf | exact Hext ] | exact Ha' ] | exact Hsub ].
    + (* metamethod: function is the value [v = tmeta ofs proto]; argument [a : A]
         steps; preserved by IH; function unchanged. *)
      rewrite Ef in *.
      destruct (IHHstep a st a' st' eq_refl eq_refl Hwt A Ha)
        as [S' [Hext [Ha' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply (TCallMeta S' [] ofs proto M Self A R) | exact Hd ].
      * eapply store_weakening; [ exact Htbl | exact Hext ].
      * exact Hin.
      * exact Hself.
      * exact Ha'.
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
  - (* MULTI-RETURN — SIfnMultiCons: a multivalue scrutinee TRUNCATES to its head
       before the test. The branches are unchanged; the new scrutinee [v] (the head)
       is typed via [inv_ret] on the old scrutinee. The result type is preserved
       (the [tifn] result depends on the branch types, not the scrutinee type). *)
    apply inv_ifn in Hty. destruct Hty as [U [T1 [T2 [Hc [H1 [H2 Hsub]]]]]].
    apply inv_ret in Hc. destruct Hc as [Ts [Hts _]].
    inversion Hts; subst.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ eapply TIfn; [ eassumption | exact H1 | exact H2 ] | exact Hsub ].
  - (* SIfnMultiNil: the empty multivalue truncates to [nil]. *)
    apply inv_ifn in Hty. destruct Hty as [U [T1 [T2 [Hc [H1 [H2 Hsub]]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ eapply TIfn; [ apply (TLit S [] LNil) | exact H1 | exact H2 ] | exact Hsub ].
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
  - (* SAnnot1: congruence under the annotation — preserves the annotation type. *)
    apply inv_annot in Hty. destruct Hty as [He Hsub].
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt T He) as [S' [Hext [He' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ apply TAnnot; exact He' | exact Hsub ].
  - (* SAnnotV: strip the annotation off a value — the value retains [T0] because
       the body was typed at the ascribed type [T] (= [Ta] from inv_annot) which
       subsumes to [T0]. *)
    apply inv_annot in Hty. destruct Hty as [Hv Hsub].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ exact Hv | exact Hsub ].
  (* MULTI-RETURN — preservation for the new reductions. *)
  - (* SRet: step one component of the return-sequence (left-to-right). The
       stepped component keeps its type (IH); the tuple type [BTuple Ts] is
       preserved, and subsumes to [T0]. *)
    apply inv_ret in Hty. destruct Hty as [Ts [Hts Hsub]].
    apply has_types_split in Hts.
    destruct Hts as [Tpre [Te [Tpost [ETs [Hpre [Hfe Hpost]]]]]]. subst Ts.
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt Te Hfe)
      as [S' [Hext [Hfe' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ apply TRet | exact Hsub ].
    eapply has_types_app_replace;
      [ eapply has_types_store_weaken; [ exact Hpre | exact Hext ]
      | exact Hfe'
      | eapply has_types_store_weaken; [ exact Hpost | exact Hext ] ].
  - (* SFstCons: TRUNCATION reduces [tfst (tret (v::rest))] to its head [v]. The
       head's component type is the tuple's head type, which subsumes to [T0]. *)
    apply inv_fst in Hty. destruct Hty as [[T0' [Ts [Htup Hsub]]] | [Htup _]].
    + (* non-empty: the multivalue is at [BTuple (T0'::Ts)]; its head [v : T0']. *)
      apply inv_ret in Htup. destruct Htup as [Tss [Hts Htsub]].
      inversion Hts; subst.
      (* [rsub (BTuple (T::Ts0)) (BTuple (T0'::Ts))] ⇒ head type [T = T0'] *)
      apply rsub_tuple_super in Htsub. simpl in Htsub. injection Htsub as <- <-.
      exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
      eapply TSub; [ eassumption | exact Hsub ].
    + (* the empty-tuple inversion branch cannot apply: [tret (v::rest)] is not
         [: BTuple []] (its component list is non-empty). *)
      apply inv_ret in Htup. destruct Htup as [Tss [Hts Htsub]].
      apply rsub_tuple_super in Htsub. simpl in Htsub. subst Tss.
      inversion Hts.
  - (* SFstNil: the empty multivalue truncates to [nil : ANil], subsumed to [T0]. *)
    apply inv_fst in Hty. destruct Hty as [[T0' [Ts [Htup _]]] | [Htup Hsub]].
    + (* the non-empty inversion cannot apply to [tret []] *)
      apply inv_ret in Htup. destruct Htup as [Tss [Hts Htsub]].
      apply rsub_tuple_super in Htsub. simpl in Htsub. subst Tss.
      inversion Hts.
    + exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
      eapply TSub; [ apply (TLit S [] LNil) | exact Hsub ].
  - (* SFst1: congruence — step the multivalue subject. *)
    apply inv_fst in Hty. destruct Hty as [[T0' [Ts [He Hsub]]] | [He Hsub]].
    + destruct (IHHstep e st e' st' eq_refl eq_refl Hwt (BTuple (T0' :: Ts)) He)
        as [S' [Hext [He' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply TFst; exact He' | exact Hsub ].
    + destruct (IHHstep e st e' st' eq_refl eq_refl Hwt (BTuple []) He)
        as [S' [Hext [He' Hwt']]].
      exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
      eapply TSub; [ eapply TFstNil; exact He' | exact Hsub ].
  - (* SAppSpread: SPREAD beta — [tappspread (\(BTuple Ts).body) mv] substitutes the
       whole multivalue [mv] into [body]. Like [SBeta], using arrow inversion to get
       the contravariant domain ([rsub (BTuple Ts) T] makes [mv : T]) and covariant
       codomain ([rsub Tb B] then [rsub B T0]). *)
    apply inv_appspread in Hty. destruct Hty as [Ts [B0 [Hg [Ha Hsub]]]].
    apply inv_lam in Hg. destruct Hg as [Tb [Hb HsubArr]].
    apply rsub_arrow_inv in HsubArr. destruct HsubArr as [HsA HsB].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    assert (HvTl : has_type S [] mv T) by (eapply TSub; [ exact Ha | exact HsA ]).
    eapply TSub; [ | eapply RsTrans; [ exact HsB | exact Hsub ] ].
    apply (subst_top S T [] body Tb mv); [ exact Hb | exact HvTl ].
  - (* SAppSpread1: congruence — step the consumer. *)
    apply inv_appspread in Hty. destruct Hty as [Ts [B0 [Hg [Ha Hsub]]]].
    destruct (IHHstep g st g' st' eq_refl eq_refl Hwt (BArrow (BTuple Ts) B0) Hg)
      as [S' [Hext [Hg' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TAppSpread;
      [ exact Hg' | eapply store_weakening; [ exact Ha | exact Hext ] ] | exact Hsub ].
  - (* SAppSpread2: congruence — step the multivalue argument. *)
    apply inv_appspread in Hty. destruct Hty as [Ts [B0 [Hg [Ha Hsub]]]].
    destruct (IHHstep a st a' st' eq_refl eq_refl Hwt (BTuple Ts) Ha)
      as [S' [Hext [Ha' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TAppSpread;
      [ eapply store_weakening; [ exact Hg | exact Hext ] | exact Ha' ] | exact Hsub ].
  - (* METATABLES — SMeta1: step the first non-value OWN field (left-to-right),
       exactly like [SRec]. The own field-types [Town] (and hence the merged type)
       are unchanged: the stepped field keeps its type by the IH. *)
    apply inv_meta in Hty. destruct Hty as [Town [Pf [Hfs [Hno [Hp [Hnp Hsub]]]]]].
    apply has_fields_split in Hfs.
    destruct Hfs as [Tpre [Tk [Tpost [ETown [Hpre [Hfe Hpost]]]]]]. subst Town.
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt Tk Hfe)
      as [S' [Hext [Hfe' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TMeta S' [] (pre ++ (k, e') :: post) proto
                            (Tpre ++ (k, Tk) :: Tpost) Pf) | exact Hsub ].
    + eapply has_fields_app_replace;
        [ eapply has_fields_store_weaken; [ exact Hpre | exact Hext ]
        | exact Hfe'
        | eapply has_fields_store_weaken; [ exact Hpost | exact Hext ] ].
    + exact Hno.
    + eapply store_weakening; [ exact Hp | exact Hext ].
    + exact Hnp.
  - (* METATABLES — SMeta2: all own fields are values; step the prototype.
       Preservation: the prototype keeps its type [BRec Pf], so the merge is
       unchanged. *)
    apply inv_meta in Hty. destruct Hty as [Town [Pf [Hfs [Hno [Hp [Hnp Hsub]]]]]].
    destruct (IHHstep proto st proto' st' eq_refl eq_refl Hwt (BRec Pf) Hp)
      as [S' [Hext [Hp' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ apply (TMeta S' [] own proto' Town Pf);
      [ eapply has_fields_store_weaken; [ exact Hfs | exact Hext ]
      | exact Hno | exact Hp' | exact Hnp ]
      | exact Hsub ].
  - (* METATABLES — SMetaProjOwn: the key is a DIRECT (own) field; step to its
       value. SOUNDNESS: [field_lookup k own = Some v] ⇒ [k] is an own key, so the
       merge resolves [k] to OWN's type [Tk] (own wins, [merge_in_own]); the
       projected field [(k,W)] in [fields] matches it via the merge⊆fields
       inversion + [NoDup]; and [field_lookup_typed] gives [v : Tk]. So [v : W]. *)
    apply inv_proj in Hty. destruct Hty as [fields [W [Hsubj [Hin Hsub]]]].
    apply inv_meta in Hsubj. destruct Hsubj as [Town [Pf [Hfs [Hno [Hp [Hnp HsubRec]]]]]].
    pose proof (has_fields_keys S [] own Town Hfs) as Hkeys.
    assert (Hndown : NoDup (map fst own)) by (rewrite Hkeys; exact Hno).
    (* the own value's field-type [Tk] for [k] *)
    destruct (field_lookup_typed S [] own Town k v Hfs Hndown H0) as [Tk [HinTk Hvt]].
    (* [k:Tk] survives into the merge (own wins) *)
    pose proof (merge_in_own k Tk Town Pf HinTk) as HinMerge.
    (* the projected supplier in the merge for the [(k,W)] requirement *)
    pose proof (merge_fields_nodup Town Pf Hno Hnp) as HndM.
    destruct (rsub_rec_inv (merge_fields Town Pf) fields k W HsubRec Hin)
      as [Tg [HinTg HsTg]].
    (* [NoDup] forces the merge's supplier for [k] to be [Tk] *)
    pose proof (nodup_unique_type (merge_fields Town Pf) k Tk Tg HndM HinMerge HinTg) as Heq.
    subst Tg.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ exact Hvt | eapply RsTrans; [ apply RsSsub; exact HsTg | exact Hsub ] ].
  - (* METATABLES — SMetaProjProto: the key is ABSENT from own; fall back to the
       prototype projection. SOUNDNESS: [field_lookup k own = None] ⇒ [k] is NOT an
       own key ([key_in k Town = false]), so the merge resolves [k] to the
       PROTOTYPE's type via [merge_in_proto]; the projected supplier [(k,W)] matches
       it ([NoDup]); and [tproj proto k] types at that prototype field. *)
    apply inv_proj in Hty. destruct Hty as [fields [W [Hsubj [Hin Hsub]]]].
    apply inv_meta in Hsubj. destruct Hsubj as [Town [Pf [Hfs [Hno [Hp [Hnp HsubRec]]]]]].
    (* [k] is not an own key *)
    assert (Hnotown : key_in k Town = false).
    { destruct (key_in k Town) eqn:Ek; [ | reflexivity ].
      apply key_in_iff in Ek.
      (* k a Town key ⇒ k an own field key ⇒ field_lookup would succeed *)
      pose proof (has_fields_keys S [] own Town Hfs) as Hkeys.
      rewrite <- Hkeys in Ek.
      (* but field_lookup k own = None contradicts k ∈ own keys *)
      exfalso. clear -Ek H0.
      induction own as [ | [k0 e0] own IH ]; simpl in *; [ contradiction | ].
      destruct (string_dec k k0) as [Hk | Hk]; [ discriminate H0 | ].
      destruct Ek as [Hbad | Ek]; [ symmetry in Hbad; contradiction | apply IH; assumption ]. }
    (* the merge supplier for the projected [(k,W)] *)
    pose proof (merge_fields_nodup Town Pf Hno Hnp) as HndM.
    destruct (rsub_rec_inv (merge_fields Town Pf) fields k W HsubRec Hin)
      as [Tg [HinTg HsTg]].
    (* [Tg] is a PROTOTYPE field type: the merge entry for [k] came from Pf. We need
       [(k,Tg) ∈ Pf]. From [HinTg : In (k,Tg) (merge Town Pf)] = Town ++ drop... and
       [k] not an own key, it is in the drop_shadowed part, hence in Pf. *)
    assert (HinPf : In (k, Tg) Pf).
    { unfold merge_fields in HinTg. apply in_app_or in HinTg.
      destruct HinTg as [HinT | HinD].
      - (* (k,Tg) in Town ⇒ k an own key, contradicting Hnotown *)
        exfalso. assert (Hkin : In k (map fst Town)) by
          (replace k with (fst (k, Tg)) by reflexivity; apply in_map; exact HinT).
        apply key_in_iff in Hkin. rewrite Hkin in Hnotown. discriminate.
      - (* in drop_shadowed ⇒ in Pf *)
        clear -HinD. induction Pf as [ | [k0 T0] Pf IH ]; simpl in *; [ contradiction | ].
        destruct (key_in k0 Town) eqn:Ek0.
        + right. apply IH; exact HinD.
        + destruct HinD as [E | HinD]; [ injection E as <- <-; left; reflexivity
                                       | right; apply IH; exact HinD ]. }
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    (* [tproj proto k : Tg], then subsume [Tg <: W <: T0] *)
    eapply TSub; [ eapply TProj; [ exact Hp | exact HinPf ]
                 | eapply RsTrans; [ apply RsSsub; exact HsTg | exact Hsub ] ].
  - (* METATABLE [__call] — SCallMeta: [tapp (tmeta own proto) arg] dispatches to
       [(table.__call) table arg]. Typing: the metamethod [tproj table mm_call :
       Self -> A -> R] (table : BRec M, [mm_call ∈ M]); apply to [table : Self]
       (table : BRec M [rsub] Self) giving [A -> R]; apply to [arg : A] giving [R],
       subsumed to [T0]. *)
    apply inv_app in Hty.
    destruct Hty as [ [A0 [B0 [Hf _]]] | [ofs [proto0 [M [Self [A [R [Ef [Htbl [Hin [Hself [Ha Hd]]]]]]]]]]] ];
      [ apply inv_meta in Hf; destruct Hf as [Tw [Pf [_ [_ [_ [_ Hbad]]]]]];
        exfalso; eapply rsub_rec_not_arrow; exact Hbad
      | ].
    injection Ef as <- <-.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ | exact Hd ].
    eapply TApp.
    + eapply TApp.
      * eapply TProj; [ exact Htbl | exact Hin ].
      * eapply TSub; [ exact Htbl | exact Hself ].
    + exact Ha.
  - (* METATABLE OPERATOR — SPrimMetaL: [tprim op (tmeta own proto) b] dispatches to
       [(table.<mm>) table b]. Same shape as SCallMeta: [tproj table (mm_binop op) :
       Self -> Other -> R], applied to [table : Self] and [b : Other], result [R].
       The NUMERIC and RIGHT-fallback disjuncts are refuted: the left operand is a
       [tmeta], which cannot inhabit a [BAtom] type (canonical forms). *)
    apply inv_prim in Hty.
    destruct Hty as [ [Ha [_ _]]
                    | [ [ofs [proto0 [M [Self [Other [R [Ea [Htbl [Hin [Hself [Hb Hd]]]]]]]]]]]
                      | [al [ofs [proto0 [M [Other [R [_ [Ha _]]]]]]] ] ] ];
      [ apply inv_meta in Ha; destruct Ha as [Tw [Pf [_ [_ [_ [_ Hbad]]]]]];
        exfalso; eapply rsub_rec_not_atom; exact Hbad
      | | apply inv_meta in Ha; destruct Ha as [Tw [Pf [_ [_ [_ [_ Hbad]]]]]];
          exfalso; eapply rsub_rec_not_atom; exact Hbad ].
    injection Ea as <- <-.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ | exact Hd ].
    eapply TApp.
    + eapply TApp.
      * eapply TProj; [ exact Htbl | exact Hin ].
      * eapply TSub; [ exact Htbl | exact Hself ].
    + exact Hb.
  - (* METATABLE OPERATOR — SPrimMetaR: [tprim op (tlit l) (tmeta own proto)]
       dispatches to [(table.<mm>) (tlit l) table]. The left operand is a LITERAL, so
       the NUMERIC and LEFT-fallback disjuncts of [inv_prim] are refuted (NUMERIC:
       the right operand [tmeta] cannot be [BAtom ANum] by canonical forms; LEFT: it
       requires the LEFT operand to be a [tmeta], but it is [tlit l] — discriminate).
       We take the RIGHT disjunct: [tproj table (mm_binop op) : BAtom al -> Other -> R],
       applied to [tlit l : BAtom al] and [table : Other], result [R]. *)
    apply inv_prim in Hty.
    destruct Hty as [ [Ha [Hb _]]
                    | [ [ofs [proto0 [M [Self [Other [R [Ea _]]]]]]]
                      | [al [ofs [proto0 [M [Other [R [Eb [Ha [Htbl [Hin [Hother Hd]]]]]]]]]] ] ] ].
    + (* NUMERIC: right operand [tmeta own proto] cannot be [BAtom ANum]. *)
      apply inv_meta in Hb. destruct Hb as [Tw [Pf [_ [_ [_ [_ Hbad]]]]]].
      exfalso; eapply rsub_rec_not_atom; exact Hbad.
    + (* LEFT-meta: requires the LEFT operand [= tmeta], but it is [tlit l]. *)
      discriminate Ea.
    + (* RIGHT-fallback: the principal case. *)
      injection Eb as <- <-.
      exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
      eapply TSub; [ | exact Hd ].
      eapply TApp.
      * eapply TApp.
        -- eapply TProj; [ exact Htbl | exact Hin ].
        -- exact Ha.
      * eapply TSub; [ exact Htbl | exact Hother ].
  - (* METATABLE [__newindex] — SNewIdx: [tnewidx own ni k v] ([k] absent from own)
       dispatches to [tassign (tproj ni k) v]. Typing: [tproj ni k : BRef U] (ni :
       BRec Pf, [(k,BRef U) ∈ Pf]); [tassign (tproj ni k) v : ANil] (cell BRef U,
       [v : U]); subsumed to [T0]. The records-of-refs write-through. *)
    apply inv_newidx in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hni [Hp [Hnp [Hin [Hv Hd]]]]]]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ | exact Hd ].
    eapply TAssign.
    + eapply TProj; [ exact Hp | exact Hin ].
    + exact Hv.
  - (* METATABLE [__newindex] — SNewIdx1: an own field steps. Preserved: own's
       field-types [Town] unchanged (stepped field keeps its type by the IH), so
       [key_in k Town] and the merge are unchanged; [TNewIdx] re-applies. *)
    apply inv_newidx in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hni [Hp [Hnp [Hin [Hv Hd]]]]]]]]]].
    apply has_fields_split in Hfs.
    destruct Hfs as [Tpre [Tk [Tpost [ETown [Hpre [Hfe Hpost]]]]]]. subst Town.
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt Tk Hfe)
      as [S' [Hext [Hfe' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TNewIdx S' [] (pre ++ (k0, e') :: post) proto
                            (Tpre ++ (k0, Tk) :: Tpost) Pf k _ U) | exact Hd ].
    + eapply has_fields_app_replace;
        [ eapply has_fields_store_weaken; [ exact Hpre | exact Hext ]
        | exact Hfe'
        | eapply has_fields_store_weaken; [ exact Hpost | exact Hext ] ].
    + exact Hno.
    + exact Hni.
    + eapply store_weakening; [ exact Hp | exact Hext ].
    + exact Hnp.
    + exact Hin.
    + eapply store_weakening; [ exact Hv | exact Hext ].
  - (* METATABLE [__newindex] — SNewIdx2: the [__newindex] target [proto] steps.
       Preserved: [proto] keeps its type [BRec Pf], merge unchanged. *)
    apply inv_newidx in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hni [Hp [Hnp [Hin [Hv Hd]]]]]]]]]].
    destruct (IHHstep proto st proto' st' eq_refl eq_refl Hwt (BRec Pf) Hp)
      as [S' [Hext [Hp' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TNewIdx S' [] own proto' Town Pf k _ U) | exact Hd ].
    + eapply has_fields_store_weaken; [ exact Hfs | exact Hext ].
    + exact Hno.
    + exact Hni.
    + exact Hp'.
    + exact Hnp.
    + exact Hin.
    + eapply store_weakening; [ exact Hv | exact Hext ].
  - (* METATABLE [__newindex] — SNewIdx3: the written value steps. Preserved: it
       keeps its content type [U]. *)
    apply inv_newidx in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hni [Hp [Hnp [Hin [Hv Hd]]]]]]]]]].
    destruct (IHHstep v st v' st' eq_refl eq_refl Hwt U Hv)
      as [S' [Hext [Hv' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TNewIdx S' [] own proto Town Pf k _ U) | exact Hd ].
    + eapply has_fields_store_weaken; [ exact Hfs | exact Hext ].
    + exact Hno.
    + exact Hni.
    + eapply store_weakening; [ exact Hp | exact Hext ].
    + exact Hnp.
    + exact Hin.
    + exact Hv'.
  - (* METATABLE UNARY METAMETHOD — SUnMetaL: [tunop uop (tmeta own proto)]
       dispatches to [(table.<mm>) table table]. Same shape as SCallMeta/SPrimMetaL:
       [tproj table (mm_unop uop) : Self -> Self -> R], applied to [table : Self]
       TWICE, result [R]. *)
    apply inv_unop in Hty.
    destruct Hty as [ofs [proto0 [M [Self [Other [R [Ee [Htbl [Hin [Hself [Hother Hd]]]]]]]]]]].
    injection Ee as <- <-.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ | exact Hd ].
    eapply TApp.
    + eapply TApp.
      * eapply TProj; [ exact Htbl | exact Hin ].
      * eapply TSub; [ exact Htbl | exact Hself ].
    + eapply TSub; [ exact Htbl | exact Hother ].
  - (* METATABLE UNARY METAMETHOD — SUnop1: the operand [tmeta ofs proto : BRec M]
       steps; preserved by IH; the stepped operand is again a [tmeta]
       ([tmeta_step_shape]) so [TUnMetaL] re-applies. *)
    apply inv_unop in Hty.
    destruct Hty as [ofs [proto0 [M [Self [Other [R [Ee [Htbl [Hin [Hself [Hother Hd]]]]]]]]]]].
    subst e.
    destruct (tmeta_step_shape ofs proto0 st e' st' Hstep) as [own' [proto' Ee']].
    subst e'.
    destruct (IHHstep (tmeta ofs proto0) st (tmeta own' proto') st' eq_refl eq_refl Hwt (BRec M) Htbl)
      as [S' [Hext [Htbl' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TUnMetaL S' [] uop own' proto' M Self Other R) | exact Hd ].
    + exact Htbl'.
    + exact Hin.
    + exact Hself.
    + exact Hother.
  - (* RAW READ — SRawGet: [trawget own proto k] with [field_lookup k own = Some v]
       steps to [v]. SOUNDNESS: the own supplier [(k,U) ∈ Town] (inv_rawget);
       [field_lookup_typed] gives [v : Tk] for the unique own supplier; [NoDup Town]
       forces [Tk = U] ([nodup_unique_type]); so [v : U <: T]. No merge, no prototype
       — the RAW own read. *)
    apply inv_rawget in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hin [Hp [Hnp Hd]]]]]]]].
    pose proof (has_fields_keys S [] own Town Hfs) as Hkeys.
    assert (Hndown : NoDup (map fst own)) by (rewrite Hkeys; exact Hno).
    destruct (field_lookup_typed S [] own Town k v Hfs Hndown H1) as [Tk [HinTk Hvt]].
    pose proof (nodup_unique_type Town k U Tk Hno Hin HinTk) as Heq. subst Tk.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ exact Hvt | exact Hd ].
  - (* RAW READ — SRawGet1: an own field steps. Preserved: own's field-types [Town]
       unchanged (stepped field keeps its type by the IH), so [In (k,U) Town] is
       unchanged; [TRawGet] re-applies. *)
    apply inv_rawget in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hin [Hp [Hnp Hd]]]]]]]].
    apply has_fields_split in Hfs.
    destruct Hfs as [Tpre [Tk [Tpost [ETown [Hpre [Hfe Hpost]]]]]]. subst Town.
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt Tk Hfe)
      as [S' [Hext [Hfe' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TRawGet S' [] (pre ++ (k0, e') :: post) proto
                            (Tpre ++ (k0, Tk) :: Tpost) Pf k U) | exact Hd ].
    + eapply has_fields_app_replace;
        [ eapply has_fields_store_weaken; [ exact Hpre | exact Hext ]
        | exact Hfe'
        | eapply has_fields_store_weaken; [ exact Hpost | exact Hext ] ].
    + exact Hno.
    + exact Hin.
    + eapply store_weakening; [ exact Hp | exact Hext ].
    + exact Hnp.
  - (* RAW READ — SRawGet2: the prototype steps. Preserved: [proto] keeps [BRec Pf];
       own and the result type unchanged. *)
    apply inv_rawget in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hin [Hp [Hnp Hd]]]]]]]].
    destruct (IHHstep proto st proto' st' eq_refl eq_refl Hwt (BRec Pf) Hp)
      as [S' [Hext [Hp' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TRawGet S' [] own proto' Town Pf k U) | exact Hd ].
    + eapply has_fields_store_weaken; [ exact Hfs | exact Hext ].
    + exact Hno.
    + exact Hin.
    + exact Hp'.
    + exact Hnp.
  - (* RAW WRITE — SRawSet: [trawset own proto k v] with [field_lookup k own = Some
       cell] steps to [tassign cell v]. SOUNDNESS: the own supplier [(k, BRef U) ∈
       Town] (inv_rawset); [field_lookup_typed] gives [cell : Tk]; [NoDup Town]
       forces [Tk = BRef U]; so [cell : BRef U] and [v : U], hence [tassign cell v :
       ANil <: T]. The records-of-refs write to OWN's cell — no prototype, no
       absent-from-own dispatch. *)
    apply inv_rawset in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hin [Hp [Hnp [Hv Hd]]]]]]]]].
    pose proof (has_fields_keys S [] own Town Hfs) as Hkeys.
    assert (Hndown : NoDup (map fst own)) by (rewrite Hkeys; exact Hno).
    destruct (field_lookup_typed S [] own Town k cell Hfs Hndown H2) as [Tk [HinTk Hct]].
    pose proof (nodup_unique_type Town k (BRef U) Tk Hno Hin HinTk) as Heq. subst Tk.
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ eapply TAssign; [ exact Hct | exact Hv ] | exact Hd ].
  - (* RAW WRITE — SRawSet1: an own field steps. Preserved: [Town] unchanged, so
       [In (k, BRef U) Town] holds; [TRawSet] re-applies at [ANil]. *)
    apply inv_rawset in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hin [Hp [Hnp [Hv Hd]]]]]]]]].
    apply has_fields_split in Hfs.
    destruct Hfs as [Tpre [Tk [Tpost [ETown [Hpre [Hfe Hpost]]]]]]. subst Town.
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt Tk Hfe)
      as [S' [Hext [Hfe' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TRawSet S' [] (pre ++ (k0, e') :: post) proto
                            (Tpre ++ (k0, Tk) :: Tpost) Pf k _ U) | exact Hd ].
    + eapply has_fields_app_replace;
        [ eapply has_fields_store_weaken; [ exact Hpre | exact Hext ]
        | exact Hfe'
        | eapply has_fields_store_weaken; [ exact Hpost | exact Hext ] ].
    + exact Hno.
    + exact Hin.
    + eapply store_weakening; [ exact Hp | exact Hext ].
    + exact Hnp.
    + eapply store_weakening; [ exact Hv | exact Hext ].
  - (* RAW WRITE — SRawSet2: the prototype steps. Preserved: [proto] keeps [BRec Pf]. *)
    apply inv_rawset in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hin [Hp [Hnp [Hv Hd]]]]]]]]].
    destruct (IHHstep proto st proto' st' eq_refl eq_refl Hwt (BRec Pf) Hp)
      as [S' [Hext [Hp' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TRawSet S' [] own proto' Town Pf k _ U) | exact Hd ].
    + eapply has_fields_store_weaken; [ exact Hfs | exact Hext ].
    + exact Hno.
    + exact Hin.
    + exact Hp'.
    + exact Hnp.
    + eapply store_weakening; [ exact Hv | exact Hext ].
  - (* RAW WRITE — SRawSet3: the written value steps. Preserved: it keeps [U]. *)
    apply inv_rawset in Hty.
    destruct Hty as [Town [Pf [U [Hfs [Hno [Hin [Hp [Hnp [Hv Hd]]]]]]]]].
    destruct (IHHstep v st v' st' eq_refl eq_refl Hwt U Hv)
      as [S' [Hext [Hv' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply (TRawSet S' [] own proto Town Pf k _ U) | exact Hd ].
    + eapply has_fields_store_weaken; [ exact Hfs | exact Hext ].
    + exact Hno.
    + exact Hin.
    + eapply store_weakening; [ exact Hp | exact Hext ].
    + exact Hnp.
    + exact Hv'.
  (* VARARG — preservation for the new reductions. *)
  - (* SVApp: the PACK reduction. [tvapp vf va rs] ⤳ [tapp (tapp vf va) (tret rs)].
       The trailing args [rs : Ts] are packed into [tret rs : BTuple Ts] ([TRet]);
       the curried function applied to [va : Tf] then to that rest yields [B], which
       subsumes to the result. No store change. *)
    apply inv_vapp in Hty. destruct Hty as [Tf [Ts [B [Hf [Ha [Hrs Hsub]]]]]].
    exists S. split; [ apply extends_refl | split; [ | exact Hwt ] ].
    eapply TSub; [ | exact Hsub ].
    eapply TApp; [ eapply TApp; [ exact Hf | exact Ha ] | apply TRet; exact Hrs ].
  - (* SVApp1: congruence — step the function. *)
    apply inv_vapp in Hty. destruct Hty as [Tf [Ts [B [Hf [Ha [Hrs Hsub]]]]]].
    destruct (IHHstep f st f' st' eq_refl eq_refl Hwt
                (BArrow Tf (BArrow (BTuple Ts) B)) Hf) as [S' [Hext [Hf' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TVApp;
      [ exact Hf'
      | eapply store_weakening; [ exact Ha | exact Hext ]
      | eapply has_types_store_weaken; [ exact Hrs | exact Hext ] ] | exact Hsub ].
  - (* SVApp2: congruence — step the fixed argument. *)
    apply inv_vapp in Hty. destruct Hty as [Tf [Ts [B [Hf [Ha [Hrs Hsub]]]]]].
    destruct (IHHstep a st a' st' eq_refl eq_refl Hwt Tf Ha) as [S' [Hext [Ha' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TVApp;
      [ eapply store_weakening; [ exact Hf | exact Hext ]
      | exact Ha'
      | eapply has_types_store_weaken; [ exact Hrs | exact Hext ] ] | exact Hsub ].
  - (* SVApp3: congruence — step the first non-value trailing arg (left-to-right).
       Mirrors [SRet]: split the rest list, step the focused component, reassemble. *)
    apply inv_vapp in Hty. destruct Hty as [Tf [Ts [B [Hf [Ha [Hrs Hsub]]]]]].
    apply has_types_split in Hrs.
    destruct Hrs as [Tpre [Te [Tpost [ETs [Hpre [Hfe Hpost]]]]]]. subst Ts.
    destruct (IHHstep e st e' st' eq_refl eq_refl Hwt Te Hfe)
      as [S' [Hext [Hfe' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TVApp;
      [ eapply store_weakening; [ exact Hf | exact Hext ]
      | eapply store_weakening; [ exact Ha | exact Hext ]
      | eapply has_types_app_replace;
          [ eapply has_types_store_weaken; [ exact Hpre | exact Hext ]
          | exact Hfe'
          | eapply has_types_store_weaken; [ exact Hpost | exact Hext ] ] ]
      | exact Hsub ].
  (* MULTIPLE-ASSIGNMENT — preservation for the new reductions. *)
  - (* SMAssign: the multi-write. [tmassign rs (tret vs)] ⤳ [nil] with all writes
       applied. The result [nil : BAtom ANil <: T0]; the store stays well-typed under
       the FIXED [S] ([store_massign_preserves]): the RHS components [vs : Ss] are
       adjusted ([pad_commute]) to [pad_ty Ss (length rs)] then subsumed
       ([has_types_subsume] via [Hadj]) to the target cell types [Tgts]. *)
    apply inv_massign in Hty. destruct Hty as [Tgts [Ss [Hrs [Hrhs [Hadj Hsub]]]]].
    exists S. split; [ apply extends_refl | split ].
    + eapply TSub; [ apply (TLit S [] LNil) | exact Hsub ].
    + (* the RHS multivalue [tret vs] types its components EXACTLY at [Ss] *)
      apply inv_ret in Hrhs. destruct Hrhs as [Ss' [Hvs Htsub]].
      apply rsub_tuple_super in Htsub. simpl in Htsub. subst Ss'.
      (* lengths: [length rs = length Tgts] (targets typed [map BRef Tgts]) *)
      pose proof (has_types_length S [] rs (map BRef Tgts) Hrs) as Hlrs.
      rewrite length_map in Hlrs.
      (* adjusted values type at [Tgts] *)
      assert (Hpad : has_types S [] (pad_tm vs (List.length rs)) Tgts).
      { eapply has_types_subsume;
          [ rewrite Hlrs; apply (pad_commute (List.length Tgts) S [] vs Ss Hvs)
          | exact Hadj ]. }
      eapply store_massign_preserves; [ exact Hrs | exact H | exact Hpad | exact Hwt ].
  - (* SMAssign1: a TARGET steps (left-to-right). Split the target list, step the
       focused target (IH), reassemble at the SAME ref-types; [TMAssign] re-applies. *)
    apply inv_massign in Hty. destruct Hty as [Tgts [Ss [Hrs [Hrhs [Hadj Hsub]]]]].
    apply has_types_split in Hrs.
    destruct Hrs as [Tpre [Tr [Tpost [ETs [Hpre [Hfr Hpost]]]]]].
    destruct (IHHstep r st r' st' eq_refl eq_refl Hwt Tr Hfr)
      as [S' [Hext [Hfr' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TMAssign;
      [ rewrite ETs; eapply has_types_app_replace;
          [ eapply has_types_store_weaken; [ exact Hpre | exact Hext ]
          | exact Hfr'
          | eapply has_types_store_weaken; [ exact Hpost | exact Hext ] ]
      | eapply store_weakening; [ exact Hrhs | exact Hext ]
      | exact Hadj ]
      | exact Hsub ].
  - (* SMAssign2: the RHS multivalue steps. The RHS keeps [BTuple Ss] (IH); the
       targets store-weaken; [Hadj] is type-level (stable); [TMAssign] re-applies. *)
    apply inv_massign in Hty. destruct Hty as [Tgts [Ss [Hrs [Hrhs [Hadj Hsub]]]]].
    destruct (IHHstep rhs st rhs' st' eq_refl eq_refl Hwt (BTuple Ss) Hrhs)
      as [S' [Hext [Hrhs' Hwt']]].
    exists S'. split; [ exact Hext | split; [ | exact Hwt' ] ].
    eapply TSub; [ eapply TMAssign;
      [ eapply has_types_store_weaken; [ exact Hrs | exact Hext ]
      | exact Hrhs'
      | exact Hadj ]
      | exact Hsub ].
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

(* MULTI-RETURN — the component-list analogue for a return-sequence: either all
   components are values (so [tret es] is a value via [VRet]) or the first
   non-value component steps (so [tret es] steps via [SRet]). *)
Lemma tret_progress : forall S es Ts st,
  has_types S [] es Ts ->
  (forall e, In e es -> value e \/ (exists e' st', step (e, st) (e', st'))) ->
  Forall value es \/
  (exists pre e post, es = pre ++ e :: post /\
     Forall value pre /\ exists e' st', step (e, st) (e', st')).
Proof.
  intros S es Ts st Hf. induction Hf; intros Hall.
  - left. apply Forall_nil.
  - destruct (Hall e (or_introl eq_refl)) as [Hv | [e' [st' He']]].
    + destruct IHHf as [Hvs | [pre [e2 [post [Efs [Hpre Hstep]]]]]].
      * intros e0 Hin. apply Hall. right; exact Hin.
      * left. apply Forall_cons; [ exact Hv | exact Hvs ].
      * right. exists (e :: pre), e2, post.
        simpl. rewrite Efs. split; [ reflexivity | ].
        split; [ apply Forall_cons; [ exact Hv | exact Hpre ] | exact Hstep ].
    + right. exists [], e, es. simpl.
      split; [ reflexivity | split; [ apply Forall_nil | exists e', st'; exact He' ] ].
Qed.

(* canonical form for a TUPLE-typed value: a value of type [BTuple Ts] is a
   return-sequence [tret es]. (Needed by [progress]'s [tfst]/[tappspread] cases.) *)
Lemma canon_tuple : forall S e Ts,
  has_type S [] e (BTuple Ts) -> value e -> exists es, e = tret es.
Proof.
  intros S e Ts Hty Hv. destruct Hv as [l | T b | fs Hfs | n | es Hes | own proto Hvo Hvp].
  - apply inv_lit in Hty. destruct l; simpl in Hty;
      exfalso; eapply rsub_atom_not_tuple; eauto.
  - apply inv_lam in Hty. destruct Hty as [Tb [_ Hsub]].
    exfalso. eapply rsub_arrow_not_tuple; eauto.
  - apply inv_rec in Hty. destruct Hty as [Ts0 [_ [_ Hsub]]].
    exfalso. eapply rsub_rec_not_tuple; eauto.
  - apply inv_loc in Hty. destruct Hty as [U [_ Hsub]].
    exfalso. eapply rsub_ref_not_tuple; eauto.
  - exists es; reflexivity.
  - apply inv_meta in Hty. destruct Hty as [Town [Pf [_ [_ [_ [_ Hsub]]]]]].
    exfalso. eapply rsub_rec_not_tuple; eauto.
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
         forall ke, In ke fs -> value (snd ke) \/ (exists e' st', step (snd ke, st) (e', st')))
    (P1 := fun S G es Ts (_ : has_types S G es Ts) =>
       G = [] -> forall st, store_well_typed S st ->
         forall e, In e es -> value e \/ (exists e' st', step (e, st) (e', st')));
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
    + (* the subject is a value of [BRec] type: either a plain record [trec fs]
         (SProj) or a metatable-table [tmeta own proto] (the [__index] DISPATCH —
         SMetaProjOwn if [k] is a direct field, else SMetaProjProto). *)
      match goal with [ He : has_type S [] e (BRec fields) |- _ ] =>
        destruct (canon_rec S e fields He Hve) as [[fs Efs] | [own [proto Em]]] end.
      * (* plain record — original SProj path *)
        subst e.
        match goal with [ He : has_type S [] (trec fs) (BRec fields), Hin0 : In (k, T) fields |- _ ] =>
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
      * (* METATABLES — the [__index] dispatch always steps. *)
        subst e.
        destruct (field_lookup k own) as [v | ] eqn:Hlk.
        -- exists v, st. apply SMetaProjOwn; [ exact Hve | exact Hlk ].
        -- exists (tproj proto k), st. apply SMetaProjProto; [ exact Hve | exact Hlk ].
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
    + destruct (value_truthy_or_falsy c Hvc) as [Htr | [Hfa | [es Hmulti]]].
      * exists (subst 0 c e1), st. apply SIfnTrue; assumption.
      * exists (subst 0 c e2), st. apply SIfnFalse; assumption.
      * (* MULTI-RETURN — a multivalue scrutinee TRUNCATES first ([SIfnMulti]). *)
        subst c. destruct es as [ | v rest ].
        -- exists (tifn (tlit LNil) e1 e2), st. apply SIfnMultiNil.
        -- exists (tifn v e1 e2), st. apply SIfnMultiCons. exact Hvc.
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
  - (* TAnnot: never a value — either the body is a value (strip, SAnnotV) or it
       steps (congruence, SAnnot1). *)
    intros st Hwt. right.
    match goal with [ IH : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
      destruct (IH eq_refl st Hwt) as [Hv | [e' [st' He']]] end.
    + exists e, st. apply SAnnotV. exact Hv.
    + exists (tannot T e'), st'. apply SAnnot1. exact He'.
  - (* MULTI-RETURN — TRet: either all components are values (so the multivalue is
       a VALUE, [VRet]) or the first non-value steps ([SRet]). *)
    intros st Hwt.
    match goal with [ Hts0 : has_types S [] es Ts, IH : [] = [] -> _ |- _ ] =>
      destruct (tret_progress S es Ts st Hts0 (IH eq_refl st Hwt)) as
        [Hvs | [pre [e [post [Ees [Hpre [e' [st' He']]]]]]]] end.
    + left. apply VRet. exact Hvs.
    + right. subst es. exists (tret (pre ++ e' :: post)), st'.
      apply SRet; [ exact Hpre | exact He' ].
  - (* TFst: subject value ⇒ a multivalue (canon_tuple) ⇒ truncate (SFstCons /
       SFstNil); else congruence (SFst1). *)
    intros st Hwt. right.
    match goal with [ IHe0 : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
      destruct (IHe0 eq_refl st Hwt) as [Hve | [e'' [st'' He'']]] end.
    + match goal with [ He : has_type S [] e (BTuple (T :: Ts)) |- _ ] =>
        destruct (canon_tuple S e (T :: Ts) He Hve) as [es Ees] end. subst e.
      destruct es as [ | v rest ].
      * (* a value [tret []] of type [BTuple (T::Ts)] is impossible (length); but we
           need only that it steps: an empty multivalue truncates to nil. *)
        exists (tlit LNil), st. apply SFstNil.
      * exists v, st. apply SFstCons. exact Hve.
    + exists (tfst e''), st''. apply SFst1. exact He''.
  - (* TFstNil: subject value ⇒ a multivalue ⇒ truncate; else congruence. *)
    intros st Hwt. right.
    match goal with [ IHe0 : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
      destruct (IHe0 eq_refl st Hwt) as [Hve | [e'' [st'' He'']]] end.
    + match goal with [ He : has_type S [] e (BTuple []) |- _ ] =>
        destruct (canon_tuple S e [] He Hve) as [es Ees] end. subst e.
      destruct es as [ | v rest ].
      * exists (tlit LNil), st. apply SFstNil.
      * exists v, st. apply SFstCons. exact Hve.
    + exists (tfst e''), st''. apply SFst1. exact He''.
  - (* TAppSpread: consumer value ⇒ a lambda (canon_arrow) ⇒ SPREAD beta
       (SAppSpread, the arg need not be a value — the whole multivalue is spliced);
       else congruence (SAppSpread1 / SAppSpread2). *)
    intros st Hwt. right.
    match goal with [ IHg : [] = [] -> forall st, _ -> value g \/ _ |- _ ] =>
      destruct (IHg eq_refl st Hwt) as [Hvg | [g' [stg Hg']]] end.
    + match goal with [ IHa : [] = [] -> forall st, _ -> value a \/ _ |- _ ] =>
        destruct (IHa eq_refl st Hwt) as [Hva | [a' [sta Ha']]] end.
      * match goal with [ Hg : has_type S [] g (BArrow (BTuple Ts) B) |- _ ] =>
          destruct (canon_arrow S g (BTuple Ts) B Hg Hvg) as [Tl [body Eg]] end. subst g.
        exists (subst 0 a body), st. apply SAppSpread. exact Hva.
      * exists (tappspread g a'), sta. apply SAppSpread2; assumption.
    + exists (tappspread g' a), stg. apply SAppSpread1. exact Hg'.
  - (* METATABLES — TMeta: build the table. If some own field steps, [SMeta1]; else
       all own fields are values — if the prototype steps, [SMeta2]; else the whole
       [tmeta own proto] is a VALUE ([VMeta]). *)
    intros st Hwt.
    match goal with [ Hfs0 : has_fields S [] ofs Town, IH : [] = [] -> _ |- _ ] =>
      destruct (fields_progress S ofs Town st Hfs0 (IH eq_refl st Hwt)) as
        [Hvs | [pre [k [e [post [Efs [Hpre [e' [st' He']]]]]]]]] end.
    + (* own all values: consult the prototype *)
      match goal with [ IHp : [] = [] -> forall st, _ -> value proto \/ _ |- _ ] =>
        destruct (IHp eq_refl st Hwt) as [Hvp | [proto' [stp Hp']]] end.
      * left. apply VMeta; [ exact Hvs | exact Hvp ].
      * right. exists (tmeta ofs proto'), stp. apply SMeta2; [ exact Hvs | exact Hp' ].
    + right. subst ofs. exists (tmeta (pre ++ (k, e') :: post) proto), st'.
      apply SMeta1; [ exact Hpre | exact He' ].
  - (* METATABLE [__call] — TCallMeta: [tapp (tmeta ofs proto) arg]. If the table
       steps, [SApp1]; else table value and the arg steps, [SApp2]; else both values
       — [SCallMeta] dispatches. The table is a [tmeta] typed at [BRec M], so its
       progress IH is the [tmeta]-subterm IH (always steps unless a value). *)
    intros st Hwt. right.
    match goal with [ IHt : [] = [] -> forall st, _ -> value (tmeta ofs proto) \/ _ |- _ ] =>
      destruct (IHt eq_refl st Hwt) as [Hvt | [t' [stt Ht']]] end.
    + match goal with [ IHa : [] = [] -> forall st, _ -> value arg \/ _ |- _ ] =>
        destruct (IHa eq_refl st Hwt) as [Hva | [a' [sta Ha']]] end.
      * exists (tapp (tapp (tproj (tmeta ofs proto) mm_call) (tmeta ofs proto)) arg), st.
        apply SCallMeta; [ exact Hvt | exact Hva ].
      * exists (tapp (tmeta ofs proto) a'), sta. apply SApp2; [ exact Hvt | exact Ha' ].
    + exists (tapp t' arg), stt. apply SApp1. exact Ht'.
  - (* METATABLE OPERATOR — TPrimMetaL: [tprim op (tmeta ofs proto) b]. If the table
       steps, [SPrim1]; else the table is a value — [SPrimMetaL] dispatches (the right
       operand need not be a value, the metamethod is a function). *)
    intros st Hwt. right.
    match goal with [ IHt : [] = [] -> forall st, _ -> value (tmeta ofs proto) \/ _ |- _ ] =>
      destruct (IHt eq_refl st Hwt) as [Hvt | [t' [stt Ht']]] end.
    + exists (tapp (tapp (tproj (tmeta ofs proto) (mm_binop op)) (tmeta ofs proto)) b), st.
      apply SPrimMetaL. exact Hvt.
    + exists (tprim op t' b), stt. apply SPrim1. exact Ht'.
  - (* METATABLE OPERATOR — TPrimMetaR: [tprim op a (tmeta ofs proto)] with [a : BAtom
       al]. If the left operand [a] steps, [SPrim1]; else [a] is a value, hence a
       literal [tlit l] ([canon_atom]) — if the right table steps, [SPrim2]; else the
       table is a value and [SPrimMetaR] dispatches. *)
    intros st Hwt. right.
    match goal with [ IHa : [] = [] -> forall st, _ -> value a \/ _,
                      Ha0 : has_type S [] a (BAtom al) |- _ ] =>
      destruct (IHa eq_refl st Hwt) as [Hva | [a' [sta Ha']]] end.
    + match goal with [ IHt : [] = [] -> forall st, _ -> value (tmeta ofs proto) \/ _ |- _ ] =>
        destruct (IHt eq_refl st Hwt) as [Hvt | [t' [stt Ht']]] end.
      * match goal with [ Ha0 : has_type S [] a (BAtom al) |- _ ] =>
          destruct (canon_atom S a al Ha0 Hva) as [l El] end. subst a.
        exists (tapp (tapp (tproj (tmeta ofs proto) (mm_binop op)) (tlit l)) (tmeta ofs proto)), st.
        apply SPrimMetaR. exact Hvt.
      * exists (tprim op a t'), stt. apply SPrim2; [ exact Hva | exact Ht' ].
    + exists (tprim op a' (tmeta ofs proto)), sta. apply SPrim1. exact Ha'.
  - (* METATABLE [__newindex] — TNewIdx: [tnewidx ofs proto k v]. If an own field
       steps, [SNewIdx1]; else own all values — if proto steps [SNewIdx2]; else if
       the value steps [SNewIdx3]; else all values — [SNewIdx] dispatches the write
       to the [__newindex] target ([k] absent from own, since [key_in k Town = false]
       and own's keys are [Town]'s keys, so [field_lookup k ofs = None]). *)
    intros st Hwt. right.
    match goal with [ Hfs0 : has_fields S [] ofs Town, IH : [] = [] -> _ |- _ ] =>
      destruct (fields_progress S ofs Town st Hfs0 (IH eq_refl st Hwt)) as
        [Hvs | [pre [k0 [e0 [post [Efs [Hpre [e0' [st0' He0']]]]]]]]] end.
    + (* own all values: proto, then value, then dispatch *)
      match goal with [ IHp : [] = [] -> forall st, _ -> value proto \/ _ |- _ ] =>
        destruct (IHp eq_refl st Hwt) as [Hvp | [proto' [stp Hp']]] end.
      * match goal with [ IHv : [] = [] -> forall st, _ -> value v \/ _ |- _ ] =>
          destruct (IHv eq_refl st Hwt) as [Hvv | [v' [stv Hv']]] end.
        -- (* all values: SNewIdx — establish [field_lookup k ofs = None] *)
           assert (Hlk : field_lookup k ofs = None).
           { match goal with [ Hkey : key_in k Town = false, Hf : has_fields S [] ofs Town |- _ ] =>
               pose proof (has_fields_keys S [] ofs Town Hf) as Hkeys;
               destruct (field_lookup k ofs) as [vv | ] eqn:Elk; [ | reflexivity ];
               exfalso;
               apply field_lookup_in_keys in Elk; rewrite Hkeys in Elk;
               apply key_in_iff in Elk; rewrite Elk in Hkey; discriminate end. }
           exists (tassign (tproj proto k) v), st.
           apply SNewIdx; [ exact Hvs | exact Hvp | exact Hvv | exact Hlk ].
        -- exists (tnewidx ofs proto k v'), stv. apply SNewIdx3; assumption.
      * exists (tnewidx ofs proto' k v), stp. apply SNewIdx2; [ exact Hvs | exact Hp' ].
    + subst ofs. exists (tnewidx (pre ++ (k0, e0') :: post) proto k v), st0'.
      apply SNewIdx1; [ exact Hpre | exact He0' ].
  - (* METATABLE UNARY METAMETHOD — TUnMetaL: [tunop uop (tmeta ofs proto)]. If the
       table steps, [SUnop1]; else the table is a value — [SUnMetaL] dispatches. *)
    intros st Hwt. right.
    match goal with [ IHt : [] = [] -> forall st, _ -> value (tmeta ofs proto) \/ _ |- _ ] =>
      destruct (IHt eq_refl st Hwt) as [Hvt | [t' [stt Ht']]] end.
    + exists (tapp (tapp (tproj (tmeta ofs proto) (mm_unop uop)) (tmeta ofs proto)) (tmeta ofs proto)), st.
      apply SUnMetaL. exact Hvt.
    + exists (tunop uop t'), stt. apply SUnop1. exact Ht'.
  - (* RAW READ — TRawGet: [trawget ofs proto k]. If an own field steps, [SRawGet1];
       else own all values — if proto steps [SRawGet2]; else all values, and since
       [(k,T) ∈ Town] and own's keys are [Town]'s keys, [field_lookup k ofs] SUCCEEDS,
       so [SRawGet] steps directly to the own value (no prototype consulted). *)
    intros st Hwt. right.
    match goal with [ Hfs0 : has_fields S [] ofs Town, IH : [] = [] -> _ |- _ ] =>
      destruct (fields_progress S ofs Town st Hfs0 (IH eq_refl st Hwt)) as
        [Hvs | [pre [k0 [e0 [post [Efs [Hpre [e0' [st0' He0']]]]]]]]] end.
    + match goal with [ IHp : [] = [] -> forall st, _ -> value proto \/ _ |- _ ] =>
        destruct (IHp eq_refl st Hwt) as [Hvp | [proto' [stp Hp']]] end.
      * (* all values: [field_lookup k ofs] succeeds (k is an own key) *)
        assert (Hink : In k (map fst ofs)).
        { match goal with [ Hin0 : In (k, T) Town, Hf : has_fields S [] ofs Town |- _ ] =>
            pose proof (has_fields_keys S [] ofs Town Hf) as Hkeys;
            rewrite Hkeys; replace k with (fst (k, T)) by reflexivity;
            apply in_map; exact Hin0 end. }
        assert (Hlk : exists v, field_lookup k ofs = Some v).
        { clear -Hink. induction ofs as [ | [k0 e0] ofs IH ]; simpl in *; [ contradiction | ].
          destruct (string_dec k k0) as [Hk | Hk].
          - exists e0; reflexivity.
          - destruct Hink as [Hbad | Hin]; [ symmetry in Hbad; contradiction | apply IH; exact Hin ]. }
        destruct Hlk as [v Hv].
        exists v, st. apply SRawGet; [ exact Hvs | exact Hvp | exact Hv ].
      * exists (trawget ofs proto' k), stp. apply SRawGet2; [ exact Hvs | exact Hp' ].
    + subst ofs. exists (trawget (pre ++ (k0, e0') :: post) proto k), st0'.
      apply SRawGet1; [ exact Hpre | exact He0' ].
  - (* RAW WRITE — TRawSet: [trawset ofs proto k v]. If an own field steps,
       [SRawSet1]; else own all values — proto steps [SRawSet2]; value steps
       [SRawSet3]; else all values, and since [(k, BRef T) ∈ Town], [field_lookup k
       ofs] SUCCEEDS, so [SRawSet] steps to the OWN-cell write (no prototype). *)
    intros st Hwt. right.
    match goal with [ Hfs0 : has_fields S [] ofs Town, IH : [] = [] -> _ |- _ ] =>
      destruct (fields_progress S ofs Town st Hfs0 (IH eq_refl st Hwt)) as
        [Hvs | [pre [k0 [e0 [post [Efs [Hpre [e0' [st0' He0']]]]]]]]] end.
    + match goal with [ IHp : [] = [] -> forall st, _ -> value proto \/ _ |- _ ] =>
        destruct (IHp eq_refl st Hwt) as [Hvp | [proto' [stp Hp']]] end.
      * match goal with [ IHv : [] = [] -> forall st, _ -> value v \/ _ |- _ ] =>
          destruct (IHv eq_refl st Hwt) as [Hvv | [v' [stv Hv']]] end.
        -- (* all values: [field_lookup k ofs] succeeds (k an own key) *)
           assert (Hink : In k (map fst ofs)).
           { match goal with [ Hin0 : In (k, BRef T) Town, Hf : has_fields S [] ofs Town |- _ ] =>
               pose proof (has_fields_keys S [] ofs Town Hf) as Hkeys;
               rewrite Hkeys; replace k with (fst (k, BRef T)) by reflexivity;
               apply in_map; exact Hin0 end. }
           assert (Hlk : exists cell, field_lookup k ofs = Some cell).
           { clear -Hink. induction ofs as [ | [k0 e0] ofs IH ]; simpl in *; [ contradiction | ].
             destruct (string_dec k k0) as [Hk | Hk].
             - exists e0; reflexivity.
             - destruct Hink as [Hbad | Hin]; [ symmetry in Hbad; contradiction | apply IH; exact Hin ]. }
           destruct Hlk as [cell Hcell].
           exists (tassign cell v), st.
           apply SRawSet; [ exact Hvs | exact Hvp | exact Hvv | exact Hcell ].
        -- exists (trawset ofs proto k v'), stv. apply SRawSet3; assumption.
      * exists (trawset ofs proto' k v), stp. apply SRawSet2; [ exact Hvs | exact Hp' ].
    + subst ofs. exists (trawset (pre ++ (k0, e0') :: post) proto k v), st0'.
      apply SRawSet1; [ exact Hpre | exact He0' ].
  - (* VARARG — TVApp: the variadic call always STEPS. If the function steps,
       [SVApp1]; else if the fixed arg steps, [SVApp2]; else if some trailing arg
       steps (first non-value, via [tret_progress] on the rest list), [SVApp3];
       else everything is a value and the PACK fires, [SVApp]. *)
    intros st Hwt. right.
    match goal with [ IHf : [] = [] -> forall st, _ -> value f \/ _ |- _ ] =>
      destruct (IHf eq_refl st Hwt) as [Hvf | [f' [stf Hf']]] end.
    + match goal with [ IHa : [] = [] -> forall st, _ -> value a \/ _ |- _ ] =>
        destruct (IHa eq_refl st Hwt) as [Hva | [a' [sta Ha']]] end.
      * match goal with [ Hts0 : has_types S [] rs Ts, IH : [] = [] -> _ |- _ ] =>
          destruct (tret_progress S rs Ts st Hts0 (IH eq_refl st Hwt)) as
            [Hvs | [pre [e [post [Ers [Hpre [e' [st' He']]]]]]]] end.
        -- exists (tapp (tapp f a) (tret rs)), st.
           apply SVApp; [ exact Hvf | exact Hva | exact Hvs ].
        -- subst rs. exists (tvapp f a (pre ++ e' :: post)), st'.
           apply SVApp3; [ exact Hvf | exact Hva | exact Hpre | exact He' ].
      * exists (tvapp f a' rs), sta. apply SVApp2; [ exact Hvf | exact Ha' ].
    + exists (tvapp f' a rs), stf. apply SVApp1. exact Hf'.
  - (* MULTIPLE-ASSIGNMENT — TMAssign: the assignment always STEPS. If some target
       is non-value, step the first one (left-to-right, via [tret_progress] on the
       target list), [SMAssign1]; else if the RHS multivalue steps, [SMAssign2];
       else every target is a value and the RHS is a value multivalue ([canon_tuple]
       ⇒ [tret vs]), so the multi-write [SMAssign] fires. *)
    intros st Hwt. right.
    match goal with [ Hts0 : has_types S [] rs (map BRef Tgts), IH : [] = [] -> _ |- _ ] =>
      destruct (tret_progress S rs (map BRef Tgts) st Hts0 (IH eq_refl st Hwt)) as
        [Hvrs | [pre [r [post [Ers [Hpre [r' [str Hr']]]]]]]] end.
    + (* all targets are values; examine the RHS *)
      match goal with [ IHr : [] = [] -> forall st, _ -> value rhs \/ _ |- _ ] =>
        destruct (IHr eq_refl st Hwt) as [Hvrhs | [rhs' [strhs Hrhs']]] end.
      * (* RHS is a value of tuple type ⇒ a multivalue [tret vs] ⇒ multi-write *)
        match goal with [ Hrhs : has_type S [] rhs (BTuple Ss) |- _ ] =>
          destruct (canon_tuple S rhs Ss Hrhs Hvrhs) as [vs Evs] end. subst rhs.
        inversion Hvrhs; subst.
        exists (tlit LNil), (store_massign rs (pad_tm vs (List.length rs)) st).
        apply SMAssign; [ exact Hvrs | assumption ].
      * exists (tmassign rs rhs'), strhs. apply SMAssign2; [ exact Hvrs | exact Hrhs' ].
    + subst rs. exists (tmassign (pre ++ r' :: post) rhs), str.
      apply SMAssign1; [ exact Hpre | exact Hr' ].
  - (* P0 HFnil *) intros st Hwt ke [].
  - (* P0 HFcons *) intros st Hwt ke Hin. simpl in Hin. destruct Hin as [Heq | Hin].
    + subst ke.
      match goal with [ IH : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
        apply (IH eq_refl st Hwt) end.
    + match goal with [ IH : [] = [] -> forall st, _ -> forall _, In _ ?l -> _ |- _ ] =>
        apply (IH eq_refl st Hwt ke Hin) end.
  - (* MULTI-RETURN — P1 HTnil *) intros st Hwt e [].
  - (* P1 HTcons *) intros st Hwt e0 Hin. simpl in Hin. destruct Hin as [Heq | Hin].
    + subst e0.
      match goal with [ IH : [] = [] -> forall st, _ -> value e \/ _ |- _ ] =>
        apply (IH eq_refl st Hwt) end.
    + match goal with [ IH : [] = [] -> forall st, _ -> forall _, In _ ?l -> _ |- _ ] =>
        apply (IH eq_refl st Hwt e0 Hin) end.
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
  destruct H as [ [A [B [Hf [_ _]]]] | [ofs [proto [M [Self [A [R [Ef _]]]]]]] ];
    [ | discriminate Ef ].
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
  destruct H as [ [A [B [Hf [Ha _]]]] | [ofs [proto [M [Self [A [R [Ef _]]]]]]] ];
    [ | discriminate Ef ].
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
  destruct H as [ [A [B [Hf [Ha _]]]] | [ofs [proto [M [Self [A [R [Ef _]]]]]]] ];
    [ | discriminate Ef ].
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
  - split; [ intros [Hb | Hn]; discriminate | intros [es Hm]; discriminate ].
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
  destruct H as [ [Ha [_ _]]
                | [ [ofs [proto [M [Self [Other [R [Ea _]]]]]]]
                  | [al [ofs [proto [M [Other [R [Eb _]]]]]] ] ] ];
    [ | discriminate Ea | discriminate Eb ].
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
           (map (fun ke => (fst ke, lift 1 kk (snd ke))) fs) = fs)
    (Pt := fun es => forall ss kk,
       map (subst kk ss) (map (lift 1 kk) es) = es);
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
  - (* tannot *) rewrite IHe; reflexivity.
  - (* MULTI-RETURN — tret *) f_equal. apply IHe.
  - (* tfst *) rewrite IHe; reflexivity.
  - (* tappspread *) rewrite IHe1, IHe2; reflexivity.
  - (* METATABLES — tmeta: own fields (Pl IH) + proto (P IH) cancel. *)
    rewrite IHe, IHe0; reflexivity.
  - (* METATABLE [__newindex] — tnewidx: own fields (Pl IH) + proto + value cancel. *)
    repeat match goal with [ IH : forall ss kk, _ = _ |- _ ] => rewrite IH end;
      reflexivity.
  - (* unary metamethod — tunop: the operand cancels. *)
    rewrite IHe; reflexivity.
  - (* RAW READ — trawget: own fields (Pl IH) + proto cancel. *)
    rewrite IHe, IHe0; reflexivity.
  - (* RAW WRITE — trawset: own fields (Pl IH) + proto + value cancel. *)
    repeat match goal with [ IH : forall ss kk, _ = _ |- _ ] => rewrite IH end;
      reflexivity.
  - (* VARARG — tvapp: function + fixed arg + trailing-arg list cancel. *)
    repeat match goal with [ IH : forall ss kk, _ = _ |- _ ] => rewrite IH end;
      reflexivity.
  - (* MULTIPLE-ASSIGNMENT — tmassign: target list + RHS cancel. *)
    repeat match goal with [ IH : forall ss kk, _ = _ |- _ ] => rewrite IH end;
      reflexivity.
  - (* Pl cons *) rewrite IHe, IHe0; reflexivity.
  - (* MULTI-RETURN — Pt cons *) rewrite IHe, IHe0; reflexivity.
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
   MULTI-RETURN — THE PAYOFF.

   A real multi-return function, and the CONTEXTUAL ADJUSTMENT machine-checked:
   the SAME multi-return call is TRUNCATED to its first value in one position and
   SPREAD (all values) in another.

   The function:  f := λx:Int. return x, true   :  Int -> (Int, Bool)
   It returns a SEQUENCE of TWO values — an Int and a Bool — so its result type is
   the TUPLE [BTuple [AInt; ABool]] (NOT a single value).

   The call:      f 3   :  (Int, Bool)   — a multivalue.

   THE CONTEXTUAL ADJUSTMENT (the crux), on the SAME [f 3]:

   1. TRUNCATION (most positions):  [tfst (f 3)]  binds the FIRST return value.
      Type:  AInt  (the head — NOT the tuple [(Int,Bool)]).  Steps:  ⤳* 3.
      This is [local x = f()]: x : Int, the first value, extras discarded.

   2. LAST-POSITION SPREAD:  [g (f 3)]  with  g : (Int, Bool) -> Int  spreads ALL
      of [f 3]'s values into [g] (the known-arity consumer receives the whole
      sequence).  Type:  AInt (g's result).  Steps:  ⤳* 0.
      This is [g(f())] with f() last: g receives BOTH values.

   Same [f 3]; truncated in (1), spread in (2) — the distinctive Lua feature,
   machine-checked.
   =========================================================================== *)

(* the multi-return function f := λx:Int. (return x, true) : Int -> (Int, Bool). *)
Definition mr_f : tm :=
  tlam (BAtom AInt) (tret [ tvar 0 ; tlit (LBool true) ]).

(* the tuple type [(Int, Bool)] f returns. *)
Definition mr_tup : BTy := BTuple [ BAtom AInt ; BAtom ABool ].

Example mr_f_typed : has_type [] [] mr_f (BArrow (BAtom AInt) mr_tup).
Proof.
  unfold mr_f, mr_tup. apply TLam. apply TRet.
  apply HTcons; [ apply TVar; reflexivity | ].
  apply HTcons; [ apply TLit | apply HTnil ].
Qed.

(* the multi-return CALL [f 3] : (Int, Bool) — a multivalue. *)
Definition mr_call : tm := tapp mr_f (tlit (LInt 3)).

Example mr_call_typed : has_type [] [] mr_call mr_tup.
Proof.
  unfold mr_call, mr_tup. eapply TApp; [ apply mr_f_typed | apply TLit ].
Qed.

(* ---- (1) TRUNCATION: [tfst (f 3)] binds the FIRST value — type [AInt], NOT the
   tuple. The contextual adjustment that discards the extra (Bool) return. *)
Example mr_truncate_typed : has_type [] [] (tfst mr_call) (BAtom AInt).
Proof.
  (* [f 3 : (Int, Bool) = BTuple (AInt :: [ABool])], truncates to head [AInt]. *)
  eapply TFst. apply mr_call_typed.
Qed.

(* The TRUNCATION step: the call reduces to the multivalue, then [tfst] takes the
   head [3] — the first return value (the [Bool] return is discarded). *)
Example mr_truncate_steps : forall st,
  multistep (tfst mr_call, st) (tlit (LInt 3), st).
Proof.
  intro st. unfold mr_call, mr_f.
  (* beta: (λx:Int. (return x,true)) 3 ⤳ (return 3, true) — a multivalue value *)
  eapply MSstep. { apply SFst1. apply SBeta. apply VLit. }
  simpl.
  (* truncate the multivalue [return 3, true] to its head [3] *)
  eapply MSstep.
  { apply SFstCons. apply VRet. apply Forall_cons; [ apply VLit | ].
    apply Forall_cons; [ apply VLit | apply Forall_nil ]. }
  apply MSrefl.
Qed.

(* ---- (2) LAST-POSITION SPREAD: [g (f 3)] with g : (Int,Bool) -> Int spreads ALL
   of [f 3]'s values into g (the consumer binds the whole sequence). Result [AInt].
   The SAME [f 3] — spread here, truncated above. *)
Definition mr_g : tm := tlam mr_tup (tlit (LInt 0)).

Example mr_g_typed : has_type [] [] mr_g (BArrow mr_tup (BAtom AInt)).
Proof. unfold mr_g. apply TLam. apply TLit. Qed.

Example mr_spread_typed : has_type [] [] (tappspread mr_g mr_call) (BAtom AInt).
Proof.
  (* g : (Int,Bool) -> Int ; the multivalue arg [f 3 : (Int,Bool)] spreads whole. *)
  eapply TAppSpread; [ apply mr_g_typed | apply mr_call_typed ].
Qed.

(* The SPREAD step: the call reduces to the multivalue [return 3, true], then the
   whole sequence is spliced into g (g binds the tuple), and g returns 0. *)
Example mr_spread_steps : forall st,
  multistep (tappspread mr_g mr_call, st) (tlit (LInt 0), st).
Proof.
  intro st. unfold mr_call, mr_f, mr_g.
  (* reduce the multivalue argument: beta the inner call to [return 3, true] *)
  eapply MSstep. { apply SAppSpread2; [ apply VLam | apply SBeta; apply VLit ]. }
  simpl.
  (* spread: substitute the whole multivalue into g's body (body is the literal 0,
     ignoring the bound tuple) ⤳ 0 *)
  eapply MSstep.
  { apply SAppSpread. apply VRet. apply Forall_cons; [ apply VLit | ].
    apply Forall_cons; [ apply VLit | apply Forall_nil ]. }
  simpl. apply MSrefl.
Qed.

(* (The EXECUTABLE-checker view of the same adjustment — [synth (tfst mr_call) =
   Some AInt] vs [synth (tappspread mr_g mr_call)] returning g's result — is
   machine-checked by [Compute]/[reflexivity] in check.v, where [synth] lives.) *)

(* progress + preservation instantiated on the payoff terms (smoke test that the
   multi-return cases of the soundness theorems actually fire on a real example). *)
Example mr_truncate_progress :
  value (tfst mr_call) \/ exists e' st', step (tfst mr_call, []) (e', st').
Proof. apply (progress [] (tfst mr_call) (BAtom AInt) [] mr_truncate_typed store_well_typed_nil). Qed.

Example mr_spread_progress :
  value (tappspread mr_g mr_call) \/ exists e' st', step (tappspread mr_g mr_call, []) (e', st').
Proof. apply (progress [] (tappspread mr_g mr_call) (BAtom AInt) [] mr_spread_typed store_well_typed_nil). Qed.

(* ===========================================================================
   VARARG [...] — THE PAYOFF: function-side variadics, machine-checked.

   The PARAMETER-side mirror of multi-return. A variadic function binds, beyond
   its fixed parameter [x], the TRAILING actual arguments as a single MULTIVALUE —
   the rest [...] — and that rest behaves EXACTLY like a multi-return result: it is
   TRUNCATED to one value in expression position and SPREAD in last position,
   reusing the SAME [tfst]/[tappspread] substrate.

   A variadic function is the two-binder curried shape [tlam T (tlam (BTuple Ts)
   body)] — fixed param [x] at de Bruijn index 1, the rest [...] at index 0. A
   variadic CALL [tvapp f a rs] PACKS the trailing actuals [rs] into the rest
   multivalue and applies [f] to [a] then to that packed rest (reusing
   [tapp]/[tret]/[SBeta]).

   The rest type here is [(Int, Bool) = BTuple [AInt; ABool]] — the SAME tuple type
   a two-value multi-return produces (the producer/consumer symmetry).

   TWO payoffs, on the SAME rest [...]:

   1. TRUNCATE [...] to one value:  [function(x, ...) return (...) end] in an
      expression position truncates the rest to its FIRST value.  Body [tfst (tvar
      0)] : Int.  Call [tvapp f 7 [3; true]] ⤳* 3.

   2. FORWARD [...] (last-position spread):  [function(x, ...) return g(...) end]
      spreads the WHOLE rest into [g].  Body [tappspread g (tvar 0)] : Int.  Call
      [tvapp f 7 [3; true]] ⤳* 0 (g ignores the bound tuple, returns 0).
   =========================================================================== *)

(* the rest type [(Int, Bool)] — the trailing arguments packed as a tuple. *)
Definition va_rest : BTy := BTuple [ BAtom AInt ; BAtom ABool ].

(* ---- (1) a variadic function that TRUNCATES [...] to its first value.
   [va_first := λx:Int. λ(... : (Int,Bool)). tfst ...]  :  Int -> (Int,Bool) -> Int.
   [...] is the inner binding [tvar 0]; [tfst] truncates it to its head [Int]. *)
Definition va_first : tm :=
  tlam (BAtom AInt) (tlam va_rest (tfst (tvar 0))).

Example va_first_typed :
  has_type [] [] va_first (BArrow (BAtom AInt) (BArrow va_rest (BAtom AInt))).
Proof.
  unfold va_first, va_rest. apply TLam. apply TLam.
  eapply TFst. apply TVar. reflexivity.
Qed.

(* the variadic CALL: fixed arg [7], trailing actuals [3, true] packed into [...]. *)
Definition va_first_call : tm :=
  tvapp va_first (tlit (LInt 7)) [ tlit (LInt 3) ; tlit (LBool true) ].

Example va_first_call_typed : has_type [] [] va_first_call (BAtom AInt).
Proof.
  unfold va_first_call, va_rest.
  eapply TVApp.
  - apply va_first_typed.
  - apply TLit.
  - apply HTcons; [ apply TLit | apply HTcons; [ apply TLit | apply HTnil ] ].
Qed.

(* The TRUNCATION step: the call PACKS the trailing args into the rest multivalue
   [return 3, true], binds it as [...], and the body truncates it to its head [3]
   (the extra [true] is discarded). *)
Example va_first_call_steps :
  multistep (va_first_call, []) (tlit (LInt 3), []).
Proof.
  unfold va_first_call, va_first, va_rest.
  (* PACK: trailing args collected into [tret [3; true]], applied to fixed arg 7 *)
  eapply MSstep.
  { apply SVApp; [ apply VLam | apply VLit | ].
    apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ]. }
  (* beta the fixed parameter [x := 7] (under the outer congruence) *)
  eapply MSstep. { apply SApp1. apply SBeta. apply VLit. } simpl.
  (* bind the rest [... := return 3, true] *)
  eapply MSstep.
  { apply SBeta. apply VRet.
    apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ]. }
  simpl.
  (* truncate the rest to its head [3] *)
  eapply MSstep.
  { apply SFstCons. apply VRet.
    apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ]. }
  apply MSrefl.
Qed.

(* ---- (2) a variadic function that FORWARDS [...] (last-position spread) into a
   known-arity consumer [g : (Int,Bool) -> Int].
   [va_fwd := λx:Int. λ(... : (Int,Bool)). (λ(t:(Int,Bool)). 0) (...)]  :
     Int -> (Int,Bool) -> Int.
   The body SPREADS the whole rest [...] into [g] — the parameter-side mirror of
   last-position spread. [g] is embedded as an inner lambda (kept closed); the
   spread argument [tvar 0] is the outer rest binding (it sits OUTSIDE [g]'s own
   binder, so the index is correct). *)
Definition va_fwd : tm :=
  tlam (BAtom AInt)
    (tlam va_rest
      (tappspread (tlam va_rest (tlit (LInt 0))) (tvar 0))).

Example va_fwd_typed :
  has_type [] [] va_fwd (BArrow (BAtom AInt) (BArrow va_rest (BAtom AInt))).
Proof.
  unfold va_fwd, va_rest. apply TLam. apply TLam.
  eapply TAppSpread.
  - apply TLam. apply TLit.
  - apply TVar. reflexivity.
Qed.

Definition va_fwd_call : tm :=
  tvapp va_fwd (tlit (LInt 7)) [ tlit (LInt 3) ; tlit (LBool true) ].

Example va_fwd_call_typed : has_type [] [] va_fwd_call (BAtom AInt).
Proof.
  unfold va_fwd_call, va_rest.
  eapply TVApp.
  - apply va_fwd_typed.
  - apply TLit.
  - apply HTcons; [ apply TLit | apply HTcons; [ apply TLit | apply HTnil ] ].
Qed.

(* The SPREAD/FORWARD step: the call packs the trailing args, binds them as [...],
   and the body spreads the WHOLE rest into [g], which returns 0. *)
Example va_fwd_call_steps :
  multistep (va_fwd_call, []) (tlit (LInt 0), []).
Proof.
  unfold va_fwd_call, va_fwd, va_rest.
  (* PACK trailing args, apply to fixed arg 7 *)
  eapply MSstep.
  { apply SVApp; [ apply VLam | apply VLit | ].
    apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ]. }
  eapply MSstep. { apply SApp1. apply SBeta. apply VLit. } simpl.
  (* bind the rest [... := return 3, true] *)
  eapply MSstep.
  { apply SBeta. apply VRet.
    apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ]. }
  simpl.
  (* spread the whole rest into [g] (binds the tuple, ignores it) ⤳ 0 *)
  eapply MSstep.
  { apply SAppSpread. apply VRet.
    apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ]. }
  simpl. apply MSrefl.
Qed.

(* progress instantiated on the variadic payoff terms (smoke test that the vararg
   case of progress actually fires on a real variadic call). *)
Example va_first_progress :
  value va_first_call \/ exists e' st', step (va_first_call, []) (e', st').
Proof. apply (progress [] va_first_call (BAtom AInt) [] va_first_call_typed store_well_typed_nil). Qed.

Example va_fwd_progress :
  value va_fwd_call \/ exists e' st', step (va_fwd_call, []) (e', st').
Proof. apply (progress [] va_fwd_call (BAtom AInt) [] va_fwd_call_typed store_well_typed_nil). Qed.

(* ===========================================================================
   MULTIPLE-ASSIGNMENT [a, b, … = e1, e2, …] — THE PAYOFF, machine-checked.

   The LHS-side CONSUMER of the SAME multi-value substrate the producers
   (multi-return / vararg) feed. A multiple-assignment adjusts its RHS multivalue to
   EXACTLY the LHS arity N — TRUNCATING extras (the [tfst] direction) and PADDING
   missing slots with [nil] (the adjust-UP direction) — then writes each adjusted
   value to its target cell ([tassign]'s store-update). Three payoffs cover the three
   adjustment regimes, on real reference cells (the reassignable-locals machinery):

   (1) [a, b = f()]   — f MULTI-RETURNS two values; both land (exact arity).
   (2) [a, b, c = e1, e2] — three targets, two RHS values ⇒ [c] is NIL-PADDED.
   (3) [a, b = e1, e2, e3] — two targets, three RHS values ⇒ [e3] is DROPPED.

   Evaluation order: all targets + the RHS evaluate to values (left-to-right), then
   every write fires at once ([SMAssign]) — Lua's "compute everything, then assign".
   =========================================================================== *)

(* ---- (1) [a, b = f()] : f multi-returns (Int, Bool); BOTH values bound.
   Targets are two cells [a : BRef Int], [b : BRef Bool] (store addresses 0, 1); the
   RHS is the multi-return call [mr_call = f 3], typed [(Int, Bool)]. Arity matches
   (2 = 2), so no truncation or padding — the producer/consumer symmetry exactly. *)
Definition ma_S : list BTy := [ BAtom AInt ; BAtom ABool ].
Definition ma_st : store := [ tlit (LInt 0) ; tlit (LBool false) ].

Lemma ma_store_wt : store_well_typed ma_S ma_st.
Proof.
  unfold ma_S, ma_st. split; [ reflexivity | ].
  intros n T Hn. destruct n as [ | [ | n']]; simpl in Hn;
    [ injection Hn as <-; apply TLit
    | injection Hn as <-; apply TLit
    | destruct n'; discriminate Hn ].
Qed.

Definition ma_call : tm := tmassign [ tloc 0 ; tloc 1 ] mr_call.

Example ma_call_typed : has_type ma_S [] ma_call (BAtom ANil).
Proof.
  unfold ma_call, ma_S.
  eapply (TMAssign ma_S [] [ tloc 0 ; tloc 1 ] mr_call
            [ BAtom AInt ; BAtom ABool ] [ BAtom AInt ; BAtom ABool ]).
  - apply HTcons; [ eapply TLoc; reflexivity
    | apply HTcons; [ eapply TLoc; reflexivity | apply HTnil ] ].
  - (* mr_call : (Int, Bool) — the multi-return result, in store typing [ma_S] *)
    unfold mr_call, mr_f. eapply TApp; [ apply TLam; apply TRet | apply TLit ].
    apply HTcons; [ apply TVar; reflexivity | apply HTcons; [ apply TLit | apply HTnil ] ].
  - (* pad_ty [Int;Bool] 2 = [Int;Bool], pointwise rsub-refl to the targets *)
    simpl. apply Forall2_cons; [ apply rsub_refl
    | apply Forall2_cons; [ apply rsub_refl | apply Forall2_nil ] ].
Qed.

(* The step: the RHS call evaluates to the multivalue [return 3, true] ([SMAssign2]),
   then the multi-write assigns 3 to [a] and true to [b] at once ([SMAssign]); the
   store becomes [3; true] and the form yields [nil]. *)
Example ma_call_steps :
  multistep (ma_call, ma_st)
            (tlit LNil, [ tlit (LInt 3) ; tlit (LBool true) ]).
Proof.
  unfold ma_call, ma_st, mr_call, mr_f.
  (* step the RHS: (λx:Int. return x,true) 3 ⤳ return 3, true *)
  eapply MSstep.
  { apply SMAssign2; [ apply Forall_cons; [ apply VLoc | apply Forall_cons; [ apply VLoc | apply Forall_nil ] ] | ].
    apply SBeta. apply VLit. } simpl.
  (* the multi-write: both targets are locations, RHS is a value multivalue *)
  eapply MSstep.
  { apply SMAssign;
      [ apply Forall_cons; [ apply VLoc | apply Forall_cons; [ apply VLoc | apply Forall_nil ] ]
      | apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ] ]. }
  simpl. apply MSrefl.
Qed.

(* progress fires on the assignment (smoke test of the [tmassign] progress arm). *)
Example ma_call_progress :
  value ma_call \/ exists e' st', step (ma_call, ma_st) (e', st').
Proof. apply (progress ma_S ma_call (BAtom ANil) ma_st ma_call_typed ma_store_wt). Qed.

(* ---- (2) [a, b, c = e1, e2] : THREE targets, TWO RHS values ⇒ [c] is NIL-PADDED.
   Targets [a : BRef Int], [b : BRef Bool], [c : BRef Nil] (the padded slot's cell
   admits [nil]). RHS [tret [5; false]] has arity 2; [pad_ty [Int;Bool] 3 =
   [Int;Bool;Nil]], pointwise rsub-below the targets — the [nil]-pad direction. *)
Definition mp_S : list BTy := [ BAtom AInt ; BAtom ABool ; BAtom ANil ].
Definition mp_st : store := [ tlit (LInt 0) ; tlit (LBool false) ; tlit LNil ].

Lemma mp_store_wt : store_well_typed mp_S mp_st.
Proof.
  unfold mp_S, mp_st. split; [ reflexivity | ].
  intros n T Hn. destruct n as [ | [ | [ | n']]]; simpl in Hn;
    [ injection Hn as <-; apply TLit
    | injection Hn as <-; apply TLit
    | injection Hn as <-; apply TLit
    | destruct n'; discriminate Hn ].
Qed.

Definition mp_assign : tm :=
  tmassign [ tloc 0 ; tloc 1 ; tloc 2 ] (tret [ tlit (LInt 5) ; tlit (LBool false) ]).

Example mp_assign_typed : has_type mp_S [] mp_assign (BAtom ANil).
Proof.
  unfold mp_assign, mp_S.
  eapply (TMAssign mp_S [] _ _ [ BAtom AInt ; BAtom ABool ; BAtom ANil ]
            [ BAtom AInt ; BAtom ABool ]).
  - apply HTcons; [ eapply TLoc; reflexivity
    | apply HTcons; [ eapply TLoc; reflexivity
    | apply HTcons; [ eapply TLoc; reflexivity | apply HTnil ] ] ].
  - apply TRet. apply HTcons; [ apply TLit | apply HTcons; [ apply TLit | apply HTnil ] ].
  - (* pad_ty [Int;Bool] 3 = [Int;Bool;Nil]: c gets the [nil] pad, rsub-refl *)
    simpl. apply Forall2_cons; [ apply rsub_refl
    | apply Forall2_cons; [ apply rsub_refl
    | apply Forall2_cons; [ apply rsub_refl | apply Forall2_nil ] ] ].
Qed.

(* The step: RHS is already a value multivalue (arity 2); the multi-write adjusts it
   UP to arity 3 — [a := 5], [b := false], and the missing [c := nil] (the pad). The
   store's third cell becomes [nil] (here unchanged from its [nil] initial value, but
   it is the PADDED write, not a no-op: [pad_tm [5;false] 3 = [5; false; nil]]). *)
Example mp_assign_steps :
  multistep (mp_assign, mp_st)
            (tlit LNil, [ tlit (LInt 5) ; tlit (LBool false) ; tlit LNil ]).
Proof.
  unfold mp_assign, mp_st.
  eapply MSstep.
  { apply SMAssign;
      [ apply Forall_cons; [ apply VLoc | apply Forall_cons; [ apply VLoc
        | apply Forall_cons; [ apply VLoc | apply Forall_nil ] ] ]
      | apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit | apply Forall_nil ] ] ]. }
  simpl. apply MSrefl.
Qed.

(* ---- (3) [a, b = e1, e2, e3] : TWO targets, THREE RHS values ⇒ [e3] is DROPPED.
   RHS [tret [7; true; 99]] has arity 3; [pad_tm [7;true;99] 2 = [7; true]] —
   the truncation direction (the extra [99] is discarded, exactly as [tfst]). *)
Definition md_assign : tm :=
  tmassign [ tloc 0 ; tloc 1 ]
    (tret [ tlit (LInt 7) ; tlit (LBool true) ; tlit (LInt 99) ]).

Example md_assign_typed : has_type ma_S [] md_assign (BAtom ANil).
Proof.
  unfold md_assign, ma_S.
  eapply (TMAssign ma_S [] _ _ [ BAtom AInt ; BAtom ABool ]
            [ BAtom AInt ; BAtom ABool ; BAtom AInt ]).
  - apply HTcons; [ eapply TLoc; reflexivity
    | apply HTcons; [ eapply TLoc; reflexivity | apply HTnil ] ].
  - apply TRet. apply HTcons; [ apply TLit | apply HTcons; [ apply TLit
    | apply HTcons; [ apply TLit | apply HTnil ] ] ].
  - (* pad_ty [Int;Bool;Int] 2 = [Int;Bool]: the third source type is DROPPED *)
    simpl. apply Forall2_cons; [ apply rsub_refl
    | apply Forall2_cons; [ apply rsub_refl | apply Forall2_nil ] ].
Qed.

(* The step: the multi-write adjusts the arity-3 RHS DOWN to arity 2 — [a := 7],
   [b := true]; the extra [99] is discarded. Store becomes [7; true]. *)
Example md_assign_steps :
  multistep (md_assign, ma_st)
            (tlit LNil, [ tlit (LInt 7) ; tlit (LBool true) ]).
Proof.
  unfold md_assign, ma_st.
  eapply MSstep.
  { apply SMAssign;
      [ apply Forall_cons; [ apply VLoc | apply Forall_cons; [ apply VLoc | apply Forall_nil ] ]
      | apply Forall_cons; [ apply VLit | apply Forall_cons; [ apply VLit
        | apply Forall_cons; [ apply VLit | apply Forall_nil ] ] ] ]. }
  simpl. apply MSrefl.
Qed.

(* ===========================================================================
   METATABLES — THE PAYOFF: prototype inheritance / OOP, machine-checked.

   A "base" object carrying a method [greet : nil -> string]; a "derived" object
   with its OWN field [name : string] and metatable [__index = base]. A field
   access on the derived object for the INHERITED method [greet] resolves THROUGH
   [__index] to the base's method (typed + stepped). A field present in NEITHER
   own nor prototype is REJECTED at every type. This is real Lua single-inheritance
   OOP, mechanized.
   =========================================================================== *)

(* the base object: a record with a [greet] method (a [nil -> string] function). *)
Definition oop_greet : tm := tlam (BAtom ANil) (tlit (LStr 0)).
Definition oop_base : list (string * tm) := [("greet"%string, oop_greet)].
(* the derived object: own field [name], prototype [__index] = the base record. *)
Definition oop_derived : tm := tmeta [("name"%string, tlit (LStr 1))] (trec oop_base).

(* the base's read type and the derived object's FLATTENED (own ++ inherited) type. *)
Definition oop_base_ty : list (string * BTy) :=
  [("greet"%string, BArrow (BAtom ANil) (BAtom AStr))].
Definition oop_derived_ty : BTy :=
  BRec (merge_fields [("name"%string, BAtom AStr)] oop_base_ty).

(* the derived object is well typed: own [name:Str] PLUS inherited [greet:nil->Str]. *)
Example oop_derived_typed : has_type [] [] oop_derived oop_derived_ty.
Proof.
  unfold oop_derived, oop_derived_ty, oop_base, oop_base_ty, oop_greet.
  eapply TMeta.
  - (* own fields: name : Str *)
    apply HFcons; [ apply (TLit [] [] (LStr 1)) | apply HFnil ].
  - (* NoDup own keys *) repeat constructor; simpl; intuition discriminate.
  - (* prototype record: { greet : nil -> Str } *)
    apply TRec.
    + apply HFcons; [ apply TLam; apply (TLit [] [(BAtom ANil)] (LStr 0)) | apply HFnil ].
    + repeat constructor; simpl; intuition discriminate.
  - (* NoDup prototype keys *) repeat constructor; simpl; intuition discriminate.
Qed.

(* THE INHERITED METHOD is directly projectable on the derived object, AT ITS BASE
   TYPE [nil -> Str] — the field [greet] is NOT an own field of the derived object;
   typing resolves it through [__index] to the base. This is inheritance, typed. *)
Example oop_inherited_typed :
  has_type [] [] (tproj oop_derived "greet") (BArrow (BAtom ANil) (BAtom AStr)).
Proof.
  eapply TProj.
  - apply oop_derived_typed.
  - (* [(greet, nil->Str)] is in the flattened (merged) field set *)
    unfold oop_derived_ty, oop_base_ty. simpl. right; left; reflexivity.
Qed.

(* THE DISPATCH, OPERATIONALLY: projecting [greet] on the derived object FALLS
   THROUGH [__index] (greet is not an own field of the derived object) to the
   base's [greet] method. Two steps: SMetaProjProto (fall through to the
   prototype), then SProj (look up [greet] in the base record). *)
Example oop_inherited_steps : forall st,
  multistep (tproj oop_derived "greet", st) (oop_greet, st).
Proof.
  intro st. unfold oop_derived, oop_base, oop_greet.
  eapply multistep_trans.
  - apply multistep_one. apply SMetaProjProto.
    + apply VMeta;
        [ repeat constructor | apply VRec; repeat constructor ].
    + reflexivity.   (* field_lookup "greet" [("name", ...)] = None — greet not own *)
  - apply multistep_one. apply SProj.
    + apply VRec. repeat constructor.
    + reflexivity.   (* field_lookup "greet" base = Some greet *)
Qed.

(* The OWN field is resolved DIRECTLY (no fallback): [name] is an own field. *)
Example oop_own_typed :
  has_type [] [] (tproj oop_derived "name") (BAtom AStr).
Proof.
  eapply TProj.
  - apply oop_derived_typed.
  - unfold oop_derived_ty, oop_base_ty. simpl. left; reflexivity.
Qed.

Example oop_own_steps : forall st,
  multistep (tproj oop_derived "name", st) (tlit (LStr 1), st).
Proof.
  intro st. unfold oop_derived, oop_base, oop_greet.
  apply multistep_one. apply SMetaProjOwn.
  - apply VMeta; [ repeat constructor | apply VRec; repeat constructor ].
  - reflexivity.   (* field_lookup "name" own = Some (LStr 1) *)
Qed.

(* A field present in NEITHER own NOR prototype is REJECTED at every type — the
   checker prevents a lookup that the dispatch could not resolve. *)
Example oop_absent_rejected : forall T,
  ~ has_type [] [] (tproj oop_derived "nonesuch") T.
Proof.
  intros T H. apply inv_proj in H. destruct H as [fields [W [Hsubj [Hin _]]]].
  apply inv_meta in Hsubj.
  destruct Hsubj as [Town [Pf [Hfs [Hno [Hp [Hnp HsubRec]]]]]].
  (* A projected key has a supplier in the MERGE (merge⊆fields inversion). *)
  destruct (rsub_rec_inv (merge_fields Town Pf) fields "nonesuch" W HsubRec Hin)
    as [Tg [HinTg _]].
  (* its key is therefore in the merge keys ⇒ an own key OR a prototype key. *)
  assert (Hk : In "nonesuch"%string (map fst (merge_fields Town Pf)))
    by (replace "nonesuch"%string with (fst ("nonesuch"%string, Tg)) by reflexivity;
        apply in_map; exact HinTg).
  apply merge_fields_key_in in Hk.
  (* OWN keys = exactly [name] (concrete [has_fields]); PROTOTYPE keys ⊆ base keys
     = [greet] (the prototype record [trec base] subtypes [BRec Pf], so [srec base
     Pf] — every Pf key is a base key). "nonesuch" is neither [name] nor [greet]. *)
  unfold oop_derived, oop_base, oop_greet in *.
  inversion Hfs as [ | S0 G0 k0 e0 Te0 fs0 Ts0 He0 Hrest E1 E2 E3 E4 ]; subst.
  inversion Hrest; subst.   (* Town = [("name", Te0)] *)
  apply inv_rec in Hp. destruct Hp as [Pbase [Hpb [_ HsubP]]].
  inversion Hpb as [ | Sb Gb kb eb Teb fsb Tsb Heb Hrestb Eb1 Eb2 Eb3 Eb4 ]; subst.
  inversion Hrestb; subst.   (* base field types = [("greet", Teb)] *)
  apply rsub_rec_super in HsubP. simpl in HsubP.
  destruct Hk as [Hown | Hproto].
  - (* own key: must be "name" *)
    simpl in Hown. destruct Hown as [E | F]; [ discriminate E | exact F ].
  - (* prototype key: via [srec base Pf], it is a base key = "greet" *)
    (* recover (nonesuch, Tg') ∈ Pf, then its supplier in base = only "greet" *)
    apply in_map_iff in Hproto. destruct Hproto as [[k' T'] [Ek' HinPf]].
    simpl in Ek'. subst k'.
    destruct (srec_lookup _ _ HsubP "nonesuch"%string T' HinPf) as [Tf [Hinb _]].
    simpl in Hinb. destruct Hinb as [E | F];
      [ injection E; intros _ Ek; discriminate Ek | exact F ].
Qed.

(* ===========================================================================
   METATABLE METAMETHODS — THE PAYOFFS: callable tables (__call), operator
   overloading (__add), and write-fallback (__newindex), machine-checked.
   =========================================================================== *)

(* ---- __call: a CALLABLE TABLE. [cobj] carries a [__call] metamethod
   [BTop -> Int -> Int] (curried self, then arg; returns the arg). Applying it to
   [3] dispatches through [__call] and computes [3]. *)
Definition call_mm : tm := tlam BTop (tlam (BAtom AInt) (tvar 0)).
Definition cobj : tm := tmeta [(mm_call, call_mm)] (trec []).
Definition cobj_M : list (string * BTy) :=
  merge_fields [(mm_call, BArrow BTop (BArrow (BAtom AInt) (BAtom AInt)))] [].

(* the callable table itself types at its merged read record. *)
Example call_obj_typed : has_type [] [] cobj (BRec cobj_M).
Proof.
  unfold cobj, cobj_M, call_mm. eapply TMeta.
  - apply HFcons; [ apply TLam; apply TLam; apply (TVar [] [BAtom AInt; BTop] 0); reflexivity | apply HFnil ].
  - repeat constructor; simpl; intuition discriminate.
  - apply TRec; [ apply HFnil | constructor ].
  - constructor.
Qed.

(* APPLYING the callable table to [3] is well typed at [Int] — via [TCallMeta],
   the [__call] metamethod's final codomain. *)
Example call_payoff_typed : has_type [] [] (tapp cobj (tlit (LInt 3))) (BAtom AInt).
Proof.
  eapply TCallMeta.
  - apply call_obj_typed.
  - unfold cobj_M, merge_fields, mm_call. simpl. left; reflexivity.
  - apply RsSsub. apply SsTop.
  - apply (TLit [] [] (LInt 3)).
Qed.

(* and it COMPUTES: [cobj 3] dispatches to [(cobj.__call) cobj 3] (the metamethod
   resolved through the [__index] chain), two betas, reaching [3]. *)
Example call_payoff_steps : forall st,
  multistep (tapp cobj (tlit (LInt 3)), st) (tlit (LInt 3), st).
Proof.
  intro st. unfold cobj, call_mm.
  eapply multistep_trans.
  { apply multistep_one. apply SCallMeta.
    - apply VMeta; [ repeat constructor | apply VRec; constructor ].
    - constructor. }
  (* resolve the metamethod via SMetaProjOwn (it is an own field) *)
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SApp1. apply SMetaProjOwn.
    - apply VMeta; [ repeat constructor | apply VRec; constructor ].
    - unfold mm_call; reflexivity. }
  (* outer beta: [(λself.λx.x) cobj] ⤳ [λx.x] *)
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SBeta.
    apply VMeta; [ repeat constructor | apply VRec; constructor ]. }
  (* inner beta: [(λx.x) 3] ⤳ [3] *)
  simpl. apply multistep_one. apply SBeta. constructor.
Qed.

(* ---- __add: OPERATOR OVERLOADING. [vobj] carries an [__add] metamethod
   [BTop -> BTop -> Int]; [vobj + vobj] dispatches to it, result type [Int]. This
   is real Lua operator overloading, machine-checked at the type level. *)
Definition add_mm : tm := tlam BTop (tlam BTop (tlit (LInt 7))).
Definition vobj : tm := tmeta [("__add"%string, add_mm)] (trec []).
Definition vobj_M : list (string * BTy) :=
  merge_fields [("__add"%string, BArrow BTop (BArrow BTop (BAtom AInt)))] [].

Example add_obj_typed : has_type [] [] vobj (BRec vobj_M).
Proof.
  unfold vobj, vobj_M, add_mm. eapply TMeta.
  - apply HFcons; [ apply TLam; apply TLam; apply (TLit [] [BTop; BTop] (LInt 7)) | apply HFnil ].
  - repeat constructor; simpl; intuition discriminate.
  - apply TRec; [ apply HFnil | constructor ].
  - constructor.
Qed.

(* [vobj + vobj] is well typed at [Int] (the [__add] metamethod's result) — LEFT
   operand dispatch via [TPrimMetaL]. [mm_binop PAdd = "__add"]. *)
Example add_payoff_typed :
  has_type [] [] (tprim PAdd vobj vobj) (BAtom AInt).
Proof.
  eapply TPrimMetaL.
  - apply add_obj_typed.
  - unfold vobj_M, merge_fields. simpl. unfold mm_binop. left; reflexivity.
  - apply RsSsub. apply SsTop.
  - (* right operand [vobj : BTop] via [SsTop] subsumption *)
    eapply TSub; [ apply add_obj_typed | apply RsSsub; apply SsTop ].
Qed.

(* and it COMPUTES: [vobj + vobj] dispatches to [(vobj.__add) vobj vobj], reaching
   the metamethod's result [7]. *)
Example add_payoff_steps : forall st,
  multistep (tprim PAdd vobj vobj, st) (tlit (LInt 7), st).
Proof.
  intro st. unfold vobj, add_mm.
  eapply multistep_trans.
  { apply multistep_one. apply SPrimMetaL.
    apply VMeta; [ repeat constructor | apply VRec; constructor ]. }
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SApp1. apply SMetaProjOwn.
    - apply VMeta; [ repeat constructor | apply VRec; constructor ].
    - unfold mm_binop; reflexivity. }
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SBeta.
    apply VMeta; [ repeat constructor | apply VRec; constructor ]. }
  simpl. apply multistep_one. apply SBeta.
  apply VMeta; [ repeat constructor | apply VRec; constructor ].
Qed.

(* ---- __add RIGHT-OPERAND FALLBACK. The prototypical Lua case [1 + obj]: the LEFT
   operand is a plain number (no metamethod), so dispatch falls to the RIGHT
   operand's metamethod. [robj] carries an [__add] metamethod whose LEFT domain is
   [BAtom ANum] (it accepts the scalar left operand) and result [Int]; [1 + robj]
   dispatches via [TPrimMetaR]/[SPrimMetaR] to [(robj.__add) 1 robj]. *)
Definition radd_mm : tm := tlam (BAtom AInt) (tlam BTop (tlit (LInt 8))).
Definition robj : tm := tmeta [("__add"%string, radd_mm)] (trec []).

Example radd_obj_typed : has_type [] [] robj
  (BRec (merge_fields
    [("__add"%string, BArrow (BAtom AInt) (BArrow BTop (BAtom AInt)))] [])).
Proof.
  unfold robj, radd_mm. eapply TMeta.
  - apply HFcons; [ apply TLam; apply TLam; apply (TLit [] [BTop; BAtom AInt] (LInt 8)) | apply HFnil ].
  - repeat constructor; simpl; intuition discriminate.
  - apply TRec; [ apply HFnil | constructor ].
  - constructor.
Qed.

(* [1 + robj] is well typed at [Int] via RIGHT-operand fallback [TPrimMetaR]: the
   left operand [1 : BAtom ANum] inhabits the metamethod's left domain, the right
   operand [robj] provides the [__add] metamethod. *)
Example add_right_payoff_typed :
  has_type [] [] (tprim PAdd (tlit (LInt 1)) robj) (BAtom AInt).
Proof.
  eapply TPrimMetaR.
  - apply (TLit [] [] (LInt 1)).
  - apply radd_obj_typed.
  - unfold merge_fields. simpl. unfold mm_binop. left; reflexivity.
  - apply RsSsub. apply SsTop.
Qed.

(* and it COMPUTES: [1 + robj] dispatches to [(robj.__add) 1 robj] ⤳ the result [8],
   exercising [SPrimMetaR] (the mirror of [SPrimMetaL]). *)
Example add_right_payoff_steps : forall st,
  multistep (tprim PAdd (tlit (LInt 1)) robj, st) (tlit (LInt 8), st).
Proof.
  intro st. unfold robj, radd_mm.
  eapply multistep_trans.
  { apply multistep_one. apply SPrimMetaR.
    apply VMeta; [ repeat constructor | apply VRec; constructor ]. }
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SApp1. apply SMetaProjOwn.
    - apply VMeta; [ repeat constructor | apply VRec; constructor ].
    - unfold mm_binop; reflexivity. }
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SBeta. constructor. }
  simpl. apply multistep_one. apply SBeta.
  apply VMeta; [ repeat constructor | apply VRec; constructor ].
Qed.

(* RIGHT-fallback is REJECTED when the right operand lacks the metamethod: [robj]
   has [__add] but not [__sub], so [1 - robj] does not type (numeric path fails —
   [robj] is not a number; LEFT path fails — [1] is not a metatable; RIGHT path
   fails — no [__sub] in [robj]'s interface). *)
Example sub_right_absent_rejected : forall T,
  ~ has_type [] [] (tprim PSub (tlit (LInt 1)) robj) T.
Proof.
  intros T H. apply inv_prim in H.
  destruct H as [ [_ [Hb _]]
                | [ [ofs [proto [M [Self [Other [R [Ea _]]]]]]]
                  | [al [ofs [proto [M [Other [R [Eb [_ [Htbl [Hin [_ _]]]]]]]]]] ] ] ].
  - (* numeric: [robj : ANum] is false (a table is not a number) *)
    apply inv_meta in Hb. destruct Hb as [Tw [Pf [_ [_ [_ [_ Hbad]]]]]].
    eapply rsub_rec_not_atom; exact Hbad.
  - (* LEFT path: requires the left operand [1] to be a [tmeta] — it is [tlit]. *)
    discriminate Ea.
  - (* RIGHT path: [robj]'s merged type [M] must contain ("__sub", _); only ("__add", _)
       is present — refuted, exactly mirroring [sub_absent_rejected]. *)
    unfold robj in Eb. injection Eb as <- <-.
    apply inv_meta in Htbl.
    destruct Htbl as [Tw [Pf [Hfs [_ [Hp [_ HsubRec]]]]]].
    unfold robj, radd_mm in Hfs.
    inversion Hfs as [ | S0 G0 k0 e0 Te0 fs0 Ts0 He0 Hrest E1 E2 E3 ]; subst.
    inversion Hrest; subst.
    apply inv_rec in Hp. destruct Hp as [Pbase [Hpb [_ HsubP]]].
    inversion Hpb; subst.
    apply rsub_rec_super in HsubP. simpl in HsubP.
    destruct (rsub_rec_inv (merge_fields [("__add"%string, Te0)] Pf) M
                "__sub"%string (BArrow (BAtom al) (BArrow Other R)) HsubRec Hin)
      as [Tg [HinTg _]].
    assert (Hk : In "__sub"%string (map fst (merge_fields [("__add"%string, Te0)] Pf)))
      by (replace "__sub"%string with (fst ("__sub"%string, Tg)) by reflexivity;
          apply in_map; exact HinTg).
    apply merge_fields_key_in in Hk.
    destruct Hk as [Hown | Hproto].
    + simpl in Hown. destruct Hown as [E | F]; [ discriminate E | exact F ].
    + apply in_map_iff in Hproto. destruct Hproto as [[k' T'] [Ek' HinPf]].
      simpl in Ek'. subst k'.
      destruct (srec_lookup _ _ HsubP "__sub"%string T' HinPf) as [Tf [Hinb _]].
      simpl in Hinb. exact Hinb.
Qed.

(* a primop whose LEFT operand is a metatable WITHOUT the operator's metamethod is
   REJECTED (the metamethod must be present in the table's read interface). Here
   [vobj] has [__add] but NOT [__sub], so [vobj - vobj] does not type via the
   metamethod, and [vobj] is not a number, so the numeric path fails too. *)
Example sub_absent_rejected : forall T,
  ~ has_type [] [] (tprim PSub vobj vobj) T.
Proof.
  intros T H. apply inv_prim in H.
  destruct H as [ [Ha [_ _]]
                | [ [ofs [proto [M [Self [Other [R [Ea [Htbl [Hin [_ [_ _]]]]]]]]]]]
                  | [al [ofs [proto [M [Other [R [Eb [Ha _]]]]]]] ] ] ].
  - (* numeric: [vobj : ANum] is false (a table is not a number) *)
    apply inv_meta in Ha. destruct Ha as [Tw [Pf [_ [_ [_ [_ Hbad]]]]]].
    eapply rsub_rec_not_atom; exact Hbad.
  - (* metamethod: [vobj]'s merged type [M] must contain ("__sub", _); but the only
       member is ("__add", _) — refuted. *)
    unfold vobj in Ea. injection Ea as <- <-.
    (* [Htbl : has_type [] [] vobj (BRec M)] forces [M] ssub-above [vobj_M] *)
    apply inv_meta in Htbl.
    destruct Htbl as [Tw [Pf [Hfs [_ [Hp [_ HsubRec]]]]]].
    unfold vobj, add_mm in Hfs.
    inversion Hfs as [ | S0 G0 k0 e0 Te0 fs0 Ts0 He0 Hrest E1 E2 E3 ]; subst.
    inversion Hrest; subst.
    (* the prototype [trec []] has read type [BRec Pf] with [Pf]'s keys empty *)
    apply inv_rec in Hp. destruct Hp as [Pbase [Hpb [_ HsubP]]].
    inversion Hpb; subst.
    apply rsub_rec_super in HsubP. simpl in HsubP.
    (* the supplier of ("__sub", _) in [M] comes from [merge [("__add",_)] Pf] *)
    destruct (rsub_rec_inv (merge_fields [("__add"%string, Te0)] Pf) M
                "__sub"%string (BArrow Self (BArrow Other R)) HsubRec Hin)
      as [Tg [HinTg _]].
    (* its key is in the merge keys ⇒ "__add" (own) or a [Pf] key; [Pf]'s keys ⊆ ∅ *)
    assert (Hk : In "__sub"%string (map fst (merge_fields [("__add"%string, Te0)] Pf)))
      by (replace "__sub"%string with (fst ("__sub"%string, Tg)) by reflexivity;
          apply in_map; exact HinTg).
    apply merge_fields_key_in in Hk.
    destruct Hk as [Hown | Hproto].
    + simpl in Hown. destruct Hown as [E | F]; [ discriminate E | exact F ].
    + (* a [Pf] key — but [Pf] has no keys (its [srec []] gives every key in ∅) *)
      apply in_map_iff in Hproto. destruct Hproto as [[k' T'] [Ek' HinPf]].
      simpl in Ek'. subst k'.
      destruct (srec_lookup _ _ HsubP "__sub"%string T' HinPf) as [Tf [Hinb _]].
      simpl in Hinb. exact Hinb.
  - (* RIGHT-fallback: requires the LEFT operand [vobj : BAtom al], but [vobj] is a
       [tmeta], which cannot inhabit a [BAtom] type. *)
    apply inv_meta in Ha. destruct Ha as [Tw [Pf [_ [_ [_ [_ Hbad]]]]]].
    eapply rsub_rec_not_atom; exact Hbad.
Qed.

(* ---- __newindex: WRITE FALLBACK. [tnewidx [] ni "k" v] with [k] ABSENT from the
   empty own fields dispatches to the [__newindex] target [ni], a record of REFS;
   the write goes through to [ni]'s cell for [k]. With [ni = { k = loc0 }] over a
   store [[0]] typed [[Int]], writing [5] yields [nil] and store [[5]]. *)
Definition ni_target : tm := trec [("k"%string, tloc 0)].
Definition niwrite : tm := tnewidx [] ni_target "k" (tlit (LInt 5)).

(* the write is well typed at [nil] ([ANil]) under store typing [[Int]]. *)
Example newindex_payoff_typed :
  has_type [BAtom AInt] [] niwrite (BAtom ANil).
Proof.
  unfold niwrite, ni_target.
  eapply (TNewIdx [BAtom AInt] [] [] (trec [("k"%string, tloc 0)])
            [] [("k"%string, BRef (BAtom AInt))] "k" (tlit (LInt 5)) (BAtom AInt)).
  - apply HFnil.
  - constructor.
  - reflexivity.                         (* key_in "k" [] = false *)
  - apply TRec; [ apply HFcons; [ apply (TLoc [BAtom AInt] [] 0); reflexivity | apply HFnil ]
                | repeat constructor; simpl; intuition discriminate ].
  - repeat constructor; simpl; intuition discriminate.
  - left; reflexivity.                   (* ("k", BRef Int) in Pf *)
  - apply (TLit [BAtom AInt] [] (LInt 5)).
Qed.

(* and it WRITES THROUGH: the [__newindex] dispatch becomes [tassign (ni.k) 5],
   which assigns [5] into the cell [loc0]; from store [[0]] the result is [nil] and
   store [[5]]. The records-of-refs write-fallback, computed end-to-end. *)
Example newindex_payoff_steps :
  multistep (niwrite, [tlit (LInt 0)]) (tlit LNil, [tlit (LInt 5)]).
Proof.
  unfold niwrite, ni_target.
  (* dispatch: SNewIdx ([k] absent from own []) ⤳ tassign (tproj ni "k") 5 *)
  eapply multistep_trans.
  { apply multistep_one. apply SNewIdx.
    - constructor.                          (* own [] all values *)
    - apply VRec; repeat constructor.       (* ni is a value record *)
    - constructor.                          (* 5 is a value *)
    - reflexivity. }                        (* field_lookup "k" [] = None *)
  (* resolve [tproj ni "k"] to [loc0] (plain record projection) *)
  eapply multistep_trans.
  { apply multistep_one. apply SAssign1. apply SProj.
    - apply VRec; repeat constructor.
    - reflexivity. }
  (* assign [5] into [loc0]: store [0] ↦ [5], yields nil *)
  apply multistep_one. apply SAssign. constructor.
Qed.

(* writing an OWN key is the deferred rawset case — but a write to a key NOT in the
   [__newindex] target's cells is REJECTED (no cell to write through to). Here the
   target [ni] has only cell [k], so [tnewidx [] ni "nope" 5] does not type. *)
Example newindex_absent_cell_rejected : forall T,
  ~ has_type [BAtom AInt] [] (tnewidx [] ni_target "nope" (tlit (LInt 5))) T.
Proof.
  intros T H. apply inv_newidx in H.
  destruct H as [Town [Pf [U [Hfs [_ [_ [Hp [_ [Hin [_ _]]]]]]]]]].
  (* own is empty; the target [ni] has read type [Pf] ssub-above [{k:BRef Int}].
     ("nope", BRef U) ∈ Pf forces "nope" a key of the target — but its only key is
     "k". Refuted via the record subtyping supplier. *)
  unfold ni_target in Hp. apply inv_rec in Hp.
  destruct Hp as [Pbase [Hpb [_ HsubP]]].
  inversion Hpb as [ | Sb Gb kb eb Teb fsb Tsb Heb Hrestb Eb1 Eb2 Eb3 ]; subst.
  inversion Hrestb; subst.
  apply rsub_rec_super in HsubP. simpl in HsubP.
  destruct (srec_lookup _ _ HsubP "nope"%string (BRef U) Hin) as [Tf [Hinb _]].
  simpl in Hinb. destruct Hinb as [E | F];
    [ injection E; intros _ Ek; discriminate Ek | exact F ].
Qed.

(* ===========================================================================
   RAW TABLE ACCESS — THE PAYOFF: [rawget]/[rawset] bypass the metatable
   [__index]/[__newindex] fallback. We reuse the OOP object [oop_derived] (own
   field [name], prototype [__index] = a base record carrying [greet]). The
   DISTINGUISHING property: [tproj oop_derived "greet"] resolves THROUGH the
   prototype (oop_inherited_typed/_steps above), yet [trawget] for the SAME key
   "greet" is REJECTED — raw access never falls through to the prototype.
   =========================================================================== *)

(* RAW READ types the OWN field — same own-field primitive as the [__index] own
   arm, WITHOUT the merge: [trawget] of [name] reads OWN's [name : Str]. *)
Example rawget_own_typed :
  has_type [] [] (trawget [("name"%string, tlit (LStr 1))] (trec oop_base) "name")
                 (BAtom AStr).
Proof.
  unfold oop_base, oop_greet.
  eapply (TRawGet [] [] _ _ [("name"%string, BAtom AStr)]
            [("greet"%string, BArrow (BAtom ANil) (BAtom AStr))] "name" (BAtom AStr)).
  - apply HFcons; [ apply (TLit [] [] (LStr 1)) | apply HFnil ].
  - repeat constructor; simpl; intuition discriminate.
  - left; reflexivity.                       (* ("name", Str) in own *)
  - apply TRec;
      [ apply HFcons; [ apply TLam; apply (TLit [] [BAtom ANil] (LStr 0)) | apply HFnil ]
      | repeat constructor; simpl; intuition discriminate ].
  - repeat constructor; simpl; intuition discriminate.
Qed.

(* RAW READ steps DIRECTLY to the own value — ONE step ([SRawGet]), no prototype
   consulted (contrast [oop_own_steps]'s [SMetaProjOwn], which is the [tmeta]
   projection; here the table is given by its own + proto components directly). *)
Example rawget_own_steps : forall st,
  multistep (trawget [("name"%string, tlit (LStr 1))] (trec oop_base) "name", st)
            (tlit (LStr 1), st).
Proof.
  intro st. unfold oop_base, oop_greet.
  apply multistep_one. apply SRawGet.
  - repeat constructor.                       (* own all values *)
  - apply VRec; repeat constructor.           (* proto a value record *)
  - reflexivity.                              (* field_lookup "name" own = Some (LStr 1) *)
Qed.

(* THE DISTINGUISHING PROPERTY (raw read): the INHERITED key "greet" — projectable
   through [__index] on the [tmeta] object (oop_inherited_typed) — is REJECTED by
   [trawget] AT EVERY TYPE, because raw access reads ONLY own fields and "greet" is
   not an own field. This is precisely "bypasses __index". *)
Example rawget_bypasses_proto : forall T,
  ~ has_type [] [] (trawget [("name"%string, tlit (LStr 1))] (trec oop_base) "greet") T.
Proof.
  intros T H. apply inv_rawget in H.
  destruct H as [Town [Pf [U [Hfs [_ [Hin [_ [_ _]]]]]]]].
  (* OWN fields are exactly [name] (concrete [has_fields]); "greet" is not among
     them. [Hin : ("greet", U) ∈ Town] is therefore refuted. *)
  inversion Hfs as [ | S0 G0 k0 e0 Te0 fs0 Ts0 He0 Hrest E1 E2 E3 E4 ]; subst.
  inversion Hrest; subst.                     (* Town = [("name", Te0)] *)
  simpl in Hin. destruct Hin as [E | F];
    [ injection E; intros _ Ek; discriminate Ek | exact F ].
Qed.

(* RAW WRITE — to OWN's cell, bypassing [__newindex]. Own field [k] is a writable
   [BRef Int] cell [loc0]; the prototype is irrelevant to the write. *)
Definition rawset_own : list (string * tm) := [("k"%string, tloc 0)].
Definition rawsetw : tm := trawset rawset_own (trec []) "k" (tlit (LInt 5)).

(* the raw write is well typed at [nil] under store typing [[Int]]. *)
Example rawset_payoff_typed :
  has_type [BAtom AInt] [] rawsetw (BAtom ANil).
Proof.
  unfold rawsetw, rawset_own.
  eapply (TRawSet [BAtom AInt] [] [("k"%string, tloc 0)] (trec [])
            [("k"%string, BRef (BAtom AInt))] [] "k" (tlit (LInt 5)) (BAtom AInt)).
  - apply HFcons; [ apply (TLoc [BAtom AInt] [] 0); reflexivity | apply HFnil ].
  - repeat constructor; simpl; intuition discriminate.
  - left; reflexivity.                       (* ("k", BRef Int) in OWN *)
  - apply TRec; [ apply HFnil | constructor ].
  - constructor.
  - apply (TLit [BAtom AInt] [] (LInt 5)).
Qed.

(* and it WRITES THROUGH OWN's cell (never the prototype): the dispatch becomes
   [tassign loc0 5], assigning [5] into [loc0]; from store [[0]] the result is
   [nil] and store [[5]]. The records-of-refs write to OWN, end-to-end. *)
Example rawset_payoff_steps :
  multistep (rawsetw, [tlit (LInt 0)]) (tlit LNil, [tlit (LInt 5)]).
Proof.
  unfold rawsetw, rawset_own.
  eapply multistep_trans.
  { apply multistep_one. apply SRawSet.
    - repeat constructor.                     (* own all values *)
    - apply VRec; repeat constructor.         (* proto a value record *)
    - constructor.                            (* 5 is a value *)
    - reflexivity. }                          (* field_lookup "k" own = Some loc0 *)
  apply multistep_one. apply SAssign. constructor.
Qed.

(* THE DISTINGUISHING PROPERTY (raw write): a key absent from OWN is REJECTED — raw
   write never dispatches to the prototype's [__newindex] (contrast [TNewIdx],
   which writes through the prototype for an absent-from-own key). Here own has
   only "k", so [trawset] for "nope" does not type at any type. *)
Example rawset_absent_own_rejected : forall T,
  ~ has_type [BAtom AInt] [] (trawset rawset_own (trec []) "nope" (tlit (LInt 5))) T.
Proof.
  intros T H. apply inv_rawset in H.
  destruct H as [Town [Pf [U [Hfs [_ [Hin [_ [_ [_ _]]]]]]]]].
  unfold rawset_own in Hfs.
  inversion Hfs as [ | S0 G0 k0 e0 Te0 fs0 Ts0 He0 Hrest E1 E2 E3 E4 ]; subst.
  inversion Hrest; subst.                     (* Town = [("k", Te0)] *)
  simpl in Hin. destruct Hin as [E | F];
    [ injection E; intros _ Ek; discriminate Ek | exact F ].
Qed.

(* ===========================================================================
   METATABLE METAMETHOD FAMILY (extension) — __concat (binary), __unm / __len
   (unary). Each reuses the SAME machinery as __add: a metamethod field in the
   table's read interface, dispatched through the [__index] chain. Typed +
   stepped end-to-end.
   =========================================================================== *)

(* ---- __concat: a BINARY operator metamethod, same shape as __add but with NO
   numeric fallback ([PConcat] is metamethod-only). [ccobj] carries a [__concat]
   metamethod [BTop -> BTop -> Str]; [ccobj .. ccobj] dispatches to it. *)
Definition concat_mm : tm := tlam BTop (tlam BTop (tlit (LStr 0))).
Definition ccobj : tm := tmeta [("__concat"%string, concat_mm)] (trec []).

Example concat_payoff_typed :
  has_type [] [] (tprim PConcat ccobj ccobj) (BAtom AStr).
Proof.
  eapply TPrimMetaL.
  - unfold ccobj, concat_mm. eapply TMeta.
    + apply HFcons; [ apply TLam; apply TLam; apply (TLit [] [BTop; BTop] (LStr 0)) | apply HFnil ].
    + repeat constructor; simpl; intuition discriminate.
    + apply TRec; [ apply HFnil | constructor ].
    + constructor.
  - unfold merge_fields. simpl. unfold mm_binop. left; reflexivity.
  - apply RsSsub. apply SsTop.
  - eapply TSub.
    + unfold ccobj, concat_mm. eapply TMeta.
      * apply HFcons; [ apply TLam; apply TLam; apply (TLit [] [BTop; BTop] (LStr 0)) | apply HFnil ].
      * repeat constructor; simpl; intuition discriminate.
      * apply TRec; [ apply HFnil | constructor ].
      * constructor.
    + apply RsSsub. apply SsTop.
Qed.

(* and it COMPUTES: [ccobj .. ccobj] dispatches to [(ccobj.__concat) ccobj ccobj]
   reaching the metamethod's result (a string literal). *)
Example concat_payoff_steps : forall st,
  multistep (tprim PConcat ccobj ccobj, st) (tlit (LStr 0), st).
Proof.
  intro st. unfold ccobj, concat_mm.
  eapply multistep_trans.
  { apply multistep_one. apply SPrimMetaL.
    apply VMeta; [ repeat constructor | apply VRec; constructor ]. }
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SApp1. apply SMetaProjOwn.
    - apply VMeta; [ repeat constructor | apply VRec; constructor ].
    - unfold mm_binop; reflexivity. }
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SBeta.
    apply VMeta; [ repeat constructor | apply VRec; constructor ]. }
  simpl. apply multistep_one. apply SBeta.
  apply VMeta; [ repeat constructor | apply VRec; constructor ].
Qed.

(* ---- __unm / __len: UNARY metamethods. [uobj] carries BOTH [__unm] and [__len]
   metamethods [BTop -> BTop -> Int]; [-uobj] dispatches to [__unm], [#uobj] to
   [__len] (the operand passed TWICE — Lua's unary calling convention). *)
Definition un_mm : tm := tlam BTop (tlam BTop (tlit (LInt 9))).
Definition uobj : tm := tmeta [("__unm"%string, un_mm); ("__len"%string, un_mm)] (trec []).

Lemma uobj_typed : has_type [] [] uobj
  (BRec (merge_fields
    [("__unm"%string, BArrow BTop (BArrow BTop (BAtom AInt)));
     ("__len"%string, BArrow BTop (BArrow BTop (BAtom AInt)))] [])).
Proof.
  unfold uobj, un_mm. eapply TMeta.
  - apply HFcons; [ apply TLam; apply TLam; apply (TLit [] [BTop; BTop] (LInt 9)) | ].
    apply HFcons; [ apply TLam; apply TLam; apply (TLit [] [BTop; BTop] (LInt 9)) | apply HFnil ].
  - repeat constructor; simpl; intuition discriminate.
  - apply TRec; [ apply HFnil | constructor ].
  - constructor.
Qed.

(* [-uobj] (unary minus) is well typed at [Int] via [TUnMetaL] on [__unm]. *)
Example unm_payoff_typed : has_type [] [] (tunop UNeg uobj) (BAtom AInt).
Proof.
  eapply TUnMetaL.
  - apply uobj_typed.
  - unfold merge_fields. simpl. unfold mm_unop. left; reflexivity.
  - apply RsSsub. apply SsTop.
  - apply RsSsub. apply SsTop.
Qed.

(* [#uobj] (length) is well typed at [Int] via [TUnMetaL] on [__len]. *)
Example len_payoff_typed : has_type [] [] (tunop ULen uobj) (BAtom AInt).
Proof.
  eapply TUnMetaL.
  - apply uobj_typed.
  - unfold merge_fields. simpl. unfold mm_unop. right; left; reflexivity.
  - apply RsSsub. apply SsTop.
  - apply RsSsub. apply SsTop.
Qed.

(* and [-uobj] COMPUTES: dispatch to [(uobj.__unm) uobj uobj] ⤳ the result [9]. *)
Example unm_payoff_steps : forall st,
  multistep (tunop UNeg uobj, st) (tlit (LInt 9), st).
Proof.
  intro st. unfold uobj, un_mm.
  eapply multistep_trans.
  { apply multistep_one. apply SUnMetaL.
    apply VMeta; [ repeat constructor | apply VRec; constructor ]. }
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SApp1. apply SMetaProjOwn.
    - apply VMeta; [ repeat constructor | apply VRec; constructor ].
    - unfold mm_unop; reflexivity. }
  eapply multistep_trans.
  { apply multistep_one. apply SApp1. apply SBeta.
    apply VMeta; [ repeat constructor | apply VRec; constructor ]. }
  simpl. apply multistep_one. apply SBeta.
  apply VMeta; [ repeat constructor | apply VRec; constructor ].
Qed.

(* a unary operator whose metamethod is ABSENT is REJECTED. [ccobj] has [__concat]
   but neither [__unm] nor [__len], so [#ccobj] does not type. *)
Example len_absent_rejected : forall T,
  ~ has_type [] [] (tunop ULen ccobj) T.
Proof.
  intros T H. apply inv_unop in H.
  destruct H as [ofs [proto [M [Self [Other [R [Ea [Htbl [Hin [_ [_ _]]]]]]]]]]].
  unfold ccobj in Ea. injection Ea as <- <-.
  apply inv_meta in Htbl.
  destruct Htbl as [Tw [Pf [Hfs [_ [Hp [_ HsubRec]]]]]].
  unfold ccobj, concat_mm in Hfs.
  inversion Hfs as [ | S0 G0 k0 e0 Te0 fs0 Ts0 He0 Hrest E1 E2 E3 ]; subst.
  inversion Hrest; subst.
  apply inv_rec in Hp. destruct Hp as [Pbase [Hpb [_ HsubP]]].
  inversion Hpb; subst.
  apply rsub_rec_super in HsubP. simpl in HsubP.
  destruct (rsub_rec_inv (merge_fields [("__concat"%string, Te0)] Pf) M
              "__len"%string (BArrow Self (BArrow Other R)) HsubRec Hin)
    as [Tg [HinTg _]].
  assert (Hk : In "__len"%string (map fst (merge_fields [("__concat"%string, Te0)] Pf)))
    by (replace "__len"%string with (fst ("__len"%string, Tg)) by reflexivity;
        apply in_map; exact HinTg).
  apply merge_fields_key_in in Hk.
  destruct Hk as [Hown | Hproto].
  - simpl in Hown. destruct Hown as [E | F]; [ discriminate E | exact F ].
  - apply in_map_iff in Hproto. destruct Hproto as [[k' T'] [Ek' HinPf]].
    simpl in Ek'. subst k'.
    destruct (srec_lookup _ _ HsubP "__len"%string T' HinPf) as [Tf [Hinb _]].
    simpl in Hinb. exact Hinb.
Qed.

(* ===========================================================================
   INCREMENT — NUMERIC FOR-LOOP:  for i = e1, e2, e3 do body end  (Lua 5.1).

   Like the [while]-loop (increment 20) this is an ENCODING over the existing core
   — NO new core terms, NO new subtyping, NO change to lift/subst/progress/
   preservation/check.v. It REDUCES to the already-proven [twhile] + reference +
   arithmetic + comparison + local-binding substrate; soundness is inherited from
   [twhile_typed]/[twhile_unfold] (hence from [progress]+[preservation]).

   WHY DESUGAR (not a new primitive). The while-loop already supplies the exact
   step/typing discipline a numeric-for needs: a fixpoint whose condition re-reads
   the store, a body that mutates it, and store-driven termination. Numeric-for is
   while-with-bookkeeping (an init, a bound-test, an increment). Reusing [twhile]
   gives the loop's metatheory for free and keeps the addition ad-hoc-free.

   LUA 5.1 SEMANTICS modelled.  [for i = e1, e2, e3 do body end]:
     - e1 (init), e2 (limit), e3 (step) are evaluated ONCE at loop entry. Here e1
       is the value placed in the counter CELL (allocated once), and e2/e3 are the
       closed number terms substituted into the condition / increment.
     - The loop variable [i] is FRESH PER ITERATION: each iteration re-reads the
       counter cell ([tderef cnt]) — the body never aliases a mutable outer [i],
       exactly Lua's per-iteration binding (faithful under the store model: the
       value the body sees is the current counter, re-fetched each turn).
     - Iteration continues while  (step>0 /\ i<=limit) \/ (step<0 /\ i>=limit);
       each iteration runs [body] then  i := i + step.

   STEP-SIGN / NAT SUBSTRATE (honest boundary, NOT a faked gap — verified against the
   core). The number model is [nat]-backed at BOTH levels: the value [VNum] carries
   [NRint nat] / [NRfrac nat] (subtype.v — no negative number value), the only number
   literal is [LInt : nat], arithmetic is [nat] ([prim_arith]; [PSub] is TRUNCATING,
   [5 - 7 = 0]), and [tunop UNeg] dispatches only on metatable values ([SUnMetaL]) — it
   is STUCK on a plain number. Hence NO term evaluates to a negative number.

   The blocker for a single runtime-sign-dispatched form is NOT the guard: a runtime
   sign test [0 < step] IS expressible ([PLt] + [tif] both exist), but it is VACUOUS —
   every number value is [>= 0], so there is no negative step to dispatch on. The deeper
   blocker is the UPDATE: the faithful single-form Lua 5.1 body is [i := i + step] with a
   SIGNED step (negative descends); here [+] is [nat] addition, so [i := i + step] can
   ONLY ascend for every representable step. Descent is therefore carried ENTIRELY by
   switching the update operator to [PSub] (the [tfor_down] encoding) — a STATIC choice,
   since no negative step value exists to select on at runtime.

   CONCRETE BLOCKED TERM: [for i = 2, 1, c do body end] with [c] meant to be [-1] — no
   term produces [-1] ([LInt] is [nat]; [tunop UNeg (tlit (LInt 1))] is stuck;
   [tprim PSub (tlit (LInt 0)) (tlit (LInt 1))] truncates to [0]), and [i := i + c] never
   descends. The FAITHFUL nat-substrate rendering resolves the step's SIGN STATICALLY (as
   a real compiler does for a constant step) into one of two encodings, mirroring the
   while-loop's ascending [cinc] (PAdd / PLt) :
     - [tfor_up]   : step>0 — guard [!i <= limit], increment [i := !i + step].
     - [tfor_down] : step<0 — guard [limit <= !i] (i.e. [i >= limit]), decrement
                     [i := !i - step] (step the POSITIVE magnitude; the descent is
                     carried by the subtraction direction, since nat has no sign).
   This is the 3-value form (init, limit, step magnitude all explicit), faithful to
   5.1 modulo the nat number model. A single runtime form deciding direction needs a
   SIGNED number model (signed [NumRep] / [LInt] + a sign-aware [PSub] or working number
   [PNeg]) — recorded as a substrate need, not faked.

   LOOP-VARIABLE TYPING (5.1).  [i = !cnt] is typed at the NUMBER type [ANum]. The
   counter cell is a [BRef ANum] cell: the increment [i := !i + step] stores the
   arithmetic result, which [TPrimArith] gives type [ANum], and a [BRef] cell is
   INVARIANT, so the cell must be a [Num] cell; thus [!cnt : ANum]. The initial
   [LInt n : AInt] widens to [ANum] at allocation by subsumption ([AInt <: ANum]).
   This is precise FOR THIS DEV'S NUMBER MODEL: arithmetic yields [ANum]; the
   precise [Int+Int : AInt] preservation is the SAME deferred substrate the while-
   loop's [sumloop] note records (needs Int-preserving arithmetic result types),
   so an all-int loop's counter is soundly — not over- — typed at [ANum]. Exactly
   Lua's single-number model: [i] is a number.
   =========================================================================== *)

(* ASCENDING numeric-for (step > 0). [cnt] is the counter cell (a reference term,
   e.g. [tloc n] or [tvar k] positioned for use INSIDE the loop, under the fix
   self-ref binder); [limit]/[step] are closed number terms; [body] is the unit
   statement (it reads the loop variable via [tderef cnt]). Reduces to [twhile]:
   loop while [!cnt <= limit]; each turn run [body] then [cnt := !cnt + step]. *)
Definition tfor_up (cnt limit step body : tm) : tm :=
  twhile (tprim PLe (tderef cnt) limit)
         (tseq body (tassign cnt (tprim PAdd (tderef cnt) step))).

(* DESCENDING numeric-for (step < 0; [step] is the positive magnitude). Loop while
   [limit <= !cnt] (i.e. [i >= limit]); each turn run [body] then [cnt := !cnt - step]. *)
Definition tfor_down (cnt limit step body : tm) : tm :=
  twhile (tprim PLe limit (tderef cnt))
         (tseq body (tassign cnt (tprim PSub (tderef cnt) step))).

(* THE LOOP VARIABLE IS A NUMBER. Whenever the counter cell is a [Num] cell,
   reading the loop variable [i = !cnt] yields the number type [ANum] — the 5.1
   typing of a numeric-for variable. (Stated abstractly over the cell reference so
   it holds for both the [tloc] and [tvar] forms.) *)
Lemma for_var_is_number : forall S G cnt,
  has_type S G cnt (BRef (BAtom ANum)) ->
  has_type S G (tderef cnt) (BAtom ANum).
Proof. intros S G cnt Hc. apply TDeref with (T := BAtom ANum). exact Hc. Qed.

(* TYPING the ascending loop. Under the self-ref binder ([Tunit :: G]) the counter
   is a [Num] cell, [limit]/[step] are numbers, and [body] is a unit statement; the
   whole loop is a unit statement. Inherits from [twhile_typed]. *)
Lemma tfor_up_typed : forall S G cnt limit step body,
  has_type S (Tunit :: G) cnt (BRef (BAtom ANum)) ->
  has_type S (Tunit :: G) limit (BAtom ANum) ->
  has_type S (Tunit :: G) step (BAtom ANum) ->
  has_type S (Tunit :: G) body Tunit ->
  has_type S G (tfor_up cnt limit step body) Tunit.
Proof.
  intros S G cnt limit step body Hc Hl Hs Hbody. unfold tfor_up.
  apply twhile_typed.
  - (* condition  !cnt <= limit : Bool *)
    apply TPrimCmp; [ reflexivity | apply for_var_is_number; exact Hc | exact Hl ].
  - (* body ; cnt := !cnt + step : Tunit *)
    eapply tseq_typed; [ exact Hbody | ].
    eapply TAssign with (T := BAtom ANum); [ exact Hc | ].
    apply TPrimArith; [ reflexivity | apply for_var_is_number; exact Hc | exact Hs ].
Qed.

(* TYPING the descending loop (same shape; guard and update swapped). *)
Lemma tfor_down_typed : forall S G cnt limit step body,
  has_type S (Tunit :: G) cnt (BRef (BAtom ANum)) ->
  has_type S (Tunit :: G) limit (BAtom ANum) ->
  has_type S (Tunit :: G) step (BAtom ANum) ->
  has_type S (Tunit :: G) body Tunit ->
  has_type S G (tfor_down cnt limit step body) Tunit.
Proof.
  intros S G cnt limit step body Hc Hl Hs Hbody. unfold tfor_down.
  apply twhile_typed.
  - apply TPrimCmp; [ reflexivity | exact Hl | apply for_var_is_number; exact Hc ].
  - eapply tseq_typed; [ exact Hbody | ].
    eapply TAssign with (T := BAtom ANum); [ exact Hc | ].
    apply TPrimArith; [ reflexivity | apply for_var_is_number; exact Hc | exact Hs ].
Qed.

(* ---------------------------------------------------------------------------
   PAYOFF 1 — A COUNTING LOOP THAT TYPES AND STEPS:  sum 1..3 into an accumulator.

     sum = 0;  for i = 1, 3, 1 do  sum := sum + i  end     (* sum = 6 *)

   Two cells: [sum] = loc 0, the counter [i] = loc 1 (init 1). The body adds the
   loop variable [!i] to [sum]; the loop increments [i] by 1 until [i > 3].
   --------------------------------------------------------------------------- *)

(* the body  [ sum := !sum + !i ]  with [sum]=loc0, [i]=loc1 (both closed values). *)
Definition forsum_body : tm :=
  tassign (tloc 0) (tprim PAdd (tderef (tloc 0)) (tderef (tloc 1))).
Definition forsum_loop : tm :=
  tfor_up (tloc 1) (tlit (LInt 3)) (tlit (LInt 1)) forsum_body.

(* it TYPES at [Tunit] under store-typing [Num; Num] (both cells are Num cells). *)
Example forsum_loop_typed :
  has_type [ BAtom ANum ; BAtom ANum ] [] forsum_loop Tunit.
Proof.
  unfold forsum_loop. apply tfor_up_typed.
  - apply TLoc. reflexivity.                                   (* counter loc1 : Num cell *)
  - eapply TSub; [ apply (TLit _ _ (LInt 3)) | apply RsSsub; apply SsAtom; apply ALInt ].
  - eapply TSub; [ apply (TLit _ _ (LInt 1)) | apply RsSsub; apply SsAtom; apply ALInt ].
  - unfold forsum_body. eapply TAssign with (T := BAtom ANum).
    + apply TLoc. reflexivity.
    + apply TPrimArith; [ reflexivity | | ].
      * apply TDeref with (T := BAtom ANum). apply TLoc. reflexivity.
      * apply TDeref with (T := BAtom ANum). apply TLoc. reflexivity.
Qed.

(* the counter/condition/body are CLOSED (only [tloc]s, values), so the fix-unfold
   substitution leaves them unchanged. *)
Lemma forsum_cond_closed : forall s,
  subst 0 s (tprim PLe (tderef (tloc 1)) (tlit (LInt 3))) =
  tprim PLe (tderef (tloc 1)) (tlit (LInt 3)).
Proof. reflexivity. Qed.
Lemma forsum_step_closed : forall s,
  subst 0 s (tseq forsum_body (tassign (tloc 1)
               (tprim PAdd (tderef (tloc 1)) (tlit (LInt 1))))) =
  tseq forsum_body (tassign (tloc 1)
               (tprim PAdd (tderef (tloc 1)) (tlit (LInt 1)))).
Proof. reflexivity. Qed.

(* ONE ITERATION at counter value [c] (with [c <= 3] so the guard is true), store
   [sum=s ; i=c]: the loop unfolds, reads [c <= 3 = true], runs the body (sum ->
   s+c), then increments the counter (i -> c+1) — leaving control back at the loop
   with store [s+c ; c+1]. Machine-checked, store-driven. *)
Lemma forsum_one_iter : forall s c,
  Nat.leb c 3 = true ->
  multistep (forsum_loop, [tlit (LInt s) ; tlit (LInt c)])
            (forsum_loop, [tlit (LInt (s + c)) ; tlit (LInt (c + 1))]).
Proof.
  intros s c Hle. unfold forsum_loop, tfor_up.
  eapply MSstep. { apply twhile_unfold. }
  rewrite forsum_cond_closed, forsum_step_closed.
  (* condition  !(loc1) <= 3 : read the counter c, then compute  c <= 3 = true *)
  eapply MSstep. { apply SIf1. apply SPrim1. apply SDeref. } simpl.
  eapply MSstep. { apply SIf1. apply SPrimCmp. reflexivity. }
  unfold prim_cmp. rewrite Hle.
  eapply MSstep. { apply SIfTrue. }
  (* body  sum := !sum + !i : read s, read c, add, write s+c -> store [s+c ; c] *)
  unfold forsum_body.
  eapply MSstep. { apply tseq_step1. apply tseq_step1.
                   apply SAssign2; [ apply VLoc | apply SPrim1; apply SDeref ]. } simpl.
  eapply MSstep. { apply tseq_step1. apply tseq_step1.
                   apply SAssign2; [ apply VLoc | apply SPrim2; [ apply VLit | apply SDeref ] ]. } simpl.
  eapply MSstep. { apply tseq_step1. apply tseq_step1.
                   apply SAssign2; [ apply VLoc | apply SPrimArith; reflexivity ]. } simpl.
  eapply MSstep. { apply tseq_step1. apply tseq_step1. apply SAssign. apply VLit. } simpl.
  (* the body finished (nil); discard it and run the increment *)
  eapply MSstep. { apply tseq_step1. apply tseq_step_value. apply VLit. }
  (* increment  i := !i + 1 : read c, add 1, write c+1 -> store [s+c ; c+1] *)
  eapply MSstep. { apply tseq_step1.
                   apply SAssign2; [ apply VLoc | apply SPrim1; apply SDeref ]. } simpl.
  eapply MSstep. { apply tseq_step1.
                   apply SAssign2; [ apply VLoc | apply SPrimArith; reflexivity ]. } simpl.
  eapply MSstep. { apply tseq_step1. apply SAssign. apply VLit. } simpl.
  (* the increment finished (nil); the outer sequence yields the loop again *)
  eapply MSstep. { apply tseq_step_value. apply VLit. }
  apply MSrefl.
Qed.

(* TERMINATION: at counter value [c] with [c > 3] (guard false), the loop reads the
   store, the condition is FALSE, and the loop ends with [nil] — store unchanged. *)
Lemma forsum_terminates : forall s c,
  Nat.leb c 3 = false ->
  multistep (forsum_loop, [tlit (LInt s) ; tlit (LInt c)])
            (tlit LNil, [tlit (LInt s) ; tlit (LInt c)]).
Proof.
  intros s c Hgt. unfold forsum_loop, tfor_up.
  eapply MSstep. { apply twhile_unfold. }
  rewrite forsum_cond_closed, forsum_step_closed.
  eapply MSstep. { apply SIf1. apply SPrim1. apply SDeref. } simpl.
  eapply MSstep. { apply SIf1. apply SPrimCmp. reflexivity. }
  unfold prim_cmp. rewrite Hgt.
  eapply MSstep. { apply SIfFalse. }
  apply MSrefl.
Qed.

(* THE WHOLE LOOP, END-TO-END: from [sum=0 ; i=1] it runs three iterations
   (i=1,2,3) and terminates at i=4, computing  sum = 0+1+2+3 = 6.  Store
   [0;1] -> [1;2] -> [3;3] -> [6;4] -> (i=4>3, stop) [6;4]. *)
Example forsum_loop_runs :
  multistep (forsum_loop, [tlit (LInt 0) ; tlit (LInt 1)])
            (tlit LNil, [tlit (LInt 6) ; tlit (LInt 4)]).
Proof.
  eapply multistep_trans. { apply (forsum_one_iter 0 1). reflexivity. } simpl.
  eapply multistep_trans. { apply (forsum_one_iter 1 2). reflexivity. } simpl.
  eapply multistep_trans. { apply (forsum_one_iter 3 3). reflexivity. } simpl.
  apply (forsum_terminates 6 4). reflexivity.
Qed.

(* ---------------------------------------------------------------------------
   PAYOFF 2 — A COUNTING-DOWN LOOP THAT TERMINATES:  for i = 2, 1, -1 do () end.

   The descending form ([tfor_down]): counter starts at 2, limit 1, step magnitude
   1; guard [1 <= !i]; each turn decrement  i := !i - 1. Body is the unit statement
   [()] (we exhibit termination of the loop control itself). One cell, [i] = loc 0.
   Iterations: i=2 (1<=2 true, ->1), i=1 (1<=1 true, ->0), i=0 (1<=0 false) stop.
   --------------------------------------------------------------------------- *)

Definition fordown_loop : tm :=
  tfor_down (tloc 0) (tlit (LInt 1)) (tlit (LInt 1)) (tlit LNil).

(* it TYPES at [Tunit] under a single [Num] cell. *)
Example fordown_loop_typed :
  has_type [ BAtom ANum ] [] fordown_loop Tunit.
Proof.
  unfold fordown_loop. apply tfor_down_typed.
  - apply TLoc. reflexivity.
  - eapply TSub; [ apply (TLit _ _ (LInt 1)) | apply RsSsub; apply SsAtom; apply ALInt ].
  - eapply TSub; [ apply (TLit _ _ (LInt 1)) | apply RsSsub; apply SsAtom; apply ALInt ].
  - apply (TLit _ _ LNil).
Qed.

Lemma fordown_cond_closed : forall s,
  subst 0 s (tprim PLe (tlit (LInt 1)) (tderef (tloc 0))) =
  tprim PLe (tlit (LInt 1)) (tderef (tloc 0)).
Proof. reflexivity. Qed.
Lemma fordown_step_closed : forall s,
  subst 0 s (tseq (tlit LNil)
               (tassign (tloc 0) (tprim PSub (tderef (tloc 0)) (tlit (LInt 1))))) =
  tseq (tlit LNil)
       (tassign (tloc 0) (tprim PSub (tderef (tloc 0)) (tlit (LInt 1)))).
Proof. reflexivity. Qed.

(* ONE DECREMENTING ITERATION at counter [c] with guard [1 <= c] true: the loop
   reads the store, runs the (empty) body, then decrements  i := c - 1. *)
Lemma fordown_one_iter : forall c,
  Nat.leb 1 c = true ->
  multistep (fordown_loop, [tlit (LInt c)])
            (fordown_loop, [tlit (LInt (c - 1))]).
Proof.
  intros c Hge. unfold fordown_loop, tfor_down.
  eapply MSstep. { apply twhile_unfold. }
  rewrite fordown_cond_closed, fordown_step_closed.
  (* condition  1 <= !(loc0) : read c, compute  1 <= c = true *)
  eapply MSstep. { apply SIf1. apply SPrim2; [ apply VLit | apply SDeref ]. } simpl.
  eapply MSstep. { apply SIf1. apply SPrimCmp. reflexivity. }
  unfold prim_cmp. rewrite Hge.
  eapply MSstep. { apply SIfTrue. }
  (* the loop body [body ; decrement] : the body is the unit value [nil], the inner
     sequence discards it, leaving the decrement. *)
  eapply MSstep. { apply tseq_step1. apply tseq_step_value. apply VLit. }
  (* decrement  i := !i - 1 : read c, subtract 1, write c-1 *)
  eapply MSstep. { apply tseq_step1.
                   apply SAssign2; [ apply VLoc | apply SPrim1; apply SDeref ]. } simpl.
  eapply MSstep. { apply tseq_step1.
                   apply SAssign2; [ apply VLoc | apply SPrimArith; reflexivity ]. } simpl.
  eapply MSstep. { apply tseq_step1. apply SAssign. apply VLit. } simpl.
  (* the decrement finished (nil); the outer sequence yields the loop again *)
  eapply MSstep. { apply tseq_step_value. apply VLit. }
  apply MSrefl.
Qed.

(* TERMINATION: at counter [c] with guard [1 <= c] FALSE (c = 0), the loop ends. *)
Lemma fordown_terminates : forall c,
  Nat.leb 1 c = false ->
  multistep (fordown_loop, [tlit (LInt c)]) (tlit LNil, [tlit (LInt c)]).
Proof.
  intros c Hlt. unfold fordown_loop, tfor_down.
  eapply MSstep. { apply twhile_unfold. }
  rewrite fordown_cond_closed, fordown_step_closed.
  eapply MSstep. { apply SIf1. apply SPrim2; [ apply VLit | apply SDeref ]. } simpl.
  eapply MSstep. { apply SIf1. apply SPrimCmp. reflexivity. }
  unfold prim_cmp. rewrite Hlt.
  eapply MSstep. { apply SIfFalse. }
  apply MSrefl.
Qed.

(* THE WHOLE COUNTING-DOWN LOOP, END-TO-END: from [i=2] it decrements 2 -> 1 -> 0
   and terminates (1 <= 0 false). A negative-step loop computed to its end. *)
Example fordown_loop_runs :
  multistep (fordown_loop, [tlit (LInt 2)]) (tlit LNil, [tlit (LInt 0)]).
Proof.
  eapply multistep_trans. { apply (fordown_one_iter 2). reflexivity. } simpl.
  eapply multistep_trans. { apply (fordown_one_iter 1). reflexivity. } simpl.
  apply (fordown_terminates 0). reflexivity.
Qed.

(* ---------------------------------------------------------------------------
   PAYOFF 3 — THE LOOP VARIABLE IS TYPED SOUNDLY AS A NUMBER. In the [forsum]
   context (the counter is a [Num] cell at loc 1), the loop variable [i = !i] has
   the number type [ANum] — and an INT consumer of it is REJECTED (the variable is
   not narrowed to [Int]; it is the full number type, exactly 5.1's number model).
   --------------------------------------------------------------------------- *)

(* [i = !(loc 1)] is typed at the NUMBER type [ANum]. *)
Example for_var_typed_number :
  has_type [ BAtom ANum ; BAtom ANum ] [] (tderef (tloc 1)) (BAtom ANum).
Proof. apply for_var_is_number. apply TLoc. reflexivity. Qed.

(* and the loop variable is NOT an [Int]: a number is not soundly an [Int]
   ([ANum </: AInt]), so [i] cannot be typed at [AInt] — Lua's number model: the
   numeric-for variable is a NUMBER, not an integer. *)
Example for_var_not_int :
  ~ has_type [ BAtom ANum ; BAtom ANum ] [] (tderef (tloc 1)) (BAtom AInt).
Proof.
  intro H. apply inv_deref in H. destruct H as [U [Hc Hsub]].
  apply inv_loc in Hc. destruct Hc as [T0 [Hnth HsubR]].
  simpl in Hnth. injection Hnth as <-.
  (* HsubR : BRef ANum <: BRef U   ==>  U == ANum (ref invariance);
     Hsub  : U <: AInt.  Then ANum <: AInt, impossible (NRfrac witness). *)
  apply rsub_ref_inv in HsubR. destruct HsubR as [Hsu Hus].
  pose proof (rsub_trans _ _ _ Hsu Hsub) as Hbad.   (* ANum <: AInt *)
  apply rsub_sound in Hbad.
  (* a NON-integer number [VNum (NRfrac 0)] inhabits ANum but NOT AInt. *)
  pose proof (Hbad (VNum (NRfrac 0)) I) as Hcontra. simpl in Hcontra. exact Hcontra.
Qed.

(* ===========================================================================
   INCREMENT — GENERIC FOR-IN LOOP:  for v1,…,vn in explist do body end (Lua 5.1).

   Like the numeric-for (previous increment) and the while-loop (increment 20)
   this is an ENCODING over the existing core — NO new core term, NO new
   subtyping, NO change to lift/subst/progress/preservation/check.v. It REDUCES
   to the already-proven [twhile] + multiple-assignment ([tmassign]) + function
   application ([tapp]) + truthiness narrowing ([tifn]) + reference substrate;
   soundness is inherited from [twhile_typed]/[twhile_unfold] (hence from
   [progress]+[preservation]). It adds NO new check.v synth arm — the build stays
   fast (no O(constructors²) blowup).

   WHY DESUGAR (not a new primitive). Lua's own definition of generic-for IS a
   desugaring into while + a multi-bind of an iterator call + a nil-termination
   test (the standard 5.1 expansion). Every ingredient already exists as proven
   substrate: [twhile] (the loop with store-driven termination), [tmassign] (bind
   the n loop variables from the iterator's multi-return, with arity adjustment),
   [tapp] (call the iterator), [tifn] (narrow the first loop variable past nil).
   Reusing them gives the loop's whole metatheory for free and keeps the addition
   ad-hoc-free.

   LUA 5.1 SEMANTICS modelled.  [for v1,…,vn in explist do body end] ≡
     local f, s, ctrl = explist        -- iterator fn f, state s, initial control
     while true do
       local v1,…,vn = f(s, ctrl)      -- call iterator → multi-return
       if v1 == nil then break end     -- nil in the FIRST var terminates
       ctrl = v1                        -- advance control to first result
       body
     end
   The KEY MODELING MOVE (avoids needing [break], which this dev does not have):
   FOLD the nil-termination into the loop GUARD, exactly as numeric-for folded its
   termination into the [twhile] guard. The iterator is called ONCE per iteration
   (it sits in the [twhile] CONDITION, which [twhile_unfold] re-evaluates against
   the current store each turn); its first result both (a) drives termination —
   nil/falsy ⇒ stop — and (b) becomes the next control value (advanced in the
   body). Loop state f/s and the bound vars/control live in MUTABLE STORE CELLS
   (locations), mirroring how numeric-for / while manage mutable loop state.

   TERMINATION-AS-TRUTHINESS (the faithful narrowing boundary, NOT faked). Lua
   terminates on [v1 == nil] EXACTLY. The narrowing substrate this dev has that
   yields a USABLE non-nil type for the body is TRUTHINESS narrowing ([tifn]):
   the then-branch narrows the scrutinee to [truthy_type] (the non-nil, non-false
   bound). A standard iterator yields a non-falsy element or nil, so on its
   results truthiness COINCIDES with non-nil; we therefore fold termination as
   "first result truthy" and the body sees [v1 : truthy_type] (the EXISTING
   expressible non-nil narrowing — exactly the truthiness increment's bound). The
   precise [v1 : V1 ∩ ¬nil] narrowing is the SAME intersection-narrowing substrate
   gap the [TIfn] note already records (proof-kernel.md / TODO.md); using the
   truthy bound is sound and Lua-faithful for the iterator protocol — not faked.

   CONTROL TYPE = V1 (compatible-with-V1, no new substrate). The control advances
   to v1 each step ([ctrl := !v1cell]); both the control cell and v1cell are typed
   at the SAME [V1 = T ∪ nil] shape, so the advance type-checks by reflexivity. A
   real iterator receives the previous loop variable as its control argument and
   narrows it itself — modelled here by the iterator's body doing a [ttypetest]/
   [tifn] on its control before using it, exactly Lua's stateful-iterator pattern.
   =========================================================================== *)

(* THE GENERIC FOR-IN GUARD (runs once per iteration as the [twhile] condition).
   It (1) calls the iterator [iter_call] (a multivalue-typed call), (2) binds the
   n results into the result cells [vcells] via multiple-assignment (arity
   adjustment for free), then (3) tests the FIRST result cell [v1cell] for
   truthiness, yielding a Bool: [true] continues the loop, [false] (falsy ⇒ nil)
   terminates it. The truthiness test is [tifn (!v1cell) true false] — a Bool that
   is [true] iff the cell holds a truthy (non-nil) value. *)
Definition forin_guard (vcells : list tm) (v1cell iter_call : tm) : tm :=
  tseq (tmassign vcells iter_call)
       (tifn (tderef v1cell) (tlit (LBool true)) (tlit (LBool false))).

(* THE GENERIC FOR-IN BODY (runs after a truthy guard). It (1) advances the control
   cell to the first result [ctrl := !v1cell] (both [V1 = T ∪ nil]-typed, so this
   type-checks), then (2) runs the user [body] under the NARROWED first loop
   variable: [tifn (!v1cell) body nil] re-reads [v1cell] (the guard just
   established it is truthy, so this selects the then-branch and SUBSTITUTES the
   value, narrowed to [truthy_type], at de Bruijn 0 in [body]). The user [body]
   references [v1] as de Bruijn 0 (narrowed non-nil); v2…vn it reads from their
   cells [!v2cell …] (at their tuple types). *)
Definition forin_body (ctrlcell v1cell body : tm) : tm :=
  tseq (tassign ctrlcell (tderef v1cell))
       (tifn (tderef v1cell) body (tlit LNil)).

(* THE GENERIC FOR-IN LOOP — the [twhile] of the guard over the body. *)
Definition tforin (vcells : list tm) (ctrlcell v1cell iter_call body : tm) : tm :=
  twhile (forin_guard vcells v1cell iter_call)
         (forin_body ctrlcell v1cell body).

(* TYPING the loop. Under the self-ref binder ([Tunit :: G]):
   - the guard's [tmassign] binds the iterator's multi-return into the result
     cells (whatever the multiple-assignment rule demands of caller),
   - the truthiness test yields Bool, so the whole guard is Bool;
   - the body's control-advance and narrowed user-body are unit statements.
   Inherits [Tunit] from [twhile_typed]. We package the obligations as the caller-
   supplied derivations of the two halves (guard : Bool, body : Tunit), keeping the
   rule a thin wrapper over [twhile_typed]. *)
Lemma tforin_typed : forall S G vcells ctrlcell v1cell iter_call body,
  has_type S (Tunit :: G) (forin_guard vcells v1cell iter_call) (BAtom ABool) ->
  has_type S (Tunit :: G) (forin_body ctrlcell v1cell body) Tunit ->
  has_type S G (tforin vcells ctrlcell v1cell iter_call body) Tunit.
Proof.
  intros S G vcells ctrlcell v1cell iter_call body Hg Hb.
  unfold tforin. apply twhile_typed; [ exact Hg | exact Hb ].
Qed.

(* The guard is a Bool whenever the multi-assignment is well typed (yields nil) and
   the first cell is a reference: the [tifn true/false] is [Bool ∪ Bool ⊑ Bool]. *)
Lemma forin_guard_typed : forall S G vcells v1cell iter_call,
  has_type S G (tmassign vcells iter_call) (BAtom ANil) ->
  (exists V1, has_type S G (tderef v1cell) V1) ->
  has_type S G (forin_guard vcells v1cell iter_call) (BAtom ABool).
Proof.
  intros S G vcells v1cell iter_call Hma [V1 Hd]. unfold forin_guard.
  eapply tseq_typed; [ exact Hma | ].
  eapply TSub.
  - eapply TIfn with (U := V1);
      [ exact Hd
      | apply (TLit S (truthy_type :: G) (LBool true))
      | apply (TLit S (falsy_type  :: G) (LBool false)) ].
  - (* Bool ∪ Bool ⊑ Bool *) apply RsSsub. apply SsUnionE; apply SsRefl.
Qed.

(* The body is a unit statement whenever the control-advance type-checks (control
   cell and v1cell share the [V1] shape) and the user body types at unit UNDER THE
   NARROWED first loop variable (de Bruijn 0 : [truthy_type]). *)
Lemma forin_body_typed : forall S G ctrlcell v1cell body V1,
  has_type S G ctrlcell (BRef V1) ->
  has_type S G (tderef v1cell) V1 ->
  has_type S (truthy_type :: G) body Tunit ->
  has_type S G (forin_body ctrlcell v1cell body) Tunit.
Proof.
  intros S G ctrlcell v1cell body V1 Hctrl Hd Hbody. unfold forin_body.
  eapply tseq_typed.
  - (* ctrl := !v1cell : nil  — both V1-shaped *)
    eapply TAssign; [ exact Hctrl | exact Hd ].
  - (* tifn (!v1cell) body nil : Tunit  — then-branch [body : Tunit] narrows v1 to
       truthy_type; else-branch [nil : Tunit]; union ⊑ Tunit. *)
    eapply TSub.
    + eapply TIfn with (U := V1);
        [ exact Hd | exact Hbody | apply (TLit S (falsy_type :: G) LNil) ].
    + (* Tunit ∪ Tunit ⊑ Tunit *) apply RsSsub. apply SsUnionE; apply SsRefl.
Qed.

(* ---------------------------------------------------------------------------
   PAYOFF — A CONCRETE GENERIC-FOR over a small explicit iterator, single loop
   variable [v1 : Num ∪ nil].

   The ITERATOR is a closed function [iter : (Num ∪ nil) -> BTuple [Num ∪ nil]]:
   given the previous control [c], it narrows [c] to a number ([ttypetest TgNum])
   and, while [c < 3], yields [c + 1]; once [c >= 3] (or [c] is nil) it yields
   [nil] — a finite sequence 1, 2, 3 then nil, driven by the control thread. The
   LOOP accumulates: a counter cell [cnt] is incremented once per (truthy)
   iteration, so after the 3 yielded values [cnt = 3]; the loop then sees [nil]
   and TERMINATES.

   STORE LAYOUT:  loc0 = cnt (the accumulator, Num),  loc1 = v1cell (the bound
   loop variable, Num ∪ nil),  loc2 = ctrlcell (the control, Num ∪ nil).
   --------------------------------------------------------------------------- *)

(* the V1 type: a number or nil — what the iterator yields, what the cells hold. *)
Definition forin_V1 : BTy := BUnion (BAtom ANum) (BAtom ANil).

(* the iterator BODY, under its parameter [c : Num ∪ nil] (de Bruijn 0). It narrows
   [c] with [ttypetest TgNum]: in the number case (then) it computes [if c < 3 then
   c+1 else nil]; in the nil case (else) it yields [nil]. The whole element is
   [Num ∪ nil]; wrapped in [tret [·]] it is the multivalue [BTuple [Num ∪ nil]]. *)
Definition forin_iter : tm :=
  tlam forin_V1
    (tret [ ttypetest TgNum (tvar 0)
              (* c : Num  ==>  if c < 3 then c+1 else nil *)
              (tif (tprim PLt (tvar 0) (tlit (LInt 3)))
                   (tprim PAdd (tvar 0) (tlit (LInt 1)))
                   (tlit LNil))
              (* c : nil (or non-number) ==> nil *)
              (tlit LNil) ]).

(* the iterator CALL each iteration: [iter (!ctrlcell)] (control = loc2). *)
Definition forin_call : tm := tapp forin_iter (tderef (tloc 2)).

(* the user BODY: [cnt := !cnt + 1] (loc0), counting iterations. It does NOT use the
   loop variable's NUMERIC value (that would need [truthy_type ⊑ Num] — the
   intersection-narrowing gap); it demonstrates the loop running to completion and
   accumulating. The narrowed [v1] (de Bruijn 0) is in scope but unused here. *)
Definition forin_user_body : tm :=
  tassign (tloc 0) (tprim PAdd (tderef (tloc 0)) (tlit (LInt 1))).

Definition forin_loop : tm :=
  tforin [ tloc 1 ] (tloc 2) (tloc 1) forin_call forin_user_body.

(* the store typing: [cnt : Num ; v1cell : Num∪nil ; ctrlcell : Num∪nil]. *)
Definition forin_S : list BTy := [ BAtom ANum ; forin_V1 ; forin_V1 ].

(* THE ITERATOR TYPES at [(Num ∪ nil) -> BTuple [Num ∪ nil]]. *)
Lemma forin_iter_typed :
  has_type forin_S [] forin_iter (BArrow forin_V1 (BTuple [ forin_V1 ])).
Proof.
  unfold forin_iter, forin_V1. apply TLam. apply TRet.
  apply HTcons; [ | apply HTnil ].
  (* the element : Num ∪ nil — by the ttypetest, both branches subsumed in. *)
  eapply TSub.
  - eapply TTypeTest with (U := BUnion (BAtom ANum) (BAtom ANil)).
    + apply TVar. reflexivity.                                  (* c : Num∪nil *)
    + (* then: c : Num (tag_type TgNum = ANum at db0). if c<3 then c+1 else nil *)
      eapply TIf.
      * apply TPrimCmp; [ reflexivity | apply TVar; reflexivity
        | eapply TSub; [ apply (TLit forin_S _ (LInt 3)) | apply RsSsub; apply SsAtom; apply ALInt ] ].
      * apply TPrimArith; [ reflexivity | apply TVar; reflexivity
        | eapply TSub; [ apply (TLit forin_S _ (LInt 1)) | apply RsSsub; apply SsAtom; apply ALInt ] ].
      * apply (TLit forin_S _ LNil).
    + (* else: nil *) apply (TLit forin_S _ LNil).
  - (* (Num ∪ nil) ∪ nil  ⊑  Num ∪ nil *)
    apply RsSsub. apply SsUnionE; [ apply SsRefl | ].
    apply SsUnionInR. apply SsRefl.
Qed.

(* THE WHOLE LOOP TYPES at [Tunit] (a statement) under [forin_S]. *)
Example forin_loop_typed :
  has_type forin_S [] forin_loop Tunit.
Proof.
  unfold forin_loop. apply tforin_typed.
  - (* guard *)
    apply forin_guard_typed.
    + (* tmassign [v1cell] (iter call) : nil — RHS is BTuple [Num∪nil], target
         cell BRef (Num∪nil), pad identity, rsub refl. *)
      unfold forin_call.
      eapply (TMAssign forin_S (Tunit :: []) [ tloc 1 ] forin_call
                [ forin_V1 ] [ forin_V1 ]).
      * apply HTcons; [ apply TLoc; reflexivity | apply HTnil ].
      * unfold forin_call. eapply TApp.
        -- apply (weakening_cons forin_S [] forin_iter
                    (BArrow forin_V1 (BTuple [forin_V1])) Tunit forin_iter_typed).
        -- eapply TDeref. apply TLoc. reflexivity.
      * simpl. apply Forall2_cons; [ apply rsub_refl | apply Forall2_nil ].
    + (* the first cell deref types (at Num∪nil) *)
      exists forin_V1. eapply TDeref. apply TLoc. reflexivity.
  - (* body *)
    eapply forin_body_typed with (V1 := forin_V1).
    + (* ctrlcell : BRef (Num∪nil) *) apply TLoc. reflexivity.
    + (* !v1cell : Num∪nil *) eapply TDeref. apply TLoc. reflexivity.
    + (* user body [cnt := !cnt + 1] : Tunit, under the narrowed v1 binder *)
      unfold forin_user_body. eapply TAssign with (T := BAtom ANum).
      * apply TLoc. reflexivity.
      * apply TPrimArith; [ reflexivity | | ].
        -- eapply TDeref. apply TLoc. reflexivity.
        -- eapply TSub; [ apply (TLit forin_S _ (LInt 1)) | apply RsSsub; apply SsAtom; apply ALInt ].
Qed.

(* ---------------------------------------------------------------------------
   PAYOFF 2 — THE FIRST LOOP VARIABLE IS NARROWED TO NON-NIL INSIDE THE BODY.

   In the body, the guard has established [v1] truthy, so [tifn (!v1cell) · ·]
   substitutes [v1] at de Bruijn 0 NARROWED to [truthy_type] — the non-nil bound.
   We exhibit a body that USES de Bruijn 0 AS A NON-NIL value (truthy_type) and
   types — but is REJECTED at [BAtom ANil] (v1 is NOT nil inside the body). This is
   the narrowing payoff: past the guard, v1's type excludes nil.
   --------------------------------------------------------------------------- *)

(* the narrowed [v1] (de Bruijn 0) has type [truthy_type] in the body context. *)
Example forin_v1_narrowed_nonnil :
  has_type forin_S (truthy_type :: []) (tvar 0) truthy_type.
Proof. apply TVar. reflexivity. Qed.

(* and the narrowed [v1] is NOT typeable at [nil]: [truthy_type </: ANil] (a truthy
   value — e.g. a number — inhabits truthy_type but never the nil type), so a
   nil-consumer of [v1] in the body is REJECTED. The body's v1 has shed nil. *)
Example forin_v1_not_nil :
  ~ has_type forin_S (truthy_type :: []) (tvar 0) (BAtom ANil).
Proof.
  intro H. apply inv_var in H. destruct H as [U [Hnth Hsub]].
  simpl in Hnth. injection Hnth as <-.
  (* Hsub : truthy_type <: ANil.  But truthy_type denotes every non-nil value;
     a number [VNum (NRint 0)] inhabits truthy_type and NOT ANil. *)
  apply rsub_sound in Hsub.
  (* Hsub : dsub truthy_type ANil. A number inhabits truthy_type (the ANum arm)
     but not ANil, contradicting the supposed inclusion. *)
  pose proof (Hsub (VNum (NRint 0))) as Hbad.
  unfold truthy_type in Hbad. simpl in Hbad.
  apply Hbad. right. left. exact I.
Qed.

(* ---------------------------------------------------------------------------
   PAYOFF 3 (operational) — ONE TRUTHY ITERATION steps, and the loop TERMINATES
   when the iterator returns nil.
   --------------------------------------------------------------------------- *)

(* the guard and body are CLOSED at the fix self-ref binder (only [tloc]s and the
   tifn-bound de Bruijn 0, which is BELOW the fix binder), so the fix-unfold
   substitution [subst 0 (loop)] leaves them unchanged. *)
Lemma forin_guard_closed : forall s,
  subst 0 s (forin_guard [ tloc 1 ] (tloc 1) forin_call) =
  forin_guard [ tloc 1 ] (tloc 1) forin_call.
Proof. reflexivity. Qed.
Lemma forin_body_closed : forall s,
  subst 0 s (forin_body (tloc 2) (tloc 1) forin_user_body) =
  forin_body (tloc 2) (tloc 1) forin_user_body.
Proof. reflexivity. Qed.

(* ONE ITERATION at control [c] with [c < 3] (so the iterator yields [c+1], truthy):
   from store [cnt ; v1 ; c] the loop calls the iterator (→ c+1), binds it into
   v1cell, the guard is TRUE, advances ctrl := c+1, runs the body (cnt := cnt+1),
   leaving control back at the loop with store [cnt+1 ; c+1 ; c+1]. *)
Lemma forin_one_iter : forall cnt v c,
  Nat.ltb c 3 = true ->
  multistep (forin_loop, [ tlit (LInt cnt) ; tlit (LInt v) ; tlit (LInt c) ])
            (forin_loop, [ tlit (LInt (cnt + 1)) ; tlit (LInt (c + 1)) ; tlit (LInt (c + 1)) ]).
Proof.
  intros cnt v c Hlt. unfold forin_loop, tforin.
  eapply MSstep. { apply twhile_unfold. }
  rewrite forin_guard_closed, forin_body_closed.
  (* GUARD: tseq (tmassign [v1cell] (iter (!ctrl))) (tifn (!v1cell) true false) *)
  unfold forin_guard, forin_call, forin_iter, forin_V1.
  (* step the iterator call: read ctrl c, beta, the ttypetest on a number, the
     inner [if c<3] true ⇒ c+1; RHS becomes [tret [c+1]]. *)
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SApp2; [ apply VLam | apply SDeref ]. } simpl.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SBeta. apply VLit. } simpl.
  (* the returned element: ttypetest TgNum (LInt c) ... : c IS a number ⇒ then *)
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SRet with (pre := []); [ apply Forall_nil
                     | apply STtTrue; [ apply VLit | exact I ] ]. } simpl.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SRet with (pre := []); [ apply Forall_nil
                     | apply SIf1; apply SPrimCmp; reflexivity ]. } simpl.
  unfold prim_cmp. rewrite Hlt.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SRet with (pre := []); [ apply Forall_nil | apply SIfTrue ]. } simpl.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SRet with (pre := []); [ apply Forall_nil | apply SPrimArith; reflexivity ]. } simpl.
  (* now RHS is [tret [c+1]] a value multivalue; the multi-write binds v1cell := c+1 *)
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply Forall_cons; [ apply VLit | apply Forall_nil ]. } simpl.
  (* the tmassign yielded nil; discard it, evaluate the truthiness test *)
  eapply MSstep. { apply SIf1. apply tseq_step_value. apply VLit. }
  (* tifn (!v1cell) true false : read v1cell = c+1 (a number, truthy) ⇒ true *)
  eapply MSstep. { apply SIf1. apply SIfn1. apply SDeref. } simpl.
  eapply MSstep. { apply SIf1. apply SIfnTrue.
                   - apply VLit.
                   - split; [ intros [F|F]; discriminate | intros [es F]; discriminate ]. } simpl.
  (* guard true ⇒ run the then-branch [tseq (forin_body) (loop)] *)
  eapply MSstep. { apply SIfTrue. }
  (* BODY (the OUTER tseq sequences [forin_body] then the recursive loop). The body
     [forin_body] is itself [tseq (ctrl := !v1cell) (tifn (!v1cell) user_body nil)]. *)
  unfold forin_body, forin_user_body.
  (* advance ctrl := !v1cell = c+1  (outer tseq_step1 + inner tseq_step1) *)
  eapply MSstep. { apply tseq_step1. apply tseq_step1.
                   apply SAssign2; [ apply VLoc | apply SDeref ]. } simpl.
  eapply MSstep. { apply tseq_step1. apply tseq_step1. apply SAssign. apply VLit. } simpl.
  eapply MSstep. { apply tseq_step1. apply tseq_step_value. apply VLit. }
  (* tifn (!v1cell) user_body nil : v1cell = c+1 truthy ⇒ run user body (subst) *)
  eapply MSstep. { apply tseq_step1. apply SIfn1. apply SDeref. } simpl.
  eapply MSstep. { apply tseq_step1. apply SIfnTrue.
                   - apply VLit.
                   - split; [ intros [F|F]; discriminate | intros [es F]; discriminate ]. } simpl.
  (* user body [cnt := !cnt + 1] : read cnt, add 1, write cnt+1 *)
  eapply MSstep. { apply tseq_step1. apply SAssign2; [ apply VLoc | apply SPrim1; apply SDeref ]. } simpl.
  eapply MSstep. { apply tseq_step1. apply SAssign2; [ apply VLoc | apply SPrimArith; reflexivity ]. } simpl.
  eapply MSstep. { apply tseq_step1. apply SAssign. apply VLit. } simpl.
  (* the body finished (nil); the outer sequence yields the loop again *)
  eapply MSstep. { apply tseq_step_value. apply VLit. }
  apply MSrefl.
Qed.

(* TERMINATION: at control [c] with [c >= 3] the iterator yields nil (falsy); the
   guard is FALSE and the loop ends with [nil]. The store: v1cell is overwritten
   with nil, ctrl is unchanged (advance only happens in the body, which the false
   guard skips), cnt unchanged. *)
Lemma forin_terminates : forall cnt v c,
  Nat.ltb c 3 = false ->
  multistep (forin_loop, [ tlit (LInt cnt) ; tlit (LInt v) ; tlit (LInt c) ])
            (tlit LNil, [ tlit (LInt cnt) ; tlit LNil ; tlit (LInt c) ]).
Proof.
  intros cnt v c Hge. unfold forin_loop, tforin.
  eapply MSstep. { apply twhile_unfold. }
  rewrite forin_guard_closed, forin_body_closed.
  unfold forin_guard, forin_call, forin_iter, forin_V1.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SApp2; [ apply VLam | apply SDeref ]. } simpl.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SBeta. apply VLit. } simpl.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SRet with (pre := []); [ apply Forall_nil
                     | apply STtTrue; [ apply VLit | exact I ] ]. } simpl.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SRet with (pre := []); [ apply Forall_nil
                     | apply SIf1; apply SPrimCmp; reflexivity ]. } simpl.
  unfold prim_cmp. rewrite Hge.
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign2.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply SRet with (pre := []); [ apply Forall_nil | apply SIfFalse ]. } simpl.
  (* RHS is [tret [nil]] a value multivalue; bind v1cell := nil *)
  eapply MSstep. { apply SIf1. apply tseq_step1. apply SMAssign.
                   - apply Forall_cons; [ apply VLoc | apply Forall_nil ].
                   - apply Forall_cons; [ apply VLit | apply Forall_nil ]. } simpl.
  eapply MSstep. { apply SIf1. apply tseq_step_value. apply VLit. }
  (* tifn (!v1cell) true false : v1cell = nil (falsy) ⇒ false *)
  eapply MSstep. { apply SIf1. apply SIfn1. apply SDeref. } simpl.
  eapply MSstep. { apply SIf1. apply SIfnFalse.
                   - apply VLit.
                   - right; reflexivity. } simpl.
  (* guard false ⇒ the loop ends with nil *)
  eapply MSstep. { apply SIfFalse. }
  apply MSrefl.
Qed.

(* THE WHOLE LOOP, END-TO-END: from [cnt=0 ; v1=0 ; ctrl=0] the iterator yields
   1, 2, 3 (control 0→1→2→3, cnt 0→1→2→3), then at control 3 yields nil and the
   loop TERMINATES — accumulating [cnt = 3] (three iterations). A generic-for over
   an explicit finite iterator, run to completion. *)
Example forin_loop_runs :
  multistep (forin_loop, [ tlit (LInt 0) ; tlit (LInt 0) ; tlit (LInt 0) ])
            (tlit LNil, [ tlit (LInt 3) ; tlit LNil ; tlit (LInt 3) ]).
Proof.
  eapply multistep_trans. { apply (forin_one_iter 0 0 0). reflexivity. } simpl.
  eapply multistep_trans. { apply (forin_one_iter 1 1 1). reflexivity. } simpl.
  eapply multistep_trans. { apply (forin_one_iter 2 2 2). reflexivity. } simpl.
  apply (forin_terminates 3 3 3). reflexivity.
Qed.

(* ===========================================================================
   ASSUMPTION AUDIT — closed under the global context.
   =========================================================================== *)
Print Assumptions progress.
(* METATABLE METAMETHOD FAMILY — __concat / __unm / __len (typed + stepped + rejected). *)
Print Assumptions concat_payoff_typed.
Print Assumptions concat_payoff_steps.
Print Assumptions unm_payoff_typed.
Print Assumptions len_payoff_typed.
Print Assumptions unm_payoff_steps.
Print Assumptions len_absent_rejected.
(* METATABLES — the OOP payoff: prototype inheritance, typed + stepped + rejected. *)
Print Assumptions oop_derived_typed.
Print Assumptions oop_inherited_typed.
Print Assumptions oop_inherited_steps.
Print Assumptions oop_own_typed.
Print Assumptions oop_own_steps.
Print Assumptions oop_absent_rejected.
(* METATABLE METAMETHODS — __call / __add / __newindex payoffs (typed + stepped +
   rejected): callable tables, operator overloading, write fallback. *)
Print Assumptions call_payoff_typed.
Print Assumptions call_payoff_steps.
Print Assumptions add_payoff_typed.
Print Assumptions add_payoff_steps.
Print Assumptions sub_absent_rejected.
(* OPERATOR RIGHT-OPERAND FALLBACK — [1 + obj] (typed + stepped + rejected). *)
Print Assumptions add_right_payoff_typed.
Print Assumptions add_right_payoff_steps.
Print Assumptions sub_right_absent_rejected.
Print Assumptions newindex_payoff_typed.
Print Assumptions newindex_payoff_steps.
Print Assumptions newindex_absent_cell_rejected.
Print Assumptions rawget_own_typed.
Print Assumptions rawget_own_steps.
Print Assumptions rawget_bypasses_proto.
Print Assumptions rawset_payoff_typed.
Print Assumptions rawset_payoff_steps.
Print Assumptions rawset_absent_own_rejected.
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
(* MULTI-RETURN — the payoff: a multi-return function, truncation-to-first and
   last-position spread of the SAME call (typed + stepped), and progress on both. *)
Print Assumptions mr_f_typed.
Print Assumptions mr_call_typed.
Print Assumptions mr_truncate_typed.
Print Assumptions mr_truncate_steps.
Print Assumptions mr_spread_typed.
Print Assumptions mr_spread_steps.
Print Assumptions mr_truncate_progress.
Print Assumptions mr_spread_progress.
(* VARARG — the payoff: a variadic function truncating [...] to one value and one
   forwarding [...] (last-position spread), typed + stepped, and progress on both. *)
Print Assumptions va_first_typed.
Print Assumptions va_first_call_typed.
Print Assumptions va_first_call_steps.
Print Assumptions va_fwd_typed.
Print Assumptions va_fwd_call_typed.
Print Assumptions va_fwd_call_steps.
Print Assumptions va_first_progress.
Print Assumptions va_fwd_progress.
(* MULTIPLE-ASSIGNMENT — the payoff: [a,b=f()] (exact arity, both bound), nil-pad
   ([a,b,c=e1,e2]), and drop ([a,b=e1,e2,e3]) — typed + stepped, plus progress. *)
Print Assumptions ma_call_typed.
Print Assumptions ma_call_steps.
Print Assumptions ma_call_progress.
Print Assumptions mp_assign_typed.
Print Assumptions mp_assign_steps.
Print Assumptions md_assign_typed.
Print Assumptions md_assign_steps.
(* NUMERIC FOR-LOOP — encoded over [twhile]: typing of the loop forms + the loop
   variable as a number; a counting-up sum loop (types + steps to 6); a counting-
   down loop (terminates); the loop variable typed soundly as ANum (not AInt). *)
Print Assumptions for_var_is_number.
Print Assumptions tfor_up_typed.
Print Assumptions tfor_down_typed.
Print Assumptions forsum_loop_typed.
Print Assumptions forsum_one_iter.
Print Assumptions forsum_terminates.
Print Assumptions forsum_loop_runs.
Print Assumptions fordown_loop_typed.
Print Assumptions fordown_one_iter.
Print Assumptions fordown_terminates.
Print Assumptions fordown_loop_runs.
Print Assumptions for_var_typed_number.
Print Assumptions for_var_not_int.
(* GENERIC FOR-IN LOOP — encoded over [twhile] + [tmassign] + [tapp] + [tifn]:
   typing of the loop forms (guard/body/loop); a concrete generic-for over an
   explicit finite iterator (types + steps to completion accumulating cnt=3);
   the first loop variable narrowed to non-nil inside the body (typed, and
   rejected at nil); one truthy iteration steps; the loop terminates on nil. *)
Print Assumptions tforin_typed.
Print Assumptions forin_guard_typed.
Print Assumptions forin_body_typed.
Print Assumptions forin_iter_typed.
Print Assumptions forin_loop_typed.
Print Assumptions forin_v1_narrowed_nonnil.
Print Assumptions forin_v1_not_nil.
Print Assumptions forin_one_iter.
Print Assumptions forin_terminates.
Print Assumptions forin_loop_runs.
