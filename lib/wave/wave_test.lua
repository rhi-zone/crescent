local T = require("lib.test.assert")
local wave = require("lib.wave")

-- Build a minimal valid WAVE binary for a mono 8-bit PCM file.
-- Sample data: 4 bytes of PCM.
local function make_wave_bytes(data)
	data = data or "\x00\x7f\x80\xff"
	local data_size   = #data
	local riff_size   = 4 + 8 + 16 + 8 + data_size

	local function u16(n)
		return string.char(n % 256, math.floor(n / 256) % 256)
	end
	local function u32(n)
		return string.char(
			n % 256,
			math.floor(n / 256) % 256,
			math.floor(n / 65536) % 256,
			math.floor(n / 16777216) % 256
		)
	end

	return table.concat({
		"RIFF",
		u32(riff_size),
		"WAVEfmt ",
		u32(16),     -- PCM fmt chunk size
		u16(1),      -- PCM format
		u16(1),      -- mono
		u32(44100),  -- sample rate
		u32(44100),  -- byte rate (mono 8-bit: same as sample rate)
		u16(1),      -- block align
		u16(8),      -- bits per sample
		"data",
		u32(data_size),
		data,
	})
end

T.describe("wave.string_to_wave", function()
	T.it("parses a minimal valid WAVE file", function()
		local s = make_wave_bytes()
		local w = wave.string_to_wave(s)
		T.ok(w ~= nil, "should return a table")
		T.eq(w.format, 1)
		T.eq(w.channels, 1)
		T.eq(w.sample_rate, 44100)
		T.eq(w.bits_per_sample, 8)
		T.eq(w.data, "\x00\x7f\x80\xff")
	end)

	T.it("returns nil+errmsg for truncated input", function()
		local s = make_wave_bytes()
		local result, err = wave.string_to_wave(s:sub(1, 20))
		T.eq(result, nil)
		T.ok(type(err) == "string", "should return an error string")
	end)

	T.it("returns nil+errmsg for missing RIFF marker", function()
		local s = "XXXX" .. make_wave_bytes():sub(5)
		local result, err = wave.string_to_wave(s)
		T.eq(result, nil)
		T.ok(err:find("RIFF") ~= nil, "error should mention RIFF")
	end)

	T.it("returns nil+errmsg for missing WAVE marker", function()
		local s = make_wave_bytes()
		s = s:sub(1, 8) .. "XXXX" .. s:sub(13)
		local result, err = wave.string_to_wave(s)
		T.eq(result, nil)
		T.ok(err:find("WAVE") ~= nil, "error should mention WAVE")
	end)

	T.it("returns nil+errmsg for unsupported format", function()
		local s = make_wave_bytes()
		-- Patch audio format bytes (offset 21-22, 1-based) to format=3 (IEEE float)
		s = s:sub(1, 20) .. "\x03\x00" .. s:sub(23)
		local result, err = wave.string_to_wave(s)
		T.eq(result, nil)
		T.ok(err ~= nil, "should return error for unsupported format")
	end)

	T.it("returns nil+errmsg for empty string", function()
		local result, err = wave.string_to_wave("")
		T.eq(result, nil)
		T.ok(type(err) == "string")
	end)
end)

T.describe("wave.wave_to_string", function()
	T.it("encodes a wave struct to a binary string", function()
		local w = {
			format         = 1,
			channels       = 1,
			sample_rate    = 44100,
			bits_per_sample = 8,
			data           = "\x00\x7f\x80\xff",
		}
		local s = wave.wave_to_string(w)
		T.ok(type(s) == "string", "should return a string")
		T.ok(s:sub(1, 4) == "RIFF", "should start with RIFF")
		T.ok(s:sub(9, 12) == "WAVE", "should contain WAVE marker")
	end)

	T.it("returns nil+errmsg for unsupported format", function()
		local w = { format = 3, channels = 1, sample_rate = 44100, bits_per_sample = 32, data = "" }
		local result, err = wave.wave_to_string(w)
		T.eq(result, nil)
		T.ok(err ~= nil)
	end)

	T.it("returns nil+errmsg when data is not a string", function()
		local w = { format = 1, channels = 1, sample_rate = 44100, bits_per_sample = 8, data = 42 }
		local result, err = wave.wave_to_string(w)
		T.eq(result, nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("round-trip", function()
	T.it("decode(encode(wave)) reproduces the original struct", function()
		local original = {
			format         = 1,
			channels       = 2,
			sample_rate    = 22050,
			bits_per_sample = 16,
			data           = "\x00\x01\x02\x03\xff\xfe\xfd\xfc",
		}
		local encoded = wave.encode(original)
		T.ok(type(encoded) == "string", "encode should return a string")
		local decoded = wave.decode(encoded)
		T.ok(decoded ~= nil, "decode should succeed")
		T.eq(decoded.format,          original.format)
		T.eq(decoded.channels,        original.channels)
		T.eq(decoded.sample_rate,     original.sample_rate)
		T.eq(decoded.bits_per_sample, original.bits_per_sample)
		T.eq(decoded.data,            original.data)
	end)

	T.it("aliases decode and encode match primary functions", function()
		T.eq(wave.decode, wave.string_to_wave)
		T.eq(wave.encode, wave.wave_to_string)
	end)
end)
