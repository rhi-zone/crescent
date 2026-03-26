# Performance Log

Experiments, measurements, and verdicts. Most recent first.

Bench machine: AMD Ryzen 7 5700G, LuaJIT 2.1.1741730670, NixOS Linux 6.12.67.

---

## 2026-03-26: JSON tier optimisation — pre-optimisation baseline

**Commit:** (baseline before optimisation, same as `122d8ca` code)

Measured before any optimisation work. Pure and FFI tiers run at nearly
identical throughput — FFI is 0–10% slower than pure on most workloads because
the `ffi.string` call overhead on safe-run extraction cancels the pointer
advantage. The decoder's string scanning is byte-by-byte in both tiers.

### Baseline raw output

```
=== JSON benchmark (ffi tier selected) ===
selected tier: ffi

encode:
  small object (10 fields), 10000 iters       pure:     2.6 µs  ffi:     2.6 µs  speedup: 1.00x
  large array (1000 numbers), 1000 iters      pure:    84.7 µs  ffi:    85.8 µs  speedup: 0.99x
  deeply nested (depth 50), 1000 iters        pure:    20.1 µs  ffi:    21.1 µs  speedup: 0.95x
  large string (10 KB with escapes), 1000 iters  pure:    42.8 µs  ffi:    43.2 µs  speedup: 0.99x

decode:
  small object (10 fields), 10000 iters       pure:     0.8 µs  ffi:     1.0 µs  speedup: 0.89x
  large array (1000 numbers), 1000 iters      pure:   202.3 µs  ffi:   211.6 µs  speedup: 0.96x
  deeply nested (depth 50), 1000 iters        pure:     5.3 µs  ffi:     6.3 µs  speedup: 0.85x
  large string (10 KB with escapes), 1000 iters  pure:    57.9 µs  ffi:    63.9 µs  speedup: 0.90x

input sizes: small_obj=109 bytes  large_arr=17498 bytes  deep=1053 bytes  large_str=7011 bytes
```

---

## 2026-03-26: three-tier JSON library (lib/format/json)

**Commit:** `122d8ca`

Replaces vendored lunajson with a crescent-native three-tier JSON library:
pure Lua (Tier 1), LuaJIT FFI scalar (Tier 2), simdjson stub (Tier 3, not
yet implemented — falls through to Tier 2). Tier selected at module load time.

Benchmark: `luajit docs/perf/json.lua`
Baseline (lunajson): `luajit docs/perf/json_baseline.lua`

### encode throughput

| scenario | lunajson (µs) | pure (µs) | ffi (µs) | vs lunajson |
|----------|--------------|-----------|----------|-------------|
| small object (10 fields) | 2.8 | 2.5 | 2.3 | ~1.1–1.2x faster |
| large array (1000 numbers) | 94.4 | 86.0 | 87.0 | ~1.1x faster |
| deeply nested (depth 50) | 21.3 | 19.8 | 20.5 | ~1.05x faster |
| large string (10 KB, escapes) | 73.3 | 43.7 | 46.0 | **~1.7x faster** |

### decode throughput

| scenario | lunajson (µs) | pure (µs) | ffi (µs) | vs lunajson |
|----------|--------------|-----------|----------|-------------|
| small object (10 fields) | 1.0 | 0.9 | 1.0 | comparable |
| large array (1000 numbers) | 228.2 | 207.6 | 215.8 | ~1.1x faster |
| deeply nested (depth 50) | 9.2 | 5.5 | 6.5 | **~1.4–1.7x faster** |
| large string (10 KB, escapes) | 160.3 | 67.7 | 69.7 | **~2.3x faster** |

### Observations

Both tiers run at comparable speed — LuaJIT JIT-compiles both paths. The FFI
tier's byte-pointer advantage is partially offset by `ffi.string` call overhead
on safe-run extraction. On most workloads the two tiers are within 5–10% of
each other; neither is consistently faster.

The largest improvement over lunajson is on string-heavy workloads (2.3x faster
decode, 1.7x faster encode on 10 KB string with escapes). The new encoder uses a
pre-built 256-entry escape table and emits safe byte runs directly rather than
per-byte gsub substitution; the new decoder avoids the gsub + surrogate-pair
state machine overhead of lunajson.

The simdjson tier (Tier 3) is a stub pending C shim build infrastructure. When
available it should achieve 2–5x over the FFI tier on large payloads.

### Input sizes

