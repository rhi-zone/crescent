# Typechecker v7 Canonical Inputs

This document specifies the M2 boundary for deterministic MR0 certificate
inputs.

Canonicalization is not a type rule. It is the input-integrity layer that makes
certificate replay reproducible and reviewable. The verifier may run without
strict IDs for hand-written fixtures, but external certificates should be
accepted only when their IDs and digests match the canonical semantic payloads.

## Scope

This spec covers the MR0 payloads admitted so far:

- terms;
- immutable MR0 contexts;
- replay nodes;
- roots;
- certificate envelopes.

It does not choose a source parser, annotation elaborator, package format, or
stdlib profile. Those are producers of certificate inputs, not kernel semantics.

## Canonical Value Encoding

The canonical serializer is a deterministic tree encoding over the semantic
payload shape:

- `nil`;
- booleans;
- strings;
- integer numbers;
- non-integer Lua numbers encoded by IEEE-754 binary64 runtime bits;
- arrays with dense integer keys from `1..n`;
- maps with string keys sorted lexicographically.

Rejected:

- NaN;
- sparse arrays;
- mixed numeric/string table keys;
- function/thread/userdata values;
- host-object identity;
- metatables.

Numeric encoding is by runtime value identity, not source spelling. Integer Lua
numbers use the existing integer encoding. Non-integer Lua numbers use the
target runtime's IEEE-754 binary64 bit pattern:

```text
number 0.5   -> f:3fe0000000000000
number -0.0  -> f:8000000000000000
number +inf  -> f:7ff0000000000000
number -inf  -> f:fff0000000000000
```

NaN is rejected because NaN has many payload bit patterns and does not compare
equal to itself. If a future target needs NaN as a source/runtime fact, it must
introduce an explicit target-profile payload rather than smuggling host NaN
identity through canonicalization.

Cdata numerics are not Lua numbers and remain outside MR0 canonical values.

## Term IDs

Terms are content-addressed by sort and payload:

```text
term_id = "t:" .. sha256(canonical({
  sort = term.sort,
  payload = term.payload
}))
```

The term ID excludes `term_id` itself and any fixture/display metadata.

Current implementation status:

- `canonical.term_id(sort, payload)` exists;
- verifier `strict_ids` checks terms only;
- non-integer Lua numeric payloads are encoded as binary64 runtime bits;
- NaN payloads are rejected in strict mode.

## Context IDs

MR0 context IDs are content-addressed over the immutable semantic context:

```text
context_id = "c:" .. sha256(canonical({
  locals = context.locals,
  identities = context.identities or {},
  live_facts = context.live_facts or {},
  dependencies = context.dependencies or {}
}))
```

The context ID excludes:

- `context_id`;
- source scope names;
- source file positions;
- fixture metadata.

For the current MR0 local-read subset, `identities`, `live_facts`, and
`dependencies` must be empty. They are still included in the digest shape so
future context extensions cannot alias older IDs.

## Node IDs

Replay nodes are content-addressed by the replay rule and declared proof
interface:

```text
node_id = "n:" .. sha256(canonical({
  family = node.family,
  rule = node.rule,
  inputs = node.inputs or {},
  premises = node.premises or {},
  outputs = node.outputs
}))
```

The node ID excludes:

- `node_id`;
- comments;
- source locations;
- display labels;
- dependency metadata that is not a replay premise.

Including `outputs` is deliberate. A node's claim is part of what replay checks.
If two nodes share rule/input/premises but assert different outputs, they must
not collide.

Premises are ordered where the rule gives them order. For example:

- `PackMoveNode` premises are one subtyping proof per slot;
- `PackNode(values_closed)` premises are one value producer per claim;
- `StmtNode(return_closed)` premises include the expression-pack producer and
  return pack movement.

Rules that require unordered premise sets must introduce their own normalized
payload shape before they can be admitted.

## Root IDs And Certificate Digest

Roots are not currently content-addressed individually. They are part of the
certificate digest:

```text
certificate_digest = sha256(canonical({
  version = cert.version,
  target = cert.target,
  sources = cert.sources or {},
  declarations = cert.declarations or {},
  terms = cert.terms or {},
  contexts = cert.contexts or {},
  nodes = cert.nodes or {},
  roots = cert.roots
}))
```

External certificates should carry this digest out-of-band or in an envelope
field excluded from the digest projection.

## Target, Source, And Declaration Digests

External JSON certificates validate input digests before replay.

Target digest:

```text
target.digest = "target:" .. sha256(canonical({
  id = target.id,
  table_digest = target.table_digest
}))
```

The target digest commits to the target profile identity and the target table
digest named by the certificate. It excludes display/provenance metadata.

