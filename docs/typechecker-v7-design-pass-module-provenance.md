# Typechecker v7 Design Pass: Modules, Declarations, And Provenance

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses the direction for modules, declaration imports, target stdlib profiles,
and FFI provenance.

## Question

How do external claims enter the checker?

The checker needs declarations for modules, stdlib bindings, primitive
capability values, FFI symbols, and imported annotations. Those claims are not
proved from the current file's syntax. If they enter through hidden global state,
loader side effects, or fallback `unknown`, the design becomes ad hoc.

## First-Principles Derivation

An external claim is either:

- checked from source under the same kernel; or
- trusted at an explicit boundary.

Therefore every external claim needs provenance:

```text
External claim = Claim + Provenance + TrustKind
```

The provenance says where the claim came from. The trust kind says whether the
kernel checked it or accepted it as a boundary.

## Decision

Choose explicit environment objects as certificate inputs:

```text
TargetProfile
StdlibProfile
ModuleEnv
DeclEnv
FfiEnv
```

These environments are part of the certificate context. They are not global
mutable checker state.

## Environment Roles

### TargetProfile

The target profile fixes runtime dialect assumptions:

- Lua version;
- LuaJIT behavior;
- numeric tower and literal policy;
- coroutine API shape;
- FFI availability;
- protected metatable behavior;
- stdlib profile selection.

Target-specific semantics must be visible in certificates. A proof under
LuaJIT is not automatically a proof under Lua 5.4.

### StdlibProfile

The stdlib profile binds initial global values.

It may introduce primitive capability values:

```text
setmetatable : primitive_cap("$SetMetatable")
getmetatable : primitive_cap("$GetMetatable")
rawget       : primitive_cap("$RawGet")
rawset       : primitive_cap("$RawSet")
```

Caps-first policy belongs here. Ambient `io`, `os`, `debug`, and FFI authority
are absent unless the selected profile explicitly provides capability values.

### ModuleEnv

The module environment maps module identifiers to module interfaces.

```text
ModuleEnv[module_id] = ModuleInterface
```

A module interface contains exported claims plus provenance:

```text
ModuleInterface = {
  exports,
  provenance,
  trust_kind
}
```

`trust_kind` is either checked, declared, or unsafe/trusted.

### DeclEnv

The declaration environment contains annotation-side declarations:

- `--:: require` imports;
- explicit global declarations;
- module-local type aliases;
- augmentation declarations, if admitted later;
- primitive/stdlib declarations selected by profile.

Declarations are per module. They are not global by default.

### FfiEnv

The FFI environment contains parsed or trusted C declarations.

`$FfiC` can project from `FfiEnv` only after:

- the C declaration source is identified;
- parsing/trust status is recorded;
- missing-symbol behavior is specified;
- target ABI/profile assumptions are recorded.

## Runtime Require Versus Annotation Require

Runtime `require` and annotation `--:: require` are related but not identical.

Runtime `require` is a Lua function with loader/cache behavior. It may have
effects and target-specific behavior.

Annotation `--:: require` imports an interface into the static environment.
It does not execute code. It elaborates to a `DeclEnv`/`ModuleEnv` edge.

Both must share module identity/provenance rules so they do not silently refer
to different modules.

## `$Require<T>`

`$Require<T>` is not pure type computation. It is a trusted module-interface
projection:

```text
RequireBridge(module_id, expected_shape) => exported_claim
```

Requirements:

- `module_id` resolves in `ModuleEnv`;
- the module interface has provenance;
- `expected_shape` is checked against the exported interface or explicitly
  trusted;
- unresolved modules reject unless an unsafe boundary is written;
- nonliteral/dynamic module IDs reject in the type-level bridge.

Returning `unknown` for unresolved modules is rejected as recovery behavior.

## `$GlobalScope`

`$GlobalScope` projects from an explicit declaration/global environment.

It must not synthesize ambient globals by scanning checker state.

Requirements:

