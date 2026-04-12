-- lib/oauth/oauth_test.lua
-- Tests for the OAuth 2.0 helper library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local oauth = require("lib.oauth")

-- ── base64url ────────────────────────────────────────────────────────────────

T.describe("base64url", function()
  T.it("encodes empty string", function()
    T.eq(oauth.base64url_encode(""), "")
  end)

  T.it("encodes known vectors", function()
    -- RFC 4648 §10 test vectors (standard base64), adapted for url-safe no-padding
    -- "f"       -> "Zg"
    -- "fo"      -> "Zm8"
    -- "foo"     -> "Zm9v"
    -- "foobar"  -> "Zm9vYmFy"
    T.eq(oauth.base64url_encode("f"),      "Zg")
    T.eq(oauth.base64url_encode("fo"),     "Zm8")
    T.eq(oauth.base64url_encode("foo"),    "Zm9v")
    T.eq(oauth.base64url_encode("foobar"), "Zm9vYmFy")
  end)

  T.it("encodes bytes that would produce + and / in standard base64 as - and _", function()
    -- byte 0xFB = 251, 0xFF = 255 -> standard b64 "+/" -> url-safe "-_"
    local raw = string.char(0xFB, 0xFF)
    local enc = oauth.base64url_encode(raw)
    T.ok(not enc:find("+"), "no + in url-safe output")
    T.ok(not enc:find("/"), "no / in url-safe output")
    T.ok(not enc:find("="), "no padding")
  end)

  T.it("decodes back to original (round-trip)", function()
    local inputs = { "", "f", "fo", "foo", "foob", "foobar", "hello world" }
    for _, s in ipairs(inputs) do
      local enc = oauth.base64url_encode(s)
      local dec = oauth.base64url_decode(enc)
      T.eq(dec, s, "round-trip for: " .. s)
    end
  end)

  T.it("decodes with padding stripped", function()
    -- Add padding manually; decoder should strip it
    local enc = oauth.base64url_encode("foo") .. "=="
    T.eq(oauth.base64url_decode(enc), "foo")
  end)

  T.it("returns nil for invalid base64url input", function()
    T.eq(oauth.base64url_decode("!@#$"), nil)
  end)
end)

-- ── url_encode / url_decode ───────────────────────────────────────────────────

T.describe("url_encode / url_decode", function()
  T.it("leaves unreserved chars unchanged", function()
    T.eq(oauth.url_encode("ABCabc012-_.~"), "ABCabc012-_.~")
  end)

  T.it("percent-encodes reserved and special chars", function()
    T.eq(oauth.url_encode(" "),  "%20")
    T.eq(oauth.url_encode("&"),  "%26")
    T.eq(oauth.url_encode("="),  "%3D")
    T.eq(oauth.url_encode("/"),  "%2F")
    T.eq(oauth.url_encode("+"),  "%2B")
    T.eq(oauth.url_encode("@"),  "%40")
  end)

  T.it("round-trips arbitrary strings", function()
    local inputs = {
      "hello world",
      "foo=bar&baz=qux",
      "https://example.com/cb?code=abc&state=xyz",
      "üñícode",
    }
    for _, s in ipairs(inputs) do
      T.eq(oauth.url_decode(oauth.url_encode(s)), s, "round-trip: " .. s)
    end
  end)

  T.it("url_decode handles + as space", function()
    T.eq(oauth.url_decode("hello+world"), "hello world")
  end)
end)

-- ── build_query / parse_query ─────────────────────────────────────────────────

T.describe("build_query", function()
  T.it("produces sorted keys", function()
    local qs = oauth.build_query({ b = "2", a = "1", c = "3" })
    T.eq(qs, "a=1&b=2&c=3")
  end)

  T.it("encodes values", function()
    local qs = oauth.build_query({ redirect_uri = "https://example.com/cb" })
    T.eq(qs, "redirect_uri=https%3A%2F%2Fexample.com%2Fcb")
  end)

  T.it("skips nil values", function()
    local qs = oauth.build_query({ a = "1", b = nil, c = "3" })
    T.ok(not qs:find("b"), "nil key not in output")
    T.eq(qs, "a=1&c=3")
  end)

  T.it("returns empty string for empty table", function()
    T.eq(oauth.build_query({}), "")
  end)
end)

