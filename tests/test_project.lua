-- Project timeline, changes since a point, restore all, quilt hits.
local H = require("tests.helpers")
local capture = require("strata.capture")
local config = require("strata.config")
local history = require("strata.history")
local ui = require("strata.ui")
local eq = MiniTest.expect.equality

local tmp, proj, base, s

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      tmp = H.tmpdir()
      proj = tmp .. "/proj"
      base = tmp .. "/store"
      vim.fn.mkdir(proj .. "/.git", "p")
      capture.setup(config.resolve({ dir = base }))
      s = capture.store_for(proj)
    end,
    post_case = function()
      ui.close()
      vim.cmd("silent! %bwipeout!")
      H.rm(tmp)
    end,
  },
})

-- a.lua edited after the label, b.lua deleted after it, c.lua added after it
local function seed()
  s:snapshot("a.lua", "a1\nsame\n", "save", 100)
  s:snapshot("b.lua", "b1\n", "save", 100)
  s:label("before refactor", 150)
  s:snapshot("a.lua", "a2\nsame\nnew\n", "save", 200)
  s:snapshot("c.lua", "c1\n", "save", 200)
  H.write(proj .. "/a.lua", "a2\nsame\nnew\n")
  H.write(proj .. "/c.lua", "c1\n")
end

T["project view lists the timeline newest first"] = function()
  seed()
  ui.project(s)
  local lines = vim.api.nvim_buf_get_lines(ui._current.buf, 0, -1, false)
  eq(#lines, 3)
  eq(lines[1]:match("2 files"), "2 files")
  eq(lines[2]:match("before refactor"), "before refactor")
  eq(lines[3]:match("2 files"), "2 files")
end

T["drilling into a label lists changes since it"] = function()
  seed()
  ui.project(s)
  ui._current.actions.diff(2)
  local lines = vim.api.nvim_buf_get_lines(ui._current.buf, 0, -1, false)
  eq(lines, { "modified  a.lua", "deleted   b.lua", "added     c.lua" })
end

T["restore_all puts modified and deleted files back and leaves added ones"] = function()
  seed()
  ui.changes(s, 150, "t")
  ui._current.actions.restore_all()
  eq(H.read(proj .. "/a.lua"), "a1\nsame\n")
  eq(H.read(proj .. "/b.lua"), "b1\n")
  eq(H.read(proj .. "/c.lua"), "c1\n")
  eq(#history.changed_since(s, 150), 1)
  eq(history.changed_since(s, 150)[1].kind, "added")
end

T["restore of one modified file goes through the buffer when loaded"] = function()
  seed()
  vim.cmd.edit(vim.fn.fnameescape(proj .. "/a.lua"))
  ui.changes(s, 150, "t")
  ui._current.actions.restore(1)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "a1", "same" })
  eq(H.read(proj .. "/a.lua"), "a1\nsame\n")
end

T["hits cover changed ranges in the current file"] = function()
  seed()
  local hits = ui.hits(s, history.changed_since(s, 150))
  eq(hits, {
    { path = proj .. "/a.lua", row = 0, end_row = 1 },
    { path = proj .. "/a.lua", row = 2, end_row = 3 },
  })
end

T["hits mark a pure deletion at the line that follows it"] = function()
  s:snapshot("d.lua", "one\ntwo\nthree\n", "save", 100)
  s:label("x", 150)
  H.write(proj .. "/d.lua", "one\nthree\n")
  s:snapshot("d.lua", "one\nthree\n", "save", 200)
  eq(ui.hits(s, history.changed_since(s, 150)), { { path = proj .. "/d.lua", row = 1, end_row = 2 } })
end

T["empty timeline and no changes only notify"] = function()
  ui.project(s)
  eq(ui._current, nil)
  seed()
  H.write(proj .. "/b.lua", "b1\n")
  ui.changes(s, 300, "t")
  eq(ui._current, nil)
end

return T
