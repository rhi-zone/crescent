-- Fixture: rec_with_indexer dynamic-key READ soundness (audit round 4 A-F1)
--
-- Source fire: audit round 4 adversarial probe. Before the fix, `t[k]` over
--   `{ a: string, [string]: integer }` under a dynamic key was typed as
--   `integer` only, dropping the listed-field type `string`. A runtime key
--   `"a"` yields the field value, a string — so the pre-fix result was unsound.
--
-- What a CORRECT checker must conclude:
--   `t[k]` where `t : { a: string, [string]: integer }` and `k : string` has
--   type `string | integer` (the union of all listed field value types joined
--   with the indexer value type). A function annotated to return `string | integer`
--   must be accepted (0 errors). This is the sound annotation for this pattern.
--
-- The pre-fix unsound typing (returning only `integer`) is tested in
-- crescent_slice_test.lua via a direct `index_result` call.
--
-- Feature families:
--   - `rec_with_indexer` (named fields + index signature)
--   - Dynamic-index reads (`t[e]`) with a non-literal key
--   - Sound union of field types in the dynamic read result (§6.9.2 / A-F1)

--:: RWI = { a: string, [string]: integer }

-- Sound annotation: the result of t[k] over a rec_with_indexer is the union
-- of all listed field value types | the indexer value type. Must ACCEPT.
--: (RWI, string) -> (string | integer)
local function f_sound(t, k) return t[k] end

return { f_sound = f_sound }
