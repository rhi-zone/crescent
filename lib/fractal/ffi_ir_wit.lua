-- lib/fractal/ffi_ir_wit.lua — the WIT (`.wit` source text) projector, ported
-- from fractal's packages/ffi-ir/src/wit.ts.
--
-- WIT is the target ffi-ir's `resource` + own/borrow vocabulary was modelled
-- on, so this backend is the one that reads `meta.ownership` most directly:
-- own/borrow lives on each REFERENCE rather than on the resource declaration
-- (see ffi_ir.lua's header), which is exactly what WIT's call-site
-- `own`/`borrow<T>` qualifiers need — the same resource is rendered bare in one
-- signature and `borrow<...>` in another, from the same resource declaration.
--
-- Scope and decisions this file follows, all already made in fractal's
-- docs/design/ffi-ir-architecture-options.md (Fork B follow-up, Fork C
-- "discipline-per-target: decided") and reproduced here rather than
-- re-derived:
--
--   - WIT is one more *target* for fractal (a `.wit` emission projector, the
--     same shape as the ~120 type-ir projectors), not a shared IR fractal's own
--     C/JS backends sit on top of. See that doc's Fork B follow-up, "Net
--     finding".
--   - The only ownership discipline this projector implements is `resource` +
--     `own`/`borrow` (WIT's own shipped mechanism, which already subsumes
--     copy-by-value for every non-resource type for free). `opaque-handle` and
--     `refcount` are REPORTED AS UNSUPPORTED — explicitly excluded for this
--     target per that doc's "Fork C, discipline-per-target: decided"
--     subsection: opaque-handle+free-fn is redundant with `resource` (which
--     provides strictly more — a lend-count/trap safety net `opaque-handle`
--     lacks), and refcount is a confirmed structural mismatch (WIT's Canonical
--     ABI is lend-count-and-trap, not reference counting).
--
-- The WIT syntax findings below were verified 2026-08-03 against
-- component-model.bytecodealliance.org by the TS source's author, and are
-- reproduced (not re-verified by this port, and not carried over from memory)
-- because they are the reasoning behind every mapping choice here:
--
--   - `module` -> WIT `interface`, not `world` (design/worlds.html): "an
--     interface groups named types+functions", while "a world describes the
--     functionality a component provides, and the functionality it requires in
--     order to work" via import/export declarations. ffi-ir's `module` kind is
--     a flat `{ functions, resources }` map with no import/export/binding
--     concept at all — structurally an `interface`, not a `world`. A
--     straightforward read of the spec, not a judgment call between two live
--     options.
--   - `resource` methods use WIT's own nested method syntax (design/wit.html):
--     a resource block's methods "implicitly take a `self` (AKA `this`)
--     parameter that is a handle" and are written `name: func(params) -> ret;`
--     INSIDE the `resource { ... }` block, with no explicit receiver parameter
--     — e.g. `resource blob { write: func(bytes: list<u8>); }`, not `write:
--     func(self: borrow<blob>, bytes: list<u8>);` as a free function. This
--     lines up with ffi-ir's own `method` shape, whose `params` already exclude
--     the receiver (carried separately, as `FfiMethodShape.receiver`) — so
--     `function` and `method` emit the exact same func-line syntax here; the
--     only difference is where that line is placed (top-level in an
--     `interface`, vs. nested in a `resource` block).
--   - WIT identifiers are ASCII kebab-case (wit.html): "sequences of words,
--     separated by single hyphens". `to_kebab_case` below converts
--     ffi-ir/type-ir's camelCase-by-convention names to match.
--
-- DATA-SHAPE COVERAGE IS DELIBERATELY MINIMAL — primitives, `record` (from
-- type-ir's `object`), `list<T>` (from `array`), `option<T>` (from
-- `meta.optional`/`meta.nullable`), plus `ref`/resource-handle syntax for the
-- ownership cases above. No standalone type-ir -> WIT data-shape projector
-- exists yet on the fractal side; building the full same-shape addition other
-- targets get (variant/enum/flags/tuple/map/result, ...) is separate,
-- not-yet-done work, out of scope for this file, which implements only what
-- ffi-ir's own function/method/resource/module projection needs. Every kind
-- outside that subset is reported, never silently degraded.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return here, the same conversion `type_ref.lua`'s
-- `resolve_ref` applies to its own source's throw: an unsupported discipline or
-- shape is a data error, not a programming error. This propagates — the
-- internal builders below return `(nil, errmsg)` too, and every caller checks.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.fractal.ffi_ir")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of type_ref.lua's
-- own declarations, reached transitively through the `require` above (every
-- ffi-ir signature this file touches names them). Duplicating a type
-- definition is normally forbidden outright; it is here only because the
-- checker cannot currently keep an imported alias resolvable through a
-- consumer — when a consumer (this file, and in turn this file's test) calls a
-- function whose signature names an alias declared in the required module, the
-- checker re-resolves that module's `--::` declarations in the CONSUMER's
-- scope, where type_ref.lua's `TypeRef`/`Meta` are not bound. They resolve to
-- `undefined type`, silently degrade to `any`, and the consumer reports errors
-- against the DEPENDENCY's line numbers. See the full write-up and minimal
-- repro in ffi_ir.lua's own copy of this comment, and the TODO.md entry ("an
-- alias imported via require ... degrades to any as soon as any consumer uses
-- that module"), which already records that the re-declaration is repeated in
-- each `lib/fractal/ffi_ir_*.lua` backend for this reason.
--
-- These MUST stay structurally identical to type_ref.lua's. Delete all three
-- and rely on the `require` once the checker resolves imported aliases through
-- a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- ── Name formatting ──────────────────────────────────────────────────────────

-- WIT's ASCII kebab-case identifier convention (see the file header's verified
-- wit.html finding). The four rewrites are the TS source's four regexes, in
-- order: split a lower/digit-to-upper boundary with a hyphen (`readFile` ->
-- `read-File`), collapse every run of non-alphanumerics into one hyphen, strip
-- leading/trailing hyphens, lowercase the result.
--: (name: string) -> string
local function to_kebab_case(name)
	local split = (name:gsub("([a-z0-9])(%u)", "%1-%2"))
	local collapsed = (split:gsub("[^a-zA-Z0-9]+", "-"))
	local head_trimmed = (collapsed:gsub("^%-+", ""))
	local trimmed = (head_trimmed:gsub("%-+$", ""))
	return trimmed:lower()
end

-- A record's keys in a deterministic (byte) order.
--
-- The TS source iterates `Object.entries(...)`, i.e. JS insertion order. Lua
-- tables have no insertion order to recover, so `pairs()` alone would make the
-- order of emitted record fields, resource methods and interface items vary
-- between runs. Byte order is the deterministic stand-in — the same
-- substitution, for the same reason, that type_ref.lua's own `ordered_keys`
-- makes. The emitted SET of declarations is identical either way, and WIT
-- attaches no meaning to the order of a record's fields or an interface's
-- items relative to each other.
--: (tbl: { [string]: unknown }) -> { [integer]: string }
local function ordered_keys(tbl)
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	for k in pairs(tbl) do
		if type(k) == "string" then
			n = n + 1
			out[n] = k
		end
	end
	table.sort(out)
	return out
end

-- ── Hoisted declarations ─────────────────────────────────────────────────────

-- The accumulator threaded through the type conversion below, collecting the
-- `record` declarations hoisted out of nested object shapes (WIT, like Rust,
-- has no anonymous inline record syntax, so an object-shaped param or field
-- has to become a named top-level declaration). `entries` maps a kebab-case
-- record name to its declaration text; `order` lists those names.
--
-- INSERTION ORDER IS TRACKED EXPLICITLY, unlike every other map in this file,
-- which uses `ordered_keys`' byte order. The TS source's accumulator is a
-- `Map<string, string>`, whose iteration order is insertion order, and its
-- emitted text is the concatenation of `decls.values()` — so byte order here
-- would emit the same declarations in a different order than the source this
-- is a port of, for no gain. Neither order guarantees declaration-before-use
-- (the source reserves an outer record's slot BEFORE recursing into its
-- fields, so a record precedes the records it references), so byte order buys
-- no well-formedness property that insertion order lacks; reproducing the
-- source's exact output is the conservative choice between the two.
--:: WitDecls = { entries: { [string]: string }, order: { [integer]: string } }

-- A fresh, empty declaration accumulator.
--: () -> WitDecls
local function new_decls()
	return { entries = {}, order = {} }
end

-- The hoisted declaration texts, in the order described on `WitDecls` —
-- the stand-in for the TS source's `[...decls.values()]`.
--: (decls: WitDecls) -> { [integer]: string }
local function decl_texts(decls)
	local out = {} --[[: { [integer]: string } ]]
	for i = 1, #decls.order do
		out[i] = decls.entries[decls.order[i]]
	end
	return out
end

-- ── Type mapping ─────────────────────────────────────────────────────────────

-- type-ir kind -> WIT primitive type name. `integer` and `number` are the
-- unsized type-ir kinds and take WIT's widest matching primitives (`s64`,
-- `f64`); the sized kinds map one-for-one.
local PRIMITIVES = {
	boolean = "bool",
	string = "string",
	int8 = "s8",
	int16 = "s16",
	int32 = "s32",
	int64 = "s64",
	integer = "s64",
	uint8 = "u8",
	uint16 = "u16",
	uint32 = "u32",
	uint64 = "u64",
	float32 = "f32",
	float64 = "f64",
	number = "f64",
} --[[: { [string]: string }]]

