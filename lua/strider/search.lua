local picker = require("strider.picker")
local state = require("strider.state")
local ui = require("strider.ui")

local M = {}

local function normalize_lane(lane)
	return state.normalize_lane(lane or "flow")
end

local function is_absolute(path)
	return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
end

local function absolute_path(path, lane)
	if path == nil or path == "" then
		return nil
	end
	if is_absolute(path) then
		return path
	end
	local session = state.get_session(normalize_lane(lane))
	if not session then
		return nil
	end
	return vim.fs.joinpath(session.cwd, path)
end

local function truncate(text, width)
	width = width or 80
	if #text <= width then
		return text
	end
	return text:sub(1, width - 1) .. "…"
end

local function parse_line(line, lane)
	line = line:gsub("^[-*]%s+", "")
	line = line:gsub("^`+", ""):gsub("`+$", "")
	local path, lnum_raw, rest = line:match("^(.-):([^:]+):(.+)$")
	if not path or not lnum_raw or not rest then
		return nil
	end

	local col_raw, count_raw, notes = rest:match("^([^,]+),([^,]+),?(.*)$")
	if not col_raw or not count_raw then
		return nil
	end

	local lnum = tonumber(lnum_raw) or 1
	local col = tonumber(col_raw) or 1
	local count = math.max(tonumber(count_raw) or 1, 1)
	local filename = absolute_path(path, lane)
	if not filename then
		return nil
	end

	return {
		filename = filename,
		lnum = lnum,
		end_lnum = lnum + count - 1,
		col = col,
		count = count,
		text = notes or "",
	}
end

local function summary_label(prompt, count)
	return string.format("%s (%d result%s)", truncate(prompt, 70), count, count == 1 and "" or "s")
end

local function quickfix_items(results)
	local items = {}
	for _, result in ipairs(results or {}) do
		table.insert(items, {
			filename = result.filename,
			lnum = result.lnum,
			end_lnum = result.end_lnum,
			col = result.col,
			text = result.text,
		})
	end
	return items
end

local function location_label(result)
	return string.format("%s:%d-%d", vim.fn.fnamemodify(result.filename, ":."), result.lnum, result.end_lnum)
end

local function result_label(result, location_width)
	local notes = result.text ~= "" and result.text or "Search result"
	local location = location_label(result)
	local padding = math.max((location_width or 0) - vim.fn.strdisplaywidth(location), 0) + 4
	return location .. string.rep(" ", padding) .. truncate(notes, 90)
end

function M.picker_items(results)
	local location_width = 0
	for _, result in ipairs(results or {}) do
		location_width = math.max(location_width, vim.fn.strdisplaywidth(location_label(result)))
	end

	local items = {}
	for _, result in ipairs(results or {}) do
		table.insert(items, {
			label = result_label(result, location_width),
			value = result,
		})
	end
	return items
end

function M.open_result(result, lane)
	if not result then
		return false
	end
	lane = normalize_lane(lane)
	ui.jump_to_file(result.filename, result.lnum)
	ui.highlight_range(result.filename, result.lnum, result.end_lnum, lane)
	return true
end

local function store_quickfix(result_set, open)
	ui.set_quickfix(
		"Strider Search: " .. truncate(result_set.prompt or "results", 50),
		quickfix_items(result_set.results),
		open
	)
end

local function present_result_set(result_set)
	local count = #result_set.results

	if picker.available() then
		local items = M.picker_items(result_set.results)
		store_quickfix(result_set, false)
		return picker.select("Strider Search Results", items, function(item)
			M.open_result(item.value, result_set.lane)
		end)
	end

	store_quickfix(result_set, true)
	if count == 1 then
		M.open_result(result_set.results[1], result_set.lane)
	end
	return true
end

function M.open_result_set(result_set, lane)
	local session = state.get_session(normalize_lane(lane))
	if not result_set or not result_set.results or #result_set.results == 0 then
		ui.notify("No search results available", vim.log.levels.WARN)
		return false
	end

	if session and session.search_history then
		local reordered = { result_set }
		for _, item in ipairs(session.search_history) do
			if item ~= result_set then
				table.insert(reordered, item)
			end
		end
		session.search_history = reordered
	end

	return present_result_set(result_set)
end

function M.handle_response(text, metadata, lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return nil
	end
	local prompt = metadata and metadata.prompt or "Strider search"
	local results = {}

	for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
		local result = parse_line(vim.trim(line), lane)
		if result then
			table.insert(results, result)
		end
	end

	local result_set = {
		id = string.format("search-%d", session.request_seq),
		lane = lane,
		prompt = prompt,
		raw = text,
		created_at = os.time(),
		results = results,
		label = summary_label(prompt, #results),
	}

	table.insert(session.search_history, 1, result_set)
	if #session.search_history > 20 then
		table.remove(session.search_history)
	end

	if #results == 0 then
		ui.notify("Strider search returned no structured results", vim.log.levels.INFO)
		return result_set
	end

	M.open_result_set(result_set, lane)
	return result_set
end

function M.summary_text(result_set)
	if not result_set then
		return "Strider search finished."
	end
	local count = #(result_set.results or {})
	if count == 0 then
		return string.format("Strider search: no matches for '%s'", result_set.prompt or "search")
	end
	if count == 1 then
		return string.format("Strider search: 1 match for '%s'", result_set.prompt or "search")
	end
	return string.format("Strider search: %d matches for '%s'", count, result_set.prompt or "search")
end

function M.last_result_set(lane)
	local session = state.get_session(normalize_lane(lane))
	return session and session.search_history[1] or nil
end

function M.history_picker(lane)
	local session = state.get_session(normalize_lane(lane))
	if not session then
		ui.notify("No Strider searches recorded yet", vim.log.levels.WARN)
		return false
	end
	local items = {}
	for _, result_set in ipairs(session.search_history or {}) do
		table.insert(items, {
			label = result_set.label,
			value = result_set,
		})
	end

	if #items == 0 then
		ui.notify("No Strider searches recorded yet", vim.log.levels.WARN)
		return false
	end

	return picker.select("Strider Searches", items, function(item)
		M.open_result_set(item.value, lane)
	end)
end

return M
