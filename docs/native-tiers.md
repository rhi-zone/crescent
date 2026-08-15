# Native Code Tiers

How crescent handles native code — SIMD, compiled C, and platform libraries — without
requiring a C compiler from users or committing to a single strategy everywhere.

## The extended tier hierarchy

The base tier model extends to five levels for native/SIMD work:

| Priority | Tier | Mechanism | C compiler? | SIMD? | Vendored? |
|---|---|---|---|---|---|
| 1 | **vendored binary** | `.so`/`.dll` committed to repo | no | hardware | yes |
| 2 | **system** | `ffi.load("libvips")` at runtime | no | hardware | no |
| 3 | **DynASM + RA** | machine code generated at load time from Lua | no | yes | `.lua` files only |
| 4 | **C build** | `build.lua` compiles C sources | yes | yes | no — output not committed |
| 5 | **pure Lua** | `.lua` only | no | no | yes |

**Vendored binary is preferred over system** when a vendored binary exists for the
current platform. Reasons:

- **Known version** — vendored binary is pinned; system library version is unknown.
- **Security** — loading an unknown system library version risks using one with known
  CVEs. The vendored binary was audited when committed.
- **Reproducibility** — same binary runs everywhere regardless of what the OS has
  installed.
- **NixOS** — system tier is unreliable on NixOS (see below); vendored binary always works.

System tier is only preferred over vendored when **no vendored binary exists** for the
functionality (e.g. `libssl` — crescent does not vendor a crypto library; use the OS).
An explicit opt-in flag (`M.prefer_system = true`) can override for users who want OS-managed
security updates on a specific library.

Selection at load time: try each in priority order, fall through on failure.
`M._tier` exposes which was selected.

The **C build** tier is not a user-facing tier. It exists for CI and developers who need to
regenerate vendored binaries after updating upstream source. Users receive either the
vendored binary or the pure Lua fallback — they never run a compiler.

### System tier is opportunistic

`ffi.load("libname")` relies on the dynamic linker — `LD_LIBRARY_PATH`, `/etc/ld.so.cache`,
`DYLD_LIBRARY_PATH`. This works on FHS-compliant systems (Debian, Arch, Fedora, macOS with
Homebrew in standard paths). It does **not** work out of the box on:

- **NixOS** — libraries live under `/nix/store/<hash>-libvips-x.y.z/lib/`; the linker
  finds nothing unless `LD_LIBRARY_PATH` is set (e.g. inside a `nix develop` shell with
  the library in `buildInputs`).
- **Distroless / minimal containers** — no system libraries present.
- **Windows without the DLL on `PATH`** — same issue.

The system tier is "user has explicitly made this library available in their runtime
environment." Probe it via `pcall(ffi.load, name)` and silently skip if absent.

---

## Vendored binaries: the "earn their place" rubric

Vendored binaries are pre-compiled platform-specific blobs committed to the repo.
They are not hackable and require maintenance across 5 platform targets. They must
earn their place. All five criteria must pass:

1. **Capability gap** — pure Lua cannot do the operation correctly, not just slowly.
   "Slower" does not qualify. "Qualitatively wrong output" (nearest-neighbor as the only
   resize option) or "practically infeasible" (JPEG Huffman + DCT at useful throughput)
   does qualify.

