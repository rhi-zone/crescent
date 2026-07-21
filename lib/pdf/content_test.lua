-- lib/pdf/content_test.lua
-- Tests for lib/pdf/content.lua's content-stream operator parser.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local content = require("lib.pdf.content")

--: (unknown) -> { [string]: unknown, [integer]: unknown }
local function as_table(v)
	if type(v) ~= "table" then error("expected table, got " .. type(v)) end
	return v
end

T.describe("content: basic operators", function()
	T.it("parses a simple BT ... Tf ... Tj ... ET sequence", function()
		local stream = "BT /F1 12 Tf 100 700 Td (Hello) Tj ET"
		local ops, err = content.string_to_content_stream(stream)
		T.eq(err, nil)
		local o = as_table(ops)
		T.eq(#o, 5)
		T.eq(as_table(o[1]).op, "BT")
		T.eq(#as_table(as_table(o[1]).args --[[: unknown]]), 0)

		local tf = as_table(o[2])
		T.eq(tf.op, "Tf")
		local tf_args = as_table(tf.args --[[: unknown]])
		T.eq(as_table(tf_args[1]).value, "F1")
		T.eq(tf_args[2], 12)

		local td = as_table(o[3])
		T.eq(td.op, "Td")
		local td_args = as_table(td.args --[[: unknown]])
		T.eq(td_args[1], 100)
		T.eq(td_args[2], 700)

		local tj = as_table(o[4])
		T.eq(tj.op, "Tj")
		local tj_args = as_table(tj.args --[[: unknown]])
		T.eq(tj_args[1], "Hello")

		T.eq(as_table(o[5]).op, "ET")
	end)

	T.it("parses a TJ array with position adjustments", function()
		local stream = "[(AB) -120 (CD) 50 (EF)] TJ"
		local ops = as_table(content.string_to_content_stream(stream))
		local op1 = as_table(ops[1])
		T.eq(op1.op, "TJ")
		local args = as_table(op1.args --[[: unknown]])
		local arr = as_table(args[1])
		T.eq(arr[1], "AB")
		T.eq(arr[2], -120)
		T.eq(arr[3], "CD")
		T.eq(arr[4], 50)
		T.eq(arr[5], "EF")
	end)

	T.it("parses q/cm/Q as uniform ops with numeric args", function()
		local stream = "q 2 0 0 2 0 0 cm Q"
		local ops = as_table(content.string_to_content_stream(stream))
		T.eq(#ops, 3)
		T.eq(as_table(ops[1]).op, "q")
		local cm = as_table(ops[2])
		T.eq(cm.op, "cm")
		local cm_args = as_table(cm.args --[[: unknown]])
		T.eq(cm_args[1], 2)
		T.eq(cm_args[2], 0)
		T.eq(cm_args[3], 0)
		T.eq(cm_args[4], 2)
		T.eq(cm_args[5], 0)
		T.eq(cm_args[6], 0)
		T.eq(as_table(ops[3]).op, "Q")
	end)

	T.it("parses single-character operators ' and \" and T*", function()
		local stream = "(hi) '\n1 2 (yo) \"\nT*"
		local ops = as_table(content.string_to_content_stream(stream))
		T.eq(#ops, 3)
		T.eq(as_table(ops[1]).op, "'")
		T.eq(as_table(ops[2]).op, "\"")
		T.eq(as_table(ops[3]).op, "T*")
	end)

	T.it("skips comments between operators", function()
		local stream = "% a comment\nBT\n% another\nET"
		local ops = as_table(content.string_to_content_stream(stream))
		T.eq(#ops, 2)
		T.eq(as_table(ops[1]).op, "BT")
		T.eq(as_table(ops[2]).op, "ET")
	end)

	T.it("recognizes unknown/opaque operators uniformly", function()
		local stream = "0 0 1 rg 0 0 100 100 re f"
		local ops = as_table(content.string_to_content_stream(stream))
		T.eq(#ops, 3)
		T.eq(as_table(ops[1]).op, "rg")
		T.eq(as_table(ops[2]).op, "re")
		T.eq(as_table(ops[3]).op, "f")
	end)
end)

T.describe("content: inline images", function()
	T.it("skips an inline image's binary data without corrupting later parsing", function()
		-- Binary data intentionally contains bytes that would break generic
		-- object-syntax parsing (a raw '(' and ')' unbalanced) to prove the
		-- data is treated as opaque raw bytes, not PDF object syntax.
		local binary = "\1\2)(\255\254\0garbage"
		local stream = "BI /W 2 /H 2 /BPC 8 /CS /G ID " .. binary .. " EI\nBT ET"
		local ops, err = content.string_to_content_stream(stream)
		T.eq(err, nil)
		local o = as_table(ops)
		T.eq(#o, 3)
		local img = as_table(o[1])
		T.eq(img.op, "INLINE_IMAGE")
		local dict = as_table(img.dict --[[: unknown]])
		T.eq(dict.W, 2)
		T.eq(dict.H, 2)
		T.eq(dict.BPC, 8)
		T.eq(as_table(dict.CS).value, "G")
		T.eq(img.data, binary)
		T.eq(as_table(o[2]).op, "BT")
		T.eq(as_table(o[3]).op, "ET")
	end)

	T.it("errors clearly when EI is missing", function()
		local stream = "BI /W 1 ID \1\2\3"
		local ops, err = content.string_to_content_stream(stream)
		T.ok(ops == nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("content: error cases", function()
	T.it("errors on a malformed operand rather than silently misparsing", function()
		local stream = "(unterminated string BT"
		local ops, err = content.string_to_content_stream(stream)
		T.ok(ops == nil)
		T.ok(err ~= nil)
	end)
end)
