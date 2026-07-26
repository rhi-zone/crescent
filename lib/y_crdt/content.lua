if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Item content payloads. Mirrors yjs's AbstractContent hierarchy
-- (ContentDeleted/ContentString/ContentJSON/ContentAny/ContentType/
-- ContentFormat/ContentDoc/ContentBinary): every Item wraps exactly one of
-- these, as a discriminated union tagged by `kind` (a literal-string
-- discriminant, so the typechecker can narrow `c.len`/`c.str`/`c.arr`/...
-- from `if c.kind == "..." then` per docs/typechecker-reference.md's
-- field-discriminant narrowing).
--
-- `ref` mirrors yjs's numeric content-type tag (used on the wire by
-- UpdateEncoder/Decoder) so a future encoding bridge can map kind <-> byte
-- without this module depending on the codec.
--
-- NOTE (scope): string content length/splice here operate on Lua byte
-- strings, not UTF-16 code units. yjs measures ContentString length in
-- UTF-16 code units and guards against splitting surrogate pairs, because JS
-- strings are UTF-16. That is a wire/JS-interop concern for the
-- serialization bridge (lib/y_crdt/encoding.lua, built separately), not a
-- core CRDT-ordering concern -- the YATA algorithm never inspects string
-- contents, only lengths and origins. Recorded here and in TODO.md so the
-- bridge work accounts for the re-indexing it will need to do.

local M = {}

--:: ContentDeleted = { kind: "deleted", ref: integer, len: integer }
--:: ContentString = { kind: "string", ref: integer, str: string }
--:: ContentJson = { kind: "json", ref: integer, arr: unknown[] }
--:: ContentEmbed = { kind: "embed", ref: integer, embed: unknown }
--:: ContentAny = { kind: "any", ref: integer, arr: unknown[] }
--:: ContentFormat = { kind: "format", ref: integer, key: string, value: unknown }
--:: ContentType = { kind: "type", ref: integer, shared_type: unknown }
--:: ContentDoc = { kind: "doc", ref: integer, guid: string, opts: unknown }
--:: ContentBinary = { kind: "binary", ref: integer, bytes: string }
--:: Content = ContentDeleted | ContentString | ContentJson | ContentEmbed | ContentAny | ContentFormat | ContentType | ContentDoc | ContentBinary

-- Numeric wire tags verified against yjs upstream (github.com/yjs/yjs, tag
-- v13.6.31 -- the actual npm `latest` release; the `main` branch is an
-- unreleased 14.0.0-rc rewrite with a different struct architecture and is
-- NOT the wire format anything deployed speaks) -- src/structs/Item.js's
-- `contentRefs` lookup array, cross-checked against each Content*.js's own
-- `getRef()`. Ref 5 (embed) exists on the wire even though this module went
-- without it until lib/y_crdt/update.lua (the wire codec) needed to decode
-- it.
local REF_DELETED = 1
local REF_JSON = 2
local REF_BINARY = 3
local REF_STRING = 4
local REF_EMBED = 5
local REF_FORMAT = 6
local REF_TYPE = 7
local REF_ANY = 8
local REF_DOC = 9

--: (len: integer) -> Content
function M.deleted(len)
  return { kind = "deleted", ref = REF_DELETED, len = len } --[[: Content]]
end

--: (str: string) -> Content
function M.string(str)
  return { kind = "string", ref = REF_STRING, str = str } --[[: Content]]
end

--: (arr: unknown[]) -> Content
function M.json(arr)
  return { kind = "json", ref = REF_JSON, arr = arr } --[[: Content]]
end

-- A single opaque richtext-embed value (yjs ContentEmbed): unlike
-- ContentAny, this holds exactly one value (getLength() == 1 in yjs), not
-- an array -- and unlike ContentJSON's per-element JSON.stringify, yjs
-- writes/reads the whole value in one JSON.stringify/parse round trip
-- (`encoder.writeJSON(this.embed)`).
--: (value: unknown) -> Content
function M.embed(value)
  return { kind = "embed", ref = REF_EMBED, embed = value } --[[: Content]]
end

--: (arr: unknown[]) -> Content
function M.any(arr)
  return { kind = "any", ref = REF_ANY, arr = arr } --[[: Content]]
end

--: (key: string, value: unknown) -> Content
function M.format(key, value)
  return { kind = "format", ref = REF_FORMAT, key = key, value = value } --[[: Content]]
end

-- `shared_type` is the child shared type this Item references (a table
-- produced by lib/y_crdt/shared_type.lua).
--: (shared_type: unknown) -> Content
function M.type(shared_type)
  return { kind = "type", ref = REF_TYPE, shared_type = shared_type } --[[: Content]]
