-- lib/sqlite/fts5_test.lua
-- Tests for lib/sqlite/fts5 (FTS5 full-text search support).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local ok_load, sqlite = pcall(require, "lib.sqlite")
if not ok_load then
	T.describe("fts5: load", function()
		T.it("sqlite module loaded", function()
			error("lib.sqlite failed to load: " .. tostring(sqlite))
		end)
	end)
	return
end

local ok_fts5, fts5 = pcall(require, "lib.sqlite.fts5")
if not ok_fts5 then
	T.describe("fts5: load", function()
		T.it("fts5 module loaded", function()
			error("lib.sqlite.fts5 failed to load: " .. tostring(fts5))
		end)
	end)
	return
end

-- ── helpers ──────────────────────────────────────────────────────────────────

local function mem()
	local db, err = sqlite.open(":memory:")
	assert(db, "sqlite.open(:memory:) failed: " .. tostring(err))
	return db
end

-- ── create_table ─────────────────────────────────────────────────────────────

T.describe("fts5: create_table", function()
	T.it("creates a standalone FTS5 table", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "docs", {
			columns = { "title", "body" },
		})
		T.ok(ok, err)
	end)

	T.it("creates a contentless FTS5 table", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "idx", {
			columns = { "content" },
			mode = "contentless",
		})
		T.ok(ok, err)
	end)

	T.it("creates an external content FTS5 table", function()
		local db = mem()
		db:execute("CREATE TABLE source (id INTEGER PRIMARY KEY, title TEXT, body TEXT)")
		local ok, err = fts5.create_table(db, "source_fts", {
			columns = { "title", "body" },
			mode = "external",
			content_table = "source",
			content_rowid = "id",
		})
		T.ok(ok, err)
	end)

	T.it("creates with tokenizer options", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "docs", {
			columns = { "body" },
			tokenizer = { name = "porter", base = "unicode61" },
		})
		T.ok(ok, err)
	end)

	T.it("creates with prefix index", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "docs", {
			columns = { "body" },
			prefix = { 2, 3 },
		})
		T.ok(ok, err)
	end)

	T.it("returns nil + error for missing columns", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "docs", { columns = {} })
		T.fail(ok)
		T.ok(err)
	end)

	T.it("returns nil + error for invalid table name", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "bad name!", { columns = { "a" } })
		T.fail(ok)
		T.ok(err)
	end)

	T.it("returns nil + error for invalid column name", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "docs", { columns = { "ok", "bad name" } })
		T.fail(ok)
		T.ok(err)
	end)

	T.it("returns nil + error for invalid mode", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "docs", {
			columns = { "a" },
			mode = "invalid",
		})
		T.fail(ok)
		T.ok(err)
	end)

	T.it("returns nil + error for external mode without content_table", function()
		local db = mem()
		local ok, err = fts5.create_table(db, "docs", {
			columns = { "a" },
			mode = "external",
		})
		T.fail(ok)
		T.ok(err)
	end)
end)

-- ── drop_table ───────────────────────────────────────────────────────────────

T.describe("fts5: drop_table", function()
	T.it("drops an existing FTS5 table", function()
		local db = mem()
		fts5.create_table(db, "docs", { columns = { "body" } })
		local ok, err = fts5.drop_table(db, "docs")
		T.ok(ok, err)
	end)

	T.it("succeeds even if table does not exist", function()
		local db = mem()
		local ok, err = fts5.drop_table(db, "nonexistent")
		T.ok(ok, err)
	end)
end)

-- ── insert + search ──────────────────────────────────────────────────────────

T.describe("fts5: insert and search", function()
	T.it("inserts and finds a single document", function()
		local db = mem()
		local cols = { "title", "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "Hello World", "This is a test document" })

		local res, err = fts5.search(db, "docs", "test")
		T.ok(res, err)
		T.eq(res.total, 1)
		T.eq(#res.results, 1)
		T.ok(res.results[1].id)
		T.ok(res.results[1].score > 0, "score should be positive")
	end)

	T.it("finds multiple documents ranked by relevance", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "apple banana cherry" })
		fts5.insert(db, "docs", cols, { "apple apple apple" })
		fts5.insert(db, "docs", cols, { "banana cherry date" })

		local res, err = fts5.search(db, "docs", "apple")
		T.ok(res, err)
		T.eq(res.total, 2)
		T.eq(#res.results, 2)
		-- The doc with more "apple" occurrences should rank higher
		T.ok(res.results[1].score >= res.results[2].score)
	end)

	T.it("returns empty results for no matches", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "hello world" })

		local res, err = fts5.search(db, "docs", "nonexistent")
		T.ok(res, err)
		T.eq(res.total, 0)
		T.eq(#res.results, 0)
	end)

	T.it("insert with explicit rowid", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "hello" }, { rowid = 42 })

		local res, err = fts5.search(db, "docs", "hello")
		T.ok(res, err)
		T.eq(res.results[1].id, 42)
	end)
