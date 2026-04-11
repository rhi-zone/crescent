-- lib/net/net_test.lua — tests for lib/net

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local net = require("lib.net")

-- ── IPv4 ─────────────────────────────────────────────────────────────────────

T.describe("ipv4", function()
  T.it("parse and to_string", function()
    local ip = net.ipv4("192.168.1.100")
    T.ok(ip, "parsed")
    T.eq(ip:to_string(), "192.168.1.100")
  end)

  T.it("to_number", function()
    local ip = net.ipv4("192.168.1.100")
    T.eq(ip:to_number(), 192 * 0x1000000 + 168 * 0x10000 + 1 * 0x100 + 100)
  end)

  T.it("to_number known value", function()
    local ip = net.ipv4("192.168.1.100")
    -- 192*2^24 + 168*2^16 + 1*2^8 + 100 = 3232235876
    T.eq(ip:to_number(), 3232235876)
  end)

  T.it("octets", function()
    local ip = net.ipv4("10.0.0.1")
    local o = ip:octets()
    T.eq(o[1], 10)
    T.eq(o[2], 0)
    T.eq(o[3], 0)
    T.eq(o[4], 1)
  end)

  T.it("ipv4_from_number roundtrip", function()
    local ip = net.ipv4_from_number(3232235876)
    T.eq(ip:to_string(), "192.168.1.100")
  end)

  T.it("is_private: 10.x.x.x", function()
    T.ok(net.ipv4("10.0.0.1"):is_private())
    T.ok(net.ipv4("10.255.255.255"):is_private())
  end)

  T.it("is_private: 172.16-31.x.x", function()
    T.ok(net.ipv4("172.16.0.0"):is_private())
    T.ok(net.ipv4("172.31.255.255"):is_private())
    T.fail(net.ipv4("172.15.0.0"):is_private())
    T.fail(net.ipv4("172.32.0.0"):is_private())
  end)

  T.it("is_private: 192.168.x.x", function()
    T.ok(net.ipv4("192.168.1.1"):is_private())
    T.fail(net.ipv4("192.169.1.1"):is_private())
  end)

  T.it("is_private: public IP is not private", function()
    T.fail(net.ipv4("8.8.8.8"):is_private())
  end)

  T.it("is_loopback", function()
    T.ok(net.ipv4("127.0.0.1"):is_loopback())
    T.ok(net.ipv4("127.255.255.255"):is_loopback())
    T.fail(net.ipv4("192.168.1.1"):is_loopback())
  end)

  T.it("is_multicast", function()
    T.ok(net.ipv4("224.0.0.1"):is_multicast())
    T.ok(net.ipv4("239.255.255.255"):is_multicast())
    T.fail(net.ipv4("223.255.255.255"):is_multicast())
    T.fail(net.ipv4("192.168.1.1"):is_multicast())
  end)

  T.it("is_broadcast", function()
    T.ok(net.ipv4("255.255.255.255"):is_broadcast())
    T.fail(net.ipv4("255.255.255.254"):is_broadcast())
  end)

  T.it("is_link_local", function()
    T.ok(net.ipv4("169.254.1.1"):is_link_local())
    T.fail(net.ipv4("169.255.1.1"):is_link_local())
    T.fail(net.ipv4("192.168.1.1"):is_link_local())
  end)

  T.it("parse error: missing octet", function()
    local ip, err = net.ipv4("192.168.1")
    T.fail(ip)
    T.ok(err)
  end)

  T.it("parse error: octet out of range", function()
    local ip, err = net.ipv4("192.168.1.256")
    T.fail(ip)
    T.ok(err)
  end)

  T.it("parse error: non-numeric", function()
    local ip, err = net.ipv4("abc.def.ghi.jkl")
    T.fail(ip)
    T.ok(err)
  end)

  T.it("0.0.0.0 parses", function()
    local ip = net.ipv4("0.0.0.0")
    T.eq(ip:to_number(), 0)
    T.eq(ip:to_string(), "0.0.0.0")
  end)

  T.it("255.255.255.255 parses", function()
    local ip = net.ipv4("255.255.255.255")
    T.eq(ip:to_number(), 0xFFFFFFFF)
  end)
end)

-- ── IPv6 ─────────────────────────────────────────────────────────────────────

