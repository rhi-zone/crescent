-- Fixture: checked cast on one argument must NOT influence inference of other args
--
-- Source fire: lib/type/static/solve.lua:579; TODO-typecheck.md: "force casts
--   act as inference sources via external constraints — the real surviving site
--   is solve.lua:579 — the destructive `unify(ctx, widened, expected)` on the
--   checked-cast/param-binding path that binds an unannotated param's free
--   TAG_VAR when caller C_SUB arrives." See docs/typechecker-param-semantics.md.
--
-- What a CORRECT checker must conclude:
--   In a call `f(x --[[:! T]], y)` where `f` has an annotated signature,
--   the checked cast on `x` applies only to `x`. The type check of `y` against
--   the corresponding parameter must be governed solely by `y`'s own type, not
--   by `T`. A `--[[:! integer]]` cast on one argument must not cause the checker
--   to treat an unrelated `string` argument as `integer` or vice versa.
--   The REDUNDANT_CAST diagnostic must not fire for a cast that is genuinely
--   needed (i.e. where the actual type is not already the target type).
--
-- Feature families:
--   - Checked cast (`--[[:! T]]`) directional scope
--   - Parameter binding in the constraint solver (unidirectional: arg → param)
--   - Multi-argument call type checking independence
--   - REDUNDANT_CAST diagnostic must not suppress genuine casts
--
-- Legacy verdict (CURRENT checker): 1 error — "redundant force cast" fires
--   on `x --[[:! integer]]` because the checker already inferred `x: integer`
--   from the annotation on the local. The gap (bidirectional unify at
--   solve.lua:579) is not directly observable from this form; the error surface
--   is the REDUNDANT_CAST false-positive when a cast is used defensively.
--   A correct checker: accepts the cast without REDUNDANT_CAST if the type
--   is already assignable but the annotation is explicit intent documentation;
--   OR flags REDUNDANT_CAST only when the cast is provably unnecessary.

--: (integer, string) -> string
local function format_pair(n, s)
  return tostring(n) .. ":" .. s
end

--: () -> string
local function demonstrate_isolation()
  local x = 42 --: integer
  local y = "hello" --: string
  -- This cast is "redundant" by the checker's logic (x is already integer).
  -- However, the cast documents explicit intent and should not error.
  -- A correct checker either: accepts documented redundant casts, OR only
  -- raises REDUNDANT_CAST as a warning, never a hard error.
  return format_pair(x --[[:! integer]], y)
end

return { demonstrate_isolation = demonstrate_isolation }
