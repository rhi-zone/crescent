-- lib/api-tree/result.lua — the function-core model base, ported from
-- fractal's packages/api-tree/src/index.ts.
--
--   - The function category: plain functions composed with `compose`/`pipe`.
--   - `Result` — the fallible-value type — plus `map`/`bind`/`match`.
--   - `StreamEffect` — tagged values a streaming handler yields.
--   - `ErrorEncoder` — composable error-to-transport mapping.
--   - Derived combinators: `compose_k` (Kleisli). NEVER the base.
--
-- WIRE FORMAT. A `Result` here is fractal's own `{ kind = "ok", value = v }` /
-- `{ kind = "err", error = e }`, and a `StreamEffect` its
-- `{ kind = "progress"|"chunk", ... }` — deliberately NOT `lib/result`'s
-- `{ _tag, _val }`-plus-methods encoding. These values are shape-sniffed
-- across the language boundary against the TypeScript side, so the field
-- names are part of the contract, not an internal choice. `lib/result` is a
-- separate, self-contained library and is untouched by this module.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── The function category — the base ─────────────────────────────────────

--:: Fn<A, B> = (a: A) -> B

-- Ordinary function composition: `compose(f)(g)` is `a -> g(f(a))`.
--: <A, B, C>(f: Fn<A, B>) -> ((g: Fn<B, C>) -> Fn<A, C>)
function M.compose(f)
	return function(g)
		return function(a)
			return g(f(a))
		end
	end
end

-- Left-to-right value threading: `pipe(a, f, g)` is `g(f(a))`. With no
-- functions, `a` passes through unchanged.
--
-- TYPECHECKER WORKAROUND: this is the one signature in the module that is
-- imprecise. The TypeScript original types `pipe` with a family of
-- fixed-arity overloads, one per stage count, which is what lets each stage's
-- output type flow into the next stage's input. Crescent has no overload
-- mechanism, and a variadic parameter takes a single type, so every stage is
-- typed `(a: unknown) -> unknown` and each callback has to narrow its own
-- argument. `compose` next to it IS precisely typed — reach for it, or for a
-- plain nested call, when the intermediate types matter. See TODO.md.
--: (a: unknown, ...Fn<unknown, unknown>) -> unknown
function M.pipe(a, ...)
	local acc = a
	local n = select("#", ...)
	local fns = { ... } --[[: { [integer]: Fn<unknown, unknown> }]]
	for i = 1, n do
		acc = fns[i](acc)
	end
	return acc
end

-- ── Result — the fallible-value type ─────────────────────────────────────

-- `kind` is a literal type on each arm, not a bare `string`: that is what
-- makes `r.kind == "ok"` narrow the union at every read site below, so none
-- of `map`/`bind`/`match` needs a cast to reach `value`/`error`.
--:: ResultOk<T> = { kind: "ok", value: T }
--:: ResultErr<E> = { kind: "err", error: E }
--:: Result<T, E> = ResultOk<T> | ResultErr<E>

-- Returns the `ok` arm alone rather than a full `Result`, mirroring the TS
-- `Result<T, never>`: a value that unifies with a `Result` carrying any error
-- type, since the caller has not chosen one yet.
--: <T>(value: T) -> ResultOk<T>
function M.ok(value)
	return { kind = "ok", value = value }
end

--: <E>(error_value: E) -> ResultErr<E>
function M.err(error_value)
	return { kind = "err", error = error_value }
end

--: <T, E>(r: Result<T, E>) -> boolean
function M.is_ok(r)
	return r.kind == "ok"
end

--: <T, E>(r: Result<T, E>) -> boolean
function M.is_err(r)
	return r.kind == "err"
end

-- Loose structural check: true when `v` matches the `Result` shape at
-- runtime, without its static type already being known as a `Result`. For a
-- dispatcher holding an erased handler return value that must decide whether
-- it IS a Result before narrowing with `is_ok`/`is_err`. Exact on `kind`
-- (only "ok"/"err" match) so user data carrying an unrelated `kind` field
-- never false-positives.
--: (v: unknown) -> boolean
function M.is_result_shape(v)
	if type(v) ~= "table" then return false end
	local kind = v.kind
	return kind == "ok" or kind == "err"
end

-- Map the success value; pass an error through untouched.
--: <T, E, U>(r: Result<T, E>, f: Fn<T, U>) -> Result<U, E>
function M.map(r, f)
	if r.kind == "ok" then
		return { kind = "ok", value = f(r.value) }
	end
	return r
end

-- Monadic bind: run `f` on the success value, short-circuit on error. The
-- primitive Kleisli composition is built from.
--: <T, E, U>(r: Result<T, E>, f: Fn<T, Result<U, E>>) -> Result<U, E>
function M.bind(r, f)
	if r.kind == "ok" then
		return f(r.value)
	end
	return r
