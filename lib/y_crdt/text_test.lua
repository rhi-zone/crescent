if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local doc = require("lib.y_crdt.doc")
local text = require("lib.y_crdt.text")
local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local integrate = require("lib.y_crdt.integrate")
local update = require("lib.y_crdt.update")

-- Counts struct entries reachable from `t.start`, for tests asserting on
-- structural shape (item count/deleted-state) rather than just visible
-- content -- matches struct_store_test.lua's own `sequence` helper style.
local function count_items(t)
  local count = 0
  local cur = t.start
  while cur ~= nil do
    count = count + 1
    cur = cur.right
  end
  return count
end

-- All items reachable from `t.start` are deleted (used to assert a delete
-- fully collapsed a formatted run, including its markers).
local function all_deleted(t)
  local cur = t.start
  while cur ~= nil do
    if not cur.deleted then return false end
    cur = cur.right
  end
  return true
end

T.describe("text.insert", function()
  T.it("inserts into an empty text", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      T.ok(text.insert(t, txn, 0, "hello"))
    end)
    T.eq(text.to_string(t), "hello")
    T.eq(text.length(t), 5)
  end)

  T.it("inserts at the beginning", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "world")
      text.insert(t, txn, 0, "hello ")
    end)
    T.eq(text.to_string(t), "hello world")
  end)

  T.it("inserts in the middle", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "helloworld")
      text.insert(t, txn, 5, " ")
    end)
    T.eq(text.to_string(t), "hello world")
  end)

  T.it("inserts at the end", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello")
      text.insert(t, txn, 5, " world")
    end)
    T.eq(text.to_string(t), "hello world")
  end)

  T.it("rejects an out-of-range index", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      local ok, err = text.insert(t, txn, 5, "x")
      T.eq(ok, nil)
      T.ok(err ~= nil)
    end)
  end)
end)

T.describe("text.delete", function()
  T.it("deletes from the beginning", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello world")
      text.delete(t, txn, 0, 6)
    end)
    T.eq(text.to_string(t), "world")
  end)

  T.it("deletes from the middle", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello world")
      text.delete(t, txn, 5, 1)
    end)
    T.eq(text.to_string(t), "helloworld")
  end)

  T.it("deletes from the end", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello world")
      text.delete(t, txn, 5, 6)
    end)
    T.eq(text.to_string(t), "hello")
  end)

  T.it("insert then delete round-trips to empty", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello")
      text.delete(t, txn, 0, 5)
    end)
    T.eq(text.to_string(t), "")
    T.eq(text.length(t), 0)
  end)

  T.it("deleted items are excluded from a later insert's neighbor walk", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello")
      text.delete(t, txn, 1, 3) -- "h" + "o" survive, "ell" deleted
      text.insert(t, txn, 1, "i")
    end)
    T.eq(text.to_string(t), "hio")
  end)

  T.it("rejects an out-of-range range", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hi")
      local ok, err = text.delete(t, txn, 0, 5)
      T.eq(ok, nil)
      T.ok(err ~= nil)
    end)
  end)
end)

T.describe("text.length", function()
  T.it("tracks visible length across inserts and deletes", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    T.eq(text.length(t), 0)
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "abcdef")
    end)
    T.eq(text.length(t), 6)
    doc.transact(d, function(txn)
      text.delete(t, txn, 2, 2)
    end)
    T.eq(text.length(t), 4)
  end)
end)

T.describe("text.format / text.to_delta", function()
  T.it("insert with attrs produces a delta run with those attributes", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello", { bold = true })
    end)
    local delta = text.to_delta(t)
    T.eq(#delta, 1)
    T.eq(delta[1].insert, "hello")
    T.ok(delta[1].attributes ~= nil)
    T.eq(delta[1].attributes.bold, true)
  end)

  T.it("plain insert produces a delta run with no attributes", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello")
    end)
    local delta = text.to_delta(t)
    T.eq(#delta, 1)
    T.eq(delta[1].insert, "hello")
    T.eq(delta[1].attributes, nil)
  end)

  T.it("format applies attributes to an existing range", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "hello world")
      T.ok(text.format(t, txn, 0, 5, { bold = true }))
    end)
    local delta = text.to_delta(t)
    -- "hello" bold, " world" unformatted
    T.eq(#delta, 2)
    T.eq(delta[1].insert, "hello")
    T.eq(delta[1].attributes.bold, true)
    T.eq(delta[2].insert, " world")
    T.eq(delta[2].attributes, nil)
  end)
