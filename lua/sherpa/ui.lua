local state = require("sherpa.state")

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
local log_rule_hl = "SherpaLogRule"
local log_assistant_bg_hl = "SherpaLogAssistantBg"
local log_user_bg_hl = "SherpaLogUserBg"
local close_windows_for_buffer
local target_window
-- Forward declaration — defined later, referenced by append_block.
local ensure_chunk_style

local spin_labels = {
  default = {
    "Sherpa is climbing...",
    "Sherpa is scouting the route...",
    "Sherpa is checking the map...",
    "Sherpa is crossing the ridge...",
    "Sherpa is setting the ropes...",
    "Sherpa is almost there...",
  },
  patch = {
    "Sherpa is placing the pitons...",
    "Sherpa is trimming the route...",
    "Sherpa is tightening the seam...",
    "Sherpa is making a careful local move...",
  },
  search = {
    "Sherpa is scanning the trail...",
    "Sherpa is checking the landmarks...",
    "Sherpa is tracing the path...",
    "Sherpa is spotting likely matches...",
  },
  review = {
    "Sherpa is walking the route...",
    "Sherpa is pointing out the key ledges...",
    "Sherpa is explaining the terrain...",
    "Sherpa is highlighting the tricky bit...",
  },
  prompt = {
    "Sherpa is climbing...",
    "Sherpa is hauling the gear...",
    "Sherpa is finding the next hold...",
    "Sherpa is making steady progress...",
  },
}
local spin_index = 0
local spin_timer = nil

local function activity_echo(message)
  return pcall(vim.api.nvim_echo, { { "sherpa: " .. message } }, false, {})
end

local function stop_spin()
  if spin_timer then
    spin_timer:stop()
    spin_timer:close()
    spin_timer = nil
  end
end

local function spin_tick()
  local session = state.get_session()
  local progress = session and session.progress
  if not progress then
    return
  end
  local labels = spin_labels[progress.operation] or spin_labels.default
  spin_index = (spin_index % #labels) + 1
  local label = labels[spin_index]
  local message = string.format("%s · %s", progress.title, label)
  local ok = activity_echo(message)
  if ok then
    return
  end
  M.append({ "[sherpa] " .. label })
end

local function start_spin()
  stop_spin()
  spin_index = 0
  spin_timer = vim.uv.new_timer()
  -- First tick fires immediately so the status line updates as soon as
  -- the activity starts — not 250ms later (which can lose to nvim redraws
  -- after closing a floating prompt window).
  spin_timer:start(0, 3000, vim.schedule_wrap(function()
    spin_tick()
  end))
end

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
  configure_scratch_buffer(buf, "markdown")
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

function M.open_log(opts)
  opts = opts or {}
  local previous = opts.preserve_focus and (target_window() or vim.api.nvim_get_current_win()) or nil
  local buf = M.ensure_log_buffer()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      if not opts.preserve_focus then
        vim.api.nvim_set_current_win(win)
      end
      scroll_log_windows(buf)
      return
    end
  end
  -- Log opens as a right-hand vertical split. Compose window, if opened,
  -- stacks below the log in that same vertical column.
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  scroll_log_windows(buf)
  if previous and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
end

function M.hide_log()
  local session = state.get_session()
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
  vim.bo[buf].filetype = "markdown"
  session.compose_buf = buf

  local function render_hint()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, compose_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local is_empty = (#lines == 0) or (#lines == 1 and lines[1] == "")
    if is_empty then
      pcall(vim.api.nvim_buf_set_extmark, buf, compose_ns, 0, 0, {
        virt_text = { { "Type a message · <C-s> to send", "Comment" } },
        virt_text_pos = "overlay",
      })
    end
  end

  render_hint()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = render_hint,
  })

  local function send_compose()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      notify("Nothing to send — type a message first", vim.log.levels.WARN)
      return
    end
    -- Remember where focus was before dispatch. send() may open the
    -- log as a side effect; we want to return to compose afterward so
    -- the user can keep typing the next message.
    local compose_wins = vim.fn.win_findbuf(buf)
    local compose_win = compose_wins[1]

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
    if compose_win and vim.api.nvim_win_is_valid(compose_win) then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(compose_win) then
          vim.api.nvim_set_current_win(compose_win)
          vim.cmd("startinsert")
        end
      end)
    end
  end

  local function leave_insert()
    pcall(vim.cmd, "stopinsert")
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", send_compose, {
    buffer = buf, nowait = true, silent = true, desc = "Send Sherpa compose"
  })
  vim.keymap.set("i", "<Esc><Esc>", leave_insert, {
    buffer = buf, nowait = true, silent = true, desc = "Leave insert without sending"
  })

  return buf
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
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then vim.cmd("startinsert") end
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

