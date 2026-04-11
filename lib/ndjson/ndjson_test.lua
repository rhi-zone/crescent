-- lib/ndjson/ndjson_test.lua
if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local ndjson = require("lib.ndjson")

T.describe("ndjson._tier", function()
    T.it("is pure", function()
        T.eq(ndjson._tier, "pure")
    end)
end)

T.describe("ndjson.encode_line", function()
    T.it("encodes an object with trailing newline", function()
        local line = ndjson.encode_line({ id = 1, name = "Alice" })
        T.ok(type(line) == "string", "should return string")
        T.ok(line:sub(-1) == "\n", "should end with newline")
        -- parse back to verify
        local json = require("lib.format.json")
        local v = json.decode(line:sub(1, -2))
        T.eq(v.id, 1)
        T.eq(v.name, "Alice")
    end)

    T.it("encodes a scalar", function()
        T.eq(ndjson.encode_line(42), "42\n")
    end)

    T.it("encodes a string", function()
        T.eq(ndjson.encode_line("hello"), '"hello"\n')
    end)

    T.it("encodes a boolean", function()
        T.eq(ndjson.encode_line(true), "true\n")
        T.eq(ndjson.encode_line(false), "false\n")
    end)

    T.it("encodes an array", function()
        T.eq(ndjson.encode_line({1, 2, 3}), "[1,2,3]\n")
    end)
end)

