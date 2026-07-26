if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Per-client struct storage in clock order. Mirrors yjs utils/StructStore.js.
-- `clients[client_id]` is a contiguous, gap-free (except for explicit Skip
-- placeholders), clock-sorted array of Item | Gc | Skip. "Contiguous" means
-- structs[i].id.clock + structs[i].length == structs[i+1].id.clock always.

local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local gc = require("lib.y_crdt.gc")
local skip = require("lib.y_crdt.skip")

local M = {}

--:: Id = { client: integer, clock: integer }

-- Captured via `typeof` from each struct module's own constructor (see
-- docs/typechecker-reference.md) rather than restated by hand: this gives
-- the exact Item/Gc/Skip shapes those modules declare, with no risk of
-- drifting from them as those modules evolve.
local sample_id = id.new(0, 0)
local sample_item = item.new(sample_id, nil, nil, nil, nil, content.deleted(0))
--:: ItemT = typeof sample_item
local sample_gc = gc.new(sample_id, 1)
--:: GcT = typeof sample_gc
local sample_skip = skip.new(sample_id, 1)
--:: SkipT = typeof sample_skip
--:: Struct = ItemT | GcT | SkipT

-- TYPECHECKER WORKAROUND: `id`/`length`/`kind`/`deleted` are structurally
-- common to all three Struct variants and, per docs/
-- typechecker-reference.md ("Field access on union: only fields present in
-- ALL members are accessible without narrowing"), should be readable
-- directly off a `Struct`-typed value with no cast. In practice, reading
-- them directly off a union built from three separate `typeof`-captured
-- record types collapses to `nil`/`any` here (confirmed with a minimal
-- repro: `s.id.clock` on `s: Struct` warns "inference fell back to any",
-- and downstream arithmetic on it then hard-errors as "cannot perform
-- arithmetic on nil"). The natural code would just read `s.id`/`s.length`
-- directly; this alias exists to route those reads through an explicit
-- upcast (`s --[[: StructCommon]]`, a width-subtyping upcast, not a forced
-- one) instead, which the checker handles correctly (see also: `x.kind ==
-- "lit"` narrows correctly, but `x.kind ~= "lit"` does not -- this file
-- always uses the positive form for that reason too). TODO.md tracks
-- reverting to direct field access once this narrows correctly upstream.
--:: StructCommon = { id: Id, length: integer, kind: string, deleted: boolean }

--:: StructStore = { clients: { [number]: Struct[] } }

-- TYPECHECKER WORKAROUND: indexing `store.clients[client]` (an index
-- signature field, `{ [number]: Struct[] }`) yields a `Struct[]` whose
-- elements later fail kind-narrowing in a way a plain `Struct[]` parameter
-- does not -- confirmed with a minimal repro: `if s.kind == "item" then
-- return s end` type-checks fine when `s` comes from indexing a `Struct[]`
-- parameter, but errors "match type contains any -- exhaustiveness cannot
-- be verified" when `s` comes from indexing the result of `store.clients[
-- client]` in a function that returns the narrowed variant. Routing the
-- looked-up array through this identity function (any ordinary function
-- call, not a cast) resets whatever provenance tag causes that, and the
-- same narrowing then type-checks correctly afterward. The natural code
-- would use `store.clients[iid.client]` directly with no extra call.
-- TODO.md tracks removing this once that narrowing bug is fixed upstream.
--: (structs: Struct[]) -> Struct[]
local function as_structs(structs)
  return structs
end

--: () -> StructStore
function M.new()
  return { clients = {} } --[[: StructStore]]
end

-- Binary search matching yjs `findIndexSS`. yjs documents this as expecting
-- the caller to have already checked the id is covered by the store
-- ("Always check state before looking for a struct in StructStore.
-- Therefore the case of not finding a struct is unexpected") and throws
-- (`error.unexpectedCase()`) rather than signaling a data error -- so this
-- does too, via Lua `error()`, which the library convention permits for
-- precondition violations (as opposed to caller-facing data errors).
--
-- TYPECHECKER WORKAROUND: an earlier version returned `integer | (nil,
-- string)` here to follow the (nil, errmsg) convention uniformly. That hit
-- a second, separate typechecker bug: narrowing `if idx == nil then return
-- ... end` on a local destructured from a `T | (nil, string)`-returning
-- call does not narrow away the `(nil, string)` arm (minimal repro: `local
-- a, b = f(x); if a == nil then return end; a + 1` still errors "cannot
-- perform arithmetic on integer | (nil, string)" after the guard).
-- Returning a single value here (throwing instead of the tuple) sidesteps
-- it entirely, and happens to match yjs's own contract for this function.
-- TODO.md tracks revisiting this once that narrowing bug is fixed upstream.
--: (structs: StructCommon[], clock: integer) -> integer
local function find_index(structs, clock)
  local n = #structs
  if n == 0 then error("struct store: empty client", 2) end
  local left, right = 1, n
  local mid = structs[right]
  if mid.id.clock == clock then return right end
  while left <= right do
    local midx = math.floor((left + right) / 2)
    mid = structs[midx]
    if mid.id.clock <= clock then
      if clock < mid.id.clock + mid.length then return midx end
      left = midx + 1
    else
      right = midx - 1
    end
  end
  error("struct store: clock " .. clock .. " not covered by any struct", 2)
end
M._find_index = find_index

-- Adds `struct` to the store. Expects `struct.id.clock` to equal the next
-- expected clock for its client -- UNLESS it lands inside an existing Skip
-- placeholder, in which case the skip is split around it (matches yjs
-- `StructStore.prototype.add`, the "replaces an integrated skip" branch).
--
-- TYPECHECKER WORKAROUND: declared `(true | nil, string | nil)` -- two
-- separate optional return values -- rather than `true | (nil, string)` (a
-- union with the error case embedded as a tuple), matching the same fix
-- applied to `get_clean_start`/`get_clean_end` above (see that comment for
-- the minimal repro): the tuple-embedded shape never narrows a caller's
-- `ok == nil` guard, so any subsequent use of a value derived from the
-- OTHER destructured local past that guard stays spuriously nilable
-- indefinitely. A caller that only checks `ok == nil` and returns
-- immediately (this file's own callers, before this change) doesn't hit
-- the bug; lib/y_crdt/update.lua's caller (which OR's the error message
-- against a fallback across loop iterations) does. Purely a type
-- annotation change -- both branches already return two values at
-- runtime, so no behavioral change for any existing caller.
--: (store: StructStore, s: Struct) -> (true | nil, string | nil)
function M.add(store, s)
  local common = s --[[: StructCommon]]
  local sid = common.id
  local structs = store.clients[sid.client]
  if structs == nil then
    structs = {}
    store.clients[sid.client] = structs
    table.insert(structs, s)
    return true
  end
  local last = structs[#structs] --[[: StructCommon]]
  if last.id.clock + last.length ~= sid.clock then
    -- Not contiguous with the last struct: must be filling in (part of) a
    -- Skip placeholder somewhere earlier in the array.
    local idx = find_index(structs, sid.clock)
    local sk = structs[idx] --[[: StructCommon]]
    if sk.kind == "skip" then
      local diff_start = sid.clock - sk.id.clock
      local diff_end = sk.id.clock + sk.length - sid.clock - common.length
      if diff_start > 0 then
        table.insert(structs, idx, skip.new(id.new(sk.id.client, sk.id.clock), diff_start))
        idx = idx + 1
      end
      if diff_end > 0 then
        table.insert(structs, idx + 1, skip.new(id.new(sk.id.client, sid.clock + common.length), diff_end))
      end
      structs[idx] = s
      return true
    end
    return nil, "struct store: clock " .. sid.clock .. " is not contiguous and does not fall inside a skip"
  end
  table.insert(structs, s)
  return true
end

-- Returns the struct (of any kind) covering `iid`. (nil, errmsg) only for
-- the caller-facing data error of an unknown client; a known client with an
-- uncovered clock is a precondition violation (see find_index) and throws.
--: (store: StructStore, iid: Id) -> Struct | (nil, string)
function M.get(store, iid)
  local structs = store.clients[iid.client]
  if structs == nil then return nil, "struct store: unknown client " .. iid.client end
  return structs[find_index(structs, iid.clock)]
end

-- Returns the Item covering `iid`. Errors if the covering struct is a Gc or
-- Skip (i.e. this id names deleted-and-collected or not-yet-known content).
--
-- TYPECHECKER WORKAROUND: the natural code calls `M.get` and checks its
-- result, but `M.get` returns `Struct | (nil, string)`, and destructuring
-- that into a local hits the same narrowing bug documented on
-- `find_index` above -- even a plain `if s == nil then return nil, err
-- end; ...; return s` after the destructure fails typechecking on the
-- final `return s`. Repeating the two-line "unknown client" + find_index
-- lookup here (instead of delegating to M.get) avoids ever destructuring a
-- `T | (nil, string)` return into a reused local. TODO.md tracks
-- collapsing this back to calling M.get once that bug is fixed upstream.
--: (store: StructStore, iid: Id) -> ItemT | (nil, string)
function M.find(store, iid)
  local structs0 = store.clients[iid.client]
  if structs0 == nil then return nil, "struct store: unknown client " .. iid.client end
  local structs = as_structs(structs0)
  local s = structs[find_index(structs, iid.clock)]
  if s.kind == "item" then return s end
  local common = s --[[: StructCommon]]
  return nil, "struct store: struct at " .. iid.client .. "#" .. iid.clock .. " is not an item (kind=" .. common.kind .. ")"
end

-- Next expected clock for `client` (0 if the client is unknown).
--: (store: StructStore, client: number) -> integer
function M.get_state(store, client)
  local structs = store.clients[client]
  if structs == nil or #structs == 0 then return 0 end
  local last = structs[#structs] --[[: StructCommon]]
  return last.id.clock + last.length
end

--: (store: StructStore) -> { [number]: integer }
function M.get_state_vector(store)
  local sv = {} --[[: { [number]: integer } ]]
  for client, _ in pairs(store.clients) do
    sv[client] = M.get_state(store, client)
  end
  return sv
end

-- Returns all structs for `client` overlapping [start_clock, end_clock),
-- without splitting any struct that straddles the range boundary (use
-- get_item_clean_start/get_item_clean_end first if you need exact
-- boundaries).
--: (store: StructStore, client: number, start_clock: integer, end_clock: integer) -> Struct[]
function M.iterate(store, client, start_clock, end_clock)
  local structs = store.clients[client]
  local result = {} --[[: Struct[] ]]
  if structs == nil then return result end
  for _, s in ipairs(structs) do
    local common = s --[[: StructCommon]]
    if common.id.clock < end_clock and common.id.clock + common.length > start_clock then
      table.insert(result, s)
    end
  end
  return result
end

-- Splits the struct at `structs[idx]` at `diff`, inserting the right part
-- right after it. Throws if `diff` names a boundary Item content refuses to
-- split at (matches yjs: reaching this on a malformed/adversarial input is
-- itself the precondition violation, not something this call recovers from
-- -- see find_index's comment on why this file throws for these).
--: (structs: Struct[], idx: integer, diff: integer) -> Struct
local function split_struct_at(structs, idx, diff)
  local s = structs[idx]
  local right --[[: Struct | nil]]
  if s.kind == "item" then
    local split_result, split_err = item.split(s, diff)
    if split_result == nil then error(split_err or "struct store: split failed", 2) end
    right = split_result
  elseif s.kind == "gc" then
    right = gc.splice(s, diff)
  else
    right = skip.splice(s, diff)
  end
  table.insert(structs, idx + 1, right)
  return right
end

-- Returns the Item starting exactly at `iid.clock`, splitting the covering
-- struct if `iid.clock` falls in its middle (matches yjs
-- `getItemCleanStart`). Errors if the covering struct is not an Item.
--: (store: StructStore, iid: Id) -> ItemT | (nil, string)
function M.get_item_clean_start(store, iid)
  local structs0 = store.clients[iid.client]
  if structs0 == nil then return nil, "struct store: unknown client " .. iid.client end
  local structs = as_structs(structs0)
  local idx = find_index(structs, iid.clock)
  local s = structs[idx]
  local common = s --[[: StructCommon]]
  if common.id.clock < iid.clock then
    split_struct_at(structs, idx, iid.clock - common.id.clock)
    idx = idx + 1
  end
  local result = structs[idx]
  if result.kind == "item" then return result end
  return nil, "struct store: struct at " .. iid.client .. "#" .. iid.clock .. " is not an item"
end

-- Returns the Item ending exactly at `iid.clock` (inclusive), splitting the
-- covering struct if `iid.clock` falls before its last clock (matches yjs
-- `getItemCleanEnd`). Errors if the covering struct is not an Item.
--: (store: StructStore, iid: Id) -> ItemT | (nil, string)
function M.get_item_clean_end(store, iid)
  local structs0 = store.clients[iid.client]
  if structs0 == nil then return nil, "struct store: unknown client " .. iid.client end
  local structs = as_structs(structs0)
  local idx = find_index(structs, iid.clock)
  local s = structs[idx]
  local common = s --[[: StructCommon]]
  if common.id.clock + common.length - 1 ~= iid.clock and common.kind == "item" then
    split_struct_at(structs, idx, iid.clock - common.id.clock + 1)
  end
  local result = structs[idx]
  if result.kind == "item" then return result end
  return nil, "struct store: struct at " .. iid.client .. "#" .. iid.clock .. " is not an item"
end

-- Same splitting behavior as `get_item_clean_start`, but returns whatever
-- struct kind actually covers `iid.clock` instead of requiring an Item.
-- Needed for wire-decoded origin/origin_right/parent resolution
-- (lib/y_crdt/integrate.lua's parent-resolution step, mirroring yjs's
-- `Item.prototype.getMissing`): a real update's origin can legitimately
-- point into an already garbage-collected range (matches yjs
-- `getItemCleanStart`/`getItemCleanEnd`, which are typed `-> Item` in their
-- JSDoc but in practice return `Item | GC` -- the `struct.constructor !==
-- GC` guard on the split step is the tell). A Skip covering `iid.clock`
-- means the content at that clock hasn't arrived yet -- a genuine missing
-- causal dependency, not a struct-kind mismatch -- so that case still
-- returns (nil, errmsg), distinguishable by message from the "unknown
-- client" case.
--
-- TYPECHECKER WORKAROUND: declared `(Struct | nil, string | nil)` -- two
-- separate optional return values -- rather than this file's other
-- error-returning functions' usual `Struct | (nil, string)` shape (a union
-- with the error case embedded as a tuple). Confirmed by minimal repro:
-- a caller that destructures `local s, err = get_clean_start(...)`, guards
-- `if s == nil then return nil, err end`, and then does anything beyond a
-- single field read or `return` with `s` (e.g. `s.length` used in a
-- comparison or arithmetic) never actually narrows `s` away from nilable
-- with the `Struct | (nil, string)` shape -- every subsequent read of a
-- plain field stays `T | nil` indefinitely, with no cast (checked or
-- forced -- force casts are hard-rejected by this project's typechecker)
-- able to fix it. The plain-two-return-values shape narrows correctly on
-- the exact same guard. This is a real behavioral difference from
-- `get_item_clean_start`/`get_item_clean_end` above (which keep the older
-- shape and work fine for their callers, which only ever do a single
-- field/kind check on the result) -- callers here (lib/y_crdt/
-- integrate.lua, lib/y_crdt/update.lua) need to do more with the result.
-- TODO.md tracks reconciling the two shapes project-wide once this
-- narrowing bug is fixed upstream.
--: (store: StructStore, iid: Id) -> (Struct | nil, string | nil)
function M.get_clean_start(store, iid)
  local structs0 = store.clients[iid.client]
  if structs0 == nil then return nil, "struct store: unknown client " .. iid.client end
  local structs = as_structs(structs0)
  local idx = find_index(structs, iid.clock)
  local s = structs[idx]
  local common = s --[[: StructCommon]]
  if common.id.clock < iid.clock and common.kind == "item" then
    split_struct_at(structs, idx, iid.clock - common.id.clock)
    idx = idx + 1
  end
  local result = structs[idx]
  local result_common = result --[[: StructCommon]]
  if result_common.kind == "skip" then
    return nil, "struct store: missing dependency at " .. iid.client .. "#" .. iid.clock
  end
  return result
end

--: (store: StructStore, iid: Id) -> (Struct | nil, string | nil)
function M.get_clean_end(store, iid)
  local structs0 = store.clients[iid.client]
  if structs0 == nil then return nil, "struct store: unknown client " .. iid.client end
  local structs = as_structs(structs0)
  local idx = find_index(structs, iid.clock)
  local s = structs[idx]
  local common = s --[[: StructCommon]]
  if common.id.clock + common.length - 1 ~= iid.clock and common.kind == "item" then
    split_struct_at(structs, idx, iid.clock - common.id.clock + 1)
  end
  local result = structs[idx]
  local result_common = result --[[: StructCommon]]
  if result_common.kind == "skip" then
    return nil, "struct store: missing dependency at " .. iid.client .. "#" .. iid.clock
  end
  return result
end

return M
