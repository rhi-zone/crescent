# Framework Audit: v7 MR0

This document audits whether `lib/type/v7_mr0/` is an instance of the
type-system-agnostic framework.

## Verdict

v7 MR0 is not a framework instance.

It is valuable prototype material for:

- replay-only acceptance;
- canonical serialization;
- content-addressed terms, contexts, nodes, and inputs;
- explicit roots;
- explicit unsafe/trusted boundaries;
- adversarial fixture style.

It should remain isolated until a future Crescent theory can express its rules
as a declarative theory spec checked by the framework derivation checker.

## Why It Is Not A Framework Instance

### The Theory Is Lua Code

MR0 rules live as verifier functions such as:

```text
validate_type
replay_wf
replay_sub
replay_pack_move
replay_call
```

Those functions are a hardcoded Crescent/MR0 theory implementation. In the
framework architecture, equivalent knowledge must live in a `TheorySpec`:

- categories;
- term heads;
- judgments;
- rule schemas;
- structural conditions;
- oracle schemas;
- root schemas.

If a future Crescent rule needs non-structural computation, that computation
must be exposed as evidence or as an explicit oracle. It must not be hidden in a
Lua side condition inside the trusted replay checker.

### MR0 Contexts Are Bespoke Payloads

MR0 has a separate `ContextEntry` shape:

```text
ContextEntry = {
  context_id,
  locals,
  identities,
  live_facts,
  dependencies
}
```

The framework decision is different: contexts are ordinary theory-declared
syntax categories with role `context`. A future Crescent theory may define a
context-role category with fields corresponding to locals, identities,
live-facts, and dependencies, but it should not add a second framework object
system for contexts.

### Node Families Are Hardcoded

MR0 has node families such as:

```text
WFNode
SubNode
PackMoveNode
ExprNode
StmtNode
CallNode
UnsafeNode
```

These are useful names for a Crescent theory, but they are not framework
concepts. In the framework, a node proves a declared judgment by applying a
declared rule. `SubNode(refl)` becomes something like:

```text
RuleApplication(
  judgment = Subtype(ctx, A, A),
  rule = subtype_refl,
  premises = []
)
```

The framework should not know that `SubNode` or `PackMoveNode` exists.

### MR0 Canonicalization Is Close But Not General

MR0 canonicalization already has the right instinct:

- deterministic map ordering;
- ordered arrays;
- content-addressed terms;
- content-addressed contexts;
- content-addressed nodes;
- target/source/declaration digests;
- JSON boundary rejecting `null`.

But the projection is MR0-specific:

- `term_id = digest(sort, payload)`;
- `context_id = digest(locals, identities, live_facts, dependencies)`;
- `node_id = digest(family, rule, inputs, premises, outputs)`;
- roots are certificate-level rather than Merkle DAG roots over reachable
  accepted evidence closure.

The framework should mine the implementation experience but define its own
canonical object model around theory specs, terms, claims, evidence nodes,
oracles, and roots.

### MR0 Trusted Boundaries Are Too Narrow And Too Specific

MR0 has useful unsafe/trusted nodes:

```text
UnsafeNode(force_claim)
UnsafeNode(trusted_decl_value)
```

The framework needs a more general oracle model:

```text
OracleApplication {
  oracle_kind,
  input_payload,
  input_digest,
  result_payload,
  result_digest,
  trust_policy
}
```

`trusted_decl_value` can become one Crescent-theory oracle kind. It should not
be a framework primitive.

## What To Reuse

Reuse these MR0 ideas in the framework implementation:

- table-native fixture authoring for early tests;
- external JSON certificate boundary;
- strict digest options staged separately from hand-written fixtures;
- rejection-first validation of malformed inputs;
- content-addressed semantic objects;
- no inference during replay;
- roots requiring accepted proof nodes;
- explicit unsafe/trusted events.

Reuse these MR0 concepts in a future Crescent theory:

- value claims;
- pack claims;
- closed pack movement;
- pure arrow calls;
- local-read contexts;
- unsafe force claims;
- trusted primitive declarations;
- primitive capability values.

Do not reuse these as framework concepts:

- `Type`/`Pack`/`ValueClaim` as built-in categories;
- `SubNode`, `PackMoveNode`, `CallNode`, or any other node family;
- Crescent primitive capability names;
- LuaJIT target profile fields;
- MR0 context payload shape;
- stdlib/declaration rules.

## Migration Path

### Step 1: Keep MR0 Isolated

Do not refactor `lib/type/v7_mr0/` into the framework core.

The current verifier is a useful control specimen: a hardcoded replay checker
with known limitations. It should remain available for comparison while the
framework checker is built.

### Step 2: Build A Tiny Framework Checker First

The first framework implementation should target:

- framework data model;
- derivation checker;
- a combinator fragment or STLC after binder replay;
- no Crescent types;
- no MR0 node families;
- no oracles.

This avoids importing Crescent assumptions before the framework has passed
unrelated validation theories.

### Step 3: Re-express A Tiny MR0 Fragment As A Crescent Theory

After STLC and System F replay, define a tiny Crescent theory fragment:

```text
Category Ty
Category Pack
Category Claim
Category CrescentContext { role = context }

Judgment WFTy(ctx, ty)
Judgment Subtype(ctx, a, b)
Judgment PackMove(ctx, source, target)
Judgment HasValue(ctx, expr, claim)
```

Start with only:

- scalar types;
- literal claims;
- `integer <: number`;
- closed exact pack movement;
- pure closed-arrow call.

This should be a new framework certificate fixture, not a rewrite of
`lib/type/v7_mr0/`.

### Step 4: Compare Against MR0

Only after a tiny Crescent theory exists should we compare:

- which MR0 rules become declarative framework rules;
- which MR0 helper functions become structural framework checks;
- which MR0 logic must become oracle evidence;
- which MR0 payloads were premature or theory-specific.

## Decision

MR0 is prototype/research input, not implementation substrate for the framework.

The framework implementation should not depend on `lib/type/v7_mr0/`.

The future Crescent theory may mine MR0 rule names and fixture patterns, but it
must restate every admitted rule as framework-checkable theory evidence.
