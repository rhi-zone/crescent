if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local math_cos = math.cos
local math_sin = math.sin
local math_sqrt = math.sqrt
local math_abs = math.abs
local math_floor = math.floor
local PI = math.pi

local M = {}
M._tier = "pure"

-- Check if n is a power of 2.
local function is_pow2(n)
  return n > 0 and bit.band(n, n - 1) == 0
end

-- In-place Cooley-Tukey radix-2 FFT.
-- re, im: 1-indexed arrays of length n (n must be a power of 2).
-- invert: if true, computes IFFT (with 1/n normalization).
local function fft_inplace(re, im, invert)
  local n = #re
  -- Bit-reversal permutation (0-indexed logic mapped to 1-indexed arrays).
  local j = 0
  for i = 1, n - 1 do
    local mask = bit.rshift(n, 1)
    while bit.band(j, mask) ~= 0 do
      j = bit.bxor(j, mask)
      mask = bit.rshift(mask, 1)
    end
    j = bit.bxor(j, mask)
    if i < j then
      re[i + 1], re[j + 1] = re[j + 1], re[i + 1]
      im[i + 1], im[j + 1] = im[j + 1], im[i + 1]
    end
  end
  -- Butterfly passes.
  local len = 2
  while len <= n do
    local ang = 2.0 * PI / len * (invert and 1.0 or -1.0)
    local wr = math_cos(ang)
    local wi = math_sin(ang)
    local half = len / 2
    for i = 0, n - 1, len do
      local wre = 1.0 --: number
      local wim = 0.0 --: number
      for k = 0, half - 1 do
        local ui = i + k + 1
        local vi = i + k + half + 1
        local u_re = re[ui]
        local u_im = im[ui]
        local v_re = re[vi] * wre - im[vi] * wim
        local v_im = re[vi] * wim + im[vi] * wre
        re[ui] = u_re + v_re
        im[ui] = u_im + v_im
        re[vi] = u_re - v_re
        im[vi] = u_im - v_im
        local new_wre = wre * wr - wim * wi
        wim = wre * wi + wim * wr
        wre = new_wre
      end
    end
    len = len * 2
  end
  if invert then
    for i = 1, n do
      re[i] = re[i] / n
      im[i] = im[i] / n
    end
  end
end

-- FFT of a signal.
-- Input: array of real numbers, or array of {re, im} tables.
-- Length must be a power of 2.
-- Returns: array of {re, im} complex numbers, or nil, errmsg.
function M.fft(signal)
  local n = #signal
  if not is_pow2(n) then
    return nil, "fft: length must be a power of 2, got " .. n
  end
  local re = {}
  local im = {}
  if type(signal[1]) == "table" then
    for i = 1, n do
      re[i] = signal[i][1] or signal[i].re or 0.0
      im[i] = signal[i][2] or signal[i].im or 0.0
    end
  else
    for i = 1, n do
      re[i] = signal[i]
      im[i] = 0.0
    end
  end
  fft_inplace(re, im, false)
  local result = {}
  for i = 1, n do
    result[i] = { re[i], im[i] }
  end
  return result
end

-- Inverse FFT.
-- Input: array of {re, im} complex numbers.
-- Returns: array of real numbers (imaginary parts discarded after IFFT).
function M.ifft(complex_array)
  local n = #complex_array
  local re = {}
  local im = {}
  for i = 1, n do
    re[i] = complex_array[i][1] or complex_array[i].re or 0.0
    im[i] = complex_array[i][2] or complex_array[i].im or 0.0
  end
  fft_inplace(re, im, true)
  return re
end

-- Magnitude spectrum of a real signal.
-- Returns array of magnitudes, length n/2+1.
function M.fft_mag(signal)
  local result, err = M.fft(signal)
  if not result then return nil, err end
  local n = #signal
  local half = math_floor(n / 2) + 1
  local mags = {}
  for i = 1, half do
    local r = result[i][1]
    local im = result[i][2]
    mags[i] = math_sqrt(r * r + im * im)
  end
  return mags
end

-- Power spectral density.
-- Returns array of power values, length n/2+1.
function M.psd(signal)
  local mags, err = M.fft_mag(signal)
  if not mags then return nil, err end
  local n = #signal
  local result = {}
  for i = 1, #mags do
    local m = mags[i]
    result[i] = (m * m) / n
  end
  return result
end

-- Linear convolution of arrays a and b.
-- Returns result of length #a + #b - 1.
function M.convolve(a, b)
  local na = #a
  local nb = #b
  local nc = na + nb - 1
  local result = {}
  for i = 1, nc do result[i] = 0.0 end
  for i = 1, na do
    local ai = a[i]
    for j = 1, nb do
      result[i + j - 1] = result[i + j - 1] + ai * b[j]
    end
  end
  return result
