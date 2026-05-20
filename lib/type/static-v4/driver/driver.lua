-- K1 — v4 driver. Glues parser → arena→POJO decoder → walker → cache.
--
-- See docs/typechecker-v4-driver-design.md for the architectural framing.
-- This module turns a Lua source file into a (exports, aliases,
-- diagnostics, source_hash, deps) tuple by running the legacy parser
-- (injected as a cap), decoding the arena AST into the POJO shape the
-- walker consumes (driver/decoder.lua, K2), invoking the walker
-- (walker/walker.lua, sub-phases A–J) on each top-level statement, and
-- storing the resulting export type into the content-addressed `.cri`
-- cache on a clean walk (no error-severity diagnostics).
--
-- Public surface
-- ──────────────
--   M.drive(source_path, opts) -> (result, errmsg | nil)
--
-- `result` on success is the record documented in the design doc §1:
--
--   { exports     = <V4Type | nil>,
--     aliases     = { [string]: V4Type },
--     diagnostics = Diagnostic[],
--     deps        = { [path]: source_hash },
--     source_hash = string,
--     -- K1-prompt's expected fields (subset of design):
--     type        = exports,       -- alias matching the K1 prompt
--   }
--
-- `errmsg` is non-nil ONLY for *driver-itself* failures (missing opts,
-- missing caps, parse exception, unreadable source). Walker-level
-- diagnostics including type errors land in `result.diagnostics` and the
-- driver still returns `(result, nil)` — error-vs-pass at the file level
-- is `#result.diagnostics_errors > 0`. This matches the design doc §1's
-- distinction.
--
-- Chunk-handler decision
-- ──────────────────────
-- The walker has no NODE_CHUNK handler — walker_test.lua uses NODE_CHUNK
-- as its canonical "unsupported-tag stub" repro, so REGISTERING a chunk
-- handler on the global walker registry would silently break that test.
-- We own chunk semantics in the driver: iterate `chunk.body` and
-- `walk_synth` each statement, threading the env. This also matches Lua
-- evaluation order — a chunk is sequential statements — and lets us
-- collect diagnostics per-statement (continue after a per-statement
-- error) instead of short-circuiting the whole file on the first failure.
--
-- Export accumulator: a chunk's `return e` flows through synth_return,
-- which requires `env.return_ty` to be non-nil. The driver pre-sets it
-- to a fresh `V.var("module_export")` before walking. Synth_return
-- constrains `ty <: module_export`, so on a clean walk the var's bounds
-- describe the actual export type. If no return statement is reached,
-- the export is `V.prim("nil")` (Lua semantics).
--
-- Recursive-walk wiring
-- ─────────────────────
-- `require_resolve.lua` previously rejected loudly on cache miss. K1
-- threads `env.drive_recursive` so a miss re-enters the driver:
--
--   env.drive_recursive(resolved_path, requiring_env) -> (exports,
--                                                         aliases,
--                                                         source_hash,
--                                                         errmsg)
--
-- The driver implements this as a recursive `drive` call with:
--   - same io_caps / cache_dir / stdlib / parse cap
--   - require_chain inherited from the requiring env (push_require is
--     done by the require_resolve handler before calling us so cycle
--     detection works through the existing E.lookup_require machinery)
--   - a FRESH solver (cross-file constraints do not propagate through
--     the cache; per design §6).
--
-- On success the recursive driver call performs its own cache_store, so
-- the outer caller's require resolves as if it had been a cache hit
-- (require_resolve loops back through cache_lookup after we return).
--
-- Caps discipline
-- ───────────────
-- Per CLAUDE.md "Caps-first, everywhere": opts.io_caps and opts.parse
-- are NEVER taken from globals; missing caps error at the entry point,
-- never silently default.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local V        = require("lib.type.static-v4")
local E        = require("lib.type.static-v4.walker.env")
local W        = require("lib.type.static-v4.walker.walker")
local D        = require("lib.type.static-v4.walker.diag")
local decoder  = require("lib.type.static-v4.driver.decoder")
local defs     = require("lib.type.static.defs")
local sha256_m = require("lib.hash.sha256")
local require_resolve = require("lib.type.static-v4.walker.require_resolve")

local M = {}

-- ── Opts validation ───────────────────────────────────────────────────────

-- Annotation-free internal helpers — same rationale as walker/effects.lua
-- and walker/ffi_cdef.lua (cross-module --:: alias resolution limit on
-- V4Type / V4IoCaps in this scope). The opts record's shape is
-- documented inline in this file's header and validated at runtime by
-- require_opts; downstream uses thread the opts table opaquely and cast
-- at concrete-use sites.

local function require_opts(opts)
	if opts == nil then return "driver: opts is required" end
	if opts.io_caps   == nil then return "driver: opts.io_caps is required"   end
	if opts.cache_dir == nil then return "driver: opts.cache_dir is required" end
	if opts.parse     == nil then return "driver: opts.parse cap is required" end
	if opts.stdlib    == nil then return "driver: opts.stdlib bindings record is required" end
	local c = opts.io_caps
	if c.read_file   == nil then return "driver: opts.io_caps.read_file is required"   end
	if c.write_file  == nil then return "driver: opts.io_caps.write_file is required"  end
	if c.mkdir       == nil then return "driver: opts.io_caps.mkdir is required"       end
	if c.file_exists == nil then return "driver: opts.io_caps.file_exists is required" end
	return nil
