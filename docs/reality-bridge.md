# Reality bridge — model ↔ real LuaJIT

> **Deferred / scoped-out / future items** from this bridge (and the proof dev)
> are consolidated into ONE authoritative backlog: `TODO.md` §"Proof-dev /
> type-system backlog (deferred items)". The forks and per-increment notes here
> stay, but that section is the single source of truth.

The Coq development (`proof/subtype.v`) proves everything *about* the type model:
subtyping is a Boolean algebra, the decider is sound, records/arrows have the
expected variance, etc. The one thing a proof **cannot** establish is
**faithfulness** — that the abstract value domain `V` and its `atom_denote`
actually correspond to how *real LuaJIT 5.1* classifies *real* values. That is an
empirical fact about an external artifact; it can only be *tested*, not proved.

This doc pins that correspondence and records the differential pipeline that
checks it. The first increment proved the pipeline **end-to-end on the
unambiguous fragment** (AStr/ABool/ANil) and enumerated the genuine design forks.
The second increment extended the bridge to the **number atoms** under the
decided **REFINE** policy (fork (A) RESOLVED), surfacing a value-domain sub-fork
(A′). **This (third) increment RESOLVES fork (A′): the value domain is collapsed
to ONE number value (a double) for LuaJIT 5.1, `int <: float` is now a proven
theorem, and the previously-recorded single disagreement (`AInt VFloat 3`) is
ELIMINATED — the number atoms `ANum`/`AInt`/`AFloat` bridge with FULL agreement
(0 disagreements). `AFloat` is no longer scoped out; it is the number type.**

Harness: `lib/sem/bridge/atom.lua` (the Lua port + correspondence), test
`lib/sem/bridge/atom_test.lua`. Reuses the `lib/sem` differential pattern: a
caps-injected `popen` cap shells the vendored interpreter; absent ⇒ skip, never
fail (bare-clone safe). Coq oracle for the number atoms reproduced via
`proof/bridge_num_oracle.v` (a scratch `.v`, not part of the build).

## 1. Value correspondence: `V` ↔ real Lua value

The proof's value domain (`proof/subtype.v`) — **collapsed to one number value
for LuaJIT 5.1**:

```
Inductive NumRep := NRint nat | NRfrac nat.   (* NRint = integer-valued double (3.0);
                                                 NRfrac = non-integer double (1.5) *)
Inductive V := VNum NumRep | VStr nat | VBool bool | VNil
             | VTable (list (string * V)) | VFun (list (V * V)).
(* VInt n := VNum (NRint n) ; VFloat n := VNum (NRfrac n)  — NOTATIONS, not
   distinct constructors: there is ONE number value per double. *)
```

Each constructor maps to a real Lua value:

| model `V`        | real Lua value                                   |
|------------------|--------------------------------------------------|
| `VStr s`         | a Lua **string**                                 |
| `VBool b`        | a Lua **boolean** (`true` / `false`)             |
| `VNil`           | **nil**                                          |
| `VTable [(k,v)…]`| a Lua **table** (finite string-keyed assoc)      |
| `VNum (NRint n)` (= `VInt n`)  | a Lua **number** — an **integer-valued** double (e.g. `3.0`, which `== 3`) |
| `VNum (NRfrac n)` (= `VFloat n`)| a Lua **number** — a **genuinely non-integer** double (e.g. `1.5`)        |
| `VFun graph`     | a Lua **function** realizing that finite I/O graph — see fork (B) |

**The value-domain collapse (fork A′ RESOLVED).** On LuaJIT 5.1 every number is
ONE IEEE double: `3 == 3.0`, an integer-valued number IS a float, and `type()`
returns `"number"` for both. So the model now has a **single number value**
`VNum`, with the `NRint`/`NRfrac` split recording (decidably) whether the double
is integer-valued. `VInt 3` and `VFloat 3` are no longer distinct values; `3.0`
is the single integer-valued number `VInt 3 = VNum (NRint 3)`. There is **no
model value whose real image is `3.0` yet is a non-integer** — so the old
`AInt (VFloat 3)` model-vs-reality disagreement cannot arise. Witnessed by the
harness: `EQ|number|number|3|3|INT` (3 and 3.0 are one double, integer-valued).
PUC 5.3/5.4's tagged-integer values (where `3` and `3.0` are distinct siblings)
are the **version-parametric DEFERRED** design, not the 5.1 model here.

(The proof carries `nat`/`bool` *payloads*; membership is **class-determined** —
`denote_head` in the proof — depending only on the value's classification head
(`VStr`/`VBool`/`VNil`/`VTable`/`VFun`) and, for numbers, the `NRint`/`NRfrac`
class, never on the `nat` inside. The bridge port renders payloads only to
produce a concrete real value to hand the interpreter; for `VFloat` it forces a
fractional part so the real image is a genuine non-integer, faithful to the
`NRfrac` class.)

## 2. Atom membership correspondence: `atom_denote` ↔ a real-Lua predicate

