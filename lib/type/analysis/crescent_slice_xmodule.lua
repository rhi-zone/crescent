-- ════════════════════════════════════════════════════════════════════════════
-- Cross-module type-alias resolution for `crescent.slice.v1` (slice v2 increment 2)
-- ════════════════════════════════════════════════════════════════════════════
--
-- The measured #1 annotation-survey demand (`docs/slice-survey-v1.md`:
-- `unknown-type-name`, 172 files). DESIGN: `docs/agnostic-static-analysis-crescent-slice.md`
-- §6.6 (the multi-artifact derived whole). This module realizes §6.6.2's import
-- pass: it assembles the cross-module alias environment for checking an entry file
-- by importing the top-level `--::` aliases of the modules the entry requires.
--
-- Two import triggers, both already in real `lib/` source (§6.6.1):
--   1. `--:: require "lib.x"`        — a TYPE-ONLY import directive (the dominant
--                                       idiom, 48 files).
--   2. `local v = require("lib.x")`  — a value import whose module's aliases ALSO
--                                       become visible (the original fixture form:
--                                       lib/dns/tcp_client.lua requires lib.epoll).
--
-- Imported aliases enter under their BARE declared names (flat, unqualified) —
-- the only form the corpus uses (`TaskDef`, `epoll`, never `mod.Type`).
--
-- CAPS-FIRST (CLAUDE.md): reading an exporting module's source is I/O, so this
-- module NEVER touches `io` directly — the caller injects a `read_file` capability.
-- With no cap, cross-module imports resolve to no aliases (the honest pre-increment
-- behavior), never a silent reach for `io`.
--
-- COLLISION POLICY (audit round 2, F1): when importing a bare name already present
-- in the env from a DIFFERENT exporter with a DIFFERENT tid, the import is rejected
-- with an error diagnostic naming both modules and the colliding name. Identical
-- tids dedupe silently (same type, no conflict). Entry-local `--::` shadowing an
-- import stays allowed — the scan_source pass runs AFTER the import pass and uses
-- most-recent-wins, which is the designed and tested shadowing behavior.
--
-- PATH VALIDATION (audit round 2, F3): require-strings with empty dot-segments
-- (e.g. `lib..secret`, `lib.x.....`) are refused with an `invalid-require` marker;
-- the cap is never reached for malformed paths.
--
-- CONTENT DIGEST (audit round 2, F4): each ImportRecord carries a `digest` field
-- (CRC32-hex of the exporting source text) so the lowering driver can include it
-- in the cross-artifact Dependency record. A body change is then visible as a
-- digest diff even when the path is unchanged.
--
-- MUTUAL-ALIAS RETRACTION (audit round 2, F2): an earlier draft claimed that
-- mutual cross-module aliases (A's body references B's name and B's body references
-- A's name) reduce to the in-file recursive case via `declare_alias`'s μ-placeholder.
-- This is FALSE: each exporting module is parsed before the other's names are
-- installed in the flat env, so the forward reference appears as an unknown-type-name
-- error in the exporting body. The correct behavior is: mutual cross-module aliases
-- error honestly (unknown-type-name on the referencing side). This is the same
-- honest-error behavior as in-file forward references (§9.8 deferral), and is
-- acceptable at v1. See §6.6.4 (corrected) and §9.11.
--
-- SUBSTRATE: untouched. This is a pure consumer of the multi-artifact object model
-- (`docs/agnostic-static-analysis-object-model.md`): it produces alias data plus the
-- import records the lowering driver turns into Artifact / Observation / Dependency /
-- TrustBoundary objects via the EXISTING substrate API. No new object kind.

-- `slice_ty` brings the `Ty` alias (and `AliasEnv`'s `Ty` member) into this file's
-- annotation scope, so the `AliasEnv` references below resolve — the adapter does the
-- same. We use no value from it directly. Required BEFORE parse so `Ty` is in scope
-- when parse's `--::` declarations are checked transitively.
local _G_ty = require("lib.type.analysis.slice_ty")
local _ = _G_ty
local P = require("lib.type.analysis.crescent_slice_parse")
local CRC32 = require("lib.hash.crc32")

local M = {}

-- ── Module-path → file-path resolution (pure, §6.6.2) ────────────────────────
--
-- `require("lib.x.y")` → `lib/x/y.lua`; if absent, `lib/x/y/init.lua` (standard Lua
-- package layout). Only `lib.`-prefixed module paths are alias sources; anything
-- else (`bit`, `ffi`, a non-lib path) contributes no aliases and is NOT an error.
-- Resolution consults the injected `read_file` cap to decide which candidate exists.
--
-- PATH VALIDATION (audit round 2, F3): each dot-separated segment must be non-empty
-- and composed only of the require-name charset (`[%a%d_]`). A module path with any
-- invalid segment is refused before building file paths; the cap is never reached.

--:: ReadFile = (path: string) -> (string | nil, string | nil)

-- Returns true when every dot-segment of `modpath` is non-empty and matches
-- the require-name charset (letters, digits, underscore). Dots themselves are
-- separators, not part of a segment; a leading, trailing, or doubled dot produces
-- an empty segment and returns false. An empty string returns false.
--: (string) -> boolean
local function valid_modpath_segments(modpath)
	if modpath == "" then return false end
	-- A leading, trailing, or doubled dot means an empty segment → invalid.
	if modpath:sub(1, 1) == "." or modpath:sub(-1) == "." or modpath:find("%.%.") then
		return false
	end
	-- Every segment must be non-empty and composed only of the require-name charset.
	for seg in modpath:gmatch("[^%.]+") do
		if not seg:match("^[%a%d_]+$") then return false end
	end
	return true
end

M.valid_modpath_segments = valid_modpath_segments

-- Candidate file paths for a `lib.`-prefixed module, in precedence order.
-- Callers must validate the modpath with `valid_modpath_segments` first.
--: (string) -> string[]
local function candidate_paths(modpath)
	local rel = (modpath:gsub("%.", "/"))
	return { rel .. ".lua", rel .. "/init.lua" }
end

-- Resolve a module path to (source, filepath) using the cap, or (nil, nil) when the
-- module is not a lib alias source (non-lib prefix, or no readable candidate).
-- Returns (nil, nil) for malformed paths WITHOUT reaching the cap (F3).
--: (string, ReadFile) -> (string | nil, string | nil)
local function read_module(modpath, read_file)
	if modpath:sub(1, 4) ~= "lib." and modpath ~= "lib" then return nil, nil end
	-- validate segments before building any file path (F3: malformed paths refused).
	if not valid_modpath_segments(modpath) then return nil, nil end
	for _, path in ipairs(candidate_paths(modpath)) do
		local src = read_file(path)
		if src ~= nil then return src, path end
	end
	return nil, nil
end

M.candidate_paths = candidate_paths
M.read_module = read_module

-- ── Top-level alias extraction from an exporting module's source ─────────────
--
-- Scan a module's source for its TOP-LEVEL `--::` alias declarations (joining
-- multi-line `--::` continuations via the existing scanner), declaring each into the
-- given env. Returns the list of declared names (for the import records). Errors in
-- an exporting alias are surfaced (a malformed exporting `--::` is a real defect),
-- attributed to the exporting module via the returned `errors` list.
--
-- COLLISION POLICY (audit round 2, F1): this function checks the env before
-- installing each name. If `name` is already present in the env (imported by a
-- PRIOR exporter tracked in `origin`):
--   - same tid (identical interned Ty): silently deduped (same type, no conflict).
--   - different tid: an error is returned naming both modules and the colliding name.
--
-- `origin` maps bare name → exporter modpath (maintained by the caller).
-- Entry-local `--::` shadowing is NOT subject to this check — the scan_source pass
-- runs after the import pass and uses most-recent-wins, which is the verified design.
--
-- NOTE (audit round 2, F2 retraction): mutual cross-module aliases do NOT reduce to
-- the in-file recursive case. Each exporting module is parsed independently, before
-- the other's names are installed. A body that references a name not yet in env
-- produces an unknown-type-name error on the exporting side. This is the correct,
-- honest behavior — the same as in-file forward references (§9.8 deferral). See
-- §6.6.4 (corrected) and §9.11.

--:: ExportError = { module: string, name: string, err: string }

--: (env: AliasEnv, origin: { [string]: string }, src: string, modpath: string) -> (string[], ExportError[])
local function import_top_level_aliases(env, origin, src, modpath)
	local lines = {} --[[: { [integer]: string } ]]
	for ln in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = ln end
	local names = {} --[[: string[] ]]
	local errors = {} --[[: ExportError[] ]]
	-- Collect this module's alias decls in source order, then install them in
	-- DEPENDENCY order (§6.12): a forward-sibling reference inside ONE exporting
	-- module (`A`'s body names `B` declared below it) needs `B` installed first.
	-- The topo order is computed over THIS module's batch only; the per-name
	-- collision check (F1) against names imported from OTHER modules is unaffected by
	-- intra-module reordering. A genuine mutual cycle keeps source order and errors
	-- honestly (the §9.19 multi-binder-μ deferral, same as the in-file case).
	local decls = {} --[[: { [integer]: { name: string, body: string } } ]]
	local idx = 1 --: integer
	while idx <= #lines do
		local d, consumed = P.scan_annotation_at(lines, idx)
		local span = (consumed > 0 and consumed or 1) --: integer
		local dname = d and d.name --[[: string | nil ]]
		local dbody = d and d.body --[[: string | nil ]]
		if d and d.kind == "alias" and dname ~= nil and dbody ~= nil then
			decls[#decls + 1] = { name = dname, body = dbody }
		end
		idx = idx + span
	end
	-- Install one alias body `dname = dbody` into `env`, applying F1 collision
	-- detection. `install` performs the actual binding (so the family path can
	-- elaborate the WHOLE family while still gating each member through F1). It is
	-- called only when there is NO cross-exporter collision; on collision it records
	-- the error and is not called.
	--: (string, string, () -> (boolean, string | nil)) -> nil
	local function install_with_f1(dname, dbody, install)
		local existing = env[dname] --[[: Ty | nil ]]
		local orig_mod = origin[dname] --[[: string | nil ]]
		if existing ~= nil and orig_mod ~= nil and orig_mod ~= modpath then
			-- parse the new body into a candidate Ty using a fresh copy of env so
			-- that parsing side effects don't corrupt the shared env.
			local probe_env = {} --[[: AliasEnv ]]
			for k2, v2 in pairs(env) do probe_env[k2] = v2 end
			local candidate = P.declare_alias(probe_env, dname, dbody)
			if candidate then
				local new_ty = probe_env[dname] --[[: Ty | nil ]]
				if new_ty ~= nil and new_ty == existing then
					-- identical: skip (already present, same type).
				else
					errors[#errors + 1] = {
						module = modpath, name = dname,
						err = "collision: name '" .. dname .. "' already imported from '"
							.. orig_mod .. "' with a different type; re-imported by '"
							.. modpath .. "' with an incompatible type (tid mismatch)",
					}
				end
			else
				errors[#errors + 1] = {
					module = modpath, name = dname,
					err = "collision: name '" .. dname .. "' already imported from '"
						.. orig_mod .. "'; re-import from '" .. modpath .. "' is also malformed",
				}
			end
		else
			local ok, e = install()
			if ok then
				names[#names + 1] = dname
				if origin[dname] == nil then origin[dname] = modpath end
			else
				errors[#errors + 1] = { module = modpath, name = dname, err = e or "alias error" }
			end
		end
	end

	-- dependency-ordered GROUPS over the batch (each group is an SCC, in topo
	-- order). A size-1 group installs via `declare_alias`; a mutual-recursive family
	-- (size ≥2) Bekić-elaborates as a unit (§6.13), each member still F1-gated.
	local groups = P.alias_decl_groups(decls)
	for _, group in ipairs(groups) do
		if #group == 1 then
			local d = decls[group[1]]
			install_with_f1(d.name, d.body, function()
				local r, e = P.declare_alias(env, d.name, d.body)
				return r ~= nil, e
			end)
		else
			-- Bekić family. Elaborate the whole family into a fresh staging env (so a
			-- collision on one member does not half-install the family), then F1-gate
			-- each member, copying the elaborated Ty into the shared env on success.
			local fmembers = {} --[[: { [integer]: { name: string, body: string } } ]]
			for _, gi in ipairs(group) do fmembers[#fmembers + 1] = { name = decls[gi].name, body = decls[gi].body } end
			local staging = {} --[[: AliasEnv ]]
			for k2, v2 in pairs(env) do staging[k2] = v2 end
			local fres = P.elaborate_family(staging, fmembers)
			for _, gi in ipairs(group) do
				local d = decls[gi]
				install_with_f1(d.name, d.body, function()
					local r = fres[d.name]
					if r and r.ok then
						env[d.name] = staging[d.name]
						return true, nil
					end
					return false, (r and r.err) or "family member unresolved"
				end)
			end
		end
	end
	return names, errors
end

M.import_top_level_aliases = import_top_level_aliases

-- ── Import-trigger collection from the entry source (§6.6.2) ─────────────────
--
-- Walk the entry file's lines collecting both import triggers in SOURCE ORDER:
--   - `--:: require "lib.x"`            → { module = "lib.x", form = "directive" }
--   - `local v = require("lib.x")`      → { module = "lib.x", form = "value" }
--   - `... = require("lib.x")` (any)    → value form (the binding name is irrelevant
--                                          to type visibility; the corpus never
--                                          qualifies).
-- A dynamic `require(expr)` (no string literal) is recorded as `{ dynamic = true }`
-- so the caller can emit a `dynamic-require` marker — never a silent drop.

--:: ImportTrigger = { module?: string, form?: string, dynamic?: boolean, line: integer }

--: (string) -> ImportTrigger[]
local function collect_imports(src)
	local out = {} --[[: ImportTrigger[] ]]
	local lineno = 0 --: integer
	for ln in (src .. "\n"):gmatch("(.-)\n") do
		lineno = lineno + 1
		-- type-only directive: `--:: require "lib.x"`
		local d = P.scan_annotation(ln)
		if d and d.kind == "import" and d.module ~= nil then
			out[#out + 1] = { module = d.module, form = "directive", line = lineno }
		else
			-- value require: a static string-literal `require("...")` / `require'...'`
			-- anywhere on a non-comment line. We only treat lines that are not
			-- annotation comments (those are handled above / by the alias scanner).
			if not ln:match("^%s*%-%-") then
				local m = ln:match([[require%s*%(%s*"([^"]+)"%s*%)]])
					or ln:match([[require%s*%(%s*'([^']+)'%s*%)]])
					or ln:match([[require%s*"([^"]+)"]])
					or ln:match([[require%s*'([^']+)']])
				if m then
					out[#out + 1] = { module = m, form = "value", line = lineno }
				elseif ln:match([[require%s*%(]]) then
					-- a require with a non-string-literal argument → dynamic, out-of-subset.
					out[#out + 1] = { dynamic = true, line = lineno }
				end
			end
		end
	end
	return out
end

M.collect_imports = collect_imports

-- ── The import pass: assemble the cross-module base alias env (§6.6.2/§6.6.4) ─
--
-- Given the entry source and an injected `read_file` cap, resolve every static
-- `lib/` import trigger and return:
--   env      : AliasEnv pre-populated with imported top-level aliases (flat, bare
--              names). The caller declares the entry's OWN aliases on top
--              (most-recent-wins shadowing).
--   imports  : per-resolved-module record { module, path, names, form, digest } —
--              the data the lowering driver turns into Artifact/Observation/Dependency/
--              TrustBoundary objects (§6.6.5/§6.6.6). `names` is the imported alias
--              names; `path` the resolved file path; `digest` is the CRC32-hex of
--              the exporting source text (for staleness/invalidation records, F4).
--   markers  : { line, construct } for dynamic requires (`dynamic-require`) and for
--              malformed require paths (`invalid-require`, F3) — never a silent drop.
--   errors   : ExportError[] — malformed exporting aliases or collisions (F1).
--
-- ACYCLIC by a visited set on module paths (§6.6.4): a module is resolved at most
-- once per assembly; a require cycle terminates with the union of reachable aliases.
-- With no `read_file` cap, this is a no-op (returns an empty base env) — the honest
-- pre-increment behavior, not a reach for `io`.
--
-- PATH VALIDATION (F3): a require string with invalid segments is refused with an
-- `out-of-subset/invalid-require` marker; the cap is never called for it.
--
-- COLLISION DETECTION (F1): importing a name already present from a different exporter
-- with a different tid is rejected as an ExportError naming both modules.

--:: ImportRecord = { module: string, path: string, names: string[], form: string, digest: string }
--:: ImportPassResult = { env: AliasEnv, imports: ImportRecord[], markers: { [integer]: { line: integer, construct: string } }, errors: ExportError[] }

--: (string, ({ read_file?: ReadFile } | nil)) -> ImportPassResult
function M.resolve(src, opts)
	local env = {} --[[: AliasEnv ]]
	local imports = {} --[[: ImportRecord[] ]]
	local markers = {} --[[: { [integer]: { line: integer, construct: string } } ]]
	local errors = {} --[[: ExportError[] ]]
	local read_file = opts and opts.read_file --[[: ReadFile | nil ]]
	-- origin maps bare name → exporter modpath (for collision detection, F1).
	local origin = {} --[[: { [string]: string } ]]

	local triggers = collect_imports(src)
	if not read_file then
		-- No cap injected: dynamic-require markers still recorded; no aliases imported.
		for _, t in ipairs(triggers) do
			if t.dynamic then markers[#markers + 1] = { line = t.line, construct = "dynamic-require" } end
		end
		return { env = env, imports = imports, markers = markers, errors = errors }
	end

	local visited = {} --[[: { [string]: boolean } ]]
	for _, t in ipairs(triggers) do
		local tmod = t.module --[[: string | nil ]]
		if t.dynamic then
			markers[#markers + 1] = { line = t.line, construct = "dynamic-require" }
		elseif tmod ~= nil and not visited[tmod] then
			-- F3: validate path segments before any cap reach.
			if not valid_modpath_segments(tmod) then
				markers[#markers + 1] = {
					line = t.line,
					construct = "out-of-subset/invalid-require",
				}
			else
				visited[tmod] = true
				local msrc, mpath = read_module(tmod, read_file)
				if msrc ~= nil and mpath ~= nil then
					-- F4: compute a content digest for staleness records.
					local digest = CRC32.crc32_hex(msrc)
					local names, errs = import_top_level_aliases(env, origin, msrc, tmod)
					if #names > 0 then
						imports[#imports + 1] = { module = tmod, path = mpath, names = names, form = t.form or "value", digest = digest }
					end
					for _, er in ipairs(errs) do errors[#errors + 1] = er end
				end
				-- a non-lib or unreadable module contributes nothing and is not an error.
			end
		end
	end

	return { env = env, imports = imports, markers = markers, errors = errors }
end

return M
