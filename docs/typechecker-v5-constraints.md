# Typechecker v5 Constraints Catalog

## Context

The typechecker has been rewritten v1→v2→v3→v4 over many sessions; each rewrite treated symptoms and inherited the substrate problems. Goal: design from scratch from first principles, with soundness non-negotiable, expressiveness preserved, and methodology disciplined. Explicit instruction for this round: **never guess at the right answer — narrow/nail down constraints from the historical record, mark anything unsupported as user-decides, not as a default.**

This file is NOT a design. It is the set of constraints any v5 design must satisfy, with each constraint cited to a source in the repo. The next session uses this as input to write the operational semantics; the design itself is downstream.

---

## A. Hard constraints (cannot be relaxed without invalidating soundness or stated user requirements)

Each line: constraint — citation.

- **A1. Soundness floor — NON-NEGOTIABLE.** Type system must reject programs that would crash at typed operations. Soundness holes are malware vectors; no convenience justification overrides this. — user opening + reinforcement msgs this session; `docs/soundness-audit.md` enumerates 11 historical gaps.
- **A2. `unknown` never casts away.** Cannot promote to `any`/another type without a runtime check. — `docs/soundness-audit.md` Gap 11; CLAUDE.md "`unknown` = TS `unknown`."
- **A3. `any` does not exist.** — CLAUDE.md library-conventions.
- **A4. Force casts (`--[[:! T]]`) are almost never correct in user code, and forbidden as checker-internal escape hatches.** — CLAUDE.md.
- **A5. Unannotated parameters that remain fully unconstrained must produce a diagnostic.** — `docs/soundness-audit.md` Gap 2 (implicit-any warning shipped).
- **A6. Locals declared without initializer require `nil <: T` or error.** — Gap 9.
- **A7. Annotation parser must be total.** — Gap 10.
- **A8. `pcall` results are `unknown`; narrowing required to use.** — corpus: 5432 force-cast sites are predominantly this pattern.
- **A9. No ambient globals.** Every name declared (local, `require`, or `--:: declare`). — CLAUDE.md.
- **A10. Caps-first.** No global I/O lookups; injected caps only. — CLAUDE.md.
- **A11. 2809 tests stay green at every commit.** Behavior is conserved across v4→v5; mechanism is not. — CLAUDE.md hard-constraints; user's stated invariant.
- **A12. Zero-dependency, pure Lua baseline.** No build-step dependency; LuaJIT optimised, pure Lua compatible. — CLAUDE.md design-principles.
- **A13. FFI cdefs are the source of truth for FFI types — never duplicate.** — CLAUDE.md.
- **A14. Single timeout enforcement.** `timeout 30 bin/cr check <file>` always; exceeding it is a soundness/termination bug, not slowness. — CLAUDE.md workflow.

## B. Architectural constraints (derived from the three named-wrong decisions)

From `docs/typechecker-architecture-from-first-principles.md` §2. D6, D11, D14 are labeled "Wrong"; each gives rise to specific constraints.

### From D6 (4-pass + deferral + waiters)

- **B1. One scheduling mechanism, not three.** Worklist drained to quiescence. No pass cap, no `_deferred` flag, no separate `tv_waiters`. — D6 wrong-finding; `solve.lua:3972` "pass<4 retry" identified as confession.
- **B2. Quiescence is decidable from the worklist state alone.** No retry heuristics. — D6.
- **B3. Termination is provable, not budgeted.** — D6.
- **B4. Wake-up composes with constraint generation order.** No "fires after pass budget ran out." — D6.

### From D11 (gen-time mutable side-channels)

- **B5. All data needed to solve a constraint lives in the constraint record.** No ctx mutation between gen and solve. — D11.
- **B6. The constraint record carries HKT decomposition payload, multi-return slot indices, rank-N bounds, forall ops — none of these as ctx fields.** — D11 enumerated examples.
- **B7. gen/solve separation is enforced by types/data shape, not by convention.** — D11.
- **B8. 18 distinct ctx fields are a symptom, not 18 problems.** Acceptable ctx fields in v5: scope/env, worklist, union-find store. Anything else needs an explicit B5 justification. — `docs/typechecker-ad-hoc-inventory.md`.

