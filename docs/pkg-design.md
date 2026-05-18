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
lib/foo/init.lua optional redirect shipped by the author: return require("lib.foo.v2")
```

`require("lib.foo.v1")` resolves to `lib/foo/v1/init.lua` via the standard `?/init.lua` path pattern. No tooling required — this is plain `package.path` resolution.

The version subdirectory is not an install artifact — it is part of the require path the author writes at development time. If a package will be consumed as `lib.foo.v2`, the author writes `require("lib.foo.v2.util")` in their own source, and their repo has `lib/foo/v2/` in it. The package manager hardlinks/copies files there for consumers. No path rewriting, ever.

**`lib/<name>/init.lua` redirect**: if the author ships a redirect in their tarball, it lands at `lib/<name>/init.lua` after extraction. The package manager does not generate this file — it is the author's decision whether to include it. Authors who want `require("lib.foo")` to work write the redirect themselves. Authors who don't include it require callers to use the explicit versioned path.

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

Text format, git-diffable, committed to VCS. Records the complete
reproducible state of everything the package manager manages: exact
versions, source URLs, include globs, and integrity hashes.

`crescent.lock` is the boundary between "managed by the package manager"
and "owned by the project". First-party code in `lib/` that was not
installed by the package manager is not in the lockfile.

```toml
# crescent.lock  (do not edit manually)

[sha1]
version  = "1.0.0"
url      = "https://pkg.crescent.run/sha1/1.0.0.tar.gz"
include  = "**"
tarball  = "sha256:a3f1..."
tree     = "sha256:d9e4..."

[lunajson]
version  = "1.3.0"
url      = "https://pkg.crescent.run/lunajson/1.3.0.tar.gz"
include  = "v2/**"
tarball  = "sha256:b7c2..."
tree     = "sha256:c1a8..."
```

**Two hashes per entry:**
- `tarball`: verified on download. Detects a corrupt or tampered tarball
  before extraction.
- `tree`: hash of the extracted file tree. Used by `cr install` to detect
  local modifications to `lib/<name>/` after install.

**`include` glob**: the subset of the tarball actually extracted (see
"Selective installs" below). The lockfile records the union installed,
which may be wider than what any single dependent requested.

Format is TOML-like but parsed by a hand-written Lua parser (no external
TOML library dependency for the package manager itself). Exact grammar TBD;
principle: simple enough to parse in ~50 lines of Lua.

---

## Selective installs

Consumers can declare which parts of a package they want using an include glob:

```bash
cr add foo --include="v2/**"
```

The default is `**` (everything). The glob is recorded in `pkg.lua`:

```lua
deps = {
  foo = { constraint = "^2.0", include = "v2/**" },
}
```

When multiple dependents request different globs of the same package, the
**union** is installed. This ensures every dependent gets what it asked for
without requiring the package to be downloaded twice. The lockfile records
the union actually installed, not the individual requests:

```toml
[foo]
version = "2.1.0"
include = "v2/**"   -- union of all dependent requests
...
```

If a new dependent later requests a wider glob (e.g., `**`), `cr install`
re-links with the expanded union.

---

## Local edits to vendored code

The tree hash in the lockfile lets `cr install` detect modifications to
`lib/<name>/` after install:

- **On hash mismatch**: warn "lib/foo/ has been modified" and stop. No files
  are overwritten without explicit consent.
- **`cr install --force`**: overwrite local changes for all packages.

Additional commands for working with modified vendored code:

```bash
cr diff foo      # diff lib/foo/ against ~/.cache/crescent/pkg/foo@<version>/
                 # no network required — the cache is already present from install
cr eject foo     # remove foo from crescent.lock entirely; the package manager
                 # never touches lib/foo/ again. Explicit primitive for "I own this."
