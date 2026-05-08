-- lib/stb/pure/image.lua
-- Pure Lua image decode stub. PNG signature detection only.
--
-- API:
--   decode(data, channels?) -> (pixels, w, h, ch) | (nil, errmsg)
--
-- TODO: implement full PNG decoder in lib/png/ and wire it here.
-- JPEG, GIF, BMP, TGA etc. require the vendored stb binary.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- PNG magic: \137 P N G \r \n \26 \n
local PNG_SIG = "\137PNG\r\n\26\n"

--: (data: string, channels: integer | nil) -> (string | nil, integer | string | nil, integer | nil, integer | nil)
function M.decode(data, _channels)
  if #data >= 8 and data:sub(1, 8) == PNG_SIG then
    return nil, "pure Lua PNG decoder not yet implemented (TODO: lib/png/)", nil, nil
  end
  return nil, "unsupported format", nil, nil
end

return M
