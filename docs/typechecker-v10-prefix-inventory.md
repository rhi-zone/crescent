# v10 prefix inventory — `proof/typing.v` as prefix-v1 evidence

Status: evidence report, not a design document. Produced by the sole
sanctioned crossing into `proof/` per
`docs/decisions/typechecker-v10-core-charter.md` item 3. This document is
what downstream design work reads INSTEAD of `proof/typing.v` itself. It
reports what is formalized, where, and with what semantic commitment — it
does not recommend a layer set, a prefix scope, or any other design
decision. Every claim below cites a specific line range or definition/lemma
name in the cited `.v` file so it can be independently re-verified.

Read scope for this report: `proof/typing.v`, `proof/subtype.v`,
`proof/ssub.v`, `proof/check.v` (headers + structure, to establish file
boundaries), `proof/bridge_*_oracle.v` (scratch oracles), `docs/reality-bridge.md`,
`docs/decisions/typechecker-v10-core-charter.md`,
`docs/decisions/typechecker-v10-core-design.md`,
`docs/decisions/typechecker-v10-design-sync.md` §1, and the "Proof-dev /
type-system backlog" section of `TODO.md`. `lib/type/static/`,
`lib/type/static-v5/`, `lib/type/framework/`, `declc`, and
`lib/sem/bridge/exec.lua` internals were NOT read (out of scope per the
charter); `docs/reality-bridge.md`'s prose account of the bridge was used
instead.

---

## 0. File-boundary correction to the design-sync §1 prior finding

`docs/decisions/typechecker-v10-design-sync.md` §1 records: "`typing.v`
bundles (a) a genuine CBV small-step operational semantics with progress and
preservation... together with (b) v9's own algorithmic-checker-soundness
proof, and (c) a subtype-lattice proof... under one file family."

Direct reading of the `Require Import` lines and file headers **partially
corrects** this:

- **(b) is WRONG as stated about `typing.v` itself.** The algorithmic
  checker (bidirectional `synth`/`check`, `synth_sound`, `check_sound`) lives
  entirely in `proof/check.v`, a SEPARATE file that does `Require Import
  subtype. Require Import typing. Require Import ssub.` (`check.v:1-45`).
  `check.v`'s own header states it is "purely ADDITIVE" and lists
  `subtype.v`/`typing.v`/`ssub.v` as "UNMODIFIED" (`check.v:17-19`). There is
  no `synth`/`check`/checker-soundness content inside `typing.v` itself — the
  "under one file family" framing is accurate only if "file family" means
  the whole `proof/` directory (four files sharing a `Require` chain), not
  that `typing.v` textually contains the checker.
- **(c) is PARTIALLY correct, but the target is imprecise.** The SEMANTIC
  subtype-lattice proof (the value-set Boolean algebra: `Atom`, `BTy`, `V`,
  `dsub`, `gdecide`) lives entirely in `proof/subtype.v`, also a separate
  file, `Require`d by `typing.v` (`typing.v:25`) but not modified by it.
  However, `typing.v` DOES itself define and prove a substantial,
  self-contained **syntactic** subtyping development — the `ssub`/`rsub`
  relations and ~930 lines of their inversion/decidability-support
  metatheory (detailed in §1 below) — that operates purely on `BTy` with NO
  dependency on `tm`/`has_type`/`step`. This block is genuinely bundled
  inside `typing.v` and is logically separable from the operational
  semantics around it, even though the file's own header (`typing.v:1-19`)
  describes `typing.v` as being about the *typing layer atop* the subtyping
  algebra of `subtype.v` — it undersells that `typing.v` also DEFINES its
  own second subtyping algebra (`ssub`/`rsub`), not merely consumes
  `subtype.v`'s.
- **(a) is confirmed.** `typing.v` does contain a genuine CBV small-step
  operational semantics (`step`, `tm`, `value`) with `progress` and
  `preservation` proved to `Qed`, with no `Admitted`/`Axiom`/`Classical`
  (confirmed by header `typing.v:1-19` and by reading the `progress`
  (`typing.v:6079`) and `preservation` (`typing.v:5115`) theorem statements
  and their placement relative to the `Inductive step`/`Inductive has_type`
  definitions).

**Corrected file-family map** (dependency order, `Require Import` chain):

| file | lines | Requires | what it proves |
|---|---|---|---|
| `subtype.v` | 4769 | (none, base) | `Atom`/`BTy`/`V`, `dsub` (semantic subtyping), `gdecide` (emptiness-based decider) — the semantic Boolean-algebra subtype lattice |
| `typing.v` | 9480 | `subtype` | `tm`/`step`/`has_type`, `progress`+`preservation` (the CBV op-sem soundness pair) — **AND** its own `ssub`/`rsub` syntactic subtyping relations + ~930-line inversion metatheory (see §1) — **AND** a ~3000-line example/demo tail (see §1) |
| `ssub.v` | 1579 | `subtype`, `typing` | `decide_ssub` (total decision procedure for `typing.v`'s `ssub`), preorder facts, `ssub`-vs-`dsub` gap characterization |
| `check.v` | 2057 | `subtype`, `typing`, `ssub` | the bidirectional algorithmic checker `synth`/`check` + `synth_sound`/`check_sound` — **the actual "v9 algorithmic-checker-soundness proof"** the prior finding attributed to `typing.v` |

## 1. Disentangling `typing.v`'s own internal bundle

`typing.v` (9480 lines) is not one undifferentiated development. Reading it
top to bottom by section marker (`(* === ... === *)` comments) and by what
each block's lemmas actually range over (`BTy` alone vs. `tm`/`has_type`/
`step`) gives five internally-distinct blocks:

