-- lib/y_crdt/parity_fuzz_test.lua
--
-- Fuzz-parity test: generates random Text/Array/Map operation sequences,
-- performs them in Lua, then shells out to real yjs (via bun +
-- fixtures/verify.js) to perform the identical sequence and compares the
-- two resulting updates.
--
-- Comparison mode used to be chosen per iteration for EVERY kind, because
-- of a real constraint discovered while building lib/y_crdt/parity_test.lua:
-- real yjs's default `gc: true` behavior GC-compacts any deleted item's
-- content down to a bare ContentDeleted placeholder (confirmed against
-- node_modules/yjs/dist/yjs.cjs; verified this happens even across
-- separate transactions, not just same-transaction insert+delete), and its
-- transaction-cleanup pass also merges adjacent same-client mergeable
-- items (`tryToMergeWithLefts`) -- neither was implemented in this port at
-- the time (TODO.md "item compaction"), so a strict byte-for-byte
-- comparison would fail on essentially any sequence containing a
-- delete/overwrite, for a reason already known and accepted, not a genuine
-- bug, which would drown out real finds.
--
-- TEXT no longer needs the weaker mode: item compaction landed, and this
-- port's `cleanupFormattingGap`/`cleanupYTextAfterTransaction` port (see
-- lib/y_crdt/text.lua's header comment) closed the remaining format-marker
-- gaps -- including two found ALONGSIDE that work, wire-visible even
-- without formatting (`find_pos`'s stopping condition not matching yjs's
-- `findPosition` exactly, and `M.insert`'s/`M.format`'s missing
-- `minimizeAttributeChanges`/`insertAttributes` port -- see text.lua for
-- both). Text always uses "bytes" mode now (`run_text_iteration`), verified
-- clean over 800+ fuzz iterations across 8 seeds before this switch.
--
-- ARRAY/MAP still use the two-mode split below -- their own equivalent of
-- text.lua's split-registration fix (a split whose tail never gets folded
-- back into an adjacent structurally-mergeable item because nothing else
-- in that transaction touched the client) is unverified for these two
-- kinds; array.lua's/map.lua's own `find_pos`/delete-split call sites don't
-- register into `txn.merge_structs` the way text.lua's now do. Fixing that
-- is a separate task (TODO.md), not something this text-focused pass
-- covers.
--
--   "bytes" mode   -- exactly ONE insert op against a fresh doc. Nothing
--                     else exists yet for it to merge with or supersede,
--                     so this is guaranteed clean of both known gaps and
--                     checks the full update byte-for-byte.
--   "content" mode -- a richer multi-op sequence that deliberately
--                     includes deletes/overwrites, compared by decoding
--                     both sides' updates and checking the resulting
--                     document CONTENT matches, not raw bytes.
--
-- Every iteration logs which mode it used (in the assertion's own
-- description/failure message) so a failure is unambiguous about what was
-- actually being checked.
--
-- Op tables are a single uniform shape PER KIND (text/array/map), not a
-- tagged union of per-op-kind shapes: every field a kind's ops could ever
-- need is present (nil where unused). This sidesteps a family of
-- table-literal-narrowing gaps already documented elsewhere in this
-- codebase (e.g. lib/y_crdt/update.lua's TYPECHECKER WORKAROUND notes) --
-- appending a `{op="delete", ...}` literal to a list whose inferred
-- element type came from an earlier `{op="insert", ...}` literal is
-- rejected as a type mismatch even though both are meant to be the same
-- open "operation" shape. A single non-union record type has no such
-- literal to narrow from.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local gen = require("lib.test.gen")
local json = require("lib.format.json")
local encoding = require("lib.y_crdt.encoding")
local doc_mod = require("lib.y_crdt.doc")
local text = require("lib.y_crdt.text")
local array = require("lib.y_crdt.array")
local map = require("lib.y_crdt.map")
local update = require("lib.y_crdt.update")

--:: TextOp = { op: string, index: integer, length: integer, text: string, key: string, value: unknown }
--:: ArrayOp = { op: string, index: integer, length: integer, values: { [integer]: unknown } }
--:: MapOp = { op: string, key: string, value: unknown }

local VERIFY_JS = "lib/y_crdt/fixtures/verify.js"

-- Full structural shape for `gen.make_rng`'s return value (mirrors
-- gen.lua's own file-local `Rng` alias, which isn't reachable from here).
-- Every function in this file that takes an `rng` parameter is annotated
-- with this SAME type -- using a narrower ad hoc shape for just one
-- function (e.g. a `{ next: ... }`-only alias for `pick_string`) leaks
-- back and corrupts every OTHER usage of the same `rng` value elsewhere in
-- its call chain: once one call site narrows the parameter's inferred
-- type, later calls like `rng:int(...)` in a sibling function start
-- failing with "field `int` doesn't exist" even though nothing about
-- their own code changed. Confirmed by minimal repro while building this
-- file. `pick` is included in the shape (for completeness/documentation)
-- but never actually CALLED here -- see `pick_string` below for why.
--:: FuzzRng = {
--::   seed: number,
--::   next: (self: FuzzRng) -> number,
--::   float: (self: FuzzRng) -> number,
--::   int: (self: FuzzRng, lo: integer, hi: integer) -> integer,
--::   bool: (self: FuzzRng) -> boolean,
--::   pick: <T>(self: FuzzRng, t: T[]) -> T,
--:: }

