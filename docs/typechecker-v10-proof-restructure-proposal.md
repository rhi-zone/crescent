# v10 tier-1 proof restructuring — proposal

Status: **PROPOSAL — awaiting owner ratification.** Nothing in this document
has been applied. No `.v` file has been modified to produce it. Every
statement below is a proposed restructuring for the owner to accept, reject,
or select among named alternatives — not a settled design.

Scope: the three structural targets identified as owner-confirmed in
`docs/typechecker-v10-prefix-inventory.md` (commit `0002a15b`) — (1)
arithmetic ⊗ metatables entanglement in `tprim`'s step/typing rules, (2)
tables ⊗ refs entanglement in `TNewIdx`/`TRawSet`, (3) hygiene extraction of
the interleaved `ssub`/`rsub` development out of `proof/typing.v`. Per
`docs/decisions/typechecker-v10-core-design.md`, the refinement-tower /
prefix layer set is explicitly UNDECIDED; nothing here presumes a layer set.
This proposal is restricted to what the inventory scoped it to: restructured
rule statements and their proof-impact, laid out so the owner can ratify
before any layer decision is made.

All line numbers cite `proof/typing.v` and `proof/ssub.v` as of commit
`baf61f04` (current HEAD at the time this proposal was written).

---

## 1. Arithmetic ⊗ metatables

### 1.1 Current statement

Two inductive families carry the entanglement, and one inversion lemma
fuses them into a single fact:

**`step`** (`typing.v:1573` onward) has, for `tprim`, five constructors that
never mention `tmeta` —

```
| SPrim1 : forall op a a' b st st',
    step (a, st) (a', st') -> step (tprim op a b, st) (tprim op a' b, st')
| SPrim2 : forall op v b b' st st',
    value v -> step (b, st) (b', st') -> step (tprim op v b, st) (tprim op v b', st')
| SPrimArith : forall op st,
    arith_op op = true ->
    step (tprim op (tlit LInt) (tlit LInt), st) (tlit LInt, st)
| SPrimCmpTrue : forall op st,
    cmp_op op = true ->
    step (tprim op (tlit LInt) (tlit LInt), st) (tlit (LBool true), st)
| SPrimCmpFalse : forall op st,
    cmp_op op = true ->
    step (tprim op (tlit LInt) (tlit LInt), st) (tlit (LBool false), st)
```

— and two that require it (`typing.v:1753-1773`):

```
| SPrimMetaL : forall op own proto b st,
    value (tmeta own proto) ->
    step (tprim op (tmeta own proto) b, st)
         (tapp (tapp (tproj (tmeta own proto) (mm_binop op)) (tmeta own proto)) b, st)
| SPrimMetaR : forall op l own proto st,
    value (tmeta own proto) ->
    step (tprim op (tlit l) (tmeta own proto), st)
         (tapp (tapp (tproj (tmeta own proto) (mm_binop op)) (tlit l)) (tmeta own proto), st)
```

All seven are constructors of the *same* `Inductive step`, over the *same*
`tm` (which already has `tmeta` as a constructor whether or not a given
`tprim` redex uses it).

**`has_type`** (`typing.v:935-944` vs `typing.v:1125-1162`) mirrors this
split exactly: `TPrimArith`/`TPrimCmp` need only `BAtom ANum`; `TPrimMetaL`/
`TPrimMetaR` need a `tmeta` operand typed `BRec M` carrying the metamethod
key. Again, one `Inductive has_type`.

**The fusing point** is `inv_prim` (`typing.v:2042-2094`), the single
inversion lemma every preservation case for `tprim` (`SPrimArith` at
`5227-5240`, `SPrimCmpTrue`/`False` at `5241-5261`, `SPrimMetaL` at
`5668-5688`, `SPrimMetaR` at `5689-5713`) destructs:

```
Lemma inv_prim : forall S G op a b T,
  has_type S G (tprim op a b) T ->
  (has_type S G a (BAtom ANum) /\ has_type S G b (BAtom ANum) /\
   ((arith_op op = true /\ rsub (BAtom ANum) T) \/
    (cmp_op op = true /\ rsub (BAtom ABool) T)))
  \/
  (exists ofs proto M Self Other R,
     a = tmeta ofs proto /\ has_type S G (tmeta ofs proto) (BRec M) /\
     In (mm_binop op, BArrow Self (BArrow Other R)) M /\
     rsub (BRec M) Self /\ has_type S G b Other /\ rsub R T)
  \/
  (exists al ofs proto M Other R,
     b = tmeta ofs proto /\ has_type S G a (BAtom al) /\
     has_type S G (tmeta ofs proto) (BRec M) /\
     In (mm_binop op, BArrow (BAtom al) (BArrow Other R)) M /\
     rsub (BRec M) Other /\ rsub R T).
```

