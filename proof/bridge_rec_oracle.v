(* Scratch oracle: RECORD/TABLE membership verdicts from the PROVEN model.
   memb t v := if denote_dec t v then true else false  (per docs recipe).
   Reproduce: nix develop -c coqc subtype.v && nix develop -c coqc bridge_rec_oracle.v
   Not part of the build; safe to delete.

   RECORD membership (proof/subtype.v `denote`/`denote_dec`, BRec case, OPEN/WIDTH):
     [VTable ents] inhabits [BRec fields] iff for EVERY listed [(k,T)] there is an
     entry at key [k] in [ents] whose value satisfies [denote T]. EXTRA keys in
     [ents] are ALLOWED (open / width). Non-table values inhabit NO record type.

   This increment's bridge scope: STRING keys + SCALAR field values (number /
   string / bool / nil). We pick member + non-member cases:
     - exact fields (member);
     - EXTRA fields present (still member — confirms OPEN/width);
     - field ORDER irrelevant (member);
     - missing field (non-member);
     - wrong field type (non-member);
     - a scalar value (not a table) is not a record (non-member). *)
Require Import subtype.
From Stdlib Require Import List.
From Stdlib Require Import String.
Import ListNotations.
Open Scope string_scope.

Definition memb (t : BTy) (v : V) : bool :=
  if denote_dec t v then true else false.

(* ---- record types over scalar field atoms --------------------------------- *)
(* { x : Int }                                            *)
Definition Rx_Int  : BTy := BRec [("x", BAtom AInt)].
(* { x : Int, y : Str }                                   *)
Definition Rxy     : BTy := BRec [("x", BAtom AInt); ("y", BAtom AStr)].
(* the empty record (table top-type): every table is a member *)
Definition R_empty : BTy := BRec [].

(* ---- sample table values (string-keyed scalar assoc lists) ----------------- *)
Definition t_x3      : V := VTable [("x", VInt 3)].
Definition t_x3_y_s  : V := VTable [("x", VInt 3); ("y", VStr)].
Definition t_y_s_x3  : V := VTable [("y", VStr); ("x", VInt 3)].   (* reordered *)
Definition t_x3_extra: V := VTable [("x", VInt 3); ("z", VBool true)]. (* extra key z *)
Definition t_only_y  : V := VTable [("y", VStr)].                    (* missing x *)
Definition t_x_str   : V := VTable [("x", VStr)].                    (* x wrong type *)

(* ---- member cases --------------------------------------------------------- *)
(* every table is in the empty record. *)
Compute (memb R_empty t_x3).                  (* true *)
(* exact single field. *)
Compute (memb Rx_Int t_x3).                   (* true *)
(* exact two fields. *)
Compute (memb Rxy t_x3_y_s).                  (* true *)
(* EXTRA field present (z) — still a member: OPEN / width. *)
Compute (memb Rx_Int t_x3_extra).             (* true *)
(* field ORDER irrelevant — the table lists y before x. *)
Compute (memb Rxy t_y_s_x3).                  (* true *)

(* ---- NON-member cases ----------------------------------------------------- *)
(* missing field x. *)
Compute (memb Rx_Int t_only_y).               (* false *)
(* wrong field type: x is a string, not an int. *)
Compute (memb Rx_Int t_x_str).                (* false *)
(* a scalar value is not a record (table). *)
Compute (memb Rx_Int (VInt 3)).               (* false *)
Compute (memb Rx_Int (VStr)).               (* false *)
