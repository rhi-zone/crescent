# Checker #1 — the value/kind checker

The first of crescent's many small, narrow, single-purpose typecheckers. It is
standalone: it does **not** use or extend the v5 typechecker's solver, op_sem,
or constrain machinery. It lives in `lib/check_kind/`.

## The plurality framing — one checker per question

The governing principle (from the project owner):

> "We shouldn't have one typechecker — every time we answer a question, we make
> a new typechecker."

A monolithic checker accretes special cases until no one can reason about it
(the documented v1→v4 failure mode). The alternative is a *family* of checkers,
each answering exactly one question with the smallest machine that suffices.
This is checker #1. Each future checker is a new module with its own value model
and its own verdict — they compose by being run together, not by sharing a
solver.

## The one question

> **Is every value used as the KIND that the operation requires?**

That is: catch kind-level misuse before runtime —

- calling a non-function,
- indexing a non-table,
- arithmetic / concat on the wrong atom,
- using a possibly-nil value where a non-nil value is required,
- passing the wrong kind to a function or operator,
- returning the wrong kind from an annotated function.

Nothing else. Field shapes, integer-vs-float, generics, and rich unions are
*other questions* — other checkers.

## The value model

Derived from the Lua/LuaJIT runtime value universe, implemented exactly (no
more) in `lib/check_kind/kinds.lua`:

- **Six opaque atoms**: `boolean`, `number`, `string`, `thread`, `userdata`,
  `cdata`. `number` is a single atom — the integer/float distinction is
  **DEFERRED**.
- **A nilable flag, NOT an atom.** `nil` is absence, modeled as a `nilable`
  boolean carried on every type (`T` vs `T?`). Reading a missing/optional field
  yields a nilable type. The literal `nil` is the absence type (`K_NIL`).
- **Arrows** for functions *and* operators: `(args...) -> ret`. Arrows are the
  propagation engine — types flow input→output through application. Operators
  are built-in arrows: arithmetic `(number, number) -> number`, concat
  `(string, string) -> string`, comparisons `-> boolean`, length `#`, unary
  minus, `not`.
- **Tables** as a single structured kind: `table`. Indexing requires a table;
  the resulting field type is `unknown?` for now. Table **SHAPES** (fields /
  records / index signatures) are **DEFERRED** to a later checker.
- **Top / bottom**: `unknown` (any value) and `never` (no value). An `unknown`
  *producer* is not a subtype of any concrete kind — it must be narrowed (i.e.
  annotated) before use; this is enforced at the use site.

A type is a plain Lua table `{ k = <K_*>, nilable = <bool>, params?, ret? }`.
No FFI arena, no cycles — trivially terminating.

## The three verbs

1. **Assign** a type to every expression: literals → atom; `nil` → absence;
   function literal → arrow (unknown arrow if unannotated); table constructor →
   `table`.
2. **Propagate** through every site a value moves: application, operator
   application, indexing/field access, local binding & assignment, `return`,
   and `if`/branch joins (with minimal narrowing — `if x then` strips nil from
   `x` inside the branch). Statement and expression forms are handled directly;
   not everything is an operator application.
3. **Check & reject** at every use site via subtyping (producer <: consumer).
   Each rejection names the violated expectation and carries the source
   line/column.

## The floor

- **Sound**: never green-lights something that can fail in the way it checks.
  Subtyping is conservative; `unknown` producers cannot satisfy a concrete
  requirement.
- **Terminating**: the AST is finite and recursion descends strictly into
  children; the value model has no cycles. Always halts with a verdict.
- **Legible**: every diagnostic states the decision it violates ("call requires
  a function, but got `number`") at the source location.

## "Demand the decision, don't infer cleverly"

The complexity-control rule. The checker does only cheap, local, decidable
propagation. Where determining a type would require non-local or non-trivial
reasoning, it does **not** try to solve it — it yields `unknown` and *demands an
annotation* at the use site. Annotations are where irreducible decisions live;
demanding them keeps the checker small. Concretely:

- An unannotated function literal has an unknown arrow — its parameters and
  return are `unknown`, and calling its result is not checked against a
  signature.
- An unannotated local bound to a call result is `unknown`; using it as a
  concrete kind (calling, indexing, arithmetic) reports "the value's kind is
  `unknown` — annotate it".
- Annotations are parsed with the **existing** annotation grammar
  (`lib.type.static.ann`) — no new syntax. Only the small supported slice
  (atoms, `T | nil`, arrows, `table`, literals→atom) is lowered into the value
  model (`lib/check_kind/lower.lua`); anything richer lowers to `unknown`.

## Reuse

- **Lexer + Lua parser**: `lib.type.static.lex` / `lib.type.static.parse`
  produce the AST. No bespoke Lua parser.
- **Annotation grammar**: `lib.type.static.ann` parses `--:` / `--::` content.
  No new annotation syntax.
- **No v5 solver / op_sem / constrain.** This checker shares none of that
  machinery — that is the entire point of the plurality framing.

## Module layout

```
lib/check_kind/
  init.lua              -- the checker: AST walk, infer, check, report
  kinds.lua             -- the value model (atoms, nilable, arrows, table, top/bottom)
  lower.lua             -- lowers the supported annotation slice into the value model
  check_kind_test.lua   -- reject/accept tests for each misuse class
```

Public API (error style per `docs/conventions.md` — diagnostics returned, never
thrown on bad input):

```lua
local ck = require("lib.check_kind")
local result = ck.check_string(source, filename)  -- { result = { errs }, errs }
local diags  = ck.check(source, filename)          -- just the diagnostics list
```

## Explicit deferrals

Each is a *different question* for a *different checker*, not a gap in this one:

- **integer vs float** — `number` is one atom here.
- **table shapes** — fields, records, index signatures. Reading a field yields
  `unknown?`; only the `table` kind itself is checked.
- **literal refinement** — `"foo" <: string`, `42 <: number`, `true <:
  boolean`. Literals lower to their atom; the singleton type is not retained.
- **generics** (`<T>`), **intersections** (`A & B`), **match types**, **named
  aliases** — lower to `unknown`.
- **unions beyond nilable** — only `T | nil` is modeled. A union of two distinct
  non-nil kinds lowers to `unknown`.
- **multi-return** — an arrow's return is collapsed to its first return slot.
- **string ordering** in `< <= > >=` — v1 requires both operands to be
  `number`.
- **method / `:` dispatch** — `obj:m(...)` checks only that `obj` is a table.
- **full cast subtyping** — `expr --[[: T]]` adopts the annotated type as the
  demanded decision; the cast's own subtyping obligation is not re-checked.
