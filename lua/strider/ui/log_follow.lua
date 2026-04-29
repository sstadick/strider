local log_pin = require("strider.log_pin")
local state = require("strider.state")

local M = {}

local scroll_timers = {}
local SCROLL_DEBOUNCE_MS = 30
local augroup = nil

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

local function bottom_line(win)
	if not window_is_log(win) then
		return 0
	end
	local ok, line = pcall(vim.api.nvim_win_call, win, function()
		return vim.fn.line("w$")
	end)
	return ok and line or 0
end

local function line_count(win)
	if not window_is_log(win) then
		return 1
	end
	local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
	if not ok or not vim.api.nvim_buf_is_valid(buf) then
		return 1
	end
	return math.max(vim.api.nvim_buf_line_count(buf), 1)
end

local function at_bottom(win)
	return bottom_line(win) >= line_count(win)
end

function M.value(win)
	local ok, value = pcall(function()
		return vim.w[win].strider_log_follow
	end)
	if not ok then
		return nil
	end
	return value
end

local function follow_line_count(win)
	local ok, value = pcall(function()
		return vim.w[win].strider_log_follow_line_count
	end)
	if not ok or type(value) ~= "number" then
		return nil
	end
	return value
end

function M.set(win, follow)
	if not window_is_log(win) then
		return
	end
	pcall(function()
		vim.w[win].strider_log_follow = follow and true or false
		if follow then
			vim.w[win].strider_log_follow_line_count = line_count(win)
		end
	end)
end

local function window_follows(win)
	if not window_is_log(win) then
		return false
	end
	local follow = M.value(win)
	if follow == nil then
		return true
	end
	return follow == true or follow == 1
end

function M.update_window(win)
	if not window_is_log(win) then
		return
	end
	if at_bottom(win) then
		M.set(win, true)
		log_pin.refresh_for_window(win)
		return
	end

	local follow = M.value(win)
	local previous_tail = follow_line_count(win)
	if (follow == true or follow == 1) and previous_tail then
		if bottom_line(win) >= previous_tail then
			log_pin.refresh_for_window(win)
			return
		end
	end
	M.set(win, false)
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

function M.ensure_autocmds()
	if augroup then
		return
	end
	augroup = vim.api.nvim_create_augroup("StriderLogFollow", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "WinResized" }, {
		group = augroup,
		callback = function(args)
			M.update_window(event_window(args))
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(args)
			log_pin.close_for_window(tonumber(args.match))
		end,
	})
end

function M.scroll_now(buf)
	local last = math.max(vim.api.nvim_buf_line_count(buf), 1)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			if window_follows(win) then
				local ok = pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
				if ok then
					M.set(win, true)
				end
			end
			log_pin.refresh_for_window(win)
		end
	end
end

function M.scroll_windows(buf)
	M.ensure_autocmds()
	local timer = scroll_timers[buf]
	if timer then
		timer:stop()
	else
		timer = vim.uv.new_timer()
		scroll_timers[buf] = timer
	end
	timer:start(
		SCROLL_DEBOUNCE_MS,
		0,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(buf) then
				M.scroll_now(buf)
			end
		end)
	)
end

return M
