if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local math_sqrt = math.sqrt
local math_abs = math.abs
local math_floor = math.floor

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Wavelet filter definitions
-- ---------------------------------------------------------------------------

local SQRT2 = math_sqrt(2)
local INV_SQRT2 = 1 / SQRT2

-- Each wavelet entry: dec_lo, dec_hi, rec_lo, rec_hi, vanishing_moments
local WAVELETS = {}

-- Haar (db1)
-- Convention: dec_hi = {h, -h} (positive-first).
-- For the circular upsample+accumulate synthesis (adjoint of conv_down),
-- rec filters equal the dec filters (no time-reversal needed).
do
  local h = INV_SQRT2
  WAVELETS["haar"] = {
    name = "haar",
    vanishing_moments = 1,
    dec_lo = { h,  h },
    dec_hi = { h, -h },
    rec_lo = { h,  h },
    rec_hi = { h, -h },
  }
  -- Alias
  WAVELETS["db1"] = WAVELETS["haar"]
end

-- db2 (Daubechies 4-tap, 2 vanishing moments)
do
  local s3 = math_sqrt(3)
  local s2_4 = 4 * SQRT2
  local dl = {
    (1 + s3) / s2_4,
    (3 + s3) / s2_4,
    (3 - s3) / s2_4,
    (1 - s3) / s2_4,
  }
  -- dec_hi[k] = (-1)^(k-1) * dec_lo[L+1-k], L=4, 1-indexed
  -- = (-1)^(k-1) * dl[5-k]
  local dh = {
    -dl[4],  -- k=1: (-1)^0 * dl[4]
     dl[3],  -- k=2: (-1)^1 * dl[3] = -dl[3]? Let's use standard QMF relation
    -dl[2],
     dl[1],
  }
  -- Standard QMF relation: dec_hi[k] = (-1)^k * dec_lo[L-k+1]
  -- with 0-indexed k: dec_hi[k] = (-1)^k * dec_lo[L-1-k]
  -- 1-indexed: dec_hi[k] = (-1)^(k+1) * dec_lo[L-k+1]
  -- k=1: (-1)^2 * dl[4] = dl[4]
  -- k=2: (-1)^3 * dl[3] = -dl[3]
  -- k=3: (-1)^4 * dl[2] = dl[2]
  -- k=4: (-1)^5 * dl[1] = -dl[1]
  -- Use hardcoded numeric values from spec:
  -- Hardcoded numeric values; rec filters same as dec (adjoint synthesis).
  local dec_lo = { 0.4829629131, 0.8365163037,  0.2241438680, -0.1294095226 }
  local dec_hi = {-0.1294095226,-0.2241438680,  0.8365163037, -0.4829629131 }
  WAVELETS["db2"] = {
    name = "db2",
    vanishing_moments = 2,
    dec_lo = dec_lo,
    dec_hi = dec_hi,
    rec_lo = dec_lo,
    rec_hi = dec_hi,
  }
  -- sym2 is essentially same as db2
  WAVELETS["sym2"] = {
    name = "sym2",
    vanishing_moments = 2,
    dec_lo = dec_lo,
    dec_hi = dec_hi,
    rec_lo = dec_lo,
    rec_hi = dec_hi,
  }
end

-- db4 (Daubechies 8-tap, 4 vanishing moments)
do
  local dec_lo = {
     0.23037781330885523,
     0.7148465705525415,
     0.6308807679295904,
    -0.02798376941698385,
    -0.18703481171888114,
     0.030841381835986965,
     0.032883011666982945,
    -0.010597401784997278,
  }
  local dec_hi = {
    -0.010597401784997278,
    -0.032883011666982945,
     0.030841381835986965,
     0.18703481171888114,
    -0.02798376941698385,
    -0.6308807679295904,
     0.7148465705525415,
    -0.23037781330885523,
  }
  WAVELETS["db4"] = {
    name = "db4",
    vanishing_moments = 4,
    dec_lo = dec_lo,
    dec_hi = dec_hi,
    rec_lo = dec_lo,
    rec_hi = dec_hi,
  }
end

-- coif1 (Coiflet 1, 6-tap, 2 vanishing moments for wavelet, 2 for scaling)
do
  local dec_lo = {
    -0.01565572813546454,
    -0.07273261951285058,
     0.3848648468648579,
     0.8525720202122554,
     0.3378976624578092,
    -0.07273261951285058,
  }
  local dec_hi = {
    -0.07273261951285058,
    -0.3378976624578092,
     0.8525720202122554,
    -0.3848648468648579,
    -0.07273261951285058,
     0.01565572813546454,
  }
  WAVELETS["coif1"] = {
    name = "coif1",
    vanishing_moments = 2,
    dec_lo = dec_lo,
    dec_hi = dec_hi,
    rec_lo = dec_lo,
    rec_hi = dec_hi,
  }
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Circular convolution with downsampling by 2.
-- Returns output of length floor(n/2) where n = #signal.
local function conv_down(signal, filter)
  local n = #signal
  local flen = #filter
  local out_len = math_floor(n / 2)
  local out = {}
  for i = 1, out_len do
    local s = 0
    for k = 1, flen do
      -- 0-indexed position: 2*(i-1) + (k-1)
      local idx = (2 * (i - 1) + (k - 1)) % n + 1
      s = s + filter[k] * signal[idx]
    end
    out[i] = s
  end
  return out
