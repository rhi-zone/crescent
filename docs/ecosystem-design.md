# Crescent Ecosystem Design

## Identity

Crescent is an ecosystem, not a LuaJIT ecosystem. LuaJIT is the first and primary
runtime, but the identity is the ecosystem itself — the package manager, typechecker,
stdlib, tooling conventions, and the values they embody. The runtime is a given; the
ecosystem is the layer on top.

The values: vendorable, pure, fast, hackable, composable. Every library is a set of
files you can copy into your project and own. No build step, no privileged runtime
access, no opinions you can't replace.

## The Standard Library

### What it is

The stdlib (`lib/`) is the seed of the ecosystem — the most trusted, most complete set
of libraries, designed as a coherent whole. It is not privileged: imported the same way
as any other package, no special runtime relationship, fully vendorable. The difference
from any other library is quality and intentionality, not access.

The model is Go's standard library: comprehensive, coherent, designed together, no
external dependencies needed for serious work. `import "net/http"` and
`import "github.com/some/library"` are the same operation.

### What it is not

Not a curated set of opinions about implementations. The stdlib defines interfaces —
stable contracts that any implementation can satisfy. The ecosystem converges on the
interfaces, not on the implementations. Concrete stdlib implementations are the
reference implementations: the best possible answer to "what does a crescent X library
look like?", not the only permissible answer.

### Completeness

If it's in the spec, it's in the library. Usage frequency does not determine inclusion.
Partial implementations create pressure to abandon rather than extend, and a reference
implementation that omits edge cases isn't a reference implementation.

## Design Process

### Interfaces first

Core interfaces are designed before implementations. The bottom-of-stack libraries
(buffers, streams, allocators) are the reference implementations of those interfaces —
the proof that the interfaces are actually implementable and ergonomic.

Libraries are written in dependency order: bottom of the stack first. You cannot write
HTTP before you have streams. The order is determined by the dependency graph, not by
what seems useful next.

### API design from the outside in

For each library, write the usage first. What does code that *uses* this library look
like when written well? Then derive the interface from the call sites. This applies at
every layer, including top-of-stack libraries with no stdlib consumers — their interface
is informed by the use cases of real programs.

### Two constraints on every implementation

1. **The spec** — defines completeness. Every RFC section, every protocol behavior,
   every edge case. No omissions.
2. **The use cases** — define ergonomics. The interface makes real code look good.

Spec alone produces complete but ergonomically terrible APIs. Use cases alone produces
pleasant but incomplete APIs. Both together produce something complete, correct, and
ergonomic.

## Spec Traceability

Every spec-derived constant, branch, and function carries a reference to the spec
section it implements (e.g. `-- RFC 9110 §9.3.1`). This is a convention, not a
process — written at implementation time, costs nothing, enables independent
verification.

With traceability, a reader can audit: here is the spec section, here is the
implementation, do they match? Without it, "we have tests" is confidence, not
verifiability.

Specs change rarely in ways that affect implementations. HTTP core semantics have had
three major revisions in 25 years; crypto specs essentially never change. Maintenance
cost is negligible if the references are written from the start.

## Conformance Testing

Tests prove the cases you thought of. Conformance tests prove the spec. For each
protocol library, conformance tests cover every behavior the spec defines — run against
real implementations, checked against RFC requirements.

For libraries with multiple implementations (tiered or competing), parity tests assert
byte-for-byte identical output. Parity fuzzing generates random inputs and runs all
implementations. Benchmarks measure each implementation on representative inputs.
None of this is optional polish — the implementation is not done until all three exist.

## The Ecosystem

The stdlib sets the bar. Third parties write libraries against the same interfaces, with
the same conventions. The best implementations win by merit, not by privileged
distribution. Our top-of-stack libraries (HTTP, crypto, serialization) are the de facto
choice until something better exists — but not the only choice.

The ecosystem is comprehensive because the interfaces are stable and the conventions are
clear, not because we wrote everything. The stdlib's job is to make the right patterns
the natural patterns.

## The Package Manager and Registry

### Vendor-first

Dependencies are committed to VCS. `cr install` populates `dep/` in user projects.
No network required to build. You own your dependencies.

### The registry as curation layer

The registry maps short names to GitHub repos. It is maintained by the crescent project,
not by package authors — a package does not need to know crescent exists to be listed.
`cr add lunajson` resolves through the registry to the upstream GitHub repo. The registry
is the curation layer; the source of truth is always the upstream repo.

This makes the entire Lua/LuaJIT ecosystem accessible through `cr add`, regardless of
whether authors have adopted crescent conventions. Quality and convention compliance are
our concern for `lib/`; the registry lists anything worth listing.

