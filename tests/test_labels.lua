-- Labels by hand and from git HEAD moves.
local H = require("tests.helpers")
local store = require("strata.store")
local labels = require("strata.labels")
local eq = MiniTest.expect.equality

local tmp, proj, s
local SHA_A = ("a"):rep(40)
local SHA_B = ("b"):rep(40)

local function git_init(dir, branch, sha)
  H.write(dir .. "/.git/HEAD", "ref: refs/heads/" .. branch .. "\n")
  H.write(dir .. "/.git/refs/heads/" .. branch, sha .. "\n")
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      tmp = H.tmpdir()
      proj = tmp .. "/proj"
      vim.fn.mkdir(proj, "p")
      s = assert(store.open(tmp .. "/store", proj))
    end,
    post_case = function()
      labels.unwatch_all()
      H.rm(tmp)
    end,
  },
})

T["add trims and refuses empty text"] = function()
  eq(labels.add(s, "  before refactor "), s:entries()[1])
  eq(s:entries()[1].l, "before refactor")
  eq(labels.add(s, "   "), nil)
  eq(#s:entries(), 1)
end

T["gitdir handles a directory and a worktree file"] = function()
  eq(labels.gitdir(proj), nil)
  git_init(proj, "main", SHA_A)
  eq(labels.gitdir(proj), proj .. "/.git")
  local wt = tmp .. "/wt"
  vim.fn.mkdir(wt, "p")
  vim.fn.mkdir(proj .. "/.git/worktrees/wt", "p")
  H.write(wt .. "/.git", "gitdir: " .. proj .. "/.git/worktrees/wt\n")
  eq(labels.gitdir(wt), proj .. "/.git/worktrees/wt")
end

T["resolve_head reads loose, packed and detached refs"] = function()
  git_init(proj, "main", SHA_A)
  eq({ labels.resolve_head(proj .. "/.git") }, { "main", SHA_A })
  vim.fn.delete(proj .. "/.git/refs/heads/main")
  H.write(proj .. "/.git/packed-refs", "# pack-refs\n" .. SHA_B .. " refs/heads/main\n")
  eq({ labels.resolve_head(proj .. "/.git") }, { "main", SHA_B })
  H.write(proj .. "/.git/HEAD", SHA_A .. "\n")
  eq({ labels.resolve_head(proj .. "/.git") }, { nil, SHA_A })
end

T["watch labels a HEAD move and an ORIG_HEAD write"] = function()
  git_init(proj, "main", SHA_A)
  H.write(proj .. "/.git/refs/heads/feature", SHA_B .. "\n")
  eq(labels.watch(s), true)
  eq(labels.watch(s), true)
  H.write(proj .. "/.git/HEAD", "ref: refs/heads/feature\n")
  eq(
    vim.wait(3000, function()
      return #s:entries() >= 1
    end),
    true
  )
  eq(s:entries()[1].l, "git: checkout feature @bbbbbbb")
  H.write(proj .. "/.git/ORIG_HEAD", SHA_A .. "\n")
  eq(
    vim.wait(3000, function()
      return #s:entries() >= 2
    end),
    true
  )
  eq(s:entries()[2].l, "git: reset/merge/rebase feature @bbbbbbb")
end

T["watch returns false without a git dir"] = function()
  eq(labels.watch(s), false)
end

return T
