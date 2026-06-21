(* Scratch oracle: number-atom membership verdicts from the PROVEN model.
   memb t v := if denote_dec t v then true else false  (per docs recipe).
   Reproduce: nix develop -c coqc subtype.v && nix develop -c coqc bridge_num_oracle.v
   Not part of the build; safe to delete.

   LuaJIT 5.1 model (corrected): ONE number value [VNum (NumRep)]. [VInt n] is
   [VNum (NRint n)] — an integer-valued double; [VFloat n] is [VNum (NRfrac n)] —
   a genuinely NON-integer double. [ANum]/[AFloat] accept ALL numbers (float ≡
   number on 5.1); [AInt] accepts only the [NRint] (integer-valued) ones. So
   [AInt <: AFloat] and [AInt <: ANum], and there is NO disjoint int/float value:
   [VFloat 3] is a non-integer double, NOT the same as [VInt 3]. *)
Require Import subtype.

Definition memb (t : BTy) (v : V) : bool :=
  if denote_dec t v then true else false.

(* ANum over int / float / non-number heads — all numbers are in ANum *)
Compute (memb (BAtom ANum) (VInt 3)).    (* expect true  *)
Compute (memb (BAtom ANum) (VFloat 3)).  (* expect true  *)
Compute (memb (BAtom ANum) (VInt 0)).    (* expect true  *)
Compute (memb (BAtom ANum) (VStr 0)).    (* expect false *)
Compute (memb (BAtom ANum) (VBool true)). (* expect false *)
Compute (memb (BAtom ANum) VNil).        (* expect false *)

(* AFloat = the number/double type on 5.1 — accepts ALL numbers, exactly ANum *)
Compute (memb (BAtom AFloat) (VInt 3)).    (* expect true  — int IS a float on 5.1 *)
Compute (memb (BAtom AFloat) (VFloat 3)).  (* expect true  *)
Compute (memb (BAtom AFloat) (VInt 0)).    (* expect true  *)
Compute (memb (BAtom AFloat) (VStr 0)).    (* expect false *)

(* AInt — only integer-valued ([NRint], i.e. [VInt _]) numbers; [VFloat _]
   ([NRfrac _], a genuinely non-integer double) does NOT inhabit it. *)
Compute (memb (BAtom AInt) (VInt 3)).    (* expect true  *)
Compute (memb (BAtom AInt) (VInt 0)).    (* expect true  *)
Compute (memb (BAtom AInt) (VFloat 3)).  (* expect false — VFloat 3 is a NON-integer double *)
Compute (memb (BAtom AInt) (VFloat 0)).  (* expect false *)
Compute (memb (BAtom AInt) (VStr 0)).    (* expect false *)
Compute (memb (BAtom AInt) (VBool false)). (* expect false *)
