if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/check.lua — phantom dependency linting for crescent packages
--
-- A "phantom dependency" is a require("lib.X") call in a package's source
-- that is not declared in that package's own pkg.lua.  It works at runtime
-- only because some other package happens to have installed lib/X/.  If that
-- other package is removed the undeclared dep silently breaks.
--
-- Usage:
--   local check = require("lib.pkg.check")
--   local result = check.scan(pkg_dir)
--   -- result = { ok=bool, phantoms=[{name,file,line,require_path},...], warnings=[string,...] }

local manifest = require("lib.pkg.manifest")

local M = {}

-- ── pure-Lua directory walker ─────────────────────────────────────────────────
-- Walk dir recursively; call fn(filepath) for each regular *.lua file found.
-- Uses io.popen("find") — same pattern as the rest of lib/pkg/*.lua.
local function walk_lua_files(dir, fn)
	local fh = io.popen(("find %q -type f -name '*.lua' | sort"):format(dir), "r")
	if not fh then
		return nil, "failed to enumerate " .. dir
	end
	local out = fh:read("*a")
	fh:close()
	for path in out:gmatch("[^\n]+") do
		if path ~= "" then
			fn(path)
		end
	end
	return true
end

-- ── require scanner ───────────────────────────────────────────────────────────
-- Scan source text for require("lib.X...") or require "lib.X..." calls.
-- Returns a list of { name=string, line=number, require_path=string }.
--
-- Patterns matched:
--   require("lib.foo")         require("lib.foo.v2.bar")
--   require('lib.foo')         require 'lib.foo'
--   require("lib.foo.v2")      require "lib.foo"
--
-- We extract only the first path component after "lib." — that is the package
-- name (e.g. "foo" from "lib.foo.v2.util").
local function scan_requires(source)
	local results = {}

	-- Two forms: with parens and without.  Both single and double quotes.
	-- We match the whole require string so we can record the full require_path.
	--
	-- Pattern explanation:
	--   require%s*%(?%s*   — "require" optionally followed by whitespace and "("
	--   (["'])             — opening quote (captured as %2)
	--   (lib%.[^"'%s]+)    — the module path starting with "lib." (captured as %3)
	--   %2                 — matching closing quote
	--
	-- We iterate line-by-line so we can record accurate line numbers.

	local line_num = 0
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		line_num = line_num + 1

		-- Skip full-line comments (heuristic: lines starting with optional
		-- whitespace then "--").  Inline comments are not stripped — a require
		-- inside an inline comment is unlikely and the false-positive rate is
		-- negligible; parsers in this codebase are heuristic by convention.
		if not line:match("^%s*%-%-") then
			-- Match both paren and no-paren forms in the same pass.
			-- We use a single pattern that handles both:
			--   require%s*%(  — with paren
			--   require%s+    — without paren (must have whitespace before quote)
			-- Merge into one scan by matching require followed by optional (
			-- then a quote character.
			local pos = 1
			while true do
				-- Find next "require" in the line.
				local rs, re = line:find("require", pos, true)
				if not rs then break end

				-- Skip past "require"
				local after = re + 1

				-- Optional whitespace
				while after <= #line and line:sub(after, after):match("%s") do
					after = after + 1
				end

				-- Optional opening paren
				local had_paren = false
				if after <= #line and line:sub(after, after) == "(" then
					had_paren = true
					after = after + 1
					-- Optional whitespace after paren
					while after <= #line and line:sub(after, after):match("%s") do
						after = after + 1
					end
				end

				-- Opening quote
				local q = line:sub(after, after)
				if q == '"' or q == "'" then
					after = after + 1
					-- Collect module path up to the matching closing quote
					local path_start = after
					while after <= #line and line:sub(after, after) ~= q do
						after = after + 1
					end
					local require_path = line:sub(path_start, after - 1)

					-- Only care about lib.* paths
					if require_path:sub(1, 4) == "lib." then
						-- Extract first component after "lib."
						local rest = require_path:sub(5)  -- everything after "lib."
						local pkg_name = rest:match("^([a-zA-Z0-9_][a-zA-Z0-9_%-]*)")
						if pkg_name then
							results[#results + 1] = {
								name         = pkg_name,
								line         = line_num,
								require_path = require_path,
							}
						end
					end
				end

				-- Advance past this occurrence to find the next one.
				pos = re + 1
			end
		end
	end

	return results
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Scan a package directory for phantom dependencies.
--
-- pkg_dir  path to the package root (contains pkg.lua + *.lua source files)
--
-- Returns:
--   {
--     ok       = bool,   -- true iff no phantoms found
--     phantoms = {       -- one entry per undeclared require
--       { name=string, file=string, line=number, require_path=string }, ...
--     },
--     warnings = { string, ... },
--   }
function M.scan(pkg_dir)
	local result = { ok = true, phantoms = {}, warnings = {} }

	-- ── 1. Load pkg.lua ───────────────────────────────────────────────────────
	local pkg_path = pkg_dir .. "/pkg.lua"
	local m, m_err = manifest.load(pkg_path)
	if not m then
		result.ok = false
		result.warnings[#result.warnings + 1] = "could not load pkg.lua: " .. tostring(m_err)
		return result
	end

	local own_name = m.name
	local deps     = m.deps or {}

	-- Build a set of declared dep names for O(1) lookup.
	local declared = {}
	for dep_name in pairs(deps) do
		declared[dep_name] = true
	end

	-- ── 2. Walk *.lua files, skipping *_test.lua ──────────────────────────────
	local walk_ok, walk_err = walk_lua_files(pkg_dir, function(filepath)
		-- Skip test files.
		if filepath:match("_test%.lua$") then
			return
		end

		-- Read the file.
		local fh, open_err = io.open(filepath, "r")
		if not fh then
			result.warnings[#result.warnings + 1] =
				"could not read " .. filepath .. ": " .. tostring(open_err)
			return
		end
		local source = fh:read("*a")
		fh:close()

		-- ── 3 & 4. Scan requires and classify ─────────────────────────────────
		local requires = scan_requires(source)
		for _, req in ipairs(requires) do
			local pkg_name = req.name

			-- Self-require: skip.
			if pkg_name == own_name then
				-- nothing
			elseif declared[pkg_name] then
				-- Declared dep: ok.
			else
				-- Phantom.
				result.ok = false
				result.phantoms[#result.phantoms + 1] = {
					name         = pkg_name,
					file         = filepath,
					line         = req.line,
					require_path = req.require_path,
				}
			end
		end
	end)

	if not walk_ok then
		result.ok = false
		result.warnings[#result.warnings + 1] = "directory walk failed: " .. tostring(walk_err)
	end

	return result
end

return M
