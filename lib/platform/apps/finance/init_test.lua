if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local finance_init = require("lib.platform.apps.finance.init")

local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
  T.describe("lib.platform.apps.finance.init", function()
    T.it("lib.sqlite loaded", function()
      error("lib.sqlite failed to load: " .. tostring(sqlite))
    end)
  end)
  return
end

local function mem_db()
  local db, err = sqlite.open(":memory:")
  if not db then error("sqlite.open(:memory:) failed: " .. tostring(err)) end
  return db
end

T.describe("finance.init", function()

  T.describe("M.new", function()
    T.it("initializes with a db cap and a fresh (first-run) book_currency", function()
      local db = mem_db()
      local app, err = finance_init.new({ db = db, book_currency = "USD" })
      T.ok(app ~= nil, err)
      T.ok(type(app.add_account) == "function")
      T.ok(type(app.sync) == "function")
    end)

    T.it("fails on a fresh db with no book_currency given (first-run requires one)", function()
      local db = mem_db()
      local app, err = finance_init.new({ db = db })
      T.eq(app, nil)
      T.ok(type(err) == "string")
    end)

    T.it("on a db that already has book_currency configured, ignores opts.book_currency", function()
      local db = mem_db()
      local app1, err1 = finance_init.new({ db = db, book_currency = "EUR" })
      T.ok(app1 ~= nil, err1)

      local app2, err2 = finance_init.new({ db = db, book_currency = "USD" })
      T.ok(app2 ~= nil, err2)
      -- EUR (the db's existing config) should still be in effect: posting an
      -- entry in EUR should succeed without a currency mismatch.
      local acct, aerr = app2.add_account({ id = "cash", name = "Cash", type = "asset" })
      T.ok(acct ~= nil, aerr)
      local equity, eqerr = app2.add_account({ id = "equity", name = "Owner's Equity", type = "equity" })
      T.ok(equity ~= nil, eqerr)
      local entry, perr = app2.post_entry("2026-Q3", {
        date = "2026-07-01", description = "opening balance",
        lines = {
          { account_id = "cash",   amount = 100,  currency = "EUR" },
          { account_id = "equity", amount = -100, currency = "EUR" },
        },
      })
      T.ok(entry ~= nil, perr)
    end)

    T.it("uses a given client_id instead of generating one", function()
      local db = mem_db()
      local app, err = finance_init.new({ db = db, book_currency = "USD", client_id = 42 })
      T.ok(app ~= nil, err)
    end)
  end)

  T.describe("full lifecycle", function()
    T.it("init -> add account -> add period -> post entry -> query report", function()
      local db = mem_db()
      local app, err = finance_init.new({ db = db, book_currency = "USD" })
      T.ok(app ~= nil, err)

      local cash, cerr = app.add_account({ id = "cash", name = "Cash", type = "asset" })
      T.ok(cash ~= nil, cerr)
      local equity, eerr = app.add_account({ id = "equity", name = "Owner's Equity", type = "equity" })
      T.ok(equity ~= nil, eerr)

      local accounts, laerr = app.list_accounts()
      T.ok(accounts ~= nil, laerr)
      T.eq(#accounts, 2)

      local period_ok, perr = app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      T.ok(period_ok, perr)
      local active_ok, acerr = app.set_active_period("2026-Q3")
      T.ok(active_ok, acerr)

      local periods = app.list_periods()
      T.eq(#periods, 1)
      T.eq(periods[1].id, "2026-Q3")

      local entry, entry_err = app.post_entry("2026-Q3", {
        date = "2026-07-01",
        description = "owner contribution",
        lines = {
          { account_id = "cash",   amount = 10000,  currency = "USD" },
          { account_id = "equity", amount = -10000, currency = "USD" },
        },
      })
      T.ok(entry ~= nil, entry_err)

      local tb, tberr = app.get_trial_balance()
      T.ok(tb ~= nil, tberr)

      local ledger, lerr = app.get_ledger()
      T.ok(ledger ~= nil, lerr)

      local sheet, serr = app.get_balance_sheet("2026-09-30")
      T.ok(sheet ~= nil, serr)
    end)
  end)

  T.describe("M.sync", function()
    T.it("is inert (no-op transport): succeeds without reaching a peer", function()
      local db = mem_db()
      local app, err = finance_init.new({ db = db, book_currency = "USD" })
      T.ok(app ~= nil, err)

      local sent_ids, serr = app.sync()
      T.ok(sent_ids ~= nil, serr)
      T.eq(sent_ids[1], "accounts")
    end)
  end)

  T.describe("M.create", function()
    T.it("builds the app from a caps table (caps.db)", function()
      local db = mem_db()
      local app, err = finance_init.create({ db = db }, { book_currency = "USD" })
      T.ok(app ~= nil, err)
      T.ok(type(app.add_account) == "function")
    end)

    T.it("rejects a non-table caps argument", function()
      local app, err = finance_init.create(nil, {})
      T.eq(app, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