1. **Term/type syntax** (`typing.v:40–347`): `tag`, `lit`, `primop`, `unop`,
   `tm` (the ~30-constructor term grammar), plus `tag_type`/`lit_type`/
   `arith_op`/`cmp_op`/`mm_binop`/`mm_unop`/`pad_tm`/`pad_ty` helper
   definitions (`347–458`) and a strengthened induction principle
   `tm_ind_strong` (`461–586`).

2. **A second, SYNTACTIC subtyping development, `ssub`/`rsub`**
   (`typing.v:621–848` for the relations + soundness, **and**
   `typing.v:2505–3432` for their inversion/decidability-support metatheory —
   ~1450 lines total, non-contiguous):
   - `Inductive ssub` (`624–664`): `SsRefl`/`SsTrans`/`SsTop`/`SsBot`/
     `SsAtom`/`SsArrow`/`SsRec`, plus union rules `SsUnionInL/InR/E`
     (increment 11) and intersection rules `SsInterPL/PR/I` (increment 12).
     Mutually inductive with `srec` (pointwise record-field subtyping,
     `664–675`). **Negation has no structural `ssub` rule** — reflexive-only,
     by explicit design note at `typing.v:655–663` (adding one would force
     `ssub` to decide emptiness, which is `dsub`'s job in `subtype.v`).
   - `ssub_sound` (`716–760`): `ssub ⊆ dsub`, proved by induction into
     `subtype.v`'s `denote`/`dsub`.
   - `Inductive rsub` (`821–825`): embeds all of `ssub` (`RsSsub`) plus
     `RsTrans`, `RsRefInv` (invariant `BRef`), `RsAnyRef` (any-ref
     widening) — the reference-aware subtyping `TSub` actually subsumes
     along (`typing.v:966`). Per the comment at `typing.v:797–819`, this
     `rsub` was **promoted into `typing.v`** from `ssub.v` as part of
     "SPLIT-STEP 3" (threading store+references into the main typing
     layer) — see the TODO.md staleness note in §3 below.
   - `typing.v:2505–3432` (~930 lines): union-robust supertype-inversion
     machinery (`arrow_above`/`rec_above`/`atom_above`/`top_above`/
     `interneg_above`, each with a `_mono` monotonicity lemma and a
     `_sound` converse), the union/intersection-target leaf inversions
     (`ssub_union_tgt_inv`, `ssub_inter_tgt_inv`), the cross-kind
     non-subtyping lemmas (`ssub_rec_not_arrow`, `ssub_atom_not_arrow`,
     etc.), and the entire `rsub`-side mirror of the same machinery
     (`rsub_ref_above`, `rsub_arrow_above`, `rsub_tuple_above`, and ~20
     `rsub_*_not_*` cross-kind lemmas, `3083–3432`). **This whole block
     operates purely on `BTy`/`ssub`/`rsub` — it never mentions `tm`,
     `has_type`, or `step`.** It is logically a subtyping-lattice
     development, textually interleaved with the operational-semantics
     content around it (canonical forms at `3432` immediately follow it and
     DO depend on `tm`).

   This is the concrete, precisely-located referent for the prior finding's
   "(c) subtype-lattice proof" claim — but it is `typing.v`'s OWN syntactic
   lattice (`ssub`/`rsub`), separate from and in addition to `subtype.v`'s
   semantic lattice (`dsub`), and it is genuinely extractable (no
   `tm`/`has_type`/`step` dependency) even though it currently sits
   textually inside the same file as the operational core.

3. **The operational-semantics core** (`typing.v:919–2011`,
   `2011–2505` inversions, `3432–6489` metatheory + theorems): `has_type`
   (`924–1256`, 27 constructors), `value`/`lift`/`subst` (`1295–1430`),
   `step` (`1573–1905`, ~70 constructors including congruences), canonical
   forms (`3438–3575`), flow-narrowing soundness (`truthy_narrows`/
   `falsy_narrows`/`tag_narrows`, `3594–3716`), weakening/substitution
   metatheory (`3716–5015`), and the two headline theorems `preservation`
   (`5115–6005`) and `progress` (`6079–6489`). This is the genuine CBV
   op-sem the design-sync finding correctly identified as (a).

4. **A ~3000-line example/demonstration tail** (`typing.v:6489–9480`, ~32%
   of the file's line count): `Definition`/`Lemma`/`Theorem` pairs
   instantiating `has_type`/`step`/`progress`/`preservation` on concrete
   closed programs — one cluster per feature (metatables' `__call`/`__add`/
   `__newindex`/`__concat`/`__unm`/`__len`/`rawget`/`rawset`, ascending/
   descending numeric `for`-loops, a generic `for`-in loop, multi-return
   truncation/spread, vararg truncation/forwarding, multiple-assignment
   truncate/pad/drop, reference aliasing, mutable-table field cells). **No
   new `Inductive` constructors appear anywhere in this range** (confirmed
   by the structural grep in §2) — it is entirely example/fixture content,
   not new metatheory. Extraction of the operational core (block 3) would
   leave essentially all of this tail behind as it directly instantiates
   the very features whose header claims them deferred (see §3).

**Cross-references between blocks 2 and 3:** `has_type`'s subsumption rule
`TSub` (`typing.v:964–967`) cites `rsub` (block 2) directly, and the
`inv_*` inversion lemmas (block 3, `2011–2505`) rely on the `ssub`/`rsub`
shape lemmas of block 2 (`2505–3432`) to invert `TSub`. So block 2 is
consumed by block 3 but not vice versa — block 2 could be extracted upstream
of block 3 without touching block 3's proofs, but block 3 cannot be
extracted without either bringing block 2 along or re-deriving equivalent
subtyping-inversion facts.

## 2. Rule-by-rule inventory of the operational semantics

### 2.1 Value forms (`Inductive value`, `typing.v:1295–1309`)

| constructor | commitment |
|---|---|
| `VLit` | none — any literal is a value; structural |
| `VLam` | none beyond closures-as-syntax (no environment; substitution-based) |
| `VRec` | needs "table" only as a finite field-list container; no mutation |
| `VLoc` | **refs**: a bare store address is itself a value form |
| `VRet` | **multi-return**: a fully-evaluated return-sequence is its own value kind |
| `VMeta` | **metatables**: a metatable-table (own-fields + prototype) is a value kind distinct from `VRec` |

### 2.2 `step` rules (`typing.v:1573–1905`), classified by minimal semantic
requirement. "Structural" = provable/statable with only `tm`/CBV
congruence, no table/ref/primop-magnitude/metamethod knowledge.

| rules | commitment | note |
|---|---|---|
| `SBeta`, `SLet`, `SLet1`, `SApp1`, `SApp2` | structural (pure CBV core) | — |
| `SProj`, `SProj1`, `SRec` | table (field-list), no mutation | `trec` fields are plain terms |
| `SPrim1`, `SPrim2`, `SPrimArith`, `SPrimCmpTrue`, `SPrimCmpFalse` | primop, but **ABSTRACT** — no arithmetic is computed | `SPrimArith` steps `tprim op (tlit LInt) (tlit LInt)` to `(tlit LInt, st)` **regardless of which arithmetic op or operand**; `SPrimCmpTrue`/`SPrimCmpFalse` are two rules for the SAME redex (non-deterministic boolean result). Numbers are "type-classes with no magnitude" per the increment-19 comment (`typing.v:382–388`) — this is a genuinely thin commitment (knows arith-vs-cmp classification only), separable from real arithmetic semantics |
| `SIfTrue`, `SIfFalse`, `SIf1` | needs only the Bool-literal case of `value`/`lit` | minimal |
| `SIfnTrue`, `SIfnFalse`, `SIfn1` | **Lua-specific truthy/falsy VALUE classification** (`falsy_value`, `typing.v:1445–1446`: only `false`/`nil` are falsy — table/function/number/string/location are ALL truthy) | this is a real semantic commitment, not structural — it encodes a specific language's truthiness rule |
| `SIfnMultiCons`, `SIfnMultiNil` | truthy/falsy (above) **entangled with multi-return**: a multivalue scrutinee must be truncated to its head before the truthy/falsy test can apply | fracture-line: `tifn`'s "own" commitment (truthiness) cannot be stated without also having the multi-return substrate in scope |
| `SFix` | structural (self-substitution only) | no data-type commitment; general recursion is "free" here |
| `STtTrue`, `STtFalse`, `STt1` | **the full `tag`/`type()` vocabulary** — `has_tag` (`typing.v:1495–1507`) pattern-matches on literal-kind, `trec`, `tmeta`, `tlam`, `tloc`, and `tret` to assign one of 7 tags | fracture-line: `ttypetest`'s mechanism ("dispatch by runtime classifier") is generic, but its CURRENT formalization is total over a tag enum that spans every other axis (tables, refs, functions, multivalues) — it cannot be stated for a sub-language lacking any one of those value kinds without shrinking the tag enum itself |
| `SAlloc`, `SAlloc1`, `SDeref`, `SDeref1`, `SAssign`, `SAssign1`, `SAssign2` | **refs/store**: needs the store-indexed configuration `tm * store`, not just term evaluation | a genuine extra dimension (mutable state) beyond a pure-term CBV judgment |
| `SAnnot1`, `SAnnotV` | structural (erasure) | — |
| `SRet`, `SFstCons`, `SFstNil`, `SFst1`, `SAppSpread`, `SAppSpread1`, `SAppSpread2` | **multi-return** (sequence-of-values + truncation + spread) | separable axis: no ref/table dependency |
| `SMeta1`, `SMeta2`, `SMetaProjOwn`, `SMetaProjProto` | **tables + prototype-chain dispatch** (dynamic `__index` fallback) | genuinely new commitment beyond `SProj`: runtime fallback search through a chain, not a fixed field-list lookup |
| `SCallMeta`, `SPrimMetaL`, `SPrimMetaR`, `SUnMetaL` | **metatables entangled with primop/unop** | fracture-line, sharpest instance: `tprim`'s step relation (otherwise the abstract, content-free `SPrimArith`/`SPrimCmp`) must pattern-match "is this operand a `tmeta` value" to route to metamethod dispatch. Arithmetic and table-dispatch are NOT separable within the single `tprim` constructor family as formalized — a prefix wanting "just arithmetic, no tables" cannot cite `tprim`'s step rules without also bringing in `tmeta`/`__index` |
| `SNewIdx`, `SNewIdx1/2/3` | **tables AND refs, combined by construction** | `tnewidx`'s dispatch reduces to `tassign (tproj ni k) v` — a table write is ALWAYS modeled as a ref-cell write (records-of-refs encoding). See §2.3, this is baked into the typing rule's premises too, not just an operational convenience |
| `SUnop1` | structural congruence only | — |
| `SRawGet`, `SRawGet1/2`, `SRawSet`, `SRawSet1/2/3` | tables + refs (same entanglement as `SNewIdx`, minus the prototype-fallback search) | — |
| `SVApp`, `SVApp1/2/3` | **vararg**, but reuses multi-return + application cleanly — no new commitment beyond composing the two | clean composition, not entanglement |
| `SMAssign`, `SMAssign1/2` | **multi-assign**, composes refs (assign) + multi-return (arity padding via `pad_tm`) | also a clean, deliberate composition (via existing `store_update`), not an accident |

**Summary fracture line:** a layer boundary of "structural < primop(abstract)
< refs < multi-return < tables" is nearly realizable from the rule set
alone (each of these axes has a cluster of rules that ONLY need that axis),
**except** that (1) `ttypetest`'s tag enum is total over ALL value kinds at
once (no sub-tag-enum exists in the file), (2) `tprim`'s step relation is
entangled with `tmeta` via `SPrimMetaL`/`SPrimMetaR` (arithmetic cannot be
cited independent of tables), and (3) "tables" as formalized here are never
a freestanding axis from "refs" — mutable table field writes
(`tnewidx`/`trawset`) are ALWAYS refs-of-cells underneath (see §2.3). These
three points are the concrete, rule-level evidence for where the
formalization's actual joints are, versus where a clean layer cut might be
assumed to exist.

### 2.3 `has_type` rules (`typing.v:924–1256`, 27 constructors + 2 mutual
judgments `has_fields`/`has_types`)

The classification mirrors §2.2 one-for-one (each `step` rule pairs with a
`has_type`/inversion rule for the same construct), with one addition worth
flagging precisely: **`TNewIdx`, `TRawSet` require the target field's type
to be `BRef T`** (`typing.v:1180`, `1223`) — i.e. it is not merely the
OPERATIONAL rule that treats a table as refs-of-cells; the STATIC TYPE of a
writable table field is required, by the typing rule's premises, to be a
reference type. "Table" and "ref" are coupled at the type-formation level
in this model, not only as a reduction-strategy choice. This is the
sharpest fracture-line finding in the whole inventory: **there is no
formalized notion of a mutable table field that is not, by type, a
reference cell** — a prefix layer that wants "tables" without "refs" would
have to either forbid all table mutation, or introduce a genuinely new
table-mutation typing/step rule pair not present in this development.

Two further single-rule notes, precisely located:

- `TPrimMetaR` (`typing.v:1157–1162`) requires the LEFT operand's type to be
  a bare `BAtom al` (a scalar) specifically so that (per the comment,
  `1140–1156`) the rule is "STABLE UNDER SUBSTITUTION" and "STEP-DISJOINT"
  from `SPrimMetaL` — i.e. the disjointness of the two metamethod-dispatch
  directions is secured by a TYPE-LEVEL discriminator (scalar vs. table),
  not a syntactic one. This is a place where the typing layer's design is
  load-bearing for the operational semantics' determinism-adjacent
  property, not merely descriptive of it.
- `TIfn`/`TTypeTest` (`typing.v:990–1017`) both bind their scrutinee FRESH
  under a new binder in both branches specifically because (per the
  extensive comment at `typing.v:125–146` and `160–177`) narrowing a FREE
  context entry is UNSOUND under substitution-based CBV semantics — the
  binding-form design is a direct consequence of the substitution
  representation choice (de Bruijn + eager substitution), not an
  independent stylistic choice. Any prefix layer wishing to support
  flow-narrowing inherits this constraint from the substitution semantics
  choice, not from Lua's language design per se.

## 3. Header vs. content

`typing.v`'s header (`typing.v:1–19`) states: **"SCOPE (honest, minimal
core): literals, variables (de Bruijn), single-arg typed lambdas,
application, let..., record construction, field projection, and
SUBSUMPTION... DEFERRED to the proof-dev backlog: statements / control
flow, mutation, multi-arg / vararg / multi-return, recursion (fix / mu),
metatables, unions/negation/arrows AS term-formers."**

