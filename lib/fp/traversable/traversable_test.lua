-- lib/fp/traversable/traversable_test.lua
-- Tests for the Traversable typeclass with Maybe and Either instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local Traversable = require("lib.fp.traversable")
local Maybe       = require("lib.fp.maybe")
local Either      = require("lib.fp.either")

-- ── Maybe Traversable: Nothing ─────────────────────────────────────────────

T.describe("Traversable.traverse on Nothing (Maybe applicative)", function()
	T.it("returns pure(ctor, Nothing)", function()
		-- traverse(f, Nothing, ctor) = pure(ctor, Maybe.nothing)
		-- Using Maybe.nothing as ctor so pure dispatches to Maybe Applicable
		local f   = function(x) return Maybe.just(x * 2) end
		local r   = Traversable.traverse(f, Maybe.nothing, Maybe.nothing)
		-- f is never called; result is Just(Nothing)
		T.ok(Maybe.is_just(r))
		T.eq(r.value, Maybe.nothing)
	end)

	T.it("does not call f", function()
		local called = false
		local f = function(_x)
			called = true
			return Maybe.just(0)
		end
		Traversable.traverse(f, Maybe.nothing, Maybe.nothing)
		T.ok(not called)
	end)
end)

-- ── Maybe Traversable: Just ────────────────────────────────────────────────

T.describe("Traversable.traverse on Just (Maybe applicative)", function()
	T.it("traverse(f, Just(a), ctor) = map(just, f(a))", function()
		-- f :: a -> Maybe b; result = map(just, f(a)) = Just(Just(b))
		-- i.e. traverse wraps the effect and reconstructs Just around it
		local f = function(x) return Maybe.just(x + 10) end
		local r = Traversable.traverse(f, Maybe.just(5), Maybe.nothing)
		-- f(5) = Just(15); map(just, Just(15)) = Just(Just(15))
		T.ok(Maybe.is_just(r))
		T.ok(Maybe.is_just(r.value))
		T.eq(r.value.value, 15)
	end)

	T.it("traverse with f returning Nothing propagates Nothing", function()
		-- f :: a -> Maybe b; if f returns Nothing, map(just, Nothing) = Nothing
		local f = function(_x) return Maybe.nothing end
		local r = Traversable.traverse(f, Maybe.just(5), Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── Either Traversable: Left ───────────────────────────────────────────────

T.describe("Traversable.traverse on Left (Maybe applicative)", function()
	T.it("traverse(f, Left(e), ctor) = pure(ctor, Left(e))", function()
		-- Left is right-biased; traverse short-circuits and wraps the Left
		local f = function(x) return Maybe.just(x) end
		local r = Traversable.traverse(f, Either.left("err"), Maybe.nothing)
		-- result = Just(Left("err"))
		T.ok(Maybe.is_just(r))
		T.ok(Either.is_left(r.value))
		T.eq(r.value.value, "err")
	end)

	T.it("does not call f for Left", function()
		local called = false
		local f = function(_x)
			called = true
			return Maybe.just(0)
		end
		Traversable.traverse(f, Either.left("e"), Maybe.nothing)
		T.ok(not called)
	end)
end)

-- ── Either Traversable: Right ──────────────────────────────────────────────

T.describe("Traversable.traverse on Right (Maybe applicative)", function()
	T.it("traverse(f, Right(a), ctor) = map(right, f(a))", function()
		local f = function(x) return Maybe.just(x * 3) end
		local r = Traversable.traverse(f, Either.right(7), Maybe.nothing)
		-- f(7) = Just(21); map(right, Just(21)) = Just(Right(21))
		T.ok(Maybe.is_just(r))
		T.ok(Either.is_right(r.value))
		T.eq(r.value.value, 21)
	end)

	T.it("traverse with f returning Nothing propagates Nothing", function()
		local f = function(_x) return Maybe.nothing end
		local r = Traversable.traverse(f, Either.right(7), Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── sequence ──────────────────────────────────────────────────────────────

T.describe("Traversable.sequence on Maybe", function()
	T.it("sequence(Just(Just(1)), ctor) = Just(Just(1))", function()
		-- sequence = traverse(id); Just(Just(1)) → map(just, Just(1)) = Just(Just(1))
		local r = Traversable.sequence(Maybe.just(Maybe.just(1)), Maybe.nothing)
		T.ok(Maybe.is_just(r))
		T.ok(Maybe.is_just(r.value))
		T.eq(r.value.value, 1)
	end)

	T.it("sequence(Just(Nothing), ctor) = Nothing", function()
		-- sequence = traverse(id); Just(Nothing) → map(just, Nothing) = Nothing
		local r = Traversable.sequence(Maybe.just(Maybe.nothing), Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)

	T.it("sequence(Nothing, ctor) = Just(Nothing)", function()
		-- traverse(id, Nothing, ctor) = pure(ctor, Nothing) = Just(Nothing)
		local r = Traversable.sequence(Maybe.nothing, Maybe.nothing)
		T.ok(Maybe.is_just(r))
		T.eq(r.value, Maybe.nothing)
	end)
end)

-- ── traverse with Either as applicative ───────────────────────────────────

T.describe("Traversable.traverse with Either applicative", function()
	T.it("traverse on Just with Either f returning Right", function()
		-- f :: a -> Either e b; Right-biased pure lifts into Right
		local f = function(x) return Either.right(x + 100) end
		local r = Traversable.traverse(f, Maybe.just(5), Either.right(0))
		-- f(5) = Right(105); map(just, Right(105)) = Right(Just(105))
		T.ok(Either.is_right(r))
		T.ok(Maybe.is_just(r.value))
		T.eq(r.value.value, 105)
	end)

	T.it("traverse on Just with Either f returning Left propagates Left", function()
		local f = function(_x) return Either.left("fail") end
		local r = Traversable.traverse(f, Maybe.just(5), Either.right(0))
		-- f(5) = Left("fail"); map(just, Left("fail")) = Left("fail")
		T.ok(Either.is_left(r))
		T.eq(r.value, "fail")
	end)

	T.it("traverse on Nothing with Either applicative = Right(Nothing)", function()
		local f = function(x) return Either.right(x) end
		local r = Traversable.traverse(f, Maybe.nothing, Either.right(0))
		-- pure(ctor, Nothing) = Right(Nothing)
		T.ok(Either.is_right(r))
		T.eq(r.value, Maybe.nothing)
	end)

	T.it("traverse on Left(e) with Either applicative = Right(Left(e))", function()
		local f = function(x) return Either.right(x) end
		local r = Traversable.traverse(f, Either.left("e"), Either.right(0))
		-- pure(ctor, Left("e")) = Right(Left("e"))
		T.ok(Either.is_right(r))
		T.ok(Either.is_left(r.value))
		T.eq(r.value.value, "e")
	end)

	T.it("traverse on Right(a) with Either applicative = map(right, f(a))", function()
		local f = function(x) return Either.right(x * 2) end
		local r = Traversable.traverse(f, Either.right(4), Either.right(0))
		-- f(4) = Right(8); map(right, Right(8)) = Right(Right(8))
		T.ok(Either.is_right(r))
		T.ok(Either.is_right(r.value))
		T.eq(r.value.value, 8)
	end)
end)
