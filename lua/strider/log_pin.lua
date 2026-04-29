local state = require("strider.state")

local M = {}

local pin_namespace = vim.api.nvim_create_namespace("strider-log-pin")
local source_namespace = vim.api.nvim_create_namespace("strider-log-pin-source")
local pin_bg_hl = "StriderLogUserBg"
local pin_text_hl = "StriderLogUser"
local pin_user_prefix = "› "
local pin_user_continuation = "  "
local pin_windows_by_base = {}

local function lane_for_buffer(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	for _, lane in ipairs(state.lanes()) do
		local session = state.get_session(lane)
		if session and session.log_buf == buf then
			return lane, session
		end
	end
	return nil
end

local function lane_for_window(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
	if not ok then
		return nil
	end
	return lane_for_buffer(buf)
end

local function win_var(win, name)
	local ok, value = pcall(function()
		return vim.w[win][name]
	end)
	return ok and value or nil
end

local function set_win_var(win, name, value)
	pcall(function()
		vim.w[win][name] = value
	end)
end

local function close_pin(win)
	if not win then
		return
	end
	local valid = vim.api.nvim_win_is_valid(win)
	local pin_win = valid and win_var(win, "strider_log_pin_win") or nil
	pin_win = pin_win or pin_windows_by_base[win]
	if pin_win and vim.api.nvim_win_is_valid(pin_win) then
		pcall(vim.api.nvim_win_close, pin_win, true)
	end
	pin_windows_by_base[win] = nil
	if valid then
		set_win_var(win, "strider_log_pin_win", nil)
		set_win_var(win, "strider_log_pin_buf", nil)
	end
end

local function config_enabled()
	local config = state.get_config()
	if config.log_pin_user_message == false then
		return false
	end
	local max_rows = tonumber(config.log_pin_max_rows) or 5
	return max_rows > 0, max_rows
end

local function split_display(text, max_width)
	if text == "" then
		return "", ""
	end
	local used = 0
	local chars = vim.fn.strchars(text)
	local out = {}
	for i = 0, chars - 1 do
		local ch = vim.fn.strcharpart(text, i, 1)
		local width = math.max(vim.fn.strdisplaywidth(ch), 1)
		if used > 0 and used + width > max_width then
			return table.concat(out), vim.fn.strcharpart(text, i)
		end
		out[#out + 1] = ch
		used = used + width
	end
	return table.concat(out), ""
end

local function truncate_display(text, max_width)
	if vim.fn.strdisplaywidth(text) <= max_width then
		return text
	end
	local head = split_display(text, math.max(max_width, 1))
	return head
end

local function add_ellipsis(line, width)
	local ellipsis = "…"
	local ellipsis_width = vim.fn.strdisplaywidth(ellipsis)
	local head = truncate_display(line, math.max(width - ellipsis_width, 1))
	return head .. ellipsis
end

local function push_wrapped(rows, line, width, max_rows)
	local rest = line
	local first = true
	repeat
		if #rows >= max_rows then
			return false
		end
		local prefix = first and pin_user_prefix or pin_user_continuation
		local body_width = math.max(width - vim.fn.strdisplaywidth(prefix), 1)
		local chunk
		chunk, rest = split_display(rest, body_width)
		rows[#rows + 1] = prefix .. chunk
		first = false
	until rest == ""
	return true
end

local function preview_lines(text, width, max_rows)
	local rows = {}
	local lines = vim.split(text or "", "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end
	for _, line in ipairs(lines) do
		if not push_wrapped(rows, line, width, max_rows) then
			rows[#rows] = add_ellipsis(rows[#rows], width)
			return rows
		end
	end
	return rows
end

local function source_range(buf, message)
	if not message or not message.mark_id then
		return nil
	end
	local ok, mark =
		pcall(vim.api.nvim_buf_get_extmark_by_id, buf, source_namespace, message.mark_id, { details = true })
	if not ok or not mark or not mark[1] then
		return nil
	end
	local details = mark[3] or {}
	local end_row = details.end_row and (details.end_row - 1) or mark[1]
	return mark[1], end_row
end

local function visible_range(win)
	local ok, range = pcall(vim.api.nvim_win_call, win, function()
		return { vim.fn.line("w0") - 1, vim.fn.line("w$") - 1 }
	end)
	if not ok or not range then
		return nil
	end
	return range[1], range[2]
end

local function ranges_overlap(a_start, a_end, b_start, b_end)
	return a_start <= b_end and a_end >= b_start
end

local function source_is_visible(win, buf, message)
	local source_start, source_end = source_range(buf, message)
	if not source_start then
		return false
	end
	local view_start, view_end = visible_range(win)
	if not view_start then
		return false
	end
	return ranges_overlap(source_start, source_end, view_start, view_end)
end

local function ensure_pin_buf(win)
	local buf = win_var(win, "strider_log_pin_buf")
	if buf and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end
	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	vim.b[buf].strider_log_pin = true
	set_win_var(win, "strider_log_pin_buf", buf)
	return buf
end

local function set_pin_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, pin_namespace, 0, -1)
	for row = 0, #lines - 1 do
		pcall(vim.api.nvim_buf_set_extmark, buf, pin_namespace, row, 0, {
			end_row = row + 1,
			hl_group = pin_text_hl,
			hl_eol = true,
			priority = 10,
		})
	end
	vim.bo[buf].modifiable = false
end

local function configure_pin_window(pin_win)
	vim.wo[pin_win].wrap = false
	vim.wo[pin_win].number = false
	vim.wo[pin_win].relativenumber = false
	vim.wo[pin_win].signcolumn = "no"
	vim.wo[pin_win].foldcolumn = "0"
	vim.wo[pin_win].winhighlight = table.concat({
		"Normal:" .. pin_bg_hl,
		"NormalFloat:" .. pin_bg_hl,
		"EndOfBuffer:" .. pin_bg_hl,
	}, ",")
end

local function pin_config(win, width, height)
	return {
		relative = "win",
		win = win,
		anchor = "NW",
		row = 0,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		focusable = false,
		zindex = 45,
	}
end

local function upsert_pin(win, lines, width)
	local buf = ensure_pin_buf(win)
	set_pin_lines(buf, lines)
	local height = #lines
	local pin_win = win_var(win, "strider_log_pin_win")
	if pin_win and vim.api.nvim_win_is_valid(pin_win) then
		vim.api.nvim_win_set_config(pin_win, pin_config(win, width, height))
	else
		pin_win = vim.api.nvim_open_win(buf, false, pin_config(win, width, height))
		set_win_var(win, "strider_log_pin_win", pin_win)
	end
	pin_windows_by_base[win] = pin_win
	configure_pin_window(pin_win)
end

function M.refresh_for_window(win)
	local lane, session = lane_for_window(win)
	if not lane or not session then
		return
	end

	local enabled, max_rows = config_enabled()
	local message = session.last_user_message
	local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
	if not enabled or not message or vim.trim(message.text or "") == "" then
		close_pin(win)
		return
	end
	if not ok or source_is_visible(win, buf, message) then
		close_pin(win)
		return
	end

	local width = math.max(vim.api.nvim_win_get_width(win), 1)
	local lines = preview_lines(message.text, width, max_rows)
	if #lines == 0 then
		close_pin(win)
		return
	end
	upsert_pin(win, lines, width)
end

function M.refresh_for_buffer(buf)
	if not lane_for_buffer(buf) then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			M.refresh_for_window(win)
		end
	end
end

function M.record_user_message(lane, text, buf, start_row, end_row)
	local session = state.get_session(lane)
	if not session or not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local mark_id = vim.api.nvim_buf_set_extmark(buf, source_namespace, start_row, 0, {
		end_row = end_row + 1,
		end_col = 0,
		right_gravity = false,
		end_right_gravity = false,
	})
	session.last_user_message = {
		text = text or "",
		mark_id = mark_id,
	}
	M.refresh_for_buffer(buf)
end

function M.close_for_window(win)
	close_pin(win)
end

return M
