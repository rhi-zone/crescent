# Adversarial audit round 5 — crescent slice v2 increments 7–8

Date: 2026-06-12. HEAD `7422ad9e` (increment 8). Execution-led; every finding is
reproduced against the real substrate via `crescent_slice_lower.lower → A.check`.
Scope: the new surfaces since round 4 — increment 7 (`9f396092`: field-path narrowing
with sound-conservative invalidation, §6.11) and increment 8 (`7422ad9e`: dependency-
ordered alias declaration, §6.12). Prior rounds: `audit-round-{3,4}.md`.

Scratch probes lived in `/tmp/probe.lua` + `/tmp/p*.lua` (harness drives `L.lower`
then `A.check`, reporting verdict + acc/rej/unk + markers). Nothing in `lib/` was
modified.

---

## Finding count by severity

| Severity | Count | Findings |
|---|--:|---|
| HIGH (soundness) | 1 | F1 — same-statement path refinement survives a happens-before call |
| MEDIUM (precision / wrong-rejection) | 1 | F2 — post-exit (`if not x.f then return`) does not narrow a field PATH |
| LOW (claim-vs-implementation) | 1 | F3 — the "readonly fields survive" invalidation carve-out is vacuous/unimplemented |

Regressions: **none** (rounds 1–4 fixes hold on the new paths; suite green, 6501 assertions).

---

## F1 [HIGH — soundness] A path refinement survives a call that happens-BEFORE the read inside the SAME statement

**Reproduced — the round-5 target.** Field-path refinement invalidation
(`invalidate_paths`, `crescent_slice_lower.lua:1078`) is applied by the block walker
(`lower_block`, line 2629) **AFTER each whole statement**:

```lua
if stmt_invalidates_paths(s) then invalidate_paths(ctx) end
```

But Lua evaluation is **sub-statement-ordered**: within one statement, a side-effecting
call can be fully evaluated *before* a later field-path read. The slice consults the
live (pre-call) refinement for that read because invalidation is deferred to the end of
the statement. A callee holding the base (no escape analysis — the slice's own stated
assumption) may set `x.f = nil` during that call, so the post-call read is `string | nil`
at runtime while the slice types it `string`. **An unsound result type is accepted.**

### Cleanest repro — plain argument-evaluation order (`F1c`)

```lua
--:: O = { f: string | nil }
--: (string, string) -> string
local function id2(a, b) return b end
--: (O) -> string
local function emit(o) return "x" end
--: (O) -> string
local function g(o)
  if o.f then return id2(emit(o), o.f) end   -- CLEAN  ← UNSOUND
  return ""
end
```

Lua evaluates arguments left-to-right: `emit(o)` runs (and may mutate `o.f`) before
`o.f` is read as the second argument. The slice accepts `o.f` at its refined non-`nil`
type. Verdict: **CLEAN, 0 rejections** — an idiomatic pattern (a computed value passed
alongside a narrowed field) is silently mis-typed.

### Corroborating variants (all CLEAN = all unsound)

| Probe | Statement | Why the call happens-before the read |
|---|---|---|
| `F1` | `return emit("x") or o.f` | `or` evaluates the left operand (`emit`) first |
| `F1b` | `return id(emit("x") .. o.f)` | `..` evaluates left-to-right |
| `A1b` | `local v = f(x) and id(x.f)` | `and` evaluates the left operand first |
| `A7` | `return id(x:m2() .. x.f)` | method call on the base, then concat |
| `C3` | `local r = touch(n) and id(n.left)` | **μ-typed base** across the unfold (§3 interaction) |

### Proof it is the refinement, not the value, that is accepted

The byte-equivalent **two-statement** forms are correctly **FINDINGS** (the existing
test at `corpus_lower_test.lua:1053` is exactly this):

| Control | Verdict |
|---|---|
| `emit("x"); return o.f` (call, then read — 2 stmts) | FINDINGS (type-mismatch) |
| `local v = f(x) and id(x.f)` with **no guard** (proves accept came from the refinement) | FINDINGS |
| `f(x); return id(x.f)` (2 stmts) | FINDINGS |

The *only* difference between the accepted and rejected forms is whether the
side-effecting call and the path read sit in **one statement** or **two**. The
invalidation discipline is statement-granular; Lua's mutation point is not.

### Why the existing tests miss it

The increment-7 suite has exactly one "live refinement inside a call" test
(`corpus_lower_test.lua:1029`, the coinductive `s = s + sz(n.left)`). There the read
`n.left` genuinely happens-**before** the call `sz(...)` — the read IS the argument, so
the accept is sound. The design generalized this to "the read inside the statement uses
the live refinement" (comment at line 2624–2627: *"The read inside the statement already
used the live refinement (happens-before the call)"*) — but that happens-before only
holds when the read is an argument *to* the invalidating call, not when the call is a
*sibling* sub-expression evaluated first. No test exercises the call-before-read
intra-statement ordering, so the bug ships green at 6501 assertions.

