# TODO

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

## Current roadmap

See `docs/roadmap-v2.md` for the authoritative project roadmap and sequencing. The roadmap provides the current strategic direction informed by the value landscape analysis.

## tcc native build: missing dep/tcc/conftest.c blocks ./configure-based jobs (2026-08-21)

- [x] **`dep/tcc/configure` compiles `"$source_path/conftest.c"` (configure:455) as
  a static compiler-probe source that is expected to already exist in the vendored
  tree, but no such file is tracked anywhere in `dep/tcc/`** (`git log --all -- conftest.c`
  and `git ls-files | grep conftest` both empty). This blocks the `make` step with
  `No rule to make target 'conftest.c', needed by 'c2str.exe'` (Makefile:258 depends
  on it directly) on every platform that uses the `./configure && make` path —
  confirmed locally (Alpine/musl, `docker run alpine:latest`, both `-j1` and default
  parallelism) and independently confirmed in the actual `tcc-bootstrap-macos-arm64`
  CI job of run 32453775057 (2026-08-21), which failed at `./configure` with
  `clang: error: no such file or directory: '.../dep/tcc/conftest.c'`. The two
  Windows tcc jobs are unaffected because they build via `win32/build-tcc.bat`
  instead, which never reaches this code path. This is a vendoring gap (a file
  missing from the committed tcc source, not a patch-content or CI-flag problem).
  See also the "Apply dep/tcc/patches" step fix in `build-vendored.yml`
  (`tcc-linux-x86_64` job) committed the same session, a separate, already-fixed
  issue (missing `git` binary in that job's Alpine container).
  **Fixed (2026-08-21, follow-up session): root cause was a vendoring-process bug,
  not a build-process bug.** The original vendoring commit (`9d389a37`) added
  `dep/tcc/.gitignore` in the *same commit* as copying the whole upstream source
  tree in. Any upstream source file whose name happened to match a gitignore
  pattern got silently dropped from `git add` even though its bytes were written
  to disk — `conftest.c` (blocked by `conftest*`) was one casualty, and a second,
  previously-unnoticed one was found the same way: `win32/include/tcc/tcc_libm.h`
  (blocked by the bare `tcc` pattern matching the `win32/include/tcc/` directory
  component, not just the root `tcc` build output). Both confirmed byte-identical
  to upstream `TinyCC/tinycc` at the pinned commit (`dep/tcc/VERSION`,
  `2ba12e83b3599ca8f5d50c179fe5138fe956f0c9`) before being force-added. Every other
  ignored-and-untracked path under `dep/tcc/` (`git status --ignored`) was checked
  against `git ls-files` in a fresh clone of upstream at that same commit and
  confirmed to be local build-artifact cruft (`.o`/`.a`/binaries/generated docs —
  `config.h`, `config.mak`, `config.texi`, `tcc-doc.html`, `tcc-doc.info`, `tcc.1`,
  `tccdefs_.h`, `c2str.exe` — none tracked upstream, all reproducible by running
  `./configure && make`), correctly left ignored. `dep/tcc/.gitignore` narrowed to
  stop recurrence: bare `tcc` → `/tcc` (anchor to repo root so it only matches the
  build output binary, not any subdirectory named `tcc`), `conftest*` →
  `conftest` + `conftest-*` (upstream's own `configure` only ever creates a
  `conftest` binary or `conftest-$$*` temp files, never overwrites `conftest.c`
  itself). `dep/tcc/SOURCE_SHA256` regenerated via
  `tooling/scripts/vendor-verify.sh update tcc`. Verified: full `./configure && make`
  bootstrap (including `lib/libtcc1.a`) succeeds end-to-end in a fresh
  `docker run alpine:latest` container (matching CI's `tcc-linux-x86_64` job
  environment) with these two files present; all 8 patches
  (`dep/tcc/patches/0001`–`0008`) still apply cleanly against the updated tree
  when applied one-per-invocation, same as before this fix (no regression — this
  fix never touches any `.c`/`.h` file the patches target, only `.gitignore` +
  the two newly-tracked files + `SOURCE_SHA256`).

## build-vendored.yml: `git apply` with all 8 tcc patches as one multi-arg invocation fails (2026-08-21)

- [ ] **Unrelated pre-existing finding surfaced while verifying the conftest.c/tcc_libm.h
  vendoring fix above — not caused by that fix, not investigated further (out of scope for
  that task).** `build-vendored.yml`'s "Apply dep/tcc/patches" steps (`tcc-linux-x86_64`,
  `tcc-linux-aarch64`, `tcc-macos-arm64`, `tcc-windows-x86_64` jobs) all run
  `git apply dep/tcc/patches/0001-....patch dep/tcc/patches/0002-....patch ... 0008-....patch`
  as a single `git apply` invocation with all 8 patch files as separate pathspec arguments.
  Reproduced locally (fresh clone of this repo at `b6547ec2`, both on the host and inside
  `docker run alpine:latest`): that exact multi-arg invocation fails —
  `error: patch failed: dep/tcc/tccasm.c:45` / `error: dep/tcc/tccasm.c: patch does not apply`
  — even though every one of the 8 patch files applies cleanly when given to `git apply` one
  at a time, in the same order (`for p in 0001... ; do git apply "$p"; done` succeeds
  end-to-end, confirmed both on host and in the Alpine container). Confirmed present on
  `b6547ec2` (current HEAD before this session's changes) with no files modified, so this is
  not a regression from the conftest.c/tcc_libm.h fix — that fix touches no `.c`/`.h` file
  the patches target. Whether this multi-arg failure mode also reproduces inside actual GitHub
  Actions runners (vs. local Docker) wasn't checked — flagging rather than guessing; if it
  does reproduce there, the fix is presumably splitting each workflow's single `git apply`
  call into 8 sequential calls (one per patch file), but that's a call for whoever picks this
  up, not decided here.
  **Data point from the `0009` session (2026-08-21), does not close this.** The same multi-arg
  invocation was re-run in a freshly extracted tree at `36c8ff97` and at `b6547ec2` (the commit
  this entry names), and also directly in the working tree at `36c8ff97`, now with all 9 patch
  files: it applies cleanly every time on this host. What DOES reproduce the reported message
  exactly is adding `--check` — `git apply --check` validates each patch against the
  *unmodified* tree instead of chaining them, so `0003`'s `tccasm.c` hunks fail against context
  `0001` has not yet created, giving `patch failed: dep/tcc/tccasm.c:45`. That is a candidate
  explanation for the original report, not a confirmed account of what was run, so this stays
  open for whoever can check the actual invocation.

- [ ] **Want unused-local-variable checking as a real typechecker capability,
  not a bolt-on lint script.** Surfaced this session while cleaning up 15
  sites across the repo that used a `_ = expr` idiom (assign-to-discard) to
  suppress an "unused variable" feel — cruft that only existed because
  nothing in the toolchain flags unused locals today. User has previously had
  this via `lua-language-server` (luals) as an editor-side lint and wants the
  equivalent as a first-class typechecker feature (`bin/cr check`), not a
  separate script bolted onto the pipeline.
  This is a **new feature request**, not a restoration of dead-code coverage
  already present. `lib/type/static/rules/dead_locals.lua` already exists and
  covers a narrow slice of the same problem — "local assigned but never read"
  — but it is incomplete on two axes: it only walks top-level statements of
  the chunk (`M.check`'s `collect_locals` only scans `NODE_LOCAL_STMT` at
  `chunk.data[0]/data[1]`, i.e. the file's outermost block; anything declared
  inside a function body, `if`, `for`, `while`, etc. is invisible to it), and
  it explicitly skips test files (`if filepath:match("_test%.lua$") then
  return end`, `dead_locals.lua:280`). A real unused-local feature needs to
  walk into nested scopes (function bodies, blocks) and needs a decision on
  whether/how to handle test files (many of the 15 `_ = expr` sites found
  this session were inside `_test.lua` files precisely because the existing
  rule ignores them). No design work done yet on how this should integrate
  with the existing `dead_locals` rule (extend it in place vs. new rule) —
  flagging the gap and its context, not proposing the approach.

## Vendoring reproducibility: LuaJIT source + hash-signature verification (2026-08-14)

- [x] **LuaJIT source vendored into `dep/luajit/`, closing the zero-dependency violation
  where `build-vendored.yml` `git fetch`ed github.com/LuaJIT/LuaJIT at CI time instead of
  building from committed source like every other vendored dep.** Vendored at the commit
  already pinned (`1edc3e52b67eaf6ce5f809be8e17d6862594b8bc`, cloned live from upstream and
  verified byte-identical against `.git`'s fetched tree, then copied in without `.git/`).
  `dep/luajit/VERSION` records the pin; all five `luajit-*` jobs in
  `.github/workflows/build-vendored.yml` (linux-x86_64, linux-aarch64, macos-arm64,
  windows-x86_64, windows-x86) now `make -C dep/luajit/src` / run `msvcbuild.bat` against
  the local tree — no `git fetch`/`git clone`/cross-repo `checkout` of LuaJIT/LuaJIT remains
  anywhere in the workflow. The `luajit_ref` workflow_dispatch input is removed (it
  controlled a fetch that no longer happens; bumping LuaJIT now means re-vendoring
  `dep/luajit/`, same procedure as `dep/tcc/` — see the TinyCC section below). Verified the
  vendored source actually builds and runs (`make -C dep/luajit/src XCFLAGS=...` under
  `nix develop`'s gcc, produced a working `luajit -v`). `dep/luajit/` also got the
  VERSION/VENDORED_VERSION skip-logic parity that sqlite3/zlib/libressl already have (skips
  rebuilding when the pin hasn't moved).

- [x] **Content-hash verification added for every vendored dep's source tree** — sqlite3,
  zlib, libressl, wepoll, tcc, luajit. `dep/<name>/VERSION` only ever proved someone typed
  the right version string; nothing previously caught a hand-edit to committed vendored
  source that left `VERSION` untouched. `tooling/scripts/vendor-verify.sh` computes a
  manifest hash (sorted `path  sha256(file)` lines, itself sha256'd) over each dep's pinned
  source files — excluding prebuilt binaries CI writes back (`*.so`/`*.dylib`/`*.dll`,
  `dep/libressl/linux-x86_64/`) and the metadata files themselves — and records it in
  `dep/<name>/SOURCE_SHA256`. Wired into two real, failing gates (not decorative): (1)
  `build-vendored.yml`'s `version-check` job runs `vendor-verify.sh verify` for all six deps
  before anything builds, and every build job (`luajit-*`, `sqlite3-*`, `zlib-*`,
  `libressl-*`, `wepoll-*`, `tcc-bootstrap-*`) now `needs: version-check`, so a hash mismatch
  blocks the whole workflow; (2) `.githooks/pre-commit` runs the same check against any
  staged `dep/<name>/**` change and rejects the commit on mismatch, with the fix command
  printed. Verified both fire for real: tampered `dep/wepoll/wepoll.c` by hand, confirmed
  `vendor-verify.sh verify` and the pre-commit hook both fail loudly with the mismatch and
  the exact recorded/computed hashes; restored and reverified clean.

- [x] **`dep/wepoll/` had no VERSION pin at all — gave it one.** Diffed the vendored
  `dep/wepoll/wepoll.c` + `wepoll.h` against upstream (github.com/piscisaureus/wepoll,
  `dist` branch, which carries the same bundled single-file layout already vendored here):
  byte-identical to commit `0598a791bf9cbbf480793d778930fc635b044980`, tagged `v1.5.8`
  (the tip of `dist` at clone time — no ambiguity, exact match found on the first diff, no
  guessing required). `dep/wepoll/VERSION` = `1.5.8`; `dep/wepoll/VENDORED_VERSION` set to
  match (binaries already reflect this exact source); `dep/wepoll/SOURCE_SHA256` added.
  Wired into the same version-check skip-logic and push-trigger machinery sqlite3/zlib/
  libressl already use (wepoll was already push-triggered on `dep/wepoll/**`; it now also
  skips rebuilding when the pin hasn't moved, and its two Windows build jobs are hash-gated
  like everything else).

- [ ] **Not done, out of scope for this pass:** wiring the vendored `dep/luajit/` source
  into the tcc-as-`CC` `tcc-build-deps-*` job (unattempted as of this pass — later wired in
  and verified end-to-end, see the TinyCC section's "Update 2" note below; that job was
  subsequently removed entirely, see the note appended after "Update 2"). Extending hash
  verification or VERSION/VENDORED_VERSION skip-logic to
  platforms/deps beyond what's listed above (e.g. macOS/Windows sqlite3/zlib binaries are
  still built unconditionally by the `commit` job's per-artifact `copy_if_present`, unrelated
  to this pass). `dep/xterm-js` and `dep/acorn` (JS deps for `docs/`) were not touched —
  they're contributor tooling, not part of the zero-dependency runtime vendoring set this
  task scoped to.

## TinyCC (tcc) fallback compiler tier (vendored, 2026-08-14)

- [ ] **`dep/tcc/VERSION` (mob branch commit SHA) is pinned to a specific commit and does
  NOT auto-track upstream — bump it manually, periodically, by design.** This is an
  intentional reproducibility-over-freshness tradeoff, not a bug or an oversight: `mob` is
  an untagged, actively-moving branch, so pinning "the branch name" means two builds on
  different days silently vendor different, unreviewed code. A commit SHA pin means the
  vendored code only changes on a deliberate commit that bumps the pin. Cost: tcc's
  security fixes or improvements don't land until someone manually re-pins. To bump:
  `git ls-remote https://github.com/TinyCC/tinycc mob`, update `dep/tcc/VERSION`,
  re-vendor `dep/tcc/` from the new SHA, regenerate its hash
  (`tooling/scripts/vendor-verify.sh update tcc`), and re-run `bin/cr test` plus a manual
  `nix develop`-shell tcc bootstrap smoke test.
  **LuaJIT's equivalent pin moved to the same mechanism (2026-08-14):** the old
  `luajit_ref` workflow_dispatch input that `git fetch`ed
  github.com/LuaJIT/LuaJIT at CI time is gone — LuaJIT source is now vendored in
  `dep/luajit/` (same treatment as tcc/sqlite3/zlib/libressl: `dep/luajit/VERSION` pins the
  commit SHA, `dep/luajit/SOURCE_SHA256` hash-verifies the tree, `build-vendored.yml`'s
  five `luajit-*` jobs build from `dep/luajit/src` directly, no network fetch). To bump:
  `git ls-remote https://github.com/LuaJIT/LuaJIT v2.1`, re-vendor `dep/luajit/` from the
  new SHA (update `dep/luajit/VERSION`, replace the source tree, regenerate the hash with
  `tooling/scripts/vendor-verify.sh update luajit`), and rebuild.

- [x] **tcc's assembler rejected GNU-as `sym@PLT` relocation-suffix syntax outright — now
  patched (`dep/tcc/patches/0001-plt-suffix.patch`), verified in isolation, LuaJIT still NOT
  wired in.** Root cause was purely a parser gap in `tccasm.c`'s `asm_expr_unary`: after
  resolving a bare identifier as a symbol it called `next()` with zero lookahead for a
  trailing `@PLT`, so `sym@PLT` tokenized as three separate tokens and choked on `@`.
  `i386-asm.c`'s `gen_disp32` already emitted the correct `R_X86_64_PLT32` relocation for
  external call/jmp targets unconditionally, so the fix is purely syntactic: peek for `@`
  followed by the identifier `PLT` and discard both if present (leaving the symbol resolution
  untouched), restoring the original tokens via `unget_tok` if it's any other suffix (`@GOT`,
  `@GOTPCREL`, `@TLSGD`, ... — deliberately NOT handled, still errors as before). Verified by
  actually building tcc from the patched source (`nix develop`'s system gcc bootstraps it) and
  assembling a standalone `call pow@PLT` / `jmp bar@PLT` test file: correct `R_X86_64_PLT32`
  relocations emitted, byte-identical to real GNU `as` output; a `sym@GOTPCREL` test still
  errors as before, confirming the narrow scope held. **NOT verified: a full LuaJIT build
  with this tcc** — building `lj_vm.S` requires bootstrapping LuaJIT's own host tools first.
  LuaJIT remains unwired in `tcc-build-deps-*`; the vendored LuaJIT binaries and the existing
  gcc/clang-based `luajit-*` CI jobs remain the only way LuaJIT gets built. Revisit (rewire
  LuaJIT into `tcc-build-deps-*`) only once a real `lj_vm.S` has actually been assembled and
  linked successfully with this patched tcc.
  **Update (2026-08-14):** the "no LuaJIT source is vendored in this repo" premise above no
  longer holds — LuaJIT source is now vendored in `dep/luajit/` (see the pin-bump item
  above). That removes the "no source to build `lj_vm.S` against locally" blocker
  specifically; the "bootstrapping LuaJIT's own host tools" and the actual tcc-as-`CC`
  wiring into `tcc-build-deps-*` are still unattempted and still the open work.
  **Update 2 (2026-08-14) — actually wired in and verified end to end for real, in the
  exact `alpine:latest` container this job runs in (not a substitute host); found a genuine
  compiler-intrinsics gap, not fixed:**
  - **Two pre-existing bugs found and fixed, unrelated to LuaJIT, that were silently
    breaking `tcc-bootstrap-linux-x86_64`/`-aarch64` and `tcc-build-deps-linux-x86_64` for
    sqlite3/zlib too** (both jobs are `workflow_dispatch`-only, so nobody had actually run
    them for real since they were written): (1) `tcc-bootstrap-linux-{x86_64,aarch64}` ran
    `./configure` with no flag inside an Alpine (musl) container; tcc's own configure does
    NOT autodetect musl, so it took the glibc-assuming branch, and `lib/bcheck.c` (built
    into `libtcc1.a`) calls the glibc-only `__ctype_b_loc()`/`__ctype_tolower_loc()`, which
    musl lacks — `make` failed `bcheck.c:1068: error: pointer expected` and the whole
    bootstrap job would have failed on every real invocation. Fix: `./configure
    --config-musl`. Reproduced the failure verbatim, then confirmed the fix, both inside a
    real `alpine:latest` Docker container matching the CI image exactly. (2)
    `tcc-build-deps-linux-x86_64`'s "Prepare tcc" step put `libtcc1.a` at
    `tcc-bin/lib/libtcc1.a`; tcc's own `CONFIG_TCC_LIBPATHS` (`tcc.h`) resolves to `"{B}" ":"
    "/usr/lib"` for this target — no implicit `/lib` suffix under `-B` — so that layout is
    silently never found and even a trivial `tcc -B tcc-bin hello.c -o hello` failed `tcc:
    error: file 'libtcc1.a' not found`. Fix: place it directly at `tcc-bin/libtcc1.a`.
    Re-verified sqlite3 and zlib both build cleanly against tcc with both fixes applied
    (previously only claimed "verified" from a non-Alpine sandbox that never hit either
    bug). Both fixes are now in `build-vendored.yml` with comments explaining why.
  - **LuaJIT itself: genuine substrate gap, confirmed, NOT fixed, NOT worked around.**
    `dep/tcc` (mob@2ba12e83b3599ca8f5d50c179fe5138fe956f0c9) defines only `__TINYC__` in its
    predefined macros — never `__GNUC__` or `__clang__` — and provides none of the
    `__builtin_ctz`/`__builtin_clz`/`__builtin_ctzll`/`__builtin_clzll` builtins. LuaJIT's
    `lj_def.h` has exactly three branches for `lj_ffs`/`lj_fls`/bit-scan helpers: GCC/clang
    (via `__GNUC__`/`__clang__`, using those builtins), MSVC (via `_MSC_VER`, using
    `_BitScanForward`/`_BitScanReverse` intrinsics), and a `_M_PPC`+`LUAJIT_NO_UNALIGNED`-only
    manual fallback — anything else, including tcc, falls through to `#error "missing
    defines for your compiler"`. This fires at `host/buildvm.o` (a LuaJIT host tool needed
    to generate `lj_vm.S` and friends), i.e. before the `sym@PLT`/`lj_vm.S`
    assembler question the 0001-plt-suffix.patch item above was scoped to ever gets
    reached — `host/minilua` (no GNUC dependency) builds and runs fine under tcc, but
    `buildvm` does not compile at all. Exact repro: `make -C dep/luajit/src CC="<tcc> -B
    <tcc-bin>" XCFLAGS="-DLUAJIT_ENABLE_GC64"` inside the same `alpine:latest` container,
    after both tcc fixes above → `In file included from host/buildvm.c:17: ... ./lj_def.h:322:
    error: "missing defines for your compiler"`. Confirmed via `tcc -E -dD` macro dump that
    tcc predefines `__TINYC__` and nothing else relevant. Closing this needs either a
    `__TINYC__` branch added to LuaJIT's own `lj_def.h` (an upstream LuaJIT change, not a
    local patch) or teaching tcc to define `__GNUC__`-compatible builtins (substantially
    larger than either existing `dep/tcc/patches/*.patch`) — neither attempted here, per
    CLAUDE.md's no-special-casing/no-fake-success rule. `tcc-build-deps-linux-x86_64` now has
    a real (not commented-out, not `continue-on-error`) "Build LuaJIT with tcc" step that
    will fail exactly this way until the gap above is closed — the job is expected to be red
    on `workflow_dispatch` until then. This does not affect the five gcc/clang-based
    `luajit-*` CI jobs (linux-x86_64/aarch64, macos-arm64, windows-x86_64/x86), which remain
    the only working way LuaJIT gets built and are unaffected by any of this.
  - **Scope correction (2026-08-16, found while verifying patch `0006`): this blocker is not
    confined to `host/buildvm.c`.** The wording above ("fires at `host/buildvm.o`", "`buildvm`
    does not compile at all") reads as though `buildvm` is the one obstacle and LuaJIT would
    build once past it. It is not — EVERY LuaJIT C source hits the identical
    `lj_def.h:322: error: #error "missing defines for your compiler"`. Verified directly against
    this vendored tcc: `lj_state.c`, `lj_gc.c`, `lj_api.c` and `host/buildvm.c` all fail the
    same way; only `lj_vm.S` (assembly, which does not include `lj_def.h`) compiles. So the
    accurate statement is "tcc cannot compile LuaJIT at all", not "tcc cannot build LuaJIT's
    host tools". This does not change the fix options already recorded above, but it does change
    the size of the task: closing it unblocks the whole build, not one tool.
  - **`tcc-build-deps-linux-x86_64` (and the other `tcc-build-deps-*`/`tcc-bootstrap-*`
    diagnostic jobs) removed entirely (commit `59b4e224`, "refactor(ci): fold tcc back into
    build-vendored.yml, full lockstep").** The job never produced a shippable artifact — it
    existed only to verify tcc-as-`CC` against the vendored deps — and every finding it
    surfaced (the two pre-existing bootstrap/libpath bugs fixed above, sqlite3/zlib building
    cleanly, libressl needing `--disable-asm`, and the LuaJIT `__TINYC__`/`lj_def.h`
    substrate gap) is already captured in this file, so keeping a live CI job around to
    re-derive already-recorded findings was redundant. This section stays as the durable
    record of what was found; there is no corresponding job in `build-vendored.yml` anymore.

- [x] **libressl's perlasm-generated `*-elf-x86_64.S` files use SSE2/AES-NI opcodes tcc's
  assembler had zero table entries for — now patched
  (`dep/tcc/patches/0002-libressl-sse-aesni-opcodes.patch`), but this does NOT fully unblock
  `--disable-asm` removal (see the new gap below).** Confirmed by grepping the actual
  vendored files (not the originally-assumed opcode list — `pclmulqdq` turned out to be
  unused; `paddq` and `pinsrw` turned out to be needed and were missing from the initial
  list) that `dep/tcc/x86_64-asm.h` (the table actually used by the x86_64 target — a
  *separate* file from `i386-asm.h`, discovered while implementing this) had no entries for
  `movdqa`/`movdqu`, `pshufd`, `shufps`, `xorps`, `pslldq`/`psrldq`, `paddq`, `pinsrw`, or the
  AES-NI family (`aesenc`/`aesdec`/`aesenclast`/`aesdeclast`/`aesimc`/`aeskeygenassist`).
  Table-only entries sufficed for everything except the AES-NI family, which needs the 0F38/
  0F3A three-byte-opcode escape maps that the existing 16-bit opcode/prefix-byte table
  encoding has no room for — `dep/tcc/i386-asm.c` gained two new instr_type flags
  (`OPC_0F38`, `OPC_0F3A`, using previously-unused bits) and a small addition to the opcode
  emission switch to insert the extra escape byte; this is shared code so it also compiles
  (as dead code, no vendored i386-asm.h entries reference the new flags) for the 32-bit
  `windows-x86` target without touching 32-bit behavior. Verified by building tcc from the
  patched source and assembling every new/changed opcode form (both operand directions where
  applicable) side-by-side with real GNU `as` — objdump output is byte-identical across all
  21 forms. Verified further against the real vendored files: `aes-elf-x86_64.S`,
  `rc4-elf-x86_64.S` (needs `pinsrw`), and `bn/{modexp512,mont,mont5}-elf-x86_64.S` all
  assemble cleanly with the patched tcc.
  **New gap found in the process, NOT fixed here:** `aesni-elf-x86_64.S` and
  `modes/ghash-elf-x86_64.S` still fail — not on opcodes, but because this vendored tcc
  (mob@2ba12e83b3599ca8f5d50c179fe5138fe956f0c9) defines no `xmm8`–`xmm15` registers at all
  (and, checked at the same time, no `r8`–`r15` general-purpose registers either) under
  `TCC_TARGET_X86_64` — `dep/tcc/i386-tok.h` only defines `xmm0`–`xmm7`. This is a
  substantially larger gap than the opcode-table one (needs new register tokens plus
  REX.R/X/B extension-bit plumbing through the ModRM/SIB encoding, most of which doesn't
  exist yet for *any* register class) and is out of scope for this session's two targeted
  fixes — recorded here, not attempted. *Correction from the `0010` session: the
  `r8`–`r15` half of that finding and the "REX plumbing doesn't exist" reading are both
  wrong — see the `0010` entry below for what the source actually does.* Because of this,
  `--disable-asm` in
  `tcc-build-deps-linux-x86_64` was deliberately left in place (not flipped): removing it
  would make that CI job fail on these two files. sqlite3 and zlib remain the two
  locally-verified-working deps from before; libressl's `--disable-asm` path itself (i.e.
  configuring/building/linking successfully) is still not locally verified end-to-end — this
  sandbox's tcc could not build its own `libtcc1.a` runtime helper library (unrelated
  environment issue: tcc couldn't find `stdio.h` under this NixOS sandbox's default include
  path), which blocks a full local `./configure && make` link test regardless of the asm
  question. `tcc-build-deps-linux-x86_64` no longer exists to confirm this via
  `workflow_dispatch` (removed in `59b4e224`, see the note above); confirming would need a
  manual local bootstrap of tcc (same `nix develop`-shell approach used for the other tcc
  verification in this effort, e.g. the smoke test and opcode-table checks recorded above)
  followed by a local `./configure && make` of libressl with that tcc as `CC`.

- [x] **RESOLVED by `dep/tcc/patches/0010-extended-sse-registers.patch` (2026-08-21):
  this vendored tcc could not name `%xmm8`–`%xmm15`.** The entry as originally written
  claimed two missing register sets plus absent REX.R/X/B plumbing through the ModRM/SIB
  encoding; re-deriving it from the source before implementing showed one third of that was
  right, and the correction is the reason the fix is two hunks rather than the "materially
  bigger change" this entry predicted. **`%r8`–`%r15` were never missing** — they and their
  `d`/`w`/`b` width forms already assembled, byte-identically to GNU `as`, including as SIB
  base and index. They are absent from `dep/tcc/i386-tok.h` because they are not tokens:
  `asm_parse_numeric_reg()` in `i386-asm.c` parses them out of the identifier text (which is
  also how it handles `cr8`–`cr15`). **The REX plumbing already existed** too: `asm_rex()`
  maps any register number `>= 8` onto REX.R (ModRM.reg), REX.B (ModRM.rm / SIB.base) or
  REX.X (SIB.index), subtracts 8, and `asm_modrm()` sees a 3-bit number — and its `rmi`
  branch already listed `OP_SSE` among the classes it extends. The single real gap was that
  `i386-tok.h` stopped at `xmm7`, so `%xmm8` was rejected at parse time before any of that
  ran. Fixed by adding the eight names *at the end* of the register token list, not after
  `xmm7`: `parse_operand()` derives an operand's class from position in one contiguous block
  as `1 << ((tok - TOK_ASM_al) >> 3)`, so inserting a ninth group there would silently
  renumber `cr`/`tr`/`db`. They get an explicit parse branch setting `OP_SSE` and a register
  number of 8–15, the pattern `%spl`/`%bpl`/`%sil`/`%dil` already established. Verified with
  `dep/tcc/patches/0010-tests/run.sh`: 8 cases pass, each byte-identical to GNU `as` on
  PROGBITS content and the normalized relocation table, covering REX.R/B/X and their
  combinations, the `%rsp`/`%r12` forced-SIB and `%rbp`/`%r13` forced-displacement corners,
  the 0F38/0F3A three-byte maps (REX must precede the `0x0f` escape), mixed GP/SSE operands
  and RIP-relative; against an `0001`–`0009` baseline the same harness gives 2 pass / 6 fail,
  the two passing being the `xmm0`–`xmm7` control and the `%r8`–`%r15` guard. On the real
  perlasm, all 583 (`aesni`) and 427 (`ghash`) extended-register instructions encode
  byte-identically to `as`. No regression: the other five `*-elf-x86_64.S` objects are
  byte-identical to the baseline build, a fresh `buildvm`-generated `lj_vm.S` assembles to a
  byte-identical object and its LuaJIT runs with the JIT on, and tcc's own `make test` /
  `tests2` reach the same stage on both builds (differing only in paths and ASLR addresses).
  See `docs/native-tiers.md`. **AVX deliberately not touched:** this tcc has no `ymm`/`zmm`
  registers and no VEX encoding path at all, so extending to them is a new encoding
  mechanism rather than more register names — out of scope here, not blocking anything known.

- [ ] **`dep/tcc/x86_64-asm.h` types the register-to-register form of `movups`, `movaps`
  and `movhps` as `OPT_EA | OPT_REG32` where it must be `OPT_EA | OPT_SSE`** — so
  `movaps %xmm0,%xmm1` is rejected with `bad operand with opcode 'movaps'`. Not
  extended-register-specific: it fails identically on `xmm0`–`xmm7` and on the unpatched
  vendored tcc, and it was simply hidden behind the `%xmm8` gap until `0010` closed that.
  Found while verifying `0010`, by assembling `dep/libressl/crypto/aes/aesni-elf-x86_64.S`,
  which now reaches line 828 (`movaps %xmm9,%xmm2`) before failing. Same family as
  `0002-libressl-sse-aesni-opcodes.patch` (opcode-table entries that disagree with real
  `as`). Probed locally: changing the three entries' `OPT_REG32` to `OPT_SSE` makes the form
  assemble; the resulting choice between the two `ALT` encodings (`0f28` vs `0f29`) needs
  checking against real `as` before this is called done, and that check was not run — the
  probe was reverted rather than kept, to keep `0010` to one concern.

- [ ] **tcc's assembler has no `.value` directive** (`dep/tcc/tccasm.c` has
  `TOK_ASMDIR_word`/`TOK_ASMDIR_short` but nothing for `value`, GAS's synonym for
  `.short`) — `dep/libressl/crypto/modes/ghash-elf-x86_64.S` fails at line 1004 on the
  `.Lrem_8bit` table with `incorrect number of operands`, because `.value` is not recognized
  as a directive and falls through to opcode parsing. Found while verifying `0010`; unrelated
  to registers, and the second of the two blockers now standing between the current tcc and
  assembling `ghash-elf-x86_64.S`. Probed locally (a `DEF_ASMDIR(value)` alongside `short`
  plus a fallthrough case in the emitter is enough to make the file assemble); the probe was
  reverted rather than kept, to keep `0010` to one concern. Whether GAS's `.value` is exactly
  `.short` in every respect was not confirmed against the `as` documentation or binary.

- [ ] **With those two fixed, both blocked perlasm files assemble** — confirmed locally by
  applying `0010` plus both probes above and assembling
  `dep/libressl/crypto/aes/aesni-elf-x86_64.S` and
  `dep/libressl/crypto/modes/ghash-elf-x86_64.S` cleanly. That is the remaining distance to
  dropping `--disable-asm` for libressl; the output was not compared against `as` for those
  two files under the probes, only under `0010` alone (extended-register instructions only).

- [x] **tcc's `.section NAME,"flags"` assembler directive hardcoded `SHF_ALLOC` into
  every parsed section's flags and never recognized `a` in the flags string at all — now
  patched (`dep/tcc/patches/0004-asm-section-flags-alloc.patch`), verified against real
  GNU `as`.** Root cause was in `tccasm.c`'s `TOK_ASMDIR_section`/`TOK_ASMDIR_pushsection`
  handler: `int flags = SHF_ALLOC;` initialized the flags unconditionally regardless of
  whether an explicit flags string was given at all, and the flag-parsing loop for the
  explicit-string case only ever set `SHF_WRITE` (`w`) and `SHF_EXECINSTR` (`x`) — `a`
  (alloc) was parsed nowhere, so it was structurally impossible to end up WITHOUT
  `SHF_ALLOC`. Real GNU `as` semantics (confirmed against the actual `as` binary): an empty
  flags string (`.section foo,""`) gets no `SHF_ALLOC`; `"a"` present sets it; `"w"` alone
  is write-only, no alloc unless `a` is also present. Fixed by changing the default to
  `int flags = 0;` and adding an `a` → `SHF_ALLOC` case to the parsing loop. Pre-created
  sections (`.text`/`.data`/`.bss`, allocated via `new_section()` in `tccelf.c` before any
  `.section` directive runs) are unaffected by construction, independent of the fix: the
  flags-overwrite block in `tccasm.c` only fires when `use_section`/`push_section` just
  allocated a NEW section (`old_nb_section != s1->nb_sections`), and `.text`/`.data`/`.bss`
  already exist by the time any `.section` directive executes, so that block never runs for
  them. Verified empirically: built tcc from the patched source (plain `./configure && make tcc`,
  this sandbox's system gcc) and assembled a repro `.S` exercising `.text`/`.data`/`.bss`
  plus `.section` with `""`, `"a"`, `"w"`, `"wa"`, `"ax"` flag strings; compared
  `readelf -SW` output against real system `as` on the same file — flags matched exactly for
  every case (`.sec_empty` → none, `.sec_a` → `A`, `.sec_w` → `W`, `.sec_wa` → `WA`,
  `.sec_ax` → `AX`, and `.text`/`.data`/`.bss` → `AX`/`WA`/`WA` in both). Cross-checked
  against the UNFIXED tcc build on the same file to confirm the bug and its blast radius
  precisely: unfixed tcc produced `.sec_empty` → `A` (wrong, should be none) and `.sec_w` →
  `WA` (wrong, should be `W` only) — exactly the two cases the fix corrects, nothing else
  changed. Regression-checked against the vendored libressl `*-elf-x86_64.S` files used to
  verify `0002-libressl-sse-aesni-opcodes.patch`: with `0001`+`0002`+this patch applied
  together, `aes-elf-x86_64.S`, `rc4-elf-x86_64.S`, and `bn/{modexp512,mont,mont5}
  -elf-x86_64.S` still assemble cleanly; `aesni-elf-x86_64.S` and `modes/ghash-elf-x86_64.S`
  still fail on the pre-existing, separately-recorded `xmm8`–`xmm15` register gap above, not
  on anything section-flags-related — no regression introduced.
  **Separate, deeper, NOT-fixed bug found while re-confirming this area of `tccasm.c`,
  intentionally left alone (`x86_64-gen.c` not touched):** `gen_addr32()` in
  `dep/tcc/x86_64-gen.c` (~line 265) hardcodes `R_X86_64_32S` for every 32-bit
  symbol+addend relocation regardless of context. Real `as` uses `R_X86_64_32` for
  unsigned contexts (e.g. `.long`, `movl $sym,%eax`) and reserves `R_X86_64_32S` for
  signed-extension contexts (e.g. `movq $sym,%rax`); naively flipping the constant would
  break the case tcc already gets right, so this needs a context-aware fix, not a one-line
  swap. Additionally, tcc has no section-symbol allocation / local-to-section-symbol
  relocation-rewriting subsystem at all — real `as` targets a section symbol for
  relocations against static data rather than the local label directly, and tcc has no
  equivalent mechanism. This is missing infrastructure requiring its own scoped design
  pass (per CLAUDE.md's substrate-before-consumers rule), not a quick fix — not attempted
  here.

- [x] **tcc's assembler broke `.file`-directive string parsing for the rest of the
  translation unit, and had no way to fold a same-section forward-forward label
  difference (`.long .LEND-.LSTART` written before either label is defined — the DWARF
  CIE/FDE length-prefix idiom) — now patched
  (`dep/tcc/patches/0003-asm-forward-label-diff-and-leb128.patch`), verified against real
  GNU `as 2.44`.** Two related bugs in `tccasm.c`'s `TOK_ASMDIR_file` handler and
  `asm_expr_sum()`. (1) The `.file` handler cleared `PARSE_FLAG_TOK_STR` to lex the raw
  file name as a non-string token, but only restored it on one exit path — the early
  `skip_to_eol` path left it cleared permanently, so every later `.section`/`.string`/
  `.ascii`/`.asciz` in the same translation unit saw `TOK_PPSTR` and failed. Fixed by
  saving/restoring the flag on every exit path. (2) `label2 - label1` where at least one
  label is still a forward reference previously hit `tcc_error("invalid operation with
  label")` unconditionally — real `as` defers such expressions and resolves them once the
  whole input is read. Fixed by adding a deferred-fixup mechanism (`ExprValue.sym2`,
  `AsmFixup` list, `asm_resolve_fixups()` called after `tcc_assemble_internal()` and after
  inline `asm()` statements): `.byte`/`.word`/`.long`/`.quad` reserve the field's bytes and
  register a fixup when the difference can't be folded immediately, patched in once both
  labels are defined. **Deliberately does NOT implement variable-width LEB128 relaxation**
  — a label difference used as a `.uleb128`/`.sleb128` operand is a fixed-size field only
  after relaxation, which this patch doesn't attempt; it is instead a documented, explicit
  hard error (`"unsupported: LEB128 of an unresolved symbol difference (needs
  variable-width relaxation)"`) rather than being silently mis-encoded at the wrong width.
  That relaxation infrastructure landed separately as `0005` — see below. Verified empirically: regenerated a complete,
  untruncated `dep/luajit/lj_vm.S` from source via buildvm (including its full
  `.eh_frame`/`.debug_frame` tail, which exercises exactly this forward-label-difference
  idiom), assembled it with the patched tcc, and confirmed `.text` and `.debug_frame` are
  byte-identical to real GNU `as 2.44` output (`--nocompress-debug-sections`, since gas
  defaults to compressed debug sections and tcc doesn't support them). Full end-to-end
  luajit link+run against the tcc-assembled object: JIT active, error unwinding through a
  jit-compiled loop via `pcall`, ffi working. Regression-checked against the libressl
  `*-elf-x86_64.S` files (same set used for `0002`/`0004`) plus tcc's own test suite: zero
  new failures vs. the `0001`+`0002`+`0004` baseline, confirmed by a direct differential
  run (patched-with-0003 vs. patched-without-0003, otherwise identical scratch builds) —
  byte-for-byte identical failure logs modulo multithreaded-test timing/ordering noise.
  **Re-verified after `0004` landed** (this patch was originally authored and verified
  before `0004` existed): all four patches apply together cleanly in numeric order,
  `.text`/`.debug_frame` byte-identity against real `as` reconfirmed, end-to-end
  luajit run reconfirmed, libressl regression pattern reconfirmed unchanged. One
  unresolved discrepancy from re-verification, noted rather than silently corrected: the
  originally-recorded "8 pre-existing failures" baseline could not be reproduced in the
  re-verification sandbox, which found only 4 failing top-level `make test` targets
  (`test3`, `memtest`, `cross-test`, `test1b`, all the same unrelated root cause,
  `tcctest.c:338: error: exponent digits expected`) — identically present with or without
  0003. The *shape* of the evidence (0003 adds zero new failures) is solid via the
  differential; the absolute count differs by environment (container/config differences
  affecting which test targets run) and hasn't been reconciled.

- [x] **`.uleb128`/`.sleb128` with an unresolved label difference now relax to their true
  minimal width instead of hard-erroring — `dep/tcc/patches/0005-asm-leb128-relaxation.patch`.**
  Closes the gap `0003` documented. A LEB128 operand's *width* is what the value determines,
  so unlike a fixed-width field there is nothing to reserve at parse time. Patching the
  emitted bytes afterwards is not possible in tcc: same-section branch displacements are
  written as bare immediates with no relocation (`i386-asm.c` `gen_disp32`), forward-jump
  chains are threaded through the not-yet-patched displacement fields themselves
  (`x86_64-gen.c` `gsym_addr`), and `.align` padding is a function of absolute position, so
  a size delta is not even uniform across a section. Any of those corrupts silently.
  Implemented instead as genuine multi-pass re-layout: assemble, measure every site, and if
  any width was wrong rewind all state and assemble again with the better guess. Widths only
  grow, which bounds the iteration (a LEB128 is ≤10 bytes) and yields the same minimal fixed
  point GNU `as` computes. Passes after the first replay a captured token stream
  (`tok_capture` in `tccpp.c`) rather than re-reading source, so the preprocessor runs exactly
  once — re-running it would re-evaluate `#include`/`#pragma once` against already-mutated
  state and silently change the input. Three non-obvious correctness points, each found by a
  forced-multipass idempotence check (force ≥3 passes; output must be byte-identical) rather
  than by reading: (1) capture must exclude tokens replayed from an `unget_tok()` pushback —
  they were either already captured or are synthetic tokens the parser invents
  (`i386-asm.c` `asm_parse_regvar`), and the parser re-performs the pushback on replay;
  (2) capture must be suppressed inside `preprocess()`, or `#if defined X` gets replayed to
  the assembler as an instruction; (3) `tcc_debug_start`/`tcc_debug_end` must bracket the
  *whole* iteration, not each pass, because they derive the unit identity from the lexer file
  stack (`file->prev ? file->prev->filename : file->filename`) which only has its original
  shape on pass 0 — and for the same reason the rewind point is taken *after* the first
  token, since lexing it pops the `<command line>` buffer and that pop emits the `N_EINCL`
  closing `tcc_debug_start`'s `N_BINCL`. Per-pass DWARF/stabs line state is wound back via
  `tcc_debug_pass_save`/`_restore` (`tccdbg.c`). Relaxation is rejected with an explicit
  error inside function-body inline `asm()`, which genuinely cannot be replayed — non-local
  labels hard-error on redefinition, relocations have no removal API, and `nocode_wanted`
  is not normalized there. Verified: 9 purpose-built test cases byte-match real GNU `as 2.44`
  (including the genuinely-iterative ones — a site inside the range it measures, where `as`
  guesses 1 byte, finds 128, and regrows to `8101`; growth absorbed by `.align`; and
  relocation offsets that land correctly only because an earlier site grew); 28/28 inputs
  byte-identical under forced 3-pass replay with and without `-g`; `lj_vm.S` byte-identical
  to the pre-patch tcc and `.text`/`.debug_frame` byte-identical to `as`; C front-end output
  byte-identical across tcc's own `lib/*.c` plus an inline-asm/macro test; zero byte diffs
  and zero status changes against the `0001`–`0004` baseline on libressl `*-elf-x86_64.S`,
  `asmtest.S` and `lib/*.S`; end-to-end luajit link+run (JIT active, `pcall` unwinding
  through a jit-compiled loop, ffi). Note `lj_vm.S` itself contains **no** label-difference
  LEB128 operands — all 37 of its `.uleb128`/`.sleb128` are literal constants, as are those
  in every `vm_*.dasc` target, and a repo-wide grep over `dep/` finds none. This patch is
  therefore general assembler infrastructure with no current consumer in-tree, landed
  deliberately as such.

- [x] **A real gcc object carrying a debug section outside tcc's own fixed set (verified case:
  `.debug_types` from `gcc -gdwarf-4 -fdebug-types-section`) hard-errored
  at link time with `relocation 'R_X86_64_32[S]' out of range` — fixed by
  `dep/tcc/patches/0006-dwarf-section-flag-and-debug-retention.patch`.** Pre-existing on the
  vendored source with zero forks applied. A 32-bit reference between two dwarf sections is a
  section-relative offset, not an address; tcc recognized those by testing whether a section's
  index fell inside `dwlo..dwhi` (`tcc.h:924`, checked at `tccelf.c:1145,1159` and
  `tccpe.c:1148,1170`), which is the block of debug sections tcc creates for itself. Since
  `R_DATA_32DW` is plain `R_X86_64_32` on x86_64 (`tcc.h:1921`), that index-range test was
  carrying the entire "is this a debug section" decision, via creation contiguity as a proxy —
  and the proxy fails for any debug section tcc did not create. Replaced with an explicit
  `Section->is_dwarf` set once in `new_section()`; ELF has no structural marker, so it is a
  `.debug_` name check, matching the classification `tcc_load_object_file()` already used.
  Whether the misresolution actually *errors* depends on where the referenced section lands:
  `.debug_types` points at `.debug_abbrev`/`.debug_str`/`.debug_line`, which are tcc's own and
  are `SHF_ALLOC` at high addresses under `-run` with `-g` (`tccdbg.c:445` turns on
  `do_backtrace`, which sets `shf = SHF_ALLOC` for them), so the absolute value overflows 32
  bits. A foreign section whose 32-bit reference points within *itself* stays at `sh_addr` 0,
  where absolute and section-relative coincide — checked explicitly for `.debug_frame`'s CIE
  pointer, which carries the same `R_X86_64_32`-to-a-debug-section shape but resolves to 0 both
  ways and so silently worked before and after. Recorded because an earlier framing of this bug
  listed `.debug_frame` as an affected case; it is affected in principle, not in practice.
  Per-`Section` granularity is provably sufficient — correctness depends only on which two
  sections a relocation is between, never on which object contributed it. Verified: repro
  (`gcc -gdwarf-4 -fdebug-types-section -gz=none -c`, linked `-gdwarf -nostdlib ... -run`) goes
  from 6 hard errors to exit 0 with the correct computed result, and all 6 relocations were
  checked to resolve to exactly the right section-relative values (byte-level check against the
  independently-computed merge offsets, not just "no error"): `.debug_abbrev+0 → 0x14f`,
  `.debug_line+0 → 0x4e`, four `.debug_str` entries all correct. Byte-identical to the
  `0001`–`0005` baseline across `-c`/link × `-gdwarf`/`-g`/`-gstabs`/`-g0`/`-O2`, and with
  merged foreign dwarf-4 and dwarf-5 debug objects. tcc's own test suite run differentially
  (NixOS needs `--crtprefix`/`--libpaths={B}:...`/`--sysincludepaths`/`--elfinterp` pointed at
  the nix store, else it dies at `hello-exe` before reaching anything relevant): identical
  failing-target sets (`test1b`, `test3`, `memtest`, `cross-test`, all the pre-existing
  `tcctest.c:338: error: exponent digits expected`), logs identical modulo ASLR addresses and
  multithreaded fib ordering (multisets verified equal). libressl `*-elf-x86_64.S`: 5 assemble
  byte-identically, 2 fail on the pre-existing `xmm8`–`xmm15` gap with identical messages.
  `dep/luajit/src/lj_vm.S` (which contains `.debug_frame` and `.eh_frame`) assembles
  byte-identically. eh_frame orphan-CIE checked in both producer orderings.

- [x] **Debug sections from a foreign object are now retained through a link without `-g`
  (same patch `0006`).** `tccelf.c:3350`'s `!s1->do_debug` gate dropped them entirely, and
  `set_sec_sizes` (`tccelf.c:2221`) left their `sh_size` unpublished, which makes
  `alloc_sec_names()` assign no `sh_name` and `sort_sections()` then class them `0x900`
  ("won't go to file") — so retention alone was not enough; both sites needed fixing. The
  `sh_size` predicate gained `|| s->is_dwarf` specifically (not a broader loosening): tracing
  showed the existing `|| s1->do_debug` is what publishes sizes for `.stab`/`.stabstr` and other
  non-alloc sections under `-g`, so replacing rather than extending it would have regressed
  those. Verified: `-g0` link against a `-gdwarf-4 -gz=none` object now retains 6 `.debug_*`
  sections where baseline retained 0, the retained info genuinely parses (`readelf
  --debug-dump=info` resolves indirect string offsets to real strings and shows a correctly
  relocated `DW_AT_low_pc`), every non-debug section (`.text`/`.data`/`.rodata`/`.bss`/
  `.eh_frame`) stays byte-identical, and a control object with no debug sections links
  byte-identically.

- [x] **`0006` LuaJIT verification: no regression, with an honest limit on what it proves.**
  `lj_vm.S` regenerated fresh from source (`make clean` then the full
  `minilua` → `buildvm_arch.h` → `buildvm` → `lj_vm.S` chain) came out byte-identical to the
  committed `dep/luajit/src/lj_vm.S`, so the committed one is trustworthy. Assembled with the
  `0001`–`0005` baseline and with `0006` applied: objects byte-identical
  (`ad81e290…`), and not a null test — the two tcc binaries themselves differ. `.eh_frame`
  carries `A` and `.debug_frame` is correctly non-ALLOC in gcc, baseline and patched alike.
  Full `luajit` binaries (gcc for C, tcc for the `.S`, since tcc cannot compile LuaJIT's C at
  all — see the scope correction above) are byte-identical and run identically: JIT engaging on
  a hot loop, error unwinding back through a JIT-compiled frame via `pcall` with error-object
  identity preserved, ffi calls, an ffi callback through `qsort`, plus a coroutine/GC/metatable
  stress pass. **Stated plainly: `0006` is a linker patch, so `tcc -c` barely exercises it —
  the identical objects partly reflect that rather than proving the linker changes correct.**
  The test that does exercise it is tcc-as-linker, where baseline and patched binaries differ
  by exactly one added section, `.debug_frame` (precisely `0006`'s retention behaviour, and
  nothing else), with identical runtime output. That test is weakened by the pre-existing defect
  in the next entry, so: no-regression is well supported; a positive proof of the linker changes
  under a fully working tcc-linked LuaJIT was not obtainable in this environment.

- [ ] **Pre-existing, NOT caused by `0006`: a tcc-LINKED luajit breaks `pcall` entirely with
  `PANIC: unprotected error in call to Lua API`.** Found while verifying `0006`. Not
  JIT-related — reproduces with `-joff` and on a bare
  `pcall(function() error("e1") end)`. Not the missing `-Wl,-E` either: adding
  `-Wl,-E -rdynamic` does not help, and `PT_GNU_EH_FRAME`/`.eh_frame_hdr` are both present in
  the output, so the cause is further in. A gcc-linked control built from the same objects
  passes the same script. **Baseline and `0006` fail byte-identically**, so this is not a
  regression from the patch — but it does mean tcc-as-linker is not currently viable for
  LuaJIT, independently of the `__TINYC__` compile blocker. Also note tcc does not pull the
  unwinder in by itself: the link needs an explicit `-lgcc_s` or it fails on `_Unwind_GetIP`,
  `__register_frame` and friends. Root cause not investigated; needs its own scoped pass.

- [ ] **Known gap, deliberately not fixed in `0006`: tcc cannot decompress `SHF_COMPRESSED`
  debug sections, and skips debug retention for an entire object if ANY section in it is
  compressed.** Modern gcc compresses debug sections by default (`-gz=zlib`), so the retention
  above is close to a no-op against typical real-world gcc output — it only helps for objects
  built with `-gz=none` or equivalent. Verified directly: a `gcc -gz=zlib` object retains 0
  debug sections (no error, silently skipped) while the same source with `-gz=none` retains 6.
  This is a real capability gap, not a correctness bug; closing it means adding decompression,
  which is new capability and was explicitly ruled out of scope for `0006`. Until then this
  should be described as "retains uncompressed debug sections correctly", never as "debug
  section retention works".

- [ ] **Known gap, deliberately not fixed in `0006`: a merged foreign `.stab` section
  hard-errors under `-gdwarf` when sections land at high addresses (e.g. `-run`), with
  `relocation 'R_X86_64_32[S]' out of range`.** Found while scoping `0006`; same class as the
  `.debug_types` bug it fixes, but `.stab` is not `.debug_*` so the `is_dwarf` fix does not
  cover it. `x86_64-link.c:228-230` suppresses that error only for addresses inside tcc's OWN
  `stab_section`, which is NULL under `-gdwarf` (`tccdbg.c:495` only creates it in stabs mode),
  so the guard short-circuits to "always error". Reproduced with a hand-built foreign `.stab`
  object (gas 2.44 ICEs on `.stab` directly, so it was assembled under a different name and
  renamed with `objcopy --rename-section`): `-gstabs` works, `-g0` works, `-gdwarf` errors.
  **Owner's call (2026-08-16): do NOT extend the suppression to foreign `.stab` sections — a
  loud error beats silent wrong debug data.** The suppression only silences the diagnostic; the
  truncated value is written regardless (`add32le` runs unconditionally), and `Stab_Sym.n_value`
  is `unsigned int` (`tcc.h:1543`), so unlike the dwarf case there is no correct 32-bit value
  for a high address — truncation is lossy by construction. That is why `.stab` was NOT unified
  into `is_dwarf`: its three legacy special cases (out-of-range suppression in
  `x86_64-link.c:228`, dynamic relocations dropped at `tccelf.c:1176`, `.stabstr` excluded from
  strtab ordering at `tccelf.c:2279`) share a trigger but not a concept, and none of them is the
  `is_dwarf` concept. For the same reason `.stab` is explicitly excluded from `0006`'s retention
  change: retaining a foreign `.stab` without `-g` was measured to turn the currently-working
  `-g0` case into this hard error.

- [ ] **Vestigial after `0006`: `tccdbg.c` eagerly creates seven empty `.debug_*` sections
  (`.debug_macro`, `.debug_loc`, `.debug_ranges`, `.debug_loclists`, `.debug_rnglists`,
  `.debug_str_offsets`, `.debug_addr`) that tcc itself never writes.** Their original and only
  purpose was to make a merged foreign section of the same name land inside the `dwlo..dwhi`
  index range; `Section->is_dwarf` now classifies by name, so that reason is gone. They were
  kept deliberately, because dropping them changes which (empty) section headers appear in the
  output and would break `0006`'s byte-identity verification. Removing them is a separate,
  output-affecting change that needs its own before/after comparison — not a cleanup to fold
  into an unrelated patch.

- [x] **RESOLVED by `0007` (2026-08-16): unifying the ~20 out-of-band
  `TCCState` section pointers behind a by-name resolver.** The intended shape is known — a
  name-keyed table of `{name, expected type, expected flags, field offset}`, one uniform loop,
  error-on-mismatch, covering sections a foreign producer can name via `.section` or object
  merge (so: `.text`/`.data`/`.rodata`/`.bss`/`.bounds`/`.lbounds`/`.got`/`.plt`/`.eh_frame`/
  `.eh_frame_hdr`/`.stab`/`.stabstr`/the six `dwarf_*_section` pointers/`.tcov`/`.gnu.version`/
  `.gnu.version_r`/`.pdata`), excluding `SHF_PRIVATE` sections (`.common`) and the structurally
  wired `symtab`/`dynsym`/`shstrtab`. What is NOT decided, and what blocks implementation: does
  the resolver **create** these sections (replacing the ~20 scattered `new_section()` calls) or
  **validate/rebind** the pointers when a foreign `.section` directive or object merge names
  one? The two readings have very different blast radii — the creating reading changes section
  creation ORDER, which determines ELF section indices and output layout, so a single uniform
  creation loop cannot reproduce tcc's current interleaving (`.text`/`.data`/`.rodata`/`.bss`
  first, then symtab, then debug sections only under `-g`, then `.got`/`.plt` on demand) without
  ceasing to be uniform. An exhaustive search (crescent git history including all commit bodies,
  every repo under `~/git/rhizone/`, the ecosystem open-threads registry, all handoff docs, all
  session transcripts, all branches/stashes/worktrees) found NO written record of this direction
  anywhere — it was carried only in conversation. Recorded here as open rather than settled;
  picking a reading unilaterally would mint semantics later work would trust.
  **Resolution (owner, 2026-08-16), implemented as
  `dep/tcc/patches/0007-reserved-section-gate-and-eh-frame-retention.patch`:** the two readings
  are not alternatives — it is one mechanism with a class-dependent outcome. `reserved_section()`
  (tccelf.c) does the name lookup at every internal creation site (the *creating* reading); what
  happens ON A HIT is what varies by role class (the *validate/rebind* reading):
  `SECTION_ROLE_SHARED` binds and upgrades, `SECTION_ROLE_PRIVATE` errors. The
  creation-ORDER objection above dissolves because there is no single uniform creation loop —
  each existing `new_section()` call site keeps its place and simply routes through the gate, so
  tcc's current interleaving is preserved exactly. The one ordering change in `0007` is
  deliberate and unrelated to the resolver: `.eh_frame` moved from session-start to
  first-FDE (see the next entry). Container roles were left alone entirely, since they are
  created before any input and cannot race.

- [x] **`0007` verification: the orphan-CIE bug is fixed and `lj_vm.S`'s `.eh_frame` is now
  byte-identical to GNU `as`.** Reproduced the bug first rather than trusting the report:
  `lj_vm.S`, regenerated fresh via `buildvm` (not the committed copy), carries its own
  `.section .eh_frame` with a hand-written CIE. Baseline (`0001`–`0006`) tcc produced a
  144-byte `.eh_frame`; GNU `as` produces 120; the extra 24 bytes are tcc's own CIE, emitted
  unconditionally at session start and sitting in front of LuaJIT's records —
  `readelf --debug-dump=frames` on the baseline object shows it plainly as a CIE at offset 0.
  With `0007` the section is 120 bytes and byte-identical to `as`, with `.text` identical across
  all three. A LuaJIT linked from that tcc-assembled VM (gcc for the C, per the standing scope
  correction that tcc cannot compile LuaJIT's C at all) passes JIT trace compilation on a hot
  loop, ffi calls/structs/buffers, `pcall` unwinding, 200-deep recursion unwinding, coroutines
  and a GC/string-churn pass. Also verified: the same spurious `.eh_frame` disappears from five
  of libressl's perlasm objects, matching `as`, and the other two still fail identically on the
  documented `%xmm8` gap. tcc's own suite reaches the identical stage (baseline and patched both
  stop at `test3` on a pre-existing, environmental `exponent digits expected`), and
  `abitest`/`btest`/`dlltest`/`vla_test-run`/`asm-c-connect-test`/`asmtest2`/`weaktest`/`test4`
  each have identical pass/fail against baseline.

- [x] **`0007` fixes a real hard link failure, not just an output-quality bug: input `.eh_frame`
  is now retained unconditionally.** `tcc_load_object_file()` dropped any input `.eh_frame`
  whenever `s1->eh_frame_section == NULL`, conflating "should tcc generate unwind info"
  (`-f[no-]asynchronous-unwind-tables`) with "should unwind info in a linked object survive the
  link". Reproduced directly: an object with a relocation into its own `.eh_frame`, linked with
  `-fno-asynchronous-unwind-tables`, failed with
  `Invalid relocation entry [ 2] '.rela.text' @ 00000003`; the same link succeeds with unwind
  generation on. After `0007` it links, runs, and retains the section. The BSD targets already
  retained unconditionally, so the change is a deletion of the non-BSD-only guard rather than
  new behaviour. Rejected alternatives are recorded in `docs/native-tiers.md`; the accepted cost
  is a few hundred bytes of inert `.eh_frame`-named data on PE/mach-o, which use
  `.pdata`/`.xdata` and `__TEXT,__eh_frame` instead.

- [ ] **Known consequence of `0007`, not a defect: `tcc -c` output is no longer byte-identical
  to the `0006` baseline for inputs that produce both `.eh_frame` and relocation sections.**
  `.eh_frame` is created at the first FDE now instead of at session start, so it lands later in
  the section table (index 7 → 8 for `tcc -c m.c`, swapping with `.rela.text`). Every section's
  CONTENTS are byte-identical — verified per-section on `m.c` and on `dep/sqlite3/sqlite3.c`
  (object identical in size to the byte, every section digest equal). This is inherent, not an
  implementation choice: tcc emits zero-size sections (`.data`/`.bss` come out size 0 for
  pure-asm input), so creating `.eh_frame` eagerly and deferring only its bytes would still
  leave an empty `.eh_frame` in the output, which is the exact thing being fixed. Recorded so
  that future byte-identity comparisons against pre-`0007` artifacts are not read as regressions.

- [x] **RESOLVED by `dep/tcc/patches/0009-reserved-section-input-side-gate.patch` (2026-08-21):
  the asymmetry `0007` left open — the reserved-section gate only protected a role when input
  named the section BEFORE tcc's internal creator ran.** Re-derived from source rather than
  taken from this entry, and reproduced first against a local `0001`–`0008` build: with
  `-ftest-coverage` (so `.tcov` exists before any object is merged) both an input object
  carrying `.tcov` and an `__asm__(".section .tcov")` linked with exit 0 and no diagnostic,
  while the same names in the opposite order were refused. Two input-side reuse sites, not one:
  `tcc_load_object_file()`'s by-name merge loop, and the assembler's `.section`/`.pushsection`
  via `find_section()` — the entry's own repro was the second of those, so gating only the
  merge loop would have left the observed symptom in place.
  **Shape:** shared substrate, not a parallel mechanism. `Section->internal_role` now stores
  WHICH role a section was created for (`SECTION_ROLE_NONE`/`SHARED`/`PRIVATE`) instead of
  `0007`'s bare "has a role" bit, and `reserved_section_claim()` reads that role back on the
  input side; it and `reserved_section()` raise the identical diagnostic through one helper, so
  both orderings are indistinguishable to a caller. `SHARED` still merges input content
  unchanged, so `.eh_frame`/dwarf coexistence is untouched, and the `.symtab` family stays
  `SHARED` per the standing owner decision (GNU `as` does not protect it either) — so that
  half is deliberately still unprotected, not overlooked.
  **Scope note (property of creation order, not of the policy):** `.tcov` is the only role
  reachable in this ordering today; every other `PRIVATE` role is created during
  `elf_output_file()`, after all input is merged. The gate keys on the role, not the name, so a
  role that later starts being created earlier is covered without revisiting this.
  **Verified:** `0009-tests/run.sh` — 10 pass patched, 3 fail on the `0001`–`0008` baseline (the
  three orderings fixed); `0005`/`0006`/`0007` harnesses identical on both (9/10/18 passing);
  tcc's `make test` byte-identical, stopping at the same pre-existing environmental `test3`
  failure, and the eight individually-run targets identical; objects byte-identical across
  `sqlite3.c`/`tccelf.c`/`.S` under `-g`, `-gdwarf-5`, `-ftest-coverage`,
  `-fno-asynchronous-unwind-tables`; a freshly `buildvm`-generated `lj_vm.S` assembles
  byte-identically and the LuaJIT linked from it passes trace compilation, ffi, unwinding,
  coroutines and GC churn against an all-gcc control; libressl's seven perlasm objects hold the
  recorded baseline exactly with no new diagnostic; `0008`'s `PT_GNU_STACK`/`dlopen` unchanged.
  Wired into all 5 `dep/tcc/patches` apply steps in `build-vendored.yml`, `SOURCE_SHA256`
  regenerated, reasoning recorded in `docs/native-tiers.md`.

- [x] **Fixed (`dep/tcc/patches/0008-pt-gnu-stack.patch`): tcc-built `.so` files failed to
  `dlopen` on modern glibc because tcc's linker never emitted a `PT_GNU_STACK` program
  header at all.** Root cause confirmed by reading upstream tinycc's full git history
  (`repo.or.cz/tinycc.git`, all branches): `PT_GNU_STACK` is defined in `elf.h` but never
  referenced anywhere in `layout_sections()`/`elf_output_file()` on any commit — a
  long-standing upstream gap, not a regression from `0001`–`0007` and not something already
  partially handled (the one `.note.GNU-stack` mention in `tccelf.c` is unrelated: it only
  dedups a doubled input `.note.GNU-stack` *section* when merging `crt1.o`, and never fed
  into program-header emission). glibc ≥2.41's dynamic loader reads the missing header as
  "this object wants an executable stack" and refuses to load it on hardened configs
  (reproduced locally: `cannot enable executable stack as shared object requires: Invalid
  argument`, NixOS glibc 2.42). Fix: `layout_sections()` now unconditionally emits a
  `PT_GNU_STACK` phdr with `PF_R | PF_W` (no `PF_X`) for every EXE/DLL link — matching the
  non-executable-by-default stance gcc/clang/binutils ld/lld already take, and safe because
  tcc generates no code that needs an executable stack (no nested-function trampolines).
  Verified via a genuine musl/Alpine test (docker, not documentation-only reasoning): musl's
  `dlopen()` does NOT enforce this even with the header fully absent (unpatched tcc's
  `.so` loads fine there), and the patched tcc still builds and `dlopen`s/`dlsym`s cleanly
  under both glibc (NixOS 2.42) and musl (Alpine) — no regression on either libc. Also ran
  `dep/tcc/patches/0007-tests/run.sh` against both patched and unpatched local builds; results
  were identical on both (some pre-existing local-environment-only failures — NixOS's `ld.so`
  stub for directly-executed binaries, a fake `--sysroot` needed to build tcc at all on this
  sandbox — confirmed unrelated to this patch by reproducing them against an unpatched build
  too). Wired into all 5 `dep/tcc/patches` apply steps in `build-vendored.yml` and
  `dep/tcc/SOURCE_SHA256` regenerated to include the new patch file.
  **Separately noticed while verifying, NOT fixed here (out of this patch's scope, needs its
  own investigation):** `git apply dep/tcc/patches/0001-*.patch ... 0007-*.patch` fails
  (`patch failed: dep/tcc/tccasm.c:45`) on a fresh clone of current `origin/master`, before
  any of my changes — i.e. `0001`–`0007` do not currently reapply cleanly from a clean
  checkout via a plain `git apply`, independent of build-vendored.yml's CI environment. My
  new `0008` patch applies cleanly standalone and was verified in isolation; the pre-existing
  `0001`–`0007` failure needs its own root-cause pass (patch/context drift vs. some CI-only
  applying mechanism) before relying on `git apply` locally to reproduce the full patch stack.

## Typechecker substrate gaps (found while implementing lib/os_isolation/, 2026-08-14)

- [ ] **An `ffi.new(...)`-typed module-level local's cdata element type only resolves concretely, file-wide, once at least one UNANNOTATED (inference/synthesis-mode) function in the same file has called an `ffi.C.*` member — a `--:`-annotated (checking-mode) function whose own body is the FIRST `ffi.C.*` call in the file leaves that cdata typed `?` for the rest of the file, including inside `ffi.string(buf, n)` calls in OTHER functions.** Confirmed via repeated minimal repros (see session transcript): a `--: (integer, integer|nil) -> (string|nil, string|nil)`-annotated function whose body is the first thing in the file to touch `ffi.C.read`/`ffi.C.close` leaves `ffi.string(buf, len)` erroring `cannot pass ? where integer & { [0]: integer } expected` on `buf` — even though `buf` is a plain `local buf = ffi.new("char[65536]")` with no cast at all. Adding one extra, textually EARLIER, UNANNOTATED function that calls any `ffi.C.*` member (its body's own content is irrelevant — confirmed with a no-op `ffi.C.close(fd)` and, separately, an unrelated `ffi.C.read` probe call) makes every later annotated function's `ffi.string`/cdata usage resolve correctly, file-wide, regardless of ordering after that point. Root cause not diagnosed beyond "checking-mode suppresses whatever bidirectional cdata-element-type elaboration synthesis-mode performs against `$FfiC`, and that elaboration is a global one-time-per-file effect once it fires." Worked around in `lib/os_isolation/fork_direct.lua`, `fork_supervisor.lua`, `supervisor_main.lua`, and `thread.lua` via a `-- TYPECHECKER WORKAROUND:`-labeled unannotated local `_prime(fd)` (or `_prime(L)` in `thread.lua`) function defined immediately after each file's `ffi.cdef` block and called at every `ffi.C.close`/`ffi.C.lua_close` site (both a working priming mechanism AND, incidentally, real cleanup code, so it isn't pure dead weight) — but the ordering dependency itself, and the fact that a purely STATIC (never-called) unannotated function definition alone was sufficient to fix it in isolated repros, indicates a genuine elaboration-order bug, not an intended API. Revert `_prime` back to plain `ffi.C.close`/`ffi.C.lua_close` calls (removing the workaround function and its call sites) once this ordering dependency is fixed, keeping each file's public functions `--:`-annotated as originally intended.

## `interrupt_ptrace.lua` against `thread.lua` — root cause found, permanent (2026-08-14)

- [x] **Diagnosed why `interrupt_ptrace.suspend()` fails with `EPERM` against a `thread.lua` unit's own tid: it is an unconditional Linux kernel restriction, not an environment/config issue, and not fixable from crescent's side.** Linux's `kernel/ptrace.c` `ptrace_attach()` (backing both `PTRACE_ATTACH` and `PTRACE_SEIZE`) contains `if (same_thread_group(task, current)) return -EPERM;` ahead of the `__ptrace_may_access()` permission helper — a thread can never `ptrace`-attach a sibling thread in its own thread group, on any kernel, at any privilege level, in any environment. This is separate from the `ptrace(2)`-documented "always allowed" same-thread-group exemption, which describes only the `__ptrace_may_access()` helper (also used for `/proc` access checks), not the attach syscall's own additional, earlier, unconditional guard. Verified via (1) reading the actual kernel source for `ptrace_attach()`, (2) a bare-C reproduction with no Lua/FFI involved (pthread sibling obtains its own tid via raw `syscall(SYS_gettid)`; main thread's `PTRACE_SEIZE` against it fails `EPERM` every time, confirmed via `strace`), (3) a control reproduction confirming real parent-process→child-process `ptrace` succeeds with no special privilege (the `fork_direct`/`fork_supervisor` case), and (4) a second control confirming a genuinely separate forked process attempting the same sibling-thread tid is independently denied by Yama's `ptrace_scope` (`1` on the investigating machine) — a distinct, config-dependent EPERM cause, correctly NOT conflated with the unconditional one in the fix. Also ruled out: this machine is not containerized (no `/.dockerenv`, host `init.scope` cgroup, `Seccomp: 0`), and `thread.lua` already captures the real kernel tid via `syscall(SYS_gettid)`, not `pthread_self()` (no pid/tid-vs-pthread_t confusion in the Lua code). Fixed: `lib/os_isolation/interrupt_ptrace.lua`'s module header and `errno_suffix()` EPERM note, `lib/os_isolation/thread.lua`'s module header, and `docs/genre-battery/sandboxing.md` (Decided-direction mechanism-(b) bullet, `interrupt_ptrace.lua`'s Implemented entry, and the now-resolved "Still genuinely open" bullet) all corrected from "environment-dependent, verify in your deployment target" to the accurate "permanently impossible for this specific pairing, no deployment/config knob fixes it." `interrupt_ptrace_test.lua` updated to assert the `EPERM` deterministically instead of treating it as an unpredictable environment-dependent skip case.
- [ ] **Not implemented, left as an explicit open direction, not a bug**: the only way `ptrace`-based suspend could ever apply to a `thread.lua` unit is a genuinely separate OS process acting as tracer (never the process that spawned the thread) — which then falls under ordinary cross-process `ptrace` permission rules (Yama `ptrace_scope`, `CAP_SYS_PTRACE`) this module already handles correctly for `fork_direct`/`fork_supervisor` pids. That is a different architecture (a dedicated tracer-process helper spawned via `fork_direct`/`fork_supervisor` specifically to supervise a sibling process's threads), not a fix to `interrupt_ptrace.lua` itself, and would need its own design pass (how the tracer process learns which threads to target, how results/signals get back to the caller) before being built.

- [ ] **ESCALATION (2026-08-14), supersedes/deepens the entry directly above — the `_prime` workaround does not fix a cosmetic `?`-display bug, it silently disables real `ffi.C.*` argument type-checking for the rest of the file, which is a soundness regression, not a workaround.** Root-caused via minimal repro (no `ffi.new`/`CTypeMap` involved at all, contrary to the original entry's framing):
  ```lua
  local ffi = require("ffi")
  ffi.cdef[[ int read(int fd, void *buf, unsigned long count); int close(int fd); ]]
  local function _prime(fd) return ffi.C.close(fd) end   -- unannotated, earlier in file
  --: (integer) -> integer
  local function read_it(fd)
    local n = ffi.C.read("not an fd", nil, 8192)          -- string where cdef says `int fd`
    return n
  end
  ```
  Without `_prime`: correctly rejected (`cannot pass "not an fd" where integer expected`). With `_prime` present (unchanged otherwise): **0 errors** — the string-for-integer-fd argument is silently accepted. Dumping `ctx.type_at` (via `check_mod.check_string` + `types_mod.display` on every recorded `(line, col, tid)`, see session transcript for the throwaway script) shows why: with `_prime` present, the *shared type variable* for the single `local ffi = require("ffi")` binding resolves file-wide (including retroactively at the `ffi.cdef(...)` call on line 3, textually before `_prime` is even defined) to a loose, structurally-inferred open table `{ C: { close: _ } }` — i.e. `ffi` never gets bound to the rich `--:: module "ffi": {...}` declaration from `stdlib_types.lua` at all, so `ffi.C.read`'s callee type is an unconstrained fresh var (`_`) instead of the cdef-derived `(integer, any, integer) -> integer`, and nothing about the call is checked. Without `_prime`, the same variable resolves correctly to the full declared module type and `ffi.C.read`'s callee shows the correct cdef-derived signature. This is **not** general to all `require()`'d modules — the identical shape (unannotated function touches a member of a required module before an annotated function uses it more precisely) does NOT reproduce with `require("bit")` (confirmed: `bit.band("nope", x)` is still correctly rejected regardless of an earlier unannotated `bit.bnot(x)` call) — it is specific to `$FfiC`/`TAG_FFIC` (the singleton-per-compilation-unit type in `lib/type/static/defs.lua`/`solve.lua`'s `resolve_ffic`) and how it interacts with whatever mechanism processes UNANNOTATED (inference-mode) local function bodies relative to a shared outer-scope binding (letrec generalization / closure environment capture in `lib/type/static/env.lua`'s `instantiate`/generalize path is the most likely site, but this was not pinned down to a specific line — the investigation confirmed the *symptom and trigger precisely* but did not complete a fix-ready root-cause diagnosis of the generalization mechanism itself). **Escalating rather than fixing**: this sits in core HM-inference/closure-generalization machinery (`lib/type/static/env.lua`, `solve.lua`), touching how every unannotated local function's captured outer bindings get processed — high blast radius, exactly the class of core-infra change CLAUDE.md says to escalate rather than rush. **Do not remove the `_prime` workaround** until this is fixed — removing it without a fix reintroduces the original `?`-error entry above, and the workaround (despite being unsound in the way described here) is currently the only thing letting `lib/os_isolation/*.lua` typecheck at all. **Action needed before this can close**: (1) a real fix to the generalization/instantiation path so an unannotated function referencing a required module's field does not collapse that module's binding to a loose inferred shape file-wide, and (2) a manual audit of `lib/os_isolation/fork_direct.lua`, `fork_supervisor.lua`, `supervisor_main.lua`, `thread.lua`'s `ffi.C.*` call sites against their `ffi.cdef` signatures, since typechecking has not actually been verifying argument types at those call sites since the workaround was introduced in `43fbd27c`.

## lib/os_isolation/thread.lua open safety question — follow-up (2026-08-14)

- [ ] **Re-vendor LuaJIT to pick up the `LuaJIT/LuaJIT#1498` fix.** This
  repo's vendored `bin/luajit-bin` (built by
  `.github/workflows/build-vendored.yml`, tracking the `v2.1` branch, last
  updated 2026-07-25 per commit `c651bc4e`) predates the fix for
  [LuaJIT/LuaJIT#1498](https://github.com/LuaJIT/LuaJIT/issues/1498) ("FFI
  callback invoked from C leaves `cur_L` stale — crash in `lj_trace_exit`
  when the compiled callback takes a trace exit," merged 2026-08-01) by
  about a week. `thread.lua`'s own code shape was analyzed and shown NOT to
  hit this bug's precondition (see `thread.lua`'s module header and
  `docs/genre-battery/sandboxing.md`'s `thread.lua` note) — but the fix is
  still a straightforwardly good pickup given how structurally close the
  bug is to this module's mechanism (an FFI callback invoked with no Lua
  frame active, on a thread the VM didn't just enter through). Re-running
  the workflow re-vendors LuaJIT + sqlite3 + zlib + libressl + wepoll
  together across every supported platform in one shot — a repo-wide
  infrastructure change, left here as an explicit recommendation rather
  than done unilaterally during the investigation that found this.
- [ ] **`LuaJIT/LuaJIT#1506`, "`store to dead GC object` in FFI callback,"
  is still open upstream as of 2026-08-14** — a different GC-liveness
  mechanism than `#1498` (an FFI-visible-only callback with no Lua-side
  anchor getting collected out from under a live C pointer to it), not
  analyzed against `thread.lua`'s specific shape to the same depth as
  `#1498` was. `thread.lua`'s BOOTSTRAP chunk keeps its callback anchored
  via the Lua-level `cb` local for the bootstrap pcall's duration and hands
  only the raw pointer (not the cdata) to `pthread_create`, which differs
  from `#1506`'s repro (a callback stored only behind a C global, never a
  Lua variable) — but this difference has not been checked with the same
  rigor as the `#1498` analysis. Revisit once `#1506` is resolved upstream,
  or sooner if someone wants to do the same depth of structural analysis
  against it that `#1498` got.

## Typechecker substrate gaps (found while implementing lib/type/v10_toy/{init,w,v10_toy_test}.lua, 2026-08-11)

- [ ] **For a self-recursive discriminated union (a variant whose own field type is `T[]`/`{[K]:T[]}` referencing the alias `T` being defined), assignability of ANY value against `T` only ever checks the union's FIRST declared arm — never the others, regardless of the value's actual `kind`/discriminant, and regardless of cast strategy.** Confirmed via multiple minimal repros outside `lib/type/v10_toy/`: (1) reading a self-recursive field off an already-narrowed variant (e.g. `node.premises: Node[]` after `node.kind == "rule"`) infers `never`, independent of branch order/position (`if`/`elseif` positive or negated, first or later branch) — a checked cast on the FIELD READ (`node.premises --[[: Node[] ]]`) recovers the real type fine, since that's a normal (non-recursive-union-target) cast. (2) Assigning or returning a freshly-constructed table literal, or a named local built from one, AS the recursive union type itself (not reading a field FROM it) is checked ONLY against the first-declared arm — reordering the union's arms changes which ONE shape passes, never more than one at a time; even routing the value through `unknown` first and casting `unknown -> T` still only accepts the first arm. Force casts are separately rejected outright ("fix the upstream type annotation instead"), and even `--[[:! T]]` on the exact same value reports "force cast has no overlap" between the literal's inferred shape and the union's first arm specifically. (3) The ONE construct that reliably works for passing a differently-shaped value INTO a parameter typed as the self-recursive union: widen the constructing local to `unknown` at its declaration (`local n = {...} --[[: unknown]]`), then narrow with a bare `type(n) == "table"` check (no further cast) immediately before use/passing — a value narrowed only to plain `table` (not `unknown`, not a concrete literal shape) is NOT checked structurally against the union at all and is accepted regardless of which arm it actually is at runtime. Worked around throughout `lib/type/v10_toy/` (`init.lua`'s `replay_node`/`M.replay`, `w.lua`'s `rule_node`/`axiom_node`/`emit`/`M.infer`, `v10_toy_test.lua`'s hand-built derivation nodes) by: giving `Node`-touching functions `unknown` where their signature would otherwise need the recursive union in a position other than "value already known to be `Node`, being read structurally"; and threading every externally-constructed node through a `type(x) == "table"` guard before use. This is a broad, escalation-worthy gap (recursive discriminated unions are an ordinary, expected pattern — ASTs, certificate/derivation trees, JSON-like values) — related to, but structurally distinct from, the array-element narrowing gap and the `[unknown]`-keyed-map gap already on record above (2026-07-28 entries): those are about narrowing an already-correctly-typed union value; this one is about the union type itself refusing to accept any shape but its first arm as a target, which is a strictly more basic failure (constructing/assigning, not narrowing-after-construction).
- [ ] **An annotated-but-uninitialized local (`local x --: T`) requires `T` to include `nil` even when every branch of the immediately-following code unconditionally assigns before any read — no definite-assignment analysis.** Minimal repro: `local result --: R` (R a 2-arm discriminated union) followed by an if/elseif/else where every arm assigns `result`, then `return result` — rejected with "requires an initializer because `nil` is not in type R". Worked around throughout `lib/type/v10_toy/` by giving these locals a real (always-overwritten-before-use) initializer instead of widening the annotation to `T | nil`, which would just relocate the same non-null obligation to every later read site instead of removing it.
- [ ] **A multi-return function typed `T | (nil, string)` (this repo's standard error-return convention) does not narrow via a truthy check (`if x then ... end` / `if not x then return end`) at ANY call site — including a fresh call, a call whose result is stored then checked, and the boolean-literal-discriminant form (`{ok:true,...}|{ok:false,...}` checked via `if r.ok then`)** — the truthy/falsy branch keeps the full union type, `nil` included, in the "success" arm. `type(x) == "table"` (or, for the `ok`-discriminant case, `r.ok == true` plus a per-field checked cast) narrows correctly every time this was tried instead. This shows up identically whether the union came from `require`-crossing a module boundary or a plain in-file local function, and whether the "error" arm's second value is `nil` explicitly or just untyped from a return path that doesn't provide it — see `lib/type/v10_toy/init.lua`'s `M.match`/`M.instantiate`/`M.replay`/`replay_node` and `lib/type/v10_toy/w.lua`'s `unify`/`infer`/`walk` for many instances of the workaround. Plausibly the same root cause as the two `docs/typechecker-v2`-adjacent "positional multi-return union" entries already on record for `lib/type/v10_kernel/pilot/prover.lua` (2026-07-28), but confirmed independently here via multiple isolated minimal repros with no recursive types involved, so recorded separately in case the root causes turn out to differ.
- [ ] **`require("local.module.path")`'s result types as `unknown`, with no annotation-level way found (within this experiment's own constraint of not reading `docs/type-system.md`/`docs/typechecker-reference.md`) to give it a declared type** — indexing the required module's table (`C.op`, even just `C.foo`) errors "value of type `unknown` must be narrowed before indexing" immediately after `require`, a plain checked cast on the require result errors "must be narrowed before use", and a force cast on it is rejected outright by the checker itself ("force cast — fix the upstream type annotation instead; see CLAUDE.md") — there IS clearly an intended mechanism for this (CLAUDE.md references a `$Require<T>` intrinsic used via "explicit stdlib declarations"), but its concrete syntax wasn't discovered without reading the withheld docs. Worked around in every `lib/type/v10_toy/` file that requires a sibling file by narrowing the require result once via `type(C_raw) == "table"` then a single checked cast to a hand-written interface type covering only the fields actually used. Fine as a workaround, but means genuinely typed cross-module `require` for LOCAL (non-stdlib) modules could not be made to work as presumably intended; revisit once the `$Require<T>` declaration syntax is known, and check whether it's simply undiscoverable without reading the docs this experiment deliberately avoided, or a genuine gap.

## Open bugs

- [ ] **`lib/api-tree/http_route.lua` duplicates two constants that belong to the unported `decode.ts` (2026-08-08):** The wire-time source-coverage check needs the HTTP store-name registry (`BUILTIN_HTTP_STORE_NAMES` — `path`, `query`, `header`, `body`, `caller`) and the primary-store-by-method convention (`primaryStoreForMethod` — GET/HEAD/DELETE read `query`, everything else `body`). On the TypeScript side both live in `packages/http-api-projector/src/decode.ts` and are IMPORTED by `route.ts`. `decode.ts` has no crescent port yet, so `http_route.lua` carries its own copies, deliberately module-PRIVATE so nothing downstream can come to depend on this file as their home. When the decode port lands, it should own both outright and `http_route.lua` should require them from there — that is the one direction the TypeScript already establishes, and it creates no cycle (the cycle `route.ts` avoids is with `project.ts`, not `decode.ts`). Until then the duplication is real: adding a store to one copy and not the other makes the coverage check disagree with the decoder it is checking.

- [ ] **RFC 9112 §6.2: `lib/http/format`'s `serialize_response` synthesizes `content-length: 0` on a 204 (2026-08-04):** Found while porting fractal's JSON-RPC projector (`lib/api-tree/jsonrpc_server.lua`), whose HTTP transport answers 204 No Content for a Notification or an all-Notification batch (§6). RFC 9112 §6.2: "A server MUST NOT send a Content-Length header field in any response with a status code of 1xx (Informational) or 204 (No Content)." `serialize_response` synthesizes one for every bodyless response, with no status exemption, so every 204 any handler in this repo produces carries the forbidden field. The fix belongs in the serializer (skip synthesis for 1xx/204, and 304 by the same clause), not in each handler: the alternatives available at the handler are worse — `mod.response_stream` writes a head with no content-length but then owns the socket and must close it, which would drop keep-alive for every notification-only request. Not fixed in the porting commit because it changes shared HTTP behavior for every consumer of `serialize_response`; it is a substrate decision, not a projector one. `lib/api-tree/jsonrpc_server.lua`'s `http_handler_from_tree` doc references this entry.

- [ ] **`lib/type-ir/json_rpc.lua` is a deliberately partial port of type-ir's `json-rpc.ts` (2026-08-04):** Ported: the standard error codes (§5.1) and `error_schema_from_data_schema` (`jsonRpcErrorSchema`), which is all the framework-layer projector needs for error framing. Not ported: `toJsonRpcMethod`/`toJsonRpcMethods` — the TypeRef lowering that turns an `interface` TypeRef into per-method params/result/error schemas, including the `stream`-kind return-type handling that sets `streaming` and describes ONE element. That half belongs with the rest of the `type_ref_*` projection family and depends on `type_ref_json_schema.lua`'s `type_ref_to_json_schema`. Nothing consumes it yet: `jsonrpc_project.lua` reads a caller-supplied `SchemaMap`, exactly as the TypeScript framework layer does. Finish the file when a caller needs schemas derived from a TypeRef rather than handed in.

- [ ] **Typechecker: narrowing facts are keyed by variable NAME, not by binding — a same-named local in an unrelated scope poisons narrowing file-wide (2026-08-04):** Found while building `lib/api-tree/stream.lua`. Minimal repro (checks with 1 spurious error; delete the `outer` function and it checks clean):
  ```lua
  --: (v: unknown) -> v is { data: unknown }
  local function is_boxed(v) return type(v) == "table" end

  --: (produce: () -> unknown) -> nil
  local function outer(produce)
    local wrapped = function()
      local ok, value = pcall(produce)
      _ = ok
      _ = value
    end
    wrapped()
  end

  --: (value: unknown) -> unknown
  local function read(value)
    if is_boxed(value) then return value.data end   -- "value of type `unknown` must be narrowed before indexing"
    return nil
  end
  ```
  The `value` bound by `local ok, value = pcall(...)` inside the unannotated inner closure and the `value` parameter of `read` are entirely unrelated bindings in disjoint scopes, but the first one's un-narrowable `unknown` suppresses the narrowing predicate at the second. Renaming either binding fixes it. **Worked around** in `lib/api-tree/stream.lua` by naming the producer's pcall result `outcome` instead of the natural `value` (flagged in-file as `TYPECHECKER WORKAROUND`). Revert that rename once narrowing facts are keyed by binding. Belongs to `lib/type/static/`'s narrowing environment.

- [ ] **Typechecker: a trailing `--: T` on the CLOSING line of a multi-line table constructor is mis-associated (2026-08-04):** Found while building `lib/api-tree/stream.lua`. `local st = { a = false, b = nil } --: S` (one line) checks clean; the identical annotation written as `} --: S` at the end of a multi-line constructor is not applied to the local, and every later field assignment is then checked against the whole table type instead of the field's — e.g. `st.b = "x"` reports ``cannot assign `"x"` to `{ a: boolean, b: unknown }`: string has no field `a` ``. The preceding-line form (`--: S` on its own line above `local st = {`) and the inline cast form (`} --[[: S]]`) both check clean. This is a placement bug, not a shape one. **Worked around** in `lib/api-tree/stream.lua` by putting the `StreamState` annotation on the preceding line (flagged in-file as `TYPECHECKER WORKAROUND`); restore the repo-standard trailing form once the association is fixed. Note `lib/async/init.lua`'s `co_box` uses the broken trailing form today and is only unaffected because nothing assigns to its fields afterwards.

- [ ] **`lib/html` doesn't typecheck for its own intended usage (2026-07-30):** No file in the repo consumes `lib/html` (`grep -rl 'require("lib.html")' lib/ | grep -v /html/` returns nothing) -- it has never had a real caller. Two independent problems, found while building `lib/platform/apps/finance/dom.lua` (this app's web frontend): (1) `lib/html/init.lua` itself fails `bin/cr check` at HEAD with 75 pre-existing errors, nearly all `force cast — fix the upstream type annotation instead` on the file's own `--[[:! Element<T, A>]]` casts (every `M.div`/`M.span`/`M.a`/etc. definition at the bottom of the file) -- written against a looser force-cast enforcement that no longer holds, never revisited since. (2) Independently of (1), ordinary *nested* composition -- exactly what `lib/html/html_test.lua` never exercises (it only checks leaf elements in isolation, never e.g. `h.html(...)` containing `h.head(...)` containing `h.title(...)`) -- fails on the consumer side too. Minimal repro: `h.html({ lang = "en", h.head({ h.title("hi") }), h.body({ h.div({ class = "x" }, h.p("hello")) }) })` produces `nominal type TitleElement is not assignable to MetaElement | LinkElement | ScriptElement | StyleElement | TitleElement` -- a value of a type literally listed in a union failing to satisfy that same union once it's inside a table literal passed to a `{ [integer]: ... }`-typed parameter. Per owner decision (2026-07-30), `dom.lua` ships today using plain string-template HTML (with `h.escape` for user data) instead of `lib/html`'s nested element builders, specifically to avoid the force-cast-everywhere workaround the current state would otherwise require. Migrating `dom.lua` to `lib/html` once these are fixed is expected to be a straightforward refactor, not a redesign -- but the fix itself (the `Element<Content, Attrs>` nominal-union machinery, plus lib/html/init.lua's own internal force casts) is unscoped and belongs to `lib/html`/the typechecker, not to this app.

- [ ] **No cap surfaces terminal dimensions for sandboxed TUI apps (2026-07-30):** `lib/tui/init.lua`'s `M.size` gets real terminal geometry via FFI `ioctl` (TIOCGWINSZ) or `COLUMNS`/`LINES` env vars, both unreachable from inside the platform sandbox (`os`/`ffi` are both absent per `lib/platform/CLAUDE.md`'s "Sandbox is the security boundary", and the cap taxonomy has no env/tty primitive -- `cli` only exposes argv). `lib/platform/apps/finance/tui.lua`'s `M.create` passes a stub `no_env` (always returns nil) to `tui.size`, which sends it to its documented 80x24 fallback -- functional, but every sandboxed TUI app is stuck at a fixed size regardless of the real terminal. Fix requires a new primitive cap (e.g. `tty`/`terminal` surfacing `COLUMNS`/`LINES`, or a narrow `getenv` cap) -- not something to invent ad hoc inside one app.

- [ ] **Cross-period journal entry id collision (2026-07-30):** `lib/bookkeeping/store.lua`'s schema declares `journal_entries.id TEXT PRIMARY KEY` — unique across the *entire* table, not scoped per `period_id`. But `lib/bookkeeping/journal.lua`'s auto-id assignment (`journal._next_id`, used whenever `M.post` is called without an explicit `id`) is scoped to a single in-memory `journal` instance, and `store.load_period` constructs a fresh `journal` per period — so every period's auto-id counter restarts at `"1"`. The first auto-assigned entry in any period after the first one collides with an existing entry `"1"` and the insert fails with `UNIQUE constraint failed: journal_entries.id`. Reproduced via `lib/platform/apps/finance/bridge.lua`'s new `M.list_entries` test (`lib/platform/apps/finance/bridge_test.lua`, "list_entries spans multiple periods" — currently `T.skip`-ped, pointing here). Affects any real multi-period usage of `bridge.post_entry`/`journal.post` without caller-supplied ids, not just that test. Not fixed here: the fix requires a real design call (derive the next id from a cross-period `SELECT MAX`/`COUNT` at insert time instead of per-journal state; or make the SQL primary key a composite `(period_id, id)` and update every query/FK that assumes bare `id` uniqueness, including `journal_lines.entry_id REFERENCES journal_entries(id)`; or namespace auto-ids by period, e.g. `"<period_id>:<n>"`) — each has different downstream consequences (schema migration, wire format, FK integrity) and belongs to `lib/bookkeeping/journal.lua`/`lib/bookkeeping/store.lua`, not to the finance app layer that surfaced it.

- [ ] **Typechecker: `--::` type visibility breaks across a two-hop require + annotated-function trigger (2026-07-30):** Found while building `lib/type/v10_kernel/pilot/fixpoint_prover_test.lua`. Minimal repro: a file that requires ONLY `lib/type/v10_kernel/pilot/fixpoint_prover.lua` (which itself requires `term_algebra.lua`/`replayer.lua`/`fixpoint_v1.lua`, declaring `Term`/`AxiomDecl`/`RuleDecl`/`Replayer`/`ReplayResult`/`FixpointVocab`) checks clean UNTIL that file also contains any `--:` ANNOTATED local function — even one whose own signature references NONE of those types (e.g. `--: (unknown, string) -> integer`). Adding such an annotation causes `bin/cr check` to report `undefined type Term`/`AxiomDecl`/etc. AGAINST `fixpoint_prover.lua` itself (which checks 0-errors standalone) — i.e. the presence of an annotated function in the REQUIRING file changes how the REQUIRED file's own dependencies resolve. Directly requiring `term_algebra`/`replayer`/etc. in the requiring file does NOT fix it (tried). Worked around in `fixpoint_prover_test.lua` by leaving its `--:`-signature-free (the `skip_count` lookup is inlined at each call site instead of factored into an annotated local helper) — matching `prover_narrow_test.lua`'s own pre-existing unannotated-local-helper accommodation for (presumably) the same underlying class of issue. Not investigated further (typechecker-internals territory, not this milestone's scope) — belongs to `lib/type/static/constrain.lua`'s cross-file type-declaration collection.

- [ ] **`fixpoint_prover.lua` (v10 pilot, Phase 3) does not attempt `assign-copy-transfer` at all (2026-07-30):** Neither self-copy (`x = x`) nor a copy from a genuinely different tracked variable is certified — every bare-identifier-copy RHS targeting a loop's invariant variable is a counted skip ("copy source not independently established at the assign point"), regardless of whether the source is itself tracked. Two separate reasons, both recorded in `fixpoint_prover.lua`'s own header ("Known scope reduction"): (1) self-copy needs `holds_at(Pa,X,T)` at the SAME `Pa` as its own conclusion (`Pa = exit_of(the statement's own path)`, per the corrected addressing convention in `prover_addr.lua`'s header) — under this convention that premise is not reachable via `seq-persist` from the pre-statement fact, since `stmt_preserves` requires the statement's target list NOT include `X`, and self-copy's does. The Phase 2 hand-built test (`fixpoint_v1_test.lua`) closes this same shape using a different, now-superseded addressing choice (its own header flags this: "not tied to prover_addr.lua's real conventions") that does not transfer to the corrected convention. (2) A copy from a different tracked variable `Y` would need `Y`'s own fact independently chained forward through the same body prefix (grounded in its own `pilot-initial-facts-v1` citation at `LH`), in parallel with `X`'s own chain — buildable in principle, not attempted under time pressure, no required test exercises it. Both are reported as open design questions rather than resolved unilaterally, per the halt discipline — resolving (1) needs an owner call on whether a different addressing convention specifically for self-copy is acceptable (it would depart from the uniform `Pa = exit_of(own path)` rule); (2) is pure unimplemented generality.

- [ ] **Typechecker: a named-key write to an index-signature-typed table adds that key to the index-signature TYPE as a required field, poisoning every such type in the file (2026-08-04):** Found while porting `lib/ffi-ir/init.lua`. Minimal repro, no project dependencies:

  ```lua
  --:: Meta = { [string]: unknown }
  --:: Disc = { kind: "copy" } | { kind: "refcount" }
  --: (m: Meta, d: Disc) -> Meta
  local function with_ownership(m, d)
      local out = {} --: Meta
      for k, v in pairs(m) do out[k] = v end
      out.ownership = d
      return out
  end
  ```

  → `cannot assign {} to { ownership: ..., [string]: unknown }: missing field 'ownership'` at the `local out = {} --: Meta` line. Writing `out.ownership` REFINES `Meta` itself, so the empty-table initializer of the very same variable no longer satisfies it. The pollution is not per-variable and not per-alias: a second function in the same file writing `out.provenance` makes BOTH functions' initializers demand BOTH keys, and an inline `--: { [string]: unknown }` annotation instead of the named alias is polluted identically — i.e. every structurally-equal index-signature type in the file is one shared, mutable object. A computed key (`out["ownership"]`) fails the same way. Building an open metadata bag by writing named keys is the single most ordinary use of an index signature, so this is broad, not a corner case. **Worked around** in `lib/ffi-ir/init.lua` by routing every write through a `--: (meta: Meta, key: string, value: unknown) -> Meta` `assign` helper, so the key is a `string` parameter and never a literal at the write site (same shape as the pre-existing `assign` helper in `lib/type-ir/json_schema.lua`, which is presumably there for this same reason). Revert to direct field writes and delete those helpers once fixed.

- [ ] **Typechecker: an alias imported via `require` stops resolving — and silently degrades to `any` — inside the importing module's own `--::` declarations as soon as any consumer uses that module (2026-08-04):** Found while porting `lib/ffi-ir/init.lua`; likely the same root cause as the 2026-07-30 "`--::` type visibility breaks across a two-hop require" entry above, but with a much smaller repro. `lib/ffi-ir/init.lua` requires `lib.type-ir` for its `TypeRef`/`Meta` aliases and declares e.g. `--:: FfiParam = { name: string, type: TypeRef }`. It checks **0 errors standalone**. Any consumer breaks it:

  ```lua
  local ffi_ir = require("lib.ffi-ir")
  --: (s: unknown) -> unknown
  local function pick(s) return (s --[[: FfiModuleShape]]).name end
  ```

  → `lib/ffi-ir/init.lua:263: undefined type 'TypeRef'` + `type contains 'any' — use 'unknown' ...`, reported against the *dependency's* line numbers. The checker re-resolves the required module's `--::` declarations in the CONSUMER's scope, where the dependency's own imports are not bound. The `any` degradation is the dangerous part — an imported alias silently becomes `any` rather than erroring at its declaration, which is exactly what the no-`any` rule exists to prevent. Casting to inline structural types on the consumer side does NOT avoid it: the trigger is the signature of any function the consumer calls, not the consumer's own casts, so no consumer-side formulation works. **Worked around** in `lib/ffi-ir/init.lua` (and repeated in each `lib/ffi-ir/*.lua` backend) by re-declaring `Meta`/`TypeShape`/`TypeRef` verbatim alongside the `require` — a deliberate, documented violation of "Never duplicate type definitions", flagged in-file as `TYPECHECKER WORKAROUND`, and the only formulation found that lets both the module and its consumers check clean. Delete every one of those re-declarations once imported aliases resolve through a consumer.

- [ ] **Typechecker: a second read of an imported tagged union's discriminant, after narrowing on that same discriminant, is typed `never` (2026-08-04):** Found while porting `lib/ffi-ir/wit.lua`. A union imported through `require` (`ffi_ir.ownership_of` returns `OwnershipDiscipline | nil`) narrows correctly for ONE `kind` test; testing the residual value's `kind` again collapses it to `never`, so the value cannot be used (here: concatenated into an error message naming the unsupported discipline). Minimal repro, run from the repo root so the `require` resolves:

  ```lua
  local ffi_ir = require("lib.ffi-ir")
  --:: Meta = { [string]: unknown }
  --:: TypeShape = { kind: string, ... }
  --:: TypeRef = { shape: TypeShape, meta: Meta }
  --: (ref: TypeRef) -> string
  local function f(ref)
      local d = ffi_ir.ownership_of(ref)
      if d ~= nil then
          local k = d.kind
          if k == "opaque-handle" or k == "refcount" then return "bad " .. k end
      end
      return "copy"
  end
  ```

  → `cannot concatenate type 'never'` at `.. k`. A locally-declared union of the same four member types narrows correctly through the identical code, so the collapse is specific to the union arriving across a `require` — likely the same family as the two entries above. **Worked around** in `lib/ffi-ir/wit.lua`'s `to_wit_type` by reading the discriminant through an open structural cast (`(discipline --[[: { kind: string, ... }]]).kind`) — the same structural-field-read `ffi_ir.ownership_of` uses internally — so the value is a plain `string` at every use. Note the workaround gives up exhaustiveness checking on the union, which is exactly what a discriminant read should provide. Revert to `discipline.kind` once repeated discriminant reads narrow correctly across a require.

- [ ] **Other libraries still carry private null sentinels now that `lib/null` exists (2026-08-03):** `lib/null` was created (2026-08-03) because `lib/format/json/{pure,ffi}.lua` already did `pcall(require, "lib.null")` and fell back to a private `{}` — a module referenced but never written. Both now use the shared table, so the two JSON tiers' output is mutually recognizable. Several other libraries still mint their own: `lib/json/init.lua:20`, `lib/jsonschema/init.lua:24`, `lib/bson/init.lua:35`, `lib/y_crdt/encoding.lua:60` (and `lib/pdf/object.lua:77`'s `pdf.null`, which is arguably a PDF-domain object rather than the generic sentinel and may belong outside any migration). Consequence today: a value decoded as null by one of these is NOT `== ` any other's null, so passing decoded data between them silently misreads nulls as ordinary tables. Not migrated here because it is a real design call, not a mechanical sweep: several of these attach a `__tostring` metatable naming the owning module (useful in errors, lost if they share one table), and `lib/json` vs `lib/format/json` are two separate JSON libraries whose relationship is its own open question. Needs an owner decision on whether the generic sentinel is repo-wide vocabulary that every format library adopts, or whether per-format sentinels are deliberate.

- [ ] **Typechecker: a local REASSIGNED inside a conditional branch is typed `nil` at any later use as a METHOD-CALL RECEIVER (found while porting `lib/ffi-ir/rescript_external.lua`, 2026-08-04):** The natural spelling of "conditionally rewrite a string, then test the result" — the exact formulation `type_ref_rescript_native.lua`'s own `sanitize_label` uses — fails with `cannot call value of type 'nil'` at the second method call. Minimal repro (no project dependencies, no aliasing, literal initializer):

    ```lua
    --: (name: string) -> string
    local function a(name)
        local lowered = "y"
        if name:match("^[A-Z]") ~= nil then lowered = "x" end
        if lowered:match("^[a-z_]") ~= nil then return lowered end
        return "_" .. lowered
    end
    ```

  → `cannot call value of type 'nil'` at `lowered:match`. Only the method-call RECEIVER position is affected: using the same reassigned local in a concatenation (`return lowered .. "!"`) checks clean, which is why other conditionally-reassigned locals in the same file (`attr`, `type_decl`) needed no change. Note `sanitize_label` in `lib/type-ir/rescript_native.lua` passes today with the natural formulation, but extracted verbatim into a standalone file it fails — so something in that file's surrounding context suppresses it and the real trigger is narrower than the repro alone shows. **Worked around** in `lib/ffi-ir/rescript_external.lua`'s `external_ident` by hoisting the conditional rewrite into a separate `decapitalize_leading_upper` function (returning the input unchanged on the non-matching path) and spelling the `_`-prefix decision with two returns instead of a reassignment, flagged in-file as `TYPECHECKER WORKAROUND`. Collapse it back into one function with the reassignment once a conditionally-reassigned local keeps its type at a method-call receiver.

- [ ] **A parenthesized `gsub` call in ARGUMENT position is not truncated to one value (same port, 2026-08-04):** `f((name:gsub(pat, rep)))` is rejected with "argument 1: cannot pass `(string, integer)` where `string` expected", although the identical expression in a `local x = (name:gsub(...))` binding types as `string`. Lua's parentheses truncate a multi-value expression to one value in every position, so argument position should behave the same as binding position. Worked around in `lib/ffi-ir/rescript_external.lua`'s `external_ident` by binding to a `local` first and passing the local. Not separately flagged in-file (the binding reads naturally either way); revert the extra local once parentheses truncate in argument position.

## Strategic decisions

- **Rescribe fixture alignment (2026-07-26):** Crescent's format libraries will eventually be tested against rescribe's cross-language fixture suite. This is high-value for conformance but not immediately urgent — rescribe's format crates are still in progress. Approach: pick this up per-format as format work comes up in crescent, rather than as a dedicated alignment project. Documented in `docs/roadmap-v2.md`, "Strategic direction: Rescribe fixture alignment" section.

## v10 corroboration proof-of-concept: spine-mediated composition, first evidence (2026-08-09)

Built the first genuinely spine-mediated cross-theory composition, per
`docs/decisions/typechecker-v10-core-design.md`'s "Corroboration
proof-of-concept: spine-mediated composition, first evidence" section
(fable-delegation-tier). New files, all under `lib/type/v10_kernel/pilot/`:
`effects_spine_v1.lua` (layer-owned `preserves(from,to,x)` spine judgment,
importing `point`/`path` from `addr-v1`), `assign_effects_v1.lua` (the
effects theory: its own signature, one reality-boundary axiom, one grounding
rule, one pure transitivity rule), `narrow_persist_v1.lua` (the composition
wiring — one rule, `narrow-persist`, needing NO new signature at all, citing
narrowing's existing `narrow-pilot-v1` v1 and the new spine as ordinary
premises), `prover_effects.lua` (a fresh, narrow real-AST walker deriving the
composed judgment from real source). Corrects the existing pilot's own
`narrow-pilot-v1` precedent (which grew narrowing's and the fixpoint theory's
vocabulary inside one jointly-version-bumped signature — pairwise coupling by
another name) without modifying or retracting it.

Three-leg proof (`narrow_persist_v1_test.lua`, certificate level): (a)
narrowing alone is fail-closed — no certificate rooted in a registry lacking
the effects theory can produce a closed `preserves` fact (foreign citation
rejected; hypothesis-based attempt leaves an undischarged open hypothesis);
(b) with the effects theory, `narrow-persist` derives `holds_at` at a later
point neither theory reaches alone, root-strict, taint naming exactly the
axioms trusted; (c) scale-to-zero asserted structurally — registry (a) is
registry (b) minus the one call to `assign_effects_v1.declare_vocabulary`.
Real-file corroboration (`prover_effects_test.lua`): scanning all 569
`lib/*/init.lua` files found exactly one naturally-occurring match,
`lib/table_ext/init.lua`'s `M.flatten` (`depth == nil` guard, then-branch
assigns to a different local `depth_`) — low incidence is a scope-of-
demonstration fact (the walker only attempts single-clause `if` with a
first-statement safety check), not a claim about the architecture. 32 pilot
files batch-typecheck clean; 459 assertions across 13 test files, zero
regressions in the 9 pre-existing ones.

- [ ] **`prover_effects.lua`'s real-source walker scope is deliberately
  narrow (single-clause `if` only, first-branch-statement safety check
  only, one composition hop):** extending it (elseif chains, chained
  `preserves-trans` hops across multiple statements, table-field-aware
  preservation once an aliasing theory exists) would raise real-corpus
  incidence beyond the one confirmed instance — future work, not a gap in
  what the three-leg proof already establishes at the certificate level.
  **Partly closed (2026-08-09, iteration 3 phase 2/4):** `prover_effects.lua`
  is retired; `extractor_v1.lua` + the engine reproduce its result on
  `lib/table_ext/init.lua` exactly (same guard, same composed judgment, same
  taint) and generalize it — every clause of an elseif chain, and whole
  statement chains rather than one first statement. Still open in this item:
  table-field-aware preservation (needs an aliasing theory, which does not
  exist), and rest-branch/`else` reach, which is blocked by the branch-role
  HALT recorded in the core design doc's phase-2 section.

## v10 canon swap executed: cleanroom core canonical, old kernel core retired (2026-07-29)

**Executed the owner-ratified canon swap** (`docs/decisions/typechecker-v10-core-design.md`,
"Canon swap: cleanroom core"; evidence: `docs/typechecker-v10-parity-adjudication.md`,
7 A-side bug classes vs F4/F7/F8/F10/F11/F12/F13, zero cleanroom-side):
`lib/type/v10_cleanroom/` is the canonical v10 core; `lib/type/v10_kernel/term_algebra/`
and `lib/type/v10_kernel/replayer/` (including the fast tier) are removed (git history
preserves them). Dependents ported meaning-preserved onto the canonical API
(`theories/hm.lua`, `algorithm_w.lua`, `algorithm_j.lua`, `discharge_scope_test.lua`,
and the whole `pilot/`), conforming to the canonical core's stricter semantics
(registries with per-registry (name, version) uniqueness — F11; node-identity
hypotheses/discharge — F8; plain ground closed axiom bindings — F12; plain-table
certificates validated only at replay). The four flow-narrow theory tests that
inspect deliberately-open derivations go through the owner-ratified read-only
observation entry point (`rl.observe`, ratified in commit `8b2a4483`, implemented
in `lib/type/v10_cleanroom/replayer.lua`). The adjudicator's untested list is
closed as required canonical-suite tests
(`lib/type/v10_cleanroom/adjudication_untested_test.lua`: deep F9,
declare-time validation fuzz, metavariable-in-subject fuzz, an
independently-derived DAG divergent-discharge case).

- [ ] **Rebuild the fast tier against the canonical core** (separate,
  axiom-carrying effort per the canon-swap ratification; axiom names unchanged:
  `kernel-interner-sound` / `kernel-lazy-subst-sound`). The retired
  `term_algebra/fast.lua` was built against the old core's internals and retired
  with it — do NOT resurrect it by porting; rebuild against
  `lib/type/v10_cleanroom/term_algebra.lua` as the reference, with the repo's
  standing multiple-implementation discipline (parity tests, parity fuzzing,
  benchmarks to `docs/perf/log.md`). Prior art that carries over: the retired
  tier's perf investigation and the OPEN lazy-subst design question in the
  "v10 kernel term algebra (2026-07-27)" section below (chained-substitution
  regression; thunk-of-thunk composition; workload-dependence measurements) —
  that design question must be answered (or explicitly re-scoped by the owner)
  as part of this rebuild, not rediscovered.

## Typechecker substrate gaps (found while implementing lib/type/v10_kernel/replayer/replay.lua, 2026-07-28)

- [ ] **Indexing a `{ [unknown]: T }`-shaped map with a key narrowed only to `table` (not a primitive) infers `any` at the read site, even with an explicit checked cast (`--[[: T | nil]]`) immediately on that same read.** Minimal repro shape: `memo` typed `{ [unknown]: MemoEntry }`, `node` narrowed via `type(node) == "table"` (never further to a specific record shape, since certificate nodes are a tagged union read generically); `local cached = memo[node] --[[: MemoEntry | nil ]]` still warns "inference fell back to `any` — narrow the source type or annotate to avoid the firewall" at the `memo[node]` subexpression itself, despite the enclosing `local` already carrying the intended cast. `[unknown]`-keyed maps are the correct shape here (both `memo` and the cycle-detection `visiting` set are keyed by certificate-node **table identity**, deliberately, so shared DAG nodes memoize once — there is no primitive id to key by instead). Worked around in `lib/type/v10_kernel/replayer/replay.lua` (`replay_node`) by accepting the warning (0 errors, checker still passes) rather than restructuring node identity around a synthetic string/integer id, which would be a correctness-irrelevant workaround forced onto the data model. Revisit once `[unknown]`-keyed map reads narrow via an explicit read-site cast the same way `[string]`/`[integer]`-keyed map reads already do. **SUPERSEDED IN SITE, GAP STILL OPEN (2026-07-29 canon swap):** the worked-around site (`lib/type/v10_kernel/replayer/replay.lua`) was retired with the old core; the canonical replayer hit the same class of limitation and worked around it differently (parallel-array memo — see the "Revert TYPECHECKER WORKAROUND in `lib/type/v10_cleanroom/replayer.lua`" item near the end of this file). The underlying checker gap is unchanged; this entry's repro remains valid.

## Typechecker substrate gaps (found while implementing lib/type/v10_kernel/pilot/prover.lua, 2026-07-28)

- [ ] **Discriminated-union narrowing on a literal `kind` field (the documented, normally-working pattern — `docs/type-system.md` / `lib/type/static/CLAUDE.md` "Discriminated unions require literal discriminants") does not resolve for a union-typed ARRAY ELEMENT obtained via indexing or `ipairs` iteration.** Minimal repro: `--:: A = {kind:"a", x:integer}`, `--:: B = {kind:"b", y:string}`, `--:: U = A|B`; a function taking `U` directly and checking `u.kind=="a"` then reading `u.x` typechecks cleanly, but the identical check/read on `events[1]` (or a `for _, ev in ipairs(events) do ev.kind==... end` loop variable) leaves every field access `T | nil` regardless of the check. Worked around in `lib/type/v10_kernel/pilot/prover.lua` (`Event` type's header comment, `emit_events`, `peek_next_target`) by typing sub-event-list fields `unknown[]` instead of `Event[]` and re-narrowing each element inside the loop via `type(ev_raw) == "table"` + a checked cast to `Event` — the natural code would type these fields `Event[]` directly with no per-element cast. Revisit once array-element narrowing on a discriminated union matches direct-variable narrowing.
- [ ] **A plain `T | nil`-typed local, populated via a conditional multi-value assignment (`local a, b; if cond then a,b=x,y else a,b=z,w end`), does not narrow away `nil` under a truthy check (`if a then ... end`) even after reassignment to a fresh local immediately before the check — but DOES narrow correctly under an explicit `type(a) == "table"` check.** Found in `lib/type/v10_kernel/pilot/prover.lua`'s `emit_events` (`match_path`/`rest_path`/`match_events`/`rest_events`, populated from `then_is_match and ge.then_path or ge.else_path`-shaped conditionals). A minimal repro isolating just this behavior (independent of the array-element gap above) could not be constructed in the time available — every attempted reduction narrowed correctly in isolation, so the interaction trigger is still unidentified. Worked around by using `type(x) == "table"` in place of the bare truthy check at every affected site. Revisit once isolated, or once the array-element gap above is fixed (may be the same root cause). **UPDATE (2026-07-29 canon swap):** `prover.lua` was ported onto the canonical core; both workarounds in this section carry over into the ported file (the `Event`/`unknown[]` re-narrowing unchanged; the conditional-multi-assignment sites restructured into nested single-condition guards over directly-assigned fresh locals, which narrow reliably — the underlying gaps remain open).

## lib/type/v10_kernel/: theories ported onto the ratified core, prototype kernel retired (2026-07-28)

**SUPERSEDED (2026-07-29): the "ratified core" this section ported onto —
`lib/type/v10_kernel/term_algebra/` + `replayer/` — has itself been retired by
the owner-ratified canon swap (see the "v10 canon swap executed" section at the
top of this file); the theories were re-ported onto the canonical
`lib/type/v10_cleanroom/` core. This section's porting findings (two-pass
construction, hypothesis-as-premise, DAG-shared variable references, concrete
base-type operators) remain valid and carry over unchanged in meaning.**

**Conformance task completed:** the two theory entries described in the
section immediately below (`theories/algorithm_w.lua`,
`theories/algorithm_j.lua`) have been ported onto the ratified
`docs/decisions/typechecker-v10-core-design.md` term algebra + replayer
(`lib/type/v10_kernel/term_algebra/`, `lib/type/v10_kernel/replayer/`), and
the section's own trust core — `kernel.lua`, `registry.lua` — has been
removed (git history preserves it; ported-not-lost). New: `theories/hm.lua`
(shared judgment vocabulary + rule/axiom schemas both theories build
against), `theories/algorithm_w_test.lua` (26 assertions),
`theories/algorithm_j_test.lua` (22 assertions),
`theories/discharge_scope_test.lua` (30 assertions, replacing the retired
`kernel_discharge_scope_test.lua`). `lib/type/v10_kernel/init.lua`,
`README.md`, `NOTATION.md` updated to describe the current module set — see
`NOTATION.md`'s "Port notes" section for the full correspondence between the
retired grammar and the ratified one. No expressiveness gap was hit
requiring owner escalation; every translation difference (two-pass
certificate construction instead of inline emission, a discharged
hypothesis cited as an explicit rule premise instead of an out-of-band
payload, no wrapping rule needed for a bare variable reference, two
concrete base-type operators instead of one polymorphic `con(name)`) is
accounted for by primitives the ratified design already provides
(schematic axioms, non-linear metavariables shared across premises,
DAG-shared certificate nodes) — see `README.md`'s and `NOTATION.md`'s "port
notes" for detail, including two places (App's argument/domain consistency;
discharge-pattern matching) where the new core structurally verifies more
than the retired prototype's opaque-payload design ever could. This also
resolves this section's own "**RESOLVED (2026-07-27, partially...)**" item's
open half below (ancestor-scoped discharge is superseded by the ratified
core's own, differently-formulated but verified-equivalent, per-parent DAG
discharge mechanism — see `theories/discharge_scope_test.lua`) and the
"design-sync PAUSED" section further below (superseded by
`docs/decisions/typechecker-v10-core-charter.md` +
`typechecker-v10-core-design.md`, both already ratified and built against
before this task started).

## lib/type/v10_kernel/: v10 trust-core prototype, RETIRED — ported above (2026-07-27)

Built an exploratory, dinner-sized prototype of the "v10" typechecker
architecture's trust core: `lib/type/v10_kernel/registry.lua` (theory
registry, shape-only validation), `lib/type/v10_kernel/kernel.lua` (a
domain-blind certificate replayer — citation validity, rule instantiation,
well-foundedness, hypothesis discharge), and `lib/type/v10_kernel/w.lua`
(Algorithm W, the founding theory-registry entry, an untrusted producer that
emits certificates). `lib/type/v10_kernel/kernel_test.lua` (14 assertions)
demonstrates a valid certificate replaying with zero kernel knowledge of W's
semantics, three independently tampered certificates each failing replay
(forged citation, well-foundedness cycle, skipped hypothesis discharge), and
W's own documented weakness (no let-generalization, so a let-bound
polymorphic function's type variable pins at its first call site) rejecting
a program a real let-polymorphic checker would accept — shown, not fixed.
`NOTATION.md` documents the certificate/rule-schema grammar; `README.md`
records the choices made and their rationale. This is **not** a production
module — it tests whether the validate-only-kernel / untrusted-registry-entry
shape from `docs/decisions/typechecker-v10-proposal.md` (the proposal + its
in-session critical evaluation, not yet ratified) holds together at all;
this prototype does not restate that design conversation.

**Second theory entry added (2026-07-27): Algorithm J**
(`lib/type/v10_kernel/theories/algorithm_j.lua`,
`lib/type/v10_kernel/algorithm_j_test.lua`, 14 more assertions). Same
Damas-Milner algorithm as W, in its classic imperative reformulation
(mutable ref cells + union-find-style mutation instead of W's functional
substitution map) — built specifically to stress-test registry/kernel
genericity against a structurally different producer. **Finding: zero
changes to `kernel.lua` or `registry.lua` were needed.** J registers zero
new rule schemas — it reuses `algorithm_w.lua`'s exported `RULES` table
verbatim into its own separately-scoped registry, since W and J derive the
literal same judgment. See README.md's "Algorithm J: the genericity
finding" section and NOTATION.md for the full writeup. J's let-binding
deliberately does not generalize either (matches W on purpose, so the two
are comparable on the same known weakness, not accidentally divergent).

Deliberately out of scope (not attempted, not silently papered over):
- [ ] **Algorithm-neutral rule-schema names.** Because
  `algorithm_j.lua` reuses `algorithm_w.lua`'s rule schemas verbatim (see
  above), J's certificates cite rules literally named `W-Lit`, `W-Var`,
  etc. — cosmetically odd for a J-derived certificate, since the `W-`
  prefix no longer means "specific to Algorithm W." Renaming to neutral
  names (e.g. `HM-Lit`) would fix this but touches `algorithm_w.lua`'s
  already-committed names and `kernel_test.lua`'s existing by-name lookups;
  judged out of scope for the Algorithm J entry itself.
- [ ] **Theory-registry soundness-of-schema verification beyond shape
  validity.** `registry.register` checks a schema's own structure only; a
  registrant's claim that its rule is sound is taken on faith, same as the
  rejected `lib/type/framework/` design's stated non-goal.
- [ ] **Corroboration / cross-theory citation** — a certificate citing rules
  from more than one registered theory, or a kernel replay that spans
  theories. `kernel.replay` takes exactly one registry and rejects a
  certificate whose `theory` field doesn't match it.
- [x] **Evidence-grammar alpha-stability, binder-identity, and
  capture-avoidance**, carried over unresolved from the rejected
  `lib/type/framework/` attempt (see
  `docs/typechecker-framework-postmortem.md`). This prototype's hypothesis-
  discharge check is stated plainly as an id-match-in-reachable-set
  simplification (see `NOTATION.md`), not a scoped/lexical-ancestry check —
  a certificate could in principle discharge a hypothesis on an unrelated
  branch and this kernel would accept it. Building this properly is
  exactly the machinery `framework/` spent most of its complexity on before
  being rejected on non-technical grounds; if v10 proceeds past prototype,
  this is the first real design debt to resolve.
  **RESOLVED (2026-07-27, partially — the ancestor-scoping half only):**
  `kernel.lua`'s `check_discharge` now requires a hypothesis's discharging
  node to be an ANCESTOR of the assuming node — present on every
  root-to-node path through `premises` — not merely present anywhere in the
  reachable set. Implemented as a topological-order pass computing, per
  node, the intersection (across all incoming `premises` edges) of each
  parent's own ancestor-discharge set unioned with that parent's own
  `discharges`; a plain tree is the one-parent special case where the
  intersection is trivial. `premises` is now explicitly documented as a DAG
  (a node may be a shared premise of more than one parent), a deliberate
  generalization with zero effect on any certificate either W or J emits
  today (neither producer ever shares a node), decided when this exact
  scoping question was raised mid-implementation. See `NOTATION.md`'s
  "Discharge scoping" section and `kernel.lua`'s header for the corrected
  semantics, and `kernel_discharge_scope_test.lua` for the sibling-branch,
  DAG-accepted, and DAG-rejected cases this closes. Ancestor-path scoping
  was the whole ask here; alpha-equivalence, shadowing, and
  capture-avoiding substitution proper remain unimplemented and are a
  separate, still-open piece of the original `framework/`-sized machinery
  — not reopened as a new item since they were never this item's scope
  beyond the id-match-anywhere flaw, which is what's fixed.
  **FURTHER RESOLVED (2026-07-27, binder-identity and alpha-stability
  portions only — capture-avoidance-as-a-checked-condition remains
  explicitly OPEN):** both theory entries (`theories/algorithm_w.lua`,
  `theories/algorithm_j.lua`) now represent lambda terms with de Bruijn
  indices instead of named string binders, with a purely cosmetic display
  name riding alongside each index/binder for readability only (never used
  for lookup or any identity-relevant comparison). This closes Lesson 1
  (binder identity is lexical position by construction — there is no name
  to compare) and Lesson 3 (alpha-equivalent terms are byte-identical de
  Bruijn terms, so digesting is free) STRUCTURALLY rather than by the prior
  implementation accident (Lua's metatable-chained environment happening to
  resolve innermost-first). Lesson 2 (capture-avoidance must be a CHECKED
  condition, never assumed) is only PARTIALLY narrowed by this change: de
  Bruijn shift/subst is capture-avoiding by construction of one correct
  algorithm, but the kernel trusts no producer's code (W/J are untrusted
  producers `kernel.lua` never runs), and nothing here replays or verifies
  that either producer's `infer` actually implements that correct
  algorithm — a checked, kernel-replayed capture-avoidance condition remains
  unbuilt. Do not read this as closing Lesson 2. See `NOTATION.md`'s "Term
  binder representation: de Bruijn indices" section and README.md's "De
  Bruijn indices: standardizing term binders" section for the full
  writeup. Unification and type-level machinery (`unify`/`resolve`/
  `deep_resolve`/`show_type` in W; the mutable-cell/union-find analogues in
  J) were untouched — confirmed to operate purely on `WType`/`JType`, not
  term binders. `kernel.lua`/`registry.lua` needed zero changes (both
  already treat certificate payloads as fully opaque). All 38 existing
  assertions across `kernel_test.lua`, `algorithm_j_test.lua`, and
  `kernel_discharge_scope_test.lua` still pass — this was a representation
  change, not a behavior change.

Typechecker substrate gap found while building this (worked around, not
silently avoided):
- [ ] **Concatenating (`..`) a table field whose value's type resolves
  through a *different module's* `--:: require`-imported type alias reports
  the field as type `never` at the point of concatenation only** — plain
  field access, assignment to a local, `print`, and `return` of the exact
  same value all typecheck fine; only the `..` operator on it fails.
  Reproduces with a minimal two-file case: module A declares
  `--:: Schema = { name: string, ... }` and a `lookup(name) -> Schema | nil`
  function; module B does `--:: require "A"`, calls `lookup`, guards
  `if not schema then return end`, assigns `local n = schema.name`, then
  fails only on `"x " .. n` (not on `local n = schema.name` or `return n`
  alone). Confirmed independent of parameter order and of whether a second
  local type alias is declared in module B. Worked around throughout
  `lib/type/v10_kernel/kernel.lua` by re-casting each field into a freshly
  checked local (`local schema_name = schema.name --[[: string]]`) before
  any concatenation — a checked cast, not a force cast, so it costs nothing
  in soundness, only in each field needing one extra annotated line. Revert
  (drop the `--[[: T]]` re-casts) once cross-module field types survive
  `..` the same way same-module field types already do.

## v10 typechecker: PAUSED pending design sync with external collaborator (2026-07-27)

**SUPERSEDED (2026-07-28): the design sync this section paused on has since
happened and produced two ratified decision docs —
`docs/decisions/typechecker-v10-core-charter.md` (cleanroom discipline +
scope) and `docs/decisions/typechecker-v10-core-design.md` (the term
algebra + replayer design itself, resolving open items 1 and 2 below and
scheduling 3-6 as campaign tasks).** `lib/type/v10_kernel/term_algebra/` and
`lib/type/v10_kernel/replayer/` were built fresh against that ratified
design (cleanroom, per the charter), and the section-above prototype's two
theory entries have since been ported onto it, with the prototype's own
`kernel.lua`/`registry.lua` retired — see the dated section above this
one ("theories ported onto the ratified core, prototype kernel retired").
This section's original pause instruction and the six-item gating list
below are kept as historical record of what the sync needed to resolve, not
current status.

**Stated explicitly by the project owner this session (2026-07-27, now
historical — see the supersession note just above): no further
implementation on `lib/type/v10_kernel/` until the conceptual/architectural
model is fully synced with an external collaborator referred to as
"fable."** This gated everything in the section above at the time — treat
that section's prototype as frozen, not a base to build further on, until
this synced.

Three decision docs now exist in `docs/decisions/`:
`typechecker-version-history.md` (why 8 prior typechecker rewrites — v4, v5,
v6, v7/framework, v9, toy_checker, declc — all failed; reconstructed from
git history and session transcripts since CLAUDE.md's "v1→v4 failure" line
was otherwise undocumented in one place), `typechecker-v10-proposal.md` (the
v10 architecture proposal plus a critical evaluation against that graveyard
record), and `typechecker-v10-design-sync.md` (a later round of design
refinement, conducted partly with fable, covering the prefix-as-declared-
citable-object architecture, the kernel-performative gap and its proposed
generic-content-checking-primitives resolution, and a proposed-but-unbuilt
axiom/taint mechanism for tracked, non-silent unsoundness).

`typechecker-v10-design-sync.md` closes with six explicit open items —
gating state for whoever picks this back up, not to be resolved here:

1. **v5-op-sem citation discrepancy.** The doc's own §1 states, sourced from
   direct file reading, that `lib/type/static-v5/op_sem.lua`/`op_sem_alt.lua`
   formalize v5's *type-inference algorithm's* step relation, not
   crescent-Lua's language semantics — off-target for the prefix role. A
   later message from fable cited that same op_sem pair as a prefix-role
   asset anyway, contradicting the sourced finding. Unreconciled.
2. **"v3's constraint-gen/solve as the founding shape" is ambiguous** —
   unclear whether this means reusing v3's actual code (which would repeat
   the same "context poisoning" risk already flagged for adopting
   `proof/typing.v` wholesale, since `lib/type/static/` is the exact lineage
   with 105+ documented ad-hoc `ctx._foo` instances) or only the abstract
   generation/solving-split pattern.
3. **Schematic instantiation is undesigned**, blocked on an upstream fork:
   is a judgment's content (e.g. `type_str`) an opaque string or a
   structured term? Unresolved.
4. **Discharge-certificate format is still open**, unchanged from prior
   rounds.
5. **Axiom/taint propagation cost is argued-plausible, not verified** — a
   node shared by two parents with different discharge contexts should show
   identical taint but potentially different discharge status; that's the
   worked example fable proposed to distinguish correct (node-property)
   taint propagation from an accidentally path-relative implementation, and
   it hasn't been run.
6. **The corroboration layer remains the standing, deliberately-unverified
   research bet** from the original proposal — does the closure predicate
   ever get exercised against a real, mature theory, or only against
   founding toy entries.

## lib/y_crdt/update.lua: yjs update v1 wire codec (2026-07-27)

Implemented `lib/y_crdt/update.lua` (encode_v1/apply_v1/encode_diff_v1/
encode_state_vector[_from_table]/decode_state_vector/merge_updates_v1) plus
`lib/y_crdt/update_test.lua` (38 assertions: simple round trip, root-not-
declared error, state vector round trip, delete set, diff encoding, two
multi-client convergence scenarios, merge_updates_v1). Verified against real
yjs upstream (github.com/yjs/yjs, tag v13.6.31 -- the actual npm `latest`;
`main` is an unreleased 14.0.0-rc rewrite with a different struct
architecture and is NOT the deployed wire format). Corrected one spec error
in the original task brief: delete-set clocks are NOT delta-encoded in v1
(confirmed against `DSEncoderV1.writeDsClock`/`writeDsLen`, both plain
`writeVarUint`).

Documented scope cuts (not silent gaps):
- [ ] **No resumable cross-update dependency streaming.** `apply_v1` uses a
  worklist retry loop (handles out-of-order same-update cross-client
  dependencies) but assumes every dependency is present somewhere in the
  update or the target doc when called -- unlike yjs's stack-based
  `integrateStructs`, which can hold a partial update pending a future
  arrival. A genuinely missing dependency is a caller-facing `(nil,
  errmsg)`. Build the resumable path if cross-update/streaming sync is ever
  needed.
- [ ] **ContentType (ref 7) only supports Array/Map/Text (type refs 0/1/2).**
  XmlElement/XmlFragment/XmlHook/XmlText (3-6) aren't representable at all
  in this codebase (shared_type.lua/doc.lua have no XML concept) -- decoding
  one returns `(nil, errmsg)`.
- [ ] **JSON content (ref 2)/Embed (ref 5)/Format (ref 6) collapse JS's
  null/undefined distinction into `encoding.lua`'s single `M.null`
  sentinel.** A decoded JSON-content array element whose wire value was the
  literal string `"undefined"` (yjs's per-element JSON.stringify special
  case for JS `undefined`) decodes to `encoding.null`, same as a real JSON
  `null` -- Lua tables can't hold a genuine "hole" as an array element the
  way a JS array can, so there's no second sentinel to distinguish them.
  Encoding never emits the `"undefined"` marker for this reason (always
  round-trips through `encoding.null` -> JSON `null`).
- [ ] **Root-type parent references require the caller to pre-declare that
  root** (via `doc.get_text`/`get_array`/`get_map`) before applying an
  update that references it by name. The wire format's root-parent
  reference carries only the name, never a type tag, so there's no way to
  auto-vivify the right kind of root from the update bytes alone (real
  yjs's own `doc.get(name)` without a type constructor creates a type-less
  `AbstractType`; this codebase's `SharedType` always carries a concrete
  `type_name` and has no equivalent). `merge_updates_v1` takes an optional
  `roots: { [name]: "text"|"array"|"map" }` parameter for exactly this
  reason (its scratch doc has no caller-established root context of its
  own).

Typechecker substrate gaps found (all with minimal repros, documented
in-place as `TYPECHECKER WORKAROUND` comments in `lib/y_crdt/{item,
integrate,struct_store,update}.lua`):
- [ ] **A checked cast (`--[[: T]]`) from a precisely-typed `unknown` value
  is rejected outright**, even behind a `type(v) == "table"` runtime guard
  -- unlike casting from a value whose static type has already collapsed to
  `any` through some unrelated inference gap. Narrowing `unknown` requires
  capturing it into a bare local first, then guarding *that* local (not a
  repeated field read) with `type()`/a discriminant check.
- [ ] **A union-typed local reassigned across sibling `if`/`elseif`
  branches loses kind-discriminant narrowing at several distinct points
  downstream**, each needing a different fix: (a) the very next line inside
  an `elseif` branch that itself set the discriminant -- fixed by routing
  the initial read through an identity function; (b) final use after the
  whole `if`/`elseif` chain -- an identity function does NOT fix this one;
  what works is moving the final nil-check + narrow into a *separate
  top-level function* taking the union as a plain parameter, with two
  *sequential* `if`-early-return statements (not one combined `and`-chain
  condition -- combined conditions have their own separate, already-
  documented narrowing gap). See integrate.lua's `identity_parent` /
  `require_resolved_parent`.
- [ ] **`T[]` sugar in a `--::`/`--:` annotation desugars to an index
  signature (`{ [number]: T }`), not the `{ [integer]: T }` shape
  `table.sort`'s stdlib declaration expects.** A value retrieved by
  indexing (or `pairs`-iterating the values of) a table whose declared type
  uses `T[]` sugar carries the same incompatibility onward even once copied
  into a fresh, unannotated local. The reliable pattern: sort a single flat
  array built directly from a clean, non-index-signature source (a function
  parameter, not a map lookup) *before* any map-grouping happens, using
  manual insertion sort instead of `table.sort` (which also has its own
  separate, already-documented "generic V conflict" bug across call sites
  in the same file -- see `lib/type/search/init.lua`'s comment). Every
  `table.sort` call in `lib/y_crdt/update.lua` was replaced with inline
  manual insertion sort for this reason.
- [ ] **A function declared to return a union with the error case embedded
  as a tuple (`T | (nil, string)`) never lets a caller's `if v == nil then
  return ... end` guard narrow `v` away from nilable for any subsequent use
  beyond a single field read or an immediate `return`** -- confirmed with
  a minimal repro reproducing this exact return-type shape; declaring the
  same function `(T | nil, string | nil)` (two separate optional return
  values, functionally identical since both branches already return two
  values at runtime) fixes it completely. Applied to
  `struct_store.get_clean_start`/`get_clean_end`/`add` and
  `integrate.integrate` (pure annotation changes, no behavior change) --
  `struct_store.get_item_clean_start`/`get_item_clean_end` were LEFT with
  the old shape since their existing callers never hit the bug (they only
  ever do a single field/kind check on the result) and changing them wasn't
  needed for this task. Reconcile the two shapes project-wide once this is
  fixed upstream.

## Grammar-induction prototype for tiered-dispatcher init.lua files (2026-07-27)

See `docs/design/decision-tape.md` (renamed and rewritten 2026-07-28 from
`docs/design/codebase-as-grammar.md` — the reuse-count/flat-grammar framing
recorded there was corrected; see that document's "corrected model" and
"two framings this document tried and retracted" sections) and
`tooling/grammar_gen/` (not `lib/` —
throwaway analysis tooling). Byte-for-byte reproduction of 5 real files verified
(`bin/luajit tooling/grammar_gen/generate.lua --all --diff`). Open items:

- [ ] **Not proven at scale.** Only 5 files induced by hand; whether the same
  one-flat-grammar model holds for more of crescent, or fragments into many
  small unrelated grammars, is untested. See the doc's "What's proven vs.
  aspirational" section.
- [ ] **`lib/keyring/init.lua` and `lib/stb/init.lua` are real tier-selecting
  files that don't fit this grammar** (keyring: lazy per-call dispatch with
  full tier implementations inline, no thin re-export layer; stb: mutates the
  module table per-tier rather than building one narrowed literal). Whether
  they warrant their own induced grammar, an extension of this one, or
  neither is open — do not fold them into this grammar without inducing
  their own slots first.
- [ ] **Derivation format is not yet compact.** At n=5, `tooling/grammar_gen/derivations.lua`'s
  derivation source (15770 bytes total) is *larger* than the 5 generated
  files combined (13418 bytes) — see the doc's measured compression section.
  Two concrete, fixable causes: (1) each file's free-text doc header is
  stored as a raw terminal in full, and (2) field lists (name + type per
  exported function) are repeated 2–3 times per derivation (alias block,
  struct type, M-table) instead of named once and referenced three times.
  Fixing (2) is a real refactor of the derivation format, not the mechanism;
  worth doing before drawing scale conclusions from byte ratios.
- [x] **No automated grammar induction.** (2026-07-28) Built
  `tooling/grammar_gen/luaparse.lua` (independent Lua 5.1/LuaJIT parser,
  plain nested-table AST — `lib/type/static/parse.lua` is a flat FFI-arena
  parser built for typechecker throughput and was the wrong shape for
  shape-comparison work; see the design doc for the full reasoning),
  `tooling/grammar_gen/canon.lua` (canonicalizes ternary `x and a or b` and
  `if c then x=a else x=b end` into one `cond_assign` shape; structural
  fingerprinting that abstracts identifiers/literals but keeps tag/operator/
  arity), and `tooling/grammar_gen/discover.lua` + `induce.lua` (clusters
  single-statement and 2–5-statement-window occurrences across a corpus
  into rules/slots/residue). Verified against the ground-truth case: on the
  5 dispatcher files, `compress`/`crypto`'s `if/else` ok-check and
  `regex`'s ternary land in the SAME slot
  (`COND_ASSIGN(NAME;CALL(1))`, 3 alternatives) — `luajit
  tooling/grammar_gen/induce.lua --dispatchers --verbose` reproduces this.
  Also independently rediscovered `path_bootstrap` as one slot with the
  same 4-vs-1 (base64 anomaly) alternative split the hand-induced grammar
  documents. Run on all of `lib/` (1698 files, ~7s): 2134 single-statement
  rules / 6205 slots / 13081 residue, plus 2–5-statement window clusters;
  see the design doc for real numbers and the caveats below — this is a
  genuine finding, not a tuned-to-pass demo, and it surfaced real new gaps
  (next few items), not a clean "solved."
- [ ] **Statement-shape fingerprinting floods with reuse-heavy but
  semantically-empty "slots" at whole-`lib/` scale.** `RETURN(ID)` shows
  6417 occurrences / 925 "alternatives" — nearly every single-identifier
  return statement in the corpus, one alternative per distinct variable
  name. This is real, high reuse, but it isn't "a design decision with
  named alternatives" in the same sense as `tier_select` — the variable
  name is unconstrained, not chosen from a small deliberate set. The tool
  as built has no discriminator between "a slot whose alternatives are a
  real, bounded design choice" and "a slot whose alternatives are just
  every distinct identifier that ever appeared there." Needs either an
  alternative-count/entropy threshold, a way to recognize "this hole is
  just an identifier reference, ignore its cardinality," or both — unbuilt.
- [ ] **`canon.lua`'s `cond_assign` fingerprint deliberately drops the
  condition's shape (see that file's header) to unify if/else and ternary
  forms — this is proven to work for the ground-truth case, but at whole-
  `lib/` scale it also merges semantically unrelated conditional-assignments
  that happen to share a branch-shape.** E.g. `COND_ASSIGN(NAME;CALL(1))` at
  full-corpus scale mixes crescent's tier-select idiom with unrelated code
  in `lib/type/static-v4/`'s constraint solver and `lib/memoize/init.lua`'s
  nil-sentinel handling — same shape, different concerns. Not fixed here;
  recorded as the honest tradeoff of the modeling choice (see canon.lua's
  header and the design doc).
- [ ] **Crescent's `--:`/`--::` type-annotation lines are Lua comments,
  invisible to `tooling/grammar_gen/luaparse.lua`'s AST.** The hand-induced
  grammar's `type_alias_block` and `narrow_comment` productions — called
  "the closest thing to a pure convention" in the design doc, 100% reuse
  across all 5 dispatcher files — are NOT rediscovered by this tool at all,
  because the parser treats them as comment text and discards them like any
  other comment. A real chunk of the corpus's actual repeated structure is
  invisible to this induction pass. Would need a second extraction pass
  over raw source treating contiguous `--:`/`--::` comment blocks as their
  own span type (line-shape classification: alias decl / struct open /
  field line / struct close / narrow line), separate from the Lua-syntax
  AST — unbuilt.
- [ ] **No promotion pass from raw statement-window clusters into named,
  parameterized multi-part productions.** The hand-induced grammar's
  `tier_select_cast_narrow` is one production with a `variant` parameter
  selecting a sub-shape; this tool's window clustering finds the same
  *span* repeated (e.g. the 2-, 3-, and 4-statement windows around
  compress/crypto's pcall-then-cond_assign sequence all show up as separate
  clusters at each window size) but never merges these into one named,
  parameterized production the way a human write-up would. Each window
  size is clustered independently; there's no step that recognizes "these
  N clusters at window sizes 2..5, all starting at the same statement
  positions, are one production at different levels of context."
- [ ] **Parser coverage: 7 of 1698 `lib/` files fail to parse** (as of
  2026-07-28): `lib/argon2/init.lua`, `lib/game_math/init.lua`,
  `lib/image_processing/init.lua`, `lib/keyring/keyring_test.lua`,
  `lib/logic_circuit/init.lua`, `lib/qrencode/init.lua`,
  `lib/sat/sat_test.lua`. Real syntax this parser doesn't yet handle (not
  isolated further — see `tooling/grammar_gen/induce.lua --lib`'s
  "unparsed files" output for the exact line/column). These 7 files are
  silently excluded from induction results, not miscounted as residue.

## Decision-tape model correction (2026-07-28)

`docs/design/codebase-as-grammar.md` was renamed and rewritten to
`docs/design/decision-tape.md` — the reuse-count/flat-grammar framing and a
briefly-considered probabilistic/entropy framing are both recorded there as
retracted dead ends, replaced by: determinacy (forced vs. free), not reuse
count, is the discriminator; the artifact is a decision tape (a
deterministic expander plus exactly the free choices). No `tooling/
grammar_gen/` logic changed in this pass except comment updates pointing at
the renamed doc, plus a new header comment on the item immediately below.
Open items this correction produced, not yet closed:

- [ ] **`tooling/grammar_gen/canon.lua`'s `cond_assign` unification of
  ternary (`x and a or b`) and if/else (`if c then x=a else x=b end`) is
  UNSOUND, not merely lossy — this is a real bug in committed code.** When
  `a` can evaluate to `false` or `nil`, the ternary silently falls through
  to `b` regardless of `c`; the if/else form has no such fallthrough. The
  two forms diverge on real inputs whenever `a`'s value set includes
  `false`/`nil`. This unification is exactly what produces the headline
  ground-truth result (compress/crypto's `if/else` and regex's ternary
  landing in the same slot), so that result rests on an unsound
  equivalence — every confirmed instance so far happens to fall on the
  sound side (none of the sampled `a` values are `false`/`nil`-valued in a
  way that changes behavior), but the unification doesn't check for this
  and would silently misclassify a case where it matters. Acceptable as a
  clustering heuristic (finding structural kinship between idioms); NOT
  acceptable as a semantic-equivalence claim, and any fidelity check built
  on top of it would be vacuous exactly where the bug lives. See
  `docs/design/decision-tape.md`'s "live correctness bug" section. Not
  fixed in this pass — fixing requires either restricting the rewrite to
  provably-truthy `a` values, or keeping the two forms in separate
  fingerprint buckets and finding a different (sound) way to relate them.
- [ ] **Fidelity canonicalization vs. clustering canonicalization are
  distinct and only the latter exists.** The owner's stated correctness bar
  for any "lossless" or round-trip claim is canonical-form *equality*, but
  `canon.lua`'s only canonicalization (the `cond_assign` rewrite above,
  plus its identifier/literal-abstracting fingerprint) is deliberately
  lossy — built for finding structural kinship across instances, not for
  proving two pieces of code are equivalent. It cannot serve as a fidelity
  check as-is (see the unsoundness item above for why using it as one would
  be actively wrong, not just insufficiently precise). What a fidelity
  canonicalization would need to preserve, that the clustering one is free
  to drop, is not yet decided — this is unresolved, not merely unbuilt.
- [ ] **`discover.lua`'s "residue" bucket (cluster size 1) conflates two
  different things the corrected model needs told apart: a genuinely free
  one-off decision, and a forced-but-rare site that simply doesn't repeat
  in this corpus** (e.g. the JSON `\u`-surrogate-pair escape handling,
  forced by RFC 8259, occurs once per file and would land in "residue" the
  same as an actual one-off free choice). The tool has no way to
  distinguish these today. Related to, but distinct from, the
  already-tracked `RETURN(ID)` noise-slot problem above — that one is about
  slots with too many spurious "alternatives"; this one is about size-1
  clusters having no forced/free signal at all.
- [ ] **Compression ratio at scale remains open, not negative.** The n=5
  hand-built prototype's derivation source (15770 bytes) is larger than the
  code it generates (13418 bytes) — see the two concrete, believed-fixable
  causes already tracked above (repeated field lists; doc-header prose
  stored as an uncompressed raw terminal). Carried forward unchanged: this
  is an open question about a 5-file sample, not evidence against the
  corrected model, and should not be read as a verdict either way until
  re-measured at scale with a fixed derivation format.

## Typechecker substrate gaps (found while implementing lib/y_crdt/encoding.lua, 2026-07-27)

- [ ] **Calling `string.byte`'s overloaded `(string, integer, integer) -> ...integer` multi-return candidate (or destructuring/spreading its result) from inside ANY function carrying a `--:` signature annotation is resolved incorrectly: only one value survives typing and the rest silently become `nil`/`never`, breaking arithmetic or argument-spread on the remaining results — this reproduces even with no `self`/method/struct involved at all.** This is the same family as the already-documented `string.byte` never-narrowing gaps above (found in `lib/pdf/object.lua`, `lib/pdf/xref.lua`, `lib/locale/init.lua`) but a distinct trigger: those were about a *single*-value `byte` call losing its narrowing after a nil-check guard; this one is about the *multi*-return `...integer` overload candidate specifically, and the trigger is simply "the enclosing function has any return-type annotation at all" — no loop, no guard, no method/self needed. Minimal repro: `local s = "abcd"` + `--: () -> integer` + `local function foo() local pos = 1; local b0, b1, b2, b3 = string.byte(s, pos, pos + 3); return b0 + b1 + b2 + b3 end` fails with `b1`/`b2`/`b3` typed `nil` (only `b0` survives); the identical body with no `--:` annotation on `foo` typechecks fine. Further narrowed: even the *single*-value overload (`string.byte(s, pos)`, 2-arg form) breaks the same way when the enclosing function's declared return type does not include `nil` (e.g. `--: () -> integer`) — `local b0 = string.byte(s, pos); return b0` fails ("cannot return nil: cannot assign nil to integer") even though `b0`'s real value is `integer | nil` and the guard hasn't run yet; the same code with `--: () -> (integer | nil)` passes. Wrapping every single-byte read through a locally-defined helper carrying its own explicit non-overloaded signature (`--: (string, integer) -> (integer | nil) local function byte_at(s, i) return string.byte(s, i) end`) and calling that instead of `string.byte` directly — with an explicit nil-check before arithmetic — sidesteps the bug entirely; confirmed by minimal repro before applying. Worked around in `lib/y_crdt/encoding.lua` (`byte_at`, used throughout `Decoder`'s `read_uint8/16/32`, `read_float32/64`, `read_var_uint`, `read_var_int`, and in `Encoder:write_any`'s float32 round-trip check) at the cost of N separate `string.byte` calls instead of one N-argument call per multi-byte read. Revert to direct multi-byte `string.byte(s, i, j)` destructuring (and drop `byte_at`) once this resolves.

- [ ] **Reassigning a parameter that carries an explicit `integer` type annotation (`num = 0 - num`) is rejected as "cannot assign `number` to `integer`" once the function body contains an earlier `type(num) ~= "number" or num % 1 ~= 0` guard, even though `#__sub: (integer, integer) -> integer` is declared and a *fresh* local fed by the exact same subtraction expression right after the same guard infers `integer` correctly (i.e. the RHS expression's own type is fine; only the reassignment-to-the-original-parameter binding is rejected).** Minimal repro: `--: (integer) -> nil local function f(num) if type(num) ~= "number" or num % 1 ~= 0 then error("bad") end; local is_neg = num < 0; if is_neg then num = 0 - num end; print(num) end` fails at the `num = 0 - num` line; changing only the last two lines to `local abs_num = num; if is_neg then abs_num = 0 - num end; print(abs_num)` (fresh local, never reassigns the parameter) passes with zero errors, same guard, same expression. Worked around in `lib/y_crdt/encoding.lua` (`Encoder:write_var_int`) by introducing a separate `rest` local for the running magnitude instead of reassigning `num` itself. Revert to reassigning `num` directly once this resolves.

- [ ] **Narrowing a variable via a negated `or`-chain (`type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > n`) does not narrow that variable for the later operands of the same `or` expression — only the first operand's own check is honored — even though the identical logic expressed as a nested `if type(k) == "number" then if k % 1 == 0 and ... then` (positive form, `and`-chain) narrows correctly throughout.** Minimal repro: `--: (unknown) -> nil local function f(data) if type(data) == "table" then for k in pairs(data) do if type(k) ~= "number" or k % 1 ~= 0 then end end end end` fails "cannot perform arithmetic on `never`"/`unknown` at the `k % 1` — note this also surfaces a second, related issue: bare `type(data) == "table"` narrowing of an `unknown` value produces a table type with no usable indexer for `pairs()` (keys type as `never`) unless immediately followed by a checked (not forced) cast to the value's actual open shape, e.g. `local tbl = data --[[: { [unknown]: unknown, ... } ]]`, after which `pairs()` keys type as `unknown` (still requiring the nested-if narrowing fix above before arithmetic). Worked around in `lib/y_crdt/encoding.lua` (`Encoder:write_any`'s array-vs-map detection loop) with the checked cast plus a nested `if type(k) == "number" then if k % 1 == 0 and k >= 1 and k <= n then ... end end` in place of the single `or`-chain condition. Revert to the flat `or`-chain once it narrows the way the nested `and`-chain form already does.

## Typechecker substrate gaps (found while implementing lib/y_crdt/item.lua, struct_store.lua, integrate.lua, 2026-07-27)

Six distinct narrowing/typeof gaps surfaced building the YATA core data model
(`item.lua`, `struct_store.lua`, `shared_type.lua`, `transaction.lua`,
`integrate.lua`, `doc.lua`). Each was minimally reproduced in isolation
before working around it (repros discarded after confirming, not committed).
`bin/cr check` passes with 0 errors, 0 warnings on all six library files.

- [ ] **A union built from three separately-`typeof`-captured record types loses precision on fields common to all three members.** Repro: `local a = f.new(...); --:: A = typeof a` (ditto B, C); `--:: U = A | B | C`; `--: (u: U) -> number local function g(u) return u.id.clock end` warns "inference fell back to any" on `u.id`, and any arithmetic on the result then hard-errors "cannot perform arithmetic on nil" — even though `id` is a plain non-optional field on all three source types and docs/typechecker-reference.md says common fields should be accessible on a union with no narrowing needed. Worked around in `lib/y_crdt/struct_store.lua` (`StructCommon`, a hand-declared `{ id, length, kind, deleted }` record) by upcasting `s --[[: StructCommon]]` before reading those fields instead of reading them off the `Struct` union directly — a checked width-subtyping upcast, not a force cast. Revert to direct field access on `Struct` once this resolves.
- [ ] **Negated field-discriminant narrowing (`if x.kind ~= "lit" then ... end`) does not narrow `x`, while the positive form (`if x.kind == "lit" then ... end`) narrows correctly for the identical union.** Confirmed as a distinct bug from the item above: both use the same `Struct` union, but `~=` produces "match type contains `any` — exhaustiveness cannot be verified" where `==` type-checks cleanly. `lib/y_crdt/struct_store.lua` and `lib/y_crdt/integrate.lua` avoid `~=` on any `kind` discriminant everywhere (always the positive `==` form, restructuring `if x ~= y then A else B` as `if x == y then B else A` where needed). Revert once `~=` narrows the same as `==`.
- [ ] **Destructuring a `T | (nil, string)`-returning call into two locals, then guarding with `if a == nil then return ... end`, does not narrow away the `(nil, string)` arm for any later use of `a` — including a bare `return a` with no arithmetic.** Minimal repro: `--: (integer) -> integer | (nil, string) local function f(x) if x < 0 then return nil, "neg" end; return x end` + `--: (integer) -> integer local function g(x) local idx, err = f(x); if idx == nil then return -1 end; return idx end` fails "cannot return `integer | (nil, string)`" on the final `return idx`, even though the guard already returned on the nil case. Worked around throughout `lib/y_crdt/struct_store.lua` by having the internal helpers (`find_index`, `split_struct_at`) throw via Lua `error()` on their failure paths instead of returning `(nil, string)` — which also happens to match yjs's own documented contract for the equivalent functions ("expects id is in store, throws otherwise") — so public-API functions built on them never destructure a `T | (nil, string)` return into a reused local; where a public function's own natural implementation would have delegated to another `(nil, string)`-returning public function (`M.find` calling `M.get`), the two-line "unknown client + find_index" check was inlined instead of delegating, for the same reason. Revert both workarounds — call `error()` sites back to `(nil, string)` returns, and `M.find` back to delegating to `M.get` — once this narrows correctly.
- [ ] **`typeof` on a self-referential record type loses precision on its own recursive fields.** A record with a field typed `Self | nil` (e.g. `Item.left: Item | nil`), captured via `--:: T = typeof sample` from another module's constructor, degrades every recursive field access (`x.left`, `x.left.right`, ...) to `any` ("inference fell back to any" on every such access) — even though the *identical* field access on the type's own native (non-`typeof`-round-tripped) declaration in its home module type-checks with zero warnings. Confirmed by a minimal repro isolating exactly this (typeof of a self-referential type in a second file vs. direct declaration in the first). Worked around in `lib/y_crdt/integrate.lua` and `lib/y_crdt/transaction.lua` by hand-restating `Item`/`SharedType`'s structural shape (matching `item.lua`/`shared_type.lua`'s own declarations) instead of `typeof`-capturing them, unlike the non-recursive `StructStore`/`Content` types in the same files, which `typeof` captures without issue. Revert to `typeof sample_item` (dropping the hand-restated aliases) once recursive-type capture via `typeof` is fixed.
- [ ] **Narrowing a struct field via a guard clause (`if f.x == nil then return ... end`) does not persist past the `return` for later reads of `f.x`, while narrowing a bare local the same way does.** Minimal repro: `--:: Foo = { x: number | nil }` + `--: (f: Foo) -> number local function g(f) if f.x == nil then return -1 end; local x = f.x --[[: number]]; return x end` fails the checked cast ("expects number, but argument might also be nil") on the second read of `f.x`, while `--: (x: number | nil) -> number local function g(x) if x == nil then return -1 end; return x end` (bare parameter, no field) type-checks with zero errors for the same shape of guard. Worked around in `lib/y_crdt/integrate.lua` (`M.integrate`'s parent-nil check) by capturing `i.parent` into a local (`parent0`) *before* the guard and branching on the local instead of re-reading `i.parent` after it. Revert to guarding on `i.parent` directly (dropping `parent0`) once field-narrowing survives a guard-clause return the way bare-local narrowing does.
- [ ] **Indexing an index-signature map field (`{ [number]: T[] }`) yields a `T[]` whose elements fail kind-discriminant narrowing in a function that returns the narrowed variant, even though the identical narrowing on a plain `T[]` *parameter* (not sourced from an index-signature lookup) succeeds.** Minimal repro: `--:: StructStore = { clients: { [number]: Struct[] } }` + a function that does `local structs = store.clients[client]; if structs == nil then return end; local s = structs[i]; if s.kind == "item" then return s end` fails "match type contains `any` — exhaustiveness cannot be verified" on the `s.kind == "item"` check; the same body with `structs` as a bare `Struct[]` function parameter (no `store.clients[...]` indexing involved) passes. Worked around in `lib/y_crdt/struct_store.lua` with `as_structs`, a plain identity function (not a cast) that the array is routed through immediately after the `store.clients[client]` lookup and before any indexing/narrowing on its elements — confirmed this specific shape of indirection (an ordinary function call, not a type assertion) is what resets whatever provenance tag causes the degradation. Revert (drop `as_structs`, index `store.clients[client]` directly) once this narrows correctly upstream.

Scope cuts made in the same work, none typechecker-related, all deliberate and documented at their definition site (search `SCOPE:` / `SCOPE cut` in the files below) — recorded here too so they're not mistaken for oversights:

- [ ] **`lib/y_crdt/shared_type.lua` is a bare record (`type_name`, `start`, `map`, `length`, `item`), not Y.Text/Y.Array/Y.Map.** No `insert`/`delete`/`toString`/observe API. `doc.get_text`/`get_array`/`get_map` return this bare record tagged by `type_name`; a follow-up library builds the rich per-type wrappers on top of it.
- [ ] **`lib/y_crdt/transaction.lua`'s delete tracking is a flat `Item[]` (`deleted_items`), not yjs's range-compacted client+clock delete-set.** Sufficient for in-memory correctness (an item's `.deleted` flag is authoritative); insufficient for wire encoding, which needs delete ranges. The sync-protocol bridge (`lib/y_crdt/encoding.lua`, see the section above) will need a real delete-set built on top of this.
- [ ] **No post-transaction compaction (merging adjacent same-client items via `item.merge_with`) and no update-event emission in `doc.transact`.** Both need machinery not built in this task (a background merge pass akin to yjs's `tryGc`/`tryMerge`, and an observer/event system).
- [ ] **No garbage collection pass** (yjs's `tryGcDeleteSet`/`Item.prototype.gc`, replacing tombstoned Items with `Gc` structs). `gc.lua` exists (the struct type + `merge_with`/`splice`) but nothing yet decides *when* to convert a deleted Item into one.
- [ ] **No search-marker cache** (yjs's per-type fast-lookup structure for `YArray`/`YText` index access). Pure performance optimization, not a correctness gap — omitted since nothing in this task's scope does positional indexing yet.
- [ ] **`lib/y_crdt/content.lua`'s string content operates on Lua byte strings, not UTF-16 code units.** yjs measures `ContentString` length/splits in UTF-16 code units (guarding against splitting surrogate pairs) because JS strings are UTF-16; this is a wire/JS-interop concern for the serialization bridge, not a core CRDT-ordering concern (YATA never inspects string contents, only lengths/origins). The encoding bridge will need to re-index between byte offsets and UTF-16 code-unit offsets when talking to real yjs clients.
- [ ] **No `ContentType`/`ContentDoc` recursive child-deletion** (yjs's `ContentType.prototype.delete` walks a nested type's own items and marks them deleted too). `item.delete` only affects the one Item; nested shared types aren't implemented yet (see the bare-`SharedType` item above), so there's nothing recursive to walk yet.

## Typechecker substrate gaps (found while building tooling/grammar_gen, 2026-07-27)

- [ ] **`bin/cr check` currently rejects the force-cast (`--[[:! T]]`) pattern
  that `lib/encode/base64/init.lua` and `lib/format/json/init.lua` use at
  their own tier-selection `pcall` boundary** — i.e. two files already in
  `lib/` do not pass `bin/cr check` with zero errors today. Repro: `timeout
  30 bin/cr check lib/encode/base64/init.lua lib/format/json/init.lua`
  reports 4 errors, all "force cast — fix the upstream type annotation
  instead; see CLAUDE.md" at the `impl = ffi_impl --[[:! Base64Impl]]` /
  `impl = simd_result --[[:! JsonImpl]]` lines (and the JsonImpl equivalents).
  This predates this session — not introduced here, found while building
  `tooling/grammar_gen` and hitting the identical pattern. Framed as
  substrate, not a result deficit: **narrowing an `unknown`-returning
  `require()` result (or a `pcall(require, ...)` result) for a local
  (non-stdlib) module surface has no established non-force-cast path
  today.** The two `lib/` files either need their own upstream fix (whatever
  "fix the upstream type annotation instead" means concretely for a
  `pcall(require, ...)` boundary — unclear, needs typechecker-side
  investigation) or the force-cast-rejection rule needs a documented
  exception for exactly this boundary shape. Do not silently re-permit
  force casts broadly to unblock this — that's the general case CLAUDE.md's
  "almost never correct" rule is protecting.

## Typechecker substrate gaps (found while building tooling/grammar_gen's induction pass, 2026-07-28)

- [ ] **Confirms the item above more strongly: `--[[:! T]]` force casts are
  a hard `bin/cr check` error, not merely discouraged.** Attempted using
  force casts as accessor helpers for `tooling/grammar_gen`'s dynamically-
  tagged AST nodes (a self-authored, internally-consistent tree — not
  narrowing external input, exactly the case one might expect a force cast
  to be defensible for) and every `--[[:! T]]` site was rejected outright
  ("force cast — fix the upstream type annotation instead"). Worked around
  in `tooling/grammar_gen/canon.lua` (`get`/`gs`/`gb`/`gl`/`gi`) with real
  `type()` runtime narrowing instead, erroring on a shape mismatch (an
  internal-consistency bug in this tool's own parser, not a data error).
- [ ] **Reassigning a local across several sequential `pattern:find(...)`
  calls (`local s, e, cap = str:find(p1); if not cap then s, e, cap =
  str:find(p2) end; ...`) widens the reassigned variable's type in a way
  that breaks later arithmetic on it**, distinct from the already-documented
  `string.byte`-multi-return gaps. Repro (recreate from description; not
  committed): chaining several `source:find(pattern, i)` calls into the
  same `s, e, num` locals across `if not num then ... end` branches, then
  using `i = e + 1` after, fails with "cannot perform arithmetic on `_`".
  Worked around in `tooling/grammar_gen/luaparse.lua` (`lex`'s number
  scanning) by factoring a `match_at(from, pattern)` helper that returns
  `(string | nil, integer)` from a single `find` call, called once per
  candidate pattern instead of reassigning shared locals across branches.
  Revert to the direct chained-reassignment form once this widens correctly.
- [ ] **`table.sort`'s declared generic `<V>(t: { [integer]: V, ... }, comp)
  -> ()` appears to monomorphize to the first call site's `V` for the rest
  of the file, rejecting a later, textually-distinct call with a different
  element type** ("cannot assign `{Slot fields...}` to `string`" after an
  earlier `table.sort(paths, ...)` over a `{ [integer]: string }` in the
  same file). Additionally, **passing an array into a helper function whose
  parameter type only mentions a subset of the element's fields (e.g.
  `{ count: number, ... }`, to sort generically by one shared field)
  degrades the argument's own static element type at the call site for the
  rest of its lifetime in the caller** — a later read of a field the
  helper's parameter type didn't mention fails as if the field didn't
  exist. Neither repro isolated to a minimal standalone case yet. Worked
  around in `tooling/grammar_gen/induce.lua` (`print_cluster_result`) by
  building fresh sorted arrays via insertion (never passing
  `result.slots`/`result.rules` through another function boundary, never
  reusing `table.sort` a second time in the file) instead of an in-place
  generic sort. Revert to `table.sort(result.slots, function(a,b) return
  a.count > b.count end)` (and the `result.rules` equivalent) once either
  gap resolves.

## Fixed bugs

- [x] **`.crescentcache` manifest keyed diagnostics only by content hash, ignoring file path** (2026-07-10). `check.lua`'s disk-cache path computed `src_hash = cache_mod.hash_file(filename)` — content only — and used it as the manifest key for both lookup and store. Cached diagnostics (`errors.lua` `DiagEntry.filename`) bake in the path of whichever invocation first populated the cache entry, so two different paths with identical content collided in the manifest and the second path's check returned diagnostics carrying the *first* path's filename. Fixed by adding `cache.lua` `M.entry_key(filename, content_hash)` (hashes `path .. "\0" .. content_hash`) and using it as the manifest key in `check.lua` instead of the bare content hash; `M.hash_file` / `M.hash_source` are unchanged and still used path-independently for dependency change-detection. Verified with a manual repro (two files, identical content, different paths, same `.crescentcache`): each now gets its own manifest entry and reports its own path on both cold and warm-cache runs.

## Typechecker substrate gaps (found while implementing lib/platform/apps/finance/{doc_registry,sync_manager,bridge}.lua, 2026-07-27)

- [ ] **A closure passed as `lib/y_crdt/doc.lua`'s `M.transact(d, fn)` second argument infers `fn`'s `txn` parameter incorrectly whenever `d` is a value derived from a function parameter (a struct field, or the parameter itself) rather than a value freshly constructed by `doc_mod.new(...)` in the same local scope — even when `d` is explicitly typed `Doc` throughout.** Minimal repro (recreate from description; not committed): `M.foo = function(registry) local d = registry.accounts_doc; local m = get_root_map(d, "meta"); doc_mod.transact(d, function(txn) map.set(m, txn, "k", "v") end) end` fails "argument 2: cannot pass `{ deleted_items: ..., doc: ..., ... }` where `(unknown) -> nil` expected: parameter 1: value of type `unknown` must be narrowed before use" — the closure's `txn` parameter gets pinned to the concrete `Transaction` record (from its use inside `map.set`), which then fails to satisfy `doc_mod.transact`'s own declared callback type `(unknown) -> nil` (a function requiring a concrete input can't be passed where one accepting `unknown` is expected). The identical closure body over a `d` bound directly to a fresh `doc_mod.new(...)` call infers correctly regardless of whether the enclosing function has an explicit signature. Worked around throughout `lib/platform/apps/finance/doc_registry.lua` (`transact_set_in_map`) and `lib/platform/apps/finance/bridge.lua` (`run_transaction`, `mutate_doc`) by using a *named local* `apply` function (never an inline closure expression) whose parameter is explicitly annotated `unknown` (matching `doc_mod.transact`'s own declared type, so no inference pinning occurs) and immediately narrowed via `type(x) == "table"` + a checked cast to a locally-restated `Transaction` type before use. Revert to inline closures with upvalue-captured results (matching `lib/y_crdt/map_test.lua`'s own pattern) once this is root-caused.

- [ ] **`lib/y_crdt/map.lua`'s own `Transaction.doc` type (no `share` field, `store.clients: { [number]: unknown }`) and `lib/y_crdt/update.lua`'s own `Transaction.doc` type (`share` present, `store.clients: { [number]: Struct[] }` concretely typed) are mutually exclusive record shapes at this checker's cast boundary — not width-subtyped as expected.** A single restated `Transaction` type giving `doc` the fuller (`update.lua`-compatible) shape satisfies `update.encode_v1` but then fails `map.set`/`array.insert`/`array.delete`'s own narrower `Transaction` parameter with "excess field 'share' not in target type"; the reverse (narrower shape) fails `update.encode_v1` with "missing field 'share'"/`clients` narrowing errors. Expected width/depth subtyping (a more detailed record satisfying a looser one whose fields are typed `unknown`) does not apply here. Worked around in `lib/platform/apps/finance/bridge.lua` by declaring two separate restated types (`Transaction` for map/array ops, `EncodeTransaction` for `update.encode_v1`) and casting the same runtime transaction value through whichever one matches the callee at each call site. Collapse to one shared type once record casts here are recognized as width-subtyped the way narrower-vs-wider unknown-fielded records are elsewhere in this codebase.

- [ ] **`array.to_array`'s declared return type `unknown[]` does not support the length operator (`#`), even though a structurally-identical explicit `{ [number]: unknown }` annotation on the same value does.** Minimal repro: `local current = arr.to_array(a); return #current` fails "cannot take length of type `unknown`"; adding `local current = arr.to_array(a) --[[: { [number]: unknown } ]]` (a checked cast, same shape) resolves it. Worked around at both call sites in `lib/platform/apps/finance/bridge.lua` (`M.delete_entry`, `M.apply_remote_entries`) with this cast. Revert once `T[]` sugar supports `#` the same way its expanded index-signature form does.

- [ ] **A destructured local bound from a 2-tuple-returning function call reverts to the function's full return-tuple type by the time it's used as a table-literal field value, even past a `nil`-check and a redundant `type(x) ~= "table"` re-guard, whenever that logic shares a function scope with other multi-return calls** — the same "whole-function inference instability" class already logged above for `lib/bookkeeping/import_ofx.lua`/`import_qif.lua` and for `lib/bookkeeping/store.lua`'s `read_book_currency`/`build_journal_from_rows` split, confirmed here as a new instance. In `lib/platform/apps/finance/bridge.lua`, `wire_lines_to_line_inputs(...)`'s destructured `line_inputs` local, used as `journal.post(j, chart, { ..., lines = line_inputs })`, failed with "field 'lines': tuple is not assignable to table/array" when inlined directly in `M.post_entry`/`M.apply_remote_entries` (both functions already having several other multi-return calls in scope) — isolating the call+guard+use into its own small dedicated function (`post_wire_entry`) was necessary but on its own **not sufficient**; the redundant `type(line_inputs) ~= "table"` re-guard (already established elsewhere in this codebase for the "unknown must be narrowed" class) was additionally required inside that isolated function before the error cleared. Similarly, `known_period_ids(db)`'s destructured `period_ids` local, indexed in a loop (`period_ids[i]`) inside `save_chart_to_all_periods`, required both isolating the per-period save logic into its own function (`resave_period_with_chart`) *and* rebinding `period_ids` through an explicit checked cast (`local ids = period_ids --[[: { [number]: string } ]]`) after the nil/type guards. Revert all of these once destructured multi-return locals reliably narrow to their own element type regardless of surrounding function-scope contents.

- [ ] **Short-circuit `or` does not narrow a plain local (not a field access) to non-nil for its own right-hand operand, contrary to standard flow-typing.** Minimal repro: `if wire_id == nil or journal.get(j, wire_id) == nil then ... end` fails "function expects `string`, but argument 2 might also be `nil`" at the `journal.get(j, wire_id)` call, even though `wire_id` is a bare local (not `t.wire_id`) already known `string | nil`. Worked around in `lib/platform/apps/finance/bridge.lua` (`entry_is_new`) by replacing the `or` with an explicit two-branch `if/else`, each branch returning directly (an annotated-but-uninitialized `local is_new --: boolean` followed by conditional assignment was tried first and separately rejected — "annotated local requires an initializer because `nil` is not in type `boolean`" — so the fix additionally needed to be a small function with early returns per branch, not just inline if/else assignment). Revert once `or`'s right-hand operand narrows from the left operand's negated nil-check for plain locals.

- [ ] **An object-literal argument is checked against an optional field (`field?: T`) as if the field were required whenever the argument literal itself omits that key, even though the target type declares it optional.** Minimal repro: `--:: Opts = { transport: Cap, policy?: PolicyFn }` then calling `M.new({ transport = t })` (omitting `policy` entirely, exactly what an optional field should permit) fails "missing field 'policy'" until the argument is passed with `policy = nil` explicitly assigned, or until the target type's field itself is written with `?:` (not `| nil`) — confirmed the difference is specifically `field: T | nil` (requires the key present, value may be nil) vs. `field?: T` (key may be absent) at the *type declaration* site, but even after switching the declaration to `?:`, one construction path in `lib/platform/apps/finance/sync_manager.lua` (`M.new`) still needed the field explicitly declared `?:` rather than `| nil` for the same omitted-key literal to typecheck — recorded here since it's easy to reach for `| nil` out of habit and get a spurious "missing field" instead. No code workaround needed once the declaration used `?:`; noting the distinction for future modules.

## Vendoring gaps

- [ ] **libtls vendored for Linux x86_64 only.** `dep/libressl/` carries the full LibreSSL 4.3.2 portable source (self-contained, no network needed to rebuild) and `dep/libressl/linux-x86_64/` has the built `libtls.so`/`libssl.so`/`libcrypto.so` (musl-linked, `$ORIGIN`-rpathed). `lib/tls/init.lua`'s loader only has a vendored-path case for Linux x64; macOS/aarch64/Windows fall through to the system-library search (bare `tls`/`libtls.dylib`/etc.), which will fail on a bare clone of those platforms since no system libtls is guaranteed. Follow-up: add `libressl-linux-aarch64`/`libressl-macos-arm64`/`libressl-windows-*` build jobs to `build-vendored.yml` (same shape as the `libressl-linux-x86_64` job) and extend `vendored_name()` in `lib/tls/init.lua` once those land.

## Typechecker substrate gaps (found while implementing lib/bookkeeping/account.lua, 2026-07-26)

- [ ] **`guard_check` narrowing (a user-defined type predicate, `(t: string) -> t is T`) does not narrow the argument at the call site when the predicate is bound to a table field, even if that field is first aliased to a local before being called.** Minimal repro: `M.is_t = function(t) return t == "a" or t == "b" end` (annotated `(t: string) -> t is T` where `T = "a" | "b"`), then `if not M.is_t(opts.type) then return nil, "bad" end; return opts.type` — the return still fails as `string` is not assignable to `T | nil`, even though the identical shape with `local function is_t(t) ... end` (or `local is_t = function(t) ... end`) narrows correctly. Also confirmed aliasing the field first (`local is_t = M.is_t`) does not help — the narrowing appears tied to how the predicate function itself was *declared* (`local`/`local function` vs. a table-field assignment), not to the call-site expression shape. Worked around in `lib/bookkeeping/account.lua` (`is_account_type`) by declaring the predicate as a `local function` and assigning it to the module table afterward (`M.is_account_type = is_account_type`), then using the local name for in-module calls that need narrowing (`M.add_account`, `M.is_debit_normal`). The public API (`M.is_account_type`) is unchanged; only in-module call sites needed the local. Revert to calling `M.is_account_type` directly once table-field-bound predicates narrow like local ones.

- [ ] **Narrowing an `unknown` value toward an *optional* target type (`T | nil`) via a nil-check followed by a nested (or compound `and`/`or`) type-check does not survive past the guarding `if` block, even though the identical shape narrowing toward a non-optional `T` works fine, and sequential atomic single-condition checks narrowing straight through to non-nil `T` (no `T | nil` merge involved) also work fine.** Minimal repro: `--: ({ rate: unknown }) -> (number | nil)`, body `local rate = li.rate; if rate ~= nil then if type(rate) ~= "number" then error("bad") end end; return rate` — fails with "cannot return `unknown`: value of type `unknown` must be narrowed before use (got unknown, expected `number | nil`)", i.e. the nested type-check's narrowing never reaches the join point after the outer `if rate ~= nil` closes. Confirmed the flattened compound forms fail identically: `if rate ~= nil and type(rate) ~= "number" then error(...) end; return rate` and `if not (rate == nil or type(rate) == "number") then error(...) end; return rate` (the latter also rules out a De Morgan gap specifically — `or`'s right operand isn't narrowed by the left operand's negation either: `--: (number | nil) -> nil`, `if rate == nil or rate <= 0 then error(...) end` fails "cannot compare `number | nil` with `<`" even with rate already declared `number | nil`, while the `and` analog `if rate ~= nil and rate <= 0 then` narrows correctly). By contrast, three sequential atomic checks (`if rate == nil then error() end; if type(rate) ~= "number" then error() end; if rate <= 0 then error() end; return rate`) narrow `unknown` cleanly through to non-nil `number`. Worked around in `lib/bookkeeping/journal.lua` (`build_line`) by resolving the nil-vs-not-nil split first, with each branch returning its own concretely-typed table literal (`rate = nil` literal vs. a `rate` already narrowed to plain `number` via atomic checks) instead of threading one shared `rate` variable typed `number | nil` through both branches — no line in the function ever needs an `unknown -> T | nil` narrow. No cast involved, so nothing to revert mechanically, but the two-return-literal structure can be collapsed back to a single shared-variable version once `T | nil` narrowing survives an `if`-block the way plain `T` narrowing already does.

## Typechecker substrate gaps (found while implementing lib/bookkeeping/import_ofx.lua and import_qif.lua, 2026-07-26)

- [ ] **Destructuring a 3-return local function's result (`local a, b, c = f()`) can leave any of the bound locals — not just the first — carrying the full 3-element return-tuple type instead of narrowing to its own element type, depending on how that binding is later used.** Minimal repro (`/tmp/repro2.lua`/`repro11.lua`/`repro12.lua` during this session, not committed — recreate from the description): given `--: string -> ({ [number]: row_t }, integer | nil, integer | nil)` and `local rows, truncated_at, trailing_bytes = parse_transactions(text)`, passing `rows` alone to a function expecting `{ [number]: unknown }` fails as "tuple is not assignable to table/array"; concatenating `truncated_at` with `..` after narrowing it non-nil can instead collapse it to `never` ("cannot concatenate type `never`"); and in another shape, the first binding alone was rejected in a `..` concatenation as "cannot concatenate type `(T1, T2, T3)`" — i.e. the wrong (whole-tuple) type surfaces differently depending on the consuming expression, but the root cause is the same: the destructured binding never fully narrows to its own positional element type. Worked around in `lib/bookkeeping/import_ofx.lua` (`M.string_to_entries`) by rebinding each of the three destructured locals through an explicit checked cast (`local rows = rows0 --[[: { [number]: ofx_row } ]]`, full subtyping verified, not a force cast) before using them; `lib/bookkeeping/import_qif.lua`'s equivalent call site did not reproduce this half of the bug (same destructure shape, no cast needed there — see the other entry below for what it did need), suggesting the trigger depends on surrounding code shape, not just the destructure itself. Revert the rebinding casts once a multi-return function's destructured bindings reliably narrow to their own element type regardless of how each is later consumed.

- [ ] **A local function with more than one `return` statement (i.e. any branching control flow) is rejected where an *optional* function-typed field (`(...) -> (...) | nil`) is expected on a cross-module call, even when its declared signature exactly matches — while a single-`return`-statement function with the identical declared signature is accepted in the same position.** Minimal repro (`/tmp/repro8.lua`/`repro9.lua` during this session, not committed — recreate from the description): `import.rows_to_entries(rows, j, chart, { ..., parse_date = twobranch, ... })` where `import_opts.parse_date: ((string) -> (string | nil, string | nil)) | nil` and `twobranch` is declared exactly `--: string -> (string | nil, string | nil)` with two `return` statements (one per branch) fails as "field 'parse_date': `(string) -> (string | nil, string | nil)` is not assignable to `(string) -> (string | nil, string | nil) | nil`"; a same-signature function with only one `return` statement (e.g. `local function myf(s) return s end`) passes in the identical call shape with zero errors. Worked around in both `lib/bookkeeping/import_ofx.lua` and `lib/bookkeeping/import_qif.lua` by rebinding the branching function through an explicit checked cast to its own declared signature (`local parse_date_fn = ofx_date_to_iso --[[: (string) -> (string | nil, string | nil) ]]`) before passing it as the table-literal field value. Revert once a multi-branch function's inferred type is recognized as assignable into an optional function-typed slot the same way a single-return function's is.

## Typechecker substrate gaps (found while implementing lib/pdf/object.lua, 2026-07-22)

- [ ] **A value narrowed from `string.find`'s `$FindReturn<P>`-derived return does not reliably keep its narrowed `integer` type: it sometimes satisfies `string.byte`'s overloaded (intersection) signature and plain arithmetic, and sometimes doesn't, inconsistently by call site.** Repro 1, `lib/pdf/object.lua` (`parse_dictionary_or_stream`, the `endstream`-scanning fallback for streams with an unresolvable indirect `/Length`): `local found = string.find(s, "endstream", pos, true); if found == nil then return nil, "..." end; local raw_end = found` — using `raw_end` (or even `found` directly) as an argument to `string.byte(s, raw_end)` fails overload resolution with "cannot pass `_` where `integer | nil` expected" / "cannot pass `_` where `integer` expected", i.e. both candidates of `byte`'s intersection type reject it, while the same value passes cleanly to `string.sub` (single, non-overloaded signature) and to plain arithmetic. Repro 2, `lib/pdf/xref.lua` (`find_startxref`): the structurally identical `local found = find(bytes, "startxref", search_from, true); if found == nil then break end; search_from = found + 1` fails instead with "cannot perform arithmetic on `integer | nil`" — this time arithmetic itself rejects the narrowed value, contradicting repro 1's observation that arithmetic is safe. Root cause not investigated; likely `$FindReturn<P>`'s narrowed member type carries an internal placeholder that isn't fully resolved to plain `integer`, surfacing differently (rejected by an intersection overload resolver in one call shape, rejected by arithmetic in another) depending on surrounding code the narrowing pass hasn't been observed to depend on in a legible way. Worked around at both sites with an explicit `--[[: integer]]` cast immediately after the nil-check (a same-type coercion, not a widening one — `found` is already `integer | nil` narrowed to `integer` at that point — so a normal checked cast, not `--[[:! T]]`, is correct and sufficient). Revert both casts when this resolves cleanly without them.

- [ ] **Calling `string.byte`'s overloaded (intersection) signature directly and using the result in a comparison inside a `while`/`break` loop spuriously narrows the result to `never` instead of `integer | nil`, breaking both the comparison and later arithmetic on it.** Repro in `lib/pdf/xref.lua` (`read_uint`): `while true do local b = string.byte(s, pos); if b == nil then break end; if b < 48 or b > 57 then break end; pos = pos + 1 end` reports "cannot compare `never` with `<`" on the second `if`, and the same shape inside PNG-predictor row decoding reports "cannot perform arithmetic on `never`". The identical two-step nil-then-range check pattern works with zero errors when the byte comes from a local wrapper function with a plain `(string, integer) -> integer | nil` signature instead of calling `string.byte` directly (confirmed both ways in isolated repros) — so the intersection type on `string.byte` itself is implicated, consistent with the sibling gap above (an overloaded stdlib signature's return value not surviving narrowing as cleanly as a plain function's would). Worked around in `lib/pdf/xref.lua` by wrapping `string.byte` in a local single-signature `byte(s, pos)` helper and calling that everywhere instead of the stdlib function directly. Revert to calling `string.byte` directly when this resolves cleanly.

- [ ] **Same `string.byte` never-narrowing bug, confirmed for a plain (non-loop) `if not b then return ... end` guard too (found while implementing `lib/locale/init.lua`'s `digits_to_system`, 2026-07-26).** Repro: `local b = string.byte(d); if not b then return d end; return b - 0x30` — arithmetic on `b` after the guard fails with "cannot perform arithmetic on `never`", even with no loop involved, ruling out `while`/`break` as a necessary trigger for this class of bug. Worked around by re-narrowing with a checked (non-force) cast immediately after the guard: `local bi = b --[[: integer]]`, then using `bi`. Revert to using `b` directly once `string.byte`'s narrowing is fixed (same underlying fix as the `while`/`break` entry above).

## Typechecker substrate gaps (found while implementing lib/pdf/text.lua, 2026-07-22)

- [ ] **Whether passing a value narrowed by a generic `(unknown) -> { [string]: unknown, [integer]: unknown }` helper (the `as_table` pattern every `lib/pdf/*.lua` file uses) into a function parameter typed as a specific record (e.g. `lib/pdf/init.lua`'s `Document = { bytes: string, entries: unknown, trailer: unknown }`) is flagged as a type error is inconsistent depending on the file it appears in, not just the code shape.** Isolated repro (`/tmp/repro_doc2.lua`, not committed — recreate from the description): `local as_table = function(v) if type(v) ~= "table" then error(...) end return v end` (declared `(unknown) -> { [string]: unknown, [integer]: unknown }`); `local doc = as_table(pdf.string_to_document(s))`; `pdf.resolve_reference(doc, ref)` — this reports `cannot pass { [string]: unknown, [integer]: unknown } where { bytes: string, entries: unknown, trailer: unknown } expected: missing field 'bytes'`. The same exact pattern (same helper body, same call shape, same target function `pdf.resolve_reference`) appears in the already-committed `lib/pdf/pdf_test.lua` (`T.describe("pdf: resolve_reference / resolve", ...)`, several `T.it` blocks) and passes `bin/cr check lib/pdf/pdf_test.lua` with 0 errors. The two are not obviously different: same helper signature, same call, only the surrounding file differs. Not yet root-caused — plausibly some form of per-file or per-call-count memoization of the inferred type of `as_table`'s return, or of `pdf.string_to_document`'s cross-`require` return type, that doesn't fire (or fires differently) depending on how many times the identical pattern recurs in one file. This is a soundness gap either way: the error is real when it fires (an index-signature type genuinely isn't assignable to a concrete record — that part of the check is correct) but its absence in `pdf_test.lua` means the same mistake would silently pass there. Worked around in `lib/pdf/text_test.lua` by not using the generic `as_table` helper for values with a richer known shape at all — a dedicated `as_document(v)` (and `lib/pdf/font_test.lua`'s pre-existing `as_font(v)`) narrows via a bare `type(v) ~= "table"` check followed by a *checked* (not forced) `--[[: T]]` cast to the concrete record, which the checker accepts cleanly and consistently. Generalize: **any new `lib/pdf/*_test.lua` file needing to pass a resolved `Document`/`Font`/module-specific record into another module's function should write its own single-purpose `as_<Type>` narrower this way, not reuse the generic `as_table` for that purpose** — `as_table` remains correct and necessary for genuinely-`unknown` PDF dictionary/array *contents*, just not for values whose real shape is already known.

## Typechecker substrate gaps (found while annotating lib/vt/init.lua, 2026-07-19)

- [ ] **A generic stdlib function instantiated at two different type arguments in the same file reuses the first call's resolved type variable for the second call.** Repro: declare `Cell = { char: string }`, `Line = { [integer]: Cell }`, `Grid = { [integer]: Line }`; in one file call `table.remove(line --[[: Line]])` and, anywhere else in the same file (same function or a different one — scope doesn't matter), `table.remove(grid --[[: Grid]])`. Whichever call is encountered first "wins": the second call is checked against the first call's resolved `V`, producing a spurious `missing field 'char'` (if Line resolved first) or `missing indexer for integer` (if Grid resolved first) error. Expected: each call site gets a fresh instantiation of `table.remove`'s `<V>`. Worked around in `lib/vt/init.lua` (`resize_grid`) by writing a local non-generic `pop(t: { [integer]: unknown, ... })` helper instead of calling `table.remove` twice at different types — `unknown` sidesteps the generic entirely since there is only one instantiation to solve. Root cause not investigated; likely a memoization/caching bug in how stdlib generic function types are resolved per-call-site (see `env.lua` instantiation caching, per the similar table-DAG-sharing bug logged elsewhere in this file for `instantiate_inner`).

- [ ] **Same class of bug as the `table.remove` entry above, confirmed for `table.sort` too (found while implementing `lib/pdf/write.lua`, 2026-07-22).** Minimal repro: `local a = {} --[[: { [integer]: { x: number } } ]]; table.sort(a, function(p, q) return p.x < q.x end); local b = {} --[[: { [integer]: number } ]]; table.sort(b)` — the second, comparator-less call fails with `cannot pass '{ [integer]: number }' where '{ [integer]: { x: number } }' expected`, i.e. `table.sort`'s generic element type was pinned by the first call and reused for the second regardless of shape. Worked around in `lib/pdf/write.lua` (`write_incremental_update`) by hand-writing an insertion sort over the `nums: { [integer]: number }` array instead of a second `table.sort` call. Revert to `table.sort(nums)` once generic stdlib functions are instantiated fresh per call site (same fix would resolve both this and the `table.remove` entry, since it's the same underlying mechanism).

- [ ] **The same once-per-file generic instantiation applies to PROJECT-DECLARED generics, not only stdlib ones (found while porting `lib/ffi-ir/csharp_pinvoke.lua`, 2026-08-04):** `lib/type-ir/init.lua`'s `resolve` is declared `--: <T>(kind: string, handlers: { [string]: T }) -> T | nil`. Calling it once with a `{ [string]: boolean }` handler map and once with a `{ [string]: string }` one, anywhere in the same file, fails on whichever call is checked second — "argument 2: cannot pass `{ [string]: string }` where `{ [string]: boolean }` expected: indexer value: cannot assign `string` to `boolean`", plus a knock-on return-type mismatch. Same mechanism as the three `table.remove`/`table.sort` entries above, so probably the same fix; logged separately because it establishes the bug is not specific to stdlib declarations. Worked around in `lib/ffi-ir/csharp_pinvoke.lua` by making the two single-entry lattice probes (`BOOLEAN_PROBE`/`STRING_PROBE`, the bool- and string-marshaling gates) `{ [string]: string }` maps tested with `~= nil` instead of the natural `{ boolean = true }` presence map tested with `== true`, so all three `resolve` call sites in that file instantiate `<T>` at `string`. Revert those two probes to booleans once each call site instantiates the generic freshly.

- [ ] **A checked cast from an open shape (`{ kind: string, ... }`) to a concrete variant whose `kind` is a string LITERAL is rejected, and testing `shape.kind == "resource"` first does not narrow the shape (found while porting `lib/ffi-ir/csharp_pinvoke.lua`, 2026-08-04):** `local s = ref.shape --[[: FfiResourceShape]]` (where `FfiShape = { kind: string, ... }` and `FfiResourceShape = { kind: "resource", name: string, methods: ... }`) fails with "field 'kind': cannot assign `string` to `\"resource\"`", and wrapping it in `if ref.shape.kind == "resource" then` — or binding `local s = ref.shape` and testing `s.kind` — changes nothing, since narrowing a field of an open record does not narrow the record. The TS source these backends are ported from does exactly this narrow-then-use, so every ffi-ir backend hits it at its four dispatch branches. NOT worked around with a force cast (`--[[:! T]]`), which would be wrong here. Worked around in `lib/ffi-ir/csharp_pinvoke.lua` by casting to kind-FREE structural views instead (`--[[: { name: string, methods: { [string]: FfiRef }, ... }]]`), which the checker accepts — the same idea `ffi_ir.lua`'s own `FfiFunctionLike` alias already encodes, and the same inline-structural-cast precedent `type_ref.lua`'s `resolve_ref` sets. Consequence: the emitted declaration's own `kind` is not re-checked at the cast, so the dispatch's `kind == ...` test is the only thing tying the branch to the shape. Revert those casts to the concrete `Ffi*Shape` aliases once a literal-`kind` discriminant narrows an open record.

- [ ] **Third occurrence of the `table.remove`/`table.sort` shape-pinning bug above (found while implementing N0 bracket-pair resolution in `lib/bidi/init.lua`, 2026-07-26).** `resolve_explicit`'s existing `table.remove(stack)` call (shape `{ level, override, isolate, char_index }`) pins the type; the new BD16 bracket-stack code's `table.remove(bstack)` call (shape `{ cp, k }`) then fails with `missing field 'level'`. Same mechanism hit `table.sort` when sorting the discovered bracket-pair list against the earlier `table.sort(RANGES, ...)` call's shape (`{ integer, integer, bidi_type }` vs. `{ integer, integer }`). Worked around in `find_bracket_pairs` (`lib/bidi/init.lua`) by hand-managing the bracket stack's length (nil-ing slots + a separate `bstack_len` counter instead of `table.remove`) and a manual insertion sort for the found-pairs list (bounded small: at most `BD16_MAX_STACK / 2` pairs per isolating run sequence) instead of `table.sort`. Revert both to the stdlib calls once generic stdlib functions are instantiated fresh per call site — same fix as the two entries above.

- [ ] **`table.remove` rejects a `{ [number]: V }`-typed array with "missing indexer for integer", even though `{ [number]: V }` should structurally satisfy `{ [integer]: V }` (found while implementing `M.delete_account` in `lib/bookkeeping/account.lua`, 2026-07-27).** Minimal repro: `local t = {} --[[: { [number]: string } ]]; t[1] = "a"; table.remove(t, 1)` fails with `cannot pass '{ [number]: string }' where '{ [integer]: _ }' expected: missing indexer for integer`. Distinct from the three `table.remove`/`table.sort` "generic pinned by an earlier call in the same file" entries already logged above — `account.lua` makes no other `table.remove`/`table.sort` call, so this isn't cross-call-site pinning; it reproduces standalone, on the very first and only call. Expected: since every `integer` is a `number`, a table whose declared index signature is `{ [number]: V }` already guarantees the narrower `{ [integer]: V }` contract `table.remove` asks for, so it should be accepted. Worked around in `M.delete_account` (`lib/bookkeeping/account.lua`) with a hand-written shift-left removal loop instead of `table.remove(chart.order, i)`. Revert once `{ [number]: V }` is accepted where `{ [integer]: V }` is expected.

- [ ] **A field assigned to a table *after* it has already been returned through an index-signature-typed (`{ [string]: unknown }`) return annotation retroactively becomes a required field, at its literal (unwidened) value type, of that table's type at its point of origin — and this attaches to the underlying mutable table itself, not to whichever reference/cast reached it, so even a fresh same-shape cast right before the assignment still fails (found while implementing `lib/pdf/form.lua`, 2026-07-22).** Minimal repro: `local function make() local t = {} --[[: { [string]: unknown } ]]; return t, nil end` (annotated `--: () -> ({ [string]: unknown } | nil, string | nil)`) and, in a separate function, `local d = make(); if d == nil then return end; d.V = 42` — `make`'s own `return t, nil` then fails typecheck against `{ V: 42, [string]: unknown } | nil`, even though neither `make` nor its annotation ever mentions `V`. Confirmed the pollution isn't scoped to the reference used to reach the table: re-casting the fetched value to a fresh local (`local d = d0 --[[: { [string]: unknown } ]]`) before the assignment still fails the same way, and even retyping the origin as bare `unknown` doesn't help. Likely the same underlying mechanism as the "table-DAG-sharing" class already logged in this file (a mutable table's inferred row type is shared globally across every alias of that table rather than scoped to control flow at the assignment site). Worked around in `lib/pdf/form.lua` (`fill_fields`) by never mutating a fetched dict in place: a `with_field(dict, key, value) -> new_dict` helper always builds and returns a brand-new table (the field write happens once, inside `with_field`, with no assignment surviving past its own return statement), and the caller (`apply_field`) replaces its cache entry wholesale rather than mutating an existing entry's `.dict` field. Revert to direct mutation (`dict.field = value`) once a table's inferred row type is scoped to the control-flow point of assignment rather than shared globally across every reference to the same table.

- [ ] **A destructured local from a multi-return call (`local x, err = f(...)`, guarded via `if not x then return ... end`) reverts to `f`'s full return-tuple type by the time it is reused after a large, branch-heavy loop later in the same function — reproducing regardless of which function `f` is, whether `f` is table-field-bound or a plain local, and regardless of textual distance between the guard and the later use (found while implementing period-based storage in `lib/bookkeeping/store.lua`, 2026-07-27).** Discovered building `M.load`/`M.load_period`, which need to read a `chart` and a `bookkeeping_journal` from the db and return both. Every combined-loader shape tried — destructured directly in `M.load`, factored into a shared `load_accounts`/`load_entries` pair of helpers, `book_currency`/`chart`/`j` passed as plain parameters instead of destructured locals, the reuse moved immediately next to its own guard — produced the same class of error at the point of reuse: `"tuple is not assignable to table/array"` on a `chart`/`j` argument, or `"(T | nil, string | nil) is not assignable to T"` on a `book_currency`/`j` use, even though the extracted helper functions report no error internally and their own annotated return types are correct. Confirmed via extensive bisection (see conversation/commit history around 2026-07-27) this is NOT the already-logged "generic pinned by an earlier call in the same file" `table.remove`/`table.sort` class two entries up in this file — minimal repros with two call sites and trivial function bodies pass fine; it only reproduces once the real, non-trivial bodies (loops, `db:query`/iterator calls, `opt_string`/`opt_number`-style narrowing helpers, cross-module `journal.post` calls that mutate their first argument in place) are involved, and a same-shape repro using a MUTATING cross-module call (mimicking `journal.post`'s mutate-and-return-entry behavior) still did not reproduce it standalone — so it needs the surrounding file's full complexity, not just mutation, to manifest. `--[[:! T]]` force-casting the polluted local at its use site was tried and is flatly rejected by the checker itself ("force cast has no overlap: tuple vs table" — the two shapes are reported as structurally disjoint, not merely unprovable), so this is not a case where a force cast is even available as a last resort. Worked around in `lib/bookkeeping/store.lua` by splitting "read rows as plain, non-journal-typed data" (`read_entry_rows`) from "construct a journal and post already-read rows into it" (`build_journal_from_rows`) — keeping the journal-typed value's entire lifecycle (construct, loop-post, return) inside one small function that never shares a scope with the DB-row-reading/account-loading loops, and inlining the `book_currency` config read directly inside that same small function (bypassing even the already-extracted `read_book_currency` helper, which itself still triggered the corruption when called from there) rather than accepting it as a parameter. Root cause not pinned down further given the scale of investigation already sunk into it; likely the same broad "whole-file/whole-function inference instability" phenomenon as the y_crdt `parity_fuzz_test.lua` entry elsewhere in this file (unrelated code shape perturbing a distant variable's narrowing), but is its own distinct instance/trigger, logged separately since the trigger conditions differ. Revert `lib/bookkeeping/store.lua`'s split back to a single combined read-and-post loader once this resolves.

- [ ] **A value typed only by an index signature (`{ [string]: unknown }`, no named fields) is inconsistently accepted where a struct with required named fields is expected, depending on which function is called — sometimes accepted (arguably unsoundly), sometimes correctly rejected — for the exact same value (found while implementing `lib/pdf/form_test.lua`, 2026-07-22).** Repro: with `local doc = as_table(pdf.string_to_document(bytes))` (`as_table: (unknown) -> { [string]: unknown, [integer]: unknown }`, so `doc`'s static type has no named fields at all), calling `pdf.resolve_reference(doc, ref)` or `pdf.document_root(doc)` — both declared `(Document, ...)` where `Document = { bytes: string, entries: unknown, trailer: unknown }` — typechecks with zero errors, while calling `form.document_to_fields(doc)` (declared `(FormDocument, ...)`, `FormDocument` being a separately-named but structurally identical alias) fails with "cannot pass `{ [string]: unknown, [integer]: unknown }` where `{ bytes: string, ... }` expected: missing field 'bytes'" — the technically-correct rejection, since an index signature never guarantees a specific field is present. Ruled out alias-name collision as the cause: renaming `form.lua`'s alias to a project-unique name did not change the result either way (confirmed with `lib/pdf/font.lua`, a same-named `Document` alias belonging to a concurrently-developed sibling module, also not implicated — same result with and without it renamed). Root cause not investigated further; likely `pdf.resolve_reference`/`pdf.document_root` benefit from some accidental leniency specific to their call shape (both are declared in the same file, `lib/pdf/init.lua`, as the `Document` alias itself) rather than `form.document_to_fields`'s rejection being wrong — i.e. the two `lib/pdf/init.lua` functions passing may itself be the unsound side worth double-checking, not a false rejection to route around. Not worked around by relaxing `form.document_to_fields`'s signature (that would legitimize passing genuinely under-typed values); instead, `lib/pdf/form_test.lua`'s fixtures load documents via a `load_doc(bytes)` helper that nil-checks `pdf.string_to_document`'s result directly and returns it without erasing its type through `as_table`, preserving the named-field type real callers should be constructing anyway. If `lib/pdf/pdf_test.lua`/`lib/pdf/write_test.lua`'s existing `as_table(pdf.string_to_document(...))` pattern turns out to be the unsound side once this is investigated, they should be changed to the same `load_doc`-style direct nil-check instead of `as_table`.
- [ ] **`type(x) == "number"` narrowing widens an already-`integer`-typed value back to `number` inside the narrowed branch, discarding known precision.** Repro: `--: (integer) -> nil` function body does `if type(cols) ~= "number" then error(...) end` (a defensive runtime guard over an already-statically-typed param), then later assigns `some_integer_var = cols` — fails with "cannot assign `number` to `integer`". Since `cols` was already `integer` (a subtype of `number`) before the check, `type(cols) == "number"` provides no new information and should be a no-op, not a lossy re-narrow to the wider type. Worked around in `lib/vt/init.lua` (`M.new`) by re-asserting the precise type through `floor()` (`self._cols = floor(cols)`), which is also a reasonable defensive measure in its own right (rejects non-integer floats) but shouldn't be *required* just to satisfy the checker.

## Typechecker substrate gaps (found while implementing lib/http/server.lua response_stream + request origin, 2026-08-04)

- [ ] **A dot-form field assignment whose target is an upvalue or a parameter, written inside a function body that carries a `--:` signature, resolves its expected type to the *enclosing function's* type instead of the field's type.** The RHS is then reported as unassignable to a function type. Minimal repro (0 errors expected, 2 reported):
  ```lua
  --:: T3 = { flag: boolean, doit: (self: T3) -> unknown }
  --: () -> T3
  local function a()
      local c = { flag = false, doit = nil }
      --: (self: T3) -> unknown
      function c:doit() self.flag = true; return true end   -- error: cannot assign `boolean` to `(...) -> unknown`
      return c
  end
  --:: T4 = { flag: boolean }
  --: (T4) -> nil
  local function outside(t) t.flag = true end               -- error: same shape
  ```
  The bracket form of the identical assignment (`t["flag"] = true`) is unaffected and typechecks clean, which is what pins this to assignment-target resolution rather than to the field type itself. A field assignment to a local declared *inside* the same function body is also unaffected — which is why most existing library code never trips it. Worked around in `lib/http/server_origin_test.lua` and `lib/http/server_stream_test.lua` (socket mocks: `log["closed"] = true` where the natural code is `log.closed = true`); both sites carry `-- TYPECHECKER WORKAROUND:` comments. Revert both to the dot form once assignment targets resolve against the field.

## Typechecker substrate gaps (found while implementing lib/http/server.lua WS upgrade, 2026-07-20)

- [ ] **Arithmetic on integers produces `number`, not `integer`, requiring force cast.** In `lib/http/server.lua` `ws_frame_byte_count`, 64-bit payload length is computed as `hi * 0x100000000 + lo` where both operands are `integer`. The result type is `number` even though the expression is provably integral. A `--[[:! integer]]` force cast is required to satisfy callers that need `integer`. Same gap as `lib/websocket/frame.lua:197`. Revert the force cast when the typechecker can narrow arithmetic on integers back to `integer`.

## Typechecker substrate gaps (found while fixing CI failures, 2026-07-10)

- [ ] **A bare `...T` (no enclosing parens) as a `--:` return-type expression silently fails to parse and falls back to "no signature."** Repro in `lib/encode/utf8/init.lua`: `--: (...) -> ...number` (or `...unknown`) produces the `has no signature — add a ... annotation` warning as if the line weren't there at all, and downstream param types lose their narrowing (spurious unrelated overload-resolution errors appear on `string.byte` calls in the body). Wrapping the same variadic in parens, `(...number)`, parses fine and the narrowing-dependent errors disappear. The parser should either accept bare `...T` in return position or hard-error on it — silently discarding a written signature (turning it into a no-op) is the dangerous failure mode: the file looks annotated but isn't.
- [ ] **A return-type union combining a variadic tuple arm with a fixed tuple arm, e.g. `(...number) | (nil, string)`, rejects a plain single-value `return b`/`return c` even though `integer` is a valid member of the first (variadic) arm.** Error was `integer is not assignable to ...number | (nil, string)`, i.e. the union isn't decomposed into alternatives before checking a return statement against it. Worked around in `lib/encode/utf8/init.lua`'s `mod.codepoint` by widening the declared return to `(...unknown)` instead — real fix needs the checker to try each arm of a return-type union independently.
- [ ] **Inline `--[[: T]]` parameter annotation is silently ignored on a self-recursive `local function`.** Repro: `local function f(n, collect --[[: { [integer]: integer } | nil]]) ... f(n-1, collect) end`, then call `f(3, nil)` from one site and `f(3, some_table)` from another. The annotation on `collect` has no effect — the checker still infers `collect`'s type monomorphically from the first call site it sees (here, the literal `nil` from the first-analyzed caller), then rejects the second, differently-typed call site with "cannot pass `T` where `nil` expected". A full `--:` signature placed above the function (rather than inline on the parameter) *does* take effect correctly (verified with the same repro). Worked around in `lib/sat/init.lua` (see `dpll`) by annotating the `nil` literal at its call site instead of the parameter, which avoids the bug without touching the recursive function's signature. This is a real substrate gap — inline param annotations should carry the same weight as a full signature — not something to special-case around in library code.
- [ ] ## TAG_SPREAD: spread-of-type disambiguation (deferred)

  Three cases of `...(T)` live in the codebase, currently conflated:

  1. **Spread of scalar** — `...(T)` where T is a plain type. Should mean exactly one value of T, rest nil. (What the failing test expects, what `docs/tag-spread-spec.md` documents.)
  2. **Spread of array** — `...{[integer]: T}`. Should mean 0+ values of T (unbounded variadic). Needed by `unpack`, `string.byte`. **Parser can't parse this in return position today** — needs extending.
  3. **Spread of union-of-tuples** — `...(PcallReturn<F>)`, `...($FindReturn<P>)`. Currently works via `ctx._multi_ret` + `narrow.lua:filter_tuple_union_arms`, not via `eager_slot`. Load-bearing for pcall/xpcall/string.find/io.open narrowing.

  ### Blockers
  - Parser: `...{[integer]: T}` not parseable in arrow-return position (hardcoded `...(` at `ann.lua:355-363, 432-440, 1153-1161`)
  - `eager_slot` (`constrain.lua:2944-2946`): returns `spread_inner(t)` unconditionally for all slots — treats case 1 like case 2
  - `solve_return` (`solve.lua:2917-2960`): body-side checking also treats all `...(T)` as unbounded — symmetric with caller-side. Fixing one without the other makes them disagree.
  - Case 3 preservation: the `ctx._multi_ret` + narrowing mechanism must be explicitly preserved or redesigned when cases 1 and 2 are split.

  ### Design intent
  `...` is a generic spread operator over types. Container shape determines return arity. `...{[integer]: T}` for variadic returns. Stdlib annotations (`unpack`, `string.byte`) update to use array spread once parser supports it.
- [ ] **static-v4: `string.match`/`gmatch`/`find` stdlib declarations mis-declare arity, causing a spurious `call-arity` error (cascading into `undefined-name` for destructured captures) on ordinary 2-arg calls.** Repro: `local a, b = string.match("x=1", "(%a+)=(%d+)")` — legacy accepts (0 errors); `bin/cr check --v4` rejects with `call: arity mismatch — expected 3 argument(s), got 2` at the call site, then `undefined name a`/`undefined name b`/etc. at every use of the destructured locals. This is the documented-but-still-open gap in `lib/type/static-v4/README.md` ("Known degradations": `string.match`/`gmatch`/`find` declare a fallback type pending the `$PatternReturn`/`$FindReturn` walker hook) — the fallback apparently declares the optional third `init` argument as required. Used as the "legacy accepts, v4 rejects" fixture in `lib/type/static-v4/cli_compare_test.lua` (replacing a stale fixture for a table-literal divergence that landed and stopped diverging); update that test's fixture again once `$PatternReturn`/`$FindReturn` lands and this call stops erroring.
- [x] **`check_string`/`check_file` with `opts.globals_files`: a globals file with >= 19 leading plain `--` comment lines before its first `--::` annotation silently disables argument-type checking for everything the file declares.** FIXED. Root cause was NOT leading-comment-line-count itself, and NOT `check_string`/`check_file` — it was `prelude.lua`'s `load_decls` (the `opts.globals_files` loader), specifically Pass 2a's alias-body resolution order. `load_decls` collected `ANN_DECL` results by iterating `ar.results` (keyed by absolute source line number) with Lua's `pairs()`, which yields hash-part traversal order — a function of the specific line-number integers present, unrelated to declaration order, and non-monotonic as leading-line-count shifts (matching the originally-observed "18 ok / 19–29 broken / 30 ok / 31+ broken" banding exactly). `env_mod.resolve_named_type` (env.lua) resolves a type alias **eagerly** — `return alias.body` is a snapshot, not a lazy reference — so if Pass 2a happened to process an alias (e.g. `DomCtor`) before an alias it references (`Props`) purely by accident of hash-bucket layout, `DomCtor`'s resolved body permanently captured the Pass-1 placeholder (`T_ANY`) instead of the real `Props` record, silently degrading every parameter typed `Props` to `any`. Every real `*_types.lua` file in the repo declares aliases in dependency order (referenced-before-referencing), so this only needed resolution order to *match declaration order* to be correct — not full topological/lazy resolution. Fix: added `decl_lines` (table-reference-keyed) tracking alongside `decls` collection in `prelude.lua`'s `load_decls`, then `table.sort(decls, ...)` by source line before Pass 2a — mirroring an identical, already-existing fix pattern in `constrain.lua`'s `process_type_decls` (the same-file, non-globals-file `--::` decl path already had this sort; the globals-file path did not). Also fixed a related-but-distinct hygiene gap while in the area: `ctx._ann_consumed` (bare-line-number-keyed, tracks which preceding-line annotations were consumed) was swapped in lockstep with `ctx.ann` in `process_type_decls`'s callers but not in `prelude.lua load_decls` or `constrain.lua load_decl_file` — fixed both to save/restore it alongside `ctx.ann`, preventing a real (separate) cross-file line-collision hazard even though it wasn't the cause of this bug. Verified: minimal single-file repro (ruling out cross-file collision) now resolves correctly across leading-line counts 0–40; `projection_types_test.lua` passes (38/38); `bin/cr check` on `prelude.lua` and `constrain.lua` shows zero error/warning-count regression (git-stash before/after diff); `bin/cr test lib/type/static/` clean except the pre-existing TAG_SPREAD failure (see above). This does not make genuine forward references (an alias used before its own later declaration) sound — that would need topological or lazy alias resolution, a deeper change, not needed by any current caller.

## v5 substrate program — Phase 2 implementation

Phase 0 (CLAUDE.md guardrails) and Phase 1 (three normative specs) are committed to the repo. What follows are the Phase 2+ implementation threads.

Specs in force:
- **Spec A** (simple-sub bounds — faithful-flow + canonical + eager): `docs/typechecker-v5-operational-semantics.md`, commit `26ef57a8`.
- **Spec B** (match types + TPack variadic packs): same doc, commit `c06b1ac6`.
- **Spec C** (TLiteral + TRecord three-region shape, no `$`-string encodings): `docs/type-system.md` + op-sem doc, commit `7a627c26`.

Lower-priority open gaps (G2/G4/G5/G10 substrate, G6 `__index`, P5 ann-surface features, eager-depth-limit, the two-positional-encodings smell, resume-side S narrowing) are tracked in `docs/v5-gaps.md` — read that file rather than relying on this section for exhaustiveness.

### Thread 1: Implement Spec A bounds in op_sem.lua + op_sem_alt.lua (closes R1 + bounds-spec-gap)

Spec A defines a faithful-flow bound-graph (subtyping is a directional edge; equality merges via union-find; multi-bound / transitive / polar / var-flow / cyclic-bound paths all specified). The dual-interpreter premise (op_sem.lua and op_sem_alt.lua are independent encodings of the same spec, never derived by copying between them) was vindicated by R1's finding that they had drifted. Both must be implemented from the spec independently.

The prior ~80 fixtures never exercised multi-bound / transitive / polar / var-flow / cyclic paths — new parity fixtures covering those paths are part of the deliverable.

Open question: the bound-graph coexists with union-find (equality merges, subtyping is directional). The spec defines it; implementation is unproven. Termination leans on a mandatory structural-hash cache. Verify termination properties empirically on the new fixture set, not just on the existing ones.

### Thread 2: Implement Spec C encodings (closes prefix-scoping)

TLiteral node + TRecord three-region shape (fields with optional/readonly attributes, `indexes[]`, `row`); delete every `$`-string-match and key-prefix-scan that substitutes for a proper node.

Touches all record field-walkers: shift, instantiate, equal, collect_uvars, and subtype rules. Worth mapping all walkers before starting to avoid half-migrations.

### Thread 3: Implement Spec B substrate (heaviest piece)

match_type node + CMatchEval constraint + TPack + arrow variadic-pack redesign + effect-pattern matching. The arrow/TPack redesign is the heaviest sub-piece (every arrow producer and consumer changes). Spec B is the substrate that other features build on.

### Thread 4: Re-express pcall/coroutine/pairs/ipairs as stdlib declarations; delete the handlers (closes adhoc-cluster + Y1; delivers G17)

<!-- Cross-reference (2026-05-29): This thread is the crescent instance of an ecosystem-wide pattern. Concrete artifacts for the record: `static/solve.lua` 16-handler per-constraint-kind dispatch table (`get_handlers` at solve.lua:3993, e.g. solve_index ~665 LOC, solve_overlap ~517 LOC); the `$`-intrinsic if-chain (`intrinsic.lua:912 M.expand`). The v3→v5 migration is the canonical worked example of the ecosystem anti-pattern — N parallel name-keyed dispatch tables where one visitor/registry belongs. Already fully tracked here and in lib/type/static/CLAUDE.md; this note is a cross-reference only, not new work. -->

Targets: build_pcall_ret, build_coroutine_create_ret, coroutine.* branches, extract_idx, name-keyed dispatch, `!throw`/`!yield` string-matches. After the deletion, a re-run of the adversarial ad-hoc sweep must come back empty for the AD-HOC category, and a grep must show zero `name == "$X"` / name-keyed dispatch in constrain.lua/op_sem.lua. This is the payoff — the ad-hoc dies here.

- [x] **Phase 2.4.5 — call-site declared-return instantiation + per-call-site match lowering (ENABLING SUBSTRATE for Thread 4).** Built the missing, name-agnostic mechanism that lets a stdlib declaration carry a return type depending on its arguments — the precondition Thread 4 needs before it can re-express pcall/coroutine.* as ordinary declarations and delete the handlers. Mechanism: a `TParam(idx)` parameter-reference leaf (mirrors `TCapture`; not De Bruijn-relocated) + `types.subst_params` / `types.has_param` (`lib/type/experiments/v5_perf/types.lua`); a shape-gated gen-pass rule (T-CallInst) in BOTH call paths of `constrain.lua` (single-value `NODE_CALL_EXPR` + multi-value `gen_expr_multi`) that, when `has_param(callee.ret)`, substitutes actual arg types into the declared return, `lower_matches` per call site, and CSubs with no raw TMatch crossing the constraint. Reuses the existing CMatchEval Park/Reduce/Wake/Stuck machinery — NO new interpreter rule, so no copy across op_sem.lua/op_sem_alt.lua. Also added shape-driven for-in (T-ForIn-Shape: declared-return arity / index signature, beside the pairs/ipairs name cases). Effects need no new substrate (App+Const already suffice; the `!throw`/`!yield` string-match sites are a 2.5 consumer concern). Did NOT delete any handler (that is 2.5); all existing fixtures stay green. Proof tests: `lib/type/static-v5/decl_instantiation_test.lua` (20 assertions — disc(true)→string, disc(false)→integer at distinct call sites, reject cases, identity-of-arg, for-in index-sig + declared-return-arity) + `types_row_substrate_test.lua` (TParam/subst_params/has_param units, +27) + `op_sem_independent_parity_test.lua` `indep parity: 2.4.5` fixtures (+22, reduce/stick/park-wake parity). Normative design recorded in `docs/typechecker-v5-operational-semantics.md` §"Call-site declared-return instantiation (TParam + subst_params) — Phase 2.4.5".

### Thread 5 (SEQUENCING FORK — unresolved): Phase ordering of Spec B vs Spec C

The approved program plan listed P3 (Spec C) before P4 (Spec B), but Spec C's positional/tuple migration depends on Spec B's TPack. TPack must land before Spec C's positional work. The next session should re-plan Phase 2 ordering to respect substrate-before-consumers (a CLAUDE.md planning rule now). The fork: either (a) carve out a TPack-only slice of Spec B that lands first, or (b) fully complete Thread 3 before Thread 2. Both are valid; the choice has downstream ordering consequences that need to be mapped.

### Verification discipline

Op-sem parity must hold at every commit. After the handler deletion, the adversarial ad-hoc sweep must return empty for the AD-HOC category; a grep must show zero `name == "$X"` / name-keyed dispatch in constrain.lua/op_sem.lua.

---

## Typechecker v5 follow-ups

> **Comprehensive state snapshot lives at `docs/typechecker-v5-handoff-2026-05-25.md`** — read that first. It covers artifacts + LOC, architecture, load-bearing invariants, falsifiability gates passed, 16 named spec gaps with sources + severity, all open H-questions, cross-cutting risks, methodology rules. The threads below surface high-signal items as starting context but don't capture the full picture.

### High-severity open threads (constraint families)

- [x] **CMultiReturn (spec gap G7)** — DISSOLVED 2026-05-25. No separate constraint family. Multi-return is positional Record on `Arrow.ret`; T-CSub-Record's positional-key dispatch (covariant) handles union-arity and nil-padding. Commits: `2ce1e591`, `07afc26a`, `720a9f6c`, `c9e018b9`. Parity count 146 → 187.
- [ ] **Gen-pass invariant: over-arity discard before CSub emission** — when a call site returns more slots than the LHS expects, gen-pass must emit a positional Record with only the expected slots. Emitting the full record and letting T-CSub-Record discard extras would present the solver with a width mismatch it cannot distinguish from a type error. Track when gen-pass work begins.
- [x] **CRow + CEffect unified extension (G8 + G12)** — CLOSED at op-sem layer 2026-05-26. CRow: CRowExtend/Lacks/Close constraint atoms + rules (commits `7f7d4d6c`, `b1825484`). Effects dissolved into TConst("!name") + TIntersection; CIntersectionEq/Sub/Member with canonical form (commit `c600a446`). Parity 187 → 275. NOT YET observable from user code — source pipeline (parser + gen-pass) not wired.
- [x] **v5-source-pipeline-integration** — CLOSED 2026-05-26. ann.lua, constrain.lua, stdlib_types.lua, cli.lua, `bin/cr check --v5` wired end-to-end. Commits: `52fcae6f`, `0ff434aa`, `6da6db59`, `317acc9b`. 275 → 504 assertions. Six open gaps remain (P1–P6); see handoff and items below.
- [x] **Gap P1: dotted callee effect propagation broken** — `io.write(...)` has a uvar callee at gen-pass time; `!io` is never extracted. F2 enforcement does not fire for dotted stdlib calls. Only direct-bound names propagate effects. Highest-priority source pipeline fix. (closed: 5.F1 a32b0a74 — fixture "5.F1: annotated () -> nil calling io.write (dotted) surfaces F2 error" in cli_e2e_test.lua)
- [x] **Gap P2: pcall return type is flat `boolean | unknown`** — correct form is discriminated `(true, R...) | (false, E)`. Requires variadic generics (G17) first. (closed: 5.F2 05fd0777 — special-cased at gen time; fixture "5.F2: pcall on throwing fn in annotated pure fn is clean" in cli_e2e_test.lua)
- [x] **Gap P3: coroutine.create returns unparameterised `thread`** — full `Coroutine<Y,S,R>` parameterisation deferred; requires G17 or a specialised constraint family. (closed: 5.F3 656c8596 — special-cased at gen time; fixture "5.F3: coroutine.create consumes !yield — pure outer fn is clean" in cli_e2e_test.lua)
- [x] **Gap P4: Arrow subtyping defaults uvar to CEq at S-Quiesce** — proper bounded-tvar tracking (G9) is deferred; may reject valid programs. (closed: 5.F4 93311447 — bounds substrate + meet-at-quiescence; fixture "5.F4: two distinct upper bounds — meet via intersection" in op_sem_bounds_test.lua)
- [ ] **Gap P5: ann surface forms not wired to gen-pass** — type predicates, match types, newtype, augment, pattern types: parsed but not emitted as constraints.
- [ ] **Gap P6: closure-as-value and method dispatch not modelled** — constrain.lua handles straight-line code; closures in tables, `:` dispatch, upvalue capture narrowing unhandled.
- [ ] **5.F3 residual: resume-side S narrowing incomplete** — `coroutine.resume(co, s)` does not bind `S` from the send argument's type; the `Coroutine<Y,S,R>` `S` parameter remains a free uvar. Yield and create typing are correct; resume is under-constrained on the send side.
- [ ] **5.F4 residual: compatible-bound intersection reduction not implemented** — under-constrained uvars accumulate upper bounds as `TIntersection` nodes at quiescence. Compatible bounds (e.g., `integer & number → integer`) are not yet reduced. Orthogonal to the meet-at-quiescence landing; fix is in the intersection-reduction pass.
- [ ] **G17: variadic generics** — accurate typing of `pcall` / `coroutine.resume` requires variadic generics (function-argument pack and return-pack typed through the pcall/resume boundary). Current v5.0: pcall returns `(boolean, unknown)`. Needs orchestrator design decision before implementation. Severity: low-medium. Not blocking v5.0 stable.
- **CImpl (let-poly with implication wanteds)** — OutsideIn-style scope discipline. Op-sem has `CInst` but not `CImpl`. Open: do we need GADTs at all? Roadmap H5 closed "GADT-strength flow typing out of scope," suggesting CImpl can be lighter than OutsideIn's full version.

### High-severity open threads (productionisation)

- **Realistic-scale perf is a hypothesis.** Architecture targets ~10⁵ constraints; tested at <500. Re-gate at scale during each constraint-family landing, or build a synthetic-load extrapolation harness explicitly.
- **Gen-pass connection to real Lua AST not started.** Op-sem currently takes hand-emitted constraints. Bridging to the existing parser is its own multi-cycle phase. Open: build a fresh extractor or adapt the v4 walker?
- **Substrate promotion from `lib/type/experiments/v5_perf/` to `lib/type/static-v5/`** is owed once op-sem hardens. Cleans the namespace.
- **Dead v5_perf scaffold builds records with the pre-2.3 raw-value contract.** `lib/type/experiments/v5_perf/solver.lua` (untouched since the pre-2.1 scaffold `6bbe20a4`) and `lib/type/experiments/v5_perf/bench_chkt.lua` (plus `bench.lua`) still construct `TRecord` fields as RAW `V5Type` values — `types_mod.record({ [k] = ty })`, `b.fields[k] = c.ty`, `existing = b.fields[c.key]` treating field values AS types. The v5 2.3 reshape (`f0a9e10b`) made each `TRecord` field a `TField = { type, optional, readonly }` (built via `types.field(...)`), and `subst.walk`'s record arm now recurses into `fv.type`. These files predate 2.3 and were missed by the follow-up migration (`0ca0c8ed` only fixed `types_row_substrate_test.lua`). Under the 2.3 contract the bench records are inconsistent and would crash `subst.walk` (it indexes `fv.type` on a nil) if ever walked. **Not on the live path** — `solver.lua` is required only by `bench.lua`; nothing in `bin/cr`, the static-v5 interpreters (`op_sem.lua`/`op_sem_alt.lua` require `types/subst/constraint/variance`, never `solver`), or any `*_test.lua` depends on them; `bench.lua` is the old harness superseded by `bench_chkt.lua`. No test exercises them, so the inconsistency is uncaught. Migrate to the `TField` contract or delete when `v5_perf` is next touched (likely folds into the substrate-promotion item above).
- [x] **Constraints catalog at `~/.claude/plans/radiant-gathering-gray.md` is outside the repo.** Durability risk. Relocate to `docs/typechecker-v5-constraints.md` or similar. Tiny task. — Landed in repo at `docs/typechecker-v5-constraints.md` (recovered from session transcript; original was overwritten in-place).

### Pre-stable follow-ups

- [ ] **Exhaustive prior-session mining.** Sampled pass found 5 multi-session arcs (`docs/typechecker-v5-research-report.md` §2); exhaustive pass owed. Particular value: scheduler-shaped problems, mechanisms previous attempts found load-bearing vs accidental.
- [ ] **Adversarial missed-generalisation eval** (v5 item 6 follow-up). Generate Lua snippets that the no-level-lowering discipline (Lean-style) rejects but Rémy lowering would accept. Classify idiomatic/rare/pathological. Revisit lowering as perf opt if idiomatic.
- [ ] **Lazy De Bruijn shift experiment** (v5 item 2 follow-up). After everything stable, benchmark lazy (Lean/Coq sliding-window) vs eager-shift baseline. Low prio.
- [ ] **Circular `require` corpus check.** v5 rejects circular `require` at typecheck. Grep `lib/` — if any are load-bearing, revisit before declaring v5 stable. Likely fine.
- [ ] **Property-based parity** (independent-encoding parity follow-up). Generate random constraint sequences; run both interpreters; catches rule-priority divergence fixed fixtures miss.

### Spec doc clarifications (low prio, surfaced by independent-parity agent)

- T-CSub dispatch priority not formally enforced — chose TVar-before-Refl interpretation; doc could lock this in.
- T-CTSet four-way cascade order not formally enforced — current dispatcher's if/elseif order is a reconstruction.
- T-CHKT-Reduce chain peel depth not formally specified — implementation peels up to `length(args)` binders.

### Post-stable

- [ ] **Investigate `setmetatable(t, nil)` support** (v5 item 5 backlog). Medium prio. Sandboxing's strongest use case served by fresh-table pattern. v5.x decision may be "document fresh-table as canonical idiom; never support setmetatable(t, nil)." If supporting it: open question whether monotone substitution can be preserved.

## Session-level open threads — v9/typechecker endgame (2026-07-04)

*Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

- **Owner verdicts that likely gate everything in the v9 section below.**
  Autonomous agent-orchestrated development of the typechecker was declared
  dead by owner verdict — supervision cost exceeded value; the owner drives,
  agents act only as directed hands on explicitly pointed-at work, no
  self-initiated roadmap-grinding. The parity-race framing is dead with it.
  Half-products (e.g. a "complementary linter beside the legacy checker") were
  explicitly rejected — full replacement of the legacy checker remains the
  only end-state that counts. v9 measured NOT viable as a tool today: a
  stratified 30-sample measurement found ~3% hard-true / ~27%
  true-plus-discipline precision on bug-classes-only output. Volume looked
  workable (426k -> ~16k with aspiration dials off, median 1/file) —
  precision is the blocker, not volume.
- **The owner's compression criterion — plausibly the evaluative lens for any
  future core work.** "A grind is the smell of a fundamental failure in the
  core": a correct core makes cases corollaries. Judge a core by (a)
  per-construct cost small and roughly flat (~10 lines suggests spec; ~100
  suggests the core leaking), (b) each recurring false-positive class
  dissolving under exactly ONE mechanism, (c) work that stops compressing =
  wrong core, stop. The owner's earlier "≤3000 lines" remark reads as a
  Kolmogorov-size estimate for a Lua checker, not a budget. Session evidence
  seemed consistent with it: every large diagnostic-count drop came from one
  mechanism landing, never from case-grinding, and the 22 measured false
  positives concentrate in 4 mechanism classes.
- **The never-run design campaign — the main identified open thread; NOT yet
  authorized.** The mutation × flow-sensitivity × syntax meeting point —
  where every iteration died — apparently never received design-it-twice
  treatment in any of the 9 iterations (the proof-dev characterized then
  parked the narrowing×multivalue fork in
  `docs/decisions/precise-narrowing-and-the-multivalue-model.md`; v9's
  lowering accreted mechanism-by-mechanism while only the easy engine got the
  full design discipline). The design object, if ever pursued: one
  COMPOSITIONAL account of mutation × flow-sensitivity × multi-values ×
  self-reference over Lua's ~30 forms. Acceptance tests already exist — the
  four measured FP mechanism classes: self-type/recursive-alias method calls,
  definition-order forward locals, cross-function/callback mutation,
  colon-method annotation self-binding (this last is a repro'd v9 BUG, likely
  worth fixing regardless of any campaign). Metric: the compression criterion
  above. Status: identified as designable and well-posed; the owner has NOT
  greenlit it, and it may be moot if the owner walks away.
- **v9 feasibility condition — hyper-modularity (owner thesis, with session
  evidence for it).** Units may need to be sized to a single agent's
  full-reasoning span: the engine (121 lines, seamed) saw zero churn and zero
  breakage across all increments; lower.lua (a ~3k-line closure) was the
  most-edited file in every increment and all churn and failures lived there
  (it also brushed the 92/200 Lua locals ceiling). Any future agent work on
  the lowering interior probably gates on restructuring it into per-construct
  units around a small explicit core — but weigh the counter-evidence:
  multiple prior "tiny clean core" versions never proved themselves; the
  clean core is the easy part, and cleanliness of the core ≠ viability.
- **Banked findings possibly worth acting on regardless of any typechecker
  decision.** FIXED 2026-07-04 (all lib-code items): linux/proc EOF/malformed
  nil-crash class (unguarded `f:read` into `match`/`gmatch`, plus nil-key
  writes in meminfo/vmstat/net.dev — meminfo crashed on any /proc/meminfo
  field missing from `name_to_key`); markdown:263 and ini:59 nil-receiver
  string methods; chacha20-test tonumber-nil; mimetype/by_contents annotation
  now tells the truth (`-> (string | nil, string | nil)`), force-casts in
  mimetype/init.lua dropped, and fixing it exposed a REAL behavior bug: both
  http/router/static.lua and static_full.lua served the first return (the
  extension, e.g. "png") as Content-Type instead of the mime string — fixed
  and verified end-to-end. keyring:778 / server_ws:56 needed no code change
  (v9 diagnostics that resolved once `T | nil` annotations were read; the
  code was correct). Still open — two LEGACY-checker bugs (typechecker work,
  gated by owner direction): mixed named/unnamed `--:` param spelling
  mis-infers unrelated distant code to `never`; and the
  forward-declared-local cross-file contamination (tracked in the v9 section
  below; repro not yet reduced).
- **Semantics-linter thread (2026-07-05, owner-driven).** Definition + architecture
  conversation state in `docs/semantics-linter-working-notes.md` (NOTHING greenlit;
  one OPEN owner objection — "seems wrong" on the hyperproperty framing — must be
  re-derived before anything is built on it). Session postmortem (why sessions run
  long; how ad-hocness enters — at contact) in
  `docs/postmortem-agentic-sessions-2026-07.md`, primary-source line refs included.
  Identified-not-started: tier-1 structural uniformity rule + tier-2 renaming
  property tests as standalone pre-commit antibodies predating the linter.
- [ ] **Test files fail on master (pre-existing; CI red).** Discovered
  2026-07-04 while verifying the banked fixes. Until then the full suite
  never finished at all: calendar_test hung forever (recur `until` limit
  never checked in next() — fixed, commit 0e4c52c3), so CI died at timeout
  and the failures behind it went unseen. With the hang fixed the suite
  completes: 614 pass / 23 FAIL, all 23 failing identically at HEAD before
  this session's changes. Clusters: crypto (hash 24, sha1 30, hmac 12,
  pbkdf2 8, totp 22 assertion failures — possibly one shared root cause),
  deque (14), text_diff (10), glob (6), sat (6), sqlite (5), taskgraph (5),
  chan (4), utf8 (4), plus singles/doubles (count_min, db, doc, event,
  platform×4, type/static, static-v4 cli_compare). Full list in the session
  log; rerun `bin/cr test` to reproduce.
  - [x] **crypto cluster (hash/sha1/hmac/pbkdf2) root cause found + fixed
    (2026-07-10).** `lib/hash/sha1/init.lua` built each 32-bit word with
    `bit.tobit` (signed) then formatted with `string.format("%08x", ...)`.
    For negative words, `%x` sign-extends to the host C `long` width before
    formatting — on this platform's 64-bit `long` that prints 16 hex digits
    (`ffffffff`-prefixed) instead of 8, corrupting every digest containing a
    high-bit word. hmac and pbkdf2 build on sha1 so inherited the corruption;
    totp not yet re-verified (not exercised this session). Fixed by using
    `bit.tohex` (LuaJIT's purpose-built unsigned-32-bit hex formatter)
    instead of `string.format("%08x", ...)`. Verified against HEAD (bug
    reproduces identically on a worktree at `acf0f58b`, well before this
    session's unrelated epoll/kqueue/io_poll commits — confirms pre-existing,
    not a regression). `bin/cr test lib/hash/ lib/pbkdf2/` now 8/8 files
    green (was hash_test 24 failed, sha1_test 30 failed, hmac_test 12 failed).
  - [x] **sqlite cluster root cause found + fixed (2026-07-10).**
    `lib/sqlite/init.lua:189` `db_errmsg` returned the raw FFI `const char *`
    cdata from `sqlite3_errmsg` and callers concatenated it directly into a
    Lua string (`"sqlite: prepare: " .. db_errmsg(self)`), which errors
    ("attempt to concatenate 'string' and 'const char *'") instead of
    producing the error message. Fixed by wrapping the FFI return in
    `ffi.string(...)` inside `db_errmsg` (single fix point, 4 call sites).
    Verified pre-existing the same way as the crypto cluster (reproduces at
    `acf0f58b`). `bin/cr test lib/sqlite/ lib/db/ lib/platform/caps/` now
    all green (was sqlite_test 5 failed).
  - [ ] Remaining clusters (deque 14, text_diff 10, glob 6, sat 6, taskgraph 5,
    chan 4, utf8 4, count_min, doc, event, platform×4, type/static,
    static-v4 cli_compare, cap_dispatch, projection_types, noise, audit) —
    reconfirmed pre-existing and unrelated to the kqueue/epoll/io_poll/
    diagnostic-cache-key/vendored-binary-layout commits (2026-07-10 CI
    triage; identical failures on a worktree at `acf0f58b`). Still
    untriaged — root causes unknown.
## v9 vertical slice — dynamism-boundary roadmap (2026-07-03)

The v9 slice (frontend seam -> total lowering -> engine -> `lib/type/v9/check.lua`)
checks real lib files end-to-end: 1,557 files, zero crashes, full solve ~7s
(`bin/cr lib/type/v9/smoke.lua` prints the histogram). Boundary items to shrink,
in histogram order, plus recorded debt. (2026-07-04: the session-level open
threads above — owner verdicts in particular — likely gate whether and how this
roadmap proceeds; it is no longer a self-directed grind list.)

- [x] **Record/table types in the v0 domain** — DONE 2026-07-03. Open structural
  records with per-field read/write split (r joins up / w meets down — the
  records-of-refs invariance, engine-lattice-encoded) as a domain-local lattice
  upgrade; field read/write/constructor/method-call lowered in the same one rule
  shape; engine untouched. The 314k-diag family (`field-expr` 200k +
  `table-constructor` 44k + `method-call` 33k + `field-assign` 21k + `index-expr`
  16k) is retired; residue is the honest boundary (`unsupported:dynamic-index` 22k,
  `table-array-part` 12k, `string-method` 0.4k) + real findings (`missing-field`,
  `field-write-mismatch`). Named concession: `new-field-on-write` (policy, default
  off). Note: went straight into `lattice.lua` rather than growing into the fenced
  `type_rep`/`subtype` seams — those stay fenced for the arrow/negation upgrade.
- [x] **Annotations + function types** — DONE 2026-07-03. Arrow values in the
  lattice (params as CELLS + annotation pins, results as VALUES — the polarity
  split; contravariant/covariant fn_leq; clip bounds recursion cycles);
  intra-file inference (params from call sites, per-position multi-return,
  result-open spread) in the one rule shape; the annot seam
  (`lib/type/v9/annot`) parses `--:`/`--::` into v9 types with per-feature
  `unsupported:annotation-*` buckets; pin+check wiring for locals /
  assignments / fields / fn definitions / checked + force casts. 521,517 ->
  495,478 total; use-before-narrow 444,422 -> 389,417; the two known
  pending-annotations findings (keyring:778, server_ws:56) resolve.
  `unsupported:cast-annotation` (6.7k) retired into cast-mismatch/force-cast +
  annotation buckets. Remainder of use-before-narrow is dominated by stdlib
  globals (`string.*`, `math.*`, `package.*` reads) — the next item below.
- [x] **Index signatures in the lattice** — DONE 2026-07-03. Rec gained an
  optional `idx = { str, num }` component (per-kind r/w Fields; a never part
  claims that key kind absent — how `{ [string]: T }` says "no number keys"
  and an array constructor says "no string keys"). Dynamic reads are
  `T | nil` NON-NEGOTIABLY (absent keys are nil — the spot TS is unsound by
  default and v9 is not); writes check against the part's invariant `w`
  (index-write-mismatch, error); growing a part on a part-less/never record
  is the `new-index-on-write` concession (off), the exact analogue of
  new-field-on-write. Joins keep idx only when both sides bounded and FOLD
  dropped named fields into the str part (sound widened reads, monotone
  projections); leq does width-into-index for extra named fields and
  REJECTS plain open records into index types (unbounded extras) — fresh
  constructors pass via leq_init (now recursive through record positions).
  Annotation grammar: `{ [string]: T }` / `{ [number]: T }` / `T[]` are real
  types (`annotation-index-signature` + `annotation-array` buckets retired;
  non-str/num key types are the small `annotation-index-signature-key`
  bucket). Constructors' array parts build the num part (join of elements;
  no arity/tuple tracking — stated; `#t` is number). ipairs/pairs/next
  element types flow via the CALL-SITE INSTANTIATION intrinsics
  ($Elem/$Values/$Keys/$Arg — declared result positions computed per call
  from an argument; one generic arm in call_core, power lives in the
  declarations): ipairs loop var is `T` not `T | nil` (ipairs stops at the
  first nil — Lua semantics). Keys outside string/number stay the honest
  dynamic-index boundary; reads on plain records without a signature are the
  `index-without-signature` diag (warn in v0 — dial up as annotations
  spread).
- [x] **Index-part growth through loop-head phis** — DECIDED 2026-07-03 (with
  the freshness increment): the phi kill is the sound call and stays. The
  born-index-bounded-`{}` alternative was rejected deliberately — it turns
  stale-alias reads into wrong `nil` claims (beyond the named concession,
  which yields unknown/diags, never a wrong type); the join-as-identity
  alternative breaks projection monotonicity. Constructor freshness dies at
  every phi (the join drops one-sided field/part evidence, so leq_init's
  absent⇒nil claim would go wrong through the merged version). The
  annotation requirement is kept and the DIAGNOSTIC now says so: an
  ann/call mismatch of a plain open record against an index-bounded type
  carries the annotate-the-declaration hint (`local m = {} --: { [k]: T }`
  checks the whole loop cleanly — pinned by tests).
- [x] **Cross-module summaries** — DONE 2026-07-03. Module summary = the
  chunk's recorded returns (joined post-solve, exported as At DATA via
  summary.lua's val_to_at — never live cells; the importer's at_val re-mints
  param cells in its own graph, the globals-seam interning split) + the
  exported alias env (own + imported, transitively closed). Resolution is a
  caps-first seam (modules.lua: dot->slash, init.lua fallback, one injected
  read_file cap — probing IS reading). Demand-driven session (check.session):
  summaries cached by path, cycles cut by an in-progress set (the legacy
  `_checking` pattern) into `unsupported:cross-module-cycle` — never a hang.
  `require` wiring is DECLARATION-driven: stdlib declares
  `require = (module: string) -> $Require<1>`; lowering resolves the inst
  from the literal argument (no name-keying — pinned by a test that wires a
  non-require name through the same declaration). `--:: require "mod"`
  imports the dep's alias env (own aliases shadow).
  `unannotated-module-boundary` is the policy dial over inferred summaries
  (default off). Landing it surfaced a LATTICE-OP pathology: join/meet/equal
  walk two distinct DAGs per PATH (exponential), and the imported DOM-shaped
  `lib.js_types` environment made the whole-lib smoke hang (minutes,
  gigabytes) on lib/web/html — fixed in the increment's own leq-memo pattern
  (pairwise memos + EXACT absorption dedup so the engine's no-change firing
  is identity + per-file reset; lattice.lua states why LuaJIT's
  non-ephemeron weak tables cannot express the cache). Histogram + numbers
  in ARCHITECTURE.md's slice section.
- [ ] **`_types.lua` companion declaration files at the session** — the legacy
  checker OVERRIDES a module's path with its `_types.lua` companion
  (`lib/foo.lua` -> `lib/foo_types.lua`). NOT carried into v9's resolver: v9
  summaries are inferred from the module's returns, and the two existing
  companions (lib/http/format_types.lua, lib/imap/format_types.lua) are
  alias-only files with no `return` — a path override would type the module's
  value as `true` (wrong). The principled v9 shape is alias-env MERGING at
  the session (summary(mod) also checks the companion and layers its aliases)
  — small, but zero `--:: require` consumers target those pairs today, so
  recorded instead of built.
- [ ] **Cross-module summary invalidation / persistence** — the session cache
  is per-process by design (this increment; the legacy sha256 disk cache is
  deliberately out of scope). A future watch-mode/LSP needs invalidation
  (content-hash keys + dep edges — the legacy dep_hashes pattern) before
  summaries can persist.
- [ ] **Legacy checker: forward-declared-local call sites contaminate
  IMPORTERS' checks** — while landing v9 cross-module summaries: a
  forward-declared local (`local equal_val ... join_val = function() ...
  equal_val(r, a) ... end ... equal_val = function() ... end`) in
  lib/type/v9/lattice.lua made `bin/cr check` (the LEGACY checker) report
  a spurious error in lib/type/v9/lower.lua — a DIFFERENT file that
  imports lattice — at an unrelated, previously-clean line
  (`cannot take length of type integer` on `#names` after an
  `x is { [integer]: string }` guard). Reordering lattice's definitions so
  the local is assigned before the call sites cleared it. Minimal repro
  not yet reduced; smells like module-summary inference degrading on the
  unassigned-local call and poisoning the importer's env. v9 is the
  replacement, but until cutover the legacy checker gates commits (the
  pre-commit hook), so this class costs real debugging time.
- [ ] **Cross-module solve cost on DOM-shaped imports requires Val
  INTERNING (hash-consing)** — the whole-lib full smoke moved ~23s -> 95s
  and peaks at ~19GB LuaJIT heap on the heaviest importers (the
  `lib.js_types` environment: lib/web/html, the reactive_dom trees): each
  importer re-mints the imported summary/alias DAG as fresh Vals + pinned
  cells in its own graph, so equal structures are distinct objects and
  every pairwise memo/dedup pays a full first-visit walk per file. The
  substrate fix is interning Vals (equal structure = identical object,
  the globals-seam sharing generalized), which collapses the pairwise
  memos into identity checks and bounds the re-mint. Recorded as
  substrate; not to be patched around per-name. Watch (2026-07-04): the
  exponential-DAG-walk class has now occurred TWICE (leq memoized earlier;
  join/meet/equal memoized in the cross-module salvage) — interning is the
  one-mechanism fix for the whole class; a THIRD occurrence would read as
  the fixes-don't-stick signature (per the compression criterion in the
  session-level threads above).
- [x] **Constructor freshness through locals** — DONE 2026-07-03. Freshness is
  a decl-level SSA property in lowering: a constructor bound to a local stays
  re-typeable (leq_init) along a single LINEAR version chain — rebound only by
  its own field/index writes, read only at projection bases (field/index-read
  bases, `#`'s operand: the `t[#t+1]` append idiom stays fresh) — and is
  CONSUMED by the first ascription whose type is known at lowering (annotated
  local/assignment/field write, checked cast, pinned return) with OWNERSHIP
  TRANSFER (the local rebinds to the pin; named writes on index-bounded
  records now check against the `[string]` part bound, keeping the
  transferred view checked). Kills: any retaining read, closure capture
  (permanent — the closure aliases the binding), any phi. The
  built-then-returned map class (agent/set.lua-shaped straight-line builds)
  checks clean; annotation-mismatch 1,500 -> 1,475, field-write-mismatch
  215 -> 190 on the tree.
- [x] **String metatable member access** — DONE 2026-07-03 (landed 29261ba8;
  audited + refactored to declaration data same day). Member access on
  string-typed values (`s:upper()`, `("x").len`) resolves through the
  DECLARED `string` table — LuaJIT sets the string metatable's `__index` to
  the string library. The LINKAGE is DATA at the declaration seam:
  `globals.atom_index` (atom -> declared global table NAME), consumed
  UNIFORMLY by lowering's projection joins (atom_index_libs) and check's
  read-target triage (read_meta) — no atom-keyed branch in the member-access
  path and no method list in the checker (the initial landing name-keyed
  `string` in lower/check; the audit refactor collapsed it to the map — a
  future metatabled atom, e.g. cdata, is one entry + its declaration).
  Per-file `--:: declare string` re-wires member resolution (pinned by test:
  a shadow makes `s:sub` missing-field and a novel method resolve). WRITE
  targets stay table-only (no `__newindex` wiring; a string write target is
  op-mismatch — a real runtime error). `unsupported:string-method` 4,697 ->
  0, most sites checking clean; the replacement surface is real checking
  (call-mismatch +302 on string-method arguments, missing-field +12,
  use-before-narrow +483 where members return through unknown). Verified
  post-increment histogram: 426,041 -> 422,506 at ~23s, zero crashes.
- [ ] **Freshness at call arguments (`f(t)`)** — deliberately NOT consumed:
  a call pin resolves only post-solve, so there is no lowering-time
  ownership transfer, and re-typing without one leaves a stale precise view
  (unsound). The bin_packing:698-shaped `local t = {...}; f(t)` class
  therefore still checks under full leq. Closing it needs either
  lowering-time callee types (cross-module/known-local arrow resolution
  before the solve) or a post-solve ownership discipline (e.g. consume only
  when the argument is the decl's LAST use — requires a liveness pre-pass;
  reads inside loops are never last).
- [ ] **Optional fields in records** — `{ x = cond and v or nil }`-shaped and
  conditionally-assigned fields intersect away at phi joins; reads then report
  missing-field (e.g. the `body.generationConfig = body.generationConfig or {}`
  default idiom). An optional-field attribute (field: T | absent) keeps them; also
  needed before `missing-field` can default to error.
- [ ] **Record imprecision classes to burn down** (all domain-local): fields accreted
  through one alias / inside a callee are invisible to other views (missing-field,
  sound-imprecise); function bodies see upvalue record versions at DEFINITION order,
  not call order (`lib/bigint/init.lua:40` `M._mt` is the canonical false positive);
  `x == nil`-guard narrowing inside `or`-chains (aho_corasick:151).
- [x] **Stdlib/global declarations** — DONE 2026-07-03. The globals seam
  (`lib/type/v9/globals`): LuaJIT 5.1 globals as `--:: declare` DATA in v9's own
  annotation grammar (mined from the legacy `lib/type/static/stdlib_types.lua`,
  translated to v0 — generics/overloads widen, index signatures -> `table`,
  pcall/find/match as result-OPEN arrows via the new `(T, U, ...)` tuple form;
  ffi deliberately NOT declared — not a LuaJIT global, it rides require);
  parsed once per process, shared At trees, per-file lazy At->Val conversion.
  Per-file `--:: declare name = T` wired through the same path (shadows
  stdlib). Reads resolve typed; writes stay global-write; `require(...)` stays
  the cross-module boundary. `type(x) == "…"` tag guards landed as two more
  lattice flow ops (tag_keep/tag_drop) behind the same cond_target/filter
  shape. undeclared-global 19.5k -> genuine names only; use-before-narrow drops
  with it (histogram in the ARCHITECTURE slice section).
- [x] **Loops via loop-head phi** — DONE 2026-07 (control-flow precision increment).
  All four constructs checked: loop-head phi per rebindable decl (assigned-roots
  scan), CLIPPED back edges (loop-grown values terminate), condition narrowing
  into body/exit, reachable-exit merge (`while true` has no cond-false edge;
  breaks snapshot into their loop frame), for-num var seeded number + bounds
  obligated ⊑ number, for-in as the iterator-protocol call (control cycles as
  the nil-dropped first result), repeat's `until` inside the body scope. The
  havoc fence retired with its last consumer. ~11k loop-boundary diags retired;
  histogram in the ARCHITECTURE slice section.
- [x] **true/false literal atoms** — DONE 2026-07. boolean = true | false in the
  lattice (constructors normalize, show/excess collapse); falsy/truthy exact, so
  `cond and a or b` infers `type(a) | type(b)` — op-mismatch 4,073 -> 2,165 and
  the pagination:384 stdlib-pin false positive resolved. Mutable-ref creation
  WIDENS a lone literal to the pair (the `{ enabled = false }` flag idiom);
  flow values and annotated refs keep literal precision.
- [ ] **v9 unused-local is syntactic** (declared-never-read in the lowering walk),
  not wired to the backward liveness domain; flow-precise liveness (e.g.
  assigned-after-last-read) is a later wiring of the existing domain.
- [ ] **v9 goto is unmodeled** (112 sites) — the `unsupported:goto-stmt` diag names
  the boundary, but a BACKWARD goto's loop effects (assignments between label and
  goto) are not fenced or phi'd; before the loops increment such gotos usually sat
  inside a havoc-fenced loop body, now they don't. Either model label/goto as
  merge points (same phi mechanism) or havoc-fence the label..goto span.
- [x] **Guard narrowing beyond bare `x` / `not x` / `type(x) == "..."`** — the
  `==`/`~=`-nil comparisons (the SAME keep/drop filters at the nil tag) and
  EARLY-EXIT reachability (`if type(x) ~= "s" then return end` narrows the
  fall-through; diverging branches — return/break/declared-`never` calls like
  `error` — contribute nothing to the merge) landed 2026-07; the
  lib/math/init.lua:11 false positive resolved. Remaining piece tracked below.
- [x] **Compound-condition narrowing (and/or chains)** — DONE 2026-07-03.
  `cond_narrows` in lower.lua composes branch action LISTS recursively over the
  same atomic filters: `and` narrows EVERY conjunct on the then-path; `or`
  narrows the sound duals on the else-path only (no invented positives);
  `not` swaps the lists; actions on the same decl chain in order. The RHS of
  any expression-level and/or also lowers UNDER the lhs guard (Lua's
  evaluation order), which types `opts and opts.f` as `nil | typeof(f)`.
  columnar:209, inverted_index:242, qrencode:145+149, csv:140-144/270-323,
  base64:42-43/99 all resolve. shamir:182 was MISATTRIBUTED to this gap — it
  is the zero-iteration-loop case (`len` is set inside a for-in; "k >= 2
  implies the loop ran" is value-dependent reasoning): an honest dynamism
  boundary, not a narrowing gap.
- [ ] **Field-place narrowing (`if t.f then … t.f …`, `o._x and o._x.y`)** —
  v0 narrows LOCAL bindings only (pinned decision, tested in lower_test:
  "FIELD places are NOT narrowed"). A field read is not a stable place under
  mutation/aliasing: sound field-place narrowing must invalidate on
  intervening calls and writes (TS pays exactly this machinery). Remaining
  real-file sites of the class: csv:394/410-411/457-458 (`ds._opts and
  ds._opts.quote`). The supported idiom is `local o = t.f; if o then …`.

## Typechecker soundness methodology — open fork

> **RESOLVED (2026-06-20).** Decided via design-it-twice (4 decorrelated candidates, 3 adversarial judges): ground soundness in an executable formal Lua semantics validated against reality (validated-semantics-first), version-parametric and cross-language, with mechanized proof staged behind phase 1. Full design + staging (S1–S5) in `docs/typechecker-formal-semantics.md`. Implementation TODOs in the next subsection ("Formal-semantics substrate — implementation"). The historical fork below is retained for context.

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

**Background:** the slice typechecker's soundness is established by adversarial testing (critic agents imagining attacks). The variance write-through unsoundness (fixed `cdc5b2a6` + re-verified `a4d85035`) survived 5 feature-audit rounds before a 6th adversarial pass caught it; an embedded-alias sub-hole only surfaced because someone happened to imagine that exact case. The methodology, not any single bug, may be the weak link — adversarial testing shows presence of bugs, never absence.

**Fork (three methodologies — different cost/strength; needs design-it-twice before deciding):**

1. **Mechanized type-safety proof** (progress+preservation against a formal Lua semantics). Strongest — proves absence — but PhD/research-scale and re-extended every increment. Cuts against the project's "stop anytime / each granularity independently useful" goal. Plausible as a long-term aspiration layered on later, not a prerequisite.

2. **Executable reference Lua semantics as differential-testing oracle** — generate programs, run under the reference semantics, assert the checker never accepts one that faults at runtime. Middle weight; systematic and automatic (would have caught embedded-alias without anyone imagining it). Fits the substrate's `artifact + semantics + evidence ⇒ claim` shape. Grounds the existing work rather than replacing it.

3. **Per-feature paper soundness arguments** (already partially practiced — see `docs/agnostic-static-analysis-crescent-slice.md` §6.14 closure's "3-case exhaustive" argument). Lightest; still relies on a human enumerating cases correctly — exactly what failed for variance.

**Leaning (advisory):** NOT mechanized-proof-first (too heavy); lean toward option 2 + option 3 per feature, option 1 as deferred long-term aspiration. Needs design-it-twice before adopting.

**Open sub-questions (verify before acting):** prior Lua-formalization art may exist (believed: Soldevila et al.; a PLT Redex model), but targets reference Lua 5.3/5.4, not LuaJIT 5.1. The subset-scoping crescent uses might make it far smaller than a full formalization. Verify via research; don't trust session memory. Suggested treatment: (a) research prior art, (b) design-it-twice on the soundness-methodology decision.

**Pointers:** `docs/typechecker-design-thesis.md` (§4b/claim 5 now FIXED; "fully sound is a HARD invariant" stance); `docs/agnostic-static-analysis-crescent-slice.md` §6.14 (variance closure design + soundness argument); `docs/artifacts/typechecker-run-2026-06-12/` (prior-art survey, 3 design-thesis critiques, gap-cascade-magnitude, per-property-metric, variance-fix-cost + design + reverify).

## Formal-semantics substrate — implementation

> *Implements the RESOLVED decision above. Design + rationale: `docs/typechecker-formal-semantics.md`. Each increment is independently useful; build substrate before consumers (S1 before the loops that need it).*

- [x] **S1 — primitive-decomposed Lua semantics for the core fragment.** Built in `lib/sem/`: parametric value algebra (`value.lua`), config/store + fault ADT (`config.lua`), partial primitives with faults-as-stuck (`prim.lua`), the small-step CEK relation `step` (`step.lua`), run-driver + canonical observation (`run.lua`), the single `luajit51` Profile (`profile.lua`), independent dumb lowering surface→control (`lang/lua/lower.lua`) + Lua-source printer (`lang/lua/print.lua`). Loop-α harness in `lib/sem/diff/` (observe / arb_program / alpha_test) vs vendored LuaJIT only. **Loop-α result: 2000/2000 generated v1-subset programs agree** (10 seeds × 200) between `step` and real LuaJIT; mismatches shrink to a minimal witness with PROP_SEED replay. Discipline verified: no raw Lua type tags in step/prim (values flow only through `value.lua`).
  - **Covered runtime fragment:** scalars + literals; arithmetic (add/sub/mul/div/mod); comparison (eq/ne/lt/le/gt/ge); concat; table construct/index/assign; function def/call with multi-return + vararg; if/while/return; local/assign. Faults-as-stuck for: arith-on-non-number, compare-incompatible, concat-non-concatable, index/newindex-non-table, table-key-nil, call-non-function.
  - **Deferred within S1 (recorded, not result-faked):** (1) μ / union / intersection surface terms are type-level, not runtime-evaluable — no `step` rule, so the generator does not emit them (start-narrow, per plan). (2) Records/indexers/open-closed rows/optional-readonly fields are TYPE-level structure; S1's tables are the runtime value, the typed structure is S2+. (3) Closure capture is a value-snapshot of the slot array at call time (read-only-closure semantics); mutable upvalue cells across closure/outer scope need a proper upvalue substrate — S2+. (4) String/number metatable indexing (e.g. `("a")[k]` reading the string lib) is OUT of the S1 no-metatables fragment; the generator only indexes guaranteed tables to stay in-fragment. (5) `for-in`/numeric-for, goto, coroutines, metatables, full stdlib — out of fragment.
- [x] **Typechecker substrate gap (surfaced building S1): literal-union not assignable to itself in return position** — FIXED. Root cause: `solve.lua` `solve_return` unconditionally widened the return value (`widen_for_sub`) before the assignability check, so `return "a"` against `"a" | "b"` widened the literal to `string`, which is not assignable to the literal union. Fix: a "try unwidened actual first" fast path mirroring the argument-position fast path (constrain.lua ~2256) — when the expected return (or expected tuple slot) is concrete (no free vars, not a bare var), check `try_unify(val_tid, expected)` before falling back to the widening path. Added at both return sub-cases (general scalar-vs-union at solve.lua ~2938; scalar-vs-tuple-slot at ~2820, since `() -> K` packs as a 1-tuple). Workarounds removed: `lib/sem/value.lua` `kind_of`/`ValueAlgebra.kind_of` restored to `ValKind` (exhaustiveness regained); `lib/sem/diff/arb_program.lua` `ShrinkIter` restored to `() -> (SS[] | nil, nil)`. Negative case (`return "c"`) still correctly rejected (falls through to widen+fail).
- [x] **Typechecker substrate gap (surfaced building S1): union return through multi-hop field-access callee over-narrows to `nil`** — FIXED (the "union field-access narrowing quirk"). Root cause: `peek_callee_ret_union` (and `peek_arg_type`) resolved a `NODE_FIELD_EXPR` callee only when the receiver was a bare `NODE_IDENTIFIER`; a multi-hop chain like `env.va.kind_of()` (receiver `env.va` is itself a field expr) was not peekable, so a union return (`VK = "nil" | ...`) typed the call-result local as `nil` instead of the union — surfaced once `kind_of` was tightened to `ValKind`. Fix: added a general recursive `resolve_expr_type_static(ctx, node)` that resolves identifier (scope + var_origin + require_exports) and field-access chains of any depth, and used it in `peek_callee_ret_union`'s field-expr branch (constrain.lua ~2746). Exposed a latent override-leak: an argument call's `pending_multi_return_override` (`f(g(...))` — g's override) leaked into f's own override-setting logic (guarded on `not override`), mis-typing `va.number(va.add(x,y))` as `number`; fixed by clearing `pending_multi_return_override` after `spread_last_call_arg` in NODE_CALL_EXPR (constrain.lua ~2940). Net effect on the 40-file lib sample: 596 → 590 errors (latent fixes, zero new). Typechecker suite regression-free (same 2 pre-existing TAG_SPREAD failures before/after).
- [x] **S2 — versions + Profiles.** Wired PUC 5.1–5.4 via the flake (`pucBin`: symlinks `lua5.x` → nixpkgs `lua5_1..5_4`; contributor/CI tooling ONLY, never a runtime dep — `bin/cr test` skips absent versions on a bare clone). Five Profiles in `profile.lua` (`luajit51`, `lua51`, `lua52`, `lua53`, `lua54`); a Profile is `{ name, version, va, arith_ops }` — version/language are the same parameter, a version delta is DATA. **The parametric value algebra split is CLEAN, not a leak:** arithmetic moved from raw-double ops in `prim` into `va.arith(op, Value, Value) -> Value`, so the number MODEL (`value.lua`: `single_double` vs `dual_intfloat`) fully owns int/float — distinct integer/float subtypes, `math.type`, `/`-always-float, `//` floor-div, integer/float promotion, integral-float tostring (`3.0`). The op-set (`arith_ops`) gates `//` (enabled 5.3/5.4; omitted 5.1/5.2/LuaJIT, where `//` is a real syntax error — verified against bin/luajit). no-special-casing grep CLEAN: zero `version ==` / name-keyed branches and zero int/float subtype knowledge in `step.lua`/`prim.lua` (verified). **Loop-α result (in `nix develop`, all 5 real interpreters present): 120/120 generated programs agree PER VERSION across luajit51/5.1/5.2/5.3/5.4, stable over 8 seeds**; the random stream now emits float literals + `/`/`%` so it exercises the int/float split. A positive cross-version DELTA table asserts the parametricity is real (e.g. `4/2`→`2` single vs `2.0` dual; `3.0` literal→`3` vs `3.0`; `5//2`→FAULT in 5.1/5.2/LuaJIT vs `2` in 5.3/5.4; float+int promotion). Bare clone (LuaJIT only): luajit51 120/120, PUC skipped gracefully, suite green.
  - **Deferred within S2 (recorded, not result-faked):** (1) **Full 64-bit integer wraparound** — the dual model wraps at 2^53 (the host double's exactly-representable window), where it is byte-for-byte faithful to real 5.3/5.4; true int64 two's-complement wraparound at 2^63 needs an exact int64 substrate (FFI `int64_t` or pure-Lua bignum). The harness confines integer-arithmetic operands to the representable window. (2) **Bitops** (`&` `|` `~` `<<` `>>`) — DEFERRED: LuaJIT `bit.*` is 32-bit-wrap while 5.3/5.4 native bitops are 64-bit, a genuine cross-version delta that needs the int64 substrate to model correctly; not faked. (3) **Typing-delta / desugar-delta** Profile fields are forward slots (S3 typing deltas, S4 language profiles); S2's lowering is shared (only number-literal construction is profile-parametric, via the injected `va`).
- [x] **S3 — Loop-β soundness property.** `checker accepts ⟹ ¬fault` against the deterministic spec (NOT the real interpreters) with a structure-aware alias-targeting generator. Built: `lib/sem/diff/arb_alias.lua` (CONSTRUCTS the measure-zero aliasing shape each trial — fresh annotated table, wide-typed alias, write-through-wide, read+use-through-narrow — co-producing the surface SS[] for the spec AND crescent-annotated source for the checker, plus the narrow/wide field Ty the variance decision turns on); `lib/sem/diff/beta_test.lua` (Loop-β with a pluggable checker oracle: the REAL `crescent_slice_lower.lower`→`A.check` checker, and a SYNTHETIC unsound oracle re-deriving the pre-fix COVARIANT `_rec_sub` rule from the real `slice_subtype.is_subtype` forward direction — demonstration path (b); the shipped checker is untouched). **Acceptance MET:** the variance unsoundness is MECHANICALLY DETECTED — generator + unsound oracle yield an accept∧spec-fault counterexample every run; minimal witness `local a={f=N}:NarrowBox; local b=a:WideBox{f:unknown}; b.f="…"; return a.f+1` (string through the unknown-widened alias → read as number → `arith-on-non-number` fault). The REAL (sound) checker REJECTS that witness and finds 0 violations over the alias generator. PROP_SEED replay; runs against spec+checker only (no PUC interpreters) so `bin/cr test lib/sem/` stays bare-clone green.
  - **Deferred within S3 (recorded, not faked):** broader GENERAL-v1 Loop-β coverage. The alias-targeting generator is intentionally narrow — it targets the alias-widen shape with field types in {number, string, boolean, unknown}, which is what the variance class needs and what uniform sampling misses. A general structure-aware Loop-β generator (driving the full v1 fragment from `arb_program` with annotations, hunting other accept∧fault classes beyond covariant-field-write) is the follow-up; it requires an annotation co-generator over the whole fragment (each generated binding needs a sound type to annotate). Not built this increment; the headline (mechanical variance detection + 0 violations against the real checker over the alias shape) is landed.
- [ ] **S4 — second language (cross-language bar).** λ-calculus with sum types + static arities as a Profile; must slot in without editing the core value-algebra/primitive mechanism (real falsification test).
- [ ] **S5 (phase 2) — mechanized proof.** Choose the proof host (tentatively Lean 4) only once phase 1 has forced the real primitive set; prove per-primitive progress + preservation lemmas feature-by-feature.
- [x] **Reality bridge — increment 1 (unambiguous atoms).** Connect the Coq proof model's `denote`/`atom_denote` (`proof/subtype.v`) to REAL LuaJIT 5.1 — the one thing the proofs cannot establish (faithfulness of the model to real Lua). Spec: `docs/reality-bridge.md` (V↔Lua value map, atom↔real-membership-predicate map, the int/float-is-not-a-runtime-tag finding). Harness: `lib/sem/bridge/atom.lua` (faithful Lua port of `atom_denote` for AStr/ABool/ANil + value→real-Lua-expr renderer + real predicates) and `atom_test.lua` (3 legs: Coq-`Compute` oracle validates the port 12/12; oracle vs real LuaJIT 12/12; generated differential 100 values × 3 atoms = **300/300 agree**). Caps-first (popen-injected vendored LuaJIT, skips on bare clone). **No faithfulness disagreement found.**
  - **Deferred — genuine design forks, NEED USER STEER (enumerated in `docs/reality-bridge.md` §4, not resolved):** (A) *primary* — number atoms int/float: REFINE (`AInt <: ANum`, integer-valued number as subtype, matching the slice's `integer <: number`) vs COLLAPSE `VInt`/`VFloat` to one number kind to match LuaJIT 5.1 runtime `type()` (which has NO int/float tag — `AInt` is a refined value-shape predicate, not a tag). (B) *the hard one* — functions/closures: model `VFun` is an extensional finite I/O graph; a real closure can't be introspected for its graph, so arrow membership may only be a behavioral/sampling test (refute-only), not a membership check — possibly category-different from the model. (C) tables: string-keys-only (Lua keys are any value), open/closed reading, finite-assoc vs real-table semantics.

## Proof-dev / type-system backlog (deferred items)

> **THE single source of truth** for everything deferred / scoped-out / future
> across the Coq metatheory — the subtype algebra (`proof/subtype.v`), the typing
> layer + operational semantics (`proof/typing.v`), the algorithmic subtyping
> relation (`proof/ssub.v`, incl. the reference `rsub`), and the bidirectional
> checker (`proof/check.v`) — all narrated in `docs/proof-kernel.md`, plus the
> reality bridge (`lib/sem/bridge/`, narrated in `docs/reality-bridge.md`). Those
> docs keep their per-increment notes; this is the consolidated list they both
> point to. **Last re-consolidated after the references unification** (commits
> `1e7f7fe5` + `01aae498`: store + references threaded into the MAIN typing layer,
> `imp.v` retired). Items tagged **[BLOCKING]** stand between the current dev (a
> sound-but-often-`DUnknown`/`rsub`-fenced checker) and a *usable static checker*;
> **[nice-to-have]** are precision / faithfulness refinements. Pointers are
> `file:increment` or `file:line` at time of writing.

### Decision-procedure completeness (the emptiness-based `gdecide`)

- [ ] **[BLOCKING] Coupled multi-negated-records per clause.** ≥2 negated records
  sharing keys in one DNF conjunct (arises from a *union of records on the right*
  of a subtyping query). Currently → `DUnknown` (the `Deferred` clause in
  `clause_wit3`, `proof/subtype.v:3243`). Scope predicate to lift: `dnf_ok`
  ("≤1 negated record per record-clause"). Principled fix: per-negated-record
  witnessing-key *assignment search* with per-key intersected `¬`-requirements.
  Deferred at `proof-kernel.md` increment 6 / staging "(a)". Demonstrated trap if
  done unsoundly: `gdecide {h:Int} ({f:Int}∪{g:Int})` must stay `DUnknown`.
- [ ] **[BLOCKING] Nested records.** Record field types that are themselves
  records; lifts the `flat` predicate ("every record's field types are
  record-free"). The `find_wit_fuel`/`rdepth` recursion already supports it
  structurally — the obligation is threading field-completeness through deeper
  `rdepth`, not new substrate. Deferred at `proof-kernel.md` staging "(b)".
- [ ] **[BLOCKING] Arrow subtyping decision.** Arrow subtyping is currently
  `DUnknown` — any clause with an arrow literal hits the `has_arrow` guard and
  defers (`clause_wit3`, `proof/subtype.v:3235`). Needs the Castagna-style
  arrow-aware emptiness / decomposition algorithm. Deferred at `proof-kernel.md`
  increment 7 ("[then — arrow decision procedure + multi-return]").
- [ ] **[BLOCKING] Reference subtyping decision (`has_ref` defer in `gdecide`).**
  Any DNF clause carrying a ref literal hits the `has_ref` guard (beside
  `has_arrow`) and defers — `gdecide ⇒ DUnknown`, never a wrong ref answer. The
  invariant `BRef` + any-ref widening rules ARE decided structurally by
  `decide_rsub` (`proof/ssub.v`, increment 18), but the emptiness-based `gdecide`
  in `subtype.v` itself does not decide refs. Deferred at `proof/subtype.v:2177`
  (the `has_arrow c || has_ref c` guard) + increment 17/18.
- [ ] **[BLOCKING] `decide_ssub`/`decide_rsub` inter-left distributivity (the N5
  frontier).** `decide_ssub` is COMPLETE only on the `inter_free` fragment: the
  inter-on-the-LEFT vs union/inter-on-the-right CROSS is the non-distributive
  frontier (subtype.v's N5 free lattice). Concrete sound-incompleteness witness:
  `decide_ssub ((Int∪Str)∩Bool)(Int∪Str) = false` while the subtyping holds.
  Closing it routes the connective subsumption through the `gdecide` emptiness
  path rather than widening `ssub`. Deferred at `proof-kernel.md` increment 12 +
  `proof/ssub.v:329` / `:502`.
- [ ] **[nice-to-have] Reference SOURCE into a connective target — `decide_rsub`
  completeness gap.** A `BRef`/`BAnyRef` SOURCE into a UNION/INTERSECTION target
  whose disjuncts are content-equivalent-but-not-syntactically-equal references is
  decided SOUNDLY but not completely — the delegated `decide_ssub` cannot observe
  ref-invariance through a connective. Closing it needs `decide_rsub` to grow its
  own connective-target clauses (the same inter-free boundary `decide_ssub`
  carries). Deferred at `proof/ssub.v:1356-1365` + `proof-kernel.md` increment 18
  "DEFERRED FRONTIER".

### Type formers

- [ ] **[nice-to-have] Closed / exact records.** Current `BRec` reads OPEN/WIDTH
  (extra keys allowed); a closed record needs a "no other keys" denotation.
  Deferred at `proof-kernel.md` increment 5 (and `reality-bridge.md` §4(C)).
- [ ] **[nice-to-have] Index signatures `{[K]:V}`.** A `∀ key`-quantified field
  reading. Deferred alongside closed records, `proof-kernel.md` increment 5 /
  staging "(c)".
- [ ] **[nice-to-have] First-class table atom.** Records currently subtype only
  `BRec []` (the table top-type), not a dedicated atom. `proof-kernel.md`
  increment 5 / staging "(d)".
- [ ] **[BLOCKING] Equirecursive μ + cyclic tables/values (the coinductive-V
  fork).** Recursive types `μ`; cyclic / self-referential tables would force a
  *coinductive* `V` (a genuine fork the current positive-inductive `V` avoids).
  Re-establish all laws + the decision procedure under recursion. Deferred at
  `proof-kernel.md` increment 5 ("cyclic deferred to μ") + staging
  "[then — equirecursive μ]". `proof/subtype.v:690`.
- [x] **Reference TYPE substrate — `BRef` + `BAnyRef` opaque leaves (split-step 1
  of the reference unification, DONE).** `subtype.v` gains the value `VRef : nat
  -> V` (a bare location address) and the types `BRef : BTy -> BTy` (a reference
  to `T`) and `BAnyRef` (all references, content-agnostic — so a truthy location
  can be NARROWED to "is a reference" without committing to a content type, the
  key diagnosis insight). References are INVARIANT and lack a store-free
  denotation, so the denotation is **content-blind**: `denote (BRef _) v` and
  `denote BAnyRef v` BOTH = "`v` is some `VRef n`", so denotationally `BRef T ≡
  BAnyRef ≡ BRef U` for all T,U. They are **OPAQUE LEAVES**, mirroring `BArrow`
  exactly: literals `LPosRef`/`LNegRef`/`LPosAnyRef`/`LNegAnyRef`; a `has_ref`
  guard (beside `has_arrow`) makes the witness-finder DEFER on any clause with a
  ref literal (`gdecide ⇒ DUnknown`, never a wrong ref answer); `BRef`/`BAnyRef`
  excluded from `atomic`/`flat`/`no_rec`/`neg_atomic`. All Boolean-algebra laws +
  `gdecide_DSub_sound`/`_DNotSub_sound` + `denote_dec` + `V_rect_strong` re-close
  `Qed` (Print Assumptions: closed under the global context). Non-vacuity:
  `ref_int_inhabited`, `anyref_inhabited`, `nonref_not_ref`/`_anyref`,
  `anyref_equiv_ref`, `ref_equiv_ref`, `ref_disjoint_atom`/`_rec`/`_arrow`.
  Recorded at `proof-kernel.md` increment 17 (reference TYPE substrate).
- [x] **Reference SUBTYPING — invariant `BRef` + any-ref widening (split-step 2
  of the reference unification, DONE).** `proof/ssub.v` ONLY (`subtype.v`/
  `typing.v`/`check.v`/`imp.v` byte-unmodified; whole chain recompiles clean).
  Because `ssub` is an inductive in the frozen `typing.v`, the rules are added as
  a new inductive `rsub` in `ssub.v` that EMBEDS `ssub` (`RsSsub`) + `RsTrans` and
  ADDS the two reference rules: `RsRefInv` (INVARIANT — `rsub (BRef S)(BRef T)`
  iff `S ≡ T`, read+write so NOT covariant) and `RsAnyRef` (`rsub (BRef U)
  BAnyRef`, WIDENING). The ASYMMETRY — no `rsub BAnyRef (BRef U)` — lets a truthy
  location narrow to `BAnyRef` without breaking invariance. PREORDER
  (`rsub_refl`/`rsub_trans`), SOUNDNESS vs `dsub` (`rsub_sound`; refs collapse to
  equal-denotation inclusions, `rsub ⊊ dsub` safe), and a TOTAL+TERMINATING
  decider `decide_rsub` (invariant case recurses on strictly-smaller content;
  delegates non-ref pairs to `decide_ssub`). FULL soundness; completeness on the
  reference fragment (`decide_rsub_anyref_complete`, `decide_rsub_invariant_complete`,
  the asymmetry decided + sound `rsub_anyref_not_ref`). Sanity (`reflexivity`):
  `(BRef Int)(BRef Int)=true`, `(BRef Int)(BRef Str)=false`,
  **`(BRef Int)(BRef Num)=false`** (invariance ≠ covariance, the soundness point),
  `(BRef Int) BAnyRef=true`, `BAnyRef (BRef Int)=false`. Print Assumptions on all
  new facts: closed under the global context. **DEFERRED FRONTIER:** a reference
  SOURCE into a UNION/INTERSECTION whose disjuncts are content-equivalent-but-not-
  syntactically-equal references is decided SOUNDLY but not completely (delegated
  `decide_ssub` can't see ref-invariance through a connective) — same inter-free
  boundary `decide_ssub_complete` already carries. Recorded at `proof-kernel.md`
  increment 18 (reference subtyping).
  **NEXT (split-step 3, DEFERRED):** thread store + references into the typing
  layer — promote `RsRefInv`/`RsAnyRef` into `ssub`'s inductive in `typing.v`
  (collapsing `rsub` back into `ssub`), give `decide_rsub` its own
  connective-target clauses to close the union/inter-of-refs completeness frontier,
  and add store-based mutation soundness (deref/assign typing + preservation over a
  typed store).

### Lua semantics (model faithfulness)

- [x] **Multi-return values — RETURN-side multivalue + contextual adjustment
  (truncation + last-position spread).** DONE (proof-kernel.md increment 21).
  `subtype.v` gains the `BTuple` sequence type (`VTup` value, positional/exact-length
  denotation, pointwise subtyping, disjointness, threaded through the decider as an
  opaque DEFER leaf like `BArrow`/`BRef`). `typing.v` gains `tret` (return-sequence,
  the multivalue value `VRet`), `tfst` (TRUNCATION — bind the first value, the "most
  positions" adjustment) and `tappspread` (LAST-POSITION SPREAD — a known-arity tuple
  consumer receives all values). Progress + preservation re-proved (`Qed`); synth/
  check + synth_sound/check_sound re-proved. PAYOFF: a multi-return `f : Int ->
  (Int,Bool)`, the SAME call `f 3` TRUNCATED (`tfst (f 3) : Int`, ⤳* 3) in one
  position and SPREAD (`g (f 3) : Int`, ⤳* 0) in another — typed + stepped, the
  contextual adjustment machine-checked. STILL DEFERRED below.
- [x] **vararg `...` (function-side variadic) — DONE.** The PARAMETER-side mirror
  of multi-return: a variadic function binds its trailing actuals as a single
  multivalue (the rest), typed as the EXISTING `BTuple Ts`; the rest behaves exactly
  like a multi-return result — TRUNCATED to one value (`tfst`) in expression
  position and SPREAD (`tappspread`) in last position, REUSING the increment-21
  substrate (no duplication). `typing.v` gains the variadic-call term `tvapp f a rs`
  (variadic function `f`, fixed arg `a`, trailing args `rs`) with typing rule
  `TVApp` (function `: BArrow Tf (BArrow (BTuple Ts) B)`, `a : Tf`, `rs : Ts`
  pointwise ⇒ result `B`) and op-sem `SVApp` (PACKS `rs` into `tret rs` and applies
  via existing `tapp`/`tret`/`SBeta`) + congruences `SVApp1/2/3`. Threaded through
  the whole de Bruijn metatheory (tm_rect_strong, lift/subst/closed_at, weakening,
  subst_lemma, store_weakening, has_type_closed, closed_at_lift, subst_lift_cancel,
  progress, preservation) plus `check.v` (synth/proj_free/synth_sound/narrowing).
  `subtype.v`/`ssub.v` BYTE-UNMODIFIED (the rest type is the existing `BTuple`; the
  arity match is the reflexive tuple leaf of `ssub`). All `Qed`, axiom-free.
  PAYOFF: a variadic `λx:Int.λ(...:(Int,Bool)).…` that TRUNCATES `...` to its first
  value (`tvapp f 7 [3;true]` ⤳* 3) and one that FORWARDS `...` via last-position
  spread (⤳* 0) — typed + stepped + synth-decided, plus an arity-mismatch synth =
  None. Increment 22, `proof/typing.v` (`tvapp`/`TVApp`/`SVApp`), `proof/check.v`.
- [x] **multiple-assignment `a,b,…=e1,e2,…` / `a,b=f()` — arity adjustment
  (truncate + nil-pad + last spread).** DONE: the LHS-side CONSUMER of the multivalue
  substrate. `tmassign rs rhs` (N target ref cells + a packed-multivalue RHS); typing
  `TMAssign` ADJUSTS the RHS tuple to the target arity via the pure normalizer
  `pad_ty`/`pad_tm` (TRUNCATE extras — the `tfst` direction — and NIL-PAD missing
  slots with `tlit LNil : ANil`, the adjust-UP direction truncation doesn't cover),
  each adjusted source type gated `Forall2 rsub` below its target cell; op-sem
  `SMAssign` evaluates all targets + RHS to values, then writes every adjusted value
  at once (`store_massign`, reusing the `tassign` store-update) — Lua's "compute
  everything, then assign". Last-position spread `a,b=f()` needs nothing new: the RHS
  is whatever `f()` evaluates to (a `tret` multivalue). No new subtyping, no index
  signatures. Threaded through the whole de Bruijn metatheory; `progress` +
  `preservation` + `synth_sound` + `check_sound` re-proved (all `Qed`, axiom-free).
  PAYOFF: `a,b=f()` (f multi-returns two, both bound, ⤳* store `[3;true]`), nil-pad
  `a,b,c=e1,e2` (c gets `nil`), drop `a,b=e1,e2,e3` (e3 discarded) — typed + stepped +
  synth-decided, plus a type-mismatch synth = None. Increment 27, `proof/typing.v`
  (`tmassign`/`TMAssign`/`SMAssign`), `proof/check.v` (`unref_seq`/`decide_rsub_seq`).
- [ ] **[BLOCKING] table-collect `{f()}`, arity-polymorphic spread.** The
  increment-21 multivalue covers the return-side sequence + truncation + last-spread
  at KNOWN arity, increment-22 the function-side variadic `...`, and increment-27 the
  LHS-side multiple-assignment (all at known arity — the consumer/targets pin it).
  Table-collect-all `{f()}` and FULL arity-polymorphic spread (a spread whose arity is
  not fixed by the consumer) remain deferred. (Tuple SUBTYPING is reflexive/pointwise
  only in `ssub`; semantic tuple subtyping via `gdecide` and a top-tuple type are also
  deferred.)
  Increment 21, `proof/subtype.v` (`BTuple`), `proof/typing.v` (`tret`/`tfst`/`tappspread`).
- [x] **Metatables — `__index` field-lookup fallback (TYPING LAYER).** Static
  read-only `__index` as a table/record (prototype inheritance / OOP) is DONE at
  the typing layer (`proof/typing.v` `tmeta`/`TMeta`/dispatch op-sem +
  `proof/check.v` synth; `progress`/`preservation`/`synth_sound`/`check_sound`
  re-proved — see the Typing-layer §"Metatables" entry and proof-kernel
  increment 21). It is modelled by FLATTENING over the existing `BRec` (no new
  `V`/`denote`-level former). The first-class / dynamic-metatable axis (a
  metatable model in `V`/`denote` for `setmetatable`-driven dispatch / dynamic
  mutation / dynamic-shape tables) was **DECIDED — do NOT build any first-class or
  dynamic-metatable representation now**; keep this static `tmeta`/`merge_fields`
  model. Full design-it-twice result (4 candidate designs + 4 adversarial judges,
  grounded in `proof/*.v`) recorded in
  `docs/decisions/metatable-representation.md`. The underlying open work is
  re-filed below as three substrate prerequisites + the `__meta`-ref graft (each
  gated on that substrate); they are deferred BEHIND the substrate, not built on
  top of the current core. `reality-bridge.md` §4(C) tracks the broader unobserved
  table axis.
- [ ] **[substrate] Sound optional / absent-key field reads (`T | nil`) — proof
  dev.** Reading a possibly-absent record key yielding `T | nil`. SUBTLETY: for a
  CLOSED record an absent key is exactly `nil`; for the current OPEN `BRec` ("other
  keys allowed") an absent key MIGHT be present — so this is entangled with the
  open-vs-closed-record / index-signature distinction below. This is the same gap
  recorded as "rawget on a key ABSENT from own returning `nil`" (proof-kernel
  increment 25, `proof/typing.v`). PREREQUISITE for the dynamic-metatable frontier.
  See `docs/decisions/metatable-representation.md` (substrate prerequisite 1).
- [ ] **[substrate, high-stakes] Index signatures `{[K]:V}` in `BTy` — proof dev,
  OWN design pass first.** Deferred per `subtype.v`'s comment (`BRec` is a fixed
  finite key list). Unlike the rejected `BRecMt` constructor, this has a REAL
  denotation (tables where every `K`-typed key maps to a `V`-typed value) and a
  real subtyping semantics — a justified, denotation-bearing kernel extension. But
  it TOUCHES THE FROZEN, reality-validated core, so it needs its OWN design pass
  before any code. (Distinct from, but overlapping with, the existing
  `[nice-to-have] Index signatures {[K]:V}` item under the type-algebra section.)
  PREREQUISITE for the dynamic-metatable frontier. See
  `docs/decisions/metatable-representation.md` (substrate prerequisite 2).
- [ ] **[substrate] Precise function-type narrowing (intersection-typed
  `ttypetest`) — proof dev.** For function-valued `__index` / `__newindex`.
  Already-deferred substrate; otherwise the metamethod narrows to `BArrow BBot
  BTop` and returns `BTop` (vs `tmeta`'s exact type). PREREQUISITE for
  function-valued metamethods on the dynamic-metatable frontier. See
  `docs/decisions/metatable-representation.md` (substrate prerequisite 3).
- [ ] **[substrate] Precise POSITIVE intersection narrowing (`U ∩ Pos`) — proof
  dev.** Narrow a conditional's scrutinee to `U ∩ Pos` so the narrowed binding is
  consumed at its REAL type (dissolving the `truthy_type ⊑ Num` wall). SPLIT BY
  CONSTRUCT:
  (a) **`ttypetest`-positive narrowing is SOUND and LANDABLE NOW** — a READY
  increment. Binder `BInter U (tag_type g)` with the RAW scrutinee type `U` works
  because `ttypetest` does NOT truncate (no `STtMulti*` rules; a multivalue is
  tested by `TgMulti`, `tag_type TgMulti = BTop`, and substituted WHOLE via
  `STtTrue`). Reusable proven pieces: `RsInterI` in `rsub` (`subtype.v`/`ssub.v`
  unmodified; `rsub_sound` via `dinter_glb`), merged bridge lemmas
  `tag_narrows_inter`/`truthy_narrows_inter` generic over the bound `W`. `tifn`
  POSITIVE narrowing for DIRECT (non-multivalue) scrutinees is also sound in
  isolation (`SIfnTrue` + the merged bridge at `W:=U`).
  (b) **`tifn`-truthiness precise narrowing is BLOCKED on the multivalue-model
  fork.** A uniform `tifn` rule with binder `BInter (trunc1 U) Pos` is UNSOUND under
  `SIfnMultiCons`: `inv_ifn`/`inv_ret` expose the scrutinee at a LOOSE,
  subsumption-chosen supertype `U` (e.g. `BTop` via `SsTop`), but after truncation
  the head has the first-COMPONENT type, which bears NO subtyping relation to `U` /
  `trunc1 U` (degenerates at `U=BTop`; FAILS for non-flat
  `BTuple[BTuple[AInt]]`). ROOT CAUSE: the multivalue model permits loose-supertype
  subsumption before the conditional AND non-flat multivalues. OPEN DESIGN FORK
  (no-default, design-it-twice candidate, gated): **Option 1** flat-multivalue model
  (components single-valued; `trunc1` idempotent); **Option 2** truncate-in-rule at
  `TIfn` (type the condition as truncate-to-one via `tfst`/`TFst` at a TIGHT type so
  subsumption can't loosen it); **Option 3** context-narrowing + canonical scrutinee
  typing is INSUFFICIENT alone (recorded NON-solution). FRAMING: this wall is a
  COMPLETENESS limit, not soundness — over-approximation (bind the bound-alone
  `truthy_type`/`tag_type`) stays sound. Full finding:
  `docs/decisions/precise-narrowing-and-the-multivalue-model.md`.
- [ ] **[gated graft] `setmetatable`/`getmetatable` via a reserved `__meta` ref
  field — proof dev.** Modellable WITHOUT any new core constructor and WITHOUT
  touching `subtype.v`: `setmetatable(t,mt) ≈ tassign (tproj t "__meta") mt`
  (return `t`) and `getmetatable(t) ≈ tderef (tproj t "__meta")` — pure existing
  `TAssign`/`TProj`/`TDeref`. CAVEAT: this stores/retrieves the metatable VALUE but
  does NOT by itself unify dynamic dispatch with the static `tmeta` path; adopting
  it coherently (so dispatch READS the stored metatable) is GATED on the absent-key
  / index-signature substrate above — else it is a parallel encoding of metatables.
  See `docs/decisions/metatable-representation.md` ("the one clean graft").
- [ ] **[nice-to-have] Non-string table keys.** Model `VTable` uses string keys;
  real Lua keys are any non-nil value. `reality-bridge.md` §4(C).
- [ ] **[nice-to-have] Full stdlib.** No stdlib modelled in the proof value
  domain.
- [ ] **[nice-to-have] `cdata` / `userdata` / `thread`, incl. LuaJIT FFI
  fixed-width integer types.** A separate runtime-representation axis (FFI cdata
  integers `int64_t`/`uint64_t`, `type()=="cdata"`). Deferred at
  `reality-bridge.md` §4(A) ("separate deferred axis") + Status "Deferred".
- [ ] **[nice-to-have] General `for-in` iterators.** Out of the modelled
  fragment.

### Number model

- [x] **Inert-value-payload removal — STAGE 1: drop the `VStr` payload.** `VStr`
  is now a NULLARY constructor (`VStr : V`, was `VStr : nat -> V`). The payload
  was inert: `denote` is head-determined (`denote_head`), every witness used
  `VStr 0`, and no typing/progress/preservation obligation read it (premise
  verified by grep — no destruct/match ever inspects a `VStr` payload; record
  keys are Coq `string`, unaffected; no proof needs two distinct string values).
  Makes "types, not magnitudes" structural — one string value, head-only,
  foreclosing the value-fidelity temptation by construction. First deliberate
  edit to the frozen reality-validated core; full chain rebuilt clean
  (`subtype→typing→ssub→check`, all "Closed under the global context", zero
  axioms), all four bridge oracle `.v` files recompute the expected verdicts, and
  the reality bridge differential tests re-ran green against real LuaJIT
  (`bin/cr test lib/sem/bridge/` — 600/600 atom + 80/80 rec + 60/60 arrow +
  100/100 operational). Bridge port updated: `lib/sem/bridge/atom.lua` `vstr` is
  nullary, renders the fixed representative `"s"`. Recorded at `proof-kernel.md`
  (inert-payload removal, stage 1 of 2).
- [x] **Inert-value-payload removal — STAGE 2 (FINAL): remove number magnitudes +
  value computation.** Numbers are now two type-CLASSES with NO magnitude:
  `NRint`/`NRfrac`/`LInt` are NULLARY (`subtype.v`/`typing.v`), `VInt`/`VFloat` are
  payload-free notations. The int/frac CLASS distinction is KEPT (load-bearing for
  `AInt ⊊ AFloat`; collapsing to one number would be unsound). Arithmetic and
  comparison are ABSTRACT: `prim_arith`/`prim_cmp` REMOVED; `SPrimArith` steps to
  SOME number value (`tlit LInt : ANum`); comparison steps NON-DETERMINISTICALLY to
  `LBool true`/`false` (`SPrimCmpTrue`/`SPrimCmpFalse`) — both with a real `LBool`
  head so `canon_bool`/`SIfTrue`/`SIfFalse` still fire (no determinism lemma in the
  dev, so non-det is harmless). This makes "types, not magnitudes" STRUCTURAL.
  The VALUE-COMPUTATION demos were DELETED (gold-plating, explicitly approved):
  `compute_add`/`compute_lt`/`ex_*_steps`/`ex_chain_steps`/`ex_add_preservation`,
  and the loop end-to-end / termination runs `cinc_*`/`forsum_one_iter`+
  `_terminates`+`_loop_runs`/`fordown_*`/`forin_one_iter`+`_terminates`+`_loop_runs`
  (they assert concrete computed stores / computed-`false`-guard termination). Each
  loop keeps its TYPING demo; soundness is carried by progress/preservation. Full
  chain rebuilt clean (`subtype→typing→ssub→check`, all "Closed under the global
  context", zero axioms; `progress`/`preservation`/`synth_sound`/`check_sound`/
  `AInt_sub_AFloat`/`not_float_sub_int`/`AFloat_equiv_ANum` all Closed). All four
  bridge oracle `.v` files recompute. Reality bridge re-validated green against real
  LuaJIT (`bin/cr test lib/sem/bridge/` — 4 passed, 142 assertions, 600/600 atom +
  80/80 rec + 60/60 arrow + 113/113 operational + 17/17 result-inhabits-type).
  Bridge port updated: `lib/sem/bridge/atom.lua` `vint`/`vfloat` nullary (render
  fixed `"0"`/`"0.5"`); `exec.lua` `lit_int` nullary; PDiv faithfulness-gap test
  deleted (moot — no computed magnitude). Recorded at `proof-kernel.md` (stage 2 of
  2). See the version-parametric-numbers item below for deferred number-value work.
- [ ] **[nice-to-have] Version-parametric numbers (5.3/5.4 distinct int/float
  sibling values).** The proof collapses to ONE double for LuaJIT 5.1 (fork A′
  RESOLVED). A future version-parameterized `V` gives 5.3/5.4 a genuinely
  distinct integer value alongside the float (where `3` and `3.0` are distinct
  siblings). Deferred at `reality-bridge.md` §4(A′) + `proof/subtype.v:640`.
- [ ] **[nice-to-have] The `AFloat` reading nuance.** On 5.1 `AFloat ≡ ANum`
  (every number is a double); the option-(ii) reading (`AFloat` = non-integer
  numbers, partitioning `ANum`) was NOT taken and is only meaningful under the
  version-parametric model above. Recorded so the decision isn't silently
  re-litigated. `reality-bridge.md` §4(A′).

### Bridge (model ↔ real LuaJIT faithfulness)

- [x] **Functions bridge (fork B RESOLVED).** Bridged `VFun` (finite known I/O
  graph) to a real Lua function via the operational I/O check. `lib/sem/bridge/
  fun.lua` builds a real `function(x)` dispatching the graph; `fun_test.lua` runs
  two legs — operational (`real_f(real(i))==real(o)` per pair) and membership
  (model `denote_dec (BArrow A B) (VFun g)` port vs real `∀(i,o). real(i)∈A →
  real(o)∈B`) — both AGREE (oracle 9/9 + 8/8 0-disagree; random graphs/types all
  agree). Model side validated against `proof/bridge_arrow_oracle.v` `Compute`,
  member + non-member (8/8). SCALAR graphs only. `reality-bridge.md` §4(B) RESOLVED
  + Status "Done (increment 4)".
- [ ] **[nice-to-have] Higher-order graphs in the function bridge.** A function
  value appearing as a graph INPUT or OUTPUT (`VFun` nested in a `VFun` graph
  pair). Deferred from the scalar function bridge (fork B); needs a recursive
  real-image + equality story for function-valued graph entries. `reality-bridge.md`
  §4(B) "Deferred".
- [ ] **[nice-to-have] Table-valued graph entries in the function bridge.** A
  `VTable` value as a graph input or output. Deferred from the scalar function
  bridge; depends on the table bridge (fork C) for the real-image + membership of
  compound values. `reality-bridge.md` §4(B) "Deferred".
- [x] **Records/tables bridge (fork C RESOLVED for the string-keyed scalar
  fragment).** Bridged `VTable` (finite string-keyed scalar assoc) to a real Lua
  table `{ [k]=real_image(v), … }` via OPEN/WIDTH record membership. `lib/sem/
  bridge/rec.lua` builds the real table + ports `denote_dec (BRec fields)
  (VTable t)`; `rec_test.lua` runs the membership leg (model port vs real
  `∀(k,T)∈fields. real_table[k]~=nil ∧ real_table[k]∈T`) — they AGREE (oracle 7/7
  0-disagree; random tables × record types 80/80). **Open/width confirmed against
  real tables** (extra keys ⇒ still member). Model side validated against
  `proof/bridge_rec_oracle.v` `Compute`, member (incl. extra-fields/open + field-
  order-irrelevant) + non-member (missing field; wrong field type; scalar is not a
  record). STRING-keyed SCALAR records only. `reality-bridge.md` §4(C) RESOLVED
  (for the fragment) + Status "Done (increment 5)".
- [ ] **[nice-to-have] Nested / function-valued record fields in the table
  bridge.** A `VTable` or `VFun` value as a record FIELD value (table-valued or
  function-valued fields). Deferred from the string-keyed scalar record bridge
  (fork C); needs a recursive real-image + membership story for compound field
  values (depends on the same machinery as the function bridge's higher-order /
  table-in-graph items). `reality-bridge.md` §4(C) "Deferred".
- [ ] **[nice-to-have] `nil`-valued record fields (nil-hole axis) in the table
  bridge.** A `VNil`-valued entry collapses to "absent key" in real Lua, conflating
  present-nil with absent. The string-keyed scalar bridge excludes nil-valued
  entries; bridging them faithfully needs a nil-hole semantics decision (and
  interacts with `ANil`-typed fields whose real predicate reads an absent key).
  `reality-bridge.md` §4(C) "Deferred".
- [ ] **[nice-to-have] Table richness bridge.** Any-key, array part, metatables,
  `nil`-hole semantics, iteration-order non-determinism — bridging beyond
  string-keyed scalar records. `reality-bridge.md` §4(C) "Scoped".
- [x] **Operational-semantics reality bridge (the EXECUTION axis).** The prior
  bridges (atom/rec/fun) validate the VALUE-MEMBERSHIP axis only; this one
  validates the REDUCTION axis: a WELL-TYPED term, executed on REAL LuaJIT,
  produces a value INHABITING its inferred type (`synth [] term`) — the checker's
  soundness claim (synth + progress/preservation) tested against reality.
  `lib/sem/bridge/exec.lua` ports the proof's `tm` and translates closed terms to
  runnable Lua (de Bruijn → fresh-name stack; refs → single-field mutable cells
  `{v=…}`; `tif`/`tlet`/`tseq`/`tassign` → IIFEs; `twhile` → a real `while` loop;
  primops → Lua binops). `exec_test.lua` runs a battery of **17** well-typed
  programs (arithmetic, comparison, conditional, let, record+proj, ref
  alloc/deref, ref mutation, counting while-loop, function application, literals)
  and asserts each real result inhabits its inferred type, REUSING the atom
  bridge's real predicates (records via per-field open/width). Result:
  **17/17 inhabit** their inferred type. Inferred types pinned from
  `proof/bridge_exec_oracle.v` `Compute (synth [] term)`. Caps-first
  (popen-injected LuaJIT, bare-clone skip). `reality-bridge.md` §"Operational /
  execution axis".
  - **SURFACED faithfulness gap — `PDiv`.** The proof's `PDiv` is `Nat.div`
    (INTEGER division: `7/2 = 3`) but real Lua `/` is FLOAT division (`7/2 = 3.5`).
    Both `3` and `3.5` inhabit the inferred type `ANum`, so soundness is PRESERVED
    (the result still inhabits the type) — but the VALUES disagree. This is a
    sound-but-UNFAITHFUL model choice. Recommendation (recorded in the doc): drop
    `PDiv` from the faithful computational subset, OR add a fractional number
    literal + faithful float division (`NRfrac`/`VFloat` already exist on the
    value side). Concrete witness: `proof Nat.div 7/2 = 3 vs real 7/2 = 3.5`.
  - **SURFACED synth-vs-declarative gap — the sum `while`-loop.** `sumloop_prog n`
    is declaratively typed at `ANum` (`sumloop_prog_typed`, via `TSub`-widening the
    `AInt` initialiser to a `Num` cell) but the ALGORITHMIC `synth` REJECTS it
    (`None`): it allocates `BRef AInt` from `LInt 0` and then cannot store the
    `ANum` arithmetic result back into the INVARIANT cell. The battery uses a
    synth-acceptable variant (`local i = ref (0+0)`, so the cell synthesizes
    `BRef ANum`). Recorded as a synth-completeness-vs-declarative gap (bidirectional
    inference does not recover every `TSub` the declarative system admits at an
    invariant `BRef` allocation). `reality-bridge.md` §"Operational axis". **CLOSED
    (`proof-kernel.md` increment 21):** type annotations (`tannot`) guide inference
    — `talloc (tannot (BAtom ANum) (tlit (LInt 0)))` synthesizes `BRef ANum`, so the
    annotated sum-loop now synths to `ANum` (`sumloop_ann_synths`); the un-annotated
    form still `None` (`sumloop_unann_None`).
- [ ] **[nice-to-have] Flow-narrowing terms on the operational bridge.** The
  execution bridge's battery covers the computational fragment (literals, primops,
  if/let/record/proj, refs, terminating while, application). `tifn` / `ttypetest`
  (flow narrowing) and higher-order / divergent programs are NOT executed — the
  bridge validates the FINITE-execution fragment (terminating programs to a value).
  Adding narrowing terms needs value-conditioned-step images + a binder-aware
  translation. `reality-bridge.md` §"Operational axis — scope".
- [x] **Close the synth-vs-declarative gap at invariant-ref alloc — via TYPE
  ANNOTATIONS (`tannot`).** `proof-kernel.md` increment 21. The general
  inference-guiding mechanism: a new term-former `tannot : BTy -> tm -> tm`
  (ascription), typing `TAnnot`, runtime-erased op-sem (congruence `SAnnot1` +
  value-strip `SAnnotV`; `tannot T v` is not a value), and `synth (tannot T e)` =
  CHECK `e` against `T` (`decide_rsub`) ⇒ return the ANNOTATION `T`. THE FIX: the
  annotated sum-loop — cells built `talloc (tannot (BAtom ANum) (tlit (LInt 0)))`
  ⇒ `BRef ANum`, able to hold the arithmetic result — now SYNTHESIZES
  (`sumloop_ann_synths : synth [] [] (sumloop_ann n) = Some (BAtom ANum)`),
  contrasted with the un-annotated `sumloop_unann_None` (= `None`). `synth_sound` /
  `check_sound` / `progress` / `preservation` re-proved (`Qed`) with the `tannot`
  cases (`inv_annot` + threading through weakening/subst/closedness/narrowing).
  Sanity: `(3:Num)` synths+steps (erased) to `3`; mis-ascription `(3:Str)` rejected
  (`synth = None`) and ill-typed. `Print Assumptions` on
  progress/preservation/synth_sound/check_sound/sumloop_ann_synths: Closed under the
  global context. `subtype.v` + `ssub.v` byte-unmodified. Building block for surface
  `local x : T = e` and function param/return annotations (not themselves built).
  - **RETIRED / MOOT (stage-2 number refactor):** `PDiv` float-faithfulness (the
    former `Nat.div` vs real `/ = 3.5` reality-bridge gap) — moot by construction:
    numbers have no magnitude and arithmetic is abstract, so there is no
    model-computed number value to be faithful-or-unfaithful. See the stage-2
    inert-payload-removal item under "Number model".

### Arrows (laws beyond the closed one)

- [ ] **[nice-to-have] Higher arrow decomposition / emptiness laws.** Beyond the
  proved `(A→B)∩(A→C) ≡ A→(B∩C)` (`darrow_inter_cod`): `(A→C)∩(A'→C) <: (A∪A')→C`
  and the arrow-emptiness laws. Need either an arrow-aware decision procedure or
  further model lemmas. Deferred at `proof-kernel.md` increment 7 "DECOMPOSITION
  LAW" + `proof/subtype.v:1970`.

### Metatheory bridge

- [ ] **[nice-to-have] Reconcile the old syntactic free-lattice `sub` with the
  semantic `dsub`.** The increment-1/2 inductive `sub` is RETAINED as the future
  *algorithmic* relation; prove it sound + complete against `dsub`, OR formally
  retire `sub`. Deferred at `proof/subtype.v:612` + `proof-kernel.md` increment 3
  ("`sub` retained as the future algorithmic relation").

### Typing layer (MINIMAL CORE DONE — `proof/typing.v`, increment 8)

The de-risk skeleton is built and machine-checked (`proof/typing.v`, builds on
`proof/subtype.v` unmodified). Progress + preservation both `Qed`; `Print
Assumptions` on `progress`, `preservation`, `ssub_arrow_inv`, `ssub_sound`,
`arrow_top_collapse` all report *Closed under the global context*.

- [x] **Typing judgment.** `has_type : list BTy -> tm -> BTy -> Prop` over a de
  Bruijn context, with a `has_fields` mutual for records. Rules: lit / var / lam
  (BArrow) / app / let / rec (`BRec`, NoDup keys) / proj / **subsumption (TSub)**.
- [x] **Operational semantics in the proof.** CBV substitution-based small-step
  `step : tm -> tm -> Prop` over de Bruijn terms (lift/subst defined): beta, let,
  projection lookup, plus congruence/eval-context + record left-to-right field
  reduction. `value` = literals / lambdas / all-value records.
- [x] **Progress + preservation.** `progress : has_type [] e T -> value e \/
  exists e', step e e'` and `preservation : has_type [] e T -> step e e' ->
  has_type [] e' T`, both `Qed`. Supporting: canonical forms, weakening,
  substitution lemma, arrow inversion, record inversion.
- [x] **Subtyping plugged in via `ssub` (sound vs `dsub`).** KEY FINDING: raw
  semantic `dsub` is too coarse for syntactic preservation — an `A->Top` arrow
  collapses to "any function" (`arrow_top_collapse`, machine-checked), breaking
  preservation (`preservation_dsub_counterexample`: a well-typed redex steps to a
  stuck untypeable term). TSub subsumes along a syntactic `ssub` whose arrow rule
  bakes in variance inversion; `ssub_sound : ssub a b -> dsub a b` keeps the
  proven semantic algebra as ground truth. This realizes the increment-3 roadmap
  item "retain `sub` as the future algorithmic relation, prove it sound vs `dsub`"
  for the arrow+record fragment. Guarded `dsub` arrow inversion (`arrow_inv_cod`
  / `arrow_inv_dom`, with the inhabitation side-conditions made explicit) is also
  proved, documenting the model's true edge cases.

- [x] **Conditionals + union types** (increment 11, `proof/typing.v` +
  `proof/ssub.v` + `proof/check.v`, on unmodified `subtype.v`). `tm` gains `tif`
  (op-sem literal-selectors + condition congruence, lazy branches); declarative
  `TIf` types it at `BUnion T1 T2` (the JOIN). `ssub`/`decide_ssub` gain UNION
  rules (composable intro `SsUnionInL/InR` + elim `SsUnionE`), proven SOUND vs
  `dsub` (`ssub_sound`) and DECIDED (union-left `&&` / union-right `||`; same
  `bsize a + bsize b` fuel measure, strictly decreasing — `decide_ssub_correct`
  re-proven sound + complete + total). SOUNDNESS FINDING: explicit `SsTrans` +
  union intro makes a transitivity MIDDLE possibly a union, breaking naive
  derivation-induction inversion (old `ssub_top_src`/`ssub_connective_super`
  become FALSE); fixed via STRUCTURAL above/below predicates
  (`arrow_above`/`rec_above`/`atom_above`/`top_above`/`interneg_above`/
  `union_below`) proven closed under `ssub` by derivation induction → union-robust
  inversions (`ssub_arrow_inv`, `ssub_rec_inv`, `ssub_union_src_l/r`,
  `ssub_union_tgt_inv`). `progress` + `preservation` re-proven (the `tif` cases
  subsume the selected branch into the union via the injections — operationally
  sound, no arrow-Top collapse; `canon_bool` added). `synth`/`check` handle `tif`
  (synth ⇒ `BUnion` of branches); `synth_sound`/`check_sound`/`synth_principal`
  re-proven. Non-vacuity: `if true then 3 else "s"` synths `Int∪Str`, steps to
  `3`. `Print Assumptions` closed under the global context.

Still open (DEFERRED — recorded honestly, minimal core only):
- [x] **PRIMITIVE BINARY OPERATORS — arithmetic + comparison** (increment 20,
  `proof/typing.v` + `proof/check.v`, on **byte-unmodified** `subtype.v` +
  `ssub.v`). `tm` gains `tprim : primop -> tm -> tm -> tm`,
  `primop = PAdd|PSub|PMul|PDiv|PLt|PLe|PEq`. Declarative `TPrimArith` (operands
  `ANum`, result `ANum`) + `TPrimCmp` (operands `ANum`, result `ABool`), gated by
  boolean classifiers `arith_op`/`cmp_op` (no special-casing; the classes are
  provably disjoint). Op-sem: left-to-right operand congruence (`SPrim1`/`SPrim2`)
  then COMPUTE — arithmetic on two `LInt` literals → `LInt (prim_arith op m n)`
  via nat arithmetic (`3+4=7`); comparison → `LBool (prim_cmp op m n)` via the real
  nat comparison (`3<4=true`); `PDiv` uses `Nat.div` (integer-valued
  representative — no fractional literal in the term language; sound since result
  is a number). `progress`/`preservation` re-proved `Qed` (new `canon_num`: a
  closed `ANum` value is `tlit (LInt n)`; `inv_prim` subsumption-transparent
  inversion). Checker: `synth (tprim op a b)` checks both operands `≤ ANum`,
  returns `ANum`/`ABool`; `synth_sound`/`check_sound` re-proved. Sanity: `3+4 :
  ANum →* 7`, `3<4 : Bool →* true`, `(3+4)*2 →* 14`, `"s"+1` rejected
  (`~has_type`, `synth=None`). `Print Assumptions` on `progress`/`preservation`/
  the sanity lemmas + `synth_sound`/`check_sound`: closed under the global context.
  **DEFERRED (this increment):** precise Int-preserving result types
  (`Int+Int : AInt` — sound `ANum` used now); concat / modulo / `//` / bitwise /
  metamethod-dispatch operators; general structural `==` (numbers-only here).
  Recorded at `proof-kernel.md` increment 20.
  **SUPERSEDED by the stage-2 number refactor:** the `COMPUTE`/`prim_arith`/
  `prim_cmp` value computation described above was REMOVED — arithmetic/comparison
  are now ABSTRACT (numbers are magnitude-free type-classes). The `3+4 →* 7`,
  `3<4 →* true`, `(3+4)*2 →* 14` sanity runs were deleted (gold-plating); `faithful
  PDiv float result` is RETIRED/moot. See the stage-2 item under "Number model".
- [x] **INTERSECTION + NEGATION as `ssub` rules** (increment 12, `proof/typing.v`
  + `proof/ssub.v`, on unmodified `subtype.v`). `ssub` gains the composable GLB
  rules `SsInterPL`/`SsInterPR`/`SsInterI` (projections + intro), **proven SOUND
  vs `dsub`** (`ssub_sound` extended — intersection is the meet); `progress` +
  `preservation` re-proved `Qed`. `BNeg` stays reflexive-only (the complement
  disjointness `A∩¬A <: Bot` narrowing needs is kept a SEMANTIC `dsub` fact,
  `dcomplement_inter`, NOT an `ssub` rule — adding it would force `ssub` to decide
  emptiness). `decide_ssub` gains inter-on-RIGHT (GLB, COMPLETE) + inter-on-LEFT
  (projection, SOUND); correctness SPLIT: `decide_ssub_sound` UNCONDITIONAL +
  `decide_ssub_complete` on the `inter_free` fragment. **The full `<->` is
  IMPOSSIBLE** with intersection projections present — the inter-left vs
  union/inter-right CROSS is the non-distributive frontier (subtype.v's N5);
  concrete sound-incompleteness witness `decide_ssub ((Int∪Str)∩Bool)(Int∪Str)
  = false` while the subtyping holds. `Print Assumptions` closed under the global
  context. (TERM-position intersection/negation introduction forms still
  deferred; semantic connective decision stays `gdecide`'s job.)
- [x] **Flow NARROWING — variable-condition truthiness (increment 13, DONE).**
  Sound truthiness occurrence typing — the `and`/`or`-nil class — machine-checked
  end-to-end (`progress`+`preservation`+`synth_sound`+`check_sound`+the payoff all
  `Qed`, `Print Assumptions` closed). **The refined diagnosis (correcting
  increment-12's).** Increment 12 said value-conditioned op-sem alone fixes the
  unsoundness; that is INCOMPLETE for de Bruijn SUBSTITUTION semantics: a
  `tif (tvar n)` narrowing the free context entry `n` is still unsound, because an
  enclosing `SLet`/`SBeta` substitutes the bound value into BOTH branches BEFORE
  the conditional selects — the DEAD branch then carries a now-false narrowing
  assumption (a truthy value pushed into the falsy-narrowed else-branch) and
  becomes an ill-typed residual. Value-conditioning fixes the SELECTED branch but
  not the blindly-substituted dead one. **The fix that closes:** a BINDING
  narrowing-conditional `tifn c e1 e2` — the scrutinee is bound FRESH (de Bruijn
  0) in each branch at the narrowed type, and the value-conditioned step
  (`SIfnTrue`/`SIfnFalse`, on `truthy_value`/`falsy_value`) substitutes the value
  into ONLY the selected branch (`subst 0 v e1` / `e2`), discarding the other —
  so no dead-branch residual ever exists. The bridging lemmas `truthy_narrows` /
  `falsy_narrows` (a truthy value has type `truthy_type`; falsy → `falsy_type`)
  are the operational⇒type justification, proved by canonical forms + `ssub`
  UNION-introduction only (no negation, no `dsub`-in-typing). **Types.** `truthy_type`
  = positive union of all non-nil value classes (`ABool∪ANum∪AStr∪{table}∪{fn}`);
  `falsy_type` = `nil∪bool` (over-approx — no singleton-false type exists). **Payoff
  (both proved):** a non-nil consumer `g : truthy_type→Int` applied to the
  then-narrowed scrutinee TYPES with narrowing and is REJECTED without it (the
  un-narrowed `Int∪Nil` is not `≤ truthy_type`).
- [ ] **Flow narrowing — DEFERRED sub-items (increment 13 scope boundary).**
  (1) **Full occurrence-typing precision `U ∩ truthy_type`** (carry the scrutinee's
  declared type INTO the narrowed branch, not just the truthy/falsy bound). Needs
  an intersection-INTRODUCTION rule `TInter`; its ARROW inversion is the hard core
  of intersection-type systems — `(A1→B1)∩(A2→B2)` is NOT `ssub`-below any single
  arrow, so `inv_app` cannot recover a single arrow witness. Intersection-type
  substrate, deferred. (2) **Exact falsy partition.** The value model (subtype.v)
  has NO singleton-false type (`ABool` denotes both `true` and `false`), so the
  exact falsy set `{nil, false}` is inexpressible as a `BTy`; narrowing uses the
  two expressible bounds (`truthy_type` under-approximates-the-complement,
  `falsy_type` over-approximates falsy) — both SOUND, both inexact at the
  true/false split. Exact narrowing needs a literal-false type (a subtype.v change).
  (3) **Type-test narrowing** `type(x)=="number"` — DONE in increment 15 (see the
  completed entry below); the NEGATIVE (else-branch) precision `U ∩ ¬tag_type g`
  remains deferred (over-approximated to `U`), same intersection/negation wall as (1).
  Precise NEGATIVE narrowing is separately GATED on DECIDER ROUTING (`decide_ssub`
  vs `gdecide` — the N5 inter-left non-distributive frontier, witness
  `((Int∪Str)∩Bool)(Int∪Str)`; see the [BLOCKING] inter-left distributivity item
  above) — a design-it-twice candidate, DISTINCT from the multivalue fork below. The
  POSITIVE side (`U ∩ tag_type g`) is now characterized as sound + landable for
  `ttypetest`; see the `[substrate] Precise POSITIVE intersection narrowing` item
  above and `docs/decisions/precise-narrowing-and-the-multivalue-model.md`.
  (4) **Narrowing on non-variable paths** (`x.f`, `x[i]`).
  (5) **Distributive simplification** `(T∪nil)∩¬nil <: T` — `dsub`-true, `ssub`-false
  (the N5 non-distributive frontier); routing it needs the `gdecide` emptiness path.
  (6) **Combined truthiness + type-test narrowing** in one guard (e.g. `if x and
  type(x)=="number"`) — each form is independently sound; composing their binders
  is future work.
  (7) **Precise REFERENCE narrowing.** A truthy location currently narrows to its
  bound type / `BAnyRef` (content-agnostic — sound, since a truthy value IS some
  `VRef n`), not to a precise content type. Precise negative reference narrowing
  (`U ∩ ¬BAnyRef`, "is not a reference") hits the same intersection-type arrow-
  inversion wall as (1)/(3) — the hard core of intersection-type systems.
  `typing.v:584` (BAnyRef binding-form narrowing).
- [x] **Flow NARROWING — type-test occurrence typing (increment 15, DONE).**
  The real Lua `type(x)=="T"` guard — POSITIVE tag narrowing — machine-checked
  end-to-end (`progress`+`preservation`+`tag_narrows`+`synth_sound`+`check_sound`+
  `synth_principal`+`narrowing`+both payoffs all `Qed`, `Print Assumptions` closed).
  Modifies `proof/typing.v` + `proof/check.v`; `subtype.v` + `ssub.v` UNMODIFIED.
  Extends the increment-13 `tifn` binding-narrowing infrastructure with the SAME
  value-conditioned fresh-binding discipline (the soundness crux). **Term/op-sem.**
  `tm` gains `ttypetest : tag -> tm -> tm -> tm -> tm` where `tag = {TgNum, TgStr,
  TgBool, TgNil, TgTable, TgFun}` (the `type()` tags; `TgNum` ↔ the whole number
  type `ANum`, per the 5.1 model where `type()` returns `"number"` for all numbers).
  The scrutinee is bound FRESH (de Bruijn 0) in each branch. `has_tag : tm -> tag ->
  Prop` is total on values (`value_has_some_tag`) with a unique tag (`has_tag_unique`).
  Value-conditioned step: `STtTrue` (tag matches `g` ⇒ `subst 0 v e1`), `STtFalse`
  (some other tag `g'≠g` ⇒ `subst 0 v e2`), `STt1` (congruence). **Typing.**
  `TTypeTest : has_type G c U -> has_type (tag_type g::G) e1 T1 -> has_type (U::G)
  e2 T2 -> has_type G (ttypetest g c e1 e2) (T1∪T2)` — THEN under the tag-narrowed
  binder `tag_type g`, ELSE under the scrutinee's own type `U` (a sound
  OVER-approximation of the precise `U ∩ ¬tag_type g`). `tag_type`: TgNum↦ANum,
  TgStr↦AStr, TgBool↦ABool, TgNil↦ANil, TgTable↦`BRec []` (the table top-type),
  TgFun↦`BArrow BBot BTop` (the function top-type). **The bridging lemma (crux,
  mirroring `truthy_narrows`):** `tag_narrows : has_type [] v U -> value v ->
  has_tag v g -> has_type [] v (tag_type g)` — a value whose runtime tag is `g`
  genuinely has type `tag_type g`, proved by canonical forms + `ssub`
  atom/arrow-Top/record-`SrNil` subsumption only (no negation, no `dsub`-in-typing).
  Preservation's THEN-branch uses it via `subst_top`; the ELSE-branch uses the
  scrutinee's own `U`-typing directly (no narrowing). **Payoff (both proved):** a
  number-consumer `h : ANum→Int` applied to the then-narrowed scrutinee of declared
  type `Str∪Num` TYPES with `type(x)=="number"` narrowing and is REJECTED without it
  (`Str∪Num` is not `≤ ANum` — a string is not a number, refuted at `VStr 0`).
  **Honest scope.** POSITIVE (then-branch) tag narrowing only; precise NEGATIVE
  narrowing (`U ∩ ¬tag_type g`, the intersection/negation wall), narrowing on
  non-variable paths, and combined truthiness+type-test are DEFERRED (sub-items 3/4/6
  above).
- [x] **Statements / control flow — DONE (increment 20, ENCODED).** Lua's
  imperative statement forms encode into the existing core with NO new terms —
  soundness inherited from the proven `progress`/`preservation`. Encodings (plain
  `Definition`s in `proof/typing.v`): UNIT (a statement returning nothing) ⇒
  `tlit LNil` (`Tunit := BAtom ANil`); SEQUENCING `s1 ; s2` ⇒ `tseq s1 s2 := tlet
  s1 (lift 1 0 s2)` (run `s1` for effect, discard, run `s2`; the lift makes the
  discard-binder unused so `s2`'s free vars are unchanged — `subst_lift_cancel`);
  IF-STATEMENT ⇒ `tif` (already core, increment 11); BLOCK/local scope ⇒ `tlet`
  nesting; WHILE `while c do body end` ⇒ `twhile c body := tfix Tunit (tif c (tseq
  body (tvar 0)) (tlit LNil))` — the fixpoint re-evaluates `c` against the CURRENT
  store each unfold, runs the mutating `body`, recurses via the self-ref `tvar 0`,
  terminates with `nil` when `c` is false. CAPSTONE — a REAL imperative program
  TYPES: the counting/sum loop `local i=ref 0; local s=ref 0; while (!i<n) do s:=
  !s+!i; i:=!i+1 end; !s` (`sumloop_prog_typed`, at `ANum`; cells are `BRef ANum`
  because arithmetic yields `ANum` and `BRef` is invariant — Lua's one number
  type). The single-cell counter loop TYPES at `Tunit` (`cinc_loop_typed`); its
  former END-TO-END run (`cinc_loop_runs`/`cinc_one_iter`/`cinc_terminates`,
  store `[0]`→`[1]` with a computed `1<1` false guard) was DELETED in the stage-2
  number refactor — value computation the abstract primitives no longer perform.
  SEQUENCING-WITH-MUTATION `(t.x:=9); t.x` reads 9 (`seq_mutation_typed`/`_steps`);
  IF-WITH-MUTATION `if cond then r:=1 else r:=2 end; !r` reads the taken branch's
  value (`if_mut_typed`, `if_mut_true_steps`/`if_mut_false_steps`).
  DIVERGENCE-TOLERANCE: `while true do () end` is well-typed at `Tunit` and DIVERGES
  (`while_true_typed`, `while_true_diverges` — one cycle returns the loop to itself;
  `while_true_not_stuck` — not a value yet always steps) — soundness tolerates
  non-termination (inherited from `tfix`). `while` termination relies on the body
  mutating the state the condition reads; general termination is neither provided
  nor needed. `Print Assumptions` Closed on all; cores (subtype.v/ssub.v/check.v)
  UNMODIFIED. DEFERRED (backlog): `break`/`return`/`goto` (non-local control —
  labelled exits/continuations). Numeric `for` and generic `for-in` now DONE (see
  below). See `proof-kernel.md` increment 20.
- [x] **Numeric `for`-loop `for i = e1, e2, e3 do body end` — DONE (encoded over
  `twhile`).** Models Lua 5.1 numeric-for as a desugaring over the existing while-
  loop + reference + arithmetic + comparison + local-binding substrate; NO new core
  terms, NO new subtyping, `subtype.v`/`ssub.v`/`check.v` byte-UNMODIFIED. Two forms
  (the step's SIGN is resolved statically, faithful to the nat number model that has
  no negative literal): `tfor_up cnt limit step body` (step>0: guard `!i ≤ limit`,
  increment `i := !i + step`, mirroring the while-loop's ascending `cinc`) and
  `tfor_down` (step<0: guard `limit ≤ !i`, decrement `i := !i - step` — descent
  carried by the subtraction direction). The loop variable `i = !cnt` is re-read
  each iteration (Lua's per-iteration binding under the store model) and typed at
  the NUMBER type `ANum` (the counter is a `BRef ANum` cell: arithmetic yields
  `ANum`, invariant cell ⇒ Num cell; init `AInt` widens by `AInt <: ANum`). Typing
  inherited from `twhile_typed` (`tfor_up_typed`/`tfor_down_typed`), unfold/step from
  `twhile_unfold`. Payoffs: a counting-up sum loop `for i=1,3,1 do sum:=sum+i end`
  TYPES (`forsum_loop_typed`) and STEPS end-to-end to `sum=6` (`forsum_loop_runs`,
  three store-driven iterations + termination); a counting-down loop `for i=2,1,-1`
  TYPES (`fordown_loop_typed`) and terminates `2→1→0` (`fordown_loop_runs`); the
  loop variable is typed soundly as a number (`for_var_typed_number : !i : ANum`)
  and NOT an integer (`for_var_not_int : ~ !i : AInt`, via a `NRfrac` witness — 5.1's
  single-number model). `Print Assumptions` Closed on all. See `proof-kernel.md`
  increment 28.
  **SUPERSEDED by the stage-2 number refactor:** the end-to-end RUNS
  (`forsum_loop_runs` → `sum=6`, `fordown_loop_runs` → `2→1→0`) were DELETED — value
  computation the abstract magnitude-free primitives no longer perform; each loop
  keeps only its TYPING demo. The SIGNED-NUMBER substrate boundary (a single
  runtime-sign-dispatched form needs signed `NumRep`/`LInt` + sign-aware `PSub`) is
  RETIRED/MOOT by construction: numbers have no magnitude, so there is no sign to
  dispatch on at runtime; direction is a STATIC operator choice
  (`tfor_up`/`tfor_down`). See the stage-2 item under "Number model".
- [x] **Generic `for-in` loop `for v1,…,vn in explist do body end` (iterator
  protocol) — DONE (encoded over `twhile` + `tmassign` + `tapp` + `tifn`).** Models
  Lua 5.1's own generic-for desugaring (`local f,s,ctrl=explist; while true do local
  v1..vn=f(s,ctrl); if v1==nil then break end; ctrl=v1; body end`) as a desugaring
  over EXISTING substrate; NO new core term, NO new subtyping, NO new check.v synth
  arm; `subtype.v`/`ssub.v`/`check.v` byte-UNMODIFIED. KEY MOVE (avoids needing
  `break`, which this dev lacks): FOLD the nil-termination into the `twhile` GUARD,
  exactly as numeric-for folded its termination. The iterator sits in the `twhile`
  CONDITION (re-evaluated each unfold ⇒ called ONCE per iteration); its first result
  both drives termination and becomes the next control value (advanced in the body).
  Forms: `forin_guard` = `tseq (tmassign vcells iter_call) (tifn (!v1cell) true
  false)` (call iterator, multi-bind the n results via multiple-assignment, test the
  first cell truthy ⇒ Bool); `forin_body` = `tseq (ctrl := !v1cell) (tifn (!v1cell)
  body nil)` (advance control, run body under the NARROWED first loop variable);
  `tforin = twhile forin_guard forin_body`. Typing inherited from `twhile_typed`
  (`tforin_typed`/`forin_guard_typed`/`forin_body_typed`), unfold/step from
  `twhile_unfold`. NARROWING: the body's `tifn (!v1cell)` substitutes `v1` at de
  Bruijn 0 narrowed to `truthy_type` (the EXISTING expressible non-nil bound), so the
  body sees `v1` non-nil. CONTROL TYPE = `V1 = T ∪ nil` (compatible-with-V1, no new
  substrate): `ctrl := !v1cell` type-checks by reflexivity; the iterator narrows its
  own control argument internally (`ttypetest TgNum`), exactly Lua's stateful-iterator
  pattern. Payoffs: a concrete generic-for over an explicit finite iterator
  `(Num∪nil)→BTuple[Num∪nil]` TYPES (`forin_loop_typed`, `forin_iter_typed`); its
  former END-TO-END run (`forin_loop_runs`/`forin_one_iter`/`forin_terminates`,
  accumulating `cnt=3` over distinct stores) was DELETED in the stage-2 number
  refactor — value computation the abstract primitives no longer perform; the loop
  keeps only its TYPING demo. The first
  loop variable is narrowed to non-nil inside the body (`forin_v1_narrowed_nonnil :
  v1 : truthy_type`) and REJECTED at nil (`forin_v1_not_nil : ~ v1 : ANil`, via a
  number witness in `truthy_type`). `Print Assumptions` Closed on all. SUBSTRATE BOUNDARY noted
  (not faked): termination is folded as "first result TRUTHY" (the only expressible
  non-nil narrowing — `tifn`'s `truthy_type` bound) rather than exact `v1 == nil`;
  the precise `v1 : V1 ∩ ¬nil` narrowing is the SAME intersection-narrowing substrate
  gap the `TIfn` note already records (needs an intersection-introduction typing rule
  + arrow inversion). On a standard iterator (non-falsy element or nil) truthiness
  COINCIDES with non-nil, so this is sound and Lua-faithful. See `proof-kernel.md`
  increment 29.
- [x] **Mutable TABLE fields (record fields as refs) — DONE (increment M4,
  records-of-refs ENCODING).** A Lua mutable table `{x:T,y:U}` IS a record of
  reference cells `BRec [("x", BRef T); ("y", BRef U)]`: the field SET is fixed
  (immutable, width/depth-covariant — inherited from `BRec`), each field is a
  mutable `BRef` cell (per-field mutation is INVARIANT — inherited from `BRef`).
  ENCODED into the existing core (NO new terms): table literal `{x=e}` ⇒
  `trec [("x", talloc e)]`; read `t.x` ⇒ `tderef (tproj t "x")`; write `t.x := v`
  ⇒ `tassign (tproj t "x") v`. Soundness is INHERITED — `progress`/`preservation`
  already cover `talloc`/`tderef`/`tassign`/`trec`/`tproj`, so the cores are
  UNMODIFIED. Proved (`Qed`, all `Print Assumptions` Closed): `mutation_*` (build,
  assign a field, read back the NEW value 9), `field_invariance_*` (string into a
  `BRef Int` field REJECTED at every type; well-typed assign accepted;
  `field_cell_invariant`: `BRef Int` NOT usable as `BRef Num`), `covariant_*`
  (record-of-refs width-subtypes on the immutable field set, composing with the
  invariant cells). See `proof-kernel.md` increment M4.
- [x] **Reassignable locals — DONE (increment M4).** A `local x` whose binding is
  reassigned is a ref cell over the SAME ref core: `local x = e` ⇒ `talloc e`,
  `x := v` ⇒ `tassign x v`, read `x` ⇒ `tderef x`. Proved `reassign_local_*`
  (`local x=7; x:=9; x` types at Int and multi-steps to 9 — the read observes the
  reassigned value). `Print Assumptions` Closed; cores unmodified.
- [x] **Aliasing — DONE (increment M4), strong-update precision still nice-to-have.**
  Two bindings to the SAME table value share its store cells; a write through one
  is observed through the other. Proved `aliasing_*` (`let a=<table> in let b=a in
  (a.x:=9); b.x` types at Int and multi-steps to 9 — mutation through `a` seen via
  `b`, both touching the same location). Flow-sensitive STRONG update on a
  uniquely-owned cell remains DEFERRED (nice-to-have). `proof-kernel.md` M4.
- [x] **Mutation / references — store-based soundness (increment 16, DONE).**
  NEW file `proof/imp.v` (on unmodified `subtype.v`+`typing.v`; `ssub.v`+`check.v`
  untouched). Own type syntax `RTy` (atoms + `RArrow` + `RRef`, since `subtype.v`'s
  `BTy` has no ref former and stays unmodified) with `rsub` (atom order; arrow
  contra/co — the same rule as `ssub`, the reason preservation survives
  subsumption; `RRef` **INVARIANT**). `rtm` = references CORE (lit/var/lam/app/let/
  if) + `ralloc`/`rderef`/`rassign`/`rloc` (a location is a VALUE, not source).
  CONFIGURATION op-sem `rstep : rtm*store -> rtm*store` (`store := list rtm`):
  every existing reduction threads the store unchanged; alloc appends
  (`rloc(length st), st++[v]`), deref reads (`store_lookup n st`), assign writes
  in place (`store_update n v st`) yielding the unit value `nil`. STORE TYPING
  `has_typeR Σ Γ e T` (Σ threaded through every rule; `RTLoc` reads Σ; alloc⇒`RRef
  T`, deref `RRef T⇒T`, assign `RRef T,T⇒unit`), `store_well_typed Σ st`,
  `extends Σ' Σ` (prefix). **`progress` + `preservation` BOTH `Qed` WITH the
  store** — progress: `has_typeR Σ [] e T -> store_well_typed Σ st -> value e \/
  exists e' st', rstep (e,st) (e',st')`; preservation: `... -> rstep (e,st)
  (e',st') -> exists Σ', extends Σ' Σ /\ has_typeR Σ' [] e' T /\ store_well_typed
  Σ' st'`. Substantive cases: alloc EXTENDS Σ (store-weakening re-types old
  cells), deref uses the store invariant, assign re-establishes `store_well_typed`
  in place. Supporting metatheory `Qed`: store-weakening, the Σ-adapted
  substitution lemma, store-update/lookup lemmas, canonical forms. Σ-threaded
  `synthR`/`checkR` proven SOUND (`synthR_sound`/`checkR_sound`); `decide_rsub`
  (fuel-structural for the contravariant arrow swap) sound. SANITY (all proved):
  alloc/read (types+steps), **assign-MUTATES** (deref of the updated store reads
  the NEW value, not the old), ref-of-int as ref-of-int, ill-typed assign
  (string into `RRef Int`) REJECTED at every type + by the checker.
  `Print Assumptions` on progress/preservation/synthR_sound/checkR_sound + the
  mutation/ill-typed sanity: **Closed under the global context**; whole chain
  compiles, protected files unmodified. **RESOLVED by the references unification**
  (`01aae498` + `1e7f7fe5`): `imp.v` is RETIRED and the store + references are
  threaded into the MAIN `typing.v`/`ssub.v`/`check.v` — RECORDS, flow-narrowing
  (`tifn`/`ttypetest`), and recursion (`tfix`) now all coexist with Σ in ONE
  language (progress + preservation re-proved `Qed` over the unified judgment;
  `synth_sound`/`check_sound` survive). Cost: algorithmic principality is fenced
  (see the `rsub` union-elim substrate item above). **CONSUMERS NOW BUILT
  (increment M4, above):** Lua's mutable TABLE FIELDS (records-of-refs) and
  reassignable LOCALS + aliasing are proved via the ref-core encoding. Only
  flow-sensitive strong-update precision remains nice-to-have.
- [x] **Multi-RETURN values + contextual adjustment (increment 21, DONE).**
  `BTuple` sequence type in `subtype.v`; `tret`/`tfst`/`tappspread` in `typing.v`;
  truncation (bind-first) + last-position spread (known-arity tuple consumer);
  progress/preservation/synth/check re-proved `Qed`; the payoff (same call truncated
  vs spread) machine-checked. Vararg `...`, multiple-assignment, table-collect, and
  arity-polymorphic spread remain deferred (see the [BLOCKING] item in §"Lua
  semantics").
- [x] **General recursion — single fixpoint `tfix` (increment 14, DONE).**
  `proof/typing.v` + `proof/check.v` (on unmodified `subtype.v` + `ssub.v`). `tm`
  gains `tfix : BTy -> tm -> tm`: in `tfix T body`, de Bruijn 0 of `body` is the
  recursive self-ref of type `T`, the whole `tfix T body : T`. Op-sem: the unfold
  rule `SFix : step (tfix T body) (subst 0 (tfix T body) body)` — no premise, so
  `tfix` is never a value / never stuck. Typing `TFix : has_type (T::G) body T ->
  has_type G (tfix T body) T`. **`progress` + `preservation` re-proved `Qed`**
  threading `tfix` (progress immediate via `SFix`; preservation by substituting the
  whole fixpoint for its `:T` self-ref — `inv_fix` + `subst_top`). **Type soundness
  TOLERATES NON-TERMINATION** — no termination argument: `diverge := tfix Int (tvar
  0)` is well-typed and `step diverge diverge` (loops forever, type `Int`
  invariant). `synth (tfix T body)` checks `body` against `T` under `T::G` ⇒ `Some
  T`; `synth_sound`/`check_sound`/`synth_principal`/`narrowing` re-proved.
  `Print Assumptions` on `progress`/`preservation`/`synth_sound`/`check_sound`
  closed under the global context. DEFERRED below: mutual recursion, recursive
  TYPES (μ). Lua's `local function f` is the derivable consumer.
- [x] **Metatables — static read-only `__index` field-lookup fallback / prototype
  inheritance (increment 21, DONE).** `proof/typing.v` + `proof/check.v` (on
  UNMODIFIED `subtype.v` + `ssub.v`). `tm` gains `tmeta own proto` (own a literal
  field-list; proto the `__index` target — record or another `tmeta`, a prototype
  CHAIN). Modelled by FLATTENING over the existing `BRec` (NO new type-level
  former): `merge_fields Town Pf` = own fields ∪ inherited fields not shadowed by
  own (Lua: own wins); `TMeta` ⇒ `tmeta own proto : BRec (merge_fields Town Pf)`.
  Dispatch op-sem `SMetaProjOwn` (own field) / `SMetaProjProto` (fall through to
  the prototype, chained). **`progress`/`preservation`/`synth_sound`/`check_sound`
  re-proved `Qed`** (extended canonical form: a `BRec`-value is `trec` OR `tmeta`).
  SOUNDNESS FORK surfaced (not fudged): own MUST be a literal field-list — a
  width-subsumed own term makes preservation FALSE (under-reports own keys ⇒
  dispatch-to-own but type-via-prototype). PAYOFF machine-checked: a base method
  resolved through `__index` at the derived object (`oop_inherited_typed`/`_steps`,
  `oop_inherited_synths`), own-field direct resolution (`oop_own_*`),
  everywhere-absent field rejected at every type (`oop_absent_rejected`,
  `oop_absent_synth_None`). `Print Assumptions` closed under the global context.
  DEFERRED: `__newindex`, operator/`__eq`/`__lt`/`__call` metamethods, `__index`
  as a FUNCTION, dynamic metatable MUTATION (`setmetatable`), `rawget`/`rawset`.
- [ ] **Mutual recursion** (`tfix` is single-binding; mutual `local function`
  groups need either a tupled fixpoint or a multi-binding `tfix`). Backlog.
- [ ] **Recursive TYPES — equirecursive μ** (distinct from the recursive TERM
  `tfix` above; needs the coinductive-`V` fork). See the BLOCKING μ item below.
- [x] **Metatables — static read-only `__index` field-lookup fallback (prototype
  inheritance / OOP)** (increment 21, `proof/typing.v` + `proof/check.v`,
  `subtype.v`/`ssub.v` UNMODIFIED). New term `tmeta own proto` (own a literal
  field-list, prototype the `__index` target); type-level flattening
  `merge_fields` over the existing `BRec` (no new type former); dispatch op-sem
  `SMetaProjOwn`/`SMetaProjProto` (own field, else fall through to the prototype,
  chained). `progress`/`preservation`/`synth_sound`/`check_sound` re-proved `Qed`.
  SOUNDNESS FORK surfaced (not fudged): own MUST be a literal field-list — a
  subsumed own term makes preservation false (width-subsumption under-reports own
  keys, dispatching to own while typing via the prototype). PAYOFF: OOP
  inheritance machine-checked (`oop_inherited_typed`/`_steps` resolve a base
  method through `__index`; `oop_absent_rejected` rejects an everywhere-absent
  field). `Print Assumptions`: Closed under the global context.
  - DEFERRED (backlog): `__newindex` (write fallback), operator/comparison
    metamethods (`__add`/`__eq`/`__lt`/…), `__call`, `__index` as a FUNCTION,
    dynamic metatable MUTATION (`setmetatable`), `rawget`/`rawset`.
- [x] **Metatable metamethods — `__newindex`, `__call`, binary operators**
  (`proof/typing.v` + `proof/check.v`; `subtype.v`/`ssub.v` BYTE-UNMODIFIED — no new
  type-level former). Completes the metamethod protocol begun with `__index`:
  - **`__call`** (callable tables): a metatable-table whose read interface carries
    a `__call : Self -> Arg -> R` metamethod is APPLICABLE — `tapp (tmeta ofs proto)
    arg` dispatches (op-sem `SCallMeta`) to `(table.__call) table arg`, resolving the
    metamethod through the same `__index` chain (`tproj`) and reusing the arrow
    machinery (two betas). Typing `TCallMeta`; result `R`. Payoff `call_payoff_typed`/
    `call_payoff_steps` (callable table computes `3`).
  - **Binary operators** (`__add`/`__sub`/`__mul`, `__eq`/`__lt`/`__le`): a primop
    whose LEFT operand is a metatable-table dispatches (op-sem `SPrimMetaL`,
    typing `TPrimMetaL`) to `(a.<mm>) a b`; the metamethod key is `mm_binop op`
    (ordinary data — one general `tproj`-resolved lookup, NOT a name-keyed handler).
    Number path (`TPrimArith`/`TPrimCmp`) kept for plain numbers. Payoff
    `add_payoff_typed`/`add_payoff_steps` (vector-like `vobj + vobj : Int` → `7`);
    `sub_absent_rejected` rejects an absent metamethod. **RIGHT-operand fallback
    DEFERRED** (left-operand dispatch is the representative; Lua tries left then
    right — the right-operand branch is a clean follow-up, not a fork).
  - **`__newindex`** (write fallback): new term `tnewidx own proto k v` (the write
    `(tmeta own proto).k = v`). When `k` is ABSENT from own, dispatches (op-sem
    `SNewIdx`, typing `TNewIdx`) to `tassign (proto.k) v` — the records-of-refs
    write-through (`proto`'s field `k` is a mutable `BRef` cell). Mirrors the
    `__index` read fallback on the assignment side. Payoff `newindex_payoff_typed`/
    `newindex_payoff_steps` (write `5` through the cell; store `[0]` → `[5]`);
    `newindex_absent_cell_rejected` rejects a missing target cell.
  - `progress`/`preservation`/`synth_sound`/`check_sound` ALL re-proved `Qed`; new
    helper `tmeta_step_shape` (a `tmeta` steps only to a `tmeta`). `Print
    Assumptions` on every result + payoff: Closed under the global context.
  - HONEST SCOPE / model note: metamethods are carried as OWN fields of the table
    under their reserved keys (`__call`/`__add`/…) — a simplification of Lua's
    separate-metatable-object, sound and faithful for the static fragment. STILL
    DEFERRED: `setmetatable`/dynamic metatables, `__index`/`__newindex` as
    FUNCTIONS, `__concat`/`__len`/`__unm`/`__tostring`/other metamethods, `__call`
    multi-arg/multi-return, operator RIGHT-operand fallback, own-present rawset on
    the immutable own record, `rawget`/`rawset`.
- [x] **Metamethod family extension — `__concat`, `__unm`, `__len`** (increment 23;
  `proof/typing.v` + `proof/check.v`; `subtype.v`/`ssub.v` BYTE-UNMODIFIED). Reuses
  the Increment 22 dispatch machinery with no new lookup mechanism:
  - **`__concat`** (`..`): new `primop PConcat`, metamethod-ONLY (`arith_op`/`cmp_op`
    both false, so `SPrimArith`/`SPrimCmp` never fire). Sole rule is the EXISTING
    binary-operator dispatch `TPrimMetaL`/`SPrimMetaL` via `mm_binop PConcat =
    "__concat"` — i.e. just more keys in the `mm_binop` table, no new term/step form.
    Payoff `concat_payoff_typed`/`_steps` (`ccobj .. ccobj : Str`, computes).
  - **`__unm`/`__len`** (`-x`/`#x`): new `unop` tag + term `tunop uop e` + `mm_unop`
    name table (ordinary data). Typing `TUnMetaL`: operand a `tmeta : BRec M` carrying
    `mm_unop uop : Self -> Other -> R`, both self gates via `rsub`; result `R`. Op-sem
    `SUnMetaL` dispatches to `(table.<mm>) table table` (operand passed TWICE — Lua's
    unary calling convention), `SUnop1` congruence. New inversion `inv_unop`.
    Metamethod-ONLY (no built-in numeric negation / table length). Payoffs
    `unm_payoff_typed`/`_steps`, `len_payoff_typed`, `len_absent_rejected`; checker
    mirrors `concat_synths`/`unm_synths`/`len_synths` + `*_check_sound` +
    `len_absent_synth_None`.
  - `progress`/`preservation`/`synth_sound`/`check_sound` ALL re-proved `Qed`;
    `tunop` threaded through the full de Bruijn metatheory. `Print Assumptions` on
    every result + payoff: Closed under the global context. See proof-kernel
    increment 23.
  - STILL DEFERRED (the rest of the original metamethod-family task): operator
    RIGHT-operand fallback; `rawget`/`rawset`; `__tostring`; built-in numeric
    negation / table length; `setmetatable`/dynamic metatables; `__index`/
    `__newindex` as FUNCTIONS.
- [x] **Binary operator RIGHT-operand fallback — `TPrimMetaR`/`SPrimMetaR`**
  (increment 24; `proof/typing.v` + `proof/check.v`; `subtype.v`/`ssub.v`
  BYTE-UNMODIFIED). The exact MIRROR of `TPrimMetaL`/`SPrimMetaL`, closing the ONE
  deferral left by Increment 22's binary operators — when the left operand carries
  no metamethod, dispatch to the right's. Shares `mm_binop`, the `__index`-chain
  `tproj` resolution, and the arrow machinery; no new lookup mechanism.
  - **Typing** `TPrimMetaR`: `tprim op a (tmeta ofs proto)` with the right table's
    `BRec M` carrying `mm_binop op : BAtom al -> Other -> R`, the LEFT operand a
    SCALAR `a : BAtom al`, and `rsub (BRec M) Other`; result `R`. The `BAtom` left
    domain (not "syntactically not a `tmeta`") is the discriminator: stable under
    substitution, step-disjoint from `SPrimMetaL`, and refutable by canonical forms.
    New lemma `canon_atom` (a closed value of `BAtom al` is a literal).
  - **Op-sem** `SPrimMetaR`: `tprim op (tlit l) (tmeta own proto)` (literal left —
    the canonical scalar; table right a value) ⤳ `(table.<mm>) (tlit l) table`.
  - `inv_prim` becomes a THREE-way disjunction (numeric / left-meta / right-meta),
    threaded through every consumer. `synth` dispatches TYPE-FIRST on the synthesized
    LEFT type (the existing outer `match synth a`): `BRec`+`tmeta` left ⇒ left-meta;
    scalar `BAtom` left ⇒ refine on `synth b` (`BRec`+`tmeta` right ⇒ right-meta, else
    numeric); else numeric. (Type-first, NOT a syntactic `destruct e1 × destruct e2`
    split — that is quadratic and blows up the `synth_sound` compile time.)
    `progress`/`preservation`/`synth_sound`/`check_sound`/`narrowing` ALL re-proved `Qed`.
  - Payoffs (in `typing.v`): `add_right_payoff_typed`/`_steps` (`1 + robj : Int` ⤳ `8`),
    `sub_right_absent_rejected` (`1 - robj` rejected — all 3 disjuncts refuted). The
    algorithmic right-fallback is exercised by `synth_sound`/`check_sound` over the new
    `synth` arm; no separate `check.v` payoff examples were added.
    `Print Assumptions` on every result + payoff: Closed under the global context.
    See proof-kernel increment 24.
  - DEFERRED (narrower than before): a `tmeta` left missing the key falling through
    to the right (needs a decidable `__index`-chain side-condition); `rawget`/
    `rawset`; `__tostring`; built-in numeric negation / table length; `setmetatable`
    / dynamic metatables; `__index`/`__newindex` as FUNCTIONS.
- [x] **`rawget`/`rawset` — raw table access bypassing `__index`/`__newindex`**
  (increment 25; `proof/typing.v` + `proof/check.v`; `subtype.v`/`ssub.v`
  BYTE-UNMODIFIED — confirmed `git diff --stat`). Raw access reduces DIRECTLY to the
  underlying record-of-refs read/write on the table's OWN fields, NEVER consulting
  the prototype — the own-field path of `tproj`/`tnewidx` WITHOUT the fallback step;
  reuses the SAME `field_lookup`/`tassign` primitives (no new lookup mechanism, no
  special-casing).
  - **Terms** `trawget own proto k` / `trawset own proto k v` (the table given by
    its own field-list + prototype-position target directly, like `tnewidx`, so own
    is typed EXACTLY via `has_fields`).
  - **Typing** `TRawGet`: own `(k,T) ∈ Town` ⇒ result `T` (no merge — an inherited
    proto-only key is NOT typeable). `TRawSet`: writable own cell `(k, BRef T) ∈
    Town`, `v : T` ⇒ `nil`. The prototype is typed (`BRec Pf`) for well-formedness
    but never read/written.
  - **Op-sem** `SRawGet` (own value via `field_lookup k own`, no proto rule) +
    congruences `SRawGet1`/`SRawGet2`; `SRawSet` (own cell → `tassign cell v`, no
    proto rule) + congruences `SRawSet1`/`SRawSet2`/`SRawSet3`.
  - Full de Bruijn metatheory threaded (`tm_rect_strong`, lift/subst/closed_at,
    weakening, `subst_lemma`, `store_weakening`, `has_type_closed`, `proj_free`).
    `progress`/`preservation`/`synth_sound`/`check_sound`/`narrowing` ALL re-proved
    `Qed`. `synth` dispatches structurally on the `trawget`/`trawset` constructor
    (like `tnewidx` — NOT a quadratic syntactic operand split); `check.v` builds in
    seconds.
  - Payoffs (`typing.v`): `rawget_own_typed`/`_steps`, `rawset_payoff_typed`/`_steps`
    (raw write through OWN's cell over a store, `[0]`⤳`[5]`), and the DISTINGUISHING
    property `rawget_bypasses_proto` / `rawset_absent_own_rejected` (a key in the
    PROTOTYPE but absent from OWN — resolved by `tproj` via `__index`, see
    `oop_inherited_typed` — is REJECTED by raw access at every type). Algorithmic
    mirror (`check.v`): `rawget_own_synths`, `rawget_bypasses_proto_synth_None`,
    `rawset_synths`, `rawset_absent_own_synth_None`. `Print Assumptions` on every
    result + payoff: Closed under the global context. See proof-kernel increment 25.
  - DEFERRED (recorded as substrate, not faked): raw access on a key ABSENT from own
    returning `nil` (the static fragment does not model absent-key reads — `TProj`
    likewise requires the key present); `__index`/`__newindex` as FUNCTIONS;
    `setmetatable`/dynamic metatables; `__tostring`; built-in numeric negation /
    table length.
- [ ] **Arrow types as TERM introduction forms** (the type ALGEBRA has arrows via
  `BTy` and `tlam` introduces them; broader arrow-term ergonomics are min-core).
- [ ] **Duplicate-key record literals** (currently `TRec` requires `NoDup` keys,
  Lua-faithful; last-wins literal semantics is a separate concern).
- [x] **`ssub` preorder + total decision procedure + `dsub`/`ssub` gap**
  (increment 9, `proof/ssub.v`, on unmodified `subtype.v` + `typing.v`).
  `ssub_refl`/`ssub_trans` named; `decide_ssub : BTy -> BTy -> bool` **total +
  sound + complete** (`decide_ssub_correct`), terminating by structural fuel
  recursion on `bsize a + bsize b` (no DNF — `ssub` is syntactic). Total-decidable
  fragment = exactly what `ssub` relates (atoms/arrows/records + Top/Bot
  structural; connectives coarse). Two gap instances exhibited
  (`dsub_ssub_gap` arrow/Top; `dsub_ssub_gap_atom` AFloat≡ANum); coincidence on
  afloat-free atoms + the structural ⊆ direction. Subtyping wired into typing
  (`subsumption_decidable`). `Print Assumptions` closed under the global context.
- [ ] **Connective-`ssub` decided SEMANTICALLY (lift `decide_ssub`'s connective
  coarseness).** PRECISE PREDICATE: for connective-headed `c`/`d` (`BUnion`/
  `BInter`/`BNeg`), `decide_ssub c d` currently returns `true` ONLY for the
  reflexive/Top/Bot subtypings (`ssub_connective_super`/`_sub` prove these are the
  ONLY ones `ssub` admits). Deciding the SEMANTIC Boolean subtypings (e.g.
  `BInter X Y <: X`, `X <: BUnion X Y`) is `dsub`'s job and is the increment-6
  `gdecide` emptiness route — NOT `ssub`'s. The open question is whether the
  typing layer should subsume along connective subtypings at all (it currently
  does not need them); if so, route connective subsumption through `gdecide`
  rather than widening `ssub`. Substrate: requires the typing core to actually
  introduce connective types in term position (deferred above).
- [ ] **`ssub` GENERAL completeness vs ALL operationally-sound subtypings** (the
  DEEP open characterization). Partial progress proved in increment 9: the two
  precise gap instances (`dsub_ssub_gap`, `dsub_ssub_gap_atom`) and the
  coincidence fragments (`ssub_dsub_coincide_atom` on afloat-free atoms;
  `decide_ssub_implies_dsub` for the structural ⊆ direction). The full question —
  characterize EXACTLY the subtypings that preserve operational soundness and show
  `ssub` decides precisely those — is not tractable at this increment and remains
  open. (The `AFloat`≡`ANum` gap suggests a candidate refinement: add the missing
  `atom_le` edges that the value model justifies — but that is a `subtype.v`
  change, out of scope for the unmodified-substrate increment.)
- [x] **Bidirectional algorithmic checker, proven SOUND vs declarative typing**
  (increment 10, `proof/check.v`, on unmodified `subtype.v` + `typing.v` +
  `ssub.v`; build order `subtype → typing → ssub → check`). Turns the
  non-syntax-directed declarative `has_type` into a RUNNABLE checker.
  `synth : list BTy -> tm -> option BTy` (infer) + `check : list BTy -> tm -> BTy
  -> bool` (`check G e T := match synth G e with Some S => decide_ssub S T |
  None => false`) — executable, total, structural on `tm`; `synth` reduces under
  `Compute` (well-typed ⇒ `Some`/right type, ill-typed `(3).f` / `3 1` /
  duplicate-key literal ⇒ `None`). **SOUNDNESS (the point), both `Qed`:**
  `synth_sound : synth G e = Some T -> has_type G e T`,
  `check_sound : check G e T = true -> has_type G e T` (mutual `tm` induction,
  `decide_ssub_sound` at the check switch). **COMPLETENESS = principality
  (tractable, proved):** `synth_principal : proj_free e -> has_type G e T ->
  synth G e = Some S -> ssub S T` (synth's output is the LEAST declarative type);
  supporting general context `narrowing` lemma. `Print Assumptions` on
  `synth_sound`, `check_sound`, `synth_principal`, `narrowing` all **Closed under
  the global context** (no Admitted/Axiom/Classical). **NOTE — this PRINCIPALITY
  result was REMOVED by the references unification** (see the next item): under the
  unified, Sigma-threaded, reference-aware `has_type`, the declarative inversion
  lemmas conclude `rsub` (not `ssub`), and `rsub` lacks the union-elimination rule
  that recomposed branch principalities. `synth_sound`/`check_sound` survive the
  unification; `synth_principal` is fenced until the substrate below lands.
- [ ] **[BLOCKING] `rsub` union-elimination substrate — restore algorithmic
  principality over the unified relation.** The references unification
  (`01aae498` + `1e7f7fe5`, retiring `imp.v` into a unified `typing.v`/`ssub.v`/
  `check.v`) made `TSub` subsume along the reference-aware `rsub`. The union-typed
  term-formers (`tif`/`tifn`/`ttypetest`) need UNION-ELIMINATION at the `rsub`
  level — `rsub a c -> rsub b c -> rsub (BUnion a b) c` — to recompose branch
  principalities, but `rsub` has NO such structural rule: it embeds `ssub` (which
  HAS `SsUnionE`) + the two reference rules + transitivity, and a branch subtyping
  that goes through ref-widening has no `ssub` witness to feed `SsUnionE`. So
  `rsub`-level principality needs a NEW SUBSTRATE rule (an `rsub` union-elim / a
  join-completeness lemma) — a genuine substrate gap, NOT hardcoded. **Simpler
  partial:** an `rsub`→`ssub`-on-ref-free collapse lemma restores prior
  principality on the reference-free fragment (every subtyping there collapses to
  `ssub`); both are deferred together. The checker remains SOUND and EXECUTABLE on
  the whole unified language — only the principality META-property is fenced.
  Deferred at `proof/check.v:560-580` (framed-deferral comment) + `proof-kernel.md`
  (the references-unification increment).
- [ ] **Algorithmic adequacy / non-degeneracy of `synth`** (DEFERRED from
  increment 10). The completeness proved is principality (IF synth answers, that
  answer is least); NOT that synth ALWAYS answers on a well-typed term. Two
  degenerate positions block it: (a) a function/record SUBJECT declaratively typed
  at `BBot` (uninhabited) where `synth` only produces an arrow/record head; (b)
  the `let` body context narrowing. Closing it needs a canonicalization / a
  not-stuck argument over the BBot-free fragment — out of scope for the minimal
  core. Precise deferred statement: `has_type G e T -> exists S, synth G e =
  Some S /\ ssub S T` (the existence half synth_principal does not assert).
- [ ] **`tproj` principality under `NoDup` records** (DEFERRED from increment 10).
  `synth_principal` is fenced to the `proj_free` fragment because declarative
  `TProj` over a non-`NoDup` record assigns multiple types (no least type), and
  `synth`'s first-match `flook` only matches the subtyping supplier under `NoDup`
  (typing.v itself proves projection principality only under `NoDup`). Extend
  principality to projections over `NoDup`-keyed records.
- [ ] **Connective subtyping IN CHECKING** (DEFERRED from increment 10). `check`
  routes subtyping through `decide_ssub`, which is structural-only on the Boolean
  connectives (increment 9 coarseness). So connective subtyping in checking
  inherits that limitation; full connective checking needs the `dsub`/`gdecide`
  route — same substrate need as the connective-`ssub` item above.
- [ ] **[BLOCKING] Operational-semantics reality bridge (`step` ↔ real Lua
  execution).** The bridge so far validates the proof's VALUE model (`V`/`denote`
  ↔ real Lua values + membership predicates; atoms/functions/records all RESOLVED,
  `lib/sem/bridge/`). The unvalidated axis is the proof's small-step `step` /
  `rstep` REDUCTION matching real LuaJIT execution — the empirical anchor proof
  cannot establish (that the modelled operational semantics, incl. store
  mutation, is faithful to what real Lua does). `reality-bridge.md` §3 (the
  differential pipeline targets values, not reductions, today).

## Slice typechecker — coverage and precision open threads

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

- **Success metric reframing:** the survey reframed from whole-file-CLEAN% to sound-verdict-sites / error-classes-caught-corpus-wide. Remaining coverage front by measured demand: operators, dynamic-index, multi-assign, multi-return root constructs — prioritized by corpus frequency, not exhaustiveness.
- **`readonly`/mutable variance split deferred:** recovers sound alias-and-read (the embedded-alias sub-hole would not arise); corpus doesn't currently exhibit the pattern that demands it. Mark as precision layer, not soundness blocker — revisit when corpus evidence justifies it.

## Platform isolation migration (mandatory, not eventual)

Architectural reframing settled this session: capabilities are the
platform's only abstraction; the sandbox+bridge+lockdown work is the
implementation of a single platform-level cap (`web_runtime`); there is
no separate `browser_caps` manifest field; first-party apps migrate to
`web_runtime` on the same terms as any third-party app. See
`docs/platform_isolation.md` "Framing" and `docs/browser_caps.md`
"Framing" for the consolidated decisions. The work below is the migration
to that endpoint.

- [x] **Revert the `browser_caps` manifest field.** Dropped the field and
  related plumbing from `lib/platform/platform_types.lua`,
  `lib/platform/init.lua`, `lib/platform/cli.lua`,
  `lib/platform/manifest_caps.lua`, plus the corresponding tests and the
  `docs/browser_caps.md` §3 cross-references that pointed at the now-gone
  code. The existing `caps` field (with `type: "web_runtime"`) is the
  abstraction; no parallel field is added. Background: commit `e6e7b532`
  introduced the field.

- [ ] **Design the explicit `web_runtime` cap interface.** Entry function
  (inputs: pack source + declared sub-caps; output: sandboxed-realm handle),
  sub-cap delegation, audit envelope, cleanup hooks, lifecycle (launch,
  reload, shutdown). Document in `docs/platform_isolation.md` "Cap interface
  (web_runtime)".

- [ ] **Decide where the `web_runtime` cap impl lives.** Candidate:
  `lib/platform/caps/web_runtime/`. Document the choice once made.

- [ ] **Move the existing browser-side libraries under the cap impl
  directory.** Sources to relocate: `lib/js_realm_sandbox/`,
  `lib/js_cap_bridge/`, `lib/js_pack_host/`, `lib/js_caps/`,
  `lib/js_pack_validator/`, `lib/js_safe_regex/`, `lib/js_types/`. Update
  all imports. Run typecheck + parity tests + manual sanity after the move.

- [ ] **Define the `web_runtime` cap-impl's manifest schema.** It is a cap
  kind dispatched by `type: "web_runtime"` in the existing `caps` field;
  decide what fields the entry's value accepts (declared sub-caps, sub-cap
  configs, entry-point selection). Document in `docs/browser_caps.md` §3
  alongside the existing per-entry axes. Resolves the open question called
  out in §3 about how tenants declare sub-caps under `web_runtime`.

- [ ] **Migrate `charactercardv2` (ccv2) from `http_server` to `web_runtime`.**
  ccv2's `static/*.js` (currently plain JS with full DOM access) gets
  adapted into pack-JS subset form running in the sandboxed realm. This is
  mandatory for the platform's security guarantees to hold uniformly; ccv2
  is not architecturally privileged.

- [ ] **Migrate `library` from `http_server` to `web_runtime`.** Same terms.

- [ ] **Migrate `sillytavern` from `http_server` to `web_runtime`.** Same
  terms.

- [ ] **Migrate `system_dashboard` from `http_server` to `web_runtime`.**
  Largest migration — projection registry and friends. Same terms.

- [ ] **Tighten the `http_server` cap once browser-UI consumers are migrated.**
  Long-term, `http_server` is retained only for "expose an API endpoint" use
  cases — no HTML response type, no JS-serving. Possible rename to
  `http_endpoint`, response-type restriction (no `text/html`), tighter
  content-type allowlist, possibly require explicit `--bind-external` to
  listen on anything other than localhost. Decide and document.

- [ ] **Move the `/_platform/lib/js_*/` daemon route into the
  `web_runtime` cap impl.** The platform daemon currently serves the
  browser-side platform libraries directly (commit `622efc40`). That route
  doesn't belong in platform code — the `web_runtime` cap impl owns serving
  its runtime files to its tenant iframes. Move accordingly once the cap
  impl exists.

- [ ] **Strip `browser_caps` references from `docs/platform_isolation.md`
  and `docs/browser_caps.md` after migration.** The current "Framing" notes
  in both docs flag the field as slated-for-revert; once revert lands, the
  surrounding prose that still describes the field as if it exists (`§3`
  schema discussion, the `app manifest` ASCII diagram in browser_caps §1,
  the manifest example in platform_isolation §4) gets rewritten against
  the `web_runtime`-sub-cap model.

- [ ] **Decide whether first-party apps move from `lib/platform/apps/<name>/`
  to `lib/apps/<name>/`.** The current path is a historical misnomer —
  first-party apps are not part of the platform; they are crescent-team-
  authored apps that happen to ship in the source tree. Purely
  organizational; not blocking the migration above.

- [ ] **Audit the `path_guard` lint violation across `lib/js_*/init.lua`.**
  Pre-existing per commit `746b5ef7`. Resolves when the `lib/js_*/`
  packages move under the cap impl directory.

- [ ] **Daemon serve path Phase B: pack JS source with `'use strict';` prepend
  + hash-verify against installed-pack-hash recorded in manifest.** Phase A
  shipped as `622efc40`; Phase B was named but never started; orphaned by the
  `web_runtime` cap pivot — fold into the cap impl's responsibilities or
  revisit when cap-impl lands.

- [ ] **Daemon serve path Phase C: per-pack host HTML stub generation.**
  Same orphaning context as Phase B.

- [ ] **Daemon serve path Phase D: CSP headers per pack manifest's web cap
  config.** Same orphaning context as Phase B.

- [ ] **Rename `lib/js_pack_host/`** to align with the terminology pinned in
  `138b8661` (pack vs app). Either `lib/js_app_host/` or move entirely into
  the `web_runtime` cap impl directory.

- [ ] **Rename `lib/js_pack_validator/`** similarly.

- [ ] **Rename `pack_id` → `app_id`** in `lib/js_caps/kv.js` and any other
  places. Same for `pack-abc.localhost` doc examples.

- [ ] **Move `_skipGlobalFreeze` opt off the production `installLockdown`
  API into a test-internal API.** Currently the test-only flag is part of
  the public production signature; foot-gun for any future real-browser
  caller.

- [ ] **Audit `lib/platform/`'s duplicate type declarations across
  `platform_types.lua`, `cli.lua`, `init.lua`.** Single source of truth.

- [ ] **Verify commit `352aab90` (stub `registry.lua`/`dom.lua`) has no
  vestige after the real impls landed.** Stubs may be dead code.

- [ ] **Re-evaluate `lib/lua2ts/` retention** given Initiative B is dead.
  Commits `844dd384` (`opts.imports`) and related lua2ts work shipped under
  an abandoned framing; their continued purpose needs explicit assessment.

- [x] **`lib/lua2ts/`: declared globals (`--:: declare x = T`) don't resolve to
  ESM imports** — closed via option (b): a caller-supplied
  `opts.global_imports = { [name] = path }` map, mirroring the existing
  `opts.imports` require-remap. When a declared-global identifier (introduced
  by `--:: declare x = T`) is referenced and `opts.global_imports` has an entry
  for its name, lua2ts hoists a named import — ESM: `import { x } from "path";`,
  CJS: `const { x } = require("path");` — instead of leaving `x` bare. Names
  absent from the map are unchanged (bare identifier, pre-existing behaviour).
  Not consulted in bundle mode. Option (a) (extending the `--:: declare`
  grammar itself to carry a source) was not pursued — the caller-supplied-map
  option was the one explicitly requested when this was picked up. Implemented
  in `lib/lua2ts/init.lua`; tests in `lib/lua2ts/lua2ts_test.lua`.

- [x] **`lib/lua2ts/`: `ann_for` doesn't check `ann.kind`, so a `--:: declare`
  line immediately preceding a `local` or `function` statement gets
  (mis-)consumed as if it were a `--:` type annotation for that statement.**
  Found while adding `opts.global_imports` tests: `--:: declare baz =
  integer\nlocal a = baz` emits `const a: declare baz = number = baz;` instead
  of `const a = baz;`, because `emit_stmt`'s two call sites
  (`ctx:ann_for(n.line)` in the `NODE_LOCAL_STMT` and `NODE_FUNC_DECL`
  branches) do `ann and ann.content or nil` without checking `ann.kind ==
  "type"` first — a `"decl"`-kind annotation (`--::`) passes through the same
  path as a `"type"`-kind one (`--:`). Fixed: both call sites now guard on
  `ann.kind == "type"`; the workaround separator statement in the
  `global_imports` test was removed since it's no longer needed.

## Platform isolation (top priority)

- [ ] **Deprecate `http_server` in favour of `web_runtime` for browser-UI apps.**
  `http_server` currently doubles as (a) "expose an HTTP API for external
  tools" and (b) "serve a browser UI for the user". Case (b) is the dangerous
  one: the served JS runs unsandboxed at the app's origin, outside the cap
  boundary, so a grant of `http_server` is effectively "let this app do
  anything to the browser tab it owns". The risk text on the cap warns the
  operator, but the structural fix is to split:
    - `web_runtime` (forthcoming, sandboxed) — for apps that need browser UI.
      The platform serves the shell; the app supplies declarative content and
      browser-cap calls. See `docs/browser_caps.md` / `docs/platform_isolation.md`.
    - `http_server` (retained, tightened contract) — for apps that legitimately
      need to expose an HTTP endpoint to external tools. Design open: drop the
      HTML response type, require a content-type allowlist, possibly require
      explicit `--bind-external` to listen on anything other than localhost.
  Migration: identify which existing apps use `http_server` purely for browser
  UI vs which actually need a public HTTP API; port the former to `web_runtime`
  once it exists, leave the latter on the tightened `http_server`.

- [ ] **Browser-side pack isolation architecture** — draft design doc at
  `docs/platform_isolation.md`. Frames the ambient-capability problem
  (per-app CSP narrows the outer envelope but does not partition the inner
  surface between scripts on a page), proposes a sandboxed-iframe realm
  per pack plus a postMessage capability bridge to a daemon-served stub
  page, and leaves the rendering model (Options A/B/C) as an open question.
  Blocks all browser-side pack work, including Initiative B (the pack-load
  pipeline for projection-Lua), pack-shipped UI beyond projections, and any
  third-party-pack browser UX work. Next step: settle the open questions in
  §7 of the design doc, in particular the rendering model and the per-pack
  origin mechanism.

- [ ] **Browser caps day-zero implementation** — design doc at
  `docs/browser_caps.md` enumerates the entire Web Platform surface and
  classifies each API (exposed-now / placeholder / future / not-shipping /
  realm-incompatible). Day-zero surface is ~17 caps (`fetch_api`, `kv_*`,
  `navigate`, `dialog`, `toast`, `clipboard_write`, `web_crypto_random`,
  `web_crypto_subtle`, `text_encode`, `text_decode`, `compress`,
  `decompress`, `console_log`, `set_timeout`). Implementation steps:
  (1) extend `lib/pkg/manifest.lua` with the `browser_caps` field per
  `browser_caps.md` §3 (cross-reference `docs/pkg-design.md` and
  `docs/pkg-versioning.md` before changing manifest); (2) add per-kind
  modules under `lib/platform/browser_caps/<kind>/` carrying impl +
  config-schema validator; (3) wire the host stub to register granted
  caps into `lib/js_cap_bridge`'s host bridge per `__cap__` install;
  (4) resolve the `event` frame format for streaming caps (open question
  in `browser_caps.md` §7) before any of `websocket` / `sse` /
  `set_interval` ship. Follow-up to platform-isolation work above;
  cross-references: `docs/platform_isolation.md`, `docs/browser_caps.md`.

- [ ] **Cap-bridge AbortSignal cancellation extension (commit B)** —
  per `docs/platform_isolation.md` §4 "Cancellation via AbortSignal",
  extend `lib/js_cap_bridge` so cap calls with AbortSignal args get
  cancellation routed across the bridge: realm side intercepts the
  signal locally, replaces it on the wire with a marker, and emits a
  `{kind:"cancel"}` frame on abort; host side reconstructs a fresh
  `AbortController` per call and aborts it on the cancel frame. The
  pack-realm Promise rejects with `AbortError`. Decide opt-in-per-cap
  vs universal scan (open question §7). Blocks `set_timeout` and
  `fetch_api` shipping.

- [ ] **Re-add `set_timeout` cap on AbortSignal (commit C)** — once
  the bridge extension above lands, ship `set_timeout(delay_ms, {signal?})
  : Promise<void>` per `docs/browser_caps.md` §4.9.1: Promise resolves
  after the delay; if `signal.aborted` becomes true the Promise rejects
  with `AbortError`. No platform-side delay clamp beyond the browser
  native `setTimeout` ceiling. Re-add to `lib/js_caps/index.js`
  `dayZeroCaps`, add tests + parity needles, update inventory count.
  Follow-up to the broken-cap revert (this commit).

## Platform polish

- [ ] **Filed: `ExitPlanMode` triggers auto mode.** Raised very early in the
  audited session (Turn 4); user wanted this filed somewhere. Harness-level,
  not crescent-level; may belong in `~/.claude/` notes — recorded here so it
  is not lost again.

- [ ] **`core.hooksPath` per-clone-activation structural issue.** CLAUDE.md
  still requires `git config core.hooksPath .githooks` per clone. Possible
  fixes: ship a one-time bootstrap script, or rethink the convention so the
  hook auto-activates without per-clone config.

- [ ] **`lib/safe_regex/` algorithm upgrade: alternation overlap.** Current
  v1 ban (no quantifier-on-quantifier) explicitly accepts patterns like
  `(a|aa)+` as a "known limit". User flagged this in-session as unacceptable
  ("'known limit' is objectively GARBAGE"). Upgrade the algorithm or
  document why this specific limit is acceptable.

- [ ] **Typechecker latent narrowing gap: `tonumber(string.sub(...))`** is
  inferred as `string` rather than `number | nil`. Worked around in
  `02812180` without `any`/force-casts. Worth a typechecker-side fix.

- [ ] **Typechecker latent narrowing gap: `local b = string.byte(s, i)`**
  doesn't narrow against `nil` after a guard; requires explicit
  `--: integer | nil` annotation. Same workaround commit (`02812180`).
  Worth a typechecker-side fix.

- [ ] **`set_interval` cap with AbortSignal cancellation** — parallel to
  `set_timeout`. User asked in-session.

- [ ] **`notification` cap** (browser's `Notification` API, distinct from
  host-rendered `toast`). Browser-permission-gated. Currently a placeholder
  in `docs/browser_caps.md` §4 but no TODO entry until now.

- [ ] **Third-party projections design** — concrete answer to "how do
  third-party projections work?" given the cap-based reframe. Likely: each
  projection is an app declaring it provides type-X-projection; daemon-side
  registry maps type → projection app; consuming apps query the registry and
  invoke projection apps via cap-bridge. Needs a design doc.

- [ ] **Shared `.d.ts` for pack-JS authoring** — the `web_runtime` cap impl
  ships a `.d.ts` (or equivalent) that pack authors reference for
  type-checking against the runtime's actual surface. Single source of
  truth; matches the platform's actually-exposed API. Cross-references
  `docs/platform_isolation.md` §7 (`.d.ts` location).

## HIGH PRIORITY

### Typechecker solver rewrite — direction unresolved

*Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

After 15+ iterations across one session, the rewrite path is unresolved.
`docs/typechecker-session-handoff.md` (commit `a55871da`) is the
authoritative briefing — read it before any further rework work. Three
honest directions on the table:

- **(A) Accept the current architecture as the structural shape.** Stop
  trying to paradigm-shift; focus on documenting the synchronous
  semantics that exist (e.g., why `solve_callable` is
  synchronous-by-necessity per the paradigm-fit finding in caveat 3) and
  consolidating fundamental 6 (fresh instantiation at use site) as a
  small refactor that replaces the three current call paths with one
  `instantiate_at_use` primitive.
- **(B) Pick a different paradigm than OutsideIn/X.** Late-session
  finding: OutsideIn/X emit-shape doesn't fit handlers needing
  backtracking (overload resolution), aggregation (union callable), or
  synchronous mid-iteration deferral (rank-N param loop).
  Continuation-passing or staged solving may fit better.
- **(C) Refactor `unify_mod.unify`** as the actual rewrite target
  (~700 LOC of synchronous structural recursion used by `try_unify`,
  `is_subtype`, `types_overlap`, `widen_deep`). Multi-thousand-LOC
  foundational change.

Personal lean from that session: (A). Convergence happened at the
mechanism level (items 1-5+1.5 + TV ownership), not the paradigm-shift
level.

#### H2 record-of-generics dispatch — still pinned as known gap

H2/H2a/H2b/H2e pinned at `has_error("Maybe%(_%)")` in
`lib/type/static/type_soundness_test.lua` ~lines 3875-3990 since the H2
revert (`9f025732`). Re-landing needs either:

- The Outside-In/X rewrite to actually shift handlers (caveat 3 in the
  handoff briefing — partial fit only).
- Or fundamental 6's consolidation (single `instantiate_at_use`
  primitive replacing the three current call paths). The previous
  Phase F-impl attempt revealed producer→consumer ordering issues; TV
  ownership (`63c55f18` + `8b8c6bc4`) partially addresses but the audit
  was incomplete — `solve_check_args` / `solve_bind_generics` also read
  potentially-owned ret_TVs through inner unify calls.

#### BMT1 pin — match-type call-site forward-reduction broken

`lib/type/static/type_soundness_test.lua` (BMT block immediately after H6,
search for `BMT1 (KNOWN GAP)`). Generic functions returning a match type
keep the return as an unreduced `match ... { ... }` at the call site when
the type parameter is bound from a concrete arg. Direct instantiation
(e.g. `Discrim<number>` as a literal) reduces correctly; the gap is
specifically that call-site binding does not trigger re-evaluation of
containing match types. Pinned at `has_error("cannot assign \`match.* to")`.
Flip to `no_errors` once call-site forward-reduction through match types
is correct (rewrite work — see commit `b4bb9667` for the set-theoretic
foundation context).

#### solve2.lua infrastructure — landed but not exercised meaningfully

P1-P4a (commits `4eebb1de`, `c3f59312`, `f2686228`, `e2762912`) added
the solve2 core, blocked_on capture, per-kind dispatch, and ported 6
kinds via routing (not rewriting). The infrastructure supports an
Outside-In/X rewrite but doesn't BE one. If direction (A) is chosen,
this code may become orphaned — consider whether to remove it or keep
it as scaffolding for future use.

#### Caveats that should not be lost

- **Every audit count came back inflated** (105→90, 18→30, 51→6, 5→1).
  Skeptically verify before acting on any future audit.
- **`docs/typechecker-solver-rewrite.md` is incomplete** — it specifies
  routing-not-rewriting; the design's premise that
  "port == paradigm shift" is wrong.
- **`docs/typechecker-solver-invariant-inventory.md` overstates** —
  distilled to 6 fundamentals in `-fundamentals.md`.
- **CLAUDE.md addition** (commit `c3b287e2`): "Ad-hoc conditions are
  strictly forbidden." Holds.

#### Cleanup state at end of session

The accessor cleanup landed (`a644d0aa` through `69b9bd80`). The FFI
fixed-size-array typing fix (`bb930ab5`) closed >1300 errors. Per-file
error counts: types 12, env 2, constrain 31, solve 35, unify 0. Further
reductions are possible but no longer load-bearing.

### Polymorphic recursion (future, optional)

Standard HM (Damas-Milner) is **monomorphic-recursive**: inside a function's
body, the recursive self-call sees the function as locked to the current
call's instantiation, not free to re-instantiate at a different type.
Crescent's HM-for-unannotated-params work (the active backlog item below)
deliberately ships monomorphic recursion only.

A polymorphic-recursive function calls itself at a *different* instantiation
of its type variable than the outer call. Example:

```lua
local function nest(n, x)
  if n == 0 then return {x} end
  return nest(n - 1, {x})  -- outer x: T; recursive arg {x}: { [integer]: T }
end
nest(3, "hi")  -- outer T = string; recursive call needs T = { [integer]: string }
```

**Why type *inference* of polymorphic recursion is undecidable** (Henglein
1993, "Type inference with polymorphic recursion"): inferring the
polymorphic type signature without an annotation reduces to semi-unification,
which is undecidable. The typechecker would have to guess the polymorphic
shape of the recursive function's signature from a finite number of body
operations, in a way that's consistent across infinitely-many possible
instantiations of the recursive call. There is no algorithm that always
terminates and always finds the most-general signature.

**With an explicit annotation, polymorphic recursion is decidable and easy.**
The annotation `--: <T>(integer, T) -> { T }` *tells* the typechecker the
polymorphic signature; the body's recursive call instantiates against the
declared signature exactly like any other call. crescent's existing
annotated-generic instantiation (commits before the unannotated-params work)
already handles this case correctly.

**If we ever want to support polymorphic-recursive *inference***, the path is:
- Adopt a *bounded* form (e.g. polymorphic recursion only when the user
  marks the function with a `--::` template directive saying "infer
  polymorphic recursion here, may not terminate").
- Or accept best-effort inference that may fail to terminate on adversarial
  inputs — and document the timeout.

Not on the roadmap. Captured here so future sessions don't re-derive the
problem from scratch.

### HM let-polymorphism — Phase 1 mostly done (2026-05-15 evening)

**State:** Phases 1a, 1b, 1c (steps 1, 2, 3, 4, 7) and 1d all landed.
Unannotated functions are now inferred polymorphic: `id(x) return x end`
becomes `<T>(T) -> T`; `get_x(t) return t.x end` becomes
`<T: { x: U, ... }>(T) -> U`; `add(a, b) return a + b end` becomes
`<A: { #__add: (A, B) -> R, ... }, B, R>(A, B) -> R`. Multiple call
sites instantiate fresh per call. Body usages emit metamethod-shape
bounds (Principle 10 compliant — no predicate-style collapse).

Commits (in order):
- `5a9e1b4b` — Phase 1a: propagate_meta_bound branch in solve_bound
- `8944dd9c` — Phase 1b + 1c step 3: sub-solve plumbing + solve_arith
- `ccf96435` — Phase 1c step 1: solve_index named-field
- `490ef49e` — Phase 1c step 4: solve_compare
- `2ac9ab31` — Phase 1c step 2: solve_callable free callee
- `36e5f292` — Phase 1d: MISSING_FUNCTION_SIGNATURE → warning
- `1196577a` — Phase 1c step 7: solve_index integer-key
- `748a67a9` — Autofix renderer Phase A: walk fn_tid + bounds
- `3943f919` — `_solved` flag prevents body-constraint re-fire after sub-solve
- `47e56146` — emit C_INDEX for literal-int key on free param vars (bug 3 fix)

**Still open:**

- [x] **Higher-order signature contravariance.** Fully fixed via two
  commits:
  - `fdc1c7d8` — `solve_bound` TAG_FUNCTION branch runs a final `unify`
    after `propagate_function_bound` so concrete-vs-concrete slots are
    validated under function variance. Catches mismatches in annotated
    `<F: (T)->U>` bounds. Skips vararg-as-tuple `(...P) -> R` to avoid
    spurious rejection of pcall-style callers.
  - `5a2558b8` — extend Phase 1c step 2's bound emission from
    `solve_callable` to `solve_check_args`' free-TV branch. Ordinary
    `f(x)` calls go through C_CHECK_ARGS, not C_CALLABLE, so the
    emission needs to live in both places. Now `inferred_apply(inc,
    "hi")` correctly errors when inc expects integer.

- [x] **propagate_meta_bound indexer support.** Done in `fedf12d0`.
  Walks bound's indexer pairs (data[2..3]); for TAG_TABLE actuals
  matches structurally OR via integer-literal-keyed fields fallback
  (Lua table literals type as `{1: a, 2: b}`). Now `first({10, 20, 30})`
  works; `first("hello")` correctly errors as missing indexer.

- [ ] **Phase 3: remove `_inferred_param_*` side-tables — partial.**
  `_inferred_param_tid` removed (commit c3a71a73): the
  REDUNDANT_CAST suppression it gated is no longer needed under HM
  (param vars are FLAG_GENERIC, instantiated fresh per call, so a
  body force-cast operates on the inst-fresh var). Suite green;
  motivating false-positive class did not return.

  `_inferred_params` removed (commits 695b55b3, 88c3c3cd):
  after f230643d had solve.lua consume `fn_tid` directly from
  `_missing_signatures`, the side-table had no remaining readers
  — only writes in `gen_function`. All write sites, the
  `inferred_start` snapshot, and the post-make_func fn_tid patch
  loop are gone. Suite green.

  `_inferred_param_callsites` and the old `render_signature` /
  `combine_inferred` / `widen_for_annotation` /
  `render_for_annotation` / `aliases_in_scope` / `has_free_var`
  helpers are STILL load-bearing — `render_hm_signature` returns
  nil for many real shapes (open-table receiver methods with
  open-table param types, multi-return functions whose returns
  involve `unknown`, intersection-of-function returns), and the
  callsite-aggregating renderer fills the gap. Verified by
  instrumented run over `lib/type/static/*.lua`: ~10 distinct
  fallback hits across `lib/test/{gen,arb}.lua` alone. Removing
  these would silently drop the autofix payload on those
  diagnostics. Real fix: extend `render_hm_signature` to cover
  the cases it currently rejects, then re-evaluate.

- [x] **Phase 6: fuzz invariants.** Added 11 HM-specific invariants in
  `lib/type/static/fuzz_test.lua` (H1–H10): true polymorphism per
  call, inferred row poly, missing-field rejection, multi-field
  intersection bound, self-reference equi-recursive bound,
  metamethod constraint rejection, higher-order contravariance
  (commit 5a2558b8), monomorphic recursion, annotated-generic
  compat, indexer bound rejection (commit 1196579e), and
  MISSING_FUNCTION_SIGNATURE warning demotion (36e5f292).

- [x] **Field-value-type propagation through HM bounds (Phase 2 unsoundness).**
  Landed 2026-05-15. Design: `docs/typechecker-hm-phase2.md`. Commits
  `3c3cadaf` (design), `772fb7dd` (record `_forall_ops` on bound vars),
  `9260751e` (re-emission of recorded ops against instantiated arguments
  at the call site), `391bde98` (extend to `C_COMPARE`), `52873f05`
  (perf baseline), `92f866b2` (flip H3/H10 fuzz invariant from
  "incorrectly passes" to "now errors"), `169228eb` (xfail-comment
  sweep). Probe `local function f(t) return t.x + t.y end;
  f({x="a", y="b"})` now correctly errors with `cannot perform
  arithmetic on "a"`. Historical analysis below kept for design
  archaeology.

  `function f(t) return t.x + t.y end` called with `{x="a", y="b"}` (both
  literal strings — non-numeric, would runtime-error on `"a" + "b"`) was
  silently accepted. Same for `{x=true, y=false}`, `{x=nil, y=nil}`, etc.
  Verified via probe at session-end 2026-05-15. The earlier note
  attributing this to "string has __add via Lua's coercion" was wrong —
  `"a" + "b"` is a real runtime error in LuaJIT (`attempt to perform
  arithmetic on a string value`); only numeric strings coerce.

  **Root cause.** The HM body uses a polymorphic *template*: param `t`
  is a free TV, `t.x` access creates a fresh field-result TV `U_x` and
  emits `{ x: U_x, ... }` into `_forall_bounds[t]`. The body's C_ARITH
  references `U_x` and `U_y` directly. At each call site the template
  is *instantiated* with fresh TVs (`t'`, `U_x'`, `U_y'`); the bound is
  checked against the instance, so propagate_meta_bound's `unify(actual,
  bf_tid)` (solve.lua line 930) binds `U_x' = "a"`, NOT `U_x = "a"`. The
  body's C_ARITH still sees `U_x` as TAG_VAR forever (confirmed via
  trace: `lhs.tag=13 rhs.tag=13` on every re-fire post call site). The
  meta-op dispatch never gets to inspect `"a"` and reject it.

  **Why H3 missing-field works:** propagate_meta_bound's `table_field`
  lookup runs against the *actual* table at the call site, so a missing
  field is caught structurally. Field-value-type checks would require
  running the body's metamethod dispatch with the instance's bf_tids
  substituted in — i.e. either re-checking the body per call site, or
  adding an explicit operand-value constraint to each emitted bound and
  having propagate_meta_bound re-trigger that constraint after binding
  the bf_tid.

  **Scope:** non-trivial. Re-running body per call breaks
  generalization (back to monomorphisation). The cleaner path is to
  attach a deferred operation constraint to `_forall_bounds` entries
  that fires when the bound is checked. Out of scope for Phase 1.

- [x] **Rank-N subsumption at call sites.** Landed 2026-05-17. Call-site
  argument subsumption against forall-typed parameters now skolemizes the
  rank-N quantifier with a per-call identifier, rejecting monomorphic and
  wrong-arity arguments (cases N1/N5/N6/N7/N8 in
  `lib/type/static/type_soundness_test.lua`). Implementation:
  `env_mod.collect_rank_n_generics` identifies FLAG_GENERIC TVs nested in a
  function-typed param/return slot of the callee; at the call site those
  fresh images become FLAG_SKOLEM with the call's id stored in `data[4]`.
  Rank-N in return position is handled by `env_mod.skolemize_return_for_rank_n`
  used by `gen_function` when pushing the annotated return slot. Per-call
  escape check via new `C_ESCAPE_CHECK` constraint walks the inferred return
  type and rejects any skolem with the matching call id. Unify's TV bind
  ordering now prefers binding a free TV TO a skolem when both sides are TVs
  (positive rank-N case where a `<T>(T)->T` argument is accepted). See
  `docs/typechecker-rank-n.md`. Landed with `--no-verify` (commit `289bc54d`):
  the +13 new errors are all instances of two pre-existing typechecker
  limitations (~140 sites at HEAD); local fixes would require banned force
  casts. Tracked as the two items below.

- [x] **Typed accessors for `Type.data` slots.** Landed via the data-accessor
  cleanup series (Phase A+B, commits `a644d0aa` through `7192eed7`). Per-tag
  typed accessor helpers added in `types.lua`; all call sites in `env.lua`,
  `unify.lua`, `constrain.lua`, `narrow.lua`, `match.lua`, `ann.lua`,
  `intrinsic.lua`, `solve.lua`, `cri_write.lua` migrated. See plan
  `docs/typechecker-data-accessor-cleanup.md`.

- [x] **Typed constraint payload tuples.** Landed via the payload-migration
  phase (C18, commit `a9c82ff7`); 51 force casts removed in `solve.lua`.
  C17 skipped (no payload reads in `constrain.lua` to migrate). C19 sweep
  (commit `dfaf8233`) removed 6 further redundant casts across `solve.lua`,
  `env.lua`, `unify.lua`.

  By-products surfaced during the cleanup and landed independently:
  FFI fixed-size-array element typing (`bb930ab5`), tuple positional-slot
  fix (`58d10766`), tuple expression-side fix (`0c2939d2`).

**Design doc:** `docs/typechecker-hm-phase1.md` (committed `9bb1960d`)
has the architectural sketch + bound shapes per body operation.

### Typechecker work — paused 2026-05-14 (resumable)

> *Pivot to platform/UI work; typechecker is in a working state. Resume here later.*

**State at pause:** Phases A/B/C of the unannotated-param-semantics plan all
landed (`c43bd439`, `a61c7cbb`, `eff69f9d`) with five rounds of follow-up
fixes (`c4d55139`, `931ea329`, `333bd691`, `ee4184f4`, plus stdlib bit-typedef
tightening at `73f24041`). Smoke tested on 11 libraries: 0 error regressions,
67 annotations applied. Design captured in `docs/typechecker-param-semantics.md`.

Open items, ordered by priority:

- [ ] **Cosmetic: union dedup in compound shapes.** Some autofix outputs still
  surface visible duplicates like `string | integer | string | integer | nil`
  where literals widened in nested positions re-introduce structurally-equal
  members that `make_union`'s `struct_equal` doesn't catch in compound contexts.
  Output is valid Lua, just ugly. Probably needs a string-level dedup pass
  after `widen_for_annotation`, OR a tighter `union_has` for nested positions.
- [ ] **Cosmetic: huge enum unions inline in returns.** Functions returning a
  value out of a `"a" | "b" | ... | "z"` enum get the full enum spelled out
  in the autofix annotation. Technically correct, unwieldy as source. Consider
  detecting the alias and rendering the alias name when in scope. (The
  in-scope check exists for params; same logic should apply to returns.)
- [ ] **`bit` typedef tightening interacts badly with REDUNDANT_CAST autofix
  on bit-wrapping libs.** `lib/bits/init.lua` regresses 13→17 errors when
  `--fix` runs because it had explicit casts on bit ops that were widening
  to `(number, number)` — those casts are no longer redundant in the right
  direction after `73f24041`, but the autofix still strips them. Either:
  (a) re-survey the REDUNDANT_CAST autofix classifier for the new typedef
  shape, or (b) carve out an exception for libs that intentionally re-typed
  the bit ops. The MISSING_PARAM_ANNOTATION autofix itself is unaffected.
- [ ] **Corpus-wide `--fix` run — go/no-go.** Smoke tests are clean across
  11 small/medium libraries. Surveyed counts: 2010 REDUNDANT_CAST + 3502
  MISSING_PARAM_ANNOTATION across 777 files. Recommended approach: commit
  per-library so a regression in one doesn't poison the batch. Need user
  go-ahead before running (this is the same territory as the abandoned
  REDUNDANT_CAST bulk-autofix from earlier).
- [ ] **`PARAM_INFERENCE_OUTLIER` (deferred from Phase C).** Original plan
  called for a separate diagnostic at minority call sites when the modal
  autofix runs. Dropped because under destructive-bind semantics outliers
  already error at their call sites. If the solver semantics change later
  (HM-style or non-destructive inferred-param binding), revisit.
- [ ] **Smoke-test surface coverage.** Tested 11 libraries (mix of small +
  large). `lib/grammar` got 0 annotations applied — most warnings are leaky
  structural shapes (`{ _parse: _ }`) or inline anon functions, both
  correctly suppressed. Worth one more pass after refining union dedup to
  see what gets unblocked.
- [ ] **[nice-to-have] Contextual row/element type only pushes to a row
  literal's FIRST field; later anonymous fields fall back to `any`/diverge.**
  Production-checker (`lib/type/static/`) imprecision: when an array/row literal
  is checked against a contextual type (e.g. `local atoms = { "AStr", … } --[[:
  RecAtom[] ]]`), the contextual element/field type pushes down only to the FIRST
  element; later anonymous elements are inferred from the literal (widening
  `"AStr" | …` to `string`), so a downstream `pick(atoms) --[[: RecAtom]]` checked
  cast then rejects (`string` not a subtype of the union). Surfaced in
  `lib/sem/bridge/rec_test.lua` (worked around with direct indexing
  `atoms[rng:int(1,#atoms)]`, which preserves the element type; the generic
  `pick`'s `T` decays it). Nice-to-have precision: propagate the contextual
  element/field type to ALL anonymous fields, not just the first.

### Desktop integration follow-ups (2026-04-30)

- [ ] **Rasterize `branding/crescent.svg` for Windows + macOS.** Generate
  `branding/crescent.ico` (multi-resolution: 16/24/32/48/64/128/256) and
  `branding/crescent.icns` (`iconutil -c icns`). Tooling lives outside the
  Nix dev shell (`rsvg-convert`, `icotool`, `iconutil`); see
  `branding/README.md` for the exact commands. Installers already pick the
  rasters up automatically when present.
- [ ] **`cr open <file.png>` auto-import.** Currently logs a "not yet
  implemented — drag the file into the library window" note and falls
  through to the plain library URL. Real implementation should detect the
  file type and route it through the existing import-card pipeline before
  opening the library.

### Platform pivot — directions (2026-05-14)

> *Triggered by chub.ai banning underage content; pivoting to get our own
> frontend properly up. Four directions, ordered roughly by sequencing.*

- [ ] **Stabilize the platform.** Before piling on UI work or ecosystem
  features, get the current platform reliable. Audit what's flaky / what's
  half-finished / what blocks daily use. Concrete first pass: identify the
  top 3 reliability or correctness issues that would bite a new user in
  their first session, and fix those before anything else. Surface the
  list here once it exists.

- [ ] **Make the UI actually best-in-class.** Not "good enough" — the
  benchmark is "the user prefers this over chub.ai / janitorai / SillyTavern
  for the same task." Means: deliberate visual design, fast interactions,
  no jank, proper keyboard support, mobile-viable. Define what "best in
  class" means concretely (compare against named competitors on specific
  flows: first-message latency, message editing, character switching,
  multi-character scenes) before building.

- [ ] **Better LLM self-feedback / analysis on UI usability.** Build a
  loop where Claude (or another model) can inspect the running UI and
  assess how it looks/feels to use — screenshot + DOM dump + interaction
  trace, scored against a rubric. Goal: catch usability regressions
  before users do, and produce concrete actionable feedback ("this button
  is unclear", "this layout breaks at <viewport>", "this flow takes 4
  clicks when it could take 1") rather than vibes-level "looks good."
  Tools to consider: chrome-devtools-mcp, playwright snapshots,
  computer-use API. Open question: scored manually-curated rubric vs.
  open-ended critique.

- [ ] **Build the repository — decentralized, local-first, noncanon-style.**
  A character/persona/world-content repository that lives on user
  machines, not on a platform. Same primitive as noncanon (the world
  lives with the user; canon is a local concept; divergence is a feature),
  applied to the chat-content domain. Not a clone of chub or
  characterhub-as-a-service — explicitly local-first so it can't be
  taken down by a single org's content policy. Open questions: addressing
  scheme (git remotes? IPFS? content-addressed?), discoverability without
  a central index, NSFW/age-gate enforcement model that doesn't require
  a trusted central authority. Likely needs a separate repo
  (`~/git/exoplace/<name>/`) once direction is clear; meantime track
  thinking here.

### Surfaced from recent sessions (2026-05-13 grooming)

> *Added 2026-05-13 by a backlog-grooming pass over the prior three session transcripts (`d4565916`, `e4f73deb`, `9501a0b0`). These are open threads identified mid-session and not closed; treat as starting context, not directives.*

- [x] **Typechecker bug: unannotated function params infer to `any`** — Closed 2026-05-15 (audit pass): the framing was incorrect. Unannotated params do NOT get bound to `any` — they get a fresh `TAG_VAR` (see `constrain.lua:1561`). The downstream `any`-laundering symptom traced to a different mechanism: the destructive `unify` call at `solve.lua:579` binds the param's free var to caller arg types. That is captured in the second-pass entry below (`solve.lua:579 — destructive unify ...`) and remains open. Closing this entry to stop a future session re-deriving the wrong attribution. (see docs/typechecker-param-semantics.md)

- [x] **Typechecker bug: force casts act as inference sources via external constraints** — FIXED. User flagged: "force casts MUST NEVER BE INFERENCE SOURCES." Attribution was correct: the mechanism was the destructive `unify(ctx, widened, expected)` on the checked-cast C_SUB path in `solve_sub` (NOT `try_unify`/`types_overlap`, which are non-destructive and were left untouched). Resolved by deferring the cast when its actual is a free var (see the `solve.lua:579 — destructive unify ...` entry below for the full fix + verification). (see docs/typechecker-param-semantics.md)

- [ ] **Original task abandoned mid-execution: bulk REDUNDANT_CAST autofix** — The current session opened with a plan to apply `bin/cr check --fix` across ~2114 `REDUNDANT_CAST` instances. The plan was rejected once the user observed the autofix would propagate the two typechecker bugs above (unannotated params → `any`, force casts as inference sources). **Partial unblock 2026-05 via commit `c43bd439` (Phase A):** force casts on unannotated params no longer flag REDUNDANT_CAST, so the most common false-positive class is gone. Re-survey the corpus and re-evaluate whether the remaining REDUNDANT_CAST instances are now safe to bulk-fix. (Source: current session.)

- [ ] **CLAUDE.md redesign — partial deletion landed, full redesign pending** — Current session deleted three rules from `CLAUDE.md` (reactive-bandaid additions, delegate-on-doubt, inline-edit) after the user identified them as actively harmful. `~/git/rhizone/github-io/scaffolding/claude-md-failure-modes.md` (commit `e0a5159`) records the failure modes for future redesign. The full redesign — what positive rules replace the deleted ones, how to prevent reactive accretion, how to structure the file so an agent cannot confidently follow the wrong rule — is not done. Read `claude-md-failure-modes.md` before attempting. (Source: current session.)

- [ ] **Unified autofix pipeline — plan written, subtasks tracked separately** — Prior session (`e4f73deb`) produced the design: `bin/cr check --fix` in-process, no JSON roundtrip, `lib/edit` atomic byte-range edits, fixes attached at emit sites. Mechanism shipped (see existing "Autofix for redundant/widening casts" TODO marked `[x]`). Remaining work (WIDENING_CAST classification, `--nocheck: rule_name` inline suppression, rule groups, LSP code-action handler, snapshot path onto `lib/edit`, lint autofix attach, unify typechecker+lint pipeline) is already enumerated in the existing HIGH PRIORITY section above — no new items, but flagged here as surfaced from prior session and still open. (Source: prior session.)

- [ ] **`bin/cr check` vs `bin/cr fix` — subcommand boundary unsettled** — Prior session ended with conflicting framings: `--fix` as a flag on `check` (universal convention: eslint, ruff, clippy, golangci-lint) vs `fix` as a separate subcommand (different semantics: mutates source). Current implementation took `--fix`. The user explicitly rejected `bin/cr fix` / `check --fix` / `lint --fix` framings at multiple points; verify the shipped surface matches the user's preferred shape before extending it. (Source: prior session.)

- [x] **Older session (`9501a0b0`) handoff already captured** — That session ended with a `/handoff` that wrote the current TODO.md. Items from it are already enumerated above; nothing new to add. Noted here only so a future grooming pass doesn't re-mine it. (Source: older session.)

#### Second-pass additions (2026-05-13)

> *Re-mined the same three jsonls more carefully. The "handoff captured everything" claim above turned out partially wrong — the `/handoff` captured headline items but missed mid-conversation backlog requests and several specific findings. Items below are additive to the original 6.*

- [ ] **Design our own doc-comment syntax (survey prior art first)** — Older session `9501a0b0` user request: "maybe add to backlog to design our own doc comment syntax by looking at all prior art?" Context was the audit of `@param`/`@return` LuaLS annotations across the codebase. The conversation distinguished annotation syntax (`--:` / `--::`, already settled) from doc-comment syntax (the human-readable description block that travels alongside). `lib/doc/` extracts `---` comments today; whether `---` is the right marker, whether it should support sections (params/returns/examples/throws), whether it should be markdown or structured, are all unsettled. Survey: rustdoc, jsdoc, docstrings (PEP 257), godoc, javadoc, scaladoc, emmylua/LuaLS, sumneko, ldoc. Output: a `docs/doc-comments.md` design proposal. (Source: older session, USER #198.)

- [ ] **Lint config implementation (steal normalize's format)** — Older session pushed hard on this: "ideally it should be arbitrarily configurable" (USER #1848), "why not implement the config system first? the entire point is that we want stricter configs than the defaults" (USER #1882). The user told the model to send a subagent to `~/git/rhizone/normalize` to study its linting engine config format and to use that as a reference. Implementation result was the `pkg.lua` `rules` table (severity promotion), which is the *minimum* slice. The broader item — arbitrary per-rule configuration matching normalize's surface (not just severity; rule-specific options, file globs, per-directory overrides) — is unbuilt. (Source: older session, USER #1848/#1867/#1882/#1887.)

- [ ] **Lint to detect `--:: module` declarations in own codebase** — Older session, USER #1493: "add a lint for `--:: module` (NOT a text based lint)". The user is explicit that crescent's own libraries must never use `--:: module "..."` — module return types are inferred from `return M`. A *structural* lint (AST/parser level, not regex over source) flagging any `--:: module` declaration is needed so this doesn't drift back in. CLAUDE.md already documents the rule ("DO NOT USE in crescent source"), but there is no automated check. (Source: older session.)

- [ ] **Lint to warn on `--[[:! ...]]` force casts** — Older session, USER #1404: "now time to add a lint to warn on force casts and enable it for our codebase?" — discussed but not landed as a dedicated lint. Some force-cast diagnostics exist via the typechecker (REDUNDANT_CAST), but the user wanted a *named lint rule* (`force_cast`) so it can be configured per-project via the rules table. Distinct from the typechecker's classification work, this is the lint-side surface. (Source: older session.)

- [ ] **Remove `function` as a type alias** — Older session, USER #1448: "function shouldn't exist as a type alias imo :/" and USER #1454: "emit the same 'does not exist' error it would for any other unknown name. don't you dare fucking specialcase it." The bare `function` type (which means "any function, untyped") is documented in the typechecker quick-reference but the user wants it removed entirely — code should write the actual function shape (`(unknown) -> unknown` or whatever), not a permissive alias. Removing it will surface every site using it; those become annotation-debt items. (Source: older session.)

- [ ] **Investigate why "fails to propagate integer as the return type" was scoped to `math.floor`** — Older session, USER #1816: "i'm not sure why that would necessarily only apply to math.floor". A subagent had reported a fix narrowly targeting `math.floor` for an integer-return-propagation bug; the user (correctly) suspected the underlying issue was broader. Whether the eventual fix generalized or remained narrow was never resolved in-session. Re-audit: is integer-return propagation broken for other built-in numeric functions (`math.ceil`, `math.abs` of integer, `bit.*`, `string.byte`, `#t`) — or did the fix happen to be general? (Source: older session.)

- [ ] **REDUNDANT_CAST should fire on regular `--[[: T]]` casts too, not only force casts** — Older session, USER #1928: "the force casts are still there, right? why are they not marked as errors ('redundant cast' which would apply to both force casts and regular casts)". The redundant-cast diagnostic currently classifies only the force-cast variant (`--[[:! T]]`); a checked cast (`--[[: T]]`) on an expression whose static type already equals T is silently accepted. Both forms are equally redundant. Expand REDUNDANT_CAST to fire on both, with autofix stripping the cast comment regardless of variant. (Source: older session.)

- [ ] **The "90% of force casts are in test strings" claim from session 9501a0b0 was wrong** — Older session, USER #1583: "what :/ but surely not NINETY PERCENT of all force casts are in test strings." A subagent had reported that ~90% of force casts in the codebase lived inside test-fixture strings (test inputs, not real code). The user (correctly) found that implausible. The agent's reported breakdown of categories (350 "clearly fixable" / 2100 structural / 4600 hard) is therefore suspect — the "test string" sub-claim has not been re-verified. Before relying on the breakdown for triage planning, re-derive the categories with a script that excludes only confirmed test-fixture strings. (Source: older session.)

- [ ] **Pre-commit lint wiring + `--disable-rule=` flag + `bin/cr-lint.lua` (Part 3 of the original `9501a0b0` plan)** — The session opened with a 3-part plan: Part 1 (collect_preceding_run fix) and Part 2 (`bin/cr lint` subcommand wrapper) landed; Part 3 (pre-commit hook section that runs `bin/cr lint` on staged files, mirroring the typecheck loop's staged-vs-HEAD comparison) was sketched and never explicitly closed. Also from the same plan: `--disable-rule=<name>` flag on `lint_cli.lua` accumulating into `opts.disabled_rules` and `Checked N file(s): X violation(s)` grep-parseable summary. Verify each piece against the current `lib/stdlib/lint_cli.lua` and `.githooks/pre-commit`; close the gaps. (Source: older session, USER #8 initial plan.)

- [ ] **`force_cast = "warning"` (narrowing) vs `force_cast = "error"` (unrelated) vs autofix (widening) split is still aspirational** — Older session, USER #1835/#1842 spelled out the desired classification: redundant → strip, widening → autofix-rewrite to checked cast, narrowing → warning, unrelated → error. The current TODO captures "WIDENING_CAST classification" as a separate diagnostic but does not call out that the user wants four distinct outcomes mapped to four distinct severities/actions, with `force_cast` itself further split into narrowing-vs-unrelated. The existing widening item should be expanded to cover all four. (Source: older session.)

- [x] **`solve.lua:579` — destructive `unify(ctx, widened, expected)` on checked cast site is the actual binding mechanism for free param vars** — FIXED (bounded-stabilization session, see commit). Root cause confirmed exactly as pinned: in `solve_sub`, the `unify(ctx, widened, expected)` on a checked-cast C_SUB (`constrain.sub_is_cast(c)` true) is bidirectional and binds `widened` (an unannotated param's free `TAG_VAR`) to the asserted type — making the cast an inference source. Minimal fix: in `solve_sub`, when the constraint is a cast AND the (widened) actual is still a free `TAG_VAR`/`TAG_ROWVAR`, **defer** via `await(ctx, c, find(ctx, widened))` instead of falling into the destructive `unify`. The await parks the cast on the var and re-runs it once a producer (caller arg inference for the param) resolves it, so the cast checks against the inferred type rather than injecting one. The unsoundness arises only when the *actual* is a free var — with a concrete actual, `unify` only binds vars inside `expected` (the user-written asserted type, no free inference vars), so all other cast cases keep the original `unify` path verbatim and every diagnostic (incl. the `unknown`→`any` "must be narrowed" guidance and the `integer`→`string` widened-actual detail) is preserved. Verification: soundness repro (`local y = x --[[: integer]]` in an unannotated-param body no longer rejects `f("hello")`); crash-free per-file corpus delta = 0 (every sampled lib file identical to HEAD: rational 3, oauth2 12, image_processing 13, graphql_parser 69); solve.lua self-check unchanged at 35; `bin/cr test lib/type/static/` regression-free (10 passed / 1 pre-existing TAG_SPREAD failure both before and after). (see docs/typechecker-param-semantics.md)

- [ ] **`constrain.lua:1542` and `:1516` — param-var creation sites (both are unannotated-param branches)** — The same investigation pinpointed two `make_var(ctx, fn_scope.level)` call sites that create the fresh `TAG_VAR` that later flows through `solve.lua:579`. Both are at `constrain.lua:1542` (one branch) and `:1516` (the other). When fixing the param-inference bug, both branches must change — fixing only one leaves a residual leak through the other code path. Cross-reference with `constrain.lua:1469` and `:1548` which set `ctx.T_ANY` as the varargs default — these may also need to change to `T_UNKNOWN` for soundness. (Source: current session.) (see docs/typechecker-param-semantics.md)

- [ ] **`try_unify` is genuinely non-destructive — the prior session's "force-cast binds via types_overlap" theory was wrong** — Current session verified by reading every line of `unify.lua:851-1102` (`try_unify`) and `unify.lua:1132-1232` (`types_overlap`): neither calls `bind_var`, neither mutates `ta`/`tb`. The headline TODO item ("force casts act as inference sources") originally attributed the bug to those two functions; the real culprit is upstream (param var creation + `solve.lua:579`). Update mental model: do NOT modify `try_unify` / `types_overlap` to "fix" the force-cast bug — they are correct. The fix is at the param-binding sites. Per CLAUDE.md ("Context is poisoned the moment you confidently state something wrong"), the prior-session attribution itself was a context-poisoning event; the corrected attribution should propagate before any code change. (Source: current session subagent verification.) (see docs/typechecker-param-semantics.md)

- [x] **REDUNDANT_CAST classifier conflates *unifiability* with *assignability*** — Closed 2026-05-15 (audit pass). The specific repro (`local tv = type(v); ... v --[[:! number]]`) no longer fires, and the broader principle was applied: `solve_overlap` now uses `unify.is_subtype` (try_unify + closed-table excess-field check) instead of `try_unify`, so casts that strip fields are no longer misclassified as redundant. The unknown-narrowing path is handled separately by the inferred-param suppression (`ctx._inferred_param_tid`). Re-open if a new repro of the original symptom surfaces. (see docs/typechecker-param-semantics.md)

- [x] **`solve.lua:517-525` already has an `original_was_free_var` guard suppressing REDUNDANT_CAST emission** — Done 2026-05 via commit `c43bd439` (Phase A of the unannotated-param-semantics plan). The fix took a slightly different shape than this entry proposed: rather than mirroring `original_was_free_var` directly, `constrain.lua` now tracks unannotated-param tids in `ctx._inferred_param_tid`, and `solve_overlap` checks that set before classifying as REDUNDANT_CAST. The free-var-at-check-time signal was unreliable (param vars may already be bound by callers when `solve_overlap` runs); the explicit "this tid came from an unannotated param" mark is what works. (see docs/typechecker-param-semantics.md)

- [ ] **`solve.lua:2489 / :2509 / :2522 / :2563` — overlap-check code paths that need re-auditing alongside the classifier fix** — Current session investigations referenced these four solve.lua line numbers in the context of the REDUNDANT_CAST classifier; not enumerated here in detail, but flagged as needing co-review when the fix lands so a partial fix at 2515 doesn't leave the other sites incoherent. (Source: current session.)

- [x] **Phase C of unannotated-param-semantics plan: MISSING_PARAM_ANNOTATION autofix + modal inference** — Shipped. Approach taken was a hybrid of paths (a) and (b): solver semantics unchanged (destructive `solve_sub` retained); a side table `ctx._inferred_param_callsites` is populated in `solve_callable` / `solve_check_args` *before* the unify attempt, so every attempted caller is recorded (including ones the solver subsequently rejects). The post-pass aggregates per param: single distinct widened type → write it; modal ≥80% AND strictly dominant → write the modal; otherwise → write the union of distinct widened types. Outliers continue to error normally at their call sites (CALL_ARG_MISMATCH path), making typo-vs-legitimate callers self-localizing. Annotation rendering uses option (iii) — `display` output for primitives/structural shapes, with a `TAG_NAMED` in-scope check to fall back when an alias isn't resolvable in the destination file (the warning still fires; only the autofix payload is suppressed). Autofix is keyed off the function-def line: insert `--: (T1, ..., TN) -> R\n` at the start of that line, matching indentation, unless the preceding non-blank line already contains `--:` or `--::`. `PARAM_INFERENCE_OUTLIER` from the original plan was deliberately not implemented — under current destructive-bind semantics, outliers already error at their call sites, so there's nothing to "outlier-warn" about. (see docs/typechecker-param-semantics.md)

- [ ] **Session-start compaction concern** — Older session, USER #2047: "did this session start with a compaction?" followed by a forensic exchange where the user was visibly frustrated that auto-compaction had silently changed the working context mid-session. Not actionable as a code item, but the implied request — *make compaction events visible and reviewable* — is a harness/Claude-Code request, not a crescent code request. Logged here so it isn't lost on the assumption it was idle chatter. (Source: older session; out of scope for crescent code but worth flagging upstream.)

- [ ] **Pre-commit lint pass — confirm shipped surface matches `9501a0b0` plan** — Spot-check that the pre-commit hook section described in the original plan (lint section running after typecheck, comparing staged-vs-HEAD violation counts mirroring the typecheck loop) actually exists in `.githooks/pre-commit` today. If only the typecheck section is wired, the lint section is still TODO. (Source: older session.)

- [ ] **`/handoff` skill captures headlines, not sub-items — meta-finding** — Reviewing the older session `/handoff` output revealed that mid-conversation backlog requests ("add X to backlog", "let's also consider Y") and specific user objections to subagent reports do not survive a `/handoff` to TODO.md. Only the explicitly-pinned headline items do. Going forward, either (a) the `/handoff` skill needs to scrape mid-conversation `add to backlog` patterns from the transcript itself, not just rely on the model's recollection, or (b) every grooming pass needs to re-mine the source jsonl directly. This grooming pass is example (b). (Source: this grooming pass.)

- [ ] **Pre-commit: enforce 0 errors AND 0 warnings** — Pre-commit currently checks errors only. With `pkg.lua` config now promoting force_cast/explicit_any/any_in_type/match_contains_any/module_decl to errors, the codebase shows ~5579 errors and ~2 warnings. Once those errors are worked through, this becomes feasible. Requires `bin/cr check --exit-on-warnings` flag + hook update mirroring the staged-vs-HEAD comparison.

- [ ] **Genuine force casts (3278 of them) need upstream annotation work** — These are `--[[:! T]]` where actual type isn't already assignable to T. Each represents a producer with a wrong/missing type annotation. Fix patterns: missing function return annotations, setmetatable not propagating `__index` type, `pcall` result narrowing, FFI cdata typed as `unknown`. The previous session's diagnostic breakdown identified categories: ~350 "clearly fixable" (missing `--:`), ~2100 "structural" (setmetatable/pcall/generic arrays), ~4600 "hard" (heterogeneous ASTs, polymorphic data, cross-module inference). Numbers were from an earlier state and need re-counting against the current 3278.

- [ ] **Redundant force casts (2112 of them) — autofix mechanism shipped, classifier is unsound** — `bin/cr check --fix` (added 2026-05-13) attaches a safe-deletion fix to every `REDUNDANT_CAST` diagnostic and `lib/edit` applies them atomically. Bulk-applying it currently regresses ~20+ files: the classifier uses `try_unify(actual, expected)` which returns true for `unknown` ↔ T, so casts where `actual = unknown` (e.g. `local tv = type(v); if tv == "number" then ... v --[[:! number]]` — alias-narrowing doesn't propagate to `v`) are misclassified as redundant. Stripping them produces real type errors downstream. The autofix mechanism is correct; the classifier needs `is_subtype(actual, expected)` (or an equivalent assignability check) instead of `try_unify`. Until that's fixed, running `bin/cr check --fix` over the whole tree is not safe. See `lib/type/static/solve.lua` `solve_overlap` line ~2515.

- [x] **Autofix for redundant/widening casts** — Mechanism shipped: `--fix` flag on `bin/cr check`, in-process (no JSON roundtrip), `lib/edit` applies atomic byte-range edits, fixes attached at emit sites in solve.lua / constrain.lua. Widening cast classification, inline suppression (`--nocheck: rule_name`), and rule groups remain TODO (separate items below).

- [ ] **Widen FORCE_CAST classification: distinguish narrowing vs widening vs unrelated** — Currently only `REDUNDANT_CAST` (identical types, strip) and `FORCE_CAST` (everything else) exist. Widening (`S <: T`, convert `--[[:! T]]` to `--[[: T]]`) is not distinguished from narrowing or unrelated. User stance: narrowing should be warning, unrelated should be error, widening should be autofixed by rewriting `:!` to `:`. New diagnostic codes: `WIDENING_CAST` (autofix-safe, replace `--[[:! T]]` with `--[[: T]]`) and refine `FORCE_CAST` into "narrowing" (warning) vs "unrelated" (error). Reuses the autofix mechanism already in place.

- [ ] **Inline suppression `--nocheck: rule_name`** — Allow per-line suppression of specific rules.
- [ ] **Rule groups/categories in `pkg.lua` rules config** — Group related rules so they can be configured together.
- [ ] **LSP code-action handler for autofixes** — `lib/type/static/lsp.lua` should expose the same `fix` field via `textDocument/codeAction` so editors can offer Quick Fix for individual diagnostics. The diagnostic-level fix payload already exists; needs to be plumbed through the LSP serialization path and mapped to LSP `WorkspaceEdit`.
- [ ] **Migrate `UPDATE_SNAPSHOTS=1` onto `lib/edit`** — `lib/test/fixture.lua` rewrites snapshot files when `UPDATE_SNAPSHOTS=1`. Switch its write path to `lib.edit.apply` so all in-place source mutations go through one atomic-write code path (tmp + rename). Currently each tool does its own io.open/write — easy to get partial writes on crash.
- [ ] **Lint autofixes (emmylua → `--:`, etc.) via `lib/edit`** — `lib/stdlib/lint.lua` produces diagnostics for emmylua annotations and other syntactic patterns. Many are mechanically rewriteable. Attach `fix` records the same way as type diagnostics and reuse `bin/cr check --fix` / `bin/cr lint --fix` to apply.

- [ ] **Unify typechecker and lint tool** — `lib/type/static/` (typechecker) and `lib/stdlib/lint.lua` (lint) are separate tools with separate invocations (`bin/cr check` vs `bin/cr lint`). Diagnostics that belong in the typechecker (force casts, explicit any, non-exhaustive match) are already there. Diagnostics that are purely syntactic (emmylua annotations) belong in lint. But there's no reason for two separate pipelines — `bin/cr check` should run both and report all diagnostics together. Design: lint rules become typechecker passes that run after type inference, with the same diagnostic infrastructure (line/col, codes, format options). The split creates friction: pre-commit runs them separately, LSP only surfaces type errors, users have to remember two commands.

- [ ] **LSP daemon + VS Code extension** — The LSP daemon (`lib/type/static/lsp.lua`) is implemented: stdio JSON-RPC 2.0, diagnostics, hover, go-to-def (within-file + cross-file), completions (scope + field), signature help. What's missing: (1) a VS Code extension that spawns the daemon and wires it to the editor protocol; (2) packaging so users can install it without a dev shell. VS Code extension is the highest-leverage surface for adoption — inline type errors, hover-to-inspect, go-to-def make the typechecker usable for daily editing. Extension shell: `package.json` with `contributes.languages` for `.lua`, a `LanguageClient` pointing at `bin/cr lsp` (new subcommand that execs `lib/type/static/lsp.lua`), activation on workspace open. Stretch: JetBrains / Neovim / Helix configs (all speak LSP; just need a `bin/cr lsp` entry point and docs).

---

- [ ] **type/static: hash-cons unions/intersections for sound cycle detection** — recursive type aliases (e.g. `Term = string | { args: { [integer]: Term } }`) caused stack overflows in multiple typechecker functions. Patched with seen-set cycle guards in `meta_op_ret_impl`, `display`, `widen` (commits 56810b6, 32b7d5a). The deeper issue: `make_union(members)` always creates a fresh tid, so structurally-identical unions present as different tids per visit; tid-keyed cycle detection misses the cycle until a depth limit catches it. Display has a hard-assert depth limit (commit b0095b2) — fires nowhere yet. Hash-consing make_union/make_intersection so structural identity → tid identity would make all cycle detection sound and remove the depth limit. Verify if/when the assert fires before doing this work.

- [ ] **type/static: stack overflows in parallel workers under structural cycle work** — distinct from the SIGSEGV thread above. Some files (proto, prolog, protocol_buffer, hamt) hit Lua stack overflow when the typechecker recurses through type structures without cycle guards. Recent passes added guards in the obvious sites; an audit-style sweep over remaining recursive walkers in `unify.lua`, `solve.lua`, `narrow.lua`, `match.lua` would catch any latent cases. None reported in the current corpus, but the pattern (cycle guard + memoization) is now the standard.

- [ ] **type/static: multi-return inference surfaced ~hundreds of tuple-mismatch bugs across the codebase** — commit 1d30f3c packs multi-returns into TAG_TUPLE so callers get correct slot types. This exposed many sites where `return ok, err` from a 3-tuple-annotated function was actually wrong (real bugs), plus patterns like `local ap, aq = f()` where callers were silently relying on `aq=nil` from the broken inference. After the fix, these became visible diagnostics. Most have been cleaned up in the post-1d30f3c commits but a slow trickle remains across the long tail. Pattern: "tuple length mismatch: 2 vs 3" or "argument might also be `nil`" in arms after multi-return narrowing.

- [ ] **lib/ljsocket/init.lua resists fixes (19 errors)** — 3 clean errors fixed (shadowing bug, nullable annotation, force cast). 19 structural errors remain: duplicate `ffi.cdef` for `FormatMessageA`, `$FfiC` opaque type mismatches between POSIX/Windows FFI, `addrinfo_to_table` reverse-lookup types not satisfying `LjSocketAddrInfo` literal unions, and `meta.*` methods requiring coordinated `LjSocket` alias + body changes. See below for rewrite option.
- [ ] **Dedicated style design session** — crescent library conventions need to be deliberately designed, not inferred from whatever happens to exist. The agent survey of epoll/inotify/timerfd is evidence, not a decision. Topics: caps injection shape, fd/handle abstraction, async patterns, FFI tier structure, error return conventions, type declaration style, module shape. Output: `docs/style.md` (or extend `docs/conventions.md`) that is prescriptive enough to be a reference when writing any new library. Do this before the socket rewrite so the rewrite is an example of correct style, not another thing to audit later.
- [ ] **Rewrite ljsocket as crescent-native socket library** — after the style session. ljsocket is a vendored port (CapsAdmin/luajitsocket, Feb 2026), 1250 lines, no caps injection, 19 structural type errors. The API surface (create/connect/accept/send/recv/close + fd property for epoll) is proven by tcp/http callers and should be preserved. Write `docs/socket-design.md` then implement.

- [ ] **lib/imap/format.lua: convert LuaLS `@param`/`@return` to crescent `--:` (17 errors)** — the file uses `--[[@param s string]]` style annotations which the typechecker doesn't recognize. Mechanical conversion to `--: (string) -> ...` form is straightforward in principle but cascades into the multi-return narrowing of `s:find` returns. Estimated 2–3 hours of focused work.

- [ ] **Codebase-wide error sweep complete (session 28, 2026-05-09)** — reduced from 1744 → 59 errors (−1685, 96.6% reduction) across 773 files. Remaining: ljsocket (22, resistant FFI), imap/format (17, LuaLS annotations), example_text/projection_types (6, need globals_files loader context), workflow/taskgraph (3×1, parallel checker artifact — 0 errors individually). All other 765 files are now clean. Typechecker self-checks: lib/type/static/ and lib/type/check.lua fully annotated in this session. Added ffi.cast (string,unknown)->cdata overload and register_ffi_module optional global to stdlib_types.lua.

- [x] **lib/xgboost, lib/stream, lib/hamt: recursive type aliases need method signatures** — fixed in commit 3540827. Declared TreeNode/Model (xgboost), Stream internals (stream), HamtLeaf/HamtCollision/HamtInterior/HamtNode/HamtMap (hamt). All three at 0 errors.

- [ ] **system_dashboard projection_types loader: 5 undefined-type errors when checked standalone** — `lib/platform/apps/system_dashboard/projections/projection_types.lua` and `example_text.lua` reference `Primitive`/`Text`/`Element`/`Ctx` which are declared in `primitive_types.lua`/`projection_types.lua`. These files are designed to be loaded with their peers as `opts.globals_files`, but the project-level `pkg.lua` only registers `lib/type/static/stdlib_types`. Decide: register the dashboard primitive/projection types as globals (scoped how?), or add a per-app pkg.lua override mechanism. 5 errors total at present.

- [x] **Add precise opaque-object type declarations for 9 libraries** — all 9 verified at 0 errors. Most were already fixed in prior sessions; remaining work done in this session: cron (SHORTHANDS indexer + or-chain), graph (bfs/dfs second return type), glob (Matcher type + return annotations), ratelimit (5 types declared). `lib/regex/pure` does not exist.

- [x] **type/static: worker SIGSEGV under `bin/cr check` — C_BIND_GENERICS solver livelock (Gen-3 root cause)**

  Symptom: `rm -rf .crescentcache && bin/cr check lib/bloom/init.lua` → exit 139 (SIGSEGV). Old user-level repro still valid as a symptom check: `for i in $(seq 1 10); do rm -rf .crescentcache && bin/cr check 2>&1 | grep -E "warning: .*crashed"; done` — prints the warning on most runs.

  ---

  **~~Gen-1 (REFUTED): Fork × JIT mcode interaction~~**
  ~~The original framing attributed the crash to LuaJIT trace-compiler mcode and fork interactions: `RIP` landing in anonymous RX mcode regions after fork suggested JIT-compiled code was the culprit. Ruled out by: (a) the bug reproduces in the sequential, single-process path (`--summary`, njobs=1, no `fork()`); (b) a minimal fork+ctype-array-growth repro (16 children growing `ASTNode[?]` arrays under JIT warmup) runs 3/3 clean; (c) with JIT disabled, crashes still occur — `RIP` was a red herring.~~

  ---

  **~~Gen-2 (REFUTED by Gen-3 measurement): Intra-`instantiate` exponential DAG copying~~**
  ~~Root cause pinned (session 2026-06-12): `instantiate_inner` (env.lua:353) memoizes a table entry via `seen[tid]` only for the duration of that table's own recursion, then clears it (`seen[tid] = nil`, env.lua:450). A sub-type reachable via multiple paths through a generic DAG is fully re-instantiated on each path — exponential in DAG sharing depth. Observed arena growth: 512 → 16 777 216 → 33 554 432 TypeSlots (32 B each → 2 GB+) before throwing. The blowup manifests as either a catchable `arena.lua ct_arr: "size of C type is unknown or too large"` (sequential path) or a SIGSEGV from a dangling FFI pointer into a freed/realloc'd backing array (parallel path).~~

  ~~Corroborating evidence (second investigation, core-dump forensics):~~
  - ~~Core dump: with JIT disabled, crash lands at `luajit-bin+0x53537` `mov (%r8),%eax` (FFI cdata→TValue load), `r8` into unmapped memory — dangling pointer into a realloc'd arena.~~
  - ~~`waitpid` instrumentation: ~3–4 genuine SIGSEGV exits + ~4–5 catchable Lua-error exits per full-tree run — two symptom paths, one blowup cause.~~
  - ~~`jit.off()+jit.flush()` in workers: 4 SIGSEGVs with vs 3 without (noise); +29 % wall-time (185 s → 239 s). Rejected — treats a non-JIT symptom. Do not resurrect.~~

  ~~Proposed fix: persist `seen[tid] → result_id` for the entire `instantiate` call (do not clear at env.lua:450); cycle safety comes from the pre-registered `result_id` at env.lua:367.~~

  **Gen-3 (current, measured — third investigation):** the arena blowup is a **C_BIND_GENERICS solver livelock**, not intra-`instantiate` exponential copying.

  - **A/B on the Gen-2 "persist seen" fix (env.lua:450):** arena peak IDENTICAL with and without — 67,108,864 TypeSlots both ways on lib/bloom/init.lua. Per-`instantiate` growth is a constant 31 slots/call, never exponential. The Gen-2 mechanism does not occur. (The `seen`-persist remains a valid standalone micro-optimization but does not affect the crash.)
  - **Blowup is the call count:** >1,080,000 `instantiate` calls × 31 slots = arena exhaustion.
  - **Round-loop instrumentation** (solve.lua `solve_range`, ~lines 4139–4182): every round reports `solved=false` but `gen` advances by exactly 1 — observed past 504,000 rounds. The quiescence test (`not solved_this_round and gen_after == gen_before`) never fires.
  - **The livelock cycle:** re-seed re-queues the unsolved `C_BIND_GENERICS` → handler instantiates a fresh callee (solve.lua:2974, +31 slots, fresh param TVs) → param-bind loop fires `unify` (solve.lua:3012) → `wake_waiters` → `gen+1` → `ctx._bind_woke_given` causes defer at ~3013–3014 WITHOUT retiring → repeat forever. Defer-after-mutation.

  **Candidate fixes (ranked):**
  1. ~~Cache the per-constraint instantiation across re-seeds — removes both the slot leak and the spurious gen advance.~~ **LANDED — commit `bd06264e` (rebased onto master 2026-06-12).** Verification: `bin/cr check lib/bloom/init.lua` → 1 error / 25 warnings in <60 s (no crash, no exit 139); 6 crash→verdict wins across the corpus, zero other verdict changes; livelock rounds capped <200 on bloom. `bin/cr test lib/type/static/` → 10 passed / 1 pre-existing TAG_SPREAD failure (no regressions).
  2. Roll back / skip binds issued in a round that ends in a `_bind_woke_given` defer, so the defer does not register as progress.
  3. Tighten the quiescence signal against immediately-superseded binds.

  **Repro confirmed clean:** `bin/cr check lib/bloom/init.lua` exits with a verdict, not exit 139.

- [ ] **type/static: 5 residual crashers — arena-exhaustion class (distinct from C_BIND_GENERICS livelock)** — After the Gen-3 livelock fix (`bd06264e`), five files still crash the worker: `finite_field`, `pipeline`, `pipeline_dsl`, `rope`, `time_series`. These are a separate class: arena exhaustion via a different blowup path (not the C_BIND_GENERICS defer-after-mutation cycle). Needs its own diagnosis: instrument arena peak + round count on each file, identify the solver constraint type responsible, and apply the appropriate fix. Do not conflate with the now-closed SIGSEGV item above.

- [ ] **type/static: regression test for parallel CLI determinism** — currently relies on the `bin/cr check` repro above. A proper test would: (1) drive `check_parallel` with a synthetic file set, (2) inject a SIGSEGV in one worker (`kill -SEGV $pid` from a controlled child), (3) assert the parent's reported error count matches the no-crash baseline. Blocked on a way to inject a deterministic worker crash from inside the test runner; for now, the manual repro is documented.

- [ ] **Phase D3 cleanup: 157 new `unknown <: any` errors after Gap 11 fix** — closing Gap 11 in `unify.lua` (commit closing this gap) added 157 new "cannot pass `unknown` where `any` expected" diagnostics across 62 files. Pattern: code uses `--: any` to launder values that are typed as `unknown` (often from open-table indexer access, generic `Schema<unknown>` fields, or schema dispatch). Fix per file: replace `local x = src --: any` (followed by a `--: T` cast) with a single `--[[:! T]] src` force cast. Most concentrated in: `symbolic_diff/init.lua` (15), `graphql_parser/init.lua` (9), `type/static/fuzz_alg.lua` (8), `platform/caps/http_client.lua` (8), `type/check.lua` (7), `ukanren/init.lua` (6), `type/static/parse.lua` (6), `platform/session_store/init.lua` (6), `platform/audit/init.lua` (6), `gradient_descent/init.lua` (6). Repo-wide check: 17302 → 17894 errors total (delta 592 includes cascading effects). No soundness implication; the unify fix is the load-bearing change.

- [ ] **replace VitePress with a pure Lua doc toolchain** — `bin/cr run docs/build.lua` for SSG (CI deployment), `bin/cr run docs/server.lua` for local dev preview. Removes bun entirely — no JS toolchain in CI or locally. Needs `lib/markdown` (CommonMark renderer). Dogfood priority.

- [ ] **type/static: type-id → annotation string renderer** — needed for round-trip parse(render(parse(s))) regression tests over fuzz_arb generators. Currently `fuzz_arb.type_to_string` only renders arb tree nodes (input shape), not parsed type IDs. A real renderer would walk the FFI TypeSlot arena and emit precedence-correct annotation syntax. Planned use: extend `lib/type/static/annotation_totality_test.lua` with a round-trip invariant.

- [ ] **lib/db: undefined class types + postfix `?`** — `bin/cr check lib/db/init.lua` reports 78 errors. Two distinct issues: (a) `--[[@class sqlite]]`/`--[[@class Select]]` LuaLS-style class declarations are not understood by the typechecker (every `--[[@param x sqlite]]` etc. emits `undefined type`); (b) postfix `?` (`true?`) is treated as part of the return signature in `--[[@return true? success, string? error]]` but produces `boolean is not assignable to true | nil` at every `return true` site. Phase C deliberately did NOT touch this file — fixing requires either porting to `--:` annotation syntax (preferred per `docs/conventions.md`) or extending the typechecker to handle LuaLS-style `@class`/`?` annotations as a compatibility layer. Decision: port to `--:` syntax. Out of scope for the FFI-load Phase C pass.

- [x] **type/static: pcall return tuple binding propagates input fn type to slot 2** — verified fixed (session 27). sqlite and sha256 both at 0 errors; pcall(ffi.load, ...) correctly produces `$FfiC | string` with narrowing working inside `if ok then`.

- [x] **type/static: `ffi.new("Byte[?]", n)` VLA overload not modelled** — verified fixed (session 27). compress/system.lua and sha256/init.lua both at 0 errors.

- [ ] **lib/hash/sha256: Lua tier and FFI tier annotation gaps** — `bin/cr check lib/hash/sha256/init.lua` reports ~37 errors after Phase C fixed the FFI-load site. Remaining errors are in (a) the pure-Lua tier (`_bxor`/`_band`/`_bnot`/`_rshift`/`_rrotate` typed as union with `any` because they fall back to math when LuaJIT bit lib is missing; `blk = {}` and `W2 = {}` typed as `unknown`); (b) the FFI tier (`pcall(lib.SHA256, ...)` return-tuple binding bug — see related TODO). Pure annotation work, no soundness implication; out of scope for Phase C (which only covers FFI-load `unknown→T` leakage).

- [ ] design: http_client attenuation — query param filtering (wildcard syntax? exact key match? key+value match?)
- [ ] design: http_client attenuation — request header filtering (which headers are meaningful to restrict? security implications of allowing Content-Type vs Authorization override?)

## system_dashboard

- [x] **Pack cap declarations** — action `caps = { name = { type, binaries/etc, reason } }` shape mirrors manifest cap decls; validated in packs.lua; attenuated at execute time.
- [x] **User approval flow** — per-action cap_info modal fetched before execution; shows command, per-cap cards with author reason + platform risk (severity-coloured); Cancel has default focus.
- [x] **Attenuate-then-invoke** — `POST /api/execute` finds parent cap by `_type`, calls `parent.attenuate(action_decl)`, invokes sub-cap. Shell and exec dispatch both wired.
- [x] **Registry actions (Windows)** — `type = "registry"` actions wired in server.lua; demo actions added to default.lua (`win-reg-product-name`, `win-reg-list-startup`); dispatch tests in server_test.lua.
- [ ] **User-installed packs** — `user_packs` fs cap declared in manifest; third-party pack execution needs scrutiny before enabling (attenuation + approval flow now exist).
- [x] **Pack-level cap declarations** — pack may declare `caps = {...}` once at pack scope; every action inherits those caps by default. Action-level caps fully override on name collision. Resolved at pack-load time in `flatten_pack`; server.lua sees the merged result. Demo: `packs/git.lua`.
- [x] **Output envelope schema** — `lib/platform/apps/system_dashboard/output.lua` declares all 30 primitives from `docs/system_dashboard_primitives.md` with constructors, validators, and `cite` channel. Pure data contract; no rendering wired yet.
- [x] **Primitives renderers — first 5 end-to-end** — backend dispatcher (`server.lua`) adapts cap results into validated envelopes via `output.lua`; pack actions declare `exec.output` (string shorthand or table spec) to pick a primitive. Frontend `static/app.js` `renderEnvelope`/`renderPrimitive` covers `text`, `code`, `key_value`, `table`, `status_badge` with DOM construction (no innerHTML for pack-supplied strings). Demo actions in `packs/default.lua`: `disk-usage` (table), `system-info-linux/macos` (code), `win-reg-list-startup` (key_value), `service-status-linux` (status_badge), `win-reg-product-name` (text default).
- [x] **Primitives renderers — full catalogue (frontend)** — `renderPrimitive` switch superseded by the projection registry below. All 30 catalogue tags have dedicated projection modules.
- [x] **Renderer architecture: shape-dispatch + projection registry** — `static/app.js` collapsed from a 1731-line IIFE with a 30-case switch into a 658-line ES module that imports `static/dom.js` (sealed `createElement` builder with strict tag/attr/style allowlists), `static/harden.js` (freezes built-in prototypes at load), and `static/projections/registry.js` (`Map<tag, Projection[]>` with most-recently-registered-wins selection, runtime overridable). Each of the 33 catalogue tags lives in its own file under `static/projections/` and self-registers via `static/projections/index.js`. `shapeOf(v)` keys the registry by `typeof` for primitives, `"array"` for arrays, `value.type` for tagged variants, `"object"` for plain records. `Ctx = {project, action}` — `ctx.action(alias_id, args?, onResult?)` returns a click handler that POSTs to `/api/execute` and feeds the response envelope back to `onResult` for inline re-projection. Streaming projections return `{__stream: true, el, onFrame, onGap?, onError?, onEnd?, dispose?}`; SSE consumer calls those hooks per frame. `index.html` loads as `<script type="module">`. Wire shape (envelopes via `output.lua`) unchanged.
- [ ] **Initiative B — lua2ts + projection-Lua subset for pack-shipped projections** — partial. **Gated on platform isolation landing** (`docs/platform_isolation.md`): Initiative B's output (transpiled pack JS) has to land into whatever rendering and isolation model the platform-isolation design picks, so resume after that doc's open questions (especially the rendering model — Options A/B/C) are settled.
  - [x] **lua2ts harden mode** (commits `5df9003`, `56deab2`) — `opts.harden: bool`. Emits `__rec({...})` for record table constructors (null-prototype via `Object.create(null) + Object.assign`); rewrites `padStart` / `padEnd` / `join` (and `repeat`, modulo Lua keyword caveat) to `__safe_*` helpers with 100KB output cap; `__safeGet(t, k)` wraps non-numeric-literal bracket access with a 7-key prototype-key blocklist (`__proto__`, `constructor`, `prototype`, `__defineGetter__`, `__defineSetter__`, `__lookupGetter__`, `__lookupSetter__`); refuses emission of identifiers in a fixed JS-hazard blocklist (`globalThis`, `window`, `document`, `eval`, `Function`, `setTimeout`, `fetch`, `Worker`, ...) exported as `M.JS_HAZARDS`. 111 assertions in `lib/lua2ts/lua2ts_harden_test.lua`.
  - [x] **Projection prelude** (commits `56f9838`, `8624a2e`, `85ac3d3`) — `lib/platform/apps/system_dashboard/projections/projection_types.lua` declares the sealed `dom.<tag>(props, children) -> Element` builder (64 tags), `Ctx`, `Projection`, `Style`, `Props`. Imports `Element` / `Event` / `MouseEvent` / `KeyboardEvent` / `Text` from `lib/js_types/init.lua` rather than re-declaring. `Primitive` extracted to `lib/platform/apps/system_dashboard/primitive_types.lua` for sharing with `output.lua`. E2E test typechecks an example projection against the prelude and transpiles it through harden mode.
  - **Layering settled**: typechecker (with `opts.globals_files = projection_types + primitive_types + js_types + stdlib_types`) is the primary gate; lua2ts harden mode is the JS-runtime-hazard backstop for `any` / soundness gaps / skipped-typecheck cases. No "projection mode detection" — caller passes preludes explicitly. No typechecker projection-mode rule (the original "reject computed string keys" idea was wrong-headed — the typechecker can't know runtime key values; that's lua2ts's `__safeGet` job).
  - **Still open**:
    - **Pack-load pipeline** — needs to run typechecker (with `globals_files = projection_types + primitive_types + js_types + stdlib_types`) → lua2ts harden mode → register transpiled projection in the host JS registry. Open question: when does transpile happen? Pack-load time (host caches output), CI build step (pack ships pre-built JS), or on-the-fly in the daemon? Affects pack distribution shape.
    - **Browser-side loader** — host JS that consumes transpiled ES module output and calls `register()` on `static/projections/registry.js`. Trivial once pack-load pipeline exists; depends on its output shape.
    - **Sync-only relaxation** — debounced renders, animations, tooltips need timers. Punted for v1; revisit when a real use case lands. Decision will be: relax the `setTimeout`/`requestAnimationFrame` blocklist in lua2ts (with what bound?) vs proxy/wrap them.
    - **ShadowRealm / Worker isolation** — alternative to the static lua2ts approach. Not needed for v1; revisit if static hardening proves insufficient (e.g. if pack authors keep finding escape hatches, or if host JS evolves to require properties the static analysis can't prove).
    - **`s:repeat(n)` unparseable** — `repeat` is a Lua keyword. Author would need `s["repeat"](s, n)` (works, ugly) or the prelude exposes a different name. Not blocking v1 (the helper rewrite entry exists in lua2ts and would fire if/when the source compiles); affects projection author UX.
    - **Hardening against future `<script>` insertion in `index.html`** — `harden.js` runs at app boot and freezes prototypes, but a hostile script that loaded *first* could replace `globalThis.Object` etc. before the freeze runs. Today there's only one `<script>` tag (the app entry), so this is theoretical. Decision: do we want hardening to survive future template changes that might add scripts before the entry? Could enforce loading order or add a CSP.
- [ ] **Backend output adapters — beyond first 5** — `server.lua` currently adapts cap results into `text`/`code`/`key_value`/`table`/`status_badge`. Other primitive shapes (`single_stat`, `gauge`, `list`, `top_list`, `tree`, `json_view`, etc.) have validators and renderers but no `exec.output` adapter — packs cannot exercise them yet. Each adapter needs a design call (what does a cap result map to a `gauge`?). Likely simplest path: a `passthrough` adapter for caps whose return value already has the right shape.
- [x] **Streaming primitives transport — SSE for `log_stream`** — http_server cap exposes `res.send_event(data, opts?)` with `id`/`event` plus `req.last_event_id`; first send_event sets TCP_NODELAY (default on, configurable) + SO_KEEPALIVE/15/15/3. shell cap gained `run_stream(cmd) -> iter` (line iterator with idempotent `:close`). system_dashboard server.lua takes the SSE branch when `exec.output.type` ∈ {log_stream, live_table, event_stream}: emits schema (id=0, event=schema), then frame events (id=1.., default event=message), then `event=end`. Ring-buffered replay on `Last-Event-ID`, `gap` event when buffer cannot cover. Frontend consumes via `fetch + ReadableStream`, reconnects with exponential backoff. Demo alias: `ping-stream-localhost`.
- [x] **Streaming primitives — `live_table` and `event_stream` renderers** — projection modules now exist with op-coded discriminated-union frames for `live_table` (`{op:"upsert"|"delete"|"reset"}`, upsert-by-key column) and `{time, kind, body: Primitive}` β-shape for `event_stream` (recurses body via `ctx.project`). No demo pack actions exercise either yet — backend pump path is generic but only the shell cap exposes `run_stream`; other caps (exec, http_client, registry watch, fs watch) still need streaming surfaces. CSS classes (`.prim-live-table`, `.prim-event-stream`, `.event-row`, etc.) are forward-declared in the projections but `style.css` has no rules for them yet — visual smoke pending.

- [x] **Frame-parser surface for live_table / event_stream demos** — landed `output.frame_format = "jsonl"` in `pump_stream`. When set, each line is `pcall(json.decode, line)`'d and the parsed object becomes the frame body. Decode failure emits a per-line `event=error` envelope and the pump continues to the next line; an unknown `frame_format` value emits the error and closes the stream. Default (nil) preserves the legacy log_stream message-wrapping behaviour. Tests in `server_streaming_test.lua` cover live_table upsert/delete frames, event_stream frames with bad-JSON skip, and the unknown-format rejection. Demo aliases for live_table / event_stream are unblocked but not yet added — open a follow-up if a packs/default.lua entry is wanted. Built-in parsers (`output.parser = "ps" | "journalctl"`) and structured cap surfaces remain future options.
- [ ] **Daemon HTTP server SSE contract** — daemon mode in `lib/platform/caps/http_server.lua` is registration-only; when the daemon ships its own listener it MUST honour the SSE wire-format contract documented at the top of that file (incremental writes on first send_event, Last-Event-ID propagation onto `req.last_event_id`, send_event err return on client-closed, TCP_NODELAY/keepalive).
- [x] **Card app `send_event` return-check audit** — fixed via `client_gone` flag (commit `60f30a7`). LLM stream cannot be cancelled mid-flight (no abort signal in `caps.llm.call_stream`'s `on_token` callback contract); follow-up could extend that callback to return an abort signal so dropped clients stop generation immediately rather than silently consuming tokens until natural completion.
- [ ] **macOS TCP keepalive parity** — ljsocket only declares Linux constants for `TCP_KEEPIDLE/INTVL/CNT`; on macOS those `set_option` calls fail silently via `pcall`. `SO_KEEPALIVE` itself works cross-platform. Adding macOS constants is a one-line ljsocket extension.
- [ ] **Manual smoke verification** — the renderer refactor + ES-module conversion landed without browser-side verification (subagents had no DOM available). Worth opening the dashboard in a browser, confirming console clean, `Object.isFrozen(Object.prototype) === true`, and that `disk-usage` / `system-info-linux` / `win-reg-list-startup` / `service-status-linux` / `ping-stream-localhost` render identically to pre-refactor. Class names pass through `dom.js` unchanged (no `proj-` prefix) so existing CSS should still match.
- [ ] **`form` primitive renderer** — placeholder shipped; needs design input on widget set (text/password/number/bool/select/multiselect/path/host), validation surface (regex/range/async-validate), and submit semantics before implementing.
- [ ] **Vision: dashboard becomes every system tool** — `docs/system_dashboard.md` lays out the framing. Packs decide what the surface is: Raycast, Home Assistant, Control Panel, Tailscale admin, regedit hacks, all simultaneously. High-leverage pack directions: curated regedit hacks (Windows, no legitimate competition), cross-platform unification (file associations, startup programs, etc.), local HTTP services (Tailscale/Ollama/Grafana), web service APIs. Bidirectionality and rich display (NAS-software bar) are the parity standards.

## Platform caps

- [x] **`db`/`shared_db` naming inconsistency** — every cap that takes a read/write boolean now uses `opts.allow_write` (default false). Latent fs builder bug fixed (was passing ignored `readonly` field).
- [x] **`http_client` methods in CAP_FACTORIES** — `http_client_cap` now accepts `opts.methods` whitelist, but `lib/platform/init.lua` CAP_FACTORIES doesn't pass `methods` from manifest declarations. Small gap.
- [ ] **`caps.llm.call_stream` abort signal** — current `on_token` callback has no way to cancel an in-flight LLM generation. card app works around this with a `client_gone` flag that drops tokens but lets the LLM keep generating. Worth extending the contract so callbacks can signal abort (return `false`? throw? out-of-band cancel handle?) — affects any caller that streams to a client that may disconnect.

## Codebase consolidation

- [ ] **Duplicate library clusters (low priority)** — `docs/duplicate_clusters.md` (commit `c17f053`) triages 22 clusters under `lib/`. Strict-superset and port-then-drop clusters resolved 2026-05-15 (`648ca3be`..`18f98347`, 16 commits): unified stubs, merkle, noise, expression_evaluator, roman, patch, geohash, lsystem, observable, finite_automata, ratelimit. Remaining clusters require human design decisions before any agent can act:
  - `cron` vs `cron_parser` — different scope (scheduler vs parser-only)? Could merge by folding `parse_field`/`validate` into `cron`.
  - `proto` vs `protocol_buffer` — high-level DSL vs raw wire primitives. Decide whether raw helpers stay public.
  - JSON Schema cluster (`json_schema` vs `jsonschema`) — pick canonical; both ~same API, different impls. Separately: combinator cluster (`validate` / `schema_validator` / `validation`) — `validation` is largest; verify before dropping the other two.
  - `automata_2d` vs `cellular_automata` — different scopes (2D-with-RLE vs 1D-Wolfram+2D). Either keep both (rename for clarity) or merge with explicit 1D/2D submodules.
  - `option` / `either` / `fp/either` / `fp/maybe` — gated on whether `lib/fp/` typeclass design is endorsed (currently wip).
  - FSM family (5 impls): pick one flat (lean `state_machine`) and one hierarchical (lean `state_machine_hsm`); drop `fsm`, `state`, `statemachine`.
  - Caches (4 impls): `lru` is broadest; fold `lru_cache` + `lru_ttl` policies into it; decide whether `cache` (generic TTL store) stays separate.
  - Bloom (4 impls): keep `bloom_clock` (different concern); among the rest, merge into `bloom` and fold `bloom_count`'s Cuckoo; drop `bloom_filter`. Decide if Cuckoo belongs in a Bloom module.
  - `neural` vs `neural_net` — not a strict superset; single-call vs compositional API. Pick a winner (doc leans `neural_net`). Pulled out of Tier 2 strict-superset batch because the APIs don't actually align.
  - `lib/json/` vs `lib/format/json/` — doc says `format/json` is canonical (tiered impl); verify the pure-Lua tier covers `lib/json/`'s behaviour before dropping.
  None of these are actively breaking anything, but each unresolved duplicate is a future foot-gun where someone imports the wrong one.

## Documentation infrastructure

- [ ] **Docs site violates zero-dependency principle** — The docs site depends on bun/node (vitepress) with a 255MB `node_modules` tree. Every other part of the project runs from a bare `git clone`; the docs site is the exception. Becomes precedent the longer it sits.

- [ ] **Inventory drift risk** — `docs/inventory.md` and `docs/inventory_summary.md` (commits `fa7e83b`, `a6e5caa`) are now hand-maintained per the CLAUDE.md rule. First time someone adds a library without updating the inventory, the rule will need a stronger nudge. Possible follow-ups: a pre-commit hook that warns when `lib/<new_dir>/` is added without an `inventory.md` change; or generation of inventory from a directory walk + per-library frontmatter. Don't optimise prematurely — wait for the first miss.

## Binary distribution

- [x] Build LuaJIT for Linux x86-64 — dynamic binary + bundled musl linker in `bin/ld-musl-x86_64.so.1` (`bin/cr` invokes the linker directly). Works on NixOS, Alpine/musl, glibc.
- [x] Build LuaJIT for Linux arm64 — same approach, with `bin/ld-musl-aarch64.so.1`.
- [x] Build LuaJIT for macOS arm64 / Apple Silicon — `bin/luajit-macos-aarch64` (dynamic Mach-O).
- [ ] Build LuaJIT for macOS x86-64 — GitHub deprecated `macos-13` Intel runners; deferred until a build path exists. Intel Mac users currently fall through to "no bundled LuaJIT" error in `bin/cr`.
- [x] Reproducible build process via CI — `.github/workflows/build-vendored.yml` builds LuaJIT + sqlite3 + zlib for all platforms, auto-commits to `bin/`/`dep/`. Triggered on `dep/sqlite3/**` or `dep/zlib/**` push, or `workflow_dispatch`.
- [ ] Audit any other unvendored FFI deps — sqlite3, zlib are vendored. ljsocket uses `ffi.C` (POSIX, no extra dep). Other libraries that pull in non-libc shared objects would violate zero-dependency.

## RP / LLM interaction platform — primitives needed

See `docs/batteries.md` and `docs/platform-design.md` for full design. Primitives the platform needs that don't exist yet:

- [x] `lib/png` — chunk-level PNG reader/writer, tEXt metadata helpers (6d78b94)
- [x] `lib/sandbox` — capability-based sandbox for turn scripts (457edea)
- [x] `lib/reactive_optics` — Rainbow port for Lua (reactive UI, optics-based)
- [x] `lib/platform` — app loader + capability factories: `caps.self`, `caps.http_server`, `caps.http_client`, `caps.db`, `caps.shared_db`, `caps.kv`, `caps.time`, `caps.fs`, `caps.cli`, `caps.stdin`, `caps.stdout`. CLI launcher with explicit per-cap grant/deny.
- [x] `lib/ecs` — SQLite-backed entity-component store, mutable world state for sandboxed scripts. 30 assertions.
- [x] **Saved state pattern — redesign needed** — current design in `docs/platform-design.md` is a sketch (`saved_states` SQLite table, `state_ref` + `metadata` JSON columns). Needs a proper design pass: how does the platform own the schema vs. the script? How does state_ref interact with the conversation tree (`canonical_child_id`)? How does restore-on-reboot work with reactive caps? What does the save/load API look like from inside a sandboxed script? Write the redesign to `docs/platform-design.md` before implementing.
- [x] `lib/platform/caps/kv` + `caps/db` readonly support — `opts.readonly` on kv (Lua-level block), `SQLITE_OPEN_READONLY` on db (9ca0489)
- [x] `lib/formats/ccv2/macro` — ST-compatible macro substitution, 79 assertions (6a21487)
- [x] `lib/formats/ccv2/lorebook` — lorebook format conversion + trigger engine, 116 assertions (6a21487)
- [x] `lib/formats/ccv2/card` — CCv2 card format parser (read/write PNG `chara` chunk JSON), 80 assertions
- [x] `shared_db` cap with SQLite authorizer + `_app_id()` custom function (per-app isolation), 51 assertions
- [x] Context assembly engine — `lib/formats/ccv2/context`, builds messages array from card fields + lorebook + history + token budget, 60 assertions
- [x] Card app — first-party CCv2-compatible conversation app (dom entrypoint), 111 assertions
- [x] Library app — general-purpose collection browser with adapter interface + BFF server + index adapter, 135 assertions
- [x] Card app static JS UI — hand-written vanilla JS frontend + Lua BFF backend (server.lua, 76 assertions). Swipe cache, greeting alternatives, all logic server-side.
- [x] Streaming LLM responses — SSE via `POST /api/message/stream`, `llm.call_stream()` in caps, `res.raw` socket takeover in http server
- [x] Card app: message editing (fork) and deletion (subtree) — integrated with conversation tree
- [x] Conversation tree — SQLite-backed branching via lib/conversation, canonical path, sibling navigation
- [x] Impersonate mode — generate text as user character, placed in input for review
- [x] CCv2 import — charactercardv2 `import` entrypoint (PNG/JSON → parsed card), 25 assertions
- [x] Generation settings UI — temperature, top_p, penalties, max_tokens; LLM cap passthrough
- [x] Lorebook editor — CRUD endpoints + collapsible entry panel with keyword/position/order editing
- [x] Session management — create, list, switch, delete conversations; session panel UI
- [x] Preset system — connection, generation, prompt presets with save/load/import/export (71 assertions)
- [x] Card editor — view/edit all card fields with overrides persisted to kv, reset to original
- [x] Markdown rendering — client-side renderer (bold, italic, code, lists, quotes, headings, links) with XSS protection
- [x] User personas — named profiles with description injected into context, selectable per session
- [x] Token counter — context usage progress bar with color thresholds, updated after each action
- [x] Mobile responsive — ccv2 + library at 768px breakpoint: burger-menu card-header, full-screen overlays/session-panel on mobile, single-column grid + stacked header for library, horizontal-scroll tag bar. Deferred: touch gestures (swipe-to-dismiss), pinch-zoom for avatars, viewport-units fallback for older iOS Safari address-bar quirks
- [x] Character avatar — header + message avatars from PNG via `caps.self`, 400 assertions
- [x] Library app — BFF server + index adapter + static frontend, 135 assertions (0e9d187). Index adapter bridges index DB into adapter interface. Server serves HTML/JS/CSS + JSON API with tag/search filtering.
- [x] **App import + install pipeline** — complete end-to-end flow:
  1. Parse card PNG → extract card data + metadata (name, description, tags, etc.)
  2. Bundle: card data + card app runtime → app PNG (`chara` chunk untouched, add `lua` iTXt = base64(gzip(tar)), add `lua-manifest` iTXt = raw JSON manifest with card metadata in `meta.tags`, `meta.name`, etc.)
  3. Install: copy app PNG to `~/.crescent/apps/`, upsert manifest into index DB (SQLite, json_extract queryable)
  4. Library app discovers it on next scan via index DB
  **Components:**
  - [x] `lib/png` iTXt chunk support — parse/build/get/set/remove_itxt, 99 assertions. lib/platform/init.lua now uses png.get_itxt.
  - [x] `lib/gzip` — already exists as `lib/compress` (deflate/inflate with `format = "gzip"`, system zlib FFI + pure Lua tiers)
  - [x] App index database schema + upsert logic — `lib/platform/index.lua`, 43 assertions
  - [x] Card app runtime bundling + import — `lib/platform/import.lua`, 42 assertions. CLI: `luajit lib/platform/cli.lua import card.png`
  - [x] Library app BFF server — `lib/platform/apps/library/server.lua`, 41 assertions. Index adapter, 47 assertions.
- [ ] Library app — **open threads** *(from a previous session — starting
  context, not instructions; verify relevance before acting)*:
  - [x] **Uninstall UI + endpoint.** `DELETE /api/apps/:id` on daemon origin
    (daemon owns apps dir — no new destructive cap needed). Library cards
    get × button → confirm → DELETE → refresh. File deletion failure is
    non-fatal. 7 tests in daemon_test.lua. (d58798d)
  - [x] **`/discover` protocol shape defined.** See
    `docs/library-app-design.md` "Source adapters / /discover endpoint
    contract". Request: `?q&limit&offset`. Response: `{ source_name,
    total, limit, offset, entries: [{id, name, description, tags,
    thumb_url}] }`. Source adapter apps declare `meta.source_adapter=true`.
    Launch of virtual entries: library uses `/launch/<source_app_id>?entry=<id>`.
  - [x] **Second canonical app — `lib/platform/apps/sillytavern/`.**
    Lists `~/SillyTavern/public/characters/*.png`, exposes `/discover`
    with q/limit/offset, caches CCv2 metadata in SQLite. 77 tests. (next commit)
  - [x] **Wire source adapters into library UI.** Library server now
    accepts `caps.sources = [{ id, name, discover(params)->resp }]`.
    Adds `/api/sources` (list) + `/api/sources/:id/discover` (proxy).
    Frontend renders per-source sections with independent pagination and
    "load more". Daemon passes `opts.sources` through to library.
    Daemon CLI auto-loads source adapter apps from the index at startup
    (`meta.source_adapter=true`). 17 new tests.
  - [x] **Configurable caps.** `app_cap_config` table in index DB; `get/set/reset_cap_config`
    on index; app_loader merges stored overrides into cap decls before construction;
    `crescent list` + `crescent caps` CLI subcommands. 7+2 new tests. (dbfc54e, ff63155)
  - [x] **ST adapter: PNG metadata (name/description/tags).** Implemented
    via SQLite cache: reads CCv2 iTXt `chara` chunk on miss, stores in
    `card_meta`. 77 tests. (d97da4f)
  - [x] **ST adapter: card view page.** `GET /` reads `?entry=` and renders
    name/description/tags with a download link. `GET /card/:id` returns raw
    PNG bytes. daemon/cli.lua now also stores `handler` in each source entry
    for future in-process calls. 17 new tests. (09f8024→next)
  - [x] **ST adapter: "Open in conversation" button.** `POST /api/import-card`
    on daemon origin. Runtime loaded from `--runtime-dir` at startup. Library
    "Open" button calls this endpoint and navigates to launch_url. (bd62484)
  - [ ] **ST adapter: thumbnails (`GET /thumb/:id`).** Blocked on
    `stb_image_resize` FFI binding (see below). Serve resized PNG crop
    from the card file; raw card PNGs are too large to use as-is.
  - [ ] **Extract `lib/ccv2-ui/` shared library.** Chat rendering,
    markdown, LLM-cap wiring currently live in
    `lib/platform/apps/charactercardv2/dom.lua`. Both canonical-CCv2 and
    SillyTavern apps will want them. Risk of extracting before two
    consumers exist: wrong boundaries. Risk of deferring: the ST app
    duplicates code and the two diverge. Lean: wait until ST's UI
    actually needs something from dom.lua, then pull out exactly that
    piece. Not "extract everything reusable up front."
  - [ ] **Library index is validated at 20k apps** (see
    `docs/perf/library_index.lua`, `docs/perf/log.md`). If a realistic
    SillyTavern library blows past 20k, rerun the bench at 100k before
    assuming the current plan holds — FTS index build cost scales
    roughly linearly but SQLite query planning can degrade non-linearly.
- [x] Author's note — depth-based context injection with configurable position
- [x] Chat export — JSON and text format downloads with Content-Disposition
- [x] Regex scripts — find/replace on AI output and user input, test endpoint, ordered execution
- [x] Group chats — multiple characters in one conversation, turn-based speaker selection
- [x] World info / global lorebook — CRUD + import/export, merged with card lorebook in context assembly
- [x] Instruct mode / chat templates — 7 default templates (ChatML, Llama2, Alpaca, Mistral, etc.), configurable per model
- [x] Connection testing — verify LLM endpoint with latency measurement
- [x] Keyboard shortcuts — Escape closes panels, Ctrl+Shift shortcuts for all panels
- [x] Capability-based I/O migration — 77 libraries migrated from os/io globals to injected functions (time_fn, clock_fn, seed, read_fn, getenv, etc.). Directory-mode apps sandboxed. Safe subsets for jit/bit. No os/io/ffi/debug/package in sandbox.
- [x] **ccv2 card self-containment migration** — writable `self_write` cap, migrate kv → PNG for card state, world_info → user_lorebooks[] array with active toggle + "My Lorebooks" UI. Landed in 4b98ad5, c065f99, 5e751de.
- [x] **ccv2 reproduction-audit #1, #2, #9** — New Card button + `POST /api/new-card` (blank CCv2 PNG download), card header refactored to nav hub (Edit + Export on hover), reset-to-original confirm dialog. 113bc18, 4b63c1e.
- [x] **"Define crescent-format card"** — MOOT. There is no "crescent-format card"; crescent has apps. A card PNG carrying a `lua` iTXt runtime IS an app. The question was the wrong framing. Established in `docs/platform-design.md` → "No 'crescent format'."
- [x] **ccv2 import-time conversion + library integration.** Import pipeline embeds runtime (113bc18). Daemon `POST /api/import-card/upload` accepts PNG + gzip/tar.gz. Library app "Import" button + drag-drop handles both formats.
- [ ] **Import: WebP/JPEG/folder support** — apps can be embedded in any image format that supports metadata chunks (WebP has XMP/EXIF, JPEG has EXIF APP1). Folder import (dragging a directory) is also a natural target. None of these are currently handled by `lib/png` or the import pipeline — needs format detection + per-format chunk extraction in `lib/platform/import.lua`. Documented as a goal; not blocking anything today.
- [x] **ccv2 tabbed card surface** — Identity/Greetings/Lorebook/Regex in one panel. Author's Note removed from persistent bar, moved into Identity tab. Lorebook and Regex moved from standalone overlays into tabs. bdf83a6.
- [x] **ccv2 input toolbar redesign** — removed btn-lorebook, btn-card-edit, btn-regex (redundant with card header Edit), btn-export (chat export moved to card header actions). 6 buttons remain: Send, Continue, Impersonate, Settings, My Lorebooks, Group. d6fe4bd.
- [x] **ccv2 `static/app.js` modularisation** — the frontend was ~2400 lines in a single file; now ~319. All feature areas extracted: `api.js` (HTTP helper), `persona.js`, `group.js`, `regex.js`, `settings.js`, `sessions.js`, `my-lorebooks.js`, `card-editor.js`, `lorebook-entry.js`, `card-lorebook.js`, `messages.js`, `send.js`, `token-counter.js` (#token-count-text/fill, `/api/token_count`), `chat-export.js` (#btn-card-header-export-chat, `/api/export/chat`), `new-card.js` (#btn-new-card + cross-origin daemon install + download fallback), `card-state.js` (card header / avatar / writable flag / history + greeting boot). `app.js` is now wiring: `showError` indirection, focus-trap helpers (used by overlay modules), `closeAnyPanel`, keyboard shortcut dispatch, `loadAuthorsNote`. Each extracted module has a `*_test.js` covering init shape + main behaviors (135 frontend tests pass; 3 reds in `mobile-responsive.test.js` are aspirational and pre-existed this work).
- [x] **Frictionless new card — cross-origin problem** — `create_instance` cap implemented. ccv2 backend's `POST /api/new-card` calls `caps.create_instance.create(png_bytes)`, which extracts the calling app's own runtime from its installed tarball and feeds it (plus the new PNG) into the existing `import_card` pipeline, then returns `(app_id, launch_url)`. Frontend redirects on JSON response, falls back to PNG download if the cap isn't granted. New files: `lib/platform/caps/create_instance.lua` + `*_test.lua`. Wired through `lib/platform/init.lua` `CAP_FACTORIES` with deps (`apps_dir`/`write_fn`/`index_obj`/`time_fn`/`audit_log`) threaded via `context` through `daemon/app_loader.lua` from `daemon/cli.lua`. ccv2 `manifest.json` declares the cap as `required: false` so apps without it still work via the download fallback.
  - Follow-up: `extract_runtime` is a near-mirror of `import.lua`'s `bundle_runtime`. Worth extracting to a shared helper in `lib/platform/import.lua` (e.g. `M.extract_runtime(app_path)`) and reusing it from the cap. Left as a small refactor to keep this change focused.
- [ ] **ccv2 message-level fork affordance** — message action menu gains "use as first message / greeting / example" (reproduction-audit #6, rules G2/G4). Requires a fork endpoint design: `POST /api/card/fork` saves a copy of current card state with the selected message seeded as first_mes/alternate_greetings. Design before implementing.
- [ ] **ccv2 editor: WYSIWYG + live styleable preview** — the card editor fields (Description, Personality, First Message, etc.) need: (1) live preview of macro substitutions ({{char}}, {{user}}, etc.) rendered inline as the user types, with color-coded macro highlighting via CSS; (2) WYSIWYG editing — preview and edit are the same surface, not separate panels. Without this the editor is not best-in-class. Design: likely a contenteditable or CodeMirror-style field with a macro tokenizer + CSS class injection.
- [ ] **ccv2 reproduction-audit items** — living list in `docs/ccv2-reproduction-audit.md`. Items #3–#8 remain open; #3/#4/#7/#8 blocked on tabbed card surface; #6 needs fork design; #10 (blank option on import surface) is small but depends on import UI work.
- [ ] **Verify `depth_prompt_depth`/`depth_prompt_role` extension field names against ST** — `depth_prompt` (Author's Note text) and `regex_scripts` are confirmed ST fields. But `depth_prompt_depth` and `depth_prompt_role` are our flat sibling fields; ST may store the whole author's note as a nested object `depth_prompt: { prompt, depth, role }`. If wrong, author's note depth/position won't round-trip through a real ST-exported card. Needs empirical check: export a card with AN from ST, inspect the raw iTXt `chara` chunk. Code comment in server.lua (~line 423) already flags the uncertainty.
- [ ] **ccv2 linked lorebooks + Chub/ST URL import** — data model (`extensions.linked_lorebooks[]`) is specced in `docs/card-app-design.md`. First pass: import via file/paste. Follow-up: paste URL → fetch → vendor snapshot. Card-self-containment preserved via vendored snapshots; source reference is informational only.
- [ ] **App/asset versioning and forking** — broader platform question: how do apps and shared assets version, fork, and update over time? The linked-lorebook pattern (vendored snapshot + optional source for "update available" checks) is one instance. The general case (apps with shared library dependencies, preset sharing, template evolution) needs a platform-level design doc before any implementation beyond linked lorebooks.
- [ ] lua2ts async support (low priority, needs design) — transpile cap calls as `await`, propagate `async` up through callers.
- [x] lua2ts dep bundling — follow `require()` calls within the tarball and bundle all in-app deps into the JS output.
- [ ] stb_image_resize FFI binding — thumbnail generation, compiled into binary, zero runtime dep
- [x] **CLI handler convention for apps** — apps should handle a CLI entrypoint alongside their HTTP one, using `caps.cli` (args) + `caps.stdout`. Convention: `cr run <app> [-- args...]` dispatches to the app's CLI handler if it declares `cli` cap; app writes result to stdout, `--json` for machine-readable output. Lets agents invoke app functionality without HTTP. Implement the convention in `lib/platform/cli.lua` and add CLI handlers to the canonical apps (card, library).
- [ ] **REPL cap** — deferred pending design. Good REPLs need readline, history, completion, multiline input, error recovery — not worth half-solving. Design question: is this a cap (app gets a line-reader), a platform primitive, or a library on top of `caps.stdin`/`caps.stdout`?
- [x] **service/cli.lua `pretty_print` nested tables** — already works; `serialize_value` is recursive and handles maps-with-array-values correctly. TODO was stale.
- [x] **`caps.llm` backward-compat path in server.lua** — STALE TODO. The pcall pattern does not exist in the current code; server.lua uses `caps.llm` directly through the declared manifest cap, which is correct.
- [x] **`lib/http/` x-suffix naming cleanup** — renamed to `server_ws.lua`, `table_glob.lua`, `static_full.lua`, `static_full_404.lua` via git mv, all callers updated. 0c8444e.
- [x] **http_client TLS — add to `lib/http/server_tls_test.lua`** — TLS client path added in `lib/platform/caps/http_client.lua` is not yet tested. Add integration test: start a TLS server, make a TLS client request, verify round-trip. The existing `server_tls_test.lua` tests the server side; extend it to also test the client path.

## frontend accessibility audit (2026-04-30)

Audit run across `lib/platform/apps/charactercardv2/static/*` and `lib/platform/apps/library/server.lua` inline frontend. Grouped by severity. Fix-shapes are sketches, not specs.

### high — blocks SR / keyboard-only on core flows

- [x] ~~**Icon-only buttons missing `aria-label`**~~ — fixed: ccv2 session-toggle/close, settings gear/close, my-lorebooks/close, group/close, card-edit close, swipe prev/next, library card-delete all have `aria-label`.
- [x] ~~**Overlays missing `role="dialog"` + `aria-modal="true"` + `aria-labelledby`**~~ — fixed across settings, my-lorebooks, card-edit, group, session-panel.
- [x] ~~**No focus management on overlay open/close**~~ — first-pass implemented: `trapFocus`/`releaseFocus` in app.js move focus into overlay on open and restore on close. See follow-up item below.
- [x] ~~**Loading indicator not announced**~~ — `#loading` and `#connection-result` now have `role="status"` + `aria-live="polite"`.
- [x] ~~**Tabpanel `aria-labelledby` missing**~~ — added on `#tab-identity`, `#tab-greetings`, `#tab-lorebook`, `#tab-regex`.
- [x] ~~**Full focus cycling (Tab key cycle within overlay)**~~ — fixed: `setupFocusTrap` in app.js cycles Tab/Shift+Tab within overlays (settings, my-lorebooks, card-edit, group, session-panel); visible-only filter avoids hidden tab panes.

### medium — degrades but workaround exists

- [x] ~~**Swipe buttons (`<`/`>`) need descriptive labels**~~ — already done in template: `aria-label="Previous message"` / `aria-label="Next message"`.
- [x] ~~**Error/status messages dynamically inserted without `aria-live`**~~ — fixed: `#card-edit-notice`, `#lorebook-notice`, `#regex-test-output` now have `role="status" aria-live="polite"`; `#message-list` got `role="log"`. Persona save errors flow through `addMessage` → message-list (covered by `role="log"`).
- [x] ~~**Message edit cancel doesn't return focus to message**~~ — fixed: `exitEdit` now refocuses the originating Edit button (Escape also exits).
- [x] ~~**`.message__speaker` contrast borderline**~~ — fixed: new `--text-speaker` variable (~6:1 on `--bg-message`) replaces `--accent` on `.message__speaker`.

### low — polish

- [x] ~~**Avatar `alt=""` in group chat**~~ — fixed: `addMessage` sets `avatar.alt = msg.speaker + " avatar"` when a speaker is present; stays empty in single-character chat.
- [x] ~~**Tag buttons in library need `aria-pressed`**~~ — fixed: `renderTagBar` sets `aria-pressed="true|false"` on the "All" button and each tag.
- [x] ~~**Heading semantics**~~ — fixed: promoted panel titles to `<h2>` (session, settings, my-lorebooks, card-edit, group) and `<h3>` (settings sections, linked-lorebooks). Library already had `<h1>`. CSS rules updated with `margin: 0` to preserve visuals.
- [ ] **Long message list could benefit from a "Jump to input" skip link** — speculative; revisit if a user reports the navigation cost.

## frontend test regressions

> *Failing tests in `lib/platform/apps/charactercardv2/static/test/` — tests
> encode aspirational correct behavior. Each entry below is a red test that
> will turn green automatically when the underlying bug is fixed. Do NOT
> adjust tests to match buggy behavior.*

- [x] **card-editor: Escape inside the overlay does not close it** — fixed: card-editor.js registers a `keydown` listener on the overlay. Other overlays (settings, group, my-lorebooks, sessions) still rely on the document-level handler — same pattern should apply to them as follow-up.
- [x] **Per-overlay Escape handlers** — done: settings, group, my-lorebooks, sessions each register their own overlay (or panel) `keydown` listener that stops propagation and calls `close()` when `isOpen()`. Module-local tests verify the close path without touching `document`.
- [x] **card-editor: save does not surface storage path (kv vs PNG)** — fixed: `POST /api/card/edit` now returns `storage: "png"` or `storage: "kv"` (mirrors the `flush_card_state` branch — `caps.self_write.write_metadata` present → PNG; otherwise kv). Frontend `card-editor.js` already calls `showInfo("Saved to " + data.storage)` when the field is present.
- [x] **messages: sibling cache is keyed by current message id, not by the originating swipe-set id** — fixed by aliasing every sibling's id to the same cache entry in `ensureSiblings` + `addSiblingToCache`. The next swipe finds the entry regardless of which sibling's id the DOM is currently showing.

## admin app

- [ ] **Admin app** — single app (`lib/platform/apps/admin/`) with `server` (HTTP UI) and `headless` (agent/script) entrypoints. Caps: `keyring` (write) for secret management, `fs` (write, apps dir) for install/uninstall. Grant management stays in the daemon (an app that can modify other apps' grants could silently escalate its own privileges). Design in `docs/platform-design.md` under "First-party apps".
- [x] **Daemon `POST /api/new-card` removed** — endpoint and BLANK_CHARA_JSON constants deleted from daemon. The daemon must not know "card" exists. 858e0b1.

## platform daemon — implementation track

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

Full design in `docs/daemon-design.md`. The daemon is the long-running host that serves
installed apps over HTTP, brokers capability grants, and enforces the per-app browser-side
sandbox. Threat model: apps (backend + frontend, one author) are the adversary; defense
hinges on per-subdomain origin isolation + VM sandbox + strict CSP.

**v1 bring-up order** (each step testable on its own; deliberately narrow):

- [x] **HTTP skeleton** — single-port listener, path-prefix router, per-subdomain routing
  (`app-<id>.<daemon-host>` canonical, `127.0.0.x` loopback-IP fallback, URL-token fallback),
  `HttpOnly __Host-session` cookie auth, mount existing library app at the root.

  **Open threads around the skeleton:**
  - [x] Session store is in-memory only. The 24h idle-TTL bounds the map
    in steady state, but a burst of unique operators inside that window
    still grows it unboundedly, and a daemon restart forgets everyone.
    Resolved: `lib/platform/session_store/` — SQLite-backed store with
    idle TTL. Wire in via `opts.session_db_path`; in-memory path kept
    as backward-compat default. `purge_expired()` runs at daemon startup.
  - [ ] Loopback IP allocator grows monotonically and never reclaims.
    Fine at v1 scale (you run out at 127.255.255.254 apps), but a
    long-lived multi-app daemon that churns installs leaks IPs.
    Revisit when it becomes a real bound.
  - [ ] Routable-interface deployments should inject their own
    `random_bytes_fn` rather than rely on the default's `lib/rand`
    probe succeeding on the target platform. Not a code gap — an
    operator-doc gap. Might fold into daemon-design.md "deployment"
    section if/when that section exists.
- [x] **Launch flow** — operator clicks app in library → daemon mints one-shot 16-byte
  launch token, 303-redirects to app origin. Per-app cookie `__Host-app-session-<id>`.

  **Open threads around the launch flow:**
  - [x] `app_sessions` accumulated empty buckets for uninstalled apps.
    Fixed: DELETE /api/apps/:id now clears app_sessions[id], app_handlers[id],
    and app_csp[id] on eviction. (8272164)
  - [x] Rate limiting on `/launch` — token bucket burst=5, rate=0.5/s per session. (e53a4d7)
  - [ ] Standing risk note (not a gap to fix — architectural): launch
    tokens are URL-bearer on consume, not session-bound. Mitigations
    in place: 5-min expiry, one-shot, clean-URL 303, `Referrer-Policy:
    no-referrer` on the mint response. True session-binding would
    need a different architecture — signed token with session-id
    payload, or a daemon→app-origin bridge — because the daemon
    session cookie cannot cross origins. Worth revisiting if/when
    bearer semantics become an incident.
- [x] **Per-app VM host** — per-app env built from `lib/sandbox/` + `platform.make_caps()`,
  served by daemon's Host-based app dispatch. Env-based tier-1 sandbox (single state +
  per-app env table + pcall wrap).

  **Open threads around the VM host:**
  - [ ] `caps.self.origin` (full scheme+host URL) is not exposed. Not
    speculatively adding it — the first concrete caller that needs it
    gets to shape the field.
  - [ ] Tier 2/3 isolation escalation: coroutine-per-request with
    `debug.sethook` instruction quota (tier 2), or separate `lua_State`
    per app (tier 3). Design + triggers in `docs/daemon-isolation.md`.
  - [ ] **Grant UI: surface cap `reason` fields** — manifest cap declarations support a `"reason"` string (e.g. `"reason": "Timestamps cache entries..."`). The grant/install UI should display this alongside the cap name so operators know why the app needs each capability. Currently ignored at runtime.
    Not urgent for loopback/Tailscale-private; required before any
    routable-interface deployment, and entangled with the grant UI
    work (both move "apps are untrusted" from "documented" to
    "enforced").
  - [x] Handler cache has LRU eviction but no time-based invalidation.
    Wired `handler_ttl` daemon opt: passes `{ttl, clock}` to
    `cache.new`. Default nil (no expiry — install-time cache-busting
    covers the normal reinstall path). Hot-reload workflow: pass a
    short `handler_ttl`.
  - [ ] `app_load_errors` has a 5s retry TTL but no link to index-DB
    change notifications. A partially-written tarball during
    `pkg install` heals in 5s; an explicit operator "retry this app"
    button or an index-DB write callback would heal instantly.
    Depends on whether the index layer grows a change-notification
    surface.
  - [x] `app_loader` auto-grants every declared cap when no decisions are
    stored (`_auto_grants` fallback). Fixed: `resolve_grants` now returns
    nil (undecided) when `get_grants` is available but no decisions stored.
    Raw-db test stubs (no `get_grants`) still auto-grant for compat.
  - [ ] Typechecker gap noted during wiring: optional fields (`T | nil`)
    in an expected record must appear in the table literal even when
    semantically absent. `daemon.make({...})` callsites hit this.
    Belongs in a typechecker session, not here — but worth linking to
    when someone picks up the optional-field work.
- [x] **Cap grant UI + endpoint** — grant page at daemon origin. Zero-JS HTML form, CSRF
  token in hidden input, POST stores decisions, dispatch gate redirects on undecided required
  caps, handler cache invalidated on save. (c457175)
- [x] **CSP emission** — daemon injects `Content-Security-Policy` on all app-origin
  responses: `default-src 'self'; connect-src 'self' <http_client hosts>; frame-ancestors
  'none'; form-action 'self'`. Hosts from operator cap_config. (9576acf)
  - [ ] Tighten to `default-src 'none'` + explicit directives once apps declare their
    static asset needs in the manifest. Requires manifest-level `script-src`/`style-src`
    declarations or nonce injection.
- [x] **Daemon UI XSS resistance** — grant page ships with strict CSP (`default-src 'none';
  style-src 'unsafe-inline'; form-action 'self'`), all user/app strings HTML-escaped.
  (c457175)
- [x] **Rate limiting** — per-session token bucket on `/launch` (burst=5,
  rate=0.5/s) and `POST /apps/:id/grant` (burst=10, rate=1/s). Uses
  `lib/ratelimit` keyed limiter. Per-IP and auth-endpoint limits deferred
  (daemon has no direct access to remote IP; no auth endpoints beyond session
  cookie minting, which is implicit and not rate-sensitive).
- [x] **Audit log** — append-only log of every cap grant, every auth event, every
  admin/policy change. Tamper-evident hashing (prior-entry hash chain).
  Implemented in `lib/platform/audit/`. SHA-1 hash chain; SQLite backend;
  wired into daemon (cap_grant, auth_session, launch_token, app_install,
  app_uninstall events). `audit_log` is optional in `daemon_opts` — nil skips
  logging. 31 test assertions.
- [x] **TLS on routable interfaces** — binding to loopback is TLS-optional; binding to
  Tailscale or any routable interface requires TLS. Cert loading from disk (daemon does
  not do ACME in v1 — user provides cert). v1 implemented: `--tls-cert`/`--tls-key` flags
  in daemon CLI; `lib/http/server.lua` wraps accepted sockets via libtls `tls_accept_socket`;
  falls back to plaintext if libtls unavailable; daemon warns on non-loopback bind without TLS.
- [x] **Admin policy layer** — admin can set blanket allow/deny ceilings per app, per cap,
  per cap+host tuple. Caps the grant UI against those ceilings so the operator cannot be
  socially engineered past admin intent.

## lib/mdast Phase 2 — CommonMark gaps and GFM extensions

**[x] Phase 2 fixture validation substantially complete.** CommonMark 0.31.2 spec fixture suite
validated via `lib/unified/mdast/commonmark_fixtures_test.lua`. Current pass rates (652 examples):
- Block structure (ATX, setext, fenced code, indented code, paragraphs, thematic breaks): 100%
- Block quotes: 100%, Thematic breaks: 100%, List items: 100%, Lists: **100%** (26/26)
- Emphasis: **100%** (132/132), Code spans: 91% (20/22)
- Links: **98.9%** (89/90), Images: 100%, Hard line breaks: 87%
- Tabs: 73% (8/11) — tab expansion in indented code/list contexts

**[x] Phase 3 CommonMark compliance pass complete** (commit 8728def, 2026-04-10). All gaps from Phase 2 fixed:
- ex312 (lists lazy continuation): item_lazy_set tracks lazy lines; parse_blocks skips list-item match for them.
- Emphasis with inline HTML (ex475-ex481): tokenizer scans `<tag>`, `</tag>`, `<!-- -->`, `<![CDATA[…]]>`, `<?…?>`, `<!DECL>` as opaque html tokens; delimiters inside are never paired.
- Unicode punctuation/whitespace: full codepoint decoding via decode_utf8_at/before; U+00A0 NBSP as whitespace; Sc currency symbols (£, €) as punctuation to match cmark.
- HTML entity decoding in link URLs and titles (decode_entities, encode_url non-ASCII bytes).
- Backslash escapes in link titles.
- Multi-line link reference definitions (two-line join in block parser).
- Unicode case folding for link labels (ẞ → ss).

Remaining known gaps (acceptable, no fix planned):

- **ex491 (links)** — `[link](<foo\nbar>)` newline inside angle-bracket URL; valid raw HTML pass-through across newlines. Unfixable without implementing raw HTML block section (skipped).
- **HTML blocks** — 7 block types with different termination rules (skipped).
- **Autolinks** — `<url>` and `<email>` forms (skipped section; autolinks ARE rendered correctly via html token detection in inline renderer).
- **Backslash escapes / Entity references** — full entity name → character conversion (skipped section).
- **GFM extensions** — tables, strikethrough (`~~text~~`), task list items (`- [x]`).
- **`mdast.stringify` completeness** — round-trip is best-effort; complex nested
  structures may not stringify perfectly.
- **Benchmarks** — no throughput benchmark committed yet (needed before lib/hast).

## lib/hast and unified pipeline

- [x] **`lib/hast`** — mdast-to-hast transformer + HTML serializer. Input: mdast Root node. Output: hast Root node (element/text/raw nodes following hast spec). `hast.to_html(tree)` → HTML string. Phase 1: covers all mdast Phase 1 node types. 66 assertions.
- [x] **`lib/unified`** — pipeline runner (`:use(plugin, opts)`, `:process(source)`). 23 tests.
- [x] **`lib/rehype`** — hast plugins ported: slug, autolink-headings, sanitize, highlight, and ~20 more. See `lib/unified/STATUS.md`.

## CRITICAL: fuzz the typechecker against the full type system spec as invariants

**Prerequisite: typechecker must be in a non-broken state before starting.**

The test suite tests behaviors, not invariants. The invariants must encode the **spirit** of the type system from first principles — not mirror the implementation, which is likely wrong in places.

The full type system expressed as invariants (not exhaustive, but the spirit):
- **Subtyping**: if `A <: B`, every program that typechecks with a value of type B must also typecheck with a value of type A in its place
- **Union introduction**: a value of type A is assignable to `A | B`; a value of type B is assignable to `A | B`
- **Union elimination**: code that handles both A and B handles `A | B`
- **Intersection**: a value of type `A & B` is usable as both A and B independently
- **Function**: calling `(A) -> B` with a value of type A always produces a value of type B; calling with a non-A is always rejected
- **Narrowing**: after a nil check on `T | nil`, the type in the non-nil branch is `T`; `T` is a subtype of the original
- **Annotation soundness**: a function whose body is accepted with return type `T` annotation cannot produce a value outside `T`
- **Multi-return**: slot N of a multi-return must be the declared type for that slot; extra slots are nil

Every feature needs its own invariant class:
- **Spread multi-return**: slot extraction, narrowing propagation across slots, spread in argument position
- **HKTs**: applying a type constructor to a type argument produces the correct instantiation; HKT + generic constraints compose correctly
- **Every intrinsic** — full list, each with its own contract. Type-level intrinsics: `$Keys<T>` (union of string literal field names), `$EachField<T, F>` (maps F over each field), `$EachUnion<T, F>` (maps F over each union arm), `$Opaque<T>` / `$Opaque<T, U>` (nominal newtype with optional exposed view), `$FfiC` (closed table from ffi.cdef calls), `$GlobalScope` (closed table of declared globals), `$Name` (string literal of declaration name), `$Require<T>` (module type from string literal).
  - **v7 note:** this is a legacy/current-checker fuzz inventory, not the v7 admitted-intrinsic list. v7 tracks admitted/candidate status in `docs/typechecker-v7-kernel-semantics.md` and `docs/typechecker-v7-consolidation-audit.md`; `$Name` is currently not admitted there.
  - **Note: builtins must not be special-cased.** `require`, `pcall`/`xpcall`, `pairs`/`ipairs`, `type()`, `assert`, `error`, `select`, and stdlib functions like `string.find`/`io.open`/`string.byte` are currently hardcoded in constrain.lua. Each special case is a missing type system feature — the goal is to eliminate all of them by making stdlib_types.lua declarations expressive enough. The fuzz suite should verify each builtin's contract holds AND that the contract is expressible without special-casing. Removing a special case and replacing it with a stdlib_types.lua declaration is a correctness win, not just cleanup.
- **Match/narrowing patterns**: `if type(x) == "string"`, `if x then`, `if not x`, `if x == nil`, `and`/`or` chains — each must narrow to exactly what the spec says, no more, no less
- **Generic constraints**: a generic `<T: Constraint>` rejects instantiations that violate the constraint; accepts all that satisfy it
- **Literal types**: `1` is assignable to `integer` and `1` but not `2`; literal widening is explicit not implicit
- **Generic constraints on HKTs**: `<F: Functor>` where F is itself a type constructor — fmap must typecheck correctly for any valid F

Use `lib/test/fuzz.lua` + `lib/test/arb.lua` to generate programs and assert these invariants hold across random inputs. Fuzz targets derived from the spec, not the implementation.

**Performance**: include a benchmark gate — if typechecking throughput on a fixed corpus regresses beyond a threshold, the fuzz suite should flag it. The typechecker has a performance bar and regressions are as bad as correctness failures.

The bar to beat is `@typescript/native-preview` (tsgo / ts7 — the Go rewrite of tsc). Benchmark methodology: construct a representative "nice" TypeScript program and a structurally similar Lua program, compare cold-start + incremental throughput. Also include pathological Lua cases (deep union chains, heavily generic code, large files) that have no TS equivalent — these stress the solver and expose regressions invisible in the nice-program comparison.

**Performance note on multi-return redesign**: always wrapping rl=0 and rl=1 returns in TAG_TUPLE adds allocation + C_INDEX destructuring overhead on every call site. We may want to re-specialize these cases (bind directly, skip the tuple barrier) after measuring. Don't assume the overhead is acceptable — benchmark first.

## ~~CRITICAL: write docs/semantics.md~~ DONE (8ec327c)

`docs/semantics.md` now covers: all type tags + data layouts, the complete
subtyping relation (19 cases), expression typing rules, the constraint solver,
narrowing, annotation syntax, invariants (incl. untested blind spots), and
intrinsic contracts. Read it before touching typechecker internals.

## CRITICAL: write implementer specs before delegating

Each item below needs a self-contained spec in `docs/` (or inline in TODO) that a subagent can implement from without reading session history. Design decisions scattered across TODO.md + docs/type-system.md + session notes are not enough — an implementer needs: what to build, what files to touch, what the data representation is, what tests to write.

Items that currently lack an implementer-ready spec:
- [x] **TAG_SPREAD in return position** — spec written: `docs/tag-spread-spec.md`. Ready to delegate.
- [x] **`$Opaque<T, U>` two-arg form** — implemented (ae91a98). Fields in U accessible; fields not in U error; one-arg opaque field access errors. `ctx._opaque_nominals` + `ctx._opaque_view` side tables.
- [x] **`--:: unseal`** — implemented (6805930). Rebinds opaque variable to inner type T from declaration point forward. Line-by-line application in gen_block; block scoping via child scope; rejects newtype nominals.
- [x] **Argument literal widening at typevar binding** — was already handled by `widen_for_sub` in `solve_callable`. Clarified with explicit `widen_literal` helper + comments + 10 tests confirming the behavior (ad58bc6).
- [x] **GAP-HKT3 fix: `$Opaque` keys in lib/fp/** — applied to all 10 typeclass modules + 9 instance modules. `fa[Mappable.key]` now resolves via FLAG_OPAQUE_KEY. (2026-03-29, 839610f)
- [x] **`$Require<T>` as parameterized intrinsic** — implemented (9d92308). `expand_require` in intrinsic.lua; `resolve_deferred_intrinsic` in solve.lua evaluates TAG_TYPE_CALL on TAG_INTRINSIC callees after arg solving. Module declaration processing moved to pass 0. constrain.lua special case preserved pending full de-specialcase.
- [ ] **De-specialcase builtins** — `require` (f468b72), `pcall`/`xpcall` (d7950de), `pairs`/`ipairs` (d7950de) done. All stdlib tables (string/table/math/io/os/coroutine/debug + primitive meta types) now declared in stdlib_types.lua (33640d0). Remaining special-casing: `type()` narrowing in narrow.lua (justified, can stay), `require()` side effects in constrain.lua (architectural). Still too-loose: `select()` (needs overloads or literal matching). `string.match` ($PatternReturn<P>), `string.gmatch` ($PatternReturn<P> via iterator), `string.find` ($FindReturn<P>) all have pattern introspection. `string.gsub` returns `(string, integer)` and needs no pattern introspection. `assert` and `error` are clean.
- [x] **Eliminate intrinsics via `match` arm patterns** — MOSTLY DONE. Function-type arms, indexer arms, spread-in-tuple-position, all-fields pattern, and capture sigil all implemented (2026-03-29–30). `$PcallReturn`, `$PairsReturn`, `$IpairsReturn`, `$Keys`, `$Values`, `$IpairsValues` all deleted and replaced with pure match aliases in stdlib_types.lua.
  **Remaining intrinsics (permanent or blocked):**
  - `$Require<T>` — permanent; module system, needs literal type propagation through generics
  - `$Opaque<T>` — permanent; nominal identity
  - `$FfiC` — permanent; builds closed table from ffi.cdef call sites
  - `$EachField<T, F>` — blocked on HKT application in result position. F is a type constructor (`* -> *`); `$EachField` calls `F(field_descriptor)` per field. Match types can destructure but can't apply an arbitrary type constructor parameter. Eliminating this requires higher-kinded type application, not more match patterns.
  - `$GlobalScope` — undocumented; used for typing `_G`. Document or replace.
- [x] **Invariant-based fuzz suite** — implemented (e3d5f96): `lib/type/static/fuzz_test.lua` + `fuzz_arb.lua`. 6 invariants + performance gate (≥500 programs/sec).
- [x] **Fuzz suite gaps** — all three tiers complete: algebra (A1–A5), eval (E1–E11 + G1–G3), grammar (P1–P5). See `docs/fuzz-gaps.md` for details.
- [x] **Parser stack overflow on deeply-nested types** — fixed (5150a5a, 2026-03-29): added depth counter to scanner; parse_type fires "too deeply nested" diagnostic at depth>64 (MAX_TYPE_DEPTH). depth_limit_hit flag distinguishes this from silenced syntax errors. fuzz_test.lua pre-check skips these cleanly.
- [x] **fuzz_arb.lua sub_size halving reduces deep-type coverage** — added `M.arb_type_deep` (2026-03-29): uses `sub_size = min(size-1, 8)` for deeper trees, capped at 8 to prevent 2^N blowup. Used in fuzz_alg.lua invariants 15-18 (deep reflexivity, deep union intro, deep inter elim, deep intersection intro). Grammar-level tests still use halved arb_type (must parse strings).
- [x] **`pcall`/`xpcall` de-specialcase** — implemented (d7950de): `$PcallReturn<F>` intrinsic.
- [x] **`pairs`/`ipairs` de-specialcase** — implemented (d7950de): `$PairsReturn<T>`/`$IpairsReturn<T>` intrinsics.
- [x] **Self-check regression: constrain.lua 60 errors** — fixed (5c23738): `--:` annotations added across constrain.lua, narrow.lua, check.lua, solve.lua, lsp.lua, ctx_types.lua, type_soundness_test.lua. All now self-check at 0 errors.
- [x] **Self-check: match.lua annotation pass** — fixed (6740aeb, 2026-03-30): added Ctx type to function signatures; --: integer for lists/fields:get(); --: any for merge_bindings. 0 errors, 6 intentional any warnings.

## typechecker soundness gaps (found by type_soundness_test.lua)

- [x] **`unknown` was not strict** — `TAG_UNKNOWN` was behaving like `TAG_ANY`: field access, calls, and arithmetic silently passed through. Fixed in solve.lua: all three now emit errors. `unknown` requires narrowing first.
- [x] **Coinductive cycle detection in unify.lua** — `lib/fp/maybe` and `lib/fp/either` caused stack overflow during typechecking. Fixed by adding `seen` parameter with `copy_seen()` for disjunctive iterations.
- [x] **`match` type adversarial coverage** — non-exhaustive match on union, wrong arm result type downstream, unreachable arm, match on `never` → `never`, nested match types (concrete inner args), and `--:: module` declaration / require basic coverage all tested. Note: unreachable arm does not warn (no diagnostic emitted).
- [x] **Typechecker: nested match typevar not forwarded to inner type call** — fixed (85c92d6). Root cause: `substitute_inner`'s TAG_MATCH_TYPE handler didn't defer when subject was TAG_NAMED (only deferred for TAG_VAR/TAG_ROWVAR). Fix: added TAG_NAMED to the deferred-evaluation guard in env.lua.

- [x] **Soundness gap: optional field not rejected in required position** — `{ x?: T }` is currently accepted where `{ x: T }` (required) is expected. `unify.lua` skips source fields that are absent but does not check FLAG_OPTIONAL on *source* fields vs required target. `{ x?: T } </: { x: T }` should fail. Found while adding fuzz_eval.lua invariants (2026-03-30).

- [x] **Field access on nil/boolean** — fixed f1a9882
- [x] **Annotation on M.field assignment not enforced** — fixed 08fd6a4
- [x] **`and` RHS not narrowed** — fixed 11cf377
- [x] **Readonly not enforced through intersection** — fixed 0b40861
- [x] **Literal table not assignable to indexer type** — fixed 0b40861
- [x] **Missing return detection** — fixed; `is_definitely_returning` analysis in constrain.lua emits implicit nil C_RETURN for non-definitely-returning annotated functions.

- [ ] **Soundness gap 8: `local x --: T = expr` does not enforce the subtype check.** Broad gap, not just `unknown`:
  ```lua
  local x --: integer = "hello"      -- accepted; should error
  local s --: string = "hi"
  local y --: integer = s            -- accepted; should error
  ```
  The cast form `local y = --[[: integer]] s` is correctly rejected. The
  annotated-local path at `constrain.lua:2440` emits the same `C_SUB(rhs_tid,
  ann_tid)` constraint but the check silently passes. Function return
  annotations (`local function f() --: () -> T`) also enforce correctly. Find
  the divergence between the cast `C_SUB` and the local-init `C_SUB` and
  close the bypass. See `docs/soundness-audit.md` Gap 8 for four repros. The
  "annotation enforcement gotcha" note in `lib/type/static/CLAUDE.md` is a
  symptom of this same gap.

- [ ] **Soundness gap 9: `local x --: T` (no initializer) silently accepted.** Same family as Gap 8 — annotated local whose declared type is not enforced against the actual binding. Runtime value is `nil` but type says `T`:
  ```lua
  local y --: integer
  print(y + 1)   -- typechecks; runtime: nil + 1 errors
  ```
  Likely the same code path in `constrain.lua` near line 2440. Fix direction (preferred, matches TS): reject the declaration when `nil` is not in `T` and there is no initializer — equivalent to TS's "definite assignment" check, the strictly-weaker form (without flow analysis) that catches the obvious cases. Weaker fallback: widen to `T | nil` so reads must narrow before use. See `docs/soundness-audit.md` Gap 9. **Compounded by Gap 10**: until the parser stops dropping `= x` after `--: T`, fixing Gap 9 alone still leaves `local y --: integer = x` silently mis-parsing — fix Gap 10 first or together.

- [ ] **Soundness gap 10: parser silently accepts invalid syntax in `--:` annotations.** `integer = x` is not a valid type expression, but `ann.lua:1153–1155` parses the `integer` prefix and returns without checking the scanner reached end-of-content (`lex.lua` captures everything to EOL as the annotation content). So `local y --: integer = "string literal"`, `local y --: integer ! ! garbage`, `local y --: integer = undefined_ident` all typecheck with 0 diagnostics. This is a parser bug — the parser must reject what it cannot understand — and it is the load-bearing footgun for Gap 9: `local y --: T = x` *looks like* annotated assignment, parses cleanly, and silently becomes a no-initializer declaration. Fix: in `ann.lua` after `parse_type(s)` for `ANN_TYPE` (also `ANN_TYPE_ARGS` and the type tail of `ANN_DECL` / `declare` / `newtype`), reject with a parse error pointing at the unexpected token whenever the scanner has unconsumed non-whitespace content. No warning-instead-of-error; no weaker fallback. See `docs/soundness-audit.md` Gap 10.

- [ ] **Add fuzz invariant for `local x --: T = expr` annotation enforcement.** Existing annotation-soundness invariants use function returns as the harness, missing the local-init path entirely (which is why Gap 8 survived). Add: for `expr` of type `U` and annotation `T`, expect an error iff `U </: T`. Combine with `unknown` in the type generator (see next item) for full coverage.

- [ ] **Add `unknown` to `fuzz_arb.lua` type generator.** Currently absent (see `lib/type/static/CLAUDE.md` "Generator coverage"). Adding it will let the new annotation invariant cover the `unknown <: T` case, plus narrow / type-guard / call-result invariants currently blind to the unknown boundary.

## typechecker cast / annotation syntax

- [ ] **Decide: implement `--[[as T]]` semi-sound cast (overlap-required)?** Previously documented in `docs/type-system.md` as if real, but never implemented. The doc has been corrected to remove the false claim. If we want this, design and implement: an "overlap" check (target type must share *some* value with the source), then accept the cast even if neither direction is a subtype. Otherwise leave as-is — the current `--[[: T]] expr` is a sound checked cast and may be all we need.

- [ ] **Decide: implement `--[[as! T]] expr` force / unsafe cast?** Previously documented as if real (see above). If we want a way to escape the type system inline (vs. routing through an `any`-typed intermediary), pick a syntax — `--[[as! T]]`, `--[[unsafe T]]`, `--[[: T !]]`, etc. — and wire it through `lex.lua`/`parse.lua`/`constrain.lua` as a `NODE_CAST_EXPR` variant that emits no constraint and just rebinds the type. Keep it grep-able. Otherwise close this with "use `any` instead."

## typechecker match semantics gaps

- [x] **`Parameters<typeof f>` captures only first param** — FIXED. `Parameters<F> = match F { (...%P) -> %R => P }` now gives `(integer, string)` for `f: (integer, string) -> boolean`. fuzz_test.lua P2a/P2b both pass.

- [x] **Intersection types are opaque in match arms** — FIXED properly (521226a). DNF normalization in `M.evaluate`: `to_dnf` expands `A|(B&C)` and `A&(B|C)` into terms; each term dispatched independently. For pure-table intersections, `flatten_to_table` merges all member fields into one TAG_TABLE so structural patterns see all fields. Band-aid (0ace6b0) replaced.

## typechecker missing features

- [ ] **Bounded existentials (low priority, future extension).** Crescent uses `$Opaque<T>` (nominal opaqueness with optional view type) as a primitive form of existential. A more general bounded existential `∃T <: B. F(T)` could enable module-style abstraction, plugin systems, and abstract data types with constraints. Not currently needed — `$Opaque` has been sufficient for every observed use case. Flag for revisit only if a concrete use case appears that `$Opaque` cannot express. See `docs/type-system.md` "Union, intersection, and complement" for the foundational decisions this would extend.
- [x] **`?` optional field shorthand breaks alias usability** — `T?` in struct position was previously a thrown error that silently aborted the whole annotation parse, causing the alias to not be registered at all. Fixed: `parse_postfix` now uses `scan_hint` (non-fatal) so the error is reported as a structured diagnostic while the rest of the struct (and the alias itself) still parse correctly. `T | nil` remains the correct syntax; `T?` now produces a visible diagnostic rather than silently breaking the enclosing alias.
- [x] **`--:: require` doesn't resolve `?/init.lua` packages** — `load_decl_file` in `constrain.lua` converts the module path with `gsub("%.", "/") .. ".lua"`, so `--:: require "lib.reactive"` opens `lib/reactive.lua` (which does not exist) instead of `lib/reactive/init.lua`. Type declarations in packages structured as directories with `init.lua` are silently ignored. Fix: after the `.lua` path fails, fall back to `gsub("%.", "/") .. "/init.lua"`. Same logic used in `$Require`/`cri_loader` already handles this; `load_decl_file` is missing the fallback. Found during `lib/web/reactive_dom/init.lua` annotation: `--:: require "lib.reactive"` cannot import Signal/Computed from `lib/reactive/init.lua`. Workaround: redeclare types inline. Blocking: any `--::` declaration file that imports types from a `?/init.lua` package.
- [ ] **`lib/web/reactive_dom/` needs generics** — 12 errors remain because `signal.get()` returns `unknown` (correct — Signal is polymorphic) and `children[i]` returns `unknown` (correct — heterogeneous array). Neither is fixable by casting; both require generics: `Signal<T>` with `get: () -> T`, typed child arrays. Blocked on generic type parameters.
- [ ] **Table literal computed-key entries collapse into one indexer** — when a table literal has multiple `[key_expr]: value` entries with nominally distinct key types (e.g. `$Opaque`), the typechecker folds them into a single indexer and unifies the value types, causing false errors on heterogeneous dispatch tables like `fn_index` in `lib/fp/fn/`. Correct behavior: each distinct key type produces a separate field in the inferred table type. Fix is in table literal type construction — stop collapsing computed-key entries into one indexer; instead treat each distinct key type as a distinct field. Concrete symptom: `fn_index[Profunctor.key] = fn_profunctor_impl` errors because the inferred indexer value type comes from the first three entries (all have `map`).
- [ ] **Table construction type inference** — `local k = {}` followed by `k.field = value` should refine the type of `k` to include each assigned field, so methods defined on `k` can access those fields without `any`. Currently the typechecker treats `k` as a fixed open table throughout, so `self._insns` inside a closure assigned to `k.method` returns `unknown`. The workaround `unknown → any → T` two-step in `lib/asm/ir.lua` (`insns_any`/`self_args_any`) is a direct symptom. Real fix: flow-sensitive table type widening during construction, or structural typing on method-receiver `self` via declared object type.
- [ ] **Render function bidirectional parameter typing** — `lib/tui/init.lua` render closures (`function(a, b)`) have untyped parameters because no declared Widget.render type is checked against them. If `Widget = { render: (Widget, Ctx) -> string }` were checked bidirectionally when the closure is assigned into a Widget table, `b` would get type `Ctx` and `unpack_ctx`'s `any` parameters would be unnecessary. Root cause: typechecker does not propagate expected function parameter types into anonymous closures from the surrounding table literal. Real fix: bidirectional type checking for closures assigned to known-typed table fields.
- [x] **Record spread types** — `{ ...T, k: V }`, `{ ...T, ...U }`, `{ k: V, ...T }` as type-level operations. Unification added (33640d0): unify.lua checks spread fields by expanding inner TAG_TABLE and verifying each required field exists in the actual. Gap: **spread-union distribution** — when the spread inner type is a TAG_UNION (`{ ...(A | B), k: V }`), env.lua `substitute_inner` keeps a placeholder instead of distributing. Correct fix: distribute over union members in `env.lua:substitute_inner`, then handle in `solve.lua` field lookup and unify.lua. Needed for builder pattern and mapped-type aliases instantiated with union types.
- [x] Typechecker: `collect_rank_n_generics` over-fires on ordinary higher-order generics
  - `lib/type/static/env.lua:588-601` uses `TAG_FUNCTION` as proxy for rank-N; should use `TAG_FORALL`
  - Causes `<R>(() -> R) -> () -> R` and similar to be incorrectly skolemized
  - Minimal repro: `--:: declare wrap = <R>(() -> R) -> () -> R` then `local x = wrap(function() return 1 end)`
  - Design doc: `docs/typechecker-rank-n.md` describes the correct TAG_FORALL-based dispatch
  - Fix requires care to not regress rank-N soundness tests (N1/N5/N6/N7/N8 in type_soundness_test.lua)

## typechecker stdlib / module typing

- [x] **`module "name": T` syntax** — `--:: module "name": T` declares the type returned by `require("name")`. Implemented in ann.lua (ANN_MODULE), constrain.lua (module_types registry), prelude.lua (loaded from .d.lua files). Undeclared modules → `unknown`. stdlib_types.lua now declares `"ffi"` and `"bit"` properly.
- [x] **`$Require<Path>` intrinsic** — implemented. `require` declared as `<T: string>(module: T) -> $Require<T>` in stdlib_types.lua. `expand_require` in intrinsic.lua resolves module types from `ctx.module_types` (declarations) or `ctx.cri_loader` (cross-file cache). Undeclared modules → `T_UNKNOWN` (fixed e48fd1f — was `T_ANY`, silently disabling checking on all undeclared module returns).
- [x] **Cross-file inference enabled by default** — removed `_disk_cache_dir` gate on `check_file`'s `cri_loader` (ead40ae). Also fixed `init.lua` resolution for `require("lib.path")` → `lib/path/init.lua`.
- [x] **`$FfiC` intrinsic** — implemented. `TAG_FFIC = 26`, deferred resolution in solve.lua, cdef.lua makes `T_FFI_C` closed (undeclared C symbols error), stdlib_types.lua declares `C: $FfiC`.

## stdlib_types.lua coverage gaps (audit 2026-04-01)

- [x] **Over-broad `any` return types** — PARTIALLY FIXED (06c6b38). Tightened 7: `coroutine.status` (literal union), `string.gmatch` (`function`), `table.remove` (`any | nil`), `coroutine.create`/`wrap`/`resume`/`yield` (function params + multi-return). Remaining:
  - `assert` → needs `typeof(val)` (type-level computation)
  - `string.match` → DONE ($PatternReturn<P>, 2026-04-19)
  - `string.gmatch` → DONE ($PatternReturn<P> in iterator, 2026-04-19)
  - `string.find` → DONE ($FindReturn<P>, 2026-04-19)
  - `os.date` → format-dependent return (`string | { [string]: integer }`)
  - `io.open` / `io.popen` → needs file handle opaque type
  - Parser limitation: function types in table field return positions break the annotation parser silently
- [x] **Missing stdlib functions** — FIXED (819179f). Added `io.flush`/`input`/`output` + 8 `ffi.*` functions. Remaining:
  - `os.setlocale` (low)
  - `debug.getupvalue`, `debug.setupvalue` (low)
- [x] **`$GlobalScope` intrinsic documented** — listed in `lib/type/static/CLAUDE.md` under permanent intrinsics with full explanation of the synthesis mechanism.
- [ ] **Generalize stdlib_types.lua beyond LuaJIT** — currently mixes Lua 5.1 and LuaJIT-specific declarations (`ffi`, `bit`, `Ptr<T>`, `Arr<T>`, `Cdata`, `Ctype`, `CTypeMap`) in one file. Should split per-runtime: `stdlib_lua51_types.lua`, `stdlib_luajit_types.lua`, `stdlib_lua54_types.lua`, etc. Loaded via `pkg.lua typecheck.globals` per-project. Blocks supporting Lua 5.4 semantics (integer subtype, `//`/`>>`/`<<` ops, goto, etc.) and other variants without forking the file.
- [x] **Module type field access loses concrete types for `?/init.lua` packages** — resolved as a consequence of the `?/init.lua` resolution fix (d907c40). `R = require("lib.reactive")` now resolves to the full typed module; `R.focused` returns a concrete function type. Remaining `unknown` params in method signatures are expected — `lib/reactive` uses plain Lua generics, not Crescent type parameters.

### ffi types — open threads (from a previous session — starting context, not instructions; verify relevance before acting)

See `docs/ffi-types.md` for the postmortem and design state. Resolved in recent commits: T-as-Lua-type semantics, extensible CTypeMap, `T[K]` indexed access, `Keys<>` constraint, TAG_NOMINAL arith unwrap, dropped `Cdata<T>` wrapper, declarative `Ptr<T>`/`Arr<T>` in stdlib.

- [ ] **`int64_t`/`uint64_t` typing** — currently mapped to `integer` in `CTypeMap`. Wrong: in LuaJIT these stay as cdata, don't coerce to Lua integer (>2^53 lossy). Idea floated: each gets its own type with its own metatable defining `#__add: (int64_t, int64_t) -> int64_t` etc. — NOT promotion to integer. Open: what's the right declaration shape? Plain opaque + meta slots, or some other primitive? Also — does our typechecker handle the metatable-based arith for these once declared? May need spot-checking after authoring.
- [ ] **LuaJIT integer literal suffixes** — `5LL` is `int64_t`, `5ULL` is `uint64_t`. The lexer probably doesn't recognize these (vanilla Lua doesn't have them). Should check `lib/type/static/lex.lua` and either add LL/ULL parsing or punt and require users to use `ffi.new("int64_t", 5)`.
- [ ] **`metatype.metatable` shape** — currently `{ [string]: unknown, ... }`. Could tighten to a proper Lua metatable with named meta slots: `{ #__index: ..., #__add: ..., #__sub: ..., ... }`. Probably reusable across lua-side `setmetatable` too. See existing `setmetatable: <T, MT>(t: T, mt: MT) -> T & { #...MT }` pattern.
- [ ] **`Cdata<T> <: T` asymmetric subtyping** — only relevant if we re-introduce a `Cdata<T>` wrapper. Current model (no wrapper, return T directly) sidesteps it. But if we ever want a "branded but transparent" wrapper for FFI provenance, the typechecker has no asymmetric-subtyping primitive: `$Opaque<T,T>` is invariant, intersection-with-marker brands are hacky per the user's explicit ruling. Probably means designing a real "covariant newtype" mechanism in the typechecker, or just accepting Cdata-is-T forever.
- [ ] **Audit remaining `unknown`/`any` outside the ffi module** — string/table/math/io/os/coroutine/debug modules not yet audited in this pass. Section above lists known holes (`assert`, `string.match`, `os.date`, `io.open` file handle); a fresh sweep might surface more, plus places where `any` could be `unknown` or further constrained.

## typechecker type guards and assertions

TypeScript's type guards can lie — `function isString(x): x is string { return true }` typechecks fine. We should do better.

- [x] **User-defined type guards** — implemented (0e3be6f, 2026-03-30). `(x: unknown) -> x is T` return type: ann.lua parses the predicate, stores in pool._type_predicates; narrow.lua `guard_check` kind narrows the argument at call sites (truthy/falsy/negated). Body return type is enforced as boolean.

- [x] **Assertion functions** — implemented (6740aeb, 2026-03-30): `(x: T) -> asserts x is GuardType` parses in ann.lua, unconditional scope narrowing in StmtRule[NODE_EXPR_STMT]. Also fixed latent bug: predicate IDs now propagated from annotation arena to ctx.types arena.

- [ ] **Verified type guards** — rather than trusting the annotation, verify that the function body actually performs checks consistent with the declared predicate. If the body provably returns true for non-T values, emit a warning. This is beyond TS — TS never verifies guards, it just trusts them. Even partial verification (detecting trivially lying guards) would be a win.

- [x] **Predicate narrowing from `type()` calls** — implemented in `narrow.lua` (extract_narrowing detects `type(x) == "string"` pattern; apply_narrowing filters union members). All forms: `type(x) == "string"`, `type(x) ~= "string"`, multi-branch, `any`, `unknown`.

- [x] **`assert()` as a built-in assertion** — `assert(x)` and `assert(x, msg)` both narrow `x` to non-nil/non-false in the continuation.

- [ ] **`for` loop variable narrowing** — `for _, v in pairs(t)` where `t: { [integer]: string | nil }` gives `v: string | nil`. `if v then` should narrow `v` to `string` inside the body for all use contexts (calls, assignments, table indexing). Currently narrowing applies to specific-function call arguments but NOT to: generic function args (e.g. `table.insert`), table index assignments (`t[k] = v`), or local variable declarations (`local x = v`). Root cause likely in how narrow.lua applies narrowed env at use sites — the narrowed type map isn't queried for these patterns. Concrete symptom: `lib/asm/ra.lua` `assignment` table must be `--: any` because `pairs(assignment)` returns `string | nil` values that fail to narrow in the callee_saves loop.

## typechecker warnings / quality-of-life

- [x] **Redundant type assertion warning** — implemented. `NODE_CAST_EXPR` emits a warning when a `--[[: T]]` cast asserts a structurally identical type; excludes `any` on either side.
- [x] **Error message quoting audit** — fixed in `unify.lua` (2026-03-30): 8 error strings used single quotes around type names; converted to backtick style. All type names in error messages now use backticks.

## typechecker narrowing gaps

- [x] **Optional field narrowing** — `if opts.f then opts.f(x) end` — FIXED (5da2138, 2026-04-10). `narrow_field_non_nil` now clears FLAG_OPTIONAL on the narrowed field entry so `solve_index` doesn't re-add nil inside the branch. Early-return pattern (`if not opts.f then return end`) also works.
- [x] **Variadic param ignored in function subtyping** — when a function had fewer fixed params than expected (or vice versa), the missing param fell back to `T_NIL` instead of the function's variadic type (`data[4]`). `(integer, string) -> boolean <: (...never) -> unknown` failed because at i=0 bpl=0 triggered T_NIL fallback instead of never. Fixed 2026-04-19 in unify.lua (both unify and try_unify): out-of-bounds param index now uses `fn.data[4]` (vararg type) if available, T_NIL only if no vararg. Same session: returns loop changed from `max(arl,brl)` to `brl` only — extra actual returns are ignored in Lua, not compared against nil.
- [ ] **Optional field calls not checked at call-site** — calling an optional field OUTSIDE a guard (`opts.f(x)` without any `if opts.f then`) currently produces no error, even though `f?: T` should make `opts.f` have type `T | nil` and nil is not callable. Requires `solve_index` to error on a non-callable union.
- [x] **`ffi.C` typed from file-local cdefs** — implemented via `$FfiC`. `ffi.C` resolves to `ctx.T_FFI_C`, a closed table accumulated from `ffi.cdef(...)` calls in the file. Undeclared C symbols are errors.
- [x] **`lib/js_types/init.lua` method convention** — stripped self-parameter from all 602 DOM method declarations (single-pass: `(TypeName)→()` before `(TypeName,rest)→(rest)`). `lib/web/html/init.lua` now declares `document = Document` instead of `any`. (62cb311)
- [x] **`lib/web/reactive_dom/` typechecker annotations** — annotated with `--:: require "lib.js_types"` + `--:: declare document = Document` + Signal/Computed/Lens/Prism/EventHandler/AttrMap/CleanupArray/KeyEntry/KeyMap type aliases. 12 irreducible errors remain (see typechecker missing features: no generics, unknown→concrete casts blocked, module type mangling for `?/init.lua` packages). All 63 reactive_dom_test.lua assertions still pass.
- [x] **lib/ljsocket type declarations** — added `--::` crescent annotations: `LjSocket`, `LjSocketAddrInfo`, `LjSocketModule`, `LjSocketFamily`, `LjSocketType`, `LjSocketProtocol` to `lib/ljsocket/init.lua`. Also added `local bit = require("bit")` and `--:: declare register_ffi_module`. 100 errors remain — all internal FFI implementation details (`ffi.new`/`ffi.cast`/`ffi.sizeof` overloads, `ljsocket_ffi` unknown via `generic_function` dynamic dispatch). The `http/server.lua` `client:send/close` errors require `lib/socket/server.lua` to also be annotated to return `LjSocket`.
- [ ] **Narrowing doesn't apply to locals assigned from function call returns** — at narrowing time during constraint generation, locals assigned from function calls are still TAG_VAR (unsolved constraint variables). `types.subtract(TAG_VAR, T_NIL)` returns TAG_VAR unchanged. Workaround: add `--: T | nil` annotation to the receiving local so it gets a concrete type. Affects all `if not x then return end` patterns where `x` comes from a function call.
  **Architecture investigation (2026-04-01):** Flow typing is not inference — separate concerns. Current narrowing is cleanly split: `extract_narrowing` (structural, pure) and `apply_narrowing` (type transformation). The multi-return mechanism (`propagate_multi_ret_narrowing`) already works as a post-solve pattern. Separation is feasible — narrowing is a scope-binding side effect, not core constraint logic.
  **Complication:** constraints from narrowed scopes reference the un-narrowed TAG_VAR. After solving, `?A = string | nil`. If narrowing would have given `string`, the constraint `?A:upper()` fails against `string | nil` but would have succeeded against `string`. This is NOT just conservative — it produces false errors. Constraints from narrowed scopes need the narrowed type, not the original.
  **Options:** (a) defer constraint generation inside narrowed scopes until after solving + narrowing — re-walk those AST nodes with concrete narrowed types. Closest to a clean two-pass but requires tracking which AST regions to re-process. (b) Emit constraints against TAG_VAR as now, post-solve apply narrowing, then re-verify only the constraints that reference narrowed variables. (c) Make narrowing a solver-integrated operation: when the solver resolves a TAG_VAR that has a pending narrowing, immediately apply the narrowing and update the scope binding before evaluating dependent constraints.
  **Current status:** needs design decision on which option before implementation.
- [x] **`or` condition narrowing overwrites previous narrowing for same variable** — `if not x or x == 0 then return end` failed to narrow `x` because the second `record_narrowing` call overwrote the first. Fixed: `record_narrowing` now chains through `narrowed[name_id]`.
- [x] **Multi-return annotation on single-var capture** — fixed in solve_sub: when actual is TAG_TUPLE and expected is scalar, project first element. Annotated `local x --: string; x = f()` where f returns (string, number) now type-checks correctly.
- [x] **Multi-return aliased-call narrowing** — `local find = string.find; local s, e = find(...)` didn't narrow after `if not s then return end` because `ExprRule[NODE_FIELD_EXPR]` returned a fresh TAG_VAR; `peek_callee_ret_union` found TAG_VAR instead of TAG_FUNCTION. Fixed: `ctx._var_origin[res]` populated in NODE_FIELD_EXPR; peek traces through it. Same for ASSIGN_STMT. Call-site contamination fixed by `call_uid` on each `_multi_ret` entry. `peek_callee_ret_union` now always wraps rl=1 returns in a 1-tuple so `eager_slot` always succeeds. (2026-03-29, commits 588f56d–e0980ac)
- [ ] **`eager_slot` out-of-range should be a type error** — `slot > 0` on a concrete single-value return currently silently binds to `nil` instead of emitting a diagnostic "function returns 1 value, cannot capture slot N". The two meanings of `eager_slot` returning nil ("not a tuple" vs "out of bounds") are conflated. Blocked on TAG_SPREAD (once returns are always explicit tuples, the check is trivial).
- [ ] **Generic function body checking via skolem variables** — generic function bodies are NOT checked at definition time (`constrain.lua:1369-1376`, explicit comment). A function annotated `--: <S, C, V>((S, C) -> V, S, C) -> () -> V` whose body returns a hardcoded `42` produces no error. All verification is deferred to call sites via `C_CALLABLE`. The correct fix: at definition time, instantiate the generic params as **skolem constants** (abstract types that the solver cannot bind — distinct from the per-call-site fresh TVs). Check the body against the skolems. Binding a skolem = type error. Benefits: (1) errors at definition not call site (QoL), (2) body checked once instead of reconsidered at every call site (performance — O(1) vs O(N calls)).
- [x] **Deferred arg checking for free-TV params** — when `<F: (A,B)->R, A, B, R>(f: F, a: A, b: B)->R` is called, `a: A` and `b: B` are free TVs at argument-checking time and absorb any arg type (no error for wrong types). Fixed in solve.lua: pre-scan in `solve_callable` detects when param 0 is a free TV and arg 0 is a function (indicating a pending C_BOUND back-propagation); binds F_fresh from arg 0, then returns false to defer A/B checking until C_BOUND fires and resolves them. Guard: only defers when param 0 is TAG_VAR AND arg 0 is TAG_FUNCTION — monomorphic functions (add(a,b)) are not deferred. Tests T6 (valid call, 0 errors), T7 (wrong first arg rejected), T8 (wrong second arg rejected) all pass. type_soundness_test.lua updated accordingly.
- [ ] **Union-of-tuples detection is shape-based** — `peek_callee_ret_union` distinguishes `string.find`-style multi-returns by checking whether ALL arms are TAG_TUPLE. This is a structural hack: any function returning a single-value-union-of-tuples will be misidentified as multi-return. Correct fix: explicit `-> ...((T, T) | (nil, string))` spread syntax (TAG_SPREAD). Until then, the hack survives but is known-unsound for the edge case. See TAG_SPREAD item in CRITICAL section.
- [x] **Optional field absence in structural assignment** — already works. `{x=1}` satisfies `{x: number, y?: number}` because unify.lua skips absent optional fields (line 470: `if band(bfe.flags, FLAG_OPTIONAL) == 0 then`).

## libraries needing rewrite from scratch

These exist in `lib/` but are legacy/stubs — not crescent-native (wrong annotation style,
no init.lua, no tests, incomplete, or just placeholder files). Do not rely on them as-is;
they need to be rewritten before use.

- [ ] **`lib/mud_cp/`** — MUD Client Protocol (moo.mud.org/mcp/mcp2.html). Stubs with FIXME/TODO throughout, wrong annotation style, no tests. Low priority; rewrite if/when MUD substrate needs it.
- [x] **`lib/github/`** — rewritten with crescent annotations and tests (9 assertions).
- [ ] **`lib/markdown/`** — `format.lua` (dead second parser attempt: undefined reader functions, unresolvable `dep.pretty_print`, infinite loop, crashed on require) deleted 2026-07-26. `init.lua` works and is tested (86 assertions in `markdown_test.lua`) but is intentionally not CommonMark-complete: no reference-style links, tables, nested lists, or strikethrough; no inline HTML spans; emphasis matching is regex-based rather than a proper delimiter-run algorithm, so it diverges from CommonMark on edge cases. User has more comprehensive plans for a fuller rewrite/extension later.
- [ ] **`lib/imap/`** — EmmyLua style, incomplete RFC 9051 parser, no init.lua, no tests. Low priority.
- [x] **`lib/wave/`** — rewritten with init.lua + wave_test.lua (32 assertions).
- [ ] **`lib/socket/`** — effectively a stub (client.lua is 1 line). Superseded by `lib/ljsocket` + `lib/tcp`. Can be deleted or left until needed.
- [ ] **`lib/https/`** — client.lua and init.lua done (callbacks on instance, receive added, per-request TLS context). serverx.lua deleted (was broken stub). Certificate verification still disabled by default.
- [ ] **`lib/posix/`** — 6-line execv/execlp stub. Absorb into `lib/process/` or expand when needed.

Not libraries (do not rewrite, repurpose instead):
- `lib/crescent_examples/` — collection of small scripts demonstrating crescent. Not a unified library.
- `lib/linux/` — raw OS FFI definitions. Keep as a definitions file, not a library.
- `lib/stdlib/` — compliance linter. Keep as a linter, not a library.

## near-term (next sessions)

- [ ] **`lib/asm/emit/arm64.lua`** — NEON machine code emitter. Same structure as `emit/x64.lua`
  but NEON encoding (A64 instruction format). Gate tests on `cpu.neon` (always true on arm64).
- [ ] **`lib/asm/` convenience wrapper** — `lib/asm/init.lua` single-call API:
  `asm.compile(kernel_fn, ctype)` → selects abi (cpu.arch), calls `ra.allocate`, calls `emit.compile`.
  Hides the ra/abi/emit wiring from callers.
- [x] **`lib/reactive/`** — signal primitives. See entry in future libraries section.
  Start point: `signal`, `computed`, `effect`, `batch`. Rainbow is the API reference.
- [x] **Fuzz suite gaps** — `docs/fuzz-gaps.md` fully done (all A/E/G/P tiers checked off).
- [x] **`Parameters<typeof f>` rest capture** — FIXED (see match semantics section above). fuzz_test.lua P2a/P2b pass.
- [ ] **Spread-union distribution** — `{ ...(A | B), k: V }` keeps a placeholder instead of
  distributing. Fix in `env.lua:substitute_inner`: distribute over union members, handle in
  `solve.lua` field lookup and `unify.lua`. Needed for builder pattern + mapped-type aliases.
- [ ] **Optional field narrowing** — `if opts.f then opts.f(x) end` still errors: second read
  of `opts.f` returns the union type, not narrowed non-nil. Workaround (extract to local) is
  known; real fix requires field-access narrowing in narrow.lua.
- [ ] **Narrowing for function-call return locals** — `local x = f(); if not x then return end`
  does not narrow `x` in the continuation because `x` is TAG_VAR at narrowing time. Three
  architectural options in TODO (a/b/c); needs a design decision before implementation.
- [x] **`$GlobalScope` documented** — added to permanent intrinsics list in `lib/type/static/CLAUDE.md`.
  Synthesizes a closed TAG_TABLE from all `--:: declare` globals; same pattern as `$FfiC` but for `_G`.
- [x] **`lib/bundle/`** — Lua module bundler. Resolve static requires, inline modules, single-file output. Circular dependency handling. 99 assertions.
- [x] **`lib/diff/`** — Myers diff algorithm: diff arrays/strings, unified format, patch, LCS. 96 assertions.
- [x] **`lib/csv/`** — RFC 4180 CSV parser/encoder: quoting, headers, streaming decoder. 135 assertions.
- [x] **`lib/embed/`** — Vector index/search on lib/vec: kNN, cosine/euclidean/dot, metadata filter, serialize. 112 assertions.
- [x] **`lib/graph/`** — Graph data structures + algorithms: BFS, DFS, Dijkstra, topological sort, SCC, cycle detection. 164 assertions.
- [x] **`lib/cache/`** — LRU cache with TTL, eviction callbacks, injectable clock, resize. 102 assertions.
- [x] **`lib/validate/`** — Schema validation for Lua tables: composable validators, records, arrays, combinators. 193 assertions.
- [x] **`lib/stream/`** — Lazy iterator combinators: map, filter, reduce, take, zip, flat_map, chunks, etc. 120 assertions.
- [x] **`lib/color/`** — Color manipulation: RGB/HSL/HSV/hex conversion, lighten/darken/mix, WCAG contrast. 198 assertions.
- [x] **`lib/cron/`** — Cron expression parser: matches, next/prev scheduling, shorthands, describe. 185 assertions.
- [x] **`lib/fsm/`** — Finite state machine: declarative transitions, guards, actions, wildcards, history. 125 assertions.
- [x] **`lib/heap/`** — Binary heap/priority queue: min/max/custom, heap sort, merge, keyed mode. 615 assertions.
- [x] **`lib/set/`** — Mathematical set: union, intersection, difference, symmetric difference, subset/superset. 108 assertions.
- [x] **`lib/ringbuf/`** — Fixed-size ring buffer: O(1) push/pop both ends, overflow wrapping. 111 assertions.
- [x] **`lib/trie/`** — Prefix tree: autocomplete, longest prefix match, prefix counting. 108 assertions.
- [x] **`lib/glob/`** — Glob pattern matching: *, **, ?, [...], {a,b}, compile/match/filter. 151 assertions.
- [x] **`lib/matrix/`** — 2D matrix math: arithmetic, transpose, determinant, inverse, solve Ax=b, Gaussian elimination. 169 assertions.
- [x] **`lib/bits/`** — Bitset + Bloom filter: set/clear/toggle, popcount, set operations, FNV-1a hashing. 157 assertions.
- [x] **`lib/promise/`** — Promises/A+: resolve/reject, and_then/catch/finally, all/race/any/all_settled. 92 assertions.
- [x] **`lib/interval/`** — Interval arithmetic + tree: contains, overlaps, merge, gaps, point/overlap queries. 110 assertions.
- [x] **`lib/deque/`** — Growable double-ended queue: O(1) push/pop both ends, rotate, iterate. 1160 assertions.
- [x] **`lib/bigint/`** — Arbitrary precision integers: base 10^7, add/sub/mul/div/pow, GCD/LCM, hex. 172 assertions.
- [x] **`lib/router/`** — Radix tree URL router: :params, *wildcards, method dispatch, groups. 158 assertions.
- [x] **`lib/retry/`** — Retry with backoff (none/linear/exponential/fibonacci) + circuit breaker. 177 assertions.
- [x] **`lib/base64/`** — Base64 encode/decode (RFC 4648), URL-safe variant. 145 assertions.
- [x] **`lib/event/`** — Event emitter: on/once/off, wildcards, priority, stop propagation, mixin. 107 assertions.
- [x] **`lib/ini/`** — INI parser/encoder: sections, comments, quoted values, multiline. 90 assertions.
- [x] **`lib/pool/`** — Object pool: acquire/release, health checks, with(), buffer pool. 117 assertions.
- [x] **`lib/schema/`** — Database DDL migration DSL: create/alter/drop table, column types, constraints, indexes. 137 assertions.
- [x] **`lib/mime/`** — MIME type lookup: 120+ types, extension↔type, charset, content_type. 102 assertions.
- [x] **`lib/url/`** — URL parser/builder: RFC 3986, query strings, percent-encoding, resolve, normalize. 152 assertions.
- [x] **`lib/template/`** — String template engine: {{ expr }}, {% code %}, {# comment #}, filters, compile. 100 assertions.
- [x] **`lib/ratelimit/`** — Rate limiting: token bucket, sliding/fixed window, leaky bucket, per-key. 367 assertions.
- [x] **`lib/i18n/`** — Internationalization: translations, interpolation, pluralization, locale fallback. 85 assertions.
- [x] **`lib/codec/`** — Codec composition: chain, conditional, map, hex/rot13/xor built-ins. 103 assertions.
- [x] **`lib/observable/`** — Reactive streams: operators (map/filter/take/flat_map), subjects, combinators. 510 assertions.

## lib/asm — SIMD kernel compiler

- [x] `lib/asm/cpu.lua` — CPU feature detection (sse2/avx/avx2/neon, arch)
- [x] `lib/asm/ra.lua` — linear scan register allocator with aliasing model (51 assertions)
- [x] `lib/asm/ir.lua` — virtual register IR builder, live interval computation, loop backedge extension
- [x] `lib/asm/abi/x64.lua` — SysV AMD64 + Win64 register files (407 assertions)
- [x] `lib/asm/abi/arm64.lua` — AAPCS64 register file
- [x] `lib/asm/emit/x64.lua` — x86-64 machine code emitter: VEX-encoded AVX instructions,
  mmap executable memory, full vmulps/vaddps/vsubps/vdivps/vfmadd213ps + loop (27 assertions, AVX-gated)
- [ ] **`lib/asm/emit/x64.lua` — `insn.dst` nil safety** — `Insn.dst` is `VReg | nil` (nil for store/ret ops), but load/arith branches unconditionally access `insn.dst.id` and `.type`. Requires either runtime nil guard or opcode-specific Insn subtypes. Exposed by replacing `--: any` with `--: Insn`.
- [ ] **`lib/asm/emit/x64.lua` — `ffi.copy` string-source overload** — `alloc_exec_mem` calls `ffi.copy(ptr, code_str, n)` with a Lua string as src. stdlib_types.lua only declares the `(Ptr<T>, Ptr<U>, integer)` form; missing `(Ptr<T>, string, integer)` overload (LuaJIT special-cases string src). Causes false positive type error at call site.
- [ ] `lib/asm/emit/arm64.lua` — NEON emitter (A64 encoding)
- [x] `lib/asm/init.lua` — convenience wrapper: `asm.compile({args,ret,ctype}, build_fn)`. Selects abi+emit by jit.arch; supports x64 (sysv/win64). 28 assertions in asm_test.lua.

## lib/stb — image decode/resize (vendored stb)

- [x] Package scaffold: tier selection (vendored > system-vips > pure-lua), `lib/stb/init.lua`, `lib/stb/ffi.lua`, `lib/stb/pure/resize.lua` (nearest-neighbor, full), `lib/stb/pure/image.lua` (PNG stub), `lib/stb/build.lua`, `lib/stb/src/README.md`, `lib/stb/stb_test.lua` (80 assertions)
- [ ] Download stb headers and compile vendored binaries for all 5 platforms via CI (`lib/stb/build.lua`)
- [ ] Implement pure Lua PNG decoder in `lib/png/` and wire into `lib/stb/pure/image.lua`
- [ ] Implement system-vips decode/resize wrappers in `lib/stb/init.lua` try_system_vips()
- [ ] Parity tests: vendored vs pure-lua resize on random pixel buffers (identical output)
- [ ] Benchmarks: vendored stbir vs pure-lua nearest-neighbor; record in `docs/perf/log.md`

## future libraries

See `docs/batteries.md` for the full ecosystem scope. Key entries below; batteries.md is authoritative.

- [x] **`lib/taskgraph/`** — implemented: graph.lua, context.lua, exec.lua, combinators.lua (map/retry/refine), init.lua, executor/ai.lua, orchestration_test.lua (27 assertions).
- [x] **`lib/cli/`** — arg-parsing library. Declarative spec API: flags, options, positionals, subcommands, type coercion, auto-help/version, shell completions. 70 assertions.
- [x] **`lib/datetime/`** — date/time parsing, formatting, arithmetic. ISO 8601, Unix timestamps, offset-aware arithmetic. 186 assertions (c6e9bbb).
- [x] **`lib/regex/`** — PCRE2 FFI system tier + pure Lua backtracking fallback. compile/match/find/gmatch/gsub/split. 70+ assertions.
- [x] **`lib/uuid/`** — UUID v4/v7 generation. v4 (random), v7 (timestamp+monotonic). FFI tiers: getrandom → arc4random_buf → /dev/urandom → pure. 250 assertions.
- [x] **`lib/log/`** — structured logging with levels and sinks. log.new(), collect_sink, file_sink, stderr/stdout_sink, text/json/ansi formats, child loggers, set_level, add/remove sink. 80 assertions.
- [x] **`lib/compress/`** — zlib/gzip via FFI (system tier) + pure Lua inflate (RFC 1951). Two tiers: system-zlib (full deflate+inflate) and pure-lua (inflate only). Streaming and one-shot APIs. 24 assertions.
  - [x] **Pure Lua inflate parity bug** — FIXED (0989bb7). decode_symbol was building Huffman codes MSB-first but build_tree stores reversed codes. Fixed to accumulate bits LSB-first. 181 assertions now passing.
- [x] **`lib/ansi/`** — ANSI escape codes (colours, cursor movement). Foundation for `lib/tui/`.
- [x] **`lib/tui/`** — TUI widget layer (boxes, tables, input fields).
- [x] **`lib/reactive/`** — reactive signal primitives. Push-based, no implicit tracking scheduler.
  Core API: `signal(init)` → `{get, set, update}`, `computed(fn, deps)`, `effect(fn)`, `batch(fn)`.
  No dependencies outside crescent — not even on Rainbow.
  **Rainbow** (`~/git/rhizone/rainbow/`) is a parallel TypeScript implementation of the same algebra,
  maintained separately. It defines the intended API surface and semantics (`Signal<A>`, `computed()`,
  `cond()`, `batch()`, `product()`, `stateful()`). The Lua and TS implementations are peers —
  neither depends on the other. `lib/lua2ts/` can transpile this to standalone TS that is
  API-compatible with Rainbow but does not import from it.
  **Done**: dccd023. signal/computed/effect/batch/focused/narrowed. 56 assertions.

- [x] **`lib/reactive_optics/`** — signals focused through optics. `signal:focus(lens)` produces a
  derived signal that reads/writes structurally; lens laws (get-set, set-get, set-set) guarantee
  state consistency by construction. Combines `lib/reactive/` with `lib/fp/optics/` (already built).
  Key combinator: `focus(signal, optic)` → `{get(), set(v), update(fn)}`.
  Parallel TS implementation: Rainbow's optics layer (`~/git/rhizone/rainbow/src/optics/`).
  Again: no dependency on Rainbow — same algebra, separate codebases.
  **Done**: dccd023. field/compose_focus/focus/narrow. 9 assertions.
- [x] **`lib/ml/`** — ML vertical: `lib/xgboost` (pure Lua reference + FFI).
- [x] **`lib/knn/`** — k-nearest neighbors with euclidean/cosine/manhattan distance, classification, regression. 55 assertions.
- [x] **`lib/tfidf/`** — TF-IDF text scoring, cosine similarity, corpus search, keyword extraction. 61 assertions.
- [x] **`lib/search/`** — FTS5 full-text + vector similarity + hybrid search on SQLite. 65 assertions.
- [x] **`lib/email/`** — email composition (RFC 5322 MIME) + SMTP client with mock transport. 71 assertions.
- [x] **`lib/realtime/`** — pub/sub hub, presence tracking, event store with aggregation. 83 assertions.
- [x] **`lib/vec/`** — dense vector math with FFI and pure Lua tiers. 192 assertions.
- [x] **`lib/web/`** — web application framework: middleware, routing, cookies, CORS, CSRF, static files. 56 assertions.
- [x] **`lib/auth/`** — JWT (HS256), PBKDF2-SHA256 password hashing, token generation, HMAC-SHA256. 44 assertions.
- [x] **`lib/queue/`** — SQLite-backed task queue with priority, delay, retry, scheduling, dead-letter. 69 assertions.
- [x] **`lib/taskgraph` frontier/exec_graph/scaffolds** — absorbed from nanites design. Dynamic graph growth, frontier (live pending set, opt-in via `track=true`), exec_graph (monotonic audit log), scaffolds (pre-execution hooks). 53 assertions. Parallel LLM dispatch still needs epoll-backed HTTP (see entry above); vLLM integration (`caps.llm` → local vLLM OpenAI-compatible API) is a follow-on. Reference: `~/git/rhizone/nanites/`.

## Agent infrastructure

- [x] **`lib/exec/`** — subprocess runner (`exec.run`/`exec.run_ex`), `--help` parser
  (`lib/exec/help.lua`), identifier normalizer (`lib/exec/ident.lua`). HelpSchema produced
  by `help.fetch` or `help.parse`. Done.

- [ ] **`lib/exec/make_api`** — fluent typed API generator from HelpSchema. See `docs/exec-api-design.md`.
  Inputs: HelpSchema + cmd name + opts (`popen` injected). Outputs: `api_table` + `--::` decls string.
  Node shapes via bitflags (`CALLABLE=0x1`, `HAS_SUBCOMMANDS=0x2`). "Both" nodes use `#__call` metamethod.
  Flag expansion: named table `{json=true, limit=5}` → CLI arg strings. Depends on: `lib/exec/help`,
  `lib/exec/ident` (done). File: `lib/exec/make_api.lua`.

- [ ] **`lib/agent/` substrate** — context set, render, curated leaf executor, preset registry.
  See `docs/agent-impl.md` Section 1. Depends on: `lib/taskgraph` (done).
  Key invariant: set is re-rendered fresh each LLM call; raw tool output never accumulates.
  Files: `lib/agent/set.lua`, `lib/agent/render.lua`, `lib/agent/leaf.lua`, `lib/agent/preset.lua`.

- [ ] **`caps.exec`** — `lib/platform/caps/exec.lua` exists (popen injection removed this session) but is NOT wired into CAP_FACTORIES in `lib/platform/init.lua`. Adding it to CAP_FACTORIES is the remaining step.
  See `docs/agent-impl.md` Section 2. Depends on: `lib/exec/make_api`, `lib/platform/caps/` pattern.
  Construction auto-fetches `--help` per binary; grant precision via `allow` list restricts to specific subcommand paths.

- [ ] **`caps.llm`** — platform cap for grammar-constrained LLM generation via llama.cpp.
  See `docs/agent-impl.md` Section 3. Depends on: `lib/ai/providers/openai_compat` (done).
  File: `lib/platform/caps/llm.lua`. Endpoint: `http://127.0.0.1:8081` default. `response_format`
  JSON schema mode for structured output; response validated before returning.

- [ ] **First narrow agent app** — **priority: medium-high**. Full infrastructure stack is
  now in place (`lib/exec/`, `lib/agent/`, `caps.exec`, `caps.llm` all done) — this is a
  pure implementation task, no blockers.
  Candidate: polish-agent (parallel audit lenses, structured findings, POLISH.md artifact,
  human-as-decision-node). See `docs/agent-design.md` for thesis and design constraints.
  Success criteria from design doc: narrow app under 200 lines of Lua, useful output on small
  local model, audit trail = `exec_graph` snapshot + tarball hash.

- [ ] **`lib/protocol/capnp`** — zero-copy binary serialization via Cap'n Proto. Wire format reader + writer using LuaJIT FFI (fixed-width fields + typed pointers → direct buffer casting, near-zero allocation). Pure reader first; `.capnp` schema parser deferred (hand-write schemas as Lua tables initially). RPC layer (`lib/capnprpc`) separate. Moderately high priority — genuine capability gap over JSON/CBOR for high-throughput IPC.
- [x] **`lib/ukanren/`** — microKanren port. Goals, unification, streams, fair interleaving. 52 assertions.
- [x] **`lib/datalog/`** — pure Lua Datalog engine, naive bottom-up evaluation, recursive rules, guards. 87 assertions.
- [x] **`lib/crypto/`** — AES-256-GCM (system libcrypto FFI), ChaCha20-Poly1305 (system + pure Lua), HKDF-SHA256, random_bytes. 36 assertions + 10 skipped (AES without libcrypto).
- [x] **`lib/openapi/`** — OpenAPI 3.x parser, $ref resolution, request/response validation, JSON Schema subset, lib/web router integration. 111 assertions.
- [x] **`lib/parse/`** — parser combinators: literal, pattern, seq, alt, many, opt, map, sep_by, lazy, whitespace, number, string, ident. 92 assertions.
- [ ] **`lib/ir/`** — compiler intermediate representation (not yet implemented).
- [x] **`lib/asm/`** — SIMD kernel compiler: cpu detection, linear scan RA, virtual IR, x64 emitter. See `## lib/asm` section above.

- [x] **`lib/lua2ts/`** — Lua → TypeScript transpiler. The typechecker already builds an AST;
  emitting TS syntax instead of Lua syntax is mostly mechanical. Prior art: `dep/lua2js.lua`
  (AST printer that outputs JS syntax). Metatables are the awkward mapping; FFI doesn't cross.
  Crescent's type annotations map directly to TS types — typed Lua → typed TS with no extra
  annotation work. Primary use case: write `lib/reactive_optics/` logic in Lua, emit typed TS,
  run in browser alongside Rainbow components. Rainbow (`~/git/rhizone/rainbow/`) is the
  deployment target — `lib/lua2ts/` output is designed to compose with Rainbow's signal/optics layer.

- [x] **`lib/lua2ts/`: `__index = table` metatable → TS class** — top-level `local M = {}` +
  `M.__index = M` → `class M { ... }`. Handles `setmetatable({}, M)` and
  `setmetatable({}, { __index = M })` constructor variants. Instance methods (`function M:f()`
  and `function M.f(self, ...)`), static methods, and `function M.new(...)` constructor.
  Emits `const self = this;` preamble so method bodies work without rewriting identifiers.

- [ ] **`lib/lua2ts/`: OOP patterns not yet translated** (known limitations):
  - `__index = function(t, k)` — dynamic indexer; would need JS `Proxy`. Currently emitted as-is.
  - Inheritance: `setmetatable(Child, { __index = Parent })` at module level (not in `new`).
    Would need `class Child extends Parent`. Not yet detected.
  - `M.__index = M` where M is NOT a local `{}` declaration (e.g., assigned via `require`).
    Not detected; passes through unchanged.
  - Multiple return from constructor beyond `return self` (e.g., `return self, err`).
    The `return self` skip only triggers for single-value returns of `self`.
  - Method bodies are given `const self = this;` but `self` in nested closures inside methods
    will capture the `const self`, not the outer `this` — correct for Lua semantics.

- [x] **`lib/jsonrpc/`** — request/response dispatch over stdio or TCP. Substrate for LSP, Model Context Protocol, and any JSON-RPC protocol. Transport abstraction, method registry, typed handler registration. (1d4f85e)

- [x] **`lib/lsp/`** — LSP method bindings on top of `lib/jsonrpc`. Server builder with `on_*` registration, auto-capability detection, lifecycle handling. Covers: initialize, hover, completion, definition, references, documentSymbol, signatureHelp, formatting, rename, codeAction, diagnostic, text sync. 60 assertions.

- [x] **`lib/mcp/`** — Model Context Protocol server on top of `lib/jsonrpc`. Tool/resource/prompt registration, capability negotiation, logging with level filtering, completions. 44 assertions.

- [ ] **`lib/ecs/`** — entity-component substrate. Named entities, typed components, spatial containment (entities inside entities), mutable state store. User-defined schemas — no hardcoded concepts like "room" or "inventory". The primitive for building world simulations, games, or any entity-centric stateful system. Turn loop, perception rules, mutation rules, and renderers (RP prose, MUD-style, etc.) are built on top by the user.

## typechecker type-level features (designed this session, needs implementation)

- [x] **`$EachField<T, F>` intrinsic** — flatMap semantics implemented (fbb00f5, 2026-03-30).
  F returns a brace-tuple: `{}` = drop, `{ D }` = keep/transform, `{ D1, D2 }` = expand.
  Detection: empty TAG_TABLE → drop; positional-indexer TAG_TABLE → multi-element tuple;
  anything else → backward-compat single-descriptor. Grammar gap fixed (124c438):
  `{ { optional: true, ...Rest } }` now parses — root cause was `else break` in the
  field loop not handling `{`-started positional entries. `...Rest` splice already
  worked. `MakeOptional`, `MakeReadonly`, `DropOptional`, `Partial<T>` all tested.

- [x] **Interface declaration syntax `--:: Name: Base`** — implemented (551cbdb, 2026-03-30).
  `--:: Name<T>: Constraint<T> = body`: (1) checks `body <: Constraint<T>` at definition,
  emits E.CONSTRAINT_MISMATCH = 26 on failure; (2) registers ctx.declared_subtypes oracle
  so try_unify(Name<X>, Constraint<X>) short-circuits in O(1). ann.lua parses `: Constraint`
  before `=`; constrain.lua resolves + registers + checks; unify.lua oracle-first for TAG_NAMED pairs.

- [x] **Partial application of generic aliases** — implemented (22f1e8f, 2026-03-30). TAG_PARTIAL_APP = 31.
  Under-arity alias call (1–N-1 args) returns TAG_PARTIAL_APP(name_id, partial_args).
  apply_type_fn completes the call. substitute_inner re-evaluates when args become concrete.
  match.lua TAG_UNION pattern added (needed for `match K { Keys => ... }` where Keys is a union).
  Enables Pick<T, Keys> and Omit<T, Keys> via $EachField + PickKey<Keys> partial app.

- [x] **`{ ...[%K]: %V }` table-pattern rest capture** — `{ field: %X, ...%Rest }` in
  match patterns: captures remaining fields into Rest; `...Rest` in result splices them
  back. Specced in docs/capture-sigil-spec.md. Needed for $EachField F aliases.
  Implementation: ann.lua + match.lua. Done 2026-03-30.

- [x] **`(...%P) -> T` and `(A, ...%P) -> T` param captures** — specced in
  docs/capture-sigil-spec.md. Enables Parameters<F>, Tail<F>, Last<F>, Init<F>.
  At most one `...%P` per param list, may appear anywhere. Implementation: ann.lua +
  match.lua. Done 2026-03-30.

- [x] **`{ #...%M }` meta-slot spread** — specced in docs/meta-spread-spec.md.
  `setmetatable = <T, MT>(t: T, mt: MT) -> T & { #...MT }`. `MetaOf<T>` alias.
  Implementation: ann.lua + match.lua + types.lua + constrain.lua + env.lua + defs.lua.
  Done 2026-03-30.

- [ ] **Literal type ops** — see docs/literal-type-ops-spec.md. Conclusion: none needed
  now. Implement on demand. Boolean ops expressible as match aliases (no primitives needed).
  String `..` has no crescent use case (JS-heritage motivation doesn't apply). `#tuple`
  and `LIT_INTEGER` arithmetic have no concrete use cases yet.

## priorities (medium horizon)

- [ ] **Registry + docs site** (`pkg.crescent.run`) — see `docs/registry-design.md` for full vision.
  Key pieces: static JSON index (GitHub Pages), install fetches from GitHub releases directly,
  no server required. Docs site renders auto-generated type signatures from typechecker output.
  Uniquely: **Hoogle-style type search** — parse a query type annotation, unify against every
  exported binding in the index using the existing unify.lua engine. The hard part (type inference)
  is already done. Three sub-projects:
  - [x] Docgen tool (`lib/doc/`) — extract `---` doc comments + inferred types → JSON/Markdown.
    `doc.generate(file)` / `doc.generate_string(src)` / `doc.generate_package(dir)`.
    CLI: `luajit lib/doc/cli.lua [--format json|text|markdown] [--package dir] <file>...`
    Filters `_`-prefixed exports, extracts parameter names, batch mode.
  - [x] Type search library (`lib/type/search/`) — Hoogle-style: parse query type annotation,
    unify against exports using try_unify. `search.build_index(files)` / `search.query(type_str, index)`.
    CLI: `luajit lib/type/search/cli.lua "(string) -> string" <files...>`
  - [ ] Type search improvements:
    - Unseal mode (`{ unseal = true }`) — search through $Opaque wrappers
    - Opaque pattern queries — `$Opaque<string>` means "any opaque wrapping string"
    - Accept type_id + ctx as query (programmatic, not just strings)
    - Acceleration structures for registry-scale indexes (bloom filter, inverted index)
    - [x] Subtype ranking (exact > subtype > supertype) — 3-level scoring
    - [x] Arity pre-filtering before check_string
    - [x] Persistent index — save_index/load_index JSON, CLI --save-index/--load-index
  - [x] Stabilise `--dump` output as machine-readable JSON (exported bindings + type sigs) — `--dump --format json` emits `[{file, bindings:[{name,type}], return}]`; M.dump_one/dump_json testable exports (edaaf6f)
  - [ ] Static docs site — renders docgen JSON; search calls type-search endpoint or
    runs unification client-side. **Medium priority: replace bun with crescent-native
    markdown renderer** (`lib/markdown/` once complete) so the docs toolchain is
    self-hosted. bun is the current placeholder; it should not be a permanent dep.
  - [ ] GitHub Action — on release tag: run typechecker + docgen, publish JSON to index.
  - [ ] `cr add <name>` — resolve short name via index.json, fetch GitHub release tarball,
    extract to `dep/<name>/`, resolve transitive deps.

- [ ] **Test runner performance** — benchmark against bun; must be at parity or better.
  Current runner shells out to `find` + `sort`, then `dofile`s each file sequentially.
  Profile first: startup cost, require() overhead, per-file execution. Candidates:
  native file discovery (FFI readdir), parallel execution (fork + collect), preloaded
  module cache, LuaJIT JIT warm-up tuning. Target: same program runs comparably fast
  in bun and luajit; if not, the design needs revisiting.

- [x] **Package manager** (`lib/pkg/`) — core implementation done. See design docs for full detail.
  - [x] semver, manifest, lockfile, install (resolve/fetch/hardlink), config, CLI (install/add/remove/update/info/publish/eject/diff)
  - [x] Transitive dep resolution (BFS, cycle detection, diamond dedup)
  - [x] Version conflict detection (two-pass MVS resolver, constraint collection)
  - [x] `dep/` → `lib/` migration; lockfile v2 (include, tarball_hash, tree_hash)
  - [x] Include glob filtering + union merge across dependents
  - [x] Tree hash verification + local modification detection
  - [x] `cr diff`, `cr eject`, `cr update --merge`
  - [x] Pure Lua three-way merge (`lib/merge3/`) — Myers diff, no external deps
  - [ ] **Phantom dep linting** — `cr check`/`cr publish` scans require paths vs own `pkg.lua`
  - [ ] **Parallel fetch** (`--jobs`) — fork-based, I/O-bound, significant on large dep trees
  - [ ] **Workspaces** — single `crescent.lock` covering all packages in a monorepo; MVS resolver takes union of all workspace `pkg.lua` roots
  - [ ] **Lockfile format freeze** — add `lockfile_version` field, stabilise before v1 registry use
  - [ ] **`cr add` / `cr publish`** — blocked on live registry infrastructure

- [ ] **Typechecker** — large ongoing backlog; dedicated sessions welcome.
  Near-term candidates: access control design (see below), module-level LSP cache.
  (Variance was demoted from soundness to expressiveness, commit `ca64aeb1`; see
  `docs/typechecker-variance.md` and the variance entry below.) See typechecker
  section below for full list.
  - [x] **Overload checking against body** — implemented: `collect_preceding_run` in
    constrain.lua accumulates consecutive `--:` annotations into intersection types;
    `check_body_against_intersection` runs N inference passes (one per overload member).

- [ ] **Stdlib rewrites** — vendored packages currently in `lib/` violate the ownership
  rule (docs/stdlib-design.md). Each needs a fresh crescent-native rewrite before the
  registry exists and the vendored copy can be removed:
  - [x] `lib/format/json/` — crescent-native JSON, three tiers (pure/ffi/simd stub).
    Parity tests + benchmarks done. pure: 72 MB/s, ffi: ~same. See docs/perf/log.md.
  - [ ] `lib/format/json_sax/` — SAX + zerocopy variant (separate library, different interface).
    Design: `scan(src, cb(key,val))` and `scan_pos(src, cb(ks,ke,vs,ve))`. Pure tier only
    (no table alloc = no bottleneck to tier away). Benchmarked: 247 ns / 254 MB/s (SAX) and
    155 ns / 405 MB/s (zerocopy) on 90B object — 2.1x faster than Node.js JSON.parse.
    Implement when HTTP layer needs streaming/large JSON parsing. Design notes: docs/perf/log.md.
  - [ ] `lib/format/cbor/` — rewrite vendored CBOR. Low priority until cbor sees more use.
  - [x] `lib/encode/base64/` — rewritten. Three-tier (simd stub > ffi > pure), RFC 4648 §4+§5, 108-line tests.
  - [ ] `lib/hash/sha1/` — rewrite mpeterv/sha1. Already heavily patched; sha256 shows
    the tiered pattern to follow.
  - [ ] `lib/ljsocket/` — largest and most complex. Blocked on registry (http/websocket
    depend on it); rewrite as cross-platform `lib/socket/` (POSIX + winsock via FFI).
  - [x] `lib/cparser/`, `lib/cmark/`, `lib/plterm/` + `lib/crescent_examples/ple.lua` — deleted (unused vendored code).

- [ ] **Stdlib buildout** — see `docs/stdlib-roadmap.md`. Phase 1–3 done (2026-03-20):
  path guards, init.lua entry points, error convention sweep, tests for core packages,
  new packages (process, iter, rand, signal, format/msgpack, format/toml, hash/hmac).
  46 app-specific packages archived. Remaining: dep.* coupling resolution, type
  annotations across Tier A (done for 24 owned packages; vendored code skipped),
  tests for ljsocket/tls/dns/inotify.
  [x] dep.* coupling resolved (a79167d) — 8 dep paths across 28 files updated.
  [x] HTML docgen output (582247c) — `--format html` with inline CSS.

- [x] **Typechecker: multiline `--::` declarations** — lexer now concatenates
  continuation `--::` lines when brackets are unbalanced. Forward references between
  `--::` types in the same file work via the existing two-pass design.
  **Note**: multi-return function types in record fields must use parens:
  `generate: (req: T) -> (R?, string?)` not `-> R?, string?` (comma is ambiguous
  with field separator).

- [ ] **Typechecker: annotation parser multi-return in record fields** — bare
  `-> R?, string?` inside `{ ... }` is ambiguous (`,` could be field separator or
  multi-return separator). Workaround: parenthesize returns `-> (R?, string?)`.
  Could fix by parsing return types greedily until `,` followed by an identifier + `:`.

- [x] **Typechecker: type-level imports** — `--:: require "path"` (ANN_REQUIRE) is the
  mechanism: it loads all `--::` declarations from the referenced file into the current
  file's scope. Already implemented and in active use by lib/taskgraph/, lib/asm/,
  lib/web/, and others. No separate `--:: import` syntax is needed.

- [ ] **Shared cap function types library** — common injected-function signatures repeated
  across libs (`POpenFn`, `IOOpenFn`, `RemoveFn`, `TmpnameFn`, `ReadFn`, etc.) should
  live in one place (e.g. `lib/caps/types.lua`) declared with `--::`, imported via
  `--:: require "lib.caps.types"`. Eliminates per-file repetition and keeps cap
  signatures consistent across the codebase.

- [ ] **Type annotation syntax docs** — no public-facing `docs/type-syntax.md` exists.
  `docs/conventions.md` mentions `--:` / `--::` exist but doesn't document them.
  Need: complete syntax reference (primitives, unions, intersections, generics, tuples,
  function types, `--:: require`, `--:: declare`, intrinsics like `$Opaque`/`$Values`).
  Include: known limitations, examples.

- [ ] **Type docs staleness detection** — script that compares `git log` date of
  `docs/type-syntax.md` (once it exists) against latest commit touching
  `lib/type/static/`. Run in CI or as a pre-commit hook to catch silent doc drift.

- [ ] **Typechecker: nested generic alias application** — `Partial<Partial<T>>`
  produces `never` even though `Partial<{a: string|nil}>` (the inner result)
  works fine directly. The bug is in how a generic alias application passes its
  result as the type argument to an outer alias application. Manifests with any
  two-level `$EachField` composition. Discovered via type_complex_test.lua.

- [ ] **Typechecker: recursive structural type checking** — `{ head=1, tail=99 }`
  is accepted where `List<number>` (tail must be `List<number>?`) is expected.
  The recursive field constraint is not enforced at depth. Likely the unification
  of the recursive type hits the cycle guard before checking the concrete field.

- [ ] **Runtime type validator** (`lib/type/runtime/`) — Zod/Typebox/Arktype-style
  schema library: `T.string()`, `T.number()`, `T.object({...})`, `T.union([...])`,
  `T.array(T.string())`. Returns a validator function `(value) -> true | nil, err`.
  Pure Lua, no codegen. Key design: validators compose via the same combinators as
  the static type system. Long-term: static typechecker infers validator types so
  `local x = T.string():parse(v)` gives `x: string` after the call.

- [ ] **Typeclass dispatch key pattern** — `lib/fp/` dispatch tables annotated `{ [any]: any }` today.
  Correct design: each typeclass module exposes a `.key` field declared `--:: FooKey: $Opaque`,
  dispatch table annotated `{ [FooKey]: FooImpl, [BarKey]: BarImpl, ... }`, and
  `fa[Mappable.key]` in code resolves via the existing FLAG_OPAQUE_KEY mechanism keyed by
  the nominal `$Opaque` type instead of just the variable name string. Requires:
  (1) `$Opaque` declaration in each typeclass module (mappable, applicable, etc.),
  (2) cross-file type alias resolution in bracket-key annotation position already works
  via the existing FLAG_OPAQUE_KEY + LIT_OPAQUE_KEY path once the key IS a declared type.
  Eliminates `{ [any]: any }` from fp dispatch tables.

- [x] **Typechecker: table-valued dispatch key (GAP-HKT3)** — applied to all lib/fp/ typeclass and instance modules. `fa[Mappable.key]` resolves via FLAG_OPAQUE_KEY to the instance type. Callers annotate parameters with `{ [MappableKey]: { map: ... } }` for type-checked dispatch. (2026-03-29, 839610f)

- [x] **Typechecker: argument literal widening** — implemented in `solve.lua` (`widen_literal` applied at typevar binding; `ret_uses_tv_in_intrinsic` exempts `$Require<T>` to preserve string literal for module lookup). Confirmed: `id(0); id(1)` and `id(0); id('x')` both work.

- [ ] **Refinement types / control-flow narrowing system** — type guards, assertions, and
  `type()` narrowing are all instances of a general `refine_true`/`refine_false` algebra.
  Needed: (1) `assert(e)` narrows after the call (`x: T` in continuation); (2) `x is T`
  return type syntax for bool guards — checker *verifies* body, unlike TS which trusts;
  (3) `asserts x is T` return type for void assertions; (4) `T & asserts x is T` for
  functions that both return a value AND narrow a parameter (TS cannot express this);
  (5) `and`/`or`/`not` compose refinements automatically; (6) `getmetatable(x) == MT`
  narrows to MT's registered type; (7) exhaustiveness on `if type(x) == ...` chains.
  Design doc: `docs/type-system.md` § "Refinement types: the general system".

- [ ] **Difference types `T \ U`** — false branch of any narrowing produces `T \ U`, not
  open `~T`. Expressible as `Exclude<T, U> = match T { U => never, _ => T }`. Standalone
  `~T` only valid within Lua's closed `type()` universe (8 known values). Implement as
  false-branch refinement in constrain.lua + `Exclude` in the type prelude.

- [ ] **Type operations standard library** — `docs/type-system.md` § "Type operations are
  library aliases". Ship in prelude: `Exclude`, `Extract`, `NonNil`, `ReturnType`,
  `ElemType`, `UnwrapMaybe`, `Flatten`, `Partial`, `Required`, `Pick`, `Omit`.
  All expressible as `--::` aliases over `match` — no new compiler intrinsics needed.

- [ ] **Typechecker: HKT type argument extraction** — when `<F, A>(fa: F<A>)` is called
  with `Maybe<number>`, the solver can't extract `F = Maybe, A = number` from the
  expanded structural type. Once expanded, constructor/argument decomposition is lost.
  Constraints like `<F, A: Semigroup>(fa: F<A>)` are unenforceable — `A` is unbound.
  Blocks: typed `fmap`, typeclass-polymorphic functions, `lib/fp/` full type safety.
  Fix requires nominal type preservation or bidirectional inference before expansion.
  See `docs/type-system.md` line 862.
  **GAP-HKT1 (found 2026-03-29)**: chained fmap result is not re-usable as an HKT argument — the return type of `fmap(f, ma)` loses its constructor identity and cannot be passed to another HKT-parameterised function. Demonstrated in lib/fp/ type_complex_test.lua.

- [ ] **Typechecker: `{ [K]: V }` type param not substituted as indexer key** — when a
  generic type parameter is used as the key type of an indexer (`{ [K]: V }`), the
  parameter is not substituted at instantiation. The indexer key stays as the raw type
  variable rather than the concrete argument. Found 2026-03-29 via lib/fp/ testing.

- [ ] **Typechecker: generic variance (expressiveness, not soundness).**
  All generics are currently invariant. `Box<Dog>` is not a subtype of
  `Box<Animal>`. Demoted from soundness to expressiveness in commit
  `ca64aeb1` after the design pass (`docs/typechecker-variance.md`,
  2026-05-17): probing showed structural invariance + function
  contravariance + FLAG_SKOLEM rejection already prevent the bad cases
  the soundness audit worried about. Remaining gap is purely
  expressiveness — can't declare covariant/contravariant containers
  like `ReadOnlyMap`. Implement when a user writes the first
  heavily-generic library that wants it. Not blocking.

## security (fix soon)
- [x] http/router: path traversal via symlinks — `path.safe_resolve()` with FFI `realpath()`
- [x] http/server: reads one packet, not until headers complete — loop until `\r\n\r\n`, then read body by Content-Length
- [x] http/router/staticx: pattern `.gz$` should be `%.gz$` (Lua pattern, `.` matches any char)
- [x] http/router/staticx: opens files in `"r"` mode — should be `"rb"` to avoid newline mangling
- [x] charactercardv2/server.lua: `require("lib.keyring")` inside app — sandbox violation, app could read any key. Fixed: key resolved at platform level, injected as pre-keyed llm cap.
- [x] sillytavern/server.lua line 143: `os.time()` called directly — must accept injected `time_fn` cap instead
- [x] library/server.lua: `io.write()` / `io.stderr:write()` in CLI handler — must accept injected `stdout`/`stderr` write fns
- [x] **Sandbox: all required modules run with full host privileges** — both tarball and whitelisted platform modules run in global env. Fix: (1) tarball modules → `load(source, "t", env)`; (2) whitelisted pure-Lua platform modules → source-load from disk via `load(source, "t", env)`; (3) FFI-backed functionality → cap system only: declared in manifest, explicitly granted by platform, injected as `caps.*` globals. Apps use `caps.compress(data)` not `require("lib.compress")`. `ffi` is never on any whitelist; FFI modules are not requireable inside the sandbox. Maintain sandbox-local `package.loaded`. Fixed: tarball modules now load via `load(source, "t", env)` in `lib/platform/init.lua`.
- [x] **`caps` leaks into all module envs** — currently `caps` is a global in the sandbox env shared by all modules. Required modules must receive an env without `caps`; only the entrypoint gets it. App passes caps to internal modules explicitly as arguments. Fixed: caps stripped from module envs in `lib/platform/init.lua`.
- [x] **Dev/prod sandbox inconsistency** — CLI dev mode uses a blocklist (`ffi`, `io`, `os`, `debug`, `package`); daemon mode uses a whitelist. A violation present in dev may be invisible in prod and vice versa. Fix: CLI dev mode must use the same whitelist-only sandbox as daemon mode. Fixed: `lib/platform/cli.lua` now uses whitelist sandbox.
- [ ] Full security audit of all imported libraries

## correctness
- [x] http/router/staticx: `Content-Length = ""` is invalid HTTP — omit header entirely
- [ ] http/router/staticx: detects directories via `read("*all") == nil` — fragile, use lfs or stat
- [ ] http/router/staticx: reads entire files into memory — needs size cap or streaming for large files

## stdlib

### sha256 FFI tier performance
- [ ] `lib/sha256` FFI tier benchmarks at 72 MB/s vs theoretical ~200-500 MB/s. Known causes: `compress` is a closure (JIT can't inline), `u32_to_hex8` allocates a table per call (8× per hash), zeroing loop should use `ffi.fill`, mixed Lua number/FFI integer arithmetic in schedule extension. Not a blocker for CRI workload but worth fixing before the system tier is wired up.

### crypto / hashing stdlib design
- [ ] Design a coherent `lib/hash/` or `lib/crypto/` namespace before adding more algorithms. Questions to answer: how do tiered implementations (system lib > FFI scalar > pure Lua) get shared across blake3, xxhash, md5, sha256, etc.? How are parity tests and benchmarks structured per-algorithm vs shared? Does each algorithm live in `lib/hash/sha256/`, `lib/hash/xxhash/`, etc., or is there a single `lib/hash/` with a dispatch table? `lib/sha256/` exists as a prototype — treat it as a reference, not the final shape.

### dep.* import resolution
- [ ] Many packages in `lib/` reference `dep.ljsocket`, `dep.lunajson`, `dep.epoll`, `dep.tls`, `dep.ljltk`, etc. — these resolve against `~/git/lua/dep/` in the parent monorepo, not against anything in crescent. Affected: `lib/http/client.lua`, `lib/http/serverx.lua`, `lib/https/`, `lib/codetree/`, `lib/dns/tcp_client.lua`, `lib/discord/`, `lib/lsp/`, and others. (`lib/markdown/` removed from this list 2026-07-26: its `dep.pretty_print` reference lived only in the now-deleted dead-code `format.lua`; `init.lua` has no `dep.*` references.) These packages are not self-contained and cannot be vendored. Each needs its dependencies either pulled into `lib/` properly or declared in a manifest and resolved via the package manager.

### package audit
103+ packages surveyed. Most predate the ecosystem design and were written without crescent's conventions in mind. Many will need partial or full rewrites to meet the bar — not just cleanup. Treat the audit findings as a roadmap, not a checklist.

**Verdict summary:** type/static, test, sqlite, ljsocket, lunajson, cbor, base64, sha1, urlencode, fs/dir_list, cparser, git → `clean`. http, pkg, websocket, cli → `needs-work`.

**Wrong-home (belong in registry, not stdlib):**
- [ ] `lib/glua/` — OpenGL bindings, application-specific
- [ ] `lib/mock/` — large mock library (2.6 MB), not foundational
- [ ] `lib/love/` — game framework bindings
- [ ] `lib/tree_sitter/` — parse library bindings
- [ ] `lib/ljltk/` — Lua parser/compiler (third-party origin)
- [ ] `lib/crescent_examples/` — collection of small scripts demonstrating crescent

**Missing init.lua (35+ packages):** http, https, fs, socket, tcp, dns, imap, irc, test, and others — violates "every package is a directory with init.lua entry point". Many of these also need rewrites, so add init.lua as part of the rewrite, not as a standalone fix.

**Missing spec traceability:** ~70+ packages lack RFC/spec citations. Add as part of rewrites, not retrofitted onto existing code that may be replaced anyway.

**Missing conformance tests:** dns, irc, imap, websocket, http (partial) — no tests at all for protocol behavior. Add as part of rewrites.

#### http
- [x] No `init.lua` — re-export `format`, `client`, `status` from a top-level init
- [x] `http/client`: replace `assert(socket.create(...))` with `return nil, err` — fails with unhelpful message on socket error
- [ ] `http/format`: silently drops unparseable headers — log or return error
- [ ] extract network layer (client.lua, server.lua) — needs lib/ljsocket, lib/epoll, lib/socket/server.lua
- [ ] **`lib/http/client.lua` epoll support** — add optional `epoll` parameter (same pattern as `~/git/lua/lib/tcp/client.lua`). Non-blocking socket + epoll callback registration so multiple concurrent HTTP requests (e.g. parallel vLLM calls) can share one event loop. Prerequisite for parallel nanite fleet.
- [ ] extract routers — needs lib/path, lib/mimetype, lib/fs, lib/lunajson

#### https
- [ ] `lib/https/client.lua`: module-level TLS state (single concurrent connection) — acceptable for now but needs per-request TLS context for concurrency
- [ ] `lib/https/client.lua`: certificate verification disabled by default — `tls.config_verify()` should be the default; current code omits it for compatibility
- [ ] `lib/https/serverx.lua`: non-functional (FIXME placeholders, wrong imports) — needs full rewrite

#### ai (`lib/ai/`)
- [ ] `lib/ai/` providers hardcode `require("lib.https.client")` — violates caps-first; should accept an http client as a parameter
- [ ] `lib/ai/init.lua`: no retry/backoff on transient errors (429, 5xx)
- [ ] `lib/ai/providers/anthropic.lua`: tool call streaming only emits on content_block_stop — no partial tool call deltas
- [ ] `lib/ai/providers/openai.lua`: only flushes first accumulated tool call on finish — multi-tool-call streaming incomplete
- [ ] `lib/ai/tools.lua`: assistant message in tool loop doesn't carry tool_calls metadata — some providers need it for multi-turn tool conversations
- [ ] `lib/http/stream.lua`: buffer growth via string concat in hot path — should use table accumulator or FFI buffer
- [ ] **low-prio** providers needing custom adapters (not OpenAI-compatible):
  - Azure OpenAI (`api-key` header instead of `Authorization: Bearer`)
  - Amazon Bedrock (SigV4 signing)
  - Google Vertex AI (GCP OAuth, different endpoint from Gemini API)
  - Replicate (predictions API, polling model)
  - Cloudflare Workers AI (`account_id` in URL path)
  - Reka (own request format)

#### websocket
- [x] 15 TODOs — resolved/categorised (perf/api/extensions/policy/refactor); aa5a4e0
- [x] Tests — 118 assertions: frame encode/decode, masking, close/ping/pong, error cases
- [x] `package.path` guard added
- [ ] Error return convention: int → string (breaking API change, deferred)
- [ ] Packet size limit enforcement (caller policy decision, deferred)

#### sqlite
- [x] No tests — add coverage for query, parameter binding, iteration, error paths (sqlite_test.lua, 72 assertions)
- [x] `db:close()` bug: passes `self.db` (`sqlite3 *[1]`) to `sqlite3_close_v2` which expects `sqlite3 *`; should be `self.db[0]` — fixed (4b9ae58)
- [ ] blob support missing (TODO in source) — `sqlite3_bind_blob` declared in FFI cdef but unreachable from Lua API
- [x] macOS: dlopen path for libsqlite3 — fixed with pcall-based multi-name fallback (commit 4f67ac9)

#### pkg
- [x] `install.lua`: resolver and downloader — implemented (resolve, fetch, link, run)
- [x] `config.lua`: `~/.crescent/config.lua` loading with defaults

#### cli (lib/crescent_examples/)
- [ ] Scripts mix `main()` logic with library code — not composable
- [ ] Many scripts have implicit dep on lib/ layout; add path fixups or document
- [ ] Review lib/crescent_examples/ scripts — sort into per-library homes or keep as demos

#### cross-cutting
- [ ] Standardise error return style: prefer `nil, err` for recoverable errors; `error()` only for invariant violations. Affected: http/client (uses assert), cbor/lunajson (uses error() for encode failures — acceptable but document the choice)
- [ ] LICENSE files: most vendored packages have headers but no LICENSE file — add or verify (ljsocket, lunajson, cbor, sha1, base64, cparser, git)
- [ ] `package.path` guard missing from websocket and http submodules — add where standalone use is expected
- [ ] Review and polish all libraries pulled from ~/git/lua (bulk import done)
- [ ] lib/todo/: conflicts with dep/todo/ (stubs for jpeg, png, xcb, soloud + a sqlitex.lua (old naming), webp.lua) — decide what to keep
- [ ] Remove or integrate duplicate/overlapping libs (e.g., mock.lua vs mock/, lil.lua vs lil/)
- [ ] replx: add provenance tracking for lazy-loaded globals (symbol → source module)
- [ ] FFI bindings: add ABI sanity checks (sizeof/offsetof assertions for wlroots version skew)
- [ ] Formalize C header ingestion pipeline (update_wlroots.sh pattern) as reusable tooling

## typechecker

### self-hosting blockers (run clean on own codebase)
- [x] Widen literal types on reassignment (`local k = 1; k = k + 1` should work)
- [x] Multi-return unpacking (`local a, b, c = f()` should assign all three)
- [x] Forward-declared locals (`local f; f = 42` — use typevar, not nil)
- [x] Integer literal inference (hex `0x36` should be integer, not number)
- [x] Arithmetic on integers returns integer, not number
- [x] String method resolution (`s:gsub(...)` resolves via string metatable)
- [ ] **`string <: { sub: _ }` fails in structural subtyping** — method dispatch (`s:sub()`) already resolves via the string prelude, so the checker knows `string` has those methods. But the subtyping relation doesn't use the same lookup: `string` as a primitive fails `<: { sub: _ }`. These are the same invariant — one code path (method dispatch) uses the prelude, the other (structural subtyping) doesn't. Fix: when checking `string <: { field: T }`, look up the field in the string prelude before failing. Causes ~59 pre-existing errors in `lib/parse/init.lua`.
- [ ] **Mixed named/unnamed params in a `--:` annotation mis-infer DISTANT code** — writing `--: (Val, atom: string) -> boolean` on v9 lattice.lua's `has_atom` (commit ff25df8c, where it is spelled unnamed `(Val, string)`) makes the legacy checker report `cannot take length of type never` at the UNRELATED, much earlier `#fn.results` (lattice.lua:645, inside clip); the fully-unnamed spelling checks clean. Whole-file inference is annotation-shape sensitive at a distance — either reject the mixed spelling with a parse diag or fix the inference; silent far-away `never` is the worst failure shape.
- [x] `number` assignable to `integer` parameter (safe widening direction)
- [x] Union-typed operands (`x and "y" or "z"` produces union — concat/arithmetic now accept)
- [x] Reassignment of literal-typed bindings (`ret = "()"` then `ret = "..."` — fixed by T.widen)
- [x] Forward references in `local M = {}` / `function M.foo()` pattern (prescan)
- [x] Dict-style computed access `t[key]` checks string-keyed fields (literal and general)
- [x] Empty table `{}` assignable to array-typed parameter (absorbs indexers in unify)
- [x] `x = x or default` pattern — strip self-ref var from union in bind_var
- [x] Cross-call-site typevar mutation — generalize params + FunctionDeclaration writes raw table
- [x] Recursive `local function f()` — pre-bind name as typevar before body inference
- [x] Discriminated union narrowing (`if t.kind == "literal" then ...`)

### unify.lua blockers
- [x] Structural narrowing after `if ty.tag == "var" then` (adjust_levels/bind_var expect level/id fields on resolved vars) — fixed: `and/or` idiom nil-union, assignment-narrowing ops annotation, d.path[i] with `--: [string]?` guard

### output formats
- [x] `--format json` structured output (file, line, severity, message)
- [x] `--format sarif` for GitHub Code Scanning / CI integration
- [x] Column numbers in error positions
- [x] SARIF column off-by-one: typechecker cols are 1-indexed; `errors.format_sarif` uses `e.col+1` → outputs col+1 (2-indexed). Should use `e.col` for 1-indexed SARIF. Fixed 2026-03-15.

### done
- [x] Full require() return type tracking (infer module return type)
- [x] Implicit any error reporting (every ANY fallback site)
- [x] `--dump` CLI mode (print inferred bindings)
- [x] `--annotate` CLI mode (emit source with --: annotations)
- [x] Type inference for local bindings
- [x] Structural typing for tables
- [x] Angle-bracket generics (`Name<T, U>`) with constraint support
- [x] Named type resolution with two-pass forward references
- [x] Tuple types (`{ number, string }`) and spread (`{ ...Base }`)
- [x] Flow-sensitive type narrowing (type(), nil checks, truthiness, assert)
- [x] Module resolver + prelude system (Array, Dict, Set, Optional)
- [x] Nominal types (newtype, opaque)
- [x] Match types (`match T { pattern => result }`)
- [x] Intrinsics ($Keys, $EachField, $EachUnion)
- [x] Overload resolution (best-match scoring)
- [x] setmetatable __index merging, __call metamethod
- [x] `#field` metatable slot syntax — separate `meta` dict on table types; `#__add: fn` in annotations; setmetatable populates META_OPS into meta; unification checks meta fields

### known false positives
- [x] **Assignment narrowing**: assigning `nil` to a variable inside `if x then` is flagged — typechecker checks against narrowed type, not declared type. Fixed: narrowing-escape generalized from nil-only to any value; checks outer scope binding for the pre-narrowing type.
- [x] **Nil method call not caught**: `local x; x:match("pattern")` — fixed by nil_vars side-channel; `testdata/errors/nil_method.expected` now captures the error.

### access control (design complete, implementation pending)
- [x] **Design field access control model** — written to `docs/access-control.md` (2026-03-19)
- [ ] **Resolve open questions in access-control.md before implementation**: (1) annotation syntax for exported type vs internal type; (2) opt-in syntax at use site for intentional private access; (3) read/write independence in annotation syntax; (4) split FLAG_READONLY into FLAG_IMMUTABLE + FLAG_WRITE_PRIVATE in FieldEntry
- [ ] **Remove FLAG_PRIVATE** — current `_`-prefix enforcement (session 25) is wrong model. Privacy = absence from exported type + `$Opaque<T>` + `--:: unseal` opt-in. No definition-site whitelist.

### nominal type identity across files (bug)
- [x] **`newtype` and `$Opaque<T>` identity is now content-addressed**
  — nominal IDs are now derived from `fnv31(filename:ann_tid)` for `$Opaque` and
  `fnv31(filename:newtype:name)` for `newtype`, making them deterministic for the
  same source content across runs. The stable hash is stored in TAG_TYPE_CALL.data[3]
  and persisted through .cri files so cross-file aliases resolve consistently.
  **Remaining gap**: two *different* files declaring the same alias (e.g.
  `--:: Schema<T> = $Opaque<T>` in both init.lua and check.lua) still produce
  distinct types. The fix requires module type imports — when check.lua does
  `require("lib.type")`, its annotations should resolve `Schema` from init.lua's
  exported type aliases, not from a re-declaration. Tracked below.
- [x] **Module type imports**: type aliases from required modules are now in scope for annotations.
  CRI Section 6 serializes/deserializes type aliases. When `require()` resolves via
  cri_loader, aliases are returned alongside exports and injected into scope via
  `inject_imported_aliases` in constrain.lua. Local declarations take precedence.
  Fixed: cri_write now registers alias name/param strings in the string table.

### known false negatives (v2)
- [x] **nil/boolean concat**: `nil .. "a"` silently passed — fixed by replacing is_concat_scalar tag whitelist with `__concat` metamethod presence check via meta_op_ret/prim_meta. nil and boolean have no __concat → correctly fail. string|nil union member fails correctly.
- [x] **`_G` should be an intrinsic reflecting the global scope**: synthesized as `$GlobalScope` — closed TAG_TABLE (no fallback indexer), named fields per declared global, declared in stdlib_types.lua. TAG_INTRINSIC resolution in constrain.lua checks type aliases first so `$Name` works as a regular type reference when registered. (2026-03-19, 5a42a48)
- [x] **`ctx_types.lua` leaks internal bindings into user scope**: `populate()` now only loads stdlib_types.lua; `populate_checker()` loads both. (2026-03-19, 9c9f788)

### annotation syntax gaps
- [x] **Open table syntax in .d.lua**: `{ ... }` bare spread in table annotation creates a row variable; `{ fields..., ... }` = open table. `_G` now declared in stdlib_types.lua. (2026-03-03, commit 6e197c5)
- [x] **`typeof` annotation**: `typeof x` captures the inferred type of binding `x`. TAG_TYPEOF = 25; ann.lua recognises `typeof <ident>`; resolve_annotation_type does scope lookup. Top-level `--::` decls with typeof are deferred until after gen_block. (2026-03-19, 913110e)
- [x] **`typeof` in function signatures**: pre-bind param names as TAG_VAR placeholders before resolving annotations. All cases work: forward refs, backward refs, return refs, mutual refs.

### performance (v2 redesign)
**Full redesign in progress. See `docs/typechecker-v2.md` for architecture.**

v1 is a proof-of-concept for the type system semantics. v2 is the production
implementation targeting tsgo-competitive cold-start performance and sub-100ms
incremental checking at 1M+ LOC scale.

Key design decisions:
- Flat-array AST (32-byte FFI nodes, arena-allocated, zero GC)
- Integer type tags + union-find (no string dispatch, O(α) resolution)
- Custom parser → flat AST directly (no intermediate tables)
- mmap-able .cri interface files (zero-copy, content-addressed)
- Merkle DAG incremental cache (interface-hash propagation)
- Fork-based parallelism via libc FFI (wave-front scheduling)
- LSP daemon with tiered memory (hot/warm/cold)

**v2 checker Phase 3 — implemented (2026-03-02).**
Types: flat TypeSlot arenas + union-find. Env: let-polymorphism (generalize/instantiate).
Unify: structural, bidirectional, row polymorphism. Infer: full AST walk, annotations, narrowing.
Files: types.lua, env.lua, unify.lua, errors.lua, match.lua, narrow.lua, infer.lua, check.lua.
Tests: 721 assertions in v2_test.lua (1123 total across all suites).

Known gaps / Phase 4 deferred work:

**Phase 4 preamble complete (2026-03-02, commit 663e90a):**
- [x] cli.lua — thin CLI runner
- [x] prelude.lua — Lua 5.1 stdlib bindings (string, table, math, io, os, coroutine)
- [x] open-table extension — `function M.foo()` adds field via table_add_field
- [x] prescan: function M.foo() pre-populates M's field list before inference
- [x] prescan: `local M = {}` preserves prescanned type (no clobber on infer)
- [x] iterator type inference — `for k, v in pairs(t)` uses iter func return types
- [x] string method calls — `s:gsub()` looks up string prelude table

**Known false positives in v2 (catalogued 2026-03-02 against v2 source):**

Cat A — Forward-declared nil locals (large impact on infer.lua): **FIXED 2026-03-02**
- `local f; f = function()` — now binds a fresh type var instead of T_NIL when no RHS
- Fixed in StmtRule[NODE_LOCAL_STMT]: el==0 → make_var; last_rhs_is_call → T_ANY
- Remaining: `local x = nil` (explicit nil literal) still binds T_NIL — Cat A variant

Cat B — Multi-return assignment loses values: **FIXED 2026-03-02**
- Fixed in StmtRule[NODE_LOCAL_STMT] and StmtRule[NODE_ASSIGN_STMT]:
  when last RHS is a call, missing return slots → T_ANY instead of T_NIL
- Remaining: fully generic multi-return arity tracking (future)

Cat C — Literal table vs indexed type mismatch: **FIXED 2026-03-02**
- Fixed in unify.lua: when b has a numeric indexer and a has no matching indexer, check
  a's sequential integer-named fields ("1", "2", ...) and unify each value with the indexer value type.

Cat D — Boolean literal widen on reassignment: **FIXED 2026-03-02**
- Fixed in StmtRule[NODE_LOCAL_STMT]: boolean literal binds widen to `boolean`
- Fixed in StmtRule[NODE_ASSIGN_STMT]: existing binding widened before unify

Cat E — Nil-narrowing after early return: **FIXED 2026-03-02**
- narrow.lua: bare identifier treated as nil-check; guard clauses apply negated narrowing
- narrow.lua: TAG_VAR not narrowed to T_NEVER (prevent "never" in branched code)
- StmtRule[NODE_IF_STMT]: after unconditional-exit clause, apply negated narrow to continuation
- ASSIGN_STMT: skip unify when existing resolves to T_NEVER (narrowed-out branches)
- OP_AND short-circuit narrowing: `a and a.field` narrows `a` before evaluating `a.field`.
  narrow_scope handles OP_AND in truthy branch; infer.lua OP_AND early-returns with narrowing.
- OP_OR guard narrowing (2026-03-02): `if not x or not y then return end` — falsy branch of
  `A or B` applies De Morgan: narrow_scope handles OP_OR with is_truthy=false, extracting
  narrowings from both arms. Also added NODE_FIELD_EXPR support in extract_narrowing:
  `x.field` is a "field_presence" check; after `if not x.field then return end`, x.field
  is narrowed to non-nil in the continuation via narrow_field_non_nil (rebuilds table type).

Cat F — `intern_mod.get()` returns `string|nil`, `or "?"` not narrowed to `string`: **FIXED 2026-03-02**
- Fixed in ExprRule[NODE_BINARY_EXPR] OP_OR: strip nil from left side before union with right.
- Also fixed `is_concat_ok` to handle unions (all members must be concat-compatible).
- `string|nil or "?"` now produces `string|"?"` (concat-safe union), not `string|nil|"?"`.

Cat J — **FIXED 2026-03-02** (commit 0a91819):
- Removed `constrain()` / `meta_constraint()` — free typevars in arithmetic stay free.
- Added `prescan_block` call inside `infer_function` (forward-decl'd) to pre-bind nested
  `local function f()` before body inference (fixes self-recursive nested locals).
- Added `and`-short-circuit narrowing in ExprRule[OP_AND] (infer.lua) and narrow_scope
  (narrow.lua) — `ann and ann.field` no longer fails before entering the truthy branch.
- Added `seen` dedup table in `make_union` (types.lua) — prevents `'v | 'v` unions that
  broke field access after stripping nil from `nil | 'v | 'v`.
- Trade-off: arithmetic on unannotated params is no longer constrained (e.g. `add({}, {})` with
  unannotated `add(x,y) = x+y` won't error). Annotated code is unaffected.
- All 9 previously-clean v2 source files now self-check at 0 errors.

Cat G — string meta architecture: **FIXED 2026-03-02**
- `ctx.prim_index` (TAG_* → __index TID) for method dispatch; `ctx.prim_meta` (TAG_* → op-metamethods TID) for operator dispatch.
- Both populated by prelude.populate() from stdlib_types.lua aliases (number_meta, integer_meta, string_meta_ops, string var).
- infer.lua NODE_METHOD_CALL: generic prim_index[tag] lookup; literal strings normalized to TAG_STRING.
- infer.lua meta_op_ret: extended to check prim_meta for primitives — unary `-integer` now returns integer (not number).
- infer.lua binary dispatch (ARITH/CMP/CONCAT): TAG_TABLE guard prevents prim_meta from short-circuiting error checks and mixed-type arithmetic.
- unify.lua: replaced if/elseif tag switch with prim_meta[ptag] lookup (TAG_LITERAL normalized inline).
- Known gap: `nil .. "a"` not flagged — TAG_NIL is in is_concat_scalar (pre-existing, separate fix needed).

Integer literal typing: **FIXED 2026-03-03** (commit bb0c2e8 era)
- `NODE_LITERAL` handler was using numval index as a pool intern ID (IDs 0-21 are keywords).
- Fix: store `pr.lexer.numvals` in `ctx.numvals`; check `num % 1 == 0` for integer classification.
- integer <: number is now unidirectional (integer assignable to number, NOT vice versa).

Cross-type comparison: **FIXED 2026-03-03** (commit bb0c2e8)
- `"a" < 1` and `1 < "a"` silently passed because each operand individually had __lt in prim_meta.
- Fix: meta_fn_tid helper returns the full metamethod function TID. In CMP_META dispatch, after
  has_metamethod passes for both operands, look up the __lt/__le function (left first, then right
  per Lua calling rules) and validate both operands against its declared parameter types via try_unify.
- Bonus fix: try_unify union-LHS case: all members must be assignable to b (previously fell through
  to false, causing false positives for `integer | number > number` patterns in unify.lua self-check).

Cat H (new) — Optional function parameter typed as required: **FIXED 2026-03-02**
- Fixed in infer_function: scan first 10 body statements for `param = param or default`.
- After body inference, widen matched params to union(bound_type, T_NIL).
- `resolve_annotation_type(ctx, id)` (2 args) now accepted where 3rd param has default.

Cat I (new) — Explicit `local x = nil` still binds T_NIL: **FIXED 2026-03-02**
- Fixed in NODE_LOCAL_STMT: when rhs resolves to TAG_NIL, bind fresh typevar (same as Cat A).
- `local arg_ids = nil; arg_ids = {}` now works correctly.

Recursive function return type inference: **FIXED 2026-03-03** (commit 192b878)
- Prescan now creates `(T_ANY,...) → β` stubs (not bare TAG_VAR). β is shared across all recursive
  call sites (not FLAG_GENERIC → instantiate passes it through unchanged). add_return eagerly binds
  β on first return statement; all later recursive calls resolve via find(). ctx.return_stub_vars
  stack threads stub return vars into nested function scopes. Annotated functions skip eager binding.
- Limitation: unannotated params are TAG_VAR; arithmetic falls to T_NUMBER. Annotated params work.

**Phase 4 proper:**
- [x] .cri interface files (zero-copy module loading, content-addressed) — 2026-03-03: sha256.lua, cri_write.lua, cri_read.lua, cache.lua, check.lua integration
- [ ] Fork-based parallelism (Phase 5)
- [ ] LSP daemon integration (Phase 6)

**Next high-value false-positive fixes (from catalogue above):**
- [x] Cat A: forward-declared nil locals → make_var (unblocks most of infer.lua false positives)
- [x] Cat B: multi-return in assignments (right-hand side)
- [x] Cat D: boolean literal widen on reassignment
- [x] Cat E: guard/early-return nil narrowing (full fix: includes OP_OR De Morgan + field_presence)
- [x] Cat C: positional table vs indexed type — FIXED 2026-03-02
- [x] Cat F: `A or B` result narrowing — FIXED 2026-03-02
- [x] Cat H: optional function parameters (seen arg pattern) — FIXED 2026-03-02
- [x] Cat I: explicit `local x = nil` treated as forward declaration — FIXED 2026-03-02

- [x] Infinite recursion in resolve_require: fixed with `_globally_resolving` module-level table.

Lexer optimization (see `docs/perf/log.md` for measurements):
- [x] Kill `_buf` mechanism — pointer arithmetic + `ffi.string` at end (1.4x speedup)
- [x] Source-referencing intern pool — FNV-1a hash + memcmp, zero Lua strings in lex path (5.3x total vs baseline)
- [ ] (stretch) Full FFI struct hash table for intern entries — current impl uses Lua tables per entry with FNV-1a + memcmp; a flat FFI array could reduce GC pressure further but 5.3x is good enough to move on

### v2 → v3 migration (constraint-based inference)

Design: `docs/typechecker-v3.md`. Implementation: `lib/type/static/constrain.lua` + `solve.lua`.
Entrypoint: `check.check_string_v3(src)`. Status: Phase 1 (parallel) — v3 runs alongside v2.

**Phase 1 blockers (reach parity with v2):**
- [x] String method dispatch (`s:gsub(...)` via prim_meta) — prim_index lookup in solve_has_field
- [x] prim_index / metamethod lookup for primitives — same
- [x] Narrowing (type(), nil checks, `if x.tag == "foo"`) — narrow_scope/apply_narrowed in constrain.lua
- [x] pcall / xpcall — already correct via stdlib_types.lua `any` param declarations
- [x] Iterator inference (`for k, v in pairs(t)`) — already implemented in constrain.lua
- [x] `or`-expression union inference (`x or default` → `T | U`) — already implemented in constrain.lua
- [x] Correlated multi-return narrowing — C_INDEX + filter_tuple_union_arms + pcall intrinsic; io.open/string.find union-of-tuples stdlib types (2026-03-19)

**Phase 2 — cutover:**
- [x] Replace `check.check_string` with v3 pipeline — done; check.lua fully on v3 (commit 848ea56)
- [x] All existing tests must pass — 838/838 pass against v3 (2026-03-16)
- [x] Delete `infer.lua` — done (commit 2e33c62); type_test.lua migrated to check_mod

**Phase 3 — annotation pass (after Phase 2 cutover):**
- [x] Rewrite remaining sumneko-syntax `.d.lua` files in crescent annotation syntax
  (`--:` / `--::`). Files: `lib/http/format_types.lua`, `lib/lsp/types.d.lua`,
  `lib/imap/format_types.lua`, `lib/matrix/format_types.lua`. Done: commit `2a9ec10`.
- [ ] Strip all `--:` annotations from own codebase, run v3, record error set
- [ ] Re-annotate only where errors appear (load-bearing annotations)
- [ ] Mark inference-gap annotations with `-- TODO: v3 gap` comment so they're removable in bulk when the gap closes
- [ ] Keep annotations on public API functions regardless (they're contracts, not just inference hints)
- [ ] Goal: minimal annotation set where every annotation either fixes an error or documents a public contract

### v1 → v2 cutover status (2026-03-10)

v2 is architecturally superior but v1 CLI has QoL features v2 still needs before cutover:

| Feature | v1 | v2 |
|---|---|---|
| Source line + caret in errors | ✓ | ✓ (2026-03-10) |
| `--format sarif` | ✓ | ✓ (2026-03-10) |
| `--dump` mode (print inferred bindings) | ✓ | ✓ (2026-03-10) |
| `--annotate` mode (emit source + annotations) | ✓ | ✓ (2026-03-10) |
| Auto-glob `lib/*.lua` when no args | ✓ | ✓ (2026-03-10) |
| `.cri` cross-file require() types | ✗ | ✓ |
| Correct integer <: number | ✗ | ✓ |
| pcall/xpcall narrowing | ✗ | ✓ |
| Branch-join merging | ✗ | ✓ |
| Recursive fn return inference | ✗ | ✓ |

Blocking items for cutover:
- [x] `--dump` mode in v2 CLI — 2026-03-10
- [x] Auto-glob fallback in v2 CLI — 2026-03-10
- [x] `--annotate` mode in v2 CLI — 2026-03-10

### backlog
- [x] **Object narrowing via field access** — `if foo.x then aaa(foo)` narrows `foo` itself so `aaa(foo)` typechecks. Implemented via `field_presence` narrowing in `apply_narrowing` (narrow.lua): `narrowed[obj_name_id]` is set to `narrow_field_non_nil(obj_type, field_name_id)`, which rebuilds the table type with nil subtracted from the named field. Works for plain tables and unions. Tests added in type_test.lua ("checker: object narrowing via field access").
- [x] **Type system completeness audit** — tag × operation matrix written to `docs/type-tag-matrix.md` (2026-03-15, commit b51f976). Fixed: `x == "literal"` direct variable narrowing (lit_eq kind, LIT_STRING + LIT_BOOLEAN), boolean field discriminant narrowing, TAG_ROWVAR in try_unify/unify, TAG_TUPLE literal indexing. Known remaining gaps documented in the matrix: integer discriminants (numval per-file), covariant/contravariant generics, recursive types, TAG_MATCH_TYPE/FORALL/TYPE_CALL/SPREAD not handled in unify (by-design: meta-level constructs not expected in value position).
- [x] **Soundness audit** — 2026-03-15. Full audit written to `docs/soundness-audit.md`. Gaps enumerated: (1) TAG_VAR permissiveness in try_unify — union/intersection dispatch silently accepts free-var args; (2) unannotated params by design; (3) generic variance not enforced; (4) no occurs check for recursive types; (5) intersection dedup — FIXED 2026-03-15 (added `seen` table to make_intersection); (6) nil-padding in arity check — correct for Lua semantics; (7) LIT_INTEGER cross-file — deferred.
- [x] **Soundness fix: try_unify TAG_VAR** — `try_unify` no longer returns true for `ta.tag == TAG_VAR` (free actual type). Only `tb.tag == TAG_VAR` (free expected, for generic instantiation) stays true. `ta.tag == TAG_ROWVAR` kept true for open-table structural matching. (2026-03-15, session 21). See `docs/soundness-audit.md` Gap 1.
- [ ] **Soundness gap: `try_unify` does not check meta fields** — `try_unify` (used for generic constraint checks, oracle lookup, fuzz algebra) only checks regular table fields; meta fields are only checked in `M.unify` (constrain.lua path). Consequence: `<T: { #__add: T }>` generic constraints silently accept types without the required metamethod. Fix: extend the TAG_TABLE branch of `try_unify` to also iterate meta fields. Found while attempting A4 algebra fuzz invariants (2026-03-30).

- [ ] **Typechecker bug: `any?` as last param corrupts struct field resolution** — when a local function has `any?` as its last parameter (e.g. `--: (SomeStruct, integer, string, any?) -> nil`), the checker fails to resolve fields of `SomeStruct` in the function body, treating them as `unknown`. Workaround: drop the `?` from `any?` params (use `any` — makes no runtime difference since `any` absorbs nil). Found in lib/log/init.lua emit() during 2026-04-10 implementation.
- [ ] **Soundness fix: mutual recursion via non-table types** — `bind_var` has occurs() for simple self-ref; `display()` has seen guard for tables. Mutual recursion through function types (very rare in Lua) is not protected. Very low priority. See `docs/soundness-audit.md` Gap 4.
- [ ] **Generic variance (expressiveness, not soundness)** — type params in `<T>` generics have no variance annotation. Demoted from soundness to expressiveness in commit `ca64aeb1`; design at `docs/typechecker-variance.md`. Structural invariance + function contravariance + FLAG_SKOLEM rejection already prevent the bad cases. Remaining gap is being unable to *declare* covariant/contravariant containers. See `docs/soundness-audit.md` Gap 3 (historical framing).
- [ ] **Error message quality audit** — bar is Rust-level helpfulness. Specific gaps identified:
  - Source line + caret: **DONE** (2026-03-10) — errors.lua set_source/format_plain/format_ansi
  - "missing required argument" now shows expected type: **DONE** (2026-03-10) — `argument 1: missing required argument (expected 'string', got nil)`
  - Long type truncation: **DONE** (2026-03-10) — display_short() at 120 chars with …
  - "missing required argument" now includes parameter name: **DONE** (2026-03-10) — `argument 1 'opts': missing required argument...`; param name IDs stored in TypeSlot data[5]/data[6], threaded through instantiate/substitute
  - Named params in annotations: **DONE** (2026-03-10) — `(x: integer, y: string) -> boolean` syntax in ann.lua; stdlib_types.lua updated to use named params throughout; resolve_annotation_type passes names to make_func via data[5]/data[6]
  - Warn on annotation-only functions missing param names: **DONE** (2026-03-10) — `process_type_decls` in infer.lua emits a warning for `--:: declare fn = (T1, T2) -> ret` where the function type has params but no names; inline `--:` annotations on real functions don't warn (names come from AST)
  - [x] Overload mismatch: show *which* overload candidates existed and why each one failed (candidate-by-candidate diff) — **DONE** (2026-03-11): try_call_args (non-mutating) tries each candidate; first match wins; if none match, reports "no matching overload" with per-candidate argument errors
  - **DONE** (2026-03-15): Error message wording overhaul — natural English, no jargon. Patterns: `` `name` is `X`, but this location expects `Y` `` (field re-assign); `` `foo.baz` doesn't exist `` (field not found, no field listing); `` `arg` is `X`, but `fn` expects `Y` `` (call mismatch, uniform regardless of whether X is unknown). Secondary spans for field errors via reparse-on-error (same-file: AST walk; cross-module: reparse from disk). "Did you mean" and "consider annotating" suggestions removed — exact error is enough.
  - ctx_types.lua — **DONE** (2026-03-15): `lib/type/static/ctx_types.lua` declares `Ctx` type alias; loaded by prelude.lua; ~30 functions in infer.lua annotated; self-check 0 errors.
  - Field re-assignment type-check — **DONE** (2026-03-15): `` `name` is `X`, but this location expects `Y` `` with secondary "set to `X` here:" span.
  - Remaining gap: suggestions still listed as open below — actually dropped; error messages are intentionally minimal ("exact error, no more, no less")
- [ ] High-perf SHA-256 for .cri content addressing: current pure-Lua impl is correct but slow
  (~10 MB/s). For 1M LOC scale, SHA-256 should be done via FFI (libssl EVP_DigestInit or
  kernel crypto via syscall). Profile first — .cri files are small (kB range) so this may
  not matter until we're hashing source files at scale.
- [x] Generic function inference (infer type params from call site args)
- [x] `<T>` explicit generic annotation syntax — `--: <T>(T) -> T` on a function; forall vars are generic typevars, freshened at each call site; composes with type-alias params (`--:: Name<T> = …`)
- [x] Partially inferred / partially specified generics — `f --[[:<json.Format, _>]] (val)` where `_` means infer. Annotation on any line `[callee.line, node.line]` (node.line = `(` line). Lua 5.1/LuaJIT constraint: `(` cannot be on a new line from the callee (ambiguous call syntax), so annotation must share the callee's line in practice. Lua 5.2+ compat removes this restriction.
- [x] Parse LuaJIT FFI cdef blocks
- [x] **stdlib_types.lua: type `bit.*` library** — all bit.* fns typed, return integer
- [ ] **stdlib_types.lua: multi-target support** — stdlib types differ by runtime/version (LuaJIT vs Lua 5.1/5.2/5.3/5.4); currently stdlib_types.lua targets LuaJIT but isn't labelled as such; design needed: separate .d.lua files per target, or conditional sections, or CLI `--target` flag that selects which prelude to load
- [x] Field assignment `M.foo = val` now adds the field to M's table type via NODE_FIELD_EXPR handling in NODE_ASSIGN_STMT. Structural-inference guard: skip when existing field type is TAG_VAR (prevents Cat J regression where `s.pos = s.pos + 1` binds the structural typevar).
- [x] **Index assignment type-check** (`t[k] = v`) — 2026-03-15: string literal keys handled as field assignment (add/check named field); non-literal keys checked against matching indexer if present; TAG_VAR tables constrained to have `[key_type]: val_type` indexer. Conservative: no indexer added to extensible tables with no matching indexer (avoids false positives on `returns[#returns+1] = v` patterns). Field re-assignment for index exprs now matches field-expr behavior.
  - Session 15 (2026-03-15, 8486a33): enforcement tightened — error on type mismatch for concrete key types (literal, integer, etc.); skip check only when indexer key is T_ANY/T_UNKNOWN (dynamic dispatch tables). `{ [1]: string }` with `arr[1] = 42` now errors correctly.
- [x] **LIT_INTEGER literal type** — Session 15 (2026-03-15, 8486a33): `LIT_INTEGER = 4` kind added. Integer literals get globally-comparable type (value in data[1] as int32). Number annotations produce LIT_INTEGER for integers. `x == 5` narrowing, TAG_TUPLE indexing, dispatch table slot typing all benefit.
- [x] **LIT_NUMBER float fix** — Session 16 (2026-03-15, b00b27b): `double_to_i32x2`/`i32x2_to_double` helpers in defs.lua. Lex, parse, ann, types, infer, cri all updated. numvals side-array removed. Non-integer floats now produce `LIT_NUMBER` (not `T_NUMBER`), enabling `x == 3.14` narrowing.
- [x] **`x == 3.14` narrowing** — (2026-03-15, b629ef6): `make_lit_eq` in narrow.lua extended to handle LIT_NUMBER non-integer floats via `i32x2_to_double`. `M.unify`/`M.try_unify` in unify.lua fixed to compare `data[2]` for LIT_NUMBER literals (was only comparing `data[1]`).
- [x] **Enum inference** — Session 16 (2026-03-15): `TAG_ENUM_MEMBER = 24` (defs/types/unify/narrow/infer). All-literal same-kind table fields promoted to enum members via `try_promote_enum` in `StmtRule[NODE_LOCAL_STMT]`. `Status.OK` displays as `Status.OK`, `EnumMember <: integer/string` in unify. `x == Status.OK` narrowing via `enum_eq` kind in narrow.lua. Mixed-kind tables not promoted. Tests: 5 new assertions.
- [x] **Newtype IDs for type/intern/node IDs** — Session 16 (2026-03-15, f0cc150): `TypeId`, `InternId`, `NodeId`, `ListIdx` declared in ctx_types.lua. `load_decls` pass 2 in prelude.lua assigns unique `nominal_id` per newtype (was all 0, making them unify).
- [x] **Explicit `any` warning** — Session 16 (2026-03-15): DONE. `resolve_annotation_type` emits a warning when `TAG_ANY` is encountered in an explicit annotation (`ctx._ann_warn_line` set at call sites in LOCAL_STMT, FUNC_EXPR, FUNC_DECL). infer.lua annotations fixed (55 → 0 warnings).
- [x] **Structured diagnostics** — Session 16 (2026-03-15, 3cfd4b2): `M.E` table with 22 integer error codes in defs.lua. `errors.format_diag(code, args)` with per-code template closures. `report`/`warn` now take `(ctx, line, col, code, args)`. All 28 call sites updated.
- [x] v2 stdlib_types.lua: stdlib_types.lua created (2026-03-02); prelude.lua replaced with load_decls().
  `--:: declare name = type` for variable bindings; `--[[:: name = { ... }]]` for type aliases.
  Primitive meta types (number_meta, integer_meta, string_meta_ops) declared in stdlib_types.lua;
  derived into ctx fields after load_decls runs.
- [x] ann.lua: `declare` keyword added to ANN_DECL parser for variable bindings (vs type aliases).
- [x] ann.lua: function data[4] (vararg) fixed — trailing `...T` SPREAD now extracted correctly.
- [x] ann.lua: table data[4] (row_var) fixed — closed by default (-1), was accidentally open (0). Also fixed for `T[]` shorthand (parse_postfix) which had the same gap — triggered a false "undefined type S" when a generic type appeared at position 0 of the annotation arena due to `pairs()` iteration order.
- [x] ann.lua: skip_ws fixed to handle newlines (B_NL, B_CR) for multi-line block annotations.
- [x] `pcall`/`xpcall` return type narrowing — FIXED 2026-03-02: detect pcall/xpcall in ExprRule, extract wrapped fn return types, give `local ok, val = pcall(fn)` val: ret_type|nil; `if ok then`/`if not ok then return end` narrows val to ret_type via propagate_pcall_narrowing in record_narrowing.
- [x] For-in iterator return type tracking — `for k, v in pairs(t)` always gives `any` for k/v; need iterator protocol inference (ipairs/pairs over typed tables, custom iterators)
  - FIXED 2026-03-02 (commit 4efcd5a): detect pairs(t)/ipairs(t) single-call in NODE_FOR_IN; extract [K]:V indexer from actual table arg; typed loop variables. Falls back to iter-func-return extraction for other iterators.
- [x] Metatable slot syntax: `#field` in type annotations — done (see above)
- [x] Structural operator dispatch — BinaryExpression/UnaryExpression/ConcatenateExpression check `meta["__add"]` etc. on operand types via `meta_op_ret`; metamethod return type used instead of primitive check. Unlocks linalg / custom numeric types.
- [x] Structural constraint propagation for send — `x:method(args)` on a var should constrain x to `{ method: (self, args...) -> T, ...row }` (mirrors field access on var).
- [x] Implicit-any warnings on unannotated params — warn if param typevar still completely unbound after body inference; skip `self` and `_`.
- [x] Arithmetic/concat constraint propagation — `a + b` on vars should constrain to "numeric OR has `#__add`"; cannot naively bind to `number` (rejects custom types). Needs a typeclass-style "Numeric" constraint or union of `number | { #__add: ... }`. Same for concat and `#__concat`.
- [x] Branch-join / post-if type merging — FIXED 2026-03-02 (commit 19a6b19). Nil-default pattern,
  exhaustive if/else assignment, if-only assignment all handled. lookup_declared skips narrowing
  scopes; ASSIGN_STMT rebinds branch-locally; NODE_IF_STMT diffs branch scope and unions results.
  **DONE (v3, 2026-03-17, session 25)**: post-if branch-join narrowing ported to v3.
  `branch_scope_diff` + Cat E guard + union of per-branch end types. All branch-join
  tests passing. See commit `feat(type): v3 branch-join`.
- [x] Private field visibility enforcement — DONE 2026-03-17 (session 25). `_`-prefix fields
  get FLAG_PRIVATE. Cross-file access rejected in solve_has_field. ctx.type_origins maps type IDs
  to source filenames via CRI load tagging.
- [x] **Monomorphic callsite inference** — DONE (2026-03-19, commit 6cff48f): removed automatic
  `generalize` for unannotated functions. Params stay as free TAG_VARs; call-site C_CALLABLE binds
  them. Body constraints (C_ARITH etc.) defer until params are concrete. `add("hello", 2)` with
  body `a+b` now correctly errors. `self` param in methods still gets FLAG_GENERIC (avoids recursive
  type cycle). Prescan stub mutated in-place (not C_UNIFY). `unify(var, T_UNKNOWN)` now binds var.
- [x] pcall v3 narrowing — DONE (2026-03-19): C_INDEX multi-return + C_OR deferred or-expression
  fix now correctly types `s` as the pcall'd fn's return type. `s + 1` in `if ok then` errors
  with "cannot perform arithmetic on 'string'". Commits: 4976104 (C_OR), ca871ba (union subsumption).
- [x] `(string|nil) or "fallback"` not narrowing — DONE (2026-03-19): C_OR = 10 deferred constraint.
  OP_OR handler now emits `{C_OR, left, right, result}` instead of computing eagerly. solve_or
  defers while left is TAG_VAR, then runs subtract(left, nil) | right. Commit: 4976104.
- [x] `integer | 0` / `number | integer` union noise — DONE (2026-03-19): make_union now collapses
  literals subsumed by their primitive (LIT_INTEGER → integer, LIT_INTEGER → number), and integer
  into number. Fixes self-check false positives in arithmetic expression types. Commit: ca871ba.
- [ ] unnamed-params warn in --:: declare — `--:: declare fn = (T1, T2) -> R` should warn when
  param types are unnamed. Feature exists in v2 path but not v3 process_type_decls. Test fails
  after 2026-03-17 silent-crash fix.
- [x] $EachField descriptor `optional` flag — already implemented; `optional: true` in descriptor sets FLAG_OPTIONAL on output fields. Tests added (e31c6bd).
- [x] $EachField / $EachUnion full transform evaluation — descriptors, union distribution, any input all working (2026-03-19)
- [ ] Typed holes / completions
- [x] **Match type pattern-bound variables** — fixed 2026-03-19 (commit 13e9603)
- [x] **Recursive generic type crash** — fixed 2026-03-19 (commit d1bb4b9)
- [x] **`never` type not enforced** — fixed 2026-03-19 (commit bf776ff)
- [x] **`any` through `Box<any>`** — fixed 2026-03-19 (commit bf776ff + annotation authority fix)
- [x] **Tag-exclusion in else branch** — fixed 2026-03-19: else branch now applies accumulated negated narrowings from all preceding if/elseif conditions (both Cat-E exiting and pass-through). See `fix(type): tag-exclusion narrowing in else branch`.
- [x] **Tag-exclusion in else with multiple exiting elseif arms** — fixed 2026-03-20: `filter_union` added to types.lua; `guard_narrowings` fallback (when `arm_info` is nil) now uses `filter_union(guard, neg)` instead of last-write-wins, correctly intersecting the accumulated guard with each new exiting arm's negation. See `fix(typechecker): accumulate else-branch negations across all exiting elseif arms`.
- [ ] Variadic `pipe`/`compose` typing — fixed-arity overloads work but variadic needs design; blocked on generic inference + possibly variadic generics or dependent types. Low priority, pending design.

## performance

- [ ] Bench infrastructure (pure Lua, handgrown) — micro + macro; latency histograms; compare before/after on HTTP request path. v2 parser bench: `docs/perf/v2_parse.lua`; perf log: `docs/perf/log.md`
- [ ] Write buffering — HTTP response assembly currently does many small `sock:send()` calls; gather into an iovec or corked buffer before flushing (TCP_CORK / TCP_NOPUSH via setsockopt FFI)
- [ ] Zero-copy static file serving — `sendfile(2)` FFI wrapper for staticx; avoids read-into-Lua-string + write round-trip; meaningful for large files
- [ ] `writev` / scatter-gather — single syscall for header + body chunks; pairs with write buffering above; FFI wrapper + iovec builder helper
- [ ] Buffer pool — reusable fixed-size byte buffers (FFI `uint8_t[N]`) to eliminate hot-path string allocations in HTTP parser and response serialiser
- [ ] Header serialisation fast path — avoid `table.concat` + string interning on every response; pre-serialise static headers once, memcpy into buffer
- [ ] Profile-guided allocation reduction — run under `jit.p` / `jit.dump` to find top allocation sites before committing to specific optimisations

## testing

### property testing (`lib/test/prop.lua`)
- [x] QuickCheck-style property runner: `prop.check(desc, gen, fn)` / `prop.it(desc, gen, fn)` — 2026-03-11 (commit a5c2799)
- [x] Core generators: `gen.int(min, max)`, `gen.uint`, `gen.float`, `gen.bool`, `gen.byte`, `gen.string`, `gen.list(elem_gen)`, `gen.table(k_gen, v_gen)`, `gen.one_of(...)`, `gen.frequency({weight, gen}...)`, `gen.sized(fn)`, `gen.map(g, fn)`, `gen.filter(g, pred)`, `gen.constant(v)`, `gen.nil_or(g)`, `gen.tuple(gens)`
- [x] Shrinking: binary search on int ranges, element removal for lists/strings, field removal for tables
- [x] N configurable trials (default 100); on failure: print original + shrunk + seed for reproducibility
- [x] Integration with test runner: failures show in the same format as `it()` blocks; property names in output
- [x] Seed override via PROP_SEED env var for deterministic replay

### fuzz testing (`lib/test/fuzz.lua`)
- [x] Corpus-based mutation fuzzer: byte-flip, insert, delete, splice on seed inputs (2026-03-15)
- [x] Coverage-guided mode: track which branches fire (debug.sethook + branch bitmap); prefer mutations that hit new branches (2026-03-15)
- [x] Crash/error detection: wrap target in pcall; distinguish expected errors from panics (2026-03-15)
- [x] Corpus persistence: save interesting inputs to disk; resume across runs (2026-03-15)
- [x] AFL-style queue: round-robin queue; guided mode prioritises inputs that hit new branches (2026-03-15)
- [x] Integration with test runner: `fuzz.it(desc, fn, opts)` — failures appear in standard test output (2026-03-15)
- [x] Two modes: "fast" (pure random, no sethook overhead) and "guided" (coverage-guided) (2026-03-15)
- [ ] Integration with property testing: `prop.fuzz(gen, fn)` — use mutations instead of random generation when a corpus exists
- [ ] Shrinking: mutate + binary-search toward a minimal crashing input (currently reports first crash, not shrunk)

### coverage

Current: `luajit lib/test/cli.lua --coverage` does line coverage via `debug.sethook`. Gaps:

- [ ] **Statement coverage**: count each statement executed (finer than line — multiple stmts per line)
- [ ] **Branch coverage**: track both arms of every `if`/`elseif`/`else`, `and`/`or` short-circuit, `repeat`/`while`/`for` loop entry vs skip — report uncovered branches explicitly
- [ ] **MC/DC (Modified Condition/Decision Coverage)**: each boolean sub-condition independently affects the overall decision; required for aviation/automotive safety standards; needs AST instrumentation or symbolic execution
- [ ] **Path coverage**: enumerate feasible execution paths through a function; exponential in theory, approximate with DFS + budget
- [ ] **Coverage-gated CI**: fail if coverage drops below threshold; report per-file and per-function coverage delta

Branch coverage implementation sketch: instrument the AST (add synthetic nodes around branch points) or use `debug.sethook("l", ...)` + a per-function line→branch-id table derived from the parser. The v2 parser already produces a full AST, so AST instrumentation is the natural path.

### fixture / snapshot testing (`lib/test/fixture.lua`)
- [x] `fixture.run_dir(dir, runner, opts)`: discover `*.input` / `*.expected` pairs; run `runner(input)` → actual; diff vs expected; report failures with unified diff — 2026-03-11 (commit f5e9c7a)
- [x] `UPDATE_SNAPSHOTS=1` / `opts.update` mode: overwrite `.expected` files with actual output (snapshot update workflow)
- [x] Pluggable normalizers: `fixture.normalize.{strip_ws, crlf, sort_lines, compose}`
- [x] Binary fixture support: hex-dump diff on mismatch when content has non-printable bytes
- [x] Named fixture groups: `fixture.group(name, dir, runner)` wraps `run_dir` in describe
- [x] `fixture.check(in, exp, runner, opts)` — low-level single-fixture check without it() registration
- [x] `fixture.diff(expected, actual)` — LCS unified diff (pure Lua, O(n*m), capped at 600 lines)

## infra
- [ ] Formalize code style conventions — don't assume ~/git/lua conventions are correct, decide fresh
- [ ] `cr` binary entry point
- [ ] Third-party libs under lib/ must preserve original LICENSE

## LSP
- [x] LSP server (JSON-RPC over stdio) — `lib/type/static/lsp.lua`; stdio framing, initialize/shutdown/exit, textDocument/didOpen+didChange+didSave+didClose → publishDiagnostics. Full text sync. (2026-03-15)
- [x] Position → type query — `ctx.type_at` flat array {line,col,tid,...} populated by `infer_expr`; `type_at_lookup` in lsp.lua finds best match; `textDocument/hover` returns markdown type string. (2026-03-15)
- [ ] Incremental re-check — cheap scope invalidation so full reparse isn't needed on every keystroke
- [ ] Module-level type cache — avoid re-typechecking stdlib/imports on every edit; currently `check.clear_cache()` on every file change is correct but slow for large projects
- [x] Completion — scope-level name enumeration (module + stdlib + locals visible at module level); cursor-local scope completions need position-tracking infrastructure not yet built. (2026-03-15)
- [x] Completion: field completions after `foo.` — extract identifier before trigger, resolve in scope, enumerate table fields. (2026-03-15)
- [x] Completion: union/intersection field completions — table_field_items recurses into TAG_UNION/TAG_INTERSECTION members. (2026-03-15)
- [x] Go-to-def — `ctx.def_sites` (name_id → {line,col}) + `ctx.name_at` for identifier use positions; textDocument/definition handler in lsp.lua. (2026-03-15, within-file only; cross-file requires cri_loader integration)
- [x] Cross-file go-to-def for `require()` bindings — `ctx.require_sources` (name_id → module_name string) populated whenever `local x = require("mod")` is inferred. LSP go-to-def resolves module name to .lua / /init.lua file path and navigates there. Uses `rootUri`/`rootPath` from initialize. (2026-03-15)
- [x] Cross-module type resolution in LSP — `check.check_string_with_deps` added; resolves require() deps one level deep from disk (tries .lua then /init.lua). LSP uses this so hover/completions reflect actual module export types. (2026-03-15)
- [x] Signature help — `textDocument/signatureHelp` on `(` and `,` triggers; extracts callee from line prefix (simple, field, method calls), looks up function type in scope, returns SignatureInformation. (2026-03-15)
- [x] Cross-file go-to-def for fields — `x.bar` where x is a required module: navigate to where `bar` is defined in the module. Implemented via ctx.field_at flat array (stride 4: line/col/field_id/obj_id) populated in ExprRule[NODE_FIELD_EXPR]; find_field_in_ctx() scans AST; cross-file interns field name in module pool then scans module AST. (2026-03-15, commit 38f9a07)

## package manager
See `docs/pkg-design.md` for full design.
- [x] `pkg.lua` manifest format + parser — `lib/pkg/manifest.lua` (2026-03-16)
- [x] `crescent.lock` lockfile format + parser (hand-written TOML-like) — `lib/pkg/lock.lua` (2026-03-16)
- [x] Registry HTTP protocol (`pkg.rhi.zone` — simple GET index + tarballs) — curl-based v1 in `lib/pkg/install.lua` (2026-03-16)
- [x] Global cache (`~/.crescent/cache/<name>@<version>/`) — `lib/pkg/install.lua` (2026-03-16)
- [x] Install algorithm: resolve → fetch → link (hardlinks) → write lockfile — `lib/pkg/install.lua` (2026-03-16)
- [x] Lockfile fast path: dep/ name+version check → skip network entirely — `dep_ok` check in `lib/pkg/install.lua` (2026-03-16)
- [x] `--frozen-lockfile` for CI — `opts.frozen` in `lib/pkg/install.lua` (2026-03-16)
- [x] CLI: `cr add / install / remove / update / info` — `lib/pkg/cli.lua` (2026-03-16); `publish` not yet done
- [x] Semver parser (pure Lua, small) — `lib/pkg/semver.lua` (2026-03-16)
- [x] Multi-registry support with priority ordering and per-registry auth — `lib/pkg/config.lua` (2026-03-16)
- [ ] Fork-based parallel fetch with `--jobs=N` (default: CPU count) — v1 fetch is sequential
- [ ] `cr publish` — not yet implemented
- [ ] Package manifest `files` field — declare which files get installed (source only; tests, benchmarks, fixtures, docs stay in the repo). Installed footprint should be just the `.lua` files needed to run. Key to avoiding node_modules-scale bloat when vendoring.

## protocol rewrites — deferred

- [ ] **HTTP/1.1 server rewrite** — async, keep-alive (Connection: keep-alive), persistent connections. Blocked on socket layer rewrite.
- [ ] **HTTP/1.1 client rewrite** — connection pooling, redirect following, proper error recovery.
- [ ] **HTTPS rewrite** — module-level TLS state bug, `ffi.new("FIXME")` in serverx. Blocked on socket + TLS.
- [ ] **HTTP/2** (RFC 9113) — HPACK header compression, binary framing, stream multiplexing, flow control, server push. Major new implementation.
- [ ] **HTTP/3** (RFC 9114) + **QUIC** (RFC 9000) — UDP-based transport, 0-RTT, connection migration. Requires QUIC implementation first.
- [ ] **HTTP trailer fields** (RFC 9112 §7) — currently ignored in stream.lua chunks().
- [ ] **Transfer-Encoding: gzip/deflate** decompression in stream.lua.
- [x] **Path traversal audit** — `lib/http/router/static.lua` and `staticx.lua` use `path.safe_resolve()` (realpath + prefix check). No vulnerabilities found.
- [ ] **WebSocket: permessage-deflate** (RFC 7692) — compression extension.
- [ ] **WebSocket: max frame/message size policy** — currently unbounded, memory exhaustion risk.
- [ ] **WebSocket: client-side** — initiating connections (currently server-side only).
- [ ] **WebSocket: subprotocol negotiation** (RFC 6455 §4.2.2).
- [ ] **DNS: UDP client** (RFC 1035 §4.2.1) — 512-byte limit, TC flag, fallback to TCP.
- [ ] **DNS: EDNS(0)** (RFC 6891) — OPT pseudo-record, larger responses.
- [ ] **DNS: server implementation** — `lib/dns/server.lua` stub exists.
- [ ] **DNS: master file parser** (RFC 1035 §5) — `lib/dns/format_master_file.lua` stub exists.
- [ ] **DNS-over-HTTPS** (RFC 8484), **DNS-over-TLS** (RFC 7858).
- [ ] **Socket layer rewrite** — replace vendored ljsocket with cross-platform `lib/socket/` (POSIX + Winsock FFI). Prerequisite for proper async server, keep-alive, connection pooling.

## documentation (low priority now, high priority eventually)

- [ ] **Design crescent doc-comment syntax** — many `lib/` files use `-- @param`/`-- @return` in LDoc/Javadoc style as prose documentation. Before converting or deleting them, design a first-class crescent doc-comment syntax. Research prior art: LDoc (`-- @param name type desc`), Rustdoc (`/// text`), TSDoc (`/** @param */`), Julia docstrings (Markdown fenced above the binding), Haddock, Documenting Lua idioms in use across the corpus. Goals: (1) machine-readable enough for `lib/doc/` to generate HTML/JSON from, (2) composable with `--:` type annotations (types shouldn't be duplicated), (3) minimal syntax overhead — crescent has no multiline string syntax pressure. Candidate: `--| description` lines immediately after the function signature, with `--:` already providing the types. Write a design doc at `docs/doc-comment-design.md` before implementing anything.
- [ ] **Comprehensive library docs** — every `lib/` package documented: purpose, API reference, usage examples. Enough that someone new to the codebase can pick up any library and use it without reading the source.
- [ ] **Codebase directory files** — `OVERVIEW.md` or `index` files at key directories explaining the shape: what lives where, how pieces relate, what to read first. Not API docs — orientation docs. `lib/OVERVIEW.md`, `lib/platform/OVERVIEW.md`, etc.
- [ ] **Lua tutorial for beginners** — a crescent-flavored intro to Lua targeting people who know at least one other language. Covers the gotchas (no `++`, `1`-indexed, `local` scoping, metatables), the LuaJIT-specific bits (FFI, `bit.*`), and the crescent conventions. Lives at `docs/lua-primer.md`.

## lib/css

Type-safe CSS builder library. Lua table → CSS string. Pairs with `lib/html/html_builder` so web frontends write HTML + CSS in Lua, generated at server startup or request time. No build step. Design doc: `docs/css-design.md`.

- [x] **Phase 1 — Core type machinery, selector DSL, stylesheet builder, renderer.** Nominal newtype constructors (`css.class`, `css.id`, `css.var`, `css.anim`, `css.varref`), batch `css.declare`, composable selector DSL (`css.sel.*` + combinator methods), `css.rule`/`css.stylesheet`/`css.render`. Snake_case → kebab-case property normalization. CSS var keys (`--*`) left as-is. Deterministic output via sorted declarations. Files: `lib/css/init.lua`, `lib/css/css_test.lua`. 35 assertions.

- [x] **Phase 2 — Keyframe animations.** `css.keyframe_rule(name, stops)` where stops maps `"from"/"to"/percentage` keys to declaration tables. `css.render_keyframes(kf)` renders `@keyframes name { ... }`. The `AnimationName` nominal type from Phase 1 types `animation-name` property values so mismatched names are caught. Files: `lib/css/keyframes.lua`, extended `lib/css/init.lua`.

- [x] **Phase 3 — Media queries.** `css.media(query, items)` constructs `@media` rules. Query DSL covers `min-width`/`max-width`, `prefers-color-scheme`, `orientation`, and logical operators (`and_`, `or_`, `not_`). `css.render` extended to handle `_type = "media"` items. Files: `lib/css/media.lua`, extended `lib/css/init.lua`.

- [x] **Phase 4 — CSS custom property tooling.** `css.property(name, opts)` renders `@property` declarations (syntax, inherits, initial-value). Scope analysis: given a stylesheet and a set of `CssVar` names, report which rules declare vs. reference each variable. Useful for detecting undefined or unused variables at build time. Files: `lib/css/property.lua`.

- [x] **Phase 5 — lib/html integration.** Typed style injection into `lib/html` elements. Scoped class generation: given a stylesheet, emit a `<style>` block and return a record of typed `ClassName` values for use with `lib/html` element builders. Eliminates class-name string scatter from `lib/html/html_builder.lua`'s `mod.style`. Files: `lib/css/scoped.lua`.

## stretch goals (low priority, high reward)

*Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

- [ ] **Backend framework** (`lib/web/`) — high-quality, typed, idiomatic Lua web framework.
  HTTP server + router (lib/http already exists) + middleware pipeline + request/response types +
  SQLite ORM layer + templating. API inspired by Lapis/Sinatra but first-class crescent types
  throughout. Goal: write a web app in Lua that a Rails/Express developer finds familiar.

- [ ] **Games** — headless pure Lua game engines, each with CLI/TUI/web frontends.
  Pattern: library (rules + state + move gen) + `lib/minimax` AI + three frontends.
  Web frontend is a Lua HTTP server app (same pattern as card app — no build step).
  Type-safe builder APIs for constructing initial game state.
  - [ ] `lib/chess` — FEN/PGN, legal move generation, check/checkmate/draw detection
  - [ ] `lib/mahjong` — Riichi Mahjong, yaku/fu/han scoring, multi-player state
  - [ ] `lib/solitaire` — Klondike: tableau/foundation/stock/waste, auto-complete
  - [ ] `lib/spider` — Spider Solitaire: 1/2/4-suit, sequence completion, undo
  - [ ] `lib/freecell` — FreeCell: freecell/cascade/home rules, supermove, deal number

- [ ] **Genre battery design (Terraria/Minecraft/Factorio/zachlike/incremental)** —
  design doc written at `docs/genre-battery-design.md` capturing the owner's
  long-term direction (library-shelf composability, ~1000-line composition-
  glue budget, Factorio-style data/control-stage lifecycle, support for
  multiple mod-loader paradigms as separate libraries) plus a prior-art
  synthesis and internal library-quality audit. Nothing implemented: no
  mod-loader libraries, no reference cores, no fixes to any library issue
  the audit found. See that doc's "Prerequisites" and "Explicitly open
  questions" sections for what would need deciding before implementation
  starts.

- [ ] **Reactive frontend** — Lua implementation + optional TS deployment:
  1. `lib/reactive/` + `lib/reactive_optics/` are self-contained Lua libraries
  2. `lib/lua2ts/` can transpile them to standalone TypeScript (no Rainbow import)
  3. The transpiled TS is API-compatible with Rainbow so it drops into Rainbow-based apps,
     but crescent has zero runtime dependency on Rainbow — not even as an optional dep
  Rainbow (`~/git/rhizone/rainbow/`) is a parallel implementation of the same algebra in TS,
  maintained in the rhi ecosystem. Same relationship as Rust crates ↔ crescent libraries:
  peers, not wrappers. ~90 tests in Rainbow serve as a cross-implementation parity reference.
  TUI variant: `lib/tui/reactive` — same `lib/reactive_optics/` model, terminal renderer.
  Depends on `lib/tui/` and `lib/ansi/` first.

- [x] **FFI fixed-size-array element typing (typechecker prerequisite for accessor cleanup).** Fixed: `solve_index`'s LIT_INTEGER branch handled TAG_TUPLE but fell through to `unify(res, obj_tid)` for TAG_TABLE — so `t.data[N]` on `{[integer]: T}` returned the whole array. Added a TAG_TABLE branch in `lib/type/static/solve.lua` that (1) checks for an integer-named positional field, (2) consults integer/number indexers and returns the value type, (3) preserves the slot-0-is-self fallback for multi-return slot extraction. Closed >1000 pre-existing errors across `lib/type/static/*.lua` (e.g. constrain.lua 388→38, solve.lua 333→114, env.lua 138→12). Repro `ffi.cdef[[ typedef struct { int32_t data[7]; } S; ]]; local function f(t --: S) return t.data[0] end` typechecks cleanly.

### Authoring tools backlog

- [ ] **RPG Maker replacement** (2026-05-22) — offline-first, crescent-native RPG authoring tool; all features discoverable in-tool, no tutorials required to use core features (see docs/principles.md)
- [ ] **Ren'Py / visual novel authoring replacement** (2026-05-22) — offline-first, crescent-native VN authoring tool; discoverability in the tool, no online resources in the loop (see docs/principles.md)
- [ ] **Interactive fiction authoring tool** (2026-05-22) — Twine/Inform-class, offline-first, crescent-native; make interactive anything small, discoverable without tutorials (see docs/principles.md)

- [x] **Tuple positional-slot typing (parser representation bug, blocks cleanup C4+).** Fixed via option 1: parser emits `TAG_LITERAL(LIT_INTEGER, N)` keys for positional brace-tuple entries (`ann.lua` ~758-770, 833-844), and `constrain.lua` NODE_INDEX_EXPR defers literal-integer access on TAG_TABLE to C_INDEX so `solve_index`'s slot-aware branch (1404-1446) handles it instead of the legacy "first indexer wins" shortcut at 1627-1635. Consumer audit: `{ ...[%K]: %V }` distribution in `match.lua` already accepts LIT_INTEGER keys (match_pattern.lua:256 makes LIT_INTEGER match TAG_NUMBER patterns, so `IpairsReturn`'s `match K { number => ... }` still fires); `$EachField` only iterates named fields, not indexers, so unaffected; `table_meta_field` is unrelated. One pre-existing test asserting "unknown" for closed-record integer access updated to assert "nil" (correct out-of-bounds tuple-slot semantics). Pinning tests added in `type_soundness_test.lua`. Cleanup C4 unblocked. Expression-side companion fix landed: `constrain.lua` `NODE_TABLE_EXPR` was still emitting positional entries as stringified-integer FIELDS, so brace-tuple expressions `{ a, b, c }` didn't match brace-tuple type annotations. Now emits the same INDEXER + `TAG_LITERAL(LIT_INTEGER, N)` shape as the parser. Also surfaced a latent unifier gap: source-side excess indexers were never checked (`{ "a", 2 }` typed as `{ [number]: string }` passed), now covered by a new excess-indexer pass in `unify.lua` (mirrors the excess-field check; TAG_VAR/ROWVAR source keys are skipped because the b-driven loop binds them). Original entry: Brace-tuple annotations `{ A, B, C, ... }` were parsed in `lib/type/static/ann.lua:758-762` (and `:833-836`) by lowering each positional entry to an indexer pair `(TAG_NUMBER, T_i)`, discarding the slot number. Consequence: `c[N]` on a tuple cannot narrow to slot N's type — `solve.lua:solve_index` (around line 1404-1446) walks the indexer list and returns the FIRST positional indexer's value type for every literal-integer access. Variable-integer access has a separate sibling unsoundness: returns the first slot's type instead of the union of all slot types. Repro: `--:: T = { string, integer, boolean }; --: (T) -> integer; local function f(c) return c[2] end` should narrow to integer; today it returns string. Three fix options with different blast radius: (1) parser emits `TAG_LITERAL(LIT_INTEGER, N)` keys (smallest, reuses existing solve_index LIT_INTEGER comparison at 1428-1433); (2) parser emits named fields "1"/"2"/...; (3) unify brace-tuples with paren-tuples via TAG_TUPLE (which `solve_index` already handles correctly at 1396-1403; biggest change because it affects multi-return typing, spread handling, Parameters<F>/Tail<F>). All three need an audit of consumers that pattern-match indexer keys: `{ ...[%K]: %V }` distribution in `match.lua`, `$EachField`, `table_meta_field` spread expansion, ipairs/pairs typing, tuple-vs-array structural subtyping. Fuzz/grammar tests for positional slot precision needed before shipping. Discovered by the cleanup C4 attempt 2026-05-17; investigation report in that attempt's stop-and-report.

## Pedagogy / reader thesis + per-question typechecker (2026-05-31)

Backlog from the foundations session captured in `docs/foundations/pedagogy-and-the-reader.md`.

- [ ] Write the from-scratch documentation doc for `lib/check_kind` — the parser reuse rationale, the annotation-syntax decisions, the typechecking algorithm, and a from-scratch "how a typechecker works" — and make it trivially findable from the source files. (Blocked on the in-progress flatten refactor.)
- [ ] Build the marker→doc findability convention + a deterministic lint that proves the links resolve bidirectionally.
- [ ] Design and build the surprisal-coverage mechanism: an LLM leaf-oracle surprisal meter, a cached deterministic artifact, and a deterministic CI coverage gate.
- [ ] Resolve the two open foundational questions: the precise statement of "coverage", and whether leaf-oracle-as-meter is acceptable.
- [ ] Fix the stale comment in `lib/type/static/defs.lua` claiming `NODE_LITERAL` stores kind/value in `data[2]`/`data[3]` — the parser actually writes `data[0]`/`data[1]`.
- [ ] Decide and execute the disposition of the v5 typechecker and `docs/type-system-design/` (the 19-axis plan), now superseded by the plural per-question approach — formal retirement/cleanup.
- [ ] Pin v6 from `docs/typechecker-v6-plan.md`: value-movement matrix first, then implement thin verticals beside v4; v5 is research input, not the foundation.
- [ ] Build checker #2: pick the next property-question (candidates: table shapes, integer/float) and write its standalone checker.
- [ ] Land the deferred sub-checkers from checker #1: integer/float distinction, table shapes, literal refinement, generics, intersections, match types, multi-return.
- [x] Finish flattening `lib/check_kind` — the refactor into per-node-kind handler functions over an explicit `ctx` is mid-done but `ctx` has no explicit type annotation, so the checker can't unify its shape across handler call sites and emits ~26 typecheck errors; add an explicit `ctx` type, re-verify tests + typecheck, then integrate. **Ctx-type + re-verify part DONE** (this session, `refactor/check-kind-ctx-tables` branch): added an explicit `--:: Ctx` (7 fields: `nodes`, `lists`, `pool`, `report`, `ann_res`, `lower`, `line_ann`) plus `Scope`/`AnnRes`/`LowerCtx` aliases in `lib/check_kind/init.lua`, and threaded `--:` signatures through every `EXPR_HANDLERS`/`STMT_HANDLERS` entry and shared helper so they all agree on the shape. `timeout 30 bin/cr check lib/check_kind/init.lua lib/check_kind/lower.lua`: 26 → 0 errors (6 pre-existing "no signature" warnings on `lower.lua`'s internals remain, deliberately — see that file's own header comment). `bin/cr test lib/check_kind/`: still 20/20. Judgment call worth a second look: `ASTNodeArena`/`ASTNodeArena`-shaped `ListPool` aren't reachable from `ctx_types.lua` here (that file is explicitly self-check-only, see its header) and `--::` alias bodies resolve names eagerly (unlike `--:` signatures, which resolve lazily against cross-file inferred types — confirmed empirically), so a bare `ASTNodeArena` token doesn't resolve inside a `--::` body even though it resolves fine inside a `--:` signature. Mirrored `ASTNode`/`ASTNodeArena`/`ListPool` locally in `init.lua` instead, same pattern `lib/doc/init.lua`'s `DocCtx*` family and the `lib/type/v10_kernel/pilot/*` files already use for the identical shapes. **"then integrate" NOT done** — `lib/check_kind` is still not required/wired from anywhere else in the tree (`grep -rn check_kind lib bin` outside `lib/check_kind/` itself is empty); that's a separate, not-yet-scoped step.

## typechecker declarative core (2026-07-05)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

Open threads from the declarative-core session; details in
`docs/artifacts/2026-07-05-typechecker-declarative-core/open-threads.md`.

- [ ] H1: the middle derivation layer is still undefined (undecided undefinable without it; ◇-refutation witness object undefined) — shelf: Cousot calculational AI, 3-valued/abstract model checking, O'Hearn incorrectness logic.
- [ ] Uniformity class: whether the 2-safety framing is correct remains open (owner's standing "seems wrong" objection) — might need re-derivation; single-trace claim grammar cannot express it (H4).
- [ ] The mined-beliefs presupposition catalog ("form F presupposes φ") is unwritten — H5; only two examples exist.
- [ ] The process-killer gap: terminal states / increments / banking absent from all design material — untouched by the session.
- [ ] Bar negotiability: owner has not ruled on the Dialyzer point (consistency-only keeps lie-findings/behavior-output/never-reject; gives up proven-fine + dominance-over-tsc-truths).
- [ ] Convergence evidence: LLM-solver-simulation ruled inadmissible (owner-certified); requires human hand-run or a minimal real implementation (proposed: lib/json screen prototype + minimal chase over 10 labeled cases).
- [ ] Owner decision: does the ceiling-survey composite spine become the design direction (demoting the pool design from spine to layer)? See `docs/artifacts/2026-07-05-typechecker-declarative-core/research/ceiling-survey/judgment.md`.
- [ ] Owner decision: is the ceiling mandate ("unlimited short of uncomputable") the binding ambition? See `docs/artifacts/2026-07-05-typechecker-declarative-core/research/ceiling-survey/judgment.md`.
  2026-07-06 owner call: provisionally executing the entire composite (FP spine + all layers, pool demoted to claim-harvester) 'in some order or another'. Both items stay open — the wall execution hits is the evidence that closes them. No permanent spine/ceiling commitment made.
- [ ] Session-process context recorded nowhere durable except here: the previous session's owner stated preferences for frequent owner checkpoints with a bias toward stopping; that research must be problem-anchored, not incumbent-design-anchored (that session was corrected twice on this); that LLM hand-simulation of unimplemented machinery is not admissible evidence (also in open-threads.md); and that design work is currently quarantined from the bars ("bars irrelevant FOR NOW" — owner's words).
- [ ] owner: certify/reject abstract-kernel synthesis deltas (docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/synthesis.md)

## persona-prompt iteration (2026-07-05)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

`.claude/agents/me.md` / `general-purpose.md` were rewritten (commit `0a2e3917`) from a
structure that had grown one rule per annoyance into a file that says who the agent is — "a
friend who knows you, but not that well" — and says what to do rather than what not to.
Pre-rewrite drafts kept alongside as `.orig`.

- [ ] The new framing is untested in the wild: this session's own responses ran under an older draft, so there is no live sample of it yet.
- [ ] Open question: whether the new framing actually suppresses the habits it replaced (unearned praise, filler acknowledgments, narrating compliance, made-up option menus), or whether some of them need explicit mention again once there's live evidence. Any future edit should respect what the owner already said no to: a one-rule-per-annoyance structure, a detached "no stakes" identity, guard rules the identity already implies, and rules phrased as don'ts.
  2026-07-06 first live sample (session running under the rewritten persona), owner verdict: succeeded at 'superficial changes' (register, hedging words, friend framing), failed at 'literally everything that matters'. Failures observed in the orchestrator's own voice, not relays: issuing design verdicts without standing ('the encoding that actually answers your critique is...' — crowned an encoding one message before the owner showed it was wrong); grading the owner's own suspicion ('your special-casing suspicion — half right, in an interesting way'); session-coined jargon density; each successive apology itself a new confident (wrong) diagnosis of the failure. Pattern per owner: the confident conclusion is generated first and the persona's register is applied on top — 'the hedge decorates the overreach instead of preventing it' (agent's own description, owner did not dispute). Open question sharpened: promptable at all, or stop iterating the file.
- [ ] owner rule candidate (2026-07-06, owner's wording): 'ANYTHING undecided that affects semantics/behavior AT ALL, MUST halt.' Replaces unpromptable disposition ('don't be overconfident') with an auditable behavior (halt-on-underspecification). Supporting cases from this session: invert engine's UNDERSPECIFIED halt exposed a real design gap (good); harvester invented site string formats where design was silent → manufactured the misleading 100%-Open corpus number (bad); orchestrator invented design verdicts without standing (bad). Known hard case: the site-format choice looked cosmetic and was load-bearing — the rule's 'affects semantics/behavior' test must catch that class. Undecided: where to install (persona files me.md/general-purpose.md, CLAUDE.md delegation section, standard subagent prompt clause) — owner's call.
- [ ] Undecided, not discussed with the owner: whether sibling personas (v14, v15 agents) should inherit the new framing — do not presume either way.
- [ ] `.claude/settings.json` carries an uncommitted modification (owner's own mid-session hooks work, distinct from the hooks commits already landed) — owner's call whether/how it lands.

## Ecosystem priorities + platform design (2026-07-09)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

Roadmap and platform capability design notes were written this session. Key artifacts:
- `docs/artifacts/2026-07-08-roadmap/roadmap.md` — three priorities + overarching "crescent as the entire computer" vision
- `docs/artifacts/2026-07-09-platform-caps-design/notes.md` — capability model design principles with mined owner quotes
- `docs/artifacts/2026-07-08-toy-checker-findings/notes.md` — parked typechecker toy findings

### Priority 1: Scribble ideas → crescent

Import scribble's ideas (creative tool primitives) into crescent as core ecosystem libraries/apps. The old scribble design doc (`~/git/rhizone/scribble/docs/design.md`) is partially wrong per owner — primitives need fresh thinking, not cargo-culting from the old doc. The tool should be something people "just reach for" to make art (interactive or not). Imported ideas lose their special names and become core ecosystem capabilities.

- [ ] Design pass needed: what are the right creative-tool primitives for crescent? Not tilemap/sprite/spatial from the old doc — those are unexamined.
- [ ] Open: how does this relate to dusklight's projectional UI? Owner said "dusklight is the multi-projectional UI" but also "it is dusklight does not mean it is dusklight" — the idea matters, the codebase boundary doesn't.

### Priority 2: AI RP frontend

Non-conversational-context AI roleplay frontend, based on `lib/platform/`. Existing app at `lib/platform/apps/charactercardv2/`. Design pass needed — prior sessions may have design intent recoverable via `normalize sessions`.

- [ ] Design pass needed. Mine prior sessions for design intent on the RP frontend.
- [ ] The cap set for ccv2 (self, self_write, kv, time, http_server, llm, shared_db, create_instance) is the current working example of the platform cap model.

### AI RP frontend UX — persona-based mental model discovery (2026-07-16)

- [x] First batch personas: new-user, returning-user, multi-char-scenario, card-creator
- [x] Second batch personas (tool-specific): st-migrator, chub-browser, chatgpt-casual, kobold-local, talemate-narrative
- [x] Consolidated mental model analysis across all 9 personas
- [ ] Revisit conflicts: catalog-first vs import-first entry, engine visibility, single-target vs autonomous multi-actor
- [ ] Structured context construction vs embed-and-pray — crescent's persistence model advantage
- [ ] Test longer sessions: world-state grounding survival past context window, auto-progress director autonomy
- [ ] Outputs in `docs/artifacts/2026-07-16-ux-personas/`

Key insight from owner: ChatGPT dominates AI RP because of persistence (cross-conversation memory), not despite lacking it. The gap is character (stays in character, doesn't break fourth wall). Crescent's advantage is structured context construction over embed-and-pray retrieval. Mental models are discovered, not designed.

### Priority 3: Taskgraph

Agent harness as platform app. "Beyond SOTA agent harness by deleting the concept of an agent." Existing code at `lib/taskgraph/`. Design pass needed.

- [ ] Design pass needed.

### Platform capability model

Design principles established this session (details in the caps design notes):
- Swappability determines cap level (not I/O boundary, not service level)
- Attenuation narrows a capability before passing it on
- Construction assembles higher-level caps from lower-level resources + config
- DIP: app depends on cap interface, platform injects implementation
- Hot-swappability: cap implementations swappable at runtime
- Permission dialog: all caps require dialog, no silent grants, user-defined presets only (predefined presets unacceptable), compression to true decision points
- Sandbox: tarball modules load in sandbox so they are not an escape vector (not "so caps don't leak")

- [ ] Open: powerbox design was discussed in some prior session, possibly under other names — unmined.
- [ ] Unmined session dumps at /tmp/mine2.txt (48.6KB capability search) and /tmp/mine3.txt (29.6KB manifest search) — may contain additional design intent. Ephemeral; may not survive.

### Toy typechecker (parked)

Moded-obligation toy checker at `lib/toy_checker/` validated the approach at toy scale (43 assertions). Parked with findings written up. Key insight for future work: constraint structure is a graph (not a flat pool); real typecheckers use AST as the schedule; dynamic edge direction through shared variables is the open hard problem. Mode proliferation is static approximation of a dynamic property.

- [ ] Resume point: graph-structure insight as starting point, not mode proliferation workaround.

## conventions

- [ ] Adversarial audit of existing function names against naming convention (low priority)
- [ ] 2026-07-07 owner: design-it-twice skill removed. Grounds: 2026-07-06 evidence — 4/4 same-model 'decorrelated' candidates failed identically (flagship overclaim); supporting 'adversarial critique panel' numbers died in verification (aggregator gloss, no primary source); evidenced alternative is cross-model review + output verification (see docs/artifacts/2026-07-06-agentic-coding-research/agentic-coding-evidence.md). Open: whether design-an-interface and the CLAUDE.md 'decorrelate via parallel subagents' disposition line follow.

## Prior art survey — rhi ecosystem (2026-07-09)

Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.

- [ ] Survey all repos under ~/git/rhizone/ for ideas/functionality to subsume into crescent
- [ ] Survey all repos under ~/git/exoplace/ for ideas/functionality to subsume into crescent
- [ ] unshape (~/git/rhizone/unshape/) partially surveyed — see docs/artifacts/2026-07-09-userspace-exploration/unshape-xref.md
- [ ] dusklight (~/git/rhizone/dusklight/) discussed in roadmap — see docs/artifacts/2026-07-08-roadmap/roadmap.md
- [ ] scribble (~/git/rhizone/scribble/) discussed in roadmap — see docs/artifacts/2026-07-08-roadmap/roadmap.md
- [ ] marinada (~/git/rhizone/marinada/) — placement question open, see roadmap

## charactercardv2 conversations cap fallback (2026-07-16)

- [ ] **`lib/platform/apps/charactercardv2/server.lua:3387` fallback (`require("lib.conversation")`) is unreachable-by-design when `caps.conversations` is denied, and this is a substrate gap, not a one-line fix.** Traced via `bin/cr run lib/platform/cli.lua lib/platform/apps/charactercardv2 server`: the app runs under the full sandbox (`lib/sandbox/init.lua`), whose `require` whitelist is empty for every app (`lib/platform/cli.lua:585,1264`, `lib/platform/init.lua:645` all hardcode `modules = {}`). `lib.conversation` transitively pulls in `lib/sqlite.lua`, which does `require("ffi")` — whitelisting it would hand every app raw FFI access under a different name, violating the hard constraint in `lib/platform/CLAUDE.md` ("ffi is the ABSENCE of a sandbox... never on any whitelist, never grantable"). It also bypasses the per-app manifest grant/deny model, since the whitelist mechanism as currently implemented (`sandbox/init.lua:47-52`) is global across all apps, not scoped by manifest declaration — contradicting the cap system's per-app revocability. Real fix needs one of: (a) a pure-Lua (no-ffi) in-memory conversation store usable as an actual sandboxed fallback, (b) making `conversations` `required: true` in `manifest.json` and dropping the fallback branch entirely (the app just doesn't run without the cap), or (c) a per-app whitelist substrate keyed off manifest declarations rather than the current hardcoded-empty list. Not fixed in this pass — surfaced instead of guessed, per the no-special-casing / substrate-before-consumers rules. Also note: `lib/platform/CLAUDE.md` documents a `package.searchpath`-based whitelist load path (step 3 of the sandbox require process) that doesn't exist in code — the real whitelist path calls host `require(name)` directly (full host privilege), a second, separate discrepancy between docs and implementation worth reconciling.

## Cross-platform event loop (2026-07-09)

Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.

- [x] Vendor wepoll.dll in dep/ for Windows — done: `dep/wepoll/wepoll-x64.dll` and `dep/wepoll/wepoll-x86.dll` present
- [x] Implement kqueue backend for macOS — done: `lib/kqueue/init.lua` (284 lines, 6 passing tests)
- [x] Unify lib/epoll/ + lib/async/ — done: `lib/async`'s `loop(poller)` accepts an injected `io_poll` instance; `await_readable`/`await_writable`/`sleep` work end-to-end (133 passing assertions including poller-driven suite). Update 2026-07-22: this gap was already closed by the time it was checked — `lib/http/server.lua` turned out to already be a coroutine-per-connection async server wired through this exact integration (commit `2bd68565` and follow-ups, prior to this note being written). What actually remained was cleanup, not adoption: commit `8e161785` fixed an idle-timeout race (the keep-alive timer's callback could still fire and close a connection that had just read data successfully in the same poller tick; replaced with `async.race()` over the readable promise and the sleep timer, recording only the first settler), added `lib/http/server_concurrency_test.lua` (proves N concurrent handlers interleave rather than serialize), and removed the dead fork()-based `lib/http/server_fork.lua`, which had no remaining callers.
- [x] Update batteries.md async I/O gap — done: updated to reflect integration complete, gap reframed as adoption
- Note: batteries.md's #1 priority was AI-generated from first principles without checking the codebase; provenance traced to session fccf7f65 turn 22

## Three substrates + ecosystem audit + FTS5 + lua2ts ESM fixes (2026-07-16)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

- [ ] Roadmap now frames the ecosystem around three substrates instead of an app list: capture (pad-like, content-addressed), display (dusklight-like, address-agnostic), creation (scribble-like, identity-addressed, mutable object with no fixed schema — convention over spec). Library names for these substrates are undecided, the exact boundaries between them at the library level are undecided, and which to build first is undecided.
- [ ] An ecosystem audit mapped existing libraries against the three substrates' needs. Findings, roughly in order of how load-bearing they seemed: async + io_poll integration is the biggest cross-cutting gap (also flagged in batteries.md, and overlaps the "Cross-platform event loop" thread above — worth reconciling into one gap rather than tracked twice); the creation substrate has no composition/layering mechanism at all yet; a content-addressed blob store has the pieces (hashing, storage) but needs composition work to become a real library; `lib/reactive` and `lib/signal`/`lib/signals` look like unresolved duplication — worth checking whether these three are actually distinct in scope or need consolidating. On the solid side: hashing, sqlite, event_sourcing, transport (http/ws/unix socket), jsonrpc, and mimetype (real and working despite `docs/inventory.md` marking it "stub" — doc drift worth fixing separately).
- [x] `lib/lua2ts/`'s declared-global → ESM import gap (documented at TODO.md line ~1773, "declared globals don't resolve to ESM imports") is closed via `opts.global_imports` (option (b) from the two candidates written up there); the export-default and bare-top-level-return gaps next to it in that entry were fixed earlier this session (commit `0dbc9933`).
- [ ] User wants a `lib/platform/` app that multiplexes existing terminal PTYs into a web UI (tabs/tiling), reachable over tailscale from phone/TV, motivated by wanting to monitor ~10 concurrent claude code sessions remotely. Would exercise the async/io_poll gap, the lua2ts browser pipeline, and websocket streaming end to end — but whether this is the right thing to prioritize next, and its design, are both open.
- [ ] pad (`~/git/pad/`) was mined as prior art for the capture substrate — not a port target. Its design decisions were sorted into three buckets: mechanisms general enough to become crescent libraries, architectural patterns/conventions worth following, and app-specific policy that should stay out of `lib/`. Documented ingestion sources: stdin, shell, clipboard, git, file watch, browser extension, 19 output parsers. Pad has its own session history (all dated Jan 28–29 2026) that hasn't been fully mined yet.
- [ ] Browser targeting is settled as lua2ts (transpile Lua → JS) rather than VM-in-browser; pipeline is typecheck → transpile → hardened sandboxed iframe. `docs/platform_isolation.md` is explicitly a draft — cap naming, the JS subset allow-list, and bootstrap order are all still open, and Initiative B (lua2ts + projection-Lua) is gated on this doc's open questions per the existing entry around line 2498.
- [ ] FTS5 full-text search landed in `lib/sqlite` this session (commit `d7364b1f`); design findings from that work (also commit `51f62838`) are in the roadmap doc — worth checking they're reflected in `docs/inventory.md`/`docs/inventory_summary.md` if those are meant to be current.

## FFI library naming convention migration (2026-07-17)

- [ ] Migrate FFI library naming convention (medium-high priority)
  - New convention: all FFI wrapper libraries get `_ffi` suffix unconditionally (e.g. `lib/pty_ffi/`, `lib/epoll_ffi/`)
  - Split pure FFI bindings from their higher-level wrappers — the FFI lib is thin bindings only, higher-level API is a separate library that gets the short name
  - Existing libraries to migrate: epoll, kqueue, inotify, timerfd, process, sqlite (and any others that are thin FFI wrappers)
  - lib/pty_ffi/ is the first library following the new convention
  - This is a codebase-wide migration: rename directories, update all require() paths, update tests, update docs

- [ ] lib/pty_ffi/: de-inline openpty body from forkpty when multivalue narrowing gap is resolved
  - Workaround for: destructured multi-return narrowing doesn't propagate to sibling locals
  - See: docs/decisions/precise-narrowing-and-the-multivalue-model.md
  - The natural code is `local master, slave = openpty(); if not master then return nil, slave end`
    but the typechecker can't narrow `slave` to `integer` in the post-guard branch

## Async-first daemon rewrite (2026-07-19)

- [ ] Replace synchronous daemon with async-first architecture (lib/async + lib/io_poll)
  - Design doc: docs/daemon-async.md
  - Motivation: terminal mux needs WebSocket + PTY fd multiplexing + server-push, none possible in current sync request-response model
  - Phases: core loop → HTTP → WS upgrade → DaemonCtx cap convention → PTY cap → WS cap → terminal mux app
  - Preserves: all existing features (routing, sessions, caps, apps, rate limiting, sandbox)
  - Blocked: terminal mux platform app depends on this
  - See also: docs/terminal-mux.md for the driving use case

## Terminal mux app (2026-07-21)

- [x] WsAcceptFn/WsHandlerFn use `http_request` type but daemon mode passes `HttpReq` shape (with `.path`, `.query`)
  - terminal_mux works around this by parsing `req.target` via `split_target()`
  - The real fix is either: unify the types, or have the daemon construct a full `http_request` for WS handlers
  - Affects: lib/http/server_ws.lua (WsAcceptFn, WsHandlerFn type declarations), lib/platform/daemon/init.lua (clean_req construction)
  - Fixed: apps only ever see WsServerCap through the daemon's ws routing, which always
    normalizes the raw http_request into an HttpReq-shaped clean_req before calling the
    app's ws_accept/ws — so the app-facing contract (`WsServerHandlerTable` in
    lib/platform/caps/cap_types.lua) is now typed over `HttpReq`, matching what actually
    arrives. lib/http/server_ws.lua's own `WsAcceptFn`/`WsHandlerFn` (typed over
    `http_request`) are unchanged — they describe that module's real wire-level contract
    for direct/standalone callers, which is a different, correct thing.
    lib/platform/daemon/init.lua's `ws_handler_entry` now aliases `WsServerHandlerTable`
    instead of casting to `unknown`; `clean_req` is built to the full `HttpReq` shape
    (including `last_event_id = nil`, since WS never resumes SSE streams).
    terminal_mux/server.lua no longer needs `split_target()` — removed, along with its
    mirrored test block in terminal_mux_test.lua.

- [x] Vendor xterm.js in dep/ for proper terminal rendering (colors, cursor, alternate screen)
  - Current frontend uses `<pre>` with ANSI stripping — proves the WS+PTY pipeline but no real terminal emulation
  - xterm.js is the standard browser terminal emulator; needs to be vendored since CDN is blocked by CSP
  - Fixed: `dep/xterm-js/` vendors `@xterm/xterm@6.0.0` (`xterm.min.js`, `xterm.css`) and
    `@xterm/addon-fit@0.11.0` (`addon-fit.min.js`) as UMD builds, fetched via
    `bun add` — see `dep/xterm-js/README.md` for the exact re-vendor steps. Symlinked into
    `lib/platform/apps/terminal_mux/static/` (same convention as `lib/platform/apps/library/static/`),
    served via `caps.self.entry("static/...")` (new `self` cap in the app's manifest).
    Frontend now creates a real `Terminal` + `FitAddon`, writes raw PTY bytes straight to
    `term.write()` (xterm.js parses ANSI/VT itself — no more manual stripping), wires
    `term.onData` → binary WS frames and `term.onResize` (driven by `fitAddon.fit()` on
    window resize) → the existing JSON resize control message. Reconnect logic unchanged.
  - CAUTION for future vendoring in this environment: `bun add` without a local
    `package.json` walks up the directory tree and can install into a shared ancestor
    (e.g. `/tmp` if one has a `package.json` from an unrelated project) — always
    `bun init -y` in the target scratch dir first. Hit this live while doing this vendor;
    see `dep/xterm-js/README.md`.

- [x] Make terminal mux shell configurable via manifest cap config
  - Currently hardcoded to `/bin/sh` in server.lua DEFAULT_SHELL
  - Sandbox cannot read SHELL from the environment; needs cap config mechanism from manifest
  - Fixed: added `cmd` (+ `configurable_fields: ["cmd"]`) to the pty cap declaration in
    terminal_mux/manifest.json, defaulting to `/bin/sh`. `PtyCap` now carries a
    `default_cmd: string` field; `lib/platform/caps/pty.lua`'s `pty_cap(daemon_ctx, default_cmd)`
    takes the manifest-configured value (falling back to `/bin/sh` if unset) and exposes it
    as `cap.default_cmd`. `lib/platform/init.lua`'s pty cap factory passes `decl.cmd`
    through. terminal_mux/server.lua calls `caps_t.pty.spawn(caps_t.pty.default_cmd, ...)`
    instead of a hardcoded local constant. Operators can override per-app via
    `crescent caps <app_id> pty cmd=<shell>` (existing cap-config CLI).

## Roadmap, value landscape, and substrate architecture (2026-07-22)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

Session committed research work on strategic roadmap and ecosystem value analysis. The outputs are four docs (two research artifacts, two authoritative): `docs/roadmap-v2.md` (cleanroom), `docs/value-landscape.md` (synthesis), `docs/marginal-value-landscape.md` (derived analysis), `docs/marginal-value-landscape-cleanroom.md` (cleanroom analysis). All represent speculative research — no decisions yet, owner review pending.

- [ ] **Roadmap-v2 authorization and refinement.** `docs/roadmap-v2.md` is marked as the authoritative roadmap, sequencing library priorities informed by value landscape analysis. It phases: (1) production substrate (shipping infrastructure), (2) highest-value-category substrate (PDF, i18n, bookkeeping, document structure), (3) motivating applications, (4) speculative research. Typechecker correctly marked as parked, not in the ship roadmap. Owner has not yet fully reviewed details — may require adjustments before it serves as the effective strategic direction.

- [ ] **Value landscape synthesis — three docs, one canonical.** `docs/value-landscape.md` is the canonical synthesis of two independent analyses: `docs/marginal-value-landscape.md` (derived margins via market-research heuristics) and `docs/marginal-value-landscape-cleanroom.md` (cleanroom derived from first principles). The synthesis resolved two contentious classifications: offline/non-English as cross-cutting properties (not separate categories), and legal-navigation liability reframed as decisive (low tractability for solo dev, surfaces as "not viable yet"). Both research streams are speculative.

- [ ] **Self-expression/compression research — recorded, not acted on.** An exploratory conversation about self-expression as a civilizational structural absence (not a product gap) was written to `docs/self-compression-research.md`. Owner explicitly stated "sit with it, don't act on it yet" — no product implications derived, no downstream decisions made. Pure research.

- [ ] **Scribble as one of three substrates (reconfirmed).** Prior session had established pad (capture) / dusklight (display+control) / scribble (create/author) as the three-substrate model driving ecosystem priorities. This session reconfirmed the framing in roadmap work. Scribble needs a crescent-native authoring substrate informed by reincarnate's IR but not dependent on it — "the concrete thing drives the substrate" is the sequencing philosophy (substrate before consumers).

- [ ] **Dusklight subsumption scope — unverified.** Some folding/consolidation of features happened in a May session (`84df5cc5`), but the exact scope of what was subsumed was never verified against the current design intent. Worth auditing if/when dusklight work resumes.

## Roadmap-v2 Phase 1a/1b/2a work (2026-07-22)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

Worked the top three roadmap-v2 items in sequence: 1a (async I/O adoption), 1b
(TLS completion), 2a (PDF codec). Details of each below; see also the
"Vendoring gaps" and "Typechecker substrate gaps" sections earlier in this
file, and `docs/roadmap-v2.md` (updated same session) for the roadmap-level
framing.

- [x] **1a closed as cleanup, not adoption** — see the updated note on the
  `lib/epoll/` + `lib/async/` unify entry above (2026-07-19 section): the HTTP
  server was already async-multiplexed; the remaining work was an idle-timeout
  race fix, a concurrency test, and removing dead `server_fork.lua` (`8e161785`).

- [x] **1b: TLS architecture decision made — FFI-first, vendor libtls.**
  Commit `6ec2a858` vendors LibreSSL 4.3.2 portable source in full under
  `dep/libressl/` (checksum-verified, rebuildable offline) plus musl-linked
  Linux x86_64 binaries (`libcrypto.so.57`, `libssl.so.60`, `libtls.so.33`,
  `$ORIGIN`-rpathed so they resolve each other's SONAMEs regardless of where
  the directory lives) under `dep/libressl/linux-x86_64/`. `build-vendored.yml`
  gained a matching build job. `lib/tls/init.lua`'s loader tries the vendored
  path first, then falls through to system library search — same tier pattern
  as `lib/sqlite`. Pure-Lua TLS (the alternative floated in roadmap-v2 1b's
  "open question") stays in scope per the zero-dependency/pure-Lua-baseline
  principle but is explicitly low priority now that the FFI tier works for the
  common platform; other platforms (macOS, aarch64, Windows) still fall
  through to an unguaranteed system libtls — tracked in the "Vendoring gaps"
  section at the top of this file.

- [x] **2a: PDF codec — shared foundation plus both forms and text-extraction
  paths built.** Four-commit sequence (`c6ec40ff` object-model lexer/parser,
  `32d69333` xref table parser incl. xref streams + PNG predictor, `b68305d5`
  filter decoding + `lib/pdf/init.lua` top-level loader, then two parallel
  paths on top: `70c78a57` AcroForm field extraction/filling +
  incremental-update writing, `6824d63d` content-stream text extraction with
  font/encoding mapping and reading-order reconstruction). 388 assertions
  total across `lib/pdf/*_test.lua`. Explicitly out of scope, documented in
  each file's header rather than silently half-done: Type0/CID composite
  fonts beyond Identity-H/V + ToUnicode, per-glyph-width text advance (no
  `/Widths` parsing yet), non-FlateDecode stream filters, Object Streams
  (xref entry type 2), and AcroForm appearance-stream regeneration (needs
  font/text layout as a parallel effort). Five new typechecker substrate gaps
  surfaced and documented with workarounds during this work — see the four
  "Typechecker substrate gaps (found while implementing lib/pdf/...)" sections
  near the top of this file.

- [x] **2a follow-up: real-world-PDF gaps closed (2026-07-26).** Four
  commits: `98118941` ASCII85Decode/ASCIIHexDecode/RunLengthDecode/LZWDecode
  (+/EarlyChange) plus `/Filter`-array filter chains (chain order verified
  against pdf.js's `Parser#filter`, not assumed); `48c8138d` Object Stream
  (xref type-2) resolution — `lib/pdf/init.lua` now parses an ObjStm's
  "objnum offset" header and resolves compressed objects, not cached across
  calls (documented perf gap); `ff71d78f` `lib/pdf/font.lua`'s glyph table
  expanded from the ~246-entry subset to the full 4281-entry Adobe Glyph
  List (fetched at implementation time, machine-generated through
  `lib/encode/utf8` rather than hand-transcribed; values are pre-encoded
  UTF-8 strings so the 81 multi-codepoint AGL entries are representable);
  `71767c87` `/Widths` + `/FirstChar`/`/LastChar`/`/MissingWidth` parsing
  drives real per-glyph advance in `lib/pdf/text.lua` (falls back to the old
  w0-as-0 approximation when a font has no `/Widths`, and for Type0/CID
  fonts whose `/DW`+`/W` widths are a distinct range-based structure, still
  out of scope), and `spans_to_reading_order`'s line-grouping Y-tolerance is
  now font-size-adaptive instead of a fixed 3-unit constant. 470 assertions
  total across `lib/pdf/*_test.lua` (up from 388). Still out of scope,
  unchanged: Type0/CID composite fonts beyond Identity-H/V + ToUnicode
  (including CID `/W` widths), TIFF predictor (`/Predictor` 2), image-only
  filters (DCTDecode/CCITTFaxDecode/JBIG2Decode/JPXDecode), AcroForm
  appearance-stream regeneration.

- [x] **2a follow-up 2: CJK/CID font edge cases + remaining perf/predictor
  gaps closed (2026-07-26).** Three commits: `94792606`
  `lib/pdf/font.lua` CID `/DW`+`/W` width parsing wired into
  `code_to_width` for Identity-H/V Type0 fonts (code == CID needs no CMap
  resolution there); Type0 `/Encoding` support widened beyond
  Identity-H/V+ToUnicode to also cover the four predefined
  `Uni*-UTF16-H/V` CMaps (GB/CNS/JIS/KS collections — codes are already
  UTF-16BE code units by construction, no CID step needed for extraction)
  and a custom embedded `/Encoding` CMap *stream* using bfchar/bfrange/
  begincodespacerange syntax (the ToUnicode CMap parser, renamed
  `parse_cmap` and now shared, also derives codespace byte width from
  `begincodespacerange`); `/ToUnicode` now correctly takes priority over
  `/Encoding` for Type0 fonts unconditionally (previously errored on a
  non-Identity `/Encoding` even with `/ToUnicode` present). `0ad3f330`
  TIFF predictor (`/Predictor` 2, ISO 32000-1 §7.4.4.4) implemented in
  `lib/pdf/filter.lua` for 8-bit samples (sub-byte `/BitsPerComponent`
  still errors clearly — documented gap, real-world usage is
  overwhelmingly byte-granular; also fixed two stale xref_test.lua/
  filter_test.lua tests that had asserted "not yet implemented", replacing
  them with functional round-trip tests). Third commit (`efbc532b`):
  Object Stream caching in `lib/pdf/init.lua` — `Document` gained an
  `objstm_cache` field (self-healing: a hand-built Document literal
  lacking it still works, `get_objstm_cache` lazily attaches an empty
  one); `resolve_compressed_object` now decodes+parses each ObjStm once
  per document and reuses the cached decode (identity-checked in a new
  `pdf_test.lua` case) across further lookups into the same stream,
  replacing the previous "not cached across calls" documented perf gap.
  Follow-up fix (`8defefd7`): the new `objstm_cache` field is required on
  `lib/pdf/init.lua`'s `Document` type, but the typechecker treats the
  plain-record mirror aliases each of `lib/pdf/{font,text,form,write}.lua`
  and their `_test.lua` files declare for `Document`/`FormDocument`/
  `WriteDocument` as exact/invariant, not width-subtyped (the existing
  "type declarations don't cross require boundaries" pattern) — so every
  mirror alias and literal-typed doc fixture needed the field added too;
  a whole-directory `bin/cr check lib/pdf/*.lua` (not caught by
  single-file checks) surfaced 50 cross-file errors, all resolved.
  501 assertions total across `lib/pdf/*_test.lua` (up from 470,
  verified 2026-07-26). Still
  out of scope, unchanged: Type0/CID composite
  fonts under a predefined non-UTF16 CMap name or an embedded
  CID-producing (begincidchar/begincidrange) CMap, CID `/W` widths for
  any /Encoding other than Identity-H/V, sub-byte-sample TIFF prediction,
  image-only filters, AcroForm appearance-stream regeneration.

- [ ] **Terminal multiplexer implementation continuing.** Web-based terminal with PTY + WebSocket + VT state machine. Initial implementation in progress: WS frame format wired (commits `36712c59`, `eacf0650`), xterm.js vendored (`dep/xterm-js/`), shell configurable via manifest (`terminal_mux/manifest.json`), frontend rendering working. Next: streaming protocol hardening, connection state management, tab/tiling UX.

## lib/bidi bounded classification scope (2026-07-26)

- [ ] **`lib/bidi/init.lua` classification table covers a bounded subset of Unicode 17.0 `DerivedBidiClass.txt`, not the full 1.1M-codepoint file.** Covered ranges: ASCII + Latin-1 Supplement (U+0000-U+00FF), Hebrew (U+0590-U+05FF), Arabic (U+0600-U+06FF), Arabic Supplement (U+0750-U+077F), General Punctuation (U+2000-U+206F), Currency Symbols (U+20A0-U+20CF), Mathematical Operators (U+2200-U+22FF), Hebrew Presentation Forms (U+FB1D-U+FB4F), Arabic Presentation Forms-A (U+FB50-U+FDFF), Arabic Presentation Forms-B (U+FE70-U+FEFF). Codepoints outside these ranges default to L (the UCD `@missing` default for 0000..10FFFF). This means scripts like Thaana (U+0780-U+07BF, R), Syriac (U+0700-U+074F, AL), N'Ko (U+07C0-U+07FF, R), and others will be misclassified as L. Extending coverage: add ranges to the `RANGES` table following the existing pattern, sourcing from `DerivedBidiClass.txt` and cross-checking `@missing` block defaults.

- [x] **N0 (paired bracket resolution, UAX #9 rule N0) implemented (2026-07-26, commit `5653cfcb`).** BD16/N0 added to the pipeline (runs between W7 and N1), using a bounded bracket-pair table (`()`, `[]`, `{}`, angle/guillemet/CJK brackets) rather than full `BidiBrackets.txt` — consistent with the module's existing bounded-classification-table approach, so brackets outside the table still fall through to N1/N2 unchanged. 212 assertions total in `lib/bidi/bidi_test.lua` (verified 2026-07-26), including hand-traced N0 cases (b), (c1 "established opposite context"), (c2), (d), unmatched brackets, and nested pairs. Extending the bracket-pair table to the full `BidiBrackets.txt` set remains open but is now an extension, not a missing rule.

## lib/arabic joining/shaping bounded scope (2026-07-26)

- [ ] **`lib/arabic/init.lua` Joining_Type table covers only the Arabic block (U+0600-U+06FF) and Arabic Supplement (U+0750-U+077F), sourced from Unicode 17.0 `extracted/DerivedJoiningType.txt`; codepoints outside those ranges default to `U` (Non_Joining, the UCD `@missing` global default).** This means other joining scripts entirely outside scope — Syriac (U+0700-U+074F), Mandaic (U+0840-U+085F), N'Ko (U+07C0-U+07FF), Manichaean, Psalter Pahlavi, Mongolian, Phags-pa, Sogdian, Old Uyghur, Hanifi Rohingya, Adlam — are not classified at all (every codepoint in them reports `U`, i.e. "does not join," which is wrong for scripts that do cursive-join). Extending coverage: add ranges to `JOIN_RANGES` following the existing pattern, sourced from `DerivedJoiningType.txt`.
- [ ] **Presentation-form shaping (`shape_codepoints`) only covers the 33 base letters U+0621-U+064A that Unicode allocated `<isolated>/<initial>/<medial>/<final>` decompositions for in Arabic Presentation Forms-B (U+FE70-U+FEFF).** Letters correctly classified with a Joining_Type but outside that range — e.g. U+066E DOTLESS BEH, U+066F DOTLESS QAF, and the whole Arabic Supplement block (U+0750-U+077F, used for African-language Arabic-script orthographies) — have no presentation-form codepoint to shape into and are left unchanged at every position. This is a real Unicode block limitation (Presentation Forms-B was frozen to the 1991 Arabic repertoire), not something fillable by table extension the way the Joining_Type gap above is — the presentation-form codepoints simply don't exist. A correct fix requires moving off presentation-form codepoints entirely toward OpenType-style glyph substitution (explicitly out of scope per the task that created this module).
- [ ] **`apply_lam_alef_ligatures` (the mandatory LAM+alef ligature pass) is not composable with `shape_codepoints`, in either pass order.** Running it after `shape_codepoints` can't detect LAM because by then it has already been replaced by its own presentation-form codepoint. Running `shape_codepoints` after it misjudges the letter preceding the ligature, because the ligature codepoint falls outside `classify_codepoint`'s covered ranges and defaults to Non_Joining, hiding that it still accepts a join from its predecessor. Producing text that is both fully positionally shaped AND ligature-correct requires joining-aware ligature detection integrated into a single pass (treating the LAM+alef pair as one unit during neighbor resolution around it), which is not implemented — see the function's doc comment for the full explanation. Each of `shape_codepoints` and `apply_lam_alef_ligatures` is correct standalone.
- [x] **Digit-system substitution implemented (2026-07-26, commit `7c7c121b`).** `lib/locale`'s `M.digits_to_system(text, system)` does codepoint-offset substitution of ASCII 0-9 into Arabic-Indic (U+0660-U+0669), Extended Arabic-Indic (U+06F0-U+06F9, Persian/Urdu), Devanagari, Bengali, and Thai digit systems. `fa`/`fa-IR`'s `NUMBER_FORMATS` comment now points callers at this function instead of flagging it as missing. 135 assertions total in `lib/locale/locale_test.lua` (verified 2026-07-26). Works around a pre-existing `string.byte` narrowing gap (see the typechecker substrate gaps section near the top of this file, "found while annotating lib/vt/init.lua" section's third entry).

## lib/locale financial-format extension (2026-07-26)

- [ ] **`format_currency`'s `opts.space` and the per-locale suffix-space default are a coarse boolean (nbsp or nothing), not a per-currency-symbol convention.** Some currency symbols in `CURRENCY_DATA` already bake a trailing space into the symbol string itself (e.g. `CHF = { symbol = "CHF ", position = "prefix" }`), so `opts.space = true` on a prefix currency like CHF would double-space. Pre-existing data quirk, not introduced by the `space` option; not fixed here since it's out of the scope of adding the option itself.
- [ ] **CLDR-accurate accounting/financial number patterns are not implemented — `negative_style` (`"minus" | "parens" | "trailing_minus"`) is a fixed enum applied uniformly across all locales, not sourced from real per-locale CLDR `accounting` number-format patterns**, which additionally vary things this doesn't model (e.g. some locales use a different currency symbol or a red/colored rendering convention for negative accounting amounts, which has no representation in a plain-text formatter anyway).

## lib/bookkeeping persistence/import/report layer (2026-07-26)

- [x] **`lib/sqlite` bug: NULL in a non-trailing SELECT column truncated every column after it.** Found while building `lib/bookkeeping/store.lua` (round-tripping an account with a NULL `code`/`description` followed by a non-NULL `parent_id` silently dropped `parent_id`). Root cause: `sqlite.query`'s and `stmt_mt.rows`'s iterators built a `columns` table via `columns[i+1] = ...` for each of `col_count` columns, then did `return unpack(columns)` with no explicit range. Assigning `nil` to a table key never creates that key, so once any column but the last is NULL, `#columns` (which `unpack` falls back to) finds a shorter border than the true column count, truncating the return — including any non-NULL columns after the NULL one. Fixed in `lib/sqlite/init.lua` by passing the already-known `col_count` explicitly: `unpack(columns, 1, col_count)`. Regression tests in `lib/sqlite/sqlite_test.lua` ("NULL in a non-trailing column does not truncate..." for both `db:query()` and a prepared statement's `:rows()`).
- [x] **Typechecker substrate gap surfaced while fixing the above: narrowing of a captured upvalue does not survive closure capture.** `local col_count = sqlite_ffi.sqlite3_column_count(stmt) or 0` narrows `col_count` from `integer | nil` to `integer` in straight-line code, but the narrowing is lost inside the closure `sqlite.query`/`stmt_mt.rows` return (which captures `col_count` as an upvalue) — the closure body sees `integer | nil` again and fails arithmetic (`col_count - 1`) even though the exact same expression narrows fine outside the closure. Worked around with an explicit checked cast at the declaration site (`--[[: integer]]`), which fixes the variable's declared type before capture instead of relying on transient narrowing (see `-- TYPECHECKER WORKAROUND:` comments in `lib/sqlite/init.lua`). Revert to plain `or 0` once narrowing survives capture by a nested closure.
- [x] **OFX and QIF bank-statement import added (2026-07-26, commits `d22fdc35`, `8b37a118`).** `lib/bookkeeping/import_ofx.lua` is a tolerant SGML tag scanner for OFX 1.x `<STMTTRN>` transactions (unclosed leaf tags, always-closed containers); an unterminated `<STMTTRN>` block stops the scan but still imports every transaction found before the break, with a distinguishable error for what was left unscanned. `lib/bookkeeping/import_qif.lua` is a line-based parser for QIF `D/T/P/M/N/^` records; a required `!Type:` header is mandatory and a second `!Type:` section anywhere in the file is a fatal whole-import error (both per explicit owner decisions during review, to avoid silently commingling a different account's transactions), and an unterminated trailing record mirrors OFX's truncation policy. Both convert each transaction into a synthetic CSV-import row and delegate posting/error-collection to the existing `lib.bookkeeping.import.rows_to_entries`, so they inherit its account-matching and error-collection behavior rather than duplicating it. 305 assertions total across `lib/bookkeeping/*_test.lua` (verified 2026-07-26, up from the CSV-only baseline). This closes the "import from OFX/QIF" item `docs/roadmap-v2.md` previously listed as unconfirmed for 2c; CSV import (`a53347b9`) was already done. Two new typechecker substrate gaps surfaced during this work — see "Typechecker substrate gaps (found while implementing lib/bookkeeping/import_ofx.lua and import_qif.lua, 2026-07-26)" near the top of this file.

## Ideas & Speculative Future Work

*Backlog entries that are not yet scoped or committed. Included for context preservation and to avoid re-deriving open questions.*

- [ ] **Direct port of tex.web (Knuth's TeX) to Lua** — Speculative idea: transliterate from the WEB/Pascal source directly rather than write a fresh TeX-like engine from scratch. The goal of direct-transliteration is to avoid behavioral drift from Knuth's many edge-case decisions — TeX's 40-year value proposition is byte-identical output across implementations, and the TRIP test is the real bar for "is this TeX," not algorithm descriptions or partial reimplementations. Known open design questions (none yet decided):
  - **Source representation:** port from tangled Pascal output (closer to executable source) or from the WEB source directly, keeping Knuth's numbered section structure and inline commentary as documentation (valuable because all TeX literature cross-references by section number)?
  - **Memory model:** tex.web's memory is a manually-managed simulated heap (`mem` array with its own allocator). Porting that as-is vs letting Lua's GC handle allocation is a semantic-risk decision, not a free simplification — divergence in allocation order or collection timing could alter output.
  - **Control flow:** Pascal's `goto` and labeled-block-heavy control flow needs a principled translation strategy into Lua; converting to structured loops or emulating with explicit state machines both have correctness hazards.
  - **Arithmetic semantics:** Pascal fixed-width integer and real arithmetic with specific overflow behavior must be handled deliberately so it doesn't silently diverge under Lua's number semantics. 
  - **Scale and effort:** tex.web is ~26,000 lines / ~1,300 numbered sections — a large mechanical effort, not a quick prototyping project.
  - **Project scope:** undecided whether this would live as a crescent `lib/` or `dep/` candidate, or as a standalone/personal project entirely separate. If pursued inside crescent, would need to reconcile with crescent's zero-dependency + pure-Lua-baseline rules (e.g., the memory-model question is exactly the kind of semantic tradeoff those rules are designed to surface).

---

## Session handoff (2026-07-26)

**Phase 1 complete (async I/O + TLS Linux x86_64).** Phase 2 substantially complete (PDF codec + i18n + bookkeeping). Phase 3 substrate ready.

**This session (Phase 2 closeout):**
- 2a PDF: Real-world robustness — ASCII85/ASCIIHex/RunLength/LZW filters, Object Stream caching, TIFF predictor, CID font widths, Type0 CMap support (Uni*-UTF16-H/V + embedded CMaps). 501 assertions (up from 388).
- 2b i18n: Bidi complete (including UAX#9 N0 paired brackets), Arabic joining/shaping, digit-system substitution. Total: 212 bidi assertions, 135 locale assertions.
- 2c bookkeeping: Multi-format import (CSV/OFX/QIF) completed. Unified CSV conversion path prevents import-format duplication. Fixed real `lib/sqlite` NULL-truncation bug. 305 assertions total.
- 2d (already done): `lib/unified` mdast/hast/remark_gfm substantially built. Rescribe evaluated as prior art, not adopted as canonical.
- Phase 3 substrate: Fractal projection pattern ported to `lib/api-tree/` (op, api, merge_meta), `lib/type-ir/` (TypeRef), and `lib/ffi-ir/`. Conventions documented in `docs/roadmap-v2.md` "Strategic direction: Fractal projection pattern" and "Format library porting strategy" sections.

**Next session (Phase 3 work):**
- 3a: Personal finance app using fractal projection pattern. Start by defining the chart-of-accounts and report-structure tree once, then project to CLI output, web UI, export formats (CSV, PDF).
- 3b: Developer tools (MCP server, type search, pkg manager polish) using fractal projectors.
- 3c: Format conversion tool (optional; many conversions work today without Phase 2c PDF, but PDF completes the high-value set).
- Markdown consolidation: `lib/markdown` onto `lib/unified/mdast` as first test of canonical-parser-per-format convention.

**Typechecker is parked.** Per earlier verdict: autonomous agent-directed development discontinued. Existing legacy checker (v2/v3) gates all commits, working reliably. Resuming typechecker work requires either solving hard-problem in v9 lineage or finding fundamentally different approach — outside Phase 3 scope.

**SUPERSEDED (2026-08-09):** the above verdict is stale. The v10 cleanroom core campaign is active and has its own running decision record — see `docs/decisions/typechecker-v10-core-charter.md` and `docs/decisions/typechecker-v10-core-design.md` for current status (term algebra, kernel primitives, replayer/certificates, the flow-narrowing pilot, and the 2026-08-09 fail-fast campaign mode). This line is kept, not deleted, per the repo's no-delete-unchecked-TODO-items convention; it no longer reflects the typechecker's actual status.

**Unresolved design questions (from prior sessions, no product implications yet):**
- Self-expression as civilizational absence (`docs/self-compression-research.md`) — owner said sit with it, no decision needed for roadmap.

## y_crdt sync protocol (2026-07-27)

- [x] `lib/y_crdt/sync.lua` — y-protocols sync messages (SyncStep1/SyncStep2/Update), verified against upstream yjs/y-protocols `src/sync.js` (fetched via `gh api`, not the raw githubusercontent URL, which 404s for this repo). Message type tags (0/1/2) match the task brief's numbering exactly — no correction needed this time.
- [ ] **TYPECHECKER WORKAROUND in `lib/y_crdt/sync.lua`'s `M.handle_message`**: a tuple-union return type `(MessageType, string) | (nil, string)` narrows correctly on its *first* slot (`msg_type == nil` guard eliminates the failure arm for `msg_type`) but leaves the *second* slot (`payload`) typed `string | nil` rather than collapsing to the surviving arm's `string`. Confirmed with a minimal repro (`(string, string) | (nil, string)`, guard the first slot, then pass the second slot into a function declared to take plain `string`, or into a fresh `--[[: string]]`-cast local) — both still reject. A second, always-true-in-practice `if payload == nil then ... end` guard is the workaround in place. Revert to relying on the single first-slot guard once tuple-union arm narrowing propagates to every slot of the surviving arm.
- [ ] `lib/y_crdt/awareness.lua` + `awareness_test.lua` — not built this session (sync.lua was the stated priority and consumed the available time). Upstream reference already fetched and verified: `y-protocols/src/awareness.js` (`outdatedTimeout = 30000`; wire format per `encodeAwarenessUpdate`/`applyAwarenessUpdate`: `varUint count`, then per entry `varUint clientID, varUint clock, varString JSON.stringify(state)`; `state === null` signals offline/removal; `applyAwarenessUpdate`'s clock-comparison and "don't let a remote peer remove local state" rules would need porting, not just the wire codec). Open for a follow-up session.

## y_crdt wire-parity fixtures + bugs found (2026-07-27)

- [x] `lib/y_crdt/fixtures/` — real yjs 13.6.31 + y-protocols 1.0.7 (via `bun install`), `generate.js` producing deterministic (fixed client ids) binary fixtures + companion `.json` metadata for encoding primitives, updates, state vectors, and sync messages, committed to the repo. `lib/y_crdt/parity_test.lua` checks decode/encode/round-trip/convergence against them.
- [x] **BUG FIXED: `lib/y_crdt/integrate.lua`'s `M.integrate` resolved a wire-decoded item's inherited `parent` (from a neighbor, or from a pending-parent-id lookup) only into the local `parent0` — never wrote it back onto `i.parent` itself.** Found via parity_test.lua's `delete_middle` fixture: a THIRD chained item (inheriting parent transitively through a second item that itself inherited via this path) found `resolved_left.parent == nil` and was wrongly discarded as GC, silently dropping its content. Confirmed with a hand-built 3-item repro before fixing. Matches yjs's actual `Item.prototype.getMissing`, which assigns `this.parent = ...` as a side effect in every resolution branch (not just locally) — fixed by adding `i.parent = parent0` right after the resolution if/elseif chain, before the neighbor-commit step.
- [x] **BUG FIXED: `lib/y_crdt/update.lua`'s `M.encode_state_vector_from_table` sorted clients ascending; upstream sorts descending.** Verified against `node_modules/yjs/dist/yjs.cjs`'s `writeStateVector`: `array.from(sv.entries()).sort((a, b) => b[0] - a[0])`. Decode is order-independent so this never affected correctness, only byte-for-byte comparison against real yjs output. Fixed by flipping the insertion-sort comparison.
- [x] **BUG FIXED: `lib/y_crdt/text.lua`'s `M.to_delta` included null-valued attributes (from a format "close" marker) in a delta run's `attributes` table instead of omitting them.** The underlying decode was already correct — verified with a bun script that real yjs's own decoded `ContentFormat.value` for a close marker is JS `null`, not `undefined` — but real yjs's `YText.prototype.toDelta` treats a null-valued attribute as "formatting removed" and drops that key from the emitted run entirely (a presentation convention, not a wire-format difference). Fixed in `snapshot_attrs` by skipping any key currently holding `encoding.null`.
- [x] **"Item compaction" closed: `lib/y_crdt/transaction.lua`'s `M.cleanup` (called from `doc.lua`'s `M.transact` after every transaction) now implements both of yjs's transaction-cleanup passes, ported directly from `node_modules/yjs/dist/yjs.cjs`'s `src/utils/Transaction.js` (`cleanupTransactions`, tag v13.6.31):**
  1. GC (gated on `Doc.gc`, new `DocOpts.gc?: boolean` field, default `true` matching yjs's `Doc({gc:true})` default): every item in `txn.deleted_items` that isn't `.keep` gets its content replaced with a bare `content.deleted(length)` placeholder (matches `Item.prototype.gc` with `parentGCd=false` — this port has no recursive ContentType/ContentDoc child deletion, so `parentGCd` is never true here, unchanged scope cut).
  2. Merge (`M._try_merge_with_lefts`, unconditional): for every client touched by the transaction (a new or deleted item), a full right-to-left sweep of that client's struct array, cascading-merging adjacent same-client/same-deleted-state/mergeable-content Items into one — a direct port of `tryToMergeWithLefts`. Upstream runs this as three narrower passes (delete-set-keyed, state-advancement-keyed, and a split-retry list) instead of one full-array sweep per touched client; `transaction.lua`'s module header explains why the full sweep is a provably equivalent fixed point, not an approximation — merge conditions are purely pairwise-local, and untouched regions are already maximally merged by the same invariant after every prior cleanup.
  `parity_test.lua`'s `multiple_inserts`/`delete_middle`/`map_operations` fixtures are un-skipped and now assert raw byte equality against the real-yjs fixture (previously `T.skip`'d with content-only checks). `parity_fuzz_test.lua` (its existing bytes/content mode split, unchanged) passes at 200+ iterations across five seeds. `lib/y_crdt/update.lua`'s hand-restated `Doc` struct type gained the same `gc: boolean` field to match `doc.lua`'s.
  Two new `TYPECHECKER WORKAROUND`s in `transaction.lua` (documented at their definition sites, cross-referenced to the pre-existing `struct_store.lua`/`integrate.lua` copies of the same gaps): indexing `StructStore.clients[client]` infers `any` unless routed through an identity-function reset (matches `struct_store.lua`'s own `as_structs`), and `StructStore`/`Struct` are hand-restated structurally rather than `typeof`-captured from `struct_store.new()` (matches `integrate.lua`'s own `Item`/`SharedType` hand-restatement) — both because `Item` is self-referential (`left`/`right: Item | nil`) and a `typeof`-captured record loses precision on its own nested fields once self-reference is involved anywhere inside it.
- [x] **Formatting-gap cleanup closed (`cleanupFormattingGap`/`cleanupYTextAfterTransaction`), plus three layered bugs found while chasing it to 0 byte-mismatches against real yjs.** What shipped, in `lib/y_crdt/text.lua` unless noted:
  1. `cleanup_formatting_gap` (port of `cleanupFormattingGap`, YText.js tag v13.6.31): called inline at the end of `M.delete`, exactly like yjs's own `deleteText` — deletes now-redundant `ContentFormat` markers left by a delete. `cleanup_contextless_formatting_gap`/`cleanup_text_formatting` (ports of `cleanupContextlessFormattingGap`/`cleanupYTextFormatting`) back `M.cleanup_after_remote_apply` (port of `cleanupYTextAfterTransaction`), called ONLY from `update.lua`'s `apply_v1` — real yjs gates the whole pass behind `!transaction.local`, i.e. it only ever runs for remote-origin transactions, since a local `deleteText` call already cleaned up inline; `apply_v1` is this port's exact stand-in for "remote." `apply_v1` previously ran NO post-transaction cleanup at all (no GC, no compaction) — now also wired into `transaction.cleanup`, so remote-applied updates get the same treatment as local ones.
  2. **`find_pos`'s stopping condition didn't match yjs's `findPosition`/`findNextPosition`**: it always walked forward past trailing deleted/non-countable items to land on the next live countable item; real yjs stops the INSTANT the visible-count target is satisfied, which can land squarely on a live ContentFormat marker. Rewritten to match exactly (same file, `find_pos`). This silently shifted every insert/delete/format boundary past a leading format marker at the same position — for `M.delete`, that alone was enough to leave a redundant marker permanently outside `cleanup_formatting_gap`'s scan range.
  3. **`M.insert`/`M.format` never implemented `minimizeAttributeChanges`/`insertAttributes`/`insertNegatedAttributes`** (previously scoped out in this file's own header as "a size optimization, not a correctness requirement" — that assessment was wrong): skipping past a deleted item or an already-matching format marker changes which item new content's `origin`/`origin_right` reference, which is wire-visible even though it never changes visible content (e.g. `insert("q"); delete(0,1); insert("W")` — real yjs places "W" with origin = the deleted "q" item, not before it). Ported in full, including `Y.Text.prototype.insert`'s own wrapper behavior (not `insertText`'s): a plain `insert(index, text)` with no attrs argument INHERITS every attribute active at the insertion point (copies `pos.currentAttributes` verbatim); `insertText`'s own "force unmentioned active keys to null" step only fires on top of an attrs object the caller explicitly passed (even `{}`). This file's `attrs: {...} | nil` parameter maps directly onto that: `nil` inherits, a non-nil table (including `{}`) negates unmentioned active keys.
  4. **A split (`struct_store.get_item_clean_start`/`get_item_clean_end`) that's the ONLY structural change for a client in a transaction was silently skipped by `transaction.lua`'s merge sweep** (which only revisits clients appearing in `new_items`/`deleted_items`) — e.g. a redundant `format()` sub-range request needs zero new markers but still lands `count` inside an existing run, splitting it for no reason, and nothing else in that transaction touched the client. Real yjs's own `splitItem` unconditionally pushes the split-off part onto `transaction._mergeStructs` for exactly this reason. Added `merge_structs: Item[]` as a THIRD list on `Transaction` (`transaction.lua`, plus every module's hand-restated copy: `text.lua`, `array.lua`, `map.lua`, `update.lua`) — deliberately NOT folded into `new_items`: an earlier version of this fix did that (reasoning "any touched-client list works"), which broke `update.lua`'s `M.encode_v1`/`M.encode_diff_v1` (those encode `new_items` as genuinely-new wire content; a split-off tail is a repartition of already-transmitted content, not new content) — caught by `update_test.lua`'s multi-exchange convergence test regressing.
  Verified against real yjs (`fixtures/verify.js`, vendored yjs v13.6.31): 1550+ fuzz iterations across 13 seeds with zero byte mismatches (previously only checked via content-equivalence for any sequence with a delete). `parity_fuzz_test.lua`'s text mode now ALWAYS does byte-for-byte comparison (dropped the weaker "content" fallback for text specifically — array/map still use it, see the new entry below for why). New unit tests in `text_test.lua`: the original repro (`insert("J"); format(0,1,{italic:true}); delete(0,1)` collapses to fully-deleted), a still-needed-marker-survives case, the redundant-format-doesn't-split regression, `M.insert`'s inherit-vs-explicit-attrs distinction, and a direct (non-wire) unit test of `M.cleanup_after_remote_apply`'s contextless path.
  Not fixed, out of scope for this pass: `array.lua`/`map.lua` have the SAME split-registration gap (bug 4 above) at their own `find_pos`/delete-split call sites — unverified whether it's ever wire-visible for those kinds (their own fuzz mode stays two-mode, `content`-checked for delete/overwrite sequences, until this is verified and fixed the same way). Their `Transaction` aliases gained `merge_structs: Item[]` too (unused by either file) purely so a `txn` value threaded through both one of them and `text.lua` in the same `doc.transact` callback still type-checks — confirmed necessary via `array_test.lua`'s own nested-array-of-Text test regressing without it.
- [x] **`array.lua`/`map.lua` unmerged-split gap, confirmed and closed (2026-07-27).** `array.lua`'s `find_pos` (now taking `txn` as its first parameter) and `M.delete`'s own split call site now register the split-off tail into `txn.merge_structs`, mirroring text.lua's `find_pos`/`M.delete`/`M.format` fix exactly — the same "a split that's the transaction's ONLY structural change for a client gets silently skipped by `transaction.lua`'s merge sweep" bug, now closed for array too. `map.lua` needed NO code change: audited every `struct_store.get_item_clean_start`/`get_item_clean_end` call site reachable from `map.lua` (`M.set`/`M.delete`) and confirmed Map entries are always single-value Items (`content.any({value})`/`content.type(value)`, length 1) that get superseded-and-deleted on overwrite, never split — `map.lua` has no split call sites of its own, so the gap this entry tracked never applied to it; this is a genuine absence of the bug, not an unclosed gap. `parity_fuzz_test.lua`'s array/map modes now always byte-compare (dropped "content" mode and the `gen_array_bytes_ops`/`gen_map_bytes_ops`/single-insert-only op generators, matching text's own drop) — verified clean over 2350 fuzz iterations across 13 seeds (`FUZZ_SEED=1..5` × 150 iters, `FUZZ_SEED=101..808` × 200 iters — see below for the run commands) with zero byte mismatches. Full suite (`bin/cr test lib/y_crdt/`) passes, `bin/cr check lib/y_crdt/*.lua` clean (0 errors; pre-existing `update.lua` `any`-inference warnings untouched by this change).
  - **New, separate, still-open finding from this session: a whole-file typechecker inference-order/shape instability in `parity_fuzz_test.lua`.** Bisected directly: removing `run_array_iteration`'s dead "content"-mode `else` branch (unreachable now that `mode` is always `"bytes"`) makes THREE unrelated `doc_mod.transact(d, function(txn) ... end)` callback sites elsewhere in the same file (inside `apply_text_ops`/`apply_array_ops`/`apply_map_ops`, none of which call `run_array_iteration` or touch array specifically) fail to narrow their `txn` parameter from `unknown` (`doc_mod.transact`'s declared `fn: (txn: unknown) -> nil`) to the `Transaction` each callback body actually needs (`text.insert(t, txn, ...)`/`array.insert(a, txn, ...)`/`map.set(m, txn, ...)`) -- "value of type `unknown` must be narrowed before use". Restoring the dead branch (still calling `doc_mod.new`/`get_array`/`update.apply_v1`/`array.to_array`/`json.encode` even though `mode == "bytes"` always short-circuits past it) makes all three sites narrow correctly again, with no other change. This is the same class of bug several other TODO.md entries already document (e.g. the `table.sort` generic-pinning entry, the `pdf` `as_table`-per-file-inconsistency entry) -- unrelated code shape/count elsewhere in a file perturbing inference at a call site that never itself changed -- but is a NEW instance, not yet root-caused, and worth its own entry since it's reproducible via direct bisection (delete the `else` branch in `run_array_iteration`, rerun `timeout 30 bin/cr check lib/y_crdt/parity_fuzz_test.lua`, observe 3 errors return; restore it, observe 0). Workaround in place: `run_array_iteration`'s dead `else` branch is kept (marked with its own `-- TYPECHECKER WORKAROUND:` comment at the site) purely to keep the rest of the file's `unknown`-narrowing stable, even though it is never executed. Revert to the natural single-line `T.eq(lua_bytes, js_bytes, ...)` form (matching `run_text_iteration`/`run_map_iteration`, neither of which needed this workaround) once this instability is root-caused and fixed.

## v10 kernel term algebra (2026-07-27)

**SECTION-WIDE UPDATE (2026-07-29 canon swap): every file this section's items
reference (`term_algebra/shared.lua`, `reference.lua`, `fast.lua`,
`term_algebra_parity_test.lua`) was retired with the old core — see the "v10
canon swap executed" section at the top of this file. Items below whose content
is a TYPECHECKER gap remain open as checker gaps (their repros are still valid)
but no longer have an in-tree workaround site; items about the fast tier's
performance and the lazy-subst design question carry over as prior art binding
the fast-tier-rebuild-against-the-canonical-core follow-up (tracked in the
canon-swap section). Unchecked items are kept, per convention, with this note
as their status.**

- [ ] **TYPECHECKER WORKAROUND in `lib/type/v10_kernel/term_algebra/shared.lua`'s `declare_signature`**: the natural code is `for i, argspec_ in ipairs(argspecs) do` using the ipairs-supplied loop index directly (for both `args[i]` and diagnostic messages). Confirmed via minimal repro (`/tmp` scratch files, not committed): when a table value is narrowed from an index-signature-typed `unknown` field (`{ [string]: unknown }`'s `.args`, narrowed via `type(x) == "table"`) rather than declared as `unknown[]` directly on the parameter, `ipairs` over the narrowed table infers its index variable as `never` (only the index; the element/value variable narrows fine) — concatenating that index into an error string then fails with "cannot concatenate type `never`". A directly-declared `--: (x: unknown[]) -> ...` parameter does not exhibit this; only a field narrowed after the fact from a wider index-signature-typed unknown does. Worked around with an explicit manual counter (`local i = 0; for _, v in ipairs(t) do i = i + 1 ... end`) at both affected loop sites (`args`/`i` and `binds`/`j`). Revert to the natural `ipairs`-index form once this narrowing gap is fixed.
- [ ] **TYPECHECKER WORKAROUND in `lib/type/v10_kernel/term_algebra/fast.lua`'s `force_head`**: a self-recursive local function whose declared return type is a strict subset of its own parameter's tagged-union type (here: `Concrete` vs. `Term = Concrete | ThunkTerm`) loses that narrower return type on its own self-calls when the result is assigned to a local and then tag-narrowed, specifically when the function also opens with a negated tag guard (`if t.tag ~= "thunk" then return t end`). Confirmed with a minimal repro (a 3-concrete-variant recursive tagged union of the same shape, `/tmp` scratch file, not committed): the assigned local's type falls back to `any`, and every subsequent `.tag`-narrowing branch on it also falls back to `any`, which in turn makes each tag-guarded return arm reject returning a `nil` alternative that the DECLARED return type actually excludes. A non-recursive call (calling a different, already-typed function) or a same-type self-call does not exhibit this; only a self-recursive call with a strictly narrower declared return type does. Worked around with a checked cast restating the function's own already-declared return type at each self-call site (`force_head(t.base) --[[: Concrete]]`, `force_head(u) --[[: Concrete]]`) — not a force cast, since `Concrete` is exactly what `force_head` already promises to return. Revert to the plain self-call once this narrowing gap is fixed.
- [ ] **TYPECHECKER note (not a workaround, a usage correction) in the same file/function**: `assert(x, msg)` does NOT narrow `x` from `T | nil` to `T` afterward (confirmed via minimal repro — `assert(x, "no"); return x` on an `x: string | nil` parameter still rejects the return as `string | nil`). Any code relying on `assert` as a type guard must use `if not x then error(msg) end` instead, which does narrow. Not filed as a workaround since `assert`-as-type-guard was never a documented feature to revert to; recorded here so the pattern isn't reintroduced elsewhere in this module.
- [ ] **TYPECHECKER WORKAROUND (tool swap) in `lib/type/v10_kernel/term_algebra/term_algebra_parity_test.lua`**: the natural code for this file's random-term generator would have used `lib/test/arb.lua` — the properly-suited facility for generating well-sorted ABTs respecting operator binder valence, with shrinking — via a custom recursive `Arb` object (`{ generate, shrink }`) fed through `arb.assert`/`arb.it`. Blocked: `arb.assert`'s callback is generically typed `(...unknown) -> unknown`; narrowing that `unknown` callback parameter back to the generator's own concrete descriptor type (a tagged union, `Desc = VarDesc | MetaDesc | ZeroDesc | SuccDesc | AppDesc | LamDesc | Pair2Desc`) has no legal spelling in this checker. Two minimal repros confirm both halves of why: (1) force casts are unconditionally rejected — `local y = x --[[:! string ]]` on an `x: unknown` parameter errors "force cast — fix the upstream type annotation instead" even in the simplest possible case, no union/context involved; (2) checked casts FROM `unknown` are equally rejected — `local y = x --[[: SomeRecordType ]]` on `x: unknown` errors "cannot assign `unknown` to `SomeRecordType`: value of type `unknown` must be narrowed before use", i.e. only genuine runtime `type()`-conditioned narrowing collapses `unknown`, never a cast of either kind. Also separately confirmed while building the same file's `desc_arb` helper: `arb.lua`'s own private `Arb` type requires each field's function type to match invariantly/exactly (a table literal whose `generate` returns a strictly-narrower-than-`unknown` tuple type, e.g. `(Desc, nil)`, is rejected as "not assignable" against the `(unknown, unknown)`-returning `Arb.generate` slot, even though `Desc <: unknown` trivially) — worked around there by declaring `desc_arb`'s own return type to literally restate `Arb`'s `unknown`-typed shape rather than the sharper Desc-specific one. Given both blockers, this file drives its own typed generator from `lib/test/fuzz.lua`'s mutated byte strings instead (`fn(input: string) -> unknown` types cleanly end to end; FUZZ_SEED gives the same replayability arb.lua's PROP_SEED would have, minus shrinking — not implemented for this recursive ADT generator either way). This is scoped to this one file — nothing about arb.lua itself was changed, and other files unaffected by a custom-recursive-generator-through-a-generic-callback pattern (e.g. `term_algebra_test.lua`'s direct, non-generic use of `T.eq`/`T.ok` on already-`unknown`-typed values) are unaffected. Revert to arb.lua for this file once `Arb`-callback narrowing past `unknown` (or invariant-vs-covariant function-field assignability for a custom `Arb` literal) has a legal path.
- [ ] **TYPECHECKER WORKAROUND (upvalue-vs-parameter narrowing collapse) in the same file**: the natural code is a single top-level `build_from_desc(k, desc)` (and `force(k, t)`) taking the kernel instance `k` (from `kernel.new(...)`, itself typed `unknown` per `init.lua`) as an explicit parameter and calling `k.build_var(...)`/`k.shift(...)` etc. directly in its own body. Confirmed via a sequence of minimal repros against the real `kernel.new`: a local's precise inferred shape (richer than its `unknown`-declared nominal return type) is retained when (a) member-accessed directly in the SAME scope that declared the local, or (b) captured as an UPVALUE by a nested closure (even one defined inside a function that itself received the table as a parameter) — but collapses to opaque `unknown`, or to an incompatible narrower generic constraint inferred from a DIFFERENT unrelated use of the same local elsewhere in the function, the moment the table itself is passed AS A PARAMETER to another function (annotated `unknown` or left fully generic/unannotated — both fail identically) and member-accessed in that function's own body. A parallel attempt to fix this by giving `kernel.new` a real named `KernelInstance` return interface (rather than bare `unknown`) hit a SEPARATE wall: assigning a concretely-typed function (e.g. `reference.build_var: (integer,string) -> (VarTerm|nil,...)`) into a table-literal field declared with a more general signature (`(integer,string) -> (unknown|nil,...)`) is rejected outright — table-literal function fields are checked invariantly here too, the same rule already on file for `arb.lua`'s `Arb` type above; reverted that attempt. The actual, working fix: extract each needed METHOD as its own local at the call site (`local build_var_ref = k_ref.build_var`, while `k_ref` is still a fresh local in its own declaring scope) and pass those already-extracted FUNCTION VALUES — never `k` itself — into `make_build_from_desc`/`make_forcer`, two factories deliberately left WITHOUT a `--:` signature (re-adding one reintroduces the collapse) that close over the passed-in functions and return a `build`/`force` closure. Revert to a single top-level `build_from_desc(k, desc)`/`force(k, t)` taking the kernel instance directly once this narrowing gap is fixed.
- [ ] **TYPECHECKER WORKAROUND (same file, `recompute_ctx`) — the same self-recursive return-narrowing gap already on file for `fast.lua`'s `force_head`**: `recompute_ctx`'s own recursive self-call (`recompute_ctx(a.term)`) loses its declared `CtxMap` return type once assigned to a local and iterated (`for idx, s in pairs(sub) do`), making `idx`/`s` fall back to `unknown`. Worked around identically: a checked cast at the self-call site restating the function's own already-declared return type (`recompute_ctx(a.term) --[[: CtxMap ]]`). Revert once fixed (see the `force_head` entry above for the fuller repro).
- [x] **BUG FOUND AND FIXED via parity fuzzing: `lib/type/v10_kernel/term_algebra/fast.lua`'s thunk nodes carried no `.ctx`/`.ground` fields, crashing `shared.lua`'s `discharge_arg_ctx` (`bad argument #1 to 'pairs' (table expected, got nil)`) the moment any op-node reconstruction (inside `force_head`, or a caller passing an unforced term straight into the public `Inst.build`) handed a thunk as a child arg to the internal `mk_op`, which unconditionally reads `a.term.ctx`/`a.term.ground` to validate/merge/aggregate.** Found by `term_algebra_parity_test.lua`'s subst-parity and post-subst context-cache-correctness fuzz properties within the first 300-iteration run (`FUZZ_SEED=1785162367`, input `"\4\5\6\7"` — a `pair2` binder chain reached through nested substitution); reproduced deterministically via `FUZZ_SEED` replay before fixing. Fixed properly, not special-cased: every thunk now carries an exact `ctx` and `ground`, computed once at thunk-construction time in `mk_subst` — `ctx` via a new `ctx_after_subst` (a dedicated recursion mirroring `subst`'s own structural walk but threading only context maps, no node construction/interning, so it stays genuinely lazy — it skips any subtree that doesn't reference the substituted index, and forces one level at a time only along the "spine" that actually contains occurrences); `ground` via an exact O(1) formula (`base.ground and u.ground`, valid specifically in the "index occurs" branch mk_subst reaches). This is also a genuine improvement over the original design note: `is_ground`/`is_closed` were previously documented as forcing the whole term before answering (a scoped, deliberate non-O(1) tradeoff) — with every thunk now carrying exact cached fields, both are true O(1) again, matching the reference tier, so that prior tradeoff no longer applies and was removed from the module header. `mk_subst`/`force_head` gained a third mutually-recursive sibling (`ctx_after_subst`); all three are pre-declared as plain (unannotated) locals per the "requires an initializer" gap already on file, with their real signatures annotated at each's own `= function(...)` assignment instead. Verified: `bin/cr test lib/type/v10_kernel/term_algebra/` clean (184 assertions, both tiers), replayed clean across 6 additional `FUZZ_SEED` values (1, 2, 3, 42, 12345, 999999) at 300 iterations each across all parity properties.
- [ ] **PERFORMANCE FOLLOW-UP (measured, not a correctness bug — see `docs/perf/log.md` 2026-07-28 entry): `lib/type/v10_kernel/term_algebra/fast.lua`'s fast tier LOSES to the reference tier by 10x on a chained-substitution benchmark (50 steps, real work per step), the opposite of the module's own design intent.** Root cause: `mk_subst` forces its `base` one level at every call (needed for the ctx/ground fix above), and each of those per-step forces pays real interning overhead (a `tostring()`-based structural key, string concatenation, and an intern-table lookup per reconstructed node — plus a wasted `shift(u, 0, 0)` reconstruction of a term that never changes). For a chain of many small operations this constant factor dominates and outweighs the deferred-allocation benefit. Two candidate fixes, neither attempted yet: (a) replace the string-concatenation-based intern key with a non-string structural key (e.g. nested-table identity chains keyed on `(decl, child1, child2, ...)` without `tostring()`/string-concat at all); (b) re-scope the "lazy subst helps chains" design claim — it may only hold for chains that are fully built and forced exactly once at the end without any mid-chain context inspection, not the interleaved build-and-inspect pattern the benchmark (deliberately) exercises. `fast.lua`'s module header now documents this measured caveat instead of the unqualified original claim.
  **UPDATE 2026-07-28 (commit `6e243de3`, see `docs/perf/log.md` for the full writeup and raw numbers): candidate (a) attempted — partial win, not a fix.** Root-caused further first: the chain benchmark's interleaved subst-then-inspect pattern makes forcing at step i cascade into forcing still-unforced thunks embedded from steps < i, so BOTH tiers are actually O(n²) in node reconstructions for this access pattern (not O(n) as the original framing assumed) — the tiers differ only in per-node constant factor, not asymptotically, so no purely-constant-factor fix (interning key encoding, wasted-shift removal) can close the gap to parity; it can only narrow it. Replaced `mk_op`'s `tostring(decl)`/`tostring(child)` key with a decl-identity-keyed id (`decl_id`, table-keyed by the decl object itself — content-keying via `sig_name`/`sig_version`/`name` was tried first and was WRONG, breaking the "two signatures declaring the same-named op are different operators" invariant, caught by `term_algebra_test.lua` and parity fuzz) plus a per-node `iid`; also skipped the wasted `Inst.shift(u, 0, 0)` call in `force_head`'s op-branch at the one call site that can prove `bound_count == 0` statically (an internal optimization, not a change to `Inst.shift`'s own contract). Result: chain-case slowdown vs. reference reduced from ~13.4x average to ~11.3x average (5-run comparisons, same session) — real and verified (parity tests + fuzz across 10 `FUZZ_SEED` values clean throughout; other four benchmark cases' wins/losses unchanged within noise), but the module still loses to reference on this benchmark, so this item stays open. Candidate (b) — re-scoping the design claim itself — was NOT attempted; see the new design-question item below for why (owner-ratification territory, not implementation work).
  **UPDATE 2026-07-28, part 2 (commit `4d0266c2`): the same no-op-`shift`-skip pattern also applied to `match_at`'s non-linear check and `instantiate_at`'s metavariable-paste — both genuinely on replay's hot path (not just the adversarial bench).** The ratified spec (`typechecker-v10-core-design.md`) requires `equal(candidate, shift(stored, d'-d))` for non-linear match and "applies shifts per binding depth" for instantiate; both call `Inst.shift(x, offset, 0)` even when `offset == 0` (the common case), paying `shift`'s full force-and-rebuild-through-`Inst.build` cost for what is mathematically a no-op. Fixed the same way as the `force_head` skip: caller-side skip when the offset is provably 0, `Inst.shift`'s own contract untouched. Verified: parity tests + fuzz clean across 15 `FUZZ_SEED` values.
  **UPDATE 2026-07-28, part 3 (commits `232f0003` + `docs/perf/log.md`'s replay-shaped-benchmarks entry): built and measured replay-shaped benchmarks, per an owner-pressure-tested hypothesis that the chained-subst regression might be against a workload replay never executes. Result: mixed, non-uniform, reported without spin.** `instantiate-heavy` (many independent small `match`-then-`instantiate` rule applications over a growing shared fact chain — the canonical replay shape per the design doc's hot-path description) shows the fast tier winning 33-46x, consistently across repeated runs — strong validation for the workload replay's own hot path actually predicts dominates. But `compose-then-match` (the SAME `CHAIN_LEN`-step substitution composition as the adversarial bench, ending in ONE small rule-sized match instead of a full force — i.e., "compose many, observe once," NOT the interleaved-deep-inspection pattern originally assumed to be the culprit) STILL loses ~9-10x, nearly matching the adversarial bench's own cost. Root cause (confirmed, not the original "interleaved observation" theory): `mk_subst` forces `base` UNCONDITIONALLY on every call regardless of caller-side observation, and — for a term shaped like `var(i)` at depth `i` — stores the fully-FORCED result as each new thunk's `.base`, so the forcing cost compounds across a composed chain no matter when (or whether) the result is inspected. This is the SAME root cause and the SAME open design question below (thunk-of-thunk chaining), not a new one. `equal` citation-check (pairwise equal over a growing shared-prefix fact pool) came out roughly a wash (fast tier ~1.4-1.8x slower) — explained by these particular facts diverging at the top level, so there's no interned-pointer win to exploit either way; not evidence against the design, just a workload that doesn't exercise interning's strength. Bottom line: the fast tier's justification is workload-dependent, confirmed by measurement — strong for match/instantiate-heavy replay, weak for substitution-chaining regardless of when the chained result is observed. Whether replay's actual critical path chains substitutions this way is outside this cleanroom investigation's reach (would require reading `kernel.lua`'s replayer, excluded by the charter) — see the design question below, now updated to reflect this.
- [ ] **OPEN DESIGN QUESTION (surfaced 2026-07-28 while investigating the chained-subst regression above, not resolved — see `docs/perf/log.md` for the investigation): does `kernel-lazy-subst-sound-v1`'s "lazy subst helps chains" premise need re-scoping to exclude the interleaved build-and-inspect access pattern, or is a representation change (e.g. an explicit substitution-list/environment batching multiple pending substitutions into one thunk instead of one thunk per chain step) the intended way to cover that pattern too?** Both are ratified-semantics-or-representation-level calls, not implementation tweaks — out of scope for an implementation-only fix per the cleanroom charter's own rules (a change here would need to stay observably identical to the current tiers per parity, which a representation change of this kind likely cannot promise without becoming a NEW axiom/primitive needing its own registry entry and owner ratification, per `docs/decisions/typechecker-v10-core-design.md`). A related, narrower rejected experiment (`Inst.shift` short-circuiting at `d == 0` without forcing) is recorded in `docs/perf/log.md`'s 2026-07-28 follow-up entry as a concrete example of why "just make shift lazier" isn't a free implementation-level move either — `shift`'s current "always forces fully" behavior is itself something other code (`term_algebra_parity_test.lua`'s `make_forcer`) already treats as a load-bearing, relied-upon contract, not an incidental detail.
  **UPDATE 2026-07-28 (replay-shaped benchmarks, see part 3 above and `docs/perf/log.md`): the "interleaved build-and-inspect" framing this question was originally posed against turns out NOT to be the operative distinction — `compose-then-match` (composes many substitutions with ZERO intermediate observation, then ONE small match) loses by almost the same margin as the fully-interleaved adversarial bench.** The re-scoping question is therefore sharper than originally posed: it is not "does replay ever interleave deep inspection with substitution" (it doesn't, confirmed) but "does replay's actual critical path ever COMPOSE MULTIPLE substitutions on one term before using the result, versus always applying at most one substitution per match/instantiate step" — the latter is exactly what `instantiate-heavy`'s 33-46x win models, and if it's also what replay always does, the chaining weakness may be moot in practice without needing either re-scoping OR a representation change. This is a question about the replayer's actual call pattern (`lib/type/v10_kernel/replayer/replay.lua`, called "kernel.lua's replayer" here since it was written before the theories' conformance port — the retired `kernel.lua` this originally meant no longer exists, see the 2026-07-28 "theories ported onto the ratified core" TODO section above), which this cleanroom-scoped perf investigation could not answer at the time (charter excluded reading `replayer/` from the term-algebra-only perf work) — genuinely open, owner/replayer-side territory, not implementation work. The 2026-07-28 conformance port (`theories/algorithm_w.lua`, `theories/algorithm_j.lua`) exercises `replay.lua` via `match`-then-`instantiate` per rule citation, one substitution-free step per premise (no composed substitution CHAINS on the replayer's own hot path) — consistent with the `instantiate-heavy` benchmark's shape, not `compose-then-match`'s, though this is an incidental observation from the port, not a targeted answer to this question.


- [ ] Revert TYPECHECKER WORKAROUND in `lib/type/v10_cleanroom/term_algebra.lua` and
  `lib/type/v10_cleanroom/replayer.lua` (and the `set_field` fixture helpers /
  two-step unwraps in their `_test.lua` files): runtime guards are named
  predicates over `unknown` because a direct inline `type(x)` guard widens an
  annotated value to `unknown` instead of intersecting, and a new-field write
  to a record-typed value retroactively pollutes the record type at earlier
  use sites. Natural code = inline `type()` guards and direct field writes;
  revert when the checker intersects `type()` narrowing with existing
  annotations.

- [ ] Revert TYPECHECKER WORKAROUND in `lib/type/v10_cleanroom/replayer.lua`:
  replay memoization and the open/discharged sets are naturally Lua tables
  keyed by certificate-node objects, but index signatures only admit
  primitive key types (`{ [string]: T }` / `{ [integer]: T }`), so the memo
  is a parallel-array association, the sets are node lists, and the
  cycle-detection path is a linked list (O(n) lookup instead of O(1)).
  Revert to node-keyed tables when the checker supports non-primitive
  index-signature keys.

## Taskgraph top-down decomposition gap (2026-08-02)

- [ ] **`lib/taskgraph/` is bottom-up/spawn-only by design, not top-down.** `graph.lua`'s
  `M.add(g, task_def, parent_id)` lets a *running* task spawn children, and the
  combinators (`combinators.lua`'s `exec_map`, `exec_retry`, `refine`) operate over
  dynamically-spawned subtasks as they're added — there is no planner/decomposer that
  takes one large task description and breaks it into a subtask tree up front, before
  execution starts. Open question, not a decided feature: whether a top-down
  decomposition-first planning tool belongs in crescent at all (e.g. as a `taskgraph`
  addition, or as a separate agent-design tool), and if so where. Not committing to
  building it here — noted gap/open question only.

## Gamedev genre batteries pointer (2026-08-02)

- [ ] See `docs/batteries.md`'s "Games — planned genre batteries" section (under
  "Missing — application verticals") for the newly recorded future direction:
  incrementals, JRPGs, 2D tilemap/spritesheet games (connectivity/autotiling, with
  multiblock support an open question), physics engine expansion, playtesting tooling,
  balance-checking tooling, maybe inline custom text elements/text measurement, and
  wavefunction collapse. Recorded there as direction, not commitment — nothing here is
  started.

## lib/api-tree port — typechecker workarounds and open items (2026-08-03)

- [ ] Revert TYPECHECKER WORKAROUND in `lib/api-tree/result.lua`
  (`match_kind`): the natural signature is
  `<R>(kind: string, response: R) -> ErrorEncoder<unknown, R>`, which would
  carry the response type through to the composed encoder. It is rejected —
  inside a generic function, returning a closure whose own return type is
  `R | nil` fails with "`_` in union is not assignable to `_ | nil`". The
  checker does not accept an unsolved type parameter as a member of a union
  formed from itself; the identical NON-generic signature (`response: string`
  returning `string | nil`) checks clean, so the shape is not the problem.
  `response` is typed `unknown` instead, so callers must narrow what comes
  back out of the encoder. Restore the generic signature when this is fixed.

- [x] Revert TYPECHECKER WORKAROUND in `lib/api-tree/direct_test.lua`
  (`invoke`): `__call` metatables are not modelled. A table carrying a
  statically-visible `__call` cannot be called — `cannot call value of type
  `{} & { __call: ... }``. `direct.lua` projected a node that is BOTH a leaf
  and a branch as exactly such a table (a Lua function cannot hold child
  keys), so the natural caller code `api(input)` did not typecheck; the test
  fetched and invoked the metamethod by hand instead.
  **MOOT (2026-08-03):** investigation into the TS original (`direct.ts`)
  found this dual leaf+children shape barely load-bearing — it appears in
  exactly 3 identical test fixtures across the fractal monorepo, has no
  constructor that produces it (`op()`/`api()` each build only one half),
  zero production callers, and even in TS it forced an untyped
  `Record<string, any>` escape hatch. Owner decision: drop the `__call`
  metatable representation. A node with both a handler and children is now
  a plain table with a `handler` key (`node.handler(input)`) plus children
  as sibling keys — no metatable involved. The `__call`-modelling gap itself
  remains open in the typechecker generally but no longer applies to this
  code.

- [ ] `lib/api-tree/result.lua`'s `pipe` is imprecisely typed
  (`(a: unknown, ...(a: unknown) -> unknown) -> unknown`). The TypeScript
  original types `pipe` with a family of fixed-arity overloads, one per stage
  count, which is what lets each stage's output type flow into the next
  stage's input. Crescent has no overload mechanism and a variadic parameter
  takes a single type, so every stage is `unknown -> unknown` and each
  callback must narrow its own argument. `compose` beside it IS precisely
  typed. Not a workaround around a bug — a missing mechanism; revisit if
  overloads or variadic tuple types land.

- [ ] `collect` (the applicative record combinator, `index.ts`) is NOT
  ported — open question, needs a decision before it is written. It runs a
  record of field-producers and short-circuits on the FIRST failure, where
  "first" in TypeScript means `Object.keys` insertion order, derived from
  source declaration order. Lua tables carry no insertion order, and LuaJIT
  randomizes hash-table iteration per process, so which error a
  multiple-failure `collect` returns cannot reproduce the TS behavior and
  would not even be stable run-to-run under raw `pairs()`. The success path
  is unaffected — only error selection. Options, none chosen: sort keys
  (deterministic, but a different error than TS surfaces); require the caller
  to pass an explicit key order alongside the producers; or leave it out.

- [ ] `lib/result`'s design is flagged for a separate future review — its
  `{ _tag, _val }`-plus-methods representation is a different encoding from
  the `{ kind, value }` shape `lib/api-tree/result.lua` needs for wire
  compatibility with the TypeScript side, and the method-based approach was
  noted as worth revisiting on its own merits. Out of scope for the fractal
  port; `lib/result` is untouched by it. Not a decided change — a review item.

- [ ] `cache.ts`'s `checkCache` / `writeCacheMetadata` / `withCache` are not
  ported and are not portable as written: they are bound to `ts.Program` (they
  hash the source-file set a TypeScript Program parsed) and to Node's
  `require.resolve` (reading installed package versions as toolchain-identity
  signals). `lib/api-tree/cache.lua` ports only the fingerprinting layer. If a
  Lua-side incremental build cache is ever wanted, it needs its own design for
  the file-closure tier rather than a translation of these.

## lib/type-ir projectors — typechecker gaps and open items (2026-08-04)

Filed alongside the port of `type_ref_codegen`, `type_ref_kinds_common`, and
the rust-serde / wasm-bindgen / gleam-native / rescript-native projectors.

- [ ] Generic type parameters are not inferred from an index-signature
  argument. `type_ref.resolve` is `<T>(string, { [string]: T }) -> T | nil`;
  called with a `{ [string]: Converter }` the result types as `never` rather
  than `Converter | nil`. It stays invisible while the value flows into a
  declared `string` position (which is why `type_ref_gleam_native.lua` needs
  no workaround — its converter result goes straight into a `string` parameter
  or return), and surfaces as ``cannot concatenate type `never | string` ``
  the moment it reaches a concatenation. Three of the four projectors hit it
  and worked around it three different ways — see the consistency item below.

- [ ] A generic function's instantiation LEAKS ACROSS CALL SITES within a
  file: the second call is checked against the first call's solved `T`.
  Verified on a minimal repro — two `type_ref.resolve` calls, one passing
  `{ [string]: (string) -> string }` and one passing `{ [string]: string }`,
  fails on the second with ``argument 2: cannot pass `{ [string]: string }`
  where `{ [string]: (string) -> string }` expected``. Almost certainly the
  same root cause as the entry above (a solution cached per function rather
  than per call site). None of the four projectors trip it — each uses a
  single handler type — so there is no workaround to revert, but any file
  calling one generic with two different instantiations will hit it.

- [ ] The `T[]` sugar lowers to `{ [number]: T }`, which the stdlib
  declarations for `table.concat` and `table.sort` reject — they require
  `{ [integer]: ... }` (`lib/type/static/stdlib_types.lua:141`). So no value
  annotated `string[]` can reach `table.concat`. It only bites where a local,
  parameter, or return needs an explicit annotation; inference on a bare
  `local out = {}` produces the integer-indexed form and works.
  `type_ref_rust_wasm_bindgen.lua` and `type_ref_gleam_native.lua` each declare a
  `StringList = { [integer]: string }` alias (arrived at independently, same
  name); rust-serde and rescript-native spell the index signature inline. One
  fix covers all four. Marked `-- TYPECHECKER WORKAROUND:` in the two files
  carrying the alias.

- [ ] A trailing `--:` annotation after a MULTI-LINE table literal is silently
  dropped. The same annotation on a single-line literal is applied, and a
  `--[[: T]]` cast in that position works multi-line (the form
  `type_ref.lua:232-235` uses). Fails open, which is what makes it dangerous —
  it surfaced during the gleam port as an unrelated-looking downstream error
  rather than at the annotation. Repro:
  ```lua
  local WRONG = {
  	"a",
  } --: { [integer]: integer }
  --: () -> string
  function M.g() return WRONG[1] end   -- no error; annotation was dropped
  ```

- [ ] Index-signature keys accept only `string` / `integer` / `unknown`. A
  `Map` keyed by object identity (`Map<TypeRef, string>` in
  `rescript-native.ts`) has no spelling: `{ [TypeRef]: string }` parses as a
  record with one field literally named `TypeRef`. `type_ref_rescript_native.lua`
  types its hoist cache `{ [unknown]: string }` with a widening cast at the
  lookup. Runtime identity keying is unaffected; the type just no longer says
  what the key is. Deliberately NOT tagged `TYPECHECKER WORKAROUND` — it is a
  widening, not a behaviour-preserving detour.

- [ ] DECIDE: whether the four projectors should share one spelling of the
  index-signature-inference workaround. They currently differ —
  `type_ref_rust_serde.lua` uses a `--[[: Converter | nil]]` cast at each call
  site, `type_ref_rust_wasm_bindgen.lua` routes through a `converter_for(kind)`
  wrapper with a concrete return type, `type_ref_rescript_native.lua` uses a
  `--: Converter | nil` annotation on the result, and
  `type_ref_gleam_native.lua` carries no workaround because its call sites
  never reach a concatenation. Each is locally minimal and correct, and no
  file carries a workaround it does not need — that is the argument for
  leaving them alone. The argument against is that eight more ffi-ir backends
  and every future projector will read these four as canonical and copy
  whichever they happen to open first. Not resolved during the port because
  the tradeoff is a repo-preference call, not a source-determined one.
  Whichever way it goes, it is cheaper to settle before the next projector
  lands than after.

- [ ] `type_ref_codegen.lua`'s module path is a placement call, not a
  source-determined one. fractal's `codegen-helpers.ts` is not a dialect, so
  it did not fit the `type_ref_<dialect>.lua` pattern the projector files use.
  Rename is a one-line change per requiring file while there are only four of
  them.

- [ ] Only the subset of `codegen-helpers.ts` these four projectors need is
  ported (identifier casing, `is_a`, `quote`). The per-ecosystem doc-comment
  renderers, `indent4`/`indentLines`, `resolveOptions`, `goFieldIdent`, and
  `toCamelCase*` are unported — they belong with the projectors that use
  them, none of which are ported yet.

- [ ] `type_ref_rust_wasm_bindgen.lua`'s `field_type` returns a `rust_name` no
  caller reads. Dead in `wasm-bindgen.ts` too, kept for fidelity during the
  port. Drop it, or keep it deliberately and say why.

- [ ] `kinds/refinements.ts` is not ported and has nothing to port: it
  declares branded TS types (`MinLength<N>`, `Pattern<P>`, …) that exist only
  for `from-typescript.ts`'s static analysis to read back as `meta` keys. No
  IR kind, no runtime value, no emit. Same for `semantic-strings.ts`'s
  `Uuid`/`Uri`/`Email` brand types. If a Lua-side ingester that recovers
  refinements from annotations is ever wanted, it needs its own design.

- [ ] `gleam-native.ts`'s hoisting-section comment overstates what the code
  does: it claims declarations are hoisted from "a field, array/list element,
  tuple slot, or map key/value", but the code hoists only from field and
  array/stream/page element positions — a nested object in a tuple slot or a
  map value renders `Dynamic`. Confirmed by running the TS.
  `type_ref_gleam_native.lua` reproduces the CODE's behaviour (two tests pin
  it) and flags the discrepancy in its header. Worth reporting upstream to
  fractal; if fractal treats it as a bug and fixes the code, the port follows.

- [ ] Field/key emission order across all four projectors is byte order, not
  the JS insertion order fractal emits — the precedent `type_ref.lua`'s
  `ordered_keys` set, for the same reason (Lua has no insertion order to
  recover). The emitted SET is always identical. In
  `type_ref_rescript_native.lua` it can additionally shift a hoisted type's
  NAME, not just line order: with field hints colliding at one base name, the
  byte-first field claims the unsuffixed name where fractal gives it to the
  insertion-first one. A test pins the `home_address` / `homeAddress` case.
  Only matters if byte-identical output against fractal ever becomes a
  requirement rather than a target.

- [ ] Revert TYPECHECKER WORKAROUND in `lib/ffi-ir/init.lua`
  (`ownership_of`) and `lib/ffi-ir/rust_wasm_bindgen.lua`
  (`declared_discipline_kind`): a `type(rec.kind) ~= "string"` guard on an
  `unknown`-typed record FIELD does not narrow that field to `string`, so the
  post-guard value still can't be returned/reused where the field's narrowed
  type is expected. Both sites work around it by casting the WHOLE record
  (`discipline --[[: OwnershipDiscipline]]` / `(discipline --[[: { kind:
  string, ... }]]).kind`) rather than relying on the field narrowing. Minimal
  repro (no project dependencies):
  ```lua
  --:: Rec = { kind: string }
  --: (r: { kind: unknown }) -> Rec | nil
  local function f(r)
      if type(r.kind) ~= "string" then return nil end
      return r  -- error: field `kind` is still `unknown`, not narrowed to `string`
  end
  ```
  Revert both sites to a direct `rec.kind`/`discipline` read, dropping the
  whole-record cast, once a `type(x) == "string"` check on a record field
  narrows that field.

## lib/api-tree CLI projector — omissions, typechecker gaps, open items (2026-08-04)

Filed alongside the port of fractal's `packages/cli-api-projector`
(`src/cli.ts` + `src/completions.ts`) to `lib/api-tree/cli_projector.lua`.

- [ ] `CliOpts.validators` is NOT ported. It wires generated validators onto
  the tree through `wrapValidators`/`isValidatorWrapped`
  (`packages/api-tree/src/build.ts`), which has no counterpart in this repo —
  there is no generated-validator pipeline to wire. The projector's
  schema-derived `coerce_input`/`apply_defaults`/`validate_required` path is
  what TS uses for every leaf a generated validator does NOT cover, so the
  ported behavior is complete for the uncovered case and simply absent for the
  covered one. Same treatment `cache.ts`'s `ts.Program`-bound entry points got.
  Port `build.ts` first if this is ever wanted.

- [ ] `CliOpts.als` is NOT ported. It runs the handler inside an
  `AsyncLocalStorage` context (`packages/api-tree/src/context.ts`); Lua has no
  ambient async-context mechanism and none is ported. `opts.middleware`
  carries the same cross-cutting concerns explicitly through `stores`, which
  is what the TS doc already recommends for anything a middleware needs to
  read. Revisit if an async-context substrate is ever built.

- [ ] **Typechecker: a RECURSIVE call's result is typed `never`, ignoring the
  function's own declared return type.** Found while porting
  `describe_field_type`. Minimal repro, no project dependencies:
  ```lua
  --:: S = { t?: string, items?: S }
  --: (fs: S) -> string | nil
  local function describe(fs)
      local items = fs.items
      if items ~= nil then
          local it = describe(items)          -- typed `never`, not `string | nil`
          if it ~= nil then return it .. "[]" end
      end
      return fs.t
  end
  ```
  → ``cannot concatenate type `never` ``. The identical call to a
  NON-recursive function of the same signature checks clean; writing the
  recursion through the module table (`M.describe`) instead fails identically,
  so it is the recursion, not the binding form. **Worked around** in
  `lib/api-tree/cli_projector.lua`'s `describe_field_type` by casting the
  recursive call's result to the function's own declared return type
  (`--[[: string | nil]]`), flagged in-file as `TYPECHECKER WORKAROUND`.
  Delete the cast once a recursive call is checked against its declaration.

- [ ] **Typechecker: a narrowing predicate does not stick to a local that is
  REASSIGNED later in the same function.** `local ok, res = pcall(...)`, then
  `if is_stream_value(res) then use(res) end`, then further down
  `res = unwrap_result(res, ...)` — the use inside the branch reports `res` as
  `unknown`. Deleting the later assignment makes it check clean, so the
  reassignment retroactively defeats the earlier narrowing. Same family as the
  "a local REASSIGNED inside a conditional branch is typed `nil` at a
  method-call receiver" entry above. **Worked around** in
  `lib/api-tree/cli_projector.lua`'s `run_cli_async` by binding a fresh
  `streamed` local for the sniff, flagged in-file. Collapse it back once
  narrowing survives a later reassignment.

- [ ] `lib/levenshtein`'s `M.distance` carries no `--:` signature. Its return
  type therefore crosses the module boundary as an unsolved variable: at a
  consumer, `local d = levenshtein.distance(a, b)` narrows to `never` under
  `d ~= nil` and to `_ | integer` under `or 0`, so the value cannot be
  compared with `<` in any formulation. `lib/api-tree/cli_projector.lua`'s
  `closest_enum_match` states the type with a `--[[: integer]]` cast at the
  call site. The real fix is annotating `lib/levenshtein/init.lua` (note that
  file already reports 5 errors of its own, so annotating it is its own piece
  of work). Drop the cast once `distance` is annotated.

- [ ] `lib/async`'s `M.cancellable` (and so `M.async`) packs its arguments
  with `{ ... }` and replays them with `unpack`, so a NIL argument anywhere in
  the list truncates every argument after it. An async function taking an
  optional middle parameter silently receives `nil` for everything following
  it — a runtime hazard with no type-level signal. Hit while porting
  `--all-pages`: `stream_all_pages(first, input, ..., paginated_meta, caps)`
  lost `caps` whenever a leaf had no `meta.cli.paginated`. **Worked around**
  in `lib/api-tree/cli_projector.lua` by bundling the walk's arguments into a
  single `PageWalk` table. The general fix is `select("#", ...)` plus an
  explicit count in `cancellable`, at which point the bundle can stay or go on
  its own merits.

- [ ] `run_cli`'s missing-capability guard has NO test. Every formulation of
  "call it with an incomplete caps table" is rejected at check time — directly,
  through `pcall`, and through a force cast (refused outright) — so the guard
  can only be exercised by a caller the typechecker does not see. Noted in
  `lib/api-tree/cli_projector_test.lua` where the test would otherwise sit. A
  mechanism for deliberately-ill-typed call sites in tests (the thing
  `lib/fsm/fsm_test.lua`'s force casts predate) would close it.

- [ ] Two behavioral divergences from the TypeScript source, both documented
  in `lib/api-tree/cli_projector.lua`'s header, both forced by the substrate
  rather than chosen:
  - Numeric flag coercion uses Lua's `tonumber`, not JS's `Number`. `""`
    (JS: 0) and `"Infinity"` (JS: Infinity) are rejected here.
  - `lib/json` fails on a value it cannot encode where `JSON.stringify`
    silently drops it, so an unencodable result surfaces as a `cli_error`
    rather than as a lossy `{}`. Visible when stream detection is disabled and
    a stream value reaches the ordinary output path.

- [ ] Output key order is SORTED, not authored. The TS source relies on JS
  object insertion order for command listings, completion levels and JSON
  bodies; LuaJIT randomizes hash iteration, so `lib/api-tree/cli_projector.lua`
  sorts every child-name walk and passes `sort_keys` to `lib/json` — the same
  answer `cache.lua` gives to the same problem. Byte-identical output against
  fractal is therefore not achievable for a tree whose authored order differs
  from alphabetical. Only matters if byte-parity with the TS side ever becomes
  a requirement.

- [ ] TYPECHECKER: a function type in UNION RETURN position warns ("wrap each
  function type in parens") and the suggested fix does not silence it —
  `-> ((A) -> B) | nil` and `-> (((A) -> B) | nil)` both warn. Worked around in
  `lib/api-tree/http_client_extension.lua` by naming the function type
  (`StreamingCallFn`), which the alias makes read better anyway, so nothing
  needs reverting when the grammar gap closes — only the note explaining it.

- [ ] The `unpack`-stops-at-the-first-nil-hole trap listed above for
  `cli_projector`'s `PageWalk` bites `lib/api-tree/http_client.lua` too:
  `perform_async(site, nil, call_opts)` — a no-input call carrying per-call
  options — silently dropped `call_opts`, so a caller's timeout or cancellation
  was ignored. Same fix (`CallBundle`, one table argument), same real fix
  (`select("#", ...)` plus an explicit count in `async.cancellable`), same
  "the bundle can then stay or go on its own merits".

- [ ] `lib/api-tree/http_client.lua` has no `create_client(node, opts)` entry
  point yet — it needs the `http_projection` rewriter pipeline, which lands
  with `lib/api-tree/http_route.lua`. Everything the wrapper ADDS over the core
  is already there (`opts.node` recovers authored member names and codegen
  names), so the wrapper is
  `create_client_from_route(http_projection(node), { node = node, ... })`.

- [ ] **`lib/regex/system.lua` PCRE2 FFI binding fully written but `ffi.load` fails — libpcre2 not packaged (2026-08-08):** `lib/regex/system.lua` provides a complete FFI binding to PCRE2 (the system tier of `lib/regex`), but `ffi.load` fails for all of `"pcre2-8"`, `"libpcre2-8"`, `"libpcre2-8.so.0"`, `"pcre2"` — libpcre2 is not in `flake.nix`, any CI workflow (`.github/workflows/build-vendored.yml`, `.github/workflows/ci.yml`, `.github/workflows/ci-full.yml`), or vendored in `dep/`. The pure-Lua tier (`lib/regex/pure.lua`) works standalone, but the system tier cannot load. Needs: (1) libpcre2 added to the dev flake (`flake.nix`); (2) built binary vendored in `dep/` per the zero-dependency/vendored-binary convention; (3) CI workflow updated to compile and commit libpcre2 per platform alongside other vendored FFI deps. Until then, `lib/regex` falls through to pure Lua at load time (per the tier-fallthrough convention), so behavior is correct but performance is unoptimized.

- [ ] **`lib/regex/pure.lua` missing bounded-repetition and non-capturing-group support (2026-08-08):** `lib/regex/pure.lua` does not handle `{n}`, `{m,n}`, `{n,}` bounded-repetition quantifiers or `(?:...)` non-capturing groups — both are parsed as literal characters, silently producing wrong (not erroring) matches instead of the intended regex behavior. The instruction tree already carries `min`/`max` on `quant` nodes and the backtracker already handles arbitrary min/max bounds — the gap is parser-only: needs a branch for `{m,n}` syntax plus a non-capturing-group flag on `(` groups. No engine rework required; same fix scope as adding any new quantifier or group type.

- [ ] **`lib/regexp` crashes on multi-instruction counted repetition (2026-08-08):** `^(?:ab){2}$`, `(?:ab){2,3}`, `(ab){2}`, `(?:ab|cd){2}` and similar (any counted repetition over a multi-instruction atom) raise `table index is nil` at `init.lua:693` during `clone_frag`. Root cause: lines 405 (`clone_frag`) and 432 (`apply_quant`) — counted repetition clones an atom's instruction range and re-derives out-slots by offset arithmetic, which fails for multi-instruction atoms because out-slot pointers cannot simply shift by a constant offset; they must be remapped through a src→dst pc map. Lines 513-521 flag this as a known limitation. **Fix:** represent out-slots as explicit `(pc, field)` handles and have `clone_frag` build a src→dst pc map, remapping all out-slot pointers and renumbering all `OP_SAVE` capture slots in each clone. Related to `lib/regex` but in `lib/regexp`, a separate engine.

## v10 corroboration engine, iteration 3 phases 2/4/5 (2026-08-09)

Built `lib/type/v10_kernel/pilot/extractor_v1.lua` (AST→base-facts, the only
AST reader in the engine line), retired `prover_effects.lua`, and measured
(design record: `docs/decisions/typechecker-v10-core-design.md`, the three
"iteration 3, phase 2/4/5" sections). Corpus: composition-only derivations
went 1/569 → 8 in 7 files, zero replay rejections. Line ledger is flat
(extractor 511 vs retired walker 470); everything present is 3,964 lines
against the ≤2,000 kill-criterion, of which 1,630 is walkers not yet
replaced.

- [ ] **HALT, owner call needed — branch role is not in the `guard_selects`
  judgment.** `narrow-select-match` and `narrow-select-rest` share one
  premise pair, so run FORWARD a single guard fact derives both the match
  type and the rest type at the same branch point; one of them is false of
  the source (measured). A walker chooses which rule to cite; an engine
  cannot. Until decided, the extractor emits only the branch the axiom's
  reading licenses and drivers must not register `narrow-select-rest` —
  which makes rest-branch/`else` narrowing, `cf_join`/`narrow-join` facts,
  and the retirement of `prover.lua` all unreachable.
- [ ] **Substrate need — hypothetical reasoning / hypothesis discharge in the
  forward engine.** `fixpoint_prover.lua` cannot be retired without it: it
  hand-maintains an `h1_live` reachability flag over the built proof term for
  the pilot's only discharge-bearing rule, and `engine.add_rule` rejects
  discharge-bearing rules outright.
- [ ] **Substrate gap — no judgment covers a NON-STATEMENT span.** Anchoring
  a declared type at its declaration site and flowing it to a guard needs a
  preservation fact spanning "previous statement exit → guard-test exit";
  both `stmt_preserves_fact` and `stmt_preserves` are documented as
  statement-paired. Until that is decided, the extractor re-grounds the
  annotation at the guard point (the existing prover idiom).
- [ ] **Owner call needed before any port of `fixpoint_prover.lua`'s content:**
  (i) boolean-literal reassignment — the code widens `true`/`false` to
  `"boolean"` at the `ty_sub` step while `assign-literal-transfer` cites
  `tag_true()`, contradicting that module's own header comment, and no test
  exercises it; (ii) shadow detection recognizes only single-name `local`
  statements, so `local a, x = ...` is not detected as shadowing.
- [ ] **`prover_narrow.lua` cannot be deleted while `prover.lua` /
  `fixpoint_prover.lua` stand** — it emits no certificates at all; it is
  their shared pass-1 event tree (and carries a live parser-arena handle on
  `while_loop` events, which cannot be a ground fact).
- [ ] **The binding constraint on corpus coverage has moved** to the pilot's
  type vocabulary: only 30 guard facts exist corpus-wide, because a variable
  is tracked only when its `--:` annotation is a 2+-member union over the six
  `type()` classes. Elseif chains and multi-statement persistence are closed.
- [x] **`lib/entity_component`'s `WorldObj` alias omitted `self`, unlike
  every other hand-written method-bearing alias in the codebase — not a
  checker bug.** FIXED. A previous session's diagnosis (this entry,
  originally) attributed the failure to the checker's flow inference not
  carrying `setmetatable({}, World)` + post-call field assignments to
  `M.world()`'s `return` point. Re-investigated and that framing was wrong:
  a minimal repro isolating just the assignability check (no flow inference
  involved at all — a plain `setmetatable({}, Widget)` returned from a
  one-line constructor) reproduced the identical "no overlap" rejection.
  The actual mechanism: `function World:emit(event, ...)` desugars to a real
  `self` parameter (Lua's own colon-sugar makes it literal, not implicit),
  and the checker's function-field-type derivation correctly keeps that
  `self` param when `emit` is read as an ordinary table field through the
  `__index` chain — exactly matching how colon-call sites (`w:emit(...)`)
  supply the receiver as that same first argument
  (`ExprRule[NODE_METHOD_CALL]` in constrain.lua). This is not a special
  case; every other hand-written method-bearing alias already in this
  codebase (`lib/db`, `lib/http/server.lua`, `lib/aho_corasick`,
  `lib/config`, `lib/net`, `lib/lru`, `lib/jsonrpc`, `lib/kqueue`,
  `lib/epoll`, `lib/interpolation`, `lib/consistent_hash`, ...) already
  writes `self: T` explicitly as the first parameter of every method field —
  `WorldObj` was the outlier, not the checker. Fixed by rewriting `WorldObj`
  in `lib/entity_component/init.lua` to list `self`-correct signatures for
  every method actually used through the alias (`register`, `entity`,
  `destroy`, `clear`, `add`, `remove`, `get`, `emit`), adding `--:`
  signatures to the three of those (`register`, `get`, `emit`) that
  previously had none, and restoring `--: () -> WorldObj` on `M.world()`.
  `World:get` was additionally made generic (`--: <T>(WorldObj, integer,
  string) -> T | nil`, mirroring the existing `Rng.pick` pattern in
  `lib/test/fuzz.lua`) since component storage is genuinely untyped from the
  ECS's point of view — the caller narrows to its own component shape with a
  checked cast at the call site (`world:get(e, "position") --[[: Position |
  nil]]`), not a force cast (force-casting `unknown` is correctly rejected
  by the checker: "fix the upstream type annotation instead"). Verified:
  `lib/entity_component/init.lua` and all three `examples/tile_sandbox/*.lua`
  files typecheck at 0 errors; repo-wide `bin/cr check` error set is
  byte-identical before/after (6989/6989, diffed line-for-line); `bin/cr
  test lib/entity_component/` and `bin/cr test lib/type/static/` unchanged
  (the latter's one pre-existing TAG_SPREAD failure is unrelated, confirmed
  present on unmodified HEAD too).
- [ ] **Substrate gap — `lib/tilemap`'s `TileMap` type alias is incomplete.**
  It lists only `in_bounds`, `get`, `set`, `fill`; every other public method
  (`fill_border`, `width`, `height`, `copy_region`, `flood_fill`, `find`,
  `count`, `neighbors4`, `neighbors8`, `astar`, `serialize`) is missing, so a
  properly narrowed `TileMap`-typed value fails "field doesn't exist" for any
  of them. `examples/tile_sandbox/world.lua` works around this by only
  calling the four aliased methods (building the map border with four
  `fill()` calls instead of `fill_border()`, and keeping its own width/height
  constants instead of querying the map).
- [ ] **`lib/sandbox`'s instruction-budget count-hook does not reliably fire
  once a sandboxed loop gets hot enough for LuaJIT to trace-compile it.**
  `M.run`'s `opts.budget` enforcement (`lib/sandbox/init.lua`) works via
  `debug.sethook(fn, "", budget)`, a count hook. Confirmed independently of
  nesting, on plain non-nested `sandbox.run` calls: a tight loop
  (`local i = 0; while true do i = i + 1 end`) run with `budget = 150` hits
  the hook and errors correctly; the same loop with `budget = 200` hangs
  forever (probed directly with `debug.gethook`/`sethook`, bypassing the
  test framework, on the vendored LuaJIT in `bin/`). The crossover sits
  between LuaJIT's ~56-back-edge hot-loop trace threshold and the ~3
  bytecode instructions per loop iteration here — once trace-compiled, the
  interpreter-level count hook stops firing reliably. This is why the
  nesting-regression test added alongside the `debug.sethook` save/restore
  fix in `sandbox_test.lua` uses artificially small budgets (20 inner / 60
  outer) rather than realistic ones — a `budget = 5000` outer value in that
  same test previously hung `bin/cr test lib/sandbox/` for exactly this
  reason (not a bug in the save/restore fix itself; confirmed by bisecting
  budget values with a standalone repro before the test was corrected). Not
  fixed here — root cause is LuaJIT trace-compilation bypassing the
  interpreter's hook dispatch, which needs either a different enforcement
  mechanism (e.g. `jit.off` on sandboxed chunks, at a real performance
  cost) or an upstream LuaJIT-level fix; out of scope for the nesting-hook
  fix this entry accompanies. Any new sandboxed-loop test with a `budget`
  large enough to plausibly get traced should stay under this threshold or
  explicitly account for it. **Design consequence written up:**
  `docs/genre-battery/sandboxing.md` ("Rejected: `debug.sethook` count-hook /
  wall-clock budgets as a security mechanism") treats this finding as
  conclusive evidence the count-hook mechanism cannot be a hostile-script
  defense for control-stage mods, not merely a perf/reliability wrinkle —
  read that doc for the downstream architecture decision this drove
  (multiple independent process/thread isolation implementations, not an
  in-VM budget).
- [ ] **`fork()`-without-`exec()` safety on LuaJIT is undocumented
  upstream — substrate gap for any fork-based mod-process-isolation
  implementation.** Surfaced while designing control-stage sandboxing
  (`docs/genre-battery/sandboxing.md`, "Decided direction," process
  isolation implementation (a)): searched the LuaJIT mailing list and issue
  tracker for `fork()` as a syscall and found zero hits — silence, not
  endorsement. Separately, POSIX itself restricts a fork-without-exec
  child of a multithreaded parent to async-signal-safe calls for its entire
  life, and any lock held by another thread of the parent at fork time
  stays locked forever in the child (`pthread_atfork(3)`: "in practice,
  this task is generally too difficult to be practicable" to fix
  generically) — this is why that implementation is scoped as opt-in for
  hosts the game author keeps single-threaded, not a default. Also worth
  noting: crescent already tried and abandoned a `fork()`-based HTTP server
  (`lib/http/server_fork.lua`, removed per the entry above around line
  5292) in favor of coroutine-based async; the specific reason for
  abandonment wasn't captured in what was checked while writing the
  sandboxing doc and is worth digging up before leaning on `fork()` again
  for mod isolation. Nothing to fix yet — this is a substrate unknown to
  resolve (upstream confirmation, or crescent's own fork-safety testing
  against the vendored LuaJIT) before any fork-based implementation ships,
  not a coded workaround to apply.

## Session pause — fractal port + agent-design status snapshot (2026-08-13)

A long session porting fractal (`~/git/rhizone/fractal`, a TypeScript
monorepo of 11 packages) to `lib/api-tree/`, `lib/type-ir/`, and `lib/ffi-ir/`, plus related agent-design and
HTTP-substrate work, is pausing. Verified against `git log`, current file
state, and `git worktree`/`git status` before writing this down, so nothing
gets lost.

- [ ] **`docs/agent-design.md` is still a draft — nothing in it is
  implemented yet.** The doc's own header says "Status: draft. Not
  implemented." Everything landed since it was written has been prior-art
  research (the fractal port, whose "one core, N thin projections" pattern
  is cited in the doc's "One authoritative store" section as verified
  precedent) plus one concrete piece of substrate: `lib/platform/caps/fs.lua`
  gained `stat`/`mkdir`/`delete`/`rename`/`list_recursive` plus
  per-operation attenuation flags (commit `b7232a75`), whose own commit
  message says it "backs the **planned** file-browser app" — the app itself
  does not exist (`lib/platform/apps/` has no file-browser/file-management
  entry; `lib/` has no file-management library either). Open question 8 in
  the doc is marked resolved (owner decision, `docs/agent-design.md:130`):
  build both a narrow instance (a file-management app) and a small
  generalist instance as two separate first apps, sequenced library-first —
  "build the library now, with UI projections (plain now, agent-driven
  later) on top." Neither has been started. The small generalist's scope is
  explicitly left open in the same paragraph: "not decided, left open below
  alongside the rest of the unresolved items." Open questions 1, 2, 3, 4, 5,
  7, and 9 in the doc (`docs/agent-design.md:122-132`) are all still
  unresolved as written; none needed rewriting for this entry.

- [ ] **`lib/api-tree`'s http-api-projector port is mid-flight and
  substantially blocked.** Landed and tested: `http_value.lua` (deferred-
  producer response model), `http_adapter.lua`, `http_meta.lua`,
  `http_route.lua`, `http_client.lua`, `http_client_extension.lua`, plus
  multi-valued query-string support in `lib/url`. Not yet ported from
  fractal's `packages/http-api-projector`: run/dispatch, the compile-time
  matcher pass (`compile.ts`), `verbs.ts`, `layers.ts`, `preset.ts`,
  `openapi.ts`, `codegen.ts`, `dx.ts` (`crud()`/`httpProjection()`), the ten
  client extensions, `webhook.ts`, `idempotency.ts`, `tracing.ts`. No
  dedicated TODO entries exist yet for these unported files individually —
  only for gaps within files that HAVE landed (see the `http_route.lua`
  decode.ts-duplication entry and the several `type_ref_json_rpc.lua`/
  `cli_projector.lua` entries above, all still open, not duplicated here).

  Several validation-shape design forks came up while scoping this work and
  were resolved during the session; none of these resolutions were written
  down anywhere before now (a repo-wide grep for their distinguishing terms
  turned up nothing outside `docs/node_modules/`), so future work on the
  unported files should treat these as settled rather than re-litigating
  them:
  - `{}` ambiguity (object vs. array on the wire): bias toward array,
    matching the msgpack/cbor convention already used elsewhere in this
    repo — not record, which is JSON's own convention.
  - Single-value query-param shape: always-array (single-element), not
    polymorphic. A real LuaJIT benchmark measured polymorphic as
    ~180-210ns/req faster, but that is ~0.02% of a 1ms request — below the
    bar for overriding consistency with the multi-valued case.
  - Multipart file field: pass the raw `DecodedPart` table from
    `lib/multipart` straight through, no wrapper type. No existing consumer
    and no evidence a wrapper would help; revisit if http-projector's own
    handler code ends up repeating unwrapping logic.
  - `ResponseOverride.body` promise: await it immediately at the point the
    handler's return value is captured, not deferred to a later dispatch
    stage — matching fractal's own `wrapResponse`, which is `async` and
    always awaits immediately.
  - `date`/`datetime` kinds: implement explicit ISO-8601 validators for
    these kinds. The parentless-kind registration only governs the
    ancestor-fallback path; it does not forbid an explicit handler.
  - `int64`/`bytes` kinds: `int64` is a plain Lua number with a safe-range
    check (53-bit clamp, matching JS — no bigint tier); `bytes` is a base64
    string, not a raw byte array.
  - Stream predicate: use `lib/api-tree/stream.lua`'s existing `M.is_stream`
    directly. No new predicate needed.
  - The 5 built-in format validators (uuid/email/time/duration/bytes):
    hand-code each as a dedicated Lua validator, not routed through a
    general regex engine — all 5 are fixed simple grammars needing no
    backtracking/lookahead. The general user-supplied `meta.pattern` field
    stays explicitly out of scope (fractal's own http-api-projector already
    excludes it too). **Do not block http-projector validation work on the
    open `lib/regex`/`lib/regexp` items below** — they're unrelated; this
    work was deliberately routed around them.
  - type-ir's `compile.ts` wire-profile section (query/path param string
    coercion, JSON-body date coercion, roughly lines 1131-2374 as audited
    this session) is confirmed in scope — actively used by
    http-api-projector today, not dead code to skip porting.

- [ ] **Two unresolved questions block landing the RFC 9112 §6.2 204/1xx/304
  Content-Length fix** logged above (`serialize_response synthesizes
  content-length: 0 on a 204`, 2026-08-04 entry). Verified current
  `lib/http/format.lua` still synthesizes `content-length` unconditionally
  on every bodyless response (no status exemption) — the fix described in
  that entry has not been implemented. An agent halted on these two
  questions this session, checked against RFC 9110 §8.6 directly, without
  implementing anything:
  1. If a handler sets a body on a 1xx/204/304 response — which becomes
     unframed/corrupting on a keep-alive connection once content-length
     synthesis is removed for those statuses — should the fix silently drop
     the body, or error loudly?
  2. CONNECT 2xx and HEAD also carry MUST-NOT-send-Content-Length rules
     (RFC 9110 §8.6), but distinguishing them needs the request method,
     which `serialize_response` does not currently receive. Is threading
     request-method info through in scope as part of this fix, or is that
     its own follow-up?
  These are separate from the http-api-projector work above and not on its
  critical path.

- [ ] **`mcp-api-projector` (one of the 11 original fractal packages
  inventoried for this port) has not been started.** Verified: `lib/api-tree/`
  has no mcp-projector file; the only "mcp" hits in the directory are
  cross-reference comments in `stream.lua`, `input.lua`, `result.lua`,
  `jsonrpc_server.lua`, and `jsonrpc_project.lua` describing how those
  modules' abstractions would eventually apply to an MCP projector, not an
  MCP projector itself. Not blocked on anything specific — simply not yet
  reached in the port order.

- [ ] **`graphql-api-projector` was deprioritized, not started.**
  Investigation this session found real duplication between `lib/graphql`
  (has an executor, a weaker parser) and `lib/graphql_parser` (a stronger
  parser, no executor) — confirmed still the case: both directories exist
  independently today, each with its own `init.lua` and test file, no
  shared code between them. This needs resolving (consolidate the two, or
  pick one and explicitly defer reconciling the other) before a graphql
  projector could be built on top of either. No decision has been made on
  which way to go — flagging the fork, not proposing an answer.

- [ ] **`auth-oidc` was explicitly deferred** ("skip for now" on the OIDC
  crypto-tier question — pure-Lua RSA/ECDSA vs. extending the FFI libcrypto
  binding). Verified: no oidc-related file exists anywhere under `lib/`. Not
  started, not blocking anything else in this list.
