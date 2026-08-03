-- lib/fs/ops.lua
-- Mutating filesystem primitives: mkdir, rmdir (empty dir), unlink (file).
-- Companion to lib/fs/dir_list.lua (read-only: dir_list, dir_info, stat).
--
-- Same OS/arch coverage as dir_list.lua (Linux x64, Windows) — extending to
-- other platforms is a pre-existing dir_list.lua gap, not introduced here.

local ffi = require("ffi")

--:: declare register_ffi_module = ((string) -> nil) | nil
--[[@diagnostic disable-next-line: undefined-global]]
if register_ffi_module then register_ffi_module("lib.fs.ops") end

local mod = {}

if ffi.os == "Linux" then
	if ffi.arch == "x64" then
		ffi.cdef [[
			int mkdir(const char *pathname, unsigned int mode);
			int rmdir(const char *pathname);
			int unlink(const char *pathname);
		]]

		local ops_ffi = ffi.C

		--: (string) -> (true | nil, string | nil)
		mod.mkdir = function(path)
			if type(path) ~= "string" then return nil, "mkdir: path must be a string" end
			local err = ops_ffi.mkdir(path, 0x1ff --[[0777]])
			if err ~= 0 then return nil, "mkdir: could not create " .. path end
			return true
		end

		--: (string) -> (true | nil, string | nil)
		mod.rmdir = function(path)
			if type(path) ~= "string" then return nil, "rmdir: path must be a string" end
			local err = ops_ffi.rmdir(path)
			if err ~= 0 then
				if ffi.errno() == 39 --[[ENOTEMPTY, Linux x64]] then
					return nil, "rmdir: directory not empty: " .. path
				end
				return nil, "rmdir: could not remove directory " .. path
			end
			return true
		end

		--: (string) -> (true | nil, string | nil)
		mod.unlink = function(path)
			if type(path) ~= "string" then return nil, "unlink: path must be a string" end
			local err = ops_ffi.unlink(path)
			if err ~= 0 then return nil, "unlink: could not remove " .. path end
			return true
		end
	end
elseif ffi.os == "Windows" then
	ffi.cdef [[
		typedef int BOOL;
		typedef unsigned long DWORD;
		typedef const char *LPCSTR;
		typedef void *LPSECURITY_ATTRIBUTES;

		BOOL CreateDirectoryA(LPCSTR lpPathName, LPSECURITY_ATTRIBUTES lpSecurityAttributes);
		BOOL RemoveDirectoryA(LPCSTR lpPathName);
		BOOL DeleteFileA(LPCSTR lpFileName);
		DWORD GetLastError();
	]]

	local ops_ffi = ffi.C

	--: (string) -> (true | nil, string | nil)
	mod.mkdir = function(path)
		if type(path) ~= "string" then return nil, "mkdir: path must be a string" end
		local ok = ops_ffi.CreateDirectoryA(path, nil)
		if ok == 0 then return nil, "mkdir: could not create " .. path end
		return true
	end

	--: (string) -> (true | nil, string | nil)
	mod.rmdir = function(path)
		if type(path) ~= "string" then return nil, "rmdir: path must be a string" end
		local ok = ops_ffi.RemoveDirectoryA(path)
		if ok == 0 then
			if ops_ffi.GetLastError() == 145 --[[ERROR_DIR_NOT_EMPTY]] then
				return nil, "rmdir: directory not empty: " .. path
			end
			return nil, "rmdir: could not remove directory " .. path
		end
		return true
	end

	--: (string) -> (true | nil, string | nil)
	mod.unlink = function(path)
		if type(path) ~= "string" then return nil, "unlink: path must be a string" end
		local ok = ops_ffi.DeleteFileA(path)
		if ok == 0 then return nil, "unlink: could not remove " .. path end
		return true
	end
end

mod.mkdir  = mod.mkdir  or function(path) return nil, "mkdir: os/processor not supported" end
mod.rmdir  = mod.rmdir  or function(path) return nil, "rmdir: os/processor not supported" end
mod.unlink = mod.unlink or function(path) return nil, "unlink: os/processor not supported" end

return mod
