# Package Versioning: Conflict Handling

How crescent handles version conflicts when two packages require different versions of the same dependency.

## The Constraint

Crescent uses a flat `dep/` layout. Every package in a project resolves `require("dep.foo")` to the same `dep/foo/init.lua`. There is no per-package path isolation. This is a consequence of how LuaJIT's module system works: `package.path` is global, and `require` caches by module name in `package.loaded`. Once `dep.foo` is loaded, every subsequent `require("dep.foo")` returns the same cached table regardless of which package called it.

This is not a limitation to work around — it is the design. The flat layout is what makes vendoring simple: `dep/` is a directory you understand, commit, and own. The tradeoff is that the project can only carry one version of any given package name.

## Prior Art

| Ecosystem | Strategy | Applicable to crescent? |
|-----------|----------|------------------------|
| npm/Node | Multi-version via nested `node_modules/`; each package gets its own `require` resolution rooted at its own directory | No. Lua's `require` is global. Replicating npm's resolution would require patching `package.loaded` and `package.path` per-call — destroying hackability and making load order matter in surprising ways. |
| Cargo | Each crate compiled separately; multiple versions coexist as distinct compilation units with explicit `extern crate` | No. Crescent has no compilation step. There is no linker to assign distinct symbols per version. |
| Go modules | MVS (minimum version selection): given a set of constraints, pick the minimum version that satisfies all of them. Breaking changes require a new module path (`v2`, `v3`). | Partially. MVS is the right algorithm for single-version resolution. The compat promise (new major = new name) is the social contract that makes it work at scale. Both apply here. |
| Bundler / Hex | SAT solver; single version per package per project; conflicts are errors | Structurally the same outcome as crescent's current approach. SAT is heavier than needed if the constraint language stays simple (semver ranges). |
| Nix / pnpm | Content-addressed store; symlinks give each package its own view of its dependencies | No. Symlink forests and content-addressed paths destroy the `dep/foo` convention. The user can no longer read `dep/` as a flat list of what is installed. Vendoring stops making sense. |

The ecosystems that allow multi-version (npm, Cargo) do so either via language-level isolation (separate compilation units) or filesystem-level path rewriting. Neither mechanism is available to Lua without giving up the properties that make crescent packages hackable and vendorable.

## Options

### Option A: Single-version + MVS (current direction)

Collect all version constraints across the full dependency tree. For each package name, find the minimum version that satisfies every constraint that mentions it. If no such version exists, error.

This is what Go modules do, with one key difference: Go enforces that `v2+` packages have a different import path, making it structurally impossible to have a silent compatibility break. Crescent relies on semver semantics (minor bumps are backward compatible) instead.

**What the current code does:** `install.lua` runs BFS over the dependency graph and calls `semver.satisfies` against the selected version when a package is re-encountered. If a transitive dep requires `foo ^1.2` but `foo 1.5.0` is already selected, `semver.satisfies(1.5.0, "^1.2")` returns true and install continues. If it requires `foo ^2.0`, the check fails and the install errors. This is correct behavior — the conflict-error is not a placeholder, it is the right response when MVS has no solution.

What is incomplete: the current resolver resolves each package independently against the lockfile and registry, then checks conflicts after the fact. A proper MVS implementation would collect all constraints first, then pick the minimum satisfying version in one pass. The current approach can select a version that satisfies the direct constraint but fails a transitive one discovered later, causing a retry loop in principle (though BFS order makes this unlikely in practice).

**Tradeoffs:**
- Simple. One version per name, flat `dep/` layout, no surprises.
- Errors are honest: if two packages genuinely need incompatible versions, the conflict is surfaced rather than silently loading the wrong one.
- Relies on the ecosystem respecting semver. A patch release that breaks the API causes a silent regression, same as in any single-version ecosystem.

### Option B: Namespaced dep dirs

Install packages as `dep/foo_1/` and `dep/foo_2/`, and have packages declare which scoped path they require. For example, a package compiled against `foo` 1.x would `require("dep.foo_1")` and one compiled against 2.x would `require("dep.foo_2")`.

**This does not work.** A package cannot know its own version suffix at author time. The suffix is an artifact of the install-time conflict resolution — it does not exist when the package is written. The package would need to be rewritten at install time to use the correct suffix, which is a transpilation step. Crescent has no transpiler.

Even if the naming were stable (e.g., always `dep.foo` vs `dep.foo_v2` for a new major), it requires every package to be rewritten when it wants to use a newer major. That is Go's module path convention, but Go has a compiler that enforces the separation. In Lua, a package that `require`s the wrong name just gets a runtime error.

### Option C: Package-local dep dirs

Each installed package gets its own dependency subtree: `dep/sha1/dep/base64/` for `sha1`'s dependency on `base64`, separate from the project's direct `dep/base64/`. Load-time path patching makes each package find its own subtree.

