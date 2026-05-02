-- lib/ical/init.lua
-- iCalendar (RFC 5545) parser and builder.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, find, match, gmatch, gsub, rep, len =
  string.byte, string.char, string.sub, string.find, string.match,
  string.gmatch, string.gsub, string.rep, string.len
local concat, insert = table.concat, table.insert
local floor = math.floor

-- ---------------------------------------------------------------------------
-- Date/time utilities
-- ---------------------------------------------------------------------------

--- Parse an iCalendar DATE-TIME value.
-- Handles:
--   20260101T100000Z  → utc=true
--   20260101T100000   → utc=false (floating)
--   20260101          → date-only (hour/min/sec nil)
--: (string) -> ({ year: integer, month: integer, day: integer, hour: integer | nil, min: integer | nil, sec: integer | nil, utc: boolean | nil } | { year: integer, month: integer, day: integer } | nil, string | nil)
function M.parse_datetime(s)
  if not s then return nil, "nil input" end
  -- DATE-TIME: YYYYMMDDTHHmmss[Z]
  local year, month, day, hour, min, sec, utc =
    match(s, "^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)(Z?)$")
  if year then
    return {
      year  = tonumber(year) --[[:! integer]],
      month = tonumber(month) --[[:! integer]],
      day   = tonumber(day) --[[:! integer]],
      hour  = tonumber(hour) --[[:! integer]],
      min   = tonumber(min) --[[:! integer]],
      sec   = tonumber(sec) --[[:! integer]],
      utc   = utc == "Z",
    }
  end
  -- DATE: YYYYMMDD
  year, month, day = match(s, "^(%d%d%d%d)(%d%d)(%d%d)$")
  if year then
    return {
      year  = tonumber(year) --[[:! integer]],
      month = tonumber(month) --[[:! integer]],
      day   = tonumber(day) --[[:! integer]],
    }
  end
  return nil, "invalid datetime: " .. s
end

--- Parse an iCalendar DATE value.
--: (string) -> ({ year: integer, month: integer, day: integer } | nil, string | nil)
function M.parse_date(s)
  if not s then return nil, "nil input" end
  local year, month, day = match(s, "^(%d%d%d%d)(%d%d)(%d%d)$")
  if not year then return nil, "invalid date: " .. s end
  return { year = tonumber(year) --[[:! integer]], month = tonumber(month) --[[:! integer]], day = tonumber(day) --[[:! integer]] }
end

--- Format a datetime table to iCalendar DATE-TIME string.
--: ({ year: integer, month: integer, day: integer, hour: integer | nil, min: integer | nil, sec: integer | nil, utc: boolean | nil }) -> string
function M.format_datetime(dt)
  local d = string.format("%04d%02d%02d", dt.year, dt.month, dt.day)
  if dt.hour == nil then return d end
  local t = string.format("T%02d%02d%02d", dt.hour or 0, dt.min or 0, dt.sec or 0)
  return d .. t .. (dt.utc and "Z" or "")
end

--- Format a date table to iCalendar DATE string.
--: ({ year: integer, month: integer, day: integer }) -> string
function M.format_date(dt)
  return string.format("%04d%02d%02d", dt.year, dt.month, dt.day)
end

-- ---------------------------------------------------------------------------
-- RRULE parsing
-- ---------------------------------------------------------------------------

