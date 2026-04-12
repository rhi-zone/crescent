if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local NT = require("lib.number_theory")

-- ---------------------------------------------------------------------------
-- Tier
-- ---------------------------------------------------------------------------
T.describe("_tier", function()
  T.it("is pure", function()
    T.eq(NT._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
-- is_prime / is_prime_trial
-- ---------------------------------------------------------------------------
T.describe("is_prime", function()
  T.it("identifies small primes", function()
    T.ok(NT.is_prime(2))
    T.ok(NT.is_prime(3))
    T.ok(NT.is_prime(5))
    T.ok(NT.is_prime(7))
    T.ok(NT.is_prime(11))
    T.ok(NT.is_prime(13))
    T.ok(NT.is_prime(97))
  end)
  T.it("rejects composites and edge cases", function()
    T.ok(not NT.is_prime(0))
    T.ok(not NT.is_prime(1))
    T.ok(not NT.is_prime(4))
    T.ok(not NT.is_prime(9))
    T.ok(not NT.is_prime(100))
    -- 561 = 3×11×17 is the smallest Carmichael number
    T.ok(not NT.is_prime(561))
    T.ok(not NT.is_prime(1105))
  end)
  T.it("handles larger primes", function()
    T.ok(NT.is_prime(7919))
    T.ok(NT.is_prime(104729))
    T.ok(not NT.is_prime(104730))
  end)
end)

T.describe("is_prime_trial", function()
  T.it("agrees with is_prime on small values", function()
    for _, n in ipairs({2, 3, 5, 7, 11, 13, 97, 1, 4, 9, 15, 100}) do
      T.eq(NT.is_prime_trial(n), NT.is_prime(n))
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- miller_rabin
-- ---------------------------------------------------------------------------
T.describe("miller_rabin", function()
  T.it("returns true for primes with known witnesses", function()
    T.ok(NT.miller_rabin(7, {2, 3}))
    T.ok(NT.miller_rabin(97, {2, 3, 5, 7}))
  end)
  T.it("returns false for composites", function()
    T.ok(not NT.miller_rabin(9, {2, 3, 5, 7}))
    T.ok(not NT.miller_rabin(100, {2, 3, 5, 7}))
    T.ok(not NT.miller_rabin(561, {2, 3, 5, 7}))
  end)
end)

-- ---------------------------------------------------------------------------
-- next_prime / prev_prime
-- ---------------------------------------------------------------------------
T.describe("next_prime", function()
  T.it("finds next prime after n", function()
    T.eq(NT.next_prime(1), 2)
    T.eq(NT.next_prime(2), 3)
    T.eq(NT.next_prime(3), 5)
    T.eq(NT.next_prime(10), 11)
    T.eq(NT.next_prime(14), 17)
    T.eq(NT.next_prime(97), 101)
  end)
end)

T.describe("prev_prime", function()
  T.it("finds largest prime less than n", function()
    T.eq(NT.prev_prime(3), 2)
    T.eq(NT.prev_prime(4), 3)
    T.eq(NT.prev_prime(10), 7)
    T.eq(NT.prev_prime(14), 13)
    T.eq(NT.prev_prime(100), 97)
  end)
  T.it("returns nil for n <= 2", function()
    T.eq(NT.prev_prime(2), nil)
    T.eq(NT.prev_prime(1), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- factorize
-- ---------------------------------------------------------------------------
T.describe("factorize", function()
  T.it("factorizes 12 = 2^2 * 3", function()
    local f = NT.factorize(12)
    T.eq(f[2], 2)
    T.eq(f[3], 1)
    T.eq(f[5], nil)
  end)
  T.it("factorizes 360 = 2^3 * 3^2 * 5", function()
    local f = NT.factorize(360)
    T.eq(f[2], 3)
    T.eq(f[3], 2)
    T.eq(f[5], 1)
  end)
  T.it("factorizes a prime", function()
    local f = NT.factorize(97)
    T.eq(f[97], 1)
    T.eq(next(f, next(f)), nil)  -- only one entry
  end)
  T.it("factorizes 1 as empty", function()
    local f = NT.factorize(1)
    T.eq(next(f), nil)
  end)
  T.it("factorizes a semiprime (large-ish)", function()
    -- 9797 = 97 * 101
    local f = NT.factorize(9797)
    T.eq(f[97], 1)
    T.eq(f[101], 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- factors
-- ---------------------------------------------------------------------------
T.describe("factors", function()
  T.it("returns sorted factors with repetition", function()
    local f = NT.factors(12)
    T.eq(f[1], 2)
    T.eq(f[2], 2)
    T.eq(f[3], 3)
    T.eq(#f, 3)
  end)
  T.it("single prime", function()
    local f = NT.factors(7)
    T.eq(f[1], 7)
    T.eq(#f, 1)
  end)
  T.it("360 = 2^3 * 3^2 * 5", function()
    local f = NT.factors(360)
    T.eq(#f, 6)  -- 3+2+1
    T.eq(f[1], 2)
    T.eq(f[4], 3)
    T.eq(f[6], 5)
  end)
end)

-- ---------------------------------------------------------------------------
-- divisors / num_divisors / sum_divisors
-- ---------------------------------------------------------------------------
T.describe("divisors", function()
  T.it("divisors of 12 are 1,2,3,4,6,12", function()
    local d = NT.divisors(12)
    T.eq(#d, 6)
    T.eq(d[1], 1); T.eq(d[2], 2); T.eq(d[3], 3)
    T.eq(d[4], 4); T.eq(d[5], 6); T.eq(d[6], 12)
  end)
  T.it("divisors of a prime p are 1 and p", function()
    local d = NT.divisors(7)
    T.eq(#d, 2)
    T.eq(d[1], 1)
    T.eq(d[2], 7)
  end)
  T.it("divisors of 1 are just {1}", function()
    local d = NT.divisors(1)
    T.eq(#d, 1)
    T.eq(d[1], 1)
  end)
end)

T.describe("num_divisors", function()
  T.it("τ(12) = 6", function() T.eq(NT.num_divisors(12), 6) end)
  T.it("τ(p) = 2 for prime p", function() T.eq(NT.num_divisors(7), 2) end)
  T.it("τ(1) = 1", function() T.eq(NT.num_divisors(1), 1) end)
  T.it("τ(36) = 9", function() T.eq(NT.num_divisors(36), 9) end)
end)

T.describe("sum_divisors", function()
  T.it("σ(12) = 28", function() T.eq(NT.sum_divisors(12), 28) end)
  T.it("σ(1) = 1", function() T.eq(NT.sum_divisors(1), 1) end)
  T.it("σ(p) = p+1 for prime p", function() T.eq(NT.sum_divisors(7), 8) end)
  T.it("σ(6) = 12", function() T.eq(NT.sum_divisors(6), 12) end)
end)

-- ---------------------------------------------------------------------------
-- GCD / LCM / gcd_ext / coprime
-- ---------------------------------------------------------------------------
T.describe("gcd", function()
  T.it("gcd(12, 8) = 4", function() T.eq(NT.gcd(12, 8), 4) end)
  T.it("gcd(7, 13) = 1", function() T.eq(NT.gcd(7, 13), 1) end)
  T.it("gcd(0, 5) = 5", function() T.eq(NT.gcd(0, 5), 5) end)
  T.it("gcd(a, 0) = a", function() T.eq(NT.gcd(42, 0), 42) end)
  T.it("gcd(100, 75) = 25", function() T.eq(NT.gcd(100, 75), 25) end)
end)

T.describe("lcm", function()
  T.it("lcm(4, 6) = 12", function() T.eq(NT.lcm(4, 6), 12) end)
  T.it("lcm(7, 13) = 91", function() T.eq(NT.lcm(7, 13), 91) end)
  T.it("lcm(0, 5) = 0", function() T.eq(NT.lcm(0, 5), 0) end)
end)

T.describe("gcd_ext", function()
  T.it("verifies ax + by = g for various inputs", function()
    local function check(a, b)
      local g, x, y = NT.gcd_ext(a, b)
      T.eq(g, NT.gcd(a, b))
      T.eq(a * x + b * y, g)
    end
    check(35, 15)
    check(7, 13)
    check(12, 8)
    check(100, 37)
    check(1, 1)
  end)
end)

T.describe("coprime", function()
  T.it("coprime(7, 13) = true", function() T.ok(NT.coprime(7, 13)) end)
  T.it("coprime(4, 6) = false", function() T.ok(not NT.coprime(4, 6)) end)
  T.it("coprime(1, 100) = true", function() T.ok(NT.coprime(1, 100)) end)
end)

-- ---------------------------------------------------------------------------
-- mod_pow
-- ---------------------------------------------------------------------------
T.describe("mod_pow", function()
  T.it("2^10 mod 1000 = 24", function()
    T.eq(NT.mod_pow(2, 10, 1000), 24)
  end)
  T.it("3^0 mod 7 = 1", function()
    T.eq(NT.mod_pow(3, 0, 7), 1)
  end)
  T.it("5^1 mod 13 = 5", function()
    T.eq(NT.mod_pow(5, 1, 13), 5)
  end)
  T.it("2^20 mod 97 (Fermat's little theorem: 2^96 ≡ 1 mod 97)", function()
    -- verify mod_pow gives same result as naive for small case
    local naive = (2^20) % 97
    T.eq(NT.mod_pow(2, 20, 97), naive)
  end)
  T.it("any^exp mod 1 = 0", function()
    T.eq(NT.mod_pow(999, 999, 1), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- mod_inv
-- ---------------------------------------------------------------------------
T.describe("mod_inv", function()
  T.it("3^{-1} mod 7 = 5", function()
    T.eq(NT.mod_inv(3, 7), 5)
  end)
  T.it("inverse times original ≡ 1 mod m", function()
    local inv = NT.mod_inv(17, 1000)
    T.ok(inv ~= nil)
    T.eq((17 * inv) % 1000, 1)
  end)
  T.it("returns nil when gcd != 1", function()
    T.eq(NT.mod_inv(4, 6), nil)
    T.eq(NT.mod_inv(6, 9), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- chinese_remainder
-- ---------------------------------------------------------------------------
T.describe("chinese_remainder", function()
  T.it("x≡2(mod3), x≡3(mod5) → x=8, N=15", function()
    local x, N = NT.chinese_remainder({3, 2}, {5, 3})
    T.eq(N, 15)
    T.eq(x, 8)
    T.eq(x % 3, 2)
    T.eq(x % 5, 3)
  end)
  T.it("x≡0(mod3), x≡0(mod5) → x=0", function()
    local x = NT.chinese_remainder({3, 0}, {5, 0})
    T.eq(x, 0)
  end)
  T.it("three moduli: x≡1(mod2), x≡2(mod3), x≡3(mod5)", function()
    local x, N = NT.chinese_remainder({2, 1}, {3, 2}, {5, 3})
    T.eq(N, 30)
    T.eq(x % 2, 1)
    T.eq(x % 3, 2)
    T.eq(x % 5, 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- euler_phi
-- ---------------------------------------------------------------------------
T.describe("euler_phi", function()
  T.it("φ(1) = 1", function() T.eq(NT.euler_phi(1), 1) end)
  T.it("φ(p) = p-1 for prime p", function()
    T.eq(NT.euler_phi(7), 6)
    T.eq(NT.euler_phi(13), 12)
    T.eq(NT.euler_phi(97), 96)
  end)
  T.it("φ(12) = 4", function() T.eq(NT.euler_phi(12), 4) end)
  T.it("φ(36) = 12", function() T.eq(NT.euler_phi(36), 12) end)
  T.it("φ(2) = 1", function() T.eq(NT.euler_phi(2), 1) end)
end)

-- ---------------------------------------------------------------------------
-- carmichael_lambda
-- ---------------------------------------------------------------------------
T.describe("carmichael_lambda", function()
  T.it("λ(1) = 1", function() T.eq(NT.carmichael_lambda(1), 1) end)
  T.it("λ(p) = p-1 for prime p", function()
    T.eq(NT.carmichael_lambda(7), 6)
  end)
  T.it("λ(12) = 2", function() T.eq(NT.carmichael_lambda(12), 2) end)
  T.it("λ(n) divides φ(n)", function()
    for _, n in ipairs({12, 15, 24, 35, 77}) do
      local phi = NT.euler_phi(n)
      local lam = NT.carmichael_lambda(n)
      T.eq(phi % lam, 0)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- is_perfect / is_abundant / is_deficient
-- ---------------------------------------------------------------------------
T.describe("is_perfect", function()
  T.it("6 and 28 are perfect", function()
    T.ok(NT.is_perfect(6))
    T.ok(NT.is_perfect(28))
  end)
  T.it("496 is perfect", function()
    T.ok(NT.is_perfect(496))
  end)
  T.it("12 and 9 are not perfect", function()
    T.ok(not NT.is_perfect(12))
    T.ok(not NT.is_perfect(9))
  end)
end)

T.describe("is_abundant", function()
  T.it("12 is abundant (1+2+3+4+6=16 > 12)", function()
    T.ok(NT.is_abundant(12))
  end)
  T.it("18 is abundant", function()
    T.ok(NT.is_abundant(18))
  end)
  T.it("6 and 9 are not abundant", function()
    T.ok(not NT.is_abundant(6))
    T.ok(not NT.is_abundant(9))
  end)
end)

T.describe("is_deficient", function()
  T.it("9 is deficient (1+3=4 < 9)", function()
    T.ok(NT.is_deficient(9))
  end)
  T.it("primes are deficient", function()
    T.ok(NT.is_deficient(7))
    T.ok(NT.is_deficient(97))
  end)
  T.it("6 is not deficient", function()
    T.ok(not NT.is_deficient(6))
  end)
  T.it("12 is not deficient", function()
    T.ok(not NT.is_deficient(12))
  end)
end)

-- ---------------------------------------------------------------------------
-- isqrt / is_square / is_power
-- ---------------------------------------------------------------------------
T.describe("isqrt", function()
  T.it("floor(sqrt(n)) for various n", function()
    T.eq(NT.isqrt(0), 0)
    T.eq(NT.isqrt(1), 1)
    T.eq(NT.isqrt(4), 2)
    T.eq(NT.isqrt(8), 2)
    T.eq(NT.isqrt(9), 3)
    T.eq(NT.isqrt(99), 9)
    T.eq(NT.isqrt(100), 10)
    T.eq(NT.isqrt(10000), 100)
  end)
end)

T.describe("is_square", function()
  T.it("perfect squares", function()
    T.ok(NT.is_square(0))
    T.ok(NT.is_square(1))
    T.ok(NT.is_square(4))
    T.ok(NT.is_square(9))
    T.ok(NT.is_square(100))
    T.ok(NT.is_square(10000))
  end)
  T.it("non-squares", function()
    T.ok(not NT.is_square(2))
    T.ok(not NT.is_square(3))
    T.ok(not NT.is_square(5))
    T.ok(not NT.is_square(99))
  end)
end)

T.describe("is_power", function()
  T.it("8 = 2^3", function()
    local b, e = NT.is_power(8)
    T.eq(b, 2); T.eq(e, 3)
  end)
  T.it("27 = 3^3", function()
    local b, e = NT.is_power(27)
    T.eq(b, 3); T.eq(e, 3)
  end)
  T.it("16 = 2^4 or 4^2 (either is valid)", function()
    local b, e = NT.is_power(16)
    T.ok(b ~= nil and e ~= nil)
    T.eq(b ^ e, 16)
  end)
  T.it("non-powers return nil", function()
    T.eq(NT.is_power(1), nil)
    T.eq(NT.is_power(2), nil)
    T.eq(NT.is_power(6), nil)
    T.eq(NT.is_power(10), nil)
  end)
  T.it("100 = 10^2", function()
    local b, e = NT.is_power(100)
    T.ok(b ~= nil and e ~= nil)
    T.eq(b ^ e, 100)
  end)
end)

-- ---------------------------------------------------------------------------
-- primes_up_to / prime_pi
-- ---------------------------------------------------------------------------
T.describe("primes_up_to", function()
  T.it("first 10 primes (up to 29)", function()
    local p = NT.primes_up_to(29)
    T.eq(#p, 10)
    T.eq(p[1], 2); T.eq(p[2], 3); T.eq(p[3], 5)
    T.eq(p[10], 29)
  end)
  T.it("primes up to 100", function()
    local p = NT.primes_up_to(100)
    T.eq(#p, 25)
    T.eq(p[25], 97)
  end)
  T.it("empty for n < 2", function()
    T.eq(#NT.primes_up_to(1), 0)
  end)
end)

T.describe("prime_pi", function()
  T.it("π(10) = 4", function() T.eq(NT.prime_pi(10), 4) end)
  T.it("π(100) = 25", function() T.eq(NT.prime_pi(100), 25) end)
  T.it("π(1) = 0", function() T.eq(NT.prime_pi(1), 0) end)
end)

-- ---------------------------------------------------------------------------
-- Jacobi and Legendre symbols
-- ---------------------------------------------------------------------------
T.describe("jacobi", function()
  T.it("jacobi(1, n) = 1", function()
    T.eq(NT.jacobi(1, 3), 1)
    T.eq(NT.jacobi(1, 15), 1)
  end)
  T.it("jacobi(a, p) for prime p = Legendre symbol", function()
    -- 2 is a QR mod 7? 2^3=8≡1 mod7, so order 3. 2^((7-1)/2)=2^3=8≡1, so QR
    T.eq(NT.jacobi(2, 7), 1)
    -- 3 mod 7: 3^3=27≡6≡-1, so NR
    T.eq(NT.jacobi(3, 7), -1)
    -- 0 mod any prime
    T.eq(NT.jacobi(7, 7), 0)
  end)
  T.it("jacobi for composite n", function()
    -- jacobi(2, 15): 15=3*5, jacobi(2,3)=-1, jacobi(2,5)=-1, product=1
    T.eq(NT.jacobi(2, 15), 1)
  end)
end)

T.describe("legendre", function()
  T.it("legendre(a, p) agrees with jacobi for prime p", function()
    T.eq(NT.legendre(2, 7), NT.jacobi(2, 7))
    T.eq(NT.legendre(3, 7), NT.jacobi(3, 7))
    T.eq(NT.legendre(0, 7), 0)
  end)
  T.it("QR / NR identification", function()
    -- quadratic residues mod 5: 1^2=1, 2^2=4, 3^2=4, 4^2=1 → QRs are 1,4
    T.eq(NT.legendre(1, 5), 1)
    T.eq(NT.legendre(4, 5), 1)
    T.eq(NT.legendre(2, 5), -1)
    T.eq(NT.legendre(3, 5), -1)
  end)
end)
