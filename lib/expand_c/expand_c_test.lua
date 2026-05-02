-- lib/expand_c/expand_c_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local E = require("lib.expand_c")

-- ---------------------------------------------------------------------------
-- Mock popen_fn builder
-- ---------------------------------------------------------------------------

-- Builds a popen_fn that returns a fake file reading from output_lines.
-- Uses 'any' parameter type to avoid nil-in-array typecheck complaints.
--: (any) -> (string, string) -> unknown
local function fake_popen(output_lines)
  return function(_, _)
    local idx = 0
    return {
      read = function(_, _)
        idx = idx + 1
        return output_lines[idx]
      end,
    }
  end
end

-- ---------------------------------------------------------------------------
-- M.expand
-- ---------------------------------------------------------------------------

T.describe("M.expand", function()
  T.it("returns empty table for empty name list", function()
    local popen_fn = fake_popen({})
    local result, err = E.expand({}, { popen_fn = popen_fn })
    T.eq(err, nil)
    T.ok(result ~= nil, "result is not nil")
    T.eq(next(result --[[: any]]), nil)  -- empty table
  end)

  T.it("parses RESULT_NAME=value lines", function()
    local lines = { --: any
      "# preprocessor comment",
      'RESULT_INT_MAX="2147483647"',
      'RESULT_EXIT_SUCCESS="0"',
    }
    local popen_fn = fake_popen(lines)
    local result, err = E.expand({ "INT_MAX", "EXIT_SUCCESS" }, { popen_fn = popen_fn })
    T.eq(err, nil)
    T.ok(result ~= nil, "result not nil")
    local r = result --[[: any]]
    T.eq(r["INT_MAX"], "2147483647")
    T.eq(r["EXIT_SUCCESS"], "0")
  end)

  T.it("ignores lines that do not match RESULT_ pattern", function()
    local lines = { --: any
      "# some preprocessor output",
      "other stuff here",
      'RESULT_FOO="bar"',
    }
    local popen_fn = fake_popen(lines)
    local result, err = E.expand({ "FOO" }, { popen_fn = popen_fn })
    T.eq(err, nil)
    local r = result --[[: any]]
    T.eq(r["FOO"], "bar")
    T.eq(r["other stuff here"], nil)
  end)

  T.it("returns nil and error when popen_fn returns nil", function()
    --: (string, string) -> unknown
    local popen_fn = function(_, _) return nil end
    local result, err = E.expand({ "FOO" }, { popen_fn = popen_fn })
    T.eq(result, nil)
    T.ok(err ~= nil, "error message present")
  end)

  T.it("requires opts.popen_fn", function()
    local result, err = E.expand({ "FOO" }, {} --[[: any]])
    T.eq(result, nil)
    T.ok(err ~= nil, "error when no popen_fn")
  end)
end)

T.describe("M.expand_one", function()
  T.it("returns the single expanded value", function()
    local lines = { --: any
      'RESULT_STDIN_FILENO="0"',
    }
    local popen_fn = fake_popen(lines)
    local val, err = E.expand_one("STDIN_FILENO", { popen_fn = popen_fn })
    T.eq(err, nil)
    T.eq(val, "0")
  end)

  T.it("returns nil value when name not found in output", function()
    local lines = {} --: any
    local popen_fn = fake_popen(lines)
    local val, err = E.expand_one("NOT_THERE", { popen_fn = popen_fn })
    T.eq(err, nil)
    T.eq(val, nil)
  end)
end)
