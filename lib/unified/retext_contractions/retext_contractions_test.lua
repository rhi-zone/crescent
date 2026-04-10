-- lib/unified/retext_contractions/retext_contractions_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T                    = require("lib.test.assert")
local retext               = require("lib.unified.retext")
local retext_contractions  = require("lib.unified.retext_contractions")

-- Helper: process text through retext + contractions plugin, return issues.
local function check(text, opts)
  local p = retext():use(retext_contractions, opts)
  local tree = p:parse(text)
  tree = p:run(tree)
  return (tree.data and tree.data.contractions) or {}
end

-- Helper: find an issue by word.
local function find_issue(issues, word)
  for _, issue in ipairs(issues) do
    if issue.word == word or issue.word:lower() == word:lower() then
      return issue
    end
  end
  return nil
end

T.describe("retext_contractions: missing apostrophe detection", function()
  T.it("detects 'dont'", function()
    local issues = check("I dont know.")
    local issue = find_issue(issues, "dont")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "don't")
  end)

  T.it("detects 'cant'", function()
    local issues = check("I cant go.")
    local issue = find_issue(issues, "cant")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "can't")
  end)

  T.it("detects 'wont'", function()
    local issues = check("She wont come.")
    local issue = find_issue(issues, "wont")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "won't")
  end)

  T.it("detects 'wouldnt'", function()
    local issues = check("He wouldnt leave.")
    local issue = find_issue(issues, "wouldnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "wouldn't")
  end)

  T.it("detects 'couldnt'", function()
    local issues = check("I couldnt believe it.")
    local issue = find_issue(issues, "couldnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "couldn't")
  end)

  T.it("detects 'shouldnt'", function()
    local issues = check("You shouldnt do that.")
    local issue = find_issue(issues, "shouldnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "shouldn't")
  end)

  T.it("detects 'doesnt'", function()
    local issues = check("It doesnt matter.")
    local issue = find_issue(issues, "doesnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "doesn't")
  end)

  T.it("detects 'didnt'", function()
    local issues = check("She didnt say.")
    local issue = find_issue(issues, "didnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "didn't")
  end)

  T.it("detects 'isnt'", function()
    local issues = check("That isnt right.")
    local issue = find_issue(issues, "isnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "isn't")
  end)

  T.it("detects 'arent'", function()
    local issues = check("They arent here.")
    local issue = find_issue(issues, "arent")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "aren't")
  end)

  T.it("detects 'wasnt'", function()
    local issues = check("It wasnt there.")
    local issue = find_issue(issues, "wasnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "wasn't")
  end)

  T.it("detects 'werent'", function()
    local issues = check("They werent ready.")
    local issue = find_issue(issues, "werent")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "weren't")
  end)

  T.it("detects 'havent'", function()
    local issues = check("I havent eaten.")
    local issue = find_issue(issues, "havent")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "haven't")
  end)

  T.it("detects 'hasnt'", function()
    local issues = check("She hasnt left.")
    local issue = find_issue(issues, "hasnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "hasn't")
  end)

  T.it("detects 'hadnt'", function()
    local issues = check("He hadnt finished.")
    local issue = find_issue(issues, "hadnt")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "hadn't")
  end)

  T.it("detects 'youre'", function()
    local issues = check("I think youre right.")
    local issue = find_issue(issues, "youre")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "you're")
  end)

  T.it("detects 'theyre'", function()
    local issues = check("I know theyre coming.")
    local issue = find_issue(issues, "theyre")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "they're")
  end)

  T.it("detects 'im'", function()
    local issues = check("im going now.")
    local issue = find_issue(issues, "im")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "I'm")
  end)

  T.it("detects 'ill'", function()
    local issues = check("ill be there.")
    local issue = find_issue(issues, "ill")
    T.ok(issue ~= nil)
    T.eq(issue.suggestion, "I'll")
  end)
end)

T.describe("retext_contractions: no false positives", function()
  T.it("ignores correct contraction with straight apostrophe", function()
    local issues = check("I don't know.")
    T.eq(#issues, 0)
  end)

  T.it("ignores normal words", function()
    local issues = check("Hello world today.")
    T.eq(#issues, 0)
  end)

  T.it("multiple issues in one sentence", function()
    local issues = check("I dont know and I cant go.")
    T.ok(#issues >= 2)
    T.ok(find_issue(issues, "dont") ~= nil)
    T.ok(find_issue(issues, "cant") ~= nil)
  end)
end)

T.describe("retext_contractions: sentence stored in issue", function()
  T.it("sentence field is set", function()
    local issues = check("I dont know.")
    T.eq(#issues, 1)
    T.ok(issues[1].sentence ~= nil)
    T.ok(issues[1].sentence:find("dont") ~= nil)
  end)
end)

T.describe("retext_contractions: opts.straight mode", function()
  T.it("warns on curly apostrophe when opts.straight=true", function()
    -- Inject a word with curly apostrophe directly into the nlcst tree.
    local nlcst_mod = require("lib.unified.nlcst")
    local tree = nlcst_mod.root({
      nlcst_mod.paragraph({
        nlcst_mod.sentence({
          nlcst_mod.word("don\xe2\x80\x99t"),  -- don't with curly apostrophe
        }),
      }),
    })
    local p = retext():use(retext_contractions, { straight = true })
    tree = p:run(tree)
    local issues = tree.data and tree.data.contractions or {}
    T.ok(#issues >= 1)
    T.eq(issues[1].suggestion, "don't")
  end)

  T.it("no warning on straight apostrophe when opts.straight=true", function()
    local issues = check("don't go.", { straight = true })
    T.eq(#issues, 0)
  end)
end)

T.describe("retext_contractions: opts.smart mode", function()
  T.it("warns on straight apostrophe when opts.smart=true", function()
    local issues = check("don't go.", { smart = true })
    -- "don't" has a straight apostrophe — should flag it
    T.ok(#issues >= 1)
    T.ok(issues[1].suggestion:find("\xe2\x80\x99") ~= nil)
  end)
end)

T.describe("retext_contractions: CONTRACTIONS table", function()
  T.it("exposes the dictionary", function()
    T.ok(type(retext_contractions.CONTRACTIONS) == "table")
    T.eq(retext_contractions.CONTRACTIONS.dont, "don't")
    T.eq(retext_contractions.CONTRACTIONS.cant, "can't")
  end)
end)
