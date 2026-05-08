if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Comprehensive statistics library: descriptive statistics, probability
--- distributions, hypothesis testing, linear regression, and histograms.
--- Pure Lua, no dependencies.
local M = {}
M._tier = "pure"

local sqrt   = math.sqrt
local abs    = math.abs
local exp    = math.exp
local log    = math.log
local floor  = math.floor
local ceil   = math.ceil
local pi     = math.pi
local huge   = math.huge
local sort   = table.sort

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--:: NumArr = { [integer]: number }

local function check_data(data --[[ : NumArr ]])
  if type(data) ~= "table" or #data == 0 then
    return nil, "data must be a non-empty array"
  end
  return true
end

local function check_pair(x --[[ : NumArr ]], y --[[ : NumArr ]])
  if type(x) ~= "table" or type(y) ~= "table" then
    return nil, "x and y must be arrays"
  end
  if #x == 0 or #y == 0 then
    return nil, "x and y must be non-empty"
  end
  if #x ~= #y then
    return nil, "x and y must have the same length"
  end
  return true
end

--- Return a sorted copy of data.
local function sorted(data --[[ : NumArr ]]) --: NumArr
  local s = {} --: NumArr
  for i = 1, #data do s[i] = data[i] end
  sort(s)
  return s
end

-- ---------------------------------------------------------------------------
-- 1. Descriptive Statistics — Central Tendency
-- ---------------------------------------------------------------------------

