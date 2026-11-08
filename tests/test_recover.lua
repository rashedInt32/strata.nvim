-- Recovering deleted files through the UI and the command.
local H = require("tests.helpers")
local capture = require("strata.capture")
local config = require("strata.config")
local ui = require("strata.ui")
local eq = MiniTest.expect.equality

local tmp, proj, base

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      tmp = H.tmpdir()
      proj = tmp .. "/proj"
      base = tmp .. "/store"
      vim.fn.mkdir(proj .. "/.git", "p")
      capture.setup(config.resolve({ dir = base }))
      capture.attach()
    end,
    post_case = function()
      ui.close()
      vim.cmd("silent! %bwipeout!")
      vim.api.nvim_create_augroup("strata", { clear = true })
      H.rm(tmp)
    end,
  },
})

T["recover lists deleted files and restores the picked one"] = function()
  local f = proj .. "/src/gone.lua"
  H.write(f, "keep me\n")
  edit(f)
  vim.cmd("silent! %bwipeout!")
  vim.fn.delete(proj .. "/src", "rf")
  vim.cmd.cd(proj)
  local s = capture.current_store()
  eq(s.root, proj)
  ui.recover(s)
  local list = assert(ui._current)
  local lines = vim.api.nvim_buf_get_lines(list.buf, 0, -1, false)
  eq(#lines, 1)
  eq(lines[1]:match("src/gone.lua"), "src/gone.lua")
  list.actions.restore(1)
  eq(H.read(f), "keep me\n")
  eq(vim.api.nvim_buf_get_name(0), f)
  eq(ui._current, nil)
end

T["recover with nothing deleted only notifies"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "x\n")
  edit(f)
  ui.recover(capture.current_store())
  eq(ui._current, nil)
end

T["current_store falls back to the cwd project"] = function()
  vim.cmd("enew")
  vim.cmd.cd(proj)
  eq(capture.current_store().root, proj)
end

return T
