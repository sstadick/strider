local markdown_render = require("strider.ui.markdown_render")
local state = require("strider.state")

local M = {}
local ns = vim.api.nvim_create_namespace("strider-patch-summaries")

local function normalize_lane(lane)
	return state.normalize_lane(lane or "patch")
end

local function escape_status_text(text)
	return (text or ""):gsub("%%", "%%%%")
end

local function display_path(path, lane)
	if not path or path == "" then
		return "(unknown)"
	end
	local session = state.get_session(lane)
	local cwd = session and session.cwd or vim.fn.getcwd()
	if cwd and cwd ~= "" and vim.startswith(path, cwd .. "/") then
		return path:sub(#cwd + 2)
	end
	return path
end

local function target_label(target, lane)
	if not target then
		return "(unknown target)"
	end
	local path = display_path(target.path, lane)
	local start_line = tonumber(target.startLine) or 1
	local end_line = tonumber(target.endLine) or start_line
	return string.format("%s:%d-%d", path, start_line, end_line)
end

local function preview_text(text, max_chars)
	local preview = vim.trim((text or ""):gsub("%s+", " "))
	if preview == "" then
		preview = "untitled"
	end
	max_chars = max_chars or 48
	if vim.fn.strchars(preview) > max_chars then
		preview = vim.fn.strcharpart(preview, 0, max_chars - 1) .. "…"
	end
	return preview
end

local function summary_name(summary)
	if summary.name and summary.name ~= "" then
		return summary.name
	end
	return string.format("StriderPatch #%s: %s", tostring(summary.seq or "?"), preview_text(summary.prompt))
end

local function ensure_state(session)
	session.patch_summaries = session.patch_summaries or {}
	session.patch_summary_seq = session.patch_summary_seq or 0
	return session.patch_summaries
end

local function next_id(session)
	session.patch_summary_seq = (session.patch_summary_seq or 0) + 1
	return string.format("patch-summary-%d", session.patch_summary_seq), session.patch_summary_seq
end

local function summary_by_id(session, id)
	if not session or not id then
		return nil
	end
	for _, summary in ipairs(ensure_state(session)) do
		if summary.id == id then
			return summary
		end
	end
	return nil
end

local function add_unique(list, value)
	if not value or value == "" then
		return
	end
	for _, item in ipairs(list) do
		if item == value then
			return
		end
	end
	table.insert(list, value)
end

local function append_lines(out, text)
	for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
		table.insert(out, line)
	end
end

local function append_section(out, title, lines)
	table.insert(out, title)
	if not lines or #lines == 0 then
		table.insert(out, "- (none yet)")
	else
		vim.list_extend(out, lines)
	end
end

local function file_bullets(paths, lane)
	local lines = {}
	for _, path in ipairs(paths or {}) do
		table.insert(lines, "- " .. display_path(path, lane))
	end
	return lines
end

local function status_text(summary)
	if summary.assistant_summary and vim.trim(summary.assistant_summary) ~= "" then
		return summary.assistant_summary
	end
	if summary.status == "running" then
		return "Patch is still running."
	end
	if summary.status == "success" then
		return "Patch completed with no final summary."
	end
	return summary.error_summary or "Patch stopped before a final summary."
end

local function append_diff_blocks(out, summary, lane)
	if not summary.diff_blocks or #summary.diff_blocks == 0 then
		return
	end
	table.insert(out, "")
	table.insert(out, "Diffs")
	for _, block in ipairs(summary.diff_blocks) do
		table.insert(out, "")
		table.insert(out, display_path(block.path, lane))
		table.insert(out, "```diff")
		append_lines(out, block.diff)
		table.insert(out, "```")
	end
end

local function render_lines(summary, lane)
	local lines = { "# " .. summary_name(summary), "" }
	append_section(lines, "Request", vim.split(summary.prompt or "(no request)", "\n", { plain = true }))
	table.insert(lines, "")
	table.insert(lines, "Target: " .. target_label(summary.target, lane))
	table.insert(lines, "")
	append_section(lines, "Files touched", file_bullets(summary.edited_files, lane))
	table.insert(lines, "")
	append_section(lines, "Inspected", file_bullets(summary.inspected_files, lane))
	table.insert(lines, "")
	append_section(lines, "Activity", summary.tool_lines)
	append_diff_blocks(lines, summary, lane)
	table.insert(lines, "")
	table.insert(lines, "Summary")
	append_lines(lines, status_text(summary))
	return lines
end

local function buffer_name(summary)
	return string.format("strider://patch/%s", tostring(summary.seq or summary.id or "1"))
end

local function configure_buffer(buf)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = true
	vim.bo[buf].swapfile = false
	markdown_render.keep_conceal(buf)
end

local function configure_window(win)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].cursorline = false
	vim.wo[win].winfixwidth = true
	markdown_render.apply_to_window(win)
