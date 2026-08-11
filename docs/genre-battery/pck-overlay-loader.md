# PROPOSAL: Godot-.pck-style overlay mod loader for crescent

**Status: design proposal, awaiting owner sign-off.** Nothing in this
document is implemented. No code exists yet. This is one of the paradigm
libraries named in `docs/genre-battery-design.md`'s "Mod-loader shape"
section — the "Godot .pck raw overlay, and '.pck + load order'" paradigm.
Best fit per that doc: asset delivery. This document proposes design options
only; it does not pick a winner where more than one option is workable, per
the owner's standing instruction that design docs lay out tradeoffs rather
than advocate.

**Sibling, not a dependency.** A separate design effort at
`docs/genre-battery/conflict-arbitration.md` covers the Harmony/BepInEx-style
runtime-patching conflict-arbitration paradigm (multiple mods wrapping the
same Lua function). This document does not need that layer and does not
block on it — per `docs/genre-battery-design.md`, this paradigm is closer to
Minecraft datapacks in spirit (path-keyed data overlay) than to
monkeypatch-style behavior hooking, and per the owner's "if they are
compatible then they are compatible" ruling, whether/how these two paradigm
libraries compose is discovered empirically at point of use in an actual
genre core, not adjudicated here.

## Existing-library scan (verified by grep, not asserted from memory)

Per task instructions, checked before designing anything:

- **No existing VFS/overlay library.** `grep -ril "vfs\|virtual filesystem" lib/`
  (excluding `node_modules`/`fixtures` noise) hits only `lib/fuse/init.lua`,
  and that is unrelated: it's an FFI binding to the real Linux kernel FUSE
  API (`fuse_new`, `fuse_mount`, `struct fuse_operations`, `errno`-shaped
  `mod.error` table) for mounting an actual OS-level filesystem. `lib/fuse/memory.lua`
  and `lib/fuse/readonly.lua` are FUSE callback-table helpers (an in-memory
  backing store and a read-only-operations wrapper) built for that kernel-FUSE
  use case, not an in-process path-overlay abstraction. `lib/fuse/fs.lua`
  is an empty file. None of this is an in-process virtual filesystem the way
  Godot's `.pck` mount is; it would require an actual OS FUSE mount
  (root/capability requirements, Linux-only) to use at all, which conflicts
  with this paradigm's "works on Linux/macOS/Windows" cross-platform bar. Not
  usable as a foundation for this library.
- **No existing "archive" or "overlay" library** matching this shape.
  `grep -rl "overlay" lib/ --include=*.lua` hits five unrelated files (type
  system control-flow "overlay" terminology, a PDF font table, a PTY cap) —
  no hits relevant to filesystem overlay.
- **No zip reader/writer anywhere in `lib/`.** `find lib -maxdepth 1 -iname
  "*zip*"` returns nothing. Godot's own `.pck` format is not zip anyway
  (it's Godot's own custom binary format with its own header/index layout);
  building against "zip" as prior art would mean adopting a third format
  that isn't what Godot uses and isn't already in the repo.
- **`lib/tar` exists and is directly usable.** Pure-Lua (`M._tier = "pure"`,
  no FFI, no system dependency) ustar (POSIX.1-1988) reader/writer,
  `M.read(bytes) -> TarEntry[] | (nil, errmsg)`, `M.write(entries) ->
  string | (nil, errmsg)`, entry shape `{ name, mode, size, mtime, data,
  typeflag }`, codec-convention aliases (`string_to_tar`/`tar_to_string`/
  `encode`/`decode`) already in place. This is a real, working, pure-Lua
  archive-format library already satisfying crescent's zero-dependency
  constraint — a mod pack archive can be a tar file today with zero new
  archive-format code.
- **`lib/compress` exists and is tiered** (`system` zlib FFI > `pure` Lua
  inflate, `M._tier` introspectable, `deflate`/`inflate`/`encode`/`decode`).
  Composable with `lib/tar` for a `.tar.gz`-shaped pack (tar the mod
  directory, then run the bytes through `compress.deflate`) without needing
  a new combined-format library.
