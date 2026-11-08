-- strata.nvim: local history for Neovim.
local M = {}

---@type strata.Config
M.config = require("strata.config").resolve()

---@param opts table?
function M.setup(opts)
  M.config = require("strata.config").resolve(opts)
  local capture = require("strata.capture")
  capture.setup(M.config)
  capture.attach()
end

--- Snapshot the current buffer by hand.
---@return strata.Entry?
function M.snapshot()
  local e = require("strata.capture").snapshot(vim.api.nvim_get_current_buf(), "manual")
  vim.notify(e and "strata: snapshot taken" or "strata: nothing new to snapshot", vim.log.levels.INFO)
  return e
end

local subcommands = {
  snapshot = function()
    M.snapshot()
  end,
}

---@param fargs string[]
function M.command(fargs)
  local name = fargs[1] or ""
  local fn = subcommands[name]
  if not fn then
    vim.notify("strata: unknown subcommand " .. name, vim.log.levels.ERROR)
    return
  end
  fn(vim.list_slice(fargs, 2))
end

---@return string[]
function M.complete()
  return vim.tbl_keys(subcommands)
end

return M
