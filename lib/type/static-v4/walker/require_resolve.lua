-- Walker sub-phase I — cross-file resolution via `require` and the .cri
-- content-addressed cache.
--
-- Per docs/typechecker-ast-walker-design.md §11. This module recognises the
-- call-site shape `require("modname")` and resolves it through the v4 cache:
--
--   1. Module-name → path resolution. `lib.foo.bar` resolves to
--      `lib/foo/bar.lua` if that file exists, otherwise
--      `lib/foo/bar/init.lua`. This mirrors Lua's standard `package.path`
--      with crescent's `?/init.lua` convention.
--   2. Content hashing via `lib.hash.sha256` (the cache's `content_hash`
--      primitive operates on the cache wire format; the import-side hash
--      is over the imported file's raw source bytes).
--   3. Cache lookup via `V.cache_lookup(io_caps, cache_dir, source_hash)`.
--      On hit: deserialise the artifact and bind both the exports type and
--      the imported file's `--::` aliases into the caller's env.
--      On miss: REJECT LOUDLY. Sub-phase I does not include the recursive
--      walk — that requires an AST/source-pipeline integration which has
--      no v4 bridge yet (sub-phase J's responsibility). The deferral is
--      honest; the message names the limitation rather than masquerading
--      as a different kind of failure.
--   4. Cycle detection via `env.require_chain`. If `require("A")` is in
--      progress on the chain when an inner `require("A")` fires, the
--      placeholder var on the chain entry is returned (Lua runtime
--      semantics: the inner require sees the in-progress module).
--   5. I/O capability injection via `env.io_caps`. Per CLAUDE.md
--      "Caps-first, everywhere": the caps are NEVER taken from globals,
--      NEVER defaulted. Absent caps on a require call is an error.
--
-- ── Artifact encoding (export type + aliases) ─────────────────────────────
--
-- v4 cache.lua serialises a single V4Type. A file's import surface is two
-- things: the runtime exports type AND the file-scope `--::` aliases the
-- file declared. Sub-phase I packs both into one cacheable V4Type using a
-- closed-record wrapper:
--
--   V.rec({
--     exports = <export V4Type>,
--     aliases = V.rec({ Foo = <T>, ... }, false, nil),
--   }, false, nil)
--
-- The wrapper is opaque to cache.lua (one V4Type in, one V4Type out) and
-- the walker unpacks it on the read side. This sidesteps any extension to
-- the cache wire format — the artifact-vs-bare-type distinction lives in
-- the walker, where the import-surface concept exists. Files written to
-- the cache from outside the walker must use the same wrapper shape; the
-- pack / unpack helpers below are the contract.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Intentionally annotation-free at function signatures; same rationale as
-- other walker handlers (cross-module `--::` alias resolution limitation
-- documented in walker/README.md).

local V          = require("lib.type.static-v4")
local E          = require("lib.type.static-v4.walker.env")
local D          = require("lib.type.static-v4.walker.diag")
local O          = require("lib.type.static-v4.walker.origin")
local defs       = require("lib.type.static.defs")
local sha256_mod = require("lib.hash.sha256")

local _types = require("lib.type.static-v4.types")
local _ = _types

local M = {}

-- ── Module-name → path resolution ─────────────────────────────────────────
--
-- `lib.foo.bar` → first try `lib/foo/bar.lua`, then `lib/foo/bar/init.lua`.
-- The second form is crescent's per-directory entry-point convention
-- (every package is a directory with an `init.lua`).
--
-- Returns (resolved_path, nil) on success or (nil, errmsg) on failure.
local function resolve_module_path(caps, mod_name)
	local rel = mod_name:gsub("%.", "/")
	local p1  = rel .. ".lua"
	if caps.file_exists(p1) then return p1, nil end
	local p2  = rel .. "/init.lua"
	if caps.file_exists(p2) then return p2, nil end
	return nil,
		"require: module " .. mod_name .. " not found " ..
		"(tried " .. p1 .. " and " .. p2 .. ")"
end

M.resolve_module_path = resolve_module_path

-- ── Artifact pack / unpack ────────────────────────────────────────────────
--
-- Pack an (exports, aliases) pair into a single V4Type suitable for
-- cache.lua's serialise / deserialise pipeline. The wrapper is a closed
-- record with two reserved fields.

-- Pack an artifact. `aliases` may be nil (treated as empty).
-- The double V.rec call funnels through unknown-typed maps because the
-- typechecker's structural-record inference does not see `V.rec`'s return
-- as a discriminant that closes the union (see effects.lua for the same
-- "build an open table of V4Types then wrap" pattern). The unknown cast
-- on the alias-map matches the rest of the walker's annotation-free
-- handler convention.
function M.pack_artifact(exports, aliases)
	-- Build the alias record's field map. The typechecker infers the table
	-- type from the FIRST assignment, so we eagerly write a sample V4Type
	-- (which we then delete) — this matches effects.lua's pcall_return_type
	-- construction pattern and keeps the inferred map type `{ [string]:
	-- V4Type }` rather than `{ [nil]: _ }`.
	local alias_map = {}
	alias_map[""] = exports
	alias_map[""] = nil
	if aliases ~= nil then
		for k, v in pairs(aliases) do alias_map[k] = v end
	end
	local alias_rec = V.rec(alias_map, false, nil)
	-- Same pattern for the outer record: seed `exports` first so the field
	-- map's value type is V4Type.
	local fields = {}
	fields["exports"] = exports
	fields["aliases"] = alias_rec
	return V.rec(fields, false, nil)
end

-- Unpack an artifact V4Type. Returns (exports, aliases, nil) on success
-- or (nil, nil, errmsg) on a malformed wrapper.
function M.unpack_artifact(artifact)
	if artifact.tag ~= "rec" then
		return nil, nil, "require: cached artifact is not a record (got " ..
			tostring(artifact.tag) .. ")"
	end
	local exports = artifact.fields.exports
	if exports == nil then
		return nil, nil, "require: cached artifact missing `exports` field"
	end
	local alias_rec = artifact.fields.aliases
	if alias_rec == nil then
		return nil, nil, "require: cached artifact missing `aliases` field"
	end
	if alias_rec.tag ~= "rec" then
		return nil, nil, "require: cached artifact `aliases` is not a record"
	end
	local aliases = {}
	for k, v in pairs(alias_rec.fields) do aliases[k] = v end
	return exports, aliases, nil
end

-- ── Call-shape detection ──────────────────────────────────────────────────
--
-- A bare-identifier callee named `require` with exactly one string-literal
-- argument. Other shapes (`pkg.require(...)`, dynamic strings) fall through
-- to the captured handler.
local function is_require_call(node)
	local callee = node.callee
	if callee == nil then return false end
	if callee.tag ~= defs.NODE_IDENTIFIER then return false end
	if callee.name ~= "require" then return false end
	local args = node.args or {}
	if #args ~= 1 then return false end
	local arg = args[1]
	if arg.tag ~= defs.NODE_LITERAL then return false end
	if arg.lit_kind ~= defs.LIT_STRING then return false end
	return true
end

M.is_require_call = is_require_call

-- ── Cache-hit resolution ──────────────────────────────────────────────────
--
-- Internal helper. Given an env carrying io_caps + cache_dir, hashes the
-- source file's bytes, performs a cache lookup, deserialises on hit, and
-- returns (exports, aliases, nil). On miss, returns
-- (nil, nil, "<recursive-walk-not-in-subphase-I message>") — sub-phase J
-- will wire the recursive walk.
local function resolve_via_cache(caps, cache_dir, source_path)
	local source, rerr = caps.read_file(source_path)
	if source == nil then
		return nil, nil, nil,
			"require: cannot read " .. source_path .. ": " .. tostring(rerr)
	end
	-- Hash the source bytes. The same SHA-256 primitive cache.lua uses for
	-- its content-addressed naming; same digest format (lowercase hex).
	local source_hash = sha256_mod.sha256(source)
	local bytes = V.cache_lookup(caps, cache_dir, source_hash)
	if bytes == nil then
		return nil, nil, source_hash,
			"require: cache miss for " .. source_path ..
			" (recursive walk not in sub-phase I; populate cache out-of-band " ..
			"or wait for sub-phase J)"
	end
	local artifact, derr = V.deserialize(bytes)
	if artifact == nil then
		return nil, nil, source_hash,
			"require: deserialise failed for " .. source_path ..
			": " .. tostring(derr)
	end
	local exports, aliases, uerr = M.unpack_artifact(artifact)
	return exports, aliases, source_hash, uerr
end

M._resolve_via_cache = resolve_via_cache

-- ── synth_call (overrides H) ──────────────────────────────────────────────

local existing_call_handler -- captured at register-time

-- K1 driver hooks (module-state, see header below for rationale).
-- Declared here so synth_call's upvalues bind correctly; the setters /
-- getters live further down for narrative grouping but the slot itself
-- must exist before the closure that references it.
-- Annotation-free per this file's convention (cross-module V4Type /
-- WalkerEnv references do not resolve in the walker's annotation scope;
-- see file header). The hooks' shapes are documented at the setter
-- definition below.
local current_drive_recursive = nil
local current_deps_sink       = nil

local function synth_call(node, env, solver)
	-- Inline the require-call shape match. Splitting it into a sub-helper
	-- (is_require_call) loses input-type unification with synth_call's
	-- inferred `node` param shape — the typechecker narrows the call-site
	-- shape too aggressively, dropping fields the sub-helper needs. The
	-- inline form keeps the inferred shape unified.
	local callee = node.callee
	local match = callee ~= nil
		and callee.tag == defs.NODE_IDENTIFIER
		and callee.name == "require"
		and node.args ~= nil
		and #node.args == 1
	if match then
		local first = node.args[1]
		if first.tag ~= defs.NODE_LITERAL or first.lit_kind ~= defs.LIT_STRING then
			match = false
		end
	end
	if not match then
		return existing_call_handler(node, env, solver)
	end
	local arg = node.args[1]
	local mod_name = arg.value
	if type(mod_name) ~= "string" then
		return nil, env, D.emit(env, D.E_REQUIRE_UNRESOLVED,
			"require: string-literal argument has non-string value")
	end

	-- Cycle break: if mod_name is already on the require chain, return its
	-- placeholder. The placeholder is either a V4Type (set by an outer
	-- frame that synthesised one for the partially-resolved module) or
	-- `true` (sentinel — no concrete placeholder available, so we mint a
	-- fresh var here and return it; the outer resolver does NOT see the
	-- fresh var because the chain entry was set before the inner call ran,
	-- so the outer's eventual unification with the real export type still
	-- closes correctly through the unification graph).
	local in_progress = E.lookup_require(env, mod_name)
	if in_progress ~= nil then
		if in_progress == true then
			local placeholder = V.var("require:" .. mod_name)
			O.record(placeholder, O.from_env(env, D.O_FROM_REQUIRE,
				{ module = mod_name, msg = "require placeholder (cycle break)" }))
			return placeholder, env, nil
		end
		return in_progress, env, nil
	end

	-- Caps gate. Per CLAUDE.md "Caps-first, everywhere": no fallback.
	local caps = env.io_caps
	if caps == nil then
		return nil, env, D.emit(env, D.E_REQUIRE_IO,
			"require: io_caps not installed on env (call E.with_io_caps " ..
			"before walking a file that uses require)",
			{ module = mod_name })
	end
	local cache_dir = env.cache_dir
	if cache_dir == nil then
		return nil, env, D.emit(env, D.E_REQUIRE_IO,
			"require: cache_dir not installed on env (call E.with_cache_dir " ..
			"before walking a file that uses require)",
			{ module = mod_name })
	end

	local source_path, perr = resolve_module_path(caps, mod_name)
	if source_path == nil then
		return nil, env, D.emit(env, D.E_REQUIRE_UNRESOLVED,
			tostring(perr), { module = mod_name })
	end

	-- Mark in-progress with `true` so any inner `require(mod_name)` fires
	-- the placeholder branch above. We unwind the chain on the way out.
	local env_in = E.push_require(env, mod_name, true)
	local exports, aliases, cached_source_hash, err = resolve_via_cache(caps, cache_dir, source_path)
	-- K1: on cache miss, attempt a recursive walk via env.drive_recursive
	-- if the driver has installed the cap. The cap re-enters the driver
	-- for the resolved source path, performs its own cache_store on
	-- success, and we then loop back through cache_lookup to fetch the
	-- newly-stored artifact. Without the cap installed (legacy callers
	-- that walk in isolation, walker tests), we keep sub-phase I's
	-- loud-rejection behaviour — the miss message is the honest answer
	-- for that configuration.
	local recursed_source_hash = nil
	if err ~= nil and current_drive_recursive ~= nil then
		local sub_exports, sub_aliases, sub_hash, sub_err =
			current_drive_recursive(source_path, env_in)
		if sub_err == nil and sub_exports ~= nil then
			exports = sub_exports
			aliases = sub_aliases
			recursed_source_hash = sub_hash
			err = nil
		elseif sub_err ~= nil then
			err = sub_err
		end
	end
	env_in = E.pop_require(env_in, mod_name)
	if err ~= nil then
		return nil, env_in, D.emit(env_in, D.E_REQUIRE_UNRESOLVED,
			tostring(err), { module = mod_name })
	end
	-- Record the dep so the outer driver's cache_store includes this
	-- import in the manifest deps map (used for transitive invalidation).
	-- On cache hit, resolve_via_cache returned the source bytes' hash
	-- back through a fourth return slot (added below) so we don't
	-- re-read the file.
	if current_deps_sink ~= nil then
		local hash = recursed_source_hash or cached_source_hash
		if hash ~= nil then
			current_deps_sink[source_path] = hash
		end
	end

	-- Merge the imported file's --:: aliases into the requiring file's
	-- alias scope. This is the v4 equivalent of legacy Pass -1 alias
	-- propagation: a name like `Foo` declared `--:: Foo = ...` in the
	-- imported file becomes visible as an annotation name here.
	local env_out = env_in
	if aliases ~= nil then
		for name, ty in pairs(aliases) do
			env_out = E.bind_alias(env_out, name, ty)
		end
	end
	-- Origin tagging (sub-phase J): the export type came from a require
	-- call. Downstream subtype failures whose LHS or RHS traces back to
	-- this type will surface the require as the origin in their diagnostic
	-- chain — this is the data-level edge that replaces the legacy
	-- "most recent preceding require" proximity heuristic.
	if exports ~= nil then
		O.record(exports, O.from_env(env, D.O_FROM_REQUIRE,
			{ module = mod_name,
			  msg = "require(\"" .. mod_name .. "\")" }))
	end
	return exports, env_out, nil
end

M.synth_call = synth_call

-- ── K1 driver hooks ───────────────────────────────────────────────────────
--
-- The driver (lib/type/static-v4/driver/driver.lua) sets these two
-- module-level slots once per drive() invocation and resets them on
-- exit. The reason for module-state rather than env-state: WalkerEnv's
-- clone() is the contract between sub-phases A–J and does not carry
-- runtime-injected fields like a "drive recursively" cap. Threading
-- those fields through clone() would expand the env shape every time a
-- new driver hook lands; using module-state keeps the env shape stable
-- and confines the K1 wiring to this file.
--
-- Single-driver-per-process is the invariant. The driver always pairs
-- `_set_driver_hooks(fn, deps_table)` with `_clear_driver_hooks()` in
-- the same call frame. Nested driver invocations (recursive walks) re-
-- set the hooks on entry and re-set the parent's hooks on return — see
-- driver.lua's drive() body for the save/restore pattern.

function M._set_driver_hooks(drive_recursive_fn, deps_sink)
	current_drive_recursive = drive_recursive_fn
	current_deps_sink       = deps_sink
end

function M._clear_driver_hooks()
	current_drive_recursive = nil
	current_deps_sink       = nil
end

function M._current_drive_recursive() return current_drive_recursive end
function M._current_deps_sink()       return current_deps_sink end

-- ── registration ─────────────────────────────────────────────────────────

function M.register(W)
	-- Capture H's CALL_EXPR handler (which itself wraps G/F/C). Sub-phase I
	-- is the outermost wrapper in the override chain — checked before any
	-- intrinsic-call recogniser because `require` is a transport-level
	-- operation that is structurally distinct from error/pcall/xpcall.
	local effects = require("lib.type.static-v4.walker.effects")
	existing_call_handler = effects.synth_call_for_subphase_i
	if existing_call_handler == nil then
		error("walker sub-phase I: cannot capture sub-phase H's synth_call " ..
			"handler — effects.lua does not expose synth_call_for_subphase_i")
	end
	W.register_synth(defs.NODE_CALL_EXPR, synth_call)
end

return M
