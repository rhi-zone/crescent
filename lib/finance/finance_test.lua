if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local finance = require("lib.finance")

local function approx(a, b, eps)
  T.ok(math.abs(a - b) < (eps or 0.01),
    "expected " .. tostring(a) .. " ≈ " .. tostring(b) .. " (eps=" .. tostring(eps or 0.01) .. ")")
end

-- ---------------------------------------------------------------------------

T.describe("lib.finance", function()

  -- -------------------------------------------------------------------------
  T.describe("tier", function()
    T.it("_tier is 'pure'", function()
      T.eq(finance._tier, "pure")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("round", function()
    T.it("rounds to given decimals", function()
      approx(finance.round(3.14159, 2), 3.14, 1e-9)
      approx(finance.round(2.675, 2), 2.68, 1e-9)   -- half-even: 7 is odd → round up
      approx(finance.round(2.665, 2), 2.66, 1e-9)   -- half-even: 6 is even → stays
      approx(finance.round(1.5, 0),   2,    1e-9)   -- 1 is odd → round up
      approx(finance.round(2.5, 0),   2,    1e-9)   -- 2 is even → stays
      approx(finance.round(3.5, 0),   4,    1e-9)   -- 3 is odd → round up
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("pv/fv", function()
    T.it("pv: present value of $1000 in 10 years at 5%", function()
      approx(finance.pv(1000, 0.05, 10), 613.91, 0.01)
    end)

    T.it("fv: future value of $1000 in 10 years at 5%", function()
      approx(finance.fv(1000, 0.05, 10), 1628.89, 0.01)
    end)

    T.it("round-trip: pv(fv(x,r,n), r, n) == x", function()
      local x, r, n = 500, 0.07, 8
      local fv = finance.fv(x, r, n)
      approx(finance.pv(fv, r, n), x, 1e-9)
    end)

    T.it("pv returns nil for negative periods", function()
      local v, err = finance.pv(1000, 0.05, -1)
      T.eq(v, nil)
      T.ok(err ~= nil)
    end)

    T.it("pv/fv at rate=0", function()
      approx(finance.pv(1000, 0, 5), 1000, 1e-9)
      approx(finance.fv(1000, 0, 5), 1000, 1e-9)
    end)

    T.it("pv/fv at period=0", function()
      approx(finance.pv(1000, 0.05, 0), 1000, 1e-9)
      approx(finance.fv(1000, 0.05, 0), 1000, 1e-9)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("npv/irr", function()
    T.it("npv: known vector rate=10%", function()
      -- NPV = -1000 + 300/1.1 + 400/1.1^2 + 500/1.1^3 ≈ -21.03
      local npv = finance.npv(0.1, {-1000, 300, 400, 500})
      approx(npv, -21.03, 0.01)
    end)

    T.it("npv at rate=0 equals sum of cash flows", function()
      local cfs = {-1000, 300, 400, 500}
      local sum = 0
      for _, v in ipairs(cfs) do sum = sum + v end
      approx(finance.npv(0, cfs), sum, 1e-9)
    end)

    T.it("irr: convergence on known cash flows", function()
      -- cash_flows = {-1000, 200, 300, 400, 300} → IRR ≈ 9.26%
      local irr = finance.irr({-1000, 200, 300, 400, 300})
      T.ok(irr ~= nil, "irr should converge")
      -- verify: npv at irr ≈ 0
      approx(finance.npv(irr, {-1000, 200, 300, 400, 300}), 0, 1e-6)
    end)

    T.it("irr: npv=0 cash flow recovers exact rate", function()
      -- Build a cash flow for which we know IRR = 20%
      -- CF = {-1000, 1200}: NPV(20%) = -1000 + 1200/1.2 = 0
      local irr = finance.irr({-1000, 1200})
      T.ok(irr ~= nil)
      approx(irr, 0.2, 1e-6)
    end)

    T.it("irr: respects initial_guess parameter", function()
      local irr = finance.irr({-1000, 200, 300, 400, 300}, 0.05)
      T.ok(irr ~= nil)
      approx(finance.npv(irr, {-1000, 200, 300, 400, 300}), 0, 1e-6)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("pmt", function()
    T.it("loan payment: $10k, 5% annual (0.4167% monthly), 60 months ≈ $188.71", function()
      local rate = 0.05 / 12
      local pmt = finance.pmt(10000, rate, 60)
      approx(pmt, 188.71, 0.01)
    end)

    T.it("pmt with rate=0 = pv/n", function()
      approx(finance.pmt(1200, 0, 12), 100, 1e-9)
    end)

    T.it("pmt returns nil for n<=0", function()
      local v, err = finance.pmt(1000, 0.05, 0)
      T.eq(v, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("pv_annuity / fv_annuity", function()
    T.it("pv_annuity ordinary: $100/period, 5%, 10 periods", function()
      -- PV = 100 * (1 - 1.05^-10) / 0.05 ≈ 772.17
      approx(finance.pv_annuity(100, 0.05, 10, 0), 772.17, 0.01)
    end)

    T.it("pv_annuity due > ordinary", function()
      local pv_ord = finance.pv_annuity(100, 0.05, 10, 0)
      local pv_due = finance.pv_annuity(100, 0.05, 10, 1)
      T.ok(pv_due > pv_ord)
    end)

    T.it("fv_annuity ordinary: $100/period, 5%, 10 periods", function()
      -- FV = 100 * ((1.05^10 - 1) / 0.05) ≈ 1257.79
      approx(finance.fv_annuity(100, 0.05, 10, 0), 1257.79, 0.01)
    end)

    T.it("pv_annuity rate=0 = pmt*n", function()
      approx(finance.pv_annuity(100, 0, 10, 0), 1000, 1e-9)
    end)

    T.it("fv_annuity rate=0 = pmt*n", function()
      approx(finance.fv_annuity(100, 0, 10, 0), 1000, 1e-9)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("nper", function()
    T.it("nper recovers periods used in pmt", function()
      -- $10k loan at 5% annual / 12, 60 months
      -- pmt is positive (received), so nper uses pv positive, pmt negative (outflow)
      local rate = 0.05 / 12
      local pmt  = finance.pmt(10000, rate, 60)
      -- sign convention: pv=+10000 (loan received), pmt=-pmt (payments out), fv=0
      local n = finance.nper(10000, rate, -pmt, 0)
      approx(n, 60, 0.001)
    end)

    T.it("nper with rate=0", function()
      -- borrowed 100, pay 10/period, target balance=0
      -- nper(100, 0, -10, 0) = (0-100)/(-10) = 10 periods
      local n = finance.nper(100, 0, -10, 0)
      approx(n, 10, 1e-9)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("compound interest", function()
    T.it("ear: 12% nominal monthly compounding", function()
      -- EAR = (1 + 0.12/12)^12 - 1 ≈ 12.68%
      approx(finance.ear(0.12, 12), 0.1268, 0.0001)
    end)

    T.it("ear returns nil for n<=0", function()
      local v, err = finance.ear(0.12, 0)
      T.eq(v, nil)
      T.ok(err ~= nil)
    end)

    T.it("apr_to_apy == ear", function()
      approx(finance.apr_to_apy(0.12, 12), finance.ear(0.12, 12), 1e-12)
    end)

    T.it("apy_to_apr round-trip", function()
      local apr = 0.12
      local apy = finance.apr_to_apy(apr, 12)
      approx(finance.apy_to_apr(apy, 12), apr, 1e-9)
    end)

    T.it("continuous_fv: PV * e^(rt)", function()
      -- FV = 1000 * e^(0.05 * 2) ≈ 1105.17
      approx(finance.continuous_fv(1000, 0.05, 2), 1105.17, 0.01)
    end)

    T.it("continuous_pv: FV * e^(-rt)", function()
      approx(finance.continuous_pv(1105.17, 0.05, 2), 1000, 0.01)
    end)

    T.it("continuous round-trip", function()
      local pv = 750
      local r, t = 0.07, 5
      approx(finance.continuous_pv(finance.continuous_fv(pv, r, t), r, t), pv, 1e-9)
    end)

    T.it("continuous_fv > discrete_fv for same rate and time", function()
      -- Continuous compounding always yields more than discrete
      local discrete = finance.fv(1000, 0.10, 1)
      local cont = finance.continuous_fv(1000, 0.10, 1)
      T.ok(cont > discrete)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("amortize", function()
    T.it("schedule has correct length", function()
      local sched = finance.amortize(10000, 0.05 / 12, 60)
      T.eq(#sched, 60)
    end)

    T.it("first period interest = principal * rate", function()
      local rate = 0.05 / 12
      local sched = finance.amortize(10000, rate, 60)
      approx(sched[1].interest, 10000 * rate, 1e-9)
    end)

    T.it("final balance is 0", function()
      local sched = finance.amortize(10000, 0.05 / 12, 60)
      approx(sched[60].balance, 0, 1e-9)
    end)

    T.it("sum of principal payments = original principal", function()
      local sched = finance.amortize(10000, 0.05 / 12, 60)
      local total_princ = 0
      for _, row in ipairs(sched) do total_princ = total_princ + row.principal end
      approx(total_princ, 10000, 0.001)
    end)

    T.it("sum of payments = total_interest + principal", function()
      local principal = 10000
      local rate = 0.05 / 12
      local periods = 60
      local sched = finance.amortize(principal, rate, periods)
      local total_pmt = 0
      for _, row in ipairs(sched) do total_pmt = total_pmt + row.payment end
      local ti = finance.total_interest(principal, rate, periods)
      approx(total_pmt, ti + principal, 0.01)
    end)

    T.it("total_interest is positive for non-zero rate", function()
      local ti = finance.total_interest(10000, 0.05 / 12, 60)
      T.ok(ti > 0)
    end)

    T.it("amortize returns nil for invalid principal", function()
      local v, err = finance.amortize(-1000, 0.05, 12)
      T.eq(v, nil)
      T.ok(err ~= nil)
    end)

    T.it("amortize with rate=0 spreads evenly", function()
      local sched = finance.amortize(1200, 0, 12)
      for _, row in ipairs(sched) do
        approx(row.interest, 0, 1e-9)
        approx(row.principal, 100, 1e-9)
      end
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("returns / volatility", function()
    T.it("flat prices yield zero returns", function()
      local rets = finance.returns({100, 100, 100, 100})
      for _, r in ipairs(rets) do approx(r, 0, 1e-9) end
    end)

    T.it("growing prices yield positive mean return", function()
      local mr = finance.mean_return({100, 105, 110, 115, 120})
      T.ok(mr > 0)
    end)

    T.it("flat prices yield zero volatility", function()
      -- log(1) = 0 for all periods
      local vol = finance.volatility({100, 100, 100, 100})
      approx(vol, 0, 1e-9)
    end)

    T.it("returns returns nil for single price", function()
      local v, err = finance.returns({100})
      T.eq(v, nil)
      T.ok(err ~= nil)
    end)

    T.it("volatility returns nil for single price", function()
      local v, err = finance.volatility({100})
      T.eq(v, nil)
      T.ok(err ~= nil)
    end)

    T.it("volatility is positive for non-constant prices", function()
      local vol = finance.volatility({100, 110, 105, 115, 108})
      T.ok(vol > 0)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("sharpe", function()
    T.it("sharpe is positive when returns exceed risk-free", function()
      local prices = {100, 105, 110, 115, 120}
      local sr = finance.sharpe(prices, 0)
      T.ok(sr > 0)
    end)

    T.it("sharpe returns nil for zero volatility", function()
      local v, err = finance.sharpe({100, 100, 100, 100}, 0)
      T.eq(v, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("cagr", function()
    T.it("doubling in 1 year = 100% CAGR", function()
      approx(finance.cagr(100, 200, 1), 1.0, 1e-9)
    end)

    T.it("quadrupling in 2 years = 100% CAGR", function()
      approx(finance.cagr(100, 400, 2), 1.0, 1e-9)
    end)

    T.it("no growth over 10 years = 0% CAGR", function()
      approx(finance.cagr(100, 100, 10), 0.0, 1e-9)
    end)

    T.it("cagr returns nil for non-positive inputs", function()
      local v1, _ = finance.cagr(0, 100, 1)
      T.eq(v1, nil)
      local v2, _ = finance.cagr(100, 0, 1)
      T.eq(v2, nil)
      local v3, _ = finance.cagr(100, 200, 0)
      T.eq(v3, nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("max_drawdown", function()
    T.it("monotone increasing → 0 drawdown", function()
      local dd = finance.max_drawdown({100, 110, 120, 130, 140})
      approx(dd.drawdown, 0, 1e-9)
    end)

    T.it("known peak-to-trough", function()
      -- peak at index 3 (value 150), trough at index 5 (value 90)
      -- drawdown = (150-90)/150 = 0.4
      local prices = {100, 120, 150, 130, 90, 110}
      local dd = finance.max_drawdown(prices)
      approx(dd.drawdown, 0.4, 1e-6)
      T.eq(dd.peak_idx, 3)
      T.eq(dd.trough_idx, 5)
    end)

    T.it("max_drawdown returns nil for single price", function()
      local v, err = finance.max_drawdown({100})
      T.eq(v, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("norm_cdf", function()
    T.it("norm_cdf(0) = 0.5", function()
      approx(finance.norm_cdf(0), 0.5, 1e-6)
    end)

    T.it("norm_cdf(large) ≈ 1", function()
      approx(finance.norm_cdf(10), 1.0, 1e-6)
    end)

    T.it("norm_cdf(-large) ≈ 0", function()
      approx(finance.norm_cdf(-10), 0.0, 1e-6)
    end)

    T.it("norm_cdf is symmetric: cdf(x) + cdf(-x) = 1", function()
      for _, x in ipairs({0.5, 1.0, 1.5, 2.0}) do
        approx(finance.norm_cdf(x) + finance.norm_cdf(-x), 1.0, 1e-6)
      end
    end)

    T.it("norm_cdf(1.96) ≈ 0.975 (95% CI)", function()
      approx(finance.norm_cdf(1.96), 0.975, 0.001)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("black-scholes", function()
    -- Reference: S=100, K=100, T=1, r=0.05, sigma=0.2
    local S, K, T_exp, r, sigma = 100, 100, 1, 0.05, 0.2

    T.it("call price ≈ 10.45", function()
      local call = finance.bs_call(S, K, T_exp, r, sigma)
      approx(call, 10.45, 0.01)
    end)

    T.it("put price ≈ 5.57", function()
      local put = finance.bs_put(S, K, T_exp, r, sigma)
      approx(put, 5.57, 0.01)
    end)

    T.it("put-call parity: C - P = S - K*e^(-rT)", function()
      local call = finance.bs_call(S, K, T_exp, r, sigma)
      local put  = finance.bs_put(S, K, T_exp, r, sigma)
      local rhs  = S - K * math.exp(-r * T_exp)
      approx(call - put, rhs, 1e-6)
    end)

    T.it("ATM call > ATM put when r > 0", function()
      local call = finance.bs_call(S, S, T_exp, r, sigma)
      local put  = finance.bs_put(S, S, T_exp, r, sigma)
      T.ok(call > put)
    end)

    T.it("call delta is in (0, 1)", function()
      local d = finance.bs_delta_call(S, K, T_exp, r, sigma)
      T.ok(d > 0 and d < 1)
    end)

    T.it("put delta is in (-1, 0)", function()
      local d = finance.bs_delta_put(S, K, T_exp, r, sigma)
      T.ok(d > -1 and d < 0)
    end)

    T.it("call delta + |put delta| = 1", function()
      local dc = finance.bs_delta_call(S, K, T_exp, r, sigma)
      local dp = finance.bs_delta_put(S, K, T_exp, r, sigma)
      approx(dc + (-dp), 1.0, 1e-9)
    end)

    T.it("deep ITM call price approaches S - K*e^(-rT)", function()
      -- S >> K
      local call = finance.bs_call(200, 100, T_exp, r, sigma)
      local intrinsic = 200 - 100 * math.exp(-r * T_exp)
      approx(call, intrinsic, 0.5)
    end)

    T.it("OTM call < ATM call", function()
      local atm = finance.bs_call(100, 100, T_exp, r, sigma)
      local otm = finance.bs_call(100, 120, T_exp, r, sigma)
      T.ok(otm < atm)
    end)

    T.it("bs_call returns nil for invalid inputs", function()
      local v1, _ = finance.bs_call(0, 100, 1, 0.05, 0.2)
      T.eq(v1, nil)
      local v2, _ = finance.bs_call(100, 100, 0, 0.05, 0.2)
      T.eq(v2, nil)
      local v3, _ = finance.bs_call(100, 100, 1, 0.05, 0)
      T.eq(v3, nil)
    end)
  end)

end)
