if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T            = require("lib.test.assert")
local doc_registry = require("lib.platform.apps.finance.doc_registry")
local bridge_mod   = require("lib.platform.apps.finance.bridge")
local import_mod   = require("lib.platform.apps.finance.import")

local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
  T.describe("lib.platform.apps.finance.import", function()
    T.it("lib.sqlite loaded", function()
      error("lib.sqlite failed to load: " .. tostring(sqlite))
    end)
  end)
  return
end

local function mem_db()
  local db, err = sqlite.open(":memory:")
  if not db then error("sqlite.open(:memory:) failed: " .. tostring(err)) end
  return db
end

-- A fresh bridge with a "checking" (asset) and "uncategorized" (expense)
-- account already posted, matching every fixture below's default_account_id/
-- contra_account_id.
local function new_bridge()
  local db = mem_db()
  local reg = doc_registry.new({ client_id = 1 })
  local b, err = bridge_mod.new({ registry = reg, db = db, book_currency = "USD" })
  if not b then error("bridge.new failed: " .. tostring(err)) end

  local a1, aerr1 = bridge_mod.add_account(b, { id = "checking", name = "Checking", type = "asset" })
  if not a1 then error("add_account(checking) failed: " .. tostring(aerr1)) end
  local a2, aerr2 = bridge_mod.add_account(b, { id = "uncategorized", name = "Uncategorized", type = "expense" })
  if not a2 then error("add_account(uncategorized) failed: " .. tostring(aerr2)) end

  return b
end

local CSV_MAPPER = { date = "Date", description = "Description", amount = "Amount", debit = nil, credit = nil }

local function base_opts(overrides)
  local o = overrides or {}
  return {
    format             = o.format,
    mapper             = o.mapper,
    default_account_id = o.default_account_id or "checking",
    contra_account_id  = o.contra_account_id or "uncategorized",
    amount_sign        = o.amount_sign,
    debit_sign         = o.debit_sign,
    parse_date         = o.parse_date,
    parse_amount       = o.parse_amount,
    csv_opts           = o.csv_opts,
  }
end

