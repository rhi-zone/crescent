-- lib/luhn/luhn_test.lua
-- Tests for lib/luhn (Luhn algorithm, card type detection, formatting).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local luhn = require("lib.luhn")
local T = require("lib.test.assert")

-- ── luhn.valid ────────────────────────────────────────────────────────────────

T.describe("luhn.valid", function()
	T.it("accepts known-valid card numbers", function()
		T.ok(luhn.valid("4532015112830366"),  "Visa test card")
		T.ok(luhn.valid("5425233430109903"),  "Mastercard test card")
		T.ok(luhn.valid("378282246310005"),   "Amex test card")
		T.ok(luhn.valid("6011111111111117"),  "Discover test card")
		T.ok(luhn.valid("3530111333300000"),  "JCB test card")
		T.ok(luhn.valid("36700102000000"),    "Diners test card")
	end)

	T.it("rejects known-invalid numbers", function()
		T.fail(luhn.valid("4532015112830367"),  "Visa with wrong check digit")
		T.fail(luhn.valid("1234567890123456"),  "random invalid number")
		T.fail(luhn.valid("9999999999999999"),  "invalid all-nines number")
	end)

	T.it("strips spaces before validating", function()
		T.ok(luhn.valid("4532 0151 1283 0366"),  "Visa with spaces")
		T.ok(luhn.valid("5425 2334 3010 9903"),  "Mastercard with spaces")
	end)

	T.it("strips dashes before validating", function()
		T.ok(luhn.valid("4532-0151-1283-0366"),   "Visa with dashes")
		T.ok(luhn.valid("3782-822463-10005"),      "Amex with dashes")
	end)

	T.it("strips mixed spaces and dashes", function()
		T.ok(luhn.valid("4532-0151 1283-0366"), "mixed separators")
	end)

	T.it("returns false for empty string", function()
		T.fail(luhn.valid(""), "empty string")
	end)

	T.it("returns false for non-digit input", function()
		T.fail(luhn.valid("abcdef"),     "letters")
		T.fail(luhn.valid("4532abc366"), "mixed digits and letters")
		T.fail(luhn.valid("4532.0151"),  "dot separator not allowed")
	end)

	T.it("returns false for non-string input", function()
		T.fail(luhn.valid(nil),    "nil")
		T.fail(luhn.valid(42),     "number")
		T.fail(luhn.valid(true),   "boolean")
	end)

	T.it("single digit 0 is valid Luhn", function()
		-- 0 has Luhn sum 0, which is divisible by 10.
		T.ok(luhn.valid("0"), "single zero")
	end)
end)

-- ── luhn.check_digit ──────────────────────────────────────────────────────────

T.describe("luhn.check_digit", function()
	T.it("computes correct check digit for Visa payload", function()
		-- 4532015112830366 → payload is 453201511283036, check digit is 6
		T.eq(luhn.check_digit("453201511283036"), 6)
	end)

	T.it("computes correct check digit for Mastercard payload", function()
		-- 5425233430109903 → payload 542523343010990, check digit 3
		T.eq(luhn.check_digit("542523343010990"), 3)
	end)

	T.it("computes correct check digit for Amex payload", function()
		-- 378282246310005 → payload 37828224631000, check digit 5
		T.eq(luhn.check_digit("37828224631000"), 5)
	end)

	T.it("computes correct check digit for Discover payload", function()
		-- 6011111111111117 → payload 601111111111111, check digit 7
		T.eq(luhn.check_digit("601111111111111"), 7)
	end)

	T.it("returns nil for empty string", function()
		local cd, err = luhn.check_digit("")
		T.eq(cd, nil)
		T.ok(err, "error message present")
	end)

	T.it("returns nil for non-digit input", function()
		local cd, err = luhn.check_digit("abc")
		T.eq(cd, nil)
		T.ok(err, "error message present")
	end)

	T.it("computed check digit produces valid number", function()
		local payload = "79927398710"
		local cd = luhn.check_digit(payload)
		T.ok(luhn.valid(payload .. tostring(cd)), "appended check digit is valid")
	end)
end)

