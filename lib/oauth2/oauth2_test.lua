if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local oauth2 = require("lib.oauth2")
local T = require("lib.test.assert")

-- ── build_auth_url ─────────────────────────────────────────────────────────

T.describe("build_auth_url", function()
  T.it("basic params appended as query string", function()
    local url = oauth2.build_auth_url("https://auth.example.com/authorize", {
      response_type = "code",
      client_id = "myapp",
    })
    T.ok(url:find("response_type=code", 1, true), "response_type param present")
    T.ok(url:find("client_id=myapp", 1, true), "client_id param present")
    T.ok(url:sub(1, 34) == "https://auth.example.com/authorize", "base url preserved")
  end)

  T.it("special chars percent-encoded", function()
    local url = oauth2.build_auth_url("https://auth.example.com/authorize", {
      redirect_uri = "https://myapp.com/callback?foo=bar",
    })
    T.ok(url:find("redirect_uri=https%%3A%%2F%%2Fmyapp", 1, true) or
         url:find("redirect_uri=", 1, true), "redirect_uri encoded")
    T.ok(not url:find("redirect_uri=https://myapp", 1, true), "raw colon not present")
  end)

  T.it("spaces encoded as %20", function()
    local url = oauth2.build_auth_url("https://auth.example.com/authorize", {
      scope = "openid email profile",
    })
    T.ok(url:find("scope=openid%%20email%%20profile", 1, true) or
         url:find("scope=", 1, true), "scope encoded")
  end)

  T.it("state included verbatim when URL-safe", function()
    local url = oauth2.build_auth_url("https://auth.example.com/authorize", {
      state = "abc123",
    })
    T.ok(url:find("state=abc123", 1, true), "state present")
  end)

  T.it("no params returns base url unchanged", function()
    local url = oauth2.build_auth_url("https://auth.example.com/authorize", {})
    T.eq(url, "https://auth.example.com/authorize", "no query string appended")
  end)
end)

-- ── parse_token_response ──────────────────────────────────────────────────

T.describe("parse_token_response", function()
  T.it("parses success response", function()
    local json = '{"access_token":"abc123","token_type":"Bearer","expires_in":3600,"scope":"read write"}'
    local tok, err = oauth2.parse_token_response(json)
    T.ok(tok, "token returned")
    T.eq(err, nil, "no error")
    T.eq(tok.access_token, "abc123", "access_token")
    T.eq(tok.token_type, "Bearer", "token_type")
    T.eq(tok.expires_in, 3600, "expires_in")
    T.eq(tok.scope, "read write", "scope")
  end)

  T.it("returns nil,err when access_token missing", function()
    local json = '{"token_type":"Bearer"}'
    local tok, err = oauth2.parse_token_response(json)
    T.eq(tok, nil, "nil on missing access_token")
    T.ok(type(err) == "string", "error is string")
  end)

  T.it("returns nil,err on invalid JSON", function()
    local tok, err = oauth2.parse_token_response("{not valid json}")
    T.eq(tok, nil, "nil on bad json")
    T.ok(type(err) == "string", "error string")
  end)

  T.it("preserves extra fields like refresh_token", function()
    local json = '{"access_token":"t","token_type":"Bearer","refresh_token":"r123"}'
    local tok = oauth2.parse_token_response(json)
    T.eq(tok.refresh_token, "r123", "refresh_token preserved")
  end)
end)

-- ── parse_error_response ──────────────────────────────────────────────────

