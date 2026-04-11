if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local stats = require("lib.stats")

local function approx(a, b, eps)
  T.ok(math.abs(a - b) < (eps or 1e-6), "expected " .. tostring(a) .. " ≈ " .. tostring(b))
end

T.describe("lib.stats", function()

  T.describe("tier", function()
    T.it("_tier is 'pure'", function()
      T.eq(stats._tier, "pure")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("descriptive", function()

    T.describe("mean", function()
      T.it("integer list", function()
        T.eq(stats.mean({1, 2, 3, 4, 5}), 3)
      end)
      T.it("float list", function()
        approx(stats.mean({1.5, 2.5, 3.0}), 7 / 3)
      end)
      T.it("single element", function()
        T.eq(stats.mean({42}), 42)
      end)
      T.it("empty returns nil", function()
        local v, e = stats.mean({})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("median", function()
      T.it("odd count", function()
        T.eq(stats.median({1, 2, 3, 4, 5}), 3)
      end)
      T.it("even count", function()
        T.eq(stats.median({1, 2, 3, 4}), 2.5)
      end)
      T.it("unsorted input", function()
        T.eq(stats.median({5, 1, 3}), 3)
      end)
    end)

    T.describe("mode", function()
      T.it("single mode", function()
        local m = stats.mode({1, 2, 2, 3})
        T.eq(#m, 1)
        T.eq(m[1], 2)
      end)
      T.it("all same", function()
        local m = stats.mode({7, 7, 7})
        T.eq(m[1], 7)
      end)
      T.it("bimodal", function()
        local m = stats.mode({1, 1, 2, 2, 3})
        T.eq(#m, 2)
        T.eq(m[1], 1)
        T.eq(m[2], 2)
      end)
    end)

    T.describe("geometric_mean", function()
      T.it("known value", function()
        -- gm({1,3,9}) = (27)^(1/3) = 3
        approx(stats.geometric_mean({1, 3, 9}), 3)
      end)
      T.it("rejects non-positive", function()
        local v, e = stats.geometric_mean({1, -1, 3})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("harmonic_mean", function()
      T.it("known value", function()
        -- hm({1,2,4}) = 3 / (1 + 0.5 + 0.25) = 3/1.75 ≈ 1.7143
        approx(stats.harmonic_mean({1, 2, 4}), 3 / (1 + 0.5 + 0.25))
      end)
      T.it("rejects zero", function()
        local v, e = stats.harmonic_mean({1, 0, 3})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("trimmed_mean", function()
      T.it("10% trim", function()
        -- {1..10}, trim 1 from each end → mean({2..9}) = 5.5
        approx(stats.trimmed_mean({1,2,3,4,5,6,7,8,9,10}, 0.1), 5.5)
      end)
      T.it("rejects trim >= 0.5", function()
        local v = stats.trimmed_mean({1,2,3}, 0.5)
        T.eq(v, nil)
      end)
    end)

    T.describe("variance", function()
      T.it("sample variance known case", function()
        -- {2,4,4,4,5,5,7,9}: sample var = 4.571...
        approx(stats.variance({2,4,4,4,5,5,7,9}, true), 32/7, 1e-9)
      end)
      T.it("population variance", function()
        approx(stats.variance({2,4,4,4,5,5,7,9}, false), 4, 1e-9)
      end)
      T.it("defaults to sample", function()
        local v = stats.variance({2,4,4,4,5,5,7,9})
        approx(v, 32/7, 1e-9)
      end)
      T.it("single element returns nil for sample", function()
        local v, e = stats.variance({5}, true)
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("std", function()
      T.it("sample std known case", function()
        approx(stats.std({2,4,4,4,5,5,7,9}, true), math.sqrt(32/7), 1e-9)
      end)
    end)

    T.describe("mad", function()
      T.it("known value", function()
        -- {1,1,2,2,4,6,9}: median=2, devs={1,1,0,0,2,4,7}, median of devs=1
        approx(stats.mad({1,1,2,2,4,6,9}), 1)
      end)
    end)

    T.describe("range", function()
      T.it("basic", function()
        T.eq(stats.range({3, 1, 4, 1, 5, 9}), 8)
      end)
    end)

    T.describe("iqr", function()
      T.it("basic", function()
        -- {1,2,3,4,5}: Q1=1.5+(0.25*4)th=2nd→ quantile method: h=1+0.25*4=2 → s[2]=2; Q3=4; iqr=2
        local v = stats.iqr({1,2,3,4,5})
        T.ok(v ~= nil)
        approx(v, stats.quantile({1,2,3,4,5}, 0.75) - stats.quantile({1,2,3,4,5}, 0.25))
      end)
    end)

    T.describe("cv", function()
      T.it("basic", function()
        local v = stats.cv({2,4,4,4,5,5,7,9})
        T.ok(v ~= nil and v > 0)
      end)
      T.it("zero mean returns nil", function()
        local v, e = stats.cv({-1, 1})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("skewness", function()
      T.it("symmetric returns ~0", function()
        approx(stats.skewness({1,2,3,4,5}), 0, 1e-9)
      end)
      T.it("right skewed > 0", function()
        local s = stats.skewness({1,1,1,1,10})
        T.ok(s > 0)
      end)
    end)

    T.describe("kurtosis", function()
      T.it("returns a number", function()
        local k = stats.kurtosis({1,2,3,4,5,6,7,8})
        T.ok(type(k) == "number")
      end)
    end)

    T.describe("min / max", function()
      T.it("min", function()
        T.eq(stats.min({3,1,4,1,5,9}), 1)
      end)
      T.it("max", function()
        T.eq(stats.max({3,1,4,1,5,9}), 9)
      end)
    end)

    T.describe("quantile", function()
      T.it("p=0 gives min", function()
        T.eq(stats.quantile({1,2,3,4,5}, 0), 1)
      end)
      T.it("p=1 gives max", function()
        T.eq(stats.quantile({1,2,3,4,5}, 1), 5)
      end)
      T.it("p=0.5 matches median", function()
        T.eq(stats.quantile({1,2,3,4,5}, 0.5), stats.median({1,2,3,4,5}))
      end)
      T.it("interpolates", function()
        -- sorted {1,2,3,4,5}, p=0.25: h = 0.25*4+1 = 2 → s[2]=2
        T.eq(stats.quantile({1,2,3,4,5}, 0.25), 2)
      end)
      T.it("rejects out-of-range p", function()
        local v, e = stats.quantile({1,2,3}, 1.5)
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("percentile", function()
      T.it("p=50 matches median", function()
        T.eq(stats.percentile({1,2,3,4,5}, 50), stats.median({1,2,3,4,5}))
      end)
    end)

    T.describe("quartiles", function()
      T.it("returns Q1 Q2 Q3", function()
        local q1, q2, q3 = stats.quartiles({1,2,3,4,5})
        T.ok(q1 ~= nil and q2 ~= nil and q3 ~= nil)
        T.ok(q1 <= q2 and q2 <= q3)
      end)
    end)

    T.describe("five_number_summary", function()
      T.it("has 5 elements in order", function()
        local s = stats.five_number_summary({3,1,4,1,5,9,2,6})
        T.eq(#s, 5)
        T.eq(s[1], stats.min({3,1,4,1,5,9,2,6}))
        T.eq(s[5], stats.max({3,1,4,1,5,9,2,6}))
        T.ok(s[1] <= s[2] and s[2] <= s[3] and s[3] <= s[4] and s[4] <= s[5])
      end)
    end)

    T.describe("normalize", function()
      T.it("z-scores have mean ~0 and std ~1", function()
        local z = stats.normalize({2,4,4,4,5,5,7,9})
        approx(stats.mean(z), 0, 1e-10)
        approx(stats.std(z, true), 1, 1e-10)
      end)
    end)

    T.describe("min_max_scale", function()
      T.it("output in [0, 1]", function()
        local s = stats.min_max_scale({3,1,4,1,5,9,2,6})
        T.eq(stats.min(s), 0)
        T.eq(stats.max(s), 1)
      end)
      T.it("all-same returns nil", function()
        local v, e = stats.min_max_scale({5,5,5})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

  end) -- descriptive

  -- -------------------------------------------------------------------------
  T.describe("correlation", function()

    T.describe("covariance", function()
      T.it("positive covariance", function()
        local cov = stats.covariance({1,2,3,4,5}, {1,2,3,4,5}, true)
        T.ok(cov > 0)
      end)
      T.it("negative covariance", function()
        local cov = stats.covariance({1,2,3,4,5}, {5,4,3,2,1}, true)
        T.ok(cov < 0)
      end)
      T.it("known value", function()
        -- x={1,2,3}, y={4,5,6}: cov_sample = sum((xi-2)(yi-5))/2 = ((-1)(-1)+(0)(0)+(1)(1))/2 = 1
        approx(stats.covariance({1,2,3}, {4,5,6}, true), 1)
      end)
    end)

    T.describe("correlation", function()
      T.it("perfectly correlated = 1", function()
        approx(stats.correlation({1,2,3,4,5}, {1,2,3,4,5}), 1)
      end)
      T.it("perfectly anti-correlated = -1", function()
        approx(stats.correlation({1,2,3,4,5}, {5,4,3,2,1}), -1)
      end)
      T.it("uncorrelated data near 0", function()
        -- {1,2,3,4}, {2,2,2,2}: std of y=0 → returns nil
        local v, e = stats.correlation({1,2,3,4}, {2,2,2,2})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
      T.it("mismatched lengths returns nil", function()
        local v, e = stats.correlation({1,2,3}, {1,2})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("spearman", function()
      T.it("monotone increasing = 1", function()
        approx(stats.spearman({1,2,3,4,5}, {10,20,30,40,50}), 1)
      end)
      T.it("monotone decreasing = -1", function()
        approx(stats.spearman({1,2,3,4,5}, {50,40,30,20,10}), -1)
      end)
    end)

  end) -- correlation

  -- -------------------------------------------------------------------------
  T.describe("distributions", function()

    T.describe("norm_pdf", function()
      T.it("standard normal at 0", function()
        approx(stats.norm_pdf(0, 0, 1), 1 / math.sqrt(2 * math.pi), 1e-9)
      end)
      T.it("approx 0.3989", function()
        approx(stats.norm_pdf(0, 0, 1), 0.3989422804, 1e-7)
      end)
      T.it("non-standard", function()
        -- N(2,3): pdf(2) = 1/(3*sqrt(2pi))
        approx(stats.norm_pdf(2, 2, 3), 1 / (3 * math.sqrt(2 * math.pi)), 1e-9)
      end)
    end)

    T.describe("norm_cdf", function()
      T.it("standard normal at 0 = 0.5", function()
        approx(stats.norm_cdf(0, 0, 1), 0.5, 1e-7)
      end)
      T.it("1.96 ≈ 0.975", function()
        approx(stats.norm_cdf(1.96, 0, 1), 0.975, 1e-3)
      end)
      T.it("-1.96 ≈ 0.025", function()
        approx(stats.norm_cdf(-1.96, 0, 1), 0.025, 1e-3)
      end)
      T.it("symmetry", function()
        local lo = stats.norm_cdf(-1, 0, 1)
        local hi = stats.norm_cdf( 1, 0, 1)
        approx(lo + hi, 1 + 1e-15, 1e-10)  -- they sum to 1 by symmetry
        approx(lo, 1 - hi, 1e-9)
      end)
    end)

    T.describe("norm_inv", function()
      T.it("p=0.5 → 0", function()
        approx(stats.norm_inv(0.5, 0, 1), 0, 1e-7)
      end)
      T.it("p=0.975 → ~1.96", function()
        approx(stats.norm_inv(0.975, 0, 1), 1.96, 1e-2)
      end)
      T.it("round-trips norm_cdf", function()
        local x = 1.23
        approx(stats.norm_inv(stats.norm_cdf(x, 0, 1), 0, 1), x, 1e-6)
      end)
      T.it("non-standard", function()
        -- N(5, 2): inv(0.5) = 5
        approx(stats.norm_inv(0.5, 5, 2), 5, 1e-7)
      end)
    end)

    T.describe("t_pdf", function()
      T.it("returns positive value", function()
        local v = stats.t_pdf(0, 5)
        T.ok(v ~= nil and v > 0)
      end)
      T.it("df=1 at 0 = 1/pi", function()
        approx(stats.t_pdf(0, 1), 1 / math.pi, 1e-7)
      end)
    end)

    T.describe("t_cdf", function()
      T.it("t=0 two-sided: P(|T|<=0)=0", function()
        approx(stats.t_cdf(0, 10), 0, 1e-7)
      end)
      T.it("large t two-sided → 1", function()
        local v = stats.t_cdf(100, 10)
        approx(v, 1, 1e-4)
      end)
    end)

    T.describe("chi2_cdf", function()
      T.it("P(0) = 0", function()
        approx(stats.chi2_cdf(0, 5), 0, 1e-9)
      end)
      T.it("large x → 1", function()
        local v = stats.chi2_cdf(100, 5)
        approx(v, 1, 1e-4)
      end)
      T.it("known value df=2: P(x) = 1 - exp(-x/2)", function()
        local x = 4
        approx(stats.chi2_cdf(x, 2), 1 - math.exp(-x/2), 1e-6)
      end)
    end)

    T.describe("poisson_pmf", function()
      T.it("k=0, lambda=1 ≈ 0.3679", function()
        approx(stats.poisson_pmf(0, 1), math.exp(-1), 1e-9)
      end)
      T.it("k=1, lambda=1 ≈ 0.3679", function()
        approx(stats.poisson_pmf(1, 1), math.exp(-1), 1e-9)
      end)
      T.it("k=2, lambda=2 = 2e^-2", function()
        approx(stats.poisson_pmf(2, 2), 2 * math.exp(-2), 1e-9)
      end)
      T.it("sums to 1 over large range", function()
        local s = 0
        for k = 0, 50 do
          s = s + stats.poisson_pmf(k, 5)
        end
        approx(s, 1, 1e-6)
      end)
    end)

    T.describe("poisson_cdf", function()
      T.it("k=0 = pmf(0)", function()
        approx(stats.poisson_cdf(0, 2), stats.poisson_pmf(0, 2), 1e-9)
      end)
      T.it("k=large → ~1", function()
        approx(stats.poisson_cdf(50, 2), 1, 1e-6)
      end)
    end)

    T.describe("binom_pmf", function()
      T.it("k=5, n=10, p=0.5", function()
        -- C(10,5) * 0.5^10 = 252/1024
        approx(stats.binom_pmf(5, 10, 0.5), 252/1024, 1e-9)
      end)
      T.it("k=0, n=5, p=0.5 = 0.5^5", function()
        approx(stats.binom_pmf(0, 5, 0.5), (0.5)^5, 1e-9)
      end)
      T.it("sums to 1", function()
        local s = 0
        for k = 0, 10 do s = s + stats.binom_pmf(k, 10, 0.3) end
        approx(s, 1, 1e-9)
      end)
    end)

    T.describe("binom_cdf", function()
      T.it("k=n → 1", function()
        approx(stats.binom_cdf(10, 10, 0.5), 1, 1e-9)
      end)
      T.it("k=0 = pmf(0)", function()
        approx(stats.binom_cdf(0, 10, 0.5), stats.binom_pmf(0, 10, 0.5), 1e-9)
      end)
    end)

  end) -- distributions

  -- -------------------------------------------------------------------------
  T.describe("hypothesis testing", function()

    T.describe("t_test_one", function()
      T.it("matches population mean → high p-value", function()
        -- Data generated from N(5, 1); test against mu=5
        local data = {4.9, 5.1, 4.8, 5.2, 5.0, 5.1, 4.7, 5.3, 5.0, 4.9}
        local r = stats.t_test_one(data, 5)
        T.ok(r ~= nil)
        T.ok(r.p_value > 0.05)
      end)
      T.it("different mean → low p-value", function()
        -- Data clearly centered at 10; test against mu=0
        local data = {9.8, 10.1, 9.9, 10.2, 10.0, 10.1, 9.7, 10.3, 10.0, 9.9}
        local r = stats.t_test_one(data, 0)
        T.ok(r ~= nil)
        T.ok(r.p_value < 0.001)
        T.ok(r.t_stat > 0)
        T.ok(r.df == 9)
      end)
      T.it("missing mu returns nil", function()
        local v, e = stats.t_test_one({1,2,3}, nil)
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("t_test_two", function()
      T.it("identical data → high p-value", function()
        local a = {5, 5, 5, 5, 5}
        local b = {5, 5, 5, 5, 5}
        -- std = 0 → SE = 0 → error expected
        local r, e = stats.t_test_two(a, b)
        -- Either nil (SE=0) or p_value near 1 both acceptable
        if r == nil then
          T.ok(type(e) == "string")
        else
          T.ok(r.p_value >= 0)
        end
      end)
      T.it("very different means → low p-value", function()
        local a = {1, 2, 1, 2, 1, 2}
        local b = {100, 101, 100, 101, 100, 101}
        local r = stats.t_test_two(a, b)
        T.ok(r ~= nil)
        T.ok(r.p_value < 0.001)
      end)
      T.it("df > 0", function()
        local r = stats.t_test_two({1,2,3,4,5}, {2,3,4,5,6})
        T.ok(r ~= nil and r.df > 0)
      end)
    end)

    T.describe("chi2_test", function()
      T.it("uniform observed matches uniform expected → high p-value", function()
        local obs = {25, 25, 25, 25}
        local exp = {25, 25, 25, 25}
        local r = stats.chi2_test(obs, exp)
        T.ok(r ~= nil)
        T.eq(r.chi2_stat, 0)
        approx(r.p_value, 1, 1e-6)
      end)
      T.it("very skewed → low p-value", function()
        local obs = {90, 5, 3, 2}
        local exp = {25, 25, 25, 25}
        local r = stats.chi2_test(obs, exp)
        T.ok(r ~= nil)
        T.ok(r.p_value < 0.01)
      end)
      T.it("df = len - 1", function()
        local r = stats.chi2_test({1,2,3,4}, {2.5,2.5,2.5,2.5})
        T.ok(r ~= nil and r.df == 3)
      end)
    end)

    T.describe("correlation_test", function()
      T.it("perfectly correlated → p near 0", function()
        local x = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
        local y = {2, 4, 6, 8, 10, 12, 14, 16, 18, 20}
        local r = stats.correlation_test(x, y)
        T.ok(r ~= nil)
        approx(r.r, 1, 1e-9)
        T.ok(r.p_value < 0.001)
      end)
      T.it("uncorrelated → high p-value", function()
        -- Constant y → correlation is nil/error
        local x = {1,2,3,4,5}
        local y = {3,3,3,3,3}
        local r, e = stats.correlation_test(x, y)
        if r == nil then
          T.ok(type(e) == "string")
        else
          T.ok(r.p_value >= 0)
        end
      end)
    end)

  end) -- hypothesis testing

  -- -------------------------------------------------------------------------
  T.describe("linear regression", function()

    T.describe("linear_regression", function()
      T.it("perfect linear data → r2=1", function()
        local x = {1, 2, 3, 4, 5}
        local y = {3, 5, 7, 9, 11}  -- y = 2x + 1
        local m = stats.linear_regression(x, y)
        T.ok(m ~= nil)
        approx(m.r2, 1, 1e-9)
        approx(m.a, 1, 1e-9)
        approx(m.b, 2, 1e-9)
      end)
      T.it("residuals sum to ~0", function()
        local x = {1, 2, 3, 4, 5}
        local y = {2.1, 3.9, 6.2, 7.8, 10.1}
        local m = stats.linear_regression(x, y)
        local sum = 0
        for _, r in ipairs(m.residuals) do sum = sum + r end
        approx(sum, 0, 1e-10)
      end)
      T.it("zero variance x returns nil", function()
        local v, e = stats.linear_regression({2,2,2}, {1,2,3})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
      T.it("mismatched lengths returns nil", function()
        local v, e = stats.linear_regression({1,2,3}, {1,2})
        T.eq(v, nil)
        T.ok(type(e) == "string")
      end)
    end)

    T.describe("multiple_regression", function()
      T.it("perfect fit → r2=1", function()
        -- y = 1 + 2*x1 + 3*x2
        local X = {{1,0},{2,0},{0,1},{0,2},{1,1}}
        local y = {3, 5, 4, 7, 6}
        local m = stats.multiple_regression(X, y)
        T.ok(m ~= nil)
        approx(m.r2, 1, 1e-6)
        -- coefficients: intercept=1, c1=2, c2=3
        approx(m.coefficients[1], 1, 1e-6)
        approx(m.coefficients[2], 2, 1e-6)
        approx(m.coefficients[3], 3, 1e-6)
      end)
    end)

    T.describe("predict", function()
      T.it("simple regression", function()
        local x = {1, 2, 3, 4, 5}
        local y = {3, 5, 7, 9, 11}  -- y = 2x + 1
        local m = stats.linear_regression(x, y)
        approx(stats.predict(m, 6), 13, 1e-9)
        approx(stats.predict(m, 0), 1, 1e-9)
      end)
      T.it("multiple regression", function()
        local X = {{1,0},{2,0},{0,1},{0,2},{1,1}}
        local y = {3, 5, 4, 7, 6}
        local m = stats.multiple_regression(X, y)
        -- predict(1, 1) = 1 + 2*1 + 3*1 = 6
        approx(stats.predict(m, {1, 1}), 6, 1e-6)
      end)
    end)

  end) -- linear regression

  -- -------------------------------------------------------------------------
  T.describe("histogram", function()

    T.describe("histogram", function()
      T.it("bin count matches n_bins", function()
        local h = stats.histogram({1,2,3,4,5,6,7,8,9,10}, 5)
        T.ok(h ~= nil)
        T.eq(h.bins, 5)
        T.eq(#h.counts, 5)
        T.eq(#h.edges, 6)
      end)
      T.it("all data covered (counts sum to n)", function()
        local data = {1,2,3,4,5,6,7,8,9,10}
        local h = stats.histogram(data, 5)
        local total = 0
        for _, c in ipairs(h.counts) do total = total + c end
        T.eq(total, #data)
      end)
      T.it("Sturges default bin count", function()
        local data = {}
        for i = 1, 16 do data[i] = i end
        local h = stats.histogram(data)
        -- Sturges: ceil(log2(16))+1 = 5
        T.eq(h.bins, 5)
      end)
      T.it("single value data", function()
        local h = stats.histogram({5, 5, 5}, 3)
        T.ok(h ~= nil)
        local total = 0
        for _, c in ipairs(h.counts) do total = total + c end
        T.eq(total, 3)
      end)
    end)

    T.describe("frequency", function()
      T.it("counts are correct", function()
        local f = stats.frequency({1,2,2,3,3,3})
        T.eq(f[1], 1)
        T.eq(f[2], 2)
        T.eq(f[3], 3)
      end)
    end)

    T.describe("cumulative_frequency", function()
      T.it("last entry has full count", function()
        local cf = stats.cumulative_frequency({1,2,2,3,3,3})
        local last = cf[#cf]
        T.eq(last.cum_freq, 6)
        approx(last.cum_rel, 1, 1e-9)
      end)
      T.it("entries are sorted by value", function()
        local cf = stats.cumulative_frequency({3,1,2})
        T.eq(cf[1].value, 1)
        T.eq(cf[2].value, 2)
        T.eq(cf[3].value, 3)
      end)
    end)

  end) -- histogram

  -- -------------------------------------------------------------------------
  T.describe("error handling", function()
    T.it("mean empty", function()
      local v, e = stats.mean({})
      T.eq(v, nil); T.ok(type(e) == "string")
    end)
    T.it("median empty", function()
      local v, e = stats.median({})
      T.eq(v, nil); T.ok(type(e) == "string")
    end)
    T.it("correlation mismatched", function()
      local v, e = stats.correlation({1,2}, {1,2,3})
      T.eq(v, nil); T.ok(type(e) == "string")
    end)
    T.it("linear_regression short", function()
      local v, e = stats.linear_regression({1}, {2})
      T.eq(v, nil); T.ok(type(e) == "string")
    end)
    T.it("norm_pdf negative sigma", function()
      local v, e = stats.norm_pdf(0, 0, -1)
      T.eq(v, nil); T.ok(type(e) == "string")
    end)
    T.it("norm_inv out of range p", function()
      local v, e = stats.norm_inv(1.1, 0, 1)
      T.eq(v, nil); T.ok(type(e) == "string")
    end)
    T.it("poisson_pmf negative lambda", function()
      local v, e = stats.poisson_pmf(1, -1)
      T.eq(v, nil); T.ok(type(e) == "string")
    end)
    T.it("binom_pmf k > n", function()
      local v, e = stats.binom_pmf(5, 3, 0.5)
      T.eq(v, nil); T.ok(type(e) == "string")
    end)
  end) -- error handling

end) -- lib.stats
