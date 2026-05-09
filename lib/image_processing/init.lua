if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Image = { width: integer, height: integer, channels: integer, data: { [integer]: integer } }
--:: Kernel = { width: integer, height: integer, data: { [integer]: number } }

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local math_sqrt  = math.sqrt
local math_exp   = math.exp
local math_ceil  = math.ceil
local math_abs   = math.abs
local math_pi    = math.pi

-- clamp a value to [0, 255]
local function clamp(v)
  if v < 0 then return 0
  elseif v > 255 then return 255
  else return math_floor(v + 0.5)
  end
end

-- pixel index (1-indexed x,y) → data offset (1-indexed)
local function idx(img, x, y)
  return ((y - 1) * img.width + (x - 1)) * img.channels + 1
end

-- ──────────────────────────────────────────────────────────────────
-- Image construction
-- ──────────────────────────────────────────────────────────────────

function M.new(width, height, channels, data)
  if not width or not height or not channels then
    return nil, "image_processing.new: width, height, channels required"
  end
  local n = width * height * channels
  local d
  if data then
    d = data
  else
    d = {}
    for i = 1, n do d[i] = 0 end
  end
  local img = { width = width, height = height, channels = channels, data = d }
  return setmetatable(img, { __index = M })
end

function M.from_bytes(width, height, channels, byte_string)
  if type(byte_string) ~= "string" then
    return nil, "image_processing.from_bytes: byte_string must be a string"
  end
  local n = width * height * channels
  local d = {}
  for i = 1, n do
    d[i] = byte_string:byte(i)
  end
  local img = { width = width, height = height, channels = channels, data = d }
  return setmetatable(img, { __index = M })
end

function M:to_bytes()
  local t = {}
  for i = 1, #self.data do
    t[i] = string.char(self.data[i])
  end
  return table.concat(t)
end

-- ──────────────────────────────────────────────────────────────────
-- Pixel access
-- ──────────────────────────────────────────────────────────────────

function M:get(x, y)
  if x < 1 or x > self.width or y < 1 or y > self.height then
    return nil, "image_processing.get: out of bounds (" .. x .. "," .. y .. ")"
  end
  local i = idx(self, x, y)
  local ch = self.channels
  if ch == 1 then
    return self.data[i]
  elseif ch == 2 then
    return self.data[i], self.data[i+1]
  elseif ch == 3 then
    return self.data[i], self.data[i+1], self.data[i+2]
  else
    return self.data[i], self.data[i+1], self.data[i+2], self.data[i+3]
  end
end

function M:set(x, y, r, g, b, a)
  if x < 1 or x > self.width or y < 1 or y > self.height then
    return nil, "image_processing.set: out of bounds (" .. x .. "," .. y .. ")"
  end
  local i = idx(self, x, y)
  local ch = self.channels
  self.data[i] = r or 0
  if ch >= 2 then self.data[i+1] = g or 0 end
  if ch >= 3 then self.data[i+2] = b or 0 end
  if ch >= 4 then self.data[i+3] = a or 255 end
  return true
end

-- ──────────────────────────────────────────────────────────────────
-- Color space conversions
-- ──────────────────────────────────────────────────────────────────

function M.rgb_to_grayscale(img)
  local img = img
  local w, h = img.width, img.height
  local src = img.data
  local dst = {}
  local n = w * h
  if img.channels == 1 then
    -- already grayscale, copy
    for i = 1, n do dst[i] = src[i] end
  elseif img.channels == 3 then
    for i = 1, n do
      local o = (i - 1) * 3
      dst[i] = clamp(0.2126 * src[o+1] + 0.7152 * src[o+2] + 0.0722 * src[o+3])
    end
  elseif img.channels == 4 then
    for i = 1, n do
      local o = (i - 1) * 4
      dst[i] = clamp(0.2126 * src[o+1] + 0.7152 * src[o+2] + 0.0722 * src[o+3])
    end
  else
    return nil, "image_processing.rgb_to_grayscale: unsupported channel count"
  end
  local out = { width = w, height = h, channels = 1, data = dst }
  return setmetatable(out, { __index = M })
end

