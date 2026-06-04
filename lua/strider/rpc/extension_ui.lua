local picker = require("strider.picker")
local state = require("strider.state")
local ui = require("strider.ui")

local M = {}

local notify_levels = {
	error = vim.log.levels.ERROR,
	info = vim.log.levels.INFO,
	warning = vim.log.levels.WARN,
}

local session_status_labels = {
	new = "New session",
	fork = "Forked session",
	resume = "Resumed session",
}

local function handle_notify(event)
	ui.notify(event.message or "Strider notice", notify_levels[event.notifyType] or vim.log.levels.INFO)
end

local function handle_status(event, lane)
	local session = state.get_session(lane)
	local previous = session and session.status[event.statusKey]
	state.set_status(event.statusKey, event.statusText, lane)

	if event.statusKey == "strider-session" then
		local reason = event.statusText
		local label = session_status_labels[reason]
		if label then
			ui.append_block("strider", string.format("──── %s ────", label), lane)
		end
		return
	end

	if event.statusKey ~= "strider" or event.statusText == previous then
		return
	end
	if event.statusText == "complete" then
		ui.append({ "[strider] Workflow complete", "" }, lane)
	elseif event.statusText and event.statusText:find("final%-awaiting%-next", 1, false) then
		ui.append({ "[strider] Final chunk awaiting :StriderNext", "" }, lane)
	elseif event.statusText and event.statusText:find("awaiting-next", 1, true) then
		ui.append({ "[strider] Awaiting :StriderNext", "" }, lane)
	end
end

local function exec_vim_request(id, prefill, respond, lane)
	local ok, vim_exec = pcall(require, "strider.vim_exec")
	local result
	if ok and vim_exec and vim_exec.exec then
		local exec_ok, value = pcall(vim_exec.exec, prefill)
		result = exec_ok and value
			or vim.json.encode({
				ok = false,
				phase = "bridge",
				error = tostring(value),
			})
	else
		result = vim.json.encode({
			ok = false,
			phase = "bridge",
			error = tostring(vim_exec),
		})
	end
	respond(id, { value = result }, lane)
end

