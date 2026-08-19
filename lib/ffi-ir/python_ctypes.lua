-- lib/ffi-ir/python_ctypes.lua — the Python `ctypes` projector, ported from
-- fractal's packages/ffi-ir/src/python-ctypes.ts.
--
-- Python source (a `ctypes.CDLL` load, per-function `.argtypes`/`.restype`
-- declarations, and thin wrapper functions/classes) as the CONSUMER side of a
-- plain-C FFI boundary. This is the mirror image of the C-ABI backend (which
-- emits the Rust/cbindgen PRODUCER side of the same boundary): where that
-- backend emits the shared library, this file emits the Python code that
-- dlopen()s it and calls in. Same family as the Ruby `ffi` gem backend in
-- `ruby_ffi.lua` — both are consumer-side loaders for a C-ABI library —
-- and it differs from that one chiefly in having a real struct/class vocabulary
-- to emit into.
--
-- Every API fact below was verified against Python's own official docs
-- (docs.python.org/3/library/ctypes.html) by the TS source's author during
-- implementation of that file, not recalled from memory, and not re-verified by
-- this port; the findings are reproduced here because they are the reasoning
-- behind every mapping choice in this file:
--   - Loading: `ctypes.CDLL(path)` (also `ctypes.cdll.LoadLibrary(path)`,
--     equivalent) — "instantiate CDLL ... to load shared libraries into the
--     Python process."
--   - Per-function signatures: "the required argument types of functions
--     exported from DLLs" are set via the function object's own `argtypes`
--     attribute (a list); "other return types can be specified by setting the
--     restype attribute of the function object" (default is C `int`). Both are
--     documented as being set directly on `lib.funcname`, e.g.
--     `printf.argtypes = [c_char_p, ...]; printf.restype = c_int`.
--   - Primitive vocabulary confirmed from the docs' ctypes-type table:
--     `c_bool`, `c_char`, `c_wchar`, `c_byte`/`c_ubyte`, `c_short`/`c_ushort`,
--     `c_int`, `c_int8`/`c_int16`/`c_int32`/`c_int64` (and unsigned
--     counterparts), `c_long`/`c_ulong`, `c_longlong`/`c_ulonglong`,
--     `c_size_t`/`c_ssize_t`, `c_float`, `c_double`, `c_longdouble`,
--     `c_char_p` (`char*`, NUL-terminated, Python `bytes`/`None`), `c_wchar_p`
--     (`wchar_t*`, Python `str`/`None`), `c_void_p` (`void*`, Python
--     `int`/`None`).
--   - Structs: "Structures ... must derive from the Structure ... base
--     class[.] Each subclass must define a `_fields_` attribute[, which] must
--     be a list of 2-tuples, containing a field name and a field type."
--   - Opaque/incomplete types: the docs' own "Incomplete Types" section
--     forward-declares a struct as `class cell(Structure): pass` (no `_fields_`
--     at all) precisely because the class name must exist before `_fields_` can
--     reference it recursively; the same `class Name(Structure): pass` form —
--     left permanently without `_fields_` — is the documented shape for a type
--     that is only ever handled behind a pointer, never dereferenced by name,
--     which is exactly cbindgen/C's own opaque-pointer convention the C-ABI
--     backend already emits on the producer side (its `#[repr(C)] pub struct
--     Name { _private: [u8; 0] }`). This projector mirrors that with `class
--     Name(Structure): pass` + `POINTER(Name)` for the handle type, rather than
--     a bare untyped `c_void_p`, so that two different resources' handles
--     remain distinct Python/ctypes types (the same distinctness cbindgen's
--     per-resource opaque struct gives on the Rust side) rather than all
--     collapsing to interchangeable raw `void*`. This is the one place this
--     backend and the Ruby `ffi` one genuinely diverge: the `ffi` gem has no
--     documented opaque-handle struct convention and uses a bare `:pointer`.
--   - Ownership: ctypes itself has no ownership or reference-counting model —
--     it is confirmed to be "low-level access to native libraries ... bypassing
--     Python's safety mechanisms," and its own docs' one lifetime warning (on
--     `CFUNCTYPE` callback objects) is about the *caller* being responsible for
--     keeping Python-side references alive, not about any ctypes-managed
--     ownership discipline for values crossing the boundary. Consequently — see
--     `to_ctypes_type` below — every `OwnershipDiscipline` other than `copy`
--     (`opaque-handle`, `refcount`, `resource`) produces the IDENTICAL ctypes
--     declaration: a pointer. ctypes has no type-level way to express "this
--     pointer is refcounted" or "this pointer is owned vs. borrowed" — that
--     bookkeeping is either done by the C library itself (refcount) or simply
--     isn't checked at all (resource own/borrow, absent a host runtime — the
--     same point the C-ABI backend's own header makes about plain C generally).
--     This file states that collapse explicitly rather than inventing three
--     different declarations for a distinction ctypes cannot see.
--
-- PYTHON SOURCE, NOT RUST. This is the only projector in the family targeting
-- Python, so none of the C-ABI/wasm-bindgen backends' Rust-specific helpers
-- (identifier escaping, snake_case conversion) apply as-is; Python identifier
-- rules and keyword list are re-derived below, self-contained, matching the TS
-- package's existing per-file duplication precedent (each projector file owns
-- its own copy of these small helpers).
--
-- WHITESPACE IS SIGNIFICANT. Unlike the Ruby backend — which can indent per
-- body ENTRY rather than per line because Ruby is indentation-insensitive —
-- every emitted line's leading spaces here are load-bearing Python syntax, so
-- each nested line carries its own indent explicitly.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return here, the same conversion `lib/type-ir/init.lua`'s
-- `resolve_ref` applies to its own source's throw: an unsupported shape, a
-- missing name, or an `object` TypeRef with no `meta.typeName` is a data error,
-- not a programming error. This propagates — the internal builders below return
-- `(nil, errmsg)` too, and every caller checks — and it applies to all three
-- exported entry points (`to_ctypes_shape`, `to_ctypes_type`, `to_ctypes`).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.ffi-ir")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of lib/type-ir/init.lua's
-- own declarations, reached transitively through the `require` above (every
-- ffi-ir signature this file touches names them). Duplicating a type definition
-- is normally forbidden outright; it is here only because the checker cannot
-- currently keep an imported alias resolvable through a consumer — when a
-- consumer (this file, and in turn this file's test) calls a function whose
-- signature names an alias declared in the required module, the checker
-- re-resolves that module's `--::` declarations in the CONSUMER's scope, where
-- lib/type-ir/init.lua's `TypeRef`/`Meta` are not bound. They resolve to `undefined
-- type`, silently degrade to `any`, and the consumer reports errors against the
-- DEPENDENCY's line numbers. See the full write-up and minimal repro in
-- init.lua's own copy of this comment, and the TODO.md entry ("an alias
-- imported via require ... degrades to any as soon as any consumer uses that
-- module"), which already records that the re-declaration is repeated in each
-- `lib/ffi-ir/*.lua` backend for this reason.
--
-- These MUST stay structurally identical to lib/type-ir/init.lua's. Delete all three
-- and rely on the `require` once the checker resolves imported aliases through
-- a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- ── Name and literal formatting ──────────────────────────────────────────────

-- The snake_case convention shared with the C-ABI backend, so a Python
-- wrapper's symbol name matches the C symbol that backend exported.
--
-- The three rewrites are the TS source's three regexes, in order: split a
-- lower/digit-to-upper boundary with an underscore (`readFile` -> `read_File`),
-- collapse every run of non-alphanumerics into one underscore, strip
-- leading/trailing underscores, lowercase the result.
--: (name: string) -> string
local function to_snake_case(name)
	local split = (name:gsub("([a-z0-9])(%u)", "%1_%2"))
	local collapsed = (split:gsub("[^a-zA-Z0-9]+", "_"))
	local head_trimmed = (collapsed:gsub("^_+", ""))
	local trimmed = (head_trimmed:gsub("_+$", ""))
	return trimmed:lower()
end

-- Python 3 reserved keywords
-- (https://docs.python.org/3/reference/lexical_analysis.html#keywords) —
-- cannot appear as a plain identifier. A set, keyed by the keyword itself,
-- standing in for the TS source's `new Set([...])`.
local PY_KEYWORDS = {
	["False"] = true, ["None"] = true, ["True"] = true, ["and"] = true,
	["as"] = true, ["assert"] = true, ["async"] = true, ["await"] = true,
	["break"] = true, ["class"] = true, ["continue"] = true, ["def"] = true,
	["del"] = true, ["elif"] = true, ["else"] = true, ["except"] = true,
	["finally"] = true, ["for"] = true, ["from"] = true, ["global"] = true,
	["if"] = true, ["import"] = true, ["in"] = true, ["is"] = true,
	["lambda"] = true, ["nonlocal"] = true, ["not"] = true, ["or"] = true,
	["pass"] = true, ["raise"] = true, ["return"] = true, ["try"] = true,
	["while"] = true, ["with"] = true, ["yield"] = true,
} --[[: { [string]: boolean }]]

-- Escapes a Python identifier that collides with a reserved keyword using a
-- trailing underscore (`class_`, `type_`) — PEP 8's own documented convention
-- for this exact situation ("single trailing underscore ... used by convention
-- to avoid conflicts with Python keyword"), the Python analogue of the C-ABI
-- backend's raw-identifier (`r#type`) escape, and the same rename this repo's
-- own port applied to `boundary.function_`.
--: (name: string) -> string
local function escape_py_ident(name)
	if PY_KEYWORDS[name] then return name .. "_" end
	return name
end

-- Characters that must be escaped inside a double-quoted string literal, and
-- their replacements. This reproduces the TS source's `JSON.stringify`
-- deliberately, rather than "improving" on it: diverging would mean this port
-- emits different Python than the source it is a port of. Every character
-- listed has the same meaning in a Python string literal as in a JSON one, and
-- the only string reaching `quote` today is a shared-library path.
local ESCAPES = {
	["\\"] = "\\\\",
	['"'] = '\\"',
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
} --[[: { [string]: string }]]

-- One character's escaped form: its named escape when it has one, else the
-- `\uXXXX` form `JSON.stringify` uses for the remaining control characters
-- (also valid in a Python string literal).
--: (c: string) -> string
local function escape_char(c)
	local mapped = ESCAPES[c]
	if mapped ~= nil then return mapped end
	return string.format("\\u%04X", string.byte(c) or 0)
end

-- `value` as a double-quoted Python string literal.
--: (value: string) -> string
local function quote(value)
	local escaped = (value:gsub('[%c"\\]', escape_char))
	return '"' .. escaped .. '"'
end

-- The `# ...` doc-comment lines for a meta bag: one line when `description`
-- holds a string, none otherwise. Returned as a list because callers splice it
-- into a line list. `indent` is prepended to the comment line — the TS source's
-- own parameter, kept because a doc comment emitted inside a class or function
-- body must carry that body's indentation to be valid Python.
--
-- TYPECHECKER WORKAROUND: the list type is spelled `{ [integer]: string }`
-- rather than the house-style `string[]` sugar, here and everywhere below a
-- list is handed to `table.concat`. `string[]` expands to `{ [number]: string }`,
-- which `table.concat`'s stdlib declaration (`{ [integer]: string | number }`)
-- rejects — "missing indexer for integer" — even though every `integer` is a
-- `number`. That is the already-recorded TODO.md entry "`table.remove` rejects
-- a `{ [number]: V }`-typed array with 'missing indexer for integer'"; this is
-- the same gap reached through `table.concat` instead. The natural spelling is
-- `string[]` throughout; revert once `{ [number]: V }` is accepted where
-- `{ [integer]: V }` is expected. The same substitution, for the same reason,
-- is in `ruby_ffi.lua`.
--: (indent: string, meta: Meta) -> { [integer]: string }
local function doc_comment(indent, meta)
	local description = meta.description
	if type(description) ~= "string" then return {} --[[: { [integer]: string } ]] end
	return { indent .. "# " .. description } --[[: { [integer]: string } ]]
end

-- A record's keys in a deterministic (byte) order.
--
-- The TS source iterates `Object.entries(...)`, i.e. JS insertion order. Lua
-- tables have no insertion order to recover, so `pairs()` alone would make the
-- order of the emitted declarations (and of a resource class's methods) vary
-- between runs. Byte order is the deterministic stand-in — the same
-- substitution, for the same reason, that lib/type-ir/init.lua's own `ordered_keys`
-- makes. The emitted SET of declarations is identical either way.
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

-- ── Type mapping ─────────────────────────────────────────────────────────────

-- The by-value ctypes expression for a type-ir `TypeShape`, ignoring ownership
-- (see `to_ctypes_type`, which applies the pointer wrap on top of this). Covers
-- the primitive/struct/ref subset ctypes can genuinely marshal; reports —
-- rather than silently degrading — for shapes with no native C-ABI
-- representation ctypes itself defines (`array`/`tuple`/`map`/`union`/
-- `intersection`/`enum`/`stream`/`page`/`instance`/`unknown`/`never`), matching
-- the C-ABI backend's own report-not-degrade convention for shapes outside its
-- target's representable subset.
--: (ref: TypeRef) -> (string | nil, string | nil)
function M.to_ctypes_shape(ref)
	local shape = ref.shape
	local kind = shape.kind

	if kind == "boolean" then return "c_bool" end
	if kind == "integer" then return "c_int64" end
	if kind == "number" then return "c_double" end

	if kind == "string" then
		-- char* — the C-ABI string convention (NUL-terminated bytes), matching
		-- this family's convention of treating a boundary `TypeRef` as crossing
		-- at the raw-C level, not a Python-native `str`. `c_char_p` marshals as
		-- Python `bytes`/`None` per the docs (see file header).
		return "c_char_p"
	end

	if kind == "null" or kind == "void" then return "None" end

	if kind == "object" then
		local type_name = ref.meta.typeName
		if type(type_name) ~= "string" then
			return nil,
				'to_ctypes_shape: an "object" TypeRef requires meta.typeName naming the Structure class declared for '
					.. "it — ctypes.Structure fields need a class name, and this shape carries no name of its own at "
					.. "this position"
		end
		return type_name
	end

	if kind == "ref" then
		-- Bare pass-through of the referenced name, trusting a Structure (or
		-- primitive alias) of that name is declared elsewhere — the same
		-- convention the JSON-schema/serde backends' `ref` handlers document
		-- ("trusting a struct of that name is declared/imported elsewhere").
		--
		-- The TS source casts `shape` to its `ref` form unchecked; a Lua cast
		-- cannot, so the target is read as `unknown` and checked, reporting a
		-- malformed shape the same way lib/type-ir/init.lua's `resolve_ref` does for
		-- exactly this field.
		local target = (shape --[[: { target: unknown, ... }]]).target
		if type(target) ~= "string" then
			return nil, 'to_ctypes_shape: a "ref" shape has no string `target`'
		end
		return target
	end

	return nil,
		'to_ctypes_shape: type-ir kind "' .. kind .. '" has no ctypes representation this backend implements — ctypes '
			.. "marshals fixed C-ABI scalar/pointer/struct values only, with no native array-length, tagged-union, or "
			.. "map convention of its own"
end

-- The ctypes-level ctype expression for one boundary position (a parameter's or
-- return's `TypeRef`), applying the same ownership rule the C-ABI backend
-- applies for the producer side, but collapsed to ctypes' own vocabulary (see
-- the file header for why every non-`copy` discipline collapses to the same
-- pointer form):
--   - no `meta.ownership` at all, or `{ kind = "copy" }` — the plain by-value
--     ctypes primitive/struct expression from `to_ctypes_shape` above.
--   - `{ kind = "opaque-handle" }` / `{ kind = "refcount" }` /
--     `{ kind = "resource", mode = ... }` — `POINTER(<T>)`, where `<T>` is the
--     same base expression, matching the C-ABI backend's `*mut <T>` on the
--     producer side. ctypes has no construct distinguishing these three at the
--     type-declaration level (see file header); all three produce this one
--     form, explicitly, rather than three near-duplicate cases.
--
-- `ownership_of` returns nil for an unannotated position, which is read as
-- `copy` — an unannotated value crosses by value.
--
-- The only failure this reports of its own is an unrecognized discipline
-- `kind`. The TS source calls that branch unreachable for anything built via
-- `ownership.*`, but ffi-ir's meta bag is open and `ownership_of` deliberately
-- does not validate what it finds there, so a malformed discipline is data this
-- projector must diagnose rather than mis-lower. Data-shape failures come from
-- `to_ctypes_shape` and are propagated unchanged.
--: (ref: TypeRef) -> (string | nil, string | nil)
function M.to_ctypes_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	local base, err = M.to_ctypes_shape(ref)
	if base == nil then return nil, err end
	if discipline == nil then return base end

	-- TYPECHECKER WORKAROUND, and a deliberate widening. Statically
	-- `OwnershipDiscipline.kind` is a closed literal union, so testing the four
	-- known kinds narrows the fall-through branch below to `never` and the
	-- checker rejects the report that branch builds. At runtime the discipline
	-- came out of an OPEN meta bag and `ownership_of` explicitly does not
	-- validate what it finds there, so an unrecognized kind is reachable data —
	-- the same reason the TS source casts to `{ kind: string }` to build its
	-- own unreachable-guard message. Same gap as the recorded TODO.md entry "a
	-- second read of an imported tagged union's discriminant, after narrowing on
	-- that same discriminant, is typed `never`" (worked around in
	-- `wit.lua` by reading the discriminant through an open structural
	-- cast; the widening cast here is the same trade). Revert to a direct
	-- `discipline.kind` dispatch — which would also restore the exhaustiveness
	-- checking this widening gives up — once that resolves.
	local kind = discipline.kind --[[: string]]
	if kind == "copy" then return base end
	if kind == "opaque-handle" or kind == "refcount" or kind == "resource" then
		return "POINTER(" .. base .. ")"
	end

	return nil, 'to_ctypes_type: unhandled ownership discipline "' .. kind .. '"'
end

-- ── Declaration builders ─────────────────────────────────────────────────────

-- One function's ctypes wiring: the `.argtypes`/`.restype` assignment on the
-- raw `lib.<fn_name>` symbol, plus a thin Pythonic wrapper function with the
-- same name (escaped/snake_cased) that calls it — matching the way hand-rolled
-- ctypes wrapper modules (and generators such as ctypesgen) structure bindings:
-- the raw `CDLL` symbol stays reachable via `lib.*`, and calling code is meant
-- to use the wrapper.
--
-- `self_param`, when given, is the resource name for a method's synthesized
-- `handle` parameter (mirroring the C-ABI backend's identical `selfParam`
-- synthesis — ffi-ir's `method` kind names its receiver by resource name only,
-- carrying no parameter of its own). Unlike the Ruby backend's equivalent, the
-- value is used and not merely tested for presence: the emitted argtype is
-- `POINTER(<resource>)`, the distinct per-resource handle type this backend can
-- express.
--
-- The wrapper's body is a genuine call-through (it really does call into the
-- loaded library) — ffi-ir carries only the signature, so there is no
-- library-side implementation to stub, unlike the producer-side C-ABI and
-- wasm-bindgen backends' `todo!()` bodies.
--: (fn_name: string, ref: FfiRef, shape: FfiFunctionLike, self_param: string | nil) -> (string | nil, string | nil)
local function build_function(fn_name, ref, shape, self_param)
	local param_names = {} --[[: { [integer]: string } ]]
	local argtypes = {} --[[: { [integer]: string } ]]
	local n = 0
	if self_param ~= nil then
		n = n + 1
		param_names[n] = "handle"
		argtypes[n] = "POINTER(" .. self_param .. ")"
	end

	for i = 1, #shape.params do
		local param = shape.params[i]
		local mapped, err = M.to_ctypes_type(param.type)
		if mapped == nil then return nil, err end
		n = n + 1
		param_names[n] = escape_py_ident(to_snake_case(param.name))
		argtypes[n] = mapped
	end

	-- A `void`/`null` return is `restype = None` without consulting
	-- `to_ctypes_type`, so that an ownership annotation on a void return cannot
	-- produce the nonsensical `POINTER(None)`.
	local return_kind = shape.returnType.shape.kind
	local restype = "None"
	if return_kind ~= "void" and return_kind ~= "null" then
		local mapped, err = M.to_ctypes_type(shape.returnType)
		if mapped == nil then return nil, err end
		restype = mapped
	end

	local joined_params = table.concat(param_names, ", ")
	local lines = doc_comment("", ref.meta)
	lines[#lines + 1] = "lib." .. fn_name .. ".argtypes = [" .. table.concat(argtypes, ", ") .. "]"
	lines[#lines + 1] = "lib." .. fn_name .. ".restype = " .. restype
	lines[#lines + 1] = ""
	lines[#lines + 1] = "def " .. fn_name .. "(" .. joined_params .. "):"
	lines[#lines + 1] = "    return lib." .. fn_name .. "(" .. joined_params .. ")"
	return table.concat(lines, "\n")
end

-- The opaque-handle Structure declaration for a resource — see the file
-- header's "Incomplete Types" citation. Permanently incomplete (no `_fields_`
-- ever assigned): calling code only ever holds `POINTER(Name)`, never
-- dereferences the pointee, matching cbindgen's own opaque-pointer convention
-- the C-ABI backend implements on the producer side.
--: (name: string, ref: FfiRef) -> string
local function build_opaque_struct(name, ref)
	local lines = doc_comment("", ref.meta)
	lines[#lines + 1] = "class " .. name .. "(Structure):"
	lines[#lines + 1] = "    pass"
	return table.concat(lines, "\n")
end

-- A resource's method surface projected as a Python class: `__init__` stores
-- the raw `POINTER(Name)` handle, each method is a bound method delegating to
-- `lib.<resource>_<method>(self._handle, ...)`, and `__del__` calls the paired
-- free function — the free-function-per-resource convention the C-ABI backend
-- establishes on the producer side (`<resource>_free`), assumed here by the
-- same fixed-name convention since ffi-ir's `resource` shape carries no
-- `freeFn` of its own (only a *reference's* `OwnershipDiscipline.freeFn` does,
-- and no reference is in scope at a resource declaration itself). This is the
-- idiomatic hand-rolled-ctypes-wrapper shape for an opaque handle (own the
-- pointer, expose methods, free on GC) — the mirror of a `cffi`/`ctypesgen`
-- wrapper class, not a bare function-taking-a-raw-handle style, so calling code
-- gets normal Python object semantics over the raw handle.
--
-- Takes the resource's `methods` map rather than the whole shape: a cast of an
-- open `FfiShape` to the closed `FfiResourceShape` alias is rejected (a
-- `kind: string` cannot narrow to the literal `"resource"`), so the entry point
-- destructures the shape through an open structural cast and passes the map
-- along — same shape as `ruby_ffi.lua`'s equivalent builders.
--: (name: string, methods: { [string]: FfiRef }) -> string
local function build_resource_class(name, methods)
	local resource_snake = to_snake_case(name)
	local lines = {
		"class " .. name .. ":",
		"    def __init__(self, handle):",
		"        self._handle = handle",
		"",
	} --[[: { [integer]: string } ]]
	local n = #lines

	local method_names = ordered_keys(methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_shape = methods[method_name].shape --[[: FfiFunctionLike]]
		local py_method_name = escape_py_ident(to_snake_case(method_name))

		local param_names = {} --[[: { [integer]: string } ]]
		for j = 1, #method_shape.params do
			param_names[j] = escape_py_ident(to_snake_case(method_shape.params[j].name))
		end
		local joined_params = table.concat(param_names, ", ")
		local call_args = #param_names > 0 and ("self._handle, " .. joined_params) or "self._handle"

		n = n + 1
		lines[n] = "    def " .. py_method_name .. "(self" .. (#param_names > 0 and (", " .. joined_params) or "") .. "):"
		n = n + 1
		lines[n] = "        return " .. resource_snake .. "_" .. to_snake_case(method_name) .. "(" .. call_args .. ")"
		n = n + 1
		lines[n] = ""
	end

	lines[n + 1] = "    def __del__(self):"
	lines[n + 2] = "        " .. resource_snake .. "_free(self._handle)"
	return table.concat(lines, "\n")
end

-- A resource -> its opaque Structure declaration, each method's wiring, the
-- paired free function's wiring, and the handle-owning wrapper class.
--: (name: string, ref: FfiRef, methods: { [string]: FfiRef }) -> (string | nil, string | nil)
local function build_resource(name, ref, methods)
	local resource_snake = to_snake_case(name)
	local decls = { build_opaque_struct(name, ref) } --[[: { [integer]: string } ]]
	local n = 1

	local method_names = ordered_keys(methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = methods[method_name]
		local fn_name = resource_snake .. "_" .. to_snake_case(method_name)
		local decl, err = build_function(fn_name, method_ref, method_ref.shape --[[: FfiFunctionLike]], name)
		if decl == nil then return nil, err end
		n = n + 1
		decls[n] = decl
	end

	-- The paired free function's own argtypes/restype — no ffi-ir shape backs it
	-- directly (same as the C-ABI backend's `buildFreeFunction`, which likewise
	-- synthesizes it rather than reading one from the IR), so its wiring is
	-- emitted inline rather than routed through `build_function`.
	n = n + 1
	decls[n] = table.concat({
		"lib." .. resource_snake .. "_free.argtypes = [POINTER(" .. name .. ")]",
		"lib." .. resource_snake .. "_free.restype = None",
		"",
		"def " .. resource_snake .. "_free(handle):",
		"    return lib." .. resource_snake .. "_free(handle)",
	}, "\n")

	decls[n + 1] = build_resource_class(name, methods)
	return table.concat(decls, "\n\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower one ffi-ir `FfiRef` to Python `ctypes` consumer source.
--
--   function — `.argtypes`/`.restype` wiring plus a thin wrapper function
--              (requires `name`, mirroring the C-ABI backend's identical
--              requirement).
--   method   — the same, plus a synthesized `handle` first parameter (requires
--              `name`, the method's own key in its resource's methods map).
--   resource — the opaque `Structure` declaration, each method's wiring, the
--              paired free-function wiring, and a Python class wrapping the
--              handle (`name`, if given, is IGNORED — the shape carries its own
--              `name`, matching the C-ABI backend's identical convention).
--   module   — one `from ctypes import *` + `CDLL(...)` load block, followed by
--              all contained resources then all contained functions.
--              `library_path` names the shared-library path passed to `CDLL`;
--              defaults to a `./lib<module-name>.so`-shaped placeholder (Linux
--              shared-object naming convention) when omitted — callers
--              generating real bindings should pass the actual build output
--              path. (Contrast the Ruby backend, which has no such default and
--              requires `meta.libPath`; the difference is the TS sources', not
--              a choice made in this port.)
--
-- Reports `(nil, errmsg)` for any type-ir kind `to_ctypes_shape` doesn't
-- implement, anywhere in a crossed `TypeRef` — the same explicit
-- report-on-unsupported pattern the C-ABI backend uses for ownership
-- disciplines and kinds it can't realize on its own target.
--: (ref: FfiRef, name: string | nil, library_path: string | nil) -> (string | nil, string | nil)
function M.to_ctypes(ref, name, library_path)
	local kind = ref.shape.kind

	if kind == "function" then
		if name == nil then
			return nil,
				'to_ctypes: "function" requires a name — a C export is a named symbol, not an anonymous inline type'
		end
		return build_function(to_snake_case(name), ref, ref.shape --[[: FfiFunctionLike]], nil)
	end

	if kind == "method" then
		if name == nil then
			return nil, 'to_ctypes: "method" requires a name — the method\'s own key in its resource\'s methods map'
		end
		-- An open structural cast, not one to the closed `FfiMethodShape` alias:
		-- narrowing an `FfiShape`'s `kind: string` to the literal `"method"` is
		-- not something the checker can currently do, so a cast to the closed
		-- alias is rejected outright. Reading just the fields this branch needs
		-- through a `...`-open record is the formulation that checks — the same
		-- one `ruby_ffi.lua` uses at the identical spot.
		local receiver = (ref.shape --[[: { receiver: string, ... }]]).receiver
		local fn_name = to_snake_case(receiver) .. "_" .. to_snake_case(name)
		return build_function(fn_name, ref, ref.shape --[[: FfiFunctionLike]], receiver)
	end

	if kind == "resource" then
		local shape = ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
		return build_resource(shape.name, ref, shape.methods)
	end

	if kind == "module" then
		local shape = ref.shape --[[:
			{ name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		local path = library_path or ("./lib" .. to_snake_case(shape.name) .. ".so")
		local header = table.concat({ "from ctypes import *", "", "lib = CDLL(" .. quote(path) .. ")" }, "\n")
		local out = { header } --[[: { [integer]: string } ]]
		local n = 1

		-- Resources before functions, matching the TS source's own order: a
		-- module-level function's signature routinely names a resource's
		-- Structure class (a constructor returns `POINTER(FileHandle)`), and in
		-- Python that class must already be bound at module-execution time.
		local res_names = ordered_keys(shape.resources)
		for i = 1, #res_names do
			local decl, err = M.to_ctypes(shape.resources[res_names[i]], res_names[i], nil)
			if decl == nil then return nil, err end
			n = n + 1
			out[n] = decl
		end

		local fn_names = ordered_keys(shape.functions)
		for i = 1, #fn_names do
			local decl, err = M.to_ctypes(shape.functions[fn_names[i]], fn_names[i], nil)
			if decl == nil then return nil, err end
			n = n + 1
			out[n] = decl
		end

		return table.concat(out, "\n\n")
	end

	return nil, 'to_ctypes: unhandled ffi-ir kind "' .. kind .. '" — no ctypes mapping implemented for this backend'
end

return M
