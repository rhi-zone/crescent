-- lib/pdf/font.lua
-- PDF font character-code -> Unicode mapping (ISO 32000-1 §9.6, §9.7, §9.10).
--
-- Builds, from a font dictionary, a function that maps a character code
-- (as it appears in a content stream's Tj/TJ string operands) to the
-- Unicode text it represents. Three data sources feed this, in the
-- priority order the spec establishes:
--
--   1. /ToUnicode (§9.10.3) — a CMap stream mapping codes directly to
--      Unicode. Takes priority over everything else when present, since
--      it's the producer's explicit "how to extract text" hint. Handles
--      `beginbfchar`/`endbfchar` (one code -> one destination) and
--      `beginbfrange`/`endbfrange` (a code range -> either a list of
--      destinations or a single template destination whose low-order
--      code unit increments across the range).
--   2. /Encoding (§9.6.6) — either a base-encoding name
--      (StandardEncoding/WinAnsiEncoding/MacRomanEncoding) or a dictionary
--      with /BaseEncoding plus a /Differences array remapping individual
--      codes to named glyphs. Codes are then mapped glyph-name -> Unicode
--      via the Adobe Glyph List subset below.
--   3. The implicit default: StandardEncoding, when /Encoding is entirely
--      absent (the correct built-in default for the standard 14 fonts —
--      see SCOPE DECISION below for the symbolic-embedded-font caveat).
--
-- ENCODING TABLE DATA — StandardEncoding, WinAnsiEncoding, MacRomanEncoding
-- (all 256 code points each) and the glyph-name -> Unicode table are
-- transcribed byte-for-byte from two externally-verified canonical
-- sources fetched at implementation time, not from memory:
--   - the three encoding arrays: Mozilla pdf.js's `src/core/encodings.js`
--     (github.com/mozilla/pdf.js), itself a direct transcription of
--     ISO 32000-1 Appendix D / Adobe's "PDF Reference" Appendix D tables.
--   - glyph name -> Unicode: Adobe's own Adobe Glyph List
--     (github.com/adobe-type-tools/agl-aglfn, glyphlist.txt), filtered to
--     exactly the glyph names that appear in the three encoding tables
--     above, plus the five standard ligatures (fi, fl, ff, ffi, ffl) that
--     commonly appear as /Differences targets even though they're not in
--     all three base tables. This is a deliberate, documented subset of
--     the full ~4300-entry AGL, not the whole list — see GLYPH_TO_UNICODE
--     below. A glyph name outside this set maps to `nil` (not silently
--     wrong output): `code_to_unicode` returns `nil` for that code, same
--     as any other "cannot map this" case, per docs/conventions.md's
--     `(nil, errmsg)` discipline applied at the single-character grain.
--   Every AGL entry pulled into this subset happens to be single-codepoint
--   (verified: none of the ~246 covered names decompose to multiple
--   codepoints in the real AGL data — e.g. "ffi" maps to the single
--   ligature codepoint U+FB03, not a decomposed "f"+"f"+"i" — contrary to
--   what the task brief's phrasing suggested). Genuine multi-codepoint
--   mapping (e.g. a producer's /ToUnicode CMap deciding to *decompose* a
--   ligature into several codepoints) is still supported by this module —
--   see the CMap bfchar/bfrange parsing below, whose destination strings
--   can and do carry multiple UTF-16BE code units — it just isn't needed
--   by the static glyph-name table for the scope covered here.
--
-- SCOPE DECISION — symbolic embedded fonts with no /Encoding entry.
-- Per spec, a font with no /Encoding uses its own "built-in encoding",
-- which for the standard 14 is StandardEncoding (implemented here) but
-- for an embedded symbolic font (e.g. a subsetted TrueType font with a
-- custom cmap) is whatever encoding is baked into the embedded font
-- program. Reading that requires parsing the embedded font file itself
-- (CFF/TrueType `cmap` table), which is explicitly out of scope for this
-- library (see the task's "what NOT to build": no CFF/TrueType parsing).
-- This module falls back to StandardEncoding in that case, which is
-- correct for the standard 14 and glyph-name-keyed simple fonts, but can
-- be wrong for a symbolic embedded font with a nonstandard built-in
-- encoding and no /Encoding override — a documented, not silent, gap:
-- such a font's codes may map to the wrong glyph name (typically only
-- affecting codes above 0x7F) unless the font also carries a /ToUnicode
-- CMap, which — per its priority above — overrides this fallback entirely
-- whenever present. See TODO.md.
--
-- SCOPE DECISION — Type0 (composite) fonts. Full CID-keyed text extraction
-- requires resolving a CIDFont's CIDToGIDMap and either a predefined
-- CJK CMap or an embedded CMap stream describing the code space and
-- code->CID mapping — a substantial parser this task's scope ("map codes
-- to Unicode for text extraction," not "implement CID font resolution")
-- doesn't justify building. This module supports the common, spec-legal
-- shortcut real-world PDF producers already rely on: a Type0 font whose
-- /Encoding is the predefined identity CMap name `Identity-H` or
-- `Identity-V` (2-byte codes, code == CID, no code-space ambiguity to
-- resolve) *and* that carries a /ToUnicode CMap (the mechanism the task
-- brief itself identifies as "explicitly the hint PDF producers leave for
-- cases /Encoding can't express, e.g. Type0/CID fonts") is fully
-- supported: code_width is 2 and code_to_unicode is driven entirely by
-- /ToUnicode. A Type0 font using any other /Encoding (a predefined CJK
-- CMap name, or an embedded CMap stream), or one with no /ToUnicode, is a
-- documented gap: `font_from_dict` returns a clear `(nil, errmsg)` rather
-- than silently producing wrong or empty text.
--
-- Errors: `(nil, errmsg)`, per docs/conventions.md. Pure Lua only.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local pdf = require("lib.pdf")
local pdf_object = require("lib.pdf.object")
local utf8_encode = require("lib.encode.utf8")

local M = {}
M._tier = "pure"

local floor = math.floor
local sub, find = string.sub, string.find

-- TYPECHECKER WORKAROUND: calling string.byte's overloaded (intersection)
-- signature directly and using the result in arithmetic or a comparison
-- inside a loop doesn't reliably keep its narrowed `integer | nil` type —
-- same substrate gap recorded in TODO.md for lib/pdf/{object,xref,filter}.lua.
-- Wrapping it in a local single-signature function avoids the overload
-- resolver entirely, matching those files' workaround.
--: (string, integer) -> integer | nil
local function byte(s, pos)
	return string.byte(s, pos)
end

--:: Font = { code_width: integer, code_to_unicode: (integer) -> (string | nil) }

-- Mirrors lib/pdf/init.lua's Document shape (same-shape local
-- redeclaration, not an import — type declarations don't cross `require`
-- boundaries in this typechecker, same as XrefOpts in lib/pdf/xref.lua).
--:: Document = { bytes: string, entries: unknown, trailer: unknown }

-- ── Narrowing helpers over `unknown` PDF values ──────────────────────────
-- Mirrors the pattern used throughout lib/pdf/{object,xref,filter,content}.lua.

--: (unknown) -> { [string]: unknown, [integer]: unknown } | nil
local function as_table(v)
	if type(v) == "table" then return v end
	return nil
end

--: (unknown) -> string | nil
local function as_name(v)
	local t = as_table(v)
	if t == nil then return nil end
	if t.kind ~= "name" then return nil end
	local val = t.value
	if type(val) == "string" then return val end
	return nil
end

--: (unknown) -> number | nil
local function as_number(v)
	if type(v) == "number" then return v end
	return nil
end

--: (unknown) -> integer | nil
local function as_integer(v)
	local n = as_number(v)
	if n == nil then return nil end
	return floor(n)
end

--: (unknown) -> string | nil
local function as_string(v)
	if type(v) == "string" then return v end
	return nil
end

--: (unknown) -> { [integer]: unknown } | nil
local function as_array(v)
	-- Arrays and dictionaries are both plain, untagged tables in
	-- lib/pdf/object.lua's representation (see that file's header comment).
	return as_table(v)
end

--: (unknown) -> unknown
local function as_stream(v)
	local t = as_table(v)
	if t == nil or t.kind ~= "stream" then return nil end
	return t
end

-- ── Base encoding tables (ISO 32000-1 Appendix D) ────────────────────────
-- Transcribed from Mozilla pdf.js's src/core/encodings.js — see file header
-- for provenance. Keyed by character code (0-255); missing codes are
-- unassigned in that encoding.

--:: EncodingTable = { [integer]: string }

local STANDARD_ENCODING = {
	[32] = "space", [33] = "exclam", [34] = "quotedbl", [35] = "numbersign",
	[36] = "dollar", [37] = "percent", [38] = "ampersand", [39] = "quoteright",
	[40] = "parenleft", [41] = "parenright", [42] = "asterisk", [43] = "plus",
	[44] = "comma", [45] = "hyphen", [46] = "period", [47] = "slash",
	[48] = "zero", [49] = "one", [50] = "two", [51] = "three", [52] = "four",
	[53] = "five", [54] = "six", [55] = "seven", [56] = "eight", [57] = "nine",
	[58] = "colon", [59] = "semicolon", [60] = "less", [61] = "equal",
	[62] = "greater", [63] = "question", [64] = "at", [65] = "A", [66] = "B",
	[67] = "C", [68] = "D", [69] = "E", [70] = "F", [71] = "G", [72] = "H",
	[73] = "I", [74] = "J", [75] = "K", [76] = "L", [77] = "M", [78] = "N",
	[79] = "O", [80] = "P", [81] = "Q", [82] = "R", [83] = "S", [84] = "T",
	[85] = "U", [86] = "V", [87] = "W", [88] = "X", [89] = "Y", [90] = "Z",
	[91] = "bracketleft", [92] = "backslash", [93] = "bracketright",
	[94] = "asciicircum", [95] = "underscore", [96] = "quoteleft", [97] = "a",
	[98] = "b", [99] = "c", [100] = "d", [101] = "e", [102] = "f", [103] = "g",
	[104] = "h", [105] = "i", [106] = "j", [107] = "k", [108] = "l",
	[109] = "m", [110] = "n", [111] = "o", [112] = "p", [113] = "q",
	[114] = "r", [115] = "s", [116] = "t", [117] = "u", [118] = "v",
	[119] = "w", [120] = "x", [121] = "y", [122] = "z", [123] = "braceleft",
	[124] = "bar", [125] = "braceright", [126] = "asciitilde",
	[161] = "exclamdown", [162] = "cent", [163] = "sterling",
	[164] = "fraction", [165] = "yen", [166] = "florin", [167] = "section",
	[168] = "currency", [169] = "quotesingle", [170] = "quotedblleft",
	[171] = "guillemotleft", [172] = "guilsinglleft", [173] = "guilsinglright",
	[174] = "fi", [175] = "fl", [177] = "endash", [178] = "dagger",
	[179] = "daggerdbl", [180] = "periodcentered", [182] = "paragraph",
	[183] = "bullet", [184] = "quotesinglbase", [185] = "quotedblbase",
	[186] = "quotedblright", [187] = "guillemotright", [188] = "ellipsis",
	[189] = "perthousand", [191] = "questiondown", [193] = "grave",
	[194] = "acute", [195] = "circumflex", [196] = "tilde", [197] = "macron",
	[198] = "breve", [199] = "dotaccent", [200] = "dieresis", [202] = "ring",
	[203] = "cedilla", [205] = "hungarumlaut", [206] = "ogonek",
	[207] = "caron", [208] = "emdash", [225] = "AE", [227] = "ordfeminine",
	[232] = "Lslash", [233] = "Oslash", [234] = "OE", [235] = "ordmasculine",
	[241] = "ae", [245] = "dotlessi", [248] = "lslash", [249] = "oslash",
	[250] = "oe", [251] = "germandbls",
} --[[: EncodingTable]]

local WINANSI_ENCODING = {
	[32] = "space", [33] = "exclam", [34] = "quotedbl", [35] = "numbersign",
	[36] = "dollar", [37] = "percent", [38] = "ampersand", [39] = "quotesingle",
	[40] = "parenleft", [41] = "parenright", [42] = "asterisk", [43] = "plus",
	[44] = "comma", [45] = "hyphen", [46] = "period", [47] = "slash",
	[48] = "zero", [49] = "one", [50] = "two", [51] = "three", [52] = "four",
	[53] = "five", [54] = "six", [55] = "seven", [56] = "eight", [57] = "nine",
	[58] = "colon", [59] = "semicolon", [60] = "less", [61] = "equal",
	[62] = "greater", [63] = "question", [64] = "at", [65] = "A", [66] = "B",
	[67] = "C", [68] = "D", [69] = "E", [70] = "F", [71] = "G", [72] = "H",
	[73] = "I", [74] = "J", [75] = "K", [76] = "L", [77] = "M", [78] = "N",
	[79] = "O", [80] = "P", [81] = "Q", [82] = "R", [83] = "S", [84] = "T",
	[85] = "U", [86] = "V", [87] = "W", [88] = "X", [89] = "Y", [90] = "Z",
	[91] = "bracketleft", [92] = "backslash", [93] = "bracketright",
	[94] = "asciicircum", [95] = "underscore", [96] = "grave", [97] = "a",
	[98] = "b", [99] = "c", [100] = "d", [101] = "e", [102] = "f", [103] = "g",
	[104] = "h", [105] = "i", [106] = "j", [107] = "k", [108] = "l",
	[109] = "m", [110] = "n", [111] = "o", [112] = "p", [113] = "q",
	[114] = "r", [115] = "s", [116] = "t", [117] = "u", [118] = "v",
	[119] = "w", [120] = "x", [121] = "y", [122] = "z", [123] = "braceleft",
	[124] = "bar", [125] = "braceright", [126] = "asciitilde",
	[127] = "bullet", [128] = "Euro", [129] = "bullet",
	[130] = "quotesinglbase", [131] = "florin", [132] = "quotedblbase",
	[133] = "ellipsis", [134] = "dagger", [135] = "daggerdbl",
	[136] = "circumflex", [137] = "perthousand", [138] = "Scaron",
	[139] = "guilsinglleft", [140] = "OE", [141] = "bullet",
	[142] = "Zcaron", [143] = "bullet", [144] = "bullet", [145] = "quoteleft",
	[146] = "quoteright", [147] = "quotedblleft", [148] = "quotedblright",
	[149] = "bullet", [150] = "endash", [151] = "emdash", [152] = "tilde",
	[153] = "trademark", [154] = "scaron", [155] = "guilsinglright",
	[156] = "oe", [157] = "bullet", [158] = "zcaron", [159] = "Ydieresis",
	[160] = "space", [161] = "exclamdown", [162] = "cent", [163] = "sterling",
	[164] = "currency", [165] = "yen", [166] = "brokenbar", [167] = "section",
	[168] = "dieresis", [169] = "copyright", [170] = "ordfeminine",
	[171] = "guillemotleft", [172] = "logicalnot", [173] = "hyphen",
	[174] = "registered", [175] = "macron", [176] = "degree",
	[177] = "plusminus", [178] = "twosuperior", [179] = "threesuperior",
	[180] = "acute", [181] = "mu", [182] = "paragraph",
	[183] = "periodcentered", [184] = "cedilla", [185] = "onesuperior",
	[186] = "ordmasculine", [187] = "guillemotright", [188] = "onequarter",
	[189] = "onehalf", [190] = "threequarters", [191] = "questiondown",
	[192] = "Agrave", [193] = "Aacute", [194] = "Acircumflex",
	[195] = "Atilde", [196] = "Adieresis", [197] = "Aring", [198] = "AE",
	[199] = "Ccedilla", [200] = "Egrave", [201] = "Eacute",
	[202] = "Ecircumflex", [203] = "Edieresis", [204] = "Igrave",
	[205] = "Iacute", [206] = "Icircumflex", [207] = "Idieresis",
	[208] = "Eth", [209] = "Ntilde", [210] = "Ograve", [211] = "Oacute",
	[212] = "Ocircumflex", [213] = "Otilde", [214] = "Odieresis",
	[215] = "multiply", [216] = "Oslash", [217] = "Ugrave", [218] = "Uacute",
	[219] = "Ucircumflex", [220] = "Udieresis", [221] = "Yacute",
	[222] = "Thorn", [223] = "germandbls", [224] = "agrave",
	[225] = "aacute", [226] = "acircumflex", [227] = "atilde",
	[228] = "adieresis", [229] = "aring", [230] = "ae", [231] = "ccedilla",
	[232] = "egrave", [233] = "eacute", [234] = "ecircumflex",
	[235] = "edieresis", [236] = "igrave", [237] = "iacute",
	[238] = "icircumflex", [239] = "idieresis", [240] = "eth",
	[241] = "ntilde", [242] = "ograve", [243] = "oacute",
	[244] = "ocircumflex", [245] = "otilde", [246] = "odieresis",
	[247] = "divide", [248] = "oslash", [249] = "ugrave", [250] = "uacute",
	[251] = "ucircumflex", [252] = "udieresis", [253] = "yacute",
	[254] = "thorn", [255] = "ydieresis",
} --[[: EncodingTable]]

local MACROMAN_ENCODING = {
	[32] = "space", [33] = "exclam", [34] = "quotedbl", [35] = "numbersign",
	[36] = "dollar", [37] = "percent", [38] = "ampersand", [39] = "quotesingle",
	[40] = "parenleft", [41] = "parenright", [42] = "asterisk", [43] = "plus",
	[44] = "comma", [45] = "hyphen", [46] = "period", [47] = "slash",
	[48] = "zero", [49] = "one", [50] = "two", [51] = "three", [52] = "four",
	[53] = "five", [54] = "six", [55] = "seven", [56] = "eight", [57] = "nine",
	[58] = "colon", [59] = "semicolon", [60] = "less", [61] = "equal",
	[62] = "greater", [63] = "question", [64] = "at", [65] = "A", [66] = "B",
	[67] = "C", [68] = "D", [69] = "E", [70] = "F", [71] = "G", [72] = "H",
	[73] = "I", [74] = "J", [75] = "K", [76] = "L", [77] = "M", [78] = "N",
	[79] = "O", [80] = "P", [81] = "Q", [82] = "R", [83] = "S", [84] = "T",
	[85] = "U", [86] = "V", [87] = "W", [88] = "X", [89] = "Y", [90] = "Z",
	[91] = "bracketleft", [92] = "backslash", [93] = "bracketright",
	[94] = "asciicircum", [95] = "underscore", [96] = "grave", [97] = "a",
	[98] = "b", [99] = "c", [100] = "d", [101] = "e", [102] = "f", [103] = "g",
	[104] = "h", [105] = "i", [106] = "j", [107] = "k", [108] = "l",
	[109] = "m", [110] = "n", [111] = "o", [112] = "p", [113] = "q",
	[114] = "r", [115] = "s", [116] = "t", [117] = "u", [118] = "v",
	[119] = "w", [120] = "x", [121] = "y", [122] = "z", [123] = "braceleft",
	[124] = "bar", [125] = "braceright", [126] = "asciitilde",
	[128] = "Adieresis", [129] = "Aring", [130] = "Ccedilla",
	[131] = "Eacute", [132] = "Ntilde", [133] = "Odieresis",
	[134] = "Udieresis", [135] = "aacute", [136] = "agrave",
	[137] = "acircumflex", [138] = "adieresis", [139] = "atilde",
	[140] = "aring", [141] = "ccedilla", [142] = "eacute", [143] = "egrave",
	[144] = "ecircumflex", [145] = "edieresis", [146] = "iacute",
	[147] = "igrave", [148] = "icircumflex", [149] = "idieresis",
	[150] = "ntilde", [151] = "oacute", [152] = "ograve",
	[153] = "ocircumflex", [154] = "odieresis", [155] = "otilde",
	[156] = "uacute", [157] = "ugrave", [158] = "ucircumflex",
	[159] = "udieresis", [160] = "dagger", [161] = "degree", [162] = "cent",
	[163] = "sterling", [164] = "section", [165] = "bullet",
	[166] = "paragraph", [167] = "germandbls", [168] = "registered",
	[169] = "copyright", [170] = "trademark", [171] = "acute",
	[172] = "dieresis", [173] = "notequal", [174] = "AE", [175] = "Oslash",
	[176] = "infinity", [177] = "plusminus", [178] = "lessequal",
	[179] = "greaterequal", [180] = "yen", [181] = "mu",
	[182] = "partialdiff", [183] = "summation", [184] = "product",
	[185] = "pi", [186] = "integral", [187] = "ordfeminine",
	[188] = "ordmasculine", [189] = "Omega", [190] = "ae", [191] = "oslash",
	[192] = "questiondown", [193] = "exclamdown", [194] = "logicalnot",
	[195] = "radical", [196] = "florin", [197] = "approxequal",
	[198] = "Delta", [199] = "guillemotleft", [200] = "guillemotright",
	[201] = "ellipsis", [202] = "space", [203] = "Agrave", [204] = "Atilde",
	[205] = "Otilde", [206] = "OE", [207] = "oe", [208] = "endash",
	[209] = "emdash", [210] = "quotedblleft", [211] = "quotedblright",
	[212] = "quoteleft", [213] = "quoteright", [214] = "divide",
	[215] = "lozenge", [216] = "ydieresis", [217] = "Ydieresis",
	[218] = "fraction", [219] = "currency", [220] = "guilsinglleft",
	[221] = "guilsinglright", [222] = "fi", [223] = "fl", [224] = "daggerdbl",
	[225] = "periodcentered", [226] = "quotesinglbase",
	[227] = "quotedblbase", [228] = "perthousand", [229] = "Acircumflex",
	[230] = "Ecircumflex", [231] = "Aacute", [232] = "Edieresis",
	[233] = "Egrave", [234] = "Iacute", [235] = "Icircumflex",
	[236] = "Idieresis", [237] = "Igrave", [238] = "Oacute",
	[239] = "Ocircumflex", [240] = "apple", [241] = "Ograve",
	[242] = "Uacute", [243] = "Ucircumflex", [244] = "Ugrave",
	[245] = "dotlessi", [246] = "circumflex", [247] = "tilde",
	[248] = "macron", [249] = "breve", [250] = "dotaccent", [251] = "ring",
	[252] = "cedilla", [253] = "hungarumlaut", [254] = "ogonek",
	[255] = "caron",
} --[[: EncodingTable]]

--: (string) -> EncodingTable | nil
local function base_encoding_by_name(name)
	if name == "StandardEncoding" then return STANDARD_ENCODING end
	if name == "WinAnsiEncoding" then return WINANSI_ENCODING end
	if name == "MacRomanEncoding" then return MACROMAN_ENCODING end
	return nil
end

-- ── Glyph name -> Unicode codepoint ──────────────────────────────────────
-- Adobe Glyph List subset — see file header for provenance and coverage
-- boundary (exactly the names used by the three tables above, plus the
-- five standard ligatures). NOT the full ~4300-entry AGL.

local GLYPH_TO_UNICODE = {
	["A"] = 65, ["AE"] = 198, ["Aacute"] = 193, ["Acircumflex"] = 194,
	["Adieresis"] = 196, ["Agrave"] = 192, ["Aring"] = 197, ["Atilde"] = 195,
	["B"] = 66, ["C"] = 67, ["Ccedilla"] = 199, ["D"] = 68, ["Delta"] = 8710,
	["E"] = 69, ["Eacute"] = 201, ["Ecircumflex"] = 202, ["Edieresis"] = 203,
	["Egrave"] = 200, ["Eth"] = 208, ["Euro"] = 8364, ["F"] = 70, ["G"] = 71,
	["H"] = 72, ["I"] = 73, ["Iacute"] = 205, ["Icircumflex"] = 206,
	["Idieresis"] = 207, ["Igrave"] = 204, ["J"] = 74, ["K"] = 75, ["L"] = 76,
	["Lslash"] = 321, ["M"] = 77, ["N"] = 78, ["Ntilde"] = 209, ["O"] = 79,
	["OE"] = 338, ["Oacute"] = 211, ["Ocircumflex"] = 212, ["Odieresis"] = 214,
	["Ograve"] = 210, ["Omega"] = 8486, ["Oslash"] = 216, ["Otilde"] = 213,
	["P"] = 80, ["Q"] = 81, ["R"] = 82, ["S"] = 83, ["Scaron"] = 352,
	["T"] = 84, ["Thorn"] = 222, ["U"] = 85, ["Uacute"] = 218,
	["Ucircumflex"] = 219, ["Udieresis"] = 220, ["Ugrave"] = 217, ["V"] = 86,
	["W"] = 87, ["X"] = 88, ["Y"] = 89, ["Yacute"] = 221, ["Ydieresis"] = 376,
	["Z"] = 90, ["Zcaron"] = 381, ["a"] = 97, ["aacute"] = 225,
	["acircumflex"] = 226, ["acute"] = 180, ["adieresis"] = 228, ["ae"] = 230,
	["agrave"] = 224, ["ampersand"] = 38, ["apple"] = 63743,
	["approxequal"] = 8776, ["aring"] = 229, ["asciicircum"] = 94,
	["asciitilde"] = 126, ["asterisk"] = 42, ["at"] = 64, ["atilde"] = 227,
	["b"] = 98, ["backslash"] = 92, ["bar"] = 124, ["braceleft"] = 123,
	["braceright"] = 125, ["bracketleft"] = 91, ["bracketright"] = 93,
	["breve"] = 728, ["brokenbar"] = 166, ["bullet"] = 8226, ["c"] = 99,
	["caron"] = 711, ["ccedilla"] = 231, ["cedilla"] = 184, ["cent"] = 162,
	["circumflex"] = 710, ["colon"] = 58, ["comma"] = 44, ["copyright"] = 169,
	["currency"] = 164, ["d"] = 100, ["dagger"] = 8224, ["daggerdbl"] = 8225,
	["degree"] = 176, ["dieresis"] = 168, ["divide"] = 247, ["dollar"] = 36,
	["dotaccent"] = 729, ["dotlessi"] = 305, ["e"] = 101, ["eacute"] = 233,
	["ecircumflex"] = 234, ["edieresis"] = 235, ["egrave"] = 232,
	["eight"] = 56, ["ellipsis"] = 8230, ["emdash"] = 8212, ["endash"] = 8211,
	["equal"] = 61, ["eth"] = 240, ["exclam"] = 33, ["exclamdown"] = 161,
	["f"] = 102, ["ff"] = 64256, ["ffi"] = 64259, ["ffl"] = 64260,
	["fi"] = 64257, ["five"] = 53, ["fl"] = 64258, ["florin"] = 402,
	["four"] = 52, ["fraction"] = 8260, ["g"] = 103, ["germandbls"] = 223,
	["grave"] = 96, ["greater"] = 62, ["greaterequal"] = 8805,
	["guillemotleft"] = 171, ["guillemotright"] = 187,
	["guilsinglleft"] = 8249, ["guilsinglright"] = 8250, ["h"] = 104,
	["hungarumlaut"] = 733, ["hyphen"] = 45, ["i"] = 105, ["iacute"] = 237,
	["icircumflex"] = 238, ["idieresis"] = 239, ["igrave"] = 236,
	["infinity"] = 8734, ["integral"] = 8747, ["j"] = 106, ["k"] = 107,
	["l"] = 108, ["less"] = 60, ["lessequal"] = 8804, ["logicalnot"] = 172,
	["lozenge"] = 9674, ["lslash"] = 322, ["m"] = 109, ["macron"] = 175,
	["mu"] = 181, ["multiply"] = 215, ["n"] = 110, ["nine"] = 57,
	["notequal"] = 8800, ["ntilde"] = 241, ["numbersign"] = 35, ["o"] = 111,
	["oacute"] = 243, ["ocircumflex"] = 244, ["odieresis"] = 246,
	["oe"] = 339, ["ogonek"] = 731, ["ograve"] = 242, ["one"] = 49,
	["onehalf"] = 189, ["onequarter"] = 188, ["onesuperior"] = 185,
	["ordfeminine"] = 170, ["ordmasculine"] = 186, ["oslash"] = 248,
	["otilde"] = 245, ["p"] = 112, ["paragraph"] = 182, ["parenleft"] = 40,
	["parenright"] = 41, ["partialdiff"] = 8706, ["percent"] = 37,
	["period"] = 46, ["periodcentered"] = 183, ["perthousand"] = 8240,
	["pi"] = 960, ["plus"] = 43, ["plusminus"] = 177, ["product"] = 8719,
	["q"] = 113, ["question"] = 63, ["questiondown"] = 191,
	["quotedbl"] = 34, ["quotedblbase"] = 8222, ["quotedblleft"] = 8220,
	["quotedblright"] = 8221, ["quoteleft"] = 8216, ["quoteright"] = 8217,
	["quotesinglbase"] = 8218, ["quotesingle"] = 39, ["r"] = 114,
	["radical"] = 8730, ["registered"] = 174, ["ring"] = 730, ["s"] = 115,
	["scaron"] = 353, ["section"] = 167, ["semicolon"] = 59, ["seven"] = 55,
	["six"] = 54, ["slash"] = 47, ["space"] = 32, ["sterling"] = 163,
	["summation"] = 8721, ["t"] = 116, ["thorn"] = 254, ["three"] = 51,
	["threequarters"] = 190, ["threesuperior"] = 179, ["tilde"] = 732,
	["trademark"] = 8482, ["two"] = 50, ["twosuperior"] = 178, ["u"] = 117,
	["uacute"] = 250, ["ucircumflex"] = 251, ["udieresis"] = 252,
	["ugrave"] = 249, ["underscore"] = 95, ["v"] = 118, ["w"] = 119,
	["x"] = 120, ["y"] = 121, ["yacute"] = 253, ["ydieresis"] = 255,
	["yen"] = 165, ["z"] = 122, ["zcaron"] = 382, ["zero"] = 48,
} --[[: { [string]: integer } ]]

-- ── /Encoding resolution: build a code -> glyph-name table ──────────────

--: (Document, unknown) -> ({ [integer]: string } | nil, string | nil)
-- `doc` is used only to resolve indirect references inside /Encoding.
local function build_code_to_glyph_name(doc, encoding)
	local resolved = pdf.resolve(doc, encoding)
	if resolved == nil then
		-- No /Encoding entry at all: built-in default. See SCOPE DECISION
		-- in the file header re: symbolic embedded fonts.
		local base = {}
		for k, v in pairs(STANDARD_ENCODING) do base[k] = v end
		return base, nil
	end

	local direct_name = as_name(resolved)
	if direct_name ~= nil then
		local base = base_encoding_by_name(direct_name)
		if base == nil then
			return nil, "unsupported /Encoding name: " .. direct_name
				.. " (only StandardEncoding, WinAnsiEncoding, MacRomanEncoding are implemented)"
		end
		local copy = {}
		for k, v in pairs(base) do copy[k] = v end
		return copy, nil
	end

	local enc_dict = as_table(resolved)
	if enc_dict == nil then
		return nil, "/Encoding is neither a name nor a dictionary"
	end

	local base = STANDARD_ENCODING
	local base_name = as_name(pdf.resolve(doc, enc_dict.BaseEncoding))
	if base_name ~= nil then
		local b = base_encoding_by_name(base_name)
		if b == nil then
			return nil, "unsupported /BaseEncoding name: " .. base_name
		end
		base = b
	end

	local code_to_name = {}
	for k, v in pairs(base) do code_to_name[k] = v end

	local diffs = as_array(pdf.resolve(doc, enc_dict.Differences))
	if diffs ~= nil then
		local current_code = 0
		local i = 1
		while diffs[i] ~= nil do
			local entry = diffs[i]
			local n = as_integer(entry)
			if n ~= nil then
				current_code = n
			else
				local glyph_name = as_name(entry)
				if glyph_name == nil then
					return nil, "/Differences entry is neither an integer nor a name"
				end
				code_to_name[current_code] = glyph_name
				current_code = current_code + 1
			end
			i = i + 1
		end
	end

	return code_to_name, nil
end

-- ── ToUnicode CMap parsing (ISO 32000-1 §9.10.3) ─────────────────────────
-- The CMap's own mini-syntax is PostScript-like: mostly hex strings, plus
-- bare keywords (begin/endbfchar, begin/endbfrange) that aren't PDF object
-- syntax, same situation lib/pdf/content.lua handles for content-stream
-- operators — so this mirrors that file's approach (reuse
-- lib/pdf/object.lua's parser for hex-string/array/number operands, plus a
-- local bare-keyword scanner for everything else). Byte-classification
-- tables mirrored locally per the xref.lua/content.lua precedent (kept
-- local: no framework coupling beyond object.lua's public API).

local WS = { [0] = true, [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }
local DELIM = {
	[40] = true, [41] = true, [60] = true, [62] = true,
	[91] = true, [93] = true, [123] = true, [125] = true,
	[47] = true, [37] = true,
}

--: (integer | nil) -> boolean
local function is_regular(b) return b ~= nil and not WS[b] and not DELIM[b] end

--: (Reader) -> integer | nil
local function peek_byte(r)
	if r.pos > r.len then return nil end
	return byte(r.src, r.pos)
end

--: (Reader) -> nil
local function skip_ws_and_comments(r)
	while true do
		local b = peek_byte(r)
		if b == nil then return end
		if WS[b] then
			r.pos = r.pos + 1
		elseif b == 37 then -- '%'
			r.pos = r.pos + 1
			while true do
				local c = peek_byte(r)
				if c == nil or c == 10 or c == 13 then break end
				r.pos = r.pos + 1
			end
		else
			return
		end
	end
end

--: (Reader) -> string | nil
local function read_token(r)
	local start = r.pos
	while is_regular(peek_byte(r)) do r.pos = r.pos + 1 end
	if r.pos == start then return nil end
	return sub(r.src, start, r.pos - 1)
end

--: (integer | nil) -> integer
local function or_zero(v)
	if v == nil then return 0 end
	return v
end

--: (string) -> integer
-- Interprets a hex-string's decoded raw bytes as a big-endian integer
-- (source codes in a CMap can be 1, 2, or more bytes wide).
local function bytes_to_uint(s)
	local v = 0
	for i = 1, #s do v = v * 256 + or_zero(byte(s, i)) end
	return v
end

--: (string) -> { [integer]: integer }
-- Splits a hex-string's decoded raw bytes into big-endian UTF-16 code
-- units (2 bytes each). A malformed (odd-length) string silently drops
-- its final dangling byte rather than erroring — CMap streams are
-- producer-generated data, not structural PDF syntax, and destination
-- strings this can't cleanly split are rare malformed input, not a case
-- worth failing the whole extraction over.
local function utf16be_units(s)
	local units = {} --[[: { [integer]: integer } ]]
	local n = #s - (#s % 2)
	for i = 1, n, 2 do
		units[#units + 1] = or_zero(byte(s, i)) * 256 + or_zero(byte(s, i + 1))
	end
	return units
end

--: ({ [integer]: integer }) -> string
-- Combines UTF-16 surrogate pairs into codepoints, then encodes each
-- resulting codepoint to UTF-8 via lib/encode/utf8. This is where a
-- destination genuinely produces multi-codepoint text (e.g. a producer's
-- CMap decomposing a ligature into several codepoints) — see file header.
local function units_to_utf8(units)
	local codepoints = {}
	local i = 1
	while i <= #units do
		local u = units[i]
		if u >= 0xd800 and u <= 0xdbff and units[i + 1] ~= nil
			and units[i + 1] >= 0xdc00 and units[i + 1] <= 0xdfff then
			local lo = units[i + 1]
			codepoints[#codepoints + 1] = 0x10000 + (u - 0xd800) * 0x400 + (lo - 0xdc00)
			i = i + 2
		else
			codepoints[#codepoints + 1] = u
			i = i + 1
		end
	end
	return utf8_encode.char(unpack(codepoints))
end

--: (string) -> ({ [integer]: string } | nil, string | nil)
local function parse_tounicode_cmap(bytes)
	local r = pdf_object.new_reader(bytes)
	local map = {} --[[: { [integer]: string } ]]

	while true do
		skip_ws_and_comments(r)
		if peek_byte(r) == nil then break end

		local before_pos = r.pos
		local obj, oerr = pdf_object.parse_object(r)
		if obj ~= nil then
			-- Bare operand outside a begin/end block: not meaningful to this
			-- parser (CMaps carry setup operators like `/CIDSystemInfo ...
			-- def` this module doesn't need); ignore and continue.
		else
			if r.pos ~= before_pos then
				return nil, "malformed ToUnicode CMap: " .. tostring(oerr)
			end
			local token = read_token(r)
			if token == nil then
				return nil, "unexpected byte in ToUnicode CMap at offset " .. r.pos
			end

			if token == "beginbfchar" then
				while true do
					skip_ws_and_comments(r)
					if find(r.src, "endbfchar", r.pos, true) == r.pos then break end
					local src, src_err = pdf_object.parse_object(r)
					if src == nil then
						return nil, "malformed bfchar entry: " .. tostring(src_err)
					end
					local src_str = as_string(src)
					if src_str == nil then return nil, "bfchar source is not a hex string" end
					skip_ws_and_comments(r)
					local dst, dst_err = pdf_object.parse_object(r)
					if dst == nil then return nil, "malformed bfchar destination: " .. tostring(dst_err) end
					local dst_str = as_string(dst)
					if dst_str == nil then return nil, "bfchar destination is not a hex string" end
					map[bytes_to_uint(src_str)] = units_to_utf8(utf16be_units(dst_str))
				end
				skip_ws_and_comments(r)
				if not read_token(r) then return nil, "expected 'endbfchar'" end -- consumes "endbfchar"

			elseif token == "beginbfrange" then
				while true do
					skip_ws_and_comments(r)
					local save = r.pos
					local lo, lo_err = pdf_object.parse_object(r)
					if lo == nil then
						r.pos = save
						break
					end
					local lo_str = as_string(lo)
					if lo_str == nil then return nil, "malformed bfrange entry: " .. tostring(lo_err) end
					skip_ws_and_comments(r)
					local hi, hi_err = pdf_object.parse_object(r)
					if hi == nil then return nil, "malformed bfrange hi: " .. tostring(hi_err) end
					local hi_str = as_string(hi)
					if hi_str == nil then return nil, "bfrange hi is not a hex string" end
					skip_ws_and_comments(r)
					local dst, dst_err = pdf_object.parse_object(r)
					if dst == nil then return nil, "malformed bfrange destination: " .. tostring(dst_err) end

					local lo_code = bytes_to_uint(lo_str)
					local hi_code = bytes_to_uint(hi_str)
					local dst_arr = as_array(dst)
					if dst_arr ~= nil then
						for k = 0, hi_code - lo_code do
							local dst_i = as_string(dst_arr[k + 1])
							if dst_i ~= nil then
								map[lo_code + k] = units_to_utf8(utf16be_units(dst_i))
							end
						end
					else
						local dst_str = as_string(dst)
						if dst_str == nil then return nil, "bfrange destination is neither a hex string nor an array" end
						local template = utf16be_units(dst_str)
						for k = 0, hi_code - lo_code do
							local units = {} --[[: { [integer]: integer } ]]
							for u = 1, #template do units[u] = template[u] end
							units[#units] = units[#units] + k
							map[lo_code + k] = units_to_utf8(units)
						end
					end
				end
				skip_ws_and_comments(r)
				read_token(r) -- consumes "endbfrange"

			else
				-- Other CMap keywords (usecmap, def, findresource, etc.) are
				-- setup operators this module doesn't need to interpret;
				-- ignored, same as unrecognized content-stream operators.
			end
		end
	end

	return map, nil
end

-- ── Public API ────────────────────────────────────────────────────────────

--- Builds a Font (code -> Unicode mapper) from a resolved font dictionary.
-- `font_dict` should already be resolved (the caller typically pulls it
-- from /Resources/Font, whose entries are frequently indirect references);
-- nested fields this function reads (/Encoding, /ToUnicode, and anything
-- inside them) are resolved here via `doc`.
--: (Document, unknown) -> (Font | nil, string | nil)
function M.font_from_dict(doc, font_dict)
	local dict = as_table(font_dict)
	if dict == nil then return nil, "font_dict is not a dictionary" end

	local subtype = as_name(pdf.resolve(doc, dict.Subtype))

	--: (unknown) -> ({ [integer]: string } | nil, string | nil)
	local function load_tounicode_map()
		local tu = as_stream(pdf.resolve(doc, dict.ToUnicode))
		if tu == nil then return nil, nil end
		local tu_bytes, tu_err = pdf.stream_to_bytes(tu)
		if tu_bytes == nil then return nil, "failed to decode /ToUnicode stream: " .. tostring(tu_err) end
		return parse_tounicode_cmap(tu_bytes)
	end

	if subtype == "Type0" then
		local encoding_name = as_name(pdf.resolve(doc, dict.Encoding))
		if encoding_name ~= "Identity-H" and encoding_name ~= "Identity-V" then
			return nil, "Type0 font uses /Encoding "
				.. tostring(encoding_name or "(non-name value)")
				.. "; only the Identity-H/Identity-V predefined identity encodings are "
				.. "supported (documented gap: general CID CMap resolution is out of scope, see file header)"
		end
		local tounicode_map, tu_err = load_tounicode_map()
		if tounicode_map == nil then
			if tu_err ~= nil then return nil, tu_err end
			return nil, "Type0 font has no /ToUnicode CMap; mapping composite-font codes to "
				.. "Unicode without one requires full CID font resolution, which is out of "
				.. "scope (documented gap, see file header)"
		end
		--: (integer) -> string | nil
		local function code_to_unicode_type0(code) return tounicode_map[code] end
		return {
			code_width = 2,
			code_to_unicode = code_to_unicode_type0,
		}, nil
	end

	-- Simple font (Type1, TrueType, MMType1, Type3): single-byte codes.
	local code_to_name, cerr = build_code_to_glyph_name(doc, pdf.resolve(doc, dict.Encoding))
	if code_to_name == nil then return nil, cerr end

	local tounicode_map, tu_err = load_tounicode_map()
	if tu_err ~= nil then return nil, tu_err end

	--: (integer) -> string | nil
	local function code_to_unicode(code)
		if tounicode_map ~= nil then
			local direct = tounicode_map[code]
			if direct ~= nil then return direct end
		end
		local glyph_name = code_to_name[code]
		if glyph_name == nil then return nil end
		local cp = GLYPH_TO_UNICODE[glyph_name]
		if cp == nil then return nil end
		return utf8_encode.char(cp)
	end

	return { code_width = 1, code_to_unicode = code_to_unicode }, nil
end

return M
