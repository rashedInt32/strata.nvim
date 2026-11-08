-- Restore snapshot content to a file. The only code path that writes into a
-- project, so it is the only one that needs the path checks.
local store = require("strata.store")
local capture = require("strata.capture")
local uv = vim.uv
local M = {}

--- Deepest existing ancestor of `abs` (or `abs` itself), resolved.
---@param abs string
---@return string?
local function resolved_anchor(abs)
  local p = abs
  while p and p ~= "/" do
    local real = uv.fs_realpath(p)
    if real then
      return real
    end
    p = vim.fs.dirname(p)
  end
  return uv.fs_realpath("/")
end

--- Absolute target for `rel` under `root`, or nil and a reason when it would
--- land outside the project (dot-dot, absolute, symlink escape).
---@param root string
---@param rel string
---@return string? abs, string? err
function M.safe_target(root, rel)
  if rel == "" or rel:sub(1, 1) == "/" or rel:find("\0", 1, true) then
    return nil, "invalid path"
  end
  for seg in rel:gmatch("[^/]+") do
    if seg == ".." then
      return nil, "path escapes the project"
    end
  end
  local real_root = uv.fs_realpath(root)
  if not real_root then
    return nil, "project root is gone"
  end
  local abs = vim.fs.joinpath(root, rel)
  local anchor = resolved_anchor(abs)
  if not anchor or (anchor ~= real_root and anchor:sub(1, #real_root + 1) ~= real_root .. "/") then
    return nil, "path resolves outside the project"
  end
  return abs
end

---@param abs string
---@return integer? buf loaded buffer for this file
local function loaded_buffer(abs)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fs.normalize(vim.fn.fnamemodify(name, ":p")) == abs then
        return buf
      end
    end
  end
  return nil
end

---@param content string
---@return string[] lines, boolean eol
local function split(content)
  local eol = content:sub(-1) == "\n"
  if eol then
    content = content:sub(1, -2)
  end
  return vim.split(content, "\n", { plain = true }), eol
end

--- Put `content` at `rel`. Keeps the current content first so the restore is
--- reversible. Goes through the buffer when one is loaded, so `u` undoes it.
---@param s strata.Store
---@param rel string
---@param content string
---@return boolean ok, string? err
function M.apply(s, rel, content)
  local abs, err = M.safe_target(s.root, rel)
  if not abs then
    return false, err
  end
  local buf = loaded_buffer(abs)
  local current = buf and capture.buffer_text(buf) or store._read_file(abs)
  -- Unsaved text would be lost; saved text is already in the log and dedups away.
  if current then
    capture.record(abs, current, "unsaved")
  end
  if buf then
    local lines, eol = split(content)
    -- close the current undo block so `u` undoes exactly the restore
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("let &l:undolevels = &l:undolevels")
    end)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].endofline = eol
    -- noautocmd: a restore writes the exact snapshot, no format-on-save
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent noautocmd keepalt write!")
    end)
    capture.record(abs, content, "restore")
    return true
  end
  local parent = vim.fs.dirname(abs)
  if not uv.fs_stat(parent) then
    vim.fn.mkdir(parent, "p")
  end
  if not store._write_file(abs, content, 420) then -- 0644
    return false, "write failed"
  end
  capture.record(abs, content, "restore")
  return true
end

return M
