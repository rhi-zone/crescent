if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local lock = require("lib.pkg.lock")

-- ── helpers ────────────────────────────────────────────────────────────────

-- New format (v2): tarball_hash + tree_hash + include
local SIMPLE_V2 = [[
# crescent.lock

[sha1]
version      = "1.0.0"
url          = "https://pkg.rhi.zone/sha1/1.0.0.tar.gz"
tarball_hash = "sha256:a3f1c2b4"
tree_hash    = "sha256:d9e4f1a2"
include      = "**"

[lunajson]
version      = "1.3.0"
url          = "https://pkg.rhi.zone/lunajson/1.3.0.tar.gz"
tarball_hash = "sha256:b7c2d3e4"
tree_hash    = "sha256:c1a8e5f3"
include      = "v2/**"
]]

-- Old format (v1): checksum key instead of tarball_hash, no tree_hash/include
local SIMPLE_V1 = [[
# crescent.lock

[sha1]
version  = "1.0.0"
url      = "https://pkg.rhi.zone/sha1/1.0.0.tar.gz"
checksum = "sha256:a3f1c2b4"

[lunajson]
version  = "1.3.0"
url      = "https://pkg.rhi.zone/lunajson/1.3.0.tar.gz"
checksum = "sha256:b7c2d3e4"
]]

-- ── parse: valid v2 lockfile ────────────────────────────────────────────────

local tbl, err = lock.parse(SIMPLE_V2)
T.ok(tbl, "parse v2 returns table")
T.ok(not err, "parse v2 returns no error")

T.eq(tbl.sha1.version,      "1.0.0",                                  "sha1 version")
T.eq(tbl.sha1.url,          "https://pkg.rhi.zone/sha1/1.0.0.tar.gz", "sha1 url")
T.eq(tbl.sha1.tarball_hash, "sha256:a3f1c2b4",                        "sha1 tarball_hash")
T.eq(tbl.sha1.tree_hash,    "sha256:d9e4f1a2",                        "sha1 tree_hash")
T.eq(tbl.sha1.include,      "**",                                      "sha1 include")

T.eq(tbl.lunajson.version,      "1.3.0",                                     "lunajson version")
T.eq(tbl.lunajson.url,          "https://pkg.rhi.zone/lunajson/1.3.0.tar.gz","lunajson url")
T.eq(tbl.lunajson.tarball_hash, "sha256:b7c2d3e4",                           "lunajson tarball_hash")
T.eq(tbl.lunajson.tree_hash,    "sha256:c1a8e5f3",                           "lunajson tree_hash")
T.eq(tbl.lunajson.include,      "v2/**",                                      "lunajson include (selective)")

-- ── parse: v1 format migration (checksum → tarball_hash) ───────────────────

local v1_tbl, v1_err = lock.parse(SIMPLE_V1)
T.ok(v1_tbl, "parse v1 returns table")
T.ok(not v1_err, "parse v1 returns no error")

-- 'checksum' is transparently aliased to 'tarball_hash'
T.eq(v1_tbl.sha1.tarball_hash, "sha256:a3f1c2b4", "v1 checksum maps to tarball_hash (sha1)")
T.eq(v1_tbl.lunajson.tarball_hash, "sha256:b7c2d3e4", "v1 checksum maps to tarball_hash (lunajson)")

-- tree_hash defaults to nil when absent
T.eq(v1_tbl.sha1.tree_hash, nil, "v1: tree_hash defaults to nil")
T.eq(v1_tbl.lunajson.tree_hash, nil, "v1: tree_hash defaults to nil (lunajson)")

-- include defaults to "**" when absent
T.eq(v1_tbl.sha1.include, "**", "v1: include defaults to **")
T.eq(v1_tbl.lunajson.include, "**", "v1: include defaults to ** (lunajson)")

-- 'checksum' is not stored as a key (it was aliased away)
T.eq(v1_tbl.sha1.checksum, nil, "v1: checksum key is not present after migration")

-- ── parse: lockfile with missing optional fields ────────────────────────────

