if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")
local import_qif = require("lib.bookkeeping.import_qif")

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

T.describe("lib.bookkeeping.import_qif", function()

  T.it("imports !Type:Bank records into balanced two-line entries", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local qif_text = "!Type:Bank\n"
      .. "D1/5/2026\nT-4.50\nPCoffee Shop\nMPurchase\nN1001\n^\n"
      .. "D01/06/2026\nT2000.00\nPPaycheck\n^\n"

    local result, err = import_qif.string_to_entries(qif_text, j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.entries, 2)
    T.eq(#result.errors, 0)
    T.eq(#journal.list(j), 2)

    T.eq(result.entries[1].row, 1)
    local e1 = result.entries[1].entry
    T.eq(e1.date, "2026-01-05")
    T.eq(e1.description, "Coffee Shop")
    T.eq(e1.lines[1].account, "checking")
    T.eq(e1.lines[1].amount.amount_minor, -450)
    T.eq(e1.lines[2].account, "uncategorized")
    T.eq(e1.lines[2].amount.amount_minor, 450)

    T.eq(result.entries[2].row, 2)
    local e2 = result.entries[2].entry
    T.eq(e2.date, "2026-01-06")
    T.eq(e2.description, "Paycheck")
    T.eq(e2.lines[1].amount.amount_minor, 200000)
  end)

  T.it("falls back to M (memo) when P (payee) is absent", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local qif_text = "!Type:Bank\nD1/5/2026\nT-10.00\nMATM withdrawal\n^\n"

    local result, err = import_qif.string_to_entries(qif_text, j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.errors, 0)
    T.eq(result.entries[1].entry.description, "ATM withdrawal")
  end)

  T.it("ignores unsupported line prefixes (category/split/address/etc.)", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local qif_text = "!Type:Bank\nD1/5/2026\nT-10.00\nPStore\nLGroceries\nCX\nAaddr line\n^\n"

    local result, err = import_qif.string_to_entries(qif_text, j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.errors, 0)
    T.eq(result.entries[1].entry.description, "Store")
  end)

  T.it("rejects an apostrophe two-digit-year date as a row error, not a guess, and still imports the good record", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local qif_text = "!Type:Bank\nD1/5'26\nT-1.00\nPBad\n^\nD1/6/2026\nT-2.00\nPGood\n^\n"

    local result, err = import_qif.string_to_entries(qif_text, j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.entries, 1)
    T.eq(result.entries[1].row, 2)
    T.eq(result.entries[1].entry.description, "Good")
    T.eq(#result.errors, 1)
    T.eq(result.errors[1].row, 1)
    T.ok(result.errors[1].message:find("unsupported QIF date", 1, true) ~= nil, result.errors[1].message)
  end)

  T.it("imports records found before an unterminated trailing record and reports the break", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local qif_text = "!Type:Bank\nD1/5/2026\nT-1.00\nPFirst\n^\nD1/6/2026\nT-2.00\nPTruncated, never closed"

    local result, err = import_qif.string_to_entries(qif_text, j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.entries, 1)
    T.eq(result.entries[1].row, 1)
    T.eq(result.entries[1].entry.description, "First")
    T.eq(#result.errors, 1)
    T.eq(result.errors[1].row, 2)
    T.ok(result.errors[1].message:find("unterminated QIF record", 1, true) ~= nil, result.errors[1].message)
  end)

  T.describe("fatal, whole-import errors", function()
    T.it("rejects a file with no !Type: header", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local result, err = import_qif.string_to_entries("D1/5/2026\nT-1.00\nPx\n^\n", j, chart, {
        bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
      })
      T.eq(result, nil)
      T.ok(type(err) == "string")
      T.eq(#journal.list(j), 0)
    end)

    T.it("rejects a file with multiple !Type: sections", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local qif_text = "!Type:Bank\nD1/5/2026\nT-1.00\nPx\n^\n!Type:CCard\nD1/6/2026\nT-2.00\nPy\n^\n"
      local result, err = import_qif.string_to_entries(qif_text, j, chart, {
        bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
      })
      T.eq(result, nil)
      T.ok(type(err) == "string")
      T.eq(#journal.list(j), 0)
    end)

    T.it("accepts a non-Bank !Type: value (e.g. CCard) since the caller configures the accounts", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local qif_text = "!Type:CCard\nD1/5/2026\nT-1.00\nPx\n^\n"
      local result, err = import_qif.string_to_entries(qif_text, j, chart, {
        bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
      })
      T.ok(result ~= nil, err)
      T.eq(#result.entries, 1)
      T.eq(result.entries[1].row, 1)
    end)

    T.it("rejects an unknown bank_account before processing any record", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local qif_text = "!Type:Bank\nD1/5/2026\nT-1.00\nPx\n^\n"
      local result, err = import_qif.string_to_entries(qif_text, j, chart, {
        bank_account = "does-not-exist", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
      })
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

    T.it("rejects a currency that does not match the journal's book currency", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local qif_text = "!Type:Bank\nD1/5/2026\nT-1.00\nPx\n^\n"
      local result, err = import_qif.string_to_entries(qif_text, j, chart, {
        bank_account = "checking", contra_account = "uncategorized", currency = "EUR", amount_sign = nil,
      })
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
