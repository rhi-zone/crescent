-- RFC 1035 §4 — Message format

local mod = {}

local empty_table = {}

local lshift = bit.lshift; local rshift = bit.rshift; local band = bit.band
local bor = bit.bor; local char = string.char; local byte = string.byte
local sub = string.sub; local concat = table.concat

-- Helper: read N bytes from s at position i, returning integers (0 if out of bounds)
--: (string, integer) -> (integer, integer)
local function read2(s, i)
	local b1, b2 = byte(s, i, i+1)
	return b1 or 0, b2 or 0
end
--: (string, integer) -> (integer, integer, integer, integer)
local function read4(s, i)
	local b1, b2, b3, b4 = byte(s, i, i+3)
	return b1 or 0, b2 or 0, b3 or 0, b4 or 0
end

-- LINT: disallow duplicate values

-- RFC 1035 §3.2.2 — TYPE values
--[[@enum dns_type]]
mod.type = {
	A = 1, --[[a host address - see RFC1035]]
	NS = 2, --[[an authoritative name server - see RFC1035]]
	MD = 3, --[[@deprecated use MX]] --[[a mail destination - see RFC883, obsoleted by RFC973]]
	MF = 4, --[[@deprecated use MX]] --[[a mail forwarder - see RFC883, obsoleted by RFC973]]
	CNAME = 5, --[[the canonical name for an alias - see RFC1035]]
	SOA = 6, --[[marks the start of a zone of authority - see RFC1035]]
	MB = 7, --[[@deprecated perpetually experimental]] --[[a mailbox domain name (EXPERIMENTAL) - see RFC883]]
	MG = 8, --[[@deprecated perpetually experimental]] --[[a mail group member (EXPERIMENTAL) - see RFC883]]
	MR = 9, --[[@deprecated perpetually experimental]] --[[a mail rename domain name (EXPERIMENTAL) - see RFC883]]
	NULL = 10, --[[@deprecated]] --[[a null RR - see RFC883, obsoleted by RFC1035]]
	WKS = 11, --[[@deprecated not to be relied upon]] --[[a well known service description - see RFC883, obsoleted by RFC1123, RFC1127]]
	PTR = 12, --[[a domain name pointer - see RFC1035]]
	HINFO = 13, --[[host information - used by cloudflare in response to TXT since it is plaintext - see RFC883, unobsoleted by RFC8482]]
	MINFO = 14, --[[@deprecated perpetually experimental?]] --[[mailbox or mail list information - see RFC883]]
	MX = 15, --[[mail exchange - see RFC1035]]
	TXT = 16, --[[text strings - see RFC1035]]
	-- https://en.wikipedia.org/wiki/List_of_DNS_record_types#Resource_records

	RP = 17, --[[@deprecated]] --[[responsible person for the domain - see RFC1183]]
	AFSDB = 18, --[[AFS database record - see RFC1183]]
	X25 = 19, --[[@deprecated]] --[[see RFC1183]]
	ISDN = 20, --[[@deprecated]] --[[see RFC1183]]
	RT = 21, --[[@deprecated]] --[[see RFC1183]]
	NSAP = 22, --[[@deprecated]] --[[see RFC1183]]
	["NSAP-PTR"] = 23, --[[@deprecated]] --[[see RFC1183]]
	SIG = 24, --[[@deprecated]] --[[signature - see RFC2065, RFC2930, RCE2931, obsoleted by RFC3755]]
	KEY = 25, --[[@deprecated]] --[[key - see RFC2065, RFC2930, RCE2931, obsoleted by RFC3445, RFC3755, RFC4025]]
	PX = 26, --[[@deprecated is not used]] --[[see RFC2163]]
	GPOS = 27, --[[@deprecated superseded by LOC]] --[[see RFC1712]]
	AAAA = 28, --[[an IPv6 host address - see RFC3596]]
	LOC = 29, --[[geographical location - see RFC1876]]
	NXT = 30, --[[@deprecated]] --[[see RFC2065, obsoleted by RFC3755]]
	EID = 31, --[[@deprecated never became RFC]] --[[Nimrod DNS - see https://datatracker.ietf.org/doc/html/draft-ietf-nimrod-dns-00]]
	NIMLOC = 32, --[[@deprecated never became RFC]] --[[Nimrod DNS - see https://datatracker.ietf.org/doc/html/draft-ietf-nimrod-dns-00]]
	SRV = 33, --[[general services - see RFC2782]]
	ATMA = 34, --[[@deprecated]] --[[]]
	NAPTR = 35, --[[naming authority pointer - see RFC3403]]
	KX = 36, --[[key exchanger - see RFC2230]]
	CERT = 37, --[[certificate (PKIX, SPXI, PGP etc.) - see RFC4398]]
	A6 = 38, --[[@deprecated historic]] --[[part of early IPv6 - see RFC2874, obsoleted by RFC6563]]
	DNAME = 39, --[[delegation name - see RFC6672]]
	SINK = 40, --[[@deprecated never became RFC]] --[[kitchen sink for structured data - see https://datatracker.ietf.org/doc/html/draft-eastlake-kitchen-sink]]
	OPT = 41, --[[option - pseudo-record used in EDNS - see RFC6891]]
	APL = 42, --[[@deprecated experimental]] --[[address prefix list - see RFC3123]]
	DS = 43, --[[delegation signer - see RFC4034]]
	SSHFP = 44, --[[ssh public key fingerprint - see RFC4255]]
	IPSECKEY = 45, --[[IPsec key - see RFC4025]]
	RRSIG = 46, --[[DNSSEC signature - see RFC4034]]
	NSEC = 47, --[[Next Secure - see RFC4034]]
	DNSKEY = 48, --[[DNS key - see RFC4034]]
	DHCID = 49, --[[DHCP identifier - see RFC4701]]
	NSEC3 = 50, --[[Next Secure version 3 - see RFC5155]]
	NSEC3PARAM = 51, --[[NSEC3 parameters - see RFC5155]]
	TLSA = 52, --[[TLSA certificate association - see RFC6698]]
	SMIMEA = 53, --[[S/MIME certificate association - see RFC8162]]
	HIP = 55, --[[Host Identity Protocol - see RFC8005]]
	NINFO = 56, --[[@deprecated expired without adoption]] --[[zone status information - see https://datatracker.ietf.org/doc/draft-reid-dnsext-zs/]]
	RKEY = 57, --[[@deprecated expired without adoption]] --[[see https://datatracker.ietf.org/doc/draft-reid-dnsext-rkey/]]
	TALINK = 58, --[[@deprecated never became RFC]] --[[see https://datatracker.ietf.org/doc/html/draft-wijngaards-dnsop-trust-history-02]]
	CDS = 59, --[[child DS - see RFC7344]]
	CDNSKEY = 60, --[[child DNSKEY - see RFC7344]]
	OPENPGPKEY = 61, --[[OpenPGP public key - see RFC7929]]
	CSYNC = 62, --[[child-to-parent synchronization - see RFC7477]]
	ZONEMD = 63, --[[cryptographic message digests for DNS zones - see RFC8976]]
	SVCB = 64, --[[service binding - see https://datatracker.ietf.org/doc/draft-ietf-dnsop-svcb-https/00/]]
	HTTPS = 65, --[[HTTPS binding - see https://datatracker.ietf.org/doc/draft-ietf-dnsop-svcb-https/00/]]
	SPF = 99, --[[@deprecated lack of support]] --[[Sender Policy Framework - see RFC4408, obsoleted in RFC7208]]
	UINFO = 100, --[[@deprecated IANA reserved]]
	UID = 101, --[[@deprecated IANA reserved]]
	GID = 102, --[[@deprecated IANA reserved]]
	UNSPEC = 103, --[[@deprecated IANA reserved]]
	NID = 104, --[[@deprecated not in use]]
	L32 = 105, --[[@deprecated not in use]]
	L64 = 106, --[[@deprecated not in use]]
	LP = 107, --[[@deprecated not in use]]
	EUI48 = 108, --[[EUI-48 MAC address - see RFC7043]]
	EUI64 = 109, --[[EUI-64 MAC address - see RFC7043]]
	TKEY = 249, --[[Transaction Key - see RFC2930]]
	TSIG = 250, --[[Transaction Signature - see RFC2845]]
	IXFR = 251, --[[Questions only. A request for a transfer of an entire zone]]
	AXFR = 252, --[[Questions only. A request for a transfer of an entire zone - see RFC1035]]
	MAILB = 253, --[[@deprecated perpetually experimental?]] --[[Questions only. A request for mailbox-related records (`MB`, `MG` or `MR`) - see RFC883]]
	MAILA = 254, --[[@deprecated see MX]] --[[Questions only. A request for mail agent RRs - see RFC883]]
	["*"] = 255, --[[Questions only. A request for all records - see RFC1035]]
	URI = 256, --[[Uniform Resource Identifier - see RFC7553]]
	CAA = 257, --[[Certification Authority Authorization - see RFC6844]]
	DOA = 259, --[[@deprecated never became RFC]] --[[Digital Object Architecture - see https://datatracker.ietf.org/doc/html/draft-durand-doa-over-dns-03]]
	TA = 32768, --[[DNSSEC Trust Authorities]]
	DLV = 32769, --[[DNSSEC Lookaside Validation - see RFC4431, RFC5074]]
}
if false --[[ignore_deprecated]] then
	for _, k in ipairs({
		"MD", "MF", "MB", "MG", "MR", "NULL", "WKS", --[[HINFO unobsoleted]] "MINFO", "RP", "X25", "ISDN", "RT", "NSAP", "NSAP-PTR",
		"SIG", "KEY", "PX", "GPOS", "NXT", "EID", "NIMLOC", "ATMA", "A6", "SINK", "APL", "NINFO", "RKEY",
		"TALINK", "SPF", "UINFO", "UID", "GID", "UNSPEC", "NID", "L32", "L64", "LP", "DOA"
	}) do mod.type[k] = nil end
end
mod.type_name = {}
for k, v in pairs(mod.type) do mod.type_name[v] = k end

-- RFC 1035 §4.1.4 — Name compression
-- RFC 1035 §3.1 — Label format
--: (string, integer | nil) -> ({ [integer]: string }, integer)
mod.string_to_domain_name = function (s, i)
	i = i or 1
	local length = byte(s, i) or 0 --: integer
	local parts = {} --: { [integer]: string }
	while length > 0 and length <= 0x3f do
		parts[#parts+1] = sub(s, i + 1, i + length)
		i = i + length + 1
		length = byte(s, i) or 0
	end
	i = i + (length > 0x3f and 2 or 1)
	local l = i - 2
	while length > 0x3f do -- pointer
		l = bor(lshift(band(length, 0x3f), 8), byte(s, l + 1) or 0) + 1
		length = byte(s, l) or 0
		while length > 0 and length <= 0x3f do
			local lbl = sub(s, l + 1, l + length)
			parts[#parts+1] = lbl
			l = l + length + 1
			length = byte(s, l) or 0
		end
	end
	parts[#parts+1] = ""
	return parts, i
end

-- RFC 1035 §3.1 — Encode domain name to wire format
mod.domain_name_to_string = function(parts)
	local out = {}
	for _, part in ipairs(parts) do
		assert(#part <= 0x3f, "domain_name_to_string: label too long")
		out[#out + 1] = char(#part) .. part
	end
	return concat(out)
end

mod.decoders = {
	-- RFC 1035 §3.3.1
	[mod.type.CNAME] = mod.string_to_domain_name,
	-- RFC 1035 §3.3.2
	--: (string, integer | nil) -> ({ cpu: string, os: string }, integer)
	[mod.type.HINFO] = function (s, i)
		i = i or 1
		local length = byte(s, i) or 0 --: integer
		local cpu = sub(s, i + 1, i + length)
		i = i + length + 1
		length = byte(s, i) or 0
		local os_str = sub(s, i + 1, i + length)
		i = i + length + 1
		return { cpu = cpu, os = os_str }, i
	end,
	-- RFC 1035 §3.3.3 --[[@diagnostic disable-next-line: deprecated]]
	[mod.type.MB] = mod.string_to_domain_name,
	-- RFC 1035 §3.3.4 --[[@diagnostic disable-next-line: deprecated]]
	[mod.type.MD] = mod.string_to_domain_name,
	-- RFC 1035 §3.3.5 --[[@diagnostic disable-next-line: deprecated]]
	[mod.type.MF] = mod.string_to_domain_name,
	-- RFC 1035 §3.3.6 --[[@diagnostic disable-next-line: deprecated]]
	[mod.type.MG] = mod.string_to_domain_name,
	-- RFC 1035 §3.3.7 --[[@diagnostic disable-next-line: deprecated]]
	[mod.type.MINFO] = function (s, i)
		local rmailbx, emailbx
		rmailbx, i = mod.string_to_domain_name(s, i)
		emailbx, i = mod.string_to_domain_name(s, i)
		return { rmailbx = rmailbx, emailbx = emailbx }, i
	end,
	-- RFC 1035 §3.3.8 --[[@diagnostic disable-next-line: deprecated]]
	[mod.type.MR] = mod.string_to_domain_name,
	-- RFC 1035 §3.3.9
	[mod.type.MX] = function (s, i)
		s = s --[[:! string]]
		i = i or 1
		local b1, b2 = read2(s, i)
		local preference = bor(lshift(b1, 8), b2)
		local exchange
		exchange, i = mod.string_to_domain_name(s, i + 2)
		return { preference = preference, exchange = exchange }, i
	end,
	-- RFC 1035 §3.3.10 --[[@diagnostic disable-next-line: deprecated]]
	[mod.type.NULL] = function (s, i, length) i = i or 1; return s:sub(i, i + length - 1), i + length end,
	-- RFC 1035 §3.3.11 — s must be the full string for ns to return the correct values
	[mod.type.NS] = mod.string_to_domain_name,
	-- RFC 1035 §3.3.12
	[mod.type.PTR] = mod.string_to_domain_name,
	-- RFC 1035 §3.3.13
	[mod.type.SOA] = function (s, i)
		s = s --[[:! string]]
		i = i or 1
		local mname, rname
		mname, i = mod.string_to_domain_name(s, i)
		rname, i = mod.string_to_domain_name(s, i)
		local b1, b2, b3, b4 = read4(s, i)
		local serial = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		b1, b2, b3, b4 = read4(s, i + 4)
		local refresh = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		b1, b2, b3, b4 = read4(s, i + 8)
		local retry = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		b1, b2, b3, b4 = read4(s, i + 12)
		local expire = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		b1, b2, b3, b4 = read4(s, i + 16)
		local minimum = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		return { mname = mname, rname = rname, serial = serial, refresh = refresh, retry = retry, expire = expire, minimum = minimum }, i + 20
	end,
	-- RFC 1035 §3.3.14
	[mod.type.TXT] = function (s, i, length)
		s = s --[[:! string]]
		i = (i or 1) --[[:! integer]]
		local end_ = i + (length --[[:! integer]]) - 1
		local ret = {}
		while i <= end_ do
			local length2 = byte(s, i) or 0
			local txt = sub(s, i + 1, i + length2)
			ret[#ret+1] = txt
			i = i + length2 + 1
		end
		return ret, i
	end,
	-- RFC 1035 §3.4.1
	[mod.type.A] = function (s, i)
		s = s --[[:! string]]; i = (i or 1) --[[:! integer]]
		return { byte(s, i, i + 3) }, i + 4
	end,
	-- RFC 1035 §3.4.2 --[[@diagnostic disable-next-line: deprecated]]
	[mod.type.WKS] = function (s, i, length)
		s = s --[[:! string]]; i = (i or 1) --[[:! integer]]
		return { address = { byte(s, i, i + 3) }, protocol = byte(s, i + 4) or 0, bitmap = sub(s, i + 5, i + (length --[[:! integer]]) - 1) }, i + (length --[[:! integer]])
	end,
	-- RFC 3596 §2.2 — AAAA RDATA
	[mod.type.AAAA] = function (s, i)
		s = s --[[:! string]]; i = (i or 1) --[[:! integer]]
		return { byte(s, i, i + 15) }, i + 16
	end,
	-- RFC 4034 §5
	[mod.type.DS] = function (s, i, length)
		s = s --[[:! string]]
		i = i or 1
		local b1, b2 = read2(s, i)
		local key_tag = bor(lshift(b1, 8), b2)
		local algorithm = byte(s, i + 2) or 0
		local digest_type = byte(s, i + 3) or 0
		local digest = sub(s, i + 4, i + (length --[[:! integer]]) - 1)
		return { key_tag = key_tag, algorithm = algorithm, digest_type = digest_type, digest = digest }, i + (length --[[:! integer]])
	end,
	-- RFC 4034 §3
	[mod.type.RRSIG] = function (s, i, length)
		s = s --[[:! string]]
		i = i or 1
		local end_ = i + (length --[[:! integer]])
		local b1, b2 = read2(s, i)
		local type_covered = bor(lshift(b1, 8), b2)
		local algorithm = byte(s, i + 2) or 0
		local labels = byte(s, i + 3) or 0
		local b3, b4
		b1, b2, b3, b4 = read4(s, i + 4)
		local original_ttl = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		b1, b2, b3, b4 = read4(s, i + 8)
		local signature_expiration = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		b1, b2, b3, b4 = read4(s, i + 12)
		local signature_inception = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		b1, b2 = read2(s, i + 16)
		local key_tag = bor(lshift(b1, 8), b2)
		local signers_name
		signers_name, i = mod.string_to_domain_name(s, i + 18)
		local signature = sub(s, i, end_ - 1)
		return {
			type_covered = type_covered, algorithm = algorithm, labels = labels, original_ttl = original_ttl,
			signature_expiration = signature_expiration, signature_inception = signature_inception, key_tag = key_tag,
			signers_name = signers_name, signature = signature,
		}, end_
	end,
	-- RFC 4034 §4
	[mod.type.NSEC] = function (s, i, length)
		s = s --[[:! string]]
		i = (i or 1) --[[:! integer]]
		local end_ = i + (length --[[:! integer]])
		local next_domain_name
		next_domain_name, i = mod.string_to_domain_name(s, i)
		local types = {}
		while i < end_ do
			local upper_bits = lshift(byte(s, i) or 0, 8)
			local length2 = byte(s, i + 1) or 0
			if length2 == 0 then break end
			i = i + 2
			for j = 0, length2 - 1 do
				local type_start = bor(upper_bits, lshift(j, 3))
				local n = byte(s, i + j) or 0
				if n ~= 0 then
					if band(n, 0x80) ~= 0 then types[#types+1] = type_start + 0 end
					if band(n, 0x40) ~= 0 then types[#types+1] = type_start + 1 end
					if band(n, 0x20) ~= 0 then types[#types+1] = type_start + 2 end
					if band(n, 0x10) ~= 0 then types[#types+1] = type_start + 3 end
					if band(n, 0x08) ~= 0 then types[#types+1] = type_start + 4 end
					if band(n, 0x04) ~= 0 then types[#types+1] = type_start + 5 end
					if band(n, 0x02) ~= 0 then types[#types+1] = type_start + 6 end
					if band(n, 0x01) ~= 0 then types[#types+1] = type_start + 7 end
				end
			end
			i = i + length2
		end
		return { next_domain_name = next_domain_name, types = types }, end_
	end,
	-- RFC 4034 §2
	[mod.type.DNSKEY] = function (s, i, length)
		s = s --[[:! string]]
		i = i or 1
		local b1, b2 = read2(s, i)
		local flags = bor(lshift(b1, 8), b2)
		return {
			is_zone_key = band(flags, 0x0100) ~= 0, is_secure_entry_point = band(flags, 0x0001) ~= 0,
			protocol = byte(s, i + 2) or 0,
			algorithm = byte(s, i + 3) or 0,
			public_key = sub(s, i + 4, i + (length --[[:! integer]]) - 1),
		}, i + (length --[[:! integer]])
	end,
}

-- RFC 4034 §2–5 (appendix A.1)
--[[@enum dnssec_algorithm]]
mod.dnssec_algorithm = {
	RSAMD5 = 1, --[[RSA/MD5. NOT RECOMMENDED. - see RFC2537]]
	DH = 2, --[[Diffie-Hellman - see RFC2539]]
	DSA = 3, --[[DSA/SHA-1. OPTIONAL. - see RFC2536]]
	ECC = 4, --[[Elliptic Curve]]
	RSASHA1 = 5, --[[RSA/SHA-1. MANDATORY. - see RFC3110]]
	INDIRECT = 252,
	PRIVATEDNS = 253, --[[algorithm depends on domain name. OPTIONAL.]]
	PRIVATEOID = 254, --[[length byte + BER encoded ISO OID + algorithm data. OPTIONAL.]]
}
mod.dnssec_algorithm_name = {}
for k, v in pairs(mod.dnssec_algorithm) do mod.dnssec_algorithm_name[v] = k end

-- RFC 4034 §2–5 (appendix A.2)
--[[@enum dnssec_digest_type]]
mod.dnssec_digest_type = {
	["SHA-1"] = 1, --[[MANDATORY]]
}
mod.dnssec_digest_type_name = {}

mod.encoders = {
	-- RFC 1035 §3.3.1
	[mod.type.CNAME] = mod.domain_name_to_string,
	-- RFC 1035 §3.3.11
	[mod.type.NS] = mod.domain_name_to_string,
	-- RFC 1035 §3.3.12
	[mod.type.PTR] = mod.domain_name_to_string,
	-- RFC 1035 §3.3.14
	[mod.type.TXT] = function(strs)
		local out = {}
		for _, s in ipairs(strs) do
			out[#out + 1] = char(#s) .. s
		end
		return concat(out)
	end,
	-- RFC 1035 §3.4.1
	[mod.type.A] = function(arr)
		local a = arr --[[:! { [integer]: integer }]]
		return char(a[1], a[2], a[3], a[4])
	end,
	-- RFC 3596 §2.2
	[mod.type.AAAA] = function(arr)
		local a = arr --[[:! { [integer]: integer }]]
		return char(
			a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8],
			a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]
		)
	end,
	-- RFC 1035 §3.3.9
	[mod.type.MX] = function(rec)
		local r = rec --[[:! { preference: integer, exchange: { [integer]: string } }]]
		local parts = mod.domain_name_to_string(r.exchange)
		return char(rshift(r.preference, 8), band(r.preference, 0xff)) .. parts
	end,
	-- RFC 1035 §3.3.13
	[mod.type.SOA] = function(rec)
		local r = rec --[[:! { mname: { [integer]: string }, rname: { [integer]: string }, serial: integer, refresh: integer, retry: integer, expire: integer, minimum: integer }]]
		local mname = mod.domain_name_to_string(r.mname)
		local rname = mod.domain_name_to_string(r.rname)
		return mname .. rname .. char(
			rshift(r.serial, 24), band(rshift(r.serial, 16), 0xff), band(rshift(r.serial, 8), 0xff), band(r.serial, 0xff),
			rshift(r.refresh, 24), band(rshift(r.refresh, 16), 0xff), band(rshift(r.refresh, 8), 0xff), band(r.refresh, 0xff),
			rshift(r.retry, 24), band(rshift(r.retry, 16), 0xff), band(rshift(r.retry, 8), 0xff), band(r.retry, 0xff),
			rshift(r.expire, 24), band(rshift(r.expire, 16), 0xff), band(rshift(r.expire, 8), 0xff), band(r.expire, 0xff),
			rshift(r.minimum, 24), band(rshift(r.minimum, 16), 0xff), band(rshift(r.minimum, 8), 0xff), band(r.minimum, 0xff)
		)
	end,
	-- RFC 1035 §3.3.2
	[mod.type.HINFO] = function(rec)
		local r = rec --[[:! { cpu: string, os: string }]]
		return char(#r.cpu) .. r.cpu .. char(#r.os) .. r.os
	end,
}

-- RFC 1035 §3.2.4 — CLASS values
--[[@enum dns_class]]
mod.class = {
	IN = 1, --[[the Internet]]
	CS = 2, --[[the CSNET class (Obsolete - used only for examples in some obsolete RFCs)]]
	CH = 3, --[[the CHAOS class]]
	HS = 4, --[[Hesiod [Dyer 87]]
}
mod.class_name = {}
for k, v in pairs(mod.class) do mod.class_name[v] = k end

--[[@enum dns_opcode]]
mod.opcode = {
	QUERY = 0, --[[a standard query]]
	IQUERY = 1, --[[an inverse query]]
	STATUS = 2, --[[a server status request]]
}
mod.opcode_name = {}
for k, v in pairs(mod.opcode) do mod.opcode_name[v] = k end

-- unofficial names
--[[@enum dns_response_code]]
mod.response_code = { OK = 0, EINVAL = 1, ESERVFAIL = 2, ENAME = 3, ENOTIMPL = 4, EREFUSED = 5 }
mod.response_code_name = {}
for k, v in pairs(mod.response_code) do mod.response_code_name[v] = k end

-- TODO: encoding queries, using compression

-- remember all names must end with the root ("")
-- RFC 1035 §4.1.1 — Header
-- RFC 1035 §4.1.2 — Question
-- RFC 1035 §4.1.3 — Resource record
--:: DnsQuestion = { name: { [integer]: string }, type: integer, class: integer }
--:: DnsResource = { name: { [integer]: string }, type: integer, class: integer, ttl: integer, data: string }
--:: DnsMessage = { id?: integer, questions?: { [integer]: DnsQuestion }, answers?: { [integer]: DnsResource }, nameservers?: { [integer]: DnsResource }, additional?: { [integer]: DnsResource }, opcode?: integer, is_response?: boolean, is_query?: boolean, is_authoritative?: boolean, is_truncated?: boolean, is_recursion_desired?: boolean, is_recursion_available?: boolean, response_code?: integer }
--: (DnsMessage) -> string
mod.dns_message_to_string = function (msg)
	local question_count = #(msg.questions or empty_table)
	local answer_count = #(msg.answers or empty_table)
	local nameserver_count = #(msg.nameservers or empty_table)
	local additional_count = #(msg.additional or empty_table)
	local parts = {}
	local i = 1
	local h_id_hi = rshift(msg.id or 0, 8)
	local h_id_lo = band(msg.id or 0, 0xff)
	local h_flags1 = bor(
		(msg.is_response or (msg.is_query == false)) and 0x80 or 0,
		lshift(msg.opcode or mod.opcode.QUERY, 3),
		msg.is_authoritative and 0x4 or 0,
		msg.is_truncated and 0x2 or 0,
		msg.is_recursion_desired and 0x1 or 0
	)
	local h_flags2 = bor(msg.is_recursion_available and 0x80 or 0, msg.response_code or 0)
	local qc_hi = rshift(question_count, 8); local qc_lo = band(question_count, 0xff)
	local ac_hi = rshift(answer_count, 8); local ac_lo = band(answer_count, 0xff)
	local nc_hi = rshift(nameserver_count, 8); local nc_lo = band(nameserver_count, 0xff)
	local adc_hi = rshift(additional_count, 8); local adc_lo = band(additional_count, 0xff)
	local next = char(h_id_hi, h_id_lo) .. char(h_flags1, h_flags2)
		.. char(qc_hi, qc_lo) .. char(ac_hi, ac_lo) .. char(nc_hi, nc_lo) .. char(adc_hi, adc_lo)
	parts[#parts+1] = next
	i = i + #next
	for _, q in ipairs(msg.questions or empty_table) do
		local parts2 = {}
		for _, part in ipairs(q.name) do
			assert(#part <= 0x3f, "dns_message_to_string: name part too long")
			parts2[#parts2+1] = char(#part) .. part
		end
		local qt_hi = rshift(q.type, 8); local qt_lo = band(q.type, 0xff)
		local qc_hi = rshift(q.class, 8); local qc_lo = band(q.class, 0xff)
		parts2[#parts2+1] = char(qt_hi, qt_lo, qc_hi, qc_lo)
		next = concat(parts2)
		parts[#parts+1] = next
		i = i + #next
	end
	local name_cache = {} --: { [string]: integer }
	for _, resources in ipairs({ msg.answers, msg.nameservers, msg.additional }) do
		for _, res in ipairs(resources) do
			local parts2 = {}
			local name_rest = concat(res.name, ".")
			local j = i
			for _, part in ipairs(res.name) do
				assert(#part <= 0x3f, "dns_message_to_string: name part too long")
				local cached_i = name_cache[name_rest]
				if cached_i then
					local cp_hi = bor(0xc0, rshift(cached_i, 8)); local cp_lo = band(cached_i, 0xff)
					parts2[#parts2+1] = char(cp_hi, cp_lo)
					break
				else
					name_cache[name_rest] = j - 1
					parts2[#parts2+1] = char(#part) .. part
				end
				j = j + #part + 1
				name_rest = sub(name_rest, #part + 1)
			end
			local length = #res.data
			local rt_hi = rshift(res.type, 8); local rt_lo = band(res.type, 0xff)
			local rc_hi = rshift(res.class, 8); local rc_lo = band(res.class, 0xff)
			local ttl_b1 = rshift(res.ttl, 24); local ttl_b2 = band(rshift(res.ttl, 16), 0xff)
			local ttl_b3 = band(rshift(res.ttl, 8), 0xff); local ttl_b4 = band(res.ttl, 0xff)
			local len_hi = rshift(length, 8); local len_lo = band(length, 0xff)
			parts2[#parts2+1] = char(rt_hi, rt_lo, rc_hi, rc_lo, ttl_b1, ttl_b2, ttl_b3, ttl_b4, len_hi, len_lo)
			next = concat(parts2)
			parts[#parts+1] = next
			i = i + #next
			parts[#parts+1] = res.data
			i = i + length
		end
	end
	return concat(parts)
end

-- RFC 1035 §4.1.1 — Header
-- RFC 1035 §4.1.2 — Question
-- RFC 1035 §4.1.3 — Resource record
--: (string) -> { [string]: unknown }
mod.string_to_dns_message = function (s)
	assert(#s >= 12, "string_to_dns_message: message too short, length was " .. #s)
	--[[@class dns_message]]
	local ret = {}
	local b1 = 0 --: integer
	local b2 = 0 --: integer
	b1, b2 = read2(s, 1)
	ret.id = bor(lshift(b1, 8), b2)
	b1 = byte(s, 3) or 0
	local qr = band(b1, 0x80)
	ret.is_query = qr == 0
	ret.is_response = qr ~= 0
	ret.opcode = band(rshift(b1, 3), 0xf)
	ret.is_authoritative = band(b1, 0x4) ~= 0
	ret.is_truncated = band(b1, 0x2) ~= 0
	ret.is_recursion_desired = band(b1, 0x1) ~= 0
	b1 = byte(s, 4) or 0 -- LINT: sequential, consecutive byte()
	ret.is_recursion_available = band(b1, 0x80) ~= 0
	-- band(b, 0x70) must be 0 - we will ignore

	ret.response_code = band(b1, 0xf)
	b1, b2 = read2(s, 5)
	local question_count = bor(lshift(b1, 8), b2) -- usually 1
	b1, b2 = read2(s, 7)
	local answer_count = bor(lshift(b1, 8), b2)
	b1, b2 = read2(s, 9)
	local nameserver_count = bor(lshift(b1, 8), b2)
	b1, b2 = read2(s, 11)
	local additional_count = bor(lshift(b1, 8), b2)
	local i = 13
	local questions = {}
	local b3 = 0 --: integer
	local b4 = 0 --: integer
	for j = 1, question_count do
		local parts = {}
		local length = byte(s, i) or 0 --: integer
		while length > 0 do
			local lbl = sub(s, i + 1, i + length)
			parts[#parts+1] = lbl
			i = i + length + 1
			length = byte(s, i) or 0
		end
		parts[#parts+1] = ""
		b1, b2, b3, b4 = read4(s, i + 1)
		-- LINT: linear values - @usages 1, @usages 2, @maxusages 1
		--[[@class dns_question]]
		questions[j] = {
			name = parts,
			type = bor(lshift(b1, 8), b2),
			class = bor(lshift(b3, 8), b4),
		}
		i = i + 5
	end
	ret.questions = questions
	local resources = { {}, {}, {} }
	for j, count in ipairs({ answer_count, nameserver_count, additional_count }) do
		local arr = resources[j]
		for k = 1, count do
			local parts
			parts, i = mod.string_to_domain_name(s, i)
			b1, b2, b3, b4 = read4(s, i)
			local type = bor(lshift(b1, 8), b2)
			local class = bor(lshift(b3, 8), b4)
			b1, b2, b3, b4 = read4(s, i + 4)
			local ttl = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
			if bit.band(ttl, 0x80000000) ~= 0 then ttl = (ttl - 0x100000000) --[[:! integer]] end
			local lb1, lb2 = read2(s, i + 8)
			local length = bor(lshift(lb1, 8), lb2)
			local data_i = i + 10
			i = data_i + length
			--[[@class dns_resource]]
			arr[k] = {
				name = parts,
				type = type,
				class = class,
				ttl = ttl, data = mod.decoders[type] and mod.decoders[type](s, data_i, length) or s:sub(data_i, data_i + length - 1),
			}
		end
	end
	ret.answers, ret.nameservers, ret.additional = resources[1], resources[2], resources[3]
	return ret
end

return mod
