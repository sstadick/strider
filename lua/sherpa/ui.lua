local state = require("sherpa.state")

local M = {}

local chunk_namespace = vim.api.nvim_create_namespace("sherpa-chunk")
local added_chunk_hl = "SherpaChunkAddedGutter"
local removed_chunk_hl = "SherpaChunkRemovedGutter"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "sherpa" })
end

local function log_name()
  return state.get_config().log_buffer_name
end

local function log_lines(lines)
  local text = table.concat(lines, "\n")
  if text ~= "" and not text:match("\n$") then
    text = text .. "\n"
  end
  return vim.split(text, "\n", { plain = true })
end

function M.ensure_log_buffer()
  local session = state.get_session()
  if session.log_buf and vim.api.nvim_buf_is_valid(session.log_buf) then
    return session.log_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, log_name())
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  session.log_buf = buf
  return buf
end

local function scroll_log_windows(buf)
  local last = math.max(vim.api.nvim_buf_line_count(buf), 1)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    end
  end
end

function M.show_log()
  local buf = M.ensure_log_buffer()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      scroll_log_windows(buf)
      return
    end
  end
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  scroll_log_windows(buf)
end

function M.append(lines)
  local buf = M.ensure_log_buffer()
  local items = log_lines(lines)
  if #items == 0 then
    return
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
  scroll_log_windows(buf)
end

function M.append_block(label, text)
  local lines = { string.format("[%s]", label) }
  vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  table.insert(lines, "")
  M.append(lines)
end

local function is_normal_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == ""
end

local function target_window()
  local current = vim.api.nvim_get_current_win()
  if is_normal_window(current) then
    return current
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_normal_window(win) then
      return win
    end
  end
end

local function refresh_buffer(buf)
  if buf <= 0 or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.cmd, "silent checktime")
  end)
end

local function clear_chunk_highlight(session)
  local buf = session.highlight_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, chunk_namespace, 0, -1)
  end
  session.chunk_lines = {}
  session.chunk_path = nil
  session.highlight_buf = nil
end

local function ensure_chunk_style()
  vim.api.nvim_set_hl(0, added_chunk_hl, { default = true, fg = "#73C991" })
  vim.api.nvim_set_hl(0, removed_chunk_hl, { default = true, fg = "#F14C4C" })
end

local function get_buffer(path)
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
    refresh_buffer(buf)
    return buf
  end
end

function M.jump_to_file(path, line)
  if not state.get_config().auto_jump or path == "" then
    return
  end

  local buf = vim.fn.bufnr(path)
  local wins = buf > 0 and vim.fn.win_findbuf(buf) or {}
  local win = wins[1] or target_window()
  if not win then
    return
  end

  vim.api.nvim_set_current_win(win)
  if buf > 0 then
    vim.api.nvim_win_set_buf(win, buf)
    refresh_buffer(buf)
  else
    pcall(vim.cmd, "silent edit " .. vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    refresh_buffer(buf)
  end

  local target = tonumber(line) or 1
  local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
  target = math.min(math.max(target, 1), max_line)
  pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, "normal! zz")
  end)
end

function M.highlight_lines(path, lines)
  local session = state.get_session()
  local buf = get_buffer(path)
  if not buf then
    return
  end

  clear_chunk_highlight(session)
  ensure_chunk_style()

  local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local marks_by_line = {}
  local ordered = {}

  for _, item in ipairs(lines or {}) do
    local line = type(item) == "table" and item.line or item
    local kind = type(item) == "table" and item.kind or "added"
    local target = math.min(math.max(tonumber(line) or 1, 1), max_line)
    if not marks_by_line[target] then
      marks_by_line[target] = kind
      table.insert(ordered, target)
    elseif marks_by_line[target] ~= "removed" and kind == "removed" then
      marks_by_line[target] = kind
    end
  end

  table.sort(ordered)
  for _, target in ipairs(ordered) do
    local removed = marks_by_line[target] == "removed"
    vim.api.nvim_buf_set_extmark(buf, chunk_namespace, target - 1, 0, {
      priority = removed and 11 or 10,
      sign_hl_group = removed and removed_chunk_hl or added_chunk_hl,
      sign_text = removed and "-" or "▎",
    })
  end

  session.chunk_lines = ordered
  session.chunk_path = path
  session.highlight_buf = buf
end

function M.highlight_range(path, first_line, last_line)
  local buf = get_buffer(path)
  if not buf then
    return
  end

  local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local start_line = math.min(math.max(tonumber(first_line) or 1, 1), max_line)
  local end_line = math.min(math.max(tonumber(last_line) or max_line, start_line), max_line)
  local lines = {}
  for line = start_line, end_line do
    table.insert(lines, { line = line, kind = "added" })
  end
  M.highlight_lines(path, lines)
end

function M.jump_to_chunk_change(direction)
  local session = state.get_session()
  if not session then
    notify("No active Sherpa session", vim.log.levels.WARN)
    return
  end
  local path = session.chunk_path
  local lines = session.chunk_lines or {}
  if not path or #lines == 0 then
    notify("No active chunk changes", vim.log.levels.WARN)
    return
  end

  local current_path = vim.api.nvim_buf_get_name(0)
  if current_path ~= path then
    local target = direction < 0 and lines[#lines] or lines[1]
    M.jump_to_file(path, target)
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  if direction < 0 then
    for index = #lines, 1, -1 do
      if lines[index] < current_line then
        M.jump_to_file(path, lines[index])
        return
      end
    end
    M.jump_to_file(path, lines[#lines])
    return
  end

  for _, line in ipairs(lines) do
    if line > current_line then
      M.jump_to_file(path, line)
      return
    end
  end
  M.jump_to_file(path, lines[1])
end

function M.show_status()
  local session = state.get_session()
  local lines = { "Sherpa status" }
  vim.list_extend(lines, session.widget)
  if session.last_touched_file then
    table.insert(lines, "File: " .. session.last_touched_file)
  end
  if session.last_summary then
    table.insert(lines, "Summary: " .. session.last_summary)
  end
  notify(table.concat(lines, " | "))
end

function M.notify(message, level)
  notify(message, level)
end

return M
