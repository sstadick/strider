local clipboard = require("sherpa.clipboard")
local log_pin = require("sherpa.log_pin")
local state = require("sherpa.state")
local status = require("sherpa.status")

local M = {}

local chunk_namespace = vim.api.nvim_create_namespace("sherpa-chunk")
local comment_namespace = vim.api.nvim_create_namespace("sherpa-comments")
local annotation_namespace = vim.api.nvim_create_namespace("sherpa-annotations")
local log_namespace = vim.api.nvim_create_namespace("sherpa-log")
local added_chunk_hl = "SherpaChunkAddedGutter"
local removed_chunk_hl = "SherpaChunkRemovedGutter"
local comment_hl = "SherpaCommentGutter"
local annotation_hl = "SherpaAnnotation"
local log_assistant_hl = "SherpaLogAssistant"
local log_user_hl = "SherpaLogUser"
local log_tool_hl = "SherpaLogTool"
local log_thinking_hl = "SherpaLogThinking"
local log_rule_hl = "SherpaLogRule"
local log_error_hl = "SherpaLogError"
local log_path_hl = "SherpaLogPath"
local log_muted_hl = "SherpaLogMuted"
local log_tool_output_hl = "SherpaLogToolOutput"
local log_tool_output_ellipsis_hl = "SherpaLogToolOutputEllipsis"
local log_user_prefix = "› "
local log_user_continuation = "  "
local log_assistant_bg_hl = "SherpaLogAssistantBg"
local log_user_bg_hl = "SherpaLogUserBg"
local log_error_bg_hl = "SherpaLogErrorBg"
local log_diff_add_hl = "SherpaLogDiffAdd"
local log_diff_remove_hl = "SherpaLogDiffRemove"
local log_diff_context_hl = "SherpaLogDiffContext"
local log_diff_stats_hl = "SherpaLogDiffStats"
local compose_working_hl = "SherpaComposeWorking"
local compose_working_soft_hl = "SherpaComposeWorkingSoft"
local compose_working_shine_hl = "SherpaComposeWorkingShine"
local close_windows_for_buffer
local target_window
-- Forward declaration — defined later, referenced by append_block.
local ensure_chunk_style

local spin_states = {}

local function normalize_lane(lane)
  return state.normalize_lane(lane)
end

local function spin_state(lane)
  lane = normalize_lane(lane)
  spin_states[lane] = spin_states[lane] or {
    index = 0,
    timer = nil,
  }
  return spin_states[lane], lane
end

local function activity_echo(message)
  return pcall(vim.api.nvim_echo, { { "sherpa: " .. message } }, false, {})
end

local function stop_spin(lane)
  local spin = spin_state(lane)
  if spin.timer then
    spin.timer:stop()
    spin.timer:close()
    spin.timer = nil
  end
end

-- Format a hrtime-based nanosecond duration as a short human string
-- that fits in the winbar. Under 60s: `3s`. Under an hour: `1m24s`.
-- Otherwise: `1h12m`.
local function format_elapsed(start_ns)
  if not start_ns then return nil end
  local now = vim.uv.hrtime()
  local elapsed_s = (now - start_ns) / 1e9
  if elapsed_s < 60 then
    return string.format("%ds", math.floor(elapsed_s))
  elseif elapsed_s < 3600 then
    local minutes = math.floor(elapsed_s / 60)
    local seconds = math.floor(elapsed_s % 60)
    return string.format("%dm%02ds", minutes, seconds)
  else
    local hours = math.floor(elapsed_s / 3600)
    local minutes = math.floor((elapsed_s % 3600) / 60)
    return string.format("%dh%02dm", hours, minutes)
  end
end

local function escape_status_text(text)
  return (text or ""):gsub("%%", "%%%%")
end

local WORKING_LABEL = "Working"
local WORKING_SHINE_PADDING = 2

-- Winbar strings support statusline highlight escapes (`%#Group#...%*`).
-- Use them to sweep a small highlight window across `Working` so the
-- compose header gets a subtle Codex-style shine while a turn is active.
local function compose_working_label(prefix, lane)
  ensure_chunk_style()
  local spin = spin_state(lane)
  local phase = spin.index or 0
  local center = phase - (WORKING_SHINE_PADDING - 1)
  local pieces = {}
  if prefix ~= "" then
    table.insert(pieces, escape_status_text(prefix))
  end
  for i = 1, #WORKING_LABEL do
    local hl = compose_working_hl
    local distance = math.abs(i - center)
    if distance == 0 then
      hl = compose_working_shine_hl
    elseif distance == 1 then
      hl = compose_working_soft_hl
    end
    table.insert(pieces, string.format("%%#%s#%s%%*", hl, WORKING_LABEL:sub(i, i)))
  end
  return table.concat(pieces)
end

local function compose_status_line(progress, lane)
  local session = state.get_session(lane)
  local statuses = session and session.status or {}
  local clarify_badge = statuses["sherpa-clarify"]
  local prefix = ""
  local idle_msg = nil
  if clarify_badge and clarify_badge ~= "" then
    prefix = "[Clarify] "
    idle_msg = "Sherpa is asking — type your answer (<Esc><Esc> to reject)."
  end
  if not progress then
    if idle_msg then return prefix .. idle_msg end
    local action = status.pending_action(lane)
    if action then
      return action
    end
    -- Idle: show model + cwd like codex's bottom bar.
    local widget = session and session.widget or {}
    local parts = {}
    for _, line in ipairs(widget) do
      local trimmed = vim.trim(line or "")
      if trimmed ~= "" then table.insert(parts, trimmed) end
    end
    if #parts > 0 then
      return table.concat(parts, " · ")
    end
    return "Sherpa is ready."
  end
  -- Active: animate `Working` and keep the elapsed-time / stop hint on the right.
  local elapsed = format_elapsed(progress.started_at) or "0s"
  local left = compose_working_label(prefix, lane)
  local right = string.format("%s · :SherpaStop to interrupt", elapsed)
  return left, right, true
end

function M.refresh_compose_winbar(lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local buf = session and session.compose_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local left, right, left_is_statusline = compose_status_line(session and session.progress, lane)
  if not left_is_statusline then
    left = escape_status_text(left)
  end
  local value = right
    and (left .. "%=" .. escape_status_text(right))
    or left
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(function() vim.wo[win].winbar = value end)
    end
  end
end

-- Ticks drive the `Working` shimmer and keep the elapsed-time suffix fresh.
local SPIN_INTERVAL_MS = 120

local function spin_tick(lane)
  local spin = spin_state(lane)
  local session = state.get_session(lane)
  local progress = session and session.progress
  if not progress then
    stop_spin(lane)
    return
  end
  spin.index = (spin.index + 1) % (#WORKING_LABEL + WORKING_SHINE_PADDING * 2)
  local cbuf = session.compose_buf
  if not cbuf or not vim.api.nvim_buf_is_valid(cbuf) or #vim.fn.win_findbuf(cbuf) == 0 then
    return
  end
  M.refresh_compose_winbar(lane)
end

local function start_spin(progress, lane)
  local spin = spin_state(lane)
  stop_spin(lane)
  spin.index = 0
  M.refresh_compose_winbar(lane)
  spin.timer = vim.uv.new_timer()
  spin.timer:start(SPIN_INTERVAL_MS, SPIN_INTERVAL_MS, vim.schedule_wrap(function()
    spin_tick(lane)
  end))
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "sherpa" })
end