end

local function close_summary_windows(summary)
	local buf = summary and summary.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if not pcall(vim.api.nvim_win_close, win, true) and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
			vim.cmd("enew")
		end
	end
end

local function close_current_split(summary)
	local current = vim.api.nvim_get_current_win()
	if summary and summary.buf and vim.api.nvim_win_get_buf(current) == summary.buf then
		if not pcall(vim.api.nvim_win_close, current, true) then
			vim.cmd("enew")
		end
	end
end

local function open_log()
	local ok, ui = pcall(require, "strider.ui")
	if ok and ui and ui.open_log then
		ui.open_log({}, "patch")
	end
end

local function attach_keymaps(buf, summary, lane)
	if vim.b[buf].strider_patch_summary_attached then
		return
	end
	vim.b[buf].strider_patch_summary_attached = true
	local function map(lhs, rhs, desc)
		vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		map(lhs, function()
			close_current_split(summary)
		end, "Close Strider patch summary")
	end
	map("d", function()
		M.dismiss(summary.id, lane)
	end, "Dismiss Strider patch summary")
	map("o", open_log, "Open Strider patch log")
	map("]c", function()
		M.focus_relative(summary.id, lane, 1)
	end, "Next Strider patch summary")
	map("[c", function()
		M.focus_relative(summary.id, lane, -1)
	end, "Previous Strider patch summary")
end

local function ensure_buffer(summary, lane)
	if summary.buf and vim.api.nvim_buf_is_valid(summary.buf) then
		return summary.buf
	end
	local existing = vim.fn.bufnr(buffer_name(summary))
	local buf = existing > 0 and existing or vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, buffer_name(summary))
	configure_buffer(buf)
	summary.buf = buf
	vim.b[buf].strider_patch_summary = summary.id
	attach_keymaps(buf, summary, lane)
	return buf
end

local function summary_winbar(summary)
	local done = summary.status ~= "running"
	local status = done and (summary.status == "success" and "complete" or "stopped") or "running"
	local left = escape_status_text(string.format("%s · %s", summary_name(summary), status))
	return left .. "%=" .. escape_status_text("q close · d dismiss · o log")
end

local function render_buffer(summary, lane)
	local buf = summary.buf and vim.api.nvim_buf_is_valid(summary.buf) and summary.buf or nil
	if not buf then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines(summary, lane))
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	vim.bo[buf].modifiable = false
	pcall(function()
		vim.bo[buf].modified = false
	end)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		pcall(function()
			vim.wo[win].winbar = summary_winbar(summary)
		end)
	end
end

local function sorted_summaries(session)
	local summaries = vim.tbl_filter(function(summary)
		return not summary.dismissed
	end, ensure_state(session))
	table.sort(summaries, function(a, b)
		return (a.started_at or 0) < (b.started_at or 0)
	end)
	return summaries
end

local function latest_summary(session)
	local best = nil
	for _, summary in ipairs(ensure_state(session)) do
		local newer = not best or (summary.started_at or 0) > (best.started_at or 0)
		if not summary.dismissed and newer then
			best = summary
		end
	end
	return best
end

local function update_summary(id, fields, lane)
	lane = normalize_lane(lane)
	local summary = summary_by_id(state.get_session(lane), id)
	if not summary then
		return nil
	end
	for key, value in pairs(fields or {}) do
		summary[key] = value
	end
	render_buffer(summary, lane)
	return summary
end

