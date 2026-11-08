-- Labels: marks set by hand, and marks added when git moves HEAD or writes
-- ORIG_HEAD. One fs_event per project on its git dir; a one-shot 200 ms
-- timer coalesces bursts. Nothing runs between events.
local store = require("strata.store")
local uv = vim.uv
local M = {}

---@class strata.Watch
---@field handle uv.uv_fs_event_t
---@field timer uv.uv_timer_t?
---@field head string? last resolved commit
---@field gitdir string

local watches = {} ---@type table<string, strata.Watch> root -> watch

---@param s strata.Store
---@param text string
---@return strata.Entry?
function M.add(s, text)
  text = vim.trim(text)
  if text == "" then
    return nil
  end
  return s:label(text)
end

--- Git dir for a root: `.git` itself, or the path named in a `.git` file (worktrees).
---@param root string
---@return string?
function M.gitdir(root)
  local dot = vim.fs.joinpath(root, ".git")
  local st = uv.fs_stat(dot)
  if not st then
    return nil
  end
  if st.type == "directory" then
    return dot
  end
  local data = store._read_file(dot) or ""
  local target = data:match("^gitdir:%s*(.-)%s*$")
  if not target then
    return nil
  end
  if target:sub(1, 1) ~= "/" then
    target = vim.fs.normalize(vim.fs.joinpath(root, target))
  end
  return uv.fs_stat(target) and target or nil
end

--- Branch name and commit for HEAD, from files only.
---@param gitdir string
---@return string? branch, string? sha
function M.resolve_head(gitdir)
  local head = store._read_file(vim.fs.joinpath(gitdir, "HEAD"))
  if not head then
    return nil
  end
  head = head:gsub("%s+$", "")
  local ref = head:match("^ref:%s*(.+)$")
  if not ref then
    return nil, head:match("^%x+$") and head or nil
  end
  local branch = ref:gsub("^refs/heads/", "")
  local sha = store._read_file(vim.fs.joinpath(gitdir, ref))
  if sha then
    return branch, (sha:gsub("%s+$", ""))
  end
  -- worktrees keep refs in the common dir
  local common = store._read_file(vim.fs.joinpath(gitdir, "commondir"))
  local dirs = { gitdir }
  if common then
    common = common:gsub("%s+$", "")
    dirs[#dirs + 1] = common:sub(1, 1) == "/" and common or vim.fs.normalize(vim.fs.joinpath(gitdir, common))
  end
  for _, d in ipairs(dirs) do
    local loose = store._read_file(vim.fs.joinpath(d, ref))
    if loose then
      return branch, (loose:gsub("%s+$", ""))
    end
    local packed = store._read_file(vim.fs.joinpath(d, "packed-refs"))
    if packed then
      for line in packed:gmatch("[^\n]+") do
        local psha, pref = line:match("^(%x+) (.+)$")
        if pref == ref then
          return branch, psha
        end
      end
    end
  end
  return branch, nil
end

local function short(sha)
  return sha and sha:sub(1, 7) or "?"
end

---@param s strata.Store
---@param w strata.Watch
---@param orig boolean ORIG_HEAD changed
local function check(s, w, orig)
  local branch, sha = M.resolve_head(w.gitdir)
  local where = branch and ("%s @%s"):format(branch, short(sha)) or ("@" .. short(sha))
  if sha and w.head and sha ~= w.head then
    s:label("git: checkout " .. where)
  elseif orig then
    s:label("git: reset/merge/rebase " .. where)
  end
  w.head = sha or w.head
end

--- Watch the project's git dir and label HEAD moves. Idempotent per root.
---@param s strata.Store
---@return boolean watching
function M.watch(s)
  if watches[s.root] then
    return true
  end
  local gitdir = M.gitdir(s.root)
  if not gitdir then
    return false
  end
  local handle = uv.new_fs_event()
  if not handle then
    return false
  end
  local w = { handle = handle, gitdir = gitdir }
  local _, sha = M.resolve_head(gitdir)
  w.head = sha
  local pending_orig = false
  local ok = handle:start(gitdir, {}, function(err, filename)
    if err then
      return
    end
    if filename ~= "HEAD" and filename ~= "ORIG_HEAD" then
      return
    end
    pending_orig = pending_orig or filename == "ORIG_HEAD"
    if w.timer then
      return
    end
    w.timer = uv.new_timer()
    w.timer:start(200, 0, function()
      w.timer:close()
      w.timer = nil
      local orig = pending_orig
      pending_orig = false
      vim.schedule(function()
        check(s, w, orig)
      end)
    end)
  end)
  if not ok then
    handle:close()
    return false
  end
  watches[s.root] = w
  return true
end

function M.unwatch_all()
  for root, w in pairs(watches) do
    if w.timer then
      w.timer:close()
    end
    w.handle:stop()
    w.handle:close()
    watches[root] = nil
  end
end

return M
