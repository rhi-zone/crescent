if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local ini = require("lib.ini")
local T = require("lib.test.assert")

-- ── Basic parsing ──────────────────────────────────────────────────────────────

T.describe("ini.decode", function()

  T.it("parses a basic section with key-value pairs", function()
    local t = ini.decode("[section]\nkey = value\n")
    T.eq(t.section.key, "value")
  end)

  T.it("parses multiple sections", function()
    local t = ini.decode("[a]\nx = 1\n[b]\ny = 2\n")
    T.eq(t.a.x, "1")
    T.eq(t.b.y, "2")
  end)

  T.it("parses global keys (no section header)", function()
    local t = ini.decode("key = value\n")
    T.eq(t[""].key, "value")
  end)

  T.it("parses global keys followed by sections", function()
    local t = ini.decode("global = yes\n[sec]\nlocal = no\n")
    T.eq(t[""].global, "yes")
    T.eq(t.sec["local"], "no")
  end)

  T.it("handles empty input", function()
    local t = ini.decode("")
    T.eq(t[""], nil)
  end)

  T.it("handles whitespace-only input", function()
    local t = ini.decode("   \n  \n  \n")
    T.eq(t[""], nil)
  end)

  T.it("returns nil and error for non-string input", function()
    local val, err = ini.decode(42)
    T.eq(val, nil)
    T.ok(err:find("expected string"), "error message mentions expected type")
  end)

  T.it("returns nil and error for nil input", function()
    local val, err = ini.decode(nil)
    T.eq(val, nil)
    T.ok(err:find("expected string"), "error message mentions expected type")
  end)

end)

-- ── Comments ───────────────────────────────────────────────────────────────────

T.describe("ini.decode comments", function()

  T.it("ignores semicolon comments", function()
    local t = ini.decode("; this is a comment\n[sec]\nkey = val\n")
    T.eq(t.sec.key, "val")
  end)

  T.it("ignores hash comments", function()
    local t = ini.decode("# this is a comment\n[sec]\nkey = val\n")
    T.eq(t.sec.key, "val")
  end)

  T.it("strips inline semicolon comments", function()
    local t = ini.decode("[sec]\nkey = val ; comment\n")
    T.eq(t.sec.key, "val")
  end)

  T.it("strips inline hash comments", function()
    local t = ini.decode("[sec]\nkey = val # comment\n")
    T.eq(t.sec.key, "val")
  end)

  T.it("preserves comment chars inside double quotes", function()
    local t = ini.decode('[sec]\nkey = "val ; not a comment"\n')
    T.eq(t.sec.key, "val ; not a comment")
  end)

  T.it("preserves comment chars inside single quotes", function()
    local t = ini.decode("[sec]\nkey = 'val # not a comment'\n")
    T.eq(t.sec.key, "val # not a comment")
  end)

  T.it("handles comment-only lines mixed with data", function()
    local t = ini.decode("[s]\n; c1\nk1 = v1\n# c2\nk2 = v2\n")
    T.eq(t.s.k1, "v1")
    T.eq(t.s.k2, "v2")
  end)

end)

-- ── Whitespace handling ────────────────────────────────────────────────────────

T.describe("ini.decode whitespace", function()

  T.it("trims whitespace around keys", function()
    local t = ini.decode("[s]\n  key  = val\n")
    T.eq(t.s.key, "val")
  end)

  T.it("trims whitespace around values", function()
    local t = ini.decode("[s]\nkey =   val   \n")
    T.eq(t.s.key, "val")
  end)

  T.it("trims whitespace around section names", function()
    local t = ini.decode("[  section  ]\nkey = val\n")
    T.eq(t.section.key, "val")
  end)

  T.it("skips blank lines", function()
    local t = ini.decode("[s]\n\nkey = val\n\n")
    T.eq(t.s.key, "val")
  end)

  T.it("handles CRLF line endings", function()
    local t = ini.decode("[s]\r\nkey = val\r\n")
    T.eq(t.s.key, "val")
  end)

  T.it("handles no trailing newline", function()
    local t = ini.decode("[s]\nkey = val")
    T.eq(t.s.key, "val")
  end)

end)

-- ── Quoted values ──────────────────────────────────────────────────────────────

T.describe("ini.decode quoted values", function()

  T.it("strips double quotes from values", function()
    local t = ini.decode('[s]\nkey = "hello world"\n')
    T.eq(t.s.key, "hello world")
  end)

  T.it("strips single quotes from values", function()
    local t = ini.decode("[s]\nkey = 'hello world'\n")
    T.eq(t.s.key, "hello world")
  end)

  T.it("preserves interior quotes", function()
    local t = ini.decode('[s]\nkey = "it\'s fine"\n')
    T.eq(t.s.key, "it's fine")
  end)

  T.it("preserves value with only one quote", function()
    local t = ini.decode('[s]\nkey = "unmatched\n')
    T.eq(t.s.key, '"unmatched')
  end)

  T.it("preserves empty quoted value", function()
    local t = ini.decode('[s]\nkey = ""\n')
    T.eq(t.s.key, "")
  end)

end)

