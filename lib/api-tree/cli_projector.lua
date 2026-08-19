-- lib/api-tree/cli_projector.lua — the CLI projection of a Node tree, ported
-- from fractal's packages/cli-api-projector (`src/cli.ts` + `src/completions.ts`).
--
-- Walks a Node tree along an argv subcommand path, resolving:
--   - branch children        → subcommand prefix segments
--   - `fallback` (wildcard)  → the current argv token IS the slug value
--                              directly (no separate key segment — the value
--                              itself discriminates, not a tree-authored name)
--   - leaf children          → terminal subcommand names
--
-- Tag-driven behavior, read from the leaf's OWN `meta.tags` (no ancestor
-- inheritance — see tags.lua):
--   destructive → confirm before running (skippable via --yes/--force)
--   streaming   → array results print one JSON object per line
--   deprecated  → "[DEPRECATED]" marker in listings and leaf help
--
-- A handler returning a `lib/api-tree/stream.lua` stream is drained
-- incrementally regardless of those tags, exactly as the TS side streams an
-- `AsyncIterable`.
--
-- ── Relationship to lib/cli ──────────────────────────────────────────────
--
-- `lib/cli` is a SPEC-DRIVEN parser: the caller declares flags, options and
-- positionals up front and gets help text and completions derived from that
-- declaration. This projector derives everything from a Node tree instead,
-- and must accept flags it was never told about (a schema-less tree parses
-- any `--flag` into the handler's input). The two have no shared
-- representation and are deliberately not merged; they sit alongside each
-- other and a program picks one.
--
-- ── Deliberate divergences from the TypeScript source ────────────────────
--
-- CAPS, NOT GLOBALS. TS reads `process.stdout`/`process.stderr`/`process.env`
-- and defaults `io` to them. This repo is caps-first: `run_cli` takes a
-- `Caps` table (`stdout_write`, `stderr_write`, `confirm`, `env`) and raises
-- when one is missing. There is no default that reaches for a global. That
-- raise is a programmer error (a raw `error`, not a `CliError`) — distinct
-- from the user-facing failures below.
--
-- FAILURES ARE PROMISE REJECTIONS. `run_cli` returns a lib/async promise (the
-- `async`/`await` convention direct.lua's leaf callables already use). TS
-- throws a `CliError` class carrying `exitCode`; a promise can only carry ONE
-- rejection value, so a CLI failure rejects with the DU-tagged
-- `{ kind = "cli_error", message = ..., exit_code = ... }` — the same tagged
-- shape result.lua's `{ kind = "ok" }`/`{ kind = "err" }` uses. `is_cli_error`
-- is the matching sniff.
--
-- DETERMINISTIC KEY ORDER. TS relies on `Object.entries` insertion order for
-- command listings, completion levels and JSON output. LuaJIT randomizes hash
-- iteration per process, so every place the TS depends on that order, this
-- port sorts keys: child names via `sorted_keys`, JSON via `lib/json`'s
-- `sort_keys` option (the same answer cache.lua's canonical serializer gives
-- to the same problem). Output is therefore key-sorted rather than
-- author-ordered, and is stable across runs.
--
-- ENCODING IS FALLIBLE. `JSON.stringify` silently drops a function-valued
-- field and never fails on ordinary data; `lib/json` returns `(nil, err)`
-- instead. A value it cannot encode therefore surfaces as a `CliError` on the
-- output path rather than as a lossy `{}`, since a CLI has no other channel
-- to report it on.
--
-- NOT PORTED. `CliOpts.validators` (build.ts's `wrapValidators` /
-- `isValidatorWrapped`) and `CliOpts.als` (context.ts's `AsyncLocalStorage`
-- config) have no ported dependency in this repo, so they are omitted
-- entirely rather than stubbed — the same treatment cache.ts's
-- `ts.Program`-bound entry points got (see cache.lua's SCOPE note). TODO.md
-- carries an entry for each.
--
-- ONE FILE. `cli.ts` and `completions.ts` are mutually dependent
-- (`completions.ts` imports `getCliMeta`, `cli.ts` imports
-- `generateCompletions`). Lua's `require` cycle handling makes that split
-- hostile for no benefit, so both live here.
--
-- See:
--   lib/api-tree/init.lua   — Node, op/api, is_array
--   lib/api-tree/tags.lua   — resolve_tags
--   lib/api-tree/input.lua  — assemble (store-based input resolution)
--   lib/api-tree/stream.lua — the streaming convention this drains
--   lib/api-tree/page.lua   — the pagination shape `--all-pages` walks

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local async       = require("lib.async")
local json        = require("lib.json")
local levenshtein = require("lib.levenshtein")
local api_tree     = require("lib.api-tree")
local input_mod   = require("lib.api-tree.input")
local page        = require("lib.api-tree.page")
local result_mod  = require("lib.api-tree.result")
local stream      = require("lib.api-tree.stream")
local tags_mod    = require("lib.api-tree.tags")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────
--
-- Every type this module reads from a sibling module is declared
-- STRUCTURALLY here rather than imported, matching tags.lua and direct.lua,
-- which do the same for `Node`/`PromiseP`. Only runtime functions cross the
-- module boundary.

--:: Meta = { [string]: unknown }
--:: NodeView = { handler?: (input: unknown) -> unknown, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: Meta }

-- The slice of a JSON Schema this projector reads — field help, flag
-- coercion and completion enum values. `items` is typed as a schema; a JSON
-- Schema `false` (the "no items permitted" spelling) is handled at runtime by
-- a `type(...) == "table"` guard rather than widened into the type.
--:: SchemaView = { type?: string, enum?: { [integer]: string }, items?: SchemaView, properties?: { [string]: SchemaView }, required?: { [integer]: string }, default?: unknown, description?: string }
--:: ToolSchema = { inputSchema: SchemaView }
--:: SchemaMap = { [string]: ToolSchema }

-- The resolved-tag view tags.lua returns.
--:: ResolvedTagsView = { readOnly?: boolean, idempotent?: boolean, destructive?: boolean, openWorld?: boolean, streaming?: boolean, deprecated?: boolean, conflict?: string }

-- The injected capabilities. `confirm` may return a plain boolean or a
-- promise of one — the same "await it if it is a promise" reading direct.lua
-- applies to a handler's return value.
--:: Caps = { stdout_write: (s: string) -> nil, stderr_write: (s: string) -> nil, confirm: (prompt: string) -> unknown, env: { [string]: string } }

--:: CliError = { kind: "cli_error", message: string, exit_code: integer }

--:: FlagValue = string | { [integer]: string } | boolean
--:: Flags = { [string]: FlagValue }
--:: Slugs = { [string]: string }
--:: Store = { [string]: unknown }
--:: Stores = { [string]: Store }

--:: ParamSource = { store: string, key?: string }
--:: SourceMap = { [string]: ParamSource }

-- `meta.cli`: an open per-projection override bag. `name`/`alias`/
-- `sourceMap`/`paginated` are leaf-position keys, `hidden` is valid at both
-- leaf and branch position. The camelCase spellings are the authored wire
-- names from the TS side and are not renamed.
--:: CliMetaView = { hidden?: boolean, name?: string, alias?: string, description?: string, sourceMap?: SourceMap, paginated?: { inputCursorParam?: string, inputOffsetParam?: string } }
--:: PaginatedMeta = { inputCursorParam?: string, inputOffsetParam?: string }

--:: Resolved = { handler: (input: unknown) -> unknown, slugs: Slugs, leaf_name: string, leaf_meta: Meta, schema_path: { [integer]: string } }

--:: ErrorResponse = { exit_code: integer, message: string }
--:: ErrorEncoder = (error_value: unknown) -> (ErrorResponse | nil)

--:: Detection = { result?: boolean, streaming?: boolean }
--:: HandlerFn = (input: unknown, stores: Stores) -> unknown
--:: Middleware = (next_fn: HandlerFn) -> HandlerFn

--:: Opts = { schemas?: SchemaMap, program_name?: string, version?: string, middleware?: { [integer]: Middleware }, detection?: Detection, error_encoder?: ErrorEncoder }

--:: ParsedArgv = { flags: Flags, help: boolean, version: boolean, yes: boolean, json: boolean, jsonl: boolean, all_pages: boolean }

--:: StreamView = { kind: "stream", next: () -> unknown }
--:: PageView = { items: { [integer]: unknown }, hasMore: boolean, cursor?: string, offset?: number, total?: number }
--:: ResultView = { kind: string, value: unknown, error: unknown }
--:: ProgressView = { progress: number, total?: number, message?: string }

-- The slice of lib/async's promise this module reads, with the `...`
-- structural-subtyping marker its own declaration carries — the same view
-- direct.lua declares for the same reason.
--:: PromiseView = { _state: string, value: unknown, reason: unknown, ... }

-- ── CliError — the failure carrier ───────────────────────────────────────

--: (message: string, exit_code: integer) -> CliError
local function cli_error(message, exit_code)
	return { kind = "cli_error", message = message, exit_code = exit_code }
end

M.cli_error = cli_error

-- The opt-in runtime sniff for a rejection payload, mirroring
-- `result.is_result_shape` and `page.is_page_shape`. Exact on `kind`, so a
-- handler's own error value carrying an unrelated `kind` never
-- false-positives.
--: (v: unknown) -> boolean
function M.is_cli_error(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	return t.kind == "cli_error"
end

-- ── Small shared helpers ─────────────────────────────────────────────────

-- Sorted key list of a string-keyed table. Every walk over `children` goes
-- through this: LuaJIT's `pairs` order is randomized per process, and the TS
-- source it is ported from walks object insertion order, so the only
-- reproducible reading is a sorted one (see the module doc).
--: (t: { [string]: unknown }) -> { [integer]: string }
local function sorted_keys(t)
	local keys = {} --: { [integer]: string }
	local n = 0
	for k in pairs(t) do
		n = n + 1
		keys[n] = k
	end
	table.sort(keys)
	return keys
end

-- Format a number for human-facing text without Lua's trailing `.0` on
-- integral floats (`25`, not `25.0`) — the reading JS's `String(n)` gives.
--: (n: number) -> string
local function number_text(n)
	if n % 1 == 0 then return string.format("%d", n) end
	return tostring(n)
end

-- Narrowing predicates over the sibling modules' plain-boolean sniffs, so the
-- value can be read without a cast past `unknown` — the idiom stream.lua's
-- `is_chunk_effect` and cache.lua's `is_json_array` already use.
--: (v: unknown) -> v is PromiseView
local function is_promise(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [string]: unknown }]]
	return t._state ~= nil
end

--: (v: unknown) -> v is StreamView
local function is_stream_value(v)
	return stream.is_stream(v)
end

--: (v: unknown) -> v is PageView
local function is_page_value(v)
	return page.is_page_shape(v)
end

--: (v: unknown) -> v is ResultView
local function is_result_value(v)
	return result_mod.is_result_shape(v)
end

--: (v: unknown) -> v is ProgressView
local function is_progress_effect(v)
	return result_mod.is_stream_progress(v)
end

-- Await `v` when it is a promise, pass it through when it is a plain value —
-- direct.lua's convention for a handler's return value, applied here to
-- every value that MAY be asynchronous (a handler result, the `confirm` cap).
-- Only legal inside an async body.
--: (v: unknown) -> unknown
local function settle(v)
	if is_promise(v) then return async.await(v) end
	return v
end

-- Encode a value as JSON with keys sorted (see the module doc's determinism
-- note). `indent` of nil produces one compact line. A value lib/json cannot
-- encode (a cycle, a function) raises a `CliError` — the transport has no
-- other channel to report it on.
--: (v: unknown, indent: number | nil) -> string
local function encode_json(v, indent)
	if v == nil then return "null" end
	local opts = { indent = indent, sort_keys = true --[[: boolean | nil]] }
	local text, err = json.encode(v, opts)
	if text == nil then
		error(cli_error("could not encode the result as JSON: " .. (err or "unknown error"), 1))
	end
	return text
end

-- One JSONL line for a value — `null` for nil, matching the non-streaming
-- default output's convention.
--: (v: unknown) -> string
local function json_line(v)
	return encode_json(v, nil) .. "\n"
end

-- `JSON.stringify(error)` in the default error message. Unencodable error
-- values fall back to `tostring`, since failing to render an error is not
-- itself worth failing on.
--: (v: unknown) -> string
local function error_text(v)
	if v == nil then return "null" end
	local opts = { indent = nil --[[: number | nil]], sort_keys = true --[[: boolean | nil]] }
	local text = json.encode(v, opts)
	if text == nil then return tostring(v) end
	return text
end

-- A node is a leaf when it carries a handler — the reading node.ts's `isLeaf`
-- uses. A node carrying BOTH a handler and children is a leaf here too.
--: (n: NodeView) -> boolean
local function is_leaf(n)
	return n.handler ~= nil
end

-- ── meta.cli ─────────────────────────────────────────────────────────────

-- Read the `meta.cli` bag. Absent or non-table `meta.cli` reads as an empty
-- bag, so every call site can index the result directly.
--: (meta: Meta) -> CliMetaView
function M.read_cli_meta(meta)
	local c = meta.cli
	if type(c) ~= "table" then return {} end
	return c --[[: CliMetaView]]
end

--: (meta: Meta) -> string | nil
local function description_of(meta)
	local d = meta.description
	if type(d) == "string" then return d end
	local c = M.read_cli_meta(meta).description
	if type(c) == "string" then return c end
	return nil
end

-- Resolve a node's own tags through tags.lua's implication lattice. No
-- ancestor inheritance — a node's tags are exactly what is on the node.
--: (meta: Meta) -> ResolvedTagsView
local function tags_of(meta)
	local t = meta.tags
	if type(t) ~= "table" then
		return tags_mod.resolve_tags({}, nil) --[[: ResolvedTagsView]]
	end
	return tags_mod.resolve_tags(t --[[: { [string]: boolean }]], nil) --[[: ResolvedTagsView]]
end

--: (meta: Meta) -> boolean
local function is_hidden(meta)
	return M.read_cli_meta(meta).hidden == true
end

-- ── Schema lookup ────────────────────────────────────────────────────────

-- The underscore-joined key convention `extractToolSchemas` produces: a
-- fallback segment contributes `fallback.name`, never the runtime slug value
-- the user typed.
--: (schema_path: { [integer]: string }) -> string
local function schema_key_for(schema_path)
	local joined = table.concat(schema_path, "_")
	local key = joined:gsub("%-", "_")
	return key
end

--: (schemas: SchemaMap, schema_path: { [integer]: string }) -> SchemaView | nil
local function input_schema_for(schemas, schema_path)
	local entry = schemas[schema_key_for(schema_path)]
	if entry == nil then return nil end
	return entry.inputSchema
end

-- ── Resolution: walk the Node tree along argv segments ───────────────────

-- Find a leaf child whose `meta.cli.alias` equals `head`. Returns the child's
-- CANONICAL key alongside the node — schema lookups and help text key off the
-- canonical name, so an alias is an alternate spelling, never a rename.
--: (children: { [string]: NodeView }, head: string) -> (string | nil, NodeView | nil)
local function find_leaf_by_alias(children, head)
	local keys = sorted_keys(children)
	for i = 1, #keys do
		local key = keys[i]
		local child = children[key]
		if child ~= nil and is_leaf(child) and M.read_cli_meta(child.meta).alias == head then
			return key, child
		end
	end
	return nil, nil
end

--: (slugs: Slugs, name: string, value: string) -> Slugs
local function extend_slugs(slugs, name, value)
	local out = {} --: Slugs
	for k, v in pairs(slugs) do out[k] = v end
	out[name] = value
	return out
end

--: (path: { [integer]: string }, segment: string) -> { [integer]: string }
local function extend_path(path, segment)
	local out = {} --: { [integer]: string }
	for i = 1, #path do out[i] = path[i] end
	out[#path + 1] = segment
	return out
end

-- Walk the tree along `segments` starting at index `i`:
--
--   static child (branch) → consume the segment, recurse
--   no static match + fallback → the segment IS the slug value; bind it as
--     `fallback.name` and recurse into the subtree
--   leaf child at the tail → terminal; resolved
--
-- A leaf's `meta.cli.alias` is accepted at the terminal position too. Returns
-- nil when no path matches.
--: (n: NodeView, segments: { [integer]: string }, i: integer, slugs: Slugs, schema_path: { [integer]: string }) -> Resolved | nil
local function resolve_leaf(n, segments, i, slugs, schema_path)
	if i > #segments then return nil end
	local head = segments[i]
	local children = n.children or {}
	local fallback = n.fallback

	-- Terminal segment: `head` names a leaf child, by key or by alias.
	if i == #segments then
		local key = head --: string | nil
		local child = children[head] --: NodeView | nil
		if child == nil then
			key, child = find_leaf_by_alias(children, head)
		end
		if child ~= nil and key ~= nil and is_leaf(child) then
			local handler = child.handler
			if handler ~= nil then
				return {
					handler = handler,
					slugs = slugs,
					leaf_name = key,
					leaf_meta = child.meta,
					schema_path = extend_path(schema_path, key),
				}
			end
		end

		-- No static or alias match. `head` may BE a fallback-captured slug
		-- value with the fallback subtree itself a bare leaf (`op()`, no
		-- further subcommand) — the Node model allows that, and without this
		-- check a real handler at `fallback.subtree` would be unreachable.
		if fallback ~= nil and is_leaf(fallback.subtree) then
			local handler = fallback.subtree.handler
			if handler ~= nil then
				return {
					handler = handler,
					slugs = extend_slugs(slugs, fallback.name, head),
					leaf_name = fallback.name,
					leaf_meta = fallback.subtree.meta,
					schema_path = extend_path(schema_path, fallback.name),
				}
			end
		end

		return nil
	end

	-- Non-terminal: a static child always wins over the fallback.
	local static_child = children[head]
	if static_child ~= nil then
		if not is_leaf(static_child) then
			return resolve_leaf(static_child, segments, i + 1, slugs, extend_path(schema_path, head))
		end
		-- A leaf at a non-tail position is a dead end: it has no children.
		return nil
	end

	if fallback ~= nil then
		return resolve_leaf(
			fallback.subtree,
			segments,
			i + 1,
			extend_slugs(slugs, fallback.name, head),
			extend_path(schema_path, fallback.name)
		)
	end

	return nil
end

-- ── Help text ────────────────────────────────────────────────────────────

--: (fs: SchemaView) -> string | nil
local function describe_field_type(fs)
	local enum_values = fs.enum
	if enum_values ~= nil then
		return "enum: " .. table.concat(enum_values, "|")
	end
	if fs.type == "array" then
		local items = fs.items
		if items ~= nil then
			-- TYPECHECKER WORKAROUND: the cast restates this function's own
			-- declared return type. A RECURSIVE call's result is typed `never`
			-- rather than the annotated `string | nil`, so narrowing it with
			-- `~= nil` and concatenating is rejected ("cannot concatenate type
			-- `never`"). The identical call to a non-recursive function of the
			-- same signature checks clean. See TODO.md.
			local item_type = describe_field_type(items) --[[: string | nil]]
			if item_type ~= nil then return item_type .. "[]" end
		end
		return "array"
	end
	return fs.type
end

--: (lines: { [integer]: string }, text: string) -> nil
local function push(lines, text)
	lines[#lines + 1] = text
end

-- Group help: the node's own description, its leaf children (callables), its
-- branch children, and the global flags.
--: (n: NodeView, path: { [integer]: string }, program_name: string) -> string
local function build_help(n, path, program_name)
	local lines = {} --: { [integer]: string }
	local cmd = program_name
	for i = 1, #path do cmd = cmd .. " " .. path[i] end

	local desc = description_of(n.meta)
	if desc ~= nil then
		push(lines, desc)
		push(lines, "")
	end

	push(lines, "Usage: " .. cmd .. " <subcommand> [options]")
	push(lines, "")

	local children = n.children or {}
	local keys = sorted_keys(children)

	local leaf_keys = {} --: { [integer]: string }
	local branch_keys = {} --: { [integer]: string }
	for i = 1, #keys do
		local child = children[keys[i]]
		if child ~= nil and is_leaf(child) then
			leaf_keys[#leaf_keys + 1] = keys[i]
		elseif child ~= nil then
			branch_keys[#branch_keys + 1] = keys[i]
		end
	end

	if #leaf_keys > 0 then
		push(lines, "Commands:")
		for i = 1, #leaf_keys do
			local key = leaf_keys[i]
			local child = children[key]
			if child ~= nil and not is_hidden(child.meta) then
				local cli_meta = M.read_cli_meta(child.meta)
				local leaf_desc = description_of(child.meta)
				local shown = cli_meta.name or key
				local alias = cli_meta.alias
				local alias_suffix = alias ~= nil and (" (alias: " .. alias .. ")") or ""
				local deprecated_prefix = tags_of(child.meta).deprecated == true and "[DEPRECATED] " or ""
				local desc_suffix = leaf_desc ~= nil and ("  — " .. leaf_desc) or ""
				push(lines, "  " .. deprecated_prefix .. shown .. alias_suffix .. desc_suffix)
			end
		end
	end

	local fallback = n.fallback
	if #branch_keys > 0 or fallback ~= nil then
		if #leaf_keys > 0 then push(lines, "") end
		push(lines, "Subcommand groups:")
		for i = 1, #branch_keys do
			local key = branch_keys[i]
			local child = children[key]
			if child ~= nil and not is_hidden(child.meta) then
				local child_desc = description_of(child.meta)
				push(lines, "  " .. key .. (child_desc ~= nil and ("  — " .. child_desc) or ""))
			end
		end
		if fallback ~= nil and not is_hidden(fallback.subtree.meta) then
			push(lines, "  <" .. fallback.name .. ">  — parameterized group")
		end
	end

	push(lines, "")
	push(lines, "Global flags:")
	push(lines, "  --help        Show this help text")
	push(lines, "  --version, -V  Print the program version")
	push(lines, "  --json        Output result as JSON (default)")
	push(lines, "  --yes, --force  Skip confirmation prompts for destructive ops")
	push(lines, "")
	push(lines, "Run '" .. cmd .. " completions <bash|zsh|fish>' to print a shell completion script.")

	return table.concat(lines, "\n") .. "\n"
end

-- Leaf help: description, tag notices, and one line per input-schema field.
--: (resolved: Resolved, path: { [integer]: string }, program_name: string, schemas: SchemaMap) -> string
local function build_leaf_help(resolved, path, program_name, schemas)
	local lines = {} --: { [integer]: string }
	local cmd = program_name
	for i = 1, #path do cmd = cmd .. " " .. path[i] end

	local desc = description_of(resolved.leaf_meta)
	if desc ~= nil then
		push(lines, desc)
		push(lines, "")
	end
	push(lines, "Usage: " .. cmd .. " [options]")
	push(lines, "")

	local tags = tags_of(resolved.leaf_meta)
	if tags.deprecated == true then
		push(lines, "  [DEPRECATED] This operation is deprecated and may be removed.")
		push(lines, "")
	end
	if tags.destructive == true then
		push(lines, "  This operation is destructive and irreversible. Requires --yes/--force to skip confirmation.")
		push(lines, "")
	end
	if tags.readOnly == true then
		push(lines, "  This operation is read-only.")
		push(lines, "")
	end
	if tags.streaming == true then
		push(lines, "  This operation streams results (one JSON object per line).")
		push(lines, "")
	end

	push(lines, "Options:")
	push(lines, "  --help        Show this help text")
	push(lines, "  --yes, --force  Skip confirm for destructive ops")
	push(lines, "  --json        Output as JSON (default)")

	local schema = input_schema_for(schemas, resolved.schema_path)
	local props = schema ~= nil and schema.properties or nil
	if props ~= nil then
		local required = (schema ~= nil and schema.required) or {}
		local required_set = {} --: { [string]: boolean }
		for i = 1, #required do required_set[required[i]] = true end
		local fields = sorted_keys(props)
		for i = 1, #fields do
			local field = fields[i]
			local fs = props[field]
			if fs ~= nil then
				local type_hint = describe_field_type(fs)
				local hint_text = type_hint ~= nil and ("  <" .. type_hint .. ">") or ""
				local fs_desc = fs.description
				local desc_text = fs_desc ~= nil and ("  " .. fs_desc) or ""
				local req = required_set[field] == true and " (required)" or " (optional)"
				push(lines, "  --" .. field .. hint_text .. desc_text .. req)
			end
		end
	end

	return table.concat(lines, "\n") .. "\n"
end

-- ── Argv parsing ─────────────────────────────────────────────────────────

-- Parse named `--flags` from argv into a flat bag.
--   valueless flag (nothing follows, or a `--` token does) → true
--   repeated flag → an array of its values
-- `--help`/`-h`, `--version`/`-V`, `--yes`/`--force`/`-y`, `--json`,
-- `--jsonl` and `--all-pages` are extracted rather than passed through.
--: (argv: { [integer]: string }) -> ParsedArgv
local function parse_flags(argv)
	local flags = {} --: Flags
	local help = false
	local version = false
	local yes = false
	local as_json = false
	local jsonl = false
	local all_pages = false

	local i = 1
	while i <= #argv do
		local arg = argv[i]
		if arg == "--help" or arg == "-h" then
			help = true
			i = i + 1
		elseif arg == "--version" or arg == "-V" then
			version = true
			i = i + 1
		elseif arg == "--yes" or arg == "--force" or arg == "-y" then
			yes = true
			i = i + 1
		elseif arg == "--json" then
			as_json = true
			i = i + 1
		elseif arg == "--jsonl" then
			jsonl = true
			i = i + 1
		elseif arg == "--all-pages" then
			all_pages = true
			i = i + 1
		elseif arg:sub(1, 2) == "--" then
			local key = arg:sub(3)
			local next_arg = argv[i + 1]
			if next_arg == nil or next_arg:sub(1, 2) == "--" then
				flags[key] = true
				i = i + 1
			else
				local existing = flags[key]
				if existing == nil then
					flags[key] = next_arg
				elseif type(existing) == "table" then
					local list = existing
					list[#list + 1] = next_arg
				elseif type(existing) == "string" then
					flags[key] = { existing, next_arg }
				end
				i = i + 2
			end
		else
			-- Non-flag tokens in the flag tail are ignored: path segments were
			-- already split off before this runs.
			i = i + 1
		end
	end

	return {
		flags = flags,
		help = help,
		version = version,
		yes = yes,
		json = as_json or not jsonl,
		jsonl = jsonl,
		all_pages = all_pages,
	}
end

-- ── Input assembly ───────────────────────────────────────────────────────

-- Assemble the handler's input bag from the CLI's named stores via
-- input.lua's `assemble`.
--
--   "flag" — the parsed `--flags`; the PRIMARY store (an unmarked param is a
--            CLI flag)
--   "path" — accumulated fallback-captured slug values; named "path" because
--            `assemble` resolves path params from a store with that literal
--            name
--   "env"  — the injected environment cap, reachable only through an explicit
--            `meta.cli.sourceMap` override (no convention pulls a field from
--            the environment implicitly)
--
-- `caller.user` is the CLI's analogue of HTTP auth headers: the OS-level
-- identity, read from the env cap's `USER` (falling back to Windows'
-- `USERNAME`). Anything richer is the consumer's job to layer on.
--
-- Returns the assembled input alongside the raw pre-assembly stores, which
-- middleware sees and the handler does not.
--: (flags: Flags, slugs: Slugs, source_map: SourceMap, env: { [string]: string }) -> (Store, Stores)
local function build_input(flags, slugs, source_map, env)
	local caller = { user = env.USER or env.USERNAME } --: Store
	local stores = {
		flag = flags --[[: Store]],
		path = slugs --[[: Store]],
		env = env --[[: Store]],
		caller = caller,
	} --: Stores

	-- The union of every key any store could produce: flag keys, slug keys,
	-- and any name a `sourceMap` declares (so a field pulled purely from an
	-- override is assembled even though no `--flag` carries it). Sorted, so
	-- assembly order does not vary run to run.
	local seen = {} --: { [string]: boolean }
	local names = {} --: { [integer]: string }
	--: (key: string) -> nil
	local function add(key)
		if seen[key] then return end
		seen[key] = true
		names[#names + 1] = key
	end
	for k in pairs(flags) do add(k) end
	for k in pairs(slugs) do add(k) end
	for k in pairs(source_map) do add(k) end
	table.sort(names)

	local slug_names = sorted_keys(slugs)
	return input_mod.assemble(stores, names, source_map, "flag", slug_names), stores
end

-- ── Coercion against the input schema ────────────────────────────────────
--
-- Flag values arrive as `string | string[] | true`. Each field present in
-- BOTH the input and the schema's `properties` is coerced to the declared
-- type before the handler runs; a field the schema does not know about (or
-- every field, when there is no schema) passes through untouched.
--
-- NUMERIC PARSING follows Lua's `tonumber`, not JS's `Number`. Two inputs
-- diverge observably: `""` (JS reads 0, `tonumber` rejects) and `"Infinity"`
-- (JS reads Infinity, `tonumber` rejects). Both readings are defensible and
-- the Lua one is stricter; it is recorded here so the difference is not later
-- read as an oversight.

-- The enum member closest to `value` by edit distance, FIRST minimum winning
-- so ties resolve deterministically. `lib/levenshtein`'s own `closest` sorts
-- with `table.sort`, which is unstable and would make a tie's outcome
-- arbitrary — only the distance metric is reused here, not the selection.
--: (value: string, options: { [integer]: string }) -> string | nil
local function closest_enum_match(value, options)
	local best = nil --: string | nil
	-- `best_distance` is a plain number rather than `number | nil`, with
	-- `best == nil` standing in for "nothing seen yet": the two are equivalent
	-- (they are set together) and a non-union distance keeps the comparison
	-- below free of a narrowing step.
	local best_distance = 0
	for i = 1, #options do
		local option = options[i]
		-- The cast states what `lib/levenshtein`'s `distance` returns. That
		-- function carries no `--:` signature of its own, so its return type
		-- crosses the module boundary as an unsolved variable: narrowing it
		-- with `~= nil` yields `never` rather than a number, and `or 0` yields
		-- `_ | integer`. Neither is usable in a comparison. Annotating
		-- `lib/levenshtein` itself is the real fix (see TODO.md); the cast is
		-- true of the function as written — it returns its final DP row cell,
		-- which is always populated.
		local d = levenshtein.distance(value, option) --[[: integer]]
		local take = best == nil
		if not take then take = d < best_distance end
		if take then
			best_distance = d
			best = option
		end
	end
	return best
end

-- Coerce one scalar against a non-array field schema. Returns
-- `(value, nil)` or `(nil, errmsg)` — the repo's fallible-return convention;
-- `run_cli` turns the message into a `CliError` rejection.
--: (field: string, value: unknown, schema: SchemaView) -> (unknown, string | nil)
local function coerce_scalar(field, value, schema)
	local enum_values = schema.enum
	if enum_values ~= nil then
		local str = type(value) == "string" and value or tostring(value)
		local found = false
		for i = 1, #enum_values do
			if enum_values[i] == str then found = true end
		end
		if not found then
			local suggestion = closest_enum_match(str, enum_values)
			local hint = suggestion ~= nil and (' Did you mean "' .. suggestion .. '"?') or ""
			return nil, "--" .. field .. ': invalid value "' .. str .. '" — expected one of: '
				.. table.concat(enum_values, ", ") .. "." .. hint
		end
		return str, nil
	end

	local raw_type = schema.type
	if raw_type == "number" or raw_type == "integer" then
		if type(value) == "boolean" then
			return nil, "--" .. field .. ": expected a number, got a boolean flag"
		end
		local n = tonumber(value)
		if n == nil then
			return nil, "--" .. field .. ': expected a number, got "' .. tostring(value) .. '"'
		end
		if raw_type == "integer" and n % 1 ~= 0 then
			return nil, "--" .. field .. ': expected an integer, got "' .. tostring(value) .. '"'
		end
		return n, nil
	end

	if raw_type == "boolean" then
		if type(value) == "boolean" then return value, nil end
		local str = tostring(value)
		local lowered = str:lower()
		if lowered == "true" or lowered == "1" or lowered == "yes" then return true, nil end
		if lowered == "false" or lowered == "0" or lowered == "no" then return false, nil end
		return nil, "--" .. field .. ': expected a boolean, got "' .. str .. '"'
	end

	-- "string", "object", or schema-less: left untouched.
	return value, nil
end

-- Coerce one field, handling the `array` wrapper around `coerce_scalar`.
--: (field: string, value: unknown, schema: SchemaView) -> (unknown, string | nil)
local function coerce_field(field, value, schema)
	if schema.type == "array" then
		local list = {} --: { [integer]: unknown }
		if type(value) == "table" and api_tree.is_array(value --[[: { [unknown]: unknown }]]) then
			local given = value --[[: { [integer]: unknown }]]
			for i = 1, #given do list[i] = given[i] end
		else
			list[1] = value
		end
		local items = schema.items
		-- A JSON Schema `items: false` is not a schema; nothing to coerce
		-- against, so the list passes through as-is.
		if type(items) ~= "table" then return list, nil end
		local out = {} --: { [integer]: unknown }
		for i = 1, #list do
			local coerced, err = coerce_scalar(field, list[i], items --[[: SchemaView]])
			if err ~= nil then return nil, err end
			out[i] = coerced
		end
		return out, nil
	end
	return coerce_scalar(field, value, schema)
end

-- Coerce a raw input bag against a leaf's input schema, field by field.
-- Fields absent from `schema.properties` — including every field when there
-- is no schema — pass through unchanged, which is what keeps schema-less
-- trees working.
--: (input: Store, schema: SchemaView | nil) -> (Store | nil, string | nil)
function M.coerce_input(input, schema)
	local props = schema ~= nil and schema.properties or nil
	if props == nil then return input, nil end

	local out = {} --: Store
	for k, v in pairs(input) do out[k] = v end
	local fields = sorted_keys(input)
	for i = 1, #fields do
		local field = fields[i]
		local fs = props[field]
		if fs ~= nil then
			local coerced, err = coerce_field(field, input[field], fs)
			if err ~= nil then return nil, err end
			out[field] = coerced
		end
	end
	return out, nil
end

-- Fill in `properties[field].default` for any field absent from `input`.
-- Defaults come out of the schema pre-typed, so no coercion is applied to
-- them. A field already present — including an explicit `false` or `0` — is
-- left alone.
--: (input: Store, schema: SchemaView | nil) -> Store
function M.apply_defaults(input, schema)
	local props = schema ~= nil and schema.properties or nil
	if props == nil then return input end

	local out = {} --: Store
	for k, v in pairs(input) do out[k] = v end
	local fields = sorted_keys(props)
	for i = 1, #fields do
		local field = fields[i]
		local fs = props[field]
		if fs ~= nil and out[field] == nil and fs.default ~= nil then
			out[field] = fs.default
		end
	end
	return out
end

-- Check that every `schema.required` field is present post-defaults. Reports
-- ALL missing fields at once, so a user fixing a multi-field miss does not
-- have to re-run once per field.
--: (input: Store, schema: SchemaView | nil) -> (boolean, string | nil)
function M.validate_required(input, schema)
	local required = schema ~= nil and schema.required or nil
	if required == nil then return true, nil end
	if #required == 0 then return true, nil end

	local missing = {} --: { [integer]: string }
	for i = 1, #required do
		local field = required[i]
		if input[field] == nil then missing[#missing + 1] = "--" .. field end
	end
	if #missing == 0 then return true, nil end
	local plural = #missing > 1 and "s" or ""
	return false, "Missing required field" .. plural .. ": " .. table.concat(missing, ", ")
end

-- ── Error encoders ───────────────────────────────────────────────────────

-- Build a `CliErrorEncoder` from a `kind` → `{ exit = n, message = s }` map:
-- `error_encoder_from_map({ notFound = { exit = 2 } })`. `exit` defaults to 1
-- and `message` to the default `Error: <json>` rendering, so an entry may
-- override either or both. Composed from one `result.match_kind` per entry.
--
-- The TS source documents "first match wins (object key order)"; each entry
-- matches a distinct `kind`, so at most one can ever match and the ordering
-- is unobservable — which is why LuaJIT's unordered `pairs` is harmless here.
--: (mapping: { [string]: { exit?: integer, message?: string } }) -> ErrorEncoder
function M.error_encoder_from_map(mapping)
	local encoders = {} --: { [integer]: (error_value: unknown) -> unknown }
	local kinds = sorted_keys(mapping)
	for i = 1, #kinds do
		local kind = kinds[i]
		encoders[i] = result_mod.match_kind(kind, mapping[kind])
	end
	local composed = result_mod.compose_error_encoders(unpack(encoders))
	return function(error_value)
		local matched = composed(error_value)
		if matched == nil then return nil end
		local override = matched --[[: { exit?: integer, message?: string }]]
		return {
			exit_code = override.exit or 1,
			message = override.message or ("Error: " .. error_text(error_value)),
		}
	end
end

-- ── Completions ──────────────────────────────────────────────────────────
--
-- Everything emitted here is baked in at generation time from the tree's own
-- shape plus the schema map — there is no dynamic invocation of the CLI at
-- completion time, so the generated script is self-contained.
--
-- A fallback (wildcard-capture) segment's own value can never be completed
-- (it is arbitrary user data); what CAN be completed is everything AFTER it.
-- bash and zsh track a `*` placeholder through that position; fish's
-- generator skips fallback subtrees entirely (see `fish_completion_script`).

--:: FlagInfo = { name: string, enum_values?: { [integer]: string } }
--:: LevelInfo = { key: string, statics: { [integer]: string }, has_fallback: boolean, is_leaf: boolean, flags: { [integer]: FlagInfo } }

--: (v: string | nil) -> boolean
function M.is_shell_name(v)
	return v == "bash" or v == "zsh" or v == "fish"
end

-- Sentinel `LevelInfo.key` for the root, standing in for the empty path.
-- `""` would work as a Lua table key, but this key doubles as a bash/zsh
-- associative-array subscript, and bash rejects an empty subscript outright.
local ROOT_KEY = "__root__"

--: (schema: SchemaView | nil) -> { [integer]: FlagInfo }
local function flags_of_schema(schema)
	local props = schema ~= nil and schema.properties or nil
	local out = {} --: { [integer]: FlagInfo }
	if props == nil then return out end
	local fields = sorted_keys(props)
	for i = 1, #fields do
		local fs = props[fields[i]]
		if fs ~= nil and fs.enum ~= nil then
			out[#out + 1] = { name = fields[i], enum_values = fs.enum }
		else
			out[#out + 1] = { name = fields[i] }
		end
	end
	return out
end

-- One `LevelInfo` per tree position a completion script can be at. A branch
-- position lists its next-word subcommand names; a leaf position lists its
-- input schema's top-level fields. `key` is the space-joined word sequence
-- leading there, with `*` standing in for a fallback-consumed slug value.
--: (n: NodeView, schemas: SchemaMap, path: { [integer]: string }, schema_path: { [integer]: string }) -> { [integer]: LevelInfo }
local function build_levels(n, schemas, path, schema_path)
	local levels = {} --: { [integer]: LevelInfo }
	local children = n.children or {}
	local keys = sorted_keys(children)

	local statics = {} --: { [integer]: string }
	for i = 1, #keys do
		local child = children[keys[i]]
		if child ~= nil and not is_hidden(child.meta) then
			statics[#statics + 1] = keys[i]
		end
	end
	-- `completions` is a reserved top-level command, not part of the authored
	-- tree, so walking `children` never finds it. Listed at the root so it
	-- tab-completes too; its own `<bash|zsh|fish>` argument is not modeled
	-- (this generator has no positional-argument completion).
	if #path == 0 then statics[#statics + 1] = "completions" end

	levels[#levels + 1] = {
		key = #path == 0 and ROOT_KEY or table.concat(path, " "),
		statics = statics,
		has_fallback = n.fallback ~= nil,
		is_leaf = false,
		flags = {},
	}

	for i = 1, #keys do
		local key = keys[i]
		local child = children[key]
		if child ~= nil and not is_hidden(child.meta) then
			local child_path = extend_path(path, key)
			local child_schema_path = extend_path(schema_path, key)
			if is_leaf(child) then
				levels[#levels + 1] = {
					key = table.concat(child_path, " "),
					statics = {},
					has_fallback = false,
					is_leaf = true,
					flags = flags_of_schema(input_schema_for(schemas, child_schema_path)),
				}
			else
				local nested = build_levels(child, schemas, child_path, child_schema_path)
				for j = 1, #nested do levels[#levels + 1] = nested[j] end
			end
		end
	end

	local fallback = n.fallback
	if fallback ~= nil then
		local subtree = fallback.subtree
		local fallback_path = extend_path(path, "*")
		local fallback_schema_path = extend_path(schema_path, fallback.name)
		-- A bare-leaf fallback subtree (`op()`, not `api({...})`) has no
		-- children to enumerate; recursing would push a spurious empty BRANCH
		-- level and completion at that position would propose nothing.
		if is_leaf(subtree) then
			levels[#levels + 1] = {
				key = table.concat(fallback_path, " "),
				statics = {},
				has_fallback = false,
				is_leaf = true,
				flags = flags_of_schema(input_schema_for(schemas, fallback_schema_path)),
			}
		else
			local nested = build_levels(subtree, schemas, fallback_path, fallback_schema_path)
			for j = 1, #nested do levels[#levels + 1] = nested[j] end
		end
	end

	return levels
end

--: (name: string) -> string
local function sanitize_ident(name)
	local ident = name:gsub("[^a-zA-Z0-9_]", "_")
	return ident
end

--: (s: string) -> string
local function bash_escape(s)
	local escaped = s:gsub('(["\\%$`])', "\\%1")
	return escaped
end

--: (words: { [integer]: string }) -> string
local function bash_escaped_words(words)
	local out = {} --: { [integer]: string }
	for i = 1, #words do out[i] = bash_escape(words[i]) end
	return table.concat(out, " ")
end

-- The bash completion FUNCTION BODY, shared verbatim by the bash and zsh
-- generators (zsh loads it through `bashcompinit`).
--: (root: NodeView, schemas: SchemaMap, func_name: string) -> { [integer]: string }
local function bash_function_lines(root, schemas, func_name)
	local levels = build_levels(root, schemas, {}, {})
	local lines = {} --: { [integer]: string }

	push(lines, "_" .. func_name .. "() {")
	push(lines, "  local cur word path i matched c prevword")
	push(lines, "  declare -A STATICS")
	for i = 1, #levels do
		local l = levels[i]
		if not l.is_leaf then
			push(lines, '  STATICS["' .. bash_escape(l.key) .. '"]="' .. bash_escaped_words(l.statics) .. '"')
		end
	end
	push(lines, "  declare -A HAS_FALLBACK")
	for i = 1, #levels do
		local l = levels[i]
		if not l.is_leaf and l.has_fallback then
			push(lines, '  HAS_FALLBACK["' .. bash_escape(l.key) .. '"]=1')
		end
	end
	push(lines, "  declare -A FLAGS")
	for i = 1, #levels do
		local l = levels[i]
		if l.is_leaf then
			local words = {} --: { [integer]: string }
			for j = 1, #l.flags do words[j] = "--" .. l.flags[j].name end
			push(lines, '  FLAGS["' .. bash_escape(l.key) .. '"]="' .. bash_escaped_words(words) .. '"')
		end
	end
	push(lines, "  declare -A ENUMS")
	for i = 1, #levels do
		local l = levels[i]
		if l.is_leaf then
			for j = 1, #l.flags do
				local f = l.flags[j]
				local values = f.enum_values
				if values ~= nil and #values > 0 then
					push(lines, '  ENUMS["' .. bash_escape(l.key .. "|--" .. f.name) .. '"]="'
						.. bash_escaped_words(values) .. '"')
				end
			end
		end
	end
	push(lines, "")
	push(lines, "  cur=${COMP_WORDS[COMP_CWORD]}")
	push(lines, '  path="' .. ROOT_KEY .. '"')
	push(lines, "  i=1")
	push(lines, '  while [ "$i" -lt "$COMP_CWORD" ]; do')
	push(lines, "    word=${COMP_WORDS[$i]}")
	push(lines, '    if [[ "$word" == --* ]]; then')
	push(lines, "      i=$((i+1))")
	push(lines, "      continue")
	push(lines, "    fi")
	push(lines, "    matched=0")
	push(lines, '    for c in ${STATICS["$path"]}; do')
	push(lines, '      if [ "$c" = "$word" ]; then')
	-- `path` is either the root sentinel (replaced outright — the sentinel is
	-- not a real prefix) or a real space-joined prefix (appended to), matching
	-- how `build_levels` joins non-root keys.
	push(lines, '        if [ "$path" = "' .. ROOT_KEY .. '" ]; then path="$word"; else path="$path $word"; fi')
	push(lines, "        matched=1")
	push(lines, "        break")
	push(lines, "      fi")
	push(lines, "    done")
	push(lines, '    if [ "$matched" -eq 0 ] && [ -n "${HAS_FALLBACK["$path"]}" ]; then')
	push(lines, '      if [ "$path" = "' .. ROOT_KEY .. '" ]; then path="*"; else path="$path *"; fi')
	push(lines, "    fi")
	push(lines, "    i=$((i+1))")
	push(lines, "  done")
	push(lines, "")
	push(lines, "  prevword=${COMP_WORDS[$((COMP_CWORD-1))]}")
	push(lines, '  if [[ "$prevword" == --* ]] && [ -n "${ENUMS["$path|$prevword"]}" ]; then')
	push(lines, '    COMPREPLY=($(compgen -W "${ENUMS["$path|$prevword"]}" -- "$cur"))')
	push(lines, '  elif [[ "$cur" == --* ]]; then')
	push(lines, '    COMPREPLY=($(compgen -W "${FLAGS["$path"]}" -- "$cur"))')
	push(lines, "  else")
	push(lines, '    COMPREPLY=($(compgen -W "${STATICS["$path"]} ${FLAGS["$path"]}" -- "$cur"))')
	push(lines, "  fi")
	push(lines, "}")
	return lines
end

-- A bash completion script: source it, or install it under a
-- bash-completion directory.
--: (root: NodeView, schemas: SchemaMap, program_name: string) -> string
function M.bash_completion_script(root, schemas, program_name)
	local func_name = sanitize_ident(program_name) .. "_completions"
	local lines = {} --: { [integer]: string }
	push(lines, "# bash completion for " .. program_name)
	push(lines, "# Generated by lib/api-tree/cli_projector.lua (static).")
	push(lines, "# Usage: source this file, or install it under your bash-completion directory.")
	push(lines, "")
	local body = bash_function_lines(root, schemas, func_name)
	for i = 1, #body do push(lines, body[i]) end
	push(lines, "")
	push(lines, "complete -F _" .. func_name .. " " .. program_name)
	push(lines, "")
	return table.concat(lines, "\n")
end

-- A zsh completion script. zsh's native system (`compdef`/`_arguments`) is a
-- much larger API; to keep this generator static and simple, zsh output loads
-- `bashcompinit` and reuses the bash function body verbatim — a documented
-- zsh compatibility path (`man zshcompsys`, "Backward Compatibility"), not a
-- trick specific to this generator.
--: (root: NodeView, schemas: SchemaMap, program_name: string) -> string
function M.zsh_completion_script(root, schemas, program_name)
	local func_name = sanitize_ident(program_name) .. "_completions"
	local lines = {} --: { [integer]: string }
	push(lines, "#compdef " .. program_name)
	push(lines, "# zsh completion for " .. program_name)
	push(lines, "# Generated by lib/api-tree/cli_projector.lua (static).")
	push(lines, "# Reuses the bash completion protocol via bashcompinit.")
	push(lines, "")
	push(lines, "autoload -U +X bashcompinit && bashcompinit")
	push(lines, "")
	local body = bash_function_lines(root, schemas, func_name)
	for i = 1, #body do push(lines, body[i]) end
	push(lines, "")
	push(lines, "complete -F _" .. func_name .. " " .. program_name)
	push(lines, "")
	return table.concat(lines, "\n")
end

--: (s: string) -> string
local function fish_escape(s)
	local escaped = s:gsub("'", "\\'")
	return escaped
end

-- A fish completion script.
--
-- Fish's condition primitive (`__fish_seen_subcommand_from`) tests PRESENCE
-- anywhere on the command line, not position, and there is no lightweight
-- fish equivalent of the bash version's associative-array path walk. To stay
-- simple and CORRECT rather than approximate, fish output covers only STATIC
-- subtrees: positions reachable without crossing a fallback segment.
-- Fallback-nested commands still work when typed by hand; they just do not
-- tab-complete under fish. bash and zsh have no such limitation.
--: (root: NodeView, schemas: SchemaMap, program_name: string) -> string
function M.fish_completion_script(root, schemas, program_name)
	local all_levels = build_levels(root, schemas, {}, {})
	local lines = {} --: { [integer]: string }
	push(lines, "# fish completion for " .. program_name)
	push(lines, "# Generated by lib/api-tree/cli_projector.lua (static).")
	push(lines, "# Limitation: fallback (wildcard-capture) subtrees are not completed.")
	push(lines, "")

	for i = 1, #all_levels do
		local l = all_levels[i]
		if l.key:find("*", 1, true) == nil then
			local condition = "__fish_use_subcommand"
			if l.key ~= ROOT_KEY then
				local words = {} --: { [integer]: string }
				for word in l.key:gmatch("[^ ]+") do
					words[#words + 1] = "'" .. fish_escape(word) .. "'"
				end
				condition = "__fish_seen_subcommand_from " .. table.concat(words, " ")
			end

			if not l.is_leaf then
				for j = 1, #l.statics do
					push(lines, "complete -c " .. program_name .. ' -n "' .. condition .. '"'
						.. " -a '" .. fish_escape(l.statics[j]) .. "'")
				end
			else
				for j = 1, #l.flags do
					local f = l.flags[j]
					local base = "complete -c " .. program_name .. ' -n "' .. condition .. '"'
						.. " -l '" .. fish_escape(f.name) .. "'"
					local values = f.enum_values
					if values ~= nil and #values > 0 then
						local escaped = {} --: { [integer]: string }
						for k = 1, #values do escaped[k] = fish_escape(values[k]) end
						push(lines, base .. " -a '" .. table.concat(escaped, " ") .. "'")
					else
						push(lines, base)
					end
				end
			end
		end
	end

	push(lines, "")
	return table.concat(lines, "\n")
end

--: (shell: string, root: NodeView, schemas: SchemaMap, program_name: string) -> string
function M.generate_completions(shell, root, schemas, program_name)
	if shell == "bash" then return M.bash_completion_script(root, schemas, program_name) end
	if shell == "zsh" then return M.zsh_completion_script(root, schemas, program_name) end
	if shell == "fish" then return M.fish_completion_script(root, schemas, program_name) end
	error("api_tree.cli_projector: unknown shell '" .. tostring(shell) .. "'")
end

-- ── Tree listing ─────────────────────────────────────────────────────────

--:: CommandEntry = { path: { [integer]: string }, leaf_name: string, handler: (input: unknown) -> unknown, slugs: { [integer]: string } }

-- Enumerate every reachable leaf with its CLI path — the listing full help
-- text and command suggestion read.
--: (n: NodeView, prefix: { [integer]: string }, slug_acc: { [integer]: string }) -> { [integer]: CommandEntry }
local function walk_commands(n, prefix, slug_acc)
	local out = {} --: { [integer]: CommandEntry }
	local children = n.children or {}
	local keys = sorted_keys(children)

	for i = 1, #keys do
		local key = keys[i]
		local child = children[key]
		if child ~= nil then
			if is_leaf(child) then
				local handler = child.handler
				if handler ~= nil then
					out[#out + 1] = { path = prefix, leaf_name = key, handler = handler, slugs = slug_acc }
				end
			else
				local nested = walk_commands(child, extend_path(prefix, key), slug_acc)
				for j = 1, #nested do out[#out + 1] = nested[j] end
			end
		end
	end

	local fallback = n.fallback
	if fallback ~= nil then
		-- A bare-leaf fallback subtree carries no children; recursing would
		-- silently drop it from the listing, so it is pushed directly at the
		-- CURRENT prefix under the fallback's own name.
		if is_leaf(fallback.subtree) then
			local handler = fallback.subtree.handler
			if handler ~= nil then
				out[#out + 1] = {
					path = prefix,
					leaf_name = fallback.name,
					handler = handler,
					slugs = extend_path(slug_acc, fallback.name),
				}
			end
		else
			local nested = walk_commands(fallback.subtree, prefix, extend_path(slug_acc, fallback.name))
			for j = 1, #nested do out[#out + 1] = nested[j] end
		end
	end

	return out
end

--: (n: NodeView) -> { [integer]: CommandEntry }
function M.walk_commands(n)
	return walk_commands(n, {}, {})
end

-- The closest reachable full command path to what the user typed, by edit
-- distance over the space-joined path strings — the same metric enum
-- near-misses use, and the same first-minimum-wins tie rule.
--: (root: NodeView, path_segments: { [integer]: string }) -> string | nil
local function suggest_command(root, path_segments)
	local typed = table.concat(path_segments, " ")
	local entries = M.walk_commands(root)
	local candidates = {} --: { [integer]: string }
	for i = 1, #entries do
		candidates[i] = table.concat(extend_path(entries[i].path, entries[i].leaf_name), " ")
	end
	return closest_enum_match(typed, candidates)
end

-- ── Pagination ───────────────────────────────────────────────────────────

--: (meta: PaginatedMeta | nil) -> (string, string)
local function pagination_params(meta)
	local cursor_param = (meta ~= nil and meta.inputCursorParam) or "cursor"
	local offset_param = (meta ~= nil and meta.inputOffsetParam) or "offset"
	return cursor_param, offset_param
end

--: (input: Store, page_value: PageView, cursor_param: string, offset_param: string) -> Store
local function next_page_input(input, page_value, cursor_param, offset_param)
	local out = {} --: Store
	for k, v in pairs(input) do out[k] = v end
	if page.is_offset_page(page_value) then
		local offset = page_value.offset or 0
		out[offset_param] = offset + #page_value.items
		return out
	end
	if page.is_cursor_page(page_value) and page_value.cursor ~= nil then
		out[cursor_param] = page_value.cursor
		return out
	end
	return input
end

-- The non-`--all-pages` discoverability nudge: the JSON body already carries
-- `cursor`/`offset` and `hasMore`, this is for a human at a terminal.
--: (page_value: PageView, meta: PaginatedMeta | nil, caps: Caps) -> nil
local function write_pagination_hint(page_value, meta, caps)
	if not page_value.hasMore then return end
	local cursor_param, offset_param = pagination_params(meta)
	if page.is_offset_page(page_value) then
		local offset = page_value.offset or 0
		caps.stderr_write("# more results available — pass --" .. offset_param .. " "
			.. number_text(offset + #page_value.items) .. " (or --all-pages) to continue\n")
	elseif page.is_cursor_page(page_value) and page_value.cursor ~= nil then
		caps.stderr_write("# more results available — pass --" .. cursor_param .. " "
			.. tostring(page_value.cursor) .. " (or --all-pages) to continue\n")
	end
end

-- ── run_cli ──────────────────────────────────────────────────────────────

-- Unwrap a `{ kind = "err" }` Result into a `CliError` rejection, or a
-- `{ kind = "ok" }` one into its value. Anything else passes through.
--: (value: unknown, detect_result: boolean, error_encoder: ErrorEncoder | nil, caps: Caps) -> unknown
local function unwrap_result(value, detect_result, error_encoder, caps)
	if not detect_result then return value end
	if not is_result_value(value) then return value end
	if value.kind == "err" then
		local encoded = nil --: ErrorResponse | nil
		if error_encoder ~= nil then encoded = error_encoder(value.error) end
		local message = "Error: " .. error_text(value.error)
		local exit_code = 1
		if encoded ~= nil then
			message = encoded.message or message
			exit_code = encoded.exit_code or exit_code
		end
		caps.stderr_write(message .. "\n")
		error(cli_error(message, exit_code))
	end
	return value.value
end

-- Everything the `--all-pages` walk needs, in ONE argument. An `async.async`
-- wrapper packs its arguments with `{ ... }` and replays them with `unpack`,
-- and a nil in the middle of that list truncates it — `paginated_meta` is
-- legitimately absent most of the time, which would silently drop every
-- argument after it. A single table has no such hole.
--:: PageWalk = { call_handler: HandlerFn, stores: Stores, detect_result: boolean, error_encoder: ErrorEncoder | nil, paginated_meta: PaginatedMeta | nil, caps: Caps }

-- One `--all-pages` continuation fetch, with the same Result unwrapping the
-- first call already applied: a later page can be an `err` exactly like the
-- first.
local fetch_next_page = async.async(function(walk, next_input)
	local out = settle(walk.call_handler(next_input, walk.stores))
	out = unwrap_result(out, walk.detect_result, walk.error_encoder, walk.caps)
	if not is_page_value(out) then
		error(cli_error("--all-pages: a subsequent page fetch did not return a page-shaped result", 1))
	end
	return out
end)

-- `--all-pages`: walk every page from `first` onward, writing each item as a
-- JSONL line as soon as its page arrives (push-as-you-go). Distinct from
-- draining a stream: this is a REQUEST/RESPONSE sequence — one handler call
-- per page — not one already-open stream.
local stream_all_pages = async.async(function(walk, first, input)
	local cursor_param, offset_param = pagination_params(walk.paginated_meta)
	local page_value = first --[[: PageView]]
	local current_input = input
	while true do
		for i = 1, #page_value.items do
			walk.caps.stdout_write(json_line(page_value.items[i]))
		end
		if not page_value.hasMore then return nil end
		current_input = next_page_input(current_input, page_value, cursor_param, offset_param)
		local fetched = async.await(fetch_next_page(walk, current_input))
		page_value = fetched --[[: PageView]]
	end
end)

-- Render one streamed emission. A `{ kind = "progress" }` effect goes to
-- stderr as a human-readable line; everything else (a `{ kind = "chunk" }`
-- payload or an untagged emission — `stream.drive` unwraps the former) is a
-- JSONL line on stdout.
--: (caps: Caps) -> { progress: ((effect: unknown) -> nil) | nil, chunk: (value: unknown) -> nil }
local function stream_arms(caps)
	--: (effect: unknown) -> nil
	local function on_progress(effect)
		if not is_progress_effect(effect) then return nil end
		local pct = number_text(effect.progress) .. "%"
		local total = effect.total
		if total ~= nil and total ~= 0 then
			pct = number_text(math.floor((effect.progress / total) * 100 + 0.5)) .. "%"
		end
		local text = effect.message
		local message = ""
		if text ~= nil then message = " " .. text end
		caps.stderr_write("[progress] " .. pct .. message .. "\n")
		return nil
	end

	--: (value: unknown) -> nil
	local function on_chunk(value)
		caps.stdout_write(json_line(value))
		return nil
	end

	return { progress = on_progress, chunk = on_chunk }
end

-- Compose `middleware` around `base`, first entry OUTERMOST — `middleware[1]`
-- wraps `middleware[2]` wraps ... wraps `base`. An empty list returns `base`
-- unchanged (identity, no wrapping overhead).
--: (middleware: { [integer]: Middleware }, base: HandlerFn) -> HandlerFn
local function compose_middleware(middleware, base)
	local wrapped = base
	for i = #middleware, 1, -1 do
		wrapped = middleware[i](wrapped)
	end
	return wrapped
end

-- Split argv into subcommand-path segments and flag tokens: leading non-flag
-- tokens are the path, everything from the first `-`-prefixed token on is
-- flag argv.
--: (argv: { [integer]: string }) -> ({ [integer]: string }, { [integer]: string })
local function split_argv(argv)
	local path_segments = {} --: { [integer]: string }
	local flag_argv = {} --: { [integer]: string }
	local seen_flag = false
	for i = 1, #argv do
		local arg = argv[i]
		if seen_flag or arg:sub(1, 1) == "-" then
			seen_flag = true
			flag_argv[#flag_argv + 1] = arg
		else
			path_segments[#path_segments + 1] = arg
		end
	end
	return path_segments, flag_argv
end

local run_cli_async = async.async(function(root, argv, caps, opts)
	local schemas = opts.schemas or {} --[[: SchemaMap]]
	local program_name = opts.program_name or "cli"

	local path_segments, flag_argv = split_argv(argv)

	-- `completions <shell>` — a reserved top-level command, not part of the
	-- authored tree, printing a static script derived from the tree's shape.
	if path_segments[1] == "completions" then
		local shell = path_segments[2]
		if not M.is_shell_name(shell) then
			caps.stderr_write("Usage: " .. program_name .. " completions <bash|zsh|fish>\n")
			error(cli_error("Unknown or missing shell for completions", 1))
		end
		caps.stdout_write(M.generate_completions(shell --[[: string]], root, schemas, program_name))
		return nil
	end

	local parsed = parse_flags(flag_argv)

	-- `--version` is a program-level query, so it takes priority over
	-- subcommand resolution (as `--help` does).
	if parsed.version then
		local version = opts.version
		if version == nil then
			caps.stderr_write("No version configured for this program.\n")
			error(cli_error("No version configured", 1))
		end
		caps.stdout_write(version .. "\n")
		return nil
	end

	if #path_segments == 0 then
		if parsed.help then
			caps.stdout_write(build_help(root, {}, program_name))
			return nil
		end
		caps.stderr_write("Usage: " .. program_name .. " <subcommand> [options]\nRun with --help for usage.\n")
		error(cli_error("No subcommand provided", 1))
	end

	if parsed.help then
		local help_target = resolve_leaf(root, path_segments, 1, {}, {})
		if help_target ~= nil then
			caps.stdout_write(build_leaf_help(help_target, path_segments, program_name, schemas))
			return nil
		end
		-- Not a leaf: walk down to the deepest branch child that matches and
		-- print that group's help.
		local cursor = root
		local depth = 0
		for i = 1, #path_segments do
			local child = (cursor.children or {})[path_segments[i]]
			if child ~= nil and not is_leaf(child) then
				cursor = child
				depth = depth + 1
			else
				break
			end
		end
		local shown_path = {} --: { [integer]: string }
		for i = 1, depth do shown_path[i] = path_segments[i] end
		caps.stdout_write(build_help(cursor, shown_path, program_name))
		return nil
	end

	local target = resolve_leaf(root, path_segments, 1, {}, {})
	if target == nil then
		local typed = table.concat(path_segments, " ")
		local suggestion = suggest_command(root, path_segments)
		local hint = suggestion ~= nil and (' Did you mean "' .. suggestion .. '"?') or ""
		local message = 'Unknown command: "' .. typed .. '".' .. hint
		caps.stderr_write(message .. "\nRun with --help for usage.\n")
		error(cli_error(message, 1))
	end

	local tags = tags_of(target.leaf_meta)

	if tags.destructive == true and not parsed.yes then
		local confirmed = settle(caps.confirm("This operation is destructive and irreversible. Proceed?"))
		if confirmed ~= true then
			caps.stderr_write("Aborted.\n")
			error(cli_error("Aborted by user", 1))
		end
	end

	-- Build the input bag (flags + slugs, provenance-blind), coerce it against
	-- the leaf's input schema, fill schema defaults, then check required
	-- fields — all before the handler is ever called.
	local cli_meta = M.read_cli_meta(target.leaf_meta)
	local source_map = cli_meta.sourceMap or {}
	local input_schema = input_schema_for(schemas, target.schema_path)
	local raw_input, stores = build_input(parsed.flags, target.slugs, source_map, caps.env)

	local coerced, coerce_err = M.coerce_input(raw_input, input_schema)
	if coerced == nil then
		local message = coerce_err or "invalid input"
		caps.stderr_write("Error: " .. message .. "\n")
		error(cli_error(message, 1))
	end
	local input = M.apply_defaults(coerced, input_schema)
	local required_ok, required_err = M.validate_required(input, input_schema)
	if not required_ok then
		local message = required_err or "missing required fields"
		caps.stderr_write("Error: " .. message .. "\n")
		error(cli_error(message, 1))
	end

	-- Bridge the plain handler `(input) -> result` into the middleware base
	-- case `(input, stores) -> result`: the handler never sees `stores`,
	-- structurally, not by convention.
	local handler = target.handler
	--: HandlerFn
	local function base(handler_input, _stores)
		return handler(handler_input)
	end
	local middleware = opts.middleware or {}
	local call_handler = #middleware == 0 and base or compose_middleware(middleware, base)

	-- A thrown error is never surfaced verbatim: a handler's message can carry
	-- internals (file paths, driver SQL, ...) not meant for a CLI consumer. A
	-- handler that WANTS to report a specific user-facing failure returns an
	-- `err(...)` Result, which IS surfaced verbatim — that is the intentional,
	-- opt-in error channel.
	local ok, res = pcall(function()
		return settle(call_handler(input, stores))
	end)
	if not ok then
		if M.is_cli_error(res) then error(res) end
		caps.stderr_write("Error: internal error\n")
		error(cli_error("internal error", 1))
	end

	local detect_streaming = true
	local detect_result = true
	local detection = opts.detection
	if detection ~= nil then
		if detection.streaming ~= nil then detect_streaming = detection.streaming end
		if detection.result ~= nil then detect_result = detection.result end
	end

	-- A stream result is drained incrementally — one JSONL line per emission,
	-- as it arrives — instead of going through Result unwrapping and the
	-- buffered output paths. Checked first: neither a Result nor a plain value
	-- is a stream, so there is no ambiguity. Not gated by `tags.streaming` or
	-- `--jsonl`, which only affect ARRAY results: a handler returning a stream
	-- IS the signal to stream, on every projector.
	-- TYPECHECKER WORKAROUND: the sniff runs on `streamed`, a fresh binding of
	-- the handler's result, rather than on `res` directly. `res` is reassigned
	-- further down (Result unwrapping), and a predicate narrowing does not
	-- stick to a local that is reassigned anywhere later in the function, so
	-- `is_stream_value(res)` leaves `res` as `unknown` at the call below. Same
	-- family as TODO.md's "a local REASSIGNED inside a conditional branch is
	-- typed nil at a later method call". Collapse the extra local once
	-- narrowing survives a later reassignment.
	local streamed = res
	if detect_streaming and is_stream_value(streamed) then
		local terminal = async.await(stream.drive(streamed, stream_arms(caps)))
		caps.stdout_write(json_line(terminal))
		return nil
	end

	res = unwrap_result(res, detect_result, opts.error_encoder, caps)

	-- A page-shaped result is detected the same way — a runtime shape check on
	-- the actual value. `--all-pages` re-invokes the handler in-process with
	-- the next cursor/offset merged into the input; without it, the current
	-- page prints normally and a hint goes to stderr.
	if is_page_value(res) then
		local paginated_meta = cli_meta.paginated
		if parsed.all_pages then
			local walk = {
				call_handler = call_handler,
				stores = stores,
				detect_result = detect_result,
				error_encoder = opts.error_encoder,
				paginated_meta = paginated_meta,
				caps = caps,
			} --: PageWalk
			async.await(stream_all_pages(walk, res, input))
			return nil
		end
		write_pagination_hint(res, paginated_meta, caps)
	end

	if tags.streaming == true or parsed.jsonl then
		-- One JSON line per item. A page-shaped result streams its `items`; the
		-- pagination metadata is not itself a result item and is dropped from
		-- this mode (the hint above already surfaced it).
		if is_page_value(res) then
			for i = 1, #res.items do
				caps.stdout_write(json_line(res.items[i]))
			end
		elseif type(res) == "table" and api_tree.is_array(res --[[: { [unknown]: unknown }]]) then
			local list = res --[[: { [integer]: unknown }]]
			for i = 1, #list do
				caps.stdout_write(json_line(list[i]))
			end
		else
			caps.stdout_write(json_line(res))
		end
	else
		if res == nil then
			caps.stdout_write("null\n")
		else
			caps.stdout_write(encode_json(res, 2) .. "\n")
		end
	end

	return nil
end)

-- Dispatch a Node tree from argv.
--
-- `argv` is the arguments AFTER the program name. Leading non-flag tokens are
-- the subcommand path; the remaining `--flags` become the handler's input.
--
-- Returns a lib/async promise resolving to nil on success. A CLI failure —
-- unknown command, invalid input, a handler's `err` Result, an aborted
-- confirmation — REJECTS it with `{ kind = "cli_error", message, exit_code }`
-- (see `is_cli_error`); the caller decides how to exit, which is what keeps a
-- test harness alive. A missing capability is a programmer error and raises
-- immediately instead.
--: (root: NodeView, argv: { [integer]: string }, caps: Caps, opts: Opts | nil) -> unknown
function M.run_cli(root, argv, caps, opts)
	if type(caps) ~= "table" then
		error("api_tree.cli_projector: run_cli requires a caps table (stdout_write, stderr_write, confirm, env)")
	end
	if type(caps.stdout_write) ~= "function" then
		error("api_tree.cli_projector: run_cli requires the caps.stdout_write cap")
	end
	if type(caps.stderr_write) ~= "function" then
		error("api_tree.cli_projector: run_cli requires the caps.stderr_write cap")
	end
	if type(caps.confirm) ~= "function" then
		error("api_tree.cli_projector: run_cli requires the caps.confirm cap")
	end
	if type(caps.env) ~= "table" then
		error("api_tree.cli_projector: run_cli requires the caps.env cap")
	end
	return run_cli_async(root, argv, caps, opts or {})
end

return M
