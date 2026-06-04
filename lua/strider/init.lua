local card_picker = require("strider.ui.card_picker")
local context = require("strider.context")
local picker = require("strider.picker")
local review = require("strider.review")
local rpc = require("strider.rpc")
local search = require("strider.search")
local state = require("strider.state")
local status = require("strider.status")
local ui = require("strider.ui")

local M = {}

local MAIN_LANE = "main"
local FLOW_LANE = "flow"
local Q_LANE = "q"
local PATCH_LANE = "patch"
local REVIEW_LANE = "review"
local FLOW_LANES = { FLOW_LANE, PATCH_LANE }
local REVIEW_CONTEXT_FRESH = "fresh"
local REVIEW_CONTEXT_MAIN = "main"
local REVIEW_MAIN_CONTEXT_LIMIT = 20000

local build_review_start_prompt
local main_chat_review_context

-- Cached CWD + hrtime to short-circuit ensure_backend's per-lane cwd check.
-- CWD changes are user-initiated and rare; avoid calling getcwd() + comparing
-- every lane's session on every send().
local cached_cwd = nil
local cached_cwd_ns = 0
local CWD_CACHE_NS = 500e6 -- 500ms in nanoseconds
local trimmed = context.trimmed
local range_from_opts = context.range_from_opts
local read_excerpt = context.read_excerpt

local function current_cwd()
	local now = vim.uv.hrtime()
	if cached_cwd and (now - cached_cwd_ns) < CWD_CACHE_NS then
		return cached_cwd
	end
	cached_cwd = vim.fn.getcwd()
	cached_cwd_ns = now
	return cached_cwd
end

local function ensure_backend(lane)
	lane = state.normalize_lane(lane)
	local cwd = current_cwd()
	for _, session_lane in ipairs(state.lanes()) do
		local session = state.get_session(session_lane)
		if session and session.cwd ~= cwd then
			rpc.stop(session_lane)
			state.clear_session(session_lane)
		end
	end
	return rpc.start(cwd, lane)
end

local function ensure_session(lane)
	return state.ensure_session(lane, current_cwd())
end

local function activity_title(operation)
	local titles = {
		patch = "Strider patch running...",
		plan = "Strider planning review...",
		q = "StriderQ running...",
		review = "Strider review running...",
		search = "Strider search running...",
		prompt = "Strider prompt running...",
		command = "Strider command running...",
	}
	return titles[operation] or "Strider running..."
end

local function activity_target(operation, lane)
	if operation == "q" and state.normalize_lane(lane) == Q_LANE then
		return "q"
	end
	if
		lane == REVIEW_LANE
		and (operation == "review" or operation == "plan")
		and (review.has_active_review() or review.is_awaiting_summary())
	then
		return "review"
	end
	return "log"
end

local function lane_title(lane)
	if state.is_q_lane(lane) then
		return "StriderQ"
	end
	if lane == PATCH_LANE then
		return "Strider patch"
	end
	if lane == FLOW_LANE then
		return "Strider flow"
	end
	if lane == REVIEW_LANE then
		return "Strider review"
	end
	return "Strider chat"
end

local CHAT_READ_ONLY_INSTRUCTIONS = table.concat({
	"Read-only chat mode is enabled.",
	"Do not create, edit, delete, rename, move, format, or otherwise modify files or project state.",
	"Do not run commands that mutate the working tree or project state.",
	"You may inspect files, run read-only commands, explain findings, and propose changes, but do not apply them.",
	"If changes are required, describe them and ask the user to disable Strider chat read-only mode.",
}, "\n")

local function chat_read_only_enabled()
	local session = state.get_session(MAIN_LANE)
	return session and session.chat_read_only == true
end

local function read_only_chat_prompt(text)
	return string.format("/prompt %s\n\nUser request:\n%s", CHAT_READ_ONLY_INSTRUCTIONS, text)
end

local function sync_chat_read_only_to_pi()
	return rpc.set_chat_read_only(chat_read_only_enabled(), MAIN_LANE)
end

local function warn_if_lane_busy(lane)
	lane = state.normalize_lane(lane)
	local pending = state.peek_pending_request(lane)
	if not pending then
		return false
	end
	local suffix = pending.operation and string.format(" (%s)", pending.operation) or ""
	ui.notify(
		string.format("%s is already running%s; wait for it to finish.", lane_title(lane), suffix),
		vim.log.levels.WARN
	)
	return true
end

