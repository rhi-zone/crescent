# Performance Log

Experiments, measurements, and verdicts. Most recent first.

Bench machine: AMD Ryzen 7 5700G, LuaJIT 2.1.1741730670, NixOS Linux 6.12.67.

---

## 2026-03-02: lexer optimization — kill _buf + source-referencing intern

**Baseline commit:** `7b58fdc` (Phase 2 parser)

Two-step optimization of the lexer hot path:

### Step 1: Kill `_buf`, use pointer arithmetic

Replaced per-byte `_buf_save_and_next()` with forward scanning and one
`ffi.string` at the end. Applied to identifiers, numbers, strings without
escapes, long strings. Kept `_buf` only for strings with escape sequences.

| file | before | after | speedup | alloc before | alloc after |
|------|--------|-------|---------|-------------|-------------|
| lex.lua (27 KB) | 10.0 ms / 2.1 MB/s | 8.9 ms / 2.9 MB/s | 1.12x | 1126 KB | 881 KB |
| parse.lua (26 KB) | 7.0 ms / 3.5 MB/s | 5.8 ms / 4.3 MB/s | 1.22x | 1012 KB | 721 KB |
| infer.lua (68 KB) | 37.3 ms / 1.8 MB/s | 27.3 ms / 2.4 MB/s | 1.37x | 3710 KB | 2489 KB |

### Step 2: Source-referencing intern pool

Replaced Lua-table intern pool with FNV-1a hash table + `memcmp`. Entries
store `(buf_id, offset, len)` referencing source buffers directly. The lexer
calls `intern_raw(pool, ptr, len, buf_id, offset)` — zero Lua string
allocation on the identifier/string hot path.

Hash function: FNV-1a 32-bit with split multiply (`lshift(h,24) + h*403`)
to stay within double precision. Open addressing with linear probing.
Keywords pre-interned from a static concatenated keyword buffer.

| file | step 1 | step 2 | speedup | alloc step 1 | alloc step 2 |
|------|--------|--------|---------|-------------|-------------|
| lex.lua (27 KB) | 8.9 ms / 2.9 MB/s | 1.5 ms / 17.7 MB/s | 6.0x | 881 KB | 518 KB |
| parse.lua (26 KB) | 5.8 ms / 4.3 MB/s | 1.7 ms / 14.3 MB/s | 3.3x | 721 KB | 563 KB |
| infer.lua (68 KB) | 27.3 ms / 2.4 MB/s | 7.0 ms / 9.5 MB/s | 3.9x | 2489 KB | 1644 KB |

### Total improvement (baseline → final)

| file | baseline | final | speedup | alloc reduction |
|------|----------|-------|---------|-----------------|
| lex.lua (27 KB) | 10.0 ms / 2.1 MB/s | 1.5 ms / 17.7 MB/s | **6.8x** | 1126→518 KB (54%) |
| parse.lua (26 KB) | 7.0 ms / 3.5 MB/s | 1.7 ms / 14.3 MB/s | **4.0x** | 1012→563 KB (44%) |
| infer.lua (68 KB) | 37.3 ms / 1.8 MB/s | 7.0 ms / 9.5 MB/s | **5.3x** | 3710→1644 KB (56%) |

### Revised 1M LOC projections

At ~10 MB/s throughput (infer.lua is the representative large file):
- 1M LOC ≈ 34 MB → **~3.6s serial, ~0.45s at 8 cores**
- Previous estimate was ~20s serial. 5.3x improvement.

The step 2 speedup was much larger than expected. The `ffi.string` call was
not just allocation overhead — it also forces a Lua string hash computation
and GC tracking per token. The FNV-1a + memcmp path skips all of that.

---

## 2026-03-02: lexer profiling and optimization path

**Commit:** `7b58fdc`

### Profile breakdown (infer.lua, 68 KB, 12080 tokens, 1937 lines)

| phase | time | % of total |
|-------|------|-----------|
| lex only | 3.8 ms | 48% |
| parse (total) | 8.1 ms | 100% |
| parse minus lex | 4.3 ms | 52% |
| arena alloc (7814 nodes) | 0.06 ms | ~0% |
| intern.new() | 0.002 ms | ~0% |

JIT: 93 traces, 0 aborts. The lexer compiles fully — 313 ns/token is the
cost of the compiled code, not interpretation.

Interning overhead (cold pool vs warm pool): **unmeasurable** (<1%). The
bottleneck is not string interning itself.

Raw byte scan baseline: 48 µs (1.5 GB/s) — 80x faster than lexing. But
the raw scan JIT-compiles to a trivial accumulator loop, so this isn't a
meaningful comparison.

### 1M LOC projections