-- Non-generic pick, restricted to string lists (every `rng:pick` use in
-- this file happens to pick from a string list). Used instead of the
-- generic `Rng:pick<T>` method: calling a generic method with a DIFFERENT
-- type argument at multiple call sites in the same scope corrupts a
-- shared generic binding in this project's typechecker (the same class of
-- bug already documented elsewhere as the "table.sort generic V conflict"
-- workaround) -- confirmed here as spurious "missing field int/bool"/
-- "missing metamethod __len" errors once `rng:pick` was used with
-- different list-literal shapes across call sites. A plain non-generic
-- function has no shared binding to corrupt.
--: (FuzzRng, { [number]: string }) -> string
local function pick_string(rng, choices)
  return choices[1 + (rng:next() % #choices)]
end

--: () -> boolean
local function bun_available()
  local fh = io.popen("command -v bun 2>/dev/null")
  if not fh then return false end
  local out = fh:read("*l")
  fh:close()
  return out ~= nil and out ~= ""
end

--------------------------------------------------------------------------
-- Shelling out to verify.js
--------------------------------------------------------------------------

--: (string) -> string
local function hex_to_bytes(h)
  local out = h:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16) or 0) end)
  return out
end

-- Writes `payload_json` to a temp file, runs `bun verify.js < tmpfile`, and
-- returns the decoded raw update bytes (or nil, errmsg on failure).
--: (string) -> (string | nil, string | nil)
local function run_verify_js(payload_json)
  local tmp = os.tmpname()
  local f, ferr = io.open(tmp, "w")
  if not f then return nil, "parity_fuzz: cannot open temp file: " .. tostring(ferr) end
  f:write(payload_json)
  f:close()

  local cmd = "bun " .. VERIFY_JS .. " < " .. tmp .. " 2>&1"
  local fh = io.popen(cmd)
  if not fh then
    os.remove(tmp)
    return nil, "parity_fuzz: io.popen failed for: " .. cmd
  end
  local out = fh:read("*a") or ""
  local ok = fh:close()
  os.remove(tmp)

  if not ok then
    return nil, "parity_fuzz: verify.js failed; output was:\n" .. out
  end
  local hex_line = out:match("^%s*(%x+)%s*$")
  if not hex_line then
    return nil, "parity_fuzz: verify.js did not print a clean hex line; output was:\n" .. out
  end
  return hex_to_bytes(hex_line)
end