Direct reading of the file's own `Inductive tm`/`has_type`/`step` **confirms
the prior finding: every one of the "DEFERRED" items is in fact present,
typed, stepped, and proved sound**, with precise line citations:

| header says "DEFERRED" | actually present at | proved to |
|---|---|---|
| statements / control flow | `tif`/`TIf`/`SIfTrue` (`124`, `968`, `1630`); `tifn` flow-narrowing (`147`, `990`, `1634`) | `progress`/`preservation` (`5115`, `6079`), plus dedicated payoff lemmas (`6570–6797`) |
| mutation | `talloc`/`tderef`/`tassign`/`tloc` (`186–189`), full store-based `step`/`has_type` (`1543–1907`, `TLoc`/`TAlloc`/`TDeref`/`TAssign` at `1020–1035`) | `preservation` over a typed store (`store_well_typed`, `1911`), reference-aliasing payoff (`6948–7009`) |
| multi-arg / vararg / multi-return | `tret`/`tfst`/`tappspread` (`226–228`, `TRet`/`TFst`/`TAppSpread` `1047–1071`); `tvapp` (`325–326`, `TVApp` `1235–1239`); `tmassign` (`346–347`, `TMAssign` `1252–1256`) | full progress/preservation re-proof per TODO.md increments 21/22/27 (`TODO.md:1353–1400`), plus payoff lemmas (`7708–8140`) |
| recursion (fix/mu) | `tfix` (`159`, `TFix` `1000–1002`, `SFix` `1649`) | soundness holds even under divergence (comment `typing.v:148–158`); `diverge` example (`6693`) |
| metatables | `tmeta`/`tnewidx`/`tunop`/`trawget`/`trawset` (`248–305`) plus 6 typing rules (`TMeta`/`TCallMeta`/`TPrimMetaL`/`TPrimMetaR`/`TNewIdx`/`TUnMetaL`/`TRawGet`/`TRawSet`, `1084–1227`) and 12 step rules (`1712–1860`) | `progress`/`preservation`, plus the largest example cluster in the file (`8141–8834`, `__call`/`__add`/`__newindex`/`__concat`/`__unm`/`__len`/`rawget`/`rawset`) |
| unions AS term-formers | `tif`'s result type is `BUnion T1 T2` (`TIf`, `972`); `ttypetest`'s and `tifn`'s results are likewise unions (`994`, `1017`) | `progress`/`preservation`; union-typed conditional example `ex_if` (`6538–6547`) |