T.describe("finance.import", function()

  T.describe("CSV", function()
    T.it("imports every row through the bridge", function()
      local b = new_bridge()
      local csv_text = "Date,Description,Amount\n"
        .. "2026-01-05,Coffee shop,-4.50\n"
        .. "2026-01-06,Paycheck,2000.00\n"

      local result, err = import_mod.from_string(b, csv_text, base_opts({ format = "csv", mapper = CSV_MAPPER }))
      T.ok(result ~= nil, err)
      T.eq(result.imported, 2)
      T.eq(result.skipped, 0)
      T.eq(#result.errors, 0)

      local ledger, lerr = bridge_mod.get_ledger(b)
      T.ok(ledger ~= nil, lerr)
    end)

    T.it("auto-detects CSV when format is nil", function()
      local b = new_bridge()
      local csv_text = "Date,Description,Amount\n2026-01-05,Coffee shop,-4.50\n"

      local result, err = import_mod.from_string(b, csv_text, base_opts({ mapper = CSV_MAPPER }))
      T.ok(result ~= nil, err)
      T.eq(result.imported, 1)
    end)

    T.it("collects a per-row parse error without stopping the rest of the import", function()
      local b = new_bridge()
      local csv_text = "Date,Description,Amount\n"
        .. "not-a-date,Bad row,10.00\n"
        .. "2026-01-06,Good row,20.00\n"

      local result, err = import_mod.from_string(b, csv_text, base_opts({ format = "csv", mapper = CSV_MAPPER }))
      T.ok(result ~= nil, err)
      T.eq(result.imported, 1)
      T.eq(#result.errors, 1)
      T.eq(result.errors[1].entry_idx, 1)
    end)

    T.it("fails the whole import for an unknown contra_account_id", function()
      local b = new_bridge()
      local csv_text = "Date,Description,Amount\n2026-01-05,x,1.00\n"

      local result, err = import_mod.from_string(b, csv_text, base_opts({
        format = "csv", mapper = CSV_MAPPER, contra_account_id = "does-not-exist",
      }))
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

    T.it("requires opts.mapper for CSV", function()
      local b = new_bridge()
      local result, err = import_mod.from_string(b, "Date,Description,Amount\n2026-01-05,x,1.00\n", base_opts({ format = "csv" }))
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("OFX", function()
    local ofx_text = "<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>\n"
      .. "<STMTTRN>\n<DTPOSTED>20260105\n<TRNAMT>-4.50\n<NAME>Coffee Shop\n</STMTTRN>\n"
      .. "<STMTTRN>\n<DTPOSTED>20260206\n<TRNAMT>2000.00\n<NAME>Paycheck\n</STMTTRN>\n"
      .. "</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>\n"

    T.it("imports every <STMTTRN> through the bridge", function()
      local b = new_bridge()
      local result, err = import_mod.from_string(b, ofx_text, base_opts({ format = "ofx" }))
      T.ok(result ~= nil, err)
      T.eq(result.imported, 2)
      T.eq(result.skipped, 0)
      T.eq(#result.errors, 0)
    end)

    T.it("auto-detects OFX from the OFXHEADER marker", function()
      local b = new_bridge()
      local text = "OFXHEADER:100\n" .. ofx_text
      local result, err = import_mod.from_string(b, text, base_opts())
      T.ok(result ~= nil, err)
      T.eq(result.imported, 2)
    end)

    T.it("auto-detects OFX from a leading <?OFX marker", function()
      local b = new_bridge()
      local text = "<?OFX OFXHEADER=\"200\"?>\n" .. ofx_text
      local result, err = import_mod.from_string(b, text, base_opts())
      T.ok(result ~= nil, err)
      T.eq(result.imported, 2)
    end)
  end)

  T.describe("QIF", function()
    local qif_text = "!Type:Bank\n"
      .. "D1/5/2026\nT-4.50\nPCoffee Shop\n^\n"
      .. "D2/6/2026\nT2000.00\nPPaycheck\n^\n"

    T.it("imports every record through the bridge", function()
      local b = new_bridge()
      local result, err = import_mod.from_string(b, qif_text, base_opts({ format = "qif" }))
      T.ok(result ~= nil, err)
      T.eq(result.imported, 2)
      T.eq(result.skipped, 0)
      T.eq(#result.errors, 0)
    end)

    T.it("auto-detects QIF from the !Type: marker", function()
      local b = new_bridge()
      local result, err = import_mod.from_string(b, qif_text, base_opts())
      T.ok(result ~= nil, err)
      T.eq(result.imported, 2)
    end)
  end)

  T.describe("period assignment", function()
    T.it("registers a monthly period per entry date and reuses it for entries in the same month", function()
      local b = new_bridge()
      local csv_text = "Date,Description,Amount\n"
        .. "2026-01-05,First,-4.50\n"
        .. "2026-01-20,Second,-1.00\n"
        .. "2026-02-01,Third,-2.00\n"

      local result, err = import_mod.from_string(b, csv_text, base_opts({ format = "csv", mapper = CSV_MAPPER }))
      T.ok(result ~= nil, err)
      T.eq(result.imported, 3)

      local periods = doc_registry.list_periods(b.registry)
      T.eq(#periods, 2)

      local by_id = {} --: { [string]: { id: string, start_date: string, end_date: string } }
      for i = 1, #periods do by_id[periods[i].id] = periods[i] end

      T.ok(by_id["2026-01"] ~= nil)
      T.eq(by_id["2026-01"].start_date, "2026-01-01")
      T.eq(by_id["2026-01"].end_date, "2026-01-31")

      T.ok(by_id["2026-02"] ~= nil)
      T.eq(by_id["2026-02"].start_date, "2026-02-01")
      T.eq(by_id["2026-02"].end_date, "2026-02-28")
    end)

    T.it("computes a leap-year February end date correctly", function()
      local b = new_bridge()
      -- 2028 is a leap year.
      local csv_text = "Date,Description,Amount\n2028-02-10,Leap day check,-1.00\n"

      local result, err = import_mod.from_string(b, csv_text, base_opts({ format = "csv", mapper = CSV_MAPPER }))
      T.ok(result ~= nil, err)
      T.eq(result.imported, 1)

      local periods = doc_registry.list_periods(b.registry)
      T.eq(#periods, 1)
      T.eq(periods[1].id, "2028-02")
      T.eq(periods[1].end_date, "2028-02-29")
    end)
  end)

  T.describe("duplicate detection (skipped)", function()
    T.it("skips a re-imported entry with the same date/description/amount, without erroring", function()
      local b = new_bridge()
      local csv_text = "Date,Description,Amount\n2026-01-05,Coffee shop,-4.50\n"

      local result1, err1 = import_mod.from_string(b, csv_text, base_opts({ format = "csv", mapper = CSV_MAPPER }))
      T.ok(result1 ~= nil, err1)
      T.eq(result1.imported, 1)
      T.eq(result1.skipped, 0)

      local result2, err2 = import_mod.from_string(b, csv_text, base_opts({ format = "csv", mapper = CSV_MAPPER }))
      T.ok(result2 ~= nil, err2)
      T.eq(result2.imported, 0)
      T.eq(result2.skipped, 1)
      T.eq(#result2.errors, 0)
    end)

    T.it("does not skip an entry whose amount differs, even with the same date/description", function()
      local b = new_bridge()
      local first = "Date,Description,Amount\n2026-01-05,Coffee shop,-4.50\n"
      local second = "Date,Description,Amount\n2026-01-05,Coffee shop,-9.00\n"

      local result1, err1 = import_mod.from_string(b, first, base_opts({ format = "csv", mapper = CSV_MAPPER }))
      T.ok(result1 ~= nil, err1)
      T.eq(result1.imported, 1)

      local result2, err2 = import_mod.from_string(b, second, base_opts({ format = "csv", mapper = CSV_MAPPER }))
      T.ok(result2 ~= nil, err2)
      T.eq(result2.imported, 1)
      T.eq(result2.skipped, 0)
    end)
  end)

end)
