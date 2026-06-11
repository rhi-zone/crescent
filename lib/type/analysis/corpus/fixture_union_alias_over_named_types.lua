-- Fixture: union type alias over named table types (v3 gap — verified fixed)
--
-- Source fire: lib/imap/format_types.lua line 53; comment: "TODO: v3 gap —
--   union aliases over named table types not yet supported".
--
-- What a CORRECT checker must conclude:
--   A type alias of the form `--:: AnyCmd = LoginCmd | LogoutCmd` where both
--   `LoginCmd` and `LogoutCmd` are themselves named table-type aliases must be
--   accepted. Functions declared to return `AnyCmd` must accept values of
--   either constituent type. Field access on `AnyCmd` must be restricted to
--   fields present in ALL members (the intersection of field sets).
--
-- Feature families:
--   - Type aliases (`--:: Foo = ...`)
--   - Union types of named aliases (`A | B` where A, B are --:: declared)
--   - Field access on union types (only fields common to all members)
--   - Function return type checking against a union alias
--
-- Legacy verdict (CURRENT checker): 0 errors. The v3 gap documented in
--   imap/format_types.lua is FIXED in the current checker. This fixture
--   records the gap's prior existence and confirms the fix is stable.
--   Any future checker must also accept this with 0 errors.

--:: LoginCmd  = { tag: string, type: string, user: string }
--:: LogoutCmd = { tag: string, type: string }
--:: AnyCmd    = LoginCmd | LogoutCmd

--: (string) -> AnyCmd
local function make_cmd(kind)
  if kind == "login" then
    return { tag = "abc", type = "login", user = "alice" }
  end
  return { tag = "abc", type = "logout" }
end

--: (AnyCmd) -> string
local function cmd_tag(cmd)
  -- `tag` is present in both LoginCmd and LogoutCmd — accessible without narrowing.
  return cmd.tag
end

return { make_cmd = make_cmd, cmd_tag = cmd_tag }
