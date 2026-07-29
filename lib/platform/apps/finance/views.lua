if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- View layer for the finance app's TUI and dom (web) frontends: defines
-- what each screen shows as plain data, never how to render it. tui.lua
-- projects a View to lib/tui widgets; dom.lua projects the same View to
-- lib/html elements. Neither frontend should ever need a piece of
-- information this file didn't put in the View -- if a renderer needs
-- something the View doesn't carry, the fix is to enrich the View, not to
-- have the renderer reach around this file into the app API itself.
--
-- Every function here takes `app` -- the object returned by
-- lib/platform/apps/finance/init.lua's M.new/M.create (add_account,
-- list_accounts, post_entry, list_periods, get_trial_balance, ... -- see
-- that file for the full surface) -- never lib.platform.apps.finance.bridge
-- directly. This module has no I/O of its own beyond calling `app`.

local money = require("lib.money")

local M = {}

-- ---------------------------------------------------------------------------
-- View schema
-- ---------------------------------------------------------------------------
--
--:: FieldKind = "text" | "number" | "date" | "select" | "hidden" | "textarea"
--:: FieldOption = { value: string, label: string }
--:: ViewField = { name: string, label: string, kind: FieldKind, value: string, options?: { [number]: FieldOption }, required?: boolean }
--:: ViewForm = { label: string, action: string, method: string, fields: { [number]: ViewField }, submit_label: string }
--:: ViewColumn = { key: string, label: string }
--:: ViewRow = { [string]: string }
--:: ViewNavItem = { label: string, view: string, params?: { [string]: string } }
--:: ViewActionItem = { label: string, view: string, params?: { [string]: string }, method: string, confirm?: boolean }
--:: ViewSummaryRow = { label: string, value: string }
--
--:: ViewSection = (
--::     { kind: "summary", label: string, rows: { [number]: ViewSummaryRow } }
--::   | { kind: "table", label: string, columns: { [number]: ViewColumn }, rows: { [number]: ViewRow }, empty_text?: string }
--::   | { kind: "nav", items: { [number]: ViewNavItem } }
--::   | { kind: "form", form: ViewForm }
--::   | { kind: "text", label?: string, value: string }
--::   | { kind: "actions", items: { [number]: ViewActionItem } }
--:: )
--
--:: View = { title: string, view: string, sections: { [number]: ViewSection }, error?: string, notice?: string }

-- Every view name this module knows how to build, and the path a
-- server-rendered frontend (dom.lua) serves it at. Single source of truth
-- for routing so dom.lua never invents its own name -> path mapping;
-- tui.lua doesn't need paths at all (it dispatches on the view name
-- directly), so it ignores this table.
--: { [string]: string }
M.routes = {
  dashboard              = "/",
  accounts               = "/accounts",
  account_form           = "/accounts/form",
  account_delete         = "/accounts/delete",
  periods                = "/periods",
  period_form            = "/periods/form",
  period_activate        = "/periods/activate",
  entries                = "/entries",
  post_entry             = "/entries/new",
  entry_void             = "/entries/void",
  entry_delete           = "/entries/delete",
  reports                = "/reports",
  report_trial_balance   = "/reports/trial_balance",
  report_income_statement = "/reports/income_statement",
  report_balance_sheet   = "/reports/balance_sheet",
}