**Not confirmed as present** (the header's "arrows/negation AS term-formers"
claim, re-read precisely): arrow and negation types exist in `BTy`
(`subtype.v:657`, `BArrow`/`BNeg`) and are used pervasively as VALUE TYPES
(every `tlam` has an arrow type), but there is no term-language CONSTRUCT
whose surface syntax directly introduces/eliminates a `BUnion`/`BInter`/
`BNeg` as a first-class term operation independent of `tif`/`tifn`
(e.g. no explicit "inject into a union" or "case-split an intersection"
term former distinct from the conditional forms). So this specific header
clause is the one part of the "deferred" list that reads as roughly
accurate on a strict term-former reading, though the union TYPE itself is
fully present and used as stated above.

**A stale internal cross-reference worth flagging precisely (not part of
the original prior finding, newly observed):** the `TODO.md` "Proof-dev
backlog" entry for reference unification "split-step 2" (`TODO.md:1320–1349`)
ends with "**NEXT (split-step 3, DEFERRED):** thread store + references into
the typing layer... promote `RsRefInv`/`RsAnyRef` into `ssub`'s inductive in
`typing.v`." But `typing.v` as currently read ALREADY contains this
("SPLIT-STEP 3" comment block, `typing.v:797–819`, and the `rsub` inductive
itself at `821–825`, with store-based `step`/`has_type` fully threaded
through `1543–1907`/`919–1256`). The backlog entry's "NEXT...DEFERRED"
framing is stale relative to the current file content — split-step 3 is
done in the code, not merely planned. This is a documentation-currency
observation, not a design finding.

