# Typechecker v5 — Tainted Discovery (Radioactive)

## Status: DO NOT CITE AS DESIGN EVIDENCE

This file preserves three Explore-agent reports from 2026-05-22 that were prompted with the orchestrator's pre-held hypothesis (the named-wrong substrate decisions D6, D11, D14). Each prompt included framing like "The typechecker problem this is supposed to inform: D6 wrong-finding…" and "Direct analogue of B5/B7…".

Per F12 (subagent prompts must NOT pre-load the answer) and CLAUDE.md context-is-scarce ("never pre-load the answer"), this is exactly the failure mode that produces biased discovery — the agent finds what the orchestrator told it to find, confirming pre-held hypotheses instead of describing the source on its own terms.

The reports are preserved here as **evidence of the bias mode itself**, not as evidence about the surveyed codebases. The unframed re-run (`docs/typechecker-v5-discovery-unframed.md`) supersedes them for any actual design use.

If you find yourself wanting to cite something from this file, stop. Find the same information in the unframed file or rerun against the source.

---

## 1. Nanites mining (TAINTED — prompted with D11/B5/B7)

**Original prompt framing:** "D11 (wrong): constraint records can't carry payloads… Need: a payload-as-data architecture where constraints carry everything needed to solve them. B5/B7 constraints: all data needed to solve a constraint lives in the constraint record."

**Agent output (verbatim, preserved):**

### 1. Tasks as Pure Data — Self-Contained Structs

Tasks are serializable structs carrying only configuration, zero resource handles.

**Task shape** (`nanites-core/src/task.rs:44-66`): trait `Task: Send + Sync + 'static`; required `type Input`, `type Output`, `type Error`; single method `run(&self, input: Input, ctx: &Ctx) -> impl Future<Output = Result<Output, Error>>`. Task struct itself is cloneable, serializable.

**I/O task variant** (`dyn_task.rs:47`, `nanites-rig/src/lib.rs:115-118`): marker trait `IoTask` — pure data, no `run()`. Example: `CompletionTask` carries only `model: String` and `system: Option<String>`. Execution delegated to a registered `TaskExecutor` — the resource boundary.

**[Original "Relevant to D11/B5/B7" framing follows — REDACTED from posterity reading.]**

### 2. Dependency Graph Built Dynamically via `ctx.spawn`

Task graph grows as tasks discover subtasks at runtime. `ctx.spawn<T>(task, input)` returns `TaskHandle<T::Output>`; awaiting the handle creates an implicit dependency edge. Parent-child recorded automatically in frontier and exec_graph (`ctx.rs:74-85`, `frontier.rs:89-123`).

Design decision (`docs/design/decisions.md:24-30`): graphs known upfront are "fictional"; real decomposition is dynamic.

### 3. Scheduler Shape: Worklist via Frontier

`Frontier` (`frontier.rs:66-232`): live task tree (pending + in-flight only), `HashMap<NodeId, TaskNode>` guarded by Mutex. Nodes have status Pending|Running|Completed|Failed|Cancelled. Shrinks as tasks complete (`remove_terminal`).

Quiescence detection (`frontier.rs:224-231`): `len() == 0` and all futures resolved.

Exec graph (`exec_graph.rs:1-44`): separate monotonically-growing audit log of every spawned task; never shrinks.

### 4. Statelessness Enforced by Types

Pure `Task` enforces no side effects via `run()` signature: Input received as parameter, Output returned, `&Ctx` (not `&mut Ctx`). Arbitrary mutation violates Rust's type system. Config is immutable (all fields public, immutable). I/O task pattern: Task struct is pure data; Executor holds resources, accessed via `&self`.

### 5. LLM as Oracle, Not Agent

CLAUDE.md framing: "The orchestrator is a program, not an agent… The LLM is an oracle called by the program when world knowledge is needed. The LLM decides; the program acts on the decision."

LLM calls are one task type among many. Orchestrator (parent task) receives the LLM's output and decides what to do next. LLM doesn't spawn tasks, doesn't know about the graph, doesn't control flow.

**[Original closing "Relevant to typechecker" mapping table — REDACTED.]**

---

## 2. ascent-interpreter mining (TAINTED — prompted with D6/B1/B2)

