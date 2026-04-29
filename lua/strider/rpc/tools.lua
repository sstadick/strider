local ui = require("strider.ui")

local M = {}

local function quoted(value)
	return type(value) == "string" and string.format("%q", value) or nil
end

local function option_summary(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local option = select(i, ...)
		if option then
			table.insert(parts, option)
		end
	end
	return #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
end

local function grep_args(args)
	local query = quoted(args.pattern)
	if not query then
		return args.path
	end
	local target = args.path and (" in " .. args.path) or ""
	return query
		.. target
		.. option_summary(
			args.glob and ("glob " .. args.glob),
			args.ignoreCase and "ignore-case",
			args.literal and "literal",
			args.context and ("context " .. args.context),
			args.limit and ("limit " .. args.limit)
		)
end

local function find_args(args)
	local query = args.pattern
	if not query then
		return args.path
	end
	local target = args.path and (" in " .. args.path) or ""
	return query .. target .. option_summary(args.limit and ("limit " .. args.limit))
end

local function ls_args(args)
	if not args.path then
		return nil
	end
	return args.path .. option_summary(args.limit and ("limit " .. args.limit))
end

local function format_tool_args(tool_name, args)
	if not args then
		return nil
	end
	if tool_name == "grep" then
		return grep_args(args)
	end
	if tool_name == "find" then
		return find_args(args)
	end
	if tool_name == "ls" then
		return ls_args(args)
	end
	if tool_name ~= "subagent" then
		return nil
	end

	local parts = {}
	if args.agent then
		table.insert(parts, args.agent)
	end
	if args.task then
		table.insert(parts, args.task:sub(1, 80))
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

local summary_tools = {
	grep = true,
	find = true,
	ls = true,
	subagent = true,
}

local summary_verbs = {
	subagent = "Delegated",
}

local function append_tool_summary(tool_name, summary, lane)
	local verb = summary_verbs[tool_name] or "Explored"
	ui.append({ "• " .. verb, string.format("  └ %s %s", tool_name, summary) }, lane)
end

function M.append_tool(tool_name, args, lane)
	if tool_name == "strider_vim" then
		local raw_intent = args and args.intent
		local intent = type(raw_intent) == "string" and vim.trim(raw_intent) or ""
		ui.append({ "• Vim" .. (intent ~= "" and (": " .. intent) or "") }, lane)
		return
	end

	local summary = summary_tools[tool_name] and format_tool_args(tool_name, args)
	if summary then
		append_tool_summary(tool_name, summary, lane)
		return
	end

	local path = args and args.path
	if path then
		if tool_name == "read" then
			local start_line = tonumber(args.offset) or 1
			local limit = tonumber(args.limit)
			local range = limit and string.format(":%d-%d", start_line, start_line + limit - 1)
				or string.format(":%d", start_line)
			ui.append_tool_line(tool_name, path, range, lane)
			return
		end
		ui.append_tool_line(tool_name, path, nil, lane)
		return
	end

	if tool_name == "bash" and args and args.command then
		ui.append({ string.format("• Ran command"), string.format("  └ %s", args.command) }, lane)
		return
	end

	summary = format_tool_args(tool_name, args)
	if summary then
		append_tool_summary(tool_name, summary, lane)
		return
	end

	ui.append({ string.format("• Ran %s", tool_name) }, lane)
end

local function is_absolute_path(path)
	return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
end

function M.absolute_path(session, path)
	if not session or not path or path == "" then
		return nil
	end
	if is_absolute_path(path) then
		return path
	end
	return vim.fs.joinpath(session.cwd, path)
end

function M.tool_result_text(event)
	local result = event.result
	if not result or not result.content then
		return nil
	end
	local parts = {}
	for _, item in ipairs(result.content) do
		if item.type == "text" and type(item.text) == "string" then
			table.insert(parts, item.text)
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

local compact_tool_output = {
	bash = {},
	grep = { count_singular = "match", count_plural = "matches" },
	ls = { count_singular = "entry", count_plural = "entries" },
	find = { count_singular = "path", count_plural = "paths" },
}

function M.fenced_output(tool_name)
	return tool_name == "read" or tool_name == "write"
end

function M.compact_output_opts(tool_name)
	return compact_tool_output[tool_name]
end

local lang_by_ext = {
	lua = "lua",
	ts = "typescript",
	tsx = "tsx",
	mts = "typescript",
	cts = "typescript",
	js = "javascript",
	jsx = "javascript",
	mjs = "javascript",
	cjs = "javascript",
	py = "python",
	pyi = "python",
	rs = "rust",
	go = "go",
	md = "markdown",
	markdown = "markdown",
	json = "json",
	yaml = "yaml",
	yml = "yaml",
	toml = "toml",
	sh = "bash",
	bash = "bash",
	zsh = "bash",
	html = "html",
	htm = "html",
	css = "css",
	scss = "scss",
	c = "c",
	h = "c",
	cpp = "cpp",
	cc = "cpp",
	hpp = "cpp",
	hh = "cpp",
	cxx = "cpp",
	java = "java",
	rb = "ruby",
	sql = "sql",
}

function M.language_for_path(path)
	if not path then
		return nil
	end
	local ext = path:match("%.([%w]+)$")
	if not ext then
		return nil
	end
	return lang_by_ext[ext:lower()]
end

local function first_changed_line(event)
	local details = event.result and event.result.details
	return details and tonumber(details.firstChangedLine) or 1
end

function M.changed_lines(event)
	local details = event.result and event.result.details
	local start = first_changed_line(event)
	local diff = details and details.diff
	if not diff then
		return { { line = start, kind = "added" } }
	end

	local changes = {}
	local seen = {}
	local anchor = start

	local function add_change(line, kind)
		local target = tonumber(line) or start
		local key = string.format("%s:%d", kind, target)
		if seen[key] then
			return
		end
		seen[key] = true
		table.insert(changes, { line = target, kind = kind })
	end

	for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
		local added = tonumber(line:match("^%+%s*(%d+)%s"))
		if added then
			anchor = added
			add_change(added, "added")
		else
			local context = tonumber(line:match("^%s+(%d+)%s"))
			if context then
				anchor = context
			else
				local removed = tonumber(line:match("^%-%s*(%d+)%s"))
				if removed then
					add_change(anchor, "removed")
				end
			end
		end
	end

	if #changes == 0 then
		return { { line = start, kind = "added" } }
	end

	table.sort(changes, function(a, b)
		if a.line == b.line then
			return a.kind < b.kind
		end
		return a.line < b.line
	end)
	return changes
end

function M.diff_stats(diff)
	local added = 0
	local removed = 0
	for _, line in ipairs(vim.split(diff or "", "\n", { plain = true })) do
		if line:match("^%+") and not line:match("^%+%+%+") then
			added = added + 1
		elseif line:match("^%-") and not line:match("^%-%-%-") then
			removed = removed + 1
		end
	end
	return added, removed
end

return M
