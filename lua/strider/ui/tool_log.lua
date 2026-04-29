local highlights = require("strider.ui.highlights")
local state = require("strider.state")

local M = {}

local ns = vim.api.nvim_create_namespace("strider-log")
local G = highlights.groups
local tool_hl = G.log_tool
local path_hl = G.log_path
local muted_hl = G.log_muted
local diff_stats_hl = G.log_diff_stats
local output_hl = G.log_tool_output
local output_ellipsis_hl = G.log_tool_output_ellipsis
local output_gutter_hl = G.log_tool_output_gutter
local output_meta_hl = G.log_tool_output_meta
local output_error_hl = G.log_tool_output_error

local function log_lines(lines)
	local text = table.concat(lines, "\n")
	if text ~= "" and not text:match("\n$") then
		text = text .. "\n"
	end
	return vim.split(text, "\n", { plain = true })
end

local tool_verbs = {
	read = "Explored",
	edit = "Edited",
	write = "Wrote",
	bash = "Ran",
	grep = "Explored",
	find = "Explored",
	ls = "Explored",
	subagent = "Delegated",
}

local function highlight_tool_header(buf, row, tool_name, path, suffix)
	local verb = tool_verbs[tool_name] or "Ran"
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
		end_row = row + 1,
		hl_group = tool_hl,
		priority = 10,
	})
	if path and path ~= "" then
		local prefix_len = #("• " .. verb .. " ")
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, prefix_len, {
			end_row = row,
			end_col = prefix_len + #path,
			hl_group = path_hl,
			priority = 11,
		})
		if suffix and suffix ~= "" then
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, prefix_len + #path, {
				end_row = row,
				end_col = prefix_len + #path + #suffix,
				hl_group = diff_stats_hl,
				priority = 11,
			})
		end
	end
end

function M.update_tool_line(row, tool_name, path, suffix, lane)
	lane = state.normalize_lane(lane)
	local session = state.get_session(lane)
	local buf = session and session.log_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) or not row then
		return
	end
	local verb = tool_verbs[tool_name] or "Ran"
	local detail = path and path ~= "" and (" " .. path .. (suffix or "")) or ""
	pcall(vim.api.nvim_buf_clear_namespace, buf, ns, row, row + 1)
	vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { "• " .. verb .. detail })
	highlight_tool_header(buf, row, tool_name, path, suffix)
end

function M.append_tool_line(tool_name, path, range, lane, deps)
	local buf = deps.ensure_log_buffer(lane)
	local verb = tool_verbs[tool_name] or "Ran"

	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		deps.append(
			{ string.format("• %s", verb), string.format("  └ %s %s%s", tool_name, path or "", range or "") },
			lane
		)
		return
	end

	if tool_name == "edit" and path and path ~= "" then
		local start_row = vim.api.nvim_buf_line_count(buf)
		deps.append({ string.format("• %s %s", verb, path) }, lane)
		highlight_tool_header(buf, start_row, tool_name, path, nil)
		return
	end

	local header = string.format("• %s", verb)
	local detail = string.format("  └ %s %s%s", tool_name, path or "", range or "")
	local start_row = vim.api.nvim_buf_line_count(buf)
	deps.append({ header, detail }, lane)

	pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_row, 0, {
		end_row = start_row + 1,
		hl_group = tool_hl,
		priority = 10,
	})
	local path_text = (path or "") .. (range or "")
	if path_text ~= "" then
		local prefix_len = #("  └ " .. tool_name .. " ")
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_row + 1, prefix_len, {
			end_row = start_row + 1,
			end_col = prefix_len + #path_text,
			hl_group = path_hl,
			priority = 10,
		})
	end
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_row + 1, 0, {
		end_row = start_row + 1,
		end_col = #"  └ ",
		hl_group = muted_hl,
		priority = 8,
	})
end

function M.mark_tool_header(tool_call_id, lane)
	if not tool_call_id then
		return
	end
	lane = state.normalize_lane(lane)
	local session = state.get_session(lane)
	local buf = session and session.log_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local row = math.max(vim.api.nvim_buf_line_count(buf) - 2, 0)
	session.tool_marks[tool_call_id] = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {})
end

function M.pop_tool_insert_row(tool_call_id, lane)
	if not tool_call_id then
		return nil
	end
	lane = state.normalize_lane(lane)
	local session = state.get_session(lane)
	local buf = session and session.log_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	local marks = session.tool_marks
	local mark_id = marks and marks[tool_call_id]
	if not mark_id then
		return nil
	end
	marks[tool_call_id] = nil
	local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, ns, mark_id, {})
	pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark_id)
	if ok and pos and pos[1] then
		return pos[1] + 1
	end
	return nil
end

local TOOL_OUTPUT_MAX_LINES = 5
local TOOL_OUTPUT_HEAD_LINES = math.floor((TOOL_OUTPUT_MAX_LINES - 1) / 2)
local TOOL_OUTPUT_TAIL_LINES = TOOL_OUTPUT_MAX_LINES - 1 - TOOL_OUTPUT_HEAD_LINES

