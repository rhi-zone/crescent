if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Shared form-submission -> app-mutation dispatch for the finance app's TUI
-- and dom (web) frontends. views.lua is the single source of truth for what
-- a form/action *looks like*; this file is the single source of truth for
-- what submitting one *does* -- neither frontend should re-derive "which
-- app function does the account_form action call" on its own, so this
-- logic lives here once instead of twice.
--
-- Every function here takes `app` (lib/platform/apps/finance/init.lua's
-- M.new/M.create return value) and a flat string->string field map (the
-- frontend's job is only to collect that map -- from parsed POST body
-- fields, or from a sequence of TUI prompts -- never to interpret it).

local views = require("lib.platform.apps.finance.views")

local M = {}

--:: AppApi = {
--::   add_account: (unknown) -> (unknown | nil, string | nil),
--::   update_account: (string, unknown) -> (unknown | nil, string | nil),
--::   delete_account: (string) -> (true | nil, string | nil),
--::   list_accounts: () -> (unknown | nil, string | nil),
--::   post_entry: (string, unknown) -> (unknown | nil, string | nil),
--::   void_entry: (string, string, string) -> (unknown | nil, string | nil),
--::   delete_entry: (string, string) -> (true | nil, string | nil),
--::   add_period: (string, unknown) -> (true | nil, string | nil),
--::   set_active_period: (string) -> (true | nil, string | nil),
--::   ...
--:: }

--:: Fields = { [string]: string }

-- What performing an action produced: either a view to redirect/re-render
-- (`ok`, `view`, `params` -- params carried so e.g. an edited account's id
-- can be echoed back if the caller wants it) or a validation/app-level
-- failure that the caller should re-render the *same* form with (`ok =
-- false`, `view` = the form's own view name, `error`, and `fields` handed
-- straight back so the user's input isn't lost).
--:: ActionResult = { ok: boolean, view: string, params?: Fields, error?: string, fields?: Fields }

--: (Fields, string) -> string | nil
local function non_empty(f, name)
  local v = f[name]
  if v == nil or v == "" then return nil end
  return v
end

--: string -> string | nil
local function nilable(s)
  if s == "" then return nil end
  return s
end

-- ---------------------------------------------------------------------------
-- Accounts: account_form (add-or-update, inferred from whether `id` already
-- names an existing account) and account_delete.
-- ---------------------------------------------------------------------------

--:: AccountRecord = { id: string, name: string, type: string, code: string | nil, description: string | nil, parent: string | nil }

--: (AppApi, string) -> boolean
local function account_exists(app, id)
  local accounts = app.list_accounts()
  if type(accounts) ~= "table" then return false end
  local list = accounts --[[: { [number]: AccountRecord } ]]
  for i = 1, #list do
    if list[i].id == id then return true end
  end
  return false
end

--: (AppApi, Fields) -> ActionResult
M.account_form = function(app, fields)
  local id = fields.id
  if id == nil or id == "" then
    return { ok = false, view = "account_form", error = "Account ID is required.", fields = fields }
  end
  local name = fields.name
  if name == nil or name == "" then
    return { ok = false, view = "account_form", error = "Account name is required.", fields = fields }
  end
  local acct_type = fields.type
  if acct_type == nil or acct_type == "" then
    return { ok = false, view = "account_form", error = "Account type is required.", fields = fields }
  end
  local data = {
    id = id, name = name, type = acct_type,
    code = nilable(fields.code or ""), description = nilable(fields.description or ""), parent = nilable(fields.parent or ""),
  }

  if account_exists(app, id) then
    local acct, err = app.update_account(id, { name = name, type = acct_type, code = data.code, description = data.description, parent = data.parent })
    if acct == nil then return { ok = false, view = "account_form", error = tostring(err), fields = fields } end
  else
    local acct, err = app.add_account(data)
    if acct == nil then return { ok = false, view = "account_form", error = tostring(err), fields = fields } end
  end
  return { ok = true, view = "accounts" }
end

--: (AppApi, Fields) -> ActionResult
M.account_delete = function(app, fields)
  local id = non_empty(fields, "id")
  if id == nil then
    return { ok = false, view = "accounts", error = "Account ID is required." }
  end
  local deleted, err = app.delete_account(id)
  if not deleted then
    return { ok = false, view = "accounts", error = tostring(err) }
  end
  return { ok = true, view = "accounts" }
end

-- ---------------------------------------------------------------------------
-- Periods: period_form (add), period_activate.
-- ---------------------------------------------------------------------------

--: (AppApi, Fields) -> ActionResult
M.period_form = function(app, fields)
  local id = non_empty(fields, "id")
  local start_date = non_empty(fields, "start_date")
  local end_date = non_empty(fields, "end_date")
  if id == nil or start_date == nil or end_date == nil then
    return { ok = false, view = "periods", error = "Period ID, start date, and end date are all required." }
  end
  local added, err = app.add_period(id, { start_date = start_date, end_date = end_date })
  if not added then
    return { ok = false, view = "periods", error = tostring(err) }
  end
  return { ok = true, view = "periods" }
end

