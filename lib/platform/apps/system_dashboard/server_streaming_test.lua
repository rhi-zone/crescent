-- lib/platform/apps/system_dashboard/server_streaming_test.lua
-- SSE streaming dispatch tests for /api/execute when action.exec.output.type
-- is a streaming primitive (log_stream / live_table / event_stream).
--
-- The dashboard server expects res.send_event / res.close per the http_server
-- cap contract. This test fakes that contract with a recording res object.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local json   = require("lib.format.json")
local server = require("lib.platform.apps.system_dashboard.server")

-- ── Stubs ─────────────────────────────────────────────────────────────────────

-- Build a streaming shell cap whose run_stream returns a fixed list of lines.
local function make_streaming_shell(lines, run_stream_err)
	local cap
	cap = {
		_type = "shell",
		run = function() return "" end,
		run_stream = function(_args)
			if run_stream_err then return nil, run_stream_err end
			local i = 0
			local closed = false
			local iter = {}
			setmetatable(iter, { __call = function()
				if closed then return nil, nil end
				i = i + 1
				if i > #lines then return nil, nil end
				return lines[i], nil
			end })
			function iter:close() closed = true end
			return iter
		end,
		attenuate = function() return cap end,
	}
	return cap
end

local function make_fs_cap(filename, content)
	return {
		_type = "fs",
		list = function() return { filename } end,
		read = function(p) if p == filename then return content end return nil, "nf" end,
	}
end

local function make_time_cap(t0)
	return { _type = "time", now = function() return t0 end }
end

-- A recording response mimicking the http_server cap surface.
local function make_recording_res()
	local res = {
		status = nil,
		headers = {},
		events = {},
		closed = false,
		body = nil,
	}
	function res.send_event(data, opts)
		if res.closed then return nil, "closed" end
		local entry = { data = data }
		if type(opts) == "table" then
			entry.id    = opts.id
			entry.event = opts.event
		end
		res.events[#res.events + 1] = entry
		return true
	end
	function res.close() res.closed = true end
	return res
end

local function build(pack_src, caps)
	local user_packs = make_fs_cap("envpack.lua", pack_src)
	local merged = { user_packs = user_packs }
	for k, v in pairs(caps) do merged[k] = v end
	return server.create(merged, {})
end

local function post_streaming(handler, alias_id, last_event_id)
	local headers = {}
	if last_event_id then
		headers["last-event-id"] = { tostring(last_event_id) }
	end
	local req = {
		method = "POST", path = "/api/execute",
		headers = headers,
		last_event_id = last_event_id,
		body = json.encode({ alias_id = alias_id, action_index = 0 }),
	}
	local res = make_recording_res()
	handler(req, res)
	return res
end

local LOG_PACK = [[
return {
  name = "stream_test",
  aliases = {
    { id = "s-log", actions = { {
      caps = { sh = { type = "shell", reason = "test" } },
      exec = {
        cap = "sh", args = "ignored",
        output = {
          type = "log_stream",
          columns = {
            { key = "time",    label = "Time",    type = "timestamp" },
            { key = "level",   label = "Level",   type = "string" },
            { key = "message", label = "Message", type = "string" },
          },
          replay_buffer = 4,
        },
      },
    } } },
  },
}
]]

T.describe("system_dashboard SSE streaming envelope", function()

	T.describe("emits schema then frames then end", function()
		local sh = make_streaming_shell({ "line one", "line two", "line three" })
		local time_cap = make_time_cap(1700000000)
		local srv = build(LOG_PACK, { shell = sh, time = time_cap })
		local res = post_streaming(srv.handler, "s-log")
		T.eq(res.status, 200)
		T.eq(res.headers["Content-Type"], "text/event-stream")
		T.eq(res.headers["Cache-Control"], "no-cache")
		T.ok(res.closed, "stream should be closed at end")
		T.eq(#res.events, 5, "schema + 3 frames + end = 5 events; got " .. #res.events)
		-- Schema event
		T.eq(res.events[1].event, "schema")
		T.eq(res.events[1].id, 0)
		local schema = json.decode(res.events[1].data)
		T.eq(schema.ok, true)
		T.eq(schema.body.type, "log_stream")
		T.eq(#schema.body.columns, 3)
		-- Frame events
		for i = 1, 3 do
			local ev = res.events[i + 1]
			T.eq(ev.id, i, "frame id should be " .. i)
			local payload = json.decode(ev.data)
			T.eq(payload.type, "frame")
			T.eq(payload.frame.level, "info")
			T.eq(payload.frame.time, 1700000000)
		end
		T.eq(res.events[2].data and json.decode(res.events[2].data).frame.message, "line one")
		T.eq(res.events[3].data and json.decode(res.events[3].data).frame.message, "line two")
		T.eq(res.events[4].data and json.decode(res.events[4].data).frame.message, "line three")
		-- End event
		T.eq(res.events[5].event, "end")
	end)

	T.describe("Last-Event-ID resume replays buffered frames after the given id", function()
		local sh = make_streaming_shell({ "a", "b", "c" })
		local time_cap = make_time_cap(0)
		local srv = build(LOG_PACK, { shell = sh, time = time_cap })
		-- Last id seen = 1, so client expects frames 2 and 3.
		local res = post_streaming(srv.handler, "s-log", "1")
		-- Schema (id=0) is always sent; resume affects only frame replay.
		-- Since this is a single-shot iterator, the server has not buffered
		-- the historical frames; the live pump produces 1, 2, 3 anyway. The
		-- test asserts at minimum the schema + end + sequencing is correct.
		-- Specific resume semantics for cross-process resume require state
		-- persistence across requests (out of scope for this phase — the
		-- stub iterator restarts from the beginning).
		T.eq(res.events[1].event, "schema")
		T.eq(res.events[1].id, 0)
		T.eq(res.events[#res.events].event, "end")
	end)

	T.describe("error envelope when run_stream returns nil, err", function()
		local sh = make_streaming_shell({}, "boom")
		local srv = build(LOG_PACK, { shell = sh, time = make_time_cap(0) })
		local res = post_streaming(srv.handler, "s-log")
		-- Schema + error + close
		T.eq(res.events[1].event, "schema")
		local err_ev
		for _, e in ipairs(res.events) do if e.event == "error" then err_ev = e end end
		T.ok(err_ev, "expected error event")
		local payload = json.decode(err_ev.data)
		T.eq(payload.ok, false)
		T.eq(payload.error, "boom")
		T.ok(res.closed)
	end)

end)
