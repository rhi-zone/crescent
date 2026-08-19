-- lib/type-ir/codegen.lua — structural helpers shared across the
-- TypeRef projector modules, ported from fractal's
-- packages/type-ir/src/codegen-helpers.ts.
--
-- fractal's file is the single canonical copy of scaffolding that every
-- projector had previously reimplemented byte-for-byte. Only the subset the
-- currently-ported projectors need is here — identifier casing, the subtype
-- check, and string quoting. The rest of codegen-helpers.ts (the per-ecosystem
-- doc-comment renderers, indentation, options merging) belongs with the
-- projectors that use them and is ported alongside those, not ahead of them.
--
-- Naming note: `lib/string_ext` has near-namesakes (`pascal_case`,
-- `snake_case`) which are NOT substitutes. Those handle only space/`-`/`_` as
-- separators; the fractal variants strip EVERY non-alphanumeric run and trim
-- the result. `string_ext.snake_case("foo.bar")` is `"foo.bar"`, this file's
-- is `"foo_bar"`. A projector's output has to match fractal's byte for byte,
-- so the fractal semantics are ported rather than approximated.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.type-ir")

local M = {}

-- ── Identifier casing ────────────────────────────────────────────────────────

-- Uppercase the first character; the empty string passes through unchanged.
--: (string) -> string
function M.capitalize(name)
	if #name == 0 then return name end
	return name:sub(1, 1):upper() .. name:sub(2)
end

-- PascalCase by stripping non-alphanumeric runs and uppercasing the character
-- that follows each one (plus the leading character). Shared by the Rust,
-- wasm-bindgen, and Gleam projectors.
--
-- Distinct from `pascal_case_from_words` below: this variant leaves internal
-- casing alone (`"myHTTPValue"` -> `"MyHTTPValue"`), matching Rust/Gleam
-- convention for already-mixed-case identifiers; that one lowercases the
-- remainder of every word.
--: (string) -> string
function M.pascal_case_strip_separators(name)
	local cleaned = name:gsub("[^A-Za-z0-9]+(.?)", function(c)
		if c == "" then return "" end
		return c:upper()
	end)
	if #cleaned == 0 then return cleaned end
	return cleaned:sub(1, 1):upper() .. cleaned:sub(2)
end

-- snake_case by inserting `_` at camelCase boundaries, replacing every other
-- non-alphanumeric run with `_`, trimming leading/trailing `_`, and
-- lowercasing. Shared by the Rust, wasm-bindgen, and Gleam projectors.
--: (string) -> string
function M.snake_case_strip_separators(name)
	local s = name:gsub("([a-z0-9])([A-Z])", "%1_%2")
	s = s:gsub("[^A-Za-z0-9]+", "_")
	s = s:gsub("^_+", "")
	s = s:gsub("_+$", "")
	return s:lower()
end

-- Split `name` into words on camelCase boundaries and `_`/`-`/whitespace
-- runs. The basis for `pascal_case_from_words`.
--: (string) -> string[]
function M.split_words(name)
	local spaced = name:gsub("([a-z0-9])([A-Z])", "%1 %2")
	spaced = spaced:gsub("[_%-%s]+", " ")
	spaced = spaced:gsub("^%s+", "")
	spaced = spaced:gsub("%s+$", "")
	local out = {}
	local n = 0
	for word in spaced:gmatch("[^ ]+") do
		n = n + 1
		out[n] = word
	end
	return out
end

-- PascalCase via `split_words` — capitalize each word, lowercase the rest of
-- it, join with no separator. Used by the ReScript projector.
--: (string) -> string
function M.pascal_case_from_words(name)
	local words = M.split_words(name)
	local parts = {}
	for i = 1, #words do
		local w = words[i]
		parts[i] = w:sub(1, 1):upper() .. w:sub(2):lower()
	end
	return table.concat(parts)
end

-- ── Subtype check ────────────────────────────────────────────────────────────

-- `kind` IS `target`, or has `target` among its registered ancestors — the
-- "is a shape of this kind usable where a `target` is expected" test every
-- projector with kind-specific branches needs (e.g. "is this int32 a
-- refinement of `integer`?").
--: (string, string) -> boolean
function M.is_a(kind, target)
	if kind == target then return true end
	local chain = type_ref.ancestors(kind)
	for i = 1, #chain do
		if chain[i] == target then return true end
	end
	return false
end

-- ── Quoting ──────────────────────────────────────────────────────────────────

-- JSON string escapes, keyed by byte. Matches `lib/json`'s encoder table.
local ESCAPE = {} --: { [integer]: string }
ESCAPE[0x22] = '\\"'
ESCAPE[0x5C] = "\\\\"
ESCAPE[0x08] = "\\b"
ESCAPE[0x0C] = "\\f"
ESCAPE[0x0A] = "\\n"
ESCAPE[0x0D] = "\\r"
ESCAPE[0x09] = "\\t"
for i = 0, 0x1F do
	if ESCAPE[i] == nil then ESCAPE[i] = string.format("\\u%04X", i) end
end

-- JSON-quote `s` — the default string-literal quoting for every target whose
-- string-literal syntax is JSON-compatible (Rust, ReScript, C-family, …).
-- Corresponds to fractal's `quote`, which is `JSON.stringify`.
--
-- Implemented here rather than delegating to `lib/json`: that module's
-- string encoder is module-local, and its exported whole-value `encode` is
-- fallible by signature (NaN, Infinity, unsupported types). Routing an
-- identifier through it would make every call site fallible for failure modes
-- a string input cannot produce. Quoting a string is total, and the signature
-- says so.
--: (string) -> string
function M.quote(s)
	local parts = {}
	local n = 0
	local start = 1
	local i = 1
	local len = #s
	while i <= len do
		local esc = ESCAPE[s:byte(i)]
		if esc ~= nil then
			if i > start then
				n = n + 1
				parts[n] = s:sub(start, i - 1)
			end
			n = n + 1
			parts[n] = esc
			start = i + 1
		end
		i = i + 1
	end
	if start <= len then
		n = n + 1
		parts[n] = s:sub(start, len)
	end
	return '"' .. table.concat(parts) .. '"'
end

return M