T.describe("ndjson.encode", function()
    T.it("encodes multiple objects", function()
        local data = {
            { id = 1, name = "Alice" },
            { id = 2, name = "Bob" },
            { id = 3, name = "Carol" },
        }
        local result = ndjson.encode(data)
        T.ok(type(result) == "string", "should return string")
        local lines = {}
        for line in (result):gmatch("[^\n]+") do
            lines[#lines + 1] = line
        end
        T.eq(#lines, 3)
    end)

    T.it("returns empty string for empty array", function()
        T.eq(ndjson.encode({}), "")
    end)

    T.it("ends with a trailing newline for non-empty input", function()
        local result = ndjson.encode({ {x = 1} })
        T.ok(result:sub(-1) == "\n", "should end with newline")
    end)

    T.it("encodes mixed types", function()
        local result = ndjson.encode({ 1, "two", true, false, {3, 4} })
        T.ok(type(result) == "string")
        local lines = {}
        for line in result:gmatch("[^\n]+") do
            lines[#lines + 1] = line
        end
        T.eq(#lines, 5)
        T.eq(lines[1], "1")
        T.eq(lines[2], '"two"')
        T.eq(lines[3], "true")
        T.eq(lines[4], "false")
        T.eq(lines[5], "[3,4]")
    end)
end)

T.describe("ndjson.decode_line", function()
    T.it("decodes an object", function()
        local v = ndjson.decode_line('{"id":1,"name":"Alice"}')
        T.eq(v.id, 1)
        T.eq(v.name, "Alice")
    end)

    T.it("decodes a scalar", function()
        local v = ndjson.decode_line("42")
        T.eq(v, 42)
    end)

    T.it("returns nil and error for invalid JSON", function()
        local v, err = ndjson.decode_line("{bad json}")
        T.eq(v, nil)
        T.ok(type(err) == "string", "should return error string")
    end)
end)

T.describe("ndjson.decode", function()
    T.it("decodes NDJSON string to array", function()
        local data = '{"id":1,"name":"Alice"}\n{"id":2,"name":"Bob"}\n{"id":3,"name":"Carol"}\n'
        local arr = ndjson.decode(data)
        T.eq(#arr, 3)
        T.eq(arr[1].id, 1)
        T.eq(arr[1].name, "Alice")
        T.eq(arr[2].id, 2)
        T.eq(arr[2].name, "Bob")
        T.eq(arr[3].id, 3)
        T.eq(arr[3].name, "Carol")
    end)

    T.it("returns empty array for empty input", function()
        local arr = ndjson.decode("")
        T.eq(#arr, 0)
    end)

    T.it("skips blank lines", function()
        local data = '{"a":1}\n\n{"b":2}\n\n'
        local arr = ndjson.decode(data)
        T.eq(#arr, 2)
        T.eq(arr[1].a, 1)
        T.eq(arr[2].b, 2)
    end)

    T.it("skips comment lines starting with #", function()
        local data = '# header comment\n{"a":1}\n# another comment\n{"b":2}\n'
        local arr = ndjson.decode(data)
        T.eq(#arr, 2)
        T.eq(arr[1].a, 1)
        T.eq(arr[2].b, 2)
    end)

    T.it("handles mixed blank and comment lines", function()
        local data = '\n# comment\n\n{"x":99}\n'
        local arr = ndjson.decode(data)
        T.eq(#arr, 1)
        T.eq(arr[1].x, 99)
    end)

    T.it("decodes mixed types", function()
        local data = '1\n"two"\ntrue\nfalse\n[3,4]\n'
        local arr = ndjson.decode(data)
        T.eq(#arr, 5)
        T.eq(arr[1], 1)
        T.eq(arr[2], "two")
        T.eq(arr[3], true)
        T.eq(arr[4], false)
        T.eq(arr[5][1], 3)
        T.eq(arr[5][2], 4)
    end)

    T.it("returns nil and error for invalid JSON line", function()
        local data = '{"a":1}\n{bad}\n{"c":3}\n'
        local arr, err = ndjson.decode(data)
        T.eq(arr, nil)
        T.ok(type(err) == "string", "should return error string")
        T.ok(err:find("line"), "error should mention line")
    end)
end)

T.describe("ndjson round-trip", function()
    T.it("encode then decode gives back original values", function()
        local original = {
            { id = 1, name = "Alice", score = 9.5 },
            { id = 2, name = "Bob",   score = 7.0 },
        }
        local encoded = ndjson.encode(original)
        local decoded = ndjson.decode(encoded)
        T.eq(#decoded, 2)
        T.eq(decoded[1].id, 1)
        T.eq(decoded[1].name, "Alice")
        T.eq(decoded[1].score, 9.5)
        T.eq(decoded[2].id, 2)
        T.eq(decoded[2].name, "Bob")
    end)

    T.it("single line round-trip", function()
        local v = { key = "value", num = 123 }
        local line = ndjson.encode_line(v)
        local back = ndjson.decode_line(line:sub(1, -2))
        T.eq(back.key, "value")
        T.eq(back.num, 123)
    end)
end)

T.describe("ndjson.iter", function()
    T.it("iterates over all values", function()
        local data = '{"a":1}\n{"b":2}\n{"c":3}\n'
        local results = {}
        for value in ndjson.iter(data) do
            results[#results + 1] = value
        end
        T.eq(#results, 3)
        T.eq(results[1].a, 1)
        T.eq(results[2].b, 2)
        T.eq(results[3].c, 3)
    end)

    T.it("skips blank lines and comments in iterator", function()
        local data = '\n# skip\n{"x":10}\n\n{"y":20}\n'
        local results = {}
        for value in ndjson.iter(data) do
            results[#results + 1] = value
        end
        T.eq(#results, 2)
        T.eq(results[1].x, 10)
        T.eq(results[2].y, 20)
    end)

    T.it("returns empty iterator for empty input", function()
        local count = 0
        for _ in ndjson.iter("") do
            count = count + 1
        end
        T.eq(count, 0)
    end)

    T.it("yields nil, err on invalid JSON", function()
        local data = '{"ok":1}\n{bad}\n'
        local values = {}
        local got_err
        -- Use raw iterator to capture the nil, err pair (for loop stops on nil)
        local iter = ndjson.iter(data)
        while true do
            local value, err = iter()
            if value == nil and err == nil then break end
            if err then
                got_err = err
            else
                values[#values + 1] = value
            end
        end
        T.eq(#values, 1)
        T.ok(got_err ~= nil, "should have gotten an error")
    end)

    T.it("iterates mixed scalar types", function()
        local data = '1\n2\n3\n'
        local sum = 0
        for value in ndjson.iter(data) do
            sum = sum + value
        end
        T.eq(sum, 6)
    end)
end)

T.describe("ndjson.encoder", function()
    T.it("write returns encoded line", function()
        local enc = ndjson.encoder()
        local line = enc:write({ id = 1 })
        T.ok(type(line) == "string")
        T.ok(line:sub(-1) == "\n")
    end)

    T.it("lines returns all written lines", function()
        local enc = ndjson.encoder()
        enc:write(1)
        enc:write(2)
        enc:write(3)
        local lines = enc:lines()
        T.eq(#lines, 3)
        T.eq(lines[1], "1\n")
        T.eq(lines[2], "2\n")
        T.eq(lines[3], "3\n")
    end)

    T.it("lines returns a copy (mutation does not affect encoder)", function()
        local enc = ndjson.encoder()
        enc:write(42)
        local lines = enc:lines()
        lines[1] = "tampered"
        local lines2 = enc:lines()
        T.eq(lines2[1], "42\n")
    end)

    T.it("write returns nil, err on unencodable value", function()
        -- coroutines cannot be JSON-encoded
        local enc = ndjson.encoder()
        local line, err = enc:write(coroutine.create(function() end))
        T.eq(line, nil)
        T.ok(type(err) == "string")
    end)

    T.it("multiple writes accumulate", function()
        local enc = ndjson.encoder()
        for i = 1, 5 do
            enc:write({ n = i })
        end
        local lines = enc:lines()
        T.eq(#lines, 5)
    end)
end)
