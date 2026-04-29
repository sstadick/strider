local render = require("strider.review.render")

local M = {}

local MAX_REVIEW_LINES = 40

local function read_lines(path, start_line, end_line)
	local buf = vim.fn.bufnr(path)
	if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
		return vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
	end
	local all = vim.fn.readfile(path)
	local lines = {}
	for line = start_line, math.min(end_line, #all) do
		table.insert(lines, all[line])
	end
	return lines
end

local function excerpt(path, start_line, end_line)
	local final_line = math.min(end_line, start_line + 12)
	return table.concat(read_lines(path, start_line, final_line), "\n")
end

local function relative_path(cwd, path)
	if cwd and vim.startswith(path, cwd .. "/") then
		return path:sub(#cwd + 2)
	end
	return path
end

local function git_run(cwd, args)
	local cmd = string.format("git -C %s %s", vim.fn.shellescape(cwd), args)
	local output = vim.fn.systemlist(cmd)
	return vim.v.shell_error == 0 and output or nil
end

local function make_stop(cwd, path, start_line, end_line, kind, why)
	local stop_excerpt = excerpt(path, start_line, end_line)
	local title = render.chunk_title(path, kind, stop_excerpt) or relative_path(cwd, path)
	return {
		id = string.format("%s:%d-%d", path, start_line, end_line),
		path = path,
		startLine = start_line,
		endLine = end_line,
		kind = kind,
		title = title,
		why = why,
		excerpt = stop_excerpt,
		status = "pending",
	}
end

local function chunk_range(cwd, path, start_line, end_line, kind, why_fn)
	local stops = {}
	local chunk_start = start_line
	while chunk_start <= end_line do
		local chunk_end = math.min(chunk_start + MAX_REVIEW_LINES - 1, end_line)
		local why = why_fn and why_fn(chunk_start, chunk_end) or nil
		table.insert(stops, make_stop(cwd, path, chunk_start, chunk_end, kind, why))
		chunk_start = chunk_end + 1
	end
	return stops
end

local function gaps_for_target(target, covered_ranges)
	local gaps = {}
	local cursor = target.startLine
	table.sort(covered_ranges, function(a, b)
		return a[1] < b[1]
	end)
	for _, seg in ipairs(covered_ranges) do
		if seg[1] > target.endLine then
			break
		end
		if seg[2] >= cursor then
			if seg[1] > cursor then
				table.insert(gaps, { path = target.path, startLine = cursor, endLine = seg[1] - 1 })
			end
			cursor = seg[2] + 1
		end
	end
	if cursor <= target.endLine then
		table.insert(gaps, { path = target.path, startLine = cursor, endLine = target.endLine })
	end
	return gaps
end

function M.ranges_cover(target_ranges, stop_ranges)
	local covered = {}
	for _, stop in ipairs(stop_ranges) do
		local list = covered[stop.path] or {}
		table.insert(list, { stop.startLine, stop.endLine })
		covered[stop.path] = list
	end

	local gaps = {}
	for _, target in ipairs(target_ranges) do
		vim.list_extend(gaps, gaps_for_target(target, covered[target.path] or {}))
	end
	return #gaps == 0, gaps
end

function M.plan_from_range(cwd, path, start_line, end_line)
	if not path or not start_line or not end_line or start_line > end_line then
		return nil
	end
	local stops = chunk_range(cwd, path, start_line, end_line, "selection", function(s, e)
		return string.format("Selected range %d-%d", s, e)
	end)
	local ok = M.ranges_cover({ { path = path, startLine = start_line, endLine = end_line } }, stops)
	return { scope = "selection", stops = stops, coverage_ok = ok }
end

local function parse_diff_hunks(diff_text)
	local files = {}
	local current = nil
	for _, line in ipairs(vim.split(diff_text or "", "\n", { plain = true })) do
		local new_path = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
		if new_path and new_path ~= "/dev/null" then
			current = { path = new_path, hunks = {} }
			files[new_path] = current
		else
			local hunk_start, hunk_len = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*)")
			if hunk_start and current then
				local start_line = tonumber(hunk_start)
				local length = tonumber(hunk_len)
				if length == nil or length == 0 then
					length = 1
				end
				table.insert(current.hunks, { start_line, start_line + length - 1 })
			end
		end
	end
	local result = {}
	for path, entry in pairs(files) do
		result[path] = entry.hunks
	end
	return result
end

local function sorted_keys(tbl)
	local keys = {}
	for key in pairs(tbl) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

function M.plan_from_diff(cwd, base)
	if not cwd or not base or base == "" then
		return nil
	end
	local diff = git_run(cwd, string.format("diff --unified=0 %s...HEAD", vim.fn.shellescape(base)))
	if not diff then
		return { scope = "diff", base = base, stops = {}, coverage_ok = true }
	end

	local stops = {}
	local target_ranges = {}
	local per_file = parse_diff_hunks(table.concat(diff, "\n"))
	for _, rel_path in ipairs(sorted_keys(per_file)) do
		local abs_path = vim.fs.joinpath(cwd, rel_path)
		local hunks = per_file[rel_path]
		table.sort(hunks, function(a, b)
			return a[1] < b[1]
		end)
		for _, hunk in ipairs(hunks) do
			local start_line, end_line = hunk[1], hunk[2]
			table.insert(target_ranges, { path = abs_path, startLine = start_line, endLine = end_line })
			vim.list_extend(
				stops,
				chunk_range(cwd, abs_path, start_line, end_line, "diff", function(s, e)
					return string.format("Changed lines %d-%d in %s", s, e, rel_path)
				end)
			)
		end
	end

	local ok = M.ranges_cover(target_ranges, stops)
	return { scope = "diff", base = base, stops = stops, coverage_ok = ok }
end

local function file_lines(path)
	local buf = vim.fn.bufnr(path)
	if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
		return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	return ok and lines or nil
end

local function find_anchor_line(path, needle, hint_line)
	if not path or not needle or needle == "" then
		return nil
	end
	local trimmed_needle = vim.trim(needle)
	if trimmed_needle == "" then
		return nil
	end

	local lines = file_lines(path)
	if not lines or #lines == 0 then
		return nil
	end

	local best_line = nil
	local best_distance = math.huge
	for index, line in ipairs(lines) do
		if vim.trim(line or "") == trimmed_needle then
			local distance = math.abs(index - (hint_line or index))
			if distance < best_distance then
				best_distance = distance
				best_line = index
			end
		end
	end
	return best_line
end

local function shifted_annotation(ann, offset)
	local line_num = tonumber(ann.line)
	local start_line = tonumber(ann.startLine)
	local end_line = tonumber(ann.endLine)
	if offset ~= 0 then
		if line_num then
			line_num = line_num + offset
		end
		if start_line then
			start_line = start_line + offset
		end
		if end_line then
			end_line = end_line + offset
		end
	end
	return {
		kind = ann.kind == "line" and "line" or "block",
		line = line_num,
		startLine = start_line,
		endLine = end_line,
		text = tostring(ann.text),
	}
end

local function clean_annotations(raw_annotations, offset)
	local clean = {}
	for _, ann in ipairs(raw_annotations or {}) do
		if type(ann) == "table" and ann.text and ann.text ~= "" then
			table.insert(clean, shifted_annotation(ann, offset))
		end
	end
	return #clean > 0 and clean or nil
end

function M.normalize_stop(cwd, raw)
	if not raw or not raw.path or not raw.startLine or not raw.endLine then
		return nil
	end
	local path = raw.path:match("^/") and raw.path or vim.fs.joinpath(cwd, raw.path)
	local start_line = tonumber(raw.startLine)
	local end_line = tonumber(raw.endLine)
	if not start_line or not end_line or start_line > end_line then
		return nil
	end

	local offset = 0
	if raw.firstLineText and raw.firstLineText ~= "" then
		local anchor = find_anchor_line(path, raw.firstLineText, start_line)
		if anchor and anchor ~= start_line then
			offset = anchor - start_line
			start_line = anchor
			end_line = end_line + offset
		end
	end

	local stop = make_stop(cwd, path, start_line, end_line, raw.kind or "planned", raw.why)
	stop.title = raw.title and raw.title ~= "" and raw.title or stop.title
	stop.summary = raw.summary and raw.summary ~= "" and raw.summary or stop.why
	stop.explanation = raw.explanation and raw.explanation ~= "" and raw.explanation or nil
	stop.annotations = type(raw.annotations) == "table" and clean_annotations(raw.annotations, offset) or nil
	return stop
end

return M
