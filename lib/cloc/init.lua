-- lib/cloc/init.lua
-- Count lines of code, comments, and blank lines per language extension.
-- All I/O is capability-injected: read_fn and walk_fn must be provided by
-- the caller.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ---------------------------------------------------------------------------
-- Language tables
-- ---------------------------------------------------------------------------

-- Extensions that are plain text (worth counting).
--:: is_text_ext = { [string]: boolean }
local is_text_ext = {
  c = true, cs = true, csx = true, cpp = true, cc = true, h = true, hpp = true,
  hh = true, hxx = true, ixx = true, java = true,
  js = true, jsx = true, cjs = true, mjs = true, ts = true, tsx = true,
  cts = true, mts = true,
  dfy = true, jakt = true, owen = true, jai = true, cone = true, qml = true,
  hx = true, kt = true, d = true,
  svelte = true, vue = true,
  fs = true, fsi = true, fsx = true, fsscript = true, re = true, res = true,
  php = true,
  f = true, ["for"] = true, ftn = true, i = true, fpp = true,
  f90 = true, i90 = true, f95 = true, f03 = true,
  cbl = true, ccp = true, cob = true, cpy = true,
  lua = true, hs = true, e = true, sql = true,
  py = true, rb = true, pl = true,
  lisp = true, lsp = true, s = true, clj = true, cljs = true, cljc = true,
  rkt = true, el = true,
  html = true, xhtml = true, svg = true, css = true,
  md = true, rst = true, tex = true, sty = true, org = true,
  txt = true, xml = true, xaml = true, yml = true, yaml = true, toml = true,
  ini = true, json = true, jsonc = true,
  edn = true, hxml = true, csproj = true, hxproj = true, editorconfig = true,
  sln = true,
  sh = true, fish = true, zsh = true, ps = true, nu = true,
  xbm = true, xpm = true,
  coq = true, agda = true, am = true, ml = true, mli = true, vb = true,
  bas = true, tal = true,
}

-- Filenames (lowercased, no extension) that are also text.
--:: is_text_name = { [string]: boolean }
local is_text_name = {
  license = true, readme = true, makefile = true,
}

-- Line-comment prefix patterns per extension.
--:: cp = { [string]: string }
local cp = {
  c = "//", cs = "//", cpp = "//", cc = "//", h = "//", hpp = "//", hh = "//",
  hxx = "//", ixx = "//", java = "//",
  js = "//", jsx = "//", cjs = "//", mjs = "//", ts = "//", tsx = "//",
  cts = "//", mts = "//", svelte = "//", vue = "//",
  dfy = "//", jakt = "//", owen = "//", jai = "//", cone = "//", qml = "//",
  hx = "//", kt = "//", d = "//",
  fs = "//", fsi = "//", fsx = "//", fsscript = "//", re = "//", res = "//",
  php = "//",
  f = "^[cC*dD!]", ["for"] = "^[cC*dD!]", ftn = "^[cC*dD!]", i = "^[cC*dD!]",
  fpp = "^[cC*dD!]",
  f90 = "!", i90 = "!", f95 = "!", f03 = "!",
  cbl = "^......%*", ccp = "^......%*", cob = "^......%*", cpy = "^......%*",
  lua = "%-%-", hs = "%-%-", e = "%-%-", sql = "%-%-",
  py = "#", rb = "#", pl = "#",
  lisp = ";", lsp = ";", s = ";", clj = ";", cljs = ";", cljc = ";",
  rkt = ";", el = ";",
  tex = "%%", sty = "%%",
  yml = "#", yaml = "#", toml = "#", ini = "[;#]", json = "//", jsonc = "//",
  edn = ";", hxml = "#",
  editorconfig = "[;#]",
  sh = "#", fish = "#", zsh = "#", ps = "#", nu = "#",
  agda = "%-%-", am = "#", vb = "'", bas = "REM",
}

-- Block-comment start patterns.
--:: csp = { [string]: string }
local csp = {
  c = "/%*", cs = "/%*", csx = "/%*", cpp = "/%*", cc = "/%*", h = "/%*",
  hpp = "/%*", hh = "/%*", hxx = "/%*", ixx = "/%*", java = "/%*",
  js = "/%*", jsx = "/%*", cjs = "/%*", mjs = "/%*", ts = "/%*", tsx = "/%*",
  cts = "/%*", mts = "/%*", svelte = "/%*", vue = "/%*",
  dfy = "/%*", jai = "/%*", cone = "/%*", qml = "/%*", hx = "/%*", kt = "/%*",
  d = "/[*+]",
  fs = "%(%*", fsi = "%(%*", fsx = "%(%*", fsscript = "%(%*", re = "/%*",
  res = "/%*", php = "/%*",
  lua = "%-%-%[=*%[", hs = "{%-", sql = "/%*",
  pl = "^=",
  lsp = ";|",
  html = "<!%-%-", xhtml = "<!%-%-", svg = "<!%-%-", css = "/%*",
  md = "<!%-%-", tex = "\\begin{comment}",
  xml = "<!%-%-", xaml = "<!%-%-", json = "/%*", jsonc = "/%*",
  hxproj = "<!%-%-", csproj = "<!%-%-",
  editorconfig = "[;#]",
  ps = "<#",
  coq = "%(%*", agda = "{%-", ml = "%(%*", mli = "%(%*", tal = "%( ",
}