end

-- ── Stdlib injection ──────────────────────────────────────────────────────
--
-- Walks the StdlibBindings record (per stdlib_types_v4.lua) and seeds the
-- env's bindings / aliases scopes. Parametric aliases are exposed on
-- env.parametric_aliases for the future annotation-bridge consumer
-- (walker-side hook is NOT in K1 scope, but the env field carries the
-- table so the bridge can land without re-plumbing).

local function inject_stdlib(env, stdlib)
	-- Annotation-free; stdlib's V4Type field values aren't shapeable in
	-- this module's annotation scope.
	if stdlib.bindings ~= nil then
		for name, ty in pairs(stdlib.bindings) do
			env = E.bind(env, name, ty)
		end
	end
	if stdlib.aliases ~= nil then
		for name, ty in pairs(stdlib.aliases) do
			env = E.bind_alias(env, name, ty)
		end
	end
	env.parametric_aliases = stdlib.parametric_aliases or {}
	-- Per-primitive method-dispatch registry (legacy `ctx.prim_index`).
	-- Keyed by primitive base tag; method calls on prim/literal receivers
	-- look up here, not via `env.bindings[<name>]`. User-shadowing the
	-- `string` global must not break `("x"):upper()` dispatch.
	env = E.with_prim_index(env, stdlib.prim_index or {})
	return env
end

M.inject_stdlib = inject_stdlib

-- ── Chunk walk ────────────────────────────────────────────────────────────
--
-- Iterate top-level statements. Each statement is walked via walk_synth.
-- A per-statement err is appended to diagnostics and the walk continues
-- (Lua chunks don't short-circuit — collecting all type errors in one
-- pass is the useful behaviour).
--
-- Returns (export_ty, env_out, diagnostics, returned_explicit).
-- `returned_explicit` is whether a NODE_RETURN_STMT was reached; when
-- false the export is V.prim("nil").

