# Decision: why crescent does not use an external Lua typechecker

**Status:** resolved — June 2026  
**Evaluated:** LuaLS/sumneko, Teal, Luau, EmmyLua / emmylua-analyzer-rust  
**Verdict:** external checkers are suitable as editor tooling; they are not suitable
as crescent's checker. The checker is load-bearing for the ecosystem's capability
posture, and that is the precise property the external tools lack by design.

---

## The load-bearing requirement

Crescent's no-ambient-globals rule is not a style preference — it is the
foundation of two guarantees the ecosystem depends on:

1. **Capability visibility.** If `os`, `io`, `print`, `require` are ambient, every
   library implicitly holds every capability and the typechecker cannot distinguish
   a library that reads `os.time()` from one that doesn't. Making the stdlib a set
   of explicit declarations lets the checker surface, per file, which capabilities
   are actually claimed.
2. **No silent widening.** An ambient-global system must decide what an undeclared
   name resolves to. The two options are "error" or "widen to a top type." Real
   ambient checkers pick widening because erroring on every typo is too noisy when
   the stdlib is implicit — and that choice leaks: undeclared names become a soft
   escape hatch from soundness.

Full rationale: `docs/type-system.md` §14 ("No ambient globals").

The external tools all fail on requirement (2). They are ambient by architecture
(LuaLS) or require a dialect migration to enforce it at all (Teal, Luau). The
annotation syntax argument is additive: `--:` / `--::` is crescent's single
annotation syntax; LuaCATS/EmmyLua forms are forbidden in `lib/` because they are
a second source of type truth that can drift from the actual implementation and
cannot be consumed by the checker. Full rationale: `docs/stdlib-design.md`
§"Why `--:` not EmmyLua".

---

## Per-tool findings (June 2026)

### LuaLS / sumneko

The maintainers explicitly disclaim building a full type system. From the official
docs (<https://luals.github.io/wiki/type-checking/>):

> "The intention with the type checking in the language server is to not implement
> such a type checking system [like TypeScript]."

The engine treats `any`/`unknown` as universally compatible on both sides;
unannotated code never errors. This is documented in the DeepWiki analysis of
`vm/type.lua` (<https://deepwiki.com/LuaLS/lua-language-server/3.4-type-checking-and-validation>).

**Verified open soundness gaps at max strictness** (all open as of June 2026):

- `string|nil` passed to a `string` parameter yields no diagnostic even with
  `weakNilCheck=false` and `type-check=Error`
  (<https://github.com/LuaLS/lua-language-server/issues/3226>, filed 2025-07,
  unanswered).
- Generic inference from multiple returns silently fails
  (<https://github.com/LuaLS/lua-language-server/issues/3007>).
- Generics "super issue" open since 2023 with 15 sub-issues
  (<https://github.com/LuaLS/lua-language-server/issues/1861>).

**Fairness note:** LuaLS CAN error on undeclared globals project-wide
(`diagnostics.groupSeverity.global=Error`). That addresses the capability-erosion
axis but not the silent-widening axis — the engine widens silently in other
positions regardless of that setting.

**Annotation syntax incompatibility.** As of June 2026, 779 files under `lib/`
use crescent `--:` / `--::` syntax. LuaCATS adoption would mean a second type
truth, already rejected when `.d.lua` sumneko-syntax files were migrated away.

No HKT, no match/conditional types, no effect annotations in LuaCATS.

### Teal

Typed dialect (.tl files). Vanilla `.lua` files are handled only in lax mode
(warnings, not errors). Real checking requires migrating the entire codebase to
the `.tl` dialect
(<https://github.com/teal-language/tl/blob/main/CHANGELOG.md>).
Not viable for a `.lua`-first project.

### Luau

Dialect and analyzer tied to the Roblox stdlib and runtime semantics; no LuaJIT
FFI or `bit` types without bespoke definitions (<https://luau.org/>).

Luau is deliberately unsound — Jeffrey (HATRA 2023) frames gradual typing as
type-error *suppression*, and the telemetry shows ~100× more untyped than typed
sessions in the Roblox population. Detailed in
`docs/typechecker-v5-research-report.md` §Luau.

### emmylua-analyzer-rust / emmylua_check (v0.23.x)

The strongest external candidate at time of evaluation: actively developed,
LuaJIT-aware, ships a CI-suitable CLI
(<https://github.com/EmmyLuaLs/emmylua-analyzer-rust>).

Two reasons it cannot replace `lib/type/static/`:

1. LuaCATS syntax — the annotation incompatibility described above applies here
   as well.
2. Narrowing and generics depth vs. crescent's checker is unbenchmarked on the
   `lib/` corpus; the capability-posture property is not a stated goal of the
   project.

Recorded as a possible *supplementary* second-opinion lint layer in the future,
not a replacement.

---

## Current status of the ecosystem

`lib/type/static/` is the operational checker; it gates commits today via the
`.githooks/pre-commit` hook (per-file staged-vs-HEAD error-regression check).
The agnostic analysis track (`lib/type/analysis/`, `docs/agnostic-static-analysis-*.md`)
is the next-generation substrate under active design.

"Is the ecosystem blocked on a typechecker" (no — `lib/type/static/` is operational)
and "is the successor ready" (not yet — the analysis track is still in design) are
different questions. This document settles only the first.

---

## Re-evaluation triggers

This decision is falsifiable. Revisit if:

- LuaLS or a successor adopts a sound strict mode as an explicit goal and closes
  the nil-check and generic-inference gaps above.
- `emmylua_check` demonstrates narrowing/generics depth comparable to
  `lib/type/static/` on a benchmarked `lib/` corpus.
- Crescent abandons the no-ambient-globals posture (would remove the load-bearing
  requirement and open the door to external tooling as a primary checker).