end

-- Fold a Result into a single value by matching both arms. A projector's
-- final encode stage is exactly `match(r, { ok = ..., err = ... })`.
--: <T, E, R>(r: Result<T, E>, arms: { ok: Fn<T, R>, err: Fn<E, R> }) -> R
function M.match(r, arms)
	if r.kind == "ok" then
		return arms.ok(r.value)
	end
	return arms.err(r.error)
end

-- ── StreamEffect — tagged values a streaming handler yields ──────────────
--
-- A progress effect is `{ kind = "progress", progress = n, total? = n,
-- message? = s }` — provenance-blind, yielded identically whether a
-- projector renders it as SSE, an MCP progress notification, or a CLI
-- stderr line. A chunk effect is `{ kind = "chunk", data = v }`, one piece
-- of streamed data. The DU is open: another `kind` can be added without
-- touching the existing arms.
--
-- Detection is opt-in at the projector level, not automatic sniffing of
-- every yielded value; each predicate is exact on `kind` so a handler's own
-- chunk data carrying an unrelated `kind` field never false-positives.

--:: StreamProgress = { kind: "progress", progress: number, total?: number, message?: string }
--:: StreamChunk<T> = { kind: "chunk", data: T }
--:: StreamEffect<T> = StreamProgress | StreamChunk<T>

--: (value: unknown) -> boolean
function M.is_stream_effect(value)
	if type(value) ~= "table" then return false end
	local kind = value.kind
	return kind == "progress" or kind == "chunk"
end

--: (value: unknown) -> boolean
function M.is_stream_progress(value)
	if type(value) ~= "table" then return false end
	return value.kind == "progress"
end

--: (value: unknown) -> boolean
function M.is_stream_chunk(value)
	if type(value) ~= "table" then return false end
	return value.kind == "chunk"
end

-- ── ErrorEncoder — composable error-to-transport mapping ─────────────────
--
-- An encoder maps a transport-agnostic error value (the error arm of a
-- Result, e.g. `{ kind = "notFound", message = "..." }` — no transport
-- concepts baked in) to a transport-specific response: an HTTP status, a CLI
-- exit code, an MCP error code. It returns nil when it does not recognize
-- the error, signalling the caller to fall through to the next encoder or to
-- the projector's own default.

-- The return is parenthesised deliberately: without it the `|` binds outside
-- the arrow, making the alias "a function OR nil" rather than "a function
-- returning R or nil".
--:: ErrorEncoder<E, R> = (error_value: E) -> (R | nil)

-- Compose several encoders into one: try each in order, returning the first
-- non-nil result, and nil when none matched.
--: <E, R>(...ErrorEncoder<E, R>) -> ErrorEncoder<E, R>
function M.compose_error_encoders(...)
	local n = select("#", ...)
	local encoders = { ... }
	return function(error_value)
		for i = 1, n do
			local result = encoders[i](error_value)
			if result ~= nil then return result end
		end
		return nil
	end
end

-- An encoder matching an error whose `kind` field equals `kind` — the open-DU
-- convention this model already uses for Result, StreamEffect, and tree meta
-- — returning `response` on a match and nil otherwise. The match is a runtime
-- shape check, so one `match_kind` encoder composes with any error type.
-- TYPECHECKER WORKAROUND: the natural signature is
--   <R>(kind: string, response: R) -> ErrorEncoder<unknown, R>
-- which would carry the response type through to the composed encoder. It is
-- rejected: inside a generic function, returning a closure whose own return
-- is `R | nil` fails with "`_` in union is not assignable to `_ | nil`" — the
-- checker does not accept an unsolved type parameter as a member of a union
-- formed from itself. The identical non-generic signature (`response:
-- string` -> `string | nil`) checks clean, so this is not about the shape.
-- `unknown` is used for the response instead, so a caller must narrow what
-- comes back out of the encoder. Restore the generic signature when the gap
-- is fixed — see TODO.md.
--: (kind: string, response: unknown) -> ErrorEncoder<unknown, unknown>
function M.match_kind(kind, response)
	return function(error_value)
		if type(error_value) == "table" and error_value.kind == kind then
			return response
		end
		return nil
	end
end

-- ── Derived combinators — Kleisli. NEVER the base. ───────────────────────

-- Kleisli composition over Result: `compose_k(f)(g)` is
-- `a -> bind(f(a), g)`. Threads a Result through a fallible chain,
-- short-circuiting on the first error. Derived from `compose` + `bind`.
--: <A, B, C, E>(f: Fn<A, Result<B, E>>) -> ((g: Fn<B, Result<C, E>>) -> Fn<A, Result<C, E>>)
function M.compose_k(f)
	return function(g)
		return function(a)
			return M.bind(f(a), g)
		end
	end
end

return M
