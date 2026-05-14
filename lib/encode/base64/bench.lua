-- lib/encode/base64/bench.lua
-- Benchmark base64 encode/decode throughput at multiple input sizes.
-- Shows pure vs ffi tiers side by side.
-- Run: luajit lib/encode/base64/bench.lua

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local base64    = require("lib.encode.base64")
local base64url = require("lib.encode.base64.base64url")
local pure      = require("lib.encode.base64.pure")
local ffi_ok, ffi_impl = pcall(require, "lib.encode.base64.ffi")

local WARMUP = 3

local sizes = {
    { label = "64B",   bytes = 64 },
    { label = "1KB",   bytes = 1024 },
    { label = "64KB",  bytes = 64 * 1024 },
    { label = "1MB",   bytes = 1024 * 1024 },
}

-- Choose iteration counts so each timed run takes a meaningful slice of wall time.
--: (bytes: integer) -> integer
local function iters_for(bytes)
    if bytes <=       64 then return 200000 end
    if bytes <=     1024 then return  20000 end
    if bytes <= 65536    then return    500 end
    return 30
end

--: (fn: (input: string, opts: { pad: boolean | nil, url: boolean | nil } | nil) -> string, input: string, n: integer) -> number
local function bench(fn, input, n)
    for _ = 1, WARMUP do fn(input, nil) end
    local t0 = os.clock()
    for _ = 1, n do fn(input, nil) end
    local t1 = os.clock()
    local mb = (#input * n) / (1024 * 1024)
    return mb / (t1 - t0)
end

--: (fn: (encoded: string, opts: { url: boolean | nil } | nil) -> (string | nil, string | nil), encoded: string, orig_bytes: integer, n: integer) -> number
local function bench_decode(fn, encoded, orig_bytes, n)
    for _ = 1, WARMUP do fn(encoded, nil) end
    local t0 = os.clock()
    for _ = 1, n do fn(encoded, nil) end
    local t1 = os.clock()
    -- Report throughput in terms of original (decoded) bytes.
    local mb = (orig_bytes * n) / (1024 * 1024)
    return mb / (t1 - t0)
end

-- ── Tier comparison ────────────────────────────────────────────────────────────

io.write("base64 benchmark — encode and decode throughput\n")
io.write(string.format("active tier: %s\n\n", base64._tier))

-- Per-tier breakdown
local tiers = { { name = "pure", impl = pure } }
if ffi_ok and ffi_impl and ffi_impl.encode then
    tiers[#tiers + 1] = { name = "ffi", impl = ffi_impl }
end

io.write(string.format("%-6s  %-6s  %14s  %14s\n",
    "tier", "size", "encode MB/s", "decode MB/s"))
io.write(string.rep("-", 48) .. "\n")

for _, tier in ipairs(tiers) do
    for _, s in ipairs(sizes) do
        local input   = string.rep("x", s.bytes)
        local encoded = tier.impl.encode(input)
        local n       = iters_for(s.bytes)

        local enc_mbps = bench(tier.impl.encode, input, n)
        local dec_mbps = bench_decode(tier.impl.decode, encoded, s.bytes, n)

        io.write(string.format("%-6s  %-6s  %11.1f MB/s  %11.1f MB/s\n",
            tier.name, s.label, enc_mbps, dec_mbps))
    end
end

-- ── Variant comparison (std vs url) using active tier ──────────────────────────

io.write("\n")
io.write(string.format("%-8s  %-6s  %14s  %14s\n",
    "variant", "size", "encode MB/s", "decode MB/s"))
io.write(string.rep("-", 50) .. "\n")

--:: BenchVariant = { name: string, enc: (s: string, opts: { pad: boolean | nil, url: boolean | nil } | nil) -> string, dec: (s: string, opts: { url: boolean | nil } | nil) -> (string | nil, string | nil) }

local base64_any = base64
local base64url_any = base64url
local variants = {
    { name = "std",        enc = base64_any.encode,    dec = base64_any.decode },
    { name = "url",        enc = base64url_any.encode,  dec = base64url_any.decode },
} --: { [integer]: BenchVariant }

for _, v in ipairs(variants) do
    for _, s in ipairs(sizes) do
        local input   = string.rep("x", s.bytes)
        local encoded = v.enc(input, nil)
        local n       = iters_for(s.bytes)

        local enc_mbps = bench(v.enc, input, n)
        local dec_mbps = bench_decode(v.dec, encoded, s.bytes, n)

        io.write(string.format("%-8s  %-6s  %11.1f MB/s  %11.1f MB/s\n",
            v.name, s.label, enc_mbps, dec_mbps))
    end
end