This is exactly the finding the inventory names as the sharpest fracture
line: `tprim`'s step relation and typing rule already have a genuinely
content-free arithmetic core (no rule in it pattern-matches on `tmeta`), but
that core is not *citable* on its own — every consumer of "what can a
`tprim` redex/typing derivation be" gets the metamethod disjuncts whether or
not it cares about them, because `step`/`has_type`/`inv_prim` are each one
inductive/lemma spanning both.

### 1.2 Proposed restructuring — two materially different designs

**Option A — relation-level split, same `tm`, same `Inductive step`/`has_type`
(citation separability only).**

A first instinct is to introduce a derived lemma that reproduces `inv_prim`
but grouped into an "arithmetic-only" name. That instinct does not survive
contact with what `inv_prim` actually says: its conclusion is a fact about
`has_type S G (tprim op a b) T` with *no* premise narrowing `a`/`b` in
advance, and that fact genuinely has three cases under the current
grammar (`a`/`b` can each be a literal or a `tmeta` value) — a lemma cannot
turn a true three-way disjunction into a true one-way fact without adding a
premise that rules the other two cases out first. What Option A can
honestly do is exactly that: narrow the premise, not the conclusion —

```
Lemma inv_prim_numeric_case : forall S G op a b T,
  has_type S G a (BAtom ANum) -> has_type S G b (BAtom ANum) ->
  has_type S G (tprim op a b) T ->
  (arith_op op = true /\ rsub (BAtom ANum) T) \/
  (cmp_op op = true /\ rsub (BAtom ABool) T).
```

i.e. narrow the *premise* to "both operands already known numeric" and only
then extract the arithmetic-only conclusion — pushing the "is this a
`tmeta`" question to the caller, who must already have canonical-forms
information ruling `tmeta` out. This is a real, low-cost decoupling
(re-derivable from the current `inv_prim` in a few lines: destruct, discard
the two `tmeta` disjuncts by contradiction using the numeric premises +
`rsub_rec_not_atom`, keep the first). It gives every existing preservation
case for `SPrimArith`/`SPrimCmpTrue`/`SPrimCmpFalse` a citable "just
arithmetic" fact.

The `step` relation itself is harder to decouple this way and honestly
should be flagged as a separate sub-question: `step`'s `SPrim1`/`SPrim2`
congruence rules already say nothing about `tmeta` (the finding already
covers this — the inventory's own table has them as "structural"). What is
NOT separable under Option A is the *type* `tm` → `step` mapping as a
whole: `step`'s generated induction principle (`induction Hstep`, used
throughout `preservation`, `5115-6005`, and `progress`, `6079-6489`) is one
match over all ~70 constructors regardless of any lemma-level regrouping,
because `Inductive step` is one type. A lemma cannot split an `Inductive`'s
induction principle after the fact.

Cost: `inv_prim_numeric_case` and its `has_types`/preservation-consumer
call-sites — low, a handful of new lemmas plus edits to the four `tprim`
preservation cases to cite the narrower fact where it suffices (they don't
strictly need to; this is additive, not a required migration). Zero risk to
`step`'s existing 70-constructor shape. Does not touch `SPrimMetaL`/
`SPrimMetaR`/`TPrimMetaL`/`TPrimMetaR` at all.

**Option B — grammar-level layer cut, new file, `typing.v` untouched.**

Define a strictly smaller term grammar `tm0` = the current `tm` grammar
minus `tmeta`/`tnewidx`/`tunop`/`trawget`/`trawset` (i.e. structural core +
literals/lambda/records/refs/multi-return/`tprim`, everything except the
metatable constructors), with its own `step0`/`has_type0` restating
`SBeta`/…/`SPrim1`/`SPrim2`/`SPrimArith`/`SPrimCmpTrue`/`SPrimCmpFalse`
verbatim over `tm0`, and prove `progress0`/`preservation0` **standalone**,
in a new file. Because `tm0` has no `tmeta` constructor at all, no case in
that standalone proof can ever need to consider `SPrimMetaL`/`SPrimMetaR` —
not as a vacuous case to discharge, but because the rule literally is not in
`step0`'s constructor list. This is the actual prefix cut: "just arithmetic,
no tables" becomes a real, freestanding, smaller development, citable
without any metatable content in scope.

