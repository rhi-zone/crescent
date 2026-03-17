-- lib/sha256/sha256_test.lua
-- Parity tests and fuzz harness for the tiered SHA-256 implementation.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local arb = require("lib.test.arb")
local sha = require("lib.sha256")

-- ── Known test vectors ────────────────────────────────────────────────────────
-- Verified against system sha256sum(1).

local VECTORS = {
	-- empty string
	{ input = "",
	  hex   = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
	-- "abc"
	{ input = "abc",
	  hex   = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
	-- "hello world"
	{ input = "hello world",
	  hex   = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9" },
	-- 55-byte input: last block has exactly 1 byte of message + padding (boundary)
	{ input = string.rep("a", 55),
	  hex   = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" },
	-- 64-byte input: exactly one full block
	{ input = string.rep("a", 64),
	  hex   = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
	-- 128-byte input: exactly two full blocks
	{ input = string.rep("a", 128),
	  hex   = "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e" },
}

-- ── Vector tests ──────────────────────────────────────────────────────────────

T.describe("sha256: known vectors", function()
	for _, v in ipairs(VECTORS) do
		local label = v.input == "" and "(empty)" or
			(#v.input <= 16 and string.format("%q", v.input) or
			 string.format("%d bytes", #v.input))
		T.it("default tier: " .. label, function()
			T.eq(sha.sha256(v.input), v.hex)
		end)
	end
end)

-- ── Parity tests: all available tiers produce identical output ────────────────

T.describe("sha256: tier parity on known vectors", function()
	local tiers = sha._tiers
	if #tiers < 2 then
		-- Only one tier available — still run vectors but skip cross-tier diff.
		T.it("only one tier available (" .. tiers[1].name .. "), skipping cross-tier diff", function()
			T.ok(true)
		end)
		return
	end

	for _, v in ipairs(VECTORS) do
		local label = v.input == "" and "(empty)" or
			(#v.input <= 16 and string.format("%q", v.input) or
			 string.format("%d bytes", #v.input))
		T.it("parity " .. label, function()
			local ref = tiers[1].fn(v.input)
			T.eq(ref, v.hex, "tier " .. tiers[1].name .. " wrong on " .. label)
			for i = 2, #tiers do
				local got = tiers[i].fn(v.input)
				T.eq(got, ref,
					"tier " .. tiers[i].name .. " differs from " .. tiers[1].name
					.. " on " .. label)
			end
		end)
	end
end)

-- ── Parity fuzz harness ───────────────────────────────────────────────────────
--
-- Random-length (0–255 bytes), random-byte strings.  All available tiers must
-- produce identical output.  Uses arb.it for integrated shrinking on failure.

T.describe("sha256: fuzz parity across tiers", function()
	local tiers = sha._tiers

	-- Generator: random byte strings of length 0-255.
	-- arb.map over arb.array(arb.byte, {max=255}) → build string from bytes.
	local byte_array_arb = arb.array(arb.byte, { min = 0, max = 255 })
	local random_bytes_arb = arb.map(byte_array_arb, function(bytes)
		local chars = {}
		for i, b in ipairs(bytes) do chars[i] = string.char(b) end
		return table.concat(chars)
	end)

	arb.it("all tiers agree on random byte strings", random_bytes_arb, function(s)
		if #tiers < 2 then return end  -- nothing to compare
		local ref = tiers[1].fn(s)
		for i = 2, #tiers do
			local got = tiers[i].fn(s)
			if got ~= ref then
				error(string.format(
					"tier %s != tier %s on %d-byte input\n  %s vs %s",
					tiers[i].name, tiers[1].name, #s, got, ref))
			end
		end
	end, { trials = 500 })

	-- Also test larger inputs: 256-2048 bytes.
	local large_arb = arb.map(
		arb.array(arb.byte, { min = 256, max = 2048 }),
		function(bytes)
			local chars = {}
			for i, b in ipairs(bytes) do chars[i] = string.char(b) end
			return table.concat(chars)
		end
	)

	arb.it("all tiers agree on larger random inputs (256-2048 bytes)", large_arb, function(s)
		if #tiers < 2 then return end
		local ref = tiers[1].fn(s)
		for i = 2, #tiers do
			local got = tiers[i].fn(s)
			if got ~= ref then
				error(string.format(
					"tier %s != tier %s on %d-byte input",
					tiers[i].name, tiers[1].name, #s))
			end
		end
	end, { trials = 100 })
end)

-- ── Output format sanity ──────────────────────────────────────────────────────

T.describe("sha256: output format", function()
	T.it("output is always 64 lowercase hex characters", function()
		local inputs = { "", "x", string.rep("z", 100) }
		for _, inp in ipairs(inputs) do
			local h = sha.sha256(inp)
			T.eq(#h, 64, "hex length for input of length " .. #inp)
			T.ok(h:match("^[0-9a-f]+$"), "only lowercase hex chars")
		end
	end)
end)
