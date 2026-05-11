-- Display formatters for decoded DNS RDATA (see RFC 1035 §3.3, RFC 3596 §2.2, RFC 4034 §2–5)
local dns = require("lib.dns.format")
local bit = require("bit")

local mod = {}

local domain_parts_to_string = function (parts) return table.concat(parts, ".") end
mod.domain_parts_to_string = domain_parts_to_string
-- LINT: warn on unused diagnostics
mod.formatters = {
	[dns.type.CNAME] = domain_parts_to_string,
	--[[@diagnostic disable-next-line: deprecated]]
	[dns.type.MB]  = domain_parts_to_string,
	--[[@diagnostic disable-next-line: deprecated]]
	[dns.type.MD] = domain_parts_to_string,
	--[[@diagnostic disable-next-line: deprecated]]
	[dns.type.MF] = domain_parts_to_string,
	--[[@diagnostic disable-next-line: deprecated]]
	[dns.type.MG] = domain_parts_to_string,
	--[[@diagnostic disable-next-line: deprecated]]
	[dns.type.MINFO] = function (x_u) local x = (x_u --[[: unknown]]) --[[:! { rmailbx: { [integer]: string | number }, emailbx: { [integer]: string | number }, ... }]]; (x --[[: unknown]]).rmailbx = domain_parts_to_string(x.rmailbx); (x --[[: unknown]]).emailbx = domain_parts_to_string(x.emailbx); return x end,
	--[[@diagnostic disable-next-line: deprecated]]
	[dns.type.MR] = domain_parts_to_string,
	--[[@diagnostic disable-next-line: param-type-mismatch]]
	[dns.type.MX] = function (x) x.exchange = domain_parts_to_string(x.exchange); return x end,
	[dns.type.NS] = domain_parts_to_string,
	[dns.type.PTR] = domain_parts_to_string,
	--[[@diagnostic disable-next-line: param-type-mismatch]]
	[dns.type.SOA] = function (x_u) local x = (x_u --[[: unknown]]) --[[:! { mname: { [integer]: string | number }, rname: { [integer]: string | number }, ... }]]; (x --[[: unknown]]).mname = domain_parts_to_string(x.mname); (x --[[: unknown]]).rname = domain_parts_to_string(x.rname); return x end,
	[dns.type.TXT] = function (strs) return table.concat(strs, "\t") end,
	[dns.type.A] = function (arr) return table.concat(arr, ".") end,
	[dns.type.AAAA] = function (arr)
		-- Convert 16 bytes to IPv6 hex notation
		local arr_t = arr --[[:! { [integer]: integer }]]
		local hex_parts = {}
		for idx = 1, 16, 2 do
			hex_parts[#hex_parts+1] = string.format("%x", bit.bor(bit.lshift(arr_t[idx] or 0, 8), arr_t[idx+1] or 0))
		end
		local s = table.concat(hex_parts, ":")
		local max0s = ""
		for m in s:gmatch("[0:][0:]+") do if #m > #max0s then max0s = m end end
		return (#max0s > 0 and s:gsub(max0s, "::", 1) or s) --: string
	end,
	[dns.type.DS] = function (x)
		x.algorithm = dns.dnssec_algorithm_name[x.algorithm] or x.algorithm
		x.digest_type = dns.dnssec_digest_type_name[x.digest_type] or x.digest_type
		return x
	end,
	[dns.type.RRSIG] = function (x)
		x.type_covered = dns.type_name[x.type] or x.type_covered
		x.algorithm = dns.dnssec_algorithm_name[x.algorithm] or x.algorithm
		return x
	end,
	[dns.type.NSEC] = function (x)
		for i = 1, #x.types do x.types[i] = dns.type_name[x.types[i]] or x.types[i] end
		return x
	end,
	[dns.type.DNSKEY] = function (x) x.algorithm = dns.dnssec_algorithm_name[x.algorithm] or x.algorithm; return x end,
}

return mod