The proof's `atom_denote a v` is a value-set membership predicate. Its real-Lua
counterpart is a classification test on a bound name `x`:

| atom    | model `atom_denote`            | real-Lua membership predicate          |
|---------|--------------------------------|----------------------------------------|
| `AStr`  | `VStr _`                       | `type(x) == "string"`                  |
| `ABool` | `VBool _`                      | `type(x) == "boolean"`                 |
| `ANil`  | `VNil`                         | `x == nil` (equivalently `type(x)=="nil"`) |
| `ANum`  | `VNum _` (all numbers)         | `type(x) == "number"`                  |
| `AFloat`| `VNum _` (all numbers; ≡ `ANum`)| `type(x) == "number"` (float ≡ number on 5.1) |
| `AInt`  | `VNum (NRint _)`  (⊂ `ANum`)   | `type(x)=="number" and x==math.floor(x) and x==x and x~=±inf` (integer-valued + finite) |

`AStr`, `ABool`, `ANil` are the **unambiguous** atoms (fork-independent). `ANum`,
`AInt`, and `AFloat` are the number atoms on the 5.1 single-double model. Bridged
atoms: **AStr, ABool, ANil, ANum, AInt, AFloat** (`lib/sem/bridge/atom.lua`
`M.atoms`). `M.unobservable_atoms` is now **empty** — nothing is scoped out.

### AFloat IS bridged on LuaJIT 5.1 (= the number type; `int <: float`)

With the value domain collapsed to one double, `atom_denote AFloat` accepts
**every** number (float ≡ number on 5.1), exactly like `ANum`. So `AFloat` is
fully observable (`type(x) == "number"`) and is bridged. The proof carries the
genuine theorems `AInt_sub_AFloat : dsub (BAtom AInt) (BAtom AFloat)` and
`AInt_sub_ANum`, plus `AFloat_equiv_ANum` (float and number denote the same set)
and `not_float_sub_int` (a non-integer number inhabits `AFloat` but not `AInt`,
so the `int <: float` edge is non-trivial). There is **no int/float
disjointness** anywhere in the model.

### The int/float refinement is NOT a runtime tag (critical)

LuaJIT 5.1's `type()` returns `"number"` for **both** integer-valued and
non-integer numbers — there is **no runtime int/float tag** (unlike PUC Lua
5.3/5.4, which expose `math.type`). So the model's `AInt <: ANum` is a **refined
type distinction** — "integer-valued number as a subtype of number", exactly like
the slice's `integer <: number` — **not** a value the runtime can observe by a
tag check. The *intended* membership test for `AInt`, if the refinement is kept,
is:

```lua
type(x) == "number" and x == math.floor(x) and x == x       -- finite, integral
                                                            -- (and not ±inf/nan)
```

Whether the model **should** track this refinement at all was fork (A); it is now
**RESOLVED = REFINE** (keep `AInt <: ANum` at the type level). The value-domain
sub-fork (A′) that REFINE left open is now **RESOLVED = collapse to one double**
(see fork (A′) below): the value layer has a single number value, so `AInt`,
`ANum`, and `AFloat` all bridge with full agreement.

## 3. The differential pipeline

Legs in `lib/sem/bridge/atom_test.lua` (now covering the 6 bridged atoms):

1. **Coq-oracle validation.** A baked-in table of `(atom, value) → verdict`, each
   verdict the verbatim result of `Compute (memb (BAtom a) v)` on the **proven**
   model (`memb t v := if denote_dec t v then true else false`). The Lua port
   `model_denote_atom` is asserted to agree with every Coq verdict — making the
   port a trustworthy proxy for the proven model. The transcript:

   ```
   (* memb (BAtom AStr)  (VStr 0)     *) = true
   (* memb (BAtom AStr)  (VInt 7)     *) = false
   (* memb (BAtom AStr)  (VBool true) *) = false
   (* memb (BAtom AStr)  VNil         *) = false
   (* memb (BAtom ABool) (VBool true) *) = true
   (* memb (BAtom ABool) (VBool false)*) = true
   (* memb (BAtom ABool) (VStr 0)     *) = false
   (* memb (BAtom ABool) (VInt 0)     *) = false
   (* memb (BAtom ANil)  VNil         *) = true
   (* memb (BAtom ANil)  (VStr 0)     *) = false
   (* memb (BAtom ANil)  (VBool false)*) = false
   (* memb (BAtom ANil)  (VFloat 3)   *) = false
   ```
   The number-atom rows (`proof/bridge_num_oracle.v`) — note `AFloat` accepts ALL
   numbers (`int IS a float`) and `AInt (VFloat 3) = false` now agrees with
   reality (`VFloat 3` is a genuine non-integer double):
   ```
   (* memb (BAtom ANum)   (VInt 3)   *) = true    (* memb (BAtom AFloat) (VInt 3)   *) = true
   (* memb (BAtom ANum)   (VFloat 3) *) = true    (* memb (BAtom AFloat) (VFloat 3) *) = true
   (* memb (BAtom ANum)   (VInt 0)   *) = true    (* memb (BAtom AFloat) (VInt 0)   *) = true
   (* memb (BAtom ANum)   (VStr 0)   *) = false   (* memb (BAtom AFloat) (VStr 0)   *) = false
   (* memb (BAtom AInt)   (VInt 3)   *) = true    (* memb (BAtom AInt)   (VFloat 3) *) = false  (model AND real)
   (* memb (BAtom AInt)   (VInt 0)   *) = true    (* memb (BAtom AInt)   (VFloat 0) *) = false
   ```
   (reproduce: `nix develop -c coqc proof/subtype.v && nix develop -c coqc
   proof/bridge_num_oracle.v`.)

