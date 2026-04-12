-- lib/mini_orm/mini_orm_test.lua
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local ORM = require("lib.mini_orm")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_db()
	local db = ORM.database()

	local User = db:model("users", {
		fields = {
			id      = { type = "integer", primary_key = true, auto_increment = true },
			name    = { type = "string",  required = true, max_length = 100 },
			email   = { type = "string",  required = true, unique = true },
			age     = { type = "integer", default = 0 },
			active  = { type = "boolean", default = true },
			created = { type = "string" },
		},
	})

	local Post = db:model("posts", {
		fields = {
			id      = { type = "integer", primary_key = true, auto_increment = true },
			title   = { type = "string",  required = true },
			body    = { type = "string" },
			user_id = { type = "integer", foreign_key = "users.id" },
		},
	})

	-- Build has_many (user:posts)
	db:_build_has_many()

	return db, User, Post
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("mini_orm", function()

	-- ── _tier ────────────────────────────────────────────────────────────────
	T.describe("_tier", function()
		T.it("is 'pure'", function()
			T.eq(ORM._tier, "pure")
		end)
	end)

	-- ── create ───────────────────────────────────────────────────────────────
	T.describe("create", function()
		T.it("saves a record with auto-increment id", function()
			local db, User = make_db()
			local u, err = User:create({ name = "Alice", email = "alice@example.com" })
			T.ok(u, "expected record, got nil")
			T.ok(not err, "unexpected error")
			T.eq(u.id, 1)
			T.eq(u.name, "Alice")
			T.eq(u.email, "alice@example.com")
		end)

		T.it("auto-increments id for multiple records", function()
			local db, User = make_db()
			local u1 = User:create({ name = "Alice", email = "a@x.com" })
			local u2 = User:create({ name = "Bob",   email = "b@x.com" })
			T.eq(u1.id, 1)
			T.eq(u2.id, 2)
		end)

		T.it("applies defaults", function()
			local db, User = make_db()
			local u = User:create({ name = "Alice", email = "a@x.com" })
			T.eq(u.age, 0)
			T.eq(u.active, true)
		end)

		T.it("accepts explicit values that override defaults", function()
			local db, User = make_db()
			local u = User:create({ name = "Bob", email = "b@x.com", age = 25, active = false })
			T.eq(u.age, 25)
			T.eq(u.active, false)
		end)

		T.it("returns nil+err when required field missing", function()
			local db, User = make_db()
			local u, err = User:create({ email = "a@x.com" })
			T.ok(u == nil)
			T.ok(err ~= nil)
			T.eq(err.name, "required")
		end)

		T.it("returns nil+err on duplicate unique field", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "same@x.com" })
			local u2, err = User:create({ name = "Bob", email = "same@x.com" })
			T.ok(u2 == nil)
			T.ok(err ~= nil)
			T.eq(err.email, "must be unique")
		end)

		T.it("returns nil+err on max_length violation", function()
			local db, User = make_db()
			local long_name = string.rep("a", 101)
			local u, err = User:create({ name = long_name, email = "a@x.com" })
			T.ok(u == nil)
			T.ok(err ~= nil)
			T.ok(err.name ~= nil)
		end)
	end)

	-- ── find ─────────────────────────────────────────────────────────────────
	T.describe("find", function()
		T.it("finds record by primary key", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			local u = User:find(1)
			T.ok(u ~= nil)
			T.eq(u.name, "Alice")
		end)

		T.it("returns nil for missing primary key", function()
			local db, User = make_db()
			local u = User:find(999)
			T.ok(u == nil)
		end)

		T.it("find_by returns first match", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			User:create({ name = "Bob",   email = "b@x.com" })
			local u = User:find_by({ email = "b@x.com" })
			T.ok(u ~= nil)
			T.eq(u.name, "Bob")
		end)

		T.it("find_by returns nil when no match", function()
			local db, User = make_db()
			local u = User:find_by({ email = "nobody@x.com" })
			T.ok(u == nil)
		end)
	end)

	-- ── all / count ───────────────────────────────────────────────────────────
	T.describe("all / count", function()
		T.it("all returns all records", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			User:create({ name = "Bob",   email = "b@x.com" })
			local all = User:all()
			T.eq(#all, 2)
		end)

		T.it("all returns empty table when no records", function()
			local db, User = make_db()
			T.eq(#User:all(), 0)
		end)

		T.it("count returns total", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			User:create({ name = "Bob",   email = "b@x.com" })
			T.eq(User:count(), 2)
		end)

		T.it("count with conditions", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com", active = true })
			User:create({ name = "Bob",   email = "b@x.com", active = false })
			T.eq(User:count({ active = true }), 1)
			T.eq(User:count({ active = false }), 1)
		end)
	end)

	-- ── where ─────────────────────────────────────────────────────────────────
	T.describe("where", function()
		T.it("filters by field value", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com", active = true })
			User:create({ name = "Bob",   email = "b@x.com", active = false })
			User:create({ name = "Carol", email = "c@x.com", active = true })
			local active = User:where({ active = true })
			T.eq(#active, 2)
		end)

		T.it("returns empty table when nothing matches", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			T.eq(#User:where({ name = "NoOne" }), 0)
		end)
	end)

	-- ── query builder ─────────────────────────────────────────────────────────
	T.describe("query builder", function()
		local function make_users(db, User)
			User:create({ name = "Alice", email = "a@x.com", age = 20, active = true })
			User:create({ name = "Bob",   email = "b@x.com", age = 30, active = true })
			User:create({ name = "Carol", email = "c@x.com", age = 40, active = false })
			User:create({ name = "Dave",  email = "d@x.com", age = 50, active = false })
			User:create({ name = "Eve",   email = "e@x.com", age = 25, active = true })
		end

		T.it("where filters", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():where({ active = true }):execute()
			T.eq(#r, 3)
		end)

		T.it("where_gt", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():where_gt("age", 30):execute()
			T.eq(#r, 2)
			for _, u in ipairs(r) do
				T.ok(u.age > 30)
			end
		end)

		T.it("where_lt", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():where_lt("age", 30):execute()
			T.eq(#r, 2)
			for _, u in ipairs(r) do
				T.ok(u.age < 30)
			end
		end)

		T.it("where_gte", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():where_gte("age", 30):execute()
			T.eq(#r, 3)
		end)

		T.it("where_lte", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():where_lte("age", 30):execute()
			T.eq(#r, 3)
		end)

		T.it("where_like prefix", function()
			local db, User = make_db()
			make_users(db, User)
			-- Alice starts with A (capital)
			local r = User:query():where_like("name", "A%"):execute()
			T.eq(#r, 1)
			T.eq(r[1].name, "Alice")
		end)

		T.it("where_like suffix", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():where_like("name", "%e"):execute()
			-- Alice, Dave, Eve end in 'e'
			T.eq(#r, 3)
		end)

		T.it("order_by asc", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():order_by("age", "asc"):execute()
			T.eq(#r, 5)
			T.eq(r[1].age, 20)
			T.eq(r[5].age, 50)
		end)

		T.it("order_by desc", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():order_by("age", "desc"):execute()
			T.eq(r[1].age, 50)
			T.eq(r[5].age, 20)
		end)

		T.it("limit", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():order_by("age", "asc"):limit(2):execute()
			T.eq(#r, 2)
		end)

		T.it("offset", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():order_by("age", "asc"):offset(3):execute()
			T.eq(#r, 2)
			T.eq(r[1].age, 40)
		end)

		T.it("limit + offset", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query():order_by("age", "asc"):limit(2):offset(1):execute()
			T.eq(#r, 2)
			T.eq(r[1].age, 25)
			T.eq(r[2].age, 30)
		end)

		T.it("chained where + order_by + limit", function()
			local db, User = make_db()
			make_users(db, User)
			local r = User:query()
				:where({ active = true })
				:where_gt("age", 20)
				:order_by("age", "asc")
				:limit(1)
				:execute()
			T.eq(#r, 1)
			T.eq(r[1].name, "Eve")
		end)
	end)

	-- ── update / delete ───────────────────────────────────────────────────────
	T.describe("update", function()
		T.it("updates field on record instance", function()
			local db, User = make_db()
			local u = User:create({ name = "Alice", email = "a@x.com" })
			local updated = u:update({ name = "Alice Smith" })
			T.ok(updated ~= nil)
			T.eq(updated.name, "Alice Smith")
			-- Persisted in storage
			local fetched = User:find(u.id)
			T.eq(fetched.name, "Alice Smith")
		end)

		T.it("update returns nil+err on unique violation", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			local u2 = User:create({ name = "Bob", email = "b@x.com" })
			local res, err = u2:update({ email = "a@x.com" })
			T.ok(res == nil)
			T.ok(err ~= nil)
		end)

		T.it("update_where updates all matching", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com", active = true })
			User:create({ name = "Bob",   email = "b@x.com", active = true })
			User:create({ name = "Carol", email = "c@x.com", active = false })
			local count = User:update_where({ active = true }, { active = false })
			T.eq(count, 2)
			T.eq(User:count({ active = false }), 3)
		end)
	end)

	T.describe("delete", function()
		T.it("deletes record instance", function()
			local db, User = make_db()
			local u = User:create({ name = "Alice", email = "a@x.com" })
			u:delete()
			T.ok(User:find(u.id) == nil)
			T.eq(User:count(), 0)
		end)

		T.it("delete_where deletes all matching", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com", active = true })
			User:create({ name = "Bob",   email = "b@x.com", active = false })
			User:create({ name = "Carol", email = "c@x.com", active = false })
			local count = User:delete_where({ active = false })
			T.eq(count, 2)
			T.eq(User:count(), 1)
		end)
	end)

	-- ── relationships ─────────────────────────────────────────────────────────
	T.describe("relationships", function()
		T.it("has_many: user:posts() returns correct posts", function()
			local db, User, Post = make_db()
			local u1 = User:create({ name = "Alice", email = "a@x.com" })
			local u2 = User:create({ name = "Bob",   email = "b@x.com" })
			Post:create({ title = "P1", user_id = u1.id })
			Post:create({ title = "P2", user_id = u1.id })
			Post:create({ title = "P3", user_id = u2.id })

			local posts = u1:posts()
			T.eq(#posts, 2)
		end)

		T.it("has_many: user with no posts returns empty table", function()
			local db, User, Post = make_db()
			local u = User:create({ name = "Alice", email = "a@x.com" })
			local posts = u:posts()
			T.eq(#posts, 0)
		end)

		T.it("belongs_to: post:user() returns correct user", function()
			local db, User, Post = make_db()
			local u = User:create({ name = "Alice", email = "a@x.com" })
			local p = Post:create({ title = "P1", user_id = u.id })

			local author = p:user()
			T.ok(author ~= nil)
			T.eq(author.id, u.id)
			T.eq(author.name, "Alice")
		end)

		T.it("belongs_to: post with nil user_id returns nil", function()
			local db, User, Post = make_db()
			local p = Post:create({ title = "Orphan" })
			local author = p:user()
			T.ok(author == nil)
		end)
	end)

	-- ── transactions ──────────────────────────────────────────────────────────
	T.describe("transactions", function()
		T.it("successful transaction commits all changes", function()
			local db, User, Post = make_db()
			db:transaction(function()
				local u = User:create({ name = "Bob", email = "bob@x.com" })
				Post:create({ title = "Hi", user_id = u.id })
			end)
			T.eq(User:count(), 1)
			T.eq(Post:count(), 1)
		end)

		T.it("failed transaction rolls back all changes", function()
			local db, User, Post = make_db()
			User:create({ name = "Existing", email = "existing@x.com" })

			local ok, err = db:transaction(function()
				User:create({ name = "Bob", email = "bob@x.com" })
				-- Force an error
				error("intentional failure")
			end)

			T.ok(ok == nil)
			T.ok(err ~= nil)
			-- Only the originally existing user should remain
			T.eq(User:count(), 1)
			T.ok(User:find_by({ email = "bob@x.com" }) == nil)
		end)

		T.it("rollback preserves next_id state", function()
			local db, User = make_db()
			db:transaction(function()
				User:create({ name = "Alice", email = "a@x.com" })
				error("rollback")
			end)
			-- After rollback, next_id should be reset too
			local u = User:create({ name = "Real", email = "real@x.com" })
			T.eq(u.id, 1)
		end)
	end)

	-- ── migrations ────────────────────────────────────────────────────────────
	T.describe("migrations", function()
		T.it("current_version starts at 0", function()
			local db = ORM.database()
			T.eq(db:current_version(), 0)
		end)

		T.it("add_column adds field to schema and existing records", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })

			db:migrate({
				{ version = 1,
					up = function(schema)
						schema:add_column("users", "bio", { type = "string", default = "" })
					end,
					down = function(schema)
						schema:remove_column("users", "bio")
					end,
				},
			})

			T.eq(db:current_version(), 1)

			-- Existing record gets default
			local u = User:find(1)
			T.eq(u.bio, "")

			-- New records get default
			local u2 = User:create({ name = "Bob", email = "b@x.com" })
			T.eq(u2.bio, "")
		end)

		T.it("remove_column removes field", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })

			db:migrate({
				{ version = 1,
					up = function(schema)
						schema:add_column("users", "bio", { type = "string", default = "" })
					end,
					down = function(schema)
						schema:remove_column("users", "bio")
					end,
				},
				{ version = 2,
					up = function(schema)
						schema:remove_column("users", "bio")
					end,
					down = function(schema)
						schema:add_column("users", "bio", { type = "string", default = "" })
					end,
				},
			})

			T.eq(db:current_version(), 2)
			local u = User:find(1)
			T.ok(u.bio == nil)
		end)

		T.it("migrations apply in version order", function()
			local db, User = make_db()
			local order = {}

			db:migrate({
				{ version = 2, up = function() order[#order + 1] = 2 end },
				{ version = 1, up = function() order[#order + 1] = 1 end },
				{ version = 3, up = function() order[#order + 1] = 3 end },
			})

			T.eq(order[1], 1)
			T.eq(order[2], 2)
			T.eq(order[3], 3)
		end)

		T.it("already-applied migrations are skipped on re-run", function()
			local db, User = make_db()
			local count = 0

			local migrations = {
				{ version = 1, up = function() count = count + 1 end },
			}
			db:migrate(migrations)
			db:migrate(migrations)  -- second call should not re-apply

			T.eq(count, 1)
		end)

		T.it("rollback applies down migration", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })

			local migrations = {
				{ version = 1,
					up   = function(schema) schema:add_column("users", "bio", { type = "string", default = "" }) end,
					down = function(schema) schema:remove_column("users", "bio") end,
				},
			}
			db:migrate(migrations)
			T.eq(db:current_version(), 1)

			db:rollback(migrations, 0)
			T.eq(db:current_version(), 0)

			local u = User:find(1)
			T.ok(u.bio == nil)
		end)
	end)

	-- ── dump / load ───────────────────────────────────────────────────────────
	T.describe("dump / load", function()
		T.it("dump returns a plain Lua table", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			local d = db:dump()
			T.eq(type(d), "table")
			T.eq(type(d.storage), "table")
			T.eq(type(d.next_id), "table")
		end)

		T.it("load restores records", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			User:create({ name = "Bob",   email = "b@x.com" })

			local dump = db:dump()
			local db2 = ORM.load(dump)

			-- Re-register same model on new db
			local User2 = db2:model("users", {
				fields = {
					id     = { type = "integer", primary_key = true, auto_increment = true },
					name   = { type = "string",  required = true, max_length = 100 },
					email  = { type = "string",  required = true, unique = true },
					age    = { type = "integer", default = 0 },
					active = { type = "boolean", default = true },
				},
			})

			T.eq(User2:count(), 2)
			local a = User2:find_by({ email = "a@x.com" })
			T.ok(a ~= nil)
			T.eq(a.name, "Alice")
		end)

		T.it("auto-increment continues from saved next_id", function()
			local db, User = make_db()
			User:create({ name = "Alice", email = "a@x.com" })
			local dump = db:dump()

			local db2 = ORM.load(dump)
			local User2 = db2:model("users", {
				fields = {
					id     = { type = "integer", primary_key = true, auto_increment = true },
					name   = { type = "string",  required = true },
					email  = { type = "string",  required = true, unique = true },
				},
			})
			local u2 = User2:create({ name = "Bob", email = "b@x.com" })
			T.eq(u2.id, 2)
		end)

		T.it("dump is independent (mutations don't affect dump)", function()
			local db, User = make_db()
			local u = User:create({ name = "Alice", email = "a@x.com" })
			local dump = db:dump()

			-- Mutate original
			u:update({ name = "Alice Changed" })

			-- Dump should still have original
			T.eq(dump.storage["users"][1].name, "Alice")
		end)
	end)

end)
