-- Fixture: $PairsReturn leaking into call result types from pairs() loops
--
-- Source fire: lib/type/static/constrain.lua ~line 4182; comment: "Direct
--   assignment triggers a typechecker bug when else_neg is built by pairs()
--   loops ($PairsReturn leaks into call result type). Intermediate variable
--   breaks the constraint chain."
--
-- What a CORRECT checker must conclude:
--   A table populated via `for k, v in pairs(other_table) do merged[k] = v end`
--   must have a clean inferred type for `merged` — specifically `{ [string]: integer }`
--   when iterating a `{ [string]: integer }` table. The `$PairsReturn` internal
--   iterator type must NOT appear in the inferred type of `merged` at any call
--   site. Passing `merged` to a function expecting `{ [string]: integer }` must
--   succeed without requiring an intermediate variable workaround.
--
-- Feature families:
--   - `pairs()` for-in loop typing
--   - Table construction via loop-based field assignment
--   - Call argument type — no internal iterator types bleeding into user type
--   - `$PairsReturn` intrinsic must not escape into user-visible argument positions
--
-- Legacy verdict (CURRENT checker): 0 errors. The $PairsReturn leak documented
--   in constrain.lua's workaround comment is FIXED (or the test form is not
--   sufficient to trigger it in isolation). This fixture records the gap for
--   regression protection. A future checker must also accept with 0 errors.

--: ({ [string]: integer }) -> integer
local function sum_values(t)
  local s = 0
  for _, v in pairs(t) do
    s = s + v
  end
  return s
end

--: ({ [string]: integer }, { [string]: integer }) -> integer
local function merge_and_sum(a, b)
  local merged = {}
  for k, v in pairs(a) do
    merged[k] = v
  end
  for k, v in pairs(b) do
    merged[k] = v
  end
  -- Gap: passing `merged` (built by pairs() loops) used to surface $PairsReturn
  -- in the inferred type, causing a call-site type mismatch here.
  return sum_values(merged)
end

return { merge_and_sum = merge_and_sum }
