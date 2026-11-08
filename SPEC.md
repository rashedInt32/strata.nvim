# strata.nvim — spec

Local history for Neovim. Every file the owner opens or saves gets a snapshot
in a store outside the project. Snapshots survive `git checkout`, `git reset`,
external rewrites (formatters, agents) and file deletion, which persistent undo
does not: Neovim drops an undo file when the on-disk hash no longer matches.

The idea is JetBrains Local History. The name is ours: layers of sediment,
newest on top.

## Non-goals

- Not a VCS. No branches, no remotes, no merge.
- Not a file watcher. Only files Neovim has touched are tracked. Zero idle
  cost is a hard requirement: no timers, no polling.
- Not a diff tool. Diffs use Neovim's `diffthis` or quilt.nvim when present.

## Store

- Base dir: `stdpath("state")/strata`, mode 0700. Config `dir` overrides.
- One store per project root: `<base>/<sha256(root):1..16>/`, holding
  `root` (the absolute root path), `objects/<sha256>` (file contents, content
  addressed, deduplicated) and `log.jsonl` (one JSON object per line).
- Project root: `vim.fs.root(path, root_markers)`; fallback is the file's
  directory. Paths in the log are relative to the root.
- Log entry: `{"t":<unix>,"e":<event>,"p":<relpath>,"h":<sha>,"s":<bytes>}`.
  Label entry: `{"t":<unix>,"e":"label","l":<text>}`.
- Appends are single `O_APPEND` writes, so parallel Neovim instances do not
  corrupt each other. Readers re-read when the log size changes.
- Objects are written to a temp name then renamed. Never rewritten.

## Capture events

| event      | trigger                                   | content          |
|------------|-------------------------------------------|------------------|
| `open`     | `BufReadPost`                             | file on disk     |
| `save`     | `BufWritePost`                            | file on disk     |
| `external` | `BufWritePre`, disk hash ≠ last known     | file on disk     |
| `unsaved`  | `FileChangedShell` on a modified buffer, `FocusLost`, `VimLeavePre` | buffer text |
| `manual`   | `:Strata snapshot`                        | buffer text      |
| `restore`  | taken right before a restore overwrites   | current content  |

A snapshot is skipped when the content hash equals the latest entry for that
path, when `buftype` is not empty, when the file matches an exclude glob, is
larger than `max_size`, or contains a NUL byte.

Default excludes cover secrets (`.env*`, keys, certificates, credentials),
lockfiles, `.git`, `node_modules`, `dist`, `build`. Secrets must never land in
the store; the list is additive by config.

## Labels

- `:Strata label <text>` appends a label entry at now.
- With `git_labels = true` and a `.git` directory at the root, one `fs_event`
  watch on `.git` adds labels when `HEAD` resolves to a different commit or
  `ORIG_HEAD` changes: `git: checkout main @abc1234`, `git: reset/merge`.
  Debounced 200 ms with a one-shot timer. Nothing runs while idle.

## Queries

- File history: entries for a relpath, newest first.
- Deleted: relpaths with at least one entry and no file on disk.
- Timeline: labels plus snapshot groups (per minute), newest first.
- State at T: for each relpath, the latest entry with `t <= T`.
- Changed since T: paths whose state-at-T hash differs from the current disk
  hash (missing on disk counts as changed).

## Restore

- Target must resolve (symlinks followed) to a path strictly under the
  resolved project root. Anything else is refused with a message.
- If the file is loaded in a buffer, lines are set through the API, so `u`
  undoes the restore. Otherwise the file is written to disk.
- The current content is snapshotted as `restore` first, so a restore is
  itself reversible from the history.

## UI

- `:Strata` — history of the current file. `<CR>` diff against the buffer,
  `r` restore, `o` open the snapshot in a scratch buffer, `q` close.
- `:Strata recover` — deleted files. `<CR>` restores the latest snapshot.
- `:Strata project` — timeline. `<CR>` lists files changed since that point:
  `<CR>` diff one, `r` restore one, `R` restore all, `Q` open the changed
  ranges in quilt.nvim when it is installed.
- `:Strata label <text>`, `:Strata snapshot`, `:Strata prune`.

## Retention

- `keep_days` (30) and `max_per_file` (100). Pruning rewrites the log and
  deletes unreferenced objects. Runs once per store per session, deferred
  after the first snapshot, and on `:Strata prune`.

## Verified Neovim version

0.12.
