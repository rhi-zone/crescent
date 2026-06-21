# Reality bridge — model ↔ real LuaJIT

The Coq development (`proof/subtype.v`) proves everything *about* the type model:
subtyping is a Boolean algebra, the decider is sound, records/arrows have the
expected variance, etc. The one thing a proof **cannot** establish is
**faithfulness** — that the abstract value domain `V` and its `atom_denote`
actually correspond to how *real LuaJIT 5.1* classifies *real* values. That is an
empirical fact about an external artifact; it can only be *tested*, not proved.

This doc pins that correspondence and records the differential pipeline that
checks it. The first increment proved the pipeline **end-to-end on the
unambiguous fragment** (AStr/ABool/ANil) and enumerated the genuine design forks.
This (second) increment extends the bridge to the **number atoms** under the
decided **REFINE** policy (fork (A) RESOLVED), surfacing a NEW value-domain
sub-fork it does not silently resolve.

Harness: `lib/sem/bridge/atom.lua` (the Lua port + correspondence), test
`lib/sem/bridge/atom_test.lua`. Reuses the `lib/sem` differential pattern: a
caps-injected `popen` cap shells the vendored interpreter; absent ⇒ skip, never
fail (bare-clone safe). Coq oracle for the number atoms reproduced via
`proof/bridge_num_oracle.v` (a scratch `.v`, not part of the build).

## 1. Value correspondence: `V` ↔ real Lua value

The proof's value domain (`proof/subtype.v`):

```
Inductive V := VInt nat | VFloat nat | VStr nat | VBool bool | VNil
             | VTable (list (string * V)) | VFun (list (V * V)).
```

Each constructor maps to a real Lua value:

| model `V`        | real Lua value                                   |
|------------------|--------------------------------------------------|
| `VStr s`         | a Lua **string**                                 |
| `VBool b`        | a Lua **boolean** (`true` / `false`)             |
| `VNil`           | **nil**                                          |
| `VTable [(k,v)…]`| a Lua **table** (finite string-keyed assoc)      |
| `VInt n`         | a Lua **number** (the double `n`) — see fork (A) + sub-fork |
| `VFloat n`       | a Lua **number** (the double `n`) — **same value as `VInt n`** on 5.1; see sub-fork |
| `VFun graph`     | a Lua **function** realizing that finite I/O graph — see fork (B) |

**Critical (the value-domain sub-fork, surfaced this increment):** `VInt n` and
`VFloat n` are DISTINCT *model values* but map to the SAME real value on LuaJIT
5.1. `VInt 3 ↦ 3` and `VFloat 3 ↦ 3.0`, and on 5.1 `3 == 3.0`, both `type()` to
`"number"`, both `tostring` to `"3"` — there is no observation that separates
them. Witnessed concretely by the harness (`EQ|number|number|3|3`). So the
model's two-number-value design is faithful to PUC 5.3/5.4 (which tag integers;
`math.type` distinguishes) but **not** to LuaJIT 5.1. This is a value-domain
redesign question for the user — see fork (A)'s sub-fork below.

(The proof carries `nat`/`bool` *payloads*; for the unambiguous atoms membership
is **head-determined** — `denote_head` in the proof — so the payload is
irrelevant to classification. The bridge port renders payloads only to produce a
concrete real value to hand the interpreter.)

## 2. Atom membership correspondence: `atom_denote` ↔ a real-Lua predicate

The proof's `atom_denote a v` is a value-set membership predicate. Its real-Lua
counterpart is a classification test on a bound name `x`:

| atom    | model `atom_denote`            | real-Lua membership predicate          |
|---------|--------------------------------|----------------------------------------|
| `AStr`  | `VStr _`                       | `type(x) == "string"`                  |
| `ABool` | `VBool _`                      | `type(x) == "boolean"`                 |
| `ANil`  | `VNil`                         | `x == nil` (equivalently `type(x)=="nil"`) |
| `ANum`  | `VInt _` ∨ `VFloat _`          | `type(x) == "number"`                  |
| `AInt`  | `VInt _`  (⊂ `ANum`)           | `type(x)=="number" and x==math.floor(x) and x==x and x~=±inf` (REFINE derived predicate) |
| `AFloat`| `VFloat _`                     | **unobservable on 5.1 — SCOPED OUT** (see below) |

`AStr`, `ABool`, `ANil` are the **unambiguous** atoms (fork-independent). `ANum`
and `AInt` are bridged under REFINE (fork (A) RESOLVED). `AFloat` is scoped out
on 5.1. Bridged atoms: **AStr, ABool, ANil, ANum, AInt** (`lib/sem/bridge/atom.lua`
`M.atoms`).

