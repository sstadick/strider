local state = require("strider.state")

local M = {}

local uv = vim.uv or vim.loop

local function paste_dir()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "strider", "paste")
end

local function ensure_paste_dir()
  local dir = paste_dir()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function next_image_path()
  local stamp = os.date("%Y%m%d-%H%M%S")
  local suffix = tostring(math.floor((uv.hrtime() / 1000000) % 1000000))
  return vim.fs.joinpath(ensure_paste_dir(), string.format("clipboard-%s-%s.png", stamp, suffix))
end

local function copy_test_image(src, dest)
  src = vim.fn.fnamemodify(src, ":p")
  if vim.fn.filereadable(src) ~= 1 then
    return nil, "Configured clipboard test image was not readable."
  end
  local ok, err = uv.fs_copyfile(src, dest)
  if not ok then
    return nil, err or "failed to copy test clipboard image"
  end
  return dest
end

local function save_with_osascript(dest)
  if vim.fn.has("macunix") ~= 1 or vim.fn.executable("osascript") ~= 1 then
    return nil, "unavailable"
  end

  local script = [[
    on run argv
      set outPath to POSIX file (item 1 of argv)
      try
        set pngData to the clipboard as «class PNGf»
      on error
        error "Clipboard does not contain an image." number 1
      end try

      set fh to open for access outPath with write permission
      try
        set eof fh to 0
        write pngData to fh
        close access fh
      on error errMsg
        try
          close access fh
        end try
        error errMsg number 1
      end try
    end run
  ]]

  vim.fn.system({ "osascript", "-", dest }, script)
  if vim.v.shell_error ~= 0 then
    pcall(uv.fs_unlink, dest)
    return nil, "Clipboard does not contain an image."
  end
  return dest
end

local function save_with_pngpaste(dest)
  if vim.fn.executable("pngpaste") ~= 1 then
    return nil, "unavailable"
  end
  vim.fn.system({ "pngpaste", dest })
  if vim.v.shell_error ~= 0 then
    pcall(uv.fs_unlink, dest)
    return nil, "Clipboard does not contain an image."
  end
  return dest
end

function M.save_image()
  local config = state.get_config()
  local dest = next_image_path()

  if config.clipboard_image_test_file and config.clipboard_image_test_file ~= "" then
    return copy_test_image(config.clipboard_image_test_file, dest)
  end

  local path, err = save_with_osascript(dest)
  if path then
    return path
  end
  if err ~= "unavailable" then
    return nil, err
  end

  path, err = save_with_pngpaste(dest)
  if path then
    return path
  end
  if err ~= "unavailable" then
    return nil, err
  end

  return nil, "Clipboard image paste needs macOS clipboard access or pngpaste (`brew install pngpaste`)."
end

return M