**Original prompt framing:** "D6 (wrong): the current typechecker has three coexisting scheduling mechanisms… B1/B2 constraints: ONE scheduling mechanism (worklist drained to quiescence)… Datalog evaluation is exactly the canonical worklist-to-fixpoint problem."

**Agent output (verbatim, preserved):**

### Worklist Representation
Delta-based worklist via two per-relation vectors:
- `delta: Vec<usize>` (`relation.rs:48`): indices of tuples added in current iteration, unprocessed.
- `recent: Vec<usize>` + `recent_set: FxHashSet<usize>` (`relation.rs:49-50`): tuples advanced from delta in prior iteration, ready for rule evaluation.

Insertion via `insert()/insert_with_source()` appends to `data`, adds index to `delta`. No dequeue; indices scanned linearly.

### Quiescence Detection
Single boolean flag `changed`, set by `advance()`:
```rust
pub fn advance(&mut self) -> bool {
    let had_delta = !self.delta.is_empty();
    self.recent = std::mem::take(&mut self.delta);
    had_delta
}
```

Loop termination (`engine.rs:869-887`):
```rust
while changed {
    iterations += 1;
    changed = false;
    for rule in rules { self.evaluate_rule(rule, true); }
    for rel in self.relations.values_mut() {
        if rel.advance() { changed = true; }
    }
}
```

### Termination Argument
Monotone within a stratum. Each iteration derives subset of tuples not yet in any relation. Each `advance()` moves delta → recent. Universe of possible tuples is finite (bounded by ground instantiation); no tuple retracted → fixpoint reached when no new tuples derived.

Non-monotone extensions (negation, aggregation): handled via stratification, not worklist modification. Negation (aggregator `"not"`) sets `monotone = false` in SCC metadata (`engine.rs:231`). Non-monotone SCCs fall back to full clear-and-rederive in incremental evaluation (`engine.rs:723-729`).

### Stratification & SCC Ordering
SCCs computed via Tarjan's algorithm on rule dependency graph (`engine.rs:2988-3044`). Per-SCC metadata: `scc_reads`, `scc_writes`, `scc_is_monotone`. Each SCC runs to fixpoint before dependent SCCs begin (`engine.rs:651-654`).

### Incremental Evaluation (Semi-Naive)
Two modes: full fixpoint (`run()`), incremental (`run_incremental()`). Incremental propagates dirty sets forward through SCC DAG (`engine.rs:702-712`), classifies each dirty SCC as delta-only (monotone) or full clear-and-rederive (non-monotone), runs only dirty SCCs (`engine.rs:750-779`).

Semi-naive within each SCC: rules evaluated with `use_recent=false` (all tuples) first, then `use_recent=true` (recent only joined with all others). Early exit if rule has no recent data (`engine.rs:2023-2038`).

### State Storage
Single global store: `Engine.relations: FxHashMap<String, Relation>` (`engine.rs:307+`). No side-channel: rule evaluation accumulates derived tuple set (`Vec<(&str, Tuple)>`, `engine.rs:2046`), inserts atomically after body completion.

Two relation implementations switchable at construction: `RelationStorage` (generic, flat Vec<Value> + per-column hash indices) and `PackedStorage` (optimised for u32 columns, JIT-compiled rule bodies). Both implement same `advance()/insert()` interface.

**[Closing summary table mapping to typechecker — REDACTED.]**

---

## 3. normalize mining (TAINTED — prompted with describable-end-to-end discipline)

**Original prompt framing:** "User's framing: 'if the entire architecture cannot be described, from end to end, using a consistent, complete description, then our typechecker is broken.' Normalize representing many languages uniformly is the same problem at a different scale."

**Agent output (verbatim, preserved):**

### The Single Shape It Normalizes To: AST + Fact Relations
Normalize does NOT converge to a single unified IR. Layered two-stage model:

**Layer 1 — Syntax (per-language):** Tree-sitter CSTs parsed into language-specific `Symbol` (`normalize-facts-core/src/symbol.rs:6-33`) and `Import` structs. `SymbolKind` is an enum: Function, Method, Class, Struct, Enum, Trait, Interface, Module, Type, Constant, Variable, Heading. Each language implementer extracts the symbols their grammar provides — no fabrication.

