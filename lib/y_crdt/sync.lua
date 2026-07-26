-- lib/y_crdt/sync.lua
--
-- y-protocols sync protocol: the 3-message handshake that lets two yjs
-- replicas converge over any byte-oriented transport. Verified byte-for-byte
-- against upstream yjs/y-protocols (src/sync.js, fetched 2026-07-27 via
-- `gh api repos/yjs/y-protocols/git/blobs/<sha>` -- the raw githubusercontent
-- URL 404s for this repo/branch, so this is how the source was actually
-- read): `messageYjsSyncStep1 = 0`, `messageYjsSyncStep2 = 1`,
-- `messageYjsUpdate = 2`, confirming the brief's numbering. Each message is
-- `[varUint messageType][varUint8Array payload]` -- `writeSyncStep1`/
-- `writeSyncStep2`/`writeUpdate` all wrap their payload via
-- `encoding.writeVarUint8Array`, which is `encoding.lua`'s
-- `write_var_buffer` here (length-prefixed raw bytes, not a nested
-- self-describing message).
--
-- SCOPE: this module only produces/consumes the 3 core message *frames* and
-- applies them to a Doc -- it does not implement upstream's SyncDone
-- message type (mentioned in y-protocols' own doc comment as an optional
-- addition for peer-to-peer topologies, not part of the core 3-message
-- protocol) or any transport/room-name framing (upstream's own comment: "A
-- message does not include information about the room name. This must be
-- handled by the upper layer protocol!").

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local encoding = require("lib.y_crdt.encoding")
local update = require("lib.y_crdt.update")
local doc_mod = require("lib.y_crdt.doc")

local M = {}

-- Doc is non-recursive (a client id, a StructStore, and a name->SharedType
-- map), so `typeof` captures it exactly -- same reasoning as doc.lua's own
-- `StructStore = typeof sample_store`.
local sample_doc = doc_mod.new({ client_id = 0 })
--:: Doc = typeof sample_doc

--:: MessageType = "step1" | "step2" | "update"

local MESSAGE_SYNC_STEP1 = 0
local MESSAGE_SYNC_STEP2 = 1
local MESSAGE_UPDATE = 2

--------------------------------------------------------------------------
-- Message construction
--------------------------------------------------------------------------

-- SyncStep1: "here's my state vector, send me what I'm missing."
--: (doc: Doc) -> string
function M.write_step1(doc)
  local enc = encoding.encoder()
  enc:write_var_uint(MESSAGE_SYNC_STEP1)
  enc:write_var_buffer(update.encode_state_vector(doc))
  return enc:to_string()
end

-- SyncStep2: reply to a received SyncStep1, carrying everything the sender
-- (whose state vector is `sv_bytes`) is missing from `doc`.
--: (doc: Doc, sv_bytes: string) -> (string | nil, string | nil)
function M.write_step2(doc, sv_bytes)
  local diff, err = update.encode_diff_v1(doc, sv_bytes)
  if diff == nil then return nil, err end
  local enc = encoding.encoder()
  enc:write_var_uint(MESSAGE_SYNC_STEP2)
  enc:write_var_buffer(diff)
  return enc:to_string()
end

-- Update: broadcast an already-encoded update (from update.encode_v1 or
-- update.encode_diff_v1) to connected peers after a local change.
--: (update_bytes: string) -> string
function M.write_update(update_bytes)
  local enc = encoding.encoder()
  enc:write_var_uint(MESSAGE_UPDATE)
  enc:write_var_buffer(update_bytes)
  return enc:to_string()
end

--------------------------------------------------------------------------
-- Message reading
--------------------------------------------------------------------------

-- Reads the message type tag and payload buffer. Returns (nil, errmsg) for
-- truncated input or an unrecognized type tag.
--: (bytes: string) -> (MessageType, string) | (nil, string)
function M.read_message(bytes)
  local dec = encoding.decoder(bytes)
  local tag, terr = dec:read_var_uint()
  if tag == nil then return nil, terr or "sync: failed to read message type tag" end
  local payload, perr = dec:read_var_buffer()
  if payload == nil then return nil, perr or "sync: failed to read message payload" end

  if tag == MESSAGE_SYNC_STEP1 then
    return "step1", payload
  elseif tag == MESSAGE_SYNC_STEP2 then
    return "step2", payload
  elseif tag == MESSAGE_UPDATE then
    return "update", payload
  else
    return nil, "sync: unknown message type tag " .. tostring(tag)
  end
end

-- Reads a message and applies it to `doc`:
--   step1  -- applies nothing; returns a SyncStep2 response to send back.
--   step2  -- applies the carried update to `doc`; returns nil (no reply).
--   update -- applies the carried update to `doc`; returns nil (no reply).
-- The caller sends the first return value (if non-nil) back over the
-- transport; a (nil, nil) result means "applied, nothing to send back."
--: (doc: Doc, bytes: string) -> (string | nil, string | nil)
function M.handle_message(doc, bytes)
  local msg_type, payload = M.read_message(bytes)
  if msg_type == nil then
    -- `payload` holds the errmsg in this branch (read_message's failure
    -- arm), not a message payload.
    return nil, payload
  end
  -- TYPECHECKER WORKAROUND: `read_message`'s declared return type is the
  -- tuple union `(MessageType, string) | (nil, string)`, and the
  -- `msg_type == nil` guard above does narrow `msg_type` correctly -- but
  -- `payload` itself is left typed `string | nil` afterward rather than
  -- collapsing to the sibling `string` of the surviving tuple arm.
  -- Confirmed by minimal repro (`(string, string) | (nil, string)`, guard
  -- on the first slot, then pass the second slot as an argument to a
  -- function declared to take plain `string`): the guard narrows a bare
  -- `return second_slot` only because that call site's own return type
  -- happens to already accept `nil`, not because narrowing actually
  -- occurred -- passing the same value into a strictly-`string` parameter
  -- (or into a fresh `--[[: string]]`-cast local) still fails. A second,
  -- redundant-at-runtime nil guard on `payload` itself is the one thing
  -- that reliably re-establishes its type. The natural code would rely on
  -- the single `msg_type == nil` guard above. TODO.md tracks removing this
  -- once tuple-union arm narrowing extends to every slot of the surviving
  -- arm, not just the one actually tested.
  if payload == nil then return nil, "sync: internal invariant: message type resolved but payload is nil" end
  if msg_type == "step1" then
    return M.write_step2(doc, payload)
  end
  -- msg_type == "step2" or "update": both are applied identically, matching
  -- upstream's own `readUpdate = readSyncStep2` alias.
  local txn, err = update.apply_v1(doc, payload)
  if txn == nil then return nil, err end
  return nil
end

return M
