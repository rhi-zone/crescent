-- crescent test runner
-- discovers and runs *_test.lua files under lib/

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local function find_test_files()
	local files = {}
	local handle = io.popen("find lib -name '*_test.lua' -type f | sort")
	if not handle then return files end
	for line in handle:lines() do
		files[#files + 1] = line
	end
	handle:close()
	return files
end

local files = find_test_files()
if #files == 0 then
	print("no test files found")
	os.exit(0)
end

local passed, failed = 0, 0
for _, file in ipairs(files) do
	local ok, err = pcall(dofile, file)
	if ok then
		passed = passed + 1
		print("  pass  " .. file)
	else
		failed = failed + 1
		print("  FAIL  " .. file)
		print("        " .. tostring(err))
	end
end

print("")
print(passed .. " passed, " .. failed .. " failed, " .. #files .. " total")
if failed > 0 then os.exit(1) end
