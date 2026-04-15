if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local dotenv = require("lib.dotenv")
local T = require("lib.test.assert")

-- ---------------------------------------------------------------------------
-- parse
-- ---------------------------------------------------------------------------

T.describe("parse", function()

  T.it("basic KEY=VALUE", function()
    local vars = dotenv.parse("APP_NAME=MyApp\nPORT=3000\n")
    T.eq(vars.APP_NAME, "MyApp")
    T.eq(vars.PORT, "3000")
  end)

  T.it("double-quoted value with spaces", function()
    local vars = dotenv.parse('SECRET_KEY="my secret key with spaces"\n')
    T.eq(vars.SECRET_KEY, "my secret key with spaces")
  end)

  T.it("single-quoted value (no escapes)", function()
    local vars = dotenv.parse("QUOTED='single quoted'\n")
    T.eq(vars.QUOTED, "single quoted")
  end)

  T.it("single-quoted value: backslash is literal", function()
    local vars = dotenv.parse("RAW='no\\nescapes'\n")
    T.eq(vars.RAW, "no\\nescapes")
  end)

  T.it("empty value KEY= gives empty string", function()
    local vars = dotenv.parse("EMPTY=\n")
    T.eq(vars.EMPTY, "")
  end)

  T.it("comment lines are ignored", function()
    local vars = dotenv.parse("# this is a comment\nFOO=bar\n")
    T.eq(vars["# this is a comment"], nil)
    T.eq(vars.FOO, "bar")
  end)

  T.it("inline comment after space ends unquoted value", function()
    local vars = dotenv.parse("HASH_VAL=value #comment\n")
    T.eq(vars.HASH_VAL, "value")
  end)

  T.it("hash without preceding space is part of value", function()
    local vars = dotenv.parse("HASH_IN_VAL=value#notacomment\n")
    T.eq(vars.HASH_IN_VAL, "value#notacomment")
  end)

  T.it("export prefix is stripped", function()
    local vars = dotenv.parse("export EXPORT_VAR=exported\n")
    T.eq(vars.EXPORT_VAR, "exported")
    T.eq(vars["export EXPORT_VAR"], nil)
  end)

  T.it("escape sequences in double-quoted values", function()
    local vars = dotenv.parse('MULTILINE="line1\\nline2\\nline3"\n')
    T.eq(vars.MULTILINE, "line1\nline2\nline3")
  end)

  T.it("\\t escape in double-quoted values", function()
    local vars = dotenv.parse('TABBED="col1\\tcol2"\n')
    T.eq(vars.TABBED, "col1\tcol2")
  end)

  T.it("\\\\ escape gives single backslash", function()
    local vars = dotenv.parse('BS="back\\\\slash"\n')
    T.eq(vars.BS, "back\\slash")
  end)

  T.it('\\" escape gives double quote', function()
    local vars = dotenv.parse('QT="say \\"hi\\""\n')
    T.eq(vars.QT, 'say "hi"')
  end)

  T.it("variable expansion ${VAR} in bare value", function()
    local vars = dotenv.parse("BASE_URL=https://example.com\nAPI_URL=${BASE_URL}/api\n")
    T.eq(vars.API_URL, "https://example.com/api")
  end)

  T.it("variable expansion $VAR in bare value", function()
    local vars = dotenv.parse("APP=myapp\nGREET=Hello $APP!\n")
    T.eq(vars.GREET, "Hello myapp!")
  end)

  T.it("variable expansion ${VAR} in double-quoted value", function()
    local vars = dotenv.parse('BASE=foo\nDQ="${BASE}bar"\n')
    T.eq(vars.DQ, "foobar")
  end)

  T.it("undefined variable expansion gives empty string", function()
    local vars = dotenv.parse("MISSING=${SURELY_NOT_SET_CRESCENT_TEST_XYZ}\n")
    T.eq(vars.MISSING, "")
  end)

  T.it("multiple assignments: last wins", function()
    local vars = dotenv.parse("FOO=first\nFOO=second\n")
    T.eq(vars.FOO, "second")
  end)

  T.it("KEY without = is boolean presence (value = 'true')", function()
    local vars = dotenv.parse("PRESENT\n")
    T.eq(vars.PRESENT, "true")
  end)

  T.it("returns nil + error for non-string input", function()
    local vars, err = dotenv.parse(42)
    T.eq(vars, nil)
    T.ok(err ~= nil, "error message expected")
  end)

end)

