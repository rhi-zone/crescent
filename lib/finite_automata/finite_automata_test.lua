if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local FA = require("lib.finite_automata")

-- ---------------------------------------------------------------------------
-- DFA: accepts strings ending in "ab"  (alphabet {a,b})
-- ---------------------------------------------------------------------------
T.describe("DFA: ends with 'ab'", function()
  -- States: q0=start, q1=saw 'a', q2=saw 'ab' (accept)
  local dfa = FA.dfa({
    states = {"q0", "q1", "q2"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = "q1", b = "q0"},
      q1 = {a = "q1", b = "q2"},
      q2 = {a = "q1", b = "q0"},
    },
  })

  T.it("accepts 'ab'", function() T.ok(dfa:run("ab")) end)
  T.it("accepts 'aab'", function() T.ok(dfa:run("aab")) end)
  T.it("accepts 'bab'", function() T.ok(dfa:run("bab")) end)
  T.it("accepts symbol array {a,b}", function()
    T.ok(dfa:run({"a","b"}))
  end)
  T.it("rejects empty string", function() T.ok(not dfa:run("")) end)
  T.it("rejects 'a'", function() T.ok(not dfa:run("a")) end)
  T.it("rejects 'ba'", function() T.ok(not dfa:run("ba")) end)
  T.it("rejects 'abb'", function() T.ok(not dfa:run("abb")) end)
end)

-- ---------------------------------------------------------------------------
-- DFA: binary strings with even number of 1s  (alphabet {0,1})
-- ---------------------------------------------------------------------------
T.describe("DFA: even number of 1s", function()
  local dfa = FA.dfa({
    states = {"even", "odd"},
    alphabet = {"0", "1"},
    initial = "even",
    accepting = {"even"},
    transitions = {
      even = {["0"] = "even", ["1"] = "odd"},
      odd  = {["0"] = "odd",  ["1"] = "even"},
    },
  })

  T.it("accepts empty string (zero 1s)", function() T.ok(dfa:run("")) end)
  T.it("accepts '00'", function() T.ok(dfa:run("00")) end)
  T.it("accepts '11'", function() T.ok(dfa:run("11")) end)
  T.it("accepts '101' (two 1s)", function() T.ok(dfa:run("101")) end)
  T.it("accepts '1001' (two 1s)", function() T.ok(dfa:run("1001")) end)
  T.it("accepts '1010'", function() T.ok(dfa:run("1010")) end)
  T.it("rejects '1'", function() T.ok(not dfa:run("1")) end)
  T.it("rejects '0010'", function() T.ok(not dfa:run("0010")) end)
end)

