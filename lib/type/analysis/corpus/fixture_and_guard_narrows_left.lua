-- Fixture: `if x and <expr>` narrows x in the truthy branch (audit round 4)
--
-- Source fire: audit round 4 mandate-B dominant false-positive. The slice
--   narrows a bare truthy test (`if title then`) but dropped the narrowing
--   when the test was an `and`-compound (`if title and title ~= "" then`):
--   the adapter's recognize_guard returned nil for the whole `and` whenever
--   the RIGHT operand was not itself a recognized guard shape (e.g. a
--   comparison not in the five v1 forms, or a function call).
--
-- What a CORRECT checker must conclude:
--   Inside `if x and <anything>` the truthy branch knows `x` is truthy. When
--   `x : string | nil`, `x` must be narrowed to `string` inside the branch.
--   A function that uses `x` as `string` after such a guard must be ACCEPTED.
--   The fix: for `and`, recognize_guard keeps the LEFT guard (the truthy `x`)
--   even when the right operand is an unrecognized expression.
--
-- Feature families:
--   - Truthy narrowing under `and`-compound guards
--   - Bare variable as the left operand of `and` is itself a guard form

--: (string | nil, string) -> string
local function get_or_default(title, fallback)
  if title and fallback ~= "" then
    return title
  end
  return fallback
end

--: (string | nil) -> integer
local function length_if_present(s)
  if s and s ~= "" then
    return #s
  end
  return 0
end

return { get_or_default = get_or_default, length_if_present = length_if_present }
