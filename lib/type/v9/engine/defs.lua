-- lib/type/v9/engine/defs.lua
-- Annotation-only module: the v9 ENGINE + DOMAIN-INTERFACE contracts as types.
--
-- This file declares NO runtime behavior. It is the load-bearing seam: the
-- monotone-fixpoint engine shuttles OPAQUE cell values (`unknown`) and is
-- parameterized by a `Lattice` + a set of `Rule`s (or, for flow analyses, a
-- `FlowDomain` lowered to rules by `dataflow`). The engine names NO domain
-- vocabulary. A domain holds its values at a concrete type internally and
-- NARROWS the opaque `unknown` at its own boundary (via a type predicate) — see
-- ARCHITECTURE.md "Why the cell type is `unknown`, not a generic parameter".

-- ===========================================================================
-- Engine core. Cell values are `unknown`: opaque to the engine, concrete to the
-- domain that produced them. (A generic `Lattice<V>` would be cleaner, but the
-- checker's generics do not survive `require` and it forbids both force-casts
-- and `unknown`->record checked-casts; `unknown` + predicate-narrowing is the
-- idiomatic, force-cast-free bridge. ARCHITECTURE.md documents this.)
--
-- A `Lattice` is a join-semilattice with bottom + equality over opaque values.
--:: Lattice = { bottom: () -> unknown, join: (unknown, unknown) -> unknown, equal: (unknown, unknown) -> boolean }

-- A `Rule` is ONE monotone transfer function over cells. It READS some cells and
-- WRITES some cells; `apply` receives a getter for current cell values and
-- proposes new values for its write-cells. The engine JOINS each proposal into
-- the target cell and re-schedules every rule reading a changed cell. This one
-- primitive subsumes subtyping-propagation (type inference) AND gen/kill
-- dataflow (a proposal may compute a set-minus internally — the lattice never
-- sees it). `reads`/`writes` are the dependency structure; a multi-input merge
-- needs no fold (emit one proposal rule per input, the engine joins them).
--:: Rule = { reads: { [integer]: string }, writes: { [integer]: string }, apply: ((string) -> unknown) -> { [string]: unknown } }

-- A `Graph` is the complete fixpoint problem: a lattice + a rule list. Plain
-- DATA. A domain LOWERS a program into a `Graph`; the engine SOLVES it.
--:: Graph = { lattice: Lattice, rules: { [integer]: Rule } }

-- The fixpoint solution: the final value of every cell, plus a step count.
--:: Solution = { values: { [string]: unknown }, steps: integer }

-- ===========================================================================
-- Surface AST — the pinned cell/op vocabulary (fork 1). Grows toward full Lua.
-- Statements + expressions over a Lua-ish subset: locals, assignment, if/else,
-- a call, return; literals, var use, and one binary op (`add`). Every domain
-- consumes this same surface; the type domain walks it directly (SSA), the flow
-- domains lower it to a CFG first.
--:: Expr = { e: "int", value: number } | { e: "str", value: string } | { e: "bool", value: boolean } | { e: "nil" } | { e: "var", name: string } | { e: "add", lhs: Expr, rhs: Expr }
--:: Stmt = { s: "local", name: string, value: Expr } | { s: "assign", name: string, value: Expr } | { s: "if", cond: Expr, then_: { [integer]: Stmt }, else_: { [integer]: Stmt } } | { s: "call", fn: string, args: { [integer]: Expr } } | { s: "return", value: Expr }
--:: Program = { [integer]: Stmt }

-- ===========================================================================
-- CFG (basic blocks) — the lowering target for FLOW analyses. `succs[1]` is the
-- branch-true target, `succs[2]` the branch-false target when `cond` is set.
--:: Block = { id: integer, stmts: { [integer]: Stmt }, cond: Expr | nil, succs: { [integer]: integer }, preds: { [integer]: integer } }
--:: Cfg = { blocks: { [integer]: Block }, byid: { [integer]: Block }, entry: integer, exit: integer }

-- ===========================================================================
-- Flow domain — a forward/backward dataflow analysis. `dataflow.to_graph`
-- lowers it to a `Graph` by wiring in/out cells per block; `direction` selects
-- the predecessors-vs-successors swap (the ONLY place direction lives; the
-- engine knows nothing of it). `boundary` is the entry value (forward) or exit
-- value (backward). `transfer` is the per-block transfer over opaque values
-- (the domain narrows its input internally).
--:: FlowDomain = { lattice: Lattice, direction: string, boundary: unknown, transfer: (Block, unknown) -> unknown }

return {}
