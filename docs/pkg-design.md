# Package Manager Design

## Goals

- **Vendor-first**: install = copy `.lua` files into your project. You own them.
- **Bun-parity performance**: same workload should run comparably fast in bun and luajit.
  Workload is I/O-bound (network fetch, file copy); LuaJIT + FFI syscalls should be competitive.
- **Fork-based parallelism** by default; configurable with `--jobs=N`.
- **Reproducible**: lockfile captures exact resolved versions + checksums + source URLs.
- **No build step**: pure Lua + FFI only. No native compilation at install time.

---

## Directory conventions

Everything lives under `lib/`. There is no separate `dep/` directory. The distinction between first-party and third-party code is irrelevant to the runtime — both are just directories under `lib/` that `require` resolves via `package.path`.

```
lib/http/        first-party package
lib/sha1/        installed third-party package
lib/lunajson/    installed third-party package
```

`lib/` is not configurable. It is where libraries live, always. The convention is the design.

Require paths:
```lua
require("lib.http.format")   -- first-party
require("lib.sha1")          -- installed dependency
require("lib.lunajson")      -- installed dependency
```

---

## Versioned subdirectories

Multiple major versions of a package coexist as separate directories:

```
lib/foo/v1/      foo 1.x — init.lua, util.lua, ...
lib/foo/v2/      foo 2.x — init.lua, util.lua, ...
lib/foo/init.lua redirect: return require("lib.foo.v2")
```

`require("lib.foo.v1")` resolves to `lib/foo/v1/init.lua` via the standard `?/init.lua` path pattern. No tooling required — this is plain `package.path` resolution.

The version subdirectory is not an install artifact — it is part of the require path the author writes at development time. If a package will be consumed as `lib.foo.v2`, the author writes `require("lib.foo.v2.util")` in their own source, and their repo has `lib/foo/v2/` in it. The package manager hardlinks/copies files there for consumers. No path rewriting, ever.

**`lib/<name>/init.lua` redirect**: the package manager writes this file automatically on install, pointing at the current major:

```lua
return require("lib.foo.v2")
```

Authors who don't care about stability write `require("lib.foo")` and get the latest. Authors who need stability write `require("lib.foo.v2")` explicitly and never see a breaking change unless they update that require path themselves.

---

## Manifest: `pkg.lua`

Each publishable package has a `pkg.lua` at its root:

```lua
return {
  name    = "sha1",
  version = "1.0.0",
  description = "SHA-1 in pure Lua",
  license = "MIT",
  deps = {
    -- name = semver constraint
    -- (empty for leaf packages)
  },
}
```

For packages with FFI bindings, an optional `platforms` table can gate
installation (design TBD — not needed until we have FFI packages in the
registry).

---

## Lockfile: `crescent.lock`

Text format, git-diffable, committed to VCS. Records the full resolved
dependency graph (direct + transitive) with exact versions, checksums,
and source URLs. Nothing in `lib/` installed by the package manager should
be trusted without a matching lockfile entry.

```toml
# crescent.lock  (do not edit manually)

[sha1]
version  = "1.0.0"
url      = "https://pkg.crescent.run/sha1/1.0.0.tar.gz"
checksum = "sha256:a3f1..."

[lunajson]
version  = "1.3.0"
url      = "https://pkg.crescent.run/lunajson/1.3.0.tar.gz"
checksum = "sha256:b7c2..."
```

Format is TOML-like but will be parsed by a hand-written Lua parser
(no external TOML library dependency for the package manager itself).
Exact grammar TBD; principle: simple enough to parse in ~50 lines of Lua.

---

## Global cache

```
~/.crescent/cache/<name>@<version>/   extracted package tree
~/.crescent/cache/<hash>.meta         binary-encoded registry metadata per package name
```

Install links (hardlink on Linux, clonefile/CoW on macOS, copy fallback) from
the global cache into `lib/<name>/v<N>/`. This means each version lives on disk once
regardless of how many projects use it.

---

## Install algorithm