--------------------------------------------------------------------------
-- Value generation. A "wire null" is two DIFFERENT sentinel objects
-- depending on which side consumes it: `encoding.null` (y_crdt's own
-- convention, required by array.lua/map.lua's public API) vs `json.null`
-- (lib.format.json's own sentinel, mapped to the JSON literal `null` by
-- its encoder). Values are generated once in JSON-ready form (using
-- `json.null`) and converted to `encoding.null` only at the point they're
-- fed into array.lua/map.lua -- there is exactly one "kind=null" source of
-- truth, not two independently-generated ones that could drift apart.
--------------------------------------------------------------------------

--: (unknown) -> unknown
local function json_value_to_lua(v)
  if v == json.null then return encoding.null end
  return v
end

--: (FuzzRng) -> unknown
local function gen_json_value(rng)
  local kind = pick_string(rng, { "number", "string", "bool", "null" })
  if kind == "number" then
    return rng:int(-1000, 1000)
  elseif kind == "string" then
    return gen.string({ charset = "abcdefghijklmnopqrstuvwxyz", min = 1, max = 6 }).generate(rng, 6)
  elseif kind == "bool" then
    return rng:bool()
  else
    return json.null
  end
end

local ASCII_CHARSET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "

--: (FuzzRng) -> string
local function random_text(rng)
  return gen.string({ charset = ASCII_CHARSET, min = 1, max = 6 }).generate(rng, 6)
end

--------------------------------------------------------------------------
-- Op generation: one function per kind, returning a plain ops list ready
-- to serialize for verify.js. `did_destructive` tracks whether any
-- delete/overwrite was generated, which decides the comparison mode.
--------------------------------------------------------------------------

--: (FuzzRng) -> { [integer]: TextOp }
local function gen_text_content_ops(rng)
  local ops = {} --[[: { [integer]: TextOp } ]]
  local len = 0
  local n_ops = rng:int(3, 6)
  local did_delete = false
  for i = 1, n_ops do
    local choices = { "insert" } --[[: { [number]: string } ]]
    if len > 0 then
      choices[#choices + 1] = "delete"
      choices[#choices + 1] = "format"
    end
    local op_kind
    if i == n_ops and not did_delete and len > 0 then
      op_kind = "delete"
    else
      op_kind = pick_string(rng, choices)
    end

    if op_kind == "insert" then
      local index = rng:int(0, len)
      local s = random_text(rng)
      ops[#ops + 1] = { op = "insert", index = index, length = 0, text = s, key = "", value = false }
      len = len + #s
    elseif op_kind == "delete" then
      local index = rng:int(0, len - 1)
      local length = rng:int(1, len - index)
      ops[#ops + 1] = { op = "delete", index = index, length = length, text = "", key = "", value = false }
      len = len - length
      did_delete = true
    else -- format
      local index = rng:int(0, len - 1)
      local length = rng:int(1, len - index)
      local key = pick_string(rng, { "bold", "italic" })
      ops[#ops + 1] = { op = "format", index = index, length = length, text = "", key = key, value = true }
    end
  end
  return ops
end

--: (FuzzRng, integer) -> { [integer]: unknown }
local function gen_value_list(rng, n)
  local values = {} --[[: { [integer]: unknown } ]]
  for i = 1, n do values[i] = gen_json_value(rng) end
  return values
end

--: (FuzzRng) -> { [integer]: ArrayOp }
local function gen_array_bytes_ops(rng)
  return { { op = "insert", index = 0, length = 0, values = gen_value_list(rng, rng:int(1, 3)) } }
end

--: (FuzzRng) -> { [integer]: ArrayOp }
local function gen_array_content_ops(rng)
  local ops = {} --[[: { [integer]: ArrayOp } ]]
  local len = 0
  local n_ops = rng:int(3, 6)
  local did_delete = false
  for i = 1, n_ops do
    local choices = { "insert" } --[[: { [number]: string } ]]
    if len > 0 then choices[#choices + 1] = "delete" end
    local op_kind
    if i == n_ops and not did_delete and len > 0 then
      op_kind = "delete"
    else
      op_kind = pick_string(rng, choices)
    end

    if op_kind == "insert" then
      local index = rng:int(0, len)
      local values = gen_value_list(rng, rng:int(1, 3))
      ops[#ops + 1] = { op = "insert", index = index, length = 0, values = values }
      len = len + #values
    else -- delete
      local index = rng:int(0, len - 1)
      local length = rng:int(1, len - index)
      ops[#ops + 1] = { op = "delete", index = index, length = length, values = {} }
      len = len - length
      did_delete = true
    end
  end
  return ops
end

local MAP_KEY_POOL = { "k1", "k2", "k3", "k4", "k5" }

--: (FuzzRng) -> { [integer]: MapOp }
local function gen_map_bytes_ops(rng)
  return { { op = "set", key = pick_string(rng, MAP_KEY_POOL), value = gen_json_value(rng) } }
end

--: (FuzzRng) -> { [integer]: MapOp }
local function gen_map_content_ops(rng)
  local ops = {} --[[: { [integer]: MapOp } ]]
  local live = {} --[[: { [string]: boolean } ]]
  local n_ops = rng:int(3, 6)
  local did_destructive = false
  for i = 1, n_ops do
    local live_keys = {} --[[: { [number]: string } ]]
    for k, present in pairs(live) do if present then live_keys[#live_keys + 1] = k end end

    local op_kind
    if i == n_ops and not did_destructive and #live_keys > 0 then
      op_kind = rng:bool() and "delete" or "overwrite"
    elseif #live_keys > 0 and rng:bool() then
      op_kind = pick_string(rng, { "set", "delete", "overwrite" })
    else
      op_kind = "set"
    end

    if op_kind == "set" then
      local key = pick_string(rng, MAP_KEY_POOL)
      ops[#ops + 1] = { op = "set", key = key, value = gen_json_value(rng) }
      if live[key] then did_destructive = true end -- overwriting an existing key supersedes (deletes) the old item
      live[key] = true
    elseif op_kind == "overwrite" then
      local key = pick_string(rng, live_keys)
      ops[#ops + 1] = { op = "set", key = key, value = gen_json_value(rng) }
      did_destructive = true
    else -- delete
      local key = pick_string(rng, live_keys)
      ops[#ops + 1] = { op = "delete", key = key, value = json.null }
      live[key] = false
      did_destructive = true
    end
  end
  return ops
end

--------------------------------------------------------------------------
-- Applying ops to a Lua doc. Each op is its own transaction, matching
-- verify.js's op-by-op semantics (every Y.Text/Y.Array/Y.Map method call
-- is implicitly its own yjs transaction unless explicitly batched).
--------------------------------------------------------------------------

-- Applies TextOp ops to a fresh Lua doc, returning the doc and its "content"
-- root's rendered string (once, up front -- used for either comparison
-- mode below).
--: (number, { [integer]: TextOp }) -> (unknown, string)
local function apply_text_ops(client_id, ops)
  local d = doc_mod.new({ client_id = client_id })
  local t = doc_mod.get_text(d, "content")
  if t == nil then error("parity_fuzz: get_text failed on a fresh doc (internal invariant violation)", 2) end
  for _, op in ipairs(ops) do
    if op.op == "insert" then
      doc_mod.transact(d, function(txn) text.insert(t, txn, op.index, op.text) end)
    elseif op.op == "delete" then
      doc_mod.transact(d, function(txn) text.delete(t, txn, op.index, op.length) end)
    else -- format
      doc_mod.transact(d, function(txn) text.format(t, txn, op.index, op.length, { [op.key] = op.value }) end)
    end
  end
  return d, text.to_string(t)
end

--: (number, { [integer]: ArrayOp }) -> (unknown, { [integer]: unknown })
local function apply_array_ops(client_id, ops)
  local d = doc_mod.new({ client_id = client_id })
  local a = doc_mod.get_array(d, "content")
  if a == nil then error("parity_fuzz: get_array failed on a fresh doc (internal invariant violation)", 2) end
  for _, op in ipairs(ops) do
    if op.op == "insert" then
      local lua_values = {} --[[: { [integer]: unknown } ]]
      for i, v in ipairs(op.values) do lua_values[i] = json_value_to_lua(v) end
      doc_mod.transact(d, function(txn) array.insert(a, txn, op.index, lua_values) end)
    else -- delete
      doc_mod.transact(d, function(txn) array.delete(a, txn, op.index, op.length) end)
    end
  end
  return d, array.to_array(a)
end

--: (number, { [integer]: MapOp }) -> (unknown, { [string]: unknown })
local function apply_map_ops(client_id, ops)
  local d = doc_mod.new({ client_id = client_id })
  local m = doc_mod.get_map(d, "content")
  if m == nil then error("parity_fuzz: get_map failed on a fresh doc (internal invariant violation)", 2) end
  for _, op in ipairs(ops) do
    if op.op == "set" then
      doc_mod.transact(d, function(txn) map.set(m, txn, op.key, json_value_to_lua(op.value)) end)
    else -- delete
      doc_mod.transact(d, function(txn) map.delete(m, txn, op.key) end)
    end
  end
  return d, map.to_table(m)
end

--------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------

--: (number, string, unknown) -> string
local function build_payload(client_id, kind, ops)
  local payload_str, err = json.encode({ client_id = client_id, kind = kind, ops = ops }, json.null)
  if not payload_str then error("parity_fuzz: failed to encode payload: " .. tostring(err), 2) end
  return payload_str
end

--: (unknown) -> string
local function content_repr(v)
  local s, err = json.encode(v, json.null)
  if s ~= nil then return s end
  return tostring(v) .. " (json.encode failed: " .. tostring(err) .. ")"
end

-- Text always uses byte-for-byte comparison now, regardless of what ops
-- were generated (see this file's header comment: both gaps that used to
-- force a weaker "content" mode for text -- item compaction and the
-- formatting-gap/positioning-primitive bugs found and fixed alongside
-- `cleanupFormattingGap`'s port -- are closed and verified against real
-- yjs, 800+ fuzz iterations across 8 seeds with zero mismatches). `mode` is
-- still threaded through for the assertion label/failure message, but it's
-- always "bytes" for text now -- kept as a parameter (not hardcoded in the
-- format string) so a future re-introduction of a weaker mode, if ever
-- needed, has an obvious single place to change.
--: (integer, string, { [integer]: TextOp }) -> nil
local function run_text_iteration(i, mode, ops)
  T.it(string.format("iter %d: kind=text mode=%s", i, mode), function()
    local client_id = i -- distinct per iteration, deterministic given the fuzz seed
    local d, _lua_content = apply_text_ops(client_id, ops)

    local payload = build_payload(client_id, "text", ops)
    local js_bytes, jerr = run_verify_js(payload)
    T.ok(js_bytes ~= nil, "verify.js failed for payload " .. payload .. ":\n" .. tostring(jerr))
    if js_bytes == nil then return end

    local empty_sv = update.encode_state_vector_from_table({})
    local lua_bytes, lerr = update.encode_diff_v1(d, empty_sv)
    T.ok(lua_bytes ~= nil, lerr)

    T.eq(lua_bytes, js_bytes, string.format("[mode=%s] byte mismatch for payload %s", mode, payload))
  end)
end

--: (integer, string, { [integer]: ArrayOp }) -> nil
local function run_array_iteration(i, mode, ops)
  T.it(string.format("iter %d: kind=array mode=%s", i, mode), function()
    local client_id = i
    local d, lua_content = apply_array_ops(client_id, ops)

    local payload = build_payload(client_id, "array", ops)
    local js_bytes, jerr = run_verify_js(payload)
    T.ok(js_bytes ~= nil, "verify.js failed for payload " .. payload .. ":\n" .. tostring(jerr))
    if js_bytes == nil then return end

    local empty_sv = update.encode_state_vector_from_table({})
    local lua_bytes, lerr = update.encode_diff_v1(d, empty_sv)
    T.ok(lua_bytes ~= nil, lerr)

    if mode == "bytes" then
      T.eq(lua_bytes, js_bytes, string.format("[mode=bytes] byte mismatch for payload %s", payload))
    else
      local d2 = doc_mod.new({ client_id = 0 })
      local a2 = doc_mod.get_array(d2, "content")
      if a2 == nil then error("parity_fuzz: get_array failed on a fresh doc (internal invariant violation)", 2) end
      local applied, aerr = update.apply_v1(d2, js_bytes)
      T.ok(applied ~= nil, "[mode=content] failed to decode yjs's bytes for payload " .. payload .. ": " .. tostring(aerr))
      T.eq(content_repr(lua_content), content_repr(array.to_array(a2)),
        string.format("[mode=content] content mismatch for payload %s", payload))
    end
  end)
end

--: (integer, string, { [integer]: MapOp }) -> nil
local function run_map_iteration(i, mode, ops)
  T.it(string.format("iter %d: kind=map mode=%s", i, mode), function()
    local client_id = i
    local d, lua_content = apply_map_ops(client_id, ops)

    local payload = build_payload(client_id, "map", ops)
    local js_bytes, jerr = run_verify_js(payload)
    T.ok(js_bytes ~= nil, "verify.js failed for payload " .. payload .. ":\n" .. tostring(jerr))
    if js_bytes == nil then return end

    local empty_sv = update.encode_state_vector_from_table({})
    local lua_bytes, lerr = update.encode_diff_v1(d, empty_sv)
    T.ok(lua_bytes ~= nil, lerr)

    if mode == "bytes" then
      T.eq(lua_bytes, js_bytes, string.format("[mode=bytes] byte mismatch for payload %s", payload))
    else
      local d2 = doc_mod.new({ client_id = 0 })
      local m2 = doc_mod.get_map(d2, "content")
      if m2 == nil then error("parity_fuzz: get_map failed on a fresh doc (internal invariant violation)", 2) end
      local applied, aerr = update.apply_v1(d2, js_bytes)
      T.ok(applied ~= nil, "[mode=content] failed to decode yjs's bytes for payload " .. payload .. ": " .. tostring(aerr))
      T.eq(content_repr(lua_content), content_repr(map.to_table(m2)),
        string.format("[mode=content] content mismatch for payload %s", payload))
    end
  end)
end

if not bun_available() then
  T.describe("y_crdt fuzz-parity vs real yjs", function()
    T.it("skipped (bun not on PATH)", function()
      T.ok(true, "bun absent -- parity_fuzz.lua requires bun to shell out to fixtures/verify.js")
    end)
  end)
else
  local ITERS = tonumber(os.getenv("FUZZ_ITERS") or "") or 20
  local SEED = tonumber(os.getenv("FUZZ_SEED") or "") or os.time()
  local rng = gen.make_rng(SEED)

  T.describe(string.format("y_crdt fuzz-parity vs real yjs (seed=%d, iters=%d, replay: FUZZ_SEED=%d)", SEED, ITERS, SEED), function()
    for i = 1, ITERS do
      local kind = pick_string(rng, { "text", "array", "map" })
      local mode = pick_string(rng, { "bytes", "content" })

      if kind == "text" then
        -- Always the richer op sequence (inserts/deletes/format) AND
        -- always byte-compared -- see `run_text_iteration`'s comment for
        -- why text no longer needs the weaker "content" mode array/map
        -- still use below.
        run_text_iteration(i, "bytes", gen_text_content_ops(rng))
      elseif kind == "array" then
        local ops = mode == "bytes" and gen_array_bytes_ops(rng) or gen_array_content_ops(rng)
        run_array_iteration(i, mode, ops)
      else
        local ops = mode == "bytes" and gen_map_bytes_ops(rng) or gen_map_content_ops(rng)
        run_map_iteration(i, mode, ops)
      end
    end
  end)
end