local function send(command, user_text, opts)
	opts = opts or {}
	local lane = state.normalize_lane(opts.lane)
	if warn_if_lane_busy(lane) then
		return false
	end
	if not ensure_backend(lane) then
		return false
	end
	if lane == MAIN_LANE and opts.operation == "prompt" then
		sync_chat_read_only_to_pi()
	end
	if opts.open_log then
		-- Don't steal focus from whatever the user is currently doing (e.g.
		-- composing in strider://compose). If the log isn't visible yet,
		-- opening it should be silent.
		ui.open_log({ preserve_focus = true }, lane)
	end
	local operation = opts.operation or nil
	local metadata = opts.metadata or {}
	state.clear_error(lane)
	if operation == "patch" then
		metadata.summary_id = ui.create_patch_summary(user_text, { target = metadata.target }, lane)
	elseif operation == "q" then
		metadata.card_lane = metadata.card_lane or Q_LANE
		ensure_session(metadata.card_lane)
		metadata.worker_lane = lane
		metadata.card_id = ui.create_q_answer(user_text, metadata.card_lane, {
			card_id = metadata.card_id,
			model_label = metadata.model_label,
			new = metadata.card_id == nil,
			preserve_name = metadata.card_id ~= nil,
			seq = metadata.q_seq,
			worker_lane = lane,
		})
	end
	state.set_pending_request(operation, metadata, lane)
	if operation then
		ui.start_activity(activity_title(operation), activity_target(operation, lane), operation, lane)
	end
	ui.refresh_compose_winbar(lane)
	ui.refresh_compose_hint()
	local ok = rpc.send_prompt(command, lane)
	if not ok then
		state.set_pending_request(nil, nil, lane)
		ui.finish_activity("Strider request failed to start", "error", lane)
		if operation == "q" then
			ui.finish_q_answer("Strider request failed to start", "error", metadata.card_lane or lane, metadata.card_id)
		elseif operation == "patch" then
			ui.finish_patch_summary(metadata.summary_id, "error", {
				assistant_summary = "Strider request failed to start",
			}, lane)
		end
		ui.refresh_compose_hint()
		return false
	end
	if user_text and user_text ~= "" then
		ui.append_block(opts.user_label or "user", user_text, lane)
	end
	if opts.debug_prompt and opts.debug_prompt ~= "" then
		ui.append_block("review-prompt", opts.debug_prompt, lane)
	end
	return true
end

local function range_pointer(range)
	return context.range_pointer(range, current_cwd())
end

local function chat_prefill(prompt, range)
	return context.chat_prefill(prompt, range, current_cwd())
end

local function send_review_prompt(prompt, label, opts)
	opts = opts or {}
	local open_log = opts.open_log
	if open_log == nil then
		open_log = true
	end
	return send("/review " .. prompt, label, {
		lane = REVIEW_LANE,
		operation = "review",
		debug_prompt = prompt,
		open_log = open_log,
	})
end

local function append_review_summary_to_main(summary)
	if not summary or summary == "" then
		return false
	end
	ensure_session(MAIN_LANE)
	local lines = {
		"Review summary",
		"",
		summary,
	}
	local comment_lines = review.pending_comment_lines()
	if comment_lines and #comment_lines > 0 then
		table.insert(lines, "")
		table.insert(lines, "Review comments")
		table.insert(lines, "")
		vim.list_extend(lines, comment_lines)
	end
	ui.append_block("assistant", table.concat(lines, "\n"), MAIN_LANE)
	return true
end

function M.forward_review_summary(summary)
	summary = trimmed(summary)
	if summary == "" then
		ui.notify("Review summary cannot be empty", vim.log.levels.WARN)
		return false
	end
	local forwarded = append_review_summary_to_main(summary)
	if forwarded then
		review.mark_summary_forwarded(summary)
		ui.notify("Review summary forwarded to main chat", vim.log.levels.INFO)
	end
	return forwarded
end

local summary_editor_name = "strider://review-summary"
local summary_editor_open = false

local function open_review_summary_editor(summary)
	summary = trimmed(summary)
	if summary == "" then
		return false
	end
	if summary_editor_open and vim.fn.bufexists(summary_editor_name) == 1 then
		ui.notify("Review summary editor is already open", vim.log.levels.WARN)
		return false
	end
	summary_editor_open = false
	if not review.begin_summary_confirmation(summary) then
		return false
	end
	summary_editor_open = true
	rpc.stop(REVIEW_LANE)
	ui.open_prompt_editor("Strider review summary", function(text)
		local forwarded = M.forward_review_summary(text)
		if forwarded then
			summary_editor_open = false
		end
		return forwarded
	end, {
		allow_empty = true,
		hint_lines = {
			"Edit the final review text, then forward it to the main chat transcript.",
			"Cancel keeps the summary in the review pane; :StriderReviewSummary reopens it.",
		},
		name = summary_editor_name,
		on_cancel = function()
			summary_editor_open = false
			review.end_summary_confirmation()
			ui.notify("Review summary kept in the review pane", vim.log.levels.INFO)
		end,
		prefill = summary,
		submit_hint = "<C-s> to forward · <Esc><Esc> to keep in review pane",
	})
	return true
end

function M.complete_review_summary(summary)
	return open_review_summary_editor(summary)
end

function M.review_summary()
	if review.summary_forwarded() then
		ui.notify("Review summary is already forwarded to main chat", vim.log.levels.INFO)
		return false
	end
	local summary = trimmed(review.summary_text() or "")
	if summary == "" then
		ui.notify("No completed review summary to forward", vim.log.levels.WARN)
		return false
	end
	return open_review_summary_editor(summary)
end

local function start_selection_review(opts)
	if not ensure_backend(REVIEW_LANE) then
		return false
	end
	if warn_if_lane_busy(REVIEW_LANE) then
		return false
	end
	local item = review.start_planned("selection", opts)
	if not item then
		ui.notify("No review items found for the selected range", vim.log.levels.WARN)
		return false
	end
	local prompt_focus = build_review_start_prompt(opts and opts.focus or "", opts and opts.start_context)
	local prompt = review.build_prompt(prompt_focus)
	if not prompt then
		return false
	end
	local label = opts and opts.focus ~= "" and opts.focus or "Review selection"
	return send_review_prompt(prompt, label, { open_log = false })
end

