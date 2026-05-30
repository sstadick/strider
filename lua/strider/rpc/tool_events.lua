local messages = require("strider.rpc.messages")
local review = require("strider.review")
local state = require("strider.state")
local tools = require("strider.rpc.tools")
local ui = require("strider.ui")

local M = {}

local function track_tool_path(session, event)
	local path = tools.absolute_path(session, event.args and event.args.path)
	if path and event.toolCallId then
		session.tool_paths[event.toolCallId] = path
	end
	return path
end

local function finish_tool_path(session, event)
	if not event.toolCallId then
		return nil
	end
	local path = session.tool_paths[event.toolCallId]
	session.tool_paths[event.toolCallId] = nil
	return path
end

local function patch_summary_id(lane)
	local pending = state.peek_pending_request(lane)
	if not pending or pending.operation ~= "patch" then
		return nil
	end
	return pending.metadata and pending.metadata.summary_id
end

local function record_patch_tool(lane, tool)
	local id = patch_summary_id(lane)
	if id then
		ui.record_patch_summary_tool(id, tool, lane)
	end
end

local function handle_tool_start(event, lane)
	local session = state.get_session(lane)
	tools.append_tool(event.toolName, event.args, lane)

	-- Mark the header row so handle_tool_end can insert the result right
	-- after it (instead of appending at the end of the log, which
	-- disconnects headers from results when tools run in parallel).
	ui.mark_tool_header(event.toolCallId, lane)

	-- Cache args for Strider planning tools — tool_execution_end events do not
	-- carry args, so we have to capture them here while they're available.
	if (event.toolName == "strider_plan" or event.toolName == "strider_append_stops") and event.toolCallId then
		session.tool_args[event.toolCallId] = event.args
	end

	local path = track_tool_path(session, event)
	if not path then
		return
	end
	state.record_file(path, lane)
	-- Do not auto-jump for model tool reads. Strider review navigation is the
	-- only flow that should move the user's code window mechanically; prompt /
	-- chat tool use should leave the coding pane where it is.
end

local function consume_tool_args(session, event)
	if not event.toolCallId then
		return nil
	end
	local cached = session.tool_args[event.toolCallId]
	session.tool_args[event.toolCallId] = nil
	return cached
end

local function handle_tool_end(event, lane)
	local session = state.get_session(lane)

	-- Resolve where to place output: right after this tool's header when
	-- the extmark is still valid, otherwise fall back to normal append.
	local insert_row = ui.pop_tool_insert_row(event.toolCallId, lane)
	local insert_opts = insert_row and { insert_at = insert_row } or {}

	-- Render textual output for tools where seeing the content helps the
	-- user follow along (everything except edit, which renders inline diff
	-- rows below, and Strider's internal planning tools which carry structured
	-- payloads rather than user-facing text). For read/write we pass a
	-- language tag so the content is fenced and treesitter +
	-- render-markdown can syntax-highlight it; bash/grep/find/ls render
	-- as compact transcript rows so markdown-looking output stays inert.
	local compact_output = tools.compact_output_opts(event.toolName)
	if tools.fenced_output(event.toolName) or compact_output then
		local text = tools.tool_result_text(event)
		if text then
			if tools.fenced_output(event.toolName) then
				-- Peek the stashed path without consuming — finish_tool_path
				-- below does the actual consume for the edit/highlight flow.
				local stashed = event.toolCallId and session.tool_paths[event.toolCallId] or nil
				ui.append_tool_output(text, tools.language_for_path(stashed), lane, insert_opts)
			else
				ui.append_compact_tool_output(text, compact_output, lane, insert_opts)
			end
		end
	end

	-- Strider planning tools carry their payload in args captured at start time.
	if event.toolName == "strider_plan" then
		local args = consume_tool_args(session, event) or {}
		-- Capture any streamed prose as the plan message BEFORE ingest_plan so
		-- ingest_plan can route to message 0.  handle_message_end skips the
		-- capture when the message contains tool_use (which it always does here),
		-- so this is the only place the plan message is reliably captured.
		local raw_text = session.assistant_text
		if raw_text and raw_text ~= "" then
			local text = messages.strip_strider_footer(vim.trim(raw_text))
			if text ~= "" then
				review.capture_plan_message(text)
			end
		end
		local item = review.ingest_plan(args)
		if item then
			ui.append(
				{ string.format("• Planned %d stop(s), scope=%s", #(args.stops or {}), args.scope or "?") },
				lane
			)
		else
			ui.notify("Strider plan was empty or invalid; review cannot start", vim.log.levels.ERROR)
		end
		return
	end
	if event.toolName == "strider_append_stops" then
		local args = consume_tool_args(session, event) or {}
		local added = review.ingest_append_stops(args)
		if added > 0 then
			ui.append({ string.format("• Appended %d stop(s)", added) }, lane)
		end
		return
	end

	local path = finish_tool_path(session, event)
	if not path then
		return
	end
	if event.toolName == "read" then
		state.record_file(path, lane)
		record_patch_tool(lane, { kind = "read", path = path })
		return
	end
	if event.toolName == "edit" then
		state.record_file(path, lane)
		-- Keep local highlights if the edited buffer is already around, but do
		-- not move the user's window to follow model tool use.
		local lines = tools.changed_lines(event)
		ui.highlight_lines(path, lines, lane)
		local added, removed = 0, 0
		local diff_text = event.result and event.result.details and event.result.details.diff
		if diff_text and diff_text ~= "" then
			added, removed = tools.diff_stats(diff_text)
			local suffix = string.format(" (+%d -%d)", added, removed)
			ui.update_tool_line(insert_row and (insert_row - 1) or nil, "edit", path, suffix, lane)
			local diff_opts = vim.tbl_extend("force", insert_opts, {
				lang = tools.language_for_path(path),
				path = path,
			})
			ui.append_diff(diff_text, lane, diff_opts)
		end
		record_patch_tool(lane, { kind = "edit", path = path, diff = diff_text, added = added, removed = removed })
		return
	end
	if event.toolName == "write" then
		state.record_file(path, lane)
		record_patch_tool(lane, { kind = "write", path = path })
		-- Same rule as edits: annotate opportunistically, never steal focus.
		ui.highlight_range(path, 1, nil, lane)
	end
end

M.handle_tool_start = handle_tool_start
M.handle_tool_end = handle_tool_end

return M
