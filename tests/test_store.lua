-- Content store: objects, log, dedup, labels, rewrite.
local H = require("tests.helpers")
local store = require("strata.store")
local config = require("strata.config")
local eq = MiniTest.expect.equality

local base
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      base = H.tmpdir() .. "/strata"
    end,
    post_case = function()
      H.rm(vim.fs.dirname(base))
    end,
  },
})

T["open creates dir, objects dir and root file"] = function()
  local s = assert(store.open(base, "/tmp/proj"))
  eq(vim.fn.isdirectory(s.dir .. "/objects"), 1)
  eq(H.read(s.dir .. "/root"), "/tmp/proj\n")
  eq(s.dir, store.dir_for(base, "/tmp/proj"))
end

T["store dir is private"] = function()
  local s = assert(store.open(base, "/tmp/proj"))
  eq(vim.fn.getfperm(base), "rwx------")
  eq(vim.fn.getfperm(s.dir), "rwx------")
end

T["put is content addressed and get returns it"] = function()
  local s = assert(store.open(base, "/tmp/proj"))
  local h = s:put("hello\n")
  eq(h, vim.fn.sha256("hello\n"))
  eq(s:put("hello\n"), h)
  eq(s:get(h), "hello\n")
  eq(s:get("nothex!"), nil)
  eq(s:get(("0"):rep(64)), nil)
end

T["snapshot appends an entry and skips duplicates"] = function()
  local s = assert(store.open(base, "/tmp/proj"))
  local e1 = s:snapshot("a.lua", "one\n", "save", 100)
  eq(e1.p, "a.lua")
  eq(e1.e, "save")
  eq(e1.s, 4)
  eq(s:snapshot("a.lua", "one\n", "save", 101), nil)
  local e2 = s:snapshot("a.lua", "two\n", "save", 102)
  eq(#s:entries(), 2)
  eq(s:latest("a.lua").h, e2.h)
  eq(s:latest("b.lua"), nil)
end

T["same content on another path still gets an entry"] = function()
  local s = assert(store.open(base, "/tmp/proj"))
  s:snapshot("a.lua", "x\n", "save", 1)
  s:snapshot("b.lua", "x\n", "save", 2)
  eq(#s:entries(), 2)
  eq(#vim.fn.readdir(s.dir .. "/objects"), 1)
end

T["entries survive reopen and pick up appends from another handle"] = function()
  local s = assert(store.open(base, "/tmp/proj"))
  s:snapshot("a.lua", "one\n", "save", 100)
  s:label("before", 101)
  local s2 = assert(store.open(base, "/tmp/proj"))
  eq(#s2:entries(), 2)
  eq(s2:entries()[2].l, "before")
  s2:snapshot("a.lua", "two\n", "save", 102)
  eq(#s:entries(), 3)
end

T["corrupt log lines are skipped"] = function()
  local s = assert(store.open(base, "/tmp/proj"))
  s:snapshot("a.lua", "one\n", "save", 100)
  local f = assert(io.open(s:log_path(), "a"))
  f:write("{not json\n")
  f:close()
  s:snapshot("a.lua", "two\n", "save", 101)
  eq(#store.open(base, "/tmp/proj"):entries(), 2)
end

T["rewrite drops entries and unreferenced objects"] = function()
  local s = assert(store.open(base, "/tmp/proj"))
  local e1 = s:snapshot("a.lua", "one\n", "save", 100)
  local e2 = s:snapshot("a.lua", "two\n", "save", 101)
  s:rewrite({ e2 })
  eq(#s:entries(), 1)
  eq(s:get(e1.h), nil)
  eq(s:get(e2.h), "two\n")
end

T["all lists stores by root"] = function()
  store.open(base, "/tmp/p1")
  store.open(base, "/tmp/p2")
  local roots = vim.tbl_map(function(s)
    return s.root
  end, store.all(base))
  table.sort(roots)
  eq(roots, { "/tmp/p1", "/tmp/p2" })
end

T["config merges exclude globs instead of replacing"] = function()
  local cfg = config.resolve({ exclude = { "**/*.min.js" }, keep_days = 7 })
  eq(cfg.keep_days, 7)
  eq(vim.tbl_contains(cfg.exclude, "**/*.min.js"), true)
  eq(vim.tbl_contains(cfg.exclude, "**/.git/**"), true)
  eq(#cfg.exclude, #config.defaults.exclude + 1)
end

return T
