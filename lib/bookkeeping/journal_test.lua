if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local money   = require("lib.money")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")

local function usd_chart()
  local chart = account.new()
  account.add_account(chart, { id = "cash",    name = "Cash",    type = "asset" })
  account.add_account(chart, { id = "revenue", name = "Revenue", type = "revenue" })
  account.add_account(chart, { id = "rent",    name = "Rent",    type = "expense" })
  return chart
end

T.describe("lib.bookkeeping.journal", function()

  T.describe("new", function()
    T.it("creates a journal with a valid book currency", function()
      local j, err = journal.new("USD")
      T.ok(j ~= nil, err)
      T.eq(j.book_currency, "USD")
      T.eq(#journal.list(j), 0)
    end)

    T.it("rejects an unknown currency", function()
      local j, err = journal.new("XYZ")
      T.eq(j, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("post: single-currency entries", function()
    T.it("posts a balanced 2-line entry", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Client payment",
        lines = {
          { account = "cash",    amount = money.new("100.00", "USD") },
          { account = "revenue", amount = money.new("-100.00", "USD") },
        },
      })
      T.ok(entry ~= nil, err)
      T.eq(#journal.list(j), 1)
      T.eq(entry.date, "2026-07-26")
    end)

    T.it("posts a balanced 3-line entry", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Split rent payment",
        lines = {
          { account = "rent", amount = money.new("60.00", "USD") },
          { account = "rent", amount = money.new("40.00", "USD") },
          { account = "cash", amount = money.new("-100.00", "USD") },
        },
      })
      T.ok(entry ~= nil, err)
    end)

    T.it("rejects an unbalanced entry", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Broken",
        lines = {
          { account = "cash",    amount = money.new("100.00", "USD") },
          { account = "revenue", amount = money.new("-99.00", "USD") },
        },
      })
      T.eq(entry, nil)
      T.ok(type(err) == "string")
      T.eq(#journal.list(j), 0)
    end)

    T.it("rejects an entry with fewer than 2 lines", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Single line",
        lines = { { account = "cash", amount = money.new("0.00", "USD") } },
      })
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)

    T.it("rejects an unknown account reference", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Bad account",
        lines = {
          { account = "does-not-exist", amount = money.new("100.00", "USD") },
          { account = "cash",           amount = money.new("-100.00", "USD") },
        },
      })
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)

    T.it("rejects a malformed date", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local entry, err = journal.post(j, chart, {
        date = "07/26/2026",
        description = "Bad date",
        lines = {
          { account = "cash",    amount = money.new("100.00", "USD") },
          { account = "revenue", amount = money.new("-100.00", "USD") },
        },
      })
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)

    T.it("rejects a non-money amount", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Bad amount",
        lines = {
          { account = "cash",    amount = 100 },
          { account = "revenue", amount = -100 },
        },
      })
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("post: multi-currency entries", function()
    T.it("balances the coordinator's worked example (USD/EUR FX)", function()
      local j = journal.new("USD")
      local chart = account.new()
      account.add_account(chart, { id = "cash-usd", name = "Cash USD", type = "asset" })
      account.add_account(chart, { id = "cash-eur", name = "Cash EUR", type = "asset" })

      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Buy EUR with USD",
        lines = {
          { account = "cash-usd", amount = money.new("-100.00", "USD") },
          { account = "cash-eur", amount = money.new("92.00", "EUR"), rate = 1.0870 },
        },
      })
      T.ok(entry ~= nil, err)
      T.eq(entry.lines[1].book_amount.currency, "USD")
      T.eq(entry.lines[1].book_amount.amount_minor, -10000)
      T.eq(entry.lines[2].book_amount.currency, "USD")
      T.eq(entry.lines[2].book_amount.amount_minor, 10000)
    end)

    T.it("requires a rate for a non-book-currency line", function()
      local j = journal.new("USD")
      local chart = account.new()
      account.add_account(chart, { id = "cash-usd", name = "Cash USD", type = "asset" })
      account.add_account(chart, { id = "cash-eur", name = "Cash EUR", type = "asset" })

      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Missing rate",
        lines = {
          { account = "cash-usd", amount = money.new("-100.00", "USD") },
          { account = "cash-eur", amount = money.new("92.00", "EUR") },
        },
      })
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)

    T.it("rejects a non-positive rate", function()
      local j = journal.new("USD")
      local chart = account.new()
      account.add_account(chart, { id = "cash-usd", name = "Cash USD", type = "asset" })
      account.add_account(chart, { id = "cash-eur", name = "Cash EUR", type = "asset" })

      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Bad rate",
        lines = {
          { account = "cash-usd", amount = money.new("-100.00", "USD") },
          { account = "cash-eur", amount = money.new("92.00", "EUR"), rate = 0 },
        },
      })
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)

    T.it("rejects a multi-currency entry that doesn't convert to balance", function()
      local j = journal.new("USD")
      local chart = account.new()
      account.add_account(chart, { id = "cash-usd", name = "Cash USD", type = "asset" })
      account.add_account(chart, { id = "cash-eur", name = "Cash EUR", type = "asset" })

      local entry, err = journal.post(j, chart, {
        date = "2026-07-26",
        description = "Off by a cent",
        lines = {
          { account = "cash-usd", amount = money.new("-100.00", "USD") },
          { account = "cash-eur", amount = money.new("92.00", "EUR"), rate = 1.05 },
        },
      })
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("entry ids", function()
    T.it("auto-assigns sequential ids when omitted", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local opts = {
        date = "2026-07-26",
        description = "x",
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      }
      local e1 = journal.post(j, chart, opts)
      local e2 = journal.post(j, chart, opts)
      T.neq(e1.id, e2.id)
    end)

    T.it("accepts an explicit id and rejects a duplicate", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local opts = {
        date = "2026-07-26",
        description = "x",
        id = "opening-balance",
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      }
      local e1, err1 = journal.post(j, chart, opts)
      T.ok(e1 ~= nil, err1)
      T.eq(e1.id, "opening-balance")

      local e2, err2 = journal.post(j, chart, opts)
      T.eq(e2, nil)
      T.ok(type(err2) == "string")
    end)

    T.it("get looks up an entry by id", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local posted = journal.post(j, chart, {
        date = "2026-07-26", description = "x", id = "e1",
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      })
      T.eq(journal.get(j, "e1"), posted)
      T.eq(journal.get(j, "nope"), nil)
    end)
  end)

  T.describe("validate (dry-run, no posting)", function()
    T.it("returns built lines without appending to the journal", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local lines, err = journal.validate(j, chart, {
        date = "2026-07-26",
        description = "dry run",
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      })
      T.ok(lines ~= nil, err)
      T.eq(#journal.list(j), 0)
    end)
  end)

  T.describe("void_entry", function()
    T.it("posts a reversing entry with negated amounts, keeping the original", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local orig = journal.post(j, chart, {
        date = "2026-07-26", description = "Client payment", id = "e1",
        lines = {
          { account = "cash",    amount = money.new("100.00", "USD") },
          { account = "revenue", amount = money.new("-100.00", "USD") },
        },
      })
      T.ok(orig ~= nil)

      local reversal, err = journal.void_entry(j, chart, "e1", "2026-08-01")
      T.ok(reversal ~= nil, err)
      T.eq(reversal.date, "2026-08-01")
      T.eq(reversal.lines[1].account, "cash")
      T.eq(reversal.lines[1].amount.amount_minor, -10000)
      T.eq(reversal.lines[2].account, "revenue")
      T.eq(reversal.lines[2].amount.amount_minor, 10000)

      T.eq(#journal.list(j), 2)
      T.ok(journal.get(j, "e1") ~= nil)
    end)

    T.it("preserves the original line's rate on a multi-currency reversal", function()
      local j = journal.new("USD")
      local chart = account.new()
      account.add_account(chart, { id = "cash-usd", name = "Cash USD", type = "asset" })
      account.add_account(chart, { id = "cash-eur", name = "Cash EUR", type = "asset" })
      journal.post(j, chart, {
        date = "2026-07-26", description = "FX", id = "e1",
        lines = {
          { account = "cash-usd", amount = money.new("-100.00", "USD") },
          { account = "cash-eur", amount = money.new("92.00", "EUR"), rate = 1.0870 },
        },
      })

      local reversal, err = journal.void_entry(j, chart, "e1", "2026-08-01")
      T.ok(reversal ~= nil, err)
      T.eq(reversal.lines[2].amount.currency, "EUR")
      T.eq(reversal.lines[2].amount.amount_minor, -9200)
      T.eq(reversal.lines[2].rate, 1.0870)
    end)

    T.it("fails for an unknown entry id", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local reversal, err = journal.void_entry(j, chart, "nope", "2026-08-01")
      T.eq(reversal, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("delete_entry", function()
    T.it("removes the entry entirely", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      journal.post(j, chart, {
        date = "2026-07-26", description = "x", id = "e1",
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      })
      T.eq(#journal.list(j), 1)

      local ok, err = journal.delete_entry(j, "e1")
      T.ok(ok, err)
      T.eq(#journal.list(j), 0)
      T.eq(journal.get(j, "e1"), nil)
    end)

    T.it("preserves order of remaining entries", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      local opts = function(id)
        return {
          date = "2026-07-26", description = id, id = id,
          lines = {
            { account = "cash",    amount = money.new("1.00", "USD") },
            { account = "revenue", amount = money.new("-1.00", "USD") },
          },
        }
      end
      journal.post(j, chart, opts("a"))
      journal.post(j, chart, opts("b"))
      journal.post(j, chart, opts("c"))

      journal.delete_entry(j, "b")
      local list = journal.list(j)
      T.eq(#list, 2)
      T.eq(list[1].id, "a")
      T.eq(list[2].id, "c")
    end)

    T.it("fails for an unknown entry id", function()
      local j = journal.new("USD")
      local ok, err = journal.delete_entry(j, "nope")
      T.eq(ok, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("update_entry_description", function()
    T.it("updates the description without touching lines/amounts", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      journal.post(j, chart, {
        date = "2026-07-26", description = "old", id = "e1",
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      })

      local entry, err = journal.update_entry_description(j, "e1", "new description")
      T.ok(entry ~= nil, err)
      T.eq(entry.description, "new description")
      T.eq(journal.get(j, "e1").description, "new description")
      T.eq(#journal.get(j, "e1").lines, 2)
    end)

    T.it("fails for an unknown entry id", function()
      local j = journal.new("USD")
      local entry, err = journal.update_entry_description(j, "nope", "x")
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)

    T.it("rejects a non-string description", function()
      local j = journal.new("USD")
      local chart = usd_chart()
      journal.post(j, chart, {
        date = "2026-07-26", description = "old", id = "e1",
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      })
      local entry, err = journal.update_entry_description(j, "e1", 42 --[[: unknown ]])
      T.eq(entry, nil)
      T.ok(type(err) == "string")
    end)
  end)
end)