This is what npm does. The problems in a Lua context:

- `package.loaded` is keyed by module name, not path. Two loaded versions of `dep.base64` would clobber each other in the cache unless the require path is made unique per version — which brings you back to Option B.
- Patching `package.path` at load time is fragile. Load order changes behavior. Any package that calls `require` at module level (i.e., most packages) would need careful sequencing.
- `dep/` becomes a tree rather than a flat list. The user can no longer inspect installed packages by reading one directory. Hackability degrades.
- If two packages load different versions of a shared package, they get different table instances. Any protocol that passes values between them (including FFI structs — see below) silently breaks.

Option C trades one honest error (conflict at install time) for many silent runtime failures (incompatible values passed between packages at runtime). That is a worse outcome.

### Option D: Compat-first ecosystem policy

Mandate that breaking changes require a new package name, not a new version. `sha1` stays `sha1` forever; if the API changes incompatibly, it becomes `sha1v2`. Any version of `sha1` can coexist with any other version of `sha1` in the dependency graph because they are different packages with different names.

This is Go's `v2+` convention applied at the package name level rather than the import path level.

**Tradeoffs:**
- Eliminates the version conflict problem structurally. Single-version resolution always finds a solution because packages with incompatible APIs have different names.
- Requires discipline from package authors. Nothing in the tooling enforces it.
- Package names proliferate over time (`sha1`, `sha1v2`, `sha1v3`). Discovery becomes harder.
- Works best combined with Option A: MVS handles minor/patch evolution; name changes handle major breaks.

Option D is not a technical solution — it is a social contract. It is worth stating explicitly in registry guidelines, but it cannot be the only line of defense.

## The FFI Identity Problem

Options B and C assume that having two versions of a package in memory simultaneously is merely an inconvenience to route around. In LuaJIT, it can be a correctness failure.

Consider a package that defines an FFI struct and exports it:

```lua
ffi.cdef [[ typedef struct { int x; int y; } Point; ]]
local M = {}
function M.make(x, y) return ffi.new("Point", x, y) end
return M
```

If two versions of this package are loaded — say `1.0.0` with `{ int x; int y; }` and `2.0.0` with `{ int x; int y; int z; }` — and a value from one is passed to a function expecting the other's layout, the result is a memory corruption bug. LuaJIT's FFI does not do runtime layout checks on struct ctype values.

This is qualitatively different from the npm situation, where two versions of a module produce plain JavaScript objects and the worst case is a missing field or a type error. In LuaJIT, the struct layout is baked into the ctype at `ffi.cdef` time, and passing a value of the wrong ctype to a C function produces undefined behavior.

Multi-version strategies that work in other ecosystems carry this additional hazard in LuaJIT. It is not a reason to rule out Option B or C entirely — packages without FFI types are unaffected — but it is a reason to prefer single-version resolution when FFI types cross package boundaries, and to document it as a registry-level constraint for packages that export FFI ctypes.

## Recommendation

**Use Option A (single-version + MVS) as the foundation. Adopt Option D (compat-first naming) as ecosystem policy.**

The flat `dep/` layout is not a limitation to eventually overcome — it is what makes crescent packages vendorable and hackable. Multi-version strategies require either a transpiler (B), runtime path gymnastics that break `package.loaded` semantics (C), or accepting silent runtime failures (C). None of these are acceptable.

MVS is simple to implement correctly and produces deterministic results. The current code's post-hoc conflict check is functionally correct but should be replaced with a proper two-pass resolver: collect all constraints first, then pick versions. This is a straightforward improvement, not a redesign.

The compat-first naming policy (Option D) is the missing piece that makes single-version work at ecosystem scale. When a package ships a breaking change under a new name, there is no conflict to resolve. Go v1's compat promise existed for this reason. The crescent registry should document this expectation for package authors.

**What this means for the current implementation:**

The conflict error in `install.lua` (lines 814–817) is correct and should stay. What needs to improve:

1. Two-pass resolution: collect all transitive constraints into a single table, then call `resolve` once with all constraints. This ensures the selected version satisfies every requirement in the graph before any package is fetched.

2. Better conflict messages: when MVS has no solution, report which packages impose the conflicting constraints, not just which version was selected and which constraint failed.

3. Registry documentation: publish a compat policy that strongly recommends new package names for breaking changes, and consider encoding `api_compat` or `api_version` in `pkg.lua` as a machine-checkable signal. Design TBD.

Multi-version is not a planned direction. If a future scenario arises where single-version is genuinely insufficient (e.g., a widely-used package ships an intentional API break and the ecosystem fails to adopt the new name), the right response is to re-examine Option D enforcement — not to add per-package path isolation.