end)

-- ── search options ───────────────────────────────────────────────────────────

T.describe("fts5: search options", function()
	T.it("limit restricts result count", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		for i = 1, 10 do
			fts5.insert(db, "docs", cols, { "test document number " .. i })
		end

		local res, err = fts5.search(db, "docs", "test", { limit = 3 })
		T.ok(res, err)
		T.eq(res.total, 10)
		T.eq(#res.results, 3)
	end)

	T.it("offset skips results", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		for i = 1, 5 do
			fts5.insert(db, "docs", cols, { "test " .. i }, { rowid = i })
		end

		local res, err = fts5.search(db, "docs", "test", { limit = 2, offset = 3 })
		T.ok(res, err)
		T.eq(res.total, 5)
		T.eq(#res.results, 2)
	end)

	T.it("column_weights adjusts ranking", function()
		local db = mem()
		local cols = { "title", "body" }
		fts5.create_table(db, "docs", { columns = cols })
		-- Doc 1: "apple" in title only
		fts5.insert(db, "docs", cols, { "apple", "nothing here" }, { rowid = 1 })
		-- Doc 2: "apple" in body only
		fts5.insert(db, "docs", cols, { "nothing here", "apple" }, { rowid = 2 })

		-- Weight title 10x higher than body
		local res, err = fts5.search(db, "docs", "apple", {
			column_weights = { 10.0, 1.0 },
		})
		T.ok(res, err)
		T.eq(#res.results, 2)
		-- Title match (doc 1) should score higher
		T.eq(res.results[1].id, 1)
	end)
end)

-- ── delete ───────────────────────────────────────────────────────────────────

T.describe("fts5: delete (standalone)", function()
	T.it("removes a row by rowid", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "hello world" }, { rowid = 1 })
		fts5.insert(db, "docs", cols, { "goodbye world" }, { rowid = 2 })

		fts5.delete(db, "docs", 1)

		local res, err = fts5.search(db, "docs", "hello")
		T.ok(res, err)
		T.eq(res.total, 0)

		local res2, err2 = fts5.search(db, "docs", "goodbye")
		T.ok(res2, err2)
		T.eq(res2.total, 1)
	end)
end)

-- ── remove_entry (external content) ──────────────────────────────────────────

T.describe("fts5: remove_entry (external content)", function()
	T.it("removes an index entry using the FTS5 delete command", function()
		local db = mem()
		db:execute("CREATE TABLE source (id INTEGER PRIMARY KEY, body TEXT)")
		db:execute("INSERT INTO source VALUES (1, 'hello world')")
		db:execute("INSERT INTO source VALUES (2, 'goodbye world')")

		local cols = { "body" }
		fts5.create_table(db, "source_fts", {
			columns = cols,
			mode = "external",
			content_table = "source",
			content_rowid = "id",
		})
		-- Populate the FTS index
		fts5.insert(db, "source_fts", cols, { "hello world" }, { rowid = 1 })
		fts5.insert(db, "source_fts", cols, { "goodbye world" }, { rowid = 2 })

		-- Remove entry for row 1
		fts5.remove_entry(db, "source_fts", cols, 1, { "hello world" })

		local res, err = fts5.search(db, "source_fts", "hello")
		T.ok(res, err)
		T.eq(res.total, 0)

		local res2, err2 = fts5.search(db, "source_fts", "goodbye")
		T.ok(res2, err2)
		T.eq(res2.total, 1)
	end)
end)

-- ── match_rows ───────────────────────────────────────────────────────────────

T.describe("fts5: match_rows", function()
	T.it("returns raw rows with rowid and rank", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "hello world" }, { rowid = 1 })

		local iter, err = fts5.match_rows(db, "docs", "hello")
		T.ok(iter, err)
		local rowid, rank = iter()
		T.eq(rowid, 1)
		T.ok(type(rank) == "number")
	end)

	T.it("returns column values when requested", function()
		local db = mem()
		local cols = { "title", "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "My Title", "Some body text" }, { rowid = 1 })

		local iter, err = fts5.match_rows(db, "docs", "body", {
			columns = { "title", "body" },
		})
		T.ok(iter, err)
		local rowid, rank, title, body = iter()
		T.eq(rowid, 1)
		T.ok(type(rank) == "number")
		T.eq(title, "My Title")
		T.eq(body, "Some body text")
	end)

	T.it("limit restricts rows", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		for i = 1, 5 do
			fts5.insert(db, "docs", cols, { "test " .. i })
		end

		local iter, err = fts5.match_rows(db, "docs", "test", { limit = 2 })
		T.ok(iter, err)
		local count = 0
		while true do
			local rowid = iter()
			if rowid == nil then break end
			count = count + 1
		end
		T.eq(count, 2)
	end)
end)

