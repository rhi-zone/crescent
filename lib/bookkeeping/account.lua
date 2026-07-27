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

-- Sentinel marking "explicitly clear this field" in an M.update_account
-- `changes` table. A plain Lua table cannot distinguish "field absent" from
-- "field explicitly set to nil" (both read back as nil), so omitting a
-- field and wanting to clear it are otherwise indistinguishable. Pass
-- `account.CLEAR` as the value to force a nilable field (code, description)
-- back to nil; omit the field entirely to leave it untouched. Identity
-- (`==`), not shape, is what's checked, so this must be the same table
-- reference `M.CLEAR` always is — never construct your own `{}`.
M.CLEAR = {}

--- Update an existing account's mutable fields (name, code, description,
-- type). `changes` is a partial record; only fields present are applied.
-- `parent` cannot be changed this way — reparenting would break the
-- parent-before-child ordering invariant `chart.order` and `add_account`
-- rely on — so `changes.parent` being non-nil is rejected outright.
--
-- To clear `code` or `description` back to nil, pass `M.CLEAR` (see above)
-- rather than nil/omitting the field.
--
-- Journal-reference and children checks are not this function's job — see
-- delete_account below; the same caps-first boundary applies here in spirit
-- (this module has no dependency on journal.lua), though update doesn't
-- remove anything so there is nothing to check against the journal.
-- Resolve one "clearable" field (code, description) from `changes`: absent
-- (nil) means "leave unchanged", `M.CLEAR` means "set to nil", anything else
-- must be a string. Returns (touched, value, err) — `touched` tells the
-- caller whether to assign `value` at all, since `value` alone can't
-- distinguish "leave unchanged" from "set to nil".
--
-- TYPECHECKER WORKAROUND: the natural code narrows `v` (typed `unknown`,
-- since it may be a string, nil, or the M.CLEAR sentinel table) once and
-- reuses the narrowed value across the "clear" and "keep string" branches.
-- Same class of bug documented in lib/bookkeeping/journal.lua's build_line
-- and lib/bookkeeping/store.lua's opt_string/opt_number (the "unknown ->
-- optional T" merge does not survive past a guarding `if`). Isolated into
-- this single-purpose helper (one guarded return per branch) so
-- M.update_account itself never threads an `unknown -> T | nil` narrow
-- through its own branches. See TODO.md; delete this indirection once
-- guard-based narrowing survives a shared optional-typed local.
--: (unknown, string) -> (boolean, string | nil, string | nil)
local function resolve_clearable(v, err_msg)
  if v == nil then return false, nil, nil end
  if v == M.CLEAR then return true, nil, nil end
  if type(v) ~= "string" then return false, nil, err_msg end
  return true, v, nil
end

--: (chart, string, { name: string | nil, code: unknown, description: unknown, type: string | nil, parent: string | nil }) -> (account | nil, string | nil)
M.update_account = function(chart, account_id, changes)
  local acct = chart.by_id[account_id]
  if not acct then
    return nil, "account.update_account: unknown account id: " .. tostring(account_id)
  end
  if changes.parent ~= nil then
    return nil, "account.update_account: cannot change parent (would break hierarchy invariants)"
  end
  local name = changes.name
  if name ~= nil then
    if type(name) ~= "string" or name == "" then
      return nil, "account.update_account: name must be a non-empty string"
    end
  end
  local acct_type = changes.type
  if acct_type ~= nil then
    if not is_account_type(acct_type) then
      return nil, "account.update_account: unknown account type: " .. tostring(acct_type)
    end
  end
  local set_code, code_val, code_err = resolve_clearable(changes.code, "account.update_account: code must be a string")
  if code_err then return nil, code_err end
  local set_description, description_val, description_err =
    resolve_clearable(changes.description, "account.update_account: description must be a string")
  if description_err then return nil, description_err end

  if name ~= nil then acct.name = name end
  if acct_type ~= nil then acct.type = acct_type end
  if set_code then acct.code = code_val end
  if set_description then acct.description = description_val end

  return acct
end

--- Delete an account from the chart. Fails if the account has children
-- (would orphan them). Does NOT check whether the account is referenced by
-- any journal line — this module has no dependency on lib.bookkeeping.journal
-- by design (journal depends on account, not the reverse), so a
-- journal-reference check cannot live here. Callers that need that guarantee
-- (e.g. a higher-level orchestration/bridge layer that holds both the chart
-- and the journal) must check journal references themselves before calling
-- this.
--: (chart, string) -> (true | nil, string | nil)
M.delete_account = function(chart, account_id)
  local acct = chart.by_id[account_id]
  if not acct then
    return nil, "account.delete_account: unknown account id: " .. tostring(account_id)
  end
  local kids = M.children(chart, account_id)
  if #kids > 0 then
    return nil, "account.delete_account: account " .. account_id .. " has " .. #kids .. " child account(s)"
  end

  chart.by_id[account_id] = nil
  -- TYPECHECKER WORKAROUND: the natural code is `table.remove(chart.order, i)`.
  -- Confirmed via minimal repro that `table.remove` rejects a `{ [number]: V }`-typed
  -- array (chart.order's declared shape) with "missing indexer for integer", even
  -- though `{ [number]: V }` should structurally satisfy `{ [integer]: V }` (every
  -- integer is a number, so a table indexed by any number already guarantees the
  -- narrower integer-keyed guarantee `table.remove` asks for). This looks like a
  -- distinct root cause from the three table.remove/table.sort "generic pinned by
  -- an earlier call in the same file" entries already in TODO.md (this file makes
  -- no other table.remove/table.sort call), so logged as a separate entry. Worked
  -- around with a hand-written shift-left removal instead of `table.remove`. See
  -- TODO.md; revert to `table.remove(chart.order, i)` once `{ [number]: V }` is
  -- accepted where `{ [integer]: V }` is expected.
  for i = 1, #chart.order do
    if chart.order[i] == account_id then
      local n = #chart.order
      for j = i, n - 1 do
        chart.order[j] = chart.order[j + 1]
      end
      chart.order[n] = nil
      break
    end
  end
  return true
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
