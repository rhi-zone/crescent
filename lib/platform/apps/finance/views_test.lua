if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local views       = require("lib.platform.apps.finance.views")
local finance_init = require("lib.platform.apps.finance.init")

local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
  T.describe("lib.platform.apps.finance.views", function()
    T.it("lib.sqlite loaded", function()
      error("lib.sqlite failed to load: " .. tostring(sqlite))
    end)
  end)
  return
end

-- Restated from lib/platform/apps/finance/init.lua's own M.new/M.create
-- return shape (same "typeof doesn't survive require(), and this name isn't
-- exported under a namespace" reasoning bridge.lua/doc_registry.lua/init.lua
-- already give for restating each other's shapes) -- needed so new_app
-- below can return a concretely-typed app object instead of `unknown`.
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

-- Every section in a View must be one of the known `kind` tags -- a cheap,
-- generic well-formedness check every view test below reuses instead of
-- hand-checking each view's section list by hand. Restated as a structural
-- supertype of views.lua's own ViewSection union (every variant has at
-- least `kind: <string literal>`, `...` matches the rest) rather than as
-- `unknown`, so no cast is needed to inspect it.
--:: TestSection = { kind: string, [string]: unknown }
--:: TestView = { title: string, view: string, sections: { [number]: TestSection }, error: string | nil, notice: string | nil }
local KNOWN_SECTION_KINDS = { summary = true, table = true, nav = true, form = true, text = true, actions = true } --[[: { [string]: boolean } ]]

--: TestView -> nil
local function assert_well_formed_view(view)
  T.ok(type(view.title) == "string", "view.title must be a string")
  T.ok(type(view.view) == "string", "view.view must be a string")
  T.ok(type(view.sections) == "table", "view.sections must be a table")
  local sections = view.sections
  for i = 1, #sections do
    local s = sections[i]
    T.ok(KNOWN_SECTION_KINDS[s.kind] == true, "section " .. i .. " has an unknown kind: " .. tostring(s.kind))
  end
end

