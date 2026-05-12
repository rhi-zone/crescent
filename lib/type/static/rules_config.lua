-- lib/type/static/rules_config.lua
-- Rule configuration helpers: look up effective severity for a diagnostic code
-- and apply allow-list glob filtering.

local M = {}

-- Resolve effective severity for a diagnostic code given rules_config.
-- rules_config: { [rule_name]: { severity?, enabled?, allow? } } | nil
-- rule_defaults: { [code]: { severity, name } }
-- Returns: "error" | "warning" | "info" | "off"
--: (integer, { [string]: { severity?: string, enabled?: boolean, allow?: { [integer]: string, ... }, ... }, ... } | nil, { [integer]: { name: string, severity: string }, ... }) -> string
function M.effective_severity(code, rules_config, rule_defaults)
    local def = rule_defaults[code]
    if not def then return "warning" end  -- unknown code: default warning
    local default_sev = def.severity
    if not rules_config then return default_sev end
    local rule_name = def.name
    local cfg = rules_config[rule_name]
    if not cfg then return default_sev end
    -- enabled = false is equivalent to severity = "off"
    local enabled = cfg.enabled
    if enabled == false then return "off" end
    local sev = cfg.severity
    if sev == "error" or sev == "warning" or sev == "info" or sev == "off" then
        return sev --[[:! string]]
    end
    return default_sev
end

-- Check whether a file path matches any of the allow patterns.
-- Returns true if the diagnostic should be suppressed.
--: (string, { [integer]: string, ... } | nil) -> boolean
function M.is_allowed(filepath, allow_patterns)
    if not allow_patterns then return false end
    local n = #(allow_patterns --[[:! { [integer]: string, ... }]])
    if n == 0 then return false end
    local glob = require("lib.glob")
    for _, pat in ipairs(allow_patterns) do
        local m = glob.compile(pat)
        if m and m:match(filepath) then return true end
    end
    return false
end

-- Get the allow list for a given diagnostic code from rules_config.
--: (integer, { [string]: { severity?: string, enabled?: boolean, allow?: { [integer]: string, ... }, ... }, ... } | nil, { [integer]: { name: string, severity: string }, ... }) -> { [integer]: string, ... } | nil
function M.allow_patterns(code, rules_config, rule_defaults)
    if not rules_config then return nil end
    local def = rule_defaults[code]
    if not def then return nil end
    local cfg = rules_config[def.name]
    if not cfg then return nil end
    return cfg.allow
end

return M
