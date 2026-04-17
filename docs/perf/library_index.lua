-- docs/perf/library_index.lua
-- Benchmark the lib/platform/index queries at library-at-scale sizes.
-- Validates the claim that the app_tags join + apps_fts trigram search
-- stay sub-5ms at ~20k apps — the ST "tag_map scan + LIKE '%q%'" failure
-- mode is the anti-goal.
--
-- Run: luajit docs/perf/library_index.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local index = require("lib.platform.index")

local N = tonumber(arg and arg[1]) or 20000
local PAGE = 200

local WORDS = {
	"alice","bob","calc","dungeon","master","rogue","wizard","knight",
	"helper","friend","mentor","tutor","engineer","artist","novelist",
	"detective","hacker","pilot","captain","astronaut","chef","doctor",
	"witch","vampire","robot","android","mage","ranger","bard","cleric",
}
local TAGS = {
	"ai","chat","roleplay","utility","math","game","tool","fantasy",
	"scifi","horror","slice","comedy","drama","cyberpunk","medieval",
	"modern","school","office","space","post-apocalyptic",
}

local function make_name(i)
	local a = WORDS[(i % #WORDS) + 1]
	local b = WORDS[((i * 7 + 3) % #WORDS) + 1]
	return a .. "-" .. b .. "-" .. tostring(i)
end

local function make_tags(i)
	local t = {}
	t[1] = TAGS[(i % #TAGS) + 1]
	if i % 3 == 0 then t[#t + 1] = TAGS[((i * 5) % #TAGS) + 1] end
	if i % 7 == 0 then t[#t + 1] = TAGS[((i * 11) % #TAGS) + 1] end
	return t
end

io.write(string.format("Seeding %d apps...\n", N))
local idx = index.open(":memory:")

-- Wrap the seeding in a single transaction — otherwise SQLite autocommits
-- per statement and we'd be benchmarking fsync, not the queries.
idx._db:execute("BEGIN")
local t0 = os.clock()
for i = 1, N do
	idx:install(
		"/apps/app-" .. tostring(i) .. ".png",
		{
			name = make_name(i),
			meta = {
				tags = make_tags(i),
				description = "A " .. WORDS[(i * 3 % #WORDS) + 1]
					.. " who plays as a " .. WORDS[(i * 13 % #WORDS) + 1],
			},
		},
		1000000 + i
	)
end
idx._db:execute("COMMIT")
local seed_time = os.clock() - t0
io.write(string.format("  seeded in %.2fs (%.0f installs/s)\n\n",
	seed_time, N / seed_time))

local function bench(label, fn, iters)
	iters = iters or 50
	-- Warmup.
	for _ = 1, 3 do fn() end
	local t = os.clock()
	local rows
	for _ = 1, iters do rows = fn() end
	local elapsed = os.clock() - t
	local per = (elapsed / iters) * 1000
	io.write(string.format("  %-38s %6.2f ms/op  (%d rows)\n",
		label, per, rows or 0))
end

io.write("Queries:\n")

bench("list() first page (no filter)", function()
	local results = idx:list()
	return math.min(#results, PAGE)
end)

bench("search('alice') FTS trigram", function()
	return #idx:search("alice")
end)

bench("search('calc-dun') phrase", function()
	return #idx:search("calc-dun")
end)

bench("list({tag='ai'}) tag join", function()
	return #idx:list({ tag = "ai" })
end)

bench("list({tag='fantasy'}) tag join", function()
	return #idx:list({ tag = "fantasy" })
end)

-- Direct SQL to measure the server.lua query_apps shape (page + count).
local db = idx._db
bench("server-style page (LIMIT 200, no filter)", function()
	local iter = db:query(
		"SELECT a.id FROM apps a ORDER BY a.name ASC LIMIT ? OFFSET ?",
		PAGE, 0)
	local n = 0
	for _ in iter do n = n + 1 end
	return n
end)

bench("server-style count (no filter)", function()
	local iter = db:query("SELECT COUNT(*) FROM apps a")
	return iter()
end)

bench("server-style FTS+tag page", function()
	-- Mirrors FROM_Q_TAG in lib/platform/apps/library/server.lua: FTS
	-- MATCH goes in an IN subquery, not a JOIN, so it's evaluated once.
	local iter = db:query(
		"SELECT a.id FROM apps a " ..
		"JOIN app_tags at ON at.app_id = a.id " ..
		"JOIN tags t ON t.id = at.tag_id " ..
		"WHERE t.name = ? AND a.id IN (SELECT rowid FROM apps_fts WHERE apps_fts MATCH ?) " ..
		"ORDER BY a.name ASC LIMIT ? OFFSET ?",
		"ai", '"alice"', PAGE, 0)
	local n = 0
	for _ in iter do n = n + 1 end
	return n
end)

idx:close()
io.write("\nDone.\n")