2. **Coq-oracle vs real LuaJIT.** Each oracle row's value is rendered to a real
   Lua expression, classified by the vendored interpreter, and compared to the
   model (= proven) verdict. On the 5.1 single-double model **every row agrees** —
   the previously-recorded `AInt VFloat 3` disagreement is gone: `VFloat 3` now
   renders to a genuine non-integer real, which both the model and reality reject
   for `AInt`. The test asserts **zero** disagreements.

2b. **3-vs-3.0 witness.** Builds the integer literal `3` (the image of the single
   integer-valued number `VInt 3`) and the float literal `3.0`, and checks they
   are `==`, both `type=="number"`, AND that `3.0` is integer-valued — pinning the
   collapse + `int <: float` concretely (`EQ|number|number|3|3|INT`).

3. **Generated differential.** 100 random model values across **all** heads ×
   the 6 bridged atoms ⇒ 600 classifications; each asserts the port verdict
   equals real LuaJIT's predicate. The renderer forces non-integer reals for the
   `VFloat`/`NRfrac` head, so model and reality agree on every generated value.

3b. **Real-value REFINE differential.** 12 real numbers (0, 3, -7, 1.5, 2.25,
   -0.0, 3.0, ±inf, nan, 2^53, 2^53+0.5) × {ANum, AInt} ⇒ 24 classifications;
   the host-side classifier (`real_refine_class`) is checked against the shelled
   real predicate, validating the integral predicate on edge cases the
   model-value generator can't express (inf/nan/-0.0/large).

### Measured agreement (this increment — fork A′ resolved)

```
[bridge] Coq-oracle:            28/28   port verdicts match the proven model
[bridge] oracle vs real LuaJIT: 28/28   agree; 0 disagreement(s)
[bridge] witness 3 vs 3.0:      EQ|number|number|3|3|INT
[bridge] differential:         600/600 agree (100 values x 6 atoms)
[bridge] real-value REFINE:     24/24  agree (12 numbers x 2 atoms)
```

All number atoms — `ANum`, `AInt`, **and `AFloat`** — correspond with **zero**
disagreement. The value-domain collapse to one double eliminated the single
`AInt (VFloat 3)` mismatch the two-number-value model exposed.

## 4. Design forks — status

### (A) Number atoms — int/float refinement  *(RESOLVED = REFINE)*

**Decision (fixed): REFINE.** The type system tracks `AInt <: ANum` (integer-
valued number as a subtype) — matching the slice's `integer <: number` and PUC
5.3/5.4's real `math.type` tag — even though LuaJIT 5.1's `type()` returns
`"number"` for both and has no runtime int/float tag. On 5.1, `AInt`-membership
is a **derived predicate**: `type(x)=="number" and x==math.floor(x) and x==x and
x~=±inf` (integer-valued + finite). This is bridged (`ANum`, `AInt` in
`M.atoms`); the reality bridge for `AInt` tests a value-shape refinement, not a
tag. FFI cdata integers (`int64_t`/`uint64_t` boxes, where `type()=="cdata"`) are
a **separate deferred axis** — a different runtime representation, not part of
this REFINE decision.

#### (A′) Value-domain sub-fork — two number values vs one double  *(RESOLVED = collapse to one double)*

**Decision (fixed): collapse to ONE number value for LuaJIT 5.1.** The proof's
`V` previously had **distinct** `VInt n` / `VFloat n` constructors — faithful to
PUC 5.3/5.4 (which tag integers) but **not** to LuaJIT 5.1, where every number is
a single double. That two-value design produced exactly one model-vs-reality
disagreement (`AInt (VFloat 3)`: model said `VFloat 3 ∉ AInt`, but its real image
`3.0` is integral). **`proof/subtype.v` now collapses the number domain to one
value** `VNum : NumRep -> V`, with `NumRep := NRint nat | NRfrac nat` recording
(decidably) integer-valued-ness. `VInt n`/`VFloat n` survive only as NOTATIONS.
The three number atoms then denote:

- **`ANum`** = all numbers (`VNum _`; `type=="number"`).
- **`AFloat`** = all numbers too (option (i): float ≡ number, since every 5.1
  number *is* a double). So **`AInt <: AFloat`** and `AFloat ≡ ANum` — both
  proven (`AInt_sub_AFloat`, `AFloat_equiv_ANum`). `AFloat` is observable and
  bridged; it carries no information beyond `ANum`, which is the honest 5.1 truth.
