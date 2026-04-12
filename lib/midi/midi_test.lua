if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local midi = require("lib.midi")
local T = require("lib.test.assert")

-- ── Note utilities ────────────────────────────────────────────────────────────

T.describe("note_name", function()
    T.it("middle C is C4", function()
        T.eq(midi.note_name(60), "C4")
    end)
    T.it("A4 is 69", function()
        T.eq(midi.note_name(69), "A4")
    end)
    T.it("sharps", function()
        T.eq(midi.note_name(61), "C#4")
        T.eq(midi.note_name(66), "F#4")
    end)
    T.it("octave boundaries", function()
        T.eq(midi.note_name(0),  "C-1")
        T.eq(midi.note_name(12), "C0")
        T.eq(midi.note_name(127), "G9")
    end)
end)

T.describe("note_number", function()
    T.it("C4 = 60", function()
        T.eq(midi.note_number("C4"), 60)
    end)
    T.it("A4 = 69", function()
        T.eq(midi.note_number("A4"), 69)
    end)
    T.it("sharps", function()
        T.eq(midi.note_number("C#4"), 61)
        T.eq(midi.note_number("F#3"), 54)
    end)
    T.it("flats", function()
        T.eq(midi.note_number("Db4"), 61)
        T.eq(midi.note_number("Bb3"), 58)
    end)
    T.it("low octave", function()
        T.eq(midi.note_number("C-1"), 0)
    end)
    T.it("invalid returns nil", function()
        T.eq(midi.note_number("Z4"), nil)
        T.eq(midi.note_number(""), nil)
    end)
    T.it("round-trips with note_name", function()
        for n = 0, 127 do
            T.eq(midi.note_number(midi.note_name(n)), n)
        end
    end)
end)

T.describe("note_frequency", function()
    T.it("A4 = 440 Hz", function()
        local f = midi.note_frequency(69)
        T.ok(math.abs(f - 440.0) < 0.001, "A4 frequency")
    end)
    T.it("A5 = 880 Hz (one octave up)", function()
        local f = midi.note_frequency(81)
        T.ok(math.abs(f - 880.0) < 0.001, "A5 frequency")
    end)
    T.it("C4 ~ 261.63 Hz", function()
        local f = midi.note_frequency(60)
        T.ok(math.abs(f - 261.626) < 0.01, "C4 frequency")
    end)
end)

-- ── VLQ encoding/decoding ─────────────────────────────────────────────────────

