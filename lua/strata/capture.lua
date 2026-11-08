-- Capture: which files qualify, which store they belong to, and the autocmds
-- that take snapshots. Everything here is event driven; nothing runs idle.
local store = require("strata.store")
local M = {}

---@type strata.Config
local cfg
local compiled ---@type table[]?
local stores = {} ---@type table<string, strata.Store>
local listeners = {} ---@type fun(s: strata.Store, e: strata.Entry)[]

---@param c strata.Config
function M.setup(c)
  cfg = c
  compiled = nil
  stores = {}
end

function M.config()
  return cfg
end

--- Called after every stored snapshot.
---@param fn fun(s: strata.Store, e: strata.Entry)
function M.on_snapshot(fn)
  listeners[#listeners + 1] = fn
end

local function globs()
  if not compiled then
    compiled = {}
    for _, g in ipairs(cfg.exclude) do
      compiled[#compiled + 1] = vim.glob.to_lpeg(g)
    end
  end
  return compiled
end

---@param abs string absolute, normalized path
---@return boolean
function M.excluded(abs)
  for _, p in ipairs(globs()) do
    if p:match(abs) then
      return true
    end
  end
  return false
end

---@param abs string
---@return string
function M.root_of(abs)
  return vim.fs.root(abs, cfg.root_markers) or vim.fs.dirname(abs)
end

---@param root string
---@return strata.Store?
function M.store_for(root)
  local s = stores[root]
  if not s then
    s = store.open(cfg.dir, root)
    stores[root] = s
  end
  return s
end

--- Store and relative path for an absolute file path.
---@param abs string
---@return strata.Store? store, string? rel
function M.locate(abs)
  local root = M.root_of(abs)
  local s = M.store_for(root)
  if not s then
    return nil
  end
  local rel = abs:sub(#root + 2)
  if abs:sub(1, #root + 1) ~= root .. "/" or rel == "" then
    return nil
  end
  return s, rel
end

---@param buf integer
---@return string? abs normalized absolute path, nil when the buffer is not a plain file
function M.path_of(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%w+://") then
    return nil
  end
  local abs = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  if abs:sub(1, 1) ~= "/" or M.excluded(abs) then
    return nil
  end
  return abs
end

---@param content string
---@return boolean
function M.acceptable(content)
  return #content <= cfg.max_size and not content:find("\0", 1, true)
end

---@param buf integer
---@return string
function M.buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if vim.bo[buf].endofline or vim.bo[buf].fixendofline then
    text = text .. "\n"
  end
  return text
end

local function emit(s, e)
  for _, fn in ipairs(listeners) do
    fn(s, e)
  end
end

--- Snapshot a file's content. Returns the entry, or nil when skipped.
---@param abs string
---@param content string
---@param event string
---@return strata.Entry?
function M.record(abs, content, event)
  if not M.acceptable(content) then
    return nil
  end
  local s, rel = M.locate(abs)
  if not s then
    return nil
  end
  local e = s:snapshot(rel, content, event)
  if e then
    emit(s, e)
  end
  return e
end

--- Snapshot a buffer: from disk for open/save/external, from the buffer otherwise.
---@param buf integer
---@param event string
---@return strata.Entry?
function M.snapshot(buf, event)
  local abs = M.path_of(buf)
  if not abs then
    return nil
  end
  local content
  if event == "open" or event == "save" or event == "external" then
    content = store._read_file(abs)
  else
    content = M.buffer_text(buf)
  end
  if not content then
    return nil
  end
  return M.record(abs, content, event)
end

--- Before a write: if the disk copy differs from what we last saw, keep it.
---@param buf integer
---@return strata.Entry?
function M.before_write(buf)
  local abs = M.path_of(buf)
  if not abs then
    return nil
  end
  local disk = store._read_file(abs)
  if not disk or not M.acceptable(disk) then
    return nil
  end
  local s, rel = M.locate(abs)
  if not s then
    return nil
  end
  local last = s:latest(rel)
  local event = last and "external" or "open"
  local e = s:snapshot(rel, disk, event)
  if e then
    emit(s, e)
  end
  return e
end

--- Snapshot every modified plain buffer as `unsaved`.
---@return integer count
function M.snapshot_modified()
  local n = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and M.snapshot(buf, "unsaved") then
      n = n + 1
    end
  end
  return n
end

function M.attach()
  local group = vim.api.nvim_create_augroup("strata", { clear = true })
  local au = function(event, cb, desc)
    vim.api.nvim_create_autocmd(event, { group = group, callback = cb, desc = "strata: " .. desc })
  end
  au("BufReadPost", function(a)
    M.snapshot(a.buf, "open")
  end, "baseline on open")
  au("BufWritePre", function(a)
    M.before_write(a.buf)
  end, "keep an external change before overwriting it")
  au("BufWritePost", function(a)
    M.snapshot(a.buf, "save")
  end, "snapshot on save")
  au("FileChangedShell", function(a)
    if vim.bo[a.buf].modified then
      M.snapshot(a.buf, "unsaved")
    end
  end, "keep unsaved text when the file changed outside")
  au("VimLeavePre", function()
    M.snapshot_modified()
  end, "keep unsaved text on exit")
  if cfg.on_focus_lost then
    au("FocusLost", function()
      M.snapshot_modified()
    end, "keep unsaved text on focus loss")
  end
end

return M