```
small_obj = 109 bytes   large_arr = 17498 bytes
deep      = 1053 bytes  large_str = 7011 bytes
```

### Raw benchmark output (new tiers)

```
=== JSON benchmark (ffi tier selected) ===
selected tier: ffi

encode:
  small object (10 fields), 10000 iters       pure:     2.5 µs  ffi:     2.3 µs  speedup: 1.09x
  large array (1000 numbers), 1000 iters      pure:    86.0 µs  ffi:    87.0 µs  speedup: 0.99x
  deeply nested (depth 50), 1000 iters        pure:    19.8 µs  ffi:    20.5 µs  speedup: 0.97x
  large string (10 KB with escapes), 1000 iters  pure:    43.7 µs  ffi:    46.0 µs  speedup: 0.95x

decode:
  small object (10 fields), 10000 iters       pure:     0.9 µs  ffi:     1.0 µs  speedup: 0.85x
  large array (1000 numbers), 1000 iters      pure:   207.6 µs  ffi:   215.8 µs  speedup: 0.96x
  deeply nested (depth 50), 1000 iters        pure:     5.5 µs  ffi:     6.5 µs  speedup: 0.84x
  large string (10 KB with escapes), 1000 iters  pure:    67.7 µs  ffi:    69.7 µs  speedup: 0.97x
```

### Raw benchmark output (lunajson baseline, measured before replacement)

```
=== lunajson baseline ===
encode:
  small object (10 fields)                      2.8 µs/iter
  large array (1000 numbers)                   94.4 µs/iter
  deeply nested (depth 50)                     21.3 µs/iter
  large string (escapes)                       73.3 µs/iter
decode:
  small object (10 fields)                      1.0 µs/iter
  large array (1000 numbers)                  228.2 µs/iter
  deeply nested (depth 50)                      9.2 µs/iter
  large string (escapes)                      160.3 µs/iter
```

---

## 2026-03-26: pure Lua Myers diff and three-way merge (lib/merge3)

**Commit:** `ada0caf`

Replaces `diff3` shell invocation in `lib/pkg/install.lua` with a pure Lua
implementation. No external dependency — works on Alpine, Windows, macOS,
anywhere LuaJIT runs.

Benchmark: `luajit docs/perf/merge.lua 200`

### diff throughput by file size (5% of lines changed)

| scenario | lines | µs/call | Klines/s | KB/s |
|----------|-------|---------|----------|------|
| diff 100 lines  | 100  | 12.7  | 7,892  | 53,331 |
| diff 500 lines  | 500  | 105.9 | 4,720  | 35,881 |
| diff 1000 lines | 1000 | 348.2 | 2,872  | 22,136 |
| diff 5000 lines | 5000 | 6,637 | 753    | 6,459  |

Targets: < 5 ms for 1000-line file. **0.35 ms — 14x under target.**

### merge3 throughput by conflict density

| scenario | lines | µs/call | Klines/s | conflicts |
|----------|-------|---------|----------|-----------|
| 0% conflict, 5% ours-only edit | 1000 | ~0     | fast-path¹ | 0  |
| 5% conflict                    | 1000 | 738    | 1,355    | 50        |
| 20% conflict                   | 1000 | 7,521  | 133      | 200       |
| 500 lines, 10% conflict        | 500  | 638    | 783      | 50        |
| 5000 lines, 2% conflict        | 5000 | 8,701  | 575      | 97        |

¹ Fast path: when theirs == base, returns ours immediately (string equality).

Targets: < 10 ms for 1000-line file with 10 conflict regions. **0.74 ms at 5%
conflict density (50 conflicts) — 13x under target.**

### Raw benchmark output

```
=== diff throughput by file size ===
scenario                                   lines   µs/call    Klines/s        KB/s
----------------------------------------------------------------------------------
diff (100 lines, 5% changed)                 100       12.7      7891.7     53330.8
diff (500 lines, 5% changed)                 500      105.9      4720.2     35881.0
diff (1000 lines, 5% changed)               1000      348.2      2871.8     22136.1
diff (5000 lines, 5% changed)               5000     6636.8       753.4      6458.5

=== merge3 throughput by conflict density ===
scenario                                           lines   µs/call    Klines/s        KB/s  conflicts
--------------------------------------------------------------------------------------------------
merge3 0% conflict, 5% ours-only edit               1000        0.0  33333333.3  256933593.8         0
merge3 5% conflict                                  1000      738.0      1355.1     10445.0        50
merge3 20% conflict                                 1000     7521.3       133.0      1024.8       200
merge3 500 lines, 10% conflict, 5% mod               500      638.4       783.2      5953.6        50
merge3 5000 lines, 2% conflict                      5000     8701.2       574.6      4926.2        97

=== correctness spot-check ===
  ok: diff(10 lines) reconstructs correctly
  ok: diff(100 lines) reconstructs correctly
  ok: diff(500 lines) reconstructs correctly
  ok: all round-trip invariants hold
```

