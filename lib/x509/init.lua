-- lib/x509/init.lua
-- X.509 certificate parser (RFC 5280). Pure Lua.
-- Depends on lib/asn1 (DER parser) and lib/pem (PEM decoder).
-- Optional: lib/hash/sha256 for fingerprint_sha256 (gracefully absent).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local asn1 = require("lib.asn1")
local pem  = require("lib.pem")

local M = {}
M._tier = "pure"

local byte, sub, format = string.byte, string.sub, string.format
local concat = table.concat

-- ── OID name mappings ────────────────────────────────────────────────────────

local OID_NAMES = {
  -- Signature / key algorithms
  ["1.2.840.113549.1.1.1"]  = "rsaEncryption",
  ["1.2.840.113549.1.1.5"]  = "sha1WithRSAEncryption",
  ["1.2.840.113549.1.1.11"] = "sha256WithRSAEncryption",
  ["1.2.840.113549.1.1.12"] = "sha384WithRSAEncryption",
  ["1.2.840.113549.1.1.13"] = "sha512WithRSAEncryption",
  ["1.2.840.10045.2.1"]     = "ecPublicKey",
  ["1.2.840.10045.4.3.2"]   = "ecdsaWithSHA256",
  ["1.3.101.110"]           = "X25519",
  ["1.3.101.112"]           = "Ed25519",
  -- Name attribute types
  ["2.5.4.3"]               = "CN",
  ["2.5.4.6"]               = "C",
  ["2.5.4.7"]               = "L",
  ["2.5.4.8"]               = "ST",
  ["2.5.4.10"]              = "O",
  ["2.5.4.11"]              = "OU",
  -- Extension OIDs
  ["2.5.29.17"]             = "subjectAltName",
  ["2.5.29.19"]             = "basicConstraints",
  ["2.5.29.37"]             = "extKeyUsage",
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Convert binary string to hex with colon separators: "aa:bb:cc:..."
--: (string) -> string
local function to_hex_colons(s)
  local parts = {}
  for i = 1, #s do
    parts[i] = format("%02x", byte(s, i))
  end
  return concat(parts, ":")
end

-- Convert binary string to plain hex: "aabbcc..."
--: (string) -> string
local function to_hex(s)
  local parts = {}
  for i = 1, #s do
    parts[i] = format("%02x", byte(s, i))
  end
  return concat(parts)
end

-- Try to load sha256; return nil if unavailable.
local _sha256
local function get_sha256()
  if _sha256 ~= nil then return _sha256 end
  local ok, mod = pcall(require, "lib.hash.sha256")
  _sha256 = ok and mod or false
  return _sha256
end

-- ── Low-level DER helpers ─────────────────────────────────────────────────────

-- Decode a TLV and return it, or propagate an error.
-- Returns: node, nil  OR  nil, errmsg
local function tlv(data, pos)
  return asn1.decode_tlv(data, pos)
end

-- Decode the children of a constructed TLV value as a sequence of TLVs.
-- Returns: array of nodes, nil  OR  nil, errmsg
local function children(node)
  return asn1.decode_sequence(node.value)
end

-- Decode an OID value bytes to dotted-decimal string, then look up friendly name.
-- Returns: oid_string, friendly_name_or_nil
local function decode_oid_node(node)
  local oid, err = asn1.decode_oid(node.value)
  if not oid then return nil, nil, err end
  return oid, OID_NAMES[oid]
end

-- ── Name (RDN sequence) parser ────────────────────────────────────────────────
--
-- Name ::= SEQUENCE OF RelativeDistinguishedName
-- RelativeDistinguishedName ::= SET OF AttributeTypeAndValue
-- AttributeTypeAndValue ::= SEQUENCE { type OID, value ANY }

local function parse_name(name_value)
  -- name_value is the raw bytes of the outer SEQUENCE
  local rdns, err = asn1.decode_sequence(name_value)
  if not rdns then return nil, "name: " .. (err or "") end

  local result = {}
  for _, rdn_node in ipairs(rdns) do
    -- Each RDN is a SET
    if not rdn_node.constructed then
      return nil, "name: RDN is not constructed"
    end
    local atvs, err2 = children(rdn_node)
    if not atvs then return nil, "name RDN: " .. (err2 or "") end

    for _, atv_node in ipairs(atvs) do
      -- ATV is a SEQUENCE
      if not atv_node.constructed then
        return nil, "name: ATV is not constructed"
      end
      local fields, err3 = children(atv_node)
      if not fields then return nil, "name ATV: " .. (err3 or "") end
      if #fields < 2 then
        return nil, "name ATV: expected at least 2 fields, got " .. #fields
      end

      local type_node  = fields[1]
      local value_node = fields[2]

      if type_node.tag ~= asn1.TAG_OID then
        return nil, "name ATV type is not OID"
      end

      local oid, attr_name = decode_oid_node(type_node)
      if not oid then return nil, "name ATV OID: decode failed" end

      local attr_value = asn1.decode_string(value_node.value)
      local key = attr_name or oid
      result[key] = attr_value
    end
  end

  return result, nil
end

-- ── AlgorithmIdentifier parser ────────────────────────────────────────────────
--
-- AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters ANY OPTIONAL }