### From D14 (implicit constraint provenance)

- **B9. Every constraint carries provenance: declared (annotation/signature/cast) vs inferred (body usage).** — D14.
- **B10. TV binds have a defined tie-breaker when declared and inferred bounds conflict.** Declared wins; inferred becomes a check. — D14; bind-ordering work attempted to patch this without removing D6.
- **B11. Source range and provenance kind live on the constraint, not reconstructed from context.** — D14.

## C. Dispatch & primitive-handling constraints

From K6e audit (`docs/typechecker-method-dispatch-audit.md`, commit `4b3abbe4`):

- **C1. Method dispatch is keyed by receiver TYPE, not by source binding name.** No `env.bindings[recv.name]`. — K6e audit.
- **C2. Primitive method lookup goes through a `prim_index` / `prim_meta` registry.** Legacy has this pattern; v4 missed it. — K6e audit.
- **C3. Handler shape multiplicity must be principled.** If N handler shapes exist, N distinct fundamental needs are named, each in writing. The five-shape catalog (pure-emit, sync-unify, backtracking, aggregation, mid-iteration deferral) is NOT principled today. — session audit §2 P2.

## D. Feature-preservation constraints (from corpus measurement)

The corpus survey (this session) measured what `lib/` actually uses. v5 must handle:

- **D1. 9343 single-line `--: T` annotations.** Locals, params, returns. — corpus.
- **D2. 4683 multi-line `--:: T` declarations.** Type aliases, declares. — corpus.
- **D3. 925 checked casts `--[[: T]]` with full subtyping.** — corpus + CLAUDE.md.
- **D4. 5432 force casts `--[[:! T]]`.** Predominantly post-`pcall` narrowing. Force is checker-side a no-op subtyping, user-side declared unsafe. — corpus + CLAUDE.md.
- **D5. Records, arrays, maps `{[K]:V}`, and their mixed forms.** Record dominant (~60%), array ~25%, map ~15%. — corpus.
- **D6. Unions, especially `T | nil` return pairs.** Most common shape: `(T | nil, string | nil)` for `(value, errmsg)`. — corpus + CLAUDE.md conventions.
- **D7. Generics with positional instantiation (`Arr<T>`).** — corpus.
- **D8. Optional fields `field?: T`.** — corpus (`ai_request` etc.).
- **D9. Method dispatch via `:` on metatable `__index` chains.** Class-like OO in `lib/github`, `lib/epoll`. — corpus.
- **D10. `setmetatable` post-construction with type narrowing.** Must be modeled SOUNDLY (see H4). — corpus, `lib/epoll/init.lua:14,99`.
- **D11. Flow typing: `if not x then return` narrows, `if type(x) == "string"` narrows, `assert(x)` narrows.** — corpus + `docs/typechecker-reference.md`.
- **D12. Module pattern: `M = {}; M.foo = ...; return M` must yield a typed module surface.** — corpus dominant.
- **D13. FFI cdata as a first-class type.** `ffi.new`, `ffi.cdef` integration. — corpus + CLAUDE.md A13.
- **D14. Type-level intrinsics (`$Require<T>`) for stdlib typing of `require`.** — CLAUDE.md.
- **D15. Row polymorphism, match types.** Currently working; must preserve semantics. — `docs/typechecker-reference.md`.
- **D16. Rank-N at call sites.** Currently landed; preserve. — roadmap A1.

## E. Performance constraints

- **E1. `timeout 30 bin/cr check <file>` is a hard ceiling per file.** — CLAUDE.md.
- **E2. `timeout 120 bin/cr check` for repo-wide.** — CLAUDE.md.
- **E3. Target throughput equivalent to tsgo.** — CLAUDE.md design-principles "Tooling performance bar: tsgo for the typechecker."
- ~~**E4. LSP daemon incremental.**~~ STRUCK as design constraint. LSP is currently unused and treated as unreliable. `lib/type/static/lsp.lua` does not constrain v5; if v5 breaks it, that is acceptable. — user this session.

## F. Methodology constraints (binding on how v5 is built, not what)

