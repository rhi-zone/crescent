# Typechecker v7 MR0 Function Body Replay

This document specifies the next source-independent MR0 slice after local
context replay.

Target example:

```lua
function f(x: integer): number
  return x
end
```

The verifier still does not parse Lua and does not infer. It replays a table
certificate that connects:

- an arrow type;
- ordered parameter places;
- an immutable entry context for the body;
- a single closed return statement;
- a function value claim exported by an accepted root.

## Existing Substrate

This slice builds on already admitted MR0 replay:

- closed pack terms;
- arrow types with closed parameter and return packs;
- immutable contexts;
- local places;
- `ExprNode(local_read)`;
- `PackNode(values_closed)`;
- `PackMoveNode(closed_return_adjust | closed_exact)`;
- `StmtNode(return_closed)`.

No table, metatable, effect, overload, generic, module, or source parser rule is
introduced here.

## Parameter Context

`BinderNode(rule = closed_params_context, inputs = { context, params_pack, places }, outputs = { ok })`

Inputs:

- `context`: context entry ID;
- `params_pack`: term ID of sort `pack`;
- `places`: ordered list of term IDs of sort `place`.

Replay checks:

- `context` is well-formed under MR0 context rules;
- `params_pack` is a closed pack;
- `places` length equals the parameter pack length;
- every place is `{ tag = "local", id = string }`;
- every place ID is unique;
- for each index `i`, `context.locals[place_i.id]` exactly equals
  `{ type = params_pack.items[i] }`;
- MR0 rejects extra locals in the context.

The extra-local rejection is intentional for this slice. Local declarations and
assignment introduce lifetime/order facts that are not part of MR0 yet. When
local-declaration replay exists, this rule should split into an initial
parameter context plus statement-level context transitions.

## Function Value

`FunctionNode(rule = closed_arrow_body, inputs = { arrow, param_context_node, body_node }, outputs = { claim })`

Inputs:

- `arrow`: term ID of sort `type`;
- `param_context_node`: accepted `BinderNode(closed_params_context)`;
- `body_node`: accepted `StmtNode(return_closed)`.

Replay checks:

- `arrow` is a well-formed MR0 arrow type;
- `param_context_node` is accepted and its `params_pack` exactly equals
  `arrow.params`;
- `body_node` is accepted and its `expected_pack` exactly equals
  `arrow.returns`;
- output is exactly `{ claim = { type = arrow } }`.

This node proves the value-level function claim. It does not prove calls by
running the function body. Calls are still checked by `CallNode(call_arrow)`
against the exported arrow claim and explicit argument pack movement.

## Root Validation

MR0 currently checks only that a root points at an accepted proof. That is too
weak for function exports because an accepted `return_closed` node is not a
function value proof.

For this slice, root validation must become kind-aware:

```text
root.kind = "function_signature_export"
```

Replay checks:

- `root.proof` names an accepted `FunctionNode(closed_arrow_body)`;
- the function node output is a value claim whose type is an arrow;
- `root.subject` is metadata only and is not used for lookup semantics.

Declaration/module export provenance remains outside MR0. This root kind only
asserts that the certificate exports a function claim for the target fixture.

## Accepted Shape

The accepted certificate for the target example has this proof chain:

```text
BinderNode(closed_params_context)
ExprNode(local_read)
PackNode(values_closed)
SubNode(integer_to_number)
PackMoveNode(closed_return_adjust)
StmtNode(return_closed)
FunctionNode(closed_arrow_body)
Root(function_signature_export)
```

The local read and return chain are source-independent:

```text
context c_body:
  p0 -> { type = integer }

place p0:
  { tag = "local", id = "p0" }
```

The binder node connects `p0` to the first arrow parameter. The return node
connects the produced expression pack to the arrow return pack.

## Rejected Shapes

The implementation slice should add adversarial fixtures for:

- parameter context local type does not match the corresponding arrow parameter;
- parameter place list has duplicates;
- parameter place list length differs from the arrow parameter length;
- parameter context has extra locals;
- function node names a non-arrow type;
- function node output chooses a different arrow claim;
- function node body return expects a pack different from `arrow.returns`;
- function-export root points at a `StmtNode` instead of a `FunctionNode`;
- function-export root points at an unaccepted proof;
- binder node uses source names instead of place terms.

## Deferred Rules

This slice intentionally rejects:

- local declarations inside the body;
- assignment or mutation;
- multi-statement blocks;
- implicit nil padding or vararg adjustment outside existing closed pack moves;
- closures/upvalues;
- recursion;
- overload exports;
- generic functions;
- typed effects;
- assertion postconditions.

Those features require context transitions, declaration environments, or richer
arrow payloads. Adding them here would make the body replay rule carry hidden
semantics.

## Mechanization Note

The intended kernel statement is:

```text
wf_arrow A
closed_params_context Γ A.params ps
Γ ⊢ body ⇓ return A.returns
-------------------------------- closed_arrow_body
⊢ function(ps, body) : A
```

The replay verifier checks a first-order certificate for those premises. It
does not search for parameter bindings or infer return movement.
