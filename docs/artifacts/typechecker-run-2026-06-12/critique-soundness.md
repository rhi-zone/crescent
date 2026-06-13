# Adversarial soundness critique of the typechecker design thesis

Date: 2026-06-14. Target: `docs/typechecker-design-thesis.md`, claims 1, 3, 5
from "Claims Requiring Adversarial Verification." Execution-led: every finding is
reproduced by driving the real substrate
(`crescent_slice_lower.lower → A.check`) from source text. Probes were run via
`bin/cr run` over a scratch driver (the same lower→check harness as
`corpus_lower_test.lua`); the driver and probe files are listed inline below so
the runs are reproducible. Nothing in `lib/` was modified.

Verdicts up front:

| Claim | Verdict | Sharpest finding |
|---|---|---|
| 1 — value/judgement dichotomy partitions cleanly | **FALSIFIED** | Mutability is neither a value-subset nor an orthogonal layer; field variance forces a per-field readonly/mutable split the dichotomy does not name, and the current covariant collapse is a *live* unsound accept (not unreachable). |
| 3 — sound ⊤ distinct from any/dynamic() in practice | **PARTIAL** | `unknown` genuinely blocks (arith/index/call all rejected, not silently accepted) — so it is *not* a bounded-any. But a sound `type(x)=="number"` guard does **not** narrow `unknown` to `number` (it does for a union), so the canonical guard-then-use idiom yields an unusable false positive — the (a) pressure-toward-bounded-any is real and demonstrated. |
| 5 — soundness holds over the covered domain | **FALSIFIED** | A fully in-subset program (annotated-local alias + field write + field read) is accepted CLEAN while writing a `number` into a field the caller reads as `integer`. Live false negative. |

---

## Claim 5 — FALSIFIED. Live false negative via covariant field write-through.

The covered domain *as it stands today* admits a false negative. It is the
mutable-field-invariance gap that §9.2 of the slice spec claims is "unreachable
in v1's checked syntax." It is reachable.

### The reproduction (`FN_widen_alias_write`)

```lua
--:: IntBox = { f: integer }
--:: NumBox = { f: number }
--: (IntBox) -> integer
local function corrupt(ib)
  --: NumBox
  local nb = ib       -- IntBox <: NumBox accepted (covariant field), CLEAN
  nb.f = 1            -- write checked against NumBox.f = number → accepted
  return ib.f         -- read as integer
end
```

Result: `expected=CLEAN requested=3 acc=3 rej=0 unk=0 diags=0`. Zero markers.
Fully in-subset, fully accepted.

The numeric-literal version could be argued away as `1 : integer`. It is not the
literal: the param-typed version is identical.

```lua
--: (IntBox, number) -> integer
local function corrupt(ib, x)
  --: NumBox
  local nb = ib
  nb.f = x            -- x : number written into ib's integer field
  return ib.f
end
```

`FN_widen_alias_write_numvar`: `expected=CLEAN ... acc=3 rej=0`. At runtime `x`
may be `1.5`; `ib.f` is then `1.5` while statically typed `integer`. The checker
accepted a program that produces a runtime type error. **This is the false
negative the thesis says cannot exist over the covered domain.**

### The two controls that prove it is the covariant accept, not noise

1. **`CtrlA_direct_bad_write`** — a *direct* `b.f = x` (`x:number`, `b.f:integer`)
   is correctly **REJECTED** (`FINDINGS`, marker `type-mismatch`). So the
   field-write rule is normally sound; the unsoundness is not a blanket
   accept-everything.

2. **`CtrlB_widen_only_no_write`** — `IntBox <: NumBox` *with no write* is
   `CLEAN`. So the widening step is exactly the covariant `_rec_sub`. The false
   negative is precisely (covariant widen) ∘ (write through the wider view) — the
   two sound-in-isolation steps compose into an unsound whole.