-- ── maintenance ──────────────────────────────────────────────────────────────

T.describe("fts5: maintenance", function()
	T.it("rebuild succeeds", function()
		local db = mem()
		fts5.create_table(db, "docs", { columns = { "body" } })
		fts5.insert(db, "docs", { "body" }, { "hello" })
		local ok, err = fts5.rebuild(db, "docs")
		T.ok(ok, err)
	end)

	T.it("optimize succeeds", function()
		local db = mem()
		fts5.create_table(db, "docs", { columns = { "body" } })
		fts5.insert(db, "docs", { "body" }, { "hello" })
		local ok, err = fts5.optimize(db, "docs")
		T.ok(ok, err)
	end)

	T.it("merge succeeds", function()
		local db = mem()
		fts5.create_table(db, "docs", { columns = { "body" } })
		fts5.insert(db, "docs", { "body" }, { "hello" })
		local ok, err = fts5.merge(db, "docs", 10)
		T.ok(ok, err)
	end)

	T.it("rebuild re-indexes external content", function()
		local db = mem()
		db:execute("CREATE TABLE src (id INTEGER PRIMARY KEY, body TEXT)")
		db:execute("INSERT INTO src VALUES (1, 'alpha beta')")

		fts5.create_table(db, "src_fts", {
			columns = { "body" },
			mode = "external",
			content_table = "src",
			content_rowid = "id",
		})

		-- Before rebuild, the FTS index is empty
		local res1, err1 = fts5.search(db, "src_fts", "alpha")
		T.ok(res1, err1)
		T.eq(res1.total, 0)

		-- After rebuild, the FTS index reflects the content table
		fts5.rebuild(db, "src_fts")
		local res2, err2 = fts5.search(db, "src_fts", "alpha")
		T.ok(res2, err2)
		T.eq(res2.total, 1)
	end)
end)

-- ── FTS5 query syntax ────────────────────────────────────────────────────────

T.describe("fts5: query syntax", function()
	T.it("OR query matches documents with either term", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "apple pie" })
		fts5.insert(db, "docs", cols, { "banana split" })
		fts5.insert(db, "docs", cols, { "cherry tart" })

		local res, err = fts5.search(db, "docs", "apple OR banana")
		T.ok(res, err)
		T.eq(res.total, 2)
	end)

	T.it("phrase query matches exact phrases", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", { columns = cols })
		fts5.insert(db, "docs", cols, { "the quick brown fox" })
		fts5.insert(db, "docs", cols, { "quick the brown fox" })

		local res, err = fts5.search(db, "docs", '"quick brown"')
		T.ok(res, err)
		T.eq(res.total, 1)
	end)

	T.it("prefix query with *", function()
		local db = mem()
		local cols = { "body" }
		fts5.create_table(db, "docs", {
			columns = cols,
			prefix = { 3 },
		})
		fts5.insert(db, "docs", cols, { "testing tested tester" })
		fts5.insert(db, "docs", cols, { "something else" })

		local res, err = fts5.search(db, "docs", "test*")
		T.ok(res, err)
		T.eq(res.total, 1)
	end)
end)
