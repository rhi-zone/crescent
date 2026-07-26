if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Chart of accounts for lib/bookkeeping.
--
-- An account has no fixed currency — postings in any currency may land on
-- any account (see docs decision: multi-currency accounts). Currency lives
-- on the journal line, not the account. See lib/bookkeeping/ledger.lua for
-- how per-account balances are kept as a map keyed by currency.

local M = {}

--:: account_type = "asset" | "liability" | "equity" | "revenue" | "expense"
--:: account = {
--::   id: string,
--::   name: string,
--::   type: account_type,
--::   code: string | nil,
--::   description: string | nil,
--::   parent: string | nil,
--:: }
--:: chart = { by_id: { [string]: account }, order: { [number]: string } }

local ACCOUNT_TYPES = {
  asset     = true,
  liability = true,
  equity    = true,
  revenue   = true,
  expense   = true,
}

-- Account types whose normal balance increases with a debit (positive signed
-- amount): asset, expense. The remaining types (liability, equity, revenue)
-- are credit-normal.
local DEBIT_NORMAL = {
  asset   = true,
  expense = true,
}

-- TYPECHECKER WORKAROUND: the natural code is `M.is_account_type = function(t) ... end`
-- with callers narrowing via `if not M.is_account_type(x) then return ... end`. The
-- checker's guard_check narrowing (`t is T`) only fires for predicates bound by a
-- `local`/`local function` declaration; a call through a table field (`M.is_account_type(x)`,
-- even aliased to a local first) does not narrow the argument. Confirmed via minimal
-- repro (predicate as `M.f = function`: does not narrow; same predicate as
-- `local f = function`: narrows). Defining the predicate as a local and exposing it as
-- a module field (below) keeps the public API unchanged while narrowing works for
-- in-module callers. See TODO.md; revert to a plain `M.is_account_type = function` once
-- guard_check narrows through table-field-bound predicates.

--- Is `t` a recognized chart-of-accounts type?
--: (t: string) -> t is account_type
local function is_account_type(t)
  return ACCOUNT_TYPES[t] == true
end
M.is_account_type = is_account_type

--- Does this account type's balance increase with a debit (positive amount)?
-- Returns (nil, errmsg) for an unrecognized type.
--: account_type -> (boolean | nil, string | nil)
M.is_debit_normal = function(account_type)
  if not is_account_type(account_type) then
    return nil, "account.is_debit_normal: unknown account type: " .. tostring(account_type)
  end
  return DEBIT_NORMAL[account_type] == true
end

--- "debit" or "credit": which side increases this account type's balance.
--: account_type -> (string | nil, string | nil)
M.normal_side = function(account_type)
  local debit_normal, err = M.is_debit_normal(account_type)
  if debit_normal == nil then return nil, err end
  return debit_normal and "debit" or "credit"
end

--- Create an empty chart of accounts.
--: () -> chart
M.new = function()
  return { by_id = {}, order = {} }
end

--- Add an account to the chart.
-- opts: { id: string, name: string, type: account_type, code?: string,
--         description?: string, parent?: string }
-- If `parent` is given, it must already exist in the chart (accounts must
-- be added in parent-before-child order; this makes cycles impossible by
-- construction rather than requiring a separate cycle check).
--: (chart, { id: string, name: string, type: string, code: string | nil, description: string | nil, parent: string | nil }) -> (account | nil, string | nil)
M.add_account = function(chart, opts)
  if type(opts.id) ~= "string" or opts.id == "" then
    return nil, "account.add_account: id must be a non-empty string"
  end
  if chart.by_id[opts.id] then
    return nil, "account.add_account: duplicate account id: " .. opts.id
  end
  if type(opts.name) ~= "string" or opts.name == "" then
    return nil, "account.add_account: name must be a non-empty string"
  end
  local acct_type = opts.type
  if not is_account_type(acct_type) then
    return nil, "account.add_account: unknown account type: " .. tostring(acct_type)
  end
  local parent = opts.parent
  if parent ~= nil then
    if type(parent) ~= "string" then
      return nil, "account.add_account: parent must be a string"
    end
    if not chart.by_id[parent] then
      return nil, "account.add_account: parent account does not exist: " .. parent
    end
  end
  if opts.code ~= nil and type(opts.code) ~= "string" then
    return nil, "account.add_account: code must be a string"
  end
  if opts.description ~= nil and type(opts.description) ~= "string" then
    return nil, "account.add_account: description must be a string"
  end

  local acct = {
    id          = opts.id,
    name        = opts.name,
    type        = acct_type,
    code        = opts.code,
    description = opts.description,
    parent      = parent,
  }

  chart.by_id[opts.id] = acct
  chart.order[#chart.order + 1] = opts.id
  return acct
end

--- Look up an account by id.
--: (chart, string) -> account | nil
M.get = function(chart, id)
  return chart.by_id[id]
end

--- All accounts, in the order they were added.
--: chart -> { [number]: account }
M.list = function(chart)
  local out = {}
  for i = 1, #chart.order do
    out[i] = chart.by_id[chart.order[i]]
  end
  return out
end

--- Direct children of `parent_id`, in the order they were added.
--: (chart, string) -> { [number]: account }
M.children = function(chart, parent_id)
  local out = {}
  for i = 1, #chart.order do
    local acct = chart.by_id[chart.order[i]]
    if acct.parent == parent_id then
      out[#out + 1] = acct
    end
  end
  return out
end

return M