end)

T.describe("text concurrent inserts (YATA convergence)", function()
  T.it("converges to the same visible order regardless of integration order", function()
    -- Two items from different clients, both targeting index 0 of an empty
    -- text (same origin/origin_right: nil/nil). YATA must place them in a
    -- deterministic order (lower client id wins the left position) no
    -- matter which one is integrated first -- this is the core correctness
    -- property this whole library exists to guarantee, exercised here at
    -- the text.lua level rather than item.lua's (see item_test.lua/
    -- struct_store_test.lua for the lower-level version).
    --: (first: "a" | "b") -> string
    local function build(first)
      local d = doc.new({ client_id = 99 })
      local t = doc.get_text(d, "content")
      doc.transact(d, function(txn)
        local item_a = item.new(id.new(1, 0), nil, nil, t, nil, content.string("A"))
        local item_b = item.new(id.new(2, 0), nil, nil, t, nil, content.string("B"))
        if first == "a" then
          integrate.integrate(txn, item_a)
          integrate.integrate(txn, item_b)
        else
          integrate.integrate(txn, item_b)
          integrate.integrate(txn, item_a)
        end
      end)
      return text.to_string(t)
    end

    local s1 = build("a")
    local s2 = build("b")
    T.eq(s1, s2)
    T.eq(#s1, 2)
  end)
end)

T.describe("text.delete formatting cleanup (cleanupFormattingGap port)", function()
  T.it("deleting a fully-formatted range collapses its format markers too", function()
    -- The exact TODO.md repro this cleanup pass was added to close:
    -- insert; format the whole thing; delete the whole thing should leave
    -- EVERY item deleted (matching real yjs), not just the string content.
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "J")
      text.format(t, txn, 0, 1, { italic = true })
      text.delete(t, txn, 0, 1)
    end)
    T.eq(text.to_string(t), "")
    T.eq(text.length(t), 0)
    T.ok(all_deleted(t), "expected every item (string + both format markers) to be deleted")
  end)

  T.it("does not delete a format marker still needed by surviving text", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "ab")
      text.format(t, txn, 0, 2, { italic = true })
      text.delete(t, txn, 0, 1) -- delete "a" only; "b" is still italic
    end)
    T.eq(text.to_string(t), "b")
    local delta = text.to_delta(t)
    T.eq(#delta, 1)
    T.eq(delta[1].insert, "b")
    T.eq(delta[1].attributes.italic, true)
  end)

  T.it("a redundant format() sub-range that already matches does not split the covering item", function()
    -- Regression test for the `find_pos`/`merge_structs` fix found via
    -- fuzzing: formatting a SUBSET of an already-fully-matching range used
    -- to gratuitously split the covering string item and leave the split
    -- unmerged (real yjs never splits here at all).
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "abc")
      text.format(t, txn, 0, 3, { italic = true })
      text.format(t, txn, 0, 2, { italic = true }) -- redundant subset
    end)
    T.eq(text.to_string(t), "abc")
    -- format-open, "abc" (unsplit), format-close -- exactly 3 items.
    T.eq(count_items(t), 3)
  end)
end)

T.describe("text.insert attribute inheritance vs explicit attrs", function()
  T.it("a plain insert (attrs=nil) inherits the attributes active at that position", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "a", { italic = true })
      text.insert(t, txn, 1, "b") -- no attrs -- should continue italic
    end)
    local delta = text.to_delta(t)
    T.eq(#delta, 1)
    T.eq(delta[1].insert, "ab")
    T.eq(delta[1].attributes.italic, true)
  end)

  T.it("an explicit empty attrs table removes attributes active at that position", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    doc.transact(d, function(txn)
      text.insert(t, txn, 0, "a", { italic = true })
      text.insert(t, txn, 1, "b", {}) -- explicit, empty -- should NOT be italic
    end)
    local delta = text.to_delta(t)
    T.eq(#delta, 2)
    T.eq(delta[1].insert, "a")
    T.eq(delta[1].attributes.italic, true)
    T.eq(delta[2].insert, "b")
    T.eq(delta[2].attributes, nil)
  end)
end)

