local clipboard = require("sherpa.clipboard")
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
local log_thinking_hl = "SherpaLogThinking"
local log_rule_hl = "SherpaLogRule"
local log_error_hl = "SherpaLogError"
local log_path_hl = "SherpaLogPath"
local log_muted_hl = "SherpaLogMuted"
local log_tool_output_hl = "SherpaLogToolOutput"
local log_tool_output_ellipsis_hl = "SherpaLogToolOutputEllipsis"
local log_assistant_bg_hl = "SherpaLogAssistantBg"
local log_user_bg_hl = "SherpaLogUserBg"
local log_error_bg_hl = "SherpaLogErrorBg"
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
    "Sherpa is gaining altitude...",
    "Sherpa is navigating the crevasse...",
    "Sherpa is reading the terrain...",
    "Sherpa is securing the belay...",
    "Sherpa is traversing the glacier...",
    "Sherpa is finding a foothold...",
  },
  plan = {
    "Sherpa is scouting the route...",
    "Sherpa is checking the map...",
    "Sherpa is marking the next stop...",
    "Sherpa is laying out the route...",
    "Sherpa is plotting waypoints...",
    "Sherpa is measuring the distance...",
    "Sherpa is charting the ascent...",
    "Sherpa is surveying base camp...",
    "Sherpa is calculating the grade...",
    "Sherpa is penciling in the camps...",
    "Sherpa is sketching the approach...",
    "Sherpa is noting the hazards...",
  },
  patch = {
    "Sherpa is placing the pitons...",
    "Sherpa is trimming the route...",
    "Sherpa is tightening the seam...",
    "Sherpa is making a careful local move...",
    "Sherpa is adjusting the anchor...",
    "Sherpa is threading the rope...",
    "Sherpa is resetting the cam...",
    "Sherpa is fine-tuning the stance...",
    "Sherpa is clipping the quickdraw...",
    "Sherpa is cinching the knot...",
    "Sherpa is repositioning the gear...",
    "Sherpa is patching the fixed line...",
  },
  search = {
    "Sherpa is scanning the trail...",
    "Sherpa is checking the landmarks...",
    "Sherpa is tracing the path...",
    "Sherpa is spotting likely matches...",
    "Sherpa is looking for cairns...",
    "Sherpa is glassing the ridge...",
    "Sherpa is following the bootpack...",
    "Sherpa is sweeping the valley...",
    "Sherpa is tracking the markers...",
    "Sherpa is peering through the fog...",
    "Sherpa is checking each switchback...",
    "Sherpa is hunting for the blaze...",
  },
  review = {
    "Sherpa is walking the route...",
    "Sherpa is pointing out the key ledges...",
    "Sherpa is explaining the terrain...",
    "Sherpa is highlighting the tricky bit...",
    "Sherpa is narrating the ascent...",
    "Sherpa is describing the crux...",
    "Sherpa is reviewing the beta...",
    "Sherpa is recapping the sequence...",
    "Sherpa is stepping through the moves...",
    "Sherpa is showing the holds...",
    "Sherpa is annotating the topo...",
    "Sherpa is guiding you through...",
  },
  prompt = {
    "Sherpa is thinking...",
    "Sherpa is tracing the code...",
    "Sherpa is drafting a reply...",
    "Sherpa is lining up the next move...",
    "Sherpa is pondering the approach...",
    "Sherpa is considering options...",
    "Sherpa is gathering thoughts...",
    "Sherpa is working it out...",
    "Sherpa is reading the wall...",
    "Sherpa is planning the sequence...",
    "Sherpa is mapping the logic...",
    "Sherpa is studying the problem...",
  },
  q = {
    "Sherpa is tracing the tangent...",
    "Sherpa is checking the side trail...",
    "Sherpa is working through the tangent...",
    "Sherpa is following the detour...",
    "Sherpa is inspecting the side path...",
    "Sherpa is mapping the tangent...",
  },
}
local activity_prefixes = {
  plan = "Plan",
  patch = "Patch",
  prompt = "Chat",
  q = "Q",
  review = "Review",
  search = "Search",
}
local spin_states = {}

