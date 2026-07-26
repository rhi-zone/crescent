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
-- transcribed from two externally-verified canonical sources fetched at
-- implementation time, not from memory:
--   - the three encoding arrays: Mozilla pdf.js's `src/core/encodings.js`
--     (github.com/mozilla/pdf.js), itself a direct transcription of
--     ISO 32000-1 Appendix D / Adobe's "PDF Reference" Appendix D tables.
--   - glyph name -> Unicode: the full, official Adobe Glyph List (Adobe's
--     own github.com/adobe-type-tools/agl-aglfn, glyphlist.txt, table
--     version 2.0) — all 4281 entries, machine-generated into
--     GLYPH_TO_UTF8 below by fetching glyphlist.txt and encoding each
--     entry's codepoint sequence through lib/encode/utf8 (never
--     hand-transcribed — base-85/UTF-8/etc. byte arithmetic by hand isn't a
--     trustworthy way to produce ~4300 data entries). A glyph name outside
--     the AGL maps to `nil` (not silently wrong output): `code_to_unicode`
--     returns `nil` for that code, same as any other "cannot map this"
--     case, per docs/conventions.md's `(nil, errmsg)` discipline applied at
--     the single-character grain.
--   GLYPH_TO_UTF8's values are pre-encoded UTF-8 strings, not bare
--   codepoints: 81 of the 4281 AGL entries (mostly Hebrew
--   letter-plus-point sequences, e.g. "dalethatafpatah" -> dalet + hataf
--   patah) map to a *sequence* of codepoints, not one — storing the
--   already-encoded UTF-8 bytes represents both cases uniformly without a
--   separate single-vs-multi-codepoint branch in `code_to_unicode`.
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
-- SCOPE DECISION — Type0 (composite) fonts. Full CID-keyed glyph rendering
-- requires resolving a CIDFont's CIDToGIDMap and a code->CID CMap (either
-- the real Adobe CID-collection resource tables for a predefined CJK CMap,
-- or a begincidchar/begincidrange embedded CMap) — that's out of scope
-- here, consistent with this module's "map codes to Unicode for text
-- extraction," not "implement CID font resolution." What IS supported,
-- covering real-world CJK PDFs broadly: (1) any Type0 font carrying a
-- /ToUnicode CMap, regardless of /Encoding — highest priority per this
-- file's stated priority order, since it's the producer's own text-
-- extraction hint; (2) absent that, a Type0 font whose /Encoding is one of
-- the predefined `Uni*-UTF16-H`/`Uni*-UTF16-V` CMaps (GB/CNS/JIS/KS
-- collections) — those CMaps' codes are already the UTF-16BE code units of
-- the Unicode value by construction, so no CID step is needed for
-- extraction; (3) absent that, a Type0 font whose /Encoding is an embedded
-- CMap *stream* using bfchar/bfrange destination-Unicode syntax (the same
-- syntax /ToUnicode CMaps use) rather than the CID-producing
-- begincidchar/begincidrange syntax real code->CID CMaps normally use —
-- narrower than general embedded-CMap support, but exactly the shape a
-- producer choosing to make /Encoding double as its own Unicode hint
-- produces. A Type0 font using any other /Encoding (Identity-H/V with no
-- /ToUnicode, some other predefined non-UTF16 CMap name, or an embedded
-- CID-producing CMap) is a documented gap: `font_from_dict` returns a clear
-- `(nil, errmsg)` rather than silently producing wrong or empty text.
-- CID glyph WIDTHS (/DW + /W, ISO 32000-1 §9.7.4.3) are wired only for
-- Identity-H/V, the one case where code == CID needs no CMap resolution at
-- all — see `build_code_to_cid_width`'s comment below for why the other
-- /Encoding branches above (which resolve Unicode without ever resolving a
-- CID) can't also drive width lookup.
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

-- `code_to_width` (ISO 32000-1 §9.6.3, Table 111 /Widths, /FirstChar,
-- /LastChar, plus /FontDescriptor /MissingWidth) is `nil` when the font
-- dictionary carries no /Widths array at all — callers (lib/pdf/text.lua)
-- fall back to treating the glyph-width advance term as 0 in that case,
-- the same documented approximation this module used universally before
-- /Widths parsing existed. When present, it is total over codes: any code
-- (in range or not) returns a number, since an out-of-[FirstChar,LastChar]
-- code still resolves to /MissingWidth (default 0) per spec, not "no data".
-- Units are glyph space (thousandths of a text space unit at the font's
-- default 0.001 /FontMatrix) — the same units TJ array adjustments and
-- Type3 /FontMatrix already use elsewhere in this codebase, so callers
-- divide by 1000 themselves rather than this module doing it once and
-- callers needing to know that already happened.
--:: Font = {
--::   code_width: integer,
--::   code_to_unicode: (integer) -> (string | nil),
--::   code_to_width: ((integer) -> number) | nil,
--:: }

-- Mirrors lib/pdf/init.lua's Document shape (same-shape local
-- redeclaration, not an import — type declarations don't cross `require`
-- boundaries in this typechecker, same as XrefOpts in lib/pdf/xref.lua).
--:: Document = { bytes: string, entries: unknown, trailer: unknown, objstm_cache: unknown }

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

-- ── Glyph name -> Unicode ────────────────────────────────────────────────
-- Full Adobe Glyph List — see file header for provenance and the
-- pre-encoded-UTF-8 value shape.