local function parse_alg_id(node)
  if not node.constructed then
    return nil, "AlgorithmIdentifier is not a SEQUENCE"
  end
  local fields, err = children(node)
  if not fields then return nil, "AlgorithmIdentifier: " .. (err or "") end
  if #fields < 1 then
    return nil, "AlgorithmIdentifier: missing OID"
  end

  local oid_node = fields[1]
  if oid_node.tag ~= asn1.TAG_OID then
    return nil, "AlgorithmIdentifier: first field is not OID (tag=" .. oid_node.tag .. ")"
  end

  local oid, friendly = decode_oid_node(oid_node)
  if not oid then return nil, "AlgorithmIdentifier OID decode failed" end

  return { oid = oid, name = friendly }, nil
end

-- ── Validity parser ───────────────────────────────────────────────────────────
--
-- Validity ::= SEQUENCE { notBefore Time, notAfter Time }
-- Time ::= UTCTime | GeneralizedTime

local function parse_validity(node)
  if not node.constructed then
    return nil, "Validity is not a SEQUENCE"
  end
  local fields, err = children(node)
  if not fields then return nil, "Validity: " .. (err or "") end
  if #fields < 2 then
    return nil, "Validity: expected 2 fields, got " .. #fields
  end

  local function decode_time_node(n)
    local n_ = n --[[:! { tag: integer, value: string }]]
    if n_.tag == asn1.TAG_UTCTIME or n_.tag == asn1.TAG_GENERALIZEDTIME then
      return asn1.decode_time(n_.value, n_.tag)
    end
    return nil, "Validity: unexpected time tag " .. n_.tag
  end

  local nb, err_nb = decode_time_node(fields[1])
  if not nb then return nil, err_nb end

  local na, err_na = decode_time_node(fields[2])
  if not na then return nil, err_na end

  return { not_before = nb, not_after = na }, nil
end

-- ── SubjectPublicKeyInfo parser ───────────────────────────────────────────────
--
-- SubjectPublicKeyInfo ::= SEQUENCE {
--   algorithm   AlgorithmIdentifier,
--   subjectPublicKey BIT STRING
-- }

local function parse_spki(node)
  if not node.constructed then
    return nil, "SubjectPublicKeyInfo is not a SEQUENCE"
  end
  local fields, err = children(node)
  if not fields then return nil, "SubjectPublicKeyInfo: " .. (err or "") end
  if #fields < 2 then
    return nil, "SubjectPublicKeyInfo: expected 2 fields, got " .. #fields
  end

  local alg, err_alg = parse_alg_id(fields[1])
  if not alg then return nil, "SubjectPublicKeyInfo algorithm: " .. (err_alg or "") end

  if fields[2].tag ~= asn1.TAG_BIT_STRING then
    return nil, "SubjectPublicKeyInfo: key is not a BIT STRING"
  end

  local bs, err_bs = asn1.decode_bit_string(fields[2].value)
  if not bs then return nil, "SubjectPublicKeyInfo BIT STRING: " .. (err_bs or "") end

  return {
    algorithm      = alg.oid,
    algorithm_name = alg.name,
    key_data       = bs.bits,
  }, nil
end

-- ── Extensions parser ─────────────────────────────────────────────────────────
--
-- Extensions ::= SEQUENCE OF Extension
-- Extension ::= SEQUENCE {
--   extnID    OID,
--   critical  BOOLEAN DEFAULT FALSE,
--   extnValue OCTET STRING
-- }

