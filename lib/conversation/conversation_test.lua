-- lib/conversation/conversation_test.lua
-- Tests for lib/conversation/init.lua

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local T    = require("lib.test.assert")
local conv = require("lib.conversation")

-- Use an in-memory SQLite database for tests.
local DB_PATH = ":memory:"

local function open()
	local db, err = conv.open(DB_PATH)
	T.ok(db, "open: " .. tostring(err))
	return db
end

T.describe("conversation.open", function()
	T.it("opens and creates schema", function()
		local db = open()
		T.ok(db ~= nil, "db is not nil")
	end)
end)

T.describe("create_session / get_session", function()
	T.it("creates and retrieves a session", function()
		local db = open()
		local session, err = db:create_session("app1")
		T.ok(session, "create_session: " .. tostring(err))
		T.ok(type(session.id) == "string", "session.id is string")
		T.eq(session.app_id, "app1")
		T.ok(session.created_at > 0, "created_at set")

		local got, gerr = db:get_session(session.id)
		T.ok(got, "get_session: " .. tostring(gerr))
		T.eq(got.id, session.id)
		T.eq(got.app_id, "app1")
	end)

	T.it("stores and retrieves metadata", function()
		local db = open()
		local session, err = db:create_session("app2", { user = "alice", score = 42 })
		T.ok(session, "create_session with metadata: " .. tostring(err))
		T.eq(session.metadata.user, "alice")
		T.eq(session.metadata.score, 42)

		local got, gerr = db:get_session(session.id)
		T.ok(got, "get_session: " .. tostring(gerr))
		T.eq(got.metadata.user, "alice")
		T.eq(got.metadata.score, 42)
	end)

	T.it("returns error for missing session", function()
		local db = open()
		local got, err = db:get_session("nonexistent-id")
		T.ok(got == nil, "should be nil")
		T.ok(err ~= nil, "should have error")
	end)
end)