- **`lib/fs`** (`lib/fs/init.lua`) is the existing injected-cap surface for
  real disk I/O: `dir_list`, `dir_info`, `stat`, `mkdir`, `rmdir`, `unlink`,
  all `(value | nil, errmsg)`. This is the cap this library's disk-backed
  filesystem provider would take as an injected dependency (never call
  `io.*` directly, per `CLAUDE.md`'s caps-first rule).
- **`lib/graph`** has topological-sort support — usable for load-order
  resolution from a mod dependency DAG rather than hand-rolling a toposort.
- **`lib/semver`** exists — usable for manifest `requires`/version-constraint
  fields if the manifest format wants semver-range dependency declarations.
- **`lib/glob`** exists — potentially usable for manifest path-pattern
  fields (e.g. "this mod's file list matches `assets/**`") if a design
  option below wants glob-based path predicates instead of exact paths.

Conclusion: this library's own scope is the **overlay/mount + manifest/
orchestration layer**, not a new archive codec. `lib/tar` (+ optionally
`lib/compress`) already covers "packaged archive of files"; nothing new is
needed there. The archive-format question in the task ("does crescent need
its own pack format, or build on an existing standard") reduces to: which
*existing* crescent archive primitive to build on, not whether to write a
parser from scratch.

## 1. Archive format

Three options, differing in what "the mod package" physically is:

**Option A — tar (uncompressed) as the canonical pack container.**
A mod is a `.tar` file read via `lib.tar.read`. Simplest: one already-working
pure-Lua dependency, no new parser, entries already carry `name`/`data`/
`mode`/`mtime`. Tradeoff: no compression — mod packs are as large as their
uncompressed contents. For asset-heavy mods (textures, audio) this could
matter; tar itself has no answer to it.

**Option B — tar + `lib/compress` (`.tar.gz`-equivalent) as the canonical
pack container.** Tar the mod tree, run the resulting bytes through
`lib.compress.deflate`; unpack by `inflate` then `lib.tar.read`. Still zero
new archive-format code — composes two existing libraries. Tradeoff: two
decode passes instead of one, and whichever `lib/compress` tier is active
at load time (`system` zlib vs `pure`) becomes part of this library's
performance profile, not something it controls directly — it inherits
`lib/compress`'s own tiering guarantees (never silently falls back to a
slower tier without trying faster ones, per `docs/conventions.md`).

**Option C — no packed-archive requirement at all; a mod is a plain
directory.** `.pck` packs into a single file specifically because Godot
ships binary game exports; crescent mods ship as source-visible plain files
(consistent with "copy-paste-ownable" library philosophy and modding-as-plain-
files ergonomics — a modder can `git diff` a directory, not a binary blob).
The loader's mount step takes either a directory path (via `lib.fs`) or an
already-decoded tar entry list (via `lib.tar.read`) as its input, so
packaging is the mod *distributor's* choice, not something this library
forces. Tradeoff: if no single-file container is mandated, "mod = one
downloadable file" (a real modding-community affordance — one link to share)
requires the distributor to zip/tar it themselves and the loader to accept
both shapes, which is more surface for the loader's mount API to support
(directory-cap-backed source and archive-entries-backed source both need a
uniform internal representation — see section 2).

None of these require zip. If zip specifically is wanted for interop with
externally-authored `.pck`/zip-based tooling, no pure-Lua zip reader exists
in crescent today and one would need to be built or vendored — that is a
separate, unstarted piece of substrate this document does not propose
building, since it's not required by any of the three options above.

## 2. Virtual filesystem overlay mechanics

**Core data structure, independent of which archive option is chosen:** a
single `overlay = { [path] = source }` map, where `path` is a normalized
(leading-slash-stripped, no `..`, forward-slash) virtual path and `source`
is a *reference* to where the byte content ultimately comes from — never a
pre-materialized copy. Building the map is a fold over mods in load order:
for each mod, for each file it declares, `overlay[path] = { mod = mod_id,
mode = <disk|tar-entry>, backing = <lib.fs handle | tar-entry> }`,
unconditionally overwriting whatever was there before. This directly mirrors
Godot's documented "last loaded wins" semantics (`docs/genre-battery-design.md`
cites `exporting_pcks` for this).

**Read path (`overlay:read(path) -> bytes | (nil, errmsg)`):** look up
`overlay[path]`; if absent, fall through to the base game's own file source
(itself just mod-id `"base"` loaded first, per the "everything is a mod,
including the base game" framing already settled for the Factorio paradigm
in `docs/genre-battery-design.md` — reusable here even though this paradigm
has no data/control staging). If `source.mode == "disk"`, read via the
injected `lib.fs`-shaped cap (never `io.open` directly — caps-first, per
`CLAUDE.md`). If `source.mode == "tar-entry"`, return the entry's `data`
field already held in memory from `lib.tar.read`.