T.describe("ipv6", function()
  T.it("parse full address", function()
    local ip = net.ipv6("2001:0db8:0000:0000:0000:0000:0000:0001")
    T.ok(ip)
    local g = ip:groups()
    T.eq(g[1], 0x2001)
    T.eq(g[2], 0x0db8)
    T.eq(g[8], 1)
  end)

  T.it("parse compressed ::", function()
    local ip = net.ipv6("2001:db8::1")
    T.ok(ip)
    local g = ip:groups()
    T.eq(g[1], 0x2001)
    T.eq(g[2], 0x0db8)
    T.eq(g[3], 0)
    T.eq(g[4], 0)
    T.eq(g[8], 1)
  end)

  T.it("parse loopback ::1", function()
    local ip = net.ipv6("::1")
    T.ok(ip)
    T.ok(ip:is_loopback())
  end)

  T.it("parse all zeros ::", function()
    local ip = net.ipv6("::")
    T.ok(ip)
    local g = ip:groups()
    for i = 1, 8 do T.eq(g[i], 0) end
  end)

  T.it("to_full_string", function()
    local ip = net.ipv6("2001:db8::1")
    T.eq(ip:to_full_string(), "2001:0db8:0000:0000:0000:0000:0000:0001")
  end)

  T.it("to_string compressed", function()
    local ip = net.ipv6("2001:0db8:0000:0000:0000:0000:0000:0001")
    T.eq(ip:to_string(), "2001:db8::1")
  end)

  T.it("to_string loopback", function()
    local ip = net.ipv6("::1")
    T.eq(ip:to_string(), "::1")
  end)

  T.it("to_string all zeros", function()
    local ip = net.ipv6("::")
    T.eq(ip:to_string(), "::")
  end)

  T.it("is_loopback: ::1", function()
    T.ok(net.ipv6("::1"):is_loopback())
    T.fail(net.ipv6("::2"):is_loopback())
  end)

  T.it("is_link_local: fe80::", function()
    T.ok(net.ipv6("fe80::1"):is_link_local())
    T.fail(net.ipv6("2001:db8::1"):is_link_local())
  end)

  T.it("is_multicast: ff00::/8", function()
    T.ok(net.ipv6("ff02::1"):is_multicast())
    T.fail(net.ipv6("2001:db8::1"):is_multicast())
  end)

  T.it("parse error: too many groups", function()
    local ip, err = net.ipv6("1:2:3:4:5:6:7:8:9")
    T.fail(ip)
    T.ok(err)
  end)

  T.it("groups copy not aliased", function()
    local ip = net.ipv6("2001:db8::1")
    local g1 = ip:groups()
    local g2 = ip:groups()
    g1[1] = 0xDEAD
    T.eq(g2[1], 0x2001)
  end)
end)

-- ── CIDR ─────────────────────────────────────────────────────────────────────