-- ── Empty values ───────────────────────────────────────────────────────────────

T.describe("ini.decode empty values", function()

  T.it("parses key with no value as empty string", function()
    local t = ini.decode("[s]\nkey =\n")
    T.eq(t.s.key, "")
  end)

  T.it("parses key with only whitespace value as empty string", function()
    local t = ini.decode("[s]\nkey =   \n")
    T.eq(t.s.key, "")
  end)

end)

-- ── Duplicate keys ─────────────────────────────────────────────────────────────

T.describe("ini.decode duplicate keys", function()

  T.it("last value wins for duplicate keys", function()
    local t = ini.decode("[s]\nkey = first\nkey = second\n")
    T.eq(t.s.key, "second")
  end)

  T.it("duplicate keys in different sections are independent", function()
    local t = ini.decode("[a]\nkey = alpha\n[b]\nkey = beta\n")
    T.eq(t.a.key, "alpha")
    T.eq(t.b.key, "beta")
  end)

end)

-- ── Section edge cases ─────────────────────────────────────────────────────────

T.describe("ini.decode section edge cases", function()

  T.it("handles section with no keys", function()
    local t = ini.decode("[empty]\n[full]\nkey = val\n")
    T.eq(next(t.empty), nil)
    T.eq(t.full.key, "val")
  end)

  T.it("handles section-only input", function()
    local t = ini.decode("[section]\n")
    T.eq(next(t.section), nil)
  end)

  T.it("handles reopening the same section", function()
    local t = ini.decode("[s]\na = 1\n[s]\nb = 2\n")
    T.eq(t.s.a, "1")
    T.eq(t.s.b, "2")
  end)

  T.it("handles section names with dots", function()
    local t = ini.decode("[a.b.c]\nkey = val\n")
    T.eq(t["a.b.c"].key, "val")
  end)

  T.it("handles section names with spaces", function()
    local t = ini.decode("[my section]\nkey = val\n")
    T.eq(t["my section"].key, "val")
  end)

end)

-- ── Options ────────────────────────────────────────────────────────────────────

T.describe("ini.decode options", function()

  T.it("respects custom comment char", function()
    local t = ini.decode("// comment\n[s]\nkey = val\n", { comment = "/" })
    T.eq(t.s.key, "val")
  end)

  T.it("custom comment char does not strip default comment chars", function()
    local t = ini.decode("[s]\nkey = val ; not stripped\n", { comment = "/" })
    T.eq(t.s.key, "val ; not stripped")
  end)

  T.it("respects custom delimiter", function()
    local t = ini.decode("[s]\nkey: val\n", { delimiter = ":" })
    T.eq(t.s.key, "val")
  end)

  T.it("respects lowercase option for keys", function()
    local t = ini.decode("[s]\nMyKey = val\n", { lowercase = true })
    T.eq(t.s.mykey, "val")
  end)

  T.it("respects lowercase option for sections", function()
    local t = ini.decode("[MySection]\nkey = val\n", { lowercase = true })
    T.eq(t.mysection.key, "val")
  end)

end)

-- ── Multiline via backslash continuation ───────────────────────────────────────

T.describe("ini.decode multiline", function()

  T.it("joins backslash-continued lines", function()
    local t = ini.decode("[s]\nkey = hello \\\nworld\n")
    T.eq(t.s.key, "hello world")
  end)

  T.it("joins multiple continued lines", function()
    local t = ini.decode("[s]\nkey = a \\\nb \\\nc\n")
    T.eq(t.s.key, "a b c")
  end)

end)

-- ── Delimiter edge cases ───────────────────────────────────────────────────────

T.describe("ini.decode delimiter edge cases", function()

  T.it("handles value containing delimiter char", function()
    local t = ini.decode("[s]\nkey = a=b=c\n")
    T.eq(t.s.key, "a=b=c")
  end)

  T.it("ignores lines without delimiter", function()
    local t = ini.decode("[s]\nnot a pair\nkey = val\n")
    T.eq(t.s.key, "val")
    -- "not a pair" has no = so it's silently skipped
  end)

end)

-- ── Encoding ───────────────────────────────────────────────────────────────────