end

-- Upsample by 2 and convolve (synthesis step).
-- input has length n; output has length 2*n.
-- The upsampled signal inserts a zero between each sample (even indices become 0).
-- With 1-indexed filter of length flen, output[j] = sum_k filter[k] * upsampled[j-k+1]
-- But we use the adjoint / synthesis convolution:
--   output[j] = sum_{i} input[i] * rec[j - 2*i + 1]  (linear, zero-padded boundaries)
-- We'll accumulate by upsample+overlap.
local function upsample_conv(input, filter, out_len)
  local n = #input
  local flen = #filter
  local out = {}
  for j = 1, out_len do out[j] = 0 end
  for i = 1, n do
    for k = 1, flen do
      -- position in output: 2*(i-1) + (k-1) + 1, with circular wrap
      local j = (2 * (i - 1) + (k - 1)) % out_len + 1
      out[j] = out[j] + input[i] * filter[k]
    end
  end
  return out
end

local function get_wavelet(name)
  local w = WAVELETS[name]
  if not w then
    return nil, "unknown wavelet: " .. tostring(name)
  end
  return w
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Return wavelet filter info.
function M.wavelet_info(name)
  local w, err = get_wavelet(name)
  if not w then return nil, err end
  return {
    name = w.name,
    dec_lo = w.dec_lo,
    dec_hi = w.dec_hi,
    rec_lo = w.rec_lo,
    rec_hi = w.rec_hi,
    vanishing_moments = w.vanishing_moments,
  }
end

