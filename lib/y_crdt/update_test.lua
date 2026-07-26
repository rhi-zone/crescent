-- lib/y_crdt/update_test.lua
-- Tests for the yjs update v1 wire codec (lib/y_crdt/update.lua).

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local doc_mod = require("lib.y_crdt.doc")
local text = require("lib.y_crdt.text")
local update = require("lib.y_crdt.update")

T.describe("update.encode_v1 / apply_v1: simple round trip", function()
  T.it("carries a text insert from one doc to a fresh doc", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    local txn = doc_mod.transact(d1, function(txn)
      text.insert(t1, txn, 0, "hello")
    end)
    T.ok(txn ~= nil)

    local bytes, err = update.encode_v1(d1, txn)
    T.ok(bytes ~= nil, err)

    local d2 = doc_mod.new({ client_id = 2 })
    local t2 = doc_mod.get_text(d2, "content")
    local applied, aerr = update.apply_v1(d2, bytes)
    T.ok(applied ~= nil, aerr)

    T.eq(text.to_string(t2), "hello")
  end)

  T.it("carries multiple sequential inserts", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    local txn1 = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "hello") end)
    local bytes1 = update.encode_v1(d1, txn1)

    local txn2 = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 5, " world") end)
    local bytes2 = update.encode_v1(d1, txn2)

    local d2 = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(d2, "content")
    local t2 = d2.share["content"]
    local ok1, err1 = update.apply_v1(d2, bytes1)
    T.ok(ok1 ~= nil, err1)
    local ok2, err2 = update.apply_v1(d2, bytes2)
    T.ok(ok2 ~= nil, err2)

    T.eq(text.to_string(t2), "hello world")
  end)

  T.it("fails cleanly when the target doc hasn't declared the referenced root", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    local txn = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "x") end)
    local bytes = update.encode_v1(d1, txn)

    local d2 = doc_mod.new({ client_id = 2 }) -- no get_text("content") call
    local applied, aerr = update.apply_v1(d2, bytes)
    T.eq(applied, nil)
    T.ok(aerr ~= nil)
  end)
end)

T.describe("update.encode_state_vector / decode_state_vector", function()
  T.it("round-trips an empty doc's state vector", function()
    local d = doc_mod.new({ client_id = 7 })
    local bytes = update.encode_state_vector(d)
    local sv, err = update.decode_state_vector(bytes)
    T.ok(sv ~= nil, err)
    T.eq(next(sv), nil)
  end)

  T.it("round-trips a populated state vector", function()
    local d = doc_mod.new({ client_id = 7 })
    local t = doc_mod.get_text(d, "content")
    doc_mod.transact(d, function(txn) text.insert(t, txn, 0, "abcde") end)

    local bytes = update.encode_state_vector(d)
    local sv, err = update.decode_state_vector(bytes)
    T.ok(sv ~= nil, err)
    T.eq(sv[7], 5)
  end)

  T.it("encode_state_vector_from_table round-trips a hand-built table", function()
    local bytes = update.encode_state_vector_from_table({ [1] = 3, [42] = 100 })
    local sv, err = update.decode_state_vector(bytes)
    T.ok(sv ~= nil, err)
    T.eq(sv[1], 3)
    T.eq(sv[42], 100)
  end)
end)

T.describe("update.encode_v1: delete set", function()
  T.it("carries a deletion so the receiving doc marks the same range deleted", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    local txn1 = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "hello world") end)
    local bytes1 = update.encode_v1(d1, txn1)

    local d2 = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(d2, "content")
    update.apply_v1(d2, bytes1)

    local txn2 = doc_mod.transact(d1, function(txn) text.delete(t1, txn, 5, 6) end) -- delete " world"
    T.ok(txn2 ~= nil)
    T.ok(#txn2.deleted_items > 0)
    local bytes2, err2 = update.encode_v1(d1, txn2)
    T.ok(bytes2 ~= nil, err2)

    local t2 = d2.share["content"]
    local applied, aerr = update.apply_v1(d2, bytes2)
    T.ok(applied ~= nil, aerr)

    T.eq(text.to_string(t1), "hello")
    T.eq(text.to_string(t2), "hello")
  end)
end)

