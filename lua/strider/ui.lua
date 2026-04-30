local chat_card = require("strider.ui.chat_card")
local clipboard = require("strider.clipboard")
local flow_cards = require("strider.ui.flow_cards")
local highlights = require("strider.ui.highlights")
local log_diff = require("strider.log.diff")
local log_pin = require("strider.log_pin")
local log_follow = require("strider.ui.log_follow")
local live_block = require("strider.ui.live_block")
local patch_cards = require("strider.ui.patch_cards")
local marks = require("strider.ui.marks")
local prompt_editor = require("strider.ui.prompt_editor")
local tool_log = require("strider.ui.tool_log")
local state = require("strider.state")
local status = require("strider.status")

local M = {}

local log_namespace = vim.api.nvim_create_namespace("strider-log")
local G = highlights.groups
local ensure_chunk_style = highlights.ensure
local log_assistant_hl = G.log_assistant
local log_user_hl = G.log_user
local log_tool_hl = G.log_tool
local log_thinking_hl = G.log_thinking
local log_rule_hl = G.log_rule
local log_error_hl = G.log_error
local log_muted_hl = G.log_muted
local log_user_prefix = "› "
local log_user_continuation = "  "
local log_user_bg_hl = G.log_user_bg
local log_error_bg_hl = G.log_error_bg
local log_diff_add_hl = G.log_diff_add
local log_diff_remove_hl = G.log_diff_remove
local log_diff_context_hl = G.log_diff_context
local log_diff_add_sign_hl = G.log_diff_add_sign
local log_diff_remove_sign_hl = G.log_diff_remove_sign
local log_diff_line_number_hl = G.log_diff_line_number
local log_diff_gutter_hl = G.log_diff_gutter
local compose_working_hl = G.compose_working
local compose_working_soft_hl = G.compose_working_soft
local compose_working_shine_hl = G.compose_working_shine
local close_windows_for_buffer
local target_window
local ensure_log_follow_autocmds = log_follow.ensure_autocmds
local scroll_log_windows = log_follow.scroll_windows
local set_log_follow = log_follow.set
local log_follow_value = log_follow.value
local update_log_follow_state = log_follow.update_window

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
	return pcall(vim.api.nvim_echo, { { "strider: " .. message } }, false, {})
end

local function flow_done_echo(message)
	return pcall(vim.api.nvim_echo, {
		{ "strider: ", "Comment" },
		{ "● ", "MoreMsg" },
		{ message or "Strider flow complete" },
	}, true, {})
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
	if not start_ns then
		return nil
	end
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
	local escaped = (text or ""):gsub("%%", "%%%%")
	return escaped
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

local function stop_command(lane)
	lane = normalize_lane(lane)
	if state.is_flow_lane(lane) then
		return ":StriderStopFlow"
	end
	return ":StriderStop"
end

local function stop_hint(lane)
	return stop_command(lane) .. " to interrupt"
end

local function compose_status_line(progress, lane)
	local session = state.get_session(lane)
	local statuses = session and session.status or {}
	local clarify_badge = statuses["strider-clarify"]
	local prefix = session and session.chat_read_only and lane == "main" and "[RO] " or ""
	local idle_msg = nil
	if clarify_badge and clarify_badge ~= "" then
		prefix = prefix .. "[Clarify] "
		idle_msg = "Strider is asking — type your answer (<Esc><Esc> to reject)."
	end
	if not progress then
		if idle_msg then
			return prefix .. idle_msg
		end
		local action = status.pending_action(lane)
		if action then
			return prefix .. action
		end
		-- Idle: show model + cwd like codex's bottom bar.
		local widget = session and session.widget or {}
		local parts = {}
		for _, line in ipairs(widget) do
			local trimmed = vim.trim(line or "")
			if trimmed ~= "" then
				table.insert(parts, trimmed)
			end
		end
		if #parts > 0 then
			return prefix .. table.concat(parts, " · ")
		end
		return prefix .. "Strider is ready."
	end
	-- Active: animate `Working`, keep elapsed time beside it, and leave the stop hint on the right.
	local elapsed = format_elapsed(progress.started_at) or "0s"
	local left = compose_working_label(prefix, lane) .. escape_status_text(string.format(" (%s)", elapsed))
	local right = stop_hint(lane)
	return left, right, true
end

