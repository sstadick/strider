local highlights = require("strider.ui.highlights")
local state = require("strider.state")

local M = {}

local chunk_namespace = vim.api.nvim_create_namespace("strider-chunk")
local comment_namespace = vim.api.nvim_create_namespace("strider-comments")
local annotation_namespace = vim.api.nvim_create_namespace("strider-annotations")
local G = highlights.groups

-- Per-buffer checktime guard. checktime is expensive (stat + potential
-- reload). A single stop focus can touch the same buffer several times;
-- skip re-checking within 500ms.
local checktime_stamps = {}
local CHECKTIME_DEBOUNCE_NS = 500e6

local function clamp(value, low, high)
	return math.min(math.max(tonumber(value) or low, low), high)
end

function M.refresh_buffer(buf)
	if not buf or buf <= 0 or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified then
		return
	end
	local now = vim.uv.hrtime()
	local last = checktime_stamps[buf]
	if last and (now - last) < CHECKTIME_DEBOUNCE_NS then
		return
	end
	checktime_stamps[buf] = now
	vim.api.nvim_buf_call(buf, function()
		pcall(vim.cmd, "silent checktime")
	end)
end

function M.buffer_for_path(path)
	if not path or path == "" then
		return nil
	end
	local buf = vim.fn.bufnr(path)
	if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
		M.refresh_buffer(buf)
		return buf
	end
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

local function ordered_chunk_marks(lines, max_line)
	local marks_by_line = {}
	local ordered = {}
	for _, item in ipairs(lines or {}) do
		local line = type(item) == "table" and item.line or item
		local kind = type(item) == "table" and item.kind or "added"
		local target = clamp(line, 1, max_line)
		if not marks_by_line[target] then
			marks_by_line[target] = kind
			table.insert(ordered, target)
		elseif marks_by_line[target] ~= "removed" and kind == "removed" then
			marks_by_line[target] = kind
		end
	end
	table.sort(ordered)
	return ordered, marks_by_line
end

local function set_chunk_mark(buf, line, kind)
	local removed = kind == "removed"
	vim.api.nvim_buf_set_extmark(buf, chunk_namespace, line - 1, 0, {
		priority = removed and 11 or 10,
		sign_hl_group = removed and G.removed_chunk or G.added_chunk,
		sign_text = removed and "-" or "▎",
	})
end

function M.highlight_lines(path, lines, lane)
	local session = state.get_session(lane) or state.ensure_session(lane or "main", vim.fn.getcwd())
	local buf = M.buffer_for_path(path)
	if not buf then
		return
	end

	clear_chunk_highlight(session)
	highlights.ensure()

	local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
	local ordered, marks_by_line = ordered_chunk_marks(lines, max_line)
	for _, target in ipairs(ordered) do
		set_chunk_mark(buf, target, marks_by_line[target])
	end

	session.chunk_lines = ordered
	session.chunk_path = path
	session.highlight_buf = buf
end

function M.highlight_range(path, first_line, last_line, lane)
	local buf = M.buffer_for_path(path)
	if not buf then
		return
	end

	local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
	local start_line = clamp(first_line, 1, max_line)
	local end_line = clamp(last_line or max_line, start_line, max_line)
	local lines = {}
	for line = start_line, end_line do
		table.insert(lines, { line = line, kind = "added" })
	end
	M.highlight_lines(path, lines, lane)
end

local function wrap_text(text, width)
	width = width or 78
	local out = {}
	for _, raw_line in ipairs(vim.split(text or "", "\n", { plain = true })) do
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

local annotated_bufs = {}

function M.clear_stop_annotations()
	for buf in pairs(annotated_bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_clear_namespace, buf, annotation_namespace, 0, -1)
		end
	end
	annotated_bufs = {}
end

local function render_block(buf, anchor_line, text)
	if not text or text == "" then
		return
	end
	local virt_lines =
		{ { { "┌─ strider ─────────────────────", G.annotation } } }
	for _, line in ipairs(wrap_text(text, 78)) do
		table.insert(virt_lines, { { "│ " .. line, G.annotation } })
	end
	table.insert(virt_lines, {
		{
			"└──────────────────────────────",
			G.annotation,
		},
	})
	pcall(vim.api.nvim_buf_set_extmark, buf, annotation_namespace, anchor_line - 1, 0, {
		virt_lines = virt_lines,
		virt_lines_above = anchor_line > 1,
		priority = 40,
	})
end

local function render_line_annotation(buf, bounds, line_no, text)
	if not text or text == "" then
		return
	end
	local target = clamp(line_no, bounds.start_line, bounds.end_line)
	pcall(vim.api.nvim_buf_set_extmark, buf, annotation_namespace, target - 1, 0, {
		virt_text = { { "  ◂ " .. text, G.annotation } },
		virt_text_pos = "eol",
		priority = 40,
	})
end

local function stop_bounds(buf, item)
	local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
	local start_line = clamp(item.startLine, 1, max_line)
	local end_line = clamp(item.endLine or start_line, start_line, max_line)
	return { start_line = start_line, end_line = end_line }
end

local function render_extra_annotations(buf, item, bounds)
	for _, ann in ipairs(item.annotations or {}) do
		if ann.kind == "block" and tonumber(ann.startLine) then
			render_block(buf, clamp(ann.startLine, bounds.start_line, bounds.end_line), ann.text)
		elseif ann.kind == "line" then
			render_line_annotation(buf, bounds, ann.line, ann.text)
		end
	end
end

function M.set_stop_annotations(item)
	if not item or not item.path then
		return
	end
	local buf = M.buffer_for_path(item.path)
	if not buf then
		return
	end

	highlights.ensure()
	annotated_bufs[buf] = true

	local bounds = stop_bounds(buf, item)
	render_block(buf, bounds.start_line, item.explanation)
	render_extra_annotations(buf, item, bounds)
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
	if not session then
		return
	end
	local buf = M.buffer_for_path(path)
	if not buf then
		return
	end

	highlights.ensure()
	local max_line = math.max(vim.api.nvim_buf_line_count(buf), 1)
	local target = clamp(line, 1, max_line)
	vim.api.nvim_buf_set_extmark(buf, comment_namespace, target - 1, 0, {
		priority = 20,
		sign_hl_group = G.comment,
		sign_text = "●",
	})

	session.comment_buffers = session.comment_buffers or {}
	if not vim.tbl_contains(session.comment_buffers, buf) then
		table.insert(session.comment_buffers, buf)
	end
end

return M
