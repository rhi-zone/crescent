local ffi = require("ffi")

--:: declare register_ffi_module = ((string) -> nil) | nil
--[[@diagnostic disable-next-line: undefined-global]]
if register_ffi_module then register_ffi_module("lib.fs.dir_list") end

local mod = {}

-- FIXME: refactor directory listing out?
-- it'd result in duplication of work tho
-- (you can't check whether a file is a directory...)
if ffi.os == "Linux" then
	if ffi.arch == "x64" then
		ffi.cdef [[
			// https://elixir.bootlin.com/linux/latest/source/tools/include/nolibc/std.h
			typedef unsigned long dev_t;
			typedef unsigned long ino_t;
			typedef unsigned long mode_t;
			typedef signed int pid_t;
			typedef unsigned int uid_t;
			typedef unsigned int gid_t;
			typedef unsigned long nlink_t;
			typedef signed long off_t;
			typedef signed long blksize_t;
			typedef signed long blkcnt_t;
			typedef signed long time_t;
			typedef void DIR;
			// https://codebrowser.dev/glibc/glibc/sysdeps/unix/sysv/linux/bits/dirent.h.html#dirent
			struct dirent {
				ino_t d_ino;
				off_t d_off;
				unsigned short d_reclen;
				unsigned char d_type;
				char d_name[256];
			};
			// https://codebrowser.dev/glibc/glibc/sysdeps/unix/sysv/linux/x86/bits/struct_stat.h.html#stat
			/* struct stat {
				dev_t st_dev;
				ino_t st_ino;
				nlink_t st_nlink; // nlink and mode are reversed on 64-bit
				mode_t st_mode;
				uid_t st_uid;
				gid_t st_gid;
				dev_t st_rdev;
				off_t st_size;
				blksize_t st_blksize;
				blkcnt_t st_blocks;
				// https://man7.org/linux/man-pages/man3/clock_gettime.3.html
				// inlined:
				// struct timespec { time_t tv_sec; long tv_nsec; };
				// struct timespec st_atim;
				// struct timespec st_mtim;
				// struct timespec st_ctim;
				time_t st_atime;
				long st_atime_ns;
				time_t st_mtime;
				long st_mtime_ns;
				time_t st_ctime;
				long st_ctime_ns;
				long __glibc_reserved[3];
			}; */

			// https://codebrowser.dev/glibc/glibc/io/bits/types/struct_statx.h.html
			struct statx {
				uint32_t stx_mask;
				uint32_t stx_blksize;
				uint64_t stx_attributes;
				uint32_t stx_nlink;
				uint32_t stx_uid;
				uint32_t stx_gid;
				uint16_t stx_mode;
				uint16_t __statx_pad1[1];
				uint64_t stx_ino;
				uint64_t stx_size;
				uint64_t stx_blocks;
				uint64_t stx_attributes_mask;
				// `struct statx_timestamp` inlined:
				// https://codebrowser.dev/glibc/glibc/io/bits/types/struct_statx_timestamp.h.html
				int64_t stx_atime_sec;
				uint32_t stx_atime_nsec;
				int32_t __stx_atime_pad1[1];
				int64_t stx_btime_sec;
				uint32_t stx_btime_nsec;
				int32_t __stx_btime_pad1[1];
				int64_t stx_ctime_sec;
				uint32_t stx_ctime_nsec;
				int32_t __stx_ctime_pad1[1];
				int64_t stx_mtime_sec;
				uint32_t stx_mtime_nsec;
				int32_t __stx_mtime_pad1[1];
				uint32_t stx_rdev_major;
				uint32_t stx_rdev_minor;
				uint32_t stx_dev_major;
				uint32_t stx_dev_minor;
				uint64_t __statx_pad2[14];
			};

			DIR *opendir(const char *name);
			struct dirent *readdir(DIR *dirp);
			int closedir(DIR *dirp);
			// int stat(const char *restrict pathname, struct stat *restrict statbuf);
			int statx(int dirfd, const char *restrict pathname, int flags, unsigned int mask, struct statx *restrict statxbuf);
		]]

		local dir_list_ffi = ffi.C

		local stat = ffi.new("struct statx[1]")

		--: (self: { dir: cdata, path: string }) -> ({ name: string, path: string, is_dir: boolean, size: number | nil, created: number, modified: number } | nil, string | nil)
		local dir_list_iter = function(self)
			local entry = dir_list_ffi.readdir(self.dir)
			if entry == nil then
				local err = dir_list_ffi.closedir(self.dir)
				if err ~= 0 then return nil, "dir_list: could not close directory" end
				return
			end
			local file_name = ffi.string(entry.d_name)
			local file_path = self.path .. "/" .. file_name
			--[[https://codebrowser.dev/glibc/glibc/io/fcntl.h.html#_M/AT_FDCWD]]
			--[[https://codebrowser.dev/glibc/glibc/io/bits/statx-generic.h.html#_M/STATX_ALL]]
			local err = dir_list_ffi.statx(-100 --[[AT_FDCWD]], file_path, 0, 0xfff --[[STATX_ALL]], stat)
			return {
				name = file_name,
				path = file_path,
				--[[https://elixir.bootlin.com/linux/latest/source/include/uapi/linux/stat.h#L23]]
				is_dir = bit.band(stat[0].stx_mode, 0xf000) == 0x4000,
				size = err == 0 and tonumber(stat[0].stx_size) or 0,
				created = (tonumber(stat[0].stx_btime_sec) or 0) + (tonumber(stat[0].stx_btime_nsec) or 0) / 1000000000,
				modified = (tonumber(stat[0].stx_mtime_sec) or 0) + (tonumber(stat[0].stx_mtime_nsec) or 0) / 1000000000,
			}
		end

		mod.dir_list = function(path)
			path = path or "."
			if type(path) ~= "string" then return nil, "dir_list: path must be a string" end
			local dir = dir_list_ffi.opendir(path)
			if dir == nil then return nil, "dir_list: could not open directory" end
			--[[assume first two entries are . and ..]]
			dir_list_ffi.readdir(dir)
			dir_list_ffi.readdir(dir)
			return dir_list_iter, { dir = dir, path = path }
		end

		mod.dir_info = function(path)
			path = path or "."
			if type(path) ~= "string" then return nil, "dir_info: path must be a string" end
			local dir = dir_list_ffi.opendir(path)
			if dir == nil then return nil, "dir_info: could not open directory" end
			local result = dir_list_iter({ dir = dir, path = path })
			dir_list_ffi.closedir(dir)
			result.path = path
			return result
		end

		-- stat(path) -> file_info for ANY path (file or directory), unlike
		-- dir_info which only works on directories (it opendir()s the path).
		-- statx'd directly; no opendir required.
		--: (string | nil) -> ({ name: string, path: string, is_dir: boolean, size: number, modified: number } | nil, string | nil)
		mod.stat = function(path)
			path = path or "."
			if type(path) ~= "string" then return nil, "stat: path must be a string" end
			local err = dir_list_ffi.statx(-100 --[[AT_FDCWD]], path, 0, 0xfff --[[STATX_ALL]], stat)
			if err ~= 0 then return nil, "stat: could not stat " .. path end
			local name = path:match("([^/]+)$") or path
			return {
				name = name,
				path = path,
				is_dir = bit.band(stat[0].stx_mode, 0xf000) == 0x4000,
				size = tonumber(stat[0].stx_size) or 0,
				modified = (tonumber(stat[0].stx_mtime_sec) or 0) + (tonumber(stat[0].stx_mtime_nsec) or 0) / 1000000000,
			}
		end
	end
elseif ffi.os == "Windows" then
	ffi.cdef [[
		typedef unsigned short WORD;
		typedef unsigned long DWORD;
		typedef void *HANDLE;
		typedef const void *LPCVOID;
		typedef char CHAR;
		typedef const char *LPCSTR;

		typedef struct _FILETIME {
			DWORD dwLowDateTime;
			DWORD dwHighDateTime;
		} FILETIME, *PFILETIME, *LPFILETIME;

		typedef struct _WIN32_FIND_DATA {
			DWORD dwFileAttributes;
			FILETIME ftCreationTime;
			FILETIME ftLastAccessTime;
			FILETIME ftLastWriteTime;
			DWORD nFileSizeHigh;
			DWORD nFileSizeLow;
			DWORD dwReserved0;
			DWORD dwReserved1;
			CHAR cFileName[260 /*MAX_PATH*/];
			CHAR cAlternateFileName[14];
			DWORD dwFileType; // obsolete
			DWORD dwCreatorType; // obsolete
			WORD wFinderFlags; // obsolete
		} WIN32_FIND_DATA, *PWIN32_FIND_DATA, *LPWIN32_FIND_DATA;

		HANDLE FindFirstFileA(LPCSTR lpFileName, LPWIN32_FIND_DATA lpFindFileData);
		bool FindNextFileA(HANDLE hFindFile, LPWIN32_FIND_DATA lpFindFileData);
		bool FindClose(HANDLE hFindFile);
		DWORD GetLastError();
		DWORD FormatMessageA(DWORD dwFlags, LPCVOID lpSource, DWORD dwMessageId, DWORD dwLanguageId, LPCSTR lpBuffer, DWORD nSize, va_list *Arguments);
	]]

	local dir_list_ffi = ffi.C

	local err_buf = ffi.new("char[512]")
	local entry = ffi.new("WIN32_FIND_DATA[1]")

	--: (self: { dir: cdata, path: string }) -> ({ name: string, path: string, is_dir: boolean, size: number | nil, created: number | nil, modified: number | nil } | nil, string | nil)
	local dir_list_iter = function(self)
		local success = dir_list_ffi.FindNextFileA(self.dir, entry)
		if not success then
			local err = dir_list_ffi.GetLastError()
			if err ~= 18 --[[ERROR_NO_MORE_FILES]] then
				--[[FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000, FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200]]
				local len = dir_list_ffi.FormatMessageA(0x00001200, nil, dir_list_ffi.GetLastError(), 0, err_buf, 512, nil)
				return nil, "dir_list: " .. ffi.string(err_buf, len - 2)
			end
			success = dir_list_ffi.FindClose(self.dir)
			if not success then return nil, "dir_list: could not close directory" end
			return
		end
		local file_name = ffi.string(entry[0].cFileName)
		return {
			name = file_name,
			path = self.path .. "\\" .. file_name,
			is_dir = bit.band(entry[0].dwFileAttributes, 0x10 --[[FILE_ATTRIBUTE_DIRECTORY]]) ~= 0,
			size = tonumber(entry[0].nFileSizeHigh * 0x100000000 + entry[0].nFileSizeLow),
			created = tonumber((entry[0].ftCreationTime.dwHighDateTime * 0x100000000ULL + entry[0].ftCreationTime.dwLowDateTime) /
			10000000ULL - 11644473600ULL),
			modified = tonumber((entry[0].ftLastAccessTime.dwHighDateTime * 0x100000000ULL + entry[0].ftLastAccessTime.dwLowDateTime) /
			10000000ULL - 11644473600ULL),
		}
	end

	mod.dir_list = function(path)
		path = path or "."
		if type(path) ~= "string" then return nil, "dir_list: path must be a string" end
		local dir = dir_list_ffi.FindFirstFileA(path .. "\\*", entry)
		dir_list_ffi.FindNextFileA(dir, entry) --[[assume first two entries are . and ..]]
		if dir == nil then return nil, "dir_list: could not open directory" end
		return dir_list_iter, { dir = dir, path = path }
	end

	mod.dir_info = function(path)
		path = path or "."
		if type(path) ~= "string" then return nil, "dir_list: path must be a string" end
		local dir = dir_list_ffi.FindFirstFileA(path .. "\\*", entry)
		if dir == nil then return nil, "dir_info: could not open directory" end
		local result = dir_list_iter({ dir = dir, path = path })
		local success = dir_list_ffi.FindClose(dir)
		if not success then return nil, "dir_info: could not close directory" end
		result.path = path
		return result
	end

	-- stat(path) -> file_info for ANY path (file or directory). Unlike
	-- dir_info, FindFirstFileA is pointed directly at path (no \* wildcard),
	-- so it works for plain files too.
	--: (string | nil) -> ({ name: string, path: string, is_dir: boolean, size: number, modified: number } | nil, string | nil)
	mod.stat = function(path)
		path = path or "."
		if type(path) ~= "string" then return nil, "stat: path must be a string" end
		local dir = dir_list_ffi.FindFirstFileA(path, entry)
		if dir == nil then return nil, "stat: could not stat " .. path end
		local name = path:match("([^\\]+)$") or path
		local result = {
			name = name,
			path = path,
			is_dir = bit.band(entry[0].dwFileAttributes, 0x10 --[[FILE_ATTRIBUTE_DIRECTORY]]) ~= 0,
			size = tonumber(entry[0].nFileSizeHigh * 0x100000000 + entry[0].nFileSizeLow) or 0,
			modified = tonumber((entry[0].ftLastAccessTime.dwHighDateTime * 0x100000000ULL + entry[0].ftLastAccessTime.dwLowDateTime) /
			10000000ULL - 11644473600ULL) or 0,
		}
		local success = dir_list_ffi.FindClose(dir)
		if not success then return nil, "stat: could not close handle for " .. path end
		return result
	end
end

mod.dir_list = mod.dir_list or function(path) return nil, "dir_list: os/processor not supported" end
mod.dir_info = mod.dir_info or function(path) return nil, "dir_info: dir_info: os/processor not supported" end
mod.stat = mod.stat or function(path) return nil, "stat: os/processor not supported" end

return mod
