if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local money   = require("lib.money")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")
local store   = require("lib.bookkeeping.store")

local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
  T.describe("lib.bookkeeping.store", function()
    T.it("lib.sqlite loaded", function()
      error("lib.sqlite failed to load: " .. tostring(sqlite))
    end)
  end)
  return
end

local function mem_db()
  local db, err = sqlite.open(":memory:")
  if not db then error("sqlite.open(:memory:) failed: " .. tostring(err)) end
  local ok, cerr = store.create_schema(db)
  if not ok then error("create_schema failed: " .. tostring(cerr)) end
  return db
end

local function full_chart()
  local chart = account.new()
  account.add_account(chart, { id = "cash",    name = "Cash",    type = "asset",
    code = "1000", description = "Operating cash account" })
  account.add_account(chart, { id = "bank",    name = "Bank",    type = "asset", parent = "cash" })
  account.add_account(chart, { id = "revenue", name = "Revenue", type = "revenue" })
  account.add_account(chart, { id = "rent",    name = "Rent",    type = "expense" })
  return chart
end

T.describe("lib.bookkeeping.store", function()

  T.describe("round trip", function()
    T.it("saves and loads an empty chart + journal", function()
      local db = mem_db()
      local chart = account.new()
      local j = journal.new("USD")

      local ok, err = store.save(db, chart, j)
      T.ok(ok, err)

      local loaded, lerr = store.load(db, "USD")
      T.ok(loaded ~= nil, lerr)
      T.eq(#account.list(loaded.chart), 0)
      T.eq(#journal.list(loaded.journal), 0)
      T.eq(loaded.journal.book_currency, "USD")
    end)

    T.it("saves and loads a chart with a parent/child account and descriptions/codes", function()
      local db = mem_db()
      local chart = full_chart()
      local j = journal.new("USD")

      local ok, err = store.save(db, chart, j)
      T.ok(ok, err)

      local loaded, lerr = store.load(db, "USD")
      T.ok(loaded ~= nil, lerr)

      local accounts = account.list(loaded.chart)
      T.eq(#accounts, 4)

      local cash = account.get(loaded.chart, "cash")
      T.ok(cash ~= nil)
      T.eq(cash.name, "Cash")
      T.eq(cash.type, "asset")
      T.eq(cash.code, "1000")
      T.eq(cash.description, "Operating cash account")
      T.eq(cash.parent, nil)

      local bank = account.get(loaded.chart, "bank")
      T.ok(bank ~= nil)
      T.eq(bank.parent, "cash")
    end)

    T.it("saves and loads posted single-currency entries", function()
      local db = mem_db()
      local chart = full_chart()
      local j = journal.new("USD")
      journal.post(j, chart, {
        date = "2026-01-01", description = "Client payment",
        lines = {
          { account = "cash",    amount = money.new("100.00", "USD") },
          { account = "revenue", amount = money.new("-100.00", "USD") },
        },
      })
      journal.post(j, chart, {
        date = "2026-01-05", description = "Rent",
        lines = {
          { account = "rent", amount = money.new("40.00", "USD") },
          { account = "cash", amount = money.new("-40.00", "USD") },
        },
      })

      local ok, err = store.save(db, chart, j)
      T.ok(ok, err)

      local loaded, lerr = store.load(db, "USD")
      T.ok(loaded ~= nil, lerr)

      local entries = journal.list(loaded.journal)
      T.eq(#entries, 2)
      T.eq(entries[1].date, "2026-01-01")
      T.eq(entries[1].description, "Client payment")
      T.eq(#entries[1].lines, 2)
      T.eq(entries[1].lines[1].amount.amount_minor, 10000)
      T.eq(entries[1].lines[1].amount.currency, "USD")
      T.eq(entries[2].date, "2026-01-05")
    end)

    T.it("saves and loads multi-currency entries with rates", function()
      local db = mem_db()
      local chart = full_chart()
      local j = journal.new("USD")
      journal.post(j, chart, {
        date = "2026-02-01", description = "EUR client payment",
        lines = {
          { account = "cash",    amount = money.new("100.00", "USD") },
          { account = "revenue", amount = money.new("-92.00", "EUR"), rate = 100 / 92 },
        },
      })

      local ok, err = store.save(db, chart, j)
      T.ok(ok, err)

      local loaded, lerr = store.load(db, "USD")
      T.ok(loaded ~= nil, lerr)

      local entries = journal.list(loaded.journal)
      T.eq(#entries, 1)
      local eur_line = entries[1].lines[2]
      T.eq(eur_line.amount.currency, "EUR")
      T.eq(eur_line.amount.amount_minor, -9200)
      T.ok(eur_line.rate ~= nil)
      T.eq(eur_line.book_amount.currency, "USD")
      T.eq(eur_line.book_amount.amount_minor, -10000)
    end)

    T.it("save is a full-snapshot replace, not incremental", function()
      local db = mem_db()
      local chart1 = account.new()
      account.add_account(chart1, { id = "cash", name = "Cash", type = "asset" })
      local j1 = journal.new("USD")
      store.save(db, chart1, j1)

      local chart2 = account.new()
      account.add_account(chart2, { id = "bank", name = "Bank", type = "asset" })
      local j2 = journal.new("USD")
      store.save(db, chart2, j2)

      local loaded, lerr = store.load(db, "USD")
      T.ok(loaded ~= nil, lerr)
      T.eq(#account.list(loaded.chart), 1)
      T.eq(account.get(loaded.chart, "cash"), nil)
      T.ok(account.get(loaded.chart, "bank") ~= nil)
    end)
  end)

  T.describe("load", function()
    T.it("revalidates entries: rejects an unbalanced row planted directly via SQL", function()
      local db = mem_db()
      local chart = account.new()
      account.add_account(chart, { id = "cash", name = "Cash", type = "asset" })
      account.add_account(chart, { id = "revenue", name = "Revenue", type = "revenue" })

      db:execute("INSERT INTO journal_entries (id, date, description, metadata) VALUES (?, ?, ?, ?);",
        "1", "2026-01-01", "broken", nil)
      db:execute(
        "INSERT INTO journal_lines (entry_id, account_id, amount_minor, currency, rate, book_amount_minor, book_currency) "
          .. "VALUES (?, ?, ?, ?, ?, ?, ?);",
        "1", "cash", 10000, "USD", nil, 10000, "USD")
      db:execute(
        "INSERT INTO journal_lines (entry_id, account_id, amount_minor, currency, rate, book_amount_minor, book_currency) "
          .. "VALUES (?, ?, ?, ?, ?, ?, ?);",
        "1", "revenue", -9900, "USD", nil, -9900, "USD")
      account.add_account(chart, { id = "_unused", name = "_unused", type = "asset" })
      -- accounts table wasn't populated via store.save for this test; insert directly too.
      db:execute("DELETE FROM accounts;")
      db:execute("INSERT INTO accounts (id, name, type, code, description, parent_id, metadata) VALUES (?, ?, ?, ?, ?, ?, ?);",
        "cash", "Cash", "asset", nil, nil, nil, nil)
      db:execute("INSERT INTO accounts (id, name, type, code, description, parent_id, metadata) VALUES (?, ?, ?, ?, ?, ?, ?);",
        "revenue", "Revenue", "revenue", nil, nil, nil, nil)

      local loaded, err = store.load(db, "USD")
      T.eq(loaded, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
