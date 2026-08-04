-- lib/fractal/stream_test.lua
-- Tests for lib/fractal/stream.lua (the streaming-handler convention).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local async  = require("lib.async")
local result = require("lib.fractal.result")
local stream = require("lib.fractal.stream")

-- The slice of lib/async's promise this file reads, with the `...` structural
-- subtyping marker its own declaration uses.
--:: PromiseView = { _state: string, ... }

--: (v: unknown) -> v is PromiseView
local function is_promise(v)
  if type(v) ~= "table" then return false end
  return v._state ~= nil
end

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

-- True when `v` is a string containing `needle`. The rejection reasons this
-- file checks arrive typed `unknown`, so the type test and the search live
-- together rather than at every call site.
--: (v: unknown, needle: string) -> boolean
local function contains(v, needle)
  if type(v) ~= "string" then return false end
  return v:find(needle, 1, true) ~= nil
end

-- An arm that appends everything it receives to `into` — what a projector's
-- chunk/progress arms do, minus the transport.
--: (into: { [integer]: unknown }) -> (value: unknown) -> nil
local function collector(into)
  --: (value: unknown) -> nil
  local function push(value)
    into[#into + 1] = value
  end
  return push
end

-- Pull one step off a stream and settle it. Every stream in this file is
-- synchronous, so the promise settles before `next()` even returns and no
-- event loop is needed — the same property direct_test.lua relies on.
--: (s: unknown) -> (unknown, unknown)
local function pull(s)
  if not as_record(s) then error("pull: not a stream") end
  local next_fn = s.next
  if type(next_fn) ~= "function" then error("pull: stream has no next()") end
  local p = next_fn()
  if not is_promise(p) then error("pull: next() did not return a promise") end
  return async.run(p)
end

-- Read `kind`/`value` off a settled step.
--: (step: unknown) -> (unknown, unknown)
local function step_parts(step)
  if not as_record(step) then error("step_parts: not a step") end
  return step.kind, step.value
end

T.describe("lib.fractal.stream", function()

  T.describe("shape", function()

    T.it("from() produces a stream-tagged table with a next()", function()
      local s = stream.from(function(_) return "done" end)
      T.eq(stream.is_stream(s), true)
    end)

    T.it("is_stream rejects a bare kind tag with no next()", function()
      T.eq(stream.is_stream({ kind = "stream" }), false)
    end)

    T.it("is_stream rejects other tagged values and non-tables", function()
      T.eq(stream.is_stream({ kind = "ok", value = 1 }), false)
      T.eq(stream.is_stream({ items = {}, hasMore = false }), false)
      T.eq(stream.is_stream(nil), false)
      T.eq(stream.is_stream("stream"), false)
    end)

    T.it("is_emit and is_done are exact on the step tag", function()
      T.eq(stream.is_emit({ kind = "emit", value = 1 }), true)
      T.eq(stream.is_emit({ kind = "done", value = 1 }), false)
      T.eq(stream.is_done({ kind = "done", value = 1 }), true)
      T.eq(stream.is_done({ kind = "emit", value = 1 }), false)
      T.eq(stream.is_emit(nil), false)
      T.eq(stream.is_done("done"), false)
    end)

  end)

  T.describe("laziness", function()

    T.it("the producer does not run until the first next()", function()
      local ran = { n = 0 } --: { n: integer }
      local s = stream.from(function(_)
        ran.n = ran.n + 1
        return nil
      end)
      T.eq(ran.n, 0)
      pull(s)
      T.eq(ran.n, 1)
    end)

  end)

  T.describe("stepping", function()

    T.it("emits in order and ends with the terminal value", function()
      local s = stream.from(function(emit)
        async.await(emit("a"))
        async.await(emit("b"))
        return "fin"
      end)

      local k1, v1 = step_parts(pull(s))
      T.eq(k1, "emit")
      T.eq(v1, "a")

      local k2, v2 = step_parts(pull(s))
      T.eq(k2, "emit")
      T.eq(v2, "b")

      local k3, v3 = step_parts(pull(s))
      T.eq(k3, "done")
      T.eq(v3, "fin")
    end)

    T.it("a producer that emits nothing yields done immediately", function()
      local s = stream.from(function(_) return 7 end)
      local k, v = step_parts(pull(s))
      T.eq(k, "done")
      T.eq(v, 7)
    end)

    T.it("the terminal value is distinct from the emissions", function()
      -- The point of the DU: `done` carries a Result, the emissions carry
      -- chunks, and nothing conflates them.
      local s = stream.from(function(emit)
        async.await(emit({ kind = "chunk", data = "part" }))
        return result.ok("summary")
      end)
      local k1, v1 = step_parts(pull(s))
      T.eq(k1, "emit")
      T.eq(result.is_stream_chunk(v1), true)

      local k2, v2 = step_parts(pull(s))
      T.eq(k2, "done")
      T.eq(result.is_result_shape(v2), true)
    end)

    T.it("next() after done keeps returning the same terminal step", function()
      local s = stream.from(function(_) return "end" end)
      step_parts(pull(s))
      local k, v = step_parts(pull(s))
      T.eq(k, "done")
      T.eq(v, "end")
    end)

  end)

  T.describe("lockstep — nothing is buffered", function()

    T.it("the producer parks at each emit until the consumer pulls", function()
      local log = {} --: { [integer]: unknown }
      local note = collector(log)

      local s = stream.from(function(emit)
        note("before-a")
        async.await(emit("a"))
        note("after-a")
        async.await(emit("b"))
        note("after-b")
        return nil
      end)

      pull(s)
      T.eq(#log, 1)
      T.eq(log[1], "before-a")
      pull(s)
      T.eq(#log, 2)
      T.eq(log[2], "after-a")
      pull(s)
      T.eq(#log, 3)
      T.eq(log[3], "after-b")
    end)

    T.it("emitting twice without awaiting is rejected, not buffered", function()
      local s = stream.from(function(emit)
        emit("a")
        emit("b")
        return nil
      end)
      -- The first emission was legitimately delivered to the pending next(),
      -- so it lands as normal; the second has nowhere to go, and the raise it
      -- causes surfaces on the following next() rather than being queued.
      local k, v = step_parts(pull(s))
      T.eq(k, "emit")
      T.eq(v, "a")

      local step2, err = pull(s)
      T.eq(step2, nil)
      T.eq(contains(err, "still pending"), true)
    end)

  end)

  T.describe("errors", function()

    T.it("a raise in the producer rejects the pending next()", function()
      local s = stream.from(function(_)
        error("boom")
      end)
      local step, err = pull(s)
      T.eq(step, nil)
      T.eq(contains(err, "boom"), true)
    end)

    T.it("a raise after an emission rejects only the following next()", function()
      local s = stream.from(function(emit)
        async.await(emit("a"))
        error("late")
      end)
      local k, v = step_parts(pull(s))
      T.eq(k, "emit")
      T.eq(v, "a")

      local step2, err = pull(s)
      T.eq(step2, nil)
      T.eq(contains(err, "late"), true)
    end)

    T.it("every next() after a failure keeps rejecting", function()
      local s = stream.from(function(_) error("boom") end)
      pull(s)
      local step, err = pull(s)
      T.eq(step, nil)
      T.eq(contains(err, "boom"), true)
    end)

  end)

  T.describe("drive", function()

    T.it("dispatches chunks unwrapped and returns the terminal value", function()
      local chunks = {} --: { [integer]: unknown }
      local s = stream.from(function(emit)
        async.await(emit({ kind = "chunk", data = "a" }))
        async.await(emit({ kind = "chunk", data = "b" }))
        return "fin"
      end)
      local final, err = async.run(stream.drive(s, { chunk = collector(chunks) }))
      T.eq(err, nil)
      T.eq(final, "fin")
      T.eq(#chunks, 2)
      T.eq(chunks[1], "a")
      T.eq(chunks[2], "b")
    end)

    T.it("an untagged emission is indistinguishable from a chunk", function()
      local chunks = {} --: { [integer]: unknown }
      local s = stream.from(function(emit)
        async.await(emit("bare"))
        async.await(emit({ kind = "chunk", data = "wrapped" }))
        return nil
      end)
      async.run(stream.drive(s, { chunk = collector(chunks) }))
      T.eq(#chunks, 2)
      T.eq(chunks[1], "bare")
      T.eq(chunks[2], "wrapped")
    end)

    T.it("progress effects go to the progress arm, whole", function()
      local seen   = {} --: { [integer]: unknown }
      local chunks = {} --: { [integer]: unknown }
      local s = stream.from(function(emit)
        async.await(emit({ kind = "progress", progress = 1, total = 2 }))
        async.await(emit({ kind = "chunk", data = "x" }))
        return nil
      end)
      async.run(stream.drive(s, {
        progress = collector(seen),
        chunk    = collector(chunks),
      }))
      T.eq(#seen, 1)
      T.eq(result.is_stream_progress(seen[1]), true)
      T.eq(#chunks, 1)
      T.eq(chunks[1], "x")
    end)

    T.it("omitting the progress arm drops progress effects", function()
      local chunks = {} --: { [integer]: unknown }
      local s = stream.from(function(emit)
        async.await(emit({ kind = "progress", progress = 1 }))
        async.await(emit({ kind = "chunk", data = "x" }))
        return "fin"
      end)
      local final = async.run(stream.drive(s, { chunk = collector(chunks) }))
      T.eq(final, "fin")
      T.eq(#chunks, 1)
      T.eq(chunks[1], "x")
    end)

    T.it("an empty stream calls no arm and still returns the terminal value", function()
      local chunks = {} --: { [integer]: unknown }
      local s = stream.from(function(_) return result.ok("nothing") end)
      local final = async.run(stream.drive(s, { chunk = collector(chunks) }))
      T.eq(#chunks, 0)
      T.eq(result.is_result_shape(final), true)
    end)

    T.it("a producer failure surfaces as a rejection from drive", function()
      local chunks = {} --: { [integer]: unknown }
      local s = stream.from(function(emit)
        async.await(emit({ kind = "chunk", data = "partial" }))
        error("mid-stream")
      end)
      local final, err = async.run(stream.drive(s, { chunk = collector(chunks) }))
      T.eq(final, nil)
      T.eq(contains(err, "mid-stream"), true)
      -- Output produced before the failure still reached the arm.
      T.eq(chunks[1], "partial")
    end)

  end)

end)
