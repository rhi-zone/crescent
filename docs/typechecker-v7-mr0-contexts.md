# Typechecker v7 MR0 Contexts

This document specifies the first context/local replay slice for the table-native
MR0 verifier.

It refines the active frontier in `docs/typechecker-v7-roadmap.md`:

```text
M0 -> M1: context/local replay for source-independent function body certificates
```

## Scope

MR0 contexts are immutable certificate inputs. They are not source scopes, and
they are not the production checker's mutable environment.

This slice admits only enough context machinery to replay local reads and tie an
existing `return_closed` statement to a stable place:

```text
ContextEntry = {
  context_id,
  locals,
  identities = {},
  live_facts = {},
  dependencies = {}
}

locals = {
  [place_id] = value_claim
}
```

MR0 context replay excludes:

- assignment;
- mutation/invalidation;
- control-flow joins;
- field places;
- imported places;
- upvalues;
- identity state transitions;
- fact refinement;
- source-name lookup.

Those exclusions are semantic boundaries. The verifier must reject certificates
that require them.

## Places

MR0 represents places as terms of sort `place`.

Admitted place payload:

```text
place = {
  tag = "local",
  id = string
}
```

The `id` is a stable semantic slot ID. It is not source text. A frontend may
derive it from a source local/parameter, but replay only sees the resolved slot
ID.

MR0 does not distinguish local vs parameter places yet. A function parameter in
source-independent fixtures is represented by a local place in the body context:

```text
{ tag = "local", id = "p0" }
```

This is sufficient for the first body replay slice because no call-site
postcondition substitution occurs in MR0.

Deferred place payloads:

```text
{ tag = "param", id }
{ tag = "upvalue", id }
{ tag = "result", id }
{ tag = "field", identity, key }
{ tag = "imported", id }
```

Admitting any of these requires its own context/fact/invalidation rules.

## Value Claims

A context local maps a place ID to a value claim:

```text
value_claim = {
  type = Type
}
```

MR0 value claims may later carry identity/correlation data. This slice does not
admit that data. Extra fields are preserved by equality but ignored by local
read rules unless a later rule specifies them.

## Context Well-Formedness

`WFNode(rule = wf_context, inputs = { context }, outputs = { ok })`

Replay checks:

- the context term has sort `context`;
- `locals` is a map from string place IDs to value claims;
- every local value claim has a well-formed MR0 type;
- `identities`, `live_facts`, and `dependencies` are empty tables if present.

MR0 rejects a context that contains non-empty identity/fact/dependency entries
because no invalidation semantics are admitted yet.

## Local Read

`ExprNode(rule = local_read, inputs = { context, place }, outputs = { claim })`

Replay checks:

- `context` names a term of sort `context`;
- `place` names a term of sort `place`;
- the place payload is `{ tag = "local", id = string }`;
- the context contains a local entry for that place ID;
- the output claim exactly equals the context's value claim for that place.

No source name is inspected. No lookup fallback exists. Missing locals reject.

## Pack Claim From Values

To connect local reads to existing closed return replay, MR0 admits a minimal
pack-claim node:

```text
PackNode(rule = values_closed, inputs = { claims }, outputs = { claim })
```

where `claims` is an ordered list of term IDs of sort `value_claim`.

Replay checks:

- every input claim term exists and is sort `value_claim`;
- every claim contains a well-formed type;
- output is exactly `{ pack = { tag = "pack", items = [claim.type...], rest = nil } }`.

This is not expression-list spread. It is the closed scalar value-list
constructor. Multi-return spread and `PackAlt` remain outside MR0.

## Adversarial Fixtures

Accepted:

- context with local place `p0: integer`;
- local read of `p0` returns `{ type = integer }`;
- `values_closed([p0_claim])` creates `pack_claim(integer)`;
- `return_closed` moves that pack to expected `number` through a named
  `integer <: number` return movement.

Rejected:

- local read through a source name rather than a place term;
- local read of a missing place;
- context with non-empty `live_facts`;
- context local whose value claim has an unsupported type;
- `values_closed` output that chooses a different pack;
- `values_closed` over a non-`value_claim` term.

## Mechanization Note

This slice should translate to a proof assistant as finite maps and lookup
lemmas:

```text
wf_context Γ
lookup Γ.locals p = claim
-------------------------------- local_read
Γ ⊢ local_read(p) ⇓ claim
```

No mutation theorem is needed for MR0 because contexts are immutable inputs and
local reads do not change them.
