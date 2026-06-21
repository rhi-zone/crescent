(* Scratch oracle: number-atom membership verdicts from the PROVEN model.
   memb t v := if denote_dec t v then true else false  (per docs recipe).
   Reproduce: nix develop -c coqc subtype.v && nix develop -c coqc bridge_num_oracle.v
   Not part of the build; safe to delete. *)
Require Import subtype.

Definition memb (t : BTy) (v : V) : bool :=
  if denote_dec t v then true else false.

(* ANum over int / float / non-number heads *)
Compute (memb (BAtom ANum) (VInt 3)).    (* expect true  *)
Compute (memb (BAtom ANum) (VFloat 3)).  (* expect true  *)
Compute (memb (BAtom ANum) (VInt 0)).    (* expect true  *)
Compute (memb (BAtom ANum) (VStr 0)).    (* expect false *)
Compute (memb (BAtom ANum) (VBool true)). (* expect false *)
Compute (memb (BAtom ANum) VNil).        (* expect false *)

(* AInt — only VInt inhabits it; VFloat does NOT (the central question) *)
Compute (memb (BAtom AInt) (VInt 3)).    (* expect true  *)
Compute (memb (BAtom AInt) (VInt 0)).    (* expect true  *)
Compute (memb (BAtom AInt) (VFloat 3)).  (* expect false — VFloat 3 is NOT AInt in the model *)
Compute (memb (BAtom AInt) (VFloat 0)).  (* expect false *)
Compute (memb (BAtom AInt) (VStr 0)).    (* expect false *)
Compute (memb (BAtom AInt) (VBool false)). (* expect false *)
