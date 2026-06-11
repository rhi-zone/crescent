-- Fixture: tonumber() return type inference (gap — verified fixed)
--
-- Source fire: lib/safe_regex/init.lua lines 148-151; commit 02812180
--   (worked around by annotating the intermediate string local with `--: string`
--   to ensure `tonumber` received a correctly-typed argument).
--
-- What a CORRECT checker must conclude:
--   `tonumber(s)` where `s: string` must infer as `number | nil` — nil when
--   the string is not a valid number. Without an explicit `--: string`
--   annotation on the intermediate `n_str`, `tonumber(n_str)` must still
--   produce `number | nil`. Accessing `math.floor(n_raw)` after a nil-guard
--   must succeed (n_raw narrows to `number`).
--
-- Feature families:
--   - Standard library typing (`tonumber`, `string.sub`)
--   - Function call return type inference for stdlib functions
--   - `number | nil` union from stdlib calls that can fail to parse
--   - Nil-narrowing after `if not n then return end` guard
--
-- Legacy verdict (CURRENT checker): 0 errors. The gap documented in
--   the workaround comment is FIXED. This fixture records it as a
--   regression guard: any future checker must also produce 0 errors.

--: (string, integer, integer) -> (integer | nil)
local function parse_int_slice(s, i, j)
  -- No explicit `--: string` annotation needed on n_str.
  -- A correct checker must infer tonumber(string) as `number | nil`.
  local n_str = string.sub(s, i, j)
  local n_raw = tonumber(n_str)
  if not n_raw then return nil end
  return math.floor(n_raw)
end

return { parse_int_slice = parse_int_slice }
