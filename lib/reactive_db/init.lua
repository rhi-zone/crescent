-- lib/reactive_db/init.lua
-- Reactive in-memory relational database with live queries.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Row = { [string]: unknown }
--:: Pred = (row: Row) -> boolean
--:: Tbl = { _db: unknown, _name: string, _schema: unknown, _pk: string | nil, _rows: { [unknown]: Row }, _order: { [integer]: unknown }, _subs: { [integer]: unknown }, _live: { [integer]: unknown }, _indexes: { [string]: { [unknown]: { [integer]: unknown } } }, _fire: (self: Tbl, event: string, row: Row | nil, old_row: Row | nil) -> nil, _index_add: (self: Tbl, pk: unknown, row: Row) -> nil, _index_remove: (self: Tbl, pk: unknown, row: Row) -> nil, insert: (self: Tbl, row: Row) -> boolean | (nil, string), update: (self: Tbl, pk: unknown, patch: Row) -> boolean | (nil, string), ... }
--:: QB = { _tbl: Tbl, _where: Pred | nil, _order: string | nil, _dir: string, _limit: integer | nil, _offset: integer, _join: { other: Tbl, local_field: string, other_field: string } | nil, _base_rows: (self: QB) -> { [integer]: Row }, select: (self: QB) -> { [integer]: Row }, where: (self: QB, pred: unknown) -> QB, order_by: (self: QB, field: string, dir: string | nil) -> QB, limit: (self: QB, n: integer) -> QB, offset: (self: QB, n: integer) -> QB, join: (self: QB, other: Tbl, local_field: string, other_field: string) -> QB, count: (self: QB) -> integer, first: (self: QB) -> Row | nil, ... }
--:: DB = { _tables: { [string]: Tbl }, ... }

-- ── Helpers ───────────────────────────────────────────────────────────────────

--: (t: { [unknown]: unknown }) -> { [unknown]: unknown }
local function shallow_copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

