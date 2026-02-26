local path = require("lib.path")
local assert = require("lib.test.assert")

-- resolve: basic joining
assert.eq(path.resolve("/srv/www", "index.html"), "/srv/www/index.html", "resolve basic")
assert.eq(path.resolve("/srv/www", "sub/page.html"), "/srv/www/sub/page.html", "resolve nested")

-- resolve: eliminates .
assert.eq(path.resolve("/srv/www", "./index.html"), "/srv/www/index.html", "resolve dot")
assert.eq(path.resolve("/srv/www", "sub/./page.html"), "/srv/www/sub/page.html", "resolve mid dot")

-- resolve: eliminates ..
assert.eq(path.resolve("/srv/www", "sub/../index.html"), "/srv/www/index.html", "resolve dotdot")
assert.eq(path.resolve("/srv/www", "../escape"), "/srv/www/escape", "resolve dotdot clamped")

-- resolve: .. stops at base
assert.eq(path.resolve("/srv", "../../etc/passwd"), "/srv/etc/passwd", "resolve dotdot clamped at base")

-- resolve: absolute path in second arg
assert.eq(path.resolve("/srv/www", "/index.html"), "/srv/www/index.html", "resolve leading slash stripped")

-- resolve: trailing slash on base
assert.eq(path.resolve("/srv/www/", "index.html"), "/srv/www/index.html", "resolve trailing slash")

-- realpath: works on known path
local rp = path.realpath("/tmp")
assert.ok(rp, "realpath /tmp")

-- realpath: returns nil for nonexistent
assert.eq(path.realpath("/nonexistent_path_that_does_not_exist"), nil, "realpath nonexistent")

-- safe_resolve: stays within base
local sr = path.safe_resolve("/tmp", ".")
assert.ok(sr, "safe_resolve within base")

-- safe_resolve: rejects escape
local escaped = path.safe_resolve("/tmp", "../../etc/passwd")
assert.eq(escaped, nil, "safe_resolve rejects escape")