T.describe("cidr", function()
  T.it("parse and to_string", function()
    local c = net.cidr("192.168.1.0/24")
    T.ok(c)
    T.eq(c:to_string(), "192.168.1.0/24")
  end)

  T.it("prefix_len", function()
    T.eq(net.cidr("10.0.0.0/8"):prefix_len(), 8)
    T.eq(net.cidr("192.168.1.0/24"):prefix_len(), 24)
  end)

  T.it("network address", function()
    local c = net.cidr("192.168.1.0/24")
    T.eq(c:network():to_string(), "192.168.1.0")
  end)

  T.it("network masks input address", function()
    local c = net.cidr("192.168.1.100/24")
    T.eq(c:network():to_string(), "192.168.1.0")
  end)

  T.it("broadcast", function()
    local c = net.cidr("192.168.1.0/24")
    T.eq(c:broadcast():to_string(), "192.168.1.255")
  end)

  T.it("netmask", function()
    T.eq(net.cidr("192.168.1.0/24"):netmask():to_string(), "255.255.255.0")
    T.eq(net.cidr("10.0.0.0/8"):netmask():to_string(), "255.0.0.0")
    T.eq(net.cidr("0.0.0.0/0"):netmask():to_string(), "0.0.0.0")
  end)

  T.it("contains: inside", function()
    local c = net.cidr("192.168.1.0/24")
    local ip = net.ipv4("192.168.1.100")
    T.ok(c:contains(ip))
  end)

  T.it("contains: outside", function()
    local c = net.cidr("192.168.1.0/24")
    local ip = net.ipv4("192.168.2.1")
    T.fail(c:contains(ip))
  end)

  T.it("contains: network address itself", function()
    local c = net.cidr("192.168.1.0/24")
    T.ok(c:contains(net.ipv4("192.168.1.0")))
  end)

  T.it("contains: broadcast address", function()
    local c = net.cidr("192.168.1.0/24")
    T.ok(c:contains(net.ipv4("192.168.1.255")))
  end)

  T.it("host_count /24", function()
    T.eq(net.cidr("192.168.1.0/24"):host_count(), 254)
  end)

  T.it("host_count /16", function()
    T.eq(net.cidr("10.0.0.0/16"):host_count(), 65534)
  end)

  T.it("first_host", function()
    T.eq(net.cidr("192.168.1.0/24"):first_host():to_string(), "192.168.1.1")
  end)

  T.it("last_host", function()
    T.eq(net.cidr("192.168.1.0/24"):last_host():to_string(), "192.168.1.254")
  end)

  T.it("iter_hosts count", function()
    local c = net.cidr("192.168.1.0/24")
    local count = 0
    for _ in c:iter_hosts() do count = count + 1 end
    T.eq(count, 254)
  end)

  T.it("iter_hosts first and last", function()
    local c = net.cidr("192.168.1.0/24")
    local first_ip, last_ip
    for ip in c:iter_hosts() do
      if not first_ip then first_ip = ip end
      last_ip = ip
    end
    T.eq(first_ip:to_string(), "192.168.1.1")
    T.eq(last_ip:to_string(), "192.168.1.254")
  end)

  T.it("parse error: invalid prefix", function()
    local c, err = net.cidr("192.168.1.0/33")
    T.fail(c)
    T.ok(err)
  end)

  T.it("parse error: no prefix", function()
    local c, err = net.cidr("192.168.1.0")
    T.fail(c)
    T.ok(err)
  end)
end)

-- ── supernet ──────────────────────────────────────────────────────────────────

T.describe("supernet", function()
  T.it("same subnet", function()
    local c = net.supernet("192.168.1.5", "192.168.1.20")
    T.ok(c)
    T.ok(c:contains(net.ipv4("192.168.1.5")))
    T.ok(c:contains(net.ipv4("192.168.1.20")))
  end)

  T.it("identical addresses", function()
    local c = net.supernet("10.0.0.1", "10.0.0.1")
    T.ok(c)
    T.ok(c:contains(net.ipv4("10.0.0.1")))
  end)

  T.it("error on bad input", function()
    local c, err = net.supernet("bad", "10.0.0.1")
    T.fail(c)
    T.ok(err)
  end)
end)

-- ── URL ──────────────────────────────────────────────────────────────────────

T.describe("url_parse", function()
  T.it("full URL", function()
    local url = net.url_parse("https://user:pass@example.com:8080/path?q=1&r=2#anchor")
    T.ok(url)
    T.eq(url.scheme,   "https")
    T.eq(url.user,     "user")
    T.eq(url.password, "pass")
    T.eq(url.host,     "example.com")
    T.eq(url.port,     8080)
    T.eq(url.path,     "/path")
    T.eq(url.query,    "q=1&r=2")
    T.eq(url.fragment, "anchor")
  end)

  T.it("query_params parsed", function()
    local url = net.url_parse("https://example.com/?q=1&r=2")
    T.ok(url.query_params)
    T.eq(url.query_params.q, "1")
    T.eq(url.query_params.r, "2")
  end)

  T.it("simple URL no auth", function()
    local url = net.url_parse("http://example.com/")
    T.eq(url.scheme, "http")
    T.eq(url.host,   "example.com")
    T.eq(url.path,   "/")
    T.fail(url.user)
    T.fail(url.port)
  end)

  T.it("URL no path or query", function()
    local url = net.url_parse("https://example.com")
    T.eq(url.host, "example.com")
    T.fail(url.path)
  end)

  T.it("error on missing scheme", function()
    local url, err = net.url_parse("example.com/path")
    T.fail(url)
    T.ok(err)
  end)
end)

