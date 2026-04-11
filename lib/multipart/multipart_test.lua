-- lib/multipart/multipart_test.lua
-- Tests for MIME multipart encoder and decoder (RFC 2046).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = require("lib.multipart")
local T = require("lib.test.assert")

-- ── Module metadata ───────────────────────────────────────────────────────────

T.describe("module metadata", function()
    T.it("_tier is pure", function()
        T.eq(M._tier, "pure")
    end)
end)

-- ── parse_boundary ────────────────────────────────────────────────────────────

T.describe("parse_boundary", function()
    T.it("extracts unquoted boundary", function()
        T.eq(M.parse_boundary("multipart/form-data; boundary=abc123"), "abc123")
    end)

    T.it("extracts quoted boundary", function()
        T.eq(M.parse_boundary('multipart/form-data; boundary="abc 123"'), "abc 123")
    end)

    T.it("handles leading spaces around equals", function()
        T.eq(M.parse_boundary("multipart/mixed; boundary = mybound"), "mybound")
    end)

    T.it("is case insensitive for Boundary keyword", function()
        T.eq(M.parse_boundary("multipart/form-data; Boundary=xyz"), "xyz")
    end)

    T.it("returns nil,err when no boundary", function()
        local b, err = M.parse_boundary("text/plain")
        T.eq(b, nil)
        T.ok(type(err) == "string", "error is string")
    end)

    T.it("returns nil,err for nil input", function()
        local b, err = M.parse_boundary(nil)
        T.eq(b, nil)
        T.ok(type(err) == "string", "error is string")
    end)
end)

-- ── Builder: new + content_type ───────────────────────────────────────────────

