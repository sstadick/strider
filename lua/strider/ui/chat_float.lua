local chat_card = require("strider.ui.chat_card")
local state = require("strider.state")

local M = {}

local TOP = 1
local BOTTOM = 3
local COMPOSE_HEIGHT = 8

local function size()
	local info = vim.api.nvim_list_uis()[1] or { width = 120, height = 30 }
	local width = math.min(96, math.max(56, math.floor(info.width * 0.52)))
	local total = math.max(12, info.height - TOP - BOTTOM)
	local compose_height = math.min(COMPOSE_HEIGHT, math.max(4, total - 8))
	local log_height = math.max(6, total - compose_height - 4)
	return {
		col = math.max(info.width - width - 1, 0),
		compose_height = compose_height,
		log_height = log_height,
		width = width,
	}
end

local function config(kind)
	local dims = size()
	local is_log = kind == "log"
	return {
		relative = "editor",
		anchor = "NW",
		row = is_log and TOP or TOP + dims.log_height + 2,
		col = dims.col,
		width = dims.width,
		height = is_log and dims.log_height or dims.compose_height,
		border = "rounded",
		title = is_log and " Strider chat " or " Strider compose ",
		title_pos = "left",
		style = "minimal",
		focusable = true,
		zindex = is_log and 62 or 63,
	}
end

local function configure_common(win)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:FloatBorder"
end

local function configure_log(win)
	configure_common(win)
	pcall(function()
		vim.wo[win].conceallevel = 2
		vim.wo[win].concealcursor = "nc"
	end)
end

local function focus_compose(buf, win)
	vim.schedule(function()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		vim.api.nvim_set_current_win(win)
		local last = math.max(vim.api.nvim_buf_line_count(buf), 1)
		local text = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
		pcall(vim.api.nvim_win_set_cursor, win, { last, #text })
		vim.cmd("startinsert")
	end)
end

function M.open(on_send, deps)
	deps = deps or {}
	local session = state.get_session("main")
	if session then
		session.chat_collapsed = false
	end
	chat_card.close()
	deps.ensure_log_follow_autocmds()
	local log_buf = deps.ensure_log_buffer("main")
	local compose_buf = deps.ensure_compose_buffer(on_send)
	deps.close_windows_for_buffer(compose_buf)
	deps.close_windows_for_buffer(log_buf)

	local log_win = vim.api.nvim_open_win(log_buf, false, config("log"))
	configure_log(log_win)
	deps.set_log_follow(log_win, true)
	deps.scroll_log_windows(log_buf)
	deps.refresh_log_winbar("main")
	deps.log_pin_refresh_for_window(log_win)

	local compose_win = vim.api.nvim_open_win(compose_buf, true, config("compose"))
	configure_common(compose_win)
	deps.refresh_compose_winbar("main")
	focus_compose(compose_buf, compose_win)
	return compose_win
end

return M
