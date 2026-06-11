-- Fixture: missing flow-sensitive table-construction widening (literal inference)
--
-- Source fire: lib/asm/ir.lua lines 219, 251, 261, 342; TODO.md documents the
--   "unknown→any→T two-step" for table construction. The checker infers the
--   type of a table from the FIRST assignment (as a literal type), then rejects
--   subsequent assignments whose literal types differ.
--
-- What a CORRECT checker must conclude:
--   When a table is constructed by sequential field assignment at integer keys,
--   each assignment's value must be widened to the declared element type (e.g.
--   `Insn`), NOT frozen at the literal type of the first assignment. The table
--   `insns` after both assignments must be compatible with
--   `{ [integer]: Insn, ... }`. The checked cast `--[[:! { [integer]: Insn, ...}]]`
--   must be accepted without errors (it is a valid structural assertion about
--   the runtime shape).
--
-- Feature families:
--   - Table type inference / construction widening
--   - Literal type inference at table assignment sites
--   - Flow-sensitive type merging across multiple assignments
--   - Checked cast (`--[[:! T]]`) as structural assertion on built tables
--   - Index signatures (`{ [integer]: T, ... }`)
--
-- Legacy verdict (CURRENT checker): 2 errors.
--   Error 1: "cannot assign `{ dst: nil, op: \"ret\", pos: 2 }` to
--   `{ dst: 0, op: \"add\", pos: 1 }`" — the checker locked the table's element
--   type at the literal type of the first element.
--   Error 2: "redundant force cast" — because after the first error, the
--   table type was already locked.
--   A correct checker must produce 0 errors.

--:: Insn = { op: string, dst: integer | nil, pos: integer }

--: () -> { [integer]: Insn, ... }
local function build_insns()
  local insns = {}
  insns[1] = { op = "add", dst = 0, pos = 1 }
  -- Gap: checker locks insns' element type at `{ dst: 0, op: "add", pos: 1 }` (literal).
  -- Subsequent assignment with `dst = nil` and `op = "ret"` is rejected
  -- even though both conform to the declared `Insn` alias.
  insns[2] = { op = "ret", dst = nil, pos = 2 }
  return insns --[[:! { [integer]: Insn, ... }]]
end

return { build_insns = build_insns }