local function handle_flow_editor(id, title, prefill, plan_prefix, respond, lane)
	local function popup_cancel(message)
		ui.append({ message or "[strider] clarify cancelled" }, lane)
		respond(id, { cancelled = true }, lane)
	end

	if title:sub(1, #plan_prefix) == plan_prefix then
		local display_title = title:sub(#plan_prefix + 1)
		local body = prefill ~= "" and prefill or "(empty proposal)"
		ui.append_block("plan", string.format("%s\n\n%s", display_title, body), lane)
		ui.clarify_plan_proposal_picker(function(choice)
			if choice == "accept" then
				ui.append_block("user", prefill ~= "" and prefill or "(accepted)", lane)
				respond(id, { value = prefill }, lane)
			elseif choice == "modify" then
				ui.open_prompt_editor(display_title, function(text)
					ui.append_block("user", text, lane)
					respond(id, { value = text }, lane)
				end, {
					hint_lines = { "Edit the proposal, then submit it back to Strider." },
					on_cancel = function()
						popup_cancel("[strider] plan proposal rejected")
					end,
					prefill = prefill,
				})
			else
				popup_cancel("[strider] plan proposal rejected")
			end
		end)
		return
	end

	local body_parts = { title }
	if prefill ~= "" then
		table.insert(body_parts, "")
		table.insert(body_parts, prefill)
	end
	ui.append_block("clarify", table.concat(body_parts, "\n"), lane)
	ui.open_prompt_editor(title, function(text)
		ui.append_block("user", text, lane)
		respond(id, { value = text }, lane)
	end, {
		hint_lines = { "Reply to Strider's question." },
		on_cancel = popup_cancel,
		prefill = prefill ~= "" and prefill or nil,
	})
end

local function handle_main_plan_editor(id, display_title, prefill, _respond, lane)
	local body = prefill ~= "" and prefill or "(empty proposal)"
	ui.append_block("plan", string.format("%s\n\n%s", display_title, body), lane)
	state.set_pending_clarify(id, display_title, lane, {
		kind = "plan_proposal",
		prefill = prefill,
	})
	state.set_status("strider-clarify", "plan", lane)
	ui.refresh_compose_winbar(lane)
	ui.refresh_compose_hint()
	require("strider").open_compose_for_clarify()
	ui.seed_compose(prefill)
end

local function handle_main_clarify_editor(id, title, prefill, lane)
	local body_parts = { title }
	if prefill ~= "" then
		table.insert(body_parts, "")
		table.insert(body_parts, prefill)
	end
	ui.append_block("clarify", table.concat(body_parts, "\n"), lane)
	state.set_pending_clarify(id, title, lane)
	state.set_status("strider-clarify", "clarify", lane)
	ui.refresh_compose_winbar(lane)
	ui.refresh_compose_hint()
	ui.open_log({ preserve_focus = true }, lane)
	require("strider").open_compose_for_clarify()
end

local function handle_editor(event, lane, respond)
	local id = event.id
	local title = event.title or "Strider clarify"
	local prefill = event.prefill or ""
	local vim_exec_prefix = "[strider-vim-exec]"
	if title:sub(1, #vim_exec_prefix) == vim_exec_prefix then
		exec_vim_request(id, prefill, respond, lane)
		return
	end

	local plan_prefix = "[strider-plan-proposal] "
	if lane ~= "main" then
		handle_flow_editor(id, title, prefill, plan_prefix, respond, lane)
		return
	end
	if title:sub(1, #plan_prefix) == plan_prefix then
		handle_main_plan_editor(id, title:sub(#plan_prefix + 1), prefill, respond, lane)
		return
	end
	handle_main_clarify_editor(id, title, prefill, lane)
end

local function handle_confirm(event, lane, respond)
	local id = event.id
	local title = event.title or "Strider confirm"
	local message = event.message or ""
	local prompt = message ~= "" and (title .. "\n\n" .. message) or title
	vim.schedule(function()
		vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
			if choice == nil then
				ui.append({ "[strider] confirm cancelled" }, lane)
				respond(id, { cancelled = true }, lane)
			else
				local confirmed = choice == "Yes"
				ui.append({ string.format("[strider] confirm: %s", choice) }, lane)
				respond(id, { confirmed = confirmed }, lane)
			end
		end)
	end)
end

local function handle_select(event, lane, respond)
	local id = event.id
	local title = event.title or "Strider select"
	local items = {}
	for _, opt in ipairs(event.options or {}) do
		table.insert(items, { label = tostring(opt), value = opt })
	end

	ui.append_block("strider", string.format("select: %s", title), lane)
	local delivered = false
	local function deliver(chosen)
		if delivered then
			return
		end
		delivered = true
		if chosen == nil then
			ui.append({ "[strider] select cancelled" }, lane)
			respond(id, { cancelled = true }, lane)
		else
			ui.append({ string.format("[strider] select: %s", chosen) }, lane)
			respond(id, { value = chosen }, lane)
		end
	end
	vim.schedule(function()
		local ok = picker.select(title, items, function(item)
			deliver(item and item.value or nil)
		end)
		if not ok then
			deliver(nil)
		end
	end)
end

local function handle_input(event, lane, respond)
	local id = event.id
	local title = event.title or "Strider input"
	local placeholder = event.placeholder or ""
	ui.append_block("strider", string.format("input: %s", title), lane)
	vim.schedule(function()
		vim.ui.input({ prompt = title .. ": ", default = placeholder }, function(value)
			if value == nil then
				ui.append({ "[strider] input cancelled" }, lane)
				respond(id, { cancelled = true }, lane)
			else
				ui.append_block("user", value, lane)
				respond(id, { value = value }, lane)
			end
		end)
	end)
end

function M.handle(event, lane, respond)
	if event.method == "notify" then
		handle_notify(event)
	elseif event.method == "setStatus" then
		handle_status(event, lane)
	elseif event.method == "setWidget" then
		state.set_widget(event.widgetLines, lane)
		ui.refresh_log_winbar(lane)
	elseif event.method == "editor" then
		handle_editor(event, lane, respond)
	elseif event.method == "confirm" then
		handle_confirm(event, lane, respond)
	elseif event.method == "select" then
		handle_select(event, lane, respond)
	elseif event.method == "input" then
		handle_input(event, lane, respond)
	end
end

return M
