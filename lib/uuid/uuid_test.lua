-- lib/uuid/uuid_test.lua
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local uuid = require("lib.uuid")

local function time_fn() return os.time() end

local UUID_PAT = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

T.describe("uuid", function()

	T.it("_tier is a known value", function()
		local valid = {
			ffi_getrandom  = true,
			ffi_arc4random = true,
			ffi_devurandom = true,
			pure           = true,
		}
		T.ok(valid[uuid._tier], "_tier=" .. tostring(uuid._tier))
	end)

	T.describe("v4", function()
		T.it("produces a string of correct length and format", function()
			local s = uuid.v4()
			T.eq(type(s), "string")
			T.eq(#s, 36)
			T.ok(s:match(UUID_PAT), "format: " .. s)
		end)

		T.it("version nibble is 4", function()
			local s = uuid.v4()
			-- byte 7 high nibble = version; chars 15-15 in UUID string (after two dashes)
			-- UUID: xxxxxxxx-xxxx-Mxxx-Nxxx-xxxxxxxxxxxx
			-- char positions (1-indexed): 1-8, 10-13, 15-18, 20-23, 25-36
			-- M is at position 15
			T.eq(s:sub(15, 15), "4", "version nibble: " .. s)
		end)

		T.it("variant bits are 10xx (8, 9, a, or b)", function()
			local s = uuid.v4()
			-- N is at position 20
			local variant_char = s:sub(20, 20)
			local valid_variants = { ["8"] = true, ["9"] = true, ["a"] = true, ["b"] = true }
			T.ok(valid_variants[variant_char], "variant char=" .. variant_char .. " in: " .. s)
		end)

		T.it("consecutive calls produce different UUIDs", function()
			local a = uuid.v4()
			local b = uuid.v4()
			T.neq(a, b)
		end)
	end)

	T.describe("v7", function()
		T.it("produces a string of correct length and format", function()
			local s = uuid.v7(time_fn)
			T.eq(type(s), "string")
			T.eq(#s, 36)
			T.ok(s:match(UUID_PAT), "format: " .. s)
		end)

		T.it("version nibble is 7", function()
			local s = uuid.v7(time_fn)
			T.eq(s:sub(15, 15), "7", "version nibble: " .. s)
		end)

		T.it("variant bits are 10xx", function()
			local s = uuid.v7(time_fn)
			local variant_char = s:sub(20, 20)
			local valid_variants = { ["8"] = true, ["9"] = true, ["a"] = true, ["b"] = true }
			T.ok(valid_variants[variant_char], "variant char=" .. variant_char .. " in: " .. s)
		end)

		T.it("successive calls are monotonically increasing (string sort)", function()
			local prev = uuid.v7(time_fn)
			for _ = 1, 20 do
				local next = uuid.v7(time_fn)
				T.ok(next >= prev, "not monotonic: " .. prev .. " -> " .. next)
				prev = next
			end
		end)

		T.it("UUIDs generated in same millisecond are distinct and sorted", function()
			-- Generate a burst; they may or may not be in the same ms.
			-- We force same-ms by calling many in a tight loop.
			local results = {}
			for _ = 1, 100 do
				results[#results + 1] = uuid.v7(time_fn)
			end
			-- Check all distinct
			local seen = {}
			for _, s in ipairs(results) do
				T.ok(not seen[s], "duplicate UUID: " .. s)
				seen[s] = true
			end
			-- Check sorted
			for i = 2, #results do
				T.ok(results[i] >= results[i - 1],
					"not sorted: " .. results[i - 1] .. " -> " .. results[i])
			end
		end)
	end)

	T.describe("fmt + parse", function()
		T.it("parse returns nil for invalid inputs", function()
			T.ok(uuid.parse("not-a-uuid") == nil)
			T.ok(uuid.parse("") == nil)
			T.ok(uuid.parse("00000000-0000-0000-0000-0000000000zz") == nil)  -- invalid hex
			T.ok(uuid.parse("00000000000000000000000000000000") == nil)      -- no dashes
		end)

		T.it("parse -> fmt round-trips a known UUID", function()
			local s = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
			local bin = uuid.parse(s)
			T.ok(bin ~= nil, "parse returned nil")
			T.eq(#bin, 16)
			T.eq(uuid.fmt(bin), s)
		end)

		T.it("parse -> fmt round-trips v4 output", function()
			local s = uuid.v4()
			local bin = uuid.parse(s)
			T.ok(bin ~= nil)
			T.eq(uuid.fmt(bin), s)
		end)

		T.it("parse -> fmt round-trips v7 output", function()
			local s = uuid.v7(time_fn)
			local bin = uuid.parse(s)
			T.ok(bin ~= nil)
			T.eq(uuid.fmt(bin), s)
		end)
	end)

	T.describe("is_valid", function()
		T.it("accepts valid UUID strings", function()
			T.ok(uuid.is_valid("f47ac10b-58cc-4372-a567-0e02b2c3d479"))
			T.ok(uuid.is_valid(uuid.v4()))
			T.ok(uuid.is_valid(uuid.v7(time_fn)))
		end)

		T.it("rejects malformed strings", function()
			T.fail(uuid.is_valid("not-a-uuid"))
			T.fail(uuid.is_valid(""))
			T.fail(uuid.is_valid("f47ac10b-58cc-4372-a567-0e02b2c3d47"))   -- too short
			T.fail(uuid.is_valid("f47ac10b-58cc-4372-a567-0e02b2c3d4790"))  -- too long
			T.fail(uuid.is_valid("f47ac10b-58cc-4372-a567-0e02b2c3d47z"))   -- invalid char
		end)
	end)

end)