-- Number of blank journal-line rows the post-entry form offers. A static
-- form (this app renders no client-side JS -- see docs/overview.md's
-- security rationale) needs a fixed row count; blank rows are simply
-- ignored on submit (see dom.lua/tui.lua's shared line-parsing helper).
M.POST_ENTRY_LINE_ROWS = 8

-- ---------------------------------------------------------------------------
-- Formatting helpers (shared by both renderers via the View data itself --
-- these run here so tui.lua/dom.lua never format a money_value themselves)
-- ---------------------------------------------------------------------------

--:: MoneyValue = { amount_minor: number, currency: string }

--: MoneyValue -> string
local function fmt_money(mv)
  local ok, s = pcall(money.format, mv)
  if ok and type(s) == "string" then return s end
  return tostring(mv.amount_minor) .. " " .. mv.currency
end
M.fmt_money = fmt_money

--: unknown -> string
local function fmt(v)
  if v == nil then return "" end
  if type(v) == "string" then return v end
  return tostring(v)
end

-- View's `error`/`notice` fields are optional (`?: string`), which this
-- checker's optional fields accept being *absent*, not being *present with
-- a nilable value* (same rule this codebase's BridgeOpts/DocOpts-style
-- helpers document elsewhere) -- so a `string | nil`-typed local cannot be
-- assigned directly into `view.error = maybe_err` at construction time.
-- Setting it after construction, guarded by an explicit nil check that
-- narrows the local to `string`, satisfies the optional field instead.
--: (View, string | nil) -> ()
local function set_error(view, err)
  if err ~= nil then view.error = err end
end
M.set_error = set_error

-- ---------------------------------------------------------------------------
-- Account type options (shared by the account form)
-- ---------------------------------------------------------------------------

--: { [number]: FieldOption }
local ACCOUNT_TYPE_OPTIONS = {
  { value = "asset",     label = "Asset" },
  { value = "liability", label = "Liability" },
  { value = "equity",    label = "Equity" },
  { value = "revenue",   label = "Revenue" },
  { value = "expense",   label = "Expense" },
}

-- ---------------------------------------------------------------------------
-- Dashboard
-- ---------------------------------------------------------------------------

--:: AppApi = {
--::   list_accounts: () -> (unknown | nil, string | nil),
--::   list_entries: () -> (unknown | nil, string | nil),
--::   list_periods: () -> { [number]: { id: string, start_date: string, end_date: string } },
--::   active_period: () -> (string | nil),
--::   get_trial_balance: () -> (unknown | nil, string | nil),
--::   get_income_statement: (string, string) -> (unknown | nil, string | nil),
--::   get_balance_sheet: (string) -> (unknown | nil, string | nil),
--::   ...
--:: }

-- The most recent entries across every period, flattened from
-- app.list_entries() and sorted by date descending. `limit` caps how many
-- rows come back (dashboard wants a handful; other callers may want more).
--:: TrialBalanceRow = { account_id: string, name: string, type: string, balance: MoneyValue, debit: MoneyValue | nil, credit: MoneyValue | nil }
--:: TrialBalance = { book_currency: string, rows: { [number]: TrialBalanceRow }, total_debit: MoneyValue, total_credit: MoneyValue }
--:: JournalLine = { account: string, amount: MoneyValue, rate: number | nil, book_amount: MoneyValue }
--:: JournalEntry = { id: string, date: string, description: string, lines: { [number]: JournalLine } }
--:: EntryRecord = { period_id: string, entry: JournalEntry }
--: (AppApi, integer) -> { [number]: EntryRecord }
local function recent_entries(app, limit)
  local raw, err = app.list_entries()
  if raw == nil then return {} end
  if type(raw) ~= "table" then return {} end
  local records = raw --[[: { [number]: EntryRecord } ]]

  -- Selection sort for the top `limit` by date descending -- entry counts
  -- in a personal finance app are small enough that O(n*limit) is fine and
  -- this avoids pulling in a generic sort dependency for one call site.
  local n = #records
  local picked = {} --: { [number]: EntryRecord }
  local used = {} --: { [number]: boolean }
  local want = limit
  if want > n then want = n end
  for _ = 1, want do
    local best_i = nil --: integer | nil
    for i = 1, n do
      if not used[i] then
        if best_i == nil then
          best_i = i
        else
          local best = records[best_i]
          local cur = records[i]
          if cur.entry.date > best.entry.date then best_i = i end
        end
      end
    end
    if best_i == nil then break end
    used[best_i] = true
    picked[#picked + 1] = records[best_i]
  end
  return picked
end
M.recent_entries = recent_entries

--: (AppApi) -> View
M.dashboard = function(app)
  local tb, tb_err = app.get_trial_balance()
  local summary_rows = {} --: { [number]: ViewSummaryRow }
  if type(tb) ~= "table" then
    summary_rows[1] = { label = "error", value = fmt(tb_err) }
  else
    local tb_t = tb --[[: TrialBalance ]]
    summary_rows[1] = { label = "Total debits", value = fmt_money(tb_t.total_debit) }
    summary_rows[2] = { label = "Total credits", value = fmt_money(tb_t.total_credit) }
    summary_rows[3] = { label = "Accounts", value = tostring(#tb_t.rows) }
  end

  local recent = recent_entries(app, 8)
  local entry_rows = {} --: { [number]: ViewRow }
  for i = 1, #recent do
    local rec = recent[i]
    entry_rows[i] = {
      date = rec.entry.date,
      description = rec.entry.description,
      period = rec.period_id,
    }
  end

  return {
    title = "Finance",
    view = "dashboard",
    sections = {
      { kind = "summary", label = "Trial Balance", rows = summary_rows },
      {
        kind = "table", label = "Recent Entries",
        columns = { { key = "date", label = "Date" }, { key = "description", label = "Description" }, { key = "period", label = "Period" } },
        rows = entry_rows, empty_text = "No entries posted yet.",
      },
      {
        kind = "nav",
        items = {
          { label = "Accounts", view = "accounts" },
          { label = "Periods", view = "periods" },
          { label = "Entries", view = "entries" },
          { label = "New Entry", view = "post_entry" },
          { label = "Reports", view = "reports" },
        },
      },
    },
  }
end

-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------

--:: Account = { id: string, name: string, type: string, code: string | nil, description: string | nil, parent: string | nil }

--: (AppApi) -> View
M.accounts = function(app)
  local accounts, err = app.list_accounts()
  local rows = {} --: { [number]: ViewRow }
  local view_error = nil --: string | nil
  if accounts == nil then
    view_error = fmt(err)
  elseif type(accounts) == "table" then
    local list = accounts --[[: { [number]: Account } ]]
    for i = 1, #list do
      local a = list[i]
      rows[i] = {
        id = a.id, name = a.name, type = a.type,
        code = fmt(a.code), parent = fmt(a.parent),
      }
    end
  end

  local view = {
    title = "Accounts",
    view = "accounts",
    sections = {
      {
        kind = "table", label = "Chart of Accounts",
        columns = {
          { key = "id", label = "ID" }, { key = "name", label = "Name" },
          { key = "type", label = "Type" }, { key = "code", label = "Code" },
          { key = "parent", label = "Parent" },
        },
        rows = rows, empty_text = "No accounts yet.",
      },
      {
        kind = "actions",
        items = {
          { label = "Add Account", view = "account_form", method = "GET" },
        },
      },
      {
        kind = "nav",
        items = { { label = "Back to Dashboard", view = "dashboard" } },
      },
    },
  } --: View
  set_error(view, view_error)
  return view
end

-- Add/edit form for a single account. `account_id` nil = "add" mode;
-- otherwise the account's current fields prefill the form (edit mode).
-- `prefill`/`form_error` let a rejected submission re-render the form with
-- whatever the user typed plus the rejection reason, instead of losing
-- their input.
--: (AppApi, string | nil, { name: string, type: string, code: string, description: string, parent: string } | nil, string | nil) -> View
M.account_form = function(app, account_id, prefill, form_error)
  local editing = account_id ~= nil
  local values = prefill
  if values == nil and editing then
    local accounts = app.list_accounts()
    if type(accounts) == "table" then
      local list = accounts --[[: { [number]: Account } ]]
      for i = 1, #list do
        if list[i].id == account_id then
          local a = list[i]
          values = { name = a.name, type = a.type, code = fmt(a.code), description = fmt(a.description), parent = fmt(a.parent) }
          break
        end
      end
    end
  end
  if values == nil then
    values = { name = "", type = "asset", code = "", description = "", parent = "" }
  end
  local v = values --[[: { name: string, type: string, code: string, description: string, parent: string } ]]

  local fields = {} --: { [number]: ViewField }
  fields[1] = { name = "id", label = "ID", kind = editing and "hidden" or "text", value = account_id or "", required = true }
  fields[2] = { name = "name", label = "Name", kind = "text", value = v.name, required = true }
  fields[3] = { name = "type", label = "Type", kind = "select", value = v.type, options = ACCOUNT_TYPE_OPTIONS, required = true }
  fields[4] = { name = "code", label = "Code", kind = "text", value = v.code }
  fields[5] = { name = "description", label = "Description", kind = "text", value = v.description }
  fields[6] = { name = "parent", label = "Parent account ID", kind = "text", value = v.parent }

  local view = {
    title = editing and ("Edit Account: " .. tostring(account_id)) or "Add Account",
    view = "account_form",
    sections = {
      {
        kind = "form",
        form = {
          label = editing and "Edit Account" or "Add Account",
          action = "account_form", method = "POST",
          fields = fields, submit_label = editing and "Save" or "Add",
        },
      },
      { kind = "nav", items = { { label = "Back to Accounts", view = "accounts" } } },
    },
  } --: View
  set_error(view, form_error)
  return view
end

-- ---------------------------------------------------------------------------
-- Periods
-- ---------------------------------------------------------------------------

--:: PeriodEntry = { id: string, start_date: string, end_date: string }

--: (AppApi) -> View
M.periods = function(app)
  local periods = app.list_periods()
  local active = app.active_period()
  local rows = {} --: { [number]: ViewRow }
  if type(periods) == "table" then
    local list = periods --[[: { [number]: PeriodEntry } ]]
    for i = 1, #list do
      local p = list[i]
      rows[i] = {
        id = p.id, start_date = p.start_date, end_date = p.end_date,
        active = (active ~= nil and p.id == active) and "yes" or "",
      }
    end
  end

  -- Short-circuit "or" does not narrow `active` for its own right-hand
  -- operand in this checker (same confirmed behavior journal.lua's own
  -- entry_is_new comment documents), so the notice text is built via an
  -- explicit if/else rather than a ternary-style expression.
  local notice = "" --: string
  if active == nil then
    notice = "No active period is set."
  else
    notice = "Active period: " .. active
  end

  return {
    title = "Periods",
    view = "periods",
    notice = notice,
    sections = {
      {
        kind = "table", label = "Periods",
        columns = {
          { key = "id", label = "ID" }, { key = "start_date", label = "Start" },
          { key = "end_date", label = "End" }, { key = "active", label = "Active" },
        },
        rows = rows, empty_text = "No periods registered yet.",
      },
      {
        kind = "form",
        form = {
          label = "Add Period", action = "period_form", method = "POST",
          fields = {
            { name = "id", label = "Period ID", kind = "text", value = "", required = true },
            { name = "start_date", label = "Start date (YYYY-MM-DD)", kind = "date", value = "", required = true },
            { name = "end_date", label = "End date (YYYY-MM-DD)", kind = "date", value = "", required = true },
          },
          submit_label = "Add Period",
        },
      },
      {
        kind = "form",
        form = {
          label = "Set Active Period", action = "period_activate", method = "POST",
          fields = { { name = "id", label = "Period ID", kind = "text", value = "", required = true } },
          submit_label = "Set Active",
        },
      },
      { kind = "nav", items = { { label = "Back to Dashboard", view = "dashboard" } } },
    },
  }
end

-- ---------------------------------------------------------------------------
-- Entries (list, void, delete)
-- ---------------------------------------------------------------------------

--: (AppApi) -> View
M.entries = function(app)
  local raw, err = app.list_entries()
  local rows = {} --: { [number]: ViewRow }
  local view_error = nil --: string | nil
  if raw == nil then
    view_error = fmt(err)
  elseif type(raw) == "table" then
    local records = raw --[[: { [number]: EntryRecord } ]]
    for i = 1, #records do
      local rec = records[i]
      rows[i] = {
        period_id = rec.period_id, id = rec.entry.id,
        date = rec.entry.date, description = rec.entry.description,
      }
    end
  end

  local view = {
    title = "Entries",
    view = "entries",
    sections = {
      {
        kind = "table", label = "All Entries",
        columns = {
          { key = "period_id", label = "Period" }, { key = "id", label = "Entry ID" },
          { key = "date", label = "Date" }, { key = "description", label = "Description" },
        },
        rows = rows, empty_text = "No entries posted yet.",
      },
      -- Per-row void/delete is expressed as two small forms (period_id +
      -- entry id + a date for void) rather than a link-per-row: void needs
      -- a void_date the user must supply, so it can't be a bare GET link.
      {
        kind = "form",
        form = {
          label = "Void an Entry", action = "entry_void", method = "POST",
          fields = {
            { name = "period_id", label = "Period ID", kind = "text", value = "", required = true },
            { name = "id", label = "Entry ID", kind = "text", value = "", required = true },
            { name = "void_date", label = "Void date (YYYY-MM-DD)", kind = "date", value = "", required = true },
          },
          submit_label = "Void",
        },
      },
      {
        kind = "form",
        form = {
          label = "Delete an Entry", action = "entry_delete", method = "POST",
          fields = {
            { name = "period_id", label = "Period ID", kind = "text", value = "", required = true },
            { name = "id", label = "Entry ID", kind = "text", value = "", required = true },
          },
          submit_label = "Delete",
        },
      },
      { kind = "nav", items = { { label = "Back to Dashboard", view = "dashboard" } } },
    },
  } --: View
  set_error(view, view_error)
  return view
end

-- ---------------------------------------------------------------------------
-- Post entry
-- ---------------------------------------------------------------------------

-- The post-entry form: a period selector (populated from app.list_periods,
-- since bridge.post_entry requires a period_id and there is no implicit
-- default) plus date/description and a fixed number of blank line rows
-- (account_id/amount/currency). `form_error` re-renders with the
-- rejection reason (e.g. an unbalanced entry) on a failed submit.
--: (AppApi, string | nil) -> View
M.post_entry_form = function(app, form_error)
  local periods = app.list_periods()
  local period_options = {} --: { [number]: FieldOption }
  if type(periods) == "table" then
    local list = periods --[[: { [number]: PeriodEntry } ]]
    for i = 1, #list do
      period_options[i] = { value = list[i].id, label = list[i].id }
    end
  end

  local fields = {} --: { [number]: ViewField }
  fields[1] = { name = "period_id", label = "Period", kind = "select", value = "", options = period_options, required = true }
  fields[2] = { name = "date", label = "Date (YYYY-MM-DD)", kind = "date", value = "", required = true }
  fields[3] = { name = "description", label = "Description", kind = "text", value = "", required = true }
  local base = #fields
  for i = 1, M.POST_ENTRY_LINE_ROWS do
    fields[base + (i - 1) * 3 + 1] = { name = "line_account_" .. i, label = "Line " .. i .. ": Account ID", kind = "text", value = "" }
    fields[base + (i - 1) * 3 + 2] = { name = "line_amount_" .. i, label = "Line " .. i .. ": Amount (+debit/-credit, major units)", kind = "number", value = "" }
    fields[base + (i - 1) * 3 + 3] = { name = "line_currency_" .. i, label = "Line " .. i .. ": Currency", kind = "text", value = "" }
  end

  local view = {
    title = "New Entry",
    view = "post_entry",
    sections = {
      {
        kind = "form",
        form = {
          label = "Post Journal Entry", action = "post_entry", method = "POST",
          fields = fields, submit_label = "Post Entry",
        },
      },
      { kind = "nav", items = { { label = "Back to Dashboard", view = "dashboard" } } },
    },
  } --: View
  set_error(view, form_error)
  return view
end

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

--: (AppApi) -> View
M.reports = function(_app)
  return {
    title = "Reports",
    view = "reports",
    sections = {
      {
        kind = "nav",
        items = {
          { label = "Trial Balance", view = "report_trial_balance" },
          { label = "Income Statement", view = "report_income_statement" },
          { label = "Balance Sheet", view = "report_balance_sheet" },
        },
      },
      { kind = "nav", items = { { label = "Back to Dashboard", view = "dashboard" } } },
    },
  }
end

--: (AppApi) -> View
M.report_trial_balance = function(app)
  local tb, err = app.get_trial_balance()
  local rows = {} --: { [number]: ViewRow }
  local view_error = nil --: string | nil
  local summary = {} --: { [number]: ViewSummaryRow }
  if type(tb) ~= "table" then
    view_error = fmt(err)
  else
    local tb_t = tb --[[: TrialBalance ]]
    for i = 1, #tb_t.rows do
      local r = tb_t.rows[i]
      rows[i] = {
        account_id = r.account_id, name = r.name, type = r.type,
        debit = r.debit and fmt_money(r.debit) or "",
        credit = r.credit and fmt_money(r.credit) or "",
      }
    end
    summary[1] = { label = "Total debit", value = fmt_money(tb_t.total_debit) }
    summary[2] = { label = "Total credit", value = fmt_money(tb_t.total_credit) }
  end

  local view = {
    title = "Trial Balance",
    view = "report_trial_balance",
    sections = {
      { kind = "summary", label = "Totals", rows = summary },
      {
        kind = "table", label = "Trial Balance",
        columns = {
          { key = "account_id", label = "Account" }, { key = "name", label = "Name" },
          { key = "type", label = "Type" }, { key = "debit", label = "Debit" }, { key = "credit", label = "Credit" },
        },
        rows = rows, empty_text = "No accounts yet.",
      },
      { kind = "nav", items = { { label = "Back to Reports", view = "reports" } } },
    },
  } --: View
  set_error(view, view_error)
  return view
end

--:: ReportRow = { account_id: string, name: string, amount: MoneyValue }
--:: IncomeStatement = { book_currency: string, start_date: string, end_date: string, revenue_rows: { [number]: ReportRow }, expense_rows: { [number]: ReportRow }, total_revenue: MoneyValue, total_expenses: MoneyValue, net_income: MoneyValue }

-- `start_date`/`end_date` nil = show the date-range input form only (no
-- report computed yet); both given = compute and show the report alongside
-- the same form (prefilled), so the user can adjust the range in place.
--: (AppApi, string | nil, string | nil) -> View
M.report_income_statement = function(app, start_date, end_date)
  local date_fields = {
    { name = "start_date", label = "Start date (YYYY-MM-DD)", kind = "date", value = start_date or "", required = true },
    { name = "end_date", label = "End date (YYYY-MM-DD)", kind = "date", value = end_date or "", required = true },
  }
  -- Seeded empty then pushed via index assignment, not with the first
  -- section inline: this checker infers a table constructor's element type
  -- from its initial contents even when the local carries a trailing `--:`
  -- annotation, so an inline first element pins `sections`'s element type
  -- to that one section variant and every later `sections[#sections+1] =`
  -- push of a *different* ViewSection variant is rejected (confirmed by
  -- minimal repro). Starting from an empty, annotated literal avoids that.
  local sections = {} --: { [number]: ViewSection }
  sections[1] = {
    kind = "form",
    form = { label = "Date Range", action = "report_income_statement", method = "GET", fields = date_fields, submit_label = "Show" },
  }

  local view_error = nil --: string | nil
  if start_date ~= nil and end_date ~= nil then
    local is_, err = app.get_income_statement(start_date, end_date)
    if type(is_) ~= "table" then
      view_error = fmt(err)
    else
      local is_t = is_ --[[: IncomeStatement ]]
      local rev_rows = {} --: { [number]: ViewRow }
      for i = 1, #is_t.revenue_rows do
        local r = is_t.revenue_rows[i]
        rev_rows[i] = { account_id = r.account_id, name = r.name, amount = fmt_money(r.amount) }
      end
      local exp_rows = {} --: { [number]: ViewRow }
      for i = 1, #is_t.expense_rows do
        local r = is_t.expense_rows[i]
        exp_rows[i] = { account_id = r.account_id, name = r.name, amount = fmt_money(r.amount) }
      end
      sections[#sections + 1] = {
        kind = "table", label = "Revenue",
        columns = { { key = "account_id", label = "Account" }, { key = "name", label = "Name" }, { key = "amount", label = "Amount" } },
        rows = rev_rows, empty_text = "No revenue in range.",
      }
      sections[#sections + 1] = {
        kind = "table", label = "Expenses",
        columns = { { key = "account_id", label = "Account" }, { key = "name", label = "Name" }, { key = "amount", label = "Amount" } },
        rows = exp_rows, empty_text = "No expenses in range.",
      }
      sections[#sections + 1] = {
        kind = "summary", label = "Totals",
        rows = {
          { label = "Total revenue", value = fmt_money(is_t.total_revenue) },
          { label = "Total expenses", value = fmt_money(is_t.total_expenses) },
          { label = "Net income", value = fmt_money(is_t.net_income) },
        },
      }
    end
  end

  sections[#sections + 1] = { kind = "nav", items = { { label = "Back to Reports", view = "reports" } } }

  local view = {
    title = "Income Statement",
    view = "report_income_statement",
    sections = sections,
  } --: View
  set_error(view, view_error)
  return view
end

--:: BalanceSheet = { book_currency: string, as_of: string, asset_rows: { [number]: ReportRow }, liability_rows: { [number]: ReportRow }, equity_rows: { [number]: ReportRow }, net_income: MoneyValue, total_assets: MoneyValue, total_liabilities: MoneyValue, total_equity: MoneyValue }

--: (AppApi, string | nil) -> View
M.report_balance_sheet = function(app, as_of_date)
  local date_fields = {
    { name = "as_of_date", label = "As of date (YYYY-MM-DD)", kind = "date", value = as_of_date or "", required = true },
  }
  -- See M.report_income_statement's matching comment on why this starts
  -- from an empty annotated literal instead of an inline first element.
  local sections = {} --: { [number]: ViewSection }
  sections[1] = {
    kind = "form",
    form = { label = "As Of", action = "report_balance_sheet", method = "GET", fields = date_fields, submit_label = "Show" },
  }

  local view_error = nil --: string | nil
  if as_of_date ~= nil then
    local bs, err = app.get_balance_sheet(as_of_date)
    if type(bs) ~= "table" then
      view_error = fmt(err)
    else
      local bs_t = bs --[[: BalanceSheet ]]
      --: ({ [number]: ReportRow }) -> { [number]: ViewRow }
      local function rows_of(rs)
        local out = {} --: { [number]: ViewRow }
        for i = 1, #rs do
          out[i] = { account_id = rs[i].account_id, name = rs[i].name, amount = fmt_money(rs[i].amount) }
        end
        return out
      end
      local cols = { { key = "account_id", label = "Account" }, { key = "name", label = "Name" }, { key = "amount", label = "Amount" } }
      sections[#sections + 1] = { kind = "table", label = "Assets", columns = cols, rows = rows_of(bs_t.asset_rows), empty_text = "No assets." }
      sections[#sections + 1] = { kind = "table", label = "Liabilities", columns = cols, rows = rows_of(bs_t.liability_rows), empty_text = "No liabilities." }
      sections[#sections + 1] = { kind = "table", label = "Equity", columns = cols, rows = rows_of(bs_t.equity_rows), empty_text = "No equity." }
      sections[#sections + 1] = {
        kind = "summary", label = "Totals",
        rows = {
          { label = "Total assets", value = fmt_money(bs_t.total_assets) },
          { label = "Total liabilities", value = fmt_money(bs_t.total_liabilities) },
          { label = "Total equity", value = fmt_money(bs_t.total_equity) },
          { label = "Net income", value = fmt_money(bs_t.net_income) },
        },
      }
    end
  end

  sections[#sections + 1] = { kind = "nav", items = { { label = "Back to Reports", view = "reports" } } }

  local view = {
    title = "Balance Sheet",
    view = "report_balance_sheet",
    sections = sections,
  } --: View
  set_error(view, view_error)
  return view
end

-- ---------------------------------------------------------------------------
-- Dispatch: view name -> constructor
-- ---------------------------------------------------------------------------

-- Single dispatch point from a route name (one of M.routes' keys) to the
-- View it builds, so tui.lua/dom.lua share one "name -> constructor +
-- which params it reads" mapping instead of each hand-rolling their own.
-- `params` is the flat string map a route/menu selection carries (e.g.
-- account_form's `id`, the report forms' date fields); `form_error`
-- carries a failed lib.platform.apps.finance.actions submission's message
-- through to the re-rendered view. Unknown names fall back to the
-- dashboard rather than erroring -- a stale/bookmarked link should recover,
-- not crash the app.
--: (string, AppApi, { [string]: string } | nil, string | nil) -> View
M.build = function(name, app, params, form_error)
  local p = params or {}
  if name == "accounts" then return M.accounts(app) end
  if name == "account_form" then return M.account_form(app, p.id, nil, form_error) end
  if name == "periods" then return M.periods(app) end
  if name == "entries" then return M.entries(app) end
  if name == "post_entry" then return M.post_entry_form(app, form_error) end
  if name == "reports" then return M.reports(app) end
  if name == "report_trial_balance" then return M.report_trial_balance(app) end
  if name == "report_income_statement" then return M.report_income_statement(app, p.start_date, p.end_date) end
  if name == "report_balance_sheet" then return M.report_balance_sheet(app, p.as_of_date) end
  return M.dashboard(app)
end

return M
