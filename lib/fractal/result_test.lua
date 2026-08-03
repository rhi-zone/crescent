-- lib/fractal/result_test.lua
-- Tests for lib/fractal/result.lua (compose/pipe, Result, StreamEffect,
-- ErrorEncoder, compose_k).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local R = require("lib.fractal.result")

-- `pipe` is typed with a variadic `(a: unknown) -> unknown` stage — see its
-- TYPECHECKER WORKAROUND note — so a stage passed to it must narrow its own
-- argument. These shared stages do that once, rather than at every call site.
--: (a: unknown) -> unknown
local function inc(a)
  if type(a) ~= "number" then error("inc: expected a number") end
  return a + 1
end

--: (a: unknown) -> unknown
local function dbl(a)
  if type(a) ~= "number" then error("dbl: expected a number") end
  return a * 2
end

--: (a: unknown) -> unknown
local function show(a)
  return "n=" .. tostring(a)
end

T.describe("lib.fractal.result", function()

  -- ── the function category ──────────────────────────────────────────────

  T.describe("compose", function()

    T.it("compose(f)(g) is a -> g(f(a))", function()
      T.eq(R.compose(inc)(dbl)(3), 8) -- (3+1)*2, not 3*2+1
    end)

    T.it("composes across types", function()
      --: (a: string) -> integer
      local len = function(a) return #a end
      --: (a: integer) -> string
      local label = function(a) return "n=" .. a end
      T.eq(R.compose(len)(label)("abcd"), "n=4")
    end)

    T.it("is associative in effect", function()
      local left = R.compose(R.compose(inc)(dbl))(show)
      local right = R.compose(inc)(R.compose(dbl)(show))
      T.eq(left(3), right(3))
    end)

  end)

  T.describe("pipe", function()

    T.it("with no functions returns the value unchanged", function()
      T.eq(R.pipe(7), 7)
    end)

    T.it("applies one function", function()
      T.eq(R.pipe(3, inc), 4)
    end)

    T.it("threads left to right", function()
      T.eq(R.pipe(3, inc, dbl), 8)
    end)

    T.it("threads four stages", function()
      T.eq(R.pipe(1, inc, dbl, inc, show), "n=5")
    end)

    T.it("agrees with the equivalent compose chain", function()
      T.eq(R.pipe(3, inc, dbl), R.compose(inc)(dbl)(3))
    end)

  end)

  -- ── Result ─────────────────────────────────────────────────────────────

  T.describe("ok / err", function()

    T.it("ok carries kind and value", function()
      local r = R.ok(42)
      T.eq(r.kind, "ok")
      T.eq(r.value, 42)
    end)

    T.it("err carries kind and error", function()
      local r = R.err("boom")
      T.eq(r.kind, "err")
      T.eq(r.error, "boom")
    end)

    T.it("ok can carry nil", function()
      local r = R.ok(nil)
      T.eq(r.kind, "ok")
      T.eq(r.value, nil)
    end)

    T.it("is_ok / is_err discriminate", function()
      T.eq(R.is_ok(R.ok(1)), true)
      T.eq(R.is_err(R.ok(1)), false)
      T.eq(R.is_ok(R.err(1)), false)
      T.eq(R.is_err(R.err(1)), true)
    end)

  end)

  T.describe("is_result_shape", function()

    T.it("accepts both arms", function()
      T.eq(R.is_result_shape(R.ok(1)), true)
      T.eq(R.is_result_shape(R.err(1)), true)
    end)

    T.it("accepts a hand-built table with the right kind", function()
      T.eq(R.is_result_shape({ kind = "ok", value = 1 }), true)
    end)

    T.it("rejects an unrelated kind so user data never false-positives", function()
      T.eq(R.is_result_shape({ kind = "notFound", message = "x" }), false)
    end)

    T.it("rejects a table with no kind", function()
      T.eq(R.is_result_shape({ value = 1 }), false)
    end)

    T.it("rejects non-tables", function()
      T.eq(R.is_result_shape(nil), false)
      T.eq(R.is_result_shape("ok"), false)
      T.eq(R.is_result_shape(42), false)
    end)

  end)

  T.describe("map", function()

    T.it("maps the success value", function()
      --: (v: integer) -> integer
      local times5 = function(v) return v * 5 end
      local r = R.map(R.ok(2), times5)
      T.eq(r.kind, "ok")
      T.eq(r.value, 10)
    end)

    T.it("passes an error through untouched", function()
      --: (v: integer) -> integer
      local times5 = function(v) return v * 5 end
      local r = R.map(R.err("bad"), times5)
      T.eq(r.kind, "err")
      T.eq(r.error, "bad")
    end)

    T.it("does not call f on an error", function()
      local called = false
      --: (v: integer) -> integer
      local mark = function(v) called = true; return v end
      R.map(R.err("bad"), mark)
      T.eq(called, false)
    end)

  end)

  T.describe("bind", function()

    T.it("runs f on the success value", function()
      --: (v: integer) -> { kind: "ok", value: integer }
      local succ = function(v) return R.ok(v + 1) end
      local r = R.bind(R.ok(2), succ)
      T.eq(r.value, 3)
    end)

    T.it("f may return an error, which becomes the result", function()
      --: (v: integer) -> { kind: "err", error: string }
      local fail = function(_) return R.err("rejected") end
      local r = R.bind(R.ok(2), fail)
      T.eq(r.kind, "err")
      T.eq(r.error, "rejected")
    end)

    T.it("short-circuits on an incoming error", function()
      local called = false
      --: (v: integer) -> { kind: "ok", value: integer }
      local mark = function(v) called = true; return R.ok(v) end
      local r = R.bind(R.err("first"), mark)
      T.eq(called, false)
      T.eq(r.error, "first")
    end)

  end)

  T.describe("match", function()

    --: (v: integer) -> string
    local function on_ok(v) return "ok:" .. v end
    --: (e: string) -> string
    local function on_err(e) return "err:" .. e end

    T.it("folds the ok arm", function()
      T.eq(R.match(R.ok(3), { ok = on_ok, err = on_err }), "ok:3")
    end)

    T.it("folds the err arm", function()
      T.eq(R.match(R.err("x"), { ok = on_ok, err = on_err }), "err:x")
    end)

    T.it("only the matching arm runs", function()
      local err_called = false
      --: (e: string) -> string
      local mark = function(e) err_called = true; return e end
      R.match(R.ok(1), { ok = on_ok, err = mark })
      T.eq(err_called, false)
    end)

  end)

  -- ── StreamEffect ───────────────────────────────────────────────────────

  T.describe("stream effect predicates", function()

    T.it("recognizes a progress effect", function()
      local p = { kind = "progress", progress = 3, total = 10 }
      T.eq(R.is_stream_effect(p), true)
      T.eq(R.is_stream_progress(p), true)
      T.eq(R.is_stream_chunk(p), false)
    end)

    T.it("recognizes a chunk effect", function()
      local c = { kind = "chunk", data = { 1, 2 } }
      T.eq(R.is_stream_effect(c), true)
      T.eq(R.is_stream_chunk(c), true)
      T.eq(R.is_stream_progress(c), false)
    end)

    T.it("a progress effect's optional fields are optional", function()
      T.eq(R.is_stream_progress({ kind = "progress", progress = 1 }), true)
    end)

    T.it("rejects an unrelated kind", function()
      T.eq(R.is_stream_effect({ kind = "ok", value = 1 }), false)
      T.eq(R.is_stream_chunk({ kind = "data", data = 1 }), false)
    end)

    T.it("rejects non-tables", function()
      T.eq(R.is_stream_effect("chunk"), false)
      T.eq(R.is_stream_progress(nil), false)
      T.eq(R.is_stream_chunk(7), false)
    end)

    T.it("a Result is not a stream effect, and vice versa", function()
      T.eq(R.is_stream_effect(R.ok(1)), false)
      T.eq(R.is_result_shape({ kind = "chunk", data = 1 }), false)
    end)

  end)

  -- ── ErrorEncoder ───────────────────────────────────────────────────────

  T.describe("match_kind", function()

    T.it("returns the response on a kind match", function()
      local enc = R.match_kind("notFound", 404)
      T.eq(enc({ kind = "notFound", message = "gone" }), 404)
    end)

    T.it("returns nil on a different kind", function()
      local enc = R.match_kind("notFound", 404)
      T.eq(enc({ kind = "conflict" }), nil)
    end)

    T.it("returns nil for a table with no kind", function()
      local enc = R.match_kind("notFound", 404)
      T.eq(enc({ message = "gone" }), nil)
    end)

    T.it("returns nil for a non-table error", function()
      local enc = R.match_kind("notFound", 404)
      T.eq(enc("notFound"), nil)
    end)

  end)

  T.describe("compose_error_encoders", function()

    T.it("returns the first non-nil result", function()
      local enc = R.compose_error_encoders(
        R.match_kind("notFound", 404),
        R.match_kind("conflict", 409))
      T.eq(enc({ kind = "conflict" }), 409)
    end)

    T.it("tries encoders in order — an earlier match wins", function()
      local enc = R.compose_error_encoders(
        R.match_kind("x", "first"),
        R.match_kind("x", "second"))
      T.eq(enc({ kind = "x" }), "first")
    end)

    T.it("returns nil when none matched, so the caller falls back", function()
      local enc = R.compose_error_encoders(R.match_kind("notFound", 404))
      T.eq(enc({ kind = "unknownThing" }), nil)
    end)

    T.it("with no encoders always returns nil", function()
      local enc = R.compose_error_encoders()
      T.eq(enc({ kind = "anything" }), nil)
    end)

    T.it("does not consult later encoders after a match", function()
      local reached = false
      --: (e: unknown) -> (integer | nil)
      local trap = function(_) reached = true; return 2 end
      local enc = R.compose_error_encoders(R.match_kind("x", 1), trap)
      T.eq(enc({ kind = "x" }), 1)
      T.eq(reached, false)
    end)

    T.it("composes to another encoder, so composition nests", function()
      local inner = R.compose_error_encoders(R.match_kind("a", 1))
      local outer = R.compose_error_encoders(inner, R.match_kind("b", 2))
      T.eq(outer({ kind = "a" }), 1)
      T.eq(outer({ kind = "b" }), 2)
      T.eq(outer({ kind = "c" }), nil)
    end)

  end)

  -- ── derived combinators ────────────────────────────────────────────────

  T.describe("compose_k", function()

    T.it("threads a Result through a fallible chain", function()
      --: (a: integer) -> { kind: "ok", value: integer }
      local f = function(a) return R.ok(a + 1) end
      --: (b: integer) -> { kind: "ok", value: integer }
      local g = function(b) return R.ok(b * 2) end
      local r = R.compose_k(f)(g)(3)
      T.eq(r.kind, "ok")
      T.eq(r.value, 8)
    end)

    T.it("short-circuits on the first error", function()
      local reached = false
      --: (a: integer) -> { kind: "err", error: string }
      local f = function(_) return R.err("first") end
      --: (b: integer) -> { kind: "ok", value: integer }
      local g = function(b) reached = true; return R.ok(b) end
      local r = R.compose_k(f)(g)(3)
      T.eq(r.kind, "err")
      T.eq(r.error, "first")
      T.eq(reached, false)
    end)

    T.it("surfaces an error raised by the second step", function()
      --: (a: integer) -> { kind: "ok", value: integer }
      local f = function(a) return R.ok(a) end
      --: (b: integer) -> { kind: "err", error: string }
      local g = function(_) return R.err("second") end
      local r = R.compose_k(f)(g)(3)
      T.eq(r.error, "second")
    end)

    T.it("agrees with an explicit bind chain", function()
      --: (a: integer) -> { kind: "ok", value: integer }
      local f = function(a) return R.ok(a + 1) end
      --: (b: integer) -> { kind: "ok", value: integer }
      local g = function(b) return R.ok(b * 2) end
      T.eq(R.compose_k(f)(g)(3).value, R.bind(f(3), g).value)
    end)

  end)

end)