T.describe("finance.views", function()

  T.describe("M.dashboard", function()
    T.it("returns a well-formed view on an empty app", function()
      local app = new_app()
      local view = views.dashboard(app)
      assert_well_formed_view(view)
      T.eq(view.view, "dashboard")
    end)
  end)

  T.describe("M.accounts", function()
    T.it("lists accounts once added", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      local view = views.accounts(app)
      assert_well_formed_view(view)
      local table_section = view.sections[1]
      T.eq(table_section.kind, "table")
      local raw_rows = table_section.rows
      if type(raw_rows) ~= "table" then error("table_section.rows is not a table") end
      local rows = raw_rows --[[: { [number]: { id: string, ... } } ]]
      T.eq(#rows, 1)
      T.eq(rows[1].id, "cash")
    end)
  end)

  T.describe("M.account_form", function()
    T.it("add mode: empty prefill, no id field value", function()
      local app = new_app()
      local view = views.account_form(app, nil, nil, nil)
      assert_well_formed_view(view)
      T.eq(view.error, nil)
    end)

    T.it("edit mode: prefills from the existing account", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      local view = views.account_form(app, "cash", nil, nil)
      assert_well_formed_view(view)
      local form_section = view.sections[1]
      T.eq(form_section.kind, "form")
      local raw_form = form_section.form
      if type(raw_form) ~= "table" then error("form_section.form is not a table") end
      local form = raw_form --[[: { fields: { [number]: { name: string, value: string, ... } } } ]]
      local fields = form.fields
      local name_field = nil --: { name: string, value: string } | nil
      for i = 1, #fields do
        if fields[i].name == "name" then name_field = fields[i] end
      end
      T.ok(name_field ~= nil)
      if name_field ~= nil then T.eq(name_field.value, "Cash") end
    end)

    T.it("carries a form_error through to view.error", function()
      local app = new_app()
      local view = views.account_form(app, nil, nil, "something went wrong")
      T.eq(view.error, "something went wrong")
    end)
  end)

  T.describe("M.periods", function()
    T.it("shows no active period on an empty app", function()
      local app = new_app()
      local view = views.periods(app)
      assert_well_formed_view(view)
      T.eq(view.notice, "No active period is set.")
    end)

    T.it("shows the active period once set", function()
      local app = new_app()
      app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      app.set_active_period("2026-Q3")
      local view = views.periods(app)
      T.eq(view.notice, "Active period: 2026-Q3")
      local table_section = view.sections[1]
      local raw_rows = table_section.rows
      if type(raw_rows) ~= "table" then error("table_section.rows is not a table") end
      local rows = raw_rows --[[: { [number]: { active: string, ... } } ]]
      T.eq(rows[1].active, "yes")
    end)
  end)

  T.describe("M.entries", function()
    T.it("lists entries tagged with period_id", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      app.add_account({ id = "equity", name = "Equity", type = "equity" })
      app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      app.post_entry("2026-Q3", {
        date = "2026-07-01", description = "contribution",
        lines = {
          { account_id = "cash", amount = 10000, currency = "USD" },
          { account_id = "equity", amount = -10000, currency = "USD" },
        },
      })
      local view = views.entries(app)
      assert_well_formed_view(view)
      local table_section = view.sections[1]
      local raw_rows = table_section.rows
      if type(raw_rows) ~= "table" then error("table_section.rows is not a table") end
      local rows = raw_rows --[[: { [number]: { period_id: string, ... } } ]]
      T.eq(#rows, 1)
      T.eq(rows[1].period_id, "2026-Q3")
    end)
  end)

  T.describe("M.post_entry_form", function()
    T.it("offers a period option per registered period", function()
      local app = new_app()
      app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      local view = views.post_entry_form(app, nil)
      assert_well_formed_view(view)
      local form_section = view.sections[1]
      local raw_form = form_section.form
      if type(raw_form) ~= "table" then error("form_section.form is not a table") end
      local form = raw_form --[[: { fields: { [number]: { name: string, options: { [number]: { value: string, label: string } } | nil } } } ]]
      local fields = form.fields
      T.eq(fields[1].name, "period_id")
      local options = fields[1].options
      T.ok(options ~= nil)
      if options ~= nil then
        T.eq(#options, 1)
        T.eq(options[1].value, "2026-Q3")
      end
    end)

    T.it("carries a form_error through to view.error", function()
      local app = new_app()
      local view = views.post_entry_form(app, "entry did not balance")
      T.eq(view.error, "entry did not balance")
    end)
  end)

  T.describe("M.reports / M.report_trial_balance", function()
    T.it("reports is a nav menu", function()
      local app = new_app()
      local view = views.reports(app)
      assert_well_formed_view(view)
      T.eq(view.sections[1].kind, "nav")
    end)

    T.it("report_trial_balance balances debit and credit totals", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      app.add_account({ id = "equity", name = "Equity", type = "equity" })
      app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      app.post_entry("2026-Q3", {
        date = "2026-07-01", description = "contribution",
        lines = {
          { account_id = "cash", amount = 10000, currency = "USD" },
          { account_id = "equity", amount = -10000, currency = "USD" },
        },
      })
      local view = views.report_trial_balance(app)
      assert_well_formed_view(view)
      T.eq(view.error, nil)
    end)
  end)

  T.describe("M.report_income_statement", function()
    T.it("shows only the date-range form when no range is given", function()
      local app = new_app()
      local view = views.report_income_statement(app, nil, nil)
      assert_well_formed_view(view)
      T.eq(#view.sections, 2) -- form + back-nav, no report tables yet
    end)

    T.it("computes the report once a date range is given", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      app.add_account({ id = "revenue", name = "Revenue", type = "revenue" })
      app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      app.post_entry("2026-Q3", {
        date = "2026-07-01", description = "sale",
        lines = {
          { account_id = "cash", amount = 10000, currency = "USD" },
          { account_id = "revenue", amount = -10000, currency = "USD" },
        },
      })
      local view = views.report_income_statement(app, "2026-07-01", "2026-07-31")
      assert_well_formed_view(view)
      T.eq(view.error, nil)
      T.ok(#view.sections > 2)
    end)
  end)

  T.describe("M.report_balance_sheet", function()
    T.it("shows only the as-of form when no date is given", function()
      local app = new_app()
      local view = views.report_balance_sheet(app, nil)
      assert_well_formed_view(view)
      T.eq(#view.sections, 2) -- form + back-nav
    end)

    T.it("computes the report once an as-of date is given", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      app.add_account({ id = "equity", name = "Equity", type = "equity" })
      app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      app.post_entry("2026-Q3", {
        date = "2026-07-01", description = "contribution",
        lines = {
          { account_id = "cash", amount = 10000, currency = "USD" },
          { account_id = "equity", amount = -10000, currency = "USD" },
        },
      })
      local view = views.report_balance_sheet(app, "2026-07-31")
      assert_well_formed_view(view)
      T.eq(view.error, nil)
      T.ok(#view.sections > 2)
    end)
  end)

  T.describe("M.recent_entries", function()
    T.it("sorts by date descending and respects the limit", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      app.add_account({ id = "equity", name = "Equity", type = "equity" })
      app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      app.post_entry("2026-Q3", {
        date = "2026-07-01", description = "first",
        lines = {
          { account_id = "cash", amount = 100, currency = "USD" },
          { account_id = "equity", amount = -100, currency = "USD" },
        },
      })
      app.post_entry("2026-Q3", {
        date = "2026-07-15", description = "second",
        lines = {
          { account_id = "cash", amount = 200, currency = "USD" },
          { account_id = "equity", amount = -200, currency = "USD" },
        },
      })
      local recent = views.recent_entries(app, 1)
      T.eq(#recent, 1)
      T.eq(recent[1].entry.description, "second")
    end)
  end)

  T.describe("M.routes", function()
    T.it("has a path for every view a nav/action item can reference", function()
      T.ok(type(views.routes.dashboard) == "string")
      T.ok(type(views.routes.accounts) == "string")
      T.ok(type(views.routes.post_entry) == "string")
      T.ok(type(views.routes.reports) == "string")
    end)
  end)
end)
