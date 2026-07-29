if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local actions     = require("lib.platform.apps.finance.actions")
local finance_init = require("lib.platform.apps.finance.init")

local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
  T.describe("lib.platform.apps.finance.actions", function()
    T.it("lib.sqlite loaded", function()
      error("lib.sqlite failed to load: " .. tostring(sqlite))
    end)
  end)
  return
end

--:: AppApi = {
--::   add_account: (unknown) -> (unknown | nil, string | nil),
--::   update_account: (string, unknown) -> (unknown | nil, string | nil),
--::   delete_account: (string) -> (true | nil, string | nil),
--::   list_accounts: () -> (unknown | nil, string | nil),
--::   list_entries: () -> (unknown | nil, string | nil),
--::   post_entry: (string, unknown) -> (unknown | nil, string | nil),
--::   void_entry: (string, string, string) -> (unknown | nil, string | nil),
--::   delete_entry: (string, string) -> (true | nil, string | nil),
--::   list_periods: () -> { [number]: { id: string, start_date: string, end_date: string } },
--::   add_period: (string, unknown) -> (true | nil, string | nil),
--::   set_active_period: (string) -> (true | nil, string | nil),
--::   active_period: () -> (string | nil),
--::   get_ledger: () -> (unknown | nil, string | nil),
--::   get_trial_balance: () -> (unknown | nil, string | nil),
--::   get_income_statement: (string, string) -> (unknown | nil, string | nil),
--::   get_balance_sheet: (string) -> (unknown | nil, string | nil),
--::   sync: () -> ({ [number]: string } | nil, string | nil),
--:: }

local function mem_db()
  local db, err = sqlite.open(":memory:")
  if not db then error("sqlite.open(:memory:) failed: " .. tostring(err)) end
  return db
end

--: () -> AppApi
local function new_app()
  local db = mem_db()
  local app, err = finance_init.new({ db = db, book_currency = "USD" })
  if type(app) ~= "table" then error("finance_init.new failed: " .. tostring(err)) end
  return app --[[: AppApi]]
end

T.describe("finance.actions", function()

  T.describe("account_form", function()
    T.it("adds a new account when the id doesn't exist yet", function()
      local app = new_app()
      local result = actions.perform("account_form", app, { id = "cash", name = "Cash", type = "asset", code = "", description = "", parent = "" })
      T.ok(result ~= nil)
      if result ~= nil then
        T.eq(result.ok, true)
        T.eq(result.view, "accounts")
      end
      local accounts = app.list_accounts()
      T.ok(type(accounts) == "table")
    end)

    T.it("updates an existing account instead of re-adding it", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      local result = actions.perform("account_form", app, { id = "cash", name = "Petty Cash", type = "asset", code = "", description = "", parent = "" })
      T.ok(result ~= nil)
      if result ~= nil then T.eq(result.ok, true) end
    end)

    T.it("rejects a missing name, keeping the submitted fields for re-render", function()
      local app = new_app()
      local result = actions.perform("account_form", app, { id = "cash", name = "", type = "asset" })
      T.ok(result ~= nil)
      if result ~= nil then
        T.eq(result.ok, false)
        T.eq(result.view, "account_form")
        T.ok(result.error ~= nil)
      end
    end)
  end)

  T.describe("account_delete", function()
    T.it("deletes an unreferenced account", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      local result = actions.perform("account_delete", app, { id = "cash" })
      T.ok(result ~= nil)
      if result ~= nil then T.eq(result.ok, true) end
    end)
  end)

  T.describe("period_form / period_activate", function()
    T.it("adds and activates a period", function()
      local app = new_app()
      local added = actions.perform("period_form", app, { id = "2026-Q3", start_date = "2026-07-01", end_date = "2026-09-30" })
      T.ok(added ~= nil)
      if added ~= nil then T.eq(added.ok, true) end

      local activated = actions.perform("period_activate", app, { id = "2026-Q3" })
      T.ok(activated ~= nil)
      if activated ~= nil then T.eq(activated.ok, true) end
      T.eq(app.active_period(), "2026-Q3")
    end)
  end)

  T.describe("post_entry / entry_void / entry_delete", function()
    local function setup(app)
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      app.add_account({ id = "equity", name = "Equity", type = "equity" })
      actions.perform("period_form", app, { id = "2026-Q3", start_date = "2026-07-01", end_date = "2026-09-30" })
    end

    T.it("posts a balanced entry from the fixed line fields, ignoring blank rows", function()
      local app = new_app()
      setup(app)
      local result = actions.perform("post_entry", app, {
        period_id = "2026-Q3", date = "2026-07-01", description = "contribution",
        line_account_1 = "cash", line_amount_1 = "100.00", line_currency_1 = "USD",
        line_account_2 = "equity", line_amount_2 = "-100.00", line_currency_2 = "USD",
        -- rows 3..8 intentionally left blank
      })
      T.ok(result ~= nil)
      if result ~= nil then
        T.eq(result.ok, true)
        T.eq(result.view, "entries")
      end
    end)

    T.it("rejects fewer than two non-blank lines", function()
      local app = new_app()
      setup(app)
      local result = actions.perform("post_entry", app, {
        period_id = "2026-Q3", date = "2026-07-01", description = "contribution",
        line_account_1 = "cash", line_amount_1 = "100.00", line_currency_1 = "USD",
      })
      T.ok(result ~= nil)
      if result ~= nil then
        T.eq(result.ok, false)
        T.eq(result.view, "post_entry")
      end
    end)

    T.it("voids and deletes a posted entry by period_id + id", function()
      local app = new_app()
      setup(app)
      actions.perform("post_entry", app, {
        period_id = "2026-Q3", date = "2026-07-01", description = "contribution",
        line_account_1 = "cash", line_amount_1 = "100.00", line_currency_1 = "USD",
        line_account_2 = "equity", line_amount_2 = "-100.00", line_currency_2 = "USD",
      })
      local entries = app.list_entries()
      T.ok(type(entries) == "table")
      if type(entries) == "table" then
        local list = entries --[[: { [number]: { period_id: string, entry: { id: string } } } ]]
        T.eq(#list, 1)
        local entry_id = list[1].entry.id

        local void_result = actions.perform("entry_void", app, { period_id = "2026-Q3", id = entry_id, void_date = "2026-07-15" })
        T.ok(void_result ~= nil)
        if void_result ~= nil then T.eq(void_result.ok, true) end

        local delete_result = actions.perform("entry_delete", app, { period_id = "2026-Q3", id = entry_id })
        T.ok(delete_result ~= nil)
        if delete_result ~= nil then T.eq(delete_result.ok, true) end
      end
    end)
  end)

  T.describe("perform", function()
    T.it("returns nil for an unknown action name", function()
      local app = new_app()
      local result = actions.perform("not_a_real_action", app, {})
      T.eq(result, nil)
    end)
  end)
end)
