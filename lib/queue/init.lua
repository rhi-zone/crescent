if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sqlite = require("lib.sqlite")
local json = require("lib.format.json")

local M = {}

--:: Queue = { db: sqlite, close: (self) -> nil, push: (self, queue: string, payload: unknown, opts?: { delay?: number, priority?: number, max_retries?: number }) -> number?, string?, pop: (self, queue: string) -> table?, string?, ack: (self, id: number) -> true?, string?, fail: (self, id: number, errmsg?: string) -> true?, string?, retry: (self, id: number) -> true?, string?, process: (self, queue: string, handler: (job: table) -> true?, string?) -> boolean?, string?, length: (self, queue: string) -> number, pending: (self, queue: string) -> table, failed: (self, queue: string) -> table, clear: (self, queue: string) -> true?, string?, queues: (self) -> table, schedule: (self, queue: string, opts: { interval: number, payload?: unknown }) -> number?, string? }

local queue_mt = {}
queue_mt.__index = queue_mt

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS _queue_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  queue TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  priority INTEGER NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0,
  max_retries INTEGER NOT NULL DEFAULT 3,
  error_message TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  available_at TEXT NOT NULL DEFAULT (datetime('now')),
  completed_at TEXT,
  scheduled_interval INTEGER
);
CREATE INDEX IF NOT EXISTS idx_queue_pop ON _queue_jobs(queue, status, available_at, priority);
]]

--: (db: sqlite) -> Queue?, string?
local function init_schema(db)
	local ok, err = db:execute(SCHEMA)
	if not ok then return nil, "queue: schema init failed: " .. tostring(err) end
	return true
end

--: (path: string) -> Queue?, string?
M.open = function(path)
	local db, err = sqlite.open(path)
	if not db then return nil, "queue: " .. tostring(err) end
	local ok, schema_err = init_schema(db)
	if not ok then return nil, schema_err end
	return setmetatable({ db = db }, queue_mt)
end

--: (db: sqlite) -> Queue?, string?
M.wrap = function(db)
	local ok, schema_err = init_schema(db)
	if not ok then return nil, schema_err end
	return setmetatable({ db = db }, queue_mt)
end

--: (self: Queue, queue: string, payload: unknown, opts?: { delay?: number, priority?: number, max_retries?: number }) -> number?, string?
queue_mt.push = function(self, queue_name, payload, opts)
	opts = opts or {}
	local payload_json = json.encode(payload)
	if not payload_json then return nil, "queue: failed to encode payload" end
	local delay = opts.delay or 0
	local priority = opts.priority or 0
	local max_retries = opts.max_retries or 3
	local sql
	if delay > 0 then
		sql = "INSERT INTO _queue_jobs (queue, payload, priority, max_retries, available_at) VALUES (?, ?, ?, ?, datetime('now', '+' || ? || ' seconds'))"
		local ok, err = self.db:execute(sql, queue_name, payload_json, priority, max_retries, delay)
		if not ok then return nil, "queue: push failed: " .. tostring(err) end
	else
		sql = "INSERT INTO _queue_jobs (queue, payload, priority, max_retries) VALUES (?, ?, ?, ?)"
		local ok, err = self.db:execute(sql, queue_name, payload_json, priority, max_retries)
		if not ok then return nil, "queue: push failed: " .. tostring(err) end
	end
	return self.db:last_insert_rowid()
end

--: (self: Queue, queue_name: string, opts: { interval: number, payload?: unknown }) -> number?, string?
queue_mt.schedule = function(self, queue_name, opts)
	local payload_json = json.encode(opts.payload or {})
	if not payload_json then return nil, "queue: failed to encode payload" end
	local interval = opts.interval
	local sql = "INSERT INTO _queue_jobs (queue, payload, scheduled_interval, available_at) VALUES (?, ?, ?, datetime('now', '+' || ? || ' seconds'))"
	local ok, err = self.db:execute(sql, queue_name, payload_json, interval, interval)
	if not ok then return nil, "queue: schedule failed: " .. tostring(err) end
	return self.db:last_insert_rowid()
