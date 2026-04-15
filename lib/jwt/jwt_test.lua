-- lib/jwt/jwt_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end
local T   = require("lib.test.assert")
local jwt = require("lib.jwt")

T.describe("lib.jwt", function()

  T.it("_tier is 'pure'", function()
    T.eq(jwt._tier, "pure")
  end)

  T.it("encode returns a three-part dot-separated string", function()
    local token, err = jwt.encode({ sub = "user1" }, "secret")
    T.ok(token)
    T.eq(err, nil)
    -- count dots
    local dots = 0
    for _ in token:gmatch("%.") do dots = dots + 1 end
    T.eq(dots, 2)
  end)

  T.it("decode verifies a freshly-encoded token", function()
    local token = assert(jwt.encode({ sub = "user1", role = "admin" }, "mysecret"))
    local payload, header = jwt.decode(token, "mysecret", { time_fn = os.time })
    T.ok(payload)
    T.ok(header)
    T.eq(payload.sub, "user1")
    T.eq(payload.role, "admin")
    T.eq(header.alg, "HS256")
    T.eq(header.typ, "JWT")
  end)

  T.it("round-trip: encode then decode preserves all claims", function()
    local claims = { sub = "42", name = "Alice", iat = 1000000, admin = true }
    local token = assert(jwt.encode(claims, "key"))
    local payload = assert(jwt.decode(token, "key", { time_fn = os.time }))
    T.eq(payload.sub, "42")
    T.eq(payload.name, "Alice")
    T.eq(payload.iat, 1000000)
    T.eq(payload.admin, true)
  end)

  T.it("exp in the past → token expired error", function()
    local token = assert(jwt.encode({ sub = "x", exp = os.time() - 60 }, "k"))
    local payload, err = jwt.decode(token, "k", { time_fn = os.time })
    T.eq(payload, nil)
    T.ok(err and err:find("expired"))
  end)

  T.it("exp in the future → accepted", function()
    local token = assert(jwt.encode({ sub = "x", exp = os.time() + 3600 }, "k"))
    local payload, header = jwt.decode(token, "k", { time_fn = os.time })
    T.ok(payload)
    T.ok(header)
  end)

  T.it("nbf in the future → token not yet valid", function()
    local token = assert(jwt.encode({ sub = "x", nbf = os.time() + 300 }, "k"))
    local payload, err = jwt.decode(token, "k", { time_fn = os.time })
    T.eq(payload, nil)
    T.ok(err and err:find("not yet valid"))
  end)

  T.it("nbf in the past → accepted", function()
    local token = assert(jwt.encode({ sub = "x", nbf = os.time() - 60 }, "k"))
    local payload, header = jwt.decode(token, "k", { time_fn = os.time })
    T.ok(payload)
    T.ok(header)
  end)

  T.it("decode_unverified works without a secret", function()
    local token = assert(jwt.encode({ sub = "anon", data = 99 }, "anykey"))
    local payload, header = jwt.decode_unverified(token)
    T.ok(payload)
    T.ok(header)
    T.eq(payload.sub, "anon")
    T.eq(payload.data, 99)
    T.eq(header.alg, "HS256")
  end)

  T.it("wrong secret → signature verification failed", function()
    local token = assert(jwt.encode({ sub = "u" }, "correct-secret"))
    local payload, err = jwt.decode(token, "wrong-secret", { time_fn = os.time })
    T.eq(payload, nil)
    T.ok(err and err:find("signature"))
  end)

  T.it("malformed token (fewer than 3 parts) → error", function()
    local payload, err = jwt.decode("onlyone", "k", { time_fn = os.time })
    T.eq(payload, nil)
    T.ok(err and err:find("malformed"))
  end)

  T.it("malformed token (more than 3 parts) → error", function()
    local payload, err = jwt.decode("a.b.c.d", "k", { time_fn = os.time })
    T.eq(payload, nil)
    T.ok(err and err:find("malformed"))
  end)

  T.it("encode with alg 'none' → error", function()
    local token, err = jwt.encode({ sub = "x" }, "", { alg = "none" })
    T.eq(token, nil)
    T.ok(err and err:find("none"))
  end)

  T.it("decode_unverified works on a token with alg 'none' in header", function()
    -- Build a token manually with alg=none (no signature)
    local base64 = require("lib.base64")
    local json   = require("lib.json")
    local header_b64  = base64.encode('{"alg":"none","typ":"JWT"}', { url = true, pad = false })
    local payload_b64 = base64.encode('{"sub":"nobody"}', { url = true, pad = false })
    local none_token  = header_b64 .. "." .. payload_b64 .. "."
    local payload, header = jwt.decode_unverified(none_token)
    T.ok(payload)
    T.eq(payload.sub, "nobody")
    T.eq(header.alg, "none")
  end)

  T.it("decode with verify=true rejects alg 'none' token", function()
    local base64 = require("lib.base64")
    local header_b64  = base64.encode('{"alg":"none","typ":"JWT"}', { url = true, pad = false })
    local payload_b64 = base64.encode('{"sub":"nobody"}', { url = true, pad = false })
    local none_token  = header_b64 .. "." .. payload_b64 .. "."
    local payload, err = jwt.decode(none_token, "secret", { time_fn = os.time })
    T.eq(payload, nil)
    T.ok(err and err:find("none"))
  end)

  -- Known test vector from jwt.io
  -- Header:  {"alg":"HS256","typ":"JWT"}
  -- Payload: {"sub":"1234567890","name":"John Doe","iat":1516239022}
  -- Secret:  "your-256-bit-secret"
  T.it("known test vector from jwt.io verifies correctly", function()
    local token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
      .. ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
      .. ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    -- decode without verify (token has exp in past conceptually — no exp claim)
    local payload, header = jwt.decode(token, "your-256-bit-secret", { verify = true, time_fn = os.time })
    T.ok(payload)
    T.eq(header.alg, "HS256")
    T.eq(payload.sub, "1234567890")
    T.eq(payload.name, "John Doe")
    T.eq(payload.iat, 1516239022)
  end)

  T.it("encode round-trips the same claims used in the known vector", function()
    -- Encodes then decodes; verification proves HMAC signing works correctly.
    local claims = { sub = "1234567890", name = "John Doe", iat = 1516239022 }
    local token, err = jwt.encode(claims, "your-256-bit-secret")
    T.ok(token)
    T.eq(err, nil)
    local payload, header = jwt.decode(token, "your-256-bit-secret", { time_fn = os.time })
    T.ok(payload)
    T.eq(payload.sub, "1234567890")
    T.eq(payload.name, "John Doe")
    T.eq(payload.iat, 1516239022)
    T.eq(header.alg, "HS256")
  end)

  T.it("HS384 → unsupported error on encode", function()
    local token, err = jwt.encode({ sub = "x" }, "k", { alg = "HS384" })
    T.eq(token, nil)
    T.ok(err and err:find("HS384"))
  end)

  T.it("HS512 → unsupported error on encode", function()
    local token, err = jwt.encode({ sub = "x" }, "k", { alg = "HS512" })
    T.eq(token, nil)
    T.ok(err and err:find("HS512"))
  end)

  T.it("now() returns a number close to os.time()", function()
    local t = jwt.now(os.time)
    T.ok(type(t) == "number")
    T.ok(math.abs(t - os.time()) <= 1)
  end)

  T.it("exp_in(n) returns os.time() + n", function()
    local t = jwt.exp_in(os.time, 3600)
    T.ok(math.abs(t - (os.time() + 3600)) <= 1)
  end)

end)