- selected `StdlibProfile`;
- explicit global declarations;
- no undeclared fallback indexer;
- certificate node listing the environment snapshot.

## `$FfiC`

`$FfiC` projects from `FfiEnv`.

Requirements:

- target profile enables FFI;
- symbol exists in `FfiEnv`;
- missing symbol behavior is specified;
- the projected claim has provenance;
- unsafe/trusted declarations are certificate-visible.

## Module Checking

A checked module exports an interface only after checking its body.

Sketch:

```text
CheckModule(module_id, source, imports) => ModuleInterface
```

The body checks under:

- selected `TargetProfile`;
- selected `StdlibProfile`;
- imported `ModuleEnv` entries;
- module-local `DeclEnv`;
- optional `FfiEnv`.

The exported interface is sealed at the module boundary. Open construction
states cannot leak as record types except through explicit template/certificate
mechanisms.

## Cycles

Module cycles must be explicit.

Options:

- reject cycles initially;
- allow cycles only through declared interfaces;
- use fixed-point checking with explicit interface assumptions.

Decision direction: reject unchecked cycles initially. Permit cycles only when a
declared interface breaks the cycle and every module body is later checked
against that interface.

UNRESOLVED: final cyclic module policy.

## Provenance

Every external claim carries provenance:

```text
Provenance =
  checked_module(module_id, cert_id)
  declared_module(module_id, decl_id)
  stdlib_profile(profile_id, binding)
  target_profile(profile_id, feature)
  ffi_decl(source_id, symbol)
  unsafe_boundary(site_id, reason)
```

Provenance is not a type constructor. It belongs to claims, environment entries,
and certificate nodes.

## Invalidating Environment Claims

Environment entries are immutable for a certificate.

If the user changes a declaration file, FFI declaration, target profile, or
module source, the certificate context changes and dependent proofs are stale.
The checker may cache, but the cache key must include environment provenance.

No proof may depend on "whatever was loaded most recently".

## Rejected Alternatives

### Global Annotation State

Rejected:

```text
all --:: aliases and requires enter one global annotation table
```

Reason: declarations are module-scoped. Global state causes duplication,
shadowing bugs, and unsound visibility.

### File-Local Duplication

Rejected:

```text
copy imported type shapes into each file as unrelated aliases
```

Reason: imported interfaces need shared module identity and provenance. Copying
shapes loses abstraction and nominal/opaque identity.

### Unresolved Require Returns Unknown

Rejected:

```text
unresolved require => unknown
```

Reason: this is recovery widening. A module boundary is either resolved,
declared/trusted, unsafe, or rejected.

### Ambient Stdlib

Rejected:

```text
globals exist because the checker knows Lua
```

Reason: target and stdlib profiles must be certificate inputs. Ambient defaults
hide authority and target assumptions.

## Adversarial Review

### Soundness Lens

The design is sound-oriented because every external claim is either checked or
explicitly trusted. No external type appears without provenance.

Residual risk: trusted declarations can lie. The certificate must make trust
boundaries visible enough for audits.

### Ad-Hocness Lens

The design avoids loader/cache side effects, ambient globals, and unresolved
`unknown` fallback.

Residual risk: implementation may still keep mutable registries internally. That
is fine only if the certificate context is immutable and replayable.

### Modularity Lens

Per-module declarations and `--:: require` edges avoid both global annotations
and file-local duplication.

Residual risk: module identity resolution can become target/tool specific. The
resolution algorithm itself must be a target/profile rule.

### Usability Lens

Rejecting unresolved modules is stricter than fallback unknown.

That is the correct default. Users can add declarations or explicit unsafe
boundaries when they intentionally want to trust external code.

## Decision

Choose:

```text
external claims enter through explicit immutable environments with provenance;
runtime require, annotation require, stdlib profiles, globals, and FFI all
elaborate to those environments or trusted boundary nodes
```

The next design pass should tackle type-level computation and generics/HKTs, or
operator/metamethod rules if runtime expression coverage is prioritized.