local function log_name(lane)
  lane = normalize_lane(lane)
  if lane == "flow" then
    return "sherpa://SherpaLogFlow"
  end
  if lane == "review" then
    return "sherpa://SherpaLogReview"
  end
  return state.get_config().log_buffer_name
end

local function review_name()
  return "sherpa://review"
end

local function status_name()
  return "sherpa://status"
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

function M.ensure_log_buffer(lane)
  local session = state.get_session(lane)
  if session.log_buf and vim.api.nvim_buf_is_valid(session.log_buf) then
    return session.log_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, log_name(lane))
  configure_scratch_buffer(buf, "markdown")
  -- Setting `filetype = "markdown"` on a hidden scratch buffer doesn't
  -- always run the full FileType pipeline. Replay it manually, but do so
  -- with this buffer temporarily current: some ftplugins (including
  -- Neovim's built-in markdown ftplugin) call buffer-local APIs like
  -- `vim.treesitter.start()` without an explicit buffer argument.
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
  end)
  -- Belt-and-braces: if the FileType pipeline didn't start treesitter,
  -- do it explicitly for the log buffer. No-op / silent if the markdown
  -- parser isn't installed.
  pcall(vim.treesitter.start, buf, "markdown")
  session.log_buf = buf
  return buf
end

function M.ensure_review_buffer()
  local session = state.get_session("review")
  if session.review_buf and vim.api.nvim_buf_is_valid(session.review_buf) then
    return session.review_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, review_name())
  configure_scratch_buffer(buf, "markdown")
  session.review_buf = buf
  return buf
end

function M.ensure_status_buffer()
  local session = state.ensure_session("main", vim.fn.getcwd())
  if session.status_buf and vim.api.nvim_buf_is_valid(session.status_buf) then
    return session.status_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, status_name())
  configure_scratch_buffer(buf, "markdown")
  session.status_buf = buf
  return buf
end

function M.show_status(lines)
  local previous = target_window() or vim.api.nvim_get_current_win()
  local buf = M.ensure_status_buffer()
  local items = log_lines(lines or {})
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, items)
  vim.bo[buf].modifiable = false

  local win = vim.fn.win_findbuf(buf)[1]
  if not win or not vim.api.nvim_win_is_valid(win) then
    vim.cmd("botright vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    pcall(vim.api.nvim_win_set_width, win, 52)
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
  end
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  if previous and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  return win
end

-- Debounced log scroll. During tool-heavy turns scroll_log_windows fires
-- many times per frame. A 30ms trailing timer coalesces rapid appends.
-- Each log window has a window-local `sherpa_log_follow` bit: when the
-- viewport is at the bottom, appends tail the log; scrolling up clears it
-- so the user can inspect earlier output without Sherpa yanking them back.
local scroll_timers = {}
local SCROLL_DEBOUNCE_MS = 30
local log_follow_augroup = nil

local function buffer_is_log(buf)
  for _, lane in ipairs(state.lanes()) do
    local session = state.get_session(lane)
    if session and session.log_buf == buf then
      return true
    end
  end
  return false
end

local function window_is_log(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  return ok and buffer_is_log(buf)
end

local function log_window_bottom_line(win)
  if not window_is_log(win) then
    return 0
  end
  local ok, line = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.line("w$")
  end)
  return ok and line or 0
end

local function log_window_line_count(win)
  if not window_is_log(win) then
    return 1
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok or not vim.api.nvim_buf_is_valid(buf) then
    return 1
  end
  return math.max(vim.api.nvim_buf_line_count(buf), 1)
end

local function log_window_at_bottom(win)
  return log_window_bottom_line(win) >= log_window_line_count(win)
end

local function log_follow_value(win)
  local ok, value = pcall(function()
    return vim.w[win].sherpa_log_follow
  end)
  if not ok then return nil end
  return value
end

local function log_follow_line_count(win)
  local ok, value = pcall(function()
    return vim.w[win].sherpa_log_follow_line_count
  end)
  if not ok or type(value) ~= "number" then return nil end
  return value
end

local function set_log_follow(win, follow)
  if not window_is_log(win) then return end
  pcall(function()
    vim.w[win].sherpa_log_follow = follow and true or false
    if follow then
      vim.w[win].sherpa_log_follow_line_count = log_window_line_count(win)
    end
  end)
end

local function log_window_follows(win)
  if not window_is_log(win) then
    return false
  end
  local follow = log_follow_value(win)
  if follow == nil then
    -- A Sherpa-created log window is initialized explicitly. If a log
    -- buffer is shown manually before that happens, prefer tailing until
    -- the first real scroll/cursor event records the user's intent.
    return true
  end
  return follow == true or follow == 1
end

local function update_log_follow_state(win)
  if not window_is_log(win) then return end
  if log_window_at_bottom(win) then
    set_log_follow(win, true)
    log_pin.refresh_for_window(win)
    return
  end

  -- If the buffer grew under a tailing window, the viewport is no longer
  -- at the new `$` yet, but it is still at the old tail. Keep follow-mode
  -- locked until the debounced scroll catches up. A real user scroll above
  -- the old tail will clear it.
  local follow = log_follow_value(win)
  local previous_tail = log_follow_line_count(win)
  if (follow == true or follow == 1) and previous_tail then
    if log_window_bottom_line(win) >= previous_tail then
      log_pin.refresh_for_window(win)
      return
    end
  end
  set_log_follow(win, false)
  log_pin.refresh_for_window(win)
end

local function event_window(args)
  local win = args and tonumber(args.match)
  if (not win or win == 0) and vim.v.event then
    win = tonumber(vim.v.event.winid or vim.v.event.win or vim.v.event.window)
  end
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  return vim.api.nvim_get_current_win()
end

local function ensure_log_follow_autocmds()
  if log_follow_augroup then return end
  log_follow_augroup = vim.api.nvim_create_augroup("SherpaLogFollow", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "WinResized" }, {
    group = log_follow_augroup,
    callback = function(args)
      update_log_follow_state(event_window(args))
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = log_follow_augroup,
    callback = function(args)
      log_pin.close_for_window(tonumber(args.match))
    end,
  })
end

local function scroll_log_windows_now(buf)
  local last = math.max(vim.api.nvim_buf_line_count(buf), 1)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      if log_window_follows(win) then
        local ok = pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
        if ok then
          set_log_follow(win, true)
        end
      end
      log_pin.refresh_for_window(win)
    end
  end
end

local function scroll_log_windows(buf)
  ensure_log_follow_autocmds()
  local timer = scroll_timers[buf]
  if timer then
    timer:stop()
  else
    timer = vim.uv.new_timer()
    scroll_timers[buf] = timer
  end
  timer:start(SCROLL_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) then
      scroll_log_windows_now(buf)
    end
  end))
end

-- Build a single-line winbar from the widget that the extension pushes
-- via setWidget("sherpa", [...]). We flatten meaningful lines (Model,
-- Context, Cost, last response, etc.) joined with ` · `. Empty widget
-- renders a minimal idle label.
local function format_log_winbar(lane)
  local session = state.get_session(lane)
  local widget = session and session.widget or {}
  local parts = {}
  for _, line in ipairs(widget) do
    local trimmed = vim.trim(line or "")
    if trimmed ~= "" then
      table.insert(parts, trimmed)
    end
  end
  if #parts == 0 then
    return "Sherpa"
  end
  return table.concat(parts, " · "):gsub("%%", "%%%%")
end

-- Apply the winbar to every window currently showing the log buffer.
-- Idempotent; safe to call on every widget update.
function M.refresh_log_winbar(lane)
  local session = state.get_session(lane)
  local buf = session and session.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local value = format_log_winbar(lane)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(function() vim.wo[win].winbar = value end)
    end
  end