function M.grayscale_to_rgb(img)
  local img = img
  if img.channels ~= 1 then
    return nil, "image_processing.grayscale_to_rgb: expected 1-channel image"
  end
  local w, h = img.width, img.height
  local src = img.data
  local n = w * h
  local dst = {}
  for i = 1, n do
    local v = src[i]
    local o = (i - 1) * 3
    dst[o+1] = v
    dst[o+2] = v
    dst[o+3] = v
  end
  local out = { width = w, height = h, channels = 3, data = dst }
  return setmetatable(out, { __index = M })
end

-- h in [0,360), s,v in [0,1]
--: (r: number, g: number, b: number) -> (number, number, number)
function M.rgb_to_hsv(r, g, b)
  local rf = r / 255
  local gf = g / 255
  local bf = b / 255
  local mx = math_max(rf, gf, bf)
  local mn = math_min(rf, gf, bf)
  local delta = mx - mn
  local v = mx
  local s = mx == 0 and 0 or delta / mx
  local h = 0 --: number
  if delta == 0 then
    h = 0
  elseif mx == rf then
    h = 60 * (((gf - bf) / delta) % 6)
  elseif mx == gf then
    h = 60 * ((bf - rf) / delta + 2)
  else
    h = 60 * ((rf - gf) / delta + 4)
  end
  if h < 0 then h = h + 360 end
  return h, s, v
end

function M.hsv_to_rgb(h, s, v)
  local c = v * s
  local x = c * (1 - math_abs((h / 60) % 2 - 1))
  local m = v - c
  local rf, gf, bf
  if h < 60 then      rf, gf, bf = c, x, 0
  elseif h < 120 then rf, gf, bf = x, c, 0
  elseif h < 180 then rf, gf, bf = 0, c, x
  elseif h < 240 then rf, gf, bf = 0, x, c
  elseif h < 300 then rf, gf, bf = x, 0, c
  else                rf, gf, bf = c, 0, x
  end
  return clamp((rf + m) * 255), clamp((gf + m) * 255), clamp((bf + m) * 255)
end

function M.apply_lut(img, lut)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local n = w * h * ch
  local dst = {}
  for i = 1, n do
    dst[i] = lut[src[i]] or src[i]
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

-- ──────────────────────────────────────────────────────────────────
-- Pixel-level operations
-- ──────────────────────────────────────────────────────────────────

function M.brightness(img, delta)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local n = w * h * ch
  local dst = {}
  for i = 1, n do
    dst[i] = clamp(src[i] + delta)
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.contrast(img, factor)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local n = w * h * ch
  local dst = {}
  for i = 1, n do
    dst[i] = clamp((src[i] - 128) * factor + 128)
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.invert(img)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local n = w * h * ch
  local dst = {}
  if ch == 4 then
    -- preserve alpha
    for y = 1, h do
      for x = 1, w do
        local i = ((y-1)*w + (x-1)) * 4 + 1
        dst[i]   = 255 - src[i]
        dst[i+1] = 255 - src[i+1]
        dst[i+2] = 255 - src[i+2]
        dst[i+3] = src[i+3]
      end
    end
  else
    for i = 1, n do
      dst[i] = 255 - src[i]
    end
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.threshold(img, t)
  local img = img
  if img.channels ~= 1 then
    return nil, "image_processing.threshold: expected 1-channel (grayscale) image"
  end
  local w, h = img.width, img.height
  local src = img.data
  local n = w * h
  local dst = {}
  for i = 1, n do
    dst[i] = src[i] >= t and 255 or 0
  end
  local out = { width = w, height = h, channels = 1, data = dst }
  return setmetatable(out, { __index = M })
end

function M.gamma(img, g)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local n = w * h * ch
  local inv_g = 1 / g
  -- precompute LUT for speed
  local lut = {}
  for i = 0, 255 do
    lut[i] = clamp(((i / 255) ^ inv_g) * 255)
  end
  local dst = {}
  for i = 1, n do
    dst[i] = lut[src[i]]
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

-- ──────────────────────────────────────────────────────────────────
-- Geometric transforms
-- ──────────────────────────────────────────────────────────────────

