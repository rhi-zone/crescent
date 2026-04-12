-- lib/text_stats/init.lua
-- Text readability and statistics analysis.
-- Implements Flesch, Flesch-Kincaid, Gunning Fog, SMOG, ARI, Coleman-Liau,
-- and Dale-Chall readability scores plus lexical diversity metrics.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.
--
-- Note: Dale-Chall uses a simplified ~200-word familiar word list, not the
-- full 3000-word Dale-Chall list. Scores may differ from the canonical formula
-- for texts with uncommon but not truly "difficult" words.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min

-- ---------------------------------------------------------------------------
-- Stopwords (used for lexical_density)
-- ---------------------------------------------------------------------------

local STOPWORDS = {}
for _, w in ipairs({
	"a", "an", "the", "and", "or", "but", "nor", "so", "yet", "for", "of",
	"in", "on", "at", "to", "by", "up", "as", "it", "its", "is", "are",
	"was", "were", "be", "been", "being", "have", "has", "had", "do", "does",
	"did", "will", "would", "shall", "should", "may", "might", "must", "can",
	"could", "not", "no", "nor", "that", "this", "these", "those", "i", "me",
	"my", "we", "our", "ours", "you", "your", "yours", "he", "him", "his",
	"she", "her", "hers", "they", "them", "their", "theirs", "what", "which",
	"who", "whom", "whose", "when", "where", "why", "how", "all", "both",
	"each", "more", "most", "other", "some", "such", "than", "then", "very",
	"just", "with", "from", "into", "through", "during", "before", "after",
	"above", "below", "between", "out", "off", "over", "under", "again",
	"here", "there", "once", "if", "while", "about", "against",
}) do
	STOPWORDS[w] = true
end

-- ---------------------------------------------------------------------------
-- Dale-Chall familiar words (~200 most common English words)
-- ---------------------------------------------------------------------------

