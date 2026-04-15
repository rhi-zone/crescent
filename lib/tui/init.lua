if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- TUI widget layer for terminal applications.
-- Builds on lib/ansi. Pure rendering: widgets produce strings, no mutable state.
-- Widgets are tables: { render(ctx) -> string }
-- ctx: { x, y, w, h } (1-indexed position and dimensions)

local ansi = require("lib.ansi")

local M = {}

-- ---------------------------------------------------------------------------
-- Terminal size
-- ---------------------------------------------------------------------------

-- Try FFI TIOCGWINSZ, then env vars, then default 80x24.
--: ((string) -> string | nil) -> (integer, integer)
M.size = function(getenv)
  if type(getenv) ~= "function" then
    error("tui.size: getenv function is required")
  end
  local ffi_ok, ffi = pcall(require, "ffi")
  if ffi_ok then
    local ok, w, h = pcall(function()
      ffi.cdef [[
        struct winsize_tui { uint16_t ws_row; uint16_t ws_col; uint16_t ws_xpixel; uint16_t ws_ypixel; };
        int ioctl(int fd, unsigned long request, ...);
      ]]
      local ws = ffi.new("struct winsize_tui")
      -- TIOCGWINSZ: Linux=0x5413, macOS=0x40087468
      --: any
      local TIOCGWINSZ = ffi.os == "OSX" and 0x40087468 or 0x5413
      local ret = ffi.C.ioctl(1, TIOCGWINSZ, ws)
      if ret == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return ws.ws_col, ws.ws_row
      end
      return nil, nil
    end)
    if ok and w and h then return w, h end
  end
  -- Fallback: environment variables
  local cols_s  = getenv("COLUMNS")
  local lines_s = getenv("LINES")
  if cols_s ~= nil and lines_s ~= nil then
    local cols  = tonumber(cols_s)
    local lines = tonumber(lines_s)
    if cols ~= nil and lines ~= nil then
      if cols > 0 and lines > 0 then
        return math.floor(cols), math.floor(lines)
      end
    end
  end
  -- Default
  return 80, 24
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Clamp n to [lo, hi].
--: (integer, integer, integer) -> integer
local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

-- Truncate a string to at most max_len bytes.
--: (string, integer) -> string
local function trunc(s, max_len)
  if #s <= max_len then return s end
  return s:sub(1, max_len)
end

-- Pad string to exactly width characters (left-aligned).
--: (string, integer) -> string
local function pad_right(s, width)
  local len = #s
  if len >= width then return s:sub(1, width) end
  return s .. string.rep(" ", width - len)
end

-- Center-pad string in a field of `width` characters.
--: (string, integer) -> string
local function pad_center(s, width)
  local len = #s
  if len >= width then return s:sub(1, width) end
  local total_pad = width - len
  local left_pad = math.floor(total_pad / 2)
  local right_pad = total_pad - left_pad
  return string.rep(" ", left_pad) .. s .. string.rep(" ", right_pad)
end

-- Right-align string in a field of `width` characters.
--: (string, integer) -> string
local function pad_left(s, width)
  local len = #s
  if len >= width then return s:sub(1, width) end
  return string.rep(" ", width - len) .. s
end

-- ---------------------------------------------------------------------------
-- Border definitions
-- ---------------------------------------------------------------------------

--:: BorderDef = { tl: string, tr: string, bl: string, br: string, h: string, v: string }

--: any
local BORDERS = {
  single  = { tl="┌", tr="┐", bl="└", br="┘", h="─", v="│" },
  double  = { tl="╔", tr="╗", bl="╚", br="╝", h="═", v="║" },
  rounded = { tl="╭", tr="╮", bl="╰", br="╯", h="─", v="│" },
  none    = { tl=" ", tr=" ", bl=" ", br=" ", h=" ", v=" " },
}

-- ---------------------------------------------------------------------------
-- Render context extraction
-- ---------------------------------------------------------------------------

-- Widgets may be called with dot syntax (ctx) or colon syntax (self, ctx).
-- This helper normalises both call forms and returns x, y, w, h.
--: (any, any) -> (integer, integer, integer, integer)
local function unpack_ctx(a, b)
  --: any
  local ctx = (b ~= nil) and b or a
  return ctx.x, ctx.y, ctx.w, ctx.h
end

-- ---------------------------------------------------------------------------
-- tui.text
-- ---------------------------------------------------------------------------

