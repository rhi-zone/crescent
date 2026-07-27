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

  T.describe("round trip (save/load)", function()
    T.it("saves and loads an empty chart + journal", function()
      local db = mem_db()
      local chart = account.new()
      local j = journal.new("USD")

      local ok, err = store.save(db, j, chart, "2026-01")
      T.ok(ok, err)

      local loaded_j, loaded_chart, book_currency, lerr = store.load(db)
      T.ok(loaded_j ~= nil, lerr)
      T.eq(#account.list(loaded_chart), 0)
      T.eq(#journal.list(loaded_j), 0)
      T.eq(book_currency, "USD")
    end)

    T.it("saves and loads a chart with a parent/child account and descriptions/codes", function()
      local db = mem_db()
      local chart = full_chart()
      local j = journal.new("USD")

      local ok, err = store.save(db, j, chart, "2026-01")
      T.ok(ok, err)

      local loaded_j, loaded_chart, book_currency, lerr = store.load(db)
      T.ok(loaded_j ~= nil, lerr)

      local accounts = account.list(loaded_chart)
      T.eq(#accounts, 4)

      local cash = account.get(loaded_chart, "cash")
      T.ok(cash ~= nil)
      T.eq(cash.name, "Cash")
      T.eq(cash.type, "asset")
      T.eq(cash.code, "1000")
      T.eq(cash.description, "Operating cash account")
      T.eq(cash.parent, nil)

      local bank = account.get(loaded_chart, "bank")
      T.ok(bank ~= nil)
      T.eq(bank.parent, "cash")
      T.eq(book_currency, "USD")
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

      local ok, err = store.save(db, j, chart, "2026-01")
      T.ok(ok, err)

      local loaded_j, _, _, lerr = store.load(db)
      T.ok(loaded_j ~= nil, lerr)

      local entries = journal.list(loaded_j)
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

      local ok, err = store.save(db, j, chart, "2026-02")
      T.ok(ok, err)

      local loaded_j, _, _, lerr = store.load(db)
      T.ok(loaded_j ~= nil, lerr)

      local entries = journal.list(loaded_j)
      T.eq(#entries, 1)
      local eur_line = entries[1].lines[2]
      T.eq(eur_line.amount.currency, "EUR")
      T.eq(eur_line.amount.amount_minor, -9200)
      T.ok(eur_line.rate ~= nil)
      T.eq(eur_line.book_amount.currency, "USD")
      T.eq(eur_line.book_amount.amount_minor, -10000)
    end)

    T.it("accounts are a full-snapshot replace across saves, not incremental", function()
      local db = mem_db()
      local chart1 = account.new()
      account.add_account(chart1, { id = "cash", name = "Cash", type = "asset" })
      local j1 = journal.new("USD")
      store.save(db, j1, chart1, "2026-01")

      local chart2 = account.new()
      account.add_account(chart2, { id = "bank", name = "Bank", type = "asset" })
      local j2 = journal.new("USD")
      store.save(db, j2, chart2, "2026-01")

      local _, loaded_chart, _, lerr = store.load(db)
      T.ok(loaded_chart ~= nil, lerr)
      T.eq(#account.list(loaded_chart), 1)
      T.eq(account.get(loaded_chart, "cash"), nil)
      T.ok(account.get(loaded_chart, "bank") ~= nil)
    end)

    T.it("rejects an empty period_id", function()
      local db = mem_db()
      local chart = account.new()
      local j = journal.new("USD")
      local ok, err = store.save(db, j, chart, "")
      T.eq(ok, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("load", function()
    T.it("revalidates entries: rejects an unbalanced row planted directly via SQL", function()
      local db = mem_db()
      local chart = account.new()
      account.add_account(chart, { id = "cash", name = "Cash", type = "asset" })
      account.add_account(chart, { id = "revenue", name = "Revenue", type = "revenue" })

      store.save_config(db, "USD")
      db:execute("INSERT INTO journal_entries (id, date, description, period_id, metadata) VALUES (?, ?, ?, ?, ?);",
        "1", "2026-01-01", "broken", "2026-01", nil)
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

      local loaded_j, _, _, err = store.load(db)
      T.eq(loaded_j, nil)
      T.ok(type(err) == "string")
    end)

    T.it("fails when the config table has no book_currency row", function()
      local db = mem_db()
      local loaded_j, loaded_chart, book_currency, err = store.load(db)
      T.eq(loaded_j, nil)
      T.eq(loaded_chart, nil)
      T.eq(book_currency, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("save_config / load_config", function()
    T.it("round-trips the book currency independent of save/load", function()
      local db = mem_db()
      local ok, err = store.save_config(db, "EUR")
      T.ok(ok, err)

      local currency, cerr = store.load_config(db)
      T.eq(currency, "EUR")
      T.eq(cerr, nil)
    end)

    T.it("upserts on a second call rather than erroring", function()
      local db = mem_db()
      store.save_config(db, "USD")
      local ok, err = store.save_config(db, "EUR")
      T.ok(ok, err)
      T.eq((store.load_config(db)), "EUR")
    end)

    T.it("rejects an unknown currency code", function()
      local db = mem_db()
      local ok, err = store.save_config(db, "XYZ")
      T.eq(ok, nil)
      T.ok(type(err) == "string")
    end)

    T.it("load_config fails when nothing has been saved", function()
      local db = mem_db()
      local currency, err = store.load_config(db)
      T.eq(currency, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("period_id round-trip / save_period / load_period", function()
    local function post_one(j, chart, id, date)
      journal.post(j, chart, {
        id = id, date = date, description = id,
        lines = {
          { account = "cash",    amount = money.new("1.00", "USD") },
          { account = "revenue", amount = money.new("-1.00", "USD") },
        },
      })
    end

    T.it("save scopes entries to the given period; other periods are untouched", function()
      local db = mem_db()
      local chart = full_chart()

      local j_jan = journal.new("USD")
      post_one(j_jan, chart, "jan-1", "2026-01-15")
      store.save(db, j_jan, chart, "2026-01")

      local j_feb = journal.new("USD")
      post_one(j_feb, chart, "feb-1", "2026-02-15")
      store.save(db, j_feb, chart, "2026-02")

      local all_j, _, _, err = store.load(db)
      T.ok(all_j ~= nil, err)
      T.eq(#journal.list(all_j), 2)

      local jan_j, _, _, jerr = store.load_period(db, "2026-01")
      T.ok(jan_j ~= nil, jerr)
      T.eq(#journal.list(jan_j), 1)
      T.eq(journal.list(jan_j)[1].id, "jan-1")

      local feb_j, _, _, ferr = store.load_period(db, "2026-02")
      T.ok(feb_j ~= nil, ferr)
      T.eq(#journal.list(feb_j), 1)
      T.eq(journal.list(feb_j)[1].id, "feb-1")
    end)

    T.it("re-saving a period replaces only that period's rows", function()
      local db = mem_db()
      local chart = full_chart()

      local j_jan_1 = journal.new("USD")
      post_one(j_jan_1, chart, "jan-1", "2026-01-15")
      store.save(db, j_jan_1, chart, "2026-01")

      local j_feb = journal.new("USD")
      post_one(j_feb, chart, "feb-1", "2026-02-15")
      store.save(db, j_feb, chart, "2026-02")

      -- Re-save January with different content.
      local j_jan_2 = journal.new("USD")
      post_one(j_jan_2, chart, "jan-2", "2026-01-20")
      store.save(db, j_jan_2, chart, "2026-01")

      local jan_j, _, _, jerr = store.load_period(db, "2026-01")
      T.ok(jan_j ~= nil, jerr)
      T.eq(#journal.list(jan_j), 1)
      T.eq(journal.list(jan_j)[1].id, "jan-2")

      local feb_j, _, _, ferr = store.load_period(db, "2026-02")
      T.ok(feb_j ~= nil, ferr)
      T.eq(#journal.list(feb_j), 1)
      T.eq(journal.list(feb_j)[1].id, "feb-1")
    end)

    T.it("save_period replaces entries without touching accounts or config", function()
      local db = mem_db()
      local chart = full_chart()
      local j = journal.new("USD")
      store.save(db, j, chart, "2026-01")

      -- Delete an account directly to prove save_period doesn't rewrite accounts.
      db:execute("DELETE FROM accounts WHERE id = 'rent';")

      local j2 = journal.new("USD")
      post_one(j2, chart, "e1", "2026-01-10")
      local ok, err = store.save_period(db, j2, chart, "2026-01")
      T.ok(ok, err)

      local _, loaded_chart, book_currency, lerr = store.load(db)
      T.ok(loaded_chart ~= nil, lerr)
      T.eq(account.get(loaded_chart, "rent"), nil)
      T.eq(#account.list(loaded_chart), 3)
      T.eq(book_currency, "USD")

      local jan_j, _, _, jerr = store.load_period(db, "2026-01")
      T.ok(jan_j ~= nil, jerr)
      T.eq(#journal.list(jan_j), 1)
    end)

    T.it("load_period returns an empty journal for a period with no entries", function()
      local db = mem_db()
      local chart = account.new()
      local j = journal.new("USD")
      store.save(db, j, chart, "2026-01")

      local empty_j, _, _, err = store.load_period(db, "2026-03")
      T.ok(empty_j ~= nil, err)
      T.eq(#journal.list(empty_j), 0)
    end)

    T.it("rejects an empty period_id on load_period", function()
      local db = mem_db()
      local j, chart, book_currency, err = store.load_period(db, "")
      T.eq(j, nil)
      T.eq(chart, nil)
      T.eq(book_currency, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
