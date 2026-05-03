local extension_ui = require("strider.rpc.extension_ui")
local messages = require("strider.rpc.messages")
local tool_events = require("strider.rpc.tool_events")
local state = require("strider.state")
local ui = require("strider.ui")

local M = {}

local function normalize_lane(lane)
	return state.normalize_lane(lane)
end

local function resolve_lane_and_cwd(arg1, arg2)
	if state.is_lane(arg1) then
		return normalize_lane(arg1), arg2
	end
	return normalize_lane(arg2), arg1
end

local function resolve_lane_and_payload(arg1, arg2)
	if arg2 == nil then
		return "main", arg1
	end
	if state.is_lane(arg1) then
		return normalize_lane(arg1), arg2
	end
	return normalize_lane(arg2), arg1
end

local function append_cli_arg(cmd, flag, value)
	if value == nil then
		return
	end
	value = tostring(value)
	if vim.trim(value) == "" then
		return
	end
	vim.list_extend(cmd, { flag, value })
end

local function append_lane_model_args(cmd, lane)
	local profile = state.resolve_lane_model(lane)
	if not profile then
		return
	end
	append_cli_arg(cmd, "--provider", profile.provider)
	append_cli_arg(cmd, "--model", profile.model)
	append_cli_arg(cmd, "--thinking", profile.thinking or profile.reasoning)
end

function M.command_list(lane)
	local config = state.get_config()
	local cmd = vim.deepcopy(config.pi_cmd)
	local extension = config.extension_path or (config.plugin_root .. "/pi/strider-stepper.ts")
	append_lane_model_args(cmd, lane)
	vim.list_extend(cmd, { "--mode", "rpc", "--extension", extension })
	return cmd
end

local function decode(line)
	local ok, value = pcall(vim.json.decode, line)
	if ok then
		return value
	end
end

-- Send an extension_ui_response back to pi. Payload merges an id + any
-- response-specific fields (value / cancelled / confirmed).
local function send_ui_response(id, payload, lane)
	local session = state.get_session(lane)
	if not session or not session.job_id then
		return false
	end
	-- pi-coding-agent uses crypto.randomUUID() (strings) as ids. Echo the
	-- id back as-is — do not coerce to/from number.
	local body = vim.tbl_extend("force", { type = "extension_ui_response", id = id }, payload or {})
	local ok, encoded = pcall(vim.json.encode, body)
	if not ok then
		return false
	end
	vim.fn.chansend(session.job_id, encoded .. "\n")
	return true
end

local function dispatch(event, lane)
	if event.type == "response" then
		messages.handle_response(event, lane)
		return
	end
	if event.type == "extension_error" then
		messages.handle_extension_error(event, lane)
		return
	end
	if event.type == "message_update" then
		messages.handle_message_update(event, lane)
		return
	end
	if event.type == "message_end" then
		messages.handle_message_end(event, lane)
		return
	end
	if event.type == "tool_execution_start" then
		tool_events.handle_tool_start(event, lane)
		return
	end
	if event.type == "tool_execution_end" then
		tool_events.handle_tool_end(event, lane)
		return
	end
	if event.type == "extension_ui_request" then
		extension_ui.handle(event, lane, send_ui_response)
	end
end

-- Reusable per-call buffers to reduce GC pressure during rapid streaming.
-- split_lines populates `reuse_lines`; consume_json decodes into
-- `reuse_events`. Both are cleared at the start of each call.
local reuse_lines = {}
local reuse_events = {}