local function normalize_lane(lane)
  return state.normalize_lane(lane)
end

local function spin_state(lane)
  lane = normalize_lane(lane)
  spin_states[lane] = spin_states[lane] or {
    index = 0,
    tick_count = 0,
    timer = nil,
  }
  return spin_states[lane], lane
end

local function activity_echo(message)
  return pcall(vim.api.nvim_echo, { { "sherpa: " .. message } }, false, {})
end

local function activity_labels(operation)
  return spin_labels[operation] or spin_labels.default
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

local function compose_status_line(progress, lane)
  local session = state.get_session(lane)
  local statuses = session and session.status or {}
  local clarify_badge = statuses["sherpa-clarify"]
  -- Clarify takes visual precedence — the model is actively waiting on
  -- an answer, which blocks everything else. Tangent badge still shows
  -- when no clarify is pending.
  local prefix = ""
  local idle_msg = nil
  if clarify_badge and clarify_badge ~= "" then
    prefix = "[Clarify] "
    idle_msg = "Sherpa is asking — type your answer (<Esc><Esc> to reject)."
  end
  if not progress then
    if idle_msg then return prefix .. idle_msg end
    return "Chat: Sherpa is ready."
  end
  local op_prefix = activity_prefixes[progress.operation] or "Sherpa"
  local label = progress.spin_label or activity_labels(progress.operation)[1]
  local elapsed = format_elapsed(progress.started_at)
  local left = string.format("%s%s: %s", prefix, op_prefix, label)
  if elapsed then
    return left, elapsed
  end
  return left
end

function M.refresh_compose_winbar(lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local buf = session and session.compose_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local left, right = compose_status_line(session and session.progress, lane)
  left = left:gsub("%%", "%%%%")
  local value = right
    and (left .. "%=" .. right:gsub("%%", "%%%%"))
    or left
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(function() vim.wo[win].winbar = value end)
    end
  end
end

-- Ticks run every SPIN_INTERVAL_MS; every Nth tick rotates the spin
-- label to the next one. Between rotations, the winbar still refreshes
-- (so the elapsed-time suffix updates smoothly) but the label stays
-- put. That keeps the label readable while the timer feels alive.
local SPIN_INTERVAL_MS = 1000
local SPIN_ROTATE_EVERY = 2   -- 2 * 1000ms = 2s per label

local function spin_tick(lane)
  local spin = spin_state(lane)
  local session = state.get_session(lane)
  local progress = session and session.progress
  if not progress then
    stop_spin(lane)
    return
  end
  spin.tick_count = spin.tick_count + 1
  if spin.tick_count % SPIN_ROTATE_EVERY ~= 0 then
    -- Label unchanged; just refresh the winbar so the elapsed updates.
    M.refresh_compose_winbar(lane)
    return
  end
  local labels = activity_labels(progress.operation)
  spin.index = (spin.index % #labels) + 1
  progress.spin_label = labels[spin.index]
  M.refresh_compose_winbar(lane)
end

local function start_spin(progress, lane)
  local spin = spin_state(lane)
  stop_spin(lane)
  local labels = activity_labels(progress and progress.operation)
  spin.index = 1
  if progress then
    progress.spin_label = labels[spin.index]
  end
  M.refresh_compose_winbar(lane)
  spin.tick_count = 0
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

local function scroll_log_windows(buf)
  local last = math.max(vim.api.nvim_buf_line_count(buf), 1)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    end
  end
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
    if trimmed ~= "" and not trimmed:match("^Sherpa operation:") and not trimmed:match("^Sherpa: idle$") and not trimmed:match("^Use ") and not trimmed:match("^Waiting for ") and not trimmed:match("^Mode:") and not trimmed:match("^Last ") then
      table.insert(parts, trimmed)
    end
  end
  if #parts == 0 then
    return "Sherpa"
  end
  -- %#Normal# keeps it plain; escape `%` so winbar formatting doesn't
  -- interpret our payload as a statusline directive.
  local joined = table.concat(parts, " · "):gsub("%%", "%%%%")
  return joined
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
  local previous = opts.preserve_focus and (target_window() or vim.api.nvim_get_current_win()) or nil
  local buf = M.ensure_log_buffer(lane)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      if not opts.preserve_focus then
        vim.api.nvim_set_current_win(win)
      end
      scroll_log_windows(buf)
      M.refresh_log_winbar(lane)
      return
    end
  end
  -- Log opens as a right-hand vertical split. Compose window, if opened,
  -- stacks below the log in that same vertical column.
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  -- conceallevel is window-local. render-markdown.nvim and markdown's
  -- built-in syntax rely on it to hide fence markers / inline markers.
  -- Set it on the log window so fenced tool output renders cleanly.
  pcall(function()
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "nc"
  end)
  scroll_log_windows(buf)
  M.refresh_log_winbar(lane)
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
        virt_text = { { "Type a message · <C-v> screenshot · <C-s> to send", "Comment" } },
        virt_text_pos = "overlay",
      })
    end
  end

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