- **`AInt`** = the integer-valued doubles (`VNum (NRint _)`; `x==floor(x)`,
  finite) — a genuine non-trivial subset (`not_float_sub_int` witnesses a
  non-integer in `AFloat \ AInt`).

The collapse makes `int <: float` a real theorem and **eliminates the
disagreement**: there is no model value whose real image is `3.0` yet is a
non-integer (the single value for `3.0` is the integer-valued `VInt 3`). The
bridge re-validation is **fully green** (0 disagreements; `AFloat` bridged).

> **Concrete witness (now).** `3` (image of `VInt 3`) and `3.0` are `==`, both
> `type()=="number"`, and `3.0` is integer-valued (`b == math.floor(b)`): the
> harness prints `EQ|number|number|3|3|INT`. One double, integer-valued, a float.

The option-(ii) reading (`AFloat` = non-integer numbers, partitioning `ANum`) was
NOT taken: on 5.1 "float" means the runtime representation (every number is a
double), so the faithful `AFloat` is all-numbers, not the complement of `AInt`.

The `lib/sem` harness still makes the int/float split observable *across versions*
(`4/2` → `2.0` on 5.3/5.4 vs `2` on 5.1) — the refinement is real *somewhere*,
just not in 5.1's `type()`. **Version-parametric distinct-integer-siblings
(5.3/5.4) are DEFERRED**: a future increment can parameterize `V` by Lua version,
giving 5.3/5.4 a genuinely distinct integer value alongside the float. The 5.1
target is now faithful with the single-double collapse.

### (B) Functions / closures — RESOLVED = bridged via operational I/O check

The model's `VFun` is an **extensional finite I/O graph** (`list (V*V)`). A real
Lua closure cannot be introspected for its graph — but it does **not** need to be.
The model's `VFun g` is finite and **known**: the bridge constructs a real Lua
function realizing exactly that graph (a dispatch over the listed inputs) and
checks application **agrees** with the graph — `f(i) == o` for each `(i,o) ∈ g`,
and arrow membership `denote (BArrow A B) (VFun g)` reduces to
`∀(i,o)∈g. denote A i → denote B o`, every conjunct decidable and finite. So this
is an **operational I/O check**, fully bridgeable, NOT an unbridgeable limit.

The *only* thing not bridgeable is membership of an **arbitrary externally-given
opaque closure** (whose graph is unknown) — but the model never produces such a
value; `VFun` is always an explicit graph. Sampling-can-only-refute applies to
opaque closures, which are outside the model's value domain.

**This increment RESOLVES fork (B): functions ARE bridged via the operational
I/O check.** Harness: `lib/sem/bridge/fun.lua` (graph→real-function construction +
the model-side ports), test `lib/sem/bridge/fun_test.lua`. Coq oracle for arrow
membership reproduced via `proof/bridge_arrow_oracle.v` (a scratch `.v`, not part
of the build).

**The graph → real-Lua-function construction.** `fun.graph_to_lua_function_expr`
emits the source of a real `function(x) … end` that dispatches `x` against each
graph input's real image (an if/elif chain comparing with `==`, the scalar value
equality), returning the matching output's real image; an argument outside the
listed inputs `error`s (the model graph is the full extension, the operational leg
never probes outside it).

**The two legs (`fun_test.lua`):**

1. **(operational) application = graph lookup.** For each `(i,o) ∈ g`, the built
   real function is applied to `i`'s real image and the result compared `==` to
   `o`'s real image, *in real LuaJIT*. This validates that real Lua's
   function-call semantics matches the model's graph-lookup denotation — the core
   "input→output is enough" check. Measured: oracle graphs 9/9; random graphs
   120/120 (counts vary with the seed).

2. **(membership) arrow type verdict.** The model says `VFun g ∈ (A→B)` iff
   `∀(i,o)∈g, i∈A → o∈B`. `fun.model_arrow_verdict` ports `denote_dec (BArrow A B)
   (VFun g)` on the finite graph (per-pair decidable implication, folded with
   conjunction). The REAL verdict evaluates, per pair, `real(i)∈A → real(o)∈B`
   using the atom bridge's real atom predicates (`atom.atom_real_predicate`,
   textually rebound to the input/output names). The two are asserted to AGREE.
   Measured: oracle rows 8/8 (0 disagreements); random graphs × random scalar
   arrow types 60/60.

**Coq validation of the model side.** `proof/bridge_arrow_oracle.v` `Compute`s
`memb (BArrow A B) (VFun g)` for 8 concrete cases — **member** (empty graph
vacuous; `Int→Int [(1,2),(3,4)]`; `Int→Int` with a non-int input that is
vacuously satisfied; `Str→Bool`; `Num→Num` with `AInt <: ANum`) and **non-member**
(`Int→Int [(1,"s")]` — int input → str output; `Int→Int` int → non-integer;
`Str→Bool` str → int output). The Lua `model_arrow_verdict` is asserted equal to
every Coq verdict (8/8), so the bridge faithfully reflects the proven model.