function M.append(lines)
  local buf = M.ensure_log_buffer()
  local items = log_lines(lines)
  if #items == 0 then
    return
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
  scroll_log_windows(buf)
end

-- Label → highlight group mapping. Labels we don't recognize are left
-- unhighlighted (they still appear in the log, just without color).
local log_label_hl = {
  assistant = log_assistant_hl,
  user = log_user_hl,
  tool = log_tool_hl,
  sherpa = log_tool_hl,
  stderr = log_tool_hl,
  ["review-prompt"] = log_tool_hl,
  ["review-comments"] = log_tool_hl,
}

function M.append_block(label, text)
  ensure_chunk_style()
  local buf = M.ensure_log_buffer()

  -- Thin rule above every block makes it easy to scan past tool-call
  -- noise when looking for the most recent assistant answer. Match pi's
  -- visual rhythm (color-distinct block heads, quiet separators).
  local rule = string.rep("─", 60)
  local header = string.format("── [%s] %s", label, string.rep("─", math.max(60 - 5 - #label, 1)))
  local lines = { rule ~= header and "" or "" }
  -- Use only one rule-styled header line rather than a separate rule +
  -- header. Keeps the log tight.
  lines = { header }
  vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  table.insert(lines, "")

  local items = log_lines(lines)
  if #items == 0 then
    return
  end

  local start_line = vim.api.nvim_buf_line_count(buf)
  -- ensure_log_buffer keeps the buffer non-empty with a trailing blank,
  -- but we always append — so start_line is where the header lands.
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)

  -- Background highlight for entire block (user/assistant only)
  local end_line = start_line + #items - 1
  if label == "assistant" or label == "user" then
    local bg_hl = label == "user" and log_user_bg_hl or log_assistant_bg_hl
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
      end_row = end_line + 1,
      hl_group = bg_hl,
      hl_eol = true,
      priority = 5,
    })
  end

  -- Header foreground (higher priority than background)
  local hl = log_label_hl[label]
  if hl then
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
      end_row = start_line + 1,
      hl_group = hl,
      priority = 10,
    })
  end
  -- Rule characters (anything after the label in the header line) get
  -- their own dim color so the header visually "trails off".
  pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
    end_row = start_line,
    end_col = 0,
    hl_group = log_rule_hl,
    priority = 5,
  })

  scroll_log_windows(buf)
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

function M.start_activity(title, target, operation)
  local session = state.get_session()
  M.finish_activity(nil, "cancel")
  session.progress = {
    title = title,
    target = target or "log",
    operation = operation,
  }
  for _, buf in ipairs(progress_buffers(session.progress.target)) do
    set_buffer_busy(buf, true)
  end
  -- Defer briefly so the echo lands *after* any nvim redraw caused by a
  -- just-closed floating prompt window. Without the defer, the echo can
  -- get wiped by the post-close redraw and only reappear on the next
  -- spin tick.
  vim.defer_fn(function()
    activity_echo(title)
  end, 10)
  start_spin()
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
  activity_echo(message or progress.title)
  session.progress = nil
  stop_spin()
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

-- Open a floating editor for clarification. Passes a single callback
-- that receives either the submitted text or `nil` on cancel.
function M.open_clarify_editor(title, prefill, cb)
  local delivered = false
  local function deliver(value)
    if delivered then return end
    delivered = true
    cb(value)
  end
  open_scratch_editor({
    name = "sherpa://clarify",
    title = title or "Sherpa clarify",
    prefill = prefill,
    hint_lines = {
      "Sherpa is asking for clarification. Edit or reply below.",
      "Submit to answer · Cancel to decline.",
    },
    allow_empty = false,
    on_cancel = function() deliver(nil) end,
  }, function(text) deliver(text) end)
end