## 4. Coverage vs. real Lua

What crescent-Lua's actual surface has that this formalization does NOT
cover, per direct reading plus the `TODO.md` backlog's own deferred-items
list (`TODO.md:1225–1550`+):

- **Arithmetic has no computed value at all.** `SPrimArith` produces
  "SOME number value" (always `tlit LInt`) with no relation to the actual
  operands (`typing.v:1607–1610`); comparison is modeled as
  non-deterministic (`SPrimCmpTrue`/`SPrimCmpFalse`, either may fire on any
  fully-applied comparison, `1611–1618`). This is by explicit design
  ("types, not magnitudes" stage-2 refactor, `TODO.md:1518–1543`) — the
  model tracks arithmetic's TYPE only, never its VALUE. No modulo, no
  floor-division `//`, no bitwise ops exist at all (`primop` has only
  `PAdd`/`PSub`/`PMul`/`PDiv`/`PLt`/`PLe`/`PEq`/`PConcat`,
  `typing.v:80–94`); `PDiv` computes nothing (same abstract rule as
  `PAdd`/`PSub`/`PMul`).
- **Structural equality is numbers-only.** `TPrimCmp` requires BOTH
  operands typed `BAtom ANum` for ALL of `PLt`/`PLe`/`PEq`
  (`typing.v:940–944`) — there is no general Lua `==` (string/table/nil/
  boolean equality) in the declarative typing rules; `PEq` between
  non-numbers is only reachable via the metamethod path (`TPrimMetaL`/
  `TPrimMetaR`, and only if the operand is a `tmeta` carrying a `__eq`
  metamethod — the comment at `typing.v:1117` lists `__eq`/`__lt`/`__le`
  as included in principle via `mm_binop`, but the plain-value comparison
  path (no metatable) never fires for non-numbers).
- **String concatenation and unary numeric ops are metamethod-only.**
  `PConcat`/`UNeg`/`ULen` have NO built-in numeric/string path at all —
  `arith_op`/`cmp_op` both return `false` for `PConcat`
  (`typing.v:74–94`); their ONLY typing/step rules are the metamethod
  dispatch (`TPrimMetaL` via `mm_binop PConcat = "__concat"`; `TUnMetaL`).
  There is no value-level string-concatenation or numeric-negation
  semantics anywhere in the model.
- **No general stdlib.** `TODO.md:1491–1492`: "No stdlib modelled in the
  proof value domain." No `string`/`table`/`math` library functions.
- **No coroutines.** No `thread` runtime kind anywhere in `tag`
  (`typing.v:44–63`) or `V` (`subtype.v:708+`); `TODO.md:1493–1496` lists
  `cdata`/`userdata`/`thread` together as an undone "separate
  runtime-representation axis."
- **No FFI / cdata integers**, hence no LuaJIT-specific fixed-width integer
  semantics (`TODO.md:1493–1496`).
- **No general `for-in` iterator protocol as a primitive.** The `tforin`
  construct in the example tail (`typing.v:9126–9256`) is a HAND-DESUGARED
  demonstration built from `twhile`/`tmassign`, not a first-class term
  former with its own typing/step rules; `TODO.md:1497–1498` confirms
  "General `for-in` iterators... out of the modelled fragment."
