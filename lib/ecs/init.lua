-- lib/ecs/init.lua
-- SQLite-backed entity-component store for crescent platform scripts.
--
-- Entities have integer IDs; components are named typed data stored as JSON blobs.
-- Designed for mutable world state in sandboxed scripts — not a full-featured ECS
-- (no archetypes, no systems). Hackable and minimal.
--
-- API:
--   local ecs = require("lib.ecs")
--   local store = ecs.new(db)     -- db: lib/sqlite connection
--   store:init()                  -- create tables (called automatically by ecs.new)
--
--   local id = store:create()          -- -> integer entity ID
--   store:destroy(id)                  -- removes entity + all its components
--   store:set(id, "name", "Alice")     -- set component (any Lua value, JSON-encoded)
--   local val = store:get(id, "name") -- -> Lua value or nil
--   store:remove(id, "name")           -- remove one component
--   local results = store:query("hp")  -- -> array of {id, data}
--   local alive = store:query("hp", function(hp) return hp > 0 end)
--   local comps = store:components(id) -- -> { name=val, ... }

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local json = require("lib.format.json")

local M = {}

local store_mt = {}
store_mt.__index = store_mt

-- Helper: get last insert rowid from a db connection.
-- Extracted into a separate function because the typechecker narrows self._db's
-- open-table type after self._db:execute() calls, making last_insert_rowid
-- (which is not in stdlib_types.lua) resolve to unknown and become uncallable.
-- Calling it in a fresh scope avoids the narrowing conflict.
local function db_last_rowid(db)
	return db:last_insert_rowid()
end

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS ecs_entities (
  id    INTEGER PRIMARY KEY AUTOINCREMENT
);
CREATE TABLE IF NOT EXISTS ecs_components (
  entity_id  INTEGER NOT NULL REFERENCES ecs_entities(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  data       TEXT NOT NULL,
  PRIMARY KEY (entity_id, name)
);
CREATE INDEX IF NOT EXISTS ecs_comp_name ON ecs_components (name);
]]

-- init: create schema tables if they don't exist.
-- Also enables foreign key enforcement (required for ON DELETE CASCADE).
store_mt.init = function(self)
	local ok, err = self._db:execute("PRAGMA foreign_keys = ON")
	if not ok then return nil, err end
	ok, err = self._db:execute(SCHEMA)
	if not ok then return nil, err end
	return true
end

-- create: insert a new entity, return its integer ID.
store_mt.create = function(self)
	local ok, err = self._db:execute("INSERT INTO ecs_entities DEFAULT VALUES")
	if not ok then return nil, err end
	return db_last_rowid(self._db)
end

-- destroy: delete an entity and all its components (cascade).
store_mt.destroy = function(self, id)
	local ok, err = self._db:execute("DELETE FROM ecs_entities WHERE id = ?", id)
	if not ok then return nil, err end
	return true
end

-- set: attach or replace a component value on an entity.
store_mt.set = function(self, id, name, val)
	local encoded, err = json.encode(val)
	if not encoded then return nil, "ecs: json encode: " .. (err or "?") end
	local ok, err2 = self._db:execute(
		"INSERT INTO ecs_components (entity_id, name, data) VALUES (?, ?, ?)" ..
		" ON CONFLICT(entity_id, name) DO UPDATE SET data = excluded.data",
		id, name, encoded
	)
	if not ok then return nil, err2 end
	return true
end

-- get: retrieve a component value, or nil if absent.
store_mt.get = function(self, id, name)
	local iter, err = self._db:query(
		"SELECT data FROM ecs_components WHERE entity_id = ? AND name = ?",
		id, name
	)
	if not iter then return nil, err end
	local data = iter()
	if data == nil then return nil end
	local val, derr = json.decode(data)
	if val == nil and derr then return nil, "ecs: json decode: " .. derr end
	return val
end

-- remove: delete one component from an entity.
store_mt.remove = function(self, id, name)
	local ok, err = self._db:execute(
		"DELETE FROM ecs_components WHERE entity_id = ? AND name = ?",
		id, name
	)
	if not ok then return nil, err end
	return true
end

-- query: return array of {id, data} for all entities that have the named component.
-- Optional predicate filters on the decoded value.
store_mt.query = function(self, name, predicate)
	local iter, err = self._db:query(
		"SELECT entity_id, data FROM ecs_components WHERE name = ?",
		name
	)
	if not iter then return nil, err end
	local results = {}
	while true do
		local entity_id, data = iter()
		if entity_id == nil then break end
		local val, derr = json.decode(data)
		if val == nil and derr then return nil, "ecs: json decode: " .. derr end
		if predicate == nil or predicate(val) then
			results[#results + 1] = { id = tonumber(entity_id), data = val }
		end
	end
	return results
end

-- components: enumerate all components on an entity.
store_mt.components = function(self, id)
	local iter, err = self._db:query(
		"SELECT name, data FROM ecs_components WHERE entity_id = ?",
		id
	)
	if not iter then return nil, err end
	local result = {}
	while true do
		local name, data = iter()
		if name == nil then break end
		local val, derr = json.decode(data)
		if val == nil and derr then return nil, "ecs: json decode: " .. derr end
		result[name] = val
	end
	return result
end

-- new: create a store wrapping a lib/sqlite connection.
-- Automatically initializes the schema.
M.new = function(db)
	local self = setmetatable({ _db = db }, store_mt)
	local ok, err = store_mt.init(self)
	if not ok then return nil, err end
	return self
end

return M