T.describe("ini.encode", function()

  T.it("encodes a single section", function()
    local s = ini.encode({ sec = { key = "val" } })
    T.ok(s:find("[sec]", 1, true), "contains section header")
    T.ok(s:find("key = val", 1, true), "contains key-value")
  end)

  T.it("encodes global keys under empty string section", function()
    local s = ini.encode({ [""] = { key = "val" } })
    T.ok(not s:find("[", 1, true) or s:find("key = val") < (s:find("[", 1, true) or math.huge),
      "global keys appear before any section")
  end)

  T.it("encodes multiple sections", function()
    local s = ini.encode({ a = { x = "1" }, b = { y = "2" } })
    T.ok(s:find("[a]", 1, true), "contains [a]")
    T.ok(s:find("[b]", 1, true), "contains [b]")
    T.ok(s:find("x = 1", 1, true), "contains x = 1")
    T.ok(s:find("y = 2", 1, true), "contains y = 2")
  end)

  T.it("returns nil and error for non-table input", function()
    local val, err = ini.encode("not a table")
    T.eq(val, nil)
    T.ok(err:find("expected table"), "error mentions expected type")
  end)

  T.it("returns nil and error for non-table section value", function()
    local val, err = ini.encode({ sec = "not a table" })
    T.eq(val, nil)
    T.ok(err:find("must be a table"), "error mentions table requirement")
  end)

  T.it("produces deterministic output (sorted sections and keys)", function()
    local t = { z = { b = "2", a = "1" }, a = { d = "4", c = "3" } }
    local s1 = ini.encode(t)
    local s2 = ini.encode(t)
    T.eq(s1, s2, "two encodes produce identical output")
    -- a section should come before z section
    T.ok(s1:find("[a]", 1, true) < s1:find("[z]", 1, true), "sections sorted")
  end)

  T.it("respects custom delimiter", function()
    local s = ini.encode({ sec = { key = "val" } }, { delimiter = ": " })
    T.ok(s:find("key: val", 1, true), "uses custom delimiter")
  end)

  T.it("encodes empty table as empty string", function()
    local s = ini.encode({})
    T.eq(s, "")
  end)

  T.it("converts non-string values to string", function()
    local s = ini.encode({ sec = { num = 42, flag = true } })
    T.ok(s:find("num = 42", 1, true), "number converted")
    T.ok(s:find("flag = true", 1, true), "boolean converted")
  end)

end)

-- ── Roundtrip ──────────────────────────────────────────────────────────────────

T.describe("ini roundtrip", function()

  T.it("decode then encode preserves data", function()
    local input = "[database]\nhost = localhost\nport = 5432\n\n[app]\nname = myapp\ndebug = false\n"
    local t = ini.decode(input)
    local output = ini.encode(t)
    local t2 = ini.decode(output)
    T.eq(t2.database.host, t.database.host)
    T.eq(t2.database.port, t.database.port)
    T.eq(t2.app.name, t.app.name)
    T.eq(t2.app.debug, t.app.debug)
  end)

  T.it("encode then decode preserves data", function()
    local t = { server = { host = "0.0.0.0", port = "8080" }, log = { level = "info" } }
    local s = ini.encode(t)
    local t2 = ini.decode(s)
    T.eq(t2.server.host, "0.0.0.0")
    T.eq(t2.server.port, "8080")
    T.eq(t2.log.level, "info")
  end)

  T.it("roundtrip with global keys", function()
    local t = { [""] = { version = "1" }, sec = { key = "val" } }
    local s = ini.encode(t)
    local t2 = ini.decode(s)
    T.eq(t2[""].version, "1")
    T.eq(t2.sec.key, "val")
  end)

end)

-- ── Aliases ────────────────────────────────────────────────────────────────────

T.describe("ini aliases", function()

  T.it("string_to_table is the same as decode", function()
    T.eq(ini.string_to_table, ini.decode)
  end)

  T.it("table_to_string is the same as encode", function()
    T.eq(ini.table_to_string, ini.encode)
  end)

  T.it("_tier is pure", function()
    T.eq(ini._tier, "pure")
  end)

end)

-- ── Real-world style INI ───────────────────────────────────────────────────────

T.describe("ini real-world", function()

  T.it("parses a git-config style file", function()
    local input = [[
[core]
  repositoryformatversion = 0
  filemode = true
  bare = false

[remote "origin"]
  url = git@github.com:user/repo.git
  fetch = +refs/heads/*:refs/remotes/origin/*

[branch "main"]
  remote = origin
  merge = refs/heads/main
]]
    local t = ini.decode(input)
    T.eq(t.core.repositoryformatversion, "0")
    T.eq(t.core.filemode, "true")
    T.eq(t['remote "origin"'].url, "git@github.com:user/repo.git")
    T.eq(t['branch "main"'].remote, "origin")
  end)

  T.it("parses a php.ini style file", function()
    local input = [[
; PHP configuration
[PHP]
engine = On
short_open_tag = Off
precision = 14

[Date]
; timezone
date.timezone = UTC
]]
    local t = ini.decode(input)
    T.eq(t.PHP.engine, "On")
    T.eq(t.PHP.precision, "14")
    T.eq(t.Date["date.timezone"], "UTC")
  end)

  T.it("parses a desktop entry style file", function()
    local input = [[
[Desktop Entry]
Name=My Application
Comment=A great app
Exec=/usr/bin/myapp
Type=Application
Categories=Utility;Development;
]]
    local t = ini.decode(input, { delimiter = "=" })
    T.eq(t["Desktop Entry"].Name, "My Application")
    T.eq(t["Desktop Entry"].Type, "Application")
  end)

end)