end

-- Cross-correlation of a and b.
-- result[k] = sum_i a[i] * b[i - (k - center)] — implemented as convolve(a, reverse(b)).
-- Returns result of length #a + #b - 1.
function M.correlate(a, b)
  local nb = #b
  local b_flip = {}
  for i = 1, nb do b_flip[i] = b[nb - i + 1] end
  return M.convolve(a, b_flip)
end

-- Autocorrelation of signal.
function M.autocorrelate(signal)
  return M.correlate(signal, signal)
end

-- Window functions — return array of n weights.

--: (integer) -> { [integer]: number }
function M.window_rect(n)
  local w = {} --: { [integer]: number }
  for i = 1, n do w[i] = 1.0 end
  return w
end

--: (integer) -> { [integer]: number }
function M.window_hann(n)
  local w = {} --: { [integer]: number }
  local nm1 = n - 1
  for i = 1, n do
    w[i] = 0.5 * (1.0 - math_cos(2.0 * PI * (i - 1) / nm1))
  end
  return w
end

--: (integer) -> { [integer]: number }
function M.window_hamming(n)
  local w = {} --: { [integer]: number }
  local nm1 = n - 1
  for i = 1, n do
    w[i] = 0.54 - 0.46 * math_cos(2.0 * PI * (i - 1) / nm1)
  end
  return w
end

--: (integer) -> { [integer]: number }
function M.window_blackman(n)
  local w = {} --: { [integer]: number }
  local nm1 = n - 1
  for i = 1, n do
    local x = 2.0 * PI * (i - 1) / nm1
    w[i] = 0.42 - 0.5 * math_cos(x) + 0.08 * math_cos(2.0 * x)
  end
  return w
end

--: (integer) -> { [integer]: number }
function M.window_bartlett(n)
  local w = {} --: { [integer]: number }
  local half = (n - 1) / 2.0
  for i = 1, n do
    w[i] = 1.0 - math_abs((i - 1 - half) / half)
  end
  return w
end

-- Apply a window function to a signal; returns new array of same length.
function M.apply_window(signal, window)
  local n = #signal
  local result = {}
  for i = 1, n do
    result[i] = signal[i] * (window[i] or 0.0)
  end
  return result
end

-- Sinc function (unnormalized: sinc(x) = sin(pi*x)/(pi*x)).
local function sinc(x)
  if x == 0.0 then return 1.0 end
  local px = PI * x
  return math_sin(px) / px
end

-- FIR low-pass filter via windowed sinc.
-- cutoff: normalized cutoff frequency 0..0.5 (0.5 = Nyquist).
-- n_taps: number of taps (odd; default 31).
-- Returns array of filter coefficients.
--: (number, integer | nil) -> { [integer]: number }
function M.lpf(cutoff, n_taps)
  local n_taps_ = (n_taps or 31) --: integer
  if n_taps_ % 2 == 0 then n_taps_ = n_taps_ + 1 end
  local M_c = (n_taps_ - 1) / 2.0
  local win = M.window_hann(n_taps_)
  local h = {} --: { [integer]: number }
  local sum = 0.0 --: number
  for i = 1, n_taps_ do
    local t = i - 1 - M_c
    h[i] = 2.0 * cutoff * sinc(2.0 * cutoff * t) * win[i]
    sum = sum + h[i]
  end
  for i = 1, n_taps_ do h[i] = h[i] / sum end
  return h
end

-- FIR high-pass filter via spectral inversion of LPF.
--: (number, integer | nil) -> { [integer]: number }
function M.hpf(cutoff, n_taps)
  local n_taps_ = (n_taps or 31) --: integer
  if n_taps_ % 2 == 0 then n_taps_ = n_taps_ + 1 end
  local h = M.lpf(cutoff, n_taps_)
  local center = math_floor((n_taps_ + 1) / 2)
  for i = 1, n_taps_ do h[i] = -(h[i] or 0.0) end
  h[center] = (h[center] or 0.0) + 1.0
  return h
end