**Deferred (recorded in `TODO.md` proof-dev backlog):** SCALAR graphs only this
increment. **Higher-order graphs** (a function value appearing as a graph input or
output) and **table-valued graph entries** are deferred — they need the table
bridge (fork C) and a recursive real-image/equality story for compound values.
`reality-bridge.md` Status below.

### (C) Tables — open/closed, key types, finite-assoc vs real semantics  *(RESOLVED for the string-keyed scalar fragment)*

**This increment RESOLVES fork (C) for the string-keyed-scalar-record fragment:
record membership is bridged and open/width is confirmed against real Lua
tables.** Harness: `lib/sem/bridge/rec.lua` (the model `VTable`→real-table
correspondence + the membership ports), test `lib/sem/bridge/rec_test.lua`. Coq
oracle for record membership reproduced via `proof/bridge_rec_oracle.v` (a scratch
`.v`, not part of the build).

**The correspondence.** The model `VTable [(k1,v1);…]` maps to the real Lua table
`{ [k1] = real_image(v1), … }` — string-literal keys, scalar field values
(number/string/bool) rendered by the atom bridge's renderer.
`rec.table_to_lua_expr` emits the constructor source.

**The membership leg.** The model says `VTable t ∈ BRec fields` iff `t` is a
table AND for every `(k,T)∈fields` there is an entry at `k` whose value `∈ T`
(extra keys allowed = OPEN/width). `rec.model_rec_verdict` ports `denote_dec
(BRec fields) (VTable t)` (per-field `assoc_lookup` + recursive scalar atom
membership, folded with conjunction). The REAL verdict builds the real table and
checks, per field, `real_table[k] ~= nil and (real_table[k] ∈ T via the atom
oracle)`. The two are asserted to AGREE. Measured: oracle rows 7/7 (0
disagreements); random tables × random record types 80/80.

**Coq validation of the model side.** `proof/bridge_rec_oracle.v` `Compute`s
`memb (BRec fields) (VTable t)` for 9 concrete cases — **member** (empty record
`{}` ∋ every table; exact `{x:Int}`; exact `{x:Int,y:Str}`; **EXTRA field present**
`{x:Int} ∋ {x=3,z=true}` confirming OPEN/width; **field order irrelevant**
`{x:Int,y:Str} ∋ {y="s",x=3}`) and **non-member** (missing field; wrong field
type `{x:Int} ∌ {x="s"}`; a SCALAR value is not a record — `VInt 3`/`VStr 0`).
The Lua `model_rec_verdict` is asserted equal to every member/non-member Coq
verdict (7/7 over the VTable-domain rows), so the bridge faithfully reflects the
proven model.

**Deferred (recorded in `TODO.md` proof-dev backlog):** STRING keys + SCALAR
field VALUES only this increment. **Nested records** (table-valued fields),
**function-valued fields**, **non-string keys**, **array part**, **metatables**,
**iteration order**, and **`nil`-valued fields** (which collapse to "absent key"
in real Lua — a nil-hole axis) are deferred — they need a recursive
real-image/membership story for compound field values and a key-type/array
decision. The richer table behaviors below stay open.

The richness axes below (any-key, array part, metatables, nil-holes,
iteration-order) remain the open part of fork (C):



- **Open vs closed.** The model's `BRec` reads **open/width** (extra keys
  allowed). Real Lua tables are always "open" in that sense; a *closed/exact*
  record has no direct runtime counterpart (would need a "no other keys" check by
  enumeration). The model already defers closed/exact records.
- **Key types.** The model's `VTable` uses **string keys**; real Lua keys are
  **any non-nil value** (numbers, booleans, tables, functions as keys). The
  string-key restriction is a model simplification, not a faithful image of Lua
  tables.
- **Finite-assoc vs real-table semantics.** The model is a finite assoc-list;
  real tables have array/hash parts, `nil`-hole semantics, metatables, and
  iteration-order non-determinism. Whether `VTable`'s finite-assoc denotation
  matches real-table membership (and which real behaviors are admissibly
  *unobserved*, as `lib/sem/diff/observe.lua` already does for table identity)
  is an open question.

**Scoped:** the bridge targets **string-keyed records** (the model's current
`VTable`/`BRec` reading) with the richness above (non-string keys, closed/exact,
metatables, nil-holes) tracked as known unobserved/deferred axes. Bridging beyond
string-keyed records requires deciding key-type scope and the
open/closed/index-signature reading first.

## 5. Operational / execution axis — well-typed term ⇒ real result inhabits its inferred type

Forks (A)–(C) above bridge the **value-membership** axis: a model *value*
inhabits a model *type*, faithfully against real LuaJIT. They say nothing about
**reduction**. This section adds the **operational axis** — the checker's
soundness claim against reality:

