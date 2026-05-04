local M = {}

local editor_ns = vim.api.nvim_create_namespace("strider-editor-hint")

local function configure_scratch_buffer(buf, filetype)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	if filetype then
		vim.bo[buf].filetype = filetype
	end
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "strider" })
end

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

	local submit_hint = opts.submit_hint or "<C-s> to submit · <Esc><Esc> to cancel"

	local function render_hint()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.api.nvim_buf_clear_namespace(buf, editor_ns, 0, -1)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local is_empty = (#lines == 0) or (#lines == 1 and lines[1] == "")

		local virt_lines = {}
		local hint_lines = type(opts.hint_lines) == "function" and opts.hint_lines() or opts.hint_lines
		if hint_lines then
			for _, text in ipairs(hint_lines) do
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
		pcall(vim.cmd, "stopinsert")
		if submit and (text ~= "" or opts.allow_empty) then
			if on_submit(text) == false then
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_set_current_win(win)
				end
				render_hint()
				vim.cmd("startinsert")
				return
			end
		elseif submit then
			notify("Discarded empty Strider input", vim.log.levels.WARN)
			if opts.on_cancel then
				opts.on_cancel()
			end
		elseif opts.on_cancel then
			opts.on_cancel()
		end
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
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

	for _, map in ipairs(opts.extra_keymaps or {}) do
		vim.keymap.set(map.mode or { "n", "i" }, map.lhs, function()
			map.callback({ buf = buf, render_hint = render_hint })
		end, { buffer = buf, nowait = true, silent = true, desc = map.desc })
	end

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
		name = "strider://comment",
		title = "Strider comment",
		prefill = opts.prefill,
		hint_lines = opts.hint_lines or { "Leave a review comment. Multiple lines are fine." },
	}, on_submit)
end

function M.clarify_plan_proposal_picker(cb)
	vim.schedule(function()
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

local function normalize_prompt_editor_opts(opts)
	if opts == nil then
		return {}
	end
	if
		opts.hint_lines ~= nil
		or opts.prefill ~= nil
		or opts.allow_empty ~= nil
		or opts.name ~= nil
		or opts.on_cancel ~= nil
		or opts.extra_keymaps ~= nil
		or opts.submit_hint ~= nil
	then
		return vim.deepcopy(opts)
	end
	return { hint_lines = opts }
end

function M.open_prompt_editor(label, on_submit, opts)
	opts = normalize_prompt_editor_opts(opts)
	open_scratch_editor({
		allow_empty = opts.allow_empty,
		name = opts.name or "strider://prompt",
		title = label,
		hint_lines = opts.hint_lines,
		prefill = opts.prefill,
		on_cancel = opts.on_cancel,
		extra_keymaps = opts.extra_keymaps,
		submit_hint = opts.submit_hint,
	}, on_submit)
end

return M
