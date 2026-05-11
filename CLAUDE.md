# CLAUDE.md

Behavioral rules for Claude Code in the crescent repository.

## Project Overview

Crescent is an operating system in Lua — a zero-dependency, vendoring-first ecosystem that covers the entire surface area of software. Not just stdlib basics: connection protocols, parsers, codecs, game primitives, package management, typechecking, all of it, as pure Lua libraries you own outright.

`git clone` and run. No installs, no build steps. LuaJIT binaries for all supported platforms are vendored in `bin/`. Dependencies are committed, not fetched.

The design is deliberately infectious: every library is copy-paste-ownable. Vendor it into your project, and it's yours — no upstream to break you, no version negotiation, no hidden coupling. This is what vendoring-first means: the unit of reuse is source you control, not a package you depend on.

Monorepo inspired by [thi.ng/umbrella](https://thi.ng/umbrella): one repo, one vision, composable pieces. Libraries are independent by design — each a directory under `lib/` with its own tests, types, and docs alongside the code.

Part of the [rhi ecosystem](https://rhi.zone).

### Scope

Crescent's ambition is the entire surface area of software, not just stdlib basics. If a concept exists as a Rust crate in the rhi ecosystem (or as a library anywhere), and it can be implemented in pure Lua with acceptable LuaJIT performance, it belongs in crescent. Connection protocols, structural analysis, expression evaluation, game primitives, grammar parsing, format conversion — all of it, as pure Lua libraries.

The Rust projects in the rhi ecosystem and the crescent libraries are parallel implementations of the same concepts, each first-class in their own ecosystem. This is not "Rust for the real thing, Lua for the toy version" — LuaJIT is fast enough that both are real implementations. The distinction is ecosystem, not performance.

**Crescent is not a language.** It has no syntax of its own beyond type annotations in comments (`--:`, `--::`). There is no transpiler, no compilation step. Code is standard Lua executed directly by LuaJIT. Do not propose "language-level" solutions that would require new syntax or a transpiler — the answer is always a library.

## Architecture

```
lib/          — all packages (http, websocket, dns, sqlite, fs, ljsocket, ...)
lib/type/     — typechecker (parses LuaJIT FFI cdefs)
lib/pkg/      — package manager
lib/test/     — test runner
lib/crescent_examples/ — small scripts demonstrating crescent (not a library)
lib/cli/      — CLI arg parsing library (future)
doc/          — documentation
```

**Every package is a directory** under `lib/` with an `init.lua` entry point. This gives each package room for LICENSE, tests, type definitions, and docs alongside the code. LuaJIT doesn't include `?/init.lua` in the default `package.path` (that's a Lua 5.2+ default), so entry points must conditionally add `./?/init.lua` to `package.path` (check before adding — Lua 5.2+ already includes it, and multiple entry points may be composed).

## References

Pointers to conditional context — read on demand, not loaded by default.

- `.github/workflows/build-vendored.yml` — produces `bin/luajit*`, `bin/ld-musl-*`, `dep/libsqlite3*`, `dep/libz*`. Triggered via `workflow_dispatch`; commits artifacts back to the repo.
- `.github/workflows/ci.yml`, `.github/workflows/ci-full.yml` — test CI.
- `.github/workflows/deploy-docs.yml` — docs site deploy.
- `bin/cr` — platform dispatch into vendored LuaJIT (Linux: loader + `luajit-bin`; macOS: native binary; Windows: `cr.bat`/`cr.ps1`).
- `flake.nix` — contributor dev shell only (bun for docs); not a runtime dependency.
- `docs/conventions.md`, `docs/batteries.md`, `docs/inventory.md`, `docs/inventory_summary.md` — already referenced elsewhere in this file.

## Development

```bash
bin/cr test                  # Run tests
bin/cr check <file>          # Typecheck a file
bin/cr check --summary <file>  # Root-cause-grouped error summary (use this first when diagnosing why a file has errors)
cd docs && bun dev           # Local docs (requires bun)
nix develop                  # Dev shell for contributors (bun, etc.)
```

## Core Rules

**Do the right thing, don't hedge.** When the correct approach is clear, implement it. Amount of work is never a reason to do something worse.

**"Pragmatic" is not a category. It is a euphemism for wrong.** When the correct type is `integer | nil` and callers don't handle the nil case, the callers are wrong — not the type. Choosing an incorrect type signature to avoid fixing callers is context poisoning: every future session sees the wrong type, builds on it, and the error compounds. The regressions caused by a correct fix are work to be done, not a reason to revert to an incorrect solution. Never propose "pragmatic but slightly unsound" as an option — it is not an option. If a fix is correct, ship it and fix the consequences.

**No half-measures.** A design that requires X to be safe must ship with X. Implementing the unsafe version "for now" and deferring X is not a step toward the right design — it's a lie that accumulates. If X is hard, do X. If X is genuinely separable (the current code is correct without it, not just less capable), say so explicitly and put it in TODO.md. "We'll add it later" with no TODO entry means it never happens.

**"Out of scope" is not a reason to omit.** Scope is not a budget for correctness. If a security property, invariant, or design constraint applies to the thing being built, it is in scope by definition. Deferring it because it's inconvenient is not scoping — it's avoidance. The only legitimate reason to omit something is that it genuinely does not apply yet (no caller, no user, no data). That reason must survive scrutiny: if challenged, justify it, don't just re-assert it.

**Write things down immediately.** Problems and tech debt → TODO.md. Design decisions → docs/ or CLAUDE.md. Completed items → mark `[x]` in TODO.md in the same commit. Conversation evaporates — if it matters to a future session, write it now. Never delete unchecked TODO items.

**`docs/batteries.md` is the definitive ecosystem scope document.** Read it before discussing future libraries or roadmap.

**`docs/inventory_summary.md` is loaded at session start** — it lists what categories of library exist in crescent and roughly what's in each. Read it. **`docs/inventory.md` is the full per-library index** — grep it before designing or implementing anything reusable. If `inventory.md` doesn't list what you're looking for, spot-check `lib/` directly; the index can lag by a commit. **When adding a new library or `_types.lua` file, add a line to `docs/inventory.md` in the same commit. Add a line to `docs/inventory_summary.md` only if the new library belongs to a category not already there.**

**Corrections mean a rule is missing or wrong.** When the user corrects you, ask what rule would have prevented it and write it before proceeding. "The rule exists, I just didn't follow it" is never the diagnosis.

**Something unexpected is a signal, not noise.** Stop and ask why before continuing.

**Don't add type aliases that legitimize laziness.** When N annotations fail because they used a vague type name (`table`, `function`, `any`), the fix is to correct each annotation to a specific type — not to add a permissive alias that makes them "pass". The errors are the typechecker doing its job; suppressing them by widening the type system silently accepts wrong code. Same family of mistake as `any` proliferation: reducing the error count is not the goal, accuracy is. If a type alias would change a strict check into a permissive one, do not add it.

**Lua code must not regress typechecking before commit.** The pre-commit hook in `.githooks/pre-commit` enforces this — to activate it, run `git config core.hooksPath .githooks` once per clone (the repo does not auto-activate hooks for safety). For each staged `lib/**/*.lua` file the hook runs `timeout 30 bin/cr check <file>` on both the staged blob and the `HEAD` blob and rejects the commit only when the staged version has MORE errors than `HEAD` (or when a new file has any errors). Pre-existing errors in a file you happen to edit are tolerated. Timeouts always reject. Do not bypass with `--no-verify` — fix the new error or fix the hook.

**Confident assertions require proof of work.** Assert confidently only after (1) adversarially reasoning through every plausible alternative and showing each is inferior, AND (2) verifying no downsides to the assertion. If either step is incomplete, say "I don't know" or state an explicitly-flagged hypothesis — then the immediate next step is to verify, not to hedge-word a guess into sounding like knowledge.

Context is poisoned the moment you confidently state something wrong. Retraction does not fully undo it; downstream reasoning is already shaped by the bad claim. Prevention is the only real mitigation — rules that fire after the assertion cannot recover it.

## Library Conventions

See `docs/conventions.md` for the full spec. Short version:
- Errors: `(nil, errmsg)` return, never throw from data errors
- Codecs: `string_to_foo`/`foo_to_string` as primary names (type-in-the-name); `encode`/`decode` always aliased for swappability
- Protocols: `connect` / `send` / `recv` / `close` — transport injected via opts, never created internally
- Tiers: system > FFI > pure Lua, selected at load time, each independent, `M._tier` for introspection
- Annotations: `--:` / `--::` only. `unknown` = TS `unknown` (caller must narrow). `any` = TS `any` (opt-out). Prefer `unknown`; `any` only when explicitly opting out and documented why.
- **Casts: `--[[: T]]` is the checked cast (full subtyping required). `--[[:! T]]` is the overlap-checked force cast — it is almost never correct. If `unknown` can't be narrowed with a type guard (`if type(x) == "string"`, discriminant check, etc.), the upstream producer has the wrong type annotation. Fix the producer. If `A | B` can't be narrowed to `A` with a discriminant check, that is a typechecker bug to fix. A force cast that papers over either case is wrong. `--[[:! any]]` is rejected — use `--[[: any]]` if you genuinely need an any cast.**
- **`...` vs index signatures** — these are distinct. `...` is a structural subtyping marker: `{ name: string, ... }` accepts any table with at least `name`. It says nothing about reading arbitrary fields. `{ [string]: T }` is an index signature: any string key maps to `T`. Confusing them leads to open types on concrete data objects (wrong) or expecting arbitrary field reads to work on `...`-typed values (also wrong).

## Typechecker quick reference (learnxinyminutes style)

Before claiming a feature is missing: write a 5-line repro and run `timeout 30 bin/cr check <file>`. Every feature below is implemented, tested, and in active use.

### Annotation syntax

```lua
local x --: integer                   -- inline: annotates the local declaration
--: (string, integer) -> boolean      -- function type (preceding line → applies to next expr/function)
-- To annotate params: use preceding-line function type (only supported form).
-- WARNING: `function(x --: string)` is INVALID — `--` starts a line comment, eating `)` and beyond.
-- WARNING: `function(x --[[: string]])` is also INVALID — block comment form is parsed as a cast, not a param annotation; silently ignored in param position.
--:: Foo = { name: string, age: integer }  -- type alias declaration
--:: declare x = integer              -- global variable declaration
--:: newtype UserId = integer         -- nominal newtype (not assignable to/from integer)
--:: module "mylib": { foo: string }  -- declares what require("mylib") returns
--:: augment string { upper: () -> string }  -- merges fields into an existing type binding
--:: template                         -- marks next function as a generic template (advanced)
```