```
1. Parse pkg.lua (direct deps + constraints)
2. Load crescent.lock if present
3. Resolve:
     - For each dep in pkg.lua, check lockfile for pinned version
     - For new/changed deps, query registry for matching versions
     - With lockfile: fetch tarballs lazily (only what's missing from lib/)
     - Without lockfile: fetch tarballs eagerly in parallel while resolving
4. Verify lib/ fast path:
     - For each expected package, check lib/<name>/v<N>/pkg.lua name+version
     - If match: skip (same as bun's early-exit JSON check)
5. Fetch missing packages (parallel, default --jobs=N where N=CPU count):
     - Check global cache first (~/.crescent/cache/name@version/)
     - Download tarball if not cached; verify checksum
6. Link: hardlink (or copy) from global cache into lib/<name>/v<N>/
7. Write lib/<name>/init.lua redirect pointing at installed major version
8. Write crescent.lock
```

**Fast path**: if `crescent.lock` exists and `lib/` has correct name+version
for every entry → skip all network entirely. This is the primary speedup for
repeat installs (CI warm cache, developer re-install).

**`--frozen-lockfile`** (or `cr install --frozen`): error if `pkg.lua` diverges
from lockfile. For CI reproducibility.

---

## Registry protocol

Simple HTTP, content-addressed. Default registry at `pkg.crescent.run`.

**Decentralized by design.** The registry is only needed for initial
discovery and version resolution. Once a package is in `crescent.lock`,
the full source URL is stored there — installs never touch the registry
again. The checksum in the lockfile is the integrity guarantee, not the
registry. Any server that speaks the protocol can serve packages; the
default registry is a convenience, not a trust anchor.

## Multiple registries

Crescent supports multiple registries with explicit priority ordering
(first registry that satisfies the version constraint wins — not
highest-version-wins, which would be unpredictable across registries).

**Configuration sources** (merged in priority order, highest first):

1. `~/.crescent/config.lua` — user-level; private/corp registries and auth
   tokens live here, never committed to VCS:
   ```lua
   return {
     registries = { "https://corp.internal/lua-pkgs" },
     auth = {
       ["corp.internal"] = { token = "..." },
     },
   }
   ```

2. `pkg.lua` — project-level, committed, reproducible:
   ```lua
   registries = {
     "https://pkg.crescent.run",
     "https://my.mirror",
   }
   ```

Effective registry list = `user_config.registries + pkg.lua.registries`.
Registries are queried in order; the first one with a version satisfying
the constraint is used. The winning registry's URL is stored in
`crescent.lock`, so reinstalls are deterministic regardless of registry
availability.

`--registry=URL` on the CLI prepends a registry for that invocation only.

```
GET /index.json                         → {name: {versions: [...], latest: "x.y.z"}}
GET /<name>/<version>.tar.gz            → tarball
GET /<name>/<version>.sha256            → checksum file
```

Tarball contains the package files with `pkg.lua` at root, inside a `v<N>/`
subdirectory matching the major version. The package manager places them at
`lib/<name>/v<N>/`.