### AFloat is scoped out on LuaJIT 5.1 (unobservable)

The model's `atom_denote AFloat = VFloat _`. But `VFloat 3 ↦ 3.0` is the same
real double as `VInt 3 ↦ 3`. The only testable real reading of "is a float" is
"is a non-integer number" — and that DISAGREES with the model for integer-valued
floats (`VFloat 3` is a model member of `AFloat` but `3.0` is integral). Since
the value-level int/float distinction is unobservable on 5.1, `AFloat` membership
cannot be faithfully differential-tested; it is scoped out (recorded in
`M.unobservable_atoms`) until the value-domain sub-fork is decided.

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
**RESOLVED = REFINE** (keep `AInt <: ANum` at the type level). This increment
bridges `ANum` and `AInt` accordingly. What REFINE leaves open is the
**value-domain sub-fork** — whether the value layer should keep two distinct
number values (`VInt`/`VFloat`) or collapse to one double — surfaced below.

## 3. The differential pipeline

Legs in `lib/sem/bridge/atom_test.lua` (now covering the 5 bridged atoms):

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
   The number-atom rows (`proof/bridge_num_oracle.v`):
   ```
   (* memb (BAtom ANum) (VInt 3)   *) = true    (* memb (BAtom AInt) (VInt 3)   *) = true
   (* memb (BAtom ANum) (VFloat 3) *) = true    (* memb (BAtom AInt) (VInt 0)   *) = true
   (* memb (BAtom ANum) (VInt 0)   *) = true    (* memb (BAtom AInt) (VFloat 3) *) = FALSE  ← the fork witness
   (* memb (BAtom ANum) (VStr 0)   *) = false   (* memb (BAtom AInt) (VFloat 0) *) = false
   (* memb (BAtom ANum) (VBool _)  *) = false   (* memb (BAtom AInt) (VStr 0)   *) = false
   (* memb (BAtom ANum) VNil       *) = false   (* memb (BAtom AInt) (VBool _)  *) = false
   ```
   (reproduce: `nix develop -c coqc proof/subtype.v && nix develop -c coqc
   proof/bridge_num_oracle.v`.)

2. **Coq-oracle vs real LuaJIT.** Each oracle row's value is rendered to a real
   Lua expression, classified by the vendored interpreter, and compared to the
   model (= proven) verdict. The number atoms surface exactly **one known
   disagreement** — `AInt VFloat 3`: the model says `VFloat 3 ∉ AInt`, but its
   real image `3.0` satisfies the integral predicate. The test asserts the
   disagreement set is **exactly** this one case (the value-domain sub-fork) and
   that everything else agrees.

2b. **VInt/VFloat-vs-5.1 witness.** Builds `VInt 3` and `VFloat 3`'s real images
   and checks they are `==`, both `type=="number"`, identical `tostring` —
   pinning the unobservability concretely (`EQ|number|number|3|3`).

3. **Generated differential.** 100 random model values across **all** heads ×
   the 5 bridged atoms ⇒ 500 classifications; each asserts the port verdict
   equals real LuaJIT's predicate. The generator emits **non-integer** floats for
   `VFloat`, so model and reality agree on every generated value (the
   integer-valued-VFloat fork case is reached only by leg 2/2b, not here).

3b. **Real-value REFINE differential.** 12 real numbers (0, 3, -7, 1.5, 2.25,
   -0.0, 3.0, ±inf, nan, 2^53, 2^53+0.5) × {ANum, AInt} ⇒ 24 classifications;
   the host-side REFINE classifier (`real_refine_class`) is checked against the
   shelled real predicate, validating the integral predicate on edge cases the
   model-value generator can't express (inf/nan/-0.0/large).

### Measured agreement (this increment)

```
[bridge] Coq-oracle:            23/23   port verdicts match the proven model
[bridge] oracle vs real LuaJIT: 22/23   agree; 1 known value-domain-fork disagreement
   [fork] AInt VFloat 3 — VInt/VFloat-vs-5.1: distinct model values, one real double
[bridge] witness VInt 3 vs VFloat 3:  EQ|number|number|3|3
[bridge] differential:         500/500 agree (100 values x 5 atoms)
[bridge] real-value REFINE:     24/24  agree (12 numbers x 2 atoms)
```

The unambiguous atoms and `ANum` correspond with **zero** disagreement. `AInt`
agrees on all reachable real values EXCEPT the integer-valued-`VFloat` case,
which is the surfaced value-domain sub-fork — not a bug, a faithful exposure of
the model↔5.1 mismatch.

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

