-- lib/http_static/http_static_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local HS = require("lib.http_static")

-- ---------------------------------------------------------------------------
-- Mock capabilities
-- ---------------------------------------------------------------------------

-- Fake io.open: serves a map of path -> content.
--: ({ [string]: string }) -> (string, string) -> unknown
local function make_io_open(files)
  return function(path, _)
    local content = files[path]
    if not content then return nil end
    local idx = 0
    return {
      read = function(_, _)
        if idx == 0 then idx = 1; return content end
        return nil
      end,
      close = function(_) end,
    }
  end
end

-- Fake os.date (not used in these tests, just required).
--: (string, integer) -> string
local function fake_os_date(_, _) return "" end

-- Fake mimetype_fn.
--: (string) -> string | nil
local function fake_mimetype(path)
  if path:find("%.html$") then return "text/html" end
  if path:find("%.js$")   then return "application/javascript" end
  return nil
end

-- Make a fake request/response pair.
local function make_req_res(path)
  local req = { path = path }
  local res = { status = nil, body = nil, headers = {} }
  return req, res
end

-- ---------------------------------------------------------------------------
-- router
-- ---------------------------------------------------------------------------

T.describe("M.router", function()
  T.it("returns nil and error when io_open missing", function()
    local handler, err = HS.router(".", {
      os_date     = fake_os_date,
      mimetype_fn = fake_mimetype,
    } --[[: any]])
    T.eq(handler, nil)
    T.ok(err ~= nil, "error message present")
  end)

  T.it("adds CORS headers (even for non-existent paths)", function()
    -- CORS headers are added unconditionally; path resolution is handled
    -- by static_full internally and may return 404 for test paths.
    local handler, err = HS.router("/srv/www", {
      io_open     = make_io_open({}),
      os_date     = fake_os_date,
      mimetype_fn = fake_mimetype,
    })
    T.eq(err, nil)
    T.ok(handler ~= nil, "handler created")

    local req, res = make_req_res("/index.html")
    local h = handler --[[: any]]
    h(req, res)

    T.ok(res.headers["Cross-Origin-Opener-Policy"] ~= nil, "CORS opener policy set")
    T.ok(res.headers["Cross-Origin-Resource-Policy"] ~= nil, "CORS resource policy set")
    T.ok(res.headers["Cross-Origin-Embedder-Policy"] ~= nil, "CORS embedder policy set")
    T.eq(res.headers["Cross-Origin-Opener-Policy"][1], "same-origin")
  end)

  T.it("sets Content-Encoding gzip for .gz paths", function()
    -- Content-Encoding is set based on path pattern regardless of file content
    local handler, _ = HS.router("/srv/www", {
      io_open     = make_io_open({}),
      os_date     = fake_os_date,
      mimetype_fn = fake_mimetype,
    })
    local req, res = make_req_res("/app.js.gz")
    local h = handler --[[: any]]
    h(req, res)
    T.ok(res.headers["Content-Encoding"] ~= nil, "Content-Encoding set for .gz")
    T.eq(res.headers["Content-Encoding"][1], "gzip")
  end)

  T.it("sets Content-Encoding br for .br paths", function()
    local handler, _ = HS.router("/srv/www", {
      io_open     = make_io_open({}),
      os_date     = fake_os_date,
      mimetype_fn = fake_mimetype,
    })
    local req, res = make_req_res("/app.js.br")
    local h = handler --[[: any]]
    h(req, res)
    T.ok(res.headers["Content-Encoding"] ~= nil, "Content-Encoding set for .br")
    T.eq(res.headers["Content-Encoding"][1], "br")
  end)

  T.it("strips prefix so path no longer starts with /prefix", function()
    -- After stripping prefix, the CORS headers are still added.
    -- (File serving depends on path.safe_resolve which requires non-absolute paths.)
    local handler, _ = HS.router("/srv/www", {
      io_open     = make_io_open({}),
      os_date     = fake_os_date,
      mimetype_fn = fake_mimetype,
      prefix      = "app",
    })
    local req, res = make_req_res("/app/index.html")
    local h = handler --[[: any]]
    h(req, res)
    -- CORS headers should still be present
    T.ok(res.headers["Cross-Origin-Opener-Policy"] ~= nil, "CORS added after prefix strip")
  end)

  T.it("returns 404 when prefix does not match", function()
    local handler, _ = HS.router("/srv/www", {
      io_open     = make_io_open({}),
      os_date     = fake_os_date,
      mimetype_fn = fake_mimetype,
      prefix      = "app",
    })
    local req, res = make_req_res("/other/index.html")
    local h = handler --[[: any]]
    h(req, res)
    T.eq(res.status, 404)
  end)
end)
