-- History queries over a synthetic log.
local H = require("tests.helpers")
local store = require("strata.store")
local history = require("strata.history")
local eq = MiniTest.expect.equality

local tmp, proj, s

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      tmp = H.tmpdir()
      proj = tmp .. "/proj"
      vim.fn.mkdir(proj, "p")
      s = assert(store.open(tmp .. "/store", proj))
    end,
    post_case = function()
      H.rm(tmp)
    end,
  },
})

local function seed()
  s:snapshot("a.lua", "a1\n", "open", 100)
  s:snapshot("b.lua", "b1\n", "open", 110)
  s:label("before refactor", 150)
  s:snapshot("a.lua", "a2\n", "save", 200)
  s:snapshot("c.lua", "c1\n", "save", 260)
  s:snapshot("a.lua", "a3\n", "save", 300)
end

T["file history is newest first and carries labels between snapshots"] = function()
  seed()
  local es = history.file(s, "a.lua")
  eq(
    vim.tbl_map(function(e)
      return e.e .. ":" .. (e.h and s:get(e.h) or e.l)
    end, es),
    { "save:a3\n", "save:a2\n", "label:before refactor", "open:a1\n" }
  )
  eq(history.file(s, "c.lua")[1].e, "save")
  eq(#history.file(s, "c.lua"), 1)
end

T["state_at picks the latest entry up to a time"] = function()
  seed()
  local at = history.state_at(s, 250)
  eq(s:get(at["a.lua"].h), "a2\n")
  eq(s:get(at["b.lua"].h), "b1\n")
  eq(at["c.lua"], nil)
  eq(s:get(history.state_at(s)["a.lua"].h), "a3\n")
end

T["deleted lists tracked paths missing on disk"] = function()
  seed()
  H.write(proj .. "/a.lua", "a3\n")
  local d = history.deleted(s)
  eq(
    vim.tbl_map(function(x)
      return x.p
    end, d),
    { "c.lua", "b.lua" }
  )
end

T["changed_since classifies modified, deleted and added"] = function()
  seed()
  H.write(proj .. "/a.lua", "a3\n") -- differs from state at 250 (a2)
  H.write(proj .. "/c.lua", "c1\n") -- did not exist at 250
  -- b.lua missing on disk
  local ch = history.changed_since(s, 250)
  eq(
    vim.tbl_map(function(c)
      return c.p .. "=" .. c.kind
    end, ch),
    { "a.lua=modified", "b.lua=deleted", "c.lua=added" }
  )
  eq(s:get(ch[1].was.h), "a2\n")
  -- nothing changed when disk matches the state
  H.write(proj .. "/a.lua", "a2\n")
  H.write(proj .. "/b.lua", "b1\n")
  vim.fn.delete(proj .. "/c.lua")
  eq(history.changed_since(s, 250), {})
end

T["timeline groups snapshots per minute and keeps labels as points"] = function()
  seed()
  local tl = history.timeline(s)
  eq(
    vim.tbl_map(function(p)
      return p.kind .. ":" .. (p.text or tostring(p.count))
    end, tl),
    { "snap:1", "snap:1", "snap:1", "label:before refactor", "snap:2" }
  )
  eq(tl[5].paths, { "a.lua", "b.lua" })
  eq(tl[5].t, 110)
  eq(tl[2].t, 260)
end

return T
