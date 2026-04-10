if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local sqlite = require("lib.sqlite")
local vec = require("lib.vec")
local json = require("lib.format.json")

local M = {}

--: (db: sqlite) -> search_index
local function make_index(db)
  local ok, err = db:execute([[
    CREATE TABLE IF NOT EXISTS _search_collections (
      name TEXT PRIMARY KEY,
      config TEXT NOT NULL
    )
  ]])
  if not ok then return nil, err end
  --: search_index
  local idx = { _db = db }
  setmetatable(idx, { __index = M })
  return idx
end

--: (path: string) -> search_index?, string?
function M.open(path)
  local db, err = sqlite.open(path)
  if not db then return nil, err end
  return make_index(db)
end

--: (db: sqlite) -> search_index?, string?
function M.wrap(db)
  return make_index(db)
end

--: (self: search_index, name: string, opts: { fields: {string}, vector_dims: number? }) -> true?, string?
function M.create_collection(self, name, opts)
  local db = self._db
  local fields = opts.fields
  if not fields or #fields == 0 then
    return nil, "search: create_collection: fields required"
  end

  local config = json.encode({
    fields = fields,
    vector_dims = opts.vector_dims,
  })

  -- store config
  local ok, err = db:execute(
    "INSERT INTO _search_collections (name, config) VALUES (?, ?)",
    name, config)
  if not ok then return nil, err end

  -- main document table
  local col_defs = { "id TEXT PRIMARY KEY", "meta TEXT" }
  for i = 1, #fields do
    col_defs[#col_defs + 1] = fields[i] .. " TEXT"
  end
  ok, err = db:execute(
    "CREATE TABLE _search_" .. name .. " (" .. table.concat(col_defs, ", ") .. ")")
  if not ok then return nil, err end

  -- FTS5 virtual table (external content)
  local fts_cols = {}
  for i = 1, #fields do
    fts_cols[i] = fields[i]
  end
  ok, err = db:execute(
    "CREATE VIRTUAL TABLE _search_" .. name .. "_fts USING fts5(" ..
    table.concat(fts_cols, ", ") ..
    ", content='_search_" .. name .. "', content_rowid='rowid')")
  if not ok then return nil, err end

  -- vector table (only if vector_dims specified)
  if opts.vector_dims then
    ok, err = db:execute(
      "CREATE TABLE _search_" .. name .. "_vectors (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
    if not ok then return nil, err end
  end

  return true
end

-- helper: load collection config
--: (self: search_index, name: string) -> { fields: {string}, vector_dims: number? }?, string?
local function get_config(self, name)
  local iter, err = self._db:query(
    "SELECT config FROM _search_collections WHERE name = ?", name)
  if not iter then return nil, err end
  local cfg_str = iter()
  if not cfg_str then return nil, "search: collection not found: " .. name end
  return json.decode(cfg_str)
end

-- helper: get rowid for a document id
--: (db: sqlite, name: string, doc_id: string) -> number?, string?
local function get_rowid(db, name, doc_id)
  local iter, err = db:query(
    "SELECT rowid FROM _search_" .. name .. " WHERE id = ?", doc_id)
  if not iter then return nil, err end
  local rowid = iter()
  if not rowid then return nil, "search: document not found: " .. doc_id end
  return rowid
end

--: (self: search_index, name: string, doc: table) -> true?, string?
function M.add(self, name, doc)
  local db = self._db
  local config, err = get_config(self, name)
  if not config then return nil, err end

  local fields = config.fields
  local cols = { "id", "meta" }
  local placeholders = { "?", "?" }
  local meta_str = doc.meta and json.encode(doc.meta) or ""
  local n_values = 2
  local values = {}
  values[1] = doc.id
  values[2] = meta_str
  for i = 1, #fields do
    cols[#cols + 1] = fields[i]
    placeholders[#placeholders + 1] = "?"
    n_values = n_values + 1
    values[n_values] = doc[fields[i]] or ""
  end

  local ok
  ok, err = db:execute(
    "INSERT INTO _search_" .. name .. " (" .. table.concat(cols, ", ") ..
    ") VALUES (" .. table.concat(placeholders, ", ") .. ")",
    unpack(values, 1, n_values))
  if not ok then return nil, err end

  -- sync FTS index
  local rowid
  rowid, err = get_rowid(db, name, doc.id)
  if not rowid then return nil, err end

  local fts_cols = {}
  local fts_placeholders = { "?" }
  local fts_values = { rowid }
  for i = 1, #fields do
    fts_cols[i] = fields[i]
    fts_placeholders[#fts_placeholders + 1] = "?"
    fts_values[#fts_values + 1] = doc[fields[i]] or ""
  end

  ok, err = db:execute(
    "INSERT INTO _search_" .. name .. "_fts (rowid, " .. table.concat(fts_cols, ", ") ..
    ") VALUES (" .. table.concat(fts_placeholders, ", ") .. ")",
    unpack(fts_values))
  if not ok then return nil, err end

  -- vector
  if doc.vector and config.vector_dims then
    local vec_json = json.encode(doc.vector)
    ok, err = db:execute(
      "INSERT INTO _search_" .. name .. "_vectors (id, data) VALUES (?, ?)",
      doc.id, vec_json)
    if not ok then return nil, err end
  end

  return true
end

--: (self: search_index, name: string, doc_id: string, updates: table) -> true?, string?
function M.update(self, name, doc_id, updates)
  local db = self._db
  local config, err = get_config(self, name)
  if not config then return nil, err end

  local fields = config.fields

  -- get old rowid for FTS delete
  local old_rowid
  old_rowid, err = get_rowid(db, name, doc_id)
  if not old_rowid then return nil, err end

  -- read old field values for FTS delete command
  local field_list = table.concat(fields, ", ")
  local iter
  iter, err = db:query(
    "SELECT " .. field_list .. " FROM _search_" .. name .. " WHERE id = ?", doc_id)
  if not iter then return nil, err end
  local old_values = { iter() }

  -- delete old FTS entry
  local fts_del_placeholders = { "?" }
  local fts_del_values = { old_rowid }
  for i = 1, #fields do
    fts_del_placeholders[#fts_del_placeholders + 1] = "?"
    fts_del_values[#fts_del_values + 1] = old_values[i] or ""
  end
  local ok
  ok, err = db:execute(
    "INSERT INTO _search_" .. name .. "_fts (_search_" .. name .. "_fts, rowid, " ..
    field_list .. ") VALUES ('delete', " .. table.concat(fts_del_placeholders, ", ") .. ")",
    unpack(fts_del_values))
  if not ok then return nil, err end

  -- update main table
  local set_parts = {}
  local set_values = {}
  for k, v in pairs(updates) do
    if k ~= "id" and k ~= "vector" and k ~= "meta" then
      set_parts[#set_parts + 1] = k .. " = ?"
      set_values[#set_values + 1] = v
    end
  end
  if updates.meta ~= nil then
    set_parts[#set_parts + 1] = "meta = ?"
    set_values[#set_values + 1] = json.encode(updates.meta)
  end
  if #set_parts > 0 then
    set_values[#set_values + 1] = doc_id
    ok, err = db:execute(
      "UPDATE _search_" .. name .. " SET " .. table.concat(set_parts, ", ") .. " WHERE id = ?",
      unpack(set_values))
    if not ok then return nil, err end
  end

  -- re-read new values for FTS insert
  iter, err = db:query(
    "SELECT " .. field_list .. " FROM _search_" .. name .. " WHERE id = ?", doc_id)
  if not iter then return nil, err end
  local new_values = { iter() }

  local fts_ins_placeholders = { "?" }
  local fts_ins_values = { old_rowid }
  for i = 1, #fields do
    fts_ins_placeholders[#fts_ins_placeholders + 1] = "?"
    fts_ins_values[#fts_ins_values + 1] = new_values[i] or ""
  end
  ok, err = db:execute(
    "INSERT INTO _search_" .. name .. "_fts (rowid, " .. field_list ..
    ") VALUES (" .. table.concat(fts_ins_placeholders, ", ") .. ")",
    unpack(fts_ins_values))
  if not ok then return nil, err end

  -- update vector if provided
  if updates.vector and config.vector_dims then
    local vec_json = json.encode(updates.vector)
    ok, err = db:execute(
      "INSERT OR REPLACE INTO _search_" .. name .. "_vectors (id, data) VALUES (?, ?)",
      doc_id, vec_json)
    if not ok then return nil, err end
  end

  return true
end

--: (self: search_index, name: string, doc_id: string) -> true?, string?
function M.remove(self, name, doc_id)
  local db = self._db
  local config, err = get_config(self, name)
  if not config then return nil, err end

  local fields = config.fields

  -- get rowid and old values for FTS delete
  local old_rowid
  old_rowid, err = get_rowid(db, name, doc_id)
  if not old_rowid then return nil, err end

  local field_list = table.concat(fields, ", ")
  local iter
  iter, err = db:query(
    "SELECT " .. field_list .. " FROM _search_" .. name .. " WHERE id = ?", doc_id)
  if not iter then return nil, err end
  local old_values = { iter() }

  -- delete FTS entry
  local fts_del_placeholders = { "?" }
  local fts_del_values = { old_rowid }
  for i = 1, #fields do
    fts_del_placeholders[#fts_del_placeholders + 1] = "?"
    fts_del_values[#fts_del_values + 1] = old_values[i] or ""
  end
  local ok
  ok, err = db:execute(
    "INSERT INTO _search_" .. name .. "_fts (_search_" .. name .. "_fts, rowid, " ..
    field_list .. ") VALUES ('delete', " .. table.concat(fts_del_placeholders, ", ") .. ")",
    unpack(fts_del_values))
  if not ok then return nil, err end

  -- delete from main table
  ok, err = db:execute("DELETE FROM _search_" .. name .. " WHERE id = ?", doc_id)
  if not ok then return nil, err end

  -- delete vector
  if config.vector_dims then
    ok, err = db:execute("DELETE FROM _search_" .. name .. "_vectors WHERE id = ?", doc_id)
    if not ok then return nil, err end
  end

  return true
end

-- helper: build result row from query columns
--: (config: table, doc_id: string, fields_data: table, meta_str: string?) -> table
local function build_result(config, doc_id, fields_data, meta_str, score)
  local r = { id = doc_id, score = score }
  for i = 1, #config.fields do
    r[config.fields[i]] = fields_data[i]
  end
  if meta_str and meta_str ~= "" then
    r.meta = json.decode(meta_str)
  end
  return r
end

--: (self: search_index, name: string, query: string, opts: { limit: number?, offset: number?, fields: {string}? }?) -> {table}?, string?
function M.search(self, name, query, opts)
  opts = opts or {}
  local db = self._db
  local config, err = get_config(self, name)
  if not config then return nil, err end

  local limit = opts.limit or 10
  local offset = opts.offset or 0
  local all_fields = config.fields

  -- build FTS match expression
  local match_expr = query
  if opts.fields and #opts.fields > 0 then
    -- search only specific columns: {col1 col2} : query
    local col_set = "{"
    for i = 1, #opts.fields do
      if i > 1 then col_set = col_set .. " " end
      col_set = col_set .. opts.fields[i]
    end
    col_set = col_set .. "}"
    match_expr = col_set .. " : " .. query
  end

  local qualified_fields = {}
  for i = 1, #all_fields do
    qualified_fields[i] = "s." .. all_fields[i]
  end
  local qualified_list = table.concat(qualified_fields, ", ")
  local sql = "SELECT s.id, s.meta, " .. qualified_list ..
    " FROM _search_" .. name .. "_fts f" ..
    " JOIN _search_" .. name .. " s ON f.rowid = s.rowid" ..
    " WHERE _search_" .. name .. "_fts MATCH ?" ..
    " ORDER BY rank LIMIT ? OFFSET ?"

  local iter
  iter, err = db:query(sql, match_expr, limit, offset)
  if not iter then return nil, err end

  local n_cols = 2 + #all_fields
  local results = {}
  while true do
    local vals = { iter() }
    -- check for end-of-results: iter returns nil, "sqlite: done"
    if vals[1] == nil then break end
    local id = vals[1]
    local meta_str = vals[2]
    local fields_data = {}
    for i = 1, #all_fields do
      fields_data[i] = vals[i + 2]
    end
    results[#results + 1] = build_result(config, id, fields_data, meta_str, nil)
  end

  -- add BM25 rank scores via separate query
  local rank_sql = "SELECT s.id, f.rank FROM _search_" .. name .. "_fts f" ..
    " JOIN _search_" .. name .. " s ON f.rowid = s.rowid" ..
    " WHERE _search_" .. name .. "_fts MATCH ?" ..
    " ORDER BY f.rank LIMIT ? OFFSET ?"
  iter, err = db:query(rank_sql, match_expr, limit, offset)
  if not iter then return results end

  local rank_map = {}
  while true do
    local id, rank = iter()
    if id == nil then break end
    rank_map[id] = rank
  end
  for i = 1, #results do
    results[i].score = rank_map[results[i].id] or 0
  end

  return results
end

--: (self: search_index, name: string, query_vector: {number}, opts: { limit: number? }?) -> {table}?, string?
function M.similar(self, name, query_vector, opts)
  opts = opts or {}
  local db = self._db
  local config, err = get_config(self, name)
  if not config then return nil, err end

  if not config.vector_dims then
    return nil, "search: collection has no vector dimensions"
  end

  local limit = opts.limit or 10
  local qvec = vec.new(query_vector)

  -- load all vectors and compute similarity
  local iter
  iter, err = db:query("SELECT id, data FROM _search_" .. name .. "_vectors")
  if not iter then return nil, err end

  local scored = {}
  while true do
    local id, data = iter()
    if id == nil then break end
    local t = json.decode(data)
    local v = vec.new(t)
    local sim = vec.cosine(qvec, v)
    scored[#scored + 1] = { id = id, score = sim }
  end

  -- sort by similarity descending
  table.sort(scored, function(a, b) return a.score > b.score end)

  -- fetch full documents for top-k
  local results = {}
  local all_fields = config.fields
  local field_list = table.concat(all_fields, ", ")
  for i = 1, math.min(limit, #scored) do
    local s = scored[i]
    iter, err = db:query(
      "SELECT meta, " .. field_list .. " FROM _search_" .. name .. " WHERE id = ?", s.id)
    if not iter then return nil, err end
    local vals = { iter() }
    local meta_str = vals[1]
    local fields_data = {}
    for j = 1, #all_fields do
      fields_data[j] = vals[j + 1]
    end
    results[#results + 1] = build_result(config, s.id, fields_data, meta_str, s.score)
  end

  return results
end

--: (self: search_index, name: string, opts: { text: string, vector: {number}, text_weight: number?, vector_weight: number?, limit: number? }) -> {table}?, string?
function M.hybrid(self, name, opts)
  local db = self._db
  local config, err = get_config(self, name)
  if not config then return nil, err end

  local text_weight = opts.text_weight or 0.5
  local vector_weight = opts.vector_weight or 0.5
  local limit = opts.limit or 10

  -- run text search (get more than limit to allow good merging)
  local fetch_n = limit * 3
  local text_results
  text_results, err = M.search(self, name, opts.text, { limit = fetch_n })
  if not text_results then return nil, err end

  -- run vector search
  local vec_results
  vec_results, err = M.similar(self, name, opts.vector, { limit = fetch_n })
  if not vec_results then return nil, err end

  -- normalize text scores to [0,1] (FTS5 rank is negative; more negative = better)
  local min_rank, max_rank = 0, 0
  for i = 1, #text_results do
    local s = text_results[i].score
    if s < min_rank then min_rank = s end
    if s > max_rank then max_rank = s end
  end
  local rank_range = max_rank - min_rank
  local text_norm = {}
  for i = 1, #text_results do
    local r = text_results[i]
    -- normalize: most relevant (most negative rank) gets score 1.0
    if rank_range ~= 0 then
      text_norm[r.id] = 1.0 - (r.score - min_rank) / rank_range
    else
      text_norm[r.id] = 1.0
    end
  end

  -- vector scores are already cosine similarity [0,1] (approximately)
  local vec_norm = {}
  for i = 1, #vec_results do
    local r = vec_results[i]
    vec_norm[r.id] = r.score
  end

  -- merge all candidate ids
  local seen = {}
  local all_ids = {}
  for i = 1, #text_results do
    local id = text_results[i].id
    if not seen[id] then seen[id] = true; all_ids[#all_ids + 1] = id end
  end
  for i = 1, #vec_results do
    local id = vec_results[i].id
    if not seen[id] then seen[id] = true; all_ids[#all_ids + 1] = id end
  end

  -- compute combined scores
  local combined = {}
  for i = 1, #all_ids do
    local id = all_ids[i]
    local ts = text_norm[id] or 0
    local vs = vec_norm[id] or 0
    combined[#combined + 1] = { id = id, score = text_weight * ts + vector_weight * vs }
  end
  table.sort(combined, function(a, b) return a.score > b.score end)

  -- build result set from doc lookup table
  local doc_map = {}
  for i = 1, #text_results do
    local r = text_results[i]
    doc_map[r.id] = r
  end
  for i = 1, #vec_results do
    local r = vec_results[i]
    if not doc_map[r.id] then doc_map[r.id] = r end
  end

  local results = {}
  for i = 1, math.min(limit, #combined) do
    local c = combined[i]
    local doc = doc_map[c.id]
    if doc then
      local r = {}
      for k, v in pairs(doc) do r[k] = v end
      r.score = c.score
      results[#results + 1] = r
    end
  end

  return results
end

--: (self: search_index, name: string) -> number?, string?
function M.count(self, name)
  local iter, err = self._db:query("SELECT COUNT(*) FROM _search_" .. name)
  if not iter then return nil, err end
  local n = iter()
  return n or 0
end

--: (self: search_index) -> {string}?, string?
function M.collections(self)
  local iter, err = self._db:query("SELECT name FROM _search_collections ORDER BY name")
  if not iter then return nil, err end
  local names = {}
  while true do
    local name = iter()
    if name == nil then break end
    names[#names + 1] = name
  end
  return names
end

--: (self: search_index, name: string) -> true?, string?
function M.drop_collection(self, name)
  local db = self._db
  local config = get_config(self, name)

  -- drop tables (ignore errors for tables that might not exist)
  db:execute("DROP TABLE IF EXISTS _search_" .. name .. "_fts")
  db:execute("DROP TABLE IF EXISTS _search_" .. name .. "_vectors")
  db:execute("DROP TABLE IF EXISTS _search_" .. name)
  db:execute("DELETE FROM _search_collections WHERE name = ?", name)

  return true
end

--: (self: search_index) -> ()
function M.close(self)
  self._db:close()
end

return M
