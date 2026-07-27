if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Y.Text: a sequence shared type over string content, with optional
-- ContentFormat markers for inline formatting attributes. A rich wrapper
-- around the bare SharedType record (shared_type.lua) and the YATA core
-- (item.lua/integrate.lua/struct_store.lua) -- see TODO.md for the
-- "shared_type.lua is bare" entry this fills in.
--
-- Splitting an already-integrated Item must go through
-- struct_store.get_item_clean_start/get_item_clean_end (not item.split
-- directly), because the store keeps its own per-client clock-ordered
-- array in sync with every split -- calling item.split standalone would
-- desync the two. Every index-to-item translation below routes through
-- those two functions for that reason.
--
-- SCOPE: `format` inserts open/close ContentFormat marker pairs computed
-- from a left-to-right scan of currently-active attributes at the target
-- index. This does not implement yjs's redundant-marker cleanup
-- (YText.js's insertNegatedAttributes/cleanupContextlessFormatting), which
-- is a size optimization, not a correctness requirement -- `to_delta`'s own
-- attribute-tracking scan produces the same visible result either way.
-- TODO.md tracks adding the cleanup pass.

local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local shared_type = require("lib.y_crdt.shared_type")
local struct_store = require("lib.y_crdt.struct_store")
local integrate = require("lib.y_crdt.integrate")
local encoding = require("lib.y_crdt.encoding")

local M = {}

-- Hand-restated (not `typeof`-captured) for the same reason integrate.lua
-- hand-restates them: Item/SharedType are mutually self-referential, and
-- `typeof` on a self-referential record loses precision on its own
-- recursive fields (see TODO.md). These are structurally identical to
-- item.lua's/shared_type.lua's own declarations, which remain the sole
-- source of the *values*.
--:: Id = { client: integer, clock: integer }
-- `ParentPendingId`/`SharedType.kind` match item.lua's/shared_type.lua's own
-- additions (built alongside lib/y_crdt/update.lua, the wire decoder, in
-- parallel with this file) -- see integrate.lua's matching restatement for
-- the full rationale.
--:: ParentPendingId = { kind: "pending_parent_id", client: integer, clock: integer }
--:: Content = { kind: "deleted", ref: integer, len: integer } | { kind: "string", ref: integer, str: string } | { kind: "json", ref: integer, arr: unknown[] } | { kind: "embed", ref: integer, embed: unknown } | { kind: "any", ref: integer, arr: unknown[] } | { kind: "format", ref: integer, key: string, value: unknown } | { kind: "type", ref: integer, shared_type: unknown } | { kind: "doc", ref: integer, guid: string, opts: unknown } | { kind: "binary", ref: integer, bytes: string }
--:: SharedType = { kind: "shared_type", type_name: string, start: Item | nil, map: { [string]: Item }, length: number, item: Item | nil }
--:: Item = {
--::   kind: "item",
--::   id: Id,
--::   origin: Id | nil,
--::   origin_right: Id | nil,
--::   left: Item | nil,
--::   right: Item | nil,
--::   parent: SharedType | ParentPendingId | nil,
--::   parent_sub: string | nil,
--::   content: Content,
--::   length: integer,
--::   deleted: boolean,
--::   keep: boolean,
--:: }

local sample_store = struct_store.new()
--:: StructStore = typeof sample_store

-- `doc` is restricted to the fields this file actually touches (matches
-- integrate.lua's `Transaction.doc` restatement, for the same reason: the
-- alternative is `typeof`-capturing transaction.lua's own `Transaction`,
-- whose `doc` field is declared `unknown` there specifically to avoid a
-- require() cycle back to doc.lua -- too imprecise to use here).
--:: Transaction = { doc: { client_id: number, store: StructStore, clock: number }, new_items: Item[], deleted_items: Item[] }

-- TYPECHECKER WORKAROUND: see map.lua's `M.new` for the full writeup --
-- `shared_type.new(...)`'s return can't be cast wholesale into this file's
-- `Item`-fielded `SharedType`. Sidestepped by constructing the return
-- value from the known-empty literal fields of a freshly-made SharedType
-- directly, borrowing the original's metatable so `shared_type.is()`
-- still recognizes it.
--: () -> SharedType
function M.new()
  local st = shared_type.new("text")
  return setmetatable({
    kind = "shared_type",
    type_name = st.type_name,
    start = nil,
    map = {},
    length = 0,
    item = nil,
  }, getmetatable(st)) --[[: SharedType]]
end

-- TYPECHECKER WORKAROUND: previously returned `(Item | nil, Item | nil) |
-- (nil, nil, string)` and let callers destructure `local left, right, ferr
-- = find_pos(...)`. That hits the same destructuring-narrowing bug
-- struct_store.lua's TODO entry documents for `T | (nil, string)`:
-- `left`/`right` don't cleanly narrow away the failure arm afterward.
-- Changed to throw instead, matching struct_store.lua's own precedent for
-- this situation: a genuine failure here can only originate from a
-- wire-decoded item referencing an unknown/not-yet-arrived id, which
-- cannot happen for `index` already validated in range over a store this
-- same transaction is the only writer to. `doc.transact`'s `pcall` turns
-- this into an ordinary `(nil, errmsg)` at the public API boundary
-- regardless, so no caller-observable behavior changes. TODO.md tracks
-- reverting to `(nil, nil, string)` once multi-arity-union destructuring
-- narrows correctly.
--
-- Walks from `parent.start`, skipping deleted/non-countable items, to find
-- the two live neighbors surrounding visible position `index`. Splits the
-- covering item via struct_store when `index` falls inside one. Returns
-- (left, right) -- either may be nil (start/end of the sequence).
--: (store: StructStore, parent: SharedType, index: integer) -> (Item | nil, Item | nil)
local function find_pos(store, parent, index)
  local n = parent.start
  local prev = nil --[[: Item | nil]]
  local count = index
  while n ~= nil do
    if not n.deleted and item.is_countable(n) then
      if count < n.length then
        if count > 0 then
          local right, err = struct_store.get_item_clean_start(store, id.new(n.id.client, n.id.clock + count))
          if right == nil then error(err or "text: split failed", 2) end
          return right.left, right
        end
        return n.left, n
      end
      count = count - n.length
    end
    prev = n
    n = n.right
  end
  return prev, nil
end

-- TYPECHECKER WORKAROUND: previously returned `Item | (nil, string)` and
-- let callers destructure it into a reused local (`left = marker`) -- same
-- destructuring-narrowing bug as `find_pos` above. Changed to throw for
-- the same reason and with the same no-observable-behavior-change
-- guarantee (via `doc.transact`'s `pcall`): `integrate.integrate` can only
-- fail here for a malformed *wire-decoded* item, never one freshly
-- originated by this same in-memory operation. TODO.md tracks reverting
-- once that bug is fixed upstream.
--
-- Creates and integrates a single Item between `left`/`right`, advancing
-- doc.clock by its length. The one seam every insert/format operation in
-- this file goes through.
--: (t: SharedType, txn: Transaction, left: Item | nil, right: Item | nil, c: Content) -> Item
local function insert_item(t, txn, left, right, c)
  local doc = txn.doc
  local origin = left ~= nil and item.last_id(left) or nil
  local origin_right = right ~= nil and right.id or nil
  -- `math.floor` (declared `(x: number) -> integer` in stdlib_types.lua) is
  -- this codebase's established `number -> integer` narrowing tool -- a
  -- plain checked cast (`doc.client_id --[[: integer]]`) is rejected
  -- outright ("cannot assign number to integer"; confirmed by minimal
  -- repro, `integer` isn't checked-cast-reachable from bare `number`).
  local iid = id.new(math.floor(doc.client_id), math.floor(doc.clock))
  local new_item = item.new(iid, origin, origin_right, t, nil, c)
  -- `integrate.integrate` declares its own narrower `Transaction.doc` type
  -- (`{ store: StructStore }` only) to avoid a require() cycle back to
  -- doc.lua; nested record fields are not width-subtyped by the
  -- typechecker (confirmed with a minimal repro: passing a wider nested
  -- field type where a narrower one is declared is rejected as an "excess
  -- field"), so this file's wider `Transaction.doc` (client_id/store/clock)
  -- can't be passed directly. Wrapping in a fresh table matching
  -- integrate.lua's exact declared shape sidesteps that -- `new_items`/
  -- `deleted_items` are the *same* array objects (Lua tables are
  -- references), so integrate.lua's `table.insert` calls still land in
  -- this transaction's real arrays.
  local ok, err = integrate.integrate({ doc = { store = doc.store }, new_items = txn.new_items, deleted_items = txn.deleted_items }, new_item)
  if ok == nil then error(err or "text: integrate failed", 2) end
  doc.clock = doc.clock + new_item.length
  return new_item
end

-- Scans from `parent.start` up to (not including) visible position `index`,
-- tracking the running format state via ContentFormat markers. Deleted
-- items (including deleted format markers) are skipped -- a cleared marker
-- should not affect the attributes reported at a later position.
--: (parent: SharedType, index: integer) -> { [string]: unknown }
local function current_attrs_at(parent, index)
  local attrs = {} --[[: { [string]: unknown } ]]
  local n = parent.start
  local count = 0
  while n ~= nil and count < index do
    if not n.deleted then
      if n.content.kind == "format" then
        attrs[n.content.key] = n.content.value
      elseif item.is_countable(n) then
        count = count + n.length
      end
    end
    n = n.right
  end
  return attrs
end

--: (a: { [string]: unknown } | nil, b: { [string]: unknown } | nil) -> boolean
local function attrs_equal(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k, v in pairs(b) do
    if a[k] ~= v then return false end
  end
  return true
end

-- Inserts `str` at visible position `index`, optionally bracketing it with
-- ContentFormat open/close markers for each key in `attrs` that differs
-- from the attributes already in effect at `index`.
--: (t: SharedType, txn: Transaction, index: integer, str: string, attrs: { [string]: unknown } | nil) -> true | (nil, string)
function M.insert(t, txn, index, str, attrs)
  if type(str) ~= "string" then return nil, "text.insert: str must be a string" end
  if #str == 0 then return true end
  -- See `insert_item` above for why `math.floor` is needed here (the
  -- `type(index) == "number"` guard widens `index`'s declared `integer`
  -- down to plain `number`).
  if type(index) ~= "number" or index < 0 or index > t.length then return nil, "text.insert: index out of range" end
  index = math.floor(index)

  local store = txn.doc.store
  local left, right = find_pos(store, t, index)

  local before = current_attrs_at(t, index)

  if attrs ~= nil then
    for key, value in pairs(attrs) do
      if before[key] ~= value then
        left = insert_item(t, txn, left, right, content.format(key, value))
      end
    end
  end

  left = insert_item(t, txn, left, right, content.string(str))

  if attrs ~= nil then
    for key, value in pairs(attrs) do
      if before[key] ~= value then
        left = insert_item(t, txn, left, right, content.format(key, before[key]))
      end
    end
  end

  return true
end

-- Applies `attrs` to the visible range [index, index+length) by inserting
-- an open marker (new value) at `index` and a close marker (the value that
-- was in effect immediately before `index`, possibly nil) at `index+length`.
--: (t: SharedType, txn: Transaction, index: integer, length: integer, attrs: { [string]: unknown }) -> true | (nil, string)
function M.format(t, txn, index, length, attrs)
  if type(index) ~= "number" or type(length) ~= "number" or length <= 0 then return nil, "text.format: invalid range" end
  if index < 0 or index + length > t.length then return nil, "text.format: range out of bounds" end
  if type(attrs) ~= "table" or next(attrs) == nil then return nil, "text.format: attrs must be a non-empty table" end
  -- See `insert_item` above for why `math.floor` is needed here.
  index = math.floor(index)
  length = math.floor(length)

  local store = txn.doc.store
  local before = current_attrs_at(t, index)

  local start_left, start_right = find_pos(store, t, index)
  local left = start_left
  for key, value in pairs(attrs) do
    if before[key] ~= value then
      left = insert_item(t, txn, left, start_right, content.format(key, value))
    end
  end

  local end_left, end_right = find_pos(store, t, index + length)
  left = end_left
  for key, value in pairs(attrs) do
    if before[key] ~= value then
      left = insert_item(t, txn, left, end_right, content.format(key, before[key]))
    end
  end

  return true
end

-- Deletes `length` visible characters starting at `index`.
--: (t: SharedType, txn: Transaction, index: integer, length: integer) -> true | (nil, string)
function M.delete(t, txn, index, length)
  if type(index) ~= "number" or type(length) ~= "number" or length <= 0 then return nil, "text.delete: invalid range" end
  if index < 0 or index + length > t.length then return nil, "text.delete: range out of bounds" end
  -- See `insert_item` above for why `math.floor` is needed here.
  index = math.floor(index)
  length = math.floor(length)

  local store = txn.doc.store
  local _left, right = find_pos(store, t, index)

  local n = right
  local remaining = length
  while remaining > 0 and n ~= nil do
    if not n.deleted and item.is_countable(n) then
      if n.length <= remaining then
        item.delete(txn, n)
        remaining = remaining - n.length
        n = n.right
      else
        local tail, terr = struct_store.get_item_clean_start(store, id.new(n.id.client, n.id.clock + remaining))
        if tail == nil then return nil, terr or "text.delete: split failed" end
        item.delete(txn, n)
        remaining = 0
        n = tail
      end
    else
      n = n.right
    end
  end

  return true
end

--: (t: SharedType) -> string
function M.to_string(t)
  local parts = {} --[[: string[] ]]
  local n = t.start
  while n ~= nil do
    if not n.deleted and n.content.kind == "string" then
      table.insert(parts, n.content.str)
    end
    n = n.right
  end
  -- TYPECHECKER WORKAROUND: `table.concat`'s stdlib signature wants
  -- `{ [integer]: string | number, ... }` (an open index signature); the
  -- `string[]` sugar this file declares `parts` with expands to
  -- `{ [number]: string }` instead (narrower value type, no open marker,
  -- `number` not `integer` key) and is rejected as "missing indexer for
  -- integer". A checked cast to the exact open shape `table.concat` wants
  -- widens rather than narrows (superset of both key and value type), so
  -- it's sound. The natural code would be the bare `table.concat(parts)`
  -- above. TODO.md tracks removing this once `T[]` and `{ [integer]: T,
  -- ... }` unify for stdlib functions declared against the latter.
  return table.concat(parts --[[: { [integer]: string | number, ... } ]])
end

--: (t: SharedType) -> number
function M.length(t)
  return t.length
end

--:: DeltaOp = { insert: string, attributes: ({ [string]: unknown } | nil) }

-- Quill-delta-style rendering: runs of visible text grouped by the format
-- attributes in effect over that run, in document order.
--: (t: SharedType) -> DeltaOp[]
function M.to_delta(t)
  local delta = {} --[[: DeltaOp[] ]]
  local attrs = {} --[[: { [string]: unknown } ]]
  local buf = {} --[[: string[] ]]
  local buf_attrs = nil --[[: { [string]: unknown } | nil]]

  -- BUG FIX (found via lib/y_crdt/parity_test.lua against a real yjs
  -- fixture): a format "close" marker's value is the attribute's prior
  -- value at that position, which for "was never set" is the wire-null
  -- sentinel (`encoding.null`) rather than absence -- confirmed against
  -- real yjs, whose own decoded `ContentFormat.value` for such a marker is
  -- JS `null`, not `undefined` (verified with a bun script applying
  -- fixtures/updates/text_format.bin and inspecting the decoded struct
  -- store directly). Real yjs's `YText.prototype.toDelta`, though, treats a
  -- null-valued attribute as "formatting removed" and omits that key from
  -- the emitted run's `attributes` object entirely -- this is a
  -- presentation-layer convention on top of the (correctly decoded) null
  -- value, not a change to what's stored. `snapshot_attrs` matches that
  -- convention here: it skips any key currently holding `encoding.null`
  -- rather than copying it forward into the delta run's attributes.
  --: () -> ({ [string]: unknown } | nil)
  local function snapshot_attrs()
    local copy = nil --[[: { [string]: unknown } | nil]]
    for k, v in pairs(attrs) do
      if v ~= encoding.null then
        if copy == nil then copy = {} end
        copy[k] = v
      end
    end
    return copy
  end

  --: () -> nil
  local function flush()
    if #buf > 0 then
      table.insert(delta, { insert = table.concat(buf --[[: { [integer]: string | number, ... } ]]), attributes = buf_attrs })
      buf = {}
    end
  end

  local n = t.start
  while n ~= nil do
    if not n.deleted then
      if n.content.kind == "format" then
        flush()
        attrs[n.content.key] = n.content.value
        buf_attrs = nil
      elseif n.content.kind == "string" then
        local snap = snapshot_attrs()
        if not attrs_equal(snap, buf_attrs) then
          flush()
          buf_attrs = snap
        end
        table.insert(buf, n.content.str)
      end
    end
    n = n.right
  end
  flush()

  return delta
end

return M