-- 1D forward DWT.
-- signal: 1-indexed array of numbers (length should be even).
-- Returns approx, detail (each of length floor(#signal/2)).
function M.dwt(signal, wavelet_name)
  local w, err = get_wavelet(wavelet_name or "haar")
  if not w then return nil, err end
  local n = #signal
  if n < 2 then return nil, "signal too short" end
  local approx = conv_down(signal, w.dec_lo)
  local detail = conv_down(signal, w.dec_hi)
  return approx, detail
end

-- 1D inverse DWT.
-- approx, detail: coefficient arrays of equal length.
-- Returns reconstructed signal of length 2 * #approx.
function M.idwt(approx, detail, wavelet_name)
  local w, err = get_wavelet(wavelet_name or "haar")
  if not w then return nil, err end
  if #approx ~= #detail then
    return nil, "approx and detail must have equal length"
  end
  local n = #approx
  local out_len = 2 * n
  local lo = upsample_conv(approx, w.rec_lo, out_len)
  local hi = upsample_conv(detail, w.rec_hi, out_len)
  local out = {}
  for i = 1, out_len do
    out[i] = lo[i] + hi[i]
  end
  return out
end

-- Multi-level 1D decomposition.
-- Returns coeffs table: coeffs[1] = final approx, coeffs[2..level+1] = details coarsest→finest.
function M.wavedec(signal, level, wavelet_name)
  if level < 1 then return nil, "level must be >= 1" end
  local w, err = get_wavelet(wavelet_name or "haar")
  if not w then return nil, err end

  local coeffs = {}
  local current = signal
  local details = {}
  for lv = 1, level do
    local approx, detail = M.dwt(current, wavelet_name)
    if not approx then return nil, detail end
    details[lv] = detail
    current = approx
  end
  -- coeffs[1] = deepest approx; coeffs[2] = detail at deepest level; ...
  coeffs[1] = current
  for lv = level, 1, -1 do
    coeffs[level - lv + 2] = details[lv]
  end
  return coeffs
end

-- Multi-level 1D reconstruction.
-- coeffs: {approx_n, detail_n, detail_{n-1}, ..., detail_1} as returned by wavedec.
-- Returns reconstructed signal.
function M.waverec(coeffs, wavelet_name)
  if not coeffs or #coeffs < 2 then
    return nil, "coeffs must have at least 2 entries"
  end
  local level = #coeffs - 1
  local current = coeffs[1]
  for lv = 1, level do
    local detail = coeffs[lv + 1]
    local rec, err = M.idwt(current, detail, wavelet_name)
    if not rec then return nil, err end
    current = rec
  end
  return current
end

-- ---------------------------------------------------------------------------
-- 2D DWT
-- ---------------------------------------------------------------------------

-- Apply 1D DWT to each row of a 2D matrix.
-- matrix: array of rows, each row is a 1D array.
-- Returns {lo_rows, hi_rows}.
local function dwt_rows(matrix, w_name)
  local lo_rows, hi_rows = {}, {}
  for r = 1, #matrix do
    local a, d = M.dwt(matrix[r], w_name)
    if not a then return nil, nil, d end
    lo_rows[r] = a
    hi_rows[r] = d
  end
  return lo_rows, hi_rows
end

-- Apply 1D DWT to each column of a 2D matrix.
-- Returns {lo_cols, hi_cols} as 2D arrays.
local function dwt_cols(matrix, w_name)
  local rows = #matrix
  local cols = #matrix[1]
  -- Build column signals, apply DWT, scatter back.
  local half = math_floor(rows / 2)
  local lo = {}
  local hi = {}
  for r = 1, half do lo[r] = {} end
  for r = 1, half do hi[r] = {} end

  for c = 1, cols do
    local col = {}
    for r = 1, rows do col[r] = matrix[r][c] end
    local a, d = M.dwt(col, w_name)
    if not a then return nil, nil, d end
    for r = 1, half do
      lo[r][c] = a[r]
      hi[r][c] = d[r]
    end
  end
  return lo, hi
end

-- 2D forward DWT.
-- matrix: 2D array (rows × cols), both dimensions must be even.
-- Returns LL, LH, HL, HH subbands.
function M.dwt2(matrix, wavelet_name)
  local w_name = wavelet_name or "haar"
  -- First pass: apply along rows
  local lo_rows, hi_rows, err = dwt_rows(matrix, w_name)
  if not lo_rows then return nil, nil, nil, nil, err end

  -- Second pass: apply along columns of each row-filtered result
  local LL, HL, err2 = dwt_cols(lo_rows, w_name)
  if not LL then return nil, nil, nil, nil, err2 end
  local LH, HH, err3 = dwt_cols(hi_rows, w_name)
  if not LH then return nil, nil, nil, nil, err3 end

  return LL, LH, HL, HH
end

-- Apply 1D IDWT to each row of approx/detail row pairs.
local function idwt_rows(lo_rows, hi_rows, w_name)
  local result = {}
  for r = 1, #lo_rows do
    local rec, err = M.idwt(lo_rows[r], hi_rows[r], w_name)
    if not rec then return nil, err end
    result[r] = rec
  end
  return result
end

-- Apply 1D IDWT to each column.
local function idwt_cols(lo_mat, hi_mat, w_name)
  local rows_lo = #lo_mat
  local out_rows = rows_lo * 2
  local cols = #lo_mat[1]
  local result = {}
  for r = 1, out_rows do result[r] = {} end
  for c = 1, cols do
    local lo_col, hi_col = {}, {}
    for r = 1, rows_lo do
      lo_col[r] = lo_mat[r][c]
      hi_col[r] = hi_mat[r][c]
    end
    local rec, err = M.idwt(lo_col, hi_col, w_name)
    if not rec then return nil, err end
    for r = 1, out_rows do
      result[r][c] = rec[r]
    end
  end
  return result
end

-- 2D inverse DWT.
-- LL, LH, HL, HH: subbands as returned by dwt2.
-- Returns reconstructed 2D matrix.
function M.idwt2(LL, LH, HL, HH, wavelet_name)
  local w_name = wavelet_name or "haar"
  -- Reconstruct column direction first (inverse of second pass)
  local lo_rows, err1 = idwt_cols(LL, HL, w_name)
  if not lo_rows then return nil, err1 end
  local hi_rows, err2 = idwt_cols(LH, HH, w_name)
  if not hi_rows then return nil, err2 end
  -- Reconstruct row direction
  local result, err3 = idwt_rows(lo_rows, hi_rows, w_name)
  if not result then return nil, err3 end
  return result
end

-- ---------------------------------------------------------------------------
-- Threshold (denoising)
-- ---------------------------------------------------------------------------

-- Apply threshold to an array in-place.
-- mode = "hard" or "soft"
function M.threshold(coeffs, thresh, mode)
  mode = mode or "hard"
  local abs = math_abs
  if mode == "hard" then
    for i = 1, #coeffs do
      if abs(coeffs[i]) < thresh then
        coeffs[i] = 0
      end
    end
  elseif mode == "soft" then
    for i = 1, #coeffs do
      local v = coeffs[i]
      local av = abs(v)
      if av <= thresh then
        coeffs[i] = 0
      elseif v > 0 then
        coeffs[i] = v - thresh
      else
        coeffs[i] = v + thresh
      end
    end
  else
    return nil, "unknown threshold mode: " .. tostring(mode)
  end
  return coeffs
end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

-- Pad signal with zeros to next power of 2 length.
function M.pad_to_power_of_2(signal)
  local n = #signal
  local p = 1
  while p < n do p = p * 2 end
  if p == n then
    -- Already power of 2; return copy
    local out = {}
    for i = 1, n do out[i] = signal[i] end
    return out
  end
  local out = {}
  for i = 1, n do out[i] = signal[i] end
  for i = n + 1, p do out[i] = 0 end
  return out
end

return M
