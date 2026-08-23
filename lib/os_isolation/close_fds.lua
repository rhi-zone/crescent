-- lib/os_isolation/close_fds.lua
-- Bulk file-descriptor hygiene for fork()-without-exec children.
--
-- WHY THIS EXISTS. FD_CLOEXEC is not a fork-time flag: it fires on exec(),
-- and a fork()-without-exec child never execs. Such a child therefore
-- inherits EVERY descriptor its parent held open, including descriptors the
-- parent's own callers opened and that the forking code has no name for --
-- pipe write ends belonging to an outer runner, sockets belonging to a
-- sibling, and so on. Holding a pipe's write end open is indistinguishable
-- (to the reader) from "the writer is still alive": the reader never sees
-- EOF. A child that keeps such a descriptor by accident can wedge a process
-- that has nothing to do with it.
--
-- Manual per-site close() calls cannot fix this on their own. A fork site
-- can only close the descriptors it created itself; the leaked ones come
-- from outer scope by construction. Hence a sweep: name what the child
-- needs, and close everything else.
--
-- API:
--   close_fds.close_fds_except(keep_fds) -> true | (nil, errmsg)
--     keep_fds is an array of integer descriptors to leave open. EVERY
--     other descriptor in the process is closed, starting from 0 -- the
--     standard descriptors are NOT implicitly preserved. A child that wants
--     stdin/stdout/stderr must say so: close_fds_except({0, 1, 2, mypipe}).
--     This is deliberate. An implicit "0,1,2 are special" rule would be a
--     hidden policy the caller cannot see or override, and children that
--     dup2() their real output elsewhere genuinely do want 1 and 2 gone.
--     Closing an already-closed or never-opened descriptor is not an error
--     and is silently ignored -- EBADF is the expected case for most of the
--     range, not a failure. The (nil, errmsg) return is reserved for the
--     sweep mechanism itself failing (e.g. the descriptor range could not be
--     determined at all), which leaves the caller genuinely unswept.
--
--   close_fds._tier -> "close_range" | "proc" | "scan"
--     Which implementation close_fds_except is bound to.
--
--   close_fds.close_range_impl / .proc_impl / .scan_impl
--     The individual implementations, or nil where unavailable on this
--     host. Exposed so the parity test can exercise every tier that this
--     machine can actually run, rather than only the fastest one.
--
-- TIERS (fastest first; each is a real independent implementation, selected
-- at load time by probing, never by assuming a kernel or libc version):
--
--   close_range  close_range(2), Linux 5.9+. One syscall per contiguous gap
--                between kept descriptors -- so a sweep with no kept
--                descriptors is a single syscall regardless of how many are
--                open. Probed by actually calling it on a high, certainly-
--                empty range: a kernel without it answers ENOSYS.
--   proc         Enumerate /proc/self/fd (Linux) and close exactly the
--                descriptors that are actually open. Touches only real
--                descriptors, so it does not care how high the descriptor
--                limit is. Uses getdents64(2) rather than opendir/readdir so
--                it needs no `struct dirent` typedef, which would collide
--                with other modules' cdefs and make the tier unavailable
--                merely because some unrelated module loaded first.
--   scan         close() every descriptor from 0 to sysconf(_SC_OPEN_MAX)-1.
--                Works on every POSIX host including non-Linux ones. Cost is
--                one syscall per descriptor slot, and the slot count is the
--                soft RLIMIT_NOFILE, which can be large. It is not clamped:
--                a clamp would silently leave descriptors above the cap
--                open, and a last-resort tier that is quietly incorrect is
--                worse than a slow one.
--
-- BOTH Linux tiers reach their syscall through resolve_syscall() below, which
-- prefers the libc wrapper and falls back to raw syscall(2). That fallback is
-- not belt-and-braces: the LuaJIT crescent vendors is linked against musl,
-- and musl exports neither close_range nor getdents64 as a symbol (verified
-- on this tree -- ffi.C lookup raises "Symbol not found" for both). Without
-- the raw path, both fast tiers would be permanently inert on crescent's own
-- shipping runtime, and the sweep would always land on `scan`.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")

pcall(ffi.cdef, [[
	int close(int fd);
	long sysconf(int name);
	int open(const char *pathname, int flags, ...);
	long syscall(long number, ...);
]])

local SC_OPEN_MAX = 4      -- <bits/confname.h>, Linux
local O_RDONLY    = 0
local O_DIRECTORY = 0x10000 -- <asm-generic/fcntl.h>, Linux

