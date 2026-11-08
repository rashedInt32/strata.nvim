-- Queries over a store's log. Pure functions apart from disk reads.
local store = require("strata.store")
local M = {}

--- Snapshot and label entries that concern one file, newest first.
--- Labels are included so the file view shows where checkouts and marks fall.
---@param s strata.Store
---@param rel string
---@return strata.Entry[]
function M.file(s, rel)
  local out = {}
  local es = s:entries()
  local seen_snapshot = false
  for i = #es, 1, -1 do
    local e = es[i]
    if e.p == rel then
      out[#out + 1] = e
      seen_snapshot = true
    elseif e.e == "label" and seen_snapshot then
      out[#out + 1] = e
    end
  end
  -- drop trailing labels older than the first snapshot
  while #out > 0 and out[#out].e == "label" do
    out[#out] = nil
  end
  return out
end

---@param s strata.Store
---@return strata.Entry[]
function M.labels(s)
  return vim.tbl_filter(function(e)
    return e.e == "label"
  end, s:entries())
end

--- Latest entry per path, over the whole log or up to time `t`.
---@param s strata.Store
---@param t integer?
---@return table<string, strata.Entry>
function M.state_at(s, t)
  local state = {}
  for _, e in ipairs(s:entries()) do
    if e.p and (not t or e.t <= t) then
      state[e.p] = e
    end
  end
  return state
end

---@param abs string
---@return string? hash nil when the file is missing
local function disk_hash(abs)
  local data = store._read_file(abs)
  return data and store.hash(data) or nil
end

--- Tracked paths that no longer exist on disk, with their latest entry.
---@param s strata.Store
---@return { p: string, entry: strata.Entry }[] newest first
function M.deleted(s)
  local out = {}
  for rel, e in pairs(M.state_at(s)) do
    if not vim.uv.fs_stat(vim.fs.joinpath(s.root, rel)) then
      out[#out + 1] = { p = rel, entry = e }
    end
  end
  table.sort(out, function(a, b)
    return a.entry.t > b.entry.t
  end)
  return out
end

---@class strata.Change
---@field p string
---@field was strata.Entry? state at the chosen time; nil when the file did not exist in the log yet
---@field now string? current disk hash; nil when the file is missing
---@field kind "modified"|"deleted"|"added"

--- Files whose state at `t` differs from the disk now.
---@param s strata.Store
---@param t integer
---@return strata.Change[] sorted by path
function M.changed_since(s, t)
  local then_ = M.state_at(s, t)
  local now = M.state_at(s)
  local out = {}
  for rel in pairs(now) do
    local was = then_[rel]
    local cur = disk_hash(vim.fs.joinpath(s.root, rel))
    if not was then
      if cur then
        out[#out + 1] = { p = rel, was = nil, now = cur, kind = "added" }
      end
    elseif not cur then
      out[#out + 1] = { p = rel, was = was, now = nil, kind = "deleted" }
    elseif was.h ~= cur then
      out[#out + 1] = { p = rel, was = was, now = cur, kind = "modified" }
    end
  end
  table.sort(out, function(a, b)
    return a.p < b.p
  end)
  return out
end

---@class strata.Point
---@field t integer
---@field kind "label"|"snap"
---@field text string? label text
---@field count integer? files in the group
---@field paths string[]?

--- Labels and per-minute snapshot groups, newest first.
---@param s strata.Store
---@return strata.Point[]
function M.timeline(s)
  local points = {}
  local group ---@type strata.Point?
  local seen ---@type table<string, boolean>
  for _, e in ipairs(s:entries()) do
    if e.e == "label" then
      group = nil
      points[#points + 1] = { t = e.t, kind = "label", text = e.l }
    elseif e.p then
      if not group or math.floor(e.t / 60) ~= math.floor(group.t / 60) then
        group = { t = e.t, kind = "snap", count = 0, paths = {} }
        seen = {}
        points[#points + 1] = group
      end
      group.t = e.t
      if not seen[e.p] then
        seen[e.p] = true
        group.count = group.count + 1
        group.paths[#group.paths + 1] = e.p
      end
    end
  end
  local out = {}
  for i = #points, 1, -1 do
    out[#out + 1] = points[i]
  end
  return out
end

return M
