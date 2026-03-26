if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/cli.lua — crescent package manager CLI dispatcher
--
-- Usage: luajit lib/pkg/cli.lua <command> [args...]
--
-- Commands:
--   install [--frozen] [--force]    install all deps from pkg.lua / lockfile
--   add <name[@version]>            add dep to pkg.lua, install, update lockfile
--   remove <name>                   remove dep, delete lib/<name>/, update lockfile
--   update [name]                   re-resolve to latest matching version(s)
--   eject <name>                    remove from lockfile; leave lib/<name>/ untouched
--   diff <name>                     diff lib/<name>/ against cached version (no network)
--   info <name>                     show package info from registry
--   check [--strict]                scan current package for phantom deps
--
-- Global flags:
--   --verbose                       enable verbose output
--   --registry=URL                  override default registry (https://pkg.crescent.run)
--   --jobs=N                        parallelism (default: CPU count; 1 = sequential)
--   --force                         overwrite local modifications (install only)
--   --strict                        exit 1 on any phantom dep (check command)
--   --skip-check                    skip phantom dep lint (publish command)

local manifest  = require("lib.pkg.manifest")
local lock      = require("lib.pkg.lock")
local install   = require("lib.pkg.install")
local publish   = require("lib.pkg.publish")
local check     = require("lib.pkg.check")
local workspace = require("lib.pkg.workspace")

local M = {}

-- ── constants ────────────────────────────────────────────────────────────────

local DEFAULT_REGISTRY = "https://pkg.crescent.run"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function stderr(fmt, ...)
	io.stderr:write(("error: " .. fmt .. "\n"):format(...))
end

local function info(fmt, ...)
	io.stdout:write((fmt .. "\n"):format(...))
end

-- Run a shell command for side effects. Returns true or nil, err.
local function run_cmd(cmd)
	local ok = os.execute(cmd)
	if ok ~= 0 and ok ~= true then
		return nil, "command failed: " .. cmd
	end
	return true
end

-- Fetch URL and return body string, or nil, err.
local function http_get(url)
	local fh, err = io.popen(("curl -fsSL %q"):format(url), "r")
	if not fh then
		return nil, "popen failed: " .. tostring(err)
	end
	local out = fh:read("*a")
	fh:close()
	return out
end

-- Check whether a path exists.
local function path_exists(path)
	local f = io.open(path, "r")
	if f then f:close(); return true end
	return false
end

-- Return the global cache directory root (~/.crescent/cache).
local function cache_root()
	local home = os.getenv("HOME") or "/tmp"
	return home .. "/.crescent/cache"
end

-- ── argument parsing ─────────────────────────────────────────────────────────

--- Parse argv into { command, args, flags }.
-- Global flags (--verbose, --registry=X, --jobs=N, --frozen, --force, --merge) are extracted.
-- Remaining positional args are left in the args list.
function M.parse_args(argv)
	local result = {
		command    = nil,
		args       = {},
		verbose    = false,
		frozen     = false,
		dry_run    = false,
		force      = false,
		merge      = false,
		overwrite  = false,
		strict     = false,
		skip_check = false,
		workspace  = false,
		registry   = DEFAULT_REGISTRY,
		jobs       = 0,
	}

	local i = 0
	-- argv may be 0-indexed (arg table from luajit) or 1-indexed
	-- Normalise: collect into a plain 1-indexed list starting after index 0.
	local list = {}
	-- Support both arg[1..n] (test callers) and raw tables
	for j = 1, #argv do
		list[#list + 1] = argv[j]
	end

	for _, v in ipairs(list) do
		if v == "--verbose" then
			result.verbose = true
		elseif v == "--workspace" then
			result.workspace = true
		elseif v == "--frozen" then
			result.frozen = true
		elseif v == "--dry-run" then
			result.dry_run = true
		elseif v == "--force" then
			result.force = true
		elseif v == "--merge" then
			result.merge = true
		elseif v == "--overwrite" then
			result.overwrite = true
		elseif v == "--strict" then
			result.strict = true
		elseif v == "--skip-check" then
			result.skip_check = true
		elseif v:sub(1, 11) == "--registry=" then
			result.registry = v:sub(12)
		elseif v:sub(1, 7) == "--jobs=" then
			local n = tonumber(v:sub(8))
			if n and n >= 0 then
				result.jobs = math.floor(n)
			end
		elseif v:sub(1, 2) == "--" then
			-- unknown flag — pass through as positional (commands may handle it)
			result.args[#result.args + 1] = v
		elseif result.command == nil then
			result.command = v
		else
			result.args[#result.args + 1] = v
		end
	end

	return result
end

--- Parse a package specifier like "sha1" or "sha1@1.0.0".
-- Returns name, constraint where constraint is "*" for bare names or "=1.0.0" for pinned.
function M.parse_pkg_spec(spec)
	local at = spec:find("@", 1, true)
	if at then
		local name    = spec:sub(1, at - 1)
		local version = spec:sub(at + 1)
		return name, "=" .. version
	end
	return spec, "*"
end

-- ── commands ─────────────────────────────────────────────────────────────────

--- cr install [--frozen] [--force] [--workspace]
local function cmd_install(project_dir, parsed)
	-- Workspace detection: if --workspace flag is set or workspace.lua exists in
	-- any ancestor, use the workspace root as project_dir.
	local effective_dir = project_dir
	if parsed.workspace then
		local ws_root = workspace.find_root(project_dir)
		if ws_root then
			effective_dir = ws_root
		else
			stderr("install: --workspace specified but no workspace.lua found in %s or any parent", project_dir)
			return false
		end
	else
		-- Auto-detect: walk up looking for workspace.lua
		local ws_root = workspace.find_root(project_dir)
		if ws_root then
			effective_dir = ws_root
		end
	end

	local opts = {
		frozen   = parsed.frozen,
		force    = parsed.force,
		registry = parsed.registry,
		jobs     = parsed.jobs,
		verbose  = parsed.verbose,
	}

	local result = install.run(effective_dir, opts)

	for _, name in ipairs(result.installed) do
		info("installed %s", name)
	end
	for _, name in ipairs(result.skipped) do
		if parsed.verbose then
			info("up to date %s", name)
		end
	end

	if not result.ok then
		for _, e in ipairs(result.errors) do
			stderr("%s", e)
		end
		return false
	end

	if #result.installed == 0 and #result.skipped == 0 then
		info("nothing to install")
	end

	return true
end

--- cr add <name[@version]>
local function cmd_add(project_dir, parsed)
	local spec = parsed.args[1]
	if not spec then
		stderr("add: missing package name")
		stderr("usage: cr add <name[@version]>")
		return false
	end

	local name, constraint = M.parse_pkg_spec(spec)

	-- Validate name roughly (matches manifest rules)
	if name == "" or name:find("[^a-z0-9_%-]") then
		stderr("add: invalid package name %q (only [a-z0-9_-] allowed)", name)
		return false
	end

	-- Load or create pkg.lua
	local pkg_path = project_dir .. "/pkg.lua"
	local m, m_err

	if path_exists(pkg_path) then
		m, m_err = manifest.load(pkg_path)
		if not m then
			stderr("add: failed to load pkg.lua: %s", tostring(m_err))
			return false
		end
	else
		-- Bootstrap a minimal manifest from the directory name
		local dir_name = project_dir:match("([^/]+)$") or "project"
		m = {
			name    = dir_name:gsub("[^a-z0-9_%-]", "-"):lower(),
			version = "0.1.0",
			deps    = {},
		}
	end

	m.deps = m.deps or {}

	if m.deps[name] then
		info("updating %s constraint: %s → %s", name, m.deps[name], constraint)
	else
		info("adding %s (%s)", name, constraint)
	end

	m.deps[name] = constraint

	local write_ok, write_err = manifest.write(pkg_path, m)
	if not write_ok then
		stderr("add: failed to write pkg.lua: %s", tostring(write_err))
		return false
	end

	-- Run install to fetch + update lockfile
	return cmd_install(project_dir, parsed)
end

--- cr remove <name>
local function cmd_remove(project_dir, parsed)
	local name = parsed.args[1]
	if not name then
		stderr("remove: missing package name")
		stderr("usage: cr remove <name>")
		return false
	end

	-- Load pkg.lua
	local pkg_path = project_dir .. "/pkg.lua"
	local m, m_err = manifest.load(pkg_path)
	if not m then
		stderr("remove: failed to load pkg.lua: %s", tostring(m_err))
		return false
	end

	m.deps = m.deps or {}

	if not m.deps[name] then
		stderr("remove: %q is not a direct dependency", name)
		return false
	end

	m.deps[name] = nil

	local write_ok, write_err = manifest.write(pkg_path, m)
	if not write_ok then
		stderr("remove: failed to write pkg.lua: %s", tostring(write_err))
		return false
	end

	-- Delete lib/<name>/ directory
	local lib_dir = project_dir .. "/lib/" .. name
	if path_exists(lib_dir .. "/pkg.lua") or path_exists(lib_dir) then
		local rm_ok, rm_err = run_cmd(("rm -rf %q"):format(lib_dir))
		if not rm_ok then
			stderr("remove: failed to delete lib/%s: %s", name, tostring(rm_err))
			return false
		end
		info("deleted lib/%s/", name)
	end

	-- Remove from crescent.lock
	local lock_path = project_dir .. "/crescent.lock"
	if path_exists(lock_path) then
		local entries, l_err = lock.load(lock_path)
		if not entries then
			stderr("remove: failed to parse crescent.lock: %s", tostring(l_err))
			return false
		end
		if entries[name] then
			entries[name] = nil
			local w_ok, w_err = lock.write(lock_path, entries)
			if not w_ok then
				stderr("remove: failed to write crescent.lock: %s", tostring(w_err))
				return false
			end
		end
	end

	info("removed %s", name)
	return true
end

--- cr update [name] [--merge | --overwrite]
--
-- --merge: three-way merge local edits with the new version.
--   Algorithm:
--   1. Identify locally-modified packages in the target set (tree hash mismatch).
--   2. For each modified package:
--      a. Stash lib/<name>/ → lib/<name>.__merge_stash/ (preserves local edits).
--      b. Drop the lock entry so install re-resolves and links the new version
--         into lib/<name>/ cleanly.
--   3. Run install for all packages (modified ones now have empty lib/ so install
--      fetches and links the new version without interference).
--   4. For each modified package, run merge_package:
--        base   = cache of old version (always present from initial install)
--        ours   = stash (the locally-modified copy)
--        theirs = new version already in lib/<name>/ (also in cache)
--      Then replace lib/<name>/ with the merged result.
--   5. Clean up stashes and update lockfile with merged tree hashes.
--
-- --overwrite: discard local changes (maps to install --force).
local function cmd_update(project_dir, parsed)
	local target       = parsed.args[1]  -- nil means update all
	local do_merge     = parsed.merge
	local do_overwrite = parsed.overwrite

	-- Load lockfile
	local lock_path = project_dir .. "/crescent.lock"
	local entries = {}
	if path_exists(lock_path) then
		local l, l_err = lock.load(lock_path)
		if not l then
			stderr("update: failed to parse crescent.lock: %s", tostring(l_err))
			return false
		end
		entries = l
	end

	if do_merge then
		-- ── Phase 1: identify locally-modified packages in the target set ─────
		local target_names = {}
		if target then
			target_names[target] = entries[target]
		else
			for k, v in pairs(entries) do
				target_names[k] = v
			end
		end

		local modified = {}  -- name → old lock entry
		for name, entry in pairs(target_names) do
			if entry and entry.tree_hash then
				local lib_dir = project_dir .. "/lib/" .. name
				local actual_hash, _ = install.tree_hash(lib_dir)
				if actual_hash and actual_hash ~= entry.tree_hash then
					modified[name] = entry
				end
			end
		end

		-- ── Phase 2: stash modified packages, drop their lock entries ─────────
		local stashed = {}   -- name → stash_path
		local stash_ok = true

		for name, old_entry in pairs(modified) do
			local lib_dir   = project_dir .. "/lib/" .. name
			local stash_dir = project_dir .. "/lib/" .. name .. ".__merge_stash"

			-- Remove any leftover stash from a previous interrupted run.
			os.execute(("rm -rf %q"):format(stash_dir))

			-- Stash: move lib/<name>/ → lib/<name>.__merge_stash/
			local mv_ok = os.execute(("mv %q %q"):format(lib_dir, stash_dir))
			if mv_ok ~= 0 and mv_ok ~= true then
				stderr("update --merge: failed to stash lib/%s/", name)
				-- Roll back already-stashed packages.
				for n, sp in pairs(stashed) do
					local ld = project_dir .. "/lib/" .. n
					os.execute(("rm -rf %q"):format(ld))
					os.execute(("mv %q %q"):format(sp, ld))
				end
				return false
			end
			stashed[name] = stash_dir

			-- Drop from entries so install re-resolves this package.
			entries[name] = nil
		end

		-- Drop non-modified target packages too so they get re-resolved.
		for name in pairs(target_names) do
			if not modified[name] then
				entries[name] = nil
			end
		end

		-- Write the updated lockfile (modified + other target packages dropped).
		local w_ok, w_err = lock.write(lock_path, entries)
		if not w_ok then
			stderr("update: failed to write crescent.lock: %s", tostring(w_err))
			-- Restore stashes before aborting.
			for name, stash_dir in pairs(stashed) do
				local lib_dir = project_dir .. "/lib/" .. name
				os.execute(("rm -rf %q"):format(lib_dir))
				os.execute(("mv %q %q"):format(stash_dir, lib_dir))
			end
			return false
		end

		-- ── Phase 3: run install (resolves + links new versions) ─────────────
		-- Modified packages now have empty lib/ dirs, so install links new version.
		-- Non-modified packages are re-resolved normally.
		local inst_opts = {
			frozen   = false,
			force    = false,
			registry = parsed.registry,
			jobs     = parsed.jobs,
			verbose  = parsed.verbose,
		}
		local inst_result = install.run(project_dir, inst_opts)

		-- Re-read the lockfile to get the new resolved version for each modified pkg.
		local new_lock = {}
		if path_exists(lock_path) then
			local l2, _ = lock.load(lock_path)
			if l2 then new_lock = l2 end
		end

		-- ── Phase 4: merge each stashed package ──────────────────────────────
		local overall_ok  = inst_result.ok
		local any_conflict = false

		for name, old_entry in pairs(modified) do
			local stash_dir  = stashed[name]
			local lib_dir    = project_dir .. "/lib/" .. name
			local new_entry  = new_lock[name]
			local new_version = new_entry and new_entry.version
			local old_version = old_entry.version
			local include     = (old_entry.include or "**")

			if not new_version then
				-- Install couldn't resolve this package (e.g., removed from pkg.lua).
				-- Restore the stash.
				io.stderr:write(("warning: update --merge: %s: could not resolve new version — restoring local copy\n"):format(name))
				os.execute(("rm -rf %q"):format(lib_dir))
				os.execute(("mv %q %q"):format(stash_dir, lib_dir))
				stashed[name] = nil
				-- Restore old lock entry.
				new_lock[name] = old_entry

			elseif new_version == old_version then
				-- No version change: restore stash (keep local modifications).
				if parsed.verbose then
					info("update --merge: %s@%s unchanged, keeping local modifications", name, old_version)
				end
				-- lib/<name>/ now holds the freshly-linked old version.
				-- Restore the stash back on top (or just swap).
				os.execute(("rm -rf %q"):format(lib_dir))
				os.execute(("mv %q %q"):format(stash_dir, lib_dir))
				stashed[name] = nil
				-- Restore old lock entry (tree_hash matches original).
				new_lock[name] = old_entry

			else
				-- New version was installed into lib/<name>/ by install.
				-- stash_dir = local modifications ("ours")
				-- lib/<name>/ = new version ("theirs") — also in cache
				-- cache/<name>@<old_version>/ = base

				-- Move "theirs" aside so we can reconstruct ours from the stash.
				-- merge_package uses:
				--   base   = cache/<name>@<old_version>/
				--   ours   = lib/<name>/               (currently the stash contents)
				--   theirs = cache/<name>@<new_version>/
				-- So we need to restore the stash into lib/<name>/ first, then merge.
				os.execute(("rm -rf %q"):format(lib_dir))
				os.execute(("mv %q %q"):format(stash_dir, lib_dir))
				stashed[name] = nil

				-- Run three-way merge.
				local merge_result, merge_err = install.merge_package(
					project_dir, name, old_version, new_version, include, { verbose = parsed.verbose }
				)

				if not merge_result then
					stderr("update --merge: %s: %s", name, tostring(merge_err))
					overall_ok = false
				elseif not merge_result.ok then
					-- Conflicts.
					info("merged %s@%s → %s: %d file(s) have conflicts — resolve manually",
						name, old_version, new_version, merge_result.conflicts)
					any_conflict = true
					overall_ok = false
					-- Recompute tree_hash and update the lock (with the conflicted state).
					local t_hash, _ = install.tree_hash(lib_dir)
					new_lock[name] = {
						version      = new_version,
						url          = new_entry.url,
						tarball_hash = new_entry.tarball_hash,
						tree_hash    = t_hash,
						include      = include,
					}
				else
					-- Clean merge.
					info("merged %s@%s → %s cleanly", name, old_version, new_version)
					local t_hash, _ = install.tree_hash(lib_dir)
					new_lock[name] = {
						version      = new_version,
						url          = new_entry.url,
						tarball_hash = new_entry.tarball_hash,
						tree_hash    = t_hash,
						include      = include,
					}
				end
			end
		end

		-- Clean up any remaining stashes (safety net for unexpected error paths).
		for name, stash_dir in pairs(stashed) do
			os.execute(("rm -rf %q"):format(stash_dir))
		end

		-- Write the final lockfile with merged entries.
		local wf_ok, wf_err = lock.write(lock_path, new_lock)
		if not wf_ok then
			stderr("update: failed to write crescent.lock: %s", tostring(wf_err))
			return false
		end

		for _, n in ipairs(inst_result.installed) do
			-- Only report packages that weren't part of the merge set.
			if not modified[n] then
				info("updated %s", n)
			end
		end

		return overall_ok
	end  -- end do_merge

	-- ── Standard update (no --merge) ──────────────────────────────────────────
	-- Drop lock entries for the target set so install re-resolves them.
	if target then
		if entries[target] then
			entries[target] = nil
			local w_ok, w_err = lock.write(lock_path, entries)
			if not w_ok then
				stderr("update: failed to write crescent.lock: %s", tostring(w_err))
				return false
			end
			info("unpinned %s, re-resolving...", target)
		else
			info("update: %s is not in the lockfile, will resolve fresh", target)
		end
	else
		-- Drop all entries — full re-resolve
		if path_exists(lock_path) then
			local w_ok, w_err = lock.write(lock_path, {})
			if not w_ok then
				stderr("update: failed to reset crescent.lock: %s", tostring(w_err))
				return false
			end
			info("unpinned all packages, re-resolving...")
		end
	end

	-- Re-run install (no frozen — we want fresh resolution).
	-- --overwrite maps to force=true (discards local changes).
	local opts_copy = {
		frozen   = false,
		force    = do_overwrite or parsed.force,
		registry = parsed.registry,
		jobs     = parsed.jobs,
		verbose  = parsed.verbose,
	}
	local result = install.run(project_dir, opts_copy)

	for _, n in ipairs(result.installed) do
		info("updated %s", n)
	end
	for _, n in ipairs(result.skipped) do
		if parsed.verbose then
			info("unchanged %s", n)
		end
	end

	if not result.ok then
		for _, e in ipairs(result.errors) do
			stderr("%s", e)
		end
		return false
	end

	return true
end

--- cr eject <name>
-- Removes <name> from crescent.lock (and pkg.lua deps if present), but leaves
-- lib/<name>/ untouched. After eject the package manager no longer manages
-- that directory — it is owned by the project.
local function cmd_eject(project_dir, parsed)
	local name = parsed.args[1]
	if not name then
		stderr("eject: missing package name")
		stderr("usage: cr eject <name>")
		return false
	end

	local lock_path = project_dir .. "/crescent.lock"

	-- Must be in lockfile to eject
	if not path_exists(lock_path) then
		stderr("eject: no crescent.lock found")
		return false
	end

	local entries, l_err = lock.load(lock_path)
	if not entries then
		stderr("eject: failed to parse crescent.lock: %s", tostring(l_err))
		return false
	end

	if not entries[name] then
		stderr("eject: %q is not in crescent.lock", name)
		return false
	end

	entries[name] = nil
	local w_ok, w_err = lock.write(lock_path, entries)
	if not w_ok then
		stderr("eject: failed to write crescent.lock: %s", tostring(w_err))
		return false
	end

	-- Also remove from pkg.lua deps if present. Warn if not found there.
	local pkg_path = project_dir .. "/pkg.lua"
	if path_exists(pkg_path) then
		local m, _ = manifest.load(pkg_path)
		if m then
			m.deps = m.deps or {}
			if m.deps[name] then
				m.deps[name] = nil
				manifest.write(pkg_path, m)  -- ignore write errors; lock already updated
			else
				io.stderr:write(("warning: %q is not in pkg.lua deps (lockfile entry removed anyway)\n"):format(name))
			end
		end
	end

	info("ejected %s — lib/%s/ is now yours to own", name, name)
	return true
end

--- cr diff <name>
-- Diffs lib/<name>/ against ~/.crescent/cache/<name>@<version>/ for each file
-- present in lib/<name>/. No network required — the cache holds the original
-- extracted tree from install time.
--
-- Only files currently present in lib/<name>/ are diffed; files that were
-- excluded by the install glob are not shown (they are absent from lib/ by design).
--
-- Exit semantics: returns true if no differences, false on differences or error.
local function cmd_diff(project_dir, parsed)
	local name = parsed.args[1]
	if not name then
		stderr("diff: missing package name")
		stderr("usage: cr diff <name>")
		return false
	end

	local lock_path = project_dir .. "/crescent.lock"
	if not path_exists(lock_path) then
		stderr("diff: no crescent.lock found")
		return false
	end

	local entries, l_err = lock.load(lock_path)
	if not entries then
		stderr("diff: failed to parse crescent.lock: %s", tostring(l_err))
		return false
	end

	local entry = entries[name]
	if not entry then
		stderr("diff: %q is not in crescent.lock", name)
		return false
	end

	local cdir = cache_root() .. "/" .. name .. "@" .. entry.version
	if not path_exists(cdir) then
		stderr("diff: cache entry for %s@%s not found — cannot diff (try reinstalling)", name, entry.version)
		return false
	end

	local lib_dir = project_dir .. "/lib/" .. name
	if not path_exists(lib_dir) then
		stderr("diff: lib/%s/ does not exist (package not installed locally)", name)
		return false
	end

	-- Walk lib/<name>/ and diff each file against its counterpart in the cache.
	-- This avoids showing spurious deletions for files excluded by the install glob.
	local find_fh = io.popen(("find %q -type f | sort"):format(lib_dir), "r")
	if not find_fh then
		stderr("diff: failed to enumerate lib/%s/", name)
		return false
	end
	local lib_files = find_fh:read("*a")
	find_fh:close()

	-- Normalise lib_dir for stripping prefix
	local lib_prefix = lib_dir:gsub("/$", "") .. "/"
	local any_diff = false

	for abs_path in lib_files:gmatch("[^\n]+") do
		if abs_path ~= "" then
			local rel = abs_path
			if abs_path:sub(1, #lib_prefix) == lib_prefix then
				rel = abs_path:sub(#lib_prefix + 1)
			end
			local cache_path = cdir .. "/" .. rel
			-- diff the two files; exit code 0 = same, 1 = differ
			local fh = io.popen(("diff --unified %q %q 2>&1"):format(cache_path, abs_path), "r")
			if fh then
				local output = fh:read("*a")
				fh:close()
				if output ~= "" then
					io.stdout:write(output)
					if not output:match("\n$") then
						io.stdout:write("\n")
					end
					any_diff = true
				end
			end
		end
	end

	-- Return false (exit 1) when there are differences, true (exit 0) when clean.
	return not any_diff
end

--- cr publish [--dry-run] [--skip-check]
local function cmd_publish(project_dir, parsed)
	-- ── phantom dep lint (skipped when --skip-check is passed) ────────────────
	if not parsed.skip_check then
		local check_result = check.scan(project_dir)
		for _, w in ipairs(check_result.warnings) do
			io.stderr:write("warning: " .. w .. "\n")
		end
		if not check_result.ok then
			local n = #check_result.phantoms
			for _, p in ipairs(check_result.phantoms) do
				io.stdout:write(("phantom dep: lib/%s required in %s:%d but not declared in pkg.lua\n")
					:format(p.name, p.file, p.line))
			end
			stderr("publish aborted: %d phantom dep(s) found — declare them in pkg.lua or use cr check to review", n)
			return false
		end
	end

	local opts = {
		registry = parsed.registry,
		dry_run  = parsed.dry_run,
		verbose  = parsed.verbose,
	}

	local result = publish.run(project_dir, opts)

	if not result.ok then
		stderr("publish: %s", tostring(result.error))
		return false
	end

	if opts.dry_run then
		info("dry-run: %s@%s packed (%s)", result.name, result.version, result.checksum)
	else
		info("published %s@%s (%s)", result.name, result.version, result.checksum)
	end

	return true
end

--- cr check [--strict]
-- Scans the current package for phantom dependencies.
-- A phantom dep is a require("lib.X") call in source that is not declared in
-- pkg.lua.  Without --strict, prints warnings and exits 0.  With --strict,
-- exits 1 if any phantoms are found.
local function cmd_check(project_dir, parsed)
	local result = check.scan(project_dir)

	for _, w in ipairs(result.warnings) do
		io.stderr:write("warning: " .. w .. "\n")
	end

	if #result.phantoms == 0 then
		info("check: no phantom dependencies found")
		return true
	end

	for _, p in ipairs(result.phantoms) do
		io.stdout:write(("phantom dep: lib/%s required in %s:%d but not declared in pkg.lua\n")
			:format(p.name, p.file, p.line))
	end

	local n = #result.phantoms
	if parsed.strict then
		stderr("check: %d phantom dep(s) found — declare them in pkg.lua", n)
		return false
	else
		io.stdout:write(("check: %d phantom dep(s) found — use cr check --strict to enforce\n"):format(n))
		return true
	end
end

--- cr info <name>
local function cmd_info(project_dir, parsed)
	local name = parsed.args[1]
	if not name then
		stderr("info: missing package name")
		stderr("usage: cr info <name>")
		return false
	end

	local registry = parsed.registry:gsub("/$", "")
	local url = registry .. "/index.json"

	local body, fetch_err = http_get(url)
	if not body then
		stderr("info: failed to fetch registry index: %s", tostring(fetch_err))
		return false
	end

	-- Minimal parse: find the entry for `name`
	-- Pattern: "name": { ... }
	-- Use install's exposed _parse_index if available, else a quick search.
	local idx, parse_err = install._parse_index(body)
	if not idx then
		stderr("info: failed to parse registry index: %s", tostring(parse_err))
		return false
	end

	local pkg = idx[name]
	if not pkg then
		stderr("info: package %q not found in registry", name)
		return false
	end

	info("package: %s", name)
	info("latest:  %s", tostring(pkg.latest))
	if pkg.versions and #pkg.versions > 0 then
		info("versions:")
		-- Print in reverse order (newest first) — versions are presumed ascending in registry
		for i = #pkg.versions, 1, -1 do
			info("  %s", pkg.versions[i])
		end
	else
		info("versions: (none)")
	end

	return true
end

-- ── main dispatcher ───────────────────────────────────────────────────────────

local COMMANDS = {
	install = cmd_install,
	add     = cmd_add,
	remove  = cmd_remove,
	update  = cmd_update,
	eject   = cmd_eject,
	diff    = cmd_diff,
	info    = cmd_info,
	publish = cmd_publish,
	check   = cmd_check,
}

local USAGE = [[
usage: cr <command> [options]

commands:
  install [--frozen] [--force] [--workspace]
                                        install all deps from pkg.lua / lockfile
  add <name[@version]>                  add dep to pkg.lua, install, update lockfile
  remove <name>                         remove dep, delete lib/<name>/, update lockfile
  update [name] [--merge|--overwrite]   re-resolve to latest matching version(s)
  eject <name>                          remove from lockfile; leave lib/<name>/ unmanaged
  diff <name>                           diff lib/<name>/ against cached version (no network)
  info <name>                           show package info from registry
  publish [--dry-run] [--skip-check]    publish package to registry
  check [--strict] [--workspace]        scan for phantom dependencies

global options:
  --verbose                     enable verbose logging
  --registry=URL                registry base URL (default: https://pkg.crescent.run)
  --jobs=N                      parallel jobs (default: CPU count; 1 = sequential)
  --force                       overwrite local modifications to lib/ (install only)
  --workspace                   operate at workspace root (auto-detected from workspace.lua)
  --merge                       three-way merge local edits with new version (update only)
  --overwrite                   discard local modifications before update (update only)
  --dry-run                     pack but do not upload (publish only)
  --strict                      exit 1 if phantoms found (check only)
  --skip-check                  skip phantom dep lint (publish only)
]]

--- Main entry point. argv is the arg table (1-indexed positional args).
-- Returns true on success, false on failure.
function M.main(argv)
	-- Determine project dir from CWD
	local project_dir = "."

	local parsed = M.parse_args(argv)

	if not parsed.command then
		io.stderr:write(USAGE)
		return false
	end

	local handler = COMMANDS[parsed.command]
	if not handler then
		stderr("unknown command %q", parsed.command)
		io.stderr:write(USAGE)
		return false
	end

	local ok, result = pcall(handler, project_dir, parsed)

	if not ok then
		stderr("internal error: %s", tostring(result))
		return false
	end

	return result == true
end

-- ── entry point ───────────────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:match("pkg/cli%.lua$") then
	os.exit(M.main(arg) and 0 or 1)
end

return M
