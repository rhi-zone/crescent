if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Financial math library for crescent.
-- Pure Lua implementation of core financial primitives:
--   time value of money, compound interest, amortization,
--   statistical finance, Black-Scholes option pricing.

local M = {}

M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local exp  = math.exp
local log  = math.log
local sqrt = math.sqrt
local abs  = math.abs
local floor = math.floor
local huge = math.huge

-- ---------------------------------------------------------------------------
-- 6. Rounding (placed first — used by other functions)
-- ---------------------------------------------------------------------------

-- Banker's rounding (half-even): round `value` to `decimals` decimal places.
-- Ties (exactly 0.5) round to the nearest even digit.
--: (number, number) -> number
M.round = function(value, decimals)
  local factor = 10 ^ (decimals or 0)
  local shifted = value * factor
  local floored = floor(shifted)
  local diff = shifted - floored
  local result
  if diff > 0.5 then
    result = floored + 1
  elseif diff < 0.5 then
    result = floored
  else
    -- exactly 0.5 — round to even
    if floored % 2 == 0 then
      result = floored
    else
      result = floored + 1
    end
  end
  return result / factor
end

-- ---------------------------------------------------------------------------
-- 1. Time Value of Money
-- ---------------------------------------------------------------------------

-- Present value of a future sum.
-- PV = FV / (1 + r)^n
--: (number, number, number) -> (number | nil, string)
M.pv = function(fv, rate, periods)
  if periods < 0 then return nil, "periods must be non-negative" end
  return fv / (1 + rate) ^ periods
end

-- Future value of a present sum.
-- FV = PV * (1 + r)^n
--: (number, number, number) -> (number | nil, string)
M.fv = function(pv, rate, periods)
  if periods < 0 then return nil, "periods must be non-negative" end
  return pv * (1 + rate) ^ periods
end

-- Net present value of a cash flow series.
-- cash_flows[1] is period 0 (usually the initial investment, negative).
--: (number, { [number]: number }) -> number
M.npv = function(rate, cash_flows)
  local total --: number
  total = 0.0
  for i, cf in ipairs(cash_flows) do
    total = total + cf / (1 + rate) ^ (i - 1)
  end
  return total
end

-- Internal rate of return via Newton's method.
-- Returns the rate at which NPV = 0, or nil if no convergence.
--: ({ [number]: number }, number | nil) -> number | nil
M.irr = function(cash_flows, initial_guess)
  local rate = initial_guess or 0.1
  local max_iter = 1000
  local tol = 1e-10

  for _ = 1, max_iter do
    local npv --: number
    npv = 0.0
    local dnpv --: number
    dnpv = 0.0
    for i, cf in ipairs(cash_flows) do
      local t = i - 1
      local denom = (1 + rate) ^ t
      npv = npv + cf / denom
      if t > 0 then
        dnpv = dnpv - t * cf / ((1 + rate) ^ (t + 1))
      end
    end
    if abs(dnpv) < 1e-15 then return nil end
    local new_rate = rate - npv / dnpv
    if abs(new_rate - rate) < tol then
      return new_rate
    end
    rate = new_rate
  end
  return nil
end

-- Present value of an annuity (series of equal periodic payments).
-- annuity_type: 0 = ordinary (end of period), 1 = due (beginning of period).
--: (number, number, number, number | nil) -> (number | nil, string)
M.pv_annuity = function(pmt, rate, n, annuity_type)
  if n < 0 then return nil, "periods must be non-negative" end
  annuity_type = annuity_type or 0
  if rate == 0 then
    local base = pmt * n
    return annuity_type == 1 and base or base
  end
  local factor = (1 - (1 + rate) ^ (-n)) / rate
  if annuity_type == 1 then factor = factor * (1 + rate) end
  return pmt * factor
end

-- Future value of an annuity.
--: (number, number, number, number | nil) -> (number | nil, string)
M.fv_annuity = function(pmt, rate, n, annuity_type)
  if n < 0 then return nil, "periods must be non-negative" end
  annuity_type = annuity_type or 0
  if rate == 0 then
    return pmt * n
  end
  local factor = ((1 + rate) ^ n - 1) / rate
  if annuity_type == 1 then factor = factor * (1 + rate) end
  return pmt * factor
end

-- Periodic payment for a loan (ordinary annuity payment).
-- pv: loan amount; rate: periodic rate; n: number of periods.
--: (number, number, number) -> (number | nil, string)
M.pmt = function(pv, rate, n)
  if n <= 0 then return nil, "periods must be positive" end
  if rate == 0 then return pv / n end
  return pv * rate / (1 - (1 + rate) ^ (-n))
end

