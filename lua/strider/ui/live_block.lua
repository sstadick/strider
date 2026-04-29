local state = require("strider.state")

local M = {}

local THROTTLE_MS = 50

local function normalize_lane(lane)
	return state.normalize_lane(lane)
end

local function create(lane, ensure_log_buffer)
	local buf = ensure_log_buffer(lane)
	return {
		buf = buf,
		start_row = vim.api.nvim_buf_line_count(buf),
		lines_in_buffer = 0,
		pending_text = nil,
		flush_pending = false,
	}
end

function M.start(lane, deps)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return
	end
	if session.live_block then
		deps.finalize(nil, nil, lane)
	end
	session.live_block = create(lane, deps.ensure_log_buffer)
end

function M.ensure(lane, deps)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session or session.live_block then
		return
	end
	session.live_block = create(lane, deps.ensure_log_buffer)
end

local function flush(lb, scroll)
	local text = lb.pending_text
	lb.pending_text = nil
	lb.flush_pending = false
	if not text or not vim.api.nvim_buf_is_valid(lb.buf) then
		return
	end

	local lines = vim.split(text, "\n", { plain = true })
	while #lines > 1 and lines[#lines] == "" do
		table.remove(lines)
	end
	if #lines == 0 then
		return
	end

	local old_count = lb.lines_in_buffer
	local new_count = #lines
	if new_count > old_count and old_count > 0 then
		vim.api.nvim_buf_set_lines(
			lb.buf,
			lb.start_row + old_count - 1,
			lb.start_row + old_count,
			false,
			{ lines[old_count] }
		)
		if new_count > old_count then
			local tail = {}
			for i = old_count + 1, new_count do
				tail[#tail + 1] = lines[i]
			end
			vim.api.nvim_buf_set_lines(lb.buf, lb.start_row + old_count, lb.start_row + old_count, false, tail)
		end
	else
		vim.api.nvim_buf_set_lines(lb.buf, lb.start_row, lb.start_row + old_count, false, lines)
	end

	lb.lines_in_buffer = new_count
	scroll(lb.buf)
end

function M.update(full_text, lane, deps)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	local lb = session and session.live_block
	if not lb or not vim.api.nvim_buf_is_valid(lb.buf) then
		return
	end
	lb.pending_text = full_text
	if lb.flush_pending then
		return
	end
	lb.flush_pending = true
	vim.defer_fn(function()
		local current = state.get_session(lane)
		if current and current.live_block == lb then
			flush(lb, deps.scroll)
		end
	end, THROTTLE_MS)
end

function M.finalize(label, text, lane, deps)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return
	end
	local lb = session.live_block
	session.live_block = nil
	if lb then
		if lb.pending_text then
			flush(lb, deps.scroll)
		end
		if vim.api.nvim_buf_is_valid(lb.buf) and lb.lines_in_buffer > 0 then
			vim.api.nvim_buf_set_lines(lb.buf, lb.start_row, lb.start_row + lb.lines_in_buffer, false, {})
		end
	end
	if label and text and vim.trim(text) ~= "" then
		deps.append_block(label, text, lane)
	end
end

return M