- **No closed/exact records, no index signatures, no first-class table
  atom.** `BRec` is read open/width only (`subtype.v:653–655`); closed
  records, `{[K]:V}` index signatures, and a dedicated table atom (as
  opposed to `BRec []`, the vacuous record) are all deferred
  (`TODO.md:1287–1295`).
- **No non-string table keys.** `VTable`'s keys are Coq `string` only
  (`subtype.v:712–714` per the reality-bridge excerpt); real Lua permits
  any non-nil key. `TODO.md:1489–1490`.
- **No recursive/cyclic tables or equirecursive types (μ).** `V` is a
  strictly positive INDUCTIVE type (`subtype.v:708+`) — a table containing
  itself is not representable in the value domain at all; this is flagged
  in the file itself as a "real fork we do not take here" (comment at
  `subtype.v` table-value constructor) and tracked as
  `TODO.md:1296–1301` ("[BLOCKING] Equirecursive μ + cyclic tables").
- **No error handling.** No `pcall`/`error`/exception-raising construct
  appears anywhere in `tm` (`typing.v:109–347`) or the backlog's Lua-
  semantics section.
- **Dynamic/first-class metatables (`setmetatable`/`getmetatable`) are
  explicitly NOT modeled**, by an explicit prior decision recorded in
  `TODO.md:1416–1420`: "The first-class / dynamic-metatable axis... was
  **DECIDED — do NOT build any first-class or dynamic-metatable
  representation now**; keep this static `tmeta`/`merge_fields` model."
  The current `tmeta` is a purely STATIC prototype-chain encoding fixed at
  term-construction time, not real Lua's mutable, runtime-`setmetatable`-
  driven metatable protocol.
- **Full occurrence-typing precision is explicitly NOT achieved**: `TIfn`/
  `TTypeTest` narrow to the bound-alone type (`truthy_type`/`tag_type g`),
  not the theoretically tighter `U ∩ truthy_type`/`U ∩ tag_type g`
  (comment `typing.v:982–989`, `1003–1009`) — an intersection-introduction
  rule would be needed for the precise version, and is deferred
  (`TODO.md:1451–1479` documents this as a further OPEN design fork with
  three unresolved candidate fixes, not merely an unbuilt increment).

## 5. Reality-bridge fit — what has empirical LuaJIT parity evidence, and what has none

This section maps `docs/reality-bridge.md`'s five evidence legs onto the
rule inventory of §2. **Two of the five legs (§1–4 of the bridge doc,
"value correspondence"/"atom membership"/"functions"/"tables") validate
`subtype.v`'s DENOTATIONAL value domain (`V`, `atom_denote`) — they are NOT
evidence about `typing.v`'s operational `step` relation at all.** `V`'s
`VFun` (an extensional finite input/output graph, reality-bridge.md
line ~262) and `VTable` (a finite string-keyed assoc-list) are a
DIFFERENT, denotational model of "function"/"table" than `typing.v`'s
actual operational values — `tlam` closures that reduce by substitution
(`SBeta`) and `trec`/`tmeta` structural records that reduce by field lookup
(`SProj`/`SMetaProjOwn`/`SMetaProjProto`). The bridge's forks (A)/(A′)/(B)/(C)
(reality-bridge.md §4) are faithfulness evidence for `subtype.v`'s `V`↔real-Lua-
value correspondence, useful for a prefix's TYPE-MEMBERSHIP layer, but say
nothing directly about whether `typing.v`'s `step` relation matches real
LuaJIT reduction.

**Only reality-bridge.md §5 ("Operational / execution axis") bridges
`typing.v` itself** — via `lib/sem/bridge/exec.lua` translating `typing.v`'s
`tm` to real Lua source and checking, for a battery of well-typed closed
terms, that the REAL LuaJIT result inhabits the `synth`-inferred type
(`check.v`'s algorithmic checker, run through `bridge_exec_oracle.v`'s
`Compute (synth [] term)` pins). This is where the empirical parity
evidence for the operational core actually lives. Its scope, precisely
against the §2 rule inventory:

**Empirically bridged** (present in the 17-term battery,
reality-bridge.md §5.3): `tlit`, `tvar` (implicitly, via `tlet`/`tlam`
binding), `tprim` (all four arithmetic ops + all three comparisons, but see
the faithfulness-gap correction below), `tlam`/`tapp`, `tlet`, `trec`/
`tproj`, `tif`, `talloc`/`tderef`/`tassign`, and ONE terminating `twhile`
loop (exercising `tfix`'s unfold machinery only through this bounded
encoding, per reality-bridge.md §5.5: "`tfix` is exercised only through the
terminating `twhile` encoding, not as open-ended recursion").

**NOT empirically bridged at all** — no term in the 17-term battery
exercises any of the following, despite each being fully formalized with
its own `has_type`/`step` rules and dedicated example lemmas in `typing.v`'s
example tail (§1, block 4):

- `tifn`/`ttypetest` (flow-narrowing) — explicitly named as out of scope
  in reality-bridge.md §5.5 ("flow-narrowing terms... are not executed").
- ALL of the metatable/metamethod machinery: `tmeta`, `tnewidx`, `tunop`,
  `trawget`, `trawset`, and the four metamethod-dispatch typing rules
  (`TCallMeta`, `TPrimMetaL`, `TPrimMetaR`, `TUnMetaL`) — none appear in
  `bridge_exec_oracle.v`'s battery (confirmed by the battery list,
  reality-bridge.md §5.3, and by `bridge_exec_oracle.v` containing no
  `tmeta` term). This is the single largest formalized-but-unbridged
  surface: the largest example cluster in `typing.v` (`8141–8834`, ~700
  lines) has zero corresponding real-LuaJIT execution evidence.