end

local function parse_job_row(id, queue_name, payload_json, attempts, max_retries, created_at, available_at, scheduled_interval)
	if not id then return nil end
	local payload = json.decode(payload_json)
	return {
		id = id,
		queue = queue_name,
		payload = payload,
		attempts = attempts,
		max_retries = max_retries,
		created_at = created_at,
		available_at = available_at,
		scheduled_interval = scheduled_interval,
	}
end

--: (self: Queue, queue_name: string) -> table?, string?
queue_mt.pop = function(self, queue_name)
	-- Use a transaction: SELECT the candidate, then UPDATE it.
	local ok, err = self.db:execute("BEGIN IMMEDIATE")
	if not ok then return nil, "queue: pop begin failed: " .. tostring(err) end

	local iter, qerr = self.db:query(
		"SELECT id FROM _queue_jobs WHERE queue = ? AND status = 'pending' AND available_at <= datetime('now') ORDER BY priority DESC, available_at ASC, id ASC LIMIT 1",
		queue_name
	)
	if not iter then
		self.db:execute("ROLLBACK")
		return nil, "queue: pop select failed: " .. tostring(qerr)
	end

	local job_id = iter()
	if not job_id then
		self.db:execute("ROLLBACK")
		return nil
	end

	local ok2, err2 = self.db:execute(
		"UPDATE _queue_jobs SET status = 'processing', attempts = attempts + 1 WHERE id = ?",
		job_id
	)
	if not ok2 then
		self.db:execute("ROLLBACK")
		return nil, "queue: pop update failed: " .. tostring(err2)
	end

	local iter2, qerr2 = self.db:query(
		"SELECT id, queue, payload, attempts, max_retries, created_at, available_at, scheduled_interval FROM _queue_jobs WHERE id = ?",
		job_id
	)
	if not iter2 then
		self.db:execute("ROLLBACK")
		return nil, "queue: pop read failed: " .. tostring(qerr2)
	end

	local job = parse_job_row(iter2())

	local ok3, err3 = self.db:execute("COMMIT")
	if not ok3 then return nil, "queue: pop commit failed: " .. tostring(err3) end

	return job
end

--: (self: Queue, id: number) -> true?, string?
queue_mt.ack = function(self, id)
	-- Check if this is a scheduled (recurring) job
	local iter, qerr = self.db:query(
		"SELECT scheduled_interval, queue, payload FROM _queue_jobs WHERE id = ?",
		id
	)
	if not iter then return nil, "queue: ack query failed: " .. tostring(qerr) end
	local interval, queue_name, payload_json = iter()

	local ok, err = self.db:execute(
		"UPDATE _queue_jobs SET status = 'completed', completed_at = datetime('now') WHERE id = ?",
		id
	)
	if not ok then return nil, "queue: ack failed: " .. tostring(err) end

	-- If recurring, enqueue the next occurrence
	if interval and interval > 0 then
		local ok2, err2 = self.db:execute(
			"INSERT INTO _queue_jobs (queue, payload, scheduled_interval, available_at) VALUES (?, ?, ?, datetime('now', '+' || ? || ' seconds'))",
			queue_name, payload_json, interval, interval
		)
		if not ok2 then return nil, "queue: ack reschedule failed: " .. tostring(err2) end
	end

	return true
end

--: (self: Queue, id: number, errmsg?: string) -> true?, string?
queue_mt.fail = function(self, id, errmsg)
	-- Get current attempts and max_retries
	local iter, qerr = self.db:query(
		"SELECT attempts, max_retries FROM _queue_jobs WHERE id = ?",
		id
	)
	if not iter then return nil, "queue: fail query failed: " .. tostring(qerr) end
	local attempts, max_retries = iter()
	if not attempts then return nil, "queue: fail: job not found" end

	if attempts < max_retries then
		-- Retry with exponential backoff
		local backoff = math.min(2 ^ attempts, 3600)
		local ok, err = self.db:execute(
			"UPDATE _queue_jobs SET status = 'pending', error_message = ?, available_at = datetime('now', '+' || ? || ' seconds') WHERE id = ?",
			errmsg, backoff, id
		)
		if not ok then return nil, "queue: fail update failed: " .. tostring(err) end
	else
		-- Dead letter
		local ok, err = self.db:execute(
			"UPDATE _queue_jobs SET status = 'dead', error_message = ? WHERE id = ?",
			errmsg, id
		)
		if not ok then return nil, "queue: fail dead-letter failed: " .. tostring(err) end
	end

	return true