-- Number of periods needed to reach a target future value.
-- nper(pv, rate, pmt, fv): solve for n in fv = pv*(1+r)^n + pmt*((1+r)^n - 1)/r
-- Assumes ordinary annuity (payments at end of period).
--: (number, number, number, number) -> (number | nil, string)
M.nper = function(pv, rate, pmt, fv)
  if rate == 0 then
    if pmt == 0 then return nil, "cannot solve: rate=0 and pmt=0" end
    return (fv - pv) / pmt
  end
  -- From: fv = pv*(1+r)^n + pmt/r*((1+r)^n - 1)
  -- => (1+r)^n = (fv + pmt/r) / (pv + pmt/r)
  local num = fv + pmt / rate
  local den = pv + pmt / rate
  if den == 0 then return nil, "cannot solve: denominator is zero" end
  if num / den <= 0 then return nil, "no real solution" end
  return log(num / den) / log(1 + rate)
end

-- ---------------------------------------------------------------------------
-- 2. Compound Interest
-- ---------------------------------------------------------------------------

-- Effective annual rate from nominal rate.
-- nominal: annual nominal rate; n: compounding periods per year.
--: (number, number) -> (number | nil, string)
M.ear = function(nominal, n)
  if n <= 0 then return nil, "compounding periods must be positive" end
  return (1 + nominal / n) ^ n - 1
end

-- Future value with continuous compounding: FV = PV * e^(r*t)
--: (number, number, number) -> number
M.continuous_fv = function(pv, rate, time)
  return pv * exp(rate * time)
end

-- Present value with continuous compounding: PV = FV * e^(-r*t)
--: (number, number, number) -> number
M.continuous_pv = function(fv, rate, time)
  return fv * exp(-rate * time)
end

-- APR to APY conversion (APY = EAR).
-- apr: annual percentage rate; n: compounding periods per year.
--: (number, number) -> (number | nil, string)
M.apr_to_apy = function(apr, n)
  return M.ear(apr, n)
end

-- APY to APR conversion.
--: (number, number) -> (number | nil, string)
M.apy_to_apr = function(apy, n)
  if n <= 0 then return nil, "compounding periods must be positive" end
  return n * ((1 + apy) ^ (1 / n) - 1)
end

-- ---------------------------------------------------------------------------
-- 3. Amortization
-- ---------------------------------------------------------------------------

-- Generate full amortization schedule for a loan.
-- Returns array of {period, payment, principal, interest, balance}.
-- rate: periodic rate (e.g. monthly_rate = annual_rate / 12).
--: (number, number, number) -> ({ [number]: { period: number, payment: number, principal: number, interest: number, balance: number } } | nil, string)
M.amortize = function(principal, rate, periods)
  if periods <= 0 then return nil, "periods must be positive" end
  if principal <= 0 then return nil, "principal must be positive" end
  local payment, err = M.pmt(principal, rate, periods)
  if not payment then return nil, err end

  local schedule = {}
  local balance = principal
  for i = 1, periods do
    local interest
    if rate == 0 then
      interest = 0
    else
      interest = balance * rate
    end
    local princ = payment - interest
    balance = balance - princ
    -- clamp final balance to 0 (floating point dust)
    if i == periods then balance = 0 end
    schedule[i] = {
      period    = i,
      payment   = payment,
      principal = princ,
      interest  = interest,
      balance   = balance,
    }
  end
  return schedule
end

-- Total interest paid over the life of a loan.
--: (number, number, number) -> (number | nil, string)
M.total_interest = function(principal, rate, periods)
  local payment, err = M.pmt(principal, rate, periods)
  if not payment then return nil, err end
  return payment * periods - principal
end

-- ---------------------------------------------------------------------------
-- 4. Statistical Finance
-- ---------------------------------------------------------------------------

-- Compute per-period simple returns from a price series.
-- returns[i] = (prices[i+1] - prices[i]) / prices[i]
--: ({ [number]: number }) -> ({ [number]: number } | nil, string)
M.returns = function(prices)
  if #prices < 2 then return nil, "need at least 2 prices" end
  local rets = {}
  for i = 1, #prices - 1 do
    rets[i] = (prices[i + 1] - prices[i]) / prices[i]
  end
  return rets
end

-- Arithmetic mean of simple returns.
--: ({ [number]: number }) -> (number | nil, string)
M.mean_return = function(prices)
  local rets, err = M.returns(prices)
  if not rets then return nil, err end
  local sum --: number
  sum = 0.0
  for _, r in ipairs(rets) do sum = sum + r end
  return sum / #rets
end

-- Population standard deviation of log returns (volatility).
--: ({ [number]: number }) -> (number | nil, string)
M.volatility = function(prices)
  if #prices < 2 then return nil, "need at least 2 prices" end
  -- log returns
  local lr = {}
  for i = 1, #prices - 1 do
    lr[i] = log(prices[i + 1] / prices[i])
  end
  local n = #lr
  local sum --: number
  sum = 0.0
  for _, r in ipairs(lr) do sum = sum + r end
  local mean = sum / n
  local var --: number
  var = 0.0
  for _, r in ipairs(lr) do var = var + (r - mean) ^ 2 end
  return sqrt(var / n)
end

-- Sharpe ratio: (mean_return - risk_free) / std_dev_of_log_returns.
--: ({ [number]: number }, number) -> (number | nil, string)
M.sharpe = function(prices, risk_free_rate)
  local mean, err = M.mean_return(prices)
  if not mean then return nil, err end
  local vol, err2 = M.volatility(prices)
  if not vol then return nil, err2 end
  if vol == 0 then return nil, "zero volatility" end
  return (mean - risk_free_rate) / vol
