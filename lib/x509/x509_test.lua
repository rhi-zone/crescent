-- lib/x509/x509_test.lua
-- Tests for lib/x509 X.509 certificate parser.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local x509 = require("lib.x509")

-- ── Test certificate: Amazon Root CA 3 (self-signed, ECDSA, v3) ───────────────
-- Source: system ca-bundle. Small (655 bytes PEM), real, well-formed.
local CERT_PEM = [[-----BEGIN CERTIFICATE-----
MIIBtjCCAVugAwIBAgITBmyf1XSXNmY/Owua2eiedgPySjAKBggqhkjOPQQDAjA5
MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6b24g
Um9vdCBDQSAzMB4XDTE1MDUyNjAwMDAwMFoXDTQwMDUyNjAwMDAwMFowOTELMAkG
A1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJvb3Qg
Q0EgMzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABCmXp8ZBf8ANm+gBG1bG8lKl
ui2yEujSLtf6ycXYqm0fc4E7O5hrOXwzpcVOho6AF2hiRVd9RFgdszflZwjrZt6j
QjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMB0GA1UdDgQWBBSr
ttvXBp43rDCGB5Fwx5zEGbF4wDAKBggqhkjOPQQDAgNJADBGAiEA4IWSoxe3jfkr
BqWTrBqYaGFy+uGh0PsceGCmQ5nFuMQCIQCcAu/xlJyzlvnrxir4tiz+OpAUFteM
YyRIHN8wfdVoOw==
-----END CERTIFICATE-----]]

-- Second test cert: an RSA-based root CA (DigiCert Global Root CA, v3, RSA 2048)
-- Source: /etc/ssl/certs/ca-bundle.crt on NixOS.
local CERT_RSA_PEM = [[-----BEGIN CERTIFICATE-----
MIIDrzCCApegAwIBAgIQCDvgVpBCRrGhdWrJWZHHSjANBgkqhkiG9w0BAQUFADBh
MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
d3cuZGlnaWNlcnQuY29tMSAwHgYDVQQDExdEaWdpQ2VydCBHbG9iYWwgUm9vdCBD
QTAeFw0wNjExMTAwMDAwMDBaFw0zMTExMTAwMDAwMDBaMGExCzAJBgNVBAYTAlVT
MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
b20xIDAeBgNVBAMTF0RpZ2lDZXJ0IEdsb2JhbCBSb290IENBMIIBIjANBgkqhkiG
9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4jvhEXLeqKTTo1eqUKKPC3eQyaKl7hLOllsB
CSDMAZOnTjC3U/dDxGkAV53ijSLdhwZAAIEJzs4bg7/fzTtxRuLWZscFs3YnFo97
nh6Vfe63SKMI2tavegw5BmV/Sl0fvBf4q77uKNd0f3p4mVmFaG5cIzJLv07A6Fpt
43C/dxC//AH2hdmoRBBYMql1GNXRor5H4idq9Joz+EkIYIvUX7Q6hL+hqkpMfT7P
T19sdl6gSzeRntwi5m3OFBqOasv+zbMUZBfHWymeMr/y7vrTC0LUq7dBMtoM1O/4
gdW7jVg/tRvoSSiicNoxBN33shbyTApOB6jtSj1etX+jkMOvJwIDAQABo2MwYTAO
BgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUA95QNVbR
TLtm8KPiGxvDl7I90VUwHwYDVR0jBBgwFoAUA95QNVbRTLtm8KPiGxvDl7I90VUw
DQYJKoZIhvcNAQEFBQADggEBAMucN6pIExIK+t1EnE9SsPTfrgT1eXkIoyQY/Esr
hMAtudXH/vTBH1jLuG2cenTnmCmrEbXjcKChzUyImZOMkXDiqw8cvpOp/2PV5Adg
06O/nVsJ8dWO41P0jmP6P6fbtGbfYmbW0W5BjfIttep3Sp+dWOIrWcBAI+0tKIJF
PnlUkiaY4IBIqDfv8NZ5YBberOgOzW6sRBc4L0na4UU+Krk2U886UAb3LujEV0ls
YSEY1QSteDwsOoBrp+uvFRTp2InBuThs4pFsiv9kuXclVzDAGySj4dzp30d8tbQk
CAUw7C29C79Fv1C5qfPrmAESrciIxpg0X40KPMbp1ZWVbd4=
-----END CERTIFICATE-----]]

-- Helper: decode the PEM cert to DER bytes for parse_der tests
local function pem_to_der(p)
  local pem_mod = require("lib.pem")
  local block, err = pem_mod.decode(p)
  if not block then error("test setup: pem decode failed: " .. tostring(err)) end
  return block.data
end