#### (A′) Value-domain sub-fork — two number values vs one double  *(NEW — needs a user decision)*

REFINE settles the *type* layer. It leaves open the *value* layer. The proof's
`V` has **distinct** `VInt n` and `VFloat n` constructors. On LuaJIT 5.1 these map
to the **same** real value:

> **Concrete witness.** `VInt 3 ↦ 3`, `VFloat 3 ↦ 3.0`; in real LuaJIT 5.1
> `3 == 3.0` (`EQ`), both `type()=="number"`, both `tostring`→`"3"`. So
> `VFloat 3` and `VInt 3` are one real value. Yet the model puts `VFloat 3 ∈ ANum,
> ∉ AInt`, while its real image `3.0` satisfies the `AInt` integral predicate.
> ⇒ a model-vs-reality **disagreement** on the single row `AInt (VFloat 3)`
> (the harness asserts this is the *only* disagreement).

The distinct-`VInt`/`VFloat`-value design is faithful to **5.3/5.4** (which tag
integers) but **not** to **LuaJIT 5.1** (single double). The 5.1-faithful number
value domain is **ONE** number value (a double). The remaining choice is what the
three number atoms denote over that single value domain:

- **`ANum`** = all numbers (`type=="number"`). Unambiguous; agrees with reality
  already.
- **`AInt`** = the **integral-value refinement subset** of the doubles
  (`x==floor(x)` and finite). This is the only faithful 5.1 reading of `AInt` and
  is what the bridge already tests.
- **`AFloat`** — two options, the actual fork:
  - **(i) `AFloat` = all numbers** (a synonym of `ANum`; "float" = the runtime
    representation, since every 5.1 number *is* a double). Then `AInt <: AFloat`
    and `AFloat ≡ ANum`. Faithful and observable, but `AFloat` carries no
    information beyond `ANum`.
  - **(ii) `AFloat` = the non-integer-valued numbers** (the complement of `AInt`
    within `ANum`). Then `AInt` and `AFloat` partition `ANum` and `AFloat` is
    observable (`number and x~=floor(x)`). This is a *different* type than the
    model's current `AFloat = VFloat _` (which includes integer-valued floats),
    so it is a genuine redesign, not a port.

Either single-double option requires **collapsing `VInt`/`VFloat` to one value
constructor** in `V` (a `proof/subtype.v` change — **NOT made here**, per the
constraint). Until that decision, `AFloat` is **scoped out** of the bridge
(`M.unobservable_atoms`): with two distinct model values it is not faithfully
testable on 5.1. `ANum` and `AInt` are bridged because they ARE observable
(number; integer-valued number) regardless of how the sub-fork resolves.

The existing `lib/sem` harness already makes the int/float split observable
*across versions* (`4/2` → `2.0` on 5.3/5.4 vs `2` on 5.1) — evidence the
refinement is real *somewhere*, but not on 5.1's `type()`. **This sub-fork (A′)
needs a user decision** before `V` is touched or `AFloat` is bridged.

### (B) Functions / closures — BRIDGEABLE via operational I/O check  *(re-characterized)*

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
opaque closures, which are outside the model's value domain. Deferred as the next
increment (function-value reality bridge), no longer flagged as possibly
unbridgeable.

### (C) Tables — open/closed, key types, finite-assoc vs real semantics

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

## Status

- **Done (increment 1):** unambiguous atoms AStr/ABool/ANil — port validated
  against Coq `Compute` (12/12), differential green (300/300), no disagreement.
- **Done (increment 2, this one):** number atoms under REFINE. Port for
  `ANum`/`AInt` validated against the Coq oracle (23/23 over all bridged atoms);
  differential green (500/500 generated, 24/24 real-value REFINE edge cases);
  the **one** model-vs-reality disagreement (`AInt (VFloat 3)`) surfaced and
  asserted-as-the-only-one. `AFloat` scoped out (unobservable on 5.1).
- **Resolved:** fork (A) = **REFINE** (type-level `AInt <: ANum`).
- **Needs user decision:** sub-fork **(A′)** — collapse `VInt`/`VFloat` to one
  double in `V` (a `proof/subtype.v` redesign), and the `AFloat` reading
  (all-numbers vs non-integer-valued). FFI cdata integers — separate deferred
  axis.
- **Re-characterized:** fork (B) functions — **bridgeable** via the operational
  I/O check on the model's finite known graph (next increment); only opaque
  external closures are unbridgeable, and the model never yields those.
- **Scoped:** fork (C) tables — string-keyed records, richer behaviors tracked.
