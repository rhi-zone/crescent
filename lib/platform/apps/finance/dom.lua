if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Web (dom) frontend for the finance app: projects lib/platform/apps/finance
-- .views' View data to server-rendered HTML pages, and drives navigation/
-- form submission through lib/platform/apps/finance/init.lua's app API and
-- actions.lua's form-submission dispatch. tui.lua is the terminal
-- counterpart, projecting the exact same View data differently.
--
-- No client-side JavaScript, ever: every page is rendered and every action
-- processed on the server (see manifest.json's `dom` entry and this app's
-- architecture notes) -- client JS would run outside the platform's caps
-- sandbox with full webpage privileges, which is exactly the exfiltration
-- surface the caps model exists to close off. Forms POST back to this
-- server and the response is the next fully-rendered page, not a redirect
-- (a redirect-then-GET would need somewhere to stash a failed submission's
-- error/re-typed values across the redirect -- a flash-message mechanism
-- this app has no session/cookie cap wired up for -- so a failed POST
-- re-renders the target view directly, in the same response, instead).
--
-- HTML via plain string templates, not lib/html's nested element builders:
-- see TODO.md "`lib/html` doesn't typecheck for its own intended usage" --
-- lib/html has never had a real consumer, and both its own internal force
-- casts and its nominal Element<Content,Attrs> union types fail to
-- typecheck for ordinary nested composition. Only lib.html.escape (which
-- does work) is used here, for every piece of user-supplied text. Owner
-- decision (2026-07-30): ship this way now; migrate to lib.html once its
-- types are fixed, expected to be a refactor, not a redesign.
--
-- Caps: db (via init.lua), server (http_server) -- see manifest.json's dom
-- entry.

local html    = require("lib.html")
local web     = require("lib.web")
local views   = require("lib.platform.apps.finance.views")
local actions = require("lib.platform.apps.finance.actions")

local M = {}

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

-- Restated from views.lua's own declarations (typeof doesn't survive
-- require(), and these aliases aren't exported under a namespace -- same
-- reasoning bridge.lua/init.lua/tui.lua's own headers give for restating
-- each other's shapes). Every optional-looking field is genuinely optional
-- (`?`) here because different ViewSection *kinds* carry different subsets
-- of fields -- only `kind` itself is common to all of them.
--:: ViewField = { name: string, label: string, kind: string, value: string, options?: { [number]: { value: string, label: string } }, required?: boolean }
--:: ViewForm = { label: string, action: string, method: string, fields: { [number]: ViewField }, submit_label: string }
--:: ViewSection = { kind: string, label?: string, rows?: unknown, columns?: unknown, empty_text?: string, items?: unknown, form?: ViewForm, value?: string }
--:: View = { title: string, view: string, sections: { [number]: ViewSection }, error?: string, notice?: string }
--:: ViewSummaryRow = { label: string, value: string }
--:: ViewColumn = { key: string, label: string }
--:: ViewRow = { [string]: string }
--:: ViewNavItem = { label: string, view: string, params: { [string]: string } | nil }

--: (unknown) -> string
local function esc(s)
  if s == nil then return "" end
  if type(s) == "string" then return html.escape(s) end
  return html.escape(tostring(s))
end

-- ---------------------------------------------------------------------------
-- HTML string templates
-- ---------------------------------------------------------------------------

--: (string, string) -> string
local function nav_link(item_view, label)
  local path = views.routes[item_view] or "/"
  return '<a href="' .. esc(path) .. '">' .. esc(label) .. "</a>"
end