end

--: (guid: string, opts: unknown) -> Content
function M.doc(guid, opts)
  return { kind = "doc", ref = REF_DOC, guid = guid, opts = opts } --[[: Content]]
end

--: (bytes: string) -> Content
function M.binary(bytes)
  return { kind = "binary", ref = REF_BINARY, bytes = bytes } --[[: Content]]
end

--: (c: Content) -> integer
function M.length(c)
  if c.kind == "deleted" then return c.len end
  if c.kind == "string" then return #c.str end
  if c.kind == "json" then return #c.arr end
  if c.kind == "any" then return #c.arr end
  return 1
end

--: (c: Content) -> boolean
function M.is_countable(c)
  if c.kind == "deleted" then return false end
  if c.kind == "format" then return false end
  return true
end

-- Shallow-copies content: matches each yjs Content*'s own `copy()` (arrays
-- get a fresh backing table; other kinds' fields are immutable-by-convention
-- and shared, matching yjs sharing `guid`/`opts`/`key`/`value`/etc. across
-- the copy).
--: (c: Content) -> Content
function M.copy(c)
  if c.kind == "deleted" then return { kind = "deleted", ref = c.ref, len = c.len } end
  if c.kind == "string" then return { kind = "string", ref = c.ref, str = c.str } end
  if c.kind == "json" then
    local copy_arr = {} --[[: unknown[] ]]
    for i, v in ipairs(c.arr) do copy_arr[i] = v end
    return { kind = "json", ref = c.ref, arr = copy_arr }
  end
  if c.kind == "any" then
    local copy_arr = {} --[[: unknown[] ]]
    for i, v in ipairs(c.arr) do copy_arr[i] = v end
    return { kind = "any", ref = c.ref, arr = copy_arr }
  end
  if c.kind == "format" then return { kind = "format", ref = c.ref, key = c.key, value = c.value } end
  if c.kind == "type" then return { kind = "type", ref = c.ref, shared_type = c.shared_type } end
  if c.kind == "doc" then return { kind = "doc", ref = c.ref, guid = c.guid, opts = c.opts } end
  if c.kind == "embed" then return { kind = "embed", ref = c.ref, embed = c.embed } end
  return { kind = "binary", ref = c.ref, bytes = c.bytes }
end

-- Splits content at `offset`, mutating `c` in place to hold the left part
-- and returning a new Content for the right part.
--: (c: Content, offset: integer) -> Content | (nil, string)
function M.splice(c, offset)
  if c.kind == "deleted" then
    local right_len = c.len - offset
    c.len = offset
    return M.deleted(right_len)
  end
  if c.kind == "string" then
    local str = c.str
    local right = M.string(str:sub(offset + 1))
    c.str = str:sub(1, offset)
    return right
  end
  if c.kind == "json" then
    local arr = c.arr
    local right_arr = {} --[[: unknown[] ]]
    for i = offset + 1, #arr do right_arr[#right_arr + 1] = arr[i] end
    for i = #arr, offset + 1, -1 do arr[i] = nil end
    return { kind = "json", ref = c.ref, arr = right_arr } --[[: Content]]
  end
  if c.kind == "any" then
    local arr = c.arr
    local right_arr = {} --[[: unknown[] ]]
    for i = offset + 1, #arr do right_arr[#right_arr + 1] = arr[i] end
    for i = #arr, offset + 1, -1 do arr[i] = nil end
    return { kind = "any", ref = c.ref, arr = right_arr } --[[: Content]]
  end
  -- format / type / doc / binary: matches yjs throwing `methodUnimplemented`
  -- for these kinds' `.splice` -- per library convention this returns
  -- (nil, errmsg) instead of throwing.
  return nil, "content kind '" .. c.kind .. "' cannot be split"
end

-- Merges `right` into `left` in place. Returns whether the merge happened.
--: (left: Content, right: Content) -> boolean
function M.merge_with(left, right)
  if left.kind ~= right.kind then return false end
  if left.kind == "deleted" and right.kind == "deleted" then
    left.len = left.len + right.len
    return true
  end
  if left.kind == "string" and right.kind == "string" then
    left.str = left.str .. right.str
    return true
  end
  if left.kind == "json" and right.kind == "json" then
    for i = 1, #right.arr do left.arr[#left.arr + 1] = right.arr[i] end
    return true
  end
  if left.kind == "any" and right.kind == "any" then
    for i = 1, #right.arr do left.arr[#left.arr + 1] = right.arr[i] end
    return true
  end
  -- format / type / doc / binary never merge (matches yjs `mergeWith`
  -- always returning false for these).
  return false
end

return M