-- Raw syscall numbers, keyed by jit.arch, for the calls whose libc wrapper
-- may be absent. ONLY architectures whose numbers have been verified by
-- actually issuing the call on that hardware belong in this table. Adding an
-- entry from memory or from a header read on a different architecture is a
-- guess, and a wrong syscall number is not a failed lookup -- it silently
-- invokes some unrelated syscall. An architecture that is absent here simply
-- has no raw path, and the tier degrades to the next one, which is correct
-- behaviour rather than a gap.
--: { [string]: { [string]: integer } }
local SYSCALL_NR = {
	-- verified on this tree: close_range returned 0 for an empty high range,
	-- getdents64 returned a plausible byte count for /proc/self/fd.
	x64 = { close_range = 436, getdents64 = 217 },
}

--[[A sweep implementation: given the descriptors to keep, close the rest.]]
--:: fd_sweep = (keep_fds: { [integer]: integer }) -> (true | nil, string | nil)

--[[A resolved three-argument syscall entry point (libc wrapper, or raw).]]
--:: raw_syscall = (a: unknown, b: unknown, c: unknown) -> number

-- Both calls this module needs take exactly three arguments, so the resolved
-- callable is fixed-arity rather than variadic. That is not just tidiness:
-- syscall(2) is declared `long syscall(long, ...)`, and a Lua number passed
-- through a C vararg is promoted to DOUBLE, not to long. The kernel then
-- reads the register file as integers and receives garbage -- and the
-- failure is silent, because the syscall still returns a plausible status
-- (an all-zeros "first" and "last" makes close_range(2) a successful no-op).
-- Every integer argument on the raw path is therefore cast explicitly.
--: (string) -> (raw_syscall | nil)
local function resolve_syscall(name)
	-- Prefer the libc wrapper where the platform provides one: it carries a
	-- real prototype, so the FFI converts arguments correctly on its own.
	local have_symbol = pcall(function() return ffi.C[name] end)
	if have_symbol then
		return function(a, b, c) return tonumber(ffi.C[name](a, b, c)) or -1 end
	end
	local arch_table = SYSCALL_NR[(jit and jit.arch) or ""]
	local nr = arch_table and arch_table[name] or nil
	if not nr then return nil end
	local have_syscall = pcall(function() return ffi.C.syscall end)
	if not have_syscall then return nil end
	--: (unknown) -> unknown
	local function as_arg(v)
		if type(v) == "number" then return ffi.cast("long", v) end
		return v
	end
	return function(a, b, c)
		return tonumber(ffi.C.syscall(ffi.cast("long", nr), as_arg(a), as_arg(b), as_arg(c))) or -1
	end
end

local M = {}

-- ── kept-descriptor bookkeeping ──────────────────────────────────────────────

