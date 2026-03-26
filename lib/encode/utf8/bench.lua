-- lib/encode/utf8/bench.lua
-- Benchmark UTF-8 validation, length counting, codepoint extraction, and iteration.
-- Run: luajit lib/encode/utf8/bench.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local utf8 = require("lib.encode.utf8")

-- Input generators

-- All ASCII: printable characters 0x20–0x7e
local function make_ascii(n)
	local t = {}
	for i = 1, n do t[i] = string.char(0x20 + (i % 0x5f)) end
	return table.concat(t)
end

-- Mixed: 80% ASCII (1 byte), 20% 2-byte UTF-8 (U+00A1–U+07FF range)
local function make_mixed(n)
	local t = {}
	local i = 1
	while i <= n do
		if i % 5 == 0 then
			-- 2-byte sequence: U+00A1 (¡) = 0xC2 0xA1
			t[#t+1] = "\xC2\xA1"
			i = i + 2
		else
			t[#t+1] = string.char(0x41 + (i % 26))
			i = i + 1
		end
	end
	return table.concat(t)
end

-- All multibyte: CJK unified ideographs U+4E00–U+9FFF (3-byte sequences)
-- U+4E00 = 0xE4 0xB8 0x80
local function make_cjk(n)
	local t = {}
	local cp = 0x4e00
	local i = 1
	while i + 2 <= n do
		local c = cp + (math.floor(i / 3) % 0x51ff)
		t[#t+1] = string.char(
			0xe0 + bit.rshift(c, 12),
			0x80 + bit.band(bit.rshift(c, 6), 0x3f),
			0x80 + bit.band(c, 0x3f)
		)
		i = i + 3
	end
	return table.concat(t)
end

local SIZES = { 1024, 64 * 1024, 1024 * 1024 }
local WARMUP = 3
local REPS   = 10

local inputs = {
	{ label = "ascii",   make = make_ascii },
	{ label = "mixed",   make = make_mixed },
	{ label = "cjk",     make = make_cjk   },
}

local ops = {
	{
		name = "is_valid",
		fn = function(s) return utf8.is_valid(s) end,
	},
	{
		name = "len",
		fn = function(s) return utf8.len(s) end,
	},
	{
		name = "codes (iter)",
		fn = function(s)
			local n = 0
			for _, _ in utf8.codes(s) do n = n + 1 end
			return n
		end,
	},
	{
		name = "codepoint",
		-- walk the string in 256-byte chunks to avoid stack overflow from unpack
		fn = function(s)
			local len = #s
			local i = 1
			while i <= len do
				local j = math.min(i + 255, len)
				utf8.codepoint(s, i, j)
				i = j + 1
			end
		end,
	},
}

io.write("utf8 benchmark\n")
io.write(string.format("warmup: %d  reps: %d\n\n", WARMUP, REPS))

local col_w = { 16, 8, 12, 10, 12 }

local function hdr()
	io.write(string.format("%-"..col_w[1].."s  %-"..col_w[2].."s  %"..col_w[3].."s  %"..col_w[4].."s  %"..col_w[5].."s\n",
		"operation", "input", "size", "ms/op", "MB/s"))
	io.write(string.rep("-", col_w[1]+col_w[2]+col_w[3]+col_w[4]+col_w[5]+8) .. "\n")
end

hdr()

for _, op in ipairs(ops) do
	for _, inp in ipairs(inputs) do
		for _, sz in ipairs(SIZES) do
			local data = inp.make(sz)
			local bytes = #data

			-- warmup
			for _ = 1, WARMUP do op.fn(data) end

			local t0 = os.clock()
			for _ = 1, REPS do op.fn(data) end
			local t1 = os.clock()

			local elapsed_s = t1 - t0
			local per_op_ms = elapsed_s / REPS * 1000
			local mbps = (bytes * REPS) / (1024 * 1024) / elapsed_s

			local sz_label
			if sz >= 1024 * 1024 then sz_label = string.format("%dMB", math.floor(sz / (1024*1024)))
			else sz_label = string.format("%dKB", math.floor(sz / 1024)) end

			io.write(string.format("%-"..col_w[1].."s  %-"..col_w[2].."s  %"..col_w[3].."s  %"..col_w[4]..".3f  %"..col_w[5]..".1f MB/s\n",
				op.name, inp.label, sz_label, per_op_ms, mbps))
		end
	end
	io.write("\n")
end