3. **`Ctrl_annotated_local_rejects_nonsub`** — `--: NumBox local nb = sb` with
   `sb : StrBox` is **REJECTED** (`type-mismatch`). So the annotated local *does*
   enforce its annotation; the widening in the false negative is a genuine
   `IntBox <: NumBox` accept, not an ignored annotation.

### Root cause in the code

`lib/type/analysis/slice_subtype.lua` `_rec_sub`, lines 342–352:

```lua
-- depth: covariant field type (v1 treats fields covariantly; the
-- mutable-field-invariance gap is recorded in §9.2).
...
if not sub(af.ty, bf.ty, seen, memo) then return false end
```

Fields are compared covariantly *unconditionally*. There is no readonly/mutable
discriminator: `slice_ty.lua` carries a `readonly` slot but
`crescent_slice_parse.lua` hardcodes `readonly = false` and nothing ever sets it
true (confirmed by audit round 5 F3). Every field is mutable in practice, and
every field is checked covariantly — the exact unsound combination.

### Why "unreachable in v1" is wrong

§9.2 fences this as unreachable because "no v1 corpus fixture writes through a
widened field alias." That is an observation about the *corpus*, not about the
*checked syntax*. The reachability question is whether v1 syntax can *express*
the pattern — and it can: annotated `local`, alias assignment, field write, and
field read are each independently in-subset (each is a CLEAN construct above).
The fence confuses "no current fixture does this" with "the language cannot say
this." A real `lib/` author writing a setter that takes a record annotated at a
numeric supertype hits it. The claim that soundness holds over the covered domain
is false as stated; the honest statement is "sound over the covered domain
*except* mutable-field variance, which is a known live hole, not a fenced one."

---

## Claim 1 — FALSIFIED. Mutability straddles the value/judgement dichotomy.

The dichotomy (thesis §3): every property is *either* a value-subset checkable by
subtyping (→ lattice enrichment, no pass) *or* a genuinely-orthogonal judgement
(→ its own de-special-cased layer). The falsifier the thesis itself nominates is
mutable-field invariance. Driving it shows it sits in **neither** bucket cleanly.

**It is not a clean value-subset.** Subtyping is a relation on value sets. The set
of values inhabiting `{f: integer}` *is* a subset of the values inhabiting
`{f: number}` — so by the value-set test, `IntBox <: NumBox` is correct, and the
lattice (covariant `_rec_sub`) computes it correctly. The Claim-5 false negative
proves the value-subset answer is the *wrong* answer for a mutable field: read-set
inclusion holds, but write-safety does not. Subtyping-on-value-sets cannot see the
difference, because the difference is not about *which values* the field can hold
— it is about *whether the field can be written through this reference*. That is
the textbook reason mutable references are invariant: the value-set is covariant,
the *reference* is invariant, and a structural value-set lattice has no place to
record the latter.

**It is not a clean orthogonal judgement either.** The thesis's orthogonal layers
(effects, linearity, taint, termination) are about *how a value is produced or
used*, and they compose as separate row/usage judgements that do not touch the
subtype relation. Mutable-field variance cannot be lifted out that way: the fix
the slice spec itself prescribes (§3.2, §9.2) is to **split readonly fields
(covariant) from mutable fields (invariant) inside the depth rule of
`_rec_sub`** — i.e. inside the one subtype relation, per field. That is not a
separable judgement layer; it is a *modification of the subtyping rule keyed on a
per-field mutability bit*. It changes how `<:` itself is computed.

So mutability is the third category the dichotomy denies: a property that lives
**inside** the value-set lattice's subtype rule yet is **not** a value-subset
fact — a variance annotation on a structural constructor. The dichotomy's sharp
question "is it a value-subset, yes/no?" has no correct answer for it: yes by the
value-set membership test (and that yes is unsound), no by the write-safety test
(and that no cannot be expressed as an orthogonal layer). The principled fix is a
*hybrid* — a per-field variance marker threaded through the subtype relation —
which is precisely "a special case or a hybrid the dichotomy does not name." The
`readonly` slot already in `slice_ty.lua` is the vestige of exactly this hybrid;
it exists because the clean dichotomy could not hold it anywhere else.

