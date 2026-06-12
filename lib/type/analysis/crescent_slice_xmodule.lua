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

local M = {}

-- ── Module-path → file-path resolution (pure, §6.6.2) ────────────────────────
--
-- `require("lib.x.y")` → `lib/x/y.lua`; if absent, `lib/x/y/init.lua` (standard Lua
-- package layout). Only `lib.`-prefixed module paths are alias sources; anything
-- else (`bit`, `ffi`, a non-lib path) contributes no aliases and is NOT an error.
-- Resolution consults the injected `read_file` cap to decide which candidate exists.

--:: ReadFile = (path: string) -> (string | nil, string | nil)

-- Candidate file paths for a `lib.`-prefixed module, in precedence order.
--: (string) -> string[]
local function candidate_paths(modpath)
	local rel = (modpath:gsub("%.", "/"))
	return { rel .. ".lua", rel .. "/init.lua" }
end

-- Resolve a module path to (source, filepath) using the cap, or (nil, nil) when the
-- module is not a lib alias source (non-lib prefix, or no readable candidate).
--: (string, ReadFile) -> (string | nil, string | nil)
local function read_module(modpath, read_file)
	if modpath:sub(1, 4) ~= "lib." and modpath ~= "lib" then return nil, nil end
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
-- Recursive aliases that span modules reduce to the in-file recursive case the moment
-- the names are co-visible in the same flat env, so `declare_alias`'s existing
-- μ-placeholder binding handles them (§6.6.4).

--:: ExportError = { module: string, name: string, err: string }

--: (env: AliasEnv, src: string, modpath: string) -> (string[], ExportError[])
local function import_top_level_aliases(env, src, modpath)
	local lines = {} --[[: { [integer]: string } ]]
	for ln in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = ln end
	local names = {} --[[: string[] ]]
	local errors = {} --[[: ExportError[] ]]
	local idx = 1 --: integer
	while idx <= #lines do
		local d, consumed = P.scan_annotation_at(lines, idx)
		local span = (consumed > 0 and consumed or 1) --: integer
		local dname = d and d.name --[[: string | nil ]]
		local dbody = d and d.body --[[: string | nil ]]
		if d and d.kind == "alias" and dname ~= nil and dbody ~= nil then
			local r, e = P.declare_alias(env, dname, dbody)
			if r then
				names[#names + 1] = dname
			else
				errors[#errors + 1] = { module = modpath, name = dname, err = e or "alias error" }
			end
		end
		idx = idx + span
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
--   imports  : per-resolved-module record { module, path, names, form } — the data
--              the lowering driver turns into Artifact/Observation/Dependency/
--              TrustBoundary objects (§6.6.5/§6.6.6). `names` is the imported alias
--              names; `path` the resolved file path.
--   markers  : { line, construct } for dynamic requires (`dynamic-require`) — never
--              a silent drop.
--   errors   : ExportError[] — malformed exporting aliases (attributed to the module).
--
-- ACYCLIC by a visited set on module paths (§6.6.4): a module is resolved at most
-- once per assembly; a require cycle terminates with the union of reachable aliases.
-- With no `read_file` cap, this is a no-op (returns an empty base env) — the honest
-- pre-increment behavior, not a reach for `io`.

--:: ImportRecord = { module: string, path: string, names: string[], form: string }
--:: ImportPassResult = { env: AliasEnv, imports: ImportRecord[], markers: { [integer]: { line: integer, construct: string } }, errors: ExportError[] }

--: (string, ({ read_file?: ReadFile } | nil)) -> ImportPassResult
function M.resolve(src, opts)
	local env = {} --[[: AliasEnv ]]
	local imports = {} --[[: ImportRecord[] ]]
	local markers = {} --[[: { [integer]: { line: integer, construct: string } } ]]
	local errors = {} --[[: ExportError[] ]]
	local read_file = opts and opts.read_file --[[: ReadFile | nil ]]

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
			visited[tmod] = true
			local msrc, mpath = read_module(tmod, read_file)
			if msrc ~= nil and mpath ~= nil then
				local names, errs = import_top_level_aliases(env, msrc, tmod)
				if #names > 0 then
					imports[#imports + 1] = { module = tmod, path = mpath, names = names, form = t.form or "value" }
				end
				for _, er in ipairs(errs) do errors[#errors + 1] = er end
			end
			-- a non-lib or unreadable module contributes nothing and is not an error.
		end
	end

	return { env = env, imports = imports, markers = markers, errors = errors }
end

return M
