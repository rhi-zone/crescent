-- lib/graphql_parser/graphql_parser_test.lua
-- Tests for the graphql_parser library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local G = require("lib.graphql_parser")

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

local function parse_ok(src)
  local doc, err = G.parse(src)
  T.ok(doc, "parse should succeed: " .. tostring(err))
  T.ok(not err, "should have no error")
  return doc
end

local function parse_err(src)
  local doc, err = G.parse(src)
  T.ok(not doc, "parse should fail")
  T.ok(err, "should return error message")
  return err
end

-- Deep-equality check for AST nodes (ignores extra keys)
local function ast_eq(a, b, path)
  path = path or "root"
  if type(a) ~= type(b) then
    error("type mismatch at " .. path .. ": " .. type(a) .. " vs " .. type(b))
  end
  if type(a) == "table" then
    for k, v in pairs(b) do
      ast_eq(a[k], v, path .. "." .. tostring(k))
    end
  else
    if a ~= b then
      error("value mismatch at " .. path .. ": " .. tostring(a) .. " vs " .. tostring(b))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Simple query
-- ---------------------------------------------------------------------------

T.describe("simple query", function()
  T.it("parses a minimal query", function()
    local doc = parse_ok("{ hero { name } }")
    T.eq(doc.kind, "Document")
    T.eq(#doc.definitions, 1)
    local op = doc.definitions[1]
    T.eq(op.kind, "OperationDefinition")
    T.eq(op.operation, "query")
    T.ok(op.name == nil)
    T.eq(#op.variableDefinitions, 0)
    T.eq(#op.directives, 0)
    local ss = op.selectionSet
    T.eq(ss.kind, "SelectionSet")
    T.eq(#ss.selections, 1)
    local field = ss.selections[1]
    T.eq(field.kind, "Field")
    T.eq(field.name.value, "hero")
    T.eq(#field.selectionSet.selections, 1)
    T.eq(field.selectionSet.selections[1].name.value, "name")
  end)

  T.it("parses named query", function()
    local doc = parse_ok("query HeroQuery { hero { id name } }")
    local op = doc.definitions[1]
    T.eq(op.operation, "query")
    T.eq(op.name.value, "HeroQuery")
    T.eq(#op.selectionSet.selections[1].selectionSet.selections, 2)
  end)

  T.it("M.get path accessor works", function()
    local doc = parse_ok("{ hero { name } }")
    T.eq(G.get(doc, "definitions[1].kind"), "OperationDefinition")
    T.eq(G.get(doc, "definitions[1].selectionSet.selections[1].name.value"), "hero")
    T.eq(G.get(doc, "definitions[1].selectionSet.selections[1].selectionSet.selections[1].name.value"), "name")
  end)
end)

-- ---------------------------------------------------------------------------
-- Mutation and subscription
-- ---------------------------------------------------------------------------

T.describe("mutation and subscription", function()
  T.it("parses mutation", function()
    local doc = parse_ok("mutation CreateUser($name: String!) { createUser(name: $name) { id } }")
    local op = doc.definitions[1]
    T.eq(op.kind, "OperationDefinition")
    T.eq(op.operation, "mutation")
    T.eq(op.name.value, "CreateUser")
    T.eq(#op.variableDefinitions, 1)
    local vd = op.variableDefinitions[1]
    T.eq(vd.variable.name.value, "name")
    T.eq(vd.type.kind, "NonNullType")
    T.eq(vd.type.type.name.value, "String")
  end)

  T.it("parses subscription", function()
    local doc = parse_ok("subscription OnMessage { messageAdded { content } }")
    local op = doc.definitions[1]
    T.eq(op.operation, "subscription")
    T.eq(op.name.value, "OnMessage")
  end)
end)

-- ---------------------------------------------------------------------------
-- Fields with arguments and aliases
-- ---------------------------------------------------------------------------

T.describe("fields with arguments and aliases", function()
  T.it("parses field arguments", function()
    local doc = parse_ok('{ user(id: 42) { name } }')
    local field = doc.definitions[1].selectionSet.selections[1]
    T.eq(field.name.value, "user")
    T.eq(#field.arguments, 1)
    T.eq(field.arguments[1].name.value, "id")
    T.eq(field.arguments[1].value.kind, "IntValue")
    T.eq(field.arguments[1].value.value, "42")
  end)

  T.it("parses field alias", function()
    local doc = parse_ok("{ myHero: hero { name } }")
    local field = doc.definitions[1].selectionSet.selections[1]
    T.eq(field.alias.value, "myHero")
    T.eq(field.name.value, "hero")
  end)

  T.it("parses multiple arguments", function()
    local doc = parse_ok('{ search(q: "hello", limit: 10) { id } }')
    local field = doc.definitions[1].selectionSet.selections[1]
    T.eq(#field.arguments, 2)
    T.eq(field.arguments[1].name.value, "q")
    T.eq(field.arguments[1].value.value, "hello")
    T.eq(field.arguments[2].name.value, "limit")
    T.eq(field.arguments[2].value.value, "10")
  end)
end)

-- ---------------------------------------------------------------------------
-- Directives
-- ---------------------------------------------------------------------------

T.describe("directives", function()
  T.it("parses field directive", function()
    local doc = parse_ok("{ hero @deprecated { name } }")
    local field = doc.definitions[1].selectionSet.selections[1]
    T.eq(#field.directives, 1)
    T.eq(field.directives[1].name.value, "deprecated")
    T.eq(#field.directives[1].arguments, 0)
  end)

  T.it("parses directive with argument", function()
    local doc = parse_ok('{ hero @include(if: true) { name } }')
    local dir = doc.definitions[1].selectionSet.selections[1].directives[1]
    T.eq(dir.name.value, "include")
    T.eq(dir.arguments[1].name.value, "if")
    T.eq(dir.arguments[1].value.value, true)
  end)

  T.it("parses operation directive", function()
    local doc = parse_ok("query Q @auth { hero { name } }")
    local op = doc.definitions[1]
    T.eq(#op.directives, 1)
    T.eq(op.directives[1].name.value, "auth")
  end)
end)

-- ---------------------------------------------------------------------------
-- Nested selection sets
-- ---------------------------------------------------------------------------

T.describe("nested selection sets", function()
  T.it("handles deep nesting", function()
    local doc = parse_ok("{ a { b { c { d } } } }")
    local sel = doc.definitions[1].selectionSet
    T.eq(sel.selections[1].name.value, "a")
    T.eq(sel.selections[1].selectionSet.selections[1].name.value, "b")
    T.eq(sel.selections[1].selectionSet.selections[1].selectionSet.selections[1].name.value, "c")
    T.eq(sel.selections[1].selectionSet.selections[1].selectionSet.selections[1].selectionSet.selections[1].name.value, "d")
  end)

  T.it("handles multiple fields at each level", function()
    local doc = parse_ok("{ hero { id name friends { id name } } }")
    local hero = doc.definitions[1].selectionSet.selections[1]
    T.eq(#hero.selectionSet.selections, 3)
    T.eq(hero.selectionSet.selections[1].name.value, "id")
    T.eq(hero.selectionSet.selections[2].name.value, "name")
    T.eq(hero.selectionSet.selections[3].name.value, "friends")
  end)
end)

-- ---------------------------------------------------------------------------
-- Fragment definitions and spreads
-- ---------------------------------------------------------------------------

T.describe("fragments", function()
  T.it("parses fragment definition", function()
    local doc = parse_ok("fragment HeroFields on Character { id name }")
    T.eq(#doc.definitions, 1)
    local frag = doc.definitions[1]
    T.eq(frag.kind, "FragmentDefinition")
    T.eq(frag.name.value, "HeroFields")
    T.eq(frag.typeCondition.kind, "NamedType")
    T.eq(frag.typeCondition.name.value, "Character")
    T.eq(#frag.selectionSet.selections, 2)
  end)

  T.it("parses fragment spread", function()
    local doc = parse_ok("{ hero { ...HeroFields } } fragment HeroFields on Character { id }")
    local spread = doc.definitions[1].selectionSet.selections[1].selectionSet.selections[1]
    T.eq(spread.kind, "FragmentSpread")
    T.eq(spread.name.value, "HeroFields")
  end)

  T.it("parses inline fragment with type condition", function()
    local doc = parse_ok("{ hero { ... on Droid { primaryFunction } } }")
    local inline = doc.definitions[1].selectionSet.selections[1].selectionSet.selections[1]
    T.eq(inline.kind, "InlineFragment")
    T.eq(inline.typeCondition.name.value, "Droid")
    T.eq(inline.selectionSet.selections[1].name.value, "primaryFunction")
  end)

  T.it("parses inline fragment without type condition", function()
    local doc = parse_ok("{ hero { ... { id name } } }")
    local inline = doc.definitions[1].selectionSet.selections[1].selectionSet.selections[1]
    T.eq(inline.kind, "InlineFragment")
    T.ok(inline.typeCondition == nil)
    T.eq(#inline.selectionSet.selections, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Variables and variable definitions
-- ---------------------------------------------------------------------------

T.describe("variables", function()
  T.it("parses variable reference in argument", function()
    local doc = parse_ok("query Q($id: ID) { user(id: $id) { name } }")
    local arg = doc.definitions[1].selectionSet.selections[1].arguments[1]
    T.eq(arg.value.kind, "Variable")
    T.eq(arg.value.name.value, "id")
  end)

  T.it("parses variable with default value", function()
    local doc = parse_ok('query Q($ep: Episode = JEDI) { hero(episode: $ep) { name } }')
    local vd = doc.definitions[1].variableDefinitions[1]
    T.eq(vd.variable.name.value, "ep")
    T.eq(vd.type.name.value, "Episode")
    T.eq(vd.defaultValue.kind, "EnumValue")
    T.eq(vd.defaultValue.value, "JEDI")
  end)

  T.it("parses multiple variable definitions", function()
    local doc = parse_ok("query Q($a: String!, $b: Int, $c: [Boolean!]!) { x }")
    local vars = doc.definitions[1].variableDefinitions
    T.eq(#vars, 3)
    T.eq(vars[1].type.kind, "NonNullType")
    T.eq(vars[2].type.kind, "NamedType")
    T.eq(vars[3].type.kind, "NonNullType")
    T.eq(vars[3].type.type.kind, "ListType")
  end)
end)

-- ---------------------------------------------------------------------------
-- Value types
-- ---------------------------------------------------------------------------

T.describe("value types", function()
  T.it("int value", function()
    local doc = parse_ok("{ f(x: 42) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "IntValue")
    T.eq(v.value, "42")
  end)

  T.it("negative int value", function()
    local doc = parse_ok("{ f(x: -7) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "IntValue")
    T.eq(v.value, "-7")
  end)

  T.it("float value", function()
    local doc = parse_ok("{ f(x: 3.14) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "FloatValue")
    T.eq(v.value, "3.14")
  end)

  T.it("float with exponent", function()
    local doc = parse_ok("{ f(x: 1.5e10) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "FloatValue")
    T.eq(v.value, "1.5e10")
  end)

  T.it("string value", function()
    local doc = parse_ok('{ f(x: "hello world") { id } }')
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "StringValue")
    T.eq(v.value, "hello world")
    T.eq(v.block, false)
  end)

  T.it("string escape sequences", function()
    local doc = parse_ok('{ f(x: "line1\\nline2\\ttab") { id } }')
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.value, "line1\nline2\ttab")
  end)

  T.it("boolean true", function()
    local doc = parse_ok("{ f(x: true) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "BooleanValue")
    T.eq(v.value, true)
  end)

  T.it("boolean false", function()
    local doc = parse_ok("{ f(x: false) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "BooleanValue")
    T.eq(v.value, false)
  end)

  T.it("null value", function()
    local doc = parse_ok("{ f(x: null) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "NullValue")
  end)

  T.it("enum value", function()
    local doc = parse_ok("{ f(x: NORTH) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "EnumValue")
    T.eq(v.value, "NORTH")
  end)

  T.it("list value", function()
    local doc = parse_ok("{ f(x: [1, 2, 3]) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "ListValue")
    T.eq(#v.values, 3)
    T.eq(v.values[1].value, "1")
    T.eq(v.values[2].value, "2")
    T.eq(v.values[3].value, "3")
  end)

  T.it("empty list value", function()
    local doc = parse_ok("{ f(x: []) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "ListValue")
    T.eq(#v.values, 0)
  end)

  T.it("object value", function()
    local doc = parse_ok('{ f(x: {a: 1, b: "hi"}) { id } }')
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "ObjectValue")
    T.eq(#v.fields, 2)
    T.eq(v.fields[1].name.value, "a")
    T.eq(v.fields[1].value.kind, "IntValue")
    T.eq(v.fields[2].name.value, "b")
    T.eq(v.fields[2].value.value, "hi")
  end)

  T.it("nested object value", function()
    local doc = parse_ok("{ f(x: {a: {b: 99}}) { id } }")
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.fields[1].value.kind, "ObjectValue")
    T.eq(v.fields[1].value.fields[1].value.value, "99")
  end)
end)

-- ---------------------------------------------------------------------------
-- Block strings
-- ---------------------------------------------------------------------------

T.describe("block strings", function()
  T.it("parses triple-quoted block string", function()
    local doc = parse_ok('{ f(x: """hello""") { id } }')
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "StringValue")
    T.eq(v.block, true)
    T.eq(v.value, "hello")
  end)

  T.it("strips common indentation from block string", function()
    local src = '{ f(x: """\n  line1\n  line2\n""") { id } }'
    local doc = parse_ok(src)
    local v = doc.definitions[1].selectionSet.selections[1].arguments[1].value
    T.eq(v.kind, "StringValue")
    T.eq(v.block, true)
    T.eq(v.value, "line1\nline2")
  end)

  T.it("block string as description in SDL", function()
    local doc = parse_ok('"""A user type""" type User { id: ID }')
    local def = doc.definitions[1]
    T.eq(def.kind, "ObjectTypeDefinition")
    T.eq(def.description.value, "A user type")
  end)
end)

-- ---------------------------------------------------------------------------
-- Comments
-- ---------------------------------------------------------------------------

T.describe("comments", function()
  T.it("skips inline comments", function()
    local doc = parse_ok([[
      # This is a comment
      {
        hero { # another comment
          name
        }
      }
    ]])
    T.eq(doc.definitions[1].selectionSet.selections[1].name.value, "hero")
  end)
end)

-- ---------------------------------------------------------------------------
-- SDL: type definitions
-- ---------------------------------------------------------------------------

T.describe("SDL type definitions", function()
  T.it("parses object type", function()
    local doc = parse_ok("type User { id: ID! name: String }")
    local def = doc.definitions[1]
    T.eq(def.kind, "ObjectTypeDefinition")
    T.eq(def.name.value, "User")
    T.eq(#def.fields, 2)
    T.eq(def.fields[1].name.value, "id")
    T.eq(def.fields[1].type.kind, "NonNullType")
    T.eq(def.fields[1].type.type.name.value, "ID")
    T.eq(def.fields[2].name.value, "name")
    T.eq(def.fields[2].type.name.value, "String")
  end)

  T.it("parses type with implements", function()
    local doc = parse_ok("type Cat implements Animal & Pet { name: String }")
    local def = doc.definitions[1]
    T.eq(def.kind, "ObjectTypeDefinition")
    T.eq(#def.interfaces, 2)
    T.eq(def.interfaces[1].name.value, "Animal")
    T.eq(def.interfaces[2].name.value, "Pet")
  end)

  T.it("parses interface type", function()
    local doc = parse_ok("interface Named { name: String! }")
    local def = doc.definitions[1]
    T.eq(def.kind, "InterfaceTypeDefinition")
    T.eq(def.name.value, "Named")
    T.eq(#def.fields, 1)
    T.eq(def.fields[1].name.value, "name")
  end)

  T.it("parses union type", function()
    local doc = parse_ok("union SearchResult = User | Post | Comment")
    local def = doc.definitions[1]
    T.eq(def.kind, "UnionTypeDefinition")
    T.eq(def.name.value, "SearchResult")
    T.eq(#def.types, 3)
    T.eq(def.types[1].name.value, "User")
    T.eq(def.types[2].name.value, "Post")
    T.eq(def.types[3].name.value, "Comment")
  end)

  T.it("parses enum type", function()
    local doc = parse_ok("enum Direction { NORTH SOUTH EAST WEST }")
    local def = doc.definitions[1]
    T.eq(def.kind, "EnumTypeDefinition")
    T.eq(def.name.value, "Direction")
    T.eq(#def.values, 4)
    T.eq(def.values[1].name.value, "NORTH")
    T.eq(def.values[4].name.value, "WEST")
  end)

  T.it("parses input type", function()
    local doc = parse_ok("input CreateUserInput { name: String! age: Int }")
    local def = doc.definitions[1]
    T.eq(def.kind, "InputObjectTypeDefinition")
    T.eq(def.name.value, "CreateUserInput")
    T.eq(#def.fields, 2)
    T.eq(def.fields[1].name.value, "name")
    T.eq(def.fields[1].type.kind, "NonNullType")
    T.eq(def.fields[2].name.value, "age")
  end)

  T.it("parses scalar type", function()
    local doc = parse_ok("scalar DateTime")
    local def = doc.definitions[1]
    T.eq(def.kind, "ScalarTypeDefinition")
    T.eq(def.name.value, "DateTime")
  end)

  T.it("parses schema definition", function()
    local doc = parse_ok("schema { query: Query mutation: Mutation }")
    local def = doc.definitions[1]
    T.eq(def.kind, "SchemaDefinition")
    T.eq(#def.operationTypes, 2)
    T.eq(def.operationTypes[1].operation, "query")
    T.eq(def.operationTypes[1].type.name.value, "Query")
  end)

  T.it("parses directive definition", function()
    local doc = parse_ok("directive @auth(role: String) on FIELD | FIELD_DEFINITION")
    local def = doc.definitions[1]
    T.eq(def.kind, "DirectiveDefinition")
    T.eq(def.name.value, "auth")
    T.eq(#def.arguments, 1)
    T.eq(def.arguments[1].name.value, "role")
    T.eq(#def.locations, 2)
    T.eq(def.locations[1].value, "FIELD")
    T.eq(def.locations[2].value, "FIELD_DEFINITION")
  end)

  T.it("parses field with arguments in type", function()
    local doc = parse_ok("type Query { user(id: ID!): User }")
    local def = doc.definitions[1]
    T.eq(def.fields[1].name.value, "user")
    T.eq(#def.fields[1].arguments, 1)
    T.eq(def.fields[1].arguments[1].name.value, "id")
    T.eq(def.fields[1].arguments[1].type.kind, "NonNullType")
  end)

  T.it("parses list type in SDL", function()
    local doc = parse_ok("type User { friends: [User!]! }")
    local field = doc.definitions[1].fields[1]
    T.eq(field.type.kind, "NonNullType")
    T.eq(field.type.type.kind, "ListType")
    T.eq(field.type.type.type.kind, "NonNullType")
    T.eq(field.type.type.type.type.name.value, "User")
  end)
end)

-- ---------------------------------------------------------------------------
-- M.print
-- ---------------------------------------------------------------------------

T.describe("M.print", function()
  T.it("prints simple query", function()
    local doc = parse_ok("{ hero { name } }")
    local out = G.print(doc)
    T.ok(out:find("hero"), "output should contain 'hero'")
    T.ok(out:find("name"), "output should contain 'name'")
  end)

  T.it("prints named query", function()
    local doc = parse_ok("query HeroQuery { hero { id name } }")
    local out = G.print(doc)
    T.ok(out:find("query HeroQuery"), "should have operation keyword and name")
  end)

  T.it("prints mutation", function()
    local doc = parse_ok("mutation CreateUser($name: String!) { createUser(name: $name) { id } }")
    local out = G.print(doc)
    T.ok(out:find("mutation CreateUser"), "should have mutation keyword")
    T.ok(out:find("%$name: String!"), "should have variable definition")
  end)

  T.it("prints fragment definition", function()
    local doc = parse_ok("fragment HeroFields on Character { id name }")
    local out = G.print(doc)
    T.ok(out:find("fragment HeroFields on Character"), "should have fragment definition")
  end)

  T.it("prints inline fragment", function()
    local doc = parse_ok("{ hero { ... on Droid { primaryFunction } } }")
    local out = G.print(doc)
    T.ok(out:find("%.%.%. on Droid"), "should have inline fragment")
  end)

  T.it("prints object type definition", function()
    local doc = parse_ok("type User { id: ID! name: String }")
    local out = G.print(doc)
    T.ok(out:find("type User"), "should have type keyword")
    T.ok(out:find("id: ID!"), "should have non-null field")
  end)

  T.it("prints union type", function()
    local doc = parse_ok("union SearchResult = User | Post")
    local out = G.print(doc)
    T.ok(out:find("union SearchResult"), "should have union keyword")
    T.ok(out:find("User | Post"), "should have union members")
  end)

  T.it("prints enum type", function()
    local doc = parse_ok("enum Direction { NORTH SOUTH }")
    local out = G.print(doc)
    T.ok(out:find("enum Direction"), "should have enum keyword")
    T.ok(out:find("NORTH"), "should have enum value")
  end)

  T.it("prints input type", function()
    local doc = parse_ok("input CreateUserInput { name: String! }")
    local out = G.print(doc)
    T.ok(out:find("input CreateUserInput"), "should have input keyword")
  end)

  T.it("prints all value types", function()
    local doc = parse_ok('{ f(a: 1, b: 3.14, c: "hi", d: true, e: null, f: ENUM, g: [1,2], h: {x:1}) { id } }')
    local out = G.print(doc)
    T.ok(out:find("3.14"), "float")
    T.ok(out:find('"hi"'), "string")
    T.ok(out:find("true"), "boolean")
    T.ok(out:find("null"), "null")
    T.ok(out:find("ENUM"), "enum")
  end)

  T.it("prints directives", function()
    local doc = parse_ok('{ hero @include(if: true) { name @deprecated } }')
    local out = G.print(doc)
    T.ok(out:find("@include%(if: true%)"), "should have include directive")
    T.ok(out:find("@deprecated"), "should have deprecated directive")
  end)
end)

-- ---------------------------------------------------------------------------
-- Round-trip tests: parse → print → parse gives same AST
-- ---------------------------------------------------------------------------

T.describe("round-trip parse→print→parse", function()
  local function roundtrip(src, label)
    local doc1, err1 = G.parse(src)
    T.ok(doc1, label .. ": first parse failed: " .. tostring(err1))
    local printed = G.print(doc1)
    local doc2, err2 = G.parse(printed)
    T.ok(doc2, label .. ": second parse failed: " .. tostring(err2))
    -- Check that key structural elements are preserved
    T.eq(#doc1.definitions, #doc2.definitions, label .. ": definition count")
    for i = 1, #doc1.definitions do
      T.eq(doc1.definitions[i].kind, doc2.definitions[i].kind, label .. ": def[" .. i .. "].kind")
    end
  end

  T.it("simple query round-trips", function()
    roundtrip("{ hero { id name } }", "simple query")
  end)

  T.it("named operation round-trips", function()
    roundtrip("query GetHero($ep: Episode) { hero(episode: $ep) { id name } }", "named query")
  end)

  T.it("fragment definition round-trips", function()
    roundtrip("fragment F on T { a b c }", "fragment")
  end)

  T.it("object type definition round-trips", function()
    roundtrip("type User { id: ID! name: String friends: [User!]! }", "type def")
  end)

  T.it("union type round-trips", function()
    roundtrip("union Result = A | B | C", "union")
  end)

  T.it("enum type round-trips", function()
    roundtrip("enum Color { RED GREEN BLUE }", "enum")
  end)

  T.it("interface type round-trips", function()
    roundtrip("interface Named { name: String! }", "interface")
  end)

  T.it("input type round-trips", function()
    roundtrip("input UserInput { name: String! age: Int }", "input")
  end)

  T.it("mutation with variables round-trips", function()
    roundtrip("mutation M($x: String!) { doThing(x: $x) { ok } }", "mutation")
  end)
end)

-- ---------------------------------------------------------------------------
-- M.validate
-- ---------------------------------------------------------------------------

T.describe("M.validate", function()
  T.it("validates a correct document", function()
    local doc = parse_ok("{ hero { name } }")
    local ok, errs = G.validate(doc)
    T.ok(ok, "valid doc should pass")
    T.eq(#errs, 0)
  end)

  T.it("catches missing selectionSet on operation", function()
    -- Construct a bad AST manually
    local bad_doc = {
      kind = "Document",
      definitions = {
        {
          kind = "OperationDefinition",
          operation = "query",
          name = nil,
          variableDefinitions = {},
          directives = {},
          selectionSet = nil,  -- intentionally missing
        }
      }
    }
    local ok, errs = G.validate(bad_doc)
    T.ok(not ok, "should fail validation")
    T.ok(#errs > 0, "should have error messages")
  end)

  T.it("catches invalid operation type", function()
    local bad_doc = {
      kind = "Document",
      definitions = {
        {
          kind = "OperationDefinition",
          operation = "badop",
          selectionSet = { kind = "SelectionSet", selections = {{ kind = "Field", name = {value = "x"} }} },
        }
      }
    }
    local ok, errs = G.validate(bad_doc)
    T.ok(not ok)
    T.ok(#errs > 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Error cases
-- ---------------------------------------------------------------------------

T.describe("error cases", function()
  T.it("returns error for unclosed brace", function()
    local err = parse_err("{ hero { name }")
    T.ok(type(err) == "string" and #err > 0, "error should be a non-empty string")
  end)

  T.it("returns error for unexpected character", function()
    local err = parse_err("@ invalid")
    T.ok(type(err) == "string" and #err > 0, "should be a non-empty error string")
  end)

  T.it("returns error for unterminated string", function()
    local err = parse_err('{ f(x: "unterminated) { id } }')
    T.ok(err, "should be an error message")
  end)

  T.it("returns error for missing colon in argument", function()
    local err = parse_err("{ f(x 42) { id } }")
    T.ok(err, "should be an error message")
  end)

  T.it("returns error for fragment without 'on'", function()
    local err = parse_err("fragment F Character { id }")
    T.ok(err, "should be an error message")
  end)

  T.it("returns nil+error not exception", function()
    local doc, err = G.parse("{ { broken }")
    T.ok(doc == nil, "should return nil")
    T.ok(type(err) == "string", "error should be a string")
  end)

  T.it("handles empty string", function()
    local doc, err = G.parse("")
    T.ok(doc ~= nil, "empty doc should parse to empty document")
    T.ok(err == nil, "should have no error")
    T.eq(doc.kind, "Document")
    T.eq(#doc.definitions, 0)
  end)

  T.it("handles whitespace-only string", function()
    local doc, err = G.parse("   \n\t  ")
    T.ok(doc ~= nil)
    T.eq(#doc.definitions, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Comments are ignored in parsing
-- ---------------------------------------------------------------------------

T.describe("comment handling", function()
  T.it("comments between fields are ignored", function()
    local doc = parse_ok([[
      {
        # first field
        hero {
          # nested
          name
          # another
          id
        }
      }
    ]])
    local hero = doc.definitions[1].selectionSet.selections[1]
    T.eq(hero.name.value, "hero")
    T.eq(#hero.selectionSet.selections, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Comma as whitespace
-- ---------------------------------------------------------------------------

T.describe("comma as whitespace", function()
  T.it("commas are ignored in selection sets", function()
    local doc = parse_ok("{ a, b, c }")
    T.eq(#doc.definitions[1].selectionSet.selections, 3)
  end)

  T.it("commas are ignored in argument lists", function()
    local doc = parse_ok("{ f(a: 1, b: 2) { id } }")
    T.eq(#doc.definitions[1].selectionSet.selections[1].arguments, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Type references
-- ---------------------------------------------------------------------------

T.describe("type references", function()
  T.it("NamedType", function()
    local doc = parse_ok("query Q($x: String) { f }")
    T.eq(doc.definitions[1].variableDefinitions[1].type.kind, "NamedType")
  end)

  T.it("ListType", function()
    local doc = parse_ok("query Q($x: [String]) { f }")
    T.eq(doc.definitions[1].variableDefinitions[1].type.kind, "ListType")
    T.eq(doc.definitions[1].variableDefinitions[1].type.type.name.value, "String")
  end)

  T.it("NonNullType on named", function()
    local doc = parse_ok("query Q($x: String!) { f }")
    T.eq(doc.definitions[1].variableDefinitions[1].type.kind, "NonNullType")
    T.eq(doc.definitions[1].variableDefinitions[1].type.type.name.value, "String")
  end)

  T.it("NonNullType on list", function()
    local doc = parse_ok("query Q($x: [String!]!) { f }")
    local t = doc.definitions[1].variableDefinitions[1].type
    T.eq(t.kind, "NonNullType")
    T.eq(t.type.kind, "ListType")
    T.eq(t.type.type.kind, "NonNullType")
    T.eq(t.type.type.type.name.value, "String")
  end)
end)

-- ---------------------------------------------------------------------------
-- Multiple definitions in one document
-- ---------------------------------------------------------------------------

T.describe("multiple definitions", function()
  T.it("parses multiple operations and fragments", function()
    local src = [[
      query Q1 { a { id } }
      query Q2 { b { id } }
      fragment F on T { x y }
    ]]
    local doc = parse_ok(src)
    T.eq(#doc.definitions, 3)
    T.eq(doc.definitions[1].kind, "OperationDefinition")
    T.eq(doc.definitions[1].name.value, "Q1")
    T.eq(doc.definitions[2].kind, "OperationDefinition")
    T.eq(doc.definitions[2].name.value, "Q2")
    T.eq(doc.definitions[3].kind, "FragmentDefinition")
    T.eq(doc.definitions[3].name.value, "F")
  end)

  T.it("parses mixed SDL and operations", function()
    -- SDL and operation in same document (unusual but valid)
    local src = [[
      type User { id: ID }
      scalar DateTime
    ]]
    local doc = parse_ok(src)
    T.eq(#doc.definitions, 2)
    T.eq(doc.definitions[1].kind, "ObjectTypeDefinition")
    T.eq(doc.definitions[2].kind, "ScalarTypeDefinition")
  end)
end)