-- Block-comment end patterns.
--:: cep = { [string]: string }
local cep = {
  c = "%*/", cs = "%*/", csx = "%*/", cpp = "%*/", cc = "%*/", h = "%*/",
  hpp = "%*/", hh = "%*/", hxx = "%*/", ixx = "%*/", java = "%*/",
  js = "%*/", jsx = "%*/", cjs = "%*/", mjs = "%*/", ts = "%*/", tsx = "%*/",
  cts = "%*/", mts = "%*/", svelte = "%*/", vue = "/%*",
  dfy = "%*/", jai = "%*/", cone = "%*/", qml = "%*/", hx = "%*/", kt = "%*/",
  d = "[*+]/",
  fs = "%*%)", fsi = "%*%)", fsx = "%*%)", fsscript = "%*%)", re = "%*/",
  res = "%*/", php = "%*/",
  lua = "%]=*%]", hs = "%-}", sql = "%*/",
  pl = "^=cut$",
  lsp = "|;",
  html = "%-%->", xhtml = "%-%->", svg = "%-%->", css = "%*/",
  md = "%-%->", tex = "\\end{comment}",
  xml = "%-%->", xaml = "%-%->", json = "%*/", jsonc = "%*/",
  hxproj = "%-%->", csproj = "%-%->", editorconfig = "[;#]",
  ps = "#>",
  coq = "%*%)", agda = "%-}", ml = "%*%)", mli = "%*%)", tal = " %)",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Detect the language extension for a file path.
--: (string) -> string
local function detect_ext(path)
  local ext = (path:match("%.([^./]+)$") or ""):lower()
  if is_text_ext[ext] then return ext end
  local name = (path:match("%/([^./]+)$") or ""):lower()
  if is_text_name[name] then return name end
  return ""
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--:: cloc_counts = { code: number, comment: number, blank: number }

-- Count lines in one file given its text content and detected extension.
-- Returns nil if the extension is not a recognised text type or if the content
-- appears binary (non-ASCII bytes in the first line).
--: (string, string) -> { code: number, comment: number, blank: number } | nil
M.count_string = function(content, ext)
  if not is_text_ext[ext] and not is_text_name[ext] then return nil end
  if #content == 0 then
    return { code = 0.0, comment = 0.0, blank = 0.0 }
  end

  local ncode    = 0.0
  local ncomment = 0.0
  local nblank   = 0.0
  local csp_ = csp[ext]
  local cep_ = cep[ext]
  local cp_ = cp[ext]
  local first = true

  -- Split into lines (simple approach, handles CR+LF)
  local lines = {} --: { [integer]: string }
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line:gsub("\r$", "")
  end
  -- Remove trailing empty line added by the sentinel "\n" if content ends with "\n"
  -- Skip the trailing empty sentinel line if content ends with \n
  local has_trailing_newline = content:sub(-1) == "\n"
  local nlines_raw = #lines

  local i = 1
  while i <= nlines_raw do
    if i == nlines_raw and has_trailing_newline and lines[nlines_raw] == "" then break end
    local line = lines[i] --: string
    if first then
      first = false
      if #line >= 3 and not line:find("^[%z\x01-\x7f][%z\x01-\x7f][%z\x01-\x7f]") then
        return nil
      end
    end
    if line:find("^%s*$") then
      nblank = nblank + 1
    elseif csp_ and line:find(csp_) then
      ncomment = ncomment + 1
      while not line:find(cep_) do
        i = i + 1
        if i > nlines_raw then break end
        line = lines[i] --: string
        ncomment = ncomment + 1
      end
    elseif cp_ and line:find(cp_) then
      ncomment = ncomment + 1
    else
      ncode = ncode + 1
    end
    i = i + 1
  end
  return { code = ncode, comment = ncomment, blank = nblank }
end

-- Count lines for a single file.  read_fn receives the path and returns the
-- file contents as a string, or nil on failure.
--: (string, (string) -> string | nil) -> { code: number, comment: number, blank: number } | nil
M.count_file = function(path, read_fn)
  local ext = detect_ext(path)
  if ext == "" then return nil end
  local content = read_fn(path)
  if not content then return nil end
  return M.count_string(content, ext)
end

-- Walk a directory tree and aggregate counts per extension.
-- walk_fn(path) must yield (is_dir: boolean, name: string, full_path: string)
-- triples (or iterate pairs in any fashion the caller chooses).
-- The canonical signature matches lib.fs.dir_list semantics:
--   walk_fn(path) -> (iter, state) where iter yields file_info values with
--   { name, path, is_dir } fields.
--: (string, (string) -> string | nil, (string) -> (((unknown) -> { name: string, path: string, is_dir: boolean } | nil), unknown)) -> { [string]: { code: number, comment: number, blank: number } }
M.count_dir = function(path, read_fn, walk_fn)
  --:: result_map = { [string]: { code: number, comment: number, blank: number } }
  local result = {} --[[:! result_map]]
  local ignore = { [".git"] = true, node_modules = true }

  local function recurse(dir)
    local iter, state = walk_fn(dir)
    if not iter then return end
    for entry in iter, state do
      if entry.is_dir then
        if not ignore[entry.name] then recurse(entry.path) end
      else
        local ext = detect_ext(entry.path)
        if ext ~= "" then
          local content = read_fn(entry.path)
          if content then
            local counts = M.count_string(content, ext)
            if counts then
              local agg = result[ext]
              if not agg then
                agg = { code = 0.0, comment = 0.0, blank = 0.0 }
                result[ext] = agg
              end
              agg.code    = agg.code    + counts.code
              agg.comment = agg.comment + counts.comment
              agg.blank   = agg.blank   + counts.blank
            end
          end
        end
      end
    end
  end

  recurse(path)
  return result
end

return M