function M.crop(img, x1, y1, x2, y2)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  if x1 < 1 or y1 < 1 or x2 > w or y2 > h or x1 > x2 or y1 > y2 then
    return nil, "image_processing.crop: out of bounds or invalid rectangle"
  end
  local nw = x2 - x1 + 1
  local nh = y2 - y1 + 1
  local src = img.data
  local dst = {}
  local di = 1
  for y = y1, y2 do
    local row_start = ((y - 1) * w + (x1 - 1)) * ch + 1
    for c = 0, nw * ch - 1 do
      dst[di] = src[row_start + c]
      di = di + 1
    end
  end
  local out = { width = nw, height = nh, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.flip_h(img)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local dst = {}
  for y = 1, h do
    for x = 1, w do
      local si = ((y-1)*w + (x-1)) * ch + 1
      local di = ((y-1)*w + (w-x)) * ch + 1
      for c = 0, ch - 1 do
        dst[di + c] = src[si + c]
      end
    end
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.flip_v(img)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local dst = {}
  for y = 1, h do
    local sy = h - y + 1
    local s_row = (sy - 1) * w * ch + 1
    local d_row = (y  - 1) * w * ch + 1
    for x = 0, w * ch - 1 do
      dst[d_row + x] = src[s_row + x]
    end
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

-- n = 1,2,3 clockwise 90-degree rotations
function M.rotate_90(img, n)
  n = (n or 1) % 4
  if n == 0 then
    -- copy
    local d = {}
    for i = 1, #img.data do d[i] = img.data[i] end
    local out = { width = img.width, height = img.height, channels = img.channels, data = d }
    return setmetatable(out, { __index = M })
  end
  -- apply one rotation at a time
  local cur = img --: Image
  for _ = 1, n do
    local w, h, ch = cur.width, cur.height, cur.channels
    local src = cur.data
    local nw, nh = h, w
    local dst = {}
    -- 90 CW: dst(x, y) = src(y, h+1-x) in 1-indexed terms
    -- new coords: new x in [1,nw=h], new y in [1,nh=w]
    for ny = 1, nh do
      for nx = 1, nw do
        local sx = ny
        local sy = nw - nx + 1
        local si = ((sy-1)*w + (sx-1)) * ch + 1
        local di = ((ny-1)*nw + (nx-1)) * ch + 1
        for c = 0, ch - 1 do
          dst[di + c] = src[si + c]
        end
      end
    end
    local out = { width = nw, height = nh, channels = ch, data = dst }
    cur = setmetatable(out, { __index = M })
  end
  return cur
end

function M.scale_nearest(img, new_w, new_h)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local dst = {}
  local di = 1
  for ny = 1, new_h do
    local sy = math_floor((ny - 1) * h / new_h) + 1
    for nx = 1, new_w do
      local sx = math_floor((nx - 1) * w / new_w) + 1
      local si = ((sy-1)*w + (sx-1)) * ch + 1
      for c = 0, ch - 1 do
        dst[di] = src[si + c]
        di = di + 1
      end
    end
  end
  local out = { width = new_w, height = new_h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.scale_bilinear(img, new_w, new_h)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local dst = {}
  local di = 1
  for ny = 1, new_h do
    local fy = (ny - 1) * (h - 1) / (new_h - 1)
    if new_h == 1 then fy = 0 end
    local y0 = math_floor(fy) + 1
    local y1 = math_min(y0 + 1, h)
    local ty = fy - math_floor(fy)
    for nx = 1, new_w do
      local fx = (nx - 1) * (w - 1) / (new_w - 1)
      if new_w == 1 then fx = 0 end
      local x0 = math_floor(fx) + 1
      local x1 = math_min(x0 + 1, w)
      local tx = fx - math_floor(fx)
      local i00 = ((y0-1)*w + (x0-1)) * ch + 1
      local i10 = ((y0-1)*w + (x1-1)) * ch + 1
      local i01 = ((y1-1)*w + (x0-1)) * ch + 1
      local i11 = ((y1-1)*w + (x1-1)) * ch + 1
      for c = 0, ch - 1 do
        local v = (1-ty)*((1-tx)*src[i00+c] + tx*src[i10+c])
                +    ty *((1-tx)*src[i01+c] + tx*src[i11+c])
        dst[di] = clamp(v)
        di = di + 1
      end
    end
  end
  local out = { width = new_w, height = new_h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

-- ──────────────────────────────────────────────────────────────────
-- Convolution / filters
-- ──────────────────────────────────────────────────────────────────

-- kernel: { width, height, data }  (row-major float values)
-- replicate border padding
function M.convolve(img, kernel)
  local img = img
  local kernel = kernel
  local iw, ih, ch = img.width, img.height, img.channels
  local kw, kh = kernel.width, kernel.height
  local kdata = kernel.data
  local src = img.data
  local dst = {}
  local kcy = math_floor(kh / 2)
  local kcx = math_floor(kw / 2)
  local di = 1
  for y = 1, ih do
    for x = 1, iw do
      for c = 0, ch - 1 do
        local acc = 0
        for ky = 0, kh - 1 do
          local sy = math_max(1, math_min(ih, y + ky - kcy))
          for kx = 0, kw - 1 do
            local sx = math_max(1, math_min(iw, x + kx - kcx))
            local si = ((sy-1)*iw + (sx-1)) * ch + c + 1
            acc = acc + src[si] * kdata[ky * kw + kx + 1]
          end
        end
        dst[di] = clamp(acc)
        di = di + 1
      end
    end
  end
  local out = { width = iw, height = ih, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.blur_box(img, radius)
  local img = img
  local r = radius or 1
  local size = 2 * r + 1
  local n = size * size
  local kdata = {}
  for i = 1, n do kdata[i] = 1 / n end
  return M.convolve(img, { width = size, height = size, data = kdata })
end

-- Gaussian blur via separable passes
--: (img: Image, sigma: number) -> unknown
function M.blur_gaussian(img, sigma)
  local img = img
  local ks = math_ceil(3 * sigma) * 2 + 1
  local half = math_floor(ks / 2)
  -- build 1D kernel
  local k1d = {}
  local sum = 0.0 --: number
  for i = 0, ks - 1 do
    local x = i - half
    local v = math_exp(-x*x / (2*sigma*sigma))
    k1d[i+1] = v
    sum = sum + v
  end
  for i = 1, ks do k1d[i] = k1d[i] / sum end
  -- horizontal pass
  local h_kernel = { width = ks, height = 1, data = k1d }
  local tmp = M.convolve(img, h_kernel)
  -- vertical pass
  local v_kernel = { width = 1, height = ks, data = k1d }
  return M.convolve(tmp, v_kernel)
end

function M.sharpen(img)
  local img = img
  local kernel = {
    width = 3, height = 3,
    data = {
       0, -1,  0,
      -1,  5, -1,
       0, -1,  0,
    }
  }
  return M.convolve(img, kernel)
end

-- Sobel edge detection — returns grayscale magnitude image
function M.edge_detect(img)
  local img = img
  local gray = img --: Image
  if img.channels ~= 1 then
    local g, _err = M.rgb_to_grayscale(img)
    if not g then return nil, _err end
    gray = g
  end
  local iw, ih = gray.width, gray.height
  local src = gray.data
  local dst = {}
  for y = 1, ih do
    for x = 1, iw do
      -- Sobel kernels
      local gx, gy = 0.0, 0.0 --: number
      local kx = { -1, 0, 1, -2, 0, 2, -1, 0, 1 } --: { [integer]: integer }
      local ky = { -1, -2, -1, 0, 0, 0, 1, 2, 1 } --: { [integer]: integer }
      for ky_i = 0, 2 do
        for kx_i = 0, 2 do
          local sy = math_max(1, math_min(ih, y + ky_i - 1))
          local sx = math_max(1, math_min(iw, x + kx_i - 1))
          local v = src[(sy-1)*iw + sx] or 0
          local kxv = kx[ky_i * 3 + kx_i + 1] or 0
          local kyv = ky[ky_i * 3 + kx_i + 1] or 0
          gx = gx + v * kxv
          gy = gy + v * kyv
        end
      end
      local mag = math_min(255, math_sqrt(gx*gx + gy*gy))
      dst[(y-1)*iw + x] = math_floor(mag + 0.5)
    end
  end
  local out = { width = iw, height = ih, channels = 1, data = dst }
  return setmetatable(out, { __index = M })
end

function M.emboss(img)
  local img = img
  local kernel = {
    width = 3, height = 3,
    data = {
      -2, -1, 0,
      -1,  1, 1,
       0,  1, 2,
    }
  }
  return M.convolve(img, kernel)
end

-- ──────────────────────────────────────────────────────────────────
-- Histogram
-- ──────────────────────────────────────────────────────────────────

-- Returns a table of tables, one per channel, each with indices [0..255]
-- For grayscale returns a single table (not nested in another)
function M.histogram(img)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local hists = {}
  for c = 1, ch do
    local hc = {} --: { [integer]: integer }
    for i = 0, 255 do hc[i] = 0 end
    hists[c] = hc
  end
  local hists_ = hists
  local n = w * h
  for i = 1, n do
    for c = 1, ch do
      local v = src[(i-1)*ch + c] or 0
      hists_[c][v] = (hists_[c][v] or 0) + 1
    end
  end
  if ch == 1 then
    return hists[1]
  end
  return hists
end

function M.equalize(img)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local src = img.data
  local n = w * h
  -- equalize each channel independently
  local luts = {}
  for c = 1, ch do
    local hist = {} --: { [integer]: integer }
    for i = 0, 255 do hist[i] = 0 end
    for i = 1, n do
      local v = src[(i-1)*ch + c] or 0
      hist[v] = (hist[v] or 0) + 1
    end
    -- CDF
    local cdf = {} --: { [integer]: integer }
    local cum = 0 --: integer
    for i = 0, 255 do
      cum = cum + (hist[i] or 0)
      cdf[i] = cum
    end
    -- find cdf_min (first non-zero)
    local cdf_min = 0 --: integer
    for i = 0, 255 do
      if (cdf[i] or 0) > 0 then cdf_min = cdf[i] or 0; break end
    end
    local lut = {} --: { [integer]: integer }
    for i = 0, 255 do
      lut[i] = math_floor(((cdf[i] or 0) - cdf_min) / (n - cdf_min) * 255 + 0.5)
      if n == cdf_min then lut[i] = 0 end
    end
    luts[c] = lut
  end
  local dst = {}
  for i = 1, n do
    for c = 1, ch do
      local vi = (i-1)*ch + c
      dst[vi] = luts[c][src[vi]]
    end
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

-- ──────────────────────────────────────────────────────────────────
-- Drawing
-- ──────────────────────────────────────────────────────────────────

local function set_pixel_raw(data, width, channels, x, y, r, g, b, a)
  local i = ((y-1)*width + (x-1)) * channels + 1
  data[i] = r
  if channels >= 2 then data[i+1] = g end
  if channels >= 3 then data[i+2] = b end
  if channels >= 4 then data[i+3] = a or 255 end
end

function M.fill(img, r, g, b, a)
  local img = img
  local w, h, ch = img.width, img.height, img.channels
  local dst = {}
  for y = 1, h do
    for x = 1, w do
      set_pixel_raw(dst, w, ch, x, y, r, g or 0, b or 0, a)
    end
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.draw_rect(img, x1, y1, x2, y2, r, g, b)
  local img = img
  -- copy image data
  local dst = {}
  for i = 1, #img.data do dst[i] = img.data[i] end
  local w, h, ch = img.width, img.height, img.channels
  -- clamp to image bounds
  local cx1 = math_max(1, x1)
  local cy1 = math_max(1, y1)
  local cx2 = math_min(w, x2)
  local cy2 = math_min(h, y2)
  -- top/bottom edges
  for x = cx1, cx2 do
    if y1 >= 1 and y1 <= h then set_pixel_raw(dst, w, ch, x, y1, r, g, b) end
    if y2 >= 1 and y2 <= h then set_pixel_raw(dst, w, ch, x, y2, r, g, b) end
  end
  -- left/right edges
  for y = cy1, cy2 do
    if x1 >= 1 and x1 <= w then set_pixel_raw(dst, w, ch, x1, y, r, g, b) end
    if x2 >= 1 and x2 <= w then set_pixel_raw(dst, w, ch, x2, y, r, g, b) end
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

function M.fill_rect(img, x1, y1, x2, y2, r, g, b)
  local img = img
  local dst = {}
  for i = 1, #img.data do dst[i] = img.data[i] end
  local w, h, ch = img.width, img.height, img.channels
  local cx1 = math_max(1, x1)
  local cy1 = math_max(1, y1)
  local cx2 = math_min(w, x2)
  local cy2 = math_min(h, y2)
  for y = cy1, cy2 do
    for x = cx1, cx2 do
      set_pixel_raw(dst, w, ch, x, y, r, g, b)
    end
  end
  local out = { width = w, height = h, channels = ch, data = dst }
  return setmetatable(out, { __index = M })
end

return M