**Composing with `require()`:** this is the one place this paradigm's
"possibly Lua source files/modules" clause needs a real answer, since Lua's
`require` resolves through `package.path`/`package.loaded`, not through an
arbitrary virtual filesystem. Two sub-options:

- **2a. `package.searchers` insertion.** Install a custom entry in Lua's
  `package.searchers` (LuaJIT: `package.loaders`) that, given a module name,
  maps it to a virtual path, consults `overlay:read`, and returns a loader
  function via `load(bytes, chunkname)` if found — falling through to the
  normal filesystem searcher otherwise. This makes `require("mymod.thing")`
  transparently resolve through the overlay with no caller-visible change,
  matching how Godot's resource loader transparently resolves overlaid
  paths. Tradeoff: touches a genuinely global, process-wide table
  (`package.searchers`) — every `require()` call in the process now passes
  through this resolution step, which needs to be cheap (a hash lookup) and
  needs to compose correctly if multiple overlay instances or other
  searchers are also installed (ordering of `package.searchers` entries
  becomes load-bearing).
- **2b. Explicit `overlay:require(module_name)` entry point, no global
  `package.searchers` mutation.** The loader exposes its own `require`-shaped
  function that mod/game code calls explicitly instead of the ambient
  global `require`. Tradeoff: does not compose transparently with
  third-party code (e.g. a vendored `dep/` library) that calls plain
  `require` internally and expects to see overlaid modules — but avoids any
  global mutation, which fits `CLAUDE.md`'s "no ambient globals by default"
  and caps-first stance more literally: `require` behavior changing based on
  which overlay happens to be active anywhere in the process is itself a
  form of ambient/global state.

This is a real, load-bearing branch point — not a detail to default without
sign-off, since it decides whether the overlay is transparent-global or
explicit-local, and that shapes every mod author's mental model of how their
`require` calls behave. Flagging for the doc's audience, per the owner's
"lay out tradeoffs, don't pick" instruction, rather than choosing 2a or 2b
here.

**Asset reads outside `require` (textures, config files, etc.):** these have
no Lua-native ambient resolution mechanism to intercept in the first place
(unlike `require`), so they always go through the explicit `overlay:read(path)`
call — no design choice needed there, any calling code that wants overlay-aware
asset access calls the loader's function directly.

## 3. Orchestration layer: manifest, load order, conflict reporting