2. **DynASM-RA gap** — the algorithm is too complex to maintain as generated assembly.
   Either the implementation is too large (stb's resampler with multiple filter types),
   or the algorithm evolves with upstream (security patches, format quirks), making an
   assembly port a permanent maintenance liability.

3. **Stability** — the library's ABI has been stable for years and shows no signs of
   churn. A library that breaks ABI every major version is not a vendoring candidate.

4. **Footprint** — the binary is ≤1 MB per platform. Stb libraries compile to 100–300 KB.

5. **Coverage** — binaries for all five target platforms are practical to produce and
   maintain: `linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-aarch64`,
   `windows-x86_64`.

### Current qualified libraries

| Library | Gap | Reason |
|---|---|---|
| `stb_image` | capability | JPEG decode (Huffman + IDCT) is infeasible in pure Lua at speed |
| `stb_image_resize2` | capability + DynASM-RA | Quality gap (bilinear/bicubic vs nearest-neighbor); resampling kernel too complex to maintain in assembly |
| `stb_truetype` | capability + DynASM-RA | Font rasterization + hinting; hundreds of KB of algorithm, evolves with font spec edge cases |

### Disqualified

| Library | Reason |
|---|---|
| `libssl`/`libcrypto` | System tier handles it; present on virtually all targets |
| `libvips` | Too large (~10 MB); system library — use as system tier only |
| `xxhash`, custom hashes | DynASM + RA handles these; algorithm is bounded and stable |
| `zlib` | System tier (present everywhere); pure Lua inflate is tractable for non-hot paths |

---

## TinyCC: enabling tier 4, not a tier

TinyCC (`tcc`, vendored source in `dep/tcc/`, prebuilt binaries in `bin/tcc-*`)
is not a sixth tier alongside the five above. Tier 4 ("C build") already
assumes *some* C compiler is available to run `build.lua`; tcc exists to
supply that compiler on a platform or CI runner that doesn't have gcc/clang
available, so tier 4 stays reachable everywhere rather than silently
degrading straight to tier 5 (pure Lua) for want of a compiler.

This is infrastructure underneath tier 4, not a new point in the priority
order — tier selection at load time is unaffected; `M._tier` still only
ever reports one of the five values above. `tcc` never appears as a load-time
tier because it doesn't produce a different runtime artifact than tier 4
does; it's a different way of *reaching* tier 4's output.

**Where it helps:** any tier-4 CI job or developer machine that lacks gcc/
clang/cl — a bare Alpine container without `build-base`, a minimal cross
target, or a contributor machine mid-setup. `.github/workflows/build-vendored.yml`'s
`workflow_dispatch`-only tcc jobs bootstrap tcc (built once with the
runner's own system compiler) and then use it as `CC` for the C-build tier.

**What it does not change:** tcc is never a substitute for the vendored
binaries in `lib/stb/vendor/` etc. — those are still built with gcc/clang/cl
in the primary CI path (`.github/workflows/build-vendored.yml`'s
push-triggered jobs), unmodified. tcc is a fallback path for regenerating
tier-4 output, not a replacement for how the shipped vendored binaries are
produced today.

**Known gap, found by actually building with it:** tcc (mob branch,
`dep/tcc/VERSION` pin) cleanly builds `sqlite3.c` and zlib's sources (the
former needs an explicit `-lm`; tcc's driver doesn't auto-link libm the way
gcc/clang's does). It still does not build LuaJIT end-to-end: `buildvm`'s
generated `lj_vm.S` used GNU-as-only `sym@PLT` relocation-suffix syntax that
tcc's assembler rejected outright ("end of line expected") — that specific
parser gap is now patched (see below) and verified in isolation, but a full
LuaJIT build with the patched tcc has not been attempted. LuaJIT source is
now vendored locally (`dep/luajit/`, pinned via `dep/luajit/VERSION`; used
by the gcc/clang/cl `luajit-*` jobs in `build-vendored.yml`) — the tcc gap
here is specifically about wiring that vendored source into the
`tcc-build-deps-*` job's tcc-as-`CC` path, which hasn't been attempted, not
about the source's availability. LuaJIT stays unwired in `tcc-build-deps-*`
until that's verified for real (see TODO.md). libressl's `--disable-asm`
tcc path is still wired (kept, not flipped):
the perlasm-generated `*-elf-x86_64.S` files' SSE2/AES-NI opcode gap is now
patched, but assembling them surfaced a *separate* gap — this vendored tcc
defines no `xmm8`–`xmm15` (or `r8`–`r15`) registers at all — that still
blocks two of the seven asm files. See TODO.md for the full breakdown.

**Patch mechanism (`dep/tcc/patches/`):** `dep/tcc/`'s vendored source stays
pristine — bugs found in it are fixed as unified diffs under
`dep/tcc/patches/*.patch` (numbered, e.g. `0001-plt-suffix.patch`), applied
via `git apply dep/tcc/patches/*.patch` (order matters; apply in numeric
order) as a CI step in each `tcc-bootstrap-*` job in
`.github/workflows/build-vendored.yml`, immediately after checkout and
before the tcc build step. This is the only place in the repo that patches
vendored source rather than either vendoring it modified or forking it
outright; it exists because tcc is infrastructure we actively extend
(assembler/opcode-table gaps) rather than a dependency we only consume
as-is. Currently: `0001-plt-suffix.patch` (tccasm.c, GNU-as `sym@PLT`
suffix parsing), `0002-libressl-sse-aesni-opcodes.patch`
(x86_64-asm.h + i386-asm.c, SSE2/AES-NI opcode-table entries for
libressl's perlasm output), and `0004-asm-section-flags-alloc.patch`
(tccasm.c, `.section NAME,"flags"` directive: `SHF_ALLOC` was hardcoded
into every parsed section's flags and the flag-parsing loop never
recognized `a` at all, so an explicit `"w"`-only section came out
allocatable and an empty flags string still got `SHF_ALLOC` — both wrong
against real GNU `as`, which only sets `SHF_ALLOC` when `a` is actually
present.

## Vendored binary layout

```
lib/stb/
  init.lua                     -- public API; selects tier at load time
  pure/
    image.lua                  -- pure Lua PNG/BMP decoder (no JPEG)
    resize.lua                 -- nearest-neighbor resize
  vendor/
    linux-x86_64/stb.so
    linux-aarch64/stb.so
    macos-x86_64/stb.dylib
    macos-aarch64/stb.dylib
    windows-x86_64/stb.dll
  build.lua                    -- compiles stb headers → .so; for regenerating vendor/
  src/
    stb_image.h
    stb_image_resize2.h
    stb_truetype.h
```

`build.lua` is a developer/CI tool, not part of the load-time tier chain.

Tier selection in `init.lua`:

```lua
local ffi = require("ffi")
local M = {}

-- 1. System tier (libvips or platform image library)
local ok, vips = pcall(ffi.load, "vips")
if ok then
  M._tier = "system-vips"
  -- ... bind vips API
  return M
end

-- 2. Vendored binary
local plat = detect_platform()   -- "linux-x86_64", "macos-aarch64", etc.
local ext  = plat:match("^windows") and "dll"
          or plat:match("^macos")   and "dylib"
          or                            "so"
local path = script_dir .. "/vendor/" .. plat .. "/stb." .. ext
local ok2, stblib = pcall(ffi.load, path)
if ok2 then
  M._tier = "vendored"
  -- ... bind stb API via ffi.cdef
  return M
end

-- 3. Pure Lua fallback
M._tier = "pure-lua"
-- ... require pure/ implementations
return M
```

---

## DynASM + RA: `lib/asm/`

For SIMD kernels that crescent owns — hash functions, string search, custom filters,
parser acceleration — the DynASM + register allocator approach eliminates the main
pain of hand-written assembly (manual register allocation) while staying entirely in
Lua with no external dependencies.

DynASM ships with LuaJIT (`dynasm/dasm_x86.lua`, `dynasm/dasm_arm.lua`) and is already
used to build LuaJIT itself. The addition is a register allocator and a typed virtual
IR sitting above it.

### Directory layout

```
lib/asm/
  init.lua          -- public API: compile kernel → callable FFI function
  ir.lua            -- virtual register IR builder
  ra.lua            -- linear scan register allocator
  cpu.lua           -- CPUID / HWCAP detection (avx2, sse2, neon, ...)
  abi/
    x64.lua         -- AMD64 SysV + Win64 calling conventions; register file
    arm64.lua       -- AAPCS64 calling convention; register file
  emit/
    x64.lua         -- IR → DynASM x86-64 directives
    arm64.lua       -- IR → DynASM ARM64 directives
  dynasm/           -- vendored DynASM from LuaJIT source
```

### Virtual IR

Types:

```
-- Scalars
i8  i16  i32  i64  f32  f64  ptr

-- 128-bit SIMD (SSE2 / NEON baseline)
i8x16  i16x8  i32x4  i64x2  f32x4  f64x2

-- 256-bit SIMD (AVX2 / SVE optional)
i8x32  i16x16  i32x8  i64x4  f32x8  f64x4
```

Instructions:

```
-- Memory
load(dst, ptr, offset?)       store(ptr, src, offset?)
-- Arithmetic
add  sub  mul  div  fma(a, b, c)   -- fma = a*b + c
-- Bitwise
and  or  xor  not  shl(n)  shr(n)
-- SIMD-specific
broadcast(scalar, type)        -- scalar → all lanes
shuffle(src, imm)              -- permute lanes within vector
blend(a, b, mask)              -- lane-wise select
cvt(dst_type, src)             -- convert between element types
hadd(vec)                      -- horizontal reduce (add all lanes)
extract(vec, lane)             -- pull one lane to scalar
insert(vec, lane, scalar)      -- write one lane
```

### Register allocator

Algorithm: linear scan (Poletto & Sarkar 1999).

For straight-line SIMD kernels (the primary target — loops with no branches in the hot
path), liveness is a single backward pass: each virtual register is live from its
definition to its last use. No CFG, no dominance, no phi nodes needed.

Steps:
1. Compute live intervals `[def, last_use]` for each virtual register.
2. Sort intervals by start point.
3. Walk intervals; maintain an active set sorted by end point.
   - Expire intervals whose end < current start → free their physical register.
   - If a free physical register of the correct type is available → assign it.
   - Otherwise spill: take the interval with the latest end point; assign its register
     to the current interval; insert load/store around the spilled interval's uses.
4. Emit prologue/epilogue for callee-saved registers that were assigned.

**Aliasing model** (critical for x64):
- Assigning `ymm3` implicitly occupies `xmm3` (upper 128 bits of the same physical register).
- The register file tracks aliasing groups; allocating any member of a group marks all
  members as in-use until the group is freed.
- On x64 pre-AVX (only 8 XMM): RA must not exceed 8 SIMD intervals active simultaneously.

### Register files

**x64:**
```
GPR (16):    rax rcx rdx rbx rsp rbp rsi rdi r8–r15
  SysV args:  rdi rsi rdx rcx r8 r9
  Win64 args: rcx rdx r8 r9
  Callee-saved (SysV):  rbx rbp r12–r15
  Callee-saved (Win64): rbx rbp rdi rsi r12–r15  xmm6–xmm15

SIMD (16 groups):  xmm0–xmm15  (alias ymm0–ymm15 with AVX, zmm0–zmm15 with AVX-512)
  SysV args:  xmm0–xmm7
  Callee-saved (SysV):  none
  Callee-saved (Win64): xmm6–xmm15 (lower 128 bits)
```

**ARM64:**
```
GPR (31+sp):  x0–x30  sp
  Args:         x0–x7
  Callee-saved: x19–x29  sp

NEON (32 groups):  v0–v31  (alias q/d/s/h/b registers)
  Args:         v0–v7
  Callee-saved: v8–v15 (lower 64 bits per AAPCS64)
```

### Usage sketch

```lua
local asm = require("lib.asm")
local ir  = require("lib.asm.ir")

-- Describe a kernel: element-wise multiply of two f32x8 arrays
local function make_mul_f32x8(n)
  local k = ir.kernel({ "ptr", "ptr", "ptr", "i64" }, {})  -- (dst, a, b, n)
  local dst, a, b, count = k:args()
  local i = k:vreg("i64")
  k:emit("mov", i, ir.imm(0))
  local loop = k:label()
    local va = k:vreg("f32x8")
    local vb = k:vreg("f32x8")
    local vc = k:vreg("f32x8")
    k:emit("load", va, a, i)
    k:emit("load", vb, b, i)
    k:emit("mul",  vc, va, vb)
    k:emit("store", dst, vc, i)
    k:emit("add", i, i, ir.imm(32))  -- 8 × 4 bytes
    k:emit("cmp_lt", i, count)
  k:loop(loop)
  return asm.compile(k)
end

local mul = make_mul_f32x8()
mul(dst_ptr, a_ptr, b_ptr, n)   -- callable FFI function
```

### What DynASM + RA is for vs. vendored binaries

Use DynASM + RA when:
- Crescent **owns** the algorithm (hash functions, string search, parser inner loops)
- The algorithm is bounded and stable (not a moving target like image format quirks)
- The SIMD code can be written once and maintained as an IR kernel

Use vendored binaries when:
- The upstream C library is large and algorithmically complex (stb)
- Tracking upstream bug fixes in assembly would be a permanent maintenance burden
- The capability gap criterion is met (see rubric above)

---

## CPU feature detection

```lua
local cpu = require("lib.asm.cpu")
-- x86-64
cpu.sse2   -- always true on x86-64
cpu.avx2
cpu.avx512f
-- ARM64
cpu.neon   -- always true on ARM64
cpu.sve
cpu.sve2
```

Detection via CPUID (x86) or `getauxval(AT_HWCAP)` (Linux ARM64) / `sysctlbyname`
(macOS ARM64), called once at load time and cached.

Tier selection in `lib/asm/` kernels:

```lua
local cpu   = require("lib.asm.cpu")
local asm   = require("lib.asm")

local dot = cpu.avx2
  and asm.compile(dot_avx2_kernel)
  or  cpu.sse2
  and asm.compile(dot_sse2_kernel)
  or  dot_pure_lua
```
