-- lib/y_crdt/sync_test.lua
-- Tests for the y-protocols sync protocol (lib/y_crdt/sync.lua).

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local doc_mod = require("lib.y_crdt.doc")
local text = require("lib.y_crdt.text")
local update = require("lib.y_crdt.update")
local sync = require("lib.y_crdt.sync")

T.describe("sync: message type round-trip", function()
  T.it("write_step1 round-trips through read_message as 'step1' with the state vector", function()
    local d = doc_mod.new({ client_id = 1 })
    local t = doc_mod.get_text(d, "content")
    doc_mod.transact(d, function(txn) text.insert(t, txn, 0, "abc") end)

    local msg = sync.write_step1(d)
    local msg_type, payload = sync.read_message(msg)
    T.eq(msg_type, "step1")

    local sv, err = update.decode_state_vector(payload)
    T.ok(sv ~= nil, err)
    T.eq(sv[1], 3)
  end)

  T.it("write_step2 round-trips through read_message as 'step2' carrying an update", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "hello") end)

    local empty_sv = update.encode_state_vector_from_table({})
    local msg, werr = sync.write_step2(d1, empty_sv)
    T.ok(msg ~= nil, werr)

    local msg_type, payload = sync.read_message(msg)
    T.eq(msg_type, "step2")

    local d2 = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(d2, "content")
    local applied, aerr = update.apply_v1(d2, payload)
    T.ok(applied ~= nil, aerr)
    T.eq(text.to_string(d2.share["content"]), "hello")
  end)

  T.it("write_update round-trips through read_message as 'update' carrying the exact bytes given", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    local txn = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "x") end)
    local update_bytes = update.encode_v1(d1, txn)

    local msg = sync.write_update(update_bytes)
    local msg_type, payload = sync.read_message(msg)
    T.eq(msg_type, "update")
    T.eq(payload, update_bytes)
  end)

  T.it("read_message rejects an unknown message type tag", function()
    local encoding = require("lib.y_crdt.encoding")
    local enc = encoding.encoder()
    enc:write_var_uint(99)
    enc:write_var_buffer("whatever")
    local msg_type, err = sync.read_message(enc:to_string())
    T.eq(msg_type, nil)
    T.ok(err ~= nil)
  end)

  T.it("read_message rejects truncated input", function()
    local msg_type, err = sync.read_message("")
    T.eq(msg_type, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("sync: full handshake between two docs", function()
  T.it("A inserts text, sends step1 to B, B responds with step2, A applies -- B converges on A's content", function()
    local a = doc_mod.new({ client_id = 1 })
    local ta = doc_mod.get_text(a, "content")
    doc_mod.transact(a, function(txn) text.insert(ta, txn, 0, "hello from A") end)

    local b = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(b, "content")

    -- A -> B: step1 (A's state vector)
    local step1 = sync.write_step1(a)

    -- B handles step1: responds with step2 (the diff A is missing, which is
    -- everything -- B has nothing yet).
    local response, rerr = sync.handle_message(b, step1)
    T.ok(response ~= nil, rerr)

    -- A handles B's step2 response: applies it. B has nothing new for A, so
    -- this update is empty and changes nothing, but must not error.
    local applied, aerr = sync.handle_message(a, response)
    T.eq(applied, nil)
    T.eq(aerr, nil)

    T.eq(text.to_string(ta), "hello from A")

    -- Now do the actual content transfer the other direction too, to prove
    -- B doesn't have A's content yet without an explicit sync step2 back to
    -- B: B replies to A's step1 with a diff of *B's* missing data relative
    -- to A's state vector -- that response goes to A, not to B. B only gets
    -- A's content when B itself sends step1 and A replies.
    local step1_from_b = sync.write_step1(b)
    local response_to_b, rerr2 = sync.handle_message(a, step1_from_b)
    T.ok(response_to_b ~= nil, rerr2)

    local applied_b, aerr2 = sync.handle_message(b, response_to_b)
    T.eq(applied_b, nil)
    T.eq(aerr2, nil)

    T.eq(text.to_string(b.share["content"]), "hello from A")
  end)

  T.it("bidirectional sync: both docs have independent changes, exchange step1/step2, converge", function()
    local a = doc_mod.new({ client_id = 1 })
    local ta = doc_mod.get_text(a, "content")
    doc_mod.transact(a, function(txn) text.insert(ta, txn, 0, "A-side") end)

    local b = doc_mod.new({ client_id = 2 })
    local tb = doc_mod.get_text(b, "content")
    doc_mod.transact(b, function(txn) text.insert(tb, txn, 0, "B-side") end)

    -- Each peer initiates with step1.
    local step1_a = sync.write_step1(a)
    local step1_b = sync.write_step1(b)

    -- Each peer handles the other's step1 and produces a step2 reply.
    local reply_for_a, rerr1 = sync.handle_message(b, step1_a)
    T.ok(reply_for_a ~= nil, rerr1)
    local reply_for_b, rerr2 = sync.handle_message(a, step1_b)
    T.ok(reply_for_b ~= nil, rerr2)

    -- Each peer applies the reply meant for it.
    local ok_a, aerr1 = sync.handle_message(a, reply_for_a)
    T.eq(ok_a, nil)
    T.eq(aerr1, nil)
    local ok_b, aerr2 = sync.handle_message(b, reply_for_b)
    T.eq(ok_b, nil)
    T.eq(aerr2, nil)

    -- Both sides now have both inserts (YATA determines a consistent, if
    -- not necessarily identical-to-any-single-side, interleaving order --
    -- what matters for convergence is that both docs agree with each
    -- other).
    T.eq(text.to_string(ta), text.to_string(tb))
    T.ok(text.to_string(ta):find("A%-side") ~= nil)
    T.ok(text.to_string(ta):find("B%-side") ~= nil)
  end)
end)

T.describe("sync: update broadcast after initial sync", function()
  T.it("A makes a change after initial sync and broadcasts an Update message that B applies", function()
    local a = doc_mod.new({ client_id = 1 })
    local ta = doc_mod.get_text(a, "content")
    doc_mod.transact(a, function(txn) text.insert(ta, txn, 0, "initial") end)

    local b = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(b, "content")

    -- Initial sync: B requests A's state via step1, A replies with step2.
    local step1 = sync.write_step1(b)
    local step2, serr = sync.handle_message(a, step1)
    T.ok(step2 ~= nil, serr)
    local synced, syncerr = sync.handle_message(b, step2)
    T.eq(synced, nil)
    T.eq(syncerr, nil)
    T.eq(text.to_string(b.share["content"]), "initial")

    -- A makes a local change and broadcasts it as an Update message.
    local txn2 = doc_mod.transact(a, function(txn) text.insert(ta, txn, 7, " + more") end)
    local update_bytes = update.encode_v1(a, txn2)
    local update_msg = sync.write_update(update_bytes)

    local applied, aerr = sync.handle_message(b, update_msg)
    T.eq(applied, nil)
    T.eq(aerr, nil)
    T.eq(text.to_string(b.share["content"]), "initial + more")
  end)
end)

T.describe("sync.handle_message: error propagation", function()
  T.it("propagates a decode error from a malformed message without throwing", function()
    local d = doc_mod.new({ client_id = 1 })
    local response, err = sync.handle_message(d, "")
    T.eq(response, nil)
    T.ok(err ~= nil)
  end)

  T.it("propagates an apply error when the target doc hasn't declared the referenced root", function()
    local a = doc_mod.new({ client_id = 1 })
    local ta = doc_mod.get_text(a, "content")
    local txn = doc_mod.transact(a, function(txn) text.insert(ta, txn, 0, "x") end)
    local update_bytes = update.encode_v1(a, txn)
    local update_msg = sync.write_update(update_bytes)

    local b = doc_mod.new({ client_id = 2 }) -- no get_text("content") call
    local response, err = sync.handle_message(b, update_msg)
    T.eq(response, nil)
    T.ok(err ~= nil)
  end)
end)
