if not string.find(package.path, "?/init.lua", 1, true) then
	package.path = package.path .. ";./?.lua;./?/init.lua"
end

local bit = require("bit")

local M = {}

-- Read a little-endian uint16 from string s at 1-based byte offset i.
--: (string, integer) -> integer
local function read_u16(s, i)
	local b1 = string.byte(s, i) or 0
	local b2 = string.byte(s, i + 1) or 0
	return bit.bor(bit.lshift(b2, 8), b1)
end

-- Read a little-endian uint32 from string s at 1-based byte offset i.
--: (string, integer) -> integer
local function read_u32(s, i)
	local b1 = string.byte(s, i) or 0
	local b2 = string.byte(s, i + 1) or 0
	local b3 = string.byte(s, i + 2) or 0
	local b4 = string.byte(s, i + 3) or 0
	return bit.bor(bit.lshift(b4, 24), bit.lshift(b3, 16), bit.lshift(b2, 8), b1)
end

-- Encode a little-endian uint16 as a 2-byte string.
--: integer -> string
local function write_u16(n)
	return string.char(
		bit.band(n, 0xff),
		bit.band(bit.rshift(n, 8), 0xff)
	)
end

-- Encode a little-endian uint32 as a 4-byte string.
--: integer -> string
local function write_u32(n)
	return string.char(
		bit.band(n, 0xff),
		bit.band(bit.rshift(n, 8), 0xff),
		bit.band(bit.rshift(n, 16), 0xff),
		bit.band(bit.rshift(n, 24), 0xff)
	)
end

-- Parse a WAVE binary string.
-- Returns a wave struct on success, or (nil, errmsg) on failure.
-- wave struct: { format, channels, sample_rate, bits_per_sample, data }
--: string -> ({ format: integer, channels: integer, sample_rate: integer, bits_per_sample: integer, data: string } | nil, string)
function M.string_to_wave(s)
	if #s < 44 then
		return nil, "wave: input too short"
	end
	if s:sub(1, 4) ~= "RIFF" then
		return nil, "wave: missing RIFF marker"
	end
	if s:sub(9, 12) ~= "WAVE" then
		return nil, "wave: missing WAVE marker"
	end
	if s:sub(13, 16) ~= "fmt " then
		return nil, 'wave: missing "fmt " chunk'
	end
	local fmt_size = read_u32(s, 17)
	if fmt_size < 16 then
		return nil, "wave: fmt chunk too small"
	end
	local format = read_u16(s, 21)
	if format ~= 1 then
		return nil, "wave: unsupported audio format " .. tostring(format)
	end
	local channels        = read_u16(s, 23)
	local sample_rate     = read_u32(s, 25)
	-- byte_rate (28) and block_align (33) are derived; skip over them
	local bits_per_sample = read_u16(s, 35)

	-- data chunk fourcc follows the fmt chunk body.
	-- fmt chunk body starts at byte 21 and is fmt_size bytes long.
	-- data fourcc is at: 20 + fmt_size + 1  (1-based)
	local data_fourcc = 20 + fmt_size + 1
	if #s < data_fourcc + 7 then
		return nil, "wave: input too short for data chunk"
	end
	if s:sub(data_fourcc, data_fourcc + 3) ~= "data" then
		return nil, 'wave: missing "data" chunk'
	end
	local data_size  = read_u32(s, data_fourcc + 4)
	local data_start = data_fourcc + 8
	if #s < data_start + data_size - 1 then
		return nil, "wave: data chunk truncated"
	end
	local data = s:sub(data_start, data_start + data_size - 1)

	return {
		format          = format,
		channels        = channels,
		sample_rate     = sample_rate,
		bits_per_sample = bits_per_sample,
		data            = data,
	}
end

-- Encode a wave struct to a WAVE binary string.
-- Returns the binary string on success, or (nil, errmsg) on failure.
--: { format: integer, channels: integer, sample_rate: integer, bits_per_sample: integer, data: string } -> (string | nil, string)
function M.wave_to_string(wave)
	if type(wave) ~= "table" then
		return nil, "wave: expected table"
	end
	local wave_ = wave --[[:! { format: integer, channels: integer, sample_rate: integer, bits_per_sample: integer, data: unknown, ... }]]
	local format          = wave_.format
	local channels        = wave_.channels
	local sample_rate     = wave_.sample_rate
	local bits_per_sample = wave_.bits_per_sample
	local data            = wave_.data
	if format ~= 1 then
		return nil, "wave: unsupported audio format " .. tostring(format)
	end
	if type(data) ~= "string" then
		return nil, "wave: data must be a string"
	end
	local byte_rate   = math.floor(sample_rate * channels * math.floor(bits_per_sample / 8))
	local block_align = math.floor(channels * math.floor(bits_per_sample / 8))
	local data_size   = #data
	-- RIFF chunk size = 4 (WAVE) + 8 (fmt header) + 16 (fmt body) + 8 (data header) + data
	local riff_size   = 4 + 8 + 16 + 8 + data_size

	local parts = {
		"RIFF",
		write_u32(riff_size),
		"WAVEfmt ",
		write_u32(16),           -- fmt chunk size (PCM = 16)
		write_u16(format),
		write_u16(channels),
		write_u32(sample_rate),
		write_u32(byte_rate),
		write_u16(block_align),
		write_u16(bits_per_sample),
		"data",
		write_u32(data_size),
		data,
	}
	return table.concat(parts)
end

M.decode = M.string_to_wave
M.encode = M.wave_to_string

return M
