# Typechecker v6 M2 Blockers

This document records semantic decisions that block M2 function/call work. M1
can continue hardening around them, but M2 should not implement calls, returns,
or function body checking until these are pinned.

## Lua Pack Adjustment

Status: blocking.

The pack constructor is structural only. Lua adjustment happens only at movement
sites. M2 must pin the movement-site matrix before implementing calls:

- `local a = f()` keeps only the first result of `f`.
- `local a, b = f()` expands `f` because it is the only and therefore final RHS.
- `local a, b = f(), g()` adjusts `f()` to one result and expands `g()`.
- `g(f())` expands `f()` only because it is the final argument.
- `g((f()))` collapses `f()` to one result.
- `return f(), g()` adjusts `f()` to one result and expands `g()`.
- missing values nil-pad only at Lua movement sites that actually pad.
- explicit nil positions in packs must not collapse.

Required before code:

- A `pack_adjustment_test.lua` fixture file with these cases as expected
  behavior, even if initially marked unsupported by the source checker.

## Union-Right And Overload Matching

Status: blocking.

Current subtype behavior accepts `A <: B | C` if any branch accepts. M2 calls
and M3 overloads need this pinned for argument checking:

- A concrete producer may satisfy a union consumer by matching one branch.
- A union producer must satisfy the consumer for every branch.
- For overload calls, collect every branch whose parameter pack accepts the
  argument pack; return the union of matching returns.
- Do not pick the first overload branch.

Required before code:

- Tests showing union arguments to monomorphic calls.
- Tests showing ambiguous overload return union, once overloads exist.

## Mutable Binding Assignment

Status: partially pinned for M1, blocking before flow.

M1 policy:

- A binding has a slot claim.
- An assignment checks `producer <: slot claim`.
- Assignment does not update the slot claim.
- Annotated local binding installs the annotation claim only after proof.
- Unannotated local binding installs the initializer claim.

Open before flow:

- Whether flow facts may narrow a mutable binding after assignment.
- Whether assignment creates a current-value flow fact distinct from the slot
  claim.
- Whether unannotated mutable locals should be widened at first assignment, or
  require annotation when mutation changes type.

M2 may proceed with the M1 slot-claim policy for parameters and locals, but flow
must not be built until the current-value/slot distinction is explicit.

## Unsupported Expression Recovery

Status: blocking for exports/modules.

Current M1 behavior emits `FEATURE_NOT_ADMITTED` and often returns `unknown` so
checking can continue. This is useful for multiple diagnostics, but it can leave
partial environment facts in failed results.

Pinned for now:

- If `ok == false`, exported environment facts are debugging artifacts only.
- No driver/module/cache layer may consume facts from a failed check.

Open before module/export work:

- Whether unsupported expressions should produce a poison type instead of
  `unknown`.
- Whether statements containing unsupported expressions should suppress binding
  installation.
- Whether partial facts should be hidden from public results when `ok == false`.

## Unsafe Boundary Severity

Status: blocking before CLI/default mode.

Current policy:

- Force casts record `unsafe_boundaries`.
- Force casts do not make `ok` false.
- Normal subtype use of `any` still fails with `UNSAFE_ANY_BOUNDARY`.

Open before CLI:

- Whether unsafe boundaries are warnings, errors, or audit events per mode.
- Whether `ok` should mean "sound with no unsafe boundaries" or "no hard
  failures".

## Unused Valid Annotations

Status: blocking before broad source support.

Current M1 policy:

- Malformed unused `--:` annotations are errors.
- `--::` declarations are errors because declarations are not admitted in M1.
- Valid unattached `--:` annotations are ignored.

Open before broader statement support:

- Whether valid unattached annotations should be warnings/errors.
- Whether annotation consumption should be one-shot globally or scoped per
  declaration form.

## M2 Entry Gate

M2 implementation may begin only after:

- pack adjustment fixtures exist;
- union-right call behavior is fixture-pinned;
- slot-claim assignment policy is accepted for functions;
- failed source checks are not used as module/export facts.
