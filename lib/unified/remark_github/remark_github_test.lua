-- lib/unified/remark_github/remark_github_test.lua
-- Tests for the remark_github plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T            = require("lib.test.assert")
local remark       = require("lib.unified.remark")
local remarkGithub = require("lib.unified.remark_github")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_proc(opts)
  return remark():use(remarkGithub, opts)
end

local function parse_and_run(src, opts)
  local proc = make_proc(opts)
  local ast, err = proc:parse(src)
  assert(ast, err)
  return proc:run(ast)
end

-- Return children of the first paragraph.
local function para_children(ast)
  local para = ast.children[1]
  if not para then return {} end
  return para.children or {}
end

-- Find the first node of given type (depth-first) in a list.
local function find_type(nodes, typ)
  for _, n in ipairs(nodes) do
    if n.type == typ then return n end
  end
  return nil
end

-- ── Issue / PR links ──────────────────────────────────────────────────────────

T.describe("remark_github: issue links", function()
  T.it("#123 becomes a link to issues/123", function()
    local ast = parse_and_run("See #123 for details.", { repo = "owner/repo" })
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.ok(lnk ~= nil, "link node exists")
    T.eq(lnk.url, "https://github.com/owner/repo/issues/123")
    T.eq(lnk.children[1].value, "#123")
  end)

  T.it("multiple issue refs in same paragraph", function()
    local ast = parse_and_run("Fixes #1 and #2.", { repo = "owner/repo" })
    local children = para_children(ast)
    local links = {}
    for _, n in ipairs(children) do
      if n.type == "link" then links[#links + 1] = n end
    end
    T.eq(#links, 2)
    T.eq(links[1].url, "https://github.com/owner/repo/issues/1")
    T.eq(links[2].url, "https://github.com/owner/repo/issues/2")
  end)

  T.it("#123 skipped when repo is absent", function()
    local ast = parse_and_run("See #123 for details.")
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.eq(lnk, nil)
  end)
end)

-- ── @mention links ────────────────────────────────────────────────────────────

T.describe("remark_github: @mention links", function()
  T.it("@user becomes a link to github.com/user", function()
    local ast = parse_and_run("Thanks @alice!", { repo = "owner/repo" })
    local children = para_children(ast)
    -- mentionStrong=true by default → strong wrapping the link
    local strong = find_type(children, "strong")
    T.ok(strong ~= nil, "strong node exists")
    local lnk = strong.children[1]
    T.eq(lnk.type, "link")
    T.eq(lnk.url, "https://github.com/alice")
    T.eq(lnk.children[1].value, "@alice")
  end)

  T.it("mentionStrong=false wraps in link only", function()
    local ast = parse_and_run("Thanks @alice!", { repo = "owner/repo", mentionStrong = false })
    local children = para_children(ast)
    local strong = find_type(children, "strong")
    T.eq(strong, nil)
    local lnk = find_type(children, "link")
    T.ok(lnk ~= nil, "link node exists")
    T.eq(lnk.url, "https://github.com/alice")
  end)

  T.it("@mention works without repo option", function()
    local ast = parse_and_run("Thanks @bob!", {})
    local children = para_children(ast)
    local strong = find_type(children, "strong")
    T.ok(strong ~= nil, "strong node present even without repo")
    T.eq(strong.children[1].url, "https://github.com/bob")
  end)
end)

-- ── Commit SHA links ──────────────────────────────────────────────────────────

T.describe("remark_github: commit SHA links", function()
  T.it("7-char hex SHA becomes commit link", function()
    local ast = parse_and_run("Commit a5c3785 fixed it.", { repo = "owner/repo" })
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.ok(lnk ~= nil, "link node exists")
    T.eq(lnk.url, "https://github.com/owner/repo/commit/a5c3785")
  end)

  T.it("40-char hex SHA becomes commit link", function()
    local sha = "a5c3785ed8d6a35868bc169f07e40e889087fd2e"
    local ast = parse_and_run("Commit " .. sha .. " fixed it.", { repo = "owner/repo" })
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.ok(lnk ~= nil, "link node exists")
    T.ok(lnk.url:find(sha, 1, true), "full SHA in URL")
  end)

  T.it("commit SHA skipped when repo is absent", function()
    local ast = parse_and_run("Commit a5c3785 fixed it.")
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.eq(lnk, nil)
  end)

  T.it("6-char hex is NOT linked (too short for SHA)", function()
    local ast = parse_and_run("Color a5c378 is nice.", { repo = "owner/repo" })
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.eq(lnk, nil)
  end)
end)

-- ── Cross-repo references ─────────────────────────────────────────────────────

T.describe("remark_github: cross-repo refs", function()
  T.it("user/repo#123 becomes cross-repo issue link", function()
    local ast = parse_and_run("See other/project#42.", { repo = "owner/repo" })
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.ok(lnk ~= nil, "link node exists")
    T.eq(lnk.url, "https://github.com/other/project/issues/42")
    T.eq(lnk.children[1].value, "other/project#42")
  end)

  T.it("user/repo@SHA becomes cross-repo commit link", function()
    local ast = parse_and_run("See other/project@a5c3785.", { repo = "owner/repo" })
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.ok(lnk ~= nil, "link node exists")
    T.eq(lnk.url, "https://github.com/other/project/commit/a5c3785")
    T.eq(lnk.children[1].value, "other/project@a5c3785")
  end)

  T.it("cross-repo refs work even without opts.repo", function()
    local ast = parse_and_run("See other/project#7.")
    local children = para_children(ast)
    local lnk = find_type(children, "link")
    T.ok(lnk ~= nil, "cross-repo link works without repo opt")
    T.eq(lnk.url, "https://github.com/other/project/issues/7")
  end)
end)
