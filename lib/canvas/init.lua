if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- 2D pixel canvas with drawing primitives and PPM/PGM/BMP export.
-- Internal storage: flat array pixels[(y*w+x)*4 + channel] (1-indexed)
-- channels: 1=R, 2=G, 3=B, 4=A

local bit = require("bit")
local M = {}

M._tier = "pure"

-- ---------------------------------------------------------------------------
-- 5x7 bitmap font (printable ASCII 32-126)
-- Each character is 7 bytes. Each byte is a row (bits 4..0 = columns 0..4).
-- ---------------------------------------------------------------------------

local FONT_W = 5
local FONT_H = 7

-- stylua: ignore
local FONT = {
  -- 32: space
  {0,0,0,0,0,0,0},
  -- 33: !
  {4,4,4,4,0,4,0},
  -- 34: "
  {10,10,0,0,0,0,0},
  -- 35: #
  {10,31,10,31,10,0,0},
  -- 36: $
  {4,14,20,14,5,14,4},
  -- 37: %
  {18,20,8,4,2,5,9},
  -- 38: &
  {12,18,20,8,21,18,13},
  -- 39: '
  {4,4,0,0,0,0,0},
  -- 40: (
  {2,4,8,8,8,4,2},
  -- 41: )
  {8,4,2,2,2,4,8},
  -- 42: *
  {0,4,21,14,21,4,0},
  -- 43: +
  {0,4,4,31,4,4,0},
  -- 44: ,
  {0,0,0,0,6,4,8},
  -- 45: -
  {0,0,0,31,0,0,0},
  -- 46: .
  {0,0,0,0,0,6,6},
  -- 47: /
  {1,2,4,4,8,16,0},
  -- 48: 0
  {14,17,19,21,25,17,14},
  -- 49: 1
  {4,12,4,4,4,4,14},
  -- 50: 2
  {14,17,1,6,8,16,31},
  -- 51: 3
  {31,1,2,6,1,17,14},
  -- 52: 4
  {2,6,10,18,31,2,2},
  -- 53: 5
  {31,16,30,1,1,17,14},
  -- 54: 6
  {6,8,16,30,17,17,14},
  -- 55: 7
  {31,1,2,4,8,8,8},
  -- 56: 8
  {14,17,17,14,17,17,14},
  -- 57: 9
  {14,17,17,15,1,2,12},
  -- 58: :
  {0,6,6,0,6,6,0},
  -- 59: ;
  {0,6,6,0,6,4,8},
  -- 60: <
  {2,4,8,16,8,4,2},
  -- 61: =
  {0,0,31,0,31,0,0},
  -- 62: >
  {8,4,2,1,2,4,8},
  -- 63: ?
  {14,17,1,6,4,0,4},
  -- 64: @
  {14,17,1,13,21,21,14},
  -- 65: A
  {14,17,17,31,17,17,17},
  -- 66: B
  {30,17,17,30,17,17,30},
  -- 67: C
  {14,17,16,16,16,17,14},
  -- 68: D
  {28,18,17,17,17,18,28},
  -- 69: E
  {31,16,16,30,16,16,31},
  -- 70: F
  {31,16,16,30,16,16,16},
  -- 71: G
  {14,17,16,23,17,17,14},
  -- 72: H
  {17,17,17,31,17,17,17},
  -- 73: I
  {14,4,4,4,4,4,14},
  -- 74: J
  {7,2,2,2,2,18,12},
  -- 75: K
  {17,18,20,24,20,18,17},
  -- 76: L
  {16,16,16,16,16,16,31},
  -- 77: M
  {17,27,21,21,17,17,17},
  -- 78: N
  {17,25,21,21,19,17,17},
  -- 79: O
  {14,17,17,17,17,17,14},
  -- 80: P
  {30,17,17,30,16,16,16},
  -- 81: Q
  {14,17,17,17,21,18,13},
  -- 82: R
  {30,17,17,30,20,18,17},
  -- 83: S
  {14,17,16,14,1,17,14},
  -- 84: T
  {31,4,4,4,4,4,4},
  -- 85: U
  {17,17,17,17,17,17,14},
  -- 86: V
  {17,17,17,17,17,10,4},
  -- 87: W
  {17,17,17,21,21,21,10},
  -- 88: X
  {17,17,10,4,10,17,17},
  -- 89: Y
  {17,17,10,4,4,4,4},
  -- 90: Z
  {31,1,2,4,8,16,31},
  -- 91: [
  {14,8,8,8,8,8,14},
  -- 92: backslash
  {16,8,4,4,2,1,0},
  -- 93: ]
  {14,2,2,2,2,2,14},
  -- 94: ^
  {4,10,17,0,0,0,0},
  -- 95: _
  {0,0,0,0,0,0,31},
  -- 96: `
  {8,4,0,0,0,0,0},
  -- 97: a
  {0,0,14,1,15,17,15},
  -- 98: b
  {16,16,28,18,18,18,28},
  -- 99: c
  {0,0,14,16,16,17,14},
  -- 100: d
  {1,1,7,9,9,9,7},
  -- 101: e
  {0,0,14,17,31,16,14},
  -- 102: f
  {6,8,8,28,8,8,8},
  -- 103: g
  {0,0,15,17,15,1,14},
  -- 104: h
  {16,16,28,18,18,18,18},
  -- 105: i
  {0,4,0,12,4,4,14},
  -- 106: j
  {0,2,0,6,2,2,18,12},
  -- 107: k
  {16,16,18,20,24,20,18},
  -- 108: l
  {12,4,4,4,4,4,14},
  -- 109: m
  {0,0,26,21,21,17,17},
  -- 110: n
  {0,0,28,18,18,18,18},
  -- 111: o
  {0,0,14,17,17,17,14},
  -- 112: p
  {0,0,28,18,28,16,16},
  -- 113: q
  {0,0,7,9,7,1,1},
  -- 114: r
  {0,0,22,24,16,16,16},
  -- 115: s
  {0,0,14,16,14,1,14},
  -- 116: t
  {8,8,28,8,8,9,6},
  -- 117: u
  {0,0,18,18,18,18,13},
  -- 118: v
  {0,0,17,17,17,10,4},
  -- 119: w
  {0,0,17,17,21,21,10},
  -- 120: x
  {0,0,17,10,4,10,17},
  -- 121: y
  {0,0,18,18,15,2,12},
  -- 122: z
  {0,0,31,2,4,8,31},
  -- 123: {
  {2,4,4,8,4,4,2},
  -- 124: |
  {4,4,4,4,4,4,4},
  -- 125: }
  {8,4,4,2,4,4,8},
  -- 126: ~
  {0,8,21,2,0,0,0},
}

-- ---------------------------------------------------------------------------
-- Canvas constructor
-- ---------------------------------------------------------------------------

local Canvas = {}
Canvas.__index = Canvas
--:: CanvasInst = { width: integer, height: integer, channels: integer, pixels: { [integer]: integer }, set: (CanvasInst, integer, integer, integer, integer, integer, integer | nil) -> nil, get: (CanvasInst, integer, integer) -> (integer, integer, integer, integer), line: (CanvasInst, integer, integer, integer, integer, integer, integer, integer, integer | nil) -> nil, rect: (CanvasInst, integer, integer, integer, integer, integer, integer, integer, integer | nil) -> nil, fill_rect: (CanvasInst, integer, integer, integer, integer, integer, integer, integer, integer | nil) -> nil, circle: (CanvasInst, integer, integer, integer, integer, integer, integer, integer | nil) -> nil, fill_circle: (CanvasInst, integer, integer, integer, integer, integer, integer, integer | nil) -> nil, fill: (CanvasInst, integer, integer, integer, integer, integer, integer | nil) -> nil, ... }

function M.new(width, height, opts)
  if type(width) ~= "number" or width < 1 then
    return nil, "width must be a positive integer"
  end
  if type(height) ~= "number" or height < 1 then
    return nil, "height must be a positive integer"
  end
  opts = opts or {}
  local bg = opts.background or {r=255, g=255, b=255, a=255}
  local channels = opts.channels or 4
  local cv = setmetatable({
    width = width,
    height = height,
    channels = channels,
    pixels = {},
  }, Canvas)
  local br, bg_, bb, ba = bg.r or 255, bg.g or 255, bg.b or 255, bg.a or 255
  local n = width * height
  local px = cv.pixels
  for i = 0, n - 1 do
    local base = i * 4
    px[base + 1] = br
    px[base + 2] = bg_
    px[base + 3] = bb
    px[base + 4] = ba
  end
  return cv
end

-- ---------------------------------------------------------------------------
-- Pixel access
-- ---------------------------------------------------------------------------

--: (self: CanvasInst, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:set(x, y, r, g, b, a)
  if x < 0 or x >= self.width or y < 0 or y >= self.height then return end
  local base = (y * self.width + x) * 4
  local px = self.pixels
  px[base + 1] = r
  px[base + 2] = g
  px[base + 3] = b
  px[base + 4] = a or 255
end

--: (self: CanvasInst, integer, integer) -> (integer, integer, integer, integer)
function Canvas:get(x, y)
  if x < 0 or x >= self.width or y < 0 or y >= self.height then
    return 0, 0, 0, 0
  end
  local base = (y * self.width + x) * 4
  local px = self.pixels
  return px[base + 1], px[base + 2], px[base + 3], px[base + 4]
end

-- ---------------------------------------------------------------------------
-- Drawing primitives
-- ---------------------------------------------------------------------------

--: (self: CanvasInst, integer, integer, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:line(x0, y0, x1, y1, r, g, b, a)
  local dx = math.abs(x1 - x0)
  local dy = math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx - dy
  while true do
    self:set(x0, y0, r, g, b, a)
    if x0 == x1 and y0 == y1 then break end
    local e2 = err * 2
    if e2 > -dy then
      err = err - dy
      x0 = x0 + sx
    end
    if e2 < dx then
      err = err + dx
      y0 = y0 + sy
    end
  end
end

--: (self: CanvasInst, integer, integer, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:rect(x, y, w, h, r, g, b, a)
  self:line(x, y, x + w - 1, y, r, g, b, a)
  self:line(x + w - 1, y, x + w - 1, y + h - 1, r, g, b, a)
  self:line(x + w - 1, y + h - 1, x, y + h - 1, r, g, b, a)
  self:line(x, y + h - 1, x, y, r, g, b, a)
end

--: (self: CanvasInst, integer, integer, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:fill_rect(x, y, w, h, r, g, b, a)
  local x1 = x + w - 1
  local y1 = y + h - 1
  for py = y, y1 do
    for px = x, x1 do
      self:set(px, py, r, g, b, a)
    end
  end
end

--: (self: CanvasInst, integer, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:circle(cx, cy, radius, r, g, b, a)
  local x = 0
  local y = radius
  local d = 3 - 2 * radius
  local function plot8(px, py)
    self:set(cx + px, cy + py, r, g, b, a)
    self:set(cx - px, cy + py, r, g, b, a)
    self:set(cx + px, cy - py, r, g, b, a)
    self:set(cx - px, cy - py, r, g, b, a)
    self:set(cx + py, cy + px, r, g, b, a)
    self:set(cx - py, cy + px, r, g, b, a)
    self:set(cx + py, cy - px, r, g, b, a)
    self:set(cx - py, cy - px, r, g, b, a)
  end
  plot8(x, y)
  while y >= x do
    x = x + 1
    if d > 0 then
      y = y - 1
      d = d + 4 * (x - y) + 10
    else
      d = d + 4 * x + 6
    end
    plot8(x, y)
  end
end

--: (self: CanvasInst, integer, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:fill_circle(cx, cy, radius, r, g, b, a)
  for py = cy - radius, cy + radius do
    for px = cx - radius, cx + radius do
      local dx = px - cx
      local dy = py - cy
      if dx * dx + dy * dy <= radius * radius then
        self:set(px, py, r, g, b, a)
      end
    end
  end
end

-- Filled triangle via scanline rasterization
--: (self: CanvasInst, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:triangle(x0, y0, x1, y1, x2, y2, r, g, b, a)
  -- Sort vertices by y
  if y1 < y0 then x0,y0,x1,y1 = x1,y1,x0,y0 end
  if y2 < y0 then x0,y0,x2,y2 = x2,y2,x0,y0 end
  if y2 < y1 then x1,y1,x2,y2 = x2,y2,x1,y1 end
  -- y0 <= y1 <= y2
  local function fill_flat_bottom(ax, ay, bx, by, cx, cy)
    -- ay == by (flat top), cy is the apex
    local inv1 = (cx - ax) / (cy - ay)
    local inv2 = (cx - bx) / (cy - by)
    local curx1 = ax
    local curx2 = bx
    for py = ay, cy do
      local ix1 = math.floor(math.min(curx1, curx2) + 0.5)
      local ix2 = math.floor(math.max(curx1, curx2) + 0.5)
      for px = ix1, ix2 do
        self:set(px, py, r, g, b, a)
      end
      curx1 = curx1 + inv1
      curx2 = curx2 + inv2
    end
  end
  local function fill_flat_top(ax, ay, bx, by, cx, cy)
    -- cy == by (flat bottom), ax is the apex
    local inv1 = (bx - ax) / (by - ay)
    local inv2 = (cx - ax) / (cy - ay)
    local curx1 = ax
    local curx2 = ax
    for py = ay, by do
      local ix1 = math.floor(math.min(curx1, curx2) + 0.5)
      local ix2 = math.floor(math.max(curx1, curx2) + 0.5)
      for px = ix1, ix2 do
        self:set(px, py, r, g, b, a)
      end
      curx1 = curx1 + inv1
      curx2 = curx2 + inv2
    end
  end
  if y1 == y2 then
    fill_flat_top(x0, y0, x1, y1, x2, y2)
  elseif y0 == y1 then
    fill_flat_bottom(x0, y0, x1, y1, x2, y2)
  else
    -- Split into flat-bottom and flat-top triangles
    local x3 = math.floor(x0 + (x2 - x0) * (y1 - y0) / (y2 - y0) + 0.5)
    local y3 = y1
    fill_flat_top(x0, y0, x1, y1, x3, y3)
    fill_flat_bottom(x1, y1, x3, y3, x2, y2)
  end
end

-- Midpoint ellipse algorithm
--: (self: CanvasInst, integer, integer, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:ellipse(cx, cy, rx, ry, r, g, b, a)
  local x = 0
  local y = ry
  local rx2 = rx * rx
  local ry2 = ry * ry
  local p = ry2 - rx2 * ry + rx2 / 4
  local function plot4(px, py)
    self:set(cx + px, cy + py, r, g, b, a)
    self:set(cx - px, cy + py, r, g, b, a)
    self:set(cx + px, cy - py, r, g, b, a)
    self:set(cx - px, cy - py, r, g, b, a)
  end
  -- Region 1
  while 2 * ry2 * x < 2 * rx2 * y do
    plot4(x, y)
    x = x + 1
    if p < 0 then
      p = p + 2 * ry2 * x + ry2
    else
      y = y - 1
      p = p + 2 * ry2 * x - 2 * rx2 * y + ry2
    end
  end
  -- Region 2
  p = ry2 * (x + 0.5) * (x + 0.5) + rx2 * (y - 1) * (y - 1) - rx2 * ry2
  while y >= 0 do
    plot4(x, y)
    y = y - 1
    if p > 0 then
      p = p - 2 * rx2 * y + rx2
    else
      x = x + 1
      p = p + 2 * ry2 * x - 2 * rx2 * y + rx2
    end
  end
end

-- ---------------------------------------------------------------------------
-- Text rendering
-- ---------------------------------------------------------------------------

--: (self: CanvasInst, integer, integer, string, integer, integer, integer, integer | nil) -> nil
function Canvas:text(x, y, str, r, g, b, a)
  local cx = x
  for i = 1, #str do
    local code = str:byte(i)
    local glyph = FONT[code - 31]  -- index 1 = space (32)
    if glyph then
      for row = 1, FONT_H do
        local bits = --[[:! integer ]] glyph[row]
        for col = 0, FONT_W - 1 do
          if bit.band(bits, bit.lshift(1, FONT_W - 1 - col)) ~= 0 then
            self:set(cx + col, y + row - 1, r, g, b, a)
          end
        end
      end
    end
    cx = cx + FONT_W + 1
  end
end

function M.text_size(str)
  local n = #str
  if n == 0 then return {w = 0, h = 0} end
  return {w = n * (FONT_W + 1) - 1, h = FONT_H}
end

-- Also available as method
Canvas.text_size = function(self, str)
  return M.text_size(str)
end

-- ---------------------------------------------------------------------------
-- Flood fill (iterative BFS)
-- ---------------------------------------------------------------------------

--: (self: CanvasInst, integer, integer, integer, integer, integer, integer | nil) -> nil
function Canvas:fill(x, y, r, g, b, a)
  local w, h = self.width, self.height
  if x < 0 or x >= w or y < 0 or y >= h then return end
  local tr, tg, tb, ta = self:get(x, y)
  -- If already the target color, nothing to do
  if tr == r and tg == g and tb == b and (ta == (a or 255)) then return end
  local queue = {x, y}
  local head = 1
  local visited = {}
  local function key(px, py) return py * w + px end
  visited[key(x, y)] = true
  while head <= #queue do
    local px = --[[:! integer ]] queue[head]
    local py = --[[:! integer ]] queue[head + 1]
    head = head + 2
    local cr, cg, cb, ca = self:get(px, py)
    if cr == tr and cg == tg and cb == tb and ca == ta then
      self:set(px, py, r, g, b, a)
      local neighbors = {
        {px-1, py}, {px+1, py}, {px, py-1}, {px, py+1}
      }
      for _, n in ipairs(neighbors) do
        local nx, ny = n[1], n[2]
        if nx >= 0 and nx < w and ny >= 0 and ny < h then
          local k = key(nx, ny)
          if not visited[k] then
            visited[k] = true
            queue[#queue + 1] = nx
            queue[#queue + 1] = ny
          end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Image operations
-- ---------------------------------------------------------------------------

--: (self: CanvasInst, integer, integer, integer, integer | nil) -> nil
function Canvas:clear(r, g, b, a)
  local n = self.width * self.height
  local px = self.pixels
  local aa = a or 255
  for i = 0, n - 1 do
    local base = i * 4
    px[base + 1] = r
    px[base + 2] = g
    px[base + 3] = b
    px[base + 4] = aa
  end
end

--: (self: CanvasInst, CanvasInst, integer, integer) -> nil
function Canvas:blit(other, dst_x, dst_y)
  for sy = 0, other.height - 1 do
    for sx = 0, other.width - 1 do
      local r, g, b, a = other:get(sx, sy)
      self:set(dst_x + sx, dst_y + sy, r, g, b, a)
    end
  end
end

--: (self: CanvasInst, integer, integer, integer, integer) -> CanvasInst
function Canvas:crop(x, y, w, h)
  local cv = M.new(w, h)
  for sy = 0, h - 1 do
    for sx = 0, w - 1 do
      local r, g, b, a = self:get(x + sx, y + sy)
      cv:set(sx, sy, r, g, b, a)
    end
  end
  return cv
end

--: (self: CanvasInst, integer, integer) -> CanvasInst
function Canvas:scale(new_w, new_h)
  local cv = M.new(new_w, new_h)
  local sx_ratio = self.width / new_w
  local sy_ratio = self.height / new_h
  for ny = 0, new_h - 1 do
    for nx = 0, new_w - 1 do
      local ox = math.floor(nx * sx_ratio)
      local oy = math.floor(ny * sy_ratio)
      local r, g, b, a = self:get(ox, oy)
      cv:set(nx, ny, r, g, b, a)
    end
  end
  return cv
end

-- Flip horizontally in place
--: (self: CanvasInst) -> nil
function Canvas:flip_h()
  local w, h = self.width, self.height
  for py = 0, h - 1 do
    for px = 0, math.floor(w / 2) - 1 do
      local r1, g1, b1, a1 = self:get(px, py)
      local r2, g2, b2, a2 = self:get(w - 1 - px, py)
      self:set(px, py, r2, g2, b2, a2)
      self:set(w - 1 - px, py, r1, g1, b1, a1)
    end
  end
end

-- Flip vertically in place
--: (self: CanvasInst) -> nil
function Canvas:flip_v()
  local w, h = self.width, self.height
  for py = 0, math.floor(h / 2) - 1 do
    for px = 0, w - 1 do
      local r1, g1, b1, a1 = self:get(px, py)
      local r2, g2, b2, a2 = self:get(px, h - 1 - py)
      self:set(px, py, r2, g2, b2, a2)
      self:set(px, h - 1 - py, r1, g1, b1, a1)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

-- PPM P6 (binary RGB)
--: (self: CanvasInst) -> string
function Canvas:to_ppm()
  local w, h = self.width, self.height
  local header = "P6\n" .. w .. " " .. h .. "\n255\n"
  local t = {header}
  local px = self.pixels
  for i = 0, w * h - 1 do
    local base = i * 4
    t[#t + 1] = string.char(px[base + 1], px[base + 2], px[base + 3])
  end
  return table.concat(t)
end

-- PGM P5 (binary grayscale, average RGB)
--: (self: CanvasInst) -> string
function Canvas:to_pgm()
  local w, h = self.width, self.height
  local header = "P5\n" .. w .. " " .. h .. "\n255\n"
  local t = {header}
  local px = self.pixels
  for i = 0, w * h - 1 do
    local base = i * 4
    local gray = math.floor((px[base + 1] + px[base + 2] + px[base + 3]) / 3 + 0.5)
    t[#t + 1] = string.char(gray)
  end
  return table.concat(t)
end

-- BMP 24-bit uncompressed (bottom-up row order)
--: (self: CanvasInst) -> string
function Canvas:to_bmp()
  local w, h = self.width, self.height
  -- Row stride: padded to 4 bytes
  local row_stride = math.floor((w * 3 + 3) / 4) * 4
  local pixel_data_size = row_stride * h
  local file_size = 54 + pixel_data_size

  local function le32(n)
    n = n % (2^32)
    return string.char(
      bit.band(n, 0xff),
      bit.band(bit.rshift(n, 8), 0xff),
      bit.band(bit.rshift(n, 16), 0xff),
      bit.band(bit.rshift(n, 24), 0xff)
    )
  end
  local function le16(n)
    return string.char(bit.band(n, 0xff), bit.band(bit.rshift(n, 8), 0xff))
  end

  local t = --[[:! string[] ]] {}
  -- BITMAPFILEHEADER (14 bytes)
  t[#t + 1] = "BM"           -- signature
  t[#t + 1] = le32(file_size)
  t[#t + 1] = le16(0)        -- reserved1
  t[#t + 1] = le16(0)        -- reserved2
  t[#t + 1] = le32(54)       -- offset to pixel data

  -- BITMAPINFOHEADER (40 bytes)
  t[#t + 1] = le32(40)       -- header size
  t[#t + 1] = le32(w)
  t[#t + 1] = le32(h)
  t[#t + 1] = le16(1)        -- color planes
  t[#t + 1] = le16(24)       -- bits per pixel
  t[#t + 1] = le32(0)        -- compression (none)
  t[#t + 1] = le32(pixel_data_size)
  t[#t + 1] = le32(2835)     -- x pixels per meter (~72 dpi)
  t[#t + 1] = le32(2835)     -- y pixels per meter
  t[#t + 1] = le32(0)        -- colors in table
  t[#t + 1] = le32(0)        -- important colors

  -- Pixel data (bottom-up)
  local px = self.pixels
  local pad = string.rep("\0", row_stride - w * 3)
  for py = h - 1, 0, -1 do
    local row = {}
    for pix = 0, w - 1 do
      local base = (py * w + pix) * 4
      -- BMP uses BGR order
      row[#row + 1] = string.char(px[base + 3], px[base + 2], px[base + 1])
    end
    t[#t + 1] = table.concat(row)
    if #pad > 0 then
      t[#t + 1] = pad
    end
  end

  return table.concat(--[[:! { [integer]: string }]] t)
end

-- ---------------------------------------------------------------------------
-- Import
-- ---------------------------------------------------------------------------

function M.from_raw(width, height, bytes, channels)
  channels = channels or 4
  local cv = M.new(width, height)
  local px = cv.pixels
  for i = 0, width * height - 1 do
    local base = i * 4
    local src = i * channels
    px[base + 1] = bytes:byte(src + 1) or 0
    px[base + 2] = bytes:byte(src + 2) or 0
    px[base + 3] = bytes:byte(src + 3) or 0
    if channels >= 4 then
      px[base + 4] = bytes:byte(src + 4) or 255
    else
      px[base + 4] = 255
    end
  end
  return cv
end

return M
