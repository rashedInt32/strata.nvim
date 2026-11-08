-- Defaults and option resolution.
local M = {}

---@class strata.Config
---@field dir string base directory of all stores
---@field root_markers string[] passed to vim.fs.root
---@field exclude string[] globs (vim.glob) matched against the absolute path; matching files are never stored
---@field max_size integer bytes; larger files are skipped
---@field on_focus_lost boolean snapshot modified buffers on FocusLost
---@field git_labels boolean label git checkouts and resets
---@field keep_days integer prune entries older than this
---@field max_per_file integer prune entries beyond this count per path
---@field keys table<string, string>

M.defaults = {
  dir = vim.fn.stdpath("state") .. "/strata",
  root_markers = { ".git" },
  exclude = {
    -- secrets: these must never enter the store
    "**/.env",
    "**/.env.*",
    "**/*.pem",
    "**/*.key",
    "**/*.p12",
    "**/*.pfx",
    "**/*.jks",
    "**/*.keystore",
    "**/id_rsa*",
    "**/id_ecdsa*",
    "**/id_ed25519*",
    "**/*.secret",
    "**/*secrets*",
    "**/*credentials*",
    "**/.netrc",
    "**/.npmrc",
    "**/.pypirc",
    "**/.aws/**",
    "**/.ssh/**",
    "**/.gnupg/**",
    -- noise
    "**/.git/**",
    "**/node_modules/**",
    "**/dist/**",
    "**/build/**",
    "**/*.lock",
    "**/package-lock.json",
    "**/pnpm-lock.yaml",
    "**/yarn.lock",
  },
  max_size = 1024 * 1024,
  on_focus_lost = true,
  git_labels = true,
  keep_days = 30,
  max_per_file = 100,
  keys = {
    diff = "<CR>",
    restore = "r",
    restore_all = "R",
    open = "o",
    quilt = "Q",
    close = "q",
  },
}

---@param opts table?
---@return strata.Config
function M.resolve(opts)
  opts = opts or {}
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- `exclude` is additive: user globs join the defaults instead of replacing them.
  if opts.exclude then
    local seen = {}
    local merged = {}
    for _, list in ipairs({ M.defaults.exclude, opts.exclude }) do
      for _, g in ipairs(list) do
        if not seen[g] then
          seen[g] = true
          merged[#merged + 1] = g
        end
      end
    end
    cfg.exclude = merged
  end
  cfg.dir = vim.fs.normalize(vim.fn.fnamemodify(cfg.dir, ":p")):gsub("/+$", "")
  return cfg
end

return M