function M.append(lines, lane)
  local buf = M.ensure_log_buffer(lane)
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

function M.append_block(label, text, lane, opts)
  opts = opts or {}
  ensure_chunk_style()
  local buf = M.ensure_log_buffer(lane)

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

  local start_line
  if opts.insert_at then
    start_line = opts.insert_at
    vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, items)
  else
    start_line = vim.api.nvim_buf_line_count(buf)
    -- ensure_log_buffer keeps the buffer non-empty with a trailing blank,
    -- but we always append — so start_line is where the header lands.
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
  end

  -- Block-wide styling. User/assistant get subtle backgrounds; thinking gets
  -- a faint foreground treatment across the whole block so it reads as
  -- secondary/internal text rather than another full-strength answer.
  local end_line = start_line + #items - 1
  if label == "assistant" or label == "user" then
    local bg_hl = label == "user" and log_user_bg_hl or log_assistant_bg_hl
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
      end_row = end_line + 1,
      hl_group = bg_hl,
      hl_eol = true,
      priority = 5,
    })
  elseif label == "error" then
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
      end_row = end_line + 1,
      hl_group = log_error_bg_hl,
      hl_eol = true,
      priority = 5,
    })
  elseif label == "thinking" then
    pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
      end_row = end_line + 1,
      hl_group = log_thinking_hl,
      hl_eol = true,
      priority = 4,
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

