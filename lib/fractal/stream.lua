-- lib/fractal/stream.lua — the streaming-handler convention, ported from
-- fractal's `async function*` handlers and the manual `.next()` drain loops
-- every projector runs over them (packages/http-api-projector/src/route.ts's
-- `streamAsSse`, cli-api-projector's `streamAsyncIterable`,
-- json-rpc-api-projector's `streamViaNotifications`/`drainToArray`).
--
-- WHAT A STREAM IS. A handler whose result is a sequence of values arriving
-- over time, plus one final value at the end. On the TypeScript side that is
-- an `AsyncIterable`, detected by a projector with
-- `Symbol.asyncIterator in returnValue`. Lua has no such protocol, so this
-- module defines one, tagged the way everything else in this port is tagged:
--
--   Stream     — { kind = "stream", next = () -> promise of StreamStep }
--   StreamStep — { kind = "emit", value = v }   one emission
--              | { kind = "done", value = v }   the terminal value
--
-- `StreamStep` is the DU reading of JS's `IteratorResult<T, TReturn>`: the
-- `done` boolean becomes the tag, and — as in JS — the terminal value is a
-- DIFFERENT thing from the emissions, not the last of them. That distinction
-- is load-bearing: HTTP renders it as an `event: done` frame and JSON-RPC as
-- the originating call's `result`, both separate from the emitted chunks.
--
-- Tagging the terminal value is a DELIBERATE DIVERGENCE from the TypeScript
-- source, noted here so it is not later read as an oversight: fractal's type
-- extractor drops `TReturn` from an `AsyncGenerator` signature even though
-- every projector's drain loop reads `step.value` at `done` and does something
-- transport-specific with it. The value is runtime-load-bearing on both sides;
-- only the TS *types* lose it. This port keeps it in the type.
--
-- `next` is a plain field holding a closure, not a method, so a stream is
-- driven as `s.next()` with no receiver to thread.
--
-- WHAT IT EMITS. Anything. `result.lua`'s `StreamEffect` values
-- (`{ kind = "progress", ... }` / `{ kind = "chunk", data = ... }`) are the
-- vocabulary a projector understands, but an untagged value is legal and is
-- treated as a chunk — `M.drive` reproduces the three-way dispatch every TS
-- projector performs, in which `emit(x)` and `emit(chunk(x))` are
-- observationally identical downstream.
--
-- LOCKSTEP, NOT BUFFERED. `async function*` suspends the generator body at
-- every `yield` until the consumer pulls again; nothing is buffered and the
-- body does not start at all until the first `.next()`. This port is
-- faithful: `M.from` runs nothing until the first `next()`, and the promise
-- `emit` returns does not resolve until the consumer pulls the value after
-- it. A producer that ignores that promise and emits twice in a row is
-- reporting a use outside the domain — the analogue is syntactically
-- impossible in TS — and errors rather than silently buffering.
--
-- ERRORS. An error raised in the producer rejects the promise the consumer is
-- waiting on, and every subsequent `next()`. This matches an async generator,
-- whose `.next()` rejects. Nothing here decides what a projector then does
-- with a mid-stream failure: the TS side has no `StreamError` effect and no
-- uniform policy (HTTP aborts the body, CLI/MCP/JSON-RPC let the throw reach
-- the per-request catch after partial output), so that stays each projector's
-- call. The documented way for a handler to signal a client-facing failure is
-- still an `err(...)` Result in the terminal position.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local async  = require("lib.async")
local result = require("lib.fractal.result")

local M = {}

--:: ResolveFn = (value: unknown) -> nil
--:: RejectFn = (reason: unknown) -> nil

-- `kind` is a literal type on each arm, so `step.kind == "done"` narrows the
-- union at a read site without a cast — the same reason result.lua's Result
-- arms are written this way.
--:: StreamEmit = { kind: "emit", value: unknown }
--:: StreamDone = { kind: "done", value: unknown }
--:: StreamStep = StreamEmit | StreamDone

-- `next` returns a promise of a `StreamStep`, typed `unknown` because
-- lib/async's promise carries no element type; the consumer narrows what comes
-- out of it, exactly as direct.lua's leaf callables require.
--:: Stream = { kind: "stream", next: () -> unknown }

-- The producer's emit cap: hands one value to the consumer and returns a
-- promise that resolves when the consumer pulls again. Awaiting it is what
-- makes the sequence lockstep.
--:: EmitFn = (value: unknown) -> unknown

--:: Producer = (emit: EmitFn) -> unknown

-- Mutable state of one stream. `waiter_*` is the consumer's outstanding
-- `next()` promise; `gate_resolve` is the parked producer's resume handle.
-- At most one of the two is ever set: the producer runs only while a consumer
-- is waiting, and parks the moment it emits.
--:: StreamState = { started: boolean, settled: boolean, final: unknown, failed: boolean, reason: unknown, waiter_resolve: ResolveFn | nil, waiter_reject: RejectFn | nil, gate_resolve: ResolveFn | nil }

-- ── Constructing a stream ────────────────────────────────────────────────

-- Build a stream from a producer function. `producer(emit)` runs as a
-- lib/async coroutine — it may `async.await` anything, exactly like the body
-- of an `async function*` — and whatever it returns becomes the stream's
-- terminal value.
--
--   local s = stream.from(function(emit)
--     async.await(emit({ kind = "progress", progress = 0, total = 2 }))
--     async.await(emit({ kind = "chunk", data = "a" }))
--     return result.ok("finished")
--   end)
--
-- Nothing runs until the first `next()`.
--: (producer: Producer) -> Stream
function M.from(producer)
	-- TYPECHECKER WORKAROUND: the annotation is on the preceding line rather
	-- than trailing the constructor (`} --: StreamState`), which is the form
	-- the rest of this repo uses. A trailing `--:` on the CLOSING line of a
	-- multi-line table constructor is mis-associated: every later field
	-- assignment is then checked against the whole table type instead of the
	-- field's, producing errors like "cannot assign `string` to `{ ... }`:
	-- string has no field `started`". The same annotation trailing a
	-- single-line constructor checks clean, so this is purely about placement.
	-- See TODO.md.
	--: StreamState
	local st = {
		started        = false,
		settled        = false,
		final          = nil,
		failed         = false,
		reason         = nil,
		waiter_resolve = nil,
		waiter_reject  = nil,
		gate_resolve   = nil,
	}

	-- Hand `step` to the consumer waiting on `next()`, clearing the slot.
	--: (step: StreamStep) -> nil
	local function deliver(step)
		local resolve_fn = st.waiter_resolve
		st.waiter_resolve = nil
		st.waiter_reject  = nil
		if resolve_fn ~= nil then resolve_fn(step) end
	end

	--: (reason: unknown) -> nil
	local function deliver_error(reason)
		local reject_fn = st.waiter_reject
		st.waiter_resolve = nil
		st.waiter_reject  = nil
		if reject_fn ~= nil then reject_fn(reason) end
	end

	--: EmitFn
	local function emit(value)
		if st.gate_resolve ~= nil then
			error("fractal.stream: emit called while the previous emit is still pending — await the promise emit returns")
		end
		if st.waiter_resolve == nil then
			error("fractal.stream: emit called with no pending next()")
		end
		local gate, gate_resolve, _ = async.promise()
		st.gate_resolve = gate_resolve
		-- Resolving the waiter can re-enter `next` synchronously, which
		-- consumes the gate above; that is why the gate is armed first.
		deliver({ kind = "emit", value = value })
		return gate
	end

	-- The producer's own settlement is done INSIDE the async body rather than
	-- by chaining `and_then`/`catch` onto the promise `async.async` returns:
	-- that promise is typed `unknown` (lib/async does not annotate `async`),
	-- and narrowing it back to a promise to attach handlers would take a cast
	-- past `unknown`. The `pcall` here is the same one `async.cancellable`
	-- performs around a coroutine body, so raising inside `producer` behaves
	-- identically either way — LuaJIT permits yielding across `pcall`, so an
	-- awaiting producer is unaffected.
	--
	-- TYPECHECKER WORKAROUND: the natural name for `outcome` is `value` — it is
	-- the producer's return value, and `deliver({ kind = "done", value = ... })`
	-- reads that way. It cannot be used: a `local ok, value = pcall(...)` inside
	-- an unannotated closure poisons narrowing for EVERY later `value` in the
	-- file, so `dispatch`'s own `value` parameter stops narrowing under
	-- `is_chunk_effect` and `value.data` is rejected. Narrowing facts appear to
	-- be keyed by name rather than by binding. See TODO.md for the repro.
	local run_producer = async.async(function()
		local ok, outcome = pcall(producer, emit)
		if ok then
			st.settled = true
			st.final   = outcome
			deliver({ kind = "done", value = outcome })
		else
			st.failed = true
			st.reason = outcome
			deliver_error(outcome)
		end
		return nil
	end)

	--: () -> nil
	local function start()
		run_producer()
	end

	--: () -> unknown
	local function next_step()
		if st.failed then return async.rejected(st.reason) end
		if st.settled then return async.resolved({ kind = "done", value = st.final }) end
		if st.waiter_resolve ~= nil then
			error("fractal.stream: next() called while a previous next() is still pending")
		end
		local p, resolve_fn, reject_fn = async.promise()
		st.waiter_resolve = resolve_fn
		st.waiter_reject  = reject_fn
		if not st.started then
			st.started = true
			start()
		else
			local gate_resolve = st.gate_resolve
			st.gate_resolve = nil
			if gate_resolve ~= nil then gate_resolve(nil) end
		end
		return p
	end

	return { kind = "stream", next = next_step }
end

-- ── Detection ────────────────────────────────────────────────────────────

-- The opt-in runtime sniff a projector performs on a resolved handler return
-- value, mirroring `is_result_shape` in result.lua and `is_page_shape` in
-- page.lua. Exact on `kind`, and requires a callable `next`, so neither user
-- data carrying an unrelated `kind` nor a bare `{ kind = "stream" }` table
-- false-positives into a crash.
--: (v: unknown) -> boolean
function M.is_stream(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	if t.kind ~= "stream" then return false end
	return type(t.next) == "function"
end

--: (v: unknown) -> boolean
function M.is_emit(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	return t.kind == "emit"
end

--: (v: unknown) -> boolean
function M.is_done(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	return t.kind == "done"
end

-- ── Driving a stream ─────────────────────────────────────────────────────

-- The arms a projector supplies to `drive`. `chunk` receives the UNWRAPPED
-- payload: `value.data` for a `{ kind = "chunk" }` effect, and the value
-- itself for an untagged emission — the two are indistinguishable to the arm,
-- which is what every TS projector does. `progress` receives the whole
-- `{ kind = "progress", ... }` effect, since `total` and `message` are both
-- optional and rendered differently per transport. Omitting `progress` drops
-- progress effects, which is the correct behavior for a transport that has no
-- progress channel (JSON-RPC over HTTP and GraphQL subscriptions both drop
-- them on the TS side).
--:: StreamArms = { progress: ((effect: unknown) -> nil) | nil, chunk: (value: unknown) -> nil }

-- Narrowing wrapper over result.lua's `is_stream_chunk`, which returns a plain
-- boolean, so `data` can be read off a chunk effect without a cast. The same
-- idiom as cache.lua's `is_json_array` over init.lua's `is_array`.
--: (v: unknown) -> v is { kind: "chunk", data: unknown }
local function is_chunk_effect(v)
	return result.is_stream_chunk(v)
end

--: (arms: StreamArms, value: unknown) -> nil
local function dispatch(arms, value)
	if result.is_stream_progress(value) then
		local on_progress = arms.progress
		if on_progress ~= nil then on_progress(value) end
		return
	end
	if is_chunk_effect(value) then
		arms.chunk(value.data)
		return
	end
	arms.chunk(value)
end

-- One drain step, factored out of the loop so the `StreamStep` union is
-- narrowed where it is read. Returns `true` plus the terminal value once the
-- stream is done, `false` while it is still emitting.
--: (step: StreamStep, arms: StreamArms) -> (boolean, unknown)
local function consume(step, arms)
	if step.kind == "done" then
		return true, step.value
	end
	dispatch(arms, step.value)
	return false, nil
end

local drive_async = async.async(function(stream, arms)
	while true do
		local step = async.await(stream.next()) --[[: StreamStep]]
		local done, value = consume(step, arms)
		if done then return value end
	end
end)

-- Drive a stream to completion, dispatching each emission to `arms` as it
-- arrives, and resolve with the terminal value.
--
-- The return is a lib/async promise. It is typed `unknown` for the same
-- reason direct.lua types its leaf callables that way: `async.async` erases
-- its wrapped function's return type, so the caller narrows. `await` it from
-- inside another async function, or `async.run` it when the whole stream is
-- synchronous.
--
-- A projector that needs to distinguish the terminal value from the emissions
-- gets that for free — emissions go to the arms, the terminal value comes
-- back here. One that flattens them (CLI, MCP) appends this value to whatever
-- the arms collected.
--: (stream: Stream, arms: StreamArms) -> unknown
function M.drive(stream, arms)
	return drive_async(stream, arms)
end

return M
