-- lib/y_crdt/update.lua
--
-- yjs update v1 wire format: encode/decode of the binary blob that carries
-- a set of new structs (Items/GC/Skip) plus a delete set between replicas.
-- Verified byte-for-byte against yjs upstream (github.com/yjs/yjs, tag
-- v13.6.31 -- the actual npm `latest`; `main` is an unreleased
-- 14.0.0-rc rewrite with a different struct architecture and is NOT the
-- deployed wire format anything speaks). Sources fetched 2026-07-27:
-- src/structs/Item.js (info-byte layout, contentRefs, write/getMissing),
-- src/structs/{GC,Skip,Content*}.js (per-struct/per-content wire shapes),
-- src/utils/{UpdateEncoder,UpdateDecoder,encoding,DeleteSet}.js (top-level
-- framing, state vector, delete set -- confirmed V1's delete-set clocks are
-- NOT delta-encoded, unlike the initial task brief's assumption).
--
-- Byte layout:
--   Section 1 (structs): varUint numClients; per client: varUint
--     numStructs, varUint client, varUint startClock; per struct: uint8
--     info (low 5 bits = struct-kind/content-ref: 0=GC, 10=Skip, 1-9=Item
--     content kind; bit 0x80=has origin, 0x40=has origin_right,
--     0x20=has parent_sub), then the kind-specific payload.
--   Section 2 (delete set): varUint numClients; per client: varUint
--     client, varUint numRanges; per range: varUint clock (ABSOLUTE, not
--     delta -- V1-specific), varUint len.
--
-- SCOPE cuts (documented, not silent): this port assumes every causal
-- dependency an update references (origin/origin_right/parent ids, delete
-- ranges) is already present in the target doc's struct store when
-- decoding -- unlike yjs's resumable stack-based `integrateStructs`
-- (src/utils/encoding.js), which can hold a partial update pending future
-- arrivals. A missing dependency here is a caller-facing (nil, errmsg), not
-- something this module resolves by waiting; TODO.md tracks building the
-- resumable path if cross-update streaming is ever needed. Content ref 5
-- (embed)/2 (json)/6 (format)'s JSON.stringify semantics collapse JS's
-- null/undefined distinction into encoding.lua's single `M.null` sentinel
-- (documented at each read/write site below; Lua tables can't hold a
-- genuine "hole" as an array element the way a JS array can). ContentType
-- (ref 7) only supports Array/Map/Text type refs (0/1/2) -- XmlElement/
-- XmlFragment/XmlHook/XmlText (3-6) are not representable at all in this
-- codebase (shared_type.lua/doc.lua have no XML concept), so decoding one
-- returns (nil, errmsg). Root-type parent references (the wire's
-- "parentYKey" form) are resolved by looking up `doc.share[name]` at
-- decode time and require the caller to have already created that root
-- (via doc.get_text/get_array/get_map) before applying -- matching how
-- every test in this codebase already establishes its roots before
-- exchanging updates; auto-vivifying an unknown name isn't attempted since
-- the wire format carries no type-name for it (real yjs's own `doc.get(name)`
-- without a constructor creates a type-less AbstractType, a laxer model
-- this codebase's SharedType -- which always carries a concrete
-- `type_name` -- doesn't have an equivalent for).

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local encoding = require("lib.y_crdt.encoding")
local content = require("lib.y_crdt.content")
local id = require("lib.y_crdt.id")
local item = require("lib.y_crdt.item")
local gc = require("lib.y_crdt.gc")
local skip = require("lib.y_crdt.skip")
local struct_store = require("lib.y_crdt.struct_store")
local integrate = require("lib.y_crdt.integrate")
local json = require("lib.format.json")

local M = {}

-- Neither is self-referential, so `typeof` captures both exactly (see
-- struct_store.lua's `StructStore` for the same reasoning).
local sample_encoder = encoding.encoder()
--:: EncoderState = typeof sample_encoder
local sample_decoder = encoding.decoder("")
--:: DecoderState = typeof sample_decoder

--:: Id = { client: integer, clock: integer }

-- Mirrors item.lua's Item/SharedType/ParentPendingId shapes structurally
-- (see item.lua for why these are hand-restated rather than `typeof`-
-- captured: recursive self-reference loses precision under `typeof`).
--:: SharedType = { kind: "shared_type", type_name: string, start: Item | nil, map: { [string]: Item }, length: number, item: Item | nil }
--:: ParentPendingId = { kind: "pending_parent_id", client: integer, clock: integer }
--:: Content = { kind: "deleted", ref: integer, len: integer } | { kind: "string", ref: integer, str: string } | { kind: "json", ref: integer, arr: unknown[] } | { kind: "embed", ref: integer, embed: unknown } | { kind: "any", ref: integer, arr: unknown[] } | { kind: "format", ref: integer, key: string, value: unknown } | { kind: "type", ref: integer, shared_type: unknown } | { kind: "doc", ref: integer, guid: string, opts: unknown } | { kind: "binary", ref: integer, bytes: string }
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
--:: Gc = { kind: "gc", id: Id, length: integer, deleted: true }
--:: Skip = { kind: "skip", id: Id, length: integer, deleted: false }
--:: Struct = Item | Gc | Skip

--:: StructStore = { clients: { [number]: Struct[] } }
--:: SharedTypeShare = { [string]: SharedType }
--:: Doc = { client_id: number, store: StructStore, share: SharedTypeShare, clock: number }
--:: Transaction = { doc: Doc, new_items: Item[], deleted_items: Item[] }

--:: StateVector = { [number]: integer }

--------------------------------------------------------------------------
-- Content type refs (yjs structs/Item.js `contentRefs`) and ContentType's
-- nested type refs (yjs structs/ContentType.js).
--------------------------------------------------------------------------

local REF_DELETED = 1
local REF_JSON = 2
local REF_BINARY = 3
local REF_STRING = 4
local REF_EMBED = 5
local REF_FORMAT = 6
local REF_TYPE = 7
local REF_ANY = 8
local REF_DOC = 9
local STRUCT_GC = 0
local STRUCT_SKIP = 10

local TYPE_REF_ARRAY = 0
local TYPE_REF_MAP = 1
local TYPE_REF_TEXT = 2

local TYPE_NAME_TO_REF = { array = TYPE_REF_ARRAY, map = TYPE_REF_MAP, text = TYPE_REF_TEXT }
local TYPE_REF_TO_NAME = { [0] = "array", [1] = "map", [2] = "text" }

--------------------------------------------------------------------------
-- Content write/read
--------------------------------------------------------------------------

-- JSON-content helpers: `arr`/`embed`/format `value` fields carry
-- application values that yjs serializes via `JSON.stringify`/`JSON.parse`
-- (NOT lib0's `writeAny`/`readAny` binary tags -- that's ContentAny's own,
-- separate encoding). `encoding.null` is reused as the null sentinel across
-- both codecs so a caller sees one identity for "wire null" throughout
-- y_crdt, per this module's header note on the null/undefined collapse.
--: (v: unknown) -> (string | nil, string | nil)
local function json_stringify(v)
  return json.encode(v, encoding.null)
end

--: (s: string) -> (unknown, string | nil)
local function json_parse(s)
  return json.decode(s, encoding.null)
end

--: (enc: EncoderState, c: Content) -> (true | nil, string | nil)
local function write_item_content(enc, c)
  if c.kind == "deleted" then
    enc:write_var_uint(c.len)
    return true
  elseif c.kind == "json" then
    local arr = c.arr
    enc:write_var_uint(#arr)
    for i = 1, #arr do
      local v = arr[i]
      local s, err = json_stringify(v)
      if s == nil then return nil, "update: json content element " .. i .. " failed to encode: " .. tostring(err) end
      enc:write_var_string(s)
    end
    return true
  elseif c.kind == "binary" then
    enc:write_var_buffer(c.bytes)
    return true
  elseif c.kind == "string" then
    enc:write_var_string(c.str)
    return true
  elseif c.kind == "embed" then
    local s, err = json_stringify(c.embed)
    if s == nil then return nil, "update: embed content failed to encode: " .. tostring(err) end
    enc:write_var_string(s)
    return true
  elseif c.kind == "format" then
    enc:write_var_string(c.key)
    local s, err = json_stringify(c.value)
    if s == nil then return nil, "update: format content value failed to encode: " .. tostring(err) end
    enc:write_var_string(s)
    return true
  elseif c.kind == "type" then
    -- content.lua's ContentType.shared_type is declared `unknown`
    -- specifically to avoid a content.lua <-> shared_type.lua require()
    -- cycle (see content.lua's `M.type` doc comment); this is the trust
    -- boundary where it's narrowed back to a concrete SharedType.
    --
    -- TYPECHECKER WORKAROUND: a plain checked cast (`--[[: SharedType]]`)
    -- straight off `c.shared_type` is rejected outright ("value of type
    -- unknown must be narrowed before use"), and stays rejected even after
    -- a `type(c.shared_type) == "table"` runtime guard -- unlike the
    -- otherwise-identical guard on a bare local holding the same value
    -- (`local raw = c.shared_type; if type(raw) == "table" then ...`),
    -- which does narrow correctly. Confirmed by minimal repro: the guard
    -- has to run against a local, not a repeated field read, for `unknown`
    -- to narrow at all here -- a stricter version of the field-read-
    -- narrowing bug documented elsewhere in this library. The natural code
    -- would guard `c.shared_type` directly with no intermediate local.
    -- TODO.md tracks removing `raw` once this narrows upstream.
    local raw = c.shared_type
    if type(raw) ~= "table" then
      return nil, "update: nested shared type content is not a table"
    end
    local st = raw --[[: { kind: unknown, type_name: unknown } ]]
    local type_name = st.type_name
    if st.kind ~= "shared_type" or type(type_name) ~= "string" then
      return nil, "update: nested shared type content is not a valid SharedType"
    end
    local type_ref = TYPE_NAME_TO_REF[type_name]
    if type_ref == nil then
      return nil, "update: nested shared type '" .. type_name .. "' has no wire type ref (only array/map/text are supported)"
    end
    enc:write_var_uint(type_ref)
    return true
  elseif c.kind == "any" then
    local arr = c.arr
    enc:write_var_uint(#arr)
    for i = 1, #arr do
      local ok, err = enc:write_any(arr[i])
      if not ok then return nil, "update: any content element " .. i .. " failed to encode: " .. tostring(err) end
    end
    return true
  else
    -- c.kind == "doc"
    enc:write_var_string(c.guid)
    local ok, err = enc:write_any(c.opts)
    if not ok then return nil, "update: doc content opts failed to encode: " .. tostring(err) end
    return true
  end
end

--: (dec: DecoderState, content_ref: integer) -> (Content | nil, string | nil)
local function read_item_content(dec, content_ref)
  if content_ref == REF_DELETED then
    local len, err = dec:read_var_uint()
    if len == nil then return nil, err end
    return content.deleted(len)
  elseif content_ref == REF_JSON then
    local len, err = dec:read_var_uint()
    if len == nil then return nil, err end
    local arr = {} --[[: unknown[] ]]
    for i = 1, len do
      local s, serr = dec:read_var_string()
      if s == nil then return nil, serr end
      if s == "undefined" then
        arr[i] = encoding.null
      else
        local v, verr = json_parse(s)
        if v == nil and verr ~= nil then return nil, "update: json content element " .. i .. " failed to decode: " .. verr end
        arr[i] = v
      end
    end
    return content.json(arr)
  elseif content_ref == REF_BINARY then
    local bytes, err = dec:read_var_buffer()
    if bytes == nil then return nil, err end
    return content.binary(bytes)
  elseif content_ref == REF_STRING then
    local str, err = dec:read_var_string()
    if str == nil then return nil, err end
    return content.string(str)
  elseif content_ref == REF_EMBED then
    local s, err = dec:read_var_string()
    if s == nil then return nil, err end
    local v, verr = json_parse(s)
    if v == nil and verr ~= nil then return nil, "update: embed content failed to decode: " .. verr end
    return content.embed(v)
  elseif content_ref == REF_FORMAT then
    local key, kerr = dec:read_var_string()
    if key == nil then return nil, kerr end
    local s, serr = dec:read_var_string()
    if s == nil then return nil, serr end
    local v, verr = json_parse(s)
    if v == nil and verr ~= nil then return nil, "update: format content value failed to decode: " .. verr end
    return content.format(key, v)
  elseif content_ref == REF_TYPE then
    local type_ref, err = dec:read_var_uint()
    if type_ref == nil then return nil, err end
    local type_name = TYPE_REF_TO_NAME[type_ref]
    if type_name == nil then
      return nil, "update: nested shared type ref " .. type_ref .. " is not supported (only array/map/text -- no XML types)"
    end
    local shared_type = require("lib.y_crdt.shared_type")
    return content.type(shared_type.new(type_name))
  elseif content_ref == REF_ANY then
    local len, lerr = dec:read_var_uint()
    if len == nil then return nil, lerr end
    local arr = {} --[[: unknown[] ]]
    for i = 1, len do
      local v, verr = dec:read_any()
      if v == nil and verr ~= nil then return nil, "update: any content element " .. i .. " failed to decode: " .. verr end
      arr[i] = v
    end
    return content.any(arr)
  elseif content_ref == REF_DOC then
    local guid, gerr = dec:read_var_string()
    if guid == nil then return nil, gerr end
    local opts, operr = dec:read_any()
    if opts == nil and operr ~= nil then return nil, "update: doc content opts failed to decode: " .. operr end
    return content.doc(guid, opts)
  else
    return nil, "update: unknown content ref " .. tostring(content_ref)
  end
end

--------------------------------------------------------------------------
-- Struct write
--------------------------------------------------------------------------

--: (enc: EncoderState, iid: Id) -> nil
local function write_id(enc, iid)
  enc:write_var_uint(iid.client)
  enc:write_var_uint(iid.clock)
end

--: (dec: DecoderState) -> (Id | nil, string | nil)
local function read_id(dec)
  local client, cerr = dec:read_var_uint()
  if client == nil then return nil, cerr end
  local clock, kerr = dec:read_var_uint()
  if clock == nil then return nil, kerr end
  return id.new(client, clock)
end

-- Writes one Item, matching yjs `Item.prototype.write` exactly: info-byte
-- bit layout, then origin/origin_right ids, then (only when both are
-- absent) parent info, then (only in that same case) parent_sub, then
-- content. `offset` supports writing a struct starting partway through
-- (used by `encode_diff_v1` when a state vector lands mid-struct);
-- `doc` resolves a root-level parent to the share-map key that names it.
--: (enc: EncoderState, it: Item, offset: integer, doc: Doc) -> (true | nil, string | nil)
local function write_item(enc, it, offset, doc)
  -- TYPECHECKER WORKAROUND: `it.origin`/`it.origin_right`/`it.parent_sub`
  -- are captured into locals here (rather than read again below, guarded
  -- only by the `has_origin`/`has_origin_right`/`has_parent_sub` booleans
  -- computed from them) because a boolean flag derived from a nil-check
  -- doesn't narrow the original field's nil-ness back at the point of use
  -- -- confirmed by minimal repro; the field has to be captured into its
  -- own local and checked again right where it's used. The natural code
  -- would just read `it.origin` etc. directly at each use. TODO.md tracks
  -- collapsing this once that narrows upstream.
  local origin0 = it.origin
  local origin_right0 = it.origin_right
  local parent_sub0 = it.parent_sub
  local has_origin = offset > 0 or origin0 ~= nil
  local has_origin_right = origin_right0 ~= nil
  local has_parent_sub = parent_sub0 ~= nil
  local info = (it.content.ref) + (has_origin and 0x80 or 0) + (has_origin_right and 0x40 or 0) + (has_parent_sub and 0x20 or 0)
  enc:write_uint8(info)

  if has_origin then
    if offset > 0 then
      write_id(enc, id.new(it.id.client, it.id.clock + offset - 1))
    elseif origin0 ~= nil then
      write_id(enc, origin0)
    else
      return nil, "update: internal invariant: has_origin true but origin is nil"
    end
  end
  if has_origin_right then
    if origin_right0 == nil then
      return nil, "update: internal invariant: has_origin_right true but origin_right is nil"
    end
    write_id(enc, origin_right0)
  end

  if not has_origin and not has_origin_right then
    local parent0 = it.parent
    if parent0 == nil then
      return nil, "update: cannot encode an item with no parent and no origin/origin_right"
    end
    if parent0.kind == "pending_parent_id" then
      return nil, "update: cannot encode an item whose parent is an unresolved pending id"
    end
    local st = parent0
    local root_name --[[: string | nil]]
    for name, shared in pairs(doc.share) do
      if shared == st then root_name = name end
    end
    if root_name ~= nil then
      enc:write_var_uint(1)
      enc:write_var_string(root_name)
    else
      local parent_item = st.item
      if parent_item == nil then
        return nil, "update: nested shared type parent has no owning item and is not a root type"
      end
      enc:write_var_uint(0)
      write_id(enc, parent_item.id)
    end
    if has_parent_sub then
      if parent_sub0 == nil then
        return nil, "update: internal invariant: has_parent_sub true but parent_sub is nil"
      end
      enc:write_var_string(parent_sub0)
    end
  end

  local c = it.content
  if offset > 0 then
    local spliced, err = content.splice(c, offset)
    if spliced == nil then return nil, "update: failed to splice content at offset: " .. tostring(err) end
    -- `content.splice` mutates `c` in place to hold the left part and
    -- returns the right part; the right part (offset onward) is what gets
    -- written here, matching yjs's `this.content.write(encoder, offset,
    -- offsetEnd)`. `c` itself (the original struct in the store) is left
    -- mutated to its left part as a side effect of calling splice at all --
    -- acceptable here because `encode_diff_v1`/`encode_v1` already used
    -- `struct_store.get_item_clean_start`-style physical splitting to
    -- avoid ever needing this path in practice (see their own callers);
    -- this fallback exists for completeness, not the primary code path.
    return write_item_content(enc, spliced)
  end
  return write_item_content(enc, c)
end

--: (enc: EncoderState, s: Struct, offset: integer, doc: Doc) -> (true | nil, string | nil)
local function write_struct(enc, s, offset, doc)
  if s.kind == "gc" then
    enc:write_uint8(STRUCT_GC)
    enc:write_var_uint(s.length - offset)
    return true
  elseif s.kind == "skip" then
    enc:write_uint8(STRUCT_SKIP)
    enc:write_var_uint(s.length - offset)
    return true
  else
    return write_item(enc, s, offset, doc)
  end
end

--------------------------------------------------------------------------
-- Struct read
--------------------------------------------------------------------------

-- Reads one struct. `doc` resolves a root-type parent reference
-- (`doc.share[name]`) immediately -- unlike a parent-by-item-id reference
-- (ParentPendingId), which integrate.lua resolves later (that item may not
-- be integrated yet when this runs; a root type is always pre-established
-- by the caller, per this module's header note on that precondition).
--: (dec: DecoderState, client: integer, clock: integer, doc: Doc) -> (Struct | nil, string | nil)
local function read_struct(dec, client, clock, doc)
  local info, ierr = dec:read_uint8()
  if info == nil then return nil, ierr end
  local kind_bits = info % 32 -- lib0 BITS5 = 0x1F

  if kind_bits == STRUCT_GC then
    local len, err = dec:read_var_uint()
    if len == nil then return nil, err end
    return gc.new(id.new(client, clock), len)
  elseif kind_bits == STRUCT_SKIP then
    local len, err = dec:read_var_uint()
    if len == nil then return nil, err end
    return skip.new(id.new(client, clock), len)
  end

  local has_origin = (info % 256 - info % 128) ~= 0 -- bit 0x80
  local has_origin_right = (info % 128 - info % 64) ~= 0 -- bit 0x40
  local has_parent_sub = (info % 64 - info % 32) ~= 0 -- bit 0x20

  local origin --[[: Id | nil]]
  if has_origin then
    local oid, err = read_id(dec)
    if oid == nil then return nil, err end
    origin = oid
  end
  local origin_right --[[: Id | nil]]
  if has_origin_right then
    local oid, err = read_id(dec)
    if oid == nil then return nil, err end
    origin_right = oid
  end

  local parent --[[: SharedType | ParentPendingId | nil]]
  local parent_sub --[[: string | nil]]
  if not has_origin and not has_origin_right then
    local is_y_key, perr = dec:read_var_uint()
    if is_y_key == nil then return nil, perr end
    if is_y_key == 1 then
      local name, nerr = dec:read_var_string()
      if name == nil then return nil, nerr end
      local root = doc.share[name]
      if root == nil then
        return nil, "update: item's parent names root type '" .. name .. "', which the target doc has not declared (call doc.get_text/get_array/get_map for it before applying)"
      end
      parent = root
    else
      local pid, ierr2 = read_id(dec)
      if pid == nil then return nil, ierr2 end
      parent = { kind = "pending_parent_id", client = pid.client, clock = pid.clock } --[[: ParentPendingId]]
    end
    if has_parent_sub then
      local sub, serr = dec:read_var_string()
      if sub == nil then return nil, serr end
      parent_sub = sub
    end
  end

  local c, cerr = read_item_content(dec, kind_bits)
  if c == nil then return nil, cerr end

  return item.new(id.new(client, clock), origin, origin_right, parent, parent_sub, c)
end

--------------------------------------------------------------------------
-- Section 1: structs
--------------------------------------------------------------------------

--: (enc: EncoderState, client: integer, structs: Struct[], start_index: integer, start_clock: integer, doc: Doc) -> (true | nil, string | nil)
local function write_client_structs(enc, client, structs, start_index, start_clock, doc)
  enc:write_var_uint(#structs - start_index + 1)
  enc:write_var_uint(client)
  enc:write_var_uint(start_clock)
  local first = structs[start_index]
  
  local ok, err = write_struct(enc, first, start_clock - first.id.clock, doc)
  if not ok then return nil, err end
  for idx = start_index + 1, #structs do
    local ok2, err2 = write_struct(enc, structs[idx], 0, doc)
    if not ok2 then return nil, err2 end
  end
  return true
end

--: (dec: DecoderState, doc: Doc) -> ({ [number]: Struct[] } | nil, string | nil)
local function read_structs_section(dec, doc)
  local num_clients, err = dec:read_var_uint()
  if num_clients == nil then return nil, err end
  local by_client = {} --[[: { [number]: Struct[] } ]]
  for _ = 1, num_clients do
    local num_structs, nerr = dec:read_var_uint()
    if num_structs == nil then return nil, nerr end
    local client, cerr = dec:read_var_uint()
    if client == nil then return nil, cerr end
    local clock, kerr = dec:read_var_uint()
    if clock == nil then return nil, kerr end
    local list = {} --[[: Struct[] ]]
    for i = 1, num_structs do
      local s, serr = read_struct(dec, client, clock, doc)
      if s == nil then return nil, serr end
      
      clock = clock + s.length
      list[i] = s
    end
    by_client[client] = list
  end
  return by_client
end

--------------------------------------------------------------------------
-- Section 2: delete set
--------------------------------------------------------------------------

--:: DeleteRange = { clock: integer, len: integer }

-- TYPECHECKER WORKAROUND: `T[]` sugar in a `--::`/`--:` annotation
-- desugars to an index signature (`{ [number]: T }`), NOT the `{ [integer]:
-- T }` shape `table.sort`'s stdlib declaration expects, and a value
-- retrieved by indexing (or `pairs`-iterating the values of) a table whose
-- declared type uses that sugar carries the same incompatibility onward,
-- even once copied into a fresh local -- confirmed by minimal repro. The
-- one shape that reliably sorts AND keeps its field types afterward is a
-- single flat array built directly from a clean, non-index-signature
-- source (here, straight off the `deleted_items: Item[]` parameter) and
-- sorted before any map grouping happens -- so this sorts one flat
-- `{client, clock, len}` list first, then groups it into the by-client map
-- afterward (never reading the map's own values before writing them, which
-- is what re-triggers the bug). The natural code would sort each client's
-- list directly. TODO.md tracks collapsing this once `T[]` sugar and
-- `table.sort`'s expected shape agree.
--: (deleted_items: Item[]) -> { [number]: DeleteRange[] }
local function delete_set_from_items(deleted_items)
  local flat = {}
  for _, it in ipairs(deleted_items) do
    flat[#flat + 1] = { client = it.id.client, clock = it.id.clock, len = it.length }
  end
  -- Manual insertion sort, not `table.sort` -- see write_delete_set's
  -- comment (further below) on why.
  for i = 2, #flat do
    local key = flat[i]
    local j = i - 1
    while j >= 1 and (flat[j].client > key.client or (flat[j].client == key.client and flat[j].clock > key.clock)) do
      flat[j + 1] = flat[j]
      j = j - 1
    end
    flat[j + 1] = key
  end
  local by_client = {} --[[: { [number]: DeleteRange[] } ]]
  for _, e in ipairs(flat) do
    local list = by_client[e.client]
    if list == nil then
      list = {}
      by_client[e.client] = list
    end
    local last = list[#list]
    if last ~= nil and last.clock + last.len >= e.clock then
      local range_end = e.clock + e.len
      local last_end = last.clock + last.len
      if range_end > last_end then last.len = range_end - last.clock end
    else
      list[#list + 1] = { clock = e.clock, len = e.len }
    end
  end
  return by_client
end

--: (store: StructStore) -> { [number]: DeleteRange[] }
local function delete_set_from_store(store)
  local by_client = {} --[[: { [number]: DeleteRange[] } ]]
  for client, structs in pairs(store.clients) do
    local merged = {} --[[: { clock: integer, len: integer }[] ]]
    local i = 1
    local n = #structs
    while i <= n do
      local s = structs[i]
      if s.deleted then
        local clock = s.id.clock
        local len = s.length
        local j = i + 1
        while j <= n do
          local nxt = structs[j]
          if not nxt.deleted then break end
          len = len + nxt.length
          j = j + 1
        end
        merged[#merged + 1] = { clock = clock, len = len }
        i = j
      else
        i = i + 1
      end
    end
    if #merged > 0 then by_client[client] = merged end
  end
  return by_client
end

--: (enc: EncoderState, ds: { [number]: DeleteRange[] }) -> nil
local function write_delete_set(enc, ds)
  local clients = {}
  for client in pairs(ds) do clients[#clients + 1] = client end
  -- Manual insertion sort, not `table.sort`: its stdlib signature is
  -- generic, and this project's typechecker binds that generic parameter
  -- once and reuses it across unrelated `table.sort` call sites later in
  -- the same file, corrupting their argument types (matches the documented
  -- "table.sort generic V conflict" workaround already established in
  -- lib/type/search/init.lua). Descending, to match yjs's own
  -- higher-client-first convention (cosmetic here -- decode doesn't care
  -- about client order -- but kept for consistency with upstream).
  for i = 2, #clients do
    local key = clients[i]
    local j = i - 1
    while j >= 1 and clients[j] < key do
      clients[j + 1] = clients[j]
      j = j - 1
    end
    clients[j + 1] = key
  end
  enc:write_var_uint(#clients)
  for _, client in ipairs(clients) do
    enc:write_var_uint(math.floor(client))
    local ranges = ds[client]
    enc:write_var_uint(#ranges)
    for _, range in ipairs(ranges) do
      -- V1: clock is written ABSOLUTE, not delta-encoded (confirmed
      -- against yjs `DSEncoderV1.writeDsClock`/`writeDsLen`, both plain
      -- `writeVarUint`; delta-encoding is a V2-only optimization).
      enc:write_var_uint(range.clock)
      enc:write_var_uint(range.len)
    end
  end
end

--: (dec: DecoderState) -> ({ [number]: DeleteRange[] } | nil, string | nil)
local function read_delete_set(dec)
  local num_clients, err = dec:read_var_uint()
  if num_clients == nil then return nil, err end
  local ds = {} --[[: { [number]: DeleteRange[] } ]]
  for _ = 1, num_clients do
    local client, cerr = dec:read_var_uint()
    if client == nil then return nil, cerr end
    local num_ranges, nerr = dec:read_var_uint()
    if num_ranges == nil then return nil, nerr end
    local ranges = {} --[[: { clock: integer, len: integer }[] ]]
    for i = 1, num_ranges do
      local clock, kerr = dec:read_var_uint()
      if clock == nil then return nil, kerr end
      local len, lerr = dec:read_var_uint()
      if len == nil then return nil, lerr end
      ranges[i] = { clock = clock, len = len }
    end
    ds[client] = ranges
  end
  return ds
end

--: (txn: Transaction, store: StructStore, ds: { [number]: DeleteRange[] }) -> (true | nil, string | nil)
local function apply_delete_set(txn, store, ds)
  for client, ranges in pairs(ds) do
    for _, range in ipairs(ranges) do
      local remaining = range.len
      local clock = range.clock
      while remaining > 0 do
        local iid = id.new(math.floor(client), clock)
        local s0, err = struct_store.get_clean_start(store, iid)
        if s0 == nil then return nil, "update: delete set references missing struct: " .. tostring(err) end
        -- CHECKED CAST (not forced): needed even with `get_clean_start`'s
        -- fixed two-optional-returns shape (see struct_store.lua's own
        -- comment there) -- this file's `Struct` union includes the
        -- hand-declared, self-referential `Item`, and reading `s0.length`
        -- for arithmetic (below) without this cast still infers `integer |
        -- nil` indefinitely, matching the recursive-type narrowing
        -- limitation already documented at the top of this file (`Item`/
        -- `SharedType`'s mutual self-reference). The natural code would use
        -- `s0` directly with no cast.
        local s = s0 --[[: Struct]]

        local take = s.length
        if take > remaining then
          -- The covering struct extends past this delete range; split it
          -- so only the in-range portion is affected.
          if s.kind == "item" then
            local split_off, split_err = struct_store.get_item_clean_end(store, id.new(math.floor(client), clock + remaining - 1))
            if split_off == nil then return nil, split_err or "update: failed to split item at delete range boundary" end
          end
          take = remaining
        end
        if s.kind == "item" and not s.deleted then
          item.delete(txn, s)
        end
        -- GC and already-deleted Items need no further action; Skip means
        -- the struct this delete range targets hasn't arrived yet.
        if s.kind == "skip" then
          return nil, "update: delete set references a struct that has not arrived yet (missing dependency)"
        end
        remaining = remaining - take
        clock = clock + take
      end
    end
  end
  return true
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

-- Encodes every struct in `transaction.new_items` (grouped by client, in
-- clock order) plus a delete set built from `transaction.deleted_items`.
-- Relies on struct_store.lua's documented contiguity invariant (a client's
-- structs are always clock-contiguous) to determine each client's starting
-- clock directly from its earliest new item, rather than needing a
-- separately-tracked "state before this transaction" (which
-- transaction.lua doesn't carry -- see its own SCOPE note).
--: (doc: Doc, txn: Transaction) -> (string | nil, string | nil)
function M.encode_v1(doc, txn)
  local by_client = {} --[[: { [number]: Item[] } ]]
  for _, it in ipairs(txn.new_items) do
    local list = by_client[it.id.client]
    if list == nil then
      list = {}
      by_client[it.id.client] = list
    end
    list[#list + 1] = it
  end
  local clients = {}
  for client in pairs(by_client) do clients[#clients + 1] = client end
  -- Manual insertion sort throughout this module -- see write_delete_set's
  -- comment on why `table.sort` isn't used.
  for i = 2, #clients do
    local key = clients[i]
    local j = i - 1
    while j >= 1 and clients[j] > key do
      clients[j + 1] = clients[j]
      j = j - 1
    end
    clients[j + 1] = key
  end

  local enc = encoding.encoder()
  enc:write_var_uint(#clients)
  for _, client in ipairs(clients) do
    local items = by_client[client]
    for i = 2, #items do
      local key = items[i]
      local j = i - 1
      while j >= 1 and items[j].id.clock > key.id.clock do
        items[j + 1] = items[j]
        j = j - 1
      end
      items[j + 1] = key
    end
    local start_clock = items[1].id.clock
    enc:write_var_uint(#items)
    enc:write_var_uint(math.floor(client))
    enc:write_var_uint(start_clock)
    for _, it in ipairs(items) do
      local ok, err = write_item(enc, it, 0, doc)
      if not ok then return nil, err end
    end
  end

  local ds = delete_set_from_items(txn.deleted_items)
  write_delete_set(enc, ds)
  return enc:to_string()
end

-- Encodes an update containing everything a peer whose state vector is
-- `sv_bytes` is missing, plus the full delete set derived from `doc`'s
-- struct store (matches yjs `encodeStateAsUpdate`'s use of
-- `createDeleteSetFromStructStore`, distinct from `encode_v1`'s
-- transaction-local delete set).
--: (doc: Doc, sv_bytes: string) -> (string | nil, string | nil)
function M.encode_diff_v1(doc, sv_bytes)
  local sv, sverr = M.decode_state_vector(sv_bytes)
  if sv == nil then return nil, sverr end

  local store = doc.store
  local clients = {} --[[: integer[] ]]
  for client in pairs(store.clients) do
    local their_clock = sv[client] or 0
    if struct_store.get_state(store, client) > their_clock then
      clients[#clients + 1] = math.floor(client)
    end
  end
  for i = 2, #clients do
    local key = clients[i]
    local j = i - 1
    while j >= 1 and clients[j] < key do
      clients[j + 1] = clients[j]
      j = j - 1
    end
    clients[j + 1] = key
  end

  local enc = encoding.encoder()
  enc:write_var_uint(#clients)
  for _, client in ipairs(clients) do
    local their_clock = sv[client] or 0
    local structs = store.clients[client]
    -- Physically split at `their_clock` first (if it falls inside an Item)
    -- so the write loop below never needs an "offset write" -- matches the
    -- wire-visible result of yjs's `firstStruct.write(encoder, offset)`
    -- without needing to special-case a mid-struct write here. GC ranges
    -- don't need a physical split (GC.write already supports an offset
    -- with no content to splice); Skip should never be the covering struct
    -- for a clock this client has already told us about via its own state
    -- vector.
    if their_clock > 0 then
      local covering, cerr = struct_store.get_clean_start(store, id.new(client, their_clock))
      if covering == nil then return nil, cerr or "update: failed to resolve diff start boundary" end
    end
    local start_index = struct_store._find_index(structs, their_clock)
    local ok, err = write_client_structs(enc, client, structs, start_index, their_clock, doc)
    if not ok then return nil, err end
  end

  local ds = delete_set_from_store(store)
  write_delete_set(enc, ds)
  return enc:to_string()
end

-- Applies a decoded update to `doc`: integrates every struct (in
-- client-then-clock order) via integrate.lua, then applies the delete set.
-- Returns the Transaction (so the caller can inspect new_items/
-- deleted_items) on success.
--: (doc: Doc, bytes: string) -> (Transaction | nil, string | nil)
function M.apply_v1(doc, bytes)
  local dec = encoding.decoder(bytes)
  local by_client, serr = read_structs_section(dec, doc)
  if by_client == nil then return nil, serr end
  local ds, dserr = read_delete_set(dec)
  if ds == nil then return nil, dserr end

  -- Built as a literal (not `transaction.new(doc)`) because transaction.lua
  -- declares its own `Transaction.doc` as `unknown` (it can't reference this
  -- module's richer `Doc` shape without a require() cycle -- same reasoning
  -- as struct_store_test.lua's `new_parent`/`new_txn` helpers, which build
  -- SharedType/Transaction literals directly for the same cross-module
  -- reason). Runtime-identical to `transaction.new(doc)`.
  local txn = { doc = doc, new_items = {}, deleted_items = {} } --[[: Transaction]]
  local clients = {} --[[: integer[] ]]
  for client in pairs(by_client) do clients[#clients + 1] = math.floor(client) end
  for i = 2, #clients do
    local key = clients[i]
    local j = i - 1
    while j >= 1 and clients[j] > key do
      clients[j + 1] = clients[j]
      j = j - 1
    end
    clients[j + 1] = key
  end

  -- Structs from different clients in the same update can reference each
  -- other (an item's origin/origin_right/parent-id may point at a struct
  -- from another client listed later in the wire encoding), so a single
  -- linear per-client pass isn't guaranteed to integrate everything in
  -- dependency order. This worklist retries structs that fail with a
  -- "missing dependency"-shaped error until no more progress is made --
  -- equivalent in effect to yjs's stack-based resumable `integrateStructs`
  -- for the case where every dependency is present *somewhere* in this
  -- update or the target doc (this module's documented SCOPE cut: no
  -- cross-update/streaming resumption).
  local pending = {} --[[: { s: Struct, client: number }[] ]]
  for _, client in ipairs(clients) do
    for _, s in ipairs(by_client[client]) do
      pending[#pending + 1] = { s = s, client = client }
    end
  end

  while #pending > 0 do
    local next_pending = {} --[[: { s: Struct, client: number }[] ]]
    local progressed = false
    local last_err = "update: no structs to integrate" --[[: string]]
    for _, entry in ipairs(pending) do
      -- TYPECHECKER WORKAROUND: `entry.s` (a field read off an element of
      -- an `--::`-annotated array) needs a fresh checked-cast local before
      -- `.kind`-narrowing works for the rest of this block -- same
      -- field-read-narrowing-loss class of bug documented elsewhere in
      -- this library (item.lua's `identity_parent`, etc.), just triggered
      -- by array-element access here instead of a bare field. The natural
      -- code would use `entry.s` directly with no intermediate local.
      -- TODO.md tracks removing this once that's fixed upstream.
      local s = entry.s --[[: Struct]]
      local ok, err
      if s.kind == "gc" then
        ok, err = struct_store.add(doc.store, s)
      elseif s.kind == "skip" then
        ok, err = struct_store.add(doc.store, s)
      elseif s.kind == "item" then
        -- CHECKED CAST (not forced): `txn`'s declared `Transaction.doc` is
        -- this module's own richer `Doc` (with `client_id`/`clock`
        -- fields), but integrate.lua's own `Transaction.doc` alias only
        -- needs `{ store: StructStore }` and rejects the extra fields as
        -- excess on the literal -- narrowing the view down to exactly what
        -- integrate.lua expects at this one call boundary.
        local txn_for_integrate = { doc = { store = doc.store }, new_items = txn.new_items, deleted_items = txn.deleted_items }
        ok, err = integrate.integrate(txn_for_integrate, s)
      else
        ok, err = nil, "update: internal invariant: struct kind is neither gc, skip, nor item"
      end
      if ok then
        progressed = true
      else
        -- TYPECHECKER WORKAROUND: `err` (declared via `local ok, err`
        -- with no initializer, then assigned across 4 sibling branches)
        -- never narrows to plain `string` here even behind an explicit
        -- `err ~= nil` guard -- the same class of cross-branch narrowing
        -- loss documented throughout this session, just resistant to
        -- every fix tried (fresh locals, checked casts, sequential
        -- guards). `tostring` sidesteps needing `err: string` at all --
        -- `last_err` is a display message, so degrading a genuinely-nil
        -- `err` to the literal text "nil" is an acceptable fallback, not
        -- a correctness loss. TODO.md tracks reverting to `last_err =
        -- err` once this narrows upstream.
        last_err = tostring(err)
        next_pending[#next_pending + 1] = entry
      end
    end
    if not progressed then
      return nil, "update: could not apply all structs (" .. #next_pending .. " remaining): " .. last_err
    end
    pending = next_pending
  end

  local ok, err = apply_delete_set(txn, doc.store, ds)
  if not ok then return nil, err end

  return txn
end

-- BUG FIX (found via lib/y_crdt/parity_test.lua against real yjs fixtures):
-- client order was previously sorted ASCENDING. Verified against upstream
-- (`node_modules/yjs/dist/yjs.cjs`'s `writeStateVector`:
-- `array.from(sv.entries()).sort((a, b) => b[0] - a[0])`, fetched from the
-- fixtures/ yjs install, 2026-07-27) -- it sorts DESCENDING by client id.
-- Decoding is order-independent (read_delete_set/decode_state_vector just
-- read whatever order is given), so this had no effect on correctness, only
-- on byte-for-byte comparison against real yjs output.
--: (sv: StateVector) -> string
function M.encode_state_vector_from_table(sv)
  local enc = encoding.encoder()
  local clients = {} --[[: integer[] ]]
  for client in pairs(sv) do clients[#clients + 1] = math.floor(client) end
  for i = 2, #clients do
    local key = clients[i]
    local j = i - 1
    while j >= 1 and clients[j] < key do
      clients[j + 1] = clients[j]
      j = j - 1
    end
    clients[j + 1] = key
  end
  enc:write_var_uint(#clients)
  for _, client in ipairs(clients) do
    enc:write_var_uint(client)
    enc:write_var_uint(sv[client])
  end
  return enc:to_string()
end

--: (doc: Doc) -> string
function M.encode_state_vector(doc)
  return M.encode_state_vector_from_table(struct_store.get_state_vector(doc.store))
end

--: (bytes: string) -> (StateVector | nil, string | nil)
function M.decode_state_vector(bytes)
  local dec = encoding.decoder(bytes)
  local num_clients, err = dec:read_var_uint()
  if num_clients == nil then return nil, err end
  local sv = {} --[[: StateVector ]]
  for _ = 1, num_clients do
    local client, cerr = dec:read_var_uint()
    if client == nil then return nil, cerr end
    local clock, kerr = dec:read_var_uint()
    if clock == nil then return nil, kerr end
    sv[client] = clock
  end
  return sv
end

-- Merges multiple update payloads into a single doc's struct store (a
-- fresh, throwaway Doc with no root types of its own -- callers merging
-- updates typically don't need parent/root resolution to succeed for
-- structs whose parents live in the real target doc's `share`; that
-- resolution still happens correctly at `apply_v1` time against the real
-- doc), then re-encodes a full update from the result.
--
-- `roots`, if given, pre-declares root-level shared types on the scratch
-- doc (`{ [name] = "text" | "array" | "map", ... }`) before any update is
-- applied. This is required whenever the merged updates contain items
-- parented directly to a root by name: the wire format's root-parent
-- reference carries only the name, never its type (see this module's
-- header note), so a real target doc resolves it by having already called
-- doc.get_text/get_array/get_map for that name -- the scratch doc used
-- here has no such caller-established context of its own, so one must be
-- supplied explicitly for those references to resolve.
--: (updates: string[], roots: { [string]: string } | nil) -> (string | nil, string | nil)
function M.merge_updates_v1(updates, roots)
  local doc_mod = require("lib.y_crdt.doc")
  local scratch = doc_mod.new({ client_id = 0 })
  if roots ~= nil then
    for name, type_name in pairs(roots) do
      local ok, err = pcall(function()
        if type_name == "text" then doc_mod.get_text(scratch, name)
        elseif type_name == "array" then doc_mod.get_array(scratch, name)
        elseif type_name == "map" then doc_mod.get_map(scratch, name)
        else error("update: merge_updates_v1: unknown root type '" .. type_name .. "' for '" .. name .. "'") end
      end)
      if not ok then return nil, tostring(err) end
    end
  end
  for _, bytes in ipairs(updates) do
    local txn, err = M.apply_v1(scratch, bytes)
    if txn == nil then return nil, err end
  end
  local full_txn = { doc = scratch, new_items = {}, deleted_items = {} } --[[: Transaction]]
  for _, structs in pairs(scratch.store.clients) do
    for _, s in ipairs(structs) do
      if s.kind == "item" then
        full_txn.new_items[#full_txn.new_items + 1] = s
      end
    end
  end
  local ds = delete_set_from_store(scratch.store)
  local enc = encoding.encoder()
  local by_client = {} --[[: { [number]: Item[] } ]]
  for _, it in ipairs(full_txn.new_items) do
    local list = by_client[it.id.client]
    if list == nil then
      list = {}
      by_client[it.id.client] = list
    end
    list[#list + 1] = it
  end
  local clients = {}
  for client in pairs(by_client) do clients[#clients + 1] = client end
  for i = 2, #clients do
    local key = clients[i]
    local j = i - 1
    while j >= 1 and clients[j] > key do
      clients[j + 1] = clients[j]
      j = j - 1
    end
    clients[j + 1] = key
  end
  enc:write_var_uint(#clients)
  for _, client in ipairs(clients) do
    local items = by_client[client]
    for i = 2, #items do
      local key = items[i]
      local j = i - 1
      while j >= 1 and items[j].id.clock > key.id.clock do
        items[j + 1] = items[j]
        j = j - 1
      end
      items[j + 1] = key
    end
    enc:write_var_uint(#items)
    enc:write_var_uint(math.floor(client))
    enc:write_var_uint(items[1].id.clock)
    for _, it in ipairs(items) do
      local ok, werr = write_item(enc, it, 0, scratch)
      if not ok then return nil, werr end
    end
  end
  write_delete_set(enc, ds)
  return enc:to_string()
end

return M