local function start_free_review(focus, opts)
	opts = opts or {}
	local text = trimmed(focus)
	if text == "" then
		ui.notify("StriderReview requires input", vim.log.levels.WARN)
		return false
	end
	if not ensure_backend(REVIEW_LANE) then
		return false
	end
	if warn_if_lane_busy(REVIEW_LANE) then
		return false
	end
	if
		not review.start_planning(text, {
			context_source = opts.context_source,
			start_context = opts.start_context,
		})
	then
		return false
	end
	local request = build_review_start_prompt(text, opts.start_context)
	return send("/plan " .. request, text, {
		lane = REVIEW_LANE,
		operation = "plan",
		debug_prompt = request,
		open_log = false,
	})
end

local function truncate_review_context(text)
	text = trimmed(text)
	if text == "" then
		return nil
	end
	if #text <= REVIEW_MAIN_CONTEXT_LIMIT then
		return text
	end
	local omitted = #text - REVIEW_MAIN_CONTEXT_LIMIT
	return string.format(
		"[... %d chars omitted from earlier main chat log ...]\n%s",
		omitted,
		text:sub(-REVIEW_MAIN_CONTEXT_LIMIT)
	)
end

local function main_log_context(session)
	local log_buf = session.log_buf
	if not log_buf or not vim.api.nvim_buf_is_valid(log_buf) then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(log_buf, 0, -1, false)
	local kept = {}
	for _, line in ipairs(lines) do
		if not line:match("^%[strider%] backend started") then
			table.insert(kept, line)
		end
	end
	return truncate_review_context(table.concat(kept, "\n"))
end

main_chat_review_context = function()
	local session = state.get_session(MAIN_LANE)
	if not session then
		return nil
	end
	local log_context = main_log_context(session)
	if log_context then
		return log_context
	end
	local parts = {}
	local summary = trimmed(session.last_summary)
	if summary ~= "" then
		table.insert(parts, "Main chat summary:\n" .. summary)
	end
	local prompt = session.last_user_message and trimmed(session.last_user_message.text) or ""
	if prompt ~= "" then
		table.insert(parts, "Latest main chat request:\n" .. prompt)
	end
	return truncate_review_context(table.concat(parts, "\n\n"))
end

build_review_start_prompt = function(text, start_context)
	local request = trimmed(text)
	local copied = trimmed(start_context)
	if copied == "" then
		return request
	end
	return table.concat({
		request,
		"",
		"<MAIN_CHAT_CONTEXT>",
		"Use this copied main-chat context as background only. The review request above is authoritative.",
		copied,
		"</MAIN_CHAT_CONTEXT>",
	}, "\n")
end

local function review_context_hint(source)
	if source == REVIEW_CONTEXT_MAIN then
		return "Context: main chat (press <C-g>c for fresh review)"
	end
	return "Context: fresh (press <C-g>c to include main chat)"
end

local function selected_review_start_context(source)
	if source ~= REVIEW_CONTEXT_MAIN then
		return nil
	end
	local copied = main_chat_review_context()
	if copied then
		return copied
	end
	ui.notify("No main chat context found; starting fresh", vim.log.levels.WARN)
	return nil
end

-- Called from rpc.lua after a /plan turn finishes and a plan has been
-- ingested. Dispatches the first /review for stop 1 so the model's next
-- turn explains the first stop instead of idling.
-- Called from rpc.lua once a plan has been ingested. With pre-computed
-- explanations (smwyg-browser style), focusing stop 1 is sufficient —
-- the explanation is already in `items[1].explanation` and the sidebar
-- renders it. No second model round-trip needed.
function M.dispatch_first_review()
	if not review.has_active_review() then
		return false
	end
	if review.is_planning() then
		return false
	end
	-- `ingest_plan` already navigated to the first visible item (message 0
	-- or stop 1) and rendered the sidebar. Nothing else to do here — this
	-- hook exists so rpc.lua can still signal "plan turn complete" without
	-- hard-coding navigation.
	return true
end

-- Re-dispatch the plan turn if it stalled. Only useful while planning;
-- once a plan has landed, explanations are already pre-computed so
-- there is nothing to retry mid-review.
function M.retry()
	if not review.has_active_review() then
		ui.notify("No active Strider review to retry", vim.log.levels.WARN)
		return false
	end
	if review.is_planning() then
		local session = state.get_session(REVIEW_LANE)
		local active = session and session.review
		local goal = active and active.goal
		if not goal or goal == "" then
			ui.notify("Cannot retry plan: review goal is missing", vim.log.levels.WARN)
			return false
		end
		local request = build_review_start_prompt(goal, active and active.start_context)
		return send("/plan " .. request, goal, {
			lane = REVIEW_LANE,
			operation = "plan",
			debug_prompt = request,
			open_log = false,
		})
	end
	ui.notify("Nothing to retry — explanations are pre-computed.", vim.log.levels.INFO)
	return false
end

function M.setup(opts)
	state.setup(opts or {})
end

function M.status()
	ui.show_status(status.lines())
end