-- FIR band-pass filter (difference of two windowed-sinc lowpass kernels).
--: (number, number, integer | nil) -> { [integer]: number }
function M.bpf(low_cutoff, high_cutoff, n_taps)
  local n_taps_ = (n_taps or 31) --: integer
  if n_taps_ % 2 == 0 then n_taps_ = n_taps_ + 1 end
  local M_c = (n_taps_ - 1) / 2.0
  local win = M.window_hann(n_taps_)
  local h = {} --: { [integer]: number }
  local peak = 0.0 --: number
  for i = 1, n_taps_ do
    local t = i - 1 - M_c
    h[i] = (2.0 * high_cutoff * sinc(2.0 * high_cutoff * t)
            - 2.0 * low_cutoff * sinc(2.0 * low_cutoff * t)) * (win[i] or 0.0)
    local a = math_abs(h[i])
    if a > peak then peak = a end
  end
  if peak > 0.0 then
    for i = 1, n_taps_ do h[i] = h[i] / peak end
  end
  return h
end

-- Apply a FIR filter to a signal.
-- Returns filtered signal of same length (zero-padded at boundaries).
function M.apply_fir(signal, coefficients)
  local ns = #signal
  local nh = #coefficients
  local half = math_floor(nh / 2)
  local result = {}
  for i = 1, ns do
    local acc = 0.0
    for k = 1, nh do
      local si = i - k + half + 1
      if si >= 1 and si <= ns then
        acc = acc + signal[si] * coefficients[k]
      end
    end
    result[i] = acc
  end
  return result
end

-- Biquad IIR filter coefficients using the Audio EQ Cookbook formulas.
-- filter_type: "lowpass" | "highpass" | "bandpass" | "notch"
-- fs: sample rate (Hz), f0: center/cutoff frequency (Hz), Q: quality factor.
-- Returns table {b0, b1, b2, a1, a2} (normalized, a0=1), or nil, errmsg.
function M.biquad(filter_type, fs, f0, Q)
  local omega = 2.0 * PI * f0 / fs
  local cos_w = math_cos(omega)
  local sin_w = math_sin(omega)
  local alpha = sin_w / (2.0 * Q)
  local b0 --: number | nil
  local b1 --: number | nil
  local b2 --: number | nil
  local a0 --: number | nil
  local a1 --: number | nil
  local a2 --: number | nil
  if filter_type == "lowpass" then
    b0 = (1.0 - cos_w) / 2.0
    b1 =  1.0 - cos_w
    b2 = (1.0 - cos_w) / 2.0
    a0 =  1.0 + alpha
    a1 = -2.0 * cos_w
    a2 =  1.0 - alpha
  elseif filter_type == "highpass" then
    b0 =  (1.0 + cos_w) / 2.0
    b1 = -(1.0 + cos_w)
    b2 =  (1.0 + cos_w) / 2.0
    a0 =  1.0 + alpha
    a1 = -2.0 * cos_w
    a2 =  1.0 - alpha
  elseif filter_type == "bandpass" then
    b0 =  sin_w / 2.0
    b1 =  0.0
    b2 = -sin_w / 2.0
    a0 =  1.0 + alpha
    a1 = -2.0 * cos_w
    a2 =  1.0 - alpha
  elseif filter_type == "notch" then
    b0 =  1.0
    b1 = -2.0 * cos_w
    b2 =  1.0
    a0 =  1.0 + alpha
    a1 = -2.0 * cos_w
    a2 =  1.0 - alpha
  else
    return nil, "biquad: unknown filter type: " .. tostring(filter_type)
  end
  local a0_ = (a0 or 1.0) --[[:! number]]
  return {
    b0 = (b0 or 0.0) --[[:! number]] / a0_,
    b1 = (b1 or 0.0) --[[:! number]] / a0_,
    b2 = (b2 or 0.0) --[[:! number]] / a0_,
    a1 = (a1 or 0.0) --[[:! number]] / a0_,
    a2 = (a2 or 0.0) --[[:! number]] / a0_,
  }
end

--:: BiquadCoeff = { b0: number, b1: number, b2: number, a1: number, a2: number }

-- Apply a biquad filter to a signal (direct form II transposed).
--: ({ [integer]: number }, BiquadCoeff) -> { [integer]: number }
function M.apply_biquad(signal, coeff)
  local n = #signal
  local result = {}
  local b0 = coeff.b0
  local b1 = coeff.b1
  local b2 = coeff.b2
  local a1 = coeff.a1
  local a2 = coeff.a2
  local d1 = 0.0 --: number
  local d2 = 0.0 --: number
  for i = 1, n do
    local x = signal[i]
    local y = b0 * x + d1
    d1 = b1 * x - a1 * y + d2
    d2 = b2 * x - a2 * y
    result[i] = y
  end
  return result
end

-- Resample a signal by a rational ratio (linear interpolation).
-- ratio = target_rate / source_rate.
function M.resample(signal, ratio)
  local n = #signal
  local out_n = math_floor(n * ratio)
  local result = {}
  for i = 1, out_n do
    local src_pos = (i - 1) / ratio
    local src_i = math_floor(src_pos)
    local frac = src_pos - src_i
    local s0 = signal[src_i + 1] or 0.0
    local s1 = signal[src_i + 2] or s0
    result[i] = s0 + frac * (s1 - s0)
  end
  return result
