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
-- `M.insert`/`M.format` implement yjs's `insertText`/`formatText` in full,
-- including `minimizeAttributeChanges`/`insertAttributes`/
-- `insertNegatedAttributes` (the skip-past-deleted-items-and-matching-
-- format-markers step that decides where new content/markers actually
-- land). This was originally scoped OUT as "a size optimization, not a
-- correctness requirement" -- WRONG, found via fuzzing against real yjs
-- byte-for-byte: skipping past a deleted item or an already-matching
-- format marker changes which item new content's `origin`/`origin_right`
-- point at, which is wire-visible (byte-for-byte, not just marker count)
-- even though it never changes VISIBLE content -- e.g. `insert("q");
-- delete(0,1); insert("W")` places "W" with origin = the deleted "q" item
-- in real yjs (having skipped past it), vs origin = nil (inserted BEFORE
-- "q") without this step.
--
-- `M.delete` implements yjs's delete-time formatting-gap cleanup
-- (`cleanupFormattingGap`, called inline exactly like yjs's own
-- `deleteText`) and remote-apply's whole-type cleanup
-- (`cleanupYTextAfterTransaction`, exposed here as
-- `M.cleanup_after_remote_apply` and called from `update.lua`'s
-- `apply_v1`) -- see the comments at each for the port mapping against
-- `src/types/YText.js`, tag v13.6.31.

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
--:: Transaction = { doc: { client_id: number, store: StructStore, clock: number }, new_items: Item[], deleted_items: Item[], merge_structs: Item[] }

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
-- Ports yjs's `findPosition`/`findNextPosition` (YText.js, tag v13.6.31)
-- EXACTLY, including its stopping condition -- this does NOT skip past
-- trailing deleted/non-countable items once `index` is satisfied, unlike
-- this function's previous behavior (which always walked forward to land
-- `right` on the next live countable item, or nil). That previous behavior
-- was a real, consequential divergence: yjs's own walk only ever advances
-- while `count > 0`, so the instant the visible-count target is reached, it
-- stops wherever that leaves it -- which can very well be a live
-- ContentFormat marker sitting immediately at that position (confirmed via
-- a raw struct-store dump against real yjs: `findPosition(txn, parent, 0)`
-- on a text starting with a format marker returns that marker itself as
-- `right`, unconditionally, since `index=0` means the walk's `count > 0`
-- loop condition is false from the very first check). Landing `right` one
-- item further along (this function's old behavior) silently shifted every
-- caller's insert/delete/format boundary past any leading format marker at
-- the same position -- for `M.delete` specifically, that meant
-- `cleanup_formatting_gap`'s scan range started one item too late to ever
-- reach (and delete) a redundant marker sitting immediately left of the
-- deleted span, a real wire-parity gap (found while porting that cleanup),
-- not a latent one this function's old contract merely "also" had.
--
-- Every iteration advances exactly one link (`left = right; right =
-- right.right`), regardless of what kind of struct `right` currently is:
-- a live ContentFormat marker or a deleted item just gets stepped over
-- (no count change, matching yjs's `switch` falling through to the
-- unconditional advance at the bottom of `findNextPosition`'s loop body);
-- a live countable item decrements `count` by its length, splitting it via
-- struct_store when `index` falls strictly inside it (mirroring yjs's
-- `getItemCleanStart` call, whose return value becomes the walk's next
-- `right` exactly as yjs's own mutate-in-place `Item.prototype.split`
-- leaves `pos.right.right` pointing at the freshly split-off tail).
--
-- Returns (left, right) -- either may be nil (start/end of the sequence).
--
-- BUG FIX (found via fuzzing against real yjs): every split produced here
-- is registered into `txn.merge_structs` -- necessary so
-- `transaction.lua`'s `M.cleanup` merge sweep actually revisits this
-- client. That sweep only runs for clients appearing in
-- `new_items`/`deleted_items`/`merge_structs` -- but a split alone adds to
-- NONE of those on its own; a client whose only change this transaction
-- was a split-with-nothing-else-new (e.g. a redundant `format()` call that
-- needs zero new markers but still lands `count` inside an existing run)
-- was silently skipped by the sweep, leaving a gratuitously split item
-- unmerged. Confirmed against real yjs's own architecture: `structs/
-- Item.js`'s `splitItem` pushes the split-off right part onto
-- `transaction._mergeStructs` unconditionally, specifically so
-- `cleanupTransactions`'s finally block re-merges it regardless of whether
-- the client's clock advanced. `merge_structs` (transaction.lua) is this
-- port's equivalent -- a separate list from `new_items`, NOT folded into
-- it: an earlier version of this fix registered split-off tails into
-- `new_items` directly (reasoning "it's just touched-client tracking, any
-- list works"), which broke `update.lua`'s `M.encode_v1`/
-- `M.encode_diff_v1` -- those encode whatever's in `new_items` as
-- genuinely NEW wire content, and a split-off tail is a repartition of
-- ALREADY-transmitted content, not new content. Confirmed via
-- `update_test.lua`'s regression: a delete's split-off tail got encoded as
-- if new, corrupting the update and breaking the receiving peer's
-- contiguity check.
--: (txn: Transaction, store: StructStore, parent: SharedType, index: integer) -> (Item | nil, Item | nil)
local function find_pos(txn, store, parent, index)
  local left = nil --[[: Item | nil]]
  local right = parent.start
  local count = index
  while right ~= nil and count > 0 do
    if right.content.kind ~= "format" and not right.deleted then
      if count < right.length then
        local tail, err = struct_store.get_item_clean_start(store, id.new(right.id.client, right.id.clock + count))
        if tail == nil then error(err or "text: split failed", 2) end
        table.insert(txn.merge_structs, tail)
        left = right
        right = tail
        count = 0
      else
        count = count - right.length
        left = right
        right = right.right
      end
    else
      left = right
      right = right.right
    end
  end
  return left, right
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

-- TYPECHECKER WORKAROUND: same reasoning as `insert_item`'s wrapping of
-- `integrate.integrate` above, applied to `item.delete` -- item.lua's own
-- `Transaction` alias (`{ doc: unknown, new_items, deleted_items }`)
-- doesn't carry this file's `merge_structs` field, and widening it would
-- ripple into array.lua's/map.lua's/integrate.lua's own hand-restated
-- copies (none of which read `merge_structs`) for a field only this file
-- and transaction.lua actually consume. The natural code would call
-- `item.delete(txn, it)` directly.
--: (txn: Transaction, it: Item) -> nil
local function delete_item(txn, it)
  item.delete({ doc = txn.doc, new_items = txn.new_items, deleted_items = txn.deleted_items }, it)
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

-- A single attribute value never having been set (Lua `nil` -- absent table
-- key) and one explicitly formatted to the wire-null sentinel
-- (`encoding.null`) both mean "no attribute" throughout this file's
-- minimization/cleanup logic -- matches yjs's own `attributes[key] ?? null`
-- collapsing `undefined` and `null` to the same comparison value.
--: (v: unknown) -> unknown
local function normalize_val(v)
  if v == nil then return encoding.null end
  return v
end

-- Ports yjs's `equalAttrs` (YText.js): reference/primitive equality, or a
-- one-level (`lib0/object#equalFlat`-style) shallow comparison when both
-- sides are tables (an attribute value can itself be a compound value, not
-- just a primitive).
--: (a: unknown, b: unknown) -> boolean
local function values_equal(a, b)
  if a == b then return true end
  if type(a) == "table" and type(b) == "table" then
    for k, v in pairs(a --[[: { [unknown]: unknown } ]]) do
      if (b --[[: { [unknown]: unknown } ]])[k] ~= v then return false end
    end
    for k, v in pairs(b --[[: { [unknown]: unknown } ]]) do
      if (a --[[: { [unknown]: unknown } ]])[k] ~= v then return false end
    end
    return true
  end
  return false
end

-- TYPECHECKER WORKAROUND: same field-read-narrowing loss `item.lua`'s own
-- `identity_parent` documents (that one is local to item.lua, so it can't be
-- reused across the module boundary) -- routing `it.parent` through this
-- identity function before checking `.kind`/`.type_name` resets whatever
-- provenance tag blocks direct narrowing on a field read. The natural code
-- would read `it.parent` directly. TODO.md tracks removing this once that's
-- fixed upstream (already tracked there for item.lua's own copy).
--: (v: SharedType | ParentPendingId | nil) -> SharedType | ParentPendingId | nil
local function identity_parent(v)
  return v
end

-- Ports yjs's `cleanupFormattingGap` (src/types/YText.js, tag v13.6.31):
-- called after visible content between `start_item` and `curr_item` has
-- been deleted, this walks that same range and deletes any ContentFormat
-- marker that's now redundant -- either a later marker for the same key
-- overwrites it before the run's true end (computed into `end_formats` by
-- the first mini-scan below, matching yjs's own two-phase walk), or its
-- value equals the attribute already in effect at `start_item`. Returns how
-- many markers were deleted.
--
-- `curr_item` is the boundary (yjs's `curr`) at/after which redundancy
-- checks stop retroactively adjusting `curr_attrs` (yjs's `reachedCurr`);
-- may be nil if the deleted range ran to the end of the type.
-- `start_attrs`/`curr_attrs` follow `current_attrs_at`'s own convention: a
-- key that was never set and a key explicitly formatted to the wire-null
-- sentinel (`encoding.null`) both read as "no attribute" via the
-- nil-normalization below (matches yjs's `Map.get(key) ?? null` collapsing
-- `undefined` and `null` to the same comparison value). `curr_attrs` is
-- mutated in place -- it must already hold the attributes in effect at
-- `curr_item` computed by walking the SAME range once before calling this
-- (matches yjs's `currPos.currentAttributes`, which `deleteText`'s own
-- forward-walk accumulates before invoking this function) -- this function
-- cannot derive that final state on its own single pass, because whether an
-- earlier marker's value survives to `curr_item` depends on markers further
-- right that this same walk hasn't reached yet when it deletes something.
--: (txn: Transaction, start_item: Item, curr_item: Item | nil, start_attrs: { [string]: unknown }, curr_attrs: { [string]: unknown }) -> integer
local function cleanup_formatting_gap(txn, start_item, curr_item, start_attrs, curr_attrs)
  local end_item = start_item --[[: Item | nil]]
  local end_formats = {} --[[: { [string]: Content } ]]
  while end_item ~= nil and (end_item.deleted or not item.is_countable(end_item)) do
    if not end_item.deleted and end_item.content.kind == "format" then
      end_formats[end_item.content.key] = end_item.content
    end
    end_item = end_item.right
  end

  local cleanups = 0
  local reached_curr = false
  local n = start_item --[[: Item | nil]]
  while n ~= nil and n ~= end_item do
    if curr_item == n then reached_curr = true end
    if not n.deleted then
      local c = n.content
      if c.kind == "format" then
        local key = c.key
        -- Normalized the same way `start_attrs`/`curr_attrs` lookups are
        -- below: a LOCALLY-constructed close/negated-attribute marker
        -- (`M.insert`/`M.format`'s `content.format(key, before[key])`) can
        -- hold a genuine Lua `nil` here when there was no prior attribute
        -- to restore -- as opposed to a wire-decoded marker, whose "no
        -- prior attribute" case is always the DISTINCT `encoding.null`
        -- sentinel (JS's explicit `null`, per encoding.lua's JSON-null
        -- convention). Comparing `value` against an attrs-map lookup (which
        -- is always pre-normalized to `encoding.null` for "absent") without
        -- normalizing `value` too would silently miss every LOCAL close
        -- marker whose restored value is nil -- confirmed via a raw
        -- struct-store dump against real yjs's own output for `insert;
        -- format; delete` on a single character: real yjs deletes both
        -- format markers, this comparison without normalization left them
        -- both live.
        local value = c.value
        if value == nil then value = encoding.null end
        local start_val = start_attrs[key]
        if start_val == nil then start_val = encoding.null end
        if end_formats[key] ~= c or start_val == value then
          delete_item(txn, n)
          cleanups = cleanups + 1
          if not reached_curr then
            local cur_val = curr_attrs[key]
            if cur_val == nil then cur_val = encoding.null end
            if cur_val == value and start_val ~= value then
              curr_attrs[key] = start_val
            end
          end
        end
        if not reached_curr and not n.deleted then
          curr_attrs[key] = value
        end
      end
    end
    n = n.right
  end
  return cleanups
end

-- Ports yjs's `cleanupContextlessFormattingGap` (YText.js): given a deleted
-- item, walks right to the next countable-and-visible item, then walks left
-- from there deleting any ContentFormat marker whose key already appeared
-- (closer to that visible item) during this same leftward walk -- a
-- "contextless" variant of `cleanup_formatting_gap` that doesn't need
-- start/curr attribute maps because it only ever removes an exact key
-- duplicate within one gap, never compares against the attribute value in
-- effect at a boundary.
--: (txn: Transaction, it: Item) -> nil
local function cleanup_contextless_formatting_gap(txn, it)
  local n = it --[[: Item | nil]]
  while n ~= nil do
    local r = n.right
    if r == nil then break end
    if not (r.deleted or not item.is_countable(r)) then break end
    n = r
  end
  local seen = {} --[[: { [string]: boolean } ]]
  while n ~= nil and (n.deleted or not item.is_countable(n)) do
    if not n.deleted and n.content.kind == "format" then
      local key = n.content.key
      if seen[key] then
        delete_item(txn, n)
      else
        seen[key] = true
      end
    end
    n = n.left
  end
end

-- Ports yjs's `cleanupYTextFormatting` (YText.js): a full left-to-right
-- sweep of the whole type in countable-run segments, calling
-- `cleanup_formatting_gap` on each gap between one countable/visible item
-- and the next. Used by `M.cleanup_after_remote_apply` below for texts that
-- received a new formatting item during a remote update (where there's no
-- single local start/curr boundary to target, unlike `M.delete`'s inline
-- call).
--: (txn: Transaction, t: SharedType) -> integer
local function cleanup_text_formatting(txn, t)
  local res = 0
  local start_item = t.start --[[: Item | nil]]
  local end_item = t.start --[[: Item | nil]]
  local start_attrs = {} --[[: { [string]: unknown } ]]
  local curr_attrs = {} --[[: { [string]: unknown } ]]
  while end_item ~= nil do
    if not end_item.deleted then
      if end_item.content.kind == "format" then
        curr_attrs[end_item.content.key] = end_item.content.value
      else
        if start_item ~= nil then
          res = res + cleanup_formatting_gap(txn, start_item, end_item, start_attrs, curr_attrs)
        end
        start_attrs = {}
        for k, v in pairs(curr_attrs) do start_attrs[k] = v end
        start_item = end_item
      end
    end
    end_item = end_item.right
  end
  return res
end

-- Ports yjs's `minimizeAttributeChanges` (YText.js): from `(left, right)`,
-- skip past any deleted item unconditionally, or any live ContentFormat
-- marker whose value already equals what `want_attrs` asks for at that
-- key -- both are cases where inserting new content/markers strictly at
-- `right` would be wrong (see this file's header comment for why this
-- isn't just a marker-count optimization: it changes which item new
-- content's `origin`/`origin_right` reference, which is wire-visible).
-- Mutates `cur_attrs` in place for every live marker skipped over (matches
-- yjs's `currPos.currentAttributes` accumulating via `forward()`), and
-- returns the advanced `(left, right)`.
--: (want_attrs: { [string]: unknown }, cur_attrs: { [string]: unknown }, left: Item | nil, right: Item | nil) -> (Item | nil, Item | nil)
local function minimize_attribute_changes(want_attrs, cur_attrs, left, right)
  while right ~= nil do
    if right.deleted then
      -- unconditional skip, no bookkeeping
    elseif right.content.kind == "format" then
      local rkey = right.content.key
      if not values_equal(normalize_val(want_attrs[rkey]), normalize_val(right.content.value)) then break end
      cur_attrs[rkey] = right.content.value
    else
      break
    end
    left = right
    right = right.right
  end
  return left, right
end

-- Ports yjs's `insertAttributes`: inserts an open ContentFormat marker for
-- every key in `want_attrs` whose desired value differs from what's
-- currently active (per `cur_attrs`, already advanced by
-- `minimize_attribute_changes`), recording the attribute's prior value
-- (normalized) into the returned `negated` map -- consumed by
-- `insert_negated_attributes` to restore it after the new content/range.
--: (t: SharedType, txn: Transaction, want_attrs: { [string]: unknown }, cur_attrs: { [string]: unknown }, left: Item | nil, right: Item | nil) -> (Item | nil, { [string]: unknown })
local function insert_attributes(t, txn, want_attrs, cur_attrs, left, right)
  local negated = {} --[[: { [string]: unknown } ]]
  for key, val in pairs(want_attrs) do
    local current_val = normalize_val(cur_attrs[key])
    if not values_equal(current_val, val) then
      negated[key] = current_val
      left = insert_item(t, txn, left, right, content.format(key, val))
    end
  end
  return left, negated
end

-- Ports yjs's `insertNegatedAttributes`: skips past any deleted item
-- unconditionally, or any live ContentFormat marker that already matches a
-- still-pending negated value (consuming it -- no close marker needed for
-- that key), then inserts a close marker for everything left in `negated`.
--: (t: SharedType, txn: Transaction, negated: { [string]: unknown }, left: Item | nil, right: Item | nil) -> nil
local function insert_negated_attributes(t, txn, negated, left, right)
  while right ~= nil do
    if right.deleted then
      -- unconditional skip
    elseif right.content.kind == "format" then
      local rkey = right.content.key
      local nv = negated[rkey]
      if nv == nil then break end
      if not values_equal(nv, normalize_val(right.content.value)) then break end
      negated[rkey] = nil
    else
      break
    end
    left = right
    right = right.right
  end
  for key, val in pairs(negated) do
    left = insert_item(t, txn, left, right, content.format(key, val))
  end
end

-- Inserts `str` at visible position `index`, optionally bracketing it with
-- ContentFormat open/close markers for each key in `attrs` that differs
-- from the attributes already in effect at `index`. Ports yjs's
-- `insertText` in full, including the minimize/negate steps above -- see
-- this file's header comment for why those are required for wire parity,
-- not just an optimization.
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
  local left, right = find_pos(txn, store, t, index)
  local cur_attrs = current_attrs_at(t, index)

  -- BUG FIX (found via fuzzing against real yjs): `Y.Text.prototype.insert`
  -- -- the CALLER of `insertText`, not `insertText` itself -- special-cases
  -- a plain `insert(index, text)` call (no attrs argument): it copies
  -- `pos.currentAttributes` VERBATIM into `attributes` before calling
  -- `insertText` (`attributes = {}; pos.currentAttributes.forEach((v, k) =>
  -- { attributes[k] = v })`), i.e. new plain text INHERITS every attribute
  -- active at the insertion point. `insertText`'s OWN internal step (force
  -- every active-but-unmentioned key to explicit null) only ever runs on
  -- top of an attrs object the CALLER explicitly passed (even `{}` --
  -- `!attributes` is false for a truthy empty object in JS, so passing `{}`
  -- explicitly skips the inherit-copy and goes straight to insertText's own
  -- forcing step instead). This file's `attrs: {...} | nil` parameter maps
  -- directly onto that distinction: `nil` (no table at all) inherits
  -- everything active, matching bare `insert(index, text)`; a non-nil
  -- table (`{}` included) merges then force-negates unmentioned active
  -- keys, matching `insert(index, text, {})`/`insert(index, text,
  -- {bold:true})`. Confirmed via a raw struct-store dump: without this
  -- distinction, `insert("W"); format(0,1,{italic:true}); insert(1,"rk6")`
  -- (no attrs on the second insert) placed "rk6" as unformatted plain text
  -- landing AFTER the format-close marker; real yjs continues the italic
  -- run, placing "rk6" BEFORE the close marker.
  local want_attrs = {} --[[: { [string]: unknown } ]]
  if attrs == nil then
    for key, value in pairs(cur_attrs) do want_attrs[key] = value end
  else
    for key, value in pairs(attrs) do want_attrs[key] = value end
    for key in pairs(cur_attrs) do
      if want_attrs[key] == nil then want_attrs[key] = encoding.null end
    end
  end

  left, right = minimize_attribute_changes(want_attrs, cur_attrs, left, right)
  local negated
  left, negated = insert_attributes(t, txn, want_attrs, cur_attrs, left, right)

  left = insert_item(t, txn, left, right, content.string(str))

  insert_negated_attributes(t, txn, negated, left, right)

  return true
end

-- Applies `attrs` to the visible range [index, index+length). Ports yjs's
-- `formatText` in full: `minimize_attribute_changes`/`insert_attributes` at
-- the range start (same as `M.insert`, minus the "force-negate untouched
-- active attributes" step -- `formatText` doesn't do that; only keys the
-- caller explicitly names are touched), then a walk through the range
-- deleting any existing marker for a touched key (redundant now that a
-- fresh open marker was just inserted) and consuming `length` against
-- countable content, then `insert_negated_attributes` at the range end.
--: (t: SharedType, txn: Transaction, index: integer, length: integer, attrs: { [string]: unknown }) -> true | (nil, string)
function M.format(t, txn, index, length, attrs)
  if type(index) ~= "number" or type(length) ~= "number" or length <= 0 then return nil, "text.format: invalid range" end
  if index < 0 or index + length > t.length then return nil, "text.format: range out of bounds" end
  if type(attrs) ~= "table" or next(attrs) == nil then return nil, "text.format: attrs must be a non-empty table" end
  -- See `insert_item` above for why `math.floor` is needed here.
  index = math.floor(index)
  length = math.floor(length)

  local store = txn.doc.store
  local left, right = find_pos(txn, store, t, index)
  local cur_attrs = current_attrs_at(t, index)

  local want_attrs = {} --[[: { [string]: unknown } ]]
  for key, value in pairs(attrs) do want_attrs[key] = value end

  left, right = minimize_attribute_changes(want_attrs, cur_attrs, left, right)
  local negated
  left, negated = insert_attributes(t, txn, want_attrs, cur_attrs, left, right)

  local remaining = length
  while right ~= nil and (remaining > 0 or (next(negated) ~= nil and (right.deleted or right.content.kind == "format"))) do
    if not right.deleted then
      if right.content.kind == "format" then
        local rkey = right.content.key
        local rvalue = right.content.value
        local attr = want_attrs[rkey]
        if attr ~= nil then
          if values_equal(normalize_val(attr), normalize_val(rvalue)) then
            negated[rkey] = nil
          else
            if remaining == 0 then break end
            negated[rkey] = rvalue
          end
          delete_item(txn, right)
        else
          cur_attrs[rkey] = rvalue
        end
      else
        if remaining < right.length then
          -- See `find_pos`'s header comment for why the split-off tail is
          -- registered into `txn.merge_structs` (NOT `new_items`) -- same
          -- reasoning applies here (this split can be the ONLY structural
          -- change client-side in a transaction, e.g. a redundant
          -- `format()` sub-range request that's already fully satisfied).
          local tail, terr = struct_store.get_item_clean_start(store, id.new(right.id.client, right.id.clock + remaining))
          if tail == nil then return nil, terr or "text.format: split failed" end
          table.insert(txn.merge_structs, tail)
        end
        remaining = remaining - right.length
      end
    end
    left = right
    right = right.right
  end

  insert_negated_attributes(t, txn, negated, left, right)

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
  local _left, right = find_pos(txn, store, t, index)

  -- `start_attrs`/`start_item` capture the pre-delete boundary state (yjs's
  -- `deleteText`: `const startAttrs = map.copy(currPos.currentAttributes);
  -- const start = currPos.right`), taken before any item below is marked
  -- deleted.
  local start_attrs = current_attrs_at(t, index)
  local start_item = right

  local n = right
  local remaining = length
  while remaining > 0 and n ~= nil do
    if not n.deleted and item.is_countable(n) then
      if n.length <= remaining then
        delete_item(txn, n)
        remaining = remaining - n.length
        n = n.right
      else
        -- See `find_pos`'s header comment for why the split-off tail is
        -- registered into `txn.merge_structs` (NOT `new_items` -- that
        -- would corrupt `update.lua`'s wire encoding, see the header
        -- comment). This particular split's client is already touched via
        -- `item.delete`'s `deleted_items` entry below, but registering
        -- unconditionally (matching yjs's own unconditional
        -- `_mergeStructs.push` inside `splitItem`) keeps this invariant
        -- true regardless of call order.
        local tail, terr = struct_store.get_item_clean_start(store, id.new(n.id.client, n.id.clock + remaining))
        if tail == nil then return nil, terr or "text.delete: split failed" end
        table.insert(txn.merge_structs, tail)
        delete_item(txn, n)
        remaining = 0
        n = tail
      end
    else
      n = n.right
    end
  end

  -- Matches yjs's `deleteText` calling `cleanupFormattingGap(transaction,
  -- start, currPos.right, startAttrs, currPos.currentAttributes)` once the
  -- delete loop finishes. `curr_attrs` here replicates what yjs accumulates
  -- via `currPos.forward()` DURING that same loop (picking up any live
  -- ContentFormat marker inside the deleted span) -- done as a clean second
  -- walk after the fact instead of interleaved, which is behaviorally
  -- identical: only ContentFormat items feed `curr_attrs`, and no
  -- ContentFormat item's deleted-state changes during the delete loop above
  -- (only countable String/Type/Embed items get deleted there), so reading
  -- `m.deleted` before or after that loop gives the same answer for every
  -- format marker in range.
  if start_item ~= nil then
    local curr_attrs = {} --[[: { [string]: unknown } ]]
    for k, v in pairs(start_attrs) do curr_attrs[k] = v end
    local m = start_item --[[: Item | nil]]
    while m ~= nil and m ~= n do
      if not m.deleted and m.content.kind == "format" then
        curr_attrs[m.content.key] = m.content.value
      end
      m = m.right
    end
    cleanup_formatting_gap(txn, start_item, n, start_attrs, curr_attrs)
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

-- Ports yjs's `cleanupYTextAfterTransaction` (src/types/YText.js, tag
-- v13.6.31). Real yjs only ever runs this pass for a REMOTE-origin
-- transaction: it's gated behind `transaction._needFormattingCleanup`,
-- which is set ONLY in `YText.prototype._callObserver`'s `if
-- (!transaction.local && this._hasFormatting)` branch -- a LOCAL
-- transaction's own `deleteText` already cleans up its own formatting gaps
-- inline (`cleanup_formatting_gap`'s call in `M.delete` above), so yjs never
-- re-runs this heavier whole-type pass for local edits. This port's
-- architecture has an exact 1:1 stand-in for yjs's "local" vs "remote":
-- `doc.lua`'s `M.transact` (local) vs `update.lua`'s `apply_v1` (remote,
-- wire-decoded) are already two distinct call sites -- so this function is
-- called ONLY from `update.lua`'s `apply_v1`, never from `doc.lua`'s
-- `transact`, matching yjs's gate exactly without needing a
-- `transaction.local` flag of its own.
--
-- SCOPE: yjs additionally gates the whole pass behind each YText's
-- `_hasFormatting` flag (an item-integration-time cache -- pure perf, skips
-- scanning texts that have never held a ContentFormat item). This port has
-- no such per-Text flag; it always attempts the contextless-cleanup scan
-- for any deleted item whose parent is a Text, which is a harmless no-op
-- when that Text never held formatting (no ContentFormat markers exist to
-- find/dedupe). Correctness-identical, not a perf optimization this port
-- makes yet.
--
-- Uses `txn.new_items`/`txn.deleted_items` directly (already-tracked flat
-- lists) instead of yjs's `beforeState`/`afterState`/`deleteSet` walk --
-- equivalent information for "which items were integrated or deleted by
-- this transaction," matching the same substitution transaction.lua's own
-- header comment justifies for its GC/merge passes.
--: (txn: Transaction) -> nil
function M.cleanup_after_remote_apply(txn)
  local need_full_cleanup = {} --[[: SharedType[] ]]

  --: (p: SharedType) -> boolean
  local function has_full_cleanup(p)
    for _, existing in ipairs(need_full_cleanup) do
      if existing == p then return true end
    end
    return false
  end

  --: (p: SharedType) -> nil
  local function mark_full_cleanup(p)
    if not has_full_cleanup(p) then
      table.insert(need_full_cleanup, p)
    end
  end

  -- Any Text that received a new, live ContentFormat item during this
  -- transaction needs the full whole-type sweep (yjs: the
  -- `transaction.afterState`/`beforeState` walk collecting into
  -- `needFullCleanup`). ContentFormat items are only ever created under a
  -- Text parent (`text.lua`'s `M.insert`/`M.format` are content.lua's sole
  -- callers of `content.format`), so no `type_name == "text"` filter is
  -- needed here the way `M.delete`'s own gap-scan uses one below.
  for _, it in ipairs(txn.new_items) do
    if not it.deleted and it.content.kind == "format" then
      local p = identity_parent(it.parent)
      if p ~= nil and p.kind == "shared_type" then
        mark_full_cleanup(p)
      end
    end
  end

  -- Every other Text-parented deletion either widens the needed cleanup to
  -- "full" (if the deleted item was itself a format marker -- yjs: `if
  -- (item.content.constructor === ContentFormat) needFullCleanup.add(parent)`)
  -- or gets the cheaper contextless gap scan.
  for _, it in ipairs(txn.deleted_items) do
    local p = identity_parent(it.parent)
    if p ~= nil and p.kind == "shared_type" and p.type_name == "text" and not has_full_cleanup(p) then
      if it.content.kind == "format" then
        mark_full_cleanup(p)
      else
        cleanup_contextless_formatting_gap(txn, it)
      end
    end
  end

  for _, p in ipairs(need_full_cleanup) do
    cleanup_text_formatting(txn, p)
  end
end

return M