local partial = [[
[mypkg]
version      = "2.0.0"
url          = "https://example.com/mypkg.tar.gz"
tarball_hash = "sha256:deadbeef"
]]

local pt, pe = lock.parse(partial)
T.ok(pt, "parse partial returns table")
T.eq(pt.mypkg.tree_hash, nil,  "missing tree_hash defaults to nil")
T.eq(pt.mypkg.include,   "**", "missing include defaults to **")

-- ── parse: comments and blank lines are ignored ────────────────────────────

local with_comments = [[
# top-level comment

# another comment

[mypkg]
version      = "2.0.0"
url          = "https://example.com/mypkg.tar.gz"
tarball_hash = "sha256:deadbeef"

# inline section comment

[otherpkg]
version      = "0.1.0"
url          = "https://example.com/other.tar.gz"
tarball_hash = "sha256:cafef00d"
]]

local t2 = lock.parse(with_comments)
T.ok(t2, "parse with comments")
T.eq(t2.mypkg.version, "2.0.0",    "mypkg version with comments")
T.eq(t2.otherpkg.version, "0.1.0", "otherpkg version with comments")

-- ── serialize: canonical output ────────────────────────────────────────────

local canonical = lock.serialize({
	sha1 = {
		version      = "1.0.0",
		url          = "https://pkg.rhi.zone/sha1/1.0.0.tar.gz",
		tarball_hash = "sha256:a3f1c2b4",
		tree_hash    = "sha256:d9e4f1a2",
		include      = "**",
	},
	lunajson = {
		version      = "1.3.0",
		url          = "https://pkg.rhi.zone/lunajson/1.3.0.tar.gz",
		tarball_hash = "sha256:b7c2d3e4",
		tree_hash    = "sha256:c1a8e5f3",
		include      = "v2/**",
	},
})

-- must start with header comment
T.eq(canonical:sub(1, 15), "# crescent.lock", "header comment")

-- lunajson sorts before sha1 alphabetically
local pos_l = canonical:find("%[lunajson%]")
local pos_s = canonical:find("%[sha1%]")
T.ok(pos_l < pos_s, "lunajson before sha1 in serialized output")

-- new fields appear in serialized output
T.ok(canonical:find('tarball_hash'), "tarball_hash in output")
T.ok(canonical:find('tree_hash'), "tree_hash in output")
T.ok(canonical:find('include'), "include in output")

-- ── serialize: include always written (defaults to "**") ───────────────────

local no_include_ser = lock.serialize({
	pkg = {
		version      = "1.0.0",
		url          = "https://example.com/pkg.tar.gz",
		tarball_hash = "sha256:abc",
	},
})
T.ok(no_include_ser:find('include%s*=%s*"[*][*]"'), "include defaults to ** in output")

-- ── round-trip ─────────────────────────────────────────────────────────────

local input_tbl = {
	zlib = {
		version      = "1.2.11",
		url          = "https://pkg.rhi.zone/zlib/1.2.11.tar.gz",
		tarball_hash = "sha256:c3e5e9fdd5004dcb542feda5ee4f0ff0744628baf8ed2dd5d66f8ca1197cb1a1",
		tree_hash    = "sha256:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
		include      = "**",
	},
	argon2 = {
		version      = "20190702",
		url          = "https://pkg.rhi.zone/argon2/20190702.tar.gz",
		tarball_hash = "sha256:daf660e6ead6a4f8a7b2f42b9a38fc02ec0ef60e06ff99bdd86f4e63a3e8b09a",
		tree_hash    = "sha256:1122334455667788990011223344556677889900112233445566778899001122",
		include      = "v1/**",
	},
}

local serialized  = lock.serialize(input_tbl)
local parsed_back = lock.parse(serialized)
T.ok(parsed_back, "round-trip parse succeeds")
local serialized2 = lock.serialize(parsed_back)
T.eq(serialized, serialized2, "round-trip serialize is idempotent")

