# Package Versioning: Conflict Handling

How crescent handles version conflicts when two packages require different versions of the same dependency.

## The Constraint

Crescent uses a flat `lib/` layout. Every package in a project resolves `require("lib.foo")` to the same `lib/foo/init.lua`. There is no per-package path isolation. This is a consequence of how LuaJIT's module system works: `package.path` is global, and `require` caches by module name in `package.loaded`. Once `lib.foo` is loaded, every subsequent `require("lib.foo")` returns the same cached table regardless of which package called it.

For minor and patch versions within a major, this is a real constraint: the project can only carry one version of any given `lib/foo/vN/` directory. The tradeoff is that `lib/` is a directory you understand, commit, and own.

For major versions, the constraint does not apply — see "Versioned subdirectories" below.

## Prior Art

| Ecosystem | Strategy | Applicable to crescent? |
|-----------|----------|------------------------|
| npm/Node | Multi-version via nested `node_modules/`; each package gets its own `require` resolution rooted at its own directory | No. Lua's `require` is global. Replicating npm's resolution would require patching `package.loaded` and `package.path` per-call — destroying hackability and making load order matter in surprising ways. |
| Cargo | Each crate compiled separately; multiple versions coexist as distinct compilation units with explicit `extern crate` | No. Crescent has no compilation step. There is no linker to assign distinct symbols per version. |
| Go modules | MVS (minimum version selection): given a set of constraints, pick the minimum version that satisfies all of them. Breaking changes require a new module path (`v2`, `v3`). | Yes. MVS is the right algorithm for single-version resolution within a major. The new major = new path convention is exactly what crescent's versioned subdirectories provide. |
| Bundler / Hex | SAT solver; single version per package per project; conflicts are errors | Structurally the same outcome as crescent's approach within a major version. SAT is heavier than needed if the constraint language stays simple (semver ranges). |
| Nix / pnpm | Content-addressed store; symlinks give each package its own view of its dependencies | No. Symlink forests and content-addressed paths destroy the `lib/foo` convention. The user can no longer read `lib/` as a flat list of what is installed. Vendoring stops making sense. |

## Options

### Option A: Single-version + MVS (foundation)

Collect all version constraints across the full dependency tree. For each package name at a given major version, find the minimum version that satisfies every constraint that mentions it. If no such version exists, error.

This is what Go modules do within a major. Crescent relies on semver semantics (minor bumps are backward compatible) instead of a compiler to enforce it.

**What the current code does:** `install.lua` runs BFS over the dependency graph and calls `semver.satisfies` against the selected version when a package is re-encountered. If a transitive dep requires `foo ^1.2` but `foo 1.5.0` is already selected, `semver.satisfies(1.5.0, "^1.2")` returns true and install continues. If it requires `foo ^2.0`, the check fails and the install errors. The conflict-error is not a placeholder — it is the right response when MVS has no solution within a major version.

What is incomplete: the current resolver resolves each package independently against the lockfile and registry, then checks conflicts after the fact. A proper MVS implementation would collect all constraints first, then pick the minimum satisfying version in one pass. The current approach can select a version that satisfies the direct constraint but fails a transitive one discovered later, causing a retry loop in principle (though BFS order makes this unlikely in practice).

**Tradeoffs:**
- Simple. One version per `lib/foo/vN/`, no surprises.
- Errors are honest: if two packages genuinely need incompatible minor versions, the conflict is surfaced rather than silently loading the wrong one.
- Relies on the ecosystem respecting semver. A patch release that breaks the API causes a silent regression, same as in any single-version ecosystem.

### Option B: Versioned subdirectories (adopted)

Install packages into `lib/<name>/v<N>/` where `N` is the major version. Multiple major versions coexist as separate directories: `lib/foo/v1/` and `lib/foo/v2/`.

**The original objection to this approach was:** "the version suffix is an install artifact — it doesn't exist when the package is written, so you'd need path rewriting at install time." This objection no longer applies.

**The new design resolves it:** the version subdirectory is known at author time because the author writes the require path. A package that targets `foo` 2.x writes `require("lib.foo.v2")` and `require("lib.foo.v2.util")` in its own source during development. Its repo contains `lib/foo/v2/`. The package manager hardlinks/copies files there for consumers. No path rewriting, ever. Require paths are honest at author time.

This means `lib.foo.v1` and `lib.foo.v2` are distinct `package.loaded` keys. The modules are independent. There is no conflict to resolve between major versions — they just coexist in `lib/`.

**Tradeoffs:**
- Major-version conflicts are eliminated structurally. No SAT solver, no MVS complexity across major versions.
- Require paths are stable and explicit. `require("lib.foo.v2")` means exactly what it says regardless of what other versions are installed.
- Authors must decide their major version at development time and write it into their require paths. This is not a burden — it is the same discipline Go modules require.
- Minor and patch versions within a major still use single-version + MVS. `lib/foo/v2/` has exactly one installed version of `foo` 2.x.

If the author ships a `lib/foo/init.lua` redirect in their tarball, it lands
after extraction. The package manager does not generate this file. Authors who
want `require("lib.foo")` to work write the redirect themselves and include it
in the tarball. Authors who don't include it require callers to use the explicit
versioned path.