The relationship of this new development to `typing.v` is then an
*embedding*: `iota : tm0 -> tm` (structural, `tmeta`/etc. never appear in
the image), with a conservativity lemma `step0 t t' -> step (iota t) (iota
t')` (the mirrored `SPrimArith` etc. constructors are literally the same
shape in both grammars, so this is a straightforward structural induction).
`typing.v` itself is **not modified** under this option — the metatable
extension is "separable" in the sense that it is simply not present in the
smaller development, and the combined language (current `typing.v`) is
characterized, after the fact, as `tm0`'s image plus the metatable
constructors plus the metatable-dispatch step/typing rules — not by editing
`typing.v` to produce that characterization.

Cost: a full new progress+preservation pair, but over a materially smaller
term set (no metatable cases, no `tmeta` canonical-forms cases) — likely
substantially less total proof volume than the metatable-inclusive core,
though it is new development, not a refactor, and the file boundary /
naming (`proof/prefix_arith.v`? something else?) is undecided. Zero risk to
`typing.v`'s existing `Qed`s (nothing there changes). Does not, by itself,
remove `SPrimMetaL`/`SPrimMetaR`/`TPrimMetaL`/`TPrimMetaR` from `typing.v` —
they remain exactly as entangled as today in the combined file; Option B
answers "can arithmetic be stated free of metatable knowledge" with a new,
separate yes, not with a change to the existing entangled statement.

### 1.3 The fork this proposal will not resolve

Options A and B are not competing implementations of the same goal — they
answer different readings of "restructure the entanglement":

- Option A: make the *existing* `typing.v` more citable in pieces, without
  changing what `tm`/`step`/`has_type` are. Low cost, low risk, does not
  produce a true prefix.
- Option B: produce a true, freestanding "arithmetic without tables"
  prefix, at the cost of new proof volume, and explicitly by *not* touching
  `typing.v` (satisfies the letter of "core arithmetic steps stated without
  metatable knowledge" via a new file, not via restructuring the cited
  file).

**Open question for the owner:** which reading is intended — regroup
`typing.v` in place (Option A, and if so, is the `step`-relation's
induction-principle cost acceptable), or stand up a new, smaller prefix
development alongside the untouched `typing.v` (Option B)? Nothing here
resolves this; it is a genuine branch point the inventory's finding does not
itself decide, and it interacts with the undecided refinement-tower layer
set (Option B produces exactly the kind of artifact a layer tower would
consume; Option A does not).

---

## 2. Tables ⊗ refs

### 2.1 Current statement

`TNewIdx` (`typing.v:1174-1182`) and `TRawSet` (`typing.v:1220-1227`) both
require the written field's *static* type to be exactly `BRef T`:

```
| TNewIdx : forall S G ofs proto Town Pf k v T,
    has_fields S G ofs Town -> NoDup (map fst Town) ->
    key_in k Town = false ->
    has_type S G proto (BRec Pf) -> NoDup (map fst Pf) ->
    In (k, BRef T) Pf ->                    (* <- the coupling *)
    has_type S G v T ->
    has_type S G (tnewidx ofs proto k v) (BAtom ANil)

| TRawSet : forall S G ofs proto Town Pf k v T,
    has_fields S G ofs Town -> NoDup (map fst Town) ->
    In (k, BRef T) Town ->                  (* <- the coupling *)
    has_type S G proto (BRec Pf) -> NoDup (map fst Pf) ->
    has_type S G v T ->
    has_type S G (trawset ofs proto k v) (BAtom ANil)
```

By contrast, **raw read** (`TRawGet`, `typing.v:1207-1213`) does *not*
require `BRef`:

```
| TRawGet : forall S G ofs proto Town Pf k T,
    has_fields S G ofs Town -> NoDup (map fst Town) ->
    In (k, T) Town ->                       (* plain T, no BRef *)
    has_type S G proto (BRec Pf) -> NoDup (map fst Pf) ->
    has_type S G (trawget ofs proto k) T
```

