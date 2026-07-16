-- lib/sqlite/fts5.lua
-- FTS5 full-text search support for lib/sqlite/.
--
-- Provides parameterized FTS5 virtual table creation (standalone, external
-- content, and contentless modes), data manipulation, ranked search with a
-- normalized result interface, a raw sqlite-native iterator, and maintenance
-- commands (rebuild/optimize/merge).

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── types ────────────────────────────────────────────────────────────────────

--:: Db = { execute: (self: Db, sql: string, ...unknown) -> (boolean | nil, string | nil), query: (self: Db, sql: string, ...unknown) -> ((() -> unknown) | nil, string | nil), ... }
--:: tokenizer_opts = { name: string | nil, base: string | nil, remove_diacritics: number | nil, separators: string | nil, token_chars: string | nil, case_sensitive: boolean | nil }
--:: fts5_create_opts = { columns: { [integer]: string }, mode: string | nil, content_table: string | nil, content_rowid: string | nil, tokenizer: tokenizer_opts | nil, prefix: { [integer]: integer } | nil, column_size: boolean | nil, detail: string | nil }
--:: search_opts = { limit: number | nil, offset: number | nil, column_weights: { [integer]: number } | nil }
--:: search_result = { id: number, score: number }
--:: search_results = { results: { [integer]: search_result }, total: number }
--:: match_opts = { limit: number | nil, columns: { [integer]: string } | nil }

-- ── identifier validation ────────────────────────────────────────────────────

--: (string) -> boolean
local function is_valid_ident(name)
	return type(name) == "string" and name:match("^[%a_][%w_]*$") ~= nil
end

--: (string) -> string
local function quote_ident(name)
	local escaped = name:gsub('"', '""') --: string
	return '"' .. escaped .. '"'
end

-- ── tokenizer options -> FTS5 clause ─────────────────────────────────────────

-- Converts typed tokenizer options into the space-separated string FTS5
-- expects inside tokenize='...'.
--
-- opts.name:              "unicode61" | "ascii" | "porter" | "trigram"
--                         (default "unicode61")
-- opts.base:              base tokenizer for porter wrapping (e.g. "unicode61")
-- opts.remove_diacritics: 0 | 1 | 2
-- opts.separators:        string of additional separator characters
-- opts.token_chars:       string of characters to keep as part of tokens
-- opts.case_sensitive:    boolean (trigram only)