T.describe("vlq", function()
    T.it("single byte values", function()
        T.eq(midi.vlq_encode(0), "\x00")
        T.eq(midi.vlq_encode(0x3F), "\x3F")
        T.eq(midi.vlq_encode(0x7F), "\x7F")
    end)
    T.it("two byte values", function()
        T.eq(midi.vlq_encode(0x80), "\x81\x00")
        T.eq(midi.vlq_encode(0xFF), "\x81\x7F")
    end)
    T.it("three byte value", function()
        T.eq(midi.vlq_encode(0x3FFF), "\xFF\x7F")
        T.eq(midi.vlq_encode(0x4000), "\x81\x80\x00")
    end)
    T.it("decode roundtrips", function()
        local cases = { 0, 1, 0x7F, 0x80, 0xFF, 0x3FFF, 0x4000, 0x1FFFFF, 0x200000 }
        for _, v in ipairs(cases) do
            local enc = midi.vlq_encode(v)
            local dec, npos = midi.vlq_decode(enc, 1)
            T.eq(dec, v)
            T.eq(npos, #enc + 1)
        end
    end)
end)

-- ── Track builder ─────────────────────────────────────────────────────────────

T.describe("track builder", function()
    T.it("builds correct event sequence", function()
        local tr = midi.track()
            :note_on(0, 0, 60, 100)
            :note_off(480, 0, 60, 64)
            :build()
        local evs = tr.events
        T.eq(evs[1].type, "note_on")
        T.eq(evs[1].tick, 0)
        T.eq(evs[1].note, 60)
        T.eq(evs[2].type, "note_off")
        T.eq(evs[2].tick, 480)
        T.eq(evs[3].type, "end_of_track")
    end)

    T.it("note() adds note_on and note_off", function()
        local tr = midi.track()
            :note(0, 240, 0, 62, 80)
            :build()
        local evs = tr.events
        T.eq(evs[1].type, "note_on")
        T.eq(evs[1].note, 62)
        T.eq(evs[1].tick, 0)
        T.eq(evs[2].type, "note_off")
        T.eq(evs[2].tick, 240)
        T.eq(evs[3].type, "end_of_track")
    end)

    T.it("events are sorted by tick", function()
        local tr = midi.track()
            :note_off(480, 0, 60, 64)
            :note_on(0, 0, 60, 100)
            :build()
        T.eq(tr.events[1].tick, 0)
        T.eq(tr.events[2].tick, 480)
    end)

    T.it("note_off before note_on at same tick", function()
        local tr = midi.track()
            :note_on(480, 0, 60, 100)
            :note_off(480, 0, 59, 64)
            :build()
        T.eq(tr.events[1].type, "note_off")
        T.eq(tr.events[2].type, "note_on")
    end)

    T.it("tempo event", function()
        local tr = midi.track()
            :tempo(0, 120)
            :build()
        local ev = tr.events[1]
        T.eq(ev.type, "tempo")
        T.eq(ev.bpm, 120)
        T.ok(ev.microseconds_per_beat > 0)
    end)

    T.it("program change", function()
        local tr = midi.track()
            :program(0, 0, 40)
            :build()
        T.eq(tr.events[1].type, "program_change")
        T.eq(tr.events[1].program, 40)
    end)

    T.it("text event", function()
        local tr = midi.track()
            :text(0, "track_name", "Piano")
            :build()
        T.eq(tr.events[1].type, "text")
        T.eq(tr.events[1].subtype, "track_name")
        T.eq(tr.events[1].text, "Piano")
    end)
end)

-- ── File builder ──────────────────────────────────────────────────────────────

T.describe("file builder", function()
    T.it("builds midi_file with specified format and tpb", function()
        local f = midi.file({ format = 1, ticks_per_beat = 960 })
            :add_track(midi.track():build())
            :build()
        T.eq(f.format, 1)
        T.eq(f.ticks_per_beat, 960)
        T.eq(#f.tracks, 1)
    end)

    T.it("defaults to format 1 and tpb 480", function()
        local f = midi.file():add_track(midi.track():build()):build()
        T.eq(f.format, 1)
        T.eq(f.ticks_per_beat, 480)
    end)
end)

-- ── Build → encode → parse round-trip ────────────────────────────────────────

T.describe("encode/parse round-trip", function()
    T.it("simple format 0 file", function()
        local tr = midi.track()
            :note_on(0, 0, 60, 100)
            :note_off(480, 0, 60, 64)
            :build()
        local mf = midi.file({ format = 0, ticks_per_beat = 480 })
            :add_track(tr)
            :build()

        local data, err = midi.encode(mf)
        T.eq(err, nil)
        T.ok(type(data) == "string")

        local parsed, perr = midi.parse(data)
        T.eq(perr, nil)
        T.eq(parsed.format, 0)
        T.eq(parsed.ticks_per_beat, 480)
        T.eq(#parsed.tracks, 1)

        local evs = parsed.tracks[1].events
        T.eq(evs[1].type, "note_on")
        T.eq(evs[1].channel, 0)
        T.eq(evs[1].note, 60)
        T.eq(evs[1].velocity, 100)
        T.eq(evs[1].tick, 0)
        T.eq(evs[2].type, "note_off")
        T.eq(evs[2].tick, 480)
        T.eq(evs[3].type, "end_of_track")
    end)

    T.it("multi-track format 1 file", function()
        local tempo_tr = midi.track():tempo(0, 120):build()
        local note_tr = midi.track():note(0, 480, 0, 64, 90):build()
        local mf = midi.file({ format = 1, ticks_per_beat = 480 })
            :add_track(tempo_tr)
            :add_track(note_tr)
            :build()

        local data = midi.encode(mf)
        local parsed = midi.parse(data)
        T.eq(parsed.format, 1)
        T.eq(#parsed.tracks, 2)

        local t1evs = parsed.tracks[1].events
        T.eq(t1evs[1].type, "tempo")
        T.ok(math.abs(t1evs[1].bpm - 120) < 1)
    end)

    T.it("parse → encode → parse gives same events", function()
        -- Build a moderately complex file
        local tr = midi.track()
            :tempo(0, 140)
            :program(0, 0, 25)
            :text(0, "track_name", "Guitar")
            :note(0, 240, 0, 60, 80)
            :note(240, 240, 0, 64, 80)
            :note(480, 240, 0, 67, 80)
            :build()
        local mf = midi.file({ format = 0, ticks_per_beat = 480 })
            :add_track(tr)
            :build()

        local data1 = midi.encode(mf)
        local parsed1 = midi.parse(data1)
        local data2 = midi.encode(parsed1)
        local parsed2 = midi.parse(data2)

        -- Same number of events
        T.eq(#parsed1.tracks[1].events, #parsed2.tracks[1].events)

        -- Check every event field matches
        local evs1 = parsed1.tracks[1].events
        local evs2 = parsed2.tracks[1].events
        for i = 1, #evs1 do
            T.eq(evs1[i].type, evs2[i].type)
            T.eq(evs1[i].tick, evs2[i].tick)
        end
    end)

    T.it("program_change round-trips", function()
        local tr = midi.track():program(0, 1, 42):build()
        local mf = midi.file({ format = 0 }):add_track(tr):build()
        local data = midi.encode(mf)
        local parsed = midi.parse(data)
        local ev = parsed.tracks[1].events[1]
        T.eq(ev.type, "program_change")
        T.eq(ev.channel, 1)
        T.eq(ev.program, 42)
    end)

    T.it("control_change round-trips", function()
        local tr = midi.track()
        tr._events[1] = { type = "control_change", tick = 0, channel = 0, controller = 7, value = 100 }
        local track = tr:build()
        local mf = midi.file({ format = 0 }):add_track(track):build()
        local data = midi.encode(mf)
        local parsed = midi.parse(data)
        local ev = parsed.tracks[1].events[1]
        T.eq(ev.type, "control_change")
        T.eq(ev.controller, 7)
        T.eq(ev.value, 100)
    end)

    T.it("pitch_bend round-trips", function()
        local tr = midi.track()
        tr._events[1] = { type = "pitch_bend", tick = 0, channel = 0, value = 1000 }
        tr._events[2] = { type = "pitch_bend", tick = 10, channel = 0, value = -1000 }
        tr._events[3] = { type = "pitch_bend", tick = 20, channel = 0, value = 0 }
        local track = tr:build()
        local mf = midi.file({ format = 0 }):add_track(track):build()
        local data = midi.encode(mf)
        local parsed = midi.parse(data)
        local evs = parsed.tracks[1].events
        T.eq(evs[1].type, "pitch_bend")
        T.eq(evs[1].value, 1000)
        T.eq(evs[2].value, -1000)
        T.eq(evs[3].value, 0)
    end)

    T.it("time_signature round-trips", function()
        local tr = midi.track()
        tr._events[1] = { type = "time_signature", tick = 0, numerator = 3, denominator = 4 }
        local track = tr:build()
        local mf = midi.file({ format = 0 }):add_track(track):build()
        local data = midi.encode(mf)
        local parsed = midi.parse(data)
        local ev = parsed.tracks[1].events[1]
        T.eq(ev.type, "time_signature")
        T.eq(ev.numerator, 3)
        T.eq(ev.denominator, 4)
    end)

    T.it("key_signature round-trips", function()
        local tr = midi.track()
        tr._events[1] = { type = "key_signature", tick = 0, key = -1, mode = 0 }  -- F major
        local track = tr:build()
        local mf = midi.file({ format = 0 }):add_track(track):build()
        local data = midi.encode(mf)
        local parsed = midi.parse(data)
        local ev = parsed.tracks[1].events[1]
        T.eq(ev.type, "key_signature")
        T.eq(ev.key, -1)
        T.eq(ev.mode, 0)
    end)

    T.it("text meta events round-trip", function()
        local subtypes = { "text", "copyright", "track_name", "instrument_name", "lyrics", "marker", "cue_point" }
        for _, st in ipairs(subtypes) do
            local tr = midi.track():text(0, st, "Hello MIDI"):build()
            local mf = midi.file({ format = 0 }):add_track(tr):build()
            local data = midi.encode(mf)
            local parsed = midi.parse(data)
            local ev = parsed.tracks[1].events[1]
            T.eq(ev.type, "text")
            T.eq(ev.subtype, st)
            T.eq(ev.text, "Hello MIDI")
        end
    end)

    T.it("sysex round-trips", function()
        local tr = midi.track()
        tr._events[1] = { type = "sysex", tick = 0, data = "\x41\x10\x42\x12" }
        local track = tr:build()
        local mf = midi.file({ format = 0 }):add_track(track):build()
        local data = midi.encode(mf)
        local parsed = midi.parse(data)
        local ev = parsed.tracks[1].events[1]
        T.eq(ev.type, "sysex")
        T.eq(ev.data, "\x41\x10\x42\x12")
    end)
end)

-- ── to_seconds ────────────────────────────────────────────────────────────────

T.describe("to_seconds", function()
    T.it("constant 120 bpm: 480 ticks = 0.5 seconds", function()
        local tr = midi.track()
            :tempo(0, 120)
            :note_on(480, 0, 60, 100)
            :build()
        local mf = midi.file({ format = 0, ticks_per_beat = 480 })
            :add_track(tr)
            :build()
        local timed = midi.to_seconds(mf)
        local evs = timed.tracks[1].events
        -- tempo event at tick 0 → time 0
        T.ok(math.abs(evs[1].time_seconds - 0) < 1e-9)
        -- note_on at tick 480 → 0.5 seconds at 120 bpm
        T.ok(math.abs(evs[2].time_seconds - 0.5) < 1e-6, "480 ticks at 120bpm = 0.5s")
    end)

    T.it("tempo change affects subsequent events", function()
        -- Track 1: tempo events; Track 2: notes
        local tempo_tr = midi.track()
            :tempo(0, 120)
            :build()
        -- Add a manual tempo change event directly
        tempo_tr.events[2] = { type = "tempo", tick = 480, bpm = 60, microseconds_per_beat = 1000000 }
        tempo_tr.events[3] = { type = "end_of_track", tick = 480 }

        local note_tr = midi.track()
        note_tr.events = {
            { type = "note_on",  tick = 0,   channel = 0, note = 60, velocity = 100 },
            { type = "note_on",  tick = 480, channel = 0, note = 62, velocity = 100 },
            { type = "note_on",  tick = 960, channel = 0, note = 64, velocity = 100 },
            { type = "end_of_track", tick = 960 },
        }

        local mf = midi.file({ format = 1, ticks_per_beat = 480 })
            :add_track(tempo_tr)
            :add_track(note_tr)
            :build()

        local timed = midi.to_seconds(mf)
        local evs = timed.tracks[2].events

        -- tick 0 → 0 seconds
        T.ok(math.abs(evs[1].time_seconds - 0) < 1e-9)
        -- tick 480 → 0.5 seconds (120 bpm = 0.5s/beat)
        T.ok(math.abs(evs[2].time_seconds - 0.5) < 1e-6)
        -- tick 960 → 0.5 + 1.0 = 1.5 seconds (60 bpm = 1s/beat after tick 480)
        T.ok(math.abs(evs[3].time_seconds - 1.5) < 1e-6)
    end)

    T.it("default tempo 120 bpm when no tempo event", function()
        local tr = midi.track():note_on(480, 0, 60, 100):build()
        local mf = midi.file({ format = 0, ticks_per_beat = 480 }):add_track(tr):build()
        local timed = midi.to_seconds(mf)
        local evs = timed.tracks[1].events
        -- Default 500000 uspb = 120 bpm → 480 ticks = 0.5s
        T.ok(math.abs(evs[1].time_seconds - 0.5) < 1e-6)
    end)
end)

-- ── Error handling ────────────────────────────────────────────────────────────

T.describe("error handling", function()
    T.it("invalid header magic", function()
        local r, e = midi.parse("XXXX\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0")
        T.eq(r, nil)
        T.ok(type(e) == "string")
        T.ok(e:find("magic") ~= nil or e:find("MThd") ~= nil, "error mentions header")
    end)

    T.it("data too short", function()
        local r, e = midi.parse("MThd\x00")
        T.eq(r, nil)
        T.ok(type(e) == "string")
    end)

    T.it("encode non-table returns error", function()
        local r, e = midi.encode("not a table")
        T.eq(r, nil)
        T.ok(type(e) == "string")
    end)
end)

-- ── _tier introspection ───────────────────────────────────────────────────────

T.describe("module metadata", function()
    T.it("_tier is pure", function()
        T.eq(midi._tier, "pure")
    end)
end)
