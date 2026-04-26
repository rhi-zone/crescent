-- lib/platform/apps/system_dashboard/search.lua
-- Fuzzy search over an alias list.
--
-- search.score(alias, query) -> number (0 = no match)
-- search.search(aliases, query, limit?) -> alias_with_score[]

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Split a string into lower-case words.
local function words(s)
	local result = {}
	for w in s:lower():gmatch("%S+") do
		result[#result + 1] = w
	end
	return result
end

-- score(alias, query) -> number
-- Scores an alias against a query string. Returns 0 if no match.
-- All comparisons are case-insensitive.
function M.score(alias, query)
	if not query or query == "" then return 0 end
	local q = query:lower()
	local alias_t = alias --: any
	local title = tostring(alias_t.title or ""):lower()
	local desc  = tostring(alias_t.description or ""):lower()
	local tags  = alias_t.tags or {}

	if title == q then return 100 end

	local total = 0
	local qwords = words(q)

	if title:sub(1, #q) == q then total = total + 80 end

	local all_in_title = true
	for _, w in ipairs(qwords) do
		if not title:find(w, 1, true) then all_in_title = false; break end
	end
	if all_in_title and #qwords > 0 then total = total + 70 end

	for _, w in ipairs(qwords) do
		if title:find(w, 1, true) then total = total + 60 end
		for _, tag in ipairs(tags) do
			if tostring(tag):lower() == w then total = total + 50 end
		end
		if desc:find(w, 1, true) then total = total + 20 end
	end

	if total == 0 and desc:find(q, 1, true) then total = total + 40 end

	return total
end

-- search(aliases, query, limit?) -> alias_with_score[]
-- Returns aliases sorted by score descending, filtered to score > 0.
-- Each result has all alias fields plus a .score field.
function M.search(aliases, query, limit)
	local scored = {}
	for _, alias in ipairs(aliases) do
		local s = M.score(alias, query)
		if s > 0 then
			local result = {}
			for k, v in pairs(alias) do result[k] = v end
			result.score = s
			scored[#scored + 1] = result
		end
	end
	table.sort(scored, function(a, b) return a.score > b.score end)
	if limit and #scored > limit then
		local trimmed = {}
		for i = 1, limit do trimmed[i] = scored[i] end
		return trimmed
	end
	return scored
end

return M