--: ViewField -> string
local function render_field(f)
  local input = "" --: string
  if f.kind == "select" then
    local opts = {} --: { [integer]: string }
    local options = f.options
    if options ~= nil then
      for i = 1, #options do
        local o = options[i]
        local selected = (o.value == f.value) and " selected" or ""
        opts[#opts + 1] = '<option value="' .. esc(o.value) .. '"' .. selected .. ">" .. esc(o.label) .. "</option>"
      end
    end
    input = '<select name="' .. esc(f.name) .. '">' .. table.concat(opts) .. "</select>"
  elseif f.kind == "hidden" then
    return '<input type="hidden" name="' .. esc(f.name) .. '" value="' .. esc(f.value) .. '" />'
  else
    local input_type = "text"
    if f.kind == "number" then input_type = "text" end -- plain text, not <input type=number>: money.from_string parses "-12.34" itself; no need for the browser's own numeric-stepper widget here
    if f.kind == "date" then input_type = "date" end
    input = '<input type="' .. esc(input_type) .. '" name="' .. esc(f.name) .. '" value="' .. esc(f.value) .. '" />'
  end
  return '<div class="field"><label>' .. esc(f.label) .. "<br />" .. input .. "</label></div>"
end

--: ViewForm -> string
local function render_form(form)
  local parts = {} --: { [integer]: string }
  parts[#parts + 1] = "<h3>" .. esc(form.label) .. "</h3>"
  parts[#parts + 1] = '<form action="' .. esc(views.routes[form.action] or "/") .. '" method="' .. esc(form.method) .. '">'
  for i = 1, #form.fields do
    parts[#parts + 1] = render_field(form.fields[i])
  end
  parts[#parts + 1] = '<button type="submit">' .. esc(form.submit_label) .. "</button>"
  parts[#parts + 1] = "</form>"
  return table.concat(parts)
end

--: ViewSection -> string
local function render_section(section)
  local parts = {} --: { [integer]: string }
  if section.label ~= nil then parts[#parts + 1] = "<h2>" .. esc(section.label) .. "</h2>" end

  if section.kind == "summary" then
    local raw_summary_rows = section.rows
    if type(raw_summary_rows) == "table" then
      local rows = raw_summary_rows --[[: { [number]: ViewSummaryRow } ]]
      parts[#parts + 1] = "<dl>"
      for i = 1, #rows do
        parts[#parts + 1] = "<dt>" .. esc(rows[i].label) .. "</dt><dd>" .. esc(rows[i].value) .. "</dd>"
      end
      parts[#parts + 1] = "</dl>"
    end
  elseif section.kind == "table" then
    local raw_rows = section.rows
    local raw_columns = section.columns
    if type(raw_rows) == "table" then
      local rows = raw_rows --[[: { [number]: ViewRow } ]]
      if #rows == 0 then
        parts[#parts + 1] = "<p>" .. esc(section.empty_text or "(none)") .. "</p>"
      elseif type(raw_columns) == "table" then
        local columns = raw_columns --[[: { [number]: ViewColumn } ]]
        parts[#parts + 1] = "<table><thead><tr>"
        for i = 1, #columns do parts[#parts + 1] = "<th>" .. esc(columns[i].label) .. "</th>" end
        parts[#parts + 1] = "</tr></thead><tbody>"
        for r = 1, #rows do
          parts[#parts + 1] = "<tr>"
          for i = 1, #columns do parts[#parts + 1] = "<td>" .. esc(rows[r][columns[i].key] or "") .. "</td>" end
          parts[#parts + 1] = "</tr>"
        end
        parts[#parts + 1] = "</tbody></table>"
      end
    end
  elseif section.kind == "nav" or section.kind == "actions" then
    local raw_items = section.items
    if type(raw_items) == "table" then
      local items = raw_items --[[: { [number]: ViewNavItem } ]]
      parts[#parts + 1] = "<ul>"
      for i = 1, #items do
        parts[#parts + 1] = "<li>" .. nav_link(items[i].view, items[i].label) .. "</li>"
      end
      parts[#parts + 1] = "</ul>"
    end
  elseif section.kind == "form" then
    local form = section.form
    if form ~= nil then parts[#parts + 1] = render_form(form) end
  elseif section.kind == "text" then
    if section.value ~= nil then parts[#parts + 1] = "<p>" .. esc(section.value) .. "</p>" end
  end
  return table.concat(parts)
end

--- Render a View to a full HTML document. Pure -- no I/O -- so it's
--- directly unit-testable.
--: View -> string
M.render_view = function(view)
  local body_parts = {} --: { [integer]: string }
  body_parts[#body_parts + 1] = "<h1>" .. esc(view.title) .. "</h1>"
  local notice = view.notice
  if notice ~= nil then body_parts[#body_parts + 1] = '<p class="notice">' .. esc(notice) .. "</p>" end
  local view_err = view.error
  if view_err ~= nil then body_parts[#body_parts + 1] = '<p class="error">' .. esc(view_err) .. "</p>" end
  for i = 1, #view.sections do
    body_parts[#body_parts + 1] = "<section>" .. render_section(view.sections[i]) .. "</section>"
  end

  return "<!doctype html><html><head><meta charset=\"utf-8\" />"
    .. "<title>" .. esc(view.title) .. " - Finance</title>"
    .. "</head><body>" .. table.concat(body_parts) .. "</body></html>"
end

-- ---------------------------------------------------------------------------
-- Form body parsing (application/x-www-form-urlencoded -- lib/web only
-- ships a JSON body parser; forms need this instead)
-- ---------------------------------------------------------------------------

--: (unknown) -> { [string]: string }
local function parse_form_body(body)
  if type(body) ~= "string" then return {} end
  return web.parse_query(body)
end

-- ---------------------------------------------------------------------------
-- Routing
-- ---------------------------------------------------------------------------

--:: WebQuery = { [string]: string }
--:: WebReq = { method: string, path: string, query?: WebQuery, params?: { [string]: string }, headers?: unknown, body?: unknown }
--:: WebRes = { status: integer, headers: { [string]: { [number]: string } }, body: string, html: (self: WebRes, string) -> WebRes }

-- lib/web's App is a metatable-based class (App:get/App:post/App:handle,
-- colon methods); require("lib.web")'s inferred module-return type doesn't
-- carry that method surface through cleanly (same class of gap as
-- lib/platform/apps/system_dashboard/server.lua's own `json = require(...)
-- --[[:! JsonMod]]` -- a required module's own declared shape, trusted once
-- at the require()/construction boundary rather than re-derived by
-- inference). Restated narrowly to just the methods this file calls.
--:: WebApp = {
--::   get: (self: WebApp, path: string, handler: (WebReq, WebRes) -> nil) -> WebApp,
--::   post: (self: WebApp, path: string, handler: (WebReq, WebRes) -> nil) -> WebApp,
--::   handle: (self: WebApp, req: { method: string, path: string, body?: unknown }) -> { status: integer, headers: { [string]: { [number]: string } }, body: string },
--:: }

--- Build the lib/web routing app for `app` (finance's app API). Exposed
--- separately from M.create so tests can drive routing directly (via
--- app_router:handle{...}) without a real http_server cap.
--: AppApi -> WebApp
M.build_router = function(app)
  local router = web.app() --[[: WebApp]]

  --: WebReq -> (WebQuery | nil)
  local function query_of(req)
    return req.query
  end

  router:get("/", function(_req, res)
    res:html(M.render_view(views.build("dashboard", app, nil, nil)))
  end)
  router:get("/accounts", function(_req, res)
    res:html(M.render_view(views.build("accounts", app, nil, nil)))
  end)
  router:get("/accounts/form", function(req, res)
    res:html(M.render_view(views.build("account_form", app, query_of(req), nil)))
  end)
  router:post("/accounts/form", function(req, res)
    local fields = parse_form_body(req.body)
    local result = actions.perform("account_form", app, fields)
    if result == nil then res.status = 404; res.body = "unknown action"; return end
    res:html(M.render_view(views.build(result.view, app, result.params, result.error)))
  end)
  router:post("/accounts/delete", function(req, res)
    local fields = parse_form_body(req.body)
    local result = actions.perform("account_delete", app, fields)
    if result == nil then res.status = 404; res.body = "unknown action"; return end
    res:html(M.render_view(views.build(result.view, app, result.params, result.error)))
  end)

  router:get("/periods", function(_req, res)
    res:html(M.render_view(views.build("periods", app, nil, nil)))
  end)
  router:post("/periods/form", function(req, res)
    local fields = parse_form_body(req.body)
    local result = actions.perform("period_form", app, fields)
    if result == nil then res.status = 404; res.body = "unknown action"; return end
    res:html(M.render_view(views.build(result.view, app, result.params, result.error)))
  end)
  router:post("/periods/activate", function(req, res)
    local fields = parse_form_body(req.body)
    local result = actions.perform("period_activate", app, fields)
    if result == nil then res.status = 404; res.body = "unknown action"; return end
    res:html(M.render_view(views.build(result.view, app, result.params, result.error)))
  end)

  router:get("/entries", function(_req, res)
    res:html(M.render_view(views.build("entries", app, nil, nil)))
  end)
  router:get("/entries/new", function(_req, res)
    res:html(M.render_view(views.build("post_entry", app, nil, nil)))
  end)
  router:post("/entries/new", function(req, res)
    local fields = parse_form_body(req.body)
    local result = actions.perform("post_entry", app, fields)
    if result == nil then res.status = 404; res.body = "unknown action"; return end
    res:html(M.render_view(views.build(result.view, app, result.params, result.error)))
  end)
  router:post("/entries/void", function(req, res)
    local fields = parse_form_body(req.body)
    local result = actions.perform("entry_void", app, fields)
    if result == nil then res.status = 404; res.body = "unknown action"; return end
    res:html(M.render_view(views.build(result.view, app, result.params, result.error)))
  end)
  router:post("/entries/delete", function(req, res)
    local fields = parse_form_body(req.body)
    local result = actions.perform("entry_delete", app, fields)
    if result == nil then res.status = 404; res.body = "unknown action"; return end
    res:html(M.render_view(views.build(result.view, app, result.params, result.error)))
  end)

  router:get("/reports", function(_req, res)
    res:html(M.render_view(views.build("reports", app, nil, nil)))
  end)
  router:get("/reports/trial_balance", function(_req, res)
    res:html(M.render_view(views.build("report_trial_balance", app, nil, nil)))
  end)
  router:get("/reports/income_statement", function(req, res)
    res:html(M.render_view(views.build("report_income_statement", app, query_of(req), nil)))
  end)
  router:get("/reports/balance_sheet", function(req, res)
    res:html(M.render_view(views.build("report_balance_sheet", app, query_of(req), nil)))
  end)

  return router
end

-- ---------------------------------------------------------------------------
-- Entrypoint: platform runner calls M.create(caps, opts), gets back a
-- {handler} the runner wires into the http_server cap (see lib/platform
-- /cli.lua: "if result.handler ... serve_cap.serve(result.handler)").
-- ---------------------------------------------------------------------------

local finance_init = require("lib.platform.apps.finance.init")

--:: HttpReq = { method: string, path: string, query?: string, headers?: unknown, body?: string | nil }
--:: HttpRes = { status: integer, headers: { [string]: unknown }, body: string | nil }

--- Adapts the http_server cap's raw req/res (path/query as separate
--- fields, query as an unparsed string) into lib/web's App:handle (which
--- expects the query string appended to `path`, and produces its own
--- {status,headers,body} shape -- happens to match the cap's res shape
--- exactly, both `{ [string]: { [number]: string } }`-valued headers, so
--- no further translation is needed on the way out).
--: (WebApp, HttpReq, HttpRes) -> ()
local function dispatch(router, req, res)
  local full_path = req.path
  local query = req.query
  if query ~= nil then full_path = full_path .. "?" .. query end
  local web_res = router:handle({ method = req.method, path = full_path, body = req.body })
  res.status = web_res.status
  res.headers = web_res.headers
  res.body = web_res.body
end

--: (unknown, unknown) -> ({ handler: (HttpReq, HttpRes) -> nil } | nil, string | nil)
M.create = function(caps, opts)
  if type(caps) ~= "table" then return nil, "finance.dom: caps must be a table" end
  local c = caps --[[: { db: unknown, server: unknown, ... } ]]
  local app, err = finance_init.create(c, opts)
  if type(app) ~= "table" then return nil, "finance.dom: " .. tostring(err) end

  local router = M.build_router(app --[[: AppApi]])

  --: (HttpReq, HttpRes) -> nil
  local function handler(req, res)
    dispatch(router, req, res)
  end

  return { handler = handler }
end

return M