-- Plan-proposal clarify flow. Three steps:
--   1. Read-only preview of the proposed plan in a floating window.
--   2. vim.ui.select picker: Accept / Modify / Reject.
--   3. On Modify, open the existing clarify editor prefilled with the plan.
--
-- cb(value) on accept or modify-submit; cb(nil) on reject or cancel.
function M.clarify_plan_proposal(title, body, cb)
  local delivered = false
  local function deliver(value)
    if delivered then return end
    delivered = true
    cb(value)
  end

  -- Preview window — read-only markdown view of the proposal. Sits on
  -- screen while the user reads and picks; closes before any follow-up
  -- editor opens so the float doesn't stack.
  local preview_buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, preview_buf, "sherpa://plan-proposal")
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].swapfile = false
  vim.bo[preview_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, vim.split(body or "", "\n", { plain = true }))
  vim.bo[preview_buf].modifiable = false
  vim.bo[preview_buf].bufhidden = "wipe"

  local ui_info = vim.api.nvim_list_uis()[1] or { width = 120, height = 30 }
  local width = math.min(100, math.max(60, math.floor(ui_info.width * 0.7)))
  local height = math.min(24, math.max(10, math.floor(ui_info.height * 0.6)))
  local row = math.floor((ui_info.height - height) / 2)
  local col = math.floor((ui_info.width - width) / 2)

  local preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    title = string.format(" Proposed plan — %s ", title or "Sherpa"),
    title_pos = "center",
    style = "minimal",
  })
  vim.wo[preview_win].wrap = true
  vim.wo[preview_win].linebreak = true
  vim.wo[preview_win].cursorline = false
  vim.wo[preview_win].winhighlight = "NormalFloat:Normal,FloatBorder:FloatBorder"

  local function close_preview()
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_win_close, preview_win, true)
    end
  end

  -- Picker runs in the next scheduler tick so the preview paints first.
  vim.schedule(function()
    vim.ui.select({ "Accept", "Modify", "Reject" }, {
      prompt = "Plan proposal — accept, modify, or reject?",
    }, function(choice)
      if choice == "Accept" then
        close_preview()
        deliver(body or "")
      elseif choice == "Modify" then
        close_preview()
        -- Hand the proposal to the standard clarify editor for in-place
        -- editing. Submit sends the edited text; cancel rejects.
        M.open_clarify_editor(title or "Modify proposed plan", body or "", function(edited)
          deliver(edited)
        end)
      else
        -- Reject or picker cancelled.
        close_preview()
        deliver(nil)
      end
    end)
  end)
end

function M.open_prompt_editor(label, on_submit, hint_lines)
  open_scratch_editor({
    name = "sherpa://prompt",
    title = label,
    hint_lines = hint_lines,
  }, on_submit)
end

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

ensure_chunk_style = function()
  vim.api.nvim_set_hl(0, added_chunk_hl, { default = true, fg = "#73C991" })
  vim.api.nvim_set_hl(0, removed_chunk_hl, { default = true, fg = "#F14C4C" })
  vim.api.nvim_set_hl(0, comment_hl, { default = true, fg = "#D7BA7D" })
  vim.api.nvim_set_hl(0, annotation_hl, { default = true, link = "Comment" })
  -- Log pane hierarchy: user messages stand out in blue; assistant and
  -- tool blocks use normal text so user input is visually primary.
  vim.api.nvim_set_hl(0, log_assistant_hl, { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, log_user_hl, { default = true, fg = "#7BB5FF", bold = true })
  vim.api.nvim_set_hl(0, log_tool_hl, { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, log_rule_hl, { default = true, link = "NonText" })
  -- Subtle background for user blocks only; assistant blocks blend in.
  vim.api.nvim_set_hl(0, log_assistant_bg_hl, { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, log_user_bg_hl, { default = true, bg = "#1a2536" })
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

-- Clear all sherpa annotations across all buffers that have any. We don't
-- track which buffers received extmarks in this namespace — just walk all
-- loaded buffers and clear. Extmarks are per-buffer so this is cheap.
function M.clear_stop_annotations()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, annotation_namespace, 0, -1)
    end
  end
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

  local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local stop_start = math.min(math.max(tonumber(item.startLine) or 1, 1), max_line)
  local stop_end = math.min(math.max(tonumber(item.endLine) or stop_start, stop_start), max_line)

  -- Default block: the stop's `explanation`, pinned above the stop's
  -- first line. virt_lines_above renders on the line *of* the anchor.
  local function render_block_above(anchor_line, text)
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
      virt_lines_above = true,
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
    render_block_above(stop_start, item.explanation)
  end

  for _, ann in ipairs(item.annotations or {}) do
    if ann.kind == "block" then
      local s = tonumber(ann.startLine)
      if s then
        local anchor = math.min(math.max(s, stop_start), stop_end)
        render_block_above(anchor, ann.text)
      end
    elseif ann.kind == "line" then
      render_line_annotation(ann.line, ann.text)
    end
  end
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