-- ── luhn.generate ─────────────────────────────────────────────────────────────

T.describe("luhn.generate", function()
	T.it("generates a valid 16-digit Visa number", function()
		local n = luhn.generate("4", 16)
		T.eq(#n, 16,                       "length is 16")
		T.eq(n:sub(1, 1), "4",             "starts with 4")
		T.ok(luhn.valid(n),                "passes Luhn check")
	end)

	T.it("generates a valid 16-digit Mastercard number", function()
		local n = luhn.generate("51", 16)
		T.eq(#n, 16,                       "length is 16")
		T.eq(n:sub(1, 2), "51",            "starts with 51")
		T.ok(luhn.valid(n),                "passes Luhn check")
	end)

	T.it("generates a valid 15-digit Amex number", function()
		local n = luhn.generate("37", 15)
		T.eq(#n, 15,                       "length is 15")
		T.eq(n:sub(1, 2), "37",            "starts with 37")
		T.ok(luhn.valid(n),                "passes Luhn check")
	end)

	T.it("generates a valid number for longer prefix", function()
		local n = luhn.generate("6011", 16)
		T.eq(#n, 16,                       "length is 16")
		T.eq(n:sub(1, 4), "6011",          "starts with 6011")
		T.ok(luhn.valid(n),                "passes Luhn check")
	end)

	T.it("returns nil when prefix length >= total length", function()
		local n, err = luhn.generate("4532", 4)
		T.eq(n, nil)
		T.ok(err, "error message present")
	end)

	T.it("returns nil for non-digit prefix", function()
		local n, err = luhn.generate("4x", 16)
		T.eq(n, nil)
		T.ok(err, "error message present")
	end)
end)

-- ── luhn.card_type ────────────────────────────────────────────────────────────

T.describe("luhn.card_type", function()
	T.it("identifies Visa", function()
		T.eq(luhn.card_type("4532015112830366"), "visa")
	end)

	T.it("identifies Mastercard (51–55 range)", function()
		T.eq(luhn.card_type("5425233430109903"), "mastercard")
	end)

	T.it("identifies Mastercard (2221–2720 range)", function()
		-- 2720990000000000 is a valid Mastercard prefix in the new range
		-- Use generate to make a valid number so length check passes
		local n = luhn.generate("2720", 16)
		T.eq(luhn.card_type(n), "mastercard")
	end)

	T.it("identifies Amex (34 prefix)", function()
		local n = luhn.generate("34", 15)
		T.eq(luhn.card_type(n), "amex")
	end)

	T.it("identifies Amex (37 prefix)", function()
		T.eq(luhn.card_type("378282246310005"), "amex")
	end)

	T.it("identifies Discover (6011 prefix)", function()
		T.eq(luhn.card_type("6011111111111117"), "discover")
	end)

	T.it("identifies Discover (65 prefix)", function()
		local n = luhn.generate("65", 16)
		T.eq(luhn.card_type(n), "discover")
	end)

	T.it("identifies JCB", function()
		T.eq(luhn.card_type("3530111333300000"), "jcb")
	end)

	T.it("identifies Diners Club (36 prefix)", function()
		T.eq(luhn.card_type("36700102000000"), "diners")
	end)

	T.it("identifies Diners Club (300–305 prefix)", function()
		local n = luhn.generate("300", 14)
		T.eq(luhn.card_type(n), "diners")
	end)

	T.it("identifies UnionPay", function()
		local n = luhn.generate("62", 16)
		T.eq(luhn.card_type(n), "unionpay")
	end)

	T.it("returns nil for unknown prefix", function()
		T.eq(luhn.card_type("9999999999999999"), nil)
	end)

	T.it("returns nil for empty string", function()
		T.eq(luhn.card_type(""), nil)
	end)

	T.it("strips spaces when detecting type", function()
		T.eq(luhn.card_type("4532 0151 1283 0366"), "visa")
	end)
end)

-- ── luhn.card_info ────────────────────────────────────────────────────────────

T.describe("luhn.card_info", function()
	T.it("returns correct info for visa", function()
		local info = luhn.card_info("visa")
		T.eq(info.name, "Visa")
		T.ok(type(info.lengths) == "table", "lengths is a table")
		-- Visa accepts 13 or 16
		local has13, has16 = false, false
		for _, l in ipairs(info.lengths) do
			if l == 13 then has13 = true end
			if l == 16 then has16 = true end
		end
		T.ok(has16, "Visa accepts 16-digit")
	end)

	T.it("returns correct info for amex", function()
		local info = luhn.card_info("amex")
		T.eq(info.name, "American Express")
		T.eq(info.lengths[1], 15)
	end)

	T.it("returns correct info for mastercard", function()
		local info = luhn.card_info("mastercard")
		T.eq(info.name, "Mastercard")
		T.eq(info.lengths[1], 16)
	end)

	T.it("returns nil for unknown type", function()
		local info, err = luhn.card_info("unknown_card")
		T.eq(info, nil)
		T.ok(err, "error message present")
	end)
end)

-- ── luhn.card_types ───────────────────────────────────────────────────────────

T.describe("luhn.card_types", function()
	T.it("returns array containing expected types", function()
		local types = luhn.card_types()
		T.ok(type(types) == "table", "returns table")
		local found = {}
		for _, t in ipairs(types) do found[t] = true end
		T.ok(found["visa"],       "includes visa")
		T.ok(found["mastercard"], "includes mastercard")
		T.ok(found["amex"],       "includes amex")
		T.ok(found["discover"],   "includes discover")
		T.ok(found["jcb"],        "includes jcb")
		T.ok(found["diners"],     "includes diners")
		T.ok(found["unionpay"],   "includes unionpay")
	end)

	T.it("has at least 7 entries", function()
		local types = luhn.card_types()
		T.ok(#types >= 7, "at least 7 card types")
	end)
end)

-- ── luhn.format ───────────────────────────────────────────────────────────────

T.describe("luhn.format", function()
	T.it("formats Visa 16-digit as 4-4-4-4", function()
		T.eq(luhn.format("4532015112830366"), "4532 0151 1283 0366")
	end)

	T.it("formats Mastercard as 4-4-4-4", function()
		T.eq(luhn.format("5425233430109903"), "5425 2334 3010 9903")
	end)

	T.it("formats Amex as 4-6-5", function()
		T.eq(luhn.format("378282246310005"), "3782 822463 10005")
	end)

	T.it("formats Diners as 4-6-4", function()
		T.eq(luhn.format("36700102000000"), "3670 010200 0000")
	end)

	T.it("formats Discover as 4-4-4-4", function()
		T.eq(luhn.format("6011111111111117"), "6011 1111 1111 1117")
	end)

	T.it("formats JCB as 4-4-4-4", function()
		T.eq(luhn.format("3530111333300000"), "3530 1113 3330 0000")
	end)

	T.it("strips input separators before formatting", function()
		T.eq(luhn.format("4532 0151 1283 0366"), "4532 0151 1283 0366")
		T.eq(luhn.format("4532-0151-1283-0366"), "4532 0151 1283 0366")
	end)

	T.it("formats short/unknown numbers in groups of 4", function()
		T.eq(luhn.format("12345678"), "1234 5678")
		T.eq(luhn.format("123456789012"), "1234 5678 9012")
		T.eq(luhn.format("12345"),        "1234 5")
	end)

	T.it("formats single group (fewer than 4 digits)", function()
		T.eq(luhn.format("123"), "123")
	end)
end)

-- ── _tier ─────────────────────────────────────────────────────────────────────

T.describe("module metadata", function()
	T.it("_tier is 'pure'", function()
		T.eq(luhn._tier, "pure")
	end)
end)