### Primitive types

```lua
--: integer   -- LuaJIT integer (32-bit range for literals; promotes to number ops)
--: number    -- any number (integer or float)
--: string
--: boolean
--: nil
--: never     -- bottom type; no value inhabits it; union member is dropped
--: unknown   -- top type; caller must narrow before use (like TS unknown)
--: any       -- opt-out of checking (like TS any); use only when explicitly documented why
--: cdata     -- LuaJIT FFI cdata value
```

### Literal types

```lua
--: "heading"    -- string literal type
--: 42           -- integer literal type (integer-valued floats auto-promoted)
--: 3.14         -- float literal type
--: true         -- boolean literal type
```

Literal types are subtypes of their base type: `42 <: integer <: number`.

### Table types

```lua
-- Closed record: exactly these fields
--: { name: string, age: integer }

-- Optional field (field may be absent or nil)
--: { name: string, age?: integer }

-- Readonly field
--: { readonly id: integer, name: string }

-- Open record: at least these fields; additional fields permitted
--: { name: string, ... }
-- Reading an unlisted field on { ..., ... } returns unknown (NOT the indexer type)

-- Index signature: any key of that type maps to the value type
--: { [string]: integer }
--: { [integer]: string }

-- Mixed: named fields + indexer
--: { [integer]: string, n: integer }

-- Array sugar (postfix [])
--: string[]            -- equivalent to { [number]: string }
--: Arr<string>         -- equivalent to { [integer]: string, ... } (stdlib alias)

-- Meta slots (metamethods)
--: { name: string, #__add: (self: unknown, other: unknown) -> unknown }

-- Meta-spread (inherit all meta slots from another type)
--: { name: string, #...MT }
```

