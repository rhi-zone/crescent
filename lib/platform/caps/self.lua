-- lib/platform/caps/self.lua
-- self_cap(app, opts?)       -> cap_table, revoke_fn   (read-only)
-- self_write_cap(app, opts?) -> cap_table, revoke_fn   (read + atomic metadata write-back)
--
-- Both caps give a sandboxed app read access to its own package contents
-- (image metadata chunks, tarball entries, identity). The `self_write` variant
-- additionally exposes `write_metadata(keyword, bytes)` which rewrites the app's
-- image metadata chunk atomically (temp file in same directory, fsync, rename).
--
-- Capability API (passed to sandbox as caps.self / caps.self_write):
--   cap.app_id                        -> string | nil
--   cap.metadata(keyword)             -> string | nil
--   cap.entries()                     -> string[]
--   cap.entry(path)                   -> string | nil
--   cap.write_metadata(keyword, val)  -> true | nil, err   (self_write only)
--
-- Tar-only apps (no image container) have `app.chunks == nil`; write_metadata
-- returns `nil, "app has no image container"` in that case.
--
-- NOTE: `metadata()` currently reads tEXt chunks via png.get_text, but
-- `write_metadata()` writes iTXt chunks (ccv2 uses iTXt, and the platform-design
-- spec names iTXt as the chunk type). JPEG/WebP write support is a follow-up.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local png = require("lib.png")
local tar = require("lib.tar")

local M = {}

-- ── Shared helpers ───────────────────────────────────────────────────────────

-- read_app_file(app, check_revoked) -> string | nil, err
-- Opens app.path, reads all bytes, closes, returns bytes or nil+err.
--: ({ path: string, ... }, () -> (nil, string) | nil) -> (string | nil, string | nil)
local function read_app_file(app, check_revoked)
	local err_nil, err_msg = check_revoked()
	if err_msg then return err_nil, err_msg end
	if not app.path then return nil, "app has no file path" end
	local f0, ferr = io.open(app.path, "rb")
	if not f0 then return nil, "self.read: " .. tostring(ferr) end
	local f = assert(f0)
	local bytes = f:read("*a")
	f:close()
	return bytes
end

-- ── Atomic file write ────────────────────────────────────────────────────────
-- Write `bytes` to `path` atomically: write to a sibling temp file, close
-- (flushing stdio buffers to the kernel), then rename over `path`. rename(2)
-- is atomic within a single filesystem on POSIX and on NTFS (MoveFileEx with
-- MOVEFILE_REPLACE_EXISTING — which os.rename uses on Windows). A crash
-- between write and rename leaves the original `path` untouched.
--
-- We intentionally do not call fsync(2) here: LuaJIT has no portable fsync
-- binding in this codebase, and the spec calls for atomic replacement of the
-- app file against partial writes, which rename guarantees. Durability across
-- a hard power loss (fsync-before-rename) is a follow-up if needed.
--: (string, string) -> (boolean | nil, string | nil)
local function atomic_write(path, bytes)
	-- Randomised temp name in the same directory so rename is same-fs.
	local rand = string.format("%d-%d", os.time(), math.random(1, 1073741824))
	local tmp = path .. ".tmp." .. rand
	local f0, ferr = io.open(tmp, "wb")
	if not f0 then return nil, "self_write: open temp failed: " .. tostring(ferr) end
	local f = assert(f0)
	local ok_w, werr = f:write(bytes)
	if not ok_w then
		f:close()
		os.remove(tmp)
		return nil, "self_write: write temp failed: " .. tostring(werr)
	end
	local ok_c, cerr = f:close()
	if not ok_c then
		os.remove(tmp)
		return nil, "self_write: close temp failed: " .. tostring(cerr)
	end
	local ok_r, rerr = os.rename(tmp, path)
	if not ok_r then
		os.remove(tmp)
		return nil, "self_write: rename failed: " .. tostring(rerr)
	end
	return true
end

-- self_cap(app, opts?) -> cap_table, revoke_fn
--: ({ path: string, chunks: { type: string, data: string }[] | nil, entries: { name: string, data: string }[], manifest: table }, { app_id: string | nil } | nil) -> (table, () -> nil)
function M.self_cap(app, opts)
	local revoked = false
	local app_id = opts and opts.app_id

	local function check_revoked()
		if revoked then return nil, "capability revoked" end
	end

	local cap = {
		app_id = app_id,

		metadata = function(keyword)
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			if not app.chunks then return nil end
			-- Check tEXt first (legacy), then iTXt (ccv2 / spec). Either form
			-- is a valid carrier for app metadata; whichever the producer used
			-- is what we return.
			local v = png.get_text(app.chunks, keyword)
			if v ~= nil then return v end
			return png.get_itxt(app.chunks, keyword)
		end,

		entries = function()
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			local paths = {}
			for i = 1, #app.entries do
				paths[i] = app.entries[i].name
			end
			return paths
		end,

		entry = function(path)
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			return tar.get(app.entries, path)
		end,

		-- read() -> string | nil, err
		-- Returns the raw bytes of the app file (PNG/tar.gz) from disk.
		-- Useful for exporting the card as a self-contained file.
		read = function() return read_app_file(app, check_revoked) end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

-- self_write_cap(app, opts?) -> cap_table, revoke_fn
-- Superset of self_cap that also exposes write_metadata(keyword, bytes).
--: ({ path: string, chunks: { type: string, data: string }[] | nil, entries: { name: string, data: string }[], manifest: table }, { app_id: string | nil } | nil) -> (table, () -> nil)
function M.self_write_cap(app, opts)
	local revoked = false
	local app_id = opts and opts.app_id

	local function check_revoked()
		if revoked then return nil, "capability revoked" end
	end

	local cap = {
		app_id = app_id,

		metadata = function(keyword)
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			if not app.chunks then return nil end
			local v = png.get_text(app.chunks, keyword)
			if v ~= nil then return v end
			return png.get_itxt(app.chunks, keyword)
		end,

		entries = function()
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			local paths = {}
			for i = 1, #app.entries do
				paths[i] = app.entries[i].name
			end
			return paths
		end,

		entry = function(path)
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			return tar.get(app.entries, path)
		end,

		-- read() -> string | nil, err
		-- Returns the raw bytes of the app file (PNG/tar.gz) from disk.
		read = function() return read_app_file(app, check_revoked) end,

		-- write_metadata(keyword, bytes) -> true | nil, err
		-- Replaces (or inserts) the iTXt chunk named `keyword` in the app's
		-- image and writes the new PNG atomically over app.path. Updates
		-- app.chunks in-place so subsequent metadata() calls see the new value.
		write_metadata = function(keyword, bytes)
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			if not app.chunks then
				return nil, "app has no image container"
			end
			if type(keyword) ~= "string" or keyword == "" then
				return nil, "write_metadata: keyword must be a non-empty string"
			end
			if type(bytes) ~= "string" then
				return nil, "write_metadata: bytes must be a string"
			end
			local new_chunks = png.set_itxt(app.chunks, keyword, bytes, { language_tag = "" })
			local new_png = png.write(new_chunks)
			local ok, werr = atomic_write(app.path, new_png)
			if not ok then return nil, werr end
			-- Swap in the new chunks only after the on-disk write succeeded.
			app.chunks = new_chunks
			return true
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
