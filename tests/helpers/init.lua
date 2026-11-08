-- Shared helpers: temp dirs and files for store/capture tests.
local H = {}

---@return string
function H.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  -- realpath: macOS tempnames live under /var, Neovim names buffers under /private/var
  return vim.uv.fs_realpath(dir) or dir
end

function H.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

function H.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

function H.rm(dir)
  vim.fn.delete(dir, "rf")
end

return H