`...` and `{ [K]: V }` are distinct. `{ name: string, ... }` does NOT mean any string key maps to any type — that is `{ [string]: unknown }`.

### Function types

```lua
--: () -> nil                        -- no params, no return
--: (string) -> integer              -- one param, one return
--: (string, integer) -> boolean     -- two params
--: (name: string, age: integer) -> boolean  -- named params (for predicate syntax)
--: (string, ...integer) -> nil      -- varadic: last param ...T means zero or more T
--: () -> (string, integer)          -- multiple returns
--: () -> ...(T)                     -- multi-return spread (T may be a tuple type alias)
--: string -> integer                -- right-associative bare arrow (curried sugar)
--: function                         -- any function (untyped)
```

Multi-return union: `(A) -> B | (C) -> D` parses as `(A) -> (B | (C) -> D)`. Wrap: `((A) -> B) | ((C) -> D)`.

### Union and intersection

```lua
--: string | nil          -- union (|)
--: A & B                 -- intersection (&): must satisfy both
--: (A -> nil) & (B -> nil)  -- overloaded function (intersection of functions)
```

Field access on union: only fields present in ALL members are accessible without narrowing.
Field access on intersection: a field present in ANY member is accessible.

### Generics

```lua
-- Basic generic function
--: <T>(T) -> T

-- Constrained generic (T must structurally satisfy the bound)
--: <T: { name: string, ... }>(T) -> T

-- Multiple type params
--: <T, U>(T, U) -> T

-- Generic alias with params
--:: Pair<A, B> = { first: A, second: B }

-- Generic alias with bounds and defaults
--:: MyAlias<T: Bound, U = string> = { key: T, val: U }
```

