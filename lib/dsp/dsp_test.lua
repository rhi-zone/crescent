if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local D = require("lib.dsp")

local function approx(a, b, tol)
  return math.abs(a - b) <= (tol or 1e-9)
end

local function approx_ok(a, b, tol, msg)
  T.ok(approx(a, b, tol), (msg or "") .. " expected ~" .. tostring(b) .. " got " .. tostring(a))
end

-- ───────────────────────────── FFT ─────────────────────────────

T.describe("fft", function()
  T.it("errors on non-power-of-2 length", function()
    local res, err = D.fft({1, 2, 3})
    T.eq(res, nil)
    T.ok(type(err) == "string", "should return error string")
  end)

  T.it("returns complex array of same length", function()
    local sig = D.sine(8, 1/8)
    local spectrum, err = D.fft(sig)
    T.ok(err == nil, "no error")
    T.eq(#spectrum, 8)
    T.ok(type(spectrum[1]) == "table", "elements are tables")
  end)

  T.it("dominant bin for pure sine at bin k", function()
    -- 8-point FFT, frequency = 1/8 cycles/sample → bin 1
    local n = 8
    local sig = D.sine(n, 1/n)
    local spectrum = D.fft(sig)
    -- magnitude at bin 2 (index 2, 0-indexed bin 1) should be dominant
    local mags = {}
    for i = 1, n do
      local r = spectrum[i][1]
      local im = spectrum[i][2]
      mags[i] = math.sqrt(r*r + im*im)
    end
    -- bin 1 (index 2) and its mirror bin 7 (index 8) should be the peaks
    local peak_val = 0
    local peak_idx = 0
    for i = 1, n/2 + 1 do
      if mags[i] > peak_val then peak_val = mags[i]; peak_idx = i end
    end
    T.eq(peak_idx, 2)  -- bin 1 = index 2
  end)

  T.it("accepts complex input", function()
    local sig = {}
    for i = 1, 4 do sig[i] = {i - 1, 0} end
    local result, err = D.fft(sig)
    T.ok(err == nil)
    T.eq(#result, 4)
  end)
end)

-- ───────────────────────────── IFFT round-trip ─────────────────

T.describe("ifft", function()
  T.it("round-trips fft(x) back to x within 1e-9", function()
    local n = 16
    local sig = D.sine(n, 3/n)
    local spectrum = D.fft(sig)
    local recovered = D.ifft(spectrum)
    T.eq(#recovered, n)
    for i = 1, n do
      approx_ok(recovered[i], sig[i], 1e-9, "sample " .. i)
    end
  end)
end)

-- ───────────────────────────── fft_mag ─────────────────────────

T.describe("fft_mag", function()
  T.it("returns length n/2+1", function()
    local sig = D.sine(32, 1/32)
    local mags = D.fft_mag(sig)
    T.eq(#mags, 17)  -- 32/2 + 1
  end)

  T.it("dominant magnitude bin matches frequency", function()
    local n = 32
    local sig = D.sine(n, 2/n)  -- 2 cycles → bin 2 (index 3)
    local mags = D.fft_mag(sig)
    local peak_idx = 1
    for i = 2, #mags do
      if mags[i] > mags[peak_idx] then peak_idx = i end
    end
    T.eq(peak_idx, 3)
  end)
end)

-- ───────────────────────────── psd ─────────────────────────────

T.describe("psd", function()
  T.it("returns length n/2+1", function()
    local sig = D.sine(64, 1/64)
    local p = D.psd(sig)
    T.eq(#p, 33)
  end)

  T.it("all values are non-negative", function()
    local sig = D.noise(64, 1.0, 42)
    local p = D.psd(sig)
    for i = 1, #p do T.ok(p[i] >= 0, "power[" .. i .. "] >= 0") end
  end)
end)

-- ───────────────────────────── convolve ────────────────────────

T.describe("convolve", function()
  T.it("result length is #a + #b - 1", function()
    local a = {1, 2, 3}
    local b = {1, 0, -1}
    local c = D.convolve(a, b)
    T.eq(#c, 5)
  end)

  T.it("impulse convolution is identity", function()
    local sig = {1, 2, 3, 4, 5}
    local imp = {1}
    local result = D.convolve(sig, imp)
    for i = 1, #sig do T.eq(result[i], sig[i]) end
  end)

  T.it("known convolution values", function()
    -- [1,2] * [3,4] = [3, 4+6, 8] = [3, 10, 8]
    local c = D.convolve({1, 2}, {3, 4})
    T.eq(#c, 3)
    approx_ok(c[1], 3,  1e-12, "c[1]")
    approx_ok(c[2], 10, 1e-12, "c[2]")
    approx_ok(c[3], 8,  1e-12, "c[3]")
  end)
end)

-- ───────────────────────────── correlate / autocorrelate ───────

T.describe("correlate", function()
  T.it("result length is #a + #b - 1", function()
    local r = D.correlate({1, 2, 3}, {4, 5})
    T.eq(#r, 4)
  end)
end)

T.describe("autocorrelate", function()
  T.it("result length is 2*#signal - 1", function()
    local sig = {1, 2, 3, 4}
    local r = D.autocorrelate(sig)
    T.eq(#r, 7)
  end)

  T.it("center value equals energy", function()
    local sig = {1, 2, 3}
    local r = D.autocorrelate(sig)
    local center = #r / 2 + 0.5  -- index 3 for length-5
    local energy = D.energy(sig)
    approx_ok(r[math.ceil(#r / 2)], energy, 1e-12, "autocorr center")
  end)
end)

-- ───────────────────────────── windows ─────────────────────────

T.describe("window_rect", function()
  T.it("all ones", function()
    local w = D.window_rect(5)
    T.eq(#w, 5)
    for i = 1, 5 do T.eq(w[i], 1.0) end
  end)
end)

T.describe("window_hann", function()
  T.it("first and last samples near 0", function()
    local w = D.window_hann(64)
    T.eq(#w, 64)
    T.ok(w[1] < 1e-10, "first sample near 0")
    T.ok(w[64] < 1e-10, "last sample near 0")
  end)

  T.it("symmetric", function()
    local w = D.window_hann(16)
    for i = 1, 8 do
      approx_ok(w[i], w[17 - i], 1e-12, "symmetry at " .. i)
    end
  end)

  T.it("peak near 1 at center", function()
    local w = D.window_hann(65)
    approx_ok(w[33], 1.0, 1e-12, "center = 1")
  end)
end)

T.describe("window_hamming", function()
  T.it("correct length and range", function()
    local w = D.window_hamming(32)
    T.eq(#w, 32)
    -- Hamming: min ~0.08, max ~1.0
    T.ok(w[1] < 0.1, "first near 0.08")
    T.ok(w[1] > 0.0, "first positive")
  end)

  T.it("symmetric", function()
    local w = D.window_hamming(10)
    for i = 1, 5 do
      approx_ok(w[i], w[11 - i], 1e-12, "symmetry at " .. i)
    end
  end)
end)

T.describe("window_blackman", function()
  T.it("correct length", function()
    local w = D.window_blackman(32)
    T.eq(#w, 32)
  end)

  T.it("symmetric", function()
    local w = D.window_blackman(16)
    for i = 1, 8 do
      approx_ok(w[i], w[17 - i], 1e-12, "symmetry at " .. i)
    end
  end)
end)

T.describe("window_bartlett", function()
  T.it("correct length and triangular shape", function()
    local w = D.window_bartlett(9)
    T.eq(#w, 9)
    approx_ok(w[1], 0.0, 1e-12, "first = 0")
    approx_ok(w[9], 0.0, 1e-12, "last = 0")
    approx_ok(w[5], 1.0, 1e-12, "center = 1")
  end)
end)

-- ───────────────────────────── apply_window ────────────────────

T.describe("apply_window", function()
  T.it("same length as input", function()
    local sig = D.sine(32, 0.1)
    local w = D.window_hann(32)
    local ws = D.apply_window(sig, w)
    T.eq(#ws, 32)
  end)

  T.it("edge samples zeroed by Hann window", function()
    local sig = D.sine(32, 0.1)
    local w = D.window_hann(32)
    local ws = D.apply_window(sig, w)
    T.ok(math.abs(ws[1]) < 1e-10, "first sample zeroed")
    T.ok(math.abs(ws[32]) < 1e-10, "last sample zeroed")
  end)
end)

-- ───────────────────────────── FIR filters ─────────────────────

T.describe("lpf", function()
  T.it("returns odd number of taps", function()
    local h = D.lpf(0.25, 31)
    T.eq(#h, 31)
  end)

  T.it("symmetric (linear phase)", function()
    local h = D.lpf(0.2, 21)
    for i = 1, 10 do
      approx_ok(h[i], h[22 - i], 1e-12, "symmetry tap " .. i)
    end
  end)

  T.it("passes low frequencies, attenuates high", function()
    local n = 256
    local low_sig = D.sine(n, 0.05)   -- well below cutoff 0.2
    local high_sig = D.sine(n, 0.4)   -- above cutoff 0.2
    local h = D.lpf(0.2, 31)
    local low_out = D.apply_fir(low_sig, h)
    local high_out = D.apply_fir(high_sig, h)
    -- measure steady-state section (skip transient)
    local low_rms = D.rms({unpack(low_out, 64, 256)})
    local high_rms = D.rms({unpack(high_out, 64, 256)})
    T.ok(low_rms > high_rms * 5, "low-freq rms >> high-freq rms after LPF")
  end)
end)

T.describe("hpf", function()
  T.it("returns correct tap count", function()
    local h = D.hpf(0.25, 31)
    T.eq(#h, 31)
  end)

  T.it("attenuates low, passes high", function()
    local n = 256
    local low_sig = D.sine(n, 0.05)   -- below cutoff 0.3
    local high_sig = D.sine(n, 0.45)  -- well above cutoff 0.3
    local h = D.hpf(0.3, 31)
    local low_out = D.apply_fir(low_sig, h)
    local high_out = D.apply_fir(high_sig, h)
    local low_rms = D.rms({unpack(low_out, 64, 256)})
    local high_rms = D.rms({unpack(high_out, 64, 256)})
    T.ok(high_rms > low_rms * 3, "high-freq rms >> low-freq rms after HPF")
  end)
end)

T.describe("bpf", function()
  T.it("returns correct tap count", function()
    local h = D.bpf(0.1, 0.3, 31)
    T.eq(#h, 31)
  end)
end)

T.describe("apply_fir", function()
  T.it("same length as input", function()
    local sig = D.sine(64, 0.1)
    local h = D.lpf(0.2, 11)
    local out = D.apply_fir(sig, h)
    T.eq(#out, 64)
  end)

  T.it("impulse response recovers filter coefficients", function()
    local h = D.lpf(0.2, 11)
    local imp = D.impulse(11, 6)  -- center of 11-tap filter
    local out = D.apply_fir(imp, h)
    -- Center output should equal center coefficient
    approx_ok(out[6], h[6], 1e-12, "center tap matches")
  end)
end)

-- ───────────────────────────── biquad ──────────────────────────

T.describe("biquad", function()
  T.it("lowpass: returns coefficient table", function()
    local c = D.biquad("lowpass", 44100, 1000, 0.707)
    T.ok(type(c) == "table")
    T.ok(c.b0 ~= nil and c.b1 ~= nil and c.b2 ~= nil)
    T.ok(c.a1 ~= nil and c.a2 ~= nil)
  end)

  T.it("unknown type returns nil, err", function()
    local c, err = D.biquad("whatever", 44100, 1000, 1)
    T.eq(c, nil)
    T.ok(type(err) == "string")
  end)

  T.it("apply_biquad returns same length", function()
    local sig = D.sine(64, 0.1)
    local c = D.biquad("lowpass", 44100, 1000, 0.707)
    local out = D.apply_biquad(sig, c)
    T.eq(#out, 64)
  end)

  T.it("lowpass attenuates above cutoff", function()
    local n = 1024
    local fs = 44100
    -- 200 Hz (below 1 kHz cutoff) vs 10 kHz (above)
    local low_sig = D.sine(n, 200/fs)
    local high_sig = D.sine(n, 10000/fs)
    local c = D.biquad("lowpass", fs, 1000, 0.707)
    local low_out = D.apply_biquad(low_sig, c)
    local high_out = D.apply_biquad(high_sig, c)
    local low_rms = D.rms({unpack(low_out, 512, 1024)})
    local high_rms = D.rms({unpack(high_out, 512, 1024)})
    T.ok(low_rms > high_rms * 5, "biquad LPF: low passes, high attenuated")
  end)

  T.it("highpass type works", function()
    local c = D.biquad("highpass", 44100, 1000, 0.707)
    T.ok(c ~= nil)
    T.ok(c.b0 ~= nil)
  end)

  T.it("bandpass type works", function()
    local c = D.biquad("bandpass", 44100, 1000, 1.0)
    T.ok(c ~= nil)
  end)

  T.it("notch type works", function()
    local c = D.biquad("notch", 44100, 1000, 10.0)
    T.ok(c ~= nil)
  end)
end)

-- ───────────────────────────── resample ────────────────────────

T.describe("resample", function()
  T.it("upsample doubles length approximately", function()
    local sig = D.sine(64, 0.1)
    local up = D.resample(sig, 2.0)
    T.eq(#up, 128)
  end)

  T.it("downsample halves length approximately", function()
    local sig = D.sine(64, 0.1)
    local down = D.resample(sig, 0.5)
    T.eq(#down, 32)
  end)

  T.it("ratio=1 preserves signal", function()
    local sig = {1, 2, 3, 4}
    local out = D.resample(sig, 1.0)
    T.eq(#out, 4)
    for i = 1, 4 do approx_ok(out[i], sig[i], 1e-12, "sample " .. i) end
  end)
end)

-- ───────────────────────────── statistics ──────────────────────

T.describe("rms", function()
  T.it("DC signal of value v has rms = v", function()
    local sig = {}
    for i = 1, 8 do sig[i] = 3.0 end
    approx_ok(D.rms(sig), 3.0, 1e-12)
  end)

  T.it("sine rms ≈ amplitude/sqrt(2) for large n", function()
    local n = 1024
    local sig = D.sine(n, 1/n)
    local r = D.rms(sig)
    approx_ok(r, 1.0 / math.sqrt(2), 0.01)
  end)
end)

T.describe("energy", function()
  T.it("impulse energy = 1", function()
    local imp = D.impulse(8, 3)
    approx_ok(D.energy(imp), 1.0, 1e-12)
  end)

  T.it("matches sum of squares", function()
    local sig = {1, 2, 3, 4}
    approx_ok(D.energy(sig), 1+4+9+16, 1e-12)
  end)
end)

T.describe("mean", function()
  T.it("constant signal", function()
    local sig = {}
    for i = 1, 8 do sig[i] = 5.0 end
    approx_ok(D.mean(sig), 5.0, 1e-12)
  end)

  T.it("sine has near-zero mean", function()
    local sig = D.sine(256, 1/256)
    T.ok(math.abs(D.mean(sig)) < 1e-12)
  end)
end)

T.describe("variance", function()
  T.it("constant signal has zero variance", function()
    local sig = {}
    for i = 1, 8 do sig[i] = 7.0 end
    approx_ok(D.variance(sig), 0.0, 1e-12)
  end)

  T.it("known variance", function()
    -- {1,2,3,4,5}: mean=3, var = (4+1+0+1+4)/5 = 2
    approx_ok(D.variance({1,2,3,4,5}), 2.0, 1e-12)
  end)
end)

T.describe("peak", function()
  T.it("sine peak ≈ amplitude", function()
    local n = 256
    local sig = D.sine(n, 4/n, 2.0)
    approx_ok(D.peak(sig), 2.0, 0.01)
  end)

  T.it("zero signal has peak 0", function()
    local sig = {}
    for i = 1, 8 do sig[i] = 0.0 end
    T.eq(D.peak(sig), 0.0)
  end)
end)

T.describe("zero_crossings", function()
  T.it("sine wave: ~2*cycles crossings", function()
    local n = 256
    local cycles = 4
    local sig = D.sine(n, cycles/n)
    local zc = D.zero_crossings(sig)
    -- 4 cycles → ~8 zero crossings
    T.ok(zc >= 7 and zc <= 9, "zero crossings ~8, got " .. zc)
  end)

  T.it("DC signal has 0 crossings", function()
    local sig = {}
    for i = 1, 8 do sig[i] = 1.0 end
    T.eq(D.zero_crossings(sig), 0)
  end)

  T.it("alternating signal has many crossings", function()
    local sig = {1, -1, 1, -1, 1, -1}
    T.eq(D.zero_crossings(sig), 5)
  end)
end)

-- ───────────────────────────── generators ──────────────────────

T.describe("sine", function()
  T.it("correct length", function()
    T.eq(#D.sine(32, 0.1), 32)
  end)

  T.it("peak ≈ amplitude", function()
    local sig = D.sine(256, 3/256, 1.5)
    approx_ok(D.peak(sig), 1.5, 0.02)
  end)

  T.it("period correct: sample at period = sample at 0", function()
    local freq = 0.1
    local period = math.floor(1 / freq)
    local sig = D.sine(period * 4, freq)
    approx_ok(sig[1], sig[period + 1], 1e-10, "sample repeats at period")
  end)

  T.it("zero phase starts at 0", function()
    local sig = D.sine(8, 0.1, 1.0, 0.0)
    approx_ok(sig[1], 0.0, 1e-12)
  end)
end)

T.describe("cosine", function()
  T.it("correct length", function()
    T.eq(#D.cosine(16, 0.1), 16)
  end)

  T.it("starts at amplitude (zero phase)", function()
    local sig = D.cosine(8, 0.1, 2.0, 0.0)
    approx_ok(sig[1], 2.0, 1e-12)
  end)
end)

T.describe("sawtooth", function()
  T.it("correct length", function()
    T.eq(#D.sawtooth(32, 0.1), 32)
  end)

  T.it("peak ≈ amplitude", function()
    local sig = D.sawtooth(256, 0.1, 1.0)
    T.ok(D.peak(sig) <= 1.0 + 1e-12)
  end)
end)

T.describe("square", function()
  T.it("correct length", function()
    T.eq(#D.square(32, 0.1), 32)
  end)

  T.it("only amplitude values", function()
    local sig = D.square(64, 0.1, 3.0)
    for i = 1, #sig do
      T.ok(math.abs(math.abs(sig[i]) - 3.0) < 1e-12, "only ±3")
    end
  end)
end)

T.describe("noise", function()
  T.it("correct length", function()
    T.eq(#D.noise(64, 1.0, 0), 64)
  end)

  T.it("values within ±amplitude", function()
    local sig = D.noise(256, 2.0, 99)
    for i = 1, #sig do
      T.ok(math.abs(sig[i]) <= 2.0 + 1e-12, "within ±2")
    end
  end)

  T.it("same seed produces same output", function()
    local s1 = D.noise(16, 1.0, 42)
    local s2 = D.noise(16, 1.0, 42)
    for i = 1, 16 do T.eq(s1[i], s2[i]) end
  end)

  T.it("different seeds produce different output", function()
    local s1 = D.noise(16, 1.0, 1)
    local s2 = D.noise(16, 1.0, 2)
    local differs = false
    for i = 1, 16 do
      if s1[i] ~= s2[i] then differs = true; break end
    end
    T.ok(differs, "different seeds yield different noise")
  end)
end)

T.describe("chirp", function()
  T.it("correct length", function()
    T.eq(#D.chirp(64, 0.01, 0.4, 1.0), 64)
  end)

  T.it("within amplitude bounds", function()
    local sig = D.chirp(128, 0.01, 0.4, 1.0)
    for i = 1, #sig do
      T.ok(math.abs(sig[i]) <= 1.0 + 1e-12, "within ±1")
    end
  end)
end)

T.describe("impulse", function()
  T.it("correct length", function()
    T.eq(#D.impulse(8, 3), 8)
  end)

  T.it("single 1 at specified position", function()
    local sig = D.impulse(8, 3)
    T.eq(sig[3], 1.0)
    for i = 1, 8 do
      if i ~= 3 then T.eq(sig[i], 0.0) end
    end
  end)

  T.it("default position is 1", function()
    local sig = D.impulse(4)
    T.eq(sig[1], 1.0)
    for i = 2, 4 do T.eq(sig[i], 0.0) end
  end)

  T.it("energy of impulse = 1", function()
    approx_ok(D.energy(D.impulse(16, 7)), 1.0, 1e-12)
  end)
end)