end

--: (self: Queue, id: number) -> true?, string?
queue_mt.retry = function(self, id)
	local ok, err = self.db:execute(
		"UPDATE _queue_jobs SET status = 'pending', attempts = attempts + 1, available_at = datetime('now') WHERE id = ?",
		id
	)
	if not ok then return nil, "queue: retry failed: " .. tostring(err) end
	return true
end

--: (self: Queue, queue_name: string, handler: (job: table) -> true?, string?) -> boolean?, string?
queue_mt.process = function(self, queue_name, handler)
	local job, pop_err = self:pop(queue_name)
	if not job then
		if pop_err then return nil, pop_err end
		return false
	end
	local ok, ret1, ret2 = pcall(handler, job)
	if not ok then
		-- handler threw an error
		local fail_ok, fail_err = self:fail(job.id, tostring(ret1))
		if not fail_ok then return nil, fail_err end
		return true
	elseif ret1 then
		-- handler returned true (success)
		local ack_ok, ack_err = self:ack(job.id)
		if not ack_ok then return nil, ack_err end
		return true
	else
		-- handler returned (nil, errmsg) or (false, ...)
		local fail_ok, fail_err = self:fail(job.id, tostring(ret2 or "handler returned failure"))
		if not fail_ok then return nil, fail_err end
		return true
	end
end

--: (self: Queue, queue_name: string) -> number
queue_mt.length = function(self, queue_name)
	local iter = self.db:query(
		"SELECT COUNT(*) FROM _queue_jobs WHERE queue = ? AND status = 'pending'",
		queue_name
	)
	if not iter then return 0 end
	return iter() or 0
end

--: (self: Queue, queue_name: string) -> table
queue_mt.pending = function(self, queue_name)
	local iter, err = self.db:query(
		"SELECT id, queue, payload, attempts, max_retries, created_at, available_at, scheduled_interval FROM _queue_jobs WHERE queue = ? AND status = 'pending' ORDER BY priority DESC, available_at ASC, id ASC",
		queue_name
	)
	if not iter then return {} end
	local jobs = {}
	while true do
		local job = parse_job_row(iter())
		if not job then break end
		jobs[#jobs + 1] = job
	end
	return jobs
end

--: (self: Queue, queue_name: string) -> table
queue_mt.failed = function(self, queue_name)
	local iter, err = self.db:query(
		"SELECT id, queue, payload, attempts, max_retries, created_at, available_at, scheduled_interval FROM _queue_jobs WHERE queue = ? AND status = 'dead' ORDER BY id ASC",
		queue_name
	)
	if not iter then return {} end
	local jobs = {}
	while true do
		local job = parse_job_row(iter())
		if not job then break end
		jobs[#jobs + 1] = job
	end
	return jobs
end

--: (self: Queue, queue_name: string) -> true?, string?
queue_mt.clear = function(self, queue_name)
	return self.db:execute("DELETE FROM _queue_jobs WHERE queue = ?", queue_name)
end

--: (self: Queue) -> table
queue_mt.queues = function(self)
	local iter, err = self.db:query(
		"SELECT DISTINCT queue FROM _queue_jobs WHERE status IN ('pending', 'processing') ORDER BY queue"
	)
	if not iter then return {} end
	local names = {}
	while true do
		local name = iter()
		if not name then break end
		names[#names + 1] = name
	end
	return names
end

--: (self: Queue) -> nil
queue_mt.close = function(self)
	self.db:close()
end

return M
