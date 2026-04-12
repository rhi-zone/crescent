-- lib/benford/init.lua
-- Benford's Law analysis for fraud detection and data quality checks.
--
-- Benford's Law: in many naturally occurring datasets, the leading digit d
-- appears with probability log10(1 + 1/d).
--
-- Public API:
--   M.expected(digit)           -> number  probability for leading digit 1-9
--   M.expected_all()            -> table   {[1]=p1,...,[9]=p9}
--   M.analyze(numbers)          -> result | (nil, errmsg)
--   M.analyze_second(numbers)   -> result | (nil, errmsg)
--   M.analyze_two_digits(numbers) -> result | (nil, errmsg)
--   M.z_score(obs_freq, exp_freq, n) -> number
--   M.chi_squared(obs_counts, exp_probs) -> number
--   M.chi_squared_pvalue(chi2, df) -> number
--   M.generate(n, opts)         -> array
--   M.suspicious_digits(result) -> array
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

local log10 = math.log10 or function(x) return math.log(x) / math.log(10) end

-- ── Leading digit extraction ──────────────────────────────────────────────────

local function leading_digit(n)
	n = math.abs(n)
	if n == 0 then return nil end
	while n < 1 do n = n * 10 end
	while n >= 10 do n = n / 10 end
	return math.floor(n)
end

local function leading_two_digits(n)
	n = math.abs(n)
	if n == 0 then return nil end
	while n < 10 do n = n * 10 end
	while n >= 100 do n = n / 10 end
	return math.floor(n)
end

-- ── Expected Benford probabilities ───────────────────────────────────────────

-- P(d) = log10(1 + 1/d) for first digit d in 1..9
function M.expected(digit)
	return log10(1 + 1 / digit)
end

-- Returns {[1]=p1, ..., [9]=p9}
function M.expected_all()
	local t = {}
	for d = 1, 9 do
		t[d] = log10(1 + 1 / d)
	end
	return t
end

-- Second digit d (0-9): sum over k=1..9 of log10(1 + 1/(10k+d))
function M.expected_second(digit)
	local sum = 0
	for k = 1, 9 do
		sum = sum + log10(1 + 1 / (10 * k + digit))
	end
	return sum
end

-- Returns {[0]=p0, ..., [9]=p9}
function M.expected_second_all()
	local t = {}
	for d = 0, 9 do
		t[d] = M.expected_second(d)
	end
	return t
end

-- First two digits (10-99): P(d) = log10(1 + 1/d)
function M.expected_two_digits(d)
	return log10(1 + 1 / d)
end

-- Returns {[10]=p10, ..., [99]=p99}
function M.expected_two_digits_all()
	local t = {}
	for d = 10, 99 do
		t[d] = log10(1 + 1 / d)
	end
	return t
end

-- ── Conformity thresholds (MAD-based) ────────────────────────────────────────

local function conformity_from_mad(mad)
	if mad < 0.006 then
		return "close"
	elseif mad < 0.012 then
		return "acceptable"
	elseif mad < 0.015 then
		return "marginally"
	else
		return "nonconforming"
	end
end

-- ── Statistical tests ─────────────────────────────────────────────────────────

-- Z-score for a single digit
-- obs_freq: observed frequency (proportion), exp_freq: expected frequency, n: sample size
function M.z_score(obs_freq, exp_freq, n)
	local denom = math.sqrt(exp_freq * (1 - exp_freq) / n)
	if denom == 0 then return 0 end
	return (obs_freq - exp_freq) / denom
end

-- Chi-squared goodness of fit
-- obs_counts: {[k]=count}, exp_probs: {[k]=probability}
-- Keys must match between the two tables
function M.chi_squared(obs_counts, exp_probs)
	-- compute total n
	local n = 0
	for _, c in pairs(obs_counts) do
		n = n + c
	end
	local chi2 = 0
	for k, p in pairs(exp_probs) do
		local expected_count = n * p
		local observed_count = obs_counts[k] or 0
		if expected_count > 0 then
			local diff = observed_count - expected_count
			chi2 = chi2 + diff * diff / expected_count
		end
	end
	return chi2
end

