if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Y.Array: a sequence shared type over arbitrary values. A rich wrapper
-- around the bare SharedType record (shared_type.lua) and the YATA core
-- (item.lua/integrate.lua/struct_store.lua) -- see TODO.md's "shared_type.lua
-- is bare" entry this fills in.
--
-- Wire-format note: a single `insert(txn, index, values)` call batches every
-- consecutive plain value (string/number/boolean/table/nil-via-encoding.null)
-- into ONE Item holding a multi-value ContentAny, splitting to a fresh Item
-- only around a nested shared-type value (ContentType) -- verified against
-- upstream yjs (`typeListInsertGenericsAfter` in yjs/yjs's src/ytype.js,
-- tag v14.0.0-rc.24, fetched 2026-07-27: it accumulates a `jsonContent`
-- array across consecutive non-Type/non-Doc/non-Binary values and only
-- flushes it into a `new ContentAny(jsonContent)` Item when it hits one of
-- those or the input ends). This module implements only the ContentAny/
-- ContentType split (Y.Doc and raw-binary values are out of this task's
-- scope, matching the task brief's value list).
--
-- Splitting an already-integrated Item must go through
-- struct_store.get_item_clean_start/get_item_clean_end (not item.split
-- directly), same reasoning as text.lua: the store keeps its own
-- per-client clock-ordered array in sync with every split.

local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local shared_type = require("lib.y_crdt.shared_type")
local struct_store = require("lib.y_crdt.struct_store")
local integrate = require("lib.y_crdt.integrate")

local M = {}

-- See text.lua for why these are hand-restated rather than `typeof`-captured.
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

-- `merge_structs` matches transaction.lua's/text.lua's own field of the
-- same name (unused by this file -- array.lua has no split call sites of
-- its own yet -- but present so a `txn` value threaded through both this
-- file and text.lua in the same `doc.transact` callback type-checks
-- consistently; see transaction.lua's `Transaction` header comment for
-- what the field is for).
--:: Transaction = { doc: { client_id: number, store: StructStore, clock: number }, new_items: Item[], deleted_items: Item[], merge_structs: Item[] }

-- TYPECHECKER WORKAROUND: see map.lua's `M.new` for the full writeup --
-- `shared_type.new(...)`'s return can't be cast wholesale into this file's
-- `Item`-fielded `SharedType` (a record whose fields are `unknown` never
-- casts field-for-field into one with concrete field types, confirmed by
-- several minimal repros). Sidestepped by constructing the return value
-- from the known-empty literal fields of a freshly-made SharedType
-- directly, borrowing the original's metatable so `shared_type.is()`
-- still recognizes it.
--: () -> SharedType
function M.new()
  local st = shared_type.new("array")
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
-- (nil, nil, string)` (a 2-tuple-success/3-tuple-failure union) and let
-- callers destructure `local left, right, ferr = find_pos(...)`. That hits
-- the same destructuring-narrowing bug struct_store.lua's TODO entry
-- documents for `T | (nil, string)`: `left`/`right` don't cleanly narrow
-- away the failure arm afterward, cascading into "argument might also be
-- (nil, string)" errors at every later use. Changed to throw instead --
-- matches struct_store.lua's own precedent for this exact situation
-- (`find_index`/`M.get_item_clean_start`'s underlying failures): a genuine
-- caller-facing error can only originate from a wire-decoded item
-- referencing an unknown/not-yet-arrived id, which cannot happen here --
-- `index` is already validated in range by every public caller before
-- `find_pos` runs, over a store this same transaction is the only writer
-- to. `doc.transact`'s `pcall` turns this into an ordinary `(nil, errmsg)`
-- at the public API boundary regardless, so no caller-observable behavior
-- changes. TODO.md tracks reverting to `(nil, nil, string)` once
-- multi-arity-union destructuring narrows correctly.
--
-- Identical in shape to text.lua's `find_pos` (see there for the
-- reasoning); kept as a separate copy rather than a shared helper module to
-- keep each rich-type file independently understandable, matching this
-- library's existing preference for per-file restatement over cross-file
-- reuse of small internals (e.g. the Item/SharedType/Content type aliases
-- above are restated the same way in text.lua).
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
          if right == nil then error(err or "array: split failed", 2) end
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
-- let callers destructure it into a reused local (`left = it`) -- same
-- destructuring-narrowing bug as `find_pos` above, since `left`/`right`
-- would then carry the `(nil, string)` failure arm forward. Changed to
-- throw for the same reason and with the same no-observable-behavior-
-- change guarantee (via `doc.transact`'s `pcall`): `integrate.integrate`
-- can only fail here for a malformed *wire-decoded* item (unknown origin,
-- parent referencing a not-yet-arrived id, ...), and every item this
-- function builds is freshly originated by this same in-memory operation,
-- never decoded. TODO.md tracks reverting once that bug is fixed upstream.
--: (a: SharedType, txn: Transaction, left: Item | nil, right: Item | nil, c: Content) -> Item
local function insert_item(a, txn, left, right, c)
  local doc = txn.doc
  local origin = left ~= nil and item.last_id(left) or nil
  local origin_right = right ~= nil and right.id or nil
  -- `math.floor` (declared `(x: number) -> integer` in stdlib_types.lua) is
  -- this codebase's established way to narrow `number` to `integer` -- a
  -- plain checked cast (`doc.client_id --[[: integer]]`) is rejected
  -- outright ("cannot assign number to integer"; confirmed by minimal
  -- repro, `integer` isn't checked-cast-reachable from bare `number`).
  local iid = id.new(math.floor(doc.client_id), math.floor(doc.clock))
  local new_item = item.new(iid, origin, origin_right, a, nil, c)
  -- Wrapped to integrate.lua's exact declared Transaction shape -- see
  -- text.lua's insert_item for why (nested record fields aren't
  -- width-subtyped; new_items/deleted_items are the same array references).
  local ok, err = integrate.integrate({ doc = { store = doc.store }, new_items = txn.new_items, deleted_items = txn.deleted_items }, new_item)
  if ok == nil then error(err or "array: integrate failed", 2) end
  doc.clock = doc.clock + new_item.length
  return new_item
end

-- TYPECHECKER WORKAROUND: same reasoning as `insert_item` above, applied to
-- `item.delete` -- item.lua's own `Transaction` alias doesn't carry this
-- file's `merge_structs` field (added so a `txn` value threaded through
-- both this file and text.lua in the same `doc.transact` callback
-- type-checks consistently; see transaction.lua's `Transaction` header
-- comment). The natural code would call `item.delete(txn, it)` directly.
--: (txn: Transaction, it: Item) -> nil
local function delete_item(txn, it)
  item.delete({ doc = txn.doc, new_items = txn.new_items, deleted_items = txn.deleted_items }, it)
end

-- Inserts `values` (a Lua list -- no embedded literal `nil`; use
-- `require("lib.y_crdt.encoding").null` for an explicit wire-null element,
-- same sentinel convention encoding.lua already documents) at visible
-- position `index`. Consecutive plain values are batched into one Item;
-- each nested-shared-type value (`shared_type.is(v)`) gets its own Item and
-- has its `.item` field wired back to the new Item, mirroring yjs's
-- `ContentType.integrate` setting `type._item`.
--: (a: SharedType, txn: Transaction, index: integer, values: unknown[]) -> true | (nil, string)
function M.insert(a, txn, index, values)
  if type(values) ~= "table" then return nil, "array.insert: values must be a table" end
  -- `index` is re-narrowed via `math.floor` right after the `type(index)`
  -- guard: the guard's `type(index) ~= "number"` check widens `index`'s
  -- declared `integer` down to plain `number` (the standard `type(x) ==
  -- "number"` narrowing rule, which doesn't know `integer` is already a
  -- more specific `number`) -- confirmed by minimal repro. `math.floor` is
  -- this codebase's established `number -> integer` narrowing tool (see
  -- `insert_item` above).
  if type(index) ~= "number" or index < 0 or index > a.length then return nil, "array.insert: index out of range" end
  index = math.floor(index)
  local n = #values
  if n == 0 then return true end

  local store = txn.doc.store
  local left, right = find_pos(store, a, index)

  local batch = {} --[[: unknown[] ]]

  --: () -> nil
  local function flush()
    if #batch > 0 then
      left = insert_item(a, txn, left, right, content.any(batch))
      batch = {}
    end
  end

  for i = 1, n do
    local v = values[i]
    if shared_type.is(v) then
      flush()
      local it = insert_item(a, txn, left, right, content.type(v))
      -- TYPECHECKER WORKAROUND: `v` is `unknown` (this is a plain `unknown[]`
      -- values list); wiring `.item` back needs a `type(v) == "table"`
      -- narrowing step first -- see map.lua's `M.set` for the full writeup
      -- (a bare `unknown -> record` cast is rejected regardless of record
      -- shape, confirmed by minimal repro; `shared_type.is` alone doesn't
      -- feed the static typechecker).
      if type(v) == "table" then
        local vt = v --[[: { item: Item | nil } ]]
        vt.item = it
      end
      left = it
    else
      table.insert(batch, v)
    end
  end
  flush()

  return true
end

-- Deletes `length` visible elements starting at `index`. Splits a
-- multi-value ContentAny item at either boundary as needed (via
-- struct_store, same as text.lua's delete).
--: (a: SharedType, txn: Transaction, index: integer, length: integer) -> true | (nil, string)
function M.delete(a, txn, index, length)
  if type(index) ~= "number" or type(length) ~= "number" or length <= 0 then return nil, "array.delete: invalid range" end
  if index < 0 or index + length > a.length then return nil, "array.delete: range out of bounds" end
  -- See M.insert for why `math.floor` is needed here (the `type(index) ==
  -- "number"` guard above widens `index`/`length` to plain `number`).
  index = math.floor(index)
  length = math.floor(length)

  local store = txn.doc.store
  local _left, right = find_pos(store, a, index)

  local n = right
  local remaining = length
  while remaining > 0 and n ~= nil do
    if not n.deleted and item.is_countable(n) then
      if n.length <= remaining then
        delete_item(txn, n)
        remaining = remaining - n.length
        n = n.right
      else
        local tail, terr = struct_store.get_item_clean_start(store, id.new(n.id.client, n.id.clock + remaining))
        if tail == nil then return nil, terr or "array.delete: split failed" end
        delete_item(txn, n)
        remaining = 0
        n = tail
      end
    else
      n = n.right
    end
  end

  return true
end

--: (a: SharedType, index: integer) -> unknown
function M.get(a, index)
  if type(index) ~= "number" or index < 0 or index >= a.length then return nil end
  local n = a.start
  local count = index
  while n ~= nil do
    if not n.deleted and item.is_countable(n) then
      if count < n.length then
        if n.content.kind == "any" then return n.content.arr[count + 1] end
        if n.content.kind == "type" then return n.content.shared_type end
        return nil
      end
      count = count - n.length
    end
    n = n.right
  end
  return nil
end

--: (a: SharedType) -> unknown[]
function M.to_array(a)
  local out = {} --[[: unknown[] ]]
  local n = a.start
  while n ~= nil do
    if not n.deleted and item.is_countable(n) then
      if n.content.kind == "any" then
        for i = 1, #n.content.arr do table.insert(out, n.content.arr[i]) end
      elseif n.content.kind == "type" then
        table.insert(out, n.content.shared_type)
      end
    end
    n = n.right
  end
  return out
end

--: (a: SharedType) -> number
function M.length(a)
  return a.length
end

return M