-- ---------------------------------------------------------------------------
-- trace()
-- ---------------------------------------------------------------------------
T.describe("DFA: trace()", function()
  local dfa = FA.dfa({
    states = {"q0", "q1", "q2"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = "q1", b = "q0"},
      q1 = {a = "q1", b = "q2"},
      q2 = {a = "q1", b = "q0"},
    },
  })

  T.it("trace of 'aab' is {q0,q1,q1,q2}", function()
    local trace, accepted = dfa:trace("aab")
    T.eq(#trace, 4)
    T.eq(trace[1], "q0")
    T.eq(trace[2], "q1")
    T.eq(trace[3], "q1")
    T.eq(trace[4], "q2")
    T.ok(accepted)
  end)

  T.it("trace of 'ba' is {q0,q0,q1}, not accepted", function()
    local trace, accepted = dfa:trace("ba")
    T.eq(#trace, 3)
    T.eq(trace[1], "q0")
    T.eq(trace[2], "q0")
    T.eq(trace[3], "q1")
    T.ok(not accepted)
  end)

  T.it("trace of empty string is just {q0}", function()
    local trace, accepted = dfa:trace("")
    T.eq(#trace, 1)
    T.eq(trace[1], "q0")
    T.ok(not accepted)
  end)
end)

-- ---------------------------------------------------------------------------
-- Dead state handling
-- ---------------------------------------------------------------------------
T.describe("DFA: dead state handling", function()
  -- DFA with no transition for 'b' from q0
  local dfa = FA.dfa({
    states = {"q0", "q1"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q1"},
    transitions = {
      q0 = {a = "q1"},
      q1 = {a = "q1"},
    },
  })

  T.it("rejects input leading to dead state", function()
    T.ok(not dfa:run("b"))
    T.ok(not dfa:run("ab"))
  end)
  T.it("accepts valid input with no dead state", function()
    T.ok(dfa:run("a"))
    T.ok(dfa:run("aa"))
  end)
end)

-- ---------------------------------------------------------------------------
-- enumerate()
-- ---------------------------------------------------------------------------
T.describe("DFA: enumerate()", function()
  -- Accepts strings ending in "ab" over {a,b}
  local dfa = FA.dfa({
    states = {"q0", "q1", "q2"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = "q1", b = "q0"},
      q1 = {a = "q1", b = "q2"},
      q2 = {a = "q1", b = "q0"},
    },
  })

  T.it("enumerate(3) includes 'ab', 'aab', 'bab'", function()
    local strs = dfa:enumerate(3)
    -- Convert each array to string for easy comparison
    local set = {}
    for _, arr in ipairs(strs) do
      set[table.concat(arr)] = true
    end
    T.ok(set["ab"])
    T.ok(set["aab"])
    T.ok(set["bab"])
    T.ok(not set["ba"])
    T.ok(not set["abb"])
  end)

  T.it("enumerate(1) includes only 'ab'-length-1 accepted strings", function()
    local strs = dfa:enumerate(1)
    -- No string of length 1 ends in 'ab'
    T.eq(#strs, 0)
  end)

  -- DFA accepting empty string (initial is accepting)
  local dfa_eps = FA.dfa({
    states = {"q0"},
    alphabet = {"a"},
    initial = "q0",
    accepting = {"q0"},
    transitions = {q0 = {a = "q0"}},
  })

  T.it("enumerate includes empty string when initial is accepting", function()
    local strs = dfa_eps:enumerate(2)
    local set = {}
    for _, arr in ipairs(strs) do
      set[table.concat(arr)] = true
    end
    T.ok(set[""])  -- empty string (path = {})
    T.ok(set["a"])
    T.ok(set["aa"])
  end)
end)

-- ---------------------------------------------------------------------------
-- NFA: accepts strings containing "ab" as substring  (alphabet {a,b})
-- ---------------------------------------------------------------------------
T.describe("NFA: contains 'ab' as substring", function()
  --[[
    q0 -a-> q1, q0 -a-> q0, q0 -b-> q0
    q1 -b-> q2 (accept)
    q2 -a-> q2, q2 -b-> q2
  ]]
  local nfa = FA.nfa({
    states = {"q0", "q1", "q2"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = {"q0","q1"}, b = {"q0"}},
      q1 = {b = {"q2"}},
      q2 = {a = {"q2"}, b = {"q2"}},
    },
  })

  T.it("accepts 'ab'", function() T.ok(nfa:run("ab")) end)
  T.it("accepts 'aab'", function() T.ok(nfa:run("aab")) end)
  T.it("accepts 'abb'", function() T.ok(nfa:run("abb")) end)
  T.it("accepts 'bab'", function() T.ok(nfa:run("bab")) end)
  T.it("accepts symbol array {a,b}", function()
    T.ok(nfa:run({"a","b"}))
  end)
  T.it("rejects 'a'", function() T.ok(not nfa:run("a")) end)
  T.it("rejects 'b'", function() T.ok(not nfa:run("b")) end)
  T.it("rejects 'ba'", function() T.ok(not nfa:run("ba")) end)
  T.it("rejects empty string", function() T.ok(not nfa:run("")) end)
end)

-- ---------------------------------------------------------------------------
-- NFA with epsilon transitions: a*b
-- ---------------------------------------------------------------------------
T.describe("NFA: a*b (epsilon transitions)", function()
  --[[
    q0 -ε-> q1   (can skip 'a' loop)
    q0 -a-> q0   (loop on 'a')
    q1 -b-> q2   (accept)
  ]]
  local nfa = FA.nfa({
    states = {"q0", "q1", "q2"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = {"q0"}, [""] = {"q1"}},
      q1 = {b = {"q2"}},
    },
  })

  T.it("accepts 'b'", function() T.ok(nfa:run("b")) end)
  T.it("accepts 'ab'", function() T.ok(nfa:run("ab")) end)
  T.it("accepts 'aab'", function() T.ok(nfa:run("aab")) end)
  T.it("accepts 'aaab'", function() T.ok(nfa:run("aaab")) end)
  T.it("rejects empty string", function() T.ok(not nfa:run("")) end)
  T.it("rejects 'a'", function() T.ok(not nfa:run("a")) end)
  T.it("rejects 'bb'", function() T.ok(not nfa:run("bb")) end)
  T.it("rejects 'ba'", function() T.ok(not nfa:run("ba")) end)
end)

-- ---------------------------------------------------------------------------
-- NFA → DFA conversion (subset construction)
-- ---------------------------------------------------------------------------
T.describe("NFA to DFA conversion", function()
  -- NFA that accepts strings containing "ab"
  local nfa = FA.nfa({
    states = {"q0", "q1", "q2"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = {"q0","q1"}, b = {"q0"}},
      q1 = {b = {"q2"}},
      q2 = {a = {"q2"}, b = {"q2"}},
    },
  })

  local dfa = nfa:to_dfa()

  T.it("converted DFA accepts 'ab'", function() T.ok(dfa:run("ab")) end)
  T.it("converted DFA accepts 'aab'", function() T.ok(dfa:run("aab")) end)
  T.it("converted DFA accepts 'bab'", function() T.ok(dfa:run("bab")) end)
  T.it("converted DFA rejects 'a'", function() T.ok(not dfa:run("a")) end)
  T.it("converted DFA rejects 'ba'", function() T.ok(not dfa:run("ba")) end)
  T.it("converted DFA rejects empty string", function() T.ok(not dfa:run("")) end)

  -- NFA with epsilon transitions: a*b
  local nfa_eps = FA.nfa({
    states = {"q0", "q1", "q2"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = {"q0"}, [""] = {"q1"}},
      q1 = {b = {"q2"}},
    },
  })
  local dfa_eps = nfa_eps:to_dfa()

  T.it("epsilon NFA→DFA accepts 'b'", function() T.ok(dfa_eps:run("b")) end)
  T.it("epsilon NFA→DFA accepts 'ab'", function() T.ok(dfa_eps:run("ab")) end)
  T.it("epsilon NFA→DFA accepts 'aab'", function() T.ok(dfa_eps:run("aab")) end)
  T.it("epsilon NFA→DFA rejects 'a'", function() T.ok(not dfa_eps:run("a")) end)
  T.it("epsilon NFA→DFA rejects ''", function() T.ok(not dfa_eps:run("")) end)