T.describe("new / content_type", function()
    T.it("uses provided boundary", function()
        local mp = M.new("testboundary")
        T.eq(mp:content_type(), "multipart/form-data; boundary=testboundary")
    end)

    T.it("generates boundary when nil", function()
        local mp = M.new()
        local ct = mp:content_type()
        T.ok(ct:find("multipart/form-data; boundary=", 1, true) ~= nil, "has prefix")
        local b = M.parse_boundary(ct)
        T.ok(type(b) == "string" and #b >= 1, "parseable boundary")
    end)

    T.it("body boundary matches content_type boundary", function()
        local mp = M.new()
        mp:field("x", "y")
        local body, bnd = mp:body()
        T.ok(body:find("--" .. bnd, 1, true) ~= nil, "boundary appears in body")
    end)
end)

-- ── Encoder: single field ─────────────────────────────────────────────────────

T.describe("encode single field", function()
    T.it("body contains boundary and field value", function()
        local mp = M.new("BOUND")
        mp:field("greeting", "hello")
        local body = mp:body()
        T.ok(body:find("--BOUND\r\n", 1, true) ~= nil, "opening boundary")
        T.ok(body:find("--BOUND--", 1, true) ~= nil, "closing boundary")
        T.ok(body:find("hello", 1, true) ~= nil, "field value present")
    end)

    T.it("Content-Disposition has field name", function()
        local mp = M.new("B")
        mp:field("myfield", "myvalue")
        local body = mp:body()
        T.ok(body:find('name="myfield"', 1, true) ~= nil, "name param present")
    end)

    T.it("body value is present verbatim", function()
        local mp = M.new("B")
        mp:field("k", "hello world\nline2")
        local body = mp:body()
        T.ok(body:find("hello world\nline2", 1, true) ~= nil, "multiline value preserved")
    end)
end)

-- ── Encoder: multiple fields ──────────────────────────────────────────────────

T.describe("encode multiple fields", function()
    T.it("all fields appear in body", function()
        local mp = M.new("BND")
        mp:field("a", "alpha")
        mp:field("b", "beta")
        mp:field("c", "gamma")
        local body = mp:body()
        T.ok(body:find("alpha", 1, true) ~= nil, "alpha")
        T.ok(body:find("beta", 1, true) ~= nil, "beta")
        T.ok(body:find("gamma", 1, true) ~= nil, "gamma")
    end)

    T.it("boundary appears between parts", function()
        local mp = M.new("SEP")
        mp:field("f1", "v1")
        mp:field("f2", "v2")
        local body = mp:body()
        -- Count boundary occurrences: 2 opening + 1 closing
        local count = 0
        local p = 1
        while true do
            local s = body:find("--SEP", p, true)
            if not s then break end
            count = count + 1
            p = s + 1
        end
        T.eq(count, 3)  -- --SEP (x2) + --SEP-- (x1)
    end)
end)

-- ── Encoder: file part ────────────────────────────────────────────────────────

T.describe("encode file part", function()
    T.it("Content-Disposition has filename", function()
        local mp = M.new("FB")
        mp:file("upload", "report.pdf", "PDF content", "application/pdf")
        local body = mp:body()
        T.ok(body:find('filename="report.pdf"', 1, true) ~= nil, "filename in disposition")
        T.ok(body:find('name="upload"', 1, true) ~= nil, "name in disposition")
    end)

    T.it("Content-Type header is set", function()
        local mp = M.new("FB")
        mp:file("img", "photo.jpg", "\xff\xd8\xff", "image/jpeg")
        local body = mp:body()
        T.ok(body:find("image/jpeg", 1, true) ~= nil, "content-type present")
    end)

    T.it("file content is present", function()
        local mp = M.new("FB")
        mp:file("doc", "hello.txt", "file body here", "text/plain")
        local body = mp:body()
        T.ok(body:find("file body here", 1, true) ~= nil, "file content present")
    end)

    T.it("default content-type is application/octet-stream", function()
        local mp = M.new("FB")
        mp:file("bin", "data.bin", "\x00\x01", nil)
        local body = mp:body()
        T.ok(body:find("application/octet-stream", 1, true) ~= nil, "default content-type")
    end)
end)

-- ── Encoder: custom part headers ─────────────────────────────────────────────

T.describe("encode custom part", function()
    T.it("custom headers appear in part", function()
        local mp = M.new("CB")
        mp:part({
            ["Content-Disposition"] = "form-data; name=\"raw\"",
            ["X-Custom"] = "my-value",
        }, "raw body")
        local body = mp:body()
        T.ok(body:find("X-Custom: my-value", 1, true) ~= nil, "custom header present")
        T.ok(body:find("raw body", 1, true) ~= nil, "body present")
    end)
end)

-- ── One-shot encode ───────────────────────────────────────────────────────────

T.describe("M.encode one-shot", function()
    T.it("encodes plain fields", function()
        local body, bnd = M.encode({
            { name = "username", value = "alice" },
            { name = "password", value = "secret" },
        }, "ONEBND")
        T.ok(body:find("alice", 1, true) ~= nil, "alice present")
        T.ok(body:find("secret", 1, true) ~= nil, "secret present")
        T.eq(bnd, "ONEBND")
    end)

    T.it("encodes file parts", function()
        local body = M.encode({
            { name = "file", filename = "test.txt", data = "file data", type = "text/plain" },
        }, "FILEBND")
        T.ok(body:find('filename="test.txt"', 1, true) ~= nil, "filename present")
        T.ok(body:find("file data", 1, true) ~= nil, "data present")
    end)

    T.it("generates boundary if not provided", function()
        local body, bnd = M.encode({ { name = "x", value = "1" } })
        T.ok(type(bnd) == "string" and #bnd >= 1, "boundary generated")
        T.ok(body:find("--" .. bnd, 1, true) ~= nil, "boundary in body")
    end)

    T.it("encodes raw parts", function()
        local body = M.encode({
            { headers = { ["Content-Disposition"] = 'form-data; name="f"' }, body = "rawval" },
        }, "RB")
        T.ok(body:find("rawval", 1, true) ~= nil, "raw body present")
    end)
end)

-- ── Decode ────────────────────────────────────────────────────────────────────

T.describe("M.decode", function()
    T.it("returns nil,err when no boundary provided", function()
        local parts, err = M.decode("body", nil)
        T.eq(parts, nil)
        T.ok(type(err) == "string", "error is string")
    end)

    T.it("returns nil,err when boundary not found in body", function()
        local parts, err = M.decode("no boundaries here", "MISSING")
        T.eq(parts, nil)
        T.ok(type(err) == "string", "error is string")
    end)

    T.it("decodes single field", function()
        local body = "--B\r\nContent-Disposition: form-data; name=\"field1\"\r\n\r\nvalue1\r\n--B--\r\n"
        local parts, err = M.decode(body, "B")
        T.eq(err, nil)
        T.eq(#parts, 1)
        T.eq(parts[1].body, "value1")
        T.eq(parts[1].name, "field1")
    end)

    T.it("decodes multiple fields", function()
        local body = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nalpha\r\n--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nbeta\r\n--B--\r\n"
        local parts = M.decode(body, "B")
        T.eq(#parts, 2)
        T.eq(parts[1].name, "a")
        T.eq(parts[1].body, "alpha")
        T.eq(parts[2].name, "b")
        T.eq(parts[2].body, "beta")
    end)

    T.it("preserves headers in decoded parts", function()
        local body = "--B\r\nContent-Disposition: form-data; name=\"f\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--B--\r\n"
        local parts = M.decode(body, "B")
        T.eq(#parts, 1)
        T.ok(parts[1].headers["content-type"] ~= nil, "content-type header present")
        T.ok(parts[1].headers["content-type"]:find("text/plain", 1, true) ~= nil, "content-type value")
    end)

    T.it("decodes file part with filename", function()
        local body = "--B\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"test.txt\"\r\nContent-Type: text/plain\r\n\r\nfile content\r\n--B--\r\n"
        local parts = M.decode(body, "B")
        T.eq(#parts, 1)
        T.eq(parts[1].name, "upload")
        T.eq(parts[1].filename, "test.txt")
        T.eq(parts[1].body, "file content")
    end)

    T.it("handles LF-only line endings", function()
        local body = "--B\nContent-Disposition: form-data; name=\"lf\"\n\nlfvalue\n--B--\n"
        local parts = M.decode(body, "B")
        T.eq(#parts, 1)
        T.eq(parts[1].name, "lf")
        T.ok(parts[1].body:find("lfvalue", 1, true) ~= nil, "lf body")
    end)

    T.it("returns empty array for body with only closing boundary", function()
        local body = "--B--\r\n"
        local parts = M.decode(body, "B")
        T.eq(#parts, 0)
    end)
end)

-- ── Round-trip ────────────────────────────────────────────────────────────────

T.describe("round-trip", function()
    T.it("single field survives encode+decode", function()
        local mp = M.new("RT")
        mp:field("name", "Alice")
        local body = mp:body()
        local parts = M.decode(body, "RT")
        T.eq(#parts, 1)
        T.eq(parts[1].name, "name")
        T.eq(parts[1].body, "Alice")
    end)

    T.it("multiple fields survive encode+decode", function()
        local mp = M.new("RT2")
        mp:field("first", "foo")
        mp:field("second", "bar")
        mp:field("third", "baz")
        local body = mp:body()
        local parts = M.decode(body, "RT2")
        T.eq(#parts, 3)
        T.eq(parts[1].body, "foo")
        T.eq(parts[2].body, "bar")
        T.eq(parts[3].body, "baz")
    end)

    T.it("file part survives encode+decode", function()
        local mp = M.new("RTF")
        mp:file("doc", "readme.txt", "readme content", "text/plain")
        local body = mp:body()
        local parts = M.decode(body, "RTF")
        T.eq(#parts, 1)
        T.eq(parts[1].filename, "readme.txt")
        T.eq(parts[1].body, "readme content")
    end)

    T.it("mixed fields and files survive encode+decode", function()
        local mp = M.new("MX")
        mp:field("title", "My Upload")
        mp:file("attachment", "data.bin", "\x00\x01\x02\x03", "application/octet-stream")
        mp:field("description", "some description")
        local body = mp:body()
        local parts = M.decode(body, "MX")
        T.eq(#parts, 3)
        T.eq(parts[1].body, "My Upload")
        T.eq(parts[2].filename, "data.bin")
        T.eq(parts[2].body, "\x00\x01\x02\x03")
        T.eq(parts[3].body, "some description")
    end)

    T.it("one-shot encode then decode preserves fields", function()
        local body, bnd = M.encode({
            { name = "user", value = "bob" },
            { name = "pass", value = "s3cr3t" },
        })
        local parts = M.decode(body, bnd)
        T.eq(#parts, 2)
        T.eq(parts[1].name, "user")
        T.eq(parts[1].body, "bob")
        T.eq(parts[2].name, "pass")
        T.eq(parts[2].body, "s3cr3t")
    end)

    T.it("empty field value round-trips", function()
        local mp = M.new("EMPTY")
        mp:field("blank", "")
        local body = mp:body()
        local parts = M.decode(body, "EMPTY")
        T.eq(#parts, 1)
        T.eq(parts[1].body, "")
    end)

    T.it("value with special chars round-trips", function()
        local val = "line1\r\nline2\ttabbed"
        local mp = M.new("SPEC")
        mp:field("data", val)
        local body = mp:body()
        local parts = M.decode(body, "SPEC")
        T.eq(#parts, 1)
        T.eq(parts[1].body, val)
    end)
end)
