-- lib/midi/init.lua
-- Standard MIDI File (SMF) parser, encoder, and utilities.
-- Pure Lua — no dependencies beyond the standard library and bit.
-- Supports SMF format 0, 1, and 2.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit = require("bit")
local byte, char, concat = string.byte, string.char, table.concat
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift
local floor = math.floor

-- ── Variable-length quantity (VLQ) ───────────────────────────────────────────

-- Decode a VLQ from data at pos. Returns value, next_pos.
local function vlq_decode(data, pos)
    local v = 0
    local b
    repeat
        b = byte(data, pos)
        if b == nil then return nil, nil end
        v = bor(lshift(v, 7), band(b, 0x7F))
        pos = pos + 1
    until band(b, 0x80) == 0
    return v, pos
end

-- Encode an integer as VLQ bytes, appended to table t.
local function vlq_encode_into(t, v)
    if v < 0 then v = 0 end
    -- Collect 7-bit groups from LSB to MSB
    local buf = {}
    buf[1] = band(v, 0x7F)
    v = rshift(v, 7)
    while v > 0 do
        buf[#buf + 1] = bor(band(v, 0x7F), 0x80)
        v = rshift(v, 7)
    end
    -- Emit MSB first, set continuation bits
    for i = #buf, 2, -1 do
        t[#t + 1] = char(buf[i])
    end
    t[#t + 1] = char(buf[1])
end

-- Encode VLQ to a string.
function M.vlq_encode(v)
    local t = {}
    vlq_encode_into(t, v)
    return concat(t)
end

-- Decode a VLQ from string s at position pos (1-indexed).
-- Returns value, next_pos or nil, nil on error.
function M.vlq_decode(s, pos)
    return vlq_decode(s, pos or 1)
end

-- ── Big-endian integer readers ────────────────────────────────────────────────

local function read_u8(data, pos)
    return byte(data, pos), pos + 1
end

local function read_u16(data, pos)
    local a, b = byte(data, pos, pos + 1)
    return bor(lshift(a, 8), b), pos + 2
end

local function read_u32(data, pos)
    local a, b, c, d = byte(data, pos, pos + 3)
    -- Use float arithmetic to avoid signed 32-bit overflow in LuaJIT
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d, pos + 4
end

local function write_u8(t, v)
    t[#t + 1] = char(band(v, 0xFF))
end

local function write_u16(t, v)
    t[#t + 1] = char(band(rshift(v, 8), 0xFF), band(v, 0xFF))
end

local function write_u32(t, v)
    -- Use division to stay in float range before flooring to avoid sign issues
    local v3 = band(floor(v / 0x1000000), 0xFF)
    local v2 = band(floor(v / 0x10000), 0xFF)
    local v1 = band(floor(v / 0x100), 0xFF)
    local v0 = band(v, 0xFF)
    t[#t + 1] = char(v3, v2, v1, v0)
end

-- ── Meta event subtype names ──────────────────────────────────────────────────

local META_TEXT_SUBTYPES = {
    [0x01] = "text",
    [0x02] = "copyright",
    [0x03] = "track_name",
    [0x04] = "instrument_name",
    [0x05] = "lyrics",
    [0x06] = "marker",
    [0x07] = "cue_point",
}

local META_TEXT_SUBTYPE_IDS = {}
for k, v in pairs(META_TEXT_SUBTYPES) do META_TEXT_SUBTYPE_IDS[v] = k end

-- ── Parser ────────────────────────────────────────────────────────────────────

-- Parse all events from a track chunk body (after "MTrk" + length).
-- Returns events list (absolute ticks) or nil, errmsg.
local function parse_track(data, start, len)
    local events = {}
    local pos = start
    local limit = start + len
    local tick = 0
    local running_status = 0

    while pos < limit do
        -- Delta time
        local delta, npos = vlq_decode(data, pos)
        if not delta then
            return nil, "truncated VLQ at pos " .. pos
        end
        pos = npos
        tick = tick + delta

        local status_byte = byte(data, pos)
        if status_byte == nil then
            return nil, "unexpected end of track data"
        end

        local status
        if band(status_byte, 0x80) ~= 0 then
            -- New status byte
            status = status_byte
            pos = pos + 1
            -- SysEx and meta do NOT update running status
            if status ~= 0xFF and status ~= 0xF0 and status ~= 0xF7 then
                running_status = status
            end
        else
            -- Running status: data byte, reuse previous status
            status = running_status
            if status == 0 then
                return nil, "running status with no prior status at pos " .. pos
            end
        end

        local msg_type = band(rshift(status, 4), 0x0F)
        local channel  = band(status, 0x0F)

        if status == 0xFF then
            -- Meta event
            local subtype = byte(data, pos)
            if subtype == nil then return nil, "truncated meta event" end
            pos = pos + 1
            local meta_len, npos2 = vlq_decode(data, pos)
            if not meta_len then return nil, "truncated meta length" end
            pos = npos2
            local meta_data = data:sub(pos, pos + meta_len - 1)
            pos = pos + meta_len

            if subtype == 0x2F then
                -- End of track
                events[#events + 1] = { type = "end_of_track", tick = tick }
            elseif subtype == 0x51 then
                -- Tempo: 3 bytes, microseconds per beat
                local a, b, c = byte(meta_data, 1, 3)
                local uspb = a * 0x10000 + b * 0x100 + c
                local bpm = 60000000 / uspb
                events[#events + 1] = {
                    type = "tempo",
                    bpm = bpm,
                    microseconds_per_beat = uspb,
                    tick = tick,
                }
            elseif subtype == 0x58 then
                -- Time signature
                local nn, dd = byte(meta_data, 1, 2)
                events[#events + 1] = {
                    type = "time_signature",
                    numerator = nn,
                    denominator = lshift(1, dd),
                    tick = tick,
                }
            elseif subtype == 0x59 then
                -- Key signature
                local sf, mi = byte(meta_data, 1, 2)
                -- sf is signed (-7 to 7)
                if sf >= 128 then sf = sf - 256 end
                events[#events + 1] = {
                    type = "key_signature",
                    key = sf,
                    mode = mi,
                    tick = tick,
                }
            elseif META_TEXT_SUBTYPES[subtype] then
                events[#events + 1] = {
                    type = "text",
                    subtype = META_TEXT_SUBTYPES[subtype],
                    text = meta_data,
                    tick = tick,
                }
            else
                -- Unknown meta
                events[#events + 1] = {
                    type = "meta",
                    subtype = subtype,
                    data = meta_data,
                    tick = tick,
                }
            end

        elseif status == 0xF0 or status == 0xF7 then
            -- SysEx
            local sysex_len, npos2 = vlq_decode(data, pos)
            if not sysex_len then return nil, "truncated sysex length" end
            pos = npos2
            local sysex_data = data:sub(pos, pos + sysex_len - 1)
            pos = pos + sysex_len
            events[#events + 1] = {
                type = "sysex",
                data = sysex_data,
                tick = tick,
            }

        elseif msg_type == 0x08 then
            -- Note off
            local note, vel = byte(data, pos, pos + 1)
            pos = pos + 2
            events[#events + 1] = {
                type = "note_off",
                channel = channel,
                note = note,
                velocity = vel,
                tick = tick,
            }

        elseif msg_type == 0x09 then
            -- Note on (velocity 0 = note off semantically, but we preserve it)
            local note, vel = byte(data, pos, pos + 1)
            pos = pos + 2
            events[#events + 1] = {
                type = "note_on",
                channel = channel,
                note = note,
                velocity = vel,
                tick = tick,
            }

        elseif msg_type == 0x0A then
            -- Polyphonic key pressure / aftertouch
            local note, pressure = byte(data, pos, pos + 1)
            pos = pos + 2
            events[#events + 1] = {
                type = "aftertouch",
                channel = channel,
                note = note,
                pressure = pressure,
                tick = tick,
            }

        elseif msg_type == 0x0B then
            -- Control change
            local ctrl, val = byte(data, pos, pos + 1)
            pos = pos + 2
            events[#events + 1] = {
                type = "control_change",
                channel = channel,
                controller = ctrl,
                value = val,
                tick = tick,
            }

        elseif msg_type == 0x0C then
            -- Program change
            local prog = byte(data, pos)
            pos = pos + 1
            events[#events + 1] = {
                type = "program_change",
                channel = channel,
                program = prog,
                tick = tick,
            }

        elseif msg_type == 0x0D then
            -- Channel pressure
            local pressure = byte(data, pos)
            pos = pos + 1
            events[#events + 1] = {
                type = "channel_pressure",
                channel = channel,
                pressure = pressure,
                tick = tick,
            }

        elseif msg_type == 0x0E then
            -- Pitch bend: two 7-bit bytes, LSB first
            local lsb, msb = byte(data, pos, pos + 1)
            pos = pos + 2
            local raw = bor(lsb, lshift(msb, 7))
            local value = raw - 8192  -- center at 0
            events[#events + 1] = {
                type = "pitch_bend",
                channel = channel,
                value = value,
                tick = tick,
            }

        else
            -- Unknown status; try to skip 1 data byte
            events[#events + 1] = {
                type = "unknown",
                status = status,
                data = "",
                tick = tick,
            }
        end
    end

    return events
end

--- Parse a Standard MIDI File binary string.
-- Returns midi_file or nil, errmsg.
-- midi_file: { format, ticks_per_beat, tracks }
--: (string) -> ({ format: number, ticks_per_beat: number, tracks: unknown[] } | nil, string)
function M.parse(data)
    if #data < 14 then
        return nil, "data too short to be a MIDI file"
    end
    -- Header chunk
    local magic = data:sub(1, 4)
    if magic ~= "MThd" then
        return nil, "invalid MIDI header magic: expected MThd, got " .. magic
    end
    local hdr_len, pos = read_u32(data, 5)
    if hdr_len < 6 then
        return nil, "MIDI header length too small: " .. hdr_len
    end
    local format, npos = read_u16(data, pos)
    local ntracks, npos2 = read_u16(data, npos)
    local division, npos3 = read_u16(data, npos2)
    pos = 9 + hdr_len  -- skip any extra header bytes

    -- division: if bit 15 = 0, ticks per quarter note; otherwise SMPTE
    local ticks_per_beat
    if band(division, 0x8000) == 0 then
        ticks_per_beat = division
    else
        -- SMPTE: we store raw value, caller can inspect
        ticks_per_beat = division
    end

    local tracks = {}
    for i = 1, ntracks do
        if pos + 7 > #data then
            return nil, "unexpected end of file before track " .. i
        end
        local chunk_id = data:sub(pos, pos + 3)
        if chunk_id ~= "MTrk" then
            return nil, "expected MTrk chunk, got " .. chunk_id .. " at track " .. i
        end
        local track_len, tpos = read_u32(data, pos + 4)
        local events, err = parse_track(data, tpos, track_len)
        if not events then
            return nil, "error parsing track " .. i .. ": " .. err
        end
        tracks[i] = { events = events }
        pos = tpos + track_len
    end

    return {
        format = format,
        ticks_per_beat = ticks_per_beat,
        tracks = tracks,
    }
end

-- ── Encoder ───────────────────────────────────────────────────────────────────

-- Encode a single track's events to binary.
-- Events must have absolute tick values; we compute deltas here.
local function encode_track(events)
    local t = {}
    local prev_tick = 0
    local prev_status = 0

    for _, ev in ipairs(events) do
        local tick = ev.tick or 0
        local delta = tick - prev_tick
        if delta < 0 then delta = 0 end
        prev_tick = tick
        vlq_encode_into(t, delta)

        local etype = ev.type

        if etype == "note_on" then
            local status = bor(0x90, band(ev.channel, 0x0F))
            if status ~= prev_status then
                write_u8(t, status)
                prev_status = status
            end
            write_u8(t, band(ev.note, 0x7F))
            write_u8(t, band(ev.velocity, 0x7F))

        elseif etype == "note_off" then
            local status = bor(0x80, band(ev.channel, 0x0F))
            if status ~= prev_status then
                write_u8(t, status)
                prev_status = status
            end
            write_u8(t, band(ev.note, 0x7F))
            write_u8(t, band(ev.velocity, 0x7F))

        elseif etype == "program_change" then
            local status = bor(0xC0, band(ev.channel, 0x0F))
            if status ~= prev_status then
                write_u8(t, status)
                prev_status = status
            end
            write_u8(t, band(ev.program, 0x7F))

        elseif etype == "control_change" then
            local status = bor(0xB0, band(ev.channel, 0x0F))
            if status ~= prev_status then
                write_u8(t, status)
                prev_status = status
            end
            write_u8(t, band(ev.controller, 0x7F))
            write_u8(t, band(ev.value, 0x7F))

        elseif etype == "pitch_bend" then
            local status = bor(0xE0, band(ev.channel, 0x0F))
            if status ~= prev_status then
                write_u8(t, status)
                prev_status = status
            end
            local raw = ev.value + 8192
            write_u8(t, band(raw, 0x7F))
            write_u8(t, band(rshift(raw, 7), 0x7F))

        elseif etype == "aftertouch" then
            local status = bor(0xA0, band(ev.channel, 0x0F))
            if status ~= prev_status then
                write_u8(t, status)
                prev_status = status
            end
            write_u8(t, band(ev.note, 0x7F))
            write_u8(t, band(ev.pressure, 0x7F))

        elseif etype == "channel_pressure" then
            local status = bor(0xD0, band(ev.channel, 0x0F))
            if status ~= prev_status then
                write_u8(t, status)
                prev_status = status
            end
            write_u8(t, band(ev.pressure, 0x7F))

        elseif etype == "tempo" then
            prev_status = 0  -- meta resets running status
            local uspb = ev.microseconds_per_beat
                or (ev.bpm and floor(60000000 / ev.bpm + 0.5))
                or 500000
            write_u8(t, 0xFF)
            write_u8(t, 0x51)
            write_u8(t, 0x03)
            write_u8(t, band(floor(uspb / 0x10000), 0xFF))
            write_u8(t, band(floor(uspb / 0x100), 0xFF))
            write_u8(t, band(uspb, 0xFF))

        elseif etype == "time_signature" then
            prev_status = 0
            -- denominator is a power of 2; encode as log2
            local dd = 0
            local denom = ev.denominator or 4
            local tmp = denom
            while tmp > 1 do tmp = rshift(tmp, 1); dd = dd + 1 end
            write_u8(t, 0xFF)
            write_u8(t, 0x58)
            write_u8(t, 0x04)
            write_u8(t, band(ev.numerator or 4, 0xFF))
            write_u8(t, band(dd, 0xFF))
            write_u8(t, 0x18)  -- 24 MIDI clocks per metronome click
            write_u8(t, 0x08)  -- 8 32nd notes per 24 MIDI clocks

        elseif etype == "key_signature" then
            prev_status = 0
            local sf = ev.key or 0
            if sf < 0 then sf = sf + 256 end
            write_u8(t, 0xFF)
            write_u8(t, 0x59)
            write_u8(t, 0x02)
            write_u8(t, band(sf, 0xFF))
            write_u8(t, band(ev.mode or 0, 0xFF))

        elseif etype == "text" then
            prev_status = 0
            local subtype_id = META_TEXT_SUBTYPE_IDS[ev.subtype] or 0x01
            local text = ev.text or ""
            write_u8(t, 0xFF)
            write_u8(t, subtype_id)
            vlq_encode_into(t, #text)
            t[#t + 1] = text

        elseif etype == "meta" then
            prev_status = 0
            local d = ev.data or ""
            write_u8(t, 0xFF)
            write_u8(t, band(ev.subtype or 0, 0xFF))
            vlq_encode_into(t, #d)
            t[#t + 1] = d

        elseif etype == "sysex" then
            prev_status = 0
            local d = ev.data or ""
            write_u8(t, 0xF0)
            vlq_encode_into(t, #d)
            t[#t + 1] = d

        elseif etype == "end_of_track" then
            prev_status = 0
            write_u8(t, 0xFF)
            write_u8(t, 0x2F)
            write_u8(t, 0x00)
        end
        -- Unknown events are silently dropped
    end

    return concat(t)
end

--- Encode a midi_file table back to a binary MIDI string.
-- Returns data string or nil, errmsg.
--: ({ format: number, ticks_per_beat: number, tracks: unknown[] }) -> (string | nil, string)
function M.encode(midi_file)
    if type(midi_file) ~= "table" then
        return nil, "midi_file must be a table"
    end
    local tracks = midi_file.tracks or {}
    local ntracks = #tracks
    local format = midi_file.format or (ntracks > 1 and 1 or 0)
    local tpb = midi_file.ticks_per_beat or 480

    local out = {}

    -- Header chunk
    out[#out + 1] = "MThd"
    write_u32(out, 6)
    write_u16(out, format)
    write_u16(out, ntracks)
    write_u16(out, tpb)

    -- Track chunks
    for i = 1, ntracks do
        local track = tracks[i]
        local events = track.events or {}
        -- Ensure end_of_track exists
        local last = events[#events]
        if not last or last.type ~= "end_of_track" then
            local last_tick = (last and last.tick) or 0
            events = {}
            for j, ev in ipairs(track.events or {}) do events[j] = ev end
            events[#events + 1] = { type = "end_of_track", tick = last_tick }
        end
        local body = encode_track(events)
        out[#out + 1] = "MTrk"
        write_u32(out, #body)
        out[#out + 1] = body
    end

    return concat(out)
end

-- ── to_seconds ────────────────────────────────────────────────────────────────

--- Convert tick-based events to absolute time in seconds.
-- Adds .time_seconds field to each event in each track.
-- Respects tempo changes found in any track.
-- Returns a new midi_file (shallow-copy of tracks/events with time_seconds added).
--: ({ format: number, ticks_per_beat: number, tracks: unknown[] }) -> { format: number, ticks_per_beat: number, tracks: unknown[] }
function M.to_seconds(midi_file)
    local tpb = midi_file.ticks_per_beat or 480
    local tracks = midi_file.tracks or {}

    -- Collect all tempo events across all tracks, sorted by tick
    local tempo_map = { { tick = 0, uspb = 500000 } }
    for _, track in ipairs(tracks) do
        for _, ev in ipairs(track.events or {}) do
            if ev.type == "tempo" then
                tempo_map[#tempo_map + 1] = {
                    tick = ev.tick,
                    uspb = ev.microseconds_per_beat,
                }
            end
        end
    end
    table.sort(tempo_map, function(a, b) return a.tick < b.tick end)

    -- Build cumulative time at each tempo change
    -- tempo_map[i].time_seconds = absolute seconds at that tick
    tempo_map[1].time_seconds = 0
    for i = 2, #tempo_map do
        local prev = tempo_map[i - 1]
        local dtick = tempo_map[i].tick - prev.tick
        local dt = dtick * prev.uspb / (tpb * 1e6)
        tempo_map[i].time_seconds = prev.time_seconds + dt
    end

    -- Function: convert tick to seconds
    local function tick_to_seconds(tick)
        -- Find the last tempo change at or before tick
        local ti = 1
        for i = 1, #tempo_map do
            if tempo_map[i].tick <= tick then
                ti = i
            else
                break
            end
        end
        local t = tempo_map[ti]
        local dtick = tick - t.tick
        return t.time_seconds + dtick * t.uspb / (tpb * 1e6)
    end

    -- Build new tracks with time_seconds attached
    local new_tracks = {}
    for ti, track in ipairs(tracks) do
        local new_events = {}
        for ei, ev in ipairs(track.events or {}) do
            -- Shallow copy
            local nev = {}
            for k, v in pairs(ev) do nev[k] = v end
            nev.time_seconds = tick_to_seconds(ev.tick or 0)
            new_events[ei] = nev
        end
        new_tracks[ti] = { events = new_events }
    end

    return {
        format = midi_file.format,
        ticks_per_beat = tpb,
        tracks = new_tracks,
    }
end

-- ── Note utilities ────────────────────────────────────────────────────────────

local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

--- Convert a MIDI note number to a name like "C4", "F#3".
-- Middle C (60) = C4.
--: (number) -> string
function M.note_name(note)
    local oct = floor(note / 12) - 1
    local pc = note % 12
    return NOTE_NAMES[pc + 1] .. oct
end

-- Build reverse lookup: "C" -> 0, "C#" -> 1, "Db" -> 1, ...
local NOTE_NAME_TO_PC = {}
for i, n in ipairs(NOTE_NAMES) do
    NOTE_NAME_TO_PC[n] = i - 1
end
-- Add flat aliases
NOTE_NAME_TO_PC["Db"] = 1
NOTE_NAME_TO_PC["Eb"] = 3
NOTE_NAME_TO_PC["Gb"] = 6
NOTE_NAME_TO_PC["Ab"] = 8
NOTE_NAME_TO_PC["Bb"] = 10

--- Convert a note name like "C4" or "F#3" to a MIDI note number.
-- Returns nil if unrecognised.
--: (string) -> number | nil
function M.note_number(name)
    -- Split into pitch class (1-2 chars) and octave number
    local pc_str, oct_str = name:match("^([A-Ga-g][#b]?)(-?%d+)$")
    if not pc_str then return nil end
    -- Normalise to uppercase first letter
    pc_str = pc_str:sub(1, 1):upper() .. pc_str:sub(2)
    local pc = NOTE_NAME_TO_PC[pc_str]
    if pc == nil then return nil end
    local oct = tonumber(oct_str)
    return (oct + 1) * 12 + pc
end

--- Return the frequency in Hz for a MIDI note number.
-- A4 = 69 = 440 Hz.
--: (number) -> number
function M.note_frequency(note)
    return 440.0 * 2 ^ ((note - 69) / 12)
end

-- ── Track builder ─────────────────────────────────────────────────────────────

local TrackBuilder = {}
TrackBuilder.__index = TrackBuilder

--- Create a new track builder.
--: () -> unknown
function M.track()
    return setmetatable({ _events = {} }, TrackBuilder)
end

function TrackBuilder:note_on(tick, channel, note, velocity)
    local e = self._events
    e[#e + 1] = { type = "note_on", tick = tick, channel = channel, note = note, velocity = velocity }
    return self
end

function TrackBuilder:note_off(tick, channel, note, velocity)
    local e = self._events
    e[#e + 1] = { type = "note_off", tick = tick, channel = channel, note = note, velocity = velocity }
    return self
end

--- Add a note_on and note_off pair.
function TrackBuilder:note(tick, duration_ticks, channel, note, velocity)
    self:note_on(tick, channel, note, velocity)
    self:note_off(tick + duration_ticks, channel, note, velocity or 64)
    return self
end

function TrackBuilder:tempo(tick, bpm)
    local e = self._events
    local uspb = floor(60000000 / bpm + 0.5)
    e[#e + 1] = { type = "tempo", tick = tick, bpm = bpm, microseconds_per_beat = uspb }
    return self
end

function TrackBuilder:program(tick, channel, program)
    local e = self._events
    e[#e + 1] = { type = "program_change", tick = tick, channel = channel, program = program }
    return self
end

function TrackBuilder:text(tick, subtype, text)
    local e = self._events
    e[#e + 1] = { type = "text", tick = tick, subtype = subtype, text = text }
    return self
end

--- Finalise and return the track table, sorted by tick, with end_of_track appended.
--: () -> { events: unknown[] }
function TrackBuilder:build()
    local events = {}
    for i, ev in ipairs(self._events) do events[i] = ev end
    table.sort(events, function(a, b)
        if a.tick ~= b.tick then return a.tick < b.tick end
        -- note_off before note_on at the same tick for legato
        if a.type == "note_off" and b.type == "note_on" then return true end
        return false
    end)
    local last_tick = (events[#events] and events[#events].tick) or 0
    events[#events + 1] = { type = "end_of_track", tick = last_tick }
    return { events = events }
end

-- ── MIDI file builder ─────────────────────────────────────────────────────────

local FileBuilder = {}
FileBuilder.__index = FileBuilder

--- Create a MIDI file builder.
-- opts: { format=0|1|2, ticks_per_beat=480 }
--: ({ format: number | nil, ticks_per_beat: number | nil } | nil) -> unknown
function M.file(opts)
    opts = opts or {}
    return setmetatable({
        _format = opts.format or 1,
        _tpb = opts.ticks_per_beat or 480,
        _tracks = {},
    }, FileBuilder)
end

--- Add a track to the file builder.
function FileBuilder:add_track(track)
    self._tracks[#self._tracks + 1] = track
    return self
end

--- Build and return the midi_file table.
--: () -> { format: number, ticks_per_beat: number, tracks: unknown[] }
function FileBuilder:build()
    return {
        format = self._format,
        ticks_per_beat = self._tpb,
        tracks = self._tracks,
    }
end

return M
