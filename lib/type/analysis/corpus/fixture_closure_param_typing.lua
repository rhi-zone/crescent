-- Fixture: typed closure parameter corrupts multi-return inference of outer call
--
-- Source fire: lib/web/reactive_dom/init.lua, beside() function; commit
--   40f3da91. Comment at lines 192-194: "beside(w1, w2): both widgets are
--   intentionally untyped in closures; typing them causes widget.with_scope
--   to mistype cleanup (checker bug)".
--
-- What a CORRECT checker must conclude:
--   Given `with_scope: ((Signal) -> Node) -> (Node, () -> ())`, calling it
--   with a closure that internally calls a typed function must still produce
--   the correct multi-return: the second return value must be `() -> ()`,
--   never `nil`. Typing the called function inside the closure must not corrupt
--   the inferred type of the outer call's second return slot.
--
-- Feature families:
--   - Higher-order functions (function taking a typed function)
--   - Closure / anonymous function type inference
--   - Multi-return type inference and destructuring
--   - Call-site return-slot inference under typed closure arguments
--
-- Legacy verdict (CURRENT checker): 1 error — `c1()` and `c2()` cannot be
--   called because they are inferred as `nil`. The typing of `w` (the inner
--   typed function) inside the closure passed to `with_scope` causes the
--   multi-return to incorrectly yield `nil` for the second slot.
--   A correct checker must accept this with 0 errors.

--:: Signal = { get: () -> unknown }
--:: Node   = { kind: string }

--: ((Signal) -> Node) -> (Node, () -> ())
local function with_scope(fn)
  local sig = { get = function() return nil end }
  local node = fn(sig)
  return node, function() end
end

--: () -> nil
local function test_typed_inner()
  --: (Signal) -> Node
  local w = function(s) return { kind = "a" } end
  -- Gap: typing `w` above causes `c1` to be inferred as `nil` instead of
  -- `() -> ()`. An untyped closure works fine; a typed one does not.
  local n1, c1 = with_scope(function(s) return w(s) end)
  c1()  -- must not error: c1 is () -> (), not nil
end

return { test_typed_inner = test_typed_inner }