local FAMILIAR_WORDS = {}
for _, w in ipairs({
	"a", "able", "about", "after", "again", "all", "also", "always", "am",
	"an", "and", "another", "any", "are", "around", "as", "ask", "at",
	"away", "back", "be", "because", "been", "before", "best", "better",
	"big", "both", "but", "by", "call", "came", "can", "come", "could",
	"day", "did", "do", "does", "done", "down", "each", "eat", "end",
	"even", "every", "far", "find", "first", "for", "found", "from", "get",
	"give", "go", "going", "good", "got", "great", "had", "has", "have",
	"he", "help", "her", "here", "high", "him", "his", "home", "how", "i",
	"if", "in", "into", "is", "it", "its", "just", "keep", "kind", "know",
	"large", "last", "left", "let", "like", "little", "live", "long", "look",
	"made", "make", "man", "many", "may", "me", "men", "more", "most", "much",
	"must", "my", "name", "need", "never", "new", "next", "no", "not", "now",
	"of", "off", "old", "on", "only", "open", "or", "other", "our", "out",
	"over", "own", "part", "people", "place", "put", "read", "right", "run",
	"said", "same", "saw", "say", "see", "seem", "she", "should", "show",
	"side", "small", "so", "some", "soon", "start", "still", "such", "take",
	"tell", "than", "that", "the", "their", "them", "then", "there", "these",
	"they", "thing", "think", "this", "those", "thought", "three", "through",
	"time", "to", "told", "too", "took", "try", "turn", "two", "under", "up",
	"us", "use", "very", "want", "was", "way", "we", "well", "went", "were",
	"what", "when", "where", "which", "while", "who", "will", "with", "words",
	"work", "world", "would", "write", "year", "yet", "you", "your",
}) do
	FAMILIAR_WORDS[w] = true
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Split text into words: sequences of alphabetic characters (and apostrophes
-- within words so "don't" counts as one word).
local function split_words(text)
	local words = {}
	for w in text:gmatch("[%a][%a']*") do
		words[#words + 1] = w:lower():gsub("'+$", ""):gsub("^'+", "")
	end
	return words
end

-- ---------------------------------------------------------------------------
-- Basic statistics
-- ---------------------------------------------------------------------------

function M.char_count(text)
	return #text
end

function M.letter_count(text)
	local _, n = text:gsub("[%a]", "")
	return n
end

function M.word_count(text)
	return #split_words(text)
end

function M.sentence_count(text)
	-- Count sentence-ending punctuation: . ! ?
	-- Collapse sequences so "..." counts as one.
	local s = text:gsub("[%.!%?]+", "\0")
	local _, n = s:gsub("%z", "")
	return max(n, 1)
end

function M.paragraph_count(text)
	-- Paragraphs separated by one or more blank lines.
	local stripped = text:match("^%s*(.-)%s*$")
	if not stripped or stripped == "" then return 0 end
	local _, n = stripped:gsub("\n%s*\n+", "\0")
	return n + 1
end

-- Syllable count for a single word (standard English heuristic).
function M.syllables_in_word(word)
	word = word:lower():gsub("[^a-z]", "")
	if #word == 0 then return 0 end
	-- Count vowel runs
	local _, count = word:gsub("[aeiou]+", "")
	-- Subtract silent trailing 'e' (only if count > 1)
	if word:sub(-1) == "e" and count > 1 then
		count = count - 1
	end
	-- 'le' at end preceded by consonant adds a syllable (already counted in
	-- vowel runs, so no extra adjustment needed here — the 'e' subtraction
	-- above would incorrectly remove it; re-add).
	if word:match("[^aeiou]le$") then
		count = count + 1
	end
	return max(1, count)
end

function M.syllable_count(text)
	local total = 0
	for _, w in ipairs(split_words(text)) do
		total = total + M.syllables_in_word(w)
	end
	return total
end

-- ---------------------------------------------------------------------------
-- Readability helpers
-- ---------------------------------------------------------------------------

-- Returns (words, sentences, syllables, letters, complex_words)
local function base_stats(text)
	local words = split_words(text)
	local wc = #words
	local sc = M.sentence_count(text)
	local syls = 0
	local complex = 0
	for _, w in ipairs(words) do
		local s = M.syllables_in_word(w)
		syls = syls + s
		-- Complex word: 3+ syllables, not a proper noun (lowercase), and not
		-- a word whose complexity is due only to common suffixes -es/-ed/-ing.
		if s >= 3 then
			local stripped = w:gsub("ing$", ""):gsub("ed$", ""):gsub("es$", "")
			if M.syllables_in_word(stripped) < 3 then
				-- suffix-inflated — not complex
			else
				complex = complex + 1
			end
		end
	end
	local lc = M.letter_count(text)
	return wc, sc, syls, lc, complex
end

-- ---------------------------------------------------------------------------
-- Readability scores
-- ---------------------------------------------------------------------------

function M.flesch_reading_ease(text)
	local wc, sc, syls = base_stats(text)
	if wc == 0 or sc == 0 then return 0 end
	return 206.835 - 1.015 * (wc / sc) - 84.6 * (syls / wc)
end

function M.flesch_kincaid_grade(text)
	local wc, sc, syls = base_stats(text)
	if wc == 0 or sc == 0 then return 0 end
	return 0.39 * (wc / sc) + 11.8 * (syls / wc) - 15.59
end

function M.gunning_fog(text)
	local wc, sc, _, _, complex = base_stats(text)
	if wc == 0 or sc == 0 then return 0 end
	return 0.4 * ((wc / sc) + 100 * (complex / wc))
end

function M.smog_grade(text)
	local wc, sc, _, _, complex = base_stats(text)
	if wc == 0 or sc == 0 then return 0 end
	return 1.0430 * sqrt(complex * (30 / sc)) + 3.1291
end

function M.automated_readability_index(text)
	local wc, sc, _, lc = base_stats(text)
	if wc == 0 or sc == 0 then return 0 end
	return 4.71 * (lc / wc) + 0.5 * (wc / sc) - 21.43
end

function M.coleman_liau_index(text)
	local wc, sc, _, lc = base_stats(text)
	if wc == 0 then return 0 end
	local L = 100 * lc / wc   -- avg letters per 100 words
	local S = 100 * sc / wc   -- avg sentences per 100 words
	return 0.0588 * L - 0.296 * S - 15.8
end

function M.dale_chall_score(text)
	local words = split_words(text)
	local wc = #words
	if wc == 0 then return 0 end
	local sc = M.sentence_count(text)
	local difficult = 0
	for _, w in ipairs(words) do
		if not FAMILIAR_WORDS[w] then
			difficult = difficult + 1
		end
	end
	local pct = 100 * difficult / wc
	local base = 0.1579 * pct + 0.0496 * (wc / sc)
	if pct > 5 then
		return base + 3.6365
	end
	return base
end

-- ---------------------------------------------------------------------------
-- Reading level from Flesch score
-- ---------------------------------------------------------------------------

local function reading_level(score)
	if score >= 90 then return "very easy"
	elseif score >= 80 then return "easy"
	elseif score >= 70 then return "fairly easy"
	elseif score >= 60 then return "standard"
	elseif score >= 50 then return "fairly hard"
	elseif score >= 30 then return "hard"
	else return "very hard"
	end
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

function M.analyze(text)
	local wc, sc, syls, lc, complex = base_stats(text)
	local pc = M.paragraph_count(text)
	local cc = M.char_count(text)
	local fre = (wc == 0 or sc == 0) and 0 or
		206.835 - 1.015 * (wc / sc) - 84.6 * (syls / wc)
	local fkg = (wc == 0 or sc == 0) and 0 or
		0.39 * (wc / sc) + 11.8 * (syls / wc) - 15.59
	local gf = (wc == 0 or sc == 0) and 0 or
		0.4 * ((wc / sc) + 100 * (complex / wc))
	local smog = (wc == 0 or sc == 0) and 0 or
		1.0430 * sqrt(complex * (30 / sc)) + 3.1291
	local ari = (wc == 0 or sc == 0) and 0 or
		4.71 * (lc / wc) + 0.5 * (wc / sc) - 21.43
	local L = wc > 0 and (100 * lc / wc) or 0
	local S = wc > 0 and (100 * sc / wc) or 0
	local cli = 0.0588 * L - 0.296 * S - 15.8
	return {
		char_count = cc,
		letter_count = lc,
		word_count = wc,
		sentence_count = sc,
		paragraph_count = pc,
		syllable_count = syls,
		avg_words_per_sentence = sc > 0 and (wc / sc) or 0,
		avg_syllables_per_word = wc > 0 and (syls / wc) or 0,
		flesch_reading_ease = fre,
		flesch_kincaid_grade = fkg,
		gunning_fog = gf,
		smog_grade = smog,
		automated_readability_index = ari,
		coleman_liau_index = cli,
		reading_level = reading_level(fre),
	}
end

-- ---------------------------------------------------------------------------
-- Lexical diversity
-- ---------------------------------------------------------------------------

function M.type_token_ratio(text)
	local words = split_words(text)
	if #words == 0 then return 0 end
	local seen = {}
	local unique = 0
	for _, w in ipairs(words) do
		if not seen[w] then
			seen[w] = true
			unique = unique + 1
		end
	end
	return unique / #words
end

function M.lexical_density(text)
	local words = split_words(text)
	if #words == 0 then return 0 end
	local content = 0
	for _, w in ipairs(words) do
		if not STOPWORDS[w] then
			content = content + 1
		end
	end
	return content / #words
end

function M.avg_word_length(text)
	local words = split_words(text)
	if #words == 0 then return 0 end
	local total = 0
	for _, w in ipairs(words) do
		total = total + #w
	end
	return total / #words
end

-- ---------------------------------------------------------------------------
-- Frequency analysis
-- ---------------------------------------------------------------------------

function M.word_frequency(text)
	local freq = {}
	for _, w in ipairs(split_words(text)) do
		freq[w] = (freq[w] or 0) + 1
	end
	return freq
end

function M.top_words(text, n)
	local freq = M.word_frequency(text)
	local pairs_list = {}
	for w, c in pairs(freq) do
		pairs_list[#pairs_list + 1] = { word = w, count = c }
	end
	table.sort(pairs_list, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.word < b.word
	end)
	local result = {}
	local limit = n and min(n, #pairs_list) or #pairs_list
	for i = 1, limit do
		result[i] = pairs_list[i]
	end
	return result
end

function M.unique_words(text)
	local seen = {}
	local count = 0
	for _, w in ipairs(split_words(text)) do
		if not seen[w] then
			seen[w] = true
			count = count + 1
		end
	end
	return count
end

return M