end

function M.open_log(opts, lane)
  opts = opts or {}
  lane = normalize_lane(lane)
  ensure_log_follow_autocmds()
  local previous = opts.preserve_focus and (target_window() or vim.api.nvim_get_current_win()) or nil
  local buf = M.ensure_log_buffer(lane)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      if log_follow_value(win) == nil then
        update_log_follow_state(win)
      end
      if not opts.preserve_focus then
        vim.api.nvim_set_current_win(win)
      end
      scroll_log_windows(buf)
      M.refresh_log_winbar(lane)
      log_pin.refresh_for_window(win)
      return
    end
  end
  -- Log opens as a right-hand vertical split. Compose window, if opened,
  -- stacks below the log in that same vertical column.
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  set_log_follow(win, true)
  -- conceallevel is window-local. render-markdown.nvim and markdown's
  -- built-in syntax rely on it to hide fence markers / inline markers.
  -- Set it on the log window so fenced tool output renders cleanly.
  pcall(function()
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "nc"
  end)
  scroll_log_windows(buf)
  M.refresh_log_winbar(lane)
  log_pin.refresh_for_window(win)
  if previous and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
end

function M.hide_log(lane)
  local session = state.get_session(lane)
  close_windows_for_buffer(session and session.log_buf)
end

-- Compose buffer: a persistent scratch buffer for user input. Sits in
-- a horizontal split below the log (right-hand column). <C-s> sends
-- its contents via the provided dispatcher; buffer is cleared on
-- successful send but kept alive across sends.
local compose_ns = vim.api.nvim_create_namespace("sherpa-compose-hint")

local function compose_buffer_name()
  return "sherpa://compose"
end

local function compose_hint_text()
  if state.peek_pending_clarify() then
    return "Answer clarify · <C-s> send · <Esc><Esc> reject"
  end
  if state.peek_pending_request() then
    return "Turn in flight · type to steer · <C-s> send · :SherpaStop cancel"
  end
  return "Type a message · <C-v> screenshot · <C-s> to send"
end

function M.ensure_compose_buffer(on_send)
  local session = state.get_session()
  if session.compose_buf and vim.api.nvim_buf_is_valid(session.compose_buf) then
    return session.compose_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, compose_buffer_name())
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  session.compose_buf = buf

  local function render_hint()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, compose_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local is_empty = (#lines == 0) or (#lines == 1 and lines[1] == "")
    if is_empty then
      pcall(vim.api.nvim_buf_set_extmark, buf, compose_ns, 0, 0, {
        virt_text = { { compose_hint_text(), "Comment" } },
        virt_text_pos = "overlay",
      })
    end
  end

  session.compose_hint_renderer = render_hint
  render_hint()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = render_hint,
  })

  local function resume_compose()
    local compose_win = vim.fn.win_findbuf(buf)[1]
    if not compose_win or not vim.api.nvim_win_is_valid(compose_win) then
      return
    end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(compose_win) then
        vim.api.nvim_set_current_win(compose_win)
        local last = math.max(vim.api.nvim_buf_line_count(buf), 1)
        pcall(vim.api.nvim_win_set_cursor, compose_win, { last, 0 })
        vim.cmd("startinsert")
      end
    end)
  end

  local function append_compose_marker(marker)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local is_empty = (#lines == 0) or (#lines == 1 and lines[1] == "")
    if is_empty then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { marker, "" })
    elseif lines[#lines] == "" then
      vim.api.nvim_buf_set_lines(buf, #lines - 1, #lines, false, { marker, "" })
    else
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { marker, "" })
    end
    render_hint()
  end

  local function paste_image()
    local path, err = clipboard.save_image()
    if not path then
      notify(err or "Clipboard image paste failed", vim.log.levels.WARN)
      resume_compose()
      return
    end
    append_compose_marker("@image " .. path)
    resume_compose()
  end

  local function send_compose()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      notify("Nothing to send — type a message first", vim.log.levels.WARN)
      return
    end

    -- Dispatch first; only clear the buffer if the send actually
    -- succeeded. Undo history is reset so `u` doesn't resurrect the
    -- just-sent text — surprising since it's now in the log as history.
    local ok = on_send(text)
    if ok ~= false then
      pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {})
      -- Reset undo so `u` can't resurrect a message already in flight.
      vim.bo[buf].undolevels = -1
      vim.bo[buf].undolevels = vim.o.undolevels
      render_hint()
    end

    -- Keep the user in the compose window + insert mode for the next
    -- message. Scheduled so it lands after any activity echo / scroll
    -- effects from the dispatch.
    resume_compose()
  end

  local function leave_insert()
    -- If a clarify is pending, <Esc><Esc> rejects it (same intuition
    -- as the old floating clarify editor's cancel). The reject reply
    -- goes back to the extension, the badge clears, and then we drop
    -- out of insert as usual. Lazy-required to avoid a load-order cycle
    -- (ui is required by init).
    local ok, sherpa = pcall(require, "sherpa")
    if ok and sherpa and sherpa.cancel_pending_clarify_if_any then
      sherpa.cancel_pending_clarify_if_any()
    end
    pcall(vim.cmd, "stopinsert")
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", send_compose, {
    buffer = buf, nowait = true, silent = true, desc = "Send Sherpa compose"
  })
  vim.keymap.set({ "n", "i" }, "<C-v>", paste_image, {
    buffer = buf, nowait = true, silent = true, desc = "Paste clipboard image into Sherpa compose"
  })
  vim.keymap.set({ "n", "i" }, "<S-Tab>", function()
    -- Mirror pi's own shift-tab UX: cycle the thinking level without
    -- leaving the compose buffer. The new level shows up in the log
    -- winbar's Model: ... (level) suffix once the widget refreshes.
    require("sherpa").cycle_thinking()
  end, {
    buffer = buf, nowait = true, silent = true, desc = "Cycle Sherpa thinking level"
  })
  vim.keymap.set("i", "<Esc><Esc>", leave_insert, {
    buffer = buf, nowait = true, silent = true, desc = "Leave insert without sending"
  })

  return buf
end

function M.refresh_compose_hint()
  local session = state.get_session()
  local render = session and session.compose_hint_renderer
  if render then
    render()
  end
end