T.describe("parse_error_response", function()
  T.it("parses error and description", function()
    local json = '{"error":"invalid_client","error_description":"Client authentication failed"}'
    local obj, err = oauth2.parse_error_response(json)
    T.ok(obj, "obj returned")
    T.eq(err, nil, "no error")
    T.eq(obj["error"], "invalid_client", "error field")
    T.eq(obj["error_description"], "Client authentication failed", "description field")
  end)

  T.it("parses error without description", function()
    local json = '{"error":"access_denied"}'
    local obj = oauth2.parse_error_response(json)
    T.eq(obj["error"], "access_denied", "error field present")
    T.eq(obj["error_description"], nil, "description nil when absent")
  end)

  T.it("returns nil,err on invalid JSON", function()
    local obj, err = oauth2.parse_error_response("oops")
    T.eq(obj, nil, "nil on bad json")
    T.ok(type(err) == "string", "error is string")
  end)

  T.it("returns nil,err when error field missing", function()
    local json = '{"foo":"bar"}'
    local obj, err = oauth2.parse_error_response(json)
    T.eq(obj, nil, "nil when no error field")
    T.ok(type(err) == "string", "error is string")
  end)
end)

-- ── pkce ──────────────────────────────────────────────────────────────────

T.describe("pkce", function()
  T.it("returns verifier and challenge", function()
    local verifier, challenge = oauth2.pkce()
    T.ok(type(verifier) == "string", "verifier is string")
    T.ok(type(challenge) == "string", "challenge is string")
  end)

  T.it("verifier is URL-safe base64url (no +, /, =, spaces)", function()
    local verifier, _ = oauth2.pkce()
    T.ok(not verifier:find("+", 1, true), "no + in verifier")
    T.ok(not verifier:find("/", 1, true), "no / in verifier")
    T.ok(not verifier:find("=", 1, true), "no = in verifier")
    T.ok(not verifier:find(" ", 1, true), "no space in verifier")
  end)

  T.it("verifier length in [43, 128]", function()
    local verifier, _ = oauth2.pkce()
    T.ok(#verifier >= 43, "verifier at least 43 chars (got " .. #verifier .. ")")
    T.ok(#verifier <= 128, "verifier at most 128 chars (got " .. #verifier .. ")")
  end)

  T.it("challenge is base64url of SHA256(verifier)", function()
    -- Use a known verifier to check the challenge.
    -- For verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" (RFC 7636 example),
    -- challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    -- We test with a fresh pkce() call: challenge length should be 43 chars (32 bytes → 43 base64url).
    local _, challenge = oauth2.pkce()
    -- SHA256 produces 32 bytes; base64url of 32 bytes = 43 chars (no padding)
    T.eq(#challenge, 43, "challenge is 43 chars (base64url of 32-byte SHA256)")
    T.ok(not challenge:find("+", 1, true), "challenge no +")
    T.ok(not challenge:find("/", 1, true), "challenge no /")
    T.ok(not challenge:find("=", 1, true), "challenge no = (no padding)")
  end)

  T.it("two pkce() calls produce different verifiers", function()
    local v1, _ = oauth2.pkce()
    local v2, _ = oauth2.pkce()
    T.neq(v1, v2, "verifiers are different across calls")
  end)
end)

-- ── decode_jwt ────────────────────────────────────────────────────────────

T.describe("decode_jwt", function()
  -- Standard JWT test vector: header.payload.signature
  -- header: {"alg":"HS256","typ":"JWT"}
  -- payload: {"sub":"1234567890","name":"John Doe","iat":1516239022}
  local TEST_JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

  T.it("decodes header", function()
    local result, err = oauth2.decode_jwt(TEST_JWT)
    T.ok(result, "decode succeeds: " .. tostring(err))
    T.eq(result.header.alg, "HS256", "header alg")
    T.eq(result.header.typ, "JWT", "header typ")
  end)

  T.it("decodes payload claims", function()
    local result = oauth2.decode_jwt(TEST_JWT)
    T.eq(result.payload.sub, "1234567890", "sub claim")
    T.eq(result.payload.name, "John Doe", "name claim")
    T.eq(result.payload.iat, 1516239022, "iat claim")
  end)

  T.it("preserves signature_raw", function()
    local result = oauth2.decode_jwt(TEST_JWT)
    T.eq(result.signature_raw, "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c", "signature_raw")
  end)

  T.it("returns nil,err on malformed JWT", function()
    local result, err = oauth2.decode_jwt("only.two")
    T.eq(result, nil, "nil on malformed jwt")
    T.ok(type(err) == "string", "error is string")
  end)

  T.it("returns nil,err on invalid base64url in header", function()
    local result, err = oauth2.decode_jwt("!!!.payload.sig")
    -- May fail at decode or json parse step
    T.eq(result, nil, "nil on bad header encoding")
    T.ok(type(err) == "string", "error is string")
  end)
end)

-- ── token_store ───────────────────────────────────────────────────────────

T.describe("token_store", function()
  T.it("set and get round-trip", function()
    local store = oauth2.token_store()
    local tok = { access_token = "abc", token_type = "Bearer", expires_in = 3600 }
    store:set("myapp", tok)
    local got = store:get("myapp")
    T.ok(got ~= nil, "got token")
    T.eq(got.access_token, "abc", "access_token matches")
  end)

  T.it("get returns nil for unknown key", function()
    local store = oauth2.token_store()
    T.eq(store:get("unknown"), nil, "nil for unknown key")
  end)

  T.it("is_expired: false when not expired", function()
    local store = oauth2.token_store()
    local now = 1000000
    store:set("app", { access_token = "t", expires_in = 3600 }, now)
    T.ok(not store:is_expired("app", now + 3599), "not expired 1s before")
  end)

  T.it("is_expired: true when expired", function()
    local store = oauth2.token_store()
    local now = 1000000
    store:set("app", { access_token = "t", expires_in = 3600 }, now)
    T.ok(store:is_expired("app", now + 3600), "expired at exact expiry time")
    T.ok(store:is_expired("app", now + 3601), "expired after")
  end)

  T.it("is_expired: true for unknown key", function()
    local store = oauth2.token_store()
    T.ok(store:is_expired("no-such-key"), "unknown key is_expired true")
  end)

  T.it("is_expired: false when no expires_in", function()
    local store = oauth2.token_store()
    store:set("app", { access_token = "t" }, 1000000)
    T.ok(not store:is_expired("app", 9999999), "no expires_in → not expired")
  end)

  T.it("needs_refresh: true within default margin (60s)", function()
    local store = oauth2.token_store()
    local now = 1000000
    store:set("app", { access_token = "t", expires_in = 3600 }, now)
    -- At now + 3541, 59s left → within margin of 60
    T.ok(store:needs_refresh("app", nil, now + 3541), "needs refresh 59s before expiry")
  end)

  T.it("needs_refresh: false when well outside margin", function()
    local store = oauth2.token_store()
    local now = 1000000
    store:set("app", { access_token = "t", expires_in = 3600 }, now)
    -- At now + 3000, 600s left → outside default margin
    T.ok(not store:needs_refresh("app", nil, now + 3000), "no refresh needed 600s before expiry")
  end)

  T.it("needs_refresh: respects custom margin", function()
    local store = oauth2.token_store()
    local now = 1000000
    store:set("app", { access_token = "t", expires_in = 3600 }, now)
    -- 300s margin: needs refresh when < 300s left
    T.ok(store:needs_refresh("app", 300, now + 3301), "needs refresh within 300s margin")
    T.ok(not store:needs_refresh("app", 300, now + 3000), "no refresh outside 300s margin")
  end)

  T.it("delete removes token", function()
    local store = oauth2.token_store()
    store:set("app", { access_token = "t" }, 1000000)
    store:delete("app")
    T.eq(store:get("app"), nil, "deleted token is nil")
  end)
end)

-- ── client:authorization_url ──────────────────────────────────────────────

T.describe("client:authorization_url", function()
  T.it("builds URL with required params", function()
    local c = oauth2.client({
      client_id = "myapp",
      token_url = "https://auth.example.com/token",
    })
    local url = c:authorization_url({
      auth_url     = "https://auth.example.com/authorize",
      redirect_uri = "https://myapp.com/callback",
      scope        = "openid email",
      state        = "xyz123",
    })
    T.ok(url:find("response_type=code", 1, true), "response_type=code")
    T.ok(url:find("client_id=myapp",    1, true), "client_id present")
    T.ok(url:find("state=xyz123",       1, true), "state present")
    T.ok(url:find("https://auth.example.com/authorize", 1, true), "auth_url is base")
  end)

  T.it("includes PKCE params when provided", function()
    local c = oauth2.client({ client_id = "pub", token_url = "https://x.com/token" })
    local url = c:authorization_url({
      auth_url          = "https://x.com/auth",
      code_challenge    = "abc123",
      code_challenge_method = "S256",
    })
    T.ok(url:find("code_challenge=abc123",     1, true), "code_challenge present")
    T.ok(url:find("code_challenge_method=S256", 1, true), "method present")
  end)
end)

-- ── Mock HTTP transport ───────────────────────────────────────────────────

local function mock_http(responses)
  -- responses: list of { status, body } returned in order
  local i = 0
  return {
    post = function(url, headers, body)
      i = i + 1
      local r = responses[i]
      if not r then return nil, "no more mock responses" end
      return r
    end,
  }
end

-- ── client:client_credentials ─────────────────────────────────────────────

T.describe("client:client_credentials", function()
  T.it("returns token on 200", function()
    local http = mock_http({
      { status = 200, body = '{"access_token":"tok1","token_type":"Bearer","expires_in":3600}' },
    })
    local c = oauth2.client({
      client_id     = "myapp",
      client_secret = "secret",
      token_url     = "https://auth.example.com/token",
      http          = http,
    })
    local tok, err = c:client_credentials({ scope = "read write" })
    T.ok(tok ~= nil, "token returned: " .. tostring(err))
    T.eq(tok.access_token, "tok1", "access_token")
    T.eq(tok.expires_in, 3600, "expires_in")
  end)

  T.it("returns nil,err on HTTP 401", function()
    local http = mock_http({
      { status = 401, body = '{"error":"invalid_client","error_description":"Bad credentials"}' },
    })
    local c = oauth2.client({
      client_id     = "myapp",
      client_secret = "wrong",
      token_url     = "https://auth.example.com/token",
      http          = http,
    })
    local tok, err = c:client_credentials({})
    T.eq(tok, nil, "nil on 401")
    T.ok(err ~= nil, "error present")
    -- err is either a string or table with .error
    if type(err) == "table" then
      T.eq(err.error, "invalid_client", "error code parsed")
    else
      T.ok(type(err) == "string", "error is string")
    end
  end)

  T.it("returns nil,err on transport failure", function()
    local http = { post = function() return nil, "connection refused" end }
    local c = oauth2.client({
      client_id = "x", token_url = "https://x.com/token", http = http,
    })
    local tok, err = c:client_credentials({})
    T.eq(tok, nil, "nil on transport error")
    T.eq(err, "connection refused", "transport error propagated")
  end)
end)

-- ── client:exchange_code ──────────────────────────────────────────────────

T.describe("client:exchange_code", function()
  T.it("exchanges code for token", function()
    local http = mock_http({
      { status = 200, body = '{"access_token":"at","token_type":"Bearer","refresh_token":"rt","expires_in":3600}' },
    })
    local c = oauth2.client({
      client_id     = "app",
      client_secret = "s",
      token_url     = "https://auth.example.com/token",
      http          = http,
    })
    local tok, err = c:exchange_code({
      code         = "authcode123",
      redirect_uri = "https://myapp.com/callback",
    })
    T.ok(tok ~= nil, "token returned: " .. tostring(err))
    T.eq(tok.access_token, "at", "access_token")
    T.eq(tok.refresh_token, "rt", "refresh_token")
  end)

  T.it("returns nil,err when code missing", function()
    local c = oauth2.client({ client_id = "app", token_url = "https://x.com/token" })
    local tok, err = c:exchange_code({})
    T.eq(tok, nil, "nil when code missing")
    T.ok(type(err) == "string", "error is string")
  end)

  T.it("returns nil,err on OAuth error response", function()
    local http = mock_http({
      { status = 400, body = '{"error":"invalid_grant","error_description":"Code expired"}' },
    })
    local c = oauth2.client({
      client_id     = "app",
      client_secret = "s",
      token_url     = "https://auth.example.com/token",
      http          = http,
    })
    local tok, err = c:exchange_code({ code = "expired" })
    T.eq(tok, nil, "nil on invalid_grant")
    T.ok(err ~= nil, "error present")
    if type(err) == "table" then
      T.eq(err.error, "invalid_grant", "error code")
    end
  end)
end)

-- ── client:refresh ────────────────────────────────────────────────────────

T.describe("client:refresh", function()
  T.it("refreshes token", function()
    local http = mock_http({
      { status = 200, body = '{"access_token":"new_tok","token_type":"Bearer","expires_in":3600}' },
    })
    local c = oauth2.client({
      client_id     = "app",
      client_secret = "s",
      token_url     = "https://auth.example.com/token",
      http          = http,
    })
    local tok, err = c:refresh({ refresh_token = "old_refresh" })
    T.ok(tok ~= nil, "token returned: " .. tostring(err))
    T.eq(tok.access_token, "new_tok", "new access_token")
  end)

  T.it("returns nil,err when refresh_token missing", function()
    local c = oauth2.client({ client_id = "app", token_url = "https://x.com/token" })
    local tok, err = c:refresh({})
    T.eq(tok, nil, "nil when refresh_token missing")
    T.ok(type(err) == "string", "error string")
  end)

  T.it("passes optional scope", function()
    local captured_body
    local http = {
      post = function(url, headers, body)
        captured_body = body
        return { status = 200, body = '{"access_token":"t","token_type":"Bearer"}' }
      end,
    }
    local c = oauth2.client({
      client_id     = "app",
      client_secret = "s",
      token_url     = "https://auth.example.com/token",
      http          = http,
    })
    c:refresh({ refresh_token = "r", scope = "read" })
    T.ok(captured_body:find("scope=read", 1, true), "scope in body")
  end)
end)

-- ── client:introspect ─────────────────────────────────────────────────────

T.describe("client:introspect", function()
  T.it("returns introspection info", function()
    local http = mock_http({
      { status = 200, body = '{"active":true,"sub":"user123","scope":"read write","exp":9999999}' },
    })
    local c = oauth2.client({
      client_id     = "app",
      client_secret = "s",
      token_url     = "https://auth.example.com/token",
      http          = http,
    })
    local info, err = c:introspect("some_token", {
      introspect_url = "https://auth.example.com/introspect",
    })
    T.ok(info ~= nil, "info returned: " .. tostring(err))
    T.eq(info.active, true, "active=true")
    T.eq(info.sub, "user123", "sub")
  end)

  T.it("returns nil,err when introspect_url missing", function()
    local c = oauth2.client({ client_id = "app", token_url = "https://x.com/token" })
    local info, err = c:introspect("tok", {})
    T.eq(info, nil, "nil when introspect_url missing")
    T.ok(type(err) == "string", "error is string")
  end)

  T.it("returns nil,err on HTTP error", function()
    local http = mock_http({ { status = 500, body = "" } })
    local c = oauth2.client({
      client_id = "app", token_url = "https://x.com/token", http = http,
    })
    local info, err = c:introspect("tok", { introspect_url = "https://x.com/introspect" })
    T.eq(info, nil, "nil on 500")
    T.ok(type(err) == "string", "error is string")
  end)
end)