--: (t: { [unknown]: unknown }) -> integer
local function table_len(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- ── Query Builder ─────────────────────────────────────────────────────────────
-- Returned by tbl:where(), tbl:order_by(), tbl:limit(), tbl:offset(), tbl:join()
-- All methods return a new query builder (immutable chain).

local QB = {}
QB.__index = QB

--: (tbl: Tbl, opts: QB | nil) -> QB
local function new_qb(tbl, opts)
  return setmetatable({
    _tbl     = tbl,
    _where   = opts and opts._where or nil,
    _order   = opts and opts._order or nil,
    _dir     = opts and opts._dir   or "asc",
    _limit   = opts and opts._limit or nil,
    _offset  = opts and opts._offset or 0,
    _join    = opts and opts._join  or nil,  -- { other, local_field, other_field }
  }, QB)
end

--: (qb: QB) -> QB
local function qb_clone(qb)
  return new_qb(qb._tbl, qb)
end

--: (self: QB, pred: unknown) -> QB
function QB:where(pred)
  local q = qb_clone(self)
  if type(pred) == "function" then
    q._where = pred
  else
    -- table of field=value pairs → equality predicate
    local filter = pred
    q._where = function(row)
      for k, v in pairs(filter) do
        if row[k] ~= v then return false end
      end
      return true
    end
  end
  return q
end

--: (self: QB, field: string, dir: string | nil) -> QB
function QB:order_by(field, dir)
  local q = qb_clone(self)
  q._order = field
  q._dir   = dir or "asc"
  return q
end

--: (self: QB, n: integer) -> QB
function QB:limit(n)
  local q = qb_clone(self)
  q._limit = n
  return q
end

--: (self: QB, n: integer) -> QB
function QB:offset(n)
  local q = qb_clone(self)
  q._offset = n
  return q
end

--: (self: QB, other: Tbl, local_field: string, other_field: string) -> QB
function QB:join(other, local_field, other_field)
  local q = qb_clone(self)
  q._join = { other = other, local_field = local_field, other_field = other_field }
  return q
end

--: (self: QB) -> { [integer]: Row }
function QB:_base_rows()
  local tbl   = self._tbl
  local pred  = self._where
  local rows  = {}

  -- If there's a hash index and the predicate is a simple equality filter,
  -- try to use it. We detect this by checking for the internal _eq_fields table.
  -- We always fall back to full scan when no index matches.
  for _, row in pairs(tbl._rows) do
    if pred ~= nil then
      if pred(row) then rows[#rows + 1] = shallow_copy(row) end
    else
      rows[#rows + 1] = shallow_copy(row)
    end
  end

  if self._order then
    local field = self._order
    local asc   = self._dir ~= "desc"
    table.sort(rows, function(a, b)
      if asc then return a[field] < b[field] end
      return a[field] > b[field]
    end)
  end

  local offset = self._offset or 0
  local limit  = self._limit

  if offset > 0 or limit then
    local out = {}
    local i   = 0
    for idx = offset + 1, #rows do
      if limit and i >= limit then break end
      i = i + 1
      out[i] = rows[idx]
    end
    return out
  end

  return rows
end

--: (self: QB) -> { [integer]: Row }
function QB:select()
  if not self._join then
    return self:_base_rows()
  end

  local j           = self._join
  local other       = j.other
  local local_field = j.local_field
  local other_field = j.other_field

  -- Build lookup index on other table keyed by other_field value.
  local other_index = {} --[[: { [unknown]: { [integer]: Row } } ]]
  for _, row in pairs(other._rows) do
    local key = row[other_field]
    if key ~= nil then
      local bucket = other_index[key]
      if not bucket then bucket = {}; other_index[key] = bucket end
      bucket[#bucket + 1] = row
    end
  end

  local base = self:_base_rows()
  local out  = {}
  for _, row in ipairs(base) do
    local key      = row[local_field]
    local matches  = other_index[key]
    if matches then
      for _, other_row in ipairs(matches) do
        local merged = shallow_copy(row)
        for k, v in pairs(other_row) do
          -- Prefix with other table name if conflict
          if merged[k] ~= nil and k ~= other_field then
            merged[other._name .. "_" .. k] = v
          else
            merged[k] = v
          end
        end
        out[#out + 1] = merged
      end
    end
  end
  return out
end

--: (self: QB) -> integer
function QB:count()
  return #self:_base_rows()
end

--: (self: QB) -> Row | nil
function QB:first()
  local rows = self:_base_rows()
  return rows[1]
end

-- ── Table ─────────────────────────────────────────────────────────────────────

local Tbl = {}
Tbl.__index = Tbl

--: (db: DB, name: string, opts: unknown) -> Tbl
local function new_table(db, name, opts)
  local opts_ = opts --[[:! { schema: unknown, primary_key: string | nil } | nil]]
  return setmetatable({
    _db         = db,
    _name       = name,
    _schema     = opts_ and opts_.schema      or nil,
    _pk         = opts_ and opts_.primary_key or nil,
    _rows       = {},   -- { [pk_value] = row }
    _order      = {},   -- insertion-order list of pk values
    _subs       = {},   -- { fn, ... }
    _live       = {},   -- { live_query, ... }
    _indexes    = {},   -- { [field] = { [value] = { pk, ... } } }
  }, Tbl)
end

-- Fire all subscribers. old_row is nil for insert, row is nil for delete.
--: (self: Tbl, event: string, row: Row | nil, old_row: Row | nil) -> nil
function Tbl:_fire(event, row, old_row)
  for _, fn in ipairs(self._subs) do
    (fn --[[:! (string, Row | nil, Row | nil) -> nil]])(event, row, old_row)
  end
  -- Update live queries
  for _, lq in ipairs(self._live) do
    (lq --[[:! { _refresh: (self: unknown) -> nil }]]):_refresh()
  end
end

-- Update hash indexes for a row being added/removed.
--: (self: Tbl, pk: unknown, row: Row) -> nil
function Tbl:_index_add(pk, row)
  for field, idx in pairs(self._indexes) do
    local val = row[field]
    if val ~= nil then
      if not idx[val] then idx[val] = {} end
      idx[val][#idx[val] + 1] = pk
    end
  end
end

--: (self: Tbl, pk: unknown, row: Row) -> nil
function Tbl:_index_remove(pk, row)
  for field, idx in pairs(self._indexes) do
    local val = row[field]
    if val ~= nil and idx[val] then
      local list = idx[val]
      for i = #list, 1, -1 do
        if list[i] == pk then table.remove(list, i); break end
      end
    end
  end
end

--: (self: Tbl, row: Row) -> boolean | (nil, string)
function Tbl:insert(row)
  if self._pk then
    local pk = row[self._pk]
    if pk == nil then return nil, "missing primary key" end
    if self._rows[pk] then return nil, "duplicate primary key: " .. tostring(pk) end
    local stored = shallow_copy(row)
    self._rows[pk] = stored
    self._order[#self._order + 1] = pk
    self:_index_add(pk, stored)
    self:_fire("insert", shallow_copy(stored), nil)
  else
    -- no primary key: use sequential int key
    local pk = #self._order + 1
    local stored = shallow_copy(row)
    self._rows[pk] = stored
    self._order[pk] = pk
    self:_fire("insert", shallow_copy(stored), nil)
  end
  return true
end

--: (self: Tbl, pk: unknown) -> Row | nil
function Tbl:get(pk)
  local row = self._rows[pk]
  if not row then return nil end
  return shallow_copy(row)
end

--: (self: Tbl, pk: unknown, patch: Row) -> boolean | (nil, string)
function Tbl:update(pk, patch)
  local row = self._rows[pk]
  if not row then return nil, "not found: " .. tostring(pk) end
  local old = shallow_copy(row)
  self:_index_remove(pk, row)
  for k, v in pairs(patch) do row[k] = v end
  self:_index_add(pk, row)
  self:_fire("update", shallow_copy(row), old)
  return true
end

--: (self: Tbl, row: Row) -> boolean | (nil, string)
function Tbl:upsert(row)
  if not self._pk then return nil, "upsert requires primary_key" end
  local pk = row[self._pk]
  if pk == nil then return nil, "missing primary key" end
  if self._rows[pk] then
    -- update: merge all fields except pk
    local patch = {}
    for k, v in pairs(row) do patch[k] = v end
    return self:update(pk, patch)
  else
    return self:insert(row)
  end
end

--: (self: Tbl, pk: unknown) -> boolean | (nil, string)
function Tbl:delete(pk)
  local row = self._rows[pk]
  if not row then return nil, "not found: " .. tostring(pk) end
  local old = shallow_copy(row)
  self:_index_remove(pk, row)
  self._rows[pk] = nil
  -- Remove from order list
  for i = #self._order, 1, -1 do
    if self._order[i] == pk then table.remove(self._order, i); break end
  end
  self:_fire("delete", nil, old)
  return true
end

--: (self: Tbl, fn: unknown) -> () -> nil
function Tbl:subscribe(fn)
  self._subs[#self._subs + 1] = fn
  local subs = self._subs
  return function()
    for i = #subs, 1, -1 do
      if subs[i] == fn then table.remove(subs, i); break end
    end
  end
end

--: (self: Tbl, filter: unknown, fn: unknown) -> unknown
function Tbl:live_query(filter, fn)
  local lq_rows = {} --: { [integer]: Row }
  local lq = {
    _tbl    = self,
    _filter = filter,
    _fn     = fn,
    _rows   = lq_rows,
  }
  --:: LiveQuery = { _tbl: Tbl, _filter: unknown, _fn: unknown, _rows: { [integer]: Row }, ... }
  --: (LiveQuery) -> nil
  function lq:_refresh()
    local rows = new_qb(self._tbl, nil):where(self._filter):select()
    self._rows = rows
    local call_fn = self._fn --[[:! ({ [integer]: Row }) -> nil]]
    call_fn(rows)
  end
  --: (LiveQuery) -> nil
  function lq:destroy()
    local live = self._tbl._live
    for i = #live, 1, -1 do
      if live[i] == self then table.remove(live, i); break end
    end
  end
  self._live[#self._live + 1] = lq
  -- Immediate evaluation
  lq:_refresh()
  return lq
end

--: (self: Tbl, field: string) -> nil
function Tbl:index(field)
  if self._indexes[field] then return end -- already exists
  local idx = {}
  -- Build from existing data
  for pk, row in pairs(self._rows) do
    local val = row[field]
    if val ~= nil then
      if not idx[val] then idx[val] = {} end
      idx[val][#idx[val] + 1] = pk
    end
  end
  self._indexes[field] = idx
end

-- Query builder entry points on table object
--: (self: Tbl, pred: unknown) -> QB
function Tbl:where(pred)   return new_qb(self, nil):where(pred) end
--: (self: Tbl, field: string, dir: string | nil) -> QB
function Tbl:order_by(field, dir) return new_qb(self, nil):order_by(field, dir) end
--: (self: Tbl, n: integer) -> QB
function Tbl:limit(n)      return new_qb(self, nil):limit(n) end
--: (self: Tbl, n: integer) -> QB
function Tbl:offset(n)     return new_qb(self, nil):offset(n) end
--: (self: Tbl, other: Tbl, local_field: string, other_field: string) -> QB
function Tbl:join(other, local_field, other_field) return new_qb(self, nil):join(other, local_field, other_field) end
--: (self: Tbl) -> { [integer]: Row }
function Tbl:select()      return new_qb(self, nil):select() end
--: (self: Tbl) -> integer
function Tbl:count()       return new_qb(self, nil):count() end
--: (self: Tbl) -> Row | nil
function Tbl:first()       return new_qb(self, nil):first() end

-- ── Database ──────────────────────────────────────────────────────────────────

local DB = {}
DB.__index = DB

--: (self: DB, name: string, opts: unknown) -> Tbl
function DB:table(name, opts)
  if self._tables[name] then return self._tables[name] end
  local t = new_table(self, name, opts)
  self._tables[name] = t
  return t
end

-- ACID-ish transaction: snapshot all table rows; on error, restore snapshot.
--: (self: DB, fn: unknown) -> boolean | (nil, unknown)
function DB:transaction(fn)
  -- Snapshot: deep copy all rows
  local snapshots = {}
  for tname, tbl in pairs(self._tables) do
    local snap = { rows = {}, order = {} }
    for pk, row in pairs(tbl._rows) do snap.rows[pk] = shallow_copy(row --[[:! { [unknown]: unknown }]]) end
    for i, pk in ipairs(tbl._order) do snap.order[i] = pk end
    snapshots[tname] = snap
  end

  local ok, err = pcall(fn)

  if not ok then
    -- Rollback: restore snapshots (suppress events during restore)
    for tname, snap in pairs(snapshots) do
      local tbl = self._tables[tname]
      tbl._rows  = snap.rows
      tbl._order = snap.order
      -- Rebuild indexes
      for field in pairs(tbl._indexes) do
        local idx = {} --[[: { [unknown]: { [integer]: unknown } } ]]
        for pk, row in pairs(tbl._rows) do
          local val = row[field]
          if val ~= nil then
            local bucket = idx[val]
            if not bucket then bucket = {}; idx[val] = bucket end
            bucket[#bucket + 1] = pk
          end
        end
        tbl._indexes[field] = idx
      end
    end
    return nil, err
  end

  return true
end

-- ── Module entry point ────────────────────────────────────────────────────────

--: () -> DB
function M.database()
  return setmetatable({ _tables = {} }, DB)
end

return M
