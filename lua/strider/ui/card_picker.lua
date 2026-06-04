local card_names = require("strider.ui.card_names")
local state = require("strider.state")

local M = {}

local flow_order = { q = 1, flow = 2 }
local patch_rank = 3

local function status_text(card)
	if card.status == "running" then
		return "running"
	end
	if card.status == "success" then
		return "done"
	end
	if card.status == "cancelled" then
		return "stopped"
	end
	if card.status == "error" then
		return "failed"
	end
	return card.status or "idle"
end

local function chat_status(session)
	if session.pending_request or session.progress then
		return "running"
	end
	if session.last_error and session.last_error ~= "" then
		return "failed"
	end
	local draft = ""
	if session.compose_buf and vim.api.nvim_buf_is_valid(session.compose_buf) then
		draft = table.concat(vim.api.nvim_buf_get_lines(session.compose_buf, 0, -1, false), "\n")
	end
	if vim.trim(draft) ~= "" then
		return "draft"
	end
	if session.last_summary and session.last_summary ~= "" then
		return "done"
	end
	return session.chat_collapsed and "collapsed" or "open"
end

local function has_chat_card(session)
	if not session then
		return false
	end
	if session.pending_request or session.progress or session.chat_collapsed then
		return true
	end
	if session.last_summary or session.last_error then
		return true
	end
	if session.log_buf and vim.api.nvim_buf_is_valid(session.log_buf) then
		return true
	end
	return session.compose_buf and vim.api.nvim_buf_is_valid(session.compose_buf) or false
end

local function chat_item()
	local session = state.get_session("main")
	if not has_chat_card(session) then
		return nil
	end
	return {
		label = "StriderChat · " .. chat_status(session),
		value = { type = "chat", lane = "main", name = "StriderChat" },
	}
end

local function add_flow_items(items, opts)
	for _, lane in ipairs(state.lanes()) do
		local session = state.get_session(lane)
		for _, card in ipairs(session and session.flow_cards or {}) do
			if card.kind ~= "patch" and not card.dismissed and (not opts.kind or opts.kind == card.kind) then
				local model = card.kind == "q" and card.model_label and (" · " .. card.model_label) or ""
				table.insert(items, {
					label = string.format("%s%s · %s", card_names.for_card(card), model, status_text(card)),
					order = card.started_at or 0,
					rank = flow_order[card.kind] or 9,
					value = {
						type = "flow",
						id = card.id,
						kind = card.kind,
						lane = lane,
						name = card_names.for_card(card),
					},
				})
			end
		end
	end
end

local function add_patch_items(items, opts)
	if opts.kind and opts.kind ~= "patch" then
		return
	end
	for _, lane in ipairs(state.lanes()) do
		local session = state.get_session(lane)
		for _, summary in ipairs(session and session.patch_summaries or {}) do
			if not summary.dismissed then
				table.insert(items, {
					label = string.format("%s · %s", summary.name or "StriderPatch", status_text(summary)),
					order = summary.started_at or 0,
					rank = patch_rank,
					value = { type = "patch", id = summary.id, kind = "patch", lane = lane, name = summary.name },
				})
			end
		end
	end
end

local function surface_items(opts)
	local items = {}
	add_flow_items(items, opts)
	add_patch_items(items, opts)
	table.sort(items, function(a, b)
		if a.order == b.order then
			return a.rank < b.rank
		end
		return a.order > b.order
	end)
	return items
end

function M.items(opts)
	opts = opts or {}
	local items = {}
	if not opts.kind then
		local chat = chat_item()
		if chat then
			table.insert(items, chat)
		end
	end
	vim.list_extend(items, surface_items(opts))
	return items
end

return M