Type params are instantiated independently per call site. No explicit instantiation syntax — the checker infers from arguments.

### Casts

```lua
local x = expr --[[: T]]    -- checked cast: T must be a supertype of expr's type
local x = expr --[[:! T]]   -- force cast: overlap-checked; almost never correct.
                             -- If unknown: fix the upstream producer's type annotation.
                             -- If A|B → A: use a discriminant check; if that fails, fix the typechecker.
                             -- A force cast that substitutes for either is wrong.
-- --[[:! any]] is REJECTED. Use --[[: any]] if you genuinely need an any cast.
```

### Narrowing forms

All forms the checker recognizes in `if`/`while`/`repeat` test position:

```lua
if x then end                    -- nil_check: x is non-nil in truthy branch
if x ~= nil then end             -- nil_check (explicit)
if x == nil then end             -- nil_check (negative)
if type(x) == "string" then end  -- type_check: narrows to string
if type(x) == "number" then end  -- type_check: narrows to number
if type(x) == "table" then end   -- type_check: narrows to table type
if x == "literal" then end       -- lit_eq: narrows to literal type
if x == 42 then end              -- lit_eq: narrows to integer literal
if x == true then end            -- lit_eq: narrows to boolean literal
if x.field then end              -- field_presence: x.field is non-nil in truthy branch
if x.field == "val" then end     -- field_disc: discriminated union narrowing (literal only!)
if x.field == 42 then end        -- field_disc: numeric discriminant
if x == Enum.Member then end     -- enum_eq: narrows to enum member type
if is_str(x) then end            -- guard_check: user-defined type predicate (see below)
if not x then end                -- negation: inverts any narrowing above
if a and b then end              -- and: both narrowings apply in truthy branch
if a or b then end               -- or: either narrowing
```

Discriminant-field narrowing requires a **literal** discriminant field type. `type: string` cannot be narrowed; `type: "heading"` can. **Aliasing to a local does NOT narrow the object:** `local t = x.field; if t == "v" then` narrows `t`, not `x`.

### Type predicates and assertion functions

```lua
-- Type predicate: narrows the argument in the caller's scope
--: (x: unknown) -> x is string
local function is_str(x) return type(x) == "string" end

-- Assertion function: asserts x is T or throws (narrows after the call)
--: (x: unknown) -> asserts x is string
local function assert_str(x)
  if type(x) ~= "string" then error("expected string") end
end
```

### Match types

```lua
--:: ReturnOf<F>    = match F { () -> %R => R }               -- extract return type
--:: ParamOf<F>     = match F { (%P, ...any) -> any => P }    -- extract first param type
--:: ParamsOf<F>    = match F { (...%P) -> any => P }         -- all params as tuple
--:: Tail<F>        = match F { (any, ...%P) -> any => P }    -- params after first

-- Table field distribution (result is a union of the expression per field)
--:: Keys<T>        = match T { { ...[%K]: %V } => K }
--:: Values<T>      = match T { { ...[%K]: %V } => V }
--:: PairsReturn<T> = match T { { ...[%K]: %V } => (K, V) }

-- Conditional type
--:: IsString<T>    = match T { string => true, _ => false }

-- Pattern captures use %Name in pattern position, bare Name in result position
-- _ is a wildcard (always matches, no binding)
-- Bare names in pattern position are concrete type lookups (error if not in scope)
```

