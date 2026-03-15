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

```
lib/        first-party packages (part of this repo)
dep/        installed third-party packages (managed by pkg, committed to VCS)
```

`dep/` is already the implicit convention — `websocket/init.lua` does
`require("dep.sha1")` and `require("dep.base64")`. The package manager
formalises this.

Require paths:
```lua
require("lib.http.format")   -- first-party
require("dep.sha1")          -- installed dependency
require("dep.lunajson")      -- installed dependency
```

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
and source URLs. Nothing in `dep/` should be trusted without a matching
lockfile entry.

```toml
# crescent.lock  (do not edit manually)

[sha1]
version  = "1.0.0"
url      = "https://pkg.rhi.zone/sha1/1.0.0.tar.gz"
checksum = "sha256:a3f1..."

[lunajson]
version  = "1.3.0"
url      = "https://pkg.rhi.zone/lunajson/1.3.0.tar.gz"
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
the global cache into `dep/<name>/`. This means each version lives on disk once
regardless of how many projects use it.

---

## Install algorithm

```
1. Parse pkg.lua (direct deps + constraints)
2. Load crescent.lock if present
3. Resolve:
     - For each dep in pkg.lua, check lockfile for pinned version
     - For new/changed deps, query registry for matching versions
     - With lockfile: fetch tarballs lazily (only what's missing from dep/)
     - Without lockfile: fetch tarballs eagerly in parallel while resolving
4. Verify dep/ fast path:
     - For each expected package, check dep/<name>/pkg.lua name+version
     - If match: skip (same as bun's early-exit JSON check)
5. Fetch missing packages (parallel, default --jobs=N where N=CPU count):
     - Check global cache first (~/.crescent/cache/name@version/)
     - Download tarball if not cached; verify checksum
6. Link: hardlink (or copy) from global cache into dep/<name>/
7. Write crescent.lock
```

**Fast path**: if `crescent.lock` exists and `dep/` has correct name+version
for every entry → skip all network entirely. This is the primary speedup for
repeat installs (CI warm cache, developer re-install).

**`--frozen-lockfile`** (or `cr install --frozen`): error if `pkg.lua` diverges
from lockfile. For CI reproducibility.

---

## Registry protocol

Simple HTTP, content-addressed. Registry at `pkg.rhi.zone` (TBD).

```
GET /index.json                         → {name: {versions: [...], latest: "x.y.z"}}
GET /<name>/<version>.tar.gz            → tarball
GET /<name>/<version>.sha256            → checksum file
```

Tarball contains the package files with `pkg.lua` at root. No `lib/` or
`dep/` prefix inside — the package manager places them at `dep/<name>/`.

Registry metadata responses cached in `~/.crescent/cache/<hash>.meta`
(binary-encoded for fast repeated reads, same principle as bun's `.npm` cache).

The registry format is simple enough that GitHub Releases can serve as a
registry backend in the short term — tarball URLs are stable, checksums can
be stored in a separate index.

---

## CLI

```bash
cr add sha1              # add to pkg.lua deps, install, update lockfile
cr add sha1@1.0.0        # pin exact version
cr install               # install all deps from pkg.lua / lockfile
cr install --frozen      # CI mode: error on lockfile divergence
cr remove sha1           # remove from pkg.lua, update lockfile, delete dep/sha1/
cr update sha1           # re-resolve to latest matching version, update lockfile
cr update                # re-resolve all
cr publish               # publish to registry (TBD)
cr info sha1             # show package info from registry
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

## Open questions (design TBD before implementation)

- **Package name scoping**: flat names (`sha1`) vs namespaced (`rhi/sha1`)?
  Flat is simpler and consistent with the existing `dep.sha1` convention.
  Namespacing avoids collisions if third-party registries are supported later.
  Proposal: flat names for now, registry-qualified in lockfile URL.

- **Version resolution algorithm**: full semver ranges (`^1.0`, `~1.2`) or
  exact-only? Full semver is more useful but requires a semver parser.
  Proposal: full semver (write a small pure-Lua semver parser).

- **Multiple registries**: support `--registry` flag or per-scope config?
  Not needed for v1 but the lockfile URL already encodes the source so
  switching registries doesn't invalidate existing lockfiles.

- **FFI packages**: packages with `.so`/`.dylib` prebuilt binaries need
  platform filtering (cpu + os in pkg.lua). Design slot exists; skip for v1.

- **`dep/` in VCS**: vendor-first means `dep/` is committed. The lockfile
  is then redundant for reproducibility but remains useful for `cr update`
  and registry provenance. Keep both.

- **Lockfile parser**: hand-written TOML-like parser vs using lunajson (JSON
  lockfile)? JSON is simpler to parse but less readable in diffs. Lean toward
  the TOML-like format with a hand-written parser — lockfiles are simple
  enough that the parser stays small.