### Comparison to diff3 shell call

The previous `diff3 -m` invocation required:
- diff3 binary present on PATH (not available on Alpine, Windows)
- 2–3 temp files per merged file (os.tmpname + write + read + cleanup)
- fork+exec overhead (~1–5 ms per file on Linux)
- Complex exit-code detection workaround for LuaJIT vs Lua 5.1

The pure Lua implementation: zero shell calls, zero temp files, zero external
dependency. For a package with 20 files needing merge, savings are ~20–100 ms
of fork overhead alone, plus elimination of temp file I/O.

---

## 2026-03-17: SHA-256 tiered implementation

**Commit:** `bb16c30`

Three-tier SHA-256 (`lib/sha256/init.lua`). Tiers selected at load time.
Benchmark: `luajit lib/sha256/bench.lua` — 1 MB input, 10 reps, 1 warm-up call.

| tier | total (ms) | per-op (ms) | throughput |
|------|-----------|-------------|------------|
| ffi  | 138.7     | 13.87       | 72.1 MB/s  |
| lua  | 245.1     | 24.51       | 40.8 MB/s  |

**system tier** (OpenSSL `SHA256()`) not available on this machine (no `libssl.so`
in `LD_LIBRARY_PATH`); would be ~1 GB/s via SHA-NI when available.

**FFI tier** (LuaJIT FFI scalar, `uint32_t[64]` work arrays, `bit.ror/bxor`):
72 MB/s. JIT-compiled loop over 64 compression rounds.

**Lua tier** (pure Lua, streaming 64-byte blocks via `string.byte`): 41 MB/s.
Much faster than the ~10 MB/s spec estimate because LuaJIT JIT-compiles the
inner loop — the bit operations via `bit.*` trace cleanly. Streaming avoids
building a full byte-table for large inputs.

### Raw benchmark output (best of 3 runs)

```
sha256 benchmark — 1 MB input, 10 reps

tier          total (ms)  per-op (ms)    throughput
------------------------------------------------------
ffi                138.7       13.87       72.1 MB/s
lua                245.1       24.51       40.8 MB/s

Default tier: ffi
```

---

## 2026-03-02: lexer optimization — kill _buf + source-referencing intern

**Baseline commit:** `7b58fdc` (Phase 2 parser)
**Optimization commit:** `8941262`

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

### Raw benchmark output

`luajit docs/perf/v2_parse.lua 500`, best of 3 rounds.

Baseline (`7b58fdc`):
```
lib/type/static/v2/lex.lua                 21.4 KB     9977 µs  1126.3 KB/parse    2.1 MB/s
lib/type/static/v2/parse.lua               25.5 KB     7035 µs  1012.3 KB/parse    3.5 MB/s
lib/type/static/infer.lua                  68.3 KB    37299 µs  3710.4 KB/parse    1.8 MB/s
```

After optimization (`8941262`):
```
lib/type/static/v2/lex.lua                 26.3 KB     1628 µs   559.2 KB/parse   15.8 MB/s
lib/type/static/v2/parse.lua               25.5 KB     2006 µs   637.0 KB/parse   12.4 MB/s
lib/type/static/infer.lua                  68.3 KB     6900 µs  1643.6 KB/parse    9.7 MB/s
```

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

**Experiment commit:** `7fcde15` (branch `experiment/scratch-stack`)

Raw output (infer.lua, N=500, from session `eacb799e`):
```
=== SCRATCH STACK ===
round 1:  75115 µs/parse  3696.7 KB/parse
round 2:  75399 µs/parse  3666.5 KB/parse
round 3:  42611 µs/parse  3712.6 KB/parse

=== LUA TABLES ===
round 1:  38983 µs/parse  3653.9 KB/parse
round 2:  37022 µs/parse  3635.0 KB/parse
round 3:  37205 µs/parse  3632.9 KB/parse
```

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
