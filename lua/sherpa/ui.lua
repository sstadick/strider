local state = require("sherpa.state")

local M = {}

local chunk_namespace = vim.api.nvim_create_namespace("sherpa-chunk")
local comment_namespace = vim.api.nvim_create_namespace("sherpa-comments")
local added_chunk_hl = "SherpaChunkAddedGutter"
local removed_chunk_hl = "SherpaChunkRemovedGutter"
local comment_hl = "SherpaCommentGutter"
local close_windows_for_buffer
local target_window

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "sherpa" })
end

local function log_name()
  return state.get_config().log_buffer_name
end

local function review_name()
  return "sherpa://review"
end

local function log_lines(lines)
  local text = table.concat(lines, "\n")
  if text ~= "" and not text:match("\n$") then
    text = text .. "\n"
  end
  return vim.split(text, "\n", { plain = true })
end

local function configure_scratch_buffer(buf, filetype)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  if filetype then
    vim.bo[buf].filetype = filetype
  end
end

function M.ensure_log_buffer()
  local session = state.get_session()
  if session.log_buf and vim.api.nvim_buf_is_valid(session.log_buf) then
    return session.log_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, log_name())
  configure_scratch_buffer(buf)
  session.log_buf = buf
  return buf
end

function M.ensure_review_buffer()
  local session = state.get_session()
  if session.review_buf and vim.api.nvim_buf_is_valid(session.review_buf) then
    return session.review_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, review_name())
  configure_scratch_buffer(buf, "markdown")
  session.review_buf = buf
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

function M.hide_log()
  local session = state.get_session()
  close_windows_for_buffer(session and session.log_buf)
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

local function configure_review_window(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].winfixwidth = true
end

function M.show_review()
  local session = state.get_session()
  local buf = M.ensure_review_buffer()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      configure_review_window(win)
      session.review_win = win
      return win
    end
  end

  local previous = target_window() or vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  configure_review_window(win)
  local width = math.min(math.max(math.floor(vim.o.columns * 0.38), 44), 72)
  pcall(vim.api.nvim_win_set_width, win, width)
  session.review_win = win
  if previous and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  return win
end

function M.set_review_lines(lines)
  local session = state.get_session()
  local buf = M.ensure_review_buffer()
  local win = M.show_review()
  local items = log_lines(lines or {})
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, items)
  vim.bo[buf].modifiable = false
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end
  session.review_win = win
end

local function set_buffer_busy(buf, busy)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(function()
      vim.bo[buf].busy = busy and 1 or 0
    end)
  end
end

local function progress_buffers(target)
  local bufs = {}
  if target == "review" or target == "both" then
    table.insert(bufs, M.ensure_review_buffer())
  end
  if target == "log" or target == "both" then
    table.insert(bufs, M.ensure_log_buffer())
  end
  return bufs
end

function M.start_activity(title, target)
  local session = state.get_session()
  M.finish_activity(nil, "cancel")
  session.progress = {
    title = title,
    target = target or "log",
  }
  for _, buf in ipairs(progress_buffers(session.progress.target)) do
    set_buffer_busy(buf, true)
  end
  local ok, id = pcall(vim.api.nvim_echo, { { title } }, true, {
    kind = "progress",
    status = "running",
    title = "sherpa",
    source = "sherpa",
  })
  if ok then
    session.progress.id = id
  end
end

function M.finish_activity(message, status)
  local session = state.get_session()
  local progress = session and session.progress
  if not progress then
    return
  end
  for _, buf in ipairs(progress_buffers(progress.target)) do
    set_buffer_busy(buf, false)
  end
  if progress.id then
    pcall(vim.api.nvim_echo, { { message or progress.title } }, true, {
      id = progress.id,
      kind = "progress",
      status = status or "success",
      title = "sherpa",
      source = "sherpa",
    })
  end
  session.progress = nil
end

local editor_ns = vim.api.nvim_create_namespace("sherpa-editor-hint")