local function parse_extensions(node)
  -- node is the [3] EXPLICIT wrapper (context, constructed, tag 3)
  -- its value contains the SEQUENCE OF Extension
  local outer, err = asn1.decode_tlv(node.value, 1)
  if not outer then return nil, "extensions outer: " .. (err or "") end

  local ext_list, err2 = children(outer)
  if not ext_list then return nil, "extensions: " .. (err2 or "") end

  local result = {}
  for _, ext_node in ipairs(ext_list) do
    if not ext_node.constructed then
      return nil, "extension entry is not a SEQUENCE"
    end
    local fields, err3 = children(ext_node)
    if not fields then return nil, "extension fields: " .. (err3 or "") end
    if #fields < 2 then
      return nil, "extension: expected at least 2 fields"
    end

    local oid_node = fields[1]
    if oid_node.tag ~= asn1.TAG_OID then
      return nil, "extension: first field not OID"
    end
    local oid, _ = decode_oid_node(oid_node)
    if not oid then return nil, "extension OID decode failed" end

    local critical = false
    local value_node
    if #fields == 3 then
      -- critical BOOLEAN present
      local crit_val = asn1.decode_boolean(fields[2].value)
      critical = crit_val == true
      value_node = fields[3]
    else
      value_node = fields[2]
    end

    -- value_node is OCTET STRING wrapping the extension value
    local ext_value = value_node.value

    result[oid] = { critical = critical, value = ext_value }
  end

  return result, nil
end

-- ── TBSCertificate parser ─────────────────────────────────────────────────────
--
-- TBSCertificate ::= SEQUENCE {
--   version         [0] EXPLICIT INTEGER DEFAULT v1,
--   serialNumber    INTEGER,
--   signature       AlgorithmIdentifier,
--   issuer          Name,
--   validity        Validity,
--   subject         Name,
--   subjectPublicKeyInfo SubjectPublicKeyInfo,
--   extensions      [3] EXPLICIT Extensions OPTIONAL
-- }

local function parse_tbs(tbs_node)
  if not tbs_node.constructed then
    return nil, "TBSCertificate is not a SEQUENCE"
  end
  local fields, err = children(tbs_node)
  if not fields then return nil, "TBSCertificate: " .. (err or "") end

  local idx = 1
  local version = 1  -- default v1

  -- Optional [0] EXPLICIT version
  local first = fields[idx]
  if first and first.class_num == asn1.CLASS_CONTEXT and first.tag == 0 then
    -- Unwrap the explicit wrapper: decode the INTEGER inside
    local ver_node, err_v = asn1.decode_tlv(first.value, 1)
    if not ver_node then return nil, "version: " .. (err_v or "") end
    local ver_val, err_vi = asn1.decode_integer(ver_node.value)
    if ver_val == nil then return nil, "version integer: " .. (err_vi or "") end
    version = (ver_val --[[:! number]] + 1) --[[:! integer]]  -- DER: 0=v1, 1=v2, 2=v3
    idx = idx + 1
  end

  -- serialNumber INTEGER
  local serial_node = fields[idx]; idx = idx + 1
  if not serial_node then return nil, "TBSCertificate: missing serialNumber" end
  if serial_node.tag ~= asn1.TAG_INTEGER then
    return nil, "TBSCertificate: serialNumber not INTEGER (tag=" .. serial_node.tag .. ")"
  end
  local serial = to_hex(serial_node.value)

  -- signature AlgorithmIdentifier
  local sig_alg_node = fields[idx]; idx = idx + 1
  if not sig_alg_node then return nil, "TBSCertificate: missing signature algorithm" end
  local tbs_sig_alg, err_sa = parse_alg_id(sig_alg_node)
  if not tbs_sig_alg then return nil, "TBSCertificate signature alg: " .. (err_sa or "") end

  -- issuer Name
  local issuer_node = fields[idx]; idx = idx + 1
  if not issuer_node then return nil, "TBSCertificate: missing issuer" end
  local issuer, err_iss = parse_name(issuer_node.value)
  if not issuer then return nil, "issuer: " .. (err_iss or "") end

  -- validity Validity
  local validity_node = fields[idx]; idx = idx + 1
  if not validity_node then return nil, "TBSCertificate: missing validity" end
  local validity, err_val = parse_validity(validity_node)
  if not validity then return nil, "validity: " .. (err_val or "") end

  -- subject Name
  local subject_node = fields[idx]; idx = idx + 1
  if not subject_node then return nil, "TBSCertificate: missing subject" end
  local subject, err_subj = parse_name(subject_node.value)
  if not subject then return nil, "subject: " .. (err_subj or "") end

  -- subjectPublicKeyInfo
  local spki_node = fields[idx]; idx = idx + 1
  if not spki_node then return nil, "TBSCertificate: missing subjectPublicKeyInfo" end
  local public_key, err_pk = parse_spki(spki_node)
  if not public_key then return nil, "subjectPublicKeyInfo: " .. (err_pk or "") end

  -- Optional extensions [3]
  local extensions = nil
  while idx <= #fields do
    local f = fields[idx]; idx = idx + 1
    if f.class_num == asn1.CLASS_CONTEXT and f.tag == 3 and f.constructed then
      local exts, err_exts = parse_extensions(f)
      if not exts then return nil, "extensions: " .. (err_exts or "") end
      extensions = exts
    end
    -- skip [1] (issuerUniqueID) and [2] (subjectUniqueID) silently
  end

  return {
    version    = version,
    serial     = serial,
    sig_alg    = tbs_sig_alg,
    issuer     = issuer,
    validity   = validity,
    subject    = subject,
    public_key = public_key,
    extensions = extensions,
  }, nil
