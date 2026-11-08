-- Retention planning and execution.
local H = require("tests.helpers")
local store = require("strata.store")
local config = require("strata.config")
local prune = require("strata.prune")
local eq = MiniTest.expect.equality

local DAY = 86400
local tmp, s

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      tmp = H.tmpdir()
      s = assert(store.open(tmp .. "/store", tmp .. "/proj"))
    end,
    post_case = function()
      H.rm(tmp)
    end,
  },
})

local function ids(entries)
  return vim.tbl_map(function(e)
    return e.l or (e.p .. "@" .. e.t)
  end, entries)
end

T["old entries go, the latest per path stays"] = function()
  local now = 100 * DAY
  local cfg = config.resolve({ keep_days = 30 })
  local entries = {
    { t = now - 50 * DAY, e = "save", p = "old.lua", h = "1" },
    { t = now - 40 * DAY, e = "label", l = "ancient" },
    { t = now - 35 * DAY, e = "save", p = "a.lua", h = "2" },
    { t = now - 10 * DAY, e = "label", l = "recent" },
    { t = now - 5 * DAY, e = "save", p = "a.lua", h = "3" },
  }
  eq(ids(prune.plan(entries, cfg, now)), { "old.lua@" .. (now - 50 * DAY), "recent", "a.lua@" .. (now - 5 * DAY) })
end

T["max_per_file keeps the newest ones"] = function()
  local now = 100 * DAY
  local cfg = config.resolve({ keep_days = 365, max_per_file = 2 })
  local entries = {}
  for i = 1, 5 do
    entries[i] = { t = now - (10 - i), e = "save", p = "a.lua", h = tostring(i) }
  end
  entries[6] = { t = now - 1, e = "save", p = "b.lua", h = "b" }
  eq(ids(prune.plan(entries, cfg, now)), { "a.lua@" .. (now - 6), "a.lua@" .. (now - 5), "b.lua@" .. (now - 1) })
end

T["run rewrites the log and drops orphaned objects"] = function()
  local now = 100 * DAY
  local cfg = config.resolve({ keep_days = 30 })
  local e1 = s:snapshot("a.lua", "old\n", "save", now - 60 * DAY)
  local e2 = s:snapshot("a.lua", "new\n", "save", now - 1)
  eq(prune.run(s, cfg, now), 1)
  eq(#s:entries(), 1)
  eq(s:get(e1.h), nil)
  eq(s:get(e2.h), "new\n")
  eq(prune.run(s, cfg, now), 0)
end

T["run_all covers every store under the base"] = function()
  local now = 100 * DAY
  local cfg = config.resolve({ dir = tmp .. "/store", keep_days = 30 })
  s:snapshot("a.lua", "old\n", "save", now - 60 * DAY)
  s:snapshot("a.lua", "new\n", "save", now - 1)
  local s2 = assert(store.open(tmp .. "/store", tmp .. "/other"))
  s2:snapshot("z.lua", "z\n", "save", now - 1)
  -- run_all uses os.time(); the seeded times are far in the past relative to it,
  -- so only the latest per path survives in each store
  local stores, dropped = prune.run_all(cfg)
  eq(stores, 2)
  eq(dropped, 1)
end

return T
