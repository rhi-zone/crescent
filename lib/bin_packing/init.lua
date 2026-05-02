if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Rect = { w: number, h: number, id: unknown }
--:: FreeRect = { x: number, y: number, w: number, h: number }
--:: PlacedRect = { id: unknown, x: number, y: number, w: number, h: number, rotated: boolean }

-- ========================
-- 1D BIN PACKING
-- ========================

-- First Fit: place each item in the first bin it fits.
-- items: array of numbers (sizes)
-- capacity: bin capacity
-- Returns array of bins (each bin is an array of item indices), or nil+errmsg
--: ({ [integer]: number }, number) -> ({ [integer]: { [integer]: integer } } | nil, string | nil)
function M.first_fit(items, capacity)
  if not capacity or capacity <= 0 then
    return nil, "capacity must be > 0"
  end
  --: { [integer]: { [integer]: integer } }
  local bins = {}
  --: { [integer]: number }
  local remaining = {}
  for i = 1, #items do
    local sz = items[i]
    if sz > capacity then
      return nil, "item " .. i .. " size " .. sz .. " exceeds capacity " .. capacity
    end
    local placed = false
    for b = 1, #bins do
      if remaining[b] >= sz then
        bins[b][#bins[b] + 1] = i
        remaining[b] = remaining[b] - sz
        placed = true
        break
      end
    end
    if not placed then
      local b = #bins + 1
      bins[b] = { i }
      remaining[b] = capacity - sz
    end
  end
  return bins
end

-- First Fit Decreasing: sort items by size descending, then first fit.
--: ({ [integer]: number }, number) -> ({ [integer]: { [integer]: integer } } | nil, string | nil)
function M.first_fit_decreasing(items, capacity)
  if not capacity or capacity <= 0 then
    return nil, "capacity must be > 0"
  end
  -- Build sorted index array (descending by size)
  --: { [integer]: integer }
  local order = {}
  for i = 1, #items do order[i] = i end
  table.sort(order, function(a, b) return items[a] > items[b] end)

  -- Check oversized items
  for i = 1, #order do
    local idx = order[i]
    if items[idx] > capacity then
      return nil, "item " .. idx .. " size " .. items[idx] .. " exceeds capacity " .. capacity
    end
  end

  --: { [integer]: { [integer]: integer } }
  local bins = {}
  --: { [integer]: number }
  local remaining = {}
  for i = 1, #order do
    local item_idx = order[i]
    local sz = items[item_idx]
    local placed = false
    for b = 1, #bins do
      if remaining[b] >= sz then
        bins[b][#bins[b] + 1] = item_idx
        remaining[b] = remaining[b] - sz
        placed = true
        break
      end
    end
    if not placed then
      local b = #bins + 1
      bins[b] = { item_idx }
      remaining[b] = capacity - sz
    end
  end
  return bins
end

-- Best Fit: place each item in the bin with least remaining space that still fits.
--: ({ [integer]: number }, number) -> ({ [integer]: { [integer]: integer } } | nil, string | nil)
function M.best_fit(items, capacity)
  if not capacity or capacity <= 0 then
    return nil, "capacity must be > 0"
  end
  --: { [integer]: { [integer]: integer } }
  local bins = {}
  --: { [integer]: number }
  local remaining = {}
  for i = 1, #items do
    local sz = items[i]
    if sz > capacity then
      return nil, "item " .. i .. " size " .. sz .. " exceeds capacity " .. capacity
    end
    local best_b = nil
    local best_rem = capacity + 1
    for b = 1, #bins do
      local r = remaining[b]
      if r >= sz and r < best_rem then
        best_b = b
        best_rem = r
      end
    end
    if best_b then
      bins[best_b][#bins[best_b] + 1] = i
      remaining[best_b] = remaining[best_b] - sz
    else
      local b = #bins + 1
      bins[b] = { i }
      remaining[b] = capacity - sz
    end
  end
  return bins
end

-- Best Fit Decreasing: sort items descending, then best fit.
--: ({ [integer]: number }, number) -> ({ [integer]: { [integer]: integer } } | nil, string | nil)
function M.best_fit_decreasing(items, capacity)
  if not capacity or capacity <= 0 then
    return nil, "capacity must be > 0"
  end
  --: { [integer]: integer }
  local order = {}
  for i = 1, #items do order[i] = i end
  table.sort(order, function(a, b) return items[a] > items[b] end)

  for i = 1, #order do
    local idx = order[i]
    if items[idx] > capacity then
      return nil, "item " .. idx .. " size " .. items[idx] .. " exceeds capacity " .. capacity
    end
  end

  --: { [integer]: { [integer]: integer } }
  local bins = {}
  --: { [integer]: number }
  local remaining = {}
  for i = 1, #order do
    local item_idx = order[i]
    local sz = items[item_idx]
    local best_b = nil
    local best_rem = capacity + 1
    for b = 1, #bins do
      local r = remaining[b]
      if r >= sz and r < best_rem then
        best_b = b
        best_rem = r
      end
    end
    if best_b then
      bins[best_b][#bins[best_b] + 1] = item_idx
      remaining[best_b] = remaining[best_b] - sz
    else
      local b = #bins + 1
      bins[b] = { item_idx }
      remaining[b] = capacity - sz
    end
  end
  return bins
end

-- Next Fit: only consider the current bin; open a new one if item doesn't fit.
--: ({ [integer]: number }, number) -> ({ [integer]: { [integer]: integer } } | nil, string | nil)
function M.next_fit(items, capacity)
  if not capacity or capacity <= 0 then
    return nil, "capacity must be > 0"
  end
  --: { [integer]: { [integer]: integer } }
  local bins = {}
  --: { [integer]: number }
  local remaining = {}
  local current = 0
  for i = 1, #items do
    local sz = items[i]
    if sz > capacity then
      return nil, "item " .. i .. " size " .. sz .. " exceeds capacity " .. capacity
    end
    if current == 0 or remaining[current] < sz then
      current = current + 1
      bins[current] = {}
      remaining[current] = capacity
    end
    bins[current][#bins[current] + 1] = i
    remaining[current] = remaining[current] - sz
  end
  return bins
end

-- Result helpers

-- Number of bins used.
function M.bin_count(bins)
  return #bins
end

-- Total fill / (bins * capacity). Returns 0 for empty bins.
--: ({ [integer]: { [integer]: integer } }, { [integer]: number }, number) -> number
function M.utilization(bins, items, capacity)
  if #bins == 0 then return 0 end
  --: number
  local total = 0
  for b = 1, #bins do
    for _, idx in ipairs(bins[b]) do
      total = total + items[idx]
    end
  end
  return total / (#bins * capacity)
end

-- Returns true if valid packing: all items placed exactly once, no bin overflows.
--: ({ [integer]: { [integer]: integer } }, { [integer]: number }, number) -> (boolean, string | nil)
function M.validate(bins, items, capacity)
  local seen = {}
  for b = 1, #bins do
    --: number
    local used = 0
    for _, idx in ipairs(bins[b]) do
      if seen[idx] then return false, "item " .. idx .. " placed twice" end
      seen[idx] = true
      used = used + items[idx]
    end
    if used > capacity then
      return false, "bin " .. b .. " overflow: " .. used .. " > " .. capacity
    end
  end
  for i = 1, #items do
    if not seen[i] then return false, "item " .. i .. " not placed" end
  end
  return true
end

-- ========================
-- 2D RECTANGLE BIN PACKING
-- ========================

-- Internal: check if rect r is fully contained within rect c.
local function rect_contains(cx, cy, cw, ch, rx, ry, rw, rh)
  return rx >= cx and ry >= cy and rx + rw <= cx + cw and ry + rh <= cy + ch
end

-- Internal: check if two placed rectangles overlap.
local function rects_overlap(ax, ay, aw, ah, bx, by, bw, bh)
  return not (ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay)
end

-- Guillotine algorithm.
-- rects: array of {w, h, [id=any]}
-- bin_w, bin_h: bin dimensions (0 = auto-grow)
-- opts: { allow_rotate=false, split="short_axis"|"long_axis" }
-- Returns: {placed=[{id,x,y,w,h,rotated}], unplaced=[...], w=used_w, h=used_h}
--: ({ [integer]: Rect }, number, number, { allow_rotate: boolean | nil, split: string | nil } | nil) -> { placed: { [integer]: PlacedRect }, unplaced: { [integer]: Rect }, w: number, h: number }
function M.guillotine(rects, bin_w, bin_h, opts)
  opts = (opts or {}) --[[:! { allow_rotate: boolean | nil, split: string | nil }]]
  local allow_rotate = opts.allow_rotate or false
  local split_mode = opts.split or "short_axis"
  local auto_grow = (bin_w == 0 or bin_h == 0)

  -- Sort by area descending for better packing
  local order = {}
  for i = 1, #rects do order[i] = i end
  table.sort(order, function(a, b)
    return rects[a].w * rects[a].h > rects[b].w * rects[b].h
  end)

  -- Auto-grow: estimate a starting size
  if auto_grow then
    --: number
    local total_area = 0
    for i = 1, #rects do
      total_area = total_area + rects[i].w * rects[i].h
    end
    local side = math.max(64, math.ceil(math.sqrt(total_area * 1.1)))
    bin_w = side
    bin_h = side
  end

  -- Free rectangles list: each is {x, y, w, h}
  --: { [integer]: FreeRect }
  local free = { { x = 0, y = 0, w = bin_w, h = bin_h } }

  --: { [integer]: PlacedRect }
  local placed = {}
  --: { [integer]: Rect }
  local unplaced = {}
  --: number
  local used_w = 0
  --: number
  local used_h = 0

  for _, ri in ipairs(order) do
    local rect = rects[ri]
    local rw = rect.w --: number
    local rh = rect.h --: number
    local id = rect.id ~= nil and rect.id or ri

    -- Find best free rect (smallest area that fits)
    --: integer | nil
    local best_idx = nil
    --: number
    local best_area = math.huge
    local best_rotated = false

    for fi = 1, #free do
      local f = free[fi]
      -- Normal orientation
      if f.w >= rw and f.h >= rh then
        local area = f.w * f.h --: number
        if area < best_area then
          best_area = area
          best_idx = fi
          best_rotated = false
        end
      end
      -- Rotated orientation
      if allow_rotate and f.w >= rh and f.h >= rw then
        local area = f.w * f.h --: number
        if area < best_area then
          best_area = area
          best_idx = fi
          best_rotated = true
        end
      end
    end

    if not best_idx then
      -- Item doesn't fit anywhere; try auto-grow once more
      if auto_grow then
        -- Grow bin and add new free space
        local new_right = { x = bin_w, y = 0, w = math.max(rw, rh), h = bin_h }
        local new_bottom = { x = 0, y = bin_h, w = bin_w + math.max(rw, rh), h = math.max(rh, rw) }
        bin_w = bin_w + math.max(rw, rh)
        bin_h = bin_h + math.max(rh, rw)
        free[#free + 1] = new_right
        free[#free + 1] = new_bottom
        -- Retry finding
        best_idx = nil
        best_area = math.huge --: number
        for fi = 1, #free do
          local f = free[fi]
          if f.w >= rw and f.h >= rh then
            local area = f.w * f.h --: number
            if area < best_area then
              best_area = area
              best_idx = fi
              best_rotated = false
            end
          end
          if allow_rotate and f.w >= rh and f.h >= rw then
            local area = f.w * f.h --: number
            if area < best_area then
              best_area = area
              best_idx = fi
              best_rotated = true
            end
          end
        end
      end
      if not best_idx then
        unplaced[#unplaced + 1] = rect
        goto continue
      end
    end

    do
      local f = free[best_idx]
      local pw, ph = rw, rh
      if best_rotated then pw, ph = rh, rw end

      placed[#placed + 1] = { id = id, x = f.x, y = f.y, w = pw, h = ph, rotated = best_rotated }
      if f.x + pw > used_w then used_w = f.x + pw end
      if f.y + ph > used_h then used_h = f.y + ph end

      -- Split remaining space
      local left_w = f.w - pw
      local bot_h = f.h - ph

      -- Determine split axis
      local split_horiz
      if split_mode == "short_axis" then
        split_horiz = left_w < bot_h
      else -- long_axis
        split_horiz = left_w > bot_h
      end

      -- Remove used free rect
      free[best_idx] = free[#free]
      free[#free] = nil

      if split_horiz then
        -- Top strip (full width of original free rect)
        if bot_h > 0 then
          free[#free + 1] = { x = f.x, y = f.y + ph, w = f.w, h = bot_h }
        end
        -- Right strip (only height of placed item)
        if left_w > 0 then
          free[#free + 1] = { x = f.x + pw, y = f.y, w = left_w, h = ph }
        end
      else
        -- Right strip (full height of original free rect)
        if left_w > 0 then
          free[#free + 1] = { x = f.x + pw, y = f.y, w = left_w, h = f.h }
        end
        -- Top strip (only width of placed item)
        if bot_h > 0 then
          free[#free + 1] = { x = f.x, y = f.y + ph, w = pw, h = bot_h }
        end
      end
    end

    ::continue::
  end

  return { placed = placed, unplaced = unplaced, w = used_w, h = used_h }
end

-- Shelf (row-based) algorithm.
-- Packs items row by row, sorted by height descending.
-- Returns: {placed=[{id,x,y,w,h,rotated}], unplaced=[...], w=used_w, h=used_h}
--: ({ [integer]: Rect }, number, number, { allow_rotate: boolean | nil } | nil) -> ({ placed: { [integer]: PlacedRect }, unplaced: { [integer]: Rect }, w: number, h: number } | nil, string | nil)
function M.shelf(rects, bin_w, bin_h, opts)
  opts = (opts or {}) --[[:! { allow_rotate: boolean | nil }]]
  local allow_rotate = opts.allow_rotate or false

  if bin_w <= 0 then return nil, "bin_w must be > 0" end
  if bin_h <= 0 then return nil, "bin_h must be > 0" end

  -- Sort by height descending
  local order = {}
  for i = 1, #rects do order[i] = i end
  table.sort(order, function(a, b)
    --: number
    local ha = rects[a].h
    --: number
    local hb = rects[b].h
    if allow_rotate then
      ha = math.max(rects[a].w, rects[a].h)
      hb = math.max(rects[b].w, rects[b].h)
    end
    return ha > hb
  end)

  --: { [integer]: PlacedRect }
  local placed = {}
  --: { [integer]: Rect }
  local unplaced = {}
  --: number
  local shelf_x = 0
  --: number
  local shelf_y = 0
  --: number
  local shelf_h = 0
  --: number
  local used_w = 0
  --: number
  local used_h = 0

  for _, ri in ipairs(order) do
    local rect = rects[ri]
    local rw = rect.w --: number
    local rh = rect.h --: number
    local id = rect.id ~= nil and rect.id or ri
    local rotated = false

    -- Try rotation if allowed and it helps fit
    if allow_rotate and rh > rw then
      rw, rh = rh, rw
      rotated = true
    end

    -- Check if item fits in the bin at all
    if rw > bin_w or rh > bin_h then
      -- Try unrotated
      if allow_rotate and rect.h <= bin_w and rect.w <= bin_h then
        rw, rh = rect.h, rect.w
        rotated = true
      elseif rect.w <= bin_w and rect.h <= bin_h then
        rw, rh = rect.w, rect.h
        rotated = false
      else
        unplaced[#unplaced + 1] = rect
        goto continue_shelf
      end
    end

    -- Try to place on current shelf
    if shelf_h == 0 then
      -- First item: open first shelf
      shelf_h = rh
    end

    if shelf_x + rw > bin_w then
      -- Doesn't fit on current shelf, open new one
      shelf_y = shelf_y + shelf_h
      shelf_x = 0
      shelf_h = rh
    end

    if shelf_y + rh > bin_h then
      -- Doesn't fit vertically
      unplaced[#unplaced + 1] = rect
      goto continue_shelf
    end

    placed[#placed + 1] = { id = id, x = shelf_x, y = shelf_y, w = rw, h = rh, rotated = rotated }
    if shelf_x + rw > used_w then used_w = shelf_x + rw end
    if shelf_y + rh > used_h then used_h = shelf_y + rh end
    shelf_x = shelf_x + rw

    ::continue_shelf::
  end

  return { placed = placed, unplaced = unplaced, w = used_w, h = used_h }
end

-- MaxRects algorithm.
-- Uses maximal rectangle free space tracking for high-quality packing.
-- opts: { allow_rotate=false, heuristic="best_short_side"|"best_long_side"|"best_area" }
--: ({ [integer]: Rect }, number, number, { allow_rotate: boolean | nil, heuristic: string | nil } | nil) -> ({ placed: { [integer]: PlacedRect }, unplaced: { [integer]: Rect }, w: number, h: number } | nil, string | nil)
function M.maxrects(rects, bin_w, bin_h, opts)
  opts = (opts or {}) --[[:! { allow_rotate: boolean | nil, heuristic: string | nil }]]
  local allow_rotate = opts.allow_rotate or false
  local heuristic = opts.heuristic or "best_short_side"

  if bin_w <= 0 then return nil, "bin_w must be > 0" end
  if bin_h <= 0 then return nil, "bin_h must be > 0" end

  -- Sort by area descending
  local order = {}
  for i = 1, #rects do order[i] = i end
  table.sort(order, function(a, b)
    return rects[a].w * rects[a].h > rects[b].w * rects[b].h
  end)

  -- Free rectangles list
  --: { [integer]: FreeRect }
  local free = { { x = 0, y = 0, w = bin_w, h = bin_h } }

  --: { [integer]: PlacedRect }
  local placed = {}
  --: { [integer]: Rect }
  local unplaced = {}
  --: number
  local used_w = 0
  --: number
  local used_h = 0

  -- Score a placement (lower = better)
  --: (number, number, number, number) -> number
  local function score(fw, fh, rw, rh)
    if heuristic == "best_area" then
      return fw * fh - rw * rh
    elseif heuristic == "best_long_side" then
      return math.max(fw - rw, fh - rh)
    else -- best_short_side
      return math.min(fw - rw, fh - rh)
    end
  end

  for _, ri in ipairs(order) do
    local rect = rects[ri]
    local rw = rect.w --: number
    local rh = rect.h --: number
    local id = rect.id ~= nil and rect.id or ri

    --: integer | nil
    local best_fi = nil
    --: number
    local best_score = math.huge
    local best_rotated = false
    --: number
    local best_x = 0
    --: number
    local best_y = 0

    for fi = 1, #free do
      local f = free[fi]
      if f.w >= rw and f.h >= rh then
        local s = score(f.w, f.h, rw, rh)
        if s < best_score then
          best_score = s
          best_fi = fi
          best_rotated = false
          best_x = f.x
          best_y = f.y
        end
      end
      if allow_rotate and rw ~= rh and f.w >= rh and f.h >= rw then
        local s = score(f.w, f.h, rh, rw)
        if s < best_score then
          best_score = s
          best_fi = fi
          best_rotated = true
          best_x = f.x
          best_y = f.y
        end
      end
    end

    if not best_fi then
      unplaced[#unplaced + 1] = rect
      goto continue_mr
    end

    do
      local pw, ph = rw, rh
      if best_rotated then pw, ph = rh, rw end

      placed[#placed + 1] = { id = id, x = best_x, y = best_y, w = pw, h = ph, rotated = best_rotated }
      if best_x + pw > used_w then used_w = best_x + pw end
      if best_y + ph > used_h then used_h = best_y + ph end

      -- Split all free rects that overlap with the placed rect
      --: { [integer]: FreeRect }
      local new_free = {}
      for fi = 1, #free do
        local f = free[fi]
        if rects_overlap(f.x, f.y, f.w, f.h, best_x, best_y, pw, ph) then
          -- Generate up to 4 sub-rects from the split
          -- Left
          if best_x > f.x then
            new_free[#new_free + 1] = { x = f.x, y = f.y, w = best_x - f.x, h = f.h }
          end
          -- Right
          if best_x + pw < f.x + f.w then
            new_free[#new_free + 1] = { x = best_x + pw, y = f.y, w = (f.x + f.w) - (best_x + pw), h = f.h }
          end
          -- Top (above placed rect)
          if best_y > f.y then
            new_free[#new_free + 1] = { x = f.x, y = f.y, w = f.w, h = best_y - f.y }
          end
          -- Bottom (below placed rect)
          if best_y + ph < f.y + f.h then
            new_free[#new_free + 1] = { x = f.x, y = best_y + ph, w = f.w, h = (f.y + f.h) - (best_y + ph) }
          end
        else
          new_free[#new_free + 1] = f
        end
      end

      -- Prune: remove free rects fully contained by another
      --: { [integer]: FreeRect }
      local pruned = {}
      for i = 1, #new_free do
        local r = new_free[i]
        local dominated = false
        for j = 1, #new_free do
          if i ~= j then
            local s = new_free[j]
            if rect_contains(s.x, s.y, s.w, s.h, r.x, r.y, r.w, r.h) and
               not (r.x == s.x and r.y == s.y and r.w == s.w and r.h == s.h) then
              dominated = true
              break
            end
          end
        end
        if not dominated then
          pruned[#pruned + 1] = r
        end
      end
      free = pruned
    end

    ::continue_mr::
  end

  return { placed = placed, unplaced = unplaced, w = used_w, h = used_h }
end

-- Auto-size: find minimal power-of-2 square bin that fits all rects.
-- Tries 64, 128, 256, 512, 1024, 2048, 4096.
function M.auto_pack(rects, opts)
  opts = opts or {}
  local sizes = { 64, 128, 256, 512, 1024, 2048, 4096 }
  for _, s in ipairs(sizes) do
    local result = M.maxrects(rects, s, s, opts)
    if result and #result.unplaced == 0 then
      return result
    end
  end
  -- Fallback: use maxrects with 4096x4096 and accept whatever fits
  return M.maxrects(rects, 4096, 4096, opts)
end

-- Efficiency: placed area / (result.w * result.h). Returns 0 for degenerate cases.
--: ({ placed: { [integer]: PlacedRect }, w: number, h: number } | nil) -> number
function M.pack_efficiency(result)
  if not result then return 0 end
  local placed = result.placed --[[:! { [integer]: PlacedRect }]]
  local rw = result.w --: number
  local rh = result.h --: number
  if not placed or #placed == 0 then return 0 end
  if rw == 0 or rh == 0 then return 0 end
  --: number
  local total = 0
  for _, p in ipairs(placed) do
    total = total + p.w * p.h
  end
  return total / (rw * rh)
end

return M
