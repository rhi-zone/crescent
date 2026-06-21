# Reality bridge — model ↔ real LuaJIT

The Coq development (`proof/subtype.v`) proves everything *about* the type model:
subtyping is a Boolean algebra, the decider is sound, records/arrows have the
expected variance, etc. The one thing a proof **cannot** establish is
**faithfulness** — that the abstract value domain `V` and its `atom_denote`
actually correspond to how *real LuaJIT 5.1* classifies *real* values. That is an
empirical fact about an external artifact; it can only be *tested*, not proved.

This doc pins that correspondence and records the differential pipeline that
checks it. This first increment de-risks scope: it proves the pipeline
**end-to-end on the unambiguous fragment** (atoms whose model↔reality
correspondence is not entangled with any open design fork) and **enumerates** the
genuine design forks rather than silently resolving them.

Harness: `lib/sem/bridge/atom.lua` (the Lua port + correspondence), test
`lib/sem/bridge/atom_test.lua`. Reuses the `lib/sem` differential pattern: a
caps-injected `popen` cap shells the vendored interpreter; absent ⇒ skip, never
fail (bare-clone safe).

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
| `VInt n`         | a Lua **number** (integer-valued) — see fork (A) |
| `VFloat n`       | a Lua **number** (non-integer-valued) — fork (A) |
| `VFun graph`     | a Lua **function** realizing that finite I/O graph — see fork (B) |

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
| `AInt`  | `VInt _`  (⊂ `ANum`)           | **see fork (A)** — *not* a runtime tag |

`AStr`, `ABool`, `ANil` are the **unambiguous** atoms: model and real LuaJIT 5.1
correspond cleanly regardless of any open fork. The bridge increment is scoped to
exactly these.

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

Whether the model **should** track this refinement at all is a genuine design
fork — see **fork (A)** below. This increment defers `AInt`/`AFloat`/`ANum`
entirely.

## 3. The differential pipeline (unambiguous atoms)

Three legs, all in `lib/sem/bridge/atom_test.lua`:

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
   (reproduce: `nix develop -c coqc proof/subtype.v` then `Require Import
   subtype.` + the `Compute` lines.)

2. **Coq-oracle vs real LuaJIT.** Each oracle row's value is rendered to a real
   Lua expression, classified by the vendored interpreter, and asserted equal to
   the model (= proven) verdict.

3. **Generated differential.** 100 random model values across **all** heads
   (string/bool/nil/int/float/table/function) × the 3 unambiguous atoms ⇒ 300
   classifications; each asserts the port verdict equals real LuaJIT's `type(x)`
   classification. Random heads exercise **rejection** (a value of the wrong head
   correctly classified as a non-member) as well as membership.

### Measured agreement (this increment)

```
[bridge] Coq-oracle:           12/12  port verdicts match the proven model
[bridge] oracle vs real LuaJIT:12/12  agree
[bridge] differential:        300/300 agree (100 values x 3 atoms)
```

**No faithfulness disagreement** was found on the unambiguous fragment. The
model↔reality differential pipeline works end-to-end on the clean fragment.

## 4. Open design forks (NOT resolved here — for the user to steer)

These are genuine forks: each has consequences either way, and resolving one
silently would manufacture an ad-hoc commitment. They are listed, not decided.

### (A) Number atoms — int/float refinement vs collapse  *(primary)*

Does the model target a **refined** type system distinguishing integer-valued
numbers (`AInt <: ANum`, matching the slice's `integer <: number`) **even though
LuaJIT 5.1 does not tag them** — or should `VInt`/`VFloat` **collapse** to one
number kind to match runtime `type()`?

- **Keep the refinement.** Pro: matches the slice's `integer <: number` and PUC
  5.3/5.4's real `math.type` tag; the model already proves the subtype edge
  cleanly. Con: on LuaJIT 5.1 `AInt` membership is **not** a runtime tag check —
  it is a *derived* predicate (`type=="number" and x==floor(x) and finite`), so
  the reality bridge for `AInt` tests a **value-shape refinement**, not a tag.
  `VInt 3` and `VFloat 3.0` are *indistinguishable* to LuaJIT 5.1 `type()`/
  `tostring` (both render `3`) — so the refinement is only observable through the
  derived integral-value predicate, never through the runtime's own kind tag.
- **Collapse to one number kind.** Pro: an exact match to LuaJIT 5.1 runtime
  `type()` — the bridge for `ANum` becomes another unambiguous atom. Con: throws
  away `integer <: number`, which the slice wants and which 5.3/5.4 *do* tag at
  runtime; the model would then *under*-approximate richer Lua versions.

The existing `lib/sem` harness already makes the int/float split **observable
across versions** (the `known cross-version deltas` test: `4/2` → `2.0` on
5.3/5.4 vs `2` on 5.1/LuaJIT). That is evidence the refinement is real *somewhere*
in the Lua family — but **not** on LuaJIT 5.1's `type()`. **Needs a user
decision** before `AInt`/`AFloat`/`ANum` can be reality-bridged.

### (B) Functions / closures — extensional graph vs un-introspectable closure

The model's `VFun` is an **extensional finite I/O graph** (`list (V*V)`); arrow
membership (`denote (BArrow A B)`) quantifies over that graph. A **real Lua
closure cannot be introspected for its graph** — there is no way to enumerate the
(input, output) pairs of an arbitrary function from the outside.

So arrow membership may **not be reality-bridgeable as a membership check at all**:
you can only *observe* a closure by **calling** it on sampled inputs and checking
outputs — a **behavioral / sampling test**, fundamentally weaker than the model's
universally-quantified membership (sampling can only *refute*, never *confirm*,
`∀(i,o)∈g …`). This is the **hard** fork: the model's value notion (a finite
explicit graph) and reality's (an opaque behavioral object) may be
*category-different*, not merely differently-tagged. Deferred; flagged as the one
that may not have a clean bridge.

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

Deferred; bridging tables requires deciding key-type scope and the
open/closed/index-signature reading first.

## Status

- **Done:** correspondence spec (this doc); Lua port of `atom_denote` validated
  against the Coq `Compute` oracle (12/12); model↔real-LuaJIT differential
  pipeline green on the unambiguous fragment (12/12 oracle, 300/300 generated);
  no faithfulness disagreement found.
- **Deferred (forks above, need user steer):** (A) int/float — primary; (B)
  function/closure behavioral bridge — the hard one; (C) tables — key types and
  open/closed reading.
