-- Float lists and the diff view.
local capture = require("strata.capture")
local history = require("strata.history")
local restore = require("strata.restore")
local M = {}

local ns = vim.api.nvim_create_namespace("strata")

---@class strata.List
---@field buf integer
---@field win integer
---@field actions table<string, fun(idx: integer)>
M._current = nil ---@type strata.List?

local function notify(msg, level)
  vim.notify("strata: " .. msg, level or vim.log.levels.INFO)
end

function M.close()
  local cur = M._current
  M._current = nil
  if cur and vim.api.nvim_win_is_valid(cur.win) then
    vim.api.nvim_win_close(cur.win, true)
  end
end

---@param t integer
---@return string
function M.fmt_time(t)
  local today = os.date("%Y-%m-%d")
  local day = os.date("%Y-%m-%d", t)
  if day == today then
    return os.date("   today %H:%M:%S", t)
  end
  return os.date("%m-%d %H:%M:%S", t)
end

---@param n integer
---@return string
function M.fmt_size(n)
  if n < 1024 then
    return ("%dB"):format(n)
  elseif n < 1024 * 1024 then
    return ("%.1fk"):format(n / 1024)
  end
  return ("%.1fM"):format(n / 1024 / 1024)
end

--- Open a float with `lines`. `actions` maps config key names to callbacks
--- that get the 1-based row. `hl` is an optional list of {row, group}.
---@param opts { title: string, lines: string[], actions: table<string, fun(idx: integer)>, hl: table[]? }
---@return strata.List
function M.list(opts)
  M.close()
  local keys = capture.config().keys
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "strata"
  for _, h in ipairs(opts.hl or {}) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1] - 1, 0, { line_hl_group = h[2] })
  end
  local width = 0
  for _, l in ipairs(opts.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width, #opts.title + 4), vim.o.columns - 4)
  local height = math.max(1, math.min(#opts.lines, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  local list = { buf = buf, win = win, actions = opts.actions }
  M._current = list
  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  for name, fn in pairs(opts.actions) do
    local lhs = keys[name]
    if lhs then
      map(lhs, function()
        fn(vim.api.nvim_win_get_cursor(win)[1])
      end)
    end
  end
  map(keys.close, M.close)
  map("<Esc>", M.close)
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      if M._current == list then
        vim.schedule(M.close)
      end
    end,
  })
  return list
end

--- Scratch buffer holding snapshot content, typed like the source.
---@param rel string
---@param e strata.Entry
---@param content string
---@param src integer? source buffer for filetype
---@return integer buf
local function scratch(rel, e, content, src)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(content:gsub("\n$", ""), "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, ("strata://%s@%s"):format(rel, os.date("%H:%M:%S", e.t)))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  if src and vim.api.nvim_buf_is_valid(src) then
    vim.bo[buf].filetype = vim.bo[src].filetype
  else
    vim.bo[buf].filetype = vim.filetype.match({ filename = rel }) or ""
  end
  return buf
end

--- Diff a snapshot against the file in a vertical split.
---@param s strata.Store
---@param rel string
---@param e strata.Entry
function M.diff(s, rel, e)
  local content = s:get(e.h)
  if not content then
    return notify("snapshot content is gone", vim.log.levels.ERROR)
  end
  M.close()
  local abs = vim.fs.joinpath(s.root, rel)
  if vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")) ~= abs then
    vim.cmd.edit(vim.fn.fnameescape(abs))
  end
  local src_win = vim.api.nvim_get_current_win()
  local src_buf = vim.api.nvim_get_current_buf()
  local buf = scratch(rel, e, content, src_buf)
  vim.cmd("vertical leftabove sbuffer " .. buf)
  local snap_win = vim.api.nvim_get_current_win()
  vim.wo[snap_win].diff = true
  vim.wo[src_win].diff = true
  vim.keymap.set("n", capture.config().keys.close, function()
    if vim.api.nvim_win_is_valid(snap_win) then
      vim.api.nvim_win_close(snap_win, true)
    end
    if vim.api.nvim_win_is_valid(src_win) then
      vim.wo[src_win].diff = false
    end
  end, { buffer = buf, nowait = true, silent = true })
end

--- Snapshot content in a split, read only.
---@param s strata.Store
---@param rel string
---@param e strata.Entry
function M.open(s, rel, e)
  local content = s:get(e.h)
  if not content then
    return notify("snapshot content is gone", vim.log.levels.ERROR)
  end
  M.close()
  vim.cmd("sbuffer " .. scratch(rel, e, content))
end

--- History of the current file.
function M.file_history()
  local buf = vim.api.nvim_get_current_buf()
  local abs = capture.path_of(buf)
  if not abs then
    return notify("no file in this buffer, or it is excluded")
  end
  local s, rel = capture.locate(abs)
  if not s then
    return notify("no store for this file")
  end
  local entries = history.file(s, rel)
  if #entries == 0 then
    return notify("no history yet for " .. rel)
  end
  local lines, hl = {}, {}
  for i, e in ipairs(entries) do
    if e.e == "label" then
      lines[i] = ("%s  ── %s"):format(M.fmt_time(e.t), e.l)
      hl[#hl + 1] = { i, "Title" }
    else
      lines[i] = ("%s  %-8s %6s"):format(M.fmt_time(e.t), e.e, M.fmt_size(e.s))
    end
  end
  local pick = function(idx)
    local e = entries[idx]
    if not e or e.e == "label" then
      notify("that row is a label")
      return nil
    end
    return e
  end
  M.list({
    title = rel,
    lines = lines,
    hl = hl,
    actions = {
      diff = function(idx)
        local e = pick(idx)
        if e then
          M.diff(s, rel, e)
        end
      end,
      open = function(idx)
        local e = pick(idx)
        if e then
          M.open(s, rel, e)
        end
      end,
      restore = function(idx)
        local e = pick(idx)
        if not e then
          return
        end
        local content = s:get(e.h)
        if not content then
          return notify("snapshot content is gone", vim.log.levels.ERROR)
        end
        M.close()
        local ok, err = restore.apply(s, rel, content)
        notify(ok and ("restored %s from %s"):format(rel, M.fmt_time(e.t)) or err, ok and nil or vim.log.levels.ERROR)
      end,
    },
  })
end

--- Deleted files with a snapshot. Pick one to put it back.
---@param s strata.Store
function M.recover(s)
  local gone = history.deleted(s)
  if #gone == 0 then
    return notify("no deleted files with history under " .. s.root)
  end
  local lines = {}
  for i, g in ipairs(gone) do
    lines[i] = ("%s  %6s  %s"):format(M.fmt_time(g.entry.t), M.fmt_size(g.entry.s), g.p)
  end
  M.list({
    title = "deleted files",
    lines = lines,
    actions = {
      open = function(idx)
        local g = gone[idx]
        if g then
          M.open(s, g.p, g.entry)
        end
      end,
      diff = function(idx)
        local g = gone[idx]
        if g then
          M.open(s, g.p, g.entry)
        end
      end,
      restore = function(idx)
        local g = gone[idx]
        if not g then
          return
        end
        local content = s:get(g.entry.h)
        if not content then
          return notify("snapshot content is gone", vim.log.levels.ERROR)
        end
        M.close()
        local ok, err = restore.apply(s, g.p, content)
        if ok then
          notify("recovered " .. g.p)
          vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(s.root, g.p)))
        else
          notify(err, vim.log.levels.ERROR)
        end
      end,
    },
  })
end

--- quilt.nvim hits for the changed ranges of modified files, in the current file.
---@param s strata.Store
---@param changes strata.Change[]
---@return table[] hits { path, row, end_row } 0-based, end-exclusive
function M.hits(s, changes)
  local hits = {}
  for _, c in ipairs(changes) do
    if c.kind == "modified" then
      local abs = vim.fs.joinpath(s.root, c.p)
      local old = s:get(c.was.h)
      local new = require("strata.store")._read_file(abs)
      if old and new then
        local total = select(2, new:gsub("\n", "")) + (new:sub(-1) == "\n" and 0 or 1)
        for _, h in ipairs(vim.diff(old, new, { result_type = "indices" }) or {}) do
          local sb, cb = h[3], h[4]
          local row, end_row
          if cb == 0 then
            -- a pure deletion: mark the line that now follows it (or the last line)
            row = math.max(0, math.min(sb, total - 1))
            end_row = row + 1
          else
            row, end_row = sb - 1, sb - 1 + cb
          end
          hits[#hits + 1] = { path = abs, row = row, end_row = end_row }
        end
      end
    end
  end
  return hits
end

--- Files changed since `t`, with per-file and whole-set restore.
---@param s strata.Store
---@param t integer
---@param title string
function M.changes(s, t, title)
  local ch = history.changed_since(s, t)
  if #ch == 0 then
    return notify("nothing changed since " .. vim.trim(M.fmt_time(t)))
  end
  local lines = {}
  for i, c in ipairs(ch) do
    lines[i] = ("%-9s %s"):format(c.kind, c.p)
  end
  local function put(c)
    if not c.was then
      return false
    end
    local content = s:get(c.was.h)
    if not content then
      return false
    end
    return (restore.apply(s, c.p, content))
  end
  local function show(idx, how)
    local c = ch[idx]
    if not c then
      return
    end
    if c.kind == "modified" then
      how(s, c.p, c.was)
    elseif c.kind == "deleted" then
      M.open(s, c.p, c.was)
    else
      M.close()
      notify(c.p .. " did not exist then")
      vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(s.root, c.p)))
    end
  end
  M.list({
    title = title,
    lines = lines,
    actions = {
      diff = function(idx)
        show(idx, M.diff)
      end,
      open = function(idx)
        show(idx, M.open)
      end,
      restore = function(idx)
        local c = ch[idx]
        if not c then
          return
        end
        M.close()
        if c.kind == "added" then
          return notify(c.p .. " did not exist then; nothing to restore (strata never deletes)")
        end
        local ok = put(c)
        notify(ok and ("restored " .. c.p) or ("could not restore " .. c.p), ok and nil or vim.log.levels.ERROR)
      end,
      restore_all = function()
        M.close()
        local n, skipped = 0, 0
        for _, c in ipairs(ch) do
          if c.kind == "added" then
            skipped = skipped + 1
          elseif put(c) then
            n = n + 1
          end
        end
        local msg = ("restored %d file(s) to %s"):format(n, vim.trim(M.fmt_time(t)))
        if skipped > 0 then
          msg = msg .. (", %d added since were left in place"):format(skipped)
        end
        notify(msg)
      end,
      quilt = function()
        local ok, quilt = pcall(require, "quilt")
        if not ok then
          return notify("quilt.nvim is not installed", vim.log.levels.WARN)
        end
        local hits = M.hits(s, ch)
        M.close()
        if #hits == 0 then
          return notify("no modified files to show")
        end
        quilt.open_hits(hits, "strata: since " .. vim.trim(M.fmt_time(t)))
      end,
    },
  })
end

--- Timeline of the project: labels and snapshot groups, newest first.
---@param s strata.Store
function M.project(s)
  local tl = history.timeline(s)
  if #tl == 0 then
    return notify("no history yet under " .. s.root)
  end
  local lines, hl = {}, {}
  for i, p in ipairs(tl) do
    if p.kind == "label" then
      lines[i] = ("%s  ── %s"):format(M.fmt_time(p.t), p.text)
      hl[#hl + 1] = { i, "Title" }
    else
      lines[i] = ("%s  %d file%s"):format(M.fmt_time(p.t), p.count, p.count == 1 and "" or "s")
    end
  end
  local drill = function(idx)
    local p = tl[idx]
    if p then
      M.changes(s, p.t, "changed since " .. vim.trim(M.fmt_time(p.t)))
    end
  end
  M.list({
    title = vim.fn.fnamemodify(s.root, ":t"),
    lines = lines,
    hl = hl,
    actions = { diff = drill, open = drill, restore = drill },
  })
end

return M