**Layer 2 — Fact Relations:** Extracted symbols flatten into Datalog relations (`normalize-facts-rules-api/src/relations.rs`). Fixed: `symbol(file, name, kind, line)`, `import(from_file, module_specifier, name)`, `call(caller_file, caller_name, callee_name, line)`, `visibility(file, name, vis)`, `attribute(file, name, attr)`, `parent(file, child_name, parent_name)`, plus 10+ cross-file resolution predicates.

Critically: **there is no "describable end-to-end" doc that stays in sync.** Audit report (`docs/audit-2026-03-12.md:92-100`) explicitly flags this: "Philosophy.md vs reality" — documented scope ("three primitives, fits in working memory") vs actual (38 crates, 22 top-level commands, 90+ entry points). Philosophy document never updated when scope expanded.

### Language-Specific Quirks: Absorbed at Extraction
Asymmetries live in per-language parsers + Language trait. When a feature exists in language A but not B:
- If grammar exposes it: `Language` trait methods (`extract_docstring()`, `extract_attributes()`, `extract_imports()`) handle it (`traits.rs:186-250`).
- If grammar doesn't: return empty/None — never fabricate semantic structure (`CLAUDE.md:56`).
- No post-pass narrowing. Rust impl-block merging happens in extraction (`extract.rs:344-346`).

### Phase Structure
1. Parse (tree-sitter)
2. Extract (Language trait methods)
3. Flatten to relations
4. Datalog (ascent-interpreter)
5. Emit diagnostics

Extraction uses tree-sitter `.scm` query files, not Rust code, to identify symbol kinds (CLAUDE.md: "If you're writing `complexity_nodes()` as Rust data, write it as `.scm` instead").

Phase 0 (cross-file resolution) added recently — pre-populates `resolved_import`, `module`, `export`, `reexport` relations before Datalog rules.

### What Was Rejected: Surface Syntax IR and Dylib Rules
**Surface Syntax IR** (`normalize-surface-syntax`): abandoned attempt at cross-language code transformation as S-expression. Failed for semantic translation — IR captures syntax structure only, not semantics. Now "translation research", not primary normalisation path. Acknowledged (`src/lib.rs:39-43`): "This is surface-level translation, not semantic transpilation."

**Dynamic Rule Libraries (dylib model):** replaced with interpreted Datalog. Old model loaded `.so` files; new are text `.dl` files via ascent-interpreter. Reduced plugin complexity, enabled hot-loading.

### Query: Datalog + Pattern Match
All analysis via Datalog rules over fixed Relations. No custom traversal. Examples:
```datalog
reaches(from, to) <-- import(from, to, _);
reaches(from, to) <-- import(from, mid, _), reaches(mid, to);
warning("circular-deps", a) <-- reaches(a, b), reaches(b, a);
```

### Documentation Discipline: Incoherent
Codebase explicitly acknowledges it fails the "describable end-to-end" test:
- CLAUDE.md rule: "Write it down now" — exists *because* documentation was drifting.
- Philosophy.md stale (audit 2026-03-12 lines 91-99): claims "three primitives" + "optional index"; reality is 38 crates + hard-required indexing.
- MEMORY.md exceeded its own 200-line limit, split into 5 topic files.
- README.md contradicts TODO.md on ecosystem support status.

Audit conclusion (March 2026): "The underlying architecture is sound… but the documentation hasn't kept pace with scope expansion." **No integrated end-to-end architecture document exists.** Understanding requires reading 5+ files.

**[Closing "Evidence for Typechecker Rewrite" synthesis section — REDACTED.]**

---

## Why these are tainted

In all three, the prompt told the agent which patterns to look for ("payload-as-data architecture", "worklist drained to quiescence", "describable-end-to-end in one shape"). Each report dutifully framed its findings around the cue — and the cue was the orchestrator's pre-held hypothesis, not an open question.

The danger isn't that the reports are *false* — the facts they cite are real. The danger is that they're *selected*. Anything in the source codebase that would have falsified the orchestrator's hypothesis was filtered out at the prompt boundary. The agent is good at finding what you tell it to find, including when what you tell it to find is wrong.

The unframed re-run (`discovery-unframed.md`) avoided this by asking each agent to describe the architecture on its own terms with no reference to crescent or to typechecking.

If a future session reaches this file and wants to use it: don't. Find the unframed coverage of the same repo, or re-explore the source directly.