-- Cycle the pi thinking level (same semantics as pi's own shift-tab).
-- Dispatched as a pure extension command — no assistant turn, no
-- activity spinner, no change to compose buffer contents. The widget
-- update triggered on the TS side refreshes the `(level)` suffix on
-- the winbar's model line.
function M.cycle_thinking()
	if not ensure_backend(MAIN_LANE) then
		return
	end
	rpc.send_prompt(MAIN_LANE, "/thinking")
end

local function set_chat_read_only(enabled, opts)
	opts = opts or {}
	local session = ensure_session(MAIN_LANE)
	session.chat_read_only = enabled == true
	ui.refresh_compose_winbar(MAIN_LANE)
	ui.refresh_compose_hint()
	sync_chat_read_only_to_pi()
	if opts.notify ~= false then
		ui.notify(
			string.format("Strider chat read-only %s", session.chat_read_only and "enabled" or "disabled"),
			vim.log.levels.INFO
		)
	end
	return session.chat_read_only
end

function M.toggle_chat_read_only()
	return set_chat_read_only(not chat_read_only_enabled())
end

function M.chat_read_only(args)
	local value = trimmed(args or ""):lower()
	if value == "" or value == "toggle" then
		return M.toggle_chat_read_only()
	end
	if value == "on" or value == "true" or value == "1" or value == "enable" or value == "enabled" then
		return set_chat_read_only(true)
	end
	if value == "off" or value == "false" or value == "0" or value == "disable" or value == "disabled" then
		return set_chat_read_only(false)
	end
	ui.notify("Usage: :StriderChatReadOnly [on|off|toggle]", vim.log.levels.WARN)
	return false
end

function M.chat_read_only_enabled()
	return chat_read_only_enabled()
end

-- :StriderStop / :StriderStopFlow — cancel an in-flight turn via pi's abort RPC.
-- The actual "[error] Turn aborted" block in the log and spinner reset
-- happen when pi emits the final message_end (see handle_message_end's
-- stopReason == "aborted" branch). We just fire the abort and give the
-- user a quick notify so the interval between keypress and message_end
-- doesn't feel like nothing happened.
local function stop_lane(lane, idle_message, stopping_message)
	if not state.peek_pending_request(lane) then
		ui.notify(idle_message, vim.log.levels.INFO)
		return
	end
	if rpc.abort(lane) then
		ui.notify(stopping_message, vim.log.levels.INFO)
	end
end

function M.stop()
	stop_lane(MAIN_LANE, "Strider is idle — nothing to stop", "Stopping Strider…")
end

function M.stop_flow()
	local stopped = false
	for _, lane in ipairs(state.lanes()) do
		if state.is_flow_lane(lane) and state.peek_pending_request(lane) and rpc.abort(lane) then
			stopped = true
		end
	end
	if stopped then
		ui.notify("Stopping Strider flow…", vim.log.levels.INFO)
	else
		ui.notify("Strider flow is idle — nothing to stop", vim.log.levels.INFO)
	end
end

local function send_main_command(command)
	return send(command, command, {
		lane = MAIN_LANE,
		operation = "command",
		open_log = true,
	})
end

function M.sessions()
	return send_main_command("/sessions")
end

function M.resume(target)
	target = trimmed(target)
	local command = target ~= "" and ("/resume " .. target) or "/resume"
	return send_main_command(command)
end

-- Slash-commands that pi routes to our /prompt etc. handlers which DO
-- send a user message to the model — treat these as normal prompt turns
-- (they produce message_end and need pending-request tracking).
local strider_prompt_commands = {
	prompt = true,
	patch = true,
	review = true,
	search = true,
	plan = true,
}

-- Recognize Strider slash-commands that intentionally start model-backed
-- prompt turns. Other slash-commands are routed as extension/built-in
-- commands and use command-style pending/activity handling.
local function is_prompt_slash(text)
	local name = text:match("^/([%w%-_:]+)")
	return name and strider_prompt_commands[name] or false
end

-- Built-in commands that are dedicated RPC message types, not extension
-- commands routed through prompt. Session-browsing commands (/sessions,
-- /resume, /switch_session) stay on the prompt path so the Strider pi
-- extension can resolve ids and paths before switching.
local rpc_commands = {
	new = {
		type = "new_session",
		activity_title = "Starting new Strider session...",
		activity_done = "New Strider session started",
	},
	compact = {
		type = "compact",
		args_key = "customInstructions",
		activity_title = "Compacting Strider context...",
		activity_done = "Strider context compacted",
	},
	export = {
		type = "export_html",
		args_key = "outputPath",
		activity_title = "Exporting Strider session...",
		activity_done = "Strider session exported",
	},
}

local function send_rpc_command(text, rpc_def, extra)
	local lane = MAIN_LANE
	if warn_if_lane_busy(lane) then
		return false
	end
	if not ensure_backend(lane) then
		return false
	end
	ui.open_log({ preserve_focus = true }, lane)
	state.clear_error(lane)
	state.set_pending_request("command", {
		activity_done = rpc_def.activity_done,
		command_text = text,
		command_type = rpc_def.type,
	}, lane)
	ui.start_activity(rpc_def.activity_title or activity_title("command"), "log", "command", lane)
	ui.refresh_compose_winbar(lane)
	ui.refresh_compose_hint()
	local ok = rpc.send_command(rpc_def.type, extra, lane)
	if not ok then
		state.set_pending_request(nil, nil, lane)
		ui.finish_activity("Strider command failed to start", "error", lane)
		ui.refresh_compose_hint()
		return false
	end
	ui.append_block("user", text, lane)
	return true
end

-- Aliases: common short-hands that map to the canonical command name
-- used by the extension or RPC layer. Checked early in dispatch_prompt
-- so `/model` works the same as `/models`.
local command_aliases = {
	model = "models",
}

-- /fork needs a multi-step flow: fetch forkable messages, present a
-- picker, then issue the actual fork command with the chosen entryId.
local function fork_flow()
	rpc.send_command("get_fork_messages", {}, nil, function(event)
		if not event.success then
			ui.notify(event.errorMessage or event.error or "Failed to get fork messages", vim.log.levels.ERROR)
			return
		end
		local messages = event.data and event.data.messages or {}
		if #messages == 0 then
			ui.notify("No messages available to fork from", vim.log.levels.WARN)
			return
		end
		local labels = {}
		local by_label = {}
		for i, msg in ipairs(messages) do
			local preview = (msg.text or "(empty)"):sub(1, 120):gsub("%s+", " ")
			local label = string.format("%3d: %s", i, preview)
			table.insert(labels, label)
			by_label[label] = msg.entryId
		end
		vim.ui.select(labels, { prompt = "Fork from message" }, function(choice)
			if not choice then
				return
			end
			local entry_id = by_label[choice]
			if not entry_id then
				return
			end
			rpc.send_command("fork", { entryId = entry_id })
		end)
	end)
end

local function dispatch_prompt(text)
	-- If the user typed a slash-command (e.g. /models, /tree, /compact),
	-- pass it through verbatim so pi routes it to the matching extension
	-- command instead of wrapping it in /prompt (which would send the
	-- slash-command to the LLM as prose and never fire the handler).
	if text:sub(1, 1) == "/" then
		local name, rest = text:match("^/([%w%-_]+)%s*(.*)$")
		local original_name = name
		name = name and (command_aliases[name] or name)
		-- Rebuild the command text if we resolved an alias so pi sees the
		-- canonical name (e.g. /model → /models).
		if name and name ~= original_name then
			text = "/" .. name .. (rest ~= "" and (" " .. rest) or "")
		end
		if name == "fork" then
			fork_flow()
			return
		end
		local rpc_def = name and rpc_commands[name]
		if rpc_def then
			local extra = {}
			if rpc_def.args_key and rest and rest ~= "" then
				extra[rpc_def.args_key] = rest
			end
			send_rpc_command(text, rpc_def, extra)
			return
		end
		if is_prompt_slash(text) then
			local command = text
			if name == "prompt" and chat_read_only_enabled() then
				command = read_only_chat_prompt(rest ~= "" and rest or text)
			end
			send(command, text, { operation = "prompt", open_log = true })
		else
			-- Pi built-in or extension command (e.g. /models).
			-- Still needs a pending request so streamed response events
			-- aren't silently dropped by the message_update handler.
			send(text, text, { operation = "command", open_log = true })
		end
		return
	end
	local command = chat_read_only_enabled() and read_only_chat_prompt(text) or ("/prompt " .. text)
	send(command, text, { operation = "prompt", open_log = true })
end

-- Send a user message from the compose buffer. If a request is already
-- in flight, deliver as a steer (mid-turn redirect) instead of a new
-- prompt. The log gets a prompt block with a normal or steer marker so the
-- transcript reads correctly. dispatch_compose is referenced by
-- M.open_compose_for_clarify (defined just below as the clarify-reply
-- entrypoint) before its own definition further down, so it is
-- forward-declared here.
local dispatch_compose

-- Send a clarify reply back through the RPC extension_ui_response
-- channel. Mirrors the shape rpc.lua's send_ui_response uses but lives
-- here so we don't have to expose that helper — we just write the JSON
-- to the same channel via the rpc module.
local function reply_to_clarify(pending, text)
	local session = state.get_session(MAIN_LANE)
	if not session or not session.job_id then
		return false
	end
	local body = { type = "extension_ui_response", id = pending.id, value = text }
	local ok, encoded = pcall(vim.json.encode, body)
	if not ok then
		return false
	end
	vim.fn.chansend(session.job_id, encoded .. "\n")
	return true
end

local function cancel_clarify(pending)
	local session = state.get_session(MAIN_LANE)
	if not session or not session.job_id then
		return false
	end
	local body = { type = "extension_ui_response", id = pending.id, cancelled = true }
	local ok, encoded = pcall(vim.json.encode, body)
	if not ok then
		return false
	end
	vim.fn.chansend(session.job_id, encoded .. "\n")
	return true
end

-- Open the compose surfaces so the user can answer a clarify. The
-- compose buffer's send callback is the standard dispatch_compose,
-- which checks pending_clarify first and routes appropriately.
function M.open_compose_for_clarify()
	if not ensure_backend(MAIN_LANE) then
		return
	end
	ui.open_log({ preserve_focus = true }, MAIN_LANE)
	ui.open_compose(function(text)
		return dispatch_compose(text)
	end)
end

-- Called from compose's <Esc><Esc> keymap. If a clarify is pending,
-- cancel it. Otherwise fall through so the keymap's usual behavior
-- (stopinsert) runs.
function M.cancel_pending_clarify_if_any()
	local pending = state.consume_pending_clarify(MAIN_LANE)
	if not pending then
		return false
	end
	state.set_status("strider-clarify", nil, MAIN_LANE)
	ui.refresh_compose_winbar(MAIN_LANE)
	ui.refresh_compose_hint()
	cancel_clarify(pending)
	if pending.kind == "plan_proposal" then
		ui.append({ "[strider] plan proposal rejected" }, MAIN_LANE)
	else
		ui.append({ "[strider] clarify cancelled" }, MAIN_LANE)
	end
	return true
end

function dispatch_compose(text)
	text = trimmed(text)
	if text == "" then
		return false
	end
	if not ensure_backend(MAIN_LANE) then
		return false
	end

	-- A pending clarify takes precedence over everything: the model is
	-- explicitly waiting for a reply on the extension_ui_request channel.
	-- Whatever the user types becomes the answer. No tangent, no steer,
	-- no new prompt turn. Clears the badge on success.
	local pending_clarify = state.peek_pending_clarify(MAIN_LANE)
	if pending_clarify then
		state.consume_pending_clarify(MAIN_LANE)
		state.set_status("strider-clarify", nil, MAIN_LANE)
		ui.refresh_compose_winbar(MAIN_LANE)
		ui.refresh_compose_hint()
		ui.append_block("user", text, MAIN_LANE)
		if not reply_to_clarify(pending_clarify, text) then
			ui.notify("Failed to send clarify reply", vim.log.levels.ERROR)
			return false
		end
		return true
	end

	local pending = state.peek_pending_request(MAIN_LANE)
	if pending then
		-- Extension commands (/models, /tree, etc.) are not allowed as steer
		-- messages — pi requires them to come through prompt. Reject with a
		-- helpful notice instead of silently dropping.
		if text:sub(1, 1) == "/" then
			ui.notify(
				"Slash-commands can't be sent mid-turn — wait for the current request to finish.",
				vim.log.levels.WARN
			)
			return false
		end
		-- Steer: the pending request stays the same, the model gets the
		-- new message mid-stream. No new operation, no new activity.
		ui.append_block("steer", text, MAIN_LANE)
		local ok = rpc.send_steer(MAIN_LANE, text)
		if not ok then
			ui.notify("Steer failed to send", vim.log.levels.ERROR)
			return false
		end
		return true
	end
	-- No pending — start a new prompt turn. send() handles the [user]
	-- append, pending state, and activity spinner.
	dispatch_prompt(text)
	return true
end

local function open_chat_surface(prefill)
	if not ensure_backend(MAIN_LANE) then
		return false
	end
	ui.hide_chat_card()
	ui.ensure_compose_buffer(function(text)
		return dispatch_compose(text)
	end)
	if prefill and prefill ~= "" then
		ui.prefill_compose(prefill)
	end
	ui.open_chat_split(function(text)
		return dispatch_compose(text)
	end)
	return true
end

function M.chat(prompt, opts)
	prompt = trimmed(prompt)
	local range = range_from_opts(opts)
	local prefill = chat_prefill(prompt, range)

	if prefill == "" and ui.chat_is_visible() then
		ui.hide_chat()
		return
	end

	open_chat_surface(prefill)
end

local function pick_cards(title, opts)
	local items = card_picker.items(opts)
	if #items == 0 then
		ui.notify("No " .. title .. " yet", vim.log.levels.INFO)
		return false
	end
	return picker.select(title, items, function(item)
		local value = item and item.value or {}
		if value.type == "chat" then
			open_chat_surface("")
		end
		if value.type == "flow" then
			if value.kind == "q" then
				ui.open_q_answer_split(value.id, value.lane)
			else
				ui.focus_flow_card(value.id, value.lane)
			end
		elseif value.type == "patch" then
			ui.open_patch_summary_split(value.id, value.lane)
		end
	end)
end

function M.cards()
	return pick_cards("Strider Cards")
end

function M.q_cards()
	return pick_cards("StriderQ Answers", { kind = "q" })
end

function M.q_latest()
	local win = ui.open_q_answer_split(nil, Q_LANE)
	if not win then
		ui.notify("No StriderQ answers yet", vim.log.levels.INFO)
		return false
	end
	return true
end

function M.patches()
	return pick_cards("Strider patches", { kind = "patch" })
end

function M.patch_latest()
	local win = ui.open_patch_summary_split(nil, PATCH_LANE)
	if not win then
		ui.notify("No Strider patches yet", vim.log.levels.INFO)
		return false
	end
	return true
end

function M.cards_clear(opts)
	local clear_opts = { all = opts and opts.bang }
	local count = (ui.clear_flow_cards(clear_opts) or 0) + (ui.clear_patch_summaries(clear_opts) or 0)
	ui.notify(string.format("Dismissed %d Strider surface%s", count, count == 1 and "" or "s"), vim.log.levels.INFO)
	return count
end

function M.search(prompt)
	prompt = trimmed(prompt)
	if prompt == "" then
		ui.open_prompt_editor("Strider search", function(text)
			M.search(text)
		end, {
			'Structured code search. e.g. "websocket entrypoints".',
			"Use :StriderSearches to browse previous searches.",
		})
		return
	end
	send("/search " .. prompt, prompt, {
		lane = FLOW_LANE,
		operation = "search",
		metadata = { prompt = prompt },
	})
end

local function submit_review_request(text, range, opts)
	opts = opts or {}
	text = trimmed(text)
	if text == "" then
		return
	end
	if warn_if_lane_busy(REVIEW_LANE) then
		return
	end

	if review.has_active_review() and range then
		local prompt = review.build_prompt(text)
		if prompt and send_review_prompt(prompt, text, { open_log = false }) then
			review.begin_ranged_question(range, text)
		end
		return
	end

	if review.has_active_review() then
		local prompt = review.build_prompt(text)
		if not prompt then
			ui.notify("No active Strider review item", vim.log.levels.WARN)
			return
		end
		if send_review_prompt(prompt, text, { open_log = false }) then
			review.begin_item_question(text)
		end
		return
	end

	if range then
		start_selection_review({
			context_source = opts.context_source,
			endLine = range.endLine,
			focus = text,
			path = range.path,
			start_context = opts.start_context,
			startLine = range.startLine,
		})
		return
	end

	start_free_review(text, {
		context_source = opts.context_source,
		start_context = opts.start_context,
	})
end

function M.review(args, opts)
	local range = range_from_opts(opts)
	local text = trimmed(args)
	local title = "Strider review context"
	local hint_lines
	local context_source = REVIEW_CONTEXT_FRESH
	local starting_review = not review.has_active_review()

	if review.has_active_review() and range then
		title = "Ask about this selected range"
		hint_lines = {
			"Ask a question about the selected range inside the active review.",
			string.format("Range: %s", range_pointer(range)),
		}
	elseif review.has_active_review() then
		title = "Ask about this review item"
		hint_lines = {
			"Ask a question about the current review item.",
		}
	elseif range then
		hint_lines = function()
			return {
				"Describe what you want reviewed in this selected range.",
				string.format("Range: %s", range_pointer(range)),
				review_context_hint(context_source),
			}
		end
	else
		hint_lines = function()
			return {
				"Describe what you want reviewed.",
				review_context_hint(context_source),
			}
		end
	end

	local extra_keymaps
	if starting_review then
		extra_keymaps = {
			{
				lhs = "<C-g>c",
				desc = "Toggle review start context",
				callback = function(editor)
					context_source = context_source == REVIEW_CONTEXT_MAIN and REVIEW_CONTEXT_FRESH
						or REVIEW_CONTEXT_MAIN
					ui.notify(
						string.format(
							"Review context: %s",
							context_source == REVIEW_CONTEXT_MAIN and "main chat" or "fresh"
						),
						vim.log.levels.INFO
					)
					editor.render_hint()
				end,
			},
		}
	end

	ui.open_prompt_editor(title, function(input)
		if review.has_active_review() then
			submit_review_request(input, range)
			return
		end
		local start_context = selected_review_start_context(context_source)
		submit_review_request(input, range, {
			context_source = start_context and context_source or REVIEW_CONTEXT_FRESH,
			start_context = start_context,
		})
	end, {
		extra_keymaps = extra_keymaps,
		hint_lines = hint_lines,
		prefill = text ~= "" and text or nil,
	})
end

local function dispatch_patch(prompt, range)
	local lines = {
		string.format("Patch target file: %s", range.path),
		string.format("Patch target lines: %d-%d", range.startLine, range.endLine),
		"Only edit this file and stay as close to the selected range as possible.",
		"<PATCH_EXCERPT>",
		read_excerpt(range.path, range.startLine, range.endLine),
		"</PATCH_EXCERPT>",
		"User request: " .. prompt,
	}
	send("/patch " .. table.concat(lines, "\n"), prompt, {
		lane = PATCH_LANE,
		operation = "patch",
		metadata = {
			target = {
				endLine = range.endLine,
				path = range.path,
				startLine = range.startLine,
			},
		},
	})
end

local function resolve_patch_range(opts)
	local range = range_from_opts(opts)
	local item = review.current_item()
	if not range and item then
		return {
			path = item.path,
			startLine = item.startLine,
			endLine = item.endLine,
		}
	end
	return range
end

local function q_model_label(label)
	label = vim.trim(label or state.get_config().q_default_model or "fast")
	return label ~= "" and label or "fast"
end

local function apply_q_model(lane, label)
	local profile, resolved = state.resolve_q_model(q_model_label(label))
	state.ensure_session(lane, current_cwd())
	state.set_model_override(lane, profile, resolved)
	return resolved
end

local function dispatch_q(prompt, range, opts)
	local message
	if range then
		local lines = {
			string.format("Context file: %s", range.path),
			string.format("Context lines: %d-%d", range.startLine, range.endLine),
			"<Q_EXCERPT>",
			read_excerpt(range.path, range.startLine, range.endLine),
			"</Q_EXCERPT>",
			"Question: " .. prompt,
		}
		message = table.concat(lines, "\n")
	else
		message = prompt
	end
	opts = opts or {}
	local lane, seq = opts.worker_lane, opts.q_seq
	local model_label = opts.model_label
	if not lane then
		lane, seq = state.next_q_worker_lane()
		model_label = apply_q_model(lane, model_label)
	end
	return send("/prompt " .. message, prompt, {
		lane = lane,
		operation = "q",
		user_label = opts.user_label,
		metadata = {
			card_id = opts.card_id,
			card_lane = Q_LANE,
			model_label = model_label,
			q_seq = seq or state.q_lane_index(lane),
		},
	})
end

local function submit_q_request(prompt, range, opts)
	prompt = trimmed(prompt)
	if prompt == "" then
		return nil
	end
	return dispatch_q(prompt, range, opts)
end

function M.q_followup(prompt, card_id)
	prompt = trimmed(prompt)
	if prompt == "" then
		return false
	end
	local card = ui.get_flow_card(card_id, Q_LANE)
	local worker_lane = card and card.worker_lane or Q_LANE
	return dispatch_q(prompt, nil, {
		card_id = card_id,
		model_label = card and card.model_label,
		user_label = "followup",
		worker_lane = worker_lane,
	})
end

local function parse_q_prompt(prompt)
	prompt = trimmed(prompt)
	local model = prompt:match("^%-%-(fast)%s*") or prompt:match("^%-%-(deep)%s*")
	if model then
		prompt = trimmed(prompt:gsub("^%-%-" .. model .. "%s*", "", 1))
	end
	return prompt, q_model_label(model)
end

function M.q(prompt, opts)
	local q_prompt, selected_model = parse_q_prompt(prompt)
	opts = opts or {}
	local range = range_from_opts(opts)
	local pointer = range_pointer(range)
	local function hint_lines()
		local other = selected_model == "fast" and "deep" or "fast"
		local lines = {
			string.format("Model: %s · <Tab> switch to %s", selected_model, other),
			"Ask a side question without opening chat.",
			"Answer notifies when ready; use :StriderQs to read it.",
		}
		if pointer then
			table.insert(lines, string.format("Range: %s", pointer))
		end
		return lines
	end

	ui.open_prompt_editor("StriderQ", function(text)
		return submit_q_request(text, range, { model_label = selected_model })
	end, {
		extra_keymaps = {
			{
				lhs = "<Tab>",
				callback = function(ctx)
					selected_model = selected_model == "fast" and "deep" or "fast"
					ctx.render_hint()
				end,
				desc = "Toggle StriderQ model",
			},
		},
		hint_lines = hint_lines,
		prefill = q_prompt ~= "" and q_prompt or nil,
	})
end

function M.patch(prompt, opts)
	prompt = trimmed(prompt)

	local range = resolve_patch_range(opts)
	if not range then
		ui.notify("StriderPatch needs a visual range or an active review item", vim.log.levels.WARN)
		return
	end

	ui.open_prompt_editor("Strider patch request", function(text)
		text = trimmed(text)
		if text == "" then
			return
		end
		dispatch_patch(text, range)
	end, {
		hint_lines = {
			string.format("Patch target: %s", range_pointer(range)),
			"Keep changes local to this range.",
			"Runs in the background; use :StriderPatches to review it.",
		},
		prefill = prompt ~= "" and prompt or nil,
	})
end

function M.next_step(accept_current)
	if not review.has_active_review() then
		ui.notify("No active Strider review session", vim.log.levels.WARN)
		return
	end

	if accept_current then
		review.accept_current_stop({ quiet = true })
	end

	-- Explanations are pre-computed at plan time. Navigation is a pure
	-- index++ that focuses the next stop; no model round-trip.
	local item, finished = review.advance(1)
	if item then
		return
	end

	if finished then
		local prompt = review.finish()
		if prompt then
			local comment_lines = review.pending_comment_lines()
			if comment_lines then
				ui.append_block("review-comments", table.concat(comment_lines, "\n"), REVIEW_LANE)
			end
			send_review_prompt(prompt, "Summarize unresolved review comments", { open_log = false })
		else
			M.complete_review_summary("Review complete. No unresolved comments.")
			ui.notify("Strider review complete", vim.log.levels.INFO)
		end
	end
end

function M.prev_step()
	if not review.has_active_review() then
		ui.notify("No active Strider review session", vim.log.levels.WARN)
		return
	end
	local _item, past_end, moved = review.advance(-1)
	if not moved and not past_end then
		ui.notify("Already at the first review item", vim.log.levels.WARN)
	end
end

function M.comment(text, opts)
	local range = range_from_opts(opts)
	local item = review.current_item()
	local prefill = trimmed(text)

	if not item then
		ui.notify("No active review item to comment on", vim.log.levels.WARN)
		return
	end

	local function log_comment(comment)
		ui.append_block(
			"review",
			string.format("%s:%d-%d\n%s", comment.path, comment.startLine, comment.endLine, comment.text),
			REVIEW_LANE
		)
	end

	review.open_comment_editor(range, log_comment, {
		prefill = prefill ~= "" and prefill or nil,
	})
end

function M.comments()
	review.comment_picker()
end

function M.review_items()
	review.item_picker()
end

function M.searches()
	search.history_picker(FLOW_LANE)
end

local function toggle_lane_log(lane)
	if ui.log_is_visible(lane) then
		ui.hide_log(lane)
		return
	end
	ensure_session(lane)
	ui.open_log({}, lane)
end

function M.flow_log()
	toggle_lane_log(FLOW_LANE)
end

local function latest_q_worker_lane()
	local session = state.get_session(Q_LANE)
	local latest = nil
	for _, card in ipairs(session and session.flow_cards or {}) do
		if
			card.kind == "q"
			and not card.dismissed
			and (not latest or (card.started_at or 0) > (latest.started_at or 0))
		then
			latest = card
		end
	end
	return latest and latest.worker_lane or Q_LANE
end

function M.q_log()
	toggle_lane_log(latest_q_worker_lane())
end

function M.patch_log()
	toggle_lane_log(PATCH_LANE)
end

function M.review_log()
	if ui.log_is_visible(REVIEW_LANE) then
		ui.hide_log(REVIEW_LANE)
		return
	end
	ensure_session(REVIEW_LANE)
	ui.open_log({}, REVIEW_LANE)
end

return M