T.describe("url_build", function()
  T.it("roundtrip", function()
    local s = "https://user:pass@example.com:8080/path?q=1&r=2#anchor"
    local url = net.url_parse(s)
    local rebuilt = net.url_build(url)
    T.eq(rebuilt, s)
  end)

  T.it("simple", function()
    local url = { scheme = "http", host = "example.com", path = "/" }
    T.eq(net.url_build(url), "http://example.com/")
  end)
end)

T.describe("url_encode / url_decode", function()
  T.it("encode spaces and special chars", function()
    T.eq(net.url_encode("hello world"), "hello%20world")
    T.eq(net.url_encode("a&b=c"), "a%26b%3Dc")
  end)

  T.it("decode", function()
    T.eq(net.url_decode("hello%20world"), "hello world")
    T.eq(net.url_decode("a%26b%3Dc"),    "a&b=c")
  end)

  T.it("roundtrip", function()
    local s = "hello world & more"
    T.eq(net.url_decode(net.url_encode(s)), s)
  end)

  T.it("unreserved chars unchanged", function()
    T.eq(net.url_encode("abcABC123-._~"), "abcABC123-._~")
  end)
end)

T.describe("query_encode / query_decode", function()
  T.it("encode", function()
    local s = net.query_encode({ a = "1", b = "hello world" })
    -- sorted keys: a before b
    T.eq(s, "a=1&b=hello+world")
  end)

  T.it("decode", function()
    local t = net.query_decode("a=1&b=hello+world")
    T.eq(t.a, "1")
    T.eq(t.b, "hello world")
  end)

  T.it("roundtrip", function()
    local orig = { name = "foo bar", value = "1" }
    local encoded = net.query_encode(orig)
    local decoded = net.query_decode(encoded)
    T.eq(decoded.name,  orig.name)
    T.eq(decoded.value, orig.value)
  end)

  T.it("percent encoding in query", function()
    local t = net.query_decode("k=%41%42%43")
    T.eq(t.k, "ABC")
  end)
end)

-- ── MAC ───────────────────────────────────────────────────────────────────────

T.describe("mac", function()
  T.it("parse colon-separated", function()
    local m = net.mac("00:1A:2B:3C:4D:5E")
    T.ok(m)
    T.eq(m:to_string(), "00:1a:2b:3c:4d:5e")
  end)

  T.it("parse dash-separated", function()
    local m = net.mac("00-1A-2B-3C-4D-5E")
    T.ok(m)
    T.eq(m:to_string(), "00:1a:2b:3c:4d:5e")
  end)

  T.it("to_colon_string", function()
    T.eq(net.mac("FF:FF:FF:FF:FF:FF"):to_colon_string(), "ff:ff:ff:ff:ff:ff")
  end)

  T.it("to_dash_string", function()
    T.eq(net.mac("00:1A:2B:3C:4D:5E"):to_dash_string(), "00-1a-2b-3c-4d-5e")
  end)

  T.it("octets", function()
    local m = net.mac("00:1A:2B:3C:4D:5E")
    local o = m:octets()
    T.eq(o[1], 0x00)
    T.eq(o[2], 0x1A)
    T.eq(o[3], 0x2B)
    T.eq(o[4], 0x3C)
    T.eq(o[5], 0x4D)
    T.eq(o[6], 0x5E)
  end)

  T.it("is_broadcast: FF:FF:FF:FF:FF:FF", function()
    T.ok(net.mac("FF:FF:FF:FF:FF:FF"):is_broadcast())
    T.fail(net.mac("00:1A:2B:3C:4D:5E"):is_broadcast())
  end)

  T.it("is_multicast: odd first octet LSB", function()
    T.ok(net.mac("01:00:5E:00:00:01"):is_multicast())  -- IPv4 multicast
    T.fail(net.mac("00:1A:2B:3C:4D:5E"):is_multicast())
  end)

  T.it("oui", function()
    T.eq(net.mac("00:1A:2B:3C:4D:5E"):oui(), "00:1a:2b")
  end)

  T.it("parse error: too few octets", function()
    local m, err = net.mac("00:1A:2B:3C:4D")
    T.fail(m)
    T.ok(err)
  end)

  T.it("parse error: invalid hex", function()
    local m, err = net.mac("GG:1A:2B:3C:4D:5E")
    T.fail(m)
    T.ok(err)
  end)

  T.it("parse error: wrong octet length", function()
    local m, err = net.mac("000:1A:2B:3C:4D:5E")
    T.fail(m)
    T.ok(err)
  end)
end)
