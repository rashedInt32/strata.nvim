if vim.g.loaded_strata then
  return
end
vim.g.loaded_strata = true

vim.api.nvim_create_user_command("Strata", function(a)
  require("strata").command(a.fargs)
end, {
  nargs = "*",
  complete = function()
    return require("strata").complete()
  end,
  desc = "strata: local history",
})

-- Capture works without an explicit setup(); setup() later re-attaches with options.
require("strata").setup()