end)

-- ---------------------------------------------------------------------------
-- DFA minimization
-- ---------------------------------------------------------------------------
T.describe("DFA minimization", function()
  -- Non-minimal DFA for even number of 1s (has redundant states)
  -- Add extra equivalent states to the "even" class
  local dfa = FA.dfa({
    states = {"even", "odd", "even2"},
    alphabet = {"0", "1"},
    initial = "even",
    accepting = {"even", "even2"},
    transitions = {
      even  = {["0"] = "even2", ["1"] = "odd"},
      even2 = {["0"] = "even",  ["1"] = "odd"},
      odd   = {["0"] = "odd",   ["1"] = "even"},
    },
  })

  local min = dfa:minimize()

  T.it("minimized DFA has fewer or equal states", function()
    T.ok(#min.states <= #dfa.states)
  end)

  T.it("minimized DFA still accepts even number of 1s", function()
    T.ok(min:run(""))
    T.ok(min:run("11"))
    T.ok(min:run("1010"))
    T.ok(not min:run("1"))
    T.ok(not min:run("10"))
  end)

  T.it("minimized state count is 2 (even/odd classes)", function()
    T.eq(#min.states, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Equivalence
-- ---------------------------------------------------------------------------
T.describe("FA.equivalent()", function()
  -- Two DFAs both accepting "even number of 1s" — equivalent
  local dfa1 = FA.dfa({
    states = {"even", "odd"},
    alphabet = {"0", "1"},
    initial = "even",
    accepting = {"even"},
    transitions = {
      even = {["0"] = "even", ["1"] = "odd"},
      odd  = {["0"] = "odd",  ["1"] = "even"},
    },
  })

  -- Same semantics, different state names
  local dfa2 = FA.dfa({
    states = {"s0", "s1"},
    alphabet = {"0", "1"},
    initial = "s0",
    accepting = {"s0"},
    transitions = {
      s0 = {["0"] = "s0", ["1"] = "s1"},
      s1 = {["0"] = "s1", ["1"] = "s0"},
    },
  })

  -- DFA accepting odd number of 1s — NOT equivalent to dfa1
  local dfa3 = FA.dfa({
    states = {"even", "odd"},
    alphabet = {"0", "1"},
    initial = "even",
    accepting = {"odd"},
    transitions = {
      even = {["0"] = "even", ["1"] = "odd"},
      odd  = {["0"] = "odd",  ["1"] = "even"},
    },
  })

  T.it("equivalent DFAs detected as equivalent", function()
    T.ok(FA.equivalent(dfa1, dfa2))
  end)

  T.it("non-equivalent DFAs detected as non-equivalent", function()
    T.ok(not FA.equivalent(dfa1, dfa3))
  end)

  T.it("DFA is equivalent to itself", function()
    T.ok(FA.equivalent(dfa1, dfa1))
  end)

  -- Minimized DFA should be equivalent to original
  local dfa_nonmin = FA.dfa({
    states = {"even", "odd", "even2"},
    alphabet = {"0", "1"},
    initial = "even",
    accepting = {"even", "even2"},
    transitions = {
      even  = {["0"] = "even2", ["1"] = "odd"},
      even2 = {["0"] = "even",  ["1"] = "odd"},
      odd   = {["0"] = "odd",   ["1"] = "even"},
    },
  })
  local min = dfa_nonmin:minimize()

  T.it("minimized DFA is equivalent to original", function()
    T.ok(FA.equivalent(dfa_nonmin, min))
  end)

  -- NFA-derived DFA equivalent to original NFA behavior
  local nfa = FA.nfa({
    states = {"q0", "q1", "q2"},
    alphabet = {"a", "b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = {"q0","q1"}, b = {"q0"}},
      q1 = {b = {"q2"}},
      q2 = {a = {"q2"}, b = {"q2"}},
    },
  })
  local nfa_dfa = nfa:to_dfa()
  -- hand-crafted DFA for "contains ab"
  local ref_dfa = FA.dfa({
    states = {"q0","q1","q2"},
    alphabet = {"a","b"},
    initial = "q0",
    accepting = {"q2"},
    transitions = {
      q0 = {a = "q1", b = "q0"},
      q1 = {a = "q1", b = "q2"},
      q2 = {a = "q2", b = "q2"},
    },
  })
  T.it("NFA→DFA equivalent to hand-crafted DFA for 'contains ab'", function()
    T.ok(FA.equivalent(nfa_dfa, ref_dfa))
  end)
end)

-- ---------------------------------------------------------------------------
-- Empty string acceptance
-- ---------------------------------------------------------------------------
T.describe("Empty string (ε) acceptance", function()
  local dfa_acc_eps = FA.dfa({
    states = {"q0"},
    alphabet = {"a"},
    initial = "q0",
    accepting = {"q0"},
    transitions = {q0 = {a = "q0"}},
  })

  local dfa_rej_eps = FA.dfa({
    states = {"q0", "q1"},
    alphabet = {"a"},
    initial = "q0",
    accepting = {"q1"},
    transitions = {q0 = {a = "q1"}, q1 = {a = "q1"}},
  })

  T.it("DFA with accepting initial state accepts empty string", function()
    T.ok(dfa_acc_eps:run(""))
  end)

  T.it("DFA with non-accepting initial state rejects empty string", function()
    T.ok(not dfa_rej_eps:run(""))
  end)

  local nfa_acc_eps = FA.nfa({
    states = {"q0"},
    alphabet = {"a"},
    initial = "q0",
    accepting = {"q0"},
    transitions = {q0 = {a = {"q0"}}},
  })

  T.it("NFA with accepting initial state accepts empty string", function()
    T.ok(nfa_acc_eps:run(""))
  end)

  -- NFA with epsilon transition to accepting state
  local nfa_eps_to_acc = FA.nfa({
    states = {"q0", "q1"},
    alphabet = {"a"},
    initial = "q0",
    accepting = {"q1"},
    transitions = {
      q0 = {[""] = {"q1"}},
      q1 = {a = {"q1"}},
    },
  })

  T.it("NFA with epsilon to accepting state accepts empty string", function()
    T.ok(nfa_eps_to_acc:run(""))
  end)

  T.it("NFA with epsilon to accepting state also accepts 'a'", function()
    T.ok(nfa_eps_to_acc:run("a"))
  end)
end)