`match` arm patterns: primitives, unions, intersections, function types `() -> %R`, `(...%P) -> T`, `(A, ...%P) -> T`, table types `{ field: T }`, `{ [K]: %V }`, `{ ...[%K]: %V }`, `{ field: T, ...%Rest }`, `{ #...%M }`.

### Tuple and spread types

```lua
--:: PcallReturn<F> = match F { (...%P) -> %R => (true, ...R) | (false, string) }
-- (true, ...R): spreads R's elements into the tuple position.
-- R = integer        → (true, integer)
-- R = (A, B)         → (true, A, B)
-- R = never (void)   → (true)
```

### Stdlib built-in aliases (no import needed)

```lua
Arr<T>           -- { [integer]: T, ... }
Ptr<T>           -- T & { [0]: T }
Ctype<T>         -- $Opaque<T> (FFI ctype wrapper)
PairsReturn<T>   -- match T { { ...[%K]: %V } => (K, V) }
IpairsReturn<T>  -- match T { { ...[%K]: %V } => match K { number => (integer, V), _ => never } }
Keys<T>          -- match T { { ...[%K]: %V } => K }
Values<T>        -- match T { { ...[%K]: %V } => V }
Open<T>          -- match T { { ...%Rest } => { ...Rest, ... } }   (open version of T)
Closed<T>        -- match T { { ...%Rest } => { ...Rest } }        (closed version of T)
MetaOf<T>        -- match T { { #...%M } => M, _ => nil }         (metatable type)
```

### Permanent intrinsics ($-prefixed)

```lua
$Require<T>          -- module system; needs literal type propagation through generics
$Opaque<T>           -- nominal identity; $Opaque<T, U> with optional exposed view U
$Opaque<T, U>        -- opaque with view: external sees U, internal treats as T
$FfiC                -- closed table built from ffi.cdef(...) call sites in the file
-- ffi.C is typed as $FfiC: symbols declared via ffi.cdef ARE typed; undeclared symbols
-- are errors. FFI-heavy files are fully typecheckable — ensure all used C symbols have
-- cdef declarations and the typechecker infers their types. Do NOT claim FFI code is
-- "untyped" or "untypeable" — that is wrong. Missing types = missing cdef declarations.
$GlobalScope         -- closed table mirroring all --:: declare globals; used for _G
$Throw<T>            -- type-level error (diagnostic side effect)
$Catch<T, Default>   -- type-level pcall; returns Default if T throws
$EachField<T, F>     -- per-field flatMap with flag access; F is a named alias
$PatternReturn<P>    -- return type of string.match/gmatch given literal pattern P
$FindReturn<P>       -- return type of string.find given literal pattern P
```

Do not add new `$` intrinsics — extend `match` patterns instead.

### Indexed access types

```lua
--:: T = { name: string, age: integer }
--:: Name = T["name"]   -- string (indexed access into a table type by string literal key)
--:: Val  = Arr<integer>["n"]  -- integer (index into named field)
```

### Newtype (nominal types)

```lua
--:: newtype UserId = integer
-- UserId is NOT assignable to integer and vice versa.
-- Use --:: unseal UserId to rebind to inner type in a scope.
```

### typeof

```lua
local point = { x = 0.0, y = 0.0 }
--:: PointType = typeof point   -- captures inferred type of `point` binding
```

### ANN_TYPE_ARGS (explicit type instantiation at call site)

```lua
local x = f() --:<integer>   -- force-instantiate generic f with T=integer
```

## Implementation Patterns

**When one implementation can't satisfy all legitimate use cases, provide multiple and let the caller choose.** This takes two forms:

- **Performance tiers** — same interface, different speed. E.g. FFI + system library > FFI scalar > pure Lua. Select the best available at load time via `pcall`. Never fail hard when a faster tier is unavailable — fall through to the next. Never silently use a slow tier without the faster ones being attempted first.
- **Interface variants** — same data, different access patterns. E.g. ergonomic (returns strings) vs zerocopy (returns positions). Provide both with clear names; the caller picks. Do not resolve the tradeoff by imposing one choice on all callers — that makes the wrong choice someone else's permanent problem.