-- WIT's function grammar has no unit/void return type to spell out, so a
-- void/null return is emitted as no `-> ...` clause at all rather than as a
-- type name. Both type-ir kinds that mean "no value" are treated alike.
--: (ref: TypeRef) -> boolean
local function is_void_type(ref)
	return ref.shape.kind == "void" or ref.shape.kind == "null"
end

-- `option<T>` wrapping for the two type-ir meta keys that mean "may be
-- absent". Applied to the finished base expression, whichever branch of
-- `to_wit_type` produced it — a borrowed resource handle can be optional the
-- same way a primitive can.
--: (ref: TypeRef, base: string) -> string
local function wrap_optional(ref, base)
	if ref.meta.optional == true or ref.meta.nullable == true then
		return "option<" .. base .. ">"
	end
	return base
end

-- Forward declaration for mutual recursion: `to_base_wit_type` recurses into
-- `to_wit_type` for an array's element and a record's fields, and
-- `to_wit_type` calls back into `to_base_wit_type` for the non-resource cases.
-- Annotated at the assignment below, not here — an annotated `local` with no
-- initializer is rejected (nil is not in the function type).
local to_wit_type

-- The structural (ownership-metadata-independent) WIT type expression for
-- `ref`. Hoists a fresh `record` declaration into `decls` (keyed by its
-- kebab-case name, which dedupes repeat references) when `ref` is an `object`
-- shape. Reports any kind this minimal subset does not implement.
--: (ref: TypeRef, decls: WitDecls, name_hint: string) -> (string | nil, string | nil)
local function to_base_wit_type(ref, decls, name_hint)
	local kind = ref.shape.kind

	local primitive = PRIMITIVES[kind]
	if primitive ~= nil then return primitive end

	if kind == "array" then
		local element = (ref.shape --[[: { element: TypeRef, ... }]]).element
		local inner, err = to_wit_type(element, decls, name_hint)
		if inner == nil then return nil, err end
		return "list<" .. inner .. ">"
	end

	if kind == "ref" then
		return to_kebab_case((ref.shape --[[: { target: string, ... }]]).target)
	end

	if kind == "object" then
		local fields = (ref.shape --[[: { fields: { [string]: TypeRef }, ... }]]).fields
		local record_name = to_kebab_case(name_hint)
		if decls.entries[record_name] == nil then
			-- Reserve the slot (both the name and its position in `order`)
			-- before recursing, in case a field self-references.
			decls.order[#decls.order + 1] = record_name
			decls.entries[record_name] = ""

			local lines = { "record " .. record_name .. " {" } --[[: { [integer]: string } ]]
			local field_names = ordered_keys(fields)
			for i = 1, #field_names do
				local field_name = field_names[i]
				local field_type, err = to_wit_type(fields[field_name], decls, field_name)
				if field_type == nil then return nil, err end
				lines[#lines + 1] = "    " .. to_kebab_case(field_name) .. ": " .. field_type .. ","
			end
			lines[#lines + 1] = "}"
			decls.entries[record_name] = table.concat(lines, "\n")
		end
		return record_name
	end

	return nil,
		'to_wit: kind "' .. kind .. '" has no WIT mapping in this minimal data-shape subset — only primitives, '
			.. '"object" (-> record), "array" (-> list<T>), and "ref" are implemented; a full type-ir -> WIT '
			.. "data-shape projector is separate, not-yet-done work"
end

-- Full WIT type expression for `ref`, including ownership-discipline handling
-- (`meta.ownership`, read through ffi_ir's `ownership_of`) and `option<T>`
-- wrapping for `meta.optional`/`meta.nullable`.
--
-- `copy` ownership — or no ownership metadata at all, which every backend
-- reads as `copy`, an unannotated position crossing by value — falls through to
-- `to_base_wit_type`'s plain structural conversion: WIT crosses non-`resource`
-- types by value natively, so a copy-discipline value needs no wrapper.
--
-- `resource` ownership renders the WIT-native call-site qualifier (an
-- unqualified resource name for `"own"`, `borrow<name>` for `"borrow"`) and
-- requires `ref` to be a `{ kind = "ref" }` TypeRef naming the resource — the
-- documented `resource_ref()` convention from ffi_ir.lua. `opaque-handle` and
-- `refcount` are reported as unsupported — see the file header for why those
-- two are explicitly out of scope for this target.
--: (ref: TypeRef, decls: WitDecls, name_hint: string) -> (string | nil, string | nil)
to_wit_type = function(ref, decls, name_hint)
	local discipline = ffi_ir.ownership_of(ref)

	if discipline ~= nil then
		-- TYPECHECKER WORKAROUND: `kind` is read through a structural cast
		-- rather than off `OwnershipDiscipline` directly. The natural code is
		-- `discipline.kind`, which the checker resolves correctly for ONE
		-- equality test and then collapses: narrowing the imported union by
		-- `kind ~= "copy"` and testing the residual value's `kind` again leaves
		-- that second read typed `never`, so the error message below cannot
		-- concatenate it. Minimal repro (from the repo root, so the require
		-- resolves):
		--
		--     local d = ffi_ir.ownership_of(ref)
		--     if d ~= nil then
		--         local k = d.kind
		--         if k == "opaque-handle" or k == "refcount" then return k end
		--     end
		--   → cannot concatenate type `never`
		--
		-- Reading through the open `{ kind: string, ... }` record — the same
		-- structural-field-read the union's own reader (`ffi_ir.ownership_of`)
		-- uses internally — sidesteps the collapse. TODO.md records the gap.
		local discipline_kind = (discipline --[[: { kind: string, ... }]]).kind
		if discipline_kind ~= "copy" then
			if discipline_kind == "opaque-handle" or discipline_kind == "refcount" then
				return nil,
					'to_wit: unsupported ownership discipline "' .. discipline_kind .. '" for the WIT target — WIT\'s '
						.. "decided scope (fractal's docs/design/ffi-ir-architecture-options.md, Fork C "
						.. '"discipline-per-target: decided") implements only "resource" (own/borrow) and "copy"; "'
						.. discipline_kind
						.. '" has no WIT-native realization and is explicitly excluded, not silently degraded'
			end

			-- Everything else is treated as `resource`, exactly as the TS source
			-- does: the discipline union is open (a consumer may register its
			-- own), and the two kinds this target cannot express are the two
			-- rejected above.
			if ref.shape.kind ~= "ref" then
				return nil,
					'to_wit: "resource" ownership metadata requires a { kind: "ref" } TypeRef naming the resource (the '
						.. 'resource_ref() convention from ffi_ir.lua), got shape kind "'
						.. ref.shape.kind
						.. '"'
			end
			local target = to_kebab_case((ref.shape --[[: { target: string, ... }]]).target)
			-- An unrecognized `mode` renders as owned (the bare resource name),
			-- matching the TS source's own `mode === "borrow" ? ... : ...`.
			local mode = (discipline --[[: { mode: unknown, ... }]]).mode
			if mode == "borrow" then return wrap_optional(ref, "borrow<" .. target .. ">") end
			return wrap_optional(ref, target)
		end
	end

	local base, base_err = to_base_wit_type(ref, decls, name_hint)
	if base == nil then return nil, base_err end
	return wrap_optional(ref, base)
end

-- ── Declaration builders ─────────────────────────────────────────────────────

-- `name: func(param: type, ...) -> return-type;` — verified syntax (wit.html,
-- per the file header: `add: func(a: u64, b: u64) -> u64;`). The return-type
-- arrow is omitted entirely for a void/null return (matching that fetch's
-- `draw-line: func(...);` example, which has no arrow at all).
--
-- Takes `FfiFunctionLike` rather than either concrete shape, which is what lets
-- one emitter serve both `function` and `method`: WIT writes them with the same
-- syntax, and a method's implicit `self` receiver is not a parameter on either
-- side (ffi-ir carries the receiver on the shape, WIT implies it from the
-- enclosing `resource` block).
--: (name: string, shape: FfiFunctionLike, decls: WitDecls) -> (string | nil, string | nil)
local function func_line(name, shape, decls)
	local params = {} --[[: { [integer]: string } ]]
	for i = 1, #shape.params do
		local param = shape.params[i]
		local param_type, err = to_wit_type(param.type, decls, param.name)
		if param_type == nil then return nil, err end
		params[i] = to_kebab_case(param.name) .. ": " .. param_type
	end

	local return_clause = ""
	if not is_void_type(shape.returnType) then
		local return_type, err = to_wit_type(shape.returnType, decls, name .. "-result")
		if return_type == nil then return nil, err end
		return_clause = " -> " .. return_type
	end

	return to_kebab_case(name) .. ": func(" .. table.concat(params, ", ") .. ")" .. return_clause .. ";"
end

-- `function` and `method` are the two ffi-ir kinds carrying a callable
-- signature, and this projector emits both as the same func line.
--: (kind: string) -> boolean
local function is_function_like(kind)
	return kind == "function" or kind == "method"
end

-- `resource name { method: func(...) -> ...; ... }` — verified syntax (same
-- fetch: `resource blob { constructor(init: list<u8>); write: func(bytes:
-- list<u8>); ... }`). ffi-ir's `resource` schema has no constructor or
-- static-function concept distinct from its flat `methods` map, so every entry
-- emits as an ordinary WIT resource method line — a WIT
-- `constructor(...)`/`static func` distinction is not modeled by ffi-ir today
-- and is not synthesized here.
--
-- Takes the name and methods map rather than the whole resource shape: an
-- `FfiShape` reaching this backend is the OPEN `{ kind: string, ... }`, which
-- no checked cast can narrow to `FfiResourceShape`'s literal `kind:
-- "resource"`, so every call site casts to the open record carrying just the
-- fields it reads. Same structural-field-read precedent as type_ref.lua's
-- `resolve_ref`.
--: (name: string, methods: { [string]: FfiRef }, decls: WitDecls) -> (string | nil, string | nil)
local function resource_block(name, methods, decls)
	local lines = { "resource " .. to_kebab_case(name) .. " {" } --[[: { [integer]: string } ]]

	local method_names = ordered_keys(methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = methods[method_name]
		if not is_function_like(method_ref.shape.kind) then
			return nil,
				'to_wit: resource "' .. name .. '"\'s method "' .. method_name .. '" has shape kind "'
					.. method_ref.shape.kind
					.. '", not "function"/"method" — a resource\'s methods map must contain callable shapes'
		end
		local line, err = func_line(method_name, method_ref.shape --[[: FfiFunctionLike]], decls)
		if line == nil then return nil, err end
		lines[#lines + 1] = "    " .. line
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

-- Every non-empty line of `text`, indented four spaces. Empty lines are left
-- empty rather than becoming four spaces of trailing whitespace, matching the
-- TS source.
--: (text: string) -> string
local function indent_block(text)
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	-- Appending a trailing newline and matching `([^\n]*)\n` yields exactly one
	-- capture per line, including empty ones — Lua has no split, and matching
	-- `[^\n]*` alone would also produce a spurious empty match between lines.
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		n = n + 1
		out[n] = #line == 0 and line or ("    " .. line)
	end
	return table.concat(out, "\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Project an ffi-ir `FfiRef` (`module`/`function`/`method`/`resource`) into
-- `.wit` source text.
--
--   module   — a WIT `interface name { ... }` block containing its resources
--              (as nested `resource` blocks) and functions (as func lines),
--              preceded by any `record` declarations hoisted out of nested
--              object-shaped params/fields. See the file header for why
--              `interface`, not `world`, is the verified mapping.
--   resource — a standalone `resource name { ... }` block (when called
--              directly rather than via a `module`), preceded by hoisted
--              `record` declarations.
--   function
--   method   — a standalone func line; requires `name`, since ffi-ir's
--              `function`/`method` shapes carry no name of their own (the name
--              lives as the key in the enclosing `module.functions` /
--              `resource.methods` map, the same requirement the other backends
--              have).
--
-- Reports — never silently degrades — for: any ownership discipline other than
-- `copy`/`resource` (see `to_wit_type`), any data-shape kind outside this
-- file's minimal primitives/record/list/option subset (see
-- `to_base_wit_type`), a `function`/`method` called without a `name`, and a
-- boundary kind this projector does not emit.
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function M.to_wit(ref, name)
	local kind = ref.shape.kind
	local decls = new_decls()

	if kind == "module" then
		local shape = ref.shape --[[: { name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		local body = {} --[[: { [integer]: string } ]]
		local n = 0

		local res_names = ordered_keys(shape.resources)
		for i = 1, #res_names do
			local res_name = res_names[i]
			local res_ref = shape.resources[res_name]
			if res_ref.shape.kind ~= "resource" then
				return nil,
					'to_wit: module "' .. shape.name .. '"\'s resource "' .. res_name .. '" has shape kind "'
						.. res_ref.shape.kind
						.. '", not "resource"'
			end
			local res_shape = res_ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
			local block, err = resource_block(res_shape.name, res_shape.methods, decls)
			if block == nil then return nil, err end
			n = n + 1
			body[n] = block
		end

		local fn_names = ordered_keys(shape.functions)
		for i = 1, #fn_names do
			local fn_name = fn_names[i]
			local fn_ref = shape.functions[fn_name]
			if not is_function_like(fn_ref.shape.kind) then
				return nil,
					'to_wit: module "' .. shape.name .. '"\'s function "' .. fn_name .. '" has shape kind "'
						.. fn_ref.shape.kind
						.. '", not "function"/"method"'
			end
			local line, err = func_line(fn_name, fn_ref.shape --[[: FfiFunctionLike]], decls)
			if line == nil then return nil, err end
			n = n + 1
			body[n] = line
		end

		-- Hoisted records first: they are collected only while the body above is
		-- built, so this concatenation cannot be hoisted earlier.
		local parts = decl_texts(decls)
		local count = #parts
		for i = 1, n do parts[count + i] = body[i] end
		return "interface " .. to_kebab_case(shape.name) .. " {\n" .. indent_block(table.concat(parts, "\n\n")) .. "\n}"
	end

	if kind == "resource" then
		local shape = ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
		local block, err = resource_block(shape.name, shape.methods, decls)
		if block == nil then return nil, err end
		local parts = decl_texts(decls)
		parts[#parts + 1] = block
		return table.concat(parts, "\n\n")
	end

	if is_function_like(kind) then
		if name == nil then
			return nil,
				'to_wit: a standalone "' .. kind .. '" shape requires a name — its own schema carries no name (see '
					.. "ffi_ir.lua's FfiFunctionShape/FfiMethodShape)"
		end
		local line, err = func_line(name, ref.shape --[[: FfiFunctionLike]], decls)
		if line == nil then return nil, err end
		local parts = decl_texts(decls)
		parts[#parts + 1] = line
		return table.concat(parts, "\n\n")
	end

	return nil, 'to_wit: kind "' .. kind .. '" is not a boundary construct this projector emits'
end

return M