function M.refresh_compose_winbar(lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	local buf = session and session.compose_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local left, right, left_is_statusline = compose_status_line(session and session.progress, lane)
	if not left_is_statusline then
		left = escape_status_text(left)
	end
	local value = right and (left .. "%=" .. escape_status_text(right)) or left
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			pcall(function()
				vim.wo[win].winbar = value
			end)
		end
	end
end

-- Ticks drive the `Working` shimmer and keep the adjacent elapsed time fresh.
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
	if cbuf and vim.api.nvim_buf_is_valid(cbuf) and #vim.fn.win_findbuf(cbuf) > 0 then
		M.refresh_compose_winbar(lane)
	end
	M.refresh_log_winbar(lane)
	if M.refresh_q_answer_winbar then
		M.refresh_q_answer_winbar(lane)
	end
end

local function start_spin(progress, lane)
	local spin = spin_state(lane)
	stop_spin(lane)
	spin.index = 0
	M.refresh_compose_winbar(lane)
	M.refresh_log_winbar(lane)
	if M.refresh_q_answer_winbar then
		M.refresh_q_answer_winbar(lane)
	end
	spin.timer = vim.uv.new_timer()
	spin.timer:start(
		SPIN_INTERVAL_MS,
		SPIN_INTERVAL_MS,
		vim.schedule_wrap(function()
			spin_tick(lane)
		end)
	)
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "strider" })
end

local function log_name(lane)
	lane = normalize_lane(lane)
	if lane == "flow" then
		return "strider://StriderLogFlow"
	end
	if state.is_q_lane(lane) then
		return lane == "q" and "strider://StriderLogQ"
			or ("strider://StriderLogQ-" .. tostring(state.q_lane_index(lane)))
	end
	if lane == "patch" then
		return "strider://StriderLogPatch"
	end
	if lane == "review" then
		return "strider://StriderLogReview"
	end
	return state.get_config().log_buffer_name
end

local function review_name()
	return "strider://review"
end

local function status_name()
	return "strider://status"
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

-- Build a single-line winbar from the widget that the extension pushes
-- via setWidget("strider", [...]). We flatten meaningful lines (Model,
-- Context, Cost, last response, etc.) joined with ` · `. Empty widget
-- renders a minimal idle label.
local function context_widget_line(parts)
	for _, part in ipairs(parts) do
		if part:lower():match("^context") then
			return part
		end
	end
end

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
	if session and session.progress then
		local elapsed = format_elapsed(session.progress.started_at) or "0s"
		local title = session.progress.title or "Strider running..."
		local active_parts = { string.format("Working (%s)", elapsed), title }
		local context = context_widget_line(parts)
		if context then
			table.insert(active_parts, context)
		end
		table.insert(active_parts, stop_hint(lane))
		return escape_status_text(table.concat(active_parts, " · "))
	end
	if #parts == 0 then
		return "Strider"
	end
	return escape_status_text(table.concat(parts, " · "))
end

-- Apply the winbar to every window currently showing the log buffer.
-- Idempotent; safe to call on every widget update.
function M.refresh_log_winbar(lane)
	local session = state.get_session(lane)
	local buf = session and session.log_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local value = format_log_winbar(lane)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			pcall(function()
				vim.wo[win].winbar = value
			end)
		end
	end
end

local function configure_log_window(win)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].cursorline = false
	pcall(function()
		vim.wo[win].conceallevel = 2
		vim.wo[win].concealcursor = "nc"
	end)
end

