-- lib/sha256/bench.lua
-- Benchmark each available SHA-256 tier hashing a 1MB input 10 times.
-- Run: luajit lib/sha256/bench.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sha = require("lib.hash.sha256")

local INPUT_SIZE = 1024 * 1024  -- 1 MB
local REPS       = 10

local data = string.rep("x", INPUT_SIZE)

io.write(string.format("sha256 benchmark — %d MB input, %d reps\n\n",
	INPUT_SIZE / (1024 * 1024), REPS))
io.write(string.format("%-12s  %10s  %10s  %12s\n",
	"tier", "total (ms)", "per-op (ms)", "throughput"))
io.write(string.rep("-", 54) .. "\n")

for _, tier in ipairs(sha._tiers) do
	-- Warm-up (1 call, not timed).
	local fn = tier.fn --[[:! (string) -> string]]
	fn(data)

	local t0 = os.clock()
	for _ = 1, REPS do
		fn(data)
	end
	local t1 = os.clock()

	local elapsed_s  = t1 - t0
	local elapsed_ms = elapsed_s * 1000
	local per_op_ms  = elapsed_ms / REPS
	local mbps       = (INPUT_SIZE * REPS) / (1024 * 1024) / elapsed_s

	io.write(string.format("%-12s  %10.1f  %10.2f  %9.1f MB/s\n",
		tier.name, elapsed_ms, per_op_ms, mbps))
end

io.write("\nDefault tier: " .. sha.tier .. "\n")