Assuming infer.lua ratios (36 bytes/line, 6.2 tokens/line):
- 1M LOC ≈ 34 MB source ≈ 6.2M tokens ≈ 3333 files at 300 lines/file
- Serial parse: **~20 seconds**
- 8-core parallel: **~2.5 seconds**
- Per-file overhead: 16 µs (negligible)

### Root cause: `_buf` mechanism + Lua string allocation

The lexer's identifier hot path is expensive per-byte:

1. `_buf_save_and_next()` — 3 nested method calls per byte
   (`_buf_save` → Lua table insert, `_nextbyte` → FFI read + 4 field writes)
2. `_buf_tostring()` — `string.char()` per byte + `table.concat` per token
3. `intern(pool, s)` — Lua table lookup keyed by Lua string

For a 10-char identifier: 30 method calls, 10 table inserts, 10 `string.char`
allocations, 1 `table.concat`, 1 Lua string intern. All unnecessary — the
source is already a contiguous `uint8_t*` buffer.

### Optimization path (decided)

**Step 1: Kill `_buf`, use pointer arithmetic.**
Scan identifiers/numbers/strings by advancing `self.pos`, then extract via
`ffi.string(src + start, len)`. Eliminates per-byte method calls and
`string.char` + `table.concat`. One `ffi.string` per token.

**Step 2: Source-referencing intern pool (zero Lua strings).**
Replace the Lua-table intern pool with an FFI hash table. Entries store
`(buf_id, offset, len)` referencing the source buffer directly. Lookup is
`hash(src+offset, len)` → probe → `memcmp` to confirm. No `ffi.string`,
no Lua string allocation anywhere in the lex path.

Source buffers must stay alive while their intern entries are referenced. This
aligns with the design doc's mmap'd source files for the LSP daemon. For
post-check cleanup, survivors (interface exports) get promoted into .cri
interface file byte buffers.

Keywords pre-intern by pointing at a static byte buffer.

A `pool:debug_str(id)` method provides `ffi.string` reconstruction for
diagnostics/error messages (cold path only).

**Hackability note:** The lexer is already FFI-heavy. This deepens that — the
intern pool becomes an FFI hash table instead of a Lua table, debugging
requires `debug_str()` instead of direct `print(s)`. The parser is unaffected
(still receives integer IDs). Within the project's existing FFI comfort level
but worth noting.

---

## 2026-03-02: scratch stack vs Lua tables for parser list collection

**Hypothesis:** Replacing temporary Lua tables in `flush_list()` with a
pre-allocated FFI `int32_t` scratch stack would reduce GC pressure and improve
parser throughput.

**Commit:** `7b58fdc` (baseline — Lua tables with `flush_list`)

**Benchmark:** `docs/perf/v2_parse.lua`, N=500, best of 3 rounds.

**Files:**

| file | size | flush_list (Lua tables) | scratch stack (FFI) |
|------|------|------------------------|---------------------|
| lex.lua | 21 KB | ~9 ms | ~13 ms |
| parse.lua | 26 KB | ~7 ms | ~8 ms |
| infer.lua | 68 KB | ~37 ms | ~42–75 ms |

Memory per parse was essentially identical (~3.6–3.8 KB/KB source).

**Verdict: rejected.** Scratch stack was ~1.5–2x slower on the large file.
LuaJIT's table allocator recycles small short-lived tables efficiently —
the handful of temporary collector tables per parse are not a meaningful
cost. The FFI method-call overhead (`scratch:push`, `scratch:flush`) exceeded
the savings.

**Takeaway:** Don't replace small Lua tables with FFI in LuaJIT unless the
tables are large, long-lived, or in a JIT-hostile path. The real allocation
pressure is in the arenas and list pools (already FFI). If list collection
ever matters, restructure the grammar (e.g. sibling-linked AST nodes) instead.

---

## 2026-03-02: v2 parser baseline (Phase 2)

**Commit:** `7b58fdc`

**Benchmark:** `docs/perf/v2_parse.lua`, N=500, best of 3 rounds.

| file | size | time | alloc | throughput |
|------|------|------|-------|------------|
| lex.lua | 21 KB | 10.0 ms | 1126 KB | 2.1 MB/s |
| parse.lua | 26 KB | 7.9 ms | 1088 KB | 3.1 MB/s |
| infer.lua | 68 KB | 38.4 ms | 3821 KB | 1.7 MB/s |

Throughput is ~2 MB/s. Allocation is ~50x source size (dominated by arena
growth policy — arenas double, so half of final capacity is wasted on average).

**Key files:** `lib/type/static/v2/parse.lua`, `lib/type/static/v2/lex.lua`
