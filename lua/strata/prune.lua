-- Retention. The latest snapshot of every path is always kept so deleted
-- files stay recoverable; everything else obeys keep_days and max_per_file.
local M = {}

---@param entries strata.Entry[] log order
---@param cfg strata.Config
---@param now integer
---@return strata.Entry[] kept, in log order
function M.plan(entries, cfg, now)
  local cutoff = now - cfg.keep_days * 86400
  local latest = {}
  for _, e in ipairs(entries) do
    if e.p then
      latest[e.p] = e
    end
  end
  local count = {}
  local kept = {}
  for i = #entries, 1, -1 do
    local e = entries[i]
    local keep
    if e.p then
      count[e.p] = (count[e.p] or 0) + 1
      keep = latest[e.p] == e or (e.t >= cutoff and count[e.p] <= cfg.max_per_file)
    else
      keep = e.t >= cutoff
    end
    if keep then
      kept[#kept + 1] = e
    end
  end
  local out = {}
  for i = #kept, 1, -1 do
    out[#out + 1] = kept[i]
  end
  return out
end

--- Prune one store. Returns how many entries were dropped.
---@param s strata.Store
---@param cfg strata.Config
---@param now integer?
---@return integer
function M.run(s, cfg, now)
  local entries = s:entries()
  local kept = M.plan(entries, cfg, now or os.time())
  local dropped = #entries - #kept
  if dropped > 0 then
    s:rewrite(kept)
  end
  return dropped
end

--- Prune every store under the base dir.
---@param cfg strata.Config
---@return integer stores, integer dropped
function M.run_all(cfg)
  local stores = require("strata.store").all(cfg.dir)
  local total = 0
  for _, s in ipairs(stores) do
    total = total + M.run(s, cfg)
  end
  return #stores, total
end

return M