-- Generated from the official Adobe Glyph List (glyphlist.txt, table version 2.0,
-- github.com/adobe-type-tools/agl-aglfn), 4281 entries, fetched at implementation
-- time (not from memory). Values are pre-encoded UTF-8 (not bare codepoints) so
-- the ~81 multi-codepoint AGL entries (e.g. Hebrew letter+point sequences) are
-- representable uniformly alongside the single-codepoint majority.
local GLYPH_TO_UTF8 = {
["A"]="A",["AE"]="\195\134",["AEacute"]="\199\188",["AEmacron"]="\199\162",["AEsmall"]="\239\159\166",
["Aacute"]="\195\129",["Aacutesmall"]="\239\159\161",["Abreve"]="\196\130",["Abreveacute"]="\225\186\174",
["Abrevecyrillic"]="\211\144",["Abrevedotbelow"]="\225\186\182",["Abrevegrave"]="\225\186\176",["Abrevehookabove"]="\225\186\178",
["Abrevetilde"]="\225\186\180",["Acaron"]="\199\141",["Acircle"]="\226\146\182",["Acircumflex"]="\195\130",
["Acircumflexacute"]="\225\186\164",["Acircumflexdotbelow"]="\225\186\172",["Acircumflexgrave"]="\225\186\166",
["Acircumflexhookabove"]="\225\186\168",["Acircumflexsmall"]="\239\159\162",["Acircumflextilde"]="\225\186\170",
["Acute"]="\239\155\137",["Acutesmall"]="\239\158\180",["Acyrillic"]="\208\144",["Adblgrave"]="\200\128",
["Adieresis"]="\195\132",["Adieresiscyrillic"]="\211\146",["Adieresismacron"]="\199\158",["Adieresissmall"]="\239\159\164",
["Adotbelow"]="\225\186\160",["Adotmacron"]="\199\160",["Agrave"]="\195\128",["Agravesmall"]="\239\159\160",
["Ahookabove"]="\225\186\162",["Aiecyrillic"]="\211\148",["Ainvertedbreve"]="\200\130",["Alpha"]="\206\145",
["Alphatonos"]="\206\134",["Amacron"]="\196\128",["Amonospace"]="\239\188\161",["Aogonek"]="\196\132",
["Aring"]="\195\133",["Aringacute"]="\199\186",["Aringbelow"]="\225\184\128",["Aringsmall"]="\239\159\165",
["Asmall"]="\239\157\161",["Atilde"]="\195\131",["Atildesmall"]="\239\159\163",["Aybarmenian"]="\212\177",
["B"]="B",["Bcircle"]="\226\146\183",["Bdotaccent"]="\225\184\130",["Bdotbelow"]="\225\184\132",["Becyrillic"]="\208\145",
["Benarmenian"]="\212\178",["Beta"]="\206\146",["Bhook"]="\198\129",["Blinebelow"]="\225\184\134",["Bmonospace"]="\239\188\162",
["Brevesmall"]="\239\155\180",["Bsmall"]="\239\157\162",["Btopbar"]="\198\130",["C"]="C",["Caarmenian"]="\212\190",
["Cacute"]="\196\134",["Caron"]="\239\155\138",["Caronsmall"]="\239\155\181",["Ccaron"]="\196\140",["Ccedilla"]="\195\135",
["Ccedillaacute"]="\225\184\136",["Ccedillasmall"]="\239\159\167",["Ccircle"]="\226\146\184",["Ccircumflex"]="\196\136",
["Cdot"]="\196\138",["Cdotaccent"]="\196\138",["Cedillasmall"]="\239\158\184",["Chaarmenian"]="\213\137",
["Cheabkhasiancyrillic"]="\210\188",["Checyrillic"]="\208\167",["Chedescenderabkhasiancyrillic"]="\210\190",
["Chedescendercyrillic"]="\210\182",["Chedieresiscyrillic"]="\211\180",["Cheharmenian"]="\213\131",["Chekhakassiancyrillic"]="\211\139",
["Cheverticalstrokecyrillic"]="\210\184",["Chi"]="\206\167",["Chook"]="\198\135",["Circumflexsmall"]="\239\155\182",
["Cmonospace"]="\239\188\163",["Coarmenian"]="\213\145",["Csmall"]="\239\157\163",["D"]="D",["DZ"]="\199\177",
["DZcaron"]="\199\132",["Daarmenian"]="\212\180",["Dafrican"]="\198\137",["Dcaron"]="\196\142",["Dcedilla"]="\225\184\144",
["Dcircle"]="\226\146\185",["Dcircumflexbelow"]="\225\184\146",["Dcroat"]="\196\144",["Ddotaccent"]="\225\184\138",
["Ddotbelow"]="\225\184\140",["Decyrillic"]="\208\148",["Deicoptic"]="\207\174",["Delta"]="\226\136\134",
["Deltagreek"]="\206\148",["Dhook"]="\198\138",["Dieresis"]="\239\155\139",["DieresisAcute"]="\239\155\140",
["DieresisGrave"]="\239\155\141",["Dieresissmall"]="\239\158\168",["Digammagreek"]="\207\156",["Djecyrillic"]="\208\130",
["Dlinebelow"]="\225\184\142",["Dmonospace"]="\239\188\164",["Dotaccentsmall"]="\239\155\183",["Dslash"]="\196\144",
["Dsmall"]="\239\157\164",["Dtopbar"]="\198\139",["Dz"]="\199\178",["Dzcaron"]="\199\133",["Dzeabkhasiancyrillic"]="\211\160",
["Dzecyrillic"]="\208\133",["Dzhecyrillic"]="\208\143",["E"]="E",["Eacute"]="\195\137",["Eacutesmall"]="\239\159\169",
["Ebreve"]="\196\148",["Ecaron"]="\196\154",["Ecedillabreve"]="\225\184\156",["Echarmenian"]="\212\181",
["Ecircle"]="\226\146\186",["Ecircumflex"]="\195\138",["Ecircumflexacute"]="\225\186\190",["Ecircumflexbelow"]="\225\184\152",
["Ecircumflexdotbelow"]="\225\187\134",["Ecircumflexgrave"]="\225\187\128",["Ecircumflexhookabove"]="\225\187\130",
["Ecircumflexsmall"]="\239\159\170",["Ecircumflextilde"]="\225\187\132",["Ecyrillic"]="\208\132",["Edblgrave"]="\200\132",
["Edieresis"]="\195\139",["Edieresissmall"]="\239\159\171",["Edot"]="\196\150",["Edotaccent"]="\196\150",
["Edotbelow"]="\225\186\184",["Efcyrillic"]="\208\164",["Egrave"]="\195\136",["Egravesmall"]="\239\159\168",
["Eharmenian"]="\212\183",["Ehookabove"]="\225\186\186",["Eightroman"]="\226\133\167",["Einvertedbreve"]="\200\134",
["Eiotifiedcyrillic"]="\209\164",["Elcyrillic"]="\208\155",["Elevenroman"]="\226\133\170",["Emacron"]="\196\146",
["Emacronacute"]="\225\184\150",["Emacrongrave"]="\225\184\148",["Emcyrillic"]="\208\156",["Emonospace"]="\239\188\165",
["Encyrillic"]="\208\157",["Endescendercyrillic"]="\210\162",["Eng"]="\197\138",["Enghecyrillic"]="\210\164",
["Enhookcyrillic"]="\211\135",["Eogonek"]="\196\152",["Eopen"]="\198\144",["Epsilon"]="\206\149",["Epsilontonos"]="\206\136",
["Ercyrillic"]="\208\160",["Ereversed"]="\198\142",["Ereversedcyrillic"]="\208\173",["Escyrillic"]="\208\161",
["Esdescendercyrillic"]="\210\170",["Esh"]="\198\169",["Esmall"]="\239\157\165",["Eta"]="\206\151",["Etarmenian"]="\212\184",
["Etatonos"]="\206\137",["Eth"]="\195\144",["Ethsmall"]="\239\159\176",["Etilde"]="\225\186\188",["Etildebelow"]="\225\184\154",
["Euro"]="\226\130\172",["Ezh"]="\198\183",["Ezhcaron"]="\199\174",["Ezhreversed"]="\198\184",["F"]="F",
["Fcircle"]="\226\146\187",["Fdotaccent"]="\225\184\158",["Feharmenian"]="\213\150",["Feicoptic"]="\207\164",
["Fhook"]="\198\145",["Fitacyrillic"]="\209\178",["Fiveroman"]="\226\133\164",["Fmonospace"]="\239\188\166",
["Fourroman"]="\226\133\163",["Fsmall"]="\239\157\166",["G"]="G",["GBsquare"]="\227\142\135",["Gacute"]="\199\180",
["Gamma"]="\206\147",["Gammaafrican"]="\198\148",["Gangiacoptic"]="\207\170",["Gbreve"]="\196\158",["Gcaron"]="\199\166",
["Gcedilla"]="\196\162",["Gcircle"]="\226\146\188",["Gcircumflex"]="\196\156",["Gcommaaccent"]="\196\162",
["Gdot"]="\196\160",["Gdotaccent"]="\196\160",["Gecyrillic"]="\208\147",["Ghadarmenian"]="\213\130",["Ghemiddlehookcyrillic"]="\210\148",
["Ghestrokecyrillic"]="\210\146",["Gheupturncyrillic"]="\210\144",["Ghook"]="\198\147",["Gimarmenian"]="\212\179",
["Gjecyrillic"]="\208\131",["Gmacron"]="\225\184\160",["Gmonospace"]="\239\188\167",["Grave"]="\239\155\142",
["Gravesmall"]="\239\157\160",["Gsmall"]="\239\157\167",["Gsmallhook"]="\202\155",["Gstroke"]="\199\164",
["H"]="H",["H18533"]="\226\151\143",["H18543"]="\226\150\170",["H18551"]="\226\150\171",["H22073"]="\226\150\161",
["HPsquare"]="\227\143\139",["Haabkhasiancyrillic"]="\210\168",["Hadescendercyrillic"]="\210\178",["Hardsigncyrillic"]="\208\170",
["Hbar"]="\196\166",["Hbrevebelow"]="\225\184\170",["Hcedilla"]="\225\184\168",["Hcircle"]="\226\146\189",
["Hcircumflex"]="\196\164",["Hdieresis"]="\225\184\166",["Hdotaccent"]="\225\184\162",["Hdotbelow"]="\225\184\164",
["Hmonospace"]="\239\188\168",["Hoarmenian"]="\213\128",["Horicoptic"]="\207\168",["Hsmall"]="\239\157\168",
["Hungarumlaut"]="\239\155\143",["Hungarumlautsmall"]="\239\155\184",["Hzsquare"]="\227\142\144",["I"]="I",
["IAcyrillic"]="\208\175",["IJ"]="\196\178",["IUcyrillic"]="\208\174",["Iacute"]="\195\141",["Iacutesmall"]="\239\159\173",
["Ibreve"]="\196\172",["Icaron"]="\199\143",["Icircle"]="\226\146\190",["Icircumflex"]="\195\142",["Icircumflexsmall"]="\239\159\174",
["Icyrillic"]="\208\134",["Idblgrave"]="\200\136",["Idieresis"]="\195\143",["Idieresisacute"]="\225\184\174",
["Idieresiscyrillic"]="\211\164",["Idieresissmall"]="\239\159\175",["Idot"]="\196\176",["Idotaccent"]="\196\176",
["Idotbelow"]="\225\187\138",["Iebrevecyrillic"]="\211\150",["Iecyrillic"]="\208\149",["Ifraktur"]="\226\132\145",
["Igrave"]="\195\140",["Igravesmall"]="\239\159\172",["Ihookabove"]="\225\187\136",["Iicyrillic"]="\208\152",
["Iinvertedbreve"]="\200\138",["Iishortcyrillic"]="\208\153",["Imacron"]="\196\170",["Imacroncyrillic"]="\211\162",
["Imonospace"]="\239\188\169",["Iniarmenian"]="\212\187",["Iocyrillic"]="\208\129",["Iogonek"]="\196\174",
["Iota"]="\206\153",["Iotaafrican"]="\198\150",["Iotadieresis"]="\206\170",["Iotatonos"]="\206\138",["Ismall"]="\239\157\169",
["Istroke"]="\198\151",["Itilde"]="\196\168",["Itildebelow"]="\225\184\172",["Izhitsacyrillic"]="\209\180",
["Izhitsadblgravecyrillic"]="\209\182",["J"]="J",["Jaarmenian"]="\213\129",["Jcircle"]="\226\146\191",
["Jcircumflex"]="\196\180",["Jecyrillic"]="\208\136",["Jheharmenian"]="\213\139",["Jmonospace"]="\239\188\170",
["Jsmall"]="\239\157\170",["K"]="K",["KBsquare"]="\227\142\133",["KKsquare"]="\227\143\141",["Kabashkircyrillic"]="\210\160",
["Kacute"]="\225\184\176",["Kacyrillic"]="\208\154",["Kadescendercyrillic"]="\210\154",["Kahookcyrillic"]="\211\131",
["Kappa"]="\206\154",["Kastrokecyrillic"]="\210\158",["Kaverticalstrokecyrillic"]="\210\156",["Kcaron"]="\199\168",
["Kcedilla"]="\196\182",["Kcircle"]="\226\147\128",["Kcommaaccent"]="\196\182",["Kdotbelow"]="\225\184\178",
["Keharmenian"]="\213\148",["Kenarmenian"]="\212\191",["Khacyrillic"]="\208\165",["Kheicoptic"]="\207\166",
["Khook"]="\198\152",["Kjecyrillic"]="\208\140",["Klinebelow"]="\225\184\180",["Kmonospace"]="\239\188\171",
["Koppacyrillic"]="\210\128",["Koppagreek"]="\207\158",["Ksicyrillic"]="\209\174",["Ksmall"]="\239\157\171",
["L"]="L",["LJ"]="\199\135",["LL"]="\239\154\191",["Lacute"]="\196\185",["Lambda"]="\206\155",["Lcaron"]="\196\189",
["Lcedilla"]="\196\187",["Lcircle"]="\226\147\129",["Lcircumflexbelow"]="\225\184\188",["Lcommaaccent"]="\196\187",
["Ldot"]="\196\191",["Ldotaccent"]="\196\191",["Ldotbelow"]="\225\184\182",["Ldotbelowmacron"]="\225\184\184",
["Liwnarmenian"]="\212\188",["Lj"]="\199\136",["Ljecyrillic"]="\208\137",["Llinebelow"]="\225\184\186",
["Lmonospace"]="\239\188\172",["Lslash"]="\197\129",["Lslashsmall"]="\239\155\185",["Lsmall"]="\239\157\172",
["M"]="M",["MBsquare"]="\227\142\134",["Macron"]="\239\155\144",["Macronsmall"]="\239\158\175",["Macute"]="\225\184\190",
["Mcircle"]="\226\147\130",["Mdotaccent"]="\225\185\128",["Mdotbelow"]="\225\185\130",["Menarmenian"]="\213\132",
["Mmonospace"]="\239\188\173",["Msmall"]="\239\157\173",["Mturned"]="\198\156",["Mu"]="\206\156",["N"]="N",
["NJ"]="\199\138",["Nacute"]="\197\131",["Ncaron"]="\197\135",["Ncedilla"]="\197\133",["Ncircle"]="\226\147\131",
["Ncircumflexbelow"]="\225\185\138",["Ncommaaccent"]="\197\133",["Ndotaccent"]="\225\185\132",["Ndotbelow"]="\225\185\134",
["Nhookleft"]="\198\157",["Nineroman"]="\226\133\168",["Nj"]="\199\139",["Njecyrillic"]="\208\138",["Nlinebelow"]="\225\185\136",
["Nmonospace"]="\239\188\174",["Nowarmenian"]="\213\134",["Nsmall"]="\239\157\174",["Ntilde"]="\195\145",
["Ntildesmall"]="\239\159\177",["Nu"]="\206\157",["O"]="O",["OE"]="\197\146",["OEsmall"]="\239\155\186",
["Oacute"]="\195\147",["Oacutesmall"]="\239\159\179",["Obarredcyrillic"]="\211\168",["Obarreddieresiscyrillic"]="\211\170",
["Obreve"]="\197\142",["Ocaron"]="\199\145",["Ocenteredtilde"]="\198\159",["Ocircle"]="\226\147\132",
["Ocircumflex"]="\195\148",["Ocircumflexacute"]="\225\187\144",["Ocircumflexdotbelow"]="\225\187\152",
["Ocircumflexgrave"]="\225\187\146",["Ocircumflexhookabove"]="\225\187\148",["Ocircumflexsmall"]="\239\159\180",
["Ocircumflextilde"]="\225\187\150",["Ocyrillic"]="\208\158",["Odblacute"]="\197\144",["Odblgrave"]="\200\140",
["Odieresis"]="\195\150",["Odieresiscyrillic"]="\211\166",["Odieresissmall"]="\239\159\182",["Odotbelow"]="\225\187\140",
["Ogoneksmall"]="\239\155\187",["Ograve"]="\195\146",["Ogravesmall"]="\239\159\178",["Oharmenian"]="\213\149",
["Ohm"]="\226\132\166",["Ohookabove"]="\225\187\142",["Ohorn"]="\198\160",["Ohornacute"]="\225\187\154",
["Ohorndotbelow"]="\225\187\162",["Ohorngrave"]="\225\187\156",["Ohornhookabove"]="\225\187\158",["Ohorntilde"]="\225\187\160",
["Ohungarumlaut"]="\197\144",["Oi"]="\198\162",["Oinvertedbreve"]="\200\142",["Omacron"]="\197\140",["Omacronacute"]="\225\185\146",
["Omacrongrave"]="\225\185\144",["Omega"]="\226\132\166",["Omegacyrillic"]="\209\160",["Omegagreek"]="\206\169",
["Omegaroundcyrillic"]="\209\186",["Omegatitlocyrillic"]="\209\188",["Omegatonos"]="\206\143",["Omicron"]="\206\159",
["Omicrontonos"]="\206\140",["Omonospace"]="\239\188\175",["Oneroman"]="\226\133\160",["Oogonek"]="\199\170",
["Oogonekmacron"]="\199\172",["Oopen"]="\198\134",["Oslash"]="\195\152",["Oslashacute"]="\199\190",["Oslashsmall"]="\239\159\184",
["Osmall"]="\239\157\175",["Ostrokeacute"]="\199\190",["Otcyrillic"]="\209\190",["Otilde"]="\195\149",
["Otildeacute"]="\225\185\140",["Otildedieresis"]="\225\185\142",["Otildesmall"]="\239\159\181",["P"]="P",
["Pacute"]="\225\185\148",["Pcircle"]="\226\147\133",["Pdotaccent"]="\225\185\150",["Pecyrillic"]="\208\159",
["Peharmenian"]="\213\138",["Pemiddlehookcyrillic"]="\210\166",["Phi"]="\206\166",["Phook"]="\198\164",
["Pi"]="\206\160",["Piwrarmenian"]="\213\147",["Pmonospace"]="\239\188\176",["Psi"]="\206\168",["Psicyrillic"]="\209\176",
["Psmall"]="\239\157\176",["Q"]="Q",["Qcircle"]="\226\147\134",["Qmonospace"]="\239\188\177",["Qsmall"]="\239\157\177",
["R"]="R",["Raarmenian"]="\213\140",["Racute"]="\197\148",["Rcaron"]="\197\152",["Rcedilla"]="\197\150",
["Rcircle"]="\226\147\135",["Rcommaaccent"]="\197\150",["Rdblgrave"]="\200\144",["Rdotaccent"]="\225\185\152",
["Rdotbelow"]="\225\185\154",["Rdotbelowmacron"]="\225\185\156",["Reharmenian"]="\213\144",["Rfraktur"]="\226\132\156",
["Rho"]="\206\161",["Ringsmall"]="\239\155\188",["Rinvertedbreve"]="\200\146",["Rlinebelow"]="\225\185\158",
["Rmonospace"]="\239\188\178",["Rsmall"]="\239\157\178",["Rsmallinverted"]="\202\129",["Rsmallinvertedsuperior"]="\202\182",
["S"]="S",["SF010000"]="\226\148\140",["SF020000"]="\226\148\148",["SF030000"]="\226\148\144",["SF040000"]="\226\148\152",
["SF050000"]="\226\148\188",["SF060000"]="\226\148\172",["SF070000"]="\226\148\180",["SF080000"]="\226\148\156",
["SF090000"]="\226\148\164",["SF100000"]="\226\148\128",["SF110000"]="\226\148\130",["SF190000"]="\226\149\161",
["SF200000"]="\226\149\162",["SF210000"]="\226\149\150",["SF220000"]="\226\149\149",["SF230000"]="\226\149\163",
["SF240000"]="\226\149\145",["SF250000"]="\226\149\151",["SF260000"]="\226\149\157",["SF270000"]="\226\149\156",
["SF280000"]="\226\149\155",["SF360000"]="\226\149\158",["SF370000"]="\226\149\159",["SF380000"]="\226\149\154",
["SF390000"]="\226\149\148",["SF400000"]="\226\149\169",["SF410000"]="\226\149\166",["SF420000"]="\226\149\160",
["SF430000"]="\226\149\144",["SF440000"]="\226\149\172",["SF450000"]="\226\149\167",["SF460000"]="\226\149\168",
["SF470000"]="\226\149\164",["SF480000"]="\226\149\165",["SF490000"]="\226\149\153",["SF500000"]="\226\149\152",
["SF510000"]="\226\149\146",["SF520000"]="\226\149\147",["SF530000"]="\226\149\171",["SF540000"]="\226\149\170",
["Sacute"]="\197\154",["Sacutedotaccent"]="\225\185\164",["Sampigreek"]="\207\160",["Scaron"]="\197\160",
["Scarondotaccent"]="\225\185\166",["Scaronsmall"]="\239\155\189",["Scedilla"]="\197\158",["Schwa"]="\198\143",
["Schwacyrillic"]="\211\152",["Schwadieresiscyrillic"]="\211\154",["Scircle"]="\226\147\136",["Scircumflex"]="\197\156",
["Scommaaccent"]="\200\152",["Sdotaccent"]="\225\185\160",["Sdotbelow"]="\225\185\162",["Sdotbelowdotaccent"]="\225\185\168",
["Seharmenian"]="\213\141",["Sevenroman"]="\226\133\166",["Shaarmenian"]="\213\135",["Shacyrillic"]="\208\168",
["Shchacyrillic"]="\208\169",["Sheicoptic"]="\207\162",["Shhacyrillic"]="\210\186",["Shimacoptic"]="\207\172",
["Sigma"]="\206\163",["Sixroman"]="\226\133\165",["Smonospace"]="\239\188\179",["Softsigncyrillic"]="\208\172",
["Ssmall"]="\239\157\179",["Stigmagreek"]="\207\154",["T"]="T",["Tau"]="\206\164",["Tbar"]="\197\166",
["Tcaron"]="\197\164",["Tcedilla"]="\197\162",["Tcircle"]="\226\147\137",["Tcircumflexbelow"]="\225\185\176",
["Tcommaaccent"]="\197\162",["Tdotaccent"]="\225\185\170",["Tdotbelow"]="\225\185\172",["Tecyrillic"]="\208\162",
["Tedescendercyrillic"]="\210\172",["Tenroman"]="\226\133\169",["Tetsecyrillic"]="\210\180",["Theta"]="\206\152",
["Thook"]="\198\172",["Thorn"]="\195\158",["Thornsmall"]="\239\159\190",["Threeroman"]="\226\133\162",
["Tildesmall"]="\239\155\190",["Tiwnarmenian"]="\213\143",["Tlinebelow"]="\225\185\174",["Tmonospace"]="\239\188\180",
["Toarmenian"]="\212\185",["Tonefive"]="\198\188",["Tonesix"]="\198\132",["Tonetwo"]="\198\167",["Tretroflexhook"]="\198\174",
["Tsecyrillic"]="\208\166",["Tshecyrillic"]="\208\139",["Tsmall"]="\239\157\180",["Twelveroman"]="\226\133\171",
["Tworoman"]="\226\133\161",["U"]="U",["Uacute"]="\195\154",["Uacutesmall"]="\239\159\186",["Ubreve"]="\197\172",
["Ucaron"]="\199\147",["Ucircle"]="\226\147\138",["Ucircumflex"]="\195\155",["Ucircumflexbelow"]="\225\185\182",
["Ucircumflexsmall"]="\239\159\187",["Ucyrillic"]="\208\163",["Udblacute"]="\197\176",["Udblgrave"]="\200\148",
["Udieresis"]="\195\156",["Udieresisacute"]="\199\151",["Udieresisbelow"]="\225\185\178",["Udieresiscaron"]="\199\153",
["Udieresiscyrillic"]="\211\176",["Udieresisgrave"]="\199\155",["Udieresismacron"]="\199\149",["Udieresissmall"]="\239\159\188",
["Udotbelow"]="\225\187\164",["Ugrave"]="\195\153",["Ugravesmall"]="\239\159\185",["Uhookabove"]="\225\187\166",
["Uhorn"]="\198\175",["Uhornacute"]="\225\187\168",["Uhorndotbelow"]="\225\187\176",["Uhorngrave"]="\225\187\170",
["Uhornhookabove"]="\225\187\172",["Uhorntilde"]="\225\187\174",["Uhungarumlaut"]="\197\176",["Uhungarumlautcyrillic"]="\211\178",
["Uinvertedbreve"]="\200\150",["Ukcyrillic"]="\209\184",["Umacron"]="\197\170",["Umacroncyrillic"]="\211\174",
["Umacrondieresis"]="\225\185\186",["Umonospace"]="\239\188\181",["Uogonek"]="\197\178",["Upsilon"]="\206\165",
["Upsilon1"]="\207\146",["Upsilonacutehooksymbolgreek"]="\207\147",["Upsilonafrican"]="\198\177",["Upsilondieresis"]="\206\171",
["Upsilondieresishooksymbolgreek"]="\207\148",["Upsilonhooksymbol"]="\207\146",["Upsilontonos"]="\206\142",
["Uring"]="\197\174",["Ushortcyrillic"]="\208\142",["Usmall"]="\239\157\181",["Ustraightcyrillic"]="\210\174",
["Ustraightstrokecyrillic"]="\210\176",["Utilde"]="\197\168",["Utildeacute"]="\225\185\184",["Utildebelow"]="\225\185\180",
["V"]="V",["Vcircle"]="\226\147\139",["Vdotbelow"]="\225\185\190",["Vecyrillic"]="\208\146",["Vewarmenian"]="\213\142",
["Vhook"]="\198\178",["Vmonospace"]="\239\188\182",["Voarmenian"]="\213\136",["Vsmall"]="\239\157\182",
["Vtilde"]="\225\185\188",["W"]="W",["Wacute"]="\225\186\130",["Wcircle"]="\226\147\140",["Wcircumflex"]="\197\180",
["Wdieresis"]="\225\186\132",["Wdotaccent"]="\225\186\134",["Wdotbelow"]="\225\186\136",["Wgrave"]="\225\186\128",
["Wmonospace"]="\239\188\183",["Wsmall"]="\239\157\183",["X"]="X",["Xcircle"]="\226\147\141",["Xdieresis"]="\225\186\140",
["Xdotaccent"]="\225\186\138",["Xeharmenian"]="\212\189",["Xi"]="\206\158",["Xmonospace"]="\239\188\184",
["Xsmall"]="\239\157\184",["Y"]="Y",["Yacute"]="\195\157",["Yacutesmall"]="\239\159\189",["Yatcyrillic"]="\209\162",
["Ycircle"]="\226\147\142",["Ycircumflex"]="\197\182",["Ydieresis"]="\197\184",["Ydieresissmall"]="\239\159\191",
["Ydotaccent"]="\225\186\142",["Ydotbelow"]="\225\187\180",["Yericyrillic"]="\208\171",["Yerudieresiscyrillic"]="\211\184",
["Ygrave"]="\225\187\178",["Yhook"]="\198\179",["Yhookabove"]="\225\187\182",["Yiarmenian"]="\213\133",
["Yicyrillic"]="\208\135",["Yiwnarmenian"]="\213\146",["Ymonospace"]="\239\188\185",["Ysmall"]="\239\157\185",
["Ytilde"]="\225\187\184",["Yusbigcyrillic"]="\209\170",["Yusbigiotifiedcyrillic"]="\209\172",["Yuslittlecyrillic"]="\209\166",
["Yuslittleiotifiedcyrillic"]="\209\168",["Z"]="Z",["Zaarmenian"]="\212\182",["Zacute"]="\197\185",["Zcaron"]="\197\189",
["Zcaronsmall"]="\239\155\191",["Zcircle"]="\226\147\143",["Zcircumflex"]="\225\186\144",["Zdot"]="\197\187",
["Zdotaccent"]="\197\187",["Zdotbelow"]="\225\186\146",["Zecyrillic"]="\208\151",["Zedescendercyrillic"]="\210\152",
["Zedieresiscyrillic"]="\211\158",["Zeta"]="\206\150",["Zhearmenian"]="\212\186",["Zhebrevecyrillic"]="\211\129",
["Zhecyrillic"]="\208\150",["Zhedescendercyrillic"]="\210\150",["Zhedieresiscyrillic"]="\211\156",["Zlinebelow"]="\225\186\148",
["Zmonospace"]="\239\188\186",["Zsmall"]="\239\157\186",["Zstroke"]="\198\181",["a"]="a",["aabengali"]="\224\166\134",
["aacute"]="\195\161",["aadeva"]="\224\164\134",["aagujarati"]="\224\170\134",["aagurmukhi"]="\224\168\134",
["aamatragurmukhi"]="\224\168\190",["aarusquare"]="\227\140\131",["aavowelsignbengali"]="\224\166\190",
["aavowelsigndeva"]="\224\164\190",["aavowelsigngujarati"]="\224\170\190",["abbreviationmarkarmenian"]="\213\159",
["abbreviationsigndeva"]="\224\165\176",["abengali"]="\224\166\133",["abopomofo"]="\227\132\154",["abreve"]="\196\131",
["abreveacute"]="\225\186\175",["abrevecyrillic"]="\211\145",["abrevedotbelow"]="\225\186\183",["abrevegrave"]="\225\186\177",
["abrevehookabove"]="\225\186\179",["abrevetilde"]="\225\186\181",["acaron"]="\199\142",["acircle"]="\226\147\144",
["acircumflex"]="\195\162",["acircumflexacute"]="\225\186\165",["acircumflexdotbelow"]="\225\186\173",
["acircumflexgrave"]="\225\186\167",["acircumflexhookabove"]="\225\186\169",["acircumflextilde"]="\225\186\171",
["acute"]="\194\180",["acutebelowcmb"]="\204\151",["acutecmb"]="\204\129",["acutecomb"]="\204\129",["acutedeva"]="\224\165\148",
["acutelowmod"]="\203\143",["acutetonecmb"]="\205\129",["acyrillic"]="\208\176",["adblgrave"]="\200\129",
["addakgurmukhi"]="\224\169\177",["adeva"]="\224\164\133",["adieresis"]="\195\164",["adieresiscyrillic"]="\211\147",
["adieresismacron"]="\199\159",["adotbelow"]="\225\186\161",["adotmacron"]="\199\161",["ae"]="\195\166",
["aeacute"]="\199\189",["aekorean"]="\227\133\144",["aemacron"]="\199\163",["afii00208"]="\226\128\149",
["afii08941"]="\226\130\164",["afii10017"]="\208\144",["afii10018"]="\208\145",["afii10019"]="\208\146",
["afii10020"]="\208\147",["afii10021"]="\208\148",["afii10022"]="\208\149",["afii10023"]="\208\129",["afii10024"]="\208\150",
["afii10025"]="\208\151",["afii10026"]="\208\152",["afii10027"]="\208\153",["afii10028"]="\208\154",["afii10029"]="\208\155",
["afii10030"]="\208\156",["afii10031"]="\208\157",["afii10032"]="\208\158",["afii10033"]="\208\159",["afii10034"]="\208\160",
["afii10035"]="\208\161",["afii10036"]="\208\162",["afii10037"]="\208\163",["afii10038"]="\208\164",["afii10039"]="\208\165",
["afii10040"]="\208\166",["afii10041"]="\208\167",["afii10042"]="\208\168",["afii10043"]="\208\169",["afii10044"]="\208\170",
["afii10045"]="\208\171",["afii10046"]="\208\172",["afii10047"]="\208\173",["afii10048"]="\208\174",["afii10049"]="\208\175",
["afii10050"]="\210\144",["afii10051"]="\208\130",["afii10052"]="\208\131",["afii10053"]="\208\132",["afii10054"]="\208\133",
["afii10055"]="\208\134",["afii10056"]="\208\135",["afii10057"]="\208\136",["afii10058"]="\208\137",["afii10059"]="\208\138",
["afii10060"]="\208\139",["afii10061"]="\208\140",["afii10062"]="\208\142",["afii10063"]="\239\155\132",
["afii10064"]="\239\155\133",["afii10065"]="\208\176",["afii10066"]="\208\177",["afii10067"]="\208\178",
["afii10068"]="\208\179",["afii10069"]="\208\180",["afii10070"]="\208\181",["afii10071"]="\209\145",["afii10072"]="\208\182",
["afii10073"]="\208\183",["afii10074"]="\208\184",["afii10075"]="\208\185",["afii10076"]="\208\186",["afii10077"]="\208\187",
["afii10078"]="\208\188",["afii10079"]="\208\189",["afii10080"]="\208\190",["afii10081"]="\208\191",["afii10082"]="\209\128",
["afii10083"]="\209\129",["afii10084"]="\209\130",["afii10085"]="\209\131",["afii10086"]="\209\132",["afii10087"]="\209\133",
["afii10088"]="\209\134",["afii10089"]="\209\135",["afii10090"]="\209\136",["afii10091"]="\209\137",["afii10092"]="\209\138",
["afii10093"]="\209\139",["afii10094"]="\209\140",["afii10095"]="\209\141",["afii10096"]="\209\142",["afii10097"]="\209\143",
["afii10098"]="\210\145",["afii10099"]="\209\146",["afii10100"]="\209\147",["afii10101"]="\209\148",["afii10102"]="\209\149",
["afii10103"]="\209\150",["afii10104"]="\209\151",["afii10105"]="\209\152",["afii10106"]="\209\153",["afii10107"]="\209\154",
["afii10108"]="\209\155",["afii10109"]="\209\156",["afii10110"]="\209\158",["afii10145"]="\208\143",["afii10146"]="\209\162",
["afii10147"]="\209\178",["afii10148"]="\209\180",["afii10192"]="\239\155\134",["afii10193"]="\209\159",
["afii10194"]="\209\163",["afii10195"]="\209\179",["afii10196"]="\209\181",["afii10831"]="\239\155\135",
["afii10832"]="\239\155\136",["afii10846"]="\211\153",["afii299"]="\226\128\142",["afii300"]="\226\128\143",
["afii301"]="\226\128\141",["afii57381"]="\217\170",["afii57388"]="\216\140",["afii57392"]="\217\160",
["afii57393"]="\217\161",["afii57394"]="\217\162",["afii57395"]="\217\163",["afii57396"]="\217\164",["afii57397"]="\217\165",
["afii57398"]="\217\166",["afii57399"]="\217\167",["afii57400"]="\217\168",["afii57401"]="\217\169",["afii57403"]="\216\155",
["afii57407"]="\216\159",["afii57409"]="\216\161",["afii57410"]="\216\162",["afii57411"]="\216\163",["afii57412"]="\216\164",
["afii57413"]="\216\165",["afii57414"]="\216\166",["afii57415"]="\216\167",["afii57416"]="\216\168",["afii57417"]="\216\169",
["afii57418"]="\216\170",["afii57419"]="\216\171",["afii57420"]="\216\172",["afii57421"]="\216\173",["afii57422"]="\216\174",
["afii57423"]="\216\175",["afii57424"]="\216\176",["afii57425"]="\216\177",["afii57426"]="\216\178",["afii57427"]="\216\179",
["afii57428"]="\216\180",["afii57429"]="\216\181",["afii57430"]="\216\182",["afii57431"]="\216\183",["afii57432"]="\216\184",
["afii57433"]="\216\185",["afii57434"]="\216\186",["afii57440"]="\217\128",["afii57441"]="\217\129",["afii57442"]="\217\130",
["afii57443"]="\217\131",["afii57444"]="\217\132",["afii57445"]="\217\133",["afii57446"]="\217\134",["afii57448"]="\217\136",
["afii57449"]="\217\137",["afii57450"]="\217\138",["afii57451"]="\217\139",["afii57452"]="\217\140",["afii57453"]="\217\141",
["afii57454"]="\217\142",["afii57455"]="\217\143",["afii57456"]="\217\144",["afii57457"]="\217\145",["afii57458"]="\217\146",
["afii57470"]="\217\135",["afii57505"]="\218\164",["afii57506"]="\217\190",["afii57507"]="\218\134",["afii57508"]="\218\152",
["afii57509"]="\218\175",["afii57511"]="\217\185",["afii57512"]="\218\136",["afii57513"]="\218\145",["afii57514"]="\218\186",
["afii57519"]="\219\146",["afii57534"]="\219\149",["afii57636"]="\226\130\170",["afii57645"]="\214\190",
["afii57658"]="\215\131",["afii57664"]="\215\144",["afii57665"]="\215\145",["afii57666"]="\215\146",["afii57667"]="\215\147",
["afii57668"]="\215\148",["afii57669"]="\215\149",["afii57670"]="\215\150",["afii57671"]="\215\151",["afii57672"]="\215\152",
["afii57673"]="\215\153",["afii57674"]="\215\154",["afii57675"]="\215\155",["afii57676"]="\215\156",["afii57677"]="\215\157",
["afii57678"]="\215\158",["afii57679"]="\215\159",["afii57680"]="\215\160",["afii57681"]="\215\161",["afii57682"]="\215\162",
["afii57683"]="\215\163",["afii57684"]="\215\164",["afii57685"]="\215\165",["afii57686"]="\215\166",["afii57687"]="\215\167",
["afii57688"]="\215\168",["afii57689"]="\215\169",["afii57690"]="\215\170",["afii57694"]="\239\172\170",
["afii57695"]="\239\172\171",["afii57700"]="\239\173\139",["afii57705"]="\239\172\159",["afii57716"]="\215\176",
["afii57717"]="\215\177",["afii57718"]="\215\178",["afii57723"]="\239\172\181",["afii57793"]="\214\180",
["afii57794"]="\214\181",["afii57795"]="\214\182",["afii57796"]="\214\187",["afii57797"]="\214\184",["afii57798"]="\214\183",
["afii57799"]="\214\176",["afii57800"]="\214\178",["afii57801"]="\214\177",["afii57802"]="\214\179",["afii57803"]="\215\130",
["afii57804"]="\215\129",["afii57806"]="\214\185",["afii57807"]="\214\188",["afii57839"]="\214\189",["afii57841"]="\214\191",
["afii57842"]="\215\128",["afii57929"]="\202\188",["afii61248"]="\226\132\133",["afii61289"]="\226\132\147",
["afii61352"]="\226\132\150",["afii61573"]="\226\128\172",["afii61574"]="\226\128\173",["afii61575"]="\226\128\174",
["afii61664"]="\226\128\140",["afii63167"]="\217\173",["afii64937"]="\202\189",["agrave"]="\195\160",
["agujarati"]="\224\170\133",["agurmukhi"]="\224\168\133",["ahiragana"]="\227\129\130",["ahookabove"]="\225\186\163",
["aibengali"]="\224\166\144",["aibopomofo"]="\227\132\158",["aideva"]="\224\164\144",["aiecyrillic"]="\211\149",
["aigujarati"]="\224\170\144",["aigurmukhi"]="\224\168\144",["aimatragurmukhi"]="\224\169\136",["ainarabic"]="\216\185",
["ainfinalarabic"]="\239\187\138",["aininitialarabic"]="\239\187\139",["ainmedialarabic"]="\239\187\140",
["ainvertedbreve"]="\200\131",["aivowelsignbengali"]="\224\167\136",["aivowelsigndeva"]="\224\165\136",
["aivowelsigngujarati"]="\224\171\136",["akatakana"]="\227\130\162",["akatakanahalfwidth"]="\239\189\177",
["akorean"]="\227\133\143",["alef"]="\215\144",["alefarabic"]="\216\167",["alefdageshhebrew"]="\239\172\176",
["aleffinalarabic"]="\239\186\142",["alefhamzaabovearabic"]="\216\163",["alefhamzaabovefinalarabic"]="\239\186\132",
["alefhamzabelowarabic"]="\216\165",["alefhamzabelowfinalarabic"]="\239\186\136",["alefhebrew"]="\215\144",
["aleflamedhebrew"]="\239\173\143",["alefmaddaabovearabic"]="\216\162",["alefmaddaabovefinalarabic"]="\239\186\130",
["alefmaksuraarabic"]="\217\137",["alefmaksurafinalarabic"]="\239\187\176",["alefmaksurainitialarabic"]="\239\187\179",
["alefmaksuramedialarabic"]="\239\187\180",["alefpatahhebrew"]="\239\172\174",["alefqamatshebrew"]="\239\172\175",
["aleph"]="\226\132\181",["allequal"]="\226\137\140",["alpha"]="\206\177",["alphatonos"]="\206\172",["amacron"]="\196\129",
["amonospace"]="\239\189\129",["ampersand"]="&",["ampersandmonospace"]="\239\188\134",["ampersandsmall"]="\239\156\166",
["amsquare"]="\227\143\130",["anbopomofo"]="\227\132\162",["angbopomofo"]="\227\132\164",["angkhankhuthai"]="\224\185\154",
["angle"]="\226\136\160",["anglebracketleft"]="\227\128\136",["anglebracketleftvertical"]="\239\184\191",
["anglebracketright"]="\227\128\137",["anglebracketrightvertical"]="\239\185\128",["angleleft"]="\226\140\169",
["angleright"]="\226\140\170",["angstrom"]="\226\132\171",["anoteleia"]="\206\135",["anudattadeva"]="\224\165\146",
["anusvarabengali"]="\224\166\130",["anusvaradeva"]="\224\164\130",["anusvaragujarati"]="\224\170\130",
["aogonek"]="\196\133",["apaatosquare"]="\227\140\128",["aparen"]="\226\146\156",["apostrophearmenian"]="\213\154",
["apostrophemod"]="\202\188",["apple"]="\239\163\191",["approaches"]="\226\137\144",["approxequal"]="\226\137\136",
["approxequalorimage"]="\226\137\146",["approximatelyequal"]="\226\137\133",["araeaekorean"]="\227\134\142",
["araeakorean"]="\227\134\141",["arc"]="\226\140\146",["arighthalfring"]="\225\186\154",["aring"]="\195\165",
["aringacute"]="\199\187",["aringbelow"]="\225\184\129",["arrowboth"]="\226\134\148",["arrowdashdown"]="\226\135\163",
["arrowdashleft"]="\226\135\160",["arrowdashright"]="\226\135\162",["arrowdashup"]="\226\135\161",["arrowdblboth"]="\226\135\148",
["arrowdbldown"]="\226\135\147",["arrowdblleft"]="\226\135\144",["arrowdblright"]="\226\135\146",["arrowdblup"]="\226\135\145",
["arrowdown"]="\226\134\147",["arrowdownleft"]="\226\134\153",["arrowdownright"]="\226\134\152",["arrowdownwhite"]="\226\135\169",
["arrowheaddownmod"]="\203\133",["arrowheadleftmod"]="\203\130",["arrowheadrightmod"]="\203\131",["arrowheadupmod"]="\203\132",
["arrowhorizex"]="\239\163\167",["arrowleft"]="\226\134\144",["arrowleftdbl"]="\226\135\144",["arrowleftdblstroke"]="\226\135\141",
["arrowleftoverright"]="\226\135\134",["arrowleftwhite"]="\226\135\166",["arrowright"]="\226\134\146",
["arrowrightdblstroke"]="\226\135\143",["arrowrightheavy"]="\226\158\158",["arrowrightoverleft"]="\226\135\132",
["arrowrightwhite"]="\226\135\168",["arrowtableft"]="\226\135\164",["arrowtabright"]="\226\135\165",["arrowup"]="\226\134\145",
["arrowupdn"]="\226\134\149",["arrowupdnbse"]="\226\134\168",["arrowupdownbase"]="\226\134\168",["arrowupleft"]="\226\134\150",
["arrowupleftofdown"]="\226\135\133",["arrowupright"]="\226\134\151",["arrowupwhite"]="\226\135\167",
["arrowvertex"]="\239\163\166",["asciicircum"]="^",["asciicircummonospace"]="\239\188\190",["asciitilde"]="~",
["asciitildemonospace"]="\239\189\158",["ascript"]="\201\145",["ascriptturned"]="\201\146",["asmallhiragana"]="\227\129\129",
["asmallkatakana"]="\227\130\161",["asmallkatakanahalfwidth"]="\239\189\167",["asterisk"]="*",["asteriskaltonearabic"]="\217\173",
["asteriskarabic"]="\217\173",["asteriskmath"]="\226\136\151",["asteriskmonospace"]="\239\188\138",["asterisksmall"]="\239\185\161",
["asterism"]="\226\129\130",["asuperior"]="\239\155\169",["asymptoticallyequal"]="\226\137\131",["at"]="@",
["atilde"]="\195\163",["atmonospace"]="\239\188\160",["atsmall"]="\239\185\171",["aturned"]="\201\144",
["aubengali"]="\224\166\148",["aubopomofo"]="\227\132\160",["audeva"]="\224\164\148",["augujarati"]="\224\170\148",
["augurmukhi"]="\224\168\148",["aulengthmarkbengali"]="\224\167\151",["aumatragurmukhi"]="\224\169\140",
["auvowelsignbengali"]="\224\167\140",["auvowelsigndeva"]="\224\165\140",["auvowelsigngujarati"]="\224\171\140",
["avagrahadeva"]="\224\164\189",["aybarmenian"]="\213\161",["ayin"]="\215\162",["ayinaltonehebrew"]="\239\172\160",
["ayinhebrew"]="\215\162",["b"]="b",["babengali"]="\224\166\172",["backslash"]="\\",["backslashmonospace"]="\239\188\188",
["badeva"]="\224\164\172",["bagujarati"]="\224\170\172",["bagurmukhi"]="\224\168\172",["bahiragana"]="\227\129\176",
["bahtthai"]="\224\184\191",["bakatakana"]="\227\131\144",["bar"]="|",["barmonospace"]="\239\189\156",
["bbopomofo"]="\227\132\133",["bcircle"]="\226\147\145",["bdotaccent"]="\225\184\131",["bdotbelow"]="\225\184\133",
["beamedsixteenthnotes"]="\226\153\172",["because"]="\226\136\181",["becyrillic"]="\208\177",["beharabic"]="\216\168",
["behfinalarabic"]="\239\186\144",["behinitialarabic"]="\239\186\145",["behiragana"]="\227\129\185",["behmedialarabic"]="\239\186\146",
["behmeeminitialarabic"]="\239\178\159",["behmeemisolatedarabic"]="\239\176\136",["behnoonfinalarabic"]="\239\177\173",
["bekatakana"]="\227\131\153",["benarmenian"]="\213\162",["bet"]="\215\145",["beta"]="\206\178",["betasymbolgreek"]="\207\144",
["betdagesh"]="\239\172\177",["betdageshhebrew"]="\239\172\177",["bethebrew"]="\215\145",["betrafehebrew"]="\239\173\140",
["bhabengali"]="\224\166\173",["bhadeva"]="\224\164\173",["bhagujarati"]="\224\170\173",["bhagurmukhi"]="\224\168\173",
["bhook"]="\201\147",["bihiragana"]="\227\129\179",["bikatakana"]="\227\131\147",["bilabialclick"]="\202\152",
["bindigurmukhi"]="\224\168\130",["birusquare"]="\227\140\177",["blackcircle"]="\226\151\143",["blackdiamond"]="\226\151\134",
["blackdownpointingtriangle"]="\226\150\188",["blackleftpointingpointer"]="\226\151\132",["blackleftpointingtriangle"]="\226\151\128",
["blacklenticularbracketleft"]="\227\128\144",["blacklenticularbracketleftvertical"]="\239\184\187",["blacklenticularbracketright"]="\227\128\145",
["blacklenticularbracketrightvertical"]="\239\184\188",["blacklowerlefttriangle"]="\226\151\163",["blacklowerrighttriangle"]="\226\151\162",
["blackrectangle"]="\226\150\172",["blackrightpointingpointer"]="\226\150\186",["blackrightpointingtriangle"]="\226\150\182",
["blacksmallsquare"]="\226\150\170",["blacksmilingface"]="\226\152\187",["blacksquare"]="\226\150\160",
["blackstar"]="\226\152\133",["blackupperlefttriangle"]="\226\151\164",["blackupperrighttriangle"]="\226\151\165",
["blackuppointingsmalltriangle"]="\226\150\180",["blackuppointingtriangle"]="\226\150\178",["blank"]="\226\144\163",
["blinebelow"]="\225\184\135",["block"]="\226\150\136",["bmonospace"]="\239\189\130",["bobaimaithai"]="\224\184\154",
["bohiragana"]="\227\129\188",["bokatakana"]="\227\131\156",["bparen"]="\226\146\157",["bqsquare"]="\227\143\131",
["braceex"]="\239\163\180",["braceleft"]="{",["braceleftbt"]="\239\163\179",["braceleftmid"]="\239\163\178",
["braceleftmonospace"]="\239\189\155",["braceleftsmall"]="\239\185\155",["bracelefttp"]="\239\163\177",
["braceleftvertical"]="\239\184\183",["braceright"]="}",["bracerightbt"]="\239\163\190",["bracerightmid"]="\239\163\189",
["bracerightmonospace"]="\239\189\157",["bracerightsmall"]="\239\185\156",["bracerighttp"]="\239\163\188",
["bracerightvertical"]="\239\184\184",["bracketleft"]="[",["bracketleftbt"]="\239\163\176",["bracketleftex"]="\239\163\175",
["bracketleftmonospace"]="\239\188\187",["bracketlefttp"]="\239\163\174",["bracketright"]="]",["bracketrightbt"]="\239\163\187",
["bracketrightex"]="\239\163\186",["bracketrightmonospace"]="\239\188\189",["bracketrighttp"]="\239\163\185",
["breve"]="\203\152",["brevebelowcmb"]="\204\174",["brevecmb"]="\204\134",["breveinvertedbelowcmb"]="\204\175",
["breveinvertedcmb"]="\204\145",["breveinverteddoublecmb"]="\205\161",["bridgebelowcmb"]="\204\170",["bridgeinvertedbelowcmb"]="\204\186",
["brokenbar"]="\194\166",["bstroke"]="\198\128",["bsuperior"]="\239\155\170",["btopbar"]="\198\131",["buhiragana"]="\227\129\182",
["bukatakana"]="\227\131\150",["bullet"]="\226\128\162",["bulletinverse"]="\226\151\152",["bulletoperator"]="\226\136\153",
["bullseye"]="\226\151\142",["c"]="c",["caarmenian"]="\213\174",["cabengali"]="\224\166\154",["cacute"]="\196\135",
["cadeva"]="\224\164\154",["cagujarati"]="\224\170\154",["cagurmukhi"]="\224\168\154",["calsquare"]="\227\142\136",
["candrabindubengali"]="\224\166\129",["candrabinducmb"]="\204\144",["candrabindudeva"]="\224\164\129",
["candrabindugujarati"]="\224\170\129",["capslock"]="\226\135\170",["careof"]="\226\132\133",["caron"]="\203\135",
["caronbelowcmb"]="\204\172",["caroncmb"]="\204\140",["carriagereturn"]="\226\134\181",["cbopomofo"]="\227\132\152",
["ccaron"]="\196\141",["ccedilla"]="\195\167",["ccedillaacute"]="\225\184\137",["ccircle"]="\226\147\146",
["ccircumflex"]="\196\137",["ccurl"]="\201\149",["cdot"]="\196\139",["cdotaccent"]="\196\139",["cdsquare"]="\227\143\133",
["cedilla"]="\194\184",["cedillacmb"]="\204\167",["cent"]="\194\162",["centigrade"]="\226\132\131",["centinferior"]="\239\155\159",
["centmonospace"]="\239\191\160",["centoldstyle"]="\239\158\162",["centsuperior"]="\239\155\160",["chaarmenian"]="\213\185",
["chabengali"]="\224\166\155",["chadeva"]="\224\164\155",["chagujarati"]="\224\170\155",["chagurmukhi"]="\224\168\155",
["chbopomofo"]="\227\132\148",["cheabkhasiancyrillic"]="\210\189",["checkmark"]="\226\156\147",["checyrillic"]="\209\135",
["chedescenderabkhasiancyrillic"]="\210\191",["chedescendercyrillic"]="\210\183",["chedieresiscyrillic"]="\211\181",
["cheharmenian"]="\213\179",["chekhakassiancyrillic"]="\211\140",["cheverticalstrokecyrillic"]="\210\185",
["chi"]="\207\135",["chieuchacirclekorean"]="\227\137\183",["chieuchaparenkorean"]="\227\136\151",["chieuchcirclekorean"]="\227\137\169",
["chieuchkorean"]="\227\133\138",["chieuchparenkorean"]="\227\136\137",["chochangthai"]="\224\184\138",
["chochanthai"]="\224\184\136",["chochingthai"]="\224\184\137",["chochoethai"]="\224\184\140",["chook"]="\198\136",
["cieucacirclekorean"]="\227\137\182",["cieucaparenkorean"]="\227\136\150",["cieuccirclekorean"]="\227\137\168",
["cieuckorean"]="\227\133\136",["cieucparenkorean"]="\227\136\136",["cieucuparenkorean"]="\227\136\156",
["circle"]="\226\151\139",["circlemultiply"]="\226\138\151",["circleot"]="\226\138\153",["circleplus"]="\226\138\149",
["circlepostalmark"]="\227\128\182",["circlewithlefthalfblack"]="\226\151\144",["circlewithrighthalfblack"]="\226\151\145",
["circumflex"]="\203\134",["circumflexbelowcmb"]="\204\173",["circumflexcmb"]="\204\130",["clear"]="\226\140\167",
["clickalveolar"]="\199\130",["clickdental"]="\199\128",["clicklateral"]="\199\129",["clickretroflex"]="\199\131",
["club"]="\226\153\163",["clubsuitblack"]="\226\153\163",["clubsuitwhite"]="\226\153\167",["cmcubedsquare"]="\227\142\164",
["cmonospace"]="\239\189\131",["cmsquaredsquare"]="\227\142\160",["coarmenian"]="\214\129",["colon"]=":",
["colonmonetary"]="\226\130\161",["colonmonospace"]="\239\188\154",["colonsign"]="\226\130\161",["colonsmall"]="\239\185\149",
["colontriangularhalfmod"]="\203\145",["colontriangularmod"]="\203\144",["comma"]=",",["commaabovecmb"]="\204\147",
["commaaboverightcmb"]="\204\149",["commaaccent"]="\239\155\131",["commaarabic"]="\216\140",["commaarmenian"]="\213\157",
["commainferior"]="\239\155\161",["commamonospace"]="\239\188\140",["commareversedabovecmb"]="\204\148",
["commareversedmod"]="\202\189",["commasmall"]="\239\185\144",["commasuperior"]="\239\155\162",["commaturnedabovecmb"]="\204\146",
["commaturnedmod"]="\202\187",["compass"]="\226\152\188",["congruent"]="\226\137\133",["contourintegral"]="\226\136\174",
["control"]="\226\140\131",["controlACK"]="\6",["controlBEL"]="\7",["controlBS"]="\8",["controlCAN"]="\24",
["controlCR"]="\13",["controlDC1"]="\17",["controlDC2"]="\18",["controlDC3"]="\19",["controlDC4"]="\20",
["controlDEL"]="\127",["controlDLE"]="\16",["controlEM"]="\25",["controlENQ"]="\5",["controlEOT"]="\4",
["controlESC"]="\27",["controlETB"]="\23",["controlETX"]="\3",["controlFF"]="\12",["controlFS"]="\28",
["controlGS"]="\29",["controlHT"]="\9",["controlLF"]="\10",["controlNAK"]="\21",["controlRS"]="\30",["controlSI"]="\15",
["controlSO"]="\14",["controlSOT"]="\2",["controlSTX"]="\1",["controlSUB"]="\26",["controlSYN"]="\22",
["controlUS"]="\31",["controlVT"]="\11",["copyright"]="\194\169",["copyrightsans"]="\239\163\169",["copyrightserif"]="\239\155\153",
["cornerbracketleft"]="\227\128\140",["cornerbracketlefthalfwidth"]="\239\189\162",["cornerbracketleftvertical"]="\239\185\129",
["cornerbracketright"]="\227\128\141",["cornerbracketrighthalfwidth"]="\239\189\163",["cornerbracketrightvertical"]="\239\185\130",
["corporationsquare"]="\227\141\191",["cosquare"]="\227\143\135",["coverkgsquare"]="\227\143\134",["cparen"]="\226\146\158",
["cruzeiro"]="\226\130\162",["cstretched"]="\202\151",["curlyand"]="\226\139\143",["curlyor"]="\226\139\142",
["currency"]="\194\164",["cyrBreve"]="\239\155\145",["cyrFlex"]="\239\155\146",["cyrbreve"]="\239\155\148",
["cyrflex"]="\239\155\149",["d"]="d",["daarmenian"]="\213\164",["dabengali"]="\224\166\166",["dadarabic"]="\216\182",
["dadeva"]="\224\164\166",["dadfinalarabic"]="\239\186\190",["dadinitialarabic"]="\239\186\191",["dadmedialarabic"]="\239\187\128",
["dagesh"]="\214\188",["dageshhebrew"]="\214\188",["dagger"]="\226\128\160",["daggerdbl"]="\226\128\161",
["dagujarati"]="\224\170\166",["dagurmukhi"]="\224\168\166",["dahiragana"]="\227\129\160",["dakatakana"]="\227\131\128",
["dalarabic"]="\216\175",["dalet"]="\215\147",["daletdagesh"]="\239\172\179",["daletdageshhebrew"]="\239\172\179",
["dalethatafpatah"]="\215\147\214\178",["dalethatafpatahhebrew"]="\215\147\214\178",["dalethatafsegol"]="\215\147\214\177",
["dalethatafsegolhebrew"]="\215\147\214\177",["dalethebrew"]="\215\147",["dalethiriq"]="\215\147\214\180",
["dalethiriqhebrew"]="\215\147\214\180",["daletholam"]="\215\147\214\185",["daletholamhebrew"]="\215\147\214\185",
["daletpatah"]="\215\147\214\183",["daletpatahhebrew"]="\215\147\214\183",["daletqamats"]="\215\147\214\184",
["daletqamatshebrew"]="\215\147\214\184",["daletqubuts"]="\215\147\214\187",["daletqubutshebrew"]="\215\147\214\187",
["daletsegol"]="\215\147\214\182",["daletsegolhebrew"]="\215\147\214\182",["daletsheva"]="\215\147\214\176",
["daletshevahebrew"]="\215\147\214\176",["dalettsere"]="\215\147\214\181",["dalettserehebrew"]="\215\147\214\181",
["dalfinalarabic"]="\239\186\170",["dammaarabic"]="\217\143",["dammalowarabic"]="\217\143",["dammatanaltonearabic"]="\217\140",
["dammatanarabic"]="\217\140",["danda"]="\224\165\164",["dargahebrew"]="\214\167",["dargalefthebrew"]="\214\167",
["dasiapneumatacyrilliccmb"]="\210\133",["dblGrave"]="\239\155\147",["dblanglebracketleft"]="\227\128\138",
["dblanglebracketleftvertical"]="\239\184\189",["dblanglebracketright"]="\227\128\139",["dblanglebracketrightvertical"]="\239\184\190",
["dblarchinvertedbelowcmb"]="\204\171",["dblarrowleft"]="\226\135\148",["dblarrowright"]="\226\135\146",
["dbldanda"]="\224\165\165",["dblgrave"]="\239\155\150",["dblgravecmb"]="\204\143",["dblintegral"]="\226\136\172",
["dbllowline"]="\226\128\151",["dbllowlinecmb"]="\204\179",["dbloverlinecmb"]="\204\191",["dblprimemod"]="\202\186",
["dblverticalbar"]="\226\128\150",["dblverticallineabovecmb"]="\204\142",["dbopomofo"]="\227\132\137",
["dbsquare"]="\227\143\136",["dcaron"]="\196\143",["dcedilla"]="\225\184\145",["dcircle"]="\226\147\147",
["dcircumflexbelow"]="\225\184\147",["dcroat"]="\196\145",["ddabengali"]="\224\166\161",["ddadeva"]="\224\164\161",
["ddagujarati"]="\224\170\161",["ddagurmukhi"]="\224\168\161",["ddalarabic"]="\218\136",["ddalfinalarabic"]="\239\174\137",
["dddhadeva"]="\224\165\156",["ddhabengali"]="\224\166\162",["ddhadeva"]="\224\164\162",["ddhagujarati"]="\224\170\162",
["ddhagurmukhi"]="\224\168\162",["ddotaccent"]="\225\184\139",["ddotbelow"]="\225\184\141",["decimalseparatorarabic"]="\217\171",
["decimalseparatorpersian"]="\217\171",["decyrillic"]="\208\180",["degree"]="\194\176",["dehihebrew"]="\214\173",
["dehiragana"]="\227\129\167",["deicoptic"]="\207\175",["dekatakana"]="\227\131\135",["deleteleft"]="\226\140\171",
["deleteright"]="\226\140\166",["delta"]="\206\180",["deltaturned"]="\198\141",["denominatorminusonenumeratorbengali"]="\224\167\184",
["dezh"]="\202\164",["dhabengali"]="\224\166\167",["dhadeva"]="\224\164\167",["dhagujarati"]="\224\170\167",
["dhagurmukhi"]="\224\168\167",["dhook"]="\201\151",["dialytikatonos"]="\206\133",["dialytikatonoscmb"]="\205\132",
["diamond"]="\226\153\166",["diamondsuitwhite"]="\226\153\162",["dieresis"]="\194\168",["dieresisacute"]="\239\155\151",
["dieresisbelowcmb"]="\204\164",["dieresiscmb"]="\204\136",["dieresisgrave"]="\239\155\152",["dieresistonos"]="\206\133",
["dihiragana"]="\227\129\162",["dikatakana"]="\227\131\130",["dittomark"]="\227\128\131",["divide"]="\195\183",
["divides"]="\226\136\163",["divisionslash"]="\226\136\149",["djecyrillic"]="\209\146",["dkshade"]="\226\150\147",
["dlinebelow"]="\225\184\143",["dlsquare"]="\227\142\151",["dmacron"]="\196\145",["dmonospace"]="\239\189\132",
["dnblock"]="\226\150\132",["dochadathai"]="\224\184\142",["dodekthai"]="\224\184\148",["dohiragana"]="\227\129\169",
["dokatakana"]="\227\131\137",["dollar"]="$",["dollarinferior"]="\239\155\163",["dollarmonospace"]="\239\188\132",
["dollaroldstyle"]="\239\156\164",["dollarsmall"]="\239\185\169",["dollarsuperior"]="\239\155\164",["dong"]="\226\130\171",
["dorusquare"]="\227\140\166",["dotaccent"]="\203\153",["dotaccentcmb"]="\204\135",["dotbelowcmb"]="\204\163",
["dotbelowcomb"]="\204\163",["dotkatakana"]="\227\131\187",["dotlessi"]="\196\177",["dotlessj"]="\239\154\190",
["dotlessjstrokehook"]="\202\132",["dotmath"]="\226\139\133",["dottedcircle"]="\226\151\140",["doubleyodpatah"]="\239\172\159",
["doubleyodpatahhebrew"]="\239\172\159",["downtackbelowcmb"]="\204\158",["downtackmod"]="\203\149",["dparen"]="\226\146\159",
["dsuperior"]="\239\155\171",["dtail"]="\201\150",["dtopbar"]="\198\140",["duhiragana"]="\227\129\165",
["dukatakana"]="\227\131\133",["dz"]="\199\179",["dzaltone"]="\202\163",["dzcaron"]="\199\134",["dzcurl"]="\202\165",
["dzeabkhasiancyrillic"]="\211\161",["dzecyrillic"]="\209\149",["dzhecyrillic"]="\209\159",["e"]="e",
["eacute"]="\195\169",["earth"]="\226\153\129",["ebengali"]="\224\166\143",["ebopomofo"]="\227\132\156",
["ebreve"]="\196\149",["ecandradeva"]="\224\164\141",["ecandragujarati"]="\224\170\141",["ecandravowelsigndeva"]="\224\165\133",
["ecandravowelsigngujarati"]="\224\171\133",["ecaron"]="\196\155",["ecedillabreve"]="\225\184\157",["echarmenian"]="\213\165",
["echyiwnarmenian"]="\214\135",["ecircle"]="\226\147\148",["ecircumflex"]="\195\170",["ecircumflexacute"]="\225\186\191",
["ecircumflexbelow"]="\225\184\153",["ecircumflexdotbelow"]="\225\187\135",["ecircumflexgrave"]="\225\187\129",
["ecircumflexhookabove"]="\225\187\131",["ecircumflextilde"]="\225\187\133",["ecyrillic"]="\209\148",
["edblgrave"]="\200\133",["edeva"]="\224\164\143",["edieresis"]="\195\171",["edot"]="\196\151",["edotaccent"]="\196\151",
["edotbelow"]="\225\186\185",["eegurmukhi"]="\224\168\143",["eematragurmukhi"]="\224\169\135",["efcyrillic"]="\209\132",
["egrave"]="\195\168",["egujarati"]="\224\170\143",["eharmenian"]="\213\167",["ehbopomofo"]="\227\132\157",
["ehiragana"]="\227\129\136",["ehookabove"]="\225\186\187",["eibopomofo"]="\227\132\159",["eight"]="8",
["eightarabic"]="\217\168",["eightbengali"]="\224\167\174",["eightcircle"]="\226\145\167",["eightcircleinversesansserif"]="\226\158\145",
["eightdeva"]="\224\165\174",["eighteencircle"]="\226\145\177",["eighteenparen"]="\226\146\133",["eighteenperiod"]="\226\146\153",
["eightgujarati"]="\224\171\174",["eightgurmukhi"]="\224\169\174",["eighthackarabic"]="\217\168",["eighthangzhou"]="\227\128\168",
["eighthnotebeamed"]="\226\153\171",["eightideographicparen"]="\227\136\167",["eightinferior"]="\226\130\136",
["eightmonospace"]="\239\188\152",["eightoldstyle"]="\239\156\184",["eightparen"]="\226\145\187",["eightperiod"]="\226\146\143",
["eightpersian"]="\219\184",["eightroman"]="\226\133\183",["eightsuperior"]="\226\129\184",["eightthai"]="\224\185\152",
["einvertedbreve"]="\200\135",["eiotifiedcyrillic"]="\209\165",["ekatakana"]="\227\130\168",["ekatakanahalfwidth"]="\239\189\180",
["ekonkargurmukhi"]="\224\169\180",["ekorean"]="\227\133\148",["elcyrillic"]="\208\187",["element"]="\226\136\136",
["elevencircle"]="\226\145\170",["elevenparen"]="\226\145\190",["elevenperiod"]="\226\146\146",["elevenroman"]="\226\133\186",
["ellipsis"]="\226\128\166",["ellipsisvertical"]="\226\139\174",["emacron"]="\196\147",["emacronacute"]="\225\184\151",
["emacrongrave"]="\225\184\149",["emcyrillic"]="\208\188",["emdash"]="\226\128\148",["emdashvertical"]="\239\184\177",
["emonospace"]="\239\189\133",["emphasismarkarmenian"]="\213\155",["emptyset"]="\226\136\133",["enbopomofo"]="\227\132\163",
["encyrillic"]="\208\189",["endash"]="\226\128\147",["endashvertical"]="\239\184\178",["endescendercyrillic"]="\210\163",
["eng"]="\197\139",["engbopomofo"]="\227\132\165",["enghecyrillic"]="\210\165",["enhookcyrillic"]="\211\136",
["enspace"]="\226\128\130",["eogonek"]="\196\153",["eokorean"]="\227\133\147",["eopen"]="\201\155",["eopenclosed"]="\202\154",
["eopenreversed"]="\201\156",["eopenreversedclosed"]="\201\158",["eopenreversedhook"]="\201\157",["eparen"]="\226\146\160",
["epsilon"]="\206\181",["epsilontonos"]="\206\173",["equal"]="=",["equalmonospace"]="\239\188\157",["equalsmall"]="\239\185\166",
["equalsuperior"]="\226\129\188",["equivalence"]="\226\137\161",["erbopomofo"]="\227\132\166",["ercyrillic"]="\209\128",
["ereversed"]="\201\152",["ereversedcyrillic"]="\209\141",["escyrillic"]="\209\129",["esdescendercyrillic"]="\210\171",
["esh"]="\202\131",["eshcurl"]="\202\134",["eshortdeva"]="\224\164\142",["eshortvowelsigndeva"]="\224\165\134",
["eshreversedloop"]="\198\170",["eshsquatreversed"]="\202\133",["esmallhiragana"]="\227\129\135",["esmallkatakana"]="\227\130\167",
["esmallkatakanahalfwidth"]="\239\189\170",["estimated"]="\226\132\174",["esuperior"]="\239\155\172",
["eta"]="\206\183",["etarmenian"]="\213\168",["etatonos"]="\206\174",["eth"]="\195\176",["etilde"]="\225\186\189",
["etildebelow"]="\225\184\155",["etnahtafoukhhebrew"]="\214\145",["etnahtafoukhlefthebrew"]="\214\145",
["etnahtahebrew"]="\214\145",["etnahtalefthebrew"]="\214\145",["eturned"]="\199\157",["eukorean"]="\227\133\161",
["euro"]="\226\130\172",["evowelsignbengali"]="\224\167\135",["evowelsigndeva"]="\224\165\135",["evowelsigngujarati"]="\224\171\135",
["exclam"]="!",["exclamarmenian"]="\213\156",["exclamdbl"]="\226\128\188",["exclamdown"]="\194\161",["exclamdownsmall"]="\239\158\161",
["exclammonospace"]="\239\188\129",["exclamsmall"]="\239\156\161",["existential"]="\226\136\131",["ezh"]="\202\146",
["ezhcaron"]="\199\175",["ezhcurl"]="\202\147",["ezhreversed"]="\198\185",["ezhtail"]="\198\186",["f"]="f",
["fadeva"]="\224\165\158",["fagurmukhi"]="\224\169\158",["fahrenheit"]="\226\132\137",["fathaarabic"]="\217\142",
["fathalowarabic"]="\217\142",["fathatanarabic"]="\217\139",["fbopomofo"]="\227\132\136",["fcircle"]="\226\147\149",
["fdotaccent"]="\225\184\159",["feharabic"]="\217\129",["feharmenian"]="\214\134",["fehfinalarabic"]="\239\187\146",
["fehinitialarabic"]="\239\187\147",["fehmedialarabic"]="\239\187\148",["feicoptic"]="\207\165",["female"]="\226\153\128",
["ff"]="\239\172\128",["ffi"]="\239\172\131",["ffl"]="\239\172\132",["fi"]="\239\172\129",["fifteencircle"]="\226\145\174",
["fifteenparen"]="\226\146\130",["fifteenperiod"]="\226\146\150",["figuredash"]="\226\128\146",["filledbox"]="\226\150\160",
["filledrect"]="\226\150\172",["finalkaf"]="\215\154",["finalkafdagesh"]="\239\172\186",["finalkafdageshhebrew"]="\239\172\186",
["finalkafhebrew"]="\215\154",["finalkafqamats"]="\215\154\214\184",["finalkafqamatshebrew"]="\215\154\214\184",
["finalkafsheva"]="\215\154\214\176",["finalkafshevahebrew"]="\215\154\214\176",["finalmem"]="\215\157",
["finalmemhebrew"]="\215\157",["finalnun"]="\215\159",["finalnunhebrew"]="\215\159",["finalpe"]="\215\163",
["finalpehebrew"]="\215\163",["finaltsadi"]="\215\165",["finaltsadihebrew"]="\215\165",["firsttonechinese"]="\203\137",
["fisheye"]="\226\151\137",["fitacyrillic"]="\209\179",["five"]="5",["fivearabic"]="\217\165",["fivebengali"]="\224\167\171",
["fivecircle"]="\226\145\164",["fivecircleinversesansserif"]="\226\158\142",["fivedeva"]="\224\165\171",
["fiveeighths"]="\226\133\157",["fivegujarati"]="\224\171\171",["fivegurmukhi"]="\224\169\171",["fivehackarabic"]="\217\165",
["fivehangzhou"]="\227\128\165",["fiveideographicparen"]="\227\136\164",["fiveinferior"]="\226\130\133",
["fivemonospace"]="\239\188\149",["fiveoldstyle"]="\239\156\181",["fiveparen"]="\226\145\184",["fiveperiod"]="\226\146\140",
["fivepersian"]="\219\181",["fiveroman"]="\226\133\180",["fivesuperior"]="\226\129\181",["fivethai"]="\224\185\149",
["fl"]="\239\172\130",["florin"]="\198\146",["fmonospace"]="\239\189\134",["fmsquare"]="\227\142\153",
["fofanthai"]="\224\184\159",["fofathai"]="\224\184\157",["fongmanthai"]="\224\185\143",["forall"]="\226\136\128",
["four"]="4",["fourarabic"]="\217\164",["fourbengali"]="\224\167\170",["fourcircle"]="\226\145\163",["fourcircleinversesansserif"]="\226\158\141",
["fourdeva"]="\224\165\170",["fourgujarati"]="\224\171\170",["fourgurmukhi"]="\224\169\170",["fourhackarabic"]="\217\164",
["fourhangzhou"]="\227\128\164",["fourideographicparen"]="\227\136\163",["fourinferior"]="\226\130\132",
["fourmonospace"]="\239\188\148",["fournumeratorbengali"]="\224\167\183",["fouroldstyle"]="\239\156\180",
["fourparen"]="\226\145\183",["fourperiod"]="\226\146\139",["fourpersian"]="\219\180",["fourroman"]="\226\133\179",
["foursuperior"]="\226\129\180",["fourteencircle"]="\226\145\173",["fourteenparen"]="\226\146\129",["fourteenperiod"]="\226\146\149",
["fourthai"]="\224\185\148",["fourthtonechinese"]="\203\139",["fparen"]="\226\146\161",["fraction"]="\226\129\132",
["franc"]="\226\130\163",["g"]="g",["gabengali"]="\224\166\151",["gacute"]="\199\181",["gadeva"]="\224\164\151",
["gafarabic"]="\218\175",["gaffinalarabic"]="\239\174\147",["gafinitialarabic"]="\239\174\148",["gafmedialarabic"]="\239\174\149",
["gagujarati"]="\224\170\151",["gagurmukhi"]="\224\168\151",["gahiragana"]="\227\129\140",["gakatakana"]="\227\130\172",
["gamma"]="\206\179",["gammalatinsmall"]="\201\163",["gammasuperior"]="\203\160",["gangiacoptic"]="\207\171",
["gbopomofo"]="\227\132\141",["gbreve"]="\196\159",["gcaron"]="\199\167",["gcedilla"]="\196\163",["gcircle"]="\226\147\150",
["gcircumflex"]="\196\157",["gcommaaccent"]="\196\163",["gdot"]="\196\161",["gdotaccent"]="\196\161",
["gecyrillic"]="\208\179",["gehiragana"]="\227\129\146",["gekatakana"]="\227\130\178",["geometricallyequal"]="\226\137\145",
["gereshaccenthebrew"]="\214\156",["gereshhebrew"]="\215\179",["gereshmuqdamhebrew"]="\214\157",["germandbls"]="\195\159",
["gershayimaccenthebrew"]="\214\158",["gershayimhebrew"]="\215\180",["getamark"]="\227\128\147",["ghabengali"]="\224\166\152",
["ghadarmenian"]="\213\178",["ghadeva"]="\224\164\152",["ghagujarati"]="\224\170\152",["ghagurmukhi"]="\224\168\152",
["ghainarabic"]="\216\186",["ghainfinalarabic"]="\239\187\142",["ghaininitialarabic"]="\239\187\143",
["ghainmedialarabic"]="\239\187\144",["ghemiddlehookcyrillic"]="\210\149",["ghestrokecyrillic"]="\210\147",
["gheupturncyrillic"]="\210\145",["ghhadeva"]="\224\165\154",["ghhagurmukhi"]="\224\169\154",["ghook"]="\201\160",
["ghzsquare"]="\227\142\147",["gihiragana"]="\227\129\142",["gikatakana"]="\227\130\174",["gimarmenian"]="\213\163",
["gimel"]="\215\146",["gimeldagesh"]="\239\172\178",["gimeldageshhebrew"]="\239\172\178",["gimelhebrew"]="\215\146",
["gjecyrillic"]="\209\147",["glottalinvertedstroke"]="\198\190",["glottalstop"]="\202\148",["glottalstopinverted"]="\202\150",
["glottalstopmod"]="\203\128",["glottalstopreversed"]="\202\149",["glottalstopreversedmod"]="\203\129",
["glottalstopreversedsuperior"]="\203\164",["glottalstopstroke"]="\202\161",["glottalstopstrokereversed"]="\202\162",
["gmacron"]="\225\184\161",["gmonospace"]="\239\189\135",["gohiragana"]="\227\129\148",["gokatakana"]="\227\130\180",
["gparen"]="\226\146\162",["gpasquare"]="\227\142\172",["gradient"]="\226\136\135",["grave"]="`",["gravebelowcmb"]="\204\150",
["gravecmb"]="\204\128",["gravecomb"]="\204\128",["gravedeva"]="\224\165\147",["gravelowmod"]="\203\142",
["gravemonospace"]="\239\189\128",["gravetonecmb"]="\205\128",["greater"]=">",["greaterequal"]="\226\137\165",
["greaterequalorless"]="\226\139\155",["greatermonospace"]="\239\188\158",["greaterorequivalent"]="\226\137\179",
["greaterorless"]="\226\137\183",["greateroverequal"]="\226\137\167",["greatersmall"]="\239\185\165",
["gscript"]="\201\161",["gstroke"]="\199\165",["guhiragana"]="\227\129\144",["guillemotleft"]="\194\171",
["guillemotright"]="\194\187",["guilsinglleft"]="\226\128\185",["guilsinglright"]="\226\128\186",["gukatakana"]="\227\130\176",
["guramusquare"]="\227\140\152",["gysquare"]="\227\143\137",["h"]="h",["haabkhasiancyrillic"]="\210\169",
["haaltonearabic"]="\219\129",["habengali"]="\224\166\185",["hadescendercyrillic"]="\210\179",["hadeva"]="\224\164\185",
["hagujarati"]="\224\170\185",["hagurmukhi"]="\224\168\185",["haharabic"]="\216\173",["hahfinalarabic"]="\239\186\162",
["hahinitialarabic"]="\239\186\163",["hahiragana"]="\227\129\175",["hahmedialarabic"]="\239\186\164",
["haitusquare"]="\227\140\170",["hakatakana"]="\227\131\143",["hakatakanahalfwidth"]="\239\190\138",["halantgurmukhi"]="\224\169\141",
["hamzaarabic"]="\216\161",["hamzadammaarabic"]="\216\161\217\143",["hamzadammatanarabic"]="\216\161\217\140",
["hamzafathaarabic"]="\216\161\217\142",["hamzafathatanarabic"]="\216\161\217\139",["hamzalowarabic"]="\216\161",
["hamzalowkasraarabic"]="\216\161\217\144",["hamzalowkasratanarabic"]="\216\161\217\141",["hamzasukunarabic"]="\216\161\217\146",
["hangulfiller"]="\227\133\164",["hardsigncyrillic"]="\209\138",["harpoonleftbarbup"]="\226\134\188",
["harpoonrightbarbup"]="\226\135\128",["hasquare"]="\227\143\138",["hatafpatah"]="\214\178",["hatafpatah16"]="\214\178",
["hatafpatah23"]="\214\178",["hatafpatah2f"]="\214\178",["hatafpatahhebrew"]="\214\178",["hatafpatahnarrowhebrew"]="\214\178",
["hatafpatahquarterhebrew"]="\214\178",["hatafpatahwidehebrew"]="\214\178",["hatafqamats"]="\214\179",
["hatafqamats1b"]="\214\179",["hatafqamats28"]="\214\179",["hatafqamats34"]="\214\179",["hatafqamatshebrew"]="\214\179",
["hatafqamatsnarrowhebrew"]="\214\179",["hatafqamatsquarterhebrew"]="\214\179",["hatafqamatswidehebrew"]="\214\179",
["hatafsegol"]="\214\177",["hatafsegol17"]="\214\177",["hatafsegol24"]="\214\177",["hatafsegol30"]="\214\177",
["hatafsegolhebrew"]="\214\177",["hatafsegolnarrowhebrew"]="\214\177",["hatafsegolquarterhebrew"]="\214\177",
["hatafsegolwidehebrew"]="\214\177",["hbar"]="\196\167",["hbopomofo"]="\227\132\143",["hbrevebelow"]="\225\184\171",
["hcedilla"]="\225\184\169",["hcircle"]="\226\147\151",["hcircumflex"]="\196\165",["hdieresis"]="\225\184\167",
["hdotaccent"]="\225\184\163",["hdotbelow"]="\225\184\165",["he"]="\215\148",["heart"]="\226\153\165",
["heartsuitblack"]="\226\153\165",["heartsuitwhite"]="\226\153\161",["hedagesh"]="\239\172\180",["hedageshhebrew"]="\239\172\180",
["hehaltonearabic"]="\219\129",["heharabic"]="\217\135",["hehebrew"]="\215\148",["hehfinalaltonearabic"]="\239\174\167",
["hehfinalalttwoarabic"]="\239\187\170",["hehfinalarabic"]="\239\187\170",["hehhamzaabovefinalarabic"]="\239\174\165",
["hehhamzaaboveisolatedarabic"]="\239\174\164",["hehinitialaltonearabic"]="\239\174\168",["hehinitialarabic"]="\239\187\171",
["hehiragana"]="\227\129\184",["hehmedialaltonearabic"]="\239\174\169",["hehmedialarabic"]="\239\187\172",
["heiseierasquare"]="\227\141\187",["hekatakana"]="\227\131\152",["hekatakanahalfwidth"]="\239\190\141",
["hekutaarusquare"]="\227\140\182",["henghook"]="\201\167",["herutusquare"]="\227\140\185",["het"]="\215\151",
["hethebrew"]="\215\151",["hhook"]="\201\166",["hhooksuperior"]="\202\177",["hieuhacirclekorean"]="\227\137\187",
["hieuhaparenkorean"]="\227\136\155",["hieuhcirclekorean"]="\227\137\173",["hieuhkorean"]="\227\133\142",
["hieuhparenkorean"]="\227\136\141",["hihiragana"]="\227\129\178",["hikatakana"]="\227\131\146",["hikatakanahalfwidth"]="\239\190\139",
["hiriq"]="\214\180",["hiriq14"]="\214\180",["hiriq21"]="\214\180",["hiriq2d"]="\214\180",["hiriqhebrew"]="\214\180",
["hiriqnarrowhebrew"]="\214\180",["hiriqquarterhebrew"]="\214\180",["hiriqwidehebrew"]="\214\180",["hlinebelow"]="\225\186\150",
["hmonospace"]="\239\189\136",["hoarmenian"]="\213\176",["hohipthai"]="\224\184\171",["hohiragana"]="\227\129\187",
["hokatakana"]="\227\131\155",["hokatakanahalfwidth"]="\239\190\142",["holam"]="\214\185",["holam19"]="\214\185",
["holam26"]="\214\185",["holam32"]="\214\185",["holamhebrew"]="\214\185",["holamnarrowhebrew"]="\214\185",
["holamquarterhebrew"]="\214\185",["holamwidehebrew"]="\214\185",["honokhukthai"]="\224\184\174",["hookabovecomb"]="\204\137",
["hookcmb"]="\204\137",["hookpalatalizedbelowcmb"]="\204\161",["hookretroflexbelowcmb"]="\204\162",["hoonsquare"]="\227\141\130",
["horicoptic"]="\207\169",["horizontalbar"]="\226\128\149",["horncmb"]="\204\155",["hotsprings"]="\226\153\168",
["house"]="\226\140\130",["hparen"]="\226\146\163",["hsuperior"]="\202\176",["hturned"]="\201\165",["huhiragana"]="\227\129\181",
["huiitosquare"]="\227\140\179",["hukatakana"]="\227\131\149",["hukatakanahalfwidth"]="\239\190\140",
["hungarumlaut"]="\203\157",["hungarumlautcmb"]="\204\139",["hv"]="\198\149",["hyphen"]="-",["hypheninferior"]="\239\155\165",
["hyphenmonospace"]="\239\188\141",["hyphensmall"]="\239\185\163",["hyphensuperior"]="\239\155\166",["hyphentwo"]="\226\128\144",
["i"]="i",["iacute"]="\195\173",["iacyrillic"]="\209\143",["ibengali"]="\224\166\135",["ibopomofo"]="\227\132\167",
["ibreve"]="\196\173",["icaron"]="\199\144",["icircle"]="\226\147\152",["icircumflex"]="\195\174",["icyrillic"]="\209\150",
["idblgrave"]="\200\137",["ideographearthcircle"]="\227\138\143",["ideographfirecircle"]="\227\138\139",
["ideographicallianceparen"]="\227\136\191",["ideographiccallparen"]="\227\136\186",["ideographiccentrecircle"]="\227\138\165",
["ideographicclose"]="\227\128\134",["ideographiccomma"]="\227\128\129",["ideographiccommaleft"]="\239\189\164",
["ideographiccongratulationparen"]="\227\136\183",["ideographiccorrectcircle"]="\227\138\163",["ideographicearthparen"]="\227\136\175",
["ideographicenterpriseparen"]="\227\136\189",["ideographicexcellentcircle"]="\227\138\157",["ideographicfestivalparen"]="\227\137\128",
["ideographicfinancialcircle"]="\227\138\150",["ideographicfinancialparen"]="\227\136\182",["ideographicfireparen"]="\227\136\171",
["ideographichaveparen"]="\227\136\178",["ideographichighcircle"]="\227\138\164",["ideographiciterationmark"]="\227\128\133",
["ideographiclaborcircle"]="\227\138\152",["ideographiclaborparen"]="\227\136\184",["ideographicleftcircle"]="\227\138\167",
["ideographiclowcircle"]="\227\138\166",["ideographicmedicinecircle"]="\227\138\169",["ideographicmetalparen"]="\227\136\174",
["ideographicmoonparen"]="\227\136\170",["ideographicnameparen"]="\227\136\180",["ideographicperiod"]="\227\128\130",
["ideographicprintcircle"]="\227\138\158",["ideographicreachparen"]="\227\137\131",["ideographicrepresentparen"]="\227\136\185",
["ideographicresourceparen"]="\227\136\190",["ideographicrightcircle"]="\227\138\168",["ideographicsecretcircle"]="\227\138\153",
["ideographicselfparen"]="\227\137\130",["ideographicsocietyparen"]="\227\136\179",["ideographicspace"]="\227\128\128",
["ideographicspecialparen"]="\227\136\181",["ideographicstockparen"]="\227\136\177",["ideographicstudyparen"]="\227\136\187",
["ideographicsunparen"]="\227\136\176",["ideographicsuperviseparen"]="\227\136\188",["ideographicwaterparen"]="\227\136\172",
["ideographicwoodparen"]="\227\136\173",["ideographiczero"]="\227\128\135",["ideographmetalcircle"]="\227\138\142",
["ideographmooncircle"]="\227\138\138",["ideographnamecircle"]="\227\138\148",["ideographsuncircle"]="\227\138\144",
["ideographwatercircle"]="\227\138\140",["ideographwoodcircle"]="\227\138\141",["ideva"]="\224\164\135",
["idieresis"]="\195\175",["idieresisacute"]="\225\184\175",["idieresiscyrillic"]="\211\165",["idotbelow"]="\225\187\139",
["iebrevecyrillic"]="\211\151",["iecyrillic"]="\208\181",["ieungacirclekorean"]="\227\137\181",["ieungaparenkorean"]="\227\136\149",
["ieungcirclekorean"]="\227\137\167",["ieungkorean"]="\227\133\135",["ieungparenkorean"]="\227\136\135",
["igrave"]="\195\172",["igujarati"]="\224\170\135",["igurmukhi"]="\224\168\135",["ihiragana"]="\227\129\132",
["ihookabove"]="\225\187\137",["iibengali"]="\224\166\136",["iicyrillic"]="\208\184",["iideva"]="\224\164\136",
["iigujarati"]="\224\170\136",["iigurmukhi"]="\224\168\136",["iimatragurmukhi"]="\224\169\128",["iinvertedbreve"]="\200\139",
["iishortcyrillic"]="\208\185",["iivowelsignbengali"]="\224\167\128",["iivowelsigndeva"]="\224\165\128",
["iivowelsigngujarati"]="\224\171\128",["ij"]="\196\179",["ikatakana"]="\227\130\164",["ikatakanahalfwidth"]="\239\189\178",
["ikorean"]="\227\133\163",["ilde"]="\203\156",["iluyhebrew"]="\214\172",["imacron"]="\196\171",["imacroncyrillic"]="\211\163",
["imageorapproximatelyequal"]="\226\137\147",["imatragurmukhi"]="\224\168\191",["imonospace"]="\239\189\137",
["increment"]="\226\136\134",["infinity"]="\226\136\158",["iniarmenian"]="\213\171",["integral"]="\226\136\171",
["integralbottom"]="\226\140\161",["integralbt"]="\226\140\161",["integralex"]="\239\163\181",["integraltop"]="\226\140\160",
["integraltp"]="\226\140\160",["intersection"]="\226\136\169",["intisquare"]="\227\140\133",["invbullet"]="\226\151\152",
["invcircle"]="\226\151\153",["invsmileface"]="\226\152\187",["iocyrillic"]="\209\145",["iogonek"]="\196\175",
["iota"]="\206\185",["iotadieresis"]="\207\138",["iotadieresistonos"]="\206\144",["iotalatin"]="\201\169",
["iotatonos"]="\206\175",["iparen"]="\226\146\164",["irigurmukhi"]="\224\169\178",["ismallhiragana"]="\227\129\131",
["ismallkatakana"]="\227\130\163",["ismallkatakanahalfwidth"]="\239\189\168",["issharbengali"]="\224\167\186",
["istroke"]="\201\168",["isuperior"]="\239\155\173",["iterationhiragana"]="\227\130\157",["iterationkatakana"]="\227\131\189",
["itilde"]="\196\169",["itildebelow"]="\225\184\173",["iubopomofo"]="\227\132\169",["iucyrillic"]="\209\142",
["ivowelsignbengali"]="\224\166\191",["ivowelsigndeva"]="\224\164\191",["ivowelsigngujarati"]="\224\170\191",
["izhitsacyrillic"]="\209\181",["izhitsadblgravecyrillic"]="\209\183",["j"]="j",["jaarmenian"]="\213\177",
["jabengali"]="\224\166\156",["jadeva"]="\224\164\156",["jagujarati"]="\224\170\156",["jagurmukhi"]="\224\168\156",
["jbopomofo"]="\227\132\144",["jcaron"]="\199\176",["jcircle"]="\226\147\153",["jcircumflex"]="\196\181",
["jcrossedtail"]="\202\157",["jdotlessstroke"]="\201\159",["jecyrillic"]="\209\152",["jeemarabic"]="\216\172",
["jeemfinalarabic"]="\239\186\158",["jeeminitialarabic"]="\239\186\159",["jeemmedialarabic"]="\239\186\160",
["jeharabic"]="\218\152",["jehfinalarabic"]="\239\174\139",["jhabengali"]="\224\166\157",["jhadeva"]="\224\164\157",
["jhagujarati"]="\224\170\157",["jhagurmukhi"]="\224\168\157",["jheharmenian"]="\213\187",["jis"]="\227\128\132",
["jmonospace"]="\239\189\138",["jparen"]="\226\146\165",["jsuperior"]="\202\178",["k"]="k",["kabashkircyrillic"]="\210\161",
["kabengali"]="\224\166\149",["kacute"]="\225\184\177",["kacyrillic"]="\208\186",["kadescendercyrillic"]="\210\155",
["kadeva"]="\224\164\149",["kaf"]="\215\155",["kafarabic"]="\217\131",["kafdagesh"]="\239\172\187",["kafdageshhebrew"]="\239\172\187",
["kaffinalarabic"]="\239\187\154",["kafhebrew"]="\215\155",["kafinitialarabic"]="\239\187\155",["kafmedialarabic"]="\239\187\156",
["kafrafehebrew"]="\239\173\141",["kagujarati"]="\224\170\149",["kagurmukhi"]="\224\168\149",["kahiragana"]="\227\129\139",
["kahookcyrillic"]="\211\132",["kakatakana"]="\227\130\171",["kakatakanahalfwidth"]="\239\189\182",["kappa"]="\206\186",
["kappasymbolgreek"]="\207\176",["kapyeounmieumkorean"]="\227\133\177",["kapyeounphieuphkorean"]="\227\134\132",
["kapyeounpieupkorean"]="\227\133\184",["kapyeounssangpieupkorean"]="\227\133\185",["karoriisquare"]="\227\140\141",
["kashidaautoarabic"]="\217\128",["kashidaautonosidebearingarabic"]="\217\128",["kasmallkatakana"]="\227\131\181",
["kasquare"]="\227\142\132",["kasraarabic"]="\217\144",["kasratanarabic"]="\217\141",["kastrokecyrillic"]="\210\159",
["katahiraprolongmarkhalfwidth"]="\239\189\176",["kaverticalstrokecyrillic"]="\210\157",["kbopomofo"]="\227\132\142",
["kcalsquare"]="\227\142\137",["kcaron"]="\199\169",["kcedilla"]="\196\183",["kcircle"]="\226\147\154",
["kcommaaccent"]="\196\183",["kdotbelow"]="\225\184\179",["keharmenian"]="\214\132",["kehiragana"]="\227\129\145",
["kekatakana"]="\227\130\177",["kekatakanahalfwidth"]="\239\189\185",["kenarmenian"]="\213\175",["kesmallkatakana"]="\227\131\182",
["kgreenlandic"]="\196\184",["khabengali"]="\224\166\150",["khacyrillic"]="\209\133",["khadeva"]="\224\164\150",
["khagujarati"]="\224\170\150",["khagurmukhi"]="\224\168\150",["khaharabic"]="\216\174",["khahfinalarabic"]="\239\186\166",
["khahinitialarabic"]="\239\186\167",["khahmedialarabic"]="\239\186\168",["kheicoptic"]="\207\167",["khhadeva"]="\224\165\153",
["khhagurmukhi"]="\224\169\153",["khieukhacirclekorean"]="\227\137\184",["khieukhaparenkorean"]="\227\136\152",
["khieukhcirclekorean"]="\227\137\170",["khieukhkorean"]="\227\133\139",["khieukhparenkorean"]="\227\136\138",
["khokhaithai"]="\224\184\130",["khokhonthai"]="\224\184\133",["khokhuatthai"]="\224\184\131",["khokhwaithai"]="\224\184\132",
["khomutthai"]="\224\185\155",["khook"]="\198\153",["khorakhangthai"]="\224\184\134",["khzsquare"]="\227\142\145",
["kihiragana"]="\227\129\141",["kikatakana"]="\227\130\173",["kikatakanahalfwidth"]="\239\189\183",["kiroguramusquare"]="\227\140\149",
["kiromeetorusquare"]="\227\140\150",["kirosquare"]="\227\140\148",["kiyeokacirclekorean"]="\227\137\174",
["kiyeokaparenkorean"]="\227\136\142",["kiyeokcirclekorean"]="\227\137\160",["kiyeokkorean"]="\227\132\177",
["kiyeokparenkorean"]="\227\136\128",["kiyeoksioskorean"]="\227\132\179",["kjecyrillic"]="\209\156",["klinebelow"]="\225\184\181",
["klsquare"]="\227\142\152",["kmcubedsquare"]="\227\142\166",["kmonospace"]="\239\189\139",["kmsquaredsquare"]="\227\142\162",
["kohiragana"]="\227\129\147",["kohmsquare"]="\227\143\128",["kokaithai"]="\224\184\129",["kokatakana"]="\227\130\179",
["kokatakanahalfwidth"]="\239\189\186",["kooposquare"]="\227\140\158",["koppacyrillic"]="\210\129",["koreanstandardsymbol"]="\227\137\191",
["koroniscmb"]="\205\131",["kparen"]="\226\146\166",["kpasquare"]="\227\142\170",["ksicyrillic"]="\209\175",
["ktsquare"]="\227\143\143",["kturned"]="\202\158",["kuhiragana"]="\227\129\143",["kukatakana"]="\227\130\175",
["kukatakanahalfwidth"]="\239\189\184",["kvsquare"]="\227\142\184",["kwsquare"]="\227\142\190",["l"]="l",
["labengali"]="\224\166\178",["lacute"]="\196\186",["ladeva"]="\224\164\178",["lagujarati"]="\224\170\178",
["lagurmukhi"]="\224\168\178",["lakkhangyaothai"]="\224\185\133",["lamaleffinalarabic"]="\239\187\188",
["lamalefhamzaabovefinalarabic"]="\239\187\184",["lamalefhamzaaboveisolatedarabic"]="\239\187\183",["lamalefhamzabelowfinalarabic"]="\239\187\186",
["lamalefhamzabelowisolatedarabic"]="\239\187\185",["lamalefisolatedarabic"]="\239\187\187",["lamalefmaddaabovefinalarabic"]="\239\187\182",
["lamalefmaddaaboveisolatedarabic"]="\239\187\181",["lamarabic"]="\217\132",["lambda"]="\206\187",["lambdastroke"]="\198\155",
["lamed"]="\215\156",["lameddagesh"]="\239\172\188",["lameddageshhebrew"]="\239\172\188",["lamedhebrew"]="\215\156",
["lamedholam"]="\215\156\214\185",["lamedholamdagesh"]="\215\156\214\185\214\188",["lamedholamdageshhebrew"]="\215\156\214\185\214\188",
["lamedholamhebrew"]="\215\156\214\185",["lamfinalarabic"]="\239\187\158",["lamhahinitialarabic"]="\239\179\138",
["laminitialarabic"]="\239\187\159",["lamjeeminitialarabic"]="\239\179\137",["lamkhahinitialarabic"]="\239\179\139",
["lamlamhehisolatedarabic"]="\239\183\178",["lammedialarabic"]="\239\187\160",["lammeemhahinitialarabic"]="\239\182\136",
["lammeeminitialarabic"]="\239\179\140",["lammeemjeeminitialarabic"]="\239\187\159\239\187\164\239\186\160",
["lammeemkhahinitialarabic"]="\239\187\159\239\187\164\239\186\168",["largecircle"]="\226\151\175",["lbar"]="\198\154",
["lbelt"]="\201\172",["lbopomofo"]="\227\132\140",["lcaron"]="\196\190",["lcedilla"]="\196\188",["lcircle"]="\226\147\155",
["lcircumflexbelow"]="\225\184\189",["lcommaaccent"]="\196\188",["ldot"]="\197\128",["ldotaccent"]="\197\128",
["ldotbelow"]="\225\184\183",["ldotbelowmacron"]="\225\184\185",["leftangleabovecmb"]="\204\154",["lefttackbelowcmb"]="\204\152",
["less"]="<",["lessequal"]="\226\137\164",["lessequalorgreater"]="\226\139\154",["lessmonospace"]="\239\188\156",
["lessorequivalent"]="\226\137\178",["lessorgreater"]="\226\137\182",["lessoverequal"]="\226\137\166",
["lesssmall"]="\239\185\164",["lezh"]="\201\174",["lfblock"]="\226\150\140",["lhookretroflex"]="\201\173",
["lira"]="\226\130\164",["liwnarmenian"]="\213\172",["lj"]="\199\137",["ljecyrillic"]="\209\153",["ll"]="\239\155\128",
["lladeva"]="\224\164\179",["llagujarati"]="\224\170\179",["llinebelow"]="\225\184\187",["llladeva"]="\224\164\180",
["llvocalicbengali"]="\224\167\161",["llvocalicdeva"]="\224\165\161",["llvocalicvowelsignbengali"]="\224\167\163",
["llvocalicvowelsigndeva"]="\224\165\163",["lmiddletilde"]="\201\171",["lmonospace"]="\239\189\140",["lmsquare"]="\227\143\144",
["lochulathai"]="\224\184\172",["logicaland"]="\226\136\167",["logicalnot"]="\194\172",["logicalnotreversed"]="\226\140\144",
["logicalor"]="\226\136\168",["lolingthai"]="\224\184\165",["longs"]="\197\191",["lowlinecenterline"]="\239\185\142",
["lowlinecmb"]="\204\178",["lowlinedashed"]="\239\185\141",["lozenge"]="\226\151\138",["lparen"]="\226\146\167",
["lslash"]="\197\130",["lsquare"]="\226\132\147",["lsuperior"]="\239\155\174",["ltshade"]="\226\150\145",
["luthai"]="\224\184\166",["lvocalicbengali"]="\224\166\140",["lvocalicdeva"]="\224\164\140",["lvocalicvowelsignbengali"]="\224\167\162",
["lvocalicvowelsigndeva"]="\224\165\162",["lxsquare"]="\227\143\147",["m"]="m",["mabengali"]="\224\166\174",
["macron"]="\194\175",["macronbelowcmb"]="\204\177",["macroncmb"]="\204\132",["macronlowmod"]="\203\141",
["macronmonospace"]="\239\191\163",["macute"]="\225\184\191",["madeva"]="\224\164\174",["magujarati"]="\224\170\174",
["magurmukhi"]="\224\168\174",["mahapakhhebrew"]="\214\164",["mahapakhlefthebrew"]="\214\164",["mahiragana"]="\227\129\190",
["maichattawalowleftthai"]="\239\162\149",["maichattawalowrightthai"]="\239\162\148",["maichattawathai"]="\224\185\139",
["maichattawaupperleftthai"]="\239\162\147",["maieklowleftthai"]="\239\162\140",["maieklowrightthai"]="\239\162\139",
["maiekthai"]="\224\185\136",["maiekupperleftthai"]="\239\162\138",["maihanakatleftthai"]="\239\162\132",
["maihanakatthai"]="\224\184\177",["maitaikhuleftthai"]="\239\162\137",["maitaikhuthai"]="\224\185\135",
["maitholowleftthai"]="\239\162\143",["maitholowrightthai"]="\239\162\142",["maithothai"]="\224\185\137",
["maithoupperleftthai"]="\239\162\141",["maitrilowleftthai"]="\239\162\146",["maitrilowrightthai"]="\239\162\145",
["maitrithai"]="\224\185\138",["maitriupperleftthai"]="\239\162\144",["maiyamokthai"]="\224\185\134",
["makatakana"]="\227\131\158",["makatakanahalfwidth"]="\239\190\143",["male"]="\226\153\130",["mansyonsquare"]="\227\141\135",
["maqafhebrew"]="\214\190",["mars"]="\226\153\130",["masoracirclehebrew"]="\214\175",["masquare"]="\227\142\131",
["mbopomofo"]="\227\132\135",["mbsquare"]="\227\143\148",["mcircle"]="\226\147\156",["mcubedsquare"]="\227\142\165",
["mdotaccent"]="\225\185\129",["mdotbelow"]="\225\185\131",["meemarabic"]="\217\133",["meemfinalarabic"]="\239\187\162",
["meeminitialarabic"]="\239\187\163",["meemmedialarabic"]="\239\187\164",["meemmeeminitialarabic"]="\239\179\145",
["meemmeemisolatedarabic"]="\239\177\136",["meetorusquare"]="\227\141\141",["mehiragana"]="\227\130\129",
["meizierasquare"]="\227\141\190",["mekatakana"]="\227\131\161",["mekatakanahalfwidth"]="\239\190\146",
["mem"]="\215\158",["memdagesh"]="\239\172\190",["memdageshhebrew"]="\239\172\190",["memhebrew"]="\215\158",
["menarmenian"]="\213\180",["merkhahebrew"]="\214\165",["merkhakefulahebrew"]="\214\166",["merkhakefulalefthebrew"]="\214\166",
["merkhalefthebrew"]="\214\165",["mhook"]="\201\177",["mhzsquare"]="\227\142\146",["middledotkatakanahalfwidth"]="\239\189\165",
["middot"]="\194\183",["mieumacirclekorean"]="\227\137\178",["mieumaparenkorean"]="\227\136\146",["mieumcirclekorean"]="\227\137\164",
["mieumkorean"]="\227\133\129",["mieumpansioskorean"]="\227\133\176",["mieumparenkorean"]="\227\136\132",
["mieumpieupkorean"]="\227\133\174",["mieumsioskorean"]="\227\133\175",["mihiragana"]="\227\129\191",
["mikatakana"]="\227\131\159",["mikatakanahalfwidth"]="\239\190\144",["minus"]="\226\136\146",["minusbelowcmb"]="\204\160",
["minuscircle"]="\226\138\150",["minusmod"]="\203\151",["minusplus"]="\226\136\147",["minute"]="\226\128\178",
["miribaarusquare"]="\227\141\138",["mirisquare"]="\227\141\137",["mlonglegturned"]="\201\176",["mlsquare"]="\227\142\150",
["mmcubedsquare"]="\227\142\163",["mmonospace"]="\239\189\141",["mmsquaredsquare"]="\227\142\159",["mohiragana"]="\227\130\130",
["mohmsquare"]="\227\143\129",["mokatakana"]="\227\131\162",["mokatakanahalfwidth"]="\239\190\147",["molsquare"]="\227\143\150",
["momathai"]="\224\184\161",["moverssquare"]="\227\142\167",["moverssquaredsquare"]="\227\142\168",["mparen"]="\226\146\168",
["mpasquare"]="\227\142\171",["mssquare"]="\227\142\179",["msuperior"]="\239\155\175",["mturned"]="\201\175",
["mu"]="\194\181",["mu1"]="\194\181",["muasquare"]="\227\142\130",["muchgreater"]="\226\137\171",["muchless"]="\226\137\170",
["mufsquare"]="\227\142\140",["mugreek"]="\206\188",["mugsquare"]="\227\142\141",["muhiragana"]="\227\130\128",
["mukatakana"]="\227\131\160",["mukatakanahalfwidth"]="\239\190\145",["mulsquare"]="\227\142\149",["multiply"]="\195\151",
["mumsquare"]="\227\142\155",["munahhebrew"]="\214\163",["munahlefthebrew"]="\214\163",["musicalnote"]="\226\153\170",
["musicalnotedbl"]="\226\153\171",["musicflatsign"]="\226\153\173",["musicsharpsign"]="\226\153\175",
["mussquare"]="\227\142\178",["muvsquare"]="\227\142\182",["muwsquare"]="\227\142\188",["mvmegasquare"]="\227\142\185",
["mvsquare"]="\227\142\183",["mwmegasquare"]="\227\142\191",["mwsquare"]="\227\142\189",["n"]="n",["nabengali"]="\224\166\168",
["nabla"]="\226\136\135",["nacute"]="\197\132",["nadeva"]="\224\164\168",["nagujarati"]="\224\170\168",
["nagurmukhi"]="\224\168\168",["nahiragana"]="\227\129\170",["nakatakana"]="\227\131\138",["nakatakanahalfwidth"]="\239\190\133",
["napostrophe"]="\197\137",["nasquare"]="\227\142\129",["nbopomofo"]="\227\132\139",["nbspace"]="\194\160",
["ncaron"]="\197\136",["ncedilla"]="\197\134",["ncircle"]="\226\147\157",["ncircumflexbelow"]="\225\185\139",
["ncommaaccent"]="\197\134",["ndotaccent"]="\225\185\133",["ndotbelow"]="\225\185\135",["nehiragana"]="\227\129\173",
["nekatakana"]="\227\131\141",["nekatakanahalfwidth"]="\239\190\136",["newsheqelsign"]="\226\130\170",
["nfsquare"]="\227\142\139",["ngabengali"]="\224\166\153",["ngadeva"]="\224\164\153",["ngagujarati"]="\224\170\153",
["ngagurmukhi"]="\224\168\153",["ngonguthai"]="\224\184\135",["nhiragana"]="\227\130\147",["nhookleft"]="\201\178",
["nhookretroflex"]="\201\179",["nieunacirclekorean"]="\227\137\175",["nieunaparenkorean"]="\227\136\143",
["nieuncieuckorean"]="\227\132\181",["nieuncirclekorean"]="\227\137\161",["nieunhieuhkorean"]="\227\132\182",
["nieunkorean"]="\227\132\180",["nieunpansioskorean"]="\227\133\168",["nieunparenkorean"]="\227\136\129",
["nieunsioskorean"]="\227\133\167",["nieuntikeutkorean"]="\227\133\166",["nihiragana"]="\227\129\171",
["nikatakana"]="\227\131\139",["nikatakanahalfwidth"]="\239\190\134",["nikhahitleftthai"]="\239\162\153",
["nikhahitthai"]="\224\185\141",["nine"]="9",["ninearabic"]="\217\169",["ninebengali"]="\224\167\175",
["ninecircle"]="\226\145\168",["ninecircleinversesansserif"]="\226\158\146",["ninedeva"]="\224\165\175",
["ninegujarati"]="\224\171\175",["ninegurmukhi"]="\224\169\175",["ninehackarabic"]="\217\169",["ninehangzhou"]="\227\128\169",
["nineideographicparen"]="\227\136\168",["nineinferior"]="\226\130\137",["ninemonospace"]="\239\188\153",
["nineoldstyle"]="\239\156\185",["nineparen"]="\226\145\188",["nineperiod"]="\226\146\144",["ninepersian"]="\219\185",
["nineroman"]="\226\133\184",["ninesuperior"]="\226\129\185",["nineteencircle"]="\226\145\178",["nineteenparen"]="\226\146\134",
["nineteenperiod"]="\226\146\154",["ninethai"]="\224\185\153",["nj"]="\199\140",["njecyrillic"]="\209\154",
["nkatakana"]="\227\131\179",["nkatakanahalfwidth"]="\239\190\157",["nlegrightlong"]="\198\158",["nlinebelow"]="\225\185\137",
["nmonospace"]="\239\189\142",["nmsquare"]="\227\142\154",["nnabengali"]="\224\166\163",["nnadeva"]="\224\164\163",
["nnagujarati"]="\224\170\163",["nnagurmukhi"]="\224\168\163",["nnnadeva"]="\224\164\169",["nohiragana"]="\227\129\174",
["nokatakana"]="\227\131\142",["nokatakanahalfwidth"]="\239\190\137",["nonbreakingspace"]="\194\160",
["nonenthai"]="\224\184\147",["nonuthai"]="\224\184\153",["noonarabic"]="\217\134",["noonfinalarabic"]="\239\187\166",
["noonghunnaarabic"]="\218\186",["noonghunnafinalarabic"]="\239\174\159",["noonhehinitialarabic"]="\239\187\167\239\187\172",
["nooninitialarabic"]="\239\187\167",["noonjeeminitialarabic"]="\239\179\146",["noonjeemisolatedarabic"]="\239\177\139",
["noonmedialarabic"]="\239\187\168",["noonmeeminitialarabic"]="\239\179\149",["noonmeemisolatedarabic"]="\239\177\142",
["noonnoonfinalarabic"]="\239\178\141",["notcontains"]="\226\136\140",["notelement"]="\226\136\137",["notelementof"]="\226\136\137",
["notequal"]="\226\137\160",["notgreater"]="\226\137\175",["notgreaternorequal"]="\226\137\177",["notgreaternorless"]="\226\137\185",
["notidentical"]="\226\137\162",["notless"]="\226\137\174",["notlessnorequal"]="\226\137\176",["notparallel"]="\226\136\166",
["notprecedes"]="\226\138\128",["notsubset"]="\226\138\132",["notsucceeds"]="\226\138\129",["notsuperset"]="\226\138\133",
["nowarmenian"]="\213\182",["nparen"]="\226\146\169",["nssquare"]="\227\142\177",["nsuperior"]="\226\129\191",
["ntilde"]="\195\177",["nu"]="\206\189",["nuhiragana"]="\227\129\172",["nukatakana"]="\227\131\140",["nukatakanahalfwidth"]="\239\190\135",
["nuktabengali"]="\224\166\188",["nuktadeva"]="\224\164\188",["nuktagujarati"]="\224\170\188",["nuktagurmukhi"]="\224\168\188",
["numbersign"]="#",["numbersignmonospace"]="\239\188\131",["numbersignsmall"]="\239\185\159",["numeralsigngreek"]="\205\180",
["numeralsignlowergreek"]="\205\181",["numero"]="\226\132\150",["nun"]="\215\160",["nundagesh"]="\239\173\128",
["nundageshhebrew"]="\239\173\128",["nunhebrew"]="\215\160",["nvsquare"]="\227\142\181",["nwsquare"]="\227\142\187",
["nyabengali"]="\224\166\158",["nyadeva"]="\224\164\158",["nyagujarati"]="\224\170\158",["nyagurmukhi"]="\224\168\158",
["o"]="o",["oacute"]="\195\179",["oangthai"]="\224\184\173",["obarred"]="\201\181",["obarredcyrillic"]="\211\169",
["obarreddieresiscyrillic"]="\211\171",["obengali"]="\224\166\147",["obopomofo"]="\227\132\155",["obreve"]="\197\143",
["ocandradeva"]="\224\164\145",["ocandragujarati"]="\224\170\145",["ocandravowelsigndeva"]="\224\165\137",
["ocandravowelsigngujarati"]="\224\171\137",["ocaron"]="\199\146",["ocircle"]="\226\147\158",["ocircumflex"]="\195\180",
["ocircumflexacute"]="\225\187\145",["ocircumflexdotbelow"]="\225\187\153",["ocircumflexgrave"]="\225\187\147",
["ocircumflexhookabove"]="\225\187\149",["ocircumflextilde"]="\225\187\151",["ocyrillic"]="\208\190",
["odblacute"]="\197\145",["odblgrave"]="\200\141",["odeva"]="\224\164\147",["odieresis"]="\195\182",["odieresiscyrillic"]="\211\167",
["odotbelow"]="\225\187\141",["oe"]="\197\147",["oekorean"]="\227\133\154",["ogonek"]="\203\155",["ogonekcmb"]="\204\168",
["ograve"]="\195\178",["ogujarati"]="\224\170\147",["oharmenian"]="\214\133",["ohiragana"]="\227\129\138",
["ohookabove"]="\225\187\143",["ohorn"]="\198\161",["ohornacute"]="\225\187\155",["ohorndotbelow"]="\225\187\163",
["ohorngrave"]="\225\187\157",["ohornhookabove"]="\225\187\159",["ohorntilde"]="\225\187\161",["ohungarumlaut"]="\197\145",
["oi"]="\198\163",["oinvertedbreve"]="\200\143",["okatakana"]="\227\130\170",["okatakanahalfwidth"]="\239\189\181",
["okorean"]="\227\133\151",["olehebrew"]="\214\171",["omacron"]="\197\141",["omacronacute"]="\225\185\147",
["omacrongrave"]="\225\185\145",["omdeva"]="\224\165\144",["omega"]="\207\137",["omega1"]="\207\150",
["omegacyrillic"]="\209\161",["omegalatinclosed"]="\201\183",["omegaroundcyrillic"]="\209\187",["omegatitlocyrillic"]="\209\189",
["omegatonos"]="\207\142",["omgujarati"]="\224\171\144",["omicron"]="\206\191",["omicrontonos"]="\207\140",
["omonospace"]="\239\189\143",["one"]="1",["onearabic"]="\217\161",["onebengali"]="\224\167\167",["onecircle"]="\226\145\160",
["onecircleinversesansserif"]="\226\158\138",["onedeva"]="\224\165\167",["onedotenleader"]="\226\128\164",
["oneeighth"]="\226\133\155",["onefitted"]="\239\155\156",["onegujarati"]="\224\171\167",["onegurmukhi"]="\224\169\167",
["onehackarabic"]="\217\161",["onehalf"]="\194\189",["onehangzhou"]="\227\128\161",["oneideographicparen"]="\227\136\160",
["oneinferior"]="\226\130\129",["onemonospace"]="\239\188\145",["onenumeratorbengali"]="\224\167\180",
["oneoldstyle"]="\239\156\177",["oneparen"]="\226\145\180",["oneperiod"]="\226\146\136",["onepersian"]="\219\177",
["onequarter"]="\194\188",["oneroman"]="\226\133\176",["onesuperior"]="\194\185",["onethai"]="\224\185\145",
["onethird"]="\226\133\147",["oogonek"]="\199\171",["oogonekmacron"]="\199\173",["oogurmukhi"]="\224\168\147",
["oomatragurmukhi"]="\224\169\139",["oopen"]="\201\148",["oparen"]="\226\146\170",["openbullet"]="\226\151\166",
["option"]="\226\140\165",["ordfeminine"]="\194\170",["ordmasculine"]="\194\186",["orthogonal"]="\226\136\159",
["oshortdeva"]="\224\164\146",["oshortvowelsigndeva"]="\224\165\138",["oslash"]="\195\184",["oslashacute"]="\199\191",
["osmallhiragana"]="\227\129\137",["osmallkatakana"]="\227\130\169",["osmallkatakanahalfwidth"]="\239\189\171",
["ostrokeacute"]="\199\191",["osuperior"]="\239\155\176",["otcyrillic"]="\209\191",["otilde"]="\195\181",
["otildeacute"]="\225\185\141",["otildedieresis"]="\225\185\143",["oubopomofo"]="\227\132\161",["overline"]="\226\128\190",
["overlinecenterline"]="\239\185\138",["overlinecmb"]="\204\133",["overlinedashed"]="\239\185\137",["overlinedblwavy"]="\239\185\140",
["overlinewavy"]="\239\185\139",["overscore"]="\194\175",["ovowelsignbengali"]="\224\167\139",["ovowelsigndeva"]="\224\165\139",
["ovowelsigngujarati"]="\224\171\139",["p"]="p",["paampssquare"]="\227\142\128",["paasentosquare"]="\227\140\171",
["pabengali"]="\224\166\170",["pacute"]="\225\185\149",["padeva"]="\224\164\170",["pagedown"]="\226\135\159",
["pageup"]="\226\135\158",["pagujarati"]="\224\170\170",["pagurmukhi"]="\224\168\170",["pahiragana"]="\227\129\177",
["paiyannoithai"]="\224\184\175",["pakatakana"]="\227\131\145",["palatalizationcyrilliccmb"]="\210\132",
["palochkacyrillic"]="\211\128",["pansioskorean"]="\227\133\191",["paragraph"]="\194\182",["parallel"]="\226\136\165",
["parenleft"]="(",["parenleftaltonearabic"]="\239\180\190",["parenleftbt"]="\239\163\173",["parenleftex"]="\239\163\172",
["parenleftinferior"]="\226\130\141",["parenleftmonospace"]="\239\188\136",["parenleftsmall"]="\239\185\153",
["parenleftsuperior"]="\226\129\189",["parenlefttp"]="\239\163\171",["parenleftvertical"]="\239\184\181",
["parenright"]=")",["parenrightaltonearabic"]="\239\180\191",["parenrightbt"]="\239\163\184",["parenrightex"]="\239\163\183",
["parenrightinferior"]="\226\130\142",["parenrightmonospace"]="\239\188\137",["parenrightsmall"]="\239\185\154",
["parenrightsuperior"]="\226\129\190",["parenrighttp"]="\239\163\182",["parenrightvertical"]="\239\184\182",
["partialdiff"]="\226\136\130",["paseqhebrew"]="\215\128",["pashtahebrew"]="\214\153",["pasquare"]="\227\142\169",
["patah"]="\214\183",["patah11"]="\214\183",["patah1d"]="\214\183",["patah2a"]="\214\183",["patahhebrew"]="\214\183",
["patahnarrowhebrew"]="\214\183",["patahquarterhebrew"]="\214\183",["patahwidehebrew"]="\214\183",["pazerhebrew"]="\214\161",
["pbopomofo"]="\227\132\134",["pcircle"]="\226\147\159",["pdotaccent"]="\225\185\151",["pe"]="\215\164",
["pecyrillic"]="\208\191",["pedagesh"]="\239\173\132",["pedageshhebrew"]="\239\173\132",["peezisquare"]="\227\140\187",
["pefinaldageshhebrew"]="\239\173\131",["peharabic"]="\217\190",["peharmenian"]="\213\186",["pehebrew"]="\215\164",
["pehfinalarabic"]="\239\173\151",["pehinitialarabic"]="\239\173\152",["pehiragana"]="\227\129\186",["pehmedialarabic"]="\239\173\153",
["pekatakana"]="\227\131\154",["pemiddlehookcyrillic"]="\210\167",["perafehebrew"]="\239\173\142",["percent"]="%",
["percentarabic"]="\217\170",["percentmonospace"]="\239\188\133",["percentsmall"]="\239\185\170",["period"]=".",
["periodarmenian"]="\214\137",["periodcentered"]="\194\183",["periodhalfwidth"]="\239\189\161",["periodinferior"]="\239\155\167",
["periodmonospace"]="\239\188\142",["periodsmall"]="\239\185\146",["periodsuperior"]="\239\155\168",["perispomenigreekcmb"]="\205\130",
["perpendicular"]="\226\138\165",["perthousand"]="\226\128\176",["peseta"]="\226\130\167",["pfsquare"]="\227\142\138",
["phabengali"]="\224\166\171",["phadeva"]="\224\164\171",["phagujarati"]="\224\170\171",["phagurmukhi"]="\224\168\171",
["phi"]="\207\134",["phi1"]="\207\149",["phieuphacirclekorean"]="\227\137\186",["phieuphaparenkorean"]="\227\136\154",
["phieuphcirclekorean"]="\227\137\172",["phieuphkorean"]="\227\133\141",["phieuphparenkorean"]="\227\136\140",
["philatin"]="\201\184",["phinthuthai"]="\224\184\186",["phisymbolgreek"]="\207\149",["phook"]="\198\165",
["phophanthai"]="\224\184\158",["phophungthai"]="\224\184\156",["phosamphaothai"]="\224\184\160",["pi"]="\207\128",
["pieupacirclekorean"]="\227\137\179",["pieupaparenkorean"]="\227\136\147",["pieupcieuckorean"]="\227\133\182",
["pieupcirclekorean"]="\227\137\165",["pieupkiyeokkorean"]="\227\133\178",["pieupkorean"]="\227\133\130",
["pieupparenkorean"]="\227\136\133",["pieupsioskiyeokkorean"]="\227\133\180",["pieupsioskorean"]="\227\133\132",
["pieupsiostikeutkorean"]="\227\133\181",["pieupthieuthkorean"]="\227\133\183",["pieuptikeutkorean"]="\227\133\179",
["pihiragana"]="\227\129\180",["pikatakana"]="\227\131\148",["pisymbolgreek"]="\207\150",["piwrarmenian"]="\214\131",
["plus"]="+",["plusbelowcmb"]="\204\159",["pluscircle"]="\226\138\149",["plusminus"]="\194\177",["plusmod"]="\203\150",
["plusmonospace"]="\239\188\139",["plussmall"]="\239\185\162",["plussuperior"]="\226\129\186",["pmonospace"]="\239\189\144",
["pmsquare"]="\227\143\152",["pohiragana"]="\227\129\189",["pointingindexdownwhite"]="\226\152\159",["pointingindexleftwhite"]="\226\152\156",
["pointingindexrightwhite"]="\226\152\158",["pointingindexupwhite"]="\226\152\157",["pokatakana"]="\227\131\157",
["poplathai"]="\224\184\155",["postalmark"]="\227\128\146",["postalmarkface"]="\227\128\160",["pparen"]="\226\146\171",
["precedes"]="\226\137\186",["prescription"]="\226\132\158",["primemod"]="\202\185",["primereversed"]="\226\128\181",
["product"]="\226\136\143",["projective"]="\226\140\133",["prolongedkana"]="\227\131\188",["propellor"]="\226\140\152",
["propersubset"]="\226\138\130",["propersuperset"]="\226\138\131",["proportion"]="\226\136\183",["proportional"]="\226\136\157",
["psi"]="\207\136",["psicyrillic"]="\209\177",["psilipneumatacyrilliccmb"]="\210\134",["pssquare"]="\227\142\176",
["puhiragana"]="\227\129\183",["pukatakana"]="\227\131\151",["pvsquare"]="\227\142\180",["pwsquare"]="\227\142\186",
["q"]="q",["qadeva"]="\224\165\152",["qadmahebrew"]="\214\168",["qafarabic"]="\217\130",["qaffinalarabic"]="\239\187\150",
["qafinitialarabic"]="\239\187\151",["qafmedialarabic"]="\239\187\152",["qamats"]="\214\184",["qamats10"]="\214\184",
["qamats1a"]="\214\184",["qamats1c"]="\214\184",["qamats27"]="\214\184",["qamats29"]="\214\184",["qamats33"]="\214\184",
["qamatsde"]="\214\184",["qamatshebrew"]="\214\184",["qamatsnarrowhebrew"]="\214\184",["qamatsqatanhebrew"]="\214\184",
["qamatsqatannarrowhebrew"]="\214\184",["qamatsqatanquarterhebrew"]="\214\184",["qamatsqatanwidehebrew"]="\214\184",
["qamatsquarterhebrew"]="\214\184",["qamatswidehebrew"]="\214\184",["qarneyparahebrew"]="\214\159",["qbopomofo"]="\227\132\145",
["qcircle"]="\226\147\160",["qhook"]="\202\160",["qmonospace"]="\239\189\145",["qof"]="\215\167",["qofdagesh"]="\239\173\135",
["qofdageshhebrew"]="\239\173\135",["qofhatafpatah"]="\215\167\214\178",["qofhatafpatahhebrew"]="\215\167\214\178",
["qofhatafsegol"]="\215\167\214\177",["qofhatafsegolhebrew"]="\215\167\214\177",["qofhebrew"]="\215\167",
["qofhiriq"]="\215\167\214\180",["qofhiriqhebrew"]="\215\167\214\180",["qofholam"]="\215\167\214\185",
["qofholamhebrew"]="\215\167\214\185",["qofpatah"]="\215\167\214\183",["qofpatahhebrew"]="\215\167\214\183",
["qofqamats"]="\215\167\214\184",["qofqamatshebrew"]="\215\167\214\184",["qofqubuts"]="\215\167\214\187",
["qofqubutshebrew"]="\215\167\214\187",["qofsegol"]="\215\167\214\182",["qofsegolhebrew"]="\215\167\214\182",
["qofsheva"]="\215\167\214\176",["qofshevahebrew"]="\215\167\214\176",["qoftsere"]="\215\167\214\181",
["qoftserehebrew"]="\215\167\214\181",["qparen"]="\226\146\172",["quarternote"]="\226\153\169",["qubuts"]="\214\187",
["qubuts18"]="\214\187",["qubuts25"]="\214\187",["qubuts31"]="\214\187",["qubutshebrew"]="\214\187",["qubutsnarrowhebrew"]="\214\187",
["qubutsquarterhebrew"]="\214\187",["qubutswidehebrew"]="\214\187",["question"]="?",["questionarabic"]="\216\159",
["questionarmenian"]="\213\158",["questiondown"]="\194\191",["questiondownsmall"]="\239\158\191",["questiongreek"]="\205\190",
["questionmonospace"]="\239\188\159",["questionsmall"]="\239\156\191",["quotedbl"]="\"",["quotedblbase"]="\226\128\158",
["quotedblleft"]="\226\128\156",["quotedblmonospace"]="\239\188\130",["quotedblprime"]="\227\128\158",
["quotedblprimereversed"]="\227\128\157",["quotedblright"]="\226\128\157",["quoteleft"]="\226\128\152",
["quoteleftreversed"]="\226\128\155",["quotereversed"]="\226\128\155",["quoteright"]="\226\128\153",["quoterightn"]="\197\137",
["quotesinglbase"]="\226\128\154",["quotesingle"]="'",["quotesinglemonospace"]="\239\188\135",["r"]="r",
["raarmenian"]="\213\188",["rabengali"]="\224\166\176",["racute"]="\197\149",["radeva"]="\224\164\176",
["radical"]="\226\136\154",["radicalex"]="\239\163\165",["radoverssquare"]="\227\142\174",["radoverssquaredsquare"]="\227\142\175",
["radsquare"]="\227\142\173",["rafe"]="\214\191",["rafehebrew"]="\214\191",["ragujarati"]="\224\170\176",
["ragurmukhi"]="\224\168\176",["rahiragana"]="\227\130\137",["rakatakana"]="\227\131\169",["rakatakanahalfwidth"]="\239\190\151",
["ralowerdiagonalbengali"]="\224\167\177",["ramiddlediagonalbengali"]="\224\167\176",["ramshorn"]="\201\164",
["ratio"]="\226\136\182",["rbopomofo"]="\227\132\150",["rcaron"]="\197\153",["rcedilla"]="\197\151",["rcircle"]="\226\147\161",
["rcommaaccent"]="\197\151",["rdblgrave"]="\200\145",["rdotaccent"]="\225\185\153",["rdotbelow"]="\225\185\155",
["rdotbelowmacron"]="\225\185\157",["referencemark"]="\226\128\187",["reflexsubset"]="\226\138\134",["reflexsuperset"]="\226\138\135",
["registered"]="\194\174",["registersans"]="\239\163\168",["registerserif"]="\239\155\154",["reharabic"]="\216\177",
["reharmenian"]="\214\128",["rehfinalarabic"]="\239\186\174",["rehiragana"]="\227\130\140",["rehyehaleflamarabic"]="\216\177\239\187\179\239\186\142\217\132",
["rekatakana"]="\227\131\172",["rekatakanahalfwidth"]="\239\190\154",["resh"]="\215\168",["reshdageshhebrew"]="\239\173\136",
["reshhatafpatah"]="\215\168\214\178",["reshhatafpatahhebrew"]="\215\168\214\178",["reshhatafsegol"]="\215\168\214\177",
["reshhatafsegolhebrew"]="\215\168\214\177",["reshhebrew"]="\215\168",["reshhiriq"]="\215\168\214\180",
["reshhiriqhebrew"]="\215\168\214\180",["reshholam"]="\215\168\214\185",["reshholamhebrew"]="\215\168\214\185",
["reshpatah"]="\215\168\214\183",["reshpatahhebrew"]="\215\168\214\183",["reshqamats"]="\215\168\214\184",
["reshqamatshebrew"]="\215\168\214\184",["reshqubuts"]="\215\168\214\187",["reshqubutshebrew"]="\215\168\214\187",
["reshsegol"]="\215\168\214\182",["reshsegolhebrew"]="\215\168\214\182",["reshsheva"]="\215\168\214\176",
["reshshevahebrew"]="\215\168\214\176",["reshtsere"]="\215\168\214\181",["reshtserehebrew"]="\215\168\214\181",
["reversedtilde"]="\226\136\189",["reviahebrew"]="\214\151",["reviamugrashhebrew"]="\214\151",["revlogicalnot"]="\226\140\144",
["rfishhook"]="\201\190",["rfishhookreversed"]="\201\191",["rhabengali"]="\224\167\157",["rhadeva"]="\224\165\157",
["rho"]="\207\129",["rhook"]="\201\189",["rhookturned"]="\201\187",["rhookturnedsuperior"]="\202\181",
["rhosymbolgreek"]="\207\177",["rhotichookmod"]="\203\158",["rieulacirclekorean"]="\227\137\177",["rieulaparenkorean"]="\227\136\145",
["rieulcirclekorean"]="\227\137\163",["rieulhieuhkorean"]="\227\133\128",["rieulkiyeokkorean"]="\227\132\186",
["rieulkiyeoksioskorean"]="\227\133\169",["rieulkorean"]="\227\132\185",["rieulmieumkorean"]="\227\132\187",
["rieulpansioskorean"]="\227\133\172",["rieulparenkorean"]="\227\136\131",["rieulphieuphkorean"]="\227\132\191",
["rieulpieupkorean"]="\227\132\188",["rieulpieupsioskorean"]="\227\133\171",["rieulsioskorean"]="\227\132\189",
["rieulthieuthkorean"]="\227\132\190",["rieultikeutkorean"]="\227\133\170",["rieulyeorinhieuhkorean"]="\227\133\173",
["rightangle"]="\226\136\159",["righttackbelowcmb"]="\204\153",["righttriangle"]="\226\138\191",["rihiragana"]="\227\130\138",
["rikatakana"]="\227\131\170",["rikatakanahalfwidth"]="\239\190\152",["ring"]="\203\154",["ringbelowcmb"]="\204\165",
["ringcmb"]="\204\138",["ringhalfleft"]="\202\191",["ringhalfleftarmenian"]="\213\153",["ringhalfleftbelowcmb"]="\204\156",
["ringhalfleftcentered"]="\203\147",["ringhalfright"]="\202\190",["ringhalfrightbelowcmb"]="\204\185",
["ringhalfrightcentered"]="\203\146",["rinvertedbreve"]="\200\147",["rittorusquare"]="\227\141\145",["rlinebelow"]="\225\185\159",
["rlongleg"]="\201\188",["rlonglegturned"]="\201\186",["rmonospace"]="\239\189\146",["rohiragana"]="\227\130\141",
["rokatakana"]="\227\131\173",["rokatakanahalfwidth"]="\239\190\155",["roruathai"]="\224\184\163",["rparen"]="\226\146\173",
["rrabengali"]="\224\167\156",["rradeva"]="\224\164\177",["rragurmukhi"]="\224\169\156",["rreharabic"]="\218\145",
["rrehfinalarabic"]="\239\174\141",["rrvocalicbengali"]="\224\167\160",["rrvocalicdeva"]="\224\165\160",
["rrvocalicgujarati"]="\224\171\160",["rrvocalicvowelsignbengali"]="\224\167\132",["rrvocalicvowelsigndeva"]="\224\165\132",
["rrvocalicvowelsigngujarati"]="\224\171\132",["rsuperior"]="\239\155\177",["rtblock"]="\226\150\144",
["rturned"]="\201\185",["rturnedsuperior"]="\202\180",["ruhiragana"]="\227\130\139",["rukatakana"]="\227\131\171",
["rukatakanahalfwidth"]="\239\190\153",["rupeemarkbengali"]="\224\167\178",["rupeesignbengali"]="\224\167\179",
["rupiah"]="\239\155\157",["ruthai"]="\224\184\164",["rvocalicbengali"]="\224\166\139",["rvocalicdeva"]="\224\164\139",
["rvocalicgujarati"]="\224\170\139",["rvocalicvowelsignbengali"]="\224\167\131",["rvocalicvowelsigndeva"]="\224\165\131",
["rvocalicvowelsigngujarati"]="\224\171\131",["s"]="s",["sabengali"]="\224\166\184",["sacute"]="\197\155",
["sacutedotaccent"]="\225\185\165",["sadarabic"]="\216\181",["sadeva"]="\224\164\184",["sadfinalarabic"]="\239\186\186",
["sadinitialarabic"]="\239\186\187",["sadmedialarabic"]="\239\186\188",["sagujarati"]="\224\170\184",
["sagurmukhi"]="\224\168\184",["sahiragana"]="\227\129\149",["sakatakana"]="\227\130\181",["sakatakanahalfwidth"]="\239\189\187",
["sallallahoualayhewasallamarabic"]="\239\183\186",["samekh"]="\215\161",["samekhdagesh"]="\239\173\129",
["samekhdageshhebrew"]="\239\173\129",["samekhhebrew"]="\215\161",["saraaathai"]="\224\184\178",["saraaethai"]="\224\185\129",
["saraaimaimalaithai"]="\224\185\132",["saraaimaimuanthai"]="\224\185\131",["saraamthai"]="\224\184\179",
["saraathai"]="\224\184\176",["saraethai"]="\224\185\128",["saraiileftthai"]="\239\162\134",["saraiithai"]="\224\184\181",
["saraileftthai"]="\239\162\133",["saraithai"]="\224\184\180",["saraothai"]="\224\185\130",["saraueeleftthai"]="\239\162\136",
["saraueethai"]="\224\184\183",["saraueleftthai"]="\239\162\135",["sarauethai"]="\224\184\182",["sarauthai"]="\224\184\184",
["sarauuthai"]="\224\184\185",["sbopomofo"]="\227\132\153",["scaron"]="\197\161",["scarondotaccent"]="\225\185\167",
["scedilla"]="\197\159",["schwa"]="\201\153",["schwacyrillic"]="\211\153",["schwadieresiscyrillic"]="\211\155",
["schwahook"]="\201\154",["scircle"]="\226\147\162",["scircumflex"]="\197\157",["scommaaccent"]="\200\153",
["sdotaccent"]="\225\185\161",["sdotbelow"]="\225\185\163",["sdotbelowdotaccent"]="\225\185\169",["seagullbelowcmb"]="\204\188",
["second"]="\226\128\179",["secondtonechinese"]="\203\138",["section"]="\194\167",["seenarabic"]="\216\179",
["seenfinalarabic"]="\239\186\178",["seeninitialarabic"]="\239\186\179",["seenmedialarabic"]="\239\186\180",
["segol"]="\214\182",["segol13"]="\214\182",["segol1f"]="\214\182",["segol2c"]="\214\182",["segolhebrew"]="\214\182",
["segolnarrowhebrew"]="\214\182",["segolquarterhebrew"]="\214\182",["segoltahebrew"]="\214\146",["segolwidehebrew"]="\214\182",
["seharmenian"]="\213\189",["sehiragana"]="\227\129\155",["sekatakana"]="\227\130\187",["sekatakanahalfwidth"]="\239\189\190",
["semicolon"]=";",["semicolonarabic"]="\216\155",["semicolonmonospace"]="\239\188\155",["semicolonsmall"]="\239\185\148",
["semivoicedmarkkana"]="\227\130\156",["semivoicedmarkkanahalfwidth"]="\239\190\159",["sentisquare"]="\227\140\162",
["sentosquare"]="\227\140\163",["seven"]="7",["sevenarabic"]="\217\167",["sevenbengali"]="\224\167\173",
["sevencircle"]="\226\145\166",["sevencircleinversesansserif"]="\226\158\144",["sevendeva"]="\224\165\173",
["seveneighths"]="\226\133\158",["sevengujarati"]="\224\171\173",["sevengurmukhi"]="\224\169\173",["sevenhackarabic"]="\217\167",
["sevenhangzhou"]="\227\128\167",["sevenideographicparen"]="\227\136\166",["seveninferior"]="\226\130\135",
["sevenmonospace"]="\239\188\151",["sevenoldstyle"]="\239\156\183",["sevenparen"]="\226\145\186",["sevenperiod"]="\226\146\142",
["sevenpersian"]="\219\183",["sevenroman"]="\226\133\182",["sevensuperior"]="\226\129\183",["seventeencircle"]="\226\145\176",
["seventeenparen"]="\226\146\132",["seventeenperiod"]="\226\146\152",["seventhai"]="\224\185\151",["sfthyphen"]="\194\173",
["shaarmenian"]="\213\183",["shabengali"]="\224\166\182",["shacyrillic"]="\209\136",["shaddaarabic"]="\217\145",
["shaddadammaarabic"]="\239\177\161",["shaddadammatanarabic"]="\239\177\158",["shaddafathaarabic"]="\239\177\160",
["shaddafathatanarabic"]="\217\145\217\139",["shaddakasraarabic"]="\239\177\162",["shaddakasratanarabic"]="\239\177\159",
["shade"]="\226\150\146",["shadedark"]="\226\150\147",["shadelight"]="\226\150\145",["shademedium"]="\226\150\146",
["shadeva"]="\224\164\182",["shagujarati"]="\224\170\182",["shagurmukhi"]="\224\168\182",["shalshelethebrew"]="\214\147",
["shbopomofo"]="\227\132\149",["shchacyrillic"]="\209\137",["sheenarabic"]="\216\180",["sheenfinalarabic"]="\239\186\182",
["sheeninitialarabic"]="\239\186\183",["sheenmedialarabic"]="\239\186\184",["sheicoptic"]="\207\163",
["sheqel"]="\226\130\170",["sheqelhebrew"]="\226\130\170",["sheva"]="\214\176",["sheva115"]="\214\176",
["sheva15"]="\214\176",["sheva22"]="\214\176",["sheva2e"]="\214\176",["shevahebrew"]="\214\176",["shevanarrowhebrew"]="\214\176",
["shevaquarterhebrew"]="\214\176",["shevawidehebrew"]="\214\176",["shhacyrillic"]="\210\187",["shimacoptic"]="\207\173",
["shin"]="\215\169",["shindagesh"]="\239\173\137",["shindageshhebrew"]="\239\173\137",["shindageshshindot"]="\239\172\172",
["shindageshshindothebrew"]="\239\172\172",["shindageshsindot"]="\239\172\173",["shindageshsindothebrew"]="\239\172\173",
["shindothebrew"]="\215\129",["shinhebrew"]="\215\169",["shinshindot"]="\239\172\170",["shinshindothebrew"]="\239\172\170",
["shinsindot"]="\239\172\171",["shinsindothebrew"]="\239\172\171",["shook"]="\202\130",["sigma"]="\207\131",
["sigma1"]="\207\130",["sigmafinal"]="\207\130",["sigmalunatesymbolgreek"]="\207\178",["sihiragana"]="\227\129\151",
["sikatakana"]="\227\130\183",["sikatakanahalfwidth"]="\239\189\188",["siluqhebrew"]="\214\189",["siluqlefthebrew"]="\214\189",
["similar"]="\226\136\188",["sindothebrew"]="\215\130",["siosacirclekorean"]="\227\137\180",["siosaparenkorean"]="\227\136\148",
["sioscieuckorean"]="\227\133\190",["sioscirclekorean"]="\227\137\166",["sioskiyeokkorean"]="\227\133\186",
["sioskorean"]="\227\133\133",["siosnieunkorean"]="\227\133\187",["siosparenkorean"]="\227\136\134",["siospieupkorean"]="\227\133\189",
["siostikeutkorean"]="\227\133\188",["six"]="6",["sixarabic"]="\217\166",["sixbengali"]="\224\167\172",
["sixcircle"]="\226\145\165",["sixcircleinversesansserif"]="\226\158\143",["sixdeva"]="\224\165\172",
["sixgujarati"]="\224\171\172",["sixgurmukhi"]="\224\169\172",["sixhackarabic"]="\217\166",["sixhangzhou"]="\227\128\166",
["sixideographicparen"]="\227\136\165",["sixinferior"]="\226\130\134",["sixmonospace"]="\239\188\150",
["sixoldstyle"]="\239\156\182",["sixparen"]="\226\145\185",["sixperiod"]="\226\146\141",["sixpersian"]="\219\182",
["sixroman"]="\226\133\181",["sixsuperior"]="\226\129\182",["sixteencircle"]="\226\145\175",["sixteencurrencydenominatorbengali"]="\224\167\185",
["sixteenparen"]="\226\146\131",["sixteenperiod"]="\226\146\151",["sixthai"]="\224\185\150",["slash"]="/",
["slashmonospace"]="\239\188\143",["slong"]="\197\191",["slongdotaccent"]="\225\186\155",["smileface"]="\226\152\186",
["smonospace"]="\239\189\147",["sofpasuqhebrew"]="\215\131",["softhyphen"]="\194\173",["softsigncyrillic"]="\209\140",
["sohiragana"]="\227\129\157",["sokatakana"]="\227\130\189",["sokatakanahalfwidth"]="\239\189\191",["soliduslongoverlaycmb"]="\204\184",
["solidusshortoverlaycmb"]="\204\183",["sorusithai"]="\224\184\169",["sosalathai"]="\224\184\168",["sosothai"]="\224\184\139",
["sosuathai"]="\224\184\170",["space"]=" ",["spacehackarabic"]=" ",["spade"]="\226\153\160",["spadesuitblack"]="\226\153\160",
["spadesuitwhite"]="\226\153\164",["sparen"]="\226\146\174",["squarebelowcmb"]="\204\187",["squarecc"]="\227\143\132",
["squarecm"]="\227\142\157",["squarediagonalcrosshatchfill"]="\226\150\169",["squarehorizontalfill"]="\226\150\164",
["squarekg"]="\227\142\143",["squarekm"]="\227\142\158",["squarekmcapital"]="\227\143\142",["squareln"]="\227\143\145",
["squarelog"]="\227\143\146",["squaremg"]="\227\142\142",["squaremil"]="\227\143\149",["squaremm"]="\227\142\156",
["squaremsquared"]="\227\142\161",["squareorthogonalcrosshatchfill"]="\226\150\166",["squareupperlefttolowerrightfill"]="\226\150\167",
["squareupperrighttolowerleftfill"]="\226\150\168",["squareverticalfill"]="\226\150\165",["squarewhitewithsmallblack"]="\226\150\163",
["srsquare"]="\227\143\155",["ssabengali"]="\224\166\183",["ssadeva"]="\224\164\183",["ssagujarati"]="\224\170\183",
["ssangcieuckorean"]="\227\133\137",["ssanghieuhkorean"]="\227\134\133",["ssangieungkorean"]="\227\134\128",
["ssangkiyeokkorean"]="\227\132\178",["ssangnieunkorean"]="\227\133\165",["ssangpieupkorean"]="\227\133\131",
["ssangsioskorean"]="\227\133\134",["ssangtikeutkorean"]="\227\132\184",["ssuperior"]="\239\155\178",
["sterling"]="\194\163",["sterlingmonospace"]="\239\191\161",["strokelongoverlaycmb"]="\204\182",["strokeshortoverlaycmb"]="\204\181",
["subset"]="\226\138\130",["subsetnotequal"]="\226\138\138",["subsetorequal"]="\226\138\134",["succeeds"]="\226\137\187",
["suchthat"]="\226\136\139",["suhiragana"]="\227\129\153",["sukatakana"]="\227\130\185",["sukatakanahalfwidth"]="\239\189\189",
["sukunarabic"]="\217\146",["summation"]="\226\136\145",["sun"]="\226\152\188",["superset"]="\226\138\131",
["supersetnotequal"]="\226\138\139",["supersetorequal"]="\226\138\135",["svsquare"]="\227\143\156",["syouwaerasquare"]="\227\141\188",
["t"]="t",["tabengali"]="\224\166\164",["tackdown"]="\226\138\164",["tackleft"]="\226\138\163",["tadeva"]="\224\164\164",
["tagujarati"]="\224\170\164",["tagurmukhi"]="\224\168\164",["taharabic"]="\216\183",["tahfinalarabic"]="\239\187\130",
["tahinitialarabic"]="\239\187\131",["tahiragana"]="\227\129\159",["tahmedialarabic"]="\239\187\132",
["taisyouerasquare"]="\227\141\189",["takatakana"]="\227\130\191",["takatakanahalfwidth"]="\239\190\128",
["tatweelarabic"]="\217\128",["tau"]="\207\132",["tav"]="\215\170",["tavdages"]="\239\173\138",["tavdagesh"]="\239\173\138",
["tavdageshhebrew"]="\239\173\138",["tavhebrew"]="\215\170",["tbar"]="\197\167",["tbopomofo"]="\227\132\138",
["tcaron"]="\197\165",["tccurl"]="\202\168",["tcedilla"]="\197\163",["tcheharabic"]="\218\134",["tchehfinalarabic"]="\239\173\187",
["tchehinitialarabic"]="\239\173\188",["tchehmedialarabic"]="\239\173\189",["tchehmeeminitialarabic"]="\239\173\188\239\187\164",
["tcircle"]="\226\147\163",["tcircumflexbelow"]="\225\185\177",["tcommaaccent"]="\197\163",["tdieresis"]="\225\186\151",
["tdotaccent"]="\225\185\171",["tdotbelow"]="\225\185\173",["tecyrillic"]="\209\130",["tedescendercyrillic"]="\210\173",
["teharabic"]="\216\170",["tehfinalarabic"]="\239\186\150",["tehhahinitialarabic"]="\239\178\162",["tehhahisolatedarabic"]="\239\176\140",
["tehinitialarabic"]="\239\186\151",["tehiragana"]="\227\129\166",["tehjeeminitialarabic"]="\239\178\161",
["tehjeemisolatedarabic"]="\239\176\139",["tehmarbutaarabic"]="\216\169",["tehmarbutafinalarabic"]="\239\186\148",
["tehmedialarabic"]="\239\186\152",["tehmeeminitialarabic"]="\239\178\164",["tehmeemisolatedarabic"]="\239\176\142",
["tehnoonfinalarabic"]="\239\177\179",["tekatakana"]="\227\131\134",["tekatakanahalfwidth"]="\239\190\131",
["telephone"]="\226\132\161",["telephoneblack"]="\226\152\142",["telishagedolahebrew"]="\214\160",["telishaqetanahebrew"]="\214\169",
["tencircle"]="\226\145\169",["tenideographicparen"]="\227\136\169",["tenparen"]="\226\145\189",["tenperiod"]="\226\146\145",
["tenroman"]="\226\133\185",["tesh"]="\202\167",["tet"]="\215\152",["tetdagesh"]="\239\172\184",["tetdageshhebrew"]="\239\172\184",
["tethebrew"]="\215\152",["tetsecyrillic"]="\210\181",["tevirhebrew"]="\214\155",["tevirlefthebrew"]="\214\155",
["thabengali"]="\224\166\165",["thadeva"]="\224\164\165",["thagujarati"]="\224\170\165",["thagurmukhi"]="\224\168\165",
["thalarabic"]="\216\176",["thalfinalarabic"]="\239\186\172",["thanthakhatlowleftthai"]="\239\162\152",
["thanthakhatlowrightthai"]="\239\162\151",["thanthakhatthai"]="\224\185\140",["thanthakhatupperleftthai"]="\239\162\150",
["theharabic"]="\216\171",["thehfinalarabic"]="\239\186\154",["thehinitialarabic"]="\239\186\155",["thehmedialarabic"]="\239\186\156",
["thereexists"]="\226\136\131",["therefore"]="\226\136\180",["theta"]="\206\184",["theta1"]="\207\145",
["thetasymbolgreek"]="\207\145",["thieuthacirclekorean"]="\227\137\185",["thieuthaparenkorean"]="\227\136\153",
["thieuthcirclekorean"]="\227\137\171",["thieuthkorean"]="\227\133\140",["thieuthparenkorean"]="\227\136\139",
["thirteencircle"]="\226\145\172",["thirteenparen"]="\226\146\128",["thirteenperiod"]="\226\146\148",
["thonangmonthothai"]="\224\184\145",["thook"]="\198\173",["thophuthaothai"]="\224\184\146",["thorn"]="\195\190",
["thothahanthai"]="\224\184\151",["thothanthai"]="\224\184\144",["thothongthai"]="\224\184\152",["thothungthai"]="\224\184\150",
["thousandcyrillic"]="\210\130",["thousandsseparatorarabic"]="\217\172",["thousandsseparatorpersian"]="\217\172",
["three"]="3",["threearabic"]="\217\163",["threebengali"]="\224\167\169",["threecircle"]="\226\145\162",
["threecircleinversesansserif"]="\226\158\140",["threedeva"]="\224\165\169",["threeeighths"]="\226\133\156",
["threegujarati"]="\224\171\169",["threegurmukhi"]="\224\169\169",["threehackarabic"]="\217\163",["threehangzhou"]="\227\128\163",
["threeideographicparen"]="\227\136\162",["threeinferior"]="\226\130\131",["threemonospace"]="\239\188\147",
["threenumeratorbengali"]="\224\167\182",["threeoldstyle"]="\239\156\179",["threeparen"]="\226\145\182",
["threeperiod"]="\226\146\138",["threepersian"]="\219\179",["threequarters"]="\194\190",["threequartersemdash"]="\239\155\158",
["threeroman"]="\226\133\178",["threesuperior"]="\194\179",["threethai"]="\224\185\147",["thzsquare"]="\227\142\148",
["tihiragana"]="\227\129\161",["tikatakana"]="\227\131\129",["tikatakanahalfwidth"]="\239\190\129",["tikeutacirclekorean"]="\227\137\176",
["tikeutaparenkorean"]="\227\136\144",["tikeutcirclekorean"]="\227\137\162",["tikeutkorean"]="\227\132\183",
["tikeutparenkorean"]="\227\136\130",["tilde"]="\203\156",["tildebelowcmb"]="\204\176",["tildecmb"]="\204\131",
["tildecomb"]="\204\131",["tildedoublecmb"]="\205\160",["tildeoperator"]="\226\136\188",["tildeoverlaycmb"]="\204\180",
["tildeverticalcmb"]="\204\190",["timescircle"]="\226\138\151",["tipehahebrew"]="\214\150",["tipehalefthebrew"]="\214\150",
["tippigurmukhi"]="\224\169\176",["titlocyrilliccmb"]="\210\131",["tiwnarmenian"]="\213\191",["tlinebelow"]="\225\185\175",
["tmonospace"]="\239\189\148",["toarmenian"]="\213\169",["tohiragana"]="\227\129\168",["tokatakana"]="\227\131\136",
["tokatakanahalfwidth"]="\239\190\132",["tonebarextrahighmod"]="\203\165",["tonebarextralowmod"]="\203\169",
["tonebarhighmod"]="\203\166",["tonebarlowmod"]="\203\168",["tonebarmidmod"]="\203\167",["tonefive"]="\198\189",
["tonesix"]="\198\133",["tonetwo"]="\198\168",["tonos"]="\206\132",["tonsquare"]="\227\140\167",["topatakthai"]="\224\184\143",
["tortoiseshellbracketleft"]="\227\128\148",["tortoiseshellbracketleftsmall"]="\239\185\157",["tortoiseshellbracketleftvertical"]="\239\184\185",
["tortoiseshellbracketright"]="\227\128\149",["tortoiseshellbracketrightsmall"]="\239\185\158",["tortoiseshellbracketrightvertical"]="\239\184\186",
["totaothai"]="\224\184\149",["tpalatalhook"]="\198\171",["tparen"]="\226\146\175",["trademark"]="\226\132\162",
["trademarksans"]="\239\163\170",["trademarkserif"]="\239\155\155",["tretroflexhook"]="\202\136",["triagdn"]="\226\150\188",
["triaglf"]="\226\151\132",["triagrt"]="\226\150\186",["triagup"]="\226\150\178",["ts"]="\202\166",["tsadi"]="\215\166",
["tsadidagesh"]="\239\173\134",["tsadidageshhebrew"]="\239\173\134",["tsadihebrew"]="\215\166",["tsecyrillic"]="\209\134",
["tsere"]="\214\181",["tsere12"]="\214\181",["tsere1e"]="\214\181",["tsere2b"]="\214\181",["tserehebrew"]="\214\181",
["tserenarrowhebrew"]="\214\181",["tserequarterhebrew"]="\214\181",["tserewidehebrew"]="\214\181",["tshecyrillic"]="\209\155",
["tsuperior"]="\239\155\179",["ttabengali"]="\224\166\159",["ttadeva"]="\224\164\159",["ttagujarati"]="\224\170\159",
["ttagurmukhi"]="\224\168\159",["tteharabic"]="\217\185",["ttehfinalarabic"]="\239\173\167",["ttehinitialarabic"]="\239\173\168",
["ttehmedialarabic"]="\239\173\169",["tthabengali"]="\224\166\160",["tthadeva"]="\224\164\160",["tthagujarati"]="\224\170\160",
["tthagurmukhi"]="\224\168\160",["tturned"]="\202\135",["tuhiragana"]="\227\129\164",["tukatakana"]="\227\131\132",
["tukatakanahalfwidth"]="\239\190\130",["tusmallhiragana"]="\227\129\163",["tusmallkatakana"]="\227\131\131",
["tusmallkatakanahalfwidth"]="\239\189\175",["twelvecircle"]="\226\145\171",["twelveparen"]="\226\145\191",
["twelveperiod"]="\226\146\147",["twelveroman"]="\226\133\187",["twentycircle"]="\226\145\179",["twentyhangzhou"]="\229\141\132",
["twentyparen"]="\226\146\135",["twentyperiod"]="\226\146\155",["two"]="2",["twoarabic"]="\217\162",["twobengali"]="\224\167\168",
["twocircle"]="\226\145\161",["twocircleinversesansserif"]="\226\158\139",["twodeva"]="\224\165\168",
["twodotenleader"]="\226\128\165",["twodotleader"]="\226\128\165",["twodotleadervertical"]="\239\184\176",
["twogujarati"]="\224\171\168",["twogurmukhi"]="\224\169\168",["twohackarabic"]="\217\162",["twohangzhou"]="\227\128\162",
["twoideographicparen"]="\227\136\161",["twoinferior"]="\226\130\130",["twomonospace"]="\239\188\146",
["twonumeratorbengali"]="\224\167\181",["twooldstyle"]="\239\156\178",["twoparen"]="\226\145\181",["twoperiod"]="\226\146\137",
["twopersian"]="\219\178",["tworoman"]="\226\133\177",["twostroke"]="\198\187",["twosuperior"]="\194\178",
["twothai"]="\224\185\146",["twothirds"]="\226\133\148",["u"]="u",["uacute"]="\195\186",["ubar"]="\202\137",
["ubengali"]="\224\166\137",["ubopomofo"]="\227\132\168",["ubreve"]="\197\173",["ucaron"]="\199\148",
["ucircle"]="\226\147\164",["ucircumflex"]="\195\187",["ucircumflexbelow"]="\225\185\183",["ucyrillic"]="\209\131",
["udattadeva"]="\224\165\145",["udblacute"]="\197\177",["udblgrave"]="\200\149",["udeva"]="\224\164\137",
["udieresis"]="\195\188",["udieresisacute"]="\199\152",["udieresisbelow"]="\225\185\179",["udieresiscaron"]="\199\154",
["udieresiscyrillic"]="\211\177",["udieresisgrave"]="\199\156",["udieresismacron"]="\199\150",["udotbelow"]="\225\187\165",
["ugrave"]="\195\185",["ugujarati"]="\224\170\137",["ugurmukhi"]="\224\168\137",["uhiragana"]="\227\129\134",
["uhookabove"]="\225\187\167",["uhorn"]="\198\176",["uhornacute"]="\225\187\169",["uhorndotbelow"]="\225\187\177",
["uhorngrave"]="\225\187\171",["uhornhookabove"]="\225\187\173",["uhorntilde"]="\225\187\175",["uhungarumlaut"]="\197\177",
["uhungarumlautcyrillic"]="\211\179",["uinvertedbreve"]="\200\151",["ukatakana"]="\227\130\166",["ukatakanahalfwidth"]="\239\189\179",
["ukcyrillic"]="\209\185",["ukorean"]="\227\133\156",["umacron"]="\197\171",["umacroncyrillic"]="\211\175",
["umacrondieresis"]="\225\185\187",["umatragurmukhi"]="\224\169\129",["umonospace"]="\239\189\149",["underscore"]="_",
["underscoredbl"]="\226\128\151",["underscoremonospace"]="\239\188\191",["underscorevertical"]="\239\184\179",
["underscorewavy"]="\239\185\143",["union"]="\226\136\170",["universal"]="\226\136\128",["uogonek"]="\197\179",
["uparen"]="\226\146\176",["upblock"]="\226\150\128",["upperdothebrew"]="\215\132",["upsilon"]="\207\133",
["upsilondieresis"]="\207\139",["upsilondieresistonos"]="\206\176",["upsilonlatin"]="\202\138",["upsilontonos"]="\207\141",
["uptackbelowcmb"]="\204\157",["uptackmod"]="\203\148",["uragurmukhi"]="\224\169\179",["uring"]="\197\175",
["ushortcyrillic"]="\209\158",["usmallhiragana"]="\227\129\133",["usmallkatakana"]="\227\130\165",["usmallkatakanahalfwidth"]="\239\189\169",
["ustraightcyrillic"]="\210\175",["ustraightstrokecyrillic"]="\210\177",["utilde"]="\197\169",["utildeacute"]="\225\185\185",
["utildebelow"]="\225\185\181",["uubengali"]="\224\166\138",["uudeva"]="\224\164\138",["uugujarati"]="\224\170\138",
["uugurmukhi"]="\224\168\138",["uumatragurmukhi"]="\224\169\130",["uuvowelsignbengali"]="\224\167\130",
["uuvowelsigndeva"]="\224\165\130",["uuvowelsigngujarati"]="\224\171\130",["uvowelsignbengali"]="\224\167\129",
["uvowelsigndeva"]="\224\165\129",["uvowelsigngujarati"]="\224\171\129",["v"]="v",["vadeva"]="\224\164\181",
["vagujarati"]="\224\170\181",["vagurmukhi"]="\224\168\181",["vakatakana"]="\227\131\183",["vav"]="\215\149",
["vavdagesh"]="\239\172\181",["vavdagesh65"]="\239\172\181",["vavdageshhebrew"]="\239\172\181",["vavhebrew"]="\215\149",
["vavholam"]="\239\173\139",["vavholamhebrew"]="\239\173\139",["vavvavhebrew"]="\215\176",["vavyodhebrew"]="\215\177",
["vcircle"]="\226\147\165",["vdotbelow"]="\225\185\191",["vecyrillic"]="\208\178",["veharabic"]="\218\164",
["vehfinalarabic"]="\239\173\171",["vehinitialarabic"]="\239\173\172",["vehmedialarabic"]="\239\173\173",
["vekatakana"]="\227\131\185",["venus"]="\226\153\128",["verticalbar"]="|",["verticallineabovecmb"]="\204\141",
["verticallinebelowcmb"]="\204\169",["verticallinelowmod"]="\203\140",["verticallinemod"]="\203\136",
["vewarmenian"]="\213\190",["vhook"]="\202\139",["vikatakana"]="\227\131\184",["viramabengali"]="\224\167\141",
["viramadeva"]="\224\165\141",["viramagujarati"]="\224\171\141",["visargabengali"]="\224\166\131",["visargadeva"]="\224\164\131",
["visargagujarati"]="\224\170\131",["vmonospace"]="\239\189\150",["voarmenian"]="\213\184",["voicediterationhiragana"]="\227\130\158",
["voicediterationkatakana"]="\227\131\190",["voicedmarkkana"]="\227\130\155",["voicedmarkkanahalfwidth"]="\239\190\158",
["vokatakana"]="\227\131\186",["vparen"]="\226\146\177",["vtilde"]="\225\185\189",["vturned"]="\202\140",
["vuhiragana"]="\227\130\148",["vukatakana"]="\227\131\180",["w"]="w",["wacute"]="\225\186\131",["waekorean"]="\227\133\153",
["wahiragana"]="\227\130\143",["wakatakana"]="\227\131\175",["wakatakanahalfwidth"]="\239\190\156",["wakorean"]="\227\133\152",
["wasmallhiragana"]="\227\130\142",["wasmallkatakana"]="\227\131\174",["wattosquare"]="\227\141\151",
["wavedash"]="\227\128\156",["wavyunderscorevertical"]="\239\184\180",["wawarabic"]="\217\136",["wawfinalarabic"]="\239\187\174",
["wawhamzaabovearabic"]="\216\164",["wawhamzaabovefinalarabic"]="\239\186\134",["wbsquare"]="\227\143\157",
["wcircle"]="\226\147\166",["wcircumflex"]="\197\181",["wdieresis"]="\225\186\133",["wdotaccent"]="\225\186\135",
["wdotbelow"]="\225\186\137",["wehiragana"]="\227\130\145",["weierstrass"]="\226\132\152",["wekatakana"]="\227\131\177",
["wekorean"]="\227\133\158",["weokorean"]="\227\133\157",["wgrave"]="\225\186\129",["whitebullet"]="\226\151\166",
["whitecircle"]="\226\151\139",["whitecircleinverse"]="\226\151\153",["whitecornerbracketleft"]="\227\128\142",
["whitecornerbracketleftvertical"]="\239\185\131",["whitecornerbracketright"]="\227\128\143",["whitecornerbracketrightvertical"]="\239\185\132",
["whitediamond"]="\226\151\135",["whitediamondcontainingblacksmalldiamond"]="\226\151\136",["whitedownpointingsmalltriangle"]="\226\150\191",
["whitedownpointingtriangle"]="\226\150\189",["whiteleftpointingsmalltriangle"]="\226\151\131",["whiteleftpointingtriangle"]="\226\151\129",
["whitelenticularbracketleft"]="\227\128\150",["whitelenticularbracketright"]="\227\128\151",["whiterightpointingsmalltriangle"]="\226\150\185",
["whiterightpointingtriangle"]="\226\150\183",["whitesmallsquare"]="\226\150\171",["whitesmilingface"]="\226\152\186",
["whitesquare"]="\226\150\161",["whitestar"]="\226\152\134",["whitetelephone"]="\226\152\143",["whitetortoiseshellbracketleft"]="\227\128\152",
["whitetortoiseshellbracketright"]="\227\128\153",["whiteuppointingsmalltriangle"]="\226\150\181",["whiteuppointingtriangle"]="\226\150\179",
["wihiragana"]="\227\130\144",["wikatakana"]="\227\131\176",["wikorean"]="\227\133\159",["wmonospace"]="\239\189\151",
["wohiragana"]="\227\130\146",["wokatakana"]="\227\131\178",["wokatakanahalfwidth"]="\239\189\166",["won"]="\226\130\169",
["wonmonospace"]="\239\191\166",["wowaenthai"]="\224\184\167",["wparen"]="\226\146\178",["wring"]="\225\186\152",
["wsuperior"]="\202\183",["wturned"]="\202\141",["wynn"]="\198\191",["x"]="x",["xabovecmb"]="\204\189",
["xbopomofo"]="\227\132\146",["xcircle"]="\226\147\167",["xdieresis"]="\225\186\141",["xdotaccent"]="\225\186\139",
["xeharmenian"]="\213\173",["xi"]="\206\190",["xmonospace"]="\239\189\152",["xparen"]="\226\146\179",
["xsuperior"]="\203\163",["y"]="y",["yaadosquare"]="\227\141\142",["yabengali"]="\224\166\175",["yacute"]="\195\189",
["yadeva"]="\224\164\175",["yaekorean"]="\227\133\146",["yagujarati"]="\224\170\175",["yagurmukhi"]="\224\168\175",
["yahiragana"]="\227\130\132",["yakatakana"]="\227\131\164",["yakatakanahalfwidth"]="\239\190\148",["yakorean"]="\227\133\145",
["yamakkanthai"]="\224\185\142",["yasmallhiragana"]="\227\130\131",["yasmallkatakana"]="\227\131\163",
["yasmallkatakanahalfwidth"]="\239\189\172",["yatcyrillic"]="\209\163",["ycircle"]="\226\147\168",["ycircumflex"]="\197\183",
["ydieresis"]="\195\191",["ydotaccent"]="\225\186\143",["ydotbelow"]="\225\187\181",["yeharabic"]="\217\138",
["yehbarreearabic"]="\219\146",["yehbarreefinalarabic"]="\239\174\175",["yehfinalarabic"]="\239\187\178",
["yehhamzaabovearabic"]="\216\166",["yehhamzaabovefinalarabic"]="\239\186\138",["yehhamzaaboveinitialarabic"]="\239\186\139",
["yehhamzaabovemedialarabic"]="\239\186\140",["yehinitialarabic"]="\239\187\179",["yehmedialarabic"]="\239\187\180",
["yehmeeminitialarabic"]="\239\179\157",["yehmeemisolatedarabic"]="\239\177\152",["yehnoonfinalarabic"]="\239\178\148",
["yehthreedotsbelowarabic"]="\219\145",["yekorean"]="\227\133\150",["yen"]="\194\165",["yenmonospace"]="\239\191\165",
["yeokorean"]="\227\133\149",["yeorinhieuhkorean"]="\227\134\134",["yerahbenyomohebrew"]="\214\170",["yerahbenyomolefthebrew"]="\214\170",
["yericyrillic"]="\209\139",["yerudieresiscyrillic"]="\211\185",["yesieungkorean"]="\227\134\129",["yesieungpansioskorean"]="\227\134\131",
["yesieungsioskorean"]="\227\134\130",["yetivhebrew"]="\214\154",["ygrave"]="\225\187\179",["yhook"]="\198\180",
["yhookabove"]="\225\187\183",["yiarmenian"]="\213\181",["yicyrillic"]="\209\151",["yikorean"]="\227\133\162",
["yinyang"]="\226\152\175",["yiwnarmenian"]="\214\130",["ymonospace"]="\239\189\153",["yod"]="\215\153",
["yoddagesh"]="\239\172\185",["yoddageshhebrew"]="\239\172\185",["yodhebrew"]="\215\153",["yodyodhebrew"]="\215\178",
["yodyodpatahhebrew"]="\239\172\159",["yohiragana"]="\227\130\136",["yoikorean"]="\227\134\137",["yokatakana"]="\227\131\168",
["yokatakanahalfwidth"]="\239\190\150",["yokorean"]="\227\133\155",["yosmallhiragana"]="\227\130\135",
["yosmallkatakana"]="\227\131\167",["yosmallkatakanahalfwidth"]="\239\189\174",["yotgreek"]="\207\179",
["yoyaekorean"]="\227\134\136",["yoyakorean"]="\227\134\135",["yoyakthai"]="\224\184\162",["yoyingthai"]="\224\184\141",
["yparen"]="\226\146\180",["ypogegrammeni"]="\205\186",["ypogegrammenigreekcmb"]="\205\133",["yr"]="\198\166",
["yring"]="\225\186\153",["ysuperior"]="\202\184",["ytilde"]="\225\187\185",["yturned"]="\202\142",["yuhiragana"]="\227\130\134",
["yuikorean"]="\227\134\140",["yukatakana"]="\227\131\166",["yukatakanahalfwidth"]="\239\190\149",["yukorean"]="\227\133\160",
["yusbigcyrillic"]="\209\171",["yusbigiotifiedcyrillic"]="\209\173",["yuslittlecyrillic"]="\209\167",
["yuslittleiotifiedcyrillic"]="\209\169",["yusmallhiragana"]="\227\130\133",["yusmallkatakana"]="\227\131\165",
["yusmallkatakanahalfwidth"]="\239\189\173",["yuyekorean"]="\227\134\139",["yuyeokorean"]="\227\134\138",
["yyabengali"]="\224\167\159",["yyadeva"]="\224\165\159",["z"]="z",["zaarmenian"]="\213\166",["zacute"]="\197\186",
["zadeva"]="\224\165\155",["zagurmukhi"]="\224\169\155",["zaharabic"]="\216\184",["zahfinalarabic"]="\239\187\134",
["zahinitialarabic"]="\239\187\135",["zahiragana"]="\227\129\150",["zahmedialarabic"]="\239\187\136",
["zainarabic"]="\216\178",["zainfinalarabic"]="\239\186\176",["zakatakana"]="\227\130\182",["zaqefgadolhebrew"]="\214\149",
["zaqefqatanhebrew"]="\214\148",["zarqahebrew"]="\214\152",["zayin"]="\215\150",["zayindagesh"]="\239\172\182",
["zayindageshhebrew"]="\239\172\182",["zayinhebrew"]="\215\150",["zbopomofo"]="\227\132\151",["zcaron"]="\197\190",
["zcircle"]="\226\147\169",["zcircumflex"]="\225\186\145",["zcurl"]="\202\145",["zdot"]="\197\188",["zdotaccent"]="\197\188",
["zdotbelow"]="\225\186\147",["zecyrillic"]="\208\183",["zedescendercyrillic"]="\210\153",["zedieresiscyrillic"]="\211\159",
["zehiragana"]="\227\129\156",["zekatakana"]="\227\130\188",["zero"]="0",["zeroarabic"]="\217\160",["zerobengali"]="\224\167\166",
["zerodeva"]="\224\165\166",["zerogujarati"]="\224\171\166",["zerogurmukhi"]="\224\169\166",["zerohackarabic"]="\217\160",
["zeroinferior"]="\226\130\128",["zeromonospace"]="\239\188\144",["zerooldstyle"]="\239\156\176",["zeropersian"]="\219\176",
["zerosuperior"]="\226\129\176",["zerothai"]="\224\185\144",["zerowidthjoiner"]="\239\187\191",["zerowidthnonjoiner"]="\226\128\140",
["zerowidthspace"]="\226\128\139",["zeta"]="\206\182",["zhbopomofo"]="\227\132\147",["zhearmenian"]="\213\170",
["zhebrevecyrillic"]="\211\130",["zhecyrillic"]="\208\182",["zhedescendercyrillic"]="\210\151",["zhedieresiscyrillic"]="\211\157",
["zihiragana"]="\227\129\152",["zikatakana"]="\227\130\184",["zinorhebrew"]="\214\174",["zlinebelow"]="\225\186\149",
["zmonospace"]="\239\189\154",["zohiragana"]="\227\129\158",["zokatakana"]="\227\130\190",["zparen"]="\226\146\181",
["zretroflexhook"]="\202\144",["zstroke"]="\198\182",["zuhiragana"]="\227\129\154",["zukatakana"]="\227\130\186",

} --[[: { [string]: string } ]]

