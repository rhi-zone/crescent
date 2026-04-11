-- lib/pem/pem_test.lua
-- Tests for lib/pem

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pem = require("lib.pem")

-- Test data: short self-signed cert (DER may not be valid, that's fine)
local CERT_PEM = [[-----BEGIN CERTIFICATE-----
MIIBpTCCAQ6gAwIBAgIBADANBgkqhkiG9w0BAQsFADAOMQwwCgYDVQQDDANmb28w
HhcNMjMwMTAxMDAwMDAwWhcNMjQwMTAxMDAwMDAwWjAOMQwwCgYDVQQDDANmb28w
gZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBAKt7KBLlNtKnP3HJUcKPtSVK3TZs
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AgMBAAGjEzARMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADgYEAAQID
BAUG
-----END CERTIFICATE-----
]]

-- RSA key (only needs to parse the label)
local RSA_PEM = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA2a2rwplBQLHQMzDGNT\n-----END RSA PRIVATE KEY-----\n"

-- Two blocks concatenated
local TWO_BLOCKS = CERT_PEM .. "\n" .. RSA_PEM

T.describe("lib.pem", function()

  T.describe("tier", function()
    T.it("is pure", function()
      T.eq(pem._tier, "pure")
    end)
  end)

  T.describe("decode", function()
    T.it("returns label CERTIFICATE", function()
      local result, err = pem.decode(CERT_PEM)
      T.ok(result ~= nil)
      T.eq(err, nil)
      T.eq(result.label, "CERTIFICATE")
    end)

    T.it("returns binary data string", function()
      local result = pem.decode(CERT_PEM)
      T.ok(result ~= nil)
      T.ok(type(result.data) == "string")
      T.ok(#result.data > 0)
    end)

    T.it("round-trips: encode then decode gives same label and data", function()
      local result = pem.decode(CERT_PEM)
      T.ok(result ~= nil)
      local repem = pem.encode(result.label, result.data)
      T.ok(repem ~= nil)
      local result2 = pem.decode(repem)
      T.ok(result2 ~= nil)
      T.eq(result2.label, result.label)
      T.eq(result2.data, result.data)
    end)

    T.it("CRLF line endings work", function()
      local crlf = CERT_PEM:gsub("\n", "\r\n")
      local result, err = pem.decode(crlf)
      T.ok(result ~= nil)
      T.eq(err, nil)
      T.eq(result.label, "CERTIFICATE")
    end)

    T.it("extra blank lines between header and body are ignored", function()
      local with_blanks = "-----BEGIN CERTIFICATE-----\n\n\nMIIBpTCCAQ6gAwIBAgIBADANBgkqhkiG9w0BAQsFADAOMQwwCgYDVQQDDANmb28w\n\n-----END CERTIFICATE-----\n"
      local result, err = pem.decode(with_blanks)
      T.ok(result ~= nil)
      T.eq(err, nil)
      T.eq(result.label, "CERTIFICATE")
    end)

    T.it("mismatched header/footer returns error", function()
      local bad = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END PRIVATE KEY-----\n"
      local result, err = pem.decode(bad)
      T.eq(result, nil)
      T.ok(err ~= nil)
      T.ok(err:find("mismatched") ~= nil)
    end)

    T.it("no PEM block found returns error", function()
      local result, err = pem.decode("this is not pem at all\n")
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("truncated block (no footer) returns error", function()
      local truncated = "-----BEGIN CERTIFICATE-----\nMIIBpTCCAQ6g\n"
      local result, err = pem.decode(truncated)
      T.eq(result, nil)
      T.ok(err ~= nil)
      T.ok(err:find("truncated") ~= nil)
    end)

    T.it("parses RSA PRIVATE KEY label", function()
      local result, err = pem.decode(RSA_PEM)
      T.ok(result ~= nil)
      T.eq(err, nil)
      T.eq(result.label, "RSA PRIVATE KEY")
    end)
  end)

  T.describe("encode", function()
    T.it("output starts with -----BEGIN LABEL-----", function()
      local out = pem.encode("CERTIFICATE", "hello")
      T.ok(out ~= nil)
      T.ok(out:sub(1, 27) == "-----BEGIN CERTIFICATE-----")
    end)

    T.it("output ends with -----END LABEL-----\\n", function()
      local out = pem.encode("CERTIFICATE", "hello")
      T.ok(out ~= nil)
      local expected = "-----END CERTIFICATE-----\n"
      T.ok(out:sub(-#expected) == expected)
    end)

    T.it("body lines are at most 64 chars", function()
      -- Use a large input to force multiple lines
      local data = string.rep("\xAB\xCD\xEF", 100)
      local out = pem.encode("CERTIFICATE", data)
      T.ok(out ~= nil)
      for line in out:gmatch("[^\n]+") do
        -- Skip header/footer lines (they start with -----)
        if not line:find("^%-%-%-%-%-") then
          T.ok(#line <= 64)
        end
      end
    end)

    T.it("custom line_length is respected", function()
      local data = string.rep("\xAB\xCD\xEF", 50)
      local out = pem.encode("CERTIFICATE", data, { line_length = 76 })
      T.ok(out ~= nil)
      for line in out:gmatch("[^\n]+") do
        if not line:find("^%-%-%-%-%-") then
          T.ok(#line <= 76)
        end
      end
    end)

    T.it("encode then decode round-trip", function()
      local original = "binary\x00data\xff\xfe\x01\x02\x03"
      local encoded = pem.encode("PRIVATE KEY", original)
      T.ok(encoded ~= nil)
      local decoded = pem.decode(encoded)
      T.ok(decoded ~= nil)
      T.eq(decoded.label, "PRIVATE KEY")
      T.eq(decoded.data, original)
    end)

    T.it("invalid label returns error", function()
      local out, err = pem.encode("invalid label!", "data")
      T.eq(out, nil)
      T.ok(err ~= nil)
    end)

    T.it("empty data encodes and decodes cleanly", function()
      local encoded = pem.encode("CERTIFICATE", "")
      T.ok(encoded ~= nil)
      local decoded = pem.decode(encoded)
      T.ok(decoded ~= nil)
      T.eq(decoded.data, "")
    end)
  end)

  T.describe("decode_all", function()
    T.it("single block returns 1-element array", function()
      local results, err = pem.decode_all(CERT_PEM)
      T.ok(results ~= nil)
      T.eq(err, nil)
      T.eq(#results, 1)
      T.eq(results[1].label, "CERTIFICATE")
    end)

    T.it("two blocks in sequence are both parsed", function()
      local results, err = pem.decode_all(TWO_BLOCKS)
      T.ok(results ~= nil)
      T.eq(err, nil)
      T.eq(#results, 2)
      T.eq(results[1].label, "CERTIFICATE")
      T.eq(results[2].label, "RSA PRIVATE KEY")
    end)

    T.it("mixed text between blocks is ignored", function()
      local mixed = "some text before\n" .. CERT_PEM .. "\nsome text between\n" .. RSA_PEM .. "\nsome text after\n"
      local results, err = pem.decode_all(mixed)
      T.ok(results ~= nil)
      T.eq(err, nil)
      T.eq(#results, 2)
      T.eq(results[1].label, "CERTIFICATE")
      T.eq(results[2].label, "RSA PRIVATE KEY")
    end)

    T.it("empty string returns empty array", function()
      local results, err = pem.decode_all("")
      T.ok(results ~= nil)
      T.eq(err, nil)
      T.eq(#results, 0)
    end)

    T.it("plain text with no PEM returns empty array", function()
      local results, err = pem.decode_all("no pem here at all\nreally none\n")
      T.ok(results ~= nil)
      T.eq(err, nil)
      T.eq(#results, 0)
    end)
  end)

  T.describe("is_pem / label", function()
    T.it("is_pem returns true for a PEM string", function()
      T.ok(pem.is_pem(CERT_PEM) == true)
    end)

    T.it("is_pem returns false for non-PEM", function()
      T.ok(pem.is_pem("this is just text") == false)
    end)

    T.it("is_pem returns false for empty string", function()
      T.ok(pem.is_pem("") == false)
    end)

    T.it("label extracts CERTIFICATE correctly", function()
      local lbl, err = pem.label(CERT_PEM)
      T.eq(err, nil)
      T.eq(lbl, "CERTIFICATE")
    end)

    T.it("label extracts RSA PRIVATE KEY correctly", function()
      local lbl, err = pem.label(RSA_PEM)
      T.eq(err, nil)
      T.eq(lbl, "RSA PRIVATE KEY")
    end)

    T.it("label on non-PEM returns nil and errmsg", function()
      local lbl, err = pem.label("not pem")
      T.eq(lbl, nil)
      T.ok(err ~= nil)
    end)

    T.it("label skips non-PEM lines to find first BEGIN", function()
      local mixed = "some prefix text\n-----BEGIN PUBLIC KEY-----\ndata\n-----END PUBLIC KEY-----\n"
      local lbl, err = pem.label(mixed)
      T.eq(err, nil)
      T.eq(lbl, "PUBLIC KEY")
    end)
  end)

end)