-- ── Chi-squared p-value approximation ────────────────────────────────────────
-- Approximates the upper-tail p-value P(X > chi2) for chi-squared distribution
-- with df degrees of freedom.
-- Uses the regularized incomplete gamma function: p = 1 - P(df/2, chi2/2)
-- where P(a,x) = gamma(a,x)/Gamma(a) is the lower regularized incomplete gamma.
-- We compute Q(a,x) = 1 - P(a,x) = upper regularized incomplete gamma.

-- Series expansion for lower regularized incomplete gamma P(a, x):
-- P(a, x) = e^(-x) * x^a / Gamma(a) * sum_{n=0}^inf x^n / (a * (a+1) * ... * (a+n))
local function log_gamma(z)
	-- Lanczos approximation
	local g = 7
	local c = {
		0.99999999999980993,
		676.5203681218851,
		-1259.1392167224028,
		771.32342877765313,
		-176.61502916214059,
		12.507343278686905,
		-0.13857109526572012,
		9.9843695780195716e-6,
		1.5056327351493116e-7,
	}
	if z < 0.5 then
		return math.log(math.pi / math.sin(math.pi * z)) - log_gamma(1 - z)
	end
	z = z - 1
	local x = c[1]
	for i = 2, g + 2 do
		x = x + c[i] / (z + i - 1)
	end
	local t = z + g + 0.5
	return 0.5 * math.log(2 * math.pi) + (z + 0.5) * math.log(t) - t + math.log(x)
end

-- Lower incomplete gamma series: gamma(a, x) / Gamma(a)
local function lower_reg_gamma(a, x)
	if x < 0 then return 0 end
	if x == 0 then return 0 end
	-- Use series expansion when x < a + 1
	if x < a + 1 then
		local ap = a
		local sum = 1 / a
		local delta = sum
		local eps = 1e-12
		for _ = 1, 200 do
			ap = ap + 1
			delta = delta * x / ap
			sum = sum + delta
			if math.abs(delta) < eps * math.abs(sum) then break end
		end
		return sum * math.exp(-x + a * math.log(x) - log_gamma(a))
	else
		-- Use continued fraction for upper incomplete gamma, then 1 - result
		-- Lentz's method for continued fraction
		local eps = 1e-12
		local fpmin = 1e-300
		local b = x + 1 - a
		local c_cf = 1 / fpmin
		local d = 1 / b
		local h = d
		for i = 1, 200 do
			local an = -i * (i - a)
			b = b + 2
			d = an * d + b
			if math.abs(d) < fpmin then d = fpmin end
			c_cf = b + an / c_cf
			if math.abs(c_cf) < fpmin then c_cf = fpmin end
			d = 1 / d
			local del = d * c_cf
			h = h * del
			if math.abs(del - 1) < eps then break end
		end
		local upper = math.exp(-x + a * math.log(x) - log_gamma(a)) * h
		return 1 - upper
	end
end

-- P-value: P(chi2 distribution with df degrees of freedom > chi2_val)
-- = 1 - CDF(chi2_val, df) = Q(df/2, chi2_val/2)
function M.chi_squared_pvalue(chi2_val, df)
	if chi2_val <= 0 then return 1 end
	local a = df / 2
	local x = chi2_val / 2
	-- Q(a,x) = 1 - P(a,x)
	return 1 - lower_reg_gamma(a, x)
end

-- ── Core analysis ─────────────────────────────────────────────────────────────

-- Internal: build result table from observed counts, expected probs, n, digit range
local function build_result(observed, expected_probs, n, keys)
	local frequency = {}
	for _, k in ipairs(keys) do
		frequency[k] = observed[k] / n
	end

	local mad_sum = 0
	for _, k in ipairs(keys) do
		mad_sum = mad_sum + math.abs(frequency[k] - expected_probs[k])
	end
	local mad = mad_sum / #keys

	local z_scores = {}
	for _, k in ipairs(keys) do
		z_scores[k] = M.z_score(frequency[k], expected_probs[k], n)
	end

	local chi2 = M.chi_squared(observed, expected_probs)
	local df = #keys - 1
	local p_value = M.chi_squared_pvalue(chi2, df)

	return {
		observed      = observed,
		frequency     = frequency,
		expected      = expected_probs,
		chi_squared   = chi2,
		chi_squared_p = p_value,
		mad           = mad,
		z_scores      = z_scores,
		conformity    = conformity_from_mad(mad),
		n             = n,
	}