T.describe("parse_query", function()
  T.it("parses key=value pairs", function()
    local t = oauth.parse_query("a=1&b=2&c=3")
    T.eq(t.a, "1")
    T.eq(t.b, "2")
    T.eq(t.c, "3")
  end)

  T.it("decodes percent-encoded values", function()
    local t = oauth.parse_query("redirect_uri=https%3A%2F%2Fexample.com%2Fcb")
    T.eq(t.redirect_uri, "https://example.com/cb")
  end)

  T.it("returns empty table for empty string", function()
    local t = oauth.parse_query("")
    T.eq(type(t), "table")
    T.eq(next(t), nil)
  end)

  T.it("round-trips with build_query", function()
    local params = { client_id = "myapp", scope = "openid profile", state = "random123" }
    local qs = oauth.build_query(params)
    local parsed = oauth.parse_query(qs)
    T.eq(parsed.client_id, params.client_id)
    T.eq(parsed.scope,     params.scope)
    T.eq(parsed.state,     params.state)
  end)
end)

-- ── random_state ──────────────────────────────────────────────────────────────

T.describe("random_state", function()
  T.it("returns default 32-char string", function()
    local s = oauth.random_state()
    T.eq(#s, 32)
  end)

  T.it("respects length parameter", function()
    T.eq(#oauth.random_state(16), 16)
    T.eq(#oauth.random_state(64), 64)
  end)

  T.it("contains only URL-safe chars", function()
    local s = oauth.random_state(128)
    T.ok(s:match("^[A-Za-z0-9%-_]+$"), "only URL-safe chars")
  end)

  T.it("returns different values on successive calls", function()
    math.randomseed(os.time())
    local a = oauth.random_state(32)
    local b = oauth.random_state(32)
    -- Vanishingly unlikely to collide
    T.ok(a ~= b, "successive calls differ")
  end)
end)

-- ── pkce_verifier ─────────────────────────────────────────────────────────────

T.describe("pkce_verifier", function()
  T.it("returns default 64-char string", function()
    local v = oauth.pkce_verifier()
    T.eq(#v, 64)
  end)

  T.it("clamps to 43-128 range", function()
    T.eq(#oauth.pkce_verifier(10),  43)
    T.eq(#oauth.pkce_verifier(200), 128)
    T.eq(#oauth.pkce_verifier(43),  43)
    T.eq(#oauth.pkce_verifier(128), 128)
  end)

  T.it("contains only URL-safe chars (RFC 7636 §4.1)", function()
    local v = oauth.pkce_verifier(128)
    T.ok(v:match("^[A-Za-z0-9%-_.~]+$"), "only unreserved chars")
  end)
end)

-- ── pkce_challenge ────────────────────────────────────────────────────────────

T.describe("pkce_challenge: plain method", function()
  T.it("returns plain method when no sha256_fn provided", function()
    local v = oauth.pkce_verifier()
    local ch = oauth.pkce_challenge(v)
    T.eq(ch.code_challenge_method, "plain")
    T.eq(ch.code_challenge,        v)
  end)
end)

T.describe("pkce_challenge: S256 method", function()
  -- Inject a fake sha256 that returns a fixed 32-byte string for determinism.
  local fake_digest = string.rep("\xAB", 32)
  local function fake_sha256(_) return fake_digest end

  T.it("returns S256 method when sha256_fn is provided", function()
    local v = oauth.pkce_verifier()
    local ch = oauth.pkce_challenge(v, fake_sha256)
    T.eq(ch.code_challenge_method, "S256")
  end)

  T.it("code_challenge is base64url of digest", function()
    local v = oauth.pkce_verifier()
    local ch = oauth.pkce_challenge(v, fake_sha256)
    T.eq(ch.code_challenge, oauth.base64url_encode(fake_digest))
  end)

  T.it("no padding in code_challenge", function()
    local v = oauth.pkce_verifier()
    local ch = oauth.pkce_challenge(v, fake_sha256)
    T.ok(not ch.code_challenge:find("="), "no padding chars")
  end)
end)

-- ── auth_url ──────────────────────────────────────────────────────────────────

T.describe("auth_url", function()
  local base = "https://auth.example.com/authorize"

  T.it("produces URL with required params", function()
    local url = oauth.auth_url({
      base_url     = base,
      client_id    = "client123",
      redirect_uri = "https://app.example.com/callback",
      scope        = "openid profile",
      state        = "stateXYZ",
    })
    T.ok(url:find("response_type=code"),                     "response_type=code present")
    T.ok(url:find("client_id=client123"),                    "client_id present")
    T.ok(url:find("state=stateXYZ"),                         "state present")
    T.ok(url:find("scope=openid"),                           "scope present")
    T.ok(url:sub(1, #base) == base,                          "starts with base_url")
  end)

  T.it("includes PKCE params when provided", function()
    local url = oauth.auth_url({
      base_url               = base,
      client_id              = "client123",
      redirect_uri           = "https://app.example.com/callback",
      code_challenge         = "mychallenge",
      code_challenge_method  = "S256",
    })
    T.ok(url:find("code_challenge=mychallenge"), "code_challenge present")
    T.ok(url:find("code_challenge_method=S256"), "code_challenge_method present")
  end)

  T.it("defaults code_challenge_method to plain", function()
    local url = oauth.auth_url({
      base_url       = base,
      client_id      = "c",
      redirect_uri   = "https://x.com/cb",
      code_challenge = "verifier",
    })
    T.ok(url:find("code_challenge_method=plain"), "defaults to plain")
  end)

  T.it("includes extra params", function()
    local url = oauth.auth_url({
      base_url    = base,
      client_id   = "c",
      redirect_uri = "https://x.com/cb",
      extra       = { prompt = "consent", access_type = "offline" },
    })
    T.ok(url:find("prompt=consent"),       "extra param prompt present")
    T.ok(url:find("access_type=offline"),  "extra param access_type present")
  end)
end)

-- ── token_request ─────────────────────────────────────────────────────────────

T.describe("token_request: authorization_code", function()
  T.it("produces correct body fields", function()
    local body, headers = oauth.token_request("authorization_code", {
      client_id    = "clientA",
      client_secret = "secretS",
      code         = "authcode123",
      redirect_uri = "https://app.example.com/callback",
    })
    T.eq(type(body), "string")
    local p = oauth.parse_query(body)
    T.eq(p.grant_type,    "authorization_code")
    T.eq(p.client_id,     "clientA")
    T.eq(p.client_secret, "secretS")
    T.eq(p.code,          "authcode123")
    T.eq(p.redirect_uri,  "https://app.example.com/callback")
  end)

  T.it("includes code_verifier for PKCE", function()
    local body = oauth.token_request("authorization_code", {
      client_id    = "c",
      code         = "xyz",
      redirect_uri = "https://x.com/cb",
      code_verifier = "verifierABC",
    })
    local p = oauth.parse_query(body)
    T.eq(p.code_verifier, "verifierABC")
  end)

  T.it("returns Content-Type header", function()
    local _, headers = oauth.token_request("authorization_code", {
      client_id = "c", code = "x", redirect_uri = "https://x.com/cb",
    })
    T.eq(headers["Content-Type"], "application/x-www-form-urlencoded")
  end)
end)

T.describe("token_request: refresh_token", function()
  T.it("produces correct body fields", function()
    local body = oauth.token_request("refresh_token", {
      client_id     = "c",
      client_secret = "s",
      refresh_token = "rt123",
    })
    local p = oauth.parse_query(body)
    T.eq(p.grant_type,     "refresh_token")
    T.eq(p.client_id,      "c")
    T.eq(p.refresh_token,  "rt123")
    T.eq(p.client_secret,  "s")
  end)
end)

T.describe("token_request: client_credentials", function()
  T.it("produces correct body fields", function()
    local body = oauth.token_request("client_credentials", {
      client_id     = "c",
      client_secret = "s",
      scope         = "api.read",
    })
    local p = oauth.parse_query(body)
    T.eq(p.grant_type,    "client_credentials")
    T.eq(p.client_id,     "c")
    T.eq(p.client_secret, "s")
    T.eq(p.scope,         "api.read")
  end)
end)

T.describe("token_request: password", function()
  T.it("produces correct body fields", function()
    local body = oauth.token_request("password", {
      client_id = "c",
      username  = "user@example.com",
      password  = "s3cr3t",
      scope     = "profile",
    })
    local p = oauth.parse_query(body)
    T.eq(p.grant_type, "password")
    T.eq(p.username,   "user@example.com")
    T.eq(p.password,   "s3cr3t")
    T.eq(p.scope,      "profile")
  end)
end)

T.describe("token_request: unknown grant type", function()
  T.it("returns nil, errmsg", function()
    local body, err = oauth.token_request("magic", {})
    T.eq(body, nil)
    T.ok(type(err) == "string" and err:find("magic"), "error mentions grant type")
  end)
end)

-- ── parse_token_response ──────────────────────────────────────────────────────

T.describe("parse_token_response", function()
  T.it("extracts access_token and other fields", function()
    local json = [[{
      "access_token": "eyJabc",
      "token_type": "Bearer",
      "expires_in": 3600,
      "refresh_token": "rt_xyz",
      "scope": "openid profile"
    }]]
    local token, err = oauth.parse_token_response(json)
    T.eq(err, nil)
    T.eq(token.access_token,  "eyJabc")
    T.eq(token.token_type,    "Bearer")
    T.eq(token.expires_in,    3600)
    T.eq(token.refresh_token, "rt_xyz")
    T.eq(token.scope,         "openid profile")
  end)

  T.it("returns nil, err when access_token missing", function()
    local token, err = oauth.parse_token_response('{"token_type":"Bearer"}')
    T.eq(token, nil)
    T.ok(type(err) == "string", "returns error string")
  end)

  T.it("returns nil, err for server error response", function()
    local token, err = oauth.parse_token_response('{"error":"invalid_client","error_description":"Bad credentials"}')
    T.eq(token, nil)
    T.ok(err:find("invalid_client"), "error code in message")
    T.ok(err:find("Bad credentials"), "description in message")
  end)

  T.it("returns nil, err for invalid JSON", function()
    local token, err = oauth.parse_token_response("not json at all")
    T.eq(token, nil)
    T.ok(type(err) == "string", "error message returned")
  end)

  T.it("handles optional id_token field", function()
    local json = '{"access_token":"at","token_type":"Bearer","id_token":"id.jwt.here"}'
    local token = oauth.parse_token_response(json)
    T.eq(token.id_token, "id.jwt.here")
  end)
end)

-- ── jwt_decode ────────────────────────────────────────────────────────────────
-- Real JWT from jwt.io (algorithm: HS256, payload: sub/name/iat)
-- Header:  {"alg":"HS256","typ":"JWT"}
-- Payload: {"sub":"1234567890","name":"John Doe","iat":1516239022}
-- Signature: irrelevant (we don't verify)

local SAMPLE_JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
  .. ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
  .. ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

T.describe("jwt_decode", function()
  T.it("decodes a real JWT", function()
    local decoded, err = oauth.jwt_decode(SAMPLE_JWT)
    T.eq(err, nil)
    T.eq(type(decoded), "table")
    T.eq(decoded.header.alg,        "HS256")
    T.eq(decoded.header.typ,        "JWT")
    T.eq(decoded.payload.sub,       "1234567890")
    T.eq(decoded.payload.name,      "John Doe")
    T.eq(decoded.payload.iat,       1516239022)
    T.eq(type(decoded.signature_b64), "string")
    T.ok(#decoded.signature_b64 > 0, "signature is non-empty")
  end)

  T.it("returns nil, err for non-string", function()
    local d, err = oauth.jwt_decode(42)
    T.eq(d, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil, err for too few parts", function()
    local d, err = oauth.jwt_decode("only.twoparts")
    T.eq(d, nil)
    T.ok(type(err) == "string" and err:find("3"), "error mentions expected count")
  end)

  T.it("returns nil, err for invalid base64url in header", function()
    local d, err = oauth.jwt_decode("!!!.payload.sig")
    T.eq(d, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── jwt_expired ───────────────────────────────────────────────────────────────

T.describe("jwt_expired", function()
  T.it("returns false when exp is in the future", function()
    local payload = { exp = os.time() + 3600 }
    T.ok(not oauth.jwt_expired(payload), "not expired")
  end)

  T.it("returns true when exp is in the past", function()
    local payload = { exp = os.time() - 1 }
    T.ok(oauth.jwt_expired(payload), "expired")
  end)

  T.it("returns false when no exp claim", function()
    T.ok(not oauth.jwt_expired({}), "no exp → not expired")
  end)

  T.it("returns true for non-table payload", function()
    T.ok(oauth.jwt_expired(nil), "nil payload → expired")
    T.ok(oauth.jwt_expired("string"), "string payload → expired")
  end)

  T.it("uses injectable clock", function()
    local payload = { exp = 1000 }
    -- Before expiry
    T.ok(not oauth.jwt_expired(payload, function() return 999 end))
    -- At expiry (exp == now → expired per >=)
    T.ok(oauth.jwt_expired(payload, function() return 1000 end))
    -- After expiry
    T.ok(oauth.jwt_expired(payload, function() return 1001 end))
  end)
end)

-- ── jwt_claims ────────────────────────────────────────────────────────────────

T.describe("jwt_claims", function()
  T.it("returns payload table for valid JWT", function()
    local claims, err = oauth.jwt_claims(SAMPLE_JWT)
    T.eq(err, nil)
    T.eq(claims.sub,  "1234567890")
    T.eq(claims.name, "John Doe")
    T.eq(claims.iat,  1516239022)
  end)

  T.it("returns nil, err for invalid JWT", function()
    local claims, err = oauth.jwt_claims("bad.token")
    T.eq(claims, nil)
    T.ok(type(err) == "string")
  end)
end)