- Multi-return/vararg/multi-assign: `tret`/`tfst`/`tappspread`, `tvapp`,
  `tmassign` — none appear in the battery either, despite each having a
  full progress/preservation re-proof (`TODO.md` increments 21/22/27) and
  dedicated payoff lemmas (`typing.v:7708–8140`).
- General (open-ended, non-terminating) recursion — only the bounded
  `twhile` encoding is exercised; `diverge` (`typing.v:6693`) and general
  `tfix` unfolding have no execution-bridge evidence (unsurprising, since
  they do not terminate to a value the "well-typed term produces a value"
  assertion can check).

**A specific staleness correction to reality-bridge.md itself, sourced
precisely:** reality-bridge.md §5.4(I) currently describes a "`PDiv`
faithfulness gap — sound but unfaithful" (proof `Nat.div` computing `3`
for `7/2` vs. real Lua's float `/` computing `3.5`) and offers two
"recommendation" options to close it. Direct reading of the CURRENT
`typing.v` (`typing.v:382–388`, the increment-19 `arith_op`/`cmp_op`
comment: "There is NO value-level computation... the former
`prim_arith`/`prim_cmp` nat-level computation functions are REMOVED") and
of `bridge_exec_oracle.v`'s own in-file comment (`bridge_exec_oracle.v:37–39`:
"the former `PDiv` faithfulness gap, proof `Nat.div` vs real float
division, is moot: numbers have no magnitude; arithmetic is abstract")
**confirm this section of reality-bridge.md is stale** — it describes a
prior state of the proof development (before the "types, not magnitudes"
stage-2 refactor) that TODO.md itself records as DONE and superseded
(`TODO.md:1518–1543`, `[x]` item: "PDiv faithfulness-gap test deleted —
moot (no computed magnitude)"). The current model commits to NO arithmetic
value at all (§4 above), so there is no PDiv-specific gap left to describe
— reality-bridge.md's own prose has not been updated to reflect this,
though per the charter's docs-freeze policy this is noted here, not
patched in the frozen doc.

---

## Summary table: rule inventory × bridge coverage × header-claim status

| feature axis | `tm` constructors | `has_type` rules | `step` rules | header claims deferred? | empirically bridged (§5)? |
|---|---|---|---|---|---|
| structural core (lit/var/lam/app/let) | `tlit`,`tvar`,`tlam`,`tapp`,`tlet` | `TLit`,`TVar`,`TLam`,`TApp`,`TLet`,`TSub` | `SBeta`,`SLet`,congruences | no (claimed core) | yes |
| records | `trec`,`tproj` | `TRec`,`TProj` | `SProj`,`SRec` | no (claimed core) | yes |
| arithmetic/comparison | `tprim` | `TPrimArith`,`TPrimCmp` | `SPrim1/2`,`SPrimArith`,`SPrimCmpTrue/False` | not mentioned | yes (but abstract — no magnitude; see §5 staleness note) |
| conditionals | `tif` | `TIf` | `SIfTrue/False`,`SIf1` | yes (claimed deferred) — confirmed present | yes |
| flow-narrowing | `tifn`,`ttypetest` | `TIfn`,`TTypeTest` | `SIfnTrue/False/1`,`STtTrue/False/1` | yes (claimed deferred, as part of "statements/control flow") — confirmed present | **no** |
| recursion | `tfix` | `TFix` | `SFix` | yes — confirmed present | partial (bounded `twhile` encoding only) |
| references/mutation | `talloc`,`tderef`,`tassign`,`tloc` | `TLoc`,`TAlloc`,`TDeref`,`TAssign` | `SAlloc`,`SDeref`,`SAssign`+congruences | yes — confirmed present | yes |
| ascription | `tannot` | `TAnnot` | `SAnnot1`,`SAnnotV` | not mentioned | not in battery explicitly (used implicitly via `check.v`) |
| multi-return/vararg/multi-assign | `tret`,`tfst`,`tappspread`,`tvapp`,`tmassign` | `TRet`,`TFst`,`TFstNil`,`TAppSpread`,`TVApp`,`TMAssign` | `SRet`,`SFst*`,`SAppSpread*`,`SVApp*`,`SMAssign*` | yes — confirmed present | **no** |
| metatables/metamethods | `tmeta`,`tnewidx`,`tunop`,`trawget`,`trawset` | `TMeta`,`TCallMeta`,`TPrimMetaL/R`,`TNewIdx`,`TUnMetaL`,`TRawGet`,`TRawSet` | `SMeta*`,`SCallMeta`,`SPrimMetaL/R`,`SNewIdx*`,`SUnMetaL`,`SRawGet*`,`SRawSet*` | yes — confirmed present | **no** |
| unions (as value types) | (via `tif`/`tifn`/`ttypetest` results) | `BUnion` results throughout | — | yes (as term-formers; the type itself is pervasive) | yes (`ex_if`, not narrowing) |

---

## Independent re-derivation, 2026-08-09

A second full inventory pass was performed by a different session, reading
`proof/typing.v` + `subtype.v`/`ssub.v`/`check.v` headers, `docs/reality-
bridge.md`, and the `docs/decisions/typechecker-v10-*.md` set — **without
reading this document first** (the second pass was drafted, then this
document was discovered already at this path mid-task, at which point the
draft was not merged in directly; this section is the reconciliation record
instead). `TODO.md` was not read in the second pass. Recorded per the
owner's request as an agreement/discrepancy record, not a replacement.

**Independently confirmed** (both passes reached this via separate reading):
the "one file family" framing is accurate only at the `proof/` directory
level — `check.v` (checker-soundness) and `subtype.v` (semantic lattice)
are already clean, separately-headed, non-modified-dependency files, not
textually inside `typing.v`; `typing.v` itself does define its own second,
syntactic subtyping development (`ssub`/`rsub`) not reducible to either of
those two files, which is the real referent for design-sync's "(c)
subtype-lattice" claim; `progress`/`preservation` are genuine, `Qed`, no
`Admitted`/`Axiom`/`Classical`; the header's "DEFERRED" list (statements/
control flow, mutation, vararg/multi-return, recursion, metatables) is
stale — every named item is in fact present, typed, stepped, and proved;
roughly a third of the file (~31–32%) is worked-example/instantiation
content, not new metatheory; `ttypetest`'s `tag` enum is totalized over
every value kind at once rather than being cleanly per-layer (named
independently by both passes as an extraction fracture-line, under
different labels — "extraction debt" vs. "fracture-line"); flow-narrowing
(`tifn`/`ttypetest`), the entire metatable/metamethod machinery, and multi-
return/vararg/multi-assign are all fully formalized in `typing.v` but have
**zero** coverage in `docs/reality-bridge.md`'s 17-term execution battery —
the largest formalized-but-unbridged surface in both readings is the
metatable/metamethod example cluster.

**Discrepancies, listed as facts, not resolved:**

- **`ssub.v` line count.** This pass: 1592 (`wc -l`, re-checked). Existing
  report: 1579. Not re-reconciled here.
- **Boundary line numbers for `preservation`/`progress` and the example
  tail differ by a few lines** across the two passes (e.g. `preservation`
  end at 6013 vs. 6005; `progress` end at 6494 vs. 6489; example-tail start
  at 6495 vs. 6489) — likely a convention difference (next-declaration
  boundary vs. last-content line) but not confirmed.
- **Size and contiguity of the "syntactic subtyping inside `typing.v`"
  bucket disagree substantively, not just by a few lines.** This pass
  reported one ~3100-line span (typing.v:624–3721, ~33% of the file),
  including the canonical-forms lemmas (`canon_arrow` etc.) and the
  narrowing-soundness bridge lemmas (`truthy_narrows`/`falsy_narrows`/
  `tag_narrows`) as part of that bucket. The existing report instead treats
  `ssub`/`rsub` as **two non-contiguous ranges** totaling ~1450 lines
  (621–848 and 2505–3432) and places canonical forms + the narrowing-
  soundness lemmas in its op-sem-core block instead, explicitly excluding
  them from the `ssub`/`rsub` bucket. This is a real disagreement about
  where the extraction seam falls for lines ~3432–3721, not a rounding
  difference — needs reconciliation before either bucket size is treated as
  authoritative.
- **`rsub`'s provenance ("SPLIT-STEP 3").** The existing report states
  `rsub` was "promoted into `typing.v` from `ssub.v`" per a `typing.v:797–
  819` comment and a `TODO.md:1320–1349` cross-reference, and flags that
  backlog entry as stale (describes split-step 3 as "NEXT...DEFERRED" when
  it is already done). This pass did not read `TODO.md` and did not
  independently verify the promotion-history claim or the staleness
  finding — neither confirmed nor contradicted, just unchecked.
- **`PDiv`/arithmetic-value staleness — a substantive, not cosmetic,
  conflict.** This pass's subset-boundary section, following `docs/
  reality-bridge.md`'s own prose, reported `PDiv` as currently computing
  term-level integer division (`Nat.div`) at the value level, distinct from
  Lua's float `/` (the reality-bridge "sound but unfaithful" gap,
  unresolved). The existing report instead found, via direct reading of
  `typing.v:382–388`'s increment-19 `arith_op`/`cmp_op` comment and
  `bridge_exec_oracle.v`'s own in-file comment, that arithmetic currently
  has **no computed value at all** ("the former `prim_arith`/`prim_cmp`
  nat-level computation functions are REMOVED"), making the whole PDiv
  gap moot and `reality-bridge.md`'s own §5.4(I) text stale. This pass did
  not read `typing.v:382–388` directly and sourced the PDiv claim from
  `reality-bridge.md`'s prose alone — a likely sourcing error in this
  pass's draft, but recorded here as a conflict between the two documents'
  claims about current file content, not adjudicated.
- **Granularity/coverage of the "over-commitment" (extraction debt)
  findings differs, not just in framing.** This pass flagged two
  signature-level over-parameterization points not raised in the existing
  report: `step`'s very first constructor is already store-configuration-
  shaped (`tm * store`), so even pure congruence rules that touch no
  store carry an unused store parameter; `has_type` similarly threads an
  unconditional `Sig` store-typing context through rules that never use
  it. The existing report's fracture-line analysis (§2.2–2.3) instead
  documents rule-*content* entanglement not raised in this pass:
  `TNewIdx`/`TRawSet` require a writable field's *type* to be `BRef T`
  (tables and refs coupled at type-formation, not just reduction
  strategy — called "the sharpest fracture-line finding" there), and
  `TPrimMetaR` requires a scalar left-operand type specifically to keep
  metamethod dispatch step-disjoint. Both passes found real, distinct
  extraction-relevant findings the other did not surface; neither
  supersedes the other.