local function tool_output_window(text)
	if type(text) ~= "string" or vim.trim(text) == "" then
		return nil
	end

	local all_lines = vim.split(text, "\n", { plain = true })
	local last_meaningful = #all_lines
	while last_meaningful > 0 do
		local line = all_lines[last_meaningful]
		if line == "" or line:match("^%[%d+ more lines in file%..-%]$") then
			last_meaningful = last_meaningful - 1
		else
			break
		end
	end
	if last_meaningful == 0 then
		return nil
	end
	if last_meaningful <= TOOL_OUTPUT_MAX_LINES then
		return all_lines, last_meaningful, 0, last_meaningful, nil
	end

	local head_end = math.min(TOOL_OUTPUT_HEAD_LINES, last_meaningful)
	local tail_start = math.max(head_end + 1, last_meaningful - TOOL_OUTPUT_TAIL_LINES + 1)
	local omitted = math.max(0, tail_start - head_end - 1)
	return all_lines, last_meaningful, omitted, head_end, tail_start
end

local function tool_output_ellipsis(omitted)
	return string.format("… +%d lines", omitted)
end

local function add_fenced_tool_segment(lines, all_lines, lang, first_line, last_line)
	if not first_line or not last_line or first_line > last_line then
		return
	end
	lines[#lines + 1] = lang and ("```" .. lang) or "```"
	for i = first_line, last_line do
		lines[#lines + 1] = all_lines[i]
	end
	lines[#lines + 1] = "```"
end

function M.append_tool_output(text, lang, lane, opts, deps)
	opts = opts or {}
	local all_lines, last_meaningful, omitted, head_end, tail_start = tool_output_window(text)
	if not all_lines then
		return
	end

	local session = state.get_session(lane)
	local buf = session and session.log_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local lines = {}
	local marker_offset
	add_fenced_tool_segment(lines, all_lines, lang, 1, head_end)
	if omitted > 0 then
		lines[#lines + 1] = tool_output_ellipsis(omitted)
		marker_offset = #lines - 1
		add_fenced_tool_segment(lines, all_lines, lang, tail_start, last_meaningful)
	end
	lines[#lines + 1] = ""

	local items = log_lines(lines)
	if #items == 0 then
		return
	end

	local start_row
	if opts.insert_at then
		start_row = opts.insert_at
		vim.api.nvim_buf_set_lines(buf, start_row, start_row, false, items)
	else
		start_row = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
	end
	deps.scroll(buf)

	if marker_offset ~= nil then
		local marker_row = start_row + marker_offset
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, marker_row, 0, {
			end_row = marker_row + 1,
			hl_group = output_ellipsis_hl,
			priority = 10,
		})
	end
end

local compact_output_prefix = "  │ "
local compact_output_gutter = "  │"

local function compact_count_label(opts, count)
	if not opts.count_label and not opts.count_singular and not opts.count_plural then
		return nil
	end
	if count == 1 then
		return opts.count_singular or opts.count_label or opts.count_plural
	end
	return opts.count_plural or opts.count_label or opts.count_singular
end

local function compact_status_line(status)
	local code = tonumber(status)
	if not code then
		return nil, nil
	end
	if code == 0 then
		return "  ✓ exited 0", "meta"
	end
	return string.format("  ✗ exited %d", code), "error"
end

local function add_compact_extmarks(buf, start_row, roles, items)
	for offset, role in ipairs(roles) do
		local row = start_row + offset - 1
		local line = items[offset] or ""
		if role == "row" then
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, #"  ", {
				end_row = row,
				end_col = #compact_output_gutter,
				hl_group = output_gutter_hl,
				priority = 10,
			})
			if #line > #compact_output_prefix then
				pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, #compact_output_prefix, {
					end_row = row,
					end_col = #line,
					hl_group = output_hl,
					priority = 9,
				})
			end
		elseif role == "meta" or role == "error" then
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
				end_row = row + 1,
				hl_group = role == "error" and output_error_hl or output_meta_hl,
				priority = 10,
			})
		end
	end
end

local function compact_tool_output_lines(tool_opts, all_lines, last_meaningful, omitted, head_end, tail_start)
	local lines = {}
	local roles = {}
	local count_label = compact_count_label(tool_opts, last_meaningful)
	if count_label then
		lines[#lines + 1] = string.format("  %d %s", last_meaningful, count_label)
		roles[#roles + 1] = "meta"
	end
	for i = 1, head_end do
		lines[#lines + 1] = compact_output_prefix .. all_lines[i]
		roles[#roles + 1] = "row"
	end
	if omitted > 0 then
		lines[#lines + 1] = "  " .. tool_output_ellipsis(omitted)
		roles[#roles + 1] = "meta"
		for i = tail_start, last_meaningful do
			lines[#lines + 1] = compact_output_prefix .. all_lines[i]
			roles[#roles + 1] = "row"
		end
	end
	local status_line, status_role = compact_status_line(tool_opts.status)
	if status_line then
		lines[#lines + 1] = status_line
		roles[#roles + 1] = status_role
	end
	lines[#lines + 1] = ""
	roles[#roles + 1] = "blank"
	return lines, roles
end

function M.append_compact_tool_output(text, tool_opts, lane, opts, deps)
	opts = opts or {}
	tool_opts = tool_opts or {}
	highlights.ensure()

	local all_lines, last_meaningful, omitted, head_end, tail_start = tool_output_window(text)
	if not all_lines then
		return
	end

	local session = state.get_session(lane)
	local buf = session and session.log_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local lines, roles = compact_tool_output_lines(tool_opts, all_lines, last_meaningful, omitted, head_end, tail_start)
	local items = log_lines(lines)
	if #items == 0 then
		return
	end

	local start_row
	if opts.insert_at then
		start_row = opts.insert_at
		vim.api.nvim_buf_set_lines(buf, start_row, start_row, false, items)
	else
		start_row = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
	end
	add_compact_extmarks(buf, start_row, roles, items)
	deps.scroll(buf)
end

return M
