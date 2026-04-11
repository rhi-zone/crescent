if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- extension (lowercase, no dot) -> mime type
--: { [string]: string }
local ext_to_type = {
	-- text
	html = "text/html",
	htm = "text/html",
	css = "text/css",
	js = "text/javascript",
	mjs = "text/javascript",
	json = "application/json",
	xml = "text/xml",
	csv = "text/csv",
	tsv = "text/tab-separated-values",
	txt = "text/plain",
	text = "text/plain",
	md = "text/markdown",
	markdown = "text/markdown",
	yaml = "text/yaml",
	yml = "text/yaml",
	rtf = "text/rtf",
	ics = "text/calendar",
	vcf = "text/vcard",
	vtt = "text/vtt",

	-- image
	jpg = "image/jpeg",
	jpeg = "image/jpeg",
	png = "image/png",
	gif = "image/gif",
	svg = "image/svg+xml",
	webp = "image/webp",
	ico = "image/x-icon",
	bmp = "image/bmp",
	tif = "image/tiff",
	tiff = "image/tiff",
	avif = "image/avif",
	heic = "image/heic",
	heif = "image/heif",
	jxl = "image/jxl",
	apng = "image/apng",

	-- audio
	mp3 = "audio/mpeg",
	wav = "audio/wav",
	ogg = "audio/ogg",
	oga = "audio/ogg",
	flac = "audio/flac",
	aac = "audio/aac",
	m4a = "audio/mp4",
	weba = "audio/webm",
	opus = "audio/opus",
	mid = "audio/midi",
	midi = "audio/midi",
	aiff = "audio/aiff",

	-- video
	mp4 = "video/mp4",
	m4v = "video/mp4",
	webm = "video/webm",
	avi = "video/x-msvideo",
	mkv = "video/x-matroska",
	mov = "video/quicktime",
	wmv = "video/x-ms-wmv",
	flv = "video/x-flv",
	mpg = "video/mpeg",
	mpeg = "video/mpeg",
	ogv = "video/ogg",
	ts = "video/mp2t",
	["3gp"] = "video/3gpp",

	-- application
	pdf = "application/pdf",
	zip = "application/zip",
	gz = "application/gzip",
	gzip = "application/gzip",
	tar = "application/x-tar",
	bz2 = "application/x-bzip2",
	["7z"] = "application/x-7z-compressed",
	rar = "application/vnd.rar",
	xz = "application/x-xz",
	zst = "application/zstd",
	br = "application/x-brotli",
	wasm = "application/wasm",
	bin = "application/octet-stream",
	exe = "application/octet-stream",
	dll = "application/octet-stream",
	so = "application/octet-stream",
	dylib = "application/octet-stream",
	dmg = "application/x-apple-diskimage",
	iso = "application/x-iso9660-image",
	deb = "application/x-debian-package",
	rpm = "application/x-rpm",
	protobuf = "application/protobuf",
	msgpack = "application/msgpack",
	cbor = "application/cbor",
	sqlite = "application/x-sqlite3",
	db = "application/x-sqlite3",

	-- documents
	doc = "application/msword",
	docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	xls = "application/vnd.ms-excel",
	xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	ppt = "application/vnd.ms-powerpoint",
	pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
	odt = "application/vnd.oasis.opendocument.text",
	ods = "application/vnd.oasis.opendocument.spreadsheet",
	odp = "application/vnd.oasis.opendocument.presentation",
	epub = "application/epub+zip",

	-- web / data
	atom = "application/atom+xml",
	rss = "application/rss+xml",
	jsonld = "application/ld+json",
	geojson = "application/geo+json",
	map = "application/json",
	webmanifest = "application/manifest+json",

	-- font
	woff = "font/woff",
	woff2 = "font/woff2",
	ttf = "font/ttf",
	otf = "font/otf",
	eot = "application/vnd.ms-fontobject",

	-- code / config
	lua = "text/x-lua",
	py = "text/x-python",
	rb = "text/x-ruby",
	rs = "text/x-rust",
	go = "text/x-go",
	java = "text/x-java-source",
	c = "text/x-c",
	h = "text/x-c",
	cpp = "text/x-c++src",
	hpp = "text/x-c++hdr",
	sh = "application/x-sh",
	bat = "application/x-msdos-program",
	ps1 = "application/x-powershell",
	toml = "application/toml",
	ini = "text/plain",
	cfg = "text/plain",
	conf = "text/plain",
	log = "text/plain",

	-- misc
	sql = "application/sql",
	graphql = "application/graphql",
	svgz = "image/svg+xml",
}