In both cases: never wrap one implementation around another. Each is a real, independent implementation. Abstraction between tiers or variants destroys hackability.

**Don't degrade runtime to surface CI gaps.** If a graceful fallback could mask a regression in the preferred tier, the fix is a CI assertion that the preferred tier took effect (`M._tier == "vendored"`, etc.) — not removing the fallback. Fallbacks exist for users on configurations you don't test; removing them shifts the cost from CI (fixable, observable) to user laptops (invisible, permanent). "We'll notice when it breaks" is not a reason to take away graceful behavior.

**Multiple implementations of the same spec require parity tests, parity fuzzing, and benchmarks.** This applies any time two implementations claim to satisfy the same spec — performance tiers, a reference impl and an optimized one, a pure-Lua and an FFI version, a stub and the real thing. Parity tests assert byte-for-byte identical output. Parity fuzzing generates random inputs and runs all implementations, catching edge cases unit tests miss. Benchmarks measure each implementation on representative inputs and results are committed to `docs/perf/log.md`. None of this is optional polish — the implementation is not done until all three exist.

**Fix the specific problem, don't abandon the approach.** When an objection applies to one aspect of a design, fix that aspect. Platform-specific library names → try each known name. Library missing → fall back to next tier. These are implementation details, not architectural blockers. Discarding a whole approach because of a fixable problem is a cop-out.

**Derive from values, not from precedent.** When designing interfaces or making architecture decisions, start from crescent's values (vendorable, pure, fast, hackable, composable). Don't reach for what Java/Go/Rust/TypeScript does — their designs embed assumptions that don't apply here. Other ecosystems are references, not templates.

**Abstraction has a cost.** Wrappers, layers, and indirection reduce hackability and readability. Every abstraction needs justification beyond "it seems cleaner." A direct implementation that is longer is often better than an indirect one that is shorter.


**No gradual migrations.** When a design decision changes the convention (e.g. "libraries must not use `os`/`io` globals, accept injected functions instead"), apply it to the entire codebase in one pass. A half-migrated codebase is context poisoning: every future session encounters both the old and new pattern, wastes time figuring out which is canonical, and risks propagating the wrong one. If the migration is too large to do at once, that's a signal to reconsider the design, not to spread the migration across sessions.

**This applies to CLAUDE.md conventions too.** Partial adoption of a new local CLAUDE.md structure, a new naming rule, or any new convention is worse than not adopting it at all. An agentic AI encountering two conflicting conventions will confidently follow the wrong one. Do the whole thing or don't start.

**Capability-based I/O.** Libraries must not reach for `os`, `io`, or other global side-effect modules directly. Instead, accept I/O functions as parameters (constructor opts, function args). This is the foundation of sandbox safety: if a library grabs `os.time()` from a global, it can't run in a capability sandbox. If it accepts a `time_fn` parameter, the caller decides what time source to provide — or whether to provide one at all. This applies to ALL libraries, not just platform app code.

**Caps-first, everywhere.** Every library that performs I/O must accept its dependencies as injected caps, not import them from globals. "This runs outside the sandbox so it's fine" is never a justification for skipping injection. **Defaulting to globals is also a violation** — `opts.popen or io.popen` reaches for `io` just as directly as `io.popen` alone. If a cap is not injected, error; do not silently fall back to the global.

## Design Principles

**This repository is zero-dependency.** A user must be able to `git clone` and run immediately with no external installs — no package manager, no compiler, no runtime. LuaJIT binaries for all supported platforms are vendored in `bin/`. "Use Nix" or "install LuaJIT" are not acceptable answers. NixOS, musl, Alpine, and every other Linux variant are first-class targets. LuaJIT can't be statically linked (FFI needs `dlopen`), so the approach is: build against musl, vendor the matching loader alongside (`bin/ld-musl-*.so.1`), and invoke via the loader explicitly so the host's `/lib/ld-*` is irrelevant. `bin/cr` is the canonical entry point. `bin/luajit` and `bin/luajit-aarch64` are shell shims that exec the real ELFs (`bin/luajit-bin`, `bin/luajit-aarch64-bin`) through the vendored loader; the shims exist so anything that resolves bare `luajit` from PATH (the dev shell adds `$PWD/bin` to PATH) still works.

