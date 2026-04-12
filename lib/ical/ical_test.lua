-- lib/ical/ical_test.lua
-- Tests for the iCalendar (RFC 5545) parser and builder.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local ical = require("lib.ical")
local T = require("lib.test.assert")

-- ---------------------------------------------------------------------------
-- parse_datetime
-- ---------------------------------------------------------------------------

T.describe("parse_datetime", function()
  T.it("UTC datetime", function()
    local dt = ical.parse_datetime("20260101T100000Z")
    T.ok(dt ~= nil)
    T.eq(dt.year,  2026)
    T.eq(dt.month, 1)
    T.eq(dt.day,   1)
    T.eq(dt.hour,  10)
    T.eq(dt.min,   0)
    T.eq(dt.sec,   0)
    T.eq(dt.utc,   true)
  end)

  T.it("floating datetime", function()
    local dt = ical.parse_datetime("20260315T143000")
    T.ok(dt ~= nil)
    T.eq(dt.year,  2026)
    T.eq(dt.month, 3)
    T.eq(dt.day,   15)
    T.eq(dt.hour,  14)
    T.eq(dt.min,   30)
    T.eq(dt.sec,   0)
    T.eq(dt.utc,   false)
  end)

  T.it("date-only (no time)", function()
    local dt = ical.parse_datetime("20260401")
    T.ok(dt ~= nil)
    T.eq(dt.year,  2026)
    T.eq(dt.month, 4)
    T.eq(dt.day,   1)
    T.eq(dt.hour,  nil)
  end)

  T.it("invalid input returns nil, errmsg", function()
    local dt, err = ical.parse_datetime("not-a-date")
    T.eq(dt, nil)
    T.ok(err ~= nil)
  end)

  T.it("nil input returns nil, errmsg", function()
    local dt, err = ical.parse_datetime(nil)
    T.eq(dt, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- parse_date
-- ---------------------------------------------------------------------------

T.describe("parse_date", function()
  T.it("parses YYYYMMDD", function()
    local d = ical.parse_date("20261231")
    T.ok(d ~= nil)
    T.eq(d.year,  2026)
    T.eq(d.month, 12)
    T.eq(d.day,   31)
  end)

  T.it("invalid returns nil, errmsg", function()
    local d, err = ical.parse_date("bad")
    T.eq(d, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- format_datetime / format_date round-trips
-- ---------------------------------------------------------------------------

T.describe("format_datetime", function()
  T.it("UTC round-trip", function()
    local s = "20260101T100000Z"
    local dt = ical.parse_datetime(s)
    T.eq(ical.format_datetime(dt), s)
  end)

  T.it("floating round-trip", function()
    local s = "20260315T143000"
    local dt = ical.parse_datetime(s)
    T.eq(ical.format_datetime(dt), s)
  end)

  T.it("date-only round-trip via format_date", function()
    local s = "20261231"
    local dt = ical.parse_date(s)
    T.eq(ical.format_date(dt), s)
  end)

  T.it("date-only via format_datetime", function()
    local dt = { year=2026, month=6, day=1 }
    T.eq(ical.format_datetime(dt), "20260601")
  end)

  T.it("zero-padded fields", function()
    local dt = { year=2026, month=1, day=5, hour=9, min=3, sec=7, utc=true }
    T.eq(ical.format_datetime(dt), "20260105T090307Z")
  end)
end)

-- ---------------------------------------------------------------------------
-- parse_property
-- ---------------------------------------------------------------------------

T.describe("parse_property", function()
  T.it("simple property", function()
    local p = ical.parse_property("SUMMARY:Team Meeting")
    T.ok(p ~= nil)
    T.eq(p.name,  "SUMMARY")
    T.eq(p.value, "Team Meeting")
    T.eq(next(p.params), nil)
  end)

  T.it("property with TZID parameter", function()
    local p = ical.parse_property("DTSTART;TZID=America/New_York:20260101T100000")
    T.ok(p ~= nil)
    T.eq(p.name,         "DTSTART")
    T.eq(p.value,        "20260101T100000")
    T.eq(p.params.TZID,  "America/New_York")
  end)

  T.it("property with VALUE=DATE parameter", function()
    local p = ical.parse_property("DTSTART;VALUE=DATE:20260101")
    T.ok(p ~= nil)
    T.eq(p.name,        "DTSTART")
    T.eq(p.value,       "20260101")
    T.eq(p.params.VALUE,"DATE")
  end)

  T.it("property with multiple parameters", function()
    local p = ical.parse_property("ATTENDEE;CN=John Doe;RSVP=TRUE:mailto:john@example.com")
    T.ok(p ~= nil)
    T.eq(p.name,       "ATTENDEE")
    T.eq(p.value,      "mailto:john@example.com")
    T.eq(p.params.CN,  "John Doe")
    T.eq(p.params.RSVP,"TRUE")
  end)

  T.it("property with quoted param value", function()
    local p = ical.parse_property('ORGANIZER;CN="Jane Smith":mailto:jane@example.com')
    T.ok(p ~= nil)
    T.eq(p.params.CN, "Jane Smith")
  end)

  T.it("property with colon in value", function()
    local p = ical.parse_property("URL:https://example.com/event?id=1")
    T.ok(p ~= nil)
    T.eq(p.name,  "URL")
    T.eq(p.value, "https://example.com/event?id=1")
  end)

  T.it("missing colon returns nil, errmsg", function()
    local p, err = ical.parse_property("SUMMARY no colon here")
    T.eq(p, nil)
    T.ok(err ~= nil)
  end)

  T.it("empty line returns nil, errmsg", function()
    local p, err = ical.parse_property("")
    T.eq(p, nil)
    T.ok(err ~= nil)
  end)

  T.it("property name is uppercased", function()
    local p = ical.parse_property("summary:hello")
    T.ok(p ~= nil)
    T.eq(p.name, "SUMMARY")
  end)
end)

-- ---------------------------------------------------------------------------
-- parse_rrule
-- ---------------------------------------------------------------------------

T.describe("parse_rrule", function()
  T.it("weekly with byday", function()
    local r = ical.parse_rrule("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR")
    T.eq(r.freq,     "WEEKLY")
    T.eq(r.interval, 1)
    T.eq(r.byday[1], "MO")
    T.eq(r.byday[2], "WE")
    T.eq(r.byday[3], "FR")
    T.eq(#r.byday, 3)
  end)

  T.it("daily with count", function()
    local r = ical.parse_rrule("FREQ=DAILY;COUNT=10")
    T.eq(r.freq,  "DAILY")
    T.eq(r.count, 10)
  end)

  T.it("monthly with bymonthday", function()
    local r = ical.parse_rrule("FREQ=MONTHLY;BYMONTHDAY=1,15")
    T.eq(r.freq,            "MONTHLY")
    T.eq(r.bymonthday[1],   1)
    T.eq(r.bymonthday[2],   15)
  end)

  T.it("with until datetime", function()
    local r = ical.parse_rrule("FREQ=DAILY;UNTIL=20261231T235959Z")
    T.eq(r.freq,           "DAILY")
    T.ok(type(r["until"]) == "table")
    T.eq(r["until"].year,     2026)
    T.eq(r["until"].month,    12)
    T.eq(r["until"].day,      31)
    T.eq(r["until"].utc,      true)
  end)

  T.it("yearly", function()
    local r = ical.parse_rrule("FREQ=YEARLY;BYMONTH=1;BYDAY=MO")
    T.eq(r.freq,         "YEARLY")
    T.eq(r.bymonth[1],   1)
    T.eq(r.byday[1],     "MO")
  end)

  T.it("format_rrule round-trip", function()
    local s = "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH"
    local r = ical.parse_rrule(s)
    T.eq(ical.format_rrule(r), s)
  end)
end)

-- ---------------------------------------------------------------------------
-- Full calendar parse
-- ---------------------------------------------------------------------------

local SIMPLE_ICS = [[BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//My App//EN
BEGIN:VEVENT
UID:abc123@example.com
DTSTART:20260101T100000Z
DTEND:20260101T110000Z
SUMMARY:Team Meeting
DESCRIPTION:Monthly sync
LOCATION:Conference Room A
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR]]

T.describe("parse - single VEVENT", function()
  local cal, err = ical.parse(SIMPLE_ICS)

  T.it("no error", function()
    T.eq(err, nil)
    T.ok(cal ~= nil)
  end)

  T.it("calendar meta", function()
    T.eq(cal.version, "2.0")
    T.eq(cal.prodid,  "-//My App//EN")
  end)

  T.it("one event parsed", function()
    T.eq(#cal.events, 1)
  end)

  T.it("event fields", function()
    local ev = cal.events[1]
    T.eq(ev.uid,      "abc123@example.com")
    T.eq(ev.summary,  "Team Meeting")
    T.eq(ev.description, "Monthly sync")
    T.eq(ev.location, "Conference Room A")
    T.eq(ev.status,   "CONFIRMED")
  end)

  T.it("DTSTART parsed as datetime", function()
    local dt = cal.events[1].dtstart
    T.ok(dt ~= nil)
    T.eq(dt.year,  2026)
    T.eq(dt.month, 1)
    T.eq(dt.day,   1)
    T.eq(dt.hour,  10)
    T.eq(dt.min,   0)
    T.eq(dt.sec,   0)
    T.eq(dt.utc,   true)
  end)

  T.it("DTEND parsed as datetime", function()
    local dt = cal.events[1].dtend
    T.ok(dt ~= nil)
    T.eq(dt.hour, 11)
    T.eq(dt.utc,  true)
  end)
end)

-- ---------------------------------------------------------------------------
-- Multiple events
-- ---------------------------------------------------------------------------

local MULTI_ICS = [[BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//EN
BEGIN:VEVENT
UID:ev1@test.com
DTSTART:20260101T090000Z
DTEND:20260101T100000Z
SUMMARY:Event One
END:VEVENT
BEGIN:VEVENT
UID:ev2@test.com
DTSTART:20260102T090000Z
DTEND:20260102T100000Z
SUMMARY:Event Two
END:VEVENT
BEGIN:VEVENT
UID:ev3@test.com
DTSTART:20260103T090000Z
DTEND:20260103T100000Z
SUMMARY:Event Three
END:VEVENT
END:VCALENDAR]]

T.describe("parse - multiple events", function()
  local cal = ical.parse(MULTI_ICS)

  T.it("three events", function()
    T.eq(#cal.events, 3)
  end)

  T.it("events are in order", function()
    T.eq(cal.events[1].uid, "ev1@test.com")
    T.eq(cal.events[2].uid, "ev2@test.com")
    T.eq(cal.events[3].uid, "ev3@test.com")
  end)

  T.it("summaries correct", function()
    T.eq(cal.events[1].summary, "Event One")
    T.eq(cal.events[2].summary, "Event Two")
    T.eq(cal.events[3].summary, "Event Three")
  end)
end)

-- ---------------------------------------------------------------------------
-- VTODO
-- ---------------------------------------------------------------------------

local TODO_ICS = [[BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//EN
BEGIN:VTODO
UID:todo-1@test.com
SUMMARY:Fix bug
DUE:20260320
STATUS:NEEDS-ACTION
PRIORITY:1
END:VTODO
END:VCALENDAR]]

T.describe("parse - VTODO", function()
  local cal, err = ical.parse(TODO_ICS)

  T.it("no error", function()
    T.eq(err, nil)
    T.ok(cal ~= nil)
  end)

  T.it("one todo parsed", function()
    T.eq(#cal.todos, 1)
  end)

  T.it("todo fields", function()
    local td = cal.todos[1]
    T.eq(td.uid,      "todo-1@test.com")
    T.eq(td.summary,  "Fix bug")
    T.eq(td.status,   "NEEDS-ACTION")
    T.eq(td.priority, "1")
  end)

  T.it("DUE as date-only", function()
    local td = cal.todos[1]
    T.ok(td.due ~= nil)
    T.eq(td.due.year,  2026)
    T.eq(td.due.month, 3)
    T.eq(td.due.day,   20)
    T.eq(td.due.hour,  nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- VALARM
-- ---------------------------------------------------------------------------

local ALARM_ICS = [[BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//EN
BEGIN:VEVENT
UID:alarm-test@test.com
DTSTART:20260101T090000Z
DTEND:20260101T100000Z
SUMMARY:Meeting with Alarm
BEGIN:VALARM
ACTION:DISPLAY
TRIGGER:-PT15M
DESCRIPTION:Reminder
END:VALARM
END:VEVENT
END:VCALENDAR]]

T.describe("parse - VALARM", function()
  local cal, err = ical.parse(ALARM_ICS)

  T.it("no error", function()
    T.eq(err, nil)
  end)

  T.it("alarm present", function()
    local ev = cal.events[1]
    T.ok(ev.alarms ~= nil)
    T.eq(#ev.alarms, 1)
  end)

  T.it("alarm fields", function()
    local alarm = cal.events[1].alarms[1]
    T.eq(alarm.action,      "DISPLAY")
    T.eq(alarm.trigger,     "-PT15M")
    T.eq(alarm.description, "Reminder")
  end)
end)

-- ---------------------------------------------------------------------------
-- Line unfolding
-- ---------------------------------------------------------------------------

T.describe("parse - line unfolding", function()
  -- RFC 5545 §3.1: a CRLF immediately followed by a single white space
  -- is treated as equivalent to no characters
  local FOLDED_ICS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\nBEGIN:VEVENT\r\nUID:fold@test.com\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nSUMMARY:This is a very long summary that should be folded across\r\n  multiple lines in the iCalendar format\r\nDESCRIPTION:Short\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

  T.it("unfolded summary concatenated correctly", function()
    local cal, err = ical.parse(FOLDED_ICS)
    T.eq(err, nil)
    T.ok(cal ~= nil)
    T.eq(#cal.events, 1)
    -- The space at start of continuation is dropped, but content is joined
    local summary = cal.events[1].summary
    T.ok(summary ~= nil)
    -- Should not contain newlines
    T.eq(summary:find("\n"), nil)
    T.ok(#summary > 20)
  end)

  T.it("LF-only unfolding also works", function()
    local LF_ICS = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//EN\nBEGIN:VEVENT\nUID:lf@test.com\nDTSTART:20260101T090000Z\nDTEND:20260101T100000Z\nSUMMARY:Hello\n World\nEND:VEVENT\nEND:VCALENDAR\n"
    local cal, err = ical.parse(LF_ICS)
    T.eq(err, nil)
    T.eq(#cal.events, 1)
    -- "Hello" + " World" continuation → "HelloWorld" (leading space stripped)
    T.ok(cal.events[1].summary ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Parse errors
-- ---------------------------------------------------------------------------

T.describe("parse - errors", function()
  T.it("nil input", function()
    local cal, err = ical.parse(nil)
    T.eq(cal, nil)
    T.ok(err ~= nil)
  end)

  T.it("empty string", function()
    local cal, err = ical.parse("")
    T.eq(cal, nil)
    T.ok(err ~= nil)
  end)

  T.it("missing BEGIN:VCALENDAR", function()
    local cal, err = ical.parse("VERSION:2.0\nPRODID:-//X//EN\n")
    T.eq(cal, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Calendar builder
-- ---------------------------------------------------------------------------

T.describe("calendar builder", function()
  T.it("creates calendar with default version", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    T.ok(cal ~= nil)
    local s = cal:to_string()
    T.ok(s:find("BEGIN:VCALENDAR", 1, true) ~= nil)
    T.ok(s:find("VERSION:2.0", 1, true) ~= nil)
    T.ok(s:find("PRODID:-//Test//EN", 1, true) ~= nil)
    T.ok(s:find("END:VCALENDAR", 1, true) ~= nil)
  end)

  T.it("add_event produces VEVENT", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    cal:add_event({
      uid     = "test-uid@example.com",
      dtstart = { year=2026, month=3, day=15, hour=14, min=0, sec=0, utc=true },
      dtend   = { year=2026, month=3, day=15, hour=15, min=0, sec=0, utc=true },
      summary = "Project Review",
    })
    local s = cal:to_string()
    T.ok(s:find("BEGIN:VEVENT", 1, true) ~= nil)
    T.ok(s:find("END:VEVENT", 1, true) ~= nil)
    T.ok(s:find("UID:test-uid@example.com", 1, true) ~= nil)
    T.ok(s:find("SUMMARY:Project Review", 1, true) ~= nil)
    T.ok(s:find("DTSTART:20260315T140000Z", 1, true) ~= nil)
    T.ok(s:find("DTEND:20260315T150000Z", 1, true) ~= nil)
  end)

  T.it("add_todo produces VTODO", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    cal:add_todo({
      uid     = "todo-1@example.com",
      summary = "Fix bug",
      due     = { year=2026, month=3, day=20 },
      status  = "NEEDS-ACTION",
      priority = 1,
    })
    local s = cal:to_string()
    T.ok(s:find("BEGIN:VTODO", 1, true) ~= nil)
    T.ok(s:find("END:VTODO", 1, true) ~= nil)
    T.ok(s:find("UID:todo-1@example.com", 1, true) ~= nil)
    T.ok(s:find("SUMMARY:Fix bug", 1, true) ~= nil)
    T.ok(s:find("STATUS:NEEDS-ACTION", 1, true) ~= nil)
  end)

  T.it("add_event returns self for chaining", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    local result = cal:add_event({ uid = "x", dtstart = {year=2026,month=1,day=1} })
    T.eq(result, cal)
  end)

  T.it("multiple events", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    cal:add_event({ uid="e1", dtstart={year=2026,month=1,day=1,hour=9,min=0,sec=0,utc=true}, summary="E1" })
    cal:add_event({ uid="e2", dtstart={year=2026,month=1,day=2,hour=9,min=0,sec=0,utc=true}, summary="E2" })
    local s = cal:to_string()
    T.ok(s:find("UID:e1", 1, true) ~= nil)
    T.ok(s:find("UID:e2", 1, true) ~= nil)
    T.ok(s:find("SUMMARY:E1", 1, true) ~= nil)
    T.ok(s:find("SUMMARY:E2", 1, true) ~= nil)
  end)

  T.it("RRULE is serialized", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    cal:add_event({
      uid     = "rrule-ev@test.com",
      dtstart = { year=2026, month=1, day=5, hour=10, min=0, sec=0, utc=true },
      summary = "Weekly standup",
      rrule   = { freq="WEEKLY", interval=1, byday={"MO","WE","FR"} },
    })
    local s = cal:to_string()
    T.ok(s:find("RRULE:", 1, true) ~= nil)
    T.ok(s:find("FREQ=WEEKLY", 1, true) ~= nil)
    T.ok(s:find("BYDAY=MO,WE,FR", 1, true) ~= nil)
  end)

  T.it("due date-only uses VALUE=DATE", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    cal:add_todo({
      uid = "t1",
      summary = "Task",
      due = { year=2026, month=6, day=1 },
    })
    local s = cal:to_string()
    T.ok(s:find("VALUE=DATE", 1, true) ~= nil)
    T.ok(s:find("DUE;VALUE=DATE:20260601", 1, true) ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Line folding at 75 chars
-- ---------------------------------------------------------------------------

T.describe("to_string - line folding", function()
  T.it("long property is folded", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    local long_summary = "This is a very long event summary that definitely exceeds the 75 octet line limit imposed by RFC 5545"
    cal:add_event({
      uid     = "fold-test@test.com",
      dtstart = { year=2026, month=1, day=1, hour=10, min=0, sec=0, utc=true },
      summary = long_summary,
    })
    local s = cal:to_string()
    -- Check that no CRLF-terminated line exceeds 75 octets (excluding CRLF)
    local ok = true
    for line in s:gmatch("[^\r\n]+") do
      if #line > 75 then
        ok = false
        break
      end
    end
    T.ok(ok)
  end)

  T.it("folded lines begin with space", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    local long_desc = ("x"):rep(200)
    cal:add_event({
      uid         = "fold-test2@test.com",
      dtstart     = { year=2026, month=1, day=1, hour=10, min=0, sec=0, utc=true },
      description = long_desc,
    })
    local s = cal:to_string()
    -- Find a continuation line (starts with space or tab after CRLF)
    T.ok(s:find("\r\n ", 1, true) ~= nil or s:find("\r\n\t", 1, true) ~= nil)
  end)

  T.it("CRLF line endings used", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    local s = cal:to_string()
    T.ok(s:find("\r\n", 1, true) ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Round-trip: parse(cal:to_string()) == original data
-- ---------------------------------------------------------------------------

T.describe("round-trip", function()
  T.it("event round-trip", function()
    local orig = ical.calendar({ prodid = "-//Test//EN", version = "2.0" })
    orig:add_event({
      uid         = "rt-ev@example.com",
      dtstart     = { year=2026, month=3, day=15, hour=14, min=0, sec=0, utc=true },
      dtend       = { year=2026, month=3, day=15, hour=15, min=0, sec=0, utc=true },
      summary     = "Project Review",
      description = "Q1 review",
      location    = "Room 101",
      status      = "CONFIRMED",
    })
    local s = orig:to_string()
    local parsed, err = ical.parse(s)
    T.eq(err, nil)
    T.ok(parsed ~= nil)
    T.eq(#parsed.events, 1)
    local ev = parsed.events[1]
    T.eq(ev.uid,         "rt-ev@example.com")
    T.eq(ev.summary,     "Project Review")
    T.eq(ev.description, "Q1 review")
    T.eq(ev.location,    "Room 101")
    T.eq(ev.status,      "CONFIRMED")
    T.eq(ev.dtstart.year,  2026)
    T.eq(ev.dtstart.month, 3)
    T.eq(ev.dtstart.day,   15)
    T.eq(ev.dtstart.hour,  14)
    T.eq(ev.dtstart.utc,   true)
  end)

  T.it("todo round-trip", function()
    local orig = ical.calendar({ prodid = "-//Test//EN" })
    orig:add_todo({
      uid      = "rt-todo@example.com",
      summary  = "Fix critical bug",
      due      = { year=2026, month=4, day=1 },
      status   = "NEEDS-ACTION",
      priority = 1,
    })
    local s = orig:to_string()
    local parsed = ical.parse(s)
    T.ok(parsed ~= nil)
    T.eq(#parsed.todos, 1)
    local td = parsed.todos[1]
    T.eq(td.uid,      "rt-todo@example.com")
    T.eq(td.summary,  "Fix critical bug")
    T.eq(td.status,   "NEEDS-ACTION")
    T.eq(td.due.year,  2026)
    T.eq(td.due.month, 4)
    T.eq(td.due.day,   1)
  end)

  T.it("RRULE round-trip", function()
    local orig = ical.calendar({ prodid = "-//Test//EN" })
    orig:add_event({
      uid     = "rrule-rt@example.com",
      dtstart = { year=2026, month=1, day=5, hour=9, min=0, sec=0, utc=true },
      summary = "Recurring",
      rrule   = { freq="WEEKLY", interval=2, byday={"TU","TH"} },
    })
    local s = orig:to_string()
    local parsed = ical.parse(s)
    T.ok(parsed ~= nil)
    T.eq(#parsed.events, 1)
    local r = parsed.events[1].rrule
    T.ok(r ~= nil)
    T.eq(r.freq,     "WEEKLY")
    T.eq(r.interval, 2)
    T.eq(#r.byday,   2)
    T.eq(r.byday[1], "TU")
    T.eq(r.byday[2], "TH")
  end)

  T.it("calendar with calscale", function()
    local orig = ical.calendar({ prodid = "-//Test//EN", calscale = "GREGORIAN" })
    local s = orig:to_string()
    T.ok(s:find("CALSCALE:GREGORIAN", 1, true) ~= nil)
    local parsed = ical.parse(s)
    T.eq(parsed.calscale, "GREGORIAN")
  end)
end)

-- ---------------------------------------------------------------------------
-- RRULE detailed tests
-- ---------------------------------------------------------------------------

T.describe("RRULE parsing", function()
  T.it("weekly recurrence", function()
    local r = ical.parse_rrule("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO")
    T.eq(r.freq, "WEEKLY")
    T.eq(r.interval, 1)
    T.eq(r.byday[1], "MO")
  end)

  T.it("daily recurrence with count", function()
    local r = ical.parse_rrule("FREQ=DAILY;COUNT=5")
    T.eq(r.freq,  "DAILY")
    T.eq(r.count, 5)
  end)

  T.it("monthly recurrence", function()
    local r = ical.parse_rrule("FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=1")
    T.eq(r.freq,           "MONTHLY")
    T.eq(r.bymonthday[1],  1)
  end)

  T.it("yearly recurrence", function()
    local r = ical.parse_rrule("FREQ=YEARLY")
    T.eq(r.freq, "YEARLY")
  end)

  T.it("with wkst", function()
    local r = ical.parse_rrule("FREQ=WEEKLY;WKST=SU;BYDAY=SA,SU")
    T.eq(r.wkst,     "SU")
    T.eq(r.byday[1], "SA")
    T.eq(r.byday[2], "SU")
  end)

  T.it("format_rrule with count", function()
    local r = ical.parse_rrule("FREQ=DAILY;COUNT=3")
    local s = ical.format_rrule(r)
    T.ok(s:find("FREQ=DAILY", 1, true) ~= nil)
    T.ok(s:find("COUNT=3", 1, true) ~= nil)
  end)

  T.it("format_rrule with until", function()
    local r = ical.parse_rrule("FREQ=WEEKLY;UNTIL=20261231T235959Z")
    local s = ical.format_rrule(r)
    T.ok(s:find("UNTIL=20261231T235959Z", 1, true) ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Text escaping
-- ---------------------------------------------------------------------------

T.describe("text escaping", function()
  T.it("backslash-n in description survives round-trip", function()
    local cal = ical.calendar({ prodid = "-//Test//EN" })
    -- Embed a literal newline in the description; it gets escaped to \n
    cal:add_event({
      uid         = "escape@test.com",
      dtstart     = { year=2026, month=1, day=1, hour=9, min=0, sec=0, utc=true },
      description = "Line one\nLine two",
    })
    local s = cal:to_string()
    -- In the serialized form the newline should be \n (escaped)
    T.ok(s:find("DESCRIPTION:Line one\\nLine two", 1, true) ~= nil)
  end)

  T.it("unescape_text reverses escaping", function()
    T.eq(ical.unescape_text("hello\\nworld"), "hello\nworld")
    T.eq(ical.unescape_text("a\\,b"), "a,b")
    T.eq(ical.unescape_text("a\\;b"), "a;b")
    T.eq(ical.unescape_text("a\\\\b"), "a\\b")
  end)
end)

-- ---------------------------------------------------------------------------
-- Full builder example from spec
-- ---------------------------------------------------------------------------

T.describe("full builder example", function()
  T.it("builds the example from the spec", function()
    local cal = ical.calendar({
      prodid  = "-//My App//EN",
      version = "2.0",
    })
    cal:add_event({
      uid         = "unique-id@example.com",
      dtstart     = { year=2026, month=3, day=15, hour=14, min=0, sec=0, utc=true },
      dtend       = { year=2026, month=3, day=15, hour=15, min=0, sec=0, utc=true },
      summary     = "Project Review",
      description = "Q1 review",
      location    = "Room 101",
      status      = "CONFIRMED",
      rrule       = { freq="WEEKLY", interval=1, byday={"MO","WE","FR"} },
    })
    cal:add_todo({
      uid      = "todo-1@example.com",
      summary  = "Fix bug",
      due      = { year=2026, month=3, day=20 },
      status   = "NEEDS-ACTION",
      priority = 1,
    })
    local s = cal:to_string()
    -- Basic sanity checks
    T.ok(s:find("BEGIN:VCALENDAR", 1, true) ~= nil)
    T.ok(s:find("BEGIN:VEVENT", 1, true) ~= nil)
    T.ok(s:find("BEGIN:VTODO", 1, true) ~= nil)
    T.ok(s:find("END:VCALENDAR", 1, true) ~= nil)

    -- Parse it back
    local parsed, err = ical.parse(s)
    T.eq(err, nil)
    T.ok(parsed ~= nil)
    T.eq(#parsed.events, 1)
    T.eq(#parsed.todos,  1)
    T.eq(parsed.events[1].uid,     "unique-id@example.com")
    T.eq(parsed.todos[1].uid,      "todo-1@example.com")
    T.eq(parsed.todos[1].priority, "1")
  end)
end)
