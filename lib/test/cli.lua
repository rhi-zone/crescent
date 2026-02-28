-- crescent test runner
-- discovers and runs *_test.lua files under lib/

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local coverage = arg[1] == "--coverage" or arg[1] == "-c"

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

local cov
if coverage then
	cov = require("lib.test.coverage")
	cov.start()
end

-- Load assert module once so we can reset/query its counters.
local assert_mod = require("lib.test.assert")

local total_pass_files, total_fail_files = 0, 0
local grand_pass, grand_fail = 0, 0

for _, file in ipairs(files) do
	assert_mod._reset()
	local ok, err = pcall(dofile, file)
	local summary = assert_mod._summary()

	grand_pass = grand_pass + summary.pass
	grand_fail = grand_fail + summary.fail

	local counts
	if summary.pass + summary.fail > 0 then
		if summary.fail == 0 then
			counts = summary.pass .. " passed"
		else
			counts = summary.pass .. " passed, " .. summary.fail .. " failed"
		end
	end

	if ok and summary.fail == 0 then
		total_pass_files = total_pass_files + 1
		io.write("  pass  " .. file)
		if counts then io.write("  (" .. counts .. ")") end
		io.write("\n")
	else
		total_fail_files = total_fail_files + 1
		io.write("  FAIL  " .. file)
		if counts then io.write("  (" .. counts .. ")") end
		io.write("\n")

		-- Show named test failures first.
		if #summary.tests > 0 then
			for _, t in ipairs(summary.tests) do
				if not t.ok then
					local detail = t.err and (": " .. t.err) or ""
					print("        \xE2\x9C\x97 " .. t.name .. detail)
				end
			end
		elseif not ok then
			-- Bare-assertion file: show the thrown error.
			print("        " .. tostring(err))
		end
	end
end

if cov then cov.stop() end

print("")
local total_assertions = grand_pass + grand_fail
io.write(total_pass_files .. " passed, " .. total_fail_files .. " failed, " .. #files .. " total")
if total_assertions > 0 then
	io.write("  (" .. total_assertions .. " assertion" .. (total_assertions ~= 1 and "s" or "") .. ")")
end
io.write("\n")

if cov then
	cov.report({ uncovered = true })
end

if total_fail_files > 0 then os.exit(1) end
