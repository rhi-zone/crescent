if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")
local import  = require("lib.bookkeeping.import")

local function new_journal(currency)
  local j, err = journal.new(currency)
  if j == nil then error(err) end
  return j
end

local function bank_chart()
  local chart = account.new()
  account.add_account(chart, { id = "checking", name = "Checking", type = "asset" })
  account.add_account(chart, { id = "uncategorized", name = "Uncategorized", type = "expense" })
  return chart
end

T.describe("lib.bookkeeping.import", function()

  T.describe("string_to_entries: single amount column", function()
    T.it("imports a simple CSV into balanced two-line entries", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local csv_text = "Date,Description,Amount\n"
        .. "2026-01-05,Coffee shop,-4.50\n"
        .. "2026-01-06,Paycheck,2000.00\n"

      local result, err = import.string_to_entries(csv_text, j, chart, {
        bank_account = "checking",
        contra_account = "uncategorized",
        currency = "USD",
        columns = { date = "Date", description = "Description", amount = "Amount", debit = nil, credit = nil },
        amount_sign = nil,
        debit_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.ok(result ~= nil, err)
      T.eq(#result.entries, 2)
      T.eq(#result.errors, 0)
      T.eq(#journal.list(j), 2)

      local e1 = result.entries[1]
      T.eq(e1.date, "2026-01-05")
      T.eq(e1.description, "Coffee shop")
      T.eq(e1.lines[1].account, "checking")
      T.eq(e1.lines[1].amount.amount_minor, -450)
      T.eq(e1.lines[2].account, "uncategorized")
      T.eq(e1.lines[2].amount.amount_minor, 450)

      local e2 = result.entries[2]
      T.eq(e2.lines[1].amount.amount_minor, 200000)
      T.eq(e2.lines[2].amount.amount_minor, -200000)
    end)

    T.it("respects amount_sign to flip a bank's inverted amount column", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      -- Some banks record withdrawals as positive numbers; amount_sign = -1
      -- flips that back to this model's convention (positive = deposit).
      local csv_text = "Date,Description,Amount\n2026-01-05,Withdrawal,50.00\n"

      local result, err = import.string_to_entries(csv_text, j, chart, {
        bank_account = "checking",
        contra_account = "uncategorized",
        currency = "USD",
        amount_sign = -1,
        columns = { date = "Date", description = "Description", amount = "Amount", debit = nil, credit = nil },
        debit_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.ok(result ~= nil, err)
      T.eq(#result.errors, 0)
      T.eq(result.entries[1].lines[1].amount.amount_minor, -5000)
    end)

    T.it("strips thousands-separator commas by default", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local csv_text = "Date,Description,Amount\n2026-01-05,Big deposit,\"1,234.56\"\n"

      local result, err = import.string_to_entries(csv_text, j, chart, {
        bank_account = "checking",
        contra_account = "uncategorized",
        currency = "USD",
        columns = { date = "Date", description = "Description", amount = "Amount", debit = nil, credit = nil },
        amount_sign = nil,
        debit_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.ok(result ~= nil, err)
      T.eq(#result.errors, 0)
      T.eq(result.entries[1].lines[1].amount.amount_minor, 123456)
    end)
  end)

  T.describe("string_to_entries: split debit/credit columns", function()
    T.it("requires debit_sign and applies it with the opposite sign to credit", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local csv_text = "Date,Description,Debit,Credit\n"
        .. "2026-01-05,Withdrawal,50.00,\n"
        .. "2026-01-06,Deposit,,75.00\n"

      -- Bank convention here: debit = money left the account (decrease).
      local result, err = import.string_to_entries(csv_text, j, chart, {
        bank_account = "checking",
        contra_account = "uncategorized",
        currency = "USD",
        debit_sign = -1,
        columns = { date = "Date", description = "Description", debit = "Debit", credit = "Credit", amount = nil },
        amount_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.ok(result ~= nil, err)
      T.eq(#result.errors, 0)
      T.eq(result.entries[1].lines[1].amount.amount_minor, -5000)
      T.eq(result.entries[2].lines[1].amount.amount_minor, 7500)
    end)

    T.it("fails fast (no rows processed) if debit/credit columns are configured without debit_sign", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local csv_text = "Date,Description,Debit,Credit\n2026-01-05,Withdrawal,50.00,\n"

      local result, err = import.string_to_entries(csv_text, j, chart, {
        bank_account = "checking",
        contra_account = "uncategorized",
        currency = "USD",
        columns = { date = "Date", description = "Description", debit = "Debit", credit = "Credit", amount = nil },
        amount_sign = nil, debit_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.ok(result ~= nil, err)
      T.eq(#result.entries, 0)
      T.eq(#result.errors, 1)
    end)
  end)

  T.describe("row-level errors do not stop the rest of the import", function()
    T.it("collects a bad-date row as an error and still imports the good rows", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local csv_text = "Date,Description,Amount\n"
        .. "not-a-date,Bad row,10.00\n"
        .. "2026-01-06,Good row,20.00\n"

      local result, err = import.string_to_entries(csv_text, j, chart, {
        bank_account = "checking",
        contra_account = "uncategorized",
        currency = "USD",
        columns = { date = "Date", description = "Description", amount = "Amount", debit = nil, credit = nil },
        amount_sign = nil,
        debit_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.ok(result ~= nil, err)
      T.eq(#result.entries, 1)
      T.eq(#result.errors, 1)
      T.eq(result.errors[1].row, 1)
      T.eq(result.entries[1].description, "Good row")
    end)

    T.it("collects an unparseable-amount row as an error", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local csv_text = "Date,Description,Amount\n2026-01-05,Garbage,not-a-number\n"

      local result, err = import.string_to_entries(csv_text, j, chart, {
        bank_account = "checking",
        contra_account = "uncategorized",
        currency = "USD",
        columns = { date = "Date", description = "Description", amount = "Amount", debit = nil, credit = nil },
        amount_sign = nil,
        debit_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.ok(result ~= nil, err)
      T.eq(#result.entries, 0)
      T.eq(#result.errors, 1)
    end)
  end)

  T.describe("fatal, whole-import errors", function()
    T.it("rejects an unknown bank_account before processing any row", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local result, err = import.string_to_entries("Date,Description,Amount\n2026-01-05,x,1.00\n", j, chart, {
        bank_account = "does-not-exist",
        contra_account = "uncategorized",
        currency = "USD",
        columns = { date = "Date", description = "Description", amount = "Amount", debit = nil, credit = nil },
        amount_sign = nil,
        debit_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.eq(result, nil)
      T.ok(type(err) == "string")
      T.eq(#journal.list(j), 0)
    end)

    T.it("rejects a currency that does not match the journal's book currency", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local result, err = import.string_to_entries("Date,Description,Amount\n2026-01-05,x,1.00\n", j, chart, {
        bank_account = "checking",
        contra_account = "uncategorized",
        currency = "EUR",
        columns = { date = "Date", description = "Description", amount = "Amount", debit = nil, credit = nil },
        amount_sign = nil,
        debit_sign = nil, parse_date = nil, parse_amount = nil, csv_opts = nil,
      })
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