**Non-ubiquitous FFI dependencies must be vendored as compiled binaries in `dep/`.** `bin/cr test` must pass on a bare clone with no system libraries installed. If FFI code requires a library that isn't part of libc (sqlite3, etc.), compile it from its official source and commit the result to `dep/` for each supported platform — the sqlite3 amalgamation (`sqlite3.c`) is the model: one C file, compiles anywhere, no exotic deps. The nix dev shell (`buildInputs`) is for contributor tooling (bun, docs), not runtime dependencies — it is not a substitute for vendoring.

**Pure Lua is the baseline and must always work standalone.** No library may hard-depend on a system lib or vendored C lib being present. Ubiquitous system libs (libc, etc.) are an optional performance tier. Non-ubiquitous system libs require a pure Lua fallback. Vendored C libs are a last resort when pure Lua is genuinely nonviable for performance reasons. Nothing requires an external install step — must work on a barebones system.


**Target LuaJIT, don't require it.** Optimise for LuaJIT performance (avoid allocations in hot paths, prefer tables over closures, measure before and after) but pure Lua code must not depend on LuaJIT quirks — it should work on standard Lua if it doesn't sacrifice performance.

**Tooling performance bar: bun (general), tsgo for the typechecker.**


**Libraries must work on Linux, macOS, and Windows** unless they explicitly wrap a platform-specific API. Don't assume a single OS.

**Keep coupling low.** A change should require understanding only the local module to reason about correctly. If making a change requires understanding five other modules, that's an architectural smell. Low coupling also means local LLM context is sufficient — high coupling makes correct edits structurally impossible regardless of context window size.

**Never duplicate type definitions.** The typechecker reads FFI cdefs directly. Don't define types separately from cdefs.

## Workflow

**Run the typechecker on files you write or modify.** `bin/cr check <file>...` — do this before committing. See `lib/type/static/CLAUDE.md` for annotation syntax and type system rules. **When diagnosing why a file has many errors, run `bin/cr check --summary <file>` first** — it groups errors by root cause (unresolved requires, cascading unknowns, etc.) and is far more informative than piping raw output through grep/sed.

**Always run typecheck under a timeout.** Single file: `timeout 30 bin/cr check <file>`. Repo-wide: `timeout 120 bin/cr check ...`. A typecheck that exceeds these limits is hanging, not slow — there is a soundness or termination bug somewhere (occurs-check, union-find self-loop, exponential expansion). When this happens, **stop other work immediately**. Two options for subagents:
1. **Hand back to the orchestrator** — return a minimal report ("typecheck hung on <file>; aborting to keep context clean") so a fresh subagent can investigate without your accumulated context.
2. **Investigate inline only if the current task is itself typechecker work** — i.e. you were already in `lib/type/static/` and have the relevant context. Otherwise option 1.

Never silently work around a hang (skip the file, longer timeout, batch differently). The hang is the signal; suppressing it poisons every future session that encounters the same code path.

**Minimize file churn.** When editing a file, read it once, plan all changes, and apply them in one pass.

**`normalize view` is available** for structural outlines of files and directories:
```bash
~/git/rhizone/normalize/target/debug/normalize view <file>    # outline with line numbers
~/git/rhizone/normalize/target/debug/normalize view <dir>     # directory structure
```

**Always commit completed work.** After tests pass, commit immediately — don't wait to be asked. When a plan has multiple phases, commit after each phase passes. Do not accumulate changes across phases. Uncommitted work is lost work.

**When verifying a newly built library, run only that library's test file — not the full suite.** Use `bin/cr test lib/mylib/` or `bin/cr test lib/mylib/mylib_test.lua` directly. Only run the full suite (`bin/cr test`) when checking global regressions.

## Context Management

**Subagent prompts for git work must include: clone the repo locally, verify `git config user.name` and `git config user.email` match the target account before committing, commit with git directly, push with git. Never instruct subagents to use `gh api` to create commits — it bypasses git config and produces wrong authorship.**

**All investigation and all implementation goes in subagents.** The only exception is work you are almost 100% certain is shorter to do inline AND are absolutely certain will not poison context. When in doubt, delegate. There is no list of acceptable inline cases — if you are asking yourself whether something qualifies, the answer is no.