local function split_lines(data, tail)
	if #data == 0 then
		return reuse_lines, tail, 0
	end

	local count = 0
	local current = tail .. (data[1] or "")
	for index = 2, #data do
		count = count + 1
		reuse_lines[count] = current
		current = data[index] or ""
	end
	if data[#data] == "" then
		if current ~= "" then
			count = count + 1
			reuse_lines[count] = current
		end
		return reuse_lines, "", count
	end
	return reuse_lines, current, count
end

local function consume_json(session, data, tail_key, lane)
	local lines, new_tail, line_count = split_lines(data, session[tail_key])
	session[tail_key] = new_tail
	local event_count = 0
	for i = 1, line_count do
		local event = decode(lines[i])
		if event then
			event_count = event_count + 1
			reuse_events[event_count] = event
		end
	end
	if event_count > 0 then
		-- Snapshot the events for the scheduled callback; clear reuse buffers.
		local snapshot = {}
		for i = 1, event_count do
			snapshot[i] = reuse_events[i]
			reuse_events[i] = nil
		end
		for i = 1, line_count do
			reuse_lines[i] = nil
		end
		vim.schedule(function()
			for i = 1, #snapshot do
				dispatch(snapshot[i], lane)
			end
		end)
	else
		for i = 1, line_count do
			reuse_lines[i] = nil
		end
	end
end

local function consume_text(session, data, tail_key, lane)
	local lines, new_tail, line_count = split_lines(data, session[tail_key])
	session[tail_key] = new_tail
	if line_count == 0 then
		return
	end
	local snapshot = {}
	for i = 1, line_count do
		snapshot[i] = lines[i]
		lines[i] = nil
	end
	vim.schedule(function()
		for i = 1, #snapshot do
			ui.append({ "[stderr] " .. snapshot[i] }, lane)
		end
	end)
end

function M.start(arg1, arg2)
	local lane, cwd = resolve_lane_and_cwd(arg1, arg2)
	local session = state.ensure_session(lane, cwd)
	if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
		return true
	end

	local job_id = vim.fn.jobstart(M.command_list(lane), {
		cwd = cwd,
		on_exit = function()
			session.job_id = nil
			vim.schedule(function()
				ui.notify("Strider backend exited", vim.log.levels.WARN)
			end)
		end,
		on_stderr = function(_, data)
			consume_text(session, data, "stderr_tail", lane)
		end,
		on_stdout = function(_, data)
			consume_json(session, data, "stdout_tail", lane)
		end,
	})

	if job_id <= 0 then
		ui.notify("Failed to start pi in RPC mode", vim.log.levels.ERROR)
		return false
	end

	session.job_id = job_id
	if lane == "main" and state.get_config().open_log_on_start then
		ui.open_log({ preserve_focus = true }, lane)
	end
	ui.append({ "[strider] backend started", "" }, lane)
	return true
end

function M.stop(lane)
	local session = state.get_session(lane)
	if not session or not session.job_id then
		return
	end
	vim.fn.jobstop(session.job_id)
	session.job_id = nil
end

-- Abort the current in-flight turn. Pi's RPC layer handles the rest:
-- it cancels the provider stream and emits a final `message_end` with
-- `stopReason = "aborted"`, which `handle_message_end` already renders
-- as a cancel-flavored `[error]` block and clears pending state.
-- No-op when no turn is in flight (still sends the RPC; pi answers
-- with success=true either way, costs nothing).
function M.abort(lane)
	local session = state.get_session(lane)
	if not session or not session.job_id then
		ui.notify("Strider backend is not running", vim.log.levels.WARN)
		return false
	end
	vim.fn.chansend(session.job_id, vim.json.encode({ type = "abort" }) .. "\n")
	return true
end

function M.send_prompt(arg1, arg2)
	local lane, message = resolve_lane_and_payload(arg1, arg2)
	local session = state.get_session(lane)
	if not session or not session.job_id then
		ui.notify("Strider backend is not running", vim.log.levels.WARN)
		return false
	end

	local payload = {
		id = state.next_request_id(lane),
		message = message,
		type = "prompt",
	}
	vim.fn.chansend(session.job_id, vim.json.encode(payload) .. "\n")
	return true
end

-- Steer an already-running turn with additional user input. Pi inserts
-- the steer message mid-stream; the model sees it and adjusts without
-- a new turn being started. No new pending_request is created — the
-- existing one continues to resolve on the next message_end.
function M.send_steer(arg1, arg2)
	local lane, message = resolve_lane_and_payload(arg1, arg2)
	local session = state.get_session(lane)
	if not session or not session.job_id then
		ui.notify("Strider backend is not running", vim.log.levels.WARN)
		return false
	end

	local payload = {
		id = state.next_request_id(lane),
		message = message,
		type = "steer",
	}
	vim.fn.chansend(session.job_id, vim.json.encode(payload) .. "\n")
	return true
end

-- Send a raw RPC command (not a prompt). Used for session-management
-- commands like new_session, fork, compact that are dedicated RPC
-- message types rather than slash-commands routed through prompt.
function M.send_command(cmd_type, extra, lane, callback)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session or not session.job_id then
		ui.notify("Strider backend is not running", vim.log.levels.WARN)
		return false
	end
	local req_id = state.next_request_id(lane)
	local payload = vim.tbl_extend("force", extra or {}, {
		id = req_id,
		type = cmd_type,
	})
	if callback then
		messages.register_callback(req_id, callback)
	end
	vim.fn.chansend(session.job_id, vim.json.encode(payload) .. "\n")
	return true
end

return M