-- ── /Widths resolution: build a code -> glyph-width function ─────────────
-- ISO 32000-1 §9.6.3, Table 111. A simple font's /Widths array is indexed
-- 0..(LastChar-FirstChar), each entry the glyph width (glyph space units,
-- i.e. thousandths of a text space unit) for code (FirstChar + index).
-- /MissingWidth (in /FontDescriptor, default 0 per Table 122) covers any
-- code outside [FirstChar, LastChar]. Returns `nil` (not an error) when
-- /Widths is entirely absent — a legitimate, common case (e.g. a
-- non-embedded standard-14 font relying on its built-in metrics), not a
-- malformed font; the caller (`code_to_width` on the returned `Font`)
-- stays `nil` in that case, and lib/pdf/text.lua's documented
-- w0-treated-as-0 approximation applies exactly as it did before /Widths
-- parsing existed.

--: (Document, { [string]: unknown, [integer]: unknown }) -> (((integer) -> number) | nil)
local function build_code_to_width(doc, dict)
	local widths_arr = as_array(pdf.resolve(doc, dict.Widths))
	if widths_arr == nil then return nil end
	local first_char = as_integer(pdf.resolve(doc, dict.FirstChar))
	if first_char == nil then return nil end

	local missing_width = 0 --: number
	local descriptor = as_table(pdf.resolve(doc, dict.FontDescriptor))
	if descriptor ~= nil then
		local mw = as_number(pdf.resolve(doc, descriptor.MissingWidth))
		if mw ~= nil then missing_width = mw end
	end

	local widths = {} --[[: { [integer]: number } ]]
	local i = 1
	while widths_arr[i] ~= nil do
		local w = as_number(widths_arr[i])
		if w ~= nil then widths[first_char + i - 1] = w end
		i = i + 1
	end

	--: (integer) -> number
	local function code_to_width(code)
		local w = widths[code]
		if w ~= nil then return w end
		return missing_width
	end
	return code_to_width