### Principled fix direction (substrate, not result)

The fence must be sub-statement: invalidate a path refinement at the evaluation point of
any call **within** an expression, before evaluating the rest of that expression — i.e.
thread invalidation through `synth_*_expr` at each call/methodcall node, not only through
`lower_block` after the statement. The conservative-correct v1 collapse (no escape
analysis) is "a path read is only refined if no call has been evaluated earlier *in the
same expression tree*". This is an effect-ordering gap in the lowering, recorded as the
substrate need ("sub-statement happens-before invalidation requires an evaluation-order
walk the statement-level fence does not provide"), not a per-fixture result patch.

Severity HIGH: a real, idiomatic program is accepted with an unsound result type; the
soundness window the increment claims to enforce is breached by ordinary evaluation order.

---

## F2 [MEDIUM — precision / wrong-rejection] Post-exit narrowing does not refine a field PATH

**Reproduced.** The post-exit guard form `if not x.f then return end; <use x.f>`
narrows a bare variable but **not** a depth-1 field path. The block walker's post-exit
arm (`lower_block`, lines 2606–2619) reads the falsy refinement via `ctx_get(ctx, var)`
only:

```lua
local pre = ctx_get(ctx, var)
if pre then ... end
```

For a path `var = "x.f"`, `ctx_get(ctx, "x.f")` is `nil` (no live refinement is bound
yet), so `pre` is nil and no narrowing is emitted — unlike the `if-then` arm (line 2333)
which computes `path_pre_type(ctx, var)` for a path. Result:

```lua
--:: Box = { f: string | nil }
--: (Box) -> string
local function g(x)
  if not x.f then return "n" end
  return id(x.f)        -- FINDINGS  ← should be CLEAN (x.f is provably non-nil here)
end
```

| Probe | Form | Verdict |
|---|---|---|
| `A4` | post-exit on a **path** `x.f` | FINDINGS (wrong-rejection) |
| `A4-ctl` | post-exit on a bare **var** `v` | CLEAN (correct) |

This is a **precision gap (false positive)**, not a soundness defect — it rejects sound
code, never accepts unsound code. It is the asymmetry between the two narrowing arms: the
`if-then` arm threads `path_pre_type`; the post-exit (`block_exits`) arm does not. The
`if x.f and b then` and-guard path form (round-4 fix) DOES narrow (`F2a` → CLEAN), so the
gap is specific to the post-exit/early-return idiom, which is common in `lib/` (the
`if not node then return` guard family round 4 flagged as the dominant corpus idiom).

Principled fix: the post-exit arm should compute the path pre-type via `path_pre_type`
and bind the falsy refinement under the path name, mirroring the `if-then` arm — the same
machinery, applied at the second site.

---

## F3 [LOW — claim-vs-implementation] The "readonly fields survive" invalidation carve-out is vacuous and unimplemented

**Reproduced by source inspection + execution.** The increment-7 commit message states
the soundness fence as: *"a path refinement dies after any call … and any write …;
**readonly fields survive**."* This presents readonly-survival as an executable part of
the fence. It is not:

1. **`invalidate_paths` (lines 1078–1096) checks no readonly marker.** It collects every
   live dotted path name and re-binds each to its un-refined declared type
   unconditionally — there is no branch that lets a readonly field's refinement persist.
   A readonly path would be invalidated identically to a mutable one.

2. **No source can produce a readonly field.** The v1 annotation grammar has no readonly
   syntax; `crescent_slice_parse.lua:219` hardcodes `readonly = false` for every parsed
   field, and a repo-wide search finds **zero** `readonly = true` productions. The `Field`
   record carries a `readonly` slot (`slice_ty.lua:35`) but nothing ever sets it true.

So the carve-out is **vacuous** (the case can never arise) AND **unimplemented** (if it
did arise, the code would not honor it). There is no *current* unsoundness: because no
field is ever readonly, ALL paths invalidate, which is the sound-conservative behavior.
The finding is the discrepancy between the stated/executable fence and the code: a future
increment that adds readonly syntax would find the promised survival logic absent, and
the silent default (invalidate-all) would mask the missing branch. Severity LOW — record,
do not block.

---

## Regression spot-checks (rounds 1–4 fixes on the new paths)

All hold. Each reproduced against the real substrate.

| Check | Round | Probe | Result |
|---|---|---|---|
| Well-formedness gate under topo reorder | 1–2 | `R1` `A = { f: Zzz }` undefined fwd-ref | OUT-OF-SUBSET `unknown-type-name:Zzz` — honest error survives reorder |
| Collision detection vs new ordering | 2 | per-module batch topo is independent of the cross-module F1 collision check (`xmodule.lua:184–214` runs per installed name regardless of order) | intact (suite + code path) |
| `rec_with_indexer` dynamic-read join | 4 (A-F1) | `R2` `return t[k]` over `{a:string,[string]:integer}` | FINDINGS — the field union is joined; round-4 fix intact under path refinement |
| F1 module-rec rebind | 3 | `R3` `M = {}` after `function M.f`; `return M.f` | OUT-OF-SUBSET `no-such-field:f` — stale rec dropped |
| F1-rebind × path refinement (new interaction) | 3×7 | `C1` narrow `M.f`; `M = nil`; read `M.f` | FINDINGS — rebind (an assign) invalidates the path |

### Sound behaviors confirmed on the new fence (positive validations)

- **Write-through / any-assign invalidation** (`A5`, `A5b`, `A8`): any `assign`
  (including an unrelated `x.g = v`, an unrelated local reassignment, and a
  multiple-assignment) kills every live path refinement — over-conservative but **sound**.
- **No-call local does not invalidate** (`A5c`): a pure `local q = 1` with no call in its
  RHS preserves the refinement (CLEAN) — correct (a local binding is not a mutation).
- **Method call on the base** (`A6`): `x:m()` then a read of `x.f` in the next statement
  invalidates — `node_has_call` recognizes `methodcall`.
- **Closure capture** (`A9`, `A9b`): a captured-base closure that is *called* invalidates
  (`A9`, the `c()` statement is a call); a closure merely *defined* and never called
  preserves the refinement (`A9b`, CLEAN) — sound, since the body does not run.
- **Alias ordering, forward sibling** (`B1`): `A = { f: B }` before `B = integer`
  resolves — CLEAN. The increment-8 feature works.
- **Cycle honesty** (`B2`, `B3`): a 3-cycle `A→B→C→A` and a self-ref `T = T` both produce
  honest alias errors — the topo sort does not paper over genuine cycles.
- **Spurious field-key edges are benign** (`B4`, `B5`): the dependency scan
  (`alias_decl_order`, `crescent_slice_parse.lua:613`) tokenizes the WHOLE body with
  `gmatch("[%a_][%w_]*")`, so a record KEY whose name matches a sibling alias creates a
  false dependency edge (and even a false `A↔B` cycle). This was attacked directly: the
  false edge does **not** break a legitimate forward reference. DFS post-order still emits
  the genuinely-depended-on alias first; the spurious back-edge only suppresses recursion
  through itself (cycle protection), and `declare_alias` binds true self/mutual cases via
  μ. `A = { f: B }` with `B = { A: integer }` (a spurious `B→A` key edge) resolves CLEAN,
  identical to a non-colliding control. No finding — the over-approximate edge set is a
  documented robustness property, not a bug.

---

## Summary

- **F1 (HIGH, soundness):** the field-path invalidation fence is statement-granular, but
  Lua evaluation is sub-statement-ordered. A side-effecting call that is syntactically a
  *sibling* of a later path read in the same statement (argument order, `and`/`or`, `..`,
  method call) is evaluated first and may mutate the field, yet the slice consults the
  pre-call refinement and accepts an unsound result type. Idiomatic (`id2(emit(o), o.f)`),
  reproduced across calls/method-calls/connectives and over a μ-typed base. The
  two-statement forms are correctly rejected; the gap is precisely the intra-statement
  ordering no test exercises.
- **F2 (MEDIUM, wrong-rejection):** the post-exit `if not x.f then return end` guard does
  not narrow a field path (only a bare var) — the `block_exits` arm omits the
  `path_pre_type` the `if-then` arm uses. Sound but over-rejecting; the early-return guard
  is a common `lib/` idiom.
- **F3 (LOW, claim-vs-impl):** the "readonly fields survive" carve-out is vacuous (no
  readonly field can be parsed) and unimplemented (`invalidate_paths` checks no readonly
  marker). No current unsoundness; a latent gap for any future readonly syntax.
- **Regressions: none.** Rounds 1–4 fixes (well-formedness gates, collision detection,
  the `rec_with_indexer` dynamic-read join, F1 module-rec rebind) all hold on the new
  paths, including the new F1-rebind × path-refinement interaction. Alias topological
  ordering is robust: forward siblings resolve, genuine cycles error honestly, and
  spurious field-key dependency edges are benign. Full analysis suite green, 6501
  assertions, 0 failed.