local function walk_chunk(chunk_node, env, solver)
	local diagnostics = {}
	local function record(d)
		if d == nil then return end
		-- Walker handlers sometimes return a raw error string instead of a
		-- diagnostic record (legacy paths in synth_local for missing-RHS-
		-- synth errors). Lift to a diagnostic so downstream consumers see
		-- a uniform shape.
		if not D.is_diagnostic(d) then
			d = D.emit(env, D.E_INTERNAL, tostring(d))
		end
		diagnostics[#diagnostics + 1] = d
	end

	local export_var = V.var("module_export")
	env = E.with_source(env, {
		file = chunk_node.filename or env.source.file,
		line = chunk_node.line or 1,
		col  = chunk_node.col  or 1,
	})
	-- Pre-install return slot so chunk-level `return e` is accepted.
	env.return_ty = export_var

	local returned_explicit = false
	local body = chunk_node.body or {}
	for _, stmt in ipairs(body) do
		if stmt.tag == defs.NODE_RETURN_STMT then
			returned_explicit = true
		end
		local _ty, env2, err = W.walk_synth(stmt, env, solver)
		env = env2 or env
		if err ~= nil then record(err) end
	end

	local export_ty
	if returned_explicit then
		export_ty = export_var
	else
		export_ty = V.prim("nil")
	end
	return export_ty, env, diagnostics, returned_explicit
end

-- ── Recursive walk plumbing (cache-miss path) ─────────────────────────────
--
-- `require_resolve.lua` consults `env.drive_recursive` on a cache miss
-- (the read side of the recursive walk contract; see the patched
-- resolve_via_cache below). The driver installs this cap before each
-- walk, closing over the driver's own opts so the recursive call can
-- reuse the same parser cap, caps, cache_dir, and stdlib.

-- Forward declaration so `make_drive_recursive` can refer to M.drive.
local drive

local function make_drive_recursive(opts)
	return function(source_path, requiring_env)
		local sub_opts = {
			io_caps       = opts.io_caps,
			cache_dir     = opts.cache_dir,
			stdlib        = opts.stdlib,
			parse         = opts.parse,
			require_chain = requiring_env.require_chain,
			on_diagnostic = opts.on_diagnostic,
		}
		local result, errmsg = drive(source_path, sub_opts)
		if result == nil then
			return nil, nil, nil, errmsg
		end
		return result.exports, result.aliases, result.source_hash, nil
	end
end

-- ── Main entry ────────────────────────────────────────────────────────────

drive = function(source_path, opts)
	local opt_err = require_opts(opts)
	if opt_err ~= nil then return nil, opt_err end

	-- 1. Read source.
	local source, rerr = opts.io_caps.read_file(source_path)
	if source == nil then
		return nil, "driver: cannot read " .. source_path .. ": " .. tostring(rerr)
	end

	-- 2. Hash source for cache lookup / store.
	local source_hash = sha256_m.sha256(source)

	-- 3. Parse via injected cap. The legacy parser raises on syntax errors;
	-- we trap with pcall so a parse failure becomes a clean diagnostic
	-- rather than an exception escaping the driver.
	local ok, parse_result_or_err = pcall(opts.parse, source, source_path)
	if not ok then
		-- Synthesise a diagnostic at the source's start; the parser's
		-- error message already carries file:line:col, but our pos field
		-- needs structured form for --summary consumers.
		local env_for_diag = E.with_source(E.new(),
			{ file = source_path, line = 1, col = 1 })
		local d = D.emit(env_for_diag, D.E_INTERNAL,
			"parse failed: " .. tostring(parse_result_or_err))
		return {
			exports     = nil,
			aliases     = {},
			diagnostics = { d },
			deps        = {},
			source_hash = source_hash,
			type        = nil,
		}, nil
	end
	local parse_result = parse_result_or_err

	-- 4. Decode arena → POJO. The decoder is annotation-free (returns
	-- `unknown`); cast to the chunk POJO shape walk_chunk reads.
	local chunk_node = decoder.decode(parse_result) --[[: { tag: integer, line: integer, col: integer, filename: string | nil, body: unknown }]]

	-- 5. Build initial env: stdlib bindings + caps + cache_dir +
	-- require_chain + drive_recursive cap. We extract stdlib into a
	-- local so later reads (`stdlib.aliases` in the result-packing
	-- block) do not narrow opts.stdlib's inferred shape backwards into
	-- this site.
	local stdlib = opts.stdlib --[[: { bindings: unknown, aliases: unknown, parametric_aliases: unknown, prim_index: unknown, ... }]]
	local env = E.new()
	env = inject_stdlib(env, stdlib)
	env = E.with_io_caps(env, opts.io_caps)
	env = E.with_cache_dir(env, opts.cache_dir)
	env = E.with_source(env, { file = source_path, line = 1, col = 1 })
	if opts.require_chain ~= nil then
		-- Carry the inherited chain so cycle detection works across
		-- recursive driver calls. Clone to avoid mutating the caller's
		-- table.
		local chain = {}
		for k, v in pairs(opts.require_chain) do chain[k] = v end
		env.require_chain = chain
	end
	-- Deps accumulator. require_resolve.lua reads this via its
	-- _current_deps_sink module-state, set just below. The driver owns
	-- this table for the duration of one walk; recursive driver calls
	-- save and restore the parent's hooks so the deps table is the
	-- accumulator for the CURRENT walk, not the parent's.
	local deps = {}

	-- 6. Install the require_resolve module-level hooks. WalkerEnv's
	-- clone() does not carry runtime-injected fields, so a per-walk
	-- module-state slot is the contract between K1's driver and sub-
	-- phase I's require resolver. Save any existing hooks (set by an
	-- enclosing driver) and restore them after this walk completes.
	local saved_dr   = require_resolve._current_drive_recursive()
	local saved_sink = require_resolve._current_deps_sink()
	require_resolve._set_driver_hooks(make_drive_recursive(opts), deps)

	-- 7. Walk the chunk.
	local solver = V.new_solver()
	local export_ty, env_out, diagnostics, _ret =
		walk_chunk(chunk_node, env, solver)

	-- Restore the parent driver's hooks (if any).
	require_resolve._set_driver_hooks(saved_dr, saved_sink)

	-- 8. Stream diagnostics to opts.on_diagnostic if installed.
	if opts.on_diagnostic ~= nil then
		for _, d in ipairs(diagnostics) do opts.on_diagnostic(d) end
	end

	-- Collect aliases from env_out for the result + cache packing.
	local aliases_out = {}
	for k, v in pairs(env_out.aliases or {}) do
		-- Skip stdlib-injected aliases — those are re-injected on every
		-- driver invocation from the stdlib record, not persisted in the
		-- cache. The file's own --:: declarations land in aliases_out
		-- when the annotation-parser bridge wires them; until then the
		-- map is effectively the stdlib pass-through, which we filter.
		if stdlib.aliases == nil or stdlib.aliases[k] == nil then
			aliases_out[k] = v
		end
	end

	-- 9. Cache store on clean walk. "Clean" = no error-severity diagnostics.
	local has_error = false
	for _, d in ipairs(diagnostics) do
		if d.severity == "error" then has_error = true; break end
	end
	if not has_error and export_ty ~= nil then
		local artifact = require_resolve.pack_artifact(export_ty, aliases_out)
		local store_ok, store_err = pcall(
			V.cache_store,
			opts.io_caps, opts.cache_dir, source_hash, artifact, deps)
		if not store_ok then
			-- A cache-store failure is a driver-itself failure, not a
			-- file-level diagnostic — promote it to errmsg so the caller
			-- sees the I/O problem rather than a phantom typecheck pass.
			return nil, "driver: cache_store failed: " .. tostring(store_err)
		end
	end

	return {
		exports     = export_ty,
		aliases     = aliases_out,
		diagnostics = diagnostics,
		deps        = deps,
		source_hash = source_hash,
		type        = export_ty,
	}, nil
end

M.drive = drive

return M