Registry metadata responses cached in `~/.crescent/cache/<hash>.meta`
(binary-encoded for fast repeated reads, same principle as bun's `.npm` cache).

The registry format is simple enough that GitHub Releases can serve as a
registry backend in the short term — tarball URLs are stable, checksums can
be stored in a separate index.

---

## CLI

`cr` is the unified crescent CLI — not just a package manager. It covers
tests, typechecking, running scripts, and package management from a single
entry point.

```
bin/cr              shebang launcher (sets package.path, calls lib/cr)
lib/cr/init.lua     dispatcher: global flags, command routing, lazy-load
```

Each subcommand is lazy-loaded so `cr test` pays no cost for the
typechecker, and vice versa.

### Command dispatch order

When `cr <arg>` is invoked:
1. `<arg>.lua` exists as a file → run it directly
2. `<arg>` matches a key in `pkg.lua`'s `scripts` table → run that script
3. `<arg>` is a built-in command → dispatch

This mirrors bun's `bun <file>` / `bun <script>` / `bun <command>` UX.

### Built-in commands

```bash
# Package management
cr install               # install all deps from pkg.lua / lockfile
cr install --frozen      # CI mode: error on lockfile divergence
cr add sha1              # add to pkg.lua deps, install, update lockfile
cr add sha1@1.0.0        # pin exact version
cr remove sha1           # remove from pkg.lua, update lockfile, delete lib/sha1/
cr update sha1           # re-resolve to latest matching version, update lockfile
cr update                # re-resolve all
cr publish               # publish to registry (TBD)
cr info sha1             # show package info from registry

# Tooling
cr test [files...]       # run test suite (lib/test/cli.lua)
cr check [files...]      # typecheck (lib/type/static/cli.lua)
cr run <file>            # run a Lua file with lib/ on package.path
```

### Scripts (pkg.lua)

```lua
return {
  name = "myapp",
  scripts = {
    build = "luajit build.lua",
    serve = "luajit lib/http/server.lua",
  },
}
```

`cr build` / `cr serve` run the corresponding script via shell.

### Global flags

```
--verbose / -v       verbose output
--jobs=N             parallelism (test runner + package fetch)
--registry=URL       prepend a registry for this invocation
--no-color           disable ANSI output
```

---

## Parallelism

Fork-based (same model as typechecker Phase 5). The main process:
1. Resolves the full dependency graph (serial — dependencies on previous results)
2. Forks N worker processes to fetch/extract packages in parallel
3. Collects results via pipe; workers signal success/failure + checksum

`--jobs=N` (default: CPU count). `--jobs=1` for sequential (debug, CI with
resource limits).

---

## File I/O strategy

Hardlinks are table stakes — pnpm does this too and is still slower than bun.
The real wins:

- **`io_uring` on Linux** (via FFI): submit a batch of file operations in a
  single syscall; kernel pipelines them. Extracting many small `.lua` files
  from a tarball is exactly the workload where this matters — traditional
  `open`/`write`/`close` per file means hundreds of kernel crossings;
  `io_uring` collapses them. Use `liburing` or raw `io_uring_setup` syscalls.
- **`clonefile()` on macOS** (via FFI): CoW copy at the filesystem level;
  instantaneous regardless of file size. Same syscall bun uses.
- **Fallback**: `sendfile(2)` or plain `read`/`write` via FFI (not `io.open`
  — avoid Lua string allocation on the copy path).

LuaJIT calls the same kernel interfaces as bun (Zig). The overhead is Lua
control-flow wrapping the submission loop, not the I/O itself. With `io_uring`
the bottleneck shifts to network latency, at which point we're on equal footing.

---

## Open questions (design TBD before implementation)

- **Package name scoping**: flat names (`sha1`) vs namespaced (`rhi/sha1`)?
  Flat is simpler. Namespacing avoids collisions if third-party registries are
  supported later. Proposal: flat names for now, registry-qualified in lockfile URL.

- **Version resolution algorithm**: full semver ranges (`^1.0`, `~1.2`) or
  exact-only? Full semver is more useful but requires a semver parser.
  Proposal: full semver (write a small pure-Lua semver parser).

- **Multiple registries**: designed — see "Multiple registries" section above.
  v1 implements single registry only; multi-registry resolution is v2.

- **FFI packages**: packages with `.so`/`.dylib` prebuilt binaries need
  platform filtering (cpu + os in pkg.lua). Design slot exists; skip for v1.

- **`lib/` in VCS**: vendor-first means installed packages under `lib/` are
  committed. The lockfile is then redundant for reproducibility but remains
  useful for `cr update` and registry provenance. Keep both.

- **Lockfile parser**: hand-written TOML-like parser vs using lunajson (JSON
  lockfile)? JSON is simpler to parse but less readable in diffs. Lean toward
  the TOML-like format with a hand-written parser — lockfiles are simple
  enough that the parser stays small.
