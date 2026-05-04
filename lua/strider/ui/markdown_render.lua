local M = {}

local CONCEAL_CURSOR = "nvic"
local CONCEAL_LEVEL = 3
local augroup = vim.api.nvim_create_augroup("StriderMarkdownRender", { clear = false })

local render_config = {
	anti_conceal = { enabled = false },
	win_options = {
		conceallevel = { rendered = CONCEAL_LEVEL },
		concealcursor = { rendered = CONCEAL_CURSOR },
	},
}

local function valid_buffer(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_window(win)
	return win and vim.api.nvim_win_is_valid(win)
end

local function apply_config(config)
	if type(config) ~= "table" then
		return false
	end
	config.anti_conceal = config.anti_conceal or {}
	config.anti_conceal.enabled = false
	config.win_options = config.win_options or {}
	config.win_options.conceallevel = config.win_options.conceallevel or {}
	config.win_options.concealcursor = config.win_options.concealcursor or {}
	config.win_options.conceallevel.rendered = CONCEAL_LEVEL
	config.win_options.concealcursor.rendered = CONCEAL_CURSOR
	return true
end

local function apply_render_markdown_config(buf)
	local ok, state = pcall(require, "render-markdown.state")
	if not ok or type(state.get) ~= "function" or not state.config then
		return false
	end
	local got_config, config = pcall(state.get, buf, render_config)
	if not got_config then
		return false
	end
	return apply_config(config)
end

local function set_window_options(win)
	pcall(vim.api.nvim_set_option_value, "conceallevel", CONCEAL_LEVEL, { scope = "local", win = win })
	pcall(vim.api.nvim_set_option_value, "concealcursor", CONCEAL_CURSOR, { scope = "local", win = win })
end

local function ensure_autocmd(buf)
	if vim.b[buf].strider_markdown_render_attached then
		return
	end
	vim.b[buf].strider_markdown_render_attached = true
	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
		group = augroup,
		buffer = buf,
		callback = function()
			local win = vim.api.nvim_get_current_win()
			if valid_window(win) and vim.api.nvim_win_get_buf(win) == buf then
				M.apply_to_window(win, { refresh = false })
			end
		end,
	})
end

function M.keep_conceal(buf)
	if not valid_buffer(buf) then
		return false
	end
	vim.b[buf].strider_keep_markdown_conceal = true
	ensure_autocmd(buf)
	return apply_render_markdown_config(buf)
end

function M.refresh(buf, win)
	if not valid_buffer(buf) then
		return false
	end
	apply_render_markdown_config(buf)
	local ok, render_markdown = pcall(require, "render-markdown")
	if not ok or type(render_markdown.render) ~= "function" then
		return false
	end
	local ctx = { buf = buf, event = "StriderKeepConceal", config = render_config }
	if valid_window(win) then
		ctx.win = win
	end
	local rendered = pcall(render_markdown.render, ctx)
	return rendered
end

function M.apply_to_window(win, opts)
	opts = opts or {}
	if not valid_window(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	M.keep_conceal(buf)
	set_window_options(win)
	if opts.refresh ~= false then
		M.refresh(buf, win)
	end
	return true
end

return M
