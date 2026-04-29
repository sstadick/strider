local state = require("strider.state")

local M = {}
local ns = vim.api.nvim_create_namespace("strider-chat-card")
local augroup = nil
local CARD_HEIGHT = 3
local STACK_MARGIN_BOTTOM = 2

local function ui_size()
	return vim.api.nvim_list_uis()[1] or { width = 120, height = 30 }
end
local function card_width(width)
	return math.min(88, math.max(42, math.floor(width * 0.42)))
end

local function buffer()
	local name = "strider://StriderChatCard"
	local existing = vim.fn.bufnr(name)
	local buf = existing > 0 and existing or vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, name)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = true
	vim.bo[buf].swapfile = false
	return buf
end

local function card_lines()
	local session = state.get_session("main")
	local pending = session and session.pending_request
	local running = pending or (session and session.progress)
	local draft = session
			and session.compose_buf
			and vim.api.nvim_buf_is_valid(session.compose_buf)
			and table.concat(vim.api.nvim_buf_get_lines(session.compose_buf, 0, -1, false), "\n")
		or ""
	local status = "Open :StriderChat to expand"
	if session and session.chat_card_status == "done" then
		status = "Chat done — :StriderChat to expand"
	end
	if session and session.last_summary and session.last_summary ~= "" then
		status = "Chat done — :StriderChat to expand"
	end
	if session and session.chat_card_status == "stopped" then
		status = "Chat stopped — :StriderChat to expand"
	end
	if session and session.last_error and session.last_error ~= "" then
		status = "Chat failed — :StriderChat to expand"
	end
	if running then
		status = "Chat running — :StriderChat to expand"
	end
	if vim.trim(draft) ~= "" then
		status = "Draft ready — :StriderChat to expand"
	end
	return {
		"› Strider chat",
		"────────────────────────────────",
		status,
	}
end

local function render(buf)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, card_lines())
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, {
		end_row = 1,
		hl_group = require("strider.ui.highlights").groups.log_user,
		priority = 10,
	})
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, 1, 0, {
		end_row = 2,
		hl_group = require("strider.ui.highlights").groups.log_rule,
		priority = 10,
	})
	vim.bo[buf].modifiable = false
end

local function config()
	local info = ui_size()
	local width = card_width(info.width)
	return {
		relative = "editor",
		anchor = "NW",
		row = math.max(info.height - CARD_HEIGHT - STACK_MARGIN_BOTTOM, 0),
		col = math.max(info.width - width - 1, 0),
		width = width,
		height = CARD_HEIGHT,
		border = "rounded",
		title = " Strider chat ",
		title_pos = "left",
		style = "minimal",
		focusable = true,
		zindex = 35,
	}
end

local function refresh_flow_cards()
	local ok, flow_cards = pcall(require, "strider.ui.flow_cards")
	if ok and flow_cards and flow_cards.refresh_layouts then
		flow_cards.refresh_layouts()
	end
end

local function configure_window(win)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].cursorline = false
	vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:FloatBorder"
end

local function attach(buf)
	if vim.b[buf].strider_chat_card_attached then
		return
	end
	vim.b[buf].strider_chat_card_attached = true
	local function open_chat()
		local ok, strider = pcall(require, "strider")
		if ok and strider and strider.chat then
			strider.chat()
		end
	end
	local function close_card()
		M.close()
	end
	for _, lhs in ipairs({ "<CR>", "i", "o" }) do
		vim.keymap.set("n", lhs, open_chat, { buffer = buf, nowait = true, silent = true, desc = "Open Strider chat" })
	end
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set(
			"n",
			lhs,
			close_card,
			{ buffer = buf, nowait = true, silent = true, desc = "Hide Strider chat card" }
		)
	end
end

function M.is_visible()
	local session = state.get_session("main")
	local win = session and session.chat_card_win
	return win and vim.api.nvim_win_is_valid(win) or false
end

function M.close()
	local session = state.get_session("main")
	local was_visible = M.is_visible()
	local win = session and session.chat_card_win
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if session then
		session.chat_card_win = nil
	end
	if was_visible then
		refresh_flow_cards()
	end
end

function M.refresh()
	local session = state.get_session("main")
	if not session or not session.chat_card_win or not vim.api.nvim_win_is_valid(session.chat_card_win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(session.chat_card_win)
	render(buf)
end

local function ensure_autocmds()
	if augroup then
		return
	end
	augroup = vim.api.nvim_create_augroup("StriderChatCard", { clear = true })
	vim.api.nvim_create_autocmd("VimResized", {
		group = augroup,
		callback = function()
			if M.is_visible() then
				M.open()
			end
		end,
	})
end

function M.open()
	ensure_autocmds()
	local session = state.ensure_session("main")
	session.chat_collapsed = true
	local buf = buffer()
	attach(buf)
	render(buf)
	local win = session.chat_card_win
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_set_config, win, config())
	else
		win = vim.api.nvim_open_win(buf, false, config())
	end
	configure_window(win)
	session.chat_card_win = win
	refresh_flow_cards()
	return win
end

return M