end

-- Maximum drawdown: largest peak-to-trough percentage decline.
-- Returns {drawdown, peak_idx, trough_idx}.
-- drawdown is a non-negative number (e.g. 0.2 = 20% decline).
--: ({ [number]: number }) -> ({ drawdown: number, peak_idx: number, trough_idx: number } | nil, string)
M.max_drawdown = function(prices)
  if #prices < 2 then return nil, "need at least 2 prices" end
  local max_dd --: number
  max_dd = 0.0
  local peak_idx = 1
  local trough_idx = 1
  local cur_peak = prices[1]
  local cur_peak_idx = 1

  for i = 2, #prices do
    if prices[i] > cur_peak then
      cur_peak = prices[i]
      cur_peak_idx = i
    else
      local dd = (cur_peak - prices[i]) / cur_peak
      if dd > max_dd then
        max_dd = dd
        peak_idx = cur_peak_idx
        trough_idx = i
      end
    end
  end
  return { drawdown = max_dd, peak_idx = peak_idx, trough_idx = trough_idx }
end

-- Compound Annual Growth Rate.
-- CAGR = (end_value / start_value)^(1/years) - 1
--: (number, number, number) -> (number | nil, string)
M.cagr = function(start_value, end_value, years)
  if start_value <= 0 then return nil, "start_value must be positive" end
  if end_value <= 0 then return nil, "end_value must be positive" end
  if years <= 0 then return nil, "years must be positive" end
  return (end_value / start_value) ^ (1 / years) - 1
end

-- ---------------------------------------------------------------------------
-- 5. Option Pricing (Black-Scholes)
-- ---------------------------------------------------------------------------

-- Normal CDF via Abramowitz & Stegun rational approximation (max error ~1.5e-7).
--: (number) -> number
M.norm_cdf = function(x)
  if x > 10  then return 1.0 end
  if x < -10 then return 0.0 end
  local t = 1 / (1 + 0.2316419 * abs(x))
  local poly = t * (0.319381530
    + t * (-0.356563782
    + t * (1.781477937
    + t * (-1.821255978
    + t * 1.330274429))))
  local pdf = exp(-0.5 * x * x) / sqrt(2 * math.pi)
  local result = 1 - pdf * poly
  if x < 0 then result = 1 - result end
  return result
end

-- Black-Scholes d1 and d2.
--: (number, number, number, number, number) -> (number, number)
local function bs_d1_d2(S, K, T, r, sigma)
  local d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt(T))
  local d2 = d1 - sigma * sqrt(T)
  return d1, d2
end

-- Black-Scholes European call price.
-- S: spot price, K: strike, T: time to expiry (years),
-- r: risk-free rate, sigma: volatility.
--: (number, number, number, number, number) -> (number | nil, string)
M.bs_call = function(S, K, T, r, sigma)
  if T <= 0   then return nil, "T must be positive" end
  if sigma <= 0 then return nil, "sigma must be positive" end
  if S <= 0   then return nil, "S must be positive" end
  if K <= 0   then return nil, "K must be positive" end
  local d1, d2 = bs_d1_d2(S, K, T, r, sigma)
  return S * M.norm_cdf(d1) - K * exp(-r * T) * M.norm_cdf(d2)
end

-- Black-Scholes European put price.
--: (number, number, number, number, number) -> (number | nil, string)
M.bs_put = function(S, K, T, r, sigma)
  if T <= 0   then return nil, "T must be positive" end
  if sigma <= 0 then return nil, "sigma must be positive" end
  if S <= 0   then return nil, "S must be positive" end
  if K <= 0   then return nil, "K must be positive" end
  local d1, d2 = bs_d1_d2(S, K, T, r, sigma)
  return K * exp(-r * T) * M.norm_cdf(-d2) - S * M.norm_cdf(-d1)
end

-- Delta of a call option: ∂C/∂S = N(d1).
--: (number, number, number, number, number) -> (number | nil, string)
M.bs_delta_call = function(S, K, T, r, sigma)
  if T <= 0   then return nil, "T must be positive" end
  if sigma <= 0 then return nil, "sigma must be positive" end
  if S <= 0   then return nil, "S must be positive" end
  if K <= 0   then return nil, "K must be positive" end
  local d1 = bs_d1_d2(S, K, T, r, sigma)
  return M.norm_cdf(d1)
end

-- Delta of a put option: ∂P/∂S = N(d1) - 1.
--: (number, number, number, number, number) -> (number | nil, string)
M.bs_delta_put = function(S, K, T, r, sigma)
  if T <= 0   then return nil, "T must be positive" end
  if sigma <= 0 then return nil, "sigma must be positive" end
  if S <= 0   then return nil, "S must be positive" end
  if K <= 0   then return nil, "K must be positive" end
  local d1 = bs_d1_d2(S, K, T, r, sigma)
  return M.norm_cdf(d1) - 1
end

return M
