local review = require("strider.review")
local search = require("strider.search")
local state = require("strider.state")
local ui = require("strider.ui")

local M = {}

local function text_content(message)
	if not message or message.role ~= "assistant" then
		return nil
	end

	local parts = {}
	for _, item in ipairs(message.content or {}) do
		if item.type == "text" and item.text ~= "" then
			table.insert(parts, item.text)
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

local function strip_strider_footer(text)
	if not text then
		return nil
	end
	local cleaned = text:gsub("\n?<STRIDER_STATUS>.-</STRIDER_STATUS>%s*$", "")
	cleaned = vim.trim(cleaned)
	return cleaned ~= "" and cleaned or text
end

-- Per-request response callbacks keyed by request id. When
-- send_command is given a callback, the id is stashed here;
-- handle_response fires and removes it before the default path.
local response_callbacks = {}

local function handle_response(event, lane)
	-- Fire per-request callback if one was registered.
	local cb = event.id and response_callbacks[event.id]
	if cb then
		response_callbacks[event.id] = nil
		cb(event, lane)
		return
	end

	if event.success then
		-- Raw RPC commands (new_session, compact, export_html, etc.) don't
		-- trigger LLM turns, so no message_end will follow. Consume the
		-- pending request now to clear the activity spinner and unblock the
		-- next send. Prompt-routed extension commands may also use operation
		-- "command"; they get the generic completion label.
		local pending = state.peek_pending_request(lane)
		if pending and pending.operation == "command" then
			state.consume_pending_request(lane)
			local metadata = pending.metadata or {}
			ui.finish_activity(metadata.activity_done or "Strider command complete", "ok", lane)
		end
		return
	end
	-- RPC transport-level error (pi rejected the request shape, backend
	-- isn't running, etc.). Less common than model-level errors — those
	-- arrive on message_end with stopReason="error" (see
	-- handle_message_end). Both paths log into the buffer so the user
	-- always has a record beyond the fleeting notify.
	local cmd = event.command or "unknown"
	local detail = event.errorMessage or event.error
	local reason
	if detail and detail ~= "" then
		reason = string.format("/%s failed: %s", cmd, detail)
	else
		reason = string.format("/%s failed (pi rejected the request)", cmd)
	end
	-- Consume the pending request so the activity spinner actually stops
	-- and the next send isn't blocked.
	local pending = state.peek_pending_request(lane)
	if pending then
		state.consume_pending_request(lane)
	end
	ui.append_block("error", reason, lane)
	state.set_error(reason, lane)
	ui.finish_activity(reason, "error", lane)
	ui.notify(reason, vim.log.levels.ERROR)
end

-- Runtime extension errors: pi emits these when sendUserMessage (or
-- another extension-side call) throws before a turn can start — e.g.
-- "No API key found for <provider>", or a provider returning 400
-- before the stream opens. The preceding `response` event reports
-- success:true because the RPC command itself dispatched cleanly; the
-- failure happens later in the extension's async promise chain.
-- Without a handler here, these silently evaporate and the log just
-- hangs on "Waiting for assistant response...".
local function handle_extension_error(event, lane)
	local reason = event.error or "Strider extension error"
	-- Collapse multi-line reasons to the first non-empty line for the
	-- notify + activity echo; put the full text in the [error] block so
	-- detail isn't lost.
	local first_line = reason
	for line in reason:gmatch("[^\r\n]+") do
		if vim.trim(line) ~= "" then
			first_line = line
			break
		end
	end
	ui.append_block("error", reason, lane)
	state.set_error(first_line, lane)
	ui.finish_activity(first_line, "error", lane)
	ui.notify(first_line, vim.log.levels.ERROR)
	-- Clear the pending request so the activity spinner actually stops
	-- and the next send doesn't think a turn is still in flight.
	state.consume_pending_request(lane)
end

local function ensure_stream_log(pending, lane)
	if lane ~= "main" then
		return
	end
	if not pending or pending.log_opened or pending.operation == "plan" or pending.operation == "q" then
		return
	end
	if ui.should_auto_open_stream_log and not ui.should_auto_open_stream_log(lane) then
		pending.log_opened = true
		return
	end
	pending.log_opened = true
	ui.open_log({ preserve_focus = true }, lane)
end

local function flush_thinking_index(session, pending, content_index, lane)
	if not session then
		return
	end
	session.assistant_thinking = session.assistant_thinking or {}
	local text = session.assistant_thinking[content_index]
	session.assistant_thinking[content_index] = nil
	if not text then
		return
	end
	text = vim.trim(text)
	if text == "" then
		return
	end
	ensure_stream_log(pending, lane)
	ui.finalize_live_block("thinking", text, lane)
end

local function flush_all_thinking(session, pending, lane)
	if not session then
		return
	end
	session.assistant_thinking = session.assistant_thinking or {}
	local indices = {}
	for index, text in pairs(session.assistant_thinking) do
		if text and vim.trim(text) ~= "" then
			table.insert(indices, index)
		end
	end
	table.sort(indices, function(a, b)
		return (tonumber(a) or 0) < (tonumber(b) or 0)
	end)
	for _, index in ipairs(indices) do
		flush_thinking_index(session, pending, index, lane)
	end
end

local function handle_message_update(event, lane)
	local delta = event.assistantMessageEvent
	if not delta then
		return
	end
	local pending = state.peek_pending_request(lane)
	if not pending then
		return
	end
	local session = state.get_session(lane)
	session.assistant_thinking = session.assistant_thinking or {}

	if delta.type == "thinking_start" then
		session.assistant_thinking[delta.contentIndex or 0] = ""
		ui.start_live_block(lane)
		return
	end
	if delta.type == "thinking_delta" then
		local index = delta.contentIndex or 0
		session.assistant_thinking[index] = (session.assistant_thinking[index] or "") .. (delta.delta or "")
		ensure_stream_log(pending, lane)
		ui.update_live_block(session.assistant_thinking[index], lane)
		return
	end
	if delta.type == "thinking_end" then
		local index = delta.contentIndex or 0
		if (not session.assistant_thinking[index] or session.assistant_thinking[index] == "") and delta.content then
			session.assistant_thinking[index] = delta.content
		end
		flush_thinking_index(session, pending, index, lane)
		return
	end
	if delta.type == "done" or delta.type == "error" then
		flush_all_thinking(session, pending, lane)
		return
	end
	if delta.type ~= "text_delta" then
		return
	end
	session.assistant_text = (session.assistant_text or "") .. (delta.delta or "")
	session.message_text = (session.message_text or "") .. (delta.delta or "")

	-- Auto-open the log on the first streamed delta of any answer-producing
	-- operation, without stealing focus. Idempotent: open_log is a no-op
	-- when the log is already visible. One-per-pending guard avoids
	-- reopening a manually-closed log mid-stream.
	ensure_stream_log(pending, lane)
	ui.ensure_live_block(lane)
	ui.update_live_block(session.message_text, lane)

	if pending.operation == "q" then
		local meta = pending.metadata or {}
		ui.update_q_answer(session.message_text, meta.card_lane or lane, meta.card_id)
	end

	if pending.operation == "review" then
		review.capture_assistant_text(session.assistant_text, { partial = true })
	end
end

local function has_tool_use(message)
	if not message or message.role ~= "assistant" then
		return false
	end
	for _, item in ipairs(message.content or {}) do
		if item.type == "tool_use" or item.type == "toolCall" then
			return true
		end
	end
	return false
end

local function notify_turn_done(pending, lane)
	if not pending then
		return
	end
	local op = pending.operation
	-- Flow-lane operations: always leave a bottom-left completion cue.
	-- The popup-style notify is still skipped when StriderLogFlow is visible,
	-- but the command-line green dot remains so completion is not silent.
	if state.is_flow_operation(op) then
		local messages = {
			q = "StriderQ answer is ready",
			search = "StriderSearch complete",
			patch = "StriderPatch complete",
		}
		local message = messages[op] or "Strider flow complete"
		if op == "q" then
			local model = pending.metadata and pending.metadata.model_label
			message = message .. (model and (" · " .. model) or "") .. " · :StriderQs"
		elseif op == "patch" then
			message = message .. " · :StriderPatches"
		end
		ui.notify_flow_done(message, {
			notify = not ui.log_is_visible(lane),
		})
		return
	end
	-- Chat (main lane): notify when StriderLog isn't visible.
	if lane == "main" then
		if ui.log_is_visible("main") then
			return
		end
		ui.notify("Strider chat complete", vim.log.levels.INFO)
	end
	-- Review pops up on its own, no notify needed.
end

local function handle_message_end(event, lane)
	local message = event.message
	local text = strip_strider_footer(text_content(message))
	local pending = state.peek_pending_request(lane)
	local session = state.get_session(lane)

	flush_all_thinking(session, pending, lane)
	ui.finalize_live_block(nil, nil, lane)
	session.message_text = nil

	-- Do not consume pending on tool-call turns or user messages.
	-- Only the final text-bearing assistant message should consume it.
	if has_tool_use(message) then
		return
	end
	if not message or message.role ~= "assistant" then
		return
	end

	pending = state.consume_pending_request(lane)
	session.assistant_text = nil
	session.assistant_thinking = {}

	-- Model/provider errors land here: pi emits a final message_end whose
	-- message.stopReason is "error" (or "aborted" for user-canceled
	-- turns), with the human-readable reason in message.errorMessage.
	-- Surface it into the log so the user sees why the turn failed
	-- instead of wondering why nothing streamed back. Short-circuit the
	-- normal plan/search/assistant branches — there's no usable text.
	local stop_reason = message.stopReason
	if stop_reason == "error" or stop_reason == "aborted" then
		local reason = message.errorMessage or (stop_reason == "aborted" and "Turn aborted" or "Model request failed")
		ui.append_block("error", reason, lane)
		state.set_error(reason, lane)
		local level = stop_reason == "aborted" and "cancel" or "error"
		ui.finish_activity(reason, level, lane)
		if pending and pending.operation == "q" then
			local meta = pending.metadata or {}
			ui.finish_q_answer(reason, "error", meta.card_lane or lane, meta.card_id)
		elseif pending and pending.operation == "patch" then
			local status = stop_reason == "aborted" and "cancelled" or "error"
			ui.finish_patch_summary(pending.metadata and pending.metadata.summary_id, status, {
				assistant_summary = reason,
			}, lane)
		end
		if stop_reason == "error" then
			ui.notify(reason, vim.log.levels.ERROR)
		end
		return
	end

	-- Plan turns: success depends on whether the plan tool landed a plan,
	-- not on whether the model produced trailing prose. Handle before the
	-- "no text" early return so empty plan-turn replies still dispatch the
	-- first /review.
	if pending and pending.operation == "plan" then
		if text and text ~= "" then
			review.capture_plan_message(text)
			ui.append_block("assistant", text, lane)
		end
		if review.has_active_review() and review.is_planning() then
			ui.notify("Strider could not produce a plan — try rephrasing.", vim.log.levels.ERROR)
			ui.finish_activity("Strider plan failed", "error", lane)
			return
		end
		ui.finish_activity("Strider plan complete", "success", lane)
		vim.schedule(function()
			local ok, mod = pcall(require, "strider")
			if ok and mod and mod.dispatch_first_review then
				mod.dispatch_first_review()
			end
		end)
		return
	end

	if not text then
		ui.finish_activity("Strider request complete (no text)", "success", lane)
		if pending and pending.operation == "q" then
			local meta = pending.metadata or {}
			ui.finish_q_answer(nil, "success", meta.card_lane or lane, meta.card_id)
		elseif pending and pending.operation == "patch" then
			ui.finish_patch_summary(pending.metadata and pending.metadata.summary_id, "success", {
				assistant_summary = "Patch completed with no final summary.",
			}, lane)
		end
		notify_turn_done(pending, lane)
		return
	end

	if pending and pending.operation == "search" then
		local result_set = search.handle_response(text, pending.metadata, lane)
		local summary = search.summary_text(result_set)
		state.set_summary(summary, lane)
		ui.append_block("assistant", summary, lane)
		ui.finish_activity(summary, "success", lane)
		notify_turn_done(pending, lane)
		return
	end

	state.set_summary(text:gsub("\n", " "), lane)
	ui.append_block("assistant", text, lane)
	local completing_review_summary = lane == "review"
		and pending
		and pending.operation == "review"
		and review.is_awaiting_summary()
	if pending and pending.operation == "review" then
		review.capture_assistant_text(text)
	end

	ui.finish_activity("Strider request complete", "success", lane)
	if pending and pending.operation == "q" then
		local meta = pending.metadata or {}
		ui.finish_q_answer(text, "success", meta.card_lane or lane, meta.card_id)
	elseif pending and pending.operation == "patch" then
		ui.finish_patch_summary(pending.metadata and pending.metadata.summary_id, "success", {
			assistant_summary = text,
		}, lane)
	end
	notify_turn_done(pending, lane)
	if completing_review_summary then
		vim.schedule(function()
			local ok, mod = pcall(require, "strider")
			if ok and mod and mod.complete_review_summary then
				mod.complete_review_summary(text)
			end
		end)
	end
end

M.strip_strider_footer = strip_strider_footer
M.handle_response = handle_response
M.handle_extension_error = handle_extension_error
M.handle_message_update = handle_message_update
M.handle_message_end = handle_message_end

function M.register_callback(id, callback)
	response_callbacks[id] = callback
end

return M
