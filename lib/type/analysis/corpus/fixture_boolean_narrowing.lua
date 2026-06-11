-- Fixture: boolean narrowing of `and`-chained comparisons
--
-- Source fire: lib/type/v7_mr0/canonical.lua; commit fcfdd612 (TODO comment);
--   also documented in TODO-typecheck.md.
--
-- What a CORRECT checker must conclude:
--   The expression `n == 0 and 1 / n < 0` has type `boolean`. Both sub-
--   expressions (`n == 0` and `1 / n < 0`) are boolean; `and` of two booleans
--   is boolean. The legacy checker inferred `nil | boolean` because it modelled
--   `and` as "first operand if falsy, second operand otherwise" without
--   intersecting the narrowed boolean result. No workaround needed; the function
--   must be accepted with return type `boolean`.
--
-- Feature families:
--   - Boolean type and literal types (`true`, `false`)
--   - Comparison operators returning `boolean`
--   - `and` operator narrowing / short-circuit typing
--   - Function return type checking

--: (number) -> boolean
local function is_negative_zero(n)
  return n == 0 and 1 / n < 0
end

return { is_negative_zero = is_negative_zero }
