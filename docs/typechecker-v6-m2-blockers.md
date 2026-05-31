# Typechecker v6 M2 Blockers

This document records semantic decisions that block M2 function/call work. M1
can continue hardening around them, but M2 should not implement calls, returns,
or function body checking until these are pinned.

## Lua Pack Adjustment

Status: fixture-pinned, implementation blocking.

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

Fixture status:

- A `pack_adjustment_test.lua` fixture file with these cases as expected
  behavior now exists under `lib/type/static-v6/`. M1 still marks the cases
  unsupported instead of guessing adjustment.

## Union-Right And Overload Matching

Status: subtype-pinned, call implementation blocking.

Current subtype behavior accepts concrete `A <: B | C` if any branch accepts and
requires every producer branch in `A | B <: C` to satisfy the consumer. M2 calls
and M3 overloads must preserve this for argument checking:

- A concrete producer may satisfy a union consumer by matching one branch.
- A union producer must satisfy the consumer for every branch.
- For overload calls, collect every branch whose parameter pack accepts the
  argument pack; return the union of matching returns.
- Do not pick the first overload branch.

Fixture status:

- Subtype tests now pin concrete producers against union consumers and union
  producers against union consumers.
- Call-level fixtures are still required once function/call syntax is admitted.
- Tests showing ambiguous overload return union are still required once
  overloads exist.

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

Status: pinned for M1, implementation blocking for exports/modules.

Current M1 behavior emits `FEATURE_NOT_ADMITTED` and often returns `unknown` so
checking can continue. This is useful for multiple diagnostics, but it can leave
partial environment facts in failed results.

Pinned for now:

- If `ok == false`, exported environment facts are debugging artifacts only.
- No driver/module/cache layer may consume facts from a failed check.
- `source.check_string` exposes `facts_valid`; it is true exactly when `ok` is
  true.

Open before module/export work:

- Whether unsupported expressions should produce a poison type instead of
  `unknown`.
- Whether statements containing unsupported expressions should suppress binding
  installation.
- Whether partial facts should be hidden from public results when `ok == false`,
  rather than retained as debug artifacts behind `facts_valid == false`.

## Unsafe Boundary Severity

Status: pinned for v6 CLI; broader modes still open.

Current policy:

- Force casts record `unsafe_boundaries`.
- Force casts do not make `ok` false.
- Normal subtype use of `any` still fails with `UNSAFE_ANY_BOUNDARY`.
- `sound` and `facts_valid` are false when unsafe boundaries exist.
- The v6 CLI is strict-sound by default: unsafe boundaries are reported as
  `UNSAFE_BOUNDARY` and cause exit code 1.

Open before CLI:

- Whether future non-strict or audit-only modes should exist.
- Whether `ok` should remain "no hard failures" after v6 becomes the default, or
  whether default-mode naming should expose only `sound`.

## Unused Valid Annotations

Status: pinned for M1.

Current M1 policy:

- Malformed unused `--:` annotations are errors.
- `--::` declarations are errors because declarations are not admitted in M1.
- Valid unattached `--:` annotations are `ANNOTATION_NOT_ATTACHED` errors.
- Source-line annotation consumption is one-shot and global per check.
- Cast annotations are exempt from orphan-source checks because the parser stores
  them under synthetic negative keys consumed by `NODE_CAST_EXPR`.

Open before broader statement support:

- Whether future declaration forms need scoped annotation lookup beyond M1's
  one-shot source-line policy.

## M2 Entry Gate

M2 implementation may begin only after:

- pack adjustment fixtures exist;
- union-right call behavior is fixture-pinned;
- slot-claim assignment policy is accepted for functions;
- failed source checks are not used as module/export facts.

Initial M2 implementation scope:

- annotated function literals assigned to locals;
- annotated local function declarations with identifier names;
- exact fixed parameter arity;
- straight-line function bodies ending in an explicit `return`;
- fixed-arity monomorphic calls into known arrow values;
- expression-statement calls;
- no overloads, varargs, open packs, global function declarations, field/method
  function declarations, methods, or return-path analysis yet.
