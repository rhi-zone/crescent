local T = require("lib.test.assert")
local fs = require("lib.fs")

T.describe("fs.dir_list", function()
	T.it("should list entries in a directory", function()
		local iter, state = fs.dir_list("lib/fs")
		T.ok(iter, "dir_list returns an iterator")
		local names = {}
		for entry in iter, state do
			names[entry.name] = true
		end
		T.ok(names["init.lua"], "contains init.lua")
		T.ok(names["dir_list.lua"], "contains dir_list.lua")
		T.ok(names["fs_test.lua"], "contains fs_test.lua")
	end)

	T.it("should return file_info fields for each entry", function()
		local iter, state = fs.dir_list("lib/fs")
		T.ok(iter, "dir_list returns an iterator")
		local entry = iter(state)
		T.ok(entry, "first entry exists")
		T.ok(type(entry.name) == "string", "name is a string")
		T.ok(type(entry.path) == "string", "path is a string")
		T.ok(type(entry.is_dir) == "boolean", "is_dir is a boolean")
		T.ok(type(entry.size) == "number", "size is a number")
		T.ok(type(entry.created) == "number", "created is a number")
		T.ok(type(entry.modified) == "number", "modified is a number")
	end)

	T.it("should identify directories correctly", function()
		local iter, state = fs.dir_list("lib")
		T.ok(iter, "dir_list returns an iterator")
		local found_fs = false
		for entry in iter, state do
			if entry.name == "fs" then
				T.ok(entry.is_dir, "fs/ is a directory")
				found_fs = true
			end
		end
		T.ok(found_fs, "found fs directory in lib/")
	end)

	T.it("should return nil and error for nonexistent path", function()
		local iter, err = fs.dir_list("/nonexistent/path/that/does/not/exist")
		T.eq(iter, nil)
		T.ok(type(err) == "string", "error is a string")
	end)

	T.it("should default to current directory when given no argument", function()
		local iter, state = fs.dir_list()
		T.ok(iter, "dir_list with no args returns an iterator")
		local names = {}
		for entry in iter, state do
			names[entry.name] = true
		end
		T.ok(names["lib"], "current directory contains lib/")
	end)
end)

T.describe("fs.dir_info", function()
	T.it("should return info for a directory", function()
		local info, err = fs.dir_info("lib/fs")
		T.ok(info, "dir_info returns a result")
		T.eq(err, nil)
		T.eq(info.path, "lib/fs")
		T.ok(info.is_dir, "lib/fs is a directory")
		T.ok(type(info.size) == "number", "size is a number")
	end)

	T.it("should return nil and error for nonexistent path", function()
		local info, err = fs.dir_info("/nonexistent/path/that/does/not/exist")
		T.eq(info, nil)
		T.ok(type(err) == "string", "error is a string")
	end)
end)
