if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local env = require("lib.env_schema")

-- ---------------------------------------------------------------------------
-- string
-- ---------------------------------------------------------------------------
T.describe("env.string", function()
  T.it("returns value when present", function()
    local v, err = env.string():validate("hello")
    T.eq(v, "hello")
    T.eq(err, nil)
  end)

  T.it("returns nil when absent and no default", function()
    local v, err = env.string():validate(nil)
    T.eq(v, nil)
    T.eq(err, nil)
  end)

  T.it("returns default when absent", function()
    local v, err = env.string({ default = "localhost" }):validate(nil)
    T.eq(v, "localhost")
    T.eq(err, nil)
  end)

  T.it("returns default when empty string", function()
    local v, err = env.string({ default = "localhost" }):validate("")
    T.eq(v, "localhost")
    T.eq(err, nil)
  end)

  T.it("errors when required and missing", function()
    local v, err = env.string({ required = true }):validate(nil)
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("errors when required and empty", function()
    local v, err = env.string({ required = true }):validate("")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("min_length pass", function()
    local v, err = env.string({ min_length = 3 }):validate("abc")
    T.eq(v, "abc")
    T.eq(err, nil)
  end)

  T.it("min_length fail", function()
    local v, err = env.string({ min_length = 5 }):validate("abc")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("max_length pass", function()
    local v, err = env.string({ max_length = 5 }):validate("abc")
    T.eq(v, "abc")
    T.eq(err, nil)
  end)

  T.it("max_length fail", function()
    local v, err = env.string({ max_length = 2 }):validate("abc")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("pattern pass", function()
    local v, err = env.string({ pattern = "^%d+$" }):validate("1234")
    T.eq(v, "1234")
    T.eq(err, nil)
  end)

  T.it("pattern fail", function()
    local v, err = env.string({ pattern = "^%d+$" }):validate("abc")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)
end)

-- ---------------------------------------------------------------------------
-- number
-- ---------------------------------------------------------------------------
T.describe("env.number", function()
  T.it("parses integer string to number", function()
    local v, err = env.number():validate("42")
    T.eq(v, 42)
    T.eq(err, nil)
  end)

  T.it("parses float string", function()
    local v, err = env.number():validate("3.14")
    T.ok(math.abs(v - 3.14) < 1e-10)
    T.eq(err, nil)
  end)

  T.it("rejects non-numeric string", function()
    local v, err = env.number():validate("abc")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("uses default when absent", function()
    local v, err = env.number({ default = 5000 }):validate(nil)
    T.eq(v, 5000)
    T.eq(err, nil)
  end)

  T.it("min pass", function()
    local v, err = env.number({ min = 0 }):validate("1")
    T.eq(v, 1)
    T.eq(err, nil)
  end)

  T.it("min fail", function()
    local v, err = env.number({ min = 5 }):validate("3")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("max pass", function()
    local v, err = env.number({ max = 100 }):validate("99")
    T.eq(v, 99)
    T.eq(err, nil)
  end)

  T.it("max fail", function()
    local v, err = env.number({ max = 100 }):validate("200")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("required error", function()
    local v, err = env.number({ required = true }):validate(nil)
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)
end)

-- ---------------------------------------------------------------------------
-- integer
-- ---------------------------------------------------------------------------
T.describe("env.integer", function()
  T.it("parses whole number", function()
    local v, err = env.integer():validate("4")
    T.eq(v, 4)
    T.eq(err, nil)
  end)

  T.it("rejects float", function()
    local v, err = env.integer():validate("3.5")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("rejects non-numeric", function()
    local v, err = env.integer():validate("nope")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("uses default", function()
    local v, err = env.integer({ default = 4 }):validate(nil)
    T.eq(v, 4)
    T.eq(err, nil)
  end)

  T.it("min/max enforcement", function()
    local f = env.integer({ min = 1, max = 10 })
    local v, err = f:validate("0")
    T.eq(v, nil)
    T.ok(err ~= nil)
    v, err = f:validate("11")
    T.eq(v, nil)
    T.ok(err ~= nil)
    v, err = f:validate("5")
    T.eq(v, 5)
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- boolean
-- ---------------------------------------------------------------------------
T.describe("env.boolean", function()
  local truthy = { "true", "1", "yes", "on", "True", "YES", "ON" }
  local falsy  = { "false", "0", "no", "off", "False", "NO", "OFF" }

  T.it("truthy variants", function()
    for _, s in ipairs(truthy) do
      local v, err = env.boolean():validate(s)
      T.eq(v, true,  s .. " should be true")
      T.eq(err, nil, s .. " should not error")
    end
  end)

  T.it("falsy variants", function()
    for _, s in ipairs(falsy) do
      local v, err = env.boolean():validate(s)
      T.eq(v, false, s .. " should be false")
      T.eq(err, nil, s .. " should not error")
    end
  end)

  T.it("invalid value", function()
    local v, err = env.boolean():validate("maybe")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("uses default", function()
    local v, err = env.boolean({ default = false }):validate(nil)
    T.eq(v, false)
    T.eq(err, nil)
  end)

  T.it("required error", function()
    local v, err = env.boolean({ required = true }):validate(nil)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- enum
-- ---------------------------------------------------------------------------
T.describe("env.enum", function()
  local f = env.enum({"debug", "info", "warn", "error"}, { default = "info" })

  T.it("valid value", function()
    local v, err = f:validate("warn")
    T.eq(v, "warn")
    T.eq(err, nil)
  end)

  T.it("invalid value error", function()
    local v, err = f:validate("verbose")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("default when absent", function()
    local v, err = f:validate(nil)
    T.eq(v, "info")
    T.eq(err, nil)
  end)

  T.it("required error", function()
    local g = env.enum({"a", "b"}, { required = true })
    local v, err = g:validate(nil)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- list
-- ---------------------------------------------------------------------------
T.describe("env.list", function()
  T.it("splits comma-separated", function()
    local v, err = env.list():validate("a,b,c")
    T.eq(err, nil)
    T.eq(#v, 3)
    T.eq(v[1], "a")
    T.eq(v[2], "b")
    T.eq(v[3], "c")
  end)

  T.it("trims whitespace from items", function()
    local v, err = env.list():validate("  a , b ,  c  ")
    T.eq(err, nil)
    T.eq(v[1], "a")
    T.eq(v[2], "b")
    T.eq(v[3], "c")
  end)

  T.it("custom separator", function()
    local v, err = env.list({ sep = ":" }):validate("x:y:z")
    T.eq(err, nil)
    T.eq(#v, 3)
    T.eq(v[1], "x")
    T.eq(v[2], "y")
    T.eq(v[3], "z")
  end)

  T.it("returns empty table when absent (no default)", function()
    local v, err = env.list():validate(nil)
    T.eq(err, nil)
    T.eq(type(v), "table")
    T.eq(#v, 0)
  end)

  T.it("returns default when absent", function()
    local v, err = env.list({ default = {"x"} }):validate(nil)
    T.eq(err, nil)
    T.eq(v[1], "x")
  end)

  T.it("required error", function()
    local v, err = env.list({ required = true }):validate(nil)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- url
-- ---------------------------------------------------------------------------
T.describe("env.url", function()
  T.it("valid http url", function()
    local v, err = env.url():validate("http://example.com/path")
    T.eq(v, "http://example.com/path")
    T.eq(err, nil)
  end)

  T.it("valid postgres url", function()
    local v, err = env.url():validate("postgres://localhost/mydb")
    T.eq(v, "postgres://localhost/mydb")
    T.eq(err, nil)
  end)

  T.it("missing scheme rejected", function()
    local v, err = env.url():validate("example.com/path")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("scheme only rejected", function()
    local v, err = env.url():validate("http://")
    T.eq(v, nil)
    T.ok(err ~= nil, "expected error")
  end)

  T.it("required error", function()
    local v, err = env.url({ required = true }):validate(nil)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("default used when absent", function()
    local v, err = env.url({ default = "http://localhost" }):validate(nil)
    T.eq(v, "http://localhost")
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- port
-- ---------------------------------------------------------------------------
T.describe("env.port", function()
  T.it("valid port", function()
    local v, err = env.port():validate("8080")
    T.eq(v, 8080)
    T.eq(err, nil)
  end)

  T.it("port 1 (min)", function()
    local v, err = env.port():validate("1")
    T.eq(v, 1)
    T.eq(err, nil)
  end)

  T.it("port 65535 (max)", function()
    local v, err = env.port():validate("65535")
    T.eq(v, 65535)
    T.eq(err, nil)
  end)

  T.it("port 0 rejected", function()
    local v, err = env.port():validate("0")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("port 65536 rejected", function()
    local v, err = env.port():validate("65536")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("non-integer rejected", function()
    local v, err = env.port():validate("abc")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("default used", function()
    local v, err = env.port({ default = 3000 }):validate(nil)
    T.eq(v, 3000)
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- schema:parse
-- ---------------------------------------------------------------------------
T.describe("schema:parse", function()
  local schema = env.schema({
    PORT         = env.number({ default = 3000, min = 1, max = 65535 }),
    HOST         = env.string({ default = "localhost" }),
    DATABASE_URL = env.string({ required = true }),
    DEBUG        = env.boolean({ default = false }),
    LOG_LEVEL    = env.enum({"debug", "info", "warn", "error"}, { default = "info" }),
    MAX_WORKERS  = env.integer({ default = 4, min = 1 }),
    API_KEYS     = env.list({ sep = ",", default = {} }),
    TIMEOUT_MS   = env.number({ default = 5000 }),
  })

  T.it("all valid — types coerced correctly", function()
    local config, err = schema:parse({
      DATABASE_URL = "postgres://localhost/mydb",
      PORT         = "8080",
      DEBUG        = "true",
      LOG_LEVEL    = "warn",
      MAX_WORKERS  = "2",
      API_KEYS     = "key1,key2",
      TIMEOUT_MS   = "1000",
    })
    T.eq(err, nil)
    T.eq(config.PORT, 8080)
    T.eq(config.HOST, "localhost")     -- default
    T.eq(config.DATABASE_URL, "postgres://localhost/mydb")
    T.eq(config.DEBUG, true)
    T.eq(config.LOG_LEVEL, "warn")
    T.eq(config.MAX_WORKERS, 2)
    T.eq(config.API_KEYS[1], "key1")
    T.eq(config.API_KEYS[2], "key2")
    T.eq(config.TIMEOUT_MS, 1000)
  end)

  T.it("defaults applied when absent", function()
    local config, err = schema:parse({
      DATABASE_URL = "postgres://localhost/mydb",
    })
    T.eq(err, nil)
    T.eq(config.PORT, 3000)
    T.eq(config.HOST, "localhost")
    T.eq(config.DEBUG, false)
    T.eq(config.LOG_LEVEL, "info")
    T.eq(config.MAX_WORKERS, 4)
    T.eq(config.TIMEOUT_MS, 5000)
  end)

  T.it("missing required → error", function()
    local config, err = schema:parse({})
    T.eq(config, nil)
    T.ok(err ~= nil, "expected error")
    T.ok(err:find("DATABASE_URL") ~= nil, "error should mention DATABASE_URL")
  end)

  T.it("multiple errors collected", function()
    local s2 = env.schema({
      A = env.number({ required = true }),
      B = env.string({ required = true }),
    })
    local config, err = s2:parse({})
    T.eq(config, nil)
    T.ok(err ~= nil)
    T.ok(err:find("A") ~= nil, "error mentions A")
    T.ok(err:find("B") ~= nil, "error mentions B")
  end)

  T.it("bad PORT type → error", function()
    local config, err = schema:parse({
      DATABASE_URL = "postgres://localhost/mydb",
      PORT         = "notanumber",
    })
    T.eq(config, nil)
    T.ok(err ~= nil)
    T.ok(err:find("PORT") ~= nil)
  end)

  T.it("injectable source table, no os.getenv", function()
    -- explicitly pass a hand-crafted table — library never calls os.getenv
    local config, err = schema:parse({
      DATABASE_URL = "sqlite:///tmp/test.db",
    })
    T.eq(err, nil)
    T.eq(config.DATABASE_URL, "sqlite:///tmp/test.db")
  end)
end)

-- ---------------------------------------------------------------------------
-- schema:template
-- ---------------------------------------------------------------------------
T.describe("schema:template", function()
  T.it("generates commented .env lines for all fields", function()
    local schema = env.schema({
      PORT  = env.number({ default = 3000 }),
      DEBUG = env.boolean({ default = false }),
    })
    local tmpl = schema:template()
    T.ok(type(tmpl) == "string")
    T.ok(tmpl:find("PORT") ~= nil,  "template mentions PORT")
    T.ok(tmpl:find("DEBUG") ~= nil, "template mentions DEBUG")
    T.ok(tmpl:find("number") ~= nil, "template mentions type number")
    T.ok(tmpl:find("boolean") ~= nil, "template mentions type boolean")
    T.ok(tmpl:find("3000") ~= nil,  "template shows default 3000")
    T.ok(tmpl:find("#") ~= nil,     "template uses comment marker")
  end)

  T.it("includes required annotation when set", function()
    local schema = env.schema({
      DB = env.string({ required = true }),
    })
    local tmpl = schema:template()
    T.ok(tmpl:find("required") ~= nil, "template mentions required")
  end)

  T.it("enum shows allowed values", function()
    local schema = env.schema({
      LVL = env.enum({"debug", "info"}, { default = "info" }),
    })
    local tmpl = schema:template()
    T.ok(tmpl:find("debug") ~= nil)
    T.ok(tmpl:find("info") ~= nil)
  end)
end)