T.describe("update.encode_diff_v1", function()
  T.it("encodes only what a peer's state vector is missing", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "hello") end)

    local d2 = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(d2, "content")
    local sv2 = update.encode_state_vector(d2)

    local diff_bytes, err = update.encode_diff_v1(d1, sv2)
    T.ok(diff_bytes ~= nil, err)

    local applied, aerr = update.apply_v1(d2, diff_bytes)
    T.ok(applied ~= nil, aerr)
    T.eq(text.to_string(d2.share["content"]), "hello")
  end)

  T.it("encodes nothing new when the peer is already caught up", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "hello") end)

    local d2 = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(d2, "content")
    local diff1, _ = update.encode_diff_v1(d1, update.encode_state_vector(d2))
    update.apply_v1(d2, diff1)

    -- d2 is now caught up to d1; a second diff against d1's own state
    -- vector should carry no structs.
    local sv1 = update.encode_state_vector(d1)
    local diff2, err2 = update.encode_diff_v1(d1, sv1)
    T.ok(diff2 ~= nil, err2)

    -- Applying an "empty" diff should be a no-op, not an error.
    local applied, aerr = update.apply_v1(d2, diff2)
    T.ok(applied ~= nil, aerr)
    T.eq(text.to_string(d2.share["content"]), "hello")
  end)
end)

T.describe("update: multi-client convergence", function()
  T.it("converges when two clients insert at the same position concurrently", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local d2 = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(d1, "content")
    doc_mod.get_text(d2, "content")

    local t1 = d1.share["content"]
    local t2 = d2.share["content"]

    -- Both start from the same empty state and insert concurrently at
    -- index 0 -- YATA's client-id tiebreak decides the final order.
    local txn1 = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "AAA") end)
    local txn2 = doc_mod.transact(d2, function(txn) text.insert(t2, txn, 0, "BBB") end)

    local bytes1 = update.encode_v1(d1, txn1)
    local bytes2 = update.encode_v1(d2, txn2)

    local ok1, err1 = update.apply_v1(d1, bytes2)
    T.ok(ok1 ~= nil, err1)
    local ok2, err2 = update.apply_v1(d2, bytes1)
    T.ok(ok2 ~= nil, err2)

    local s1 = text.to_string(t1)
    local s2 = text.to_string(t2)
    T.eq(s1, s2)
    T.eq(#s1, 6)
  end)

  T.it("converges with interleaved inserts and deletes across three exchanges", function()
    local d1 = doc_mod.new({ client_id = 10 })
    local d2 = doc_mod.new({ client_id = 20 })
    doc_mod.get_text(d1, "content")
    doc_mod.get_text(d2, "content")
    local t1 = d1.share["content"]
    local t2 = d2.share["content"]

    local txn1 = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "hello") end)
    local bytes1 = update.encode_v1(d1, txn1)
    update.apply_v1(d2, bytes1)
    T.eq(text.to_string(t2), "hello")

    -- Concurrent: d1 deletes "ll", d2 appends " world".
    local txn1b = doc_mod.transact(d1, function(txn) text.delete(t1, txn, 2, 2) end)
    local txn2b = doc_mod.transact(d2, function(txn) text.insert(t2, txn, 5, " world") end)

    local bytes1b = update.encode_v1(d1, txn1b)
    local bytes2b = update.encode_v1(d2, txn2b)

    update.apply_v1(d2, bytes1b)
    update.apply_v1(d1, bytes2b)

    local s1 = text.to_string(t1)
    local s2 = text.to_string(t2)
    T.eq(s1, s2)
    T.eq(s1, "heo world")
  end)
end)

T.describe("update.merge_updates_v1", function()
  T.it("merges two updates from the same doc into one applicable update", function()
    local d1 = doc_mod.new({ client_id = 1 })
    local t1 = doc_mod.get_text(d1, "content")
    local txn1 = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 0, "ab") end)
    local bytes1 = update.encode_v1(d1, txn1)
    local txn2 = doc_mod.transact(d1, function(txn) text.insert(t1, txn, 2, "cd") end)
    local bytes2 = update.encode_v1(d1, txn2)

    local merged, err = update.merge_updates_v1({ bytes1, bytes2 }, { content = "text" })
    T.ok(merged ~= nil, err)

    local d2 = doc_mod.new({ client_id = 2 })
    doc_mod.get_text(d2, "content")
    local applied, aerr = update.apply_v1(d2, merged)
    T.ok(applied ~= nil, aerr)
    T.eq(text.to_string(d2.share["content"]), "abcd")
  end)
end)
