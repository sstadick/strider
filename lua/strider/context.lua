local M = {}

function M.trimmed(text)
	return vim.trim(text or "")
end

function M.current_buffer_path()
	local path = vim.api.nvim_buf_get_name(0)
	return path ~= "" and path or nil
end

function M.range_from_opts(opts)
	if not opts or tonumber(opts.range or 0) == 0 then
		return nil
	end
	local path = M.current_buffer_path()
	if not path then
		return nil
	end
	return {
		path = path,
		startLine = tonumber(opts.line1) or 1,
		endLine = tonumber(opts.line2) or tonumber(opts.line1) or 1,
	}
end

function M.display_path(path, cwd)
	if path and cwd and vim.startswith(path, cwd .. "/") then
		return path:sub(#cwd + 2)
	end
	return path
end

function M.range_pointer(range, cwd)
	if not range then
		return nil
	end
	return string.format("%s:%d-%d", M.display_path(range.path, cwd), range.startLine, range.endLine)
end

function M.chat_prefill(prompt, range, cwd)
	local parts = {}
	local pointer = M.range_pointer(range, cwd)
	local text = M.trimmed(prompt)
	if pointer then
		table.insert(parts, pointer)
	end
	if text ~= "" then
		table.insert(parts, text)
	end
	return table.concat(parts, "\n\n")
end

function M.read_excerpt(path, start_line, end_line)
	local buf = vim.fn.bufnr(path)
	if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
		return table.concat(vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false), "\n")
	end
	local all = vim.fn.readfile(path)
	local lines = {}
	for line = start_line, math.min(end_line, #all) do
		table.insert(lines, all[line])
	end
	return table.concat(lines, "\n")
end

return M
