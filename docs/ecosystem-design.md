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

## Access Control (deferred)

Access control design is intentionally deferred. The wrong approach is to inherit
mechanisms from Java/C#/TypeScript — those assume nominal types, class hierarchies, and
compilation units as visibility boundaries, none of which map onto crescent's model.

The right approach is to design access control from first principles: what violations
does a crescent programmer actually want the typechecker to catch? The answer should be
derived from the ecosystem's values, not borrowed from languages with different
assumptions.

Tracked in TODO.md.
