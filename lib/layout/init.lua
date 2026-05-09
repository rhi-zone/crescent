if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local math_max   = math.max
local math_min   = math.min
local math_floor = math.floor

-- ---------------------------------------------------------------------------
-- Node constructors
-- ---------------------------------------------------------------------------

-- box(opts) -> node
-- opts: {id?, width?, height?, flex?, direction?, padding?, gap?, children?,
--        align_items?, justify_content?, position?, x?, y?,
--        aspect_ratio?, min_width?, max_width?, min_height?, max_height?}
function M.box(opts)
  local node = {
    _type          = "box",
    id             = opts.id,
    width          = opts.width,
    height         = opts.height,
    flex           = opts.flex,
    direction      = opts.direction or "row",
    padding        = opts.padding or 0,
    gap            = opts.gap or 0,
    children       = opts.children or {},
    align_items    = opts.align_items or "stretch",
    justify_content = opts.justify_content or "start",
    position       = opts.position or "relative",
    x              = opts.x,
    y              = opts.y,
    aspect_ratio   = opts.aspect_ratio,
    min_width      = opts.min_width,
    max_width      = opts.max_width,
    min_height     = opts.min_height,
    max_height     = opts.max_height,
  }
  return node
end

-- grid(opts) -> node
-- opts: {id?, columns, rows, gap?, children?}
-- columns/rows: array of numbers (fixed px) or "Nfr" strings (fractional)
function M.grid(opts)
  local node = {
    _type    = "grid",
    id       = opts.id,
    width    = opts.width,
    height   = opts.height,
    columns  = opts.columns,
    rows     = opts.rows,
    gap      = opts.gap or 0,
    children = opts.children or {},
  }
  return node
end

-- cell(opts) -> node
-- opts: {id?, col, row, col_span?, row_span?, children?}
function M.cell(opts)
  local node = {
    _type    = "cell",
    id       = opts.id,
    col      = opts.col,
    row      = opts.row,
    col_span = opts.col_span or 1,
    row_span = opts.row_span or 1,
    children = opts.children or {},
  }
  return node
end

-- ---------------------------------------------------------------------------
-- Result object
-- ---------------------------------------------------------------------------

local Result = {}
Result.__index = Result

function Result:get(id)
  return self._map[id]
end