-- ---------------------------------------------------------------------------
-- stringify
-- ---------------------------------------------------------------------------

T.describe("stringify", function()

  T.it("simple vars round-trip", function()
    local orig = { APP_NAME = "MyApp", PORT = "3000" }
    local content = dotenv.stringify(orig)
    local parsed = dotenv.parse(content)
    T.eq(parsed.APP_NAME, "MyApp")
    T.eq(parsed.PORT, "3000")
  end)

  T.it("values with spaces get double-quoted", function()
    local content = dotenv.stringify({ SECRET = "has spaces" })
    T.ok(content:find('"has spaces"'), "value should be quoted")
  end)

  T.it("empty value is double-quoted", function()
    local content = dotenv.stringify({ EMPTY = "" })
    T.ok(content:find('EMPTY=""'), "empty value should be quoted")
  end)

  T.it("newlines in value are escaped", function()
    local content = dotenv.stringify({ ML = "a\nb" })
    T.ok(content:find("\\n"), "newline should be escaped")
    -- round-trip
    local parsed = dotenv.parse(content)
    T.eq(parsed.ML, "a\nb")
  end)

end)

-- ---------------------------------------------------------------------------
-- load_into
-- ---------------------------------------------------------------------------

T.describe("load_into", function()
  local function read_fn(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
  end

  T.it("merges into existing table", function()
    -- Write a temp file
    local path = "/tmp/crescent_dotenv_test_loadinto.env"
    local f = io.open(path, "w")
    f:write("NEW_KEY=newval\n")
    f:close()

    local t = { EXISTING = "kept" }
    local result = dotenv.load_into(t, read_fn, path)
    T.eq(result.EXISTING, "kept")
    T.eq(result.NEW_KEY, "newval")
    os.remove(path)
  end)

  T.it("returns nil + error for missing file", function()
    local result, err = dotenv.load_into({}, read_fn, "/tmp/crescent_dotenv_test_DOESNOTEXIST.env")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
-- load_files
-- ---------------------------------------------------------------------------

T.describe("load_files", function()
  local function read_fn(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
  end

  local function write_tmp(path, content)
    local f = io.open(path, "w")
    f:write(content)
    f:close()
  end

  T.it("later file overrides earlier", function()
    local p1 = "/tmp/crescent_dotenv_test_f1.env"
    local p2 = "/tmp/crescent_dotenv_test_f2.env"
    write_tmp(p1, "FOO=first\nBAR=from1\n")
    write_tmp(p2, "FOO=second\n")
    local vars = dotenv.load_files(read_fn, { p1, p2 })
    T.eq(vars.FOO, "second")
    T.eq(vars.BAR, "from1")
    os.remove(p1)
    os.remove(p2)
  end)

  T.it("existing=true: first value wins", function()
    local p1 = "/tmp/crescent_dotenv_test_e1.env"
    local p2 = "/tmp/crescent_dotenv_test_e2.env"
    write_tmp(p1, "FOO=first\n")
    write_tmp(p2, "FOO=second\nBAR=only_in_second\n")
    local vars = dotenv.load_files(read_fn, { p1, p2 }, { existing = true })
    T.eq(vars.FOO, "first")
    T.eq(vars.BAR, "only_in_second")
    os.remove(p1)
    os.remove(p2)
  end)

end)

-- ---------------------------------------------------------------------------
-- resolver
-- ---------------------------------------------------------------------------

T.describe("resolver", function()

  T.it("returns value from vars table", function()
    local get = dotenv.resolver({ PORT = "4000" }, os.getenv)
    T.eq(get("PORT"), "4000")
  end)

  T.it("falls back to env_fn for unknown key", function()
    -- PATH is almost universally set
    local get = dotenv.resolver({}, os.getenv)
    T.eq(get("PATH"), os.getenv("PATH"))
  end)

  T.it("vars take precedence over env_fn", function()
    local get = dotenv.resolver({ PATH = "overridden" }, os.getenv)
    T.eq(get("PATH"), "overridden")
  end)

end)
