if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local tok = require("lib.tokenizer")

-- ---------------------------------------------------------------------------
-- Shared test lexer
-- ---------------------------------------------------------------------------

local function make_basic_lexer()
  return tok.new()
    :skip("%s+")
    :token("NUMBER",  "%d+%.?%d*")
    :token("IDENT",   "[%a_][%w_]*")
    :token("EQ",      "==")
    :token("ASSIGN",  "=")
    :token("OP",      "[%+%-%*/%%%(%%)%[%]%{%}%,%;%:]")
end

-- ---------------------------------------------------------------------------

T.describe("tokenizer", function()

  T.it("basic tokens: NUMBER, IDENT, OP", function()
    local lexer = make_basic_lexer()
    local tokens, err = lexer:tokenize("x + 42")
    T.ok(tokens, "should not error")
    T.eq(#tokens, 3)
    T.eq(tokens[1].type,  "IDENT")
    T.eq(tokens[1].value, "x")
    T.eq(tokens[2].type,  "OP")
    T.eq(tokens[2].value, "+")
    T.eq(tokens[3].type,  "NUMBER")
    T.eq(tokens[3].value, "42")
  end)

  T.it("skip whitespace: not in token list", function()
    local lexer = make_basic_lexer()
    local tokens, err = lexer:tokenize("  x   42  ")
    T.ok(tokens, "should not error")
    T.eq(#tokens, 2)
    T.eq(tokens[1].type, "IDENT")
    T.eq(tokens[2].type, "NUMBER")
  end)

  T.it("keywords: 'if' classified as keyword, not IDENT", function()
    local lexer = make_basic_lexer():keyword("if", "then", "else", "end")
    local tokens, err = lexer:tokenize("if x then")
    T.ok(tokens, "should not error")
    T.eq(#tokens, 3)
    T.eq(tokens[1].type, "if")
    T.eq(tokens[2].type, "IDENT")
    T.eq(tokens[2].value, "x")
    T.eq(tokens[3].type, "then")
  end)

  T.it("multi-line: line numbers correct on second line", function()
    local lexer = make_basic_lexer()
    local tokens, err = lexer:tokenize("x = 1\ny = 2")
    T.ok(tokens, "should not error")
    -- tokens: x(1,1) =(1,3) 1(1,5) y(2,1) =(2,3) 2(2,5)
    T.eq(#tokens, 6)
    T.eq(tokens[1].line, 1)
    T.eq(tokens[4].line, 2)
    T.eq(tokens[4].value, "y")
  end)

  T.it("column tracking: col correct after multi-char tokens", function()
    local lexer = make_basic_lexer()
    local tokens, err = lexer:tokenize("foo + bar")
    T.ok(tokens, "should not error")
    T.eq(tokens[1].col, 1)   -- "foo" starts at col 1
    T.eq(tokens[2].col, 5)   -- "+" starts at col 5
    T.eq(tokens[3].col, 7)   -- "bar" starts at col 7
  end)

  T.it("transform function: NUMBER value is tonumber()", function()
    local lexer = tok.new()
      :skip("%s+")
      :token("NUMBER", "%d+%.?%d*", function(v) return tonumber(v) end)
      :token("IDENT",  "[%a_][%w_]*")
    local tokens, err = lexer:tokenize("x 42 3.14")
    T.ok(tokens, "should not error")
    T.eq(#tokens, 3)
    T.eq(tokens[2].value, 42)
    T.eq(tokens[3].value, 3.14)
  end)

  T.it("pattern priority: '==' before '=' wins", function()
    local lexer = make_basic_lexer()
    local tokens, err = lexer:tokenize("x == y")
    T.ok(tokens, "should not error")
    T.eq(#tokens, 3)
    T.eq(tokens[2].type,  "EQ")
    T.eq(tokens[2].value, "==")
  end)

  T.it("error: unexpected character returns (nil, err) with position", function()
    local lexer = make_basic_lexer()
    local tokens, err = lexer:tokenize("x @ y")
    T.fail(tokens, "should be nil on error")
    T.ok(err, "should return error table")
    T.ok(err.message:find("@"), "message should mention '@'")
    T.eq(err.line, 1)
    T.eq(err.col,  3)
  end)

  T.it("iterator form: same tokens as array form", function()
    local lexer = make_basic_lexer()
    local array, _  = lexer:tokenize("x + 42")
    local iter_list = {}
    for t in lexer:iter("x + 42") do
      iter_list[#iter_list + 1] = t
    end
    T.eq(#iter_list, #array)
    for i = 1, #array do
      T.eq(iter_list[i].type,  array[i].type)
      T.eq(iter_list[i].value, array[i].value)
      T.eq(iter_list[i].line,  array[i].line)
      T.eq(iter_list[i].col,   array[i].col)
    end
  end)

  T.it("string with quotes: transform strips quotes", function()
    local lexer = tok.new()
      :skip("%s+")
      :token("STRING", '"([^"]*)"', function(v)
        -- v is the full match including quotes; extract the inner capture
        return v:match('^"(.*)"$')
      end)
      :token("IDENT", "[%a_][%w_]*")
    local tokens, err = lexer:tokenize('"hello" x')
    T.ok(tokens, "should not error")
    T.eq(#tokens, 2)
    T.eq(tokens[1].type,  "STRING")
    T.eq(tokens[1].value, "hello")
  end)

  T.it("empty input: empty array", function()
    local lexer = make_basic_lexer()
    local tokens, err = lexer:tokenize("")
    T.ok(tokens, "should not error")
    T.eq(#tokens, 0)
  end)

  T.it("complex expression: x*2 + y/3", function()
    local lexer = make_basic_lexer()
    local tokens, err = lexer:tokenize("x*2 + y/3")
    T.ok(tokens, "should not error")
    -- x * 2 + y / 3
    T.eq(#tokens, 7)
    T.eq(tokens[1].type,  "IDENT")
    T.eq(tokens[1].value, "x")
    T.eq(tokens[2].type,  "OP")
    T.eq(tokens[2].value, "*")
    T.eq(tokens[3].type,  "NUMBER")
    T.eq(tokens[3].value, "2")
    T.eq(tokens[4].type,  "OP")
    T.eq(tokens[4].value, "+")
    T.eq(tokens[5].type,  "IDENT")
    T.eq(tokens[5].value, "y")
    T.eq(tokens[6].type,  "OP")
    T.eq(tokens[6].value, "/")
    T.eq(tokens[7].type,  "NUMBER")
    T.eq(tokens[7].value, "3")
  end)

  T.it("_tier is 'pure'", function()
    T.eq(tok._tier, "pure")
  end)

end)
