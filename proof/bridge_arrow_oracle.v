(* Scratch oracle: ARROW membership verdicts from the PROVEN model.
   memb t v := if denote_dec t v then true else false  (per docs recipe).
   Reproduce: nix develop -c coqc subtype.v && nix develop -c coqc bridge_arrow_oracle.v
   Not part of the build; safe to delete.

   ARROW membership (proof/subtype.v `denote`/`denote_dec`, BArrow case):
     [v] inhabits [BArrow A B] iff [v = VFun g] and EVERY [(i,o)] in [g] satisfies
     [denote A i -> denote B o]. Non-function values inhabit NO arrow type.

   The function value is a FINITE I/O graph (`list (V*V)`), so membership is
   decidable on the known graph. We pick member + non-member cases over scalar
   graphs (number/string/bool/nil inputs and outputs). The headline non-member:
   a graph mapping an Int input to a Str output is NOT in Int -> Int. *)
Require Import subtype.
From Stdlib Require Import List.
Import ListNotations.

Definition memb (t : BTy) (v : V) : bool :=
  if denote_dec t v then true else false.

(* ---- Arrow types over scalar atoms ---------------------------------------- *)
Definition Int_to_Int := BArrow (BAtom AInt) (BAtom AInt).
Definition Int_to_Str := BArrow (BAtom AInt) (BAtom AStr).
Definition Str_to_Bool := BArrow (BAtom AStr) (BAtom ABool).
Definition Num_to_Num := BArrow (BAtom ANum) (BAtom ANum).

(* ---- member cases --------------------------------------------------------- *)
(* empty graph: vacuously in every arrow type. *)
Compute (memb Int_to_Int (VFun [])).                                  (* true *)
(* int->int graph entirely inside Int->Int. *)
Compute (memb Int_to_Int (VFun [(VInt 1, VInt 2); (VInt 3, VInt 4)])). (* true *)
(* the non-int input (VStr) makes the antecedent [denote AInt (VStr _)] FALSE,
   so the implication is vacuously satisfied — still in Int->Int. *)
Compute (memb Int_to_Int (VFun [(VInt 1, VInt 2); (VStr, VStr)])). (* true *)
(* str->bool graph in Str->Bool. *)
Compute (memb Str_to_Bool (VFun [(VStr, VBool true)])).             (* true *)
(* int input, int output is inside Num->Num (AInt <: ANum). *)
Compute (memb Num_to_Num (VFun [(VInt 5, VInt 6)])).                  (* true *)

(* ---- NON-member cases ----------------------------------------------------- *)
(* the headline: int input -> str output is NOT in Int->Int (consequent fails on
   an input that satisfies the antecedent). *)
Compute (memb Int_to_Int (VFun [(VInt 1, VStr)])).                  (* false *)
(* int -> float (non-integer) output is NOT in Int->Int (float not in AInt). *)
Compute (memb Int_to_Int (VFun [(VInt 1, VFloat 2)])).               (* false *)
(* str input -> int output is NOT in Str->Bool. *)
Compute (memb Str_to_Bool (VFun [(VStr, VInt 9)])).                 (* false *)
(* a non-function value inhabits NO arrow type. *)
Compute (memb Int_to_Int (VInt 3)).                                  (* false *)
Compute (memb Int_to_Int (VStr)).                                  (* false *)