-- mime type -> preferred extension (first registered wins)
--: { [string]: string }
local type_to_ext = {}
-- preferred extensions for reverse lookup (overrides for common types)
--: { [string]: string }
local preferred_ext = {
	["text/html"] = "html",
	["text/javascript"] = "js",
	["image/jpeg"] = "jpg",
	["image/tiff"] = "tiff",
	["image/svg+xml"] = "svg",
	["audio/mpeg"] = "mp3",
	["audio/ogg"] = "ogg",
	["audio/midi"] = "mid",
	["video/mp4"] = "mp4",
	["video/mpeg"] = "mpg",
	["video/ogg"] = "ogv",
	["application/gzip"] = "gz",
	["application/octet-stream"] = "bin",
	["text/yaml"] = "yaml",
	["text/markdown"] = "md",
	["text/plain"] = "txt",
	["audio/mp4"] = "m4a",
	["application/x-sqlite3"] = "sqlite",
	["application/json"] = "json",
}

for ext, mime_type in pairs(ext_to_type) do
	if not type_to_ext[mime_type] then
		type_to_ext[mime_type] = ext
	end
end
-- apply preferred overrides
for mime_type, ext in pairs(preferred_ext) do
	type_to_ext[mime_type] = ext
end

-- text types get a charset
--: { [string]: string }
local type_charset = {
	["text/html"] = "UTF-8",
	["text/css"] = "UTF-8",
	["text/javascript"] = "UTF-8",
	["text/xml"] = "UTF-8",
	["text/csv"] = "UTF-8",
	["text/plain"] = "UTF-8",
	["text/markdown"] = "UTF-8",
	["text/yaml"] = "UTF-8",
	["text/rtf"] = "UTF-8",
	["text/calendar"] = "UTF-8",
	["text/vcard"] = "UTF-8",
	["text/vtt"] = "UTF-8",
	["text/tab-separated-values"] = "UTF-8",
	["application/json"] = "UTF-8",
	["application/xml"] = "UTF-8",
	["application/javascript"] = "UTF-8",
	["application/ld+json"] = "UTF-8",
	["application/geo+json"] = "UTF-8",
	["application/manifest+json"] = "UTF-8",
	["application/sql"] = "UTF-8",
	["application/graphql"] = "UTF-8",
	["application/atom+xml"] = "UTF-8",
	["application/rss+xml"] = "UTF-8",
	["image/svg+xml"] = "UTF-8",
}

--- Extract extension from a filename or bare extension.
--- Handles compound extensions like .tar.gz.
--: (path: string) -> string | nil
local function extract_ext(path)
	-- compound extensions: check longest match first
	local compound = path:match("%.tar%.(%w+)$")
	if compound then return "tar." .. compound end
	-- strip leading dot for bare extensions like ".png"
	local ext = path:match("%.([^%./ \\]+)$")
	if ext then return ext:lower() end
	-- bare extension with no dot (e.g. "png")
	if not path:find("[%./ \\]") then return path:lower() end
	return nil
end

-- compound extension map (only those that differ from the inner extension)
--: { [string]: string }
local compound_types = {
	["tar.gz"] = "application/gzip",
	["tar.bz2"] = "application/x-bzip2",
	["tar.xz"] = "application/x-xz",
	["tar.zst"] = "application/zstd",
}

--- Look up the MIME type for a file path or extension.
--- Returns nil for unknown extensions.
--: (path: string) -> string | nil
function M.lookup(path)
	local ext = extract_ext(path)
	if not ext then return nil end
	return compound_types[ext] or ext_to_type[ext]
end

--- Look up the preferred file extension for a MIME type.
--- Returns nil for unknown types.
--: (mime_type: string) -> string | nil
function M.extension(mime_type)
	return type_to_ext[mime_type:lower()]
end

--- Return the default charset for a MIME type, or nil.
--: (mime_type: string) -> string | nil
function M.charset(mime_type)
	return type_charset[mime_type:lower()]
end

--- Return true if the MIME type is a text type.
--: (mime_type: string) -> boolean
function M.is_text(mime_type)
	local t = mime_type:lower()
	if t:sub(1, 5) == "text/" then return true end
	if type_charset[t] then return true end
	return false
end

--- Return true if the MIME type is a binary type (not text).
--: (mime_type: string) -> boolean
function M.is_binary(mime_type)
	return not M.is_text(mime_type)
end

--- Return a full Content-Type header value for a file path or extension.
--- Appends charset for text types. Returns nil for unknown extensions.
--: (path: string) -> string | nil
function M.content_type(path)
	local mime_type = M.lookup(path)
	if not mime_type then return nil end
	local cs = type_charset[mime_type]
	if cs then
		return mime_type .. "; charset=" .. cs:lower()
	end
	return mime_type
end

--- The raw extension-to-type table, for direct access.
--: { [string]: string }
M.types = ext_to_type

--- The raw type-to-extension table, for direct access.
--: { [string]: string }
M.extensions = type_to_ext

return M
