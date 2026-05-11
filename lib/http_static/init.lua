-- lib/http_static/init.lua
-- Static file server with CORS headers, pre-compressed file support
-- (gzip .gz, brotli .br), and optional path-prefix stripping.
--
-- Wraps lib.http.router.static_full with the additions the example script
-- adds: Cross-Origin-* headers, Content-Encoding detection, and prefix
-- routing.  All I/O capabilities are injected via opts.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--:: http_static_opts = { io_open: (string, string) -> unknown, os_date: (string, integer) -> string, mimetype_fn: (string) -> string | nil, prefix?: string }

-- Build a request handler that:
--  - Optionally strips a URL prefix (opts.prefix, without leading "/")
--  - Serves files from root via static_full
--  - Adds Cross-Origin-Opener-Policy / Resource-Policy / Embedder-Policy headers
--  - Detects .gz/.br file extensions and sets Content-Encoding accordingly
--  - Falls back to opts.mimetype_fn for content-type when static_full doesn't set one
--
-- Returns (handler, nil) on success or (nil, errmsg) on failure.
--
-- opts.io_open     — required; injected io.open equivalent
-- opts.os_date     — required; injected os.date equivalent
-- opts.mimetype_fn — required; (path) -> mimetype_string | nil
-- opts.prefix      — optional; strip this URL prefix (e.g. "app" strips "/app")
--
--: (string, http_static_opts) -> (((unknown, unknown) -> nil) | nil, string | nil)
M.router = function(root, opts)
  if not opts then return nil, "http_static: opts is required" end
  if not opts.io_open    then return nil, "http_static: opts.io_open is required" end
  if not opts.os_date    then return nil, "http_static: opts.os_date is required" end
  if not opts.mimetype_fn then return nil, "http_static: opts.mimetype_fn is required" end

  local static_full = require("lib.http.router.static_full")
  local static_raw, err = static_full.router(root, {
    io_open = opts.io_open,
    os_date = opts.os_date,
  })
  if not static_raw then return nil, err end
  local static = static_raw

  local prefix_path = opts.prefix and ("/" .. opts.prefix) or nil --: string | nil
  local prefix_len  = 0 --: integer
  if prefix_path then prefix_len = #prefix_path end
  local mimetype_fn = opts.mimetype_fn

  --: (unknown, unknown) -> nil
  return function(req, res)
    local r = req --[[:! { path: string }]]
    local s = res --[[:! { status: integer | nil, body: string | nil, headers: { [string]: { [integer]: string } } }]]

    -- Prefix stripping
    if prefix_path then
      if r.path:sub(1, prefix_len) ~= prefix_path then
        s.status = 404
        return
      end
      r.path = r.path:sub(prefix_len + 1)
      if r.path == "" then r.path = "/" end
    end

    -- Delegate to static_full
    static(req, res)

    -- Cross-Origin isolation headers
    s.headers["Cross-Origin-Opener-Policy"]   = { "same-origin" }
    s.headers["Cross-Origin-Resource-Policy"] = { "cross-origin" }
    s.headers["Cross-Origin-Embedder-Policy"] = { "require-corp" }

    -- Compression and content-type for pre-compressed files
    if r.path:find("%.gz$") then
      s.headers["Content-Encoding"] = { "gzip" }
      s.headers["Content-Length"]   = nil
      if not s.headers["Content-Type"] then
        local ct = mimetype_fn(root .. r.path:sub(1, -4))
        if ct then s.headers["Content-Type"] = { ct } end
      end
    elseif r.path:find("%.br$") then
      s.headers["Content-Encoding"] = { "br" }
      s.headers["Content-Length"]   = nil
      if not s.headers["Content-Type"] then
        local ct = mimetype_fn(root .. r.path:sub(1, -4))
        if ct then s.headers["Content-Type"] = { ct } end
      end
    else
      if not s.headers["Content-Type"] then
        local ct = mimetype_fn(root .. r.path)
        if ct then s.headers["Content-Type"] = { ct } end
      end
    end
  end, nil
end

return M