--: (AppApi, Fields) -> ActionResult
M.period_activate = function(app, fields)
  local id = non_empty(fields, "id")
  if id == nil then
    return { ok = false, view = "periods", error = "Period ID is required." }
  end
  local set_ok, err = app.set_active_period(id)
  if not set_ok then
    return { ok = false, view = "periods", error = tostring(err) }
  end
  return { ok = true, view = "periods" }
end

-- ---------------------------------------------------------------------------
-- Entries: post_entry, entry_void, entry_delete.
-- ---------------------------------------------------------------------------

--:: WireLine = { account_id: string, amount: number, currency: string }

-- Parses the post-entry form's fixed line_account_N/line_amount_N/
-- line_currency_N fields (views.M.POST_ENTRY_LINE_ROWS of them) into
-- WireLine[], skipping any row where account_id or amount is blank -- a
-- static form (no client-side JS to add/remove rows) always renders every
-- row, so "blank row" is the only way a user leaves a line unused. Amount
-- is parsed as a plain Lua number (major units) rather than through
-- lib.money.from_string: bridge.post_entry's WireLine.amount is the
-- integer *minor*-unit amount (see bridge.lua's own header comment), so
-- this function would need the entry's currency's decimal count to convert
-- major -> minor correctly per line -- lib.money.new/from_string already do
-- exactly that conversion, so line-by-line conversion happens in
-- M.post_entry below (which has the per-line currency in scope), not here.
--: Fields -> { [number]: { account_id: string, amount_major: string, currency: string } }
local function parse_entry_lines(fields)
  local lines = {} --: { [number]: { account_id: string, amount_major: string, currency: string } }
  for i = 1, views.POST_ENTRY_LINE_ROWS do
    local account_id = non_empty(fields, "line_account_" .. i)
    local amount_major = non_empty(fields, "line_amount_" .. i)
    local currency = non_empty(fields, "line_currency_" .. i)
    if account_id ~= nil and amount_major ~= nil and currency ~= nil then
      lines[#lines + 1] = { account_id = account_id, amount_major = amount_major, currency = currency }
    end
  end
  return lines
end

local money = require("lib.money")

--: (AppApi, Fields) -> ActionResult
M.post_entry = function(app, fields)
  local period_id = non_empty(fields, "period_id")
  local date = non_empty(fields, "date")
  local description = non_empty(fields, "description")
  if period_id == nil or date == nil or description == nil then
    return { ok = false, view = "post_entry", error = "Period, date, and description are all required.", fields = fields }
  end

  local raw_lines = parse_entry_lines(fields)
  if #raw_lines < 2 then
    return { ok = false, view = "post_entry", error = "At least two journal lines are required.", fields = fields }
  end

  local wire_lines = {} --: { [number]: WireLine }
  for i = 1, #raw_lines do
    local rl = raw_lines[i]
    local amount, merr = money.from_string(rl.amount_major, rl.currency)
    if amount == nil then
      return { ok = false, view = "post_entry", error = "Line " .. i .. ": " .. tostring(merr), fields = fields }
    end
    wire_lines[i] = { account_id = rl.account_id, amount = amount.amount_minor, currency = rl.currency }
  end

  local entry, err = app.post_entry(period_id, { date = date, description = description, lines = wire_lines })
  if entry == nil then
    return { ok = false, view = "post_entry", error = tostring(err), fields = fields }
  end
  return { ok = true, view = "entries" }
end

--: (AppApi, Fields) -> ActionResult
M.entry_void = function(app, fields)
  local period_id = non_empty(fields, "period_id")
  local id = non_empty(fields, "id")
  local void_date = non_empty(fields, "void_date")
  if period_id == nil or id == nil or void_date == nil then
    return { ok = false, view = "entries", error = "Period ID, entry ID, and void date are all required." }
  end
  local reversing, err = app.void_entry(period_id, id, void_date)
  if reversing == nil then
    return { ok = false, view = "entries", error = tostring(err) }
  end
  return { ok = true, view = "entries" }
end

--: (AppApi, Fields) -> ActionResult
M.entry_delete = function(app, fields)
  local period_id = non_empty(fields, "period_id")
  local id = non_empty(fields, "id")
  if period_id == nil or id == nil then
    return { ok = false, view = "entries", error = "Period ID and entry ID are both required." }
  end
  local deleted, err = app.delete_entry(period_id, id)
  if not deleted then
    return { ok = false, view = "entries", error = tostring(err) }
  end
  return { ok = true, view = "entries" }
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

--:: ActionFn = (app: AppApi, fields: Fields) -> ActionResult

--: { [string]: ActionFn }
M.HANDLERS = {
  account_form = M.account_form,
  account_delete = M.account_delete,
  period_form = M.period_form,
  period_activate = M.period_activate,
  post_entry = M.post_entry,
  entry_void = M.entry_void,
  entry_delete = M.entry_delete,
}

--- Look up and run the handler for `action_name` (one of M.HANDLERS' keys,
--- always a views.routes key too). nil if `action_name` isn't a known
--- mutating action (the frontend should treat that as a routing error, not
--- silently no-op).
--: (string, AppApi, Fields) -> ActionResult | nil
M.perform = function(action_name, app, fields)
  local handler = M.HANDLERS[action_name]
  if handler == nil then return nil end
  return handler(app, fields)
end

return M
