-- Capture: roots, excludes, and the snapshot autocmds in a live buffer.
local H = require("tests.helpers")
local capture = require("strata.capture")
local config = require("strata.config")
local eq = MiniTest.expect.equality

local tmp, proj, base

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function entries_for(path)
  local s, rel = capture.locate(vim.fs.normalize(path))
  local out = {}
  for _, e in ipairs(s:entries()) do
    if e.p == rel then
      out[#out + 1] = { e.e, s:get(e.h) }
    end
  end
  return out
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
      vim.cmd("silent! %bwipeout!")
      vim.api.nvim_create_augroup("strata", { clear = true })
      H.rm(tmp)
    end,
  },
})

T["root is the marker dir and paths are relative to it"] = function()
  local f = proj .. "/src/a.lua"
  H.write(f, "x\n")
  local s, rel = capture.locate(f)
  eq(s.root, proj)
  eq(rel, "src/a.lua")
end

T["without a marker the root is the file's directory"] = function()
  local f = tmp .. "/loose/b.lua"
  H.write(f, "x\n")
  local s, rel = capture.locate(f)
  eq(s.root, tmp .. "/loose")
  eq(rel, "b.lua")
end

T["opening a file records a baseline"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "one\n")
  edit(f)
  eq(entries_for(f), { { "open", "one\n" } })
end

T["saving records the new content once"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "one\n")
  local buf = edit(f)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "two" })
  vim.cmd.write()
  vim.cmd.write()
  eq(entries_for(f), { { "open", "one\n" }, { "save", "two\n" } })
end

T["an external change is kept before the buffer overwrites it"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "one\n")
  local buf = edit(f)
  H.write(f, "agent rewrote this\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
  vim.cmd("silent! write!")
  eq(entries_for(f), {
    { "open", "one\n" },
    { "external", "agent rewrote this\n" },
    { "save", "mine\n" },
  })
end

T["unsaved buffer text can be snapshotted from the buffer"] = function()
  local f = proj .. "/a.lua"
  H.write(f, "one\n")
  local buf = edit(f)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "draft" })
  eq(capture.snapshot_modified(), 1)
  eq(entries_for(f)[2], { "unsaved", "draft\n" })
  eq(H.read(f), "one\n")
end

T["secret-looking files never enter the store"] = function()
  for _, name in ipairs({ ".env", ".env.local", "server.key", "cert.pem", "aws-credentials.json", "id_ed25519" }) do
    local f = proj .. "/" .. name
    H.write(f, "SECRET=1\n")
    edit(f)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SECRET=2" })
    vim.cmd("silent! write")
    eq(capture.path_of(0), nil)
  end
  eq(vim.fn.isdirectory(base), 0)
end

T["noise dirs and lockfiles are excluded"] = function()
  for _, rel in ipairs({ "node_modules/x/index.js", "dist/app.js", "package-lock.json", "Cargo.lock" }) do
    eq(capture.excluded(proj .. "/" .. rel), true, rel)
  end
  eq(capture.excluded(proj .. "/src/lock.lua"), false)
end

T["user excludes add to the defaults"] = function()
  capture.setup(config.resolve({ dir = base, exclude = { "**/*.min.js" } }))
  eq(capture.excluded(proj .. "/a.min.js"), true)
  eq(capture.excluded(proj .. "/node_modules/a.js"), true)
end

T["binary and oversized files are skipped"] = function()
  capture.setup(config.resolve({ dir = base, max_size = 10 }))
  local f = proj .. "/a.bin"
  H.write(f, "ab\0cd\n")
  edit(f)
  local g = proj .. "/big.txt"
  H.write(g, ("x"):rep(11) .. "\n")
  edit(g)
  local s = capture.store_for(proj)
  eq(#s:entries(), 0)
end

T["special buffers are ignored"] = function()
  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  vim.api.nvim_buf_set_name(0, proj .. "/scratch.lua")
  eq(capture.path_of(0), nil)
  eq(capture.snapshot(0, "manual"), nil)
end

return T