```

**`cr update`** behavior when local edits are present:
- `cr update foo` — warns about local changes and stops.
- `cr update foo --overwrite` — discards local changes, installs new version.
- `cr update foo --merge` — three-way merge: base = cached old version,
  ours = local edits, theirs = new version. Uses diff3. The three inputs
  are all available locally (base from cache, ours from `lib/`, theirs from
  new cache entry), so no network round-trip beyond the initial fetch.

`cr eject` is the right tool when the intent is permanent ownership. `--merge`
is the right tool when the intent is to track upstream while keeping local fixes.

---

## Global cache

```
~/.cache/crescent/pkg/<name>@<version>/   extracted package tree
~/.cache/crescent/pkg/<hash>.meta         binary-encoded registry metadata per package name
```

Install links (hardlink on Linux, clonefile/CoW on macOS, copy fallback) from
the global cache into `lib/<name>/`. This means each version lives on disk once
regardless of how many projects use it. The cache always holds the full extracted
tree; selective installs apply the include glob during the link step, not during
extraction to cache.

---

## Install algorithm

```
1. Parse pkg.lua (direct deps + constraints + per-dep include globs)
2. Load crescent.lock if present
3. Resolve:
     - For each dep in pkg.lua, check lockfile for pinned version
     - For new/changed deps, query registry for matching versions
     - With lockfile: fetch tarballs lazily (only what's missing from lib/)
     - Without lockfile: fetch tarballs eagerly in parallel while resolving
     - Compute union of all include globs for each package (from direct and
       transitive dependents); record union in updated lockfile
4. Verify lib/ fast path:
     - For each expected package, check tree hash of lib/<name>/ against lockfile
     - If match: skip (same as bun's early-exit JSON check)
     - If mismatch: warn "lib/<name>/ has been modified" and stop unless --force
5. Fetch missing packages (parallel, default --jobs=N where N=CPU count):
     - Check global cache first (~/.cache/crescent/pkg/name@version/)
     - Download tarball if not cached; verify tarball hash
6. Link: hardlink (or copy) from global cache into lib/<name>/,
     applying the include glob union from step 3
7. Write crescent.lock
```

**Fast path**: if `crescent.lock` exists and tree hashes match for every entry
→ skip all network entirely. This is the primary speedup for repeat installs
(CI warm cache, developer re-install).

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

Tarball is extracted into `lib/<name>/`. If the package author structured their
tarball with a `v<N>/` subdirectory (the standard practice for versioned
packages), the extracted result is `lib/<name>/v<N>/`. The package manager
imposes no directory structure — it extracts and that's it.

Registry metadata responses cached in `~/.cache/crescent/pkg/<hash>.meta`
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
cr install                       # install all deps from pkg.lua / lockfile
cr install --frozen              # CI mode: error on lockfile divergence
cr install --force               # overwrite local modifications to lib/
cr add sha1                      # add to pkg.lua deps, install, update lockfile
cr add sha1@1.0.0                # pin exact version
cr add sha1 --include="v2/**"    # install only matching files from tarball
cr remove sha1                   # remove from pkg.lua, update lockfile, delete lib/sha1/
cr update sha1                   # re-resolve to latest matching version, update lockfile
cr update sha1 --overwrite       # update, discarding local changes
cr update sha1 --merge           # update with three-way merge of local edits
cr update                        # re-resolve all
cr diff sha1                     # diff lib/sha1/ against cached version (no network)
cr eject sha1                    # remove from lockfile; hand ownership to the project
cr publish                       # publish to registry; lints phantom deps
cr info sha1                     # show package info from registry

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

## Phantom dependency linting

`cr publish` (and `cr check`) scans a package's source for every
`require("lib.X.vN")` (or `require("lib.X")`) call and verifies that `X` is
declared in the package's own `pkg.lua` with an include glob that covers the
required path.

This catches the classic npm phantom-dependency problem: a transitive dep
happens to be present in `lib/` at runtime because some other package brought
it in, so the missing declaration goes unnoticed until someone removes that
transitive dep. The lint surfaces it at publish time rather than at a
consumer's install.

Each package is linted against its own declared deps — not the project's full
install set. A package that passes lint is self-contained: any project that
installs it will have exactly what it needs.

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