### Option C: Package-local dep dirs

Each installed package gets its own dependency subtree: `lib/sha1/lib/base64/` for `sha1`'s dependency on `base64`, separate from the project's direct `lib/base64/`. Load-time path patching makes each package find its own subtree.

This is what npm does. The problems in a Lua context:

- `package.loaded` is keyed by module name, not path. Two loaded versions of `lib.base64` would clobber each other in the cache unless the require path is made unique per version — which brings you back to Option B.
- Patching `package.path` at load time is fragile. Load order changes behavior. Any package that calls `require` at module level (i.e., most packages) would need careful sequencing.
- `lib/` becomes a tree rather than a flat list. The user can no longer inspect installed packages by reading one directory. Hackability degrades.
- If two packages load different versions of a shared package, they get different table instances. Any protocol that passes values between them (including FFI structs — see below) silently breaks.

Option C trades one honest error (conflict at install time) for many silent runtime failures (incompatible values passed between packages at runtime). That is a worse outcome.

### Option D: Compat-first ecosystem policy

Mandate that breaking changes require a new package name, not a new version. `sha1` stays `sha1` forever; if the API changes incompatibly, it becomes `sha1v2`. Any version of `sha1` can coexist with any other version of `sha1` in the dependency graph because they are different packages with different names.

This is Go's `v2+` convention applied at the package name level rather than the import path level.

**Tradeoffs:**
- Eliminates the version conflict problem structurally. Single-version resolution always finds a solution because packages with incompatible APIs have different names.
- Requires discipline from package authors. Nothing in the tooling enforces it.
- Package names proliferate over time (`sha1`, `sha1v2`, `sha1v3`). Discovery becomes harder.
- With versioned subdirectories (Option B), Option D is largely redundant — major-version coexistence is already handled structurally. Option D remains worth stating as ecosystem policy for packages that don't use the `vN` convention.

## The FFI Identity Problem

Options C and nested-path approaches assume that having two versions of a package in memory simultaneously is merely an inconvenience to route around. In LuaJIT, it can be a correctness failure.

Consider a package that defines an FFI struct and exports it:

```lua
ffi.cdef [[ typedef struct { int x; int y; } Point; ]]
local M = {}
function M.make(x, y) return ffi.new("Point", x, y) end
return M
```

If two versions of this package are loaded — say `1.0.0` with `{ int x; int y; }` and `2.0.0` with `{ int x; int y; int z; }` — and a value from one is passed to a function expecting the other's layout, the result is a memory corruption bug. LuaJIT's FFI does not do runtime layout checks on struct ctype values.

This is qualitatively different from the npm situation, where two versions of a module produce plain JavaScript objects and the worst case is a missing field or a type error. In LuaJIT, the struct layout is baked into the ctype at `ffi.cdef` time, and passing a value of the wrong ctype to a C function produces undefined behavior.

**Versioned subdirectories resolve this.** `lib.foo.v1` and `lib.foo.v2` are distinct module identities with distinct `package.loaded` keys. Each version's FFI types are independent. A value from `lib.foo.v1` is never passed to a function from `lib.foo.v2` unless the caller explicitly bridges them — in which case the caller owns that decision. The hazard is gone.

Within a major version (single-version + MVS), FFI identity is preserved: there is exactly one loaded instance of `lib.foo.v2`, so all consumers share the same ctype definitions.

## Recommendation

**Use Option B (versioned subdirectories under `lib/`) as the solution for major-version conflicts. Use Option A (single-version + MVS) within each major version.**

The `lib/foo/v1/` and `lib/foo/v2/` directories coexist without conflict. `package.loaded` keys are distinct. FFI identity is preserved per major version. The package manager installs both without conflict. A `lib/foo/init.lua` redirect, if present, was shipped by the author as part of the package — the package manager does not generate it.

MVS is simple to implement correctly and produces deterministic results for minor/patch evolution. The current code's post-hoc conflict check is functionally correct but should be replaced with a proper two-pass resolver: collect all constraints first, then pick versions. This is a straightforward improvement, not a redesign.

Option D (compat-first naming) remains worth publishing as registry guidance, but it is no longer the primary mechanism for handling major-version conflicts — Option B handles that structurally.

**What this means for the current implementation:**

The conflict error in `install.lua` (lines 814–817) is correct and should stay — it fires when two packages require incompatible minor versions of the same major. What needs to improve:

1. Two-pass resolution: collect all transitive constraints into a single table, then call `resolve` once with all constraints. This ensures the selected version satisfies every requirement in the graph before any package is fetched.

2. Better conflict messages: when MVS has no solution, report which packages impose the conflicting constraints, not just which version was selected and which constraint failed.

3. Install paths: update `link_package` and `dep_ok` to use `lib/<name>/v<N>/` instead of `dep/<name>/`. The major version `N` is determined from the resolved package's `pkg.lua`.

4. Redirect files: do not generate `lib/<name>/init.lua`. If the tarball includes one, it lands as part of normal extraction. No special handling required.

5. Registry documentation: publish a compat policy that strongly recommends versioned subdirectories for packages that export FFI types or make breaking API changes, and consider encoding `api_version` in `pkg.lua` as a machine-checkable signal. Design TBD.