**Manifest format.** Plain Lua table (consistent with "control-stage
authoring is plain Lua, not a DSL," per `docs/genre-battery-design.md`), not
JSON/TOML — a `manifest.lua` returning:

```lua
return {
  id = "my_mod",                    -- unique string, mod's own namespace
  version = "1.2.0",                -- lib.semver-parseable
  requires = { other_mod = ">=1.0.0" },  -- lib.semver range per dependency
  load_before = { "some_other_mod" },
  load_after = { "base" },
  incompatible_with = { "conflicting_mod" },
  files = { "assets/**", "scripts/**" },  -- lib.glob patterns, or omit for "everything in the pack"
}
```

**Load order resolution.** Build a dependency DAG from `requires`/
`load_before`/`load_after` edges, resolve via `lib.graph`'s topological sort.
Two sub-options for what happens when the DAG has no valid order (a cycle,
or an `incompatible_with` pair both present and enabled):

- **3a. Hard failure.** `loader.resolve_order(mods) -> (nil, errmsg)` on
  cycle/incompatibility — matches crescent's `(nil, errmsg)` convention
  directly, and forces the conflict to be surfaced before any mounting
  happens rather than deferred to a confusing runtime symptom.
- **3b. Best-effort with a warning list.** Break cycles by some deterministic
  rule (e.g. manifest declaration order as tiebreak) and return
  `(order, warnings)` where `warnings` is a list of strings describing what
  was overridden to produce an order — lets the game still boot with a
  degraded-but-working mod set instead of hard-refusing to start. Tradeoff
  against 3a: silently produces *an* order that no mod author asked for,
  which could paper over a real incompatibility the mod authors intended to
  be fatal.

**Conflict reporting for same-path overwrites.** Godot's own precedent (per
`docs/genre-battery-design.md`'s citation of godot-proposals#6788) is silent
last-wins with no built-in reporting — the documented pain point is exactly
that two mods editing the same file "can't both apply" and nothing tells the
user this happened until they notice broken behavior. Crescent doesn't have
to repeat that. Options:

- **3c. Silent last-wins (Godot parity).** `overlay:build(mods_in_order)`
  just overwrites, no report. Matches the "dumbest paradigm" framing exactly
  — pure path-keyed overlay, no merge logic, no diagnostics. Cheapest to
  implement and reason about; the tradeoff is inheriting Godot's own
  documented pain point verbatim, with the exact same "which mod actually
  won" invisibility bug reports linked in `docs/genre-battery-design.md`
  describe.
- **3d. Silent last-wins + returned collision report.** `overlay:build(mods)
  -> (overlay, collisions)` where `collisions` is `{ [path] = { winner =
  mod_id, shadowed = { mod_id, ... } } }` for every path more than one mod
  claimed — behavior is unchanged (still last-wins, still no merge), but the
  information Godot's own tooling structurally lacks is available to
  whatever calls this loader (a game's own startup log, a mod-manager UI,
  etc.) to surface to a human. This directly answers "detect and report vs.
  silently resolve" from a different angle than a binary choice: it is
  both — resolve via load order (matching Godot's real-world precedent) and
  report the resolution (fixing the exact gap Godot's own bug tracker
  documents), at effectively zero behavioral cost since building the report
  is a byproduct of the same fold that builds the overlay map.
- **3e. Configurable strictness — caller-supplied `on_collision` callback**
  (default no-op, i.e. equivalent to 3c) that's invoked per collision during
  `build`, letting a caller opt into treating collisions as fatal (`error()`
  inside the callback, though per crescent convention this would need to be
  a caller choice, not something the library does automatically — the
  library itself still returns `(nil, errmsg)` rather than throwing on
  ordinary mod conflicts, per crescent's error-handling convention and the
  task's explicit point 5) or logged, or ignored, without the library
  hardcoding one policy.

3d and 3e are not mutually exclusive with each other (3e could be built as
sugar over 3d's collision list), but either is a strictly-better-than-Godot
option relative to 3c at low cost, since the underlying fold already visits
every path claim.

## 4. Lua-native equivalent of GDScript inheritance-chain script extension

The task frames this as: does this paradigm need something more than "load
order + require() override," given it explicitly does *not* need the
Harmony-style wrapping the sibling conflict-arbitration doc covers?

**What GDScript's mechanism actually does, per `docs/genre-battery-design.md`'s
description:** multiple mods each *extend the same base script* by declaring
themselves as a subclass and calling up to the parent implementation,
instead of one mod's whole-file replacement clobbering another's — i.e., an
actual chained-inheritance composition where `super.method()` calls are
real, working calls into whichever mod's version sits below in the chain.

**Lua has no built-in class/inheritance system**, so "just do what GDScript
does" isn't directly portable — this needs a Lua-shaped equivalent, not a
transliteration. Options:

- **4a. Overlay + `require` override only (whole-module replacement).**
  A mod that wants to change `scripts/enemy_ai.lua` provides its own file at
  that virtual path; last-loaded-wins overlay semantics mean the last mod's
  version is what `require` resolves to, full stop. This is the "vanilla
  .pck" answer with no extension mechanism at all — exactly the whole-file
  clobbering the Godot orchestration layer was built specifically to avoid,
  per the task's own framing. Two mods each wanting to add independent
  behavior to `enemy_ai.lua` cannot both apply; the second mod's file
  silently and completely replaces the first's. This is a real, named
  limitation of choosing 4a, not a hidden cost — same category of problem
  as godot-proposals#6788, just one layer up (whole Lua module instead of
  whole resource file).
- **4b. Metatable-chain composition, explicit opt-in per module.** A module
  meant to be mod-extensible returns a table built with a documented
  convention — e.g. the base module (and each mod's extension of it)
  constructs its table via a shared `lib`-provided `extend(base_module,
  overrides)` helper that returns a new table whose `__index` metamethod
  falls through to `base_module`, so an extending mod's table only needs to
  define the functions it changes, and any function it doesn't redefine
  falls through to the previous layer in the chain automatically — the Lua
  metatable-inheritance idiom, applied per mod in load order. A mod that
  wants to call "the previous implementation" (GDScript's `super.method()`)
  does so by capturing the pre-extension function reference explicitly
  before overriding it, e.g. `local prev = base.attack; function
  extended.attack(...) prev(...); <mod's own logic> end` — ordinary Lua
  closures, no language feature needed beyond what Lua already has.
  Tradeoff: this only works for modules **authored to expose an extension
  point this way** — a module that returns a flat table of free functions
  with no `extend`-style construction has nothing to chain onto, so this
  is an opt-in convention the base game's own scripts must adopt, not
  something the loader can retrofit onto arbitrary existing Lua modules
  it didn't author. This is a real prerequisite this doc surfaces, not
  something it can default around: whether crescent's genre reference cores
  would actually author their scripts this way is a separate, unresolved
  question this document does not answer.
- **4c. Defer chained composition entirely to the sibling
  conflict-arbitration library.** Since Lua functions are ordinary mutable
  table values, "wrap this function and call through to what was there
  before" is exactly the monkeypatch-wrapping primitive
  `docs/genre-battery-design.md`'s Harmony-paradigm section already
  describes as "already free" in Lua. Under this option, this library does
  *not* build its own chaining mechanism at all (no 4b) — it only does path
  overlay (4a) for whole-file/whole-asset replacement, and any mod author
  who wants GDScript-style non-destructive chained extension of a specific
  function reaches for the sibling conflict-arbitration library's ordering/
  wrapping primitives instead, applied to whatever module the overlay
  resolved. Tradeoff: this keeps this library's own scope narrow and purely
  Godot-`.pck`-shaped (the task's stated best-fit: asset delivery, not
  behavior composition) but means "possibly Lua source files/modules" in
  the task's own framing gets only whole-file replacement from this library
  alone — chained/non-destructive extension of an overlaid script requires
  reaching for the sibling library on top, i.e. this paradigm and the
  Harmony paradigm compose for that use case rather than either one alone
  covering it. This is consistent with the owner's ruling that
  cross-paradigm composition is discovered at point of use, not adjudicated
  in advance — named here as the option that leans on that ruling directly
  rather than trying to reproduce Harmony's capability inside this library.

4b and 4c are not mutually exclusive: 4b could exist as a lightweight
convenience for modules that opt into the `extend()` convention, while 4c
remains true regardless (the sibling library's wrapping primitive still
works on any function, extended-convention or not). 4a is the floor every
option sits on top of, since overlay resolution has to exist before there's
anything to extend.

## 5. Error handling

Every fallible operation in every option above returns `(nil, errmsg)`,
never throws, on ordinary mod-loading conditions — malformed manifest,
missing dependency, version-constraint mismatch, cycle in load order (if
option 3a is chosen), unreadable archive, path collision (if reported per
3d/3e) — per `docs/conventions.md`'s error-handling contract and the task's
explicit point 5. Concretely, the public surface implied by the options
above:

```lua
M.manifest_from_string(s) -> manifest | (nil, errmsg)     -- parse a manifest.lua's returned table (already loaded/executed by caller) into validated shape
M.resolve_order(manifests) -> (order | nil, errmsg)        -- or (order, warnings) under option 3b
M.build_overlay(order, sources, fs_cap) -> (overlay | nil, errmsg)  -- or (overlay, collisions) under 3d
overlay:read(path) -> (bytes | nil, errmsg)
overlay:require(module_name) -> (module | nil, errmsg)     -- under option 2b only; not needed under 2a
```

Programming errors (wrong argument type — e.g. passing a number where a
manifest table is required) may still throw per the standard crescent
distinction between data errors and programming errors; only genuine
mod-authoring/mod-loading conditions are guaranteed `(nil, errmsg)`.

## Summary of open branch points requiring sign-off

Named per section, not defaulted:

1. Archive format: tar-only (A), tar+compress (B), or directory-native with
   archive-as-distribution-detail (C).
2. `require()` interception: global `package.searchers` hook (2a, transparent
   but touches global state) vs. explicit `overlay:require` (2b, no global
   mutation but not transparent to third-party `require` calls).
3. Load-order-failure policy: hard-fail on cycle/incompatibility (3a) vs.
   best-effort-with-warnings (3b). Collision reporting: silent (3c) vs.
   silent-but-reported (3d) vs. caller-configurable callback (3e).
4. Script-extension mechanism: none beyond whole-file overlay (4a alone,
   accepting the clobbering problem the task asks this library to solve)
   vs. an opt-in metatable-chain convention (4b) vs. deferring all chained
   composition to the sibling conflict-arbitration library (4c). 4b/4c are
   compatible with each other; 4a is the floor under both.
