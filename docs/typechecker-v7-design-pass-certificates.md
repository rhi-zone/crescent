# Typechecker v7 Design Pass: Certificates

This pass decides the cross-cutting certificate schema.

The certificate is not a diagnostic trace and not a dump of inference state. It
is a replayable proof object for accepted claims. The production checker may
search, normalize, cache, or use heuristics, but acceptance depends on whether a
deterministic verifier can replay the certificate against the v7 kernel and its
explicit inputs.

## Decision

Use a finite DAG of typed certificate nodes.

Every accepted top-level claim must be reachable from a root node:

```text
Certificate = {
  kernel_version,
  context_inputs,
  term_table,
  node_table,
  roots
}
```

The verifier accepts only if:

- every referenced input is present and hash-matches;
- every term is well-formed in the declared kernel version;
- every node checks by one kernel rule;
- every root claim follows from its referenced node;
- every unsafe/trusted boundary is explicit and allowed at that site.

The verifier must not infer missing branches, discover overload choices, search
for a subtyping derivation, choose a normalization path, or repair omitted
invalidation steps.

## Certificate Context

Certificate context is immutable.

```text
ContextInputs = {
  TargetProfile,
  ModuleEnv,
  DeclEnv,
  FfiEnv,
  SourceDigest*
}
```

Each input has:

```text
InputRef = {
  kind,
  stable_id,
  digest,
  trust_kind,
  provenance
}
```

Changing a target profile, declaration file, module interface, FFI declaration,
or source digest invalidates dependent certificates. The checker must not
silently reuse a certificate under a different context.

## Term Table

Large semantic terms are interned by stable IDs:

```text
Term ::= Type | Pack | Effect | Postcondition | Predicate | Place
       | Context | ValueClaim | PackClaim | EnvironmentEntry
```

The term table is not proof. It is shared data. Every term used in a proof node
still needs the relevant well-formedness or environment node unless the node rule
declares that term well-formedness as an inline premise.

Stable IDs are structural within a certificate and must be deterministic for
equivalent inputs. Source spans and display names may be attached as provenance,
but they are not part of semantic equality unless the kernel rule explicitly
uses a binding identity.

## Node Shape

All nodes share a common envelope:

```text
CertNode = {
  id,
  family,
  rule,
  inputs,
  outputs,
  premises,
  dependencies,
  provenance
}
```

`premises` are proof-node IDs. `dependencies` are mutable or external facts that
can invalidate the node, such as table identity state, metatable fields, module
environment digests, or target-profile operation tables.

`provenance` is for diagnostics and auditing. It cannot make an invalid node
valid.

## Node Families

The initial families are:

```text
WFNode              -- well-formed types, packs, effects, posts, predicates, places
SubNode             -- subtyping, pack movement, effect ordering, equality-as-mutual-subtyping
KindNode            -- kinding of type-level terms
ReduceNode          -- deterministic type-level reduction / normalization
ExprNode            -- expression value claims
StmtNode            -- statement context transitions
CallNode            -- ordinary calls and overload calls
OpNode              -- overloadable operators
ControlFlowNode     -- truthiness, if, and/or, branch joins
PostNode            -- normal-continuation fact application
IdentityNode        -- table/reference identity transitions and invalidation
MetatableNode       -- lookup, assignment, and metamethod dependency proofs
PrimitiveCallNode   -- use of primitive capabilities
GenericNode         -- forall intro/elim, skolemization, escape checks
GuardNode           -- proof-producing guards
AssertNode          -- assertion postcondition proofs
EnvNode             -- environment/profile imports
ModuleNode          -- checked or declared module interface proofs
UnsafeNode          -- explicit unsafe/trusted boundary
RootNode            -- exported checked claim
```

Families are coarse. The `rule` field names the exact kernel rule inside the
family. Adding a new `rule` is a kernel-extension event unless it is already
specified by the relevant design pass.

## Deterministic Replay

Replay is node-local.

For each node, the verifier:

1. loads the referenced inputs and prior nodes;
2. checks all premises already validate;
3. checks the node's rule-specific preconditions;
4. recomputes the output claim or context transition;
5. compares the recomputed output with the node output.

No global search is allowed during replay.

Allowed deterministic computation:

- structural equality of interned terms;
- kernel-specified normalization with explicit `ReduceNode`s or a declared
  canonicalization algorithm;
- target-profile table lookup by stable key;
- environment lookup by stable input digest;
- dependency invalidation checks against explicit context transitions.

