-- lib/pagination/init.lua
-- Pagination utilities: offset-based, page-based, cursor-based, stateful paginator.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Paginator = { _items: { [integer]: unknown }, _per_page: integer, total_items: integer, total_pages: integer, current_page: integer, page: (self: Paginator, n: integer) -> unknown, ... }
--:: LazyPaginator = { _fetch_fn: (integer, integer) -> { [integer]: unknown }, _per_page: integer, total_items: integer, total_pages: integer, current_page: integer, page: (self: LazyPaginator, n: integer) -> unknown, ... }

local floor = math.floor
local byte, char, sub, rep = string.byte, string.char, string.sub, string.rep
local concat = table.concat

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Clamp n to [lo, hi].
--: (n: integer, lo: integer, hi: integer) -> integer
local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

-- ---------------------------------------------------------------------------
-- encode_cursor / decode_cursor
-- Encodes an arbitrary Lua string as a URL-safe base64-like opaque token.
-- Uses the standard RFC 4648 URL-safe alphabet (no padding needed for opaque use).
-- ---------------------------------------------------------------------------

local B64_ENC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64_DEC = {}
for i = 1, 64 do
  B64_DEC[byte(B64_ENC, i)] = i - 1
end

--- Encode a raw byte string to a URL-safe base64 string (no padding).
--: (data: string) -> string | (nil, string)
function M.encode_cursor(data)
  if type(data) ~= "string" then
    return nil, "encode_cursor: data must be a string"
  end
  local out = {}
  local n = #data
  local i = 1
  while i <= n do
    local b0 = byte(data, i) or 0
    local b1 = byte(data, i + 1) or 0
    local b2 = byte(data, i + 2) or 0
    local v = b0 * 65536 + b1 * 256 + b2
    out[#out + 1] = sub(B64_ENC, floor(v / 262144) % 64 + 1, floor(v / 262144) % 64 + 1)
    out[#out + 1] = sub(B64_ENC, floor(v / 4096) % 64 + 1, floor(v / 4096) % 64 + 1)
    if i + 1 <= n then
      out[#out + 1] = sub(B64_ENC, floor(v / 64) % 64 + 1, floor(v / 64) % 64 + 1)
    end
    if i + 2 <= n then
      out[#out + 1] = sub(B64_ENC, v % 64 + 1, v % 64 + 1)
    end
    i = i + 3
  end
  return concat(out)
end

--- Decode a URL-safe base64 string (no padding) to a raw byte string.
--- Returns nil if the input is not valid base64.
--: (str: string) -> string | nil | (nil, string)
function M.decode_cursor(str)
  if type(str) ~= "string" then
    return nil, "decode_cursor: str must be a string"
  end
  local out = {}
  local n = #str
  local i = 1
  -- Pad to multiple of 4 characters for decoding
  while i <= n do
    local c0 = B64_DEC[byte(str, i)]
    local c1 = B64_DEC[byte(str, i + 1)]
    local c2 = B64_DEC[byte(str, i + 2)]
    local c3 = B64_DEC[byte(str, i + 3)]
    if c0 == nil or c1 == nil then return nil end
    local v = c0 * 262144 + c1 * 4096
    out[#out + 1] = char(floor(v / 65536) % 256)
    if c2 ~= nil then
      v = v + c2 * 64
      out[#out + 1] = char(floor(v / 256) % 256)
    end
    if c3 ~= nil then
      v = v + c3
      out[#out + 1] = char(v % 256)
    end
    i = i + 4
  end
  return concat(out)
end

-- ---------------------------------------------------------------------------
-- M.window
-- Returns a slice of items[offset+1 .. offset+limit] (0-based offset).
-- ---------------------------------------------------------------------------

--- Extract a slice from items using 0-based offset and limit.
--: (items: { [integer]: unknown }, offset: integer | nil, limit: integer | nil) -> { [integer]: unknown }
function M.window(items, offset, limit)
  offset = offset or 0
  limit = limit or #items
  local result = {}
  local n = #items
  for i = offset + 1, math.min(offset + limit, n) do
    result[#result + 1] = items[i]
  end
  return result
end

-- ---------------------------------------------------------------------------
-- M.offset
-- Offset/limit pagination over an in-memory list.
-- ---------------------------------------------------------------------------

--- Paginate items using offset/limit.
--- opts: { offset=0, limit=10 }
--- Returns { items, total, page, pages, has_prev, has_next, prev_offset, next_offset }
--: (items: { [integer]: unknown }, opts: { offset?: integer, limit?: integer } | nil) -> { items: { [integer]: unknown }, total: integer, page: integer, pages: integer, has_prev: boolean, has_next: boolean, prev_offset: integer, next_offset: integer } | (nil, string)
function M.offset(items, opts)
  opts = opts or {}
  local offset = opts.offset or 0
  local limit = opts.limit or 10
  if limit < 1 then return nil, "limit must be >= 1" end
  if offset < 0 then return nil, "offset must be >= 0" end
  local total = #items
  local pages = total == 0 and 1 or math.ceil(total / limit)
  local page = floor(offset / limit) + 1
  local slice = M.window(items, offset, limit)
  local has_prev = offset > 0
  local has_next = offset + limit < total
  local prev_offset = math.max(0, offset - limit)
  local next_offset = offset + limit
  return {
    items = slice,
    total = total,
    page = page,
    pages = pages,
    has_prev = has_prev,
    has_next = has_next,
    prev_offset = prev_offset,
    next_offset = next_offset,
  }
end

-- ---------------------------------------------------------------------------
-- M.pages
-- Page-number pagination over an in-memory list.
-- ---------------------------------------------------------------------------

--- Paginate items using 1-based page number.
--- opts: { page=1, per_page=10 }
--- Returns { items, total, page, pages, per_page, has_prev, has_next }
--: (items: { [integer]: unknown }, opts: { page?: integer, per_page?: integer } | nil) -> { items: { [integer]: unknown }, total: integer, page: integer, pages: integer, per_page: integer, has_prev: boolean, has_next: boolean } | (nil, string)
function M.pages(items, opts)
  opts = opts or {}
  local page = opts.page or 1
  local per_page = opts.per_page or 10
  if page < 1 then return nil, "page must be >= 1" end
  if per_page < 1 then return nil, "per_page must be >= 1" end
  local total = #items
  local pages = total == 0 and 1 or math.ceil(total / per_page)
  -- Clamp page to valid range
  page = clamp(page, 1, pages)
  local offset = (page - 1) * per_page
  local slice = M.window(items, offset, per_page)
  return {
    items = slice,
    total = total,
    page = page,
    pages = pages,
    per_page = per_page,
    has_prev = page > 1,
    has_next = page < pages,
  }
end

-- ---------------------------------------------------------------------------
-- M.cursor
-- Cursor-based forward pagination over an in-memory list.
-- The cursor encodes the index of the last-seen item as an opaque token.
-- ---------------------------------------------------------------------------

--- Paginate items using an opaque cursor.
--- opts: { cursor=nil, limit=10, key=function(item) return item.id end }
--- Returns { items, cursor, has_more }
--- cursor is nil on the last page.
--: (items: { [integer]: unknown }, opts: { cursor?: string, limit?: integer, key?: (unknown) -> unknown } | nil) -> { items: { [integer]: unknown }, cursor: string | nil, has_more: boolean } | (nil, string)
function M.cursor(items, opts)
  opts = opts or {}
  local limit = opts.limit or 10
  local key_fn = opts.key
  local cursor_str = opts.cursor
  if limit < 1 then return nil, "limit must be >= 1" end
  local total = #items
  local start_idx = 1
  if cursor_str ~= nil then
    local decoded = M.decode_cursor(cursor_str)
    if decoded == nil then return nil, "invalid cursor" end
    if key_fn ~= nil then
      -- Cursor encodes the key of the last-seen item; find it and start after.
      local found = false
      for i = 1, total do
        if tostring(key_fn(items[i])) == decoded then
          start_idx = i + 1
          found = true
          break
        end
      end
      if not found then
        start_idx = 1
      end
    else
      -- Cursor encodes the 1-based index of the last-seen item.
      local pos = tonumber(decoded)
      if pos == nil then return nil, "invalid cursor" end
      start_idx = floor(pos) + 1
    end
    if start_idx > total then
      return { items = {}, cursor = nil, has_more = false }
    end
  end
  local slice = {}
  local end_idx = math.min(start_idx + limit - 1, total)
  for i = start_idx, end_idx do
    slice[#slice + 1] = items[i]
  end
  local has_more = end_idx < total
  local next_cursor = nil
  if has_more then
    if key_fn ~= nil then
      next_cursor = M.encode_cursor(tostring(key_fn(items[end_idx])))
    else
      next_cursor = M.encode_cursor(tostring(end_idx))
    end
  end
  return {
    items = slice,
    cursor = next_cursor,
    has_more = has_more,
  }
end

-- ---------------------------------------------------------------------------
-- M.paginator
-- Stateful paginator object wrapping an in-memory list.
-- ---------------------------------------------------------------------------

local Paginator = {}
Paginator.__index = Paginator

--: (self: Paginator, n: integer) -> unknown
function Paginator:page(n)
  n = clamp(n, 1, self.total_pages)
  self.current_page = n
  local offset = (n - 1) * self._per_page
  local slice = M.window(self._items, offset, self._per_page)
  return {
    items = slice,
    total = self.total_items,
    page = n,
    pages = self.total_pages,
    per_page = self._per_page,
    has_prev = n > 1,
    has_next = n < self.total_pages,
  }
end

--: (self: Paginator) -> unknown
function Paginator:next()
  if self.current_page >= self.total_pages then return nil end
  return self:page(self.current_page + 1)
end

--: (self: Paginator) -> unknown
function Paginator:prev()
  if self.current_page <= 1 then return nil end
  return self:page(self.current_page - 1)
end

--: (self: Paginator) -> unknown
function Paginator:first()
  return self:page(1)
end

--: (self: Paginator) -> unknown
function Paginator:last()
  return self:page(self.total_pages)
end

--- Create a stateful paginator over items.
--- opts: { page=1, per_page=10 }
--: (items: { [integer]: unknown }, opts: { page?: integer, per_page?: integer } | nil) -> Paginator | (nil, string)
function M.paginator(items, opts)
  opts = opts or {}
  local per_page = opts.per_page or 10
  if per_page < 1 then return nil, "per_page must be >= 1" end
  local total = #items
  local total_pages = total == 0 and 1 or math.ceil(total / per_page)
  local start_page = clamp(opts.page or 1, 1, total_pages)
  local pg = setmetatable({
    _items = items,
    _per_page = per_page,
    total_items = total,
    total_pages = total_pages,
    current_page = start_page,
  }, Paginator)
  return pg
end

-- ---------------------------------------------------------------------------
-- M.lazy_paginator
-- Stateful paginator backed by fetch_fn/count_fn (e.g. database queries).
-- ---------------------------------------------------------------------------

local LazyPaginator = {}
LazyPaginator.__index = LazyPaginator

--: (self: LazyPaginator, n: integer) -> unknown
function LazyPaginator:page(n)
  n = clamp(n, 1, self.total_pages)
  self.current_page = n
  local offset = (n - 1) * self._per_page
  local items = self._fetch_fn(offset, self._per_page)
  return {
    items = items,
    total = self.total_items,
    page = n,
    pages = self.total_pages,
    per_page = self._per_page,
    has_prev = n > 1,
    has_next = n < self.total_pages,
  }
end

--: (self: LazyPaginator) -> unknown
function LazyPaginator:next()
  if self.current_page >= self.total_pages then return nil end
  return self:page(self.current_page + 1)
end

--: (self: LazyPaginator) -> unknown
function LazyPaginator:prev()
  if self.current_page <= 1 then return nil end
  return self:page(self.current_page - 1)
end

--: (self: LazyPaginator) -> unknown
function LazyPaginator:first()
  return self:page(1)
end

--: (self: LazyPaginator) -> unknown
function LazyPaginator:last()
  return self:page(self.total_pages)
end

--- Create a lazy paginator backed by fetch_fn and count_fn.
--- fetch_fn(offset, limit) -> items
--- count_fn() -> total
--- opts: { page=1, per_page=10 }
--: (fetch_fn: (integer, integer) -> { [integer]: unknown }, count_fn: () -> integer, opts: { page?: integer, per_page?: integer } | nil) -> LazyPaginator | (nil, string)
function M.lazy_paginator(fetch_fn, count_fn, opts)
  if type(fetch_fn) ~= "function" then
    return nil, "lazy_paginator: fetch_fn must be a function"
  end
  if type(count_fn) ~= "function" then
    return nil, "lazy_paginator: count_fn must be a function"
  end
  opts = opts or {}
  local per_page = opts.per_page or 10
  if per_page < 1 then return nil, "per_page must be >= 1" end
  local total = count_fn()
  local total_pages = total == 0 and 1 or math.ceil(total / per_page)
  local start_page = clamp(opts.page or 1, 1, total_pages)
  local pg = setmetatable({
    _fetch_fn = fetch_fn,
    _per_page = per_page,
    total_items = total,
    total_pages = total_pages,
    current_page = start_page,
  }, LazyPaginator)
  return pg
end

return M
