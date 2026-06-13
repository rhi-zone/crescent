# Partial-File Checking Behavior — crescent.slice.v1

Sourced from: `lib/type/analysis/crescent_slice_lower.lua` and
`lib/type/analysis/slice_survey.lua`. Answers four load-bearing questions about
how the slice treats a file that is only partially inside the v1 subset.

---

## Q1 — Bail vs. continue at an out-of-subset statement/expression

**Answer: skip the individual node and continue. The block loop never aborts.**

`parse_block` (§2, `crescent_slice_lower.lua` lines 762–786) iterates every
statement in the block and calls `parse_statement()` on each. When
`parse_statement` cannot handle a construct it returns an `{ k = "oos", … }`
node. `parse_block` adds that node to the list and continues to the next
statement — there is no `break` or early return. The only exception is a
`return` statement, which stops block scanning because that is a Lua rule, not
an OOS bail.

At the lowering level, `lower_block` (lines 2615–2673) loops over every
statement and calls `lower_stmt`. Inside `lower_stmt` (line 2039):

```lua
if k == "oos" then mark(lc, s); return end
```

`mark` appends a `LowerMarker` to `lc.markers`; then `return` exits only the
current call to `lower_stmt`. The `lower_block` loop continues with the next
statement. Identical early-return-after-mark behavior applies inside `synth_expr`
(line 1559):

```lua
if k == "oos" then mark(lc, e); return nil, nil end
```

This is purely local: returning `(nil, nil)` causes the *enclosing* statement
handler to abort that one statement (the pattern `if not vty then return end`
is pervasive in statement handlers), but does not abort sibling or outer-block
statements.

**Verdict: (b) — skip the individual OOS statement/expression and continue
lowering all remaining statements in all blocks.**

---

## Q2 — What an OUT-OF-SUBSET file produces

**Answer: the in-subset claims are still emitted and checked. OUT-OF-SUBSET
is a classification label, not a gate that suppresses output.**

`M.lower` (lines 2901–3049) runs the full pipeline unconditionally:
`lower_block` walks every statement and emits claims and evidence for every
in-subset node it can reach; OOS nodes append markers but do not stop the walk.
`lc.requested` accumulates the ids of every successfully-built claim throughout
the walk. At the end, `lower` classifies the verdict:

```lua
if has_construct then expected = "OUT-OF-SUBSET"
elseif has_finding then expected = "FINDINGS"
else expected = "CLEAN" end
```

`expected` is a label stored on the returned `LowerResult`. It does not filter
`lc.requested`. The survey's `survey_file_e2e` then calls `A.check` over the
full `res.requested` list (line 273 of `slice_survey.lua`):

```lua
local chk = A.check({ state = res.state, requested_claims = res.requested, … })
```

Every claim that was successfully built gets passed to the substrate checker
regardless of the file's class. The substrate returns per-claim
`accepted_claims`, `rejected_claims`, `unknown_claims` for all of them.

**Verdict: OUT-OF-SUBSET files still produce checkable claims for their
in-subset parts. The label only records that at least one construct tag was
hit; it does not zero out the output.**

---

## Q3 — Gap poisoning: `local x = <oos_expr>` then `x.f`

**Answer: `x` is left unbound (not added to ctx at all). Downstream uses of
`x` get an `unbound-name:x` marker and return `(nil, nil)`. They are not
`unknown`-typed, so the downstream check is aborted rather than checking against
`unknown`. The gap is sound but strict: no false accept or false reject is
produced; instead each downstream use of `x` becomes its own OOS marker.**

In `lower_stmt` for a `local` with one unannotated name (lines 2068–2089):

```lua
local vty, vcid = synth_expr(lc, ctx, val)
if not vty or not vcid then
    -- value out-of-subset (unannotated): stop binding (name unbound).
    return
end
-- unannotated: bind the synthesized type.
lc.requested[#lc.requested + 1] = vcid
ctx[#ctx + 1] = { name = name, type = TA.encode(vty) }
```

When `synth_expr` hits an OOS RHS it emits a marker and returns `(nil, nil)`.
The `local` handler returns without extending `ctx` — `x` is absent from the
typing environment.

Subsequently, any reference to `x` (`x.f`, `x + 1`, etc.) goes through
`synth_var_expr` (lines 1213–1228):

```lua
local ty = ctx_get(ctx, name)
if not ty then
    mark(lc, { line = 0, construct = "unbound-name:" .. name, text = name })
    return nil, nil
end
```

Each use emits its own `unbound-name:x` marker and returns `(nil, nil)`.
Callers of `synth_expr` that see `(nil, nil)` do the same: they mark and stop,
so the gap cascades upward through the expression tree without producing any
claim.

The exception is an *annotated* local (`--: T` before `local x = <oos_expr>`):
in that branch (lines 2059–2065) the handler calls `check_expr`, and even when
the check fails the name IS bound to the declared annotation type:

```lua
local _, caid = check_expr(lc, ctx, val, dt)
if caid then lc.requested[#lc.requested + 1] = caid end
ctx[#ctx + 1] = { name = name, type = TA.encode(dt) }
```

So an annotated local with an OOS RHS binds `x : T` (the annotation) and
downstream uses of `x` typecheck normally. This is the correct behavior: the
annotation is an explicit trust boundary.

**Verdict: unannotated `local x = <oos>` leaves `x` unbound; downstream uses
produce `unbound-name:x` markers (each a distinct OOS gap). No `unknown` type
is synthesized. An annotated local with an OOS RHS binds the annotation type
and downstream uses proceed.**

---

## Q4 — Per-claim/per-property output path

**Answer: yes, fully per-claim. The substrate's `CheckResult` has three
disjoint per-claim sets that cover exactly the requested ids, independent of
any whole-file status.**

`CheckResult` (defined at lines 373–379 of `lib/type/analysis/init.lua`):

```lua
--:: CheckResult = {
--::   accepted_claims: { [string]: Claim },
--::   rejected_claims: { [string]: Claim },
--::   unknown_claims: { [string]: Claim },
--::   …
--:: }
```

The substrate checker (lines 671–695) iterates `req.requested_claims` — the
list lowering accumulated into `lc.requested` — and routes each claim into
exactly one of the three sets based on its evidence outcomes. The OUT-OF-SUBSET
label on the `LowerResult` is not consulted; the substrate only sees claim ids
and evidence objects. Accepted, rejected, and unknown claims for all in-subset
parts of a partially-checked file survive in these sets and can be reported
independently ("error-class X caught at sites Y").

---

## Verdict

**Already per-property.** The slice checks everything it can reach in a file
and records each result as a separate claim in `accepted_claims`,
`rejected_claims`, or `unknown_claims`. OUT-OF-SUBSET is a summary label
(at least one construct-tagged marker was emitted), not a gate: all in-subset
claims are still produced, checked, and individually reportable.