end

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

-- Shared by /ToUnicode CMaps and (per the Type0 handling below) a Type0
-- font's own /Encoding when it is an embedded CMap stream using the same
-- bfchar/bfrange destination-Unicode syntax — real CID-mapping CMaps
-- normally use begincidchar/begincidrange instead (out of scope: those
-- produce CIDs, not Unicode text), but a producer embedding a
-- Unicode-producing CMap directly at /Encoding is handled identically to
-- /ToUnicode here. Also tracks the first begincodespacerange/
-- endcodespacerange block's low-bound byte length as `codespace_width` (nil
-- if the CMap has none) — /ToUnicode's caller ignores this (ToUnicode's
-- byte width is fixed by the font's own code_width, not by the CMap), but a
-- Type0 /Encoding CMap stream needs it to know its own code byte width.
-- A codespace with multiple ranges of differing byte width (rare,
-- variable-width mixed encodings) is not fully supported: only the first
-- range's width is used, a documented scope limit consistent with this
-- module's existing CID-resolution boundaries.
--: (string) -> ({ [integer]: string } | nil, integer | nil, string | nil)
local function parse_cmap(bytes)
	local r = pdf_object.new_reader(bytes)
	local map = {} --[[: { [integer]: string } ]]
	local codespace_width = nil --: integer | nil

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
				return nil, nil, "malformed CMap: " .. tostring(oerr)
			end
			local token = read_token(r)
			if token == nil then
				return nil, nil, "unexpected byte in CMap at offset " .. r.pos
			end

			if token == "beginbfchar" then
				while true do
					skip_ws_and_comments(r)
					if find(r.src, "endbfchar", r.pos, true) == r.pos then break end
					local src, src_err = pdf_object.parse_object(r)
					if src == nil then
						return nil, nil, "malformed bfchar entry: " .. tostring(src_err)
					end
					local src_str = as_string(src)
					if src_str == nil then return nil, nil, "bfchar source is not a hex string" end
					skip_ws_and_comments(r)
					local dst, dst_err = pdf_object.parse_object(r)
					if dst == nil then return nil, nil, "malformed bfchar destination: " .. tostring(dst_err) end
					local dst_str = as_string(dst)
					if dst_str == nil then return nil, nil, "bfchar destination is not a hex string" end
					map[bytes_to_uint(src_str)] = units_to_utf8(utf16be_units(dst_str))
				end
				skip_ws_and_comments(r)
				if not read_token(r) then return nil, nil, "expected 'endbfchar'" end -- consumes "endbfchar"

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
					if lo_str == nil then return nil, nil, "malformed bfrange entry: " .. tostring(lo_err) end
					skip_ws_and_comments(r)
					local hi, hi_err = pdf_object.parse_object(r)
					if hi == nil then return nil, nil, "malformed bfrange hi: " .. tostring(hi_err) end
					local hi_str = as_string(hi)
					if hi_str == nil then return nil, nil, "bfrange hi is not a hex string" end
					skip_ws_and_comments(r)
					local dst, dst_err = pdf_object.parse_object(r)
					if dst == nil then return nil, nil, "malformed bfrange destination: " .. tostring(dst_err) end

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
						if dst_str == nil then return nil, nil, "bfrange destination is neither a hex string nor an array" end
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

			elseif token == "begincodespacerange" then
				while true do
					skip_ws_and_comments(r)
					if find(r.src, "endcodespacerange", r.pos, true) == r.pos then break end
					local lo, lo_err = pdf_object.parse_object(r)
					if lo == nil then
						return nil, nil, "malformed codespacerange entry: " .. tostring(lo_err)
					end
					local lo_str = as_string(lo)
					if lo_str == nil then return nil, nil, "codespacerange lo is not a hex string" end
					skip_ws_and_comments(r)
					local hi, hi_err = pdf_object.parse_object(r)
					if hi == nil then return nil, nil, "malformed codespacerange hi: " .. tostring(hi_err) end
					if as_string(hi) == nil then return nil, nil, "codespacerange hi is not a hex string" end
					if codespace_width == nil then codespace_width = #lo_str end
				end
				skip_ws_and_comments(r)
				if not read_token(r) then return nil, nil, "expected 'endcodespacerange'" end -- consumes it

			else
				-- Other CMap keywords (usecmap, def, findresource, etc.) are
				-- setup operators this module doesn't need to interpret;
				-- ignored, same as unrecognized content-stream operators.
			end
		end
	end

	return map, codespace_width, nil