function M.open_log(opts, lane)
	opts = opts or {}
	lane = normalize_lane(lane)
	ensure_log_follow_autocmds()
	local previous = opts.preserve_focus and (target_window() or vim.api.nvim_get_current_win()) or nil
	local buf = M.ensure_log_buffer(lane)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			configure_log_window(win)
			if log_follow_value(win) == nil then
				update_log_follow_state(win)
			end
			if not opts.preserve_focus then
				vim.api.nvim_set_current_win(win)
			end
			scroll_log_windows(buf)
			M.refresh_log_winbar(lane)
			log_pin.refresh_for_window(win)
			return win, false
		end
	end
	-- Log opens as a right-hand vertical split. Compose window, if opened,
	-- stacks below the log in that same vertical column.
	vim.cmd("botright vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	configure_log_window(win)
	set_log_follow(win, true)
	scroll_log_windows(buf)
	M.refresh_log_winbar(lane)
	log_pin.refresh_for_window(win)
	if previous and vim.api.nvim_win_is_valid(previous) then
		vim.api.nvim_set_current_win(previous)
	end
	return win, true
end

function M.hide_log(lane)
	local session = state.get_session(lane)
	close_windows_for_buffer(session and session.log_buf)
end

-- Compose buffer: a persistent scratch buffer for user input. Sits in
-- a horizontal split below the log (right-hand column). <C-s> sends
-- its contents via the provided dispatcher; buffer is cleared on
-- successful send but kept alive across sends.
local compose_ns = vim.api.nvim_create_namespace("strider-compose-hint")

local function compose_buffer_name()
	return "strider://compose"
end

local function compose_hint_text()
	local session = state.get_session("main")
	local prefix = session and session.chat_read_only and "RO · " or ""
	if state.peek_pending_clarify() then
		return prefix .. "Answer clarify · <C-s> send · <Esc><Esc> reject"
	end
	if state.peek_pending_request() then
		return prefix .. "Turn in flight · type to steer · <C-s> send · :StriderStop cancel"
	end
	return prefix .. "Type a message · <C-v> screenshot · <C-s> send · gR RO"
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
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
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

	local function resume_compose(cursor_lnum, cursor_col)
		local compose_win = vim.fn.win_findbuf(buf)[1]
		if not compose_win or not vim.api.nvim_win_is_valid(compose_win) then
			return
		end
		vim.schedule(function()
			if vim.api.nvim_win_is_valid(compose_win) then
				vim.api.nvim_set_current_win(compose_win)
				local last = math.max(vim.api.nvim_buf_line_count(buf), 1)
				local lnum = math.max(1, math.min(cursor_lnum or last, last))
				local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
				local col = math.max(0, math.min(cursor_col or 0, #line))
				pcall(vim.api.nvim_win_set_cursor, compose_win, { lnum, col })
				vim.cmd("startinsert")
			end
		end)
	end

	local function compose_cursor_position(lines)
		local current_win = vim.api.nvim_get_current_win()
		if vim.api.nvim_win_get_buf(current_win) == buf then
			local cursor = vim.api.nvim_win_get_cursor(current_win)
			local row = math.max(0, math.min(cursor[1] - 1, #lines - 1))
			local line = lines[row + 1] or ""
			local col = math.max(0, math.min(cursor[2], #line))
			return row, col
		end
		local row = math.max(#lines - 1, 0)
		local line = lines[row + 1] or ""
		return row, #line
	end

	local function insert_compose_marker(marker)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if #lines == 0 then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
			lines = { "" }
		end
		local row, col = compose_cursor_position(lines)
		vim.api.nvim_buf_set_text(buf, row, col, row, col, { marker, "" })
		render_hint()
		return row + 1, col + #marker
	end

	local function paste_image()
		local path, err = clipboard.save_image()
		if not path then
			notify(err or "Clipboard image paste failed", vim.log.levels.WARN)
			resume_compose()
			return
		end
		resume_compose(insert_compose_marker("@image " .. path))
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
		local ok, strider = pcall(require, "strider")
		if ok and strider and strider.cancel_pending_clarify_if_any then
			strider.cancel_pending_clarify_if_any()
		end
		pcall(vim.cmd, "stopinsert")
	end

	vim.keymap.set({ "n", "i" }, "<C-s>", send_compose, {
		buffer = buf,
		nowait = true,
		silent = true,
		desc = "Send Strider compose",
	})
	vim.keymap.set({ "n", "i" }, "<C-v>", paste_image, {
		buffer = buf,
		nowait = true,
		silent = true,
		desc = "Paste clipboard image into Strider compose",
	})
	vim.keymap.set({ "n", "i" }, "<S-Tab>", function()
		-- Mirror pi's own shift-tab UX: cycle the thinking level without
		-- leaving the compose buffer. The new level shows up in the log
		-- winbar's Model: ... (level) suffix once the widget refreshes.
		require("strider").cycle_thinking()
	end, {
		buffer = buf,
		nowait = true,
		silent = true,
		desc = "Cycle Strider thinking level",
	})
	vim.keymap.set("n", "gR", function()
		require("strider").toggle_chat_read_only()
	end, {
		buffer = buf,
		nowait = true,
		silent = true,
		desc = "Toggle Strider chat read-only mode",
	})
	vim.keymap.set("i", "<C-g>r", function()
		require("strider").toggle_chat_read_only()
	end, {
		buffer = buf,
		nowait = true,
		silent = true,
		desc = "Toggle Strider chat read-only mode",
	})
	vim.keymap.set("i", "<Esc><Esc>", leave_insert, {
		buffer = buf,
		nowait = true,
		silent = true,
		desc = "Leave insert without sending",
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
				if vim.api.nvim_win_is_valid(win) then
					vim.cmd("startinsert")
				end
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
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		local last_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
		local last_text = vim.api.nvim_buf_get_lines(buf, last_line - 1, last_line, false)[1] or ""
		pcall(vim.api.nvim_win_set_cursor, win, { last_line, #last_text })
		vim.cmd("startinsert")
	end)
	return win
end

function M.hide_chat_card()
	chat_card.close()
end

function M.show_chat_card()
	return chat_card.open()
end

local function chat_split_width()
	local info = vim.api.nvim_list_uis()[1] or { width = 120 }
	return math.min(96, math.max(48, math.floor(info.width * 0.42)))
end

function M.open_chat_split(on_send)
	local session = state.get_session("main")
	if session then
		session.chat_collapsed = false
	end
	chat_card.close()
	local log_win, created = M.open_log({}, "main")
	if created and log_win and vim.api.nvim_win_is_valid(log_win) then
		pcall(vim.api.nvim_win_set_width, log_win, chat_split_width())
	end
	return M.open_compose(on_send)
end

function M.hide_compose()
	local session = state.get_session()
	close_windows_for_buffer(session and session.compose_buf)
end

-- True if either chat surface (log or compose) has a live window.
-- Used by :StriderChat to decide between open and hide on the no-args
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
	if not session then
		return false
	end
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

-- Hide both chat surfaces. Optionally leave behind a compact chat card.
function M.hide_chat(opts)
	opts = opts or {}
	local session = state.get_session("main")
	if session then
		session.chat_collapsed = true
	end
	M.hide_compose()
	M.hide_log()
	if opts.show_card then
		M.show_chat_card()
	end
end

function M.should_auto_open_stream_log(lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	return not (lane == "main" and session and session.chat_collapsed)
end

-- Trim the oldest lines from a log buffer when it exceeds the configured
-- max. Removes ~20% of max to avoid trimming on every append. Extmarks on
-- trimmed lines auto-delete.
local function trim_log_buffer(buf)
	local max = state.get_config().log_max_lines
	if not max or max <= 0 then
		return
	end
	local count = vim.api.nvim_buf_line_count(buf)
	if count <= max then
		return
	end
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
	strider = log_tool_hl,
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
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if vim.trim(line) ~= "" then
			return true
		end
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
	strider = "Strider",
	tool = "Ran",
	plan = "Plan",
	clarify = "Clarify",
	diff = "Diff",
	["review-prompt"] = "Review prompt",
	["review-comments"] = "Review comments",
}

local function diff_content_lines(text)
	return log_diff.content_lines(text)
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
	local lines, rows = log_diff.render(text)
	if #rows == 0 then
		return
	end

	local items = log_lines(lines)
	if #items == 0 then
		return
	end

	local buf = M.ensure_log_buffer(lane)
	local start_line
	if opts.insert_at then
		start_line = opts.insert_at
		vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, items)
	else
		start_line = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
	end

	log_diff.highlight_rows(buf, log_namespace, start_line, rows, {
		add = log_diff_add_hl,
		remove = log_diff_remove_hl,
		context = log_diff_context_hl,
		add_sign = log_diff_add_sign_hl,
		remove_sign = log_diff_remove_sign_hl,
		line_number = log_diff_line_number_hl,
		gutter = log_diff_gutter_hl,
	})
	log_diff.highlight_syntax(buf, log_namespace, start_line, rows, opts.lang)
	scroll_log_windows(buf)
end

local function insert_log_items(buf, items, opts)
	if #items == 0 then
		return nil
	end
	if opts.insert_at then
		vim.api.nvim_buf_set_lines(buf, opts.insert_at, opts.insert_at, false, items)
		return opts.insert_at
	end
	local start_line = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
	return start_line
end

local function user_block_lines(text)
	local lines = { "" }
	local first = true
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		if line == "" then
			table.insert(lines, "")
		else
			table.insert(lines, (first and log_user_prefix or log_user_continuation) .. line)
			first = false
		end
	end
	table.insert(lines, "")
	return lines
end

local function highlight_user_block(buf, start_line, items)
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
end

local function append_user_block(buf, text, lane, opts)
	local items = log_lines(user_block_lines(text))
	local start_line = insert_log_items(buf, items, opts)
	if not start_line then
		return false
	end
	log_pin.record_user_message(lane, text, buf, start_line, start_line + #items - 1)
	highlight_user_block(buf, start_line, items)
	scroll_log_windows(buf)
	return true
end

local function block_lines(label, text, buf)
	local lines = {}
	if label == "assistant" then
		if log_has_content(buf) then
			vim.list_extend(lines, { "", log_turn_rule(buf), "" })
		else
			table.insert(lines, "")
		end
	else
		local verb = block_verbs[label]
		table.insert(lines, "")
		table.insert(lines, verb and verb ~= "" and ("• " .. verb) or ("• " .. label))
	end

	local body_lines = label == "diff" and diff_content_lines(text) or vim.split(text, "\n", { plain = true })
	for _, line in ipairs(body_lines) do
		table.insert(lines, label == "assistant" and line or ("  " .. line))
	end
	table.insert(lines, "")
	return lines
end

local function highlight_rule_line(buf, start_line, items)
	for offset = 0, #items - 1 do
		if (items[offset + 1] or ""):match("^%-%-%-+$") then
			local row = start_line + offset
			pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, 0, {
				end_row = row + 1,
				hl_group = log_rule_hl,
				hl_eol = true,
				priority = 6,
			})
			return
		end
	end
end

local function highlight_header_line(buf, label, start_line, items)
	if label == "assistant" or label == "user" then
		return
	end
	for offset = 0, #items - 1 do
		if (items[offset + 1] or ""):sub(1, 3) == "• " then
			local row = start_line + offset
			pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, row, 0, {
				end_row = row + 1,
				hl_group = log_label_hl[label] or log_tool_hl,
				priority = 10,
			})
			return
		end
	end
end

local function highlight_block_bg(buf, start_line, end_line, group, priority)
	pcall(vim.api.nvim_buf_set_extmark, buf, log_namespace, start_line, 0, {
		end_row = end_line + 1,
		hl_group = group,
		hl_eol = true,
		priority = priority,
	})
end

local function highlight_block(buf, label, start_line, end_line, items)
	highlight_rule_line(buf, start_line, items)
	highlight_header_line(buf, label, start_line, items)
	if label == "thinking" then
		highlight_block_bg(buf, start_line, end_line, log_thinking_hl, 4)
	elseif label == "error" then
		highlight_block_bg(buf, start_line, end_line, log_error_bg_hl, 5)
	elseif label == "diff" then
		highlight_diff_rows(buf, start_line, items)
	end
end

function M.append_block(label, text, lane, opts)
	opts = opts or {}
	ensure_chunk_style()
	local buf = M.ensure_log_buffer(lane)

	if label == "user" then
		append_user_block(buf, text, lane, opts)
		return
	end

	local items = log_lines(block_lines(label, text, buf))
	local start_line = insert_log_items(buf, items, opts)
	if not start_line then
		return
	end

	highlight_block(buf, label, start_line, start_line + #items - 1, items)
	scroll_log_windows(buf)
end

function M.update_tool_line(row, tool_name, path, suffix, lane)
	return tool_log.update_tool_line(row, tool_name, path, suffix, lane)
end

function M.append_tool_line(tool_name, path, range, lane)
	return tool_log.append_tool_line(tool_name, path, range, lane, {
		append = M.append,
		ensure_log_buffer = M.ensure_log_buffer,
	})
end

function M.mark_tool_header(tool_call_id, lane)
	return tool_log.mark_tool_header(tool_call_id, lane)
end

function M.pop_tool_insert_row(tool_call_id, lane)
	return tool_log.pop_tool_insert_row(tool_call_id, lane)
end

function M.append_tool_output(text, lang, lane, opts)
	return tool_log.append_tool_output(text, lang, lane, opts, {
		scroll = scroll_log_windows,
	})
end

function M.append_compact_tool_output(text, tool_opts, lane, opts)
	return tool_log.append_compact_tool_output(text, tool_opts, lane, opts, {
		scroll = scroll_log_windows,
	})
end

function M.start_live_block(lane)
	return live_block.start(lane, {
		ensure_log_buffer = M.ensure_log_buffer,
		finalize = M.finalize_live_block,
	})
end

function M.ensure_live_block(lane)
	return live_block.ensure(lane, {
		ensure_log_buffer = M.ensure_log_buffer,
	})
end

function M.update_live_block(full_text, lane)
	return live_block.update(full_text, lane, {
		scroll = scroll_log_windows,
	})
end

function M.finalize_live_block(label, text, lane)
	return live_block.finalize(label, text, lane, {
		append_block = M.append_block,
		scroll = scroll_log_windows,
	})
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

local function ensure_q_answer_buffer(lane)
	return flow_cards.ensure_q_answer_buffer(lane)
end

function M.open_q_answer(prompt, lane, opts)
	return flow_cards.open_q_answer(prompt, lane, opts)
end

function M.update_q_answer(text, lane, card_id)
	return flow_cards.update_q_answer(text, lane, card_id)
end

function M.finish_q_answer(text, status, lane, card_id)
	return flow_cards.finish_q_answer(text, status, lane, card_id)
end

function M.toggle_q_answer(lane)
	return flow_cards.toggle_q_answer(lane)
end

function M.focus_flow_card(id, lane)
	return flow_cards.focus_card(id, lane)
end

function M.get_flow_card(id, lane)
	return flow_cards.get_card(id, lane)
end

function M.clear_flow_cards(opts)
	return flow_cards.clear_completed(opts)
end

function M.open_patch_card(prompt, opts, lane)
	return patch_cards.open(prompt, opts, lane)
end

function M.record_patch_card_tool(id, tool, lane)
	return patch_cards.record_tool(id, tool, lane)
end

function M.finish_patch_card(id, status, fields, lane)
	return patch_cards.finish(id, status, fields, lane)
end

function M.refresh_q_answer_winbar(lane)
	return flow_cards.refresh_q_answer_winbar(lane)
end

function M.refresh_q_answer_layouts()
	return flow_cards.refresh_q_answer_layouts()
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
	if target == "log" or target == "both" or target == "q" then
		table.insert(bufs, M.ensure_log_buffer(lane))
	end
	if target == "q" then
		local q_buf = ensure_q_answer_buffer(lane)
		if q_buf then
			table.insert(bufs, q_buf)
		end
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
		-- hrtime is nanoseconds, monotonic. Drives the elapsed time next to
		-- `Working` in the compose winbar so the user can see the turn is
		-- moving even while the spin label is between rotations.
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
	if normalize_lane(lane) == "main" then
		session.chat_card_status = nil
		chat_card.refresh()
	end
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
	M.refresh_log_winbar(lane)
	M.refresh_q_answer_winbar(lane)
	M.refresh_compose_hint()
	if normalize_lane(lane) == "main" then
		session.chat_card_status = status == "cancel" and "stopped" or (status == "error" and "failed" or "done")
		chat_card.refresh()
	end
end

function M.open_comment_editor(on_submit, opts)
	return prompt_editor.open_comment_editor(on_submit, opts)
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
	return prompt_editor.clarify_plan_proposal_picker(cb)
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
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	if compose_has_text(buf) then
		notify("Compose has draft text — send or clear it before modifying the proposal.", vim.log.levels.WARN)
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

-- Prefill compose for :StriderChat. Empty compose is replaced outright;
-- non-empty compose keeps the user's draft and appends the new context
-- after a blank line so command-line context doesn't stomp on typing.
function M.prefill_compose(text)
	text = text or ""
	if text == "" then
		return false
	end
	local session = state.get_session()
	local buf = session and session.compose_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

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

function M.open_prompt_editor(label, on_submit, opts)
	return prompt_editor.open_prompt_editor(label, on_submit, opts)
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
		marks.refresh_buffer(buf)
	else
		pcall(vim.cmd, "silent edit " .. vim.fn.fnameescape(path))
		buf = vim.api.nvim_get_current_buf()
		marks.refresh_buffer(buf)
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
	marks.highlight_lines(path, lines, lane)
end

function M.highlight_range(path, first_line, last_line, lane)
	marks.highlight_range(path, first_line, last_line, lane)
end

function M.clear_stop_annotations()
	marks.clear_stop_annotations()
end

function M.set_stop_annotations(item)
	marks.set_stop_annotations(item)
end

function M.clear_comment_markers()
	marks.clear_comment_markers()
end

function M.add_comment_marker(path, line)
	marks.add_comment_marker(path, line)
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

function M.notify_flow_done(message, opts)
	opts = opts or {}
	local text = message or "Strider flow complete"
	if opts.notify ~= false then
		notify("🟢 " .. text, vim.log.levels.INFO)
	end
	vim.defer_fn(function()
		flow_done_echo(text)
	end, opts.delay_ms or 20)
end

return M
