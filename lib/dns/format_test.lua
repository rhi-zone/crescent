if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local dns = require("lib.dns.format")
local T = require("lib.test.assert")

-- helpers
local char = string.char

T.describe("domain name codec", function()
	T.it("round-trip encode/decode", function()
		local parts = { "www", "example", "com", "" }
		local wire = dns.domain_name_to_string(parts)
		local decoded, pos = dns.string_to_domain_name(wire, 1)
		T.eq(#decoded, #parts)
		for i = 1, #parts do T.eq(decoded[i], parts[i]) end
		T.eq(pos, #wire + 1)
	end)

	T.it("root domain (single empty label)", function()
		local parts = { "" }
		local wire = dns.domain_name_to_string(parts)
		T.eq(wire, "\0")
		local decoded = dns.string_to_domain_name(wire, 1)
		T.eq(#decoded, 1)
		T.eq(decoded[1], "")
	end)

	T.it("rejects labels longer than 63 bytes", function()
		local long_label = string.rep("a", 64)
		local ok, err = pcall(dns.domain_name_to_string, { long_label, "" })
		T.eq(ok, false)
		T.ok(err:find("label too long"))
	end)
end)

T.describe("name compression", function()
	T.it("follows pointer to earlier name", function()
		-- Build: offset 0 = \3www\7example\3com\0, then a pointer at some offset
		local name_wire = "\3www\7example\3com\0"
		-- pointer to offset 0 (0xC000)
		local ptr = char(0xC0, 0x00)
		local full = name_wire .. ptr
		local decoded, pos = dns.string_to_domain_name(full, #name_wire + 1)
		T.eq(pos, #full + 1)
		-- should have followed the pointer
		T.eq(decoded[1], "www")
		T.eq(decoded[2], "example")
		T.eq(decoded[3], "com")
		T.eq(decoded[4], "")
	end)
end)

T.describe("RDATA decoders", function()
	T.it("A record: 4 bytes to array", function()
		local wire = char(192, 168, 1, 1)
		local decoded = dns.decoders[dns.type.A](wire, 1)
		T.eq(decoded[1], 192)
		T.eq(decoded[2], 168)
		T.eq(decoded[3], 1)
		T.eq(decoded[4], 1)
	end)

	T.it("AAAA record: 16 bytes to array", function()
		local wire = char(0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01)
		local decoded = dns.decoders[dns.type.AAAA](wire, 1)
		T.eq(decoded[1], 0x20)
		T.eq(decoded[2], 0x01)
		T.eq(decoded[16], 0x01)
	end)

	T.it("TXT record: multiple strings", function()
		local wire = char(5) .. "hello" .. char(5) .. "world"
		local decoded = dns.decoders[dns.type.TXT](wire, 1, #wire)
		T.eq(#decoded, 2)
		T.eq(decoded[1], "hello")
		T.eq(decoded[2], "world")
	end)

	T.it("TXT record: single string", function()
		local wire = char(3) .. "foo"
		local decoded = dns.decoders[dns.type.TXT](wire, 1, #wire)
		T.eq(#decoded, 1)
		T.eq(decoded[1], "foo")
	end)

	T.it("HINFO record", function()
		local wire = char(3) .. "x86" .. char(5) .. "Linux"
		local decoded = dns.decoders[dns.type.HINFO](wire, 1)
		T.eq(decoded.cpu, "x86")
		T.eq(decoded.os, "Linux")
	end)

	T.it("MX record", function()
		local wire = char(0, 10) .. char(4) .. "mail" .. char(7) .. "example" .. char(3) .. "com" .. char(0)
		local decoded = dns.decoders[dns.type.MX](wire, 1)
		T.eq(decoded.preference, 10)
		T.eq(decoded.exchange[1], "mail")
		T.eq(decoded.exchange[2], "example")
		T.eq(decoded.exchange[3], "com")
	end)
end)

T.describe("RDATA encoders", function()
	T.it("A record round-trip", function()
		local original = { 10, 0, 0, 1 }
		local wire = dns.encoders[dns.type.A](original)
		local decoded = dns.decoders[dns.type.A](wire, 1)
		for i = 1, 4 do T.eq(decoded[i], original[i]) end
	end)

	T.it("AAAA record round-trip", function()
		local original = { 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 }
		local wire = dns.encoders[dns.type.AAAA](original)
		local decoded = dns.decoders[dns.type.AAAA](wire, 1)
		for i = 1, 16 do T.eq(decoded[i], original[i]) end
	end)

	T.it("TXT record round-trip", function()
		local original = { "hello", "world" }
		local wire = dns.encoders[dns.type.TXT](original)
		local decoded = dns.decoders[dns.type.TXT](wire, 1, #wire)
		T.eq(#decoded, 2)
		T.eq(decoded[1], "hello")
		T.eq(decoded[2], "world")
	end)

	T.it("CNAME record round-trip", function()
		local original = { "www", "example", "com", "" }
		local wire = dns.encoders[dns.type.CNAME](original)
		local decoded, _ = dns.decoders[dns.type.CNAME](wire, 1)
		for i = 1, #original do T.eq(decoded[i], original[i]) end
	end)

	T.it("MX record round-trip", function()
		local original = { preference = 10, exchange = { "mail", "example", "com", "" } }
		local wire = dns.encoders[dns.type.MX](original)
		local decoded = dns.decoders[dns.type.MX](wire, 1)
		T.eq(decoded.preference, 10)
		for i = 1, 4 do T.eq(decoded.exchange[i], original.exchange[i]) end
	end)

	T.it("SOA record round-trip", function()
		local original = {
			mname = { "ns1", "example", "com", "" },
			rname = { "admin", "example", "com", "" },
			serial = 2024010100,
			refresh = 3600,
			retry = 900,
			expire = 604800,
			minimum = 86400,
		}
		local wire = dns.encoders[dns.type.SOA](original)
		local decoded = dns.decoders[dns.type.SOA](wire, 1)
		for i = 1, 4 do T.eq(decoded.mname[i], original.mname[i]) end
		for i = 1, 4 do T.eq(decoded.rname[i], original.rname[i]) end
		T.eq(decoded.serial, original.serial)
		T.eq(decoded.refresh, original.refresh)
		T.eq(decoded.retry, original.retry)
		T.eq(decoded.expire, original.expire)
		T.eq(decoded.minimum, original.minimum)
	end)

	T.it("HINFO record round-trip", function()
		local original = { cpu = "x86", os = "Linux" }
		local wire = dns.encoders[dns.type.HINFO](original)
		local decoded = dns.decoders[dns.type.HINFO](wire, 1)
		T.eq(decoded.cpu, "x86")
		T.eq(decoded.os, "Linux")
	end)
end)

T.describe("full message round-trip", function()
	T.it("query message", function()
		local msg = {
			id = 0x1234,
			is_query = true,
			is_recursion_desired = true,
			questions = {
				{ name = { "example", "com", "" }, type = dns.type.A, class = dns.class.IN },
			},
			answers = {},
			nameservers = {},
			additional = {},
		}
		local wire = dns.dns_message_to_string(msg)
		local decoded = dns.string_to_dns_message(wire)
		T.eq(decoded.id, 0x1234)
		T.eq(decoded.is_query, true)
		T.eq(decoded.is_recursion_desired, true)
		T.eq(#decoded.questions, 1)
		T.eq(decoded.questions[1].name[1], "example")
		T.eq(decoded.questions[1].name[2], "com")
		T.eq(decoded.questions[1].type, dns.type.A)
		T.eq(decoded.questions[1].class, dns.class.IN)
	end)

	T.it("response message with A record", function()
		local msg = {
			id = 0x5678,
			is_response = true,
			response_code = dns.response_code.OK,
			questions = {
				{ name = { "example", "com", "" }, type = dns.type.A, class = dns.class.IN },
			},
			answers = {
				{ name = { "example", "com", "" }, type = dns.type.A, class = dns.class.IN, ttl = 300, data = char(93, 184, 216, 34) },
			},
			nameservers = {},
			additional = {},
		}
		local wire = dns.dns_message_to_string(msg)
		local decoded = dns.string_to_dns_message(wire)
		T.eq(decoded.id, 0x5678)
		T.eq(decoded.is_response, true)
		T.eq(#decoded.answers, 1)
		-- A record is decoded by the decoder
		T.eq(decoded.answers[1].type, dns.type.A)
	end)

	T.it("message too short", function()
		local ok, err = pcall(dns.string_to_dns_message, "short")
		T.eq(ok, false)
		T.ok(err:find("too short"))
	end)
end)

T.describe("edge cases", function()
	T.it("type and type_name are inverses", function()
		for name, id in pairs(dns.type) do
			T.eq(dns.type_name[id], name)
		end
	end)

	T.it("class and class_name are inverses", function()
		for name, id in pairs(dns.class) do
			T.eq(dns.class_name[id], name)
		end
	end)

	T.it("response_code and response_code_name are inverses", function()
		for name, id in pairs(dns.response_code) do
			T.eq(dns.response_code_name[id], name)
		end
	end)
end)