So the precise shape of the entanglement (worth stating exactly, since the
inventory's framing — "mutable fields are typed as `BRef T` by
construction" — could be read as stronger than it is): a table field's type
is only forced to be `BRef T` at the moment something *writes* to it
(`TNewIdx`/`TRawSet`). There is no independent "this field is mutable"
marker; mutability is entirely *encoded* by the field's static type being
literally a `BRef`. This is not incidental — per `TODO.md:1970-1984`
(increment M4, "records-of-refs ENCODING", `[x]` DONE), it is a *deliberate*
prior decision: a mutable table `{x:T}` is defined to desugar to `BRec
[("x", BRef T)]` specifically **so that** `progress`/`preservation` need no
new cases for table mutation — they are inherited unmodified from the
existing `talloc`/`tderef`/`tassign` metatheory. The entanglement the
inventory flags is the direct, intended consequence of that free-inheritance
design, not an oversight.

### 2.2 Proposed restructuring — three options, increasing cost and increasing fidelity

**Option A — cosmetic decoupling only (zero proof impact).**

Introduce a named predicate that unfolds to exactly the current premise:

```
Definition mutable_field (k : string) (T : BTy) (Pf : list (string * BTy)) : Prop :=
  In (k, BRef T) Pf.
```

and restate `TNewIdx`/`TRawSet` citing `mutable_field k T Pf`/`mutable_field
k T Town` instead of `In (k, BRef T) Pf`/`Town`. This changes nothing
provable — `unfold mutable_field` recovers the current premise exactly — it
only gives a name a reader can cite ("this rule requires the field be
mutable") without spelling out `BRef` at every call site. Proof impact:
none beyond a global search-replace and one `Definition`; every existing
`Qed` goes through unchanged (`mutable_field` unfolds transparently). This
does **not** decouple mutability from `BRef` at the semantic level — it is
the floor option, offered because it is free, not because it answers the
inventory's finding.

**Option B — new type-level mutability marker, same operational encoding.**

Add a distinct type former, e.g. `BMut T` (name a placeholder — not
ratified), disjoint from `BRef T`, and restate the writable-field rules
over it:

```
| TNewIdx : forall S G ofs proto Town Pf k v T,
    ... In (k, BMut T) Pf -> has_type S G v T -> ...
| TRawSet : forall S G ofs proto Town Pf k v T,
    ... In (k, BMut T) Town -> has_type S G v T -> ...
```

This genuinely separates "table field is mutable" (`BMut T`, a type-level
fact) from "the runtime value at this position is a store location"
(currently exactly what `BRef T` means, via `TLoc`/`SAlloc`/`SDeref`/
`SAssign` and their canonical-forms lemmas). But the *operational* encoding
(records-of-refs: `{x:T}` compiles to `trec [("x", talloc e)]`, per M4) is
unchanged — the runtime value at a `BMut T` field is still, in fact, a
`tloc`. That correspondence is currently *given for free* by `BRef T`'s
existing metatheory (canonical forms: a `BRef T`-typed closed value is a
`tloc`, proved once, reused everywhere `BRef` appears). Decoupling the type
from `BRef` breaks that free ride: **preservation would need a new
invariant** — something of the shape "a value at a `BMut T`-typed field
position is, under `store_well_typed`, always a `VLoc`/`tloc`" — re-derived
for `BMut` specifically, because canonical forms no longer gets it from
`BRef`'s existing proof. This is exactly the kind of consequence the task
asks to be surfaced explicitly before ratification: Option B is not a
free relabeling, it is a new proof obligation shaped like — but separate
from — `BRef`'s existing canonical-forms lemma (`typing.v` canonical-forms
section, `3432` onward, e.g. the `BRef`-specific cases of `canon_arrow`/
`canon_rec` and the dedicated location canonical-forms lemma near
`inv_loc`).

**Option C — native table mutation, no ref encoding at all (breaks M4's
free-inheritance choice).**

Give tables their own first-class, in-place field-mutation semantics: a
table becomes a store-resident aggregate value in its own right (not "a
record of individually `talloc`'d cells"), with a dedicated step rule
updating one field of a stored table object directly (something like
`store_update_field n k v st` against a store now capable of holding
aggregate table values, not just scalars-behind-locations), and a
corresponding typing rule with its own store-typing premise. This is the
most Lua-faithful model (real Lua tables are one mutable object with
in-place field slots, not a record of independently-boxed reference cells)
and is the one that would let "tables" exist as an axis genuinely
independent of "refs" (a language could have first-class tables with no
general reference type at all). Cost: **high** — this requires a new value
form, a new step rule, and a full new set of progress/preservation cases
for table-field mutation; none of it is inherited, because it deliberately
gives up the M4 design's whole reason for being ("proofs are inherited
UNMODIFIED"). This is the most consequential of the three options and is
flagged as such rather than assessed further here — it amounts to replacing
a settled, `[x]`-marked, `Qed`-complete increment (M4) with an alternative
design for the same feature, which is a decision of a different order than
"restructure an existing rule statement."

### 2.3 Open question for the owner

Option A is essentially free and changes nothing about what "tables ⊗ refs"
means; Options B and C are real decouplings but at costs that scale with how
much of M4's free-inheritance is given up (B keeps the operational encoding
and pays for a new canonical-forms invariant; C discards the encoding
entirely and pays for a whole new metatheory). **Which of these — if any —
is the intended target is not decided by the inventory finding and is not
decided here.** The inventory's own framing ("there is no formalized notion
of a mutable table field that is not, by type, a reference cell") is
accurate as a description of the *current* file; whether closing that gap
is worth Option B's or C's cost, versus leaving it as a documented,
consciously-chosen tradeoff (M4's stated rationale), is the owner's call.

---

## 3. Hygiene: extracting the interleaved `ssub`/`rsub` development

### 3.1 What is actually there (confirmed by direct reading, not carried over from the inventory)

`proof/typing.v` contains two non-contiguous blocks that operate purely on
`BTy`/`ssub`/`rsub`, with zero dependency on `tm`/`has_type`/`step`:

- `typing.v:621-846`: `Inductive ssub`/`srec` (the syntactic subtyping
  relations, including the union/intersection rules), `ssub_sound` (`ssub ⊆
  dsub`), the union/intersection helper lemmas, and `Inductive rsub`
  (reference-aware subtyping: `RsSsub`/`RsTrans`/`RsRefInv`/`RsAnyRef`) with
  `rsub_sound`.
- `typing.v:2505-3432`: the supertype-inversion/shape machinery for both
  relations — `ssub_top_univ`/`ssub_bot_empty`, the arrow/record/atom
  `_above`/`_mono`/`_sound` inversion families, the union/intersection-target
  leaf inversions, the cross-kind non-subtyping lemmas, and the `rsub`-side
  mirror (`rsub_ref_above`, `rsub_anyref_above`, ~20 `rsub_*_not_*` lemmas,
  ending exactly at `typing.v:3431`, immediately before the `7. CANONICAL
  FORMS` section header at `3432` which *does* depend on `tm`/`has_type`).

Cross-reference direction (confirmed, not merely asserted): block-2 material
(the inversion lemmas) is consumed by the operational core's inversion
lemmas (`inv_prim`, `inv_newidx`, canonical forms, etc., all downstream of
`3432`) but consumes nothing from the operational core itself — the
dependency is one-directional, which is what makes the extraction
mechanically sound (no cycle to break).

### 3.2 Finding this proposal depends on: `proof/ssub.v`'s actual relationship to this material

The task asked this to be checked before proposing the extraction, since it
determines what the extraction target even is. Direct reading of
`proof/ssub.v`'s header (`ssub.v:1-65`) and its own `Require Import` lines
(`ssub.v:67-68`, `Require Import subtype.` / `Require Import typing.`)
gives an unambiguous answer:

**`ssub.v` is not a divergent copy of the interleaved development, and it
is not the extraction target either — it is a genuine downstream consumer
of it.** Its header states plainly: "`typing.v` is UNMODIFIED. This file is
purely additive: it imports `ssub` and its inversion lemmas from `typing.v`
... and adds: (1) PREORDER ... (2) a TOTAL, TERMINATING DECISION PROCEDURE
`decide_ssub` ... (3) THE `ssub`-vs-`dsub` GAP, characterized." `ssub.v`
does **not** contain its own `Inductive ssub`/`rsub` — it cites `typing.v`'s
(e.g. `ssub.v:98-99`, `Lemma ssub_refl : forall t, ssub t t. Proof. intro t.
apply SsRefl. Qed.` — `SsRefl` is `typing.v`'s constructor, not
redeclared). Its own comments (`ssub.v:84-95`) explicitly rely on
`typing.v`'s inversion machinery (the block-2 material, e.g.
`ssub_arrow_super`) for its transitivity-composition reasoning. Separately,
`ssub.v` also cites `has_type`/`TSub` directly (`ssub.v:1246-1248`,
`1554-1556`, a subsumption-decidability consumer of the operational core),
so it depends on `typing.v` for two distinct things: the `ssub`/`rsub`
relations+inversions (block 2), and the operational `has_type` judgment
(the block-3 core) — not on one alone.

Consequence for the extraction plan: relocating blocks 621-846 and
2505-3432 out of `typing.v` into a new file changes `ssub.v`'s dependency
edges (it would need to `Require` the new file for `ssub`/`rsub` facts, in
addition to still requiring `typing.v` for `has_type`), but does **not**
require touching `ssub.v`'s own logical content — none of its lemmas
change statement or proof, only which file they resolve their `Require`
against. This is a mechanical dependency-graph change, not a re-proof.

**On `ssub.v`'s current hang-at-compile** (flagged in the task as under
separate diagnosis, not this proposal's to resolve): the finding above
means the hang is not explained by `ssub.v` duplicating or diverging from
the interleaved development — it genuinely only adds the three items its
header claims. One *hypothesis* the extraction would let a separate
diagnosis test cheaply, offered as a hypothesis and explicitly not asserted
as a finding: `ssub.v` currently pulls in the *entire* 9480-line
`typing.v`, including its ~3000-line example/demonstration tail
(`6489-9480`, per the inventory's block 4) and the full operational
preservation/progress proofs, to get facts that (per its own header) only
need the `ssub`/`rsub` relations, their inversions, and `has_type`/`TSub`'s
bare judgment shape. If the hang is a resource/performance issue rather
than a logical one, a smaller `Require` surface is the kind of thing that
could matter — but this is speculation about an unresolved external
diagnosis, not a claim, and it is not required for the extraction proposal
below to be valid on its own hygiene merits.

### 3.3 Proposed extraction

Move `typing.v:621-846` and `typing.v:2505-3432` verbatim into a new file
(working name — **not ratified**, candidates: `proof/ssub_core.v`,
`proof/subtype_syntactic.v`; the existing `proof/ssub.v` name is already
taken by the decision-procedure file and reusing it would collide with that
file's own established identity and header claims, so a new name is
needed — this naming choice is left open for the owner rather than guessed).

Resulting dependency chain (mechanical, no cycle):

```
subtype.v  →  ssub_core.v  →  typing.v  →  ssub.v  →  check.v
                  ↑                            |
                  └────────────────────────────┘
              (ssub.v also Requires ssub_core.v directly,
               for ssub/rsub facts it currently gets via typing.v)
```

`typing.v` would `Require Import ssub_core.` in place of its own inline
`Inductive ssub`/`srec`/`rsub` and the 2505-3432 inversion block; every
downstream use inside `typing.v` (`TSub`'s `rsub` premise, `inv_prim`'s
`rsub` conclusions, canonical forms' use of the `_above`/`_not_*` lemmas)
is a `Require`-resolved name lookup, unchanged in content. `ssub.v` gains
one more `Require Import ssub_core.` line alongside its existing `Require
Import typing.`.

**Proof-impact assessment:** this is a pure textual relocation, not a
restatement — no lemma's statement or proof term changes, only the file
it lives in and the `Require` chain that resolves its names. Because the
inventory already confirmed (§1 of the evidence report) that this block
has zero dependency on `tm`/`has_type`/`step`, there is no forward
reference from block 2 into block 3 to break. Estimated re-prove scope:
**zero** — this is a cut-paste-plus-`Require Import`, not a re-derivation.
The only mechanical risk is Coq's `Scheme ssub_mind := Induction for ssub
... with srec_mind := ...` (`typing.v:672-673`), which must move together
with the `Inductive ssub`/`srec` it is generated from (it already sits
immediately after them, so this is satisfied by the "move verbatim, keep
adjacent" instruction, not an extra step).

**What is not addressed by this extraction:** it is purely a file-hygiene
move. It does not change `ssub`'s coarseness on the connective fragment
(`ssub.v`'s own documented gap vs. `dsub`), does not touch `rsub`'s two
reference rules, and has no bearing on the Target 1 or Target 2 questions
above — the three targets are independent restructurings that happen to
share a file.

### 3.4 The header fix

`typing.v`'s header (`typing.v:1-19`) currently states the file's SCOPE as
"literals, variables ... application, let ..., record construction, field
projection, and SUBSUMPTION" with "statements / control flow, mutation,
multi-arg / vararg / multi-return, recursion (fix / mu), metatables,
unions/negation/arrows AS term-formers" listed as "DEFERRED to the
proof-dev backlog." The inventory's §3 confirms, with line citations, that
every one of those "deferred" items is in fact present, typed, stepped, and
proved sound in the current file (`tif`/`tifn` at `124`/`990`; `talloc`/
`tderef`/`tassign`/`tloc` at `186-189`/`1020-1035`; `tret`/`tfst`/
`tappspread`/`tvapp`/`tmassign` at `226-347`/`1047-1256`; `tfix` at `159`/
`1000-1002`; the full metatable cluster at `248-305`/`1084-1227`). This is a
stale header, not a stale decision doc (the charter's docs-freeze policy
covers `docs/`, not `.v` file headers, which are working code comments) —
per this repo's own conventions, code that no longer matches its header
comment should have the comment corrected in the same commit as whatever
change prompted noticing it (here: this proposal, or its eventual
implementation).

**Proposed replacement header SCOPE line** (draft text, for the owner to
edit/ratify, not to be taken as final prose):

> SCOPE (honest, current): a CBV language with literals, variables (de
> Bruijn), lambdas/application/let, records + field projection, subsumption
> (subtyping via `rsub`), conditionals + flow-narrowing (`tif`/`tifn`/
> `ttypetest`), references/mutation (`talloc`/`tderef`/`tassign`), general
> recursion (`tfix`), multi-return/vararg/multi-assign (`tret`/`tfst`/
> `tappspread`/`tvapp`/`tmassign`), and metatables/metamethods (`tmeta`/
> `tnewidx`/`tunop`/`trawget`/`trawset`). NOT modeled: computed arithmetic
> values (types only, no magnitude — see the increment-19 note below),
> general `==`/string concat/unary ops outside the metamethod path,
> equirecursive/cyclic tables, dynamic (`setmetatable`-style) metatables,
> coroutines, FFI, a general stdlib. See `docs/typechecker-v10-prefix-inventory.md`
> for the full, line-cited accounting.

This is offered as a starting draft, explicitly flagged as prose the owner
should edit rather than adopt verbatim — the task's brief was to propose
the fix, not to finalize its wording.

Note also (staleness the inventory separately flagged, §3 of the evidence
report, not part of this proposal's scope to fix): `TODO.md`'s reference
"split-step 3" backlog entry describes threading store+references into
`typing.v` as "NEXT ... DEFERRED" when it is already done in the current
file. This is a `TODO.md` currency issue, not a `typing.v` header issue,
and is out of scope for this proposal (flagged for the owner's awareness
only).

---

## Summary of open questions requiring owner ratification

1. **Target 1 fork:** Option A (in-place citation-level split of
   `inv_prim`, cheap, does not touch `step`'s shape or produce a true
   prefix) vs. Option B (new, freestanding smaller-grammar development,
   `typing.v` untouched, produces a true prefix at the cost of new proof
   volume) — materially different answers to "restructure the
   entanglement," not variants of one design.
2. **Target 2 fork:** Option A (cosmetic naming, zero cost, does not
   address the finding), Option B (new `BMut T` type marker, keeps the
   records-of-refs encoding, requires a new canonical-forms invariant —
   named explicitly as a new proof obligation), or Option C (native
   table-mutation semantics, discards M4's free-inheritance design
   entirely, full new metatheory) — three points on a cost/fidelity curve,
   not a single answer.
3. **Target 3 naming:** the new file's name for the extracted `ssub`/`rsub`
   development (candidates offered, none ratified) — collides with nothing
   logically, but the name itself is undecided.
4. **Target 3 diagnostic hypothesis:** whether `ssub.v`'s current
   hang-at-compile is related to the size of what it currently transitively
   `Require`s through `typing.v` — offered as an untested hypothesis for
   the separate diagnosis to check or discard, not asserted as a finding of
   this proposal.
5. **Header fix wording:** draft text offered in §3.4 is a starting point,
   not final prose.

No option above has been chosen on the owner's behalf. Per the halt-on-
underspecification discipline this session operated under, every fork
above is presented because resolving it silently would mint semantics or
scope that downstream implementation work would then treat as settled.