function M.create(prompt, opts, lane)
	lane = normalize_lane(lane)
	local session = state.ensure_session(lane)
	local id, seq = next_id(session)
	local summary = {
		id = id,
		seq = seq,
		kind = "patch",
		operation = "patch",
		prompt = prompt or "",
		status = "running",
		target = opts and opts.target or nil,
		inspected_files = {},
		edited_files = {},
		tool_lines = {},
		diff_blocks = {},
		started_at = vim.uv.hrtime(),
	}
	summary.name = summary_name(summary)
	table.insert(ensure_state(session), summary)
	return id
end

function M.get(id, lane)
	lane = normalize_lane(lane)
	return summary_by_id(state.get_session(lane), id)
end

function M.open_split(id, lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	local summary = id and summary_by_id(session, id) or latest_summary(session)
	if not summary then
		return nil
	end
	local buf = ensure_buffer(summary, lane)
	render_buffer(summary, lane)
	local win = vim.fn.win_findbuf(buf)[1]
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
	else
		vim.cmd("botright vsplit")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		pcall(vim.api.nvim_win_set_width, win, math.min(math.max(math.floor(vim.o.columns * 0.38), 44), 82))
	end
	configure_window(win)
	pcall(function()
		vim.wo[win].winbar = summary_winbar(summary)
	end)
	pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
	return win
end

local function tool_line(tool, lane)
	local path = display_path(tool.path, lane)
	if tool.kind == "edit" then
		return string.format("• Edited %s (+%d -%d)", path, tool.added or 0, tool.removed or 0)
	end
	if tool.kind == "write" then
		return "• Wrote " .. path
	end
	if tool.kind == "read" then
		return "• Read " .. path
	end
	return "• Ran " .. (tool.kind or "tool")
end

function M.record_tool(id, tool, lane)
	lane = normalize_lane(lane)
	local summary = summary_by_id(state.get_session(lane), id)
	if not summary then
		return nil
	end
	local inspected = vim.deepcopy(summary.inspected_files or {})
	local edited = vim.deepcopy(summary.edited_files or {})
	local lines = vim.deepcopy(summary.tool_lines or {})
	local diffs = vim.deepcopy(summary.diff_blocks or {})
	if tool.kind == "read" then
		add_unique(inspected, tool.path)
	end
	if tool.kind == "edit" or tool.kind == "write" then
		add_unique(edited, tool.path)
	end
	table.insert(lines, tool_line(tool, lane))
	if tool.diff and tool.diff ~= "" then
		table.insert(diffs, { path = tool.path, diff = tool.diff })
	end
	return update_summary(
		id,
		{ diff_blocks = diffs, edited_files = edited, inspected_files = inspected, tool_lines = lines },
		lane
	)
end

function M.finish(id, status, fields, lane)
	return update_summary(id, {
		assistant_summary = fields and (fields.assistant_summary or fields.summary),
		error_summary = fields and fields.error_summary,
		finished_at = vim.uv.hrtime(),
		status = status or "success",
	}, lane)
end

function M.dismiss(id, lane)
	lane = normalize_lane(lane)
	local summary = summary_by_id(state.get_session(lane), id)
	if not summary then
		return false
	end
	summary.dismissed = true
	close_summary_windows(summary)
	return true
end

function M.focus_relative(id, lane, delta)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	local summaries = sorted_summaries(session)
	if #summaries == 0 then
		return false
	end
	local index = 1
	for i, summary in ipairs(summaries) do
		if summary.id == id then
			index = i
			break
		end
	end
	local target = summaries[((index - 1 + delta) % #summaries) + 1]
	return target and M.open_split(target.id, lane) or false
end

function M.clear_completed(opts)
	opts = opts or {}
	local count = 0
	for _, lane in ipairs(state.lanes()) do
		local session = state.get_session(lane)
		for _, summary in ipairs(session and ensure_state(session) or {}) do
			if not summary.dismissed and (opts.all or summary.status ~= "running") then
				if M.dismiss(summary.id, lane) then
					count = count + 1
				end
			end
		end
	end
	return count
end

function M.items(lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	return vim.deepcopy(session and ensure_state(session) or {})
end

return M