-- Open a centered floating scratch editor with ghost-text help.
-- opts: { name, title, hint_lines?, allow_empty? }
--   title is the one-line header shown above the input
--   hint_lines is an optional list of per-command guidance shown as virt_lines
--   allow_empty permits empty submissions (defaults to false)
local function open_scratch_editor(opts, on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  configure_scratch_buffer(buf, "markdown")
  vim.bo[buf].bufhidden = "wipe"

  local ui_info = vim.api.nvim_list_uis()[1] or { width = 120, height = 30 }
  local width = math.min(80, math.max(40, math.floor(ui_info.width * 0.6)))
  local height = math.min(12, math.max(6, math.floor(ui_info.height * 0.35)))
  local row = math.floor((ui_info.height - height) / 2)
  local col = math.floor((ui_info.width - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
    style = "minimal",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:FloatBorder"

  local submit_hint = " <C-s> submit · <Esc><Esc> cancel "

  -- Render ghost text. Called on open and whenever the buffer becomes empty
  -- or non-empty again via TextChanged / TextChangedI.
  local function render_hint()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, editor_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local is_empty = (#lines == 0) or (#lines == 1 and lines[1] == "")

    local virt_lines = {}
    if opts.hint_lines then
      for _, text in ipairs(opts.hint_lines) do
        table.insert(virt_lines, { { text, "Comment" } })
      end
    end
    table.insert(virt_lines, { { submit_hint, "NonText" } })

    local anchor_line = math.max(#lines - 1, 0)
    vim.api.nvim_buf_set_extmark(buf, editor_ns, anchor_line, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
    })

    if is_empty then
      vim.api.nvim_buf_set_extmark(buf, editor_ns, 0, 0, {
        virt_text = { { "type your input…", "Comment" } },
        virt_text_pos = "overlay",
      })
    end
  end

  render_hint()

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = render_hint,
  })

  local function finish(submit)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if submit and (text ~= "" or opts.allow_empty) then
      on_submit(text)
    elseif submit then
      notify("Discarded empty Sherpa input", vim.log.levels.WARN)
    end
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    finish(true)
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set("n", "q", function()
    finish(false)
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set("i", "<Esc><Esc>", function()
    finish(false)
  end, { buffer = buf, nowait = true, silent = true })

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
  end)
end

function M.open_comment_editor(on_submit)
  open_scratch_editor({
    name = "sherpa://comment",
    title = "Sherpa comment",
    hint_lines = { "Leave a review comment. Multiple lines are fine." },
  }, on_submit)
end

function M.open_prompt_editor(label, on_submit, hint_lines)
  open_scratch_editor({
    name = "sherpa://prompt",
    title = label,
    hint_lines = hint_lines,
  }, on_submit)
end

-- Editor that permits an empty submission. Used by review question mode,
-- where empty input means "continue with the current item".
function M.open_prompt_editor_allow_empty(label, on_submit, hint_lines)
  open_scratch_editor({
    name = "sherpa://prompt",
    title = label,
    hint_lines = hint_lines,
    allow_empty = true,
  }, on_submit)
end

local function is_normal_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == ""
end

target_window = function()
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

close_windows_for_buffer = function(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

function M.hide_review()
  local session = state.get_session()
  close_windows_for_buffer(session and session.review_buf)
  if session then
    session.review_win = nil
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
  vim.api.nvim_set_hl(0, comment_hl, { default = true, fg = "#D7BA7D" })
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

function M.clear_comment_markers()
  local session = state.get_session()
  if not session then
    return
  end
  for _, buf in ipairs(session.comment_buffers or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, comment_namespace, 0, -1)
    end
  end
  session.comment_buffers = {}
end

function M.add_comment_marker(path, line)
  local session = state.get_session()
  local buf = get_buffer(path)
  if not buf then
    return
  end
  ensure_chunk_style()
  local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local target = math.min(math.max(tonumber(line) or 1, 1), max_line)
  vim.api.nvim_buf_set_extmark(buf, comment_namespace, target - 1, 0, {
    priority = 20,
    sign_hl_group = comment_hl,
    sign_text = "●",
  })
  session.comment_buffers = session.comment_buffers or {}
  if not vim.tbl_contains(session.comment_buffers, buf) then
    table.insert(session.comment_buffers, buf)
  end
end

function M.set_quickfix(title, items, open)
  vim.fn.setqflist({}, "r", {
    title = title,
    items = items,
  })
  if open ~= false then
    vim.cmd("copen")
  end
end

function M.open_quickfix(title, items)
  M.set_quickfix(title, items, true)
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