From session audit `docs/session-audit-2026-05-20.md`:

- **F1. No claim ships without a runnable repro.** "X works" requires command + output, both ways. — session audit + CLAUDE.md authenticity.
- **F2. Operational semantics is a runnable test, not prose.** If it isn't executed against the implementation, it doesn't count. — session audit §4 P4.
- **F3. Grep legacy first before reimplementing any mechanism.** — session audit §5; K6e-redo precedent.
- **F4. One commit per phase, all 2809 tests green at each commit.** No "lands in next phase" deferrals dressed as boundaries. — session audit; K6e/K6f pattern flagged.
- **F5. No multi-option hedging menus. Orchestrator recommends.** — session audit §1 P5.
- **F6. No subagent dispatch as substitute for orchestrator decision.** Routing the question is not holding it. — session audit §1 P3.
- **F7. Mechanical checks over judgment-rules.** Rules that depend on self-classification fail. — session audit §3.
- **F8. Plan mode for any multi-phase architectural work.** — user this session; CLAUDE.md trim direction.
- **F9. Maintain a discovery/exploration/decision log throughout v5 work.** Append-only, one entry per decision or experiment. Each entry: timestamp, question, evidence gathered, decision (or "still open"), citation. Location: `docs/typechecker-v5-log.md` (to be created on first entry). Purpose: makes the substitution-of-tactical-for-strategic failure mode (session audit §1 P1) detectable across sessions — a log entry that resolves nothing is visible as such. — user this session.
- **F10. Experiments are first-class.** Where a constraint can be settled by running code instead of arguing about it, run code. Examples: termination of a worklist schedule on real constraint sets; throughput of an alternative unifier on the corpus; behavior of legacy on a specific input. Experiments commit under `lib/type/experiments/<name>/` or `docs/perf/log.md` (per CLAUDE.md performance-work rules), and the result is logged in F9. A discarded experiment still commits before discard so its result is reproducible. — user this session + CLAUDE.md performance-work.
- **F11. Decisions in H (open questions) close only via log entries with evidence, not via conversation alone.** A decision recorded only in chat is not durable. — derived from F1 + F9.
- **F12. Subagent prompts must NOT pre-load the answer.** Do not scope the question to a hypothesis the orchestrator already holds ("find patterns relevant to D6"). Frame the agent on its target ("describe this codebase's architecture on its own terms"), then synthesize. Pre-loading is the tunnel-vision/laziness failure mode flagged this session — produced biased discovery reports whose findings must be discarded as design evidence. — user this session; CLAUDE.md context-is-scarce "never pre-load the answer."
- **F13. Tainted discovery output is preserved separately, not merged into evidence.** Location: `docs/typechecker-v5-tainted/` or similar. Treated as radioactive but kept for posterity (audit trail of how bias entered). — user this session.
- **F14. Slacking off during design is the primary historical failure mode.** Each prior iteration produced straight-garbage results from insufficient design effort. Wide, thorough discovery before narrowing is non-negotiable — "as wide as possible" beats "smart cherry-pick." — user this session.

## G. Negative constraints (explicit "do not")

- **G1.** No 4-pass loop / pass cap / pass<N retry.
- **G2.** No `_deferred` flag on constraints.
- **G3.** No gen-time ctx mutation as inter-phase signaling channel.
- **G4.** No source-binding-name keyed dispatch.
- **G5.** No type aliases that legitimize vague annotations (`table`, `function`). — CLAUDE.md.
- **G6.** No force casts inside checker internals.
- **G7.** No "any."
- **G8.** No framework code in `lib/`. — CLAUDE.md.
- **G9.** No `--no-verify`, no skipping pre-commit. — CLAUDE.md.
- **G10.** No silent fallback to slow tier without trying faster. — CLAUDE.md.
- **G11.** No subagent for "implementation where the spec is uncertain." Uncertain spec stays with orchestrator. — CLAUDE.md context-is-scarce.
- **G12.** No pre-loaded subagent prompts. Frame on the target, not on the orchestrator's hypothesis. — F12.
- **G13.** No accepting unsoundness for backward-compat with existing `lib/` code. If v5's sound model rejects an existing pattern, refactor the pattern, not the model. — H4 framing this session.

