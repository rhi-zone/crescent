if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local account = require("lib.bookkeeping.account")
local journal = require("lib.bookkeeping.journal")
local import_ofx = require("lib.bookkeeping.import_ofx")

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

T.describe("lib.bookkeeping.import_ofx", function()

  T.it("imports well-formed <STMTTRN> transactions into balanced two-line entries", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local ofx_text = "<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>\n"
      .. "<STMTTRN>\n"
      .. "<TRNTYPE>DEBIT\n"
      .. "<DTPOSTED>20260105120000[-5:EST]\n"
      .. "<TRNAMT>-4.50\n"
      .. "<NAME>Coffee Shop\n"
      .. "<MEMO>Purchase\n"
      .. "<FITID>1001\n"
      .. "</STMTTRN>\n"
      .. "<STMTTRN>\n"
      .. "<TRNTYPE>CREDIT\n"
      .. "<DTPOSTED>20260106\n"
      .. "<TRNAMT>2000.00\n"
      .. "<NAME>Paycheck\n"
      .. "<FITID>1002\n"
      .. "</STMTTRN>\n"
      .. "</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>\n"

    local result, err = import_ofx.string_to_entries(ofx_text, j, chart, {
      bank_account = "checking",
      contra_account = "uncategorized",
      currency = "USD",
      amount_sign = nil,
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

  T.it("falls back to MEMO when NAME is absent", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local ofx_text = "<STMTTRN>\n<DTPOSTED>20260105\n<TRNAMT>-10.00\n<MEMO>ATM withdrawal\n</STMTTRN>\n"

    local result, err = import_ofx.string_to_entries(ofx_text, j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.errors, 0)
    T.eq(result.entries[1].entry.description, "ATM withdrawal")
  end)

  T.it("collects a malformed DTPOSTED as a row error and still imports the good transaction", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local ofx_text = "<STMTTRN>\n<DTPOSTED>not-a-date\n<TRNAMT>-1.00\n<NAME>Bad\n</STMTTRN>\n"
      .. "<STMTTRN>\n<DTPOSTED>20260107\n<TRNAMT>-2.00\n<NAME>Good\n</STMTTRN>\n"

    local result, err = import_ofx.string_to_entries(ofx_text, j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.entries, 1)
    T.eq(#result.errors, 1)
    T.eq(result.errors[1].row, 1)
    T.eq(result.entries[1].row, 2)
    T.eq(result.entries[1].entry.description, "Good")
  end)

  T.it("imports transactions found before an unterminated STMTTRN and reports the break", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local ofx_text = "<STMTTRN>\n<DTPOSTED>20260105\n<TRNAMT>-1.00\n<NAME>First\n</STMTTRN>\n"
      .. "<STMTTRN>\n<DTPOSTED>20260106\n<TRNAMT>-2.00\n<NAME>Truncated, never closed"

    local result, err = import_ofx.string_to_entries(ofx_text, j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.entries, 1)
    T.eq(result.entries[1].row, 1)
    T.eq(result.entries[1].entry.description, "First")
    T.eq(#result.errors, 1)
    T.eq(result.errors[1].row, 2)
    T.ok(result.errors[1].message:find("unterminated STMTTRN block", 1, true) ~= nil, result.errors[1].message)
  end)

  T.it("returns an empty result when no <STMTTRN> blocks are present", function()
    local chart = bank_chart()
    local j = new_journal("USD")
    local result, err = import_ofx.string_to_entries("<OFX></OFX>", j, chart, {
      bank_account = "checking", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
    })
    T.ok(result ~= nil, err)
    T.eq(#result.entries, 0)
    T.eq(#result.errors, 0)
  end)

  T.describe("fatal, whole-import errors", function()
    T.it("rejects an unknown bank_account before processing any transaction", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local ofx_text = "<STMTTRN>\n<DTPOSTED>20260105\n<TRNAMT>-1.00\n<NAME>x\n</STMTTRN>\n"
      local result, err = import_ofx.string_to_entries(ofx_text, j, chart, {
        bank_account = "does-not-exist", contra_account = "uncategorized", currency = "USD", amount_sign = nil,
      })
      T.eq(result, nil)
      T.ok(type(err) == "string")
      T.eq(#journal.list(j), 0)
    end)

    T.it("rejects a currency that does not match the journal's book currency", function()
      local chart = bank_chart()
      local j = new_journal("USD")
      local ofx_text = "<STMTTRN>\n<DTPOSTED>20260105\n<TRNAMT>-1.00\n<NAME>x\n</STMTTRN>\n"
      local result, err = import_ofx.string_to_entries(ofx_text, j, chart, {
        bank_account = "checking", contra_account = "uncategorized", currency = "EUR", amount_sign = nil,
      })
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