-- Append a one-line `[tool] <name> <path>[<range>]` log entry with the
-- path + range range substring highlighted distinctly. `range` is an
-- already-formatted suffix like ":1-40" or nil. The tool name keeps
-- the default tool color; only the path/range pops visually.
function M.append_tool_line(tool_name, path, range, lane)
  local session = state.get_session(lane)
  local buf = session and session.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    -- Fall back to plain append so we don't silently lose the line;
    -- the log buffer may not exist yet during very early dispatches.
    local line = string.format("[tool] %s %s%s", tool_name, path or "",
      range or "")
    M.append({ line }, lane)
    return
  end

  local prefix = string.format("[tool] %s ", tool_name)
  local path_text = path or ""
  local range_text = range or ""
  local full_line = prefix .. path_text .. range_text

  local start_row = vim.api.nvim_buf_line_count(buf)
  M.append({ full_line }, lane)

  -- The line we just appended sits one above the trailing blank that
  -- `M.append` keeps at end-of-buffer; its row is start_row.
  local path_start_col = #prefix
  local path_end_col = path_start_col + #path_text + #range_text
  pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_row, path_start_col, {
    end_row = start_row,
    end_col = path_end_col,
    hl_group = log_path_hl,
    priority = 10,
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

  local all_lines = vim.split(text, "\n", { plain = true })
  -- Strip a single trailing empty line that most text tools emit, but
  -- preserve genuine blank lines inside the output.
  if all_lines[#all_lines] == "" then
    all_lines[#all_lines] = nil
  end
  -- Pi's read tool appends a trailing meta line like
  --   `[24 more lines in file. Use offset=31 to continue.]`
  -- when the read was truncated. It's useful prose for a transcript
  -- but it's NOT code — if we leave it in and fence the block, the
  -- language parser tries to parse it as code. Strip it (and any
  -- trailing blanks it sits next to); our own `N earlier lines…`
  -- marker conveys the same "there's more you're not seeing" signal.
  while #all_lines > 0 do
    local last = all_lines[#all_lines]
    if last == "" then
      all_lines[#all_lines] = nil
    elseif last:match("^%[%d+ more lines in file%..-%]$") then
      all_lines[#all_lines] = nil
    else
      break
    end
  end
  if #all_lines == 0 then return end

  local hidden = math.max(0, #all_lines - TOOL_OUTPUT_TAIL)
  local shown
  if hidden > 0 then
    shown = vim.list_slice(all_lines, #all_lines - TOOL_OUTPUT_TAIL + 1, #all_lines)
  else
    shown = all_lines
  end

  -- Assemble lines to append. Order:
  --   1. Optional pre-fence marker: `N earlier lines…`
  --   2. Optional fence open (``` + lang)
  --   3. Shown lines
  --   4. Optional fence close (```)
  --   5. Trailing blank for visual separation
  local lines = {}
  local marker_offset = nil  -- 0-based row offset of the marker within `lines`
  if hidden > 0 then
    table.insert(lines, string.format("%d earlier %s…", hidden, hidden == 1 and "line" or "lines"))
    marker_offset = #lines - 1
  end
  table.insert(lines, lang and ("```" .. lang) or "```")
  for _, l in ipairs(shown) do table.insert(lines, l) end
  table.insert(lines, "```")
  table.insert(lines, "")

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

  -- Style the `N earlier lines…` marker as italic muted so it reads
  -- like a note rather than code / prose.
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
  }
end

function M.update_live_block(full_text, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local lb = session and session.live_block
  if not lb then return end
  if not vim.api.nvim_buf_is_valid(lb.buf) then return end
  local lines = vim.split(full_text or "", "\n", { plain = true })
  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines == 0 then return end
  vim.api.nvim_buf_set_lines(lb.buf, lb.start_row, lb.start_row + lb.lines_in_buffer, false, lines)
  lb.lines_in_buffer = #lines
  scroll_log_windows(lb.buf)
end

function M.finalize_live_block(label, text, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return end
  local lb = session.live_block
  session.live_block = nil
  if lb and vim.api.nvim_buf_is_valid(lb.buf) and lb.lines_in_buffer > 0 then
    vim.api.nvim_buf_set_lines(lb.buf, lb.start_row, lb.start_row + lb.lines_in_buffer, false, {})
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

local function refresh_buffer(buf)
  if buf <= 0 or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified then
    return
  end
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

ensure_chunk_style = function()
  vim.api.nvim_set_hl(0, added_chunk_hl, { default = true, fg = "#73C991" })
  vim.api.nvim_set_hl(0, removed_chunk_hl, { default = true, fg = "#F14C4C" })
  vim.api.nvim_set_hl(0, comment_hl, { default = true, fg = "#D7BA7D" })
  vim.api.nvim_set_hl(0, annotation_hl, { default = true, link = "Comment" })
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
  -- Subtle background for user and error blocks; assistant blocks
  -- blend in. Error background is a dim red in the same darkness
  -- range as the user block's slate blue.
  vim.api.nvim_set_hl(0, log_assistant_bg_hl, { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, log_user_bg_hl, { default = true, bg = "#1a2536" })
  vim.api.nvim_set_hl(0, log_error_bg_hl, { default = true, bg = "#361a1a" })
  -- Diff lines in tool-output [diff] blocks. Mirror the gutter-sign
  -- palette so the two surfaces agree: green for added, red for
  -- removed, dim for context.
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
