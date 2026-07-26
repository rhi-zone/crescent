if not package.path:find("?/init.lua", 1, true) then
  package.path = "?/init.lua;" .. package.path
end

-- lib/bookkeeping: double-entry bookkeeping domain model.
--
-- Submodules:
--   account.lua        chart of accounts (types, hierarchy, metadata)
--   journal.lua        double-entry journal entries (post + validate)
--   ledger.lua         per-account, per-currency transaction history
--   trial_balance.lua  book-currency summary + accounting-equation check
--   store.lua          SQLite persistence (save/load the model above)
--   import.lua         CSV bank-statement import into journal entries
--   report.lua         income statement (P&L) and balance sheet
--
-- See each submodule's header comment for the design decisions baked into
-- its API: signed amounts (positive = debit, negative = credit), lines may
-- be posted in any currency (accounts have no fixed currency), and
-- currency conversion to the journal's book currency happens once, at
-- posting time, using each line's recorded rate.

local M = {}

M._tier = "pure"

M.account       = require("lib.bookkeeping.account")
M.journal       = require("lib.bookkeeping.journal")
M.ledger        = require("lib.bookkeeping.ledger")
M.trial_balance = require("lib.bookkeeping.trial_balance")
M.store         = require("lib.bookkeeping.store")
M.import        = require("lib.bookkeeping.import")
M.report        = require("lib.bookkeeping.report")

return M
