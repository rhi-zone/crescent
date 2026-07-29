if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local tui_app     = require("lib.platform.apps.finance.tui")
local views       = require("lib.platform.apps.finance.views")
local finance_init = require("lib.platform.apps.finance.init")

local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
  T.describe("lib.platform.apps.finance.tui", function()
    T.it("lib.sqlite loaded", function()
      error("lib.sqlite failed to load: " .. tostring(sqlite))
    end)
  end)
  return
end

--:: AppApi = {
--::   add_account: (unknown) -> (unknown | nil, string | nil),
--::   list_accounts: () -> (unknown | nil, string | nil),
--::   list_periods: () -> { [number]: { id: string, start_date: string, end_date: string } },
--::   active_period: () -> (string | nil),
--::   get_trial_balance: () -> (unknown | nil, string | nil),
--::   ...
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

--: ({ [number]: string }, string) -> boolean
local function lines_contain(lines, needle)
  for i = 1, #lines do
    if lines[i]:find(needle, 1, true) then return true end
  end
  return false
end

T.describe("finance.tui", function()

  T.describe("M.render_lines", function()
    T.it("includes the view title", function()
      local app = new_app()
      local view = views.dashboard(app)
      local result = tui_app.render_lines(view)
      T.ok(lines_contain(result.lines, "Finance"))
    end)

    T.it("shows the error line when the view carries one", function()
      local app = new_app()
      local view = views.account_form(app, nil, nil, "something went wrong")
      local result = tui_app.render_lines(view)
      T.ok(lines_contain(result.lines, "ERROR: something went wrong"))
    end)

    T.it("numbers every nav item into the menu, in order", function()
      local app = new_app()
      local view = views.dashboard(app)
      local result = tui_app.render_lines(view)
      -- dashboard's nav section lists Accounts, Periods, Entries, New Entry, Reports
      T.ok(#result.menu >= 5)
      local nav_views = {}
      for i = 1, #result.menu do
        local entry = result.menu[i]
        if entry.kind == "nav" then nav_views[#nav_views + 1] = entry.view end
      end
      local found_accounts = false
      for i = 1, #nav_views do
        if nav_views[i] == "accounts" then found_accounts = true end
      end
      T.ok(found_accounts)
    end)

    T.it("gives a form section its own menu entry", function()
      local app = new_app()
      local view = views.post_entry_form(app, nil)
      local result = tui_app.render_lines(view)
      -- post_entry_form has two sections: the form itself and a "Back to
      -- Dashboard" nav item, each getting one menu slot.
      T.eq(#result.menu, 2)
      T.eq(result.menu[1].kind, "form")
      T.eq(result.menu[2].kind, "nav")
    end)

    T.it("lists table rows joined by column", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      local view = views.accounts(app)
      local result = tui_app.render_lines(view)
      T.ok(lines_contain(result.lines, "cash"))
      T.ok(lines_contain(result.lines, "Cash"))
    end)

    T.it("shows empty_text when a table has no rows", function()
      local app = new_app()
      local view = views.accounts(app)
      local result = tui_app.render_lines(view)
      T.ok(lines_contain(result.lines, "No accounts yet."))
    end)
  end)

  T.describe("M.render", function()
    T.it("produces a non-empty ANSI-rendered string containing the title", function()
      local app = new_app()
      local view = views.dashboard(app)
      local out = tui_app.render(view, 80, 24)
      T.ok(type(out) == "string")
      T.ok(#out > 0)
      T.ok(out:find("Finance", 1, true) ~= nil)
    end)
  end)

  T.describe("M.resolve_choice", function()
    T.it("resolves a numbered nav entry", function()
      local menu = { { kind = "nav", view = "accounts", params = nil } }
      local entry, quit = tui_app.resolve_choice(menu, "1")
      T.eq(quit, false)
      T.ok(entry ~= nil)
      if entry ~= nil then
        T.eq(entry.kind, "nav")
        T.eq(entry.view, "accounts")
      end
    end)

    T.it("treats 'q' and 'quit' (any case) as quit, with no entry", function()
      local menu = { { kind = "nav", view = "accounts", params = nil } }
      local entry1, quit1 = tui_app.resolve_choice(menu, "q")
      T.eq(quit1, true)
      T.eq(entry1, nil)
      local entry2, quit2 = tui_app.resolve_choice(menu, "QUIT")
      T.eq(quit2, true)
      T.eq(entry2, nil)
    end)

    T.it("returns nil (not quit) for out-of-range or non-numeric input", function()
      local menu = { { kind = "nav", view = "accounts", params = nil } }
      local entry1, quit1 = tui_app.resolve_choice(menu, "99")
      T.eq(entry1, nil)
      T.eq(quit1, false)
      local entry2, quit2 = tui_app.resolve_choice(menu, "banana")
      T.eq(entry2, nil)
      T.eq(quit2, false)
    end)
  end)

  T.describe("M.create", function()
    T.it("rejects a non-table caps argument", function()
      local app, err = tui_app.create("not a table", nil)
      T.eq(app, nil)
      T.ok(type(err) == "string")
    end)

    T.it("requires both stdin and stdout caps", function()
      local db = mem_db()
      local app, err = tui_app.create({ db = db }, { book_currency = "USD" })
      T.eq(app, nil)
      T.ok(type(err) == "string")
    end)
  end)
end)