Capability-reachability and aliasing/identity corroborate (probed `C1_identity_alias`:
`a == b` on two structurally identical `Box` values is `CLEAN` — the checker cannot
distinguish identity, because identity is not a value-set property and there is no
layer for it; it is simply invisible). But mutability is the decisive one because
the slice's *own prescribed fix* lands inside the subtype relation, not beside it.

---

## Claim 3 — PARTIAL. `unknown` blocks (not bounded-any), but the distinction
## costs an unusable false positive on the canonical narrow.

The thesis claims `unknown` is a sound ⊤ that *blocks use until narrowed*, the
opposite of `any`/`dynamic()`. Two halves to test: (b) does it ever produce an
unsound accept like a bounded-any? and (a) is it ever forced to behave like a
bounded-any to avoid unusable false positives?

### (b) — `unknown` genuinely blocks. The thesis half that SURVIVES.

Every direct use of an `unknown`-typed value is rejected (goes out-of-subset with
a precise marker), never silently accepted:

| Probe | Body | Result | Marker |
|---|---|---|---|
| `C3b_unknown_arith` | `x + 1` | OUT-OF-SUBSET | `operator-metamethod-arith` |
| `C3c_unknown_index` | `x.field` | OUT-OF-SUBSET | `no-such-field:field` |
| `C3d_unknown_call` | `x()` | OUT-OF-SUBSET | `call-non-function` |
| `C3g_unknown_into_concrete` | `return x` where ret = `Box` | FINDINGS | `type-mismatch` |

This is the real, enforced difference from Elixir's `dynamic()` (which admits an
op valid for *some* branch). Crescent's `unknown` admits *no* op until narrowed.
On the (b) axis the distinction does not collapse — it is not a bounded-any.

### (a) — but the sound block is not narrowable by the standard guard. FALSIFIES the "no false-positive pressure" implication.

The whole value proposition of a blocked ⊤ over a bounded-any is that narrowing
*restores usability*. It does not, for the most basic idiom:

```lua
--: (unknown) -> integer
local function f(x)
  if type(x) == "number" then return x + 1 end   -- FINDINGS (type-mismatch)
  return 0
end
```

`C3e_unknown_narrow_typeguard`: **FINDINGS**. The `type(x)=="number"` guard does
**not** narrow `unknown` to `number`, so `x + 1` in the then-branch is rejected.

The control proves this is specific to `unknown`, not to arithmetic or to
narrowing in general:

```lua
--:: U = integer | string
--: (U) -> integer
local function f(x)
  if type(x) == "number" then return x + 1 end   -- CLEAN
  return 0
end
```

`C3h_union_narrow`: **CLEAN**. The *identical* guard narrows a union
`integer|string` to `integer` and `x+1` is accepted. And `C3j_number_arith` /
`C3k_integer_arith` confirm `number + 1` and `integer + 1` are in-subset CLEAN —
so the only thing failing in `C3e` is the narrow of `unknown` itself.

### Why this is the (a) falsifier

The thesis frames sound `unknown` as strictly better than bounded-any because it
catches errors a bounded-any would let through, *while remaining usable via
narrowing*. The data shows the usability half is not delivered for `unknown`: a
designer whose function legitimately takes an `unknown` (an uncovered-construct
result, a genuinely-dynamic input) and does the textbook `type()` guard before use
gets a false positive on every such site, with no in-subset way to discharge it
(the union-narrow machinery that works for `integer|string` is not wired to refine
`unknown`). That is exactly the pressure the thesis says does not materialize —
"forced to behave like a bounded-any to avoid unusable false positives." The
escape a real designer reaches for is to stop using `unknown` and annotate a
concrete-or-union type instead, i.e. to avoid ⊤ — which is the bounded-any
direction in practice even though the type machinery is not bounded-any.

