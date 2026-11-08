# strata.nvim

Local history for Neovim. A safety net for work that is not committed yet.

Early: v0.1. Tested on Neovim 0.12.

Persistent undo stops helping the moment a file changes outside Neovim. A
`git checkout`, a `git reset --hard`, a formatter run from the shell, or an
agent rewriting four files at once, and the undo file is thrown away because
the on-disk hash no longer matches. Deleted files have no undo at all.

strata keeps a copy of every file I open or save, outside the project, and
lets me get it back.

The idea is JetBrains Local History. The name is mine: layers of sediment,
newest on top.

## What it does

- Snapshots on open, on save, right before an external change gets
  overwritten, and for unsaved buffers on focus loss and exit.
- `:Strata` shows the history of the current file. Diff any point against
  the buffer, or restore it. `u` undoes the restore.
- `:Strata recover` brings back deleted files.
- `:Strata project` rolls a folder back to an earlier moment. Labels I set
  by hand and labels added for every git checkout or reset mark the points.
  With [quilt.nvim](https://github.com/rashedInt32/quilt.nvim) installed,
  `Q` opens every changed range in one buffer.
- Zero idle cost. No timers, no polling. One hash per save.
- Secrets never enter the store. `.env*`, keys, certificates and credential
  files are excluded by default, and the store directory is mode 0700.

## Install

lazy.nvim:

```lua
{ "rashedInt32/strata.nvim", opts = {} }
```

`setup()` is optional. Without it the defaults apply.

## Commands

| command                 | what                                              |
|-------------------------|---------------------------------------------------|
| `:Strata`               | history of the current file                       |
| `:Strata recover`       | deleted files with a snapshot                     |
| `:Strata project`       | timeline, then files changed since a point        |
| `:Strata label {text}`  | mark now                                          |
| `:Strata snapshot`      | snapshot the buffer by hand                       |
| `:Strata prune`         | apply retention now                               |

Keys in the lists: `<CR>` diff or drill in, `o` open the snapshot, `r`
restore, `R` restore all (changes list), `Q` quilt (changes list), `q` close.

## Configuration

```lua
require("strata").setup({
  dir = vim.fn.stdpath("state") .. "/strata",
  root_markers = { ".git" },
  exclude = {},            -- globs added to the defaults
  max_size = 1024 * 1024,  -- bytes; larger files are skipped
  on_focus_lost = true,
  git_labels = true,       -- label checkouts and resets, no git process
  keep_days = 30,
  max_per_file = 100,
  keys = { diff = "<CR>", restore = "r", restore_all = "R", open = "o", quilt = "Q", close = "q" },
})
```

`:help strata` has the rest: events, storage format, retention, limits.

## How it works

One store per project under `stdpath("state")/strata`. File contents are
saved once by sha256 in `objects/`, and an append-only `log.jsonl` records
time, event, path and hash. Several Neovim instances can write to the same
store. Pruning drops old entries and unreferenced objects, but the latest
snapshot of every path always stays so deleted files remain recoverable.

A restore refuses any target that resolves outside the project, through
`..` or a symlink. It writes the exact snapshot with `noautocmd`, so
format-on-save does not alter it.

## Limits

- Only files Neovim has opened or saved are tracked. A file an agent created
  and nobody opened has no history.
- `FocusLost` needs a terminal that sends focus events.
- Restoring a moment never deletes files added since.
- Objects are not compressed.

## Development

```sh
make test   # mini.test, clones mini.nvim into deps/ on first run
make lint   # stylua --check + luacheck
```

MIT.