## H. Open questions (insufficient evidence — user decides; designer must NOT default)

These are not pickable by guess. Each one materially changes the design space.

- **H1. Is HKT in scope for v5?** Flagged as "single biggest deficit vs Haskell" (roadmap F1), unimplemented. Including it constrains the constraint payload representation and unification algorithm significantly. — roadmap F1.
- **H2. Is effect tracking in scope for v5?** Flagged as differentiator (roadmap F2). Effects propagate through function types; not free. — roadmap F2.
- **H3. Migration shape.** Three options: (a) build `lib/type/static-v5/` in parallel, swap on green, (b) in-place rewrite of legacy `lib/type/static/`, (c) abandon v4 explicitly first then v5 greenfield. User to pick. — no evidence of preference in the record.
- **H4. Sound model of `setmetatable`-post-construction.** Soundness is non-negotiable (A1). Question is HOW to model this pattern soundly, not WHETHER. Candidates: linear/affine "table-under-construction" → "table-sealed" types, construction-phase typing, restricted mutation patterns, declared-metatable-up-front. Downstream consequence on existing code is acceptable (refactor the libraries). — user this session; corpus has the pattern.
- **H5. Refinement types, GADT-strength flow typing, impredicativity.** Roadmap F7/F8/F9 mark these as deferred/uncertain. Decide explicit in-scope or explicit out-of-scope for v5. — roadmap.
- ~~**H6. LSP port vs rewrite.**~~ STRUCK. LSP is irrelevant, unreliable, not a v5 design constraint. — user this session.
- **H7. Operational-semantics representation.** Inference rules in `docs/` (prose), executable spec in Lua, or both with parity-tested equivalence? F2 says "runnable" — but designer needs to know which form. — no decision in record.
- ~~**H8. Scope/timeline.**~~ STRUCK. User does not care about session budget; the issue is design effort quality, not pacing. Slacking off during design is the named primary failure (F14). — user this session.
- **H9. When to mine sibling repos for architecture insight (see section I).** Resolved: wide unframed discovery pass NOW (per F12, F14), before operational-semantics writing. — user this session.

## I. Cross-ecosystem sources to mine for ARCHITECTURE insight

The rhi ecosystem (`~/git/rhizone/github-io/CLAUDE.md`) contains sibling repos whose architectural choices may inform v5. The signal is architectural patterns in general — not pre-targeted at D6/D11/D14 or any specific typechecker concern (per F12).

Discovery pass scope: as wide as practical. The candidate set, by ecosystem section:

**Code Intelligence:** normalize, gels, motif
**Generation:** unshape, wick
**Games & Worlds:** playmate, scribble, defocus
**Data Transformation:** tiltshift, paraphase, rescribe, concord, reincarnate
**Runtime & Interface:** rainbow, moonlet, dusklight, deskspace
**Infrastructure:** interconnect, myenv, portals, zone, nanites, server-less
**External / Related:** sketchpad, ooxml, claude-code-hub, hologram, aspect, noncanon, keybinds, ascent-interpreter, ashwren, fuwafuwa, matrix-gen, chub-stage-factory

Discovery prompt for each repo cluster: "Describe this codebase's architecture on its own terms — what it is, how it's structured, load-bearing decisions, surprises, awkwardness. No reference to crescent or to typecheckers."

Findings logged to `docs/typechecker-v5-log.md` on creation. Synthesis against crescent v5 constraints is a SEPARATE step after discovery, not interleaved.

The earlier pre-framed discovery (this session, before user correction) is tainted (F13) and is being re-run unframed. Tainted reports go to `docs/typechecker-v5-tainted/` rather than the v5 log.

## Verification

This file is verified by the user reading it and answering H1–H5, H7, H9, or correcting/striking entries in A–G with citations. There is no code to run yet. The next session begins after H is closed, at which point the operational semantics is written, and only then does mechanism implementation start.

The constraints in this file are themselves derived. Any constraint the user disagrees with: strike it with a counter-citation; do not weaken it silently.

