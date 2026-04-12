-- lib/tar/tar_test.lua
-- Tests for lib/tar (ustar reader/writer).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local tar = require("lib.tar")

T.describe("tar.write / tar.read round-trip", function()
    T.it("single regular file", function()
        local entries = {
            { name = "hello.txt", data = "Hello, world!\n", mode = 0x1A4, mtime = 1000 },
        }
        local bytes, err = tar.write(entries)
        T.ok(bytes, err)
        -- Archive must be at least 3*512 bytes (header + data block + 2 zero blocks)
        T.ok(#bytes >= 3 * 512)
        T.ok(#bytes % 512 == 0)

        local got, err2 = tar.read(bytes)
        T.ok(got, err2)
        T.eq(#got, 1)
        T.eq(got[1].name, "hello.txt")
        T.eq(got[1].data, "Hello, world!\n")
        T.eq(got[1].mode, 0x1A4)
        T.eq(got[1].mtime, 1000)
        T.eq(got[1].typeflag, "0")
        T.eq(got[1].size, 14)
    end)

    T.it("multiple files", function()
        local entries = {
            { name = "a.txt", data = "AAA" },
            { name = "b.txt", data = "BBBBB" },
            { name = "c.txt", data = "CC" },
        }
        local bytes, err = tar.write(entries)
        T.ok(bytes, err)

        local got, err2 = tar.read(bytes)
        T.ok(got, err2)
        T.eq(#got, 3)
        T.eq(got[1].name, "a.txt")
        T.eq(got[1].data, "AAA")
        T.eq(got[2].name, "b.txt")
        T.eq(got[2].data, "BBBBB")
        T.eq(got[3].name, "c.txt")
        T.eq(got[3].data, "CC")
    end)

    T.it("empty archive", function()
        local bytes, err = tar.write({})
        T.ok(bytes, err)
        -- Just the two zero-block end marker
        T.eq(#bytes, 2 * 512)

        local got, err2 = tar.read(bytes)
        T.ok(got, err2)
        T.eq(#got, 0)
    end)

    T.it("binary data", function()
        local data = ""
        for i = 0, 255 do
            data = data .. string.char(i)
        end
        local entries = { { name = "binary.bin", data = data } }
        local bytes, err = tar.write(entries)
        T.ok(bytes, err)

        local got, err2 = tar.read(bytes)
        T.ok(got, err2)
        T.eq(#got, 1)
        T.eq(got[1].data, data)
        T.eq(got[1].size, 256)
    end)

    T.it("file larger than 512 bytes", function()
        local data = string.rep("x", 1500)
        local entries = { { name = "big.txt", data = data } }
        local bytes, err = tar.write(entries)
        T.ok(bytes, err)
        -- header(512) + ceil(1500/512)*512 = 512 + 3*512 = 4*512 + 2*512 end
        T.eq(#bytes, (1 + 3 + 2) * 512)

        local got, err2 = tar.read(bytes)
        T.ok(got, err2)
        T.eq(#got, 1)
        T.eq(got[1].data, data)
        T.eq(got[1].size, 1500)
    end)

    T.it("file exactly 512 bytes", function()
        local data = string.rep("y", 512)
        local entries = { { name = "exact.bin", data = data } }
        local bytes, err = tar.write(entries)
        T.ok(bytes, err)

        local got, err2 = tar.read(bytes)
        T.ok(got, err2)
        T.eq(got[1].data, data)
        T.eq(got[1].size, 512)
    end)

    T.it("empty file", function()
        local entries = { { name = "empty.txt", data = "" } }
        local bytes, err = tar.write(entries)
        T.ok(bytes, err)
        -- header(512) + 2 zero blocks
        T.eq(#bytes, 3 * 512)

        local got, err2 = tar.read(bytes)
        T.ok(got, err2)
        T.eq(#got, 1)
        T.eq(got[1].name, "empty.txt")
        T.eq(got[1].data, "")
        T.eq(got[1].size, 0)
    end)

    T.it("directory entry", function()
        local entries = {
            { name = "mydir/", data = "", typeflag = "5" },
            { name = "mydir/file.txt", data = "content" },
        }
        local bytes, err = tar.write(entries)
        T.ok(bytes, err)

        local got, err2 = tar.read(bytes)
        T.ok(got, err2)
        T.eq(#got, 2)
        T.eq(got[1].typeflag, "5")
        T.eq(got[2].name, "mydir/file.txt")
    end)

    T.it("default mode is 0644", function()
        local entries = { { name = "f.txt", data = "hi" } }
        local bytes = tar.write(entries)
        local got = tar.read(bytes)
        T.eq(got[1].mode, 0x1A4)  -- 0644 octal
    end)
end)

T.describe("tar.get", function()
    T.it("finds file by path", function()
        local entries = {
            { name = "a.txt", data = "alpha" },
            { name = "b.txt", data = "beta" },
        }
        local bytes = tar.write(entries)
        local got = tar.read(bytes)
        T.eq(tar.get(got, "a.txt"), "alpha")
        T.eq(tar.get(got, "b.txt"), "beta")
    end)

    T.it("returns nil for missing path", function()
        local bytes = tar.write({ { name = "x.txt", data = "X" } })
        local got = tar.read(bytes)
        T.eq(tar.get(got, "nothere.txt"), nil)
    end)
end)

T.describe("tar codec aliases", function()
    T.it("encode/decode aliases work", function()
        local entries = { { name = "t.txt", data = "test" } }
        local bytes = tar.encode(entries)
        T.ok(type(bytes) == "string")
        local got = tar.decode(bytes)
        T.ok(got)
        T.eq(got[1].data, "test")
    end)

    T.it("string_to_tar / tar_to_string aliases work", function()
        local entries = { { name = "s.txt", data = "str" } }
        local bytes = tar.tar_to_string(entries)
        T.ok(type(bytes) == "string")
        local got = tar.string_to_tar(bytes)
        T.ok(got)
        T.eq(got[1].data, "str")
    end)
end)

T.describe("tar.read error handling", function()
    T.it("returns nil,err on bad checksum", function()
        local entries = { { name = "f.txt", data = "hi" } }
        local bytes = tar.write(entries)
        -- Corrupt a byte in the header (position 5, inside the name field)
        bytes = bytes:sub(1, 4) .. "\xFF" .. bytes:sub(6)
        local got, err = tar.read(bytes)
        T.eq(got, nil)
        T.ok(type(err) == "string")
    end)
end)