-- Text widget. Renders text at the widget position.
-- opts.align = "left"|"center"|"right"  (default "left")
-- opts.wrap  = bool                     (default false)
--: (string, any) -> any
M.text = function(s, opts)
  local align = "left"
  local wrap  = false
  if opts ~= nil then
    if opts.align ~= nil then align = opts.align end
    if opts.wrap  ~= nil then wrap  = opts.wrap  end
  end

  return {
    render = function(a, b)
      local x, y, w, h = unpack_ctx(a, b)
      if w <= 0 or h <= 0 then return "" end

      local lines = {}

      if wrap then
        -- Word-wrap into lines of width w
        local remaining = s
        while #remaining > 0 and #lines < h do
          local line = remaining:sub(1, w)
          if #remaining > w then
            local break_at = line:match(".*()%s")
            if break_at and break_at > 1 then
              line = remaining:sub(1, break_at - 1)
              remaining = remaining:sub(break_at + 1)
            else
              remaining = remaining:sub(w + 1)
            end
          else
            remaining = ""
          end
          lines[#lines + 1] = line
        end
      else
        -- Split on newlines
        for ln in (s .. "\n"):gmatch("([^\n]*)\n") do
          --: string
          local safe_ln = ln or ""
          lines[#lines + 1] = safe_ln
          if #lines >= h then break end
        end
      end

      local parts = {}
      for i = 1, clamp(#lines, 0, h) do
        local line = lines[i]
        local formatted
        if align == "center" then
          formatted = pad_center(trunc(line, w), w)
        elseif align == "right" then
          formatted = pad_left(trunc(line, w), w)
        else
          formatted = pad_right(trunc(line, w), w)
        end
        parts[#parts + 1] = ansi.move_to(y + i - 1, x) .. formatted
      end
      return table.concat(parts)
    end
  }
end

-- ---------------------------------------------------------------------------
-- tui.box
-- ---------------------------------------------------------------------------

-- Box widget: border + optional title + padding + inner widget.
-- opts.border  = "single"|"double"|"rounded"|"none"  (default "single")
-- opts.title   = string (shown in top border, left-aligned)
-- opts.padding = {top, right, bottom, left}          (default all 0)
--: (any, any) -> any
M.box = function(inner, opts)
  local border_name = "single"
  local title       = nil --: string | nil
  local pad_t, pad_r, pad_b, pad_l = 0, 0, 0, 0
  if opts ~= nil then
    if opts.border  ~= nil then border_name = opts.border  end
    if opts.title   ~= nil then title       = opts.title   end
    if opts.padding ~= nil then
      local p = opts.padding
      pad_t = p[1]; pad_r = p[2]; pad_b = p[3]; pad_l = p[4]
    end
  end

  return {
    render = function(a, b)
      local x, y, w, h = unpack_ctx(a, b)
      if w <= 0 or h <= 0 then return "" end

      --: BorderDef
      local bdef = BORDERS[border_name] or BORDERS.single
      local parts = {}

      -- Top border
      if h >= 1 then
        local inner_w = clamp(w - 2, 0, w)
        local top_fill
        if title ~= nil and #title > 0 then
          local label = " " .. title .. " "
          if #label > inner_w then label = label:sub(1, inner_w) end
          local remainder = inner_w - #label
          top_fill = label .. string.rep(bdef.h, remainder)
        else
          top_fill = string.rep(bdef.h, inner_w)
        end
        parts[#parts + 1] = ansi.move_to(y, x) .. bdef.tl .. top_fill .. bdef.tr
      end

      -- Side borders and interior rows
      local content_y_end = y + h - 2
      for row = y + 1, content_y_end do
        local inner_w = clamp(w - 2, 0, w)
        parts[#parts + 1] = ansi.move_to(row, x) .. bdef.v .. string.rep(" ", inner_w) .. bdef.v
      end

      -- Bottom border
      if h >= 2 then
        local inner_w = clamp(w - 2, 0, w)
        parts[#parts + 1] = ansi.move_to(y + h - 1, x)
          .. bdef.bl .. string.rep(bdef.h, inner_w) .. bdef.br
      end

      -- Inner widget render area (inside border + padding)
      local inner_x = x + 1 + pad_l
      local inner_y = y + 1 + pad_t
      local inner_w = clamp(w - 2 - pad_l - pad_r, 0, w)
      local inner_h = clamp(h - 2 - pad_t - pad_b, 0, h)

      if inner_w > 0 and inner_h > 0 and inner ~= nil and inner.render ~= nil then
        parts[#parts + 1] = inner:render({
          x = inner_x, y = inner_y, w = inner_w, h = inner_h,
        })
      end

      return table.concat(parts)
    end
  }
end

-- ---------------------------------------------------------------------------
-- tui.row
-- ---------------------------------------------------------------------------

-- Horizontal layout: divides width among children.
-- opts.flex = {1, 2, 1}  (proportional sizing; default equal)
--: (any, any) -> any
M.row = function(widgets, opts)
  local flex = nil --: any
  if opts ~= nil and opts.flex ~= nil then flex = opts.flex end

  return {
    render = function(a, b)
      local x, y, w, h = unpack_ctx(a, b)
      if w <= 0 or h <= 0 or #widgets == 0 then return "" end

      local total_flex = 0
      for i = 1, #widgets do
        total_flex = total_flex + ((flex ~= nil and flex[i] ~= nil) and flex[i] or 1)
      end

      local widths = {}
      local used = 0
      for i = 1, #widgets do
        local f = (flex ~= nil and flex[i] ~= nil) and flex[i] or 1
        local cell_w
        if i == #widgets then
          cell_w = w - used
        else
          cell_w = math.floor(w * f / total_flex)
        end
        widths[i] = clamp(cell_w, 0, w - used)
        used = used + widths[i]
      end

      local parts = {}
      local cur_x = x
      for i = 1, #widgets do
        local cw = widths[i]
        if cw > 0 then
          local wi = widgets[i]
          if wi ~= nil and wi.render ~= nil then
            parts[#parts + 1] = wi:render({
              x = cur_x, y = y, w = cw, h = h,
            })
          end
        end
        cur_x = cur_x + cw
      end
      return table.concat(parts)
    end
  }
end

-- ---------------------------------------------------------------------------
-- tui.col
-- ---------------------------------------------------------------------------

-- Vertical layout: divides height among children.
-- opts.flex = {1, 2, 1}  (proportional sizing; default equal)
--: (any, any) -> any
M.col = function(widgets, opts)
  local flex = nil --: any
  if opts ~= nil and opts.flex ~= nil then flex = opts.flex end

  return {
    render = function(a, b)
      local x, y, w, h = unpack_ctx(a, b)
      if w <= 0 or h <= 0 or #widgets == 0 then return "" end

      local total_flex = 0
      for i = 1, #widgets do
        total_flex = total_flex + ((flex ~= nil and flex[i] ~= nil) and flex[i] or 1)
      end

      local heights = {}
      local used = 0
      for i = 1, #widgets do
        local f = (flex ~= nil and flex[i] ~= nil) and flex[i] or 1
        local cell_h
        if i == #widgets then
          cell_h = h - used
        else
          cell_h = math.floor(h * f / total_flex)
        end
        heights[i] = clamp(cell_h, 0, h - used)
        used = used + heights[i]
      end

      local parts = {}
      local cur_y = y
      for i = 1, #widgets do
        local ch = heights[i]
        if ch > 0 then
          local wi = widgets[i]
          if wi ~= nil and wi.render ~= nil then
            parts[#parts + 1] = wi:render({
              x = x, y = cur_y, w = w, h = ch,
            })
          end
        end
        cur_y = cur_y + ch
      end
      return table.concat(parts)
    end
  }
end

-- ---------------------------------------------------------------------------
-- tui.styled
-- ---------------------------------------------------------------------------

-- Wrap a widget's render output in a style function.
-- style_fn: a function (string) -> string, e.g. ansi.bold, ansi.red
--: (any, any) -> any
M.styled = function(widget, style_fn)
  return {
    render = function(a, b)
      if widget == nil or widget.render == nil then return "" end
      -- Normalize ctx first, then pass as a plain table to avoid extra self arg
      local x, y, w, h = unpack_ctx(a, b)
      local ctx = { x = x, y = y, w = w, h = h }
      local out = widget.render(ctx)
      return style_fn(out)
    end
  }
end

-- ---------------------------------------------------------------------------
-- tui.render
-- ---------------------------------------------------------------------------

-- Render a widget tree to a string using absolute-position ANSI output.
-- x, y: top-left corner (1-indexed)
-- w, h: available width/height
--: (any, integer, integer, integer, integer) -> string
M.render = function(widget, x, y, w, h)
  if widget == nil or widget.render == nil then return "" end
  return widget:render({ x = x, y = y, w = w, h = h })
end

-- ---------------------------------------------------------------------------
-- tui.render_full
-- ---------------------------------------------------------------------------

-- Full-screen render: clears screen, renders widget to terminal size.
--: ((string) -> nil, () -> nil, (string) -> string | nil, any) -> ()
M.render_full = function(write_fn, flush_fn, getenv, widget)
  if type(write_fn) ~= "function" then error("tui.render_full: write_fn is required") end
  if type(flush_fn) ~= "function" then error("tui.render_full: flush_fn is required") end
  if type(getenv) ~= "function" then error("tui.render_full: getenv is required") end
  local w, h = M.size(getenv)
  write_fn(ansi.clear() .. M.render(widget, 1, 1, w, h))
  flush_fn()
end

return M