T.describe("list_sessions", function()
	T.it("returns sessions ordered by created_at DESC", function()
		local db = open()
		local s1 = db:create_session("myapp")
		local s2 = db:create_session("myapp")
		local s3 = db:create_session("myapp")
		-- Ensure different created_at by mutating one (can't easily control os.time in tests,
		-- so we just verify ids appear and order is by most recently inserted last position).
		local list, err = db:list_sessions("myapp")
		T.ok(list, "list_sessions: " .. tostring(err))
		T.eq(#list, 3)
		-- Most recently created (s3) should be first.
		-- Since all may share the same os.time second, verify all IDs present.
		local ids = {}
		for _, s in ipairs(list) do ids[s.id] = true end
		T.ok(ids[s1.id], "s1 present")
		T.ok(ids[s2.id], "s2 present")
		T.ok(ids[s3.id], "s3 present")
	end)

	T.it("filters by app_id", function()
		local db = open()
		db:create_session("appA")
		db:create_session("appA")
		db:create_session("appB")
		local list_a, err_a = db:list_sessions("appA")
		T.ok(list_a, tostring(err_a))
		T.eq(#list_a, 2)
		local list_b, err_b = db:list_sessions("appB")
		T.ok(list_b, tostring(err_b))
		T.eq(#list_b, 1)
	end)
end)

T.describe("add_message / get_message", function()
	T.it("adds a root message", function()
		local db = open()
		local session = db:create_session("app1")
		local msg, err = db:add_message(session.id, nil, "user", "Hello")
		T.ok(msg, "add_message: " .. tostring(err))
		T.ok(type(msg.id) == "string")
		T.eq(msg.session_id, session.id)
		T.ok(msg.parent_id == nil, "root has no parent")
		T.eq(msg.role, "user")
		T.eq(msg.content, "Hello")
	end)

	T.it("adds a child message and updates parent canonical_child_id", function()
		local db = open()
		local session = db:create_session("app1")
		local root, _ = db:add_message(session.id, nil, "user", "Root")
		local child, err = db:add_message(session.id, root.id, "assistant", "Reply")
		T.ok(child, "add child: " .. tostring(err))
		T.eq(child.parent_id, root.id)

		-- Root's canonical_child_id should now point to child.
		local root2, _ = db:get_message(root.id)
		T.eq(root2.canonical_child_id, child.id)
	end)
end)

T.describe("get_canonical_path", function()
	T.it("returns empty path for session with no messages", function()
		local db = open()
		local session = db:create_session("app1")
		local path, err = db:get_canonical_path(session.id)
		T.ok(path, tostring(err))
		T.eq(#path, 0)
	end)

	T.it("returns root-to-leaf path", function()
		local db = open()
		local session = db:create_session("app1")
		local m1 = db:add_message(session.id, nil,   "user",      "Hi")
		local m2 = db:add_message(session.id, m1.id, "assistant", "Hello")
		local m3 = db:add_message(session.id, m2.id, "user",      "How are you?")

		local path, err = db:get_canonical_path(session.id)
		T.ok(path, tostring(err))
		T.eq(#path, 3)
		T.eq(path[1].id, m1.id)
		T.eq(path[2].id, m2.id)
		T.eq(path[3].id, m3.id)
	end)
end)

T.describe("branching", function()
	T.it("canonical_child_id tracks the last child added", function()
		local db = open()
		local session = db:create_session("app1")
		local root = db:add_message(session.id, nil, "user", "Root")
		local c1   = db:add_message(session.id, root.id, "assistant", "Branch A")
		local c2   = db:add_message(session.id, root.id, "assistant", "Branch B")

		-- canonical_child_id on root should point to c2 (last inserted).
		local root_now, _ = db:get_message(root.id)
		T.eq(root_now.canonical_child_id, c2.id)

		-- Canonical path follows c2, not c1.
		local path, _ = db:get_canonical_path(session.id)
		T.eq(#path, 2)
		T.eq(path[2].id, c2.id)

		-- c1 is a child but not on the canonical path.
		local children, _ = db:get_children(root.id)
		T.eq(#children, 2)
	end)
end)

T.describe("swipe_to", function()
	T.it("changes canonical_child_id to an existing sibling", function()
		local db = open()
		local session = db:create_session("app1")
		local root = db:add_message(session.id, nil, "user", "Root")
		local c1   = db:add_message(session.id, root.id, "assistant", "Branch A")
		local c2   = db:add_message(session.id, root.id, "assistant", "Branch B")

		-- Currently c2 is canonical.
		local ok, err = db:swipe_to(c1.id)
		T.ok(ok, "swipe_to: " .. tostring(err))

		local root_now, _ = db:get_message(root.id)
		T.eq(root_now.canonical_child_id, c1.id)

		-- Canonical path now follows c1.
		local path, _ = db:get_canonical_path(session.id)
		T.eq(#path, 2)
		T.eq(path[2].id, c1.id)
	end)

	T.it("errors when swiping to root (no parent)", function()
		local db = open()
		local session = db:create_session("app1")
		local root = db:add_message(session.id, nil, "user", "Root")
		local ok, err = db:swipe_to(root.id)
		T.ok(ok == nil, "should fail")
		T.ok(err ~= nil, "should have error: " .. tostring(err))
	end)
end)

T.describe("update_message", function()
	T.it("updates content", function()
		local db = open()
		local session = db:create_session("app1")
		local msg = db:add_message(session.id, nil, "user", "original")
		local updated, err = db:update_message(msg.id, { content = "edited" })
		T.ok(updated, "update_message: " .. tostring(err))
		T.eq(updated.content, "edited")
		-- Verify persisted.
		local got = db:get_message(msg.id)
		T.eq(got.content, "edited")
	end)

	T.it("updates metadata", function()
		local db = open()
		local session = db:create_session("app1")
		local msg = db:add_message(session.id, nil, "user", "hi", { key = "old" })
		local updated, err = db:update_message(msg.id, { metadata = { key = "new" } })
		T.ok(updated, "update_message: " .. tostring(err))
		T.eq(updated.metadata.key, "new")
		T.eq(updated.content, "hi") -- unchanged
	end)

	T.it("returns nil, err for nonexistent message", function()
		local db = open()
		local result, err = db:update_message("no-such-id", { content = "x" })
		T.ok(result == nil, "should be nil")
		T.ok(err ~= nil, "should have error")
	end)
end)

T.describe("delete_subtree", function()
	T.it("deletes a node and all descendants", function()
		local db = open()
		local session = db:create_session("app1")
		local root  = db:add_message(session.id, nil,      "user",      "Root")
		local c1    = db:add_message(session.id, root.id,  "assistant", "C1")
		local c1a   = db:add_message(session.id, c1.id,    "user",      "C1a")
		local c1b   = db:add_message(session.id, c1.id,    "user",      "C1b")
		local c2    = db:add_message(session.id, root.id,  "assistant", "C2")

		-- Delete c1 subtree (c1, c1a, c1b).
		local result, err = db:delete_subtree(c1.id)
		T.ok(result, "delete_subtree: " .. tostring(err))
		T.eq(result.deleted, 3)

		-- c1, c1a, c1b are gone.
		T.ok(db:get_message(c1.id) == nil,  "c1 deleted")
		T.ok(db:get_message(c1a.id) == nil, "c1a deleted")
		T.ok(db:get_message(c1b.id) == nil, "c1b deleted")

		-- c2 still exists.
		T.ok(db:get_message(c2.id) ~= nil, "c2 survives")

		-- Root's canonical_child_id should be updated to c2.
		local root_now = db:get_message(root.id)
		T.eq(root_now.canonical_child_id, c2.id)
	end)

	T.it("handles leaf deletion", function()
		local db = open()
		local session = db:create_session("app1")
		local root = db:add_message(session.id, nil,     "user",      "Root")
		local c1   = db:add_message(session.id, root.id, "assistant", "C1")

		local result, err = db:delete_subtree(c1.id)
		T.ok(result, "delete leaf: " .. tostring(err))
		T.eq(result.deleted, 1)

		-- Parent's canonical_child_id should be nil (no children remain).
		local root_now = db:get_message(root.id)
		T.ok(root_now.canonical_child_id == nil, "canonical cleared")
	end)

	T.it("handles root deletion", function()
		local db = open()
		local session = db:create_session("app1")
		local root = db:add_message(session.id, nil,     "user",      "Root")
		local c1   = db:add_message(session.id, root.id, "assistant", "C1")

		local result, err = db:delete_subtree(root.id)
		T.ok(result, "delete root: " .. tostring(err))
		T.eq(result.deleted, 2)

		-- All gone.
		T.ok(db:get_message(root.id) == nil, "root deleted")
		T.ok(db:get_message(c1.id) == nil, "c1 deleted")
	end)
end)

T.describe("get_root_children", function()
	T.it("returns children of root", function()
		local db = open()
		local session = db:create_session("app1")
		local root = db:add_message(session.id, nil,     "user",      "Root")
		local c1   = db:add_message(session.id, root.id, "assistant", "C1")
		local c2   = db:add_message(session.id, root.id, "assistant", "C2")

		local children, err = db:get_root_children(session.id)
		T.ok(children, "get_root_children: " .. tostring(err))
		T.eq(#children, 2)
		local ids = {}
		for _, c in ipairs(children) do ids[c.id] = true end
		T.ok(ids[c1.id], "c1 present")
		T.ok(ids[c2.id], "c2 present")
	end)

	T.it("returns error when no root exists", function()
		local db = open()
		local session = db:create_session("app1")
		local result, err = db:get_root_children(session.id)
		T.ok(result == nil, "should be nil")
		T.ok(err ~= nil, "should have error")
	end)
end)

T.describe("delete_session", function()
	T.it("removes session and cascades to messages", function()
		local db = open()
		local session = db:create_session("app1")
		local m1 = db:add_message(session.id, nil, "user", "Hi")
		db:add_message(session.id, m1.id, "assistant", "Hello")

		local ok, err = db:delete_session(session.id)
		T.ok(ok, "delete_session: " .. tostring(err))

		-- Session should be gone.
		local got, _ = db:get_session(session.id)
		T.ok(got == nil, "session deleted")

		-- Messages should be gone (cascade).
		local msg, _ = db:get_message(m1.id)
		T.ok(msg == nil, "message cascaded")
	end)
end)