### The distribution has no external dependencies

`lib/` is self-contained. Libraries in the stdlib do not depend on packages outside the
repo. If a stdlib library needs JSON parsing, it has a crescent-native JSON
implementation in `lib/`, not a vendored third-party package. Currently vendored
packages (`dep/lunajson`, `dep/sha1`, etc.) are stopgaps predating the package manager
— they will be replaced with native implementations or removed as the stdlib matures.

Third-party packages that predate crescent (lunajson, sha1, etc.) belong in the
registry, available via `cr add`, but not in `lib/`. Their interfaces may not be
consistent with crescent's conventions; stdlib implementations are written from scratch
to meet the bar.

## Interface Design: Tradeoffs Are Real

Every interface decision involves tradeoffs, and the stdlib must acknowledge them rather
than picking one option and forcing it on all callers. The canonical example is parsing:

- **Ergonomic** — returns materialized strings. Easy to use, allocates per-parse.
- **Positional / zerocopy** — returns `(start, end)` integer pairs into the original
  buffer. Zero allocation, but the caller must call `string.sub` explicitly.

These are not tiers (same interface, different performance) — they are genuinely
different interfaces with different consumers. Both belong in the stdlib. The pattern is
multiple named implementations in the same namespace, each clear about what it does:
`require("lib.http.parse")` vs `require("lib.http.parse.raw")`. The caller picks.

This is not a mess — it is composability. Multiple implementations with coherent
interfaces are a menu, not chaos. The mess comes from inconsistent conventions, not from
having options. This is why interface design comes first: with solid interfaces, multiple
implementations compose cleanly.

### Tradeoffs are universal

Parsing tradeoffs (ergonomic vs zerocopy, streaming vs buffered) are not specific to
HTTP. They apply to every parser: JSON, CSV, binary protocols, everything. The interface
design belongs in a general parsing abstraction (`lib/parse/`), not in each protocol
library. HTTP is a consumer of the parsing interface, not the place where it is defined.

### Deriving the bottom of the stack

Bottom-of-stack interfaces are derived from real consumers, not guessed. Follow the
dependency graph of concrete libraries downward until you find things with no
dependencies — those are the primitives. Do not design primitives in isolation and hope
they fit; design them by following what real libraries actually need.

## Types as Ecosystem Accelerator

The value proposition of crescent's type system is not correctness alone — it is that
**design accelerates growth**. In a fully-annotated ecosystem, types are simultaneously
documentation, contracts, and discovery. You do not read docs to know what a function
takes; the type tells you. You do not write glue to compose two libraries; their types
either fit or they don't, and the checker tells you immediately.

This compounds: each new typed library makes every other library more composable, because
types are the coordination mechanism and they require no coordination to use.

### Typed holes via `unknown`

A global annotation `_: unknown` is a typed hole — a named placeholder that says "this
position needs a value; its type is not yet determined." The typechecker propagates
`unknown` through every call site that uses it, forcing narrowing everywhere it appears.
No special hole machinery is needed: `unknown` already errors at use sites and already
requires explicit narrowing. The hole IS the type system.

This means a stdlib definition file can annotate incomplete areas with `_: unknown`, and
the type graph will automatically flag every consumer of an unfinished interface. The
incompleteness is visible and loud, not silent.

### Protocol bindings as typed libraries

A protocol library (`lib/lsp`, `lib/mcp` (Model Context Protocol), `lib/jsonrpc`) ships with every method
pre-typed. You implement handlers; the types are already there. The protocol definition
*is* the library — you do not write schemas, you do not duplicate type information, you
simply register a handler and the typechecker validates it against the protocol spec.

```lua
local lsp = require("lib.lsp")
lsp:on_hover(function(params)   -- params: HoverParams, return: Hover
    return { contents = "..." } -- typechecked against the LSP spec
end)
lsp:serve()
```

This pattern applies to any protocol: LSP, MCP, JSON-RPC, OpenAPI. The substrate is
`lib/jsonrpc`; the bindings are typed method registrations. Different protocols, same
primitive.

## Access Control (deferred)

Access control design is intentionally deferred. The wrong approach is to inherit
mechanisms from Java/C#/TypeScript — those assume nominal types, class hierarchies, and
compilation units as visibility boundaries, none of which map onto crescent's model.

The right approach is to design access control from first principles: what violations
does a crescent programmer actually want the typechecker to catch? The answer should be
derived from the ecosystem's values, not borrowed from languages with different
assumptions.

Tracked in TODO.md.
