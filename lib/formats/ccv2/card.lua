-- lib/formats/ccv2/card.lua
-- CCv2 (Character Card v2) card format parser.
-- Reads/writes PNG chara tEXt chunks containing base64-encoded JSON.
-- Pure Lua, no FFI.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local base64 = require("lib.encode.base64") --[[: any]]
local json = require("lib.format.json") --[[: any]]
local png = require("lib.png") --[[: any]]

--:: require "lib.formats.ccv2.ccv2_types"

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

local V1_FIELDS = { "name", "description", "personality", "scenario", "first_mes", "mes_example" }
local V2_STRING_FIELDS = { "creator_notes", "system_prompt", "post_history_instructions", "creator", "character_version" }

-- ---------------------------------------------------------------------------
-- normalize(data) -> data_table
-- Fill all defaults for missing optional fields.
-- ---------------------------------------------------------------------------

--: (CardData) -> CardData
function M.normalize(data)
  local d = {}
  -- V1 fields (all strings, name required but normalize doesn't error)
  d.name = data.name or ""
  d.description = data.description or ""
  d.personality = data.personality or ""
  d.scenario = data.scenario or ""
  d.first_mes = data.first_mes or ""
  d.mes_example = data.mes_example or ""
  -- V2 string fields
  d.creator_notes = data.creator_notes or ""
  d.system_prompt = data.system_prompt or ""
  d.post_history_instructions = data.post_history_instructions or ""
  d.creator = data.creator or ""
  d.character_version = data.character_version or ""
  -- V2 array/table fields
  d.alternate_greetings = data.alternate_greetings or {}
  d.tags = data.tags or {}
  d.extensions = data.extensions or {}
  -- character_book: preserve nil/null as-is (null means explicitly absent)
  d.character_book = data.character_book
  return d
end

-- ---------------------------------------------------------------------------
-- from_json(json_str) -> data_table | nil, err
-- Parse card JSON string (raw JSON, not base64).
-- Detects V1 (flat, no "spec" field) vs V2 (has "spec" and "data").
-- ---------------------------------------------------------------------------

--: (string) -> (CardData | nil, string)
function M.from_json(json_str)
  local obj, err = json.decode(json_str)
  if not obj then
    return nil, "json decode error: " .. tostring(err)
  end

  local data
  if obj.spec == "chara_card_v2" and obj.data then
    -- V2 card
    data = obj.data
  elseif obj.name then
    -- V1 card (flat structure with V1 fields)
    data = obj
  else
    return nil, "invalid card: missing spec and name"
  end

  if not data.name or data.name == "" then
    return nil, "invalid card: name is required"
  end

  return M.normalize(data)
end

-- ---------------------------------------------------------------------------
-- to_json(data) -> json_str | nil, err
-- Serialize card data to JSON string wrapped in V2 envelope.
-- ---------------------------------------------------------------------------

--: (CardData) -> (string | nil, string)
function M.to_json(data)
  local envelope = {
    spec = "chara_card_v2",
    spec_version = "2.0",
    data = M.normalize(data),
  }
  return json.encode(envelope)
end

-- ---------------------------------------------------------------------------
-- from_png(png_bytes) -> data_table | nil, err
-- Parse a CCv2 card from PNG bytes.
-- ---------------------------------------------------------------------------

--: (string) -> (CardData | nil, string)
function M.from_png(png_bytes)
  local chunks, err = png.read(png_bytes)
  if not chunks then
    return nil, "png read error: " .. tostring(err)
  end

  local chara = png.get_text(chunks, "chara")
  if not chara then
    return nil, "no chara chunk found in PNG"
  end

  local decoded, b64_err = base64.decode(chara)
  if not decoded then
    return nil, "base64 decode error: " .. tostring(b64_err)
  end

  return M.from_json(decoded)
end

-- ---------------------------------------------------------------------------
-- Minimal 1x1 transparent RGBA PNG
-- ---------------------------------------------------------------------------

-- Pre-built minimal PNG chunks for when no input PNG is provided.
-- 1x1 transparent RGBA: IHDR(1x1, 8-bit RGBA) + IDAT(zlib of filter=0 + 4 zero bytes) + IEND
local function make_minimal_chunks()
  -- IHDR: width=1, height=1, bit_depth=8, color_type=6(RGBA), compression=0, filter=0, interlace=0
  local ihdr_data = "\0\0\0\1" -- width=1
    .. "\0\0\0\1"              -- height=1
    .. "\8"                    -- bit_depth=8
    .. "\6"                    -- color_type=6 (RGBA)
    .. "\0"                    -- compression=0
    .. "\0"                    -- filter=0
    .. "\0"                    -- interlace=0

  -- IDAT: zlib-compressed row data.
  -- Raw row: filter_byte(0) + R(0) G(0) B(0) A(0) = 5 bytes: \0\0\0\0\0
  -- zlib stream: CMF(0x78) FLG(0x01) + deflate block + adler32
  -- deflate: final block, no compression: 01 05 00 FA FF 00 00 00 00 00
  -- adler32 of \0\0\0\0\0 = 0x00060001
  local idat_data = "\x78\x01\x01\x05\x00\xFA\xFF\x00\x00\x00\x00\x00\x00\x06\x00\x01"

  return {
    { type = "IHDR", data = ihdr_data },
    { type = "IDAT", data = idat_data },
    { type = "IEND", data = "" },
  }
end

-- ---------------------------------------------------------------------------
-- to_png(data, png_bytes?) -> new_png_bytes | nil, err
-- Write a card data table to PNG bytes.
-- ---------------------------------------------------------------------------

--: (CardData, (string | nil)) -> (string | nil, string)
function M.to_png(data, png_bytes)
  local json_str, j_err = M.to_json(data)
  if not json_str then
    return nil, "json encode error: " .. tostring(j_err)
  end

  local encoded = base64.encode(json_str)

  local chunks
  if png_bytes then
    local c, p_err = png.read(png_bytes)
    if not c then
      return nil, "png read error: " .. tostring(p_err)
    end
    chunks = c
  else
    chunks = make_minimal_chunks()
  end

  chunks = png.set_text(chunks, "chara", encoded)
  return png.write(chunks)
end

return M