function Result:all()
  local out = {}
  for id, r in pairs(self._map) do
    out[#out + 1] = { id = id, x = r.x, y = r.y, width = r.width, height = r.height }
  end
  return out
end

local function make_result()
  return setmetatable({ _map = {} }, Result)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--: (v: number, lo: number | nil, hi: number | nil) -> number
local function clamp(v, lo, hi)
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

--:: LayoutNode = { _type: string, id: string | nil, width: number | string | nil, height: number | string | nil, flex: number | nil, direction: string, padding: number, gap: number, children: LayoutNode[], align_items: string, justify_content: string, position: string, x: number | nil, y: number | nil, aspect_ratio: number | nil, min_width: number | nil, max_width: number | nil, min_height: number | nil, max_height: number | nil, col: integer | nil, row: integer | nil, col_span: integer | nil, row_span: integer | nil, columns: { [integer]: unknown }, rows: { [integer]: unknown }, ... }

-- Apply min/max constraints to a dimension.
--: (node: LayoutNode, w: number) -> number
local function constrain_w(node, w)
  return clamp(w, node.min_width, node.max_width)
end

--: (node: LayoutNode, h: number) -> number
local function constrain_h(node, h)
  return clamp(h, node.min_height, node.max_height)
end

-- Parse a track definition (number or "Nfr") into {fixed, fr}.
local function parse_track(t)
  if type(t) == "number" then
    return { fixed = t, fr = 0 }
  elseif type(t) == "string" then
    local n = tonumber(t:match("^(%d+%.?%d*)fr$"))
    if n then return { fixed = 0, fr = n } end
  end
  error("invalid track definition: " .. tostring(t))
end

-- ---------------------------------------------------------------------------
-- Layout computation
-- ---------------------------------------------------------------------------

-- Resolve track sizes (columns or rows) given total available space and gap.
--: (tracks: { [integer]: unknown }, available: number, gap: number) -> { [integer]: number }
local function resolve_tracks(tracks, available, gap)
  local n = #tracks
  local total_gap = gap * (n > 1 and n - 1 or 0)
  local remaining = available - total_gap
  local total_fr = 0
  local parsed = {}
  for i = 1, n do
    parsed[i] = parse_track(tracks[i])
    remaining = remaining - parsed[i].fixed
    total_fr  = total_fr + parsed[i].fr
  end
  local sizes = {}
  for i = 1, n do
    local p = parsed[i]
    if p.fr > 0 and total_fr > 0 then
      sizes[i] = (p.fr / total_fr) * remaining
    else
      sizes[i] = p.fixed
    end
  end
  return sizes
end

-- Compute offsets (start positions) from sizes + gap.
local function track_offsets(sizes, gap)
  local offsets = {}
  local pos = 0
  for i = 1, #sizes do
    offsets[i] = pos
    pos = pos + sizes[i] + gap
  end
  return offsets
end

-- Forward declaration for recursion.
local compute_node

-- compute_box: layout a box node at (px, py) with given (bw, bh).
-- Returns computed (w, h) after constraints / aspect-ratio.
--: (node: LayoutNode, px: number, py: number, bw: number, bh: number, result: { _map: { [string]: { x: number, y: number, width: number, height: number } } }) -> (number, number)
local function compute_box(node, px, py, bw, bh, result)
  -- Resolve actual width / height.
  local w = 0.0 --: number
  local h = 0.0 --: number

  -- Width resolution.
  if type(node.width) == "number" then
    w = node.width --[[:! number]]
  elseif node.width == "fill" then
    w = bw
  elseif node.flex then
    -- flex nodes get their size injected by parent; bw is the allocated size.
    w = bw
  else
    w = bw
  end

  -- Height resolution.
  if type(node.height) == "number" then
    h = node.height --[[:! number]]
  elseif node.height == "fill" then
    h = bh
  elseif node.flex then
    h = bh
  else
    h = bh
  end

  -- Aspect ratio: if one dim is explicit and the other isn't, derive it.
  if node.aspect_ratio then
    local ar = node.aspect_ratio
    if type(node.width) == "number" and type(node.height) ~= "number" and node.height ~= "fill" then
      h = w / ar
    elseif type(node.height) == "number" and type(node.width) ~= "number" and node.width ~= "fill" then
      w = h * ar
    end
  end

  -- Apply min/max.
  local wn = constrain_w(node, w --[[:! number]])
  local hn = constrain_h(node, h --[[:! number]])
  w = wn
  h = hn

  -- Record this node.
  if node.id then
    result._map[node.id] = { x = px, y = py, width = w, height = h }
  end

  -- Layout children.
  if #node.children > 0 then
    local pad  = node.padding or 0
    local gap  = node.gap or 0
    local dir  = node.direction or "row"
    local inner_w = w - 2 * pad
    local inner_h = h - 2 * pad
    local align    = node.align_items or "stretch"
    local justify  = node.justify_content or "start"

    -- Separate absolute children from flow children.
    local flow_children = {} --: { [integer]: LayoutNode }
    local abs_children  = {} --: { [integer]: LayoutNode }
    for i = 1, #node.children do
      local c = node.children[i]
      if c.position == "absolute" then
        abs_children[#abs_children + 1] = c
      else
        flow_children[#flow_children + 1] = c
      end
    end

    -- ------------------------------------------------------------------
    -- Pass 1: measure fixed / fill dimensions of flow children.
    -- ------------------------------------------------------------------
    local total_flex = 0.0 --: number
    -- sum of fixed sizes + gaps
    local main_used  = 0.0 --: number
    local n_flow     = #flow_children

    -- Per-child resolved main/cross sizes (before flex allocation).
    local child_main  = {} --: { [integer]: number | nil }
    local child_cross = {} --: { [integer]: number | nil }

    for i = 1, n_flow do
      local c = flow_children[i]
      local cm, cc  -- main, cross sizes

      if dir == "row" then
        -- main = width, cross = height
        if c.flex then
          cm = nil  -- deferred
          total_flex = total_flex + c.flex
        elseif type(c.width) == "number" then
          cm = c.width --[[:! number]]
        elseif c.width == "fill" then
          cm = inner_w
        else
          cm = 0
        end

        if type(c.height) == "number" then
          cc = c.height --[[:! number]]
        elseif c.height == "fill" then
          cc = inner_h
        elseif align == "stretch" then
          cc = inner_h
        else
          cc = 0
        end
        -- aspect ratio for cross
        if c.aspect_ratio and cm then
          cc = (cm --[[:! number]]) / (c.aspect_ratio --[[:! number]])
        end
      else -- "col"
        -- main = height, cross = width
        if c.flex then
          cm = nil
          total_flex = total_flex + c.flex
        elseif type(c.height) == "number" then
          cm = c.height --[[:! number]]
        elseif c.height == "fill" then
          cm = inner_h
        else
          cm = 0
        end

        if type(c.width) == "number" then
          cc = c.width --[[:! number]]
        elseif c.width == "fill" then
          cc = inner_w
        elseif align == "stretch" then
          cc = inner_w
        else
          cc = 0
        end
        -- aspect ratio for cross
        if c.aspect_ratio and cm then
          cc = (cm --[[:! number]]) * (c.aspect_ratio --[[:! number]])
        end
      end

      if cm then
        local cmn = cm --[[:! number]]
        cm = (dir == "row") and constrain_w(c, cmn) or constrain_h(c, cmn)
        main_used = main_used + (cm --[[:! number]])
      end
      child_main[i]  = cm
      child_cross[i] = cc
    end

    -- gaps between flow children
    main_used = main_used + gap * (n_flow > 1 and n_flow - 1 or 0)

    -- ------------------------------------------------------------------
    -- Pass 2: allocate flex space.
    -- ------------------------------------------------------------------
    local avail_main = (dir == "row") and inner_w or inner_h
    local flex_space = avail_main - main_used

    for i = 1, n_flow do
      local c = flow_children[i]
      if c.flex and total_flex > 0 then
        local allocated = (c.flex / total_flex) * math_max(0, flex_space)
        if dir == "row" then
          allocated = constrain_w(c, allocated)
          -- cross = height
          if type(c.height) == "number" then
            child_cross[i] = c.height --[[:! number]]
          elseif c.height == "fill" then
            child_cross[i] = inner_h
          elseif align == "stretch" then
            child_cross[i] = inner_h
          else
            child_cross[i] = 0
          end
          if c.aspect_ratio then child_cross[i] = allocated / (c.aspect_ratio --[[:! number]]) end
        else
          local allocated_h = constrain_h(c, allocated)
          -- cross = width
          if type(c.width) == "number" then
            child_cross[i] = c.width --[[:! number]]
          elseif c.width == "fill" then
            child_cross[i] = inner_w
          elseif align == "stretch" then
            child_cross[i] = inner_w
          else
            child_cross[i] = 0
          end
          if c.aspect_ratio then
            child_cross[i] = allocated_h * (c.aspect_ratio --[[:! number]])
          end
          allocated = allocated_h
        end
        child_main[i] = allocated
      end
    end

    -- ------------------------------------------------------------------
    -- Pass 3: justify_content — compute starting offset and spacing.
    -- ------------------------------------------------------------------
    local actual_main_total = 0.0 --: number
    for i = 1, n_flow do actual_main_total = actual_main_total + (child_main[i] or 0) end
    actual_main_total = actual_main_total + gap * (n_flow > 1 and n_flow - 1 or 0)

    local main_start = 0.0 --: number
    local extra_gap  = 0.0 --: number

    if justify == "start" then
      main_start = 0
    elseif justify == "end" then
      main_start = avail_main - actual_main_total
    elseif justify == "center" then
      main_start = (avail_main - actual_main_total) / 2
    elseif justify == "space_between" then
      main_start = 0
      if n_flow > 1 then
        local fixed_sum = 0.0 --: number
        for i = 1, n_flow do fixed_sum = fixed_sum + (child_main[i] or 0) end
        extra_gap = (avail_main - fixed_sum) / (n_flow - 1)
      end
    elseif justify == "space_around" then
      if n_flow > 0 then
        local fixed_sum = 0.0 --: number
        for i = 1, n_flow do fixed_sum = fixed_sum + (child_main[i] or 0) end
        local space = (avail_main - fixed_sum) / n_flow
        main_start = space / 2
        extra_gap  = space
      end
    end

    -- ------------------------------------------------------------------
    -- Pass 4: place children.
    -- ------------------------------------------------------------------
    local avail_cross = (dir == "row") and inner_h or inner_w
    local cursor = main_start

    for i = 1, n_flow do
      local c   = flow_children[i]
      local cm  = child_main[i]  or 0
      local cc  = child_cross[i] or 0

      -- align_items on cross axis
      local cross_offset = 0.0 --: number
      if align == "center" then
        cross_offset = (avail_cross - cc) / 2
      elseif align == "end" then
        cross_offset = avail_cross - cc
      elseif align == "start" or align == "stretch" then
        cross_offset = 0.0
      end

      local cx = 0.0 --: number
      local cy = 0.0 --: number
      local cw = 0.0 --: number
      local ch = 0.0 --: number
      if dir == "row" then
        cx = px + pad + cursor
        cy = py + pad + cross_offset
        cw = cm
        ch = cc
      else
        cx = px + pad + cross_offset
        cy = py + pad + cursor
        cw = cc
        ch = cm
      end

      compute_node(c, cx, cy, cw, ch, result)

      local step_gap = (i < n_flow) and gap or 0.0 --: number
      if i < n_flow and extra_gap > 0 then step_gap = extra_gap end
      cursor = cursor + (cm --[[:! number]]) + step_gap
    end

    -- ------------------------------------------------------------------
    -- Absolute children: placed relative to this box's origin (px, py).
    -- ------------------------------------------------------------------
    for i = 1, #abs_children do
      local c = abs_children[i]
      local ax = px + (c.x or 0)
      local ay = py + (c.y or 0)
      local aw = type(c.width)  == "number" and c.width  or 0
      local ah = type(c.height) == "number" and c.height or 0
      compute_node(c, ax, ay, aw, ah, result)
    end
  end

  return w, h
end

-- compute_grid: layout a grid node at (px, py).
--: (node: LayoutNode, px: number, py: number, bw: number, bh: number, result: { _map: { [string]: { x: number, y: number, width: number, height: number } } }) -> (number, number)
local function compute_grid(node, px, py, bw, bh, result)
  local w = 0.0 --: number
  local h = 0.0 --: number
  if type(node.width) == "number" then w = node.width --[[:! number]] else w = bw end
  if type(node.height) == "number" then h = node.height --[[:! number]] else h = bh end
  local gap = node.gap or 0

  if node.id then
    result._map[node.id] = { x = px, y = py, width = w, height = h }
  end

  local col_sizes = resolve_tracks(node.columns, w, gap)
  local row_sizes = resolve_tracks(node.rows,    h, gap)
  local col_offs  = track_offsets(col_sizes, gap)
  local row_offs  = track_offsets(row_sizes, gap)

  for i = 1, #node.children do
    local cell = node.children[i]
    local ci   = cell.col
    local ri   = cell.row
    local cs   = cell.col_span or 1
    local rs   = cell.row_span or 1

    -- Cell x, y
    local cx = px + col_offs[ci]
    local cy = py + row_offs[ri]

    -- Cell width: sum of spanned column sizes + gaps between them.
    local cw = 0.0 --: number
    for k = ci, ci + cs - 1 do
      cw = cw + (col_sizes[k] or 0)
    end
    cw = cw + gap * (cs - 1)

    -- Cell height: sum of spanned row sizes + gaps.
    local ch = 0.0 --: number
    for k = ri, ri + rs - 1 do
      ch = ch + (row_sizes[k] or 0)
    end
    ch = ch + gap * (rs - 1)

    if cell.id then
      result._map[cell.id] = { x = cx, y = cy, width = cw, height = ch }
    end

    -- Layout children inside the cell.
    for j = 1, #cell.children do
      compute_node(cell.children[j], cx, cy, cw, ch, result)
    end
  end

  return w, h
end

-- compute_node: dispatch to box or grid layout.
--: (node: LayoutNode, px: number, py: number, bw: number, bh: number, result: { _map: { [string]: { x: number, y: number, width: number, height: number } } }) -> (number, number)
compute_node = function(node, px, py, bw, bh, result)
  if node._type == "grid" then
    return compute_grid(node, px, py, bw, bh, result)
  else
    return compute_box(node, px, py, bw, bh, result)
  end
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

-- compute(root) -> Result
-- Resolves all sizes and positions starting from the root node at (0, 0).
function M.compute(root)
  local result = make_result()
  -- Root: if no explicit size, derive from content (pass 0 as available space,
  -- the root will use its own width/height if set).
  local bw = 0.0 --: number
  local bh = 0.0 --: number
  if type(root.width)  == "number" then bw = root.width  --[[:! number]] end
  if type(root.height) == "number" then bh = root.height --[[:! number]] end
  compute_node(root, 0, 0, bw, bh, result)
  return result
end

return M