Rejected replay behavior:

- searching for an overload branch not named in the certificate;
- trying subtyping rules until one works;
- normalizing until a budget happens to succeed without recording the reduction;
- accepting budget failure as evidence;
- widening failed claims to `unknown`;
- treating an unsafe boundary as a proof of the underlying semantic relation.

## Roots And Exported Claims

Root nodes state what the checker is accepting:

```text
RootNode(kind, subject_id, exported_claim, proof)
```

Examples:

- local annotation accepted;
- function signature exported;
- overload declaration exported;
- module interface exported;
- declaration import accepted;
- unsafe boundary exported.

Every user-visible accepted claim must be reachable from a root. Internal
intermediate nodes may be omitted only if no root depends on them.

## Unsafe And Trusted Boundaries

Unsafe and trusted nodes are not ordinary proof nodes.

```text
UnsafeNode(site, exported_claim, boundary_kind, reason, provenance)
```

The verifier checks:

- the kernel admits an unsafe/trusted boundary for this boundary kind;
- the exported claim is well-formed;
- the claim is marked unsafe in audit output;
- later nodes that depend on the claim preserve its trust provenance.

The verifier does not check that the unsafe claim is true. That is why the node
must be visible and auditable.

Primitive capabilities exported through unsafe boundaries are especially
powerful because they authorize kernel state transitions. They should require a
distinct boundary kind, not a generic force-cast bucket.

## Dependencies And Invalidation

Certificates must represent invalidation explicitly enough to prevent stale
facts from being reused.

Dependency examples:

- flow facts depend on stable places and are invalidated by writes/escape;
- record observations depend on table identity state and sealing;
- metatable lookup depends on receiver identity, metatable identity, traversed
  tables, and metamethod fields;
- module claims depend on environment digests;
- target-specific operator results depend on target-profile operation tables.

Context-transition nodes must state which facts are preserved, invalidated, or
re-derived. A later node may use a fact only if the verifier can replay that the
fact is still live in the referenced context.

## Compression

Certificates may be compact, but compression cannot hide semantic work.

Allowed:

- DAG sharing of repeated terms and subproofs;
- hash-consed normalized terms;
- macro nodes only when the macro expands deterministically to admitted kernel
  nodes and the verifier knows the expansion;
- omitting diagnostics-only provenance.

Rejected:

- "checker says yes" summary nodes;
- opaque solver traces;
- caches that cannot be replayed from context inputs;
- proofs that depend on runtime object identity outside the modeled store or
  environment inputs.

## Optional Checking

Proof checking may be optional operationally but not semantically.

Modes can differ in cost:

- normal mode may run without verifying every certificate;
- audit mode emits and verifies certificates;
- CI/release modes choose larger checked sets.

Invariant:

```text
If normal mode accepts and audit mode rejects under the same inputs, normal mode
has a bug.
```

No feature may have "accepted only in non-audit mode" semantics.

## Minimal First Certificate Subset

The first implementable certificate subset should cover:

- literal/value claims;
- local annotations through subtype obligations;
- closed-pack function calls;
- overload body checking under every branch;
- force/unsafe boundaries;
- table identity writes and sealed record observations;
- primitive capability calls for a tiny audited primitive set.

It should not start with the whole Lua surface. Starting with a small but
complete replay subset is the point.

## Adversarial Review

Soundness lens: a verifier that searches is just a second checker. This design
forbids search during replay and requires certificates to name rule choices.

Ad-hocness lens: coarse families could become dumping grounds. The guardrail is
that `family` is not the rule; every `rule` must be in the kernel or an admitted
design pass.

Performance lens: full proof checking can be expensive. The optional-mode
invariant keeps performance choices from changing semantics.

Implementation lens: stable IDs and context digests are boring but load-bearing.
Without them, module/profile/metatable facts can be replayed under the wrong
assumptions.

Audit lens: unsafe nodes must be first-class roots or dependencies, not comments
in diagnostics. Otherwise `any` and force casts can leak back into the sound
algebra.

## Remaining Work

This pass chooses the certificate architecture. Detailed work remains:

1. define exact node payloads for the minimal first subset;
2. decide whether verifier code is generated from a proof assistant, extracted,
   or hand-written against kernel definitions;
3. define canonical term serialization and digests;
4. define audit output for unsafe/trusted boundary roots;
5. write replay tests that mutate context inputs and verify stale certificates
   are rejected.