end

-- Statistics

-- Root mean square.
function M.rms(signal)
  local n = #signal
  local sum = 0.0
  for i = 1, n do sum = sum + signal[i] * signal[i] end
  return math_sqrt(sum / n)
end

-- Sum of squared samples.
function M.energy(signal)
  local sum = 0.0
  for i = 1, #signal do sum = sum + signal[i] * signal[i] end
  return sum
end

-- Arithmetic mean.
function M.mean(signal)
  local n = #signal
  local sum = 0.0
  for i = 1, n do sum = sum + signal[i] end
  return sum / n
end

-- Variance (population variance).
function M.variance(signal)
  local n = #signal
  local mu = M.mean(signal)
  local sum = 0.0
  for i = 1, n do
    local d = signal[i] - mu
    sum = sum + d * d
  end
  return sum / n
end

-- Maximum absolute sample value.
function M.peak(signal)
  local p = 0.0 --: number
  for i = 1, #signal do
    local a = math_abs(signal[i])
    if a > p then p = a end
  end
  return p
end

-- Number of sign changes (zero crossings).
function M.zero_crossings(signal)
  local n = #signal
  local count = 0
  for i = 2, n do
    if (signal[i - 1] >= 0.0 and signal[i] < 0.0) or
       (signal[i - 1] < 0.0 and signal[i] >= 0.0) then
      count = count + 1
    end
  end
  return count
end

-- Signal generators

-- Sine wave: n samples, freq in cycles/sample (0..0.5), amplitude, phase in radians.
function M.sine(n, freq, amplitude, phase)
  amplitude = amplitude or 1.0
  phase = phase or 0.0
  local result = {}
  local two_pi_f = 2.0 * PI * freq
  for i = 1, n do
    result[i] = amplitude * math_sin(two_pi_f * (i - 1) + phase)
  end
  return result
end

-- Cosine wave.
function M.cosine(n, freq, amplitude, phase)
  amplitude = amplitude or 1.0
  phase = phase or 0.0
  local result = {}
  local two_pi_f = 2.0 * PI * freq
  for i = 1, n do
    result[i] = amplitude * math_cos(two_pi_f * (i - 1) + phase)
  end
  return result
end

-- Sawtooth wave (rises linearly, resets).
function M.sawtooth(n, freq, amplitude)
  amplitude = amplitude or 1.0
  local result = {}
  for i = 1, n do
    local t = (i - 1) * freq
    result[i] = amplitude * (2.0 * (t - math_floor(t + 0.5)))
  end
  return result
end

-- Square wave.
function M.square(n, freq, amplitude)
  local amplitude_ = (amplitude or 1.0) --: number
  local result = {}
  local two_pi_f = 2.0 * PI * freq
  for i = 1, n do
    result[i] = math_sin(two_pi_f * (i - 1)) >= 0.0 and amplitude_ or -amplitude_
  end
  return result
end

-- White noise with optional seed (LCG PRNG, values in [-amplitude, amplitude]).
function M.noise(n, amplitude, seed)
  amplitude = amplitude or 1.0
  seed = seed or 12345
  local result = {}
  local state = seed
  for i = 1, n do
    -- LCG: a=1664525, c=1013904223, masked to 31 bits for positive values.
    state = bit.band(1664525 * state + 1013904223, 0x7fffffff)
    result[i] = amplitude * (state / 0x3fffffff - 1.0)
  end
  return result
end

-- Linear frequency sweep (chirp) from f0 to f1 (cycles/sample).
function M.chirp(n, f0, f1, amplitude)
  amplitude = amplitude or 1.0
  local result = {}
  local denom = n > 1 and (n - 1) or 1
  for i = 1, n do
    local t = i - 1
    -- Instantaneous phase: integral of 2*pi*(f0 + (f1-f0)*t/T)
    local phase = 2.0 * PI * (f0 * t + 0.5 * (f1 - f0) * t * t / denom)
    result[i] = amplitude * math_sin(phase)
  end
  return result
end

-- Impulse: 1.0 at position pos (1-indexed), 0 elsewhere.
function M.impulse(n, pos)
  local pos_ = (pos or 1) --: integer
  local result = {} --: { [integer]: number }
  for i = 1, n do result[i] = 0.0 end
  if pos_ >= 1 and pos_ <= n then result[pos_] = 1.0 end
  return result
end

return M
