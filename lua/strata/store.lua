-- Content-addressed store, one per project root. Objects are files named by
-- sha256 of their content; the log is append-only JSON lines.
local uv = vim.uv
local M = {}

---@class strata.Entry
---@field t integer unix seconds
---@field e string event: open|save|external|unsaved|manual|restore|label
---@field p string? relative path (snapshot entries)
---@field h string? sha256 (snapshot entries)
---@field s integer? size in bytes (snapshot entries)
---@field l string? label text (label entries)

---@class strata.Store
---@field root string absolute project root
---@field dir string store directory
---@field private _entries strata.Entry[]?
---@field private _size integer
local Store = {}
Store.__index = Store

local function mkdir_p(path, mode)
  if uv.fs_stat(path) then
    return true
  end
  local parent = vim.fs.dirname(path)
  if parent ~= path and not uv.fs_stat(parent) then
    mkdir_p(parent, mode)
  end
  local ok = uv.fs_mkdir(path, mode or 448) -- 0700
  return ok or uv.fs_stat(path) ~= nil
end

local function read_file(path)
  local fd = uv.fs_open(path, "r", 292) -- 0444
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  local data = st and st.size > 0 and uv.fs_read(fd, st.size, 0) or ""
  uv.fs_close(fd)
  return data
end

--- Write atomically: temp file in the same dir, then rename.
local function write_file(path, data, mode)
  local tmp = ("%s.%d.%d.tmp"):format(path, uv.os_getpid(), math.random(1e9))
  local fd = uv.fs_open(tmp, "w", mode or 384) -- 0600
  if not fd then
    return false
  end
  local ok = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(tmp)
    return false
  end
  local renamed = uv.fs_rename(tmp, path)
  if not renamed then
    uv.fs_unlink(tmp)
  end
  return renamed ~= nil
end

M._read_file = read_file
M._write_file = write_file

---@param content string
---@return string
function M.hash(content)
  return vim.fn.sha256(content)
end

--- Store directory for a project root under `base`.
---@param base string
---@param root string
---@return string
function M.dir_for(base, root)
  return vim.fs.joinpath(base, M.hash(root):sub(1, 16))
end

--- Open (creating if needed) the store for `root`.
---@param base string
---@param root string
---@return strata.Store?
function M.open(base, root)
  local dir = M.dir_for(base, root)
  if not mkdir_p(base) or not mkdir_p(vim.fs.joinpath(dir, "objects")) then
    return nil
  end
  local rootfile = vim.fs.joinpath(dir, "root")
  if not uv.fs_stat(rootfile) then
    write_file(rootfile, root .. "\n")
  end
  return setmetatable({ root = root, dir = dir, _entries = nil, _size = -1 }, Store)
end

--- Every store under `base`.
---@param base string
---@return strata.Store[]
function M.all(base)
  local out = {}
  for name, kind in vim.fs.dir(base) do
    if kind == "directory" then
      local root = read_file(vim.fs.joinpath(base, name, "root"))
      if root and root ~= "" then
        root = root:gsub("\n$", "")
        out[#out + 1] =
          setmetatable({ root = root, dir = vim.fs.joinpath(base, name), _entries = nil, _size = -1 }, Store)
      end
    end
  end
  return out
end

function Store:log_path()
  return vim.fs.joinpath(self.dir, "log.jsonl")
end

function Store:object_path(hash)
  return vim.fs.joinpath(self.dir, "objects", hash)
end

--- Save content, return its hash. No-op when the object exists.
---@param content string
---@return string hash
function Store:put(content)
  local h = M.hash(content)
  local path = self:object_path(h)
  if not uv.fs_stat(path) then
    write_file(path, content)
  end
  return h
end

---@param hash string
---@return string?
function Store:get(hash)
  if not hash:match("^%x+$") then
    return nil
  end
  return read_file(self:object_path(hash))
end

--- Append one log entry. Single write with O_APPEND: safe across instances.
---@param entry strata.Entry
---@return boolean
function Store:append(entry)
  local line = vim.json.encode(entry) .. "\n"
  local fd = uv.fs_open(self:log_path(), "a", 384)
  if not fd then
    return false
  end
  local ok = uv.fs_write(fd, line, -1)
  uv.fs_close(fd)
  if ok then
    if self._entries then
      self._entries[#self._entries + 1] = entry
      self._size = self._size + #line
    end
  end
  return ok ~= nil
end

--- All entries in log order. Re-read when another instance grew the log.
---@return strata.Entry[]
function Store:entries()
  local st = uv.fs_stat(self:log_path())
  local size = st and st.size or 0
  if self._entries and size == self._size then
    return self._entries
  end
  local out = {}
  local data = read_file(self:log_path()) or ""
  for line in data:gmatch("[^\n]+") do
    local ok, obj = pcall(vim.json.decode, line)
    if ok and type(obj) == "table" and obj.t and obj.e then
      out[#out + 1] = obj
    end
  end
  self._entries = out
  self._size = size
  return out
end

--- Latest snapshot entry for a relative path.
---@param rel string
---@return strata.Entry?
function Store:latest(rel)
  local es = self:entries()
  for i = #es, 1, -1 do
    if es[i].p == rel then
      return es[i]
    end
  end
  return nil
end

--- Record a snapshot of `content` for `rel` unless it equals the latest one.
---@param rel string
---@param content string
---@param event string
---@param now integer?
---@return strata.Entry? entry nil when skipped as a duplicate
function Store:snapshot(rel, content, event, now)
  local h = M.hash(content)
  local last = self:latest(rel)
  if last and last.h == h then
    return nil
  end
  if not uv.fs_stat(self:object_path(h)) then
    write_file(self:object_path(h), content)
  end
  local entry = { t = now or os.time(), e = event, p = rel, h = h, s = #content }
  if not self:append(entry) then
    return nil
  end
  return entry
end

---@param text string
---@param now integer?
---@return strata.Entry?
function Store:label(text, now)
  local entry = { t = now or os.time(), e = "label", l = text }
  if not self:append(entry) then
    return nil
  end
  return entry
end

--- Rewrite the log with `entries` and delete objects nothing refers to.
---@param entries strata.Entry[]
function Store:rewrite(entries)
  local lines = {}
  local keep = {}
  for _, e in ipairs(entries) do
    lines[#lines + 1] = vim.json.encode(e)
    if e.h then
      keep[e.h] = true
    end
  end
  local data = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
  if not write_file(self:log_path(), data) then
    return false
  end
  self._entries = nil
  self._size = -1
  for name, kind in vim.fs.dir(vim.fs.joinpath(self.dir, "objects")) do
    if kind == "file" and not keep[name] and not name:match("%.tmp$") then
      uv.fs_unlink(self:object_path(name))
    end
  end
  return true
end

M.Store = Store
return M