end

-- First-digit analysis
function M.analyze(numbers)
	if type(numbers) ~= "table" then
		return nil, "analyze: expected array of numbers"
	end
	local observed = {}
	for d = 1, 9 do observed[d] = 0 end
	local n = 0
	for _, v in ipairs(numbers) do
		if type(v) == "number" and v ~= 0 then
			local d = leading_digit(v)
			if d and d >= 1 and d <= 9 then
				observed[d] = observed[d] + 1
				n = n + 1
			end
		end
	end
	if n == 0 then
		return nil, "analyze: no valid nonzero numbers in input"
	end
	local exp = M.expected_all()
	local keys = {}
	for d = 1, 9 do keys[d] = d end
	return build_result(observed, exp, n, keys)
end

-- Second-digit analysis
function M.analyze_second(numbers)
	if type(numbers) ~= "table" then
		return nil, "analyze_second: expected array of numbers"
	end
	local observed = {}
	for d = 0, 9 do observed[d] = 0 end
	local n = 0
	for _, v in ipairs(numbers) do
		if type(v) == "number" then
			local av = math.abs(v)
			if av >= 10 then
				-- number has at least two digits; get second digit
				-- normalize to [10,100)
				local tmp = av
				while tmp >= 100 do tmp = tmp / 10 end
				while tmp < 10 do tmp = tmp * 10 end
				local d = math.floor(tmp) % 10
				observed[d] = observed[d] + 1
				n = n + 1
			end
		end
	end
	if n == 0 then
		return nil, "analyze_second: no valid numbers with second digit"
	end
	local exp = M.expected_second_all()
	local keys = {}
	for d = 0, 9 do keys[d + 1] = d end
	return build_result(observed, exp, n, keys)
end

-- First-two-digits analysis (digits 10..99)
function M.analyze_two_digits(numbers)
	if type(numbers) ~= "table" then
		return nil, "analyze_two_digits: expected array of numbers"
	end
	local observed = {}
	for d = 10, 99 do observed[d] = 0 end
	local n = 0
	for _, v in ipairs(numbers) do
		if type(v) == "number" and v ~= 0 then
			local d = leading_two_digits(v)
			if d and d >= 10 and d <= 99 then
				observed[d] = observed[d] + 1
				n = n + 1
			end
		end
	end
	if n == 0 then
		return nil, "analyze_two_digits: no valid nonzero numbers in input"
	end
	local exp = M.expected_two_digits_all()
	local keys = {}
	for d = 10, 99 do keys[d - 9] = d end
	return build_result(observed, exp, n, keys)
end

-- ── Suspicious digits detection ───────────────────────────────────────────────

-- Returns array of {digit=d, z_score=z, direction="over"|"under"}
-- for digits where |z| > 1.96 (significant at 5% level)
function M.suspicious_digits(result)
	local out = {}
	for d, z in pairs(result.z_scores) do
		if math.abs(z) > 1.96 then
			out[#out + 1] = {
				digit     = d,
				z_score   = z,
				direction = z > 0 and "over" or "under",
			}
		end
	end
	-- sort by abs z descending
	table.sort(out, function(a, b)
		return math.abs(a.z_score) > math.abs(b.z_score)
	end)
	return out
end

-- ── Data generation ───────────────────────────────────────────────────────────

-- Generate n numbers approximately following Benford's Law
-- Uses inverse transform: if U ~ Uniform(0,1), then 10^U ~ Benford
-- opts.seed: optional seed for reproducibility
function M.generate(n, opts)
	opts = opts or {}
	local rng
	if opts.seed then
		-- Use a simple LCG for reproducibility
		local state = opts.seed
		rng = function()
			state = (state * 1664525 + 1013904223) % 4294967296
			return state / 4294967296
		end
	else
		rng = math.random
		math.randomseed(os.time())
	end

	local out = {}
	for i = 1, n do
		-- 10^U where U in [0,1) gives numbers in [1,10) following Benford
		-- Scale to make integers more interesting: multiply by 10^k for random k
		local u = rng()
		local k = math.floor(rng() * 5)  -- 0..4 decades
		local base = 10 ^ (u + k)
		out[i] = math.floor(base)
	end
	return out
end

return M