Source digest:

```text
source.digest = "source:" .. sha256(canonical({
  source_id = source.source_id,
  content = source.content
}))
```

`path_hint` is deliberately excluded. It is diagnostic/provenance metadata and
must not affect semantic equality. If a certificate does not carry source bytes,
this digest only commits to the source identity declared inside the certificate;
checking bytes on disk is a driver/elaborator responsibility, not replay.

Declaration digest:

```text
declaration.digest = "decl:" .. sha256(canonical({
  decl_id = declaration.decl_id,
  entries = declaration.entries or {},
  trust_kind = declaration.trust_kind
}))
```

Declaration provenance may be attached later, but provenance cannot authorize
new claims. Replay-relevant trusted entries and trust kind are what the digest
commits to.

## External Certificate Boundary

M2 separates two concepts:

- semantic canonical projection;
- concrete wire format.

The semantic projection above is mandatory.

The first authoritative external wire format is JSON:

```text
MIME: application/vnd.crescent.typecert.v7-mr0+json
Extension: .crtypecert.json
Top-level value: certificate object
```

JSON is chosen as the interchange/debug format because certificates are audit
artifacts. Humans and tools should be able to diff them without a Crescent
runtime.

The JSON subset is schema-directed:

- top-level `terms`, `contexts`, `nodes`, and `roots` are arrays;
- replay maps such as `inputs`, `outputs`, `locals`, `target`, and `claim`
  are objects;
- omitted optional fields use the defaults named by this spec;
- JSON `null` is rejected.

JSON `null` is rejected because Lua cannot store `nil` in arrays/maps without
changing the semantic shape. MR0 payloads that need a nil type already spell it
as the string atom `"nil"` or an explicit tagged payload, not JSON null.

The existing Lua JSON decoder, like normal Lua APIs, represents both `{}` and
`[]` as an empty table. Therefore external JSON must be interpreted through the
certificate schema before digest/replay. Empty-container kind is not semantic by
itself; the field position supplies the kind.

Acceptable wire formats must:

- decode only the canonical value domain or reject before replay;
- preserve array order exactly;
- preserve string map keys exactly;
- not expose host-object identity;
- not infer omitted semantic fields except where this spec names a default;
- round-trip to the same canonical projection.

The verifier should eventually expose two entry points:

- `verify_table(cert, opts)` for in-process fixture tables;
- `verify_external_json(bytes, opts)` for JSON certificate bytes.

`verify_external_json` must validate the certificate digest and strict IDs before
replay. The expected digest is supplied out-of-band; an in-file digest field is
metadata and is excluded from the certificate digest projection.

External JSON also enables target/source/declaration digest validation. In-process
fixtures may keep using placeholder digests unless a strict option asks for
these checks.

## Binary Cache Format

A LuaJIT-optimized binary certificate encoding is allowed later, but it is not
the first authoritative external format.

Binary encodings are cache formats unless they satisfy the same obligations as
JSON:

- decode to the same schema-directed semantic projection;
- produce exactly the same `certificate_digest`;
- reject unsupported numeric and host-object payloads;
- not introduce replay behavior that JSON certificates cannot express.

This keeps performance engineering separate from the soundness/review boundary.
An implementation may store binary certificates beside JSON certificates, but
the JSON projection remains the portable interchange form.

## Strictness Levels

Implementation may stage strictness:

- `strict_terms`: verify all term IDs.
- `strict_contexts`: verify all context IDs.
- `strict_nodes`: verify all node IDs.
- `strict_certificate`: verify the full certificate digest.

The final external-certificate mode should enable all of them.

The current option name `strict_ids` is term-only historical shorthand. Before
external certificates are admitted, it should either become strict-all or be
split into explicit strictness flags.

## Malformed-Input Corpus

M2 needs fixtures that reject:

- non-canonical term IDs;
- non-canonical context IDs;
- non-canonical node IDs;
- target digest mismatch;
- source digest mismatch;
- declaration digest mismatch;
- duplicate IDs with different payloads;
- duplicate IDs with identical payloads;
- sparse arrays in inputs/premises/roots;
- non-string map keys;
- non-integer numeric literals;
- roots whose proof IDs are missing;
- `function_signature_export` roots whose proof is not a function node;
- certificates whose digest excludes a replay-relevant field.

## Design Blocks

NaN and cdata numeric canonicalization remain design blocks. They affect target
profiles, equality/order facts, and digest stability. Until they are specified,
external strict mode must reject them rather than canonicalize them by host
formatting or host object identity.

The concrete external wire format decision for MR0 is JSON. A binary cache
format remains open and must be proven equivalent to the JSON semantic
projection before it is admitted.