-- field values survive the round-trip
T.eq(parsed_back.zlib.version,      input_tbl.zlib.version,      "zlib version round-trip")
T.eq(parsed_back.zlib.tarball_hash, input_tbl.zlib.tarball_hash, "zlib tarball_hash round-trip")
T.eq(parsed_back.zlib.tree_hash,    input_tbl.zlib.tree_hash,    "zlib tree_hash round-trip")
T.eq(parsed_back.zlib.include,      input_tbl.zlib.include,      "zlib include round-trip")
T.eq(parsed_back.argon2.tarball_hash, input_tbl.argon2.tarball_hash, "argon2 tarball_hash round-trip")
T.eq(parsed_back.argon2.include,    input_tbl.argon2.include,    "argon2 include round-trip")

-- ── error cases ────────────────────────────────────────────────────────────

-- bad section header
local r1, e1 = lock.parse("[bad name with spaces]")
T.ok(not r1, "rejects bad section header")
T.ok(e1 and e1:find("invalid section header"), "error message mentions invalid section header")

-- key-value before section
local r2, e2 = lock.parse('version = "1.0.0"')
T.ok(not r2, "rejects kv before section")
T.ok(e2 and e2:find("before any section header"), "error message mentions before any section header")

-- malformed value (no quotes)
local r3, e3 = lock.parse("[pkg]\nversion = 1.0.0")
T.ok(not r3, "rejects unquoted value")
T.ok(e3 and e3:find("malformed"), "error message mentions malformed")

-- unknown key
local r4, e4 = lock.parse('[pkg]\nfoo = "bar"')
T.ok(not r4, "rejects unknown key")
T.ok(e4 and e4:find("unknown key"), "error message mentions unknown key")

-- duplicate section
local r5, e5 = lock.parse('[pkg]\nversion = "1"\n[pkg]\nversion = "2"')
T.ok(not r5, "rejects duplicate section")
T.ok(e5 and e5:find("duplicate"), "error message mentions duplicate")

-- duplicate key within section
local r6, e6 = lock.parse('[pkg]\nversion = "1"\nversion = "2"')
T.ok(not r6, "rejects duplicate key")
T.ok(e6 and e6:find("duplicate"), "error message mentions duplicate key")

-- unexpected line (no =, not a header, not blank, not comment)
local r7, e7 = lock.parse("[pkg]\nthis is garbage")
T.ok(not r7, "rejects unexpected line")
T.ok(e7 and e7:find("unexpected"), "error message mentions unexpected")

-- duplicate checksum + tarball_hash (same storage slot)
local r8, e8 = lock.parse('[pkg]\nversion = "1"\nchecksum = "sha256:aaa"\ntarball_hash = "sha256:bbb"')
T.ok(not r8, "rejects both checksum and tarball_hash in same section")
T.ok(e8 and e8:find("duplicate"), "error message mentions duplicate for checksum+tarball_hash conflict")

-- ── load/write round-trip via temp file ────────────────────────────────────

local tmpfile = os.tmpname()
local ok_write, werr = lock.write(tmpfile, input_tbl)
T.ok(ok_write, "write returns true")
T.ok(not werr,  "write returns no error")

local loaded, lerr = lock.load(tmpfile)
T.ok(loaded,    "load returns table")
T.ok(not lerr,  "load returns no error")
T.eq(loaded.zlib.version,      "1.2.11",    "loaded zlib version")
T.eq(loaded.argon2.version,    "20190702",  "loaded argon2 version")
T.eq(loaded.zlib.tarball_hash, input_tbl.zlib.tarball_hash, "loaded zlib tarball_hash")
T.eq(loaded.zlib.tree_hash,    input_tbl.zlib.tree_hash,    "loaded zlib tree_hash")
T.eq(loaded.zlib.include,      "**",        "loaded zlib include")

-- cleanup
os.remove(tmpfile)

-- load from missing file
local r9, e9 = lock.load("/nonexistent/path/crescent.lock")
T.ok(not r9, "load nonexistent returns nil")
T.ok(e9,     "load nonexistent returns error string")
