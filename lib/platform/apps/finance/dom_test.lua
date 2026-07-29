if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local dom_app     = require("lib.platform.apps.finance.dom")
local views       = require("lib.platform.apps.finance.views")
local finance_init = require("lib.platform.apps.finance.init")

local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
  T.describe("lib.platform.apps.finance.dom", function()
    T.it("lib.sqlite loaded", function()
      error("lib.sqlite failed to load: " .. tostring(sqlite))
    end)
  end)
  return
end

--:: AppApi = {
--::   add_account: (unknown) -> (unknown | nil, string | nil),
--::   list_accounts: () -> (unknown | nil, string | nil),
--::   list_entries: () -> (unknown | nil, string | nil),
--::   post_entry: (string, unknown) -> (unknown | nil, string | nil),
--::   list_periods: () -> { [number]: { id: string, start_date: string, end_date: string } },
--::   add_period: (string, unknown) -> (true | nil, string | nil),
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

--:: WebApp = {
--::   get: (self: WebApp, path: string, handler: unknown) -> WebApp,
--::   post: (self: WebApp, path: string, handler: unknown) -> WebApp,
--::   handle: (self: WebApp, req: { method: string, path: string, body?: unknown }) -> { status: integer, headers: unknown, body: string },
--:: }

T.describe("finance.dom", function()

  T.describe("M.render_view", function()
    T.it("renders a title, no client-side script tags, and escapes user data", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash <script>", type = "asset" })
      local view = views.build("accounts", app, nil, nil)
      local html_out = dom_app.render_view(view)
      T.ok(html_out:find("<h1>Accounts</h1>", 1, true) ~= nil)
      T.ok(html_out:find("<script", 1, true) == nil, "must not contain a <script> tag anywhere")
      T.ok(html_out:find("Cash &lt;script&gt;", 1, true) ~= nil, "user data must be HTML-escaped")
    end)

    T.it("renders the error and notice lines when present", function()
      local app = new_app()
      local view = views.account_form(app, nil, nil, "something went wrong")
      local html_out = dom_app.render_view(view)
      T.ok(html_out:find('class="error"', 1, true) ~= nil)
      T.ok(html_out:find("something went wrong", 1, true) ~= nil)
    end)

    T.it("renders a form with an action pointing at views.routes", function()
      local app = new_app()
      local view = views.post_entry_form(app, nil)
      local html_out = dom_app.render_view(view)
      T.ok(html_out:find('action="' .. views.routes.post_entry .. '"', 1, true) ~= nil)
      T.ok(html_out:find('method="POST"', 1, true) ~= nil)
    end)

    T.it("renders table rows with escaped cell content", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      local view = views.accounts(app)
      local html_out = dom_app.render_view(view)
      T.ok(html_out:find("<td>cash</td>", 1, true) ~= nil)
      T.ok(html_out:find("<td>Cash</td>", 1, true) ~= nil)
    end)
  end)

  T.describe("M.build_router routing", function()
    T.it("GET / renders the dashboard", function()
      local app = new_app()
      local router = dom_app.build_router(app) --[[:! WebApp]]
      local res = router:handle({ method = "GET", path = "/" })
      T.eq(res.status, 200)
      T.ok(res.body:find("Finance", 1, true) ~= nil)
    end)

    T.it("GET /accounts renders the accounts list", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      local router = dom_app.build_router(app) --[[:! WebApp]]
      local res = router:handle({ method = "GET", path = "/accounts" })
      T.eq(res.status, 200)
      T.ok(res.body:find("<td>cash</td>", 1, true) ~= nil)
    end)

    T.it("POST /accounts/form adds an account and re-renders the accounts view", function()
      local app = new_app()
      local router = dom_app.build_router(app) --[[:! WebApp]]
      local body = "id=cash&name=Cash&type=asset&code=&description=&parent="
      local res = router:handle({ method = "POST", path = "/accounts/form", body = body })
      T.eq(res.status, 200)
      T.ok(res.body:find("Accounts", 1, true) ~= nil)
      local accounts = app.list_accounts()
      T.ok(type(accounts) == "table")
      if type(accounts) == "table" then
        local list = accounts --[[: { [number]: { id: string } } ]]
        T.eq(#list, 1)
      end
    end)

    T.it("POST /accounts/form with a missing name re-renders account_form with an error", function()
      local app = new_app()
      local router = dom_app.build_router(app) --[[:! WebApp]]
      local body = "id=cash&name=&type=asset"
      local res = router:handle({ method = "POST", path = "/accounts/form", body = body })
      T.eq(res.status, 200)
      T.ok(res.body:find('class="error"', 1, true) ~= nil)
    end)

    T.it("GET /reports/income_statement with no query shows only the date-range form", function()
      local app = new_app()
      local router = dom_app.build_router(app) --[[:! WebApp]]
      local res = router:handle({ method = "GET", path = "/reports/income_statement" })
      T.eq(res.status, 200)
      T.ok(res.body:find("Date Range", 1, true) ~= nil)
    end)

    T.it("GET /reports/income_statement with a query string computes the report", function()
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
      local router = dom_app.build_router(app) --[[:! WebApp]]
      local res = router:handle({ method = "GET", path = "/reports/income_statement?start_date=2026-07-01&end_date=2026-07-31" })
      T.eq(res.status, 200)
      T.ok(res.body:find("Net income", 1, true) ~= nil)
    end)

    T.it("POST /entries/void and /entries/delete round-trip through the router", function()
      local app = new_app()
      app.add_account({ id = "cash", name = "Cash", type = "asset" })
      app.add_account({ id = "equity", name = "Equity", type = "equity" })
      app.add_period("2026-Q3", { start_date = "2026-07-01", end_date = "2026-09-30" })
      app.post_entry("2026-Q3", {
        date = "2026-07-01", description = "contribution",
        lines = {
          { account_id = "cash", amount = 100, currency = "USD" },
          { account_id = "equity", amount = -100, currency = "USD" },
        },
      })
      local entries = app.list_entries()
      T.ok(type(entries) == "table")
      if type(entries) == "table" then
        local list = entries --[[: { [number]: { period_id: string, entry: { id: string } } } ]]
        local entry_id = list[1].entry.id

        local router = dom_app.build_router(app) --[[:! WebApp]]
        local void_res = router:handle({
          method = "POST", path = "/entries/void",
          body = "period_id=2026-Q3&id=" .. entry_id .. "&void_date=2026-07-15",
        })
        T.eq(void_res.status, 200)

        local delete_res = router:handle({
          method = "POST", path = "/entries/delete",
          body = "period_id=2026-Q3&id=" .. entry_id,
        })
        T.eq(delete_res.status, 200)
      end
    end)

    T.it("an unknown path 404s", function()
      local app = new_app()
      local router = dom_app.build_router(app) --[[:! WebApp]]
      local res = router:handle({ method = "GET", path = "/not-a-real-path" })
      T.eq(res.status, 404)
    end)
  end)

  T.describe("M.create", function()
    T.it("rejects a non-table caps argument", function()
      local result, err = dom_app.create("not a table", nil)
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns a handler once given a valid db cap", function()
      local db = mem_db()
      local result, err = dom_app.create({ db = db }, { book_currency = "USD" })
      T.ok(result ~= nil, err)
      if result ~= nil then
        T.ok(type(result.handler) == "function")
      end
    end)
  end)
end)