--- Parse an RRULE value string into a table.
-- Example: "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR"
--: (string) -> { freq: string | nil, interval: integer | nil, count: integer | nil, until: unknown | nil, byday: string[] | nil, bymonthday: integer[] | nil, bymonth: integer[] | nil, wkst: string | nil }
--:: RRule = { freq: string | nil, interval: integer | nil, count: integer | nil, until: unknown, byday: { [integer]: string } | nil, bymonthday: { [integer]: integer } | nil, bymonth: { [integer]: integer } | nil, wkst: string | nil, byhour: { [integer]: integer } | nil, byminute: { [integer]: integer } | nil, bysecond: { [integer]: integer } | nil, bysetpos: { [integer]: integer } | nil, [string]: unknown }
function M.parse_rrule(s)
  local r = {} --[[:! RRule]]
  for part in gmatch(s, "[^;]+") do
    local key, val = match(part, "^([^=]+)=(.*)$")
    key = key --[[:! string | nil]]
    val = val --[[:! string | nil]]
    if key and val then
      key = key:upper()
      if key == "FREQ" then
        r.freq = val:upper()
      elseif key == "INTERVAL" then
        r.interval = tonumber(val) --[[:! integer]]
      elseif key == "COUNT" then
        r.count = tonumber(val) --[[:! integer]]
      elseif key == "UNTIL" then
        r["until"] = M.parse_datetime(val) or val
      elseif key == "WKST" then
        local wkst_val = (val --[[:! string]]):upper() --: string
        r.wkst = wkst_val
      elseif key == "BYDAY" then
        r.byday = {} --: { [integer]: string }
        local byday_ = r.byday --[[:! { [integer]: string }]]
        for day in gmatch(val, "[^,]+") do
          insert(byday_, day:upper())
        end
      elseif key == "BYMONTHDAY" then
        r.bymonthday = {} --: { [integer]: integer }
        local bymonthday_ = r.bymonthday --[[:! { [integer]: integer }]]
        for d in gmatch(val, "[^,]+") do
          bymonthday_[#bymonthday_+1] = tonumber(d) --[[:! integer]]
        end
      elseif key == "BYMONTH" then
        r.bymonth = {} --: { [integer]: integer }
        local bymonth_ = r.bymonth --[[:! { [integer]: integer }]]
        for mo in gmatch(val, "[^,]+") do
          bymonth_[#bymonth_+1] = tonumber(mo) --[[:! integer]]
        end
      elseif key == "BYHOUR" then
        r.byhour = {} --: { [integer]: integer }
        local byhour_ = r.byhour --[[:! { [integer]: integer }]]
        for h in gmatch(val, "[^,]+") do byhour_[#byhour_+1] = tonumber(h) --[[:! integer]] end
      elseif key == "BYMINUTE" then
        r.byminute = {} --: { [integer]: integer }
        local byminute_ = r.byminute --[[:! { [integer]: integer }]]
        for m in gmatch(val, "[^,]+") do byminute_[#byminute_+1] = tonumber(m) --[[:! integer]] end
      elseif key == "BYSECOND" then
        r.bysecond = {} --: { [integer]: integer }
        local bysecond_ = r.bysecond --[[:! { [integer]: integer }]]
        for sec in gmatch(val, "[^,]+") do bysecond_[#bysecond_+1] = tonumber(sec) --[[:! integer]] end
      elseif key == "BYSETPOS" then
        r.bysetpos = {} --: { [integer]: integer }
        local bysetpos_ = r.bysetpos --[[:! { [integer]: integer }]]
        for p in gmatch(val, "[^,]+") do bysetpos_[#bysetpos_+1] = tonumber(p) --[[:! integer]] end
      else
        r[key:lower()] = val
      end
    end
  end
  return r
end

--- Format an RRULE table back to string.
--: (r: RRule) -> string
function M.format_rrule(r)
  local parts = {}
  if r.freq     then insert(parts, "FREQ=" .. r.freq:upper()) end
  if r.interval then insert(parts, "INTERVAL=" .. r.interval) end
  if r.count    then insert(parts, "COUNT=" .. r.count) end
  if r["until"] then
    local u = r["until"]
    if type(u) == "table" then
      insert(parts, "UNTIL=" .. M.format_datetime(u))
    else
      insert(parts, "UNTIL=" .. tostring(u))
    end
  end
  if r.byday and #r.byday > 0 then
    insert(parts, "BYDAY=" .. concat(r.byday, ","))
  end
  if r.bymonthday and #r.bymonthday > 0 then
    insert(parts, "BYMONTHDAY=" .. concat(r.bymonthday, ","))
  end
  if r.bymonth and #r.bymonth > 0 then
    insert(parts, "BYMONTH=" .. concat(r.bymonth, ","))
  end
  if r.wkst then insert(parts, "WKST=" .. r.wkst:upper()) end
  return concat(parts, ";")
end

-- ---------------------------------------------------------------------------
-- Content-line parser
-- ---------------------------------------------------------------------------

--- Parse a single iCalendar content line (after unfolding).
-- Returns { name, params, value } or nil, errmsg.
--: (string) -> ({ name: string, params: { [string]: string }, value: string } | nil, string | nil)
function M.parse_property(line)
  if not line or line == "" then return nil, "empty line" end

  -- Split name+params from value at first unescaped ':'
  -- Property name may have params: NAME;PARAM=VAL:value
  local colon_pos = find(line, ":", 1, true)
  if not colon_pos then
    return nil, "missing colon in property: " .. line
  end

  local name_part = sub(line, 1, colon_pos - 1)
  local value     = sub(line, colon_pos + 1)

  -- Parse name and parameters from name_part
  -- Format: NAME[;PARAM=value[;PARAM=value...]]
  local params = {}
  local name

  -- Split by semicolons, first token is the property name
  local tokens = {} --: { [integer]: string }
  -- We need to be careful: param values can be quoted strings containing semicolons
  local i = 1
  local current = {} --: { [integer]: string }
  local in_quote = false
  local nlen = len(name_part)
  while i <= nlen do
    local c = sub(name_part, i, i)
    if c == '"' then
      in_quote = not in_quote
      insert(current, c)
    elseif c == ";" and not in_quote then
      insert(tokens, concat(current))
      current = {} --: { [integer]: string }
    else
      insert(current, c)
    end
    i = i + 1
  end
  insert(tokens, concat(current))

  name = tokens[1] and tokens[1]:upper() or ""
  if name == "" then return nil, "empty property name" end

  for j = 2, #tokens do
    local tok = tokens[j]
    local eq = find(tok, "=", 1, true)
    if eq then
      local pname = sub(tok, 1, eq - 1):upper()
      local pval  = sub(tok, eq + 1)
      -- Strip surrounding quotes from param value
      if sub(pval, 1, 1) == '"' and sub(pval, -1) == '"' then
        pval = sub(pval, 2, -2)
      end
      params[pname] = pval
    else
      -- Boolean param (no value)
      params[tok:upper()] = true
    end
  end

  return { name = name, params = params, value = value }
end

-- ---------------------------------------------------------------------------
-- Content-line unfolding
-- ---------------------------------------------------------------------------

--- Unfold RFC 5545 content lines (CRLF + whitespace continuation).
--: (string) -> string[]
local function unfold_lines(s)
  -- Normalize line endings to \n
  s = gsub(s, "\r\n", "\n")
  s = gsub(s, "\r", "\n")
  -- Unfold: CRLF followed by a space or tab is a continuation
  s = gsub(s, "\n[ \t]", "")
  -- Split on newlines
  local lines = {}
  for line in gmatch(s, "[^\n]+") do
    insert(lines, line)
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Component parser helpers
-- ---------------------------------------------------------------------------

local DATETIME_PROPS = {
  DTSTART=true, DTEND=true, DUE=true, DTSTAMP=true,
  CREATED=true, ["LAST-MODIFIED"]=true, COMPLETED=true,
  RECURRENCE_ID=true, EXDATE=true, RDATE=true,
}

--: (name: string) -> string
local function prop_key(name)
  -- Convert property name to a Lua-friendly field name
  local s, _ = name:lower():gsub("-", "_")
  return s
end

--:: ICalProp = { name: string, value: string, params: { [string]: unknown } | nil }
--- Parse a datetime/date property value, honouring VALUE=DATE parameter.
--: (prop: ICalProp) -> ({ year: integer, month: integer, day: integer, hour: integer | nil, min: integer | nil, sec: integer | nil, utc: boolean | nil } | { year: integer, month: integer, day: integer } | nil, string | nil)
local function parse_dt_prop(prop)
  local val = prop.value
  -- If VALUE=DATE param is set, parse as date only
  if prop.params and prop.params.VALUE == "DATE" then
    return M.parse_date(val)
  end
  return M.parse_datetime(val)
end

--- Parse a VALARM sub-component from a slice of lines [start_idx, end_idx].
local function parse_valarm(lines, start_idx, end_idx)
  local alarm = {}
  for i = start_idx, end_idx do
    local prop, err = M.parse_property(lines[i])
    if prop then
      local k = prop_key(prop.name)
      if prop.name == "TRIGGER" then
        alarm.trigger = prop.value
        if prop.params then alarm.trigger_params = prop.params end
      elseif prop.name == "ACTION" then
        alarm.action = prop.value:upper()
      elseif prop.name == "DESCRIPTION" then
        alarm.description = prop.value
      elseif prop.name == "SUMMARY" then
        alarm.summary = prop.value
      elseif prop.name == "DURATION" then
        alarm.duration = prop.value
      elseif prop.name == "REPEAT" then
        alarm.repeat_count = tonumber(prop.value)
      else
        alarm[k] = prop.value
      end
    end
  end
  return alarm
end

--- Parse a VEVENT or VTODO component from a slice of lines.
local function parse_component(lines, start_idx, end_idx, comp_type)
  local comp = {} --[[:! { _alarms: { [integer]: unknown } | nil, alarms: { [integer]: unknown } | nil, [string]: unknown }]]
  comp._alarms = {} --: { [integer]: unknown }
  local i = start_idx
  while i <= end_idx do
    local line = lines[i]
    if line == "BEGIN:VALARM" then
      -- Find matching END:VALARM
      local alarm_start = i + 1
      local j = i + 1
      while j <= end_idx and lines[j] ~= "END:VALARM" do
        j = j + 1
      end
      local alarms_ = comp._alarms --[[:! { [integer]: unknown }]]
      alarms_[#alarms_+1] = parse_valarm(lines, alarm_start, j - 1) --[[: any]]
      i = j + 1
    else
      local prop, err = M.parse_property(line)
      if prop then
        local k = prop_key(prop.name)
        if DATETIME_PROPS[prop.name] then
          local dt = parse_dt_prop(prop)
          if dt then comp[k] = dt end
          -- Preserve tzid if present
          if prop.params and prop.params.TZID then
            comp[k .. "_tzid"] = prop.params.TZID
          end
        elseif prop.name == "RRULE" then
          comp.rrule = M.parse_rrule(prop.value)
        elseif prop.name == "EXDATE" then
          if not comp.exdate then comp.exdate = {} end
          local exdate_ = comp.exdate --[[:! { [integer]: unknown }]]
          local dt = parse_dt_prop(prop)
          if dt then exdate_[#exdate_+1] = dt --[[: any]] end
        elseif prop.name == "RDATE" then
          if not comp.rdate then comp.rdate = {} end
          local rdate_ = comp.rdate --[[:! { [integer]: unknown }]]
          local dt = parse_dt_prop(prop)
          if dt then rdate_[#rdate_+1] = dt --[[: any]] end
        elseif prop.name == "CATEGORIES" then
          comp.categories = {} --: { [integer]: string }
          local categories_ = comp.categories --[[:! { [integer]: string }]]
          for cat in gmatch(prop.value, "[^,]+") do
            insert(categories_, cat)
          end
        elseif prop.name == "ATTENDEE" then
          if not comp.attendees then comp.attendees = {} end
          local attendees_ = comp.attendees --[[:! { [integer]: unknown }]]
          local att = {} --[[:! { value: string, [string]: unknown }]]
          att.value = prop.value
          if prop.params then
            for pk, pv in pairs(prop.params --[[:! { [string]: unknown }]]) do
              att[pk:lower()] = pv
            end
          end
          attendees_[#attendees_+1] = att --[[: any]]
        elseif prop.name == "ORGANIZER" then
          comp.organizer = { value = prop.value }
          if prop.params then
            for pk, pv in pairs(prop.params) do
              comp.organizer[pk:lower()] = pv
            end
          end
        else
          -- Store scalar props; VALUE param indicates type
          if prop.params and next(prop.params) ~= nil then
            -- Store params alongside value for extensibility
            comp[k] = prop.value
            comp[k .. "_params"] = prop.params
          else
            comp[k] = prop.value
          end
        end
      end
      i = i + 1
    end
  end
  -- Expose alarms as comp.alarms only if non-empty
  local alarms_final = comp._alarms --[[:! { [integer]: unknown }]]
  if #alarms_final > 0 then
    comp.alarms = alarms_final
  end
  comp._alarms = nil -- cleared after move to comp.alarms
  return comp
end

-- ---------------------------------------------------------------------------
-- Main parser
-- ---------------------------------------------------------------------------

--- Parse an iCalendar string into a calendar table.
--: (string) -> ({ version: string | nil, prodid: string | nil, calscale: string | nil, method: string | nil, events: unknown, todos: unknown, journals: unknown, freebusys: unknown, timezones: unknown } | nil, string | nil)
function M.parse(s)
  if not s then return nil, "nil input" end

  local lines = unfold_lines(s)
  if #lines == 0 then return nil, "empty input" end

  -- Must start with BEGIN:VCALENDAR
  if lines[1]:upper() ~= "BEGIN:VCALENDAR" then
    return nil, "missing BEGIN:VCALENDAR"
  end

  --:: CalResult = { events: { [integer]: unknown }, todos: { [integer]: unknown }, journals: { [integer]: unknown }, freebusys: { [integer]: unknown }, timezones: { [integer]: unknown }, version: string | nil, prodid: string | nil, calscale: string | nil, method: string | nil, [string]: unknown }
  local cal = {} --[[:! CalResult]]
  cal.events    = {} --: { [integer]: unknown }
  cal.todos     = {} --: { [integer]: unknown }
  cal.journals  = {} --: { [integer]: unknown }
  cal.freebusys = {} --: { [integer]: unknown }
  cal.timezones = {} --: { [integer]: unknown }

  local i = 2
  while i <= #lines do
    local line = lines[i]
    local upper = line:upper()

    if upper == "END:VCALENDAR" then
      break
    elseif upper:find("^BEGIN:VEVENT") then
      -- Find matching END:VEVENT
      local comp_start = i + 1
      local j = i + 1
      local depth = 1
      while j <= #lines do
        local ul = lines[j]:upper()
        if ul:find("^BEGIN:") then depth = depth + 1
        elseif ul:find("^END:VEVENT") then
          depth = depth - 1
          if depth == 0 then break end
        end
        j = j + 1
      end
      local ev_ = cal.events --[[:! { [integer]: unknown }]]
      ev_[#ev_+1] = parse_component(lines, comp_start, j - 1, "VEVENT") --[[: any]]
      i = j + 1
    elseif upper:find("^BEGIN:VTODO") then
      local comp_start = i + 1
      local j = i + 1
      local depth = 1
      while j <= #lines do
        local ul = lines[j]:upper()
        if ul:find("^BEGIN:") then depth = depth + 1
        elseif ul:find("^END:VTODO") then
          depth = depth - 1
          if depth == 0 then break end
        end
        j = j + 1
      end
      local todos_ = cal.todos --[[:! { [integer]: unknown }]]
      todos_[#todos_+1] = parse_component(lines, comp_start, j - 1, "VTODO") --[[: any]]
      i = j + 1
    elseif upper:find("^BEGIN:VJOURNAL") then
      local comp_start = i + 1
      local j = i + 1
      while j <= #lines and lines[j]:upper() ~= "END:VJOURNAL" do j = j + 1 end
      local jnl_ = cal.journals --[[:! { [integer]: unknown }]]
      jnl_[#jnl_+1] = parse_component(lines, comp_start, j - 1, "VJOURNAL") --[[: any]]
      i = j + 1
    elseif upper:find("^BEGIN:VFREEBUSY") then
      local comp_start = i + 1
      local j = i + 1
      while j <= #lines and lines[j]:upper() ~= "END:VFREEBUSY" do j = j + 1 end
      local fb_ = cal.freebusys --[[:! { [integer]: unknown }]]
      fb_[#fb_+1] = parse_component(lines, comp_start, j - 1, "VFREEBUSY") --[[: any]]
      i = j + 1
    elseif upper:find("^BEGIN:VTIMEZONE") then
      local comp_start = i + 1
      local j = i + 1
      while j <= #lines and lines[j]:upper() ~= "END:VTIMEZONE" do j = j + 1 end
      local tz_ = cal.timezones --[[:! { [integer]: unknown }]]
      tz_[#tz_+1] = parse_component(lines, comp_start, j - 1, "VTIMEZONE") --[[: any]]
      i = j + 1
    elseif upper:find("^BEGIN:") then
      -- Unknown component: skip
      local begin_name = match(upper, "^BEGIN:(.+)$")
      local j = i + 1
      while j <= #lines and not lines[j]:upper():find("^END:" .. begin_name) do
        j = j + 1
      end
      i = j + 1
    else
      -- Calendar-level property
      local prop = M.parse_property(line)
      if prop then
        local k = prop_key(prop.name)
        cal[k] = prop.value
      end
      i = i + 1
    end
  end

  return cal
end

-- ---------------------------------------------------------------------------
-- Line folding
-- ---------------------------------------------------------------------------

--- Fold a content line to max 75 octets per line (RFC 5545 §3.1).
-- Continuation lines begin with a single space.
--: (string) -> string
local function fold_line(line)
  -- RFC 5545: lines SHOULD NOT be longer than 75 octets (not characters).
  -- We fold at octet boundaries; for ASCII content this equals characters.
  if len(line) <= 75 then return line end
  local out = {}
  local pos = 1
  local first = true
  while pos <= len(line) do
    local chunk_len = first and 75 or 74
    -- Don't split a multi-byte UTF-8 sequence mid-byte
    local e = pos + chunk_len - 1
    if e >= len(line) then
      insert(out, sub(line, pos))
      break
    end
    -- Walk back from e until we're at a safe UTF-8 boundary
    while e > pos do
      local b = byte(line, e)
      -- If b is a continuation byte (10xxxxxx), step back
      if b >= 0x80 and b < 0xC0 then
        e = e - 1
      else
        break
      end
    end
    insert(out, sub(line, pos, e))
    pos = e + 1
    first = false
  end
  return concat(out, "\r\n ")
end

-- ---------------------------------------------------------------------------
-- Builder
-- ---------------------------------------------------------------------------

--- Escape special characters in iCalendar TEXT values.
--: (string) -> string
local function escape_text(s)
  s = gsub(s, "\\", "\\\\")
  s = gsub(s, ";", "\\;")
  s = gsub(s, ",", "\\,")
  s = gsub(s, "\n", "\\n")
  s = gsub(s, "\r\n", "\\n")
  return s
end

--- Unescape iCalendar TEXT values.
--: (string) -> string
function M.unescape_text(s)
  s = gsub(s, "\\n", "\n")
  s = gsub(s, "\\N", "\n")
  s = gsub(s, "\\,", ",")
  s = gsub(s, "\\;", ";")
  s = gsub(s, "\\\\", "\\")
  return s
end

--- Add a property line to a lines table, with optional parameters.
--: ({ [integer]: string }, string, unknown, { [string]: unknown } | nil) -> nil
local function add_prop(lines, name, value, params)
  if value == nil then return end
  local parts = { name }
  if params then
    for k, v in pairs(params) do
      if v == true then
        insert(parts, ";" .. k)
      else
        -- Quote value if it contains special chars
        local vs = tostring(v)
        if find(vs, "[;:,]") then
          insert(parts, ";" .. k .. '="' .. vs .. '"')
        else
          insert(parts, ";" .. k .. "=" .. vs)
        end
      end
    end
  end
  local prop_line = concat(parts) .. ":" .. tostring(value)
  insert(lines, fold_line(prop_line))
end

--:: ICalDt = { year: integer, month: integer, day: integer, hour: integer | nil, min: integer | nil, sec: integer | nil, utc: boolean | nil }
--:: ICalAlarm = { action: string | nil, trigger: string | nil, trigger_params: { [string]: unknown } | nil, description: string | nil, summary: string | nil, duration: string | nil, repeat_count: number | nil, [string]: unknown }
--:: ICalComponent = { uid: string | nil, dtstart: ICalDt | nil, dtend: ICalDt | nil, dtstamp: ICalDt | nil, created: ICalDt | nil, last_modified: ICalDt | nil, due: ICalDt | nil, completed: ICalDt | nil, dtstart_tzid: string | nil, dtend_tzid: string | nil, dtstamp_tzid: string | nil, summary: string | nil, description: string | nil, location: string | nil, status: string | nil, transp: string | nil, class: string | nil, priority: string | nil, sequence: string | nil, url: string | nil, comment: string | nil, percent_complete: string | nil, rrule: RRule | nil, exdate: { [integer]: ICalDt } | nil, rdate: { [integer]: ICalDt } | nil, categories: { [integer]: string } | nil, organizer: { value: string, cn: string | nil, [string]: unknown } | nil, attendees: { [integer]: { value: string, [string]: unknown } } | nil, alarms: { [integer]: ICalAlarm } | nil, [string]: unknown }

--- Add a datetime property (handles date-only vs date-time).
--: (lines: { [integer]: string }, name: string, dt: ICalDt | nil, tzid: string | nil) -> nil
local function add_dt_prop(lines, name, dt, tzid)
  if not dt then return end
  local params = nil
  if tzid then
    params = { TZID = tzid }
  elseif dt.hour == nil then
    params = { VALUE = "DATE" }
  end
  add_prop(lines, name, M.format_datetime(dt), params)
end

--- Serialize a VEVENT component to lines.
--: (ev: ICalComponent) -> { [integer]: string }
local function event_to_lines(ev)
  local lines = { "BEGIN:VEVENT" }
  add_prop(lines, "UID",         ev.uid)
  add_dt_prop(lines, "DTSTART",  ev.dtstart,  ev.dtstart_tzid)
  add_dt_prop(lines, "DTEND",    ev.dtend,    ev.dtend_tzid)
  add_dt_prop(lines, "DTSTAMP",  ev.dtstamp,  ev.dtstamp_tzid)
  add_dt_prop(lines, "CREATED",  ev.created)
  add_dt_prop(lines, "LAST-MODIFIED", ev.last_modified)
  add_prop(lines, "SUMMARY",     ev.summary and escape_text(ev.summary))
  add_prop(lines, "DESCRIPTION", ev.description and escape_text(ev.description))
  add_prop(lines, "LOCATION",    ev.location and escape_text(ev.location))
  add_prop(lines, "STATUS",      ev.status)
  add_prop(lines, "TRANSP",      ev.transp)
  add_prop(lines, "CLASS",       ev.class)
  add_prop(lines, "PRIORITY",    ev.priority)
  add_prop(lines, "SEQUENCE",    ev.sequence)
  add_prop(lines, "URL",         ev.url)
  add_prop(lines, "COMMENT",     ev.comment and escape_text(ev.comment))
  if ev.rrule then
    add_prop(lines, "RRULE", M.format_rrule(ev.rrule))
  end
  if ev.exdate then
    for _, dt in ipairs(ev.exdate) do
      add_dt_prop(lines, "EXDATE", dt)
    end
  end
  if ev.rdate then
    for _, dt in ipairs(ev.rdate) do
      add_dt_prop(lines, "RDATE", dt)
    end
  end
  if ev.categories and #ev.categories > 0 then
    add_prop(lines, "CATEGORIES", concat(ev.categories, ","))
  end
  if ev.organizer then
    add_prop(lines, "ORGANIZER", ev.organizer.value or ev.organizer,
      ev.organizer.cn and { CN = ev.organizer.cn } or nil)
  end
  if ev.attendees then
    for _, att in ipairs(ev.attendees) do
      local params = {}
      for k, v in pairs(att) do
        if k ~= "value" then params[k:upper()] = v end
      end
      add_prop(lines, "ATTENDEE", att.value, next(params) ~= nil and params or nil)
    end
  end
  -- VALARM sub-components
  if ev.alarms then
    for _, alarm in ipairs(ev.alarms) do
      insert(lines, "BEGIN:VALARM")
      add_prop(lines, "ACTION",      alarm.action)
      if alarm.trigger then
        add_prop(lines, "TRIGGER", alarm.trigger, alarm.trigger_params)
      end
      add_prop(lines, "DESCRIPTION", alarm.description and escape_text(alarm.description --[[:! string]]))
      add_prop(lines, "SUMMARY",     alarm.summary and escape_text(alarm.summary --[[:! string]]))
      add_prop(lines, "DURATION",    alarm.duration)
      if alarm.repeat_count then
        add_prop(lines, "REPEAT", alarm.repeat_count)
      end
      insert(lines, "END:VALARM")
    end
  end
  insert(lines, "END:VEVENT")
  return lines
end

--- Serialize a VTODO component to lines.
--: (td: ICalComponent) -> { [integer]: string }
local function todo_to_lines(td)
  local lines = { "BEGIN:VTODO" }
  add_prop(lines, "UID",         td.uid)
  add_dt_prop(lines, "DTSTART",  td.dtstart)
  add_dt_prop(lines, "DUE",      td.due)
  add_dt_prop(lines, "COMPLETED", td.completed)
  add_dt_prop(lines, "DTSTAMP",  td.dtstamp)
  add_dt_prop(lines, "CREATED",  td.created)
  add_dt_prop(lines, "LAST-MODIFIED", td.last_modified)
  add_prop(lines, "SUMMARY",     td.summary and escape_text(td.summary))
  add_prop(lines, "DESCRIPTION", td.description and escape_text(td.description))
  add_prop(lines, "STATUS",      td.status)
  add_prop(lines, "PRIORITY",    td.priority)
  add_prop(lines, "PERCENT-COMPLETE", td.percent_complete)
  add_prop(lines, "CLASS",       td.class)
  add_prop(lines, "URL",         td.url)
  add_prop(lines, "COMMENT",     td.comment and escape_text(td.comment))
  if td.categories and #td.categories > 0 then
    add_prop(lines, "CATEGORIES", concat(td.categories, ","))
  end
  if td.rrule then
    add_prop(lines, "RRULE", M.format_rrule(td.rrule))
  end
  if td.alarms then
    for _, alarm in ipairs(td.alarms) do
      insert(lines, "BEGIN:VALARM")
      add_prop(lines, "ACTION",      alarm.action)
      if alarm.trigger then
        add_prop(lines, "TRIGGER", alarm.trigger, alarm.trigger_params)
      end
      add_prop(lines, "DESCRIPTION", alarm.description and escape_text(alarm.description --[[:! string]]))
      insert(lines, "END:VALARM")
    end
  end
  insert(lines, "END:VTODO")
  return lines
end

-- ---------------------------------------------------------------------------
-- Calendar builder
-- ---------------------------------------------------------------------------

--- Create a new calendar builder.
--: ({ prodid: string | nil, version: string | nil, calscale: string | nil, method: string | nil } | nil) -> unknown
function M.calendar(opts)
  local opts_ = (opts or {}) --[[:! { prodid: string | nil, version: string | nil, calscale: string | nil, method: string | nil }]]
  local cal = {
    _version  = opts_.version  or "2.0",
    _prodid   = opts_.prodid   or "-//crescent//ical//EN",
    _calscale = opts_.calscale,
    _method   = opts_.method,
    _events   = {},
    _todos    = {},
    _timezones = {},
  }

  --- Add a VEVENT to this calendar.
  function cal:add_event(ev)
    insert(self._events, ev)
    return self
  end

  --- Add a VTODO to this calendar.
  function cal:add_todo(td)
    insert(self._todos, td)
    return self
  end

  --- Serialize the calendar to an iCalendar string.
  function cal:to_string()
    local lines = {}
    insert(lines, "BEGIN:VCALENDAR")
    add_prop(lines, "VERSION",  self._version)
    add_prop(lines, "PRODID",   self._prodid)
    if self._calscale then add_prop(lines, "CALSCALE", self._calscale) end
    if self._method   then add_prop(lines, "METHOD",   self._method)   end
    for _, ev in ipairs(self._events) do
      for _, l in ipairs(event_to_lines(ev)) do insert(lines, l) end
    end
    for _, td in ipairs(self._todos) do
      for _, l in ipairs(todo_to_lines(td)) do insert(lines, l) end
    end
    insert(lines, "END:VCALENDAR")
    -- RFC 5545 requires CRLF line endings
    return concat(lines, "\r\n") .. "\r\n"
  end

  return cal
end

return M