**Never pre-load the answer in a delegation prompt.** Don't write "verify that X works" or "claim to verify: X" — write "what does X do?" or "find out whether X works". Pre-baked hypotheses in the prompt teach the agent to confirm, not investigate. If you have a hypothesis, name it as a hypothesis the agent should *attempt to falsify*, not as a thing to verify.

**"X works" and "X doesn't work" are claims of equal weight. Both require runnable evidence.** A claim grounded in code-tracing without a paste-able command and its output is a hypothesis, not a finding. If your investigation concluded "Y doesn't work" and you didn't actually run Y, your conclusion may be wrong — say so explicitly. The cost of running a 5-line `bin/cr check` repro is always lower than the cost of a wrong report.

## Commit Convention

Use conventional commits: `type(scope): message`

Types:
- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code change that neither fixes a bug nor adds a feature
- `docs` - Documentation only
- `chore` - Maintenance (deps, CI, etc.)
- `test` - Adding or updating tests

Scope is the library or component name (e.g., `feat(http): add chunked transfer encoding`).

## Performance Work

When doing performance optimization:
- **Benchmark before and after.**
- **Commit experiments before discarding.** Even rejected optimizations need a commit hash so results are reproducible. Use a branch or revert if needed — never throw away measured code.
- **Record results in `docs/perf/log.md`** with the commit hash of both baseline and optimization. Include raw benchmark output. Most recent entries first.
- **Include**: file sizes, times, throughput (MB/s), allocation (KB/parse), and speedup ratios.



## Lua Gotchas

**Table construction: all data fields go in the literal, methods go on a prototype.**

LuaJIT shapes tables at construction time. Fields present in the literal become part of the hidden class; adding fields afterward transitions to a new hidden class and breaks JIT monomorphic dispatch. The correct pattern:

```lua
-- data fields inline — JIT sees the full shape at construction
local obj = { insns = {}, args = {}, next_id = 0 }
-- methods on a shared prototype, not on the instance
setmetatable(obj, { __index = Proto })
```

All shape-defining fields belong in the literal. Post-construction field assignment (`obj.field = value` for initialization) defeats the hidden-class optimization and puts the field outside the typechecker's view.

**`local x = expr` — `x` is NOT in scope inside `expr`.**

In Lua, a local variable is not in scope within its own initializer expression. A closure created inside `expr` that references `x` will see a global (or nil), not the local being declared.

This matters whenever you want a callback/executor to reference the object being created:

```lua
-- WRONG: rt is a global lookup inside the executor (nil if no global)
local rt = N.runtime({ executors = { foo = function() rt:bar() end } })

-- CORRECT: pre-declare rt so the closure captures the local variable slot
local rt
rt = N.runtime({ executors = { foo = function() rt:bar() end } })
```

The same applies to test code that passes executors inline to a constructor. Always pre-declare the variable, then assign.

## Verify state before acting on assumptions

The filesystem is ground truth, not your memory of it or an agent's narrative
output. Before acting on "the agent must have…", "the file should still be…",
"this failure must be from my change…": run `git status`/`git log`/re-Read
the file/`git stash` and re-test. Cost of one check is always lower than the
wrong action plus cleanup.

## Pause before guessing

If you can't state in one sentence the property your answer must satisfy,
you're guessing. Say so and ask, don't answer. Writing another variation of
what you just said — another interpretation, another proposal, another
framing — is the loop signal. Applies to any response: code, prose, design
answers, conversation.

## Negative Constraints

Do not:
- Use Claude Code's auto-memory system (`~/.claude/projects/.*./memory/`) — it is unversioned, invisible to the user, and can't be diffed or backed up. Write behavioral changes directly to CLAUDE.md instead
- Announce actions ("I will now...") - just do them
- Leave work uncommitted
- Use interactive git commands (`git add -p`, `git add -i`, `git rebase -i`) — these block on stdin and hang in non-interactive shells; stage files by name instead
- Use `--no-verify` - fix the issue or fix the hook
- Edit files inline because the change "seems small" or is "just one function" — size in lines is the wrong axis. If the edit needs exploration or might iterate, delegate.
- Assume tools are missing - check if `nix develop` is available for the right environment
- Add dependencies that require a build step — pure Lua + FFI only