-- Turn the caller's keep list into a set plus a sorted copy. The sorted copy
-- is what lets the close_range tier walk the gaps between kept descriptors.
--: ({ [integer]: integer }) -> ({ [integer]: boolean }, { [integer]: integer })
local function keep_set_and_sorted(keep_fds)
	--: { [integer]: boolean }
	local set = {}
	--: { [integer]: integer }
	local sorted = {}
	for _, fd in ipairs(keep_fds) do
		if not set[fd] then
			set[fd] = true
			sorted[#sorted + 1] = fd
		end
	end
	table.sort(sorted)
	return set, sorted
end

-- The half-open gaps between kept descriptors, as inclusive [lo, hi] pairs
-- covering [0, max_fd] minus the kept set. Shared by every tier that works
-- in ranges rather than in enumerated descriptors.
--: ({ [integer]: integer }, number) -> { [integer]: { [integer]: number } }
local function gaps(sorted, max_fd)
	--: { [integer]: { [integer]: number } }
	local out = {}
	--: number
	local lo = 0
	for _, fd in ipairs(sorted) do
		if fd > max_fd then break end
		if fd > lo then out[#out + 1] = { lo, fd - 1 } end
		lo = fd + 1
	end
	if lo <= max_fd then out[#out + 1] = { lo, max_fd } end
	return out
end

-- ── tier: close_range(2) ─────────────────────────────────────────────────────

local UINT_MAX = 4294967295

--: () -> (fd_sweep | nil)
local function build_close_range_impl()
	pcall(ffi.cdef, [[
		int close_range(unsigned int first, unsigned int last, unsigned int flags);
	]])
	local close_range = resolve_syscall("close_range")
	if not close_range then return nil end

	-- Probe with a real call. A pre-5.9 kernel answers ENOSYS. The probed
	-- range is high enough to be certainly empty, so a success closes
	-- nothing.
	local probed, rc = pcall(close_range, UINT_MAX - 1, UINT_MAX, 0)
	if not probed or rc ~= 0 then return nil end

	--: ({ [integer]: integer }) -> (true | nil, string | nil)
	return function(keep_fds)
		local _, sorted = keep_set_and_sorted(keep_fds)
		for _, range in ipairs(gaps(sorted, UINT_MAX)) do
			-- A failure here is EINVAL on a malformed range or EMFILE
			-- pressure, never "that descriptor was not open" -- close_range
			-- ignores gaps by design. Nothing actionable, so nothing to
			-- report: the sweep is best-effort per descriptor.
			close_range(range[1], range[2], 0)
		end
		return true
	end
end

-- ── tier: /proc/self/fd enumeration ──────────────────────────────────────────

-- linux_dirent64 as getdents64(2) lays it out. Named uniquely so that
-- loading this module can never collide with another module's `struct
-- dirent` cdef -- the sweep must not become unavailable just because some
-- unrelated directory-listing library happened to load first.
local DIRENT_NAME_OFFSET = 19

--: () -> (fd_sweep | nil)
local function build_proc_impl()
	pcall(ffi.cdef, [[
		typedef struct crescent_close_fds_dirent64 {
			uint64_t       d_ino;
			int64_t        d_off;
			unsigned short d_reclen;
			unsigned char  d_type;
			char           d_name[1];
		} crescent_close_fds_dirent64;

		long getdents64(int fd, void *dirp, unsigned long count);
	]])
	local getdents64 = resolve_syscall("getdents64")
	if not getdents64 then return nil end

	-- Probe: /proc must be mounted AND getdents64 must work. Both are checked
	-- by doing the real thing once, not by testing jit.os.
	local probe_fd = tonumber(ffi.C.open("/proc/self/fd", O_RDONLY + O_DIRECTORY)) or -1
	if probe_fd < 0 then return nil end
	local probe_buf = ffi.new("uint8_t[?]", 256)
	local probed, probe_n = pcall(getdents64, probe_fd, probe_buf, 256)
	ffi.C.close(probe_fd)
	if not probed or (probe_n or -1) < 0 then return nil end

	--: ({ [integer]: integer }) -> (true | nil, string | nil)
	return function(keep_fds)
		local set = keep_set_and_sorted(keep_fds)

		local fd = tonumber(ffi.C.open("/proc/self/fd", O_RDONLY + O_DIRECTORY)) or -1
		if fd < 0 then return nil, "close_fds: could not open /proc/self/fd" end

		-- Collect the whole listing BEFORE closing anything. The directory
		-- descriptor itself appears in the listing, and closing descriptors
		-- mid-enumeration would invalidate the very handle we are reading.
		--: { [integer]: number }
		local found = {}
		local buf_len = 65536
		local buf = ffi.new("uint8_t[?]", buf_len)
		while true do
			local n = getdents64(fd, buf, buf_len)
			if n <= 0 then break end
			--: number
			local off = 0
			while off < n do
				local ent = ffi.cast("crescent_close_fds_dirent64 *", buf + off)
				local name = ffi.string(ffi.cast("const char *", buf + off + DIRENT_NAME_OFFSET))
				local num = tonumber(name)
				if num then found[#found + 1] = num end
				local reclen = tonumber(ent.d_reclen) or 0
				if reclen <= 0 then break end
				off = off + reclen
			end
		end
		ffi.C.close(fd)

		for _, candidate in ipairs(found) do
			if not set[candidate] and candidate ~= fd then
				ffi.C.close(candidate)
			end
		end
		return true
	end
end

-- ── tier: linear scan ────────────────────────────────────────────────────────

--: ({ [integer]: integer }) -> (true | nil, string | nil)
local function scan_impl(keep_fds)
	local set = keep_set_and_sorted(keep_fds)
	local max_open = tonumber(ffi.C.sysconf(SC_OPEN_MAX)) or -1
	if max_open <= 0 then
		return nil, "close_fds: sysconf(_SC_OPEN_MAX) did not report a descriptor limit"
	end
	for fd = 0, max_open - 1 do
		if not set[fd] then ffi.C.close(fd) end
	end
	return true
end

-- ── tier selection ───────────────────────────────────────────────────────────

M.scan_impl = scan_impl

local ok_cr, cr_impl = pcall(build_close_range_impl)
M.close_range_impl = (ok_cr and cr_impl) or nil

local ok_proc, proc_impl = pcall(build_proc_impl)
M.proc_impl = (ok_proc and proc_impl) or nil

if M.close_range_impl then
	M.close_fds_except = M.close_range_impl
	M._tier = "close_range"
elseif M.proc_impl then
	M.close_fds_except = M.proc_impl
	M._tier = "proc"
else
	M.close_fds_except = M.scan_impl
	M._tier = "scan"
end

return M