-- Open the compose window as a horizontal split below an existing log
-- window (or, if the log isn't open, in the bottom-right corner).
-- Focus the compose window and drop into insert.
function M.open_compose(on_send)
  local buf = M.ensure_compose_buffer(on_send)
  local session = state.get_session()

  -- Already visible somewhere? Just focus.
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      M.refresh_compose_winbar()
      vim.api.nvim_set_current_win(win)
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then vim.cmd("startinsert") end
      end)
      return win
    end
  end

  -- Prefer splitting below the log window so they share the right-hand
  -- column. Fall back to botright vsplit if the log isn't visible yet.
  local log_buf = session and session.log_buf
  local log_wins = log_buf and vim.fn.win_findbuf(log_buf) or {}
  if #log_wins > 0 and vim.api.nvim_win_is_valid(log_wins[1]) then
    vim.api.nvim_set_current_win(log_wins[1])
    vim.cmd("belowright split")
  else
    vim.cmd("botright vsplit")
  end

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  -- Compose is a thin input surface; keep it short by default.
  pcall(vim.api.nvim_win_set_height, win, 8)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixheight = true
  M.refresh_compose_winbar()
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then return end
    local last_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
    local last_text = vim.api.nvim_buf_get_lines(buf, last_line - 1, last_line, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, win, { last_line, #last_text })
    vim.cmd("startinsert")
  end)
  return win
end

function M.hide_compose()
  local session = state.get_session()
  close_windows_for_buffer(session and session.compose_buf)
end

-- True if either chat surface (log or compose) has a live window.
-- Used by :SherpaChat to decide between open and hide on the no-args
-- toggle path.
function M.log_is_visible(lane)
  local session = state.get_session(lane)
  local buf = session and session.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      return true
    end
  end
  return false
end

function M.chat_is_visible()
  local session = state.get_session()
  if not session then return false end
  for _, buf in ipairs({ session.log_buf, session.compose_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_is_valid(win) then
          return true
        end
      end
    end
  end
  return false
end

-- Hide both chat surfaces.
function M.hide_chat()
  M.hide_compose()
  M.hide_log()
end

-- Trim the oldest lines from a log buffer when it exceeds the configured
-- max. Removes ~20% of max to avoid trimming on every append. Extmarks on
-- trimmed lines auto-delete.
local function trim_log_buffer(buf)
  local max = state.get_config().log_max_lines
  if not max or max <= 0 then return end
  local count = vim.api.nvim_buf_line_count(buf)
  if count <= max then return end
  local trim = math.floor(max * 0.2)
  vim.api.nvim_buf_set_lines(buf, 0, trim, false, {})
end

function M.append(lines, lane)
  local buf = M.ensure_log_buffer(lane)
  local items = log_lines(lines)
  if #items == 0 then
    return
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
  trim_log_buffer(buf)
  scroll_log_windows(buf)
end

-- Label → highlight group mapping. Labels we don't recognize are left
-- unhighlighted (they still appear in the log, just without color).
local log_label_hl = {
  assistant = log_assistant_hl,
  user = log_user_hl,
  tool = log_tool_hl,
  thinking = log_thinking_hl,
  sherpa = log_tool_hl,
  stderr = log_tool_hl,
  error = log_error_hl,
  plan = log_tool_hl,
  clarify = log_tool_hl,
  diff = log_tool_hl,
  ["review-prompt"] = log_tool_hl,
  ["review-comments"] = log_tool_hl,
}

local function log_turn_rule(_buf)
  -- Markdown thematic break. render-markdown.nvim expands this to a
  -- window-width rule, so we don't need to guess the pane width here.
  return "---"
end

local function log_has_content(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if vim.trim(line) ~= "" then return true end
  end
  return false
end

-- Codex-style verb labels for block headers. Unlisted labels use the
-- raw label name.
local block_verbs = {
  assistant = "",
  user = log_user_prefix,
  thinking = "Thought",
  error = "Error",
  sherpa = "Sherpa",
  tool = "Ran",
  plan = "Plan",
  clarify = "Clarify",
  diff = "Diff",
  ["review-prompt"] = "Review prompt",
  ["review-comments"] = "Review comments",
}

local function diff_content_lines(text)
  local lines = {}
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if line:match("^```") then
      -- Edit diffs used to be wrapped in ```diff fences. Keep this
      -- renderer tolerant so old callers do not leak a visible `diff`
      -- fence label into the log.
    elseif line ~= "" or #lines > 0 then
      table.insert(lines, line)
    end
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

local function diff_line_hl(content)
  if content:match("^%+") and not content:match("^%+%+%+") then
    return log_diff_add_hl, true
  end
  if content:match("^%-") and not content:match("^%-%-%-") then
    return log_diff_remove_hl, true
  end
  if content:match("^%.%.%.") or content:match("^@@") then
    return log_diff_context_hl, false
  end
  return nil, false
end

local function highlight_diff_rows(buf, start_line, items)
  for offset = 0, #items - 1 do
    local row = start_line + offset
    local line_text = items[offset + 1] or ""
    local content = line_text:sub(3)
    local hl_group, full_line = diff_line_hl(content)
    if hl_group then
      pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, 0, {
        end_row = row + 1,
        hl_group = hl_group,
        hl_eol = full_line,
        priority = 8,
      })
    end
  end
end

function M.append_diff(text, lane, opts)
  opts = opts or {}
  ensure_chunk_style()
  local body = diff_content_lines(text)
  if #body == 0 then return end

  local lines = {}
  for _, line in ipairs(body) do
    table.insert(lines, "  " .. line)
  end
  table.insert(lines, "")

  local items = log_lines(lines)
  if #items == 0 then return end

  local buf = M.ensure_log_buffer(lane)
  local start_line
  if opts.insert_at then
    start_line = opts.insert_at
    vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, items)
  else
    start_line = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
  end

  highlight_diff_rows(buf, start_line, items)
  scroll_log_windows(buf)
end

function M.append_block(label, text, lane, opts)
  opts = opts or {}
  ensure_chunk_style()
  local buf = M.ensure_log_buffer(lane)

  -- Codex-style: bullet + bold verb labels plus rule-separated model
  -- turns. User/error turns get subtle panels; assistant text stays plain.
  local lines = {}
  local verb = block_verbs[label]
  if label == "assistant" then
    -- Assistant text flows with no header. When there is already log
    -- content, insert a Codex-style rule to separate model turns.
    if log_has_content(buf) then
      table.insert(lines, "")
      table.insert(lines, log_turn_rule(buf))
      table.insert(lines, "")
    else
      table.insert(lines, "")
    end
  elseif label == "user" then
    -- User input uses a non-markdown prompt glyph. Avoid `>` so the
    -- markdown renderer doesn't turn prompts into blockquotes/code-like
    -- panels or wrap long @image lines strangely.
    table.insert(lines, "")
    local first = true
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      if l == "" then
        table.insert(lines, "")
      else
        table.insert(lines, (first and log_user_prefix or log_user_continuation) .. l)
        first = false
      end
    end
    table.insert(lines, "")
    local items = log_lines(lines)
    if #items == 0 then return end
    local start_line
    if opts.insert_at then
      start_line = opts.insert_at
      vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, items)
    else
      start_line = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
    end
    local end_line = start_line + #items - 1
    log_pin.record_user_message(lane, text, buf, start_line, end_line)
    -- Give the whole user turn a subtle theme-derived panel, then
    -- keep the quoted text foreground stronger above it.
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
      end_row = start_line + #items,
      hl_group = log_user_bg_hl,
      hl_eol = true,
      priority = 3,
    })
    for offset = 1, #items - 1 do
      local row = start_line + offset
      local line_text = items[offset + 1] or ""
      if vim.trim(line_text) ~= "" then
        pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, 0, {
          end_row = row + 1,
          hl_group = log_user_hl,
          priority = 10,
        })
      end
    end
    scroll_log_windows(buf)
    return
  else
    -- Everything else: • Verb header, body indented below.
    local header = verb and verb ~= "" and ("• " .. verb) or ("• " .. label)
    table.insert(lines, "")
    table.insert(lines, header)
  end

  if label ~= "user" then
    local body_lines = label == "diff" and diff_content_lines(text)
      or vim.split(text, "\n", { plain = true })
    for _, l in ipairs(body_lines) do
      table.insert(lines, label == "assistant" and l or ("  " .. l))
    end
  end
  table.insert(lines, "")

  local items = log_lines(lines)
  if #items == 0 then return end

  local start_line
  if opts.insert_at then
    start_line = opts.insert_at
    vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, items)
  else
    start_line = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
  end

  local end_line = start_line + #items - 1

  -- Highlight any turn separator line.
  for offset = 0, #items - 1 do
    local line_text = items[offset + 1] or ""
    if line_text:match("^%-%-%-+$") then
      local row = start_line + offset
      pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, 0, {
        end_row = row + 1,
        hl_group = log_rule_hl,
        hl_eol = true,
        priority = 6,
      })
      break
    end
  end

  -- Highlight the • header line with the label's color.
  local hl = log_label_hl[label]
  if label ~= "assistant" and label ~= "user" then
    -- Find the header row (first non-blank line after start_line)
    for offset = 0, #items - 1 do
      local line_text = items[offset + 1] or ""
      if line_text:sub(1, 3) == "• " then
        local row = start_line + offset
        pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, 0, {
          end_row = row + 1,
          hl_group = hl or log_tool_hl,
          priority = 10,
        })
        break
      end
    end
  end

  -- Thinking gets faint italic on the whole block.
  if label == "thinking" then
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
      end_row = end_line + 1,
      hl_group = log_thinking_hl,
      hl_eol = true,
      priority = 4,
    })
  end

  -- Error gets a dim red background so it's unmissable.
  if label == "error" then
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
      end_row = end_line + 1,
      hl_group = log_error_bg_hl,
      hl_eol = true,
      priority = 5,
    })
  end

  -- Diff line coloring (inside the body, after the header).
  if label == "diff" then
    highlight_diff_rows(buf, start_line, items)
  end

  scroll_log_windows(buf)
end

-- Append a one-line `[tool] <name> <path>[<range>]` log entry with the
-- path + range range substring highlighted distinctly. `range` is an
-- already-formatted suffix like ":1-40" or nil. The tool name keeps
-- the default tool color; only the path/range pops visually.
-- Codex-style verb mapping for tool names.
local tool_verbs = {
  read = "Explored",
  edit = "Edited",
  write = "Wrote",
  bash = "Ran",
  grep = "Explored",
  find = "Explored",
  ls = "Explored",
  subagent = "Delegated",
}

local function highlight_tool_header(buf, row, tool_name, path, suffix)
  local verb = tool_verbs[tool_name] or "Ran"
  pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, 0, {
    end_row = row + 1,
    hl_group = log_tool_hl,
    priority = 10,
  })
  if path and path ~= "" then
    local prefix_len = #("• " .. verb .. " ")
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, prefix_len, {
      end_row = row,
      end_col = prefix_len + #path,
      hl_group = log_path_hl,
      priority = 11,
    })
    if suffix and suffix ~= "" then
      pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, prefix_len + #path, {
        end_row = row,
        end_col = prefix_len + #path + #suffix,
        hl_group = log_diff_stats_hl,
        priority = 11,
      })
    end
  end
end

function M.update_tool_line(row, tool_name, path, suffix, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local buf = session and session.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not row then return end
  local verb = tool_verbs[tool_name] or "Ran"
  local detail = path and path ~= "" and (" " .. path .. (suffix or "")) or ""
  pcall(vim.api.nvim_buf_clear_namespace, buf, log_namespace, row, row + 1)
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { "• " .. verb .. detail })
  highlight_tool_header(buf, row, tool_name, path, suffix)
end

function M.append_tool_line(tool_name, path, range, lane)
  local buf = M.ensure_log_buffer(lane)
  local verb = tool_verbs[tool_name] or "Ran"

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    M.append({ string.format("• %s", verb), string.format("  └ %s %s%s", tool_name, path or "", range or "") }, lane)
    return
  end

  if tool_name == "edit" and path and path ~= "" then
    local start_row = vim.api.nvim_buf_line_count(buf)
    M.append({ string.format("• %s %s", verb, path) }, lane)
    highlight_tool_header(buf, start_row, tool_name, path, nil)
    return
  end

  local header = string.format("• %s", verb)
  local detail = string.format("  └ %s %s%s", tool_name, path or "", range or "")

  local start_row = vim.api.nvim_buf_line_count(buf)
  M.append({ header, detail }, lane)

  -- Bold verb header
  pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_row, 0, {
    end_row = start_row + 1,
    hl_group = log_tool_hl,
    priority = 10,
  })
  -- Highlight the path portion of the detail line
  local path_text = (path or "") .. (range or "")
  if path_text ~= "" then
    local prefix_len = #("  └ " .. tool_name .. " ")
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_row + 1, prefix_len, {
      end_row = start_row + 1,
      end_col = prefix_len + #path_text,
      hl_group = log_path_hl,
      priority = 10,
    })
  end
  -- Mute the tree connector
  pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_row + 1, 0, {
    end_row = start_row + 1,
    end_col = #"  └ ",
    hl_group = log_muted_hl,
    priority = 8,
  })
end

-- Mark the tail of the log so that the matching tool_execution_end can
-- insert its result right after the header instead of at the very end
-- of the buffer. Uses an extmark so row tracking is automatic when
-- other insertions shift lines around.
function M.mark_tool_header(tool_call_id, lane)
  if not tool_call_id then return end
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local buf = session and session.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  -- The header was just appended; the last non-blank row is line_count-2
  -- (append() always keeps a trailing blank).
  local row = math.max(vim.api.nvim_buf_line_count(buf) - 2, 0)
  session.tool_marks[tool_call_id] = vim.api.nvim_buf_set_extmark(
    buf, log_namespace, row, 0, {})
end

-- Consume the extmark for a tool header and return the row where output
-- should be inserted (one past the header). Returns nil when the mark
-- is missing or invalid — callers fall back to normal append.
function M.pop_tool_insert_row(tool_call_id, lane)
  if not tool_call_id then return nil end
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local buf = session and session.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  local marks = session.tool_marks
  local mark_id = marks and marks[tool_call_id]
  if not mark_id then return nil end
  marks[tool_call_id] = nil
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id,
    buf, log_namespace, mark_id, {})
  pcall(vim.api.nvim_buf_del_extmark, buf, log_namespace, mark_id)
  if ok and pos and pos[1] then
    return pos[1] + 1  -- row after the header
  end
  return nil
end

-- Render tool output in the log. Shows only the last TAIL_LINES of the
-- output; when earlier lines are hidden, emits a muted
-- `N earlier lines…` marker BEFORE the block so nothing breaks the
-- syntactic structure of the code inside.
--
-- When `lang` is non-nil, the shown lines are wrapped in a fenced
-- markdown code block with that language tag. The log buffer's
-- markdown filetype + treesitter injection + render-markdown then
-- syntax-highlight the body. When `lang` is nil, the lines render as
-- plain muted text (used by bash / grep / ls / find — heterogeneous
-- output that doesn't map to one language).
--
-- Empty text is skipped (not every tool produces output worth showing).
local TOOL_OUTPUT_TAIL = 15

function M.append_tool_output(text, lang, lane, opts)
  opts = opts or {}
  if type(text) ~= "string" then return end
  local trimmed = vim.trim(text)
  if trimmed == "" then return end

  local session = state.get_session(lane)
  local buf = session and session.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- Single backward pass: find the last meaningful line, stripping
  -- trailing blanks and pi's "[N more lines in file...]" meta lines.
  -- Then compute the tail-start index, all without intermediate tables.
  local all_lines = vim.split(text, "\n", { plain = true })
  local last_meaningful = #all_lines
  while last_meaningful > 0 do
    local line = all_lines[last_meaningful]
    if line == "" or line:match("^%[%d+ more lines in file%..-%]$") then
      last_meaningful = last_meaningful - 1
    else
      break
    end
  end
  if last_meaningful == 0 then return end

  local hidden = math.max(0, last_meaningful - TOOL_OUTPUT_TAIL)
  local tail_start = hidden > 0 and (last_meaningful - TOOL_OUTPUT_TAIL + 1) or 1

  -- Build output lines directly from the computed window.
  local lines = {}
  local marker_offset = nil
  if hidden > 0 then
    lines[#lines + 1] = string.format("%d earlier %s\u{2026}", hidden, hidden == 1 and "line" or "lines")
    marker_offset = #lines - 1
  end
  lines[#lines + 1] = lang and ("```" .. lang) or "```"
  for i = tail_start, last_meaningful do
    lines[#lines + 1] = all_lines[i]
  end
  lines[#lines + 1] = "```"
  lines[#lines + 1] = ""

  local items = log_lines(lines)
  if #items == 0 then return end

  local start_row
  if opts.insert_at then
    start_row = opts.insert_at
    vim.api.nvim_buf_set_lines(buf, start_row, start_row, false, items)
  else
    start_row = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
  end
  scroll_log_windows(buf)

  if marker_offset ~= nil then
    local marker_row = start_row + marker_offset
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, marker_row, 0, {
      end_row = marker_row + 1,
      hl_group = log_tool_output_ellipsis_hl,
      priority = 10,
    })
  end
end

-- Live streaming block: an unformatted region at the tail of the log
-- buffer that receives incremental text (e.g. thinking tokens). When
-- finalized, the raw text is replaced with a properly styled block.

function M.start_live_block(lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return end
  if session.live_block then
    M.finalize_live_block(nil, nil, lane)
  end
  local buf = M.ensure_log_buffer(lane)
  session.live_block = {
    buf = buf,
    start_row = vim.api.nvim_buf_line_count(buf),
    lines_in_buffer = 0,
    pending_text = nil,
    flush_pending = false,
  }
end

-- Idempotent variant: reuse an existing live block if one is already
-- active. Used by text_delta streaming where many deltas share one
-- block, vs start_live_block which force-creates (used by thinking).
function M.ensure_live_block(lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session or session.live_block then return end
  local buf = M.ensure_log_buffer(lane)
  session.live_block = {
    buf = buf,
    start_row = vim.api.nvim_buf_line_count(buf),
    lines_in_buffer = 0,
    pending_text = nil,
    flush_pending = false,
  }
end

local LIVE_BLOCK_THROTTLE_MS = 50

local function flush_live_block(lb)
  local text = lb.pending_text
  lb.pending_text = nil
  lb.flush_pending = false
  if not text then return end
  if not vim.api.nvim_buf_is_valid(lb.buf) then return end

  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines == 0 then return end

  local old_count = lb.lines_in_buffer
  local new_count = #lines

  -- Fast path: only new lines were appended (common during streaming).
  -- Replace the last existing line (it may have grown) and append the
  -- rest, avoiding a full splice of the entire block.
  if new_count > old_count and old_count > 0 then
    -- Update the last old line (it may have received more text)
    vim.api.nvim_buf_set_lines(lb.buf, lb.start_row + old_count - 1, lb.start_row + old_count, false, { lines[old_count] })
    -- Append only the truly new lines
    if new_count > old_count then
      local tail = {}
      for i = old_count + 1, new_count do
        tail[#tail + 1] = lines[i]
      end
      vim.api.nvim_buf_set_lines(lb.buf, lb.start_row + old_count, lb.start_row + old_count, false, tail)
    end
  else
    -- Full replace fallback (content shrunk or first write)
    vim.api.nvim_buf_set_lines(lb.buf, lb.start_row, lb.start_row + old_count, false, lines)
  end

  lb.lines_in_buffer = new_count
  scroll_log_windows(lb.buf)
end

function M.update_live_block(full_text, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local lb = session and session.live_block
  if not lb then return end
  if not vim.api.nvim_buf_is_valid(lb.buf) then return end
  lb.pending_text = full_text
  if lb.flush_pending then return end
  lb.flush_pending = true
  vim.defer_fn(function()
    local s = state.get_session(lane)
    if s and s.live_block == lb then
      flush_live_block(lb)
    end
  end, LIVE_BLOCK_THROTTLE_MS)
end

function M.finalize_live_block(label, text, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return end
  local lb = session.live_block
  session.live_block = nil
  if lb then
    -- Flush any pending throttled content so lines_in_buffer is accurate.
    if lb.pending_text then
      flush_live_block(lb)
    end
    if vim.api.nvim_buf_is_valid(lb.buf) and lb.lines_in_buffer > 0 then
      vim.api.nvim_buf_set_lines(lb.buf, lb.start_row, lb.start_row + lb.lines_in_buffer, false, {})
    end
  end
  if label and text and vim.trim(text) ~= "" then
    M.append_block(label, text, lane)
  end
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
  local session = state.get_session("review")
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
  local session = state.get_session("review")
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

local function progress_buffers(target, lane)
  local bufs = {}
  if target == "review" or target == "both" then
    table.insert(bufs, M.ensure_review_buffer())
  end
  if target == "log" or target == "both" then
    table.insert(bufs, M.ensure_log_buffer(lane))
  end
  return bufs
end

function M.start_activity(title, target, operation, lane)
  local session = state.get_session(lane)
  M.finish_activity(nil, "cancel", lane)
  session.progress = {
    title = title,
    target = target or "log",
    operation = operation,
    -- hrtime is nanoseconds, monotonic. Drives the elapsed-time suffix
    -- in the compose winbar so the user can see the turn is moving
    -- even while the spin label is between rotations.
    started_at = vim.uv.hrtime(),
  }
  for _, buf in ipairs(progress_buffers(session.progress.target, lane)) do
    set_buffer_busy(buf, true)
  end
  -- Keep the one-shot activity echo, but move the rotating status out of the
  -- command area and into the compose header.
  vim.defer_fn(function()
    activity_echo(title)
  end, 10)
  start_spin(session.progress, lane)
end

function M.finish_activity(message, status, lane)
  local session = state.get_session(lane)
  local progress = session and session.progress
  if not progress then
    return
  end
  for _, buf in ipairs(progress_buffers(progress.target, lane)) do
    set_buffer_busy(buf, false)
  end
  activity_echo(message or progress.title)
  session.progress = nil
  stop_spin(lane)
  M.refresh_compose_winbar(lane)
  M.refresh_compose_hint()
end

local editor_ns = vim.api.nvim_create_namespace("sherpa-editor-hint")

-- Open a centered floating scratch editor with ghost-text help.
-- opts: { name, title, hint_lines?, allow_empty?, prefill?, on_cancel? }
--   title is the one-line header shown above the input
--   hint_lines is an optional list of per-command guidance shown as virt_lines
--   allow_empty permits empty submissions (defaults to false)
--   prefill seeds the buffer with initial text (editable before submit)
--   on_cancel is invoked with no args when the user cancels, if set
local function open_scratch_editor(opts, on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  configure_scratch_buffer(buf, "markdown")
  vim.bo[buf].bufhidden = "wipe"

  if opts.prefill and opts.prefill ~= "" then
    local prefill_lines = vim.split(opts.prefill, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, prefill_lines)
  end

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

  local submit_hint = "<C-s> to submit · <Esc><Esc> to cancel"

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
    table.insert(virt_lines, { { submit_hint, "Comment" } })

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
    -- Drop out of insert before closing the float, so the previous
    -- window inherits normal mode instead of staying in insert.
    pcall(vim.cmd, "stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if submit and (text ~= "" or opts.allow_empty) then
      on_submit(text)
    elseif submit then
      notify("Discarded empty Sherpa input", vim.log.levels.WARN)
      if opts.on_cancel then opts.on_cancel() end
    else
      if opts.on_cancel then opts.on_cancel() end
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
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.api.nvim_set_current_win(win)
    local last_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
    local last_text = vim.api.nvim_buf_get_lines(buf, last_line - 1, last_line, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, win, { last_line, #last_text })
    vim.cmd("startinsert")
  end)
end

function M.open_comment_editor(on_submit, opts)
  opts = opts or {}
  open_scratch_editor({
    name = "sherpa://comment",
    title = "Sherpa comment",
    prefill = opts.prefill,
    hint_lines = opts.hint_lines or { "Leave a review comment. Multiple lines are fine." },
  }, on_submit)
end

-- Plan proposal picker. The proposal body is already in the chat log
-- (as a [plan] block, pushed by rpc.lua before this runs). This just
-- asks the user what to do with it.
--
-- Invokes cb with one of:
--   "accept"            — user accepted the proposal as-is
--   "modify"            — user wants to edit; caller handles compose hijack
--   nil                 — user rejected or dismissed the picker
--
-- No floating preview, no editor — everything that needs editing
-- happens in the compose buffer, owned by the caller.
function M.clarify_plan_proposal_picker(cb)
  vim.schedule(function()
    -- Force a redraw so the plan body appended just before this picker
    -- is actually painted on screen. Without this, Neovim can batch
    -- the scheduled callbacks and show the select dialog before the
    -- log buffer visually updates.
    vim.cmd("redraw")
    vim.ui.select({ "Accept", "Modify", "Reject" }, {
      prompt = "Plan proposal — accept, modify, or reject?",
    }, function(choice)
      if choice == "Accept" then
        cb("accept")
      elseif choice == "Modify" then
        cb("modify")
      else
        cb(nil)
      end
    end)
  end)
end

local function reset_buffer_undo(buf)
  vim.bo[buf].undolevels = -1
  vim.bo[buf].undolevels = vim.o.undolevels
end

local function compose_has_text(buf)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if vim.trim(line) ~= "" then
      return true
    end
  end
  return false
end

-- Seed the compose buffer with text. Used by the plan-proposal Modify
-- flow: the user wants to edit the proposed plan in-place, so we drop
-- it into compose and they adjust it before sending. Refuses to
-- overwrite non-empty compose content so we don't stomp on draft text
-- the user was already typing.
function M.seed_compose(text)
  local session = state.get_session()
  local buf = session and session.compose_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  if compose_has_text(buf) then
    notify("Compose has draft text — send or clear it before modifying the proposal.",
      vim.log.levels.WARN)
    return false
  end
  local lines = vim.split(text or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- Reset undo so `u` from the seeded state doesn't unwind the whole
  -- buffer back to empty — consistent with the compose-cleared-on-send
  -- treatment.
  reset_buffer_undo(buf)
  return true
end

-- Prefill compose for :SherpaChat. Empty compose is replaced outright;
-- non-empty compose keeps the user's draft and appends the new context
-- after a blank line so command-line context doesn't stomp on typing.
function M.prefill_compose(text)
  text = text or ""
  if text == "" then return false end
  local session = state.get_session()
  local buf = session and session.compose_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end

  local lines = vim.split(text, "\n", { plain = true })
  if not compose_has_text(buf) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    reset_buffer_undo(buf)
    return true
  end

  local existing = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  while #existing > 0 and existing[#existing] == "" do
    table.remove(existing)
  end
  if #existing > 0 then
    table.insert(existing, "")
  end
  vim.list_extend(existing, lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, existing)
  reset_buffer_undo(buf)
  return true
end

local function normalize_prompt_editor_opts(opts)
  if opts == nil then
    return {}
  end
  if opts.hint_lines ~= nil or opts.prefill ~= nil or opts.allow_empty ~= nil or opts.on_cancel ~= nil then
    return vim.deepcopy(opts)
  end
  return { hint_lines = opts }
end

function M.open_prompt_editor(label, on_submit, opts)
  opts = normalize_prompt_editor_opts(opts)
  open_scratch_editor({
    name = "sherpa://prompt",
    title = label,
    hint_lines = opts.hint_lines,
    prefill = opts.prefill,
    on_cancel = opts.on_cancel,
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
      log_pin.close_for_window(win)
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

function M.hide_review()
  local session = state.get_session("review")
  close_windows_for_buffer(session and session.review_buf)
  if session then
    session.review_win = nil
  end
end

-- Per-buffer checktime guard. checktime is expensive (stat + potential
-- reload). A single stop focus can call get_buffer 3–4 times for the same
-- buffer; skip re-checking within 500ms.
local checktime_stamps = {}
local CHECKTIME_DEBOUNCE_NS = 500e6  -- 500ms

local function refresh_buffer(buf)
  if buf <= 0 or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified then
    return
  end
  local now = vim.uv.hrtime()
  local last = checktime_stamps[buf]
  if last and (now - last) < CHECKTIME_DEBOUNCE_NS then
    return
  end
  checktime_stamps[buf] = now
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.cmd, "silent checktime")
  end)
end

local function clear_chunk_highlight(session)
  if not session then
    return
  end
  local buf = session.highlight_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, chunk_namespace, 0, -1)
  end
  session.chunk_lines = {}
  session.chunk_path = nil
  session.highlight_buf = nil
end

local function hl_attr(group, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok or type(hl) ~= "table" then return nil end
  local value = hl[attr]
  return type(value) == "number" and value or nil
end

local function rgb_channels(color)
  return {
    r = math.floor(color / 65536) % 256,
    g = math.floor(color / 256) % 256,
    b = color % 256,
  }
end

local function blend_to_hex(base, accent, amount)
  local a = rgb_channels(base)
  local b = rgb_channels(accent)
  local function mix(from, to)
    return math.floor(from + (to - from) * amount + 0.5)
  end
  return string.format(
    "#%02x%02x%02x",
    mix(a.r, b.r),
    mix(a.g, b.g),
    mix(a.b, b.b)
  )
end

local function theme_user_log_bg()
  local base = hl_attr("Normal", "bg") or hl_attr("NormalFloat", "bg")
  if not base then return nil end
  local candidates = {
    { "Visual", "bg" },
    { "PmenuSel", "bg" },
    { "CursorLine", "bg" },
    { "Search", "bg" },
    { "Question", "fg" },
    { "Identifier", "fg" },
    { "Normal", "fg" },
  }
  for _, item in ipairs(candidates) do
    local accent = hl_attr(item[1], item[2])
    if accent and accent ~= base then
      return blend_to_hex(base, accent, 0.10)
    end
  end
end

local chunk_style_done = false
ensure_chunk_style = function()
  if chunk_style_done then return end
  chunk_style_done = true
  vim.api.nvim_set_hl(0, added_chunk_hl, { default = true, fg = "#73C991" })
  vim.api.nvim_set_hl(0, removed_chunk_hl, { default = true, fg = "#F14C4C" })
  vim.api.nvim_set_hl(0, comment_hl, { default = true, fg = "#D7BA7D" })
  vim.api.nvim_set_hl(0, annotation_hl, { default = true, link = "Comment" })
  -- Compose winbar activity shimmer. Keep the base text theme-native,
  -- then sweep muted + bright accents across `Working` while a turn runs.
  vim.api.nvim_set_hl(0, compose_working_hl, { default = true, link = "WinBar" })
  vim.api.nvim_set_hl(0, compose_working_soft_hl, { default = true, fg = "#9CA3AF" })
  vim.api.nvim_set_hl(0, compose_working_shine_hl, { default = true, fg = "#73C991", bold = true })
  -- Log pane hierarchy: user messages stand out in blue; assistant
  -- blocks are green so replies are visually distinct from tool output
  -- and rules; tool blocks use normal text.
  vim.api.nvim_set_hl(0, log_assistant_hl, { default = true, fg = "#73C991", bold = true })
  vim.api.nvim_set_hl(0, log_user_hl, { default = true, fg = "#7BB5FF", bold = true })
  vim.api.nvim_set_hl(0, log_tool_hl, { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, log_thinking_hl, { default = true, fg = "#6B7280", italic = true })
  vim.api.nvim_set_hl(0, log_rule_hl, { default = true, link = "NonText" })
  -- Error header stands out: bright red + bold, paired with a dim red
  -- block background so the error block is hard to miss when scanning
  -- the log. Colors match the removed-chunk red already in use above.
  vim.api.nvim_set_hl(0, log_error_hl, { default = true, fg = "#F14C4C", bold = true })
  -- Subtle backgrounds for user and error blocks; assistant blocks
  -- blend in. User bg is derived from the active colorscheme so it
  -- reads like a theme-native panel instead of a fixed color.
  vim.api.nvim_set_hl(0, log_assistant_bg_hl, { default = true, link = "Normal" })
  local user_bg = theme_user_log_bg()
  if user_bg then
    vim.api.nvim_set_hl(0, log_user_bg_hl, { default = true, bg = user_bg })
  else
    vim.api.nvim_set_hl(0, log_user_bg_hl, { default = true, link = "Normal" })
  end
  vim.api.nvim_set_hl(0, log_error_bg_hl, { default = true, bg = "#361a1a" })
  -- Diff rows should read like Codex's transcript diffs: changed lines
  -- get quiet full-width red/green bands, while context stays on the
  -- normal log background instead of inheriting noisy syntax colors.
  vim.api.nvim_set_hl(0, log_diff_add_hl, { default = true, bg = "#1f3326" })
  vim.api.nvim_set_hl(0, log_diff_remove_hl, { default = true, bg = "#3a2024" })
  vim.api.nvim_set_hl(0, log_diff_context_hl, { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, log_diff_stats_hl, { default = true, link = "NonText" })
  -- Paths in tool headers (e.g. after `[tool] read`) stand out so the
  -- eye finds the target quickly when scanning the transcript.
  vim.api.nvim_set_hl(0, log_path_hl, { default = true, fg = "#7BB5FF" })
  -- Muted annotations like `(+N more lines)` / `Took 0.8s`.
  vim.api.nvim_set_hl(0, log_muted_hl, { default = true, link = "NonText" })
  -- Inlined tool output (stdout from bash, read contents, grep matches,
  -- etc.) reads as secondary text — quieter than the thinking/rule
  -- tones but still legible. Italicize the `… N more lines …` separator
  -- so it stands out from the surrounding content at the same muted
  -- intensity.
  vim.api.nvim_set_hl(0, log_tool_output_hl, { default = true, fg = "#9CA3AF" })
  vim.api.nvim_set_hl(0, log_tool_output_ellipsis_hl, {
    default = true, fg = "#6B7280", italic = true,
  })
end

local highlight_augroup = vim.api.nvim_create_augroup("SherpaHighlights", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = highlight_augroup,
  callback = function()
    chunk_style_done = false
    ensure_chunk_style()
  end,
})

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

function M.highlight_lines(path, lines, lane)
  local session = state.get_session(lane) or state.ensure_session(lane or "main", vim.fn.getcwd())
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

function M.highlight_range(path, first_line, last_line, lane)
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
  M.highlight_lines(path, lines, lane)
end

-- Wrap a text blob into roughly `width`-char lines. Splits on whitespace;
-- a single long word stays unbroken rather than getting arbitrarily cut.
local function wrap_text(text, width)
  width = width or 78
  local out = {}
  for raw_line in string.gmatch(text or "", "[^\n]*") do
    if raw_line == "" then
      table.insert(out, "")
    else
      local current = ""
      for word in string.gmatch(raw_line, "%S+") do
        if current == "" then
          current = word
        elseif #current + 1 + #word <= width then
          current = current .. " " .. word
        else
          table.insert(out, current)
          current = word
        end
      end
      if current ~= "" then
        table.insert(out, current)
      end
    end
  end
  return out
end

-- Buffers that received annotation extmarks. Tracked so clear only touches
-- the 1–2 buffers that actually have marks instead of every loaded buffer.
local annotated_bufs = {}

function M.clear_stop_annotations()
  for buf in pairs(annotated_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, annotation_namespace, 0, -1)
    end
  end
  annotated_bufs = {}
end

-- Render annotations for a single plan stop. `item` is a stop from the
-- review plan; it may carry `explanation` (rendered as a block above the
-- stop's startLine) and `annotations` (optional extras). See stop schema
-- in pi/sherpa-stepper.ts for the shape.
--
-- Caller is responsible for clearing prior annotations first.
function M.set_stop_annotations(item)
  if not item or not item.path then
    return
  end
  local buf = get_buffer(item.path)
  if not buf then
    return
  end
  ensure_chunk_style()
  annotated_bufs[buf] = true

  local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local stop_start = math.min(math.max(tonumber(item.startLine) or 1, 1), max_line)
  local stop_end = math.min(math.max(tonumber(item.endLine) or stop_start, stop_start), max_line)

  -- Default block: the stop's `explanation`, usually pinned above the
  -- stop's first line. For line-1 anchors, render below instead: an
  -- above-the-first-line block exists in extmark data but does not become
  -- visible in the window, so the first stop in a file appears to have no
  -- inline help.
  local function render_block(anchor_line, text)
    if not text or text == "" then
      return
    end
    local virt_lines = {}
    table.insert(virt_lines, { { "┌─ sherpa ─────────────────────", annotation_hl } })
    for _, line in ipairs(wrap_text(text, 78)) do
      table.insert(virt_lines, { { "│ " .. line, annotation_hl } })
    end
    table.insert(virt_lines, { { "└──────────────────────────────", annotation_hl } })
    pcall(vim.api.nvim_buf_set_extmark, buf, annotation_namespace, anchor_line - 1, 0, {
      virt_lines = virt_lines,
      virt_lines_above = anchor_line > 1,
      priority = 40,
    })
  end

  local function render_line_annotation(line_no, text)
    if not text or text == "" then
      return
    end
    local target = math.min(math.max(tonumber(line_no) or stop_start, stop_start), stop_end)
    pcall(vim.api.nvim_buf_set_extmark, buf, annotation_namespace, target - 1, 0, {
      virt_text = { { "  ◂ " .. text, annotation_hl } },
      virt_text_pos = "eol",
      priority = 40,
    })
  end

  if item.explanation and item.explanation ~= "" then
    render_block(stop_start, item.explanation)
  end

  for _, ann in ipairs(item.annotations or {}) do
    if ann.kind == "block" then
      local s = tonumber(ann.startLine)
      if s then
        local anchor = math.min(math.max(s, stop_start), stop_end)
        render_block(anchor, ann.text)
      end
    elseif ann.kind == "line" then
      render_line_annotation(ann.line, ann.text)
    end
  end
end

function M.clear_comment_markers()
  local session = state.get_session("review")
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
  local session = state.get_session("review")
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

function M.notify(message, level)
  notify(message, level)
end

return M