> a **well-typed term**, executed on **real LuaJIT**, produces a value that
> **inhabits its inferred type** (`synth [] term`).

This is the operational/reduction counterpart of progress + preservation
(proved syntactically in `proof/typing.v`): the proofs guarantee a well-typed
term doesn't get stuck and keeps its type as it steps; this bridge checks that
the *real interpreter's* result for that term lands inside the *inferred* type —
empirically, against the external artifact the proofs cannot reach.

Harness: `lib/sem/bridge/exec.lua` (the term→Lua translator + inferred-type
model) and `exec_test.lua` (the battery + the result-inhabits-type assertion).
Inferred types are pinned from `proof/bridge_exec_oracle.v`
(`Compute (synth [] term)`, a scratch `.v`, not part of the build). Caps-first:
the real interpreter is the popen-injected vendored LuaJIT; absent ⇒ skip
(bare-clone safe). **REUSES the value-membership bridge**: inhabitance is decided
with `atom.lua`'s real atom predicates (`atom_real_predicate`, textually rebound
from `x` to the result access), records via a per-field open/width conjunction
(the same shape as `rec.lua`'s field predicate), a reference cell `{v=…}` by
recursing into `.v`.

### 5.1 The term → real-Lua translator (`exec.term_to_lua`)

The proof's `tm` is ported as tagged tables (`exec.lua` constructors). The
translator carries a **de Bruijn name stack** (innermost last; `tvar i` reads
`stack[#stack - i]`), emitting a self-contained Lua **expression** per term so
terms compose by nesting. Lua lacks expression-`if`, `let`, and references, so:

| proof term | Lua image |
|------------|-----------|
| `tlit (LInt n)` | `n` |
| `tlit (LBool b)` | `true` / `false` |
| `tlit LNil` | `nil` |
| `tprim PAdd a b` … | `((a) + (b))`, `-`, `*`, `/`, `<`, `<=`, `==` |
| `tlam body` / `tapp f a` | `(function(v) return (body) end)` / `((f)(a))` |
| `tlet e1 e2` | `(function() local v = (e1); return (e2) end)()` |
| `trec [(k,e)…]` | `{ ["k"] = (e), … }` |
| `tproj e k` | `((e)["k"])` |
| `tif c a b` | `(function() if (c) then return (a) else return (b) end end)()` |
| `talloc e` | `{ v = (e) }` — a **single-field mutable cell** (Lua has no refs) |
| `tderef r` | `((r).v)` |
| `tassign r v` | `(function() local _r=(r); _r.v=(v); return nil end)()` (yields `nil` = unit) |
| `tseq a b` | `(function() local _=(a); return (b) end)()` (mirrors `tseq := tlet a (lift 1 0 b)`) |
| `twhile c body` | `(function() while (c) do local _=(body) end return nil end)()` |

**`tif` wrapping.** Lua has no `if`-expression, so `tif` becomes an IIFE whose
`if`-statement returns the selected branch. Lua's `if` already tests
truthiness, which matches the proof's value-conditioned `tif` (a `Bool`
condition here). **References as cells.** Lua has no reference type; a `talloc`
is a fresh one-field table `{v=…}`, `tderef` reads `.v`, `tassign` writes `.v`
and yields `nil` (the proof's unit value). A cell value inhabits `BRef T` iff it
is a table whose `.v` inhabits `T` — exactly how the inhabitance predicate
recurses. **`twhile`** is translated as a real `while` loop (the
finite-execution image of the proof's `tfix`-unfold encoding) — same operational
behaviour for terminating loops, which is the bridge's scope.

### 5.2 The result-inhabits-type assertion (reusing the value bridge)

For each battery term: translate it, then emit one chunk that (a) binds the
result `__r = (translated term)` and (b) evaluates a Lua boolean
`inhabit_expr(inferred_type, "__r")` — the **value-membership** predicate for the
inferred type, built from the SAME real predicates the atom/rec bridges use
(atoms via `atom_real_predicate`, a union via `or`, a record via per-field
`real[k] ~= nil and (real[k] ∈ T)`, a ref via `type(__r)=="table" and (__r.v ∈
inner)`). The chunk prints `INHABITS`/`OUTSIDE` + the result shape. So
inhabitance is decided **in real LuaJIT on the real result**, by the proven
value model's real-side counterpart — this is checker-soundness-against-reality,
not a re-derivation in Lua.

### 5.3 The battery + agreement

17 representative well-typed programs (term + its `synth`'d type, verbatim from
`bridge_exec_oracle.v`): `3+4 : ANum`, `10-4 : ANum`, `6*7 : ANum`, `3<4 : Bool`,
`5<=5 : Bool`, `4==4 : Bool`, `if 3<4 then 1 else 0 : AInt∪AInt`, `let x=6+1 in
x*2 : ANum`, `{x=3+4,y=5} : {x:ANum,y:AInt}`, `{x=3+4,y=5}.x : ANum`,
`!(ref(2+3)) : ANum`, `ref(2+3) : BRef ANum`, `let r=ref 0 in (r:=9 ; !r) : AInt`,
`(\x. x+1) 5 : ANum`, the counting `while`-loop
`let i=ref(0+0) in (while !i<3 do i:=!i+1 end ; !i) : ANum`, `nil : ANil`,
`true : ABool`.

```
[bridge] exec translator:       17/17 battery terms translated
[bridge] result-inhabits-type:  17/17 well-typed programs executed to a value INHABITING their inferred type
[bridge] PDiv FAITHFULNESS GAP: proof Nat.div 7/2 = 3  vs  real Lua 7/2 = 3.5  (both inhabit ANum; the VALUE disagrees)
```

**17/17** well-typed programs executed on real LuaJIT to a value inhabiting their
inferred type — the checker's soundness claim holds against reality across the
computational fragment.

### 5.4 Surfaced gaps (the bridge's job)

**(I) `PDiv` faithfulness gap — sound but unfaithful.** The proof's `PDiv` is
`Nat.div` (INTEGER division: `prim_arith PDiv 7 2 = 3`); real Lua `/` is FLOAT
division (`7/2 = 3.5`). **Both `3` and `3.5` inhabit the inferred type `ANum`**,
so the result-inhabits-type assertion HOLDS for a division term — *soundness is
preserved*. But the **values disagree**: the proof computes `3`, reality `3.5`.
This is a **sound-but-unfaithful** model choice — the proof's `PDiv` semantics
(integer division) is not Lua's `/` (float division). The bridge surfaces this
with the concrete witness `3 vs 3.5`. **Recommendation:** either (a) **drop
`PDiv`** from the *faithful* computational subset (keep it as a sound arithmetic
op whose value is unfaithful, documented), or (b) **add a fractional number
literal + faithful float division** — the value side already has `NRfrac`/
`VFloat` (a genuinely non-integer double), so a `PDiv` that produces an `NRfrac`
result matching Lua's `/` is expressible; only the term-level `prim_arith` choice
(`Nat.div`) is the unfaithful part. (Lua's integer division is `//`, which the
proof does not yet have — see the `primop` backlog note in `typing.v`: floor-div
`//` is deferred. So the faithful mapping is `PDiv ↦ //` once `//` exists, with
`/ ↦` a future float-div op.)

**(II) synth-vs-declarative gap at an invariant `BRef` allocation.** The proof's
full sum-loop `sumloop_prog n` is **declaratively** typed at `ANum`
(`sumloop_prog_typed`), using `TSub` to widen the `AInt` initialiser (`LInt 0`)
to a `Num` cell at allocation. But the **algorithmic** `synth` **rejects** it
(`synth [] (sumloop_prog 5) = None`): it allocates `BRef AInt` from `LInt 0 :
AInt`, and then cannot store the `ANum` arithmetic result (`!s + !i`) back into
the **invariant** cell. This is a **completeness** gap of bidirectional inference
vs the declarative system (not a soundness gap — everything `synth` accepts is
still sound). The battery therefore uses a **synth-acceptable** counter loop
(`local i = ref (0+0)`, so the initialiser's type is the arithmetic result `ANum`
and the cell synthesizes `BRef ANum`). Recorded in `TODO.md`; closing it needs an
expected-type-propagating `talloc` or a widening pass at allocation. No other
disagreements were found across the battery.

### 5.5 Scope (honest)

The bridge validates the **finite-execution fragment**: terminating closed terms
that reduce to a value — literals, arithmetic/comparison primops, conditional,
let, record + projection, references (alloc/deref/assign), a terminating
`while`-loop, and function application. **Out of scope** (noted, not hidden):
flow-narrowing terms (`tifn` / `ttypetest`) and higher-order / divergent
programs are not executed; `tfix` is exercised only through the terminating
`twhile` encoding, not as open-ended recursion. These are deferred in `TODO.md`.

## Status

- **Done (increment 1):** unambiguous atoms AStr/ABool/ANil — port validated
  against Coq `Compute` (12/12), differential green (300/300), no disagreement.
- **Done (increment 2):** number atoms under REFINE. Port for `ANum`/`AInt`
  validated against the Coq oracle; the **one** model-vs-reality disagreement
  (`AInt (VFloat 3)`) surfaced and asserted-as-the-only-one; `AFloat` scoped out
  (then unobservable under the two-number-value model).
- **Done (increment 3, this one): fork (A′) RESOLVED = collapse to one double.**
  `proof/subtype.v` collapses the number value domain to one `VNum (NumRep)` for
  LuaJIT 5.1; `int <: float` is a proven theorem (`AInt_sub_AFloat`,
  `AInt_sub_ANum`, `AFloat_equiv_ANum`). The `AInt (VFloat 3)` disagreement is
  **eliminated**. `AFloat` is now bridged (= the number type). Bridge fully
  green: Coq-oracle 28/28, oracle vs real LuaJIT **28/28 (0 disagreements)**,
  generated 600/600, real-value REFINE 24/24. The whole Coq dev compiles, all
  `Qed`, `Print Assumptions` closed under the global context.
- **Done (increment 4, this one): fork (B) RESOLVED = functions bridged.**
  `lib/sem/bridge/fun.lua` constructs a real Lua function from a model `VFun`
  graph; `fun_test.lua` runs the two legs — **operational** (`real_f(real(i)) ==
  real(o)` for each `(i,o)∈g`) and **membership** (model `denote_dec (BArrow A B)
  (VFun g)` port vs the real-computed `∀(i,o)∈g. real(i)∈A → real(o)∈B`). Both
  agree (oracle: operational 9/9, membership 8/8 with 0 disagreements; random:
  operational + membership all-agree). The model side is validated against
  `proof/bridge_arrow_oracle.v` `Compute` for 8 concrete (arrow, graph) cases —
  member AND non-member (incl. the headline `Int→Int [(1,"s")]` = false). SCALAR
  graphs only; higher-order + table-in-graph deferred.
- **Done (increment 5, this one): fork (C) RESOLVED for the string-keyed-scalar-
  record fragment.** `lib/sem/bridge/rec.lua` maps a model `VTable` to a real Lua
  table `{ [k]=real_image(v), … }`; `rec_test.lua` runs the membership leg — model
  `denote_dec (BRec fields) (VTable t)` port vs the real-computed open/width
  verdict (per field `real_table[k] ~= nil and real_table[k] ∈ T`). They AGREE
  (oracle rows 7/7, 0 disagreements; random tables × record types 80/80).
  **Open/width confirmed against real tables**: extra keys present ⇒ still a
  member, on BOTH the model and reality. Model side validated against
  `proof/bridge_rec_oracle.v` `Compute` for 9 concrete cases — member (incl.
  extra-fields/open + field-order-irrelevant) AND non-member (missing field; wrong
  field type; a scalar is not a record). STRING-keyed SCALAR records only; nested/
  function-valued fields, non-string keys, array part, metatables, iteration order,
  nil-valued fields deferred (TODO.md proof-dev backlog).
- **Done (increment 6, this one): OPERATIONAL / EXECUTION axis bridged.** The
  prior increments bridge the value-membership axis; this one bridges the
  REDUCTION axis — a WELL-TYPED term, executed on REAL LuaJIT, produces a value
  INHABITING its inferred type (`synth [] term`), the checker's
  soundness-against-reality (§5). `lib/sem/bridge/exec.lua` ports the proof's `tm`
  and translates closed terms to runnable Lua (de Bruijn → fresh-name stack; refs
  → single-field cells `{v=…}`; `tif`/`tlet`/`tseq`/`tassign` → IIFEs; `twhile` →
  a real `while` loop; primops → Lua binops). `exec_test.lua` runs a **17-term**
  battery and asserts each real result inhabits its inferred type, REUSING the
  atom bridge's real predicates (records via per-field open/width, refs via `.v`).
  **17/17 inhabit** their inferred type. Inferred types pinned from
  `proof/bridge_exec_oracle.v` `Compute (synth [] term)`. **Surfaced gaps:** (I)
  the **`PDiv` faithfulness gap** — proof `Nat.div` (`7/2=3`) vs real float `/`
  (`7/2=3.5`); both inhabit `ANum` (soundness preserved) but the VALUES disagree
  (sound-but-unfaithful; recommend drop `PDiv` from the faithful subset or add
  fractional-literal float division — `NRfrac`/`VFloat` already exist); (II) a
  **synth-vs-declarative completeness gap** — `synth` rejects `sumloop_prog`
  (allocates `BRef AInt`, can't store `ANum` back into the invariant cell) though
  it is declaratively `ANum`; the battery uses a synth-acceptable `ref (0+0)`
  counter loop. No other disagreements. SCOPE: the finite-execution fragment
  (terminating terms to a value); `tifn`/`ttypetest` + higher-order/divergent
  programs out of scope (TODO.md).
- **Resolved:** fork (A) = **REFINE** (type-level `AInt <: ANum`); fork (A′) =
  **collapse to one double** (`int <: float`); fork (B) = **functions bridged via
  the operational I/O check** (scalar graphs); fork (C) = **string-keyed scalar
  records bridged via open/width membership against real tables**.
- **Deferred:** version-parametric 5.3/5.4 distinct-integer-sibling values (a
  future version-parameterized `V`); FFI cdata integers (`type()=="cdata"`) — a
  separate runtime-representation axis. **Higher-order graphs** (functions inside a
  `VFun` graph) and **table-valued graph entries** — the function bridge's scalar
  restriction (TODO.md proof-dev backlog).
- **Scoped:** fork (C) tables — string-keyed SCALAR records BRIDGED (this
  increment); richer behaviors (nested/function-valued fields, non-string keys,
  array part, metatables, nil-holes, iteration order) tracked as deferred.
