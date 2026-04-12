if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local gql = require("lib.graphql")

-- ── Parser tests ──────────────────────────────────────────────────────────────

T.describe("parse", function()

	T.it("simple query - shorthand", function()
		local ast, err = gql.parse("{ hello }")
		T.ok(ast, err)
		T.eq(ast.kind, "Document")
		T.eq(#ast.definitions, 1)
		local op = ast.definitions[1]
		T.eq(op.kind, "OperationDefinition")
		T.eq(op.operation, "query")
		T.eq(op.name, nil)
		T.eq(#op.selectionSet.selections, 1)
		T.eq(op.selectionSet.selections[1].name, "hello")
	end)

	T.it("named query with arguments", function()
		local ast, err = gql.parse([[
			query GetUser($id: ID!) {
				user(id: $id) {
					name
					email
				}
			}
		]])
		T.ok(ast, err)
		local op = ast.definitions[1]
		T.eq(op.kind, "OperationDefinition")
		T.eq(op.operation, "query")
		T.eq(op.name, "GetUser")
		T.eq(#op.variableDefinitions, 1)
		local vd = op.variableDefinitions[1]
		T.eq(vd.variable.name, "id")
		T.eq(vd.type.kind, "NonNullType")
		T.eq(vd.type.type.name, "ID")
		local user_field = op.selectionSet.selections[1]
		T.eq(user_field.name, "user")
		T.eq(#user_field.arguments, 1)
		T.eq(user_field.arguments[1].name, "id")
		T.eq(user_field.arguments[1].value.kind, "Variable")
		T.eq(user_field.arguments[1].value.name, "id")
		T.eq(#user_field.selectionSet.selections, 2)
		T.eq(user_field.selectionSet.selections[1].name, "name")
		T.eq(user_field.selectionSet.selections[2].name, "email")
	end)

	T.it("nested fields", function()
		local ast, err = gql.parse([[
			query {
				user {
					posts {
						title
						createdAt
					}
				}
			}
		]])
		T.ok(ast, err)
		local user_field = ast.definitions[1].selectionSet.selections[1]
		T.eq(user_field.name, "user")
		local posts_field = user_field.selectionSet.selections[1]
		T.eq(posts_field.name, "posts")
		T.eq(posts_field.selectionSet.selections[1].name, "title")
		T.eq(posts_field.selectionSet.selections[2].name, "createdAt")
	end)

	T.it("field aliases", function()
		local ast, err = gql.parse([[
			{
				myUser: user(id: "1") {
					fullName: name
				}
			}
		]])
		T.ok(ast, err)
		local field = ast.definitions[1].selectionSet.selections[1]
		T.eq(field.alias, "myUser")
		T.eq(field.name, "user")
		local inner = field.selectionSet.selections[1]
		T.eq(inner.alias, "fullName")
		T.eq(inner.name, "name")
	end)

	T.it("fragment definition and spread", function()
		local ast, err = gql.parse([[
			query {
				user {
					...UserFields
				}
			}
			fragment UserFields on User {
				name
				email
			}
		]])
		T.ok(ast, err)
		T.eq(#ast.definitions, 2)
		local op = ast.definitions[1]
		local frag_spread = op.selectionSet.selections[1].selectionSet.selections[1]
		T.eq(frag_spread.kind, "FragmentSpread")
		T.eq(frag_spread.name, "UserFields")
		local frag_def = ast.definitions[2]
		T.eq(frag_def.kind, "FragmentDefinition")
		T.eq(frag_def.name, "UserFields")
		T.eq(frag_def.typeCondition.name, "User")
	end)

	T.it("inline fragment", function()
		local ast, err = gql.parse([[
			{
				search {
					... on User {
						name
					}
					... on Post {
						title
					}
				}
			}
		]])
		T.ok(ast, err)
		local sels = ast.definitions[1].selectionSet.selections[1].selectionSet.selections
		T.eq(#sels, 2)
		T.eq(sels[1].kind, "InlineFragment")
		T.eq(sels[1].typeCondition.name, "User")
		T.eq(sels[2].kind, "InlineFragment")
		T.eq(sels[2].typeCondition.name, "Post")
	end)

	T.it("variables with defaults", function()
		local ast, err = gql.parse([[
			query Posts($limit: Int = 10, $offset: Int = 0) {
				posts(limit: $limit, offset: $offset) {
					title
				}
			}
		]])
		T.ok(ast, err)
		local vdefs = ast.definitions[1].variableDefinitions
		T.eq(#vdefs, 2)
		T.eq(vdefs[1].variable.name, "limit")
		T.eq(vdefs[1].defaultValue.kind, "IntValue")
		T.eq(vdefs[1].defaultValue.value, "10")
		T.eq(vdefs[2].variable.name, "offset")
	end)

	T.it("mutation keyword", function()
		local ast, err = gql.parse([[
			mutation CreatePost($title: String!) {
				createPost(title: $title) {
					id
					title
				}
			}
		]])
		T.ok(ast, err)
		T.eq(ast.definitions[1].operation, "mutation")
		T.eq(ast.definitions[1].name, "CreatePost")
	end)

	T.it("subscription keyword", function()
		local ast, err = gql.parse([[
			subscription OnMessage {
				messageAdded {
					id
					body
				}
			}
		]])
		T.ok(ast, err)
		T.eq(ast.definitions[1].operation, "subscription")
		T.eq(ast.definitions[1].name, "OnMessage")
	end)

	T.it("literal value types", function()
		local ast, err = gql.parse([[
			{
				search(q: "hello", n: 42, f: 3.14, b: true, x: null, e: ACTIVE) {
					id
				}
			}
		]])
		T.ok(ast, err)
		local args = ast.definitions[1].selectionSet.selections[1].arguments
		T.eq(args[1].value.kind, "StringValue");  T.eq(args[1].value.value, "hello")
		T.eq(args[2].value.kind, "IntValue");     T.eq(args[2].value.value, "42")
		T.eq(args[3].value.kind, "FloatValue");   T.eq(args[3].value.value, "3.14")
		T.eq(args[4].value.kind, "BooleanValue"); T.eq(args[4].value.value, true)
		T.eq(args[5].value.kind, "NullValue")
		T.eq(args[6].value.kind, "EnumValue");    T.eq(args[6].value.value, "ACTIVE")
	end)

	T.it("list and object value literals", function()
		local ast, err = gql.parse([[
			{
				foo(ids: [1, 2, 3], filter: {active: true}) { id }
			}
		]])
		T.ok(ast, err)
		local args = ast.definitions[1].selectionSet.selections[1].arguments
		T.eq(args[1].value.kind, "ListValue")
		T.eq(#args[1].value.values, 3)
		T.eq(args[2].value.kind, "ObjectValue")
		T.eq(args[2].value.fields[1].name, "active")
	end)

	T.it("directives", function()
		local ast, err = gql.parse([[
			{
				user @auth(role: "admin") {
					name @skip(if: false)
				}
			}
		]])
		T.ok(ast, err)
		local user = ast.definitions[1].selectionSet.selections[1]
		T.eq(#user.directives, 1)
		T.eq(user.directives[1].name, "auth")
		T.eq(user.directives[1].arguments[1].name, "role")
		local name_field = user.selectionSet.selections[1]
		T.eq(name_field.directives[1].name, "skip")
	end)

	T.it("parse error on malformed query", function()
		local ast, err = gql.parse("{ unclosed")
		T.eq(ast, nil)
		T.ok(err)
		T.ok(type(err) == "string")
	end)

	T.it("parse error on missing field after colon", function()
		local ast, err = gql.parse("{ user( : id) { name } }")
		T.eq(ast, nil)
		T.ok(err)
	end)

	T.it("parse_schema - basic type definitions", function()
		local ast, err = gql.parse_schema([[
			type User {
				id: ID!
				name: String!
				email: String
				posts: [Post!]!
			}
			type Post {
				id: ID!
				title: String!
				body: String
				author: User!
			}
			type Query {
				user(id: ID!): User
				posts: [Post!]!
			}
		]])
		T.ok(ast, err)
		T.eq(ast.kind, "Document")
		T.eq(#ast.definitions, 3)
		local user_type = ast.definitions[1]
		T.eq(user_type.kind, "ObjectTypeDefinition")
		T.eq(user_type.name, "User")
		T.eq(#user_type.fields, 4)
		-- id: ID!
		T.eq(user_type.fields[1].name, "id")
		T.eq(user_type.fields[1].type.kind, "NonNullType")
		T.eq(user_type.fields[1].type.type.name, "ID")
		-- posts: [Post!]!
		local posts_field = user_type.fields[4]
		T.eq(posts_field.name, "posts")
		T.eq(posts_field.type.kind, "NonNullType")
		T.eq(posts_field.type.type.kind, "ListType")
		-- Query.user(id: ID!): User
		local query_type = ast.definitions[3]
		T.eq(query_type.name, "Query")
		local user_field = query_type.fields[1]
		T.eq(user_field.name, "user")
		T.eq(#user_field.arguments, 1)
		T.eq(user_field.arguments[1].name, "id")
	end)

end)

-- ── Executor tests ────────────────────────────────────────────────────────────

-- Build a test schema + dataset once
local users_db = {
	["1"] = { id = "1", name = "Alice", email = "alice@example.com" },
	["2"] = { id = "2", name = "Bob",   email = "bob@example.com" },
}
local posts_db = {
	{ id = "p1", title = "Hello World", body = "...", author_id = "1" },
	{ id = "p2", title = "LuaJIT Tips",  body = "...", author_id = "1" },
	{ id = "p3", title = "GraphQL Fun",  body = "...", author_id = "2" },
}

local test_schema = gql.schema({
	Query = {
		user = {
			type = "User",
			args = { id = { type = "ID", required = true } },
			resolve = function(root, args, ctx)
				return ctx.users[args.id]
			end,
		},
		posts = {
			type = "[Post]",
			resolve = function(root, args, ctx)
				return ctx.posts
			end,
		},
		broken = {
			type = "String",
			resolve = function(root, args, ctx)
				error("resolver exploded")
			end,
		},
	},
	User = {
		id    = { type = "ID" },
		name  = { type = "String" },
		email = { type = "String" },
		posts = {
			type = "[Post]",
			resolve = function(user, args, ctx)
				local result = {}
				for _, p in ipairs(ctx.posts) do
					if p.author_id == user.id then
						result[#result + 1] = p
					end
				end
				return result
			end,
		},
	},
	Post = {
		id       = { type = "ID" },
		title    = { type = "String" },
		body     = { type = "String" },
		author   = {
			type = "User",
			resolve = function(post, args, ctx)
				return ctx.users[post.author_id]
			end,
		},
	},
})

local ctx = { users = users_db, posts = posts_db }

T.describe("execute", function()

	T.it("simple field resolution", function()
		local result = gql.execute(test_schema, [[
			{ user(id: "1") { name } }
		]], { context = ctx })
		T.ok(result.errors == nil, result.errors and result.errors[1].message or "")
		T.eq(result.data.user.name, "Alice")
	end)

	T.it("arguments passed to resolver", function()
		local result = gql.execute(test_schema, [[
			{ user(id: "2") { name email } }
		]], { context = ctx })
		T.ok(result.errors == nil)
		T.eq(result.data.user.name, "Bob")
		T.eq(result.data.user.email, "bob@example.com")
	end)

	T.it("nested resolvers", function()
		local result = gql.execute(test_schema, [[
			{
				user(id: "1") {
					name
					posts {
						title
					}
				}
			}
		]], { context = ctx })
		T.ok(result.errors == nil, result.errors and result.errors[1].message or "")
		T.eq(result.data.user.name, "Alice")
		T.eq(#result.data.user.posts, 2)
		T.eq(result.data.user.posts[1].title, "Hello World")
	end)

	T.it("null field - resolver returns nil", function()
		local result = gql.execute(test_schema, [[
			{ user(id: "999") { name } }
		]], { context = ctx })
		T.ok(result.errors == nil)
		T.eq(result.data.user, nil)
	end)

	T.it("list type resolvers", function()
		local result = gql.execute(test_schema, [[
			{ posts { id title } }
		]], { context = ctx })
		T.ok(result.errors == nil)
		T.eq(#result.data.posts, 3)
		T.eq(result.data.posts[1].title, "Hello World")
		T.eq(result.data.posts[2].title, "LuaJIT Tips")
	end)

	T.it("variable substitution", function()
		local result = gql.execute(test_schema, [[
			query GetUser($id: ID!) {
				user(id: $id) {
					name
				}
			}
		]], { variables = { id = "2" }, context = ctx })
		T.ok(result.errors == nil)
		T.eq(result.data.user.name, "Bob")
	end)

	T.it("resolver error collected into errors array, partial data returned", function()
		local result = gql.execute(test_schema, [[
			{
				user(id: "1") { name }
				broken
			}
		]], { context = ctx })
		T.ok(result.errors ~= nil)
		T.eq(#result.errors, 1)
		T.ok(result.errors[1].message:find("resolver exploded"))
		-- partial data: user still resolved
		T.eq(result.data.user.name, "Alice")
	end)

	T.it("__typename introspection", function()
		local result = gql.execute(test_schema, [[
			{
				user(id: "1") {
					__typename
					name
				}
			}
		]], { context = ctx })
		T.ok(result.errors == nil)
		T.eq(result.data.user.__typename, "User")
		T.eq(result.data.user.name, "Alice")
	end)

	T.it("unknown field returns error", function()
		local result = gql.execute(test_schema, [[
			{ user(id: "1") { doesNotExist } }
		]], { context = ctx })
		T.ok(result.errors ~= nil)
		T.ok(result.errors[1].message:find("doesNotExist"))
	end)

	T.it("fragment spread in execution", function()
		local result = gql.execute(test_schema, [[
			query {
				user(id: "1") {
					...UserBasic
				}
			}
			fragment UserBasic on User {
				name
				email
			}
		]], { context = ctx })
		T.ok(result.errors == nil)
		T.eq(result.data.user.name, "Alice")
		T.eq(result.data.user.email, "alice@example.com")
	end)

	T.it("deeply nested resolver (post -> author -> name)", function()
		local result = gql.execute(test_schema, [[
			{
				posts {
					title
					author {
						name
					}
				}
			}
		]], { context = ctx })
		T.ok(result.errors == nil)
		T.eq(result.data.posts[1].author.name, "Alice")
		T.eq(result.data.posts[3].author.name, "Bob")
	end)

	T.it("field alias in result", function()
		local result = gql.execute(test_schema, [[
			{
				alice: user(id: "1") { name }
				bob:   user(id: "2") { name }
			}
		]], { context = ctx })
		T.ok(result.errors == nil)
		T.eq(result.data.alice.name, "Alice")
		T.eq(result.data.bob.name, "Bob")
	end)

	T.it("parse error in query returns error", function()
		local result = gql.execute(test_schema, "{ unclosed")
		T.eq(result.data, nil)
		T.ok(result.errors ~= nil)
		T.ok(result.errors[1].message)
	end)

	T.it("__typename on Query root", function()
		local result = gql.execute(test_schema, [[
			{ __typename }
		]], { context = ctx })
		T.ok(result.errors == nil)
		T.eq(result.data.__typename, "Query")
	end)

end)
