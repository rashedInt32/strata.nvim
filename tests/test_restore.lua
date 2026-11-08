-- Restore safety and behaviour, plus the file history float.
local H = require("tests.helpers")
local capture = require("strata.capture")
local config = require("strata.config")
local restore = require("strata.restore")
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

T["safe_target refuses escapes"] = function()
  eq(restore.safe_target(proj, "src/a.lua"), proj .. "/src/a.lua")
  eq(restore.safe_target(proj, "deep/new/dir/a.lua"), proj .. "/deep/new/dir/a.lua")
  for _, bad in ipairs({ "", "/etc/passwd", "../x", "a/../../x", "a/..", "a\0b" }) do
    local abs, err = restore.safe_target(proj, bad)
    eq(abs, nil, bad)
    eq(type(err), "string")
  end
end

T["safe_target refuses a symlink that points outside"] = function()
  vim.fn.mkdir(tmp .. "/outside", "p")
  vim.uv.fs_symlink(tmp .. "/outside", proj .. "/link")
  local abs, err = restore.safe_target(proj, "link/a.lua")
  eq(abs, nil)
  eq(err, "path resolves outside the project")
  vim.fn.mkdir(proj .. "/inside", "p")
  vim.uv.fs_symlink(proj .. "/inside", proj .. "/inlink")
  eq(restore.safe_target(proj, "inlink/a.lua"), proj .. "/inlink/a.lua")
end

T["restore into a loaded buffer is undoable and keeps the current text first"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "one\n")
  local buf = edit(f)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "two" })
  vim.cmd("silent write")
  local s, rel = capture.locate(f)
  local first = s:entries()[1]
  eq(restore.apply(s, rel, s:get(first.h)), true)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one" })
  eq(H.read(f), "one\n")
  local events = vim.tbl_map(function(e)
    return e.e
  end, s:entries())
  eq(events, { "open", "save", "restore" })
  eq(s:get(s:entries()[3].h), "one\n")
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent undo")
  end)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "two" })
end

T["restore keeps unsaved buffer text before overwriting it"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "one\n")
  local buf = edit(f)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "draft" })
  local s, rel = capture.locate(f)
  eq(restore.apply(s, rel, "one\n"), true)
  local events = vim.tbl_map(function(e)
    return e.e .. ":" .. s:get(e.h)
  end, s:entries())
  eq(events, { "open:one\n", "unsaved:draft\n", "restore:one\n" })
  eq(vim.bo[buf].modified, false)
end

T["restore to disk recreates a deleted file and its directory"] = function()
  local f = proj .. "/src/gone.lua"
  H.write(f, "keep me\n")
  edit(f)
  vim.cmd("silent! %bwipeout!")
  vim.fn.delete(proj .. "/src", "rf")
  local s, rel = capture.locate(f)
  eq(restore.apply(s, rel, "keep me\n"), true)
  eq(H.read(f), "keep me\n")
end

T["restore refuses when the path is unsafe"] = function()
  local s = capture.store_for(proj)
  local ok, err = restore.apply(s, "../evil.lua", "x\n")
  eq(ok, false)
  eq(err, "path escapes the project")
  eq(vim.uv.fs_stat(tmp .. "/evil.lua"), nil)
end

T["file history float lists snapshots newest first and diffs on pick"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "one\n")
  local buf = edit(f)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "two" })
  vim.cmd("silent write")
  ui.file_history()
  local list = assert(ui._current)
  local lines = vim.api.nvim_buf_get_lines(list.buf, 0, -1, false)
  eq(#lines, 2)
  eq(lines[1]:match("save"), "save")
  eq(lines[2]:match("open"), "open")
  list.actions.diff(2)
  eq(ui._current, nil)
  local diff_wins = vim.tbl_filter(function(w)
    return vim.wo[w].diff
  end, vim.api.nvim_list_wins())
  eq(#diff_wins, 2)
  local snap = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_buf_get_lines(snap, 0, -1, false), { "one" })
  eq(vim.bo[snap].filetype, "lua")
end

T["file history restore action rewrites the buffer"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "one\n")
  local buf = edit(f)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "two" })
  vim.cmd("silent write")
  ui.file_history()
  ui._current.actions.restore(2)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one" })
  eq(ui._current, nil)
end

T["file history on an excluded or special buffer just notifies"] = function()
  vim.cmd("enew")
  ui.file_history()
  eq(ui._current, nil)
end

return T
