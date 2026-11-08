# strata.nvim

Local history for Neovim. A safety net for work that is not committed yet.

Early: v0.1.

Persistent undo stops helping the moment a file changes outside Neovim. A
`git checkout`, a `git reset --hard`, a formatter run from the shell, or an
agent rewriting four files at once, and the undo file is thrown away because
the on-disk hash no longer matches. Deleted files have no undo at all.

strata keeps a copy of every file I open or save, outside the project, and
lets me get it back.

The idea is JetBrains Local History.

## What it does

- Snapshots on open, save, before an external change gets overwritten, and
  for unsaved buffers on focus loss and exit.
- `:Strata` shows the history of the current file: diff any point against
  the buffer, restore it with undo support.
- `:Strata recover` brings back deleted files.
- `:Strata project` rolls a folder back to an earlier moment, with labels I
  set by hand and labels added for every git checkout or reset.
- Zero idle cost: no timers, no polling. One hash per save.
- Secrets never enter the store: `.env*`, keys, certificates and credentials
  are excluded by default.