end

-- ── Certificate parser ────────────────────────────────────────────────────────
--
-- Certificate ::= SEQUENCE {
--   tbsCertificate     TBSCertificate,
--   signatureAlgorithm AlgorithmIdentifier,
--   signature          BIT STRING
-- }

--- Parse a DER-encoded X.509 certificate.
-- Returns: cert_table, nil  OR  nil, errmsg
--: (string) -> (X509Cert | nil, string | nil)
function M.parse_der(der)
  if type(der) ~= "string" or #der == 0 then
    return nil, "x509: input must be a non-empty string"
  end

  -- Outer SEQUENCE
  local outer, err = asn1.decode_tlv(der, 1)
  if not outer then return nil, "x509: outer TLV: " .. (err or "") end
  if outer.tag ~= asn1.TAG_SEQUENCE or not outer.constructed then
    return nil, "x509: not a SEQUENCE (tag=" .. outer.tag .. ")"
  end

  local top_fields, err2 = children(outer)
  if not top_fields then return nil, "x509: top-level fields: " .. (err2 or "") end
  if #top_fields < 3 then
    return nil, "x509: Certificate must have 3 fields, got " .. #top_fields
  end

  -- TBSCertificate
  local tbs, err_tbs = parse_tbs(top_fields[1])
  if not tbs then return nil, "x509: TBSCertificate: " .. (err_tbs or "") end

  -- signatureAlgorithm
  local sig_alg, err_alg = parse_alg_id(top_fields[2])
  if not sig_alg then return nil, "x509: signatureAlgorithm: " .. (err_alg or "") end

  -- signature BIT STRING (we store raw bytes but don't verify here)
  -- (top_fields[3] is the signature)

  -- Fingerprint (optional)
  local fp_sha256
  local sha256_mod = get_sha256()
  if sha256_mod then
    local sha256_mod_ = sha256_mod --[[: unknown]]
    local sha256_fn = (sha256_mod_ --[[:! { sha256: (string) -> string }]]).sha256
    local hex64 = sha256_fn(der)
    -- Insert colons every 2 chars
    local parts = {}
    for i = 1, #hex64, 2 do
      parts[#parts + 1] = hex64:sub(i, i + 1)
    end
    fp_sha256 = concat(parts, ":")
  end

  --:: X509Cert = { version: number, serial: string, subject: { [string]: string }, issuer: { [string]: string }, not_before: string, not_after: string, sig_algorithm: string, sig_algorithm_name: string | nil, public_key: { algorithm: string, algorithm_name: string | nil, key_data: string }, extensions: { [string]: { critical: boolean, value: string } } | nil, fingerprint_sha256: string | nil, raw: string }
  return ({
    version            = tbs.version,
    serial             = tbs.serial,
    subject            = tbs.subject,
    issuer             = tbs.issuer,
    not_before         = tbs.validity.not_before,
    not_after          = tbs.validity.not_after,
    sig_algorithm      = sig_alg.oid,
    sig_algorithm_name = sig_alg.name,
    public_key         = tbs.public_key,
    extensions         = tbs.extensions,
    fingerprint_sha256 = fp_sha256,
    raw                = der,
  } --[[:! X509Cert]]), nil
end

--- Parse a PEM-encoded X.509 certificate.
-- The PEM block label must be "CERTIFICATE".
-- Returns: cert_table, nil  OR  nil, errmsg
--: (string) -> (X509Cert | nil, string | nil)
function M.parse_pem(pem_str)
  if type(pem_str) ~= "string" or #pem_str == 0 then
    return nil, "x509: PEM input must be a non-empty string"
  end

  local block_, err = pem.decode(pem_str)
  if not block_ then return nil, "x509: PEM decode: " .. (err or "") end

  local block = block_ --[[: unknown]]
  local block_label = (block --[[:! { label: string, data: string, ... }]]).label
  local block_data  = (block --[[:! { label: string, data: string, ... }]]).data
  if block_label ~= "CERTIFICATE" then
    return nil, "x509: expected PEM label 'CERTIFICATE', got '" .. block_label .. "'"
  end

  return M.parse_der(block_data)
end

return M