T.describe("text.cleanup_after_remote_apply (cleanupYTextAfterTransaction port)", function()
  T.it("a remote apply of an already-locally-cleaned update stays fully deleted", function()
    -- Builds a formatted-then-fully-deleted text via the LOCAL path (which
    -- already cleans up inline, see M.delete), encodes it, and replays the
    -- exact same byte-for-byte update onto a FRESH doc via apply_v1. The
    -- receiving doc must converge to the identical (fully deleted)
    -- structure the sending doc has -- a baseline sanity check that
    -- wiring `cleanup_after_remote_apply`/`transaction.cleanup` into
    -- `apply_v1` doesn't itself break ordinary convergence.
    local d1 = doc.new({ client_id = 1 })
    local t1 = doc.get_text(d1, "content")
    local txn1 = doc.transact(d1, function(txn)
      text.insert(t1, txn, 0, "J")
      text.format(t1, txn, 0, 1, { italic = true })
      text.delete(t1, txn, 0, 1)
    end)
    T.ok(txn1 ~= nil)

    local bytes = update.encode_v1(d1, txn1)
    T.ok(bytes ~= nil)

    local d2 = doc.new({ client_id = 2 })
    doc.get_text(d2, "content")
    local applied, aerr = update.apply_v1(d2, bytes)
    T.ok(applied ~= nil, aerr)

    local t2 = d2.share["content"]
    T.eq(text.to_string(t2), "")
    T.ok(all_deleted(t2), "expected every item on the receiving doc to be deleted, matching the sender")
  end)

  T.it("cleans up a contextless formatting gap left by a delete that bypassed M.delete's own cleanup", function()
    -- Directly exercises `cleanup_after_remote_apply`'s OWN value-add
    -- (distinct from `M.delete`'s inline `cleanup_formatting_gap` call):
    -- constructs [format-open(italic), "J", format-close(italic)] via
    -- integrate.integrate directly (bypassing text.lua's insert/format
    -- entirely), then deletes the string via `item.delete` directly
    -- (bypassing M.delete's own inline cleanup too -- mirrors how
    -- `update.lua`'s `apply_delete_set` marks items deleted without ever
    -- calling M.delete), then calls `cleanup_after_remote_apply` in
    -- isolation.
    --
    -- Verified against this port's own actual behavior (no new format item
    -- exists in this transaction, so this takes the CONTEXTLESS path, not
    -- the full-type sweep): `cleanup_contextless_formatting_gap` only
    -- removes a DUPLICATE-key marker found during its right-to-left walk,
    -- not a full redundancy analysis -- so exactly ONE of the two
    -- (open/close) markers ends up deleted here (the one further from the
    -- next live item), not both. This is a narrower guarantee than
    -- `M.delete`'s own inline cleanup by design (yjs's own comment on
    -- `cleanupContextlessFormattingGap`: "it is not necessary to compute
    -- currentAttributes for the affected position") -- the full 2-pass
    -- sweep only runs when a NEW format item was integrated this
    -- transaction (`need_full_cleanup`), which is not this scenario.
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    local open_item, str_item
    doc.transact(d, function(txn)
      open_item = item.new(id.new(1, 0), nil, nil, t, nil, content.format("italic", true))
      integrate.integrate(txn, open_item)
      str_item = item.new(id.new(1, 1), open_item.id, nil, t, nil, content.string("J"))
      integrate.integrate(txn, str_item)
      local close_item = item.new(id.new(1, 2), str_item.id, nil, t, nil, content.format("italic", nil))
      integrate.integrate(txn, close_item)
    end)
    T.eq(text.to_string(t), "J")

    doc.transact(d, function(txn)
      item.delete(txn, str_item)
      text.cleanup_after_remote_apply(txn)
    end)

    T.eq(text.to_string(t), "")
    T.ok(open_item.deleted, "expected the format-open marker (the duplicate found walking right-to-left) to be deleted")
    local n = t.start
    local live_format_markers = 0
    while n ~= nil do
      if not n.deleted and n.content.kind == "format" then live_format_markers = live_format_markers + 1 end
      n = n.right
    end
    T.eq(live_format_markers, 1, "expected exactly one format marker (the close marker) to remain live")
  end)
end)
