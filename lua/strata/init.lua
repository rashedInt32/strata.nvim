-- strata.nvim: local history for Neovim.
local M = {}

---@type strata.Config
M.config = require("strata.config").resolve()

local function notify(msg, level)
  vim.notify("strata: " .. msg, level or vim.log.levels.INFO)
end

---@param opts table?
function M.setup(opts)
  M.config = require("strata.config").resolve(opts)
  local capture = require("strata.capture")
  capture.setup(M.config)
  capture.attach()
  -- First snapshot per store this session: start the git watcher and prune later.
  local seen = {}
  local cfg = M.config
  capture.on_snapshot(function(s)
    if seen[s.root] then
      return
    end
    seen[s.root] = true
    if cfg.git_labels then
      require("strata.labels").watch(s)
    end
    vim.defer_fn(function()
      require("strata.prune").run(s, cfg)
    end, 3000)
  end)
end

--- Snapshot the current buffer by hand.
---@return strata.Entry?
function M.snapshot()
  local e = require("strata.capture").snapshot(vim.api.nvim_get_current_buf(), "manual")
  notify(e and "snapshot taken" or "nothing new to snapshot")
  return e
end

---@param text string
---@return strata.Entry?
function M.label(text)
  local s = require("strata.capture").current_store()
  if not s then
    notify("no store for this project", vim.log.levels.ERROR)
    return nil
  end
  local e = require("strata.labels").add(s, text)
  notify(e and ("label set: " .. e.l) or "label text is empty", e and nil or vim.log.levels.WARN)
  return e
end

local subcommands = {
  [""] = function()
    require("strata.ui").file_history()
  end,
  snapshot = function()
    M.snapshot()
  end,
  label = function(args)
    M.label(table.concat(args, " "))
  end,
  recover = function()
    local s = require("strata.capture").current_store()
    if s then
      require("strata.ui").recover(s)
    end
  end,
  project = function()
    local s = require("strata.capture").current_store()
    if s then
      require("strata.ui").project(s)
    end
  end,
  prune = function()
    local stores, dropped = require("strata.prune").run_all(M.config)
    notify(
      ("pruned %d entr%s across %d store%s"):format(
        dropped,
        dropped == 1 and "y" or "ies",
        stores,
        stores == 1 and "" or "s"
      )
    )
  end,
}

---@param fargs string[]
function M.command(fargs)
  local name = fargs[1] or ""
  local fn = subcommands[name]
  if not fn then
    notify("unknown subcommand " .. name, vim.log.levels.ERROR)
    return
  end
  fn(vim.list_slice(fargs, 2))
end

---@return string[]
function M.complete()
  local names = vim.tbl_filter(function(k)
    return k ~= ""
  end, vim.tbl_keys(subcommands))
  table.sort(names)
  return names
end

return M