--: (tokenizer_opts) -> string
local function tokenizer_to_clause(opts)
	local parts = {} --: { [integer]: string }
	local name = opts.name or "unicode61"
	parts[#parts + 1] = name
	if name == "porter" and opts.base then
		parts[#parts + 1] = opts.base
	end
	if opts.remove_diacritics ~= nil then
		parts[#parts + 1] = "remove_diacritics"
		parts[#parts + 1] = tostring(opts.remove_diacritics)
	end
	if opts.separators then
		parts[#parts + 1] = "separators"
		local sep_escaped = opts.separators:gsub('"', '""') --: string
		parts[#parts + 1] = '"' .. sep_escaped .. '"'
	end
	if opts.token_chars then
		parts[#parts + 1] = "tokenchars"
		local tc_escaped = opts.token_chars:gsub('"', '""') --: string
		parts[#parts + 1] = '"' .. tc_escaped .. '"'
	end
	if opts.case_sensitive ~= nil then
		parts[#parts + 1] = "case_sensitive"
		parts[#parts + 1] = opts.case_sensitive and "1" or "0"
	end
	return table.concat(parts, " ")
end

-- ── table management ─────────────────────────────────────────────────────────

-- Create an FTS5 virtual table.
--
-- opts.columns:       column names (required, non-empty)
-- opts.mode:          "standalone" | "external" | "contentless" (default
--                     "standalone")
-- opts.content_table: source table name (required for "external" mode)
-- opts.content_rowid: source table rowid column (for "external" mode)
-- opts.tokenizer:     tokenizer_opts table
-- opts.prefix:        list of prefix index lengths (e.g. {2, 3})
-- opts.column_size:   false to disable column size tracking
-- opts.detail:        "full" | "column" | "none"
--
--: (Db, string, fts5_create_opts) -> (boolean | nil, string | nil)
function M.create_table(db, name, opts)
	if not is_valid_ident(name) then
		return nil, "fts5: invalid table name: " .. tostring(name)
	end
	local columns = opts.columns
	if not columns or #columns == 0 then
		return nil, "fts5: columns required"
	end
	local parts = {} --: { [integer]: string }
	for i = 1, #columns do
		if not is_valid_ident(columns[i]) then
			return nil, "fts5: invalid column name: " .. tostring(columns[i])
		end
		parts[#parts + 1] = quote_ident(columns[i])
	end

	local mode = opts.mode or "standalone"
	if mode == "external" then
		if not opts.content_table then
			return nil, "fts5: content_table required for external mode"
		end
		if not is_valid_ident(opts.content_table) then
			return nil, "fts5: invalid content_table: " .. tostring(opts.content_table)
		end
		parts[#parts + 1] = "content='" .. opts.content_table .. "'"
		if opts.content_rowid then
			if not is_valid_ident(opts.content_rowid) then
				return nil, "fts5: invalid content_rowid: " .. tostring(opts.content_rowid)
			end
			parts[#parts + 1] = "content_rowid='" .. opts.content_rowid .. "'"
		end
	elseif mode == "contentless" then
		parts[#parts + 1] = "content=''"
	elseif mode ~= "standalone" then
		return nil, "fts5: invalid mode: " .. tostring(mode)
	end

	if opts.tokenizer then
		local tok = tokenizer_to_clause(opts.tokenizer)
		parts[#parts + 1] = "tokenize='" .. tok .. "'"
	end

	if opts.prefix and #opts.prefix > 0 then
		local pstrs = {} --: { [integer]: string }
		for i = 1, #opts.prefix do pstrs[i] = tostring(opts.prefix[i]) end
		parts[#parts + 1] = "prefix='" .. table.concat(pstrs, " ") .. "'"
	end

	if opts.column_size == false then
		parts[#parts + 1] = "columnsize=0"
	end

	if opts.detail then
		parts[#parts + 1] = "detail=" .. opts.detail
	end

	local sql = "CREATE VIRTUAL TABLE " .. quote_ident(name)
		.. " USING fts5(" .. table.concat(parts, ", ") .. ")"
	return db:execute(sql)
end

-- Drop an FTS5 virtual table.
--: (Db, string) -> (boolean | nil, string | nil)
function M.drop_table(db, name)
	if not is_valid_ident(name) then
		return nil, "fts5: invalid table name: " .. tostring(name)
	end
	return db:execute("DROP TABLE IF EXISTS " .. quote_ident(name))
end

-- ── data manipulation ────────────────────────────────────────────────────────

-- Insert a row into an FTS5 table.
-- columns: column names in declaration order (e.g. {"title", "body"})
-- values:  values parallel to columns
-- opts:    { rowid = integer } to set an explicit rowid (optional)
--: (Db, string, { [integer]: string }, { [integer]: string | number | nil }, { rowid: number | nil } | nil) -> (boolean | nil, string | nil)
function M.insert(db, table_name, columns, values, opts)
	if not is_valid_ident(table_name) then
		return nil, "fts5: invalid table name: " .. tostring(table_name)
	end
	local col_parts = {} --: { [integer]: string }
	local bind_vals = {} --: { [integer]: string | number | nil }
	local n = 0
	if opts and opts.rowid then
		n = 1
		col_parts[1] = "rowid"
		bind_vals[1] = opts.rowid
	end
	for i = 1, #columns do
		col_parts[n + i] = quote_ident(columns[i])
		bind_vals[n + i] = values[i]
	end
	local placeholders = {} --: { [integer]: string }
	for i = 1, #col_parts do placeholders[i] = "?" end
	local sql = "INSERT INTO " .. quote_ident(table_name)
		.. "(" .. table.concat(col_parts, ", ") .. ") VALUES("
		.. table.concat(placeholders, ", ") .. ")"
	return db:execute(sql, unpack(bind_vals, 1, #bind_vals))
end

-- Delete a row from a standalone FTS5 table by rowid.
--: (Db, string, number) -> (boolean | nil, string | nil)
function M.delete(db, table_name, rowid)
	if not is_valid_ident(table_name) then
		return nil, "fts5: invalid table name: " .. tostring(table_name)
	end
	return db:execute(
		"DELETE FROM " .. quote_ident(table_name) .. " WHERE rowid = ?", rowid
	)
end

-- Remove an entry from the FTS5 index (external/contentless mode).
-- Uses the FTS5 'delete' special command.  The old column values are required
-- so the index knows what to un-index.
-- columns:    column names in declaration order
-- rowid:      the rowid of the entry being removed
-- old_values: the column values that were previously indexed (parallel to
--             columns)
--: (Db, string, { [integer]: string }, number, { [integer]: string | number | nil }) -> (boolean | nil, string | nil)
function M.remove_entry(db, table_name, columns, rowid, old_values)
	if not is_valid_ident(table_name) then
		return nil, "fts5: invalid table name: " .. tostring(table_name)
	end
	local qt = quote_ident(table_name)
	local col_parts = { qt, "rowid" } --: { [integer]: string }
	local bind_vals = { "delete", rowid } --: { [integer]: string | number | nil }
	for i = 1, #columns do
		col_parts[#col_parts + 1] = quote_ident(columns[i])
		bind_vals[#bind_vals + 1] = old_values[i]
	end
	local placeholders = {} --: { [integer]: string }
	for i = 1, #bind_vals do placeholders[i] = "?" end
	local sql = "INSERT INTO " .. qt .. "(" .. table.concat(col_parts, ", ")
		.. ") VALUES(" .. table.concat(placeholders, ", ") .. ")"
	return db:execute(sql, unpack(bind_vals, 1, #bind_vals))
end

-- ── search ───────────────────────────────────────────────────────────────────

-- Search an FTS5 table, returning normalized results.
--
-- query_text: FTS5 match expression (e.g. "hello world", "hello OR world",
--             "hello NEAR world")
-- opts.limit:          max results to return (default 20)
-- opts.offset:         result offset for pagination (default 0)
-- opts.column_weights: per-column bm25 weights (e.g. {10.0, 1.0} to weight
--                      column 0 ten times higher than column 1)
--
-- Returns { results = {{id = rowid, score = number}}, total = total_matches }
-- Score follows "higher = better" convention (FTS5 bm25 negated).
--: (Db, string, string, search_opts | nil) -> (search_results | nil, string | nil)
function M.search(db, table_name, query_text, opts)
	if not is_valid_ident(table_name) then
		return nil, "fts5: invalid table name: " .. tostring(table_name)
	end
	local limit = (opts and opts.limit) or 20
	local offset = (opts and opts.offset) or 0
	local qt = quote_ident(table_name)

	-- Count total matches
	local count_sql = "SELECT count(*) FROM " .. qt
		.. " WHERE " .. qt .. " MATCH ?"
	local count_iter, count_err = db:query(count_sql, query_text)
	if not count_iter then return nil, count_err end
	local total_raw = count_iter()
	local total = tonumber(total_raw) or 0
	if total == 0 then
		return { results = {}, total = 0 }
	end

	-- Build ranking expression
	local rank_expr = "rank"
	local column_weights = opts and opts.column_weights
	if column_weights and #column_weights > 0 then
		local w = {} --: { [integer]: string }
		for i = 1, #column_weights do
			w[i] = tostring(column_weights[i])
		end
		rank_expr = "bm25(" .. qt .. ", " .. table.concat(w, ", ") .. ")"
	end

	local sql = "SELECT rowid, " .. rank_expr .. " AS s FROM " .. qt
		.. " WHERE " .. qt .. " MATCH ? ORDER BY s LIMIT ? OFFSET ?"
	local iter, err = db:query(sql, query_text, limit, offset)
	if not iter then return nil, err end

	local results = {} --: { [integer]: search_result }
	while true do
		local rowid_raw, score_raw = iter()
		if rowid_raw == nil then break end
		local rowid = tonumber(rowid_raw) or 0
		local score = tonumber(score_raw) or 0
		-- FTS5 bm25 returns negative values (lower = better match); negate
		-- for the "higher = better" convention used by lib/search/.
		results[#results + 1] = { id = rowid, score = -score }
	end

	return { results = results, total = total }
end

-- Raw match query returning an iterator (sqlite-native interface).
-- Each iterator call yields (rowid, rank, col1, col2, ...) or nil when done.
-- opts.limit:   max rows to return
-- opts.columns: column names to include in results after rowid and rank
--: (Db, string, string, match_opts | nil) -> ((() -> unknown) | nil, string | nil)
function M.match_rows(db, table_name, query_text, opts)
	if not is_valid_ident(table_name) then
		return nil, "fts5: invalid table name: " .. tostring(table_name)
	end
	local qt = quote_ident(table_name)
	local select_parts = { "rowid", "rank" } --: { [integer]: string }
	local match_columns = opts and opts.columns
	if match_columns then
		for i = 1, #match_columns do
			select_parts[#select_parts + 1] = quote_ident(match_columns[i])
		end
	end
	local sql = "SELECT " .. table.concat(select_parts, ", ") .. " FROM " .. qt
		.. " WHERE " .. qt .. " MATCH ? ORDER BY rank"
	local match_limit = opts and opts.limit
	if match_limit then
		sql = sql .. " LIMIT " .. tostring(match_limit)
	end
	return db:query(sql, query_text)
end

-- ── maintenance ──────────────────────────────────────────────────────────────

-- Rebuild the FTS5 index from the content table (external mode) or
-- re-index all content (standalone mode).
--: (Db, string) -> (boolean | nil, string | nil)
function M.rebuild(db, table_name)
	if not is_valid_ident(table_name) then
		return nil, "fts5: invalid table name: " .. tostring(table_name)
	end
	local qt = quote_ident(table_name)
	return db:execute("INSERT INTO " .. qt .. "(" .. qt .. ") VALUES('rebuild')")
end

-- Merge all FTS5 index segments into a single segment for optimal query
-- performance.
--: (Db, string) -> (boolean | nil, string | nil)
function M.optimize(db, table_name)
	if not is_valid_ident(table_name) then
		return nil, "fts5: invalid table name: " .. tostring(table_name)
	end
	local qt = quote_ident(table_name)
	return db:execute("INSERT INTO " .. qt .. "(" .. qt .. ") VALUES('optimize')")
end

-- Run an incremental merge of FTS5 index segments.
-- pages: approximate number of pages to merge in this step.
--: (Db, string, number) -> (boolean | nil, string | nil)
function M.merge(db, table_name, pages)
	if not is_valid_ident(table_name) then
		return nil, "fts5: invalid table name: " .. tostring(table_name)
	end
	local qt = quote_ident(table_name)
	return db:execute(
		"INSERT INTO " .. qt .. "(" .. qt .. ", rank) VALUES('merge', "
			.. tostring(pages) .. ")"
	)
end

return M