end

-- ── Type0/CID font support (ISO 32000-1 §9.7) ────────────────────────────
-- A Type0 (composite) font's character codes select a CID (character
-- identifier) via its /Encoding CMap; the CID then selects a glyph in the
-- /DescendantFonts CIDFont (via CIDToGIDMap for CIDFontType2, or directly
-- for CIDFontType0) and a width via the CIDFont's /DW + /W (ISO 32000-1
-- §9.7.4.3, Table 117/120). Full code->CID resolution for an arbitrary
-- CMap would need either the real Adobe CID-collection resource tables
-- (predefined CMaps like UniGB-UTF16-H) or a begincidchar/begincidrange
-- parser (embedded CMaps) — neither is built here (documented gap, see
-- `M.font_from_dict`'s Type0 branch). What IS in scope: the Identity-H/V
-- predefined CMaps, where code == CID *by definition* ("Identity" is
-- exactly that mapping), so /DW+/W can be looked up directly by code with
-- no CMap resolution at all. `code_to_width` therefore stays nil for any
-- other Type0 /Encoding (predefined Uni*-UTF16-* CMaps, or a custom
-- embedded CMap) even though `code_to_unicode` is supported for those via
-- the paths below — CID and Unicode are looked up through entirely
-- different mechanisms, and only the code==CID case has both.

local PREDEFINED_UTF16_CMAPS = {
	-- Adobe's four CJK character collections (GB/CNS/JIS/KS), UTF-16-H/V
	-- variants only. Per the CMap's own name: its codes ARE the UTF-16BE
	-- code units of the Unicode value directly — the CMap's job in a full
	-- rendering pipeline is converting those units to CIDs of the named
	-- collection for glyph lookup, but for text EXTRACTION the code is
	-- already the answer, no CID step needed. -H/-V (horizontal/vertical
	-- writing mode) decode identically; only layout direction differs,
	-- which is irrelevant here (mirrors this file's existing Identity-H/
	-- Identity-V precedent, which also decodes both the same way).
	["UniGB-UTF16-H"] = true, ["UniGB-UTF16-V"] = true,
	["UniCNS-UTF16-H"] = true, ["UniCNS-UTF16-V"] = true,
	["UniJIS-UTF16-H"] = true, ["UniJIS-UTF16-V"] = true,
	["UniKS-UTF16-H"] = true, ["UniKS-UTF16-V"] = true,
} --[[: { [string]: boolean } ]]

-- ISO 32000-1 §9.7.4.3, Table 117/120: /W is `[ c [w1 w2 ... wn]  cFirst cLast w  ... ]`,
-- an array mixing two entry shapes freely: `cid [w1 w2 ...]` (consecutive
-- CIDs starting at cid, one width per array element) and `cidFirst cidLast
-- w` (every CID in the inclusive range gets the same width w). /DW (default
-- width, Table 117) covers any CID /W doesn't mention; absent, its spec
-- default is 1000 (Table 117, not 0 — distinct from simple fonts'
-- /MissingWidth, which defaults to 0).
--: (Document, { [string]: unknown, [integer]: unknown }) -> ((integer) -> number)
local function build_code_to_cid_width(doc, cidfont_dict)
	local dw = as_number(pdf.resolve(doc, cidfont_dict.DW))
	if dw == nil then dw = 1000 end

	local widths = {} --[[: { [integer]: number } ]]
	local w_arr = as_array(pdf.resolve(doc, cidfont_dict.W))
	if w_arr ~= nil then
		local i = 1
		while w_arr[i] ~= nil do
			local first = as_integer(pdf.resolve(doc, w_arr[i]))
			i = i + 1
			if first == nil then break end -- malformed entry: stop, don't misread the rest
			local second_raw = pdf.resolve(doc, w_arr[i])
			local second_arr = as_array(second_raw)
			if second_arr ~= nil then
				-- `cid [w1 w2 ...]` form.
				local j = 1
				while second_arr[j] ~= nil do
					local w = as_number(second_arr[j])
					if w ~= nil then widths[first + j - 1] = w end
					j = j + 1
				end
				i = i + 1
			else
				-- `cidFirst cidLast w` form.
				local last = as_integer(second_raw)
				i = i + 1
				local w = as_number(pdf.resolve(doc, w_arr[i]))
				i = i + 1
				if last ~= nil and w ~= nil then
					for cid = first, last do widths[cid] = w end
				end
			end
		end
	end

	--: (integer) -> number
	local function code_to_width(code)
		local w = widths[code]
		if w ~= nil then return w end
		return dw
	end
	return code_to_width
end

-- /DescendantFonts (ISO 32000-1 §9.7.3) is a one-element array (the spec
-- allows only exactly one) naming the CIDFont carrying /DW, /W,
-- /CIDToGIDMap, etc.
--: (Document, { [string]: unknown, [integer]: unknown }) -> ({ [string]: unknown, [integer]: unknown } | nil)
local function descendant_cidfont_dict(doc, type0_dict)
	local descendants = as_array(pdf.resolve(doc, type0_dict.DescendantFonts))
	if descendants == nil then return nil end
	return as_table(pdf.resolve(doc, descendants[1]))
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
		local map, _, perr = parse_cmap(tu_bytes)
		return map, perr
	end

	if subtype == "Type0" then
		local encoding_val = pdf.resolve(doc, dict.Encoding)
		local encoding_name = as_name(encoding_val)
		local encoding_stream = as_stream(encoding_val)

		local tounicode_map, tu_err = load_tounicode_map()
		if tu_err ~= nil then return nil, tu_err end

		-- Priority order per file header: /ToUnicode always wins when
		-- present, regardless of /Encoding. Only when it's absent do the
		-- /Encoding-driven fallbacks below apply — mirrors the simple-font
		-- branch's ToUnicode-then-/Encoding priority further down.
		local code_width = 2 --: integer
		--: (integer) -> string | nil
		local function no_mapping_yet(_) return nil end
		local code_to_unicode_type0 = no_mapping_yet --: (integer) -> (string | nil)

		if tounicode_map ~= nil then
			local map = tounicode_map
			--: (integer) -> string | nil
			local function f(code) return map[code] end
			code_to_unicode_type0 = f
		elseif encoding_name ~= nil and PREDEFINED_UTF16_CMAPS[encoding_name] then
			-- The code IS the UTF-16BE code unit already — see
			-- PREDEFINED_UTF16_CMAPS' comment. A lone surrogate code (i.e. a
			-- character outside the BMP, split across two consecutive
			-- 2-byte codes) can't be recombined here: this module decodes
			-- one code at a time with no lookahead across codes (unlike a
			-- /ToUnicode bfrange destination, which declares its multi-unit
			-- destination explicitly per source code). Documented gap, rare
			-- for these four collections' repertoires.
			--: (integer) -> string | nil
			local function f(code) return units_to_utf8({ code }) end
			code_to_unicode_type0 = f
		elseif encoding_stream ~= nil then
			local enc_bytes, enc_err = pdf.stream_to_bytes(encoding_stream)
			if enc_bytes == nil then
				return nil, "failed to decode Type0 /Encoding CMap stream: " .. tostring(enc_err)
			end
			local enc_map, enc_width, enc_perr = parse_cmap(enc_bytes)
			if enc_map == nil then
				return nil, "malformed Type0 /Encoding CMap stream: " .. tostring(enc_perr)
			end
			if enc_width ~= nil then code_width = enc_width end
			local map = enc_map
			--: (integer) -> string | nil
			local function f(code) return map[code] end
			code_to_unicode_type0 = f
		elseif encoding_name == "Identity-H" or encoding_name == "Identity-V" then
			return nil, "Type0 font has no /ToUnicode CMap; mapping composite-font codes to "
				.. "Unicode without one requires full CID font resolution, which is out of "
				.. "scope (documented gap, see file header)"
		else
			return nil, "Type0 font uses /Encoding "
				.. tostring(encoding_name or "(non-name, non-stream value)")
				.. "; only Identity-H/Identity-V, the predefined Uni*-UTF16-H/V CMaps, an "
				.. "embedded CMap stream, or a /ToUnicode CMap are supported "
				.. "(documented gap: general CID-collection CMap resolution is out of scope, "
				.. "see file header)"
		end

		-- CID /DW+/W widths (see build_code_to_cid_width's comment above)
		-- are only wired for Identity-H/V, where code == CID by
		-- definition — every other /Encoding branch above needs a real
		-- code->CID CMap this module doesn't resolve, so code_to_width
		-- stays nil there (lib/pdf/text.lua's w0-as-0 approximation
		-- applies, same as before this existed).
		local code_to_width = nil --: ((integer) -> number) | nil
		if encoding_name == "Identity-H" or encoding_name == "Identity-V" then
			local cidfont_dict = descendant_cidfont_dict(doc, dict)
			if cidfont_dict ~= nil then
				code_to_width = build_code_to_cid_width(doc, cidfont_dict)
			end
		end

		return {
			code_width = code_width,
			code_to_unicode = code_to_unicode_type0,
			code_to_width = code_to_width,
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
		return GLYPH_TO_UTF8[glyph_name]
	end

	local code_to_width = build_code_to_width(doc, dict)

	return { code_width = 1, code_to_unicode = code_to_unicode, code_to_width = code_to_width }, nil
end

return M