local CERT_DER     = pem_to_der(CERT_PEM)
local CERT_RSA_DER = pem_to_der(CERT_RSA_PEM)

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("lib.x509", function()

  T.describe("tier", function()
    T.it("M._tier is 'pure'", function()
      T.eq(x509._tier, "pure")
    end)
  end)

  -- ── parse_der: basic field extraction ──────────────────────────────────────

  T.describe("parse_der", function()

    T.it("returns nil+errmsg on empty input", function()
      local cert, err = x509.parse_der("")
      T.eq(cert, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil+errmsg on non-string input", function()
      local cert, err = x509.parse_der(42)
      T.eq(cert, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil+errmsg on garbage bytes", function()
      local cert, err = x509.parse_der("\x00\x01\x02\x03garbage")
      T.eq(cert, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil+errmsg on truncated DER", function()
      -- A valid SEQUENCE tag+length but value cut off
      local cert, err = x509.parse_der("\x30\x82\x04\x00\x01\x02")
      T.eq(cert, nil)
      T.ok(type(err) == "string")
    end)

    T.it("parses version 3 (ECDSA cert)", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.version, 3)
    end)

    T.it("parses serial number as hex string", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.ok(type(cert.serial) == "string")
      T.ok(#cert.serial > 0)
      -- hex chars only
      T.ok(cert.serial:match("^[0-9a-f]+$") ~= nil)
    end)

    T.it("parses subject CN (Amazon Root CA 3)", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.subject.CN, "Amazon Root CA 3")
    end)

    T.it("parses subject O (Amazon)", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.subject.O, "Amazon")
    end)

    T.it("parses subject C (US)", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.subject.C, "US")
    end)

    T.it("parses issuer (self-signed: issuer == subject)", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.issuer.CN, "Amazon Root CA 3")
      T.eq(cert.issuer.O, "Amazon")
    end)

    T.it("parses not_before as ISO 8601", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.not_before, "2015-05-26T00:00:00Z")
    end)

    T.it("parses not_after as ISO 8601", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.not_after, "2040-05-26T00:00:00Z")
    end)

    T.it("parses sig_algorithm as OID string", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.sig_algorithm, "1.2.840.10045.4.3.2")
    end)

    T.it("parses sig_algorithm_name (ecdsaWithSHA256)", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.sig_algorithm_name, "ecdsaWithSHA256")
    end)

    T.it("parses public_key algorithm OID", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.public_key.algorithm, "1.2.840.10045.2.1")
    end)

    T.it("parses public_key algorithm_name (ecPublicKey)", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.public_key.algorithm_name, "ecPublicKey")
    end)

    T.it("parses public_key key_data as non-empty binary", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.ok(type(cert.public_key.key_data) == "string")
      T.ok(#cert.public_key.key_data > 0)
    end)

    T.it("stores raw DER bytes", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.eq(cert.raw, CERT_DER)
    end)

    T.it("parses extensions table", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.ok(cert.extensions ~= nil)
      T.ok(type(cert.extensions) == "table")
    end)

    T.it("basicConstraints extension is present and critical", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      T.ok(cert.extensions ~= nil)
      local bc = cert.extensions["2.5.29.19"]
      T.ok(bc ~= nil)
      T.eq(bc.critical, true)
    end)

    -- RSA cert tests
    T.it("parses RSA cert version 3", function()
      local cert, err = x509.parse_der(CERT_RSA_DER)
      T.ok(cert, err)
      T.eq(cert.version, 3)
    end)

    T.it("parses RSA cert subject CN", function()
      local cert, err = x509.parse_der(CERT_RSA_DER)
      T.ok(cert, err)
      T.eq(cert.subject.CN, "DigiCert Global Root CA")
    end)

    T.it("parses RSA cert subject OU", function()
      local cert, err = x509.parse_der(CERT_RSA_DER)
      T.ok(cert, err)
      T.eq(cert.subject.OU, "www.digicert.com")
    end)

    T.it("parses RSA cert sig_algorithm_name (sha1WithRSAEncryption)", function()
      local cert, err = x509.parse_der(CERT_RSA_DER)
      T.ok(cert, err)
      T.eq(cert.sig_algorithm_name, "sha1WithRSAEncryption")
    end)

    T.it("parses RSA cert public_key algorithm (rsaEncryption)", function()
      local cert, err = x509.parse_der(CERT_RSA_DER)
      T.ok(cert, err)
      T.eq(cert.public_key.algorithm, "1.2.840.113549.1.1.1")
      T.eq(cert.public_key.algorithm_name, "rsaEncryption")
    end)

    T.it("RSA public key data is 256+ bytes (RSA-2048)", function()
      local cert, err = x509.parse_der(CERT_RSA_DER)
      T.ok(cert, err)
      -- RSA-2048 public key is 270 bytes (with DER SEQUENCE wrapping inside BIT STRING)
      T.ok(#cert.public_key.key_data >= 256)
    end)

    T.it("RSA cert not_before parses correctly", function()
      local cert, err = x509.parse_der(CERT_RSA_DER)
      T.ok(cert, err)
      T.eq(cert.not_before, "2006-11-10T00:00:00Z")
    end)

    T.it("RSA cert not_after parses correctly", function()
      local cert, err = x509.parse_der(CERT_RSA_DER)
      T.ok(cert, err)
      T.eq(cert.not_after, "2031-11-10T00:00:00Z")
    end)

  end)

  -- ── parse_pem ───────────────────────────────────────────────────────────────

  T.describe("parse_pem", function()

    T.it("returns nil+errmsg on empty input", function()
      local cert, err = x509.parse_pem("")
      T.eq(cert, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil+errmsg on non-string input", function()
      local cert, err = x509.parse_pem(nil)
      T.eq(cert, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil+errmsg on wrong PEM label", function()
      local bad_pem = CERT_PEM:gsub("CERTIFICATE", "PRIVATE KEY")
      local cert, err = x509.parse_pem(bad_pem)
      T.eq(cert, nil)
      T.ok(type(err) == "string")
      T.ok(err:find("CERTIFICATE") ~= nil or err:find("label") ~= nil or err:find("PRIVATE") ~= nil)
    end)

    T.it("returns nil+errmsg on malformed PEM (no begin header)", function()
      local cert, err = x509.parse_pem("not pem at all")
      T.eq(cert, nil)
      T.ok(type(err) == "string")
    end)

    T.it("parses PEM cert (ECDSA): version 3", function()
      local cert, err = x509.parse_pem(CERT_PEM)
      T.ok(cert, err)
      T.eq(cert.version, 3)
    end)

    T.it("parses PEM cert: same result as parse_der", function()
      local from_pem, err1 = x509.parse_pem(CERT_PEM)
      local from_der, err2 = x509.parse_der(CERT_DER)
      T.ok(from_pem, err1)
      T.ok(from_der, err2)
      T.eq(from_pem.version,            from_der.version)
      T.eq(from_pem.serial,             from_der.serial)
      T.eq(from_pem.subject.CN,         from_der.subject.CN)
      T.eq(from_pem.not_before,         from_der.not_before)
      T.eq(from_pem.sig_algorithm,      from_der.sig_algorithm)
      T.eq(from_pem.sig_algorithm_name, from_der.sig_algorithm_name)
    end)

    T.it("parses RSA PEM cert", function()
      local cert, err = x509.parse_pem(CERT_RSA_PEM)
      T.ok(cert, err)
      T.eq(cert.subject.CN, "DigiCert Global Root CA")
      T.eq(cert.sig_algorithm_name, "sha1WithRSAEncryption")
    end)

  end)

  -- ── fingerprint ─────────────────────────────────────────────────────────────

  T.describe("fingerprint", function()

    T.it("fingerprint_sha256 is a string when sha256 is available", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      -- sha256 is available in this project (lib/hash/sha256)
      T.ok(cert.fingerprint_sha256 ~= nil)
      T.ok(type(cert.fingerprint_sha256) == "string")
    end)

    T.it("fingerprint_sha256 has colon-separated hex format", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      if cert.fingerprint_sha256 then
        -- Should be 32 hex bytes with colons: "xx:xx:...:xx" (95 chars total)
        -- Lua patterns don't support group repetition; check all chars are hex or colon
        local fp = cert.fingerprint_sha256
        T.ok(fp:match("^[0-9a-f:]+$") ~= nil)
        -- Also check it starts and ends with hex (not colon)
        T.ok(fp:match("^[0-9a-f][0-9a-f]") ~= nil)
        T.ok(fp:match("[0-9a-f][0-9a-f]$") ~= nil)
      end
    end)

    T.it("fingerprint_sha256 is 95 chars (32 bytes with colons)", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      if cert.fingerprint_sha256 then
        T.eq(#cert.fingerprint_sha256, 95)
      end
    end)

    T.it("fingerprint_sha256 is deterministic", function()
      local cert1 = x509.parse_der(CERT_DER)
      local cert2 = x509.parse_der(CERT_DER)
      T.ok(cert1 ~= nil)
      T.ok(cert2 ~= nil)
      T.eq(cert1.fingerprint_sha256, cert2.fingerprint_sha256)
    end)

    T.it("fingerprint_sha256 known value for Amazon Root CA 3", function()
      local cert, err = x509.parse_der(CERT_DER)
      T.ok(cert, err)
      if cert.fingerprint_sha256 then
        -- Pre-computed expected value (verified by running x509.parse_der on the cert)
        -- Amazon Root CA 3 SHA-256 fingerprint
        T.eq(cert.fingerprint_sha256,
          "18:ce:6c:fe:7b:f1:4e:60:b2:e3:47:b8:df:e8:68:cb:31:d0:2e:bb:3a:da:27:15:69:f5:03:43:b4:6d:b3:a4")
      end
    end)

  end)

end)
