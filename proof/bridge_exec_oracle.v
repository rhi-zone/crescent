(* bridge_exec_oracle.v — SCRATCH oracle for the OPERATIONAL-SEMANTICS reality
   bridge (lib/sem/bridge/exec.lua, exec_test.lua). NOT part of the build.

   For each battery term we `Compute (synth [] term)` to obtain the checker's
   INFERRED type, and (where short) `Compute` the multistep-normal-form value or
   reduction. The Lua harness asserts the same inferred types and then runs the
   translated term on REAL LuaJIT, checking the result inhabits the inferred type.

   Reproduce:
     nix develop -c coqc proof/subtype.v
     nix develop -c coqc proof/ssub.v
     nix develop -c coqc proof/typing.v
     nix develop -c coqc proof/check.v
     nix develop -c coqc proof/bridge_exec_oracle.v
*)

Require Import subtype.
Require Import typing.
Require Import check.
From Stdlib Require Import List.
From Stdlib Require Import String.
Import ListNotations.

(* ── the battery terms (closed; synth under empty Sig/empty G) ─────────────── *)

(* 1. arithmetic  3 + 4 *)
Definition b_add : tm := tprim PAdd (tlit (LInt)) (tlit (LInt)).
Compute (synth [] [] b_add).               (* expect Some (BAtom ANum) *)

(* 2. subtraction 10 - 4 *)
Definition b_sub : tm := tprim PSub (tlit (LInt)) (tlit (LInt)).
Compute (synth [] [] b_sub).               (* Some (BAtom ANum) *)

(* 3. multiplication 6 * 7 *)
Definition b_mul : tm := tprim PMul (tlit (LInt)) (tlit (LInt)).
Compute (synth [] [] b_mul).               (* Some (BAtom ANum) *)

(* 4. division — synth type is ANum. (The former PDiv faithfulness gap, proof
   Nat.div vs real float division, is moot: numbers have no magnitude; arithmetic
   is abstract. The inferred TYPE is all the model commits to.) *)
Definition b_div : tm := tprim PDiv (tlit (LInt)) (tlit (LInt)).
Compute (synth [] [] b_div).               (* Some (BAtom ANum) *)

(* 5. comparison 3 < 4 *)
Definition b_lt : tm := tprim PLt (tlit (LInt)) (tlit (LInt)).
Compute (synth [] [] b_lt).                (* Some (BAtom ABool) *)

(* 6. comparison 5 <= 5 *)
Definition b_le : tm := tprim PLe (tlit (LInt)) (tlit (LInt)).
Compute (synth [] [] b_le).                (* Some (BAtom ABool) *)

(* 7. equality 4 == 4 *)
Definition b_eq : tm := tprim PEq (tlit (LInt)) (tlit (LInt)).
Compute (synth [] [] b_eq).                (* Some (BAtom ABool) *)

(* 8. conditional: if (3 < 4) then 1 else 0  — declared type BUnion ANum ANum *)
Definition b_if : tm :=
  tif (tprim PLt (tlit (LInt)) (tlit (LInt)))
      (tlit (LInt)) (tlit (LInt)).
Compute (synth [] [] b_if).                (* Some (BUnion AInt AInt) *)

(* 9. let:  let x = 6 + 1 in x * 2 *)
Definition b_let : tm :=
  tlet (tprim PAdd (tlit (LInt)) (tlit (LInt)))
       (tprim PMul (tvar 0) (tlit (LInt))).
Compute (synth [] [] b_let).               (* Some (BAtom ANum) *)

(* 10. record + projection:  { x = 3+4, y = 5 } . x *)
Definition b_rec : tm :=
  trec [("x"%string, tprim PAdd (tlit (LInt)) (tlit (LInt)));
        ("y"%string, tlit (LInt))].
Compute (synth [] [] b_rec).               (* Some (BRec [(x,ANum);(y,AInt)]) *)
Definition b_proj : tm := tproj b_rec "x".
Compute (synth [] [] b_proj).              (* Some (BAtom ANum) *)
Definition b_proj_y : tm := tproj b_rec "y".
Compute (synth [] [] b_proj_y).            (* Some (BAtom AInt) *)

(* 11. ref alloc + deref:  !(ref (2+3)) *)
Definition b_alloc : tm := talloc (tprim PAdd (tlit (LInt)) (tlit (LInt))).
Compute (synth [] [] b_alloc).             (* Some (BRef ANum) *)
Definition b_deref : tm := tderef b_alloc.
Compute (synth [] [] b_deref).             (* Some (BAtom ANum) *)

(* 12. ref mutation reading the new value:
       let r = ref 0 in (r := 9 ; !r)        ([r] = de Bruijn 0)
   assign yields unit (nil); tseq discards it; the final !r reads the cell.
   NOTE: synth checks 9:AInt rsub the cell content. The cell synthesizes as
   BRef AInt (alloc of LInt : AInt), and 9 : AInt, so it types; !r : AInt. *)
Definition b_mut : tm :=
  tlet (talloc (tlit (LInt)))
    (tseq (tassign (tvar 0) (tlit (LInt)))
          (tderef (tvar 0))).
Compute (synth [] [] b_mut).               (* Some (BAtom AInt) *)

(* 13. function application:  (\x:ANum. x + 1) 5 *)
Definition b_app : tm :=
  tapp (tlam (BAtom ANum) (tprim PAdd (tvar 0) (tlit (LInt))))
       (tlit (LInt)).
Compute (synth [] [] b_app).               (* Some (BAtom ANum) *)

(* 14. counting while-loop.  NOTE: [sumloop_prog n] is declaratively typed at
   ANum ([sumloop_prog_typed]) but the ALGORITHMIC [synth] REJECTS it (None) —
   the [TSub]-widening of the AInt initialiser to a Num cell that the declarative
   proof uses is not recovered by [synth] (it allocates BRef AInt from LInt and
   then cannot store the ANum arithmetic result back into the invariant cell).
   This is a synth-vs-declarative gap surfaced by the bridge. *)
Compute (synth [] [] (sumloop_prog 5)).    (* None  (algorithmic synth rejects) *)

(* 14'. a SYNTH-ACCEPTABLE counting while-loop. Allocate the cell with an
   ARITHMETIC result (0+0 : ANum) so the cell synthesizes BRef ANum; then the
   ANum body stores back fine and the loop synths at ANum:
       local i = ref (0 + 0);  while (!i < 3) do i := !i + 1 end;  !i
   ([i] = de Bruijn 1 under the fix self-ref; de Bruijn 0 for the final read). *)
Definition b_while_cond : tm := tprim PLt (tderef (tvar 1)) (tlit (LInt)).
Definition b_while_body : tm :=
  tassign (tvar 1) (tprim PAdd (tderef (tvar 1)) (tlit (LInt))).
Definition b_while : tm :=
  tlet (talloc (tprim PAdd (tlit (LInt)) (tlit (LInt))))
    (tseq (twhile b_while_cond b_while_body) (tderef (tvar 0))).
Compute (synth [] [] b_while).             (* Some (BAtom ANum) — loop runs to 3 *)

(* 15. nil literal *)
Compute (synth [] [] (tlit LNil)).         (* Some (BAtom ANil) *)

(* 16. boolean literal *)
Compute (synth [] [] (tlit (LBool true))). (* Some (BAtom ABool) *)