PARTIAL, not FALSIFIED: the sound-block property (b) is real and enforced, so the
distinction is *not* purely on-paper. But the practical equivalence the thesis
denies (a) shows up as a concrete, reproducible false positive on the canonical
guard, and the narrowing layer that makes unions usable is absent for `unknown`.
The distinction holds in the type theory and breaks in the ergonomics.

---

## Reproduction harness

Driver (run with `bin/cr run <file>`): each probe lowers source via
`crescent_slice_lower.lower`, checks via `analysis.check` with the slice
semantics registered, and prints `verdict / requested / acc / rej / unk / diags`
plus marker tags. Identical reduction to `corpus_lower_test.lua`.

```lua
local A = require("lib.type.analysis")
local S = require("lib.type.analysis.crescent_slice")
local L = require("lib.type.analysis.crescent_slice_lower")
local function reg() local r = A.new_registry(); S.register(r); return r end
local function run(name, src)
  local res = L.lower(src, "probe://" .. name)
  local chk = A.check({ state = res.state, requested_claims = res.requested,
    semantics_registry = reg(), trust_policy = nil })
  local acc, rej, unk = 0, 0, 0
  for _ in pairs(chk.accepted_claims) do acc = acc + 1 end
  for _ in pairs(chk.rejected_claims) do rej = rej + 1 end
  for _ in pairs(chk.unknown_claims) do unk = unk + 1 end
  -- print verdict + counts + res.markers[i].construct
end
```

Observed runs (verbatim):

```
=== CtrlA_direct_bad_write ===          FINDINGS  acc=1 rej=0  marker type-mismatch
=== CtrlB_widen_only_no_write ===       CLEAN     acc=2 rej=0
=== Ctrl_annotated_local_rejects_nonsub === FINDINGS acc=1 rej=0 marker type-mismatch
=== FN_widen_alias_write ===            CLEAN     acc=3 rej=0   (FALSE NEGATIVE)
=== FN_widen_alias_write_numvar ===     CLEAN     acc=3 rej=0   (FALSE NEGATIVE)
=== C3b_unknown_arith ===               OUT-OF-SUBSET  operator-metamethod-arith
=== C3c_unknown_index ===               OUT-OF-SUBSET  no-such-field:field
=== C3d_unknown_call ===                OUT-OF-SUBSET  call-non-function
=== C3e_unknown_narrow_typeguard ===    FINDINGS  type-mismatch  (FALSE POSITIVE)
=== C3h_union_narrow ===                CLEAN     acc=4 rej=0
=== C3j_number_arith ===                CLEAN     acc=1 rej=0
=== C3g_unknown_into_concrete ===       FINDINGS  type-mismatch
=== C1_identity_alias ===               CLEAN     acc=1 rej=0
```

## Conclusion

Two of the three load-bearing claims are falsified outright and the third is
materially weakened:

- **Claim 5 is false today**, not in some future increment: mutable-field
  covariance is a *reachable* in-subset false negative, mis-fenced as
  "unreachable in v1 syntax" when only the *corpus* (not the *grammar*) avoids it.
- **Claim 1 is false**: mutability is the third category — it lives inside the
  subtype relation yet is not a value-subset fact, and its prescribed fix is a
  per-field variance hybrid the clean dichotomy cannot name. The `readonly` slot
  is the dichotomy's own admission of this.
- **Claim 3 is half-true**: sound `unknown` really does block (not a bounded-any
  on the soundness axis), but it is not narrowable by the standard `type()` guard
  that works for unions, so it inflicts unusable false positives on the canonical
  guard-then-use idiom — the precise ergonomic pressure toward bounded-any the
  thesis claims does not arise.

The unifying observation: the design's value-set lattice is correct *for reads*
and the thesis's framing is a reading-centric framing. Mutation (write-through
variance) and dynamic narrowing of ⊤ are the two places where read-centric
value-set subtyping is the wrong tool, and both surface as concrete defects
(Claim 5 false negative, Claim 3 false positive) reproducible on in-subset v1
syntax.