function M.mean(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local sum = 0 --: number
  for i = 1, #data do sum = sum + data[i] end
  return sum / #data
end

function M.median(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local s = sorted(data)
  local n = #s
  if n % 2 == 1 then
    return s[(n + 1) / 2]
  else
    return (s[n / 2] + s[n / 2 + 1]) / 2
  end
end

function M.mode(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local counts = {} --: { [number]: integer }
  local max_count = 0
  for i = 1, #data do
    local v = data[i]
    counts[v] = (counts[v] or 0) + 1
    if counts[v] > max_count then max_count = counts[v] end
  end
  local modes = {}
  for v, c in pairs(counts) do
    if c == max_count then modes[#modes + 1] = v end
  end
  sort(modes)
  return modes
end

function M.geometric_mean(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local sum_log = 0 --: number
  for i = 1, #data do
    if data[i] <= 0 then
      return nil, "geometric_mean requires all values > 0"
    end
    sum_log = sum_log + log(data[i])
  end
  return exp(sum_log / #data)
end

function M.harmonic_mean(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local sum_inv = 0 --: number
  for i = 1, #data do
    if data[i] == 0 then
      return nil, "harmonic_mean requires all values != 0"
    end
    sum_inv = sum_inv + 1 / data[i]
  end
  return #data / sum_inv
end

function M.trimmed_mean(data --[[ : NumArr ]], trim --[[ : number | nil ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local trim_ = (trim or 0.1) --: number
  if trim_ < 0 or trim_ >= 0.5 then
    return nil, "trim must be in [0, 0.5)"
  end
  local s = sorted(data)
  local n = #s
  local k = floor(n * trim_)
  local sum = 0 --: number
  local count = 0
  for i = k + 1, n - k do
    sum = sum + s[i]
    count = count + 1
  end
  if count == 0 then return nil, "trimmed_mean: all data trimmed away" end
  local denom = count --: number
  return sum / denom
end

-- ---------------------------------------------------------------------------
-- 1. Descriptive Statistics — Spread
-- ---------------------------------------------------------------------------

function M.variance(data --[[ : NumArr ]], sample)
  local ok, err = check_data(data)
  if not ok then return nil, err end
  if sample == nil then sample = true end
  local n = #data
  if sample and n < 2 then
    return nil, "sample variance requires at least 2 data points"
  end
  local mu = M.mean(data) --[[:! number]]
  local sum_sq = 0 --: number
  for i = 1, n do
    local d = data[i] - mu
    sum_sq = sum_sq + d * d
  end
  return sum_sq / (sample and (n - 1) or n)
end

function M.std(data, sample)
  local v, err = M.variance(data, sample)
  if v == nil then return nil, err end
  return sqrt(v)
end

function M.mad(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local med = M.median(data) --[[:! number]]
  local devs = {} --: NumArr
  for i = 1, #data do devs[i] = abs(data[i] - med) end
  return M.median(devs)
end

function M.range(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local mn, mx = data[1], data[1]
  for i = 2, #data do
    if data[i] < mn then mn = data[i] end
    if data[i] > mx then mx = data[i] end
  end
  return mx - mn
end

function M.iqr(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local q1, q2, q3 = M.quartiles(data)  -- luacheck: ignore q2
  return (q3 --[[:! number]]) - (q1 --[[:! number]])
end

function M.cv(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local mu = M.mean(data) --[[:! number]]
  if mu == 0 then return nil, "cv: mean is zero" end
  local s = M.std(data, true) --[[:! number]]
  return s / mu
end

-- ---------------------------------------------------------------------------
-- 1. Descriptive Statistics — Shape
-- ---------------------------------------------------------------------------

function M.skewness(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local n = #data
  if n < 3 then return nil, "skewness requires at least 3 data points" end
  local mu = M.mean(data) --[[:! number]]
  local s  = M.std(data, true) --[[:! number]]
  if s == 0 then return nil, "skewness: standard deviation is zero" end
  local sum = 0 --: number
  for i = 1, n do
    local z = (data[i] - mu) / s
    sum = sum + z * z * z
  end
  return (n / ((n - 1) * (n - 2))) * sum
end

function M.kurtosis(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local n = #data
  if n < 4 then return nil, "kurtosis requires at least 4 data points" end
  local mu = M.mean(data) --[[:! number]]
  local s  = M.std(data, true) --[[:! number]]
  if s == 0 then return nil, "kurtosis: standard deviation is zero" end
  local sum = 0 --: number
  for i = 1, n do
    local z = (data[i] - mu) / s
    sum = sum + z * z * z * z
  end
  -- Fisher's excess kurtosis (normal distribution = 0)
  local k1 = (n * (n + 1)) / ((n - 1) * (n - 2) * (n - 3))
  local k2 = (3 * (n - 1) * (n - 1)) / ((n - 2) * (n - 3))
  return k1 * sum - k2
end

-- ---------------------------------------------------------------------------
-- 1. Descriptive Statistics — Order Statistics
-- ---------------------------------------------------------------------------

function M.min(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local mn = data[1]
  for i = 2, #data do if data[i] < mn then mn = data[i] end end
  return mn
end

function M.max(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local mx = data[1]
  for i = 2, #data do if data[i] > mx then mx = data[i] end end
  return mx
end

--- Linear interpolation quantile (method 7, same as R default).
function M.quantile(data --[[ : NumArr ]], p)
  local ok, err = check_data(data)
  if not ok then return nil, err end
  if p < 0 or p > 1 then return nil, "p must be in [0, 1]" end
  local s = sorted(data)
  local n = #s
  if n == 1 then return s[1] end
  local h = p * (n - 1) + 1   -- 1-based virtual index
  local lo = floor(h)
  local hi = lo + 1
  if hi > n then return s[n] end
  local frac = h - lo
  return s[lo] + frac * (s[hi] - s[lo])
end

function M.percentile(data, p)
  if p < 0 or p > 100 then return nil, "p must be in [0, 100]" end
  return M.quantile(data, p / 100)
end

function M.quartiles(data)
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local q1, e1 = M.quantile(data, 0.25)
  if q1 == nil then return nil, e1 end
  local q2, e2 = M.quantile(data, 0.50)
  if q2 == nil then return nil, e2 end
  local q3, e3 = M.quantile(data, 0.75)
  if q3 == nil then return nil, e3 end
  return q1, q2, q3
end

function M.five_number_summary(data)
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local mn = M.min(data)
  local mx = M.max(data)
  local q1, q2, q3 = M.quartiles(data)
  return { mn, q1, q2, q3, mx }
end

-- ---------------------------------------------------------------------------
-- 1. Descriptive Statistics — Correlation
-- ---------------------------------------------------------------------------

function M.covariance(x --[[ : NumArr ]], y --[[ : NumArr ]], sample)
  local ok, err = check_pair(x, y)
  if not ok then return nil, err end
  if sample == nil then sample = true end
  local n = #x
  if sample and n < 2 then
    return nil, "sample covariance requires at least 2 data points"
  end
  local mx = M.mean(x) --[[:! number]]
  local my = M.mean(y) --[[:! number]]
  local sum = 0 --: number
  for i = 1, n do
    sum = sum + (x[i] - mx) * (y[i] - my)
  end
  return sum / (sample and (n - 1) or n)
end

function M.correlation(x, y)
  local ok, err = check_pair(x, y)
  if not ok then return nil, err end
  local sx_v, sxe = M.std(x, true)
  if sx_v == nil then return nil, sxe end
  local sy_v, sye = M.std(y, true)
  if sy_v == nil then return nil, sye end
  local sx_ = (sx_v or 0) --: number
  local sy_ = (sy_v or 0) --: number
  if sx_ == 0 or sy_ == 0 then
    return nil, "correlation: standard deviation is zero"
  end
  local cov, cerr = M.covariance(x, y, true)
  if cov == nil then return nil, cerr end
  local cov_ = (cov or 0) --: number
  return cov_ / (sx_ * sy_)
end

--- Spearman rank correlation.
local function rank_data(data --[[ : NumArr ]])
  local n = #data
  -- Create index array sorted by value
  local idx = {} --: { [integer]: integer }
  for i = 1, n do idx[i] = i end
  sort(idx, function(a, b)
    local ai = a --[[:! integer]]
    local bi = b --[[:! integer]]
    return data[ai] < data[bi]
  end)
  local ranks = {}
  local r_start = 1
  while r_start <= n do
    local rj = r_start
    local vi = data[idx[r_start]]  -- value at current run start
    -- find run of equal values
    while rj <= n and data[idx[rj]] == vi do rj = rj + 1 end
    local avg_rank = (r_start + rj - 1) / 2
    for k = r_start, rj - 1 do ranks[idx[k]] = avg_rank end
    r_start = rj
  end
  return ranks
end

function M.spearman(x --[[ : NumArr ]], y --[[ : NumArr ]])
  local ok, err = check_pair(x, y)
  if not ok then return nil, err end
  local rx = rank_data(x)
  local ry = rank_data(y)
  return M.correlation(rx, ry)
end

-- ---------------------------------------------------------------------------
-- 1. Descriptive Statistics — Normalization
-- ---------------------------------------------------------------------------

function M.normalize(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local mu = M.mean(data) --[[:! number]]
  local s_v = M.std(data, true)
  if s_v == nil then return nil, "normalize: std failed" end
  local s = (s_v or 0) --: number
  if s == 0 then return nil, "normalize: standard deviation is zero" end
  local out = {} --: NumArr
  for i = 1, #data do out[i] = (data[i] - mu) / s end
  return out
end

function M.min_max_scale(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local mn = M.min(data) --[[:! number]]
  local mx = M.max(data) --[[:! number]]
  local r  = mx - mn
  if r == 0 then return nil, "min_max_scale: all values are equal" end
  local out = {} --: NumArr
  for i = 1, #data do out[i] = (data[i] - mn) / r end
  return out
end

-- ---------------------------------------------------------------------------
-- 2. Probability Distributions — Normal
-- ---------------------------------------------------------------------------

-- Horner-form rational approximation for erfc(x) on x >= 0 (max |err| < 1.5e-7)
local function erfc(x)
  if x < 0 then return 2 - erfc(-x) end
  local t = 1 / (1 + 0.3275911 * x)
  local poly = t * (0.254829592
    + t * (-0.284496736
    + t * (1.421413741
    + t * (-1.453152027
    + t *  1.061405429))))
  return poly * exp(-x * x)
end

local SQRT2 = sqrt(2)
local SQRT2PI = sqrt(2 * pi)

function M.norm_pdf(x, mu, sigma)
  mu    = mu    or 0
  sigma = sigma or 1
  if sigma <= 0 then return nil, "norm_pdf: sigma must be > 0" end
  local z = (x - mu) / sigma
  return exp(-0.5 * z * z) / (sigma * SQRT2PI)
end

function M.norm_cdf(x, mu, sigma)
  mu    = mu    or 0
  sigma = sigma or 1
  if sigma <= 0 then return nil, "norm_cdf: sigma must be > 0" end
  local z = (x - mu) / (sigma * SQRT2)
  return 0.5 * erfc(-z)
end

-- Rational approximation for the normal inverse CDF (Peter Acklam's method).
-- Max |relative error| < 1.15e-9 for p in (0, 1).
local function norm_inv_standard(p)
  if p <= 0 then return -huge end
  if p >= 1 then return  huge end
  --: { [integer]: number }
  local a = { -3.969683028665376e+01,  2.209460984245205e+02,
              -2.759285104469687e+02,  1.383577518672690e+02,
              -3.066479806614716e+01,  2.506628277459239e+00 }
  --: { [integer]: number }
  local b = { -5.447609879822406e+01,  1.615858368580409e+02,
              -1.556989798598866e+02,  6.680131188771972e+01,
              -1.328068155288572e+01 }
  --: { [integer]: number }
  local c = { -7.784894002430293e-03, -3.223964580411365e-01,
              -2.400758277161838e+00, -2.549732539343734e+00,
               4.374664141464968e+00,  2.938163982698783e+00 }
  --: { [integer]: number }
  local d = {  7.784695709041462e-03,  3.224671290700398e-01,
               2.445134137142996e+00,  3.754408661907416e+00 }
  local p_low  = 0.02425
  local p_high = 1 - p_low
  local q, r
  if p < p_low then
    q = sqrt(-2 * log(p))
    return (((((c[1]*q+c[2])*q+c[3])*q+c[4])*q+c[5])*q+c[6]) /
           ((((d[1]*q+d[2])*q+d[3])*q+d[4])*q+1)
  elseif p <= p_high then
    q = p - 0.5
    r = q * q
    return (((((a[1]*r+a[2])*r+a[3])*r+a[4])*r+a[5])*r+a[6])*q /
           (((((b[1]*r+b[2])*r+b[3])*r+b[4])*r+b[5])*r+1)
  else
    q = sqrt(-2 * log(1 - p))
    return -(((((c[1]*q+c[2])*q+c[3])*q+c[4])*q+c[5])*q+c[6]) /
            ((((d[1]*q+d[2])*q+d[3])*q+d[4])*q+1)
  end
end

function M.norm_inv(p, mu, sigma)
  mu    = mu    or 0
  sigma = sigma or 1
  if sigma <= 0 then return nil, "norm_inv: sigma must be > 0" end
  if p <= 0 or p >= 1 then return nil, "norm_inv: p must be in (0, 1)" end
  return mu + sigma * norm_inv_standard(p)
end

-- ---------------------------------------------------------------------------
-- 2. Probability Distributions — t-distribution
-- ---------------------------------------------------------------------------

-- Regularized incomplete beta function I_x(a,b) via continued fraction (Lentz).
-- Used by t_cdf and chi2_cdf.
local function beta_cf(a, b, x)
  -- Continued fraction representation (Abramowitz & Stegun 26.5.8 / Numerical Recipes)
  local MAXIT = 200
  local EPS   = 3e-7
  local FPMIN = 1e-300
  local qab = a + b
  local qap = a + 1
  local qam = a - 1
  local c   = 1
  local d   = 1 - qab * x / qap
  if abs(d) < FPMIN then d = FPMIN end
  d = 1 / d
  local h = d
  for m = 1, MAXIT do
    local m2 = 2 * m
    -- Even step
    local aa = m * (b - m) * x / ((qam + m2) * (a + m2))
    d = 1 + aa * d
    if abs(d) < FPMIN then d = FPMIN end
    c = 1 + aa / c
    if abs(c) < FPMIN then c = FPMIN end
    d = 1 / d
    h = h * d * c
    -- Odd step
    aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
    d = 1 + aa * d
    if abs(d) < FPMIN then d = FPMIN end
    c = 1 + aa / c
    if abs(c) < FPMIN then c = FPMIN end
    d = 1 / d
    local delta = d * c
    h = h * delta
    if abs(delta - 1) < EPS then break end
  end
  return h
end

-- log(B(a,b)) = lgamma(a) + lgamma(b) - lgamma(a+b)
-- Use Stirling's series for lgamma.
local function lgamma(x)
  -- Lanczos approximation (g=7, n=9)
  --: { [integer]: number }
  local c = { 0.99999999999980993,    676.5203681218851,
              -1259.1392167224028,     771.32342877765313,
              -176.61502916214059,      12.507343278686905,
              -0.13857109526572012,     9.9843695780195716e-6,
               1.5056327351493116e-7 }
  if x < 0.5 then
    return log(pi / (math.sin(pi * x))) - lgamma(1 - x)
  end
  x = x - 1
  local a = c[1]
  local t = x + 7 + 0.5
  for i = 2, 9 do a = a + c[i] / (x + i - 1) end
  return 0.5 * log(2 * pi) + (x + 0.5) * log(t) - t + log(a)
end

-- Regularized incomplete beta I_x(a,b).
local function betai(a, b, x)
  if x < 0 or x > 1 then return nil end
  if x == 0 then return 0 end
  if x == 1 then return 1 end
  local lbeta = lgamma(a) + lgamma(b) - lgamma(a + b)
  local front = exp(log(x) * a + log(1 - x) * b - lbeta) / a
  -- Use symmetry to keep x in the region of faster convergence
  if x < (a + 1) / (a + b + 2) then
    return front * beta_cf(a, b, x)
  else
    return 1 - exp(log(1 - x) * b + log(x) * a - lbeta) / b
              * beta_cf(b, a, 1 - x)
  end
end

function M.t_pdf(x, df)
  if df == nil or df <= 0 then return nil, "t_pdf: df must be > 0" end
  local num = lgamma((df + 1) / 2)
  local den = 0.5 * log(df * pi) + lgamma(df / 2)
  return exp(num - den) * (1 + x * x / df) ^ (-(df + 1) / 2)
end

--- Two-tailed p-value from t_cdf. Returns P(|T| <= |x|) for df.
function M.t_cdf(x, df)
  if df == nil or df <= 0 then return nil, "t_cdf: df must be > 0" end
  -- I_{df/(df+x^2)}(df/2, 1/2)
  local t2 = x * x
  local ib = betai(df / 2, 0.5, df / (df + t2))
  if ib == nil then return nil, "t_cdf: betai failed" end
  local ib_ = (ib or 0) --: number
  return 1 - ib_
end

--- Two-tailed survival: P(|T| > |x|).
local function t_two_tail_p(t_stat --[[ : number ]], df --[[ : number ]])
  local r = (M.t_cdf(t_stat, df) or 0) --: number
  return 1 - r
end

-- ---------------------------------------------------------------------------
-- 2. Probability Distributions — Chi-squared
-- ---------------------------------------------------------------------------

-- Regularized lower incomplete gamma P(a, x) via series expansion.
local function gamma_p_series(a, x)
  if x < 0 then return nil end
  if x == 0 then return 0 end
  local MAXIT = 200
  local EPS   = 3e-7
  local ap  = a
  local sum = 1 / a
  local del = sum
  for _ = 1, MAXIT do
    ap  = ap + 1
    del = del * x / ap
    sum = sum + del
    if abs(del) < abs(sum) * EPS then break end
  end
  return sum * exp(-x + a * log(x) - lgamma(a))
end

-- Regularized upper incomplete gamma Q(a, x) via continued fraction.
local function gamma_q_cf(a, x)
  local MAXIT = 200
  local EPS   = 3e-7
  local FPMIN = 1e-300
  local b = x + 1 - a
  local c = 1 / FPMIN
  local d = 1 / b
  local h = d
  for i = 1, MAXIT do
    local an = -i * (i - a)
    b = b + 2
    d = an * d + b
    if abs(d) < FPMIN then d = FPMIN end
    c = b + an / c
    if abs(c) < FPMIN then c = FPMIN end
    d = 1 / d
    local delta = d * c
    h = h * delta
    if abs(delta - 1) < EPS then break end
  end
  return exp(-x + a * log(x) - lgamma(a)) * h
end

local function gamma_p(a, x)
  if x < (a + 1) then
    return gamma_p_series(a, x)
  else
    return 1 - gamma_q_cf(a, x)
  end
end

--- P(chi2 <= x) for chi-squared with df degrees of freedom.
function M.chi2_cdf(x, df)
  if df == nil or df <= 0 then return nil, "chi2_cdf: df must be > 0" end
  if x < 0 then return 0 end
  return gamma_p(df / 2, x / 2)
end

-- ---------------------------------------------------------------------------
-- 2. Probability Distributions — Poisson
-- ---------------------------------------------------------------------------

local function log_factorial(n)
  -- Use lgamma(n+1) = log(n!)
  return lgamma(n + 1)
end

function M.poisson_pmf(k, lambda)
  if lambda == nil or lambda < 0 then
    return nil, "poisson_pmf: lambda must be >= 0"
  end
  if k < 0 or k ~= floor(k) then
    return nil, "poisson_pmf: k must be a non-negative integer"
  end
  if lambda == 0 then return k == 0 and 1 or 0 end
  return exp(k * log(lambda) - lambda - log_factorial(k))
end

function M.poisson_cdf(k, lambda)
  if lambda == nil or lambda < 0 then
    return nil, "poisson_cdf: lambda must be >= 0"
  end
  if k < 0 or k ~= floor(k) then
    return nil, "poisson_cdf: k must be a non-negative integer"
  end
  local sum = 0 --: number
  for j = 0, k do
    local p, err = M.poisson_pmf(j, lambda)
    if p == nil then return nil, err end
    local p_ = (p or 0) --: number
    sum = sum + p_
  end
  return sum
end

-- ---------------------------------------------------------------------------
-- 2. Probability Distributions — Binomial
-- ---------------------------------------------------------------------------

local function log_binomial_coeff(n, k)
  if k < 0 or k > n then return -huge end
  if k == 0 or k == n then return 0 end
  return lgamma(n + 1) - lgamma(k + 1) - lgamma(n - k + 1)
end

function M.binom_pmf(k, n, p)
  if n == nil or n < 0 or n ~= floor(n) then
    return nil, "binom_pmf: n must be a non-negative integer"
  end
  if k < 0 or k > n or k ~= floor(k) then
    return nil, "binom_pmf: k must be an integer in [0, n]"
  end
  if p < 0 or p > 1 then
    return nil, "binom_pmf: p must be in [0, 1]"
  end
  if p == 0 then return k == 0 and 1 or 0 end
  if p == 1 then return k == n and 1 or 0 end
  return exp(log_binomial_coeff(n, k) + k * log(p) + (n - k) * log(1 - p))
end

function M.binom_cdf(k, n, p)
  if n == nil or n < 0 or n ~= floor(n) then
    return nil, "binom_cdf: n must be a non-negative integer"
  end
  if k < 0 or k ~= floor(k) then
    return nil, "binom_cdf: k must be a non-negative integer"
  end
  if p < 0 or p > 1 then
    return nil, "binom_cdf: p must be in [0, 1]"
  end
  if k >= n then return 1 end
  local sum = 0 --: number
  for j = 0, k do
    local v, err = M.binom_pmf(j, n, p)
    if v == nil then return nil, err end
    local v_ = (v or 0) --: number
    sum = sum + v_
  end
  return sum
end

-- ---------------------------------------------------------------------------
-- 3. Hypothesis Testing
-- ---------------------------------------------------------------------------

function M.t_test_one(data, mu)
  local ok, err = check_data(data)
  if not ok then return nil, err end
  if mu == nil then return nil, "t_test_one: mu is required" end
  local n   = #data
  if n < 2 then return nil, "t_test_one: need at least 2 data points" end
  local xbar = M.mean(data) --[[:! number]]
  local s    = M.std(data, true) --[[:! number]]
  if s == 0 then return nil, "t_test_one: standard deviation is zero" end
  local t    = (xbar - mu) / (s / sqrt(n))
  local df   = n - 1
  local p    = t_two_tail_p(t, df)
  return { t_stat = t, p_value = p, df = df }
end

function M.t_test_two(data1, data2)
  local ok1, err1 = check_data(data1)
  if not ok1 then return nil, err1 end
  local ok2, err2 = check_data(data2)
  if not ok2 then return nil, err2 end
  local n1 = #data1
  local n2 = #data2
  if n1 < 2 then return nil, "t_test_two: data1 needs at least 2 points" end
  if n2 < 2 then return nil, "t_test_two: data2 needs at least 2 points" end
  local m1 = M.mean(data1) --[[:! number]]
  local m2 = M.mean(data2) --[[:! number]]
  local v1 = M.variance(data1, true) --[[:! number]]
  local v2 = M.variance(data2, true) --[[:! number]]
  -- Welch's t-test
  local se  = sqrt(v1 / n1 + v2 / n2)
  if se == 0 then return nil, "t_test_two: standard error is zero" end
  local t   = (m1 - m2) / se
  -- Welch–Satterthwaite df
  local num = (v1 / n1 + v2 / n2) ^ 2
  local den = (v1 / n1) ^ 2 / (n1 - 1) + (v2 / n2) ^ 2 / (n2 - 1)
  local df  = num / den
  local df_int = df --[[:! integer]]
  local p   = t_two_tail_p(t, df_int)
  return { t_stat = t, p_value = p, df = df }
end

function M.chi2_test(observed --[[ : NumArr ]], expected --[[ : NumArr ]])
  if type(observed) ~= "table" or #observed == 0 then
    return nil, "chi2_test: observed must be a non-empty array"
  end
  if type(expected) ~= "table" or #expected ~= #observed then
    return nil, "chi2_test: expected must have the same length as observed"
  end
  local chi2 = 0 --: number
  local df   = #observed - 1
  for i = 1, #observed do
    if expected[i] == 0 then
      return nil, "chi2_test: expected[" .. i .. "] is zero"
    end
    local diff = observed[i] - expected[i]
    chi2 = chi2 + diff * diff / expected[i]
  end
  -- p-value = P(chi2 > stat) = 1 - chi2_cdf(stat, df)
  local chi2_p = (M.chi2_cdf(chi2, df) --[[:! number | nil]]) or 0 --: number
  local p = 1 - chi2_p
  return { chi2_stat = chi2, p_value = p, df = df }
end

function M.correlation_test(x --[[ : NumArr ]], y --[[ : NumArr ]])
  local ok, err = check_pair(x, y)
  if not ok then return nil, err end
  local n = #x
  if n < 3 then return nil, "correlation_test: need at least 3 data points" end
  local r, rerr = M.correlation(x, y)
  if r == nil then return nil, rerr end
  local r_ = (r or 0) --: number
  if abs(r_) >= 1 then
    -- Perfect correlation: t -> inf, p -> 0
    return { r = r_, t_stat = r_ > 0 and huge or -huge, p_value = 0 }
  end
  local t  = r_ * sqrt(n - 2) / sqrt(1 - r_ * r_)
  local df = n - 2
  local p  = t_two_tail_p(t, df)
  return { r = r, t_stat = t, p_value = p }
end

-- ---------------------------------------------------------------------------
-- 4. Linear Regression
-- ---------------------------------------------------------------------------

function M.linear_regression(x --[[ : NumArr ]], y --[[ : NumArr ]])
  local ok, err = check_pair(x, y)
  if not ok then return nil, err end
  local n  = #x
  if n < 2 then return nil, "linear_regression: need at least 2 points" end
  local mx = M.mean(x) --[[:! number]]
  local my = M.mean(y) --[[:! number]]
  local sxx = 0 --: number
  local sxy = 0 --: number
  for i = 1, n do
    local dx = x[i] - mx
    sxx = sxx + dx * dx
    sxy = sxy + dx * (y[i] - my)
  end
  if sxx == 0 then return nil, "linear_regression: x has zero variance" end
  local b   = sxy / sxx
  local a   = my - b * mx
  -- R-squared
  local ss_res = 0 --: number
  local ss_tot = 0 --: number
  local residuals = {} --: NumArr
  for i = 1, n do
    local pred = a + b * x[i]
    local res  = y[i] - pred
    residuals[i] = res
    ss_res = ss_res + res * res
    ss_tot = ss_tot + (y[i] - my) * (y[i] - my)
  end
  local r2 = ss_tot == 0 and 1 or (1 - ss_res / ss_tot)
  return { a = a, b = b, r2 = r2, residuals = residuals }
end

--- Multiple linear regression via normal equations (X^T X)^{-1} X^T y.
--- X: array of row-vectors (each row has the same number of features);
---    an intercept column of ones is prepended automatically.
--- y: array of target values.
--:: NumArr2D = { [integer]: NumArr }

function M.multiple_regression(X --[[ : NumArr2D ]], y --[[ : NumArr ]])
  if type(X) ~= "table" or #X == 0 then
    return nil, "multiple_regression: X must be a non-empty array of row-vectors"
  end
  if type(y) ~= "table" or #y ~= #X then
    return nil, "multiple_regression: y must have the same length as X"
  end
  local n  = #X
  local p0 = #X[1]
  if p0 == 0 then return nil, "multiple_regression: X rows must be non-empty" end
  local p = p0 + 1   -- +1 for intercept

  -- Build augmented design matrix A (n x p) with leading 1 column.
  local A = {} --: NumArr2D
  for i = 1, n do
    A[i] = { 1 } --: NumArr
    for j = 1, p0 do A[i][j + 1] = X[i][j] end
  end

  -- Compute X^T X (p x p) and X^T y (p x 1).
  local XtX = {} --: NumArr2D
  local Xty = {} --: NumArr
  for i = 1, p do
    XtX[i] = {} --: NumArr
    Xty[i] = 0 --: number
    for j = 1, p do
      local s = 0 --: number
      for k = 1, n do s = s + A[k][i] * A[k][j] end
      XtX[i][j] = s
    end
    for k = 1, n do Xty[i] = Xty[i] + A[k][i] * y[k] end
  end

  -- Solve XtX * beta = Xty via Gaussian elimination with partial pivoting.
  -- Augment XtX with Xty as the last column.
  local M2 = {} --: NumArr2D
  for i = 1, p do
    M2[i] = {} --: NumArr
    for j = 1, p do M2[i][j] = XtX[i][j] end
    M2[i][p + 1] = Xty[i]
  end
  for col = 1, p do
    -- Find pivot row
    local max_val = abs(M2[col][col])
    local max_row = col
    for row = col + 1, p do
      if abs(M2[row][col]) > max_val then
        max_val = abs(M2[row][col])
        max_row = row
      end
    end
    if max_val < 1e-14 then
      return nil, "multiple_regression: design matrix is singular or near-singular"
    end
    M2[col], M2[max_row] = M2[max_row], M2[col]
    local piv = M2[col][col]
    for j = col, p + 1 do M2[col][j] = M2[col][j] / piv end
    for row = 1, p do
      if row ~= col then
        local f = M2[row][col]
        for j = col, p + 1 do
          M2[row][j] = M2[row][j] - f * M2[col][j]
        end
      end
    end
  end
  local coeffs = {} --: NumArr
  for i = 1, p do coeffs[i] = M2[i][p + 1] end

  -- Compute residuals and R-squared.
  local y_mean = M.mean(y) --[[:! number]]
  local ss_res = 0 --: number
  local ss_tot = 0 --: number
  local residuals = {} --: NumArr
  for i = 1, n do
    local pred = 0 --: number
    for j = 1, p do pred = pred + coeffs[j] * A[i][j] end
    residuals[i] = y[i] - pred
    ss_res = ss_res + residuals[i] * residuals[i]
    ss_tot = ss_tot + (y[i] - y_mean) * (y[i] - y_mean)
  end
  local r2 = ss_tot == 0 and 1 or (1 - ss_res / ss_tot)
  return { coefficients = coeffs, r2 = r2, residuals = residuals }
end

--- Predict from a simple linear regression model.
function M.predict(model, x_new)
  if type(model) ~= "table" then
    return nil, "predict: model must be a table"
  end
  if model.coefficients then
    -- Multiple regression model
    if type(x_new) ~= "table" then
      return nil, "predict: x_new must be an array for multiple regression"
    end
    local coeffs = model.coefficients
    local pred = coeffs[1]  -- intercept
    for j = 1, #x_new do
      pred = pred + coeffs[j + 1] * x_new[j]
    end
    return pred
  elseif model.a ~= nil and model.b ~= nil then
    -- Simple regression model
    return model.a + model.b * x_new
  else
    return nil, "predict: unrecognized model format"
  end
end

-- ---------------------------------------------------------------------------
-- 5. Histograms and Frequency
-- ---------------------------------------------------------------------------

function M.histogram(data --[[ : NumArr ]], n_bins --[[ : integer | nil ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local n = #data
  local nb = n_bins or (ceil(log(n) / log(2)) + 1)
  if nb < 1 then return nil, "histogram: n_bins must be >= 1" end
  local mn = M.min(data) --[[:! number]]
  local mx = M.max(data) --[[:! number]]
  if mn == mx then
    -- All values equal: one bin
    return { bins = nb, counts = { n }, edges = { mn, mx + 1 } }
  end
  local width = (mx - mn) / nb
  local counts = {} --: { [integer]: integer }
  local edges  = {} --: NumArr
  for i = 0, nb do edges[i + 1] = mn + i * width end
  for i = 1, nb do counts[i] = 0 end
  for i = 1, n do
    local idx = floor((data[i] - mn) / width) + 1
    if idx > nb then idx = nb end  -- clamp max to last bin
    counts[idx] = counts[idx] + 1
  end
  return { bins = nb, counts = counts, edges = edges }
end

function M.frequency(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local freq = {} --: { [number]: integer }
  for i = 1, #data do
    local v = data[i]
    freq[v] = (freq[v] or 0) + 1
  end
  return freq
end

function M.cumulative_frequency(data --[[ : NumArr ]])
  local ok, err = check_data(data)
  if not ok then return nil, err end
  local s = sorted(data)
  local result = {}
  local count  = 0
  local i = 1
  while i <= #s do
    local v = s[i]
    local j = i
    while j <= #s and s[j] == v do j = j + 1 end
    count = j - 1
    result[#result + 1] = { value = v, cum_freq = count, cum_rel = count / #s }
    i = j
  end
  return result
end

return M
